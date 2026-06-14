# VM agent backups

PABS backs up VMs and LXCs with a lightweight agent deployed once per guest. The agent auto-detects the VM type, collects only what is needed to restore, and produces a self-contained `.tar.zst` bundle that PABS pulls back to USB during the backup run.

No disk images are involved. Each bundle includes a `restore-notes.txt` with type-specific instructions. This repository is not required at restore time.

---

## Supported types

| Type | Detection | What is backed up |
| :--- | :-------- | :---------------- |
| `docker` | `docker` CLI present | All compose files + `.env` files, Docker daemon config, named volumes (under threshold), package list |
| `haos` | `ha` CLI present + `/config/configuration.yaml` exists | Full native HA snapshot (`.tar`) via `ha` CLI — one-click restore in the HA UI |
| `minecraft` | `minecraft` system user, or `MINECRAFT_BASE` directory present | Weekly `.tar.zst` archives from [minecraft-server-setup](https://github.com/LetsGaming/minecraft-server-setup), server config files, mods/plugins |
| `generic` | everything else | `/etc/` (full), cron jobs, `/usr/local/bin/`, `/root/scripts/`, package list |

Detection runs in the order above — first match wins. Override with `--set PABS_TYPE=<type>` during installation.

---

## Installation

> **Using the wizard?** Run `sudo bash /opt/pabs/setup.sh --step agents` — it handles SSH key generation, asks type-specific questions, and calls `install-agent.sh` for you. The steps below are for manual setup or adding agents outside the wizard.

### Step 0 — Grant SSH access from the Proxmox host to the VM

`install-agent.sh` connects to the VM over SSH. The Proxmox host must be able to authenticate before the script can run. Do this once per VM.

**Generate a dedicated key** (recommended — keeps agent access separate from your default key):

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_pabs_agent -N ""
```

**Copy the public key to the VM:**

```bash
ssh-copy-id -i /root/.ssh/id_ed25519_pabs_agent.pub root@<vm-ip>
```

For LXCs without `ssh-copy-id`, copy it manually:

```bash
ssh root@<vm-ip> "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat /root/.ssh/id_ed25519_pabs_agent.pub | ssh root@<vm-ip> "tee -a ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

**Verify access works:**

```bash
ssh -i /root/.ssh/id_ed25519_pabs_agent root@<vm-ip> "echo OK"
```

Once this returns `OK`, proceed to Step 1.

> If you skip the dedicated key and use your default key instead, `install-agent.sh` will still work — just omit the `--key` flag. The dedicated key is recommended so that rotating your default host key later does not silently break agent backups.

### Step 1 — Deploy the agent

Run `install-agent.sh` from the Proxmox host once per VM. It copies the agent files, runs first-time setup on the VM, registers the SSH host key in `/root/.ssh/pabs_known_hosts`, and prints the `VM_AGENTS` line to add to `config.sh`.

```bash
chmod +x /opt/pabs/install-agent.sh

# Basic install — auto-detect type
./install-agent.sh root@192.168.1.10

# With a dedicated SSH key
./install-agent.sh root@192.168.1.10 --key /root/.ssh/id_ed25519_pabs_agent

# Custom remote install path
./install-agent.sh root@192.168.1.10 --dir /home/backup/pabs-agent

# Pass configuration at install time
./install-agent.sh alice@192.168.1.40 \
    --set MINECRAFT_BASE=/home/alice/servers/backups \
    --set MINECRAFT_SERVER_BASE=/home/alice/servers \
    --set MC_KEEP_WEEKLY=2
```

### Step 2 — Add to `config.sh`

Copy the `VM_AGENTS` line printed by `install-agent.sh`:

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root     /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root     /config/.pabs-agent/agent.sh"
    "pihole-lxc   192.168.1.30   root     /opt/pabs-agent/agent.sh"
    "mc-server    192.168.1.40   alice    /opt/pabs-agent/agent.sh"
)
```

> **HAOS note:** the agent path for HAOS is `/config/.pabs-agent/agent.sh`, not `/opt/pabs-agent/agent.sh`. `install-agent.sh` prints and registers the correct path automatically when you pass `--set PABS_TYPE=haos` or `--port 22222`.

### Step 3 — Test

```bash
/opt/pabs/backup.sh --dry-run
```

Run a full backup and verify bundles appear at `/mnt/backup-usb/proxmox-backup/<date>/vm-agents/<label>/`.

---

## Configuring agents with `--set`

All agent configuration is applied from the Proxmox host at install time via `--set KEY=VALUE` flags. No manual SSH into the VM required afterwards.

`--set` can be repeated:

```bash
./install-agent.sh root@192.168.1.10 \
    --set PABS_TYPE=docker \
    --set DOCKER_MANAGER=dockge \
    --set DOCKGE_STACKS_DIR=/opt/mystacks
