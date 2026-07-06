# USB drive health checks

`pabs-status.sh` runs a passive drive health assessment automatically whenever the USB stick is mounted. It does not write to the drive, does not scan all data, and completes in seconds.

Since v3.6, `backup.sh` additionally runs a quick probe of the always-reliable signals (read-only remount, kernel I/O errors, ext superblock error counter) **before every backup**, so a failing drive is flagged on the path that runs on a schedule — not only when someone remembers to run `pabs-status.sh`. Probe failures raise a warning and a Discord/mail alert; the backup still proceeds, because a failing drive is a reason to attempt the backup *more* urgently, not less. SMART is deliberately left out of the pre-backup probe (slow and unreliable through many USB bridges) — `pabs-status.sh` remains the full report.

```bash
sudo bash /opt/pabs/pabs-status.sh
```

Health output appears under `--- USB Drive Health ---`.

---

## Filesystem requirements

PABS requires **ext4** on the USB drive. The setup wizard offers to format the drive before first use.

| Filesystem | Supported | Reason |
| :--------- | :-------- | :----- |
| ext4       | ✓ Yes     | Full support: symlinks, Unix permissions, health checks |
| ext3       | ✓ Yes     | Supported, but ext4 is preferred |
| ext2       | ⚠ Partial | No journalling — power loss during write can corrupt the filesystem |
| exFAT      | ✗ No      | No symlink support, no Unix permissions — rsync transfer will fail |
| FAT32      | ✗ No      | Same as exFAT, plus 4 GB file size limit |
| NTFS       | ✗ No      | Requires `ntfs-3g`; no reliable symlink support in practice |

**Why symlinks matter:** the staging tree contains symlinks captured from `/etc/pve` (pmxcfs FUSE artefacts) and `/root/.ssh/authorized_keys`. These must be stored faithfully on the USB so manifest verification and the restore script work correctly. exFAT and FAT32 cannot store symlinks at all — rsync exits with an error when it tries to create them.

**Why Unix permissions matter:** the `MANIFEST.sha256` verification, SSH key restore (`chmod 700`/`600`), and crontab restore all depend on preserved ownership and mode bits. FAT-family filesystems have no concept of these.

**Why health checks need ext4:** Signal 3 reads the ext4 superblock error counter via `dumpe2fs`. This is the most reliable early-warning indicator of flash wear. It is silently skipped on non-ext filesystems.

### Formatting a drive as ext4

Run the setup wizard — it offers to format before mounting:

```bash
bash /opt/pabs/setup.sh --step usb
```

Or format manually:

```bash
# WARNING: erases all data on the partition
umount /dev/sdX1
mkfs.ext4 -L PABS-BACKUP -m 0 /dev/sdX1      # -m 0: no reserved blocks (backup drive, not OS)
tune2fs -c 0 -i 0 /dev/sdX1                  # disable automatic fsck by mount count
```

After formatting, re-run `setup.sh --step usb` to update the UUID and fstab entry.

---

## What is checked

Four independent signal layers are checked. Each produces its own pass/warn/fail result.

### Signal 1 — Kernel I/O error log

Scans `dmesg` for I/O errors, SCSI errors, and USB device resets attributed to the drive since the last boot. The Linux kernel logs these unconditionally at the block layer — they cannot be hidden by a failing drive or a USB bridge chip.

Patterns detected:

- `I/O error, dev sdb` — generic block layer error
- `blk_update_request: I/O error` — newer kernel format
- `EXT4-fs error (device sdb1)` — filesystem-level error
- `reset high-speed USB device` — USB device reset, often a precursor to failure
- SCSI error return codes from the USB bridge

Any hit is a strong indicator of hardware failure and is reported as a hard failure.

### Signal 2 — Read-only remount detection

When the kernel detects unrecoverable write errors, it force-remounts the filesystem read-only. PABS detects this by checking `/proc/mounts` for the `ro` flag on the USB mount point.

If this has happened, backups cannot be written and the drive is effectively dead. Reported as a hard failure with an immediate "replace the drive" message.

### Signal 3 — Filesystem error counter (ext2/3/4 only)

Reads the ext superblock via `dumpe2fs -h` (superblock only — fast, no full disk scan). The `FS Error count` field is incremented by the kernel's `ext4_error()` handler whenever it detects corruption or I/O failures at the filesystem layer.

Also reports: mount count since last `fsck`, maximum mount count threshold, and date of last filesystem check.

