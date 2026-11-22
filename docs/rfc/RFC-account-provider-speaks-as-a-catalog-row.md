---
rfc: "account-provider-speaks-as-a-catalog-row"
title: "계정 provider 는 catalog 행 하나로 말한다"
status: Draft
created: 2026-11-18
updated: 2026-11-18
author: claude
supersedes: []
superseded_by: null
related: ["exact-request-waits-only-for-a-seat"]
---

# 계정 provider 는 catalog 행 하나로 말한다

코드 위치는 main `5747d24d9a4f4` 기준이다. 이 RFC 가 병합되고 구현되면 이슈 #53022 가 닫힌다.

## 0. 요약

운영자는 Anthropic API 계정마다 provider 를 하나씩 둔다.
예를 들면 `claude_a` 와 `claude_b` 이고, provider 마다 자기 API key 를 쓴다.
Keeper 턴은 이 provider 들로 잘 돈다.
그런데 Exact lane 의 slot 으로 넣으면 부팅이 그 slot 을 버린다.
남는 것은 경고 한 줄이다.

까닭은 하나다.
Exact slot 은 model catalog 의 provider 행을 provider id 로 찾는다.
catalog 의 Claude 행은 `claude` 하나다.
`claude_a` 라는 행은 없다(§1.1).

masc 는 runtime provider 의 id 를 두 가지 뜻으로 쓴다.

- catalog 에서 행을 찾는 열쇠
- 계정을 나누는 이름

catalog 행과 id 가 같은 provider 에서는 두 뜻이 겹친다.
계정 provider 에서는 두 뜻이 갈라진다.
지금 코드는 갈라지는 경우를 표현하지 못한다(§1.2).

이 RFC 는 규칙 하나를 세운다.

> provider 는 자기가 말하는 catalog 행을 `catalog-provider` 로 적을 수 있다. catalog 를 찾는 곳은 그 행을 쓰고, 계정을 나누는 곳은 runtime provider id 를 그대로 쓴다.

```toml
[providers.claude_a]
catalog-provider = "claude"
exact-body-timeout-s = 1200.0
[providers.claude_a.credentials]
type = "env"
key = "ANTHROPIC_API_KEY_A"
```

이렇게 적은 `claude_a.claude-haiku-5-5` 는 Exact slot 이 된다.
자리, 쉼, quota 는 `claude_b` 와 섞이지 않는다.
이것들은 이미 provider id 가 아니라 key 와 runtime id 로 나뉘어 있기 때문이다(§1.4).

설치 검사도 고친다.
지금 검사는 부팅이 버릴 Exact slot 을 보지 못한다(§1.5).
고친 뒤에는 그런 slot 을 거절한다.

## 1. 지금 일어나는 일 (2026-11-18)

### 1.1 Exact slot 은 catalog provider 행을 id 로 찾는다

- Exact resolver 는 binding 의 `Provider_config.provider_id` 를 `provider_ref` 로 받는다(`packages/agent_core/lib/llm_provider/exact_output_resolver.ml` 637~645행).
- `resolve_exact` 는 catalog provider 행 가운데 `entry.id` 가 `provider_ref` 와 같은 것을 찾는다(`exact_output_catalog_binding.ml` 137~143행).
- catalog 에서 Anthropic API 를 말하는 행은 `id = "claude"` 하나다(`packages/agent_core/models.toml` 2688행~). 이 행은 `serves_bare_models` 로 `claude-haiku-5-5` 같은 맨 모델 id 를 받는다.
- 행을 찾으면 그 뒤 Exact 단계는 모두 catalog 행 id 를 쓴다. 고정된 target config 도 `~provider_id:provider.id` 로 catalog 행 id 를 담는다(`exact_output_resolver.ml` 844~861행).

### 1.2 masc 는 runtime provider id 를 catalog id 로 넘긴다

`lib/runtime/runtime_adapter.ml` 에서 runtime provider id 가 catalog 를 찾는 열쇠로 쓰이는 곳은 여섯이다.

| 행 | 하는 일 |
|---|---|
| 140 | `Declarations.find declarations provider_id`: 이 provider 가 API key 를 요구하는지 |
| 375 | `Declarations.find declarations provider.id`: `http_protocol_metadata`(kind, request path) |
| 773~774 | `Declarations.supports_parallel_tool_suppression ~provider_id:provider.id` |
| 776 | `Declarations.find declarations provider.id`: `provider_config_from_declared_provider` |
| 795~796 | `resolve_snapshot_request_policy ~provider_id:provider.id`: capability, 가격, thinking 제어 |
| 851 | `Provider_config.make ~provider_id:provider.id`: Agent-Core 가 catalog 를 고르는 열쇠이자 Exact resolver 가 행을 맞추는 값 |

