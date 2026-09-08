# 맡긴 변경의 완료·복구·규모 확장 로드맵

상태: 개발 계획. 성공 조건은 목표이며, 현재 달성했다고 주장하지 않는다.
작성: 2026-09-09. 조사 기준 소스: `d01b7bfb077439d50624986cb84669e0d005abfb`.

## 제품 약속

**맡긴 변경을 끝까지 확인하고, 끊기면 적용된 결과부터 확인해 남은 작업을 이어간다.
이 보장을 유지하며 더 많은 작업을 동시에 처리한다.**

Keeper·Task·Goal·Skill·composition·MCP는 이 약속을 수행하는 내부 수단이다.
사용자는 요청, 완료 조건, 결과와 근거, 남은 문제, 자신이 결정할 사항을 확인할 수 있어야 한다.
Scale-out은 검증된 완료 처리량을 높이는 기능으로 개발한다. 실행 중 에이전트 수는 성과가 아니다.

이 문서는 개선 순서와 Goal acceptance의 정본이다. 제품·개발 원칙은
[constitution.xml](constitution.xml), 릴리스 편성은 [VERSIONED-ROADMAP.md](VERSIONED-ROADMAP.md)를 따른다.
런타임 Goal에는 현재 착수한 범위만 등록한다. 미래 Goal을 전부 executing으로 만들지 않는다.

## 현재 연결과 부족한 부분

| 영역 | 재사용할 구현 | 이번 로드맵에서 보완할 것 |
| --- | --- | --- |
| 변경의 실행 | Keeper의 기존 tool dispatch·sandbox·Gate | 명령 응답, 외부 효과, acceptance 결과를 구분해 Task 결과까지 연결 |
| 절차·합성 | Instruction/Composition Skill, typed plan, batch 실행 | 실제 선택·결과 측정; 고정 workflow부터 재개 위치와 대상 확인 연결 |
| 복구 | 승인 소비·replay·indeterminate, Keeper 지속 상태 | 효과 이후 crash window의 대상 조회와 다음 단계 재개 |
| 병렬 처리 | dependency graph와 Eio batch 실행 | 의존성이 준비된 작업의 실행, 충돌 소유권, 공통 검증, 장애 격리 |
| 결과 확인 | Task·Goal verifier, run/turn/receipt | 요청·attempt·수정 revision·대상 결과·독립 검증 사이의 정확한 연결 |
| 측정 | coding harness와 cost ledger | 현재 null인 harness usage의 실제 관측 연결; 실패·재시도 비용 포함 |
| 사용자 경험 | TUI, Dashboard, MCP | 요청별 완료/복구/결정 필요 상태와 근거를 한 곳에서 보여 줌 |

현재 async composition은 read-only이며, inline composition에는 영속 node cursor가 없다.
`Completed`/`effect=applied`는 업무 성공 판정이 아니다. 이 제약을 숨기는 홍보 문구는 쓰지 않는다.
근거: [async admission](../lib/keeper/keeper_tool_composition_catalog.ml),
[composition boundary](../lib/keeper/keeper_tool_composition_surface.ml),
[replay](../lib/keeper/keeper_gate_replay.ml), [coding harness](../scripts/harness_coding_eval.sh).

## Goal 진행 방식

| Goal | 완료했을 때 사용자가 얻는 것 | 의존 관계 | 현재 |
| --- | --- | --- | --- |
| G1 결과와 측정 연결 | 무엇이 실제로 끝났고 무엇을 확인하지 못했는지 알 수 있음 | 시작점 | 첫 Task 착수 대상으로 등록 |
| G2 두 단계 변경의 중단 복구 | 적용한 변경을 확인하고 중복 없이 남은 단계 진행 | G1 | 계획 |
| G3 담당·모델 전환 뒤 연속성 | 에이전트가 바뀌어도 소유권과 증거가 이어짐 | G1·G2, 기존 tool-continuity Goal 재사용 | 계획 |
| G4 검증된 규모 확장 | 충돌·장애를 포함해 동시 작업 처리량을 확대 | 계측은 G1부터 병렬 가능; 완료 판정은 G2·G3 이후 | 계획 |
| G5 제품 경험과 공개 증명 | 설치 후 같은 데모를 재현하고 보장의 범위를 확인 | UI 설계·문서 초안은 병렬; 공개 보장은 해당 Goal 실측 이후 | 계획 |

