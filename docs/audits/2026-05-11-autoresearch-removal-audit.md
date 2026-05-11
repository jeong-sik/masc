# autoresearch subsystem 제거 audit

**날짜**: 2026-05-11
**대상**: `masc_autoresearch_*` 7 도구 + `lib/autoresearch/` 5 모듈 + `lib/autoresearch_codegen.ml`
**근거**: 사용자 결정 "autoresearch는 지운다". plan PR-N2a (docs only audit).
**Plan**: `~/me/planning/claude-plans/polished-juggling-galaxy.md` §2 PR-N2a

## 도구 인벤토리

| 도구 | total ref (lib + test) | 등장 파일 수 | 정의 위치 |
|------|------------------------|------------|-----------|
| `masc_autoresearch_cycle` | 20 | 14 | `lib/tool_autoresearch.ml`, `lib/tool_autoresearch_schemas.ml` |
| `masc_autoresearch_inject` | 11 | 9 | 동 |
| `masc_autoresearch_record_finding` | 14 | 11 | 동 |
| `masc_autoresearch_search_findings` | 17 | 11 | 동 |
| `masc_autoresearch_start` | 19 | 15 | 동 |
| `masc_autoresearch_status` | 18 | 14 | 동 |
| `masc_autoresearch_stop` | 15 | 12 | 동 |

총 7 도구. plan v4 가정 "~5"는 stale.

## Subsystem 모듈

`lib/autoresearch/` 디렉토리:
- `autoresearch_file.ml(.mli)` — file I/O
- `autoresearch_git.ml(.mli)` — git operations
- `autoresearch_metric.ml(.mli)` — metric measurement
- `autoresearch_serde.ml(.mli)` — JSON serialization
- `autoresearch_storage.ml(.mli)` — persistent store

추가:
- `lib/autoresearch_codegen.ml` — LLM 기반 code change prompt builder + cascade 호출. "autonomous research assistant optimizing code" 책임
- `lib/tool_autoresearch.ml` — 7 도구 dispatch
- `lib/tool_autoresearch_schemas.ml` — schema 정의
- `lib/autoresearch_types.ml` (추정 — Autoresearch_types include 발견)

## Caller chain 분류

### A. Subsystem 내부 자기참조 (제거 시 자동 사라짐)
- `lib/autoresearch/*.ml(.mli)` — 모듈끼리 서로 호출
- `lib/autoresearch_codegen.ml` — `Autoresearch_types`, `Autoresearch_serde` include
- `lib/tool_autoresearch.ml` + `lib/tool_autoresearch_schemas.ml`

### B. 표면 등록 (정리 대상, ~10 라인)
- `lib/dashboard/dashboard_keeper_feature_catalog.ml`: `"Autoresearch tools"` feature label (7 도구 명시) — feature block 통째 제거
- `lib/dashboard/dashboard_surface_readiness.ml`: `masc_autoresearch_status` 1 reference
- `lib/keeper/keeper_agent_tool_surface.ml`: 4 도구 label (status/stop/cycle + 1) — 4 라인 제거
- `lib/server/server_routes_http_routes_dashboard.ml`: start/stop endpoint 등록

### C. Tool catalog 메타데이터 (자동 정리)
- `lib/tool_catalog_surfaces.ml`: 7 entries
- `lib/tool_name.ml`: 7 variant + lookup
- `lib/tool_permission_map.ml`: 7 entries
- `lib/tool_prefilter.ml`: 4 entries (cycle/start/status/stop)

### D. Persona prompt 자동 호출
`lib/keeper/keeper_persona*.ml` + prompt 파일 grep: **0 hit**. autoresearch는 manual user invocation tool. persona가 자동 호출하지 않음 → 제거 시 persona behavior 영향 없음.

### E. Test
- `test/test_env_config_exec_timeout_10426.ml` 1건 — `Autoresearch_*` 모듈 사용 (timeout test)

## 제거 안전성 verdict

| 카테고리 | 영향 | 정리 방법 |
|----------|------|-----------|
| Subsystem 모듈 (A) | 자동 사라짐 | `lib/autoresearch/` + `tool_autoresearch.ml`/`_schemas.ml` + `autoresearch_codegen.ml` 디렉토리/파일 삭제 |
| 표면 등록 (B) | feature catalog block + surface label 4 + dashboard endpoint | 4 파일 touch |
| Tool catalog 메타 (C) | 7 entries × 4 파일 = 28 라인 제거 | mechanical |
| Persona (D) | **영향 없음** (자동 호출 없음) | skip |
| Test (E) | timeout test가 Autoresearch_serde 사용 | test 마이그레이션 또는 삭제 |

**verdict**: SAFE REMOVAL. persona 자동 호출 0 + caller chain이 자체 subsystem + 표면 등록만이라 deletion 명확. 단 **LOC 큼** (~700-1000 LOC 삭제).

## PR-N2b 권장 분할

**옵션 A (단일 PR)**: 모든 정리를 한 PR로. -700~1000 LOC. 위험: 회귀 발견 시 rollback 큼.

**옵션 B (3-step)** — 권장:
1. **PR-N2b.1**: dashboard feature + keeper surface label 제거 (표면 노출 정리, B 카테고리). caller 최소 정리. -50 LOC
2. **PR-N2b.2**: tool catalog 메타데이터 entry 제거 (C 카테고리). dispatch table에서 7 도구 제거. -100 LOC
3. **PR-N2b.3**: subsystem 파일/모듈 삭제 (A 카테고리). `lib/autoresearch/` 디렉토리 + 4 파일 삭제 + test 마이그레이션. -600~800 LOC

각 PR이 build green을 유지하면서 점진적으로 deletion. PR-N2b.1 → PR-N2b.2 → PR-N2b.3 순서로 caller가 점진적으로 사라짐.

## 위험

| 위험 | 완화 |
|------|------|
| 외부 (dashboard UI, 사용자 manual workflow)에서 autoresearch UI 사용 중 | PR-N2b.1 본문에 deprecation 명시 + dashboard release note |
| `autoresearch_codegen.ml`의 LLM cascade가 다른 곳에서 import | grep으로 외부 caller 없음 확인 (지금 0건) — RE-VERIFY on N2b.3 시점 |
| Test `test_env_config_exec_timeout_10426.ml`가 timeout 일반 케이스인데 마침 Autoresearch_serde 사용 | test에서 다른 module로 마이그레이션 (string serde 또는 inline JSON) |

## 다음 단계

1. 본 audit를 PR-N2a로 머지 (docs only).
2. 사용자 컨펌: 옵션 A (단일 PR) vs 옵션 B (3-step).
3. PR-N2b 진행.