이 여섯이 바뀌면 따라 바뀌는 곳이 있다.

- `runtime_instance.ml` 246~250행 `capabilities_for_runtime`
- `runtime.ml` 304·314행 `missing_runtime_model_capabilities`
- `runtime_wizard_inventory.ml` 3행 `http_fields`
- `runtime_setup_spec.ml` 351행
- `prompt_preset.ml` 1021행

catalog 행과 id 가 같은 provider 에는 `kind` 를 적을 수 없다. 적으면 binding 이 빠진다(`runtime_adapter.ml` 212~216행, "the AGENT_CORE catalog has a row for it and owns that fact").
이 판단은 parse 가 아니라 materialize 에서 한다(`runtime_toml_providers.ml` 469~676행 `parse_provider` 는 catalog 를 보지 않는다).

### 1.3 계정 provider 는 catalog 가 아는 것을 손으로 다시 적는다

catalog 행이 없는 계정 provider 는 Anthropic 의 사실을 손으로 다시 적는다.

- provider 표: `kind = "anthropic"`, `request-path`, `endpoint`
- 모델 행마다: `capabilities` 표와 `temperature`

`capabilities` 표가 없으면 부팅이 그 runtime 을 버린다.

- `Runtime.missing_runtime_model_capabilities` 가 catalog 가 capability 를 주지 않는 runtime 을 모은다(`runtime.ml` 298~328행).
- `prepare_degraded_loaded` 가 그것을 뺀다(`runtime.ml` 1099~1124행).
- 모델 행의 `capabilities` 표는 catalog 대신 쓰는 override 가 된다(`runtime_adapter.ml` 526~541행).

그래서 Keeper 턴은 돈다.
Exact 는 이 override 를 받지 않는다. §1.1 의 provider 행 대조에서 먼저 떨어진다.
부팅 로그에는 `Declared_target_binding_rejected` 경고 한 줄이 남는다(`runtime.ml` 2301~2306행).

### 1.4 계정은 provider id 로 나뉘지 않는다

계정을 나누는 것들은 모두 provider id 말고 다른 값으로 나뉜다.

- **자리(admission)**: 열쇠는 `(kind, base_url, API key 의 identity)` 다(`provider_admission.ml` 15~19행, `provider_admission_state.ml` 9~13행). provider id 는 들어가지 않는다.
- **quota 창**: 열쇠는 materialize 때 고정한 `Runtime_quota_window.scope` 다(`runtime_credential_selection.ml` 54~57행, `runtime_adapter.ml` 821행).
  - env 자격이면 그 변수 이름이다(`Credential_env`).
  - 파일 자격이면 그 경로다(`Credential_file`).
  - inline 이거나 자격이 없을 때만 runtime provider id 를 쓴다(`Provider_row`).
- **slot 쉼(backpressure)**: slot 은 runtime id(`<provider>.<model>`)로 찾는다(`runtime.ml` 907행). 쉼 상태는 runtime 마다 가진 칸에 쌓인다(`runtime_instance.ml` 185~197행).
- **그 칸이 다시 게시 뒤에도 남는지**: `Binding_identity.equal` 로 판단한다. 이 비교는 endpoint, request path, 인증 방식, credential scope, key identity 를 모두 본다(`packages/agent_core/lib/binding_identity.ml` 83~92행).
- **응답 cache**: 열쇠에 `api_key_identity` 와 `base_url` 이 든다(`llm_provider/cache.ml` 33·111행).

Agent-Core 안에서 `provider_id` 를 읽는 곳은 40곳이다.
- 그 가운데 계정을 나누는 데 쓰는 곳은 둘이다(`binding_identity.ml` 35~36행, `cache.ml`).
- 둘 다 key identity 를 같이 본다.
- provider id 만으로 두 계정을 하나로 묶는 곳은 없다.

### 1.5 설치 검사는 버려질 slot 을 보지 못한다

설치 검사(`bin/deployment_preflight_helper.ml` 1104~1230행)는 다음을 거절한다.

- Keeper 설정 schema 오류, `Runtime.validate_config_text`, Fusion 표
- catalog 가 capability 를 주지 않아 빠질 runtime(`Initialized_degraded`, 1207~1211행)
- `exact-body-timeout-s` 가 없는 Exact slot(1212~1217행)
- `check_exact_output_registry`(1218행)

