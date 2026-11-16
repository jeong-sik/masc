# Compute captured inventory fingerprints only when requested

`Workspace_memory_context.collect` used to serialize and hash every captured
Keeper snapshot, even when a caller read only `keepers` or produced HTTP JSON.
Collection now retains the snapshots and observation time. The existing
`fingerprint` getter computes the same canonical SHA-256 from those captured
values when explicitly called. There is no cache, lazy value or new option.

## Consumer and contract review

Baseline: `878ab909ada1cc485c609c313f1f9c61612c17bc`.
All tracked OCaml source references and their local aliases were inspected:

- `Server_workspace_memory_curator`, `Server_workspace_memory_addon` and
  `Workspace_memory_ledger_view` alias the module as `Context`. They use
  `collect`/`keepers`; no product caller reads its fingerprint.
- `Server_dashboard_http_keeper_memory_health` exposes `http_json` through a
  function alias. `Workspace_memory_ledger` consumes keeper rows and observation
  variants. These introduce no fingerprint consumer or re-exported module alias.
- Tests also alias it as `Context` and locally as `Inventory`. The baseline
  Keeper-health test calls `Inventory.fingerprint` at two sites, so the identity
  API remains. Its observation-time assertion is relabeled to describe inventory
  identity, and another assertion checks the old capture after disk replacement.

Ordinary/source-bound snapshots and their nested facts contain immutable fields
and lists. Their `to_json` functions read those values without I/O or clocks.
The getter therefore hashes the original captured values even after the files
change. The existing canonicalization, field selection, hashing and public type
signature are unchanged. Collection still reads every store independently and
retains the same missing/unavailable observations.

The historical [Curator CPU-boundary record](../2026-10-23-curator-cpu-boundary/README.md)
uses copied canonical/hash functions as a standalone scheduling demonstration.
It does not require collection to hash eagerly. That evidence and the Curator
request-preparation offload are unchanged.

## Verification layers

`actual-typing.json` records successful direct typing of the complete changed
Context interface and implementation against existing real dependency CMIs,
using OCaml 5.5.2 and fatal warnings 4/8/32/69. The recorded command-prefix digest
identifies the existing local typing setup; only its first include directory was
replaced with isolated output. No dependency rebuild or complete link was run.

The native probe separately compiles the complete baseline/candidate Context
modules and interfaces plus the real Agent Core SHA implementation. Snapshot and
configuration readers are explicit fixtures; actual Unix stat/readdir and
temporary files exercise Context's discovery/read/error branches. The clock is
fixed for exact `http_json` byte comparison. This does not execute the real Keeper
snapshot codecs or its storage/ownership authority.

Eight cases passed 54 assertions: missing/non-directory/empty inventories,
canonical owner aliases and duplicates, missing snapshots, replacement snapshots,
malformed/unavailable/vanished/exceptional reads, nonregular snapshots, blank
owner refusal and larger captures. Read traces, keeper order, errors, captured
values and HTTP JSON bytes match. Fingerprints match the baseline, exclude
observation time and keep the old capture's identity without rereading changed
files. The modified real Keeper-health test passed syntax parsing only.

## Synthetic cost observation

Three calls per row, including eight synthetic 1 MiB snapshots plus the smaller
error/alias fixtures. Snapshot serialization counts are fixture instrumentation.
Allocation uses `Gc.allocated_bytes`.

| Operation | Before allocated bytes | After allocated bytes | Before CPU s | After CPU s | Before/after snapshot serializations |
| --- | ---: | ---: | ---: | ---: | ---: |
| collect | 220,537,728 | 100,807,248 | 0.340576 | 0.187320 | 30 / 0 |
| http_json | 220,554,072 | 100,823,592 | 0.317103 | 0.169282 | 60 / 30 |
| collect + explicit fingerprint | 220,537,776 | 220,537,752 | 0.326589 | 0.329883 | 30 / 30 |

An explicit fingerprint still pays the hashing cost. Repeated explicit calls
recompute it. These one-process fixture timings do not establish production
latency, CPU utilization, RSS, installation or HTTP transport behavior.

## Reproduce the native fixture probe

Use OCaml 5.5.2 with Yojson, Digestif and Unix. Source identities and the helper's
own SHA-256 are in `result.json`. New output belongs under `artifacts/`:

```sh
python3 docs/evidence/workspace-context-fingerprint-20261116/probe.py \
  --repo . \
  --base 878ab909ada1cc485c609c313f1f9c61612c17bc \
  --out artifacts/workspace-context-fingerprint-20261116/reproduction
```

The original fixture output is in
`artifacts/workspace-context-fingerprint-20261116/run-1`; actual-CMI typing output
is in its sibling `actual-typing`. No Dune, full CI or runtime operation was run.
