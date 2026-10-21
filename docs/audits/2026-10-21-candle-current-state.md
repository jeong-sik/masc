# Candle 현황 분석 — 2026-10-21

## 분석 범위와 판정 기준

이 문서는 Candle 요구사항 명세서의 사실 근거다. 분석 소스는
`4fff07da4516d871a7ef71260585afaedad6c776`에 고정했다. 문서 작업의 시작점은
`97468f95df78f35a35bb3fe14a9670240cced930`이며, 두 커밋 사이의 변경은 Codex quota
RFC와 Dashboard 미사용 export 정리다. 아래 Candle 소스에 관한 판정은 고정 소스를 기준으로 한다.

현재 소스·테스트 본문, 운영 서버의 읽기 전용 health/config/원장 관측, 과거 실행
자료를 구분했다. 이번 분석에서는 OCaml 테스트·빌드·모델 평가·구매·지급·설정 변경·
실제 UI 조작을 실행하지 않았다. 테스트가 있다는 사실을 현재 테스트 성공으로 쓰지 않는다.

| 근거 | 의미 | 증명하지 않는 것 |
|---|---|---|
| S | 고정 소스와 직접 소비자를 읽음 | 실행·설치·배포 성공 |
| T | 고정 소스의 테스트 시나리오를 읽음 | 이번 분석에서의 테스트 성공 |
| H | 특정 과거 소스·환경의 보존된 실행 보고를 읽음 | 현재 head 또는 운영 환경의 성공 |
| L | 아래 시각에 운영 자료를 읽기 전용으로 관측 | 새 거래 성공, 현재 worker/model 준비, 화면 표시 |

`구현`은 S 수준의 연결된 구현이 있다는 뜻이다. `부분`은 요구 일부만 제공한다.
`없음`은 지정한 공개 기능 경로가 없다는 뜻이다. `미검증`은 실패와 다르다.
미채택 제안과 의도된 범위 밖 기능도 미구현 결함과 구분한다.

## 현재 되는 것과 한계

| 영역 | 현재 상태 | 남은 한계 / 확인할 것 |
|---|---|---|
| Goal → 보상 | Snapshot·사람 확정·PayoutOwed·후보·모델 판정·Paid 구현. 재오픈·재시작 중복 방지 시나리오 존재 | 이번 head의 실행 미검증. 원장에 과거 Paid 1건 존재 |
| 통화·감쇠 | 정수 milli, 원장 replay, 공급량, Q128 지수 감쇠, 정책 경계 구현 | 운영 설정 168시간과 경계 행은 관측. 현재 잔액을 별도 계산해 확정하지 않음 |
| 가격 | 고정 가격과 선택적 supply_scaled 정책 구현 | 경제 효과·공정성·조작 저항성 검증과 정책 채택은 별도 |
| 구매·착용 | Keeper 자신의 도구로 구매·착용·기본 모습 복원 구현 | 관측 구매는 무료 1건. 유료 구매·현재 UI 전체 경로 미검증 |
| 선물 | Keeper 간 금액·아이템 이전 구현 | 운영 원장에 선물 기록 없음. 이번 실행 미검증 |
| 운영자 지급 | 별도 로컬 masc-candle-grant CLI, 사유별 중복 방지 구현 | HTTP 권한 검증 경로가 아님. 서로 다른 버전의 CLI/server writer 격리 미제공 |
| TUI·Dashboard | 공급량, 잔액, Items 읽기·미리보기·새로고침·초상화 구현 | 구매·착용은 Keeper 도구 소유. operator 변경 버튼은 현재 계약에 없음 |
| 지급 관측 | 내부 의무·재시도 상태와 실행 기록·로그 존재 | 전용 pending/최근 거절/거래 내역 API·화면 없음 |
| 평가 품질 | Grade·Relation·Weights의 입력·출력 검증과 실행 영수증 구현 | 사람 보정·채택된 합격선 미완료. 유효 JSON이 공정한 평가를 뜻하지 않음 |
| 실패 복구 | 전송·자료 실패 재시도, 선언 변경 재평가, 의무 보존 구현 | 부분 판정 재사용 없음. 설정/초기 복구 Disabled 시 Goal 사실 기록을 건너뜀 |

