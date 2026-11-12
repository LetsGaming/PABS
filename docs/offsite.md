# Offsite sync

PABS implements the 3-2-1 backup rule: 3 copies, 2 different media (local SSD staging + USB stick), 1 offsite (cloud or remote server).

The offsite sync runs automatically after each successful USB commit. It is non-fatal — if the remote is unreachable, the USB backup is always intact and you receive an alert.

---

## Prerequisites

```bash
apt install rclone
```

---

## Setting up a remote

Run the interactive wizard once to configure your provider:

```bash
rclone config
```

rclone supports 70+ storage backends. Common choices for a homelab:

| Provider | Free tier | Auth type | Notes |
| :------- | :-------- | :-------- | :---- |
| Google Drive | 15 GB | OAuth token | Needs browser for initial auth |
| OneDrive | 5 GB | OAuth token | Needs browser for initial auth |
| Backblaze B2 | 10 GB | API key | No token expiry issues |
| Hetzner Storage Box | — | SFTP | Good EU option; fixed pricing |
| Wasabi | — | S3-compatible | No egress fees |
| Local NAS / second server | — | SFTP or `local` | |

For Google Drive and OneDrive, initial auth requires a browser. On a headless Proxmox server, use `rclone authorize` on a desktop machine and paste the token. See the [rclone remote setup docs](https://rclone.org/remote_setup/) for the full procedure.

Verify the remote after configuration:

```bash
rclone lsd gdrive:
rclone mkdir gdrive:proxmox-backup
rclone lsd gdrive:proxmox-backup
```

---

## Basic configuration

> **Using the wizard?** Run `sudo bash /opt/pabs/setup.sh --step offsite` — it handles provider selection, rclone config verification, retention presets, and encryption in one session. The steps below are for manual configuration.

Minimum required in `config.sh`:

```bash
RCLONE_REMOTE="gdrive:proxmox-backup"
RCLONE_EXTRA_OPTS="--bwlimit 5M"    # optional: cap upload speed
```

---

## Retention

Without limits the remote grows indefinitely. Configure limits to fit within free-tier storage or cap costs.

```bash
RCLONE_KEEP_MIN=1           # never delete below this many offsite copies
RCLONE_KEEP_MAX=4           # prune oldest when count exceeds this
RCLONE_MAX_STORAGE_GB=0     # hard storage cap in GB (0 = unlimited)
```

After each successful upload, PABS lists all backup archives (`<DATE>.tar.zst[.gpg]`) on the remote. If count exceeds `RCLONE_KEEP_MAX`, the oldest backups are marked for deletion. If total usage exceeds `RCLONE_MAX_STORAGE_GB`, more are marked. `RCLONE_KEEP_MIN` is applied as a final safety gate — PABS never deletes the last N copies regardless of other limits.

**Free-tier sizing:**

```bash
# Google Drive (15 GB free)
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=4
RCLONE_MAX_STORAGE_GB=14

# OneDrive (5 GB free)
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=2
RCLONE_MAX_STORAGE_GB=4
```

---

## Encryption

By default, the remote receives the archive in plaintext. Anyone with access to the remote, including the provider, can read it. This includes sensitive content in VM agent bundles: `.env` files, SSH keys, API tokens.

PABS encrypts each archive with GPG (AES-256) before upload. The provider sees only an opaque `<DATE>.tar.zst.gpg` file. There are two methods.

### Symmetric (default)

Set a passphrase in `config.sh`:

```bash
RCLONE_ENCRYPTION_PASSWORD="a strong passphrase"
```

The same passphrase encrypts and decrypts, so it must be available on or near this host.

### Public key

The private key needed to decrypt never lives on this host. Import the recipient public key into root's keyring, then set:

```bash
gpg --import recipient-public-key.asc

RCLONE_ENCRYPTION_METHOD="gpg-key"
RCLONE_ENCRYPTION_RECIPIENT="backups@example.com"
```

### Keeping the passphrase safe

- Store it in a password manager (Bitwarden, 1Password, KeePass), separately from the USB stick.
- PABS automatically redacts it from the `config.sh` copy written to USB.
- The `DISASTER-RECOVERY.md` generated inside each backup contains the exact decrypt command for your method.

### Verifying encryption is active

```bash
rclone lsf gdrive:proxmox-backup
```

Archive names must end in `.tar.zst.gpg`. Names ending in `.tar.zst` mean the upload was not encrypted.

If `gpg` is missing, PABS logs a warning and uploads the archive unencrypted. If `gpg` fails, the upload is skipped.

### Decrypting

```bash
gpg -d <DATE>.tar.zst.gpg | tar --use-compress-program=zstd -xf -
```

---

## OAuth token refresh (Google Drive / OneDrive)

OAuth tokens can expire if the account password changes, the token has not been used for an extended period, or the provider revokes it for security reasons.

rclone handles token refresh automatically using the refresh token in its config file. If a token does expire, the offsite sync fails and you receive an alert. To re-authenticate:

```bash
rclone config reconnect gdrive:    # or onedrive:
```

This requires a browser. On a headless server, use `rclone authorize` on a desktop machine and paste the result.

The USB backup is always intact during a token failure — offsite sync issues do not affect the local backup.

To avoid token expiry entirely: Backblaze B2, Wasabi, and SFTP-based remotes use API keys and do not have this issue.

---

## What is and is not synced

**Synced:** one archive of the final backup directory (`BACKUP_ROOT/<date>/`), uploaded as `<date>.tar.zst` or `<date>.tar.zst.gpg`. It holds all PABS-staged data: Proxmox configs, VM/CT definitions, system state, VM agent bundles, the restore script, the DR playbook, and the SHA256 manifest.

**Not synced:**

- `backup.log` — the persistent log lives one level above per-backup directories.
- Old backup directories after pruning — PABS syncs only the new backup, then prunes old ones from the remote separately.

---

## Monitoring offsite status

```bash
/opt/pabs/pabs-status.sh
```

The offsite section reports: encryption status, retention policy, remote reachability, number of remote backups, total GB used, and warnings if below `RCLONE_KEEP_MIN` or over `RCLONE_MAX_STORAGE_GB`.
