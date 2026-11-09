# Runtime / wall capture measurements

Observation aid only. The mock was re-rendered at the same usable list width (118 or 78), rather than comparing it at terminal width (120 or 80). Tick positions below are relative to the list, with the observed frame inset removed.

HH:MM values can differ with the live clock. Mock ticks may begin at :30 when its oldest visible slot begins at :30; actual wall ticks follow the RFC HH:00 rule. This is recorded, not classified as a test failure.

| Capture | Usable list width | Actual pulse / mock | Actual tick count / mock | Actual tick columns / mock |
| --- | --- | --- | --- | --- |
| after-120x35-runtime-compact.txt | 118 | unmeasured / 12 | 0 / 0 | unmeasured / unmeasured |
| after-120x35-runtime-detailed.txt | 118 | unmeasured / 12 | 0 / 0 | unmeasured / unmeasured |
| after-120x35-24h-compact.txt | 118 | 48 / 48 | 4 / 4 | 38,50,62,74 / 37,49,61,73 |
| after-120x35-24h-detailed.txt | 118 | 48 / 48 | 4 / 4 | 38,50,62,74 / 37,49,61,73 |
| after-80x24-runtime-compact.txt | 78 | unmeasured / 8 | 0 / 0 | unmeasured / unmeasured |
| after-80x24-runtime-detailed.txt | 78 | unmeasured / 8 | 0 / 0 | unmeasured / unmeasured |
| after-80x24-24h-compact.txt | 78 | 45 / 45 | 4 / 4 | 23,35,47,59 / 23,35,47,59 |
| after-80x24-24h-detailed.txt | 78 | 45 / 45 | 4 / 4 | 23,35,47,59 / 23,35,47,59 |
