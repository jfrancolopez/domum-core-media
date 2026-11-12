#!/usr/bin/env bash
# `smtp_send_message` is the ONE place mail leaves this host, and until now no
# test had ever executed it. Five suites reference it: FOUR stub it whole and the
# fifth names it only in a comment -- so nothing ran the real body (the credential
# handling, the curl invocation, the failure return) and nothing even asserted its
# text. Verified by stripping comments first, which is this project's own rule.
#
# That is the recorded family: "a test that asserts on a function's TEXT does not
# prove the function runs". Here it was weaker still, because nothing asserted
# even the text. Three defects were sitting in those twenty lines:
#
#   1. NO RETRY. One attempt, and the caller's cadence sets the cost: the weekly
#      report's next attempt is the next Sunday, so one refused connection costs
#      a week. The alert path is worse in kind -- it sends only when something
#      needs attention, so a transient failure loses the one message that
#      mattered. Adding retries required BOUNDING each attempt first: curl sets
#      no connect timeout, so three hanging connects in a unit that may send
#      twice could approach TimeoutStartSec=10m and be killed mid-way.
#
#   2. THE CREDENTIAL WAS IN curl's ARGV. Measured on this host: /proc carries no
#      hidepid option and 75 root-owned processes' argv read fine as the
#      unprivileged account, while /etc/domum-core-media/secrets is
#      drwx------ root root -- unreadable and unlistable by it. So
#      `--user user:password` widened a root-only secret to every local account
#      for as long as each send took.
#
#   3. A DEFAULT .curlrc WAS HONOURED. curl(1): the default config file is read
#      "even when --config is used". Measured on this host, with one planted:
#      CURLOPT_SSL_VERIFYPEER and VERIFYHOST both went to 0 and an EXTRA
#      CURLOPT_MAIL_RCPT appeared -- certificate verification on the mail send
#      defeated, and a second recipient for a report full of host state, without
#      a line of this file changing. The credential itself was never at risk,
#      because a command-line --config is parsed after the default config and
#      wins; the first version of section 9 asserted that wrong property and the
#      measurement corrected it.
#
# Everything below is DRIVEN. The one thing that is not stubbed is curl's
# PARSER: the stub replays production's own argv against the real curl with
# --libcurl, which prints CURLOPT_USERPWD verbatim, so the credential the
# production code wrote is compared byte for byte with what curl reads back.
# That also makes -q a behavioural observable rather than a text assertion.
#
# No network is contacted and no real secret is used: the fixture credentials
# are sentinels, and a section asserts they never reach stdout or stderr.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
# What the drivers LOAD. Defaults to the tracked CLI and is repointed at a
# mutated copy by mutate() below, so no mutation ever touches bin/.
MUTCLI="$CLI"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
# Taken BEFORE the first section, so the guard at the end proves the tracked
# CLI was never mutated rather than that the last restore ran.
PRISTINE="$TMP/cli.pristine"
cp "$CLI" "$PRISTINE"

command -v curl >/dev/null 2>&1 || { echo "SKIP: curl is not installed"; exit 0; }

# ---------------------------------------------------------------------------
#  The driver. A FILE with a quoted heredoc, never a nested -c string: that is
#  what once produced a mutation which silently did nothing.
# ---------------------------------------------------------------------------
cat > "$TMP/drive.sh" <<'DRIVER'
set -uo pipefail
source "$CLI" >/dev/null 2>&1
die() { echo "DIE: $*" >&2; exit 90; }
warn() { echo "WARN: $*" >&2; }

W="$WORK"
printf '%s' "$FIX_USER" > "$W/u"
printf '%s' "$FIX_PASS" > "$W/p"
chmod 600 "$W/u" "$W/p"
printf 'Subject: fixture\r\n\r\nbody\r\n' > "$W/msg.eml"

RECOVERY_PACK_SMTP_HOST="${HOST_OVERRIDE-smtp.invalid}"
RECOVERY_PACK_SMTP_PORT=465
RECOVERY_PACK_SMTP_USERNAME_FILE="${USER_FILE:-$W/u}"
RECOVERY_PACK_SMTP_PASSWORD_FILE="${PASS_FILE:-$W/p}"
DOMUM_EMAIL="fixture@example.invalid"

