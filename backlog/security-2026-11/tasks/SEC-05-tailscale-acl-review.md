# domum-core-media/SEC-05 Tailscale ACL review

| Field | Value |
| --- | --- |
| Status | BLOCKED — owner action in the Tailscale admin console |
| Priority and reason | P1 — decides whether a family phone can open a shell here |
| Effort and change risk | 15 min; low |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | owner; finding F-06 |
| Dependencies | none |

## Outcome

Tailscale SSH is enabled on this host and the tailnet includes family phones and
a tablet. With the default allow-all policy every device can reach every port,
and the default SSH rule lets any of the owner's devices open a shell. After
this task family devices reach the web apps only.

## Scope and setup

Tailscale admin console → Access controls. Nothing on this host or in Git changes.

## Before editing

Read the current policy. If it is the default single `accept` rule for `*:*`, every step applies.

## Implementation and checkpoints

1. Tag or group devices: one group for the owner's own machines, one for family devices.
   - **Check** each device in the Machines list shows its owner or tag
2. Replace allow-all with: owner devices → this host on any port; family devices → this host on TCP 443 and 80 only.
   - **Check** the console's policy preview for a family phone
   - **Expected** 443 allowed, 22 denied
3. Restrict the `ssh` section to owner devices, with `check` mode so a session needs a recent re-authentication.
   - **Check** `tailscale ssh <this host>` from an owner machine
   - **Expected** works, with a browser re-auth the first time
4. Confirm key expiry is on for phones and laptops. Servers may have it off; note which.
5. Negative test from a family phone on mobile data: open a photo in Immich, then try any SSH client against the host's tailnet name.
   - **Expected** Immich loads; SSH times out or is refused

## Acceptance

- Step 5 passes in both directions.
- Optional: Tailnet Lock, so a new device cannot join without a signature from one you already trust.

## Rollback and stop conditions

The console keeps policy history; revert to the previous version. Stop if an owner device loses access.

## Verification handoff

- **Result** _not started_
- **References** none in Git
- **Evidence** _policy before; steps 2, 3, 5_
- **Next model** none; this is not machine-checkable from the host
- **Open items** —
