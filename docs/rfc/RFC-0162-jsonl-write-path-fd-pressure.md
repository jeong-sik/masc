---
rfc: "0162"
title: "JSONL Write-Path FD Pressure Root-Fix"
status: Draft
created: 2026-05-23
updated: 2026-05-23
author: vincent
supersedes: []
superseded_by: null
related: ["0089", "0097", "0108", "0137", "0154"]
implementation_prs: []
---

# RFC-0162 — JSONL Write-Path FD Pressure Root-Fix

## 0. TL;DR

Dashboard 라이브 상태(2026-05-23) 가 `.masc/tool_calls/` append 경로에서 `EMFILE/ENFILE` 을 표시하고 있다. 진단 결과 7 개의 표면 신호(`tool_call_io_append_failed`, `Fiber_unresolved` paused keeper, `CDAL proof incomplete`, `Fleet capacity degraded`, `PULSE idle`, dashboard self-amplification, 영구 누적 disk) 가 **단일 root** `.masc/` JSONL writer 의 fd/disk 압박으로 수렴한다.

RFC-0108 §3.3 는 `Cross-domain LRU fd cache` 를 *명시적 비목표* 로 선언하면서 "fd 수가 keeper N (≤64) 수준이라 cache 가 없어도 무방" 이라고 가정했다. 본 RFC 는 production evidence 로 이 가정을 반증하고, 네 phase 로 root chain 을 닫는다.

| Phase | 변경 | RFC 의존 | Effect |
|---|---|---|---|
| 0a | `Fs_compat.append_jsonl` mkdir_p path-keyed memoize | 없음 (RFC-0108 직교) | append 당 stat syscall 1 → 0 |
| 0b | `Dated_jsonl.count_entries` TTL cache (10s) | 없음 | dashboard 30s refresh self-amplification 제거 |
| 1 | `MASC_TOOL_CALL_LOG_RETENTION_DAYS` opt-in → opt-out default 30d | 본 RFC (mli 약속 회복) | 무한 누적 정책 종료 |
| 2 | Cross-domain fd reuse (per-domain fd cache) | 본 RFC, RFC-0108 §3.3 가정 invalidate | append 당 open+close 2 syscall 제거 |

## 1. Context & Evidence

### 1.1 화면 trace (2026-05-23)

dashboard `monitoring?section=fleet-health` (Tool Monitor 패널) 가 표시:

```
coverage gaps 3: tool_call_io_append_failed
  PRODUCER keeper_hooks_oas|mcp_server_eio_call_tool
  STORE    /Users/dancer/me/.masc/tool_calls
  ERROR    taskmaster/masc_transition: Sys_error("/Users/dancer/me/.masc/tool_calls/2026-05:
           Eio.Io Unix_error (Too many open files in system, fstatat, ...)")
SUCCESS 68.3% / 22,440 calls
PAUSED KEEPERS 9 / RUNNING 13 / TOTAL 24
REACTION CAPACITY 1/17  (exec 4, shortfall 16)
HEALTH banner: [Source mismatch] [Paused keepers 9] [Fleet capacity degraded] [CDAL proof incomplete 1]
PULSE idle (footer)
```

### 1.2 Disk state

```
$ find /Users/dancer/me/.masc/tool_calls -type f -name '*.jsonl' | wc -l
30
$ du -sh /Users/dancer/me/.masc/tool_calls/
465M
```

30 day-file × 평균 15 MB. `MASC_TOOL_CALL_LOG_RETENTION_DAYS` env unset → 영구 누적 (`lib/keeper_tool_call_log.ml:93-103` `retention_days ()` 가 None 반환).

### 1.3 RFC-0108 §3.3 가정 invalidate

RFC-0108 (Atomic JSONL Append) 가 다음을 명시적 비목표로 선언:

