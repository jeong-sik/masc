# 다계정 Google OIDC·Provider·Runtime 권한 설계

- 날짜: 2026-10-27
- 상태: 적대 설계 리뷰 대상. 구현·배포 승인이 아니다.
- 관련 Board: `p-01a8be37d38b1cd54c79d05233308911`, 종합 `c-8484f100744604fd48f85b31104bf3f9`
- 코드 대조: main `90dd18193c8` (§1의 코드 근거는 이 커밋에서 다시 읽었다)

이 문서가 설계 기준이다. 판정은 읽은 head SHA에 대한 것만 센다. PASS는 구현이나 실측이 아니라 설계 판정이다.

## 1. 사용예와 현재 차이

한 머신에서 MASC를 실행하고, 초대받은 사용자만 Google OIDC로 Dashboard에 로그인한다. 각 사용자는 자신의 Codex 또는 Claude Code 구독을 등록하고 기본적으로 본인만 Runtime을 사용한다. 필요하면 credential이 아니라 특정 Runtime의 실행 권한만 공유한다.

현재 코드는 이 사용예를 그대로 지원하지 않는다.

- Dashboard는 `dashboard/src/api/core.ts:194-208`에서 저장한 bearer를 `Authorization`에 붙인다. Keeper 외부 서비스 OAuth(`lib/server/server_keeper_oauth.mli:1-12`)는 Dashboard 사용자의 Google OIDC 로그인과 다른 기능이다.
- 공식 계정 로그인은 `dashboard/src/api/setup-login.ts:22-29`에 있지만 `lib/server/server_setup_account_login.mli:1-4`가 `CanAdmin`을 요구한다. 일반 사용자의 개인 구독 등록 모델과 맞지 않는다.
- `lib/auth/auth.ml:204-225,303-318`은 `auth disabled` 또는 `workspace secret`을 Admin으로 허용한다. 초대받은 principal만 허용하는 모델과 충돌한다.
- `lib/auth/auth_strict_mode.ml:17-20`과 `lib/mcp_server_eio_caller_identity.ml:176-192`는 Strict라고 항상 거부하지 않고 로그 후 caller alias를 유지한다.
- `lib/server/server_mcp_transport_http_headers.ml:267-270`은 MCP cookie에 `Secure`와 `HttpOnly`가 없고 `SameSite=Lax`다.
- official client는 모델 호출과 내장 도구 루프를 소유하고 account-home을 사용한다. MASC가 중개하는 단일 provider 요청 모델을 그대로 적용할 수 없다.
- 자격 증명 레코드 `Types_auth.agent_credential`(`lib/types/types_auth.mli:98-107`)은 token 해시와 `role`을 가지며 `role`이 유일한 역할 권위다. 진행 중인 MCP OAuth(`docs/rfc/RFC-mcp-dual-bearer-oauth.md`)도 정적 bearer와 OAuth token을 같은 `agent_credential` 투영으로 풀고, loopback 승인 화면에서 기존 bearer를 한 번 제시하게 한다.
- official client turn에는 protocol-idle 침묵 감시가 있다. Runtime이 `turn-timeout-s`를 선언하지 않으면 기본 300초가 서고, 0 이하로 선언하면 마감이 없다. 정당한 작업의 길이를 자르는 상한이 아니라 조용해진 client를 알아차리는 값이다(`lib/runtime/runtime_inference.ml:57-69`, `lib/runtime/runtime_claude_code.ml:33-35`).

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
- 실행 시간 전체의 상한(기존 `turn-timeout-s`는 침묵 감시이며 그대로 쓴다), 누적 turn/time/token/cost 상한, ProviderAccount의 가상 principal별 quota 분할.
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
7. **부분 실패를 숨기지 않는다.** `Outcome_unknown`, `Revocation_pending`, `AuthorizationUncertain`, `Quarantined`, `Purge_pending`, `Purged`를 구분한다.
8. **판정은 닫힌 합타입으로 표현한다.** 문자열 비교나 이름으로 권한을 추정하지 않는다.
9. **owner의 부재는 그 의존 사슬만 막는다.** 다른 Cleared 사슬은 계속 실행할 수 있어야 한다.
10. **실제 증명이 없는 공유는 거부다.** lane·readiness·provider 호출·복구 증명이 없으면 다계정을 열지 않는다.
11. **dispatch의 prompt·output·transcript는 initiator의 것이다.** owner와 Admin은 사용량·시각·dispatch_id·결과 종류만 읽는다. 공유는 Runtime의 Use이며 대화 내용의 공유가 아니다. Keeper의 지속 상태(컨텍스트·기억·산출 글)는 만든 dispatch의 initiator를 표시하고, 다른 initiator의 dispatch에는 `Read_state` effect가 허용될 때만 보인다. 허용이 없으면 initiator별로 분리된 컨텍스트로 돌린다. 여러 dispatch의 내용을 합쳐 만든 파생 상태(요약·병합된 기억)의 표시는 원천 initiator 전체이고, 모든 원천이 허용될 때만 보인다. 사람 initiator가 없는 dispatch(autonomous·system)가 만든 상태는 Service(system) 표시를 달고 `Read_state`가 허용된 initiator에게만 보인다. initiator가 Disabled가 되면 그가 만든 분리 컨텍스트와 prompt·output은 지우지 않고 아무도 읽지 못한다. 파생 상태에 그의 몫이 섞여 있으면 읽는 호출은 `Source_sealed`를 돌려받고 값은 보지 못한다. 봉인은 읽을 때 원천 initiator의 현재 상태로 판정하고 표시를 쓰지 않으며, Active로 돌아오면 풀린다. initiator가 삭제되면 그의 몫은 `Delete` 사건과 같은 append로 `Purge_pending`이 되고(§8.5) 감사 메타데이터만 남는다. 파생 상태에 섞인 그 몫에는 원천별 `source_purged` 표시를 달고, 표시가 하나라도 있는 파생 상태를 읽는 호출은 결과 값 `Source_purged`를 돌려받고 값은 보지 못한다. Disabled에서 삭제로 가는 것은 명시 결정이고 시간 경과는 근거가 아니다. `Source_sealed`와 `Source_purged`가 막는 범위는 그 원천이 섞인 파생 상태 하나이고, 다른 원천의 분리 컨텍스트와 다른 파생 상태는 읽힌다(§3-9). 대가는 그 파생 상태에 같이 섞인 다른 initiator의 몫도 읽지 못하는 것이다. 남은 원천의 분리 컨텍스트로 새 파생 상태를 만들 수 있으면 Keeper가 만들고, 만들 수 없는 몫은 잃는다. 몫 단위로 되살리는 설계는 이 문서의 범위가 아니며 알려진 한계다.

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

- ID는 불변이며 삭제 후 재사용하지 않는다. Human의 `user_id`는 OS CSPRNG가 만든 128비트 이상의 값이고 `(iss, sub)`나 email 같은 외부 값에서 유도하지 않는다. principal을 만들 때는 writer lock 안에서 현재 principal과 revocation ledger의 `Delete` 기록 양쪽에 같은 ID가 없는지 검사한다. `user_id`가 겹치면 새로 뽑고, 이름으로 정하는 `service_id`가 겹치면 등록을 거부한다. ledger를 읽지 못하면(`AuthorizationUncertain`) principal을 만들지 않는다.
- Principal의 상태는 `Active | Disabled`이고 삭제된 principal은 레코드가 없다. 삭제는 revocation ledger의 `Delete` 기록(ID만)과 `authz.jsonl`의 `Delete` 사건으로 남는다. `(iss, sub)`는 `authz.jsonl`의 사건에만 싣는다. `authz.jsonl`은 purge 대상이 아니고 결속 사건에서 이미 같은 값을 담고 있어서, 삭제 사건이 새 외부 식별자를 더 남기지 않는다. 삭제된 principal과 같은 `(iss, sub)`로 로그인하면 초대받은 적 없는 사람과 같게 다룬다. 새 초대가 있어야 새 principal이 생기고, 새 principal은 옛 principal의 grant·산출물·표시를 이어받지 않는다. 입장하는 쪽에 삭제 이력을 보이는 방법은 §5.1-6이다.
- Dashboard Admin은 활성 Human principal과 활성 Admin_assignment가 필요하다. 비밀 제시로 role을 만들지 않는다. Admin_assignment의 생성·회수·변경은 `role_epoch`로 기록하고 Admin 경로의 stream·관리 실행만 재평가한다. 개인 Self Runtime은 role 변경만으로 무효화하지 않는다.
- Service/Keeper에는 일반 Admin role이 없다. 필요한 경우 `ManageMachineShared`, `AdminDisableBlock`, `ReadAuditMetadata` 같은 닫힌 개별 권한만 부여한다.
- Admin은 다른 사람의 credential·private Runtime을 사용하지 못한다. Disable/Block/감사와 Service-owned 공유 관리만 한다. 점유 중인 dispatch의 `Executor_teardown`은 `AdminDisableBlock`에 포함한다.
- Admin_assignment 회수에는 `cause = Security_incident | Operational`을 필수로 둔다(§10.4의 Block과 같은 구분). `Security_incident`이면 같은 append로 그 Admin이 author인 MachineSharePolicy와 Delegated grant를 `Revocation_pending`에 둔다. 적격 Admin이 항목별로 재승인(§8.3의 취소 기록)하거나 회수해서만 푼다. `Operational`이면 그 목록을 감사에 남기고 grant는 유효하게 둔다.
- **Admin은 관리 권한으로 자기 자신 또는 자신이 관리하는 principal에게 grant를 만들거나 수정할 수 없다.** 감사에는 author·beneficiary·beneficiary manager를 남긴다. Admin이 Service-owned Runtime을 사용하려면 독립된 Service 관리 owner나 제2 승인자의 grant가 필요하다. 제2 승인자는 author와 다른 principal이며 author의 관리 대상이 아니어야 한다.
- **적격 Admin**은 어떤 항목에 대해 그 항목의 owner, 원 grant 승인자, beneficiary, subject, 그리고 beneficiary와 subject를 관리하는 manager가 아닌 활성 Admin이다. incident 해제(§10.4)와 `Revocation_pending` 취소(§8.3)와 재승인은 적격 Admin만 한다.

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
- 삭제된 principal의 grant는 감사를 위해 `Revoked`로 남기고 실행하지 않는다. Purged 대상의 grant와 artifact도 `Purged`로 표시한다.

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
  | Workspace of workspace_id
