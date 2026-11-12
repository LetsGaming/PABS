# Setup wizard

`setup.sh` is an interactive wizard that runs the complete PABS setup in one session. Start here for new installations. Safe to re-run at any time to update settings or add new VMs.

```bash
sudo bash /opt/pabs/setup.sh
```

---

## Usage

```bash
# Full wizard — all steps in order
sudo bash /opt/pabs/setup.sh

# Jump directly to one step
sudo bash /opt/pabs/setup.sh --step usb
sudo bash /opt/pabs/setup.sh --step notifications
sudo bash /opt/pabs/setup.sh --step agents
sudo bash /opt/pabs/setup.sh --step offsite
sudo bash /opt/pabs/setup.sh --step cron
sudo bash /opt/pabs/setup.sh --step run

# Non-interactive — accept all defaults (CI / automation)
sudo bash /opt/pabs/setup.sh --yes
```

Available steps: `deps` | `usb` | `notifications` | `agents` | `offsite` | `cron` | `run`

---

## What each step does

The wizard sources modular step files and writes to `config.sh` exclusively through `setup/config_editor.sh`. It never modifies library or agent code. Every change is visible in `config.sh` afterwards.

### Step 1 — Dependencies (`deps`)

Checks for required binaries: `rsync`, `zstd`, `tar`, `gzip`, `curl`, `python3`, `ssh`. Offers to install any missing via `apt`. Also checks optional packages:

- `rclone` — needed only for offsite sync; `n` is the default answer
- `mailutils` — needed only for email failure alerts; `n` is the default

### Step 2 — USB backup target (`usb`)

Displays `lsblk` output to help identify the device, then configures:

- **USB mount point** — defaults to `/mnt/backup-usb`, creates the directory if absent
- **UUID** — auto-detected if the drive is already mounted; offers to mount a device if not. UUID targeting prevents PABS from writing to the wrong drive.
- **fstab entry** — optionally adds an auto-mount entry to `/etc/fstab`
- **`KEEP_BACKUPS`** — how many weekly backups to retain before rotating
- **`LOCAL_STAGE_BASE`** — staging directory on local disk. Warns if the root partition is small and suggests ZFS or Proxmox directory storage alternatives

### Step 3 — Notifications (`notifications`)

- **Discord** — prompts for a webhook URL and sends a live test message before saving.
- **Email** — shown only if `mail` or `sendmail` is installed. Optionally sends a test email.

Both are optional and `n`-by-default.

### Step 4 — VM / LXC agents (`agents`)

Handles SSH key setup and VM deployment:

**1. SSH key** — checks for an existing dedicated key at `/root/.ssh/id_ed25519_pabs_agent`, offers to reuse or generate a new one. The wizard generates the key but cannot deploy it to your VMs — you must copy the public key to each VM before the wizard runs `install-agent.sh`:

```bash
ssh-copy-id -i /root/.ssh/id_ed25519_pabs_agent.pub root@<vm-ip>
```

The wizard will prompt you to do this and pause before proceeding.

**2. Per-VM loop** — for each VM, asks for IP, SSH user, and label, then presents a type selector:

| Choice | Type | Extra questions |
| :----- | :--- | :-------------- |
| 1 | Docker | Manager (`auto`/`dockge`/`portainer`), Dockge stacks dir, Portainer URL + token |
| 2 | Home Assistant OS | SSH add-on port (default: 22222), backup type (`full`/`partial`), HA snapshot encryption, retention count |
| 3 | Minecraft | System username, `MINECRAFT_BASE`, weekly/daily retention |
| 4 | Generic | Extra paths to include |
| 5 | Auto-detect | No extra questions |

All answers are passed as `--set` flags to `install-agent.sh`. On success, the VM entry is appended to `VM_AGENTS` in `config.sh` automatically.

**3. Parallelism** — if more than one agent is configured, asks for `VM_AGENT_MAX_PARALLEL`.

### Step 5 — Offsite sync (`offsite`)

Provider selection with free-tier sizes shown. Sets smart retention defaults per provider:

| Provider | `KEEP_MIN` | `KEEP_MAX` | `MAX_STORAGE_GB` |
| :------- | :--------: | :--------: | :--------------: |
| Google Drive (15 GB free) | 1 | 4 | 14 |
| OneDrive (5 GB free) | 1 | 2 | 4 |
| Backblaze / custom | 1 | 4 | 0 (unlimited) |

Also handles:

