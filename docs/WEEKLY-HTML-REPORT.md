# The weekly report — terminal-style HTML and plain text

One command, two behaviours:

```
sudo domum-media report weekly --stdout     # plain text, sends nothing
sudo domum-media report weekly --html       # the HTML, sends nothing
sudo domum-media report weekly --dry-run    # text + what WOULD be sent
sudo domum-media report weekly --email      # actually sends it
```

**Preview never sends.** `--email` is the only form that mails, and it refuses
when `RECOVERY_PACK_EMAIL_ENABLED` is not `1`.

Bare `domum-media report`, `report --json` and `report --write` are unchanged.

## Where the design came from

Adapted from `domum-core`'s weekly report (`bin/domum-core`:
`report_render_weekly`, `report_render_weekly_html`, `report_sparkline`,
`report_append_history`, `report_cmd`), studied from a read-only clone.
`domum-core` was not modified.

The architecture is what was worth reusing:

> **The plain text is the source.** The HTML renderer re-derives nothing. It
> wraps the already-rendered text line by line, keyed on line *prefix* and
> coloured by the escalation *glyph* the text already carries.

So the two MIME parts cannot disagree about a number — the repository's "two
numbers that must agree are one number" rule, applied to presentation. The line
grammar is therefore load-bearing; changing it changes the HTML:

| line starts with | becomes |
|---|---|
| `╔` `║` | the boxed terminal header, green with a glow |
| `╚` | header close, or the dim footer once the verdict has been seen |
| `> ` | the boot line, with a blinking cursor |
| `Verdict: ` | the prominent bordered verdict box, coloured by its glyph |
| `── TITLE ───` | a section heading |
| anything else | body text, coloured by any `✗` / `▲` / `▴` it contains |

Palette, monospace stack and 600px column are `domum-core`'s:
`#141a15` paper, `#42e07d` green, `#cfe3cf` ink, `#e5b567` amber, `#ff7a6e` red,
`#2a352c` rules.

### Verified against the real reference, not by eye

The two renderers were fed **the same synthetic report** and their output
diffed. Normalising colours and text content, the structure is **identical** —
same tags, same nesting, same style shape. The only colour difference is one
deliberate divergence:

```
$ diff <(norm ref.html) <(norm mine.html)
  (no output — identical structure)

$ diff <(colours ref.html) <(colours mine.html)
< color:#5f7263      domum-core's dim
> color:#748978      lifted for contrast (see below)
```

Every palette value, the monospace stack, the 600px cap, the `color-scheme`
hints, the `keyframes dcb` cursor animation, the `text-shadow` glow, the
`letter-spacing:2px` section headings and the `role="presentation"` table
scaffold are all present in both.

**One deliberate divergence.** `domum-core`'s dim (`#5f7263`) measures
**3.43:1** against the `#141a15` background — below WCAG AA for body text — and
it is used for the 11px footer. Lifted within the same grey-green family to
`#748978` (**4.71:1**). Every text colour now clears 4.5:1, and a test
recomputes the ratios so a future palette edit cannot silently regress them.

### What was deliberately not copied

- **The POWER section.** It reads Raspberry Pi wattage through `vcgencmd`. There
  is no trustworthy power measurement on an N100, and inventing one is worse
  than omitting the section. A test requires `POWER` to be **absent**.
- **Its missing header sanitisation.** `send_email_body` there interpolates the
  subject into the message with no CR/LF guard — a header-injection hole by
  construction, not currently exploitable because its subject is a controlled
  verdict string. Here every header value goes through `mreport_header_safe`,
  which strips CR, LF and NUL.

## Sections, and which numbers are live

| section | source | live or recorded |
|---|---|---|
| IMMICH & DISASTER RECOVERY | `<target>-snapshot-coverage.json` | **recorded** — the counts are from the last reconciliation, and the snapshot they are about is cited |
| | `<target>-sample-verified.jsonl`, `-large-verified.jsonl` | **recorded**, cumulative |
| BACKUPS | `backup_last_success_epoch`, the recovery-pack state file | live file ages |
| SYSTEM | `uptime`, `/proc/loadavg`, `/proc/meminfo`, `df`, `uname` | **live** |
| TRENDS | `$DOMUM_STATE_ROOT/report/history.csv` | **recorded**, one row per day |
| DRIVE HEALTH | `smartctl -j`, `btrfs scrub status`, `btrfs device stats` | **live** |
| SERVICES | `service_health_state` per enabled service | **live** |
| UPDATES | staged candidate records | live file count |
| LOG ERRORS | `journalctl -p err --since -7d` | **live** |
| FINDINGS / SUGGESTED ACTIONS | the `checkup` arrays | **live** |

