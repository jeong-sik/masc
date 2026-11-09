# 감사 5/8 전수 판정 — 2026-11-08 (task-3365 취합 문서)

작성: claude-62be833e. 감사 원문: board:p-7570986c17b1739c31e27e092a79fc88 및
jeong-sik/masc#49744. 모든 좌표는 main 516d72b9f3b0(판정 시점 origin/main)에서
재직독해 판정했다(전용 재검증 에이전트 보고: 세 통계 시스템의 쓰기·읽기 경로 실측 포함).

## 항목 1 Tool_unified 통계 split-brain — 판정: 세 시스템 세 스코프 (문서화)

| 시스템 | 쓰기 | 읽기 | 스코프 |
| --- | --- | --- | --- |
| Tool_registry.get_stats | mcp_server_eio_call_tool.ml:821(외부 MCP)·keeper_tools_agent_core.ml:89(내부) | tool_info → runtime_info·agent_api | 프로세스 수명 in-memory 카운터(재시작 리셋), 소스 분리·assignment_id 는 여기만 |
| Tool_metrics.all_stats | 공유 dispatch observer(server_bootstrap_maintenance.ml:590-595)·기동 hydrate(sqlite) | summary_report | 표본 백분위 p50-p99, retained+current |
| Telemetry_eio.tool_usage_stats | track_tool_called 2곳 | summarize_tool_usage·tool_profile | date-split JSONL 영구 로그 |

통합은 동작 변경이다 — tool_info 를 Tool_metrics 로 돌리면 소스 분리가 사라지고
O(1) 조회도 아니며, summary_report 를 registry 로 돌리면 백분위·지속성이 소실된다.
summary_report 는 이미 metrics_source 블록으로 스스로를 선언한다(:155-159).
**수리**: tool_unified.mli tool_info 문서에 call_stats 의 소유·스코프 한 줄.

## 항목 2 1-생성자 화석 — 해소 2 + 문서화 3 + 유지 3

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| keeper_failure_taxonomy 산하 단일 생성자 파일 | **해소 확인** | #49779 이후 남은 10개 모듈 전부 다중 생성자(approval_queue 6·checkpoint_failure_operation 6·checkpoint_store 4·fs 4·…) — 단일 생성자 파일 0 |
| tool_catalog.implementation_status | **해소 확인** | 존재하지 않음(헤더 "every registered tool is Real" 주석만) |
| tool_catalog.lifecycle = Active | **문서화** | tool_info JSON(:49)에 나가는 필드 — 두 번째 종류는 대시보드 wire 변경. mli 한 줄 |
| goal_verification_run_registry.review_kind = Proof | **문서화** | durable JSONL 행의 wire 필드(쓰기 :139·:496, 읽기 :161-162). 삭제·재추가 비용 동일 — mli 한 줄 |
| board_metrics_hooks.flusher_outcome = Switch_finished | **유지** | 계량 라벨 훅의 한 축(board_metric_hooks_adapter 라벨 변환·시험 2종) — 지우려면 훅 시그니처까지 함께 |
| browser_backend.t = Ego / browser_lane_name.t = Live | **유지** | 문서화된 seam — mli "a new source is a new constructor, and every reader matches without a catch-all" |
| board_dispatch.board_backend = Jsonl of Board.store | **유지(열림 선택권 기록)** | mli 헤더 "Board now runs on the JSONL store only". 평탄화(type = Board.store + 패턴 15곳 기계 교체)는 한 파일 안이라 위험 낮으나 이득도 포장 제거뿐 — 후속 선택 |

## 항목 3 unified_tool_registry 폐허 — 판정: 해소 (기동 랫칫으로 생존)

mcp_server_eio.ml:68-69 가 register_all + enforce_visible_tag_coverage 를 기동에
실행하고 reserved_tool_names 는 candle_appraiser·skill_editor·workspace_memory_addon·
lane_addon_runtime·librarian_addon 이 소비한다. 16개 Mod_* 디스패치 팔은
tag_of_runtime_handler 와 짝을 이루는 현행 구조. 미사용 facade 가 아니다.

