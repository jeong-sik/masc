# 주간 변경과 Context 흐름 재검증 — 2026-10-07

판독 기준은 `b99c9d77b503fe53c1635712fae24d5e744bb180`이다. 9월 30일~10월 6일의 일곱 KST 날짜와 10월 7일 현재를 나눴다. 첫 경계는 `e126a20e72319032d2136064562bca1524a87572`다. 이 기간 main first-parent 커밋은 **939개**다. 전체 변경 경로를 집계한 뒤 아래 기능의 생산자→저장→소비자와 주요 실패 경로를 직접 읽었다. 939개 전체 diff의 모든 줄을 검증했다는 뜻은 아니다.

실행 중인 서버의 `/health?full=1`은 binary SHA `831bbeaa0d91014554f570318f6dba91b3c7c223`과 올바른 `<base-path>/.masc`를 보고했다. 따라서 최신 소스와 실행 결과를 같은 버전으로 취급하지 않는다. 이 감사에서 유지하는 두 코드 수정은 별도 PR이며 이 문서 작성 시 배포하지 않았다. 과거 감사 [#41433](https://github.com/jeong-sik/masc/pull/41433)은 탐색 출발점으로만 사용했다.

마감 전 fetch에서 main은 `5f442ddeea667e4451331d1bf66fa03e847f034c`로 세 커밋 더 전진했다. 아래 939개 집계는 고정한 첫 기준의 수치로 유지한다. 추가분은 account allowance의 실행 중 scheduler 반영(#41381), TUI Keeper 탐색(#41527), appraiser 불가 중 Candle 기록 테스트(#41310)이며 이번 코드 수정과의 교차 영향을 별도로 확인했다. 감사 기준, 현재 branch tip, 실행 binary를 한 SHA처럼 표시하지 않는다.

## 날짜별 변경 흐름

각 행의 종료 SHA와 바로 전 행 사이를 diff했다. JSON의 areas는 변경 경로가 많은 상위 12개 영역이며 전 영역 목록이 아니다. 경로 수는 rename 추측을 끈 값이며 이동·삭제·문서 분할도 포함한다. 커밋 수는 first-parent 기준이라 모든 조상 커밋을 세는 다른 감사 수치와 같지 않다. [정확한 경계와 영역 집계](2026-10-07-context-flow/daily-diff-census.json).

| KST 날짜 | 커밋 | 변경 경로 | 종료 SHA | 주요 흐름과 남은 위험 |
|---|---:|---:|---|---|
| 09-30 | 130 | 1,037 | `ae82a3b855` | native resume 중복 문맥 제거, 공유 Goal·Candle Snapshot/Owed/Candidates. 저장 사실과 파생 투영의 구분이 중요해짐 |
| 10-01 | 197 | 1,506 | `a66db1a44d` | Recall을 요구 기반 조회로 전환, artifact 보존, 마지막 후보 한도 소진 처리 개선. queue 성공과 실제 기억 소비를 구분해야 함 |
| 10-02 | 164 | 1,301 | `83d23c96c0` | 전체 기억 fallback 제거, 검색 후보만 원본 검증, Librarian 역사 Task 문맥·catch-up 보존. 읽기 실패를 소거로 취급하지 않는 경로 강화 |
| 10-03 | 58 | 807 | `0ec18301d0` | 짧은 검색 질의와 durable value 판정 개선, lane 관련 변경. 과거 감사의 ‘이 영역 변경 없음’을 그대로 쓰지 않음 |
| 10-04 | 118 | 1,439 | `87123f7df9` | 동적 기억 분류, no-change preflight, Goal 알림 복구, typed Board audience. audience 저장과 읽기 권한은 아직 별개 |
| 10-05 | 14 | 127 | `6a9b9ac462` | 주로 TUI·문서 변화. 변경 건수가 적다고 운영 상태가 안정됐다고 판정하지 않음 |
| 10-06 | 186 | 2,626 | `8ae4ea4392` | provider 경계 정리, 판단 레인 admission 우선권, Goal Pause/Block, curator config wake, cross-cycle ledger seed. seed의 위치 단위 혼합 결함 잔존 |
| 10-07 현재 | 72 | 321 | `b99c9d77b5` | shared-memory digest 추가, Memory 검색 CPU 분리, tool receipt TUI 연결, Librarian prompt 순서·입력 축소. 배포 전인 수정과 새 회귀를 분리해야 함 |

## 기능 매트릭스

**연결 확인**은 열거한 소스 경로가 계약을 구현한다는 판독이다. 실행 PASS가 아니다. **부분**은 구현된 경로와 미검증·누락이 함께 있다. 아래 줄 번호는 감사 기준 SHA의 탐색 위치다.

| 기능 | 현재 소스 판정 | 근거와 남은 조건 |
|---|---|---|
| Runtime failover | 부분 | `keeper_turn_driver.ml:1111`, `keeper_turn_driver_try_provider.ml:2324`: effect/checkpoint 근거로 다음 후보 선택. 5-provider 연속 실행 실측 없음 |
| Codex Context resume | 보수적 재전송 유지 | `keeper_codex_runtime.ml:1226-1250`: host-stop은 마지막 usage보다 먼저 끝날 수 있어 compaction 미관측 가능 |
| Claude Code Context resume | 연결 확인 | `keeper_claude_code_runtime.ml:723,941`: held digest와 compaction 처리. fixture 소스 확인, 실행 미검증 |
| Antigravity Context resume | 부분 | `keeper_antigravity_runtime.ml:658,749`: vendor compaction 증거가 없어 매번 context 전달. Codex 방식의 생략을 그대로 적용하면 기억 손실 위험 |
| GLM Coding / OpenRouter | 부분 | `runtime_execution.ml:32,68`: HTTP Agent Core 경로 공유. GLM의 실제 투영 기록은 아래에 있음. 이 샘플에서 OpenRouter 실행 증거는 없음 |
| Context 수명 / Librarian 지연 | 부분 | `keeper_turn_driver.ml:1803`, `keeper_turn_driver_try_provider.ml:2535,2744`: continuity 선택이 있으면 일반 context marks eviction을 건너뛰고 provider refusal 경로가 처리. [#41428](https://github.com/jeong-sik/masc/issues/41428). 미합성 원문을 임의 숫자로 잘라 해결하지 않음 |
| Drain Queue / continuation | 연결 확인·한계 | `keeper_heartbeat_loop.ml:627-691`: 완료는 admitted batch ack, checkpoint yield는 attention만 ack, 실패·취소·입력대기는 보존. vendor 세션 교체 뒤 이미 ack한 문맥의 복원은 추가 실측 필요 |
| 반복 감지 N+M | 결함·수리 PR | `keeper_run_tools_setup.ml:330-399,626-652`, `keeper_repetition_judged.ml:35-68`: sliding ledger와 누적 history count 혼합. [#41550](https://github.com/jeong-sik/masc/pull/41550)에서 두 위치를 분리하고 반복 판정·저장 실패 경계를 수정 |
| Memory Recall | 연결 확인 | `keeper_memory_os_recall.ml:103-122,199-209`: 상태·건수·조회 안내, 전체 사실 fallback 없음. `keeper_tool_memory_runtime.ml:166-254`: 조회 후보만 원본 검증; 읽기 불능은 빈 결과와 구분 |
| Memory 생산·흡수·소거 | 부분 | `keeper_memory_os_current.ml:2608-2669`, `keeper_librarian_absorb_gate.mli:11-25`: 흡수 원문을 먼저 보존하고 판정 실패 시 범위를 유지. echo/흡수 관측은 기존 #41390·#41513 작업과 겹침 |
| Memory 강화·반감기 | 자동 기능 없음 | `keeper_memory_os_current.ml:2759-2770`: 다시 관측됐다는 사실은 strength 증가가 아님. Candle 반감기와 다른 개념이며 자동 감쇠를 Memory에 연결하면 안 됨 |
| Librarian Working Context | 소스에서 개선됨 | `keeper_librarian_queue_refresh.ml:537-581`, `keeper_librarian.ml:356-362`: #41408로 current Memory 입력 제거. 관측한 binary에는 아직 미반영 |
| Librarian Working State | 캐시 순서 수리 PR | 완료 범위·역사 Task·이전 상태와 Memory를 합성. changing Task가 큰 stable Memory보다 앞에 있었음. [#41533](https://github.com/jeong-sik/masc/pull/41533) |
| Librarian 큐 | 큐 개수는 닫힘 | `keeper_memory_lane.ml:144-168`: Keeper당 실행 하나와 교체 가능한 대기 하나. 큐가 닫혀 있어도 합성 실패 중 원문 크기는 커질 수 있음 |
| World Curator | 부분·역할 공백 | `server_workspace_memory_curator.ml:167-248,288-303`: 변경 Memory 사실을 분류한다. `workspace_memory_context.ml`의 입력은 Keeper Memory이며 전체 Lane의 현재 작업·진행·막힘을 직접 종합한 브리핑은 아니다. 사용자 요구인 공유 상황 전달과의 공백은 [#41525](https://github.com/jeong-sik/masc/issues/41525). 출력 실패를 모두 크기 초과로 해석할 근거는 없음 |
| Shared Fact 안내 | 전달 유지·선정 결함 | 전체 1,146개 중 ID 순서 34개를 매 턴 주입. 원장 모듈의 8192/160/96바이트 절단은 Curator의 의미 판단이 아니다. 공유 정보 전달 자체는 제품 목적이므로 유지 |
| Skills 생산·사용 | 명시적 workflow 있음 | `server_keeper_skill_publish.ml:46-149`, `server_skill_write_audit.ml:27-54`: evidence와 revision 기록, frozen snapshot에서 body 필요 시 조회. Memory→Skill 자동 합성을 보장하는 daemon은 없음 |
| Tool schema / result | 부분 | schema는 고정 prefix·deferred loading이 있고 body는 요청 시 읽음. 제공 목록 크기를 전부 실제 모델 점유로 계산하면 안 됨. 큰 조회 결과는 carried range를 차지할 수 있음 |
| Exact lane 관측 | 누락 | `exact_lane_run_registry.mli:47-61`: outcome/elapsed/output/slot은 있으나 run별 reported usage 없음. [#41532](https://github.com/jeong-sik/masc/issues/41532). bytes/4 같은 토큰 추정으로 대체하지 않음 |
| Board | 읽기 권한 결함 | `board_audience.ml:82-110`은 Direct 대상을 저장하지만 `keeper_tool_board_runtime.ml:175-186`, `board_tool_post.ml:223-283,382-421`의 read는 대상을 검사하지 않음. 기존 [#37152](https://github.com/jeong-sik/masc/issues/37152) |
| Task | inspected lifecycle 연결 | `workspace_task_lifecycle.ml:58-113`: 소유권 충돌, owner-only start, 자기 Done 거부. `workspace_gc.ml:82-156`: archive 저장 후 backlog 제거. 모든 Task 소비자 실행은 미검증 |
| Goal | inspected FSM 연결 | `goal_phase.ml:105-173`, `workspace_goals.ml:705-717`: Pause/Block 복원, 검증 후 사람 확인, #41455로 proof 경로 통합. 생성 feasibility는 기존 #41399 대상 |
| HITL / Access Control | 부분 | `keeper_approval_queue_state.ml:66-111`: restart 불확실성 격리. `types_auth.ml:338-374`: 역할 권한과 Board 객체별 읽기 권한은 별도. operator tool 차단은 기존 #41421 |
| Multi Lane / Schedule | 부분 | judgment priority와 config wake 연결. `schedule_store.ml:865-960`: cancel/retention 경계는 있으나 wake 없는 취소·종단 메모 정리가 제한적. edit delivery는 기존 #41430 |
| Candle / Economy / 논공행상 | 정책 일치·강결합 | 원장 사실·CAS·half-life 투영 확인. `candle_status.mli:54-58`은 appraiser 불가 시 Keeper 소비 금지를 명시. 이를 버그로 바꾸어 말하지 않음. appraisal retry의 재판정 비용은 남음 |
| Portrait / Item Slot | 부분 | `candle_equipment.ml:3-17`, `candle_observe.ml:24-27`: persisted 읽기와 observation 읽기의 appraiser 불가 의미가 다름. 읽기 가용성 계약 통일을 제안 |
| Play Invite | 공개 URL 결함 | `server_bootstrap_http.ml:19-24`가 미설정 URL을 localhost로 채워 `play_invite.ml:60-71`의 미설정 거부를 무력화. 기존 #39953 범위. TUI error-field decoder는 #41427로 개선됨 |
| TUI | 소스 일부 확인·실화면 미검증 | #41407 official tool receipt가 waiting 해제에 연결; #41427 Play 오류 디코더 연결. 이번 작업에서 PTY/브라우저 렌더링을 실행하지 않았음 |
| Terminal-Bench 4.0 | adapter 있음·성공 미증명 | `benchmarks/terminal_bench/agents/masc_agent.py`, `run_matrix.sh`, `aggregate.py`. 현재 수정 SHA의 공식 task verifier 결과 없음. 기존 [#37202](https://github.com/jeong-sik/masc/issues/37202) |

## N → N+M 흐름

```mermaid
sequenceDiagram
    participant Q as 입력 큐
    participant K as Keeper N
    participant P as Provider
    participant L as Librarian
    participant M as 기억 저장소
    Q->>K: admitted input + 현재 Task
    M-->>K: 상태와 조회 경로
    K->>P: working state + 미합성 원문 + 현재 문맥
    P-->>K: 응답 또는 도구 호출
    K->>M: 완료 원문과 실행 증거 보존
    K->>L: 완료 구간 합성 요청
    Note over K,L: 한 실행 + 최신 대기 하나; 합성은 비동기
    L->>M: 기억 저장 후 해당 소비 위치 갱신
    Note over L,M: continuity는 별도 완료 범위와 working state 저장
    M-->>K: N+1에서 커밋된 범위와 working state
    Note over K,P: native resume는 보유 문맥 receipt 사용; compaction이면 무효화
```

1. **N 첫 요청:** ordinary Recall은 본문을 전량 싣지 않는다. Working Context는 별도 artifact, Working State는 완료 원문을 대신하는 요약이다. 도구 결과가 추가되는 같은 턴의 다음 요청은 ordinary Recall I/O를 반복하지 않는다 (`keeper_run_tools_hooks.ml:992-1024`).
2. **N 완료 후:** Librarian은 정확히 완료된 범위와 그때의 Task/Goal을 읽는다. 합성할 자료가 있으면 기억 저장이 성공해야 해당 cursor가 움직인다 (`keeper_librarian_durable_consumer.ml:1239-1265,1347-1349`). 새 fragment가 없는 구간은 합성 없이 skip 위치를 전진시킬 수 있으며(:1267-1277), 이것은 새 기억을 만들었다는 증거가 아니다. 큐 접수·합성 결과·실제 다음 요청 소비는 다른 사건이다.
3. **N+1/N+2:** 합성이 늦으면 이전 working state 뒤의 원문을 계속 보낸다. ‘대기 큐 2개 이하’는 context 크기나 의미 보존의 증명이 아니다. 합성 실패를 만료나 숫자 절단으로 숨기면 연속성을 깨뜨린다.
4. **N+3:** curator는 Keeper 기억을 분류해 공유 원장을 만든다. 분류는 사실 검증·승격이 아니다. 다른 Keeper의 개인 저장소를 덮어쓰지 않는다.
5. **N+4..M:** Keeper가 반복 가능한 절차를 판단해 Skill을 명시적으로 게시할 수 있다. 모든 기억 변화가 Skill 생성을 자동 보장하지 않는다. 별도 성공 조건과 재사용 결과가 필요하다.

Codex의 host-stop은 마지막 응답의 usage 프레임보다 먼저 끝날 수 있다. compaction이 별도 item 없이 후행 `Context_estimate`로만 관측되면, 그 전에 저장한 held-context receipt는 사실이 아닐 수 있다. 그래서 현재의 보수적 재전송을 유지한다. Claude Code의 별도 compaction flag와 Antigravity의 관측 부재도 각 계약대로 판단해야 한다.

확정된 반복 감지 결함은 다른 문제다. 최근 ledger 200개에 누적 judged count 201 이상을 적용하면 N+1부터 seed가 계속 빈다. 다음 사이클마다 같은 조회를 한 번만 해도 다시 감지하지 못한다. [#41550](https://github.com/jeong-sik/masc/pull/41550)은 **history 위치와 실제 ledger cursor를 분리**한다. ledger의 파일·device·inode·append offset으로 이후 행을 읽고, HTTP에서는 실제 Agent checkpoint의 쌍 개수만 기록한다. native 시도 뒤 HTTP로 전환했을 때 native 호출 개수까지 checkpoint에 더하지 않는다. flush는 실제 저장 구간까지 직렬화하며 append 커밋 전에 실패·취소한 행은 큐에 보존하고 ledger 경계를 넘기지 않는다.

서로 다른 두 이력의 연결 순서도 추측하지 않는다. HTTP의 A1..A4 다음 native B5, 다시 HTTP A6인 경우 history와 ledger를 이어 붙이면 A가 다섯 번 연속한 것처럼 보일 수 있다. 순서를 모르는 혼합 이력은 exact 입출력 횟수에는 쓰되, input-only 연속 판정은 이번 실행에서 직접 관측한 호출만 사용한다. 따라서 순서를 입증할 수 없는 과거 입력 반복을 덜 잡는 보수적 한계가 있다. 단일 이력의 순서와 현재 실행의 실제 연속 호출은 유지한다.

최초 cursor가 없는 cold read는 해당 Keeper의 보존된 ledger 전체를 읽을 수 있다. ledger 행 수와 본문 크기는 수집 범위·계산을 보존한 집계가 없어 검증 근거에서 제외한다. 이후 tick은 기존 per-Keeper memo에 본문 대신 fingerprint를 보존하고 새 append만 읽는다. 실제 cold-read latency와 상주 메모리 개선률은 별도 측정이 필요하다. 감사 도중 열린 #41546은 기존 ledger의 역순만 다루고, #41456은 flush 취소 전파를 다룬다. #41550과 겹치는 부분은 어느 PR이 먼저 병합되는지에 따라 재검토해야 한다.

## 입력·캐시·도구 점유 관측

[집계 artifact](2026-10-07-context-flow/observed-context-sizes.json)는 원문 대화·기억·비밀값 없이 크기와 범위만 담는다. UTC 10월 7일의 보존된 로그를 여러 시점에 읽은 관측이며 24시간 전체 또는 원자적 fleet snapshot이 아니다. projection-change 총계와 종류별 집계는 서로 불일치하고 각 읽기의 정확한 경계를 복원할 수 없어 철회했다. 같은 snapshot에서 다시 수집하기 전에는 그 빈도를 근거로 쓰지 않는다.

- 3,850개의 **per_request** usage 행: input 449,851,313, cache read 431,922,974, non-cached input 17,928,339 tokens. 이 집합의 약 96%가 cache read다. 별도 `turn_total`, `conversation_cumulative`, scope 없는 행을 더하면 중복 집계할 수 있어 합산하지 않았다. 큰 총 입력을 전부 재과금·낭비라고 판정하지 않는다.
- 4,515개의 **전송 전 request capture**에서 tool schema 중앙값 75,327 B, system prompt 21,199 B; extra context가 있는 1,442행의 중앙값은 25,894 B였다. 공식 클라이언트의 제공 도구 목록은 deferred schema도 포함하므로 실제 모델에 모두 실렸다는 증거가 아니다.
- 같은 capture의 history 중앙값 12,812개는 canonical checkpoint 크기다. 이 값은 provider input 크기가 아니다. `keeper_wire_capture.ml:274`와 `keeper_agent_run.ml:1931`의 **request_projection_change**가 전송 직전 투영을 관측한다.
- 실제 GLM 투영 기록의 한 Keeper 연속 다섯 턴에서 각 턴 요청의 투영 메시지 개수 최솟값–최댓값은 `223–257 → 37–79 → 45–93 → 51–63 → 2–26`이었다. 이는 원문 위치 범위가 아니며, 전송 전 투영의 메시지 개수 변화만 보여 준다. 해당 다섯 턴의 canonical history 개수와 checkpoint 식별자를 보존하지 않아 원문 누적 여부나 history reset 여부는 판정할 수 없다. 별도 extra-system-context carrier를 포함한 전체 provider 입력량으로 해석하지 않는다. 이것은 기억의 의미 보존, 모든 Keeper, 다른 provider, 재시작 후 N+M 성공을 증명하지 않는다.
- 공유 기억 digest는 1,146개 주장 중 ID 순서 34개, 8,061 B였다. 이는 범위가 좁고 선정 순서가 임의적이라는 증거다. 공유 정보 전달 자체가 낭비라는 증거는 아니다. 토큰 환산이나 판단 정확도 향상을 수치로 지어내지 않는다.
- Continuity 입력의 표본 수·크기 중앙값·공통 prefix 변화는 집계 artifact와 원본 로그가 없어 이번 감사의 검증 근거에서 제외한다. #41533의 prompt 순서 변경은 소스 검토 범위로만 기록하며, 실제 cache hit 개선률은 미측정이다.
- Librarian 입력의 표본 수와 current Memory 포함 빈도는 검증 근거에서 제외한다. #41408의 소스 변경과 관측 binary의 버전 차이는 위 기능 매트릭스에 구분했으며, 입력 빈도를 다시 보고하려면 수집 범위와 집계를 보존해야 한다.
- Recall reference의 전체·중복 행 수는 검증 근거에서 제외한다. 같은 artifact의 durable append/current pin 경로에 대한 I/O 개선 후보는 소스 관찰이며, 중복 빈도와 사용자 지연 영향은 별도 측정이 필요하다.

Tool Result의 내부 `raw_output`과 `data` 필드가 둘 있다는 이유로 모델이 본문을 두 번 받는다고 판정하지 않았다. `tool_bridge.ml:296-329,379-466`의 정상 경로는 본문 하나를 projection한 뒤 model content로 보내며 structured data는 artifact 식별에 사용한다. 실패 경로도 message와 같은 data를 다시 싣지 않는 비교가 있다. 다만 실제 조회 결과 자체가 큰 경우와 공식 클라이언트별 schema 전달은 별도 측정 대상이다.

World Curator의 실행·coverage·unknown-claim 실패 건수는 집계 artifact와 원본 로그가 없어 검증 근거에서 제외한다. 실패 원인을 분리할 수집 범위와 집계, exact run별 usage를 보존한 뒤 token/cache 원인을 분석해야 한다. 현재 근거로 output truncation을 단정하거나 임의 batch 한도를 정하지 않는다.

## 개념과 결합도

Memory(오래 보관하는 사실), Working Context(받은 일 묶음), Working State(완료 대화가 남긴 진행 상태)는 다른 원천과 수명을 갖는다. 중복 이름처럼 보여 합치면 cursor·미해결 입력·사실의 권위가 섞인다. #41408처럼 **그 회차가 사용하지 않는 Memory를 전달하지 않는 것**은 적절한 분리다.

공유 기억의 분류와 개인 기억 조회도 구분한다. 사용자가 명시한 World Curator의 목적은 전체 Lane의 공유 상황을 Keeper에게 전달하는 것이다. 현재 코드의 Workspace Curator는 Keeper Memory 사실 분류를 구현하지만, 그 목적 전체를 구현했다는 증거는 아니다. 수신자가 아직 모르는 정보의 존재를 스스로 검색할 것이라고 가정하면 전달 기능이 사라진다. 자동 전달과 추가 상세 조회는 함께 있어야 한다.

#41389는 도구를 먼저 부르지 않아도 Keeper가 공유 정보의 내용을 알게 하려고 digest를 추가했다. 다만 실제 출력은 Curator가 만든 상황 요약이 아니라 `workspace_memory_ledger.ml:324-349`의 8192/160/96바이트 고정 상수로 자른 ID 순서 목록이었다. 해당 PR은 절단 규칙을 설명하지만 이 숫자의 provider·protocol 근거는 제시하지 않는다. 원장의 저장 책임과 정보 선택·표현 책임이 섞인 문제를 고쳐야 한다. 사실 수집→합성→전달→실제 소비를 확인하는 수리는 #41525에 남긴다.

Candle 반감기는 화폐 가치의 감쇠이며 Memory 소거나 Task 만료가 아니다. 평가 레인 고장이 wallet·장비 조회까지 닫는 정책은 재검토할 가치가 있지만, 현재 명시 계약을 ‘구현 버그’로 몰아 변경하지 않았다.

## 수리, 검증, 남은 일

| PR | 독립 소스 리뷰를 받은 head | 검증 범위 |
|---|---|---|
| [#41533](https://github.com/jeong-sik/masc/pull/41533) | `69047992a4248e429797dfe7e1f942bf857e321e` | prompt/caller complete diff, rebase 및 changelog delta. 입력 재구성 실측은 재검산 가능한 기록이 없어 검증 근거에서 제외 |
| [#41550](https://github.com/jeong-sik/masc/pull/41550) | `05c14758825d8516ab619150101b2b1dc35073f1` | cursor·flush·두 provider 경계·scope 복원·changelog, 20개 OCaml 파일 parse-only, 분리된 SQLite·fixture dispatcher·독립 순수 함수 실행. 추가한 native 회귀 fixture는 이 리뷰 시점에는 미실행 |

#41550 은 위 리뷰 뒤 `05e2f3d78b`에서 파일 generation, cold read projection, 커밋 시점 보고를 추가했고 `a2b331af82`에서 부모 브랜치를 합쳤다. 이 변경은 아직 독립 소스 리뷰를 받지 않았다. 같은 head에서 `test_keeper_tool_call_log`(79개), `test_keeper_turn_outcome`(48개), `test_dated_jsonl`(69개)을 `dune build --root .`로 컴파일하고 실행해 통과했다. CI와 그 밖의 test는 실행하지 않았다.

유지하는 각 direct diff는 작성하지 않은 에이전트가 읽었다. local PASS는 GitHub의 독립 승인이나 compiled/native 실행을 대신하지 않는다. TUI Keeper 질의는 별도 비동기 작업이며 접수나 Running을 답변 완료로 취급하지 않는다.

마감 시 확인한 changelog 형식 실패는 #41533 항목의 자기 PR 번호 누락이었다. 두 문서 줄을 고친 뒤 스택을 재배치했고, `3f1663c4` 트리의 664개 fragment 검사와 diff check가 통과했다. 이 결과는 이후 restack으로 추가된 fragment나 이 문서의 현재 head를 검증하지 않는다. 코드 본문이 같은지를 별도로 대조해 위 최종 head의 소스 리뷰를 갱신했다. 이 문서 수리를 위해 native 테스트나 CI watch를 반복하지 않았다. 10월 8일 리뷰 대응에서는 `1b43c331a0`에 이 문서·집계·기존 fragment 수정만 적용한 트리에서 `python3 scripts/changelog-fragments.py check`를 다시 실행했고, 814개 fragment가 통과했다. 이 검사는 changelog 형식만 검증한다.

로컬 Dune build, CI watch, 실제 provider 전환 실험, 운영 재시작, 배포, PTY/브라우저 렌더링을 이번 감사의 증거로 주장하지 않는다. 현재 binary의 full-health snapshot은 두 관측에서 warming이고 dashboard asset은 mismatched였다. 이는 관측된 운영 상태이며 이 PR들이 원인이라는 증거는 없다.

남은 우선순위는 **World Curator 공유 상황의 수집·전달 공백(#41525)과 Board 객체 읽기 권한(#37152), 반복 seed 수정의 실제 실행 검증(#41550), exact usage(#41532), Librarian 지연 시 연속성 범위(#41428)**다. Play URL은 #39953, Goal feasibility·Schedule delivery·operator tool 제한은 기존 PR로 이어간다. 같은 일을 다시 구현하지 않도록 현재 head에서 재확인해야 한다.

Terminal-Bench 목표는 아직 달성됐다고 판정할 수 없다. [공식 4.0 안내](https://www.tbench.ai/news/terminal-bench-4-0)는 `terminal-bench/terminal-bench@4.0.0`과 바뀐 실행 환경의 재실행을 요구한다. 저장소에는 Harbor adapter, 실제 task container에 연결되는 remote SSH 경로, 결과 보존과 오류를 분모에서 빼지 않는 aggregate가 있다. 그러나 이 수정 SHA에 연결된 task verifier 결과는 없다. GPU를 제외한 실행, fixture 검사, provider smoke를 전체 benchmark 성공으로 승격하면 안 된다. 정확한 binary/dataset/provider/arm/environment와 원본 trial verdict를 묶은 실행은 #37202의 남은 작업이다.
