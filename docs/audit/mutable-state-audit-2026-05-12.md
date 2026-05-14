# Mutable State Audit — 2026-05-12

목적: `lib/` 의 `mutable` 레코드 필드 / 모듈 전역 `ref` / 모듈 전역 `Hashtbl` 사용을 전수 분류하여,
mutable 이 잘못된 위치·모양으로 쓰여 혼란과 잠재 버그를 만드는 지점을 식별한다.
대규모 일괄 리팩터링이 아니라 (CLAUDE.md "Surgical Changes"), 명확한 고위험 항목만 별도 PR 로 수정하고
나머지는 이 문서가 후속 작업 백로그가 된다.

origin/main 기준 (`7ba2f79c0`, 2026-05-12).

## 0. 방법론 (재현 가능)

```bash
# mutable 필드 선언 총수 (prose 의 "mutable" 단어 제외 위해 ': ' 로 끝나는 것만)
rg --no-filename -o 'mutable [a-z_][A-Za-z0-9_'"'"']* *:' lib/ --type ml | wc -l
# 모듈 전역 ref (column-0 let X = ref ...)
rg -n '^let \w[A-Za-z0-9_]* *(:[^=]*)?= ref ' lib/ --type ml
# 모듈 전역 Hashtbl.create (column-0 let)
rg -n '^let .*Hashtbl.create' lib/ --type ml
# write-once-dead 후보: mutable 필드명 추출 후 'field <-' 쓰기 0건인 것
rg --no-filename -o 'mutable [a-z_][A-Za-z0-9_'"'"']* *:' lib/ --type ml | sed 's/mutable //; s/ *:.*//' | sort -u > /tmp/mut.txt
while read f; do c=$(rg -c "\.${f} *<-|\b${f} *<-" lib/ bin/ test/ --type ml | awk -F: '{s+=$2} END{print s+0}'); [ "$c" = 0 ] && echo "$f"; done < /tmp/mut.txt
```

## 1. 규모 (origin/main 7ba2f79c0)

| 항목 | 수 |
|------|----|
| `mutable` 필드 선언 (`: ` 형) | 259 (raw `rg -o 'mutable '` 카운트는 365 — 차이는 주석/문서 본문의 "mutable") |
| `mutable` 필드 보유 파일 | 95 |
| 모듈 전역 `ref` (`^let X = ref`) | 96 |
| `Hashtbl.create` 총 | 415 |
| 모듈 전역 `Hashtbl.create` (`^let`) | 110 |

mutable 필드 고밀도 sub-lib: `keeper`(69), `dashboard`(50), `gate`(35), `server`(26), `cascade`(18), `exec`(14), `cdal_runtime`(13), `activity_graph`(11), `pulse`(10).
대부분은 메트릭 누산기·캐시처럼 mutation 이 설계 의도인 경우이고, 단일 도메인 모듈 안에서 (또는 Mutex 보호 하에) 쓰인다.

**모범 사례 (그대로 둘 것 — 다른 곳의 템플릿):**
- `lib/agent_registry_eio.ml:42-66` — "3개의 분산된 mutable 전역을 단일 Mutex 보호 레코드로 통합". read-modify-write 를 `with_state_rw`/`with_state_ro` 단일 critical section 으로. mutable→record 정리의 표준 패턴.
- `lib/keeper/keeper_turn_slot.ml:107-128` — `holder_table_atomic : ... Atomic.t` (writers 는 `holder_mutex` 보유, readers 는 lock-free `Atomic.get`), `autonomous_wait_queue_*` 는 `autonomous_wait_queue_mutex` 보호. lock 규율이 주석으로 명시됨.
- `lib/discovery_cache.ml:11-31` — Eio capability 는 `Atomic.t` (init 시 1회 set), 캐시는 `cache_mu` 보호, HTTP probe 는 lock 밖에서 실행 (drift-class 주석 포함). `cached_endpoints : ... list ref` + `cache_updated_at : float Atomic.t` 가 한 논리적 캐시 엔트리인 점은 사소한 shape 흠 (저위험).

## 2. 버킷 분류

### 버킷 A — Lock 규율 위반 (실제 버그성) — **수정 대상**

