# TUI fleet stream observation: isolated comparison

The reader now holds its last observed fleet state, followed revision,
connection-loss time and refusal in one immutable snapshot. The observation
is either absent, a reading, or an unavailable scan; it cannot contain both
a reading and an unavailable scan. The SSE decoder remains separately owned
and mutable. The existing single-reader ownership is unchanged; this is not
a cross-domain synchronization mechanism.

The base is `0be0b4cb714605d7e5f8ec67bfb1e8fa44bddf72`; the changed code is
`f2c53111667c3bb9bcb2b34b70c8efca75c366f1` (binary code diff SHA-256
`eeb100b0e59cc2886f0287e4046699c00a41f7d7b5c0c18865706a462c6cfc64`). The old
and new stream source SHA-256 values are respectively
`62475ac439e603c9b6157defa0e41d03f04e390e07d347dcde1735a76d4692fc` and
`5e564835d6ef831731850bffbf1a73fb0f9e8235093b5e20db253ad28c3e2f27`.
The 2026-10-30 run used OCaml 5.5.1, Yojson 3.0.0 and Alcotest 1.9.1 on a
shared Darwin arm64 host, macOS 26.6.1. It used `ocamlfind ocamlopt`, without
Dune or a project build. The [HTML event-stream specification](https://html.spec.whatwg.org/multipage/server-sent-events.html)
describes framing and reconnection; MASC's revision and snapshot rules are
its own contract and are compared here against its actual existing code.

## Behavior

Twenty-three existing lifecycle cases were selected from
`test/test_tui_fleet_stream.ml` and passed against each implementation. They
cover snapshots, unavailable scans, revision gaps, loss, refusal, schema
rejection, partial frames and reconnection. The selected run omits the two
screen/hub cases and does not execute an HTTP connection or the TUI.

The [seeded differential harness](equivalence.ml.txt) compared 200,000
lifecycle actions, including 139,823 fed chunks, against both production
stream implementations. It uses the real Fleet encoder/decoder and SSE wire
decoder, with only a small module wrapper to reproduce the `Masc` namespace.
It compares each `Keep_reading`/`Reconnect` decision and the resulting typed
observation, including malformed JSON and partial frames. All compared actions
matched. This is a finite synthetic comparison, not exhaustive proof or a live
screen observation.

## Timing and allocation

The [final raw samples](bench-final.csv) and [benchmark source](bench.ml.txt)
contain seven alternating-order samples per role in one process. Each sample
starts with `Gc.full_major`; allocation is the `Gc.allocated_bytes` difference,
CPU is `Sys.time`, and wall is `Unix.gettimeofday`. The synthetic workloads
include harness overhead and have no explicit warmup. The following values are
separate medians; small timing differences can be caused by scheduling, clock
granularity or the shared host.

| Workload | CPU ms, old → new | Wall ms, old → new | Allocated bytes, old → new |
| --- | ---: | ---: | ---: |
| 3,000 direct Changed events and observations | 0.040 → 0.032 | 0.039 → 0.032 | 457,016 → 577,064 |
| 3,000 SSE Changed frames and observations | 27.987 → 27.863 | 28.054 → 27.963 | 45,153,144 → 45,273,192 |
| 1,000 snapshot/loss/reconnect cycles | 9.871 → 9.800 | 9.879 → 9.804 | 17,688,528 → 17,808,496 |
| 100,000 repeated loss notifications | 0.157 → 0.190 | 0.155 → 0.190 | 1,600,936 → 1,600,984 |

The new snapshot adds about 40 bytes per Changed event in the direct workload:
allocation rose 26.27% there and 0.27% when the same events included SSE
decoding. Reconnection allocation rose 0.68%. Repeated loss had a 21.02% CPU
median increase in a sub-millisecond batch; the actual reader normally calls
loss on connection termination, so this synthetic batch does not quantify a
production regression. No runtime or frame-rate improvement is claimed.

An earlier [candidate](candidate-v1.ml.txt) and its [raw samples](bench-v1.csv)
are retained: its valid-event update allocated an extra temporary option.
For 3,000 direct events it allocated 601,064 bytes versus 577,064 in the
adopted version. These are separate runs; their timings are not used as an
apples-to-apples candidate comparison.

## Fresh reproduction

With the listed compiler and packages, from a checkout containing both commits,
choose a new output directory under ignored `artifacts/`:

```sh
python3 -B docs/evidence/tui-fleet-observation-20261030/reproduce.py \
  artifacts/FRESH-fleet-observation \
  0be0b4cb714605d7e5f8ec67bfb1e8fa44bddf72 \
  f2c53111667c3bb9bcb2b34b70c8efca75c366f1
```

The script verifies the recorded source bytes and that the supporting modules
are unchanged, extracts the 23 lifecycle cases, and writes fresh test,
differential and benchmark results into the new directory. It refuses to
overwrite an existing directory. Fresh timings do not certify the original
samples; no full regression, live HTTP stream or TUI execution is implied.
