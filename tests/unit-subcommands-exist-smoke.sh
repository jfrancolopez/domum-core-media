#!/usr/bin/env bash
set -uo pipefail

# CLAUDE.md section 9 says plainly:
#
#   `systemd-analyze verify` only checks unit syntax and that `ExecStart`
#   binaries exist. It cannot detect a unit invoking a subcommand the CLI does
#   not implement. Verify subcommand existence separately.
#
# This is that separate verification. It exists because the live host carries
# /etc/systemd/system/domum-media-hot-prune.service with
#
#   ExecStart=/usr/local/bin/domum-media hot prune
#
# and the CLI has no `hot` subcommand at all. That unit is disabled, so it is
# harmless -- but nothing in CI would have stopped it being shipped, and a timer
# that fires a nonexistent subcommand fails silently in the journal, which is the
# worst way for a scheduled job to not work.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

checked=0
while IFS= read -r line; do
  # Only the project's own entrypoints; the dr-reminder unit runs /bin/sh.
  case "$line" in
    *"/usr/local/bin/domum-media "*)   bin=domum-media ;;
    *"/usr/local/bin/domum-media-backup"*) bin=domum-media-backup ;;
    *) continue ;;
  esac

  args="${line#*/usr/local/bin/$bin}"
  # shellcheck disable=SC2086
  set -- $args
  sub="${1:-}"
  [[ -n "$sub" ]] || continue          # bare invocation, nothing to check

  checked=$(( checked + 1 ))
  case "$bin" in
    domum-media)
      # The dispatcher is a case statement over the first argument.
      grep -qE "^\s+${sub}[)|]" "$REPO_ROOT/bin/domum-media" \
        || grep -qE "^\s+[a-z|-]*\|${sub}\)" "$REPO_ROOT/bin/domum-media" \
        || fail "systemd unit invokes '$bin $sub', which the CLI does not dispatch: $line"
      ;;
    domum-media-backup)
      # This one takes --flags rather than subcommands.
      case "$sub" in
        --*) grep -qE -- "^\s+${sub}[)|]" "$REPO_ROOT/bin/domum-media-backup" \
               || grep -qE -- "\\${sub}\)" "$REPO_ROOT/bin/domum-media-backup" \
               || fail "systemd unit invokes '$bin $sub', which the script does not handle: $line" ;;
        *)   grep -qE "^\s+${sub}[)|]" "$REPO_ROOT/bin/domum-media-backup" \
               || fail "systemd unit invokes '$bin $sub', which the script does not handle: $line" ;;
      esac
      ;;
  esac
done < <(grep -h '^ExecStart=' "$REPO_ROOT/systemd"/*.service)

(( checked > 0 )) || fail "no ExecStart subcommands were checked; this test is not looking at anything"
echo "  checked $checked unit subcommand(s)"

# A unit that exists on the host but not in the repo cannot be verified here and
# is drift by definition. Reported, not failed: the repo cannot fix the host.
if [[ -d /etc/systemd/system ]]; then
  for f in /etc/systemd/system/domum-media-*.service /etc/systemd/system/domum-media-*.timer; do
    [[ -e "$f" ]] || continue
    b="$(basename "$f")"
    [[ -f "$REPO_ROOT/systemd/$b" ]] \
      || echo "  NOTE: $b is installed on this host but absent from systemd/ (drift)"
  done
fi

echo "PASS: unit subcommands exist smoke test"
