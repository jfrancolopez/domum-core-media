# Task 12 — CI: add yamllint and gitleaks  [shared-philosophy]

## Reconciliation with SEC-02

- The Gitleaks portion is implemented by
  [SEC-02](security-2026-11/tasks/SEC-02-ci-identifier-and-secret-scan.md),
  merged in PR #198: the v3.0.0 action is SHA-pinned and runs on branch pushes
  and pull requests with full history available.
- SEC-02 locally scanned the complete repository history with no findings and
  confirmed a synthetic committed AWS credential is detected (match redacted).
- Task 12 as a whole remains open for YAML linting and `.shellcheckrc`; SEC-02
  does not add either or change Compose YAML.

## Objective
Bring this repo's CI up to the sibling's coverage: YAML linting and secret
scanning, alongside the existing bash-syntax, shellcheck, smoke-test, and
compose-config jobs.

## Files involved
- `.github/workflows/compose-validate.yml` (or a second small workflow file)
- `.yamllint.yml` (new — copy domum-core's)
- `.gitleaks.toml` (new — default config; no allowlist needed here)
- `.shellcheckrc` (new — copy domum-core's: `disable=SC1091`,
  `external-sources=true`, since runtime-sourced config can't be followed)

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
2. **Gitleaks covered by SEC-02.** It uses
   `gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e`
   (v3.0.0) with `fetch-depth: 0`. The redacted local history scan was clean;
   no `.gitleaks.toml` allowlist is required.
3. Add YAML linting as a job/step in the existing workflow (keep one workflow
   file — this repo's style).
3b. Add `.shellcheckrc` so local runs match CI; the existing shellcheck job
   picks it up automatically.
4. Fix any yamllint complaints in compose files (expect minor whitespace
   only; do not restructure YAML for the linter — tune the config instead).

## Testing plan
- Branch push: all jobs green.
- Deliberately add a fake AWS key in a scratch commit locally and confirm
  `gitleaks git` catches it (do not push). **Covered by SEC-02.**

## Rollback plan
Delete the jobs/config files.

## Dependencies
None. Blocks task 34 (the catalog-consistency CI test extends this
workflow).

## Risk / complexity / token size
Low (CI only). Small. ~6k tokens.

## Suggested order
Phase 0, after task 18.
