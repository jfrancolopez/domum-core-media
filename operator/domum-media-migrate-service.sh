#!/usr/bin/env bash
#
# domum-media — migrate ONE service directory to a Btrfs subvolume, and prove it.
#
#   sudo bash /home/jfranco/domum-media-migrate-service.sh <service>
#   sudo bash /home/jfranco/domum-media-migrate-service.sh <service> --preflight-only
#
# Generalised from the Jellyfin pilot, incorporating everything that run taught us:
#
#   * the pre-stop fingerprint is OBSERVATIONAL. A clean shutdown legitimately
#     writes (Jellyfin appended 743 bytes of shutdown log and ran a SQLite
#     optimize), and a restart writes again. Requiring them to match aborted a
#     perfect migration.
#   * the integrity claim is  .premigration == proof snapshot  -- two STATIC trees.
#   * the live tree is classified, not compared: a hard failure only if something
#     went MISSING; everything else reported and split into runtime state or not.
#   * application health is checked separately from byte-level verification.
#   * .premigration is retained. This script never deletes anything.
#
# See docs/MIGRATION-LIFECYCLE.md.

# WHY THIS LIVES IN THE REPOSITORY NOW. It carried two stale absolutes, which is
# the shape that has aborted three correct production states:
#
#   REVISION=d4734fc5...        pinned a revision that was superseded twice
#   case "$SVC" in
#     calibre-web|plex) ;;                     <- plex is migrated; this was wrong
#     jellyfin|kavita|navidrome) already ;;    <- a hardcoded list of live state
#
# A hardcoded list of which services are migrated is an absolute assertion about
# the storage topology. Every one of those has been true once and permanently
# false afterwards. The CLI already answers the question, so ask it.

set -u

# Production defaults. Overridable ONLY so this can be rehearsed against a
# disposable fixture; an unset environment gives exactly the production values.
REPO="${DOMUM_REPO:-/opt/domum-core-media}"
CLI="${DOMUM_CLI:-/usr/local/bin/domum-media}"
SNAPROOT="${DOMUM_SNAPSHOT_ROOT_OVERRIDE:-/srv/snapshots}"
DATAROOT="${DOMUM_DATA_ROOT_OVERRIDE:-/srv/data}"

SVC=""
PREFLIGHT_ONLY=0
EXPECT_REVISION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --expect-revision) EXPECT_REVISION="${2:-}"; shift 2 ;;
    -*) printf 'usage: %s <service> [--preflight-only] [--expect-revision <sha>]\n' "$0" >&2; exit 2 ;;
    *) SVC="$1"; shift ;;
  esac
done

abort() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
note()  { printf '  %s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

# Capabilities this migration needs, by behaviour.
NEEDED_CAPS="protection-state topology-verify verify-recovery-deep
service-migration migration-integrity-proof
migration-live-tree-classification recovery-point-identity"

[ -n "$SVC" ] || abort "usage: sudo bash $0 <service> [--preflight-only]"

SVC_PATH="$DATAROOT/$SVC"
PREMIG="$DATAROOT/$SVC.premigration"

[ "$(id -u)" -eq 0 ] || abort "must run as root: sudo bash $0 $SVC"
for c in git docker systemctl btrfs stat find sha256sum du df flock date sort readlink cut tr wc grep; do
  command -v "$c" >/dev/null 2>&1 || abort "required command not found: $c"
done

head2 "0. what is installed, and whether this service can be migrated at all"
PROD_HEAD="$(git -C "$REPO" rev-parse HEAD)" || abort "cannot read production HEAD"
if [ -n "$EXPECT_REVISION" ] && [ "$PROD_HEAD" != "$EXPECT_REVISION" ]; then
  abort "production is $PROD_HEAD, not the expected $EXPECT_REVISION."
fi
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
  || abort "tracked drift in $REPO; what is running is not what is committed"
# The check that actually matters: the binary being invoked is the one in the
# checkout whose revision was just printed. A revision pin alone says nothing
# about /usr/local/bin.
[ "$(sha256sum "$CLI" | cut -d' ' -f1)" \
  = "$(sha256sum "$REPO/bin/domum-media" | cut -d' ' -f1)" ] \
  || abort "$CLI does not match $REPO/bin/domum-media"
note "production HEAD = $PROD_HEAD; installed binary matches the checkout"

MISSING=""
for cap in $NEEDED_CAPS; do
  "$CLI" capabilities --has "$cap" >/dev/null 2>&1 || MISSING="$MISSING $cap"
done
[ -z "$MISSING" ] || abort "the installed CLI does not support:$MISSING"
note "required capabilities supported: $NEEDED_CAPS"

# ELIGIBILITY, asked of the CLI. `storage protection` prints the state word and
# exits 0 only when the service is already protected -- which is exactly the
# case that must NOT be migrated again.
PROT="$("$CLI" storage protection "$SVC" 2>/dev/null)"; PROT_RC=$?
case "$PROT" in
  unprotected)
    note "$SVC is '$PROT' -- an ordinary directory on the protected tier: migratable" ;;
  protected)
    abort "$SVC is already protected (a subvolume with at least one snapshot).
