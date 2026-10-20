#!/usr/bin/env bash
# The new host/storage/off-site checks, driven against controlled inputs.
#
# The rule each one must obey: an input it cannot read is a WARNING naming the
# remedy, never silence and never "healthy". A check that skips quietly reads as
# a clean bill of health, which is the defect family this repository exists to
# prevent.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state/restore-verification" "$TMP/data"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

# $1 = shell defining the stubs, $2 = function to run -> the four arrays, flat
probe() {
  (
    export PATH="$TMP/bin:$PATH"
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export DOMUM_SNAPSHOT_ROOT="$TMP/snapshots" ENABLE_IMMICH=1
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=(); CHECKUP_ACTIONS=()
    eval "$1"
    "$2"
    # Only non-empty classes are printed. `"${arr[@]:-}"` on an empty array
    # yields one EMPTY element, so every probe emitted a bare `CRIT|` line and
    # `grep -q 'CRIT|'` could never fail -- a negative assertion that cannot
    # fail is not an assertion.
    (( ${#CHECKUP_CRITICAL[@]} )) && printf 'CRIT|%s\n' "${CHECKUP_CRITICAL[@]}"
    (( ${#CHECKUP_WARNINGS[@]} )) && printf 'WARN|%s\n' "${CHECKUP_WARNINGS[@]}"
    (( ${#CHECKUP_HEALTHY[@]} ))  && printf 'OK|%s\n'   "${CHECKUP_HEALTHY[@]}"
    (( ${#CHECKUP_ACTIONS[@]} ))  && printf 'ACT|%s\n'  "${CHECKUP_ACTIONS[@]}"
    true
  ) 2>&1
}

# ---------------------------------------------------------------------------
sect "a failed domum unit is CRITICAL; a failed foreign unit is a warning"
out="$(probe '
systemctl() {
  case "$*" in
    *--failed*) printf "domum-media-check.service loaded failed failed x\ncups.service loaded failed failed y\n" ;;
    *list-timers*) : ;;
  esac
}' checkup_systemd_health)"
grep -q 'CRIT|systemd unit domum-media-check.service has FAILED' <<< "$out" \
  || fail "a failed domum unit must be critical: $out"
grep -q 'WARN|systemd unit cups.service has failed' <<< "$out" \
  || fail "a failed foreign unit must be a warning: $out"
grep -q 'ACT|.*journalctl' <<< "$out" || fail "no remedy was given: $out"
echo "  domum unit critical, foreign unit warning, remedy named"

sect "a timer's service that exited NON-ZERO is caught even when not 'failed'"
# systemctl --failed lists only units currently in the failed state. A service
# that failed and was restarted is absent from it, so the last exit status of
# each timer's service is read separately. Nothing checked this before: a failed
# weekly restic integrity check was completely invisible.
out="$(probe '
systemctl() {
  case "$*" in
    *--failed*) : ;;
    *list-timers*) printf "a b c d e domum-media-check.service\n" ;;
    *ExecMainStatus*) printf "3\n" ;;
  esac
}' checkup_systemd_health)"
grep -q 'CRIT|domum-media-check.service last exited non-zero (status 3)' <<< "$out" \
  || fail "a non-zero last run was not caught: $out"
echo "  caught by last exit status, not by the failed list"

sect "a service that has never run is NOT a failure"
out="$(probe '
systemctl() {
  case "$*" in
    *--failed*) : ;;
    *list-timers*) printf "a b c d e domum-media-check.service\n" ;;
    *ExecMainStatus*) : ;;
  esac
}' checkup_systemd_health)"
grep -q 'CRIT|domum' <<< "$out" && fail "a never-run service was reported as failed: $out"
echo "  an empty status is not a non-zero one"

# ---------------------------------------------------------------------------
sect "a non-zero Btrfs error counter is CRITICAL, and checksums are named"
mkdir -p "$TMP/data"
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs    0\n[/dev/sda1].corruption_errs 4\n" ;;
    scrub)  printf "Scrub started:    Mon Oct 20 03:00:00 2026\n" ;;
  esac
}' checkup_btrfs_health)"
grep -q 'CRIT|Btrfs CHECKSUM failures' <<< "$out" \
  || fail "corruption_errs must be reported as a checksum failure: $out"
grep -q 'corruption_errs = 4' <<< "$out" || fail "the counter value is missing: $out"
grep -q 'ACT|btrfs device stats' <<< "$out" || fail "no remedy: $out"
grep -q 'OK|Btrfs error counters' <<< "$out" && fail "it also claimed the counters were clean: $out"
echo "  critical, named as a checksum failure, with the counter and a remedy"

sect "all-zero counters are healthy, and a recent scrub is healthy"
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs 0\n[/dev/sda1].corruption_errs 0\n" ;;
    scrub)  printf "Scrub started:    %s\n" "$(date -d "-3 days" "+%a %b %d %T %Y")" ;;
  esac
}' checkup_btrfs_health)"
grep -q 'OK|Btrfs error counters' <<< "$out" || fail "clean counters not reported healthy: $out"
grep -q 'OK|Btrfs on .* scrubbed 3 day' <<< "$out" || fail "a recent scrub is healthy: $out"
grep -q 'CRIT|' <<< "$out" && fail "nothing was wrong: $out"
echo "  counters clean and scrubbed 3 days ago, both healthy"

