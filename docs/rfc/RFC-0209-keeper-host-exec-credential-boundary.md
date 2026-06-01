---
rfc: RFC-0209
title: Keeper Host-Exec Credential Boundary
author: jeong-sik
created: 2026-06-02
status: Draft
related:
  - RFC-0019 (Keeper Credential Unification — F-1 invariant)
  - RFC-0070 (Keeper Sandbox Pure/Edge Separation — §82-83 host-path credential brokering defer)
  - RFC-0126 (Silent Fallback Discipline — fail-closed)
issue: "#19770"
supersedes: -
---

# RFC-0209: Keeper Host-Exec Credential Boundary

## §0 Summary

Local keeper의 host 명령 실행 경로가 호스트 환경변수를 scrub 없이 상속해, operator의 `GH_TOKEN` / `SSH_AUTH_SOCK` / `GIT_CONFIG_*`가 keeper 자식 프로세스로 흘러간다. keeper는 자기 credential bundle이 아니라 operator 자격으로 git network 작업을 수행하며, 이는 RFC-0019 F-1 invariant("the credential boundary IS the token; anything weaker is cosmetic")를 위반한다.

본 RFC는 host-exec env 경로를 F-1 enforcement 범위로 끌어들인다. Docker 경로가 이미 사용하는 `Env_keeper_scrub.filter_environment`를 host 경로에도 적용하고(Option A), 후속으로 host-path credential bundle 주입(Option B)을 정의한다.

## §1 Problem

### 1.1 git identity/credential은 환경변수로 귀결된다

keeper의 git identity와 credential은 최종적으로 다음 환경변수로 표현된다: `GIT_AUTHOR_NAME/EMAIL`, `GIT_COMMITTER_NAME/EMAIL`(identity), `GH_TOKEN`/`GITHUB_TOKEN`/`SSH_AUTH_SOCK`/`GH_CONFIG_DIR`/`GIT_CONFIG_GLOBAL`(credential). 이 값들이 자식 프로세스(`git`, `gh`)에 어떻게 주입/차단되는가가 credential boundary의 실체다.

현재 3경로가 존재하며 일관성이 없다:

