#!/usr/bin/env bash
# Rehearse operator/domum-media-deploy-reporting-fixes.sh against a fake
# production tree. A wrapper that has only been read has not been tested.
#
# The roots are overridable ONLY for this, and they default to the production
# paths, so the rehearsal must not weaken a single check. The root check is
# satisfied by running under `unshare -r`, where the caller maps to uid 0 and
# `[ "$(id -u)" -eq 0 ]` runs exactly as written.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/operator/domum-media-deploy-reporting-fixes.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
unshare -r true 2>/dev/null || { echo "SKIP: unshare -r unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

UP="$TMP/upstream"; CO="$TMP/checkout"; BIN="$TMP/bin"; LIB="$TMP/lib"
mkdir -p "$UP" "$BIN" "$LIB"

# An upstream with two revisions: the second changes one of the three files.
git init -q -b main "$UP"
git -C "$UP" config user.email t@e; git -C "$UP" config user.name t
mkdir -p "$UP/bin"
for f in domum-media domum-media-backup domum-media-report; do
  printf '#!/usr/bin/env bash\necho old-%s\n' "$f" > "$UP/bin/$f"
  chmod +x "$UP/bin/$f"
done
# .gitignore belongs to the FIRST upstream commit, so the clone's history is a
# strict prefix of upstream's. Committing it in the clone instead made the
# checkout diverge, and the script correctly refused -- the fixture was wrong,
# not the check.
printf 'config/domum-media.conf\n' > "$UP/.gitignore"
git -C "$UP" add -A; git -C "$UP" commit -qm one
REV1="$(git -C "$UP" rev-parse HEAD)"
# The new build: emits classification JSON, as the real one does.
cat > "$UP/bin/domum-media-backup" <<'NEWBK'
#!/usr/bin/env bash
if [ "${1:-}" = "verify-snapshot-coverage" ]; then
  printf '%s\n' '{"result":"pending","originals":23125,"in_snapshot":23120,"missing_from_snapshot":5,"missing_backup_gap":0,"missing_pending_next_backup":5,"missing_timing_unknown":0,"missing_classified":"known"}'
  # The real command prints the human report AFTER the json line.
  printf '  result            : PENDING -- 5 await the next run\n'
  exit 3
fi
echo new-backup
NEWBK
chmod +x "$UP/bin/domum-media-backup"
git -C "$UP" add -A; git -C "$UP" commit -qm two
REV2="$(git -C "$UP" rev-parse HEAD)"

git clone -q "$UP" "$CO"
git -C "$CO" checkout -q "$REV1"
git -C "$CO" branch -qf main "$REV1" && git -C "$CO" checkout -q main
# Pre-install the OLD binaries, as production has them.
for f in domum-media domum-media-backup; do
  install -m 0755 "$CO/bin/$f" "$BIN/$f"
done
install -m 0755 "$CO/bin/domum-media-report" "$LIB/domum-media-report"
# Untracked, like the real production configuration: it must survive.
mkdir -p "$CO/config"; printf 'SECRET_LOOKING=value\n' > "$CO/config/domum-media.conf"

run() {  # rehearse as uid 0 without touching the host
  unshare -r env \
    DOMUM_DEPLOY_CHECKOUT="$CO" DOMUM_DEPLOY_BIN_DIR="$BIN" \
    DOMUM_DEPLOY_LIB_DIR="$LIB" DOMUM_DEPLOY_REMOTE=origin \
    bash "$SCRIPT" "$@" 2>&1
}

sect "the rehearsal really runs the root check as written"
grep -q '\[ "\$(id -u)" -eq 0 \]' "$SCRIPT" \
  || fail "the script no longer checks for root; the rehearsal proves nothing"
out="$(DOMUM_DEPLOY_CHECKOUT="$CO" DOMUM_DEPLOY_BIN_DIR="$BIN" \
       DOMUM_DEPLOY_LIB_DIR="$LIB" bash "$SCRIPT" 2>&1)"
grep -q 'must run as root' <<< "$out" || fail "a non-root run was not refused: $out"
echo "  refuses without root, and the check is unmodified"

sect "a DRY RUN changes nothing and names what would change"
before_bk="$(sha256sum "$BIN/domum-media-backup" | cut -d' ' -f1)"
before_rev="$(git -C "$CO" rev-parse HEAD)"
out="$(run)"
rc=$?
(( rc == 0 )) || fail "the dry run did not exit 0: $out"
grep -q 'DRY RUN' <<< "$out" || fail "it does not say it was a dry run: $out"
# A dry run must not describe the fast-forward in the indicative. It did, and
# the operator reasonably read it as "the checkout moved" when nothing had.
grep -q 'WOULD fast-forward' <<< "$out" \
  || fail "the dry run does not mark the fast-forward as hypothetical: $out"
grep -qE '^  fast-forward: ' <<< "$out" \
  && fail "the dry run claims a completed fast-forward: $out"
grep -qE 'bin/domum-media-backup .* INSTALL' <<< "$out" \
  || fail "the changed file is not named: $out"
grep -qE 'bin/domum-media-report .* unchanged' <<< "$out" \
  || fail "an unchanged file must be reported unchanged: $out"
[[ "$(sha256sum "$BIN/domum-media-backup" | cut -d' ' -f1)" == "$before_bk" ]] \
  || fail "the dry run installed something"
[[ "$(git -C "$CO" rev-parse HEAD)" == "$before_rev" ]] \
  || fail "the dry run moved the checkout"
echo "  nothing installed, checkout unmoved, changed and unchanged both named"

sect "--expect-revision refuses a revision that is not the target"
out="$(run --confirm --expect-revision=deadbeefdeadbeef)"
grep -q 'not the expected' <<< "$out" || fail "a wrong expected revision was accepted: $out"
[[ "$(git -C "$CO" rev-parse HEAD)" == "$before_rev" ]] \
  || fail "it moved the checkout after refusing"
echo "  refuses, and refuses BEFORE mutating anything"

sect "local changes in the checkout are never discarded"
printf 'operator edit\n' >> "$CO/bin/domum-media"
out="$(run --confirm)"
grep -q 'local changes' <<< "$out" || fail "a dirty checkout was not refused: $out"
grep -q 'will not discard work' <<< "$out" || fail "it does not say why: $out"
grep -q 'operator edit' "$CO/bin/domum-media" || fail "the local edit was destroyed"
git -C "$CO" checkout -q -- bin/domum-media
echo "  refuses on a dirty checkout and leaves the edit in place"

sect "a DIVERGED checkout is refused rather than rewritten"
git -C "$CO" -c user.email=t@e -c user.name=t commit -q --allow-empty -m divergent
out="$(run --confirm)"
grep -q 'NOT an ancestor' <<< "$out" \
  || fail "a diverged history was not refused: $out"
git -C "$CO" reset -q --hard "$REV1"
echo "  refuses when a fast-forward would be a rewrite"

sect "--confirm installs ONLY what differs, and verifies it"
out="$(run --confirm)"
rc=$?
grep -qE '^  fast-forward: ' <<< "$out" \
  || fail "the confirming run must state the fast-forward plainly: $out"
grep -q 'WOULD fast-forward' <<< "$out" \
  && fail "a confirmed run must not hedge: $out"
grep -q "installed $BIN/domum-media-backup" <<< "$out" \
  || fail "the changed binary was not installed: $out"
grep -q "installed $LIB/domum-media-report" <<< "$out" \
  && fail "an UNCHANGED file was reinstalled: $out"
grep -q 'verified domum-media-backup' <<< "$out" \
  || fail "it did not verify installed == checkout: $out"
[[ "$(sha256sum "$BIN/domum-media-backup" | cut -d' ' -f1)" \
   == "$(sha256sum "$CO/bin/domum-media-backup" | cut -d' ' -f1)" ]] \
  || fail "the installed binary does not match the checkout"
echo "  installed the changed file, skipped the unchanged, verified both"

sect "the untracked production configuration survived"
[[ -f "$CO/config/domum-media.conf" ]] || fail "the production config was removed"
grep -q 'SECRET_LOOKING=value' "$CO/config/domum-media.conf" \
  || fail "the production config was modified"
echo "  present and unmodified"

sect "the new build's classification keys are what it verifies"
grep -q 'classification keys present' <<< "$out" \
  || fail "the behaviour check did not run: $out"
grep -q 'verdict: pending' <<< "$out" || fail "the verdict was not read: $out"
grep -qE 'pending   : 5' <<< "$out" || fail "the pending count was not printed: $out"
grep -qE 'gap       : 0' <<< "$out" || fail "the gap count was not printed: $out"
echo "  reads the JSON contract, prints the counts, asserts neither"

sect "a build WITHOUT the classification keys is refused"
cat > "$UP/bin/domum-media-backup" <<'OLDBK'
#!/usr/bin/env bash
if [ "${1:-}" = "verify-snapshot-coverage" ]; then
  printf '%s\n' '{"result":"incomplete","originals":1,"in_snapshot":0,"missing_from_snapshot":1}'
  exit 1
fi
OLDBK
chmod +x "$UP/bin/domum-media-backup"
git -C "$UP" add -A; git -C "$UP" -c user.email=t@e -c user.name=t commit -qm regress
out="$(run --confirm)"
grep -q 'does not emit the classification keys' <<< "$out" \
  || fail "a build without the classification was accepted: $out"
echo "  a regressed build fails the deployment's own behaviour check"

sect "a reported BACKUP GAP is a finding, not a deployment failure"
cat > "$UP/bin/domum-media-backup" <<'GAPBK'
#!/usr/bin/env bash
if [ "${1:-}" = "verify-snapshot-coverage" ]; then
  printf '%s\n' '{"result":"gap","originals":10,"in_snapshot":8,"missing_from_snapshot":2,"missing_backup_gap":2,"missing_pending_next_backup":0,"missing_timing_unknown":0,"missing_classified":"known"}'
  printf '  result            : BACKUP GAP -- 2 originals\n'
  exit 1
fi
GAPBK
chmod +x "$UP/bin/domum-media-backup"
git -C "$UP" add -A; git -C "$UP" -c user.email=t@e -c user.name=t commit -qm gap
out="$(run --confirm)"; rc=$?
grep -q 'a BACKUP GAP is reported' <<< "$out" \
  || fail "a gap was not surfaced to the operator: $out"
grep -q 'not a$\|not a' <<< "$out" || fail "it does not distinguish the two: $out"
grep -q '== deployed ==' <<< "$out" \
  || fail "a gap must not fail the DEPLOYMENT, only be reported: $out"
echo "  the gap is reported and the deployment still completes"

echo "PASS: deploy-reporting-rehearsal"
