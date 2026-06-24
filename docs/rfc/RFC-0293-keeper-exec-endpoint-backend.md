---
rfc: "0293"
title: "Keeper execution-endpoint backend (host / ephemeral-docker / persistent-docker-exec / external-shell)"
status: Draft
created: 2026-06-24
updated: 2026-06-24
author: vincent
supersedes: []
superseded_by: null
related: ["0006", "0042", "0070", "0097", "0107", "0210", "0213", "0286"]
implementation_prs: []
---

# RFC-0293 — Keeper execution-endpoint backend

- Status: **Draft** (design only — no behavior change ships with this document)
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-24
- Scope: `lib/exec/` (`sandbox_target`, `exec_dispatch`), `lib/keeper/` (`keeper_sandbox_*`, `keeper_tool_execute_runtime`, `keeper_turn_sandbox_runtime`), `lib/keeper/governance_pipeline.ml`, `lib/config/keeper_sandbox_config.ml`, `lib/keeper_types_profile_sandbox/`
- Boundary: 본 RFC는 **실행 백엔드 추상화의 설계 계약**만 정의한다. 코드 변경(타입 확장, dispatch 통합, 새 백엔드)은 본 RFC가 세팅한 계약 위에서 phased PR로 진행한다. gated subsystem(`lib/keeper/keeper_sandbox*`)이므로 모든 구현 PR은 본 RFC를 선행 인용해야 한다(CLAUDE.md `<agent_delegation>`).

---

## 1. 동기 (Motivation)

오늘 keeper가 명령을 실행하는 방식은 **명령 1건 = `docker run --rm` 휘발 컨테이너 1개**(Docker 프로파일) 또는 host 직접 실행(Local 프로파일)이다. 두 가지 요구가 이 모델을 넘어선다:

1. **영속 실행** — 컨테이너를 매 명령마다 새로 만들지 않고, keeper별 장기 컨테이너에 `docker exec`로 들어가 반복 실행. 컨테이너 기동 비용이 지배적인 turn에서 이득. (이미 RFC-0097이 설계했으나 구현이 purge됨 — §5.)
2. **외부 셸** — docker 영속에 국한하지 않고, **operator가 신뢰하는 외부 엔드포인트(SSH/원격 호스트, 또는 제공된 장기 셸)** 에 명령을 보내는 실행 경로. 사용자 요청 그대로: *"꼭 docker 영속이 아니라 외부 셸일 수도 있으니까."*

두 요구의 공통 구조는 **"파싱된 `Shell_ir.simple`이 어디서 OS 프로세스가 되는가"를 결정하는 단일 지점**을 휘발-docker 너머로 일반화하는 것이다. 본 RFC는 그 지점을 **실행 엔드포인트(exec-endpoint)** 닫힌 합 타입으로 승격하고, 4종 백엔드(host / ephemeral-docker / persistent-docker-exec / external-shell)를 그 위에 정의한다.

이 RFC는 **세 가지를 정직하게** 다룬다 — 타입 설계가 약속하는 컴파일러 레버리지가 어디까지 진짜인지, 보안 게이트가 현재 코드에서 백엔드를 *모른다*는 사실, 그리고 외부 셸이 로컬 경로의 불변식(주입 안전·FS 격리·시크릿 수명)을 어디서 깨는지. (적대 검증 라운드에서 확인된 결함을 §3.4/§4/§9에 명시.)

---

## 2. 현재 코드 실측 (Ground truth)

### 2.1 dispatch 경로가 둘이다

| 경로 | 진입 | OS 프로세스화 | Sandbox_target 경유 |
|------|------|---------------|----------------------|
| **타입드-IR** | `Exec_dispatch.dispatch_simple` (`exec_dispatch.ml:213`) `match s.sandbox` | Host→`Exec_gate.run_argv_with_status_split`(`:222`) / Docker→runner 클로저(`:280`) | **예** |
| **비타입드 bash** | `keeper_sandbox_docker.ml:276` `docker_run_argv` → `Exec_gate.run_argv_with_stdin_and_status`(`:583`) | `docker run --rm` | **아니오 (참조 0건)** |

두 경로 모두 최종적으로 단일 leaf `Eio.Process.spawn`(`process_eio.ml:483`)에 수렴한다. 핵심: **비타입드 경로는 `Sandbox_target.t`를 전혀 참조하지 않는 평행 dispatch**다. 타입 추상화가 이 경로를 덮지 못하면 새 백엔드는 bash 경로에서 조용히 누락된다.