- **rclone remote verification** — checks if the remote is configured, offers to open `rclone config` inline if not. Includes instructions for headless OAuth setup.
- **Connectivity test** — verifies the remote is reachable before saving.
- **Bandwidth limit** — sets `RCLONE_EXTRA_OPTS` (default: `--bwlimit 5M`).
- **Encryption** — asks for a passphrase and confirms it. Shows a warning to store the passphrase before proceeding. The passphrase is redacted from the `config.sh` copy written to USB.

### Step 6 — Cron schedule (`cron`)

Four presets plus a custom expression option. Writes to root's crontab, removing any existing PABS entry first.

| Preset | Expression | Schedule |
| :----- | :--------- | :------- |
| 1 (default) | `0 3 * * 0` | Weekly, Sunday at 03:00 |
| 2 | `0 2 * * 6` | Weekly, Saturday at 02:00 |
| 3 | `0 3 * * *` | Daily at 03:00 |
| 4 | `0 3 1 * *` | Monthly, 1st of month at 03:00 |
| 5 | custom | Enter any cron expression |

### Step 7 — First backup run (`run`)

Shows a configuration summary table, runs `pabs-status.sh` as a pre-flight check, then offers:

1. **Dry run** — verifies everything without writing data; offers a full backup if it passes
2. **Full backup** — runs `backup.sh` immediately with output shown inline
3. **Skip** — exits; backup runs on the cron schedule

---

## Re-running the wizard

The wizard reads existing values before prompting. If a value is already configured, it shows the current value and asks whether to update it.

Common re-run scenarios:

```bash
# Add a new VM agent
sudo bash /opt/pabs/setup.sh --step agents

# Update the offsite encryption password
sudo bash /opt/pabs/setup.sh --step offsite

# Change the backup schedule
sudo bash /opt/pabs/setup.sh --step cron

# Re-check after a hardware change
sudo bash /opt/pabs/setup.sh --step run
```

---

## Non-interactive mode (`--yes`)

Accepts all defaults without prompting. Intended for automated testing or scripted re-deployments. Secrets (`RCLONE_ENCRYPTION_PASSWORD`, `HAOS_BACKUP_PASSWORD`) are never auto-filled in `--yes` mode — set them interactively or write to `config.sh` directly.

```bash
sudo bash /opt/pabs/setup.sh --yes
```

---

## File structure

`setup.sh` is a thin orchestrator (~120 lines). Each step is isolated in its own file.

```
setup.sh
setup/
├── ui.sh                   Terminal output helpers (_ok, _warn, _ask, _ask_yn, ...)
├── config_editor.sh        config.sh read/write (_cfg_get, _cfg_set, _cfg_set_raw, ...)
└── steps/
    ├── welcome.sh          ASCII banner and intro screen
    ├── deps.sh             Dependency checks and apt installs
    ├── usb.sh              USB target, UUID, fstab, retention, staging directory
    ├── notifications.sh    Discord webhook test, email setup
    ├── agents.sh           SSH key, per-VM loop, type questionnaires, install-agent.sh
    ├── offsite.sh          Provider picker, rclone config, bandwidth, retention, encryption
    ├── cron.sh             Schedule presets and crontab write
    └── run.sh              Config summary, health check, dry-run / full-run
```

### `setup/ui.sh`

Terminal primitives shared across every step. Color detection is automatic (disabled in pipes or CI). Functions: `_header`, `_step`, `_ok`, `_warn`, `_info`, `_err`, `_dim`, `_die`, `_ask`, `_ask_yn`, `_ask_secret`, `_pause`.

### `setup/config_editor.sh`

All `config.sh` read/write operations. Step files call these functions — no raw `sed` in step files:

| Function | Behaviour |
| :------- | :-------- |
| `_cfg_get KEY` | Reads the active (uncommented) value; returns empty if missing or commented out |
| `_cfg_set KEY VALUE` | Sets a quoted string value; replaces an active assignment, uncomments a commented key, or appends before the internal vars sentinel |
| `_cfg_set_raw KEY VALUE` | Like `_cfg_set` but without quotes — for integers and booleans |
| `_cfg_append_vm_agent ENTRY` | Appends one agent entry to `VM_AGENTS`, handling both empty and populated array cases |

### Adding a new agent type

Each VM type's configuration questions are isolated in a dedicated function using Bash namerefs. Adding a new type requires one function and one `case` branch:

```bash
_agent_type_mytype() {
    # shellcheck disable=SC2178
    local -n _flags=$1          # nameref to caller's set_flags array
    _flags+=(--set "PABS_TYPE=mytype")
    local myval
    myval=$(_ask "Some setting" "default")
    [[ "$myval" != "default" ]] && _flags+=(--set "MY_VAR=$myval")
}
```