Nothing to migrate. This is read from the CLI rather than a hardcoded list,
because a list of which services are migrated is an absolute assertion about the
storage topology and goes stale the moment one more is done." ;;
  snapshottable)
    abort "$SVC is already a subvolume but has no snapshot. It does not need a
migration; it needs a snapshot. Investigate before proceeding." ;;
  degraded)
    abort "$SVC reports 'degraded' -- a nested subvolume would be omitted from
any snapshot of it. Migrating will not fix that; investigate first." ;;
  docker-volume)
    abort "$SVC keeps its durable state in a Docker volume, which a Btrfs
subvolume cannot hold. Migrating $DATAROOT/$SVC would protect nothing, because
the application does not write there. Its recovery point is taken with:
  sudo $CLI storage volume-pre-upgrade-point $SVC --archive-image" ;;
  stateless)
    abort "$SVC is declared to hold no durable state, so there is nothing to
migrate. If that is wrong, fix the declaration rather than working around this." ;;
  *)
    abort "the CLI reports $SVC protection as '${PROT:-unknown}' (exit $PROT_RC).
Failing closed: a migration must not proceed on an unclassified state." ;;
esac

# Content AND metadata. A file that cannot be hashed makes the comparison
# worthless silently, so it is a refusal -- Jellyfin's tree really does contain
# two files unreadable to a normal user.
fingerprint_strict() {
  local root="$1" listing unreadable
  listing="$(mktemp)" || abort "cannot create a temporary file"
  ( cd "$root" && find . -depth -print0 | sort -z | while IFS= read -r -d '' e; do
      printf '%s|%s|%s|%s|%s' "$(stat -c '%F' "$e")" "$(stat -c '%a' "$e")" \
        "$(stat -c '%u:%g' "$e")" "$(stat -c '%Y' "$e")" "$e"
      if [ -L "$e" ]; then printf '|-> %s' "$(readlink "$e")"
      elif [ -f "$e" ]; then
        h="$(sha256sum "$e" 2>/dev/null | cut -d' ' -f1)"
        if [ -z "$h" ]; then printf '|UNREADABLE'; else printf '|%s' "$h"; fi
      fi
      printf '\n'
    done ) > "$listing"
  unreadable="$(grep -c '|UNREADABLE$' "$listing" || true)"
  if [ "${unreadable:-0}" != "0" ]; then
    grep '|UNREADABLE$' "$listing" >&2
    rm -f "$listing"
    abort "$unreadable file(s) under $root could not be hashed; the comparison would prove nothing"
  fi
  sha256sum < "$listing" | cut -d' ' -f1
  rm -f "$listing"
}

