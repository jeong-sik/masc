# 예약 Job 행동별 최신 근거 — 2026-10-26

[최초 감사](2026-10-26-scheduled-job-behavior-audit.md)의 59개 행을 같은 순서로
다시 대조했다. 과거 실행 기록을 새 결과로 덮지 않고 이 표에 현재 판정과 한계를 적는다.
**전체 PASS가 아니다. F1 취소 잔류와 F6 busy 작업 조기 소비의 실제 반례는 보존한다. 수리와 새 실행의 범위는 해당 행에 따로 적는다.**

CI 근거는 **Test [40325758202](https://github.com/jeong-sik/masc/actions/runs/40325758202)**,
head `ae6cabc219bccb6eb57726d81c3f8cc99ba3e04e`, ref
`audit/scheduled-job-runtime-20261026`, conclusion **success**다.
실제 artifact의 195 OK/skip 0/fail 0과 원본/발췌 해시는
[완료 영수증](../evidence/2026-10-26-schedule-runtime-behavior/targeted-ci-after-restack-result.json)에 있다.
독립 source/raw 리뷰로 아래 case와 실제 실행 경계를 대조했다.

- W: `test_schedule_tool_wiring`, group `wiring` 52개, 생산 tool/service/store. HTTP 인증은 fixture.
- S: `test_schedule_store` 58개, 실제 filesystem/lock/encode. `state`, `due`, `lifecycle`, `corruption`은 로그 group이며 번호는 0부터 시작한다.
- R: `test_schedule_runner` 22개. 생산 tick/store지만 다수 consumer는 accepting fixture.
- C: `test_schedule_consumer_dispatch`, group `keeper_wake` 56개. 생산 runner/consumer/queue/reaction/dashboard. 모델 turn terminal 등은 fixture/직접 전이.
- L: `test_lane_addon_scheduled_act`, group `masc.lane_act` 7개. 생산 admission/queue/receipt지만 worker는 `Runtime.For_testing.with_backend`의 메모리 callback이다.

API33/F1/restart 상태23은 [실제 API bundle](../evidence/2026-10-26-schedule-runtime-behavior/README.md),
두 단독 모델 예와 F6는 [실제 모델 bundle](../evidence/2026-10-26-schedule-real-model-behavior/README.md)에
있다. 실제 바이너리 SHA는 각 run의 self-observed build에 결속된다. 성공 사례, 실패 반례,
함수 통합 검사와 모델 실행을 합산해 사용자 시나리오 수로 부르지 않는다.

| 행 | 사용자 행동 / 기대 | 실제 근거 | 현재 판정과 남은 한계 |
|---:|---|---|---|
| 1 | Keeper에게 단발 메시지를 예약한다 | W3, C3; API33 | 생성·저장·enqueue 및 실제 MCP 생성 통과. 실제 모델 단독 실행은 별도 두 예. |
| 2 | Lane installation/action을 예약한다 | W24, L0 | Lane 전용 shape·생산 admission/queue 통과. L의 worker는 대체 callback. |
| 3 | 제목·메시지·대상·알 수 없는 필드를 검증한다 | W17–24, W50, C48 | unknown/혼합 shape·대상·일부 타입 검증 실행. 모든 문자열 경계값 전수 검사는 아님. |
| 4 | 상대 지연을 생성 시점 기준으로 적용한다 | W44–45 | 생산 tool handler의 dispatch clock 기준 상대 지연·calendar first due 실행. |
| 5 | 과거·현재 초 경계 예약의 허용 여부가 일관된다 | W32–33, W46, S-state8; API33 | 과거 거절·현재 초·원래 overdue 시각 보존 실행. |
| 6 | one-shot 시각·ISO offset을 처리한다 | W15 | 생산 생성의 +09:00/−03:30·소수 초·잘못된 offset/civil date 실행. |
| 7 | interval·daily·cron을 반복한다 | W5, W45, S-due3–4, R-tick10–14 | interval tick·daily first due·cron reschedule 실행. 장기간 daily/cron loop 미검증. |
| 8 | cron 목록·범위·step·요일/날짜 조합을 해석한다 | Domain37의 request10–16; S-due4 | Test40365052184에서 기존 cron steps/ranges/lists·wildcard·불가능 날짜·장기 다음 날짜 case도 실행. 장기간 서버 반복 운용 증거와 구분. |
| 9 | 윤일·불가능한 날짜·장기간 다음 날짜를 구분한다 | Domain37의 request15–16; W15 | Test40365052184의 장기 다음 날짜·불가능한 calendar 거절 실행과 기존 civil-date admission 근거. 실제 서버 장기 운용은 미검증. |
| 10 | 시간대를 정한다 | Domain37의 request7–9; W15/W45/S-due4 | Test40365052184에서 fixed-offset 별명·명시 offset 허용과 DST/IANA 거절 정책 실행. DST 전환 지원을 제공한다는 뜻은 아니다. |
| 11 | runner tick보다 작은 interval을 생성·수정한다 | W43, R-tick14 | create sub-tick 거절과 저장된 값 처리 실행. update 동일 경계 독립 증거는 없음. |
| 12 | expires_at을 두고 예약한다 | S-due2, S-state16; restart-expiry-3 | 저장소 expiry와 실제 downtime expiry 실행. accepted source는 보존됨. |
| 13 | operator/creator/recipient가 수정·취소한다 | W37–41, C11; API33 | named 권한·직접 Operator_caller 취소 실행. HTTP credential→Operator 인증은 미검증. |
| 14 | 호출자가 임의 결과 채널을 주입한다 | W12–13/19, C4 | 신뢰 origin 결속·creator route 보존·queue 전달 실행. 외부 송신은 미검증. |
| 15 | public id를 유지하며 새 instance로 바꾼다 | W4–7, S-state4–7; API33 | public id 유지·fresh instance 및 terminal 변경 거절 실행. |
| 16 | 내용만 수정하면서 과거 due 시각을 보존한다 | W8–9/46, S-state8; API33 | due/recurrence/expiry 보존 및 명시 retime 경계 실행. |
| 17 | 동시 수정·retime가 저장 결과를 잃지 않는다 | W10 | 양쪽 timing 생략 content edit의 결정적 concurrent retime 보존 실행. 전 조합 보장 아님. |
| 18 | 권한 확인 사이 target이 바뀌면 이전 recipient 변경을 거절한다 | F3 소스 반례; 수리 PR46182 | locked current-row 권한 수리 PR46182의 새 Test124 통과. 공개 update interleaving/locked cancel 거절 포함; 실제 HTTP cancel race·새 binary는 미검증. |
| 19 | due만 바꿀 때 다른 호출이 갱신한 recurrence를 보존한다 | F4 소스 반례; 수리 PR46193 | 최신 recurrence 보존 수리와 공개 interleaving 2건 포함 Test40332170687의 115 cases 통과. 실제 HTTP race/새 binary 재현은 미검증. |
| 20 | A에 이미 대기 중인 반복 예약을 B로 바꾸고 취소한다 | retarget-cancel-4; 수리 PR46211 | 실제 F1 반례는 유지. all-owner 철회·transfer fencing 수리의 Test40343103111에서 3 suites 통과(명시 64+12=76 cases + queue executable). 새 binary 반례 재검증·강제 concurrent transfer는 미검증. |
| 21 | 아직 dispatch되지 않은 Scheduled/Due를 취소한다 | W3, S-lifecycle1, C10–11; API33 | 정의 및 current-target pending 취소 실행. 이전 target/instance 조합은 F1 실패. |
| 22 | 전달됐지만 아직 턴이 시작되지 않은 단발을 취소한다 | W34 | accepted one-shot Succeeded 뒤 cancel의 typed refusal 실행. 현행 기능 한계 유지. |
| 23 | 이미 시작한 작업·완료된 effect를 되돌린다 | S-lifecycle2, C12/14–15 | Running 거절·직접 turn-start/terminal 주입 경계 실행. 실제 effect rollback 보장 없음. |
| 24 | 상태·owner·target·limit/cursor로 페이지를 읽는다 | W35–36/47–50; API33 | owner/status/target/bounds/cursor filtering과 실제 MCP pagination 실행. |
| 25 | 빈 목록·부분 목록·조회 실패를 구분한다 | W26–27/36, S-corruption0 | 정상 부재·unknown/read error·부분 조회 실행. TUI retained async 오류 화면은 미검증. |
| 26 | 정확한 instance/occurrence·wake 이력을 읽는다 | S-due12/14, C8, W14; restart-expiry-3 | exact instance history·ID 재사용 분리·실제 재시작 history 보존 실행. |
| 27 | 최신 실패 사유·인계 owner·종단 결과를 읽는다 | C33–38/47 | 생산 dashboard의 실제 durable outbox/terminal/transfer projection 실행. 실제 모델 간 인계 아님. |
| 28 | 이후 도구 호출과 최종 산출물을 인과적으로 추적한다 | real model tool receipts | 단독 두 예와 busy 반례는 exact turn/tool/note 대조 가능. 일반 산출물 D4 durable causal join 보장 미검증. |
| 29 | note_add로 append하고 notes_list로 읽는다 | S-state0; API33; real-deepseek-1/real-glm-1 | 실제 MCP add/list 및 두 실제 Keeper의 자기 명의 note/readback 실행. 195 CI만의 증거와 구분. |
| 30 | 최신 N개 노트를 시간순으로 읽는다 | API33; W47는 bounds만 | 실제 최신 N window·오래된 순 반환 확인. 195개에서 별도 양성 window 검증은 없음. |
| 31 | terminal 정의의 노트를 유지한다 | S-state12; API33 | terminal append/정의·wake retention 뒤 note 보존 실행. 모든 terminal 상태 전수 검사 아님. |
| 32 | 동시 append·손상·읽기 오류를 처리한다 | S-state0–1, W0–1; API33 | 실제 동시 append·손상/read/write 실패와 두 MCP client append 실행. 모든 interleaving 보장 아님. |
| 33 | due가 되면 wake를 한 번 접수한다 | R-tick0/7–8, C3/28 | 신호 중복·생산 enqueue·offline 반복 tick single acceptance 실행. 모델 완료와 별개. |
| 34 | 접수 후 receipt 저장 실패에도 중복 효과를 피한다 | C23–27/30–31/41/54, L5 | acceptance/receipt 장애 뒤 같은 occurrence 재사용 실행. F5 settlement write 실패와 다름. |
| 35 | 한 예약 실패가 다른 due 예약을 막지 않는다 | R-tick17, C42 | fixture retry 격리와 실제 corrupt ledger의 다른 Keeper dispatch 격리 실행. |
| 36 | Keeper가 작업 중일 때 도착한 예약을 보존한다 | real-busy-deepseek-1; repair-validation 실제 두 모델 | 과거 F6 반례 유지. product94b2에서 DeepSeek/GLM의 checkpoint 보존·두 note·exact ACK 확인. DeepSeek observer의 overlap FAIL은 유지하며 원장으로 별도 대조. b5c976의 Owner103/3 실패는 보존하고 fixture 수리 ccb000의 Owner106 PASS와 구분. rebased6dedd 실행은 미검증. |
| 37 | paused Keeper에 도착해도 유실하지 않는다 | C11; retarget-cancel-4/restart-expiry-3 | 실제 pause·pending 보존 실행. Resume 후 모델 소비는 미검증. |
| 38 | owner가 꺼져 있어도 demand를 유지한다 | C28–29 | 등록됐으나 미시작 owner의 deferred/not_running·single acceptance 실행. Boot 후 모델 소비 미검증. |
| 39 | notice에서 busy/paused/offline 원인과 다음 행동을 안다 | C3/28/32는 backend reason만 | notice의 원인별 Resume/Boot 안내와 실제 사용자 조치는 여전히 공백. |
| 40 | 앞 회차가 미소비면 다음 회차를 보류한다 | R-tick19, C29/44; restart-expiry-3 | delivery=none의 previous occurrence hold·no dispatch·pending 보존 실행. |
| 41 | 지나간 모든 tick을 빠짐없이 실행한다 | R-tick13–14, C5–6, L1 | 정책별 supersede/hold/queue 차이 실행. 모든 missed tick 실행 보장은 없음. |
| 42 | 다른 입력의 busy를 이 예약의 실행 시작으로 오인하지 않는다 | C38, S-state10; 기존 decoder | 생산 stale identity 거절과 기존 TUI exact input 해석. 이번 CI는 TUI busy stage 전체 검사 아님. |
| 43 | 턴 시작·끝·ACK·durable 완료를 구분한다 | C34–37/12/14–15/54; 모델 실제 reaction ledger | 단독 두 예의 start/end/ACK/Completed 관측. F6는 checkpoint를 Completed로 소비하는 실패를 추가 증명. |
| 44 | dispatch 실패와 실제 occurrence 실패를 구분한다 | R-tick15–16, C23/41/35; 기존 decoder | 생산 dispatch/occurrence 실패 projection 실행. TUI 문구 전체 실행 아님. |
| 45 | dispatch 기록만 있고 exact queue가 없으면 경고한다 | C38; 기존 decoder | 생산 stale occurrence 거절 + 기존 Missing 판정 근거. 새 CI의 채팅 경고 검사는 아님. |
| 46 | ledger와 queue 종단 증거가 충돌하면 완료로 만들지 않는다 | 기존 decoder conflict | 새 195개에 직접 TUI terminal-conflict case 없음. 이전 component 근거 유지. |
| 47 | 이전 owner ACK와 새 owner pending을 구분한다 | C21/33/37; 기존 decoder/재생 | 실제 transfer outbox/projection/cached target 실행. 실제 model-to-model 인계 미검증. |
| 48 | 재시작 전 Running을 Due로 복원한다 | S-due7–8 | 실제 filesystem Running→Due recovery 함수/idempotence 실행. 새 process bootstrap은 아님. |
| 49 | 첫 startup recovery 실패 후 같은 process에서 회복한다 | Test40358821346 Consumer의 keeper_wake46–47, 117 PASS; Test40365052184에 같은 source 포함 | genuine Running·실제 publication 실패→첫 recovery 실패→저장 복원→같은 maintenance state의 다음 cadence 성공, 성공 뒤 normal crash가 startup으로 돌아가지 않음 실행. 실제 서버 프로세스 bootstrap/설치 binary는 미검증. |
| 50 | dispatch 실패 정산 write 실패 뒤 같은 process에서 회복한다 | Test40365052184의 exact attempt/primary fault 회귀; 후속 PR46248 | Store의 실제 primary 실패·같은 capability 재정산은 실행. 보류 intent를 다음 production cadence에 보존/재시도하는 PR46248은 작성·독립 소스 검토 완료, Test40369739062는 head22014660의 직접 Eio 의존 참조로 suite 전 컴파일 실패. head2861571의 Test40371389026도 warning4로 suite 전 실패. 닫힌 오류 분기와 문서 수리 headc52f799의 Test40374192059는 요청됐으며 결과 미관측. 실제 서버 binary 수렴은 미검증. |
| 51 | 손상·stale receipt·결과 불확실을 성공으로 덮지 않는다 | S-corruption2–3/6–9, C23–27/34/38/41/43/47/49 | 손상·write failure·retired/stale/noncanonical receipt 거절 실행. 전체 runtime 장애 복구는 아님. |
| 52 | 도착한 단발이 dispatch Succeeded여도 계속 보인다 | 기존 chat_schedule_entries 추출 결정 | 새 195개에 해당 TUI suite 없음. 실제 채팅 표시 미검증. |
| 53 | 선택한 Keeper의 예약만 보인다 | 기존 selection; W35는 backend owner만 | TUI Keeper 전환·generation·shared-read UI 실행 미검증. |
| 54 | 앞 회차 시각·다음 예정·hold가 구분된다 | C44–45 | 생산 hold JSON→TUI hold decoder의 exact occurrence/due 실행. 전체 clock/render 미검증. |
| 55 | F9로 펼치고 입력 공간·좁은 화면을 보존한다 | 직접 실행 없음 | F9·좁은 화면·입력 공간의 실제 상호작용 미검증. |
| 56 | 오래된 조회를 현재 사실로 오인하지 않는다 | C45–46 | Hold_current→Hold_as_of 결정 및 cache invalidation 실행. 전체 async refresh/화면 미검증. |
| 57 | overdue 때 사용자에게 알려 준다 | 직접 새 실행 없음 | persistent notice 구현/기존 선택 결정과 별개로 실제 overdue 알림 UX 미검증. OS push/sound 보장 없음. |
| 58 | 채널/파일에 요청한 실제 결과가 도착한다 | real-deepseek-1/real-glm-1; C4는 route만 | 실제 내부 note 목적지 효과/readback 성공. posting/file/외부 채널은 미검증. |
| 59 | worker 실행·idempotence·effect unknown을 처리한다 | L0–6 | 생산 queue/receipt와 대체 worker lifecycle/redelivery 실행. 실제 package/container worker/외부 effect 미검증. |


F3 수리는 [PR46182](https://github.com/jeong-sik/masc/pull/46182)의
`ed79abfd0500cec731168ab2517969ef30db490a`에 게시됐다. 소스 검토와 별도 **Test [40330717541](https://github.com/jeong-sik/masc/actions/runs/40330717541)**,
head `ed79abfd0500cec731168ab2517969ef30db490a`, ref `fix/schedule-mutation-authority-20261026`,
conclusion **success**를 확인했다. 실제 artifact는 55/58/9/2=124 cases이며
[완료 영수증](../evidence/2026-10-26-schedule-runtime-behavior/authority-fix-ci-result.json)에 있다.
이 표의 기존 195개와 다른 코드 head/검사이며 설치·실제 HTTP cancel race 증명은 아니다.
F4와 F1의 완료 검사, 별도 product94b2의 native build 및 실제 모델 재검증은
[수리 증거 묶음](../evidence/2026-10-26-schedule-repair-validation/README.md)에 있다.
F6 Test40341860767은 b5c976 head에서 Connector32 PASS, Owner103 PASS/3 FAIL로 전체 실패다.
이후 Test40348100243의 ccb000 head에서 Owner106 PASS/skip0/fail0를 확인했다.
main 위로 rebase한 6dedd head의 결과로 이월하지 않는다.
소스 작성·리뷰·CI·격리 binary 실행·운영 설치를 구분하며, 전체 기능 PASS는 아니다.


2026-10-27 보강: [정산·복구 검증 bundle](../evidence/2026-10-27-schedule-settlement-verification/README.md)은
workflow **Test40358821346**, head `b07769be553f54d14873c72f9ccd161d4085799e`,
ref `fix/schedule-ledger-commit-result-20261027`, conclusion **success**의 117 PASS와
workflow **Test40365052184**, head `fa23bf437c3679bb4b7bd7c47eb592675697e370`,
ref `fix/schedule-attempt-authority-20261027`, conclusion **success**의 420 PASS를 보존한다.
두 실행은 중복 suite를 포함하므로 합쳐서 새 시나리오 수로 세지 않는다. 이 근거로
8–10행의 기존 domain 정책 실행과 49행의 생산 maintenance 조합 복구를 보강했다.
50행의 후속 pending loop, actual process restart·모델·TUI·설치는 따로 검증해야 한다.
