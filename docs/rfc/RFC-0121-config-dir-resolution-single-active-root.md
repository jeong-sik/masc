---
rfc: "0121"
title: "Config-dir resolution — single active root, no implicit fallback"
status: Active
created: 2026-05-17
updated: 2026-05-18
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0077", "0088", "0098", "0103"]
implementation_prs:
  - "16084"  # PR-1: Config_dir_resolver named accessors (SSOT prereq)
  - "16092"  # PR-5: scripts purge ME_ROOT/cwd silent fallback (merged)
  - "16096"  # PR-2: repo_manager + auth_resolve to resolver
  - "16097"  # PR-3: host_config + server routes + shutdown to resolver
  - "16099"  # PR-4: tool dispatch + telemetry to resolver
  # PR-6 (current): docs sweep + audit-path-ssot.sh CI gate
---

# RFC-0121: Config-dir resolution — single active root, no implicit fallback

## §1 Problem (caller-context)

지난 2 일 (2026-05-15 → 2026-05-17) 동안 **4 PR 가 home config fallback 제거** 를 시도했지만 매번 새 fallback 사이트 발견:

| PR | 제목 | 결과 |
|---|---|---|
| #15738 | `fix: remove home config fallback` | 일부 제거 |
| #15766 | `[codex] Purge legacy home config fallbacks` | 추가 제거 |
| #15930 | `fix(config): purge home masc config surface` | 추가 제거 |
| #15952 | `fix(test): restore home_dir reference dropped by #15930 rename` | test fix |

**4 PR / 2 일 / 같은 surface** — CLAUDE.md `software-development.md` §"워크어라운드 거부 기준" 의 시그니처 §"N-of-M 패치":

> "Complete the migration", "finish int→int option in Y", "Closes the gap deferred in PR #X"
> **본질**: 같은 변환을 여러 사이트에서 따로 하는 것 자체가 abstraction 실패. 컴파일러가 모든 사이트를 강제 변환하지 못함.

게다가 *현재 main* 에 잔존: `lib/config_dir_resolver/config_dir_resolver.ml:105` 의 `home_base = Env_config_core.normalize_masc_base_path_input home`. 5번째 PR 가 또 fix 시도 예정.

### 의도된 architecture (문서)

`docs/CONFIG-DOCTOR.md` (PR #15930 가 수정):

> "It only resolves operator config from `MASC_CONFIG_DIR` or `<base-path>/.masc/config`."

`docs/spec/14-configuration.md`:

> "암묵적 secondary search (운영자 home personas, base-path root personas) 는 사용하지 않는다."

`docs/BOOT-ENV-STATE-INVENTORY.md`:

> "There is no secondary operator config fallback. On shared hosts, use an explicit base path and expect live config under `<base-path>/.masc/config`."

즉, **문서는 commit 됨, 코드는 4 PR 후에도 unsync.** Doc 가 *aspirational*, 코드가 *legacy fallback* 잔존.

### Why this needs an RFC

1. **3 PRs 가 같은 surface fix 시도** — CLAUDE.md `<feedback>` "AI 페어 프로그래밍 검증 규칙 §2": "2번째 fix → 근본 수정 강제". **4번째까지 와도 미해결**.

2. **Architecture commit 부재**: 위 3 doc 가 *intent* 만 명시. *어떤 fallback 가 *완전 제거* 되어야 하는지* 의 closed list 없음.

3. **PR #15952 fix(test): restore home_dir reference dropped by #15930 rename**: rename 이 test 깨뜨림 — *change surface 가 production code 외 test fixture 까지 확장*. 단일 source-of-truth 부재 증거.

4. **Surface 의 의미적 단일화**:
   - `MASC_CONFIG_DIR` env (explicit)
   - `<base-path>/.masc/config` (implicit but well-defined)
   - 그 외 fallback **모두 제거** (home, home-root .masc, operator home personas, base-path-root personas, etc.)

근본 원인: **resolver function 가 *list of candidates* 가 아닌 *typed Result* 가 되어야**. 명시적 priority chain 으로.

## §2 Approach

3 layer:

**Layer A — Closed-sum `Config_root_source.t`**

```ocaml
module Config_root_source : sig
  type t =
    | Explicit_env of { value : string }           (* MASC_CONFIG_DIR *)
    | Base_path_masc of { base_path : string }     (* <base-path>/.masc/config *)
    (* 이게 *전부*. 다른 fallback variant 추가 금지 *)
  val to_string : t -> string
end

val resolve :
  base_path:string option ->
  env:(string -> string option) ->
  (Config_root_source.t * string, [ `No_explicit_env_no_base_path ]) Result.t
