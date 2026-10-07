#!/usr/bin/env bash
#
# domum-media — upgrade Plex, with an INDEPENDENT witness around the CLI.
#
#   sudo bash /home/jfranco/domum-media-upgrade-plex.sh [options]
#
#     --preflight-only          run every check, change nothing, exit 0
#     --expect-revision <sha>   require production HEAD to equal this revision
#
# The CLI does the work: lock, backup freshness, pre-upgrade recovery point,
# image archive, archive verification, Plex-only deployment, verification and the
# cleanup dry run. This script does NOT reimplement any of that. What it adds is
# a second opinion, derived differently -- all eleven container identities
# captured and compared HERE, the archive re-derived from the metadata and
# re-checksummed, the cleanup decision re-read.
#
# WHY THIS SCRIPT LIVES IN THE REPOSITORY.
#
# Three operator wrappers have now aborted correct production states, each by
# asserting on something that was never a contract:
#
#   1. a stale topology invariant ("no subvolumes exist") -- true before the
#      first migration, permanently false after it;
#   2. a grep for the prose line `recovery point  : verified` -- the wording
#      changed when the summary was split into four claims;
#   3. a grep for `make_pre_upgrade_point()` in the installed binary -- a
#      private function from a refactor that was attempted and reverted, so it
#      had never existed in any merged revision.
#
# All three escaped review because operator scripts were not in the repository
# and therefore not in CI. This one is, and tests/operator-wrapper-audit.py
# fails if a private function name or a CLI prose string is asserted on again.
#
# THE RULES THIS SCRIPT FOLLOWS
#   * capability questions go to `domum-media capabilities --has <token>`;
#   * machine-readable state comes from `--json`, never from parsing prose;
#   * everything else is asserted on exit status, on files, or on docker/btrfs/
#     systemd output, which are stable external contracts.
#
# No global `set -e`: several expected states return nonzero. Every step is
# checked explicitly.

set -u

# Production defaults. Overridable ONLY so this script can be rehearsed against
# a disposable production-shaped fixture before it is ever pointed at the real
# host -- which is the point of it living in the repository. An unset
# environment gives exactly the production values.
REPO="${DOMUM_REPO:-/opt/domum-core-media}"
CLI="${DOMUM_CLI:-/usr/local/bin/domum-media}"
SVC="${DOMUM_SVC:-plex}"
DATA_ROOT="${DOMUM_DATA_ROOT_OVERRIDE:-/srv/data}"
SNAPSHOT_ROOT="${DOMUM_SNAPSHOT_ROOT_OVERRIDE:-/srv/snapshots}"
STATE_ROOT="${DOMUM_STATE_ROOT_OVERRIDE:-/var/lib/domum-media}"
SVC_PATH="$DATA_ROOT/$SVC"
EXPECT_CONTAINERS="${DOMUM_EXPECT_CONTAINERS:-11}"
PREFLIGHT_ONLY=0
EXPECT_REVISION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --expect-revision) EXPECT_REVISION="${2:-}"; shift 2 ;;
    *) printf 'usage: %s [--preflight-only] [--expect-revision <sha>]\n' "$0" >&2; exit 2 ;;
  esac
done