```

Intent는 대상 없이 digest만 남기지 않는다. 중단된 회수가 어느 `Grant`·`Credential`·`Principal`·`Runtime`에 대한 것인지 게이트가 식별할 수 있어야 한다. 모드 사건(§5.1)은 회수가 아니라서 이 목록에 들지 않고, 대상은 `Workspace`다.

## 5. 인증과 Provider 등록

### 5.1 모드와 초대

`auth_config.account_mode = Single_user | Multi_account`를 둔다. 파일이나 값이 없으면 `Single_user`이고, 알 수 없는 값이면 부팅을 거부한다. 부팅은 `config.json`을 JSON 파서로 통째로 읽고 최상위 객체의 `account_mode` 멤버만 본다. 문자열이나 정규식으로 멤버를 떼어 내지 않는다. 파일이 JSON이 아니거나 최상위가 객체가 아니면 설정은 없는 것으로 읽는다. 지금 동작과 같고(요청 때 503), 아래 표의 다른 두 열이 `Multi_account`의 흔적을 거부하므로 조용한 강등이 되지 않는다. 파일이 JSON 객체이면 다른 필드가 틀려도 `account_mode` 멤버를 읽는다. 멤버는 정확히 `"Single_user"`나 `"Multi_account"` 문자열이어야 한다. `null`, 숫자, 객체, 다른 대소문자, 두 번 나온 멤버는 알 수 없는 값이고, `auth_config` 디코더가 파일 전체를 거절하더라도 부팅을 거부한다. 이 안전은 불변식에 의존한다. multi-owned record를 만드는 모든 길은 먼저 모드 사건을 `authz.jsonl`과 외부 저장소에 남긴다. 값을 써 넣는 설치·업그레이드 단계는 두지 않는다. principal 수나 초대 수로 모드를 추론하지 않는다. 첫 bootstrap 전에도 `Multi_account`를 선택할 수 있다.

설정 값은 바라는 모드에 대한 요청이다. 부팅 때 설정을 `authz.jsonl`의 마지막 모드 사건이 만든 모드와 외부 고수위(§8.2)에 대조해 모드를 한 번 정한다. 외부 저장소는 backup 밖 append-only 저장소이고, 외부 고수위는 그 저장소에 적힌 값이다. 모드 사건은 셋이다. `Fresh_bootstrap`(§8.4)과 `reactivate`(§10.5)는 `Multi_account`를 만들고 `off`(§10.5)는 `off`를 만든다. 아래 표의 둘째 열은 사건 이름이 아니라 마지막 모드 사건이 만든 모드다. 결과는 표를 따르고, 거부 사유가 여럿이면 모두 돌려준다. 조용한 강등은 읽지 못한 것이나 없는 것을 근거로 `Multi_account` 설치를 `Single_user`로 내리는 것이고, 부팅 판정은 이를 거부한다.

| 설정 | 마지막 모드 사건이 만든 모드 | 외부 고수위 | 결과 |
|---|---|---|---|
| 없음 또는 `Single_user` | 없음 | 없음 | `Single_user`. 현재 동작 그대로다. |
| 없음 또는 `Single_user` | 없음 | 있음 | 부팅 거부. 복원이 설정과 `authz.jsonl`을 함께 되감은 경우다. |
| 없음 또는 `Single_user` | `Multi_account` | 무엇이든 | 부팅 거부. 설정만 낮추는 것은 조용한 강등이다(§11-3). |
| 없음 또는 `Single_user` | `off` | 맞음 | `Single_user`. multi-owned record는 읽기 전용이고, 남은 `Purge_pending`을 끝내는 쓰기(§8.5-5)만 한다(§10.5). |
| `Multi_account` | 없음 | 없음 | 활성화 전 요청이다. 호스트 로컬 bootstrap(`Fresh_bootstrap`, §8.4)만 열고 원격 경로와 실행은 열지 않는다(§5.1-1, §11-5). |
| `Multi_account` | 없음 | 있음 | 부팅 거부. 새 설치가 아니라 되감김이다. `Fresh_bootstrap`은 외부 고수위가 `없음`인 새 설치만 연다(§8.4). |
| `Multi_account` | `Multi_account` | 맞음 | `Multi_account`. §11의 준비 상태는 별개다. |
| `Multi_account` | `Multi_account` | 없음, 안 맞음, 읽지 못함 | `AuthorizationUncertain`으로 시작한다(§8.2, §8.4). |
| `Multi_account` | `off` | 맞음 | `reactivate` 요청이다. §10.5의 `Recovery_manifest`와 `Pending` 절차가 있어야 하고, 없으면 부팅을 거부한다. |
| 없음, `Single_user`, `Multi_account` | `off` | 없음, 안 맞음, 읽지 못함 | 부팅 거부. `off` 뒤에 `reactivate`가 있었는데 그 사이 시점으로 복원했을 수 있다. |
| 알 수 없는 값 | 무엇이든 | 무엇이든 | 부팅 거부. |

외부 고수위 열은 §8.2의 판정 1~5를 먼저 돌린 뒤에 읽는다. 판정은 외부 저장소를 읽어서 내리고, 판정 2의 `Committed` 승격이나 판정 3의 `aborted_intent` 쓰기가 성공했는지는 결과를 바꾸지 않는다(§8.2-2, §8.2-3). 판정 2로 승격되는 `Intent_pending`은 `Committed`에 포함한다. 값은 넷이다.

- `맞음`: 마지막 `Committed`(판정 2로 승격되는 것을 포함)가 replay에 있고, 남은 `Intent_pending`이 판정 1~5로 풀리고, 외부 고수위와 replay의 epoch 값이 같다. lease 줄은 외부 저장소에 가지 않으므로 늘어도 `맞음`은 깨지지 않는다.
- `안 맞음`: 외부 저장소를 읽을 수 있는데 `맞음`도 `없음`도 아니다. §8.2의 판정 1~5를 통과하지 못한 경우가 여기에 든다.
- `읽지 못함`: 외부 저장소나 설치 기록이 있는데 열지 못하거나 손상됐다(§8.4). 쓰다가 죽어 끝이 잘린 마지막 항목은 손상이 아니다. 마지막 줄바꿈 뒤에 남은 바이트만 끝이 잘린 항목이고, 줄바꿈으로 끝났는데 읽히지 않는 항목은 손상이다. 잘린 항목에 든 `Committed`에 의존해 나간 응답은 없고, 잘라 낸 `Committed`는 판정 2가, 잘라 낸 `aborted_intent`는 판정 3이 다시 세운다. 부팅은 외부 저장소를 열 때(판정 1~5를 돌리기 전에) 그 항목을 잘라 내고, 잘라 낸 바이트 수와 남긴 바이트 수를 경고로 남긴다(`authz.jsonl`에서 끝이 잘린 마지막 줄을 자르는 규칙과 같다).
- `없음`: 외부 저장소가 없거나, 있어도 `Committed`가 하나도 없고 남은 `Intent_pending`이 모두 `Fresh_bootstrap`의 것이어서 판정 3이 `aborted_intent`로 정한다(쓰기가 실패해도 판정은 선다). `Fresh_bootstrap`이 `Intent_pending`을 쓴 뒤 `authz.jsonl`에 append하기 전에 죽은 설치가 여기에 든다. 이 설치는 `Fresh_bootstrap`을 다시 실행할 수 있고, 새 `Intent_pending`을 쓰기 전에 남은 것을 판정 3으로 닫는다(§8.2-1). workspace_id는 `Committed`가 된 `Fresh_bootstrap`(판정 2로 승격되는 것을 포함)의 것만 유효하다.

`있음`은 `없음`이 아닌 모든 값(`맞음`, `안 맞음`, `읽지 못함`)이다.

`authz.jsonl`이 있는데 열지 못하거나 검증에 실패하면 설정과 상관없이 부팅을 거부한다. 쓰다가 죽어 끝이 잘린 마지막 줄은 실패가 아니다. 마지막 줄바꿈 뒤에 남은 바이트만 끝이 잘린 줄이고(`Fs_compat` 복구 읽기와 같은 구분이다), 줄바꿈으로 끝났는데 검증에 실패하는 줄은 실패다. 끝이 잘린 줄은 열 때 잘라 내고, 줄이 하나도 남지 않으면 파일이 없는 것과 같이 마지막 모드 사건이 만든 모드가 없다(표 둘째 열 `없음`). 두 자르기(`authz.jsonl`과 외부 저장소)는 서로 읽지 않아서 어느 쪽을 먼저 해도 결과가 같다. 이 파일은 `Fresh_bootstrap`의 append로만 생기므로, 읽지 못한 것을 기록이 없는 것으로 읽으면 조용한 강등이 된다. 외부 고수위는 부팅이 설치 기록(§8.4)에서 외부 저장소의 위치를 읽을 수 있을 때만 `있음`으로 볼 수 있다.

1. 최초 Admin은 호스트 로컬 bootstrap으로 만들고 원격 선착순 Admin은 없다.
2. 신규 사용자는 다음 셋 중 하나로만 입장한다. (a) Admin이 등록한 `(iss, sub)` allowlist, (b) 단회 초대 token, (c) 도메인 정책(7번)을 통과한 첫 로그인이 만든 입장 요청을 Admin이 승인하는 것. 어느 경로든 입장은 첫 OIDC 로그인의 `(iss, sub)` 결속으로 끝난다.
3. 초대 소비·sub 결속·User 생성은 writer lock 안의 unique 검사와 한 append로 완료한다. 동시 소비나 sub 재결속은 409다. 입장 요청의 승인과 (a)·(b)의 User 생성도 같은 구역에서 같은 `(iss, sub)`에 User가 이미 있는지 검사하고, 있으면 409다(§5.1-7).
4. 초대 token은 URL fragment에만 두고 폼 POST로 전달한다. QueryString·Referer·로그에 싣지 않는다. 초대 token은 만료 시각을 갖고 Admin이 발급을 취소할 수 있다. 만료 시간은 구현 계획에서 정한다. token을 가진 사람은 도메인 정책과 무관하게 입장하므로 만료와 취소가 그 범위를 닫는다. email과 handle은 신원 키가 아니다.
5. 계정 링크·병합은 초기에 금지하고, 마지막 Admin의 삭제·강등·비활성화는 거부한다.
6. 등록하거나 소비하거나 입장 요청으로 올라온 `(iss, sub)`에 삭제된 principal의 `Delete` 사건(§4.1)이 있으면 Admin 화면(입장 요청 목록 포함)과 감사 기록에 `previously_deleted`로 보인다. 입장을 막지 않는다. 입장은 Admin의 새 결정이고, 새 principal은 새 ID를 받아 옛 몫을 이어받지 않는다. 이 표시는 `authz.jsonl`을 읽어 만드는 projection이며 principal 레코드에 저장하지 않는다.
7. **도메인 정책과 입장 요청.** 설정 `oidc.admission_request_domains`(입장 요청을 만들 수 있는 `hd`의 소문자 도메인 목록)가 비어 있지 않으면 도메인 정책이 있다. 비어 있으면 도메인 필터가 없고 입장은 (a), (b)뿐이다.
   - 도메인 정책은 (c)의 입장 조건일 뿐이다. 로그인한 `(iss, sub)`가 (a)로 등록돼 있거나, (b)의 초대 token을 소비하는 로그인이거나, 이미 입장한 principal이면 정책을 보지 않는다. Admin이 등록하거나 초대한 것이 그 사람에 대한 명시적 허가이기 때문이다. 그래서 개인 Gmail의 외부 협력자도 (a)나 (b)로 들어올 수 있다. 정책에서 도메인을 빼도 이미 입장한 사용자는 막히지 않는다. 정책을 보지 않는다는 말은 도메인 검사를 건너뛴다는 뜻일 뿐이다. principal이 `Disabled`이면 §4.1의 Disabled 규칙이 정책 면제와 무관하게 그대로 적용된다.
   - 미등록 `(iss, sub)`가 정책 아래에서 로그인하면 callback은 ID token의 `hd` claim을 ASCII 소문자로 바꾼 값이 목록과 정확히 같고 `email_verified = true`일 때만 입장 요청을 만든다. `hd`가 없거나(일반 Gmail 등) 다르거나 `email_verified`가 아니면 어떤 상태도 만들지 않고 거절한다. email 문자열의 접미사나 부분 일치는 쓰지 않는다.
   - 입장 요청(`request_id`, `(iss, sub)`, 표시용 `hd`·email·이름, 요청 시각)은 권한도 session도 주지 않는다. Admin 화면에 보인다. email과 이름은 Admin이 판단하는 표시 자료이고 신원 키가 아니다.
   - 요청의 `hd`·email·이름은 지울 수 있는 별도 저장소에 두고 `authz.jsonl`에 싣지 않는다. `authz.jsonl`은 purge 대상이 아니고 새 외부 식별자를 더하지 않는다는 전제(§4.1)로 둔 로그다. 요청의 생성·거절·만료는 권한을 바꾸지 않으므로 scoped epoch를 올리지 않고 §8.2의 Intent/Committed 대상이 아니다.
   - 요청 저장소에는 `Pending`과 `Rejected`만 저장한다. 요청의 상태는 저장된 값, `authz.jsonl`, 현재 시각으로 계산하는 닫힌 합타입 `Pending | Approved | Rejected | Superseded | Expired`이고, 이 중 `Approved`·`Superseded`·`Expired`는 파생이다. `authz.jsonl`에 이 요청의 `request_id`를 실은 결속 사건이 있으면 저장된 값과 무관하게, 그 User가 나중에 삭제돼도 `Approved`다. 같은 `(iss, sub)`에 User가 있고 그 결속 사건이 이 `request_id`를 싣지 않았으면 `Superseded`다. 요청 시각에서 정해진 시간이 지난 `Pending`은 `Expired`다. 둘 이상이 참이면 `Approved`, `Superseded`, `Rejected`, `Expired`, `Pending` 순으로 처음 참인 것을 상태로 읽는다.
   - 같은 `(iss, sub)`에는 만료 전 `Pending`이 하나만 있다. `Pending` 중 다시 로그인하면 새 요청을 만들지 않고 대기 화면을 보인다. 만료된 요청은 새 요청을 막지 않는다. 만료 판정은 승인 대기 목록과 승인 검사가 같은 시계 값을 쓴다. 승인은 만료 전 `Pending`인 요청에만 한다. User가 삭제되어 `(iss, sub)`가 다시 미등록이 되면, `Superseded`였던 만료 전 요청은 다시 `Pending`으로 읽힌다. 그 요청은 한 번도 쓰이지 않았고, 승인은 Admin의 새 결정이며 `previously_deleted`가 함께 보인다(§5.1-6). 승인된 요청은 `Approved`로 남아 다시 열리지 않으므로, 그 사람이 다시 들어오려면 새 요청을 만들거나 (a)·(b)로 입장해야 한다. 거절 기록도 사람을 따라간다. User가 생겼다가 삭제돼도 보존 기간 안의 `Rejected`는 (c)를 막는다.
   - 승인과 (a)·(b)의 User 생성은 `authz.jsonl`의 한 append이고, §5.1-3의 같은 writer lock 구역에서 `(iss, sub)`의 User 존재를 검사한다. 승인은 초대 소비와 같은 원자 단계로 User를 만들고 그 결속 사건에 `request_id`를 싣는다. 거절은 요청 저장소에만 쓴다. 쓰기 전에 `authz.jsonl`에서 `(iss, sub)`의 User 존재를 읽고, 있으면 409(이미 입장함)를 돌려준다. 두 저장소를 한 원자 단계로 묶지 않는다. 한 Admin의 승인과 다른 Admin의 거절이 겹치면 User가 생긴 쪽이 이긴다. 복원이나 중단으로 요청 저장소가 뒤처져도 User가 있는 `(iss, sub)`의 요청은 `Approved`나 `Superseded`로 읽히고 승인 대기 목록에 나오지 않는다.
   - 승인 때 요청의 `hd`가 그 시점의 정책 목록에 없으면 승인은 거부된다. 정책이 비어 있어도 같다. 그 사람을 들이려면 Admin이 (a)나 (b)로 직접 입장시킨다.
   - `Rejected`인 `(iss, sub)`는 (c)로 새 요청을 만들 수 없다. 마음이 바뀌면 Admin이 (a)나 (b)로 직접 입장시킨다. 요청의 개수 상한과 상한을 넘었을 때의 동작(새 요청을 거절할지 오래된 요청을 밀어낼지), 만료 시간, 종단 요청의 보존 기간은 구현 계획에서 정한다. 보존 기간이 지나 지워지면 `Rejected`의 막힘도 풀린다.
   - 퇴사와 회수는 도메인 정책이 대신하지 않는다. Admin의 명시적 `Disable`·`Delete`(§4.1)가 한다. Google이 계정을 정지하거나 삭제하면 그 계정은 새 ID token을 받지 못해 로그인할 수 없다.

### 5.2 Google OIDC

Authorization Code + PKCE(S256), state, nonce, exact redirect URI를 사용하고 ID Token의 signature/iss/aud/exp/nonce를 검증한다. 도메인 정책(§5.1-7)이 있으면 `hd`와 `email_verified`는 미등록 사용자가 입장 요청을 만들 때의 필수 조건이다. 그러나 이 조건만으로 입장하지 않는다. 입장은 §5.1-2의 세 경로뿐이다.

- `__Host-masc_session`: Secure, HttpOnly, host-only, Path=/, SameSite=Strict.
- `__Host-masc_oidc_txn`: Secure, HttpOnly, host-only, Path=/, SameSite=Lax. state/nonce/PKCE와 서버 transaction에 결속한다.
- `__Host-masc_mcp_session`: Secure, HttpOnly, host-only, Path=/, SameSite=Strict. `mcp-session-id` 헤더와 별개이며 **인증 수단이 아니다.**

transport는 `Browser_session(session_id) | Scoped_pat(pat_id)`에 결속하고 opaque transport ID는 auth session ID와 다르다. 매 요청에 독립 인증을 요구하고 transport ID만으로 principal을 만들지 않는다. auth session/PAT 폐기·재발급 시 transport와 WS/SSE를 닫는다.

`/auth/oidc/callback`은 transaction만 인증 입력으로 사용한다. 기존 session은 새 세션 발급과 같은 원자 단계에서 `session_revoked_at`을 기록해 폐기하고 그 transport를 닫는다. 다른 경로의 transaction cookie는 401이다. 독립 credential이 둘 이상이면 401이지만 auth session과 그에 결속된 transport는 한 인증이다.

callback은 303 대신 비공개 데이터가 없는 200 HTML 완료 화면을 반환한다. same-origin Dashboard 링크 또는 `location.replace`로 이동해 다음 탐색부터 Strict cookie를 사용한다. `return_to`는 로컬 경로만 허용하고 Strict·Secure를 낮추지 않는다. 다계정은 HTTPS를 요구하고 단일 사용자 개발 모드의 기존 cookie 동작을 깨지 않는다.

OIDC Dashboard는 Authorization header를 제거한 뒤 모드를 연다. cookie+Bearer를 cookie가 조용히 이기는 상태는 두지 않는다. CLI/MCP는 scoped PAT 또는 MCP OAuth token을 사용한다. 원격 WS/SSE의 `token` query·`sse_kind=observer`·IDE LSP query credential은 비활성화하고, 기존 query credential은 단일 사용자 loopback의 단회 교환만 허용한다.

### 5.3 credential 선택과 Strict

- `Legacy_workspace_secret`은 parser가 명시적으로 인식하지만 다계정에서는 단독·조합 모두 `Legacy_credential_forbidden`이다. Admin이나 Worker로 해석하지 않는다. HTTP recovery grace는 제거하고 `masc auth recovery`(새 명령, §10.5)의 Local_operator 경로만 사용한다.
- 요청 하나는 `Browser_session`, `Scoped_pat`, `Service_credential`, `Mcp_oauth_token` 중 정확히 하나로 인증하고, 모두 같은 인증 투영(principal + `auth_binding` + `Pat_scope`)으로 풀어 §6.2 판정을 거친다. 두 번째 권한표를 두지 않는다. `Service_credential`은 `Not_pat`이고 범위는 Delegated grant와 DelegatePolicy가 정한다. PAT·Service·OAuth token의 레코드는 `principal`과 `Pat_scope`를 가진 새 형식이고, `agent_name`과 `role`을 가진 `agent_credential`은 다계정에서 읽지 않고, 옛 bearer를 든 요청은 `Legacy_credential_forbidden`으로 Reject한다. Admin은 `Admin_assignment`에서만 온다.
- MCP OAuth는 loopback 전용 승인 화면에서 기존 bearer를 제시하게 한다. 다계정에서는 이 승인을 해당 Human의 OIDC session에 결속하고, 발급한 token은 `Pat_scope`와 같은 범위 필터를 가진다. 이 결속은 OAuth 스택이 main에 들어간 뒤 별도 층에서 구현한다. 그 층이 들어오기 전까지 `Mcp_oauth_token`은 Reject한다.
- `auth disabled`, `require_token=false`, `MASC_ALLOW_ANONYMOUS_MUTATIONS=true`는 다계정 부팅·활성화를 거부한다. 이 검사는 기존 기능이 아니라 새 요구사항이다.
- HTTP `http_auth_strict_enabled`와 MCP caller strict를 `Auth_gate.decide = Allow(principal) | Reject(reason) | Log_only(evidence)`로 통합한다. 다계정은 Reject가 실제 응답일 때만 허용하고 token 해석 실패 후 caller alias 유지 경로는 제거한다. 다계정에서 `Log_only` 처분은 금지한다. route 표의 모든 항목이 `Reject`를 반환함을 보이는 시험이 있어야 다계정을 연다. `MASC_AUTH_STRICT=strict` 값만으로는 통과하지 않는다.
- session cookie가 조금이라도 있으면 bearer 유무와 무관하게 same-origin과 session-bound CSRF token을 모두 요구한다. `Option.is_some token` 우회와 GET mutation은 금지한다. credentialed cross-origin CORS는 기본 거부다.
- agent query/header와 `x-masc-keeper-name`은 Actor_hint다. 제시한 service hint가 credential의 service_id와 다르면 거부한다. 익명 rate-limit은 직접 접속 peer IP이며 Actor_hint로 나누지 않는다. 인증 진단 endpoint는 Admin 전용이며 token·hash·credential 본문을 반환하지 않는다.
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
6. 연결 때 lane이 CLI가 실제로 읽는 credential 저장소 종류(`file | keychain | 그 밖`)를 확인해 기록한다. CLI의 자기 신고는 증거가 아니다. 이 값은 §7.2의 증명 묶음에 넣어 lease에 기록하고, dispatch 때 다르면 `NoAuthorizedRuntime`이다. `file` 밖의 저장소는 MASC가 읽는 경로가 증명되기 전까지 `Sign_in_required`로 거부한다. keychain 지원은 이 문서의 범위 밖이며 미검증이다. 같은 구분이 `Runtime_muse_home`의 `sign_in_gap`에 있다.

## 6. 실행 인가

### 6.1 Runtime 조회와 실행

`Runtime_view.t`는 목록·설정·표시용이고 실행할 수 없다. `Authorized_runtime.t`는 abstract 타입으로, attempt를 시작할 때와 failover 후보를 고를 때마다 `Runtime.authorize`로 발급한다. attempt 하나에 결속하며 저장소·캐시에 두거나 다른 attempt에 넘기지 못한다. 발급 근거는 닫힌 합타입 `Authorization_basis = Stored_grant of Grant_id.t | Single_user_operator`다. `Single_user`는 저장된 grant를 읽지 않고 `Single_user_operator` 근거로만 발급하며, `Multi_account`는 이 근거를 만들 수 없다. `Single_user_operator`는 owner가 operator 자신인 Runtime에만 발급하고, 다른 principal이 소유한 Runtime에는 발급하지 않는다(§10.5). 발급 당시의 근거 값(`Stored_grant`의 grant_id 또는 `Single_user_operator`)은 lease와 durable work(schedule·resume·retry) record에 남기고, `Authorized_runtime.t` 자체는 저장하지 않는다. 모드는 부팅 때 정해지고 실행 중에 바뀌지 않는다. 바꾸려면 §10.5의 전환 절차를 거친다. string ID만으로 실행 객체를 얻는 경로는 금지한다. 허용 후보가 없으면 `NoAuthorizedRuntime`이며 다른 principal의 private Runtime으로 failover하지 않는다.

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

- `current_grant`는 저장된 Self/Delegated의 status·expires_at·grant_epoch·resource_epoch·현재 owner·membership을 검사한다. ownership predicate를 별도 인가 경로로 쓰지 않는다. `initiator_grant`·`executor_grant`는 각각 `current_grant(initiator, runtime)`·`current_grant(executor, runtime)`가 돌려주는 저장된 행이다.
- `Not_pat`은 교집합에서만 중립 필터이며 `Empty`와 혼동하지 않는다. grant/policy/PAT의 effect는 모두 현재 범위를 좁히는 필터이며 넓히지 못한다. Direct의 중립 policy와 `All`도 현재 grant 안으로 제한된다.
- `invocation_allowed`는 initiator=executor인 Direct를 허용하되 grant와 effects는 그대로 요구한다. 외부 initiator의 Delegate·Schedule·BoardTrigger는 현재 일치하는 DelegatePolicy가 필요하다.
- 영속 작업은 원본 `{initiator, executor, channel, stored_scope}`를 유지하고 발화·재시도·resume 때 **initiator와 executor 양쪽의 현재 grant**를 재확인한다. 원본 권한이 철회된 뒤 executor grant만으로 실행하지 않는다. chain은 감사 기록이며 권한 확장 근거가 아니다.
- Disabled이거나 삭제된 principal은 새 실행과 새 durable record 생성이 모두 거부된다. 순수 system 이벤트만 initiator=Service(system)이며, Human schedule이 cron으로 발화할 때도 initiator는 Human이다.
- `author`는 record writer, `initiator`는 실행 권한 출처다. 비실행 진단 record만 initiator가 없을 수 있다.

### 6.3 authorless writer 경계

```text
System_cron        -> 허용된 trigger evidence만
System_maintenance -> 실행/lease 종단 evidence와 사전 승인된 만료만
System_migration   -> migration 진단 record만
```

`RuntimeGrant`, `DelegatePolicy`, `Principal`, `InternalServiceCredential`, 명시적 permission revocation은 인증된 author가 필요하다. owner는 자기 자산, Admin은 허용된 관리 행위, 로컬 복구와 `Fresh_bootstrap`은 `Local_operator`만 쓴다. migration 기동은 호스트 로컬 운영자/런처 전용이며 actor·run_id를 남긴다.

자동 만료는 `Preauthorized_expiry(cause_event_id)`로 닫고 author는 System_maintenance다. 원 승인자와 원 승인 사건을 보존하고, 원 승인자가 삭제된 뒤에도 새 서명 없이 만료를 적용한다. revalidation 성공 증거나 새 grant·owner 변경·임의 회수에는 쓰지 않는다.

## 7. Runtime별 lease와 도구

### 7.1 MASC 중개 요청·도구

`Provider_request`는 MASC가 중개하는 provider 요청 1건, `Masc_tool_effect`는 MASC가 중개하는 tool effect 1건이다. lease ID만으로 credential을 얻을 수 없다.

- lease 발급은 writer lock 안에서 `Authorized_runtime.t`의 grant·fencing을 저장소 최신 상태와 비교한다. 다르면 조용히 재발급하지 않고 `NoAuthorizedRuntime`이다. 같은 attempt의 두 번째 tool 전 회수라면 다음 lease를 거부한다.
- `Provider_request`는 `Lease_dispatched`가 회수보다 먼저 기록된 한 응답만 일반 회수 후 완료할 수 있다. `Lease_dispatched`가 발급과 전송 허가의 선형화 지점이며 Active와 Request_sent를 모호하게 합치지 않는다. 그 전 회수라면 전송하지 않는다. 다음 입력·재시도는 새 lease다.
- `Masc_tool_effect`는 일반 회수에서도 `Revoked`와 취소 채널·checkpoint·효과 직전 재확인으로 종료한다. 이미 전송된 외부 호출·공개 데이터의 회수는 약속하지 않는다.

`Provider_request`·`Masc_tool_effect`·`Official_client_dispatch`의 lease는 (자원, 그 자원의 writer가 발급하는 단조 카운터)이며 한 번 쓰면 다시 쓰지 못하는 선형 자원이다. 상태는 닫혀 있다. `Lease_dispatched`는 그 lease가 허가한 일(요청 전송, 효과 실행, incarnation 기동)을 시작해도 되는 선형화 지점이다.

```text
Lease_state =
  Issued | Lease_dispatched | Completed of (Effected | Not_started)
  | Revoked of (Cancelled | Teardown | Grant_revoked)
  | Outcome_unknown
