---
rfc: "0218"
title: "Keeper↔Sandbox↔Repo domain boundary"
status: Draft
created: 2026-06-05
updated: 2026-06-05
author: jeong-sik
supersedes: []
superseded_by: null
related: ["0210", "0213", "0208", "0121"]
implementation_prs: ["20170"]
---

# RFC-0218: Keeper↔Sandbox↔Repo domain boundary

## 0. Summary

Keeper, Sandbox, Repository, Account, AccessPolicy는 서로의 내부를
몰라야 하는 독립 도메인이다. 현재 keeper runtime이 sandbox 파일시스템을
직접 탐색하고, `"repos/"` 경로 규약이 3개 모듈에 산재하며,
repo→keeper 역참조가 정방향 매핑과 중복 저장된다. 이 경계 위반을
단방향 데이터 흐름 + parameter injection으로 교정한다.

Trigger: PR #20170이 `missing_file_error_json`에 +75줄의 repo-aware
에러 힌트를 추가했는데, 이 힌트가 (1) keeper의 sandbox FS 직접
탐색, (2) `"repos/"` 하드코딩 8회, (3) 이미 dashboard에만 쓰이는
`playground_repos_json`의 중복 구현을 포함하고 있어 근본적 설계
재검토가 필요해졌다.

## 1. Problem (code-grounded)

### 1-A. Keeper가 sandbox FS를 직접 탐색한다

