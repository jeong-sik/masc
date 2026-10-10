# 2026-10-10 MASC 기능 매트릭스

이 문서는 MASC 주요 기능이 지금 제대로 이어지는지 영역별로 정리한 표예요.
기준은 감사 시작 커밋 `d7fc5a7fec`이고, 문서를 올린 시점의 `origin/main`은 `08b40c12bf`예요.
코드를 읽기만 했어요. 빌드, 테스트, 라이브 설정, 로그는 보지 않았어요.
판정은 영역별 감사 에이전트의 보고를 따랐고, CX-01, W1의 계산 위치, E-01, E-02, LB 상수 위치만 직접 다시 확인했어요.
나머지는 다시 확인하지 않았어요.

## 판정 기준

| 판정 | 뜻 |
|---|---|
| 확인됨 | 정상 경로가 끝까지 이어지고, 결함을 찾지 못함 |
| 부분 | 이어지지만 결함이나 빈틈이 있음 |
| 결함 | 정상 경로나 마무리 처리가 깨져 있음 |
| 미확인 | 깊이 보지 못함 |
| 없음 / 설계상 없음 | 코드에 구현이 없음. 설계 문서에서 일부러 뺀 경우는 "설계상 없음" |

## 기능별 판정

| 기능 | 판정 | 근거 (ID) | 비고 |
|---|---|---|---|
| Runtime failover | 부분 | F-1 P1(효과 펜스가 걸려서 다음 후보로 못 넘어감), F-2, F-3, F-4 | hard quota는 다른 후보가 있을 때만 다음 후보로 넘어감. 후보 수는 라이브 설정이라 확인 못 함 |
| Keeper context 생명주기 | 결함 | CX-01 P1(매 턴 history_restarted 기록), CX-02, CX-04, CX-05 | 정상 동작 확인: WAL compaction, owner outbox sweep, 버전 컷, snapshot 상한 12 |
| Event queue / drain | 결함 | CX-07, W4(호출하는 곳 없음) | 켜지지 않은 Keeper의 pending이 닫히지 않음 |
| Librarian | 부분 | LB-01 P1(32KB를 넘으면 패스 전체가 실패하고 깨울 때마다 반복), LB-02, LB-03, LB-09, LB-10 | 10-07 감사의 F-02, D3-02는 해결됨 |
| World Curator | 부분 | LB-04, LB-05, LB-06, E-17 | 분류가 매번 전체 백로그에서 시작함. CLI 슬롯이 탈락했다는 기억이 없음 |
| Memory 생산·소거·흡수 | 결함 | M-1~M-4 P1, M-5~M-10 | 스택 #41916이 M-2, M-4, M-7을 메우는지는 확인 못 함 |
| Memory 강화(reinforcement) | 설계상 없음 | M-15 | RFC-0418에서 일부러 뺌 |
| Skills 자동 재생성 | 없음 | 코드 검색 결과 0건 | 수동 publish만 있음. 프롬프트 한 문단(`keeper.md:58`)이 전부 |
| Skills 카탈로그·Task pin | 결함 | S-1 P1 | Skill을 수정하거나 지우면, 그 Skill을 pin한 Task의 Keeper가 매 턴 setup에서 실패함 |
| Board / 후보 원장 | 부분 | BOARD-1 P1(못 읽는 행이 하나라도 있으면 prune이 영구히 멈춤. 열린 #38068이 같은 뿌리를 다룸), BOARD-2 | #41506이 consumed 행은 지움 |
| Task FSM | 확인됨 | 전이를 모두 명시함 | |
| Goal | 부분 | GOAL-1 P3(refuted 뒤 순환을 끝내는 규칙이 없음. keeper가 매번 다시 요청해야만 도는 경로라서 관측되기 전까지는 잠복 결함) | FSM 전이 쌍은 모두 명시되어 있어 확인됨. 같은 결함을 닫힌 #31244가 "관측 없음, 잠복"으로 닫음 |
| HITL | 부분 | HITL-1, HITL-2 | 늦게 온 승인을 메모리에만 기억함 |
| Access Control | 미확인 | 범위를 확인한 뒤 별도로 기록 | 이 문서에는 상세를 싣지 않음 |
| Multi Lane | 부분 | LANE-1(거절 원인이 2초 뒤에 사라짐), LANE-2(미확인) | lane action이 재시작 때 닫히는 것은 확인됨 |
| Schedule | 결함 | SCH-1 P1(반복 스케줄이 terminal 거절 한 번에 영구 Failed), SCH-2, SCH-3, SCH-4 | |
| Candle 원장 | 부분 | E-01 P1(수신자가 있는지 검증하지 않음), E-02 P1(Disabled 중에 지급하면 소실. 열린 #41322이 같은 결함), E-04 | 잔액 보존식은 유지됨 |
| 반감기·분배 산식 | 확인됨 | 결함을 찾지 못함 | |
| 논공행상 | 부분 | E-09(Goal당 1회만 지급. 의도인지 확인 못 함) | |
| Item Slot / Portrait | 미확인 | P3: 아이템을 늘리면 모든 keeper의 기본 외모가 바뀜 | 깊이 보지 못함 |
| Play Invite | 부분 | E-15(링크가 127.0.0.1로 나옴. 이전 감사의 F3), DOS 컨트롤러가 Crashed일 때 해제되는지는 미확인 | 철회·만료 때 해제되는 것은 확인됨. #41612 스택은 보지 않음 |
| TUI 연결·가시성 | 부분 | LANE-1, SCH-6, E-04(Rejected가 안 보임), TUI-1(`*_error`가 약 50개) | |
| 토큰·캐시 | 부분 | W1 P1, W3, W5, W7, W8 | 접두 캐시와 keeper_tool_search는 문제 없음 |

## P1 목록 (13건)

크기는 읽고 어림잡은 값이에요. 측정한 값이 아니에요.

| ID | 한 줄 | 크기(추정) | 기록 |
|---|---|---|---|
| CX-01 | 공식 클라이언트 Keeper가 매 턴 history_restarted를 기록함 | 작음(조건 하나) | PR #42206 |
| W1 | Codex, Claude Code가 매 턴 이력 전체를 직렬화하고 SHA256을 계산함. 읽는 곳이 있는지 불확실 | 작음(호출 지점부터 확인) | #42210 |
| SCH-1 | 반복 스케줄이 terminal 거절 한 번에 영구히 멈춤 | 중간 | #42209 |
| BOARD-1 | rejected_rows가 0보다 크면 prune과 compaction이 영구히 멈춤 | 중간 | #38068(기존) |
| LB-01 | absorb gate가 32KB를 넘으면 패스 전체가 실패하고, 깨울 때마다 반복됨 | 중간 | #42211 |
| E-01 | 선물 수신자가 있는지 검증하지 않아 돈이 사라짐 | 작음 | PR #42207 |
| E-02 | Disabled 중에 Goal을 통과하면 지급이 영구히 사라짐(warn만 남기고 Ok) | 중간 | #41322(기존) |
| F-1 | claude_code 펜스가 spawn 시점에 걸려서 다음 후보로 못 넘어감 | 중간 | #42212 |
| M-1 | quarantine가 receipt를 전부 지워서 explicit-write 큐가 영구히 멈춤 | 중간 | #42213 |
| M-2 | 철회한 주장이 다시 살아남 | 중간 | #42214 |
| M-3 | write 도구가 lane이 꺼진 채로 ok:true를 돌려주고, 큐 상한이 없음 | 작음~중간 | #42215 |
| M-4 | 후보 reason을 파싱만 하고 쓰지 않음. not_durable write가 기록 없이 사라짐 | 중간 | #42216 |
| S-1 | Skill을 수정하거나 지우면 pin한 Task의 Keeper가 매 턴 실패함 | 작음 | PR #42208 |

## 공통 주제

1. 상한 없이 전체를 읽고 직렬화함: W1, CX-02, CX-04, CX-05, LB-09, LB-10, LB-11, M-8, S-5, E-(원장 전체 재검증).
2. 경고만 남기고 Ok로 넘겨서 손실이 조용함: E-02, M-4, SCH-1(영구 Failed), BOARD-2(창 밖 재게시).
3. 같은 규칙이 여러 곳에 중복됨: F-5(5곳), E-07(keeper 판정 3곳), 의미 판단 경로가 둘(#42055와 keeper_memory_select), journal 골격 307줄과 466줄.
4. 호출하는 곳이나 만드는 곳이 없음: W4(CX-07과 같은 건), SCH-3, CX-13, CX-14, S-7, M-11, M-12, TUI-3.
5. 오류 표시가 다음 갱신에 사라짐: LANE-1, SCH-6, TUI-1.

## 스택 리뷰 요약

- #41731(스택 35): 방향은 맞음. 층 구성을 다시 잡아야 함. #41793에 133개 파일이 섞여 있음. model_signal이 4개 층에 증상별로 나뉘어 고쳐져 있음. #41710은 제외. main에서 분해한 코드 위로 다시 쌓아야 함.
- #41916(스택 48): Memory 갈래는 방향이 맞음. Codex context 갈래(#42109~#42168)는 중단을 권장함. 의미 판단 경로를 하나로 합쳐야 함. 고치는 층은 부모 층에 합쳐야 함. #42020은 큐 파일 스키마에 결함이 있음.

## 스택과 겹치는 파일

수리 PR이 아래 영역을 건드리면 진행 중인 스택과 충돌해요.

- #41731 영역: `bin/masc_tui_keeper_chat_transcript.ml`, `masc_tui_render_chat.ml`, `keeper_codex_runtime.ml`, `keeper_claude_code_runtime.ml`, `runtime_codex_app_server.ml`. W1과 F-1이 여기를 건드림.
- #41916 영역: Memory OS 전반. M-1~M-4, M-7이 여기에 해당함.

## ID 규칙

ID 앞의 글자는 어느 영역 감사에서 나온 항목인지 알려줘요. 번호는 그 영역 보고서 안의 순번이에요.
P1, P2, P3는 보고서가 붙인 심각도예요. P1이 가장 높아요.

| 접두 | 영역 | 감사 보고서 |
|---|---|---|
| F | Runtime failover | audit-failover |
| LB | Librarian, World Curator | audit-librarian |
| CX | Keeper context, Event queue | audit-context |
| M | Memory | audit-memory |
| S | Skills | audit-memory |
| E | Candle 경제, Play Invite | audit-economy |
| SCH, GOAL, BOARD, HITL, LANE, TUI | 핵심 기능 연결과 TUI 가시성 | audit-tui-core |
| W | 토큰, 캐시, 낭비 | audit-waste |

- W4와 CX-07은 같은 문제를 가리켜요.
- 영역별 보고서와 스택 리뷰(#41731, #41916) 원문은 이 문서에 싣지 않았어요.
