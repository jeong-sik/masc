# Native MiniMax Responses binding

Relates #27924 and #45969. Source base is #45962 at `b183eb090a737547fccd2bc12c408228f0a1e9ac`. This stack's source is separate from current main and has not been validated as a current-main combination.

## Official basis and unresolved identities

The [official Responses OpenAPI](https://platform.minimax.io/docs/api-reference/text/api/openapi-responses.json) was fetched again2026-10-25: SHA256 `a8c51922e4530595537030fd5c0ab16a6faaf263e662bf753c588fe61169e5ea`,79832bytes, MIT. Selected model/effort/tool-choice nodes are frozen with that digest. The schema directly names MiniMax-M3 and MiniMax-M3.1-Flash. It describes M2.x reasoning semantics without enumerating exact M2 Responses identities.

The initial proposal copied seven M2/highspeed spellings from the native Chat SDK guide. Review identified that cross-protocol identity assumption as insufficient availability evidence. Those rows were removed. Their Responses availability remains an unresolved item in the original issue, not an unsupported-model claim or a redefinition of whole-issue completion. The two directly named models are the current candidate scope.

M3 is off by default unless non-none effort enables reasoning; effort does not tune its depth. M3.1 always reasons, accepts low/medium/high/xhigh/max, and does not accept none. The existing typed ladder also excludes minimal because its model-specific description lists only the five values. Forced required/named tool choice is not declared: the Responses schema documents auto. A local None_ choice removes tools and sends no undocumented none field. These are documented/local wire facts; no vendor acceptance/rejection was observed.

## Candidate behavior

An explicit minimax_responses provider declares the native endpoint, /v1/responses route and required API-key auth. Two exact provider-scoped rows use the existing preserve_responses_text replay declaration. There is no provider-name/URL heuristic, new capability knob or inline capability override. M3 and M3.1 reuse the categorical effort control and their respective declared ladders. Native Chat, OpenAI opaque and hosted Ollama declarations are untouched.

Each model's public fixture resolves the shipped registry, checks its route/auth, obtains scoped capabilities, and compares stable producing-source and consuming-request contracts. Sync and SSE summary/full reasoning plus function call pass through actual response cache, assistant conversion, canonical Checkpoint message bytes written/read from a temporary file, later tool result and user, and the final Common HTTP serializer's actual codec selection. It checks full-text replay through documented input summary, call IDs, auto/forced/local tool-free behavior, effort object and disable admission. This is message persistence in the same process, not full Agent resume.

## Actual failures and corrected request

- Run40198829234 at3dc43c1ed9e4d1687aa131c03b89c72d32012d03 failed compilation: the fixture named a private dialect helper. No cases ran. It now uses the public replay capability and source stamp.
- Run40198894805 at5dd2109449ae8439896d77e8fd803c0c333eefe8 compiled and ran9 cases; all9 failed at the absent shipped provider. Later replay/control assertions were unreached. These nine fixtures reflected the initial identity proposal and do not certify nine vendor models.
- Run40199106856 at0178e767ff2131c9956923bd0fda99e4ce4d2c99 compiled and ran9 native cases, all failing because the fixture supplied a wrapped wire tool instead of the normalized public tool definition. Registry/scoped declaration checks were reached; later assertions were not. Generic sync16 and SSE22 separately passed in that failed workflow. The fixture now uses name/description/input_schema and the final Common serializer.
- Corrected run40199608144 targets `fe5060711754abcb42188d6c7188eec33074d283`:2 native plus generic16+22 requested; result pending inspection. The changed count reflects the documentation correction, not nine repaired native passes.

No initial failure is relabeled PASS. OCaml syntax, Python TOML/duplicate checks and whitespace are not OCaml parser/behavior execution.

## Current main native Chat integration

Existing #45859 is now confirmed MERGED at `a10b06930eec47805688a939105bfc39bab0f1d7`. Its strict-catalog port is distinct from the earlier121-case execution before that port. New run40198051855 checked out main545d7f2266e3c3d7364369218293ad4ad108f89e and actually passed64 codec cases, including the shipped nine-name native Chat sync/SSE replay case. The workflow overall FAILED because root requested a nonexistent second suite; this is a selection error, not a native codec failure or successful workflow.

The corrected selection run40198342839 checked out main3d22830d3992e6eec7011f65bebb5cbac2f0e4f9 and completed SUCCESS with57 provider-agnostic reasoning replay cases. The complete commit delta between those heads is docs/changelog only (#45926); it changes no implementation/test/catalog input. These are two separately identified executions, not one121-case workflow and not proof of this unmerged Responses combination.

## Limits and next action

Read the exact corrected result at a substantive work boundary. Native HTTP, exact M2 Responses availability, current-main combination, whole Agent restart, rendered UI, installation/deployment, full regression and whole issue completion remain unverified. No local Dune/typecheck/build. Native Stack submit reports repository disabled; REST membership is inspected separately. #27924 remains OPEN.