| 위치 | 문제 |
|------|------|
| `lib/board_votes.ml:1032-1055` `get_all_karma` | `store.karma_cache` 를 `with_lock` **밖**에서 읽고(1034), `with_lock` 안에서 재구축, 재구축 결과를 `with_lock` **밖**에서 `store.karma_cache <- Some result` 로 쓴다(1054). 같은 필드를 `lib/board_core.ml:66-72` `invalidate_post_caches`/`invalidate_comment_caches` 가 `<- None` 으로 무효화 (이들은 lock 미보유 bare 함수지만 모든 호출 사이트가 `with_lock` 안 — caller-holds-lock 헬퍼). 결과: 캐시 read/write 가 invalidate 와 다른 lock 상태에서 일어남 → torn cache (무효화 직후 stale 값을 다시 캐시할 창) + 동시 fiber 가 모두 `None` 보면 중복 재구축. **참고**: `with_lock` = `Board_core.with_lock` = `Eio.Mutex.use_rw ~protect:true store.mutex` (board_votes.ml:6 `module Mutex = Stdlib.Mutex` 는 파일 상단 stdlib 별칭 묶음 중 하나로 *미사용*; Stdlib.Mutex-in-Eio 이슈 아님). |

대조군 (정상): `lib/board_core.ml:848-867` `list_posts` 는 `sorted_posts_cache` 의 read 와 write 가 둘 다 `with_lock` 블록(850-867) 안에 있음. `get_all_karma` 만 패턴이 어긋남.

→ 수정: `get_all_karma` 의 cache read-check / rebuild / write 를 하나의 `with_lock store` 블록으로 묶는다. 추가로 `lib/board_core.mli` 의 `invalidate_*` doc 주석에 "caller must hold `store.mutex`" 명시 (선택, 같은 PR). 패턴: `agent_registry_eio.ml`.

### 버킷 B — Shape 문제 (Mutex 보호되지만 invariant 가 타입에 없음) — **백로그 (이번 범위 밖)**

| 위치 | 문제 |
|------|------|
| `lib/cascade/cascade_client_capacity_history.ml:53-57` | 링버퍼가 `cap_ref`/`buf`/`head`/`count` 4개의 모듈 전역 `ref` 로 분산. invariant 는 주석(43-51)으로만 유지. `with_lock`(Stdlib.Mutex, 순수 non-yielding 구간이라 OK) 보호됨. → 4개가 함께 움직여야 한다는 사실이 구조에 없음. `agent_registry_eio.ml` 패턴으로 단일 record 화 시 invariant 가 구성상 원자적이 됨. |
| `lib/board_types/board_types.ml:287-299` | `last_sweep`/`karma_cache`/`sorted_posts_cache`/`dirty_posts`/`dirty_comments`/`last_flush` 6개 mutable 필드가 캐시·dirty-flag 협조 상태. `board_core.ml`/`board_votes.ml` 양쪽에서 변경. lock 규율은 (버킷 A 수정 후) 일관됨. dirty-flag + dirty-id-Hashtbl 쌍이 함께 움직여야 하는 점은 잠재 흠. |
| `lib/heuristic_metrics.ml:165-167` | `flush_interval_sec_ref`(설정값) + `last_flush_ref`(런타임 상태) + `uninitialized_record_warned_ref`(WARN dedup) 이 한 곳에 섞임. 설정과 상태 미분리. |

### 버킷 C — Mutable 레코드 bag (다수 mutable 필드, 부분 업데이트로 일관성 깨질 위험) — **백로그 / 일부 RFC 후보**

| 위치 | 비고 |
|------|------|
| `lib/thompson_sampling.ml:18-39` `agent_stats` | 13 mutable 필드 + 모듈 전역 `stats_table`/`pending_votes` Hashtbl(`:60,63`). **`ts_mu` Eio.Mutex 로 보호됨 — 동작 버그 없음.** 흠: 13개 필드 직접 mutation 시 `updated_at` 등 누락하면 일관성 깨짐 (단일 `update` 헬퍼 강제 또는 immutable+functional update 로 전환 가능 — 큰 변경, 별도 RFC). 이번 작업 손대지 않음 (감사 기록만). |
| `lib/gate/channel_gate_metrics.ml` | mutable 필드 34개 (lib 내 최다). 메트릭 누산기 — mutation 자체는 설계 의도일 가능성 높음. 파일별 triage 필요. |
| `lib/dashboard/dashboard_governance_judge.ml` (18), `lib/dashboard/dashboard_http_keeper_metrics.ml` (17), `lib/keeper/keeper_run_tools.ml` (14), `lib/cascade/cascade_health_tracker.ml` (13) | 동일 — 대부분 메트릭/판정 누산기. 단 `keeper_run_tools.ml` 의 4개 필드는 버킷 D (write-once) 로 분류됨. |

### 버킷 D — Write-once / dead `mutable` (생성 후 `<- ` 재대입 0건 → `mutable` 불필요)