```

To update a setting after initial installation, re-run `install-agent.sh` with the new `--set` value. It overwrites the previous value and updates the agent files to the latest version.

---

## Type-specific configuration

### Docker (`types/docker.sh`)

| Variable | Default | Description |
| :------- | :------ | :---------- |
| `DOCKER_COMPOSE_DIR` | `""` | If set, search only this directory for compose files (skips auto-detection) |
| `DOCKER_SEARCH_PATHS` | `/opt /srv /home /root /var/lib/docker/compose` | Directories to search for compose files when no manager is detected |
| `DOCKER_SEARCH_DEPTH` | `3` | Recursion depth for compose file search |
| `DOCKER_MANAGER` | `auto` | Manager override: `auto` \| `none` \| `dockge` \| `portainer` |
| `DOCKGE_STACKS_DIR` | `/opt/stacks` | Dockge stacks directory |
| `DOCKGE_DATA_DIR` | `/opt/dockge` | Dockge data/config directory |
| `PORTAINER_URL` | `http://localhost:9000` | Portainer API URL |
| `PORTAINER_TOKEN` | `""` | Portainer API token for stack export (`ptr_...`) |
| `DOCKER_INCLUDE_VOLUMES` | `""` | Comma-separated named volumes to always include |
| `DOCKER_VOLUME_AUTO_THRESHOLD_MB` | `5` | Auto-include volumes smaller than this many MB |
| `DOCKER_SKIP_VOLUMES` | `false` | Set to `true` to skip all volume backups |
| `EXTRA_PATHS` | `""` | Space-separated extra paths to always include (universal — works across all agent types) |

**Examples:**

```bash
# Dockge with a non-default stacks directory
./install-agent.sh root@192.168.1.10 \
    --set DOCKER_MANAGER=dockge \
    --set DOCKGE_STACKS_DIR=/srv/stacks \
    --set DOCKGE_DATA_DIR=/srv/dockge

# Portainer with API stack export
./install-agent.sh root@192.168.1.10 \
    --set DOCKER_MANAGER=portainer \
    --set PORTAINER_URL=http://localhost:9000 \
    --set PORTAINER_TOKEN=ptr_abc123xyz

# Force-include specific named volumes regardless of size
./install-agent.sh root@192.168.1.10 \
    --set DOCKER_INCLUDE_VOLUMES=portainer_data,traefik_certs,vaultwarden_data
```

---

### Home Assistant OS (`types/haos.sh`)

The PABS agent runs inside the **SSH & Web Terminal add-on** shell. This is not the same as SSH access to the HAOS VM itself — HAOS does not expose a standard Linux SSH server. The add-on is required.

#### Why the agent lives in `/config/.pabs-agent/`

HAOS OS updates regenerate the add-on container from scratch. Any files written into the container's own filesystem — `/opt/`, `/etc/`, `/root/`, etc. — are wiped on every update. The only path that survives is `/config/`, which is mounted from the persistent HA host storage (the same directory that holds `configuration.yaml`).

For this reason, `install-agent.sh` automatically installs the agent to `/config/.pabs-agent/` when it detects a HAOS target (via `--set PABS_TYPE=haos` or `--port 22222`). The agent reads its config from `/config/.pabs-agent/config` — also persistent. No manual redeploy after HAOS updates is required.

The `VM_AGENTS` entry in `config.sh` will therefore point to `/config/.pabs-agent/agent.sh` instead of the usual `/opt/pabs-agent/agent.sh`. `install-agent.sh` prints and registers the correct path automatically.

#### Prerequisites — SSH add-on setup

**1. Install the add-on:**

In the HA UI: Settings → Add-ons → Add-on store → search **SSH & Web Terminal** → Install.

Use the **"SSH & Web Terminal"** add-on by the Home Assistant team (not the legacy "SSH Server" add-on). It provides a proper shell with the `ha` CLI available.

**2. Configure and start the add-on:**

In the add-on configuration, set an authorised key. Using a key is strongly recommended — set it here in the add-on config UI (not by writing to `~/.ssh/authorized_keys` inside the shell, which would be lost on updates):

```yaml
authorized_keys:
  - "ssh-ed25519 AAAA... root@proxmox"
```

Paste the contents of `/root/.ssh/id_ed25519_pabs_agent.pub` from your Proxmox host.

Set `sftp: true` — required for `scp` to work (used by `install-agent.sh` as the fallback when `rsync` is not available).

Start the add-on and enable **"Start on boot"**.

**3. Note the SSH port:**

The add-on listens on port **22222** by default (not 22). SSH into it from the Proxmox host to verify access:

