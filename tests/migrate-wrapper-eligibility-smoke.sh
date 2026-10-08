#!/usr/bin/env bash
set -uo pipefail

# The migration wrapper decides eligibility by ASKING the CLI, not from a list.
#
# WHY IT EXISTS. operator/domum-media-migrate-service.sh carried two stale
# absolutes when it was brought into the repository:
#
#   REVISION=d4734fc58e7a...      pinned a revision superseded twice over
#   case "$SVC" in
#     calibre-web|plex) ;;                     <- plex was ALREADY migrated
#     jellyfin|kavita|navidrome) already ;;    <- a hardcoded list of live state
#
# A hardcoded list of which services are migrated is an absolute assertion about
# the storage topology, and every one of those has been true once and
# permanently false afterwards -- one of them aborted a correct deployment. The
# CLI answers the question, so the wrapper asks it.
#
# It also replaced twenty `check_feature` greps of the installed binary's SOURCE
# for private function names -- and for literal code fragments like
# `running="$(docker ps` -- with capability tokens.
#
# The root check is satisfied under `unshare -r` rather than weakened, as in the
# Plex wrapper's rehearsal.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$REPO_ROOT/operator/domum-media-migrate-service.sh"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

[ -x "$WRAPPER" ] || fail "the wrapper is not executable"

echo "== 1. the stale absolutes are gone =="
body="$(grep -vE '^\s*#' "$WRAPPER")"
grep -qE '^REVISION=' <<< "$body" \
  && fail "a REVISION constant is pinned again. It goes stale by construction:
what is always checked instead is that the installed binary matches the checkout."
grep -qE 'jellyfin\|kavita\|navidrome|calibre-web\|plex' <<< "$body" \
  && fail "a hardcoded list of migrated services is back. That is an absolute
assertion about the storage topology, and it was already wrong about plex."
grep -q 'check_feature' <<< "$body" \
  && fail "check_feature is back; it grepped the installed binary's source"
grep -q 'storage protection' <<< "$body" \
  || fail "the wrapper does not ask the CLI for the protection state"
echo "  no REVISION pin, no service list, no source greps; it asks the CLI"

echo "== 2. it requires the capabilities it uses, and they all exist =="
caps="$(sed -nE '/^NEEDED_CAPS="/,/"$/p' "$WRAPPER" | tr -d '"' | sed 's/^NEEDED_CAPS=//')"
[ -n "$caps" ] || fail "NEEDED_CAPS is not declared"
n=0
for cap in $caps; do
  "$CLI" capabilities --has "$cap" >/dev/null 2>&1 \
    || fail "the wrapper requires capability '$cap', which the CLI does not advertise"
  n=$((n + 1))
done
[ "$n" -ge 5 ] || fail "only $n capabilities required; the twenty greps collapsed into too few"
grep -q 'capabilities --has "$cap"' "$WRAPPER" \
  || fail "NEEDED_CAPS is declared but never checked against the installed CLI"
echo "  $n capabilities required, all advertised, and actually checked"

# A fake production: a git checkout, a shim that looks like the installed CLI,
# and a stubbed `storage protection` whose answer each case controls.
make_env() {  # $1 = what `storage protection` should print, $2 = its exit code
  rm -rf "${TMP_DIR:?}/f"
  ENV_DIR="$TMP_DIR/f"
  mkdir -p "$ENV_DIR"/{repo/bin,inst,data,snaps}
  mkdir -p "$ENV_DIR/data/calibre-web"
  cat > "$ENV_DIR/inst/domum-media" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "capabilities --has") exit 0 ;;
  "storage protection") printf '%s\n' "$1"; exit $2 ;;
esac
exit 0
SHIM
  chmod +x "$ENV_DIR/inst/domum-media"
  cp "$ENV_DIR/inst/domum-media" "$ENV_DIR/repo/bin/domum-media"
  ( cd "$ENV_DIR/repo" && git init -q . \
    && git -c user.email=t@t -c user.name=t add -A \
    && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1
}

AS_ROOT=()
if [ "$(id -u)" -ne 0 ]; then
  unshare -r true 2>/dev/null && AS_ROOT=(unshare -r)
fi

run_wrapper() {  # $@ = args
  "${AS_ROOT[@]}" env \
    "DOMUM_REPO=$ENV_DIR/repo" \
    "DOMUM_CLI=$ENV_DIR/inst/domum-media" \
    "DOMUM_DATA_ROOT_OVERRIDE=$ENV_DIR/data" \
    "DOMUM_SNAPSHOT_ROOT_OVERRIDE=$ENV_DIR/snaps" \
    "PATH=$PATH" "HOME=$ENV_DIR" \
    bash "$WRAPPER" "$@" >"$ENV_DIR/out" 2>"$ENV_DIR/err"
  echo $?
}
wout() { cat "$ENV_DIR/out" "$ENV_DIR/err"; }