## 항목 4 중복 capability 축 — 판정: 문서화 (층위가 만든 이중 열거)

Tool_catalog.execution_policy_axis(등록 시점 완전성 검증, wire "readonly")와
Tool_capability.kind(디스패치 시점 질의, wire "read_only")는 같은 3개 메타데이터를
다른 어휘로 열거한다. 의존 방향(tool_capability → Tool_catalog.metadata)이 순환을
막아 단일 축으로 합칠 수 없다 — tool_capability.mli 에 상호 언급 한 줄.

## 항목 5 다이아몬드 include — 수리 3 + 유지 3

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| keeper_types_profile.ml:93 include Keeper_config 2벌 | **수리 (PR #49970)** | :9 에 이미 include — 같은 모듈 이중 include 삭제 |
| otel_metric_store.ml facade | **수리 (PR #49970)** | 이름 모듈 7개를 direct(:8,:10-15)와 Builtin(:9 경유) 이중 수신 + Otel_metric_names 별칭 let 4개가 include 와 중복. direct 7개·별칭 4개 삭제(이름은 Builtin 경로로 동일 제공) |
| dashboard_execution 3중 include | **수리 (PR #49970)** | `dashboard_execution.ml`에서 `Dashboard_execution_sessions`가 이미 재수출하는 중복 `include Dashboard_execution_helpers`를 제거하여 다이아몬드 중복 include 해소 |
| workspace 14-include + 1줄 루트 | **유지** | godfile 분해의 repo 표준 패턴(각 모듈 1회 — 다이아몬드 아님), Workspace.X 소비처 전역 |
| board 루트 shim 7개 | **유지** | wrapped lib 에 bare 이름을 노출하는 load-bearing 경로(Board_dispatch 9파일 등 전부 루트 이름 사용) |
| OTel 스택 2벌 (`packages/agent_core/lib/otel_tracer.ml`·`otel_export.ml` vs `lib/otel_spans/`·`lib/otel_metrics/`·`lib/otel_metric_store/`) | **유지(계층 경계·브리지 확인)** | `packages/agent_core`(`agent_core.opam`)는 상위 `masc`(`lib/`) 및 외부 `opentelemetry` protobuf SDK에 의존할 수 없는 독립 하위 라이브러리 패키지로 자체 인메모리 스팬 링·OTLP JSON 직렬화(`otel_tracer.ml`·`otel_export.ml`)를 제공한다. 반면 `lib/otel_spans/`(`Opentelemetry` SDK 래퍼)·`lib/otel_metrics/`·`lib/otel_metric_store/`는 상위 `masc` 서버 계층의 스팬·메트릭 집계기이며, `lib/server/server_bootstrap_maintenance.ml:673-688`에서 `Otel_metric_store.register_otel_source_once ()` 및 `Agent_core.Otel_tracer.create_instance_eio ()`를 통해 `agent_core` 트레이서 상태를 서버 메트릭/트레이스 파이프라인으로 브리지한다. 패키지 의존 역전 없이 통합 불가하므로 현행 2계층 구조를 유지한다 |

## 항목 6 9스토어 fan-in — 판정: 읽기 전용 뷰가 계약

모듈·mli 주석이 "Read-only aggregation… No existing write paths are modified"
로 명시 — 순수 읽기 fan-in 이 받아들어진 설계이고 각 스토어는 독자적으로 쓴다.

## 감사 후속 (등기)

1. board_backend 평탄화(선택) — 열림 선택권으로 기록. 달성 조건: 패턴 15곳 기계 교체 + 시험.
2. 도구 통계의 영구 통합 원천 단일화는 별도 설계 과제(세 스코프의 의미 정합부터).

## 수리 커밋 (이 PR)

1. `refactor(taxonomy)` — keeper_types_profile 이중 include·otel facade 이중 재수출/별칭 제거, 스코프 문서 4건
