#!/usr/bin/env bash
set -uo pipefail

# Proves the repository cannot be made to carry production configuration or
# secret material.
#
# The production config lives at /opt/domum-core-media/config/domum-media.conf,
# mode 0600 root-only, 11 KB of production topology -- domains, backup
# endpoints, SFTP hosts -- plus the path of every secret file. It was NOT
# gitignored, so `git add -A` in the production checkout would have staged it,
# and it showed as permanently untracked there, which trains the operator to
# ignore git status in production.
#
# Secret VALUES live in /etc/domum-core-media/secrets and are referenced by
# *_FILE, so the config is not a secret store. It is still production
# configuration that must never be committed.
#
# Hermetic: reads only this repository's own git metadata.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || fail "cannot enter the repository"

# $1 = path -> 0 ignored, 1 not ignored
is_ignored() { git check-ignore -q -- "$1"; }

sect "the real production config is ignored"
is_ignored config/domum-media.conf \
  || fail "config/domum-media.conf is NOT gitignored; 'git add -A' in the
production checkout would stage production configuration"
echo "  config/domum-media.conf cannot be staged"

sect "the example config is still visible to git"
# If the example were caught by the same rule the installer would have nothing
# to copy, and the fix would have broken setup instead of securing it.
is_ignored config/domum-media.conf.example \
  && fail "the .example was caught by the ignore rule; the installer copies it"
git ls-files --error-unmatch config/domum-media.conf.example >/dev/null 2>&1 \
  || fail "config/domum-media.conf.example is not tracked"
echo "  the .example is tracked and unignored"

sect "no production config is actually committed"
tracked="$(git ls-files | grep -E '(^|/)domum-media\.conf$' || true)"
[[ -z "$tracked" ]] || fail "a real production config is TRACKED: $tracked"
echo "  nothing matching domum-media.conf is in the index"

sect "the ignore rule is not so broad that it hides the whole config directory"
# Over-ignoring would silently drop config/ci.env, which CI needs.
is_ignored config/ci.env && fail "config/ci.env is ignored; CI reads it"
git ls-files --error-unmatch config/ci.env >/dev/null 2>&1 \
  || fail "config/ci.env is not tracked"
echo "  config/ci.env is still tracked"

sect "no secret material of any kind is tracked"
bad="$(git ls-files | grep -E '\.(key|pem|crt|p12|pfx)$|(^|/)secrets?/' || true)"
[[ -z "$bad" ]] || fail "secret-shaped files are TRACKED: $bad"
echo "  no .key/.pem/.crt/.p12/.pfx and no secrets/ directory in the index"

sect "mutation: removing the rule must make the config stageable again"
# Proves the assertion above is load-bearing rather than passing because of
# some other rule in the file.
TMP="$(mktemp -d)"
# The backup is taken BEFORE the mutation and the restore goes in the trap, so
# an interrupt between the two cannot leave this repository with a mutated
# .gitignore -- a test that edits the repo it is testing has to be safe to kill.
cp .gitignore "$TMP/gitignore.orig"
# shellcheck disable=SC2064
trap "cp '$TMP/gitignore.orig' '$REPO_ROOT/.gitignore' 2>/dev/null; rm -rf '$TMP'" EXIT
# shellcheck disable=SC2064
trap "cp '$TMP/gitignore.orig' '$REPO_ROOT/.gitignore' 2>/dev/null; rm -rf '$TMP'; exit 143" HUP INT TERM
grep -vFx 'config/domum-media.conf' .gitignore > "$TMP/gitignore.mut"
cp "$TMP/gitignore.mut" .gitignore
rc=0
git check-ignore -q -- config/domum-media.conf || rc=$?
cp "$TMP/gitignore.orig" .gitignore
[[ "$rc" -ne 0 ]] \
  || fail "the config is still ignored without its rule; the assertion proves nothing"
# And the restore must have worked, or this suite just damaged the repository.
is_ignored config/domum-media.conf || fail ".gitignore was not restored after the mutation"
echo "  without the rule it becomes stageable; .gitignore restored"

echo "PASS: repo-hygiene-smoke"