abort() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
note()  { printf '  %s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

# Capabilities this upgrade needs. Semantic tokens, not function names: the
# implementation may be refactored freely as long as the behaviour remains.
NEEDED_CAPS="service-scoped-upgrade pre-upgrade-point archive-image
verify-image-archive rollback-upgrade recovery-image-protection
machine-readable-cleanup-images protection-state"

identities() {  # all container identities, one per line, sorted
  docker ps -a --format '{{.Names}}' | LC_ALL=C sort | while IFS= read -r c; do
    printf '%s %s %s\n' "$c" \
      "$(docker inspect -f '{{.Id}}' "$c" 2>/dev/null)" \
      "$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
  done
}

# Is this image a cleanup deletion candidate, per the STRUCTURED interface?
# Never `cleanup images | grep`: that is parsing a human report.
cleanup_says_candidate() {  # $1 = full image id -> 0 if candidate
  local json
  json="$("$CLI" cleanup images --json 2>/dev/null)" || return 2
  printf '%s' "$json" \
    | jq -e --arg id "$1" '.images[] | select(.id == $id) | .candidate' >/dev/null 2>&1
}

cleanup_knows() {  # $1 = full image id -> 0 if present in the record set
  local json
  json="$("$CLI" cleanup images --json 2>/dev/null)" || return 2
  printf '%s' "$json" \
    | jq -e --arg id "$1" 'any(.images[]; .id == $id)' >/dev/null 2>&1
}

[ "$(id -u)" -eq 0 ] || abort "must run as root: sudo bash $0"
command -v jq >/dev/null 2>&1 || abort "jq is required to read the structured cleanup output"

head2 "1. what is installed is what is in the production checkout"
PROD_HEAD="$(git -C "$REPO" rev-parse HEAD)" || abort "cannot read production HEAD"
if [ -n "$EXPECT_REVISION" ] && [ "$PROD_HEAD" != "$EXPECT_REVISION" ]; then
  abort "production is $PROD_HEAD, not the expected $EXPECT_REVISION.
Deploy the reviewed revision first."
fi
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
  || abort "tracked drift in $REPO; what is running is not what is committed"
# This is the check that actually matters: the binary being invoked is the one
# in the checkout whose revision was just printed. A revision pin alone proves
# nothing about /usr/local/bin.
[ "$(sha256sum "$CLI" | cut -d' ' -f1)" \
  = "$(sha256sum "$REPO/bin/domum-media" | cut -d' ' -f1)" ] \
  || abort "$CLI does not match $REPO/bin/domum-media"
note "production HEAD = $PROD_HEAD"
note "no tracked drift; installed binary matches the checkout"

head2 "2. the installed CLI supports what this upgrade needs"
# Behaviour, asked of the binary itself. NOT a grep for private function names:
# that is what aborted a correct production state once already.
"$CLI" capabilities >/dev/null 2>&1 \
  || abort "the installed CLI has no 'capabilities' command, so its supported
behaviour cannot be established. Deploy a revision that provides it."
MISSING=""
for cap in $NEEDED_CAPS; do
  "$CLI" capabilities --has "$cap" >/dev/null 2>&1 || MISSING="$MISSING $cap"
done
[ -z "$MISSING" ] \
  || abort "the installed CLI does not support:$MISSING
Deploy a revision that does before upgrading."
note "all $(printf '%s' "$NEEDED_CAPS" | wc -w) required capabilities supported"

head2 "3. Plex, and the two images"
docker inspect "$SVC" >/dev/null 2>&1 || abort "$SVC is not present"
OLD_CID="$(docker inspect -f '{{.Id}}' "$SVC")"
OLD_IMG="$(docker inspect -f '{{.Image}}' "$SVC")"
OLD_CREATED="$(docker inspect -f '{{.Created}}' "$SVC")"
OLD_STATE="$(docker inspect -f '{{.State.Status}}' "$SVC")"
TAG="$(docker inspect -f '{{.Config.Image}}' "$SVC")"
NEW_IMG="$(docker image inspect -f '{{.Id}}' "$TAG" 2>/dev/null)" \
  || abort "the tag $TAG is not present locally; nothing is staged to deploy"
[ "$OLD_IMG" != "$NEW_IMG" ] \
  || abort "$SVC already runs what $TAG resolves to; there is nothing to upgrade"
[ "$OLD_STATE" = "running" ] \
  || abort "$SVC is '$OLD_STATE', not running. A migration or upgrade preserves
runtime state, and this script was written for the running case."
note "container   : ${OLD_CID:0:12}  created $OLD_CREATED"
note "old image   : ${OLD_IMG:0:19}  $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$OLD_IMG" 2>/dev/null)"
note "new image   : ${NEW_IMG:0:19}  $(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$NEW_IMG" 2>/dev/null)"

head2 "4. protection and capacity preconditions"
# TWO independent judgments, because one implementation checking itself is not
# a second opinion.
#
# (a) The filesystem fact, read here: a Btrfs subvolume root is inode 256. The
#     expected value is overridable only so this script can be rehearsed on an
#     ordinary filesystem; production leaves it at 256.
EXPECT_INODE="${DOMUM_EXPECT_INODE:-256}"
[ "$(stat -c %i "$SVC_PATH")" = "$EXPECT_INODE" ] \
  || abort "$SVC_PATH is not a Btrfs subvolume (inode $(stat -c %i "$SVC_PATH"), expected
$EXPECT_INODE); no pre-upgrade snapshot could be taken"
note "$SVC_PATH is a subvolume (inode $EXPECT_INODE)"
# (b) The CLI's own verdict, by EXIT STATUS. `storage protection` prints the
#     state word and exits 0 only when it is `protected`, which is exactly why
#     it exists -- so a script tests the command instead of matching its prose.
PROT="$("$CLI" storage protection "$SVC" 2>/dev/null)"; PROT_RC=$?
[ "$PROT_RC" -eq 0 ] \
  || abort "the CLI reports $SVC protection as '${PROT:-unknown}' (exit $PROT_RC), not