**A report does no recovery work.** It never calls restic, never queries the
Immich asset table, and never downloads a byte — the Immich counts come from
recorded evidence. A test asserts the renderer contains no `restic`, no
`immich_original_inventory` and no `docker exec … psql`.

### Measurements that are deliberately unavailable

- **CPU utilisation.** Load average is shown and *labelled* as load average.
  Instantaneous CPU needs two `/proc/stat` samples; reporting load average as
  "CPU %" is the kind of conflation this project treats as a defect.
- **Power draw.** No trustworthy source. Section omitted.
- **SSD wear on a drive with placeholder attributes.** Reported as
  `NOT INTERPRETABLE -- vendor attributes` rather than as a percentage. See
  `docs/SSD-HEALTH-STATUS.md`: the OS drive reports all 30 attributes at
  `value=100`, and a wear figure derived from that would be invented.
- **Trends before there is history.** With fewer than two recorded rows the
  section says it is still collecting and draws nothing. One current
  measurement is never spread across eight weeks.

## The two email behaviours

| | automatic (`health-notify`, weekly timer) | on demand (`report weekly --email`) |
|---|---|---|
| healthy | **no mail at all** | sends the full report |
| warnings only | **no mail** (verdict reads `WARNINGS (n)`) | sends the full report |
| action required | one mail, **alert mode** | sends the full report |
| critical | one mail, alert mode, critical first | sends the full report |

**Alert mode** is the same design, compacted: the finding and the suggested
actions first, then only IMMICH & DISASTER RECOVERY, BACKUPS and DRIVE HEALTH —
enough to act without logging in. It drops TRENDS, SYSTEM, SERVICES, UPDATES and
LOG ERRORS.

The silence gate is unchanged: mail leaves only on a **critical** or an
**action**. Adding HTML did not start weekly healthy mail.

The verdict is four-level and **shared** between the report and the notifier,
and the subject is derived from it. Without that, a `--force` send on a
warnings-only host carried the subject *"healthy"* over a body saying
*"WARNINGS"*.

## Trend history

`$DOMUM_STATE_ROOT/report/history.csv`, mode 0640, written by every report run:

```
date,disk_data_pct,mem_pct,containers_running,journal_errors,immich_originals,scrub_age_days,disk_temp_c
```

One row per **day**, last run wins, so trends stay genuinely week-by-week when
the report is run several times. The header is always rewritten rather than
copied, so a schema addition migrates old files automatically — existing column
positions never change. Bounded at 120 rows. Every value is cheap; no new
service, daemon or database.

## Mobile

The layout is one column capped at 600px with a `width=device-width` viewport,
percentage-width tables and no fixed width above the cap.

**Measured:** the longest line in a critical report is **84 characters** — a
suggested command — which is about 655px at 13px monospace, wider than the
column. It **wraps**: every body block carries `white-space:pre-wrap`, there is
no `nowrap`, no `<pre>`, and no element wider than 600px, so there is no
horizontal scroll. Wrapping was chosen over truncation deliberately: the
operator has to be able to copy the command. A test pins all four conditions.

## Troubleshooting

| symptom | cause |
|---|---|
| `Email is disabled` from `--email` | `RECOVERY_PACK_EMAIL_ENABLED` is not `1`. Use `--stdout` or `--html`. |
| trends say "still collecting" | fewer than two rows in `history.csv`. Expected until the second run. |
| `NOT CHECKED` in the Immich section | no coverage evidence yet. Run `domum-media-backup verify-snapshot-coverage cloud` — metadata only, downloads nothing. |
| `wear  NOT INTERPRETABLE` | that drive reports placeholder SMART attributes. Not a fault. |
| the HTML looks plain in Gmail | Gmail strips `<style>`, so the cursor stops blinking. Everything else is inline and unaffected. |
| a section is missing | it had nothing to report, or its input was unreadable — an unreadable input says `UNKNOWN`, never nothing. |

To inspect what would be sent, without sending:

```
sudo domum-media report weekly --html > /tmp/report.html   # then open it
sudo domum-media report weekly --dry-run                   # text + the subject
```

## Changing the presentation safely

The HTML follows the **line grammar** above, so most presentation changes are
changes to the plain text. Three constraints hold:

1. **Styles stay inline**, with no remote asset, script, font or tracking pixel.
   A test asserts there is no `src=`, `@import` or `url(`.
2. **Every dynamic value is escaped** by `mreport_html_escape` and lands in
   element *content*, never in an attribute. A mutation that drops the escape
   must make a hostile finding inject markup.
3. **A visual badge is never the only signal.** Severity is always also the
   words `HEALTHY`, `WARNINGS`, `ACTION REQUIRED` or `CRITICAL`, and the glyphs
   `●` `▴` `▲` `✗` survive into the plain-text part.

If the renderer outgrows roughly 150 lines of HTML emission, simplify the
**design**, not the data — the guard `domum-core` records, kept here.
