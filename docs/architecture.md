# Architecture

Explains PABS internals: the data flow through a backup run, how integrity is guaranteed, and the reasoning behind key design decisions.

---

## Data flow

A complete backup run moves data through three locations:

```
1. Proxmox SSD (staging)              2. USB stick                    3. Offsite remote
/var/tmp/pabs-stage/                   /mnt/backup-usb/                gdrive:proxmox-backup/
└── .tmp-2026-06-01_03-00-00/         └── proxmox-backup/             └── 2026-06-01_03-00-00/
    ├── etc/                               ├── 2026-06-01_03-00-00/       (rclone-synced copy)
    ├── etc-pve.tar                        │   ├── etc/
    ├── vm-ct-definitions/                 │   ├── etc-pve.tar
    ├── system-state/                      │   ├── vm-ct-definitions/
    ├── vm-agents/                         │   ├── system-state/
    │   └── my-vm/                         │   ├── vm-agents/
    │       └── bundle.tar.zst             │   ├── MANIFEST.sha256
    ├── config.sh (secrets redacted)       │   ├── proxmox-restore.sh
    ├── backup.sh                          │   ├── README.txt
    └── MANIFEST.sha256                    │   └── DISASTER-RECOVERY.md
                                           └── backup.log
```

The staging directory always has a `.tmp-` prefix while in progress. The USB directory never gets its final name until the rename succeeds.

---

## Backup run sequence

```
backup.sh
│
├── source config.sh
├── source lib/core.sh         (logging, lock, trap, alerts)
├── source lib/offsite.sh      (rclone encryption, upload, retention pruning)
├── source lib/preflight.sh    (check functions)
├── source lib/sections.sh     (the 8 backup sections)
├── source helpers/manifest.sh
├── source helpers/output.sh
│
├── check_root                 must run as root
├── check_usb_mounted          USB at USB_MOUNT, UUID matches TARGET_UUID,
│                              write-test confirms not read-only
├── mkdir BACKUP_ROOT + LOCAL_STAGE_BASE
├── check_local_stage_space    estimates needed space + 20% margin; hard-fails if too low
├── check_usb_space            same estimate; auto-purges oldest backup if recoverable
├── mkdir STAGE_DIR
├── acquire_lock               flock on LOCK_FILE; aborts if already held
│
├── SECTION 1: section_proxmox_configs      /etc/pve/ tar, network, hosts, APT sources
├── SECTION 2: section_vm_ct_definitions    qm config + pct config exports; raw pmxcfs configs
├── SECTION 3: section_cron_jobs            /etc/crontab, /etc/cron.d/, user crontabs
├── SECTION 4: section_firewall             nftables, iptables, PVE firewall rules
├── SECTION 5: section_ssh_keys             /etc/ssh/, /root/.ssh/
├── SECTION 6: section_system_state         disk layout, kernel, ZFS pools, LVM VGs, packages
├── SECTION 7: section_custom_scripts       /usr/local/bin/, /root/scripts/,
│                                           config.sh (secrets redacted), backup.sh
├── SECTION 8: section_vm_agents            SSH into each VM, run agent, rsync bundle back
│
├── generate_and_verify_manifest   SHA256 of every staged file → MANIFEST.sha256
│                                  immediately re-verified on local SSD
│
│   ┌── detach ERR/EXIT trap ───────────────────────────────────────────────┐
│   │                                                                        │
├── atomic_commit               rsync STAGE_DIR → FINAL_DIR.tmp/           │
│   │                           then mv FINAL_DIR.tmp → FINAL_DIR           │
│   └── reattach trap ──────────────────────────────────────────────────────┘
│
├── generate_restore_script    proxmox-restore.sh (self-contained, baked hostname/version)
├── generate_readme            README.txt
├── generate_dr_playbook       DISASTER-RECOVERY.md (hostname/version/disk-layout-specific)
│
├── verify_manifest_on_usb     re-verify MANIFEST.sha256 on USB after transfer
├── offsite_sync               rclone to remote (if configured; non-fatal on failure)
├── rotate_old_backups         prune USB backups beyond KEEP_BACKUPS
│
├── release_lock
└── dispatch_alert "SUCCESS"
```

