# Prepared snapshot blob digests

A snapshot hashes each serialized payload before its artifact-map lookup. On a
map miss the previous blob writer hashed those same bytes again. The new opaque
owner payload carries immutable bytes and the owner's digest into the strict
writer, removing that second hash. This evidence covers that owner boundary,
not an entire Keeper turn or an installed server.

## Source and method

`manifest.json` records exact source commits, ML/MLI hashes, compiler/platform,
the retained raw-file hashes, and the four focused regression results. The
baseline is the actual owner-hardened blob-store source at
`eb5b4703ab8ebae89a449fec061651e914e5f7ac`; the candidate owner API is
`c9263841595821da450957c3014d11f21dc95f6b`. Both enforce the effective-owner UID.

The actual ML/MLI are renamed `Tool_blob_store_before` and
`Tool_blob_store_after` only to coexist in one native executable. They were
compiled directly with OCaml 5.5.2 and linked to 70 existing dependency CMXs,
including the existing Fs strict publication implementation. There was no Dune
invocation or whole-repository rebuild. The harnesses here are the exact run
inputs. They include the former snapshot's bytes/SHA record construction and
artifact key/lookup shape; they do not compile the complete snapshot module.

Both sides prepare and hash their payload in every measured operation. JSON
encoding is common and excluded; input bytes are materialized beforehand.
Ordinary-address control performs its existing single hash. Artifact-map hit
control performs preparation and the map lookup without addressing, preview
creation or I/O. Address misses call the actual owner address functions. Strict
cold and strict memo cases call the actual durable APIs against temporary
fixture roots, removed after the run. The live `.masc` tree was untouched.

Five rounds alternate the order of baseline and candidate. `benchmark.ml`
records wall time and allocation; `benchmark-cpu.ml` uses fewer iterations and
also records process CPU time. The latter was already running when the
coordinator requested no further measurements on the loaded host; no additional
run followed. Each harness states its iteration counts. Strict memo cases
publish once before measurement. Cold cases each start in a fresh root.

To reproduce with matching cached dependencies, materialize both ML/MLI pairs
from the recorded commits with `git show`, compile each renamed pair using the
same `ocamlopt -no-alias-deps` include set, and link either harness after the
resulting CMXs and dependency closure. The package set used was
`eio_main,yojson,digestif.c,uuidm,mtime.clock,re,ptime,mcp_protocol.eio,alcotest`;
the Fs native stub archive was linked explicitly. Write all new files under a
new `artifacts/` directory. Existing compiled dependencies are required; these
instructions are not authorization for a local Dune/full build.

## Result

Allocation medians from `results.csv`, in bytes per operation:

| Case | Input bytes | Before | After | Saved |
| --- | ---: | ---: | ---: | ---: |
| Prepare + address miss | 4,096 | 2,432.2 | 1,880.2 | 552 |
| Prepare + address miss | 1,048,576 | 8,932.6 | 5,140.6 | 3,792 |
| Prepare + address miss | 3,200,000 | 23,188.6 | 12,268.6 | 10,920 |

Ordinary addressing and preparation plus an artifact-map hit have exactly the
same allocation before and after at all three sizes. Strict memo recall saves
the same digest allocation but still allocates the body read. Strict cold
publication also saves that digest work; filesystem/ledger allocation varies by
a few bytes between path/counter instances.

The already-collected CPU data supports removal of one hash pass: at 1 MiB,
prepare plus address uses a median 15,963→8,067 microseconds, while ordinary
address control uses 7,703→7,790 microseconds. Wall time is unsuitable for a
latency verdict: unchanged controls varied materially under concurrent host
load, and one 3.2 MB strict memo wall median worsened despite lower CPU work.

The supported conclusion is one fewer full-payload hash per snapshot map miss,
with no extra prepared record on ordinary writes/addressing or map hits. The
initial serialization and hash, map lookup, strict owned-file validation, exact
byte comparison, full reads and required durability remain. This does not show
an end-to-end runtime speedup.

## Regression and review limits

Four exact source test bodies and their helpers were extracted from the I1 test
file, with their module alias pointing at the actual compiled candidate. All
four passed: cross-root/exact binary payload reference preservation; prepared
repair and non-durable replacement; warm unsafe-parent rejection for both
strict APIs; and the existing root/shard symbolic-link writer matrix. The test
file SHA is `852193391cdeaa01435cff48c1db101960de749c4a6618519f6fce4bdcbe7f5b`.
This is focused actual-module execution, not the complete blob suite.

Both units passed independent source review. Direct actual-source typechecks
passed for changed production modules and the complete snapshot/projection
tests. Full blob and result-outbox tests encounter cached dependency-interface
mismatches; the outbox `Runtime_schema` mismatch also occurs on its unchanged
parent source. No full-suite, CI-completion, installed-runtime or deployment
claim is made.
