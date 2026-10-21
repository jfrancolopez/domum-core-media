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
# BOTH roots must exist, or checkup_btrfs_health skips the second one on
# `[[ -d ]]` and every per-filesystem assertion below passes for the wrong
# reason -- the dedup test would "pass" while iterating a single root.
mkdir -p "$TMP/bin" "$TMP/state/restore-verification" "$TMP/data" "$TMP/snapshots"

# A fake /sys/block with a KNOWN non-rotational device. The estimate's rate
# comes from the device's rotational flag, so a section that asserts a duration
# must pin the device -- otherwise it reads the HOST's disk. That is exactly
# what happened: this suite asserted "~10 min" and CI reported 39, because the
# runner's device backing /tmp reports rotational=1. A test that depends on host
# state is not a test.
SB="$TMP/sysblock"
mkdir -p "$SB/ssdz/queue"; echo 0 > "$SB/ssdz/queue/rotational"
# Pin BOTH halves: the device name findmnt reports, and the flag under $SB.
PIN_SSD='export DOMUM_SYSBLOCK_ROOT="'"$SB"'"; findmnt() { printf "/dev/ssdz1[/@data]\n"; }'
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
sect "the weekly unit's ExecStart prefixes make failures VISIBLE"
# systemd semantics for Type=oneshot: each ExecStart runs in order, and a
# non-zero one WITHOUT a `-` prefix fails the unit and the remaining lines are
# never executed. Both prefixes were originally the wrong way round:
#
#   report --write had no `-`, so a failed report SUPPRESSED the alert -- which
#   is precisely when the operator needs telling;
#   health-notify had `-`, so an UNDELIVERABLE alert left the unit green and
#   nothing surfaced it. Silence would have meant "healthy" when it actually
#   meant "could not tell you".
UNIT="$REPO_ROOT/systemd/domum-media-weekly-report.service"
[[ -f "$UNIT" ]] || fail "the weekly unit is missing"
grep -qx 'ExecStart=-/usr/local/bin/domum-media report --write' "$UNIT" \
  || fail "the report step must be prefixed with '-' so a failed report cannot
suppress the alert:
$(grep ExecStart "$UNIT")"
grep -qx 'ExecStart=/usr/local/bin/domum-media health-notify' "$UNIT" \
  || fail "the notify step must NOT be prefixed, so an undeliverable alert
fails the unit and becomes visible in systemctl --failed:
$(grep ExecStart "$UNIT")"
# Order matters too: the report must come first, or `-` on it is pointless.
[[ "$(grep -n 'ExecStart=-.*report --write' "$UNIT" | cut -d: -f1)" \
   -lt "$(grep -n 'ExecStart=/usr/local/bin/domum-media health-notify' "$UNIT" | cut -d: -f1)" ]] \
  || fail "the report step must precede the notify step"
echo "  report tolerated, notify failure fatal, report first"

sect "a failed unit is what SURFACES an undeliverable alert"
# The two halves must join up: health-notify failing puts the unit in the failed
# state, and checkup_systemd_health reports a failed domum unit as CRITICAL.
# Without that link, a delivery failure would be invisible.
out="$(probe '
systemctl() {
  case "$*" in
    *--failed*) printf "domum-media-weekly-report.service loaded failed failed x\n" ;;
    *list-timers*) : ;;
  esac
}' checkup_systemd_health)"
grep -q 'CRIT|systemd unit domum-media-weekly-report.service has FAILED' <<< "$out" \
  || fail "a failed weekly unit must be critical, or delivery failures are
invisible: $out"
echo "  a failed weekly unit is CRITICAL, closing the loop"

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

sect "the remedy quotes the MEASURED size and a derived duration, not \"hours\""
# The remedy used to say "takes hours". Measured on this host, `Total to scrub`
# is 215.87GiB on a SATA SSD -- about ten minutes. An order-of-magnitude
# overstatement of a remedy's cost is the "a remedy that reads as expensive does
# not get run" defect, applied to the one check that guards the photo library.
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs 0\n" ;;
    scrub)  printf "UUID: x\n        no stats available\nTotal to scrub:   215.87GiB\nError summary:    no errors found\n" ;;
  esac
}
'"$PIN_SSD" checkup_btrfs_health)"
grep -q 'ACT|btrfs scrub start' <<< "$out" || fail "no remedy: $out"
grep -q 'takes hours' <<< "$out" && fail "the remedy still overstates the cost: $out"
grep -qE 'ACT\|btrfs scrub start .*~10 min' <<< "$out" \
  || fail "the remedy must derive ~10 min for 215.87GiB on a non-rotational device: $out"