`lib/keeper/keeper_tool_shared_runtime.ml` (PR #20170):

```ocaml
let available_repos =
  let repos_dir =
    Filename.concat (Keeper_sandbox.host_root_abs_of_meta ~config meta) "repos"
  in
  Sys.readdir repos_dir                          (* keeper가 FS 탐색 *)
  |> List.filter (fun entry ->
    safe_file_exists (Filename.concat candidate ".git"))  (* sandbox layout 지식 *)
```

의존성 방향 위반: keeper가 sandbox의 디렉토리 구조를 알고 직접 읽는다.

### 1-B. `"repos/"` 경로 규약이 3개 모듈에 산재

| 모듈 | `"repos"` 출현 | 맥락 |
|------|-----------------|------|
| `keeper_tool_shared_runtime.ml` | 8회 (PR #20170) | 에러 메시지 |
| `keeper_repo_mapping.ml` | 4회 (L210-226) | `playground_path_of_path` |
| `keeper_sandbox_control.ml` | 4회 (L351,387,407,426) | `playground_repos_json` |
| `keeper_sandbox.ml` | 1회 (구조적) | `repos_arg` 필드 |

SSOT가 없다. 한 곳에서 `"repos"`를 `"repositories"`로 바꾸면
나머지 3곳이 조용히 깨진다.

### 1-C. 역참조 중복

```
keeper_repo_mappings.toml:   keeper_id → repository_ids[]  (정방향)
repository.keepers:          repo → keeper_ids[]            (역방향, 중복)
```

같은 관계를 두 출처에서 저장. 한쪽만 변경 시 분기(bifurcation).
역방향 질의는 정방향에서 computed로 해결 가능하다.

### 1-D. Repo 정보가 LLM turn context에 없다

`playground_repos_json` (`keeper_sandbox_control.ml:421`)은 이미 repo
목록 + git enrichment(branch, latest_commit, shallow)를 계산한다.
하지만 이 데이터는:

- dashboard/status API (`keeper_status_detail.ml`) — 사용
- sandbox status (`keeper_sandbox_control.ml:590`) — 사용
- **LLM turn context** — **미사용**

결과: LLM이 자기 sandbox에 어떤 repo가 있는지 **오직 tool 에러
메시지로만** 학습한다. 에러마다 FS를 탐색해서 힌트를 만드는 건,
turn 시작 시 한 번만 주면 될 걸 매 에러마다 반복하는 셈.

### 1-E. Tool이 너무 똑똑하다

Read/Execute tool이 에러 발생 시:

1. sandbox FS 탐색으로 repo 목록 계산
2. `"repos/"` 경로 조합으로 recovery hint 생성
3. LLM에게 `next_action`, `recovery_examples` 제안

Tool은 **명령 실행 + 결과 반환**이어야 한다. 에러 enrichment는
tool의 책임이 아니다.

## 2. Domain model (target state)

```
Repository          AccessPolicy          Keeper
(식별만)            (단방향)              (실행 주체)
  id      ◄── ref id ── keeper→repos ── ref id ──►  id
  url                  역참조 없음
  default_branch
  provider
     │
     │ cloned into
     ▼                                      runs in
Account                                    Sandbox
(자격증명)         clone/sync 시에만 소비    (실행 환경)
  env vars ────────────────────────────────── SandboxLayout
                                               "repos/" SSOT
```

### 각 도메인이 아는 것 / 모르는 것

| 도메인 | 안다 | 모른다 |
|--------|------|--------|
| **Repository** | id, url, default_branch, provider | keeper, sandbox, account |
| **AccessPolicy** | keeper_id → repository_id[] (정방향만) | sandbox layout, account |
| **Sandbox** | 자기 layout 규약, 자기 root | keeper 식별, repo URL, account |
| **SandboxLayout** | `"repos"`, `"mind"` 등 경로 규약 | 나머지 전부 |
| **Account** | 자격증명 값 (env vars) | repo, keeper, sandbox |
| **Keeper runtime** | 자기 id | sandbox layout, repo FS, account |
| **Tool (Read/Execute)** | 실행 + 결과/에러 반환 | sandbox layout, repo context |

역방향 질의(어떤 keeper가 repo X에 접근할 수 있는가?)는
정방향 매핑에서 computed로 해결한다. 저장하지 않는다.

## 3. Implementation phases

### Phase 1: SandboxLayout SSOT + turn context injection

목표: `"repos/"` 산재 제거 + LLM이 turn 시작 시 repo 정보를 받도록.

**1-A. `Keeper_sandbox_layout` 모듈 신규**

```ocaml
(* lib/keeper/keeper_sandbox_layout.ml *)
module Layout = struct
  let repos_subdir = "repos"
  let mind_subdir = "mind"

  let repos_dir ~sandbox_root =
    Filename.concat sandbox_root repos_subdir

  let repo_display_path repo_id =
    Filename.concat repos_subdir repo_id

  let repo_physical_path ~sandbox_root repo_id =
    Filename.concat (repos_dir ~sandbox_root) repo_id

  let allowed_roots ~sandbox_root =
    [ sandbox_root ^ "/"
    ; Filename.concat sandbox_root (mind_subdir ^ "/")
    ; repos_dir ~sandbox_root ^ "/"
    ]
end
```

**1-B. 기존 모듈이 Layout 상수 사용**

- `keeper_tool_shared_runtime.ml` → `Layout.repo_display_path`
- `keeper_repo_mapping.ml:playground_path_of_path` → `Layout.repos_subdir`
- `keeper_sandbox_control.ml` → `Layout.repos_dir`, `Layout.repo_display_path`
- `keeper_alerting_path.ml` → `Layout.allowed_roots`

**1-C. Turn context에 repo 정보 주입**

`keeper_turn_up_create.ml` 또는 `build_keeper_system_prompt`에서
`playground_repos_json`을 한 번 호출하여 LLM context에 추가.

이미 존재하는 데이터(`playground_repos_json`: repo name, path,
branch, latest_commit, shallow)를 dashboard 전용에서 LLM
visible로 승격.

### Phase 2: Keeper에서 sandbox FS 탐색 제거

목표: `missing_file_error_json`이 FS를 직접 읽지 않도록.

**2-A. 시그니처 변경**

```ocaml
(* Before *)
val missing_file_error_json
  :  raw_path:string option
  -> cwd:string option
  -> config:Workspace.config          (* FS 탐색에 사용 *)
  -> meta:Keeper_meta_contract.keeper_meta  (* FS 탐색에 사용 *)
  -> target:string
  -> fallback_dir:string
  -> error:string
  -> string

(* After -- FS 탐색 파라미터 제거 *)
val missing_file_error_json
  :  raw_path:string option
  -> cwd:string option
  -> playground:string               (* caller가 계산해서 전달 *)
  -> target:string
  -> error:string
  -> string
```

**2-B. 에러 메시지 최소화**

Turn context에 이미 repo 정보가 있으므로, 에러 메시지는:

```json
{
  "ok": false,
  "error": "file not found",
  "path": "/resolved/absolute/path",
  "your_playground": "masc-mcp/"
}
```

`available_repos`, `repo_cwd_hint`, `next_action`,
`recovery_examples`의 `cwd=` 필드 등은 제거. LLM이 turn context에서
이미 sandbox 구조를 알고 있으므로 불필요.

### Phase 3: 역참조 제거

목표: `repository.keepers` 필드 제거.

**3-A. `repository` record에서 `keepers` 필드 제거**

```ocaml
(* Before *)
type repository = {
  id : repository_id;
  ...
  keepers : string list;      (* 제거 대상 *)
  ...
}

(* After *)
type repository = {
  id : repository_id;
  ...
  (* keepers 필드 없음 — computed function으로 대체 *)
  ...
}
```

**3-B. 역방향 질의를 computed function으로 대체**

```ocaml
(* keeper_repo_mapping.ml에 추가 *)
let keepers_for_repo ~repo_id ~base_path =
  match load_all ~base_path with
  | Error _ -> []
  | Ok mappings ->
    List.filter_map
      (fun m ->
         if List.mem repo_id m.repository_ids
         then Some m.keeper_id
         else None)
      mappings
```

소비자(dashboard 등)는 `repo.keepers` 대신
`Keeper_repo_mapping.keepers_for_repo` 호출.

### Phase 4: Account 도메인 명시화 (optional, future)

현재 account/credential은 env vars로 관리되며 clone/sync에서만
소비된다. 별도 모듈 분리는 repo provisioning 리팩토링과 함께
검토.

## 4. Phase ordering and dependencies

```
Phase 1 (SandboxLayout + turn injection)
  |
  +-- Phase 1-A: SandboxLayout 신규           (독립)
  +-- Phase 1-B: 기존 모듈 Layout 참조        (1-A 선행)
  +-- Phase 1-C: turn context 주입             (1-B 선행, playground_repos_json 승격)
       |
       v
Phase 2 (keeper FS 탐색 제거)
  |   Phase 1-C 선행 (LLM이 turn context로 repo를 알아야 에러 힌트 제거 가능)
  |
  v
Phase 3 (역참조 제거)
      Phase 2와 독립. 다만 Phase 1-B에서 Layout 상수 사용이 선행.
```

각 Phase는 별도 PR. Phase 1 내에서도 A → B → C 순서로 개별 PR 가능.

## 5. PR #20170에 대한 권고

PR #20170 (merge commit `0343d02cb7`)은 3개 변경을 포함:

| 변경 | 권고 |
|------|------|
| repo-aware 에러 힌트 (+75줄) | Phase 1-C + Phase 2 완료 후 제거 |
| timeout 재분류 (`reclassify_provider_timeout_for_attempt`) | 독립 PR로 분리. 이 RFC와 무관한 정당한 fix |
| retired tool 정리 (`keeper_task_submit_for_verification`) | 독립 PR로 분리. 무해한 cleanup |

repo-aware 힌트는 Phase 1-C(turn context 주입)가 완료된 후에만
안전하게 제거할 수 있다. 그 전에 제거하면 LLM이 sandbox 구조를
알 수단이 완전히 사라진다.

## 6. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Turn context 주입으로 token 증가 | `playground_repos_json`은 repo당 ~100 token. 20 repo = ~2K token. 캐싱된 system prompt 밖에 두어 prompt cache 유지 |
| `repository.keepers` 제거로 기존 소비자 깨짐 | `keepers_for_repo` computed function으로 1:1 대체. 컴파일러가 모든 소비자를 나열 |
| Phase 1-C 전에 PR #20170 힌트를 제거하면 LLM blind | Phase ordering 준수. 1-C 완료 전에 2-B 금지 |

## 7. Related

- **RFC-0210**: Playground repo currency. Repo provisioning 레이어와 연관.
- **RFC-0213**: Sandbox isolation model. `local` profile의 물리적 격리.
- **RFC-0208**: Shell exec 3-layer authorization. Tool 실행의 보안 모델.
- **RFC-0121**: Config dir resolver. `repos/` 경로의 SSOT와 연관.