# The stub IS the curl call, so the credential file still exists here.
curl() {
  : > "$W/argv"
  local a
  for a in "$@"; do printf '%s\0' "$a" >> "$W/argv"; done

  local cfg="" want=0
  for a in "$@"; do
    if (( want )); then cfg="$a"; want=0; continue; fi
    [[ "$a" == --config ]] && want=1
  done
  if [[ -n "$cfg" ]]; then
    printf '%s' "$cfg" > "$W/cfgpath"
    stat -c '%a' "$cfg" > "$W/cfg-mode"
    # Replay production's OWN leading argv against the real curl. -q is copied
    # only if production passed it, which is what makes its effect observable:
    # with CURL_HOME planted, a missing -q lets the planted credential win.
    local -a replay=()
    [[ "${1:-}" == -q ]] && replay+=(-q)
    replay+=(--config "$cfg")
    command curl "${replay[@]}" --libcurl /dev/stdout --silent --max-time 2 \
      file:///dev/null > "$W/libcurl" 2>/dev/null || true
  fi
  return "${CURL_RC:-0}"
}

rc=0
smtp_send_message "$W/msg.eml" || rc=$?
echo "rc=$rc"
if [[ -s "$W/cfgpath" ]] && [[ -e "$(cat "$W/cfgpath")" ]]; then
  echo "CFG-SURVIVED"
else
  echo "CFG-REMOVED"
fi
DRIVER

# Run the driver. Everything the driver needs arrives by environment, so one
# file serves every scenario and the scenarios cannot drift apart.
drive() {  # drive <workdir> [VAR=VAL ...]
  local work="$1"; shift
  rm -rf -- "$work"; mkdir -p "$work"
  env WORK="$work" CLI="$MUTCLI" \
      FIX_USER="${FIX_USER:-domum-fixture-user}" \
      FIX_PASS="${FIX_PASS:-SENTINEL-pw-7f3a9c}" \
      "$@" bash "$TMP/drive.sh" 2>&1
}

argv_lines() { tr '\0' '\n' < "$1/argv"; }

# ===========================================================================
sect "1. the real function runs, and the retry flags reach curl"
out="$(drive "$TMP/s1")" || true
grep -qx 'rc=0' <<< "$out" || fail "a successful send did not return 0: $out"
av="$(argv_lines "$TMP/s1")"
grep -qx -- '--retry' <<< "$av" || fail "--retry was not passed: $av"
grep -qx -- '--retry-connrefused' <<< "$av" || fail "--retry-connrefused was not passed"
# The VALUES, read by position rather than by "the next line that is a number".
mapfile -t A < <(printf '%s\n' "$av")
for i in "${!A[@]}"; do
  [[ "${A[$i]}" == --retry ]] && { [[ "${A[$((i+1))]}" == 2 ]] || fail "--retry took '${A[$((i+1))]}', expected 2"; }
  [[ "${A[$i]}" == --retry-delay ]] && { [[ "${A[$((i+1))]}" == 10 ]] || fail "--retry-delay took '${A[$((i+1))]}', expected 10"; }
done
echo "   ok: --retry 2 --retry-delay 10 --retry-connrefused"

# ===========================================================================
sect "2. RECOVERY_PACK_SMTP_RETRIES=0 restores the single-attempt behaviour"
out="$(drive "$TMP/s2" RECOVERY_PACK_SMTP_RETRIES=0)" || true
av="$(argv_lines "$TMP/s2")"
grep -qx -- '--retry' <<< "$av" && fail "retries=0 still passed --retry: $av"
grep -qx -- '--retry-connrefused' <<< "$av" && fail "retries=0 still passed --retry-connrefused"
grep -qx 'rc=0' <<< "$out" || fail "the single-attempt form did not send"
echo "   ok: no retry option at all, and the send still happens"

# ===========================================================================
sect "3. a configured retry count and delay are honoured"
out="$(drive "$TMP/s3" RECOVERY_PACK_SMTP_RETRIES=5 RECOVERY_PACK_SMTP_RETRY_DELAY=3)" || true
av="$(argv_lines "$TMP/s3")"
mapfile -t A < <(printf '%s\n' "$av")
got_r=""; got_d=""
for i in "${!A[@]}"; do
  [[ "${A[$i]}" == --retry ]] && got_r="${A[$((i+1))]}"
  [[ "${A[$i]}" == --retry-delay ]] && got_d="${A[$((i+1))]}"
done
[[ "$got_r" == 5 ]] || fail "--retry took '$got_r', expected 5"
[[ "$got_d" == 3 ]] || fail "--retry-delay took '$got_d', expected 3"
echo "   ok: 5 / 3"

