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
UNITS="$TMP/units"
mkdir -p "$UP" "$BIN" "$LIB" "$UNITS"

# An upstream with two revisions: the second changes one of the three files.
git init -q -b main "$UP"
git -C "$UP" config user.email t@e; git -C "$UP" config user.name t
mkdir -p "$UP/bin" "$UP/systemd" "$UP/operator"
# The script must exist in the FIRST commit: git does not commit an empty
# directory, so without this the checkout has no operator/ copy and the
# self-replacement check has nothing to compare against.
cp "$SCRIPT" "$UP/operator/domum-media-deploy-reporting-fixes.sh"
printf '[Unit]\nDescription=weekly\n[Service]\nExecStart=/bin/true\n' \
  > "$UP/systemd/domum-media-weekly-report.service"
printf '[Unit]\nDescription=weekly\n[Timer]\nOnCalendar=Sun *-*-* 08:00:00\n' \
  > "$UP/systemd/domum-media-weekly-report.timer"
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
# The weekly unit gains the notify step, which is what makes installing it the
# thing that enables the FEATURE (not the timer).
printf '[Unit]\nDescription=weekly\n[Service]\nExecStart=/bin/true\nExecStart=-/bin/true\n' \
  > "$UP/systemd/domum-media-weekly-report.service"
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
install -m 0644 "$CO/systemd/domum-media-weekly-report.service" "$UNITS/"
install -m 0644 "$CO/systemd/domum-media-weekly-report.timer" "$UNITS/"
# Untracked, like the real production configuration: it must survive.
mkdir -p "$CO/config"; printf 'SECRET_LOOKING=value\n' > "$CO/config/domum-media.conf"

# systemd is not reachable inside `unshare -r`, so a real `daemon-reload` fails
# and the script aborts -- correctly. The sandbox provides the external
# dependency, exactly as it provides a fake git upstream, and RECORDS the call
# so the reload can be asserted rather than assumed. The script's own check is
# not weakened: a failing reload is still fatal.
mkdir -p "$TMP/stub"
# The stub RECORDS every call and can also ANSWER the two queries the script
# makes about the timer. `is-enabled` is a query, so answering it is providing
# an external dependency rather than weakening a check -- the same reason this
# rehearsal supplies a systemctl at all. With the variables unset it answers
# nothing, which is the "could not tell" case.
cat > "$TMP/stub/systemctl" <<'SYSCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSCTL_LOG:?}"
case "${1:-}" in
  is-enabled) [ -n "${SYSCTL_IS_ENABLED:-}" ] && printf '%s\n' "$SYSCTL_IS_ENABLED" ;;
  show)       [ -n "${SYSCTL_NEXT_ELAPSE:-}" ] && printf '%s\n' "$SYSCTL_NEXT_ELAPSE" ;;
esac
exit 0
SYSCTL
chmod +x "$TMP/stub/systemctl"
# docker is ANSWERED, never reached: the live-mount gate asks which running
# containers bind-mount what. Unset variables answer "no containers", which is
# what every section before the live-mount ones needs. DOCKER_FAIL makes the
# daemon unreachable, to prove the gate fails closed.
cat > "$TMP/stub/docker" <<'DOCKER'
#!/usr/bin/env bash
[ -n "${DOCKER_FAIL:-}" ] && exit 1
case "${1:-}" in
  ps)      [ -n "${DOCKER_IDS:-}" ] && printf '%s\n' "$DOCKER_IDS" ;;
  inspect) [ -n "${DOCKER_MOUNTS:-}" ] && printf '%b' "$DOCKER_MOUNTS" ;;
esac
exit 0
DOCKER
chmod +x "$TMP/stub/docker"
export SYSCTL_LOG="$TMP/systemctl.log"
: > "$SYSCTL_LOG"

