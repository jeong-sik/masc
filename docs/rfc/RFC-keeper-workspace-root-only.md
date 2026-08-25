---
rfc: "keeper-workspace-root-only"
title: "시스템은 workspace root 만 정한다 (레이아웃 규정 폐기)"
status: Draft
created: 2026-08-13
updated: 2026-08-13
author: vincent
related: ["0312", "0343", "0324", "0128"]
---

# RFC — 시스템은 workspace root 만 정한다 (레이아웃 규정 폐기)

- Related: RFC-0312 (keeper-repo-mapping advisory scope, **Accepted**), RFC-0343 (repo location SSOT), RFC-0324 (filesystem repo truth), RFC-0128 §4.5 (write partition)
- Absorbs: RFC-0343 §3.1 (reverse-parse → git-remote attribution) — 이 RFC 의 구현 단계에 포함된다
- Replaces: RFC-0364 (keeper 당 체크아웃 하나) — 그 RFC 의 §5 Open Q1 자기무효화 조항이 발동해 삭제됐다. 근거는 §6.

## 0. Summary

masc 는 keeper 의 체크아웃이 `<playground_root>/repos/<repo_name>/` 에 있다고 **규정**한다. 그 경로를 스캔하고, 역파싱해 저장소 정체성을 추론하고, 프롬프트로 keeper 에게 가르친다.

그런데 **시스템은 그 구조를 만들지 않는다.** per-keeper clone 코드는 PR #24558 에서 삭제됐고 keeper 가 스스로 clone 한다. 만들지도 않는 구조를 읽고 가르치는 상태다.

이 RFC 는 레이아웃 규정을 폐기한다. 시스템은 **workspace root 만 정하고**, 그 아래 무엇이 어디에 있는지는 **git 으로 실측 관측**한다. keeper 가 체크아웃을 몇 개 두든 어떻게 배치하든 keeper 소관이다.

## 1. Problem (evidence)

### 1.1 규정은 이미 깨져 있고, 관측만 잃고 있다

`<base-path>/.masc/playground/` 아래 `.git` 전수 조사 (2026-08-13, 운영 인스턴스 실측). keeper 들이 이미 `repos/` 밖에 체크아웃을 만들었고 시스템은 그것들을 보지 못한다.

| 실제 위치 | 종류 | 현재 관측 |
|---|---|---|
| `code-reviewer/.masc/repos/vp-tempo-cli/` | 주 체크아웃 | 안 보임 |
| `sangsu/.masc/repos/vp-slugify-lib/` | 주 체크아웃 | 안 보임 |
| `kidsnote/.tmp/task136-fix/` (외 2건) | worktree | 안 보임 |
| `analyst/repos/masc/` (외 14건) | 주 체크아웃 | 보임 |

규정 밖 6건은 전부 `git rev-parse --show-toplevel` 이 자기 자신을 반환하는 진짜 체크아웃이다. `kidsnote/.tmp/task136-fix` 의 origin 은 `github.com/kidsnote/kidsnote_web_inapp.git` 이다.

**이 RFC 를 채택하지 않는 것은 현상 유지가 아니라 손실 누적이다.**

### 1.2 세 스캔의 판정 기준이 서로 다르다

같은 질문("이 keeper 의 체크아웃은 무엇인가")에 세 곳이 각각 다르게 답한다.

| 위치 | 체크아웃 판정 | 실패 처리 | 답을 받는 쪽 |
|---|---|---|---|
| `keeper_sandbox_control.ml:289` | 디렉터리면 전부 (`.git` 무관) | `Sys_error` 면 warn 후 `[]` | 대시보드 |
| `keeper_turn_sandbox_runtime.ml:158` | 디렉터리 + `.git` 필수 | `[]`, 로그 없음 | 턴 런타임 cwd 투영 |
| `keeper_tool_filesystem_runtime.ml:206` | 디렉터리 + dot-prefix 제외 | `[]`, 로그 없음 | 모델 대면 에러 힌트 |

즉 대시보드가 보는 집합, 런타임이 인식하는 집합, keeper 에게 알려주는 집합이 다르다. 그리고 셋 다 "체크아웃 0개" / "디렉터리 없음" / "읽기 실패" 를 `[]` 하나로 접어 호출자가 구별할 수 없다.

세 번째 함수의 주석(`:203-205`)은 이미 올바른 원칙을 적어 뒀다:

> An empty set is reported as empty rather than omitted, because "no repository is materialized" is the answer to a different question than "you named the wrong one".

