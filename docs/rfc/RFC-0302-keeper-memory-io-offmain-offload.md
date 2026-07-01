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
- **§5 분류(PURE 37/LOCK_MIXED 15/NO_IO 16)는 여전히 유효**: "read-only·shared-state 없음"이 도메인 풀 오프로드의 안전 기준과 정확히 일치(PURE = 넘길 수 있음, LOCK_MIXED = 락/Fs_compat 때문에 통째로는 불가). §4.1/§5의 `run_in_systhread` 언급은 `Domain_pool_ref.submit_io_or_inline`으로 읽는다.

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

### 4.1 1축 — 순수 blocking I/O를 systhread로 오프로드 (primary)

**기존 선례 재사용**(신규 메커니즘 도입 안 함): `auth_credential_base.ml`이 이미 동일 문제를 이렇게 푼다 —

```ocaml
let run_blocking_io f = Eio_guard.run_in_systhread f
let file_exists path = run_blocking_io (fun () -> Sys.file_exists path)
let read_dir path = run_blocking_io (fun () -> Sys.readdir path)
(* read_dir + N×JSON parse 를 한 번의 run_blocking_io 로 묶음 *)
```

`Eio_guard.run_in_systhread`(eio_guard.ml:55)는 Eio 활성 시 `Eio_unix.run_in_systhread`로 body를 시스템 스레드에서 실행(→ main 스케줄러 비점유, 다른 fiber 진행), 비활성(module-init/테스트) 시 직접 실행. keeper_memory_os_io에 동일 `run_blocking_io`를 도입하고 **순수-blocking file I/O를 감싼다**.

### 4.2 2축 — 빈도/알고리즘 감소 (secondary)

오프로드는 스케줄러를 살리지만 systhread 제출 오버헤드가 호출당 발생한다. 따라서 호출 수 자체를 줄인다: 같은 dir을 turn마다 재스캔하는 중복 `readdir` 제거, 재-`stat` 제거, recall/skill 결과를 파일 mtime 기반 캐시로 무효화. (별도 후속 PR 가능.)

### 4.3 3축 — 관측 (guard)

메모리 I/O 경로에 latency/호출수 메트릭(Turn당 readdir/stat/read 카운트, systhread 제출 수)을 추가해 회귀 감시. "모든건 관측됨" 원칙 정합.

## 5. 안전 분석 (CRITICAL) — PURE vs LOCK_MIXED 분류

**최대 리스크**: `Eio_guard.run_in_systhread`의 body는 **순수 blocking C/Unix/Stdlib만** 허용된다. 시스템 스레드는 Eio effect handler가 **없어서**, body 안의 Eio 연산(`Eio.Mutex.use_rw/ro`, `Eio.Switch`, `Eio.Fiber`, `Eio.Time`, `File_lock_eio` flock, `Eio_guard.with_mutex/protect`, 그 밖의 effect)은 `Effect.Unhandled`를 던지고 **감싸는 mutex를 poison**시킨다 → **정확히 2026-06-19 keeper stall**(process-shared `dir_mu` poison). 즉 잘못된 오프로드는 HOL을 고치려다 **더 심한 stall을 재유발**한다.

그러므로 각 함수를 분류한다:

- **PURE_BLOCKING**: 전체 body(+ 모든 transitive helper)가 Stdlib/Sys/Unix 파일 op + Yojson 파싱 + 순수 계산만. Eio op 0 → **body 전체를 `run_blocking_io`로 감싸도 안전**.
- **LOCK_MIXED**: Eio lock(`with_facts_lock`/`with_episode_bundle_lock`/`File_lock_eio`/`Eio.Mutex`)·clock·yield 등 Eio effect를 body 어딘가에서 수행 → **Eio 부분은 main 도메인 유지**, lock 획득/해제 사이의 **순수 file-I/O 하위 구간만** 오프로드.
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

**핵심 mitigation (poison 아님, domain-safety)**: `keepers_dir()`→`Config_dir_resolver.resolve()`가 plain(non-atomic) ref memo `cached_resolution`를 first-touch 채움. systhread offload가 그 첫 write를 하면 main-domain 다른 fiber와 **benign data race**(idempotent, poison 아님). 따라서 ambient 진입점은 **`keepers_dir()`를 main에서 먼저 resolve**한 뒤 `_for_keepers_dir` 변형(순수 seam)을 오프로드. `_for_keepers_dir`/`_for_base_path` 변형은 keepers_dir을 인자로 받아 memo 미접촉 = clean seam.

(전체 69행 판정·why_safe·poison_if_wrapped: workflow `wf_ef7cea25-9f1` 산출물.)
| _(workflow 완료 후 기입)_ | | | |

## 6. 마이그레이션 (단계)

프로파일 hot 경로 우선(각 단계 독립 PR, behavior-preserving):

1. **읽기/스캔 hot path**(PURE 확정분): `read_facts_all`/`read_*_tail`, `list_fact_store_keeper_ids_*`, `cap_episode_files`의 readdir+stat 스캔 → `run_blocking_io` 오프로드.
2. **쓰기/cap path**(LOCK_MIXED): lock은 main 유지, lock 내부의 read/parse/write/rename 순수 구간만 오프로드.
3. **빈도 감소**(2축) + **메트릭**(3축).

각 단계는 분류 테이블의 PURE/LOCK_MIXED 판정을 따른다. 저confidence 함수는 단계에서 제외하고 재분석.

## 7. 테스트

- **드리프트/회귀 가드**: 오프로드로 감싼 각 body가 Eio op를 포함하지 않음을 보장 — `run_blocking_io` 헬퍼는 systhread 경로에서 `Effect.Unhandled`를 named `Failure`로 변환(eio_guard 기존 방어)하므로, LOCK_MIXED를 잘못 감싸면 테스트에서 즉시 실패.
- **behavior-preserving**: 오프로드는 실행 위치만 바꾸고 결과 불변 — 기존 keeper_memory_os_io 테스트(atomic write/CAS/tail read/cap)가 그대로 green이어야 함.
- **fallback**: `Eio_guard.run_in_systhread`는 Eio 비활성 시 직접 실행 → 기존 non-Eio 테스트 무영향.
- **liveness(선택)**: 다수 keeper 동시 사이클에서 main-domain 점유 감소를 메트릭으로 관측.

## 8. 대안 / 트레이드오프

- **(기각) Eio.Path 전면 전환**: 모든 함수 시그니처에 `~fs`(`Eio.Path.t`) 스레딩 필요 → 전 caller 전파, 대규모 blast. 이득(io_uring 진짜 async) 대비 위험·범위 과다. 현 목표(스케줄러 비점유)는 systhread 오프로드로 충분.
- **Executor_pool_ref.submit_or_inline**: Eio-touching 작업의 정공 오프로드(pool에 Eio handler 존재). LOCK_MIXED 함수의 lock+I/O를 통째로 오프로드하려면 이게 맞지만, 본 RFC는 lock을 main에 두고 순수 I/O만 systhread로 빼는 최소 접근을 우선(더 낮은 복잡도). 향후 필요 시 채택.
- **systhread 오버헤드**: 호출당 스레드 제출 비용. 2축(빈도 감소)으로 호출 수를 줄여 상쇄.

## 9. 범위 / 경계

- RFC-gated subsystem(credential/operator/sandbox/dashboard-credential/hooks/workflow) **아님**. 단 keeper 메모리 I/O 경로 전반이라 본 RFC로 scope.
- workaround 아님: 레거시 blocking I/O를 검증된 오프로드 primitive로 교체(숙청). band-aid/telemetry-as-fix/string-match 무관.
