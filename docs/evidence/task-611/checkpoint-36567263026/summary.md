# Checkpoint inventory comparison

Synthetic fixture: 128 valid v11 histories and 8192 nonmatching entries; identical bytes.
HTTP times include scan, checkpoint decoding, response encoding and transport.
Concurrent client starts do not prove overlap with directory sorting. Scheduler windows overlap; their percentiles are not pooled. Runtime-events domain 0 is the main domain.
This experiment does not close task-611 or #25893.

| Pair | Build | Inventory p50/p95/max ms | Health p50/p95/max ms | Scheduler p99/max ms |
|---|---|---|---|---|
| 1 | baseline | 26.755/29.432/31.766 | 1.359/1.649/3.561 | 0.21371099999999144/2.1300989999999964 |
| 1 | candidate | 27.062/30.227/31.478 | 1.387/1.625/4.649 | 0.23523300000000136/0.5604550000000014 |
| 2 | candidate | 27.024/30.015/31.815 | 1.400/1.625/4.170 | 0.21896899999999941/0.2794669999999916 |
| 2 | baseline | 26.034/28.399/29.702 | 1.421/1.591/2.594 | 0.2042329999999981/0.260721999999991 |
| 3 | baseline | 26.321/29.758/33.254 | 1.344/1.585/4.047 | 0.19010899999999387/0.28403499999998805 |
| 3 | candidate | 26.310/29.883/30.862 | 1.353/1.599/4.687 | 0.18296199999999485/0.49998099999999657 |

## Main-domain uninterrupted execution distribution

Columns: domain, runs, run_ms, busy%, >=10ms, >=50ms, >=100ms, max_ms.

```text
pair 1 baseline: 0           71197      428.7     0.5%        0        0        0       2.8
pair 1 candidate: 0           71196      432.1     0.5%        0        0        0       3.7
pair 2 candidate: 0           71190      440.0     0.5%        0        0        0       3.5
pair 2 baseline: 0           71181      406.9     0.5%        0        0        0       2.4
pair 3 baseline: 0           71202      425.1     0.5%        0        0        0       3.1
pair 3 candidate: 0           71200      415.0     0.5%        0        0        0       3.9
```

Full per-domain GC/STW distributions and trace-loss counts are in each rtev_watch.txt.
Raw responses, commands, hashes, host loads and cleanup receipts accompany each session.
