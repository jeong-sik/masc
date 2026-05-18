---
rfc: "0122"
title: "Keeper disk pressure — process-local fleet failure mode beyond FD"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0097", "0101", "0103"]
implementation_prs: []
---

# RFC-0122: Keeper disk pressure — process-local fleet failure mode beyond FD

## §1 Problem (caller-context)

`lib/keeper_disk_pressure.ml` (342 LoC, 신설 2026-05-15) 가 *process-local disk exhaustion guard* — FD pressure (RFC-0101) 와 *다른* fleet failure mode 를 cover. 본 모듈 자체는 RFC 부재로 작성됨. RFC-0103 (log retention) 가 §"PR-4 disk pressure cooldown — 별도 영역" 으로 *명시적으로 다른 RFC* 명시.

모듈 자체 주석:

> "Disk pressure is a different fleet failure mode from FD exhaustion: Docker playgrounds and JSONL telemetry can keep growing after the request that created them has returned. This module exposes a cheap cached filesystem-free-space projection and a circuit breaker tripped by ENOSPC style errors."

### 누적 PR (RFC 없이 진행)

| PR | 제목 | 변경 |
|---|---|---|
| #15845 (`980107d7ed` + `e208e53988`) | `fix(keeper): disk pressure circuit breaker (PR-4/5)` | 신규 모듈 추가 |
| (`287cca2bf4`) | `fix: surface keeper admission denials` | admission 통합 |
| (`e577d51552`) | `fix(keeper): harden 24-fleet resource gates` | fleet-scale wiring |

**"PR-4/5" 표기** = 5 PR sequence — 4번째 + 5번째가 머지된 것으로 보임 — *외부 RFC 없음 in commit log*. RFC-0103 가 *cross-reference* 만, 본 series 의 architecture commitment 없음.

### Module API 분석

```ocaml
type disk_snapshot = {
  path : string;
  filesystem : string;
  total_bytes : int;
  used_bytes : int;
  available_bytes : int;
  capacity_percent : float;
  available_percent : float;
  mounted_on : string;
}

type snapshot_result =
  | Snapshot of disk_snapshot
  | Probe_error of string

type admission_block =
  | Disk_pressure_cooldown of float
  | Disk_free_space_low of {
      path : string;
      available_bytes : int;
      min_free_bytes : int;
      available_percent : float;
      ...
    }
```

- *typed* admission block (`Disk_pressure_cooldown` cooldown signature, `Disk_free_space_low` predicate) — RFC-0042 closed-sum 정신 적용.
- *cached projection* 의 staleness 정책 미명시.
- *ENOSPC circuit breaker trip 조건* — heuristic 그대로 코드.
- *circuit breaker reset 정책* — cooldown duration 만 (audit doc 없음).

### Why this needs an RFC

1. **5+ PR series 가 RFC 없이 진행** — CLAUDE.md `pre_workflow.md` §"진입 장벽" 위반 (`복잡한 비즈니스 로직: 상태 다이어그램/의사코드/테스트 케이스 먼저 작성`).
2. **FD accountant (RFC-0101) 의 sibling** — 같은 *process-local resource exhaustion* family. RFC-0101 의 multi-kind Eio.Pool 패턴 적용 가능.
3. **Cooldown / cache 패턴 잠재 워크어라운드 시그니처**: CLAUDE.md §"Cap / Cooldown" — "force a turn after the cap", "saturation pre-skip cap". Disk cooldown 의 *근본* (왜 fleet 가 disk 압력 trigger? log retention RFC-0103 가 default disabled 이라서? Docker playground unbounded growth? JSONL unbounded growth?) 명시 부재.
4. **`Probe_error` 의 silent drop 가능성**: snapshot probe 실패 시 cached 값 사용 — staleness 측정 없으면 RFC-0044 read-side fallback 시그니처.
5. **`min_free_bytes` threshold tuning**: env knob 없음 또는 hardcoded — 운영자 tuning surface 미정의.

근본 원인: **disk pressure 가 *별도 mechanism* 으로 작성 — RFC-0101 (FD pressure) 의 통합 *Resource pressure family* 가 없음.**

## §2 Approach

3 layer:

**Layer A — Unified `Resource_pressure` family**

`lib/keeper_disk_pressure` 를 `lib/resource_pressure/disk.ml` 로 reorganize:

```ocaml
module Resource_pressure : sig
  module type S = sig
    type snapshot
    type admission_block
    val snapshot : unit -> (snapshot, [ `Probe_error of string ]) Result.t
    val should_block : snapshot -> admission_block option
    val circuit_breaker_state : unit -> [ `Open | `Half_open | `Closed ]
  end
end

module Disk_pressure : Resource_pressure.S with type admission_block = ...
module Fd_pressure : Resource_pressure.S with type admission_block = ...  (* RFC-0101 *)
(* future: Memory_pressure, IO_throughput_pressure, etc. *)
```

각 pressure 가 *같은 admission interface* — caller 가 uniformly dispatch. RFC-0101 의 multi-kind Eio.Pool 패턴 generalize.

**Layer B — Probe staleness contract**

`snapshot` 의 *max cached age* 명시:

```ocaml
val snapshot : ?max_cached_age_ms:int -> unit -> snapshot_result
```

`Probe_error _` 시 cached 가 *명시적으로 stale* — caller 가 `Result.Error _` 처리 vs `Result.Ok stale_snapshot` 차이 결정.

**Layer C — Disk pressure tuning surface**

`MASC_DISK_PRESSURE_MIN_FREE_BYTES` (default 1GB? — fleet size 의존), `MASC_DISK_PRESSURE_COOLDOWN_SEC` (default 60s?), `MASC_DISK_PRESSURE_PROBE_INTERVAL_MS` (default 5000ms?) env knob 명시. Operator-tunable surface.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Resource_pressure.S` interface module + `Disk_pressure` 가 implements + 5 unit test | dune build PASS, alcotest PASS |
| P3 | `Fd_pressure` (RFC-0101) 가 `Resource_pressure.S` implement (alias only) — unified caller dispatch | RFC-0101 호환 break 없음 |
| P4 | Probe staleness contract — `~max_cached_age_ms` 도입. `Probe_error` 시 명시적 caller 처리 | PBT: 5 staleness scenario PASS |
| P5 | Tuning env knob 정의 (`MASC_DISK_PRESSURE_*`) + docs/spec/14-configuration.md 갱신 | doc-code drift CI PASS |
| P6 | Telemetry: `keeper_disk_pressure_admission_block_total{kind}` — **Counter-as-Validator** (cooldown trigger 횟수 monitor) | 4주 baseline 측정, anomaly threshold 설정 |

P2-P3 가 unified family interface. P4 staleness. P5 tunability. P6 observability.

## §4 Open questions

1. **Q1**: `Resource_pressure.S` 의 generic admission_block ↔ disk-specific `Disk_pressure_cooldown` / `Disk_free_space_low` variant 의 type relationship? **잠정**: `admission_block` 가 functor type parameter — `Disk_pressure.admission_block` = `Disk_pressure.t` variant set.

2. **Q2**: Probe staleness 의 *기본값* — 5s vs 30s? 빠른 회복 trade-off vs probe cost. **잠정**: 5s (현 코드 patten 추정). P4 의 PBT 가 5s 가정 검증.

3. **Q3**: Disk pressure circuit breaker 의 *trip 조건* — ENOSPC 1회 vs N회? cascade error 와 분리? **잠정**: ENOSPC 1회 trip + cooldown 60s. P2 의 첫 commit 가 spec 명시.

4. **Q4**: RFC-0103 (log retention) 의 *default disabled* 가 disk pressure trigger root — 그러나 본 RFC 는 *pressure 자체* 만, retention 정책 별도. **잠정**: 본 RFC 가 RFC-0103 cross-reference, retention 정책 변경 별도 RFC.

## §5 Non-goals

- **`Memory_pressure`, `IO_throughput_pressure` 같은 새 dimension**: 본 RFC 는 *disk + FD* family unification 만. 새 dimension 은 같은 family 확장으로 후속 RFC.
- **Disk usage 정책** (어떤 directory 가 어떤 size limit): RFC-0103 (log retention) + 별도 RFC 담당. 본 RFC 는 *pressure 감지 + admission gate* 만.
- **사용자 일별 *purge* 정책**: 별도 RFC (또는 사용자 GitOps).

## §6 Risk & rollback

- **Risk 1**: `Resource_pressure.S` functor refactor 가 RFC-0101 (FD) 의 *기존 caller* 깨뜨림. → P3 의 alias 가 기존 API 보존. Caller migration P3 안에서 점진적.
- **Risk 2**: Probe staleness 가 *기존 production* 보다 strict — 운영자 부담. → P4 의 default 가 *기존 behavior 보존* (max_cached_age = infinity by default), opt-in tuning.
- **Risk 3**: Env knob (P5) 도입이 *config doctor* 부담. → P5 가 default 값 검증 후 doc 갱신.
- **Risk 4**: Circuit breaker telemetry (P6) 가 *false positive* — fleet 가 disk pressure 없는데 trigger. → telemetry 가 4주 baseline 후 threshold 설정, alerting 별도.

Rollback: P2-P3 functor 비활성 가능 (각 모듈 standalone 유지). P4 staleness default infinity 시 영향 0. P5/P6 env knob/counter 명시적 disable.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Resource_pressure.S` functor + `Disk_pressure.implements`.
- [ ] P3: `Fd_pressure` (RFC-0101) 도 implement. Unified caller dispatch.
- [ ] P4: Probe staleness contract + `~max_cached_age_ms`.
- [ ] P5: Env knob 도입 + docs/spec/14-configuration.md 갱신.
- [ ] P6: telemetry counter 4주 baseline, anomaly threshold 설정.

## §8 Number allocation note

Allocated as RFC-0122. Ledger advanced 0109 → 0123 (skip 0109-0121 due to inflight #15902 RFC-0109 + #15924/15927/15933/15937/15939/15944/15947/15957/15963/15967/15968/15971 RFC-0110~0121 (iter-2..13 of this loop)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