Silently skipped for FAT/exFAT/NTFS filesystems.

### Signal 4 — SMART overall health

Calls `smartctl -H -d sat` (SCSI-ATA Translation pass-through). Only the single overall `PASSED`/`FAILED` line is checked — individual attribute values are deliberately ignored because USB bridge chips frequently return fabricated zeros for them.

| Result | Meaning |
| :----- | :------ |
| `PASSED` | Drive's self-assessment reports no imminent failure |
| `FAILED` | Drive is reporting imminent failure — replace immediately |
| Unavailable | Bridge chip does not support SMART (normal for many USB sticks) |

SMART unavailability is reported as an informational note, not a failure.

---

## Final verdict

| Failing signals | Verdict |
| :-------------- | :------ |
| 0 | ✓ No problems detected |
| 1 | ⚠ One signal requires attention — consider replacing the drive |
| 2+ | ✗ Multiple signals indicate drive problems — replace the drive |

A single failing signal is a warning, not an emergency, because false positives can occur (a USB reset from a loose cable, a missed fsck on a healthy drive). Two or more failing signals from independent layers means something is genuinely wrong.

---

## Why a health percentage is not shown

USB flash sticks track wear-level counters internally, but expose them through vendor-specific SMART attributes (e.g. 173, 177, 202) with non-standardised scales. Most consumer USB bridges either block SMART entirely or return fabricated zeros. A percentage derived from these would be meaningless or actively misleading.

USB-attached HDDs have better-standardised SMART attributes, but USB bridge pass-through is unreliable enough that the result cannot be trusted. HDDs connected via SATA should use `smartd` for continuous monitoring instead.

What PABS checks — kernel I/O errors, forced read-only remounts, filesystem error counters, and SMART overall health — are the signals that are actually reliable through a USB connection.

---

## Example output

**Healthy drive:**

```
--- USB Drive Health ---
  ✓  Device: /dev/sdb1 (disk: /dev/sdb)
  ✓  Filesystem: mounted read-write (no forced remount)
  ✓  Kernel log: no I/O errors for sdb since last boot
  ✓  Filesystem errors: ext4 superblock reports 0 errors (mounts: 12/50, last check: Thu May 1 2026)
  ✓  SMART: overall health PASSED

  ✓  Drive health verdict: no problems detected
```

**Drive with kernel errors:**

```
--- USB Drive Health ---
  ✓  Device: /dev/sdb1 (disk: /dev/sdb)
  ✓  Filesystem: mounted read-write (no forced remount)
  ✗  Kernel log: 3 I/O error(s) for sdb since last boot
        [123456.789] blk_update_request: I/O error, dev sdb, sector 1234567890
        [123457.012] EXT4-fs error (device sdb1): ...
  ✗      This is a strong indicator of hardware failure — replace the drive
  ✓  Filesystem errors: ext4 superblock reports 0 errors (mounts: 38/50, last check: ...)
  ✓  SMART: overall health PASSED

  ⚠  Drive health verdict: 1 signal requires attention (see above)
  ⚠      Consider replacing the drive and verifying your latest backup
```

**Unsupported SMART bridge (normal):**

```
  ✓  SMART: not supported by this USB bridge (normal for many USB sticks)
```

---

## Dependencies

| Tool | Package | Required for |
| :--- | :------ | :----------- |
| `dmesg` | `util-linux` (always present) | Kernel error log |
| `findmnt` | `util-linux` (always present) | Device resolution, ro detection |
| `dumpe2fs` | `e2fsprogs` (usually present) | ext2/3/4 superblock check |
| `smartctl` | `smartmontools` | SMART health check |

Install optional tools:

```bash
apt install e2fsprogs smartmontools
```

Both are optional — their checks are skipped with an informational note if the tool is not installed.

---

## Responding to health warnings

**One failing signal** — run a backup immediately if one is not recent. Verify offsite sync is working. Plan to replace the drive within weeks.

**Two or more failing signals** — treat as urgent. Verify the most recent backup is intact (`sha256sum --check MANIFEST.sha256`). Procure a replacement drive. Do not wait for the next scheduled run.

**Read-only remount** — the drive cannot accept new backups. Replace immediately. Restore from offsite if the USB is unreadable.

---

## Integration with backup decisions

The health check is intentionally read-only and non-blocking. A failing health check does not prevent a backup from running — PABS runs the backup regardless and lets you decide what to do. This ensures you always have the freshest possible backup even on a degraded drive.
