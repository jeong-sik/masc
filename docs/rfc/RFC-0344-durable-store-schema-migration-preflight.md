# RFC-0344 — Durable store schema-version migration & boot preflight

- Status: Draft
- Updated: 2026-07-19
- Author: vincent (drafted by Claude Opus 4.8)
- Related: RFC-0338 (lane-per-keeper persistence isolation — explicitly scopes out "데이터 파일 migration은 없다"), RFC-0341 (keeper lifecycle projection SSOT), RFC-0000 §Law 4 (HARD CUT), keeper-product-performance-goal-2026-07-17 #1 (event queue v2→v3 one-shot migration & deploy preflight)
- Supersedes: none
- Tracking: #25287

## 0. Summary

여러 durable store가 on-disk schema version(namespace / generation / schema 문자열)을 올릴 때, **디스크에 있는 라이브 state의 실제 version을 boot 시점에 확인하는 공용 경로가 없다**. 각 store가 개별적으로 "old shape을 거부(hard-cut)" 또는 "새 generation으로 경로 분리" 또는 "compatibility read 추가"를 그때그때 손으로 결정한다. hard-cut을 고르면 배포 순간 구 데이터가 orphan 되거나 fleet이 boot을 거부한다.

이 RFC는 세 가지를 도입한다: (1) 각 durable store가 `{path; current_version; migrate}`를 선언하는 **descriptor SSOT**, (2) boot 전에 모든 store의 on-disk version을 current와 대조해 불일치 시 migration 실행 또는 operator-facing fail-loud를 강제하는 **preflight gate**, (3) version을 store 타입에 결속해 version bump 시 migration path 미제공이면 **컴파일 타임에 실패**하게 만드는 phantom-type 결속.