protected. It would refuse the upgrade, and this script agrees with it."
note "the CLI independently reports protection: $PROT" 
WAL="$(find "$SVC_PATH" -xdev -type f -name '*-wal' -printf '%s %p\n' 2>/dev/null | sort -rn | head -1)"
note "largest live WAL: ${WAL:-none} (the CLI stops and re-checks after the stop)"
AVAIL_MIB=$(( $(df --output=avail -k "$DATA_ROOT" | tail -1 | tr -d ' ') / 1024 ))
IMG_MIB=$(( $(docker image inspect -f '{{.Size}}' "$OLD_IMG") / 1024 / 1024 ))
note "archive needs <= ${IMG_MIB} MiB; ${AVAIL_MIB} MiB free on $DATA_ROOT"
[ "$AVAIL_MIB" -gt $(( IMG_MIB * 2 )) ] || abort "not enough room for the image archive"

head2 "5. independent baseline: ALL container identities"
BEFORE="$(mktemp)"; AFTER="$(mktemp)"
trap 'rm -f -- "$BEFORE" "$AFTER"' EXIT
identities > "$BEFORE"
N_BEFORE="$(wc -l < "$BEFORE")"
note "captured $N_BEFORE container identities"
[ "$N_BEFORE" -eq "$EXPECT_CONTAINERS" ] \
  || abort "expected $EXPECT_CONTAINERS containers, found $N_BEFORE. Investigate
before upgrading: the scope proof compares this set before and after."
# The old image must be protected AFTERWARDS. Record whether cleanup can even
# see it now, so "protected after" cannot be confused with "never considered".
cleanup_says_candidate "$OLD_IMG"; CAND_RC=$?
case "$CAND_RC" in
  0) note "NOTE: the old image is currently a cleanup candidate (no recovery point"
     note "      names it yet). The upgrade is what creates that protection." ;;
  1) note "the old image is not currently a cleanup candidate" ;;
  # rc 2 means the QUERY failed, which is not the same as "not a candidate".
  # Reading a failed query as reassurance is the shape of defect this project
  # keeps finding; the post-upgrade check below treats it as fatal.
  *) note "WARNING: could not read the structured cleanup records (exit $CAND_RC)."
     note "         Nothing can be concluded about the old image's protection yet." ;;
esac

if [ "$PREFLIGHT_ONLY" = 1 ]; then
  printf '\nPREFLIGHT ONLY — every check above passed and nothing was changed.\n'
  printf 'To upgrade:  sudo bash %s%s\n' "$0" \
    "$([ -n "$EXPECT_REVISION" ] && printf ' --expect-revision %s' "$EXPECT_REVISION")"
  exit 0
fi

head2 "6. the upgrade (the project implementation, unmodified)"
"$CLI" updates apply --service "$SVC"
RC=$?
note "updates apply --service $SVC exit status: $RC"

head2 "7. independent verification"
NOW_IMG="$(docker inspect -f '{{.Image}}' "$SVC" 2>/dev/null || true)"
NOW_CID="$(docker inspect -f '{{.Id}}' "$SVC" 2>/dev/null || true)"

# ---- FAILED BEFORE DEPLOYMENT ---------------------------------------------
# Distinguish "refused and changed nothing" from "ran and something is wrong".
# Both exit non-zero, and reporting the first as a verification failure would
# read as alarming when it is the gate working.
if [ "$RC" -ne 0 ] && [ "$NOW_IMG" = "$OLD_IMG" ]; then
  note "$SVC is still on its original image, so the upgrade refused before deploying."
  note "That is the protection working, not a failed upgrade."
  [ "$NOW_CID" = "$OLD_CID" ] \
    && note "the container object is also unchanged (${OLD_CID:0:12})" \
    || abort "$SVC was recreated despite not being upgraded"
  [ "$(docker inspect -f '{{.State.Status}}' "$SVC" 2>/dev/null)" = "running" ] \
    || abort "$SVC is NOT running after a refusal. It must be returned to service:
  sudo docker compose -f $REPO/compose/base.yml start $SVC
Nothing was deleted; read the CLI output above."
  identities > "$AFTER"
  if ! diff -q "$BEFORE" "$AFTER" >/dev/null; then
    diff "$BEFORE" "$AFTER" >&2
    abort "the upgrade refused, but containers changed anyway"
  fi
  note "all $N_BEFORE container identities unchanged; $SVC still running"
  printf '\nUPGRADE DID NOT PROCEED. Nothing was changed. Read the CLI output above.\n'
  exit "$RC"
fi

# ---- DEPLOYED: verify, and never improvise --------------------------------
identities > "$AFTER"
CHANGED="$(diff <(grep -v "^$SVC " "$BEFORE") <(grep -v "^$SVC " "$AFTER") || true)"
if [ -n "$CHANGED" ]; then
  printf '%s\n' "$CHANGED" >&2
  abort "a NON-PLEX container changed. This was supposed to be a $SVC-only upgrade."
fi
note "the other $(( N_BEFORE - 1 )) containers are unchanged (id and image)"

[ "$NOW_IMG" = "$NEW_IMG" ] \
  || abort "$SVC is running $NOW_IMG, not the intended $NEW_IMG"
