# Testing

PABS ships with an automated test suite in `tests/pabs.bats` using [bats-core](https://github.com/bats-core/bats-core).

Tests run without root, without a real USB drive, and without a Proxmox environment. Each test sources only the function under test with a minimal stub environment, isolating individual functions from SSH, Proxmox APIs, and hardware state.

---

## Prerequisites

Install bats-core (not in the default Debian repos):

```bash
git clone https://github.com/bats-core/bats-core /opt/bats
/opt/bats/install.sh /usr/local
```

No other test dependencies. The suite stubs out all external calls inline.

---

## Running the tests

```bash
# Run all tests
bats tests/pabs.bats

# TAP output (for CI pipelines)
bats tests/pabs.bats --tap

# Run a subset by name pattern
bats tests/pabs.bats --filter rotate      # rotation tests only
bats tests/pabs.bats --filter manifest    # manifest tests only
bats tests/pabs.bats --filter log         # log counter tests only
bats tests/pabs.bats --filter docker      # docker volume policy tests only
```

---

## What is tested

### `rotate_old_backups` — 6 tests

Covers the rotation logic in `helpers/manifest.sh`:

| Test | What it checks |
| :--- | :------------- |
| Removes excess, keeps newest | With 5 backups and `KEEP_BACKUPS=3`, only 3 remain |
| Removes oldest first | Oldest directories (by sort order) are deleted before newer ones |
| Does nothing when under limit | No deletions when existing count ≤ `KEEP_BACKUPS` |
| Empty backup dir | No error when `BACKUP_ROOT` exists but is empty |
| `KEEP_BACKUPS=0` guard | Skips rotation and increments `WARNINGS` instead of deleting everything |
| `KEEP_BACKUPS` non-integer | Invalid values (`abc`, `-1`) skip rotation and warn rather than crash or delete |

The `KEEP_BACKUPS=0` and non-integer guards exist because `head -n -0` has undefined behaviour in some GNU coreutils versions and would mark all backups for deletion.

### Manifest generation and verification — 3 tests

Covers `generate_and_verify_manifest` in `helpers/manifest.sh`:

| Test | What it checks |
| :--- | :------------- |
| Creates correct checksums | `MANIFEST.sha256` is written and passes `sha256sum --check` |
| Does not include itself | `MANIFEST.sha256` is excluded from its own checksum list |
| Handles filenames with spaces | `find -print0 \| xargs -0` pipeline handles spaces without splitting |

### Manifest hardening (v3.6) — 4 tests

Covers the audit fixes in `src/helpers/manifest.sh`:

| Test | What it checks |
| :--- | :------------- |
| Empty staging aborts | An empty `STAGE_DIR` triggers the "all sections failed" `die` instead of fabricating a 1-line manifest for stdin (`xargs -r` guard) |
| Dirs-only staging aborts | Same guard fires when staging contains directories but zero files |
| Generated docs become verifiable | `extend_manifest_on_usb` appends `proxmox-restore.sh` / `README.txt` / `DISASTER-RECOVERY.md` so `--verify` detects their corruption |
| Missing doc is non-fatal | A doc that failed to generate warns without failing the backup |

### Docker volume capture policy (v3.6) — 10 tests

Covers `_volume_decision`, `_backup_named_volume`, and `_backup_volumes` in `src/vm-agent/types/docker.sh`, with the `docker` CLI stubbed as a shell function so results are deterministic on any machine:

| Test | What it checks |
| :--- | :------------- |
| Opt-out default | Every named volume is included unless explicitly excluded |
| Exclude list | `DOCKER_EXCLUDE_VOLUMES` skips exactly the listed volumes — exact match, so excluding `db` does not also exclude `my-db` |
| Include precedence | `DOCKER_INCLUDE_VOLUMES` beats both the exclude list and the size cap |
| Size cap | `DOCKER_VOLUME_MAX_SIZE_MB` skips oversized volumes with an actionable reason |
| Unknown size → include | A volume whose size cannot be probed is always captured, even with a cap set (the old code silently skipped it) |
| Skips are recorded | Cap skips land in `_skipped_volumes` for restore-notes and the host notice |
| Legacy mapping | `DOCKER_VOLUME_AUTO_THRESHOLD_MB` still works, mapped onto the new cap with a deprecation warning |
| Disabled volumes notify | `DOCKER_SKIP_VOLUMES=true` pushes a notice to the host |

### Log counter safety — 3 tests

Covers `log_err` and `log_warn` in `lib/core.sh`:

| Test | What it checks |
| :--- | :------------- |
| `log_err` does not abort under `set -e` | `(( ERRORS++ ))` returns exit 1 when `ERRORS==0`, aborting under `set -e`. The `: $(( ))` form avoids this — this test confirms the backup never exits on the first error. |
| `log_warn` counter increments correctly | Multiple warnings accumulate correctly |
| `ERRORS` increments sequentially | Starts at 0 and increments from there |

---

## Test isolation

Each test function calls a `_source_*` helper that sets up a minimal stub environment before sourcing the library under test:

```bash
_source_manifest() {
    BACKUP_ROOT="$BATS_TEST_TMPDIR/usb/proxmox-backup"
    LOG="$BATS_TEST_TMPDIR/backup.log"
    KEEP_BACKUPS=3
    WARNINGS=0; ERRORS=0
    log()      { echo "[LOG] $*" >> "$LOG"; }
    log_warn() { echo "[WARN] $*" >> "$LOG"; : $(( WARNINGS++ )); }
    log_err()  { echo "[ERR] $*"  >> "$LOG"; : $(( ERRORS++ )); }
    source "$PABS_DIR/helpers/manifest.sh"
}
```

`$BATS_TEST_TMPDIR` is a per-test temporary directory created and cleaned up by bats automatically. Tests never share state and never touch the real filesystem outside `/tmp`.

---

## What is not tested

The suite covers pure-Bash logic that can be exercised without real infrastructure. The following require hardware or external services and are not tested automatically:

- USB write operations (`backup.sh`, `atomic_commit`)
- SSH connections to VMs (`section_vm_agents`, `install-agent.sh`)
- rclone offsite sync (`lib/offsite.sh`)
- Pre-flight checks that require a mounted filesystem or root privileges
- The setup wizard's interactive prompts

For these, `backup.sh --dry-run` and `pabs-status.sh` serve as integration-level smoke tests against a real environment.

---

## Adding a test

1. Add a `@test "description" { ... }` block to `tests/pabs.bats`.
2. Call the appropriate `_source_*` helper at the top of the test.
3. Create needed fixture files under `$BATS_TEST_TMPDIR`.
4. Use `run <function>` for tests that check exit codes; call functions directly when testing side-effects.

To add a new `_source_*` helper for a library not yet covered, stub out only the variables and functions that library directly calls — keep stubs minimal so tests do not pass due to a stub hiding a real dependency.