On any error, the `ERR EXIT` trap calls `_on_exit`, which cleans up `STAGE_DIR`, releases the lock, and sends a failure alert.

---

## Integrity guarantees

### Pre-commit manifest verification

After all sections complete on local SSD, `generate_and_verify_manifest` walks the staging directory, writes `MANIFEST.sha256` with the SHA256 of every file, and immediately re-reads and verifies all checksums.

This catches: filesystem corruption on the local SSD, files truncated during staging, and rsync transfers from agent VMs that produced a truncated bundle. If verification fails, the backup aborts before anything reaches USB.

### Atomic commit to USB

Data is written to `<FINAL_DIR>.tmp/` and renamed to `<FINAL_DIR>/` only after the full rsync completes:

- The USB never contains a directory that looks complete but is not.
- A power loss mid-transfer leaves a `.tmp/` directory, not a corrupt complete backup.
- `rotate_old_backups` and `pabs-status.sh` exclude `*.tmp` directories from their listings.

The trap is detached during the rename window so the cleanup handler does not delete the staging directory while the rename is in flight. `sync` is called before and after the rename to flush the kernel write-behind cache.

rsync uses `--whole-file` (no delta algorithm) because this is a local copy. `--inplace` is deliberately not used — it writes in-place and leaves a partial file indistinguishable from a complete one after power loss.

### Post-transfer manifest verification

After the USB rename, `verify_manifest_on_usb` re-verifies all checksums on the USB. This catches USB write errors, bad sectors, write-behind cache failures, and silent bit rot. Both verifications must pass before PABS proceeds to offsite sync or rotation.

### UUID targeting

`check_usb_mounted` reads the UUID of whatever is mounted at `USB_MOUNT` and compares it to `TARGET_UUID`. The backup aborts if they do not match. This prevents writing to the wrong drive if a second USB stick is connected and automounted at the same path.

---

## Space checks

Space estimation runs before staging begins. `_estimate_backup_kb` sums the disk usage of all paths that will be backed up, then adds 512 MB per configured VM agent as a conservative heuristic for bundle size. Both `check_local_stage_space` and `check_usb_space` apply a 20% margin on top.

If USB space is insufficient, PABS attempts auto-recovery: it purges the oldest backup and re-checks. It does not purge if only one backup remains. If still not enough space after purging, the backup aborts.

---

## Lock file

`LOCK_FILE` at `$LOCAL_STAGE_BASE/.backup.lock` prevents concurrent runs. Acquired at startup via `flock -n` (fails immediately if already held), released on exit via the `ERR EXIT` trap.

If a previous run was killed hard (SIGKILL, power loss mid-run), the lock file may remain. `pabs-status.sh` warns about a stale lock. Clear it manually:

```bash
rm /var/tmp/pabs-stage/.backup.lock
```

---

## Section 6 — system state detail

`section_system_state` captures a snapshot of the host's storage and package configuration. This data is reference material for rebuilding after total loss — it is not directly restored by `proxmox-restore.sh` (except for LVM configs).

| File | Command | Use |
| :--- | :------ | :-- |
| `system-state/dpkg-selections.txt` | `dpkg --get-selections` | Restore exact package set: `dpkg --set-selections < ... && apt-get dselect-upgrade` |
| `system-state/apt-holds.txt` | `apt-mark showhold` | Held packages reference |
| `system-state/apt-manual.txt` | `apt-mark showmanual` | Manually-installed packages reference |
| `system-state/proxmox-version.txt` | `pveversion --verbose` | Target version for reinstall |
| `system-state/kernel-version.txt` | `uname -r` | Kernel version reference |
| `system-state/disk-layout-lsblk.txt` | `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID` | Disk layout reference |
| `system-state/disk-layout-fdisk.txt` | `fdisk -l` | Partition table reference |
| `etc/fstab` | — | Mount configuration |
| `system-state/zfs-*/` | `zpool status/list`, `zfs list -t all`, per-pool `zpool get all` | ZFS reference (only if `BACKUP_ZFS=true`) |
| `system-state/lvm-pvs/vgs/lvs.txt` | `pvs/vgs/lvs` | LVM reference |
| `system-state/lvm-vg-<name>.cfg` | `vgcfgbackup` | Restorable with `vgcfgrestore -f lvm-vg-<name>.cfg <vg-name>` |