grep -q '215.87GiB it reports' <<< "$out" \
  || fail "the remedy must quote the size the filesystem itself reported: $out"
echo "  ~10 min for the measured 215.87GiB, and the word 'hours' is gone"

sect "an unparseable size omits the estimate instead of printing a zero"
# A caller that gets nothing from the estimator must drop the clause. Printing
# "~0 min" would be a fabricated measurement, and the whole point of the
# estimate is that it was derived from something.
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs 0\n" ;;
    scrub)  printf "UUID: x\n        no stats available\nError summary:    no errors found\n" ;;
  esac
}
'"$PIN_SSD" checkup_btrfs_health)"
grep -q 'ACT|btrfs scrub start' <<< "$out" || fail "the remedy must survive a missing size: $out"
grep -q 'min for the' <<< "$out" && fail "it invented a duration from no size: $out"
grep -q '~0 min' <<< "$out" && fail "it printed a zero estimate: $out"
grep -q 'reports one that does not' <<< "$out" \
  || fail "the repair limit must be stated either way -- a scrub REPAIRS what has a
second copy and only reports what does not, and the remedy has to say so: $out"
echo "  no size, no estimate, and the repair limit is still stated"

sect "the estimate uses the device's OWN rotational flag, both ways"
# Both disks on this host are SSDs, so without DOMUM_SYSBLOCK_ROOT the 100 MB/s
# branch could never be driven and a test would default to 400 and pass for the
# wrong reason -- the fixture-skips-the-iteration mistake. Assert BOTH rates.
mkdir -p "$SB/sdz/queue"
est() {
  (
    export DOMUM_SYSBLOCK_ROOT="$SB"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    findmnt() { printf '/dev/sdz1[/@data]\n'; }
    btrfs_scrub_estimate 'Total to scrub:   215.87GiB' /srv/data
  )
}
echo 1 > "$SB/sdz/queue/rotational"
rot="$(est)"
echo 0 > "$SB/sdz/queue/rotational"
ssd="$(est)"
[[ "$rot" == "39 215.87GiB 100" ]] \
  || fail "a rotational device must be rated 100 MB/s: got '$rot'"
[[ "$ssd" == "10 215.87GiB 400" ]] \
  || fail "a non-rotational device must be rated 400 MB/s: got '$ssd'"
[[ "$rot" != "$ssd" ]] || fail "the rotational flag changed nothing: '$rot'"
echo "  39 min spinning, 10 min solid-state, from sdz1 -> sdz"

sect "a partition suffix is trimmed to find the block device"
# findmnt reports /dev/sdz1[/@data]; the rotational flag lives under sdz.
# Without the trim the lookup misses, the fallback rate applies, and the
# rotational case would silently read as an SSD.
rm -rf "$SB/sdz"; mkdir -p "$SB/nvme0n1/queue"; echo 1 > "$SB/nvme0n1/queue/rotational"
nv="$(
  export DOMUM_SYSBLOCK_ROOT="$SB"
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  findmnt() { printf '/dev/nvme0n1p1[/@data]\n'; }
  btrfs_scrub_estimate 'Total to scrub:   215.87GiB' /srv/data
)"
[[ "$nv" == "39 215.87GiB 100" ]] \
  || fail "nvme0n1p1 must resolve to nvme0n1: got '$nv'"
echo "  nvme0n1p1 -> nvme0n1"

sect "mutation: ignoring the rotational flag makes a spinning disk read as an SSD"
# An estimate that silently ignores the device class is how a plausible wrong
# figure survives -- the same shape as quoting the cap that does not bind. The
# mutation removes the rate selection and requires the two devices to agree,
# which they must not.
MUTROT="$TMP/mut-rot"
cp "$CLI" "$MUTROT"
sed -i 's/^    \[\[ "\$rota" == "1" \]\] \&\& rate=100$/    rate="$rate"/' "$MUTROT"
grep -q '^    rate="\$rate"$' "$MUTROT" \
  || fail "the rotational mutation was not applied; it proves nothing"
grep -q 'rota" == "1" \]\] && rate=100' "$MUTROT" \
  && fail "the mutation left the original line in place; it proves nothing"
rm -rf "$SB/nvme0n1"; mkdir -p "$SB/sdz/queue"; echo 1 > "$SB/sdz/queue/rotational"
mrot="$(
  export DOMUM_SYSBLOCK_ROOT="$SB"
  # shellcheck disable=SC1090
  source "$MUTROT" >/dev/null 2>&1
  findmnt() { printf '/dev/sdz1[/@data]\n'; }
  btrfs_scrub_estimate 'Total to scrub:   215.87GiB' /srv/data
)"
[[ "$mrot" == "10 215.87GiB 400" ]] \
  || fail "the mutation should rate a spinning disk as an SSD: got '$mrot'"
