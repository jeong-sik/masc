# Encode OpenAI chat streaming requests once

`Complete_common.serialize_final_http_request_unadmitted` previously encoded a
complete request, parsed those bytes to add streaming fields, then encoded again.
For streaming OpenAI chat it now uses the same canonical request artifact,
extracts the output-token receipt and finalizes the JSON tree before encoding.
The final seal still hashes the actual outgoing bytes. Sync and other codecs keep
their existing paths. No request, tree or authority is cached.

Raw `Intlit` fragments and nonfinite floats retain the text injector's validation
through the lower Core API. Dropping those values before validation would change
refusals or writer exceptions. The receipt is extracted before the encoder so its
result-mapping closure does not capture the complete artifact; peak retention was
not measured.

## Actual comparison

Measured source: Core `922090554eae4c3bdeb37a1eac162a3b551299a2`, consumer
`f74e81c107dfc6974b60645670ed909bcce0c2f3`, baseline
`1c7ce32df1db1d5e87c7b916922a5309049a808a`.

[Source inputs](native-inputs.json), [fixture](probe_actual.ml),
[observations](observed.json) and [native verification](native-verification.json)
retain the completed curated replay. All 19 commands reached their expected
result, including the intentional hidden-Yojson compile refusal. Complete original
and changed consumer ML files were compiled against their full explicit MLI;
both CMI digests stayed unchanged after ML compilation. PPX inline tests were
dropped, not executed. Fatal warnings 4, 8, 32 and 69 remain enabled.

The actual comparison made 104 assertions: seven configuration cases covering six
HTTP codecs, sync/stream controls, body bytes, sealed/computed SHA, codec and output
receipt, plus 30 raw-schema/tool-argument cases and four measured request cases.
The full maintained output-token-receipt suite passed all 15 tests. The lower
Core's four maintained tests also passed with only declared test libraries public.
The consumer fixture compares serialization rejection text; the lower Core tests
separately compare exception constructors and detail.

| Synthetic input | Wire bytes | Allocation ratio after/before | Median paired process CPU ratio |
| --- | ---: | ---: | ---: |
| Ordinary 4 KiB | 5,010 | 0.58226 | 0.51793 |
| Ordinary 256 KiB | 311,442 | 0.36196 | 0.54954 |
| Raw-literal fallback 4 KiB | 4,392 | 1.00051 | 0.97037 |
| Raw-literal fallback 256 KiB | 262,440 | 1.00002 | 0.97222 |

Each row uses four paired rounds, alternating order, eight requests per side.
Allocation is `Gc.allocated_bytes` for the current standalone domain; CPU is
`Sys.time`. The large ordinary case uses 30,839,456 versus 11,162,784 counter bytes
per eight calls. Fallback retains the old work and adds 40 counter bytes per call;
these short CPU samples do not establish a general fallback improvement. Earlier
broader-link observations are preserved separately and give the same allocation
ratio and a 0.54080 large ordinary CPU ratio.

Wall time comes from uncontrolled `Unix.gettimeofday`; it is not monotonic server
latency. The fixture forces GC only in its owned process. No live MASC, HTTP,
provider, pool dispatch, installation, whole-host CPU/RSS or peak-retention result
is claimed. Other dependencies remain prebuilt; this is not a Dune workspace build
or full regression.

## Replay

```sh
python3 docs/evidence/openai-stream-encoding-20261117/replay.py \
  --repo "$CANDIDATE_CHECKOUT" --build-repo "$COMPATIBLE_BUILD_CHECKOUT" \
  --opam-prefix "$OCAML_552_PREFIX" \
  --bundle "$CANDIDATE_CHECKOUT/docs/evidence/openai-stream-encoding-20261117" \
  --out "$OUTPUT_REPO/artifacts/openai-stream-encoding-new"
```

Use a new output directory. The manifest freezes actual source and fixture hashes,
including the baseline Git object and PPX executable location. The replay compiles
complete modules and the actual maintained suites, with only namespace aliases
for the fresh candidates. Other dependencies must be compatible prebuilt libraries.
Its output records exact argv, terminal results and new observations; an incompatible
prebuilt graph is an error. It does not invoke Dune, provider calls or the server.

Two initial recipe failures, missing prebuilt runtime archives and concrete
Digestif link order, are retained in the original working run. The final recipe
adds the real runtime packages and places the concrete C backend before its
consumers. No fake interfaces or product dependency rebuild was used.

[Independent source review](source-review.json) covers the frozen consumer delta
and original complete-module evidence. It is not a formal GitHub approval or a
review of this later evidence packaging. Selected JSON verification/review summaries
normalize private paths; their original-capture hashes keep their original meaning.
