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

# ---------------------------------------------------------------------------
# Manifest — empty-staging total-failure guard (audit BUG-05, added in 3.6)
# ---------------------------------------------------------------------------

@test "generate_and_verify_manifest: empty staging aborts instead of fabricating a manifest" {
    _source_manifest
    die() { echo "DIE: $*"; exit 1; }
    STAGE_DIR="$BATS_TEST_TMPDIR/stage-empty"
    mkdir -p "$STAGE_DIR"

    # Before the xargs -r fix, an empty stage produced a 1-line manifest for
    # stdin ('-'), defeating the "all sections failed" guard.
    run generate_and_verify_manifest
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"empty"* ]]
}

@test "generate_and_verify_manifest: dirs-only staging also aborts" {
    _source_manifest
    die() { echo "DIE: $*"; exit 1; }
    STAGE_DIR="$BATS_TEST_TMPDIR/stage-dirs"
    mkdir -p "$STAGE_DIR/etc/pve" "$STAGE_DIR/vm-agents"

    run generate_and_verify_manifest
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE:"* ]]
}

# ---------------------------------------------------------------------------
# Manifest — post-generation extension for generated docs (audit BUG-08)
# ---------------------------------------------------------------------------

@test "extend_manifest_on_usb: generated docs become covered by --verify" {
    _source_manifest
    FINAL_DIR="$BATS_TEST_TMPDIR/usb/2025-01-01_03-00-00"
    mkdir -p "$FINAL_DIR"
    echo "payload" > "$FINAL_DIR/data.txt"
    ( cd "$FINAL_DIR" && sha256sum ./data.txt > MANIFEST.sha256 )

    # Docs are written after the manifest, exactly like backup.sh does it
    echo "#!/bin/bash" > "$FINAL_DIR/proxmox-restore.sh"
    echo "readme"      > "$FINAL_DIR/README.txt"
    echo "# DR"        > "$FINAL_DIR/DISASTER-RECOVERY.md"

    extend_manifest_on_usb "proxmox-restore.sh" "README.txt" "DISASTER-RECOVERY.md"

    grep -q "proxmox-restore.sh"   "$FINAL_DIR/MANIFEST.sha256"
    grep -q "README.txt"           "$FINAL_DIR/MANIFEST.sha256"
    grep -q "DISASTER-RECOVERY.md" "$FINAL_DIR/MANIFEST.sha256"
    ( cd "$FINAL_DIR" && sha256sum --quiet --check MANIFEST.sha256 )

    # ...and corruption of a generated doc is now detectable
    echo "tampered" > "$FINAL_DIR/README.txt"
    run bash -c "cd '$FINAL_DIR' && sha256sum --quiet --check MANIFEST.sha256"
    [ "$status" -ne 0 ]
}

@test "extend_manifest_on_usb: missing doc warns but does not fail the run" {
    _source_manifest
    FINAL_DIR="$BATS_TEST_TMPDIR/usb/2025-01-02_03-00-00"
    mkdir -p "$FINAL_DIR"
    echo "payload" > "$FINAL_DIR/data.txt"
    ( cd "$FINAL_DIR" && sha256sum ./data.txt > MANIFEST.sha256 )

    run extend_manifest_on_usb "does-not-exist.txt"
    [ "$status" -eq 0 ]
    ( cd "$FINAL_DIR" && sha256sum --quiet --check MANIFEST.sha256 )
}

# ---------------------------------------------------------------------------
# Docker agent — volume capture policy (audit BUG-01/BUG-03, agent v1.1)
# ---------------------------------------------------------------------------

# Source the docker type handler with a stubbed agent environment.
# `docker` is stubbed as a failing shell function so tests are deterministic
# regardless of whether a Docker daemon exists on the test machine.
_source_docker() {
    STAGE_DIR="$BATS_TEST_TMPDIR/agent-stage"
    mkdir -p "$STAGE_DIR"
    WARNINGS=0; ERRORS=0
    STAGED=(); NOTICES=()
    log()      { :; }
    log_warn() { : $(( WARNINGS++ )); }
    log_err()  { : $(( ERRORS++ )); }
    notify_host() { NOTICES+=("$*"); }
    stage_path()  { STAGED+=("$1"); }
    stage_cmd()   { :; }
    stage_write() { :; }
    docker()      { return 1; }
    # shellcheck source=../src/vm-agent/types/docker.sh
    source "$PABS_DIR/src/vm-agent/types/docker.sh"
}

@test "docker _volume_decision: default is include (opt-out model)" {
    _source_docker
    run _volume_decision "postgres_data" "4096"
    [[ "$output" == include* ]]
}

