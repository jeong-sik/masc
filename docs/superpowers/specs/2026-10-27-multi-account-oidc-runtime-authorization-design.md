# 다계정 Google OIDC·Provider·Runtime 권한 설계

- 날짜: 2026-10-27
- 상태: 적대 설계 리뷰 대상. 구현·배포 승인이 아니다.
- 관련 Board: `p-01a8be37d38b1cd54c79d05233308911`, 종합 `c-8484f100744604fd48f85b31104bf3f9`
- 코드 대조: `fdda2724cbabc12db0de606ede72496430bc0f1c`

이 문서는 이전 v2~v2.6.6 댓글과 리뷰를 하나의 상태 모델로 다시 구성한다. 이전 댓글의 개별 문장이 아니라 이 문서가 새 설계 기준이다. PASS는 구현이나 실측이 아니라, 아직 받지 않은 이 문서의 독립 설계 판정이다.

## 1. 사용예와 현재 차이

한 머신에서 MASC를 실행하고, 초대받은 사용자만 Google OIDC로 Dashboard에 로그인한다. 각 사용자는 자신의 Codex 또는 Claude Code 구독을 등록하고 기본적으로 본인만 Runtime을 사용한다. 필요하면 credential이 아니라 특정 Runtime의 실행 권한만 공유한다.

현재 코드는 이 사용예를 그대로 지원하지 않는다.

- Dashboard는 `dashboard/src/api/core.ts:194-208`에서 저장한 bearer를 `Authorization`에 붙인다. Keeper 외부 서비스 OAuth(`lib/server/server_keeper_oauth.mli:1-12`)는 Dashboard 사용자의 Google OIDC 로그인과 다른 기능이다.
- 공식 계정 로그인은 `dashboard/src/api/setup-login.ts:22-29`에 있지만 `lib/server/server_setup_account_login.mli:1-4`가 `CanAdmin`을 요구한다. 일반 사용자의 개인 구독 등록 모델과 맞지 않는다.
- `lib/auth/auth.ml:204-225,303-318`은 `auth disabled` 또는 `workspace secret`을 Admin으로 허용한다. 초대받은 principal만 허용하는 모델과 충돌한다.
- `lib/auth/auth_strict_mode.ml:17-20`과 `lib/mcp_server_eio_caller_identity.ml:176-192`는 Strict라고 항상 거부하지 않고 로그 후 caller alias를 유지한다.
- `lib/server/server_mcp_transport_http_headers.ml:267-270`은 MCP cookie에 `Secure`와 `HttpOnly`가 없고 `SameSite=Lax`다.
- official client는 모델 호출과 내장 도구 루프를 소유하고 account-home을 사용한다. MASC가 중개하는 단일 provider 요청 모델을 그대로 적용할 수 없다.

## 2. 목표·비목표·반목표

### 목표

1. 초대한 사용자만 Google OIDC로 인증하고 `(iss, sub)`를 신원으로 사용한다.
2. ProviderAccount와 Runtime의 owner를 명확히 하고, owner가 아니면 관리·재인증·공유를 할 수 없게 한다.
3. credential이 아니라 Runtime의 `Use`만 공유하고, 사용자·Admin·Service/Keeper의 권한을 분리한다.
4. 직접 호출·Keeper·schedule·Board·retry·resume·Fusion·vision·failover에서 같은 인가 모델을 적용한다.
5. 회수·재기동·복원·모드 변경에서도 과거 허가가 부활하지 않게 한다.

### 비목표

- Google offline API access, Google access token의 MASC bearer 전환, 계정 링크·병합.
- credential/account-home/raw TOML/grant의 재공유와 재위임.
- Admin이 다른 사람의 credential을 읽거나 재인증하거나 private Runtime을 실행하는 기능.
- 임의 실행 TTL, 누적 turn/time/token/cost 상한, ProviderAccount의 가상 principal별 quota 분할.
- official client의 미검증 공유 실행.

### 반목표

- `account_ref`, Runtime ID, agent 이름, header, email이 권한을 대신하는 경로.
- `auth disabled`, anonymous mutation, legacy 공유 token, workspace secret을 이용한 Admin 승격.
- 복원된 Active grant·revocation 누락·오래된 credential을 그대로 실행하는 경로.
- owner의 일시적 부재가 무관한 Keeper까지 멈추는 전역 정지.
- 문서만으로 readiness를 선언하거나, 실제 인증·격리·두 계정 호출을 생략하는 출시.

## 3. 불변식

1. **credential은 항상 비공개다.** 공유는 특정 Runtime의 Use grant뿐이다.
2. **인가 principal은 검증된 credential record에서만 온다.** Actor_hint는 표시와 진단에만 쓴다.
3. **RuntimeGrant가 실행 권한의 유일한 SSOT다.** 소유권은 Self의 유효 조건이지 별도 인가 경로가 아니다.
4. **모든 외부 initiator의 기본값은 Deny다.** 빈 scope, 빈 channel, 빈 effect는 모두 Deny다. `All`도 현재 grant 안으로 제한된다.
5. **부여와 회수는 비대칭이다.** 새 Grant는 명시 commit이 필요하지만, 보안 회수가 끊기면 `Revocation_pending`으로 실행을 막는다.
6. **복원은 새 권한을 만들지 않는다.** backup·replay·고수위 일치만으로 실행을 승인하지 않는다.
7. **부분 실패를 숨기지 않는다.** `Outcome_unknown`, `Revocation_pending`, `AuthorizationUncertain`, `Quarantined`, `Purged`를 구분한다.
8. **판정은 닫힌 합타입으로 표현한다.** 문자열 비교나 이름으로 권한을 추정하지 않는다.
9. **owner의 부재는 그 의존 사슬만 막는다.** 다른 Cleared 사슬은 계속 실행할 수 있어야 한다.
10. **실제 증명이 없는 공유는 거부다.** lane·readiness·provider 호출·복구 증명이 없으면 다계정을 열지 않는다.

## 4. 주체와 레코드

### 4.1 Principal과 Admin

```text
Principal = Human(user_id) | Service(service_id)

Admin_assignment {
  principal: Human,
  status: Active | Revoked,
  role_epoch
}

WorkspaceMembership {
  workspace_id,
  principal,
  status: Active | Disabled,
  account_home_namespace,
  membership_epoch
}
```

- ID는 불변이며 삭제 후 재사용하지 않는다. `(iss, sub)`도 tombstone으로 남겨 재결속하지 않는다.
- Dashboard Admin은 활성 Human principal과 활성 Admin_assignment가 필요하다. 비밀 제시로 role을 만들지 않는다. Admin_assignment의 생성·회수·변경은 `role_epoch`로 기록하고 Admin 경로의 stream·관리 실행만 재평가한다. 개인 Self Runtime은 role 변경만으로 무효화하지 않는다.
- Service/Keeper에는 일반 Admin role이 없다. 필요한 경우 `ManageMachineShared`, `AdminDisableBlock`, `ReadAuditMetadata` 같은 닫힌 개별 권한만 부여한다.
- Admin은 다른 사람의 credential·private Runtime을 사용하지 못한다. Disable/Block/감사와 Service-owned 공유 관리만 한다.
- **Admin은 관리 권한으로 자기 자신 또는 자신이 관리하는 principal에게 grant를 만들거나 수정할 수 없다.** 감사에는 author·beneficiary·beneficiary manager를 남긴다. Admin이 Service-owned Runtime을 사용하려면 독립된 Service 관리 owner나 제2 승인자의 grant가 필요하다. 제2 승인자는 author와 다른 principal이며 author의 관리 대상이 아니어야 한다.

