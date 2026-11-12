#!/usr/bin/env bash
set -uo pipefail

# send_recovery_pack_email is the encrypted recovery pack's ONLY off-host route
# -- the pack holds the configuration, the secrets, Traefik's ACME account key
# and a validated Uptime Kuma dump, and it is what makes every other off-site
# copy openable. It was in the never-executed set. Two defects, both measured:
#
#   * NO HEADER SANITISATION, while mreport_header_safe exists in the same file
#     and the weekly report's mail path already used it. Demonstrated: a newline
#     in RECOVERY_PACK_EMAIL_TO injected a Bcc into the message carrying the
#     pack. Not a privilege boundary -- the config is 0600 root -- but an
#     injection hole in that path, in a project that deliberately did NOT copy
#     exactly this hole from domum-core.
#   * the message file was left behind when the send FAILED. smtp_send_message
#     DIES, and `die` exits the process, so neither a RETURN trap nor a `||`
#     could clean up: measured, the whole base64 pack stayed in the temp
#     directory, on the path that fails when a credential is missing.
#
# Hermetic: mktemp -d, nothing is sent, no production path is read.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
MUTCLI="$CLI"
PRISTINE="$TMP/cli.pristine"
cp "$CLI" "$PRISTINE"

printf 'ENCRYPTED-PACK-BYTES' > "$TMP/pack.age"

