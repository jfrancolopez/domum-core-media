# Rehearsals

Scripts that drive production code against **real production images** in
**disposable** compose projects. They are here for the same reason the operator
wrappers are: a script that lives in `/tmp` or in a transcript is reviewed by
nothing. Three rehearsals (Kavita, Jellyfin, and the first Plex run) existed
only as output pasted into `docs/`, so nobody could re-run them or review how
they established what they claimed.

**CI shellchecks these and deliberately does not run them.** They need the
production images, a Docker daemon, and several minutes; a runner has none of
those. `tests/ci-coverage-audit.sh` governs `tests/` and does not apply here —
these are not hermetic suites and must never be presented as if they were.

They are also covered by `tests/pipefail-grep-audit.py`, which is not a
formality: the first versions of both scripts contained
`docker logs … | grep -q <readiness line>`, and under `pipefail` that makes a
readiness line that IS present read as absent — the dangerous direction, and
intermittent.

## What a rehearsal must do

Every one of these was learned by getting it wrong once:

- **assert isolation BEFORE anything mutates** — the disposable project name is
  free, and the production container id is absent from the project's scope;
- **pin images by ID** read from the running container, never by a mutable tag;
- **pass `PUID`/`PGID` (or `user:`) as the invoking account.** The Jellyfin
  rehearsal ran as root and left 39 root-owned files the development account
  could not delete;
- **no production path, volume or network.** `network_mode: none` is the only
  honest guarantee that nothing leaves the host, and the logs prove it: the
  navidrome run shows `network is unreachable` reaching for its background
  images;
- **measure the readiness line from the image's own output.** The first version
  looked for "accepting requests"; navidrome logs
  `----> Navidrome server is ready!`, so a correct start was reported as a
  failure;
- **assert the teardown**, including that the fixture directory could be
  removed, and that the production container count and ids are unchanged.

## The scripts

| script | what it establishes |
|---|---|
| `plex-capture-restore.sh` | the `consistent` capture path against the real Plex image: three declared items, paths containing spaces, a sqlite binary whose own path has a space, `Preferences.xml` (the server token) at mode 600, and the **fail-closed** case — Plex creates `blobs.db` last, so a mid-startup capture correctly reports `INCOMPLETE` and names it |
| `navidrome-capture-restore-start.sh` | capture → restore → **the application starts against the restored capture**. A marker row proves navidrome opened *that* database rather than creating a fresh one, which a table count cannot show because a fresh navidrome also creates tables |

Both leave production untouched and assert it.

## What they do NOT establish

That a recovered service **serves its library**. navidrome starts, reports
ready, and opens the restored database; it has no music, no users and no client
has fetched anything. The tiers are kept apart deliberately, as they are for
Immich: `capture restores` < `application starts against it` < `application
serves it`.