> Cross-domain LRU fd cache: 단순화를 위해 fd 는 첫 `open_writer` 가 가지고 있다가 `close` 시 해제. **fd 수가 keeper N (≤64) 수준이라 cache 가 없어도 무방.**

라이브 데이터는 이 가정을 *세 축* 에서 반증한다:

1. **호출량 축**: 22,440 tool calls / 활동 윈도우 → 매 호출이 fresh `open_out_gen` (`lib/fs_compat/fs_compat.ml:642-661`) 를 부르므로 N=64 fd 는 *순간 동시 open 수* 일 뿐, OS file-table churn 은 그 1000× 이상.
2. **stat 축**: `Fs_compat.append_jsonl` 가 매 호출 `mkdir_p dir` 호출 (`fs_compat.ml:645`). month dir 이 이미 존재해도 `Sys.file_exists` 또는 `Eio.Path.mkdirs` 가 `fstatat` 1회 호출. RFC-0108 의 fd budget 분석 *밖* — fd 가 아닌 stat 압박.
3. **read-side amplification 축**: dashboard 가 30s 마다 `Dated_jsonl.count_entries` (`lib/dated_jsonl/dated_jsonl.ml:426`) 로 30 day-file 을 모두 `open_in_bin` + line-scan. write-path fd 압박을 *보여주는* UI 가 read-path 로 같은 fd 풀을 더 압박한다. self-amplification.

### 1.4 7 surface → single root chain

```
.masc/<store>/YYYY-MM/DD.jsonl writer 의 fd/disk write-path 압박
  ├─ S1. coverage_gap "tool_call_io_append_failed: 3"
  │       lib/keeper_tool_call_log.ml:179 stale_reason
  ├─ S2. trace "taskmaster/masc_transition: ...fstatat..."
  │       lib/keeper_tool_call_log.ml:182 (~error formatter)
  ├─ S3. paused 9 의 일부 — blocker_class=Fiber_unresolved
  │       lib/keeper/keeper_status_bridge.ml:317-321
  │       (코드 자체가 "preserve the original root cause" 라고 자인)
  ├─ S4. CDAL proof incomplete 1 — 같은 write-path 가 CDAL writer 에도 영향
  ├─ S5. Fleet capacity degraded — keeper turn 실패 누적
  ├─ S6. PULSE idle — journal entry write 실패 → latestEntry undefined
  │       dashboard/src/components/status-tray.ts:321
  └─ S7. dashboard refresh self-amplification (§1.3 #3)
```

S3 의 `Fiber_unresolved` variant 는 RFC-0089 (substring classifier closure) family 의 *carve-out gap* 이다: typed variant 22 종 중 어디에도 `Fd_pressure_blocked` / `Disk_write_failed` 같은 infra-level cause 가 *없다*. 본 RFC §3.5 가 관련 후속 RFC 후보로 명시한다.

## 2. Diagnosis: 3 concurrent root contributors

| Contributor | 위치 | 책임 |
|---|---|---|
| **C1. mkdir_p 매 호출** | `lib/fs_compat/fs_compat.ml:642-661` `append_jsonl` 가 `mkdir_p dir` 호출 | append 당 stat 1회. month dir 이 이미 존재해도 회피 불가 |
| **C2. fresh fd 매 호출** | 같은 함수의 `open_out_gen` ... `close_out_noerr` | RFC-0108 §3.3 이 *명시적* 으로 cache 안 함. 결과: append 당 open+close 2 syscall |
| **C3. 무한 disk 누적** | `lib/keeper_tool_call_log.ml:93-103` `retention_days ()` 의 None default | 4 월 데이터가 5 월 운영 fd 압박에 기여. mli 가 *이미 "default is 30 days"* 약속 → ml drift 가 root |

C1 은 RFC-0108 결정과 *직교*. C2 는 RFC-0108 §3.3 결정과 *충돌* — 가정 invalidate 후 변경. C3 은 *문서-구현 drift 회복*.

## 3. Design

