---
rfc: "0072"
title: "provider_adapter.ml 서브-라이브러리 추출"
status: Draft
created: 2026-05-12
updated: 2026-05-12
author: yousleepwhen
supersedes: []
superseded_by: null
related: ["0056", "0058", "0070"]
implementation_prs: []
---

# RFC-0072: `provider_adapter.ml` 서브-라이브러리 추출

- **Depends on**: RFC-0056 §3.1 G1–G5 추출 게이트 (이 RFC의 모든 단계가 통과 의무)
- **Related**: RFC-0058 §2.4 (capability-flag SSOT, 본 파일의 6 touch 중 5개가 이 RFC 작업), RFC-0070 (sub-lib 추출의 phasing 패턴 차용)
- **Drives**: 200-PR self-eval 에서 식별된 2nd hot spot (10시간 / 6 touch) 의 구조적 봉합 — godfile-split 회피하고 *boundary*를 도입

## 1. Motivation

### 1.1 Hot-spot 측정

`git log --oneline -50 -- lib/provider_adapter.ml lib/provider_adapter.mli` 결과, **최근 10시간 안에 6 touch** 가 발생했다. 200-PR self-evaluation 에서 `keeper_unified_turn.ml` 다음으로 큰 churn 영역으로 식별되었다.

| # | PR | 변경 성격 |
|---|----|----------|
| 1 | #14771 | `is_http_probe_capable_kind` exhaustive variant enumeration |
| 2 | #14736 | `timeout_bounds_of_kind` boundary helper (RFC-0058 Phase 5.6 leak 4/4) |
| 3 | #14721 | caller-driven explicit capacity register, `looks_like_ollama` 제거 |
| 4 | #14717 | `apply_wire_overlay` boundary helper (RFC-0058 Phase 5.6 leak 3/4) |
| 5 | #14695 | RFC-0058 §2.4 — 3 closed-variant dispatch sites 봉합 |
| 6 | #14659 | `tool_policy_of_cascade_capabilities` bridge primitive (RFC-0058 §2.4 SSOT) |

여섯 PR 모두 RFC-0058 의 "vendor-specific match 를 capability flag 로 봉합" 작업이며, 그 흡수 지점이 매번 동일 파일이다. 파일 크기 1,982 LOC + .mli 610 LOC = **2,592 LOC** 단일 모듈. fan-in 은 외부 56 파일 (`rg 'Provider_adapter\.' lib/ test/ bin/`).

### 1.2 왜 godfile-split 이 아닌가

project instructions §software-development.md 의 "경계를 정확하게 구분하는 것이 더 좋은 제품" 원칙. RFC-0056 §3.2 가 이미 *cosmetic split* (LoC 재분배) 을 거부한다 — PR #14166 (prometheus 모듈) 가 user 거부된 선례.

본 파일의 churn 은 LoC 때문이 아니다. **서로 다른 시간축 / 다른 결정자 / 다른 SSOT** 의 책임이 한 모듈 안에서 공존하기 때문이다 (§3 참조). 따라서 godfile-split 이 아닌 sub-lib 추출이 답이다. 단, RFC-0056 §3.3 의 G1–G5 게이트 *전부 통과* 가 머지 조건이다.

### 1.3 RFC-0058 작업의 잔여 (out of scope)

RFC-0058 의 capability-flag 통합은 *콜러 측* 의 closed-variant dispatch 를 봉합한다. 본 RFC 는 *호스팅 측* 의 분리를 다룬다 — capability-flag 가 어디서 정의/저장/조회되는지를 분리하면 콜러는 더 좁은 surface 만 의존하게 된다. RFC-0058 자체의 phase 진행은 본 RFC 의 추출 결과와 *직교* 이며, 본 RFC 는 RFC-0058 의 SSOT 위치는 건드리지 않는다.

## 2. Architectural Invariant — Provider Opacity

OAS/MASC 의 핵심 불변식: **Provider 와 Model 은 opaque alias 다.** keeper-tool-selection 패턴과 동일하게, 본 sub-lib 의 *경계* 위에서는 어떤 vendor 이름도 1st-class 가 아니다.

### 2.1 추출 후 새 sub-lib 안에서

- 모듈 이름은 abstract term 만 사용한다:
  - `provider_adapter_dispatch` — adapter 레지스트리 조회 / canonical name resolution / cascade prefix routing
  - `provider_adapter_capability` — tool_policy / telemetry_policy / capability flags (RFC-0058 §2.4 SSOT)
  - `provider_adapter_voice` — voice adapter / voice HTTP request / voice session URL
