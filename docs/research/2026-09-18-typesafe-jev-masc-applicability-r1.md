# TypeSafe Jev(System One) 분석과 masc 판단 레인 적용 가능성 (r1)

- 작성: 2026-09-18
- 근거: [2026-09-18-typesafe-jev-masc-applicability-evidence-record.md](2026-09-18-typesafe-jev-masc-applicability-evidence-record.md)
- 대상 문서: docs.typesafe.ai (introduction / primitives / confidence / patterns / quickstart), typesafe.ai
- 방법: 공식 문서 열람 + masc 코드 탐색(lib/, packages/agent_core/, docs/) + board_attention 판정 replay 실험 35호출(고유 후보 27건)

## 1. TypeSafe Jev 요약

샌프란시스코 소재 TypeSafe AI의 첫 모델. LLM과 달리 텍스트를 생성하지 않고,
상태(state) 텍스트와 타입화된 질문들(questions)을 넣으면 제약된 답(확률 분포)을 반환한다.
API는 `POST https://api.typesafe.ai/v1/systemone`, 모델 `jev-latest`(실측 응답 jev-1.13.0).

| 프리미티브 | 입력 | 반환 | 용도 |
|---|---|---|---|
| Choice | instructions + criteria(라벨↔설명 맵) | choice, probabilities, confidence | 분류/라우팅 |
| Score | instructions + criteria(순서 레벨 배열) | score(레벨 사이 가능), probabilities, confidence | 스펙트럼 측정 |
| Noul | instructions | noul(0~1) | 예/아니오 확률 |

핵심 설계:

- 질문들은 같은 state를 보고 독립·병렬 평가된다. 질문을 추가해도 응답 시간이 거의 변하지 않는다.
  질문 간 컨텍스트 오염이 없다는 뜻이자, 질문끼리 추론을 공유하지 못한다는 제약이기도 하다.
- confidence는 probabilities 분포의 집중도에서 유도된 통계량이지 별도 예측이 아니다.
- 가격: 입력 10억 토큰당 $42. 본 연구 실측 호출당 평균 input 약 1.4k tokens = $0.00006.
- 단일 모델, early access, SLA·자체 호스팅 언급 없음. 능력 들쭉날쭉함(jaggedness)을 다룬 별도 문서가 존재.

### 검증 안 된 주장 (사실과 분리)

- "Claude Fable 5.1 대비 238배 저렴", "193.6배 빠름/444.6배 저렴" — 전부 회사 자체 벤치마크이고 조건이 공개되지 않았다.

## 2. masc 측 탐색 — 같은 패턴이 이미 6개 존재한다

masc은 "구조화된 마이크로 판단"(LLM에 스키마를 주고 타입화된 답을 강제)을 exact-output 레인 체계로
자체 구현하고 있다. 공통 인프라: `lib/keeper/keeper_structured_output_schema.ml`(스키마 집약) +
strict 파서 + slot failover + 측정 영수증.