### 2.2 확장점 — `Sandbox_target.t`

```ocaml
(* lib/exec/sandbox_target.ml:54 *)
type t = Host | Docker of { image : string; runner : runner; pipeline_runner : pipeline_runner option }
```

- `lib/exec`는 `lib/keeper`에 의존할 수 없다(레이어 불변식). 그래서 비-host 백엔드는 keeper 레이어가 만든 **`runner` 클로저를 variant payload로 주입**한다(`keeper_sandbox_shell_ir_target.ml:55,128`).
- `runner` 시그니처(`sandbox_target.ml:33`)는 백엔드 무관하게 균일: `on_stdout_chunk → on_stderr_chunk → stdin_content → argv → env → cwd → Unix.process_status * stdout * stderr`. 새 백엔드는 이 계약을 **그대로 재사용**하고 클로저 본문만 다르다(`docker run` vs `docker exec` vs `ssh`).

### 2.3 이미 존재하는 `docker exec` runner

타입드 경로의 Docker runner는 이미 영속 컨테이너에 대한 **`docker exec -i <c> bash -lc`**를 emit한다(`keeper_turn_sandbox_runtime.ml:907,1036`). `keeper_sandbox_control.ml:171`은 하드닝된 영속 컨테이너를 빌드한다. 즉 persistent-docker-exec의 *실행 골격은 이미 클로저 뒤에 있고*, 빠진 것은 (a) 타입 레벨 구분과 (b) per-exec 시크릿/스크래치 scrub(§4.3)이다.

### 2.4 silent-None 함정 두 곳

`exec_dispatch.ml:301-309`(`host_pipeline_specs`)와 `:323-334`(`docker_pipeline_specs`)는 `[@warning "-4"]`로 catch-all을 억제한다. 이 둘은 단순 생성자 match가 아니라 **가드 + partial-record** match다:

- `Host when simple.redirects = []`(`:302`) — 가드 arm
- `Docker { pipeline_runner = Some runner; _ } when simple.redirects = [] && same_sandbox_target`(`:324`) — 가드 + `pipeline_runner = None`이 실제 도달 가능한 partial-record arm

OCaml의 exhaustiveness 분석은 `when` 가드를 무시한다. 따라서 이 두 match는 **억제 제거 여부와 무관하게 None을 내는 잔여 arm을 항상 요구**한다(§3.4 결함 D1).

---

## 3. 설계 — 실행 엔드포인트 닫힌 합

### 3.1 타입 (in-place 일반화)

`Sandbox_target.t`를 제자리에서 4-arm으로 확장한다. `runner`/`pipeline_runner` 시그니처는 byte-identical 유지(클로저 계약 불변).

```ocaml
(* lib/exec/sandbox_target.ml *)
type t =
  | Host
    (* runner 없음: Exec_gate로 직결 (sandbox_target.ml:58, 의존성 사이클 차단 주석 :22-31) *)
  | Ephemeral_docker of { image : string; runner : runner; pipeline_runner : pipeline_runner option }
    (* 현행 `docker run --rm`. `Docker`에서 개명 — 모든 소비자가
       ephemeral vs persistent를 컴파일 타임에 구분하도록 강제 *)
  | Persistent_docker_exec of { container : string; runner : runner; pipeline_runner : pipeline_runner option }
    (* RFC-0097의 장기 컨테이너에 `docker exec`. runner는
       keeper_turn_sandbox_runtime.run_exec_with_status_split를 감싼다
       (이미 docker exec emit, keeper_turn_sandbox_runtime.ml:907) *)
  | External_shell of { endpoint : endpoint_ref; runner : runner; pipeline_runner : pipeline_runner option }
    (* ssh / operator 제공. endpoint_ref는 lib/exec에 불투명 *)

(* lib/exec에 불투명: host/credential/transport는 keeper 레이어에 산다.
   lib/exec는 pp/승인 큐 evidence 용도로만 display string을 운반. *)
and endpoint_ref = { display : string (* 예: "ssh:user@host" *) }
```

**Parse, don't validate**: `image`/`container`/`endpoint`/credential은 keeper 측 빌더가 *한 번* 해석해 variant payload에 동결한다. `lib/exec`는 절대 재유도하지 않는다.

### 3.2 dispatch 변경 (`exec_dispatch.ml:213`)

```ocaml
match s.sandbox with
| Host -> (* Exec_gate.run_argv_with_status_split, 현행 :222 *)
| Ephemeral_docker { runner; _ }
| Persistent_docker_exec { runner; _ }
| External_shell { runner; _ } ->
    runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd
```

