# RFC-0057: Tool Descriptor Codegen — `[@@deriving tool]` via Build-Time Generation

> **Status**: Draft
> **Author**: masc-mcp design loop
> **Date**: 2026-05-09
> **Depends on**: RFC-0054 (shell-ir-ppx-deriving) — PPX track CLOSED-WONTFIX, codegen track ACTIVE
> **Replaces**: progress_report.md §3.2 "PPX 개발" claim (outdated)

---

## §0 Abstract

RFC-0054에서 Shell IR GADT의 walker를 PPX로 생성하려는 5가지 접근법이 모두 실패했습니다. 원인은 ppxlib가 GADT의 existentially-quantified parameter를 narrowing하지 못해 `[@@deriving]` 속성을 GADT constructor에 부착할 수 없는 구조적 제약입니다 (RFC-0054 §5.3.3).

이 RFC는 동일한 문제를 **빌드 타임 codegen**으로 해결하는 패턴을 공식화하고, 이를 61개 MCP 도구의 typed descriptor 자동 생성으로 확장합니다. 핵심 원칙은 **"spec-as-data → emit-to-buffer → dune rule"** 3단계 패턴입니다.

progress_report.md §3.2의 "`[@@deriving shell_ir]` PPX 개발 (수동 구현 중, PPX화 필요)" 및 "`[@@deriving tool]` PPX 개발 (아직 미시작)" 항목은 본 RFC의 codegen 접근법으로 대첵됩니다.

---

## §1 Background & Motivation

### 1.1 현재 상태

PR #14240, #14258을 통해 다음이 완료되었습니다:

- `('i, 'o, 'r, 's) command` GADT (9 constructors + `Generic` fallback)
- `Capability_check_typed` — GADT 기반 capability walker
- `Risk_classifier_typed` — GADT 기반 risk classification
- `Approval_policy_typed` — GADT → 기존 Approval_policy bridge

### 1.2 남은 문제

progress_report.md §2.1에 기록된 8개 문제 중 미해결 4개:

| # | 문제 | 현상 | 본 RFC 적용 범위 |
|---|------|------|-----------------|
| 1 | `mode_enforcer.ml` 50+ 문자열 하드코딩 | OAS 측 tool effect 분류가 문자열 매칭 | **범위外** — OAS subsystem 별도 RFC |
| 2 | `agent_tools` O(n) 선형 검색 | 도구 이름 문자열로 linear search | **Phase 2** — GADT dispatch로 대체 |
| 3 | **61개 도구 수동 Yojson AST** | `{name="..."; description="..."; ...}` 하드코딩 | **핵심 범위** — codegen으로 자동화 |
| 4 | 중복 도구 | `read_file` / `masc_code_read` 등 의미 중복 | **Phase 2** — alias/unification 계획 |

### 1.3 Current Schema Architecture

61개 도구는 `lib/tool_schemas/`의 13개 파일에 분산되어 있습니다:

| 파일 | 도구 수 | 카테고리 |
|------|--------|----------|
| `tool_schemas_misc.ml` | 12 | config, webrtc, admin, board 등 |
| `tool_schemas_plan.ml` | 8 | plan, task 관련 |
| `tool_schemas_agent.ml` | 6 | agent 관리 |
| `tool_schemas_coord_core.ml` | 6 | coord 핵심 |
| `tool_schemas_run.ml` | 6 | run, execution |
| `tool_schemas_inline_coord.ml` | 6 | inline coord |
| `tool_schemas_coord_extra.ml` | 5 | coord 부가 |
| `tool_schemas_inline_infra.ml` | 4 | infra |
| `tool_schemas_code.ml` | 3 | code 편집 |
| `tool_schemas_worktree.ml` | 3 | worktree |
| `tool_schemas_control.ml` | 2 | control |
| `tool_schemas_inline_episodes.ml` | 0 | (empty, reserved) |
| **합계** | **61** | |

