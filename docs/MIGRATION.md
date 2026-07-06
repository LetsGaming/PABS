# MIGRATION — v3.5 → v3.6

v3.6 implements the findings of the July 2026 code audit. No files moved; the changes are behavioral.

## ⚠ Behavior change: Docker volumes are now backed up by default

Before v3.6 the Docker agent auto-included only named volumes **smaller than 5 MB** (`DOCKER_VOLUME_AUTO_THRESHOLD_MB`). Database and app-data volumes — the irreplaceable part of a Docker VM — were silently excluded while the run still reported SUCCESS.

**Now every named volume is captured by default.** Opt out per volume with `DOCKER_EXCLUDE_VOLUMES`, cap by size with `DOCKER_VOLUME_MAX_SIZE_MB` (0 = no cap), and force-include with `DOCKER_INCLUDE_VOLUMES`. Every skipped volume is reported in the log, in `restore-notes.txt`, in the final run summary, and in the alert.

Two consequences to plan for:

1. **Backups get bigger.** Check that your USB drive and `LOCAL_STAGE_BASE` have room, or exclude large rebuildable volumes (media caches, transcode dirs). The first run after updating shows every volume and its size in the log — a good moment to tune the excludes.
2. **If you explicitly set `DOCKER_VOLUME_AUTO_THRESHOLD_MB`** in an agent config, it keeps working: it is honored as `DOCKER_VOLUME_MAX_SIZE_MB` (identical skip-above-N behavior) with a deprecation warning. Rename it when convenient.

New: `DOCKER_QUIESCE_STACKS=true` stops the containers using a volume during its copy and restarts them after, for consistent database copies. Off by default; hot copies are marked per volume in `restore-notes.txt`.

## ⚠ Update order: host first, then agents

The agent protocol gained `PABS-NOTICE:` lines on stdout (how skipped items reach the host summary and alert). Hosts older than v3.6 treat every stdout line as a file path, so:

```bash
bash /opt/pabs/setup.sh --update     # 1. update the host
bash /opt/pabs/update-agents.sh      # 2. then push the agents
```

A v3.6 host works fine with older agents — there are just no notices yet until the agents are updated.

## Other changes

- **`VM_AGENT_KEEP_BUNDLES` removed.** Each dated backup is a full, independent snapshot with exactly one bundle per VM, so there was never anything to prune inside a run — the old in-staging prune could only ever delete bundles an agent had just produced. A leftover value in `config.sh` is ignored. Cross-run retention remains `KEEP_BACKUPS`.
- **USB health probe before every backup.** `backup.sh` now runs the always-reliable read-only signals (ro-remount, dmesg, ext superblock) before staging and alerts on failure. The backup still proceeds — a failing drive is a reason to attempt it *more* urgently. `pabs-status.sh` remains the full report including SMART.
- **`--verify` now covers the generated docs.** `proxmox-restore.sh`, `README.txt`, and `DISASTER-RECOVERY.md` are appended to `MANIFEST.sha256` after generation, so their corruption is detectable. Backups made before v3.6 keep their old manifests — the docs there remain uncovered.
- **Offsite archive is no longer built in `/tmp`** (tmpfs/RAM on many Proxmox installs). It is assembled under `LOCAL_STAGE_BASE`, overridable with the new `OFFSITE_TMP_DIR`.
- **Hardened guards:** the empty-staging "all sections failed" check can no longer be bypassed (`xargs -r`), and a Docker volume whose size cannot be measured is now always *included* instead of silently skipped.
- **Portainer token** is passed to `curl` via a 0600 config file instead of a `-H` argument, so it no longer appears in the process list.

---

# MIGRATION — v3.4 → v3.5

## What changed

Library code moved from root-level folders into `src/`:

| Before (≤ v3.4) | After (v3.5+) |
|---|---|
| `lib/` | `src/lib/` |
| `helpers/` | `src/helpers/` |
| `setup/` | `src/setup/` |
| `vm-agent/` | `src/vm-agent/` |

The five user-facing scripts in the project root are unchanged:
`backup.sh`, `pabs-status.sh`, `setup.sh`, `install-agent.sh`, `update-agents.sh`

Your `config.sh` is also unchanged — it lives in the root and is never touched by updates.

New file: `src/lib/host_health.sh` — adds Proxmox host drive health monitoring to
`pabs-status.sh` (SMART, NVMe health log, dmesg I/O errors, filesystem error counters).

---

## Updating

### Git install (recommended)

```bash
bash /opt/pabs/setup.sh --update
```

`--update` runs `git pull`, then checks whether any new config keys from
`config.template.sh` are missing from your `config.sh` and appends them with
their defaults. Your existing settings are never overwritten.

### Manual install (zip)

Download the latest release zip, extract it, then copy your existing `config.sh`
into the new directory before replacing the old install:

```bash
unzip pabs-v3.5.zip -d /opt/pabs-new
cp /opt/pabs/config.sh /opt/pabs-new/config.sh
mv /opt/pabs /opt/pabs-old
mv /opt/pabs-new /opt/pabs
```

Your cron job (`0 3 * * 0 /opt/pabs/backup.sh`) continues to work without changes.

---

## Verifying the migration

```bash
bash /opt/pabs/pabs-status.sh
```

You should now see a **Host Drive Health** section in the output, between
the USB health checks and the Local Stage section. If that section appears,
the migration succeeded.