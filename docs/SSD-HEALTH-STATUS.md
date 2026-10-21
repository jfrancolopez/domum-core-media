# SSD health — measured 2026-10-21

Both drives pass their SMART self-assessment. **Neither shows an actionable wear
or error indicator.** The interesting result is not the verdict; it is the
asymmetry between the two drives, and what that means for how much the verdict
is worth.

Nothing was installed and nothing in production was changed. `smartmontools`
7.4-3 was already present.

## 1. `/dev/sda` — Samsung SSD 870 EVO 1TB — holds `/srv/data`

Firmware `SVT03B6Q`, 1000.2 GB, 3568 power-on hours (148.7 days), 74 power
cycles, 37 °C.

**Every error counter is zero:**

| attribute | raw | meaning |
|---|---|---|
| 5 Reallocated_Sector_Ct | 0 | no sectors retired |
| 179 Used_Rsvd_Blk_Cnt_Tot | 0 | no reserve blocks consumed |
| 181 Program_Fail_Cnt_Total | 0 | no write failures |
| 182 Erase_Fail_Count_Total | 0 | no erase failures |
| 183 Runtime_Bad_Block | 0 | no blocks failed in service |
| 187 Uncorrectable_Error_Cnt | 0 | nothing the ECC could not fix |
| 195 ECC_Error_Rate | 0 | — |
| 199 CRC_Error_Count | 0 | no SATA link/cable errors |

No attribute has ever tripped its threshold (`WHEN_FAILED` is `-` throughout).

**Endurance is a non-issue.** `241 Total_LBAs_Written` = 6,071,952,788 × 512 B =
**3.11 TB** written. The 870 EVO 1TB is rated **600 TBW**:

```
  0.52% of rated endurance used in 148.7 days
  20.9 GB/day average write rate
  ~79 years to 600 TBW at that rate
```

`177 Wear_Leveling_Count` agrees independently: normalized **99/100**, i.e. ~1%
of endurance consumed, average erase count 4. Two different measures giving the
same order of magnitude is the useful part — a single one could be a
misread unit.

**Two things worth noting, neither actionable:**

- **Historical maximum temperature 62 °C.** Current is 37 °C.
  `190 Airflow_Temperature_Cel` reports normalized = 100 − °C on this drive, and
  its `worst` is 38 → a peak of 62 °C at some point. The 870 EVO's operating
  range is 0–70 °C, so that was in spec but closer to the top than the current
  reading suggests. Nothing to do; worth re-reading if the host is ever enclosed
  differently or the ambient rises.
- **`235 POR_Recovery_Count` = 8** unexpected power-loss recoveries, against 74
  power cycles — about 11% of starts were unclean. Btrfs handled all of them
  (error counters are zero and the scrub was clean), and the DUP metadata
  profile is what makes that survivable. It is a count of past events, not a
  prediction.

## 2. `/dev/sdb` — KOWIN KAE2000A512HI47 — holds `/` (the OS)

Firmware `W0406A0`, 512.1 GB, 3054 power-on hours, 31 power cycles, 47 °C.

Passes its self-assessment, and **its attribute table is largely
uninterpretable:**

- **All 30 attributes report `value=100`, `threshold=50`.** One distinct
  value/threshold pair across the entire table. A drive whose every attribute
  reads exactly 100 after 127 days of service is reporting placeholders, not
  measurements.
- **10 of 30 attributes are `Unknown_Attribute`** — vendor-specific IDs
  smartmontools has no drive-database entry for, so their raw values cannot be
  interpreted at all.
- **`177 Wear_Leveling_Count` raw = 0** on a drive that has been in use for
  3054 hours. That is a placeholder, not good news.
- **`241 Total_LBAs_Written` raw = 10,991** — the unit is not determinable for
  this controller. Read as literal 512 B LBAs it would be 5.6 MB, which is
  impossible; read as GiB it is ~11.8 TB, which is plausible for an OS disk
  running Docker. **The honest statement is that its write volume is unknown**,
  and with no published TBW rating for this model there is nothing to compare it
  against anyway.
