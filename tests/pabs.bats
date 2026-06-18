#!/usr/bin/env bats
# =============================================================================
# tests/pabs.bats — PABS automated test suite
#
# Requires: bats-core  (https://github.com/bats-core/bats-core)
#   Install: git clone https://github.com/bats-core/bats-core /opt/bats
#            /opt/bats/install.sh /usr/local
#
# Run:
#   bats tests/pabs.bats
#   bats tests/pabs.bats --tap           # TAP output for CI
#   bats tests/pabs.bats --filter rotate # run only rotation tests
# =============================================================================

PABS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Source only the function under test with a minimal stub environment.
# This isolates each function without requiring real USB, SSH, or Proxmox.
_source_manifest() {
    # Minimal stubs required by manifest.sh
    BACKUP_ROOT="$BATS_TEST_TMPDIR/usb/proxmox-backup"
    LOG="$BATS_TEST_TMPDIR/backup.log"
    KEEP_BACKUPS=3
    WARNINGS=0; ERRORS=0
    log()      { echo "[LOG] $*" >> "$LOG"; }
    log_warn() { echo "[WARN] $*" >> "$LOG"; : $(( WARNINGS++ )); }
    log_err()  { echo "[ERR] $*"  >> "$LOG"; : $(( ERRORS++ )); }
    # shellcheck source=../src/helpers/manifest.sh
    source "$PABS_DIR/src/helpers/manifest.sh"
}

_source_core() {
    BACKUP_ROOT="$BATS_TEST_TMPDIR/usb/proxmox-backup"
    LOCAL_STAGE_BASE="$BATS_TEST_TMPDIR/stage"
    LOG="$BATS_TEST_TMPDIR/backup.log"
    LOCK_FILE="$LOCAL_STAGE_BASE/.backup.lock"
    SCRIPT_VERSION="test"
    DISCORD_WEBHOOK=""
    NOTIFY_EMAIL=""
    WARNINGS=0; ERRORS=0
    # shellcheck source=../src/lib/core.sh
    source "$PABS_DIR/src/lib/core.sh"
}

# Create N fake completed backup directories under BACKUP_ROOT
_make_backups() {
    local n="$1"
    mkdir -p "$BACKUP_ROOT"
    for i in $(seq 1 "$n"); do
        local name
        printf -v name "2025-01-%02d_03-00-00" "$i"
        mkdir -p "$BACKUP_ROOT/$name"
        echo "fake" > "$BACKUP_ROOT/$name/MANIFEST.sha256"
    done
}

# ---------------------------------------------------------------------------
# rotate_old_backups — normal operation
# ---------------------------------------------------------------------------

@test "rotate_old_backups: removes excess, keeps KEEP_BACKUPS newest" {
    _source_manifest
    _make_backups 5
    KEEP_BACKUPS=3

    rotate_old_backups

    local remaining
    remaining=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "$remaining" -eq 3 ]
}

@test "rotate_old_backups: removes oldest first" {
    _source_manifest
    _make_backups 5
    KEEP_BACKUPS=2

    rotate_old_backups

    # Oldest two (day-01, day-02) should be gone; day-04 and day-05 remain
    [ ! -d "$BACKUP_ROOT/2025-01-01_03-00-00" ]
    [ ! -d "$BACKUP_ROOT/2025-01-02_03-00-00" ]
    [ ! -d "$BACKUP_ROOT/2025-01-03_03-00-00" ]
    [   -d "$BACKUP_ROOT/2025-01-04_03-00-00" ]
    [   -d "$BACKUP_ROOT/2025-01-05_03-00-00" ]
}

@test "rotate_old_backups: does nothing when count <= KEEP_BACKUPS" {
    _source_manifest
    _make_backups 2
    KEEP_BACKUPS=3

    rotate_old_backups

    local remaining
    remaining=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "$remaining" -eq 2 ]
}

@test "rotate_old_backups: nothing to rotate produces no error" {
    _source_manifest
    mkdir -p "$BACKUP_ROOT"
    KEEP_BACKUPS=3

    run rotate_old_backups
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# rotate_old_backups — KEEP_BACKUPS guard (M10)
# ---------------------------------------------------------------------------

@test "rotate_old_backups: KEEP_BACKUPS=0 skips rotation and warns" {
    _source_manifest
    _make_backups 3
    KEEP_BACKUPS=0

    rotate_old_backups

    # All 3 backups must still exist
    local remaining
    remaining=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "$remaining" -eq 3 ]
    [ "$WARNINGS" -ge 1 ]
}

@test "rotate_old_backups: KEEP_BACKUPS=abc skips rotation and warns" {
    _source_manifest
    _make_backups 3
    KEEP_BACKUPS="abc"

    rotate_old_backups

    local remaining
    remaining=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "$remaining" -eq 3 ]
    [ "$WARNINGS" -ge 1 ]
}

