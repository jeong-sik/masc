# 런타임 연속성: 무엇을 근거로 판정하는가

압축·재연결·후보 전환·진단 기록을 고칠 때는, 관측한 사실과 그 사실로 내릴 수 있는
판정을 먼저 구분한다. 이 문서는 기존 계약의 위치와 수리 이력을 연결하는 지도다.
타입·상태 전이·전송 계약의 정본은 아래 모듈 인터페이스다.

## 판정별 소유자

| 질문 | 정본과 소비자 | 별도로 유지할 사실 |
| --- | --- | --- |
| Muse 세션을 이어도 되는가? | [Runtime_muse_serve.resume_last_turn](../../lib/runtime/runtime_muse_serve.mli) → session/resume admission | 완료 턴 개수는 압축 때 다시 센다. 정확한 턴 ID·끝난 상태·미확정 dispatch의 관계가 재개 근거다. |
| 공식 클라이언트가 어떤 문맥을 보유하는가? | [Keeper_official_client_session_store](../../lib/keeper/keeper_official_client_session_store.mli)의 frontier·settlement·held_context → 각 adapter | 정본 입력, 전송한 입력, 완료를 확인한 입력, vendor가 보존하는 문맥은 서로 다른 사실이다. |
| 채팅 턴이 끝났는가? | [Keeper_chat_run_signal](../../lib/keeper/keeper_chat_run_signal.mli) → TUI·connector·journal 소비자 | 한 provider 후보의 StreamIncomplete/진단은 전체 턴의 종료가 아니다. |
| provider가 생산 중인가? | [Streaming](../../packages/agent_core/lib/llm_provider/streaming.mli)의 first-token·deliverable predicates → [Keeper_agent_run_turn_helpers](../../lib/keeper/keeper_agent_run_turn_helpers.mli) watchdog | reasoning 생산은 진행이다. 이를 최종 답으로 전달할 수 있는지는 완료 시 accept gate가 판정한다. |
| 실행 결과와 진단 기록이 누구의 것인가? | [Agent_trace](../../packages/agent_core/lib/agent/agent_trace.mli)의 실행 정산·[Agent.last_raw_trace_run](../../packages/agent_core/lib/agent/agent.mli)의 귀속 → Runtime_agent 결과. [Tracing](../../packages/agent_core/lib/tracing.mli)의 span·trace-context 관측 경계 → provider·tool 소비자. [Reserved_exn](../../packages/agent_core/lib/llm_provider/reserved_exn.mli)이 삼키면 안 되는 예외를 판정한다. | 정본 실행·checkpoint 실패는 실행 권위다. raw trace와 선택적 tracer의 일반 진단 실패가 실행 결과를 바꾸거나 효과를 다시 실행해서는 안 된다. 실제 취소·reserved 예외는 보존하며, 이전 실행의 기록은 현재 실행 증거가 아니다. |

소유자가 다른 판정을 한 enum으로 합치지 않는다. 예를 들어 `Run_yielded`는 trace의
관측 분류이고, cooperative 실행의 실제 중단 지점과 다음 실행 허가는 별도 소유자가 정한다.
반대로 같은 판정을 소비자마다 다시 만들지도 않는다. 채팅 종료는
`Keeper_chat_run_signal`, 생성된 내용인지는 canonical Streaming predicates를 따른다.

## 수리 이력에서 빠졌던 경계