head2 "1. preflight"
# Revision, drift and the installed-vs-checkout hash are stage 0's job; they are
# not repeated here. What follows is about the SERVICE.
# The behaviours this migration depends on, asked of the installed CLI as
# CAPABILITIES.
#
# This block used to be twenty `check_feature` calls grepping
# /usr/local/bin/domum-media for private function names -- and for literal code
# fragments like `running="$(docker ps` and `boundary}Z`. That is the exact
# pattern that aborted a correct production state once already, when a wrapper
# grepped for a function from a reverted refactor that had never existed.
# Twenty of them is twenty chances for a refactor to break a migration that
# would have worked.
#
# What those greps were really asserting is listed here as prose, because prose
# is what a human needs and a grep is not what a machine should check:
#
#   * a snapshot of ANOTHER service cannot authorise destroying this one
#   * a nested subvolume refuses, rather than silently omitting part of the tree
#   * the retention floor keeps a service's last recovery point from the prune
#   * the stop verification is SIGPIPE-proof, so a running container can never
#     be reported as stopped
#   * metadata verification covers ownership, permissions and symlink targets
#   * the migration asserts its own integrity claim: .premigration == proof
#     snapshot, plus database integrity
#   * `starting` is not `healthy`
#   * it refuses to DEPLOY a staged image as a side effect of moving data
#   * runtime state is preserved; a stopped container is still inspected
#   * recovery evidence is staged BEFORE the stop and bound atomically
#   * it records whether the image is RECOVERABLE, not merely identified
#   * the readiness window carries an explicit timezone
#   * the live tree is classified by the CLI, not by this script
#
# Each is covered by a test in the repository, which is where that belongs. The
# capability tokens below are the contract; stage 0 already checked them.

[ -d "$SVC_PATH" ] || abort "$SVC_PATH does not exist"
INODE="$(stat -c %i "$SVC_PATH")"
[ "$INODE" != "256" ] || abort "$SVC_PATH is ALREADY a Btrfs subvolume. Nothing to do."
[ ! -e "$PREMIG" ] || abort "$PREMIG already exists; investigate before migrating"
[ ! -e "${SVC_PATH}.new" ] || abort "${SVC_PATH}.new exists (interrupted attempt); investigate"
[ "$(stat -f -c %T "$DATAROOT")" = "btrfs" ] || abort "$DATAROOT is not Btrfs"
NESTED="$(find "$SVC_PATH" -xdev -mindepth 1 -type d -inum 256 2>/dev/null)"
[ -z "$NESTED" ] || abort "nested subvolume(s) under $SVC_PATH would be empty in its snapshot:
$NESTED"
note "$SVC_PATH is an ordinary directory (inode $INODE), no nesting, no leftovers"

AVAIL_KB="$(df --output=avail -k "$DATAROOT" | tail -1 | tr -d ' ')"
SIZE_B="$(du -sb --apparent-size "$SVC_PATH" | cut -f1)"
[ "$AVAIL_KB" -gt 1048576 ] || abort "less than 1 GiB free on $DATAROOT"
note "size $SIZE_B bytes; $(( AVAIL_KB / 1024 )) MiB free"

LOCK=/var/lib/domum-media/operation.lock
if [ -e "$LOCK" ]; then
  flock -n 9 9>>"$LOCK" || abort "another domum-media operation holds the lock:
$(cat "${LOCK}.holder" 2>/dev/null || echo unknown)"
  exec 9>&-
fi
note "operation lock is free"

