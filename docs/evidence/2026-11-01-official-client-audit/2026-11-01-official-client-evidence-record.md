# Official client and provider continuity audit

## 공통 헤더

- 날짜(ISO8601): 2026-11-01T09:59:32+09:00
- 작성자: Codex
- 결정 ID: official-client-continuity-20261101
- 적용 대상: Muse MSP, GLM reasoning replay, Keeper native inline checkpoints
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: Current client contracts must survive Memory projection, turn settlement and durable resume.
- 출처: Installed CLI help/version commands and official documents in the table below; `GET /health?full=1`; bounded system-log prefixes described in `runtime-summary.json`.
- 확인일시: 2026-11-01T09:59:32+09:00
- 신뢰도: High
- 제한조건: Contract/source inspection and read-only local runtime observations; model calls and deployment are separate evidence.

| Surface | Current primary evidence | Code path inspected | Finding and limit |
| --- | --- | --- | --- |
| Codex | `codex --version` = 0.166.0, `codex app-server --help`; [app-server contract](https://developers.openai.com/codex/app-server) | `keeper_codex_runtime.ml`, shared official session store and context projection | Completed `contextCompaction` and observed usage invalidate held context. No new defect established in inspected paths; no fresh live multi-turn proof. |
| Claude Code | `claude --version` = 2.1.316, `claude --help`; [programmatic CLI](https://code.claude.com/docs/en/headless) | `keeper_claude_code_runtime.ml`, `runtime_claude_code.ml`, official session/context store | Explicit session identity and compaction boundaries inspected. Existing quota failures are observations, not proof of a new adapter defect. |
| Antigravity | `agy --version` = 1.4.12, `agy --help`; [headless](https://antigravity.google/docs/cli/headless), [resume](https://antigravity.google/docs/cli/commands/resume) | `runtime_antigravity.ml`, `keeper_antigravity_runtime.ml`, carried context | No compaction witness means unchanged context is resent. Quota prose alone cannot establish typed account exhaustion or safe replay. Additional documented terminal statuses need follow-up. |
| Muse Code | `muse --version` = 1.4.14; `muse serve --help`; `muse schema generate-json-schema`; [MSP schema](https://github.com/meta-models/muse-code-sdk/blob/main/schema/msp/msp.d.ts) | MSP decode → serve → scoped quota observers → Keeper/Fusion/readiness/Board/exact consumers; view gap → held-context frontier → settlement | Typed quota was discarded; gaps did not invalidate held Memory. Both fixed with protocol fixtures. Installed schema fingerprint: `sha256:c94c3d1f2f51e6424074b9ec43eac3eedcf532d3dcd77351ec1383a87d3049c6`. The historical corpus fingerprint is intentionally retained, not relabeled as current coverage. |
| GLM Coding | Local `glm --help` identifies a Claude Code wrapper; [Z.AI Thinking Mode](https://docs.z.ai/guides/capabilities/thinking-mode) | `reasoning_dialect.ml` → source-stamped checkpoint messages → `backend_glm.ml` request | Separate API path loses active tool-call reasoning when full-history preserved thinking is off. Separate stack layer repairs it. The local wrapper is not a separate MASC protocol. |
| Kimi Coding | `kimi --version` = 2.4.0, `kimi --help`; [providers](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/providers), [error reference](https://www.kimi.com/code/docs/en/kimi-code/error-reference.html) | `config/runtime.toml` uses OpenAI-compatible HTTP; shared reasoning provenance/projection and request serialization | MASC's configured lane uses HTTP rather than `kimi` session ownership. Required `reasoning_content` is distinct from native CLI session state. No fresh Kimi model request was made. |
| OpenRouter | [reasoning details](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens) and runtime 402 observations | Shared Chat Completions serializer/reasoning-details replay and failure routing | Preserve structured reasoning details across tools. Observed 402 states requested 131072 output tokens exceeded the credential's affordable allowance; no output limit or account spending setting was changed. |
| Ollama Cloud | `ollama --version` = 0.40.13, `ollama --help`; [cloud](https://docs.ollama.com/cloud), [tool calling](https://docs.ollama.com/capabilities/tool-calling) | Configured cloud `/v1` Chat Completions path; separate `backend_ollama.ml` native `/api/chat` path | Native Ollama `thinking`/tool messages and OpenAI-compatible reasoning fields are separate contracts. No new defect established in inspected paths; no cloud generation was invoked. |
| MiniMax native API | [OpenAI API contract](https://platform.minimax.io/docs/api-reference/text-openai-api) | Native parser → typed inline witness → Keeper finalization → checkpoint save/load → next request | Visible-text normalization and blank-shell pruning could corrupt/drop exact native carriers. Separate stack layer preserves witnessed source bytes. |

The recently retained [context audit](../../audits/2026-09-29-repeated-runtime-context.md) is background, not current execution proof. The shared session-store/recall/outbox code was read again at base `dbd032511fea4e3d04687448275c0f41abff56cc`.

## 검증 (Verification)

- 1차: Opened the primary documentation above and compared relevant fields to current source. Exported the installed Muse schema without a model call.
- 2차: Captured the installed client versions/help; server reported release 0.66.0 and binary commit `dbd032511fea4e3d04687448275c0f41abff56cc`, effective runtime root `/Users/dancer/me/.masc`.
- 3차: Added actual production-adapter fixtures for quota/account/effect propagation and four-turn Memory redelivery; separate stack layers add GLM checkpoint/request and MiniMax disk-restore/request regressions. Focused CI results are recorded separately when available.
- 재현 결과: Source and parser checks establish the defects and well-formed changed source. Behavioral success requires completion of the selected CI suites; syntax checks are not type or behavior proof.

The log capture covers 367557 complete JSONL lines across October 30, October 31 and the November 1 prefix at capture time. `runtime-summary.json` contains counts, first/last timestamps and coordinates, prefix byte lengths and capture-time digests. These are message counts, not deduplicated request counts. Raw private conversations, authentication and account identifiers are excluded. The summary is a derivative; the private log bytes are not published.

| Log message class | Oct 30 | Oct 31 | Nov 1 prefix |
| --- | ---: | ---: | ---: |
| Muse schema mismatch warning | 1053 | 327 | 22 |
| Muse model context-overflow message | 225 | 20 | 0 |
| OpenRouter payment-required message | 0 | 80 | 60 |
| Antigravity quota text in error message | 0 | 172 | 28 |
| Runtime failure lacking execution capture | 345 | 153 | 24 |

The Muse context-overflow logs motivated the continuity checks; they do not prove that the gap repair caused or cures those specific historical overflows. A read-only outbox inspection found one nonempty outbox with 34 receipts and 209247 bytes, not the earlier tens-of-megabytes repeated-results backlog.

## 불확실성 (Uncertainty)

- 미확인 항목: New-head behavior CI, post-install live multi-turn execution, quota reset expiry in a live account, and long-duration failover across every named service.
- 영향: A source or fixture result cannot establish deployment or absence of all provider bugs. Native clients may compact opaque state outside MASC's observations.
- 추가 확인 필요: Read exact-head CI results and test logs; after installation, observe real subsequent turns and durable receipts. Keep unrelated contract gaps as linked issues.

## 적용범위 (Scope)

- 영향 받는 영역: Typed Muse quota consumers and Memory invalidation; GLM active-exchange reasoning; exact native inline checkpoint preservation.
- 제약/배제: No runtime data writes, service restarts, shared Keeper messages, billing changes, full regression claim or deployment. `requestDenied` is not treated as whole-turn no-effects evidence.
- 롤백 조건: Revert the affected stack layer if exact-head tests or live receipts show a contract regression; retain the original failure evidence.
