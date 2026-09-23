# Task 41 — Align IMAGE_AUTO_UPDATE_ENABLED with the image-refresh freeze

## Objective
Set `IMAGE_AUTO_UPDATE_ENABLED=0` in the live production config so it agrees
with the deliberate image-refresh freeze.

## Evidence
`domum-media report` on 2026-09-23 reported:

```
Image refresh: policy=true; timer=disabled/inactive
[WARNING] IMAGE_AUTO_UPDATE_ENABLED is set in the config while the
          image-refresh timer is disabled
```

The freeze is enforced by the **timer**, which is disabled and deliberately
absent from `systemd/auto-enable.timers`. The policy flag does not currently
enable anything on its own, so this is not an active risk.

## Reason
Defense in depth, and truthfulness. Someone reading only the config would
conclude automatic image deployment is live. The config should not disagree
with the intent it is supposed to express. `config/domum-media.conf.example`
already ships `0`; only the live config still says `1`.

## Implementation plan
Operator step only — the live config is not in git:

```bash
sudo sed -i 's/^IMAGE_AUTO_UPDATE_ENABLED=1$/IMAGE_AUTO_UPDATE_ENABLED=0/' \
  /opt/domum-core-media/config/domum-media.conf
```

Then confirm with `sudo domum-media report` that the finding is gone and that
the image-refresh timer is still `disabled`/`inactive`.

## Testing plan
The report already asserts this relationship; the finding disappearing is the
test. `tests/operational-report-smoke.sh` covers the severity rules.

## Rollback plan
Set the value back to `1`. It changes no behaviour while the timer is disabled.

## Risk / complexity / token size
None (a single config value, no code). Trivial.

## Suggested order
Whenever convenient. Deliberately NOT bundled with a restore drill or any
deployment — a config edit and a Restic operation should not share a window.