ZFS pool creation requires manual `zpool create` — these files are reference snapshots, not a pool restore mechanism.

---

## VM agent execution flow

```
Proxmox host (lib/sections.sh: section_vm_agents → _run_agent)
│
│  SSH connection
│  ssh -i $key $user@$ip "$agent_path --bundle-output $remote_bundle"
│
VM (vm-agent/agent.sh)
│
├── source /etc/pabs-agent/config    written by install-agent.sh
├── detect_type                      haos / docker / minecraft / generic
│                                    (first match wins; override with PABS_TYPE)
├── source types/<type>.sh           provides run_backup()
│
├── run_backup()
│   ├── create staging dir: /tmp/pabs-<label>-<date>/
│   ├── collect type-specific files
│   ├── write restore-notes.txt
│   └── tar -I zstd → /tmp/pabs-bundle-<label>-<date>.tar.zst
│
└── print bundle path to stdout
    ↓
Proxmox host (_run_agent continued)
│
├── parse agent stdout: file paths + PABS-NOTICE lines (v3.6 — items the
│   agent reports as NOT backed up; folded into the run summary and alert)
├── rsync bundle(s) from VM to local staging
├── cleanup /tmp/pabs-bundle-* on remote
├── check staging free space (abort if below VM_AGENT_STAGE_MIN_FREE_KB)
└── log bundle size, continue with next agent

(In-staging bundle pruning was removed in v3.6: STAGE_DIR is created fresh
each run, so there are never cross-run bundles to prune — the old prune could
only ever delete bundles the agent had just produced. Cross-run retention is
handled by rotate_old_backups on the USB side.)
```

The agent runs entirely inside the VM's `/tmp/` — it never writes to any persistent path on the VM, only reads. If the agent or the rsync fails, the error is logged and the backup continues with the next agent (non-fatal).

### Parallel agent execution

When `VM_AGENT_MAX_PARALLEL > 1`, agents are launched in the background with `_run_agent &`. A `_wait_one` loop enforces the parallelism cap by blocking until a slot is free before launching the next agent.

Each parallel worker writes to a private temp file. The shared log file (`$LOG`) is written via `tee -a`, which is atomic for short writes on Linux.

---

## Secret redaction

`config.sh` is copied into each backup as a restore reference. Secrets are redacted before writing — the original `config.sh` on the host is never modified.

Keys always redacted:

- `DISCORD_WEBHOOK`, `NOTIFY_EMAIL`, `PORTAINER_TOKEN`
- `RCLONE_ENCRYPTION_PASSWORD`, `RCLONE_ENCRYPTION_SALT`

Generic catch-all — any variable whose name contains `Password`, `Secret`, `_TOKEN`, `_KEY`, or `WEBHOOK` (case-insensitive for `Password`/`Secret`), with a value of at least 4 characters.

Redaction uses `sed` on a copy in the staging directory.

---

## Offsite encryption

When `RCLONE_ENCRYPTION_PASSWORD` is set, `_offsite_effective_remote` in `lib/offsite.sh` calls:

```bash
rclone config create pabs_crypt_runtime crypt \
    remote                    "$RCLONE_REMOTE" \
    filename_encryption       standard \
    directory_name_encryption true \
    password                  "$(rclone obscure "$RCLONE_ENCRYPTION_PASSWORD")" \
    password2                 "$(rclone obscure "${RCLONE_ENCRYPTION_SALT:-}")"
```

This creates or overwrites the named rclone remote `pabs_crypt_runtime` at runtime. Because rclone's crypt remote is deterministic — the same password and salt always produce the same key material (derived via scrypt) — overwriting the config each run is idempotent and existing offsite data remains readable.

`rclone obscure` converts the plaintext password to rclone's config storage format (simple XOR, not the encryption key itself). The actual AES-256 key is derived from the passwords using scrypt. All subsequent rclone operations use `pabs_crypt_runtime:`, including retention pruning, so they operate through the crypt layer and see decrypted directory names.

