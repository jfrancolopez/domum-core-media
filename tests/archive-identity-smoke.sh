#!/usr/bin/env bash
# An archive must state its own identity, and it must do so WITHOUT loading.
#
# `storage verify-archive` proved the FILE was intact and said so honestly:
# "that is not the same as the identity it restores". The gap mattered, because
# the docker save archive is the only PROVEN copy of the application half of
# every recovery point on this host -- no tagged image here has an independent
# registry reference, and traefik's and uptime-kuma's running images are
# dangling outright.
#
# Measured 2026-11-02 on this host (containerd image store, overlayfs): an
# archive written by `docker save <image-id>` carries index.json whose
# manifests[0].digest EQUALS the image Id, and a blob at that digest whose own
# sha256 equals it (9,535 bytes for busybox). So identity is provable by
# content-addressing, read-only.
#
# This suite builds its archives from a real local image where one is available
# and falls back to a synthetic OCI layout otherwise, so it runs in CI too.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

probe() {
  (
    export PATH="$TMP/bin:$PATH"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    warn() { echo "WARN: $*"; }
    eval "$1"
  ) 2>&1
}
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"

# A synthetic archive in the same shape `docker save` writes: the manifest blob
# is content-addressed, so its NAME is the sha256 of its own bytes, and that is
# the image id. Built here rather than taken from the daemon so the suite is
# hermetic and the failure cases can be constructed exactly.
mk_archive() {  # $1 = output tar, $2 = manifest body, $3 = blob name override or ""
  local out="$1" body="$2" override="${3:-}" dg lay
  rm -rf "$TMP/build"; mkdir -p "$TMP/build/blobs/sha256"
  printf '%s' "$body" > "$TMP/build/manifest-body"
  dg="$(sha256sum "$TMP/build/manifest-body" | cut -d' ' -f1)"
  lay="${override:-$dg}"
  mv "$TMP/build/manifest-body" "$TMP/build/blobs/sha256/$lay"
  printf '{"schemaVersion":2,"manifests":[{"digest":"sha256:%s","size":%s}]}\n' \
    "$lay" "$(stat -c %s "$TMP/build/blobs/sha256/$lay")" > "$TMP/build/index.json"
  printf '{"imageLayoutVersion":"1.0.0"}\n' > "$TMP/build/oci-layout"
  ( cd "$TMP/build" && tar -cf "$out" . )
  printf '%s' "$dg"
}

sect "a REAL docker save archive names its image, if one can be built here"
real_done=0
if command -v docker >/dev/null 2>&1 && img_id="$(command docker image inspect -f '{{.Id}}' busybox:latest 2>/dev/null)" && [[ -n "$img_id" ]]; then
  if command docker save -o "$TMP/real.tar" "$img_id" 2>/dev/null; then
    v="$(probe "domum_archive_identity '$TMP/real.tar' '$img_id'")"
    [[ "$v" == "verified" ]] \
      || fail "a real 'docker save' archive of $img_id did not verify its own
identity (got '$v'). The archive is the only proven copy of the application
half of every recovery point on this host."
    echo "  verified against a real archive of $img_id"
    # And the recorded sha256 of the FILE is a different claim: corrupting a
    # LAYER leaves the manifest blob intact, so identity still verifies while
    # the file checksum would not. Both claims are needed.
    real_done=1
  fi
fi
(( real_done == 1 )) || echo "  skipped: no local image to save (the synthetic cases below still run)"

sect "a synthetic archive in the same shape verifies"
id="$(mk_archive "$TMP/a.tar" '{"config":{},"layers":[]}')"
v="$(probe "domum_archive_identity '$TMP/a.tar' 'sha256:$id'")"
[[ "$v" == "verified" ]] || fail "a well-formed archive did not verify: $v"
echo "  verified"

sect "an archive of a DIFFERENT image is 'absent', never a pass"
other="$(printf 'something else' | sha256sum | cut -d' ' -f1)"
v="$(probe "domum_archive_identity '$TMP/a.tar' 'sha256:$other'")"
[[ "$v" == "absent" ]] \
  || fail "an archive that does not contain the named image returned '$v'. A
recovery point whose archive holds the wrong application is the pairing
failure this project exists to prevent."
echo "  absent"

sect "a CORRUPT blob is distinguished from a missing one"
# The blob is named for a digest its contents no longer have: present, and
# would not restore that image. That is a different finding from 'absent' and
# must not be collapsed into it.
id2="$(mk_archive "$TMP/c.tar" '{"config":{},"layers":[]}' )"
rm -rf "$TMP/cx"; mkdir -p "$TMP/cx"; tar -xf "$TMP/c.tar" -C "$TMP/cx"
printf 'tampered' >> "$TMP/cx/blobs/sha256/$id2"
( cd "$TMP/cx" && tar -cf "$TMP/c2.tar" . )
v="$(probe "domum_archive_identity '$TMP/c2.tar' 'sha256:$id2'")"
[[ "$v" == "corrupt" ]] \
  || fail "a blob present under its digest but no longer hashing to it returned
'$v'; it must be reported as corrupt, not absent and not verified"
echo "  corrupt"