### 3.1 Phase 0a — mkdir_p once-per-path memoize

`lib/fs_compat/fs_compat.ml` 에 process-local cache 추가:

```ocaml
let mkdir_p_done : (string, unit) Hashtbl.t = Hashtbl.create 32
let mkdir_p_memo_mu = Stdlib.Mutex.create ()

let mkdir_p_memoized (path : string) : unit =
  let cached =
    Stdlib.Mutex.protect mkdir_p_memo_mu (fun () ->
      Hashtbl.mem mkdir_p_done path)
  in
  if not cached then begin
    mkdir_p path;
    Stdlib.Mutex.protect mkdir_p_memo_mu (fun () ->
      Hashtbl.replace mkdir_p_done path ())
  end
```

`append_jsonl` 의 `mkdir_p dir` → `mkdir_p_memoized dir` 로 swap (hot path 만).

**보장**:

| 보장 | 메커니즘 |
|---|---|
| Cross-domain safe | `Stdlib.Mutex.protect` 가 cache lookup/insert 보호. mkdir 자체는 idempotent |
| Race 시 max 2 회 stat | A/B 두 도메인 동시 진입 시 둘 다 lookup→miss→mkdir 실행. 두 번째 mkdir 은 EEXIST 무해 |
| Cache eviction 없음 | dir path 는 month/store 단위라 process lifetime 동안 O(month 수) 항목만 누적 |

**RFC-0108 과 직교**: 본 cache 는 *fd* 가 아니라 *dir 존재 사실* 만 캐싱. RFC-0108 §2.5 의 `out_channel` buffer 공유 corruption 과 무관.

### 3.2 Phase 0b — Dated_jsonl.count_entries TTL cache

`lib/dated_jsonl/dated_jsonl.ml` `count_entries` 에 process-local TTL cache. `count_entries_uncached` 를 새 public symbol 로 추가해 audit/test 가 live 값을 볼 수 있게 한다.

```ocaml
let count_cache_ttl_sec = 10.0
let count_cache : (string, count_cache_entry) Hashtbl.t = Hashtbl.create 8
let count_cache_mu = Stdlib.Mutex.create ()

let count_entries t =
  let key = t.base_dir in
  let now = Unix.gettimeofday () in
  let cached_opt =
    Stdlib.Mutex.protect count_cache_mu (fun () ->
      match Hashtbl.find_opt count_cache key with
      | Some entry when now -. entry.computed_at < count_cache_ttl_sec ->
        Some entry.entry_count
      | _ -> None)
  in
  match cached_opt with
  | Some n -> n
  | None ->
    let n = count_entries_uncached t in
    Stdlib.Mutex.protect count_cache_mu (fun () ->
      Hashtbl.replace count_cache key { entry_count = n; computed_at = now });
    n
```

dashboard 30s refresh × 3 surface 동시 → TTL 10s 이내 첫 호출만 scan. 30 day-file × 15 MB scan 비용 ~3× ↓.

`count_cache_ttl_sec = 10.0` 는 dashboard refresh interval(30s) 의 1/3 — 한 refresh 사이클당 최대 1회 scan 보장.

### 3.3 Phase 1 — Retention default opt-out

`lib/keeper_tool_call_log.ml:93-103` `retention_days ()` 변경:

```diff
-let retention_days () =
-  (* Opt-in: default disabled. ... *)
-  match Sys.getenv_opt "MASC_TOOL_CALL_LOG_RETENTION_DAYS" with
-  | Some raw ->
-    (match int_of_string_opt (String.trim raw) with
-     | Some days when days > 0 -> Some days
-     | _ -> None)
-  | None -> None
+let retention_days_default = 30
+
+let retention_days () =
+  match Sys.getenv_opt "MASC_TOOL_CALL_LOG_RETENTION_DAYS" with
+  | Some raw ->
+    (match int_of_string_opt (String.trim raw) with
+     | Some days when days > 0 -> Some days
+     | Some _ -> None       (* explicit 0 or negative → retain forever *)
+     | None -> Some retention_days_default)
+  | None -> Some retention_days_default
```