각 Goal은 implementation / CI / isolated live / destination acceptance / UI / human review를
따로 기록한다. 해당 없는 항목에는 이유를 명시한다. PR 수, 테스트 파일 수, tool 호출 수로
제품 Goal을 닫지 않는다. 성공 조건 변경은 새 contract revision과 재측정을 요구한다.

Goal 완료 요청은 원시 증거를 보존한 뒤 verifier에 제출한다. 사람이 결과를 확인한 기록도 남긴다.
현재 런타임의 proof-proven 상태가 사람의 최종 확인을 강제한다고 가정하지 않는다.

## G1 — 요청부터 검증 결과까지 측정이 끊기지 않는다

Runtime Goal ID: `goal-reliable-change-g1-20260909`. 첫 구현 Task: `task-1478` (등록 시 todo).
[등록 당시 readback](evidence/reliable-change-roadmap/activation.json)은 실행 결과가 아니다.
정의 정본: [G1 acceptance contract](roadmaps/reliable-change-g1.json).

범위는 기존 coding harness와 run/turn/request/cost ledger의 연결이다. 새로운 실행 엔진을 만들지 않는다.
다음 여섯 사례를 각각 3회 실행한다. 3회는 잘못된 재사용·누적 집계를 찾는 소규모 반복이며
품질 우위의 통계적 증거가 아니다. 필수 실행은 18개이고 반복 ID가 서로 달라야 한다.

| 사례 ID | 입력 조건 | 기대 결과 |
| --- | --- | --- |
| success | 같은 revision의 변경·외부 검증 성공 | 해당 요청·revision만 verified로 연결 |
| exit-nonzero | 도구 호출은 완료됐으나 명령 exit 1 | 도구 완료를 업무 성공으로 승격하지 않음 |
| stale-revision | 성공 증거가 요청과 다른 revision | 현재 작업의 성공 증거로 채택하지 않음 |
| missing-artifact | 검증할 산출물이 없음 | 미검증/거절로 남기고 성공 집계에서 제외 |
| retry-success | 첫 attempt 실패, 다음 attempt 성공 | 양 attempt 관측·비용을 보존하고 최종 결과만 한 번 연결 |
| usage-unreported | provider가 usage를 보고하지 않음 | null 및 미보고 이유를 보존; 비용 0으로 보간하지 않음 |

관측 행은 요청/Task, run/turn/provider attempt, source·binary·model 설정, artifact revision,
검증 실행, 결과를 연결한다. 해당 사례에 없는 엔티티는 명시적 not-applicable로 나타내며
임의 ID나 가짜 usage를 만들지 않는다. 사례별 필수/applicable 엔티티와 phase 경계는
실행 전 manifest에서 고정하며 관측 행이나 checker가 사후에 면제하지 못한다. queue/model/tool/verification/cleanup의 시각을 구분하고,
누적 usage를 더해 이중 청구하지 않는다. 비용 미보고도 측정 범위의 일부다.

측정 입력은 manifest를 실행 전에 고정하고 해시를 보존한다. 기대 결과는 모델 출력에서 만들지 않는다.
독립 checker가 원시 관측과 artifact/command outcome을 대조한다.
여섯 사례 중 usage 미보고는 통제된 provider 응답으로 재현할 수 있으며 real-model 측정과 구분한다.
별도로 실제 설정 provider의 positive/negative/retry 실행을 1회씩 남겨 native wiring을 확인한다.
이는 비교 성능 실험이 아니다.

증거 위치: Goal verifier의 playground root 기준 `reliable-change-evidence/g1/`.
`contract.json`, `summary.json`, `manifest.json`, `runs.jsonl`, checker 출력,
원시 증거의 경로·해시를 보존한다. 최초 summary는 `not_run`이며 성공 수를 추정하지 않는다.