# ===========================================================================
sect "3b. every attempt is BOUNDED, so retries cannot threaten TimeoutStartSec"
# curl sets no connect timeout of its own, so a black-holed SMTP port hangs for
# the OS TCP timeout. Unbounded retries in a unit whose other ExecStart may also
# send could approach TimeoutStartSec=10m and be killed mid-way -- a transient
# fault turned into a failed report. --max-time is NOT sufficient on its own:
# curl(1) resets its counter on every retry, so the WINDOW needs
# --retry-max-time.
av="$(argv_lines "$TMP/s1")"
mapfile -t A < <(printf '%s\n' "$av")
declare -A BOUND=()
for i in "${!A[@]}"; do
  case "${A[$i]}" in
    --connect-timeout|--max-time|--retry-max-time) BOUND["${A[$i]}"]="${A[$((i+1))]}" ;;
  esac
done
for flag in --connect-timeout --max-time --retry-max-time; do
  [[ -n "${BOUND[$flag]:-}" ]] || fail "$flag was not passed -- an attempt is unbounded"
  [[ "${BOUND[$flag]}" =~ ^[0-9]+$ ]] || fail "$flag took a non-numeric '${BOUND[$flag]}'"
  (( BOUND[$flag] > 0 )) || fail "$flag was 0, which disables the bound"
done
# The whole point is that the bound is small relative to the unit's 10m timeout.
(( BOUND[--max-time] <= 120 )) || fail "--max-time ${BOUND[--max-time]} is too large to bound two senders under 600s"
(( BOUND[--retry-max-time] <= 120 )) || fail "--retry-max-time ${BOUND[--retry-max-time]} is too large"
echo "   ok: connect ${BOUND[--connect-timeout]}s, attempt ${BOUND[--max-time]}s, retry window ${BOUND[--retry-max-time]}s"

# The PER-ATTEMPT bounds must survive retries being switched off -- that is the
# configuration where a single unbounded attempt would hang the unit alone.
av0="$(argv_lines "$TMP/s2")"
grep -qx -- '--connect-timeout' <<< "$av0" || fail "retries=0 lost --connect-timeout"
grep -qx -- '--max-time' <<< "$av0" || fail "retries=0 lost --max-time"
grep -qx -- '--retry-max-time' <<< "$av0" && fail "retries=0 still passed --retry-max-time, which needs --retry"
echo "   ok: the per-attempt bounds survive RETRIES=0; the retry window does not"

# ===========================================================================
sect "4. THE CREDENTIAL IS NOT IN ARGV"
av="$(argv_lines "$TMP/s1")"
grep -qx -- '--user' <<< "$av" && fail "--user is still passed on the command line: $av"
if grep -qaF 'SENTINEL-pw-7f3a9c' <<< "$av"; then
  fail "the password appears in curl's argv, which /proc exposes to every local account"
fi
grep -qx -- '--config' <<< "$av" || fail "--config was not passed, so the credential has no route at all"
echo "   ok: no --user, no password in argv, --config present"

# ===========================================================================
sect "5. -q is the FIRST argument, and --config precedes --ssl-reqd"
mapfile -t A < <(printf '%s\n' "$av")
[[ "${A[0]}" == "-q" ]] || fail "the first argument is '${A[0]}', not -q; curl would read a default .curlrc"
i_cfg=-1; i_ssl=-1
for i in "${!A[@]}"; do
  [[ "${A[$i]}" == --config  && $i_cfg -lt 0 ]] && i_cfg=$i
  [[ "${A[$i]}" == --ssl-reqd && $i_ssl -lt 0 ]] && i_ssl=$i
done
(( i_cfg >= 0 )) || fail "--config not found"
(( i_ssl >= 0 )) || fail "--ssl-reqd not found -- TLS is no longer required"
(( i_cfg < i_ssl )) || fail "--config ($i_cfg) comes after --ssl-reqd ($i_ssl), so a config file could override it"
echo "   ok: argv[0] = -q, --config at $i_cfg before --ssl-reqd at $i_ssl"

# ===========================================================================
sect "6. the credential file is 0600 while curl runs, and removed afterwards"
[[ -s "$TMP/s1/cfg-mode" ]] || fail "the stub never observed a --config file"
mode="$(cat "$TMP/s1/cfg-mode")"
[[ "$mode" == 600 ]] || fail "the credential file was mode $mode, not 600"
out1="$(drive "$TMP/s6")" || true
grep -qx 'CFG-REMOVED' <<< "$out1" || fail "the credential file survived a SUCCESSFUL send"
out2="$(drive "$TMP/s6b" CURL_RC=7)" || true
grep -qx 'CFG-REMOVED' <<< "$out2" || fail "the credential file survived a FAILED send -- the dangerous direction"
echo "   ok: 0600 during the call, removed after success and after failure"