echo "  killed: without the flag a 39-minute scrub is advertised as 10"

sect "an unknown device falls back to the FASTER rate, and says the size anyway"
# The fallback must not inflate the cost: an unknown device reported as
# rotational would reintroduce the overstatement this section exists to remove.
unk="$(
  export DOMUM_SYSBLOCK_ROOT="$TMP/absent"
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  findmnt() { printf '\n'; }
  btrfs_scrub_estimate 'Total to scrub:   215.87GiB' /srv/data
)"
[[ "$unk" == "10 215.87GiB 400" ]] || fail "unknown device must not inflate: got '$unk'"
echo "  unknown device -> 400 MB/s, size still quoted"

sect "two roots on ONE filesystem are reported once, not twice"
# Measured 2026-10-20: /srv/data and /srv/snapshots are both subvolumes of
# /dev/sda1, uuid 211e06b3-.... Iterating by PATH produced two identical
# "never been scrubbed" warnings and told the operator to run TWO scrubs of the
# same device -- the second re-reading the same 215.87 GiB for nothing.
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
findmnt() { printf "SAME-FS-UUID\n"; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs 0\n" ;;
    scrub)  printf "UUID: x\n        no stats available\n" ;;
  esac
}' checkup_btrfs_health)"
[[ "$(grep -c 'WARN|Btrfs on .* has NEVER been scrubbed' <<< "$out")" == "1" ]] \
  || fail "one filesystem produced $(grep -c 'NEVER been scrubbed' <<< "$out") scrub
warnings; it must produce exactly one:
$out"
[[ "$(grep -c 'ACT|btrfs scrub start' <<< "$out")" == "1" ]] \
  || fail "it suggested more than one scrub for one filesystem: $out"
grep -q 'one scrub covers every subvolume' <<< "$out" \
  || fail "the warning does not say one scrub is enough: $out"
echo "  one warning, one scrub suggested, and it says why"

sect "two roots on DIFFERENT filesystems are both reported"
# The dedup must not hide a second, genuinely separate filesystem.
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }
findmnt() { case "$*" in *snapshots*) printf "FS-B\n" ;; *) printf "FS-A\n" ;; esac; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs 0\n" ;;
    scrub)  printf "UUID: x\n        no stats available\n" ;;
  esac
}' checkup_btrfs_health)"
[[ "$(grep -c 'WARN|Btrfs on .* has NEVER been scrubbed' <<< "$out")" == "2" ]] \
  || fail "two distinct filesystems must both be reported: $out"
echo "  both reported when the UUIDs differ"

sect "with findmnt unavailable it falls back to the device id"
# The dedup must still hold, or an absent tool silently doubles every finding.
out="$(probe '
stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *-c*%d*) printf "66\n" ;; *) command stat "$@" ;; esac; }
findmnt() { return 1; }
btrfs() {
  case "$1" in
    device) printf "[/dev/sda1].write_io_errs 0\n" ;;
    scrub)  printf "UUID: x\n        no stats available\n" ;;
  esac
}' checkup_btrfs_health)"
[[ "$(grep -c 'WARN|Btrfs on .* has NEVER been scrubbed' <<< "$out")" == "1" ]] \
  || fail "without findmnt the dedup failed and doubled the finding: $out"
echo "  st_dev fallback keeps it to one"

sect "a filesystem that has never been scrubbed is caught in BOTH wordings"
# Measured on the production host 2026-10-20: btrfs-progs reports
#
#   UUID:             211e06b3-...
#           no stats available
#   Total to scrub:   215.87GiB
#   Error summary:    no errors found
#
# The first matcher looked only for "never ran", so it fell through, found no
# "Scrub started:" line either, and said NOTHING. A filesystem holding 23,155
# irreplaceable originals that has never been scrubbed reported as neither
# healthy nor a warning -- the silence read as fine.
for wording in 'no stats available' 'Scrub status: never ran'; do
  out="$(probe "
stat() { case \"\$*\" in *-f*%T*) printf 'btrfs\n' ;; *) command stat \"\$@\" ;; esac; }
btrfs() {
  case \"\$1\" in
    device) printf '[/dev/sda1].write_io_errs 0\n' ;;
    scrub)  printf 'UUID: x\n        $wording\nTotal to scrub:   215.87GiB\nError summary:    no errors found\n' ;;
  esac
}" checkup_btrfs_health)"
  grep -q 'WARN|Btrfs on .* has NEVER been scrubbed' <<< "$out" \
    || fail "wording '$wording' was not recognised as never-scrubbed: $out"
  grep -q 'ACT|btrfs scrub start' <<< "$out" || fail "no remedy for '$wording': $out"
  grep -q 'reports one that does not' <<< "$out" \
    || fail "the remedy must state what a scrub cannot do: $out"
  grep -q 'OK|Btrfs on .* scrubbed' <<< "$out" \
    && fail "'$wording' was also reported as recently scrubbed: $out"
