# Codex resumed standing instructions

## 공통 헤더

- 날짜(ISO8601): `2026-11-02T08:43:00Z`
- 작성자: `Codex external coding session`
- 결정 ID: `issue-47572-codex-standing-system`
- 적용 대상: `Keeper_codex_runtime; Codex app-server 0.166.0`
- 결정 상태: `추적 필요`

## 근거 (Evidence)

- 항목: Resume configuration and model-visible Developer history are distinct.
- 출처: [official 0.166.0 release](https://github.com/openai/codex/releases/tag/rust-v0.166.0), [App Server documentation](https://learn.chatgpt.com/docs/app-server), and the installed `codex --version`.
- 확인일시: `2026-11-02T08:43:00Z`
- 신뢰도: `High`
- 제한조건: One new text-only thread on the external session's own account, model `gpt-6.1-terra`, three completed turns. No existing Keeper thread or credentials were changed.

The exact upstream release commit is
`6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`.
[Resume restores history and its reference](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/session/mod.rs#L1693).
With that reference, the [next turn adds world-state differences](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/session/mod.rs#L5131), which do not include the newly configured standing Developer text.
The [initial-context builder](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/session/mod.rs#L4725) and [compaction](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/compact.rs#L84) use the configured instructions.
This is a conditional source finding, not a claim that every Resume ignores new configuration.

The existing [inject-items consumer](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server/src/request_processors/turn_processor.rs#L976) accepts raw Developer messages before the next turn. An [upstream regression scenario](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server/tests/suite/v2/thread_inject_items.rs#L528) checks their presence in the subsequent mock-provider request. That upstream test was read, not executed here.

## 검증 (Verification)

- 1차: Read the fixed release source and locally generated app-server JSON schemas.
- 2차: Installed CLI reported `codex-cli 0.166.0`; the original affected Keeper session also recorded CLI version 0.166.0.
- 3차: Started a new read-only text-only thread with standing marker A. In a new app-server process, resumed the same thread with marker B only in `developerInstructions`. In another process, resumed that thread with B and injected a Developer B message, awaited ACK, then started its next turn.
- 재현 결과: The three actual final replies were A, A, B. All three turns completed; all three app-server processes exited 0. Their item notifications contained only user and agent messages, with no tool items.

[probe-selected.json](probe-selected.json) retains the exact selected outgoing request packets, their original compact-JSON byte counts/hashes, thread/turn identities and observed final replies. It is an explicitly selected derivative, not a byte-identical raw capture. The original 77,130-byte local record has SHA-256 `34dfa55811dad39a9e17a1c36ec40025f7c0d5d8497bdf86a76e9eabd2e22204` and remains under `artifacts/issue-47572-applied-review-instructions-20261102T081000Z/` in the investigation checkout. No authentication material is included.

For #47572, the original MASC turn was `trace-1790137685250-00000#12995`, operation `kmsg-f13009d70d2681e986f1af3cb80296d5`. Its exact User input was found in the native session log. The last earlier compaction was at 06:57:46 UTC; that input arrived at 07:44:29 UTC. Earlier Developer history contains the old review role, and the intervening Developer entries contain no latest no-guard correction. The same original MASC raw trace also records loading a stale `project-agents / masc-pr-adversarial-read` Skill. Private Keeper context is retained locally rather than published in this bundle. These observations establish stale sources and the actual refusal; they are not an HTTP-wire capture of the model request.

## 불확실성 (Uncertainty)

- 미확인 항목: The MASC candidate's OCaml typing and regression execution are not established by the three-turn vendor probe. Installed runtime, next actual Keeper review and other official clients/providers are unverified.
- 영향: Injection appends current instructions; it does not erase old Developer messages. Native compaction and failed turns can invalidate delivery knowledge. An ACK is client protocol evidence, not a guarantee of every upstream storage write or model understanding.
- 추가 확인 필요: Execute the focused MASC suites on the candidate, obtain independent source review, then verify the installed runtime separately. The separately owned stale workspace Skill also needs correction.

## 적용범위 (Scope)

- 영향 받는 영역: Standing Keeper System prompt plus resolved Codex native posture. The existing session frontier records their exact digest only with a completed vendor turn. A changed or unacknowledged value uses the existing Developer injection path before turn start. Per-turn Goal, completion and scheduled observations keep their existing placement.
- 제약/배제: Canonical conversation, existing native session identity and completed effects are preserved. No session reset, history replay, migration, review gate or other provider change is introduced. Full `developerInstructions` can additionally contain canonical System history; this receipt names only the standing prefix described above.
- 롤백 조건: Revert the scoped source change if a regression shows incorrect authority/order, repeated effects or false acknowledgement. Retain the original evidence and report deployment separately.
