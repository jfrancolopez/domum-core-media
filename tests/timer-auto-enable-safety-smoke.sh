#!/usr/bin/env bash
set -euo pipefail

# Proves that installation and convergence cannot silently enable automatic
# image deployment.
#
# This matters because sync_timer_overrides is reached by `apply`, `init`,
# `configure` and `configure --non-interactive` -- and `domum-media update`
# execs `apply`. A hardcoded enable list there means routine convergence can
# resume automatic deployment without anyone asking for it.
#
# The assertions execute the real shipped functions with systemctl stubbed;
# nothing is enabled, disabled, or reloaded.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LIST="$REPO_ROOT/systemd/auto-enable.timers"

# Timers that must never be enabled by installation or convergence.
DEPLOYMENT_TIMERS=(domum-media-image-refresh.timer)

# ---------------------------------------------------------------------------
# 1. The canonical list exists and excludes every deployment timer.
# ---------------------------------------------------------------------------
[[ -r "$LIST" ]] || fail "missing canonical auto-enable list: $LIST"

parsed="$(sed -E 's/#.*//; s/[[:space:]]+//g' "$LIST" \
  | grep -E '^domum-media-[A-Za-z0-9-]+\.timer$' || true)"
[[ -n "$parsed" ]] || fail "canonical list parsed to nothing"

for timer in "${DEPLOYMENT_TIMERS[@]}"; do
  if grep -qx "$timer" <<< "$parsed"; then
    fail "$timer is listed in $LIST; deployment timers must never auto-enable"
  fi
done

# The protective timers must still be enabled, or the fix has broken backups.
for timer in domum-media-backup.timer domum-media-check.timer; do
  grep -qx "$timer" <<< "$parsed" || fail "$timer is missing from $LIST"
done

# ---------------------------------------------------------------------------
# 2. Every unit referenced by the list must actually ship.
# ---------------------------------------------------------------------------
while IFS= read -r timer; do
  [[ -f "$REPO_ROOT/systemd/$timer" ]] || fail "$LIST names $timer, which does not exist"
done <<< "$parsed"

# ---------------------------------------------------------------------------
# 3. Behavioral: the CLI's sync_timer_overrides must enable exactly the list.
#    bin/domum-media guards its main invocation, so it can be sourced.
# ---------------------------------------------------------------------------
enabled_log="$TMP_DIR/cli-enabled"
: > "$enabled_log"

(
  DOMUM_DIR="$REPO_ROOT"
  export DOMUM_DIR
  # shellcheck disable=SC1091
  source "$REPO_ROOT/bin/domum-media"

  # Neutralise everything with a side effect; keep the enable path real.
  systemctl() {
    if [[ "${1:-}" == "enable" ]]; then
      shift
      while [[ "${1:-}" == --* ]]; do shift; done
      printf '%s\n' "$@" >> "$enabled_log"
    fi
    return 0
  }
  write_timer_override() { return 0; }
  sync_unattended_upgrades() { return 0; }

  sync_timer_overrides >/dev/null 2>&1
) || fail "sync_timer_overrides failed under stubbed systemctl"

[[ -s "$enabled_log" ]] || fail "sync_timer_overrides enabled nothing at all"

for timer in "${DEPLOYMENT_TIMERS[@]}"; do
  if grep -qx "$timer" "$enabled_log"; then
    fail "sync_timer_overrides enabled $timer; convergence must never deploy"
  fi
done
grep -qx 'domum-media-backup.timer' "$enabled_log" \
  || fail "sync_timer_overrides stopped enabling the backup timer"

# What it enabled must match the canonical list exactly.
if ! diff -q <(sort -u "$enabled_log") <(sort -u <<< "$parsed") >/dev/null; then
  fail "sync_timer_overrides enabled a set different from $LIST: $(sort -u "$enabled_log" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 4. Behavioral: the installer's unit step must do the same.
#    install.sh exits when sourced unprivileged, so its real function text is
#    extracted and executed rather than copied.
# ---------------------------------------------------------------------------
installer_log="$TMP_DIR/installer-enabled"
: > "$installer_log"

fn_text="$(awk '/^install_systemd_units\(\) \{/,/^\}/' "$REPO_ROOT/install.sh")"
[[ -n "$fn_text" ]] || fail "could not extract install_systemd_units from install.sh"

(
  INSTALL_DIR="$REPO_ROOT"
  systemctl() {
    if [[ "${1:-}" == "enable" ]]; then
      shift
      while [[ "${1:-}" == --* ]]; do shift; done
      printf '%s\n' "$@" >> "$installer_log"
    fi
    return 0
  }
  install() { return 0; }
  eval "$fn_text"
  install_systemd_units >/dev/null 2>&1
) || fail "install_systemd_units failed under stubs"

[[ -s "$installer_log" ]] || fail "install_systemd_units enabled nothing at all"
for timer in "${DEPLOYMENT_TIMERS[@]}"; do
  if grep -qx "$timer" "$installer_log"; then
    fail "install.sh enabled $timer; bootstrap must never start deploying"
  fi
done
if ! diff -q <(sort -u "$installer_log") <(sort -u <<< "$parsed") >/dev/null; then
  fail "install.sh enabled a set different from $LIST: $(sort -u "$installer_log" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 5. No hardcoded deployment timer may sit next to a systemctl enable call.
#    Guards against a future edit reintroducing the literal list.
# ---------------------------------------------------------------------------
for f in "$REPO_ROOT/install.sh" "$REPO_ROOT/bin/domum-media"; do
  for timer in "${DEPLOYMENT_TIMERS[@]}"; do
    if grep -n "systemctl enable" -A 8 "$f" | grep -q "$timer"; then
      fail "$f still passes $timer to systemctl enable"
    fi
  done
done

# ---------------------------------------------------------------------------
# 6. The parser must reject anything that is not a domum-media timer unit.
# ---------------------------------------------------------------------------
cat > "$TMP_DIR/hostile.timers" <<'EOF'
# comment mentioning domum-media-image-refresh.timer
domum-media-backup.timer
  domum-media-check.timer
not-a-unit
/etc/passwd
domum-media-backup.service
EOF
hostile="$(sed -E 's/#.*//; s/[[:space:]]+//g' "$TMP_DIR/hostile.timers" \
  | grep -E '^domum-media-[A-Za-z0-9-]+\.timer$' || true)"
[[ "$(printf '%s' "$hostile" | wc -l)" -eq 1 ]] \
  || fail "parser accepted unexpected entries: $hostile"
grep -qx 'domum-media-backup.timer' <<< "$hostile" || fail "parser dropped a valid entry"
grep -q 'image-refresh' <<< "$hostile" && fail "parser accepted a timer named only inside a comment"
grep -q 'passwd\|not-a-unit\|\.service' <<< "$hostile" && fail "parser accepted a non-timer entry"

echo "PASS: timer auto-enable safety smoke test"