```

- 발급은 `with_lease` 범위 안에서만 한다. attempt 종료·fiber 취소·executor teardown 중 어느 경로로 나가도 범위 출구에서 `Issued`는 `Revoked`로, `Lease_dispatched`는 종단 기록이 있으면 `Completed`(효과가 나갔으면 `Effected`, 나가기 전에 실패했거나 취소됐으면 `Not_started`), 없으면 `Outcome_unknown`으로 닫는다. 종단 기록이 실패하면 삼키지 않고 `Outcome_unknown`으로 올린다. `Revoked`의 하위 값은 닫은 원인이 정한다. attempt 종료·fiber 취소·`Effect_cancel`은 `Cancelled`, `Executor_teardown`과 재기동은 `Teardown`, scoped epoch 회수(§8.1)는 `Grant_revoked`다. 효과가 시작되지 않은 `Issued` lease는 어느 경로로 닫혀도 `Outcome_unknown`이 되지 않고 reconciliation 질문도 만들지 않는다.
- 효과는 `consume`으로만 일으킨다. `consume`은 `Issued`에서 한 번만 성공하고 `Lease_dispatched`를 동기 commit한 뒤에 효과를 낸다. 같은 lease의 두 번째 `consume`과 `Revoked` lease의 `consume`은 거부하고 audit record를 남긴다.
- 재기동 때 `Issued`로 남은 lease는 질문 없이 `Revoked(Teardown)`로 닫는다. `Lease_dispatched`로 남은 lease만 `Outcome_unknown`이 되어 §9의 확인 대상이 된다.

도구 registry의 효과 분류는 닫힌 `Read_only | Effecting`이다. 분류가 없는 새 tool은 Effecting이다.

- `Read_only`: dispatch credential·현재 scoped fencing·snapshot 권한·출력 ACL을 매 호출 검사하지만 외부 상태를 바꾸지 않으므로 lease append는 하지 않는다. 허용된 단일 조회 응답만 완료하고 다음 호출에는 현재 snapshot을 다시 읽는다. Runtime 실행·Manage를 새로 허용하지 않는다.
- `Effecting`: 기존 `Masc_tool_effect` lease와 동기 commit·취소 채널을 적용한다.

### 7.2 official-client dispatch

Codex/Claude Code는 credential을 CLI가 읽고 한 dispatch에서 여러 요청과 내장 도구를 실행한다. 따라서 `Official_client_dispatch`의 단위는 **인증된 CLI process incarnation 하나 + dispatch 하나**이며 `dispatch_id`로 구분한다. Request_sent·한 응답 완료·MASC tool lease를 이 경로에 적용하지 않는다.

broker는 `Lease_dispatched` 기록 뒤에만 account-home을 최소 연결하고, 일반 회수에서도 process tree 종료와 account-home 연결 해제를 실행한다. 연결이나 spawn이 CLI 실행 전에 실패하면 broker가 그 실패를 종단 기록으로 남겨 lease를 `Completed(Not_started)`로 닫고 attempt는 `Failed(Not_started)`로 끝낸다. CLI 실행 전에 `Effect_cancel`이 오면 같은 방식으로 lease를 `Completed(Not_started)`로 닫고 attempt는 `Cancelled_before_effect`로 끝낸다. 두 경우 모두 `Outcome_unknown`도 확인 질문도 만들지 않는다. `Lease_dispatched`는 시작하려 했다는 기록일 뿐이고 시작하지 못했다는 증거는 이 종단 기록뿐이므로, 그 기록을 쓰지 못하면 §7.1대로 `Outcome_unknown`이다. 다음 입력은 새 incarnation·새 lease다.

공유/Delegated official 실행은 다음 둘 중 하나를 **현재 후보의 레인 실측으로 증명할 때만** 허용한다.

- `Inference_only`: 내장 도구·MASC MCP·credential/debug 출력을 비활성화한 순수 추론이다. 도구가 필요한 Keeper 실행에는 쓸 수 없다.
- `Isolated_tools`: trusted official runtime에만 account-home을 두고 내장 tool subprocess·initiator·다른 Keeper가 credential/account-home을 읽을 수 없음을 증명한다. allowed_effects를 실제 sandbox/tool 정책으로 강제하고 종료를 검증한다. CLI 내장 도구 정책으로 옮길 수 없는 effect는 거부한다.

증명은 `{cli_binary_digest, effective_config_digest, credential_store_kind, state_separation, lane_identity, host_kernel, filesystem_type, eio_version, evidence_id}`에 결속하고 lease에 기록한다. `state_separation`은 executor별 state 디렉터리의 digest와, 다른 executor로 그 디렉터리를 읽으려다 거절된 시험의 `evidence_id`다. dispatch 시점 값이 다르거나 증명이 없으면 `NoAuthorizedRuntime(Lane_not_isolated | Attestation_stale)`이다. Human의 Keeper도 owner와 executor가 달라 private 예외가 아니다. owner=executor인 private 실행만 executor별 격리 하에 허용한다. 미검증 lane에 account-home을 mount하지 않는다. 호스트에서 직접 도는 경로는 다계정에서 열지 않는다.

### 7.3 dispatch MCP credential

official CLI가 MASC MCP를 부를 때는 **dispatch 전용 MCP credential**을 발급한다. `{dispatch_id, lease_id, initiator, executor, worker_instance, fencing, allowed_effects}`에 결속하고 관리·새 dispatch·재위임 권한이 없다. 각 Effecting 호출은 별도 `Masc_tool_effect` lease를 요구하며 dispatch lease Revoked와 함께 무효다. 장수 Service token이나 wall-clock TTL로 대체하지 않는다.

official runtime에만 전달하고 내장 tool 자식에서 제거하지 못하면 `Isolated_tools` 증명이 실패한다. `Inference_only`에는 발급하지 않는다. tool/Execute/비신뢰 자식에는 Service credential을 넣지 않으며 부모가 여러 credential을 가지면 `MultipleServiceCredentials`로 spawn을 거부한다.

## 8. scoped epoch·log·회수

### 8.1 epoch과 읽기 모델

```text
principal_epoch  : principal Disable/Delete/RevokeAll에만 증가
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

