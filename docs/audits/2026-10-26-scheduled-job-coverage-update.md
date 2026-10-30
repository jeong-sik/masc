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
| 2 | Lane installation/action을 예약한다 | W24, L0 | Lane 전용 shape·생산 admission/queue 통과. L의 worker는 대체 callback. [candidate c52f799 실제 Docker export](../evidence/2026-10-27-schedule-candidate-runtime/README.md#actual-scheduled-lane-export-and-ownership-control)는 occurrence→handoff→original worker confirmed→빈 export bytes/readback 일치. 모든 action 검증은 아님. |
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
| 13 | operator/creator/recipient가 수정·취소한다 | W37–41, C11; API33 | named 권한·직접 Operator_caller 취소 실행. candidate c52f799 실제 HTTP Admin create/cancel human_operator stamp, Worker 타인 control 취소400/not_schedule_owner와 원장 불변 확인. 전체 역할·HTTP race 검증은 아님. |
| 14 | 호출자가 임의 결과 채널을 주입한다 | W12–13/19, C4 | 신뢰 origin 결속·creator route 보존·queue 전달 실행. 외부 송신은 미검증. |
| 15 | public id를 유지하며 새 instance로 바꾼다 | W4–7, S-state4–7; API33 | public id 유지·fresh instance 및 terminal 변경 거절 실행. |
| 16 | 내용만 수정하면서 과거 due 시각을 보존한다 | W8–9/46, S-state8; API33 | due/recurrence/expiry 보존 및 명시 retime 경계 실행. |
| 17 | 동시 수정·retime가 저장 결과를 잃지 않는다 | W10 | 양쪽 timing 생략 content edit의 결정적 concurrent retime 보존 실행. 전 조합 보장 아님. |
| 18 | 권한 확인 사이 target이 바뀌면 이전 recipient 변경을 거절한다 | F3 소스 반례; 수리 PR46182 | locked current-row 권한 수리 PR46182의 새 Test124 통과. 공개 update interleaving/locked cancel 거절 포함; 실제 HTTP cancel race·새 binary는 미검증. |
| 19 | due만 바꿀 때 다른 호출이 갱신한 recurrence를 보존한다 | F4 소스 반례; 수리 PR46193 | 최신 recurrence 보존 수리와 공개 interleaving 2건 포함 Test40332170687의 115 cases 통과. 실제 HTTP race/새 binary 재현은 미검증. |
| 20 | A에 이미 대기 중인 반복 예약을 B로 바꾸고 취소한다 | retarget-cancel-4; 수리 PR46211 | 실제 F1 반례는 유지. all-owner 철회·transfer fencing 수리의 Test40343103111에서 3 suites 통과(명시 64+12=76 cases + queue executable). [candidate c52f799 실제 재검증](../evidence/2026-10-27-schedule-candidate-runtime/README.md)은 동일 A→B 변경·취소 후 양쪽 원 source/pending 없음 확인. paused/zero-turn이며 모델 실행 없음. 강제 concurrent transfer는 미검증. |
| 21 | 아직 dispatch되지 않은 Scheduled/Due를 취소한다 | W3, S-lifecycle1, C10–11; API33 | 정의 및 current-target pending 취소 실행. 이전 target/instance 조합의 과거 F1 실패와 새 candidate의 제한된 통과는 20행 참조. |
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
| 36 | Keeper가 작업 중일 때 도착한 예약을 보존한다 | real-busy-deepseek-1; repair-validation 실제 두 모델; [D9 실제 after-effect](../evidence/2026-10-27-schedule-after-effect-models/README.md) | 과거 F6 반례 유지. product94b2에서 DeepSeek/GLM의 checkpoint 보존·두 note·exact ACK 확인. DeepSeek observer의 overlap FAIL은 유지하며 원장으로 별도 대조. b5c976의 Owner103/3 실패는 보존하고 fixture 수리 ccb000의 Owner106 PASS와 구분. standalone rebased6dedd 실행은 미검증. 조합본D9 DeepSeek는 A1→checkpoint·원 incarnation 보존→B ACK→동일 A 재입장→A2→ACK를 실제 확인했지만, 모델이 잘못된 정정 노트까지 추가해 총4회 썼다. 같은 D9 GLM은 A1 없이 다른 ID를 조회하고 원 요청을 완료·ACK해 B 생성 전 실패했다. 모델 행동 전체 PASS가 아니다. 수리 #46272를 포함한 [C2 실제 두 모델](../evidence/2026-10-27-schedule-durable-runtime/README.md)에서 post-tool durable 본문 유지 확인. GLM은 A3에서 canonical B 결과를 읽고 A2를 썼다. 원 observer의 notes_list 전용 FAIL은 보존하고 별도 raw 검증으로 구분한다. DeepSeek는 세 note만 썼지만 B가 A2를 수행한 뒤 A3는 실행 없이 완료했다. B의 A 작업 금지 조건 위반이며 요청별 행동 격리는 FAIL이다([후속 #46281](https://github.com/jeong-sik/masc/issues/46281)). [C3 실제 두 FAIL](../evidence/2026-10-27-schedule-entry-model-negative/README.md): frozen87의 DeepSeek·GLM 각 1회 모두 정확3 note를 쓰되 A2를 B 턴에서 실행했다. 실제 B admission과 B의 A 작업 금지 본문이 보존됐고 B의5개 모델 라운드 issuer에서도 같은 typed frame을 확인했다. 관측 추가만으로 요청 준수 문제를 해소하지 못했으며 두 원 FAIL·controller exit1/server 정상 exit0을 보존한다. |
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
| 48 | 재시작 전 Running을 Due로 복원한다 | S-due7–8 | 실제 filesystem Running→Due recovery 함수/idempotence 실행. [c52 native 새 process](../evidence/2026-10-27-schedule-native-startup-recovery/README.md)에서 genuine Running 사망 후 old attempt가 process_interrupted로 정리되고 새 attempt/paused enqueue까지 관측. 중간 Due 화면을 직접 캡처한 것은 아님. |
| 49 | 첫 startup recovery 실패 후 같은 process에서 회복한다 | Test40358821346 Consumer의 keeper_wake46–47, 117 PASS; Test40365052184에 같은 source 포함 | genuine Running·실제 publication 실패→첫 recovery 실패→저장 복원→같은 maintenance state의 다음 cadence 성공, 성공 뒤 normal crash가 startup으로 돌아가지 않음 실행. [c52 native 실제 bootstrap](../evidence/2026-10-27-schedule-native-startup-recovery/README.md): SIGSTOP·lease 자연만료·의도SIGKILL로 보존된 Running에 첫 실제 staging-write 실패→동일 B runtime 다음tick 복구·원본/control 합계 dispatch2. old Running/control 원장 불변 확인. scheduler ok이나 overall health는 degraded, 모델/운영 설치 증명 아님. |
| 50 | dispatch 실패 정산 write 실패 뒤 같은 process에서 회복한다 | Test40365052184의 exact attempt/primary fault 회귀; 후속 PR46248 | Store의 실제 primary 실패·같은 capability 재정산은 실행. 보류 intent를 다음 production cadence에 보존/재시도하는 PR46248은 작성·독립 소스 검토 완료, Test40369739062는 head22014660의 직접 Eio 의존 참조로 suite 전 컴파일 실패. head2861571의 Test40371389026도 warning4로 suite 전 실패. 닫힌 오류 분기와 문서 수리 headc52f799의 [Test40374192059](../evidence/2026-10-27-schedule-settlement-verification/test40374192059/result.json)는 success: Runner30·Consumer60·Tool wiring64·Lane act7, 161 PASS/FAIL0/SKIP0. production maintenance composition에서 intent 보존·같은 process cadence 재정산·health와 오류 경계 검증. [C2 native 실제 F5](../evidence/2026-10-27-schedule-durable-runtime/settlement/README.md)는 실제 queue Permission denied + primary ledger Is-a-directory를 확인했다. 동일 PID에서 pending1→queue-only 복구 후 재발행0→원장 복구로 원 Retry 정산→다음 주기 단일 새 attempt/queue 전달을 관측했다. 독립 원형 검산·정상 종료0·재시작0. 첫 준비 실험 INCOMPLETE는 보존한다. 모델 실행·프로세스 사망 뒤 in-memory intent 보존 증거는 아니다. |
| 51 | 손상·stale receipt·결과 불확실을 성공으로 덮지 않는다 | S-corruption2–3/6–9, C23–27/34/38/41/43/47/49 | 손상·write failure·retired/stale/noncanonical receipt 거절 실행. 전체 runtime 장애 복구는 아님. |
| 52 | 도착한 단발이 dispatch Succeeded여도 계속 보인다 | 기존 chat_schedule_entries 추출 결정; C2 실제 TUI trial4 | 실제 TUI의 A 대상 응답에 원 instance의 dispatch succeeded·accepted·matched_pending이 함께 도착했다. incarnation0은 같은 post ID의 별도 root waiting inventory에서 결합한 값이다. backend 수락을 소비 완료와 구분한다. 지속 표시·notice paint는 미검증이다. |
| 53 | 선택한 Keeper의 예약만 보인다 | 기존 selection; W35; C2 Test40409087814; 실제 TUI trial4 | 기존 state suite의 schedule-target/generation 1 case에서 late A·오래된 generation·roster/chat target 분리 결정을 실행했다. 실제 native TUI A→B→A의 대상별 응답도 해당 owner의 예약만 포함했다. 실제 late-response 교차와 화면은 별도이며 전체 UI PASS는 아니다. |
| 54 | 앞 회차 시각·다음 예정·hold가 구분된다 | C44–45 | 생산 hold JSON→TUI hold decoder의 exact occurrence/due 실행. 전체 clock/render 미검증. |
| 55 | F9로 펼치고 입력 공간·좁은 화면을 보존한다 | C2 실제 TUI trial4 | 정상 typing/paste·F9 의도 byte2회·120→20→120 resize·좁은 typing/paste 후 실제 수락된 원 queued edit는 정상 suffix만 보존했다. B 작업은 불변이다. F9 인식/펼침 상태·UI resize 처리 ack·좁은 guard 인과·입력 공간 paint는 미검증이다. |
| 56 | 오래된 조회를 현재 사실로 오인하지 않는다 | C45–46; C2 Test40409087814; 실제 TUI trial4 | Hold_current→Hold_as_of·cache invalidation 및 failed refresh 때 last read 보존·target별 error/generation 결정을 실행했다. 실제 refresh 입력 후 새 canonical row도 TUI 응답에서 관측했으나 공유 polling의 영향과 분리하지 않는다. 실제 failure/interleaving·paint는 미검증. |
| 57 | overdue 때 사용자에게 알려 준다 | 직접 새 실행 없음 | persistent notice 구현/기존 선택 결정과 별개로 실제 overdue 알림 UX 미검증. OS push/sound 보장 없음. |
| 58 | 채널/파일에 요청한 실제 결과가 도착한다 | real-deepseek-1/real-glm-1; C4는 route만; C2 file trial2 | 실제 내부 note 목적지 효과/readback 및 C2 DeepSeek의 단일 MicroVM Write→정확한 71 UTF-8 bytes 전체 Read→원 Job marker 1개를 실행했다. 첫 shim 누락 FAIL은 보존한다. host export·독립 guest FS 추출·posting/외부 채널·두 Job 범위 정확성은 미검증이다. |
| 59 | worker 실행·idempotence·effect unknown을 처리한다 | L0–6 | 생산 queue/receipt와 대체 worker lifecycle/redelivery 실행. candidate c52f799 실제 package/Docker worker export와 원 receipt 안정성·빈 blob/volume readback 일치 확인. 실제 worker redelivery·unknown·외부 effect exactly-once는 미검증. |


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
후속 workflow **Test40374192059**, head `c52f799e52d3683bd2a4c624f0f6adfe36015ec9`,
ref `fix/schedule-pending-settlement-20261027`, conclusion **success**의 161 PASS는
50행의 pending loop 생산 composition을 검증한다. 이 실행들은 중복 suite를 포함하므로
합쳐서 새 시나리오 수로 세지 않는다. 8–10행의 기존 domain 정책과 49행 복구 근거도
각 실행 head에 한정한다. [동일 candidate 실제 실행](../evidence/2026-10-27-schedule-candidate-runtime/README.md)은
20행의 제한된 A→B 취소와 2·13·59행의 빈 export/권한 사례를 보강한다.
[통제된 실제 bootstrap 복구](../evidence/2026-10-27-schedule-native-startup-recovery/README.md)는 c52에 한정해 48–49행을 보강했다. [D9 실제 모델 두 사례](../evidence/2026-10-27-schedule-after-effect-models/README.md)는 36행의 기계적 보존·재개와 의미상 정확성을 구분한다. F5 process-local intent 사망 후 보존·임의 모델의 작업 정확성·모델 전환·TUI·운영 설치는 별도 경계다.


2026-10-27 C2 후속: [durable 요청·실제 정산·두 모델 근거](../evidence/2026-10-27-schedule-durable-runtime/README.md)는
원 수리 #46272 head `2d8fa7543519c5c58be056f3460a2a06e76c2730`의
Test40394461863 두 suite 44+66=110 PASS와, 원 source slices를 그대로 조합한
별도 Draft #46274 head `a3950a189b9cc5a7ce82cb725699455d79923f42`의 native producer
40396800146 및 격리 실제 실행을 구분한다. C2는 중복 소스 검증용이며 병합 대상이 아니다.
원 #46272의 정식 source 승인과 focused CI는 실제 모델 성공 판정과 다르다.

GLM 원 관측기 FAIL은 실제 canonical 결과 재조회 경로를 놓친 관측 한계다.
별도 원형 검증은 B 결과 blob→A3 실제 읽기→A2와 저장된 checkpoint 선택 자료의 연속성을 확인했다.
원 관측기의 정상 종료 PASS로 다시 쓰지 않는다. DeepSeek 원 FAIL은 실제 B 턴의 A2 실행이다.
세 효과의 수가 맞아도 B의 명시적 요청 범위 제한을 지켰다는 뜻은 아니다.
두 실험의 요청별 행동을 합쳐 전체 PASS로 부르지 않으며, old D9 반례도 그대로 남긴다.
50행의 실제 동일 PID 정산 복구는 이번에 보강됐지만 52–57행의 보이는 TUI·F9·알림 동작,
강제 HTTP race·장기 calendar·모델/계정 전환·외부 파일/채널 효과와 설치는 여전히 별도 미검증 범위다.

2026-10-27 추가 관측은 [TUI state·파일 효과 bundle](../evidence/2026-10-27-schedule-tui-file/README.md)에 있다.
workflow **Test40409087814**, 실행 head `a3950a189b9cc5a7ce82cb725699455d79923f42`,
ref `ci/schedule-durable-candidate-20261027`, conclusion **success**는
기존 `test_tui_loading_notice`만 실행한 8 PASS이며 full CI나 실제 PTY 증명이 아니다.
동일 C2 native의 파일 trial1은 실제 Write의 `microvm_shim_missing`으로 FAIL이다.
새 격리 base에 명시적으로 pin한 기존 arm64 shim/sidecar를 준비한 trial2는
Write·완전 Read·marker·원 source/incarnation·ACK·fresh idle·정상 exit 0을 확인했다.
88개의 반복 검사 기록은 한 파일 시나리오이며, 이전 DeepSeek 두 Job 범위 FAIL을 수리한 근거가 아니다.
TUI 첫 실제 관측은 compact `/health`를 놓친 검증기 시작 조건과 별도 통신 실패로 INCOMPLETE이다.
selector를 고친 다음 관측은 실제 TUI의 HTTP400과 별도 진단의 동일 응답 digest를 통해
관측 relay의 Host가 서버 identity로 설정되지 않아 `request_authority_untrusted`로 거절된 것을 확인했다.
이 관측도 INCOMPLETE이며 키보드 시나리오에는 도달하지 않았다.
이 관측을 화면·F9·좁은 입력·알림의 성공이나 예약 기능의 새 실패로 바꾸어 해석하지 않는다.

[후속 실제 TUI 요청·상태 bundle](../evidence/2026-10-27-schedule-tui-request-state/README.md)은
동일 C2 native에서 trial4의 한 요청·저장 상태 시나리오 PASS를 보존한다.
실제 TUI 요청147건과 root 사전 확인1건을 분리하고, A/B 대상·새 목록·원 queued edit·B 불변·두 owner zero-turn과 정상 child exit0을 검산했다.
기존 routine 관측을 TUI child에만 활성화하여 같은 PID/capture의 적용·decoder 준비를 첫 입력 전에 확인했다.
이전 trial3 INCOMPLETE와 roster 시점 원인 미확정의 별도 정정은 유지한다.
43개 반복 assertion은 한 시나리오이며 visible UI·전체 52–57행·DeepSeek 두 Job 범위 오류의 해결을 뜻하지 않는다.


2026-10-27 C3 실제 음성 근거: [새 retained bundle](../evidence/2026-10-27-schedule-entry-model-negative/README.md)은
frozen source `87e6f274ddd5958b3966608fab376cfd1cb50ed3`, server SHA256
`8fb19608eac66c5b0cbaf10cc5a549ae9e3093222d4a504abcd8b6e85473adfe`,
controller v2 SHA256 `5dc790ed515f4bdeab148314ab0dc0d4e6b48c0050c58105a8109bfacf8a5aec`의
DeepSeek·GLM 각 한 실제 시나리오를 보존한다. 둘 다 전체 owned tool10행과 정확3 note_add를
직독했으며 A2는 B의 exact note readback 후 같은 B 턴에 속했다. B Completed/ACK와
A의 exact 재입장은 그 뒤다. 각 B의5개 pre/post-tool issuer System partition은 실제
provider capture의 정확한 typed Known[B] span과 맞고, B의 A 작업 금지 요청도 JSON-unquote 뒤
원 generated body와 같다. 따라서 관측 전달의 양성 근거와 요청 준수의 실제 FAIL은 동시에 존재한다.
이는 같은 Keeper의 협업 note 권한 우회나 새로운 hard isolation 계약을 증명하지 않는다.

Workflow **Minimal manual checks40428400174**, execution head87 위 SHA,
ref `ci/schedule-entry-candidate-20261027`, conclusion **success**는
기존 addon-lifecycle27+5 cases와 native 생산 범위다. 실제 두 모델의 FAIL과 별개이며
C3가 물려받은 wire fixture P2 두 건도 해소하지 않는다. canonicalcb의 후속 fixture 수리나
그 head의 별도 검사 결과를 이 후보로 이월하지 않는다. 원 snapshot 회전으로 재읽을 수 없는 과거 checkpoint는
관측 선택 자료와 해시만 남았으며 원형 전체 복원 성공으로 바꾸지 않는다.
두 controller exit1, 두 owned server 정상 exit0, forced kill0이며 자동 재실행은 없었다.
원 C2 GLM 관측기/정정과 DeepSeek FAIL, D9 반례는 모두 유지한다. 59행 ID·순서와
52–57행의 미검증 경계를 그대로 두며, 전체 기능·일반 provider·운영 설치 PASS는 아니다.