# Day-aware: three of the four scheduled jobs are weekly, so a guard that fired
# every day would refuse while stating something untrue.
HOUR="$(date +%H)"; MIN="$(date +%M)"; DOW="$(date +%u)"
NOW=$(( 10#$HOUR * 60 + 10#$MIN ))
inw() { [ "$NOW" -ge "$1" ] && [ "$NOW" -le "$2" ]; }
inw 145 175 && abort "inside the nightly backup window (02:30 +15m)"
if [ "$DOW" = "7" ]; then
  inw 205 235 && abort "inside the weekly check window (Sun 03:30 +20m)"
  inw 265 295 && abort "inside the weekly snapshot-prune window (Sun 04:30 +20m)"
fi
[ "$DOW" = "1" ] && inw 340 400 && abort "inside the Monday host-upgrade window (05:45 +45m)"
note "outside every scheduled-job window ($(date '+%a %H:%M'))"

# The storage topology, before. Unlike a deployment, a migration is SUPPOSED to
# change this -- so the assertion afterwards is not "unchanged" but "exactly the
# change I intended, and nothing else". The inventory and the comparison come from
# the repository (domum-media storage topology), tested in CI; this script only
# says which difference it expects. An operator script must not carry its own copy
# of a project invariant: that is how the guard that aborted the b762fe8 deployment
# escaped review.
TOPOLOGY_CAPTURE="$(mktemp)" || abort "cannot create a temporary file"
"$CLI" storage topology > "$TOPOLOGY_CAPTURE" \
  || abort "cannot capture the storage topology"
grep -q '^# topology-format ' "$TOPOLOGY_CAPTURE" \
  || abort "the topology capture has no header; it could not be compared afterwards"
grep -q "^subvolume $SVC_PATH\$" "$TOPOLOGY_CAPTURE" \
  && abort "$SVC_PATH is already listed as a subvolume; nothing to do"
note "storage topology captured ($(grep -vc '^#' "$TOPOLOGY_CAPTURE") item(s))"

CONTAINERS_BEFORE="$(docker ps -q | wc -l)"
FAILED_BEFORE="$(systemctl --failed --no-legend --plain | wc -l)"
HEALTH_BEFORE="$(docker inspect "$SVC" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo unknown)"
note "containers=$CONTAINERS_BEFORE failed_units=$FAILED_BEFORE docker health before=$HEALTH_BEFORE"

head2 "2. database state before the migration"
# Recorded, not gated: the migration's own quiesce check is what refuses on a
# non-empty WAL AFTER the service stops. This is evidence for the operator about
# what the clean shutdown then had to do.
find "$SVC_PATH" \( -name '*-wal' -o -name '*-shm' -o -name '*-journal' \) \
  -printf '  %-58p %s bytes\n' 2>/dev/null || true
note "(a non-empty -wal here must clear on clean shutdown, or the migration refuses)"

head2 "3. baseline evidence (observational)"
BEFORE_FP="$(fingerprint_strict "$SVC_PATH")"
note "pre-stop fingerprint : $BEFORE_FP"
note "files/dirs           : $(find "$SVC_PATH" -type f | wc -l) / $(find "$SVC_PATH" -type d | wc -l)"
note "NOTE: this is observational. A clean shutdown legitimately changes it."

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  rm -f "$TOPOLOGY_CAPTURE"
  printf '\nPREFLIGHT ONLY — nothing was changed.\n'
  exit 0
fi

head2 "4. migration (the project implementation, unmodified)"
MIG_OUT="$(mktemp)" || abort "cannot create a temporary file"
# Every abort below this point exits without reaching the explicit rm.
trap 'rm -f "${MIG_OUT:-}"' EXIT
set +e
"$CLI" storage migrate-subvolume "$SVC" 2>&1 | tee "$MIG_OUT"
MIG_RC="${PIPESTATUS[0]}"
set -e
printf '\n  migrate-subvolume exit status: %s\n' "$MIG_RC"

head2 "5. verification"
[ -d "$SVC_PATH" ] || abort "CRITICAL: $SVC_PATH is missing. Look for $PREMIG."

if [ "$MIG_RC" -ne 0 ]; then
  note "inode is now $(stat -c %i "$SVC_PATH") (256 = migrated)"
  [ -d "$PREMIG" ] && note "pre-migration copy retained at $PREMIG"
  abort "migration did not complete cleanly. Read the output above; nothing was deleted."
fi

[ "$(stat -c %i "$SVC_PATH")" = "256" ] || abort "reported success but $SVC_PATH is not a subvolume"
[ "$(stat -c %d "$DATAROOT")" != "$(stat -c %d "$SVC_PATH")" ] \
  || abort "the new subvolume shares the parent st_dev; snapshot coverage depends on it differing"
note "now a Btrfs subvolume, distinct st_dev"

[ -d "$PREMIG" ] || abort "the pre-migration copy is missing from $PREMIG"
PRE_FP="$(fingerprint_strict "$PREMIG")"
PROOF="$(find "$SNAPROOT" -maxdepth 1 -name "${SVC}-*-post-migration" -printf '%f\n' 2>/dev/null | sort | tail -1)"
[ -n "$PROOF" ] || abort "no proof snapshot was created under $SNAPROOT"
[ "$(btrfs property get -ts "$SNAPROOT/$PROOF" 2>/dev/null)" = "ro=true" ] \
  || abort "the proof snapshot is not read-only"
PROOF_FP="$(fingerprint_strict "$SNAPROOT/$PROOF")"

# The implementation asserts this itself now (migrate_verify_recovery_point). If a
# future revision silently stops doing so, this notices -- a check that quietly
# disappears is worse than one that was never there.
# The CLI must have asserted its own integrity claim, and the assertion is made on
# DURABLE artefacts rather than on the wording of its summary.
#
# The previous version grepped for the literal string "recovery point  : verified".
# That wording changed when the summary was restructured into four separate claims,
# and this script aborted a migration that had completed perfectly -- a stale
# string assertion of exactly the kind the deploy script's topology invariant was.
# The exit status and the recovery-evidence file are contracts; prose is not.
if [ "$MIG_RC" -ne 0 ]; then
  abort "the CLI reported the migration as INCOMPLETE (exit $MIG_RC). Read its output above.
Nothing was deleted. Do not delete .premigration or the proof snapshot."
fi
RECOVERY_META="/var/lib/domum-media/snapshots/${PROOF}.recovery"
if [ ! -s "$RECOVERY_META" ]; then
  abort "the CLI reported success but wrote no recovery evidence at:
  $RECOVERY_META
A recovery point is the filesystem state AND the application that wrote it. Nothing
was deleted; investigate before relying on rollback for $SVC."
fi
# Re-verified with the CLI's own verifier, against the service and snapshot this
# run actually produced.
if ! VERIFY_OUT="$("$CLI" storage verify-recovery "$SVC" "$PROOF" 2>&1)"; then
  # The subcommand may not exist on older revisions; fall back to the structural
  # checks below rather than failing on its absence.
  case "$VERIFY_OUT" in
    *"Usage:"*|*"unknown"*) note "NOTE: this CLI has no 'storage verify-recovery'; checking the file directly" ;;
    *) abort "the recovery evidence for $PROOF did not verify: $VERIFY_OUT" ;;
  esac
