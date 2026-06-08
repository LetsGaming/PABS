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