각 도구는 `Masc_domain.tool_schema = {name: string; description: string; input_schema: Yojson.Safe.t}`로 정의됩니다. `input_schema`는 raw Yojson AST (`` `Assoc``, `` `String``, `` `List`` 등)로 하드코딩되어 있어 타입 안정성이 없습니다.

### 1.4 Known Issues from Hardcoded Schemas

- **Issue #8546**: `masc_config_admin`이 schema에는 `[auth; unit_policy]`를 광고하지만 handler는 `auth`만 구현 → LLM client가 schema를 따르다 conflicting error
- **Issue #8592**: `dashboard_scope_enum_strings`가 `Dashboard.valid_scope_strings`와 hand-mirrored. cycle dependency 때문에 별도 파일에 분리
- **Issue #8493**: `config_category_enum_strings`가 `Env_config_snapshot.valid_config_category_strings`와 mirror. sync test가 없으면 silent drift

이 모든 문제의 공통점: **문자열 기반 enum이 schema와 handler 사이에서 동기화되지 않음**.

---

## §2 Goals

1. **Tool Spec as OCaml Record**: 각 MCP 도구의 descriptor를 OCaml record로 정의하여 컴파일 타임 타입 검증 확보
2. **Automatic JSON Schema Generation**: record 정의로부터 OpenAI-compatible `tools` JSON array를 빌드 타임에 생성
3. **Fail-Closed by Default**: 새 도구 추가 시 descriptor 누락 → 컴파일 에러
4. **Zero Runtime Overhead**: 생성된 JSON은 빌드 아티팩트, 런타임에는 OCaml 문자열 리터럴로 로드

---

## §3 Non-goals

1. **PPX 사용** (RFC-0054 §3 Non-goals #1과 동일한 근거)
2. **런타임 코드 생성** — 동적 `ocamlc` 호출이나 `Metaocaml` 사용 금지
3. **`mode_enforcer.ml` 마이그레이션** — OAS subsystem 별도 작업
4. **다국어 description 자동 번역** — 영문 description 기준, 번역은 별도 파이프라인

---

## §4 Design Overview

### 4.1 Three-Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Generated JSON Schema (OpenAI tools format)        │
│  → build-time artifact, checked into git or generated       │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: Codegen Engine                                     │
│  → bin/gen_tool_descriptors.ml                              │
│  → reads Tool_spec.t list, emits JSON + OCaml source        │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: Tool Spec Definitions                              │
│  → lib/mcp_server/tool_spec.ml (or similar)                 │
│  → OCaml record per tool: {name; description; params; ...}  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Codegen Pattern (RFC-0054 POC 기반)

`bin/gen_shell_ir_walkers.ml`에서 검증된 패턴을 재사용합니다:

```ocaml
type tool_spec =
  { name : string
  ; description : string
  ; parameters : param_spec list
  ; required : string list
  }

and param_spec =
  { param_name : string
  ; param_type : [ `String | `Int | `Bool | `Object | `Array ]
  ; description : string
  ; enum_values : string list option
  }
```

**Emit 함수**:

```ocaml
let emit_tool_json buf spec =
  Buffer.add_string buf (Printf.sprintf
    {|  { "type": "function"
  , "function": {
      "name": %S,
      "description": %S,
      "parameters": {
        "type": "object",
        "properties": {
%s
        },
        "required": [%s]
      }
    }
  }|}
    spec.name
    spec.description
    (emit_properties spec.parameters)
    (String.concat ", " (List.map (Printf.sprintf "%S") spec.required)))
```

### 4.3 Dune Integration

```dune
; lib/mcp_server/dune
(rule
 (target tool_descriptors_gen.ml)
 (deps (:gen %{exe:../../bin/gen_tool_descriptors.exe}))
 (action (with-stdout-to %{target} (run %{gen}))))
```

생성된 `tool_descriptors_gen.ml`은 `let descriptors_json : string = "..."` 형태로 OCaml 소스 내장 JSON을 제공합니다.

---

## §5 Reference Implementation (Shell IR Walkers)

`bin/gen_shell_ir_walkers.ml`은 이미 본 패턴의 완전한 POC입니다:

| 구성 요소 | 역할 | Tool Descriptor 버전에 대한 대응 |
|-----------|------|-------------------------------|
| `type ctor` record | constructor 메타데이터 | `type tool_spec` record |
| `shell_ir_typed_spec` list | 9개 constructor 정의 | 61개 tool spec list |
| `emit_risk` / `emit_sandbox` | per-constructor 함수 생성 | `emit_tool_json` |
| `emit_to_simple` | typed → untyped 변환 | spec → JSON string 변환 |
| `dune (rule ...)` | 빌드 타임 생성 | 동일 |

**핵심 교훈**: GADT의 type parameter를 다룰 필요 없이, **value-level record**로 spec을 정의하면 Buffer 기반 codegen이 trivial해집니다.

---

## §6 61-Tool Integration Plan

### 6.1 도구 분류

현재 `lib/tool_schemas/`의 61개 도구는 다음 카테고리로 분류됩니다:

| 카테고리 | 예시 | GADT화 우선순위 |
|----------|------|----------------|
| **Shell IR** | ls, cat, rg, git_*, curl, rm, sudo | P0 — 이미 GADT 있음 |
| **File System** | read_file, write_file, list_directory | P1 — parameter 타입 단순 |
| **Code Search** | grep_search, find_symbols | P1 — 반복 패턴 |
| **Keeper Ops** | keeper_status, keeper_claim | P2 — keeper domain |
| **Dashboard** | dashboard_query, telemetry_fetch | P2 — dashboard coupling |
| **Meta / MASC** | masc_add_task, masc_broadcast | P3 — 낮은 도구 |

### 6.2 중복 도구 통합 (progress_report.md §2.1 #4)

| 기존 도구들 | 통합안 | 근거 |
|------------|--------|------|
| `read_file` + `masc_code_read` | `read_file` (unified) with optional `format` param | 기능 동일, namespace만 다름 |
| `grep_search` + `rg` (Shell IR) | Shell IR `Rg`를 MCP surface로 노출 | GADT 재사용 |
| `list_directory` + `ls` (Shell IR) | Shell IR `Ls`를 MCP surface로 노출 | GADT 재사용 |

**원칙**: Shell IR에 이미 GADT가 있는 도구는 MCP layer에서 해당 GADT를 직접 참조하여 descriptor를 생성합니다. 중복 구현 금지.

---

## §7 Parameter Type System

### 7.1 Typed Parameters

```ocaml
type 'a param =
  | String : { description : string; enum : string list option } -> string param
  | Int : { description : string; min : int option; max : int option } -> int param
  | Bool : { description : string } -> bool param
  | Object : { description : string; properties : 'b param list } -> 'b param
  | Array : { description : string; item_type : 'a param } -> 'a list param
  | Optional : 'a param -> 'a option param
```

### 7.2 Example: read_file

```ocaml
let read_file_spec : tool_spec =
  { name = "read_file"
  ; description = "Read contents of a file at the given path."
  ; parameters =
      [ String { description = "Absolute file path"; enum = None }
      ; Optional (Int { description = "Offset in bytes"; min = Some 0; max = None })
      ; Optional (Int { description = "Max bytes to read"; min = Some 1; max = Some 1_000_000 })
      ]
  ; required = ["path"]
  }
```

---

## §8 Testing Strategy

### 8.1 Golden Test

`bin/gen_tool_descriptors.exe` 출력이 기대값과 byte-for-byte 동일한지 검증:

```ocaml
(* test/test_tool_descriptors_gen.ml *)
let%expect_test "golden" =
  let generated = Tool_descriptors_gen.descriptors_json in
  let expected = In_channel.read_all "test/tool_descriptors_golden.json" in
  Alcotest.(check string) "byte-for-byte match" expected generated
```

### 8.2 JSON Schema Validation

생성된 JSON이 OpenAI `tools` API 스키마를 만족하는지 Python/jsonschema로 검증:

```bash
python3 -c "import json; tools=json.load(open('tool_descriptors_golden.json')); \
  assert all(t['type'] == 'function' for t in tools)"
```

### 8.3 Round-Trip Test

`Shell_ir_typed.of_simple`와 같은 역함수가 필요한 경우, JSON → spec record → JSON 라운드트립이 identity인지 검증합니다.

---

## §9 Rollout & Migration

| Phase | 범위 | 기간 추정 | 의존성 | 상태 |
|-------|------|----------|--------|------|
| **0** | POC: Shell IR 9개 도구 descriptor 생성 | 1일 | gen_shell_ir_walkers.ml 재사용 | merged (PR #14396) |
| **1** | File System 카테고리 (10개 도구) | 2일 | Phase 0 완료 | merged (PR #14405) |
| **2** | 나머지 52개 도구 + 중복 통합 | 1주 | Phase 1 완료, 중복 분석 | merged (PR #14412 + #14658 PR-2a..2d split) |
| **3** | `agent_tools` O(n) 검색 → GADT dispatch | 3일 | Phase 2 완료 | merged (PR #14416) |
| **4** | Telemetry/ Dashboard 도구 전환 | 별도 RFC | RFC-0049 (telemetry foundation) | merged (PR #14417) |
| ~~5~~ | (number skipped — see footnote) | — | — | — |
| **6** | Tool selection mode codegen + GADT activation | — | Phase 4 완료 | merged (PR #14421) |

> **Phase numbering footnote**: Phase 5 was reserved during planning but not
> ultimately scoped into a PR — the work originally intended for Phase 5
> (codegen-swap inline_coord group) was bundled into Phase 6's scope when
> the cross-cutting nature became clear during Phase 4 review. The number
> is preserved as a gap rather than renumbered to avoid invalidating PR
> titles already merged with "Phase 6" / "Phase 7" labels. Future RFCs
> should renumber phases when a number is dropped, or add a footnote like
> this one. See issue #14561 for the process-gap discussion.

---

## §10 Open Questions

1. **Parameter record의 GADT화 수준**: `param`을 GADT로 만들면 type-safe tool calling이 가능하지만, 61개 도구의 parameter 정의가 복잡해집니다. Phase 0에서는 value-level record로 시작할까요, 아니면 바로 GADT로 갈까요?
2. **`mode_enforcer.ml`과의 경계**: OAS 측 `tool_effect` 문자열 분류를 이 codegen 시스템과 통합할 때, 어느 layer에서 통합해야 할까요?
3. **Git 관리**: `tool_descriptors_gen.ml`을 `.gitignore`할지, 아니면 golden test용으로 커밋할지?

---

## §11 Relation to Existing Work

| 문서 | 관계 |
|------|------|
| RFC-0054 | PPX track CLOSED-WONTFIX, codegen pattern POC 제공 |
| RFC-0049 | Telemetry foundation — Phase 4에서 참조 |
| progress_report.md | §3.2의 PPX claim은 본 RFC로 대첵됨 |
| PR #14240, #14258 | GADT Shell IR 구현 — 본 RFC의 Layer 1 기반 |