## 운영 읽기 관측

2026-10-21의 이번 조사에서 `/health?full=1`로 effective base path와 runtime root를
먼저 확인한 뒤, 해당 root의 `config/candle.toml`과 `candle-ledger.jsonl`을 읽었다.
호스트 절대 경로와 원장 원문·Goal 내용·인증 정보는 이 공개 문서에 싣지 않는다.
정확한 수집 시각·해시·집계는 [정규화 관측 영수증](../evidence/2026-10-21-candle-observation.json)에 있다.

| 항목 | 관측값 |
|---|---|
| 서버 버전 / embedded commit | 0.59.0 / ad6ca89213d57c9ac978e1f3e5704292c4334cf6 |
| health | liveness ok, full health degraded. Candle 장애로 귀속하지 않음 |
| 반감기 | half_life = 168시간 |
| 감액 | deduction_rate = 0, deduction_floor = 1000 — 운영상 지연 감액 없음 |
| 지급 정책 | weight_max = 1; grades는 trivial/small/medium/large/epic, 금액 100/700/1000/1000/1000 milli |
| 가격 정책 | shop.pricing 미지정 → 현재 구현의 Fixed; 카탈로그 가격 18개 |
| 원장 | 40행, 10,709바이트; 모든 행의 JSON 구문 해석 성공 |
| 사건 수 | HalfLifeSet 2, Granted 28, Snapshot 2, PayoutOwed 2, Candidates 2, Paid 1, Unattributed 1, Purchased 1, Equipped 1 |
| 기록 시각 범위 | 2026-10-06T07:52:37Z ~ 2026-10-14T08:47:23Z |
| 기록된 총 발행 | Granted 280 + Paid의 실제 allocations 1000 = 1280 milli |
| 관측 구매 | glasses, 0 milli, 1건 |
| 선물 | Gifted/GiftedItem 관측 0건. 기능 실패나 비활성을 뜻하지 않음 |

1280 milli는 과거 기록의 발행 합계다. 168시간 감쇠를 반영한 현재 유통량·개별 잔액이
아니다. JSON 구문 성공도 OCaml의 엄격한 row/정산/지갑 검증 성공과 다르다.
이번 수집은 파일 간 원자적 snapshot이 아니며, 현재 서버 commit은 분석 소스 commit과
같지 않다. 운영 전체 기능의 PASS로 일반화하지 않는다.

## 과거 지적의 현재 판정

| 과거 항목 | 고정 소스에서 다시 확인한 결과 |
|---|---|
| Stable_lock_contended 무한 재시도 | 해결된 구현: Locked/Write_locked 즉시 반환. Cursor_mismatch만 새 ledger로 판단 재시도(S03) |
| 양성 Goal→Paid 통합 시나리오 없음 | 현재 test_candle_goal_flow에 실제 Goal/HTTP confirmation/worker/candidate reader 경로 존재(T01). 판정 경계는 주입 |
| appraiser 미공개면 Snapshot/Owed 누락 | 유효한 설정·복구 상태에서는 for_recording이 lane 가용성을 우회하여 보존(S06). 설정/복구 Disabled 누락은 별도 문제 |
| 감쇠 헌법 예외 미채택 | 현재 constitution domain/candle과 no_wall_clock_death에 예외 존재(S00). 과거 ‘개정 전 Off만’ 문구는 현재 금지가 아님 |
| 캐시가 이름·크기만 사용 | 현재 PNG/TUI 캐시는 장비를 구별함(S16). 원격 TUI는 서버 PNG를 받는 대신 서버 관측 장비를 로컬 렌더 |
| grant가 공통 CAS를 안 씀 | 현재 grant는 공통 update/CAS 사용(S11). 그러나 별도 로컬 CLI라는 writer-version 위험은 여전히 구분해야 함 |
| 읽을 때 정산 규칙 재검사 | 당시 산술 재계산과 현재의 durable 후보/정산 관계 재검증을 구분. #44391은 여전히 열린 수정이며 main 완료로 쓰지 않음 |
| 모든 단계가 실패 뒤 처음부터 재실행 | 현재도 부분 판정 resume 없음(S08). 후보와 의무 보존, 실행 영수증 보존은 단계 재사용과 다름 |
| ‘다섯 등급’이 코드 고정 목록 | 현재는 TOML id/criteria 목록. 관측 운영 정책이 다섯 등급인 것과 파서 계약을 구분(S01/S08) |

