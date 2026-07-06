# Configuration reference

`config.sh` is the only file you edit. All variables are documented here with type, default, and examples. The setup wizard writes most of these interactively — edit `config.sh` directly to fine-tune anything it does not cover.

> **Security note:** `config.sh` may contain webhook URLs, API tokens, and encryption passphrases. Restrict access after setup:
> ```bash
> chmod 600 /opt/pabs/config.sh
> ```
> Secrets are automatically redacted from the `config.sh` copy written into each backup. See [Secret redaction](#secret-redaction) for the full list.

---

## USB target

### `USB_MOUNT`

**Type:** path | **Default:** `"/mnt/backup-usb"`

Mount point of the USB stick. PABS refuses to run if nothing is mounted here.

```bash
USB_MOUNT="/mnt/backup-usb"
```

### `TARGET_UUID`

**Type:** string | **Default:** `""` (disabled)

UUID of the USB partition. When set, PABS verifies the partition mounted at `USB_MOUNT` matches this UUID before writing anything — preventing accidental writes to the wrong drive.

```bash
blkid /dev/sdX1    # get the UUID
```

```bash
TARGET_UUID=""                                       # disabled — any drive at USB_MOUNT is used
TARGET_UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"  # recommended
```

### `KEEP_BACKUPS`

**Type:** positive integer | **Default:** `4`

How many completed backups to keep on USB. Rotation runs after the new backup is successfully committed, so the current run is never deleted.

```bash
KEEP_BACKUPS=4    # ~1 month at weekly cadence
KEEP_BACKUPS=8    # ~2 months
```

### Filesystem requirement

PABS requires the USB partition to be formatted as **ext4**. exFAT, FAT32, and NTFS are not supported — rsync cannot create symlinks or set Unix permissions on those filesystems, so the transfer fails.

The setup wizard offers to format the drive. To format manually:

```bash
umount /dev/sdX1
mkfs.ext4 -L PABS-BACKUP -m 0 /dev/sdX1
tune2fs -c 0 -i 0 /dev/sdX1
```

See [USB filesystem requirements](usb-health.md#filesystem-requirements) for the full comparison.

---

## Local staging

All backup data is assembled on the Proxmox host's local disk first. The USB drive receives a single sequential write at the end. The staging directory must have enough free space to hold one complete backup.

### `LOCAL_STAGE_BASE`

**Type:** path | **Default:** `"/var/tmp/pabs-stage"`

Base directory for the temporary staging area. On Proxmox installs with a small root partition (common with LVM-thin or ZFS), point this at a larger volume:

```bash
LOCAL_STAGE_BASE="/var/tmp/pabs-stage"           # default — root LVM
LOCAL_STAGE_BASE="/rpool/data/pabs-stage"        # ZFS pool
LOCAL_STAGE_BASE="/mnt/pve/mystore/pabs-stage"   # Proxmox directory storage
```

Typical staging size: 300 MB – 3 GB depending on the number and type of VM agents. See [staging size estimates](architecture.md#staging-size-estimates).

### `LOCAL_STAGE_WARN_GB`

**Type:** integer (GB) | **Default:** `5`

PABS warns at startup if the staging filesystem is the same device as `/` and has less than this many GB free. Non-fatal — the backup continues, but you should address it before the next run.

```bash
LOCAL_STAGE_WARN_GB=5
```

---

## VM / LXC agent backups

### `VM_AGENTS`

**Type:** array | **Default:** `()` (empty)

Each entry is a space-separated string with four fields:

```
"label  ip-or-hostname  ssh-user  agent-path"
```

| Field | Description |
| :---- | :---------- |
| `label` | Unique short name. Used as the backup subfolder name and in log output. Lowercase with dashes. |
| `ip-or-hostname` | Address reachable from the Proxmox host. |
| `ssh-user` | SSH user on the VM. Typically `root` for LXCs or a dedicated `backup` user. |
| `agent-path` | Full path to `agent.sh` on the remote VM. Default install path: `/opt/pabs-agent/agent.sh`. |

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root      /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root      /opt/pabs-agent/agent.sh"
    "pihole-lxc   192.168.1.30   root      /opt/pabs-agent/agent.sh"
    "mc-server    192.168.1.40   alice     /opt/pabs-agent/agent.sh"
)

VM_AGENTS=()   # skip all VM agent backups
```

### `VM_SSH_KEY`

**Type:** path | **Default:** `""` (use host default key)

Shared SSH private key for all VM agent connections. A dedicated key is recommended so rotating the host's default key does not break agent backups.

Before setting this, the corresponding public key must be deployed to every VM that PABS will back up. PABS cannot do this for you — it needs SSH access to deploy itself in the first place.

```bash
# 1. Generate the key on the Proxmox host
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_pabs_agent -N ""

# 2. Copy the public key to each VM (repeat for every VM)
ssh-copy-id -i /root/.ssh/id_ed25519_pabs_agent.pub root@<vm-ip>

# 3. Verify access
ssh -i /root/.ssh/id_ed25519_pabs_agent root@<vm-ip> "echo OK"

# 4. Set in config.sh
VM_SSH_KEY="/root/.ssh/id_ed25519_pabs_agent"
```

If you skip the dedicated key, PABS uses the host's default key (`~/.ssh/id_*`). This works but is not recommended for long-term use.

### Per-VM SSH key override

Format: `VM_SSH_KEY_<label>` with dashes replaced by underscores. Takes precedence over `VM_SSH_KEY` for that VM:

```bash
VM_SSH_KEY_docker_vm="/root/.ssh/id_ed25519_dockervm"
VM_SSH_KEY_pihole_lxc="/root/.ssh/id_ed25519_pihole"
```

### `VM_AGENT_KEEP_BUNDLES` *(removed in v3.6)*

This option no longer exists. Each dated backup is a full, independent snapshot containing exactly one bundle per VM, so there was never anything to prune inside a run — the old prune could only ever delete bundles an agent had just produced. Cross-run retention is handled by `KEEP_BACKUPS`. A leftover `VM_AGENT_KEEP_BUNDLES` value in an existing `config.sh` is harmless and simply ignored.

### `VM_AGENT_MAX_PARALLEL`

**Type:** integer | **Default:** `1` (sequential)

Maximum number of VM agents to run simultaneously.

```bash
VM_AGENT_MAX_PARALLEL=1    # sequential (default)
VM_AGENT_MAX_PARALLEL=3    # up to 3 agents at once
```

### `VM_AGENT_STAGE_MIN_FREE_KB`

**Type:** integer (KB) | **Default:** `524288` (512 MB)

Minimum free space on local staging after each agent bundle is pulled. If breached, the agent section aborts immediately.

```bash
VM_AGENT_STAGE_MIN_FREE_KB=524288    # 512 MB
VM_AGENT_STAGE_MIN_FREE_KB=1048576   # 1 GB
```

### `VM_AGENT_SSH_OPTS`

**Type:** array | **Default:** (see below)

SSH options applied to every VM agent connection during backup runs.

```bash
VM_AGENT_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15
                   -o StrictHostKeyChecking=yes
                   -o UserKnownHostsFile=/root/.ssh/pabs_known_hosts)
```

`StrictHostKeyChecking=yes` requires host keys to be pre-registered via `install-agent.sh`. Do not change to `accept-new` in production — it removes MITM protection on the backup channel.

---

## Notifications

### `DISCORD_WEBHOOK`

**Type:** string | **Default:** `""` (disabled)

Discord webhook URL. Alerts fire on: backup success, backup failure, low USB space with auto-purge, offsite sync success/failure.

Create a webhook at **Server Settings → Integrations → Webhooks**.

```bash
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
```

Webhook payloads are JSON-serialised via Python (`json.dumps`) — not shell-interpolated — so message content containing quotes, tabs, or non-ASCII never breaks the payload.

### `NOTIFY_EMAIL`

**Type:** string | **Default:** `""` (disabled)

Email address for failure alerts. Requires a working MTA. Fires on failure only.

```bash
apt install mailutils    # plus postfix or nullmailer

NOTIFY_EMAIL="admin@example.com"
```

---

## Optional features

### `BACKUP_ZFS`

**Type:** `"true"` | `"false"` | **Default:** `"true"`

Exports ZFS pool and dataset layout into `system-state/`. Enabled by default because ZFS is the standard Proxmox storage backend since PVE 6.x. Captures `zpool status`, `zpool list -v`, `zfs list -t all`, and per-pool property exports (reference only — ZFS pool creation requires manual `zpool create`).

```bash
BACKUP_ZFS="true"
BACKUP_ZFS="false"   # non-ZFS setups only
```

---

## Offsite sync

The offsite sync runs after each successful USB commit. Failure is non-fatal — the USB backup is always intact regardless.

### `RCLONE_REMOTE`

**Type:** string | **Default:** `""` (disabled)

rclone remote name and path. Configure the base remote with `rclone config`. PABS handles encryption on top transparently.

```bash
RCLONE_REMOTE=""                               # disabled
RCLONE_REMOTE="gdrive:proxmox-backup"          # Google Drive (15 GB free)
RCLONE_REMOTE="onedrive:proxmox-backup"        # OneDrive (5 GB free)
RCLONE_REMOTE="backblaze:bucket/proxmox"       # Backblaze B2
RCLONE_REMOTE="hetzner-sftp:backup/proxmox"   # Hetzner Storage Box
```

### `RCLONE_EXTRA_OPTS`

**Type:** string | **Default:** `"--bwlimit 5M"`

Extra flags passed to every `rclone sync` call. Word-split by the shell before use — do not include glob characters (e.g. `--filter='*.bak'`), as they undergo filename expansion.

```bash
RCLONE_EXTRA_OPTS="--bwlimit 5M"               # cap upload at 5 MB/s
RCLONE_EXTRA_OPTS="--bwlimit 2M --transfers 1"
RCLONE_EXTRA_OPTS=""                            # no limits
```

### `OFFSITE_TMP_DIR`

**Type:** path | **Default:** empty (uses `LOCAL_STAGE_BASE`)

Where the offsite archive is assembled before upload. Deliberately **not** `/tmp`: on many Proxmox installs `/tmp` is tmpfs (RAM-backed), and an agent-heavy archive could consume gigabytes of RAM or fail outright. Set this only if you want the scratch space on a different disk-backed path than the staging area.

```bash
OFFSITE_TMP_DIR=""                          # default: build under LOCAL_STAGE_BASE
OFFSITE_TMP_DIR="/mnt/pve/mystore/scratch"  # dedicated scratch volume
```

### `RCLONE_KEEP_MIN`

**Type:** positive integer | **Default:** `1`

Minimum number of offsite backups to always retain. PABS never deletes below this count regardless of `RCLONE_KEEP_MAX` or `RCLONE_MAX_STORAGE_GB`.

```bash
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MIN=2
```

### `RCLONE_KEEP_MAX`

**Type:** integer | **Default:** `4`

Maximum number of offsite backups to keep. Oldest are pruned after a new upload exceeds this count. Set to `0` to disable count-based pruning.

```bash
RCLONE_KEEP_MAX=4
RCLONE_KEEP_MAX=0    # no count limit — rely on RCLONE_MAX_STORAGE_GB only
```

### `RCLONE_MAX_STORAGE_GB`

**Type:** integer (GB) | **Default:** `0` (unlimited)

Hard cap on total remote storage used by PABS. Oldest backups are pruned to stay under this limit, subject to `RCLONE_KEEP_MIN`.

```bash
RCLONE_MAX_STORAGE_GB=0     # unlimited (default)
RCLONE_MAX_STORAGE_GB=4     # fit within OneDrive's 5 GB free tier
RCLONE_MAX_STORAGE_GB=14    # fit within Google Drive's 15 GB free tier
```

### `RCLONE_ENCRYPTION_PASSWORD`

**Type:** string | **Default:** `""` (disabled)

Main passphrase for offsite encryption. When set, PABS wraps `RCLONE_REMOTE` with rclone's `crypt` remote at runtime. The provider sees only AES-256 encrypted blobs; filenames are encrypted too.

Store this passphrase in a password manager, separately from the USB stick. It is required to decrypt the offsite data and is automatically redacted from the `config.sh` copy written to USB.

```bash
RCLONE_ENCRYPTION_PASSWORD=""                    # disabled
RCLONE_ENCRYPTION_PASSWORD="a strong passphrase"
```

### `RCLONE_ENCRYPTION_SALT`

**Type:** string | **Default:** `""` (disabled)

Optional second passphrase (rclone `password2`). Protects against rainbow-table attacks on the main password. Recommended if your main password is short or memorable. Also redacted from the USB copy.

```bash
RCLONE_ENCRYPTION_SALT=""
RCLONE_ENCRYPTION_SALT="another passphrase"
```

### Free-tier configuration examples

**Google Drive (15 GB free)**

```bash
RCLONE_REMOTE="gdrive:proxmox-backup"
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=4
RCLONE_MAX_STORAGE_GB=14
RCLONE_ENCRYPTION_PASSWORD="your passphrase"
```

**OneDrive (5 GB free)**

```bash
RCLONE_REMOTE="onedrive:proxmox-backup"
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=2
RCLONE_MAX_STORAGE_GB=4
RCLONE_ENCRYPTION_PASSWORD="your passphrase"
```

---

## Secret redaction

`config.sh` is copied into every backup for restore reference. The following values are redacted (replaced with empty strings) before writing to USB — the original `config.sh` on the host is never modified.

Keys always redacted regardless of value length:

- `DISCORD_WEBHOOK`
- `NOTIFY_EMAIL`
- `PORTAINER_TOKEN`
- `RCLONE_ENCRYPTION_PASSWORD`
- `RCLONE_ENCRYPTION_SALT`

Generic catch-all — any variable name containing `Password`, `Secret`, `_TOKEN`, `_KEY`, or `WEBHOOK` (case-insensitive for `Password`/`Secret`) with a value of at least 4 characters.

---

## Internal variables

Derived automatically. Marked `readonly` after sourcing. Do not edit.

| Variable | Value |
| :------- | :---- |
| `SCRIPT_VERSION` | Current PABS version string |
| `DATE` | Timestamp for this run (`YYYY-MM-DD_HH-MM-SS`) |
| `BACKUP_ROOT` | `$USB_MOUNT/proxmox-backup/` |
| `STAGE_DIR` | `$LOCAL_STAGE_BASE/.tmp-$DATE/` |
| `FINAL_DIR` | `$BACKUP_ROOT/$DATE/` |
| `LOG` | `$BACKUP_ROOT/backup.log` |
| `LOCK_FILE` | `$LOCAL_STAGE_BASE/.backup.lock` |
| `WARNINGS` | Warning counter (initialised to 0) |
| `ERRORS` | Error counter (initialised to 0) |
