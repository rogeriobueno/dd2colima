#!/opt/homebrew/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# dd2colima.sh
#
# Goal:
#   Replace Docker Desktop with Colima on macOS while keeping maximum
#   compatibility for tools that assume Docker Desktop defaults, especially:
#     - /var/run/docker.sock
#     - Testcontainers (Java)
#     - docker buildx / BuildKit
#     - Docker contexts
#     - Docker credential helpers
#     - Docker Compose v2 (CLI plugin)
#
# Modes:
#   1) Migration mode (default):
#        - installs/updates Colima + Docker CLI tools via Homebrew
#        - shows the host CPU/RAM and prompts for VM resources
#          (Enter accepts the suggested value; env overrides skip the prompt)
#        - writes a static Colima config (no interactive editor)
#        - starts Colima
#        - creates /var/run/docker.sock symlink -> Colima socket
#        - sets env vars for DOCKER_HOST, DOCKER_BUILDKIT, TESTCONTAINERS...
#        - cleans orphan contexts/buildx leftovers (Desktop/OrbStack)
#        - optionally uninstalls Docker Desktop (brew cask only)
#
#   2) Destructive reset mode:
#        --remove-colima
#        - removes Colima VMs/profiles (best-effort)
#        - deletes ~/.colima completely
#        - removes related env lines from shell rc (with .bak backup)
#        - cleans orphan Docker contexts and buildx state
#        - removes /var/run/docker.sock only if it points to ~/.colima
#        - optionally uninstalls Homebrew formulas colima/lima (keeps docker CLI)
#
#   3) Memory resize helper:
#        --set-mem <GB>
#        - adjusts the running VM's RAM to <GB> (integer) without a full
#          re-migration: updates ~/.colima/<profile>/colima.yaml and restarts.
#        - NOTE: with vmType "vz" (default on arm64) Colima/Lima does NOT return
#          idle RAM to the host; the VM reserves whatever it is given while it
#          runs. Keep RAM low (default 8 GB) and use this helper to raise it only
#          when a heavy container workload needs it, so the rest stays free for
#          local AI / other apps.
#
# Flags:
#   --remove-colima
#   --remove-docker-desktop
#   --set-mem <GB>
#
# Optional environment overrides (set to skip the interactive prompt):
#   COLIMA_PROFILE        (default: default)
#   COLIMA_CPU            (default: host CPUs - 4, min 2)
#   COLIMA_MEM_GB         (default: 8)
#   COLIMA_DISK_GB        (default: 100)
#   COLIMA_VM_TYPE        (default: arm64->vz, intel->qemu)
#   COLIMA_MOUNT_TYPE     (default: virtiofs)
# -----------------------------------------------------------------------------

REMOVE_DOCKER_DESKTOP="false"
REMOVE_COLIMA="false"
SET_MEM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-docker-desktop) REMOVE_DOCKER_DESKTOP="true" ;;
    --remove-colima)         REMOVE_COLIMA="true" ;;
    --set-mem)               SET_MEM="${2:-}"; shift ;;
    --set-mem=*)             SET_MEM="${1#*=}" ;;
    *) ;;
  esac
  shift
done