## 남은 차이와 정책 결정

| ID | 현황 / 재현 가능한 수용 조건 | 관련 요구사항 |
|---|---|---|
| GAP-01 | 전용 지급 대기·최근 거절 관측 없음. 원장·로그를 수동 조합하지 않고 Goal별 의무/현재 재시도 사유/마지막 판정 시각을 읽을 수 있어야 함 | CND-OPS-01/02 |
| GAP-02 | 전송 실패 후 부분 판정을 재사용하지 않음. 단계 재사용을 채택한다면 동일 verifier/policy/prompt/후보 identity에 결속한 재개 계약과 시험이 필요 | CND-APR-08 |
| GAP-03 | 사람 보정·공정성 합격선 미채택. 운영 등급/슬롯/프롬프트별 사람 기준과 반복·불변성·주입·관계·기여도 결과가 필요 | CND-APR-09 |
| GAP-04 | 최초 원장 복구 불가 시 Disabled로 사실 기록을 생략하지만, 이후 Enabled append 실패는 전이를 거절함. 조용한 의무 누락과 Goal 가용성 중 어떤 계약을 채택할지 필요 | CND-GOAL-09 |
| GAP-05 | 로컬 grant CLI에 서버 버전/세대 admission 없음. reader가 모르는 row를 별도 writer가 넣는 경계를 정의하고 양방향 버전 충돌 시나리오 검증 필요 | CND-SEC-05 |
| GAP-06 | 과거 row의 의미 admission이 현재 규칙과 결합됨. 읽기 당시 사실/새 append 검사 분리를 다루는 #44391은 아직 open | CND-LED-07 |
| GAP-07 | appraiser 가용성이 잔액·가격·구매·장착·선물에도 영향을 줌. grant만 우회하는 현재 정책은 명시되어 있으나 경제 조회/소비와 지급을 분리할지는 미결정 | CND-CFG-06 |
| GAP-08 | 시간 경과만으로 고정 가격 계정 revision이 바뀌지 않음. 정확한 실시간 잔액 표시 요구를 채택한다면 경과 시간에 따른 관측 신선도 계약이 필요 | CND-UI-06 |
| GAP-09 | 원장은 서명·hash chain이 없는 로컬 파일. 금전 정확성은 trusted host/file access에 의존하며, 호스트 쓰기 권한 공격에 대한 무결성 보장 미제공 | CND-SEC-04 |

operator 구매 버튼·Candle 전용 설정 편집기·환불·재판매·미귀속 판정 재개는 현재 제공되지
않는다. 앞의 둘은 확장 후보이며 기존 확정 요구가 아니다. 뒤의 기능도 새 정책 없이
추가할 수 있다고 가정하지 않는다. Tool/Skill/model/turn budget 구매는 헌법상 범위 밖이다.

## 소스와 시험 근거 색인

아래 링크의 줄은 분석 커밋에 고정된다. 파일 이름만 제시한 테스트도 같은 커밋에서
읽은 소스이며 이번에 실행한 결과는 아니다.

