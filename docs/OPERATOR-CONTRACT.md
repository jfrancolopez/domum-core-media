# The operator contract: what a wrapper may assert on

## Why this document exists

Three operator wrappers have aborted **correct** production states. None of them
had a bug in its logic. Each asserted on something that was never a contract.

| # | The assertion | Why it broke |
|---|---|---|
| 1 | `/srv/snapshots` is empty / no subvolumes exist | True before the first migration, permanently false after it. An absolute claim about a storage topology that was always going to change. |
| 2 | `grep 'recovery point  : verified'` | The wording changed when the summary was split into four separate claims. It aborted a migration that had completed perfectly. |
| 3 | `grep "^make_pre_upgrade_point()" /usr/local/bin/domum-media` | A private helper from a refactor that was attempted, broke, and was reverted. It had never existed in any merged revision. |

All three escaped review for the same reason: **operator scripts lived outside
the repository, so CI never saw them.** They are in `operator/` now, and
`tests/operator-wrapper-audit.py` runs against them.

Incident 3 is the instructive one. The wrapper was *right* to refuse — the
installed CLI genuinely could not perform the upgrade, because `service_upgrade`
called `assert_pre_upgrade_possible`, which was also missing. But it refused for
the wrong reason, and the right reason was invisible: the CLI would have died
*after stopping Plex*. A correct refusal reached by invalid reasoning is not a
safety mechanism; it is luck.

## What a wrapper MAY assert on

* **Exit status.** `storage protection plex` prints a state word and exits 0 only
  when it is `protected`. `storage verify-archive <point>` exits 0 or not. This
  is why those subcommands exist.
* **Capability tokens.** `domum-media capabilities --has <token>` — see below.
* **Structured output.** `cleanup images --json`, read with `jq`.
* **Files on disk.** A snapshot directory, a `.recovery` file, an archive and its
  `.sha256`.
* **External contracts.** `docker inspect` fields, `stat -c %i`, `btrfs property
  get`, `systemctl is-enabled`, `sha256sum`, `git rev-parse`. These are stable
  interfaces owned by other projects.

## What a wrapper MUST NOT assert on

* **The CLI's prose.** Any human-readable line. It is written for a human and its
  wording is not versioned. `cmd | grep 'some phrase'` is the forbidden shape.
* **The CLI's source text.** `grep <anything> /usr/local/bin/domum-media`. The
  binary's text is not a contract — only its behaviour is. This rule is stated
  as "never grep the binary", not "never grep for a function name", because
  incident 3's actual form looped over names held in a **variable**:

  ```bash
  for fn in service_upgrade … make_pre_upgrade_point …; do
    grep -q "^$fn()" /usr/local/bin/domum-media || abort …
  ```

  No literal function name appears on the grep line, so a name-based rule misses
  it entirely.
* **Absolute claims about mutable state.** Not "no subvolumes exist" but "the
  topology is unchanged since this capture" — `storage topology --verify`.
* **A revision constant baked into the repository it pins.** It goes stale by
  construction. `--expect-revision <sha>` is an argument the operator passes;
  what is *always* checked is that the installed binary's sha256 equals the
  production checkout's, which is the claim that actually matters. A revision pin
  alone says nothing about `/usr/local/bin`.

## The capability contract

```
domum-media capabilities                 # one semantic token per line
domum-media capabilities --has <token>   # 0 supported, 1 absent, 2 unknown
```

Exit code 2 matters: a script asking about a token this binary has never heard of
must not read the answer as a yes.

Tokens are promises about **behaviour**. Private function names, dispatcher
wiring and prose may all change underneath a token freely. A token is never
renamed in place.

Advertisement is tied to reality in both directions:

* **At run time**, each token is gated on `declare -F` of its implementation, so
  a token disappears if its implementation does. This is the half that matters on
  the operator's host — it describes the binary that is actually installed.
* **In CI**, `tests/capabilities-contract-audit.py` walks `main()`'s case
  statement and each subcommand dispatcher and proves the advertised argv path
  genuinely reaches that implementation. A capability whose dispatcher line is
  deleted stops being reachable and fails.