| 레인/지점 | 위치 | 판단 |
|---|---|---|
| Board attention relevance | `lib/keeper/keeper_board_attention_judgment.ml` — durable FSM `Pending → Judged → Consumed`, 배치 판정, 빈 rationale 거부 | 글이 키퍼와 관련 있는가 |
| Fusion judge/refine/meta | `lib/fusion_core/fusion_policy.ml` — 3x3x3 JOJ, 쿼럼 min_answered | 다중 응답 종합 |
| Librarian current-memory 선택 | exact lane | 어떤 기억을 현재 컨텍스트에 |
| HITL auto-judge 요약 | exact lane | 승인 맥락 요약 |
| Workspace memory curator | `lib/server/server_workspace_memory_curator.ml` | 기억 정리 |
| Task anti-rationalization reviewer | `packages/agent_core/lib/task/` + `lib/eval_calibration.mli` | 완료 주장 검증. 인간 라벨 divergence 캘리브레이션 보유 (#3068) |

레인 열거: `lib/exact_lane_run_registry.mli` (`Librarian | Hitl_auto_judge | Board_attention | Workspace_curator`).

### 이 연구의 기준선이 되는 기존 원칙

1. **"가치 판단은 키퍼(이미 LLM)의 몫, 코드는 구조 안전만"** — RFC-0252 §6. fusion 발동 여부를
   score 비교로 판정하지 않고 키퍼의 호출 자체로 표현한다.
2. **결정론적 코어 보호** — turn FSM, autonomous phase(`lib/autonomous/autonomous_phase.ml`,
   phantom type + TLA 검증)는 전부 결정론. `docs/external-comparison-and-positioning.md`는
   "determinism over speed"를 명시적 트레이드오프로 선언한다.
3. **스트링 분류기 → 타입 교체 궤적** — RFC-0089, RFC-0174, RFC-0421, RFC-0454.
4. **Gate 권위 사다리** — `lib/keeper/keeper_gate.ml`: `Always_allow → Auto_judge → Manual`.
   판단자는 싼 권위(샌드박스 관찰)가 전부 거절한 뒤에만 물음.
5. **확장 비대칭** — 새 provider 종류(provider_kind 닫힌 variant + codec)는 비싸고,
   새 exact-output 레인은 싸다. 판단을 늘리려면 provider가 아니라 레인을 늘린다.

## 3. 적용 가능성

### 3.1 개념이 정면으로 겹친다

TypeSafe의 제안(싸고·제약되고·캘리브레이션된 마이크로 판단)은 masc이 exact-output 레인으로
만든 것의 외주 버전이다. RFC-0042(출력 공간을 타입으로 좁혀 불법 상태를 표현 불가능하게)와
TypeSafe(출력 공간을 API에서 종혀 파싱을 없앰)는 같은 철학의 다른 계층 구현이다.
그래서 질문은 "도입할까"가 아니라 **"레인의 모델을 더 싼 판단 전용 모델로 바꿀 가치가 있나"** 이다.

### 3.2 Jev가 주는 것 / 못 주는 것

주는 것:

- 판당 비용 차이. 본 연구 실측과 원 judge 비용 추정으로 30~250배(원 측정은 없음, 근거 기록 참조).
- probabilities와 confidence가 모델에서 나온다. `lib/eval_calibration.mli`의 캘리브레이션 재료가 된다.
- 파싱 실패가 구조적으로 없다. exact-output의 `Reject_and_advance` 재시도가 필요 없다.

못 주는 것:

- **rationale.** board_attention 파서는 빈 rationale을 거부한다. 판단 근거가 감사 계약인 레인에는
  Jev를 그대로 넣을 수 없다.
- 자체 호스팅, 결정성, 벤더 독립. 판단 대상 상태가 제3자 API로 나간다
  (`docs/KEEPER-SANDBOX-BOUNDARY-POLICY.md`와 충돌 검토 필요).
- 느린 추론. 질문 간 독립 평가는 다단계 추론이 필요한 판단(verification 등)에 구조적으로 부적합하다.

### 3.3 통합 지점별 판정

| 지점 | 판정 | 근거 |
|---|---|---|
| turn FSM / autonomous phase / intake 어드미션 | 부적합 | 결정론 코어. constitution 위반 |
| 키퍼 게이트(외부효과) Auto_judge 단 | 부적합~보류 | 외부 효과를 여는 판단에 early-access 외부 API는 리스크가 과함 |
| Board attention relevance | 조건부 후보 | §4 실험에서 등가성 확인. 단 rationale 계약 때문에 그대로는 안 되고, 스키마에서 근거를 분리하거나 confidence-gated 이중 판단 구조가 필요 |
| Board curation | 가장 자연스러운 신규 레인 | `lib/board/board_curation.ml`이 저장소로만 존재(ordering/highlights/score/rationale 스키마는 있으나 생성 경로가 없음) |
| Anti-rationalization reviewer 대체 | 부적합 | 깊은 검증이라 Jev 범위 밖. 평가자 baseline으로는 유용 |
| 새 provider_kind/api_format 추가 | 비용 비대칭 주의 | 닫힌 variant + codec 비용. 레인 우선 |

## 4. Replay 실험 요약 (상세는 근거 기록)

wkbl 워크스페이스 board_attention 후보 중 기존 judge 판정이 있는 고유 후보 17건(전부 relevant)과
합성 negative 대조군 10건을 실 API로 재생했다. 판정 원장이 후보 8건을 두 줄씩 담고 있어서
historical 쪽 호출은 25번이다. baseline에 음성이 0건이라 specificity 측정을
위해 대조군을 만들었다.

| 항목 | 결과 |
|---|---|
| Historical 재생(고유 후보 17건, 호출 25번) | 기존 judge와 합의: 호출 25/25, 후보 17/17 |
| 합성 negative 10건 | specificity 10/10 (전부 not_relevant 정판) |
| Noul↔Choice 교차 일관성 | 호출 35/35 |
| 비용 | 총 input 48,742 tokens = $0.002 (호출당 $0.00006) |
| 지연 | 평균 0.66s / 최대 1.03s (클라이언트에서 잼, 호출마다 새 연결) |
| 에러 | 0건 |

경계선 관측: 명백한 negative 8건은 confidence 0.99~1.0 / noul 0.03~0.16 이었고,
가장 어려운 negative("다른 프로젝트의 Railway 상태 이야기", 주제는 인접하나 keeper 업무와 무관)가
confidence 0.55 / noul 0.39 로 가장 낮았다. 다른 경계선 negative(다중 에이전트 프레임워크 잡담)는 0.99 였고,
historical relevant 한 건(`7881ef0a…`)도 0.83/0.84 로 내려갔다. 35호출 전부가 기준선과 일치해
틀린 답이 없으므로, 이 표본으로는 confidence 가 정답률과 맞는지(캘리브레이션)를 잴 수 없다.

### 실험의 한계

1. Baseline이 전부 relevant였다. 합성 negative로 보완했으나 합성이 실제 negative보다 쉬웠을 수 있다.
2. 합의는 정확도가 아니다. 인간 라벨 ground truth가 없다(board_attention엔 없고
   anti-rationalization 라벨은 4건뿐). 기존 judge가 틀린 곳에서 Jev가 같이 틀렸을 가능성은 배제 못 한다.
3. 원 judge의 판정당 실제 비용은 미측정이다(`.masc/exact-lane-runs-v5.jsonl`이 등록 이벤트
   로그라 usage가 없음). 30~250배는 일반 LLM 가격 대입 추정이다.
4. 재현은 원 judge 프롬프트 원문이 아닌 근사 재구성이다(배치 구조, 스레드 컨텍스트 차이 가능).

### 결론

"Jev가 정확하다"가 아니라 **"이 질문 모양에서 Jev의 판정이 기존 전체-LLM judge와
일치하며, 비용은 자릿수 아래"**가 확인됐다. board routing이 이미 Unlisted를 사전 필터링해
judge 도달 집단이 예비선별되어 있으므로(`lib/keeper/keeper_board_audience.mli`),
confidence가 높으면 통과·낮으면 기존 judge로 올리는 이중 판단 구조가 자연스러운 후속이다.

## 5. 리스크

- early access 단독 벤더, 단일 모델, SLA 없음. 검증 안 된 자체 벤치마크.
- 데이터 반출: 판단 대상 상태가 외부로 나간다. 본 실험에서도 요청 35번이 나갔고, 그중 25번에 wkbl board 원문(고유 후보 17건)이 실렸다.
- jaggedness: 능력이 작업류별로 고르지 않다. 도입 전 우리 판단 분포에서의 replay 측정이 유일한 근거다.