done
echo "  both wordings warn, with a remedy that states its own limit"

sect "'Error summary: no errors found' from a scrub that NEVER RAN is not a pass"
# That line is printed even when no scrub has ever happened, so reading it as a
# clean result would turn an unmeasured filesystem into a healthy one.
out="$(probe "
stat() { case \"\$*\" in *-f*%T*) printf 'btrfs\n' ;; *) command stat \"\$@\" ;; esac; }
btrfs() {
  case \"\$1\" in
    device) printf '[/dev/sda1].write_io_errs 0\n' ;;
    scrub)  printf 'UUID: x\n        no stats available\nError summary:    no errors found\n' ;;
  esac
}" checkup_btrfs_health)"
grep -q 'WARN|Btrfs on .* has NEVER been scrubbed' <<< "$out" \
  || fail "it must still warn: $out"
echo "  warned despite the reassuring error summary"

sect "an UNPARSEABLE scrub status is UNKNOWN, not healthy"
out="$(probe "
stat() { case \"\$*\" in *-f*%T*) printf 'btrfs\n' ;; *) command stat \"\$@\" ;; esac; }
btrfs() {
  case \"\$1\" in
    device) printf '[/dev/sda1].write_io_errs 0\n' ;;
    scrub)  printf 'some future format nobody has seen\n' ;;
  esac
}" checkup_btrfs_health)"
grep -q 'WARN|Btrfs scrub history for .* could not be parsed' <<< "$out" \
  || fail "an unparseable status must warn: $out"
grep -q 'OK|Btrfs on .* scrubbed' <<< "$out" && fail "it claimed a scrub happened: $out"
echo "  says it could not parse, claims nothing"

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
smartctl() { printf "%s" "{\"smart_status\":{\"passed\":false}}"; }' \
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

sect "FULL coverage is healthy even when the evidence predates classification"
# Production, 2026-10-20. The evidence said 23155 of 23155 with zero missing --
# the best possible state -- and `checkup` reported "recorded but NOT
# classified" and demanded a reconciliation of a fully reconciled library. The
# classification block was guarded on `n_missing > 0`, so nothing missing left
# `missing_classified: unknown`. That would have been the first notification
# this host ever sent, and it would have been wrong.
printf '{"snapshot_id":"ab8c31c8","recorded_at":"t","originals":23155,"in_snapshot":23155,"missing_from_snapshot":0}\n' > "$EV"
out="$(probe "$STUB" checkup_immich_offsite)"
grep -q 'OK|Immich originals: every one is in snapshot ab8c31c8' <<< "$out" \
  || fail "full coverage must be healthy: $out"
grep -q 'ACT|' <<< "$out" && fail "full coverage demanded an action: $out"
grep -q 'WARN|' <<< "$out" && fail "full coverage produced a warning: $out"
echo "  healthy, no action, no warning -- nothing to classify is not unknown"

sect "mutation: reading classification BEFORE the count brings the false alarm back"
MUTFA="$TMP/mut-fa"
cp "$CLI" "$MUTFA"
sed -i 's/^    if \[\[ "\$miss" =~ \^\[0-9\]+\$ \]\] \&\& (( miss == 0 )); then$/    if false; then/' "$MUTFA"
grep -q '^    if false; then' "$MUTFA" \
  || fail "the full-coverage mutation was not applied; it proves nothing"
