---
rfc: "0154"
title: "System_error_class typed SSOT — close substring-classifier loop across backend + telemetry + dashboard"
status: Draft
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0088", "0097", "0105", "0122", "0142", "0148", "0149"]
implementation_prs: []
---

# RFC-0154 — System_error_class typed SSOT

## §0 한 줄 요약

OS-level 실패 (FD exhaustion, disk exhaustion, …) 의 *분류* 가 backend 에 4 substring matcher 로 분산되어 있고, 그 결과는 typed 으로 보존되지 않은 채 `Printexc.to_string exn` 으로 압축되어 `Telemetry_coverage_gap.record ~error:string` 로 흐르며, dashboard 가 다시 *그 string 을 substring 으로 재분류* 한다. 본 RFC 는 backend 단일 `System_error_class.t` closed sum SSOT 로 분류를 1회만 수행하고 그 결과를 wire format 에 typed tag (`error_class`) 로 보존하여 dashboard 가 lookup-only 가 되도록 한다.

## §1 문제 — 실측 사이트 (2026-05-20)

### 1.1 분산된 substring vocabulary (이미 4 사이트)

| 파일 | 함수 / 사이트 | needles | 행위 |
|------|--------------|---------|------|
| `lib/keeper_fd_pressure.ml:97-110` | `is_fd_exhaustion_text` | 6 | boolean predicate |
| `lib/keeper_disk_pressure.ml:55-65` | `is_disk_exhaustion_text` | 6 | boolean predicate |
| `lib/coord/coord_utils_ops.ml:410` | inline list | 6 (FD 복붙) | local match |
| `lib/keeper/keeper_stale_watchdog.ml:203` | inline literal | 1 (FD 단독) | watchdog flag |

검증 grep:

```bash
rg -n "too many open files|enospc|disk full" lib/ --type ocaml
```

→ `software-development.md` §AI 코드 생성 안티패턴 §1 (하드코딩 산포): "같은 설정값이 여러 파일에 리터럴로 복붙. AI 가 codebase 의 기존 상수를 검색하지 않고 리터럴을 직접 삽입." 명백한 사례.

### 1.2 Backend 가 *분류 결과* 를 타입으로 보존하지 않음

```ocaml
(* lib/cascade/cascade_event_bridge.ml:664-668 *)
Keeper_fd_pressure.active () || Keeper_fd_pressure.is_fd_exhaustion_exn exn
|| Keeper_disk_pressure.is_disk_exhaustion_exn exn
```

`is_*_exhaustion_exn` 은 `exn → bool` predicate. 분류 결과 (FD vs Disk vs Other) 가 boolean 으로 축약 — 누가 어느 클래스에 매칭됐는지 호출자가 알 수 없음.

### 1.3 Telemetry surface 에서 다시 string 압축

`Telemetry_coverage_gap.record ~error` 의 13 caller 가 *전부* `Printexc.to_string exn` 또는 `sprintf` 합성 문자열을 전달:

```
lib/tool_usage_log.ml           ~error:(Printexc.to_string exn)         (3 sites)
lib/mcp_server_eio_call_tool.ml ~error:(Printexc.to_string exn)         (2 sites)
lib/keeper/keeper_*.ml          ~error:(Printexc.to_string exn|msg)     (7 sites)
lib/keeper_tool_call_log.ml     ~error:(sprintf "%s/%s: %s" ...)        (3 sites)
```

검증 grep:

```bash
rg -B0 -A10 "Telemetry_coverage_gap.record" lib/ --type ocaml | rg "error:|Printexc.to_string|\?error"
```

13 caller 중 0 개가 *분류 결과* 를 전달. 모두 raw string.

### 1.4 Dashboard 가 substring matching 으로 재분류

`dashboard/src/components/common/coverage-gap-block.ts` (RFC-0097/0122 hint 추가 후 현재 상태):

```ts
const FD_EXHAUSTION_NEEDLES = ['too many open files', 'enfile', 'emfile'] as const
const DISK_EXHAUSTION_NEEDLES = [
  'no space left on device', 'enospc', 'disk quota exceeded',
  'quota exceeded', 'disk full', 'not enough space',
] as const
```

→ Backend 가 이미 동일 vocabulary 로 분류한 정보를 wire 에서 *버리고* dashboard 가 *다시 분류*. 정보 손실 cycle.

### 1.5 정보 손실 다이어그램

```
exn (typed in OCaml)
  └─→ Keeper_fd_pressure.is_fd_exhaustion_exn → bool   ❶ 분류 결과 → bool 으로 축약
       Printexc.to_string exn → string             ❷ raw text 만 보존
        └─→ Telemetry_coverage_gap.record ~error    ❸ wire 에 string
             └─→ dashboard (TS)                      ❹ string 다시 substring match
                  → reason: "fd_exhaustion"         ❺ 분류 정보 *재발명*
```

❶ 의 분류 결과를 ❺ 까지 보존하면 ❷~❹ 의 가공이 전부 lookup 으로 단순화됨.

## §2 왜 워크어라운드인가