`authz.jsonl`의 writer lock은 최신 snapshot 검증 + append/fsync + 새 불변 snapshot 발행에만 쓴다. epoch를 올리거나 `credential_generation`을 바꾸는 사건은 §8.2의 고수위 쓰기도 같은 구역에서 한다. 읽기는 lock-free snapshot, replay는 기동·복구 때만이다. grant·lease 발급·회수·Lease_dispatched는 동기 commit이다. Completed evidence는 다음 동기 commit에 함께 실을 수 있지만 손실되면 완료로 추정하지 않고 `Outcome_unknown`이다. lease 계열 commit(발급·`Lease_dispatched`·`Revoked`)은 group commit을 허용한다. 한 fsync로 대기 중인 writer 여럿을 묶되, 각 writer의 응답은 자기 record가 fsync된 뒤에만 나간다. blocking I/O는 main domain에서 분리하고 authorize/append/flush를 각각 측정한다.

### 8.2 고수위와 Intent/Committed

backup 밖 append-only 저장소에는 객체의 scoped epoch 최고값·artifact별 `credential_generation`·Intent 상태를 기록한다. 이 저장소와 아래 Intent/Committed 규칙은 **scoped epoch를 올리거나 `credential_generation`을 바꾸는 사건**(Grant·Revoke·Disable·Delete·Block·Purge·정책 회수·credential 교체)과 모드 사건(`Fresh_bootstrap`, `off`, `reactivate`. §5.1)에만 적용한다. lease 발급·`Lease_dispatched`·`Completed`·`Revoked`는 `authz.jsonl`에만 쓰고 발급 때 읽은 epoch에 결속한다. replay 값과 외부 고수위가 다르거나 외부 저장소를 읽지 못하면 `AuthorizationUncertain`으로 시작하고 옛 lease·점유·grant를 승인하지 않는다. 고수위 일치는 무결성 조건이지 실행 승인 조건이 아니다.

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

