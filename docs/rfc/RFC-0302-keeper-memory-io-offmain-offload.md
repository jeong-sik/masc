# RFC-0302: Keeper 메모리 파일 I/O off-main-domain 오프로드 (HOL fix)

- Status: Draft
- Author: Claude Opus 4.8
- Date: 2026-07-01
- Related: issue #22823 (tracking), RFC-0243/0259/0272 (keeper memory store), 2026-06-19 keeper stall (mutex poison via Eio-in-systhread)
- 근거 메모리: `reference-masc-compaction-not-hol-cause-measured-7ms-20260630.md`

## 0. 정정 (v2) — #22824 선행 + 메커니즘 교정

초안(v1)은 stale memory("사용자 scope 대기")를 근거로 `Eio_guard.run_in_systhread`를 추천했으나, **현재 main SSOT 재확인 결과 교정**한다:

- **#22824 MERGED**(`fix(keeper): run memory render I/O off the main Eio domain`)가 이미 **READ 경로**(user-model render + memory-os recall)를 `keeper_run_tools_hooks.ml`에서 **call-site 오프로드**했다. 사용한 메커니즘 = **`Domain_pool_ref.submit_io_or_inline`**(공유 **도메인 풀**; 풀 미설치 시 inline — 테스트). `Executor_pool_ref`의 policy-preserving 동반자이며 eio_guard.ml:46-48이 지목한 "structural cure(Executor_pool)"의 keeper 정책판.
- **따라서 메커니즘은 `run_in_systhread`가 아니라 `Domain_pool_ref.submit_io_or_inline`**(established·preferred). run_in_systhread는 (a) 열등하고 (b) #22824의 도메인-풀 오프로드 안에서 read를 또 systhread로 감싸면 nested `run_in_systhread` → 핸들러 없는 스레드에서 `Effect.Unhandled` 위험.
- **접근도 source→call-site로 교정**: #22824가 확립한 call-site 오프로드 패턴을 **아직 안 된 경로로 확장**한다. 잔여 미오프로드 = **librarian WRITE/cap 경로**(`keeper_librarian_runtime.ml`의 append/cap/merge)와 기타 동기 I/O 호출 사이트.
- **도메인 풀 오프로드 제약(§5 재프레이밍)**: systhread-poison이 아니라 **read-only + module-level mutable state 없음**이 조건(#22824 주석). 즉 (a) plain-ref memo(`keepers_dir()`의 `cached_resolution`)는 main 선-resolve, (b) `File_lock_eio`의 **process-shared Eio.Mutex는 cross-domain 안전이 아님** → LOCK_MIXED(write/cap)를 도메인 풀에 통째로 넘길 수 없다. lock은 main 유지하고 lock 내부 순수 read/parse/write만 넘기거나, 락 획득을 도메인-안전 구조로 재설계해야 한다.
- **§5 분류(PURE 37/LOCK_MIXED 15/NO_IO 16)는 여전히 유효**: "read-only·shared-state 없음"이 도메인 풀 오프로드의 안전 기준과 정확히 일치(PURE = 넘길 수 있음, LOCK_MIXED = 락/Fs_compat 때문에 통째로는 불가). 아래 §4.1/§5는 `Domain_pool_ref.submit_io_or_inline` / Executor_pool worker-domain job을 기준으로 작성한다.

아래 §1-§9는 문제·분류·마이그레이션 골격으로 유효하되, **메커니즘은 위 정정을 따른다**.

## 1. 문제 (라이브 측정)

라이브 masc 프로세스(PID 116.7% CPU) `sample` 프로파일에서 main Eio 도메인이 keeper 메모리 서브시스템의 **동기 파일 I/O + JSON 파싱**에 점유됨:

- `Keeper_memory_os_io` stat/file_exists — **1388 샘플**
- Yojson 파싱 — 762 샘플
- 동기 `read` — 345 샘플
- `Skill_candidate_store` — 111 샘플
- `cap_episode_files` / `Keeper_memory_recall` 추가 점유

Eio는 **단일 도메인 cooperative 스케줄러**다. main 도메인에서 도는 blocking syscall은 그동안 **모든 fiber를 stall**시킨다. 결과: inline MCP dispatch가 60s 예산을 초과 → timeout → **형제 keeper HOL(head-of-line blocking)**. 즉 "하나가 멈추면 다 멈춘다".

> 구분: fiber-크래시 격리(`Eio_guard.protect`)는 이미 verified. 이건 **별개 메커니즘** — 크래시가 아니라 **동기 I/O에 의한 스케줄러 스타베이션**. compaction 가설은 측정 6.8ms로 배제됨.

## 2. 경계 분석

이건 **MASC-internal**이다. OAS 무관(OAS는 single-provider completion만; 파일 저장/메모리는 MASC 소유). MASC↔OAS 경계 변경 없음. 대상은 `lib/keeper/keeper_memory_os_io.ml`(781줄) 및 동일 패턴의 `Skill_candidate_store`/`Keeper_memory_recall`(후속).

## 3. 근본 원인

`keeper_memory_os_io.ml`이 **순수 blocking Stdlib I/O**를 사용(Eio async/도메인 오프로드 0):

- `Sys.readdir` 스캔 4곳: `list_fact_store_keeper_ids_for_keepers_dir`(:64), `max_generation_from_files`(:190), `read_episode_files_tail`(:709), `cap_episode_files`(:763)
- `Sys.file_exists`/`Sys.is_directory`/`open_in_bin`+`really_input_string`+`close_in` 다수(:13,:202,:361,:408,:433,:680 …)
- 이 함수들이 `Keeper_memory_recall`/`Keeper_memory_os_consolidation_runtime` 등에서 **main 도메인 fiber 경로**로 turn마다 호출.

## 4. 접근

### 4.1 1축 — 순수 blocking I/O를 도메인 풀로 오프로드 (primary)

채택 primitive는 `Domain_pool_ref.submit_io_or_inline`이다. 풀 설치 전 테스트/초기화 경로에서는 inline fallback하고, 런타임에서는 `Domain_pool.submit_io` -> `Eio.Executor_pool.submit_exn`으로 공유 도메인 풀 워커에서 실행한다. RFC-0302의 규범은 v1의 `run_in_systhread` 패턴이 아니라 #22824가 확립한 **call-site domain-pool offload**를 따른다.

예상 구현 형태:

```ocaml
let keepers = keepers_dir () (* main-domain first touch for path/memo resolution *)

let facts =
  Domain_pool_ref.submit_io_or_inline (fun () ->
    read_facts_all_strict_for_keepers_dir ~keepers_dir:keepers ~keeper_id)
```

오프로드 closure는 **read-only + module-level mutable state 없음 + Eio/shared-lock/Fs_compat effect 없음**이어야 한다. path/memo resolution(`keepers_dir()` / `Config_dir_resolver`)은 main domain에서 먼저 끝내고, `_for_keepers_dir` / `_for_base_path` 계열의 pure seam만 제출한다. `File_lock_eio` lock acquire/release, `Fs_compat.save_file(_atomic)`, 그리고 Eio effect가 발생할 수 있는 write는 main domain에 남긴다.

### 4.2 2축 — 빈도/알고리즘 감소 (secondary)

오프로드는 스케줄러를 살리지만 도메인 풀 제출(`Domain_pool_ref.submit_io_or_inline`) 오버헤드가 호출당 발생한다. 따라서 호출 수 자체를 줄인다: 같은 dir을 turn마다 재스캔하는 중복 `readdir` 제거, 재-`stat` 제거, recall/skill 결과를 파일 mtime 기반 캐시로 무효화. (별도 후속 PR 가능.)

### 4.3 3축 — 관측 (guard)

메모리 I/O 경로에 latency/호출수 메트릭(Turn당 readdir/stat/read 카운트, 도메인 풀 제출 수)을 추가해 회귀 감시. "모든건 관측됨" 원칙 정합.

## 5. 안전 분석 (CRITICAL) — PURE vs LOCK_MIXED 분류

**최대 리스크**: `Domain_pool_ref.submit_io_or_inline`에 넘기는 closure를 "아무 blocking 작업"으로 취급하는 것이다. 이 closure는 Executor_pool worker domain에서 실행되므로, Eio effect / process-shared lock / module-level mutable first-touch를 넣으면 안전하지 않다. 금지 항목은 `Eio.Mutex.use_rw/ro`, `Eio.Switch`, `Eio.Fiber`, `Eio.Time`, `File_lock_eio` flock, `Eio_guard.with_mutex/protect`, `Fs_compat.save_file(_atomic)`의 Eio.Path 경로, 그리고 `Config_dir_resolver` 같은 plain-ref memo first-touch다. 잘못된 오프로드는 HOL을 고치려다 worker-domain 예외, lock-order 꼬임, 또는 2026-06-19 계열의 keeper stall을 재유발한다.

그러므로 각 함수를 분류한다:

- **PURE_BLOCKING**: 전체 body(+ 모든 transitive helper)가 Stdlib/Sys/Unix 파일 op + Yojson 파싱 + 순수 계산만. Eio op 0, shared lock 0, module-level mutable first-touch 0 → **body 전체를 `Domain_pool_ref.submit_io_or_inline`에 제출해도 안전**.
- **LOCK_MIXED**: Eio lock(`with_facts_lock`/`with_episode_bundle_lock`/`File_lock_eio`/`Eio.Mutex`)·clock·yield·Fs_compat write 등 Eio/shared effect를 body 어딘가에서 수행 → **Eio/lock/write 부분은 main 도메인 유지**, lock 획득/해제 사이의 **순수 file-I/O 하위 구간만** 오프로드.
- 기본 가정은 **LOCK_MIXED(unsafe)**; transitive call graph를 읽어 Eio op 0을 증명해야만 PURE.

### 5.1 함수별 분류 (적대적 verify workflow 산출)

`wf_ef7cea25-9f1` (69 함수, default-unsafe, transitive helper까지 재판독, low-confidence 0): **PURE 37 / LOCK_MIXED 15 / NO_IO 16**.

**PURE_BLOCKING (37, whole-body 오프로드 안전)** — Eio op 0. hot path 포함:
- readdir 스캔(#22823 hotspot): `list_fact_store_keeper_ids_for_keepers_dir`(:64), `max_generation_from_files`(:190), `cap_episode_files`(:763), `read_episode_files_tail`(:709 경유 `read_episode_file`).
- read tail(sync-read 345 samples): `read_lines_tail`/`read_lines_all`, `read_facts_tail_for_keepers_dir`, `read_events_tail`, `read_episodes_tail`, `read_facts_all_for_keepers_dir`, `read_all_facts`, `read_facts_all_strict(_for_keepers_dir)`, `read_facts_for_rewrite`.
- path/append: `ensure_dir`, `episodes_dir`, `tool_result(s)_dir`, `episode_path`, `generation_counter_path`, `unique_episode_path`, `read_generation_counter`, `append_line`/`append_json`/`append_fact`(raw open_out_gen, **Fs_compat 미경유**), `keepers_dir`, `list_fact_store_keeper_ids(_for_base_path)`, `episode_bundle_lock_path`.

**LOCK_MIXED (15, whole-body wrap 금지 — poison)** — `File_lock_eio.with_lock`(→`Eio.Mutex.use_rw`) 또는 `write_file_atomically`→`Fs_compat.save_file(_atomic)`→**`Eio.Path.save`**(production `global_fs` set 시 Eio effect) 사용:
- `with_facts_lock`, `with_episode_bundle_lock`, `next_generation(_with_floor)`, `append_episode`, `append_episode_bundle`, `write_file_atomically`, `rewrite_facts_atomically(_for_keepers_dir/_for_base_path)`, `cap_facts`, `cap_events`, `merge_and_cap_facts`, `save_tool_result`, `For_testing.with_keepers_dir`.
- 이들은 **lock/Fs_compat write는 main 유지**, lock 내부의 순수 read/parse 구간만 오프로드(phase 2).

**핵심 mitigation (domain-safety)**: `keepers_dir()`→`Config_dir_resolver.resolve()`가 plain(non-atomic) ref memo `cached_resolution`를 first-touch 채움. worker-domain closure가 그 첫 write를 하면 main-domain fiber와 data race가 생긴다. 따라서 ambient 진입점은 **`keepers_dir()`를 main에서 먼저 resolve**한 뒤 `_for_keepers_dir` 변형(순수 seam)을 오프로드. `_for_keepers_dir`/`_for_base_path` 변형은 keepers_dir을 인자로 받아 memo 미접촉 = clean seam.

(전체 69행 판정·why_safe·poison_if_wrapped: workflow `wf_ef7cea25-9f1` 산출물.)

## 6. 마이그레이션 (단계)

프로파일 hot 경로 우선(각 단계 독립 PR, behavior-preserving):

1. **읽기/스캔 hot path**(PURE 확정분): `read_facts_all`/`read_*_tail`, `list_fact_store_keeper_ids_*`, `cap_episode_files`의 readdir+stat 스캔 → `Domain_pool_ref.submit_io_or_inline` 오프로드.
2. **쓰기/cap path**(LOCK_MIXED): lock은 main 유지, lock 내부의 read/parse/write/rename 순수 구간만 오프로드.
3. **빈도 감소**(2축) + **메트릭**(3축).

각 단계는 분류 테이블의 PURE/LOCK_MIXED 판정을 따른다. 저confidence 함수는 단계에서 제외하고 재분석.

## 7. 테스트

- **드리프트/회귀 가드**: 오프로드로 감싼 각 body가 Eio op / shared lock / module-level mutable first-touch를 포함하지 않음을 보장. LOCK_MIXED를 통째로 `Domain_pool_ref.submit_io_or_inline`에 넣는 테스트는 실패해야 한다.
- **behavior-preserving**: 오프로드는 실행 위치만 바꾸고 결과 불변 — 기존 keeper_memory_os_io 테스트(atomic write/CAS/tail read/cap)가 그대로 green이어야 함.
- **fallback**: `Domain_pool_ref.submit_io_or_inline`은 풀 미설치 시 직접 실행 → 기존 non-Eio 테스트 무영향.
- **liveness(선택)**: 다수 keeper 동시 사이클에서 main-domain 점유 감소를 메트릭으로 관측.

## 8. 대안 / 트레이드오프

- **(기각) Eio.Path 전면 전환**: 모든 함수 시그니처에 `~fs`(`Eio.Path.t`) 스레딩 필요 → 전 caller 전파, 대규모 blast. 이득(io_uring 진짜 async) 대비 위험·범위 과다. 현 목표(스케줄러 비점유)는 domain-pool offload로 충분.
- **LOCK_MIXED 통째 오프로드**: lock+I/O 전체를 worker domain으로 옮기려면 `File_lock_eio`/`Fs_compat`/Eio effect 소유권을 함께 재설계해야 한다. 본 RFC는 lock을 main에 두고 순수 I/O 하위 구간만 domain pool로 빼는 최소 접근을 우선한다.
- **domain-pool 제출 오버헤드**: 호출당 제출 비용. 2축(빈도 감소)으로 호출 수를 줄여 상쇄.

## 9. 범위 / 경계

- RFC-gated subsystem(credential/operator/sandbox/dashboard-credential/hooks/workflow) **아님**. 단 keeper 메모리 I/O 경로 전반이라 본 RFC로 scope.
- workaround 아님: 레거시 blocking I/O를 검증된 오프로드 primitive로 교체(숙청). band-aid/telemetry-as-fix/string-match 무관.
