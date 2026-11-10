# domum-core-media/SEC-02 CI guard: identifiers stay out, secrets are scanned

| Field | Value |
| --- | --- |
| Status | QUEUED |
| Priority and reason | P2 — keeps D-1 true after SEC-01 |
| Effort and change risk | 45 min; low |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker; findings F-01, F-14; overlaps the gitleaks half of `../../task-12-ci-yamllint-gitleaks.md` |
| Dependencies | SEC-01 landed (the guard fails until then) |

## Outcome

Nothing stops a real identifier or a secret being committed again. After this
task CI fails when a tracked file contains a private-range address outside the
documentation ranges, a tailnet address, or a backup-account pattern, and a
secret scanner runs on every push.

## Scope and setup

- Add `tests/identifier-audit.py` in the style of `tests/no-conflict-markers-audit.py`:
  tracked text files only, fails when it scans zero files, prints what it matched and where.
- **Do not put the real domain in the audit.** That would publish it again.
  Match shapes: RFC 1918 addresses other than `10.0.0.x` examples already in
  docs, the CGNAT range Tailscale uses, and `u` followed by five or more digits.
- Add a smoke test with one fixture that must fail and one that must pass.
- Add both to `.github/workflows/compose-validate.yml` by name; `tests/ci-coverage-audit.sh` enforces that.
- Add a gitleaks step using the upstream action pinned by commit SHA.
- Reconcile `task-12`: mark its gitleaks half as covered here.

## Before editing

- SEC-01 landed: `git grep -c 'DOMUM_DOMAIN:-example.test' -- bin` prints two files.
- Baseline: `tests/ci-coverage-audit.sh` exits 0.

## Implementation and checkpoints

1. Write the audit and run it on the tree.
   - **Check** `python3 tests/identifier-audit.py`
   - **Expected** exit 0, with a printed count of files scanned greater than zero
   - **Time and failure action** 20 min; a hit is either a real leftover (fix it) or a legitimate example (narrow the pattern and say why in the audit)
2. Write the smoke test with a failing and a passing fixture.
   - **Check** `tests/identifier-audit-smoke.sh`
   - **Expected** exit 0; the failing fixture is reported with its file and line
   - **Time and failure action** 10 min
3. Wire both, plus gitleaks, into the workflow.
   - **Check** `tests/ci-coverage-audit.sh`
   - **Expected** exit 0
   - **Time and failure action** 10 min

## Acceptance

- Pre-review: a scratch commit adding a tailnet-range address to a doc makes the audit exit non-zero and name the line.
- Pre-review: CI green on the PR, with the new steps visible in the run.
- Regression: `python3 tests/pipefail-grep-audit.py` still exits 0 (the new smoke test is in its scope).

## Rollback and stop conditions

`git revert`. Stop if gitleaks flags an existing commit: do not print the match; tell the owner the file and commit privately.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint_
- **Next model** `python3 tests/identifier-audit.py; echo $?` prints `0`
- **Open items** —