1. 고수위는 Intent_pending으로 시작하고 authz append/fsync 뒤 `Committed(record_hash)`로 갱신한다. snapshot 발행 뒤에만 성공 응답을 돌려준다. Committed 전 성공 응답은 없다. `Intent_pending` 쓰기, authz append/fsync, `Committed` 갱신은 같은 writer lock 구역 안에서 하고, 그 구역이 열려 있는 동안 lease 계열 commit(group commit 포함)은 끼지 않는다. 그래서 intended record의 직전 해시는 `Intent_pending`의 `previous_record_hash`와 같다. 새 `Intent_pending`을 쓰기 전에 남아 있는 것을 아래 2~5로 먼저 판정한다. 재기동 때만이 아니라 writer lock에 들어올 때마다 한다. append가 실패해도 프로세스는 계속 살아 있기 때문이다.
2. `Intent_pending`이 남아 있고 replay에 `intended_next_record_digest`와 일치하는 record가 있으면 **digest를 검증하고 Committed로 승격**한다. record가 이미 있으므로 의도를 다시 실행하지 않고 고수위 포인터만 완료한 뒤 현재 scoped fencing을 다시 검사한다. digest가 다르면 `AuthorizationUncertain`이다.
3. `Intent_pending`인데 replay의 head가 `previous_record_hash`와 같고 intended record가 없으면 `Incomplete_append_aborted`로 기록하고 intended event를 재생하지 않는다. 기록은 외부 저장소에 `aborted_intent {intended_next_record_digest, intended_event_kind, subject}`를 append하는 것이며 `Intent_pending`을 지우지 않는다. `aborted_intent`가 가리키는 `Intent_pending`은 이후 판정(1~5)에서 제외하므로, head가 움직인 뒤에도 같은 의도를 다시 판정하거나 `AuthorizationUncertain`으로 읽지 않는다. 응답이 나가지 않은 미완료 의도이며 `aborted_intent`로 epoch 간격의 이유를 남긴다. 재기동 때 해소되지 않은 `aborted_intent` 중 `intended_event_kind`가 §8.3의 권한 축소 사건인 것만 읽어 그 차단을 다시 세운다. 새 Grant 같은 나머지는 차단하지 않고 다시 승인받는다. 이 판정이 서면 §8.3의 차단을 바로 세우며, `aborted_intent`를 쓰는 데 성공해야 세우는 것이 아니다. `aborted_intent`를 쓰지 못하면 `Intent_pending`이 그대로 남아 다음 writer lock 진입이나 재기동이 같은 판정으로 되돌아온다. 저장소가 계속 실패하는 동안은 새 `Intent_pending`도 쓸 수 없으므로 scoped epoch 사건은 성공하지 못한다(§8.4). `Fresh_bootstrap`의 `Intent_pending`이 이 판정으로 닫히면 §5.1의 `없음`이다.
4. `Committed(h)`인데 replay에 h가 없으면 미완료 append가 아니라 **응답한 사건의 롤백**이다. `AuthorizationUncertain`으로 시작하고 되돌아온 Active grant를 실행하지 않는다. replay에 h가 있으면 포인터만 완료하고 현재 scoped fencing을 다시 검사한다.
5. `Intent_pending`은 intended record의 존재와 head 위치로, `Committed`는 `record_hash`의 존재로 판정한다. 위 어느 가지도 아니면(예: record가 없는데 head가 `previous_record_hash`와 다르다) 되감기나 구역 밖 append의 흔적이므로 `AuthorizationUncertain`이다. 일반 크래시와 실제 복원 누락을 같은 가지로 처리하지 않는다.
6. backup 밖 저장소가 실제 backup 대상에서 제외되는지 T/T+1/T+2 리허설의 경로·제외 목록·digest로 증명한다.

### 8.3 중단된 보안 회수

`Incomplete_append_aborted`이고 `intended_event_kind`가 권한을 줄이거나 credential을 무효화하려는 사건(`Revoke`, `Disable`, `Delete`, `Block`, `Purge`, 정책 회수, credential 교체)이면 해당 `subject`를 **로그를 건드리지 않고 게이트에서만 `Revocation_pending`으로 차단**한다. grant 행이 Active로 보여도 새 dispatch·lease·tool effect를 허용하지 않는다.

- 새 Grant·credential 생성·일반 설정 변경은 자동 재생하지 않고 다시 승인한다.
- `Revocation_pending`은 **재시도 append 성공** 또는 **적격 Admin(§4.1)의 명시적 취소 기록** 중 하나로만 닫는다. 두 출구 record는 닫는 `aborted_intent`를 가리키고, 가리키는 record가 없는 `aborted_intent`는 재기동 뒤에도 차단을 유지한다. 재시도는 새 요청이며 aborted 의도를 이어 쓰지 않고 새 `Intent_pending`으로 시작한다. owner나 공격자가 임의로 해제하지 못한다. 적격 Admin이 없으면 실행을 재개하지 않고 Local_operator가 `Quarantined(cause=No_eligible_admin)`로 보낸다.
- 중단된 회수라는 표시만 남기고 Active로 실행하지 않는다. 자동 재생과 `Revocation_pending`은 다른 개념이다.

### 8.4 신규 설치와 읽기 실패

이 절은 `Fresh_bootstrap`을 실행하는 경우와 마지막 모드 사건이 있는 설치에 적용한다. 모드 사건이 없는 `Single_user` 설치는 외부 저장소가 없는 것이 정상이고 그대로 시작한다(§5.1 표 첫 행). 외부 저장소가 없을 때(`ENOENT`, 부모 경로 부재) 새로 시작할 수 있는 것은 명시적 `Fresh_bootstrap`뿐이다. §5.1이 `없음`으로 읽는 저장소도 같다.

외부 저장소의 위치는 설치 기록에서 읽는다. 설치 기록은 `$XDG_CONFIG_HOME/masc/`(없으면 `~/.config/masc/`) 아래에 base path 단위로 두는 파일이고 외부 저장소의 경로를 적는다. 기록 안에도 canonical base path를 적어 읽을 때 대조한다. 설치 기록은 임시 파일에 쓰고 fsync한 뒤 rename하고 부모 디렉터리를 fsync한다. 그래서 읽는 쪽이 보는 파일은 없거나 온전하고, 온전하지 않은 기록은 손상이다. `Fresh_bootstrap`은 설치 기록을 먼저 쓰고 외부 저장소를 만든다. 외부 저장소가 있는데 설치 기록이 가리키지 않는 상태를 만들지 않기 위해서다. `Fresh_bootstrap`은 외부 고수위가 `없음`일 때만 열리므로 설치 기록이 이미 있어도 그 기록이 가리키는 저장소는 `없음`이다. 이때는 기록을 같은 방식으로 새 경로로 교체한다. 설치 기록이 없거나 가리키는 곳에 외부 저장소가 없으면 부팅은 외부 고수위를 `없음`으로 읽는다(§5.1). 설정 디렉터리를 알 수 없으면(`XDG_CONFIG_HOME`과 `HOME`이 모두 없다) 설치 기록이 없는 것이고, 이때 `Fresh_bootstrap`은 기록을 쓸 수 없어 거부한다. 설치 기록이 없는데 `Fresh_bootstrap`이 외부 저장소를 만들 경로에 파일이 이미 있으면 그 파일을 열지 않고 실패한다. 기록 없이 옛 저장소를 덮거나 잇지 않기 위해서다. 설치 기록과 외부 저장소는 백업 복원이 되돌린 것을 알아채려는 장치다. 설정 디렉터리와 base path에 모두 쓸 수 있는 쪽은 막지 못한다.

`Fresh_bootstrap`은 **Local_operator가 서명한** 새 workspace_id·새 `account_mode`(`Multi_account`)·빈 `authz.jsonl`·빈 Recovery_manifest·초기 generation이 같은 bootstrap append로 확인되어야 한다. workspace_id도 외부 저장소와 같은 append에 기록한다. `Fresh_bootstrap`이 확인하는 `account_mode`는 `Multi_account`뿐이다. `Multi_account`를 거친 적 없는 `Single_user`는 `authz.jsonl`을 쓰지 않는다(§9.2).

`EACCES`·다른 I/O 오류·손상 JSON(쓰다가 죽어 끝이 잘린 마지막 항목은 제외, §5.1)·디렉터리·심볼릭 링크·workspace_id 불일치는 `AuthorizationUncertain`으로 거부한다. 설치 기록도 같아서, 읽지 못하거나 손상됐거나 디렉터리나 심볼릭 링크이면 거부한다. 마지막 모드 사건이 있는데 외부 저장소가 없거나 생성 규칙이 맞지 않으면 실행하지 않는다. 외부 고수위를 생략하고 legacy 경로로 부팅하지 않는다.

외부 저장소가 복구되지 않으면 창은 닫히지 않는다. `/health`와 `account_busy`에 `Recovery_store_unavailable`과 필요한 운영 조치를 표시하고, stale snapshot으로 Cleared를 만들지 않는다.

### 8.5 purge의 지정과 삭제

purge는 지정과 삭제가 따로다. 삭제된 initiator의 컨텍스트·prompt·output(§3-11)과 Quarantined 자산의 credential(§10.4)에 같은 규칙을 쓴다.

1. 지정은 authz append 하나로 `Purge_pending {target}`을 기록한다(initiator 삭제이면 삭제와 같은 append다). 이 append는 §8.2의 `Purge` 사건(initiator 삭제이면 `Delete` 사건)이므로 Intent/Committed 규칙을 따른다. 대상은 지정 시점의 ID 목록이 아니라 initiator(또는 자산) 표시로 정한다. 지정 뒤 그 initiator의 새 shard 쓰기는 §6.2 판정에서 거부된다.
2. `Purge_pending`인 대상은 삭제가 끝나기 전에도 읽을 수 없다.
3. 삭제는 대상에 쓸 수 있는 dispatch가 모두 종단에 이른 뒤에 시작한다. 지정 뒤 새 dispatch는 §6.2에서 거부되고, 진행 중인 dispatch는 지정이 올린 epoch(§8.1)로 회수되어 끝난다. official dispatch는 executor 종료를 attestation으로 확인해야 한다(§9.1). 확인하지 못했다는 것은 회수가 건 취소와 §9-4의 teardown(SIGTERM 뒤 SIGKILL/VM teardown)이 끝났는데도 lease 종단이나 executor 종료 attestation이 없다는 뜻이다. 이 대기에 새 시간 상한은 없다. 그 경우 지우지 않고 `Purge_failed {target, failed_stage: Writer_not_terminated}`로 끝낸다. 삭제는 writer lock을 잡지 않고 대상 표시가 붙은 shard·transcript·credential을 ID 단위로 멱등하게 지운다. 남은 대상이 0임을 확인하면 `Purged {target, deleted_count}`를 `authz.jsonl`에 append한다. 이 append만 writer lock 구역에서 한다. 쓸 수 있는 주체가 모두 끝난 뒤에 지우므로 `Purged` 뒤에 대상 표시가 붙은 데이터가 새로 생기지 않는다.
4. 삭제가 실패하면 `Purge_failed {target, failed_stage}`를 append하고 대상은 읽을 수 없는 채로 둔다. `Purge_failed`는 Dashboard와 `/health`에 보이고, 다음 재기동이나 Local_operator의 명시 재실행으로만 다시 한다.
5. 재기동 때 남은 `Purge_pending`은 모두 이어서 삭제한다. `Purge_pending`은 `Purged` 아니면 눈에 보이는 `Purge_failed`로만 끝나며 무기한 남지 않는다.
6. `Purge_pending`과 `Purged`는 target 단위로 멱등이다. 복원이 지운 데이터를 되살려 같은 target을 다시 지정하면(§10.5) `Purged`가 한 번 더 나가고, 읽는 쪽은 target의 마지막 사건을 현재 상태로 본다.

## 9. worker·account-home·취소

