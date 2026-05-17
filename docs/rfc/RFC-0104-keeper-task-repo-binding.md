---
rfc: "0104"
title: "Keeper task → default repo binding (sandbox cwd disambiguation)"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0006", "0036", "0070", "0097"]
implementation_prs: []
---

# RFC-0104 — Keeper task → default repo binding

> 2026-05-17 prod observation: keeper `tech_glutton` 가 sandbox root
> `/Users/dancer/me/.masc/playground/docker/tech_glutton` 에서 `git log`
> 시도 → `sandbox root cannot run git/gh: ... multiple sandbox repos exist`
> 차단. 사용자에게 `cwd` 명시 강요. keeper 가 *현재 task 의 default repo*
> 를 추론할 mechanism 이 없다는 사실의 표면화.

## §1 컨텍스트

### §1.1 관측

2026-05-17 08:33 logs:

```
ERROR Keeper keeper:tech_glutton tool_error: Bash —
  "sandbox root cannot run git/gh: mount point
   /Users/dancer/me/.masc/playground/docker/tech_glutton is not a git
   repository and multiple sandbox repos exist. Set cwd explicitly before
   retrying. Example next call: keeper_bash { cmd: ... cwd: repos/deepclaude }.
   Available repos: deepclaude, masc-mcp. Do not retry the same cmd from
   sandbox root."
```

이어서 `registry: recording error name=tech_glutton` + circuit_breaker
fail counter 증가. keeper 가 *어떤 repo* 인지 답하지 못해 *retry 폭격* 후
*operator intervention* 까지 escalate.

### §1.2 boundary 분류

| layer | 정책 |
|---|---|
| sandbox FS mount | RFC-0070 §3.2 — sandbox root 위에 `repos/<id>/` 다중 mount 정책 |
| `keeper_bash`/`keeper_shell` git allowlist | RFC-0006 §4 — multiple repos 시 git/gh 실행 시 cwd 명시 요구 |
| **task → repo binding** | **누락** — 본 RFC 가 채움 |

현재의 hard-fail (cwd 강요) 는 *결정론적*이라 안전. 그러나 keeper 가
*default 를 알 수 없는 root cause* 는 *task 와 repo 의 binding 부재*.

### §1.3 RFC-0006 / 0070 / 0097 과의 관계

- **RFC-0006** (Keeper Tool Surface Realignment) — keeper_bash/keeper_shell
  의 *외부 표면* 정의. cwd 파라미터 자체는 RFC-0006 의 표면 일부.
- **RFC-0070** (Sandbox Pure/Edge Separation) — sandbox FS mount 의
  *Phase 4* prep 단계. multi-repo mount layout 자체는 RFC-0070 scope.
- **RFC-0097** (Sandbox Container Reuse) — keeper-당 long-running 컨테이너.
  default cwd 가 *컨테이너 lifetime* 동안 stable 한지의 invariant 가
  본 RFC 와 결합.

본 RFC 는 위 셋의 *gap* — *task 의 metadata 에 어떤 repo 가 default 인지의
typed field* — 만 다룬다. mount layout / sandbox semantics / container
lifecycle 은 모두 기존 RFC scope.

## §2 문제 명세

### §2.1 typed gap

`Masc_domain.task` 의 현재 schema (`lib/masc_domain/masc_domain.ml` 추정):

```ocaml
type task = {
  id : string;
  goal_id : string option;
  title : string;
  description : string;
  task_status : task_status;
  assignee : string option;
  priority : priority;
  required_tools : string list;
  (* ... *)
}
```

`title` 또는 `description` 본문에 `"in masc-mcp"`, `"on repos/deepclaude"`
같은 *string hint* 가 들어가지만 *typed binding 은 없음*.

keeper 가 task 를 claim 하면 sandbox 시작 시 cwd 를 *어디로 set 할지* 의
*결정 알고리즘 자체가 없음*. 결과: 매 git 호출마다 hard-fail.

### §2.2 *추론 시도가 워크어라운드인가?*

worktree 매핑 추정 후보 — 그러나 모두 *symptom 억제* 시그니처:

1. **title 의 substring 분류기** — `String.contains title "masc-mcp"` →
   RFC-0089 분류기 anti-pattern.
2. **goal description 의 prose parse** — *string-as-protocol* (RFC-0091
   keeper-bash typed-argv 와 동일 anti-pattern).
