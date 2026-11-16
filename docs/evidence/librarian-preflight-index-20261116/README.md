# Preflight ancestor indexes without repeated History restoration

Base: local `242a1cfe2d87112a195765a99aa01d002c487ca1`, the same tree as
PR #52516 remote head `ce49c16cd7ee413367b76a676e967d8c8182891c`.

A scope scan checks every history execution. Each execution walks its ancestor
chain. Published_reader already reuses the decoded outer JSON while freshly
read bytes remain identical, but each ancestor visit reconstructed the nested
History source and frozen prompt and recomputed its complete index again.
A chain therefore repeated that expensive work for each descendant.

The scan now owns a small index map for its current physical scope. Each entry
holds a weak identity of the verified outer JSON, its digest and the fully
confirmed typed index. A hit requires the fresh reader to return that same JSON,
the same actual record ID, digest and full owner (including epoch), and a freshly decoded equal
summary whose scope and host binding validate. Changed inputs fall through the
original restore/confirm path and preserve its error order. Failed index checks
are not saved. Scope transitions, including non-History scopes, discard the map.

Each walk still reads every body through Published_reader and checks current
fences, intents, child ACKs, digests and cycles. Known-basis publication checks
still obtain the complete request. The map retains no reconstructed source,
prompt or progress. Original/root execution captures are not seeded: root
restoration intentionally does not validate source-index digests until some
consumer needs those digests. This change grants no live-root or effect authority.

## Validation

The complete candidate Lineage and Store_preflight implementations and public
signatures type with OCaml 5.5.2 and fatal warnings 4/8/32/69 against existing
dependency interfaces. The existing Lineage CMI lacked the new API, so the
actual candidate implementation was checked by module ascription and supplied
to the full Store_preflight source; no executable substitute was linked.
[typing.json](typing.json) records the scope and source hashes.

The executable probe extracts the actual Published_reader, lineage walk/index
reuse and per_scope functions. Its History restore/index and fence/intent/progress
parsers are synthetic fixture ports. All 27 checks pass: unchanged chains,
missing/same-length-corrupt bodies, changed summary/host binding/full owner,
wrong-key reads followed by rebound metadata, fresh child ACK and intended digest,
current known-basis progress, weak-reference
retention and scope transitions. In its 32-node chain the fixture restoration
invocations are 528 without index reuse and 63 with it: 32 starting captures plus
31 distinct ancestors, instead of 32 captures plus 496 ancestor visits. Body,
fence and resolution read ports continue to run on the walks. These counts
exclude Exact checks, gate validation and other preflight work. They are not
measured production preflight invocations or installed CPU/RSS results.

Replay with the project's OCaml/findlib/Yojson toolchain:

```sh
python3 docs/evidence/librarian-preflight-index-20261116/probe.py \
  --source-root . --output artifacts/preflight-index-replay
```

The production fenced-resolution regression adds cached/uncached result
comparisons through actual Published_reader for missing/corrupt ancestor bodies
and changed root summary, then verifies recovery after restoring them. That
large fixture was parsed but not executed. No Dune build, link, full regression,
CI, install, restart or runtime data mutation was performed for this candidate.