runner 계약이 균일하므로 3개 runner-운반 arm은 한 본문으로 합쳐진다. `_ ->` catch-all 금지.

### 3.3 격리(isolation)는 변형의 *증거*, 게이트의 *입력*

각 엔드포인트의 격리 능력은 변형에서 파생되는 데이터다(아래). **단, 이 레코드 자체는 보안을 강제하지 못한다** — §4가 정의하는 소비자(승인 게이트)가 *읽어서* 결정에 반영해야 의미가 있다. (§3.4 결함 D2: 이 레코드를 "illegal state 표현 불가"라고 주장하면 거짓이다.)

```ocaml
type isolation = {
  fs_readonly_rootfs : bool;
  net_none : bool;
  cap_drop_all : bool;
  secret_ephemeral : bool;   (* 시크릿이 명령 1건으로 수명 제한되나 *)
}
```

| 백엔드 | fs_ro | net_none | cap_drop | secret_ephemeral |
|--------|:----:|:-------:|:-------:|:----------------:|
| Host | ✗ | ✗ | ✗ | ✓ (per-process env) |
| Ephemeral_docker | ✓ | ✓ | ✓ | ✓ (`--rm` per-cmd) |
| Persistent_docker_exec | ✓ | ✓ | ✓ | **✗** (exec 간 잔존) |
| External_shell | ✗ | ✗ | ✗ | ✗ |

### 3.4 컴파일러 레버리지는 *부분적*이다 (정직한 한계)

적대 검증에서 확인된 결함 — RFC가 덮지 않고 명시한다:

- **D1 (pipeline silent-None)**: §2.4의 두 가드 match는 `[@warning "-4"]`를 지워도 None 잔여 arm을 항상 요구한다. 3번째 변형이 오면 자연스러운 수정은 그 잔여 arm을 `| External_shell _ -> None`으로 확장하는 것 — anti-pattern #4를 명명 arm으로 다시 쓰는 셈. **완화책**: pipeline 지원 여부를 변형의 boolean이 아니라 `pipeline_runner` payload의 유무로만 판정하고, "pipeline 미지원"을 명령 거부가 아닌 **타입드 `Unsupported_pipeline` 결과**로 표면화(컴파일러가 None 증발을 못 막으므로 런타임 계약으로 보강). 이건 워크어라운드임을 인정하며, 근본은 pipeline 분해를 endpoint와 직교한 별도 계약으로 빼는 것(별도 RFC).
- **D2 (isolation flag-map)**: `isolation`은 4-bool 레코드 + 전사 함수 `isolation_of`로, 설계가 거부한다던 flag-map 그 자체다. `External_shell { net_none = true }`가 표현 가능하고 손으로 쓴 `isolation_of` 본문만 막는다. **결정**: isolation을 "illegal state 표현 불가"로 *주장하지 않는다*. 대신 §4가 그것을 읽는 **단일 소비자**(승인 게이트)를 명시하고, 능력 미달 필드는 hard-forbid 또는 risk-bump로 매핑한다. (타입-carried 격리는 follow-up RFC.)
- **D3 (untyped 경로)**: "닫힌 합이 모든 소비자를 강제한다"는 **Phase 2 전엔 거짓**이다. `keeper_sandbox_docker.ml:276`은 `Sandbox_target` 참조가 0건이라 컴파일러가 arm을 강제할 수 없다. config 측 `all_sandbox_profiles`(`keeper_types_profile_sandbox.ml:59`)도 손-유지 리스트(컴파일러 비강제)다.

---

## 4. 보안 모델 (gated subsystem — 가장 엄격하게)

### 4.1 BLOCKER: 승인 게이트가 현재 백엔드를 모른다

현행 `governance_pipeline.ml:332-336`: `needs_approval = (risk >= keeper_confirm_threshold)`, 여기서 `risk = combinatorial_risk_escalation(assess_risk ~tool_name ~input, trifecta)`(`:328-331`) — **tool 이름 + 파싱된 입력 + trifecta tool-count로만** 파생된다. 선택된 `sandbox_target`/backend는 그 *이후* `:380`에서 계산된다.

따라서 "External_shell은 HITL 게이트가 막는다"는 **현재 코드에서 성립하지 않는다**. 본 RFC의 보안 계약:

