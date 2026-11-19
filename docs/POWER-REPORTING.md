# Power reporting — Intel RAPL, and only what RAPL measures

## What this claims, and what it does not

`domum-media power status` and the weekly report's **POWER (CPU PACKAGE)**
section report the energy the **CPU package** drew: cores, uncore and the
memory controller.

They do **not** report what the server draws at the wall. Not measured, and not
estimated from this counter:

- the two SSDs;
- the fans;
- the NIC;
- the PSU's conversion loss.

The wall figure is **higher**, by an amount nothing on this host can determine.
Measure that with a meter at the socket. Nothing here is scaled, grossed up or
calibrated toward a whole-system number, because a scaling factor nobody
measured is an invented number printed beside measured ones.

The scope is in the section **heading**, not only in a footnote, because the
heading is what a skimming reader takes away.

## Why this exists when `domum-core`'s POWER section was refused

`docs/WEEKLY-HTML-REPORT.md` records that `domum-core`'s POWER section was
deliberately not copied: it reads Raspberry Pi wattage through `vcgencmd`, and
*"there is no trustworthy power measurement on an N100"*.

**The premise was wrong; the rule was right.** Measured 2026-11-19, this host
exposes Intel RAPL:

```
/sys/class/powercap/intel-rapl:0     name=package-0   energy_uj  (mode 0400)
/sys/class/powercap/intel-rapl:0:0   name=core
/sys/class/powercap/intel-rapl:0:1   name=uncore
```

So a real hardware counter exists and is read. The rule the refusal protected —
never invent a measurement, never state a narrow one in a broad one's words —
is unchanged, and `vcgencmd` is still never used. A test asserts it appears
nowhere.

## The counter has two discontinuities, and both are handled

`energy_uj` is a free-running counter. It does two things that a naive
difference gets wrong:

| | what happens | what the reader does |
|---|---|---|
| **wrap** | it rolls over at `max_energy_range_uj` | adds the range back — valid only for ONE wrap, see below |
| **reset** | it restarts near zero on reboot | the interval is **EXCLUDED** and counted, never estimated |

A decrease is ambiguous between the two, so **the boot id is recorded with
every sample** and is what tells them apart. Reading a reset as a wrap
fabricates very nearly a whole counter range — about **72.8 Wh** here — out of
an interval that drew almost nothing. That is a mutation in
`tests/power-reporting-smoke.sh`, and it must fabricate that energy for the
suite to pass.

### Why the timer is every 15 minutes and not daily

Measured, from this host's own `max_energy_range_uj` of 262,143 J:

| package power | the counter wraps every |
|---|---|
| 5 W | **14.6 h** |
| 10 W | 7.3 h |
| 25 W | 2.9 h |
| 65 W | 1.1 h |

**A daily sample is longer than the wrap period at every plausible power.** One
wrap and two are indistinguishable from the endpoints alone, so a daily series
would silently undercount — the shape of defect this project exists to avoid.

The reader enforces the same arithmetic rather than trusting the timer: an
interval longer than `max_energy_range_uj / POWER_MAX_PLAUSIBLE_WATTS`
(262,143 J / 65 W = **4,033 s**) is excluded and counted, because beyond it a
correction would be a guess. Sampling every 15 minutes sits comfortably inside
that bound even under sustained load.

### Exclusions name their own cause

Two causes, counted and reported **separately**:

```
Excluded               2 interval(s) spanned a reboot -- EXCLUDED
Excluded               1 interval(s) too long to rule out a second counter wrap
                       -- EXCLUDED rather than corrected on a guess
```

One counter would make the report assert a reboot for an interval that was
merely too long. The remedies differ — nothing to do, versus sample more often
— so a single wording would be a confident wrong cause.

When **every** interval is excluded the section says so and names which cause,
rather than falling back to "not enough samples", which would be true of a new
host and false here.

## Cost

Printed only when `POWER_TARIFF_PER_KWH` is set. There is **no default**: this
host cannot know what electricity costs where it is. With no tariff the report
states the energy and says why there is no cost, which is actionable; an
invented default would not be.

`POWER_CURRENCY` is a prefix only. No conversion is performed.

## Commands

```
domum-media power status            # the section, as the report renders it
domum-media power status --json     # same numbers; carries "scope":"cpu-package"
domum-media power sample            # record one sample (what the timer runs)
```

All three need root: `energy_uj` is mode `0400` and the sample history is
`0600` under the state root.

`--json` carries the scope as a **field**, so a consumer cannot read the
numbers as whole-system without ignoring a key that says otherwise.

## Enabling it

Nothing is sampled until the operator installs and enables the timer. It is
deliberately absent from `systemd/auto-enable.timers`: it deploys nothing,
deletes nothing and sends nothing, so the deployment argument does not apply to
it — but enabling a timer is an operator decision on this host, and a sampler
that started itself during convergence would begin writing state nobody asked
for.

```
OPERATOR ACTION REQUIRED
sudo install -m 0644 /opt/domum-core-media/systemd/domum-media-power-sample.service \
                     /opt/domum-core-media/systemd/domum-media-power-sample.timer \
                     /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now domum-media-power-sample.timer
```

The first figure appears after the **second** sample, i.e. within about 30
minutes. Before that the report says it does not have enough samples yet, which
is a different statement from `0 W` and is kept different.

## What it costs to run

A sysfs read and one appended line, 96 times a day. Samples are pruned to
`POWER_SAMPLE_RETENTION_DAYS` (90) and each is one short line, so the history
stays a few hundred kilobytes at most.
