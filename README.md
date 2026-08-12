# dd2colima

Quickly migrate from Docker Desktop to Colima on macOS while keeping Docker Desktop-style compatibility for:

- `/var/run/docker.sock`
- Testcontainers (Java)
- `docker buildx` / BuildKit
- Docker contexts
- Docker credential helpers
- Docker Compose v2 (CLI plugin)

## Quick Start

### 1) Run migration (default mode)

```bash
chmod +x ./dd2colima.sh
./dd2colima.sh
```

The script prints the host CPU/RAM and prompts for the VM resources. Press Enter to
accept the suggested value, or type a number. Set the `COLIMA_*` env vars (below) to
skip the prompt entirely (useful for automation / CI).

### 2) Reload your shell

```bash
source ~/.zshrc
```

### 3) Verify

```bash
docker context ls
docker buildx ls
docker version
```

## Optional Flags

### Remove Docker Desktop after migration

```bash
./dd2colima.sh --remove-docker-desktop
```

### Adjust VM memory on demand

```bash
./dd2colima.sh --set-mem 16   # raise to 16 GB for heavy container workloads
./dd2colima.sh --set-mem 6    # lower to 6 GB to free RAM for local AI / other apps
```

This updates `~/.colima/<profile>/colima.yaml` and restarts the VM without a full
re-migration.

> **Memory note:** with `vmType: vz` (default on arm64), Colima/Lima does **not** return
> idle RAM to the host — the VM reserves whatever it is given while running (unlike
> Docker Desktop). That is why the default is a modest **8 GB**; raise it with `--set-mem`
> only when you need it, so the rest stays free for local AI / other apps.

### Destructive reset (remove Colima setup)

```bash
./dd2colima.sh --remove-colima
```

This reset mode removes Colima profiles/data, cleans related Docker client state, removes exports written by this script from your shell rc, and may uninstall `colima`/`lima` Homebrew formulas.

## Environment Overrides

Set variables before running the script:

```bash
COLIMA_PROFILE=default
COLIMA_CPU=10
COLIMA_MEM_GB=8
COLIMA_DISK_GB=100
COLIMA_VM_TYPE=vz
COLIMA_MOUNT_TYPE=virtiofs
./dd2colima.sh
```

Current script defaults (used as suggestions in the prompt):

- `COLIMA_PROFILE`: `default`
- `COLIMA_CPU`: host CPUs − 4 (minimum 2)
- `COLIMA_MEM_GB`: `8` (kept modest; `vz` reserves RAM while running)
- `COLIMA_DISK_GB`: `100`
- `COLIMA_VM_TYPE`: `vz` on arm64, `qemu` on intel
- `COLIMA_MOUNT_TYPE`: `virtiofs`

Setting any of `COLIMA_CPU` / `COLIMA_MEM_GB` / `COLIMA_DISK_GB` uses that value as the
prompt default; setting all three skips the interactive prompt.

## Notes

- Do not run Docker Desktop at the same time as Colima.
- The script may prompt for `sudo` when managing `/var/run/docker.sock`.
- If Docker Desktop was installed from DMG (not Homebrew cask), remove `/Applications/Docker.app` manually when needed.