완료 목표: 필수 18개 전부 일치, 별도 real-model 3개 전부 관측 연결,
잘못된 성공 0, 필요한 연결 누락 0, 미보고 usage를 0으로 변환한 행 0,
같은 비용의 중복 합산 0. 관측되지 않은 비율·금액은 null이다.
`retry-success`의 통제 fixture는 실패 request, 성공 request의 누적 snapshot 두 개,
verifier request를 제공한다. 합계는 input 40 / output 8 / cache-read 8 tokens / USD 0.07이다.
정확한 원시 값은 JSON contract에 있고 합계 불일치도 0이어야 한다.
모두 null을 반환하는 구현은 통과하지 않는다. 이 수치는 실제 provider 청구액이 아니다.

첫 Task: 여섯 사례 manifest 및 observation checker를 고정하고 기존 harness의
run/turn/request/attempt 및 usage 연결을 구현한다. 새 runtime budget gate는 추가하지 않는다.
다음 Task는 CI 바이너리로 위 18+3 실행을 수행하고 증거를 제출한다.

## G2 — 고정된 두 단계 변경이 중단 뒤 수습된다

범위: 격리된 Git 원격에 branch를 게시하고, 그 revision의 검증 산출물을 별도 단계로 게시하는
고정 workflow 하나. 작업 ID·plan revision·목적지를 첫 효과 전에 영속화한다.
제품에 GitHub PR 데모를 추가할 때는 사용자가 지정한 시험 저장소에서만 별도 수행한다.
임의 shell 명령이나 일반 DAG의 자동 복구는 이 Goal의 보장 범위가 아니다.

필수 fault matrix는 다음 6개 × 3회 = 18개다.

| ID | 중단/장애 지점 | 기대 상태 |
| --- | --- | --- |
| before-dispatch | 첫 효과 dispatch 전 서버 중단 | 재시작 후 정상 두 단계 완료 |
| first-effect-unrecorded | 첫 효과 적용 후 settlement 기록 전 중단 | 대상 조회로 첫 효과 확인, 중복 생성 없이 다음 단계 완료 |
| between-steps | 첫 settlement 이후 둘째 dispatch 전 중단 | 첫 효과를 반복하지 않고 둘째 완료 |
| second-effect-unrecorded | 둘째 효과 적용 후 settlement 기록 전 중단 | 목적지 확인으로 완료 복구 |
| readback-unavailable | 복구 대상 조회 권한 거절/응답 실패 | unknown 유지, 완료 주장·임의 효과 재실행 없음 |
| readback-conflict | 대상 revision이 고정 intent와 다름 | 충돌과 결정 필요 상태, 이전 성공 증거 재사용 없음 |

목표: 18/18 기대 상태 일치; 복구 가능한 첫 네 사례 12/12 목적지 확인 완료;
나머지 6/6은 명시적으로 미완료; 중복 효과·잘못된 완료·관측 유실 0.
문서의 exactly-once 표현 대신 식별 가능한 효과의 재확인과 불확실성 보존 범위를 명시한다.
각 지점은 실제 dispatch/receipt 경계의 barrier로 주입하고 잠깐 sleep 뒤 kill하는 추측은 쓰지 않는다.
완료 기록만 저장하고 effect 이후 기록 전 crash를 빼면 통과가 아니다.
목적지 상태와 별도의 dispatch/application 기록을 함께 검사한다. 같은 ref로 중복 push한 것을
최종 상태가 같다는 이유로 중복 없음으로 세지 않는다. 확인된 효과의 불필요한 재dispatch도 0이어야 한다.
측정 파일: `reliable-change-evidence/g2/summary.json`과 목적지 readback 원문.

## G3 — 담당자와 모델이 바뀌어도 같은 변경을 이어간다

기존 `goal-tool-continuity-20260907`의 도구/모델 전환 증거를 재사용한다.
기존 Goal의 성공 조건이나 담당 작업을 덮어쓰지 않는다. 이 제품 workflow의 부족한 사례만
해당 Goal에 연결된 Task로 보완하며, 기존 Goal 전체 완료와 G3 행렬 완료를 구분한다.

G2의 workflow를 유지한다. provider families 두 개를 사전 manifest에 실제 가용 설정으로 고정하고
A→B, B→A 두 방향 × 아래 5개 상황 × 3회 = 30개를 실행한다.

