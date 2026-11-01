# Strict self-review of official-client continuity

## 공통 헤더

- 날짜(ISO8601): 2026-11-01T12:08:43+09:00
- 작성자: Codex
- 결정 ID: official-client-self-review-20261101
- 적용 대상: Native Stack #47014; Memory retention, durable completion/usage, native attempt effects and provider request contracts
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: Strict rereview of the original nine layers found incomplete failure/event-order boundaries. Keep the original published heads fixed and add bounded followup layers.
- 출처: REST PR heads/bases/diffs and stack membership; exact aggregate source `7fd50df9ddb1079279f9ca295cb9a331e4f9fc01`; installed Muse 1.4.14 stable schema; official sources linked below; Test workflow run 41265918467.
- 확인일시: 2026-11-01T12:08:43+09:00
- 신뢰도: High
- 제한조건: Source/contract comparison and previously completed targeted CI. New repair syntax/source review does not establish new-head compilation, behavior, installation or live continuity.

| Finding at original aggregate | Trigger and impact | Bounded repair |
| --- | --- | --- |
| GLM omitted clear controls disagree with Coding endpoint default | Client removes completed-turn reasoning while omitted wire leaves Coding preservation enabled | Send the existing client clear policy explicitly on a declared reasoning clear wire; leave thinking.type absent, preserve explicit overrides and non-reasoning omission |
| Antigravity observed built-in actions can be replayed after transport failure | Native marker write then process exit or model idle; DONE/ERROR can also arrive without ACTIVE | Observe typed built-in start and finish before fallible observers; CAS only no-effect to unavailable, preserving known effects and MCP ownership |
| Muse live push silence cannot certify retained Memory | A dropped compaction's gap notification can arrive after the terminal | Reuse the session but retransmit selected current context; do not persist exact held-context certificates without a durable retention witness |
| Muse can accept an earlier final reply after a newer reply was dropped | A is seen, B is durably committed but lost in push, terminal and gap can interleave | Read the complete contiguous durable current-turn range backward from the terminal's opaque cursor before successful settlement/receipt consumption; derive final reply and per-call metadata from that witness |