fi
for k in FORMAT SERVICE RECOVERY_POINT CAPTURED_AT RUNTIME_STATE_BEFORE CONTAINER_1_SERVICE; do
  grep -q "^$k=" "$RECOVERY_META" || abort "recovery evidence is missing $k: $RECOVERY_META"
done
grep -q "^SERVICE='$SVC'\$" "$RECOVERY_META" \
  || abort "recovery evidence names the wrong service: $(grep '^SERVICE=' "$RECOVERY_META")"
grep -q "^RECOVERY_POINT='$PROOF'\$" "$RECOVERY_META" \
  || abort "recovery evidence names the wrong snapshot: $(grep '^RECOVERY_POINT=' "$RECOVERY_META")"
grep -qiE "password|secret|token|api[_-]?key|PRIVATE KEY" "$(grep -v '^#' "$RECOVERY_META" > /tmp/.rm.$$; echo /tmp/.rm.$$)" \
  && { rm -f /tmp/.rm.$$; abort "recovery evidence contains something secret-shaped"; }
rm -f /tmp/.rm.$$
note "the CLI asserted the integrity claim itself, and bound recovery evidence to $PROOF"
note "  $RECOVERY_META"

# ...and then re-derive it independently, with a different implementation. Same
# claim, different code: that is the point.
if [ "$PRE_FP" = "$PROOF_FP" ]; then
  note "INTEGRITY RE-PROVEN INDEPENDENTLY : .premigration == proof snapshot"
  note "  $PRE_FP"
else
  abort "CRITICAL: the preserved original and the proof snapshot differ.
  .premigration  : $PRE_FP
  proof snapshot : $PROOF_FP
Both trees are intact. Do NOT delete either."
fi