@test "docker _volume_decision: DOCKER_EXCLUDE_VOLUMES skips exactly that volume" {
    _source_docker
    DOCKER_EXCLUDE_VOLUMES="jellyfin_cache, plex_transcode"

    run _volume_decision "jellyfin_cache" "900"
    [[ "$output" == skip* ]]
    run _volume_decision "plex_transcode" "900"
    [[ "$output" == skip* ]]
    run _volume_decision "postgres_data" "900"
    [[ "$output" == include* ]]
}

@test "docker _volume_decision: exclude match is exact, not substring/word-boundary" {
    _source_docker
    # grep -qw would have treated '-' as a word boundary and skipped 'my-db' too
    DOCKER_EXCLUDE_VOLUMES="db"
    run _volume_decision "my-db" "10"
    [[ "$output" == include* ]]
    run _volume_decision "db" "10"
    [[ "$output" == skip* ]]
}

@test "docker _volume_decision: DOCKER_INCLUDE_VOLUMES beats exclude list and cap" {
    _source_docker
    DOCKER_INCLUDE_VOLUMES="postgres_data"
    DOCKER_EXCLUDE_VOLUMES="postgres_data"
    DOCKER_VOLUME_MAX_SIZE_MB=1

    run _volume_decision "postgres_data" "50000"
    [[ "$output" == include* ]]
}

@test "docker _volume_decision: size cap skips oversized volumes loudly-reasoned" {
    _source_docker
    DOCKER_VOLUME_MAX_SIZE_MB=100

    run _volume_decision "big_volume" "500"
    [[ "$output" == skip* ]]
    [[ "$output" == *"DOCKER_VOLUME_MAX_SIZE_MB"* ]]

    run _volume_decision "small_volume" "50"
    [[ "$output" == include* ]]
}

@test "docker _volume_decision: unknown size is INCLUDED even with a cap set (BUG-03)" {
    _source_docker
    DOCKER_VOLUME_MAX_SIZE_MB=100

    # Old behavior defaulted unknown size to 999 → silently skipped.
    run _volume_decision "unmeasurable" "unknown"
    [[ "$output" == include* ]]
}

@test "docker _backup_named_volume: size-probe failure still stages the volume (BUG-03)" {
    _source_docker
    DOCKER_VOLUME_MAX_SIZE_MB=1   # cap active — unknown size must bypass it

    local fake_mount="$BATS_TEST_TMPDIR/vol-mnt"
    mkdir -p "$fake_mount"
    echo "data" > "$fake_mount/db.sqlite"

    # docker inspect resolves; du fails → size unknown
    docker() {
        case "$1" in
            volume) [[ "$2" == "inspect" ]] && { echo "$fake_mount"; return 0; }; return 1 ;;
            ps)     return 0 ;;   # no writers
            *)      return 1 ;;
        esac
    }
    du() { return 1; }

    _backup_named_volume "unmeasurable_vol" "auto"

    [ "${#STAGED[@]}" -eq 1 ]
    [ "${STAGED[0]}" = "$fake_mount" ]
    [ "${#_skipped_volumes[@]}" -eq 0 ]
}

@test "docker _backup_named_volume: cap skip is recorded for notes and host notice" {
    _source_docker
    DOCKER_VOLUME_MAX_SIZE_MB=1

    local fake_mount="$BATS_TEST_TMPDIR/vol-big"
    mkdir -p "$fake_mount"
    dd if=/dev/zero of="$fake_mount/blob" bs=1M count=3 status=none

    docker() {
        case "$1" in
            volume) [[ "$2" == "inspect" ]] && { echo "$fake_mount"; return 0; }; return 1 ;;
            *)      return 1 ;;
        esac
    }

    _backup_named_volume "big_vol" "auto"

    [ "${#STAGED[@]}" -eq 0 ]
    [ "${#_skipped_volumes[@]}" -eq 1 ]
    [[ "${_skipped_volumes[0]}" == "big_vol"* ]]
}

@test "docker _backup_volumes: legacy DOCKER_VOLUME_AUTO_THRESHOLD_MB maps to the new size cap" {
    _source_docker
    DOCKER_VOLUME_AUTO_THRESHOLD_MB=25
    DOCKER_VOLUME_MAX_SIZE_MB=0

    _backup_volumes   # docker stub fails → volume sweep is empty, mapping still runs

    [ "$DOCKER_VOLUME_MAX_SIZE_MB" = "25" ]
    [ "$WARNINGS" -ge 1 ]   # deprecation warning fired
}

@test "docker _backup_volumes: DOCKER_SKIP_VOLUMES=true notifies the host" {
    _source_docker
    DOCKER_SKIP_VOLUMES="true"

    _backup_volumes

    [ "${#NOTICES[@]}" -eq 1 ]
    [[ "${NOTICES[0]}" == *"disabled by config"* ]]
}
