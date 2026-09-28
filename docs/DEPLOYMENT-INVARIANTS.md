# Deployment postconditions: unchanged, not empty

The `b762fe8` deployment installed every file correctly and then aborted:

```
== 8. confirm nothing moved ==
ABORT: a subvolume appeared under /srv/data: /srv/data/jellyfin
```

`/srv/data/jellyfin` is *supposed* to be a subvolume. The Jellyfin pilot made it
one, deliberately, three days earlier.

## What was wrong

The guard asserted an **absolute** state:

```bash
SUBVOLS="$(find /srv/data -maxdepth 1 -mindepth 1 -type d -inum 256)"
[ -z "$SUBVOLS" ] || abort "a subvolume appeared under /srv/data: $SUBVOLS"
[ "$(ls -1 /srv/snapshots | wc -l)" = "0" ] || abort "/srv/snapshots is no longer empty"
```

Both lines were true when written — no service had been migrated and the snapshot
root was empty. Both became permanently false the moment the first migration
succeeded. The second would have fired as soon as the first was fixed.

This is the same class as every other defect this project has found around the
migration: **an assumption that was harmless while nothing was a subvolume, and
wrong the moment one is.** It differs only in living in a hand-written operator
script that CI never sees.

## The correct invariant

A deployment installs files and moves a git ref. It cannot create, remove or
rename a subvolume or a snapshot. So the question is not *"is the topology
empty?"* but *"is the topology the same as before I started?"*

That comparison now lives in the repository, as one implementation the operator
script calls:

```
domum-media storage topology                  # capture
domum-media storage topology --verify <file>  # compare against the capture
```

```
0  unchanged
1  CHANGED -- each appearance and disappearance named
2  NOT COMPARABLE -- the two captures do not describe the same question
```

It detects a new subvolume, a vanished one, a renamed one, and a snapshot
appearing or disappearing — while accepting whatever was already intentionally
there. It keeps working after Kavita, Calibre-Web and the rest are migrated,
which the absolute form could not.

### Three outcomes, because "I cannot tell" is not "unchanged"

`2` is a distinct exit status and the reason the capture carries a header:

```
# topology-format 1 detector=btrfs-tool data-root=/srv/data snapshot-root=/srv/snapshots
```

`domum_is_subvolume` answers with the `btrfs` tool when it can (root) and with
inode + filesystem type when it cannot. Both are correct and they are not
guaranteed to agree in every corner, so a capture records which one produced it,
along with the roots it described and the format version. A capture taken
unprivileged and verified as root is refused rather than diffed — otherwise the
mechanism built to stop a false "the topology changed" could produce one itself.

A caller that only tests for success treats `2` as a failure, which is the safe
default.

### What it deliberately does not detect

- **Content changes** at an unchanged path. This is a topology guard. Content
  integrity is proven by the migration's own verification and by
  `.premigration == proof snapshot`.
- **Destroy-then-recreate with the same name**, which nets to an equal inventory.
  Comparing `st_dev` would catch it, and was considered and rejected: anonymous
  device numbers are assigned per mount, so a comparison across any remount would
  false-positive — and a false positive here is exactly the failure being fixed.
  Nothing in a file-install deployment can destroy a subvolume anyway.

### The upgrade boundary, and why one pinned copy is used for both captures

The obvious way to call this from a deployment is wrong: the pre-capture would run
the **old** installed binary and the post-capture the **new** one, so a change to
the subcommand's own output would look like a topology change — the same false
positive arriving from the other direction.

The deploy script therefore takes **both** captures with the *new* revision's
`bin/domum-media`, from the development checkout, whose SHA-256 the script already
pins and which is the very file it installs:

```bash
TOPO_TOOL="$SRC/bin/domum-media"
verify_sha "$TOPO_TOOL" "$SHA_DM"
DOMUM_DIR="$REPO" "$TOPO_TOOL" storage topology > "$CAPTURE"
...
DOMUM_DIR="$REPO" "$TOPO_TOOL" storage topology --verify "$CAPTURE"
```

Both captures provably run identical bytes, and the script carries no copy of the
invariant. `storage topology` is read-only, deliberately does not call
`need_root`, and `load_cfg` has no side effects, so running it before the install
changes nothing.

The format version in the header is the backstop: if a future revision changes the
inventory, a capture from an older format is reported as *not comparable* instead
of as a change.

## Regression coverage

`tests/storage-topology-smoke.sh` covers the full progression, because the
invariant has to survive it:

| case | expectation |
|---|---|
| zero migrated services | empty body, header present, verifies clean |
| **one expected migrated service** | two captures compare **equal** — the bug |
| several expected migrated services | clean, and order-independent |
| an unexpected subvolume appears | `rc=1`, `APPEARED` names it |
| an expected subvolume disappears | `rc=1`, `DISAPPEARED` names it |
| a snapshot appears, disappears or is renamed | `rc=1`, named |
| topology changes during a storage-neutral deployment | `rc=1`, end to end |
| capture missing, headerless, other detector, other root | `rc=2`, not `0` |
| contents change at an unchanged path | `rc=0` — not a topology change |

The test uses **real directories and the real `find`**; only
`domum_is_subvolume` is stubbed, because inode 256 cannot be arranged without root
and a btrfs filesystem and there is none writable on this host or in CI. That
predicate is pinned separately by `tests/subvolume-detection-smoke.sh`, and
`tests/integration/btrfs-migration-integration.sh` exercises the inventory against
a **real** migrated subvolume, a **real** proof snapshot, a real second subvolume
appearing, a real snapshot moved aside, and an ordinary sibling directory that must
not be listed.

Ordering matters on its own: `find` walks a directory in neither lexical nor
creation order (measured: `calibre-web jellyfin plex kavita immich` for a fixture
created as `immich kavita plex jellyfin calibre-web`). `--verify` sorts both sides
before diffing so it is immune, but a caller comparing captures as strings — which
is what the aborted script did — is not, so the listing is sorted and the test
asserts it.

Eleven mutants killed: header dropped, subvolume listing unsorted, snapshot
listing unsorted, subvolumes omitted, snapshots omitted, verify always clean,
`rc=2` downgraded to `rc=0`, header compared loosely, snapshot lines excluded from
the diff, an inline inode test in place of the shared helper, and `need_root` added
to `storage topology` (which would let a pre-capture silently differ from the
post-capture).

## The lesson worth keeping

The operator scripts are generated by hand and are **not** covered by CI. That is
how an invariant nobody reviewed came to gate a production deployment.

So the rule is now explicit: **one canonical implementation, tested in CI, invoked
by the operator script.** A hand-written script may capture facts (`docker ps`,
`systemctl is-enabled`, a SHA-256) and compare them, but it must not carry its own
copy of a project invariant. Where it needs one, the invariant gets a subcommand
and a test first.