### 4.2 ProviderAccount와 Runtime

```text
ProviderAccount {
  id,
  owner: Principal,
  credential_ref: opaque,
  credential_generation,
  status: Active | Disabled | Quarantined | Purged,
  resource_epoch,
  revision
}

Runtime {
  id,
  owner: Principal,
  provider_account_id,
  resource_epoch,
  revision
}
```

- `Runtime.owner = ProviderAccount.owner`여야 하며 setup·raw TOML 저장·서버 부팅 때 모두 검사한다.
- Admin이라도 다른 사람의 ProviderAccount로 Runtime을 만들지 못한다. 개인 setup은 전역 default·lane·assignment를 바꾸지 않는다.
- provider hard quota는 ProviderAccount/account-home 범위로 유지하고 principal별 가상 quota로 나누지 않는다.
- Runtime ID·account_ref는 조회 키일 뿐 권한이 아니다. 다른 사람의 ID 존재·이름·오류는 projection으로 제한한다.

### 4.3 RuntimeGrant와 MachineSharePolicy

```text
RuntimeGrant =
  Self {
    id, runtime_id, grantee,
    allowed_effects, source_binding,
    grant_epoch, revision, status
  }
  | Delegated {
    id, runtime_id, grantee,
    allowed_effects, source_binding,
    share_policy_id: option,
    grant_epoch, revision, status, expires_at: option
  }

MachineSharePolicy {
  id,
  runtime_id,
  member_template_effects,
  approved_by: Admin,
  approved_at,
  revision,
  status
}
```

- `Self`는 `grantee = Runtime.owner`일 때만 유효하며 **Runtime 생성과 같은 append**로 만든다. 실행·조회 경로에서 생성하지는 않지만 인가 판정은 저장된 Self/Delegated를 읽어서만 한다.
- Human의 Keeper는 Self가 아니라 owner가 명시한 Delegated를 사용한다. Runtime–Keeper binding/profile 승인 시점에 만들고, Human에게 공유했다는 사실만으로 Keeper에 상속하지 않는다.
- **MachineShared는 wildcard가 아니라 `MachineSharePolicy + 승인된 사람별 Delegated`다.** 정책 자체는 실행 권한이 아니다. 미래 principal은 grant가 없으므로 자동 포함되지 않는다. 사람 추가는 해당 Delegated 생성, 제거는 그 grant의 회수다.
- `member_template_effects`는 신규 member grant 생성 시 초기값일 뿐 현재 정책의 권한이 아니다. 정책 수정으로 기존 member grant를 암묵 변경하지 않는다. 실제 효과 변경은 대상 grant를 지정한 `Grant_effect_update`로만 하며, 관련 행을 같은 append로 갱신한다.
- 전체 정책 회수·resource_epoch 상승·모든 연결 grant 회수는 같은 append다. member 추가는 revision만, member 제거는 해당 grant_epoch만 올린다.
- Service-owned Runtime의 Keeper용 Delegated는 Service 관리 owner 또는 Admin이 발급하지만 §4.1의 자기 승인 금지가 적용된다.
- UI의 Private/Granted/MachineShared와 `New_humans_excluded`는 grant에서 유도한다. Self는 공유로 세지 않는다.
- profile의 권한 관련 수정은 owner만 하며 연결된 grant의 effects와 revision을 같은 append로 바꾼다. 효과 제거는 해당 grant_epoch만 올려 다음 lease를 막고, 다른 grant나 principal은 건드리지 않는다.
- tombstone의 grant는 감사를 위해 `Revoked`로 남기고 실행하지 않는다. Purged 대상의 grant와 artifact도 `Purged`로 표시한다.

### 4.4 DelegatePolicy, PAT, scope

```text
Runtime_scope = Empty | All | Only of Runtime_id.Set

DelegatePolicy {
  id,
  initiator: Principal,
  executor: Principal,
  channels: Channel_set,
  runtime_scope: Runtime_scope,
  allowed_effects: Effect_set,
  policy_epoch,
  revision
}

Pat_scope {
  runtimes: Runtime_scope,
  channels: Channel_set,
  allowed_effects: Effect_set,
  expires_at: option
}

Authorization_scope {
  runtimes: Runtime_scope,
  channels: Channel_set,
  allowed_effects: Effect_set
}

ExecutionContext {
  initiator,
  executor,
  channel: Direct | Delegate | Schedule | BoardTrigger |
           Retry | Resume | Fusion | Vision | Verifier | Autonomous,
  stored_scope: Authorization_scope,
  pat_scope: Not_pat | Pat of Pat_scope
}
```

- `Empty`는 Runtime·channel·effect를 모두 허용하지 않는다. `All`은 현재 grant와 policy 안으로 제한한다. PAT 발급 UI는 명시적 범위를 요구한다.
- `Not_pat`은 PAT를 쓰지 않는 인증 방식이다. 교집합 계산에서는 `runtimes = All`, `channels = All`, `allowed_effects = All`인 중립 필터로 두지만 이것은 grant·policy·channel 검사를 면제하지 않는다. `Pat(Empty)`는 어떤 Runtime·channel·effect도 허용하지 않는다.
- PAT는 Runtime뿐 아니라 channel과 allowed_effects도 제한한다. Manage·영속 work 생성은 명시된 channel/effect가 없으면 거부한다. PAT로 다른 PAT나 Admin_assignment를 만드는 것은 별도 명시 권한이 필요하며 기본 거부다.
- `DelegatePolicy`는 정확한 initiator/executor 쌍에만 적용된다. `initiator = executor`인 Direct는 별도 DelegatePolicy 없이도 Self/Delegated grant가 필요하다. 이때 `current_delegate_policy`는 `runtimes = All`, `channels = {Direct}`, `allowed_effects = All`인 중립 필터이며 권한 행이 아니다. 외부 initiator의 Delegate·Schedule·BoardTrigger는 현재 일치하는 DelegatePolicy가 필요하며 재위임은 금지한다.
- channel은 Direct·Delegate·Schedule·BoardTrigger·Retry·Resume 등으로 닫힌다. Board 작성 권한이 Runtime·tool 권한을 의미하지는 않는다.
- effect는 `Read_state`, `Invoke_model`, `Use_tool`, `ManageOwnProvider`, `ManageOwnRuntime`, `ManageOwnGrant`, `ManageOwnKeeper`, `ManageMachineShared`, `AdminDisableBlock`, `ReadAuditMetadata` 등으로 닫힌다. tool의 `Read_only | Effecting` 분류와는 다른 축이다.

### 4.5 Intent의 subject

```text
Subject =
  Grant of grant_id
  | Credential of provider_account_id
  | Principal of principal_id
  | Runtime of runtime_id
```

Intent는 대상 없이 digest만 남기지 않는다. 중단된 회수가 어느 grant·credential·principal·Runtime에 대한 것인지 게이트가 식별할 수 있어야 한다.

## 5. 인증과 Provider 등록

### 5.1 모드와 초대

`auth_config.account_mode = Single_user | Multi_account`를 필수로 둔다. 설치·업그레이드 도구는 기존 Single_user에도 값을 명시하고, 값이 없거나 알 수 없으면 부팅을 거부한다. principal 수나 초대 수로 모드를 추론하지 않는다. 첫 bootstrap 전에도 Multi_account를 선택할 수 있다.

