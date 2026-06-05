---
rfc: "0218"
title: "Keeper↔Sandbox↔Repo domain boundary"
status: Draft
created: 2026-06-05
updated: 2026-06-05
author: jeong-sik
supersedes: []
superseded_by: null
related: ["0215", "0210", "0208"]
implementation_prs: []
---

# RFC-0218: Keeper↔Sandbox↔Repo domain boundary

## 0. Summary

Keeper runtime이 sandbox 레이아웃을 알고, repo_manager를 런타임에
호출하며, `"repos/"` 문자열 리터럴이 8개 파일에 산재한다.
근본 원인: keeper가 **setup-time에 주입받아야 할 정보**를
**runtime에 직접 탐색**해서 얻는다.

해결: temporal boundary — keeper session 시작 시 sandbox 모듈이
pre-compute한 `allowed_paths` + `repo_context`를 keeper에게 주입.
Keeper는 런타임에 repo_manager·TOML·sandbox layout을 전혀 모른다.

Trigger: PR #20170이 `missing_file_error_json`에 +75줄의 repo-aware
에러 힌트를 추가. 이 힌트가 (1) keeper의 sandbox FS 직접 탐색,
(2) `"repos/"` 하드코딩, (3) `playground_repos_json`의 중복 구현을
포함. 증상 치료이며 근본 설계 재검토가 필요.

## 1. Measured dependency graph (origin/main, 2026-06-05)

### 1.1 Keeper → repo_manager (5 call sites, 단 1개 함수)

```
keeper_tool_filesystem_runtime.ml:236  → Keeper_repo_mapping.validate_path_access
keeper_tool_filesystem_runtime.ml:572  → Keeper_repo_mapping.validate_path_access
keeper_tool_filesystem_runtime.ml:671  → Keeper_repo_mapping.validate_path_access
keeper_workspace_read_ops.ml:26        → Keeper_repo_mapping.validate_path_access
keeper_workspace_ops.ml:48             → Keeper_repo_mapping.validate_path_access
```

5개 호출점 모두 같은 함수. keeper가 런타임에 "이 keeper가 이 repo에
접근 가능한가?"를 TOML 읽기로 매번 확인.

### 1.2 Keeper → sandbox layout (문자열 산재)

`"repos"` 리터럴 출현:

| 파일 | 횟수 | 맥락 |
|------|------|------|
| `keeper_tool_execute_command_semantics.ml` | 4 | 경로 패턴 매치 |
| `keeper_tool_execute_path.ml` | 7 | repos_dir, 패턴 매치 |
| `keeper_sandbox_control.ml` | 5 | display path, JSON key |
| `keeper_tool_shared_runtime.ml` | 5 | PR #20170 에러 힌트 |
| `keeper_alerting_path.ml` | 4 | prefix match, equality |
| `keeper_sandbox.ml` | 4 | 필드 초기화, JSON key |
| `keeper_tool_filesystem_runtime.ml` | 1 | list literal |
| `keeper_tool_execute_runtime.ml` | 1 | 패턴 매치 |

총 31개. keeper가 sandbox의 `repos/` 하위 디렉토리 구조를 알고 있다.

### 1.3 Keeper → TOML (20개 파일)

keeper_types_profile_toml_parser, keeper_types_profile_toml_io,
keeper_tool_policy_config 등 20개 파일이 TOML을 참조.
이건 RFC-0215(keeper sub-library extraction)의 범위이며
본 RFC와 독립. 단 keeper→repo_manager의 TOML 읽기는 본 RFC로 해결.

### 1.4 역참조: `repository.keepers`

```
repo_manager_types.ml:18        — type field definition
repo_store.ml:107               — TOML serialization
dashboard_branches.ml:298       — display
server_routes_http_routes_repositories.ml:54 — HTTP API response
```

`repository.keepers : string list`는 keeper→repo 정방향 매핑
(`keeper_repo_mappings.toml`)과 동일 정보의 역방향 저장.
한쪽만 변경 시 분기.

### 1.5 이미 존재하는 SSOT

`Playground_paths` (`lib/config/playground_paths.ml`)이 이미
`.masc/playground/<keeper>/repos/`, `mind/` 경로 SSOT 역할.

keeper 내부에 만든 `Keeper_sandbox_layout` 모듈은 **중복**이다.

## 2. Critique of previous approach (Phase 1-A/1-B)