send() {  # $1 = scratch dir for TMPDIR, $2 = extra setup, $3 = smtp stub body
  bash -c "
set -uo pipefail
export TMPDIR='$1'
source '$MUTCLI' >/dev/null 2>&1
die() { echo \"DIE: \$*\"; exit 9; }
RECOVERY_PACK_EMAIL_ENABLED=1
DOMUM_EMAIL='ops@example.invalid'
RECOVERY_PACK_SMTP_HOST='smtp.example.invalid'
RECOVERY_PACK_SMTP_USERNAME_FILE='$1/u'
RECOVERY_PACK_SMTP_PASSWORD_FILE='$1/p'
printf u > '$1/u'; printf p > '$1/p'
$2
smtp_send_message() { $3 }
send_recovery_pack_email '$TMP/pack.age'
" 2>&1
}
scratch() { local d; d="$(mktemp -d "$TMP/s.XXXXXX")"; printf '%s' "$d"; }
leftovers() { find "$1" -maxdepth 1 -type f ! -name u ! -name p | wc -l; }

# ---------------------------------------------------------------------------
# 1. A newline in a header value cannot introduce a header.
# ---------------------------------------------------------------------------
d="$(scratch)"
out="$(send "$d" "RECOVERY_PACK_EMAIL_TO=\$'victim@example.invalid\nBcc: attacker@example.invalid'" \
  'sed -n "1,4p" "$1";')"
grep -qE '^Bcc:' <<< "$out" \
  && fail "1: a newline in RECOVERY_PACK_EMAIL_TO introduced a Bcc header: $out"
grep -q 'Subject: domum-media recovery pack' <<< "$out" \
  || fail "1: the Subject is missing, so the message was not built: $out"
echo "  1: a newline in a header value cannot introduce a header"

# ...and the same for From and for the archive NAME, which reaches three headers.
d="$(scratch)"
out="$(send "$d" "RECOVERY_PACK_EMAIL_FROM=\$'a@b.invalid\nX-Injected: yes'" 'sed -n "1,4p" "$1";')"
grep -qE '^X-Injected:' <<< "$out" && fail "1: From injected a header: $out"
printf 'x' > "$TMP/$(printf 'pack\nX-Evil: yes').age" 2>/dev/null || true
echo "  1: From is sanitised too"

# ---------------------------------------------------------------------------
# 2. The pack is attached, base64-encoded, and the body is well-formed.
# ---------------------------------------------------------------------------
d="$(scratch)"
out="$(send "$d" "" 'cat "$1";')"
grep -q 'Content-Transfer-Encoding: base64' <<< "$out" || fail "2: not base64: $out"
grep -qF "$(base64 < "$TMP/pack.age" | head -1)" <<< "$out" \
  || fail "2: the pack bytes are not in the message"
grep -q -- '--domum-boundary--' <<< "$out" || fail "2: the multipart is not closed: $out"
echo "  2: the pack is attached base64 and the multipart is closed"

# ---------------------------------------------------------------------------
# 3. Nothing is left behind -- on success, and on the failure paths.
# ---------------------------------------------------------------------------
d="$(scratch)"; send "$d" "" 'return 0;' >/dev/null
[ "$(leftovers "$d")" = "0" ] || fail "3: a successful send left $(leftovers "$d") file(s) behind"

d="$(scratch)"
out="$(send "$d" "RECOVERY_PACK_SMTP_HOST=''" 'echo SENT;')"
grep -q 'DIE:' <<< "$out" || fail "3: a missing SMTP host did not refuse: $out"
grep -q 'SENT' <<< "$out" && fail "3: it sent despite an unusable transport: $out"
[ "$(leftovers "$d")" = "0" ] \
  || fail "3: refusing left $(leftovers "$d") message file(s) behind -- the refusal
must happen BEFORE the message is built, because die exits and no trap can run"

d="$(scratch)"
out="$(send "$d" "RECOVERY_PACK_SMTP_USERNAME_FILE='$d/absent'" 'echo SENT;')"
grep -q 'DIE:' <<< "$out" || fail "3: a missing credential did not refuse: $out"
[ "$(leftovers "$d")" = "0" ] || fail "3: a missing credential left a message behind"
echo "  3: success and both refusal paths leave nothing behind"

# ---------------------------------------------------------------------------
# 4. Delivery disabled is a no-op that builds nothing.
# ---------------------------------------------------------------------------
d="$(scratch)"
out="$(bash -c "
set -uo pipefail
export TMPDIR='$d'
source '$MUTCLI' >/dev/null 2>&1
die() { echo \"DIE: \$*\"; exit 9; }
RECOVERY_PACK_EMAIL_ENABLED=0
smtp_send_message() { echo SENT; }
send_recovery_pack_email '$TMP/pack.age'" 2>&1)"
grep -q 'SENT' <<< "$out" && fail "4: it sent with delivery disabled: $out"
grep -q 'DIE' <<< "$out" && fail "4: disabled delivery must be a no-op, not a refusal: $out"
[ "$(leftovers "$d")" = "0" ] || fail "4: disabled delivery still built a message"
echo "  4: delivery disabled builds nothing and refuses nothing"

# ---------------------------------------------------------------------------
# 5. smtp_send_message enforces the SAME check, through the same function.
# ---------------------------------------------------------------------------
d="$(scratch)"; printf 'msg' > "$d/m"
out="$(bash -c "
set -uo pipefail
source '$MUTCLI' >/dev/null 2>&1
die() { echo \"DIE: \$*\"; exit 9; }
RECOVERY_PACK_SMTP_USERNAME_FILE='$d/absent'
RECOVERY_PACK_SMTP_PASSWORD_FILE='$d/absent'
RECOVERY_PACK_SMTP_HOST='smtp.example.invalid'
smtp_send_message '$d/m'" 2>&1)"
grep -q 'SMTP credential files are missing' <<< "$out" \
  || fail "5: smtp_send_message lost its own precondition wording: $out"
echo "  5: the sender enforces the same check, with its wording unchanged"

# ---------------------------------------------------------------------------
# 6. MUTATIONS, against a COPY.
# ---------------------------------------------------------------------------
MUTCLI="$TMP/cli-mutant"
cp "$CLI" "$MUTCLI"
cat > "$TMP/mut-hdr.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  to="$(mreport_header_safe "${RECOVERY_PACK_EMAIL_TO:-$DOMUM_EMAIL}")"'
new = '  to="${RECOVERY_PACK_EMAIL_TO:-$DOMUM_EMAIL}"'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
python3 -I "$TMP/mut-hdr.py" "$MUTCLI" || fail "6: the header mutation did not apply"
d="$(scratch)"
out="$(send "$d" "RECOVERY_PACK_EMAIL_TO=\$'victim@example.invalid\nBcc: attacker@example.invalid'" \
  'sed -n "1,4p" "$1";')"
grep -qE '^Bcc:' <<< "$out" \
  || fail "6: the mutation applied but no header was injected, so section 1
would pass without the sanitiser: $out"
echo "  6: without the sanitiser a config newline injects a Bcc again"

MUTCLI="$TMP/cli-mutant2"
cp "$CLI" "$MUTCLI"
cat > "$TMP/mut-pre.py" <<'PY'
import io, sys
# Line-based: the construct spans a continuation, and expressing one backslash
# through a heredoc and then a Python string literal is two escaping layers that
# the first attempt got wrong (the anchor matched 0 times). Delete the three
# lines around the refusal instead.
p = sys.argv[1]
lines = io.open(p, encoding="utf-8").read().split("\n")
hits = [i for i, l in enumerate(lines)
        if 'die "Refusing to build the recovery-pack message' in l]
assert len(hits) == 1, "refusal line matched %d times" % len(hits)
i = hits[0]
assert 'smtp_transport_problem' in lines[i - 1], "unexpected line above: %r" % lines[i - 1]
assert lines[i - 2].strip() == "local problem", "unexpected line two above: %r" % lines[i - 2]
del lines[i - 2:i + 1]
io.open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
python3 -I "$TMP/mut-pre.py" "$MUTCLI" || fail "6: the preflight mutation did not apply"
d="$(scratch)"
# The stub must DIE, as the real smtp_send_message does: `die` exits, which is
# why no RETURN trap can clean up. A stub that merely echoes lets the trap fire
# and the mutant looks safe -- name the observable the mutation actually
# changes.
send "$d" "" 'die "SMTP credential files are missing.";' >/dev/null 2>&1
[ "$(leftovers "$d")" != "0" ] \
  || fail "6: the mutation applied but nothing was left behind, so section 3
would pass without the preflight"
echo "  6: without the preflight a failed send leaves the pack message behind"
MUTCLI="$CLI"

cmp -s "$CLI" "$PRISTINE" \
  || fail "the tracked CLI differs from the pristine copy taken before the first section"

echo "PASS: recovery pack email smoke test"