1. 첫 효과 전 provider 실패: 같은 intent로 successor 진행.
2. 첫 효과 확인 후 provider 실패: 확인된 단계 반복 없이 진행.
3. 효과 불명 상태에서 실패: successor도 readback부터 수행.
4. ownership 이전 뒤 이전 담당자의 늦은 응답: 새 mutation/완료 권한 없음.
5. 승계 중 권위 있는 최신 상태 읽기 실패: stale snapshot으로 mutation 승인하지 않음.

목표: 30/30 기대 상태 일치, 중복 효과·stale-owner mutation·evidence 오귀속 0.
사례 1~4는 목적지 조회가 가능한 fixture로 고정하여 최종 완료 24/24를 요구한다.
사례 3은 unknown을 승계한 뒤 조회로 해소해야 한다. 사례 5의 6회는 명시적인
결정 필요/unknown 상태가 정답이며 성공 분자에 넣지 않는다.
Tool 기록을 서로 다른 model attempt에서 섞어 한 번의 성공으로 주장하지 않는다.
증거에는 실제 provider/model identity, ownership 전이, 승계 전후 context와 목적지 확인을 연결한다.
측정 파일: `reliable-change-evidence/g3/summary.json`.

## G4 — 정확성을 유지한 scale-out을 측정한다

같은 호스트의 동시 실행과 여러 호스트의 분산 실행을 구분한다.
첫 qualification 범위는 실제 workers 1/2/4/8이며, 그 결과가 64 workers 지원을 뜻하지 않는다.
16/32/64 및 다중 호스트는 첫 결과와 bottleneck 분석을 바탕으로 manifest를 확장하는 후속 Goal이다.

정확성 workload 네 개: independent(서로 다른 대상), contended(같은 파일/branch),
integration(공통 최종 검증), worker-failure(한 실행자 실패 후 소유권 복구).
고정한 16개 작업 묶음을 각 workload·worker 수에서 3회 실행한다: 4×4×3 = 48 campaign cells.
작업 16개는 8 workers에서 한 번의 할당으로 끝나지 않게 하는 첫 qualification 규모다.
이 48개는 C(MASC)의 정확성 qualification이다. 각 셀의 16개 작업 중 independent,
integration, worker-failure는 16/16 검증 완료를 요구한다. contended는 호환 가능한 12개 완료와
의도적으로 충돌시킨 4개 결정 필요 상태를 요구한다. 전체 768개 제출 중 기대 완료는 720개,
기대 미완료는 정확히 48개다. 해당 작업 ID와 충돌/장애 주입 지점은 본 실행 전에 manifest로 고정한다.
일괄 unknown 처리로 정상 작업의 완료 의무를 면제하지 못한다.

최초 목표: 48/48 campaign cells의 외부 acceptance 일치, 중복 효과·stale-owner mutation·
잘못된 완료 0. 충돌·해소 불가능한 실패는 사전 계약의 명시적 미완료 상태로 집계한다.
미완료를 처리량의 완료 분자에 넣지 않는다. 장애가 없는 작업의 진행·지연도 따로 기록한다.

같은 모델/도구/권한으로 A(강한 단일 agent+batch/scripts), B(scripted parallel),
C(MASC)를 비교한다. 같은 MASC의 1-worker 결과만 비교해 제품 우위를 주장하지 않는다.
성능 비교는 위 48개와 별도의 manifest에 arm/task/repeat를 전수 열거한다.
A는 1-agent, B/C는 1/2/4/8 workers로 동일 16개 작업 묶음과 workload 네 개를 각각 3회 수행한다.
따라서 비교 coverage는 A 12셀 + B 48셀 + C 48셀 = 108셀이다.
C qualification 48셀은 같은 frozen manifest·환경인 경우 이 108셀 안에서 재사용할 수 있다.
평가 작업 목록, baseline 명령, cache 정책, 실행 순서를 고정하고 재시도·실패·setup 및 사람 개입을 포함한다.

G4는 두 결과를 분리한다.

- **측정 완료:** 모든 필수 셀과 A/B/C 비교 원시 증거, verified completions/elapsed time,
  전체 소비 비용과 미보고 비율, 사람 개입, 재작업, queue 및 p50/p95 지연을 기록.