- 어떤 vendor 이름도 *모듈 이름, dune 파일, 디렉토리 이름, public_name* 어디에도 두지 않는다 (구체 vendor 식별자 목록은 RFC-0058 추적 자료에 위임).
- 기존 *내부* vendor-식별 literal (현행 `cn_*` 상수군) 은 RFC-0058 추적의 일환이며 본 RFC 의 scope 가 아니다. 그러나 sub-lib *경계* 에는 단 한 개도 노출되지 않아야 한다.

### 2.2 검증

vendor-식별자 regex (RFC-0058 추적 자료의 vendor-token list 와 동기화) 로 `lib/provider_adapter_*/dune` 와 `docs/rfc/RFC-0072*.md` 를 grep 했을 때 0 hit 여야 한다 (sub-lib 내부 .ml 의 string literal 은 별개; 본 RFC 문서 자체와 sub-lib *디렉토리 메타* 는 vendor-free).

## 3. Boundary Analysis

### 3.1 현재 책임 (.mli 14 section)

`lib/provider_adapter.mli` 의 OCamldoc `{1 ...}` 헤더로 식별되는 sections:

| Section | LOC range | 책임 cluster |
|---------|-----------|-------------|
| Types | 9–173 | **types** — types 만 (공용) |
| Canonical Provider Names | 175–191 | **dispatch** — `cn_*` 상수 |
| String Converters | 193–197 | **types** — variant ↔ string |
| Adapter Registry | 199–205 | **dispatch** — `direct_adapters` / `voice_adapters` 리스트 |
| Label and Provider Resolution | 207–316 | **dispatch** — label → adapter, kind → adapter, prefix routing, capability bridges |
| Voice Adapter Resolution | 318–339 | **voice** |
| Voice Session URLs | 341–353 | **voice** |
| Voice HTTP Requests | 355–371 | **voice** |
| Model Label Resolution | 373–429 | **dispatch** — model label parsing / classification |
| Llama Model Resolution | 431–434 | **dispatch** |
| Ollama | 436–439 | **dispatch** |
| Auth | 441–460 | **dispatch** — `auth_kind_for_*`, `auth_detail_of_*` |
| Direct-API Auth | 462–600 | **dispatch** — direct-API auth, wire overlay, capability flags |
| Misc | 602–610 | **dispatch** |

5개 cluster 식별:

| Cluster | Description | LOC est. | 새 위치 |
|---------|-------------|---------|---------|
| **types** | variant types + string converter | ~250 | `provider_adapter_types` |
| **dispatch** | adapter 레지스트리 + label/kind 해상도 + auth resolution | ~1100 | `provider_adapter_dispatch` |
| **capability** | tool_policy / telemetry_policy / `is_http_probe_capable_kind` / `timeout_bounds_of_kind` / `tool_policy_of_cascade_capabilities` (RFC-0058 §2.4) | ~400 | `provider_adapter_capability` |
| **voice** | voice adapter / voice HTTP / voice session URL | ~450 | `provider_adapter_voice` |
| **model_label** | model label parsing / `provider_of_model_label` / `configured_*_model_label_result` | ~250 | `provider_adapter_dispatch` 와 합침 (cycle: model label resolution 이 adapter 레지스트리 에 의존) |

### 3.2 Fan-in 측정 (bare `Provider_adapter.` 패턴)

총 56 외부 파일. 디렉토리 분포:

| 디렉토리 | 파일 수 |
|---------|--------|
| `lib/cascade/` | 15 |
| `lib/keeper/` | 13 |
| `test/` | 약 12 (`rg -l 'Provider_adapter\.' test/`) |
| `lib/voice/` | 2 |
| `lib/dashboard/` | 2 |
| `lib/` (root) | 나머지 |

### 3.3 Fan-in 측정 (wrapped `Masc_mcp.Provider_adapter` 패턴)

`feedback_extraction_audit_must_grep_both_bare_and_wrapped` (MEMORY) 가 강제하는 *cross-grep*:

```
rg -l 'Masc_mcp\.Provider_adapter' lib/ test/ bin/
```

현 시점 7 파일 (모두 `test/`). Phase 0 의 dune 변환 후 이들은 `s/Masc_mcp\.Provider_adapter/Provider_adapter/g` 단일 패턴 rewrite 만 받는다 (RFC-0056 §3.1 G5).

