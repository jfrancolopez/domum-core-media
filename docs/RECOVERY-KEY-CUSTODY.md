# Recovery-key custody: the single point of failure

**Read-only review, 2026-10-30. No credential was read, copied, printed or
changed, and no key operation was performed.** Everything below is derived from
the code paths and from evidence already recorded in this repository.

## The chain, as it actually is

To restore the family photographs from Hetzner after losing this host, four
things are needed in sequence:

| # | Needed | Where it lives | Survives loss of the host? |
|---|---|---|---|
| 1 | Hetzner Storage Box access (SFTP key / credentials) | `/etc/domum-core-media/secrets` | **no** |
| 2 | restic repository password | `/etc/domum-core-media/secrets` | **no** |
| 3 | the encrypted recovery pack, which contains copies of 1 and 2 | 37 copies: `$RECOVERY_PACK_DEST`, inside the cloud backup set, and emailed off-host | **yes** |
| 4 | the **age private key** that opens the pack | **operator custody only, off-host** | only if the operator still has it |

Step 3 is well covered. The off-host audit, run as root on 2026-10-12, found all
four repository credentials present, 37 encrypted packs with the newest 0 days
old, off-host delivery enabled by email, and the pack correctly **not** inside
the backup it would be needed to open.

## The single point of failure

**The age private key.** The pack is encrypted with `age -r <recipient>` against
`RECOVERY_PACK_AGE_PUBKEY_FILE` — only the *public* key is on this host. That is
the right design: a host compromise cannot decrypt the packs it produced, and
the host cannot read its own off-site escrow.

The consequence is the risk:

> Lose this host **and** the age private key, and all 37 packs are unopenable.
> The photographs remain in Hetzner, encrypted, with the repository password
> reachable only through a pack that cannot be decrypted.

This project already records that "the whole chain rests on that age key — 37
copies are equally useless without it". This document states what follows from
it: **key custody, not backup coverage, is the weakest link in off-site
recovery.** Every other link has redundancy; this one has whatever the operator
has.

## The one fact that changes the severity, and only the operator knows it

**Is the restic repository password recoverable independently of the pack?**

- If it is also in a password manager, written down, or memorised, then losing
  the age key costs the pack's convenience but **not** the photographs: steps 1
  and 2 can be reconstructed and the repository opened directly.
- If the pack is its only off-host copy, then the age private key is a single
  point of failure for **the entire off-site backup**, and a second copy is not
  optional.

This cannot be established from the host — by design, since the whole point is
that the host does not hold the means to open its own escrow. It is the first
question to answer, because it decides whether the checklist below is prudent
or urgent.

## Operator checklist — a second offline copy of the age private key

Justified in either case above; **urgent** in the second. None of this is
something an agent should do, and none of it is done here.

1. **Confirm the current copy is readable.** A key that cannot be read is
   already lost, and finding that out during a recovery is the worst possible
   time. `age-keygen -y <identity-file>` prints the *public* key from a private
   one — if it matches `RECOVERY_PACK_AGE_PUBKEY_FILE` on this host, the key in
   hand is the right key. This reads the private key locally and prints only
   public material.
2. **Decide what "offline" means for the second copy.** A second copy on the
   same laptop is not a second copy. Paper in a different building, or a
   hardware token, or a sealed envelope with someone trusted — the requirement
   is that one event cannot destroy both.
3. **Never put it where it would be needed to open itself.** The pack is
   deliberately not inside the backup it unlocks; the same reasoning forbids
   storing the key in Hetzner, in the pack, in `/srv/data`, or anywhere this
   host can write.
4. **Record the recipient's public key separately and durably.** It is not
   secret, and having it lets a future operator verify that a recovered private
   key is the right one before trusting a recovery.
5. **Prove the copy works, once, on a machine that is not this host.** Decrypt
   one pack with the second copy and confirm the archive opens. A copy that has
   never been used is a copy that might be a copy of nothing — this repository
   already holds that a backup is not proven until it has been restored, and a
   key is no different.
6. **Re-check after any key rotation.** Rotating the recipient re-encrypts only
   *future* packs. Older packs still need the old private key, so a rotation
   creates a second key to keep, not a replacement.

## What the host can and cannot tell you

| question | answerable here? |
|---|---|
| Is the public key present and the pack encrypted to it? | yes — `dr-offhost-audit` checks it |
| Are the packs being produced, and delivered off-host? | yes — 37 packs, newest 0 days old, email delivery enabled |
| Is the pack outside the backup it unlocks? | yes — checked, and correct |
| **Is the private key safe, readable and duplicated?** | **no — and it never will be** |

That last row is why the off-host audit reports `UNPROVEN` rather than clean,
and it is the correct verdict: two items in the chain cannot be established from
the host whose loss is being assumed. The other is that `pgvecto.rs` is
deprecated, so the set of Immich versions able to import today's dump shrinks
over time — a separate risk, recorded in `docs/DISASTER-RECOVERY-STATUS.md`.

## Not changed

No credential was read or printed. No key was created, copied, rotated or
transmitted. No configuration, schedule or exclusion was altered.