```bash
ssh -i /root/.ssh/id_ed25519_pabs_agent -p 22222 root@<haos-ip> "ha --version"
```

If this returns a version string (e.g. `2024.11.0`), access is working.

**4. Deploy the agent:**

```bash
./install-agent.sh root@<haos-ip> \
    --key /root/.ssh/id_ed25519_pabs_agent \
    --port 22222 \
    --set PABS_TYPE=haos
```

`install-agent.sh` will install the agent to `/config/.pabs-agent/` and register the `VM_AGENTS` entry with the correct persistent path. No further action is needed after HAOS updates.

> The `--port` flag passes `-p 22222` to the SSH and scp calls inside `install-agent.sh`. Without it, the connection attempt goes to port 22 which is not listening on HAOS.

The add-on shell is Alpine-based. `rsync` is not installed by default — `install-agent.sh` detects this and falls back to `scp` automatically.

---

**Variable reference:**

Triggers a native HA snapshot via the `ha` CLI.

| Variable | Default | Description |
| :------- | :------ | :---------- |
| `HAOS_BACKUP_DIR` | `/backup` | Where HA stores snapshots (inside the add-on shell) |
| `HAOS_BACKUP_NAME` | `pabs-auto` | Prefix for the generated backup name (visible in HA UI) |
| `HAOS_BACKUP_TYPE` | `full` | `full` or `partial` |
| `HAOS_BACKUP_PASSWORD` | `""` | Encrypt the HA snapshot (leave empty for no encryption) |
| `HAOS_WAIT_SECONDS` | `300` | Max seconds to wait for HA to finish creating the snapshot. Must be greater than 0. |
| `HAOS_POLL_INTERVAL` | `10` | How often to poll for snapshot completion (seconds) |
| `HAOS_KEEP_ON_HOST` | `1` | How many `pabs-*` backups to keep on the HA host; oldest pruned after pull |
| `HAOS_PARTIAL_ADDONS` | `""` | Comma-separated add-on slugs (partial backup only) |
| `HAOS_PARTIAL_FOLDERS` | `""` | Comma-separated folders (partial backup only): `homeassistant,ssl,share,media,addons/local` |

> HA snapshots are commonly 200 MB – 2 GB. Set `VM_AGENT_KEEP_BUNDLES=1` in `config.sh` if USB space is limited.

**Examples:**

```bash
# Full backup with encryption
./install-agent.sh root@192.168.1.20 \
    --port 22222 \
    --set PABS_TYPE=haos \
    --set HAOS_BACKUP_PASSWORD=mysecretpassword \
    --set HAOS_KEEP_ON_HOST=2

# Partial backup — HA config and SSL only
./install-agent.sh root@192.168.1.20 \
    --port 22222 \
    --set PABS_TYPE=haos \
    --set HAOS_BACKUP_TYPE=partial \
    --set HAOS_PARTIAL_FOLDERS=homeassistant,ssl
```

---

### Minecraft (`types/minecraft.sh`)