3. **assignee → repo 매핑 외부 table** — *cross-cutting state* 추가.
4. **fallback 첫 번째 repo** — *Unknown → Permissive Default* (V13 / OAS #555).

모든 후보가 *root-fix 아닌 워크어라운드*. typed field 가 정답.

## §3 제안: typed `default_repo` field on `task`

### §3.1 schema 변경

```ocaml
(* lib/masc_domain/masc_domain.ml — extend [task] *)
type task = {
  ...
  default_repo : repo_id option;
  (* None = sandbox root 에서 작동 OK 한 *repo-agnostic* task
     (e.g. health check, ledger update).
     Some _ = git/gh 호출 default cwd. *)
}

(* lib/masc_domain/repo_id.ml — new module *)
type repo_id = private string  (* opaque, parsed at boundary *)

val of_string_exn : string -> repo_id  (* trim + non-empty + no '..' / '/' *)
val to_string : repo_id -> string
val equal : repo_id -> repo_id -> bool
```

`repo_id` 는 *boundary parsed* (Alexis King's *parse-don't-validate*).
input 은 `masc_add_task`, `masc_update_task` 의 typed param.

### §3.2 sandbox / cwd 처리

`keeper_bash` / `keeper_shell` / `masc_code_shell` 의 cwd 결정 알고리즘:

```ocaml
let resolve_default_cwd
    ~(current_task : Masc_domain.task option)
    ~(call_cwd : string option)
    ~(sandbox_repos : Masc_domain.repo_id list)
    : (cwd, cwd_error) result =
  match call_cwd, current_task with
  | Some explicit, _ -> validate_explicit explicit sandbox_repos
  | None, Some t ->
    (match t.default_repo with
     | Some r when List.mem r sandbox_repos -> Ok (Repo_cwd r)
     | Some r -> Error (Repo_not_mounted r)
     | None -> Ok Sandbox_root_cwd)
  | None, None ->
    (match sandbox_repos with
     | [] -> Ok Sandbox_root_cwd
     | [single] -> Ok (Repo_cwd single)
     | _ -> Error Multi_repo_no_task_binding)
```

`Multi_repo_no_task_binding` 가 **현재 production 에 보이는 정확한
error**. 본 RFC 가 해결.

### §3.3 RFC-0070 mount 정책 확장

기존 sandbox mount layout (RFC-0070 §3.2 추정):

```
<sandbox_root>/
  repos/
    <repo_id>/    <- git repo mount per task.default_repo
```

본 RFC 는 *어떤 repo 가 mount 되어야 하는지* 의 결정 정책을 추가:

- task 의 `default_repo = Some r` → r 이 mount 되어야 함 (필수)
- task 의 `required_repos = [r1; r2]` → 추가 mount (optional 확장, 본
  RFC scope 밖)

mount-time validation 은 RFC-0070 Phase 4 의 책임.

## §4 Migration

### Phase 1 — typed field 추가 (inert)

- PR-1: `Masc_domain.repo_id` module + `task.default_repo` field
  (default `None`). schema migration 0-effect: 기존 task 는 `None`.
- 모든 reader 가 `None` 을 *현재 동작* (multi-repo hard-fail) 로 처리.

### Phase 2 — keeper_bash cwd resolver

- PR-2: `resolve_default_cwd` 함수 추가 + keeper_bash/keeper_shell call
  사이트 wiring. error variant `Multi_repo_no_task_binding` 도입.
- *현재 error message* 와 동일한 hard-fail 유지 — typed 만 강화.

### Phase 3 — task creation API

- PR-3: `masc_add_task` / `masc_update_task` 에 `default_repo` typed
  param. dashboard form 추가.
- 기존 keeper persona presets (`config/keepers/*.toml`) 의 task template
  에 `default_repo` 명시 옵션.

### Phase 4 — auto-binding heuristic (optional, behind RFC-0089 gate)

- task title/description 에서 *repo 후보 추출* 은 *RFC-0089 의 typed
  parser* 가 ready 된 후만 시작. 그 전에는 명시 binding 만.

### Phase 5 — RFC-0070 mount validator

- mount-time invariant: 만약 task 의 `default_repo = Some r` 이면 sandbox
  startup 에서 r mount 검증. RFC-0070 Phase 4 의 follow-up PR.

## §5 비범위

- task title/description 의 *natural-language* repo 추출 (Phase 4 후보,
  본 RFC 머지 후 RFC-0089 와 합쳐 별도 RFC).
- repo discovery (어떤 repo 가 *available* 한지) — 이미 sandbox mount
  inventory 가 처리.
- cross-repo task (한 task 가 다중 repo 수정) — `required_repos`
  확장 후보, 본 RFC scope 밖.

## §6 Anti-pattern self-check

RFC-0088 § Counter-as-Fix + RFC-0089 § String-Classifier audit:

| anti-pattern | 본 RFC 의 위치 |
|---|---|
| Telemetry-as-fix | NO — typed field, 동작 fix |
| String classifier | NO — `repo_id` typed (opaque parsed boundary) |
| N-of-M | NO — 모든 task 가 동일 field, sole resolver |
| Catch-all `_` | NO — exhaustive `match` on `default_repo` |
| Cap/cooldown/dedup/repair | NO |
| Test backdoor | NO |
| 반복 typo | NO |

## §7 결정 evidence

- 2026-05-17 08:33 sandbox root cannot run git/gh — 단일 sample, 다중
  repo (deepclaude + masc-mcp) tech_glutton keeper.
- 24h log audit 권장 — 같은 error pattern 의 빈도 측정 후 본 RFC §1.1
  업데이트. Phase 1 시작 *전* baseline 수집 의무.

## §8 Open questions

- `repo_id` 의 *validation*: `[a-z0-9_-]+` 만? path traversal 가드
  (`..` 거부) 는 boundary 책임 — 어디서 enforce?
- `default_repo = Some r` 가 mount 안 된 상태 → error code Phase 2 의
  `Repo_not_mounted r` 외 *추가 보복 정책* 필요? (task auto-pause? operator
  notify?) — Phase 2 PR 의 §4 결정.
- Worktree 분리 task (한 keeper 가 같은 repo 의 다른 branch 작업)? —
  `default_repo` 가 *repo_id only* 면 worktree-level binding 미지원. 후속
  RFC.

## §9 Related & supersedes

- Related: RFC-0006 (Keeper Tool Surface), RFC-0070 (Sandbox Pure/Edge),
  RFC-0036 (Multi-Keeper Docker Orchestration), RFC-0097 (Container Reuse).
- Supersedes: none.
- Superseded by: TBD.
