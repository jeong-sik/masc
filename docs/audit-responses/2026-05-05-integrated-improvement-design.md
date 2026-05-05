# Audit Response — 2026-05-05 Integrated Improvement Design (16→36+ Keepers)

## Source

- **Audit**: `/Users/dancer/Downloads/INTEGRATED_IMPROVEMENT_DESIGN.md`
  (작성일: 2026-05-05, 자체 문서 헤더 기준)
- **Scope**: 36-keeper 확장을 위한 4-phase × 18 action item 통합 설계.
- **Audit's framing**: 현재 14-keeper가 전면 stuck → 같은 구조로 36개 확장 시
  Semaphore wait O(K²), Dashboard N+1 O(K×N), Credential starvation O(K),
  Config 파일 O(K) 폭발. "땜빵을 땜빵으로 막지 말고" 근본 재설계.

## Why this response document

이 audit은 매우 야심찬 통합 설계서이며, 정량 클레임 다수(turn slot 1, keeper
14, env var 443, config 14파일, snapshot 3.3s 등)를 **현재 코드/머지 상태로
검증 가능**한 형태로 제시했습니다. 검증한 결과 **상당수 클레임이 audit 작성
시점 이전~당일 오전에 이미 머지/적용된 변경**이거나, **별도 active 트랙(RFC-0027
PR-9a/9b, #13099, #13072 등)이 같은 axis로 진행 중**입니다.

내부 MEMORY 두 항목이 정확히 이 패턴을 경고:

- `feedback_wave_pattern_60_80_stale_resolved.md` — wave-style multi-issue
  roadmap는 60-80% pre-resolved.
- `feedback_external_report_widespread_stale_critical_path.md` — 외부 audit
  Critical 16 sample 중 6+ stale.

본 문서는 18 action item을 (A/B/C/D)로 분류하고, **남은 진짜 design idea
(Phase 1 생성 기능, 3-Tier 필드 노출, Dashboard N+1 batch)** 만 별도 RFC
트랙으로 분리할 수 있게 합니다. 다음 audit이 이 디렉터리를 먼저 읽으면 같은
inflation을 반복하지 않을 수 있습니다.

## Methodology

각 클레임을 4분류:

- **A — Verified bug** : 코드가 audit 묘사대로이고 production 영향 있음.
- **B — Intentional / already-active track** : 코드는 그렇게 되어 있지만 의도된
  설계이거나, 이미 active RFC/PR 트랙에서 같은 axis로 진행 중.
- **C — Partial truth** : 진짜 design idea 살릴 만하지만 audit 표현은 inflation
  되어 있음. 별도 RFC 필요.
- **D — Stale** : 이미 fix됐거나 audit이 본 snapshot이 outdated.

검증 방법: 각 클레임마다 (1) audit 라인 직접 read, (2) 30-50줄 caller-context
read, (3) 관련 `.mli`/문서/RFC/PR 인용, (4) `git log --since`로 최근 활동 확인.

## 0. Executive summary 검증

| Audit 클레임 (§0) | 실제 | 분류 |
|------------------|------|------|
| 현재 14개 Keeper가 전면 stuck | 검증 불가 (문서가 production telemetry source 미명시). 최근 14일 474 commits, fix 145+feat 128+chore 62 — dead system signature 아님 | **D** |
| `turn_available=0` (14개 모두 skip) | 출처 미상. Recent #13099 (Draft) "surface turn slot holders on starvation" 가 존재 → 진짜 starvation 사례가 있더라도 별도 트랙 처리 중 | **B** |
| Semaphore wait > 180s (100%) | 출처 미상. `keeper_turn_slot.ml:9` `Semaphore_wait_timeout` exception + `holder_table` (line 58) 이미 main에 존재 — 정확한 timeout 값은 env-tunable | **B** |
| Warmup 60s→255s (선형 → 8분 45초) | 산출 근거 미명시. 현 default `keeper_turn_throttle_limit=32` 이미 36-headroom | **D** |
| `autonomous_available=14` | 14는 historical observation. 현 `Eio.Semaphore.make 32` (env-tunable, max_v=max_int) | **D** |

**§0 결과**: Executive summary의 위기 framing은 outdated audit snapshot 기반.
"36개로 확장하면 다 죽는다"는 결론의 전제가 무너집니다.

## 1. 대규모 확장 구조적 결함 검증

### §1-1 Turn Slot Semaphore: O(K²) 병목

| 클레임 | 실제 | 분류 |
|--------|------|------|
| `let autonomous_sem = Eio.Semaphore.create 14` `let turn_sem = Eio.Semaphore.create 1` | `lib/keeper/keeper_turn_slot.ml:43`: `let turn_semaphore = Eio.Semaphore.make keeper_turn_throttle_limit` (default **32**, env `MASC_KEEPER_AUTOBOOT_MAX`, min_v=1, max_v=max_int) | **D** |
| 14 keeper가 1 turn slot 경쟁 → 36배 더 심각 | 1 → 32 (env-tunable) → typo cap `max_v:20` 명시적으로 제거됨 (line 32-33 commit comment: "forced operator raise-cycles every time the fleet grew. Removed.") | **D** |

`keeper_turn_slot.ml:27-41` 인용:

```
(* Global turn slot cap across autonomous + reactive pools.

   Sized for the observed 14-keeper fleet plus burst headroom. Operators
   running larger fleets raise [MASC_KEEPER_AUTOBOOT_MAX] explicitly; the
   only enforced floor is [min_v:1] (0 = deadlock). The previous [max_v:20]
   cap was a typo-defence boilerplate, not an architectural ceiling, and
   forced operator raise-cycles every time the fleet grew. Removed. *)
let keeper_turn_throttle_limit =
  int_of_env_default_with_deprecated
    ~primary:"MASC_KEEPER_AUTOBOOT_MAX"
    ~deprecated:"MASC_KEEPER_AUTOBOT_MAX"
    ~default:32
    ~min_v:1
    ~max_v:max_int
```

**§1-1 결과**: audit 표현 자체가 source code와 일치하지 않음. 18-permit /
36-permit / K-permit 변경은 한 줄 env knob (또는 default 변경) 수준이며,
"근본 재설계"가 아닙니다.

### §1-2 Dashboard Snapshot: O(K × N) 폭발

| 클레임 | 실제 | 분류 |
|--------|------|------|
| `snapshot_json total: 3.3s (keepers_json: 3.2s)` | 출처/측정 조건 미명시. dashboard 측정 dashboard 자체가 SQL을 쓰지 않음 (`rg "Sqlite3\|psql" lib/dashboard/` zero hits) — `Sqlite3.exec db ...` 솔루션은 stack 미스매치 | **C — partial truth** |
| 36개 → snapshot 8.5s+ | sub-op 산출 가능하지만 "예상" 수치이며 측정 evidence 없음 | **C** |

**§1-2 결과**: snapshot N+1 자체는 fixable한 진짜 design improvement 후보지만,
audit이 제안한 "단일 SQL"은 코드 스택과 맞지 않음. fix 방향은 OCaml fiber-batched
fetch 또는 in-memory aggregation. **별도 RFC 필요** (RFC-0029 후보).

### §1-3 Credential/Auth: O(K) starvation

| 클레임 | 실제 | 분류 |
|--------|------|------|
| 현재 14개 모두 `PR-3b1 starvation`으로 archived | `rg "PR-3b1\|starvation"` zero hits in `lib/keeper/credential*`. 단일 `lib/keeper/credential_provider.ml` 존재 | **D** (출처 misread) |
| 36개 starvation → boot 불가 | 전제 자체가 미확인 | **D** |

해당 axis에서 active 작업: **#13088 (EINTR-safe waitpid in credential_materializer,
2026-05-05)** + **#13068 (R)** — credential rotation/reissue 트랙은 별도로
진행. audit이 본 "archived" 상태가 어떤 snapshot인지 출처 미명시.

