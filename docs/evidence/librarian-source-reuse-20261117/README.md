# Source reuse within one history-inventory load

`Owner.load_many` reads selected originals in order. It uses each discovered
source digest only to find a previously successful request as a reuse hint.
The lower Request implementation requires equal captured owners and complete
source-text bytes before sharing the immutable source. Every body, hash, current
record/progress, request preparation, binding, stored index and physical source
root is read or validated afresh. The first failure stops later reads. The hint
map is private to this call and is discarded before return.

Baseline: `a5eae5da05442ea52f67e3fd44705293b7392e7c` plus the lower
[Request source-reuse change](../durable-source-reuse-20261117/README.md).
The production consumer filter retains its original selected subsequence and
order. The three changed production file hashes, exact copied function-body
hashes and proof limits are in [provenance.json](provenance.json).
The current measurement driver is bound by
[replay-provenance.json](replay-provenance.json); original source and observation
records remain unchanged.

## Observed native experiment

The unchanged baseline `load` body and the entire new
`load_with_restore`/`load`/`load_many` bodies are copied verbatim into
`batch_before.ml` and `batch_after.ml`. Their prefixes provide namespace aliases
and count calls while delegating to the actual `Systhread_host.run`. The fixture
uses the real generic Owner and Store with an owned temporary filesystem;
there is no fake Store, request decoder, source-root check or hash validator.

[observations.json](observations.json) records 32 successful `check` calls in
one native execution. They cover empty/mixed/unique/reversed/duplicate input,
equal-source physical sharing, no sharing across calls, a weak-reference check
that the private hint map releases its source, and exact baseline values/errors
and I/O-wrapper invocation counts. They also cover a forged equal metadata
source digest with different source text, progress advanced after discovery,
and a corrupted or missing second body after a reuse hit. In those failure
cases both paths stop before the third body.

The original claimed 296-byte overhead, and a subsequent 416-byte replay
observation, are withdrawn as allocation evidence. Both used GC-boundary
sampled `Gc.quick_stat` counters. See the lower packet's
[measurement correction](../durable-source-reuse-20261117/README.md#measurement-correction)
and this packet's [original driver location](measurement-correction.json).
The corrected all-distinct-source measurement uses current-domain `Gc.counters`;
the new [counter replay](counter-replay-observations.json) records 9,157,248 to
9,158,560 bytes for eight distinct sources, an additional 1,312 bytes in each of
four alternating trials. Native-counter precision and measurement overhead
still apply; no fixed overhead is promised. There is no upper-layer CPU measurement.
Together with the lower layer's two
executions, the total is 73 assertion calls, not 73 full integration scenarios.

## Replay and verification boundary

Run the lower evidence's replay with this optional argument:

```sh
python3 docs/evidence/durable-source-reuse-20261117/replay.py \
  --repo "$SOURCE_CHECKOUT" --build-repo "$COMPATIBLE_BUILD_CHECKOUT" \
  --opam-prefix "$OCAML_552_PREFIX" \
  --out "$OUTPUT_REPO/artifacts/source-reuse-consumer-replay-new" \
  --consumer docs/evidence/librarian-source-reuse-20261117
```

It checks upper production hashes and that both copied bodies are verbatim
production source before compiling and executing them. The compatible prebuilt
dependency requirement and original observation/replay distinction are the same
as in the lower packet. New output is separate from these retained results.

Complete changed Owner/Execution parser checks passed. Full changed Owner MLI
and ML typing attempts both stopped before the bodies because prebuilt
`masc__Lane_addon_submit_once.cmi` and freshly compiled `owner_under_test.cmi`
made inconsistent assumptions over `Masc__Lane_addon_store`. No substitute
interface or dependency rebuild was used to bypass that error. This proof
therefore executes the actual load bodies, not the whole Durable_owner or
Execution modules, inventory scheduler, server or provider. It does not prove
installed-runtime CPU/RSS recovery or a full product build/regression run.

Original fixture digests from the unchanged provenance are also indexed in
[current-locations.json](current-locations.json). The accompanying flat digest
manifest is a derivative of that provenance, not a new captured run. The scoped
`scripts/check-evidence-locations.py` check verifies all retained original bytes.
