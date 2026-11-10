# domum-core-media/SEC-03 Protect main and narrow the GitHub credential on this host

| Field | Value |
| --- | --- |
| Status | BLOCKED — needs the owner's approval; these are changes on GitHub |
| Priority and reason | P1 — a push to `main` becomes root at the next update |
| Effort and change risk | 15 min; low, fully reversible in repo settings |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | owner, or an agent once the owner says so; findings F-02, F-03 |
| Dependencies | none |

## Outcome

`main` accepts direct and force pushes today, and `domum-media update` applies
whatever `main` holds as root. The token on this server can write to every
repository on the account. After this task `main` changes only through a pull
request with CI passing, and the server's credential reaches this repository only.

## Scope and setup

GitHub settings only. No file in the repository changes. Branch protection is
free on a public repository.

## Before editing

- `gh api repos/{owner}/{repo}/branches/main/protection` returns HTTP 404 "Branch not protected". If it returns a rule set, read it before changing anything.
- Find the exact CI check name: `gh pr checks <any recent PR number>`.

## Implementation and checkpoints

1. In repository Settings → Branches (or a ruleset), protect `main`: require a pull request, require the CI check to pass, block force pushes and deletion. Zero required approvals is fine for a single owner.
   - **Check** `gh api repos/{owner}/{repo}/branches/main/protection -q '.required_status_checks.contexts, .allow_force_pushes.enabled'`
   - **Expected** the check name, then `false`
   - **Time and failure action** 5 min; if merging your own PR becomes impossible, lower required approvals to 0 rather than removing protection
2. Prove the block. From a scratch clone: `git commit --allow-empty -m probe && git push origin HEAD:main`.
   - **Expected** the push is rejected with a protected-branch message. Then `git reset --hard HEAD~1`.
   - **Time and failure action** 2 min; if it is accepted, revert the probe commit with a PR and re-check the rule
3. Replace the classic token on this host with a fine-grained token limited to this repository (Contents, Pull requests, Actions: read/write). `gh auth login` and paste it.
   - **Check** `gh auth status`
   - **Expected** no all-repositories `repo` scope listed
   - **Time and failure action** 5 min; keep the old token until `gh pr list` works with the new one, then revoke it
4. Optional: make the SSH key on this host a deploy key for this repository rather than an account key.

## Acceptance

- Step 2's rejection is the negative test.
- `gh pr list` and `git fetch` still work from the dev checkout.
- Owner gate: all of it.

## Rollback and stop conditions

Delete the protection rule; re-issue a token. Stop if the production checkout can no longer fetch (it uses anonymous HTTPS today, which protection does not affect).

## Verification handoff

- **Result** _not started_
- **References** none in Git
- **Evidence** _per checkpoint_
- **Next model** the 404 in **Before editing** is now a JSON rule
- **Open items** the update command still trusts `main` unconditionally; signed-commit verification before `update` would be a further task if wanted