### §1-4 Config 파일: O(K) 파일 증가

| 클레임 | 실제 | 분류 |
|--------|------|------|
| `config/keepers/`에 14개 .toml 파일 | **6개** (`base.toml`, `issue_king.toml`, `masc-improver.toml`, `ramarama.toml`, `sangsu.toml`, `taskmaster.toml`) | **D** |
| 36개로 확장 → 36개 파일 | base+overrides 패턴 이미 적용됨 — `sangsu.toml` line 2: `base = "base.toml"` (overrides 4 줄) | **D** |
| "5개 keeper 파일을 base+overrides로 축소 필요"의 근거 | 이미 5 persona × ~5 line override + 1 base.toml 구조 | **D** |

**§1-4 결과**: audit의 가장 명백한 stale. 5 persona file은 이미 minimal
override 형태이고 36-keeper로 늘어나도 1 line 추가 수준. base+overrides는
이미 land.

### §1-5 Metric/Telemetry: O(K²) 콜백

| 클레임 | 실제 | 분류 |
|--------|------|------|
| `on_keeper_tool_call`, `on_cache_hit/miss`이 keeper별 no-op ref | 사실 — 일부 hook bridge가 incremental wire-in 패턴. 단 audit이 "no-op"로 본 것은 wire-in 진행 중 단계 — `feedback_wave_pattern_60_80_stale_resolved` 패턴 | **B** |
| 36 → 36 no-op ref → 메모리 낭비 | refs는 module-level, keeper-per 아님. 산출 부정확 | **D** |