1. 최초 Admin은 호스트 로컬 bootstrap으로 만들고 원격 선착순 Admin은 없다.
2. 신규 사용자는 Admin이 등록한 `(iss, sub)` allowlist 또는 단회 초대 token과 첫 OIDC 로그인의 `(iss, sub)` 결속으로만 입장한다.
3. 초대 소비·sub 결속·User 생성은 writer lock 안의 unique 검사와 한 append로 완료한다. 동시 소비나 sub 재결속은 409다.
4. 초대 token은 URL fragment에만 두고 폼 POST로 전달한다. QueryString·Referer·로그에 싣지 않는다. email과 handle은 신원 키가 아니다.
5. 계정 링크·병합은 초기에 금지하고, 마지막 Admin의 삭제·강등·비활성화는 거부한다.

### 5.2 Google OIDC

Authorization Code + PKCE(S256), state, nonce, exact redirect URI를 사용하고 ID Token의 signature/iss/aud/exp/nonce를 검증한다. `hd`는 도메인 정책이 있을 때만 보조 조건이며 개별 허용 목록을 대신하지 않는다.

- `__Host-masc_session`: Secure, HttpOnly, host-only, Path=/, SameSite=Strict.
- `__Host-masc_oidc_txn`: Secure, HttpOnly, host-only, Path=/, SameSite=Lax. state/nonce/PKCE와 서버 transaction에 결속한다.
- `__Host-masc_mcp_session`: Secure, HttpOnly, host-only, Path=/, SameSite=Strict. `mcp-session-id` 헤더와 별개이며 **인증 수단이 아니다.**

transport는 `Browser_session(session_id) | Scoped_pat(pat_id)`에 결속하고 opaque transport ID는 auth session ID와 다르다. 매 요청에 독립 인증을 요구하고 transport ID만으로 principal을 만들지 않는다. auth session/PAT 폐기·재발급 시 transport와 WS/SSE를 닫는다.

`/auth/oidc/callback`은 transaction만 인증 입력으로 사용한다. 기존 session은 새 세션 발급과 같은 원자 단계에서 `session_revoked_at`을 기록해 폐기하고 그 transport를 닫는다. 다른 경로의 transaction cookie는 401이다. 독립 credential이 둘 이상이면 401이지만 auth session과 그에 결속된 transport는 한 인증이다.

callback은 303 대신 비공개 데이터가 없는 200 HTML 완료 화면을 반환한다. same-origin Dashboard 링크 또는 `location.replace`로 이동해 다음 탐색부터 Strict cookie를 사용한다. `return_to`는 로컬 경로만 허용하고 Strict·Secure를 낮추지 않는다. 다계정은 HTTPS를 요구하고 단일 사용자 개발 모드의 기존 cookie 동작을 깨지 않는다.

OIDC Dashboard는 Authorization header를 제거한 뒤 모드를 연다. cookie+Bearer를 cookie가 조용히 이기는 상태는 두지 않는다. CLI/MCP는 scoped PAT을 사용한다. 원격 WS/SSE의 `token` query·`sse_kind=observer`·IDE LSP query credential은 비활성화하고, 기존 query credential은 단일 사용자 loopback의 단회 교환만 허용한다.

### 5.3 credential 선택과 Strict

- `Legacy_workspace_secret`은 parser가 명시적으로 인식하지만 다계정에서는 단독·조합 모두 `Legacy_credential_forbidden`이다. Admin이나 Worker로 해석하지 않는다. HTTP recovery grace는 제거하고 `masc auth recovery`의 Local_operator 경로만 사용한다.
- `auth disabled`, `require_token=false`, `MASC_ALLOW_ANONYMOUS_MUTATIONS=true`는 다계정 부팅·활성화를 거부한다. 이 검사는 기존 기능이 아니라 새 요구사항이다.
- HTTP `http_auth_strict_enabled`와 MCP caller strict를 `Auth_gate.decide = Allow(principal) | Reject(reason) | Log_only(evidence)`로 통합한다. 다계정은 Reject가 실제 응답일 때만 허용하고 token 해석 실패 후 caller alias 유지 경로는 제거한다. `MASC_AUTH_STRICT=strict` 값만으로는 통과하지 않는다.
- session cookie가 조금이라도 있으면 bearer 유무와 무관하게 same-origin과 session-bound CSRF token을 모두 요구한다. `Option.is_some token` 우회와 GET mutation은 금지한다. credentialed cross-origin CORS는 기본 거부다.
- agent query/header와 `x-masc-keeper-name`은 Actor_hint다. 제시한 service hint가 credential의 service_id와 다르으면 거부한다. 익명 rate-limit은 직접 접속 peer IP이며 Actor_hint로 나누지 않는다. 인증 진단 endpoint는 Admin 전용이며 token·hash·credential 본문을 반환하지 않는다.
- route 표에 모든 HTTP/WS/SSE/MCP 경로의 인증·인가·CSRF·query credential 처분을 열거하고, legacy workspace secret을 쓰는 기존 호출자와 대체 `InternalServiceCredential.service_id`도 열거한다. legacy 사용 목록이 0이어야 다계정을 연다.

### 5.4 ProviderLink

```text
ProviderLink {
  login_id,
  owner: Principal,
  integration: Codex | ClaudeCode | ...,
  existing_account_ref: option,
  workspace_id,
  account_home_namespace,
  worker_instance_id,
  auth_binding,
  status
}
```

1. `owner`는 인증 principal에서 결정하고 클라이언트가 지정하지 못한다. 시작 시 서버 저장소의 활성 membership과 namespace를 확인한다. workspace는 공유일 수 있으므로 단일 소유자 개념은 쓰지 않는다.
2. 시작·SSE·resume·로그인 코드 입력·취소·receipt 조회마다 **요청 값이 아니라 저장소의 현재 membership record**와 owner·workspace·namespace·auth_binding을 대조한다. 다른 사람의 workspace_id·namespace는 거부한다.
3. 모든 `account_ref` resolve는 `ManageOwnProvider + workspace + integration + CLI + owner + namespace`를 검사한다. account_ref·login_id는 권한이 아니다.
4. official-client OAuth와 MASC Google OIDC transaction은 다른 흐름이다. 각각 state/PKCE와 단회 소비를 검증하고, 완료 시 ProviderAccount.owner와 격리된 account-home을 결속한다. provider email은 소유권 키가 아니다.
5. OAuth code·provider token·credential 본문은 로그·응답에 남기지 않는다. 로그인 완료와 실제 호출 성공은 구분한다. 현재 `CanAdmin`은 일반 사용자의 `ManageOwnProvider`로 분리한다.

## 6. 실행 인가

### 6.1 Runtime 조회와 실행

`Runtime_view.t`는 목록·설정·표시용이고 실행할 수 없다. `Authorized_runtime.t`는 abstract 타입으로, attempt·failover 후볼 때만 `Runtime.authorize`로 발급한다. string ID만으로 실행 객체를 얻는 경로는 금지한다. 허용 후보가 없으면 `NoAuthorizedRuntime`이며 다른 principal의 private Runtime으로 failover하지 않는다.

attempt 시작·failover·credential 해석 직전에 현재 grant·policy·fencing을 검사한다. 저장소를 읽지 못하면 `AuthorizationUncertain`으로 거부한다. 새 입력·재시도·resume·official-client 다음 턴은 새 dispatch다.

### 6.2 범위와 효과를 분리한 판정