**정책 변경 정당화**:

- 무한 누적은 *기본값* 이 아니라 *명시적 opt-in* 이어야 한다.
- 30 day-file 윈도우는 debugging 충분: trajectory replay, evidence 추적, weekly retro 모두 30 일 내.
- 영구 보존 운영자는 `MASC_TOOL_CALL_LOG_RETENTION_DAYS=0` 명시.
- **추가 정당화 — 문서-구현 drift**: `lib/keeper_tool_call_log.mli:99-103` 가 *이미* "default is 30 days, and values <= 0 disable pruning" 라고 *약속* 한 상태. 구현이 그 약속을 위반한 drift. 본 phase 는 *새 정책 도입* 이 아니라 *공표된 약속 회복*. RFC-0108 §3.3 가정 invalidate 보다 정당화 부담이 낮다.

### 3.4 Phase 2 — Per-path fd cache (RFC-0108 §3.3 invalidate)

본 phase 가 RFC-0108 §3.3 의 *명시적 비목표* 결정을 뒤집는 핵심.

**§3.3 가정**: "fd 수가 keeper N (≤64) 수준이라 cache 가 없어도 무방."

**Invalidation**:

- "fd 수" 는 *순간 동시 open 수* 가 아니라 *unit time 당 open/close churn* 으로 봐야 한다.
- 22,440 tool calls × 평균 4-5 동시 fiber → unit time 당 fd churn 이 호스트 kernel `filp_cachep` 슬랩에 압력.
- macOS Apple Virtualization VM (RFC-0137 §1) 환경에서 host-wide `kern.maxfiles` 가 인근 프로세스와 공유되어 budget 가정이 흔들림.

**Design re-think (2026-05-23, Phase 2 작성 중 발견)**: 본 RFC 초안의 *Design 후보 A — Per-domain fd cache* 는 *cross-domain interleave 위험*을 새로 도입한다. POSIX `O_APPEND + write(buf, len)` 의 atomicity 는 `PIPE_BUF` 이하만 보장 (macOS/Linux 일반적으로 ~4 KB). 4 KB+ record (예: prompt dump, large tool output) 가 두 domain 의 *서로 다른 fd* 로 동시에 write 될 때 record interleave 발생 가능. RFC-0108 §3.2 의 *Record interleave 0* 보장이 깨진다.

**채택 Design — Per-path fd cache (cross-domain serialized)**:

| 결정 | 메커니즘 |
|---|---|
| **Single fd per path** | path 당 단 하나의 `out_channel` 이 process lifetime 동안 재사용. cross-domain interleave 불가능 (fd 가 하나뿐). |
| **Cross-domain serialize** | 기존 `append_path_mutex_registry` (`Stdlib.Mutex`) 가 path 별 mutex 로 fiber + 도메인 양쪽을 직렬화. RFC-0108 §3.2 보장 *그대로 활용*. |
| **Cache lookup 분리 mutex** | path mutex 와 별개의 `fd_cache_mu` 가 Hashtbl op 만 보호 (microsecond 단위 critical section). path mutex 는 `output_string + flush` 만 보유. |
| **LRU evict** | `fd_cache_max = 32` 초과 시 oldest `last_used` 의 fd 를 `Stdlib.close_out`. day rollover 시 어제 path 가 자연 evict. |
| **Process shutdown** | `Stdlib.at_exit` 에 `close_all_cached_writers` 등록. flush 후 close. |

