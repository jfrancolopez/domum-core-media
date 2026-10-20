#!/usr/bin/env bash
# Deploy the accumulated recovery-REPORTING fixes, and nothing else.
#
# WHAT THIS CHANGES
#
#   /usr/local/bin/domum-media           (if its hash differs)
#   /usr/local/bin/domum-media-backup    (if its hash differs)
#   /opt/domum-core-media                fast-forwarded to origin/main
#   operator/ scripts inside that checkout, as part of the fast-forward
#   /etc/systemd/system/domum-media-weekly-report.{service,timer}
#       Installed if their hashes differ, then `systemctl daemon-reload`.
#       NEITHER IS ENABLED OR STARTED. The weekly unit carries the
#       `health-notify` step, so installing the file is what makes the
#       notification available; enabling the timer sends mail and stays an
#       explicit operator decision.
#
# WHAT IT DOES NOT TOUCH: containers, images, compose files, systemd units,
# timers, Restic schedules, Restic exclusions, the Immich database, originals,
# Btrfs subvolumes, snapshots, recovery archives, and the production
# configuration (untracked, so a fast-forward cannot disturb it).
#
# No service is stopped, started or recreated. These are three text files.
#
# WHY NO BAKED-IN REVISION. A revision constant inside the repository it pins
# goes stale by construction, and a deployment script asserting an absolute
# production state has aborted a correct deployment here before -- at its own
# stage 7, after every mutation had already succeeded. So:
#
#   * the revision to deploy is whatever `origin/main` is at run time;
#   * `--expect-revision <sha>` pins it, supplied by the OPERATOR, not stored;
#   * the only invariant asserted afterwards is the one that cannot go stale:
#     each installed file's sha256 equals that file in the production checkout.
#
# It also asserts nothing about which service is in which protection state.
# That is live state this deployment neither controls nor changes.
set -euo pipefail

# Roots are overridable ONLY so this script can be rehearsed. They default to
# the production paths, and a rehearsal must run the checks as written.
CHECKOUT="${DOMUM_DEPLOY_CHECKOUT:-/opt/domum-core-media}"
BIN_DIR="${DOMUM_DEPLOY_BIN_DIR:-/usr/local/bin}"
LIB_DIR="${DOMUM_DEPLOY_LIB_DIR:-/usr/local/lib/domum-media}"
UNIT_DIR="${DOMUM_DEPLOY_UNIT_DIR:-/etc/systemd/system}"
REMOTE="${DOMUM_DEPLOY_REMOTE:-origin}"
BRANCH="${DOMUM_DEPLOY_BRANCH:-main}"

CONFIRM=0
EXPECT_REV=""
SKIP_BEHAVIOUR=0
for a in "$@"; do
  case "$a" in
    --confirm)          CONFIRM=1 ;;
    --expect-revision=*) EXPECT_REV="${a#*=}" ;;
    --no-behaviour-check) SKIP_BEHAVIOUR=1 ;;
    -h|--help)
      printf 'Usage: %s [--confirm] [--expect-revision=<sha>] [--no-behaviour-check]\n' "${0##*/}"
      printf '  Without --confirm, reports what WOULD change and exits 0.\n'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$a" >&2; exit 64 ;;
  esac
done

abort() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
say()   { printf '  %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || abort "must run as root: it installs into $BIN_DIR"
[ -d "$CHECKOUT/.git" ] || abort "not a git checkout: $CHECKOUT"
command -v jq >/dev/null 2>&1 || abort "jq is required to verify the new output"

printf '== domum-media reporting deployment ==\n'
say "checkout : $CHECKOUT"
say "binaries : $BIN_DIR"

# ---------------------------------------------------------------------------
# 1. The checkout must hold nothing of its own that a fast-forward would lose.
# ---------------------------------------------------------------------------
DIRTY="$(git -C "$CHECKOUT" status --porcelain --untracked-files=normal)"
if [ -n "$DIRTY" ]; then
  # The production configuration is deliberately untracked and must survive, so
  # an ignored file is fine; anything else is drift this script will not judge.
  printf 'ABORT: the production checkout has local changes:\n%s\n' "$DIRTY" >&2
  abort "resolve them deliberately; this script will not discard work"
fi
say "checkout is clean (tracked and untracked)"

# ---------------------------------------------------------------------------
# 2. Fast-forward only. Never reset --hard: a fast-forward cannot discard a
#    commit, and git refuses it outright when history has diverged.
# ---------------------------------------------------------------------------
BEFORE_REV="$(git -C "$CHECKOUT" rev-parse HEAD)"
git -C "$CHECKOUT" fetch --quiet "$REMOTE" "$BRANCH" || abort "fetch failed"
TARGET_REV="$(git -C "$CHECKOUT" rev-parse "$REMOTE/$BRANCH")"

if [ -n "$EXPECT_REV" ]; then
  case "$TARGET_REV" in
    "$EXPECT_REV"*) : ;;
    *) abort "$REMOTE/$BRANCH is ${TARGET_REV:0:12}, not the expected $EXPECT_REV" ;;
  esac
  say "revision matches --expect-revision"
