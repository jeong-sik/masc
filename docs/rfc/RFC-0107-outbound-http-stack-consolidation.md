---
rfc: "0107"
title: "Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker socket transport"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0097", "0100", "0101"]
implementation_prs: []
---

# RFC-0107 — Outbound HTTP stack consolidation

본 RFC 는 2026-05-16 ENFILE storm 의 *진짜* 근본 원인 4개를 다룬다. RFC-0101 (Fd_accountant 4-kind throttle) 는 같은 사고에 대한 transitional defense 였으나, *증상 완화* 이지 *원인 치료* 가 아니다. RFC-0101 의 1 kind (Docker_spawn) 만 wired 됐고 나머지 3 kind 는 dead branch 로 남아 있어, 본 RFC 가 머지되면 RFC-0101 은 *transitional defense-in-depth* 로 redefine 되며 §5 retirement clock 으로 demote 된다.

Prior Art 는 `~/me/knowledge/research/2026-05-17-piaf-ocsigen-eio-fd-prior-art.md` 에서 사전 검토했다. piaf 가 *per-endpoint keep-alive* 의 검증된 구현체이고, multi-host pool 은 application 책임이라는 추상화 경계가 우리에게 그대로 적합하다. 본 RFC §3.2 의 L2 Pool 은 piaf 위에 올리는 `(host, port) → Client.t` thin wrapper 이지 자체 connection pool 의 재발명이 아니다.

## 1. Problem

### 1.1 cohttp-eio 6.1.1 socket-not-closed bug

- **Evidence**: `lib/masc_http_client/masc_http_client.ml:1-13` 헤더 인용:
  > *"cohttp-eio 6.1.1 does not reliably close the underlying TCP socket fd when the Eio.Switch exits (observed on macOS). This module intercepts the connection factory via [make_generic] to capture the raw socket and close it explicitly on switch release."*