1. **backend/isolation을 승인 결정의 일급 입력으로 승격** — `needs_approval` 계산이 endpoint의 `isolation`을 읽어, container-equivalent baseline(Ephemeral_docker의 4필드 전부 ✓)을 못 채우면 risk를 bump하거나 hard-require approval. 이는 `assess_risk` *이전*에 endpoint를 해석해야 함을 의미(현재 순서 역전 필요).
2. **우회 경로 차단** — 두 short-circuit이 큐 제출 전 Approve로 단락된다:
   - `always_approve`(`governance_pipeline.ml:419-439`): `keeper_meta.always_approve=true` keeper는 External_shell을 **HITL 없이** dispatch.
   - auto-approve rule(`:441-462`): `find_matching_rule` 자동 승인.
   
   계약: **non-container-equivalent 백엔드(Persistent의 `secret_ephemeral=false`, 모든 External_shell)는 두 우회를 무효화** — backend 격리 미달 시 always_approve/rule auto-approve를 건너뛰고 큐 제출을 강제.

### 4.2 시크릿 투영 (백엔드별)

오늘 두 채널 모두 ambient-env allowlist를 우회한다 — (1) host env default-deny + `_TOKEN/_SECRET/_API_KEY/_PASSWORD/_CREDENTIALS` suffix 거부(`env_keeper_scrub.ml:14-113`), (2) per-keeper 시크릿을 0o600 temp env-file로 써서 `--env-file` + `:ro` bind-mount, 명령 후 `~finally`에서 삭제(`keeper_secret_projection.ml:419-535`, `keeper_sandbox_docker.ml:578`).

- **Ephemeral**: `secret_ephemeral=true` (구조적으로 보장).
- **Persistent_docker_exec**: 컨테이너가 1회 기동 → 시크릿을 **per-exec 주입**(`docker exec --env-file`)하고, exec env는 컨테이너 수명 동안 모든 잔존 PID에 노출. 따라서 본 RFC가 **per-exec 주입+scrub 단계를 소유**하고, exec가 생성시 cap-drop/no-new-privileges/--user/--read-only를 *재완화하지 못함*을 강제(exec는 느슨하게만 가능, 더 조일 수 없음).
- **External_shell**: 신뢰 경계가 호스트 밖으로 이동. 시크릿이 네트워크를 횡단(env-over-ssh 또는 원격 temp 파일)하고 로컬 cleanup 클로저가 도달 불가. `--network none` 불가, cap-drop/read-only/seccomp 무적용, 공유 FS 없음.

### 4.3 External_shell 신뢰 경계

masc는 operator가 명명한 엔드포인트의 OS/계정을 **전적으로 신뢰**한다. 격리는 그 원격 계정이 제공하는 수준으로 떨어진다(그래서 4필드 전부 ✗). 결과:

- **argv→원격 문자열 framing (RFC-blocking)**: `ssh host -- argv`는 argv를 단일 원격 셸 문자열로 접는다 → `process_eio.ml:8`(argv-only, no `sh -c`)이 제거한 주입 표면이 부활. **따라서 ssh-argv-per-command MVP를 먼저 출하하지 않는다.** 타입드 quoted-argv framing 명세가 선행 전제(§8 OQ1).
- **원격 경로 정책**: `path_scope.classify`(`path_scope.ml:83`)는 host-local realpath 기반이라 원격 FS에 무효 — "inapplicable로 표시"가 아니라, External_shell의 FS-touching 명령 전에 **원격 path-policy를 정의**해야 한다(미정 시 FS-touching 거부).
- **repo 동기화**: docker는 `host_root:container_root:rw` bind-mount(`keeper_sandbox_runtime_setup.ml:289`); 원격 셸은 공유 FS가 없어 repo를 git-push/rsync로 동기화해야 한다(새 일관성/cwd-매핑 경계 — §8 OQ2).

---

## 5. RFC-0097과의 관계 (extend + supersede)