검출: `field <-` 쓰기가 `lib/` + `bin/` + `test/` 전체에서 0건인 mutable 필드.

**D1 — 패턴이 깨끗해 안전히 제거 가능 (Phase 2 에서 실제 제거 + 컴파일 검증 완료):**

| 필드 | 선언 위치 | 비고 |
|------|----------|------|
| `channel` | `lib/fs_compat/fs_compat.ml:167` `Append_fd_cache.entry` | Hashtbl 의 entry 자체는 교체되지만 `channel` 필드 자체 재대입 없음. peer `last_used` 는 mutable+written. |
| `subscriptions` | `lib/streamable_http.ml:18` (`.mli:21`) | session 레코드. `subscriptions = []` 초기화만. peer `last_seen` 는 `[@atomic]` mutable. |
| `table` | `lib/exec/exec_cache.ml:16` | Hashtbl *내용*은 `Hashtbl.replace/clear/remove t.table` 로 변경되지만 `table` *필드* (Hashtbl handle) 재대입 없음 — OCaml mutable 의 흔한 혼동: `mutable` 은 슬롯 재대입만 허용. |

**D2 — Single mutable accumulator 패턴 안의 일부 필드 (백로그, 손대지 않음):**

다음 6개는 grep 으로 `<- ` 0건이지만 *명시적으로 "single mutable record" 로 설계된* 레코드의 일부 필드다 (doc 주석 인용). 4개 중 일부만 immutable 로 바꾸면 레코드의 의도된 대칭성이 깨진다. 이 레코드들 자체가 단일 record 로 재구성 (functional update) 되는 RFC 가 있을 때만 같이 처리:

| 필드 | 선언 위치 | 같은 레코드의 의도 |
|------|----------|--------------------|
| `discovered` `tool_calls` `tool_overlay` `tool_surface` | `lib/keeper/keeper_run_tools.ml:19,24-26` | `hook_accumulator` — doc 주석: "they write into this single mutable record during Agent.run execution". 12 필드 중 4 개만 비변경. |
| `provider_snapshot` | `lib/cdal_runtime/proof_capture.ml:35` | `.mli:12` doc: "Opaque mutable accumulator. One per agent run, not shared." |
| `review_warning` | `lib/cdal_runtime/mode_enforcer.ml:124` | peer `violations`/`token_snapshots`/`effect_evidence` 가 mutable. |

**D3 — False positive (line-based grep miss):**

| 필드 | 선언 위치 | 비고 |
|------|----------|------|
| `trace_completed` | `lib/server/server_dashboard_http_core.ml:1187` | grep 으로 0건이었으나 Phase 2 컴파일에서 `lib/server/server_dashboard_http_core.ml:1257-1261` 의 `trace.trace_completed\n    <- ...` (multi-line `<-`) 발각. mutable 유지. → 향후 line-based grep 결과는 **반드시 컴파일러로 최종 확정** (D1 의 3개도 같은 절차로 검증함). |

**검출 한계 메모**: `rg` 는 라인 기반이라 `expr.field` 와 `<- value` 가 서로 다른 줄에 걸친 OCaml 패턴 (긴 우변, formatter 가 줄바꿈) 을 못 잡는다. Phase 2 의 실제 결정 절차 = "grep 후보 → `mutable` 제거 → `dune build @check` → 에러나면 false positive 로 분류". D3 의 `trace_completed` 가 이 절차로 정확히 걸러졌다.

### 버킷 E — 범위 밖 (이미 별도 RFC/audit 대상) — **건드리지 않음**

| 위치 | 사유 |
|------|------|
| `lib/core/safe_ops.ml:69-92` | UTF-8 repair 카운터/dedup mutable (`utf8_repaired_reads`/`utf8_repaired_bytes`/`utf8_repair_path_samples` ref + `utf8_repair_log_seen` Hashtbl). telemetry-as-fix 워크어라운드 패턴 — CLAUDE.md §워크어라운드 거부 기준. 별도 RFC 로 흡수. |
| `lib/prometheus.ml` 중앙 `metrics : (string, metric) Hashtbl.t` (`:77` 부근) | godfile — `docs/audit/godfile-inventory-2026-05-12.md` + 별도 RFC. metric 소유권 분산이 근본 해결. |
| `lib/keeper/credential_*`, `lib/repo_manager/`, `lib/operator/operator_control*` | CLAUDE.md `<agent_delegation>` RFC-gate 대상. 이번 작업 대상 파일 (`board_*`, `cascade_*`, `thompson_sampling`, `heuristic_metrics`, `keeper_run_tools`, `exec_cache`, `fs_compat`, `streamable_http`, `cdal_runtime/*`, `server_dashboard_http_core`) 은 gate 목록 밖. push 전 `bash ~/me/scripts/pr-rfc-check.sh` 재확인. |

