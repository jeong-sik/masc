# 연속성 후속 수리의 SDK 실행 기록

검증한 commit은 `f635d901af065b85df3547956b6b84625d544715`, tree는
`771cef8bee7cd990d9197ad120d4db95e34d0cd1`이다.
clean checkout에서 `scripts/ci-run-targeted-tests.sh`에 일곱 target을 명시해
2026-11-16 16:20:22Z–16:24:48Z에 실행했다. 종료 코드는 0이고,
아래 244개 케이스가 통과했다. 원본 로그 전체를 공식 artifact API로 읽고
161,379바이트와 SHA-256
`57dbbe1a6bdb2c7410eb9de161649511a9427eb394021d1c9304bd84b8737258`를 확인했다.

| 실행한 suite | 통과 |
| --- | ---: |
| `packages/agent_core/test/test_tracing` | 16 |
| `packages/agent_core/test/test_pipeline` | 137 |
| `packages/agent_core/test/test_otel_tracer` | 33 |
| `packages/agent_core/test/test_otel_tracer_fiber` | 4 |
| `test_keeper_stream_retry_consumers` | 6 |
| `test_keeper_turn_driver_accept` | 44 |
| `packages/agent_core/test/test_agent_cleanup_diagnostics` | 4 |

`test_keeper_turn_driver_accept`의 case 28은 동일한 실제 accumulator →
progress callback → registry → production probe → stall 판정 경로에서 두 종료를
검사한다. 기존 #47962 정책에 따라 reasoning-only `EndTurn`은 원래 run·response와
typed 완료를 유지한다. `MaxTokens`는 기존 typed 거절과 truncation selector를
유지한다. 새 테스트의 잘못된 거절 기대를 고쳤으며 production acceptance는 바꾸지 않았다.

`test_agent_cleanup_diagnostics`의 네 케이스는 실제 public `Agent.run`과
execution store를 거쳐 두 진단 위치의 원래 예외·source location·canonical
terminal/recovery와 새 reserved logger 예외 전파를 검사한다.
이 실행은 앞서 보존한 [helper replay](../runner-cleanup-diagnostic-20261116/README.md)와
별도 증거다. helper 캡처의 당시 범위와 바이트는 그대로 유지한다.

실행 환경은 genuine Keeper Linux lane의 OCaml **5.5.1**, Dune 3.24.2,
Alcotest 1.9.1, Eio 1.3이다. 저장소 핀 **5.5.2**와 다르므로 핀과 같은 환경의
CI 또는 Release 검증으로 부르지 않는다. 실제 의존성을 전용 prefix에서 사용했으며
stub·SDK source·공유 opam switch를 바꾸지 않았다.

이 문서는 [실행 영수증의 선택 기록](verification.json)이다. 원본 전체 로그는 포함하지
않으며, JSON을 원본 로그와 같은 바이트 또는 같은 해시라고 주장하지 않는다.
run1–3의 실패는 각각 보존했다. 이전 423개 케이스·native Muse 관측·추출 helper
결과는 각자 기록된 head와 범위로만 인용하고 합산하거나 현재 head 결과로 바꾸지 않는다.

이후 문서만 추가한 head가 이 결과를 인용할 때는 검증한 commit과의 전체 diff가
문서뿐인지 따로 확인해야 한다. 이 기록 자체가 이후 head의 실행을 증명하지 않는다.

검증하지 않은 범위는 전체 회귀·CI·실제 provider와 network delivery·watchdog fiber,
설치 후 fleet·서버 재시작 복구·릴리스 준비 완료다.