runtime에 영구 backward reader를 다시 넣는 방식이 **아니다**(keeper-product-performance-goal #1의 명시적 non-goal). runtime은 current version만 읽고, 구 version 처리는 boot preflight의 one-shot migration으로 격리한다.

## 1. Problem (evidence)

durable store schema version bump이 배포 경계에서 데이터 유실 또는 boot 거부를 유발한 사고가 2026-07 한 달에만 4회 반복됐다:

| 이슈 | store | version 변경 | 처리 | 결과 |
|------|-------|-------------|------|------|
| #25078 | event queue | v2→v3 | hard-cut, 라이브 migration 없이 배포 | 16/16 keeper boot 거부 |
| #25197 | reaction ledger | same-generation(v3) | hard-cut | 배포 경계 livelock (v4 bump로 우회) |
| #25231 | fusion terminal codec | shape 변경 | hard-cut | 구 `{ok,resolved_answer}` 행 디코드 불가 (compat read로 우회) |
| #25135 (OPEN) | gate approval order | v2→v3 | hard-cut | 라이브 `<base-path>/.masc/gate/pending.json`(version=2, 367 durable HITL 레코드) exact-reject → store Unavailable → HITL Gate silent outage |

공통 근본: 각 store가 version bump 시 (a) migration 도구 또는 (b) generation-bump(경로 분리) 중 하나를 **타입 수준에서 강제받지 않는다**. 현재는 주석(`keeper_reaction_ledger.ml`의 "namespace and row schema advance together")으로만 규율되고 컴파일러가 미강제 → 매번 hand-decision, 매번 라이브 state 확인 누락.

**이 4건은 표층이다.** 전수 인벤토리(§현황)는 durable store 약 21개 중 **16개가 위험**임을 보인다 — hard-cut-reject 7개(구 데이터 orphan/store Unavailable), unversioned 9개(암묵적 hard-cut). 리포 전체에 **durable state의 구→신 변환을 책임지는 공용 preflight 경로가 없고**, 존재하는 startup 변환은 store별 ad-hoc이라 재사용·검증되지 않으며 boot 시점 버전 대조와 결속되지 않는다. event queue는 오히려 migration을 명시적으로 거부한다(`keeper_event_queue_state.ml:228` "cannot migrate legacy inflight work"). 즉 다음 version bump가 어느 store에서 일어나도 5번째 사고가 된다.

RFC-0338은 durable persistence를 다루면서도 "데이터 파일 migration은 없다"(본문 §rollback)고 scope에서 명시적으로 제외한다. 즉 개별 durability RFC들은 각자 "내 변경엔 migration 불요"를 판단할 뿐, **"durable store 전반의 version bump 안전성"을 책임지는 RFC가 구조적으로 없다**. 이 공백이 위 4건이 반복되는 이유다.

## 2. Non-goals

- runtime에 영구 backward-compatibility reader를 넣지 않는다. runtime은 current version만 읽는다(keeper-product-performance-goal #1 원칙 (1)).
- store별 persistence 로직을 하나로 통일하지 않는다. 각 store는 여전히 자신의 shape을 소유하되, version 대조·migration은 공용 인프라를 경유한다.
- 이미 배포된 구 데이터를 삭제 후 재시작하는 경로를 표준화하지 않는다(#1 원칙 (2): "queue 파일을 삭제하고 재시작하지 않는다").
- old runtime이 쓰는 중에 일괄 rewrite하지 않는다(#1 원칙 (3)). preflight는 boot 전 단일 프로세스 시점에만 실행.

## 3. Design

### 3.1 Durable store descriptor (SSOT)

각 durable store가 다음을 선언한다:

```ocaml
type on_disk_state =
  | Absent                          (* 파일 없음 = fresh install *)
  | Unversioned_legacy              (* 파일은 있으나 version 필드 도입 이전(pre-versioning) *)
  | Present of Store_version.t      (* 명시 version (미인식 값은 Present (Unknown s)) *)

type 'row descriptor = {
  name : string;                              (* 진단·로그용 식별자 *)
  instances : unit -> Eio.Fs.dir_ty Eio.Path.t list;
    (* 정적 store는 단일 경로 [p]; per-keeper 등 동적 store는 base dir를
       열거해 전 인스턴스 반환(event queue = keeper당 1파일). 단일 path로는
       동적 store를 놓치므로 열거를 descriptor 계약에 둔다. *)
  current_version : Store_version.t;          (* 이 바이너리가 쓰는 version *)
  read_on_disk_state : Eio.Fs.dir_ty Eio.Path.t -> on_disk_state;
    (* append-only(memory_bank.jsonl 등)는 행별 version이 섞일 수 있어
       파일 내 최저 행 version을 Present로 보고한다(전 행 current면 up-to-date). *)
  migrate : from_:Store_version.t -> Eio.Fs.dir_ty Eio.Path.t
            -> (unit, Migration_error.t) result;
    (* from_ 미만 → current_version 변환. atomic. 대상 경로를 인자로 받아
       동적 store의 각 인스턴스에 적용된다. *)
}
```

`Store_version.t`는 자유 문자열이 아니라 store별 closed variant(예: `Gate_v1 | Gate_v2 | Gate_v3`)로, 알 수 없는 on-disk 값은 `Unknown of string`으로 파싱해 hard-fail 경로로 보낸다(permissive default 금지, CLAUDE.md 안티패턴 #2).

**세 상태를 분리하는 이유**: `option` 하나는 "파일 없음(fresh)"과 "파일은 있으나 version 필드 이전(§현황 위험 B의 unversioned 9개 store, 라이브 데이터 보유)"을 둘 다 `None`으로 뭉갠다 → 구 데이터를 fresh로 오인해 무시/덮어쓸 수 있다. `Unversioned_legacy`를 별도 상태로 두어 legacy 파일을 "최초 version에서 migrate 대상"으로(fresh 아님) 명시한다(Parse, don't validate).

### 3.2 Boot preflight gate

boot 시퀀스에서 keeper 시작 **전에**, base-path 배타 락(§3.2.1) 획득 후 실행:

```
for each registered descriptor d:
  for each path p in d.instances ():         (* 동적 store 전 인스턴스 *)
    match d.read_on_disk_state p with
    | Absent                -> ok (fresh install)
    | Present (Unknown s)   -> fatal "unrecognized version: %s" s   (* 비교보다 먼저 *)
    | Unversioned_legacy    -> backup p; d.migrate ~from_:v0 p      (* legacy=최초 version, fresh 아님 *)
    | Present v ->
        match Store_version.compare v d.current_version with        (* total; polymorphic (<) 금지 *)
        | Eq -> ok (up to date)
        | Lt -> backup p; d.migrate ~from_:v p    (* 성공 시 on-disk = current_version *)
        | Gt -> fatal "downgrade: binary older than data"
```

두 가지가 순서/전역성에 걸린다. (1) `Present (Unknown s)`를 `<`/`>` 비교보다 **먼저** 매칭한다 — OCaml 다형 비교(`(<)`)는 `Unknown`을 임의 순서로 정렬해 미인식 version이 migrate/downgrade 경로로 조용히 새기 때문(Silent Failure 방지). (2) 비교는 store별 **total `Store_version.compare`**로만 하고 다형 `(<)`를 쓰지 않는다.

migration 실패 또는 fatal은 **operator-facing 명시적 종료**로 처리한다(silent Unavailable 금지). #25135의 실패 모드(store Unavailable → 조용한 HITL outage)를 boot 시점 fail-loud로 전환한다.

**store 간 원자성**: 위 루프가 store를 하나씩 즉시 commit하면, store A가 새 version으로 rewrite된 뒤 store B의 migration이 실패했을 때 A(new)·B(old)의 부분 마이그레이션 상태로 남아 다음 boot이 불일치를 마주한다. 각 `migrate`는 §3.4처럼 backup을 남기고 **재실행에 멱등**(구 version이면 다시 변환, 이미 current면 no-op)이어야 하며, preflight는 실패 시 fatal로 멈춰 **다음 boot이 남은 store를 이어서 완료**할 수 있게 한다(commit된 store는 current라 재-migrate 대상 아님). 즉 부분 진행이 손실이 아니라 재개 가능한 상태가 되도록, `migrate`의 멱등성과 backup을 §4 acceptance에서 검증한다.

### 3.2.1 배타 락으로 구 프로세스 quiesce

preflight를 "새 프로세스의 boot 전"에만 두는 것으로는 부족하다 — 같은 base-path를 공유하는 **구 프로세스가 아직 쓰는 중**이면 preflight의 backup·rewrite가 라이브 write와 경합한다(§2 non-goal "old runtime이 쓰는 중 rewrite 금지"의 실제 강제 수단 부재). preflight 진입 시 `<base-path>/.masc/preflight.lock`에 대한 **배타 flock**을 획득하고, 실패하면(구 프로세스 잔존) migrate하지 않고 fatal로 종료한다. 락 보유 중에만 migration을 수행하고, keeper 시작까지 유지한다.

**첫 배포의 한계**: 이 락은 락을 아는 바이너리끼리만 quiesce를 보장한다. 이 메커니즘을 **처음 도입하는 배포**에서는 구 바이너리가 락을 잡지 않으므로 새 프로세스의 flock 획득이 성공해도 구 프로세스가 여전히 쓰고 있을 수 있다. 따라서 락은 정상 상태(락-aware ↔ 락-aware) 전환만 보호하고, **락을 처음 들이는 배포는 구 프로세스 종료를 배포 오케스트레이션 수준에서 보장하는 stop-the-world 단계**(구 프로세스 drain/stop 후 새 프로세스 start)로 처리해야 한다. 이 1회 조건을 §4 acceptance에 명시한다.

### 3.3 Version–store 타입 결속 (phantom type)

`current_version`을 store 모듈의 타입 파라미터로 결속해, version constructor를 추가(bump)하면 `migrate`의 exhaustive match가 새 arm을 요구하도록 만든다. 즉 version을 올리면서 migration 경로를 제공하지 않으면 **컴파일이 실패**한다. 주석 규율을 컴파일러 규율로 대체한다(CLAUDE.md FSM sparse-match 안티패턴 #4의 적용).

exhaustive match만으로는 부족하다 — 새 arm이 **어느 version으로 착지하는지**는 강제되지 않아, `Gate_v4` 추가 후에도 `Gate_v2 → Gate_v3`(중간 version) migration이 exhaustive를 만족하며 통과할 수 있다. 따라서 `migrate`의 결과 타입에 target을 phantom으로 결속한다: `migrate : from_:'from -> path -> ('current, Migration_error.t) result`에서 `'current`는 descriptor의 `current_version`과 같은 phantom 파라미터로 묶여, current 아닌 version으로 착지하는 migration은 **타입 에러**가 된다(exhaustiveness가 아니라 target identity를 컴파일러가 강제).

### 3.4 One-shot migration primitive

`migrate` 구현이 공유하는 무손실 절차:

```
v_old = load raw (v_old parser)
rows  = transform v_old → v_new
validate rows (row-count / integrity invariant vs v_old; 손실 감지 시 fatal, replace 금지)
backup original → path.bak.<from> → fsync(backup 파일 + 그 parent dir)
write temp → fsync(temp) → atomic rename over path → fsync(parent dir)
```

`rename` 후 **parent 디렉토리를 fsync**한다 — temp 파일 payload만 fsync하고 rename하면 디렉토리 엔트리 자체가 crash-durable하지 않아, preflight가 성공을 보고한 뒤 전원 손실 시 새 파일이 사라질 수 있다(POSIX 내구성).

**SQLite store는 이 raw-file 절차를 쓰지 않는다.** chat queue(`chat-queue.sqlite3`)는 `-wal`/`-journal`/`-shm` 사이드카를 동반해, 라이브 DB 파일의 단순 copy·temp-rename은 DB를 손상시킨다. descriptor에 store class(`Raw_file | Sqlite`)를 표기해, SQLite는 backup·변환을 SQLite backup API(`VACUUM INTO` 또는 online backup)로 수행하는 별도 primitive로 분기한다. 기존 부분 선례(#25197 generation-bump, #25231 compat read)를 raw-file primitive로 수렴한다.

## 4. Acceptance

- **TLA+ bug model** (`specs/bug-models/DurableStoreSchemaMigration.tla`, TLC v1.8.0 검증): 실제 관측된 두 실패 모드를 모두 모델링한다 — `HardCutAbsorb`(drop-on-mismatch: 파일까지 rewrite해 row 소실, §현황 위험 C 메모리 뱅크) + `HardCutOrphan`(hard-cut reject: 파일은 디스크에 남고 store Unavailable, `live_rows=0`이나 boot ok → silent outage, #25078·#25135의 실제 전이). `NoDurableRowLostOnBump` invariant(`boot_outcome=ok ⇒ live_rows=OldRows`; fatal boot은 fail-loud로 면제)는 두 모드 모두에서 위반된다(파일 잔존 여부와 무관하게 "ok인데 live row 없음"이 버그). clean cfg = "No error has been found", buggy cfg = "Invariant NoDurableRowLostOnBump is violated". 양쪽 cfg 모두 기대대로 통과해 spec 유효.
- **회귀 재현 테스트**: 위 4개 사고 각각을 fixture로 — 구 version 파일을 심고 boot preflight를 돌려 (a) migration 있으면 무손실 변환, (b) 없으면 fatal(silent Unavailable 아님)을 assert.
- **counterfactual**: preflight의 version 대조를 삭제하면 재현 테스트가 red.
- descriptor 미등록 durable store가 없음을 boot에서 열거 검증(meta guard).

## 5. Blast radius

- boot 시퀀스에 preflight 단계 삽입(keeper 시작 전, 단일 프로세스).
- 위험 store 우선 배선: **drop-on-mismatch 1개(메모리 뱅크, 무경고 유실이라 최우선)** → hard-cut-reject 7개(즉시 descriptor + migration/generation-bump 결정) → unversioned 9개(version 필드 도입 + descriptor). **Memory OS(episode `-g%04d`)는 안전 아님** — `-g%04d`는 schema namespace가 아니라 episode/trace generation이라 schema bump 시 구 파일이 자동 orphan되므로 hard-cut 그룹으로 분류해 descriptor 대상. 진짜 안전 참고는 shutdown projection의 backward-read와 reaction ledger의 경로-generation-bump 2개뿐.
- `Store_version` variant화로 각 store의 version 문자열 → typed. wire 호환 유지(디스크 표기 불변, 파싱만 typed).
- version 표기 6가지 상이 컨벤션(schema-suffix / storage_generation / int schema_version / 문자열 rfc-vN / 경로-embed generation / 표기부재)을 descriptor의 `Store_version.t`로 수렴. 디스크 표기는 store별로 유지하되 **선언은 한 타입**으로.

## 6. Interaction with existing RFCs

- **RFC-0338**(lane isolation): lane별 store 격리와 직교. preflight는 lane store에도 descriptor로 적용.
- **RFC-0341**(lifecycle projection SSOT): projection store도 durable이면 descriptor 대상.
- **RFC-0000 Law 4**(HARD CUT): 이 RFC는 Law 4의 예외가 아니라 **구현**이다 — "새 경계 검증 후 legacy 삭제"에서 검증 단계에 durable state migration을 넣어, 삭제가 데이터 유실이 되지 않도록 보장.

## 7. Workaround-rejection self-check (CLAUDE.md)

이 RFC는 반복된 hand-fix를 인프라로 흡수한다:

- #25197(v4 generation-bump), #25231(compat read)은 **N-of-M 패치 시그니처**(store마다 따로 처리)의 전형. §3.4 primitive + §3.3 타입 결속이 근본(변환 추출 + type-level invariant).
- #25135의 "store Unavailable" 조용한 실패는 **telemetry-as-fix가 아니라 fail-open**이었다. §3.2는 이를 fail-loud로 전환(관찰이 아니라 boot 차단).
- **telemetry-as-fix가 이미 존재하나 근본을 못 막았다**: `read_drop_reason.ml:37`의 `Schema_version_mismatch` enum + `metric_persistence_read_drops`(`keeper_approval_queue.ml:118-122`)는 version 불일치 drop을 *센다*. 이것이 정확히 CLAUDE.md 시그니처 #1(counter-as-fix) — drop을 visible하게 만들 뿐 데이터 유실은 그대로다. §3.2 preflight는 counter를 boot-time migration/fatal로 대체해 이 시그니처를 근본 해소한다.
- 이 RFC 자체는 cap/cooldown/dedup/repair 억제 패턴을 도입하지 않는다. migration은 repair(read 시 sanitize)와 다르다 — boot 시점 1회 변환 후 runtime은 current만 본다.

---

## §현황: durable store 인벤토리 (2026-07-19 code-verified)

전수 조사 결과 durable store 약 **21개**(compaction evidence는 host store에 embed, fs lock은 payload 없음 — 제외). unknown-version 처리 방식으로 분류:

### 위험 A — hard-cut-reject (7개, 구 데이터 orphan / store Unavailable)

| store | 경로 | version | reject 지점 |
|-------|------|---------|-------------|
| Event queue snapshot | `.masc/keepers/<name>/event-queue.json` | `keeper.event_queue.state.v3` | `keeper_event_queue_persistence.ml:200-201` |
| Event queue settlement WAL | `…/event-queue-settlements.jsonl` | `masc.keeper_event_queue.settlement.v1` | `keeper_event_queue_persistence.ml:245` |
| Event queue inflight sidecar | `…/event-queue-inflight.json` | (존재=legacy) | `…persistence.ml:204-217` (명시적 migration 거부) |
| Gate approval order | `.masc/gate/pending.json` | `pending_store_version=2` | `keeper_approval_queue.ml:516-522` → `mark_store_unavailable` |
| Checkpoint | `…/sessions/<id>.json` | SDK int version | `keeper_checkpoint_store.ml:233-234` |
| Prompt overrides | `.masc/prompt_overrides.json` | `schema_version=1` | `prompt_override_persistence.ml:119-123` |
| Chat queue (SQLite) | `…/chat-queue.sqlite3` | `keeper_chat_queue.sqlite.v2` | `keeper_chat_queue.ml:1477-1478` |

### 위험 B — unversioned (9개, 암묵적 hard-cut; 필드 추가만 관대)

gate mode(`gate/mode.json`), gate always-allowed rules(`gate/always-allowed.json`), channel gate bindings(slack/discord/imessage/telegram `bindings.json`/`status.json`), board posts·comments·reactions·sub_boards(`board_*.jsonl`), board votes(`board_votes.jsonl`), candidate ledger(`board_attention_candidates/<name>.jsonl`), keeper meta store(`keepers/<name>.json` — `meta_version`은 CAS용이지 schema 아님), generation lineage(write-only 태그), compact audit(`data/harness-compact/*.jsonl`).

### 위험 C — drop-on-mismatch (1개, 무경고 데이터 유실)

Keeper memory bank(`memory_bank.jsonl`, `keeper_memory_schema_version=2`): version 불일치 row를 조용히 `None`으로 drop (`keeper_memory_bank.ml:97-99`). bump 시 무경고 유실.

### 안전 참고 사례 (2개)

- **backward-read**: shutdown/lifecycle projection(`keeper_shutdown_store.ml:578-586`) — 유일하게 4개 구 스키마 compat reader 보유. §3.1 descriptor의 참조 구현.
- **generation-bump**: reaction ledger(경로에 `/v4/` embed) — 경로에 schema generation을 embed해 구 세대가 명시적으로 분리·무손실.
- (정정) memory OS의 episode `-g%04d.json`은 안전 사례가 **아니다** — `-g%04d`는 schema generation이 아니라 episode/trace 카운터라 schema shape이 bump되면 구 episode 파일이 조용히 orphan된다. §위험 A(hard-cut) 성격으로 재분류.

### SSOT 부재 (심각)

version 표기가 store마다 6가지 상이 컨벤션으로 공존: (1) schema-suffix `…state.v3`, (2) 별도 `storage_generation="v4"`, (3) int `schema_version`/`pending_store_version`, (4) 문자열 `rfc0259-v1`, (5) 경로-embed generation, (6) 표기 부재. 공유 version 모듈·preflight 없음. `lib/core/read_drop_reason.ml:37`의 `Schema_version_mismatch` enum + `Otel_metric_store.metric_persistence_read_drops` telemetry는 존재하나 **사후 관측**이지 migration/preflight이 아니다 — RFC가 채울 정확한 공백.

전체 23행 상세 표: 이슈 #25287.