```ocaml
type cached_writer = { oc : out_channel; last_used : float }
let cached_writers : (string, cached_writer) Hashtbl.t = Hashtbl.create 32
let fd_cache_mu = Stdlib.Mutex.create ()
let fd_cache_max = 32

(* Inside fd_cache_mu: get-or-open + LRU. *)
let get_or_open_writer_locked path =
  match Hashtbl.find_opt cached_writers path with
  | Some w ->
    Hashtbl.replace cached_writers path
      { w with last_used = Unix.gettimeofday () };
    w.oc
  | None ->
    if Hashtbl.length cached_writers >= fd_cache_max
    then evict_lru_locked ();
    let oc =
      Stdlib.open_out_gen
        [ Stdlib.Open_append; Stdlib.Open_creat; Stdlib.Open_wronly ]
        0o644 path
    in
    Hashtbl.add cached_writers path
      { oc; last_used = Unix.gettimeofday () };
    oc

let append_jsonl path json =
  test_exec_home_guard ~op:"append_jsonl" path;
  let dir = Filename.dirname path in
  mkdir_p_memoized dir;                              (* Phase 0a *)
  let line = Yojson.Safe.to_string json ^ "\n" in
  let path_mu = get_append_path_mutex path in
  let oc =
    Stdlib.Mutex.protect fd_cache_mu (fun () ->
      get_or_open_writer_locked path)
  in
  Stdlib.Mutex.protect path_mu (fun () ->
    Stdlib.output_string oc line;
    Stdlib.flush oc)
```

**보장 (RFC-0108 §3.2 와 1:1 매칭)**:

| 보장 | 메커니즘 |
|---|---|
| Fiber race 0 | `append_path_mutex_registry` 가 path 별 `Stdlib.Mutex` 로 fiber+도메인 양쪽 직렬화 (RFC-0108 와 같음) |
| Partial-write 0 | `output_string + flush` 가 single critical section 안. `out_channel` buffer 가 cross-call carry-over 하지만 critical section 보장 |
| Record interleave 0 | path 당 단일 fd → POSIX write 가 어떤 size 든 단일 producer 에서 순차 |
| Large record 안전 | 같은 path mutex 가 끝까지 record 보유 |
| Cross-process race | RFC-0108 §3.3 와 같음 — 비목표 |
| Per-record fsync | `flush` 만, no `fsync` — RFC-0108 §6 와 같음 |

**fd budget 분석**:

- macOS default `RLIMIT_NOFILE` = 256 (soft) / unlimited (hard). masc 가 256 root 안에서 운영.
- 4 writer (system_log / trajectory / oas-events / reaction-ledger) × 평균 1 active path = 4 fd baseline.
- Day rollover 시 어제 path 도 evict 전까지 남음 → 최대 8 fd.
- Dashboard read-side, network connection 등 합쳐 ~30 fd. fd_cache_max=32 는 safe margin.
- RFC-0108 §3.3 의 "N≤64" budget 안 *충분히 들어옴*.

### 3.5 §4.5 — Observability gap (related, non-blocking)

본 RFC scope 밖이지만 §1.4 S3 의 `blocker_class` typed variant 의 infra-cause carve-out 은 별도 RFC 후보:

- `Fd_pressure_blocked`
- `Disk_write_failed`
- `Telemetry_lane_unavailable`

RFC-0089 (substring classifier closure) family 의 *infrastructure-level extension* — 본 RFC 머지 후 별도 RFC 로 작성.

## 4. Migration Plan

### 4.1 PR 분할

| PR | Phase | 변경 영역 | Base |
|---|---|---|---|
| #N+0 | RFC body + Phase 0a + 0b + 1 (소규모 cluster, independent commits) | docs/rfc, lib/fs_compat, lib/dated_jsonl, lib/keeper_tool_call_log, test | origin/main |
| #N+1 | Phase 2 impl (큰 작업, 별도 PR) | lib/fs_compat per-domain fd cache, test | origin/main |

각 PR 은 *독립 머지 가능* (RFC-0108 §4.3 학습 반영, `feedback_post_merge_push_check_required` + `feedback_stacked_pr_sha_runtime_on_amend`).