마지막 검사는 꺼진 필수 lane 과 slot 이 하나도 없는 필수 lane 만 거절한다(`runtime_exact_output_registry.ml` 370~394행).
`check_publication` 은 resolver 가 버린 slot 목록(`rejected_slots`)을 받고도 버린다(같은 파일 432~435행).
그래서 다른 slot 이 남은 lane 은 통과한다. 필수가 아닌 lane 은 그렇게 비어도 통과한다.

2026-11-18 운영에서 Librarian lane 에 계정 slot 을 넣으려다 이 문제에 닿았다.
설치 검사는 body deadline 만 지적했다.
deadline 을 적었더라도 부팅이 그 slot 을 버렸을 것이다.

## 2. 규칙

1. provider 는 `catalog-provider = "<catalog 행 id>"` 를 적을 수 있다. 적지 않으면 지금처럼 provider id 가 곧 catalog 행 id 다.
2. catalog 를 찾는 곳은 모두 한 함수에서 catalog 행 id 를 얻는다. 그 함수는 `catalog-provider` 가 있으면 그 값을, 없으면 provider id 를 준다.
3. 계정을 나누는 곳은 runtime provider id 와 자격을 그대로 쓴다. 자격 materialize, quota scope, runtime id, 쉼 칸, 자리가 그렇다.
4. `catalog-provider` 를 적은 provider 는 id 가 그 행인 provider 와 같은 규칙을 받는다. `kind` 는 catalog 의 몫이라 적으면 로드가 거절된다(§3.1). `request-path` 와 `endpoint` 는 지금처럼 적으면 catalog 값 대신 쓰인다.
5. 설치 검사는 부팅 때 Exact registry 가 버릴 slot 을 까닭과 상관없이 모두 거절한다.

## 3. 설계

### 3.1 키