- **재사용(설계만)**: 영속 컨테이너 lifecycle FSM(create/start/exec/remove + missing/timeout/image-change lazy-recreate, RFC-0097:114-152), `exec_response = {exit_code; stdout; stderr}` shape(RFC-0097:26-37).
- **재사용 안 함(코드)**: RFC-0097이 landed한 `lib/sandbox/docker_api.{ml,mli}`(PR #15991, 모든 본문 `raise (Failure ...)`, 프로덕션 caller 0건)는 **PR #19156(6bbe43f65f, -780L)이 dead code로 purge**. 현재 origin/main에 존재하지 않음. RFC-0097 frontmatter `implementation_prs:[15991]`는 **STALE**.
- **transport 차이**: RFC-0097 "step 2"는 `/var/run/docker.sock` UDS + cohttp-eio HTTP 클라이언트였다. **RFC-0293 Phase 3는 그 transport를 채택하지 않는다** — 이미 존재하는 runner의 **`docker exec` CLI 경로**(`keeper_turn_sandbox_runtime.ml:907`)를 쓴다. 즉 0293 Phase 3 ≠ 0097 step 2; 0293은 0097의 docker-only 가정을 4-백엔드 합으로 **포함·일반화**하며, error를 string match 대신 typed variant로 처음부터 닫는다(RFC-0042 정렬).
- **Phase 0 정리**: stale `MASC_DOCKER_TRANSPORT` 마커(`keeper_sandbox_runtime_setup.ml:43`, 삭제된 모듈 지시)와 inert playground env(`docker_playground_enabled`/`container_name` 미배선, dead `_docker_playground_cwd` at `keeper_tool_execute_path.ml:53`) 제거 + RFC-0097 frontmatter 정정.

---

## 6. 마이그레이션 (phased, 각 단계 default-OFF)

| Phase | 내용 | 동작 변화 | 전제/게이트 |
|-------|------|-----------|-------------|
| **0** | 전제조건. §2.4 catch-all 2곳을 현행 2-arm에 대해 정리(D1 완화 계약 포함). §5 dead seam 정리 + RFC-0097 frontmatter 정정. **§4.1 backend-aware 승인** 골격(endpoint를 risk 계산 전에 해석). | 없음 | — |
| **1** | `Docker`→`Ephemeral_docker` 개명. 컴파일러가 모든 exhaustive-match 소비자(§7)를 강제 순회. | 없음(레버리지 시연) | Phase 0 |
| **2** | 비타입드 `docker run --rm` 경로(`keeper_sandbox_docker.ml:276`)를 동일 `Ephemeral_docker` 엔드포인트로 통합 → dispatch 1개. | 없음(경로 통합) | Phase 1. **이때부터 D3 해소** |
| **3** | `Persistent_docker_exec` arm 추가. **per-exec 시크릿 주입+scratch/PID scrub를 HARD 전제**(prose 아님). lazy-recreate 복구. `MASC_KEEPER_SANDBOX_MODE oneshot→persistent` 게이트(RFC-0097 4-phase 재사용). | flag-on 시만 | Phase 2 + scrub 계약(§8 OQ3) |
| **4** | `External_shell` arm 추가. **HITL 게이트 필수**(§4.1, 무음 default 금지). MVP는 ssh-argv가 **아니라** 타입드 framing 명세 이후의 transport. | flag-on + HITL | Phase 3 + framing(§8 OQ1) + 원격 path-policy |

기존 Local/Docker keeper는 `effective_sandbox_profile`(`keeper_tool_execute_runtime.ml:359`)이 그대로 해석 → **byte-unchanged**. config 측 `sandbox_profile`(Local|Docker)은 **넓히지 않는다**(권고) — endpoint 합만 넓히고 profile→endpoint 투영(`:377`)에서 구분.

---

## 7. Exhaustive match 소비자 (Phase 1에서 컴파일러가 강제)

- `lib/exec/sandbox_target.ml:54` (type t — 3 arm 추가, `Docker`→`Ephemeral_docker`)
- `lib/exec/sandbox_target.ml:60` (smart constructor — endpoint별 분리)
- `lib/exec/sandbox_target.ml:62` (`pp` — 변형마다 arm 강제)
- `lib/exec/exec_dispatch.ml:213` (`dispatch_simple` — 실제 exec fork)
- `lib/exec/exec_dispatch.ml:301-309, :323-334` (pipeline_specs — §2.4/D1, 억제 제거 + None 잔여 arm 명시 계약)
- `lib/keeper/keeper_tool_execute_runtime.ml:377, :389` (profile→target / 중첩 match)
- `lib/keeper/keeper_sandbox_factory.ml:65` (resolve — turn runtime 생성 게이트)
- `lib/keeper/keeper_sandbox_shell_ir_target.ml:55` (runner 클로저 빌더 — 새 클로저 구성처)
- `lib/keeper_types_profile_sandbox/keeper_types_profile_sandbox.ml:59` (`all_sandbox_profiles` — **손-유지, 컴파일러 비강제 soft hazard**)
- `lib/keeper/keeper_sandbox_docker.ml:276` (비타입드 ephemeral — Phase 2까지 컴파일러 미강제, D3)

---

## 8. Open questions (HARD — 미해결 명시)

1. **OQ1 (RFC-blocking)**: External_shell argv→원격 framing. `ssh`는 단일 문자열을 보내 `sh -c` 주입 표면을 부활. 타입드 quoted-argv witness 명세가 어떤 external 명령보다 선행.
2. **OQ2**: External_shell repo/FS 동기화 + cwd 매핑 + `path_scope` 원격 재정의(또는 inapplicable 강제).
3. **OQ3**: Persistent_docker_exec per-exec scrub 계약 — exec 간 무엇을(/tmp scratch, env 변이, pids-limit까지의 background PID) 청소해야 `--rm`이 주는 per-command 보장을 재수립하나.
4. **OQ4**: 원격 exit-code/stderr/cancellation/timeout fidelity — `ssh`로 `WEXITED/WSIGNALED` 충실 전파 + `process_eio` reap(SIGTERM→SIGKILL) 동등 취소가 가능한가.
5. **OQ5**: `sandbox_profile`(Local|Docker)을 N-backend로 넓힐지 vs 2-case 유지 + endpoint 합이 구분 운반. 권고는 profile narrow 유지.
6. **OQ6**: 네이티브 OCaml ssh/persistent-session transport(ssh CLI spawn 대신) — needs-new-infra, 전면 deferred(MVP는 `Process_eio`로 ssh CLI spawn).

## 9. Risks

- **R1**: §2.4 catch-all 미정리 시 새 endpoint가 clean 컴파일되며 silent `None`(pipeline 미지원). 단일 최고-레버리지 전제(Phase 0).
- **R2**: 비타입드 ephemeral 경로(D3) 미통합 시 추상화가 타입드 경로만 덮고 bash 경로에서 새 backend 누락.
- **R3**: config-side `sandbox_profile`과 exec-side `Sandbox_target.t` 두 합이 lockstep 필요. 잘못된 쪽(profile)을 넓히면 레버리지 약함; `all_sandbox_profiles` 손-리스트는 새 backend가 무음 누락 가능.
- **R4**: Persistent_docker_exec를 per-exec scrub 없이 출하 = 기능이 아니라 보안 회귀(state bleed + 시크릿 파일 수명 붕괴).
- **R5**: External_shell를 무음 default(HITL-gate + risk-bump 없이)로 출하 = container-equivalent baseline을 보이지 않게 완화.
- **R6**: RFC-0097 docker_api 스켈레톤을 live prior-art로 인용 = 오류(purge됨). 설계만 재사용, 코드는 typed error로 재구현.
- **R7**: under-spec된 External_shell MVP의 argv→문자열 framing = 로컬 경로에 없는 command-injection hole.

## 10. 검증 방법 (Harness)

- **컴파일러 강제**: Phase 1 개명 PR이 §7 전 사이트를 컴파일 에러로 띄우는지(= 레버리지 실증). `all_sandbox_profiles` 손-리스트는 별도 drift-guard 테스트로 핀(컴파일러 비강제 보강).
- **승인 게이트 backend-awareness**: `governance_pipeline`에 endpoint를 주입하고, `External_shell` + `always_approve=true` 조합이 **여전히 큐 제출**되는지 테스트(§4.1 우회 차단 회귀).
- **TLA+ bug-model**(`software-development.md` §TLA+): 승인 FSM에 "backend 격리 미달인데 auto-approve" action을 모델링하고 `NoSilentDowngrade` invariant가 clean spec에서 성립/buggy spec에서 위반되는지 양쪽 cfg로 검증.
- **시크릿 수명**: Persistent_docker_exec per-exec scrub 후 잔존 env/파일 0건 단언(통합 테스트, mock 아님).
- **주입 안전**: External_shell framing 명세에 대해 메타문자 포함 argv가 원격에서 단일 토큰으로 전달되는지(주입 불가) 증명 — framing 미구현 시 FS/네트워크-touching 거부가 default임을 테스트.

---

## 부록 A — 용어

- **exec-endpoint**: 파싱된 `Shell_ir.simple`이 OS 프로세스가 되는 위치를 결정하는 닫힌 합(`Sandbox_target.t`).
- **runner 클로저**: keeper 레이어가 만들어 endpoint variant에 주입하는, 백엔드 무관 균일 실행 함수. `lib/exec`의 keeper 비의존을 유지하는 의존성 역전 장치.
- **container-equivalent baseline**: Ephemeral_docker의 격리 4필드(fs_ro/net_none/cap_drop/secret_ephemeral) 전부 ✓. 승인 게이트가 backend 위험을 판정하는 기준선.