본 영역은 `software-development.md` §워크어라운드 시그니처 3종 중 **§2 (String/Substring 분류기 보강)** 의 다중 사이트 사례 + **§3 (N-of-M 패치)** 의 잠재 누적 사례 .

- **§2 신호**: 4 사이트에서 동일 substring vocabulary. 한 곳에 새 패턴 추가하면 다른 3 곳은 *반드시 누락*. RFC-0042 (`keeper_terminal_code` closed-sum) 가 같은 패턴을 다른 surface 에서 닫음.
- **§3 신호**: PR #17051 (오늘 머지) 가 dashboard 측에 RFC-0122 패턴 *추가*. PR-1 (FD) 에 이어 PR-2 (Disk) — 2-of-M. M 은 미정 (Permission_denied / Connection_refused / Timeout 등 가능). N-of-M 패턴이 *render-side hint* 라는 좁은 surface 라 단기적으로는 무해하지만, 누적이 시작된 상태.

RFC-0149 (Counter-as-Fix sunset) 가 이미 *같은 audit 사이클* 에서 telemetry-as-fix self-recurrence 를 기록함 (`feedback_telemetry_as_fix_self_recurrence.md`). 본 RFC = 그 audit 흐름의 다음 site.

## §3 Root Fix — `System_error_class.t` typed SSOT

### 3.1 새 모듈 (PR-1, 단독 머지 가능)

`lib/system_error_class.ml` (신규, 의존성 없음):

```ocaml
(** Closed-sum classification of operating-system / runtime error surfaces
    that the masc-mcp fleet reacts to today (FD storm, disk pressure, …).
    Adds new variants only when a backend reactor and a canonical RFC both
    exist for the failure mode — see §3.3 below. *)

type t =
  | Fd_exhaustion       (** RFC-0097: ENFILE / EMFILE / "too many open files" *)
  | Disk_exhaustion     (** RFC-0122: ENOSPC / disk quota / "disk full" *)
  | Permission_denied   (** EACCES / "permission denied" — operator action: check perms *)
  | Connection_refused  (** ECONNREFUSED / "connection refused" — upstream down *)
  | Timeout             (** ETIMEDOUT / "operation timed out" *)
  | Other of string     (** parse-don't-validate escape hatch: original message preserved verbatim *)

val classify_exn : exn -> t
(** Pattern-match on [Unix.Unix_error _] errno values first, then fall back
    to [classify_string (Printexc.to_string exn)]. *)

val classify_string : string -> t
(** Case-insensitive substring match. Vocabulary is the union of the four
    pre-existing inline matchers documented in §1.1. *)

val to_short_tag : t -> string
(** "fd_exhaustion" / "disk_exhaustion" / "permission_denied" /
    "connection_refused" / "timeout" / "other". Wire-format stable. *)

val to_raw_text : t -> string
(** Original error message — [Other s] returns [s], named variants return a
    canonical short label. Used when the caller wants both the typed tag
    and a human-readable message. *)
```

### 3.2 Caller migration (PR-2, codemod)

`Telemetry_coverage_gap.record` 시그니처에 `?error_class:System_error_class.t` 추가, JSON wire 에 `error_class` 필드 추가 (backward compat: `error` 원본 string 유지). 13 caller 를 codemod 로 일괄 변경:

```ocaml
(* before *)
Telemetry_coverage_gap.record ~error:(Printexc.to_string exn) ...

(* after *)
let cls = System_error_class.classify_exn exn in
Telemetry_coverage_gap.record
  ~error_class:cls
  ~error:(System_error_class.to_raw_text cls)
  ...
```

동시에 4 inline matcher → `System_error_class.classify_*` 호출로 치환 → vocabulary SSOT 단일화.

### 3.3 Dashboard lookup-only (PR-3)

`coverage-gap-block.ts` 의 `classifyCoverageError` 제거, `errorClassFromBackend(structured.error_class)` lookup 으로 교체:

```ts
const ERROR_CLASS_HINTS: Record<string, CoverageErrorHint> = {
  fd_exhaustion: { reason: 'fd_exhaustion', label: 'FD exhaustion — see RFC-0097', href: '...RFC-0097...' },
  disk_exhaustion: { reason: 'disk_exhaustion', label: 'Disk pressure — see RFC-0122', href: '...RFC-0122...' },
  // permission_denied / connection_refused / timeout: hint 추가 시점에 entry 추가
}
export function errorHintFromClass(errorClass: string | null | undefined): CoverageErrorHint | null {
  return errorClass ? ERROR_CLASS_HINTS[errorClass] ?? null : null
}
```

→ Dashboard 에서 *substring matching 0 사이트*. 새 클래스 추가 시 lookup table 한 entry 만 추가.

## §4 Wire format (backward compat)

`masc.telemetry_coverage_gap.v1` JSON schema 갱신:

```json
{
  "schema": "masc.telemetry_coverage_gap.v1",
  "ts": 1716220800.0,
  ...
  "error": "Sys_error(\"Eio.Io Unix_error (Too many open files...\")",
  "error_class": "fd_exhaustion"  // NEW, optional during transition
}
```