# ===========================================================================
sect "7. failure propagation is preserved"
out="$(drive "$TMP/s7" CURL_RC=7)" || true
grep -qx 'rc=7' <<< "$out" || fail "curl exit 7 did not propagate: $out"
out="$(drive "$TMP/s7b" CURL_RC=67)" || true
grep -qx 'rc=67' <<< "$out" || fail "curl exit 67 (login denied) did not propagate: $out"
echo "   ok: 7 and 67 both returned unchanged"

# ===========================================================================
sect "8. ROUND TRIP -- the real curl parses back exactly what was written"
# The property is the round trip, not the escaping text. Per curl(1) the only
# escapes inside a quoted config value are \\ \" \t \n \r and \v, so a backslash
# and a double quote are what must be escaped; everything else must survive
# literally. read_secret_file_value trims surrounding whitespace, so a password
# with leading or trailing space is out of scope by construction.
# curl's --libcurl output prints CURLOPT_USERPWD as a C string literal, so
# reading it back means undoing exactly one layer of C escaping. A FILE, not an
# inline `python3 -c`: expressing this regex through shell quoting as well is
# what produced a pattern needing two literal backslashes where there is one.
cat > "$TMP/userpwd.py" <<'PYX'
import codecs, re, sys

src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'CURLOPT_USERPWD, "((?:[^"\\]|\\.)*)"', src)
if not m:
    print("NO-USERPWD")
    sys.exit(0)
print(codecs.decode(m.group(1), "unicode_escape"))
PYX

roundtrip() {  # roundtrip <label> <password>
  # Separate statements on purpose: under `set -u`, `local a="$1" b="$a"` FAILS,
  # because bash creates every name in one `local` as an unset local BEFORE
  # running the assignments -- so the earlier name is shadowed and unbound while
  # the later initialiser reads it. Measured. Without set -u it expands to empty,
  # which is the silent direction.
  local label="$1" pw="$2"
  local work="$TMP/rt-$label"
  FIX_PASS="$pw" drive "$work" >/dev/null 2>&1 || true
  [[ -s "$work/libcurl" ]] || fail "[$label] the real curl produced no --libcurl output"
  local got
  got="$(python3 -I "$TMP/userpwd.py" "$work/libcurl")"
  local want="domum-fixture-user:$pw"
  [[ "$got" == "$want" ]] || fail "[$label] curl parsed the credential as >$got<, wrote >$want<"
  printf '   ok: %-18s survived the config round trip\n' "$label"
}
roundtrip plain      'SENTINEL-pw-7f3a9c'
roundtrip dquote     'SENTINEL-a"b'
roundtrip backslash  'SENTINEL-a\b'
roundtrip both       'SENTINEL-a\"b'
roundtrip dollar     'SENTINEL-a$b`c'
roundtrip separators 'SENTINEL-a:b=c#d'
roundtrip space      'SENTINEL-a b c'
roundtrip tabish     'SENTINEL-a\tb'

# ===========================================================================
sect "9. a planted default .curlrc cannot weaken the send (what -q buys)"
# The CREDENTIAL was never what -q protects: a command-line --config is parsed
# after the default config, so our own `user` wins either way -- measured, and
# the first version of this section asserted the wrong property. What a planted
# config CAN do is add options this code does not set. Measured on this host,
# without -q: CURLOPT_SSL_VERIFYPEER 0 and VERIFYHOST 0 -- certificate
# verification on the mail send defeated -- plus an EXTRA CURLOPT_MAIL_RCPT,
# i.e. a second recipient for a report full of host state.
plant="$TMP/curlhome"; mkdir -p "$plant"
printf 'insecure\nmail-rcpt = "attacker@example.invalid"\n' > "$plant/.curlrc"
drive "$TMP/s9" CURL_HOME="$plant" >/dev/null 2>&1 || true
[[ -s "$TMP/s9/libcurl" ]] || fail "no --libcurl output for the planted-curlrc case"
grep -qE 'CURLOPT_SSL_VERIFYPEER, 0L' "$TMP/s9/libcurl" \
  && fail "a planted .curlrc disabled certificate verification despite -q"