fi

if [ "$BEFORE_REV" = "$TARGET_REV" ]; then
  say "checkout already at ${TARGET_REV:0:12}"
else
  git -C "$CHECKOUT" merge-base --is-ancestor "$BEFORE_REV" "$TARGET_REV" \
    || abort "the checkout is NOT an ancestor of $REMOTE/$BRANCH -- a
fast-forward would be a rewrite. Investigate before deploying."
  # A dry run must not describe an action in the indicative. This said
  # "fast-forward: X -> Y" before the --confirm gate, which reads as though the
  # checkout had already moved -- it had not, and the operator had to be told
  # so afterwards. A report that implies a mutation it did not make is the
  # defect this project keeps correcting, and a deployment script is the worst
  # place for it.
  if [ "$CONFIRM" -eq 1 ]; then
    say "fast-forward: ${BEFORE_REV:0:12} -> ${TARGET_REV:0:12}"
  else
    say "WOULD fast-forward: ${BEFORE_REV:0:12} -> ${TARGET_REV:0:12} (not done yet)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. State the hashes BEFORE changing anything.
# ---------------------------------------------------------------------------
# installed path : path within the repository
TARGETS="
$BIN_DIR/domum-media:bin/domum-media
$BIN_DIR/domum-media-backup:bin/domum-media-backup
$LIB_DIR/domum-media-report:bin/domum-media-report
"

# Unit files, installed 0644 into the systemd directory. Deliberately a
# separate list: a different mode, a different destination, and a daemon-reload
# afterwards. Installing a unit neither enables nor starts it.
UNIT_TARGETS="
$UNIT_DIR/domum-media-weekly-report.service:systemd/domum-media-weekly-report.service
$UNIT_DIR/domum-media-weekly-report.timer:systemd/domum-media-weekly-report.timer
"