note "$SVC is running the intended staged image"

# The pre-upgrade point, found by kind rather than by guessing its name.
# A glob, not `ls | grep`: snapshot names are timestamped YYYYMMDD-HHMMSS, so
# lexical order is chronological and the last match is the newest.
POINT=""
for _d in "$SNAPSHOT_ROOT/$SVC"-*-pre-upgrade; do
  [ -d "$_d" ] || continue
  POINT="${_d##*/}"
done
[ -n "$POINT" ] || abort "no ${SVC}-*-pre-upgrade snapshot exists; the recovery point
was not created, yet the staged image is deployed. Do NOT run cleanup."
note "pre-upgrade point: $POINT"
[ "$(btrfs property get -ts "$SNAPSHOT_ROOT/$POINT" | tr -d ' ')" = "ro=true" ] \
  || abort "$POINT is not read-only"
META="$STATE_ROOT/snapshots/$POINT.recovery"
[ -s "$META" ] || abort "no recovery evidence at $META"
note "$POINT is read-only and has recovery evidence"

# The CLI has its own verifier; invoke it rather than re-deriving its verdict
# from prose. Exit status is the contract.
"$CLI" storage verify-archive "$POINT" >/dev/null 2>&1 \
  || abort "the CLI's own archive verification failed for $POINT"
note "storage verify-archive $POINT: exit 0"

# And re-derive it independently, because one implementation checking itself is
# not a second opinion.
ARCH="$(sed -nE "s/^IMAGE_ARCHIVE='(.*)'\$/\1/p" "$META" | head -1)"
WANT_SHA="$(sed -nE "s/^IMAGE_ARCHIVE_SHA256='(.*)'\$/\1/p" "$META" | head -1)"
REC_IMG="$(sed -nE "s/^CONTAINER_1_IMAGE_ID='(.*)'\$/\1/p" "$META" | head -1)"
[ -n "$ARCH" ] || abort "the recovery evidence names no image archive"
[ -r "$ARCH" ] || abort "the archive $ARCH is missing"
[ "$(sha256sum "$ARCH" | cut -d' ' -f1)" = "$WANT_SHA" ] \
  || abort "the archive checksum does not match the recorded $WANT_SHA"
[ "$REC_IMG" = "$OLD_IMG" ] \
  || abort "the recovery evidence records $REC_IMG but $SVC was running $OLD_IMG"
note "archive verifies independently, and pairs with the image that was running"

# The metadata-only cleanup proof, read from the STRUCTURED interface. The old
# image is no longer used by any container, so only the recovery metadata can
# protect it now.
IN_USE="$(docker ps -aq --filter ancestor="$OLD_IMG" | wc -l)"
note "old image now used by $IN_USE container(s)"
cleanup_knows "$OLD_IMG" \
  || abort "the old image $OLD_IMG does not appear in the cleanup records at all,
so nothing here can establish that it is protected. Do NOT run cleanup --confirm."
if cleanup_says_candidate "$OLD_IMG"; then
  abort "the old image $OLD_IMG is a cleanup DELETION CANDIDATE although a recovery
point depends on it. Do NOT run cleanup --confirm."
fi
note "old image present in the cleanup records and NOT a candidate"

[ "$(systemctl --failed --no-legend --plain | wc -l)" = "0" ] || abort "failed systemd units appeared"
[ "$(systemctl is-enabled domum-media-image-refresh.timer 2>&1)" = "disabled" ] \
  || abort "the image-refresh timer is no longer disabled"
note "0 failed units; image refresh still disabled"

printf '\n'
if [ "$RC" -eq 0 ]; then
  printf 'PLEX UPGRADED and independently verified.\n'
  printf '  %s -> %s\n' "${OLD_IMG:0:19}" "${NEW_IMG:0:19}"
  printf '  rollback: sudo %s rollback-upgrade %s %s\n' "$CLI" "$SVC" "$POINT"
  exit 0
fi

# Deployed, and the CLI reported a problem. This script does NOT roll back on
# its own: a rollback is itself a stop/restore/recreate, and guessing when to
# perform one is how "warn and continue" caused harm twice before. The complete
# rollback material is present and named, so the decision is the operator's.
printf 'The CLI reported a problem (exit %s) AFTER deploying. The independent\n' "$RC"
printf 'checks above passed, so the rollback material is complete:\n'
printf '  recovery point : %s (read-only)\n' "$POINT"
printf '  image archive  : %s (checksum verified)\n' "$ARCH"
printf '  records image  : %s\n' "$REC_IMG"
printf '\nNothing was deleted. Read the CLI output above, then either keep the new\n'
printf 'build or roll both halves back:\n'
printf '  sudo %s rollback-upgrade %s %s\n' "$CLI" "$SVC" "$POINT"
exit "$RC"
