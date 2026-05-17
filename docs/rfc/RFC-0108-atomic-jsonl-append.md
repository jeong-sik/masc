---
rfc: "0108"
title: "Atomic JSONL Append (in-process)"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0079", "0088"]
implementation_prs: []
---

# RFC-0108: Atomic JSONL Append (in-process)

> **Numbering note**: originally allocated as RFC-0107 via
> `scripts/rfc-allocate-next.sh`. Renumbered to 0108 after PR #15900
> ("RFC-0107 outbound HTTP stack consolidation") merged to main first.
> CLAUDE.md `feedback_rfc_number_reservation_needed` — claim 전 + push
> 직전 두 번 `git fetch + ls docs/rfc/` 가 권고되지만, 본 사례는 두
> PR이 같은 시각대에 allocate-next 를 호출한 race 였음.

## 1. Context & Evidence

2026-05-17 `~/me/.masc/` 스캐너로 라이브 JSONL 출력을 전수 검증한 결과 **43 파일 / 379 라인 malformed**가 발견되었다. 손상 데이터는 raw_decode + utf-8 replace 로 수리되어 `~/me/.masc/_repair_backup/20260517/` 에 백업되어 있고, 잔해 38건은 `*.quarantine` sidecar 로 격리되어 있다.

손상은 4 카테고리에 분포한다:

| 카테고리 | malformed 라인 | 손상 패턴 |
|---|---|---|
| `logs/system_log_YYYY-MM-DD.jsonl` | 2 | `}{` concat (두 JSON 이 newline 없이 한 라인에) |
| `oas-events/YYYY-MM/DD.jsonl` | 38 | `}{` concat + 라인 중간에 다른 record 헤더 삽입 |
| `trajectories/<keeper>/trace-*.jsonl` | 89 | utf-8 multibyte 절단 — record 끝의 한글 byte가 다음 라인으로 흘러감 |
| `keepers/<keeper>/reaction-ledger/YYYY-MM/DD.jsonl` | 114 | utf-8 multibyte 절단 — 같은 패턴, 2026-05-17 하루에 집중 |
| (총) | **243** (live) + 136 (legacy _backups) | |

손상은 *데이터 보존 가능* 한 케이스가 대부분이지만(라인 1개 절단으로 record 1개 손실), 다음 위험이 누적된다:

- 로그 파서/리플레이가 한 줄 단위 `json.loads` 호출 시 throw → fallback fail-open 시 데이터 침묵 손실
- `Yojson.Safe.from_string` 의 `Extra data` 와 utf-8 `Malformed_utf8` 가 서로 다른 분기로 노출되어 호출자가 패턴별 catch 필요
- 진단 중 손상 라인을 sample 로 보고 "data drift" 로 오해할 가능성

## 2. Diagnosis: 3-Tier Concurrency Protection 누적

탐색 결과 같은 코드베이스에 **3 단계 동시성 보호**가 누적되어 있다:

| Tier | Writer | 보호 메커니즘 | 손상 발생 |
|---|---|---|---|
| 0 (없음) | `Ring.write_to_sink` (`lib/masc_log/log.ml:286-294`) | `output_string + output_char + flush` 3 syscall, mutex 0 | `}{` concat 직발 |
| 1 (Stdlib) | `Fs_compat.append_file_unix` (`lib/fs_compat/fs_compat.ml:152-214`) → `trajectories` | `Stdlib.Mutex` + `Append_fd_cache` LRU | utf-8 절단 발생 |
| 2 (Eio) | `Dated_jsonl.append` (`lib/dated_jsonl/dated_jsonl.ml:256-272`) → `oas-events` / `reaction-ledger` | `Eio.Mutex.use_ro` per base_dir + 내부 `Fs_compat.append_jsonl` | utf-8 절단 발생 |

핵심 인사이트: **Tier-1 도 Tier-2 도 손상이 발생했다**. 이는 다음을 의미한다:

1. `Fs_compat.append_file_unix` 의 코멘트(`lib/fs_compat/fs_compat.ml:152-156`)가 명시한 *"single-domain assumption holds"* 가 이미 깨졌다. masc-mcp는 cascade dispatch / dashboard 등에서 Eio domain 을 분기시키며, `Stdlib.Mutex` 는 도메인 간 동기화가 보장되지만 같은 도메인에서 fiber preemption이 발생할 때 OCaml channel buffer의 atomicity 가 깨진다.
2. `Eio.Mutex` 를 써도 내부에서 `Fs_compat.append_jsonl → Stdlib.output_string + flush` 두 단계로 호출하면, large record (PIPE_BUF=512B macOS / 4KB Linux 초과)가 multiple `write(2)` 로 쪼개진다. POSIX는 `O_APPEND` 의 atomicity를 PIPE_BUF 이하만 보장하므로, 같은 path 에 다른 도메인 writer가 있으면 interleave 가능.
3. trajectories record는 prompt 전체 dump 라 routine 하게 1KB ~ 8KB 범위. PIPE_BUF 초과는 *예외가 아니라 기본 케이스*.