# The live-tree classification used to live HERE, in this script, with two
# defects that Plex is the first service to trigger:
#
#   1. `for f in $CHANGED $ADDED` word-splits. Measured: two real Plex paths
#      became ELEVEN fragments, and because `Server.2.log` matches `*.log` while
#      `Support/Plex` matches nothing, pieces of one path were classified
#      differently from each other. Any service whose paths contain spaces made
#      that review list meaningless.
#
#   2. Any snapshotted file missing from the live tree was an unconditional
#      abort. True enough for jellyfin, kavita and navidrome; FALSE for Plex,
#      which rotates `Plex Media Server.N.log` and prunes its own dated database
#      backups. It would have aborted a correct migration on log rotation -- the
#      same shape as the stale topology invariant.
#
# Both are fixed in the CLI, which now performs this as migration stage 10
# (migrate_classify_live_tree / migrate_report_live_tree) and is covered by
# tests/live-tree-classification-smoke.sh. Per the project rule, this script
# invokes the one implementation rather than carrying a second copy; the
# integrity claim above is still independently re-derived here, because that is a
# different claim and two implementations of it is the point.
note "live-tree classification: performed by the CLI (migration stage 10)"
note "  a LOST file makes the CLI's migration report it; this script asserts on its exit status"

head2 "6. application verification (separate from byte-level)"
docker ps --format '{{.Names}}' | grep -qFx "$SVC" || abort "$SVC is not running after the migration"
HEALTH_AFTER="$(docker inspect "$SVC" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo unknown)"
note "docker health: before=$HEALTH_BEFORE after=$HEALTH_AFTER"
[ "$HEALTH_AFTER" != "unhealthy" ] || abort "$SVC reports UNHEALTHY after the migration. Nothing was deleted."
if [ "$HEALTH_AFTER" = "starting" ]; then
  note "waiting up to 120s for the healthcheck to settle..."
  for _ in $(seq 1 24); do
    sleep 5
    HEALTH_AFTER="$(docker inspect "$SVC" --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
    [ "$HEALTH_AFTER" = "starting" ] || break
  done
  note "docker health settled to: $HEALTH_AFTER"
  [ "$HEALTH_AFTER" != "unhealthy" ] || abort "$SVC became UNHEALTHY. Nothing was deleted."
fi
[ "$HEALTH_AFTER" = "none" ] \
  && note "NOTE: no container healthcheck -- 'running' is all this proves. Exercise the app yourself."

# SQLite integrity, on a COPY, never against the live database.
# PARENTHESISED. `find p -name a -o -name b` binds the implicit -print to the
# last term only, so the first pattern's matches can be dropped silently.
DBS="$(find "$SVC_PATH" -xdev -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) 2>/dev/null | sort)"
if [ -n "$DBS" ] && command -v python3 >/dev/null 2>&1; then
  TMPDB="$(mktemp -d)"
  for db in $DBS; do
    cp "$db" "$TMPDB/probe.db" 2>/dev/null || continue
    res="$(python3 -c "
import sqlite3,sys
con=sqlite3.connect('file:$TMPDB/probe.db?mode=ro',uri=True)
print(con.execute('PRAGMA integrity_check').fetchone()[0], len(con.execute('PRAGMA foreign_key_check').fetchall()))
" 2>/dev/null || echo 'unchecked')"
    # The path, not the basename: kavita has config/kavita.db AND a copy under
    # config/backups/, so two different databases printed as the same line twice.
    note "sqlite ${db#"$SVC_PATH/"}: $res"
    case "$res" in ok*) ;; unchecked) ;; *) abort "$db failed its integrity check: $res" ;; esac
    rm -f "$TMPDB/probe.db"
  done
  rm -rf "$TMPDB"
fi

HC="$(docker inspect "$SVC" --format '{{if .Config.Healthcheck}}yes{{else}}no{{end}}' 2>/dev/null || echo no)"
if [ "$HC" = "yes" ]; then
  [ "$HEALTH_AFTER" = "healthy" ] \
    || abort "$SVC has a container healthcheck but its state is '$HEALTH_AFTER', not 'healthy'.
