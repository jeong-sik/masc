# MASC runtime 오류 정리 및 개선안 — 2026-10-03

현재 가장 큰 운영 문제는 단발 호출 실패가 아니라 quota로 멈춘 Keeper의 대기열과 검증 대기, 여러 provider에 함께 나타나는 간헐 네트워크 오류다. Librarian/recall 수리가 라이브에 포함돼 있어도 이 문제들은 별도로 남는다.

이 문서는 PR #40866의 reviewer-failover 설정과 별도로 전체 개선 우선순위를 기록한다. 현재 상태는 명시된 수집 시점의 스냅샷이며 이후 상태를 뜻하지 않는다. 공개 산출물에는 생로그, 계정 home, 개인 경로, 대화 본문을 포함하지 않는다.

## 범위와 증거

- runtime root: `<base-path>/.masc`. `/health?full=1`의 resolved path로 확인했다.
- 라이브 서버: `0.49.0`, embedded SHA `83d23c96c01f2505fe0bad39c699b330a3f9df93`. 이 문서는 새 release 게시나 Full RC 성공을 주장하지 않는다.
- 현재 health 스냅샷: operator health snapshot (captured 2026-10-03T03:14:05Z; private artifact retained).
- `system_log_2026-10-02.jsonl`, `system_log_2026-10-03.jsonl` 전체를 읽은 시점의 166,970개 JSON row. 파싱 실패 0개. 파일 날짜 및 `ts`는 UTC, 아래 운영 시각은 KST로 명시한다. 스캔 중 파일이 증가하므로 이후 레코드는 포함하지 않는다. counts.json에 파일별 byte cutoff, 마지막 record ts, 수집 시각을 기록했다.
- [counts.json](counts.json): 경고/오류 family별 로그 행 수와 파일별 cutoff·마지막 record 시각. 문자열 분류는 오프라인 조사용이고 제품의 상태 분기 코드가 아니다. 하나의 실패가 provider/상위 lane/continuity에 여러 번 기록되므로 행 수를 독립 장애 건수로 해석하면 안 된다. `other` 4,350행을 포함하며 이는 미분류 잔여이지 정상 판정이 아니다.
- 원본 대화·인증 토큰·secret 파일은 수집하지 않았다. 전체 playground/backup의 무결성 검사, 모든 provider 실호출, 모든 VM 검사 또는 브라우저 UI 증명은 하지 않았다.
- 선행 조사: earlier Librarian source audit (private artifact retained), earlier Queue design audit (private artifact retained). 당시 결과를 현재 발생 증거로 재사용하지 않았다.

## 현재 상태

| 항목 | 관측 | 해석 |
|---|---|---|
| health | degraded | reaction pending와 queue backlog가 직접 사유다 |
| Keeper | 실행 fiber 19, recovering Keeper 이름 4 | 복구 중: code-reviewer, glossary-maniac, indie-geek-blue, pr-updater |
| 이벤트 | pending 37 = runnable 30 + paused/dead 7 | source age와 queue residence를 구별해야 한다 |
| 검증 | completion authority 대기 Task 30 | fleet-blocking=false여도 결과 완료는 미증명이다 |
| runnable 가장 오래된 source | 약 89,699초, indie-geek-blue | queue에 그 시간 내내 있었다고 주장할 수는 없다 |
| queue residence | first_admission_not_recorded | 체류 시간은 unknown으로 보존 중이다 |
| config | schema ok, Keeper config error 0 | 현재 설정 파싱 장애는 관측되지 않았다 |
| 파일/저장 공간 | FD 197/245760, 공간 약 1.12TB 가용, exhaustion 0 | FD·disk 부족을 이번 장애의 원인으로 볼 증거가 없다 |
| ledger | pending stimulus 5, quarantined row 0, queue read error 0 | pending만으로 operator action을 켜는 현재 정책을 점검할 필요가 있다 |

## 개선 우선순위

우선순위는 개발 순서이며 확인하지 않은 보안/데이터 손실을 확정한 severity 판정이 아니다.