grep -qE 'CURLOPT_MAIL_RCPT' "$TMP/s9/libcurl" \
  && fail "a planted .curlrc added a mail recipient despite -q"
grep -qF 'domum-fixture-user' "$TMP/s9/libcurl" \
  || fail "the real credential did not survive the planted .curlrc"
echo "   ok: neither 'insecure' nor the extra recipient was honoured"

# ===========================================================================
sect "10. the password never reaches stdout or stderr"
out="$(drive "$TMP/s10")" || true
grep -qaF 'SENTINEL-pw-7f3a9c' <<< "$out" && fail "the password appeared in the function's output"
out="$(drive "$TMP/s10b" CURL_RC=67)" || true
grep -qaF 'SENTINEL-pw-7f3a9c' <<< "$out" && fail "the password appeared in output on the FAILURE path"
echo "   ok: absent from both the success and the failure path"

# ===========================================================================
sect "11. the refusals: no message, no host, missing credential files"
out="$(env WORK="$TMP/s11" CLI="$MUTCLI" FIX_USER=u FIX_PASS=p bash -c '
  mkdir -p "$WORK"; source "$CLI" >/dev/null 2>&1
  die(){ echo "DIE: $*"; exit 90; }
  RECOVERY_PACK_SMTP_HOST=h RECOVERY_PACK_SMTP_PORT=465
  RECOVERY_PACK_SMTP_USERNAME_FILE=/dev/null RECOVERY_PACK_SMTP_PASSWORD_FILE=/dev/null
  smtp_send_message "$WORK/absent.eml"' 2>&1)" || true
grep -q 'DIE: smtp_send_message: no message file' <<< "$out" || fail "an absent message file was not refused: $out"

out="$(drive "$TMP/s11b" HOST_OVERRIDE=)" || true
grep -q 'DIE: RECOVERY_PACK_SMTP_HOST is required' <<< "$out" || fail "an empty host was not refused: $out"

out="$(drive "$TMP/s11c" PASS_FILE="$TMP/does-not-exist")" || true
grep -q 'DIE: SMTP credential files are missing' <<< "$out" || fail "a missing credential file was not refused: $out"
# A refusal must happen BEFORE curl is invoked at all.
[[ -e "$TMP/s11c/argv" ]] && fail "curl was invoked despite missing credentials"
echo "   ok: all three refuse, and the last one refuses before curl is reached"

# ===========================================================================
sect "12. it behaves the same under production's shell options"
# The probe above runs without errexit, so it cannot see an abort that
# production would take. This section drives the function in its own
# `set -euo pipefail` bash process.
out="$(env WORK="$TMP/s12" CLI="$MUTCLI" FIX_USER=u FIX_PASS='SENTINEL-strict' bash -c '
  set -euo pipefail
  source "$CLI" >/dev/null 2>&1
  die(){ echo "DIE: $*" >&2; exit 90; }
  mkdir -p "$WORK"
  printf "%s" "$FIX_USER" > "$WORK/u"; printf "%s" "$FIX_PASS" > "$WORK/p"
  printf "x\r\n" > "$WORK/m.eml"
  RECOVERY_PACK_SMTP_HOST=smtp.invalid RECOVERY_PACK_SMTP_PORT=465
  RECOVERY_PACK_SMTP_USERNAME_FILE="$WORK/u" RECOVERY_PACK_SMTP_PASSWORD_FILE="$WORK/p"
  DOMUM_EMAIL=a@example.invalid
  curl(){ return 0; }
  smtp_send_message "$WORK/m.eml"
  echo "STRICT-OK"' 2>&1)" || true
grep -qx 'STRICT-OK' <<< "$out" || fail "the function aborted under set -euo pipefail: $out"
echo "   ok: completes under set -euo pipefail"

# ===========================================================================
#  Mutations. Each names the observable it actually changes.
# ===========================================================================
# Mutations operate on a COPY, and MUTCLI is what the drivers below load.
# A suite that mutates the TRACKED file can be stopped mid-run and leave it
# mutated -- which happened twice -- and makes any concurrent run unsound: a
# deterministic suite failed because another full-suite loop had that file
# mutated while it read it. unmutate is therefore a pointer reset, not a file
# restore, so there is nothing to miss if the run stops early.
mutate() {  # mutate <python-file>
  MUTCLI="$TMP/cli-mutant"
  cp "$CLI" "$MUTCLI"
  python3 -I "$1" "$MUTCLI" || fail "the mutation did not apply"
}
unmutate() { MUTCLI="$CLI"; }