---

## Rotation logic

### USB rotation

Lists all `YYYY-MM-DD_*` directories under `BACKUP_ROOT` (excluding `*.tmp`), sorts oldest-first, and deletes until count ≤ `KEEP_BACKUPS`. Rotation happens after offsite sync, so USB always holds the freshest backup when offsite sync fires.

### Offsite rotation

Runs after each successful upload in two passes:

1. **Count pass** — marks oldest backups for deletion if count > `RCLONE_KEEP_MAX`.
2. **Storage pass** — iterates oldest-first, estimating remaining usage locally, until usage drops below `RCLONE_MAX_STORAGE_GB`.

`RCLONE_KEEP_MIN` is then applied as a safety gate: items are removed from the delete list (newest first) until survivors ≥ `RCLONE_KEEP_MIN`. Deletions use `rclone purge`. Failures on individual deletions are non-fatal.

---

## Alert flow

```
backup.sh completion
│
├── SUCCESS → dispatch_alert "SUCCESS — backup $DATE complete. Size: $BACKUP_SIZE."
│             + offsite success/failure sub-alerts
│
└── FAILURE → _on_exit trap fires
              dispatch_alert "FAILED with exit code $n. Review log: $LOG"

dispatch_alert (lib/core.sh)
│
├── Discord webhook (if DISCORD_WEBHOOK set)
│   curl POST with JSON payload (serialised via Python — no shell injection surface)
│   Non-fatal on curl failure
│
└── Email (if NOTIFY_EMAIL set, failure only)
    mail -s "PABS Alert: $(hostname)" $NOTIFY_EMAIL
    Requires a working MTA (postfix, nullmailer, etc.)
```

Discord fires on both success and failure. Email fires on failure only.

---

## Staging size estimates

Typical full backup with four VM agents:

| Component | Typical size |
| :-------- | :----------- |
| Proxmox `/etc/pve/` tar | 1–5 MB |
| Network + system state | < 1 MB |
| VM/CT config exports | < 1 MB |
| Docker agent bundle | 1–20 MB (compose files + small volumes) |
| HAOS agent bundle | 200 MB – 2 GB (full HA snapshot) |
| Minecraft agent bundle | 50–500 MB (weekly archive) |
| Generic agent bundle | 1–50 MB (`/etc/` + packages) |

Total typical range: **300 MB – 3 GB**. The space estimator uses 512 MB per configured agent as a conservative heuristic with a 20% margin on top.

---

## `pabs-status.sh` flow

`pabs-status.sh` is fully independent from the backup run. It sources only `config.sh` and `lib/usb_health.sh`, holds no lock, and makes no writes.

```
pabs-status.sh
│
├── source config.sh
├── source lib/usb_health.sh
│
├── Environment check        (running as root?)
├── USB / storage            (mounted, free space, backup count)
│
├── usb_health_check()       [lib/usb_health.sh]
│   ├── _usb_check_ro_remount    /proc/mounts: force-remounted read-only?
│   ├── _usb_check_dmesg         dmesg: I/O errors for this device?
│   ├── _usb_check_ext_superblock dumpe2fs: filesystem error counter (ext only)
│   └── _usb_check_smart         smartctl -H -d sat: overall health (if available)
│
├── Most recent backup       (date, size, manifest integrity re-verification)
├── Local stage space        (staging filesystem free GB)
├── VM agent connectivity    (SSH reachable for each VM_AGENTS entry)
├── Offsite sync             (remote reachable, backup count, GB used, retention)
└── Lock file                (stale lock warning if LOCK_FILE exists)
```

Exit codes: `0` = OK, `1` = error, `2` = warning.

---

## Setup wizard flow

`setup.sh` is an orchestrator that sources step modules. Writes to `config.sh` exclusively through `setup/config_editor.sh`. Never modifies library or agent code.

The `--step NAME` flag causes each step function to return immediately unless its name matches, allowing entry at any point without re-running earlier steps.

See [docs/setup-wizard.md](setup-wizard.md) for the full guide.
