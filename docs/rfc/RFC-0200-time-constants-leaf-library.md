# RFC-0200 — Time constants 를 leaf library 로 분리

| Field | Value |
|-------|-------|
| Status | Draft |
| Author | jeong-sik |
| Date | 2026-05-27 |
| Related | Magic Number Time-literal 시리즈 회고 §3.1, PR #19099, PR #19109 |

## 1. Context

Magic Number Time-literal 시리즈 (16 PR, 107 sites removed, 회고 `docs/audit/2026-05-27-magic-number-time-literal-series-retrospective.md`) 가 `Masc_time_constants` SSOT 로 매직 넘버 정리.  그러나 4 사이트가 *library boundary* 때문에 out-of-scope 남음:

- `lib/masc_log/log.ml` (2 사이트, `86400.0`)
- `lib/core/safe_ops.ml` (1 사이트, `3600.0`)
- `lib/briefing_compactors/briefing_compactors.ml` (1 사이트, `3600.0`)

## 2. 현재 dep graph

```
masc_log ─────────────── (leaf, no deps on masc_config/masc_core)
   ↑
masc_core ── (depends on masc_log)
   ↑
masc_config ── (depends on masc_core + masc_log)
   │
   └─ contains  Masc_time_constants
```

`Masc_time_constants` 가 `masc_config` 안에 있어서:
- `masc_log → masc_config` 시 cycle (`masc_config → masc_log` already)
- `masc_core → masc_config` 시 cycle (`masc_config → masc_core` already)

→ 4 사이트가 SSOT 호출 불가, magic literal 보존.

## 3. Proposal

**`Masc_time_constants` 을 별도 leaf library `masc.time_constants` 로 분리.**

```
masc_time_constants ────── (NEW leaf, no deps)
   ↑     ↑     ↑     ↑
masc_log  masc_core  masc_config  ...
```

leaf library 는 *stdlib 만 의존* — cycle 발생 0.  모든 library (현재 + 미래) 가 자유롭게 호출 가능.

### 3.1 변경 사항

| 파일 | 동작 |
|------|------|
| `lib/time_constants/dune` (NEW) | `(library (name masc_time_constants) (public_name masc.time_constants) (wrapped false))` |
| `lib/time_constants/masc_time_constants.ml` (MOVE) | `lib/config/masc_time_constants.ml` 에서 이동 |
| `lib/time_constants/masc_time_constants.mli` (MOVE) | `lib/config/masc_time_constants.mli` 에서 이동 |
| `lib/config/dune` (EDIT) | `(modules ...)` 에서 `masc_time_constants` 제거 + `(libraries ...)` 에 `masc.time_constants` 추가 |
| `lib/masc_log/dune` (EDIT) | `(libraries ...)` 에 `masc.time_constants` 추가 |
| `lib/core/dune` (EDIT) | `(libraries ...)` 에 `masc.time_constants` 추가 |
| `lib/briefing_compactors/dune` (EDIT) | `(libraries ...)` 에 `masc.time_constants` 추가 |

기존 caller 의 `Masc_time_constants.hour` / `.day` / `.hour_int` / `.day_int` / `.days_to_seconds` 호출은 그대로 — `wrapped false` 이라 module name unchanged.

### 3.2 미적용 4 사이트 활용 (post-merge)

```ocaml
(* lib/masc_log/log.ml *)
let yesterday = format_utc_date_of (Time_compat.now () -. Masc_time_constants.day)
let cutoff = Time_compat.now () -. (float_of_int keep_days *. Masc_time_constants.day)

(* lib/core/safe_ops.ml *)
let utf8_repair_log_idle_eviction_sec = Masc_time_constants.hour

(* lib/briefing_compactors/briefing_compactors.ml *)
| latest :: _ -> now_ts -. latest <= Masc_time_constants.hour
```

= 매직 넘버 4 사이트 추가 정리 (총 sweep: 107 → 111).

## 4. Risk

| Risk | 평가 |
|------|------|
| Build break | **Low** — `wrapped false` 라 module name 동일.  callers 무변경. |
| Cycle 도입 | **None** — leaf library 라 cycle 발생 불가. |
| Performance | **None** — 컴파일 시 inline. runtime 동일. |
| Test 영향 | **None** — 동작 무변경. |

## 5. Migration plan

**단일 PR 가능** (변경 작음, 모두 dune metadata + file move):

1. `lib/time_constants/{dune, masc_time_constants.ml, masc_time_constants.mli}` 신설 (3 file move)
2. `lib/config/dune` 의 `modules` 에서 `masc_time_constants` 제거 + `libraries` 에 `masc.time_constants` 추가
3. `lib/masc_log/dune`, `lib/core/dune`, `lib/briefing_compactors/dune` 의 `libraries` 에 dep 추가
4. 4 미적용 사이트 SSOT 호출 변환
5. `dune build lib/` PASS 검증

## 6. Alternatives considered

### (A) `Masc_time_constants` 을 `masc_log` 로 이동

`masc_log` 가 가장 lower leaf 였다면 의미적 align. 그러나 *logging surface 와 time constants 무관* — 책임 혼합. 그리고 *time-only library* 가 향후 timezone/duration 추가 시 확장 base.

### (B) `masc_core` 에서 *time-only sub-module* 분리

기존 `masc_core` 안 `Time_compat` 와 함께. 단점: `masc_log` 가 `masc_core` 의존 안 함 (역방향, cycle). `masc_core` 이전 새 leaf 신설 필요.

→ (A) 도 (B) 도 leaf-library 신설 패턴이라 결국 같은 작업.

### (C) 그대로 두고 4 사이트 보존

Magic literal 4 개 보존, 회고 §3.1 처럼 "out-of-scope" 명시. *코드 변경 0* 의 장점. 단점: 향후 SSOT 작업이 *같은 library boundary 한계* 반복.

→ 본 RFC 가 (C) 의 *반복 비용* > leaf library 신설 *1회 비용* 으로 판단.

## 7. Acceptance criteria

- [ ] `lib/time_constants/` 신설, `dune build lib/` PASS
- [ ] 4 미적용 사이트 SSOT 호출로 변환
- [ ] 기존 dependents (masc_config + 모든 caller) 동작 무변경 확인
- [ ] 회고 문서 §3.1 (library boundary 4 사이트) 가 "RFC-0200 by 처리됨" 으로 update
- [ ] Magic Number lint 가 hour/day 매직 넘버 추가 사이트 0 검증

## 8. Out-of-scope

- `minute_int` SSOT 추가 (회고 §3.2) — 별도 RFC.  단위 변환 계수 예외 해석 + canonical idiom 보존 결정 영역.
- `time_constants` 외 다른 SSOT 모듈 의 library boundary issue — 본 RFC 는 *time constants 1 모듈* 만 다룸.

## 9. Open questions

- Library 이름: `masc.time_constants` (descriptive, 길음) vs `masc.time` (짧음, 향후 확장 base) vs `masc.consts` (가장 generic).  본 RFC 는 `time_constants` 권장 — *time-specific scope* 명시가 library 책임 명확.
- `wrapped false` vs `wrapped true`: 기존 호출자 무변경 위해 `wrapped false` (module name 유지). 향후 더 많은 module 추가 시 `wrapped true` 로 namespacing — 별도 RFC.

🤖 Draft generated as part of `/loop` iter 71 — Magic Number Time-literal retrospective §3.1 follow-up.