sect "13. MUTATION -- putting the credential back in argv must be caught"
cat > "$TMP/m1.py" <<'PY'
import io,sys
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
old='''  curl -q --config "$curl_cfg" \\\n    --silent --show-error --ssl-reqd \\\n'''
new='''  curl -q \\\n    --silent --show-error --ssl-reqd \\\n    --user "${smtp_user}:${smtp_pass}" \\\n'''
assert s.count(old)==1, "anchor matched %d times" % s.count(old)
io.open(p,"w",encoding="utf-8").write(s.replace(old,new,1))
PY
mutate "$TMP/m1.py"
drive "$TMP/mut1" >/dev/null 2>&1 || true
av="$(argv_lines "$TMP/mut1")"
unmutate
grep -qaF 'SENTINEL-pw-7f3a9c' <<< "$av" \
  || fail "the mutant did not put the password back in argv -- the mutation changed nothing"
echo "   ok: the mutant exposes the password in argv, which section 4 rejects"

sect "14. MUTATION -- dropping the retry options must be caught"
cat > "$TMP/m2.py" <<'PY'
import io,sys
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
old='''  if (( retries > 0 )); then
    retry_opts=(--retry "$retries" --retry-delay "$retry_delay" --retry-connrefused
                --retry-max-time 60)
  fi'''
new='''  if (( retries > 0 )) && [[ "$retries" != "$retries" ]]; then
    retry_opts=(--retry "$retries" --retry-delay "$retry_delay" --retry-connrefused
                --retry-max-time 60)
  fi'''
assert s.count(old)==1, "anchor matched %d times" % s.count(old)
io.open(p,"w",encoding="utf-8").write(s.replace(old,new,1))
PY
mutate "$TMP/m2.py"
drive "$TMP/mut2" >/dev/null 2>&1 || true
av="$(argv_lines "$TMP/mut2")"
unmutate
grep -qx -- '--retry' <<< "$av" && fail "the mutant still passed --retry -- the mutation changed nothing"
echo "   ok: the mutant sends with one attempt, which section 1 rejects"

sect "15. MUTATION -- leaving the credential file behind must be caught"
cat > "$TMP/m3.py" <<'PY'
import io,sys
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
old='''  rm -f "$curl_cfg"
  return "$rc"'''
new='''  return "$rc"'''
assert s.count(old)==1, "anchor matched %d times" % s.count(old)
io.open(p,"w",encoding="utf-8").write(s.replace(old,new,1))
PY
mutate "$TMP/m3.py"
out="$(drive "$TMP/mut3" CURL_RC=7)" || true
unmutate
grep -qx 'CFG-SURVIVED' <<< "$out" \
  || fail "the mutant removed the credential file anyway -- the mutation changed nothing"
echo "   ok: the mutant leaves the credential on disk, which section 6 rejects"

sect "16. MUTATION -- dropping -q must let a planted .curlrc win"
cat > "$TMP/m4.py" <<'PY'
import io,sys
p=sys.argv[1]; s=io.open(p,encoding="utf-8").read()
old='  curl -q --config "$curl_cfg" \\\n'
new='  curl --config "$curl_cfg" \\\n'
assert s.count(old)==1, "anchor matched %d times" % s.count(old)
io.open(p,"w",encoding="utf-8").write(s.replace(old,new,1))
PY
mutate "$TMP/m4.py"
drive "$TMP/mut4" CURL_HOME="$plant" >/dev/null 2>&1 || true
got_inject=no
if [[ -s "$TMP/mut4/libcurl" ]] \
   && grep -qE 'CURLOPT_SSL_VERIFYPEER, 0L' "$TMP/mut4/libcurl" \
   && grep -qE 'CURLOPT_MAIL_RCPT' "$TMP/mut4/libcurl"; then
  got_inject=yes
fi
unmutate
[[ "$got_inject" == yes ]] \
  || fail "the mutant did not let the planted .curlrc through -- the mutation changed no ANSWER"
echo "   ok: without -q the planted 'insecure' and extra recipient both apply"

# The tree must be pristine again.
cmp -s "$CLI" "$PRISTINE" \
  || fail "the tracked CLI differs from the pristine copy taken before the first
section -- something mutated it IN PLACE, so stopping this suite part-way would
leave the change behind and any concurrent run would read it"

echo
echo "PASS: smtp-transport-smoke (17 sections, 4 mutants)"