## 3. 모듈 전역 `ref` (96개) — 분류

대다수는 다음 중 하나:
- **init guard** (`let initialized = ref false` — `lib/multimodal/workspace_id.ml:22`, `lib/shared_types/artifact_id.ml:3`, `lib/shared_audit/envelope.ml`, `lib/server_base_path_diagnostics.ml:153` 등): 정당. idempotent 초기화 1회 가드.
- **lazy-init store handle** (`let store_ref : Dated_jsonl.t option ref = ref None` — `lib/tool_metrics_persist.ml:74`, `lib/eval_calibration.ml:100`, `lib/tool_usage_log.ml:42`, `lib/discovery_history.ml:11`, `lib/agent_stress.ml:253` 등): 서버 init 시 1회 set, 이후 읽기. 대부분 전용 Mutex 또는 `Stdlib.Mutex.protect` 로 보호됨 (예: `lib/tool_shard.ml:1837` `agent_shards_mutex`, `lib/agent_sdk_metrics_bridge.ml:37` `registry_mutex`). 해당 모듈은 "no Eio context" 주석으로 Stdlib.Mutex 선택 근거 명시 — 정당.
- **dedup / "logged once" 상태** (`lib/config_dir_resolver.ml:537,554` `last_logged_*_signature`, `lib/prometheus.ml:334` `backend_mutex_observers_installed`): 로그 노이즈 억제 — 동작에 영향 없으나 mutable 전역.

이미 식별된 위험/흠 (버킷 A/B 와 중복): `lib/heuristic_metrics.ml:165-167` (설정·상태 혼재), `lib/cascade/cascade_client_capacity_history.ml:53-56` (4-ref 링버퍼). `lib/core/safe_ops.ml:69-71` 는 버킷 E.

전체 목록은 위 §0 의 `rg -n '^let \w...= ref '` 명령으로 재생성. 개별 96개를 여기 나열하지 않음 — 추가 위험은 발견되지 않았다.

## 4. 기존 `adversarial_eval.ml` Stdlib.Mutex 린트 — 보정 제안

`lib/cdal/adversarial_eval.ml:235-241` `unsafe_patterns` 에 `("Stdlib.Mutex", "non-Eio mutex in concurrent code")` 규칙이 이미 있다. 현재 이 패턴은:
- 파일 상단 stdlib 별칭 묶음의 `module Mutex = Stdlib.Mutex` (~20개 파일, 대부분 *미사용* 별칭) 을 전부 잡는다 → false positive 다발.
- `tool_shard.ml:1830`, `agent_sdk_metrics_bridge.ml:4`, `relay.ml:63` 처럼 "no Eio context" 주석으로 근거가 명시된 정당한 사용도 잡는다.

→ 제안 (Phase 3 후보, 사용자 sign-off 후):
1. `module Mutex = Stdlib.Mutex` 단순 별칭 라인은 제외하고, 실제 `Stdlib.Mutex.lock`/`.protect` *호출* 만 플래그.
2. 또는 근거 주석 (`Stdlib.Mutex:` 로 시작하는 인접 주석) 이 있으면 severity 를 info 로 강등.
3. 진짜 위험 = "Stdlib.Mutex 를 잡은 채로 Eio yield 지점 (`Eio.*`, `Fiber.*`, I/O) 호출" — 이건 정적으로 잡기 어려우니, 최소한 1·2 로 노이즈만 줄여도 신호 대 잡음비가 개선됨.

## 5. 추천 후속 수정

| Phase | 항목 | 범위 |
|-------|------|------|
| 1 | `board_votes.ml get_all_karma` DCL 수정 + 회귀 테스트 (완료) | ~15-25 LOC + 53 LOC 테스트 |
| 2 | 버킷 D1 의 write-once `mutable` 3개 제거 (`.mli` 동기, 컴파일 검증 완료) | ~6 LOC, 동작 변경 없음 |
| 3 (선택, sign-off 후) | `adversarial_eval.ml` Stdlib.Mutex 린트 보정 **또는** 버킷 B 중 1건 (예: `cascade_client_capacity_history.ml` 4-ref→1 record) | 1건만 |

백로그로 남기는 것 (이 작업에서 안 함): 버킷 B 의 나머지, 버킷 C 전체 (thompson_sampling 포함), 버킷 E (별도 RFC).
