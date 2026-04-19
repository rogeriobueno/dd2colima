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
chmod +x ./migrate-docker-desktop-to-colima.sh
./migrate-docker-desktop-to-colima.sh
```

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
./migrate-docker-desktop-to-colima.sh --remove-docker-desktop
```

### Destructive reset (remove Colima setup)

```bash
./migrate-docker-desktop-to-colima.sh --remove-colima
```

This reset mode removes Colima profiles/data, cleans related Docker client state, removes exports written by this script from your shell rc, and may uninstall `colima`/`lima` Homebrew formulas.

## Environment Overrides

Set variables before running the script:

```bash
COLIMA_PROFILE=default
COLIMA_CPU=10
COLIMA_MEM_GB=12
COLIMA_DISK_GB=100
COLIMA_VM_TYPE=vz
COLIMA_MOUNT_TYPE=virtiofs
./migrate-docker-desktop-to-colima.sh
```

Current script defaults:

- `COLIMA_PROFILE`: `default`
- `COLIMA_CPU`: `10` (arm64 and intel)
- `COLIMA_MEM_GB`: `12` (arm64 and intel)
- `COLIMA_DISK_GB`: `100`
- `COLIMA_VM_TYPE`: `vz` on arm64, `qemu` on intel
- `COLIMA_MOUNT_TYPE`: `virtiofs`

## Notes

- Do not run Docker Desktop at the same time as Colima.
- The script may prompt for `sudo` when managing `/var/run/docker.sock`.
- If Docker Desktop was installed from DMG (not Homebrew cask), remove `/Applications/Docker.app` manually when needed.