| 순서 | 문제와 현재 증거 | 개선 경계 | 검증할 결과 |
|---|---|---|---|
| 1 | code-reviewer·pr-updater: Antigravity `Individual quota reached`, reset 약 95h, 실패 기록에 deferred_next_runtime=none | 해당 Keeper의 실제 assignment와 lane을 먼저 읽고, 승인된 다른 provider binding을 포함한 failover lane으로 재설계. 계정 quota observation과 reset 증거를 공유해 같은 계정의 다른 모델을 무의미하게 순환하지 않기 | 같은 pending event를 유지한 채 다른 provider로 성공; ack는 실제 적용 뒤에만; quota-only로 source width를 줄이지 않음 |
| 2 | 검증 Task 30건 대기. evaluator unavailable 및 verifier fallback 고갈 로그 | verifier_exact의 실제 slot, 계정 quota, retryable 정책, pending verification identity를 함께 표시. 현재 쓰이는 API/CLI binding에서 결과를 낼 수 있는 fallback 확보 | 기존 verification_id로 재시도해 verdict durable commit; unavailable을 PASS/Done으로 바꾸지 않음 |
| 3 | 10/3 11:02·11:18·11:35·11:39 KST에 DNS/CLI routing 실패 군집. 두 Codex fallback은 별도 재검증 턴 성공 | host DNS resolver·provider 접속·Codex routing 단계를 같은 attempt와 시각으로 수집. 공통 host 네트워크 장애인지 vendor 오류인지 입증한 뒤 수정. 독립 장애 영역의 fallback 검토 | 네트워크 장애 재현 시 전송 전 실패와 전송 후 불확실을 구별; 회복 후 동일 durable 작업 전진; 성공 1회를 완치 증거로 쓰지 않음 |
| 4 | indie-geek-blue Muse 응답 관측 중단, turn/start 이후 300s silence, effect observation_unavailable; 현재 recovering | Muse host의 해당 turn_id/terminal receipt를 조회하는 복구 경로 강화. schema drift도 별도 codec 검증 | 기존 턴 terminal/효과를 확인한 뒤에만 다음 dispatch; observation timeout을 terminal로 간주해 중복 실행하지 않음 |
| 5 | runnable 30 / paused/dead 7 / pending stimulus 5. queue residence unknown | operator/UI에서 runnable·recovering·operator-paused 보존을 분리하고 exact event/owner/원인/복구 동작 표시. 첫 admission 시각은 새 입장 시 durable 기록; 기존 행은 추측하지 않기 | 건강한 진행 중 pending이 자동으로 운영 개입 요구가 되지 않도록 typed 상태 검토; 실제 막힌 owner는 degraded 유지; paused event 무단 삭제/자동 재개 없음 |
| 6 | 10/2 missing fragments 60행, 10/3 4행. 코드가 empty fragments에서 progress를 전진시킴 | 공식 행의 의도적 빈 projection과 fragment 손실을 typed 결과로 구분. source와 trace가 실제 없는지 확인해 검증된 loss 복구 설계 | 의도적으로 빈 행은 전진; 읽기 실패/누락으로 내용 소실이 의심되는 행은 증거 보존·복구 대상으로 남김. 손실 확정은 아직 안 됨 |
| 7 | 10/2 remote SSH shim config 오류 12행, image marker missing 147행; 10/3 같은 family는 발견 안 됨 | 현재 사용하는 VM별 shim 파일/권한/프로토콜을 읽기 전용 probe하고 image build와 admission에 동일 manifest binding 적용 | 실제 현재 VM에서 Read/Execute 성공; 이미지 marker 존재만으로 실행 정상이라고 판정하지 않음 |
| 8 | Muse 1.4.2 MSP schema digest와 검증 codec digest 불일치 69행 | 설치 CLI의 실제 protocol 샘플로 codec 소비 경로 검증. 알려진 version으로 고정하거나 대응 codec 변경은 별도 PR | thread/start·turn/start·tool·terminal 전 경로의 exact installed version 검증. 경고 문구 삭제로 해결 처리하지 않음 |
| 9 | dashboard activity_defaults refresh 325.2MB allocation, 0.362s, TTL 10s 로그 | 호출자가 날짜별 ledger 전체를 반복 읽는지 측정하고 incremental/shared projection cache 검토 | 같은 fleet/기록량에서 latency·allocation·cache hit 실측; Gc.allocated_bytes는 동시 fiber 영향을 받을 수 있어 단일 함수 325MB로 단정하지 않음 |
| 10 | WebFetch upstream refusal 146행 및 기타 capability/artifact/tool errors | 권한 거부·입력 오류·runtime 오류·정상 빈 결과를 현재 typed tool contract에 맞게 집계. 동일 인수로 권한 거부 무한 반복 방지 | 권한 있는 경로 또는 수정된 인수로만 후속 시도; schema rejection을 네트워크 retry로 보내지 않음 |
| 11 | 로그 중 quota family 4,957행, Codex routing 1,030행, DNS 322행; 다층 중복 | attempt_id/call_id, keeper, frozen binding identity, failure stage, effect disposition, first/last, 현재 복구 상태를 구조화해 operator가 한 사건으로 볼 수 있게 집계 | 원본 증거는 유지하면서 현재 incident 수·historical row 수를 구별. payload와 secret을 대시보드에 노출하지 않음 |

## 잔여 패턴과 추가 개선 경계

`other` 4,350행은 operator residual-pattern index (private artifact retained)에
동일 byte cutoff로 다시 읽어 모두 인덱싱했다. 1,747개 텍스트 패턴은 독립
장애 수가 아니다. ID·provider·Keeper별 표현 차이가 남아 있는 조사 인덱스다.