# -------------------------------
# Logging helpers
# -------------------------------
ok()   { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

detect_shell_rc() {
  # Prefer zsh, then bash, then profile
  if [[ -n "${ZDOTDIR:-}" && -f "${ZDOTDIR}/.zshrc" ]]; then echo "${ZDOTDIR}/.zshrc"
  elif [[ -f "${HOME}/.zshrc" ]]; then echo "${HOME}/.zshrc"
  elif [[ -f "${HOME}/.bashrc" ]]; then echo "${HOME}/.bashrc"
  else echo "${HOME}/.profile"; fi
}

append_once() {
  local line="$1" file="$2"
  grep -Fqs -- "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

safe_prune() {
  # Do not fail if the daemon is not running
  docker system prune -af >/dev/null 2>&1 || true
}

ensure_symlink() {
  local target="$1" link="$2"
  sudo mkdir -p "$(dirname "$link")"
  if [[ -L "$link" ]]; then
    local cur
    cur="$(readlink "$link" || true)"
    [[ "$cur" == "$target" ]] && return 0
  fi
  sudo ln -sfn "$target" "$link"
}

purge_orphan_contexts() {
  # Remove known orphan Docker contexts (client-side; does not require daemon)
  docker context rm -f colima        >/dev/null 2>&1 || true
  docker context rm -f desktop-linux >/dev/null 2>&1 || true
  docker context rm -f orbstack      >/dev/null 2>&1 || true

  # Hard cleanup metadata in rare cases where it persists
  local META_DIR="$HOME/.docker/contexts/meta"
  if [[ -d "$META_DIR" ]]; then
    find "$META_DIR" -type f -name "meta.json" -print0 \
      | xargs -0 grep -l '"Name":"colima"' 2>/dev/null \
      | xargs -I{} rm -f "{}" 2>/dev/null || true

    find "$META_DIR" -type f -name "meta.json" -print0 \
      | xargs -0 grep -l '"Name":"desktop-linux"' 2>/dev/null \
      | xargs -I{} rm -f "{}" 2>/dev/null || true

    find "$META_DIR" -type f -name "meta.json" -print0 \
      | xargs -0 grep -l '"Name":"orbstack"' 2>/dev/null \
      | xargs -I{} rm -f "{}" 2>/dev/null || true

    find "$META_DIR" -type d -empty -delete 2>/dev/null || true
  fi

  docker context use default >/dev/null 2>&1 || true
}

purge_orphan_buildx_state() {
  # Remove buildx local state for known orphan builders.
  local BX="$HOME/.docker/buildx"

  rm -rf "$BX/instances/desktop-linux" \
         "$BX/instances/orbstack" \
         "$BX/instances/multiarch" >/dev/null 2>&1 || true

  rm -rf "$BX/contexts/docker/desktop-linux" \
         "$BX/contexts/docker/orbstack" >/dev/null 2>&1 || true

  # Remove buildx 'current' pointer (safe)
  [[ -e "$BX/current" ]] && rm -f "$BX/current" >/dev/null 2>&1 || true
}

ensure_default_builder() {
  # Prefer 'colima' builder if it exists; else use 'default'; else create 'colima'
  if docker buildx inspect colima >/dev/null 2>&1; then
    docker buildx use colima >/dev/null
  elif docker buildx inspect default >/dev/null 2>&1; then
    docker buildx use default >/dev/null
  else
    docker buildx create --name colima --driver docker-container --use >/dev/null
  fi
  docker buildx inspect --bootstrap >/dev/null
}

remove_script_exports_from_rc() {
  # Remove the exact exports this script adds (creates a .bak backup once).
  local rc="$1"
  [[ -f "$rc" ]] || return 0

  cp -n "$rc" "${rc}.bak" 2>/dev/null || true

  # Remove DOCKER_HOST lines pointing to ~/.colima/**/docker.sock
  # Remove DOCKER_BUILDKIT and TESTCONTAINERS override lines we add.
  perl -i -ne '
    next if /^export DOCKER_HOST="unix:\/\/.*\/\.colima\/.*\/docker\.sock"\s*$/;
    next if /^export DOCKER_BUILDKIT=1\s*$/;
    next if /^export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="\/var\/run\/docker\.sock"\s*$/;
    print;
  ' "$rc" 2>/dev/null || true
}

remove_colima_everything_and_exit() {
  warn ">>> DESTRUCTIVE MODE: Removing Colima completely (for retesting) <<<"

  # 1) Remove exports from shell rc
  local rc
  rc="$(detect_shell_rc)"
  warn "Removing script exports from: $rc (backup: ${rc}.bak)"
  remove_script_exports_from_rc "$rc"

  # 2) Clean orphan contexts/buildx client-side state
  warn "Cleaning orphan Docker contexts and buildx state..."
  purge_orphan_contexts
  purge_orphan_buildx_state

  # 3) Stop & delete Colima profiles (best-effort)
  if have colima; then
    warn "Stopping Colima (if running)..."
    colima stop --profile default >/dev/null 2>&1 || true

    if colima list >/dev/null 2>&1; then
      warn "Deleting all Colima profiles..."
      mapfile -t PROFILES < <(colima list 2>/dev/null | awk 'NR>1{print $1}' | sed 's/*//g' | grep -vE '^(NAME|)$' || true)
      if [[ "${#PROFILES[@]}" -gt 0 ]]; then
        for p in "${PROFILES[@]}"; do
          [[ -z "$p" ]] && continue
          colima delete -f --profile "$p" >/dev/null 2>&1 || true
        done
      else
        colima delete -f --profile default >/dev/null 2>&1 || true
      fi
    else
      warn "colima list not available; deleting default profile..."
      colima delete -f --profile default >/dev/null 2>&1 || true
    fi
  fi

  # 4) Remove ~/.colima entirely
  warn "Deleting ~/.colima ..."
  rm -rf "$HOME/.colima" >/dev/null 2>&1 || true

  # 5) Remove /var/run/docker.sock only if it points to ~/.colima
  warn "Checking /var/run/docker.sock..."
  if [[ -L /var/run/docker.sock ]]; then
    local cur
    cur="$(readlink /var/run/docker.sock || true)"
    if [[ "$cur" == *"/.colima/"* ]]; then
      warn "Removing /var/run/docker.sock symlink (it pointed to Colima)..."
      sudo rm -f /var/run/docker.sock >/dev/null 2>&1 || true
    else
      warn "/var/run/docker.sock exists but does not point to Colima; leaving it untouched."
    fi
  fi

  # 6) Optionally uninstall Homebrew formulas colima/lima (keep docker CLI)
  if have brew; then
    warn "Uninstalling Homebrew formulas colima/lima (keeping Docker CLI)..."
    brew uninstall colima >/dev/null 2>&1 || true
    brew uninstall lima  >/dev/null 2>&1 || true
  else
    warn "Homebrew not found; skipping brew uninstall."
  fi

  ok "Colima removal completed."
  cat <<'EOF'

Next steps (to retest Docker Desktop):
  1) Install Docker Desktop manually (DMG or Homebrew cask).
  2) Start Docker Desktop and wait until it's running.
  3) Validate:
       docker version
       docker context ls
       docker buildx ls
       docker compose ls