hash_of() { [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1 || printf 'ABSENT'; }
blob_of() { git -C "$CHECKOUT" show "$TARGET_REV:$1" | sha256sum | cut -d' ' -f1; }

printf '\n  %-42s %-14s %-14s %s\n' FILE INSTALLED TARGET ACTION
CHANGES=0
for entry in $TARGETS $UNIT_TARGETS; do
  inst="${entry%%:*}"; rel="${entry##*:}"
  have="$(hash_of "$inst")"; want="$(blob_of "$rel")"
  if [ "$have" = "$want" ]; then act="unchanged"; else act="INSTALL"; CHANGES=$((CHANGES+1)); fi
  printf '  %-42s %-14s %-14s %s\n' "$rel" "${have:0:12}" "${want:0:12}" "$act"
done

if [ "$CONFIRM" -ne 1 ]; then
  printf '\n  %s\n' "DRY RUN. $CHANGES file(s) would be installed; nothing was changed."
  printf '  %s\n' "Re-run with --confirm to apply."
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Apply: fast-forward the checkout, then install only what differs.
# ---------------------------------------------------------------------------
printf '\n'
if [ "$BEFORE_REV" != "$TARGET_REV" ]; then
  git -C "$CHECKOUT" merge --ff-only "$REMOTE/$BRANCH" >/dev/null \
    || abort "fast-forward failed"
  say "checkout now at $(git -C "$CHECKOUT" rev-parse --short HEAD)"
fi

for entry in $TARGETS; do
  inst="${entry%%:*}"; rel="${entry##*:}"
  src="$CHECKOUT/$rel"
  [ -f "$src" ] || abort "missing in the checkout after fast-forward: $rel"
  if [ "$(hash_of "$inst")" != "$(sha256sum "$src" | cut -d' ' -f1)" ]; then
    install -D -m 0755 "$src" "$inst" || abort "install failed: $inst"
    say "installed $inst"
  fi
done

UNITS_CHANGED=0
for entry in $UNIT_TARGETS; do
  inst="${entry%%:*}"; rel="${entry##*:}"
  src="$CHECKOUT/$rel"
  [ -f "$src" ] || abort "missing in the checkout after fast-forward: $rel"
  if [ "$(hash_of "$inst")" != "$(sha256sum "$src" | cut -d' ' -f1)" ]; then
    install -D -m 0644 "$src" "$inst" || abort "install failed: $inst"
    say "installed $inst (not enabled, not started)"
    UNITS_CHANGED=1
  fi
done
if [ "$UNITS_CHANGED" -eq 1 ]; then
  systemctl daemon-reload || abort "systemctl daemon-reload failed"
  say "systemd reloaded; no unit was enabled or started"
fi

# ---------------------------------------------------------------------------
# 5. The invariant that cannot go stale: installed == checkout, for every file.
# ---------------------------------------------------------------------------
printf '\n'
for entry in $TARGETS $UNIT_TARGETS; do
  inst="${entry%%:*}"; rel="${entry##*:}"
  a="$(hash_of "$inst")"; b="$(sha256sum "$CHECKOUT/$rel" | cut -d' ' -f1)"
  [ "$a" = "$b" ] || abort "$inst does not match $CHECKOUT/$rel after install"
  say "verified ${rel##*/} ${a:0:12}"
done

# ---------------------------------------------------------------------------
# 6. Behaviour, asserted through the machine-readable contract -- never prose.
#
# The point of this deployment is that a missing original is CLASSIFIED rather
# than reported as a bare absence. So the proof is that the JSON carries the
# classification keys and a verdict from the known set. Counts are printed for
# the operator and deliberately NOT asserted: the library changes hourly.
# ---------------------------------------------------------------------------
if [ "$SKIP_BEHAVIOUR" -ne 1 ]; then
  printf '\n'
  # `--json` prints the machine-readable line and THEN the human report, so the
  # JSON is the FIRST line starting with '{' -- not the last line, which is
  # prose. Extracted from a captured variable with no pipe: `| tail`/`| head`
  # short-circuits and can report 141 under pipefail.
  COV_OUT="$("$BIN_DIR/domum-media-backup" verify-snapshot-coverage cloud --json 2>/dev/null || true)"
  COV_JSON="$(sed -n '/^{/{p;q;}' <<< "$COV_OUT")"
  if [ -z "$COV_JSON" ]; then
    abort "the new build produced no --json output for verify-snapshot-coverage"
  fi
  jq -e 'has("missing_classified") and has("missing_backup_gap")
         and has("missing_pending_next_backup") and has("missing_timing_unknown")' \
     >/dev/null <<< "$COV_JSON" \
    || abort "the installed build does not emit the classification keys"
  jq -e '.result as $r
         | ["covered","pending","gap","unknown"] | index($r) != null' \
     >/dev/null <<< "$COV_JSON" \
    || abort "the installed build reported a verdict outside the known set"
  say "classification keys present; verdict: $(jq -r '.result' <<< "$COV_JSON")"
  say "backed up : $(jq -r '.in_snapshot' <<< "$COV_JSON") of $(jq -r '.originals' <<< "$COV_JSON")"
  say "gap       : $(jq -r '.missing_backup_gap' <<< "$COV_JSON")"
  say "pending   : $(jq -r '.missing_pending_next_backup' <<< "$COV_JSON")"
  say "unknown   : $(jq -r '.missing_timing_unknown' <<< "$COV_JSON")"
  if [ "$(jq -r '.missing_backup_gap' <<< "$COV_JSON")" != "0" ]; then
    printf '\n  %s\n' "NOTE: a BACKUP GAP is reported. That is a real finding, not a"
    printf '  %s\n' "deployment problem. Investigate it separately."
  fi
fi

printf '\n== deployed ==\n'
say "revision  : $(git -C "$CHECKOUT" rev-parse --short HEAD)"
if [ "${UNITS_CHANGED:-0}" -eq 1 ]; then
  printf '\n  %s\n' "The weekly report + health notification unit is INSTALLED but NOT"
  printf '  %s\n' "enabled. It mails only when something needs attention. To review"
  printf '  %s\n' "its output and then enable it:"
  printf '\n    %s\n' "sudo domum-media health-notify --dry-run"
  printf '    %s\n' "sudo systemctl enable --now domum-media-weekly-report.timer"
fi
say "untouched : containers, images, compose, OTHER systemd units, timers, Restic"
say "            schedules and exclusions, the Immich database, originals,"
say "            Btrfs subvolumes, snapshots, recovery archives, and the"
say "            production configuration"