- shutdown operation이 supervisor recovery를 보류한 로그 216행: 해당 operation의
  실제 terminal receipt와 owner fence를 연결해 운영 화면에 표시한다. 로그 빈도만
  보고 fence를 지우거나 재시작하지 않는다.
- provider 입장 permit 전 queue timeout 패턴 36행: 요청 전송 후 timeout과 구분해
  계정별 사용량/대기 후보/입장 관측을 조사한다. queue 길이와 permit wait를 실측한
  뒤 동시성 설정을 바꾸며, timeout 증대만으로 해결 처리하지 않는다.
- `masc_keeper_msg` 실패 패턴 38행, `masc_keeper_up` error 패턴 35행: generic 요약과
  같은 요청의 typed payload를 연결해 입력 거부/권한/대상 상태/runtime failure를
  구분한다. 동일 인수로 재시도하거나 다른 Keeper 이름을 추측하지 않는다.
- long-turn 패턴은 해당 owner의 dispatch 단계·provider terminal 관측과 연결한다.
  긴 시간만으로 작업을 죽이지 않는다.
- 이 인덱스의 다른 HTTP·verification·effect-fence 패턴은 위 개선안 2·3·4·10·11의
  조사 범위다. 알려진 원인처럼 합치거나 각 패턴의 모든 근본 원인이 확정됐다고
  주장하지 않는다.

## 코드에서 확인한 경계

- `lib/keeper/keeper_reaction_ledger.ml:2099`: pending_count > 0 자체가 reaction_ledger_pending_stimulus 사유다. 따라서 현재 degraded가 모두 실행 불가능을 뜻하지 않는다. 정상/진행 중/차단 판정 설계가 필요하며 pending을 숨기는 수리는 부적절하다.
- `lib/keeper_runtime/keeper_event_queue_persistence.ml:1748`: First_admission_not_recorded를 unknown으로 출력한다. source age를 큐 체류 시간으로 바꿔 표시하면 안 된다.
- `lib/keeper/keeper_librarian_durable_consumer.ml:1274`: selected_messages와 observations가 모두 비면 경고 후 advance(). 실제 데이터 손실 여부를 source producer/retention과 함께 검증해야 한다.
- `lib/runtime/runtime_muse_serve.ml:786`: codec schema digest 경고 경계. 경고가 실제 parse 실패를 입증하는 것은 아니다.
- `lib/exec_shim/exec_shim.mli`: config 오류는 파일 부재/파싱/읽기 실패를 포함한다. VM 배포 상태를 확인하지 않고 Keeper 입력 오류로 분류하면 안 된다.
- `lib/dashboard/dashboard_snapshot.ml:247`: elapsed/allocation 진단 로그는 process-wide allocation 차이를 사용한다. profiler 없이 함수별 할당 확정은 금물이다.

## 이미 회복된 것과 남은 것

- installed TUI 80/140열 fixture PTY와 demand recall 714B의 선행 측정은 해당 범위 증거다. 이것으로 전체 fleet 연속성을 증명하지 않는다.
- 10/3 12:11 KST 두 Codex fallback 모델 턴 재검증은 모두 completed였다. 이 증거는 현재 endpoint 응답 가능성을 확인할 뿐 간헐 장애 원인 해결을 증명하지 않는다.
- task_context 누락 및 turn-boundary 오류가 10/2 로그에 존재한다. 이전 binary/과거 데이터 오류를 현재 코드의 재발로 확정하지 않았다. 새 발생 시 runtime SHA, exact trace, producer row를 먼저 고정한다.
- 제품 코드·runtime 설정·Keeper pause·Task 상태는 이 조사에서 바꾸지 않았다. 검증을 건너뛰는 Done 처리, progress 삭제, VM/queue 초기화를 개선안으로 제안하지 않는다.

## 실행 계획과 완료 조건

1. 우선 quota로 막힌 두 Keeper와 검증 lane의 assignment/관측을 묶어 별도 작은 변경 단위로 수리한다. 성공 조건은 실제 기존 pending 항목의 처리 및 verification verdict commit이다.
2. 다음으로 Muse의 effect-uncertain 복구와 missing-fragments 증거 보존을 독립 PR로 다룬다. 성공 조건은 중복 outward effect 없음과 읽지 못한 source의 조용한 소비 없음이다.
3. host/provider 오류 관측과 queue 건강도 표시를 개선한다. provider 장애 재현·회복, 정상 pending, operator pause를 함께 검증한다.
4. VM shim 및 dashboard 성능은 운영 인스턴스/기록량을 고정해 실측한 후 수정한다.

이 문서의 완료는 오류 목록과 근거 있는 개선안의 제출을 뜻한다. 모든 항목의 수리·배포 또는 전체 runtime 정상화는 별도 작업이며 아직 완료되지 않았다.
