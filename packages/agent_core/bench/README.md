# Schema wire byte microbenchmark

`schema_wire_bytes_bench.exe` links the actual `Agent_core.Tool` SDK. Its pure,
rich authoritative schemas include nested properties, constraints, defaults,
enums, escaped text and UTF-8. It starts no provider or Keeper.

After freezing and independently reviewing the source, an authorized development
check can build and run only this executable:

```sh
git rev-parse HEAD
dune exec --profile release packages/agent_core/bench/schema_wire_bytes_bench.exe -- \
  --schemas 16 --repetitions 1000 --cold-batches 4
```

Save the exact source revision, toolchain, command, machine description and all
JSON lines together. These commands are an execution recipe, not an execution
receipt. The benchmark is an ordinary executable, outside `@runtest`.

The repository's targeted development runner can select the explicit
`schema_wire_bytes_bench` alias alongside focused suites. That opt-in alias
runs the defaults above and streams the JSON lines into the runner log. A
successful runner exit proves byte equivalence and execution, not a performance
threshold; ordinary regression runs do not select this benchmark.

The work counts are harness configuration, with no performance admission
threshold. Each output row reports its actual input count, repetitions,
operations, monotonic elapsed nanoseconds and allocated bytes. Checksums sum
returned byte lengths. The final integrity row requires per-schema byte
equivalence with `String.length (Yojson.Safe.to_string
(Tool.wire_json_of_schema schema))`, including the UTF-8 payload.

- Preparation rows include SDK schema construction and validation. Hot priming
  separately reports JSON creation, reference length preparation, and initial
  byte-count calculation. The latter two include their result arrays.
- Hot rows traverse the same retained physical schemas repeatedly, comparing
  `Tool.wire_bytes_of_schema` with direct serialization in the **same build**.
- Cold rows each traverse a fresh, physically distinct schema set once. Their
  preparation is separate, their field values match, and all keys stay alive.
  Verification runs after both cold measurements to avoid priming them.
- Elapsed time includes garbage collection and loop/checksum overhead.
  `Gc.allocated_bytes` reports allocation on this single domain, including
  measurement overhead; it does not measure retained or peak memory. No forced
  GC or cache reset occurs. Cold rows have fixed order and different cache
  populations, so they describe these runs rather than a controlled speedup.

The direct serialization reference is not an old-source baseline. This
microbenchmark does not establish whole-wake CPU causality, installed-runtime
behavior, 300-Keeper performance, or achievement of a 0.1ms goal.
