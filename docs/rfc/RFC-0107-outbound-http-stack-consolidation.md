---
rfc: "0107"
title: "Outbound HTTP stack consolidation — pooled keep-alive, scoped Switch, Docker socket transport"
status: Active
created: 2026-05-17
updated: 2026-05-18
author: vincent
supersedes: []
superseded_by: null
related: ["0097", "0100", "0101"]
implementation_prs: [15932, 15950, 15965, 15985, 15990, 16017, 15993, 15991, 16102, 16150]
# Excluded from list (RFC body / design-spec merges, per README convention):
#   #15912  Phase C.0   — Eio_context audit + RFC §3.3 amend
#   #15941  Phase D.1   — Pool design (interface-first spec)
#   #16039  Status sync — Draft→Active frontmatter only
---

# RFC-0107 — Outbound HTTP stack consolidation

본 RFC 는 2026-05-16 ENFILE storm 의 *진짜* 근본 원인 4개를 다룬다. RFC-0101 (Fd_accountant multi-kind throttle) 는 같은 사고에 대한 transitional defense 였으나, *증상 완화* 이지 *원인 치료* 가 아니다. RFC-0101 이 Docker/Provider/exec/log 계열을 점진적으로 wire 하더라도, 본 RFC 가 머지되면 RFC-0101 은 *transitional defense-in-depth* 로 redefine 되며 §5 retirement clock 으로 demote 된다.

Prior Art 는 `~/me/knowledge/research/2026-05-17-piaf-ocsigen-eio-fd-prior-art.md` 에서 사전 검토했다. piaf 가 *per-endpoint keep-alive* 의 검증된 구현체이고, multi-host pool 은 application 책임이라는 추상화 경계가 우리에게 그대로 적합하다. 본 RFC §3.2 의 L2 Pool 은 piaf 위에 올리는 `(host, port) → Client.t` thin wrapper 이지 자체 connection pool 의 재발명이 아니다.

## 1. Problem

### 1.1 cohttp-eio 6.1.1 socket-not-closed bug

- **Evidence**: `lib/masc_http_client/masc_http_client.ml:1-13` 헤더 인용:
  > *"cohttp-eio 6.1.1 does not reliably close the underlying TCP socket fd when the Eio.Switch exits (observed on macOS). This module intercepts the connection factory via [make_generic] to capture the raw socket and close it explicitly on switch release."*