### 3.4 단일 cluster fan-in (voice 가 가장 깨끗)

`rg -lF 'Provider_adapter.voice_' lib/ test/ bin/` → **2 파일** (`lib/voice/voice_bridge_core.ml`, `lib/voice/voice_bridge.ml`). voice cluster 가 가장 약한 cross-cluster 결합을 가져 Phase 1 후보가 된다.

## 4. RFC-0056 G1–G5 Compliance

각 Phase 가 RFC-0056 §3.1 의 5개 gate 를 *전부* 통과해야 머지된다. gate 정의는 RFC-0056 §3.1 의 표를 그대로 차용한다 — 본 RFC 는 별도 게이트를 도입하지 않는다.

### G1: No cycle

> "candidate 의 outbound 모듈 참조 가 (a) `dune` `(libraries ...)` 에 선언된 sub-lib, (b) candidate 자체 모듈, (c) candidate 가 의존성으로 선언한 모듈 에만 해석. flat namespace 로 돌아가는 참조 없음." (RFC-0056 §3.1)

Phase 0 (types 추출) 은 `Yojson` 외부 dep 만 사용. Phase 1 (voice 추출) 은 `Voice_config`, `provider_adapter_types`, `Eio` 만 사용 — `Voice_config` 가 flat namespace 모듈이지만 voice → flat 한 방향만이므로 cycle 없음. Phase 2 (capability + dispatch) 는 `Llm_provider.Provider_config`, `Cascade_declarative_types` 등 외부 sub-lib 만 사용. **각 Phase 의 G1 검증은 `scripts/audit-sublib-cycle.py lib/<X>` (RFC-0056 §3.1 에서 예약된 스크립트) 가 dune build green 과 함께 통과해야 함**. 스크립트 부재 시 `dune build --root . @check` 가 green 인 것으로 잠정 검증, 단 PR body 에 명시.

### G2: No `.mli` change

> "이동된 모듈의 public interface 는 byte-identical 로 유지. Phase 0 는 어떠한 signature 도 좁히거나 넓히지 않는다." (RFC-0056 §3.1)

Phase 0/1/2/3 모두 `.mli` 추가/이동만 허용. 기존 `lib/provider_adapter.mli` 의 *signature 자체* 는 byte-identical 로 새 위치로 이동 — 단순 textual move. signature 의 *분할* 은 발생하지만 (한 .mli 가 N .mli 로) 각 함수의 type signature 는 동일. `git diff --stat lib/**/*.mli` 가 add + delete 만 보여야 하고 modify 없음.

### G3: No caller rename

> "이동된 모듈의 callers 는 계속 `Foo` (`Bar.Foo` 아님) 라고 쓴다. `(wrapped false)` 로 달성." (RFC-0056 §3.1)

각 새 sub-lib 은 `(wrapped false)`. caller 는 여전히 `Provider_adapter.<cn_*>`, `Provider_adapter_voice.voice_adapter_for_endpoint` 같은 unprefixed 이름 사용. 단 모듈 *이름* 자체는 변한다 (예: voice 호출자 가 `Provider_adapter.voice_adapter_for_endpoint` → `Provider_adapter_voice.voice_adapter_for_endpoint`). G3 는 `open` / module-prefix 추가 금지 — `Provider_adapter` 라는 prefix 의 *내용물 일부* 가 `Provider_adapter_voice` 로 옮겨가는 이름 변화는 G5 의 caller-delta 로 다룬다.

### G4: Build green on `@check`

> "`dune build @check` 가 로컬과 CI Fundamental 에서 green." (RFC-0056 §3.1)

각 Phase PR 의 머지 조건. push *전* `dune build --root . @check` 가 worktree 안에서 green 이어야 함 (MEMORY `reference_masc_mcp_dune_local_lock_contention` 참고 — `--root .` 명시 의무).

### G5: Caller delta budget

> "candidate 디렉토리 외부 에서 변경되는 파일 수는 bounded. Phase 0 에서 허용된 유일한 caller 변화는 이동된 모듈의 *redundant-qualifier 제거*. `Masc_mcp.X` 콜러는 `X` 로 rewrite. `s/Masc_mcp\.<Module>/<Module>/g` 외 어떤 것도 G5 위반 (signature 변경, `open` 추가, semantic accommodation 포함)." (RFC-0056 §3.1)