Note:
  - Your shell rc file backup was created as *.bak (if changes were made).

EOF
  exit 0
}

is_uint() {
  # True when arg is a positive integer (>= 1)
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]]
}

prompt_resources() {
  # Resolve CPU / MEM_GB / DISK_GB into globals.
  # Priority: explicit env override > interactive prompt > suggested default.
  # Non-interactive (no TTY) or env-set values skip the prompt entirely.
  local host_cpus host_mem_gb sug_cpu sug_mem sug_disk ans

  host_cpus="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  host_mem_gb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo $((4*1024*1024*1024))) / 1024 / 1024 / 1024 ))"

  # Suggested defaults (with safety floors)
  sug_cpu=$(( host_cpus - 4 )); (( sug_cpu < 2 )) && sug_cpu=2
  sug_mem=8                                        # keep RAM low for local AI / other apps
  sug_disk=100

  ok "Detected host: ${host_cpus} CPU, ${host_mem_gb} GB RAM (${HOST_ARCH})"
  warn "Note: with vmType '${VM_TYPE}' the VM RESERVES its RAM while running (no reclaim to host)."
  warn "      Keep memory modest; raise later on demand with:  $(basename "$0") --set-mem <GB>"

  # If all three come from env, skip the prompt (automation / CI).
  if [[ -n "${COLIMA_CPU:-}" && -n "${COLIMA_MEM_GB:-}" && -n "${COLIMA_DISK_GB:-}" ]]; then
    CPU="$COLIMA_CPU"; MEM_GB="$COLIMA_MEM_GB"; DISK_GB="$COLIMA_DISK_GB"
    ok "Using resources from environment: CPU=${CPU}, MEM=${MEM_GB}GB, DISK=${DISK_GB}GB"
    return 0
  fi

  # Start from env value if present, else suggested.
  CPU="${COLIMA_CPU:-$sug_cpu}"
  MEM_GB="${COLIMA_MEM_GB:-$sug_mem}"
  DISK_GB="${COLIMA_DISK_GB:-$sug_disk}"

  # No TTY: accept suggested/env values without prompting.
  if [[ ! -t 0 ]]; then
    ok "Non-interactive shell; using CPU=${CPU}, MEM=${MEM_GB}GB, DISK=${DISK_GB}GB"
    return 0
  fi

  # Interactive: ask each value; empty Enter accepts the shown default.
  if [[ -z "${COLIMA_CPU:-}" ]]; then
    read -r -p "CPU cores for the VM [${CPU}]: " ans || true
    [[ -n "$ans" ]] && { is_uint "$ans" && CPU="$ans" || warn "Invalid value; keeping ${CPU}"; }
  fi
  if [[ -z "${COLIMA_MEM_GB:-}" ]]; then
    read -r -p "Memory in GB for the VM [${MEM_GB}]: " ans || true
    [[ -n "$ans" ]] && { is_uint "$ans" && MEM_GB="$ans" || warn "Invalid value; keeping ${MEM_GB}"; }
  fi
  if [[ -z "${COLIMA_DISK_GB:-}" ]]; then
    read -r -p "Disk in GB for the VM [${DISK_GB}]: " ans || true
    [[ -n "$ans" ]] && { is_uint "$ans" && DISK_GB="$ans" || warn "Invalid value; keeping ${DISK_GB}"; }
  fi

  ok "Selected resources: CPU=${CPU}, MEM=${MEM_GB}GB, DISK=${DISK_GB}GB"
}

