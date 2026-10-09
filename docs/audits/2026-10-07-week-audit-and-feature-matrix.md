# 2026-10-07 주간 감사 — 기능 매트릭스와 결함

기간: 2026-09-30 ~ 2026-10-07. 커밋 1,248개(09-30 255, 10-01 406, 10-02 170, 10-03 58, 10-04 136, 10-05 23, 10-06 190, 10-07 9).
기준 코드: `7fb34c7172`(라이브 서버와 같은 커밋). 라이브 자료: `~/me/.masc`(읽기만 함).
기준선: [10-01 주간 감사](2026-10-01-week-audit-and-feature-matrix.md). 아래 판정은 그 대비 "고쳐짐 / 그대로 / 나빠짐 / 새로 생김"이에요.

판정 방법:
- 영역 감사 8개(런타임, Keeper context, Librarian·Memory·Skills, Candle 계열, 턴당 context 크기, Board·Task·Goal·HITL·권한·Schedule, TUI, Glossary·결합도)가 코드를 읽고 라이브 숫자를 셌어요.
- 고치기 전에 모든 항목을 이 세션이 코드에서 다시 확인했어요. 하위 감사 제안 중 4건은 확인해 보니 틀려서 버렸어요(맨 아래 "버린 것").
- 영역별 원문: [2026-10-07-week-audit/](2026-10-07-week-audit/) (A 런타임, B context, C Librarian·Memory·Skills, D Candle 계열, E context 크기, F Task·Goal·HITL·Schedule, H Glossary·결합도). Board·권한·TUI 는 하위 감사 결과를 이 문서에 바로 옮겼어요. 원문의 판정과 이 문서가 다르면 이 문서가 맞아요.

## 1. 요약

가장 큰 문제 다섯 가지예요.