- The named error counters do read zero — `5 Reallocated_Sector_Ct`,
  `197 Current_Pending_Sector`, `198 Offline_Uncorrectable`,
  `199 UDMA_CRC_Error_Count`. Given everything else is a placeholder, it cannot
  be established whether those are measured or also placeholders.

**47 °C is the warmest thing on the host**, 10 °C above the data drive. Within
spec for a consumer SSD (typically rated to 70 °C), and not actionable.

## 3. The conclusion: the asymmetry is the right way round

| | holds | SMART quality | if it fails |
|---|---|---|---|
| sda | the irreplaceable photo library | **fully interpretable, excellent** | the snapshots and `.premigration` copies go with it; Immich is recoverable from Hetzner, the five media services are not |
| sdb | the OS | **largely placeholders** | reinstall the OS, restore config and secrets from the recovery pack |

**The drive whose health can actually be measured is the one holding data that
cannot be replaced.** The drive whose health cannot be measured holds only
rebuildable state. That is the correct arrangement, and it is why there is no
action here.

It also sets the honest expectation for `sdb`: **it will report "passed" until it
does not.** With placeholder attributes there is no gradual signal to watch, so
its failure mode is "working, then not". The mitigation is not monitoring — it is
that losing it costs an OS reinstall and nothing else, which is already true.

## 4. Why attribute thresholds were NOT added to `checkup`

`checkup_disk_health` reads the self-assessment verdict only. Extending it to
read attributes was considered and deliberately not done:

- For **sda** every meaningful counter is zero, so no threshold would fire
  today. It would be real coverage for the future, but it is new code added
  during a stabilization period to watch a drive with 0.52% wear.
- For **sdb** a threshold check would be **actively misleading**. Comparing
  `value` against `threshold` when every attribute reports 100/50 would produce
  a confident "healthy, 0% wear" from a drive that measures nothing — which is
  precisely the HEALTHY-means-UNMEASURED defect this project exists to prevent.
  Any attribute check would first need to *detect* a placeholder table and
  report UNKNOWN, and that is the larger half of the work.

**Recommendation:** leave it. Revisit if sda's wear-leveling normalized value
ever drops below ~90, or if any error counter on sda becomes non-zero — both of
which the operator would see in a `smartctl -a` run, and neither of which is
close.

What *was* fixed in `checkup_disk_health` is a defect that could fire today: see
§5.

## 5. The check itself had two defects

Both found while verifying this measurement, both now fixed and tested against
the real captures above.

- **An unreadable device was reported as a FAILED one.** The check grepped
  `smartctl -H` output for `PASSED|OK` and sent anything else to
  **CRITICAL "did NOT pass"** — so a permission or access failure told the
  operator to replace a healthy disk. Measured: under permission denied
  `smartctl -j -H` returns well-formed JSON with `exit_status: 2` and **no**
  `smart_status` at all. "I could not check it" is not "it is broken". It is now
  UNKNOWN with a remedy.
- **`grep -qiE 'PASSED|OK'` matched `ok` as a case-insensitive substring**
  anywhere in the output, so unrelated prose could read as a pass. The verdict is
  now read from `--json`, which is also the form these captures are in — a text
  pattern could not have been verified without root and would have failed closed
  into warnings if smartctl's wording differed.

And one defect introduced while fixing those, caught by the test:

- **`jq`'s `//` operator is FALSE-coalescing, not null-coalescing.**
  `.smart_status.passed // empty` returns *nothing* when `passed` is `false`, so
  a drive that genuinely **failed** its self-assessment became indistinguishable
  from one that could not be read — reported as UNKNOWN instead of CRITICAL, the
  dangerous direction. Measured:

  ```
  {"smart_status":{"passed":false}} | .smart_status.passed // empty  -> (nothing)
  {"smart_status":{"passed":true}}  | .smart_status.passed // empty  -> true
  {}                                | .smart_status.passed // empty  -> (nothing)
  ```

  `| tostring` keeps all three distinct: `false` / `true` / `null`. Only a
  boolean is at risk — jq's falsy set is exactly `null` and `false`, so the
  codebase's other `// empty` reads (counts, ids, strings) are unaffected;
  verified, `{"n":0} | .n // empty` yields `0`.