```

closed sum 가 *forbidden by design*: 새 fallback 추가 시 variant 정의 필요 → architectural review trigger.

**Layer B — Adoption gate**

`scripts/lint-config-fallback.sh`: `lib/` 안 `home_dir`, `Sys.getenv "HOME"`, `Filename.concat home`, `home_base`, `home-root .masc`, `operator_home_personas`, `base_path_root_personas` 같은 token grep. *grandfather list* (baseline = 현재 잔존 site) 에 등록된 site 만 허용. 새 호출은 build fail.

RFC-0112 (typed JSON parse boundary, iter-4) 의 `lint-json-parse-raw.sh` 패턴 재사용.

**Layer C — Doc gate**

`docs/CONFIG-DOCTOR.md` + `docs/BOOT-ENV-STATE-INVENTORY.md` + `docs/spec/14-configuration.md` 의 *현재 commit 된 intent* 와 *코드* 일치 보장. CI 가 lint 와 doc 의 *baseline count* 일치 확인 — drift 시 fail.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Config_root_source.t` closed-sum + `resolve` typed Result API. Default = backwards-compat (raw call sites unchanged). | dune build PASS, alcotest 5 case PASS |
| P3 | `lint-config-fallback.sh` baseline = inventory of *현재* fallback site (e.g. `config_dir_resolver.ml:105` `home_base`). CI workflow `.github/workflows/config-fallback-lint.yml`. | grandfather list initial count = N (실측, P3 안에서) |
| P4 | High-traffic site migration (5+ inventoried). 호출자가 `resolve` 의 `Result.Error _` 처리. | grandfather count -= 5 |
| P5 | Remaining sites 모두 migrate. grandfather = 0. | `rg "home.*config|home_dir|operator.*home" lib/` = 0 (unescaped `|` for regex alternation) |
| P6 | Doc 정합 lint — `docs/CONFIG-DOCTOR.md` 의 intent 와 `Config_root_source.t` variant set 일치 검증 | CI 가 doc-code drift 차단 |

P3 가 핵심 — grandfather list 가 더 이상 늘어나지 않음을 enforce. P5 가 *N-of-M closure* — 최종 0 보장.

## §4 Open questions

1. **Q1**: `Base_path_masc` 의 *base_path 결정* — env (`MASC_BASE_PATH`)? CLI flag? 작업 디렉토리? **잠정**: 별도 결정자 (`Base_path_resolver`) — 본 RFC 는 `Config_root_source` 만, base_path 자체 결정은 별도 surface.

2. **Q2**: legacy disk state 가 home-root config 에 있는 사용자 — migration path? **결정**: runtime fallback 은 제공하지 않는다. operator 가 명시적으로 `<base-path>/.masc/config` 로 옮기고, server 는 `MASC_BASE_PATH` 또는 `--base-path` 로만 active root 를 결정한다.

3. **Q3**: `MASC_CONFIG_DIR` 가 *empty string* 또는 *invalid path* 시 행동? **잠정**: P2 의 `resolve` 가 `Error \`Invalid_explicit_env_value` 추가 — 명시적 error.

4. **Q4**: `scripts/lint-config-fallback.sh` 의 false positive (예: variable named `home` for tilde-home dir display in dashboard UI)? **잠정**: lint 가 *`lib/`* 만 검사, dashboard 별도 scope.

## §5 Non-goals

- **Base path 자체 결정 정책 변경**: 본 RFC 는 *config root resolution* 만, base path 별도.
- **Disk format / schema 변경**: 본 RFC 는 *config 위치* 만, 내용 별도.
- **사용자별 personas vs operator personas 의 *의도된* 분리**: 본 RFC 는 *모든 personas* 가 `<base-path>/.masc/personas` 가정. 다른 위치 personas 사용 case 별도 spec PR.

## §6 Risk & rollback

- **Risk 1**: 기존 production user 가 home-root config 에 데이터 보유 — P5 의 lint 통과 후 *runtime fallback 0* 가 그 user 의 config 잃음. → startup 은 home-root 를 추론하지 않고, operator 는 명시적으로 `<base-path>/.masc/config` 를 지정하거나 이전 데이터를 수동 이전한다.
- **Risk 2**: `Config_root_source.t` 가 *future fallback* 강제 reject — 의도된 fallback (예: 새 hosted scenario) 추가 시 architectural review 필요. *이게 정확히 원하는 행동* (closed sum 의 의도).
- **Risk 3**: lint (P3) 가 *기존 4 PR 의 잔존 site* 표시 — P3 baseline 이 정확한 inventory. → P3 의 첫 commit 가 `rg` 로 실측 + 명시.
- **Risk 4**: Doc-code gate (P6) 가 doc PR 와 code PR 동시 강제 — 두 PR 분리 시 *순간 drift*. → CI 가 *PR diff* 만 검사.

Rollback: P3 lint 비활성. P5 의 fallback function 복구 가능 (P2 typed API 는 backwards-compat).

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Config_root_source.t` typed module + `resolve` Result API.
- [ ] P3: `lint-config-fallback.sh` baseline = N (실측).
- [ ] P4: 5+ site migration.
- [ ] P5: grandfather = 0. `rg` 0 hit.
- [ ] P6: doc-code drift CI check.

## §8 Number allocation note

Allocated as RFC-0121. Ledger advanced 0109 → 0122 (skip 0109-0120 due to inflight #15902 RFC-0109 + #15924/15927/15933/15937/15939/15944/15947/15957/15963/15967/15968 RFC-0110~0120 (iter-2..12 of this loop)). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."