The [installed/official MSP contract](https://github.com/meta-models/muse-code-sdk/blob/main/schema/msp/msp.d.ts) does not promise gap delivery order relative to neighboring pushes. It supplies opaque exclusive cursors and contiguous durable pages. The repair follows those cursors without parsing or ordering their contents, stops on the exact current turn boundary and retains uncertainty when evidence is unavailable, truncated or inconsistent. Reading a page does not replay tools or approvals. Quiet success requires the same complete range proof as a visible answer.

Muse's retention fallback deliberately sends selected Memory/context again on resume. It increases request bytes and potentially tokens/latency, and does not cure the historical overflow logs. A future optimization needs a durable witness spanning context delivery and compaction across turns. No new runtime setting or heuristic delay is introduced.

The later review repairs validate the published nested SourceRange shape, reject a push-only gap inserted in a durable page, and require terminal completion for every accumulated current-turn agent message before selecting an answer or quiet completion. Stream kinds and positions remain opaque. SourceRange-absent ephemeral starts are omitted from durable fixture pages; sourced updates are retained. Installed schema was rechecked at 2026-11-01T03:51:42Z with the same manifest fingerprint.

Antigravity uncertainty is scoped to the resolved full-native posture and first recorded inside the validated conversation-ready callback, before fallible session persistence. This covers missing action telemetry while allowing read-only transport fallback. Pre-admission failures and actual MCP Effect_attempted evidence keep their own rules; non-completed provider errors retain their terminal retry class.

The [Z.AI Thinking Mode guide](https://docs.z.ai/guides/capabilities/thinking-mode) distinguishes Coding and standard endpoint preservation defaults. The [API clear control](https://docs.z.ai/api-reference/llm/chat-completion) lets the existing client policy be explicit while leaving the thinking toggle absent. The fix uses typed capabilities rather than guessing from URL text.

The followup layers are [GLM #47095](https://github.com/jeong-sik/masc/pull/47095), [Antigravity #47096](https://github.com/jeong-sik/masc/pull/47096), [Muse #47097](https://github.com/jeong-sik/masc/pull/47097) and [contract fixtures #47098](https://github.com/jeong-sik/masc/pull/47098). Issues [#47081](https://github.com/jeong-sik/masc/issues/47081) and [#47082](https://github.com/jeong-sik/masc/issues/47082) retain the native-effect and Muse reproduction conditions; source fixes do not close the deployment proof gap.

## 검증 (Verification)

- 1차: Reacquired all nine REST heads, direct bases and diff digests; read producers, storage, consumers and candidate/receipt callers. Parent self-review and peer source checks are distinct from formal independent GitHub approval.
- 2차: Read the retained installed Muse schema (`sha256:c94c3d1f2f51e6424074b9ec43eac3eedcf532d3dcd77351ec1383a87d3049c6`) and current official GLM defaults. No model generation, private conversation publication or runtime mutation.
- 3차: Test workflow [41265918467](https://github.com/jeong-sik/masc/actions/runs/41265918467), ref `fix/openrouter-effort-contract-audit-20261101`, exact head `7fd50df9ddb1079279f9ca295cb9a331e4f9fc01`, completed FAILURE on 2026-11-01T02:59:21Z. Twelve explicit suites in minimal mode; no full regression was requested. Eleven suites passed 821 cases: reasoning replay59, catalog28, provider config142, Kimi9, runtime configuration175, format8, Keeper Muse78, Antigravity runtime69, Keeper Antigravity25, Codex199 and checkpoint29. Thinking dialects had three failures among51 cases.
- 4차: The three failing cases used an unregistered Ollama tag, an undeclared Anthropic alias policy and an undeclared Gemini sampling policy. The relevant test/backends and those model contracts were unchanged by the original audit. Followup test fixtures declare their exact model/control data; no production inference is added to make them pass.
- 5차: All 21 initial followup OCaml files passed parsing. Initial peer source checks found no remaining concrete P0–P2 in the GLM authored head `b627ab57a401f0f001451c901a5416b8b692fb39`, Antigravity `0b3988f379b667b93f29abf67e373495a4f495cc` and Muse `62a54f50910a7bfb105683a7c85093a203221e14` deltas against the original aggregate. Caller fixtures and dialect fixtures were directly read separately. The [initial source-equivalence record](https://github.com/jeong-sik/masc/blob/0d9d54f389309838ca4db1887e9156fde09581f9/docs/evidence/2026-11-01-official-client-self-review/source-equivalence.json) binds those 21 file blobs to snapshot `4dd1e9b84f8b774420dc036ef1507198229b3ff4`; it is not a whole-diff, type-check or behavior verdict. Later findings and source changes are separate below.
- 6차: Later automated review found the additional posture/admission, provenance and open-agent boundaries described above; initial source verdicts did not certify them. The GLM missing-parenthesis claim was disproved on its exact published blob by `ocamlc -stop-after parsing -impl test/test_keeper_replay_checkpoint.ml` (exit 0), with the actual function boundaries explained in its resolved thread.
- 7차: Selected run [41270288353](https://github.com/jeong-sik/masc/actions/runs/41270288353) on `0d9d54f389309838ca4db1887e9156fde09581f9` completed FAILURE. Three suites passed 212 cases. Two newly introduced test compile errors stopped the dialect suite and native executable group: construction of a private codec variant and an undeclared direct Digestif reference. Public read-only codec tagging and the existing SHA-256 facade repair those tests without changing production policy or the assertions. [Exact retained coordinates](ci-41270288353-summary.json). New source/fixture repairs are not certified by that failed run.
- 8차: Final bounded peer source reads found no remaining concrete P0–P2 in Antigravity `0caf2425cb5236c5f2eaf6f3fe5b19211755122b` and Muse `c1a8bf0e99676c2a7e39e11689cd1fed401f3147`, each against `0d9d54f389309838ca4db1887e9156fde09581f9`. The public codec-query repair `0df0d1d2a184f5813e09e052f3194bc88d547254` and public digest facade were separately checked against their actual interfaces and declared test dependencies. All 21 final followup source files parsed and match the authored blobs in the current [source-equivalence record](source-equivalence.json), snapshot `62ff44aa00a4f01900e5a14313afe1b9444ed2d5`. This combines the initial full reads and later bounded deltas; it is not type/build/behavior evidence or a formal GitHub approval.
- 재현 결과: New regressions traverse disk restore/admission/request serialization, real isolated protocol hosts and native marker/candidate walks. Local syntax/embedded fixture checks and source review are recorded separately from their requested behavior CI.

## 불확실성 (Uncertainty)

- 미확인 항목: New-head behavior CI, installation, real quota/account resets, post-compaction multi-turn operation and long-duration failover.
- 영향: A source PASS or an older successful test cannot establish the new code is deployed or certify all clients bug-free. The previous aggregate run remains a failure despite its eleven passing suites.
- 추가 확인 필요: Read the exact new-head selected run at a work boundary; preserve its failure coordinates if present. No CI watch/wait/poll loop or local Dune is used by this external session.

## 적용범위 (Scope)

- 영향 받는 영역: GLM clear policy wire, Antigravity observed native effects, Muse durable completion/usage and exact context retention, explicit provider-contract fixtures.
- 제약/배제: Existing nine published layer heads retained. No merge, installation, live Keeper/config changes, spending change or overall regression claim. Existing #44154 Memory corpus mismatch, #47021 custom Kimi identity and #47028 Anthropic account-bound reasoning remain separate.
- 롤백 조건: Revert the affected followup layer if its exact-head behavior evidence shows a contract regression; preserve original failure records and receipts.