1. lease에는 dispatch_id·runtime_kind·initiator/executor·runtime/grant·worker_instance·server_boot·attestation·scoped fencing·auth_binding을 기록한다. server_boot_id는 기동마다 OS CSPRNG로 새로 만들고 worker_instance는 프로세스/VM 회차마다 새로 증명한다.
2. `attestation = Spawn_nonce | Mtls | Os_identity | Broker_attestation`이다. Spawn_nonce는 전용 IPC의 단일 사용자 개발 전용이며 다계정에서 허용하지 않는다. 다계정은 lane별 VM instance ID·OS process/boot identity·broker run ID의 실제 출처를 요구하고 미증명 lane은 실행 불가다. 격리·attestation을 먼저 완료한다.
3. worker 종료·channel closed·supervisor exit 같은 실제 사건으로 미종료 lease를 §7.1의 출구 규칙으로 닫는다(종단 기록이 없는 `Lease_dispatched`만 `Outcome_unknown`이고, 기록이 있으면 `Completed`, `Issued`는 `Revoked(Teardown)`이다). 임의의 N초 heartbeat TTL은 없다. 침묵하는 dispatch는 Runtime의 `turn-timeout-s` 선언 또는 §9.1의 `Executor_teardown`으로 끝낸다. 다음 worker가 예전 lease를 재사용하지 않는다.
4. 취소는 `Effect_cancel | Executor_teardown`이다. per-effect shim이 없으면 executor 전체를 종료하고 영향 lease를 §7.1의 출구 규칙으로 닫는다(종단 기록이 없는 `Lease_dispatched`만 `Outcome_unknown`이고, 기록이 있으면 `Completed`, `Issued`는 `Revoked(Teardown)`이다). 다른 principal은 종료하지 않는다. process tree SIGTERM 후 종료가 확인되지 않으면 SIGKILL/VM teardown을 사용하며 미증명 lane은 제외한다.
5. `Outcome_unknown`은 `Failed(Outcome_unknown)`이라는 attempt 종단이며 AuthorizationUncertain보다 우선한다. 복원 Cleared가 이전 lease를 살리지 않는다. attempt가 `Outcome_unknown`이 되는 것은 `Lease_dispatched` lease가 종단 기록 없이 닫힐 때뿐이다(§7.1). 효과가 시작되기 전에 끝났고 그것이 기록된 attempt는 `Outcome_unknown`이 아니며 확인 질문도 만들지 않는다. 시작 전에 취소된 attempt의 종단은 `Cancelled_before_effect`이고 시작 전에 실패한 attempt의 종단은 `Failed(Not_started)`다. 둘 다 attempt의 종단이며 lease 상태나 대기 항목의 종단이 아니다. 같은 사건에서 `Issued` lease는 §7.1대로 `Revoked`로 닫히고, `Lease_dispatched` 뒤 실행 전에 실패했거나 취소된 lease는 `Completed(Not_started)`로 닫힌다. 시작 전이란 lease가 `Issued`이거나 `Completed(Not_started)`로 기록된 경우다. 이미 종단에 이른 attempt의 종단은 전이·복원·off 전환이 바꾸지 않는다. attempt 종단 전체의 목록(성공 종단 포함)은 기존 dispatch 정책이 소유한다. 이 문서가 더하는 종단은 `Failed(Outcome_unknown)`, `Failed(Not_started)`, `Cancelled_before_effect` 셋이다.
   - 전송 전이라면 현재 권한으로 새 attempt를 만들 수 있다. 시작 전 실패(`Failed(Not_started)`)의 재시도 횟수도 기존 retry 정책을 따르며 이 문서가 새 상한을 만들지 않는다.
   - 전송된 provider 요청은 idempotent로 단정하지 않는다. 기존 dispatch 정책이 새 lease·새 인가·duplicate_possible로 새 attempt를 만들 수는 있지만 exactly-once는 주장하지 않는다.
   - `Inference_only`가 아닌 official dispatch나 Non_idempotent/불명 tool effect는 외부 결과 확인 뒤 새 attempt를 만든다. idempotency key나 외부 dedup 증거가 있는 tool만 자동 새 attempt를 허용한다.
   - 확인이 필요한 attempt는 영구 Pending이 아니라 실패 종단이다. 원 initiator Human 또는 Keeper의 지정 Human owner, ownerless Keeper나 system initiator이면 Local_operator에게 별도 reconciliation 질문을 남긴다. 질문에 대한 응답이 새 attempt를 만들며 다른 턴·작업은 막지 않는다. 정상 종료(graceful drain)에서는 진행 중 dispatch의 `Completed(Effected)` evidence를 동기 commit한 뒤 닫아 질문을 만들지 않는다. 중단된 dispatch의 확인 질문은 (executor, 재시작 사건) 단위 한 건으로 묶는다.

### 9.1 account-home single-flight와 대기

같은 ProviderAccount의 official account-home은 single-flight다. credential 파일 동시 갱신 가능성을 가정하지 않고 한 incarnation만 연결한다. 대기자는 credential 없이 기다리고 lock을 얻은 뒤 writer lock에서 현재 권한을 다시 검사한 뒤 mount/spawn한다. 회수되면 대기를 취소하고 authz writer lock을 잡은 채 account-home lock을 기다리지 않는다.

- 대기열은 ProviderAccount별 단일 FIFO다. owner와 `managed_by=owner`인 Keeper/Service도 같은 줄에 서며 순위 가중치나 선점 횟수 규칙은 없다. owner는 자기 ProviderAccount의 점유 중인 dispatch를 `Executor_teardown`으로 끊을 수 있고(끊긴 dispatch의 종단 기록 없는 `Lease_dispatched` lease는 `Outcome_unknown`이다, §7.1), 대기 중인 grantee 항목도 취소할 수 있다. 취소된 항목은 `Owner_cancelled`로 종단하고 failover 규칙은 그대로다. owner는 대기열의 grantee·도착 시각·dispatch_id를 보지만 prompt는 보지 못한다. 대기 항목은 재기동을 넘지 않고, 재기동 때 사라지는 항목의 attempt는 효과가 시작되기 전이므로 `Cancelled_before_effect`로 끝난다(`Outcome_unknown`이 아니다, §9-5). `Owner_cancelled`는 owner가 취소한 대기 항목의 종단이며 재기동으로 사라지는 경우와 겹치지 않는다. 항목의 종단이지 attempt의 종단이 아니고, 그 attempt는 기존 failover 규칙을 따른다. 영속 work(schedule·retry·resume)는 새 attempt가 다시 줄을 서고, 호출자가 연결돼 있던 직접 HTTP/WS 요청은 다시 줄서지 않으며 initiator에게 `Cancelled_before_effect`로 보인다.
- `account_busy`에는 대기 수와 `Account_recovery_pending`을 구분해 보인다. owner와 Admin에게는 holder의 dispatch_id, 점유 시작 시각, 마지막 출력 이벤트 시각(관측값이며 판정 기준이 아니다)을 보여 주고 prompt·credential은 노출하지 않는다. grantee에게는 사유 코드만 보이고 항목 ID는 숨긴다. owner가 부재하면 Admin이 `AdminDisableBlock`으로 holder를 `Executor_teardown`한다.
- 침묵 감시는 기존 Runtime의 `turn-timeout-s` 선언을 그대로 쓰고 새 값을 만들지 않는다. 선언자는 Runtime owner다. 선언이 없으면 기존 기본값이 서고, 0 이하로 선언하면 마감이 없다. 마감이 오면 기존 `Timeout` typed 실패로 `Executor_teardown`이 되고, 그때 종단 기록이 없는 `Lease_dispatched` lease는 `Outcome_unknown`이 된다(§7.1). 마감이 없는 Runtime에서 dispatch가 멈추면 `account_busy`의 holder 정보를 보고 owner나 Admin이 하는 `Executor_teardown`이 출구다. 출력을 조금씩 흘려 이 감시를 피하는 holder도 같은 출구로 끊는다. 알려진 한계다.
- account-home은 credential과 state로 나눠 다룬다. credential은 ProviderAccount당 하나이고 한 번에 한 incarnation만 쓴다. 대화 기록·cache·프로젝트 설정 같은 state는 executor principal별 디렉터리에 둔다. 다음 incarnation은 이전 executor의 state를 읽지 못해야 한다. 분리 방식은 lane마다 달라도 되지만(`Runtime_muse_home`은 managed credential generation과 native session/data 디렉터리를 나눈다) §7.2의 증명에 이 분리가 들어가야 한다.
- 점유는 `{provider_account_id, dispatch_id, server_boot_id, worker_instance_id, state}`로 영속 기록한다. 재기동 뒤 이전 점유는 **이전 worker 종료와 account-home 연결 해제가 attestation으로 확인된 뒤에만** 해제한다. 확인하지 못하면 `AuthorizationUncertain`으로 새 mount/spawn을 거부한다. teardown 후 credential 무결성을 검증하고 확인하지 못하면 owner 재인증 또는 로컬 운영자의 Quarantined로 진행한다. credential을 오래된 backup에서 자동 복원하지 않는다.

### 9.2 동시성

다계정에서 같은 ProviderAccount의 official dispatch는 항상 Single_flight다. 동시 실행은 이 설계 범위가 아니다. credential 갱신을 쓰는 쪽이 둘 이상이면 그 CLI의 갱신 구간에 동기화 지점을 넣을 수 없어 갱신 경쟁이 없다는 것을 증명할 수 없다. 동시성이 필요해지면 credential 갱신을 MASC broker 하나가 맡고 incarnation에는 읽기 전용 사본만 주는 설계를 별도 문서로 연다.

Single_user 모드의 현재 동작은 바꾸지 않는다. 계정당 동시 dispatch 1의 처리량 비용은 §12의 기준선 측정으로 확인한다.

## 10. 복원·귀속·모드 전환

### 10.1 `Cleared`와 계승

`Cleared = {cleared_epoch, evidence_id, method}`이며 `method = Integrity_carry_forward | Owner_revalidated | Admin_incident_cleared`다. 실행은 모든 의존 사슬이 `cleared_epoch = 현재 transition_epoch`인 경우에만 허용한다. 과거 epoch의 Cleared를 그대로 현재 권한으로 읽지 않는다.

- 새 전이에서 `cleared_epoch < transition_epoch`인 record를 전부 owner가 다시 승인할 필요는 없다. 현재 manifest·generation·revocation 고수위·principal 상태·grant·policy·runtime·membership이 이전 Cleared 이후 **인가 관련 변경이 없음**을 확인한 record는 `Integrity_carry_forward`로 현재 epoch의 Cleared를 기록할 수 있다. 이것은 새 grant가 아니라 기존 권한의 무결성 계승이다. `Integrity_carry_forward`는 author=System_maintenance가 다음을 모두 만족할 때만 기록한다. (a) record digest가 마지막 Cleared 시점과 같다. (b) 그 객체의 외부 고수위가 record의 epoch와 같고 그 뒤의 회수 사건이 없다. (c) 의존 사슬의 모든 항이 같은 방식으로 Cleared다. `Security_incident` Block 대상, Quarantined, 외부 고수위에 흔적이 없는 record(복원본에서만 존재하는 것)는 계승할 수 없다. 계승마다 (a)(b)(c)의 입력 값을 `evidence_id`로 남기고, 분류 단계의 authz append는 한 묶음 단위로 Intent/Committed 규칙을 적용해 중단되면 같은 묶음을 이어서 한다.
- 계승은 **전 record 일괄 epoch 갱신이 아니라 의존 사슬별 판정**이다. `Recovery_manifest` 항목별로 증거 입력과 digest를 남기고, 각 사슬을 독립적으로 평가한다. 배치를 실행의 선행 조건으로 두지 않아 전이 중 전역 정지를 만들지 않는다.
- 변경·누락·판정 불일치가 있는 record만 Pending으로 남기고 Active 원 owner·원 승인자 또는 Service 후계가 `Owner_revalidated`로 닫는다. 증명하지 못하면 자동 계승하지 않는다. 부재 owner의 Pending은 그 의존 사슬만 막고 다른 Cleared 사슬은 실행한다.
- 창은 manifest 게시와 모든 record/artifact의 분류가 끝나는 시점에 닫는다. Pending이 0이라는 뜻이 아니다. 분류 도중 크래시하면 같은 transition_epoch와 manifest를 재사용해 이어서 분류하고, 새 epoch이나 부분 계승 상태를 만들지 않는다. 분류할 수 없는 record(파싱 불가, 참조 끊김, digest 불일치)는 `Denied(unclassifiable)`로 확정하고 `failed_stage`와 digest를 manifest에 남긴 뒤 분류가 끝난 것으로 센다. 창 중 purge로 대상이 사라진 항목은 여기에 넣지 않고 §10.5의 `Purged_during_window`로 센다. credential을 품은 record는 `Denied` 대신 `CredentialUncertain`으로 두고 Quarantined로 보낸다. 창 중 도래한 `Preauthorized_expiry`는 분류 단계에서 다시 유도한다.

