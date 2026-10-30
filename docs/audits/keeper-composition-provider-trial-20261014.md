# Composition result recovery: controlled provider trial, 2026-10-14

The first real model trial shows a faster successful-result recovery path and a
larger failure envelope. It does not establish live Keeper preparation speed.

## Source and execution

Native Stack42813: public nested integration#42902 and measurement harness#42914.
[Focused Test38439301787](https://github.com/jeong-sik/masc/actions/runs/38439301787)
at `b19803084fd9b3782771532a1ff8f588f8dab779` passed nested6 and executor24.
The suite-runner-log artifact11835435230 contains the complete106488-byte corpus:
two fixture producer scenarios, production executor/projection/reader/serializer,
and seven exact default artifact pages. The console omits the large corpus line.

The public success trial recorded2 scopes,2 admissions,4 completed leaves and2
parent deliveries. The partial admission-failure trial recorded4 scopes,3
admission attempts,2 successful admissions,4 completed leaves,1 blocked child
and2 parent deliveries. Original Task/run bindings and independent selected
results remained available. These are isolated public Tool executions.

Model runner source digest:
`f2245b9c94fb2411f633eec5f82dc52d2b2a29ed0c1929f597bcf5b75c1079ef`.
The requested model was `glm-4.7` at the existing Z.AI coding endpoint; every
response reported `glm-5.3-flash`. Both conditions have the same reported identity
in these samples. Each experiment used2 pairs per scenario and alternating order.
Exact requests, responses, usage and outcomes remain in the local experiment
manifests; no credentials or headers were retained.

## Experiment A: text response, strict task JSON validation

Same execution, task, model/options and captured reader responses in both
conditions. Options: temperature0, max_tokens512, thinking disabled, nonstreaming.
Timing begins after the initial composition result is delivered to the model.

| Successful path,2 correct samples per condition | Original | Selected exports |
|---|---:|---:|
| Initial provider ToolResult content |350 B|849 B|
| Total serialized request bodies per sample |21727 B|2969 B|
| Provider requests per sample |2|1|
| Artifact reads per sample |1|0|
| Reported prompt tokens per sample |3471|770|
| Correct completion median |9.234 s|4.119 s|
| First useful recovery action median |4.761 s|4.119 s|

The original result was already a blob marker. Its initial wire content was
smaller, but recovering the answer required another model request carrying an
actual artifact page. Exports made the answer available in the first response.
Raw producer data was17035 B versus636 B selected data; these numbers are distinct
from serialized request bodies and provider tokens.

| Partial unknown-effect path,2 attempted samples per condition | Original | Selected exports |
|---|---:|---:|
| Initial provider ToolResult content |3088 B|6971 B|
| Serialized request body per sample |5546 B|10674 B|
| Reported prompt tokens per sample |1338|2576|
| Strict correct answers |0/2|0/2|

All four partial answers used Markdown fences; original answers also added prose.
Their JSON examples preserved the independent count and unknown-effect failure,
but the requested raw JSON output contract was not met. They remain failed
samples. Experiment A therefore completed4/8 under its explicit task contract.
No producer was replayed. Latency for successful answers is conditional on the
correct counts in the tables, not an overall completion-rate claim.

## Experiment B: explicit JSON response format

A separate experiment added `response_format={"type":"json_object"}` to both
conditions. The first experiment was preserved. Correct counts were0/2 original
versus1/2 selected for the successful path, and1/2 original versus0/2 selected for
the partial path:2/8 total. Some answers used an extra `answer` wrapper or encoded
the requested object as a string; one changed failed_available to `unknown`.
This provider option did not establish reliable task completion. Both experiments
together retain16 attempted samples and6 strict correct answers; none is removed
from the denominator.

## Concrete next finding

The selected failure wire envelope carries2526 B of structured_content and4001 B
of content, beside its artifact reference. Tool_bridge retains both structured
failure data and a separately rendered diagnostic containing the same data and
manifest metadata. Source inspection confirms this boundary. A follow-up should
let the producer declare that structured data carries its diagnostic, preserve
failure class/next move/effect/exports and full durable evidence, and avoid sending
those values twice. It must preserve opaque human failure messages from other
producers and keep async/status projection faithful to the same contract.

The existing effectful read/write-set admission and durable suspension/resume
work, actual preparation-time comparison and visible Ask Question proof remain
separate required work in#42799. These small controlled recovery samples support
their stated path only; no end-to-end improvement percentage is established.