| 근거 | 직접 읽은 소스 / 테스트 |
|---|---|
| S00 | [constitution Candle·불변식](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/docs/constitution.xml#L213), [기존 RFC](../rfc/RFC-goal-candle-ledger.md), [지급 설정 가이드](../guides/candle-payout-policy.md) |
| S01 | [config](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_config/candle_config.ml#L1), candle_config.mli |
| S02 | [event schema](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle/candle_event.mli#L1), candle_event.ml |
| S03 | [ledger](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_store/candle_ledger.ml#L1), candle_ledger.mli |
| S04 | [balance projection](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle/candle_balance.ml#L1), candle_balance.mli |
| S05 | [payment/math](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle/candle_payment.ml#L1), candle_math.ml, candle_decay.ml, [산술 계약](../design/candle-decay-arithmetic.md) |
| S06 | [Snapshot](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_runtime/candle_snapshot.ml#L42), candle_payout_owed.ml:38, candle_status.ml:23, workspace_goals.ml |
| S07 | [candidates](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_runtime/candle_candidates.ml#L1), candle_tasks.ml, candle_payout.ml |
| S08 | [appraisal](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_runtime/candle_appraise.ml#L1), candle_appraisal.ml, server_candle_appraiser.ml |
| S09 | [worker](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_runtime/candle_payout_worker.ml#L1), candle_payout_worker.mli |
| S10 | [server bootstrap](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/server/server_runtime_bootstrap.ml#L1429), server_candle_appraiser.ml |
| S11 | [shop](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_runtime/candle_shop.mli#L1), candle_equipment.ml, candle_gift.ml, candle_grant.ml, bin/masc_candle_grant.ml |
| S12 | [Keeper tools](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/keeper/keeper_candle_tools.ml#L1), config/tools/keeper_candle_*.toml, mcp_server_eio_execute.ml:443 |
| S13 | [read-only observation](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/candle_runtime/candle_observe.ml#L1), candle_observation.ml, candle_status.ml:103 |
| S14 | [TUI Items](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/bin/masc_tui_render_keepers.ml#L724), masc_tui_keeper_items.ml, masc_tui_candle.ml, [TUI manual](../TUI-GUIDE.md#keepers) |
| S15 | [Dashboard Items](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/dashboard/src/components/keeper-items-panel.ts#L1), candle-economy.ts, keeper-portrait.ts |
| S16 | [portrait HTTP](https://github.com/jeong-sik/masc/blob/4fff07da4516d871a7ef71260585afaedad6c776/lib/server/server_dashboard_http_keeper_portrait.ml#L1), server_dashboard_http_keeper_items.ml, bin/masc_tui_keeper_portrait.ml |
| T01 | test/test_candle_goal_flow.ml:642–899; test_candle_snapshot.ml; test_candle_payout_owed.ml; test_candle_candidates.ml; test_candle_tasks.ml |
| T02 | test/test_candle_config.ml; test_candle_event.ml; test_candle_ledger.ml; test_candle_balance.ml; test_candle_math.ml; test_candle_time.ml |
| T03 | test/test_candle_appraisal_flow.ml; test_candle_appraiser_transport.ml; test_candle_payout_worker.ml; test_candle_payout.ml; test_candle_status.ml |
| T04 | test/test_candle_purchase_flow.ml; test_candle_gift.ml; test_candle_grant.ml; test_candle_grant_cli.py; test_keeper_portrait_http.ml |
| T05 | dashboard/src/components/{keeper-items-panel,keeper-portrait,candle-economy}.test.ts; test/test_tui_portrait_view.ml |
| H01 | [과거 양성 지급 통합 실행](../evidence/2026-09-30-candle-confirmed-paid/README.md), [정책 fixture 실행과 미해결 transport 한계](../evidence/2026-10-02-candle-configured-policy/README.md) |
| H02 | [과거 native PNG/browser component 실행](../evidence/2026-09-30-equipped-portrait-browser/README.md); 전체 Dashboard·현재 TUI 실행 증거와 구분 |
| H03 | [사람 기준 보정 현황](../testing/candle-appraiser-calibration-proposal/README.md), [Grade 후보 비교](../evidence/2026-09-30-candle-grade-explicit-outcome/README.md) |

## 관련 진행 상황

2026-10-21 GitHub 조회 기준 #44391(원장 읽기 정산 재검증 분리)과 #44702(Add-on
Candle appraisal 통합)는 open이며 미병합이다. 열린 issue #41321, #41322, #41323은
각각 원장 재검증, 초기 복구 실패, 단계 재시도를 추적한다. issue가 열려 있다는 사실만으로
현재 결함을 판정하지 않고 위 소스와 함께 읽었다. Add-on worker 통합을 이미 main의
기능이라고 명세하지 않는다. 향후 반영 여부는 PR의 새 head·실제 병합·설치 상태를 다시 확인한다.