resize_memory_and_exit() {
  # Adjust the running VM's RAM to $SET_MEM (integer GB) and restart, without a
  # full re-migration. Persists the value in colima.yaml.
  local gb="$1"
  local profile cfg
  profile="${COLIMA_PROFILE:-default}"
  cfg="$HOME/.colima/${profile}/colima.yaml"

  is_uint "$gb" || die "--set-mem requires a positive integer (GB). Got: '${gb}'"
  have colima   || die "Colima is not installed. Run the migration first."

  if [[ -f "$cfg" ]]; then
    cp -n "$cfg" "${cfg}.bak" 2>/dev/null || true
    if grep -qE '^memory:' "$cfg"; then
      perl -i -pe "s/^memory:.*\$/memory: ${gb}/" "$cfg" 2>/dev/null || true
    else
      printf 'memory: %s\n' "$gb" >> "$cfg"
    fi
  else
    warn "Config $cfg not found; colima start will create it with the new memory."
  fi

  ok "Restarting Colima (profile=${profile}) with memory=${gb}GB..."
  colima stop  --profile "$profile" >/dev/null 2>&1 || true
  colima start --profile "$profile" --memory "$gb" >/dev/null

  ok "Memory now set to: $(grep -E '^memory:' "$cfg" 2>/dev/null || echo "memory: ${gb}")"
  docker version >/dev/null 2>&1 && ok "Docker daemon reachable." || warn "Docker not reachable yet; open a new terminal or check 'colima status'."
  exit 0
}

# -------------------------------
# Entry: memory resize helper
# -------------------------------
if [[ -n "$SET_MEM" ]]; then
  resize_memory_and_exit "$SET_MEM"
fi

# -------------------------------
# Entry: destructive reset mode
# -------------------------------
if [[ "$REMOVE_COLIMA" == "true" ]]; then
  remove_colima_everything_and_exit
fi

# -------------------------------
# Normal mode: migrate to Colima
# -------------------------------
have uname || die "uname is required"
HOST_ARCH="$(uname -m || true)"

PROFILE="${COLIMA_PROFILE:-default}"
MOUNT_TYPE="${COLIMA_MOUNT_TYPE:-virtiofs}"

if [[ "$HOST_ARCH" == "arm64" ]]; then
  ARCH="aarch64"
  VM_TYPE="${COLIMA_VM_TYPE:-vz}"
else
  ARCH="x86_64"
  VM_TYPE="${COLIMA_VM_TYPE:-qemu}"
fi

# Resolve CPU / MEM_GB / DISK_GB (env override > interactive prompt > suggested)
prompt_resources

SOCK_COLIMA="$HOME/.colima/${PROFILE}/docker.sock"
SOCK_STD="/var/run/docker.sock"
CONFIG="$HOME/.docker/config.json"

have brew || die "Homebrew (brew) is required in migrate mode. Install it first and rerun."

ok "Updating Homebrew and installing required packages..."
brew update >/dev/null || true
brew install colima docker docker-buildx docker-compose lima >/dev/null 2>&1 || true
brew upgrade colima docker docker-buildx docker-compose lima >/dev/null 2>&1 || true
brew install docker-credential-helper >/dev/null 2>&1 || true
brew upgrade docker-credential-helper >/dev/null 2>&1 || true

ok "Ensuring Docker CLI plugins directory (buildx)..."
mkdir -p "$HOME/.docker/cli-plugins"
if have docker-buildx; then
  ln -sfn "$(which docker-buildx)" "$HOME/.docker/cli-plugins/docker-buildx"
fi

ok "Ensuring Docker Compose v2 (CLI plugin)..."
if have docker-compose; then
  ln -sfn "$(which docker-compose)" "$HOME/.docker/cli-plugins/docker-compose"
else
  die "docker-compose not found after brew install. Compose v2 is required."
fi