- `Runtime_schema.provider` 에 `catalog_provider : string option` 을 더한다(`runtime_schema.ml` 143행 근처).
- `runtime_toml_providers.ml` 의 `provider_keys`(460~466행)에 `catalog-provider` 를 더한다. 값은 빈 문자열이 아닌 한 줄 문자열이다.
- 거절은 넷이다. 모두 `drop_reason` 의 `Catalog_provider_refused { provider_id; catalog_provider; refusal }` 하나로 모이고, `refusal` 은 닫힌 타입 `catalog_provider_refusal` 이다. `dangling_reference_reason` 이 이것을 `Some _` 로 돌려주므로 `Runtime.load_list` 에서 로드 오류가 된다. 오타를 binding 하나 빠지는 것으로 넘기지 않는다.
  - **없는 행**(`Names_no_row`): catalog 에 그 id 의 provider 행이 없다.
  - **자기 id 가 이미 catalog 행**(`Beside_own_row`): provider id 가 catalog 행인데 `catalog-provider` 도 적었다. 한 provider 가 두 행으로 말할 수 없다.
  - **다른 표기**(`Names_alias row_id`): catalog 조회(`Catalog_snapshot.find`)는 별칭과 대소문자가 다른 표기도 받는다. 그런데 exact-output resolver 는 행 id 를 글자 그대로 맞춘다. 그래서 `"Claude"` 는 로드되고 Exact lane 에서만 빠진다. 행 id 를 그대로 적게 거절하고, 적을 id 를 알려 준다.
  - **catalog 의 몫을 적음**(`Beside_kind`): `kind` 를 같이 적었다. 처음 판(#53030)은 id 가 catalog 행인 provider 처럼 binding 만 뺐다. 그런데 기존 계정에 `catalog-provider` 만 더하고 `kind` 를 남기는 실수가 가장 흔할 것이고, 빠진 binding 은 보고만 남는다. 운영자가 고른 선택을 두 번 적은 것이라 로드 오류로 올린다(#53030 리뷰).
- 거절 검사는 binding 을 만드는 construction 과 같은 catalog snapshot 을 읽는다. 두 번 읽으면 그 사이 catalog 가 다시 게시될 때 검사와 binding 이 다른 답을 낸다.
- 검사는 켜진 binding 이 가리키는 provider 만 본다. 어느 binding 도 쓰지 않는 `[providers.x]` 행을 따로 검사하지 않는 것과 같다.
- `request-path` 와 `endpoint` 는 지금 id 가 catalog 행인 provider 에서처럼 적어도 된다. 적으면 catalog 값 대신 쓰인다(`runtime_adapter.ml` 324~325행). 운영의 `[providers.claude]` 가 이미 `endpoint` 를 적는다.
- `catalog-provider` 는 HTTP provider 만 적는다. official client 가 적으면 parse 가 거절한다. official client 는 catalog 의 wire 행으로 말하지 않는다.

### 3.2 catalog 행 id 는 한 함수로만 읽는다

```ocaml
(* Runtime_schema *)
let catalog_provider_id (provider : provider) =
  Option.value provider.catalog_provider ~default:provider.id
```

- §1.2 의 여섯 곳이 모두 이 함수를 지난다.
  - 140, 375, 773, 776, 795행의 catalog 조회
  - 851행의 `Provider_config.make ~provider_id`
- 851행을 바꾸면 `Provider_config.provider_id` 는 catalog 행 id 가 된다.
  - Agent-Core 는 이 필드를 catalog 를 고르는 열쇠로 쓴다(`provider_runtime_binding.ml` 102~110행도 catalog declaration id 를 넘긴다).
  - 그래서 계정 provider 에서도 이 필드의 뜻이 Agent-Core 의 계약과 맞는다.
- `runtime_setup_spec.ml` 518~524행은 runtime 행 id 를 catalog id 로 쓴다. 이곳도 같은 함수를 지난다.
- `server_runtime_setup_actions.ml` 501·523·539행은 설치 선택지의 id 를 catalog id 로 넘긴다. 이 층에서는 그대로 둔다(§9).
- 사용처를 소스 문구 검사로 막지 않는다. 헌법은 기능 고장과 이어지지 않는 문구 검사를 만들지 않게 한다.
  - catalog 조회 함수가 private 타입만 받게 하려면 Agent-Core `Declarations` API 를 바꿔야 한다. 이 RFC 범위 밖이다.
  - 대신 행동 시험이 catalog 대조 경로를 잡는다. 계정 slot 이 Exact lane 에 남는지, quota 창이 계정마다 따로인지를 본다. 851행을 계정 id 로 되돌리면 이 시험이 실패한다.

### 3.3 계정은 그대로 나뉜다

바꾸지 않는 곳:

- `runtime_adapter.ml` 821행 `materialize_credentials_from_declaration ~provider_id`
  - quota scope 가 env 변수나 파일 경로로 정해진다.
  - inline 자격일 때만 runtime provider id 를 쓴다.
  - 계정 provider 는 env 나 파일 자격을 쓰므로 계정마다 다르다.
- runtime id: `claude_a.claude-haiku-5-5`, `claude_b.claude-haiku-5-5` 로 계정마다 다르다.
- 쉼 칸과 `Binding_identity`: endpoint 와 key identity 를 같이 보므로 계정마다 다르다.
- 자리: key identity 가 다르므로 계정마다 다르다.

### 3.4 설치 검사

- `check_publication` 은 버린 slot 을 버리지 말고 돌려준다.
- 설치 검사는 그 목록이 비어 있지 않으면 거절한다. 거절 문구는 lane, 자리 번호, slot id, 까닭을 적는다.
  - 까닭은 `Declared_target_binding_rejected` 와 `Configured_runtime_only` 같은 이미 있는 진단이다(`runtime.ml` 2298~2310행).
- 부팅은 지금처럼 그 slot 을 빼고 뜬다. 운영 중인 서버를 config 하나 때문에 멈추지 않는다.
- 이 규칙은 `catalog-provider` 와 따로 서 있다. 그래서 따로 된 층으로 낸다(§7).

## 4. 따라가 보기

운영자가 Librarian lane 의 HTTP slot 끝에 `claude_a.claude-haiku-5-5` 와 `claude_b.claude-haiku-5-5` 를 넣었다.

### 4.1 부팅

1. 두 provider 는 `catalog-provider = "claude"` 를 적었다.
2. 851행이 `Provider_config.provider_id = "claude"` 로 만든다. API key 는 각자의 env 변수 값이다.
3. `resolve_exact` 가 `claude` 행을 찾는다. 두 slot 모두 lane 에 남는다.
4. capability 는 catalog 의 `claude-haiku-5-5` 에서 온다. 모델 행에 손으로 적은 `capabilities` 표가 있으면 지금처럼 override 로 쓰인다.

### 4.2 A 계정이 한도에 걸렸다

1. 걷기가 `claude_a` slot 에 간다.
2. 거절이 reset 시각을 담은 429 라면, backpressure 가 그 runtime 의 칸을 쉬게 한다. 칸은 runtime id 로 찾는다. `claude_b` 의 칸은 그대로다. 다음 걷기는 쉬는 `claude_a` 를 건너 `claude_b` 로 간다.
3. 거절이 bare HTTP 400 이면 쉼이 생기지 않는다(RFC exact-request-waits-only-for-a-seat §5). 2026-11-18 에 사용량 한도에 걸린 key 가 이렇게 답했다.
   - 걷기는 그 방문을 실패로 치고 같은 걷기 안에서 `claude_b` 로 간다. 요청은 답을 받는다.
   - 대신 걷기마다 `claude_a` 에서 1초 남짓한 호출을 하나씩 버린다. 그래서 이런 key 는 운영자가 lane 에서 빼야 한다.
   - 이 RFC 는 이 점을 바꾸지 않는다.

### 4.3 두 계정이 같은 순간에 자리를 찾는다

자리 열쇠는 key identity 를 담는다. 두 계정은 서로 다른 줄에 선다. 한 계정의 `max-concurrent` 는 다른 계정의 자리를 쓰지 않는다.

### 4.4 운영자가 `catalog-provider = "claud"` 로 잘못 적었다

로드가 거절된다. 문구는 provider 와 없는 행 id 를 적는다. 설치 검사도 같은 문구로 멈춘다.

## 5. 대가

- **관측 칸 하나가 계정을 잃는다.**
  - 자리 대기 사건 `masc.provider_admission.waited` 는 provider 칸에 `Provider_config.provider_id` 를 싣는다(`provider_admission.ml` 213행, `lib/provider_admission_events.ml` 23행). 계정 provider 의 이 칸은 모두 `claude` 가 된다.
  - 이 칸으로 나눠 세는 런타임 코드는 없다.
  - Exact receipt 의 provider 칸도 이미 catalog 행 id 를 싣는다(§1.1). slot id 는 runtime id 라서 계정을 담는다.
- **같은 모델로 본다.** `Runtime_response_identity.same_model_identity`(`types/runtime_response_identity.ml` 56행)는 `claude_a` 와 `claude_b` 의 같은 모델을 같은 모델로 보게 된다. 지금은 다른 모델로 본다. 모델이 같으니 이쪽이 맞다고 본다.
- **운영자가 고칠 것이 있다.**
  - 계정 provider 에서 `kind` 를 지우고 `catalog-provider` 를 적는다. `request-path` 는 catalog 값과 같으면 지워도 된다.
  - Exact slot 으로 쓸 provider 에는 `exact-body-timeout-s` 를 적는다.
  - 고치지 않은 provider 는 지금과 똑같이 돈다. 하드컷이 아니다. 새 키가 없으면 뜻도 없다.
- **두 가지 적는 법이 남는다.** 손으로 `kind` 를 적는 provider 는 catalog 에 없는 endpoint 에 계속 필요하다. Anthropic 계정은 `catalog-provider` 를 쓰는 쪽이 맞다고 문서에 적는다.

## 6. 바뀌는 계약과 문서

- `Runtime_schema.provider` 에 `catalog_provider` 필드가 생긴다.
- `Runtime_config_error.drop_reason` 에 `Catalog_provider_not_declared` 와 `Catalog_provider_beside_own_row` 가 생긴다. 이 타입을 `match` 하는 곳은 모든 경우를 다 따지므로 컴파일러가 빠진 곳을 알려 준다.
- `Provider_config.provider_id` 는 masc 가 만든 config 에서도 catalog 행 id 다.
- `Runtime_exact_output_registry.check_publication` 이 버린 slot 을 돌려준다.
- 문서
  - `docs/guides/provider-admission-fairness.md` 에 계정 provider 예와 `catalog-provider` 를 더한다. provider 표의 키를 모은 안내는 따로 없다.

## 7. 구현 층

| 층 | 내용 | 확인 |
|---|---|---|
| L1 | `catalog_provider` 필드와 parse, `catalog_provider_id` 함수, §3.1 의 거절 셋 | 거절마다 시험. 없는 행이 로드 오류가 되는지 |
| L2 | §3.2 의 사용처가 모두 그 함수를 지난다 | `catalog-provider` 를 적은 계정 slot 이 Exact lane 에 남는 시험. 두 계정의 자리와 쉼이 섞이지 않는 시험 |
| L3 | `check_publication` 이 버린 slot 을 돌려주고 설치 검사가 거절한다 | 계정 slot 에 `catalog-provider` 가 없는 runtime.toml 을 설치 검사가 거절하는 시험 |
| L4 | 문서와 changelog Upgrade notes | `changelog-fragments.py check` |

L1 과 L2 는 한 배포로 나간다. L1 만 나가면 키는 받고 뜻은 없다.

## 8. 대안

### 8.1 catalog 파일을 통째로 갈아 끼운다

`AGENT_CORE_MODEL_CATALOG` 로 catalog 전체를 바꾸고 계정마다 provider 행을 더한다.

- 장점: 코드를 바꾸지 않는다.
- 단점: 운영자가 catalog 사본을 따로 들고 원본을 손으로 따라가야 한다. 운영 안내 문서도 없다. 계정이 늘 때마다 catalog 행이 는다.

### 8.2 endpoint 로 catalog 행을 맞춘다

계정 provider 의 `kind`·`endpoint`·`request-path` 가 catalog 행과 같으면 그 행으로 본다.

- 장점: 운영자가 아무것도 적지 않아도 된다.
- 단점: 같은 wire 를 쓰는 다른 행이 있다. `deepseek-anthropic` 은 `claude` 와 같은 kind 와 request path 를 쓰고 다른 모델을 답한다. 맞추기는 추측이다. 운영자가 적은 선언을 읽는 편이 낫다.

### 8.3 catalog 에 계정마다 행을 더한다

- 단점: 계정은 운영자의 사실이다. 저장소의 catalog 는 계정을 모른다.

### 8.4 provider 하나에 API key 여러 개를 둔다

이슈 #53023 이다. provider 하나가 key 목록을 돌려 쓴다.

- 장점: catalog 대조를 건드리지 않는다.
- 단점: 자격은 지금 한 provider 에 하나다(`runtime_schema.mli` 40~43행 `Env | File | Inline`). 자리, quota, 쉼, runtime id 가 모두 key 하나를 전제로 한다. 바뀌는 범위가 이 RFC 보다 넓다.
- 사용자가 2026-11-18 에 "지금은 아니고 TODO" 로 정했다.

### 8.5 `Provider_config` 에 `catalog_provider_id` 필드를 따로 둔다

`Provider_config.provider_id` 는 계정 id 로 두고, catalog 를 고를 때만 새 필드를 읽는다.

- 장점: §5 의 관측 칸이 계정을 지킨다.
- 단점: Agent-Core 안에서 catalog 를 고르는 15곳이 모두 새 필드로 옮겨야 한다. 한 곳이라도 남으면 그곳은 계정 id 로 catalog 를 찾다가 조용히 실패한다. 지금 필드의 뜻(catalog 를 고르는 열쇠)을 바꾸지 않는 이 RFC 쪽이 범위가 좁다.
- 관측 칸이 계정을 다시 담아야 하면, 자리 대기 사건에 runtime id 를 더하는 편이 범위가 좁다.

## 9. 확인하지 못한 것

- 설치 마법사가 Anthropic 계정을 하나 더 만들 때 무엇을 쓰는지 보지 않았다. 지금 setup 은 이름 있는 provider(`claude`)를 그 id 로 쓴다(`runtime_setup_spec.ml` 458~468행). 같은 이름의 두 번째 계정을 만들 수 있는지, `catalog-provider` 를 써야 하는지는 이 RFC 범위 밖이다.
- `runtime_wizard_inventory.ml` 98~102·137행은 runtime 행이 catalog 원형과 같은 id 면 원형을 숨긴다. `catalog-provider` 를 적은 provider 가 원형을 숨겨야 하는지는 정하지 않았다. id 가 다르므로 지금 코드로는 숨기지 않는다.
- `provider_kind_resolver.ml` 25행의 호출자를 세지 않았다.
- `server_runtime_setup_actions.ml` 501·523·539행이 넘기는 설치 선택지 id 가 runtime 행 id 일 수 있는지 보지 않았다. 그럴 수 있다면 그 행의 `catalog-provider` 를 읽어야 한다.
- 설치 스크립트가 마법사 기록의 `id` 를 어떻게 쓰는지(`bin/main_eio.ml` 2055·2070·2091행) 보지 않았다.
- `Provider_config.make` 는 `provider_id` 를 소문자로 바꾼다. `resolve_exact` 는 `String.equal` 로 그대로 비교한다. catalog 행 id 가 모두 소문자라서 지금은 문제가 없다.
- 운영 계정 key 가 크레딧을 가졌는지는 이 RFC 와 상관없이 따로 확인해야 한다. 크레딧 없는 key 는 매번 바로 실패해서, 자리가 늘 빈 slot 이 된다(RFC exact-request-waits-only-for-a-seat §5).