즉 손상의 직접 원인은 단순 mutex 누락이 아니라 다음 두 가지의 결합이다:
- **a)** `output_string` + `flush` 가 두 syscall이라 그 사이 race window가 존재한다 (Tier-0/1).
- **b)** record + '\n' 의 *직렬화 단계와 write 단계가 분리*되어 있어, large content의 multiple `write(2)` 사이에 다른 writer가 끼어든다 (Tier-1/2).

3 단계의 분기 누적은 RFC-0088 (Counter-as-Fix umbrella) 가 가리키는 *Symptom 억제 패턴*의 사례다. 한 모듈씩 fix가 들어갈 때마다 그 모듈에만 적합한 작은 mutex 가 추가됐고, 통일된 SSOT 로 수렴된 적이 없다. 이번 RFC는 그 수렴을 한다.

## 3. Design: `Jsonl_atomic.append` SSOT

새 모듈 `lib/jsonl_atomic/jsonl_atomic.ml` 를 신설하여 4 writer 가 모두 이걸로 수렴한다.

### 3.1 Interface

```ocaml
(* lib/jsonl_atomic/jsonl_atomic.mli *)

type t
(** Opaque writer handle. One [t] per output path. *)

val open_writer :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  path:string ->
  t
(** Open or reuse an append writer for [path].
    The handle is shared via a per-path registry — calling [open_writer]
    twice for the same path returns equivalent handles that serialize
    against the same Eio.Mutex. *)

val append : t -> Yojson.Safe.t -> (unit, [`Io of string]) result
(** Atomic JSONL line append (in-process):
    1. Serialize [record + "\n"] into a single Bytes buffer in memory
       — no JSON syscall.
    2. Acquire the per-path Eio.Mutex (fiber + domain safe).
    3. Single write(2) loop: retry on short-write / EINTR until the
       full buffer is written. Behaves as POSIX append-atomic for
       in-process callers regardless of record size.
    4. Release mutex. fsync is NOT called per-record (per-record
       fsync would dominate runtime); fsync runs on [close] only. *)

val close : t -> unit
(** Flush + close the underlying fd. Removes the handle from the
    registry. Idempotent. *)