- **확대 판단:** pilot 이후 held-out 평가 전에 주 지표·최소 효과 크기·품질 허용 범위를 고정한다.
  기준을 넘지 못하면 measured_no_advantage로 기록하고 bottleneck에 맞춘 다음 작업을 정한다.
  측정 완료를 성능 우위의 성공으로 바꾸지 않는다. 수치 미정이면 확대 Goal은 활성화하지 않는다.

G2/G3 전에 정상 실행 throughput 실험을 병렬로 할 수 있지만 복구와 안전한 scale-out 보장은
G2/G3 증거가 필요하다. 다중 호스트 확대에서는 네트워크 단절, 이전 worker의 늦은 재접속,
서로 다른 서버의 동시 claim을 추가해야 하며 이들은 최초 48개에 포함됐다고 주장하지 않는다.
측정 파일: `reliable-change-evidence/g4/summary.json`과 raw campaign table.

## G5 — 킬러 기능을 제품 안팎에서 재현 가능하게 보여 준다

개발할 핵심 장면은 하나다: **변경 요청 → 실제 변경 → 중단 → 적용 결과 확인 →
다른 담당자/모델이 이어서 처리 → 독립 검증 결과**.
TUI에서 요청별 진행, 완료 근거, 복구 중인 지점, 사람의 결정이 필요한 이유를 읽을 수 있어야 한다.
Dashboard는 같은 상태를 사실대로 보여 준다. Agent 수나 내부 tool 개수를 첫 성과로 내세우지 않는다.

필수 사용자 시나리오 다섯 개: 정상 완료 / 중단 후 복구 / provider 전환 /
증거 부족으로 미완료 / 병렬 작업 충돌. 공개 바이너리 설치 경로에서 5/5를 재현한다.
각각 TUI capture, 같은 원장에 연결된 브라우저 screenshot, 원시 실행·목적지 확인을 남긴다.
상태·revision·결과의 UI↔원장 불일치는 0이어야 한다.

영문·한국어 README/사용 가이드에 동일한 범위표와 실행 명령을 제공한다.
공개 주장은 각각 binary/source/config revision, 비교 조건, 원시 증거 링크에 연결한다.
미측정 성능/복구 주장 0, 결과 링크 없는 정량 주장 0. 사용자 최종 확인 기록 1건을 남긴다.
현재 README에는 이 방향이 개발 목표임을 밝히고 로드맵으로 연결한다.
측정 파일: `reliable-change-evidence/g5/summary.json` 및 demo bundle.

## 기존 Goal과의 관계

| 기존 Goal | 이 로드맵에서 쓰는 범위 |
| --- | --- |
| goal-tool-continuity-20260907 | G2/G3의 기존 도구·provider 전환 증거; 미완료 기능을 완료로 계승하지 않음 |
| goal-measurement-honesty-20260828 | G1/G4의 실제 관측·시간·누락값 규칙 |
| goal-verdict-authority-20260828 | G1/G3의 요청에 결속된 독립 판정 |
| goal-r07-durable-ownership-20260829 | G2/G3의 저장 책임·수명·참조자 |
| goal-queue-receipt-lifecycle-20260828 | G2/G3의 배포·종료 시 pending evidence 보존 |

다른 Goal의 소유권과 acceptance는 그대로 존중한다. 관련 PR은 실제 head/changed files를
확인한 뒤 재사용한다. 이름이 비슷하다는 이유로 별도 구현하거나 다른 담당자의 Task를 가져오지 않는다.

## 실행 순서와 범위

각 Task/PR은 한 가지 관측 가능한 변화를 끝내는 단위로 나누고 constitution의 20k output 범위를 따른다.
G1 Task의 계측 작업과 G2 설계, G5 정보 구조 초안은 독립적으로 진행할 수 있다.
이전 변경에는 적대적 리뷰를 붙이고, 지적은 구현 또는 범위·증거 수정으로 해결한다.
로컬 Dune 빌드는 하지 않는다. CI는 완료 경계에 실행하며 watch/wait polling으로 시간을 보내지 않는다.

새 runtime budget/deadline gate, 임의 agent-count 최적화, 범용 compiler, 전사 gateway,
임의 shell 효과의 자동 재실행은 이 로드맵의 선행 조건으로 넣지 않는다.
비용·시간은 측정하고 비교하되 누적 숫자로 Keeper 상태를 종료하지 않는다.