Writing that audit exposed two of its own blind spots, both worth recording
because they are easy to reintroduce:

* a **nested `case`** truncated the branch at the inner `;;`, hiding `--verify)`
  inside the `topology)` branch;
* the `apply` branch's **comment** mentions `service_upgrade`, so deleting the
  real call left the capability still looking dispatchable until comments were
  stripped. Documentation is not wiring.

## The structured cleanup interface

`cleanup images --json` emits one record per **relevant** image:

```json
{"id": "sha256:…", "candidate": false, "in_use": true,
 "recovery_referenced": true, "local": true,
 "recovery_points": ["plex-…-pre-upgrade"], "tags": []}
```

The record set is deliberately **wider** than the candidate set. "Is this image
still protected?" cannot be answered from a candidate list, because a candidate
list cannot distinguish *protected* from *never considered* — which is exactly
the ambiguity that made the old `0 named by a recovery point` line unfalsifiable.
So a wrapper asks two questions: is the image in the records at all, and is it a
candidate.

`--json` and the human report are thin filters over one decision function,
`cleanup_image_decisions`, so they cannot disagree.
`tests/cleanup-images-json-smoke.sh` asserts that structurally *and* by comparing
both outputs over one fixture, and kills a mutant that inverts the JSON flag.

## One wrapper, any service

`operator/domum-media-upgrade-service.sh` takes the service as a **positional
argument**. It was `${DOMUM_SVC:-plex}` on a file named `-upgrade-plex.sh` while
Plex was the only migrated service with a staged image; Calibre-Web joined it on
2026-10-09, and driving a second service through an environment variable on a
file named after the first is how the wrong service gets upgraded at 2am.

Generalising it exposed a real defect that only a rehearsal finds: `SVC_PATH` was
derived at the top of the script, **before** the argument loop, so with the
service positional it became `"$DATA_ROOT/"` and stage 4 checked the inode of the
data root itself. The fixture reported it as

```
ABORT: /tmp/.../f/data/ is not a Btrfs subvolume (inode 424656, expected 424663)
```

Section 30c now drives the wrapper for `calibre-web` end to end and asserts it
checks its *own* path, upgrades only itself, leaves Plex untouched, and names the
service it upgraded.

## Rehearsal, not review

`operator/domum-media-upgrade-service.sh` is rehearsed in
`tests/service-upgrade-integration-smoke.sh` against a production-shaped fixture:
Plex on `58f13a1df833` with `7f9a1d574958` staged, four protected subvolumes with
their retained post-migration proof snapshots, eleven containers, Calibre-Web an
ordinary directory with its own staged image.

Its roots are overridable **only** for this purpose; an unset environment gives
the production paths. The root check is not weakened — the rehearsal runs under
`unshare -r`, where the calling user maps to uid 0, so `[ "$(id -u)" -eq 0 ]`
runs exactly as written and passes honestly.

Rehearsal earns its place by finding things review does not. In this round it
found that the fixture's docker stub stripped `-f <file>` arguments
unconditionally, which also ate the format argument of `docker inspect -f`. The
CLI uses `--format` and was unaffected; the wrapper uses `-f` and broke.

One section deserves particular note: **the wrapper's scope proof is proven
independent of the CLI's.** The CLI's own before/after container comparison is
blinded, another service is made to move, and the wrapper must still catch it.
Without that, "asserted twice by two implementations" would be a claim rather
than a fact.

## Failure behaviour

**Before deployment.** Distinguish "refused and changed nothing" from "ran and
something is wrong" — both exit non-zero, and reporting the first as a
verification failure reads as alarming when it is the gate working. Then assert
the service is still **running**, and if not, name the one command to bring it
back.

**After deployment.** Verify the rollback material is complete and name it:
recovery point, archive path, recorded image id. Then **stop**. The wrapper does
not roll back on its own. A rollback is itself a stop/restore/recreate, and
improvising one is the shape of the two "warn and continue" incidents. The
decision is the operator's, and the one command to make it is printed.