mout="$(
  (
    export PATH="$TMP/bin:$PATH" DOMUM_STATE_ROOT="$TMP/state" ENABLE_IMMICH=1
    # shellcheck disable=SC1090
    source "$MUTFA" >/dev/null 2>&1
    set +e
    CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=(); CHECKUP_ACTIONS=()
    backup_target_names() { printf 'cloud\n'; }
    backup_target_enabled() { :; }
    checkup_immich_offsite
    (( ${#CHECKUP_ACTIONS[@]} )) && printf 'ACT|%s\n' "${CHECKUP_ACTIONS[@]}"
    true
  ) 2>&1
)"
grep -q 'ACT|' <<< "$mout" \
  || fail "without the count check a fully covered library should demand an action: $mout"
echo "  killed: without it, 23155 of 23155 asks the operator to reconcile again"

sect "never reconciled at all is a warning with the free remedy"
rm -f "$EV"
out="$(probe "$STUB" checkup_immich_offsite)"
grep -q 'WARN|Immich off-site coverage for cloud has never been reconciled' <<< "$out" \
  || fail "an absent proof must warn: $out"
grep -q 'metadata only, no download' <<< "$out" || fail "the remedy must state its cost: $out"
echo "  warned, and the remedy says it downloads nothing"

sect "SMART: a device that cannot be READ is UNKNOWN, never CRITICAL"
# The old check grepped `smartctl -H` for PASSED|OK case-insensitively and sent
# an unreadable device to CRITICAL "did NOT pass" -- a false alarm telling the
# operator to replace a healthy disk. Measured: under permission denied
# `smartctl -j -H` returns well-formed JSON with exit_status 2 and NO
# smart_status. "I could not check it" is not "it is broken".
DENIED='{"json_format_version":[1,0],"smartctl":{"exit_status":2,"messages":[{"string":"Smartctl open device: /dev/sda failed: Permission denied","severity":"error"}]}}'
out="$(probe "
lsblk() { printf 'sda disk\n'; }
smartctl() { printf '%s' '$DENIED'; }
" checkup_disk_health)"
grep -q 'CRIT|' <<< "$out" && fail "an unreadable device was reported as a FAILED disk: $out"
grep -q 'WARN|SMART health for /dev/sda is UNKNOWN' <<< "$out" \
  || fail "an unreadable device must be UNKNOWN: $out"
grep -q 'OK|SMART' <<< "$out" && fail "an unreadable device was reported healthy: $out"
grep -q 'ACT|smartctl -H' <<< "$out" || fail "no remedy, so it never mails: $out"
grep -qi 'not a failed one' <<< "$out" || fail "the remedy does not say it is not a failure: $out"
echo "  UNKNOWN with a remedy, neither healthy nor critical"

sect "SMART: a real PASSED capture reads healthy; a failed one reads CRITICAL"
# Driven with the shape of the real captures taken from this host 2026-10-21,
# where both drives report smart_status.passed = true.
out="$(probe "
lsblk() { printf 'sda disk\n'; }
smartctl() { printf '%s' '{\"smart_status\":{\"passed\":true}}'; }
" checkup_disk_health)"
grep -q 'OK|SMART self-assessment for /dev/sda: passed' <<< "$out" \
  || fail "a passing drive was not reported healthy: $out"
grep -qE 'CRIT\||WARN\|SMART' <<< "$out" && fail "a passing drive raised something: $out"
out="$(probe "
lsblk() { printf 'sda disk\n'; }
smartctl() { printf '%s' '{\"smart_status\":{\"passed\":false}}'; }
" checkup_disk_health)"
grep -q 'CRIT|SMART self-assessment for /dev/sda did NOT pass' <<< "$out" \
  || fail "a FAILING drive was not critical: $out"
grep -q 'ACT|smartctl -a' <<< "$out" || fail "a failing drive has no remedy: $out"
echo "  true -> healthy, false -> critical, both with the right class"

sect "SMART: the verdict is not matched as a SUBSTRING"
# `grep -qiE 'PASSED|OK'` matched "ok" anywhere in the output. Unrelated prose
# containing those letters must not read as a pass.
out="$(probe "
lsblk() { printf 'sda disk\n'; }
smartctl() { printf '%s' '{\"smartctl\":{\"messages\":[{\"string\":\"Device looks OK but SMART is disabled\"}]}}'; }
" checkup_disk_health)"
grep -q 'OK|SMART' <<< "$out" \
  && fail "prose containing 'OK' was read as a passing self-assessment: $out"
grep -q 'WARN|SMART health for /dev/sda is UNKNOWN' <<< "$out" \
  || fail "a verdict-less capture must be UNKNOWN: $out"
echo "  prose containing OK is still UNKNOWN"

sect "SMART: jq absent is UNKNOWN with a remedy, not silence"
out="$(probe "
lsblk() { printf 'sda disk\n'; }
cmd_exists() { [[ \"\$1\" != jq ]]; }
" checkup_disk_health)"
grep -qi 'jq is not installed' <<< "$out" || fail "a missing jq is not reported: $out"
grep -q 'ACT|apt-get install -y jq' <<< "$out" || fail "no remedy for missing jq: $out"
grep -q 'OK|SMART' <<< "$out" && fail "it claimed disk health with no way to parse it: $out"
echo "  UNKNOWN, named, with the remedy"

echo "PASS: health-checks smoke test"
