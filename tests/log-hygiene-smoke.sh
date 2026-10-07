#!/usr/bin/env bash
set -uo pipefail

# The backup log receives restic's per-run output, and restic prints paths from
# the photo library on error. It must therefore be created restrictively, must
# stay bounded, and must still never be touched by a read-only invocation.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_ensure_dirs() {
  bash -c "
set -uo pipefail
DOMUM_LOG_DIR='$1'
eval \"\$(awk '/^ensure_dirs\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media-backup')\"
eval \"\$(awk '/^log\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media-backup')\"
ensure_dirs
${2:-}
"
}

# ---------------------------------------------------------------------------
# 1. A log that does not exist is created 0640, not world-readable.
# ---------------------------------------------------------------------------
L="$TMP_DIR/fresh"
run_ensure_dirs "$L" || fail "1: ensure_dirs failed"
[ -e "$L/backup.log" ] || fail "1: the log was not created"
perms="$(stat -c %a "$L/backup.log")"
[ "$perms" = "640" ] || fail "1: log created $perms, expected 640 (restic can print library paths)"

# ---------------------------------------------------------------------------
# 2. An EXISTING log is never touched -- the read-only report must not look
#    like backup activity.
# ---------------------------------------------------------------------------
before="$(stat -c %Y "$L/backup.log")"
sleep 1
run_ensure_dirs "$L" || fail "2: ensure_dirs failed on the second run"
after="$(stat -c %Y "$L/backup.log")"
[ "$before" = "$after" ] || fail "2: ensure_dirs changed the mtime of an existing log"

# ...and its permissions are not rewritten either.
chmod 0600 "$L/backup.log"
run_ensure_dirs "$L" || fail "2: ensure_dirs failed on the third run"
[ "$(stat -c %a "$L/backup.log")" = "600" ] \
  || fail "2: ensure_dirs overwrote the permissions of an existing log"

# ---------------------------------------------------------------------------
# 3. Logging still works when the log was created restrictively.
# ---------------------------------------------------------------------------
L2="$TMP_DIR/writable"
run_ensure_dirs "$L2" 'log "hello"' >/dev/null 2>&1 || fail "3: log() failed"
grep -q hello "$L2/backup.log" || fail "3: log() did not write through"

# ---------------------------------------------------------------------------
# 4. A logrotate config ships, bounds growth, and corrects permissions.
# ---------------------------------------------------------------------------
CFG="$REPO_ROOT/logrotate/domum-media"
[ -f "$CFG" ] || fail "4: no logrotate config ships"
grep -q '/var/log/domum-media/\*\.log' "$CFG" || fail "4: the config does not cover the domum-media logs"
grep -qE '^\s*rotate [0-9]+' "$CFG" || fail "4: growth is not bounded (no rotate)"
grep -qE '^\s*(weekly|daily|monthly)' "$CFG" || fail "4: no rotation interval"
grep -qE '^\s*create 0640 root root' "$CFG" || fail "4: rotation must create the log 0640 root root"
grep -qE '^\s*missingok' "$CFG" || fail "4: rotation must tolerate a missing log"

# ...and it is actually installed by both the installer and convergence.
grep -q 'logrotate.d/domum-media' "$REPO_ROOT/install.sh" \
  || fail "4: install.sh does not install the logrotate config"
grep -q 'logrotate.d/domum-media' "$REPO_ROOT/bin/domum-media" \
  || fail "4: convergence does not install the logrotate config"

# The world-readable default must not creep back in.
grep -E 'logrotate/domum-media' "$REPO_ROOT/install.sh" | grep -q -- '-m 0644' \
  || fail "4: the logrotate config itself should be installed 0644"

# ---------------------------------------------------------------------------
# The --help text lives in an UNQUOTED `cat <<EOF`, so a backtick or $( ) in it
# is command substitution, not documentation.
#
# Measured: usage text containing a backticked `apply --service <s>` printed as
# "  upgrades ONE ... Bare  is the" -- the backticked words were EXECUTED and
# vanished, and `<s>` inside the substitution parsed as an input redirection.
# shellcheck reported it as a parse error; `--help` would have shown it to anyone
# who looked.
#
# Scoped deliberately. A first version flagged every heredoc and tripped on
# `TIMESTAMP='$(date -Iseconds)'` inside a QUOTED one, which is literal and
# correct. A second flagged every unquoted `cat <<EOF` and tripped on
# "$(immich_postgres_data_dir)", which deliberately interpolates a real path into
# a message.
#
# So: a BACKTICK is always wrong in message text, and $( ) is only wrong in the
# `Usage:` block, where everything is documentation rather than a value.
for cli in "$REPO_ROOT/bin/domum-media" "$REPO_ROOT/bin/domum-media-backup" "$REPO_ROOT/bin/domum-media-report"; do
  [ -r "$cli" ] || continue
  all_unquoted="$(awk '/^[[:space:]]*cat <<EOF$/{inside=1; next} inside && /^EOF$/{inside=0} inside' "$cli")"
  if [ -n "$all_unquoted" ] && grep -q '`' <<< "$all_unquoted"; then
    grep -n '`' <<< "$all_unquoted" | head -3 >&2
    fail "$(basename "$cli"): a backtick in an unquoted heredoc is command
substitution. Message text would be executed and silently disappear."
  fi
  usage="$(awk '
    /^[[:space:]]*cat <<EOF$/ { buf=""; inside=1; next }
    inside && /^EOF$/         { if (buf ~ /Usage:/) printf "%s", buf; inside=0; next }
    inside                    { buf = buf $0 "\n" }
  ' "$cli")"
  if [ -n "$usage" ] && grep -qE '\$\(' <<< "$usage"; then
    grep -nE '\$\(' <<< "$usage" | head -3 >&2
    fail "$(basename "$cli"): \$( ) in the Usage heredoc. Help text is
documentation, not a value: quote the heredoc or build that line separately."
  fi
done
echo "  no backticks in unquoted heredocs; no substitution in the Usage block"

echo "PASS: log hygiene smoke test"
