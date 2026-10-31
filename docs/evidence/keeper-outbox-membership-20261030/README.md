# Keeper outbox membership: isolated comparison

The heartbeat intake checks whether an exact receipt remains in an immutable
outbox snapshot. The old lookup first made a list of every receipt ID and then
searched it. The new lookup applies the same filename-to-ID conversion while
searching and stops at the first match. The separate `receipt_ids` operation
still returns all IDs in snapshot order. [OCaml's list documentation](https://ocaml.org/manual/5.5/api/Stdlib.List.html)
describes the short-circuiting membership traversal.

The base is `ef307dea2bfb0e4c3e5334bd7f99d441cf923f2e` and the changed code is
`ff330a4b33ece857ecb2784426fa55009e3e5e08` (binary code diff SHA-256
`dbc2cccc89575fd0e6ae51ae0e9ec53caef6de5b6bcf0dd5a57b62315d2ebaa6`). The
exact extracted lookup sections have SHA-256
`9d20563c33cb453448ccdc2043d48ba650ecb9ee28033f16242084e003230977` and
`467aa76c9c97f3d21669d91f0159806228c0d853dadb312be94a3abd9b9b2b86`.
The 2026-10-30 comparison used OCaml 5.5.1 on a shared Darwin arm64 host,
macOS 26.6.1, compiling with `ocamlopt` and the standard Unix library. It did
not use Dune or build the whole application.

## Behavior and scope

The [lookup harness](lookup_bench.ml.txt) compiles those exact old and new
functions with a small synthetic snapshot/entry type. Ten thousand seeded
snapshots, including unusual filename bytes and path forms, produced the same
ID lists and membership decisions. Actual stored receipt paths are validated
by the outbox before they reach this lookup; the extra synthetic paths exercise
the pure conversion more broadly.

The project test now checks that all 22 retained host/vendor IDs are found and
that an unrelated ID is absent. That real-storage test was added but was not
run by this isolated probe. The probe reads no filesystem receipts and does
not execute the heartbeat intake, producer leases, acknowledgements, or an
actual Keeper turn. The loaded snapshot's existing freshness boundary is
unchanged. This change does not reduce the size of the model-facing outbox
context or establish a fix for context overflow.

## Timing and allocation

[Membership samples](lookup-samples.csv) and [full-list samples](ids-samples.csv)
contain seven same-process samples per role in alternating order. Membership
misses use a 64-character lowercase hexadecimal ID, the shape accepted by the
actual `Tool_result_ready` intake. The first [short-miss run](lookup-short-miss-samples.csv)
and its [source](lookup_bench-short-miss.ml.txt) are also retained: its
six-byte `absent` target did not represent that intake, so the table below
uses the separate 64-character run instead. That run compiled successfully
with an OCaml warning about the temporary source file's hyphenated name.
Each sample
began with `Gc.full_major`; allocation is the `Gc.allocated_bytes` difference,
CPU is `Sys.time`, and wall is `Unix.gettimeofday`. Timings include lookup and
harness overhead, with no explicit warmup. The table gives separate medians;
short measurements on a shared host are noisy and wall time is nonmonotonic.
All paths and IDs are synthetic. No file reads, locks or JSON decoding are
included.

| Snapshot and result | Repeated lookups | CPU ms, old → new | Wall ms, old → new | Allocated bytes, old → new |
| --- | ---: | ---: | ---: | ---: |
| 0 receipts, missing | 10,000 | 0.032 → 0.022 | 0.031 → 0.021 | 400,096 → 320,096 |
| 1 receipt, first | 10,000 | 1.979 → 1.983 | 1.986 → 2.004 | 3,760,096 → 3,440,096 |
| 16 receipts, first | 2,000 | 6.090 → 0.415 | 6.117 → 0.414 | 10,832,096 → 688,096 |
| 16 receipts, missing | 2,000 | 6.280 → 6.239 | 6.299 → 6.268 | 10,832,096 → 10,048,096 |
| 256 receipts, first | 200 | 9.714 → 0.040 | 9.740 → 0.039 | 17,211,296 → 68,896 |
| 256 receipts, last | 200 | 9.918 → 9.897 | 9.935 → 9.917 | 17,211,296 → 15,980,896 |
| 1,024 receipts, missing | 40 | 8.285 → 7.757 | 8.294 → 7.781 | 13,764,256 → 12,780,896 |

The one-receipt first-match case had a 0.20% CPU and 0.91% wall median
increase. The separate full-list workload for 1,024 receipts (40 iterations)
had CPU 7.841 → 7.953 ms and wall 7.839 → 7.986 ms, while allocation stayed
13,762,656 bytes. Those short samples do not establish a stable regression.
They do show why a first-position lookup result must not be generalized to
misses, full-list consumers or end-to-end Keeper time.

## Fresh reproduction

From a checkout containing both commits, with OCaml 5.5.1 installed, choose a
new output directory under ignored `artifacts/`:

```sh
python3 -B docs/evidence/keeper-outbox-membership-20261030/reproduce.py \
  artifacts/FRESH-outbox-membership \
  ef307dea2bfb0e4c3e5334bd7f99d441cf923f2e \
  ff330a4b33ece857ecb2784426fa55009e3e5e08
```

The script verifies the two source-section hashes, constructs synthetic
entries, and writes new comparison samples and the randomized-check result to
that directory. It refuses to overwrite an existing directory. Fresh timings
do not certify the original samples.