- `error` (기존): backward compat 유지 — 외부 reader 가 raw message 를 기대.
- `error_class` (신규): optional. Reader 가 absent 일 때 `unknown` fallback. PR-2 머지 후 모든 신규 row 에 present.

Transition cutoff: 14 일 후 (`schema: masc.telemetry_coverage_gap.v2`) — `error_class` required. 본 RFC closeout commit 에서 schema bump 확정.

## §5 Phase plan

| Phase | PR | Scope | 의존성 |
|-------|-----|------|--------|
| Spec | (this PR) | RFC body + ledger ratchet + README index update | — |
| PR-1 | TBD | `lib/system_error_class.ml` + tests | Spec |
| PR-2 | TBD | `Telemetry_coverage_gap.record` sig + 13 caller codemod + 4 inline matcher → SSOT | PR-1 |
| PR-3 | TBD | Dashboard lookup-only + remove `classifyCoverageError` | PR-2 머지 후 wire 안정화 (~3일) |
| PR-4 | TBD | Schema v2 (`error_class` required), deprecate v1 reader path | PR-3 |
| Closeout | TBD | Status: Draft → Implemented, README index update | All |

각 PR 은 *독립적으로 revert 가능* — PR-1 만 머지하고 PR-2 보류하더라도 모듈은 dead code 로 안전하게 잔존.

## §6 비-목표 (Out of scope)

- **SDK error → masc_internal_error 분류**: RFC-0142 의 영역. cascade_error_classify.ml 의 33 catch-all 은 본 RFC 가 다루지 않음.
- **LLM-facing tool_error closed sum**: RFC-0148 의 영역. tool_library / tool_code_write 의 6 LLM-facing surface 는 본 RFC 가 다루지 않음.
- **OS errno 전수 분류**: `Other of string` escape hatch 유지. POSIX errno 50+ 개를 전부 named variant 으로 만들지 않음 — 본 RFC 는 *backend reactor + RFC* 가 존재하는 클래스만 named.
- **Repository-wide `Printexc.to_string` 제거**: log-only 사이트는 본 RFC scope 아님 (RFC-0148 §1.2 와 동일 원칙).

## §7 워크어라운드 거부 시그니처 self-check

CLAUDE.md `software-development.md` §워크어라운드 거부 체크리스트 7항목 + 시그니처 3종:

| 항목 | 본 RFC |
|------|--------|
| §1 텔레메트리-as-fix | ❌ 분류 자체를 typed 화. counter 추가 없음. |
| §2 string/substring 분류기 추가 | ❌ 오히려 4 substring matcher → 1 typed SSOT 로 **dedup**. |
| §3 N-of-M | ❌ 13 caller + 4 matcher 전부 PR-2 codemod 한 번에. |
| §4 catch-all `_->` | ❌ `Other of string` 명시 (parse-don't-validate escape hatch). |
| §5 cap/cooldown/dedup/repair | ❌ |
| §6 test backdoor | ❌ |
| §7 같은 typo N-N fix | ❌ |

전부 통과. Override 조건 (production-blocking + WORKAROUND 라벨) 불필요.

## §8 Related work

| RFC | 관계 |
|-----|------|
| **RFC-0042** | keeper_terminal_code closed-sum — 선례 (안티패턴 닫는 방식 참조) |
| **RFC-0088** | Counter-as-Fix umbrella — 본 RFC 는 umbrella 의 typed-boundary 적용 사례 |
| **RFC-0097** | keeper-sandbox container reuse — FD class 가 매핑되는 RFC |
| **RFC-0105** | Agent_sdk.Error.t typed envelope (Implemented) — wire-level typed envelope 선례 |
| **RFC-0122** | keeper disk pressure — Disk class 가 매핑되는 RFC |
| **RFC-0142** | cascade_error_classify decomp — 다른 모듈 (SDK error vs OS error), §6 비-목표 |
| **RFC-0148** | LLM-facing tool_error closed sum — **자매 RFC** (operator-facing 버전이 본 RFC) |
| **RFC-0149** | telemetry-as-fix sunset — 같은 audit 흐름, §2 Out-of-scope 의 후속 site |

## §9 Open questions

1. **`Other of string` 의 어디까지 typed 화?** — 본 RFC 는 *backend reactor + RFC* 가 동시 존재하는 클래스만 named variant. POSIX errno 추가 demand 가 누적되면 별도 RFC 로 확장.
2. **Wire schema cutoff** — 14 일은 임의 선택. 외부 reader 인벤토리 (`masc.telemetry_coverage_gap.v1` consumer) 가 모두 SSOT 안에 있으면 더 빠르게 가능. PR-3 시점에 재평가.
3. **`coord_utils_ops.ml:410` inline matcher** — `cascade_*` 영역이라 RFC-0142 와의 경계가 살짝 겹침. `is_fd_exhaustion_text` 의 caller 인지 확인 후 PR-2 에서 본 RFC 적용 / RFC-0142 보류 결정.