본 RFC 는 단순 추출이 아니라 *분할* 이므로 추가 caller-delta 가 발생한다 — `Provider_adapter.X` 의 X 가 어떤 sub-lib 으로 갔는지에 따라 caller 가 `Provider_adapter_voice.X` 로 rewrite 해야 한다. 이는 RFC-0056 §3.1 G5 *원문의* `s/Masc_mcp\.<Moved>/<Moved>/g` 패턴을 넘어선다. 본 RFC 의 G5 해석:

- **Phase 0 (types)**: G5 원문 그대로. `Masc_mcp.Provider_adapter` → `Provider_adapter` 만 허용 (현 7 callers).
- **Phase 1+ (분할)**: caller-delta 가 `s/Provider_adapter\.X/Provider_adapter_<sublib>\.X/g` 단일 패턴으로 한정. *어떤 caller 도 새로운 `open` / 새로운 인자 / 새로운 invariant 를 받지 않는다*. PR body 에 그 패턴과 영향 파일 수를 명시.
- Phase 1 voice 분할 의 예상 caller-delta: 2 (lib/voice/voice_bridge_core.ml, lib/voice/voice_bridge.ml).

caller-delta 가 위 패턴을 벗어나는 순간 candidate 는 leaf 가 아니며 PR 은 분할 더 깊게 해야 한다 (RFC-0056 §3.3 "deferred set" 패턴).

## 5. Migration Plan

각 Phase 는 *standalone revertible*. 직전 Phase 에 의존하지만 직후 Phase 없이도 main 에서 stable.

### Phase 0 — dune stanza + types 추출 (1 PR)

- `lib/provider_adapter_types/dune` 신설, `(include_subdirs no)`, `(wrapped false)`, deps = `yojson` 만.
- `lib/provider_adapter.mli` 의 `{1 Types}` + `{1 String Converters}` 섹션 (변환 함수 3개: `string_of_runtime_kind`, `string_of_auth_mode`, `string_of_voice_transport`) 을 `lib/provider_adapter_types/provider_adapter_types.{ml,mli}` 로 이동.
- 단 `Llm_provider.Provider_config.provider_kind` 에 의존하는 *함수* (`string_of_provider_kind` 등) 는 Phase 0 에서 *제외* (cycle 회피). dispatch 와 함께 Phase 2.
- 기존 `lib/provider_adapter.{ml,mli}` 는 새 sub-lib 을 *open* 하고 type alias 만 re-export (G3/G5 충족).
- **Phase 0 caller audit (MEMORY `feedback_extraction_audit_must_grep_both_bare_and_wrapped` 강제)**:
  ```
  rg -l '\bProvider_adapter\b' lib/ test/ bin/
  rg -l 'Masc_mcp\.Provider_adapter' lib/ test/ bin/
  ```
  두 패턴의 합집합으로 caller 모집단 확정. Phase 0 에서는 type 만 이동하므로 *type 호출 사이트* 만 영향 — 측정치 PR body 에 명시.

**G1–G5 expected**: types-only 이동, 외부 fan-in 없음, `.mli` byte-identical move, G5 = wrapped-qualifier-removal 7 callers + bare-qualifier `Provider_adapter.runtime_kind` 등 ~30 callers (type 사용처).

### Phase 1 — voice 분할 (1 PR)

- `lib/provider_adapter_voice/dune` 신설, deps = `voice_config`, `provider_adapter_types`, `yojson`, `eio`.
- `.mli` 의 `{1 Voice Adapter Resolution}` + `{1 Voice Session URLs}` + `{1 Voice HTTP Requests}` 섹션 전체 이동.
- caller-delta: 2 파일 (`lib/voice/voice_bridge_core.ml`, `lib/voice/voice_bridge.ml`) + test fan-in 측정 후 명시.
- 패턴: `s/Provider_adapter\.voice_/Provider_adapter_voice.voice_/g`, `s/Provider_adapter\.all_agent_voices/Provider_adapter_voice.all_agent_voices/g`, `s/Provider_adapter\.default_voice_session_url/Provider_adapter_voice.default_voice_session_url/g`.

**왜 voice 가 Phase 1 인가**: §3.4 측정 — voice fan-in 이 2 파일 (cluster 자체 안) 로 가장 깨끗. RFC-0056 §3.3 의 "smallest scope that exercises G1–G5 non-trivially" 와 동일 동기.

### Phase 2 — capability 분할 (1 PR)