구별의 중요성을 알면서 **실패 축에서는 놓쳤다** (`:212` 가 `Sys_error` 를 `[]` 로 삼킨다). 이 주석이 인용한 #23442 는 live taskmaster 가 잘못된 prefix 로 무한 재시도한 사고다 — 관측 불일치가 실제로 keeper 를 멈춘 전례.

### 1.3 가르친 레이아웃이 이미 두 번 거짓이 됐다

- 프롬프트 불변식 *"every catalog id resolves under `repos/<name>/`"* 가 거짓이어서 제거됐다 (RFC-0324 B-1). 그 전까지 `path_not_found` **379건/24h** (2026-07-08 audit). keeper 들이 clone 된 적 없는 경로를 믿었다.
- 남은 잔여물도 이미 거짓이다. `tool_shard_types_schemas_search_files.ml:12` 가 `'repos/X' or 'scratch/X'` 를 가르치는데 **`scratch/` 를 만드는 코드가 없다.** `scratch` 는 코드베이스 전체에서 그 문장과 `keeper_run_tools_hooks.ml:78` 허용목록 두 곳에만 존재한다.

산문이 거짓이 되는 것은 사고가 아니라 이 설계의 정상 동작이다. **시스템이 만들지 않는 것을 가르치면 언젠가 반드시 어긋난다.**

### 1.4 역파싱이 이미 귀속을 잃고 있다

`Playground_paths.parse_playground_repo_path` (`playground_paths.ml:141`) 는 정확히 두 레이아웃만 매치한다:

```ocaml
| ".masc" :: "playground" :: rest -> (
  match rest with
  | "docker" :: _keeper :: "repos" :: repo :: r when repo <> "" && r <> [] -> Some (...)
  | _keeper :: "repos" :: repo :: r when repo <> "" && r <> [] -> Some (...)
  | _ -> None)
```

§1.1 의 규정 밖 6건에 쓴 파일은 전부 `None` 으로 떨어진다. 그 keeper 들의 편집은 canonical-URL 버킷에 귀속되지 않는다.

같은 함수의 주석(`:158-162`)이 왜 스캔이 아니라 구조적 파싱인지 설명한다 — *"keeper names can themselves be `repos`"*, *"repository working trees may legitimately contain nested `.masc/playground` directories"*. 경로 문자열로 정체를 알아내려는 시도가 이미 방어 코드를 여러 겹 요구하고 있다.

### 1.5 강제하지 않기로 한 것을 레이아웃으로만 규정하고 있다

