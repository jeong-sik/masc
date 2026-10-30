# Keeper extra-context receipt: isolated comparison

The hook used to retain the latest immutable context assembly and separately
store a digest and size computed from the same extra-context string. The
assembly's own receipt already contains those values, so the change removes
the duplicate mutable fields and the second whole-carrier hash. This is an
issuer-side receipt; it does not prove what a provider or official client sent
or received.

The compared source starts at `e9a91c46e360340f4a5f1aeb31c4f8def084f337` and
the changed code is `880296c2523bbd60b33427e976caa26e2669ff0b` (binary code
diff SHA-256 `a9e0bcffcd4186c63b57530e35fe521e110fd910faa2fbee76b4b6007e26034c`).
The actual context assembly source used for the experiment has SHA-256
`3999e935958d599e93ea928ecd8ccb426200528de4a4188cbf49ff1f75e80198`; the
changed accumulator has SHA-256
`39f5329360cf1036781178b7af991bb3a0f1924d4481b1f81216bd30f6672529`.
The run used OCaml 5.5.1, Digestif 1.3.0 C implementation, Yojson 3.0.0 and
Alcotest 1.9.1 on a shared Darwin arm64 host, macOS 26.6.1. The initial
standalone link using the unselected `digestif` package failed; the reported
run linked `digestif.c` successfully and emitted a duplicate-interface
findlib warning. [Digestif](https://github.com/mirage/digestif) documents its
separate C and OCaml implementations.

## Behavior and scope

The added test follows absent assembly, an assembly with no extra carrier, an
empty carrier, a carrier containing NUL, invalid bytes and Korean text, and a
subsequent absent carrier. It checks the exact bytes, length and SHA-256 and
keeps a separate System observation present. The isolated run compiled the
actual accumulator and interface, context assembly and interface, context
layers, and Agent Core SHA-256 wrapper. It stubbed the unrelated metadata,
tool, hook response and prompt-block-ID dependencies. The test body was
extracted from the project test, changing its `Masc.Keeper_` qualification to
the unwrapped module names and supplying a fixture stub. It passed.

This does **not** execute the production `before_turn_params` hook, manifest
serialization, final execution receipt, a Keeper turn, or the full project
build. Those integration boundaries remain unverified by this isolated test.
The two removed fields were exposed in the public OCaml `hook_accumulator`
record. External consumers that read or construct those fields must update;
their existence is unknown. No thread-safety claim is made for the remaining
accumulator.

## Synthetic timing and allocation

The [benchmark](receipt_bench.ml.txt) compiles the real context assembly,
context layers and SHA-256 code with a prompt-block-ID stub. It compares the
old extra hash and length calculation to reading the assembly receipt, after
constructing the same assembly. These projections are manually expressed in
the harness; they are not a complete production hook. The input is synthetic
ASCII repeated to the sizes shown and no private prompt is recorded.

The [original raw samples](receipt-bench.csv) comprise seven same-process
samples per role in alternating order. Each sample starts with `Gc.full_major`;
allocation is the `Gc.allocated_bytes` difference, CPU is `Sys.time`, and wall
is `Unix.gettimeofday`. Measurements include assembly, the selected projection
and harness overhead. There was no explicit warmup. The table gives separate
medians; host scheduling and the nonmonotonic wall clock can affect them.

| Extra carrier | Iterations | CPU ms, old → new | Wall ms, old → new | Allocated bytes, old → new |
| --- | ---: | ---: | ---: | ---: |
| absent | 50,000 | 0.787 → 0.797 | 0.786 → 0.796 | 22,400,096 → 22,400,096 |
| empty | 50,000 | 49.601 → 34.687 | 49.714 → 34.827 | 84,000,096 → 67,200,096 |
| 4 KiB | 2,000 | 74.645 → 51.093 | 74.709 → 51.118 | 21,120,096 → 20,016,096 |
| 64 KiB | 150 | 87.165 → 59.016 | 87.206 → 59.245 | 20,016,096 → 19,933,296 |
| 1 MiB | 12 | 105.247 → 70.272 | 105.521 → 70.420 | 25,310,976 → 25,265,472 |

The absent-carrier case had a 1.27% median CPU and wall increase at sub-ms
scale and no allocation change. For 1 MiB, median CPU decreased 33.23% in
this isolated workload; this cannot be turned into a whole-turn or production
latency claim. The accessor's `Option.bind` preserves the absent value without
wrapping it; see [OCaml's option documentation](https://ocaml.org/docs/options).

## Fresh reproduction

From a checkout containing the code commit, with the listed compiler and
packages, choose a new directory under ignored `artifacts/`:

```sh
python3 -B docs/evidence/keeper-context-receipt-20261030/reproduce.py \
  artifacts/FRESH-keeper-receipt 880296c2523bbd60b33427e976caa26e2669ff0b
```

The script verifies the two recorded source SHA-256 values, constructs the
explicit stubs in the new directory, compiles the focused test and benchmark,
and writes fresh results there. It refuses to overwrite an existing directory.
Fresh timings cannot certify the original captured values.