- `lib/provider_adapter_capability/dune` 신설, deps = `llm_provider`, `cascade_declarative_types`, `provider_adapter_types`.
- RFC-0058 §2.4 SSOT 함수들 이동:
  - `tool_policy_of_cascade_capabilities`
  - `is_http_probe_capable_kind`
  - `timeout_bounds_of_kind`
  - `apply_wire_overlay`
  - `oas_capabilities_of_config`
  - `requires_per_keeper_bridging_for_bound_actor_tools_for_kind`
  - `tolerates_bound_actor_fallback_for_kind`
  - `supports_runtime_mcp_http_headers_for_config`
  - `accepts_runtime_mcp_http_header_for_config`
- caller-delta: §3.2 측정 의 `lib/cascade/` 15 + `lib/keeper/` 13 부분 — capability 함수 사용 사이트만 (RFC-0058 추적 으로 이미 식별됨).

**왜 capability 가 Phase 2 인가**: RFC-0058 의 *capability flag SSOT* 동기와 직접 매핑. 이 분할 후에 RFC-0058 의 잔여 closed-variant 봉합 PR 들이 자연스럽게 *이 sub-lib 내부에서* 발생, churn 이 본 RFC 의 분할 boundary 안으로 격리됨.

### Phase 3 — dispatch 잔여 (N PRs, N 미정)

- 남은 `{1 Adapter Registry}`, `{1 Label and Provider Resolution}`, `{1 Model Label Resolution}`, `{1 Local-Runtime Model Resolution}`, `{1 Local Runtime}`, `{1 Auth}`, `{1 Direct-API Auth}`, `{1 Misc}` 섹션 (.mli 의 원본 헤더와 매핑) 이 dispatch 본체.
- 이 클러스터 내부의 cycle 측정 (Adapter Registry 가 Model Label Resolution 을 호출 하는지, 그 반대인지) 후 sub-PR 로 분할.
- 모든 Phase 3 PR 은 G1–G5 재검증.

**N 의 미정 이유**: Phase 0–2 통과 후 측정되는 잔여 cycle 에 따라 1–3 PR 로 결정. RFC-0056 §3.3 의 "deferred set 은 TODO 가 아니라 explicit Phase 1 ask" 패턴 차용.

## 6. Risks

### 6.1 dune build cycle 위험

RFC-0056 §3.3 의 Phase 1 ask 가 `Cdal_loader` 의 `Proof_artifact_reader` cycle, `Cdal_verdict_gate` 의 `Attribution`/`Bounded` cycle, `Cdal_friction_projection` 의 `Session`/`Violation_record` cycle 을 예측한 것과 동일한 risk. provider_adapter 의 후보 cycle:

- **types ↔ Llm_provider**: `Llm_provider.Provider_config.provider_kind` 가 types 의 일부 함수에서 사용됨 (`string_of_provider_kind` 등). 해결: 그 함수들은 Phase 0 에서 *제외* 하고 Phase 2 capability 와 함께 이동.
- **capability ↔ dispatch**: `adapter_of_provider_config` (dispatch) 가 `tool_policy` (capability) 를 빌드한다. dispatch 가 capability 를 *읽지만* capability 는 dispatch 를 모름 — 단방향, cycle 없음 예상. 단 Phase 2 PR 의 G1 검증에서 확정.
- **voice ↔ dispatch**: voice 가 `cn_*` canonical name 상수 (dispatch) 를 사용 가능. 해결: cn_* 상수는 Phase 0 types 가 아닌 dispatch 에 둠 — voice 가 직접 string literal 을 사용하지 않고 dispatch 의 cn_* 을 import. 또는 voice 가 cn_* 의존성 없으면 격리 가능. Phase 1 PR 의 dune build 가 검증.

### 6.2 Test-only callers 누락 위험

bare `\bProvider_adapter\b` grep 만으로는 wrapped `Masc_mcp.Provider_adapter` 의 7 test callers 를 놓친다 — MEMORY `feedback_extraction_audit_must_grep_both_bare_and_wrapped` 의 정확한 시나리오. 각 Phase 의 caller audit 는 두 패턴을 *모두* 측정하고 PR body 에 양쪽 count 를 명시.

### 6.3 Telemetry metric naming 연속성

`Keeper_usage_trust` 가 capability sub-lib 의 wire-cache flag (현행 `Provider_adapter.uses_*_caching` 류 함수) 를 통해 텔레메트리 anomaly flag 를 builds. 이 caller path 가 capability sub-lib 으로 옮겨질 때 *metric name* 자체는 변하지 말아야 한다 (대시보드, Prometheus query). 본 RFC 는 *함수 이름* 만 옮기고 *metric label* 은 변경 없음 — Phase 2 PR body 의 verification 섹션에서 `rg 'metric_.*provider' lib/` 의 결과가 byte-identical 임을 확인.