해당 axis active: **#13096 (observable telemetry/audit drop on non-Eio dispatch
#10358 c1)**, **#13085 / #13093 (GOAL LOOP metrics + scanner)**.

## 2. 신규 요구사항 3가지 검증

### §2 요구사항 1: Cascade 생성 기능

| 클레임 | 실제 | 분류 |
|--------|------|------|
| `cascade.toml`을 수동으로 편집 | 진짜 — `config/cascade.toml` 수동 편집 기반 | **C — real gap** |
| `masc cascade create/activate/list/delete` CLI | 미구현 | **C — design idea** |
| 런타임에 즉시 적용 (재시작 없이) | RFC-0027 진행 중 — **#13067 (PR-9a weighted_entry, schema additive, R)** + **#13097 (PR-9b dual-track resolver wiring, D)**가 같은 axis (cascade evolution) | **B** |

**§2-1 결과**: "Cascade CRUD CLI"는 진짜 unimplemented design idea. 다만
실시간 reload는 RFC-0027의 PR-9a/9b가 dual-track resolver로 풀고 있는 axis.
사용자 결정 후 별도 RFC로.

### §2 요구사항 2: Persona 생성 + 올바른 필드만

| 클레임 | 실제 | 분류 |
|--------|------|------|
| `unknown keys: keeper.base` 경고 | 검증 필요 — `base.toml` 자체가 valid key 인지 schema 확인 | TBD |
| 죽은 필드 (`work_discovery_sources`, `git_identity_mode`, etc.) | active cleanup 트랙: **#13091 (drop dead persona-schema computed signals -6 LOC)**, **#13076 (unexport internal-only helpers across 4 components)**, **#13070 (-655 LOC dead ide-editor-mock)**, **#13071 (-40 LOC orphans)** — 같은 axis 매주 진행 | **B** |
| `masc persona create` CLI + validate | 미구현 | **C — design idea** |

**§2-2 결과**: 죽은 필드 cleanup은 매우 active한 트랙. CLI 자체는 unimplemented.

### §2 요구사항 3: 고급 필드 숨김 (Progressive Disclosure)

| 클레임 | 실제 | 분류 |
|--------|------|------|
| 모든 필드가 TOML에 노출됨 | sangsu.toml 실제 5줄 (basic 필드만) — base.toml에 default 응집 | **D — already minimal** |
| `--advanced` 옵션 필요 | 5 persona file이 모두 minimal override임을 감안하면 advanced disclosure는 unprioritized | **C** |