1. **checkpoint 저장이 하루 약 2.4TB 를 써요.** tool 라운드마다 checkpoint 전체(최대 85MB)를 세 번 다시 써요. 10-07 01:37~04:40 사이 7,781번, 297GB. 이슈 #36690(09-15, must-do)이 3주째 열려 있어요.
2. **Librarian 이 밀리면 Keeper context 를 아무것도 묶지 않아요.** 선언한 한도(`context_marks`)로 자르는 코드는 `continuity` 가 없을 때만 돌아요. session 이 있는 보통 턴은 늘 `continuity` 가 있어요. sangsu 한 Keeper 가 15시간 동안 턴마다 최대 3.43MB(1M 창의 90%)를 보냈고, 10-06 하루 입력 토큰 2.77억(Fleet 의 19%)을 썼어요.
3. **쉼 기록이 프로세스 메모리에만 있어요.** 10-05~06 사이 서버가 12번 부팅했고, 부팅마다 "이 계정은 다 썼다"는 기록이 사라져요. Librarian 은 쿼터가 막힌 Claude 를 10-05 하루 1,265번 다시 불렀어요. 쉼을 쓰는 곳이 다섯 군데, 순서 규칙이 세 벌이에요.
4. **Keeper 가 운영자 전용 도구를 부를 수 있었어요.** 도구 권한 기준표는 `masc_gc`·`masc_board_cleanup` 을 `CanAdmin` 으로 두지만 Keeper 실행 경로는 그 권한을 읽지 않아요. 09-20 Keeper 호출 한 번이 메시지 3,462개를 지웠어요. → PR #41421.
5. **새로 들어온 기억 다이제스트(#41389)가 임의의 6%를 매 턴 보내요.** 주장 492개 중 해시 순서로 앞의 34개(8KB)만 모든 Keeper 의 매 턴에 실려요. 세 감사(B·C·E)가 따로 같은 결론을 냈어요.

이번 세션에서 한 일은 7절, 운영자가 정할 것은 8절이에요.

## 2. 일자별 변경 흐름

| 날짜 | 흐름 |
|---|---|
| 09-30 | Candle 지급 사슬이 들어옴(on/off #39928, Snapshot #39978, PayoutOwed #39979). native resume 이 같은 context 를 다시 보내지 않음(#39972). Librarian 변화 없는 회차는 snapshot 유지(#40001). 여러 계정이 model set 을 나눠 씀(#40096) |
| 10-01 | 가장 많은 날(406). recall 을 필요할 때 찾는 방식으로 바꿈(#40473) — 턴마다 140~450KB 가 0.7KB 안내문이 됨. Item 구매·착용(#40365·#40010), 반감기 정책(#40392). 한 provider 쿼터로 lane 전체가 멈추지 않게 함(#40503). TUI 수정 75건 |
| 10-02 | recall 검색 우선, 대량 fallback 제거(#40782). Candle closed variant·영구 실패 분류(#40595·#40581). exact lane backpressure 귀속(#40742) |
| 10-03 | 스택 rebase 위주. provider admission 선언 충돌 거절(#40802), 모르는 capability key 거절(#40926) |
| 10-04 | 조용히 무시되던 provider 필드 거절(#41048). Librarian 이 기억 분류를 만듦(#40744), Jev 변화 없음 사전검사(#40758). Candle 등급·분배 정책 설정(#40848) |
| 10-05 | `max-prompt-bytes` 제거, 시작 상한을 창에서 계산 |
| 10-06 | 판정 lane 우선순위(#41316·#41332). 턴 간 반복 감지를 호출 원장에서 seed(#41234). Candle 켜짐(16:23 KST), 운영자 지급 CLI(#41371). curator lane 이 glm 으로 살아남(15:16Z) |
| 10-07 | 끊긴 실행 비용 정산(#41383·#41387·#41400). 기억 브리핑에 주장 다이제스트(#41389) |

## 3. 기능 매트릭스

판정: **동작** = 기본 흐름과 흔한 예외가 맞음 / **일부** = 기본 흐름은 돌지만 구멍이 있음 / **깨짐** = 기본 흐름이 틀림 / **없음** = 코드가 없음.

| 기능 | 판정 | 10-01 대비 | 근거 |
|---|---|---|---|
| Runtime 실패 분류 | 동작 | 그대로 | status·typed 오류만 읽어요. 문장 분류는 표시용에만 남음(`retry.ml:327-361`) |
| Runtime Failover (후보 걷기) | 일부 | 그대로 | 쉼 기록이 메모리에만 있어 부팅마다 사라짐(`runtime_quota_window.ml:23-25`). 힌트 없는 429(Ollama 세션 한도)는 사용량을 읽지 않고 60초마다 같은 계정을 다시 부름. 배정 29명 중 11명은 후보가 하나 |
| Multi Lane / exact lane | 일부 | 조금 나아짐 | verifier 는 HTTP 2 + CLI 5 로 늘었음. HTTP slot·CLI 꼬리는 쉬는 후보를 순서만 바꿔 계속 부름(D1-01·L2-04). HITL 판정·Board attention 은 slot 하나 |
| Provider admission | 동작 | 새로 생김 | 판정 lane 우선 permit. 새 구멍 못 찾음(추적 중 PR 제외) |
| Keeper 한 명의 context 생명주기 | 일부 | 조금 나아짐 | 턴 종료 이유는 closed variant 로 모두 기록. 끝나지 않은 턴은 경계 줄이 없음(#41378). continuity snapshot 거절은 고쳐짐(D2-01) |
| Runtime 을 넘지 않는 순환 | 깨짐(조건부) | 나빠짐 | 선언 한도가 보통 턴에서 돌지 않음(1절 2번). 공식 클라이언트는 typed overflow 에 반으로 줄임 |
| Checkpoint 저장 | 깨짐(자원) | 나빠짐 | 3시간 297GB(1절 1번). #36690 |
| 반복 감지 (턴 안) | 일부 | 그대로 | 매번 바뀌는 영수증을 못 잡음(#41393·#41398 열림) |
| 반복 감지 (턴 사이) | 깨짐 | 새로 생김 | #41234 의 seed 가 첫 반복 정지 뒤 비거나 이미 판정한 줄을 남김(B-01) |
| Librarian | 일부 | 그대로 | 회차마다 facts 전체를 보냄(p50 170~223KB, 24시간 654MB). 66% 가 변화 없는 회차. Jev 사전검사는 533건 중 406건이 `max_tokens_exceeded`(#41365·#41388) |
| Memory 생산·합성·흡수·소거 | 일부 | 조금 나아짐 | 모두 라이브로 돎. 흡수는 09-30 아침 0건에서 하루 54~116건으로 돌아왔지만 이전(372~589)보다 적음 — Librarian 회차가 줄어든 만큼. 같은 주장 반복 쓰기(sangsu 하루 157번, #41390) |
| Memory 감쇠·강화 | 없음 | 그대로 | RFC-0418(Draft)이 reinforcement 카운터를 걷어내고 강도 감쇠 상수를 두지 않기로 함. 헌법에는 Memory 규칙이 없음. 설계 선택 |
| 공유 기억 브리핑 다이제스트 | 일부 | 새로 생김 | 1절 5번 |
| World (Workspace) Curator | 일부 | 나아짐 | 10-06 15:16Z 부터 glm 으로 돎(10-07 28회 중 23회 성공). 입력의 97% 가 이웃 facts. 밀린 일 4,439건, 1.5~2일이면 비움 |
| Skills 발행 | 일부 | 그대로 | Keeper 가 이번 주 5개 발행. 기본 Skill 2개가 저장소보다 낡음. 발행 근거 파일 없음(D4-07) |
| Skills 재생성 | 없음 | 그대로 | 되풀이된 풀이를 알아보는 코드가 없음. 프롬프트 한 문단과 발행 도구뿐 |
| Task | 일부 | 나아짐 | 상태 전이는 모든 경우를 적은 `decide`. 검증 대기 0건(10-01 은 35건). GC 를 부르는 일정이 없어 09-20 뒤 안 돎 — `backlog.json` 4.2MB 의 95% 가 끝난 Task. 10-06 손 정리 440건이 건마다 파일 전체를 다시 씀(약 3.7GB) |
| Task 검증 | 일부 | 나아짐 | 10-06 판정 69건. 10-03 은 137번 시도에 판정 0건, 10-04 는 slot 68.6시간을 헛씀(퇴역 모델·쿼터 다 쓴 claude_code 를 계속 부름). 지금은 운영자가 설정을 바꿔 깨끗함. 실행 기록에 마지막 후보의 오류만 남음 |
| Goal | 일부 | 나아짐 | 29개(진행 11, 완료 6, 취소 12, 검증 중 0). 상태 전이 표는 모든 경우를 적었지만 `Executing -> Verifying` 한 경로는 표를 거치지 않고 레코드를 직접 고침(F-07, `workspace_goals.ml:705-713`, 고치는 PR 은 #41455). 기한 지난 진행 Goal 3개를 아무에게도 알리지 않음(#39975 뒤 알림 없음). Goal 확정이 Goal lock 을 잡은 채 Candle 지급 줄을 써서, Candle 쓰기 실패가 확정을 막음 |
| Goal 알림 | 동작 | 고쳐짐 | 10-04~06 사이 34.5시간 막혔던 것을 #41237 이 고침 |
| HITL (Gate 승인) | 알 수 없음 | 그대로 | 라이브가 09-23 부터 `always_allow` 라 Manual·Auto Judge 경로는 라이브에서 돈 적 없음. 승인 큐 분리(5,152 → 3,182줄)는 동작을 잃지 않음(함수 210개 중 209개 그대로, 옮긴 77개 본문 동일) |
| Schedule | 일부 | 조금 나아짐 | 10-06 발화 570건, 실패 0. 꺼져 있던 동안 놓친 발화는 한 번만. stub 이던 `resolve_keeper_wake_target` 은 고쳐짐(D5-11). TUI·대시보드 수정이 결과 전달을 지움(D5-10) → #41430. `schedules.json` 4.1MB 중 살아 있는 일정 53/655, 메모가 56% |
| Board | 일부 | 그대로 | 글 하나만 바뀌어도 posts(8.7MB)·comments(21MB) 전체를 다시 씀(D12-05). 목록 캐시는 고쳐짐(D12-01) |
| Board attention | 일부 | 지연은 나아짐 | 처리 p50 0.53초(10-01 중앙값 12.9시간). 원장이 처리 끝난 후보를 안 지워 623MB, 하루 +53MB(#41422). 모델 답 형식 오류가 사람이 풀 때까지 격리(10-06 LLM 회차의 7%) |
| Access Control | 일부 | 나아짐 | 만료 규칙 하나로 통일(D7-05 고쳐짐). Keeper 의 관리자 도구 호출(W1-01) → #41421. 질문 답변 route 가 Worker 권한(D7-03) |
| Candle 원장 | 일부 | 켜짐 | 10-06 부터 라이브. 31줄(지급 28, 반감기 설정 1, 구매 1, 착용 1). 감정·분배는 켜진 뒤 확정된 Goal 이 없어 한 번도 안 돎. 운영자 CLI 가 원장 파일을 직접 써서 35분간 읽기 실패(D-F1) |
| 논공행상 분배 | 동작(코드) | 그대로 | 합이 총액과 같고 중복 이름 거절. 라이브 실행 0회 |
| 반감기 | 동작(코드) | 새로 생김 | 시각에서 계산하는 projection 이라 재시작에도 한 번만 적용(D8-09 고쳐짐). 라이브 설정은 꺼짐 |
| Item 슬롯·구매·착용 | 일부 | 새로 생김 | item id·slot 이 variant. 잔액·상점·착용은 감정 lane 이 살아 있어야 열리고, 지급은 안 그럼 — 읽는 곳마다 기준이 셋(D-F4) |
| Portrait | 일부 | 그대로 | D9-01·D9-02·D9-05 그대로 |
| Play Invite | 일부 | 그대로 | 서버가 `MASC_HTTP_BASE_URL` 을 스스로 채워 링크가 127.0.0.1 로 나감(D10-01). TUI 거절 이유 → #41427 |
| Economy (토큰 집계) | 일부 | 그대로 | exact lane 실행 기록 5,185건 모두 토큰 사용량이 없음 — Librarian 비용이 집계에서 빠짐(L1-04) |
| Drain queue | 일부 | 그대로 | 크기는 모두 묶여 있음. 큐 상태의 옛 줄(D5-03, #40074), 회차 영수증(D5-04), schedule 신호 28MB(D5-06)를 지우는 코드가 없음 |
| TUI 배선 | 일부 | 그대로 | 대조한 경로는 모두 서버 route 에 닿음. Gate 화면이 Auto Judge 판단 근거를 안 읽음(G-W1). Goals 합계가 Pause·Block 을 뺌. 첫 화면 이름이 셋(Overview·Dashboard·Home) |
| Terminal-Bench 4.0 | 일부 | 그대로 | 하네스(harbor 0.23.0, 4.0.0 태스크)는 있음. 마지막 실행 09-24, 그 뒤 head 로 돌린 기록 0건 |


## 4. 시간축으로 본 열린 고리

틱(tick)을 N 번 돌렸을 때 상태가 닫히는지(묶이고 정리됨) 열리는지(계속 늘거나 새거나 같은 일을 반복) 봤어요.

| 고리 | 1틱 | N틱 | 판정 |
|---|---|---|---|
| checkpoint 저장 | tool 라운드마다 전체 파일을 3번 씀 | 파일은 Keeper 수명만큼 자라고, 쓰는 양은 그 크기 × 라운드 수 | 열림 |
| Librarian 이 밀릴 때의 context | 이번 턴 range 를 그대로 보냄 | Librarian 이 다시 나아갈 때까지 턴마다 창을 채워 보냄 | 열림 |
| 쉼 기록 | 403 을 읽어 reset 까지 쉼 | 부팅하면 잊고, 다른 걷기(vision·exact·CLI 꼬리)는 처음부터 배우지 않음 | 열림 |
| 힌트 없는 429 | 60초 뒤 같은 계정 | reset 까지 60초마다 반복, 같은 계정을 쓰는 소비자 수만큼 곱해짐 | 묶였지만 눈먼 반복 |
| Board attention 원장 | 후보가 Consumed 로 남음 | 하루 +53MB, 힙 캐시와 정렬 비용이 같이 늘어남 | 열림 |
| 턴 사이 반복 seed | 첫 정지까지는 맞음 | 원장 창(200줄)이 차면 seed 가 비어 다시 못 잡음 | 열림 |
| 기억 다이제스트 | 해시 순서 앞 34개 | 새 주장은 해시가 앞이 아니면 영영 안 보임 | 닫혔지만 고정된 편향 |
| Memory 저장소 | 회차마다 facts 전체 전송 | 큰 Keeper 셋은 09-30 부터 크기가 평평(최대 512KiB 의 77%) | 닫힘 |
| Board attention 처리 지연 | 후보 → Jev → 끝 | p50 0.53초로 유지 | 닫힘 |

## 5. 토큰·캐시·context 낭비 (10-06 측정)

- Fleet Keeper 요청 입력 14.5억 토큰, 그중 95.2% 가 캐시 읽기예요. 캐시는 잘 맞아요. 따뜻한 요청은 114.6K 토큰 중 1.7K 만 캐시 밖이에요.
- 보통 요청의 약 70% 가 시스템 프롬프트와 도구 스키마(93KB)예요. 도구 스키마만 74.6KB 예요.
- 줄일 수 있는 것:
  - 기억 다이제스트 8KB × 모든 Keeper × 매 턴 → 하루 약 2,800만 토큰(대부분 캐시).
  - Skill 목록이 `keeper_skill` 스키마에 통째로 들어감(13.7~18.8KB, 6일간 안 열린 Skill 5개).
  - Candle 도구 4개가 미뤄 읽기(defer) 없이 매 요청 약 1.6KB.
  - Librarian 회차마다 facts 전체(p50 170KB+), 변화 없는 회차가 66%.
  - curator 입력의 97% 가 이웃 facts(30개씩).
- 공식 클라이언트(Claude Code) Keeper 는 155~244개 도구를 받지만 CLI 가 쓸 때만 스키마를 읽어 추가 토큰은 없어요.

## 6. Glossary 와 결합도

### Glossary

- 크기가 계속 커져요. 246KB·208항목(10-01) → 297KB·236항목(10-07), 이번 주 커밋 53개, 하루 약 +8.8KB. 한 번 읽는 데 약 7~9만 토큰(추정, 토크나이저로 재지 않음). `## Core` 하나가 144KB 예요.
- 코드 이름 1,566개 중 7개가 코드에 없어요. 그중 사실이 틀린 것(Candle 사건 9종 → 10종, `Half_life_set`, `Requeued`)은 #41432 에서 고쳤어요. 나머지는 구현된 적 없는 Draft RFC 의 이름이에요.
- 대소문자만 다른 두 항목이 있어요: "Lane Activity"(DOS 기계 동작 피드)와 "Lane activity"(활성화 플래그, #41352).
- 코드에서 같은 것으로 확인된 중복 개념: Runtime Attempt = provider attempt, Librarian Round = Librarian Pass, Assignee = Producer = worker. `working_context` 와 Claim 은 각각 뜻이 셋이에요. "Lane" 이 들어간 항목 제목이 15개(10-06 에 4개 추가)예요.
- 어려운 말: 사정, 걸음, 씨앗(Seed), 파견, 판독, 결말 등 15곳. 원장은 51줄에서 영어 없이 쓰여요.
- 제안: 한 줄 색인(약 1.2만 토큰) + 도메인별 파일. 불변식과 PR 번호는 `.mli` 로 옮겨요.

중복 정리·문장 다듬기·구조 RFC 는 Keeper `polisher` 에게 맡겼어요(`glossary-maniac` 은 운영자가 멈춰 둔 상태). 원문: [H-glossary-coupling.md](2026-10-07-week-audit/H-glossary-coupling.md).

### 결합도

| 경계 | 무엇 | 필요한가 |
|---|---|---|
| H-04 | `candle_store` 가 경로 함수 하나 때문에 `masc_workspace` 전체를 링크 | 아니요. `masc_core` 의 `Common.masc_dir_from_base_path` 가 같은 경로를 줌 |
| H-05 | 서버의 lane add-on 샘플링이 `Keeper_turn_driver.assignment_walk_order` 를 부름 | 아니요. Runtime 상태만 읽으니 `lib/runtime` 으로 옮길 수 있음 |
| H-06 | `lib/runtime` 이 윗층의 `Keeper_runtime_failure_route` 를 부름 | 아니요. 아래층이 위층을 아는 역방향 |
| H-07 | 턴 안 반복 감지가 SQLite 호출 원장 색인에 기댐. 색인이 없으면 경고 없이 빈 결과 | 줄일 수 있음. 턴이 자기 지문을 checkpoint 에 들고 다니면 됨. B-01 도 이 결합에서 나옴 |
| H-08 | TUI 클라이언트가 `masc` 전체를 링크하고, 디코더가 상수 몇 개 때문에 Keeper runtime 모듈을 부름 | 아니요. wire 상수를 작은 라이브러리로 |
| H-09 | Keeper registry 가 Librarian 을 직접 부름 | 아니요. 이 선이 Keeper 라이브러리 분리를 막음 |
| F | Goal 확정이 Goal lock 을 잡은 채 Candle 지급 줄을 씀 | 아니요. 8절 11번 |

Keeper 는 여전히 `masc` 라이브러리 안의 557파일·23만 줄이에요. 떼어 낼 순서 제안: (0) meta·registry 바닥층의 윗방향 선부터 끊기 → (1) Board attention + exact lane 묶음(9.3k줄, 바깥 인터페이스 모듈 4개) → (2) 공식 클라이언트 runtime → (3) Librarian + Memory OS.

## 7. 이번 세션에서 한 일

PR(모두 Draft, base main):
- #41421 Keeper 가 `masc_gc`·`masc_board_cleanup` 을 부르지 못하게 함. Keeper 에게 보이는 도구가 Worker 권한 안에 있는지 확인하는 테스트 추가(일부러 되돌려 실패 확인).
- #41426 아무도 부르지 않는 `drain_board_all`·`is_board_signal` 삭제.
- #41427 TUI 가 Play 초대 거절 이유를 서버가 쓰는 `error` 칸에서 읽음. 테스트 입력을 서버 함수로 만듦.
- #41430 일정을 고쳐도 결과를 돌려줄 대화가 바뀌지 않음(D5-10). 수정이 저장된 전달 경로를 이어받음.

- #41432 Glossary 의 Candle 원장 사건을 10종으로 고치고, 코드에 없는 이름을 바로잡음.

#41421·#41427·#41430 은 고친 코드를 일부러 되돌려 새 테스트가 실패하는 것을 확인했어요. #41426 은 삭제만 해서 `rg` 0건과 `@check` 로 확인했어요.

2차(사용자가 "나머지 이상한 구현 해결함?"이라고 물은 뒤):
- #41455 Goal 증명 요청이 다음 상태를 상태 기계에서 받음. 손으로 적은 두 번째 규칙 제거, 거절 경로 테스트 추가(F-07, F-04).
- #41456 반복 감지 seed 준비가 Eio 취소를 삼키지 않음(B-03). 지워진 바이트 상한을 설명하던 주석 수정(B-04).
- #41457 Board 새 글 id 를 결과 문장 파싱 대신 typed 데이터에서 읽음. `post_id: "unknown"` 기본값 제거.
- #41459 Board flusher 시작 CAS 의 근거 없는 재시도 상한·백오프·테스트 뒷문 제거. 실패 뒤 되돌림이 물리 비교 때문에 한 번도 동작하지 않던 버그 수정(저장소 전체에서 같은 패턴은 이 한 곳).
- #41461 Candle 상점 목록 JSON 작성기 하나로 통일, `candle_store` 의 `masc_workspace` 의존 제거(D-F8, D-F9 = H-04).
- #41462 TUI Goals 합계에 멈춘·막힌 Goal 포함(B1).
- #41464 TUI Gate 화면이 Auto Judge 의 근거와 질문을 보여 줌(G-W1, P2).

3차(남은 TUI 죽은 코드, 워크어라운드 복사본, 실패 기록 표시):
- #41468 TUI 화면 목록에 Approvals 가 없는데 남아 있던 숨김 갈래·배지·경고색, 테스트만 부르던 `approvals_count_label`, 아무도 안 부르던 `approvals_human_pending` 삭제(A2).
- #41471 아무도 부르지 않는 TUI 함수 9개 삭제(A3, G-W5). 그 뒤 테스트만 남은 채팅 작업 다시 읽기 해석기(`decode_operation_reconciliation`)도 삭제. 커넥터 행의 `workspace_id` 읽기 제거(G-W6), 엉뚱한 자리의 주석 삭제(G-W7).
- #41473 Gate mode 를 `Keeper_gate_mode` 로 한 번만 읽고, 모르는 값은 세 화면이 서버 철자 그대로 보여 줌. 서버가 보내지 않는 `"workspace"` 갈래 제거(G-W2, G-W3).
- #41475 (#41459 위에 쌓음) Board 관련 여부 읽기의 즉시 3회 재시도와 테스트 뒷문 제거. 09-30~10-07 로그에서 재시도·포기 줄 0번(같은 기간 `board signal` 줄 하루 약 1,500개). 커서 스캔이 댓글까지 다시 읽어 배달하는 것을 코드와 기존 테스트로 확인.
- #41479 `/api/v1/runtime/resolved` 와 TUI Runtime 상세에 마지막 실패(종류, 시각, 기록한 Keeper)를 보여 줌. lane 걸음이 이 값으로 후보를 뒤로 미루는데 투영이 버리고 있었음.

4차(사용자 "지워"):
- #41485 (#41475 위에 쌓음) Board 읽기 전용 오류 타입 `board_read_error`. Board 읽기는 메모리만 봐서 `Io_error` 를 낼 수 없어요.
- #41486 (#41485 위에 쌓음) Keeper 의 Board 읽기 "일시 실패" 처리(intake 보류, 커서 스캔 정지, 밀어 주기 경고), `disposition` 타입, 테스트 뒷문 `force_transient_board_reads`, 그 뒷문으로만 돌던 테스트 5개 삭제. Keeper 코드에서 `Board.Io_error` 를 만드는 곳은 테스트 뒷문 두 개뿐이었고, 09-30~10-07 로그에 일시 실패 줄 0번.

5차(사용자 "불필요한 거 버려"): 운영 코드가 한 번도 만들지 않는 상태를 지웠어요. 기준은 "만드는 곳이 없으면 지우고, 바깥 입력(저장된 기록, 외부 프로토콜)이 보낼 수 있으면 남긴다"예요. 컴파일된 타입 트리(`.cmt`)에서 variant 생성자를 만드는 곳을 세는 도구로 후보 319개를 찾고, 하나씩 다시 확인한 뒤 지웠어요.
- 실제 버그 1건: #41562 `keeper_candle_gift` 가 MCP 와 tag 경로에서 실패. 세 곳 중 한 곳만 고쳐져 있었고, misc 도구 56개를 한 함수에서 전부 다루게 바꿈.
- 삭제 PR: #41534 #41535 #41538 #41540 #41541 #41543 #41544 #41545 #41547 #41548 #41549 #41551 #41552 #41553 #41554 #41559 #41563 #41564 #41566 #41567 #41569 #41570 #41571 #41575 #41576 #41577 #41578 #41580 #41581 #41585 #41586 #41587 #41588 #41593 #41597 #41598 #41599 #41600 #41601 #41602 #41603 #41605 #41606 #41607 #41608 #41609 #41610 #41613 #41616 #41617 #41618 #41619 #41621 #41625 #41628 #41629 #41630 #41631 #41632 #41634 #41635 #41639 #41644 #41646 #41648.
- 읽는 곳이 없는 필드 통째 삭제: 런타임 실패 경로의 `provenance`(#41602), fleet scan 의 `non_executable_cause`(#41608), 구독 저장소 전체(#41613).
- 빈 테스트: TOML 을 안 보고 OCaml 목록 둘만 비교하던 config category 테스트를 TOML 을 읽게 고침(#41585, TOML 값을 빼면 실패하는 것 확인). 없는 도구의 부재만 확인하던 테스트 2개 삭제(#41631).
- main 빌드 수정: #41520 이 #41583 뒤에 머지되며 `bin/masc_tui.ml:10935` 타입 검사가 깨짐 → #41643. #41520 의 `test_tui_home_queue_identity_pty.py` 는 main 꼬리말과 기대 문구가 달라 따로 실패.
- 이슈: #41627 `LockContention` 이 HTTP 400 으로 나감(`Masc_error.code` 는 503).

남은 TUI 문구(B3·B4·B5): "task owner without fiber N", "running X/Y" 와 "not running" 목록의 Failing 처리, Approvals 제목 수와 Home "need you" 수 차이. 다음 차례.

Keeper 가 올린 Glossary PR(`polisher`): #41435 DOS 피드 개명, #41437 Draft RFC 이름 제거, #41440 중복 개념 통일, #41446 어려운 말 15곳, #41449 RFC-0472 분할 제안.

이슈:
- #41422 Board attention 원장이 처리 끝난 후보를 안 지움(지워도 되는 근거 포함).
- #41428 Librarian 이 밀리면 Keeper context 를 묶는 것이 없음(E-01, D2-08).
- #41429 exact lane 실행 기록에 토큰 사용량이 없음(E-03 = 10-01 L1-04).
- #36690 에 checkpoint 쓰기량 측정값을 덧붙임.

Keeper 에게 맡긴 것:
- `tui-developer`: Gate 판단 근거 표시(G-W1), Goals 합계·죽은 TUI 코드, 헷갈리는 문구 3묶음. → 자기 task-2174 에 턴을 써서 손대지 못함. G-W1·B1 은 이 세션이 직접 고침(#41464, #41462), 죽은 TUI 코드와 Gate mode 는 3차에서 고침(#41468, #41471, #41473). 문구 3묶음(B3·B4·B5)은 남음.
- `e-masc-the-leader`: #41422 담당 지정 → task-2176.
- `sangsu`: 자기 PR #41234 의 턴 사이 반복 seed 결함(B-01). 원인 분석에 동의했고, 도구가 돌아오면 등록하겠다고 답함.
- `polisher`: Glossary 중복 개념 합치기, 어려운 말 15곳, 도메인별 파일 구조 RFC.

## 8. 운영자가 정할 것

| # | 무엇 | 선택지 | 근거 |
|---|---|---|---|
| 1 | checkpoint 저장 방식(#36690) | (a) 바뀐 부분만 덧붙이는 저장 (b) Librarian 위치 뒤의 atom 을 자동으로 잘라 파일을 작게 유지 (c) 당장은 큰 trace 를 purge runbook 으로 정리 | 하루 약 2.4TB 쓰기, 저장 한 번에 최대 1.4초 |
| 2 | Librarian 이 밀릴 때 context 를 누가 묶나(E-01) | (a) RFC #34180(context 초과 복구)의 만드는 쪽을 마저 붙임 (b) `recovery_view` 를 지우고 다른 경계를 정함 | 받는 쪽만 들어와 있고(`recovery_view` 는 테스트만 만듦), 그 빈 자리가 E-01 |
| 3 | 기억 다이제스트(#41389) | (a) 유지 (b) 읽는 Keeper 의 facts 와 묶인 주장만 (c) 빼고 개수 + 읽기 도구만 | 주장 6% 를 해시 순서로 고름 |
| 4 | 쉼 기록 | 계정 단위의 durable typed 저장소 하나로 모으고, 모든 걷기(Keeper·vision·exact·CLI 꼬리)가 같은 것을 읽게 | D1-01·D1-06·L2-04·A-01·A-02. 힌트 없는 429 에서도 사용량을 읽을지(10-01 D1-07 "설계대로" 재검토) |
| 5 | Play 초대 공개 주소(D10-01) | 초대 경로만 운영자가 넣은 값을 따로 읽음 | 기본값 `putenv` 를 지우면 loopback OAuth 동작이 바뀜 |
| 6 | Candle 지급 CLI(D-F1) | 서버만 원장을 쓰고 CLI 는 관리자 route 를 부름 | 배포 시점 차이로 35분간 잔액·구매·착용이 막힘 |
| 7 | `masc_board_delete` 를 Keeper 에게 열어 둘지 | 작성자 확인이 있어 #41421 에서는 남김. 영구 삭제를 관리자 등급으로 볼지 | 기준표 주석은 영구 삭제를 관리자 등급으로 봄 |
| 8 | Skills 재생성 | 반복 풀이를 알아보는 고리를 만들지, 문서에서 그 약속을 지울지 | 지금은 프롬프트 한 문단과 발행 도구뿐 |
| 9 | Terminal-Bench 4.0 head 실행 | docker 또는 modal 과 API 비용이 듦 | 2주째 head 기록 0건(#37202) |
| 10 | Task GC 를 누가 언제 부르나 | 정해진 주기로 돌리거나, 끝난 Task 를 저장 때 바로 archive 로 옮김 | 09-20 뒤 안 돎, `backlog.json` 의 95% 가 끝난 Task |
| 11 | Goal 확정과 Candle 지급의 결합 | Goal 확정은 먼저 끝내고, 지급 줄은 그 뒤 따로 씀(실패하면 다시 시도) | 지금은 Candle 쓰기 실패가 Goal 확정을 막음 |
| 12 | Candle 분배 대상이 한 명일 때 | 모델 호출 없이 그 한 명에게 전부(원장 `weights_trace` 에 "규칙으로 정함" variant 추가) | 지금은 결과가 정해진 질문을 모델에 하고, 0 을 답하면 지급이 거절됨(D-F6). 라이브 지급 줄 0개라 형식 변경 비용이 지금이 가장 작음 |
| 13 | 잔액 조회가 반감기 정책을 기록하는 구조 | 정책 사건은 설정 변경 경로가 쓰고, 잔액 도구는 읽기만 | 지금은 Keeper 의 `keeper_candle_balance` 가 쓰기 lock 을 잡고 정책 사건을 덧붙임(D-F5) |


5차 삭제 작업에서 나온 결정(바깥으로 나가는 출력이나 저장 형식이 바뀌어서 직접 하지 않음):

| # | 무엇 | 선택지 | 근거 |
|---|---|---|---|
| 14 | `lib/autonomous` 와 `/api/v1/autonomous/{phases,transitions}` | 라이브러리·경로·`specs/autonomous` 삭제 | #41617 뒤 남은 건 고정 목록 둘. 저장소 안에서 이 경로를 읽는 곳 없음 |
| 15 | Slack `record_gateway_event` | Discord 처럼 연결하거나, 카운터 선언까지 삭제(`/metrics` 의 0 시리즈가 사라짐) | 부르는 곳 0 |
| 16 | Keeper 상태의 `credential_archived` | 조건 칸·JSON 키·phase 계산·Mermaid 문구를 함께 삭제 | 이제 참이 될 수 없음. 대시보드 `keeper-composite.ts:88` 이 키를 읽음 |
| 17 | `Context_measured` 와 composite JSON 의 `measurement` 키 | 함께 삭제 | 만드는 곳 없음. 대시보드·TUI 해석기 확인 필요 |
| 18 | `reload_class` 를 `requires_restart` 하나로, 설명자 `sandbox` 를 `backend` 에서 계산 | 합치기 | 두 쌍 모두 늘 같은 짝으로만 나옴(#41618, #41646) |
| 19 | IDE `?kind=turn`, `staticArguments`, `implementationStatus` 키 | hard cut | 값이 늘 같거나 쓰는 곳 없음 |
| 20 | `Store.semantic_prepare`, `FileSystem.set_if_not_exists`·`extend_lock`, `validate_decision_transition` | 삭제 | 운영 호출 0. 앞의 것은 저장 형식과 얽힘 |
| 21 | span `masc.turn_type`, `Auth_error_kind.Invalid_json` | 삭제 | 앞의 것은 늘 `"direct"`, 뒤의 것은 TUI 만 읽음 |
| 22 | `keeper_decision_audit` 의 Mermaid 문구 | 지금 동작에 맞게 고침 | 지워진 `decide` 를 설명함 |
| 23 | `docs/KEEPER-SANDBOX-BOUNDARY-POLICY.md` 의 소스 경계 테스트 | 규칙을 다시 검사하게 만들거나 문서에서 지움 | 문서가 `test_keeper_sandbox_boundary_policy` 가 규칙 10여 개를 지킨다고 적었지만 그 테스트 파일이 없음 |

## 9. 버린 것 (확인해 보니 틀림)

| 제안 | 왜 틀렸나 |
|---|---|
| workspace secret·`initial_admin` 이 죽은 코드 | 새 workspace 의 첫 로그인(`prepare_login_auth`, `auth_credential_token.ml:418-433`)이 씀 |
| 판정 멈춤 알림에 `@<subject_owner_id>` 를 붙이면 된다 | `subject_owner_id` 는 Keeper 가 아니라 task id·goal id 를 돌려줌. 작성자 Keeper 는 따로 찾아야 함 |
| Codex host 정지가 `held_context:[]` 로 context 를 버린다(D2-04) | tool 경계에서는 Codex 가 압축했는지 알 수 없어 다시 보내는 게 안전하다는 주석이 있고, 압축 관측 경로도 같은 선택 |
| `sangsu` 의 파일 도구가 3턴째 주소 불명으로 죽는다 | 01:07 뒤 파일 도구 호출 기록이 없음. 04:34 Execute 한 번이 빈 인자로 거절됐고, Fleet 전체로 하루 12건 수준 |