RFC-0312 (**Accepted**, PR #23359) 가 "keeper repo 매핑은 advisory default scope 이지 access cap 이 아니다" 를 확정했다. 매핑은 접근을 막지 않는다.

그런데 레이아웃 규정은 남아 있다. **강제력 없는 정책을 디렉터리 구조로만 표현하는 상태**이며, 이는 두 선택지 중 어느 쪽도 아니다:

- 강제한다면 `repository_scope` 가 실제로 접근을 막아야 한다 — RFC-0312 가 명시적으로 기각했다.
- 강제하지 않는다면 레이아웃으로 흉내 낼 이유가 없다.

### 1.6 기성 하네스는 root 만 정한다

> **Evidence Record**
> - Evidence: OpenClaw 공식 문서 <https://docs.openclaw.ai/gateway/sandboxing>, Hermes Agent 문서/이슈 <https://github.com/NousResearch/hermes-agent>, Orca <https://github.com/rasca/orca>
> - Timestamp: 2026-08-12T16:51Z (KST 2026-08-13 01:51)
> - Confidence: High (OpenClaw·Hermes 는 공식 문서 확인, Orca 는 저장소 설명 확인)
> - Delta: 세 하네스 모두 마운트 지점과 접근 모드는 규정하나 **저장소 체크아웃의 내부 위치는 규정하지 않음**을 확인. masc 만 `repos/<repo>` 를 강제한다.

| 하네스 | 시스템이 정하는 것 | 시스템이 정하지 않는 것 |
|---|---|---|
| **OpenClaw** | 마운트 지점(`/workspace` rw, `/agent` ro, `~/.openclaw/sandboxes` none)과 접근 모드. 키는 `agents.defaults.sandbox.workspaceAccess`, agent 별 override 가 우선 | root 아래 저장소 배치 규약 없음 |
| **Hermes** | `/workspace` 와 `/root` bind-mount, `container_persistent` 로 영속, `docker_volumes` 로 호스트 디렉터리 마운트 | root 아래 레이아웃 규약 없음 |
| **Orca** | git worktree 를 만들고 Docker 컨테이너의 `/workspace` 에 마운트 | 그 안의 구조는 프로젝트 것 |

셋 다 **"어디에 마운트하고 어떤 권한인가"** 를 정하고 **"그 안을 어떻게 쓰는가"** 는 정하지 않는다.

## 2. Non-goals

- **다중 체크아웃 능력의 제거.** keeper 는 저장소 여러 개를 다룬다. 이 RFC 가 없애는 것은 그 능력이 아니라 배치에 대한 규정이다.
- **저장소 정체성 저장 방식 변경.** `repositories.toml` 이 identity SSOT 로 남는다.
- **마이그레이션.** §3.4 참조 — 필요 없다.
- **keeper credential / GitHub identity.** 별도 RFC 게이트 영역.
- **오퍼레이터 작업 트리 `.masc/repos/<id>`.** playground 의 `repos/` 와 이름만 같은 별개 개념이다 (`config_dir_resolver.ml:435-441`, `Repo_manager` 소유). 건드리지 않는다.
- **Docker `docker/` 세그먼트 존폐.** 역파싱이 사라지면 이 분기의 존재 이유도 사라지지만, 결정은 후속으로 분리한다.

## 3. Design

### 3.1 시스템은 root 만 정한다

```
현재:  시스템이 <root>/repos/<repo>/ 를 규정하고, 스캔하고, 역파싱하고, 가르친다
변경:  시스템은 <root> 를 정한다. 그 아래는 keeper 가 쓴다.
```

`Keeper_sandbox_config.host_root_abs_of_agent` 가 반환하는 경로가 keeper 의 workspace root 다. 시스템이 그 아래에 만드는 디렉터리는 없다.

**root 를 정하는 곳이 현재 둘이다.** `keeper_sandbox_config.ml:67-73` 과 `keeper_sandbox.ml:94-100` (`host_root_rel_of_backend`) 에 Local/Docker 분기가 문자열까지 복제돼 있고, meta 경로(`:117-118`)는 config 모듈을 거치지 않고 복제본을 쓴다. root 를 정하는 곳이 둘이면 "root 만 정한다" 는 명제 자체가 성립하지 않으므로 통합한다.

### 3.2 관측은 git 실측으로

규정을 없앤 자리를 산문이나 다른 규약으로 채우지 않는다. **git 이 답한다.**

| 질문 | 현재 | 변경 후 |
|---|---|---|
| 이 keeper 의 체크아웃은? | `<root>/repos/` 나열 | root 아래에서 `.git` 을 실측 발견 |
| 이 파일은 어느 저장소인가? | 경로 역파싱 | `git remote get-url origin` |
| repo 상대 경로는? | 세그먼트 산술 | `git rev-parse --show-toplevel` 기준 |

발견 규칙은 하나다: **`<dir>/.git` 이 존재하고 심링크가 아니면 `<dir>` 은 체크아웃이며, 그 하위로는 내려가지 않는다.** `.git` 이 디렉터리면 주 체크아웃, 정규 파일이면 linked worktree 또는 submodule 이다.

이 단일 규칙이 세 가지를 부수 효과로 해결한다:

- `_build/.sandbox/.git`, `node_modules/*/.git` 은 발견된 체크아웃 **내부**에 있으므로 자동으로 걸러진다. 이름 기반 블랙리스트가 필요 없다.
- `.worktrees/<task>/` 는 부모 체크아웃에서 정지되므로 별도 계수 규칙이 필요 없다. **`.worktrees` 라는 이름을 특별 취급하는 코드가 한 줄도 필요 없다** — 실측상 worktree 는 그 관례 밖에도 놓인다.
- 깊이 상한이 필요 없다. 상한은 *"체크아웃은 root 로부터 N 단계 안에 있어야 한다"* 를 강제하는 규정의 약한 형태이고, 어기면 **조용히 안 보인다** — 이 RFC 가 없애려는 실패 클래스 그 자체다.

실측 비용 (12 keeper, 2026-08-13): 최악 495 readdir 엔트리 / 107 디렉터리, 중앙값 34 엔트리. 폭발을 막는 것은 깊이가 아니라 체크아웃에서의 정지다.

### 3.3 모델에게 레이아웃을 가르치지 않는다

경로 규약을 산문으로 가르치는 것이 §1.3 의 두 사고를 만들었다. 대신 keeper 는 이미 관측 채널을 갖고 있다:

- `Keeper_sandbox_repo_path.execution_location_json` 이 Execute 응답마다 `scope` / `playground_root` / `relative_cwd` 를 실측으로 돌려준다.
- `tool_list_dir` / `tool_read_file` 로 직접 확인할 수 있다.

**관측은 거짓이 될 수 없고, 산문은 될 수 있다.**

메인 프롬프트의 `<workspace>` 블록(`keeper_prompt.ml:56-68`)은 이미 이 형태다 — root 절대경로와 규약(상대 `cwd` 사용)만 말하고 레이아웃을 언급하지 않는다. 오염은 툴 스키마와 에러 힌트에만 있다.

산문을 지우는 방식은 **경로 예시를 다른 경로 예시로 바꾸는 것이 아니라 관측 보고로 바꾸는 것**이다:

```
현재: no repository is materialized under repos/ for this keeper,
      so no repos/<repo> cwd exists yet
변경: no git checkout found under your workspace root

현재: available repo cwds: repos/masc, repos/agent_core
변경: git checkouts under your workspace root: masc, work/agent_core, .tmp/task-12
```

앞의 것은 **어디에 있어야 하는지를 주장**하고 뒤의 것은 **어디에 있는지를 보고**한다. 앞은 틀릴 수 있고(379건/24h 틀렸다) 뒤는 틀릴 수 없다.

단, 경로가 아니라 **규약**을 가르치는 문장은 유지한다. `exec_policy.ml:28,33-34` 의 "체인·리다이렉트 금지, `cd` 대신 `cwd` 인자" 는 레이아웃 규정이 아니므로 예시 경로만 중립적인 것으로 바꾼다.

### 3.4 마이그레이션이 필요 없다

구조를 규정하지 않는다는 것은 **기존 구조도 허용한다**는 뜻이다. 기존 `<root>/repos/masc/` 체크아웃은 git 실측 발견으로 그대로 잡힌다. 대시보드 개수 변화는 실측 기준 `code-reviewer` +1, `kidsnote` +3, `sangsu` +1, 나머지 9개 0 이며 전부 "못 보던 것을 보게 된다" 방향이다.

이것이 RFC-0364 와의 결정적 차이다. 그 RFC 는 레이아웃을 **다른 레이아웃으로 교체**하려 했으므로 hard cut 과 playground 재생성이 필요했다.

### 3.5 사라지는 것

| 대상 | 근거 |
|---|---|
| `"repos"` 경로 세그먼트 리터럴 (프로덕션 20곳 / 9파일) | 조립할 세그먼트가 없다 |
| `ensure_sandbox_bundle` 의 `repos/` mkdir (`keeper_alerting_path.ml:790,812`) | 시스템이 만들지 않는다. **이것이 남으면 모델이 빈 `repos/` 를 보고 규약을 재발명한다** |
| `parse_playground_repo_path` + 호출자 | git 이 답한다 (§3.2) |
| `skip_worktree_prefix` 의 `.worktrees` 하드코딩 | git 이 worktree 를 구분한다 |
| 툴 스키마·에러 힌트의 `repos/X` 산문 9곳 | 관측 채널이 대체 (§3.3) |
| 허용목록의 `"repos"`, `"scratch"` | `scratch` 는 애초에 유령 |
| `repos_arg`, `task_overlay_pattern`, wire `sandbox_repos` | 알릴 구조가 없다 |
| 죽은 `candidate_repo_roots_no_create`, `repos_root_of_playground_root` | 호출자 0 |

### 3.6 남는 것 — `execution_location_scope` 는 삭제가 아니라 재정의

`Repo_root` / `Repo_subpath` 는 현재 경로 문자열 매칭으로 생성되고 소비자가 0 이다. 그러나 **삭제하지 않는다.**

§3.3 이 산문을 지우면서 대체 채널로 지목한 것이 바로 이 `scope` 다. 자유 레이아웃 + 다중 체크아웃 세계에서 모델은 *"내가 지금 체크아웃 루트에 있나"* 를 **더** 알아야 하지 덜 알아야 하지 않는다. 산문을 지우면서 관측 해상도까지 낮추면 남는 것이 없다.

경로 매칭을 `git rev-parse --show-toplevel` 실측으로 바꾸고 `Checkout_root` / `Checkout_subpath` 로 개명한다.

## 4. 검증

이 RFC 를 구현했다고 말하려면 다음이 성립해야 한다.

1. `rg -n '"repos"' lib/ bin/` 이 `config_dir_resolver.ml` 의 `.masc/repos` (오퍼레이터 작업 트리, **별개 개념**) 외에 아무것도 반환하지 않는다.
2. `parse_playground_repo_path` 가 존재하지 않는다.
3. 시스템이 `repos/` 디렉터리를 만들지 않는다.
4. `execution_location_scope` 가 git 실측 기반이다.
5. keeper 가 root 아래 **임의 위치**에 clone 해도 대시보드에 체크아웃으로 보인다 — §1.1 의 6건이 관측된다.
6. 스캔 실패와 체크아웃 0개가 wire 에서 구별된다.
7. 기존 `repos/<repo>` 체크아웃이 계속 발견된다 (§3.4 마이그레이션 불필요의 전제).
8. `path_not_found` 카운터가 변경 전 기준선을 넘지 않는다 (§1.3 재발 방지).

### 4.1 이 설계가 틀렸다고 판정할 조건

근거 없이 밀지 않기 위한 선이다.

| 관측 | 무엇이 틀린 것인가 |
|---|---|
| 정상 playground 에서 스캔 예산이 소진된다 | 비용 추정(최악 495 엔트리)의 전제가 깨짐 |
| 대시보드 체크아웃이 실측 델타(+1/+3/+1)를 크게 초과 | 체크아웃에서의 정지가 예상대로 안 걸린 것 |
| 귀속 실패 비율이 기준선보다 상승 | git 귀속이 어휘 파싱보다 나쁜 경우가 있다 |
| 산문 제거 후 `path_not_found` 가 기준선 초과 | 관측 채널이 산문을 대체하지 못했다 |

## 5. 구현 순서

각 단계는 머지 직후 시스템이 일관된 상태여야 한다.

| 단계 | 내용 | 성격 |
|---|---|---|
| 1 | 체크아웃 발견·조립·생성·힌트 실측화 (§3.2, §3.5 의 mkdir 포함) | 관측 확대 |
| 2a | git 인프라: `get_origin_url` 에 timeout·read-only env, checkout 단위 캐시, typed `Unattributed` | 행동 변화 없음 |
| 2b | 귀속 전환 (§3.2) — 플래그 뒤에 | 토글 롤백 |
| 3 | 모델 대면 산문 + `scratch` 허용목록 + `sandbox_repos` wire | 합쳐야 함 |
| 3b | GC/FD 스크립트 (`rm -rf` 경로라 분리) | dry-run 근거 필요 |
| 4 | 잔여 타입/필드 | 컴파일러 검증 |
| 5 | `validate-prompt-paths.sh` 를 실제 대상 + lower-bound 어서션으로 교체 | 게이트 복구 |

순서 제약:

- **1 이 3 보다 먼저.** 산문을 먼저 지우면 시스템은 `repos/` 만 보는데 keeper 는 딴 데 clone 한다.
- **3 과 4 는 두 지점에서 분리 불가.** `scratch` 는 산문과 허용목록이 짝이고, `sandbox_repos` 는 산문과 wire 가 짝이다. 한쪽만 지우면 각각 반쪽 상태가 된다.
- **2b 는 플래그 뒤.** RFC-0343 §5 가 이미 권고한 것이며, 롤백이 코드 revert 가 아니라 토글이 되어 3·4 와의 순서 결합이 끊긴다.

### 5.1 2a 가 선행 단계인 이유

RFC-0343 §3.1 은 *"Both git ops already exist and are **bounded**. No new infrastructure."* 라고 쓴다. **절반만 맞다.**

`repo_git.ml:193` 의 `get_origin_url` 에는 `~timeout_sec` 도 `~env:read_only_git_env` 도 없다. `run_git` 의 기본값이 `None` 이라 무제한이다 (`worktree_root` 는 5초 바운드 + read-only env 로 되어 있다). 그리고 이것이 얹히는 자리는 `keeper_run_tools_hooks.ml:269-275` — **모든 툴 호출의 post-hook** 이다. 지금은 순수 문자열 파싱이다.

캐시 없이 전환하면 툴 호출마다 git 서브프로세스 2개, 그중 하나는 타임아웃 없음이 된다.

### 5.2 2b 가 반드시 처리해야 할 것

전환이 귀속을 **후퇴**시키는 라이브 사례가 있다:

```
$ git -C .../code-reviewer/repos/masc/review-pr-28304 remote get-url origin
/Users/dancer/me/.masc/repos/masc
```

로컬 경로 origin 이라 `canonical_url_of_remote` 가 `None` 을 반환한다. 오늘 이 경로는 역파싱 → 카탈로그 조회로 정상 귀속된다. 순진하게 전환하면 정상 → 고아로 후퇴한다. **origin 이 canonicalize 안 되면 그 로컬 경로를 등록 repo 의 `local_path` prefix 와 매칭하는 폴백이 필요하다.**

그리고 동일 origin N-클론(`sangsu/repos/{masc, masc-wtask-188, -195, -204, -205}`)이 한 버킷으로 붕괴한다. RFC-0128 §4.5 의 조인 의도로는 옳지만 동시 작업 격리가 관측층에서 사라지므로, checkout 판별자를 record 에 넣을지의 결정은 **RFC-0378 §5.1 이 소유한다** — 판별자는 넣되 join key 가 아니라 projection 메타데이터이며, region 레코드 한정이 아니라 Code fact 전체에 같은 자리로 들어간다. 2b 는 그 계약을 소비만 한다.

## 6. RFC-0364 를 대체하는 근거

RFC-0364 는 같은 문제(§1.3, §1.4)를 진단했으나 해법이 **레이아웃을 다른 레이아웃으로 교체**하는 것이었다 — `<root>/repos/<repo>/<file>` → `<root>/<file>`, 즉 keeper 당 체크아웃 하나.

그 RFC 는 §5 Open Q1 에 자기무효화 조항을 두었다:

> 다중 저장소를 쓸 계획이 있는가. (…) 계획이 있다면 이 RFC 는 무효이고, 대신 `repository_scope` 를 실제로 강제하는 쪽이 과제가 된다 — 지금처럼 표시만 하는 상태가 최악이다.

세 가지가 그 조항을 발동시켰다:

1. **다중 체크아웃 계획이 확인됐다.** 사용자가 keeper 가 저장소 여러 개를 다룰 것임을 확정했다.
2. **§1.2 의 근거 데이터가 틀린 authority 를 쟀다.** RFC-0364 §1.2 는 `repositories.toml` 카탈로그(5개 repo)를 재고 "keeper 하나가 저장소 둘 이상을 갖는 사례 0건" 이라 결론했다. 파일시스템은 정반대다 — kidsnote 12개, sangsu 7개, rondo 3개, code-reviewer 3개, analyst 2개.
3. **조항이 제시한 대안도 채택 불가다.** `repository_scope` 강제는 RFC-0312 (Accepted) 를 뒤집는 것이다.

세 번째 길이 이 RFC 다: 강제하지도 않고 규정하지도 않되, **관측은 정확히 한다.**

RFC-0364 에서 살린 것은 §1 의 증거(§1.3, §1.4 로 이식)와 §3.3 의 원칙("관측은 거짓이 될 수 없고, 산문은 될 수 있다")이다. 버린 것은 §3.1 (root = 체크아웃 1개)과 §1.2 (다중 매핑 0건 논증)이다.

## 7. Open questions

1. **`docker/` 세그먼트.** Docker 프로필일 때 호스트 경로가 `<playgrounds>/docker/<keeper>/` 가 되어 저장 경로가 실행 백엔드 이름을 담는다. 역파싱이 사라지면(§3.2) `playground_paths.ml:132` 의 `docker/` 분기도 존재 이유가 사라진다. 이 RFC 와 직교하지만 둘 다 정리하면 레이아웃이 `.masc/playground/<keeper>/` 하나로 수렴한다.
2. **keeper playground 안의 `.masc/repos/`.** `code-reviewer` 와 `sangsu` 가 자기 playground 안에 `.masc/repos/` 를 만들었다. `keeper_runtime_contract.ml:287-291` 은 `.masc` 를 sandbox filesystem target 이 아니라고 금지하는데, `keeper_run_tools_hooks.ml:74-79` 허용목록은 `.masc` 를 통과시킨다. 계약문과 코드가 어긋나 있다 — 어느 쪽이 옳은지 결정이 필요하다.
3. **`sandbox_rooted_relative_path` 의 존재 근거.** 이 함수는 "이 상대경로가 이미 sandbox-rooted 인가, cwd-상대인가" 를 고정 어휘(`repos`/`scratch`)로 판정한다. 어휘가 사라지면 판정이 불가능하다. keeper 가 클론을 `masc/` 에 두면 `{file_path="masc/lib/foo.ml", cwd="masc"}` 가 **오늘도 이미** 이중 앵커된다. 툴이 실제로 쓰는 리졸버 결과를 hook 이 재사용하는 것이 근본 해법이지만, 범위가 이 RFC 를 넘는다.