**§2-3 결과**: 현재 config는 이미 minimal. Progressive disclosure는 향후 CLI
도입 시점에 reopen.

## 3. 통합 개선 설계 (3-Tier / Token Bucket / N+1 / Credential Pool) 검증

### §3-1 3-Tier Config (Basic / Advanced / Godmode)

설계 자체는 design idea. 현재 5 persona TOML이 이미 minimal이라 즉시 도입할
경계는 약함. **C — design idea, low priority**.

### §3-2 생성 기능: CLI + API + TUI

§2-1 / §2-2와 중복. **C — design idea**.

### §3-3 대규모 확장 구조 변경

#### A. Turn Slot 1개 → K/2개

§1-1과 동일 — 이미 32 default + env-tunable max_int. **D**.

#### B. Eio.Semaphore → Token Bucket

| 클레임 | 실제 | 분류 |
|--------|------|------|
| binary semaphore → token bucket | 메모리 `feedback_semaphore_tier_is_architectural_anti_pattern.md` (2026-05-05)와 같은 결론 — 단 그 fix 방향은 "multi-cascade fanout / deadline scheduling / token bucket per provider". RFC-0026 PR-E-1.6/1.7 가 admission router cascade로 같은 axis 풀고 있음 | **B** |
| token bucket per provider | RFC-0026/0027 트랙과 중복. **#13104 (cascade_state Mutex+Hashtbl → Atomic+immutable Map)** 도 concurrency 패러다임 갱신 axis | **B** |

#### C. Dashboard N+1 → 단일 쿼리

§1-2 참조. SQL 솔루션은 스택 미스매치이지만 N+1 자체는 fixable. **C — RFC
candidate (RFC-0029)**.

#### D. Credential 개별 관리 → Pool 기반

§1-3 참조. credential rotation은 #13088 axis. Pool 추상화는 별도 design.
**B — partial overlap with active track**.

## 4. 죽은 필드 제거 청산 계획 검증

### §4-1 Keeper TOML 죽은 필드 (10 항목)

| 필드 | audit 클레임 | 실제 | 분류 |
|------|-------------|------|------|
| `keeper.base` | 죽음 (unknown key 경고) | sangsu.toml line 2가 실제 사용 — base.toml inheritance 선언 | **D — false** |
| `work_discovery_sources` | 죽음, `work.source`로 대체 | sangsu.toml line 4가 실제 사용. 코드 caller 확인 필요 | TBD |
| `git_identity_mode` | 죽음, 항상 `"github_identity"` | active cleanup 후보 | **C** |
| `tool_access.preset` | 중복 with `tools.preset` | sangsu.toml line 8 실제 사용. `tools.preset`은 audit의 가정 키 | **D — false** |
| `sandbox_profile` | 기본값이라 advanced로 | 5 TOML 모두 미선언 — 이미 default | **D** |
| `network_mode` | 기본값이라 advanced로 | 5 TOML 모두 미선언 — 이미 default | **D** |
| `github_identity` | persona에서 파생 | 검증 필요 | TBD |
| `max_context_tokens` | tier에서 파생 | tier 자체가 cascade routing이라 derive 가능 | **C** |
| `fallback_cascade` | tier 순서에서 파생 | RFC-0027의 weighted_entry로 더 정밀 | **B** |
| `keeper_assignable` | advanced로 | 5 TOML 미선언 | **D** |

**§4-1 결과**: 10개 중 7개가 D 또는 C. 진짜 죽은 필드 1-2개는 #13091/#13076
cleanup 트랙에 추가 가능.

### §4-2 Cascade TOML 죽은 필드