if [ "$(id -u)" -ne 0 ] && [ "${#AS_ROOT[@]}" -eq 0 ]; then
  echo "== 3-9. SKIPPED: not root and no user namespaces =="
else
  [ "$(id -u)" -eq 0 ] || echo "  (rehearsing under unshare -r; uid 0 in a user namespace)"

echo "== 3. 'unprotected' is the ONLY state that proceeds =="
# calibre-web's actual state today, measured: an ordinary directory on the
# protected tier. This is the case the migration exists for.
make_env unprotected 1
rc="$(run_wrapper calibre-web --preflight-only)"
grep -q "is 'unprotected'" "$ENV_DIR/out" \
  || { wout; fail "an unprotected service was not accepted as migratable"; }
echo "  accepted, and named as migratable"

echo "== 4. every other state refuses, with its OWN reason =="
# The list is the point: each refusal has to say something different and true,
# or the operator cannot act on it.
check() {  # $1 = protection word, $2 = exit, $3 = expected substring
  make_env "$1" "$2"
  rc="$(run_wrapper calibre-web --preflight-only)"
  [ "$rc" != "0" ] || { wout; fail "state '$1' did not refuse"; }
  grep -qF -- "$3" "$ENV_DIR/err" \
    || { wout; fail "state '$1' did not say '$3'"; }
}
check protected     0 "already protected"
check snapshottable 1 "needs a snapshot"
check degraded      1 "nested subvolume"
check docker-volume 1 "volume-pre-upgrade-point"
check stateless     1 "hold no durable state"
check weird-value   1 "Failing closed"
echo "  protected / snapshottable / degraded / docker-volume / stateless / unknown"

echo "== 5. the docker-volume refusal names the command that DOES work =="
# Not "unknown service", and not silence: the operator is told which recovery
# point applies to volume-backed state.
make_env docker-volume 1
run_wrapper traefik --preflight-only >/dev/null
grep -q 'would protect nothing' "$ENV_DIR/err" \
  || { wout; fail "it does not warn that migrating the directory protects nothing"; }
grep -q 'storage volume-pre-upgrade-point' "$ENV_DIR/err" \
  || { wout; fail "it does not name the command that can take the point"; }
echo "  warns against the wrong fix and names the right command"

echo "== 6. an unknown protection value FAILS CLOSED =="
make_env '' 3
rc="$(run_wrapper calibre-web --preflight-only)"
[ "$rc" != "0" ] || { wout; fail "an empty protection answer proceeded"; }
grep -q 'Failing closed' "$ENV_DIR/err" || { wout; fail "it did not fail closed"; }
echo "  an unreadable answer refuses"

echo "== 7. the installed binary must match the checkout =="
make_env unprotected 1
printf '\n# installed-only drift\n' >> "$ENV_DIR/inst/domum-media"
rc="$(run_wrapper calibre-web --preflight-only)"
[ "$rc" != "0" ] || fail "an installed binary differing from the checkout was accepted"
grep -q 'does not match' "$ENV_DIR/err" || { wout; fail "wrong refusal"; }
echo "  refused"

echo "== 8. --expect-revision is checked when given, optional when not =="
make_env unprotected 1
rc="$(run_wrapper calibre-web --preflight-only --expect-revision 0000000000000000000000000000000000000000)"
[ "$rc" != "0" ] || fail "a wrong --expect-revision was accepted"
grep -q 'not the expected' "$ENV_DIR/err" || { wout; fail "wrong refusal"; }
make_env unprotected 1
head_sha="$(git -C "$ENV_DIR/repo" rev-parse HEAD)"
run_wrapper calibre-web --preflight-only --expect-revision "$head_sha" >/dev/null
grep -q "production HEAD = $head_sha" "$ENV_DIR/out" \
  || { wout; fail "the correct revision was not accepted"; }
echo "  wrong refused, correct accepted, absent tolerated"

echo "== 9. a missing capability refuses BY NAME =="
make_env unprotected 1
cat > "$ENV_DIR/inst/domum-media" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "capabilities --has")
    [ "$3" = "topology-verify" ] && exit 1
    exit 0 ;;
  "storage protection") printf 'unprotected\n'; exit 1 ;;
esac
exit 0
SHIM
chmod +x "$ENV_DIR/inst/domum-media"
cp "$ENV_DIR/inst/domum-media" "$ENV_DIR/repo/bin/domum-media"
( cd "$ENV_DIR/repo" && git -c user.email=t@t -c user.name=t commit -qam drop ) >/dev/null 2>&1
rc="$(run_wrapper calibre-web --preflight-only)"
[ "$rc" != "0" ] || fail "it proceeded without a capability it requires"
grep -q 'does not support' "$ENV_DIR/err" || { wout; fail "wrong refusal"; }
grep -q 'topology-verify' "$ENV_DIR/err" || fail "the missing capability was not named"
echo "  refused, naming topology-verify"

fi

echo
echo "PASS: migrate wrapper eligibility smoke"