@test "rotate_old_backups: KEEP_BACKUPS=-1 skips rotation and warns" {
    _source_manifest
    _make_backups 3
    KEEP_BACKUPS="-1"

    rotate_old_backups

    local remaining
    remaining=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
    [ "$remaining" -eq 3 ]
    [ "$WARNINGS" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Manifest generation and verification
# ---------------------------------------------------------------------------

@test "generate_and_verify_manifest: creates MANIFEST.sha256 with correct checksums" {
    _source_manifest
    STAGE_DIR="$BATS_TEST_TMPDIR/stage"
    mkdir -p "$STAGE_DIR"
    echo "hello" > "$STAGE_DIR/file_a.txt"
    echo "world" > "$STAGE_DIR/file_b.txt"

    generate_and_verify_manifest

    [ -f "$STAGE_DIR/MANIFEST.sha256" ]
    ( cd "$STAGE_DIR" && sha256sum --check MANIFEST.sha256 )
}

@test "generate_and_verify_manifest: does not include MANIFEST.sha256 itself in manifest" {
    _source_manifest
    STAGE_DIR="$BATS_TEST_TMPDIR/stage"
    mkdir -p "$STAGE_DIR"
    echo "data" > "$STAGE_DIR/config.txt"

    generate_and_verify_manifest

    # MANIFEST.sha256 must not reference itself (circular checksum)
    run grep "MANIFEST.sha256" "$STAGE_DIR/MANIFEST.sha256"
    [ "$status" -ne 0 ]
}

@test "generate_and_verify_manifest: handles filenames with spaces" {
    _source_manifest
    STAGE_DIR="$BATS_TEST_TMPDIR/stage"
    mkdir -p "$STAGE_DIR"
    echo "content" > "$STAGE_DIR/file with spaces.txt"

    run generate_and_verify_manifest
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# log_err / log_warn — counter safety under set -e (4.11)
# ---------------------------------------------------------------------------

@test "log_err: counter increments without aborting under set -e" {
    _source_core
    ERRORS=0

    # This must not exit the test process even with set -e active
    log_err "test error 1"
    log_err "test error 2"

    [ "$ERRORS" -eq 2 ]
}

@test "log_warn: counter increments correctly" {
    _source_core
    WARNINGS=0

    log_warn "test warning 1"
    log_warn "test warning 2"
    log_warn "test warning 3"

    [ "$WARNINGS" -eq 3 ]
}

@test "log_err: ERRORS starts at 0 and increments from there" {
    _source_core
    ERRORS=0

    log_err "first"
    [ "$ERRORS" -eq 1 ]
    log_err "second"
    [ "$ERRORS" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Config validation (src/lib/validate.sh) — added in 3.5
# ---------------------------------------------------------------------------

_source_validate() {
    USB_MOUNT="/mnt/x"; LOCAL_STAGE_BASE="/var/tmp/x"; BACKUP_ROOT="/mnt/x/p"
    KEEP_BACKUPS=4; BACKUP_ZFS="true"
    RCLONE_KEEP_MIN=1; RCLONE_KEEP_MAX=4; RCLONE_MAX_STORAGE_GB=0
    VM_AGENTS=()
    DIED=""
    log()      { :; }
    log_warn() { echo "WARN: $*"; }
    log_err()  { echo "ERR: $*"; }
    die()      { echo "DIE: $*"; exit 1; }
    # shellcheck source=../src/lib/validate.sh
    source "$PABS_DIR/src/lib/validate.sh"
}

@test "validate_config: passes on a clean config" {
    _source_validate
    run validate_config
    [ "$status" -eq 0 ]
}

@test "validate_config: rejects non-integer KEEP_BACKUPS" {
    _source_validate
    KEEP_BACKUPS="abc"
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEEP_BACKUPS"* ]]
}

@test "validate_config: rejects invalid BACKUP_ZFS" {
    _source_validate
    BACKUP_ZFS="maybe"
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"BACKUP_ZFS"* ]]
}

@test "validate_config: rejects unsafe VM_AGENTS label" {
    _source_validate
    VM_AGENTS=("bad;label 1.2.3.4 root /opt/a.sh")
    run validate_config
    [ "$status" -ne 0 ]
}

@test "validate_config: rejects duplicate VM_AGENTS labels" {
    _source_validate
    VM_AGENTS=("vm1 1.2.3.4 root /opt/a.sh" "vm1 1.2.3.5 root /opt/a.sh")
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate"* ]]
}

@test "validate_config: gpg-key method requires a recipient" {
    _source_validate
    RCLONE_ENCRYPTION_METHOD="gpg-key"
    RCLONE_ENCRYPTION_RECIPIENT=""
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"RCLONE_ENCRYPTION_RECIPIENT"* ]]
}
