# Composition failure presentation: execution and provider evidence

This comparison measures result recovery over already executed fixture results.
It does not measure live Keeper preparation, whole-task completion, effectful job
continuation or Ask Question screen behavior. Native Stack #42813 remains draft.

## Executed producer and artifact capture

[Test 38443355344](https://github.com/jeong-sik/masc/actions/runs/38443355344)
at `984158d382ac79afee17425b4be48b336c00ec1b` passed bridge 28, executor 24
and public nested composition 6 cases: 58/58. The selected partial-failure content
was 6,971 bytes with the previous presentation and 3,253 bytes with the structured
diagnostic, a 53.3% reduction. Successful selected content remained 849 bytes.
Complete messages/data stay in durable evidence; failure class, disposition,
unknown effects, available exports and original task/run identities remain visible.

Independent review found missing outer manifest pages in that first corpus.
[Test 38445403694](https://github.com/jeong-sik/masc/actions/runs/38445403694)
at `d5ff28c1096f655e882d9b1efdb4a8161507b8c2` passed executor 24/24 after
repair. References from the original, previous-selected and current-selected
actual wire all contribute exact default pages from the canonical artifact reader.
No producer reruns or Python-generated artifact contents are used.

The corpus contains three scenarios, with 7, 2 and 2 captured pages respectively.
Ordinary descriptor ceilings are 16,384 bytes. A separate boundary uses the actual
new content length, 3,253 bytes, as the same ceiling for both presentations:
previous selected becomes a 386-byte marker and new selected remains inline.
That fixture changes no production ceiling. Its actual execution marker is:

```text
composition_provider_trial_root_capture previous_marker=true selected_inline=true root_page_captured=true producer_dispatches=4 projection_ceiling_bytes=3253
```

## Actual provider comparison

Receipt: `keeper-composition-failure-provider-trial-20261014/manifest.json`,
SHA-256 `6c979d5aaf8e4e14e379a9e9606a00b7733a7b9810df09315ecb9c243921c2ec`.
Producer head/run are the second test above. Executed runner SHA-256 is
`3232a26ebea0b6e3470f9ff2265b853dcc6d016c4f7fd0c82ad0665263216b0f`.
The receipt retains all 12 expected samples and 14 actual HTTP responses.

Transport was the ZAI coding chat-completions endpoint. Requested `glm-4.7`;
every response reported `glm-5.3-flash`. This is evidence about the reported model,
not an observed run of GLM 4.7. Both conditions use temperature 0, max_tokens 512,
thinking disabled, nonstreaming text output, identical task/tool/options and the
same producer result. Two pairs alternate baseline/selected order. Baseline is
`previous_selected`; selected uses the structured diagnostic.

The table gives values **per attempt**, with two attempts in each cell. Request
bytes and prompt tokens include every request needed for that attempt.

| Scenario | Initial tool bytes, previous → new | Total request JSON bytes | Prompt tokens | Requests / artifact reads | Strict correct, previous → new |
|---|---:|---:|---:|---:|---:|
| Successful path control | 849 → 849 | 2,969 → 2,969 | 767 → 767 | 1/0 → 1/0 | 2/2 → 2/2 |
| Partial unknown effect | 6,971 → 3,253 | 10,674 → 5,716 | 2,574 → 1,348 | 1/0 → 1/0 | 0/2 → 0/2 |
| Partial failure at marker boundary | 386 → 3,253 | 13,671 → 5,716 | 3,240 → 1,348 | 2/1 → 1/0 | 0/2 → 0/2 |

The ordinary partial failure reduced actual request bytes by 46.4% and prompt
tokens by 47.6%. At the marker boundary, it removed one reader/model round trip
and reduced request bytes by 58.2%, prompt tokens by 58.4%. A larger inline
message can therefore require fewer total request bytes than an indirect marker.

Overall strict completion was **4/12**: all four successful-path controls correct,
all eight partial-failure samples `invalid_or_uncaptured_response` because the
final assistant content failed strict JSON parsing. All were HTTP 200; outer
response JSON parsed successfully. All samples retain complete reported usage.
No provider errors, unfinished samples or credential-echo outcomes occurred.
Failed response elapsed time is not successful completion time.

The unchanged successful-path control had conditional completion medians
4.367s and 4.011s (two correct each). The payloads and request counts are identical,
so this small timing difference does not establish a change effect. Partial
failures have no correct completion median. The experiment proves reduced wire
and usage costs, but **does not prove improved failure recovery correctness or
whole-task speed**. The original two experiments remain separate: 16 attempts,
6 strict correct, documented in [the earlier audit](keeper-composition-provider-trial-20261014.md).

## Measurement-tool boundary repair

Source review identified malformed response-shape handling, credential echo
propagation and a remaining escaped credential in malformed raw JSON. The runner
now validates provider shapes, stops credential echoes before metadata/history
propagation, and omits raw bodies whenever safe decode/redaction cannot finish.
Original body size/SHA and failed samples remain recorded. Safe responses retain
exact original bytes.

Actual localhost HTTP verification used only a fake credential: 33 scenarios,
66/66 persisted attempts, 72 requests; 14 credential echoes stopped without
follow-up, 40 invalid responses, 4 provider errors, 6 correct and 2 unfinished.
HTTP 200 and 401 malformed escaped echoes retained only hash/size/diagnostic.
204 recorded JSON files passed the credential scan; 48 safe responses matched
exact original bytes. No remote provider or live Keeper was called by this fixture.
The final composed runner SHA-256 is
`9d9bc38b4422a2f7cb114e41e0d341ff11cfdc44ea35200f1b28f8f40c98cbb3`;
receipt `masc-provider-response-proof-nwl70th2/proof-summary.json`.

The actual model experiment used the preceding runner digest, recorded above.
All 14 outer response bodies were valid JSON, so the later malformed-body fallback
repair was not exercised by those observations. Its proof is the separate local
HTTP fixture; the old experiment is preserved rather than relabeled as a new run.

The seven changed OCaml files were compared byte-for-byte with the tested d5ff
head after the lower runner repairs; they are identical. This carries only those
executed inputs, not CI success for a newer whole head. Independent source review,
GitHub approval, full-stack admission, merge and installed behavior are distinct
claims. Resource/job continuation, admission-to-first-action measurement and fresh
Ask Question TUI evidence remain in #42799.