### 10.2 전이 중 work

전이 시작 전에 새 dispatch·새 grant·새 durable work를 먼저 거부하고, 이미 진행 중인 dispatch는 §9-5에 따라 종결한다. 효과가 시작된 **Effecting dispatch는 `Outcome_unknown`**이고 시작 전에 끝난 것은 §9-5가 정한 종단(`Cancelled_before_effect` 또는 `Failed(Not_started)`)을 따른다. 창 중 도착한 효과는 성공한 work로 적용하지 않고 새 record로 현재 epoch 검사를 받는다. account-home은 unmount 확인 전 `Release_pending`이다. `Read_only` dispatch도 새로 받지 않는다. 긴급 Block·Disable·Revoke는 창 중에도 거부하지 않는다.

복구 안내 Board 글은 typed `recovery_notice`로 표시하고 **subscription 후보 생성 필터와 dispatch 진입 검사 양쪽**에서 Keeper wake를 제외한다. `recovery_notice`의 작성자는 Local_operator와 manifest 게시 시스템 이벤트뿐이며, 복원 창이 열려 있는 동안만 유효하다. 창이 닫히면 `closed`로 바꾸고 wake 제외는 유지한다. 일반 Board 글에 문자열로 wake를 끄는 규칙은 두지 않는다. Cleared 승인자에게는 wake 대신 Dashboard 배지와 별도 inbox로 자기 항목 수를 보여 준다.

### 10.3 귀속은 claim 후보다

1. ownerless 귀속 append는 `candidate_owner=bootstrap`과 `Self.status=Revoked(Attributed_unclaimed)`를 기록한다. 이 시점에 Active Self는 없고 bootstrap principal이 Admin이든 Service이든 실행할 수 없다.
2. 후보 목록은 후보 본인·Admin·Local_operator가 읽는 projection으로 노출한다. 후보는 자기 항목을 조회·claim할 수 있지만 credential은 볼 수 없다.
3. 후보 Human이 현재 OIDC 인증으로 본인임을 확인하고 `ManageOwnProvider`와 provider 재인증·credential 결속을 완료하면, 그 claim append에서 **새 grant_id의 Active Self**를 만든다. 관리 권한의 자기 승인이 아니라 명시적 소유 수락이다. Revoked 행을 다시 Active로 바꾸지 않는다.
4. 후보가 Service이면 그 Service 관리 owner가 같은 절차를 수행한다. Local_operator는 후보를 지정할 뿐 claim·Cleared·실행을 대신하지 않는다. claim이 없으면 자산은 Disabled/Pending이며 MachineShared로 승격하지 않는다.
5. 검증은 귀속 즉시 실행이 아니라 **claim 완료 후 저장된 새 Self로 owner direct가 성공하고 구 Self·구 Delegated는 실행되지 않는 것**이다.

### 10.4 Block·Pending·Quarantine

1. Block record에 `cause = Security_incident | Operational`을 필수로 둔다. 원인이 없는 기존 Block은 `Security_incident`로 취급한다.
2. `Security_incident` 해제 후에는 원 owner·원 grant 승인자가 스스로 Cleared할 수 없다. **적격 Admin(§4.1)이 owner가 수행한 provider 재인증·credential 교체·격리 증거를 확인하고 항목별로 Cleared한다.** Admin이 owner 대신 재인증하거나 credential을 읽는 것은 아니다.
3. `Operational` 해제 후에는 Active 원 owner·원 승인자 또는 Service 후계가 Cleared한다. 두 경우 모두 Unblock이 lease·stream·durable work를 자동 재개하지 않는다.
4. Security_incident를 해제할 때 적격 Admin(§4.1)이 없으면 Unblock/Cleared하지 않고 Local_operator가 `Quarantined(cause=No_eligible_admin)`로 기록한다. 적격 Admin이 생기면 같은 항목을 `Admin_incident_cleared`로 풀 수 있고, 이때도 2번의 항목별 증거 확인을 그대로 요구한다. owner 부재로 그 증거를 만들 수 없으면 해제하지 않고 purge로만 종단한다. purge는 Local_operator의 명시 결정과 적격 Admin이 없다는 확인 기록을 요구하며, 시간 경과는 근거가 아니다. 관리자 부재나 이해충돌을 이유로 owner에게 해제 권한을 돌려주지 않는다.
5. **부재가 확인된 owner의 Pending은 Local_operator의 Quarantined로만 종단하고 그 의존 사슬은 Disabled로 내린다.** Pending을 무기한 감사에 남기지 않는다. Quarantined 후보는 의존 단계 재검증이 명시적으로 실패한 record이며 `failed_stage`, `failure_evidence_id`, `manifest_id`를 필수로 남긴다. 시간 경과를 실패로 취급하지 않는다.
6. Quarantined는 일반 재활성화·공유·실행이 불가능하다. 종단은 로컬 운영자의 명시적 purge이거나, `cause=No_eligible_admin`인 항목의 Admin 해제다. purge는 §8.5의 두 단계(`Purge_pending`, 삭제 뒤 `Purged`)로 하며, credential 조회나 grant 재검증 없이 대상 ID·실행자·사유·결과를 audit/revocation ledger에 남기고 credential을 파기한다. 비밀이 아닌 model/execution config는 읽기 전용으로 export하고 credential은 파기한다. grant는 이전하지 않는다. Purged를 복원으로 Active로 승격하지 않는다.

### 10.5 복원·모드·ledger

- 복원·롤백 직후 모든 공유·실행은 AuthorizationUncertain이다. snapshot Active·ledger replay·store_seq 고수위만으로 해제하지 않는다. 도메인 상태와 별도의 `restore_disposition = Pending | Denied | Cleared | Quarantined | Purged`를 둔다.
- Disabled·삭제·purged initiator·executor·owner의 durable work는 먼저 Denied로 확정하고 나중에 계정이 활성화돼도 자동 복귀하지 않는다. `Outcome_unknown` lease는 되살리지 않는다.
- 복원본에서 되살아난 principal 레코드는 다른 분류보다 먼저 ID로 revocation ledger의 `Delete` 기록과 대조한다. 같은 ID가 있으면 레코드를 삭제로 확정하고(복원은 삭제를 되돌리지 않는다) 그 `(iss, sub)`를 실은 `Delete` 사건을 `authz.jsonl`에 다시 남긴 뒤, 그 principal의 grant·work·shard를 위 규칙으로 분류한다.
- 컨텍스트 shard와 파생 상태도 복원 분류 대상이다. 복원본의 `source_purged` 표시는 옛 상태이므로 믿지 않고, revocation ledger(아래)의 삭제 기록과 shard·파생 상태의 initiator 표시를 대조한다. 삭제된 initiator의 몫은 읽기 전에 `Purge_pending`(§8.5)으로 다시 올리고, 파생 상태의 그 몫에는 `source_purged`를 다시 붙인다. Disabled initiator의 몫은 §3-11의 읽기 시점 판정이 그대로 봉인한다. 이 분류가 끝나기 전에는 컨텍스트 shard와 파생 상태 읽기를 `AuthorizationUncertain`으로 거부한다. `Purged`를 복원으로 되살리지 않는다는 §10.4-6의 원칙은 컨텍스트에도 적용한다.
- 남은 record는 Principal/credential → grant/policy → Runtime → schedule/resume/work 의존 순서로 재검증한다. Admin/Service → system cron → Human은 같은 단계의 우선순위일 뿐이며 Pending/Denied work는 cron이 열리더라도 실행하지 않는다. Cleared는 원 grant 승인자 또는 Service의 Admin 지정 후계가 항목별로 승인한다.
- Recovery_manifest는 전 record의 ID·의존 관계·분류·digest를 접근 제한된 artifact로 게시한다. 전이 시작에 `Outcome_unknown`으로 종결한 dispatch와 창 중 purge로 대상이 사라진 항목(`Purged_during_window`)은 분류와 별도 칸으로 센다. 독자는 Cleared 승인자·Admin·Local_operator로 제한하고 owner/승인자는 자기가 승인할 entry만 projection으로 읽는다. Board/health에는 count와 미해제 상태만 공개한다. manifest에는 산출 명령·대상 범위·전이 epoch·분류 count·digest를 기록한다.
- backup/rollback에서 되돌아온 account-home과 credential artifact는 `CredentialUncertain`이다. **현재 owner가 provider official 재인증을 완료하고 새 credential generation과 account-home을 검증하기 전에는 mount하지 않는다.** MASC principal의 Dashboard 로그인만으로 Cleared하지 않는다. 비밀이 아닌 설정만 별도 projection으로 복원하고 credential-bearing home은 새로 만든다. owner가 없거나 재인증할 수 없으면 Local_operator가 Quarantined로 기록하고 purge한다. provider에서 아직 유효한 token이라도 사용하지 않는다.
- 일반 재기동이나 on/off만으로 backup을 되돌린 것은 아니라면, artifact와 외부 generation이 일치하는지 대조해 provider 재인증 없이 기존 credential을 재검증할 수 있다. 평시 재기동에 Recovery_manifest가 없어도 generation을 대조한다.
- revocation ledger 현재본은 backup과 분리된 append-only 저장소에 유지하고 backup 사본과 합집합으로 대조한다. 고수위 불일치·누락이 있으면 AuthorizationUncertain이며 일치도 실행 승인 근거가 아니다. T 백업 → T+1 revoke R → T+2 복원 후 R 유지·연결 work Denied·유효 lease 0을 확인한다.
- 최초 활성화 전 initiator가 없는 legacy work는 `Denied(legacy_unattributed)`로 분류하고 Service(system)으로 신원을 세탁하지 않는다. `Single_user_operator` 근거로 기록된 durable work는 initiator가 없는 것으로 보고 `legacy_unattributed`로 분류한다(§6.1). initiator/scope가 없는 record는 **각 transition_epoch 직전의 무귀속 record**로 분류하고 `legacy_unattributed | legacy_scope_missing`으로 둔다. Local_operator author로 총계·Denied·Cleared·미분류를 기록하고 미분류 0을 확인한다. ownerless 자산은 dry-run 후 bootstrap principal에 명시 귀속하고 귀속하지 못하면 Disabled이며 MachineShared로 승격하지 않는다.
- 다계정 on→off에서는 multi-owned record를 읽기 전용으로 보존하고 legacy 공유 token/admin으로 실행하지 않는다. 진행 중 multi dispatch·session은 종료하고 재활성화 시 동일한 Recovery_manifest·Pending 절차를 거친다. `off` 사건 때 진행 중인 dispatch는 §9-5에 따라 종결하고(효과가 시작된 것은 `Outcome_unknown`, 시작 전에 끝난 것은 §9-5가 정한 종단을 따른다) account-home 점유는 `Release_pending`으로 바꿔 unmount 확인 뒤에만 Released로 한다. off의 기존 단일 사용자 동작 확인은 multi-owned 자산을 legacy로 여는 의미가 아니다. `off`와 `reactivate`는 각각 `authz.jsonl`에 모드 사건으로 남고 외부 저장소에도 남는다(§8.2). §5.1의 부팅 판정은 마지막 모드 사건이 만든 모드를 읽는다. `off` 상태의 `Single_user`는 남은 `Purge_pending`을 끝내는 쓰기(§8.5-5)만 `authz.jsonl`에 한다.
- 로컬 복구는 인증 가능한 Admin이 0명이거나 IdP 복구 불가일 때 `masc auth recovery --base-path <path>`(현재 코드에 없는 새 명령)로 연다. 호스트 관리자와 root 소유 일회용 recovery 파일이 필요하고 실행자·사유·시각·결과·파일 digest·파기 결과를 append-only audit/Board에 남긴다. 원격 break-glass는 없으며 활성화 전 리허설한다. 이 경로에서 Local_operator는 `Admin_assignment`를 새로 발급할 수 있다. 발급받은 principal의 grant와 Cleared에는 관여하지 않고, 감사에 이 사실을 남긴다.