Nothing was deleted. This is the application-level signal $SVC was chosen for."
  note "application health: the container healthcheck PASSED after the migration"
else
  note "NOTE: $SVC has no container healthcheck; 'running' is all that is proven. Exercise it yourself."
fi
rm -f "$MIG_OUT"

head2 "7. nothing else moved"
[ "$(docker ps -q | wc -l)" = "$CONTAINERS_BEFORE" ] || abort "container count changed"

# The topology must have changed by EXACTLY two appearances: this service's
# subvolume, and its proof snapshot. Nothing may have disappeared, and no other
# service may have gained or lost anything. rc=0 here would mean the migration
# reported success without changing the topology at all.
set +e
TOPO_OUT="$("$CLI" storage topology --verify "$TOPOLOGY_CAPTURE" 2>&1)"
TOPO_RC=$?
set -e
printf '%s\n' "$TOPO_OUT" | sed 's/^/    /'
rm -f "$TOPOLOGY_CAPTURE"
case "$TOPO_RC" in
  1) : ;;
  0) abort "the storage topology is unchanged, but a migration must change it.
The verification above passed, so read it carefully before touching anything." ;;
  *) abort "the storage topology could not be compared (rc=$TOPO_RC). Investigate." ;;
esac
TOPO_DIFF="$(printf '%s\n' "$TOPO_OUT" | grep -E '^(APPEARED|DISAPPEARED) ' | sort)"
EXPECTED_DIFF="$(printf 'APPEARED    snapshot %s\nAPPEARED    subvolume %s\n' "$PROOF" "$SVC_PATH" | sort)"
if [ "$TOPO_DIFF" != "$EXPECTED_DIFF" ]; then
  printf -- '--- expected ---\n%s\n--- observed ---\n%s\n' "$EXPECTED_DIFF" "$TOPO_DIFF" >&2
  abort "the storage topology changed in a way this migration did not intend.
Nothing was deleted. Do NOT remove a snapshot or a .premigration directory to
reconcile this."
fi
note "topology changed by exactly the two intended additions, and nothing else"
[ "$(systemctl --failed --no-legend --plain | wc -l)" = "$FAILED_BEFORE" ] || abort "failed unit count changed"
# Protection, as a value rather than a sentence.
#
# This used to grep `domum-media report` for ": protected" / ": snapshottable" /
# ": degraded" and ABORT on the English -- the same dependency that aborted a
# completed migration when a summary line was reworded, except here it was a
# safety decision rather than a note.
set +e
PROT_STATE="$("$CLI" storage protection "$SVC" 2>&1)"
PROT_RC=$?
set -e
case "$PROT_RC:$PROT_STATE" in
  0:protected) note "protection: protected" ;;
  *:snapshottable) abort "protection is SNAPSHOTTABLE, not protected.
The data moved but no snapshot covers it. Nothing was deleted." ;;
  *:degraded) abort "protection is DEGRADED: a nested subvolume would be omitted
from any snapshot of $SVC_PATH. Nothing was deleted." ;;
  *:unprotected) abort "protection is UNPROTECTED: $SVC_PATH is not a subvolume,
although the migration reported success. Nothing was deleted." ;;
  *) abort "could not determine protection for $SVC (exit $PROT_RC): $PROT_STATE" ;;
esac
note "containers and units unchanged"

printf '\nMIGRATION COMPLETE for %s\n' "$SVC"
printf '  now a subvolume : %s\n' "$SVC_PATH"
printf '  proof snapshot  : %s/%s\n' "$SNAPROOT" "$PROOF"
printf '  previous state  : %s\n' "$PREMIG"
printf '\nNOTHING WAS DELETED. %s is the only independent copy of the pre-migration state.\n' "$PREMIG"
printf 'Exercise %s yourself, wait for one nightly backup, then remove it when satisfied:\n' "$SVC"
printf '  sudo rm -rf %s\n' "$PREMIG"
printf '\nSee docs/PREMIGRATION-LIFECYCLE.md for the evidence that should exist first.\n'