초기 구현(PRD #20183)이 시도한 것:

| Phase | 내용 | 문제 |
|-------|------|------|
| 1-A | `Keeper_sandbox_layout` 모듈 신규 | `Playground_paths`와 중복. keeper namespace 내부에 있어 경계 교정 안 됨 |
| 1-B | 31개 `"repos"` → `Keeper_sandbox_layout.repos_subdir` 교체 | **상수 중앙화는 했지만 의존성 방향은 안 바꿈.** keeper가 여전히 "repos/"라는 개념을 앎 |
| | | keeper가 `Keeper_sandbox_layout.repos_dir ~sandbox_root`를 호출 = 여전히 sandbox layout 지식 보유 |

**근본 오류**: keeper가 layout 상수를 모듈로 참조하든 문자열로 참조하든
keeper가 "repos/"를 안다는 사실은 변하지 않는다. 올바른 해결은
keeper가 layout을 아예 모르게 만드는 것.

## 3. Architectural principle: temporal boundary

```
현재 (runtime coupling):
  Keeper → Keeper_repo_mapping.validate_path_access → TOML → 결과
  Keeper → "repos/" → FS 탐색 → 결과
  Keeper → playground_repos_json → FS 탐색 → 결과

목표 (setup-time injection):
  [Setup] Sandbox 모듈 → allowed_paths + repo_context 계산 → keeper meta에 저장
  [Runtime] Keeper → pre-computed allowed_paths로만 검증 → repo_manager·TOML·FS 모름
```

핵심 변화: **정보 획득 시점**을 runtime에서 setup으로 이동.

각 도메인이 아는 것 / 모르는 것:

| 도메인 | 안다 | 모른다 |
|--------|------|--------|
| **Playground_paths** (`lib/config/`) | `.masc/playground/` layout SSOT | keeper, repo_manager |
| **Keeper_repo_mapping** (`lib/repo_manager/`) | keeper↔repo 정방향 매핑 | sandbox layout, keeper runtime |
| **Repo_sync/Store/Git** (`lib/repo_manager/`) | clone, sync, git operations | keeper, sandbox |
| **Sandbox** (미래 `lib/keeper_sandbox/`) | Playground_paths로 layout 계산, repo_manager로 repo 목록 획득 | keeper turn internals |
| **Keeper runtime** | pre-computed `allowed_paths` | "repos/", repo_manager, TOML, sandbox layout |
| **Tool** | 실행 + 결과/에러 반환 | sandbox layout, repo context |

## 4. Proposed design

### 4-A. Revert Phase 1-A/1-B

`Keeper_sandbox_layout` 모듈과 31개 문자열 교체를 revert.
`Playground_paths`가 이미 SSOT. keeper 내부에 중복 모듈 유지 불필요.

### 4-B. Pre-compute `allowed_paths` at setup time

현재 `Keeper_sandbox.allowed_path_roots_of_meta`는 sandbox root
하나만 반환:

```ocaml
(* current — broad sandbox root *)
let allowed_path_roots_of_meta ~(meta : keeper_meta) : string list =
  [ allowed_root_rel_of_meta ~meta ]   (* ".masc/playground/<keeper>/" *)
```

변경: sandbox 모듈(keeper 외부, 장기적으로 RFC-0215 cluster 7
extraction 시 이동)이 session 시작 시:

1. `Keeper_repo_mapping.allowed_repositories` 호출 → 허용된 repo_id 목록
2. 각 repo_id → `Playground_paths.repos_path keeper_name ^ repo_id`로 실제 경로 계산
3. sandbox root 대신 **특정 repo 경로**를 allowed_paths에 추가

```ocaml
(* target — specific paths, no broad "repos/" wildcard *)
type sandbox_paths = {
  root : string;              (* sandbox root, for sandbox-level ops *)
  mind : string;              (* .../mind/ *)
  repo_paths : string list;   (* [.../repos/repo1/, .../repos/repo2/] *)
  extra : string list;        (* meta.allowed_paths — user-specified *)
}

let compute_sandbox_paths ~config ~meta =
  let root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let mind = Playground_paths.mind_path meta.name
    |> Filename.concat config.base_path in
  let allowed_repos =
    match Keeper_repo_mapping.allowed_repositories
            ~keeper_id:meta.name ~base_path:config.base_path with
    | Ok repo_ids ->
      repo_ids
      |> List.map (fun repo_id ->
        Playground_paths.repos_path meta.name
        |> Filename.concat config.base_path
        |> Filename.concat repo_id)
    | Error _ -> []
  in
  { root; mind; repo_paths = allowed_repos; extra = meta.allowed_paths }
```

이 계산은 keeper session 시작 시 **한 번** 실행.
결과는 keeper context에 저장되어 런타임에 사용.

**보안 개선**: 현재는 broad sandbox root + runtime repo check.
변경 후 specific repo paths only. repo_manager 호출이 런타임에
필요 없어 physical boundary와 logical boundary가 단일
allowlist로 통합.

### 4-C. Remove `Keeper_repo_mapping` runtime calls from keeper

5개 호출점(`validate_path_access`)을 모두 제거.
pre-computed `allowed_paths`에 이미 repo 경로가 포함되어 있으므로
기존 `is_within_allowed_norms` 검사로 충분.

```ocaml
(* before — two checks *)
let allowed_norms = absolute_allowed_paths ~config ~allowed_paths in
let repo_ok = Keeper_repo_mapping.validate_path_access ... in
(* repo_ok separate from path check *)

(* after — single check against pre-computed allowlist *)
let allowed_norms = absolute_allowed_paths ~config ~allowed_paths in
(* repo paths already in allowed_norms — single check suffices *)
```

### 4-D. Turn context injection for repos

`playground_repos_json` (`keeper_sandbox_control.ml:421`)은 이미
repo name/path/branch/commit/shallow 정보를 계산.
현재 dashboard에만 사용. 이 데이터를 LLM turn context에 주입.

주입 위치: `build_keeper_system_prompt` 또는
`keeper_agent_run.ml`의 context initialization.

```ocaml
(* keeper_agent_run.ml — context initialization *)
let repos_context =
  Keeper_sandbox_control.playground_repos_json ~config ~meta
in
(* inject as system-level context, outside cached system prompt *)
let dynamic_context =
  Printf.sprintf
    "Your sandbox contains these git repositories:\n%s"
    (Yojson.Safe.pretty_to_string repos_context)
in
```

LLM이 turn 시작 시 자기 sandbox의 repo 구조를 알면:
- 에러 메시지에 repo-aware hint 불필요
- PR #20170의 +75줄 제거 가능
- Tool은 순수하게 "명령 실행 + 결과 반환" 역할

### 4-E. Remove PR #20170 repo-aware error hints

Phase 4-D 완료 후 PR #20170의 `missing_file_error_json` enrichment 제거:

```
available_repos, repo_cwd_hint, next_action, recovery_examples, cwd= 필드
```

에러 메시지는 최소한으로:

```json
{ "ok": false, "error": "file not found", "path": "resolved/path" }
```

### 4-F. Reverse reference removal

`repository.keepers` 필드 제거. 역방향 질의는 computed function으로:

```ocaml
(* keeper_repo_mapping.ml에 추가 *)
let keepers_for_repo ~repo_id ~base_path =
  match load_all ~base_path with
  | Error _ -> []
  | Ok mappings ->
    List.filter_map (fun m ->
      if List.mem repo_id m.repository_ids
      then Some m.keeper_id
      else None)
    mappings
```

소비자 4곳(dashboard, server API, repo_store, config_dir_resolver)이
`repo.keepers` 대신 `keepers_for_repo` 호출.

## 5. Phase ordering

```
4-A: Revert Phase 1-A/1-B                    (독립, 정리)
 |
4-B: Pre-compute allowed_paths at setup       (핵심 변경)
 |
4-C: Remove Keeper_repo_mapping runtime calls (4-B 선행)
 |
4-D: Turn context injection                   (4-B 선행, playground_repos_json 승격)
 |
4-E: Remove PR #20170 error hints             (4-D 선행)
 |
4-F: Reverse reference removal                (4-B와 독립, 병렬 가능)
```

각 단계는 별도 PR.

## 6. Alignment with RFC-0215

RFC-0215는 keeper를 flat namespace에서 sub-library로 추출하는
캠페인. 본 RFC는 그 캠페인과 독립적으로 진행 가능하다:

| 본 RFC 변경 | RFC-0215와의 관계 |
|-------------|-------------------|
| pre-compute allowed_paths | keeper 내부 `effective_allowed_paths` 시그니처 변경. extraction 전에 적용하면 caller delta 작음 |
| remove repo_manager calls | keeper의 flat-ns fan-out에서 `Keeper_repo_mapping` 제거 — G1(무결기) 개선에 기여 |
| turn context injection | keeper↔tool_surface 경계 변경 없음. extraction과 무관 |
| reverse ref removal | repo_manager 내부 변경. keeper extraction과 무관 |

장기적으로 sandbox module은 RFC-0215 cluster 7(execution, ≈70 modules)
extraction 시 `lib/keeper_sandbox/`로 이동. 본 RFC의
`compute_sandbox_paths`는 그 이동의 자연스러운 seed.

## 7. Risks

| Risk | Mitigation |
|------|------------|
| Pre-compute 후 repo 추가 시 session restart 필요 | Acceptable. repo mapping 변경은 드묾. 현재도 session 중 repo 추가 시 keeper가 인지 못함 |
| `allowed_paths` 정밀도 변경: broad root → specific paths | 더 엄격한 보안. 의도치 않은 접근 경로 차단 효과 |
| Turn context 주입으로 token 증가 | repo당 ~100 token. 20 repo = ~2K token. cache-friendly 위치에 배치 |
| `repository.keepers` 제거로 소비자 4곳 변경 | 컴파일러가 모든 `.keepers` 접근을 나열. `keepers_for_repo`로 기계적 교체 |
| Phase 4-D 전에 4-E 실행하면 LLM blind | Phase ordering 강제. 4-D 완료 전 4-E 금지 |

## 8. PR #20170에 대한 권고

| 변경 | 권고 |
|------|------|
| repo-aware 에러 힌트 (+75줄) | Phase 4-D + 4-E 완료 후 제거 |
| timeout 재분류 | 독립 PR로 분리 추천. 본 RFC와 무관 |
| retired tool 정리 | 독립 PR로 분리 추천. 무해한 cleanup |

## 9. Related

- **RFC-0215**: Keeper sub-library extraction campaign. 본 RFC의 sandbox
  module은 cluster 7 extraction 시 `lib/keeper_sandbox/`로 이동.
- **RFC-0210**: Playground repo currency. repo provisioning과 연관.
- **RFC-0208**: Shell exec 3-layer authorization. tool 실행 보안 모델.