Designed to work with [minecraft-server-setup](https://github.com/LetsGaming/minecraft-server-setup). Defaults match an unmodified install — only set these if you changed the username, install path, or backup path in `variables.json`.

| Variable | Default | Description |
| :------- | :------ | :---------- |
| `MINECRAFT_BASE` | `/home/minecraft/minecraft-server/backups` | Parent directory containing per-instance backup folders |
| `MINECRAFT_SERVER_BASE` | `/home/minecraft/minecraft-server` | Server root — used to capture `server.properties`, mods, plugins |
| `MC_KEEP_WEEKLY` | `4` | How many weekly archives to include per instance |
| `MC_KEEP_DAILY` | `0` | How many daily archives to include (0 = skip dailies entirely) |
| `MC_MIN_AGE_MINUTES` | `5` | Only include archives older than this — guards against in-progress compression |
| `MC_INCLUDE_MODS` | `true` | Include the `mods/` directory from each server instance |
| `EXTRA_PATHS` | `""` | Space-separated extra paths to always include (universal — works across all agent types) |

**Examples:**

```bash
# Default minecraft-server-setup install — no --set flags needed
./install-agent.sh minecraft@192.168.1.40

# Non-default username
./install-agent.sh alice@192.168.1.40 \
    --set MINECRAFT_BASE=/home/alice/minecraft-server/backups \
    --set MINECRAFT_SERVER_BASE=/home/alice/minecraft-server

# Multiple instances with daily archives
./install-agent.sh minecraft@192.168.1.40 \
    --set MC_KEEP_WEEKLY=4 \
    --set MC_KEEP_DAILY=2 \
    --set MC_MIN_AGE_MINUTES=10
```

---

### Generic (`types/generic.sh`)

Catch-all for Pi-hole, AdGuard Home, Nginx, Vaultwarden, Gitea, and any plain Debian/Ubuntu VM or LXC. Backs up `/etc/` (the primary config store for most Linux services), cron jobs, scripts, and the package list.

| Variable | Default | Description |
| :------- | :------ | :---------- |
| `GENERIC_INCLUDE_ETC` | `true` | Back up `/etc/` (full) |
| `GENERIC_INCLUDE_CRON` | `true` | Back up crontabs |
| `GENERIC_INCLUDE_SCRIPTS` | `true` | Back up `/usr/local/bin/` and `/root/scripts/` |
| `GENERIC_INCLUDE_PACKAGES` | `true` | Save dpkg selections and apt marks |
| `GENERIC_EXCLUDE_PATHS` | `""` | Space-separated paths to exclude from `/etc/` (rsync `--exclude` syntax) |
| `EXTRA_PATHS` | `""` | Space-separated extra paths to always include |

The agent detects common services that store data outside `/etc/` and logs a hint if found (AdGuard Home, Vaultwarden, Gitea, Nextcloud, etc.) — add their data paths to `EXTRA_PATHS` to include them.

**Examples:**

```bash
# Pi-hole — /etc/pihole/ is already under /etc/, no EXTRA_PATHS needed
./install-agent.sh root@192.168.1.30

# AdGuard Home — data directory is outside /etc/
./install-agent.sh root@192.168.1.31 \
    --set EXTRA_PATHS=/opt/AdGuardHome

# Vaultwarden
./install-agent.sh root@192.168.1.32 \
    --set EXTRA_PATHS=/opt/vaultwarden/data

# Nextcloud — config only, not media files
./install-agent.sh www-data@192.168.1.33 \
    --set EXTRA_PATHS=/var/www/nextcloud/config

# Exclude sensitive paths from /etc/ backup
./install-agent.sh root@192.168.1.34 \
    --set GENERIC_EXCLUDE_PATHS=/etc/ssl/private
```

---

## SSH key management

There are two distinct SSH keys involved in the agent setup. It helps to keep them separate in your head:

| Key | Where it lives | What it does |
| :-- | :------------- | :----------- |
| **PABS private key** | Proxmox host — `/root/.ssh/id_ed25519_pabs_agent` | Used by PABS to authenticate *to* each VM during backup runs |
| **VM host key** | VM — registered in `/root/.ssh/pabs_known_hosts` on the host | Used by PABS to verify *it is talking to the right VM* (MITM protection) |

`install-agent.sh` handles the host key registration automatically. The public key deployment to the VM (Step 0 above) is a one-time manual step you do before running `install-agent.sh`.

### Adding the public key to a VM

```bash
# Using ssh-copy-id (requires password auth to be enabled on the VM)
ssh-copy-id -i /root/.ssh/id_ed25519_pabs_agent.pub root@<vm-ip>

# Without ssh-copy-id (works on any VM with SSH access)
cat /root/.ssh/id_ed25519_pabs_agent.pub | ssh root@<vm-ip> \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && tee -a ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### Host key registration

`install-agent.sh` registers each VM's SSH host key in `/root/.ssh/pabs_known_hosts` automatically. This file is used by `VM_AGENT_SSH_OPTS` with `StrictHostKeyChecking=yes`, protecting against MITM attacks on the backup channel.

If a VM's host key changes (e.g. after an OS reinstall), re-run `install-agent.sh` to update the registered key:

```bash
./install-agent.sh root@<vm-ip>
```

Inspect or remove a registered key manually:

```bash
ssh-keygen -F <vm-ip> -f /root/.ssh/pabs_known_hosts   # check if registered
ssh-keygen -R <vm-ip> -f /root/.ssh/pabs_known_hosts   # remove
```

The known hosts file has `chmod 600` applied by `install-agent.sh` on creation.

---

## Updating agents

Re-run `install-agent.sh` after a PABS upgrade to push the latest agent code to a VM:

```bash
./install-agent.sh root@<vm-ip>
```

It rsyncs the latest agent files and re-applies any `--set` values you pass. The agent version is recorded in `agent-meta.txt` inside each bundle.

---

## Bundle structure

Each bundle is a `.tar.zst` archive:

```
agent-meta.txt          PABS agent version, type, hostname, date
restore-notes.txt       Type-specific restore instructions (human-readable)
<type-specific files>   Compose files, HA snapshot, MC archives, /etc/, etc.
system-state/           OS info, package list, hostname
```

Inspect without extracting:

```bash
tar -I zstd -tf vm-agents/my-vm/pabs-bundle-my-vm-<date>.tar.zst
```

Read restore notes:

```bash
tar -I zstd -xOf vm-agents/my-vm/pabs-bundle-my-vm-<date>.tar.zst restore-notes.txt
```