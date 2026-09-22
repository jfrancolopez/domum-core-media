# Restore verification

A backup that has never been restored is a hypothesis.

This records, durably and machine-readably, that a real restore actually
produced a usable artefact. Nothing else may write that record.

## What does and does not count

| | Counts as restore verification? |
|---|---|
| A successful backup run | **No.** It proves data was written, not that it can come back. |
| `restic check` / `--check-deep` | **No.** It proves repository integrity, not that the artefact restores and is usable. |
| A documented restore that once succeeded | **No.** History is not a current machine-readable fact. |
| An isolated restore whose artefact revalidated | **Yes.** |

The P0 scratch restore in [P0-BACKUP-BASELINE.md](P0-BACKUP-BASELINE.md) really
happened, and it remains valid historical evidence. It is deliberately **not**
converted into a verification record: it left no machine-readable result, and
fabricating one would make the report assert something it cannot stand behind.
The first record will be written by the first run of the command below.

## Running it

```bash
sudo domum-media backup verify-restore cloud
```

What it does, in order:

1. Creates a scratch directory under `/var/lib/domum-media/restore-verification/`
   and refuses to run at all if that location resolves inside a live data root.
2. Restores **only** the Immich database dump from the target's latest snapshot
   into that scratch directory. No live path is written.
3. Revalidates the restored bytes with the **same three checks** the dump had to
   pass when it was written: `gzip -t`, a minimum plausible size, and the
   `-- PostgreSQL database dump complete` footer.
4. Records the outcome.
5. Removes the scratch directory — on success, on failure, and on interruption.

It performs **no repository write**: no `backup`, `forget`, `prune`, `repair`,
`init` or `unlock`. Retention is untouched.

A failure is recorded as a failure rather than being silently dropped, and the
command exits non-zero.

## The record

`/var/lib/domum-media/restore-verification/<target>.env`, written atomically,
mode `0600`:

```
SCHEMA_VERSION, TARGET, RESULT, VERIFIED_TS, SNAPSHOT_ID, ARTIFACT, BYTES,
CHECKS, REASON
```

`domum-media report` reads it and reports `verified` only for `RESULT=success`,
carrying the target, snapshot id, checks performed and age. Otherwise it reports
`failed` or `unknown` — never an optimistic default.

Findings:

- no successful record → **warning**
- most recent record failed → **critical**
- last success older than 31 days → **warning**

## Scope, and what is still missing

This verifies that the **database dump** restores and is structurally valid. It
does **not** prove:

- that the dump imports cleanly into a running PostgreSQL instance;
- that the Immich photo library restores in full (only the dump is fetched, to
  keep the drill cheap enough to run often);
- that a complete host rebuild succeeds.

Those remain the job of the full drill in
[disaster-recovery.md](disaster-recovery.md). This is the cheap, frequent,
automatable check that catches the common failure — a repository that reads fine
but yields an artefact that is not usable.

Scheduling it is deliberately left to the operator for now: it costs restore
bandwidth against the cloud target and should be enabled knowingly.