sect "a filesystem that has NEVER been scrubbed is a warning with a remedy"
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs 0\n" ;;
    scrub)  printf "no stats available\nScrub status: never ran\n" ;;
  esac
}' checkup_btrfs_health)"
grep -q 'WARN|Btrfs on .* has NEVER been scrubbed' <<< "$out" \
  || fail "a never-scrubbed filesystem must be flagged: $out"
grep -q 'ACT|btrfs scrub start' <<< "$out" || fail "no remedy: $out"
echo "  flagged, with the scrub command"

sect "UNREADABLE Btrfs counters are a warning, never healthy"
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
btrfs() { return 1; }' checkup_btrfs_health)"
grep -q 'WARN|Btrfs error counters for .* could not be read' <<< "$out" \
  || fail "an unreadable counter set must warn: $out"
grep -q 'OK|Btrfs error counters' <<< "$out" && fail "it claimed healthy without reading: $out"
echo "  says it could not read, and claims nothing"

# ---------------------------------------------------------------------------
sect "absent smartmontools is UNKNOWN with a remedy, not a clean bill"
out="$(probe 'cmd_exists() { [[ "$1" != smartctl ]]; }' checkup_disk_health)"
grep -q 'WARN|Disk SMART health is UNKNOWN' <<< "$out" \
  || fail "a missing tool must report UNKNOWN: $out"
grep -q 'ACT|apt-get install -y smartmontools' <<< "$out" || fail "no remedy: $out"
grep -q 'OK|SMART' <<< "$out" && fail "it claimed disks were healthy with no tool: $out"
echo "  UNKNOWN, remedy named, no health claimed"

sect "a SMART self-assessment that does not pass is CRITICAL"
out="$(probe '
cmd_exists() { :; }
lsblk() { printf "sda disk\n"; }
smartctl() { printf "SMART overall-health self-assessment test result: FAILED!\n"; }' \
  checkup_disk_health)"
grep -q 'CRIT|SMART self-assessment for /dev/sda did NOT pass' <<< "$out" \
  || fail "a failing disk must be critical: $out"
grep -q 'ACT|smartctl -a /dev/sda' <<< "$out" || fail "no remedy: $out"
echo "  critical, with the command to investigate"

# ---------------------------------------------------------------------------
EV="$TMP/state/restore-verification/cloud-snapshot-coverage.json"
mk_ev() {  # $1 = classified, $2 = gap, $3 = pending, $4 = unknown
  if [[ "$1" == "none" ]]; then
    printf '{"snapshot_id":"s1","recorded_at":"t","originals":10,"in_snapshot":9,"missing_from_snapshot":1}\n' > "$EV"
  else
    printf '{"snapshot_id":"s1","recorded_at":"t","missing_classified":"%s","missing_backup_gap":%s,"missing_pending_next_backup":%s,"missing_timing_unknown":%s}\n' \
      "$1" "$2" "$3" "$4" > "$EV"
  fi
}
STUB='backup_target_names() { printf "cloud\n"; }; backup_target_enabled() { :; }'

sect "a recorded BACKUP GAP is CRITICAL"
mk_ev known 3 0 0
out="$(probe "$STUB" checkup_immich_offsite)"
grep -q 'CRIT|BACKUP GAP: 3 Immich original' <<< "$out" || fail "a gap must be critical: $out"
grep -q 'ACT|.*verify-snapshot-coverage' <<< "$out" || fail "no remedy: $out"
echo "  critical, with the command that names the paths"

sect "originals merely AWAITING the next backup are healthy, not an alert"
mk_ev known 0 5 0
out="$(probe "$STUB" checkup_immich_offsite)"
grep -q 'OK|Immich originals: no backup gap; 5 awaiting' <<< "$out" \
  || fail "a pending upload must be healthy: $out"
grep -q 'CRIT|' <<< "$out" && fail "a routine upload raised a critical: $out"
grep -q 'ACT|' <<< "$out" && fail "a routine upload demanded an action: $out"
echo "  recorded as healthy, no action demanded -- this is the anti-noise rule"

sect "timing UNKNOWN is a warning, neither excused nor blamed"
mk_ev known 0 0 2
out="$(probe "$STUB" checkup_immich_offsite)"
grep -q 'WARN|2 Immich original(s) were ingested during the backup window' <<< "$out" \
  || fail "an unknown must warn: $out"
grep -q 'CRIT|' <<< "$out" && fail "an unknown was blamed as a gap: $out"
echo "  warned, not blamed"

sect "evidence with NO classification keys is NOT read as zero gap"
mk_ev none
out="$(probe "$STUB" checkup_immich_offsite)"
grep -q 'WARN|.*recorded but NOT classified' <<< "$out" \
  || fail "unclassified evidence must say so: $out"
grep -q 'OK|Immich originals' <<< "$out" && fail "missing keys were read as healthy: $out"
echo "  unclassified, never a clean zero"

sect "never reconciled at all is a warning with the free remedy"
rm -f "$EV"
out="$(probe "$STUB" checkup_immich_offsite)"
grep -q 'WARN|Immich off-site coverage for cloud has never been reconciled' <<< "$out" \
  || fail "an absent proof must warn: $out"
grep -q 'metadata only, no download' <<< "$out" || fail "the remedy must state its cost: $out"
echo "  warned, and the remedy says it downloads nothing"

echo "PASS: health-checks smoke test"