## 11. MultiAccountReadiness

`account_mode = Multi_account` 자체는 실행 허가가 아니라 요청이다. 실제 활성화에는 테스트 실행기가 산출한 `MultiAccountReadiness`가 필요하다.

1. readiness에는 route inventory와 각 경로의 실제 Reject/CSRF/credential 단일성 증명, `legacy_workspace_secret_callers=[]`, `agent_credential_callers=[]`, `auth disabled`·`require_token=false` 부팅 거부 증명, Provider 두 계정 호출·제3자 거부, official lane 격리·복구 리허설 결과, `lib/runtime`에서 string만으로 실행 객체를 얻는 경로(`get_runtime_by_id`, `runtime_id_for_keeper`, `get_runtime_ids`, `capability_of_runtime_id`, `keeper_assignments`, `resolve_assignment` 등)의 잔존 0, MCP OAuth 결속 층 전에는 `Mcp_oauth_token`이 Reject라는 시험을 포함한다. `auth disabled` 부팅 거부는 기존 코드에 있다는 의미가 아니라 새로 추가할 요구사항이다.
2. 각 증명은 build 전체가 아니라 **그 항목이 읽는 표면의 digest**에 결속한다. route 표·credential parser·lane 격리·Provider fixture·복구 리허설이 각각 `evidence_id`와 digest를 가진다. 운영자가 문서나 빈 boolean으로 `ready=true`를 쓰는 경로는 없다. 누락·미검증·digest 불일치·legacy 잔존이 있으면 열지 않는다.
3. digest 불일치 시 `Multi_account_readiness_stale(surface)`로 **부팅·활성화를 거부**하고 `/health`와 로그에 같은 사유를 표시한다. 재-readiness 없이 Single_user로 조용히 강등하거나 legacy 인증으로 돌아가지 않는다. 변경된 표면의 항목만 다시 실행한다.
4. Provider 실계정 증거는 상시 CI가 아니라 후보·Provider 관련 표면이 바뀐 경우에 갱신한다. 실제 계정의 credential 상태도 확인하고, 검증 당시와 다른 계정·credential·Provider 설정이면 그 증거를 사용하지 않는다.
5. `Fresh_bootstrap`도 readiness 없이 원격 다계정을 열지 않는다. loopback 로컬 복구는 별도 Local_operator 경로로 제한한다.
6. Single_flight 대기 시간(§12)의 측정값은 readiness의 evidence로 요구한다. 허용 여부는 운영자가 그 값을 보고 내린 명시 결정을 evidence에 기록해서 정하고, 숫자 기준은 문서에 두지 않는다.

## 12. 필수 적대 시나리오

### 인증·입장·세션

- 초대 동시 소비·sub 재결속·잘못된 issuer/nonce/audience/state는 거부한다. 마지막 Admin 보호와 로컬 복구 리허설을 확인한다.
- 삭제된 `(iss, sub)`를 다시 등록하거나 초대하면 새 ID로 입장하고 옛 grant·산출물·표시를 이어받지 않으며 `previously_deleted`가 보인다. 새 principal ID가 현재 principal이나 ledger의 `Delete` 기록과 겹치면 `user_id`는 다시 뽑고 `service_id`는 거부하며, ledger를 읽지 못하면 principal을 만들지 않는다.
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
- 중단된 Revoke/Disable은 `Revocation_pending`으로 차단하고 재시도 성공 또는 Admin 취소만으로 해제한다. 보안 사건에서 Active로 실행하지 않는다. 중단된 새 Grant는 차단하지 않고 다시 승인받는다. `aborted_intent` append가 실패하면 `Intent_pending`이 남아 같은 판정으로 되돌아온다.
- `Intent_pending`에 record가 있으면 digest를 검증해 Committed로 승격하고, record가 없으면 abort하며, `Committed(h)`가 replay에 없으면 롤백으로 거부한다.
- 복원 후 Active grant·취소된 schedule·Disabled principal이 자동 실행되지 않고, Recovery_manifest·Denied·Pending·Cleared·Quarantined가 의존 순서로 기록된다.
- 부재 owner의 Pending은 Local_operator의 Quarantined로만 종단하고 다른 Cleared 사슬은 계속 실행한다. 계승 배치를 기다리는 전역 정지는 없다.
- 복원된 account-home은 owner provider 재인증 전 mount하지 않고, 일반 재기동은 generation이 같으면 재인증 없이 검증한다. 외부 저장소 불일치·읽기 실패는 `AuthorizationUncertain`이다.
- `Recovery_in_progress` 중 진행 중인 dispatch는 §9-5에 따라 종결한다. 효과가 시작된 Effecting dispatch는 `Outcome_unknown`이고 시작 전에 끝난 것은 §9-5가 정한 종단(`Cancelled_before_effect` 또는 `Failed(Not_started)`)을 따른다. 창 중 도착한 효과는 성공으로 적용하지 않는다. 복원 Cleared로 부활하지 않는다.
- initiator가 Disabled가 되면 그의 컨텍스트·prompt·output은 지워지지 않고 읽히지 않으며 Active로 돌아오면 다시 읽힌다. initiator의 `Delete`는 `Purge_pending`에서 `Purged`로 끝난다. 삭제 도중 크래시하면 재기동이 이어서 지우고 그 사이 읽기는 거부된다. `Delete` 시점에 effecting 중인 dispatch가 있으면 그 dispatch가 끝난 뒤에 삭제가 시작되어 `Purged` 뒤 같은 initiator 표시 데이터가 0이고, 종료를 확인하지 못하면 `Purge_failed {Writer_not_terminated}`다. 시간 경과만으로 Disabled가 삭제되지 않는다.
- T 백업 → T+1 initiator `Delete`와 purge → T+2 복원 뒤, 되살아난 principal 레코드는 먼저 `Delete` 대조로 삭제 확정되고 분류가 끝나기 전 컨텍스트 shard·파생 상태 읽기는 `AuthorizationUncertain`이다. 분류 뒤 그 initiator의 몫은 다시 지워지거나 `source_purged`로 표시되어 `Read_state`가 허용된 다른 initiator도 읽지 못한다. 창 중 purge된 항목은 `Purged_during_window`로 세고 `Denied(unclassifiable)`로 세지 않는다.
- `Single_user`에서 만든 durable work는 `Single_user_operator` 근거로 기록되고, `Multi_account` 활성화 뒤 `Denied(legacy_unattributed)`로 분류된다.

### official·동시성·성능

- 두 실제 Codex/Claude 계정이 올바른 구독으로 호출되고 제3자 호출·Admin private 사용·Keeper로의 묵시적 공유·미검증 delegated official이 거부된다.
- 같은 account-home 동시 요청은 한 incarnation만 연결하고 완료 후 owner 로그인이 유지된다. 한 dispatch가 침묵해도 대기자는 `account_busy`로 holder를 보고, owner 또는 Admin이 `Executor_teardown`으로 풀 수 있으며, owner 쪽 Keeper가 grantee를 계속 앞지르지 못한다. 한 grantee의 dispatch가 끝난 뒤 다음 executor가 그 prompt·output·transcript를 읽지 못한다.
- 재기동으로 대기열이 사라지면 영속 work는 새 attempt로 다시 줄을 서고, 직접 HTTP/WS 요청의 initiator는 `Cancelled_before_effect`를 본다.
- A의 Keeper 기억에 있는 값이 B의 dispatch 출력에 나오지 않고, B의 prompt가 다음 initiator C의 dispatch에 보이지 않는다.
- dispatch MCP credential 회수 뒤 Read_only/Effecting 호출이 모두 거부되고, Read_only에는 lease append가 없어도 인가·출력 ACL이 유지된다.
- lease가 취소·teardown·크래시로 끝나는 모든 경로에서 `Issued`가 남지 않고, 같은 lease로 효과가 두 번 나가지 않는다. `Issued` lease는 어느 경로에서도 `Outcome_unknown`이 되지 않고 reconciliation 질문을 만들지 않는다. `Lease_dispatched` 기록 뒤 CLI 실행 전에 mount나 spawn이 실패하면 lease는 `Completed(Not_started)`이고 attempt는 `Failed(Not_started)`이며 질문이 없다. 그 종단 기록을 쓰지 못하면 `Outcome_unknown`이다. 종단 기록이 있는 `Lease_dispatched`는 그 기록의 종단(`Completed(Effected)` 또는 `Completed(Not_started)`)으로, 없는 것은 `Outcome_unknown`으로 닫히고 둘이 서로 바뀌어 기록되지 않는다. CLI 실행 전 `Effect_cancel`은 lease `Completed(Not_started)`와 attempt `Cancelled_before_effect`로 끝난다.
- 300 Keeper 부하에서 authorize/append/flush p99·snapshot 지연·복원 직후 일제 기상·owner/grantee 대기 수·credential/process/filesystem/trace 격리를 실측한다. 권한 검사를 생략해 목표를 맞추지 않는다. 먼저 Single_user의 계정당 동시 official dispatch 수와 지연을 기준선으로 재고, 같은 부하의 대기 시간을 다계정 Single_flight에서 잰다. §8.2의 writer lock 구역 점유 시간(`Intent_pending` 쓰기부터 `Committed` 갱신까지)도 직접 잰다.

## 13. 검토 요청과 미검증

이 문서를 기준으로 다음을 적대 검토한다.

- **인증**: legacy Admin·workspace secret·cookie·PAT·membership·scope·readiness의 우회가 없는가?
- **SSOT/타입**: Self·Delegated·MachineSharePolicy·Pat_scope·DelegatePolicy·scope/effect 수식이 모순 없이 구현 가능한가?
- **lifecycle**: `Revocation_pending`·`Outcome_unknown`·`AuthorizationUncertain`·`Quarantined`·`Purge_pending`·`Purged`가 상태와 출구를 잃지 않는가?
- **Runtime**: official-client의 credential·도구·process·MCP credential·single-flight·재시도가 실제 실행 모델과 맞는가?
- **복구**: carry-forward가 부분 epoch·전역 정지를 만들지 않으며, 중단된 회수·복원된 credential·미완료 Intent가 부활하지 않는가?

미검증 사항은 명확히 남긴다. 이 문서는 구현·빌드·PR·실제 Google OIDC 로그인·두 Provider 계정 호출·성능·복구 리허설·구독 약관 검토를 증명하지 않는다. 구현 착수 전에 현재 head의 source와 위 시나리오를 다시 대조하고, 설계상 P0/P1/P2 해소와 독립 리뷰가 필요하다.

## 참고

- [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect): `sub`는 안정적인 사용자 식별자이고, ID Token 검증이 필요하다.
- [RFC 9700, Best Current Practice for OAuth 2.0 Security](https://datatracker.ietf.org/doc/rfc9700/): Authorization Code·PKCE·redirect/token 보호.
- [RFC 10017, OAuth 2.0 for Browser-Based Applications](https://datatracker.ietf.org/doc/rfc10017/): browser 애플리케이션의 BFF·cookie/token 보호.