#Fix Docker credential helper
if [[ -f "$CONFIG" ]] && grep -q '"desktop"' "$CONFIG"; then
  warn "Removing deprecated docker-credential-desktop references"
  cp "$CONFIG" "$CONFIG.bak"
  sed -E \
    -e '/"credHelpers"/,/\}/d' \
    -e 's/"credsStore"[[:space:]]*:[[:space:]]*"desktop"/"credsStore": "osxkeychain"/' \
    "$CONFIG.bak" > "$CONFIG"
fi

# Quit Docker Desktop if running (best-effort)
if pgrep -f "Docker.app" >/dev/null 2>&1; then
  warn "Docker Desktop is running; quitting it..."
  osascript -e 'quit app "Docker"' || true
  sleep 2
fi

# If asked to remove Docker Desktop, prune first (ignore failures)
if [[ "$REMOVE_DOCKER_DESKTOP" == "true" ]]; then
  warn "Pruning unused Docker objects (safe; ignored if daemon is not running)..."
  safe_prune
fi

# Write static Colima config (non-interactive; no --edit)
ok "Writing Colima config (profile=$PROFILE, arch=$ARCH, vmType=$VM_TYPE, mountType=$MOUNT_TYPE)..."
mkdir -p "$HOME/.colima/$PROFILE"
cat > "$HOME/.colima/$PROFILE/colima.yaml" <<EOF
cpu: ${CPU}
memory: ${MEM_GB}
disk: ${DISK_GB}
arch: ${ARCH}
vmType: ${VM_TYPE}
mountType: ${MOUNT_TYPE}
EOF

ok "Starting Colima..."
colima start --profile "$PROFILE" >/dev/null

# Docker Desktop compatibility socket
ok "Creating Docker Desktop-compatible socket: $SOCK_STD -> $SOCK_COLIMA (sudo may prompt)..."
ensure_symlink "$SOCK_COLIMA" "$SOCK_STD"

# Shell env exports
RC_FILE="$(detect_shell_rc)"
ok "Writing environment exports to: $RC_FILE"
append_once "export DOCKER_HOST=\"unix://${SOCK_COLIMA}\"" "$RC_FILE"
append_once "export DOCKER_BUILDKIT=1" "$RC_FILE"
append_once "export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=\"/var/run/docker.sock\"" "$RC_FILE"

# Export for current session
export DOCKER_HOST="unix://${SOCK_COLIMA}"
export DOCKER_BUILDKIT=1
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="/var/run/docker.sock"

# Smoke test
ok "Validating Docker daemon connectivity..."
docker version >/dev/null

warn "Running hello-world (optional; ignored if networking/proxy blocks it)..."
docker run --rm hello-world >/dev/null 2>&1 || true

# Cleanup orphan contexts/buildx state (Desktop/OrbStack leftovers)
warn "Cleaning orphan Docker contexts (desktop-linux/orbstack) ..."
purge_orphan_contexts

warn "Cleaning orphan buildx state (desktop-linux/orbstack/multiarch) ..."
purge_orphan_buildx_state

ok "Ensuring a healthy default buildx builder..."
ensure_default_builder

# Optionally remove Docker Desktop via brew cask (only if installed that way)
if [[ "$REMOVE_DOCKER_DESKTOP" == "true" ]]; then
  if brew list --cask docker >/dev/null 2>&1; then
    warn "Uninstalling Docker Desktop (Homebrew cask docker)..."
    brew uninstall --cask docker >/dev/null 2>&1 || true
  else
    warn "Docker Desktop cask not found. If installed via DMG, remove /Applications/Docker.app manually if desired."
  fi
fi

cat <<'EOF'

[Done] Migration completed.

Important:
  - Open a NEW terminal or run:  source ~/.zshrc   (or your shell rc file)
  - Do NOT run Docker Desktop at the same time (it may take over /var/run/docker.sock).

Quick checks:
  docker context ls
  docker buildx ls
  docker version

Adjust VM memory later (no re-migration; vz reserves RAM while running):
  ./dd2colima.sh --set-mem 16   # raise to 16 GB for heavy container workloads
  ./dd2colima.sh --set-mem 6    # lower to 6 GB to free RAM for local AI / other apps

Buildx multi-arch test (run in a directory that contains a Dockerfile):
  docker buildx build --platform linux/amd64,linux/arm64 -t test/multiarch:dev . --load
  # If your Dockerfile is elsewhere, use: -f /path/to/Dockerfile /path/to/context

EOF

ok "All set."