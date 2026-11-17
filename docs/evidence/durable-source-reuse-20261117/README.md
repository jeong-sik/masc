# Immutable history-source reuse

Two retained requests can contain the same complete history source while having
different request IDs and preparations. The baseline restores and canonically
encodes that source again for each request. `restore_reusing_source` shares only
the already validated immutable source when the supplied captured owner and all
source-text bytes match. Other source text takes the full decoder.

Baseline: `a5eae5da05442ea52f67e3fd44705293b7392e7c`.
Exact baseline and candidate file SHA-256 values are in
[provenance.json](provenance.json). The candidate is the production Request
implementation and interface, not a decoder implemented by the fixture.

## Measurement correction

The original allocation figures and the claimed 21.47% reduction are withdrawn.
The original drivers used `Gc.quick_stat`, which reports program-wide counters
sampled at a GC boundary. Its differences are not instantaneous allocation
measurements and can even report zero for a short allocating operation. This
was confirmed in the installed OCaml 5.5.2 `gc.mli` and the
[official GC documentation](https://ocaml.org/manual/5.4/api/Gc.html).

The corrected drivers use current-domain `Gc.counters` and subtract promoted
words from minor plus major words. Native counters and measurement overhead
still limit precision; these are not byte-exact allocator events. Original
observations and provenance remain byte-for-byte unchanged. Original versions
of the changed drivers are under `original/`; their digests and locations are in
[measurement-correction.json](measurement-correction.json). The current replay
verifies [replay-provenance.json](replay-provenance.json).

## Observed native experiment

OCaml 5.5.2, 64-bit macOS, fatal warnings 4/8/32/69. Complete copied Source,
Runtime, generic Owner, Question and before/after Request modules were compiled
against compatible prebuilt dependencies. Copies add only `open Masc` and named
module aliases. There are no replacement interfaces. Request bodies come from
a synthetic in-memory `Published_reader` port; source-root identity checks use
an owned temporary directory.

[counter-replay-observations.json](counter-replay-observations.json) retains the
corrected counter replay: 28 initial and 13 additional `check` calls. The checks cover
distinct requests sharing the exact source/input object, unchanged JSON values,
different or malformed source text, noncanonical text, invalid kind/preparation,
`create`/`of_json` seeds, changed preparation and predecessor, summary/body
binding errors, a changed supplied owner/epoch, and replacing the physical source
directory after the first restore. Both paths refuse that replaced root.

For the pair containing a 256 KiB synthetic message:

| Metric | Full restore | Reuse |
| --- | ---: | ---: |
| Current-domain allocation-counter bytes | 29,475,608 | 23,716,368 |
| Reachable words in the pair's union | 372,039 | 339,079 |
| CPU seconds, round 1, eight pairs | 0.636511 | 0.519616 |
| CPU seconds, round 2, eight pairs | 0.611495 | 0.521602 |
| CPU seconds, round 3, eight pairs | 0.632481 | 0.533578 |
| CPU seconds, round 4, eight pairs | 0.631460 | 0.503927 |

In this corrected replay, the allocation-counter difference fell about 19.54%
and the median of the four paired CPU ratios is about 0.8300. The 4 KiB pair's
counter reading was 2,004,664 to 1,851,720 bytes. These readings include
measurement overhead and retain native-counter precision limits.
The union graph is 263,680 bytes smaller at eight bytes per word. CPU uses `Sys.time` with
explicitly alternating order; graph size uses one `Obj.reachable_words` call
over the pair. These independent measurements do not use `quick_stat`.
They are fixture measurements, not whole-server CPU, RSS or leak
measurements. The synthetic source span/receipt is not a complete checkpoint
selector workload. All original numeric observations remain in
[observations.json](observations.json);
its allocation values are historical sampled-counter readings, not allocation
proof.

Every request still decodes/restores its preparation, checks source binding,
canonical request encoding, host/body binding, stored index and the current
physical source root. No provider, dispatch, epoch ownership, Memory or source
acknowledgement authority is retained by this optimization.

## Replay

`replay.py` reads the fixed baseline from Git and the candidate from `--repo`,
verifies current replay source/fixture hashes, adds the namespace aliases and compiles the
complete files. All output and disposable native executables go to a **new**
directory under `artifacts/`. It never calls Dune, a server or a provider.

```sh
python3 docs/evidence/durable-source-reuse-20261117/replay.py \
  --repo "$SOURCE_CHECKOUT" --build-repo "$COMPATIBLE_BUILD_CHECKOUT" \
  --opam-prefix "$OCAML_552_PREFIX" \
  --out "$OUTPUT_REPO/artifacts/source-reuse-replay-new"
```

The path-normalized [native recipes](native-recipes.json) are a derivative of
the recorded native argument vectors, not a portable clean-build recipe. They
require the compatible prebuilt `_build` interfaces and archives and OCaml
5.5.2 packages. Missing or incompatible artifacts fail visibly; this script does
not rebuild dependencies. The recipe retains an earlier experiment's include
directory; it contained no CMI files when the packet was curated. That check does
not establish its contents at original compilation time.

[observed-dependencies.json](observed-dependencies.json) records 324 native
archive hashes collected **after** the original runs. Those hashes do
not establish archive source heads or immutable compile-time provenance.
The original command-manifest digests are in `provenance.json`; the corrected replay writes
its own commands, stdout, stderr, source hashes and results without overwriting
the retained observation.

This evidence does not establish a complete product build, installed-runtime
improvement, original stalled-request recovery or full regression success.

Original fixture digests from the unchanged provenance are also indexed in
[current-locations.json](current-locations.json). The accompanying flat digest
manifest is a derivative of that provenance, not a new captured run. The scoped
`scripts/check-evidence-locations.py` check verifies all retained original bytes.