### 6.4 RFC-0058 작업 동시성

RFC-0058 의 잔여 Phase 가 본 RFC 의 분할 *직전* 또는 *직후* 에 동일 함수를 만질 수 있다. mitigation: Phase 2 (capability) PR 직전 에 `git log --oneline -5 -- lib/provider_adapter.ml` 확인, RFC-0058 PR 이 in-flight 면 그것이 머지될 때까지 Phase 2 대기.

## 7. Verification Gates

각 Phase PR 의 머지 조건 (RFC-0056 §3.1 G1–G5 위에 추가):

1. **`dune build --root . @check`** — green (worktree 안에서, MEMORY `reference_masc_mcp_dune_local_lock_contention` 의 `--root .` 의무 준수).
2. **`dune runtest`** — Phase 0 은 0 test 변화 기대; Phase 1+ 는 영향 받는 test (`test/test_provider_adapter.ml` + cascade/voice/keeper 의 관련 test) 가 pass count 유지.
3. **Provider opacity**: vendor-식별 token regex (RFC-0058 추적 자료의 token list 와 동기화) 로 `lib/provider_adapter_*/dune` 와 본 RFC 문서를 grep 했을 때 0 hits. (sub-lib 내부 .ml 의 RFC-0058 추적용 string literal 은 별개 — 본 검증은 *경계* 문서/메타에만 적용.)
4. **Fan-in delta = 0 (Phase 0)** / **단일 패턴 rewrite (Phase 1+)**: caller 들의 diff 는 RFC-0056 §3.1 G5 의 `s/Masc_mcp\.Provider_adapter/Provider_adapter/g` (Phase 0) 또는 본 RFC §4 G5 의 `s/Provider_adapter\.X/Provider_adapter_<sublib>\.X/g` (Phase 1+) 단일 패턴 만. `open` 추가, signature 변경, semantic accommodation 없음.
5. **`.mli` byte-identity**: 이동된 signature 의 OCamldoc 텍스트 포함 byte-for-byte 동일. `diff <(원본 .mli 의 해당 섹션) <(새 .mli)` 가 빈 출력.
6. **Audit cross-grep**: PR body 에 bare + wrapped 두 패턴 의 fan-in count 명시 (MEMORY `feedback_extraction_audit_must_grep_both_bare_and_wrapped` 강제).
7. **RFC 번호 충돌 사전 확인**: push *직전* `git fetch origin main && ls docs/rfc/ | grep -E '007[0-9]'` 로 RFC-0072 가 아직 미사용임을 재확인 (MEMORY `feedback_rfc_number_reservation_needed`).

Failure of any gate → reject. 본 RFC 도 RFC-0056 §3.1 과 동일하게 "WORKAROUND:" override path 없음.

## 8. Out of Scope

- **RFC-0058 잔여 capability-flag 통합**: 본 RFC 분할 후에 sub-lib 내부에서 자연스럽게 진행. 본 RFC 는 SSOT 위치를 *옮기지만* SSOT *내용물* 은 건드리지 않는다.
- **adapter 레지스트리 의 TOML-driven 화**: provider_adapter.mli §3.4 의 "future caller cutover will route `adapter_of_provider_config` through this bridge so `config/cascade.toml` becomes the lookup root" — 별도 RFC.
- **Vendor literal 제거**: 본 RFC 는 *경계* 의 opacity 만 보장. sub-lib *내부* 의 `cn_*` 류 literal 은 RFC-0058 의 추적 대상이며 별개 작업.
- **모듈 이름 wrapping (Phase ≥ 2 of RFC-0056)**: 모든 새 sub-lib 은 `(wrapped false)`. 향후 wrapping 은 별도 RFC.

## 9. Decision

본 RFC 는 *plan* 만 — Phase 0/1/2/3 의 어느 코드도 포함하지 않는다. RFC-0056 §3.3 의 PoC-included 패턴과 달리, 본 RFC 는 doc-only 머지 후 Phase 0 PR 이 후속으로 등장한다. 그 분리는 RFC-0070 의 phasing 패턴 (RFC + 후속 Phase 1–5 PR) 과 동일.

머지 후 즉시 Phase 0 PR 작성 가능 — 본 RFC 의 §5 Phase 0 가 그 PR 의 scope 와 G1–G5 expected 를 미리 명시.