```text
scope_ok =
  runtime_id ∈ (
    stored_scope.runtimes
    ∩ current_delegate_policy.runtimes
    ∩ pat_scope.runtimes)

channel_ok =
  channel ∈ (
    stored_scope.channels
    ∩ current_delegate_policy.channels
    ∩ pat_scope.channels)

effects_ok =
  requested_effects ⊆ (
    stored_scope.allowed_effects
    ∩ initiator_grant.allowed_effects
    ∩ executor_grant.allowed_effects
    ∩ current_delegate_policy.allowed_effects
    ∩ pat_scope.allowed_effects)

allowed =
  active(initiator)
  ∧ active(executor)
  ∧ active(auth_binding)
  ∧ current_membership(initiator, workspace_id)
  ∧ current_membership(executor, workspace_id)
  ∧ invocation_allowed(initiator, executor, channel)
  ∧ current_grant(initiator, runtime)
  ∧ current_grant(executor, runtime)       -- 같으면 한 번 평가
  ∧ scope_ok
  ∧ channel_ok
  ∧ effects_ok
  ∧ ¬ revocation_pending(subject)
  ∧ dependencies_cleared(current_transition_epoch)
```

- `current_grant`는 저장된 Self/Delegated의 status·expires_at·grant_epoch·resource_epoch·현재 owner·membership을 검사한다. ownership predicate를 별도 인가 경로로 쓰지 않는다.
- `Not_pat`은 교집합에서만 중립 필터이며 `Empty`와 혼동하지 않는다. grant/policy/PAT의 effect는 모두 현재 범위를 좁히는 필터이며 넓히지 못한다. Direct의 중립 policy와 `All`도 현재 grant 안으로 제한된다.
- `invocation_allowed`는 initiator=executor인 Direct를 허용하되 grant와 effects는 그대로 요구한다. 외부 initiator의 Delegate·Schedule·BoardTrigger는 현재 일치하는 DelegatePolicy가 필요하다.
- 영속 작업은 원본 `{initiator, executor, channel, stored_scope}`를 유지하고 발화·재시도·resume 때 **initiator와 executor 양쪽의 현재 grant**를 재확인한다. 원본 권한이 철회된 뒤 executor grant만으로 실행하지 않는다. chain은 감사 기록이며 권한 확장 근거가 아니다.
- Disabled/tombstone principal은 새 실행과 새 durable record 생성이 모두 거부된다. 순수 system 이벤트만 initiator=Service(system)이며, Human schedule이 cron으로 발화할 때도 initiator는 Human이다.
- `author`는 record writer, `initiator`는 실행 권한 출처다. 비실행 진단 record만 initiator가 없을 수 있다.

### 6.3 authorless writer 경계

```text
System_cron        -> 허용된 trigger evidence만
System_maintenance -> 실행/lease 종단 evidence와 사전 승인된 만료만
System_migration   -> migration 진단 record만
```

`RuntimeGrant`, `DelegatePolicy`, `Principal`, `InternalServiceCredential`, 명시적 permission revocation은 인증된 author가 필요하다. owner는 자기 자산, Admin은 허용된 관리 행위, 로컬 복구는 Local_operator만 쓴다. migration 기동은 호스트 로컬 운영자/런처 전용이며 actor·run_id를 남긴다.

자동 만료는 `Preauthorized_expiry(cause_event_id)`로 닫고 author는 System_maintenance다. 원 승인자와 원 승인 사건을 보존하고 tombstone이어도 새 서명 없이 만료를 적용한다. revalidation 성공 증거나 새 grant·owner 변경·임의 회수에는 쓰지 않는다.

## 7. Runtime별 lease와 도구

### 7.1 MASC 중개 요청·도구

`Provider_request`는 MASC가 중개하는 provider 요청 1건, `Masc_tool_effect`는 MASC가 중개하는 tool effect 1건이다. lease ID만으로 credential을 얻을 수 없다.

- lease 발급은 writer lock 안에서 `Authorized_runtime.t`의 grant·fencing을 저장소 최신 상태와 비교한다. 다르으면 조용히 재발급하지 않고 `NoAuthorizedRuntime`이다. 같은 attempt의 두 번째 tool 전 회수라면 다음 lease를 거부한다.
- `Provider_request`는 `Lease_dispatched`가 회수보다 먼저 기록된 한 응답만 일반 회수 후 완료할 수 있다. `Lease_dispatched`가 발급과 전송 허가의 선형화 지점이며 Active와 Request_sent를 모호하게 합치지 않는다. 그 전 회수라면 전송하지 않는다. 다음 입력·재시도는 새 lease다.
- `Masc_tool_effect`는 일반 회수에서도 `Revoked`와 취소 채널·checkpoint·효과 직전 재확인으로 종료한다. 이미 전송된 외부 호출·공개 데이터의 회수는 약속하지 않는다.

도구 registry의 효과 분류는 닫힌 `Read_only | Effecting`이다. 분류가 없는 새 tool은 Effecting이다.

- `Read_only`: dispatch credential·현재 scoped fencing·snapshot 권한·출력 ACL을 매 호출 검사하지만 외부 상태를 바꾸지 않으므로 lease append는 하지 않는다. 허용된 단일 조회 응답만 완료하고 다음 호출에는 현재 snapshot을 다시 읽는다. Runtime 실행·Manage를 새로 허용하지 않는다.
- `Effecting`: 기존 `Masc_tool_effect` lease와 동기 commit·취소 채널을 적용한다.

### 7.2 official-client dispatch

Codex/Claude Code는 credential을 CLI가 읽고 한 dispatch에서 여러 요청과 내장 도구를 실행한다. 따라서 `Official_client_dispatch`의 단위는 **인증된 CLI process incarnation 하나 + dispatch 하나**이며 `dispatch_id`로 구분한다. Request_sent·한 응답 완료·MASC tool lease를 이 경로에 적용하지 않는다.

broker는 lease 뒤에만 account-home을 최소 연결하고, 일반 회수에서도 process tree 종료와 account-home 연결 해제를 실행한다. 다음 입력은 새 incarnation·새 lease다.

공유/Delegated official 실행은 다음 둘 중 하나를 **현재 후보의 레인 실측으로 증명할 때만** 허용한다.

- `Inference_only`: 내장 도구·MASC MCP·credential/debug 출력을 비활성화한 순수 추론이다. 도구가 필요한 Keeper 실행에는 쓸 수 없다.
- `Isolated_tools`: trusted official runtime에만 account-home을 두고 내장 tool subprocess·initiator·다른 Keeper가 credential/account-home을 읽을 수 없음을 증명한다. allowed_effects를 실제 sandbox/tool 정책으로 강제하고 종료를 검증한다.

증명은 `{cli_binary_digest, effective_config_digest, lane_identity, host_kernel, filesystem_type, eio_version, evidence_id}`에 결속하고 lease에 기록한다. dispatch 시점 값이 다르거나 증명이 없으면 `NoAuthorizedRuntime(Lane_not_isolated | Attestation_stale)`이다. Human의 Keeper도 owner와 executor가 달라 private 예외가 아니다. owner=executor인 private 실행만 executor별 격리 하에 허용한다. 미검증 lane에 account-home을 mount하지 않는다.

### 7.3 dispatch MCP credential

official CLI가 MASC MCP를 부를 때는 **dispatch 전용 MCP credential**을 발급한다. `{dispatch_id, lease_id, initiator, executor, worker_instance, fencing, allowed_effects}`에 결속하고 관리·새 dispatch·재위임 권한이 없다. 각 Effecting 호출은 별도 `Masc_tool_effect` lease를 요구하며 dispatch lease Revoked와 함께 무효다. 장수 Service token이나 wall-clock TTL로 대체하지 않는다.

official runtime에만 전달하고 내장 tool 자식에서 제거하지 못하면 `Isolated_tools` 증명이 실패한다. `Inference_only`에는 발급하지 않는다. tool/Execute/비신뢰 자식에는 Service credential을 넣지 않으며 부모가 여러 credential을 가지면 `MultipleServiceCredentials`로 spawn을 거부한다.

## 8. scoped epoch·log·회수

### 8.1 epoch과 읽기 모델