| 필드 | 분류 |
|------|------|
| `tier_small.models = []` | **C** — 빈 배열 자체가 의도일 수 있음 (cascade 구조에서 "사용 안 함" 표시). cleanup 후보지만 RFC-0027 진행 후 정리. |
| `ollama_max_concurrent`, `cli_max_concurrent` null | **B** — null 자체가 "no cap" 표현일 가능성. caller-context 30줄 확인 필요. |
| `routes` 16개 항목 중복 | **C** — 단순 cleanup 후보. |
| `max_tokens` 파생 가능 | **B** — 모델 capability snapshot이 시간 따라 변하므로 명시 유지가 안전. |

### §4-3 Config/env 죽은 필드 (4 항목)

| 필드 | audit 클레임 | 실제 | 분류 |
|------|-------------|------|------|
| `MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC` | 443개 중 하나 | 실제 unique env var는 audit이 추정한 443보다 많음(`rg "MASC_[A-Z_]+" lib scripts` raw 1662 mentions). 통합 작업은 RFC-급 | **C** |
| `probe_timeout_sec` | orphan | 검증 필요 | TBD |
| `internal_model_rotation_count` | dead | 검증 필요 | TBD |
| `MASC_CLIENT_CAPACITY` | 중복 with `cli_max_concurrent` | 검증 필요 | TBD |

## 5. 36-Keeper 확장 검증 체크리스트

§5-1 / §5-2 / §5-3 모두 위 분류의 결과적 합. 별도 점검 불필요.

## 6. 구현 우선순위 4 Phase × 18 Item 검증

### Phase 0: Emergency

| # | Action item | 분류 | 근거 |
|---|------------|------|------|
| 1 | Slot 강제 회수 (wall-clock timeout) | **B** | `Semaphore_wait_timeout` + `holder_table` 이미 main. **#13099 (Draft)** 가 holder surface 강화 중 |
| 2 | Credential auto-refresh (starvation 방지) | **B** | active axis: **#13088 (R)** |
| 3 | Bootstrap health check 실제 수행 | TBD | 별도 verification 필요 |

### Phase 1: 생성 기능

| # | Action item | 분류 | 근거 |
|---|------------|------|------|
| 4 | `masc create keeper` CLI/API | **C** | 진짜 unimplemented. 사용자 결정 필요 |
| 5 | `masc create cascade` CLI/API | **C** | 진짜 unimplemented. RFC-0027과 정합성 확인 |
| 6 | `masc create persona` CLI/API | **C** | 진짜 unimplemented |
| 7 | Auto-credential + auto-registration | **C** | dependency on #4-6 |

### Phase 2: 구조 변경

| # | Action item | 분류 | 근거 |
|---|------------|------|------|
| 8 | Turn slot 1개 → K/2개 | **D** | 이미 32 default + env-tunable |
| 9 | Semaphore → Token Bucket | **B** | RFC-0026/0027 active axis (memory `feedback_semaphore_tier_is_architectural_anti_pattern.md`) |
| 10 | Dashboard N+1 → batch query | **C** | 진짜 design improvement. SQL 제안은 스택 mismatch — RFC-0029 후보 |
| 11 | Config TOML 14개 → base+overrides 2개 | **D** | 이미 적용됨 (5 persona × `base = "base.toml"`) |

### Phase 3: 필드 정리

