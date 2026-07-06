# Task 12 — CI: add yamllint and gitleaks  [shared-philosophy]

## Objective
Bring this repo's CI up to the sibling's coverage: YAML linting and secret
scanning, alongside the existing bash-syntax, shellcheck, smoke-test, and
compose-config jobs.

## Files involved
- `.github/workflows/compose-validate.yml` (or a second small workflow file)
- `.yamllint.yml` (new — copy domum-core's)
- `.gitleaks.toml` (new — default config; no allowlist needed here)

## Reason
domum-core runs yamllint + gitleaks + shellcheck + compose-validate; this
repo runs only the latter two (plus its excellent smoke test, which core is
adopting in return). Gitleaks is the one that matters: the sibling repo has
already lived through a committed secret (Zigbee network key), and this repo
handles more credentials (Cloudflare token, Immich DB password, restic
passwords, SFTP keys) — all correctly kept out of git today, and a scanner
keeps it that way for the cost of one CI job. Yamllint is cheap consistency
for the compose tree.

Not proposing anything heavier — no CD, no scheduled workflows.

## Implementation plan
1. Copy `.yamllint.yml` from domum-core verbatim (200-char lines, 2-space
   indents); extend `ignore:` with `nimbalyst-local/` and `backlog/` if
   needed.
2. Add a gitleaks job identical to domum-core's (`gitleaks/gitleaks-action@v2`,
   `fetch-depth: 0`). Run it once locally first (`gitleaks detect`) — if
   history is clean, no `.gitleaks.toml` allowlist is required; if it flags
   something, STOP and report the finding instead of allowlisting it.
3. Add both as jobs in the existing workflow (keep one workflow file — this
   repo's style).
4. Fix any yamllint complaints in compose files (expect minor whitespace
   only; do not restructure YAML for the linter — tune the config instead).

## Testing plan
- Branch push: all jobs green.
- Deliberately add a fake AWS key in a scratch commit locally and confirm
  `gitleaks detect` catches it (do not push).

## Rollback plan
Delete the jobs/config files.

## Dependencies
None.

## Risk / complexity / token size
Low (CI only). Small. ~6k tokens.

## Suggested order
12.
