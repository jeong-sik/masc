# Footer pin-rule comparison

[Run 36244138896](https://github.com/jeong-sik/masc/actions/runs/36244138896)
passed 600 acknowledged transitions and six draft checks on one macOS ARM
runner. All 27 raw comparison files are retained unchanged, together with
independently recomputed aggregates. No sample was removed.

## Identities and workload

- Baseline: `f69b7b40a379f3b3ff7fd8060b041d0315b15851`, artifact `10906805085`
  from run `36241260409`; TUI SHA-256
  `c96d72f1a3ba9379c47f8dc777c67e12edb2141b4da28770f40f7471593e4383`.
- Candidate: `9adb139dd3aabcb67d7bdf35184f21915c401e41`, artifact `10906509317`
  from run `36243647589`; TUI SHA-256
  `815bdbfd53d13c64f8f4f1fe84da5a23155c91764da8d8365b57d9b964326854`.
- Both use observer harness `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`,
  helper SHA-256 `4841c61f45457db49dac8afb8a6714a8a9f109671a33e5e9b96b7cf8d4bd39d8`,
  and scenario SHA-256 `2b12d51f3fb64d0a32924804c601a2f9e489729962da303a6049cada1114af55`.
- Each session measures 60 roster transitions, checks a draft, loads 250
  synthetic alpha Channels bindings plus one beta binding, then measures 40
  Info transitions with the Channels snapshot retained.
- The order is baseline/candidate, candidate/baseline, baseline/candidate.
- The only `bin/` or `lib/` difference is `masc_tui_footer.ml`. The candidate
  also contains the standalone test environment correction, which does not
  change product sources or this external observer. Two independent source
  reviews checked the integration and unchanged instrumentation.

Root verification reconciled all receipts with stdout, all summary arrays and
aggregates, all PASS markers, empty stderr and identical preflight identities.
The local copies of all three binaries from each artifact were rehashed against
the manifest. Both manifests say `release_validated: false`.
Independent adversarial and response reviews also reconciled all 600
observations, raw copies and aggregates and found no discrepancy.

## Observations

Milliseconds; p95 is the nearest-rank percentile. Counts are per arm.

| Scope | Count | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|---:|
| All inputs | 300 | 0.356521 / 0.781584 / 10.245875 | 0.293833 / 0.613791 / 1.652792 |
| Roster | 180 | 0.331521 / 0.621292 / 1.349209 | 0.280208 / 0.637875 / 1.652792 |
| Info scrolling | 120 | 0.387917 / 4.503708 / 10.245875 | 0.325334 / 0.468750 / 0.690958 |

All-input medians by repetition are 0.358604/0.341646/0.352917 baseline and
0.288521/0.329770/0.282917 candidate. Candidate medians are lower in all three
sessions; the roster p95 and maximum are higher. This is an observed improvement
in this workload's median, not proof that every action or tail improved.

Whole-session child CPU medians are 0.130788s baseline and 0.125092s candidate.
These include startup, navigation, draft entry and shutdown and exclude observer
CPU. They are not per-input CPU measurements. This is the unprofiled comparator,
separate from the native profile's contaminated child CPU counter.
CPU in repetition 2 increased from 0.122299s to 0.125092s; the median reduction
does not describe every session.

Candidate internal Build maxima are 2.20/2.19/2.25ms and Present maxima are
0.40/0.40/0.47ms. Those include setup frames and are not directly correlated with
the timed inputs. They do not establish universal latency bounds.

The candidate minimum is 0.227209ms; every candidate input exceeds the 0.1ms
goal. These are input-to-completed-PTY-frame observations, not physical display
or deployed runtime performance. Do not pool them with previous runs on other
runner instances, including the earlier candidate median of 0.637042ms.

## Compiled source verification

[Integration run 36243648974](https://github.com/jeong-sik/masc/actions/runs/36243648974)
on candidate `9adb139dd3aabcb67d7bdf35184f21915c401e41` passed 124 key cases,
12 detail-footer cases, 57 status-footer cases and 7 active timing cases
(200 total). Its optional standalone step passed 170 suites, including the
same seven active timing cases, with zero failures, zero unbuilt and 1346
explicitly skipped suites. This verifies the initial environment-propagation
correction alongside the footer source; the later standalone CLI environment
error exit-status change is outside this integration head.

The main-based PR head has separate CI. None of these checks prove deployment
or broaden the synthetic interaction coverage of this comparison.