```text
principal_epoch  : principal Disable/tombstone/RevokeAll에만 증가
role_epoch       : Admin_assignment 생성·회수·변경에만 증가
membership_epoch : WorkspaceMembership 생성·회수·namespace 변경에만 증가
auth_binding_epoch: 해당 browser session/PAT/Service credential 폐기에만 증가
grant_epoch      : 해당 grant의 회수·효과 축소에만 증가
policy_epoch     : 해당 DelegatePolicy의 회수·범위 축소에만 증가
resource_epoch   : Runtime/ProviderAccount Disable/Block/Quarantine/Purge/정책 전체 회수
```

- Admin 경로의 stream·관리 실행은 `role_epoch`를 대조하고, workspace의 ProviderLink·dispatch는 `membership_epoch`를 대조한다. 개인 Self Runtime은 role 변경만으로 무효화하지 않는다.
- lease와 stream은 자기 `principal_epoch + auth_binding_epoch + grant_epoch + 필요한 policy_epoch + resource_epoch`를 대조한다. `store_seq`는 로그 순서·감사 좌표일 뿐 수명 판정에는 쓰지 않는다.
- 개별 grant 회수는 `(executor, runtime_id, grant_id)` 구독과 lease만 닫는다. 다른 Runtime·다른 grant·다른 session/PAT의 transport는 유지한다. PAT 폐기도 그 PAT에 결속한 것만 닫는다.
- model/execution revision은 다음 attempt에 적용하고 진행 중 lease를 끊지 않는다. 권한 축소만 scoped epoch으로 회수한다.
- WS/SSE/MCP는 `principal active ∧ auth_binding active ∧ 구독 대상 grant/policy/resource 유효`를 재평가한다. auth session/PAT 폐기·principal Disable은 해당 transport를 무효화하지만 개별 Runtime 회수가 무관한 transport를 끊지 않는다.

`authz.jsonl`의 writer lock은 최신 snapshot 검증 + append/fsync + 새 불변 snapshot 발행에만 쓴다. 읽기는 lock-free snapshot, replay는 기동·복구 때만이다. grant·lease 발급·회수·Lease_dispatched는 동기 commit이다. Completed evidence는 다음 동기 commit에 함께 실을 수 있지만 손실되면 완료로 추정하지 않고 `Outcome_unknown`이다. blocking I/O는 main domain에서 분리하고 authorize/append/flush를 각각 측정한다.

### 8.2 고수위와 Intent/Committed

backup 밖 append-only 저장소에는 객체의 scoped epoch 최고값·artifact별 `credential_generation`·Intent 상태를 기록한다. replay 값과 외부 고수위가 다르거나 외부 저장소를 읽지 못하면 `AuthorizationUncertain`으로 시작하고 옛 lease·점유·grant를 승인하지 않는다. 고수위 일치는 무결성 조건이지 실행 승인 조건이 아니다.

```text
Intent_pending {
  previous_record_hash,
  intended_next_record_digest,
  intended_event_kind,
  subject
}
Committed {
  record_hash
}
```

1. 고수위는 Intent_pending으로 시작하고 authz append/fsync 뒤 `Committed(record_hash)`로 갱신한다. snapshot 발행 뒤에만 성공 응답을 돌려준다. Committed 전 성공 응답은 없다.
2. 재기동 시 `Intent_pending`인데 replay에 `intended_next_record_digest`와 일치하는 record가 있으면 **digest를 검증하고 Committed로 승격**한다. record가 이미 있으므로 의도를 다시 실행하지 않고 고수위 포인터만 완료한다. digest가 다르으면 `AuthorizationUncertain`이다.
3. `Intent_pending`인데 replay가 직전 해시와 같고 intended record가 없으면 `Incomplete_append_aborted`로 기록하고 intended event를 재생하지 않는다. 응답이 나가지 않은 미완료 의도이며 `aborted_intent`로 epoch 간격의 이유를 남긴다.
4. `Committed(h)`인데 replay에 h가 없으면 미완료 append가 아니라 **응답한 사건의 롤백**이다. `AuthorizationUncertain`으로 시작하고 되돌아온 Active grant를 실행하지 않는다. replay에 h가 있으면 포인터만 완료하고 현재 scoped fencing을 다시 검사한다.
5. replay가 직전 해시와 일치하는지, intended digest가 일치하는지를 분리해서 판정한다. 일반 크래시와 실제 복원 누락을 같은 가지로 처리하지 않는다.
6. backup 밖 저장소가 실제 backup 대상에서 제외되는지 T/T+1/T+2 리허설의 경로·제외 목록·digest로 증명한다.

### 8.3 중단된 보안 회수

`Incomplete_append_aborted`이고 `intended_event_kind ∈ {Revoke, Disable, Block}`이면 해당 `subject`를 **로그를 건드리지 않고 게이트에서만 `Revocation_pending`으로 차단**한다. grant 행이 Active로 보여도 새 dispatch·lease·tool effect를 허용하지 않는다.

- 새 Grant·credential 생성·일반 설정 변경은 자동 재생하지 않고 다시 승인한다.
- `Revocation_pending`은 **재시도 append 성공** 또는 **Admin의 명시적 취소 기록** 중 하나로만 닫는다. owner나 공격자가 임의로 해제하지 못한다. Admin이 없으면 실행을 재개하지 않고 Local_operator의 Quarantined 경로로 간다.
- 중단된 회수라는 표시만 남기고 Active로 실행하지 않는다. 자동 재생과 `Revocation_pending`은 다른 개념이다.

### 8.4 신규 설치와 읽기 실패

외부 고수위 저장소의 `ENOENT`는 명시적 `Fresh_bootstrap`에서만 허용한다. `Fresh_bootstrap`은 **Local_operator가 서명한** 새 workspace_id·새 account_mode·빈 authz log·빈 Recovery_manifest·초기 generation이 같은 bootstrap append로 확인되어야 한다. workspace_id도 외부 저장소와 같은 append에 기록한다.

`EACCES`·다른 I/O 오류·손상 JSON·디렉터리·심볼릭 링크·부모 경로 부재·workspace_id 불일치는 `AuthorizationUncertain`으로 거부한다. `Fresh_bootstrap`이 아닌데 저장소가 없거나 생성 규칙이 맞지 않으면 실행하지 않는다. 외부 고수위를 생략하고 legacy 경로로 부팅하지 않는다.

외부 저장소가 복구되지 않으면 창은 닫히지 않는다. `/health`와 `account_busy`에 `Recovery_store_unavailable`과 필요한 운영 조치를 표시하고, stale snapshot으로 Cleared를 만들지 않는다.

## 9. worker·account-home·취소

