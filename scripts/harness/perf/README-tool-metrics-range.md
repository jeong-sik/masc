# Tool-metrics time-window reads

The optional-bound form `(? IS NULL OR ts >= ?)` makes SQLite scan the
timestamp index, including when a recent window is empty. Compare the
complete source readers with independently bound range predicates:

```sh
python3 scripts/harness/perf/tool_metrics_range_probe.py \
  --before-ref cc29cac733c27d6e31337ca0bf56f6dabbdc7e75 \
  --output-dir /tmp/metric-range-new
```

The output directory must be new. Existing OCaml, ocamlfind, SQLite, Yojson
and Mtime bytecode are required; no build or server is launched.
`--after-root` selects the candidate checkout. `--rows` selects fixture sizes
(defaults 30,000 and 300,000 records, not running agents).

The runner uses the baseline table schema and timestamp index. Timestamps
repeat ten times to include identity ordering within a timestamp. Each
reader's complete source module executes with its actual database, prepared
statement, bindings, mutex, result conversion and cleanup functions. The
fixture replaces only filesystem initialization for its already-existing
parent and the day constant used by the uncalled retention function.

Correctness comparisons convert rows to JSON outside timing. Timed reads
return typed rows and discard each result. Seven filter scenarios run in
five alternating rounds of 20 warm calls. Additional comparisons include
inclusive, inverted, infinite and SQLite-NULL bounds, and nonpositive limits.
The summary reports median/worst batch means, not individual percentiles.

Keep the runner, source snapshots, generated probe, source/library hashes,
checks, raw observations and summary together. These measurements include
the interpreter and SQLite reads from a local synthetic store; they exclude
server HTTP, Eio scheduling, concurrent writers, cold-cache I/O, production
retention distributions and 300 live Keepers. They do not certify the overall
0.1 ms goal. The schema, durability settings and database authority do not
change.