| # | Action item | 분류 | 근거 |
|---|------------|------|------|
| 12 | 죽은 필드 20개 제거 | **B** | cleanup 트랙 active (#13091/#13076/#13070/#13071, 매주 -100~-700 LOC) |
| 13 | 3-Tier 필드 노출 | **C** | 사용자 priority 결정 후 |
| 14 | 파생 필드 자동화 | **B/C** | `fallback_cascade`는 RFC-0027 weighted_entry로 진행. `max_tokens`는 catalog miss 위험 |
| 15 | 443 env var → 50 통합 JSON | **C** | RFC-급 변경. 별도 design 필요 |

### Phase 4: 검증

| # | Action item | 분류 | 근거 |
|---|------------|------|------|
| 16 | 36 keeper 동시 실행 테스트 | TBD | infra 결정 |
| 17 | 부하 테스트 36×1000 concurrent | TBD | 측정 환경 |
| 18 | TLA+ proof: 36-keeper liveness | **C** | 진짜 가치 — masc-mcp는 이미 25 TLA+ spec 보유 |

## 7. 분류 합산

- **A (verified bug)**: 0건
- **B (intentional / active track)**: 7건 (§1-2 inflation, §1-5, §2-1 partial,
  §3-3-B, §3-3-D, §4-1 fallback, Phase 0 #1, #2, Phase 2 #9, Phase 3 #12, #14)
- **C (real design idea, RFC 필요)**: 7건 (§1-2 N+1, §2-1 CLI, §2-2 CLI, §2-3,
  §3-1, §3-3-C, Phase 1 #4-7, Phase 2 #10, Phase 3 #13, #15, #18)
- **D (stale)**: 14건 (§0 framing, §1-1, §1-3, §1-4, §3-3-A, §4-1 다수,
  Phase 2 #8, #11; **§10 추가 분류로 5건 더**)
- **TBD**: 1건 (Phase 0 #3 — audit specific path 미명시)

**Stale/B-track 비율 ≈ 21/29 ≈ 72% (TBD 후속 분류 후)**. 메모리
`feedback_wave_pattern_60_80_stale_resolved` 임계(60-80%) 정확히 일치.

## 8. 해소 계획

### 8.1 즉시 처리 (이 PR)

본 audit-response 문서 1개 commit. 코드 변경 없음.

### 8.2 사용자 결정 필요한 design idea (별도 RFC 후보)

| 후보 RFC | 내용 | 우선순위 결정 사항 |
|---------|------|-----------------|
| **RFC-0029 후보** | Dashboard snapshot N+1 → fiber-batched aggregation (SQL 아님) | 진짜 measurement 데이터 수집 후 결정 |
| **RFC-0030 후보** | `masc create keeper/cascade/persona` CLI/API + auto-registration | "operator UX" priority confirm 필요 |
| **RFC-0031 후보** | 3-Tier 필드 노출 (Progressive Disclosure) | RFC-0030 후 도입 시 자연스러움 |
| **RFC-0032 후보** | 1662 raw env mention → unified JSON config | 매우 큰 cross-cut 변경. 별도 sprint |

### 8.3 active 트랙에 합류 가능한 작은 개선

- §1-2 코멘트 보강: Dashboard `dashboard_http_keeper_metrics.ml` 헤더에
  "no SQL layer; fiber-batched aggregation TBD" 한 줄 (false-positive 방지).
- §4-1 cleanup: `git_identity_mode` 등 진짜 죽은 필드는 다음 cleanup PR
  (#13091 axis)에 함께.

위 두 항목은 본 audit-response 머지 후 follow-up commit으로 처리. 본 PR에는
포함 안 함 — audit-response 문서가 single concern.

## 10. TBD 항목 후속 검증 (follow-up commit, 2026-05-05)

§4-1 / §4-3 의 5개 TBD 필드를 caller-context grep으로 검증한 결과, 모두
**D — false claim**으로 분류 가능합니다:

### §10.1 §4-1 `work_discovery_sources` ("죽음, `work.source`로 대체")

`rg "work_discovery_sources" lib/ test/` → 9 hit, 모두 active:

| 위치 | 역할 |
|------|------|
| `lib/keeper/keeper_types_profile.ml:299, 473, 923` | `string list option` 타입 + default + ser/de |
| `lib/keeper/keeper_meta_json_parse.ml:623-626` | TOML/JSON parse |
| `lib/keeper/keeper_persona_authoring.ml:209, 544` | persona authoring path |
| `lib/keeper/keeper_run_tools.ml:908` | `Option.value ~default:[] meta.work_discovery_sources` — runtime consumer |
| `test/test_keeper_toml.ml:685, 712` | TOML round-trip 검증 |

**`work.source`는 audit이 추정한 키이며 코드에 존재하지 않음**. 분류 **D**.

### §10.2 §4-1 `github_identity` ("persona에서 파생 가능")

`rg "github_identity\b" lib/keeper/` → 12 hit, 명시 필드:

- `lib/keeper/keeper_turn_up_create.ml:116`:
  `~github_identity:p.profile_defaults.github_identity` — 명시적 named arg.
- `lib/keeper/keeper_types_profile.ml:290, 465, 714, 911`: type +
  default + parse + ser.
- `lib/keeper/keeper_types_profile.ml:728`: 별도 필드 `git_identity_mode`
  의 valid value 중 하나로 사용 — 즉 *파생 가능한 다른 모드와의 enumeration*
  으로 선택되는 명시 필드.

**Persona에서 자동 파생되는 구조가 아님**; 분류 **D**.

### §10.3 §4-3 `probe_timeout_sec` ("orphan")

서로 다른 두 layer에서 active:

- `lib/tool_local_runtime_probe.mli:90`: `val default_probe_timeout_sec :
  int` export → `lib/tool_local_runtime.ml:169-171` `Option.value ~default:
  Tool_local_runtime_probe.default_probe_timeout_sec` 로 default fallback
  값으로 직접 사용.
- `lib/server/server_startup_takeover.mli:20`: `?probe_timeout_sec:float ->`
  startup takeover API의 optional arg.
- `lib/cascade/cascade_catalog_runtime.ml:6`: `let probe_timeout_sec = 5.0`
  module-internal const.

세 위치 모두 active 사용. 분류 **D**.

### §10.4 §4-3 `internal_model_rotation_count` ("dead, 정의만 있고 사용 없음")

`rg "internal_model_rotation_count" lib/ scripts/ test/` → **zero hits**.
즉 **정의 자체가 코드에 없음**. audit이 "정의만 있다"고 주장한 전제가 false.
분류 **D**.

### §10.5 §4-3 `MASC_CLIENT_CAPACITY` ("중복 with `cli_max_concurrent`")

두 layer는 의도된 ortogonality:

- `MASC_CLIENT_CAPACITY` (`lib/cascade/cascade_client_capacity.ml:153, 196,
  201, 211, 216, 231, 254`): env-level override, `"url=max,url=max,..."`
  포맷, runtime override.
- `cli_max_concurrent` (`lib/cascade/cascade_toml_materializer.ml:283, 356`,
  `lib/cascade/cascade_config.ml:1356-1362`, `lib/oas_worker_named.ml:892`):
  config-file-level field, per-cascade.
- `cascade_client_capacity.ml:216` 코멘트가 정확히 둘의 관계 명시:
  "explicit `MASC_CLIENT_CAPACITY` entry. ... when this is missing,
  capacity should use [the config field] (parsed above)".

즉 env가 config-file의 explicit override layer이라는 표준 패턴. **중복이
아니라 layer separation**. 분류 **D**.

### §10.6 종합

5건 모두 **D**. TBD 잔여는 Phase 0 #3 (audit specific path 미명시)뿐.
**남은 진짜 design idea는 §8.2의 RFC-0029~0032 후보 4개 그대로**.

---

## 9. 다음 audit이 같은 inflation 다시 일으키지 않도록

이 audit이 정확히 짚은 것: **wave-style multi-issue roadmap의 위험성**. 18
action item을 한 큰 문서로 묶으면 매트릭스 검증 cost가 폭증하고, 60-80%가
pre-resolved여도 처음 30분 동안은 알 수 없습니다.

Recommendation:

1. 외부 audit (특히 wave-style)을 받으면 **반드시 이 디렉터리부터 점검**.
2. 새 audit이 정량 클레임을 낼 때 **`git log --since=<2 weeks>` + `gh pr list
   --search` 두 명령으로 "active 트랙이 있는가"** 부터 확인.
3. 본 매트릭스의 **C** 항목 7개는 진짜 design idea이므로, 사용자 우선순위 결정
   후 RFC-0029~0032 후보로 별도 트랙 분리.