```

### 3.2 보장 (in-process only)

| 보장 | 메커니즘 |
|---|---|
| Fiber race 0 | Per-path `Eio.Mutex.t` 가 fiber + 도메인 양쪽 직렬화 (Eio scheduler 인식) |
| Partial-write 0 | `write(2)` 루프가 short-write / EINTR 처리하며 record + '\n' 전체 전송 |
| Record interleave 0 | serialize→write 가 같은 critical section, 두 record 가 절대 섞이지 않음 |
| Large record 안전 | PIPE_BUF 초과 record(prompt dump 등)도 mutex 보유 fiber가 끝까지 쥐고 있음 |

### 3.3 명시적 비목표

- **Cross-process race**: 별 OCaml CLI / subprocess 가 같은 파일에 write 하는 시나리오. masc-mcp 단일 프로세스 전제로 보호하지 않는다. 필요해지면 별도 RFC 에서 `flock(2)` 추가.
- **Per-record fsync**: durability 보장은 `close` 시점만. crash 시 마지막 N record 손실은 수용.
- **Cross-domain LRU fd cache**: 단순화를 위해 fd 는 첫 `open_writer` 가 가지고 있다가 `close` 시 해제. fd 수가 keeper N (≤64) 수준이라 cache 가 없어도 무방.

## 4. Migration Plan

### 4.1 4 Writer 수렴

| 파일 | 변경 |
|---|---|
| `lib/masc_log/log.ml:286-294` | `output_string + output_char + flush` 3-syscall → `Jsonl_atomic.append` 1 호출. mutex 추가가 사이드 이펙트. |
| `lib/trajectory/trajectory.ml:229-269` | 3 함수 (`append_entry`, `append_thinking`, `append_summary`) 가 `Fs_compat.append_file` → `Jsonl_atomic.append` 로 swap. Stdlib.Mutex 간접 의존 제거. |
| `lib/dated_jsonl/dated_jsonl.ml:256-272` | `Fs_compat.append_jsonl` → `Jsonl_atomic.append`. 외부 시그니처 변경 없음. |
| `lib/cascade/cascade_event_bridge.ml:992` | (변경 없음 — `Dated_jsonl.append` 경유, 자동 fix) |
| `lib/keeper/keeper_reaction_ledger.ml:135-137` | (변경 없음 — `Dated_jsonl.append` 경유, 자동 fix) |

### 4.2 기존 Helper 처리

- `Fs_compat.append_file` 자체는 유지 (non-jsonl generic append 호출자: ledger 등). `Fs_compat.append_jsonl` 은 `Jsonl_atomic.append` 로 위임만 하는 thin wrapper 가 되어 점진적 deprecate.
- `Append_fd_cache` LRU 는 Tier-1 caller 가 사라지면 데드 코드가 됨. 별도 PR 에서 정리.

### 4.3 PR 분할 (stack)

각 PR 이 독립 머지 가능하게 구성한다 (post-merge child orphan 회피, `feedback_stacked_pr_auto_close_recovery`).

1. **PR-1** (본 PR): RFC docs-only.
2. **PR-2**: `Jsonl_atomic` 모듈 + `test/test_jsonl_atomic.ml`. Caller 0 으로 머지 가능 (`Jsonl_atomic_test` 만 caller).
3. **PR-3**: system_log 마이그레이션. 가장 단순, 가장 큰 효과 (`}{` concat 즉시 차단).
4. **PR-4**: trajectories 마이그레이션.
5. **PR-5**: `Dated_jsonl` 내부 swap (oas-events + reaction-ledger 동시 fix).

## 5. Verification

### 5.1 Unit (`test/test_jsonl_atomic.ml`)

3 stress 케이스:

| 케이스 | 시나리오 | 검증 |
|---|---|---|
| Concurrent fibers | 16 fiber × 1000 record 동시 append | 라인 수 == 16,000 / 모든 라인 valid JSON / 모든 record 정확히 1회 등장 |
| Large records | record 4 KB (PIPE_BUF 초과) × 1000 | decode error 0 / 라인 길이 변동 없음 |
| Multibyte boundary | 한글 record 가 PIPE_BUF 경계에 걸치도록 padding × 1000 | utf-8 decode error 0 |

각 케이스 후 `~/me/scripts/validate-jsonl-files.py` 와 동등한 검증 로직(per-file scan, 라인별 `Yojson.Safe.from_string`).

### 5.2 Integration (실측)

각 마이그레이션 PR 머지 후 24시간 운영 → 해당 카테고리 경로 재스캔. malformed 0 확인.

- PR-3 머지 후: `~/me/.masc/logs/system_log_*.jsonl`
- PR-4 머지 후: `~/me/.masc/trajectories/`
- PR-5 머지 후: `~/me/.masc/oas-events/` + `~/me/.masc/keepers/*/reaction-ledger/`

한 번이라도 malformed ≥ 1 재발견 시 즉시 §3.2 보장 모델 회귀.

### 5.3 Stress reproduce

수리 백업 (`~/me/.masc/_repair_backup/20260517/`) 의 손상 라인 패턴을 unit test 골든으로 복제. 같은 동시성 조건을 `Jsonl_atomic` 위에서 재현 시 malformed 0 이어야 한다.

## 6. Non-Goals (명시)

이 RFC 의 scope 밖. 별도 RFC 후보:

| 항목 | 이유 |
|---|---|
| Cross-process flock | masc-mcp 단일 프로세스 전제. 외부 CLI tool 이 `.masc/` 에 동시 write 한다는 evidence 없음. |
| `Stdlib.Mutex` 전역 audit | jsonl 외 다른 IO (SQLite, network) 도 같은 함정일 수 있으나, evidence 가 아직 jsonl 에 한정됨. evidence 가 추가되면 별도 RFC. |
| 손상 데이터 재조립 자동화 | boundary 추정은 또 하나의 워크어라운드. quarantine 수동 유지. |
| Per-record fsync / durability | crash recovery 는 별도 design space. |
| Performance benchmark | Eio.Mutex 대비 Stdlib.Mutex 의 throughput 차이 측정. PR-5 머지 이후 별도 작업. |

## 7. Open Questions

- `Append_fd_cache` 의 LRU 가 모두 데드코드가 된 시점에 제거할지, 별도 helper 로 보존할지. PR-5 머지 후 caller 0 확인 후 결정.
- `Jsonl_atomic.close` 가 호출되지 않은 채 프로세스 종료될 때의 graceful flush. `at_exit` 등록 vs Eio Switch teardown 어느 쪽이 더 적합한지.

## 8. References

- 이번 스캔 결과: `~/me/planning/claude-plans/fluffy-stargazing-eclipse.md`
- 수리 백업: `~/me/.masc/_repair_backup/20260517/`
- RFC-0079: structured log source decoder (system_log writer 가 따르는 schema)
- RFC-0088: Counter-as-Fix umbrella (이 RFC 의 진단 §2 가 같은 패턴 분석에 닿음)