sect "an unreadable or unrecognised archive is UNDETERMINED, never verified"
printf 'not a tar at all' > "$TMP/junk.tar"
v="$(probe "domum_archive_identity '$TMP/junk.tar' 'sha256:$id'")"
[[ "$v" == "undetermined" ]] || fail "a non-archive returned '$v': $v"
v="$(probe "domum_archive_identity '$TMP/absent.tar' 'sha256:$id'")"
[[ "$v" == "undetermined" ]] || fail "a missing archive returned '$v'"
v="$(probe "domum_archive_identity '$TMP/a.tar' ''")"
[[ "$v" == "undetermined" ]] || fail "no recorded image id returned '$v'"
v="$(probe "domum_archive_identity '$TMP/a.tar' 'not-a-digest'")"
[[ "$v" == "undetermined" ]] || fail "a malformed image id returned '$v'"
echo "  a non-archive, a missing archive, an empty id and a malformed id all undetermined"

sect "the legacy config-blob layout is found too"
# Under the classic image store the Id is the CONFIG blob's digest, which is
# written as <hex>.json at the archive root. The same content-addressed test
# must find it there, so the check is not tied to one storage driver.
rm -rf "$TMP/legacy"; mkdir -p "$TMP/legacy"
printf '{"architecture":"amd64","config":{}}' > "$TMP/legacy/body"
lid="$(sha256sum "$TMP/legacy/body" | cut -d' ' -f1)"
mv "$TMP/legacy/body" "$TMP/legacy/$lid.json"
printf '[{"Config":"%s.json","RepoTags":null,"Layers":[]}]\n' "$lid" > "$TMP/legacy/manifest.json"
( cd "$TMP/legacy" && tar -cf "$TMP/legacy.tar" . )
v="$(probe "domum_archive_identity '$TMP/legacy.tar' 'sha256:$lid'")"
[[ "$v" == "verified" ]] || fail "the classic <hex>.json config layout was not recognised: $v"
echo "  verified under the classic layout"

sect "identity and the FILE checksum are different claims"
# Corrupting a layer blob leaves the manifest blob intact, so identity still
# verifies while the file's recorded sha256 would not. Neither check subsumes
# the other, which is why verify-archive reports both.
rm -rf "$TMP/lx"; mkdir -p "$TMP/lx"; tar -xf "$TMP/a.tar" -C "$TMP/lx"
printf 'extra layer junk' > "$TMP/lx/blobs/sha256/0000000000000000000000000000000000000000000000000000000000000000"
( cd "$TMP/lx" && tar -cf "$TMP/l2.tar" . )
v="$(probe "domum_archive_identity '$TMP/l2.tar' 'sha256:$id'")"
[[ "$v" == "verified" ]] \
  || fail "identity should still verify when a non-manifest blob changed: $v"
before="$(sha256sum "$TMP/a.tar" | cut -d' ' -f1)"
after="$(sha256sum "$TMP/l2.tar" | cut -d' ' -f1)"
[[ "$before" != "$after" ]] || fail "the fixture did not actually change the file"
echo "  identity holds, the file checksum does not -- both claims are reported"

sect "the report says identity is UNPROVEN rather than silently omitting it"
va="$(awk '/^storage_verify_archive\(\) \{/,/^\}/' "$CLI")"
grep -q 'domum_archive_identity' <<< "$va" \
  || fail "verify-archive does not consult the identity check at all"
for want in 'UNDETERMINED' 'CORRUPT' 'DIFFERENT image'; do
  grep -qF "$want" <<< "$va" || fail "verify-archive does not report the '$want' case"
done
# And it must still say what it has NOT proven: that the application runs.
grep -q 'still unproven' <<< "$va" \
  || fail "the report does not state its own limit. Containing the right image
is not evidence that the application starts, and this project's rule is that
the weaker claim is never stated in the stronger claim's words."
echo "  all four verdicts reported, and the limit stated"

# ---------------------------------------------------------------------------
sect "MUTATION: without the digest comparison any archive claims the identity"
cp "$CLI" "$TMP/cli.orig"
cat > "$TMP/mutate.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '    if [[ "$got" == "$hex" ]]; then printf \'verified\'; return 0; fi'
new = '    if [[ "$hex" == "$hex" ]]; then printf \'verified\'; return 0; fi'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
( python3 -I "$TMP/mutate.py" "$CLI" ) || { cp "$TMP/cli.orig" "$CLI"; fail "the mutation did not apply"; }
mv="$(probe "domum_archive_identity '$TMP/a.tar' 'sha256:$other'")"
cp "$TMP/cli.orig" "$CLI"
[[ "$mv" == "verified" ]] \
  || fail "the mutation changed no ANSWER -- comparing the digest to itself must
make an archive of a DIFFERENT image claim the identity: $mv"
echo "  killed: without the comparison, the wrong archive claims the identity"

sect "MUTATION: treating an unreadable archive as verified"
cp "$CLI" "$TMP/cli.orig2"
cat > "$TMP/mutate2.py" <<'PYMUT2'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "  [[ -r \"$arch\" && -n \"$want\" ]] || { printf 'undetermined'; return 0; }"
new = "  [[ -r \"$arch\" && -n \"$want\" ]] || { printf 'verified'; return 0; }"
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT2
( python3 -I "$TMP/mutate2.py" "$CLI" ) || { cp "$TMP/cli.orig2" "$CLI"; fail "the second mutation did not apply"; }
mv2="$(probe "domum_archive_identity '$TMP/absent.tar' 'sha256:$id'")"
cp "$TMP/cli.orig2" "$CLI"
[[ "$mv2" == "verified" ]] \
  || fail "the mutation changed no ANSWER -- an archive that is not there must
then read as verified, which is the 'I could not check it' defect: $mv2"
echo "  killed: an absent archive would read as proven"

echo "ALL ARCHIVE-IDENTITY CHECKS PASSED"