- **현재 워크어라운드**: `make_closing_client` 는 cohttp-eio 의 `make_generic` factory 를 가로채 `tracked_flows: Eio.Resource.t list ref` 에 모든 socket flow 를 등록한 뒤, `Switch.on_release` 시점에 명시적으로 close. 정교한 우회 trick 이지만 *Eio 공식 권고 위반* — Eio issue #244 에서 Eio 팀이 "라이브러리의 자동 리소스 정리에 맡기고 명시적 close 하지 말 것" 권고했음에도, 우리는 cohttp-eio 의 부족을 우회하기 위해 어쩔 수 없이 명시적 close 를 추가.
- **결과**: 매 호출 `connection: close` 강제 → keep-alive 0건 → cascade 마다 N socket burst.
- **상위 issue**: [`ocaml-cohttp#85`](https://github.com/mirage/ocaml-cohttp/issues/85) "Support HTTP Keep-Alive" — 2014-01 개설, Closed (milestone "1.0 Stable API"), 결과적으로 abandoned/out-of-scope. masc-mcp 의 워크어라운드는 그 gap 의 lower bound.

### 1.2 Connection pool 부재 — masc-mcp + oas 양쪽

- **masc-mcp**: `lib/masc_http_client/masc_http_client.ml` 가 매 호출 fresh `Eio.Switch.run` → `Client.make` → 1 request → switch release → tracked socket close.
- **oas**: `oas/lib/llm_provider/http_client.ml:380-410` 의 `get_sync` / `post_sync` 가 동일 패턴.
- **RFC-0100 (Streamable HTTP)** 가 명시적으로 connection pooling 을 *out-of-scope* 로 명시 (line 20).
- **Cascade 영향**: 12+ keeper 가 cascade 재시도 안에서 매 호출 새 TCP+TLS 를 염. cascade 1 turn 에 5~12 fd burst (provider probe + cascade attempt + tool call HTTP).

### 1.3 Switch hierarchy gap

- **`lib/keeper/keeper_turn_driver_try_provider.ml:406`**: cascade attempt 마다 fresh `Eio.Switch.run (fun attempt_sw -> ...)` 존재 — cascade level 은 OK.
- **`lib/keeper/keeper_agent_run.ml:196`**: `run_turn` 자체는 ambient switch 사용. **turn-scoped FD boundary 가 없음**.
- **결과**: turn 내부에서 spawn 된 fiber 가 attempt switch 가 아니라 ambient switch 에 attach 되면, turn 종료 후에도 FD 가 해제되지 않음. `try_provider:406` 의 fresh switch 는 *opt-in* 이라 turn 본체 코드가 그 switch 를 쓰지 않을 수 있음.
- **Eio.Switch 공식 axiom**: *"Resource cannot outlive its switch"* ([공식 docs](https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html)). Ambient switch 를 쓰면 resource lifetime 의 상한이 ambient 만큼 길어지는데, 우리 ambient 는 keeper lifetime 전체 — *FD 가 keeper 종료까지 살아남을 수 있음*.

### 1.4 Subprocess-heavy Docker

- **모든 Docker 호출** 이 `lib/docker_spawn_throttle.ml` 의 `with_slot` 으로 감싼 subprocess `docker run/exec` (`lib/worker_runtime_docker.ml`, `lib/keeper/keeper_sandbox_*.ml`, `lib/keeper/keeper_shell_docker.ml`, `lib/keeper/keeper_docker_client_real.ml`).
- **Docker HTTP API (`/var/run/docker.sock`) 사용 0건**. `lib/keeper/keeper_shell_docker.ml:180-181` 가 명시적으로 `blocked_mount_paths` 에 등재 (security 의도).
- **fd 비용**: subprocess 1회 = daemon socket 1 + stdio pipe 3 + cgroup fd. SDK/HTTP API 호출 = 같은 daemon socket 재사용. *cascade-storm 의 가장 큰 spike 원인*.
- **RFC-0097 (container reuse)** 는 Draft, spec-only — 머지 후 *spec body 만* 존재하고 구현 PR 없음. 본 RFC 가 §3.4 에서 활성화.

## 2. Non-goals

- HTTP/2 multiplexing 의 fine-grained tuning (piaf 의 default 만 사용)
- gRPC 도입
- cohttp 자체 fork (upstream PR 가능 시 우선, 우리 repo 에서 vendor 하지 않음)
- sandbox 격리 모델 변경 (Docker → namespaces / nsjail / firejail)
- RFC-0101 PR-2/PR-3 즉시 revert — *transitional 가치 인정*, retirement clock 으로 demote (§5)
- TLS 1.3 0-RTT, HTTP/3 / QUIC

## 3. Design — 4-layer

### 3.1 L1 Transport (Phase B spike 결정)

후보:
- **(a) piaf** (anmonteiro) — Eio-native, keep-alive ✓, h1+h2, eio_main >= 1.0. Prior Art §2 검증.
- **(b) cohttp-eio + 자체 upstream patch** — `opam show cohttp-eio` 의 latest changelog 가 keep-alive 추가했을 경우만 후보. `make_generic` extension point 가 이미 검증됐으므로 마이그레이션 비용 적음.
- **(c) http_eio** — 실험적, 제외 후보.

4-axis 결정 기준 (Phase B bench):

| Axis | piaf | cohttp-eio | http_eio |
|---|---|---|---|
| fd-peak (100k call burst) | ? | ? | ? |
| RPS | ? | ? | ? |
| TLS handshake 횟수 | ? | ? | ? |
| switch-clean exit (no leak after sw teardown) | ? | ? | ? |

결정 기록은 Phase B 산출물 `lib/masc_http_client/CHOICE.md` 에 commit, 본 RFC 의 §3.1 표를 PR 추가 commit 으로 backfill.

### 3.2 L2 Pool — `(host, port) → Client.t` keyed wrapper

```ocaml
(* lib/masc_http_client/pool.ml (Phase D 신규) *)

type config = {
  max_per_host : int ;      (* 한 endpoint 당 최대 동시 client *)
  max_total : int ;         (* 전체 pool 의 상한 *)
  idle_ttl_sec : float ;    (* idle 시 client teardown *)
  connect_timeout_sec : float ;
}

val with_client :
  pool:t ->
  sw:Eio.Switch.t ->
  Uri.t ->
  (Client.t -> 'a) ->
  'a
(* host:port 기반으로 keyed lookup. miss 면 piaf.Client.create.
   사용 후 *close 하지 않고 pool 에 반환*. idle eviction 은 별도 fiber. *)
```

Contract:
- *Switch 종료 시 강제 release-not-close* — piaf 의 Client.t 는 별도 sw 위에 만들어진 long-lived 자원, 호출자 sw 가 끝나도 살아남음.
- per-host TLS context cache — piaf 의 Client.t 내부에 위임.
- Idle eviction: idle_ttl_sec 경과한 client 는 background fiber 가 shutdown.
- max_per_host 도달 시 acquire 가 block (Eio.Pool 의 backpressure 활용).

### 3.3 L3 Switch hierarchy — `run_turn` fresh switch

```ocaml
(* lib/keeper/keeper_agent_run.ml:196 (Phase C) *)

let run_turn ... =
  Eio.Switch.run @@ fun turn_sw ->
  (* turn 본체. retry 시 fresh sub-switch 는 try_provider:406 이 이미 보장.
     turn_sw 는 turn 의 모든 FD 의 절대 상한 lifetime 으로 동작. *)
  ...
```

Invariant (Phase C TLA+ spec):
- For any FD `f` opened during `run_turn`, `f ∈ turn_sw.resources` at any timepoint
- After `run_turn` returns, `turn_sw.alive = false` ∧ `∀ f. f ∉ turn_sw.resources`

`try_provider:406` 의 attempt switch 는 turn switch 의 *자식* 으로 nested — Eio Switch 가 부모-자식 lifecycle 을 정상 지원하므로 변경 불필요. 주석만 강화.

### 3.4 L4 Sandbox transport — Docker HTTP API via UDS

```
sandbox_exec
   │
   ├─ env MASC_DOCKER_TRANSPORT=api      → docker_api.ml (UDS + L1 transport)
   └─ env MASC_DOCKER_TRANSPORT=subprocess → 기존 docker_spawn_throttle (fallback)
```

- 기본값: `api` (Phase E 머지 후).
- Subprocess 경로는 *transitional fallback* — env flag 로 rollback 가능, 30-90일 후 제거.
- security: docker.sock mount 정책 별도 §7 open question.
- RFC-0097 의 container reuse 가 자연스럽게 활성화 — exec endpoint 가 같은 UDS 위에 multiplex.

## 4. Implementation phases

본 RFC 의 phase 구성은 plan `~/me/planning/claude-plans/me-workspace-yousleepwhen-masc-mcp-oas-vast-moonbeam.md` 와 동기화. 요약:

| Phase | Scope | Critical path? |
|---|---|---|
| A.0 | Prior Art deep-read | yes (prereq) |
| A | RFC Draft + push | yes |
| B | HTTP transport spike + 결정 | yes |
| C | `run_turn` fresh Switch (TLA+ 포함) | yes (B 와 병행) |
| D | L2 Pool 도입 — user-visible ENFILE 종결 | yes |
| E | Docker UDS + RFC-0097 활성화 | yes |
| F | Fd_accountant retirement (30일 production soak 후) | no (long tail) |
| G | launchd plist + sb_raise_nofile_limit | no (parallel) |

## 5. Migration & retirement

### 5.1 RFC-0101 demotion

본 RFC 머지 직후:
1. RFC-0101 frontmatter `status: Active` → `status: Active(transitional)` (또는 별도 라벨).
2. Phase D 머지 직후: RFC-0101 frontmatter 에 `superseded_by: "0107"` 추가, 상태 → `Superseded`.
3. PR #15881 (Sandbox_exec wrap PR-4) **머지하지 않고 close** — `gh pr close 15881 --comment "Superseded by RFC-0107 Phase D pool acquire path"`.

### 5.2 Retirement gate (production soak 기반)

Phase D 머지 후 **30일 production sample**:
- peak `process_open_fds < RLIMIT_NOFILE_soft × 0.5`
- ENFILE count = 0 (24h × 30일)

Gate 통과 시:
- `Fd_accountant.with_slot` → `Fd_accountant.observe` (counter only, no blocking)
- `_shared_pressure_mutex` 제거 (재진입 deadlock 위험 해소)
- dead variant (`Provider_http`, `Sandbox_exec`, `Log_writer`) 삭제

**90일** 후:
- `Fd_accountant` 모듈 전체 제거 또는 metrics-only stub 으로 강등
- `Docker_spawn_throttle` 모듈 retire

### 5.3 cohttp-eio 워크어라운드 sunset

Phase D 머지 시 `lib/masc_http_client/masc_http_client.ml` 의 `make_closing_client` 함수와 `tracked_flows` 매커니즘 **전체 삭제**. piaf (또는 cohttp-eio latest) 위의 thin pool wrapper 로 대체.

## 6. Trade-offs & risks

| Risk | 대응 |
|---|---|
| piaf opam dep 도입 — upstream maintenance 의존 | Phase B 에서 piaf 최근 6개월 commit 빈도 + open issue triage 로 health check. cohttp-eio 후보 (b) 가 fallback. |
| Pool eviction 잘못 짜면 idle socket leak (RFC-0101 보다 나쁜 시나리오) | Phase D property test 로 max_per_host invariant 강제. Eio.Pool primitive 활용 — backpressure 검증된 path. |
| Docker HTTP API → security mount 정책 재설계 | §7 open question. Phase E 진입 전 별도 security review. Subprocess fallback 으로 rollback 가능. |
| Eio.Mutex 재진입 deadlock (RFC-0101 잔존) | Phase F 에서 `_shared_pressure_mutex` 제거. 그 전까지 nested with_slot 추가 금지. PR #15881 close 가 이 risk 의 marginal contribution 제거. |
| Phase B spike 결정이 RFC body 와 lag | RFC body 의 §3.1 표를 Phase B 결과 backfill commit 으로 채움. RFC Draft 단계에서 *결정 framework* 만 합의. |

## 7. Open questions

1. **Docker socket security 정책** — Phase E 진입 전 결정 필요:
   - (a) Keeper 별 cap (RFC-0005 typed cap substrate 재활용)
   - (b) 호스트 deny + sidecar daemon proxy (예: `dockerd-proxy` 와 같은 mediated socket)
2. **cohttp-eio upstream PR 수용 timeline** — `opam show cohttp-eio` 의 latest changelog 가 keep-alive 추가 여부 확인 필요. abandoned 라면 Phase B 의 (b) 후보 제외.
3. **launchd plist `SoftResourceLimits.NumberOfFiles`** — 10240 (macOS default) vs 65536 (RFC-0101 cap 합 120 의 540×). Phase G 의 별도 결정.
4. **piaf `Client.t` 의 idle timeout 동작** — switch teardown 까지 holding 인지 자체 idle eviction 인지 — Phase B source 정독 대상.

## 8. Prior Art

상세 노트: `~/me/knowledge/research/2026-05-17-piaf-ocsigen-eio-fd-prior-art.md`.

| Reference | 본 RFC 의 어디에 매핑 |
|---|---|
| [piaf](https://github.com/anmonteiro/piaf) | §3.1 (a), §3.2, §5.3 |
| [Tarides Ocsigen → Eio migration (2025-03)](https://tarides.com/blog/2025-03-13-we-re-moving-ocsigen-from-lwt-to-eio/) | §1.3 (동시대 동등 문제 발생 증거) |
| [ocaml-cohttp issue #85](https://github.com/mirage/ocaml-cohttp/issues/85) | §1.1, §1.2 |
| [Eio issue #244](https://github.com/ocaml-multicore/eio/issues/244) | §1.1 (`make_closing_client` 가 Eio 권고 위반 의 증거) |
| [Eio.Switch official docs](https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html) | §1.3, §3.3 (axiom) |

### Anti-prior-art (피해야 할 패턴)

- 자체 multi-host pool 재발명 (semaphore + dict) — piaf 가 per-endpoint 의 어려운 부분을 이미 해결.
- socket 을 explicit close 하는 wrapper — Eio 권고 위반.
- `_shared_pressure_mutex` 같은 global Eio.Mutex (재진입 불가) — RFC-0101 이 이미 빠진 함정.
- cohttp PR fork — upstream relationship 비용. piaf 또는 dune-vendoring 이 cheaper.

## 9. Verification plan

상세는 plan §"Verification". Phase 별 합격 기준:

- **A**: `rfc-number-collision-check` CI green, `pr-rfc-check.sh` PASS.
- **B**: 4-axis bench 결과 `lib/masc_http_client/CHOICE.md` 에 commit, RFC §3.1 표 backfill.
- **C**: TLA+ clean spec invariant 통과, buggy spec 위반 ≤ 3 steps. e2e 100-turn loop `lsof` peak linear-bounded.
- **D**: 16 keepers × 5 turn cascade-storm reproducer 통과, ENFILE 0건.
- **E**: container reuse 100회 exec 후 fd diff = 0. security review pass.
- **F**: 30일 production sample 의 fd peak / ENFILE 카운트 측정.
- **G**: 부팅 후 `launchctl limit maxfiles` 반영 확인.

회귀 방지:
- 30일 평균 `cohttp_eio.connection_close_workaround_counter` (Phase D 후 0 되어야 함)
- 30일 평균 `fd_accountant.with_slot.invocations{kind=Docker_spawn}` (Phase E 후 monotonic 감소)
- `git log --grep="WORKAROUND"` 신규 0 (Phase F 이후)