1. lease에는 dispatch_id·runtime_kind·initiator/executor·runtime/grant·worker_instance·server_boot·attestation·scoped fencing·auth_binding을 기록한다. server_boot_id는 기동마다 OS CSPRNG로 새로 만들고 worker_instance는 프로세스/VM 회차마다 새로 증명한다.
2. `attestation = Spawn_nonce | Mtls | Os_identity | Broker_attestation`이다. Spawn_nonce는 전용 IPC의 단일 사용자 개발 전용이며 다계정에서 허용하지 않는다. 다계정은 lane별 VM instance ID·OS process/boot identity·broker run ID의 실제 출처를 요구하고 미증명 lane은 실행 불가다. 격리·attestation을 먼저 완료한다.
3. worker 종료·channel closed·supervisor exit 같은 실제 사건으로 미종료 lease를 `Outcome_unknown`으로 종결한다. 임의의 N초 heartbeat TTL은 없다. 다음 worker가 예전 lease를 재사용하지 않는다.
4. 취소는 `Effect_cancel | Executor_teardown`이다. per-effect shim이 없으면 executor 전체를 종료하고 영향 lease를 모두 `Outcome_unknown`으로 기록한다. 다른 principal은 종료하지 않는다. process tree SIGTERM 후 종료가 확인되지 않으면 SIGKILL/VM teardown을 사용하며 미증명 lane은 제외한다.
5. `Outcome_unknown`은 `Failed(Outcome_unknown)`이라는 attempt 종단이며 AuthorizationUncertain보다 우선한다. 복원 Cleared가 이전 lease를 살리지 않는다.
   - 전송 전이라면 현재 권한으로 새 attempt를 만들 수 있다.
   - 전송된 provider 요청은 idempotent로 단정하지 않는다. 기존 dispatch 정책이 새 lease·새 인가·duplicate_possible로 새 attempt를 만들 수는 있지만 exactly-once는 주장하지 않는다.
   - `Inference_only`가 아닌 official dispatch나 Non_idempotent/불명 tool effect는 외부 결과 확인 뒤 새 attempt를 만든다. idempotency key나 외부 dedup 증거가 있는 tool만 자동 새 attempt를 허용한다.
   - 확인이 필요한 attempt는 영구 Pending이 아니라 실패 종단이다. 원 initiator Human 또는 Keeper의 지정 Human owner, ownerless Keeper나 system initiator이면 Local_operator에게 별도 reconciliation 질문을 남긴다. 질문에 대한 응답이 새 attempt를 만들며 다른 턴·작업은 막지 않는다.

### 9.1 account-home single-flight와 대기

같은 ProviderAccount의 official account-home은 기본적으로 single-flight다. credential 파일 동시 갱신 가능성을 가정하지 않고 한 incarnation만 연결한다. 대기자는 credential 없이 기다리고 lock을 얻은 뒤 writer lock에서 현재 권한을 다시 검사한 뒤 mount/spawn한다. 회수되면 대기를 취소하고 authz writer lock을 잡은 채 account-home lock을 기다리지 않는다.

- owner 대기열은 **ProviderAccount.owner와 `managed_by=owner`인 Keeper/Service**의 대기열이다. 다른 Human과 그 Keeper는 grantee 대기열이며 각각 FIFO다. owner가 대기 중이면 새 grantee admission은 그 뒤로 하되 실행 중인 grantee는 preempt하지 않는다. 점유 시간 상한 대신 owner의 명시적 회수로 해제한다.
- `account_busy`에는 같은 owner 클래스의 Keeper 대기 수와 `Account_recovery_pending`을 구분한다. owner에게는 holder dispatch_id·대기 메타데이터를 보여 주지만 prompt·credential은 노출하지 않는다.
- 점유는 `{provider_account_id, dispatch_id, server_boot_id, worker_instance_id, state}`로 영속 기록한다. 재기동 뒤 이전 점유는 **이전 worker 종료와 account-home 연결 해제가 attestation으로 확인된 뒤에만** 해제한다. 확인하지 못하면 `AuthorizationUncertain`으로 새 mount/spawn을 거부한다. teardown 후 credential 무결성을 검증하고 확인하지 못하면 owner 재인증 또는 로컬 운영자의 Quarantined로 진행한다. credential을 오래된 backup에서 자동 복원하지 않는다.

### 9.2 `Concurrent_ok`

`account_concurrency = Single_flight | Limited of positive_int`다. `Limited n`은 **입장 큐가 owner 클래스의 동시 incarnation 수를 n 이하로 실제 제한할 때만** 허용하며 `Concurrent_ok` 증거의 N도 같은 n이다. 증거 없이 `Limited`를 설정하면 실제 동작은 Single_flight다.

증거 키는 `{cli_binary_digest, effective_config_digest, account_home_implementation, host_kernel, filesystem_type, eio_version, lane_identity}`다. 값이나 n이 바뀌면 다시 증명하고 TTL은 두지 않는다. N개의 incarnation이 refresh read-modify-write 구간에 동시에 들어가도록 동기화 지점을 사용하고 모든 credential 파일의 무결성과 현재 credential로의 실제 호출을 확인한다. 한 실패라도 증거를 무효로 하고 실행 로그 위치·digest를 `evidence_id`로 남긴다. 한두 번의 우연한 성공이나 임의 반복 횟수로 대체하지 않는다.

`account_concurrency_effective = Single_flight(evidence_missing | evidence_key_changed)`를 `/health`·`account_busy`·로그에 표시한다. 설정과 실제 병렬화가 다르다는 것을 조용히 숨기지 않는다.

## 10. 복원·귀속·모드 전환

### 10.1 `Cleared`와 계승

`Cleared = {cleared_epoch, evidence_id, method}`이며 `method = Integrity_carry_forward | Owner_revalidated | Admin_incident_cleared`다. 실행은 모든 의존 사슬이 `cleared_epoch = 현재 transition_epoch`인 경우에만 허용한다. 과거 epoch의 Cleared를 그대로 현재 권한으로 읽지 않는다.

- 새 전이에서 `cleared_epoch < transition_epoch`인 record를 전부 owner가 다시 승인할 필요는 없다. 현재 manifest·generation·revocation 고수위·principal 상태·grant·policy·runtime·membership이 이전 Cleared 이후 **인가 관련 변경이 없음**을 확인한 record는 `Integrity_carry_forward`로 현재 epoch의 Cleared를 기록할 수 있다. 이것은 새 grant가 아니라 기존 권한의 무결성 계승이다.
- 계승은 **전 record 일괄 epoch 갱신이 아니라 의존 사슬별 판정**이다. `Recovery_manifest` 항목별로 증거 입력과 digest를 남기고, 각 사슬을 독립적으로 평가한다. 배치를 실행의 선행 조건으로 두지 않아 전이 중 전역 정지를 만들지 않는다.
- 변경·누락·판정 불일치가 있는 record만 Pending으로 남기고 Active 원 owner·원 승인자 또는 Service 후계가 `Owner_revalidated`로 닫는다. 증명하지 못하면 자동 계승하지 않는다. 부재 owner의 Pending은 그 의존 사슬만 막고 다른 Cleared 사슬은 실행한다.
- 창은 manifest 게시와 모든 record/artifact의 분류가 끝나는 시점에 닫는다. Pending이 0이라는 뜻이 아니다. 분류 도중 크래시하면 같은 transition_epoch와 manifest를 재사용해 이어서 분류하고, 새 epoch이나 부분 계승 상태를 만들지 않는다.

### 10.2 전이 중 work

전이 시작 전에 새 dispatch·새 grant·새 durable work를 먼저 거부하고, 이미 진행 중인 **Effecting dispatch는 `Outcome_unknown`으로 종결**한다. 창 중 도착한 효과는 성공한 work로 적용하지 않고 새 record로 현재 epoch 검사를 받는다. account-home은 unmount 확인 전 `Release_pending`이다.

복구 안내 Board 글은 작성할 수 있지만 typed `recovery_notice`로 표시하고 **subscription 후보 생성 필터와 dispatch 진입 검사 양쪽**에서 Keeper wake를 제외한다. 일반 Board 글에 문자열로 wake를 끄는 규칙은 두지 않는다.

### 10.3 귀속은 claim 후보다

