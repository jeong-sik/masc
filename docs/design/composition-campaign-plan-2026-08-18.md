# Composition Campaign Plan (2026-08-18)

Keeper 연속성 캠페인의 다음 단계와 Tool 합성 도약의 실행 계획. 7개 병렬 정찰(코드베이스 5축 + 논문/제품 연구 2축) 결과를 종합한 갭/액션 매트릭스이며, 각 실행 케이스마다 서로 다른 접근법 3개와 권장안을 명시한다.

- 정찰 기준: server v0.23.0, commit `03920433d0`, :8935 live (2026-08-18 22시 KST 실측 포함)
- 시각 자료: [갭/액션 매트릭스 아티팩트](https://claude.ai/code/artifact/09e17492-f9a2-4d75-9ce5-6dff4ef36872)
- 관련 SSOT: `docs/design/keeper-feature-state-matrix-2026-08-13.html`(기능 매트릭스), `docs/KEEPER-FULL-FEATURE-GOAL.md`(조사 방법), `docs/VERIFICATION-MATRIX.md`(검증 계층)

## 1. 현황 스냅샷

제품 성공 4축 중 3축은 캠페인 실측으로 닫혔다.

| 축 | 상태 | 근거 |
|---|---|---|
| ① 턴 연속성 | 닫힘 | 10T→1h→2h→4h→24h ladder 전 구간 완주 (M4) |
| ② 턴 간 기억 | 닫힘 | RW11 durable memory, RW18 재시작 걸친 11연결 턴 — 양 라운드 pass |
| ③ Keeper 간 소통 | 닫힘 | RW02 goal 공유, RW04 board comment 핸드오프 pass |
| ④ 맥락 기반 표면 선택 | 부분 | Connector 라우팅의 live/browser 증거 축 결손 |

핵심 수치: E0 대표 실측 r6 15/19 (r7 11/19은 표본 분산 — 재실행으로 점수를 쫓지 않는다) · 시나리오 12행 중 실측 1행 · composable 출력 도구 12개 · Concurrent 도구 28개(08-20 재실측) · evidence 축 결손 37/46행 · 10T 런타임 스윕 31/49.

핵심 판단: **합성 인프라는 신규 개발이 아니라 개봉 대상이다.** typed DAG 플랜(`keeper_tool_plan`), 실행기(`keeper_tool_plan_executor`), TOML 카탈로그, async 브로커(`keeper_msg_async`)까지 프로덕션에 살아 있고, 당일 `keeper_compose_mission-snapshot` 호출 65건이 스토어에 기록되어 있다. 막는 것은 아래 세 병목이다.

## 2. 갭 매트릭스

### D1. Tool 합성

| 갭 | 심각도 | 액션 | 케이스 |
|---|---|---|---|
| 합성 실행 도구가 정적·무인자 — 모델 입력 스키마가 빈 closed object (`keeper_tool_composition_surface.ml:4-11`; status/cancel 제어 도구는 request_id 인자를 받으므로 해당 없음) | HIGH | 턴 타임 플랜 정의/파라미터화 경로 개설 | A1 |
| ~~composable 출력 3개뿐~~ → **A2-1 착륙 (#29012), 08-20 실측 12개**. 남은 병목은 개수가 아니라 대상: `web_search`·`web_fetch`·`keeper_memory_search`가 여전히 Opaque라 검색·회상 결과를 다음 노드로 흘릴 수 없다 | HIGH | 시나리오가 요구하는 도구부터 스키마 부여 | A2 |
| ~~Concurrent 선언 2개뿐~~ → **A3-1 착륙 (#29017), 08-20 실측 28개**(명시 19 + board read 자동 9). 남은 미해결은 선언과 실행의 불일치 — 런타임이 Serial 선언 도구를 배치하는 이유가 미판정(#29068 본문, #26516) | MED | 원인 진단 후 결정 | A3 후속 |
| Tool Group은 표시 메타데이터일 뿐 실행 문법에 없음 (`keeper_tool_plan.mli:1-4`) | MED | A1 플랜 경로에 흡수 | A1·A4 |
| 합성 중첩 불가, async 플랜 전 노드 read-only 강제, deferred 노드가 플랜 종료 | MED | A1 안착 후 단계 해제 (measure-first) | A1 후속 |
| CLI 런타임(Claude Code·Codex)은 vendor 루프가 도구 반복 소유 — 배치 의미론 미적용. 합성 도구는 콜백 1회라 통함 | LOW | 합성이 CLI 런타임의 병렬화 우회로임을 실측 | A1 |

### D2. 시나리오 커버리지

| 갭 | 심각도 | 액션 | 케이스 |
|---|---|---|---|
| 시나리오 12행 중 11행 NOT RUN — 미션 카탈로그(RW01–19)에 제품 시나리오 미션 부재 | HIGH | missions.json 확장, 근접 행(PoC·상호 반론)부터 | B1 |
| Web/Browser keeper 도구 0건 — 4행 차단 (web_fetch는 정적 HTML만) | HIGH | 웹 검색/브라우저 도구 신설 | B2 |
| RW17 합성 exactly-once 위반 지속 (#28977, builder-b 무귀속 행 2라운드 재현) | HIGH | 귀속 누락 근본 원인 확정 후 수리 | B3 |
| RW19 tier 투영이 공유 fleet에서 구조적 실패 (격리 전제) | MED | 격리 러너 설계 결정 | B4 |
| 10T 런타임 스윕 31/49 (codex 쿼터 대기, mlx/local GPU 미스케줄, gpt-oss #28967) | LOW | 사유별 순차 재개 | B5 |
| feature 46행 중 37행 evidence 축 결손 (browser ~17행, duration ~10행) | MED | B1/B2 미션이 축을 채우도록 미션-축 매핑 | B1 |

### D3. 라이브 런타임 결함

| 갭 | 심각도 | 액션 | 케이스 |
|---|---|---|---|
| sangsu 실효 런타임이 운영 의도(deepseek)와 모순 — shadow lane 첫 후보가 glm이라 glm에서 turning (22:01 로그 실측) | MED | lane 정의 의도 정렬 | C1 |
| llama_cpp :9010 다운 — head로 둔 keeper 2개가 매 턴 조용히 failover (latency 684s 기록) | MED | 재기동 또는 lane 제거 | C1 |
| wire-capture 일일 상한 도달로 레코드 드롭 진행 중 (18:35 boot 로그 반복 WARN). 현재 256MiB는 env 오버라이드 값, 코드 기본은 64MiB (`env_config_keeper.ml:85`) — 수리 시 이 SSOT 기준 | MED | 드롭 대신 파일 회전 | C2 |
| 검증 리뷰 retryable=false 종결 시 영구 정지 — 표면이 registry 행뿐 (`verification_run_registry.mli:14-24`) | MED | 정지 리뷰 board 표면 + 재제출 경로 | C3 |
| 토큰 추정 String.length/4+4 (CJK 과소), proactive 유사도 word Jaccard (spec §15 자인 부채) | MED | **전제 소멸 확인 (2026-08-19)**: Jaccard 유사도 게이트는 #27478(2026-08-08)이 proactive Quality Gate 전체와 함께 이미 삭제. `/4` 토큰 추정기는 현재 lib/ 어디에도 없음(`/ 4`·`asr 2`·`token_estimate` 계열 전수 스윕 + `git log -S` 역추적). Memory OS 예산은 `keeper_memory_os_budget.ml`이 정확한 렌더링 바이트를 세고, window-fit oracle은 provider로 이미 이관됨. 남은 액션 없음 | C3 |
| Memory OS 잠금 경로 `.lock` 이중 append — `*.lock.lock` (`keeper_memory_os_current.ml:539,550`) | LOW | lock_path 일원화 | C3 |
| goal reconciliation 부팅마다 e0 goal 3건 ambiguous 실패 · taskmaster paused인데 hourly wake 발화 | LOW | 잔여 상태 정리 | C4 |

### D4. 대시보드 관측성

| 갭 | 심각도 | 액션 | 케이스 |
|---|---|---|---|
| 클라이언트 디코더가 기록 필드 대량 폐기 — runtime_contract·action_radius·route_evidence·thinking 설정·prompt_fingerprint (`dashboard-keeper-tool-calls.ts:95-143`). 서버는 그대로 서빙 | HIGH | 디코더 복원 | A5 |
| 합성 run의 시각 중첩 없음 — occurrence 텍스트 한 줄 | MED | 합성 트리 렌더 (W1 PR-3에서 선행 — A1 출하 전에 관측이 준비되어야 함) | A5 |
| agent-core-events(당일 tool_called/completed 각 4,266건 + turn_ready 로스터)에 대시보드 리더 전무 | MED | Acting 표면 신설 | A5 |
| raw trace 뷰어 없음 — turn record의 ref가 텍스트 라벨로만 렌더 (`keeper-turn-inspector.ts:988`) | MED | ref → 열람 뷰어 연결 | A5 |
| 자율 턴 thinking 사후 재구성 불가 (trajectory는 char_count만 — 설계 의도이나 runaway 포렌식 차단) | MED | 보존 정책 재결정 | A5 결정 |
| fleet 도구 통계 메모리 집계 — 재시작마다 증발, durable store는 3필드 | LOW | durable 집계 교체 | A5 후속 |

### D5. 죽은 개념 척살

| 갭 | 심각도 | 액션 |
|---|---|---|
| recall_injections 스토어는 죽었는데(#26952) RFC-0264가 그 ledger 기반 eval을 여전히 처방 | MED | 디렉터리 삭제 + RFC 폐기 또는 Memory OS 기준 재작성 |
| RFC-0283·RFC-0284 Draft 표기인데 구현은 출하·라이브 | LOW | 상태 정정 |
| keeper TOML 129개 중 ~100개, runtime.toml 배정 130행 중 ~110행이 사망 잔재 | LOW | 페르소나 외 삭제 (마이그레이션 없이) |
| autonomy_stats.jsonl 13일 정지 · board_attention retired-v3 디렉터리 잔존 | LOW | 배선 확인 완료 (2026-08-19): `autonomy_stats`는 lib/bin/scripts/dashboard 어디에도 producer/reader가 없고(마지막 기록 08-05), `board_attention_candidates-retired-v3-20260814`는 리포 참조 0. 둘 다 삭제 확정 — live store 삭제는 세션 권한 분류기가 차단하므로 운영자가 base path의 `.masc/` 아래에서 `board_attention_candidates-retired-v3-20260814` 디렉터리와 `autonomy_stats.jsonl`을 1회 삭제 |

## 3. 실행 케이스 — 각 접근법 3개

권장안은 `→` 표시. 나머지 접근법은 채택하지 않은 이유와 함께 기록해 재탐색을 막는다.

### Track A. Tool 합성 도약

**A1. 모델 주도 합성** (HIGH)
1. 카탈로그 입력 개방 — TOML에 typed input 스키마 선언, 노드 args가 `/inputs/*` 포인터 참조. 플랜 저자가 여전히 운영자라 목표에 미달, A1-2의 디딤돌.
2. → **`masc_plan_execute` 단일 composite tool** — 모델이 `[{id; tool; args($ref); after}]`를 턴에 내면 기존 `keeper_tool_plan` validator로 typed DAG 파싱(미지 도구·미결속 참조·순환은 파싱 거부), executor가 한 액션에서 실행. ReWOO-flat으로 시작, 측정이 요구할 때만 DAG 확장. 근거: LLMCompiler(ICML'24)·ReWOO. MCP 스펙이 wire 배칭을 제거(2025-06-18)했으므로 합성은 정확히 이 층이 맞다.
3. code-as-action 레인 — registry에서 typed binding 기계 생성 + isolate 실행 (CodeAct·Code Mode·Anthropic PTC). 천장 최고이나 샌드박스 경계와 하네스 선행 필요. A1-2 부족이 측정으로 확인된 뒤.

**A2. composable 출력 3 → 전면** (HIGH)
1. → **read-only 핵심 수작업 선언 (1차)** — 실제 출력 구성 코드와 대조 검증한 수기 스키마. 구조화 출력(success_data) 도구 5곳이 최우선 후보.
2. 인코더 기계 유도 codemod — **반증됨** (#29007 적대적 리뷰): 파생 원천이 될 typed encoder 층이 존재하지 않는다. 기존 composable 3개도 수기 스키마이고 출력 경로는 success(평문 문자열) 29곳 vs success_data(구조화) 5곳. encoder 층이 A2-3으로 생긴 뒤에만 재검토.
3. **producer 계약화 (근본, 2차)** — 도구 반환을 typed value로 계약화하고 스키마는 타입에서 유도. 전수 커버리지로 가는 실경로. A2-1 이후 점진 전환.

**A3. Concurrent 2 → readonly 전면** (HIGH)
1. → **readonly 서술자 일괄 승격** — 핸들러 동시성 안전성 감사 후 `ordinary_execution_mode:Concurrent`. 독립 read-only 병렬·부작용 직렬 원칙(Anthropic parallel tool use와 동일).
2. call-set 단위 판정 — 자원 접근 분석기가 새 복잡도. A3-1로 대부분 회수 후 재평가.
3. async 브로커 오프로드 — 턴 밖 병렬. 즉시성 fan-out엔 부적합, A3-1과 상보.

**A4. Tool 표면 정책·맥락 절감** (MED)
1. ~~policy-before-schema~~ — **전제 감사 결과 기각 (2026-08-19, W2 PR-6 자리에서 판정)**. 사전 계산으로 걸러낼 "런컨텍스트상 결정적으로 거부될 도구"가 현재 keeper bundle에 존재하지 않는다: 정적 배제(Operator_only·Transport_alias·invalid-schema)는 `Keeper_tool_descriptor.model_visible_descriptors`(keeper_tool_descriptor.ml:2071)가 이미 수행하고, sandbox factory는 keeper bundle이 항상 생성하며(keeper_tools_agent_core_bundle.ml:63), web_search/web_fetch·masc dispatch는 전 keeper에 배선 완료(keeper_tool_runtime.ml:305-324). 근거로 삼았던 실측 99/122는 인자 수준 거부라 스키마 미전송으로 막을 수 없다(그 축은 A4-3 input_examples·plan 도구 문법 교육이 담당). 제거할 거부가 없는 필터는 투기적 게이트다 — §4 "하지 않는 것"의 하드 게이팅 금지에 스스로 걸린다. **구현 심(seam)은 이미 존재**: `compute_tool_surface`(keeper_run_tools_setup.ml:429)가 매 턴 schema_filter를 계산하며 지금은 전체 통과 상수다. 재개 조건: lane별 도구 권한 축소, 또는 런컨텍스트 조건부 거부 클래스가 dispatch에 실제로 생기는 첫 시점.
2. masc_tool_search + 지연 로딩 — 상시 코어 + 이름/한 줄 stub + lexical 검색 (ToolRet 근거로 임베딩 아닌 lexical부터). A4-1 기각 후에도 유효: 이 축의 목표는 거부 제거가 아니라 프롬프트 스키마 바이트 절감이다.
3. input_examples 부여 — 복잡 파라미터 도구에 예시 내장. A1-2 plan 도구가 최대 수혜자라 같은 PR에 동반. descriptor `examples` 필드가 이미 존재하므로 채우는 작업이다.

**A5. Acting 관측성 — 기록-화면 갭 청산** (HIGH, 합성과 동반 출하)
1. → **인스펙터 복원+트리** — 디코더에 route_evidence/runtime_contract/action_radius 복원, composition run 부모-자식 트리 렌더. 서버 변경 0.
2. Acting 타임라인 신설 — agent-core-events(로스터 + called/completed 짝) 기반 새 패널.
3. 서버측 projection API — turn 단위 서버 조인 뷰. 파생 상태 blast radius 명시 필요, 측정 후 결정.

### Track B. 시나리오 캠페인 확장

**B1. 미션 카탈로그 확장** (HIGH)
1. → **근접 행 우선** — 요소가 이미 실측된 PoC(요구→구현→실행 증명→리뷰→터미널 산출물)·상호 반론(재진술+반박 이력)부터 RW20/RW21 설계. 각 미션이 결손 evidence 축(browser/duration)을 같이 채우도록 설계.
2. 11행 일괄 설계 — 전선이 넓어 판정 품질 흐려질 위험. 미션 설계만 백그라운드 축적.
3. 실사용 장기 캠페인 — 페르소나 keeper로 연작 소설·기고문 주 단위 운영 + 정기 판정. 재현성 낮아 acceptance 아닌 관찰 캠페인으로 병행.
- 저장소 실습이 필요한 미션은 신규 private 저장소에서만 수행한다.

**B2. Web/Browser keeper 도구** (HIGH)
1. → **web_search + web_fetch 확장 (읽기 전용)** — **전제 감사 결과 구축 단계는 이미 출하됨 (2026-08-19 확인)**: WebSearch/WebFetch descriptor가 `Preferred_public_name`으로 keeper 모델에 투영되고(keeper_tool_descriptor.ml, `agent.search_web`/`agent.fetch_web`), keeper 런타임이 network-read Gate 경유로 실제 핸들러에 배선돼 있다(keeper_tool_in_process_runtime.ml:251 `with_external_gate_execution` → `Tool_misc_web_search.handle`). 남은 것은 도구 구축이 아니라 **evidence 행 해제** — web 도구를 실제로 쓰는 미션 라운드에서 tool-calls 증거를 수집해 매트릭스 행을 채우는 일이며, 이는 RW20+ 신규 라운드 판정(B1)과 같은 트랙에서 진행한다.
2. 브라우저 sidecar (CDP) — browser 축 ~17행을 채우는 정공법, sidecar 수명주기 부담으로 2수.
3. 기존 브라우저 MCP 프록시 — 외부 프로세스 신뢰·정책 경계가 Gate 밖에 생겨 보류.

**B3. RW17 exactly-once 수리 (#28977)** (HIGH)
1. → **라이브 트레이스 원인 확정** — 무귀속 행을 tool_calls·agent-core-events 교차 역추적, writer 확정 후 그 지점 수리.
2. 생성 시점 identity mint — 원인이 늦은 발급으로 확정되면 이것이 수리안.
3. store 감사 도구 — 단독은 텔레메트리-as-fix라 반드시 1/2와 동반.

**B4. RW19 격리 러너** (MED)
1. → **스크래치 서버 격리** — 전용 base-path 러너 서버, E0 러너에 격리 모드 추가.
2. fleet 스냅샷 상대 판정 — 판정 가치 훼손 위험, 비추천 기록.
3. 대시보드 run-scope 필터 — 유용하나 격리 전제 자체는 미해결, B4-1 보조.

**B5. 10T 런타임 스윕 완주 (31/49)** (LOW)
1. → **사유별 순차 재개** — codex는 8/20 쿼터 리셋 직후, gpt-oss는 #28967 수리 후, mlx/local GPU는 자원 여유 시간.
2. 야간 일괄 배치 — 스케줄러 실사용 증거 겸함.
3. 대표 모델 축소 — Model Free 주장과 상충, 비추천 기록.

### Track C. 라이브 위생 (병렬 소형 PR)

**C1. 레인 정합** — 1) → 의도 정렬(sangsu deepseek head 교정, :9010 재기동 또는 제거) 2) 정합 검사 표면(수리 동반일 때만) 3) 단일 후보 레인 fallback 충원(단일 후보면 failover 전체가 no-op).

**C2. 관측 파이프 손실** — 1) → wire-capture 상한 드롭을 파일 회전으로 교체 2) 일 256MB를 채우는 레코드 구성 진단 3) autonomy_stats 13일 정지의 사인 확정(죽었으면 D5 척살로 이관).

**C3. 정공법 교체** — 1) ~~provider를 토큰 환산 oracle로~~ 전제 소멸 확인(갭 매트릭스 해당 행 참조: Jaccard는 #27478로 삭제, `/4` 추정기 부재, 바이트 예산·provider oracle 이미 정공법) 2) 정지 리뷰 board 승격 + 재제출 경로 — 미착수 3) lock_path 일원화 — PR #29033.

## 4. PR 분해

작업 단위 ≤20k 토큰. 연쇄면 Stacked PR, 이전 PR에 적대적 리뷰 에이전트 병렬. CI는 기다리지 않고 다음 작업 진행.

| Wave | PR | 내용 | 의존 |
|---|---|---|---|
| W1 | PR-1 | ~~A2-1: read-only 핵심 서술자 Json_output 수기 부여~~ — **착륙 #29012** (3→12) | — |
| W1 | PR-2 | ~~A3: readonly 서술자 Concurrent 승격~~ — **착륙 #29017** (2→28, 심사 근거는 커밋 본문) | PR-1 (Stacked) |
| W1 | PR-3 | A5-1: 대시보드 디코더 복원 + 합성 트리 렌더 | — |
| W1 | PR-4 | B3: RW17 무귀속 원인 확정 + 수리 | — |
| W2 | PR-5 | ~~A1-2: 모델 정의 플랜 도구~~ — **착륙 #29021** (`keeper_plan_execute`). 단 08-20 기준 `tool_calls` 전 파일에서 호출 0건 — 출하됐으나 아무도 쓰지 않는다 | PR-1 |
| W2 | PR-6 | ~~A4-1: policy-before-schema~~ → 전제 감사로 기각, 본 문서 정정으로 대체 (A4-1 항목 참조) | — |
| W2 | PR-7 | C1·C2·C3 위생 소형 PR 3~4건 | — |
| W3 | PR-8 | B1-1: RW20(PoC)·RW21(상호 반론) 미션 + acceptance 확장 | PR-5 권장 |
| W3 | PR-9 | ~~B2-1: keeper web_search/web_fetch 표면~~ → 이미 출하 확인, 본 문서 정정으로 대체 (B2-1 항목 참조). evidence 행 해제는 RW20+ 라운드로 | — |
| W3 | PR-10 | D5 척살 스윕 | — |
| W4 | PR-11+ | A5-2 Acting 타임라인 · B4-1 스크래치 러너 · A1-3/B2-2는 측정 결과로 결정 | W2·W3 실측 |

하지 않는 것: 하드 게이팅 기본 금지(새 게이트는 durable truth 손상 시에만) · 예산 숫자 비교/매직 넘버/문자열 분류기 신설 금지(string-classifier 축은 RFC-0042/0154로 닫힘) · 레거시 필드/호환 reader/마이그레이션 코드 금지 · 관측-단독 PR은 수리 동반 없이 거부(텔레메트리-as-fix).

## 5. 연구 근거

| 출처 | 채택 내용 | 케이스 |
|---|---|---|
| LLMCompiler (ICML'24) · ReWOO (2023) | 플래너가 한 번에 DAG/evidence-참조 플랜 방출, 러너 병렬 실행 | A1-2 |
| Anthropic parallel tool use 문서 | 독립 read-only 병렬·부작용 직렬, 결과 일괄 반환, 미실행 호출도 is_error 결과 | A3-1 |
| Anthropic advanced tool use (2025-11) | Tool Search(프롬프트 대폭 절감 보고)·Programmatic Tool Calling·input_examples | A4-2·A4-3·A1-3 |
| CodeAct (ICML'24) · Cloudflare Code Mode · Anthropic code-execution-with-MCP | 액션=프로그램, binding=capability, 중간 결과의 컨텍스트 격리 | A1-3 |
| MCP 스펙 2025-06-18 | JSON-RPC 배칭 제거 — 합성은 wire 위층에서. structured tool output 스펙 지원 | A1 제약 |
| OpenClaw | policy-before-schema: 거부될 도구 스키마를 모델에 미전송 | A4-1 |
| Codex CLI | sandbox 축·approval 축 직교 분리, 구조화 patch=ledger 증거 | 후속 RFC |
| Claude Code subagents | 위임=신선한 컨텍스트+최종 보고만 회수, 완료는 이벤트 수신 | 후속 RFC |
| stablyai/orca | worktree-per-agent fan-out + 승자 병합 ("Microsoft Orca" 에이전트 제품은 실존 미확인) | B1-3 참고 |
| ToolRet (2025) | 임베딩 도구 검색은 실측상 약함 — lexical 우선 | A4-2 |

## 6. 검증 규약 (완료의 정의)

- 합성 도약의 정량 목표: 동일 미션에서 keeper 턴 수·턴당 벽시계·프롬프트 토큰의 전/후 비교를 하네스로 측정. 수치 없는 개선 주장 금지.
- E0 규율: 대표 실측 원칙 유지(r6). 점수를 쫓는 재실행 금지. 신규 미션(RW20+)은 신규 라운드에서만 판정.
- 대시보드 동반 출하: 실행 문법을 바꾸는 모든 PR은 관측 표면 갱신 포함. wire 모양 변경 시 대시보드 TS 스윕. 매트릭스 갱신은 다섯 표면 전수 스윕.
- 증거: 라운드마다 reports/ 번들(assertions·health·turns·browser 스크린샷) + 매트릭스 evidence 축 갱신 + 체크인 receipt.
- Browser 실측: A5 출하 후 대시보드에서 합성 트리·acting 표면을 브라우저로 실측하고 스크린샷을 번들에 포함.
