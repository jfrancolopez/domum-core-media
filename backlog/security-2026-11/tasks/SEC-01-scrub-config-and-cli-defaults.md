# domum-core-media/SEC-01 Scrub identifiers from the config example and CLI defaults

| Field | Value |
| --- | --- |
| Status | IN_PROGRESS |
| Priority and reason | P1 — decision D-1; the largest remaining disclosure in tracked files |
| Effort and change risk | 45–60 min; medium, because a CLI default changes |
| Target and baseline | `domum-core-media`, branch off current `origin/main` = `e53adf2` (2026-11-10); security audit baseline `e0754a8` |
| Owner and evidence | worker; finding F-01, decision D-1 |
| Dependencies | SEC-00 landed |

## Outcome

Today `config/domum-media.conf.example` carries the real domain (eight occurrences: the base domain and seven service hosts), a
real LAN address, and the real off-site backup account and host; and both CLIs
default `DOMUM_DOMAIN` to the real domain. After this task the example uses
`example.test`, a documentation-range address and a placeholder account, and
the CLIs carry no real domain.

## Scope and setup

- Work in a worktree off `origin/main`. Hermetic tests only; no production path.
- Change: `config/domum-media.conf.example`, the `DOMUM_DOMAIN` default in
  `bin/domum-media` and `bin/domum-media-backup` (one line each; find with
  `git grep -n 'DOMUM_DOMAIN:-' -- bin`), and the backup account and host in
  `docs/P0-BACKUP-BASELINE.md`, `docs/SETUP-HETZNER-STORAGE-BOX-B11.md`,
  `docs/SETUP-RESTIC.md`.
- Preserve: `config/ci.env` values CI depends on; every variable name.
- The filesystem UUID in six docs is measured evidence. Leave it; it identifies
  nothing reachable.
- **Design choice to make and record:** the new default is `example.test`. Do
  not make the variable required (`:?`) in this task; that turns a missing
  config line into a hard failure and belongs in its own change.
- Out of scope: Git history, deployment.

## Before editing

- `git merge-base --is-ancestor <SEC-00 landed commit> HEAD` exits 0. If SEC-00
  landed by squash, instead confirm `git grep -c '<real domain>' -- docs` finds nothing.
- Baseline: `tests/repo-hygiene-smoke.sh` exits 0 (seconds). If it fails, stop and record.

## Implementation and checkpoints

1. Replace the domain, address and backup account in `config/domum-media.conf.example`.
   - **Check** `git grep -nE 'example\.test|192\.0\.2\.' -- config/domum-media.conf.example`
    - **Expected** all eight domain occurrences and the LAN line show placeholders; the SFTP example uses a placeholder account and host; no real value remains in the file
   - **Time and failure action** 10 min; if a test fixture copies real values from the example, stop and list the fixtures
2. Change the two CLI defaults to `example.test`.
    - **Check** `git grep -n 'export DOMUM_DOMAIN="${DOMUM_DOMAIN:-' -- bin`
    - **Expected** two lines, both `example.test`
    - **Note** the broader `DOMUM_DOMAIN:-` search also matches three empty-value probes; those are not defaults and must remain unchanged.
   - **Time and failure action** 5 min
3. Replace the backup account and host in the three docs with `uNNNNNN` and a placeholder host.
   - **Check** `git grep -cE 'u[0-9]{5,}' -- docs config`
   - **Expected** no output
   - **Time and failure action** 10 min
4. Run the suites that load config.
   - **Check** `tests/checkup-produces-output-smoke.sh && tests/immich-secret-propagation-smoke.sh && tests/repo-hygiene-smoke.sh`, then the `docker compose … config -q` step exactly as written in `.github/workflows/compose-validate.yml`
   - **Expected** all exit 0
   - **Time and failure action** 2–3 min; a failure that depends on the old domain is a fixture to fix, not a reason to restore it

## Acceptance

- Pre-review: `git grep -c '<real domain>'` over the whole tree finds nothing.
- Pre-review: shellcheck as in `CLAUDE.md` §9 exits 0; CI green on the PR.
- Regression: a config with no `DOMUM_DOMAIN` line now yields `example.test`, not the real domain. Assert it in a test that runs the real `load_cfg`.
- **Owner gate before deployment:** the owner confirms production's config sets `DOMUM_DOMAIN` explicitly (`sudo grep -c '^DOMUM_DOMAIN=' /opt/domum-core-media/config/domum-media.conf` prints `1`). If it prints `0`, production relies on the default and deploying this would change every hostname. Do not deploy; add the line first.

## Rollback and stop conditions

`git revert`. Stop if any test needs a real identifier to pass.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _each checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** `git grep -c 'DOMUM_DOMAIN:-example.test' -- bin` prints two files; next is SEC-02
- **Open items** the owner gate above
