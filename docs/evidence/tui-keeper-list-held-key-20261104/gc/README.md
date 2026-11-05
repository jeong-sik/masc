# Keepers Build spikes and the minor GC

2026-11-04, after the roster join fix. Question: are the 30 to 180 ms
keeper-list Builds GC pauses, and does the TUI's domain count cause them?

## How

- `gcwatch.ml.txt` (built outside the repo with `ocamlfind ocamlopt -package
  runtime_events,unix`) attaches to the TUI's runtime events ring
  (`OCAML_RUNTIME_EVENTS_START=1`, `OCAML_RUNTIME_EVENTS_DIR`) and records every
  runtime phase span per domain while the process lives.
- Same harness as the parent bundle: Keepers, 60 Down then 60 Up at 30 ms,
  55 x 200, live workspace. Host load average 170 to 210.
- `domain-count-ab.txt`: the branch's TUI (16 domains: UI, IO and a 14-worker
  pool from `Domain_pool.recommended_domain_count`) against the same source
  with `Domain_pool.create ~domain_count:2` (4 domains), alternated. The fifth
  run's trace failed with `Runtime_events: corrupt stream` and is missing.

## What the traces show

- A Build spike and a UI-domain minor collection line up when they happen
  together. In one run the two largest Builds were 35.8 and 109.4 ms, and
  `empty_minor` on domain 0 took 34.0 and 107.1 ms at the same moments (clock
  offset 1.7 ms). Four other 26 to 35 ms Builds had no GC under them. Two
  long collections, 71.6 and 30.1 ms, fell between frames.
- Inside one 149 ms collection: 37 ms waiting for every domain to arrive
  (`stw_api_barrier`), 42 ms of minor work, 70 ms waiting for every domain to
  finish (`minor_leave_barrier`). The 13 other domains each sat in
  `stw_handler` for the whole 149 ms.
- Collections of 30 ms or more, summed over the runs:

  | | count | total | waiting for other domains | minor work |
  |---|---|---|---|---|
  | 16 domains | 11 | 888 ms | 611 ms (69%) | 202 ms (23%) |
  | 4 domains | 12 | 1,407 ms | 439 ms (31%) | 699 ms (50%) |

  Fewer domains cut the waiting but not the total; the longest single
  collection with 4 domains was 243 ms, 140 ms of it promoting the remembered
  set. The domain count is not the lever, so the product keeps its pool.

## Reading

The median UI collection is 0.05 to 0.08 ms. The long ones happen while the
host runs at load 170 to 210 on 16 cores: a barrier waits for the last of its
threads to get a core, and promotion copies freshly loaded values into the
major heap. Neither is the roster code. Not measured: the same runs on an idle
host, and which loaded value the long promotions copied.