- **현재 워크어라운드**: `make_closing_client` 는 cohttp-eio 의 `make_generic` factory 를 가로채 `tracked_flows: Eio.Resource.t list ref` 에 모든 socket flow 를 등록한 뒤, `Switch.on_release` 시점에 명시적으로 close. 정교한 우회 trick 이지만 *Eio 공식 권고 위반* — Eio issue #244 에서 Eio 팀이 "라이브러리의 자동 리소스 정리에 맡기고 명시적 close 하지 말 것" 권고했음에도, 우리는 cohttp-eio 의 부족을 우회하기 위해 어쩔 수 없이 명시적 close 를 추가.
- **결과**: 매 호출 `connection: close` 강제 → keep-alive 0건 → runtime 마다 N socket burst.
- **상위 issue**: [`ocaml-cohttp#85`](https://github.com/mirage/ocaml-cohttp/issues/85) "Support HTTP Keep-Alive" — 2014-01 개설, Closed (milestone "1.0 Stable API"), 결과적으로 abandoned/out-of-scope. masc 의 워크어라운드는 그 gap 의 lower bound.

### 1.2 Connection pool 부재 — masc + oas 양쪽

- **masc**: `lib/masc_http_client/masc_http_client.ml` 가 매 호출 fresh `Eio.Switch.run` → `Client.make` → 1 request → switch release → tracked socket close.
- **oas**: `oas/lib/llm_provider/http_client.ml:380-410` 의 `get_sync` / `post_sync` 가 동일 패턴.
- **RFC-0100 (Streamable HTTP)** 가 명시적으로 connection pooling 을 *out-of-scope* 로 명시 (line 20).
- **Runtime 영향**: 12+ keeper 가 runtime 재시도 안에서 매 호출 새 TCP+TLS 를 염. runtime 1 turn 에 5~12 fd burst (provider probe + runtime attempt + tool call HTTP).

### 1.3 Switch hierarchy gap

- **`lib/keeper/keeper_turn_driver_try_provider.ml:406`**: runtime attempt 마다 fresh `Eio.Switch.run (fun attempt_sw -> ...)` 존재 — runtime level 은 OK.
- **`lib/keeper/keeper_agent_run.ml:196`**: `run_turn` 자체는 ambient switch 사용. **turn-scoped FD boundary 가 없음**.
- **결과**: turn 내부에서 spawn 된 fiber 가 attempt switch 가 아니라 ambient switch 에 attach 되면, turn 종료 후에도 FD 가 해제되지 않음. `try_provider:406` 의 fresh switch 는 *opt-in* 이라 turn 본체 코드가 그 switch 를 쓰지 않을 수 있음.
- **Eio.Switch 공식 axiom**: *"Resource cannot outlive its switch"* ([공식 docs](https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html)). Ambient switch 를 쓰면 resource lifetime 의 상한이 ambient 만큼 길어지는데, 우리 ambient 는 keeper lifetime 전체 — *FD 가 keeper 종료까지 살아남을 수 있음*.

### 1.4 Subprocess-heavy Docker

- **모든 live Docker 호출** 은 subprocess `docker run/exec`의 실제 dynamic extent를 `Fd_accountant.observe`로 기록한다 (`lib/worker_runtime_docker.ml`, `lib/keeper/keeper_sandbox_*.ml`). 관측은 호출을 지연하거나 거부하지 않는다.
- **Docker HTTP API (`/var/run/docker.sock`) 사용 0건**. sandbox Execute runner 가 명시적으로 `blocked_mount_paths` 에 등재 (security 의도).
- **fd 비용**: subprocess 1회 = daemon socket 1 + stdio pipe 3 + cgroup fd. SDK/HTTP API 호출 = 같은 daemon socket 재사용. *runtime-storm 의 가장 큰 spike 원인*.
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

> **Phase C 복잡도 정정 (2026-05-17)**: 본 절은 초기에 "run_turn 본문을 `Eio.Switch.run` 으로 감싸기 — ~반일" 로 추정됐다. Phase C.0 audit 결과 (`RFC-0107-eio-context-switch-audit.md`) `lib/eio_context/eio_context.ml:84` `get_switch_opt ()` 가 **전역 atomic** 으로 root switch 를 반환하고, **26 callsite** (server/dashboard 9 + keeper-turn 16 + misc 1) 가 이걸 거치므로 naïve wrap 단독으로는 효과가 없음이 드러났다. 실제 wiring 은 별도 Phase C.1 PR 로 분리한다.

**의도된 lifecycle**:

```ocaml
(* lib/keeper/keeper_agent_run.ml:196 — Phase C.1 (wiring) *)

let run_turn ... =
  Eio.Switch.run @@ fun turn_sw ->
  (* turn 본체. retry 시 fresh sub-switch 는 try_provider:406 이 이미 보장.
     turn_sw 는 turn 의 모든 FD 의 절대 상한 lifetime 으로 동작.

     주의: 단순 wrap 만으로는 부족하다. body 내부 호출이
     Eio_context.get_switch_opt () 를 거치는 경우 root_sw 로 우회된다.
     audit §4 의 Option (2)/(3)/(4) 중 결정 필요. *)
  ...
```

**Invariant (Phase C TLA+ spec — `specs/keeper-switch-hierarchy/`)**:
- For any FD `f` opened during `run_turn`, `f ∈ turn_sw.resources` at any timepoint
- After `run_turn` returns, `turn_sw.alive = false` ∧ `∀ f. f ∉ turn_sw.resources`
- **추가 invariant**: `∀ r. r.role = server ⇒ r.attached = root_sw` — server/dashboard fiber 가 fork 한 자원은 *반드시* root_sw 에 attach. 이 invariant 가 buggy.cfg 에서 깨지는 race scenario 가 `ServerForkDuringTurn` (audit §5).

`try_provider:406` 의 attempt switch 는 turn switch 의 *자식* 으로 nested — Eio Switch 가 부모-자식 lifecycle 을 정상 지원하므로 변경 불필요. 주석만 강화.

**Phase C 분할**:
- **Phase C.0** (본 RFC 와 함께 머지): audit doc + TLA+ spec (clean+buggy). wiring 없음.
- **Phase C.1** (audit §6 결정 후): Option (2) atomic swap + §2.1 root_sw_ref 분리 *OR* Option (3) fiber-local *OR* Option (4) 명시적 ~sw propagation. critical path 가 아니므로 Phase D pool 머지를 차단하지 않는다.

### 3.4 L4 Sandbox transport — Docker HTTP API via UDS

```
sandbox_exec
   │
   ├─ env MASC_DOCKER_TRANSPORT=api      → docker_api.ml (UDS + L1 transport)
   └─ env MASC_DOCKER_TRANSPORT=subprocess → 직접 subprocess + FD observation
```

- 기본값: `api` (Phase E 머지 후).
- Subprocess 경로는 *transitional fallback* — env flag 로 rollback 가능, 30-90일 후 제거.
- security: docker.sock mount 정책 별도 §7 open question.
- RFC-0097 의 container reuse 가 자연스럽게 활성화 — exec endpoint 가 같은 UDS 위에 multiplex.

## 4. Implementation phases

본 RFC 의 phase 구성은 plan `~/me/planning/claude-plans/me-workspace-yousleepwhen-masc-oas-vast-moonbeam.md` 와 동기화. 요약:

| Phase | Scope | Critical path? |
|---|---|---|
| A.0 | Prior Art deep-read | yes (prereq) |
| A | RFC Draft + push | yes |
| B | HTTP transport spike + 결정 | yes |
| C.0 | Audit + TLA+ spec (wiring 없음) | yes (본 RFC 와 함께) |
| C.1 | run_turn wrap + Option (2/3/4) 결정 wiring | follow-up (critical path 아님) |
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

Gate 입력은 두 개의 보완적 evidence — *결정론적 in-process witness* + *비결정론적 production 30일 sample*. 한 쪽만으로는 demotion 정당화 불충분.

**Witness 1 — in-process (deterministic).** `test/test_pool_runtime_storm.ml` (Phase D.2e). cohttp-eio loopback echo server + 16 fiber × 5 sequential request 81-call burst. `Pool.stats` 가 keep-alive 계약을 만족해야 통과:
- `create_count_total ≤ fiber_count` (worst case = 모든 fiber 가 첫 dial 에서 parked queue miss)
- `reuse_count_total > total − fiber_count − 1` (reuse 가 우세)
- `reuse + create == total` (accounting)

실측: `create=16, reuse=65, fibers=16`. pre-D `make_closing_client` 시절이라면 `create=81, reuse=0` 이 됐을 runtime-fd-storm 패턴 (§1.1) 이 정확히 사라졌음을 입증.

**Witness 2 — production (statistical).** Phase D 머지 후 **30일 production sample**:
- peak `process_open_fds < RLIMIT_NOFILE_soft × 0.5`
- ENFILE count = 0 (24h × 30일)

Gate 통과 = Witness 1 reproducer green AND Witness 2 두 임계 충족. 통과 시:
- blocking accountant API → `Fd_accountant.observe` (counter only, no blocking)
- `_shared_pressure_mutex` 제거 (재진입 deadlock 위험 해소)
- dead variant (`Provider_http`, `Sandbox_exec`, `Log_writer`) 삭제

**90일** 후:
- `Fd_accountant` 모듈 전체 제거 또는 metrics-only stub 으로 강등
- legacy Docker-only pre-admission 모듈 제거 (2026-07-13 완료)

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
- **D**: 16 keepers × 5 turn runtime-storm reproducer 통과, ENFILE 0건.
- **E**: container reuse 100회 exec 후 fd diff = 0. security review pass.
- **F**: 30일 production sample 의 fd peak / ENFILE 카운트 측정.
- **G**: 부팅 후 `launchctl limit maxfiles` 반영 확인.

회귀 방지:
- 30일 평균 `cohttp_eio.connection_close_workaround_counter` (Phase D 후 0 되어야 함)
- 30일 평균 `fd_accountant.with_slot.invocations{kind=Docker_spawn}` (Phase E 후 monotonic 감소)
- `git log --grep="WORKAROUND"` 신규 0 (Phase F 이후)
