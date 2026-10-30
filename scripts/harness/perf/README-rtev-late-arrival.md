# Runtime-event late-arrival attribution

Compare the exact before/after `rtev_watch.ml` accumulator construction using
installed OCaml bytecode packages. No server, runtime-event producer, build or
MASC workload is started.

```sh
python3 scripts/harness/perf/rtev_late_arrival_probe.py \
  --before-ref 63960ad2c29fcafcd8b1785269c7d687d39e5194 \
  --after /path/to/candidate-checkout \
  --output /tmp/rtev-late-arrival-new
```

The output directory must be new. Existing `ocaml`, `ocamlfind`, `runtime_events`
and `mtime.clock.os` are required. `--repo` selects the Git repository; it defaults
to this checkout. `--rounds 0` performs correctness comparisons without timing.
`--dimensions` accepts a count-only JSON fixture in the companion file's shape.
`--prepare-only` writes the source-bound probe and metadata without executing
OCaml. With the default dimensions, baseline, candidate source and three rounds,
the prepared probe is byte-identical to the historical measured probe, SHA256
`43a865f41c6c47e64f98f483fd64e9260e3565ba8454d847480668508bf8aa94`.

The default large fixture uses per-domain **completed** `stw_handler` and
`stw_api_barrier` span counts from a retained partial diagnostic summary: 22,439
and 23,010 respectively across 30 domains. Completed handler counts size
synthetic begin lists. They do not identify the exact captured begin count:
unfinished spans can exist at the window boundary, and raw starts were not
retained. All timestamps are generated. This is not captured-event replay.

The probe extracts both source bodies and helper declarations directly. It
checks selected domains, counts, durations, maxima and sample order for edge
cases, seeded fixtures and the three measured sizes. Index construction,
array copying/sorting and accumulator updates remain inside timing; event
collection, other summaries, row sorting/percentiles and printing are excluded.
Three alternating rounds report median and worst whole-component timings,
process CPU and allocated bytes, rather than per-event or request percentiles.

Keep the runner, source snapshots, generated probe, count fixture, hashes,
checks, raw observations and summary together. The original measured packet
has its own frozen generator/hash; this portable runner did not retrospectively
generate those historical results. A diagnostic component speedup does not
prove a successful updated capture, application speedup, or the 0.1 ms target.
The original partial capture's failure remains independent and unchanged.