1. ownerless 귀속 append는 `candidate_owner=bootstrap`과 `Self.status=Revoked(Attributed_unclaimed)`를 기록한다. 이 시점에 Active Self는 없고 bootstrap principal이 Admin이든 Service이든 실행할 수 없다.
2. 후보 목록은 후보 본인·Admin·Local_operator가 읽는 projection으로 노출한다. 후보는 자기 항목을 조회·claim할 수 있지만 credential은 볼 수 없다.
3. 후보 Human이 현재 OIDC 인증으로 본인임을 확인하고 `ManageOwnProvider`와 provider 재인증·credential 결속을 완료하면, 그 claim append에서 **새 grant_id의 Active Self**를 만든다. 관리 권한의 자기 승인이 아니라 명시적 소유 수락이다. Revoked 행을 다시 Active로 바꾸지 않는다.
4. 후보가 Service이면 그 Service 관리 owner가 같은 절차를 수행한다. Local_operator는 후보를 지정할 뿐 claim·Cleared·실행을 대신하지 않는다. claim이 없으면 자산은 Disabled/Pending이며 MachineShared로 승격하지 않는다.
5. 검증은 귀속 즉시 실행이 아니라 **claim 완료 후 저장된 새 Self로 owner direct가 성공하고 구 Self·구 Delegated는 실행되지 않는 것**이다.

### 10.4 Block·Pending·Quarantine

1. Block record에 `cause = Security_incident | Operational`을 필수로 둔다. 원인이 없는 기존 Block은 `Security_incident`로 취급한다.
2. `Security_incident` 해제 후에는 원 owner·원 grant 승인자가 스스로 Cleared할 수 없다. **Admin이 owner가 수행한 provider 재인증·credential 교체·격리 증거를 확인하고 항목별로 Cleared한다.** Admin이 owner 대신 재인증하거나 credential을 읽는 것은 아니다.
3. `Operational` 해제 후에는 Active 원 owner·원 승인자 또는 Service 후계가 Cleared한다. 두 경우 모두 Unblock이 lease·stream·durable work를 자동 재개하지 않는다.
4. Security_incident 해제 시 활성 Admin이 없으면 Unblock/Cleared하지 않고 Local_operator가 Quarantined로 기록한 뒤 기존 purge로만 종단한다. 관리자 부재를 이유로 owner에게 해제 권한을 돌려주지 않는다.
5. **부재가 확인된 owner의 Pending은 Local_operator의 Quarantined로만 종단하고 그 의존 사슬은 Disabled로 내린다.** Pending을 무기한 감사에 남기지 않는다. Quarantined 후보는 의존 단계 재검증이 명시적으로 실패한 record이며 `failed_stage`, `failure_evidence_id`, `manifest_id`를 필수로 남긴다. 시간 경과를 실패로 취급하지 않는다.
6. Quarantined는 일반 재활성화·공유·실행이 불가능하고 로컬 운영자의 명시적 purge만 종단이다. purge는 credential 조회나 grant 재검증 없이 대상 ID·실행자·사유·결과를 audit/revocation ledger에 남기고 credential을 파기한다. 비밀이 아닌 model/execution config는 읽기 전용으로 export하고 credential은 파기한다. grant는 이전하지 않는다. Purged를 복원으로 Active로 승격하지 않는다.

### 10.5 복원·모드·ledger

- 복원·롤백 직후 모든 공유·실행은 AuthorizationUncertain이다. snapshot Active·ledger replay·store_seq 고수위만으로 해제하지 않는다. 도메인 상태와 별도의 `restore_disposition = Pending | Denied | Cleared | Quarantined | Purged`를 둔다.
- Disabled/tombstone/purged initiator·executor·owner의 durable work는 먼저 Denied로 확정하고 나중에 계정이 활성화돼도 자동 복귀하지 않는다. `Outcome_unknown` lease는 되살리지 않는다.
- 남은 record는 Principal/credential → grant/policy → Runtime → schedule/resume/work 의존 순서로 재검증한다. Admin/Service → system cron → Human은 같은 단계의 우선순위일 뿐이며 Pending/Denied work는 cron이 열리더라도 실행하지 않는다. Cleared는 원 grant 승인자 또는 Service의 Admin 지정 후계가 항목별로 승인한다.
- Recovery_manifest는 전 record의 ID·의존 관계·분류·digest를 접근 제한된 artifact로 게시한다. 독자는 Cleared 승인자·Admin·Local_operator로 제한하고 owner/승인자는 자기가 승인할 entry만 projection으로 읽는다. Board/health에는 count와 미해제 상태만 공개한다. manifest에는 산출 명령·대상 범위·전이 epoch·분류 count·digest를 기록한다.
- backup/rollback에서 되돌아온 account-home과 credential artifact는 `CredentialUncertain`이다. **현재 owner가 provider official 재인증을 완료하고 새 credential generation과 account-home을 검증하기 전에는 mount하지 않는다.** MASC principal의 Dashboard 로그인만으로 Cleared하지 않는다. 비밀이 아닌 설정만 별도 projection으로 복원하고 credential-bearing home은 새로 만든다. owner가 없거나 재인증할 수 없으면 Local_operator가 Quarantined로 기록하고 purge한다. provider에서 아직 유효한 token이라도 사용하지 않는다.
- 일반 재기동이나 on/off만으로 backup을 되돌린 것은 아니라면, artifact와 외부 generation이 일치하는지 대조해 provider 재인증 없이 기존 credential을 재검증할 수 있다. 평시 재기동에 Recovery_manifest가 없어도 generation을 대조한다.
- revocation ledger 현재본은 backup과 분리된 append-only 저장소에 유지하고 backup 사본과 합집합으로 대조한다. 고수위 불일치·누락이 있으면 AuthorizationUncertain이며 일치도 실행 승인 근거가 아니다. T 백업 → T+1 revoke R → T+2 복원 후 R 유지·연결 work Denied·유효 lease 0을 확인한다.
- 최초 활성화 전 initiator가 없는 legacy work는 `Denied(legacy_unattributed)`로 분류하고 Service(system)으로 신원을 세탁하지 않는다. initiator/scope가 없는 record는 **각 transition_epoch 직전의 무귀속 record**로 분류하고 `legacy_unattributed | legacy_scope_missing`으로 둔다. Local_operator author로 총계·Denied·Cleared·미분류를 기록하고 미분류 0을 확인한다. ownerless 자산은 dry-run 후 bootstrap principal에 명시 귀속하고 귀속하지 못하면 Disabled이며 MachineShared로 승격하지 않는다.
- 다계정 on→off에서는 multi-owned record를 읽기 전용으로 보존하고 legacy 공유 token/admin으로 실행하지 않는다. 진행 중 multi dispatch·session은 종료하고 재활성화 시 동일한 Recovery_manifest·Pending 절차를 거친다. off 전환의 dispatch는 `Outcome_unknown`으로 종결하고 account-home 점유는 `Release_pending`으로 바꿔 unmount 확인 뒤에만 Released로 한다. off의 기존 단일 사용자 동작 확인은 multi-owned 자산을 legacy로 여는 의미가 아니다.
- 로컬 복구는 인증 가능한 Admin이 0명이거나 IdP 복구 불가일 때 `masc auth recovery --base-path <path>`로 연다. 호스트 관리자와 root 소유 일회용 recovery 파일이 필요하고 실행자·사유·시각·결과·파일 digest·파기 결과를 append-only audit/Board에 남긴다. 원격 break-glass는 없으며 활성화 전 리허설한다.

## 11. MultiAccountReadiness

`account_mode = Multi_account` 자체는 실행 허가가 아니라 요청이다. 실제 활성화에는 테스트 실행기가 산출한 `MultiAccountReadiness`가 필요하다.