| 수리 | 원래 고장 | 후속 변경에서 유지할 경계 |
| --- | --- | --- |
| [#48054](https://github.com/jeong-sik/masc/pull/48054) | Muse 압축 후 줄어든 count를 세션 불일치로 처리 | 관측용 count를 세션 identity로 쓰지 않는다. 마지막 턴 ID와 끝난 상태를 검증한다. |
| [#48737](https://github.com/jeong-sik/masc/pull/48737) | Codex 압축이 보존한 standing System의 receipt를 지워 전체 System 재주입 | 실제로 보존된 System과 재전달할 문맥을 구분한다. 미확정 전송을 성공 receipt로 바꾸지는 않는다. |
| [#35986](https://github.com/jeong-sik/masc/pull/35986) | 후보 실패를 Event_error로 전송해 다음 후보의 답 수신을 중단 | 실패 범위는 후보이며 최종 턴 판정 전까지 소비자가 계속 읽는다. |
| [#36169](https://github.com/jeong-sik/masc/pull/36169) | reasoning이 계속 와도 본문이 없어 진행 없음 timeout | watchdog의 생산 신호와 최종 답 수락 조건을 구분한다. ping·빈 carrier는 생산 증거가 아니다. |
| [#45995](https://github.com/jeong-sik/masc/pull/45995) → [#51935](https://github.com/jeong-sik/masc/pull/51935) → [#52494](https://github.com/jeong-sik/masc/issues/52494) | 종료 기록, 중간 기록, 시작 기록 순서로 진단 실패의 실행 전파가 발견됨 | 개별 write만 고치지 말고 시작부터 종료까지 본다. trace 가용성과 관계없이 실행·예외 정산 경로는 하나다. 현재 실행 ID와 다른 완료 trace를 결과에 붙이지 않는다. |
| 2026-11-16 tracer 후속 수리 | Fmt 출력 채널 실패가 본문 실행을 막거나 성공값·원래 예외를 덮음 | preferred `Tracing.with_span`은 본문 진입 여부와 결과·예외/backtrace를 보존한다. 본문 진입 뒤에는 효과를 재실행하지 않는다. trace-context 조회의 일반 실패는 빈 관측이며, `Reserved_exn`은 cleanup·parallel wrapper 안의 취소도 원래 outer 예외 전체로 전파한다. |
| L3: canonical cleanup 진단 수리 | abort·terminal receipt 실패 뒤의 Eio debug 출력 오류가 선택된 reserved 원본 예외를 덮음 | 실행 journal의 정산과 예외 선택은 `Agent_execution_runner`가 소유한다. 일반 진단 실패는 그 선택을 바꾸지 않고, 새 reserved 진단 예외는 기존 `Reserved_exn`으로 전파한다. HostStop의 모든 원인 판정과 Reserved의 한 원인 포함 판정을 합치지 않는다. 연결된 helper 캡처의 범위와 public Agent 실행 검증을 구분한다. |
| [#47097](https://github.com/jeong-sik/masc/pull/47097) → [#52487](https://github.com/jeong-sik/masc/pull/52487) | 누락된 최신 답의 거짓 성공을 막는 history 검증이 정상 압축을 거짓 실패로 처리 | 정확한 최종 답 검증을 유지하면서 압축된 앞부분과 훼손된 범위를 typed coverage로 구분한다. |

이력에 같은 단어가 있어도 기존 guard를 그대로 지우지 않는다. Muse의 압축 count와
Agent Core의 checkpoint/durable turn count는 다른 계약이다. 후자는 실행 단계와
소유권을 검증하며, [#52341](https://github.com/jeong-sik/masc/issues/52341)의 복구는 그 단계에 맞춰야 한다.

## 변경을 확인하는 방법

먼저 `입력 사실 → 판정 소유자 → 직접 소비자 → 실제 시나리오`를 적는다.
문자열·정규식으로 로그를 분류하거나 임의 횟수·시간으로 성공과 실패를 정하지 않는다.
프로토콜 파싱, 정확한 ID·digest 비교, 실제 저장 실패와 명시적 취소는 각 계약에 따라 처리한다.

유사 수리의 확인 범위는 다음처럼 실제 동작을 따라간다.

- 압축: 같은 세션의 시작 → 압축 → 재개. 변한 count와 안정된 턴 ID를 함께 두고,
  다른 턴 ID·잘못된 완료 범위는 계속 거절되는지 확인한다.
- 보유 문맥: Start → 완료 → Resume → compaction → Resume의 실제 전송을 확인한다.
  System·Goal·승인 관측은 issuer의 partition과 순서를 보존한다. pure projection의
  digest가 같다는 사실만으로 adapter의 세션 유지나 vendor 보유를 증명하지 않는다.
- 후보 전환: 첫 후보의 스트림 실패 뒤 다음 후보의 답과 최종 종료를 같은 소비자로 읽는다.
- 생산 신호: reasoning이 오는 동안 watchdog 진행을 확인한다. 완료 응답의 수락은
  [Response.accepts_response](../../lib/keeper_tooling/response.mli)가 판정한다.
  [#47962](https://github.com/jeong-sik/masc/pull/47962)에서 모든 턴의 reasoning-only
  `EndTurn` 종료를 허용했다. `MaxTokens`는 잘린 응답이므로 checkpoint continuation을
  위해 거절한다. 화면의 receiving 표시는 실행 진행의 정본이 아니다.
- 진단 실패: 같은 Agent/sink로 한 번 성공한 뒤 시작·응답 기록·도구 기록·종료를 각각
  실패시킨다. 응답, 효과 횟수, 정본 terminal, callback, lifecycle, 현재 trace 귀속을 확인한다.
  실제 checkpoint/journal 거절과 취소는 원래 결과로 남는 대조군을 둔다.
- tracer: 시작 전·provider 응답 뒤·tool 효과 뒤의 관측 실패에서도 같은 실행 사실을
  확인한다. 전용 Fmt 출력 채널을 닫아 실제 I/O 실패를 만들되 프로세스 stderr는 유지한다.
  checkpoint 거절·실제 Eio 취소와 진단 실패를 겹쳐 보고, wrapper에 담긴 reserved 예외를
  일반 진단 실패로 삼키지 않는지 확인한다. low-level `TRACER.with_span` 직접 호출과
  preferred `Tracing.with_span`의 격리 계약은 구분한다.

기존 실행 시험은 `test_runtime_muse_serve`, `test_keeper_codex_current_context`,
`test_keeper_stream_tool_accum`, `test_keeper_run_tools_hooks`, `test_pipeline`,
`test_agent_advanced`에서 찾는다. tracer의 결과·예외·trace-context·wrapped reserved
경계는 [test_tracing.ml](../../packages/agent_core/test/test_tracing.ml), 실제 Fmt 고장과
checkpoint·취소 조합의 Agent 회귀 소스는
[test_pipeline.ml](../../packages/agent_core/test/test_pipeline.ml)에 있다.
source-extracted replay, 문법 검사, 실제 통합 시험, vendor 세션 실측, 설치 후 관측은
각각 실행한 범위로 기록한다. 하나의 성공을 다른 범위의 증거로 이월하지 않는다.

후보 실패에서 다음 후보의 답까지 같은 Slack·Discord adapter와 TUI wire·journal을
잇는 시험은 `test_keeper_stream_retry_consumers`에 있다. 실제 registry callback에서
production progress probe·stall 판정·완료 응답 accept까지 잇는 시험은
`test_keeper_turn_driver_accept`에 있다. fixture의 stream과 제어 시계가 실제 provider
호출·watchdog fiber 실행을 대신 증명하지는 않는다.

native Muse 압축·세션 재적재 실측은
완료 턴 수 3→1과 같은 마지막 턴 ID, release 후 reload·다음 턴 완료를 확인한다.
같은 host 프로세스에서 측정했으며 MASC adapter 실행·서버 재시작 복구 증거는 아니다.

## Native System 갱신의 검증 범위

issued 관측을 공통 Resume projection이 별도로 고른다는 사실만으로 native adapter가
전체 지시문을 다시 보내지 않거나 같은 세션을 유지한다고 결론 내리지 않는다.
Codex는 변경된 지시문을 model-visible Developer 주입으로 반영하고, Muse는 전체
System을 포함한 canonical source가 바뀌면 새 세션을 선택할 수 있다.
Muse가 Start turn text에 합치는 instruction frame과 Codex의 Developer role은 서로
다른 전송 계약이다. 둘을 같은 native System 설정이라고 부르지 않는다.

Codex의 분해 가능한 issued System은 base와 현재 standing 관측의 전달을 따로
계획한다. 정확한 base와 native posture의 정산된 receipt가 있으면 새 operation이나
Goal은 명시적으로 이전 관측을 대체하는 Developer snapshot으로 보낸다. 같은 관측을
User 본문에 중복하지 않으며, Completion Authority 같은 턴별 관측은 계속 전달한다.
주입 ACK 전에 turn/start를 보내지 않고, 완료 정산 전에 새 receipt를 보유 증거로
쓰지 않는다. issuer가 불명확하거나 base의 전달 근거가 없으면 전체 System을 갱신한다.
native compaction용 developerInstructions는 현재 전체 System을 그대로 유지한다.
알려진 compaction의 재구성 계약과 단순 token estimate/window-fill 관측은 구분한다.

Antigravity와 Muse 같은 framed `Canonical_source_guard` 어댑터도 같은
`Keeper_official_client_host.canonical_system_guard` 규칙을 공유한다.
분해 가능한 issued System(`issued.text = raw_system_prompt`, 지원 standing 관측인
`Constitution_amendments`·`Active_goals`·`Direct_input_source`만 포함)은
별도 `system_prompt_scope` 태그와 함께 `base_text`와 정적 workspace/posture
안내를 해시하고, Resume에서는 `Host.framed_prompt_for_turn`이 공통
`standing_system_replacement_notice` 바로 아래에 현재 standing 관측을
발급 순서대로 중복 없이 실어 빠진 관측 종류의 해제를 명시한다.
`Goals_awaiting_proof`가 포함되거나 issuer가 일치하지 않는 hook override는
전체 System과 빈 scope로 해시해 새 세션을 연다.

Goal·승인 관측의 권위와 순서, 관측 제거와 미확정 ACK를 보존하는
전달 계약 없이 `base_text`만 해시하거나 지시문 주입을 없애는 수리를 하지 않는다.
그 최적화가 필요하면 기존 receipt와 provider별 실제 갱신·압축 계약에서 출발한다.

tracer 후속 수리의 실제 Fmt 반례와 후보 복구 캡처는
모듈 경계 실행만 증명하며 Agent 통합 시험이나 SDK suite 결과를 대신하지 않는다.
