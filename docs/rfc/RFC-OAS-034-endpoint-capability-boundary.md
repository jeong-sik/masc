# RFC-OAS-034: Endpoint capability boundary — host는 capability의 provenance가 아니다

| | |
|---|---|
| Status | Superseded by the explicit provider/model tuple hard cut (#2590) |
| Author | jeong-sik (Claude Opus 4.8 조사) |
| Created | 2026-07-01 |
| Target | `agent_sdk` (oas) — `lib/llm_provider/` (`provider_endpoint.ml`, `provider_config.ml`, `provider_registry.ml`, `discovery.ml`, `capabilities.ml`, `complete_sampling.ml`) |
| Supplements | RFC-OAS-023 (capability axis = model × transport) — 034는 그 원칙의 *집행* 레이어 |
| Mirrors | RFC-OAS-022 (monotone-decrease ratchet) — 신규 위반 사이트를 CI에서 0으로 고정 |
| Aligned infra | RFC-OAS-018 (catalog externalization), PR #2404 (declarative override SSOT) |
| Triggering PRs | #2374, #2408 (둘 다 host `*.proxy.runpod.net` → capability namespace `runpod_mtp`) |

## 0. Summary

> Current contract: provider identity and model id are separate typed/configured
> values. A model row may declare `provider_name` plus its bare `id_prefix`;
> OAS does not synthesize `/`, `:`, or `.`-qualified model ids. Provider identity
> is carried as the explicit provider selector / `Provider_config.provider_id`;
> endpoint URLs and request paths never select it, even when they happen to
> equal a catalog row. The rest of this RFC records the historical problem and
> migration and is not the current lookup contract.

OAS가 엔드포인트의 **capability set / catalog namespace를 배포 host·URL에서 추론**하는 사이트가 여럿 있다. capability는 `(serving runtime) × (model)`의 함수이고 host는 직교하는 전송 주소일 뿐이다. capability를 host에 키잉하면 **동일 server+model이 임대 위치를 옮기는 순간 다르게 동작하거나 capability를 통째로 잃는다(silent fail-closed)**.

RFC-OAS-023이 이미 축을 선언했다 — capability = `model_caps ∩ transport_caps`, host/provider는 model 축이 아니다. 그럼에도 2026-06~07 사이 **같은 host→capability 패턴으로 PR이 2개 열렸다**(#2374 via `provider_endpoint.ml`, #2408 via `provider_config.ml`). 원칙 문서만으로는 재발이 막히지 않는다는 실측이다. 본 RFC는 원칙을 집행 가능한 형태로 못박는다:

1. 위반 유형을 명명하고 감사 인벤토리를 고정한다 (§3).
2. 신규 `base_url_targets_* → capability-label` 사이트를 금지하는 ratchet을 추가한다 (§5, RFC-OAS-022 미러).
3. host 변경에 capability가 불변임을 증명하는 회귀 테스트를 추가한다 (§6).

## 1. Problem

### 1.1 재발하는 계열 (원칙 RFC만으로 안 막힘)

2026-07-01 감사 (`oas-endpoint-capability-boundary-audit`, 29 agents, 7 finder 차원 + 적대 검증): 41 dedup 사이트 중 **confirmed 4 / borderline 5 / legit 32**.

핵심은 `runpod_mtp`가 신규 실수 하나가 아니라 **이미 main에 사는 계열의 재발**이라는 것이다. main에 `provider_registry.ml`의 `is_local → "nous"`가 이미 있었고(§3 B3), #2374·#2408은 그 선례를 두 번 따랐다. 한 번 워크어라운드 패턴이 main에 들어가면 이후 코드 생성(AI든 사람이든)이 그 패턴을 *합리적 선례*로 학습해 누적되는 나선 — 이 RFC가 문서화하는 반복이 바로 그 실측 사례다.

### 1.2 구체 증거 — host를 옮기면 capability가 사라진다

```ocaml
(* PR #2374 자체 테스트 *)
Provider_config.make ~kind:OpenAI_compat
  ~model_id:"qwen36-35b-a3b-mtp"                 (* namespace 미포함 *)
  ~base_url:"https://abc123.proxy.runpod.net/v1"
(* capability_provider_label = "runpod_mtp"  ← host에서 유도 *)
(* catalog 키 = "runpod_mtp/qwen36-35b-a3b-mtp" = <host유도namespace>/<model_id> *)
```

같은 server+model을 `https://mybox.example.com/v1`로 옮기면 → label=`openai_compat` → `runpod_mtp/…` row miss → `capabilities_for_config_model = None` → tools/reasoning/thinking-dialect 전부 상실. RunPod은 임의의 server(vLLM/SGLang/llama.cpp)+model을 얹는 generic GPU-rental edge이므로, "RunPod ⟹ MTP" 가정이 공유 라우팅 코드에 박히면 임대처마다(`_vastai`, `_lambda` …) branch 하나씩 누적되는 나선이 열린다.

### 1.3 왜 host가 아니라 runtime×model인가

capability(MTP, tool_choice, reasoning dialect, structured output)를 결정하는 것은 **무엇이 떠 있냐**(serving runtime × model)이지 **어디에 떠 있냐**(host)가 아니다. 임대 host는 어떤 server+model이든 담을 수 있으므로 host로부터의 capability 추론은 논리적으로 부당하다. 유일한 예외는 **host가 곧 vendor인 canonical 도메인**(`api.openai.com`, `ollama.com`, `api.z.ai`)뿐이다 — 거긴 host==provider가 참이다.

## 2. 경계 원칙 (What vs Where)

| 축 | 결정 요소 | 정당한 출처 |
|----|-----------|------------|
| **WHAT** (capability / namespace) | serving runtime × model | config 필드 / model catalog row / manifest (선언) |
| **WHERE** (transport) | host / URL / request path | auth, base path, edge 튜닝, pricing |

규칙:

1. **capability provenance = 명시적 provider/model 선언.** generic host·URL 또는 model-id 문법 유도 금지.
   - provider-scoped row는 `provider_name`과 bare `id_prefix`를 별도 필드로 선언한다.
   - serving-contract identity가 필요하면 provider catalog id로 선언하고 model id에 namespace를 덧붙이지 않는다.
2. **endpoint → provider identity는 provider catalog 선언으로만 허용.** canonical URL, optional declared environment override, and exact identity host are data; OCaml vendor-host branches are forbidden.
3. **path → wire-protocol**(Responses vs Chat)은 path가 실제 API envelope를 결정하는 경우에만, 정확 문자열 등가 + 비대상 kind는 catch-all 없는 exhaustive match로 fail-closed (`request_path_targets_responses_api`/`validate_request_path`가 정답례).
4. **unknown host/provider/model/label → Unknown/None/fail-closed.** permissive/specific default 금지 (CLAUDE.md AI코드생성 #2).

## 3. 미비 사항 인벤토리 (감사 확정)

### P1 — PR #2374 / #2408 (미병합, 병합 차단) · host → capability namespace

| # | 위치 | 증상 | severity |
|---|------|------|----------|
| B1 | `provider_endpoint.ml:31` `capability_provider_label` (#2374) | `OpenAI_compat when base_url_targets_runpod_proxy → "runpod_mtp"`. label이 `Capabilities.for_provider_model_id ~provider_label`로 흘러 catalog namespace `runpod_mtp/<model>` 선택. host가 namespace의 유일한 provenance. | medium |
| B2 | `provider_endpoint.ml:17` `base_url_targets_runpod_proxy` (#2374) | `host == proxy.runpod.net || *.proxy.runpod.net` predicate. B1에 먹이는 host matcher. 저자가 ollama(broad preset) vs runpod(catalog-scoped) 비대칭을 둔 것 = rental≠vendor를 알면서도 rental host에 provenance를 키잉. | medium |
| B1' | `provider_config.ml` `capability_provider_label` (#2408) | #2374와 **경쟁하는 중복 구현** — 같은 runpod_mtp를 다른 파일 경로로. 같은 root, 같은 조치. | medium |

**조치**: #2374·#2408을 현 형태로 머지하지 않는다. host branch 삭제 → namespace를 §2 규칙 1의 명시 선언에서만 유도. RunPod-MTP를 신호해야 하면 base_url이 아니라 catalog의 runtime+model 키로.

### P2 — main 기존 (선행 결함, 같은 계열) · host locality → vendor + 권한 인플레이션

| # | 위치 | 증상 | severity |
|---|------|------|----------|
| B3 | `provider_registry.ml:533-534` `provider_name_of_config` (`OpenAI_compat + is_local → "nous"`) | 임의 로컬 OpenAI-compat 엔드포인트(bare llama.cpp/vLLM)가 loopback host만으로 특정 벤더 "nous"(Nous Research)로 라벨링. (a) `complete.ml`의 `~provider:` 텔레메트리가 모든 로컬 요청을 nous로 **무조건 오귀속**(+ free-pricing); (b) `registry_capabilities_for_provider_config` fallback이 `nous → openai_compat_chat_extended_capabilities`를 주어 uncatalogued 로컬 모델에 `supports_reasoning`/`extended_thinking`/`reasoning_budget` **권한 인플레이션**. 자기 `.mli` 계약(§69-78 "stable kind-derived label")과 `capabilities.ml:388-409` declaration-over-probing 철학에 모순. | medium |

**조치**: `is_local → "nous"` 특례 삭제. 현재 typed 계약에는 locality로 선택되는 legacy carrier가 없다. 호출자가 `Provider_config.make`의 `kind`, `provider_id`, `base_url`, `request_path`, credential을 명시하고, `Provider_config.is_local`은 loopback 여부만 투영해야 한다. provider identity·capability·pricing·auth는 locality에서 추론하지 않는다.

### P3 — Borderline (경화 / 일관성, 낮은 우선순위)

| # | 위치 | 증상 | 조치 |
|---|------|------|------|
| B4 | `provider_config.ml:199` `base_url_targets_ollama_cloud` | vendor-canonical `ollama.com`은 정당하나 loose `String.starts_with` prefix라 `https://ollama.com.attacker.example` look-alike가 `ollama_cloud` namespace 상속. 형제 `base_url_targets_openai`(205)·`openai_host_supports_output_schema`(789)는 이미 `Uri.host` 정확 비교. | prefix → `Uri.host` 파싱 후 `= "ollama.com" || ends_with ".ollama.com"`. |
| B5 | `discovery.ml` endpoint capability inference | unknown model id, URL/port, `/api/show` template를 근거로 generic endpoint에 capability를 부여했다. | **hard cut** — caller가 `endpoint_protocol`과 catalog capability를 선언한다. Discovery는 objective `/props` 값만 overlay하며 malformed probe는 endpoint-local failure로 반환한다. |
| B6 | `capabilities.ml:761` `apply_manifest_entry` | manifest 오타 `base_label`이 `capabilities_for_provider_label = None`을 거쳐 **경고 없이** `default_capabilities`로 붕괴. 형제 필드 핸들러(805·856)는 `Diag.warn`함. 함수 docstring 자체가 fail-closed를 명시. host 무관(config→capability), 권한 손실이라 low. | **false-positive로 강등, 조치 없음** — 이미 fail-closed(권한 상승 아님)라 §4/§7 재감사에서 기각. |
| B7 | `complete_sampling.ml:57` `openai_compat_should_default_min_p` | capabilities 미상일 때 `None → is_local`로 min_p default 결정. host locality가 sampling default 선택. `config.min_p` 명시값 우선이라 blast radius 최소. | 명시 runtime/model capability 우선; 미상이면 미설정 또는 선언된 runtime kind로 키잉. |

### Legit 32건 (대조군 — 변경 없음, 경계의 정답례)

- `ollama.com → ollama_cloud`(`provider_config.ml:211`) — vendor-canonical host==provider (case a).
- `zai_catalog.ml` `is_zai/is_coding_base_url` — 정확 `Uri.host` 등가 + path prefix + env override, look-alike 거부 테스트 핀 (a+c).
- `http_client.ml:242` `cdn_per_header_limit_bytes = 8192` — RunPod/Cloudflare edge per-header-line 한계를 host-gate 없는 generic 전송 상수로, 진단에만 (b). **B1/B2가 어떻게 달랐어야 하는지의 정답.**
- `Provider_config.make` + `Provider_config.is_local` — caller가 typed provider identity·wire·credential을 명시하고 locality는 loopback 투영으로만 유지한다. capability·pricing·auth 정책은 locality에서 파생하지 않는다 (b).
- `request_path_targets_responses_api`(832) + `validate_request_path`(842) — path가 실제 API envelope 결정, 정확 문자열 등가 + exhaustive match fail-closed (c).

## 4. Migration

1. namespace provenance를 명시 선언으로 도입 (`model_id` prefix 또는 config 필드). PR #2404(declarative override SSOT)와 정렬.
2. `base_url_targets_runpod_proxy → "runpod_mtp"`(B1/B2) 및 `is_local → "nous"`(B3)를 포함한 모든 generic-host→capability 매핑 삭제.
3. host-결합 namespace를 serving-contract 식별자로 rename.
4. P3 경화 — 적대적 재감사(#2414) 후 착지: **B4**=ollama `Uri.host` 정확 비교(#2420), **B7**=min_p를 `is_local` 대신 catalog-declared로(#2425), **model_catalog**=unknown TOML 키 fail-closed(#2426), **:840**=unknown base label parse-time fail-closed(이 PR). **B5는 후속 hard cut으로 제거**되어 discovery가 protocol/catalog declaration만 소비한다. **B6는 이미 fail-closed라 조치 없음**.
   **B4'(:804 host→output_schema capability)는 설계 변경 필요로 defer**(§7 참조).
5. §5 ratchet 추가로 재발 차단 — **#2419 착지**(hardening ratchet 확장).

## 5. Ratchet (RFC-OAS-022/023 미러) — 구현: PR #2419

초안은 standalone `scripts/ci-endpoint-capability-ratchet.sh` +
`.ci/endpoint-capability-baseline.json`을 제안했으나, **기존 production hardening
ratchet**(`scripts/hardening-ratchet.sh`, RFC-OAS-023)에 metric 1개를 추가하는
방식으로 구현했다. scan/waiver/baseline/reporting 인프라를 재사용해 중복
(anti-pattern #1 scattered infra)을 피한다. 이미 `model_id_string_classifiers_outside_catalog`라는 정확한 대칭 metric이 존재한다.

- **`base_url_host_fuzzy_classifiers`** (`.ci/hardening-baseline.json`) —
  `base_url`/`host`/`Uri.host`에 대한 fuzzy `String` 매칭
  (`starts_with`/`ends_with`/`contains`/`is_substring`) 사이트 수를
  monotone-decrease 고정. baseline = 기존 `ollama.com` 매처(B4 reducible debt),
  이후 증가 금지.
- 판정 경계: exact `String.equal (Uri.host …) "vendor"`
  (vendor-canonical identity)와 정규화(`lowercase_ascii`/`trim`)는 **제외** →
  legit 패턴 오탐 없음. `is_local`(hand-rolled `String.sub`)도 transport
  predicate라 제외.
- **차단 실증 (mutation test)**: #2374의
  `String.ends_with ~suffix:".proxy.runpod.net" host` 주입 시 count가 baseline을
  초과해 `--check`가 FAIL(+1) → revert 시 OK. 원칙 RFC만으론 못 막던 host→capability
  재도입을 기계적으로 차단(#2374·#2408이 재발 실측).

baseline은 신규 metric만 수술적으로 add한다. 나머지 hardening metric은 drift로
stale-high(monotone-safe)이며, 전체 rebaseline은 별도 hygiene 작업으로 분리.

## 6. Verification (완료 정의)

- **provider/model tuple 회귀 테스트**: 동일 explicit `provider_id` + bare `model_id`가 endpoint 위치와 무관하게 동일 capability로 resolve됨을 assert. Provider identity는 endpoint가 아니라 config에 직접 실어야 한다.
- generic-host→capability 사이트 0건 (§5 ratchet green).
- vendor-canonical/transport/path-protocol 사이트는 유지되되 근거를 코드 주석 또는 RFC로 명시.
- `ocamlformat --check` clean, 기존 test suite green.

## 7. Related

- **RFC-OAS-023** capability axis reshape — 034는 그 원칙(model × transport)의 집행. 023이 축을 정의하고 034가 host-유도 위반을 금지.
- **RFC-OAS-022** monotone-decrease ratchet — §5가 script/workflow shape를 미러.
- **RFC-OAS-018** provider-model catalog externalization — namespace의 선언 출처가 catalog임을 전제.
- **PR #2404** declarative override SSOT — B1/B2/B3의 root fix가 안착할 기반.
- **PR #2374, #2408** — 본 RFC가 흡수하는 트리거 (host→capability namespace, 중복 구현).
- AI 코드 생성 안티패턴 3종(§1.1의 재발 논의가 근거하는 분류): #1 scattered hardcoded defaults(같은 설정값이 여러 파일에 리터럴로 산포), #2 unknown → permissive default(모르는 입력을 에러 대신 편리한 기본값으로 매핑 — 본 RFC의 B1-B7이 정확히 이 패턴), #3 boundary violation(하위 모듈이 상위 소비자의 타입/모듈을 참조).

### 구현 현황 (추적 이슈 #2414)

| finding | 상태 | PR |
|---|---|---|
| B3 `is_local → "nous"` 중립화 | merged | #2415 |
| §5 ratchet (`base_url_host_fuzzy_classifiers`) | Draft | #2419 |
| B4 ollama `Uri.host` 정확 비교 | Draft | #2420 |
| B7 min_p catalog-declared (host 비의존) | Draft | #2425 |
| model_catalog unknown 키 fail-closed | Draft | #2426 |
| B5 discovery / B6 manifest | false-positive (미구현) | — |
| :840 (unknown base label → silent default) | Draft — 기존 `Capability_vocab` SSOT 패턴으로 catalog+manifest parse fail-closed (설계 변경 아님) | 이 PR |
| B4'(:804 host→output_schema) | defer (override 우선이라 fallback 제거 시 behavior 파손 → catalog-declared 마이그레이션) | — |
| B1/B2 (#2374·#2408 흡수) | Draft — namespace `runpod_mtp`→`vllm-qwen3-mtp` rename + host-불변 회귀 테스트. #2374·#2408은 불필요(명시 선언 경로가 이미 작동)로 close | 이 PR |