### 4.2 RFC-0108 §3.3 표기 갱신 (Phase 2 PR 과 동봉)

본 RFC §3.4 머지 시 RFC-0108 §3.3 본문에 다음 추가:

```diff
 - **Cross-domain LRU fd cache**: 단순화를 위해 fd 는 첫 `open_writer` 가
   가지고 있다가 `close` 시 해제. fd 수가 keeper N (≤64) 수준이라 cache 가 없어도 무방.
+
+  **Update (RFC-0162, 2026-05-23)**: production evidence (22,440 calls × ENFILE)
+  로 위 가정이 반증됨. Per-domain fd cache 가 RFC-0162 §3.4 에서 도입됨.
```

## 5. Verification

### 5.1 Phase 0a — mkdir cache

- Unit: `test/test_fs_compat_mkdir_memo.ml` — 4 케이스 (first call, repeat idempotent, external-delete contract, concurrent race-safe).
- Integration: 머지 후 24h 운영 → `coverage_gap.tool_call_io_append_failed` 빈도 변화 측정.

### 5.2 Phase 0b — count_entries TTL

- Unit: `test/test_dated_jsonl_count_cache.ml` — 3 케이스 (cache returns stale within TTL, reset clears, distinct stores independent).
- Integration: dashboard refresh 30s × 3 surface 90s 윈도우에 scan 9 회 → 3 회로 ↓.

### 5.3 Phase 1 — Retention default

- mli 약속(`default is 30 days`) 이 이미 contract 라 별도 ml unit test 없이 mli 가 guard.
- Integration: 머지 후 7 일 운영 → `.masc/tool_calls/` 파일 수 ≤ 30 day 유지.

### 5.4 Phase 2 — Per-domain fd cache

- Unit: RFC-0108 §5.1 의 3 stress 케이스 재실행 (16 fiber × 1000 record, 4 KB record, multibyte boundary). malformed 0 확인.
- Stress: 8 domain × 4 path × 1000 record concurrent → fd churn 측정. 가설: open/close syscall ~95% ↓.
- Integration: 24h 운영 후 `EMFILE/ENFILE` trace 빈도 측정.

## 6. Non-Goals

| 항목 | 이유 |
|---|---|
| `Fd_pressure_blocked` typed variant 추가 | §3.5 별도 RFC |
| Cross-process flock | RFC-0108 §6 와 같음 — masc 단일 프로세스 전제 |
| Per-record fsync | RFC-0108 §6 와 같음 — durability 별도 design space |
| Dashboard refresh interval 자체 변경 | UX 결정. Phase 0b 가 효과적이면 interval 유지 가능 |

## 7. Open Questions

- Phase 0a/0b cache 의 *invalidation* — 운영자 외부 `rm -rf .masc/tool_calls/2026-04` 시 cache stale. SIGUSR1 hook 으로 `Hashtbl.reset` 노출 vs 무시.
- Phase 2 per-domain fd cache 의 *day rollover* — UTC 자정 모든 캐시 entry stale. eager refresh vs lazy LRU evict 선택.
- Phase 1 default 30d 적정성 — 운영 7d/debug 30d/audit 90d 의 사용 패턴 evidence 필요.

## 8. References

- RFC-0089 — Substring classifier closure (carve-out gap §1.4 S3)
- RFC-0097 — Keeper sandbox container reuse (FD storm initial fix; spawn-side fd, 본 RFC 는 append-side fd)
- RFC-0108 — Atomic JSONL Append (§3.3 가정 invalidate 대상)
- RFC-0137 — Host FD pressure → keeper pause (외부 host pressure detection; 본 RFC 는 *내부 contributor* 감소)
- RFC-0154 — System error class typed SSOT (`error_class` 필드가 coverage_gap 에 흐름)

## 9. Implementation summary (filled at close-out)

(머지 후 phase 별 PR 번호 + evidence 측정값 기록)