run() {  # rehearse as uid 0 without touching the host
  unshare -r env \
    PATH="$TMP/stub:$PATH" SYSCTL_LOG="$SYSCTL_LOG" \
    SYSCTL_IS_ENABLED="${SYSCTL_IS_ENABLED:-}" \
    SYSCTL_NEXT_ELAPSE="${SYSCTL_NEXT_ELAPSE:-}" \
    DOCKER_IDS="${DOCKER_IDS:-}" DOCKER_MOUNTS="${DOCKER_MOUNTS:-}" \
    DOCKER_FAIL="${DOCKER_FAIL:-}" \
    DOMUM_DEPLOY_CHECKOUT="$CO" DOMUM_DEPLOY_BIN_DIR="$BIN" \
    DOMUM_DEPLOY_LIB_DIR="$LIB" DOMUM_DEPLOY_UNIT_DIR="$UNITS" \
    DOMUM_DEPLOY_REMOTE=origin \
    bash "${RUN_SCRIPT:-$SCRIPT}" "$@" 2>&1
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

sect "the weekly unit is INSTALLED 0644, and NOTHING is enabled or started"
# Installing the unit is what makes the notification available; enabling the
# timer is what starts sending mail, and that stays the operator's decision.
grep -q "installed $UNITS/domum-media-weekly-report.service (not enabled, not started)" <<< "$out" \
  || fail "the weekly unit was not installed: $out"
[[ "$(stat -c %a "$UNITS/domum-media-weekly-report.service")" == "644" ]] \
  || fail "a unit must be 0644, got $(stat -c %a "$UNITS/domum-media-weekly-report.service")"
[[ "$(sha256sum "$UNITS/domum-media-weekly-report.service" | cut -d" " -f1)" \
   == "$(sha256sum "$CO/systemd/domum-media-weekly-report.service" | cut -d" " -f1)" ]] \
  || fail "the installed unit does not match the checkout"
grep -q 'no unit was enabled or started' <<< "$out" \
  || fail "it does not state that nothing was enabled: $out"
grep -qx 'daemon-reload' "$SYSCTL_LOG" \
  || fail "systemd was never reloaded, so it has not seen the new unit: $(cat "$SYSCTL_LOG")"
grep -qE '^(enable|start|restart)' "$SYSCTL_LOG" \
  && fail "the deployment enabled or started a unit: $(cat "$SYSCTL_LOG")"
grep -qE 'systemctl (enable|start|restart) ' <<< \
  "$(grep -v '^ *#' "$SCRIPT" | grep -v 'printf')" \
  && fail "the deployment script itself enables or starts a unit"
grep -q 'systemctl enable --now domum-media-weekly-report.timer' <<< "$out" \
  || fail "it does not tell the operator how to enable it deliberately: $out"
echo "  installed 0644, matches the checkout, nothing enabled, remedy offered"

sect "an UNCHANGED unit is not reinstalled"
out2="$(run --confirm)"
grep -q 'installed .*domum-media-weekly-report' <<< "$out2" \
  && fail "an unchanged unit was reinstalled: $out2"
echo "  skipped on a second run"

# Installing the unit is INERT only when the timer is off. On a host whose
# timer is already enabled -- which production's is, and has been since
# 2026-10-20 -- the new ExecStart lines run at the next firing and the first of
# them MAILS the report. The old message asserted "INSTALLED but NOT enabled"
# unconditionally, so it described a state that host is not in, at the one
# moment the operator decides whether to expect mail. Both branches are driven,
# because a message that always says the same thing cannot be right about both.
sect "an ALREADY-ENABLED timer is reported as such, and not as not-enabled"
printf '\n# perturbed so the unit differs and is reinstalled\n' \
  >> "$UNITS/domum-media-weekly-report.service"
out3="$(SYSCTL_IS_ENABLED=enabled SYSCTL_NEXT_ELAPSE='Sun 2026-11-22 08:14:26 EST' run --confirm)"
grep -q 'timer was ALREADY enabled before this run' <<< "$out3" \
  || fail "an already-enabled timer was not reported as such: $out3"
grep -q 'INSTALLED but NOT' <<< "$out3" \
  && fail "it still claims the timer is not enabled: $out3"
grep -q 'next firing: Sun 2026-11-22 08:14:26 EST' <<< "$out3" \
  || fail "it does not say when the new lines first take effect: $out3"
grep -q 'mails the weekly report whether or not anything is wrong' <<< "$out3" \
  || fail "it does not say the first ExecStart sends mail regardless: $out3"
grep -q 'report weekly --stdout' <<< "$out3" \
  || fail "it offers no way to preview what will be sent: $out3"
# It still must not have enabled or started anything itself.
grep -qE '^(enable|start|restart)' "$SYSCTL_LOG" \
  && fail "the deployment enabled or started a unit: $(cat "$SYSCTL_LOG")"
echo "  says ALREADY enabled, names the firing, offers a preview, enables nothing"

sect "a timer that is NOT enabled still gets the deliberate-enable remedy"
printf '\n# perturbed again\n' >> "$UNITS/domum-media-weekly-report.service"
out4="$(SYSCTL_IS_ENABLED=disabled run --confirm)"
grep -q 'INSTALLED but NOT' <<< "$out4" \
  || fail "a disabled timer was not reported as not enabled: $out4"
grep -q 'systemd reports: disabled' <<< "$out4" \
  || fail "it does not quote what systemd actually said: $out4"
grep -q 'systemctl enable --now domum-media-weekly-report.timer' <<< "$out4" \
  || fail "the enable remedy is gone: $out4"
grep -q 'timer was ALREADY' <<< "$out4" \
  && fail "a disabled timer was reported as already enabled: $out4"
echo "  reports not-enabled, quotes systemd, offers the enable command"

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

# An UNKNOWN reply is the build ANSWERING. `verify-snapshot-coverage` emits
# target/snapshot/result/reason and nothing else when the snapshot could not be
# listed -- a locked or unreachable repository -- so demanding the
# classification keys there would abort a deployment whose install had already
# completed and verified, and blame the binary for the repository. The counts
# are the part that must still be demanded when a real verdict comes back,
# which the section above pins.
sect "an UNKNOWN coverage verdict is a finding, not a build regression"
cat > "$UP/bin/domum-media-backup" <<'UNKBK'
#!/usr/bin/env bash
if [ "${1:-}" = "verify-snapshot-coverage" ]; then
  printf '%s\n' '{"target":"cloud","snapshot_id":"deadbeef","result":"unknown","reason":"listing failed"}'
  printf '  result            : UNKNOWN -- the snapshot could not be listed\n'
  exit 2
fi
UNKBK
chmod +x "$UP/bin/domum-media-backup"
git -C "$UP" add -A; git -C "$UP" -c user.email=t@e -c user.name=t commit -qm unknown
out="$(run --confirm)"
grep -q 'does not emit the classification keys' <<< "$out" \
  && fail "an UNKNOWN reply was blamed on the build: $out"
grep -q 'coverage  : UNKNOWN -- listing failed' <<< "$out" \
  || fail "the reason the check could not answer was not reported: $out"
grep -q 'ARE installed and verified' <<< "$out" \
  || fail "it does not say the install already completed: $out"
grep -q '== deployed ==' <<< "$out" \
  || fail "a deployment that installed everything did not complete: $out"
echo "  reports the reason, keeps the deployment, blames neither wrongly"

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

sect "a script cannot deploy its own replacement -- it hands over"
# Production, 2026-10-20: the fast-forward installed a NEWER copy of the
# deployment script while the shell went on executing the one it had already
# started. That older logic knew nothing about the systemd units added in the
# same revision, so it installed one binary, skipped both units, and printed
# "== deployed ==" as though complete. `systemctl cat` then said "No files
# found".
#
# The fixture puts a CHANGED copy of the script in upstream, and the marker it
# prints can only come from the new one.
cp "$SCRIPT" "$UP/operator/domum-media-deploy-reporting-fixes.sh"
printf 'say "NEW-SCRIPT-RAN"\n' >> "$UP/operator/domum-media-deploy-reporting-fixes.sh"
git -C "$UP" add -A
git -C "$UP" -c user.email=t@e -c user.name=t commit -qm 'change the deploy script'
out="$(run --confirm)"
grep -q 'handing over to the new one' <<< "$out" \
  || fail "it did not hand over to its replacement: $out"
grep -q 'NEW-SCRIPT-RAN' <<< "$out" \
  || fail "the REPLACEMENT never ran -- this is the production defect: $out"
# Exactly once: the handover must not loop.
[[ "$(grep -c 'handing over to the new one' <<< "$out")" == "1" ]] \
  || fail "it handed over more than once; the guard does not hold: $out"
grep -q '== deployed ==' <<< "$out" || fail "the handover did not complete: $out"
echo "  handed over once, the new version ran, and the run completed"

sect "the DRY RUN warns that the script itself will change"
# A dry run cannot hand over -- nothing has been fast-forwarded -- so it must
# say the list may grow rather than present it as final.
git -C "$CO" reset -q --hard "$REV1"
out="$(run)"
grep -q 'this deployment script itself changes in that revision' <<< "$out" \
  || fail "the dry run does not warn that the script will change: $out"
grep -q 'the list above may grow' <<< "$out" \
  || fail "it does not say the file list is not final: $out"
grep -q 'NEW-SCRIPT-RAN' <<< "$out" && fail "a dry run must not run the replacement: $out"
echo "  warns the list may grow, and runs nothing"

# ---------------------------------------------------------------------------
# A fast-forward that changes a file a RUNNING container bind-mounts.
# Production, 2026-11-18 -> 11-23: the fast-forward rewrote traefik.yml for a
# container definition that did not exist yet; a Docker upgrade restarted
# traefik and every HTTPS route returned 404. The gate cannot judge such a
# change, so it names it and --confirm refuses without an explicit acceptance.
# ---------------------------------------------------------------------------
cp "$SCRIPT" "$UP/operator/domum-media-deploy-reporting-fixes.sh"
mkdir -p "$UP/compose/proxy/traefik" "$UP/compose/photos"
printf 'endpoint: tcp://docker-socket-proxy:2375\n' > "$UP/compose/proxy/traefik/traefik.yml"
printf 'x\n' > "$UP/compose/photos/immich.yml"
git -C "$UP" add -A
git -C "$UP" -c user.email=t@e -c user.name=t commit -qm 'change a live-mounted file'
REV_MOUNT="$(git -C "$UP" rev-parse HEAD)"
TRAEFIK_MOUNT="/traefik\t$CO/compose/proxy/traefik\n/traefik\t/var/run/docker.sock\n"

sect "a change under a running container's mount is NAMED by the dry run"
git -C "$CO" reset -q --hard "$REV1"
out="$(DOCKER_IDS=abc DOCKER_MOUNTS="$TRAEFIK_MOUNT" run)"; rc=$?
(( rc == 0 )) || fail "the dry run did not exit 0: $out"
grep -q 'LIVE-MOUNTED' <<< "$out" || fail "the live-mounted change is not reported: $out"
grep -q 'traefik: compose/proxy/traefik/traefik.yml' <<< "$out" \
  || fail "it does not name the container AND the file: $out"
grep -q 'compose/photos' <<< "$out" && fail "an UNMOUNTED change was reported as mounted: $out"
echo "  names traefik and the file, and nothing unmounted"

sect "--confirm REFUSES it, and changes nothing"
before_bk="$(sha256sum "$BIN/domum-media-backup" | cut -d' ' -f1)"
out="$(DOCKER_IDS=abc DOCKER_MOUNTS="$TRAEFIK_MOUNT" run --confirm)" && fail "it did not refuse: $out"
grep -q 'mounted into running containers' <<< "$out" || fail "the refusal does not say why: $out"
[[ "$(git -C "$CO" rev-parse HEAD)" == "$REV1" ]] || fail "the checkout MOVED despite the refusal"
[[ "$(sha256sum "$BIN/domum-media-backup" | cut -d' ' -f1)" == "$before_bk" ]] \
  || fail "a binary was installed despite the refusal"
echo "  refused before the fast-forward; checkout and binaries untouched"

sect "a mount the fast-forward does NOT touch is not gated (negative control)"
out="$(DOCKER_IDS=abc DOCKER_MOUNTS="/plex\t$CO/somewhere-else\n" run)"
grep -q 'LIVE-MOUNTED' <<< "$out" && fail "an untouched mount was gated: $out"
echo "  untouched mounts pass"

sect "a daemon that cannot be asked FAILS CLOSED"
out="$(DOCKER_FAIL=1 run)" && fail "an unreadable mount set was treated as none: $out"
grep -q 'cannot tell what the fast-forward reaches' <<< "$out" \
  || fail "the refusal does not say it could not look: $out"
echo "  refuses when it cannot look"

sect "MUTATION: without the refusal, the change would be deployed"
MUT="$TMP/deploy-mutant.sh"; cp "$SCRIPT" "$MUT"
python3 - "$MUT" <<'MUTPY' || fail "mutation did not apply"
import sys
p = sys.argv[1]; s = open(p).read()
old = 'if [ -n "$MOUNTED_CHANGES" ] && [ "$ACCEPT_MOUNTED" -ne 1 ]; then'
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, 'if [ -n "$MOUNTED_CHANGES" ] && [ "$ACCEPT_MOUNTED" != "$ACCEPT_MOUNTED" ]; then'))
MUTPY
git -C "$CO" reset -q --hard "$REV1"
out="$(RUN_SCRIPT="$MUT" DOCKER_IDS=abc DOCKER_MOUNTS="$TRAEFIK_MOUNT" run --confirm)"
[[ "$(git -C "$CO" rev-parse HEAD)" == "$REV_MOUNT" ]] \
  || fail "the mutant did not deploy -- the refusal is not what stops it: $out"
echo "  mutant fast-forwarded onto the live-mounted change: the refusal is load-bearing"

sect "--accept-mounted-changes is the operator's explicit acceptance"
git -C "$CO" reset -q --hard "$REV1"
out="$(DOCKER_IDS=abc DOCKER_MOUNTS="$TRAEFIK_MOUNT" run --confirm --accept-mounted-changes)" \
  || fail "an accepted run failed: $out"
grep -q 'accepted by the operator' <<< "$out" || fail "the acceptance is not stated: $out"
[[ "$(git -C "$CO" rev-parse HEAD)" == "$REV_MOUNT" ]] || fail "the accepted run did not fast-forward: $out"
grep -q '== deployed ==' <<< "$out" || fail "the accepted run did not complete: $out"
echo "  accepted, fast-forwarded, deployed"

echo "PASS: deploy-reporting-rehearsal"