1. readiness에는 route inventory와 각 경로의 실제 Reject/CSRF/credential 단일성 증명, `legacy_workspace_secret_callers=[]`, `auth disabled`·`require_token=false` 부팅 거부 증명, Provider 두 계정 호출·제3자 거부, official lane 격리·복구 리허설 결과를 포함한다. `auth disabled` 부팅 거부는 기존 코드에 있다는 의미가 아니라 새로 추가할 요구사항이다.
2. 각 증명은 build 전체가 아니라 **그 항목이 읽는 표면의 digest**에 결속한다. route 표·credential parser·lane 격리·Provider fixture·복구 리허설이 각각 `evidence_id`와 digest를 가진다. 운영자가 문서나 빈 boolean으로 `ready=true`를 쓰는 경로는 없다. 누락·미검증·digest 불일치·legacy 잔존이 있으면 열지 않는다.
3. digest 불일치 시 `Multi_account_readiness_stale(surface)`로 **부팅·활성화를 거부**하고 `/health`와 로그에 같은 사유를 표시한다. 재-readiness 없이 Single_user로 자동 강등하거나 legacy 인증으로 돌아가지 않는다. 변경된 표면의 항목만 다시 실행한다.
4. Provider 실계정 증거는 상시 CI가 아니라 후보·Provider 관련 표면이 바뀐 경우에 갱신한다. 실제 계정의 credential 상태도 확인하고, 검증 당시와 다른 계정·credential·Provider 설정이면 그 증거를 사용하지 않는다.
5. `Fresh_bootstrap`도 readiness 없이 원격 다계정을 열지 않는다. loopback 로컬 복구는 별도 Local_operator 경로로 제한한다.

## 12. 필수 적대 시나리오

### 인증·입장·세션

- 초대 동시 소비·sub 재결속·잘못된 issuer/nonce/audience/state는 거부한다. 마지막 Admin 보호와 로컬 복구 리허설을 확인한다.
- callback에 session과 transaction이 함께 와도 transaction으로 재개하고 성공 뒤 구 세션·transport·WS/SSE가 닫힌다. 다른 경로의 transaction cookie는 401이다.
- cookie가 있으면 bearer 유무와 무관하게 same-origin+CSRF가 필요하다. `auth disabled`, workspace secret, anonymous mutation, 중복 credential은 다계정에서 거부한다.
- 원격 query token·`sse_kind`·IDE LSP query credential은 비활성화하고, Actor_hint·`?agent=`·`x-masc-keeper-name`으로 신원을 바꾸지 못한다. 익명 버킷은 peer IP 기준이다.

### 소유권·공유·실행

- A가 B의 account_ref/Runtime ID를 알아낸 뒤 직접 API·PAT·raw TOML·새 Keeper·Fusion·vision으로 실행하면 거부한다.
- B가 공유받은 Runtime을 자기 Keeper·schedule·retry·delegate로 확장하고 명시 grant가 없으면 거부한다. B가 A의 Keeper에게 Board mention/direct/delegate를 볼 때 owner OAuth/Execute/파일 효과가 delegate_scope 없이 발생하지 않는다.
- Human이 추가한 신규 사용자는 MachineSharePolicy에 자동 포함되지 않고, Admin이 자기·관리 principal에게 grant를 만들면 거부한다. 제2 승인자가 author의 관리 대상이면 거부한다.
- Admin이 A의 credential·private Runtime을 사용할 수 없지만 Disable/Block/긴급 종료는 가능하다. Service/Keeper는 개별 Delegated가 필요하다.
- Provider 등록의 시작·resume·코드 입력·취소·receipt가 owner와 membership/namespace 외에는 거부되고, 일반 사용자는 Admin 없이 자기 Provider를 등록할 수 있다.

### 회수·복원·재기동

- grant 회수·Disable·Block이 dispatch·failover·credential 해석과 동시에 발생하는 경우에도 새 허가를 내지 않는다. R1 회수가 R2 stream·다른 PAT을 끊지 않는다.
- 중단된 Revoke/Disable은 `Revocation_pending`으로 차단하고 재시도 성공 또는 Admin 취소만으로 해제한다. 보안 사건에서 Active로 실행하지 않는다.
- `Intent_pending`에 record가 있으면 digest를 검증해 Committed로 승격하고, record가 없으면 abort하며, `Committed(h)`가 replay에 없으면 롤백으로 거부한다.
- 복원 후 Active grant·취소된 schedule·Disabled principal이 자동 실행되지 않고, Recovery_manifest·Denied·Pending·Cleared·Quarantined가 의존 순서로 기록된다.
- 부재 owner의 Pending은 Local_operator의 Quarantined로만 종단하고 다른 Cleared 사슬은 계속 실행한다. 계승 배치를 기다리는 전역 정지는 없다.
- 복원된 account-home은 owner provider 재인증 전 mount하지 않고, 일반 재기동은 generation이 같으면 재인증 없이 검증한다. 외부 저장소 불일치·읽기 실패는 `AuthorizationUncertain`이다.
- `Recovery_in_progress` 중 진행 중인 Effecting dispatch는 `Outcome_unknown`이며, 창 중 도착한 효과는 성공으로 적용하지 않는다. 복원 Cleared로 부활하지 않는다.

### official·동시성·성능

- 두 실제 Codex/Claude 계정이 올바른 구독으로 호출되고 제3자 호출·Admin private 사용·Keeper로의 묵시적 공유·미검증 delegated official이 거부된다.
- 같은 account-home 동시 요청은 한 incarnation만 연결하고 완료 후 owner 로그인이 유지된다. `Concurrent_ok`가 없거나 키가 바뀌면 병렬화하지 않고 effective Single_flight를 표시한다.
- dispatch MCP credential 회수 뒤 Read_only/Effecting 호출이 모두 거부되고, Read_only에는 lease append가 없어도 인가·출력 ACL이 유지된다.
- 300 Keeper 부하에서 authorize/append/flush p99·snapshot 지연·복원 직후 일제 기상·owner/grantee 대기 수·credential/process/filesystem/trace 격리를 실측한다. 권한 검사를 생략해 목표를 맞추지 않는다.

## 13. 검토 요청과 미검증

이 문서를 기준으로 다음을 적대 검토한다.

- **인증**: legacy Admin·workspace secret·cookie·PAT·membership·scope·readiness의 우회가 없는가?
- **SSOT/타입**: Self·Delegated·MachineSharePolicy·Pat_scope·DelegatePolicy·scope/effect 수식이 모순 없이 구현 가능한가?
- **lifecycle**: `Revocation_pending`·`Outcome_unknown`·`AuthorizationUncertain`·`Quarantined`·`Purged`가 상태와 출구를 잃지 않는가?
- **Runtime**: official-client의 credential·도구·process·MCP credential·single-flight·재시도가 실제 실행 모델과 맞는가?
- **복구**: carry-forward가 부분 epoch·전역 정지를 만들지 않으며, 중단된 회수·복원된 credential·미완료 Intent가 부활하지 않는가?

미검증 사항은 명확히 남긴다. 이 문서는 구현·빌드·PR·실제 Google OIDC 로그인·두 Provider 계정 호출·성능·복구 리허설·구독 약관 검토를 증명하지 않는다. 구현 착수 전에 현재 head의 source와 위 시나리오를 다시 대조하고, 설계상 P0/P1/P2 해소와 독립 리뷰가 필요하다.

## 참고

- [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect): `sub`는 안정적인 사용자 식별자이고, ID Token 검증이 필요하다.
- [RFC 9700, Best Current Practice for OAuth 2.0 Security](https://datatracker.ietf.org/doc/rfc9700/): Authorization Code·PKCE·redirect/token 보호.
- [RFC 10017, OAuth 2.0 for Browser-Based Applications](https://datatracker.ietf.org/doc/rfc10017/): browser 애플리케이션의 BFF·cookie/token 보호.