| 경로 | 위치 | env 구성 | scrub | 상태 |
|------|------|---------|-------|------|
| A (dead) | `keeper_identity.git_env_for_keeper` | `Unix.environment()` + `@masc.local` override | 부분 | **제거 완료** (#19768) |
| B (Docker) | `credential_bundle.compose_base_with_credential_bundle` | `filter_environment(Unix.environment())` + bundle 주입 | 완전 | 안전 |
| **C (local/host)** | `exec_dispatch.resolve_host_env` | `Unix.environment()` 통째 상속 + override만 필터 | **없음** | **ACTIVE_LEAK** |

### 1.2 Leak (경로 C)

`lib/exec/exec_dispatch.ml:122 resolve_host_env`:

```ocaml
let resolve_host_env = function
  | [] -> None
  | env_bindings ->
      let overrides = resolve_env env_bindings |> Array.to_list in
      let override_keys = List.map env_key overrides in
      let inherited =
        Unix.environment ()                       (* ← scrub 없음 *)
        |> Array.to_list
        |> List.filter (fun entry ->
          not (List.mem (env_key entry) override_keys))
      in
      Some (Array.of_list (inherited @ overrides))
```

override로 명시된 키만 교체하고, 나머지 호스트 환경(operator `GH_TOKEN` 포함)은 그대로 자식에게 전달한다. 두 번째 leak 지점은 pipeline-stage 빌더 `host_pipeline_specs`(line 235)로 동일 패턴이다.

live keeper 14/16이 local 프로파일이므로 이 경로가 dominant다.

### 1.3 F-1 corner

RFC-0019 P1: "The credential boundary IS the token. Two identities with the same token share capabilities, regardless of labels. Any identity separation weaker than per-token enforcement is cosmetic." 그러나 RFC-0019 텍스트는 `Sandbox_target`, `resolve_host_env`, `Env_keeper_scrub`, `sandbox_profile`을 언급하지 않는다 — host-exec env 경로는 F-1 invariant의 **unenforced corner**다. keeper가 operator token으로 push하면 credential bundle 레이블은 cosmetic이다.

## §2 Caller-world (검증됨)

`Exec_dispatch.dispatch_decided`의 production 호출처는 정확히 둘이다:

1. **keeper chokepoint** — `lib/keeper/agent_tool_execute_shell_ir.ml:145` (`dispatch_classified`). 모든 keeper Host producer가 여기로 수렴.
2. **server 자체** — `lib/.../worker_dev_tools.ml:482` (`for_keeper_command = false`, keeper 모듈 우회).

`dispatch`/`dispatch_simple`/`dispatch_pipeline`은 public이지만 production 호출처 없음(테스트/문서만). 따라서 **scrub을 keeper chokepoint에만 적용하면 비-keeper(서버) 경로는 구조적으로 무영향**이다.

keeper Host producer 4종(모두 chokepoint 경유):

1. `agent_tool_execute_runtime.ml:120` — Local keeper, network-git (실제 leak 모집단).
2. `keeper_workspace_ops.ml:74` — 전 keeper hardcoded host, readonly git(status/log/diff).
3. `keeper_workspace_read_ops.ml:63` — 전 keeper hardcoded host, readonly.
4. `keeper_sandbox_shell_ir_target.ml:107` (`docker_local_fallback_target`) — Docker keeper가 이미지 부재 시 silent degrade. (RFC-0126 위반, §8 참조.)

## §3 Design

### 3.1 의존성 제약

`lib/exec`는 `lib/keeper`에 의존할 수 없다(`sandbox_target.ml` 주석이 문서화 — Docker가 closure를 carry하는 이유). 따라서 scrub은 keeper layer에서 구성해 `Sandbox_target.Host`에 **데이터로 운반**한다.

### 3.2 Typed Scrubbed_env (parse-don't-validate)

`private`/abstract `Scrubbed_env.t`를 도입하고 smart constructor만 `Env_keeper_scrub.filter_environment`를 경유하게 한다. `Sandbox_target.Host`는 `Scrubbed_env.t option`을 carry:

- server emit → `Host None` → `resolve_host_env`가 현행 raw 동작 유지(회귀 없음, by construction).
- keeper chokepoint emit → `Host (Some scrubbed)` → exec가 scrubbed env를 inherited base로 사용.

`private` 타입이 "scrub 안 거친 array가 `Some` arm에 도달 불가"를 컴파일러로 강제한다. server는 실수로 scrub될 수 없고, keeper는 실수로 scrub을 건너뛸 수 없다.

### 3.3 변경 표면

- `lib/exec/sandbox_target.ml` / `.mli`: `Host`에 `Scrubbed_env.t option` payload.
- `lib/exec/exec_dispatch.ml`: `resolve_host_env`와 `host_pipeline_specs`(line 235)가 payload를 consume. `Some`이면 scrubbed base, `None`이면 현행.
- `lib/keeper/agent_tool_execute_shell_ir.ml`: chokepoint에서 모든 `Host` target에 `Some (Scrubbed_env.make (Unix.environment ()))` 주입. Option A는 `keeper_id` 불필요(`filter_environment`는 identity-free) — B의 credential 배선과 분리.
- `lib/env_keeper_scrub.ml`: 재사용. smart constructor 위치는 구현 시 `Env_keeper_scrub` 도달 가능 모듈에 배치.

## §4 Option A — scrub-only

leak 즉시 차단. `Env_keeper_scrub.pass`가 `GIT_AUTHOR_*`/`GIT_COMMITTER_*`를 유지하고, `GH_TOKEN`/`GITHUB_TOKEN`/`SSH_AUTH_SOCK`/`GIT_CONFIG_*`/`GIT_ASKPASS`/`GH_HOST`/`ANTHROPIC_*`/`AWS_*` 등 ~30개를 scrub한다.

**회귀 (operator 결정사항)**: readonly git(producer #2/#3/#4)은 zero functional loss. 그러나 **Local keeper network git(`git push`/`gh`, producer #1)**은 현재 operator ambient creds로만 동작하므로 Option B(credential bundle 주입) 전까지 **fail-closed**가 된다. Local keeper가 push 업무를 수행 중이면 그 기능이 일시 차단된다.

RFC 신규 불필요 — RFC-0019 F-1 scope의 미적용 corner를 닫는 security bug-fix. RFC-0019 changelog에 host-exec path가 F-1-enforced됨을 기록한다.

## §5 Option B — credential bundle 주입

Local keeper에도 Docker 동등의 credential bundle env를 주입해 기능을 유지한다. host-path credential brokering은 RFC-0070 §82-83이 별도 RFC로 명시 defer한 영역이며, 본 RFC가 그 RFC다.

Host-path consumer of `compose_base_with_credential_bundle` / `Keeper_host_config_provider`를 신설해, Docker의 `cred_envs` 경로를 Local keeper에 mirror한다. 현재 `Keeper_host_config_provider` consumer는 `keeper_turn_sandbox_runtime`/`keeper_sandbox_docker`/`keeper_in_container_login_provider`(전부 Docker)뿐이므로 host 분기를 추가한다.

## §6 권장 순서

A 먼저(leak 즉시 차단) → B(기능 복원). fail-closed 회귀(§4)는 operator가 수용 여부를 결정한다. A는 B의 credential 배선과 분리되어 독립적으로 ship 가능하다.

## §7 검증 전략

기존 `test_credential_materializer.ml:393`(ambient `GH_TOKEN=...` 설정 후 부재 단언) 패턴 재사용:

1. **Leak closed**: keeper Host dispatch 시 `Unix.environment`의 `GH_TOKEN`/`GITHUB_TOKEN`/`SSH_AUTH_SOCK`가 exec 도달 env에서 부재. `dispatch_simple`과 pipeline(`host_pipeline_specs:235`) 양쪽 커버.
2. **Identity pass**: `GIT_AUTHOR_NAME/EMAIL`, `GIT_COMMITTER_NAME/EMAIL` 존재.
3. **Server path 불변**: `Host None`(server emit) → raw inherit, `GH_TOKEN` 존재(비-keeper 무회귀 증명).
4. **Type guarantee**: `Some` arm이 scrub smart constructor로만 생성 가능(.mli에서 raw-array constructor 미노출 단언).
5. **(B, deferred)**: bundle 주입 시 keeper token 존재 + operator token 부재.

## §8 Out-of-scope

- producer #4(`docker_local_fallback`)의 silent fallback-to-Host 동작 수정은 RFC-0126 위반의 별도 사안. 본 RFC의 scrub chokepoint가 그 경로의 leak은 제거하나, fallback 동작 자체 교정은 별도 follow-up.
- dead-code 숙청(PR #19768)은 본 RFC의 전제(경로 A 제거)로 이미 진행.

## §9 References

- Issue #19770 (ACTIVE_LEAK 보고)
- RFC-0019 §P1 (F-1 invariant)
- RFC-0070 §82-83 (host-path credential brokering defer)
- RFC-0126 (fail-closed discipline)
- `lib/env_keeper_scrub.ml` (재사용할 scrub 함수)
- `lib/keeper/credential_bundle.ml:159` (Docker scrub 패턴 reference)
