# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dd2colima is a migration script that helps macOS users transition from Docker Desktop to Colima while maintaining full compatibility with Docker Desktop-style workflows. The script handles socket setup, environment configuration, context management, and optional Docker Desktop removal.

## Core Script: dd2colima.sh

This is a bash script (requires bash 4+, uses `/opt/homebrew/bin/bash` shebang) with four operational modes:

### Mode 1: Migration (Default)
Installs and configures Colima to replace Docker Desktop:
- Installs/upgrades: `colima`, `docker`, `docker-buildx`, `docker-compose`, `lima`, `docker-credential-helper` via Homebrew
- Prints host CPU/RAM and prompts for VM resources (`prompt_resources()`); Enter accepts the suggested value, env vars skip the prompt, non-TTY uses suggestions
- Creates static Colima config at `~/.colima/${PROFILE}/colima.yaml`
- Starts Colima VM
- Creates `/var/run/docker.sock` symlink pointing to `~/.colima/${PROFILE}/docker.sock` (requires sudo)
- Exports environment variables to shell rc file (auto-detected: `.zshrc`, `.bashrc`, or `.profile`)
- Cleans orphan Docker contexts (desktop-linux, orbstack) and buildx state
- Sets up Docker Compose v2 as CLI plugin
- Fixes deprecated `docker-credential-desktop` references in `~/.docker/config.json`

### Mode 2: Docker Desktop Removal
Flag: `--remove-docker-desktop`
- Prunes Docker objects before removal
- Uninstalls Docker Desktop via Homebrew cask (if installed that way)
- Manual removal required for DMG installations (`/Applications/Docker.app`)

### Mode 3: Destructive Reset
Flag: `--remove-colima`
- Stops and deletes all Colima profiles
- Removes `~/.colima` directory completely
- Cleans exports from shell rc file (creates `.bak` backup)
- Removes `/var/run/docker.sock` symlink only if it points to Colima
- Optionally uninstalls `colima`/`lima` Homebrew formulas (keeps Docker CLI)
- Cleans orphan contexts and buildx state

### Mode 4: Memory Resize Helper
Flag: `--set-mem <GB>` (positive integer)
- Function `resize_memory_and_exit()`: validates the value, requires Colima installed
- Updates `memory:` in `~/.colima/${PROFILE}/colima.yaml` (creates `.bak` backup)
- Restarts the VM with `colima stop` + `colima start --memory <GB>` (no full re-migration)
- Rationale: `vmType: vz` reserves RAM while running and does not reclaim idle memory to the host (Lima issues #4828/#4220/#2789 still open), unlike Docker Desktop. Default RAM is kept modest (8 GB); raise on demand.

## Running the Script

```bash
# Basic migration
chmod +x ./dd2colima.sh
./dd2colima.sh

# Migration with Docker Desktop removal
./dd2colima.sh --remove-docker-desktop

# Destructive reset (remove Colima)
./dd2colima.sh --remove-colima

# Adjust VM memory on demand
./dd2colima.sh --set-mem 16
```

After migration, reload shell:
```bash
source ~/.zshrc  # or source ~/.bashrc
```

## Environment Overrides

Set before running the script to customize Colima VM. Setting a value uses it as the prompt default; setting all of `COLIMA_CPU`/`COLIMA_MEM_GB`/`COLIMA_DISK_GB` skips the interactive prompt entirely.
- `COLIMA_PROFILE` (default: `default`)
- `COLIMA_CPU` (default: host CPUs − 4, minimum 2)
- `COLIMA_MEM_GB` (default: `8`)
- `COLIMA_DISK_GB` (default: `100`)
- `COLIMA_VM_TYPE` (default: `vz` on arm64, `qemu` on intel)
- `COLIMA_MOUNT_TYPE` (default: `virtiofs`)

Example:
```bash
COLIMA_CPU=8 COLIMA_MEM_GB=16 ./dd2colima.sh
```

## Key Technical Details

### Socket Management
- Colima socket: `~/.colima/${PROFILE}/docker.sock`
- Compatibility symlink: `/var/run/docker.sock` → Colima socket
- Environment: `DOCKER_HOST="unix://${HOME}/.colima/${PROFILE}/docker.sock"`

### Testcontainers Support
Script exports `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="/var/run/docker.sock"` to ensure Java Testcontainers works correctly with the compatibility socket.

### BuildKit and Buildx
- `DOCKER_BUILDKIT=1` is exported
- Script ensures buildx CLI plugin is symlinked at `~/.docker/cli-plugins/docker-buildx`
- Preferred builder priority: `colima` → `default` → create new `colima` builder
- Orphan builders removed: `desktop-linux`, `orbstack`, `multiarch`

### Context Cleanup
Script removes client-side state for known orphan contexts by:
1. Running `docker context rm -f` for known contexts
2. Searching `~/.docker/contexts/meta` for stale `meta.json` files
3. Forcing default context as active

### Shell Detection
Auto-detects shell rc file in this order:
1. `${ZDOTDIR}/.zshrc` (if ZDOTDIR set)
2. `~/.zshrc`
3. `~/.bashrc`
4. `~/.profile`

## Script Architecture

Key helper functions:
- `detect_shell_rc()` - Finds user's shell configuration file
- `append_once()` - Idempotent append to rc file
- `ensure_symlink()` - Creates/updates symlinks with sudo
- `purge_orphan_contexts()` - Removes stale Docker contexts
- `purge_orphan_buildx_state()` - Cleans `~/.docker/buildx` leftovers
- `ensure_default_builder()` - Sets up functional buildx builder
- `remove_script_exports_from_rc()` - Removes exports (with backup) using perl
- `safe_prune()` - Docker system prune with error suppression
- `is_uint()` - Validates a value is a positive integer
- `prompt_resources()` - Detects host CPU/RAM, shows specs, resolves CPU/MEM/DISK (env override > prompt > suggested)
- `resize_memory_and_exit()` - `--set-mem` handler: rewrites `memory:` in colima.yaml and restarts the VM

## Verification Commands

After migration:
```bash
docker context ls
docker buildx ls
docker version
docker compose version
```

Multi-arch buildx test:
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t test/multiarch:dev . --load
```

## Important Notes

- Script requires `bash` 4+ (uses `/opt/homebrew/bin/bash` shebang for macOS Homebrew bash)
- Uses `set -euo pipefail` for strict error handling
- Do not run Docker Desktop and Colima simultaneously
- Script may prompt for `sudo` when managing `/var/run/docker.sock`
- Colored output for logging: green `[OK]`, yellow `[WARN]`, red `[FAIL]`
- Architecture detection via `uname -m`: `arm64` → `aarch64`, else `x86_64`
