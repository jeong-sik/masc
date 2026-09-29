---
rfc: "codex-account-quota-scope"
title: "Codex 한도의 주인은 홈이 아니라 그 홈이 지금 쓰는 계정이다"
status: Draft
created: 2026-09-28
updated: 2026-09-28
author: vincent
supersedes: []
superseded_by: null
related: ["0433", "0464"]
implementation_prs: []
---

# Codex 한도의 주인은 홈이 아니라 그 홈이 지금 쓰는 계정이다

## 요약

MASC 는 Codex 의 사용량과 한도 소진을 **계정 홈 경로**(`CODEX_HOME`)로 묶는다.
Codex 가 한도를 매기는 단위는 홈이 아니라 **ChatGPT 계정**이다.
그래서 두 방향으로 틀린다.

- 홈 둘이 같은 계정을 쓰면 MASC 는 계정 둘로 본다.
  Overview 에 같은 숫자가 두 줄로 나오고, 한쪽이 소진돼도 다른 쪽 후보는 뒤로 가지 않는다.
- 홈 하나에 `codex login` 을 다시 하면 계정이 바뀐다.
  MASC 는 같은 주인으로 보고, 옛 계정의 소진 기록과 사용량 창을 새 계정에 그대로 붙인다.

제안은 이렇다.

1. 계정은 Codex app-server 의 안정 계약인 `account/rateLimits/read` 응답의 `accountId` 로 안다.
   같은 workspace 의 여러 seat 를 합치지 않도록 `account/read` 의 `email` 과 짝짓되, 두 값과 기록할 사건이 같은 인증 주인에게 속한다는 증거가 필요하다 (결정 1).
2. Codex turn 은 `account/read` 다음에 이 읽기를 **보내기만 하고** `thread/start` 로 간다. 답은 turn 이 도는 동안 받는다.
   읽기가 늦거나 실패해도 turn 은 기다리지 않는다.
3. 그 turn 의 기록은 읽기와 turn 의 인증 주인이 같다고 확인된 계정에 붙인다. 답이나 귀속 증거가 없으면 그 홈에만 걸리는 별도 variant 에 둔다.
4. 홈이 지금 어느 계정을 쓰는지는 프로세스 안 관측 표 하나에 둔다. 현재 자격 증명 세대의 가장 새 읽기가 계정을 확인하지 못하면 그 홈은 "미확인" 이 된다. 옛 세대의 읽기는 이 표를 되돌리지 못한다.
5. 홈의 계정이 바뀌어도 기록은 옮기지 않는다. 기록은 계정의 것이고, 홈은 가리키는 계정만 바꾼다.

게이트·만료 시각·호환 코드는 더하지 않는다.

이 문서는 **Draft** 다. 아래 "관측 귀속의 구현 선행 조건" 두 항목은 아직 충족하지 못했다.
같은 프로세스에서 받은 두 응답이나 요청 순번만으로 계정 공유·기록을 구현해도 된다는 뜻이 아니다.

## 지금 어떻게 동작하나

### scope 를 정하는 곳

- Runtime 을 만들 때 scope 를 정하고 얼린다.
  Codex 는 `Runtime_codex_app_server.effective_account_home` 이 고른 홈으로
  `Runtime_quota_window.scope_of_codex_home` 을 부른다 (`lib/runtime/runtime.ml:301`, Codex 갈래 `:328-331`).
  얼리는 이유는 PR #28219 에 있다. 나중에 다시 고르면 바뀐 환경변수로 다른 자격 증명에 기록이 붙는다.
- scope 는 `Official_client_home ("codex-app-server", home)` 이다 (`lib/runtime/runtime_quota_window.ml:11-15`, `:108-134`).
  두 scope 는 client 와 home 문자열이 같을 때만 같다 (`:97-106`).
- Codex Keeper turn 은 시작할 때 scope 를 한 번 더 계산한다 (`lib/keeper/keeper_codex_runtime.ml:1672-1675`).
  `account-home` 이 없으면 이 계산은 호출할 때의 `CODEX_HOME` 을 읽는다 (`lib/runtime/runtime_codex_app_server.ml:1926-1939`).
  MASC 안에 `CODEX_HOME` 을 바꾸는 코드가 없어서 두 값은 지금 어긋날 수 없다. 이 RFC 가 이 계산을 지우는 것은 정리이지 수정이 아니다.
  이 turn 의 사용량 창은 이 두 번째 값에 기록된다 (`:285-288`).

### 한도 소진이 기록되고 읽히는 길

- Codex turn 이 `usageLimitExceeded` 나 `sessionBudgetExceeded` 로 거절되면 둘 다 "사용량 소진" 으로 묶이고
  (`lib/runtime/runtime_codex_app_server.ml:462-465`), `HardQuota { retry_after = None }` 가 된다 (`lib/keeper/keeper_codex_runtime.ml:498-507`).
- turn driver 는 이를 `Hard_quota` 경로로 읽고, 리셋 시각이 없으니
  `Runtime_quota_window.note_observed_exhausted ~scope` 를 부른다 (`lib/keeper/keeper_turn_driver.ml:845-853`, `:913-915`).
  scope 는 dispatch 직전에 잡은 후보의 scope 다 (`:791`). 이 scope 를 주는 함수는 후보 순서에도 쓰인다 (`:594`, `:617-623`, `:715`).
- 이 기록에는 끝나는 시각이 없다. 같은 scope 로 호출이 한 번 통과해야 지워진다 (`lib/runtime/runtime_quota_window.ml:36-50`, RFC-0433).
- 후보 순서는 scope 가 소진인지 묻고, 소진이면 뒤로 보낸다 (`lib/keeper/keeper_turn_driver.ml:202-245`).
- 거절 뒤에는 같은 홈으로 `account/rateLimits/read` 를 백그라운드에서 한 번 읽는다 (`lib/keeper/keeper_codex_runtime.ml:296-304`, `:1432-1436`).
  이 결과는 운영자에게 보여 주는 사용량 표에 들어간다. 모델 호출을 막는 창이 다 찼고 리셋 시각이 있으면,
  403 뒤 읽기와 같은 규칙으로 같은 scope 를 그 시각까지 쉬게 한다 (`lib/runtime/runtime_provider_usage_read.ml`, `read_codex_after_spent_usage`).

### 사용량 창이 기록되고 보이는 길

- 서버가 시작할 때 scope 마다 한 번 읽는다. 같은 scope 의 runtime 이 여럿이면 한 번만 읽는다
  (`lib/runtime/runtime_provider_usage_read.ml:58-70`, 호출은 `lib/server/server_bootstrap_maintenance.ml:510`).
  Codex 는 `refresh-s` 반복 읽기 대상이 아니다 (`lib/runtime/runtime_provider_usage_read.ml:311`).
- 표는 `(scope, limit_id, kind)` 마다 최신 값 하나를 남긴다. 키를 지우는 일은 없다
  (`lib/runtime/runtime_provider_usage_window.ml:812-833`).
- `/api/v1/runtime/resolved` 는 runtime 을 scope 별로 묶고 `account:N` 이라는 응답 안에서만 쓰는 이름을 붙인다
  (`lib/server/server_dashboard_runtime_resolved_json.ml:233-261`, `:295-296`).
  runtime 줄은 scope 하나의 `quota_exhausted`·`quota_resets_at`·`quota_scope` 를 싣는다 (`:39-43`, `:74-76`).
- TUI Overview 는 묶음 하나를 한 줄로 그리고 (`bin/masc_tui_overview_providers.ml:174`, `:246`),
  그 줄의 소진 여부는 runtime 줄의 `quota_scope` 라벨이 같은지로 이어 붙인다 (`:200-215`).

## 무엇이 틀리나

### 한 계정, 여러 홈

2026-09-28 live `runtime.toml` 에는 Codex provider 가 셋 있다.

| provider | 홈 | 계정 |
|---|---|---|
| `codex_subscription` | 지정 없음. 서버(pid 1087)에 `CODEX_HOME` 이 없어 `~/.codex` | 계정 B |
| `codex_acct1` | `~/.codex-account1` | 계정 A |
| `codex_853c5995` | `<base-path>/.masc/official-clients/codex/9594…` (setup 로그인이 만든 홈, 아래 "setup 마법사·로그인 계층과 겹치는 곳") | 계정 A |

계정은 두 방법으로 비교했다. 원문 id 는 출력하지 않고 SHA-256 앞 8자리만 비교했다.

- 각 홈 `auth.json` 의 `tokens.account_id`.
- 각 홈으로 띄운 `codex app-server` 가 답한 `account/rateLimits/read.accountId`.

두 방법 모두 `codex_acct1` 과 `codex_853c5995` 가 같은 계정이고, `~/.codex` 는 다른 계정이라고 답했다.
세 계정 모두 `planType` 이 `pro` 인 개인 계정이다.

코드로 따라가면 이렇게 된다.

1. 서버 시작 때 scope 가 둘이므로 같은 계정을 두 번 읽고, 같은 숫자를 두 scope 에 적는다. Overview 에 두 줄이 나온다.
2. `codex_acct1` 후보가 `usageLimitExceeded` 로 거절되면 `~/.codex-account1` scope 만 소진으로 적힌다.
3. `codex_853c5995` 후보는 scope 가 달라서 뒤로 가지 않는다. 걷기가 그 후보에 닿으면 같은 계정이라 또 거절된다.
   그다음에야 그 scope 도 소진으로 적힌다.
4. 나중에 한 홈으로 호출이 통과해도 다른 홈의 기록은 남는다. 그 홈으로 통과할 때까지 뒤에 있다.

같은 경로가 exact lane 순서(`lib/runtime/runtime_exact_lane_backpressure.ml:24-31`),
one-shot 순서(`lib/keeper/keeper_lane_cli_oneshot.ml:216-221`),
Fusion 의 Codex 패널(`lib/fusion/fusion_official_client.ml:332`, `:357-360`)에도 있다.

비용은 소진 한 번마다 같은 계정의 다른 홈 하나당 거절 한 번이다. 끝없이 반복되지는 않는다.
2026-09-25 에 기록 자체가 없어서 3,135번 거절된 사례(`lib/fusion/fusion_official_client.ml:349-356` 주석)와는 규모가 다르다.

**확신: 높음** (코드 경로를 끝까지 읽음, 계정 일치는 live 로 확인).
**재현하지 않음**: 실제로 소진된 계정으로 두 홈의 걷기 순서를 관찰하지는 않았다.

### 한 홈, 여러 계정

운영자는 같은 홈에 `codex login` 을 다시 해서 계정을 바꾼다.
2026-09-27 밤에 `~/.codex` 를 계정 넷이 거쳐 갔다 (팀 리드 관찰, 이 RFC 에서 다시 세지 않음).

1. 계정 X 가 소진되면 `~/.codex` scope 에 끝없는 소진 기록이 붙는다.
2. 계정 Y 로 다시 로그인해도 scope 는 같다. `~/.codex` 후보는 계속 뒤에 있다.
   같은 lane 의 앞 후보가 계속 답하면 그 홈으로는 아무것도 보내지 않으므로 기록이 지워질 기회도 없다.
   Codex turn 거절에는 리셋 시각이 없어서 이 기록은 언제나 끝 없는 `Observed` 다.
3. 사용량 표는 새 보고가 온 키만 바꾼다. 계정 X 에만 있던 버킷은 계정 Y 의 것처럼 계속 보인다.
   실제로 두 계정의 버킷 구성은 다르다. `~/.codex` 의 계정은 `base_model_inference`, `codex` 둘을, `~/.codex-account1` 의 계정은 `codex` 하나를 보고했다.

**확신: 높음** (코드). **재현하지 않음**: 재로그인 뒤의 Overview 를 실제로 찍지는 않았다.

### 따로 찾은 것: `sessionBudgetExceeded` 는 계정 한도가 아니다

upstream 은 이 오류를 "shared rollout token budget exhausted" 로 정의한다
(`codex-rs/protocol/src/error.rs` 87-88행, `rust-v0.157.1`).
Codex 클라이언트 안의 rollout 토큰 예산이 넘쳤다는 뜻이다 (`codex-rs/core/src/agent/control/budget.rs`).
MASC 는 지금 이것을 `usageLimitExceeded` 와 같은 계정 소진으로 읽어 홈 scope 를 뒤로 보낸다.
이 RFC 는 이것을 계정 scope 로 넓히지 않는다. 지금의 처리가 맞는지는 이 RFC 밖에서 따로 다룬다 (결정 7).

## 계정은 어디서 알 수 있나

### 확인한 버전

- repo 는 codex-cli 버전을 잠그지 않는다. provider 는 `command = "codex"` 로 PATH 에서 찾는다.
  주석이 근거로 드는 스키마는 0.156.0 이다 (`lib/runtime/runtime_codex_app_server.ml:278`).
- 이 PC 의 PATH 는 0.157.1 이고, 오늘 만들어진 rollout 의 `cli_version` 은 0.158.0 이다.
- 그래서 upstream tag `rust-v0.156.0`, `rust-v0.157.1`, `rust-v0.158.0` 의 생성 스키마와
  `codex app-server generate-json-schema`(0.157.1, `--experimental` 유무 둘 다)를 비교했다. 세 버전 모두 아래 표와 같다.

### 후보

| 출처 | 계정 id | 계약 | 판단 |
|---|---|---|---|
| `account/rateLimits/read` 응답 `accountId` | 있음. nullable, "when supplied by the backend" | 안정 | **채택** |
| `account/read` 응답 `account` | 없음. `type`, `planType`, `email` 만 | 안정 | `email` 만 결정 1 의 짝으로 후보 |
| `account/read` 응답 `workspaceRouting.chatgptAccountId` | 있음 | `#[experimental("account/read.workspaceRouting")]` | 쓰지 않음 |
| `account/updated` 알림 | 없음. `authMode`, `planType` 만 | 안정 | 계정 id 로 못 씀 |
| `account/rateLimits/updated` 알림 | 없음. `rateLimits` 만 | 안정 | 계정 id 로 못 씀 |
| `<CODEX_HOME>/auth.json` `tokens.account_id` | 있음 | Codex 내부 파일 | 거절 |
| rollout 첫 줄 `session_meta.payload.creator_account_id` | 있음 | Codex 내부 파일 | 거절 |

채택 근거는 이렇다.

- `accountId` 는 backend 가 사용량 응답과 함께 준 값이다.
  app-server 는 이 값을 로그인된 자격 증명의 `auth.get_account_id()` 와 비교해서, 계정에 묶인 내용을 보여 줄지 정한다
  (upstream `codex-rs/app-server/src/request_processors/account_processor.rs`, `rust-v0.157.1` 1196-1202행).
  즉 auth.json 의 `tokens.account_id` 와 같은 개념이다.
- live 로 두 홈에 읽기를 보냈고, 두 번 모두 `accountId` 가 그 홈 auth.json 의 값과 같았다 (해시 비교).
- 이미 MASC 가 서버 시작 때와 한도 거절 뒤에 보내는 요청이다 (#38671). 새 요청 종류가 아니다.

거절 근거는 이렇다.

- **auth.json**: Codex 는 자격 증명을 OS keyring 에 둘 수 있다 (`cli_auth_credentials_store_mode`, upstream `codex-rs/core/src/config/auth_keyring.rs`).
  그 모드에서는 파일이 없다. MASC 도 이 설정을 이미 따로 다룬다 (`lib/runtime/runtime_verification_codex_home.mli`).
  파일 형식은 vendor 가 약속한 적이 없다.
  #39612 가 로그인 직후 이 파일의 `id_token` email 을 읽기 시작했지만, 그 모듈은 "표시용이고 계정 식별·라우팅에 쓰지 않는다" 고 못 박았다 (`lib/runtime/runtime_account_email.mli:1-5`).
  표시가 틀리면 글자가 틀리고 끝나지만, 한도 주인이 틀리면 후보 순서가 틀린다. 같은 파일이라도 쓰임이 다르다.
- **rollout**: 역시 내부 파일이고, thread 가 시작된 뒤에야 생긴다. 후보 순서를 정하는 시점에는 없다.
- **workspaceRouting**: 실험 필드라 예고 없이 바뀔 수 있다. MASC 는 `experimentalApi: true` 로 초기화하므로
  (`lib/runtime/runtime_codex_app_server.ml:1715`) 지금도 받고 있지만, 안정 필드가 있는데 실험 필드에 기대지 않는다.
- **email 단독**: 같은 사람이 개인·팀 workspace 를 따로 가지면 email 은 같고 한도는 다르다. 두 계정을 하나로 합치게 된다.

### 프로세스가 같아도 계정 키가 고정되지는 않는다

upstream `rust-v0.157.1` (`36650394c5b38c2990ccf2a3457165ca3e9d9726`) 의
[`reload_if_account_id_matches`](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/login/src/auth/manager.rs#L2487-L2520)는
새 `account_id` 가 다르면 다시 읽기를 거절한다. 같으면 **자격 증명 전체**를 교체하며 email·user id 는 비교하지 않는다.
따라서 이 guard 는 같은 workspace 안의 사용자 변경을 막지 않고, `(accountId, email)` 키의 불변성을 증명하지 않는다.

이는 인증 실패 때만의 경로가 아니다. [`auth()`](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/login/src/auth/manager.rs#L2389-L2414)가
선제 갱신을 할 수 있고, [`refresh_token()`](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/login/src/auth/manager.rs#L2855-L2879)은 이 guard 를 거친다.
사용량 처리기도 `auth_with_http_client_factory()` 로 이 경로에 들어간다
([account_processor.rs:1119-1137](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/app-server/src/request_processors/account_processor.rs#L1119-L1137)).
앞선 `account/read` 의 email 과 뒤의 사용량 응답이 다른 사용자에게 속할 수 있다.

사용량 처리기의 `account_id`·`user_id` 비교는 CTA 관련 값을 거르는 데 쓰인다.
일반 사용량과 `account_id` 는 그 비교가 실패해도 응답하며, `user_id` 는 응답하지 않는다
([account_processor.rs:1192-1221](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/app-server/src/request_processors/account_processor.rs#L1192-L1221)).
이는 소스에서 확인한 한계다. 실제 multi-seat 재로그인 재현이나 모든 `reload()` 호출 경로의 검증을 뜻하지 않는다.

### 한계

- `accountId` 는 nullable 이다. backend 가 비우면 계정을 모른다. 설계는 이 경우를 따로 다룬다.
- `accountId` 는 ChatGPT **workspace 계정** id 다. Team·Business 처럼 한 workspace 에 seat 가 여럿이면 seat 들이 같은 값을 가질 수 있다.
  app-server 도 계정을 확인할 때 `account_id` 와 `user_id` 를 **둘 다** 비교한다 (위 1196-1202행).
  Codex 한도를 workspace 단위로 세는지 seat 단위로 세는지는 확인하지 못했다. **미검증**.
  seat 단위라면 `accountId` 만으로 묶을 때 멀쩡한 seat 가 다른 seat 의 소진 때문에 뒤로 밀린다. 그래서 키에 email 을 짝지운다 (결정 1).
  live 계정 셋은 모두 개인 `pro` 라서 이 PC 에서는 차이가 없다.
- 읽기 시간은 이 PC 에서 `account/read` 0.4–5.4초, `account/rateLimits/read` 0.5–0.7초였다 (세 번).
  첫 시도 한 번은 두 요청이 30초 안에 끝나지 않았다. 원인은 확인하지 않았다. 그래서 설계는 이 읽기를 기다리지 않는다.

## 설계

### 원칙

- 한도의 주인은 vendor 계정이다. 홈은 runtime 이 계정에 닿는 길이다. 둘을 다른 타입으로 둔다.
- 계정은 vendor 가 답한 값으로만 안다. 파일을 읽거나 짐작하지 않는다.
- 관측은 기록이고 게이트가 아니다. 계정 읽기가 늦거나 실패해도 turn 은 기다리지 않는다.
- 현재 자격 증명 세대의 가장 새 관측이 계정을 모르면 모른다고 둔다. 옛 계정으로 채우지 않는다.
- 요청 순서와 자격 증명을 포착한 순서는 다르다. 옛 프로세스의 새 요청에 홈 갱신 권한을 다시 주지 않는다.
- 시간이 지났다고 관측을 지우지 않는다.

### 관측 귀속의 구현 선행 조건

1. **홈 갱신 권한은 관측이 포착한 자격 증명 세대에 묶는다.** 읽기 요청에 새 순번을 주는 것으로 대신하지 않는다.
   X 를 쓰던 프로세스 P 가 멈춘 사이 로그인 완료 읽기가 Y 를 확인했다면, P 가 나중에 새 요청을 보내도 홈은 Y 를 유지해야 한다.
   P 의 증거가 X 에 속한다고 별도로 확인됐다면 X 에 기록한다. Y 로 옮기지 않는다.
   이전 세대의 실패 응답도 Y 를 `Unconfirmed` 로 바꾸지 못한다.
2. **계정 키와 기록할 사건이 같은 인증 주인에 속함을 확인한다.** email 과 quota 응답을 같은 인증 스냅숏에 묶는 증거가 필요하고,
   turn 소진·성공·알림에는 해당 사건까지 그 귀속을 연결해야 한다. 같은 PID, process 시작 순번, RPC 발송 순번은 이 증거가 아니다.
   앞뒤 email 이 같다는 검사만으로도 중간의 X→Y→X 변경을 배제할 수 없다.
   증거가 없거나 변경이 감지되면 `Identity_unconfirmed` 로 두고 홈 미확인 scope 에 기록한다.
   이전 email 로 새 사용량을 적거나, 이전 계정의 소진 기록을 성공으로 지우지 않는다.

**미해결:** 지원하는 Codex 계약으로 자격 증명 포착 시점·세대 순서와 사건별 귀속을 얻는 경로를 아직 정하지 못했다.
MASC 의 로그인 세션 잠금은 외부 `codex login` 과 app-server 내부 갱신을 직렬화하지 않는다.
세대 번호를 MASC 에서 발급했다는 사실만으로 credential capture 를 증명했다고 하지 않는다.
아래 타입과 PR 분할은 이 증거를 공급할 수 있을 때의 계약 초안이다. 공급 경로를 정하고 아래 반례 시험을 통과하기 전에는
`Stated` 를 생성해 계정 scope 에 기록하거나 그 관측으로 홈의 계정을 바꾸는 구현으로 진행하지 않는다.
읽기와 turn 은 계속 진행하며, 증거는 결정 4 의 홈 미확인 scope 에 남긴다.

### 타입

```ocaml
(* lib/runtime/runtime_codex_account.mli (새 모듈) *)
type key
(** 한도 주인으로 쓰는 계정 키. 같은 인증 주인으로 확인한 [accountId] 와
    [account/read] email 의 짝이다 (결정 1).
    표현은 문자열만 담는 불변 값이라 구조적 비교가 [equal] 과 같다.
    원문은 메모리 안에만 둔다. 밖으로 내보내는 함수는 [log_label] 하나다. *)

val equal : key -> key -> bool
val log_label : key -> string   (* SHA-256 앞 8자리 *)

type read =
  | Stated of key               (* 이 읽기/사건에 대한 인증 주인 귀속이 확인됨 *)
  | Identity_unconfirmed        (* 값은 있어도 같은 인증 주인이라는 증거가 없음 *)
  | Not_stated                  (* 응답은 왔고 accountId 나 email 이 없거나 null 이다 *)
  | Not_applicable              (* ChatGPT 로그인이 아니다: apiKey, amazonBedrock, provider 관리 *)
  | Read_failed of read_failure

and read_failure =
  | Rpc_error                   (* app-server 가 오류로 답했다 *)
  | Undecodable                 (* accountId 가 문자열이 아니거나 빈 문자열이다 *)
  | No_answer_before_turn_end   (* turn 이 끝날 때까지 답이 없었다 *)
```

빈 문자열을 `Not_stated` 로 눌러 담지 않는다. 계약이 말하지 않은 값이므로 `Undecodable` 이다.
읽기는 `account/read` 가 `Chatgpt _` 를 답했을 때만 보낸다 (`lib/runtime/runtime_codex_app_server.ml:789-808`).
다른 로그인은 `account/rateLimits/read` 가 "chatgpt authentication required" 로 거절하는 요청이라 보내지 않고 `Not_applicable` 로 둔다.

```ocaml
(* lib/runtime/runtime_codex_home_account.mli (새 모듈, 프로세스 안) *)
type serving =
  | Not_read_since_start
  | Serves of Runtime_codex_account.key
  | Unconfirmed                 (* 현재 세대의 가장 새 읽기가 계정을 확인하지 못했다 *)

type source
(** 홈과 실제로 포착한 자격 증명 세대에 묶인 관측 출처.
    발급에 필요한 증거 공급 경로는 위 구현 선행 조건의 미해결 항목이다. *)

type ticket
val begin_read : source -> ticket
(** 같은 출처 안의 요청 순서만 정한다. 새 요청은 출처의 세대를 올리지 않는다. *)

val observe : ticket -> Runtime_codex_account.read -> unit
(** 현재 홈 세대에 속하는 출처의, 이미 반영한 것보다 새 요청만 홈을 갱신한다.
    옛 세대이거나 세대 순서를 증명하지 못한 결과는 홈을 갱신하지 않는다.
    갱신 권한이 있을 때 [Stated k] 는 [Serves k], 나머지는 [Unconfirmed] 가 된다.
    홈 갱신의 채택/거절은 그 요청의 quota 증거 귀속을 바꾸지 않는다. *)

type snapshot
val snapshot : unit -> snapshot
val serving : snapshot -> home:string -> serving
```

표의 키는 runtime 이 쓰는 홈 **문자열 그대로**다. `Runtime_account_home` 은 홈 표기를 바꾸지 않고
(`lib/runtime/runtime_account_home.mli:1-4`), #38764 도 경로 별칭을 따로 선택된 홈으로 둔다.
심볼릭 링크로 같은 디렉터리를 두 표기로 선언하면 표에는 두 키가 생긴다.
각 키의 현재 세대와 인증 주인 귀속이 확인되면 같은 계정을 가리키므로, 소진 기록은 계정 단위에서 합쳐진다.

```ocaml
(* lib/runtime/runtime_quota_window.mli *)
type load_time_scope =          (* 설정을 읽을 때 정해지는 주인. Codex 생성자는 없다 *)
  | Provider_row of string
  | Credential_env of string
  | Credential_file of string
  | Official_client_home of string * string   (* Claude Code, Muse. 홈이 곧 주인이다 *)

type scope =
  | Load_time of load_time_scope
  | Codex_account of Runtime_codex_account.key
  | Codex_home_account_not_stated of string    (* 계정을 확인하지 못한 채 남긴 Codex 증거 *)
```

- `scope_of_codex_home` 은 없어진다. Codex 는 `Official_client_home` 을 더 만들지 않는다.
- `scope_to_string` 은 `Codex_account k` 를 `codex-account:` 와 `log_label k` 로만 쓴다. 로그에 원문 id 가 나가지 않는다
  (지금 이 함수는 `lib/runtime/runtime_provider_usage_read.ml:94`, `:376`, `:382` 등에서 로그로 찍힌다).
- 소진 표(`lib/runtime/runtime_quota_window.ml:25`)와 사용량 표는 지금 기본 `Hashtbl` 의 구조적 비교를 쓴다.
  `Hashtbl.Make` 로 바꿔 `scope_equal` 과 같은 비교를 쓰게 한다. `key` 의 표현이 바뀌어도 표가 어긋나지 않는다.

```ocaml
(* lib/runtime/runtime.mli *)
type quota_owner =
  | Load_time of Runtime_quota_window.load_time_scope
  | Codex_home of string        (* materialize 때 고른 홈. 계정은 관측한다 *)

val quota_scopes_of_runtime :
  Runtime_codex_home_account.snapshot -> t ->
  Runtime_quota_window.scope * Runtime_quota_window.scope list
(** 후보 순서가 읽는 scope 들. 비어 있지 않다.
    [Load_time s] -> [(Load_time s, [])]
    [Codex_home h] -> [(Codex_home_account_not_stated h, [Codex_account k])] ([Serves k] 일 때)
                      [(Codex_home_account_not_stated h, [])]            (그 밖) *)
```

- `quota_owner` 는 `of_binding` 안에서 `Runtime_execution.t` 로만 정한다 (`lib/runtime/runtime.ml:367-402`).
  `Codex_app_server` 갈래만 `Codex_home` 이 되고, 홈은 그때 `effective_account_home` 으로 한 번 고른 값이다.
  다른 갈래는 지금처럼 `Load_time` 이다. 밖에서 짝이 어긋난 값을 만들지 못하도록 이 필드를 만드는 곳은 `of_binding` 하나로 둔다.
- 한 scope 만 쓰는 writer(HTTP 403 뒤 읽기, vision 402, Muse 검증·probe)는 자기가 이미 가진 execution 갈래에서 `load_time_scope` 를 받는다.
  `Runtime.t` 에서 다시 꺼내지 않으므로 Codex 갈래에 닿는 분기가 생기지 않는다.
- 후보 하나를 해석하지 못한 경우(runtime id 가 없음)는 지금처럼 `None` 이다. "모르는 것은 소진 증거가 아니다" 라는 `demote_order` 계약은 그대로다.

홈을 얼리는 규칙(PR #28219)은 그대로다. 달라지는 것은 계정을 얼리지 않는다는 점이다.

### 언제 계정을 읽나

| 시점 | 지금 | 바뀌는 것 |
|---|---|---|
| 서버 시작 | 홈마다 `account/rateLimits/read` 한 번 | 응답의 계정으로 `observe`. 창은 그 계정 scope 에 기록. 중복 제거는 홈 기준이다 (읽기 전에는 같은 계정인지 모른다) |
| Codex turn 마다 (Keeper turn, Fusion 패널, one-shot) | `initialize` → `account/read` → `thread/start` (`lib/runtime/runtime_codex_app_server.ml:1703-1723`) | `account/read` 가 `Chatgpt _` 이면 `account/rateLimits/read` 를 보내고 **기다리지 않고** `thread/start` 로 간다 |
| Codex 검증 | 설정에 없는 임시 홈 (`lib/runtime/runtime_verification.ml:787-800`) | 읽기는 같이 가지만 `observe` 하지 않는다 |
| 한도 거절 뒤 백그라운드 읽기 | 창만 기록 | `observe` 도 한다 |
| MASC 로그인 세션이 그 홈에서 끝났을 때 (#39533) | 인증만 확인하고 email 을 기록한다 (`lib/server/server_setup_account_login.ml:104-109`, `:146-150`) | 그 홈을 한 번 읽는다 (결정 3) |
| 운영자가 다시 읽기를 요청할 때 | 없음 | 그 홈을 한 번 읽는다 (결정 3) |

### turn 안의 읽기

- 핸드셰이크는 admission 제한 시간 안에서 돈다 (`lib/runtime/runtime_codex_app_server.ml:76-80`, `:2099-2102`, Keeper turn 은 `lib/keeper/keeper_codex_runtime.ml:1072`).
  이 안에서 읽기를 기다리면 멈춘 읽기 하나가 turn 을 Timeout 으로 실패시킨다. 그래서 기다리지 않는다.
- 지금 `await_response` 는 기다리지 않은 id 의 응답을 protocol 오류로 처리한다 (`lib/runtime/runtime_codex_app_server.ml:765-776`).
  turn 마다 "답을 기다리는 곁 요청" 자리 하나를 두고, 그 id 의 응답이나 오류만 그 자리로 넘긴다. 다른 id 는 지금처럼 오류다.
  turn 이벤트 루프도 같은 자리를 본다.
- turn 이 끝날 때까지 답이 없으면 `Read_failed No_answer_before_turn_end` 다. 답을 기다리려고 프로세스를 붙잡지 않는다.
- app-server 가 `thread/start` 와 이 읽기를 동시에 처리하는지, 순서대로 처리해서 `thread/start` 가 늦어지는지는 확인하지 않았다. **미검증**.
  PR1 의 가짜 app-server 시험은 답이 순서를 바꿔 오는 경우와 끝내 안 오는 경우를 다룬다.
- quota 응답의 귀속과 turn 사건의 귀속은 각각 확인해야 한다. 프로세스가 같다는 이유로 turn 전체를 한 계정에 묶지 않는다.
  위 구현 선행 조건을 충족하지 못한 사건은 `Identity_unconfirmed` 다.

### 기록의 주인

아래 `Codex_run.read` 는 quota RPC 의 파싱 결과를 그대로 재사용한 값이 아니다.
이 시도가 남길 소진·성공·사용량 사건까지 같은 인증 주인으로 확인한 결과다.
quota 응답만 확인됐거나 시도 중 인증 주인이 바뀔 수 있어 이 연결을 증명하지 못하면 `Identity_unconfirmed` 다.

순서를 정하는 함수와 기록할 주인을 정하는 함수를 가른다.
지금은 `?quota_scope_of` 하나가 둘 다 한다 (`lib/keeper/keeper_turn_driver.ml:594`, `:617-623`, `:715`, `:791`).

```ocaml
(* 시도 하나가 끝나면 run_attempt 가 Ok 든 Error 든 함께 돌려준다 *)
type quota_write_owner =
  | Captured of Runtime_quota_window.load_time_scope
      (* Codex 가 아닌 후보: dispatch 전에 잡은 scope. 지금과 같다 *)
  | Codex_run of { home : string; read : Runtime_codex_account.read }

let scopes_to_write = function
  | Captured s -> Load_time s, []
  | Codex_run { home; read = Stated k } -> Codex_account k, [ Codex_home_account_not_stated home ]
  | Codex_run { home; read = Identity_unconfirmed | Not_stated | Not_applicable | Read_failed _ } ->
    Codex_home_account_not_stated home, []
```

- 사용량 소진(`usageLimitExceeded`)은 `scopes_to_write` 의 첫 scope 에 `note_observed_exhausted` 로 적는다.
- `sessionBudgetExceeded` 는 계정 증거가 아니다. 읽기와 관계없이 `Codex_home_account_not_stated home` 에 적는다.
  지금 이것을 홈 scope 에 적는 동작과 같은 결과다. 넓히지도 좁히지도 않는다 (결정 7).
- 성공(`note_succeeded`)은 `scopes_to_write` 의 scope 를 모두 지운다.
  계정을 확인한 turn 은 계정 기록과 그 홈의 미확인 기록을 함께 지운다. 그 홈으로 통과했으니 그 홈의 "알 수 없는 계정이 소진" 증거도 틀렸다.
  계정을 확인하지 못한 turn 은 그 홈의 미확인 기록만 지운다. 어느 계정이 답했는지 모르므로 계정 기록은 건드리지 않는다.
- 사용량 창(`account/rateLimits/updated` 알림과 turn 안 읽기의 창)은 첫 scope 에 적는다.
  알림이 읽기의 답보다 먼저 오면 turn 이 끝날 때 한꺼번에 적는다. 알림 창을 먼저 홈에 적고 나중에 옮기지 않는다.
- turn 안 읽기의 결과는 출처가 확인됐을 때 그 출처의 ticket 으로 `observe` 에도 넘긴다.
  요청 시점에 옛 프로세스를 현재 자격 증명 세대로 다시 표시하지 않는다.

계정을 확인하지 못한 증거를 계정 scope 로 옮기거나, 홈이 마지막으로 가리킨 계정에 붙이지 않는다.
그렇게 하면 "이 홈의 알 수 없는 계정" 과 "계정 A" 를 조용히 같은 것으로 만든다.

### 후보 순서와 쉬는 시각

- 후보는 `quota_scopes_of_runtime` 의 scope 가운데 하나라도 소진이면 뒤로 간다. 스냅숏은 순서를 한 번 정할 때 한 번 뜬다.
- path rest(`lib/keeper/keeper_turn_driver.ml:330-337`)는 scope 마다 쉬는 시각을 구해 합친다.
  `Until r` 는 `(r, 앞당길 수 있음)`, `Observed` 는 `(now + Hard_quota 기본 휴식, 앞당길 수 없음)` 이다.
  합치는 규칙은 지금 rate limit 과 quota 를 합치는 규칙과 같다. 가장 늦은 시각, 그리고 모두 앞당길 수 있을 때만 앞당긴다 (`:338-344`).

### 재로그인

- 재로그인은 그 홈의 현재 자격 증명 세대를 읽고 귀속을 확인했을 때 안다. 계정을 확인하면 `Serves` 가 새 계정으로 바뀐다.
  답하지 못하면 `Unconfirmed` 가 되어 옛 계정의 소진 기록으로 그 홈이 밀리지 않는다. 그 홈에는 미확인 기록만 걸린다.
- Codex 가 다른 프로세스에서 한 로그인은 MASC 의 app-server 프로세스에 알림으로 오지 않는다.
  `account/updated` 는 로그인을 처리한 프로세스 안의 알림이고, 계정 id 도 없다.
- 같은 출처에서 늦게 끝난 옛 요청은 ticket 순서로 막고, 다른 출처는 포착한 자격 증명 세대의 갱신 권한으로 가른다.
  "P 가 X 로 시작 → Y 로그인 완료 읽기 반영 → P 가 새 quota 요청" 에서 홈을 X 로 되돌리지 않아야 한다.
- 남는 틈은 "그 홈 후보가 뒤에 있고 앞 후보가 계속 답해서 그 홈으로 turn 이 가지 않는 경우" 다. 이 틈은 결정 3 이 메운다.

### 홈의 계정이 바뀌었을 때 기존 기록

아무것도 옮기지 않는다.

- 계정 X 의 소진 기록은 계정 X 에 남는다. 다른 홈이 아직 X 를 쓰면 그 홈 후보는 계속 뒤에 있다. 맞는 동작이다.
- 홈은 이제 Y 를 가리키거나 `Unconfirmed` 다. 그 홈 후보의 순서는 Y 의 기록과 그 홈의 미확인 기록으로 정한다.
- 계정 X 의 사용량 창도 X 에 남는다. 어느 provider 도 X 를 쓰지 않으면 Overview 는 provider 없이 보고만 남은 줄로 보여 준다.
  이것은 지금도 있는 동작이다 (`lib/server/server_dashboard_runtime_resolved_json.ml:253-261`).
  계정 Y 의 줄에는 Y 가 보고한 버킷만 나온다.

끝 없는 기록을 시간으로 지우지 않는다. 계정 X 의 기록은 X 로 호출이 통과할 때 지워진다.

### 표면

- `/api/v1/runtime/resolved` 는 응답 하나를 만들 때 `Runtime_codex_home_account.snapshot` 을 **한 번** 뜨고, 묶음과 runtime 줄이 모두 그 스냅숏을 쓴다.
  지금은 묶음을 한 번 만들고 runtime 줄마다 scope 를 다시 구한다 (`:39`, `:295-305`). 가변 표를 읽으면서 이렇게 하면 사이에 `observe` 가 끼어 라벨을 못 찾고 `failwith` 로 500 이 난다.
- 사용량 묶음의 키는 Codex runtime 이면 `Serves k` 일 때 `Codex_account k`, 아니면 `Codex_home_account_not_stated h` 다.
  `codex_acct1` 과 `codex_853c5995` 는 한 줄이 된다.
  계정을 확인한 홈이라도 미확인 scope 에 창이나 소진 기록이 있으면 그 scope 는 따로 한 줄을 갖는다. 계정 줄과 합치지 않는다.
- 묶음마다 자기 scope 의 `exhausted`·`resets_at` 과 주인의 종류를 싣는다.
  주인의 종류는 닫힌 값이다. `vendor_account`, `account_home`(Claude Code·Muse), `codex_home_account_not_stated`, `credential`, `provider_row`.
  Overview 는 줄의 소진 여부를 이 묶음 값에서 읽는다. runtime 줄의 `quota_scope` 라벨로 이어 붙이지 않는다 (지금 `bin/masc_tui_overview_providers.ml:200-215`).
- runtime 줄은 `quota_exhausted`(scope 중 하나라도), `quota_resets_at`(위 합치는 규칙), 그리고 사용량 묶음 라벨 `usage_scope` 를 싣는다. 단일 `quota_scope` 는 없앤다.
- dashboard Overview 의 "같은 home 을 쓰는 provider" 줄(#39604, #39617)은 같은 계정을 쓰는 provider 줄이 된다. provider 는 지금처럼 `{id, display_name}` 으로 싣는다.
- 공개 이름은 지금처럼 `account:N` 이다. 계정 id·email·홈 경로는 싣지 않는다.
- wire 가 바뀌므로 서버, TUI decoder, dashboard schema 를 한 PR 에서 함께 바꾼다. 옛 모양을 읽는 코드는 남기지 않는다.

### 새로 생기는 것과 없어지는 것

MASC 규칙은 "새 상태·필드·Gate 는 없을 때 durable truth 가 손상되는 경우에만 더한다" 이다.

| 새로 | 없으면 무엇이 틀리나 |
|---|---|
| `Runtime_codex_account` | 계정을 나타낼 타입이 없어 홈 문자열로 대신한다. 이것이 지금의 결함이다 |
| `Runtime_codex_home_account` (홈 → 확인한 계정) | 후보 순서를 정하는 시점에 그 홈이 어느 계정에 닿는지 알 곳이 없다 |
| `Codex_home_account_not_stated` | 계정을 모르는 증거를 버리거나 계정으로 꾸며야 한다 |
| `quota_write_owner` | 순서와 기록이 같은 함수를 써서, turn 이 알아낸 계정이 기록에 닿지 못한다 |
| turn 마다 보내는 `account/rateLimits/read` | turn 의 기록을 그 turn 이 쓴 계정에 붙일 수 없다 |

| 없어지는 것 |
|---|
| Codex 의 `Official_client_home` scope 와 `scope_of_codex_home` |
| Codex turn 의 scope 재계산 (`lib/keeper/keeper_codex_runtime.ml:1672-1675`) |
| `Runtime.t.quota_scope` 필드 (→ `quota_owner`), resolved JSON runtime 줄의 단일 `quota_scope` |

게이트는 없다. 후보를 뒤로 보내는 것은 지금도 있는 순서 선호이고, 뒤에 있는 후보도 lane 에 남은 것이 그것뿐이면 시도한다.
두 표는 프로세스 안에만 있다. 서버를 다시 켜면 시작 때 읽기로 다시 채운다. 옮길 데이터가 없으니 이관 코드도 없다.

## 소비처별 변경

| 소비처 | 지금 읽는 것 | 바뀌는 것 |
|---|---|---|
| walk 매개변수 `?quota_scope_of` (`lib/keeper/keeper_turn_driver.ml:594`, 기본값 `:617-623`) | 순서와 기록에 같은 함수 | 순서용 `?quota_scopes_of` 와 `run_attempt` 가 돌려주는 `quota_write_owner` 로 가른다 |
| `demote_unavailable_candidates` (`:202-245`) 와 부르는 곳 `:247-256`, `:715`, `:1243-1250`, `:2144-2146` | 후보 하나에 scope 하나 | `scope * scope list`. 하나라도 소진이면 뒤로 |
| path rest (`:330-337`) | scope 하나의 `active_until` | 위 "후보 순서와 쉬는 시각" 규칙 |
| 시도 뒤 기록 (`:791`, `:802-803`, `:845-853`, `:913-915`) | dispatch 전 scope | `quota_write_owner` |
| exact lane 순서 (`lib/runtime/runtime_exact_lane_backpressure.ml:24-31`) | scope 하나 | scope 들 |
| one-shot 순서 (`lib/keeper/keeper_lane_cli_oneshot.ml:216-221`) | `demote_order ~quota_scope_of` | `~quota_scopes_of`. 해석 못 한 후보는 지금처럼 뒤로 보내지 않는다 |
| Fusion Codex 패널 (`lib/fusion/fusion_official_client.ml:332-360`) | runtime scope 로 소진·성공 기록 | turn 이 돌려준 `quota_write_owner` 로 기록 |
| Vision (`lib/keeper/keeper_vision_tool.ml:84-89`, `:540-543`, `:721-722`) | runtime scope | 순서는 scope 들. 기록은 HTTP execution 의 `load_time_scope` |
| 사용량 읽기 시작·거절 뒤 (`lib/runtime/runtime_provider_usage_read.ml:58-80`, `:354-384`) | runtime scope 로 중복 제거, 그 scope 에 기록 | Codex 는 홈 단위로 읽고, 답한 계정으로 `observe` 하고 그 계정에 기록 |
| 403 뒤 HTTP 읽기 (`read_runtime_after_account_refusal`, `:496`) | runtime scope | HTTP execution 의 `load_time_scope`. 동작은 같다 |
| Codex turn 사용량 알림·거절 뒤 읽기 (`lib/keeper/keeper_codex_runtime.ml:285-304`, `:372-379`) | turn 시작 때 다시 계산한 홈 scope | `quota_write_owner` 의 첫 scope |
| `/api/v1/runtime/resolved` (`lib/server/server_dashboard_runtime_resolved_json.ml:39-76`, `:233-305`) | runtime scope 로 묶음, runtime 줄에 scope 하나 | 스냅숏 한 번, 묶음별 소진·주인 종류, runtime 줄의 `usage_scope` |
| TUI (`lib/tui_decode.mli:883-885`, `:2951-2960`, `bin/masc_tui_overview_providers.ml:200-215`, `bin/masc_tui_render_prim.ml:3011`, `bin/masc_tui_types.ml:10303`, `bin/masc_tui_render.ml:12354`) | runtime 줄의 `ro_quota_scope` 로 소진 조인 | 묶음의 소진 값을 읽는다. runtime 목록은 `quota_exhausted` 를 그대로 쓴다 |
| dashboard (`dashboard/src/api/schemas/runtime-resolved.ts`, `dashboard/src/components/overview/runtime-stats.ts`) | 같음 | 새 필드 schema |
| Muse 검증·probe (`lib/runtime/runtime_verification.ml:603`, `lib/keeper/keeper_capability_probe.ml:671`, `lib/keeper/keeper_muse_runtime.ml`) | Muse 홈 scope | Muse execution 의 `load_time_scope`. 동작은 같다 |

## setup 마법사·로그인 계층과 겹치는 곳

#39403(2026-09-28 07:45Z 병합)과 그 아래 #39533, #39588, #39612 가 계정 로그인 경로를 만들었다.
이 RFC 의 base(`c424573c76`)에 모두 들어 있다.

### 새 홈이 생기는 경로

1. 로그인 요청에 기존 계정 참조가 없으면 서버는 세션 잠금 키로 새 토큰을 만들고 (`lib/server/server_setup_account_login.ml:59`),
   `Client.prepare` 가 `new_home` 으로 `<base-path>/.masc/official-clients/codex/<로그인 세션 id>` 를 만든다
   (`lib/server/server_setup_account_login.ml:66`, `lib/runtime/runtime_setup_login_client.ml:27-36`, `:52-55`).
   참조가 있으면 그 참조가 가리키는 홈을 그대로 쓴다 (`lib/runtime/runtime_setup_login_client.ml:38-50`).
2. 로그인을 돌리기 전에 `publish` 가 그 홈을 `Runtime_setup_accounts.register_home` 으로 참조 등록한다 (`:143-146`).
3. 그 홈에서 `codex login --device-auth` 를 돌린다 (`:76-77`).
4. 로그인 뒤 확인(`Client.observe`, `:94-103`)은 `probe_subscription`, 즉 `initialize` 와 `account/read` 다.
   인증됐는지만 보고 어느 계정인지는 보지 않는다.
5. #39612 가 `auth.json` 의 email 을 표시용으로 기록한다 (`lib/server/server_setup_account_login.ml:146-150`, `Client.finish` 의 `~account`).
6. 로그인 세션의 잠금 키(`account_key`)는 기존 홈이면 그 경로를 `realpath` 로 정규화한 값이다 (`lib/server/server_setup_account_login.ml:38-40`, `:58-61`).
   이 RFC 의 표는 정규화하지 않은 표기를 키로 쓴다. 두 키는 쓰임이 다르다. 잠금 키는 같은 디렉터리에 로그인이 겹치지 않게 하고, 표의 키는 runtime 이 쓰는 표기를 따라간다.

그래서 `9594…` 는 MASC 가 만든 로그인 세션 id 이고 vendor 계정과 관계없다.
새 계정으로 로그인하기를 고른 뒤 브라우저에서 이미 `~/.codex-account1` 과 같은 ChatGPT 계정으로 device 인증을 하면 같은 계정의 홈이 둘 생긴다.
live 사례가 실제로 이 순서였는지, 그때 마법사가 `~/.codex-account1` 을 기존 계정으로 보여 줬는지는 확인하지 않았다.

마법사는 로그인이 끝나기 전에는 어느 계정이 들어올지 모른다. 그래서 로그인 전에 막을 수는 없다.
막는 것은 gates 정책과도 맞지 않는다 (결정 5).

### 이 RFC 가 쓰는 자리

- 로그인이 끝난 자리(`lib/server/server_setup_account_login.ml:146-150`, `Client.finish`)는 결정 3 의 첫 연결 지점이다.
  여기서 그 홈을 한 번 읽는다. 현재 자격 증명 세대와 인증 주인 귀속이 확인된 결과만 `observe` 로 계정에 연결한다.
  로그인이 쓴 홈 표기가 runtime.toml 의 표기와 다르면(별칭) 그 runtime 의 키는 자기 다음 읽기 때 확인된다.
- 같은 자리에서 읽은 계정을 이미 다른 홈이 쓰고 있으면 setup 화면에 "이 계정은 `codex_acct1` 도 쓰고 있어요" 를 보여 줄 수 있다.
  관측을 보여 주는 것이고 저장을 막지 않는다 (결정 5).
- #39612 의 email 기록과 섞지 않는다. 그 email 은 `auth.json` 에서 읽은 표시용 글자다.
  결정 1 에서 짝으로 쓰는 email 은 `account/read` 가 답한 값이다. 같은 인증 주인이라는 증거와 `accountId` 없이 쓰지 않는다.

### 겹치지 않는 것

- #39400 은 Muse 모델 발견과 MCP 준비 확인이다. Codex 쪽은 선택한 홈으로 `model/list` 를 읽을 뿐 quota scope 를 건드리지 않는다
  (`lib/runtime/runtime_codex_model_refresh.mli`).
- #39518, #39527 의 계정 추가 폼은 같은 홈을 거절한다. 같은 계정은 모른다. 이 RFC 뒤에도 폼은 바꾸지 않는다.

## 다른 공식 클라이언트

- **Claude Code**: scope 가 `CLAUDE_CONFIG_DIR` 홈이라 모양이 같다.
  `claude auth status --json`(2.1.283)이 `orgId`, `email`, `subscriptionType` 을 준다.
  `orgId` 가 한도를 매기는 키인지는 확인하지 않았다. 따로 다룬다.
- **Muse**: scope 가 관리 홈이다. 계정 식별 수단은 조사하지 않았다. 따로 다룬다.
- **Antigravity**: scope 가 OAuth 파일 경로(`Credential_file`)라 모양이 같다. 따로 다룬다.
- **Codex 세션 이어받기**: 공식 클라이언트 세션 식별도 홈을 포함한다 (#38764).
  재로그인한 홈에서 이전 계정의 thread 를 이어받는 문제는 이 RFC 범위 밖이다.

## 하지 않는 것

- `ordinaryUsageAllowed`(응답이 "현재 계정 기준으로 확인한 사용 허용" 이라고 설명하는 필드)로 turn 전에 소진을 판정하지 않는다.
  뜻을 검증하지 않았다. 필요하면 따로 제안한다.
- 사용량 퍼센트나 리셋 시각으로 가용성을 추론하지 않는다 (#38671 과 같은 이유).
- 같은 계정을 쓰는 홈을 둘 이상 선언하는 것을 막지 않는다. Overview 가 한 줄로 보여 준다.
- auth.json 이나 rollout 을 읽지 않는다.
- `sessionBudgetExceeded` 의 처리를 바꾸지 않는다 (결정 7).

## 테스트 계획

constitution 의 testing 절에 따라 기능 단위로 본다. 기존 가짜 app-server
(`test/test_runtime_codex_app_server.ml`) 와 walk 시험대(`test/test_keeper_turn_driver_failover.ml`) 를 쓴다.

| 시나리오 | 확인하는 것 |
|---|---|
| 홈 둘, 같은 계정 | 한 홈 후보가 `usageLimitExceeded` 로 거절된 뒤 다음 걷기에서 다른 홈 후보도 뒤에 있다. exact lane·one-shot 순서도 같다. resolved JSON 의 사용량 묶음이 하나이고 provider 둘을 싣는다 |
| 한 홈, 재로그인 | 가짜 app-server 가 계정 X 뒤에 Y 를 답한다. X 소진 뒤 Y 를 확인하면 그 홈 후보가 앞으로 온다. X 를 쓰는 다른 홈은 계속 뒤에 있다. X 에만 있던 버킷이 Y 줄에 나오지 않는다 |
| 재로그인 뒤 읽기 실패 | X 소진 뒤 그 홈의 현재 자격 증명 세대에서 시작한 읽기가 오류를 답하면 홈은 `Unconfirmed` 이고, X 기록으로 뒤로 가지 않는다 |
| 늦게 끝난 옛 읽기 | 같은 출처의 읽기 둘을 보내고 먼저 보낸 읽기가 늦게 답해도 새 결과가 남는다. 다른 출처는 요청 순번 대신 자격 증명 세대의 갱신 권한을 본다 |
| 옛 프로세스의 새 요청 | P 가 X 를 포착한 뒤 멈춤 → Y 로그인 완료 관측 반영 → P 가 더 큰 순번으로 quota 읽기. 홈은 Y 를 유지하고, X 로 귀속이 증명된 P 의 증거만 X 에 남는다. P 의 실패도 Y 를 미확인으로 바꾸지 않는다 |
| 같은 workspace 의 사용자 변경 | `account/read` 는 `(W, email X)`, 갱신 뒤 quota/turn 은 `(W, email Y)`. 앞선 email X 로 기록하거나 X 의 소진을 성공으로 지우지 않는다. RPC 에서 귀속을 확인하지 못하면 `Identity_unconfirmed` 와 홈 scope 를 쓴다 |
| 관측 사이의 X→Y→X | 앞뒤 email 은 같아도 중간 quota/turn 이 Y 를 쓴다. 앞뒤 일치만으로 `Stated X` 를 만들지 않는다. 인증 스냅숏 증거가 없으면 홈 scope 를 쓴다 |
| 계정 미확인 | `accountId: null` 이면 증거가 `Codex_home_account_not_stated` 에 남고 그 홈 후보만 뒤로 간다. 주인 종류가 `codex_home_account_not_stated` 로 나온다 |
| 읽기가 멈춤 | 가짜 app-server 가 읽기에 끝내 답하지 않아도 turn 은 admission 제한 시간에 걸리지 않고 끝난다. 기록은 `No_answer_before_turn_end` 로 홈 미확인 scope 에 간다 |
| 답이 순서를 바꿔 옴 | 읽기의 답이 `thread/start` 답보다 늦게, 또는 먼저 와도 protocol 오류가 나지 않는다. 다른 모르는 id 는 여전히 오류다 |
| ChatGPT 가 아닌 로그인 | `account/read` 가 `apiKey` 를 답하면 읽기를 보내지 않는다 |
| `sessionBudgetExceeded` | 계정을 확인한 turn 이라도 홈 미확인 scope 에만 적고 계정 scope 에는 적지 않는다 |
| 성공이 지우는 것 | 계정을 확인한 turn 의 성공은 계정 기록과 홈 미확인 기록을 지운다. 확인 못 한 turn 의 성공은 홈 미확인 기록만 지운다 |
| resolved JSON 과 observe 경합 | 응답을 만드는 도중 `observe` 가 끼어도 응답은 500 없이 한 스냅숏으로 일관된다 |
| 식별자 노출 | 가짜 계정 id·email 문자열이 resolved JSON, 로그 줄, TUI 캡처 어디에도 나오지 않는다 |

변이 확인:

- 계정 scope 대신 홈 scope 로 적게 되돌리면 "홈 둘, 같은 계정" 이 실패해야 한다.
- `observe` 가 계정을 바꾸지 않게 하면 "한 홈, 재로그인" 이 실패해야 한다.
- 실패한 읽기가 마지막 `Serves` 를 남기게 하면 "재로그인 뒤 읽기 실패" 가 실패해야 한다.
- 미확인 증거를 홈이 마지막으로 가리킨 계정에 붙이면 "계정 미확인" 이 실패해야 한다.
- turn 안 읽기를 기다리게 되돌리면 "읽기가 멈춤" 이 실패해야 한다.
- 세대 대신 요청 순번만으로 홈을 갱신하면 "옛 프로세스의 새 요청" 이 실패해야 한다.
- 같은 프로세스 또는 앞뒤 email 일치만으로 귀속을 확정하면 사용자 변경·X→Y→X 시험이 실패해야 한다.

추가한 세 시나리오는 구현의 수용 시험 계획이다. 실제 multi-seat 계정으로 재현했거나 구현 시험을 실행했다는 주장이 아니다.

배포 뒤 실측:

- live resolved JSON 에서 `codex_acct1` 과 `codex_853c5995` 가 한 묶음인지 본다.
- 로그에 홈마다 `codex-account:<8자리>` 확인 줄이 남는지 본다.
- turn 시작부터 `thread/start` 답까지의 시간이 배포 전후로 달라지지 않았는지 본다 (위 미검증 항목).
- TUI Overview 캡처와 dashboard 브라우저 캡처를 붙인다.

## PR 나누기

먼저 위 두 구현 선행 조건의 증거 공급 경로를 별도 설계 검토로 확정한다. 이 문서는 그 경로를 구현 완료로 세지 않는다.
뒤 PR 은 앞 PR 에 의존하므로 stack 으로 올린다. 각 단위는 출력 20k 토큰 안으로 잡는다.

1. **turn 안의 계정 읽기** — `Runtime_codex_account`(key, read). `account/rateLimits/read` 디코더가 `accountId` 를 typed 로 돌려준다.
   `await_response` 와 turn 루프에 "곁 요청" 자리를 둔다. `Chatgpt _` 일 때만 보내고 기다리지 않는다. 결과를 turn 결과에 싣는다.
   `read_rate_limits` 도 계정을 돌려준다. scope 는 아직 바꾸지 않는다.
   시험: Stated·Identity_unconfirmed·Not_stated·Undecodable·Rpc_error·No_answer_before_turn_end, 사용자 변경·X→Y→X, 순서 바뀐 답, 멈춘 읽기, apiKey.
2. **순서가 계정을 읽는다** (1 위) — `Runtime_codex_home_account`(source, ticket, snapshot), `load_time_scope`/`scope` 분리, `quota_owner`,
   `quota_scopes_of_runtime`, `Hashtbl.Make`, `scope_to_string` 의 `log_label`.
   시작 때 읽기·거절 뒤 읽기·turn 읽기가 `observe` 한다. 순서를 읽는 곳(turn driver, path rest, exact lane, one-shot, vision)이 scope 들을 읽는다.
   이 단계에서 기록은 아직 `Codex_home_account_not_stated home` 에 적는다. 계정 scope 에는 기록이 없으므로 동작은 지금과 같다.
3. **기록이 계정에 붙는다** (2 위) — `quota_write_owner` 를 `run_attempt` 가 돌려주고 turn driver·Fusion·Codex turn 이 그 값으로 적는다.
   사용량 창도 계정에 적는다. `sessionBudgetExceeded` 는 홈에 남긴다. Codex turn 의 scope 재계산을 지운다.
   시험: 홈 둘·재로그인·재로그인 뒤 읽기 실패·늦은 읽기·옛 프로세스의 새 요청·사용자 변경·미확인·성공·session budget, 위 변이 시험.
4. **표면** (3 위) — resolved JSON 스냅숏, 묶음별 소진·주인 종류, runtime 줄 `usage_scope`. TUI decode·Overview, dashboard schema 를 같은 PR 에서 바꾼다.
   glossary 의 "닫힌 quota 창"·"Provider Usage Window" 항목과 `docs/spec/14-configuration.md`. 시험: 식별자 노출, 경합, TUI 캡처.
5. **재로그인 알아채기** (2 위, 결정 3 에 따라) — 로그인 세션 완료 때 읽기, 운영자 다시 읽기 요청, setup 화면의 "같은 계정" 표시.

## 결정

2026-09-28 에 아래 일곱 가지를 정했다. 결정 1 의 귀속 증명과 결정 3 의 세대 연결 경로는 위 선행 조건으로 남아 있다.
근거는 `origin/main` `59c99562db` 과 upstream `rust-v0.157.1`, 로컬 `codex app-server generate-json-schema`(0.157.1)에서 다시 확인했다.

1. **계정 키는 `accountId` 와 email 의 짝이다.**
   - `accountId` 는 `account/rateLimits/read` 에서, email 은 `account/read` 에서 받는다. 같은 인증 주인과 사건에 묶였다는 증거가 있어야 짝을 만든다.
     같은 프로세스라는 전제는 충분하지 않다. 증거 공급 경로는 위 구현 선행 조건으로 남아 있다.
   - app-server 도 "지금 로그인한 계정" 인지 볼 때 `account_id` 와 `user_id` 를 둘 다 비교한다
     (upstream `codex-rs/app-server/src/request_processors/account_processor.rs` 1196-1201행).
     안정 응답에는 `user_id` 가 없다. 사람마다 다른 안정 필드는 `account/read` 의 `email` 하나다
     (0.157.1 스키마: `GetAccountResponse.account.email` 은 `string | null`, `GetAccountRateLimitsResponse` 에는 `userId` 가 없다).
   - 같은 인증 주인의 짝이라고 확인했을 때 서로 다른 email 의 seat 를 합치지 않는다. 서로 다른 시점의 값이면 잘못된 seat 에 기록할 수 있으므로 짝을 만들지 않는다.
   - `accountId` 나 email 이 null 이면 `Not_stated` 다. 값은 있지만 귀속을 증명하지 못하면 `Identity_unconfirmed` 다.
     MASC 는 이미 email 을 선택 값으로 읽는다 (`lib/runtime/runtime_codex_app_server.ml:805`).
   - `accountId` 하나만 쓰는 안은 버렸다. 한도가 seat 단위라면 멀쩡한 seat 가 다른 seat 의 소진 때문에 뒤로 밀린다.
2. **turn 안의 읽기는 기다리지 않는다.**
   - 핸드셰이크는 `Awaiting_admission` 단계에서 돌고, 이 단계의 쉬는 한도는 `admission_timeout_s` 다
     (`lib/runtime/runtime_codex_app_server.ml:76-80`, `:2099-2102`). 여기서 읽기를 기다리면 멈춘 읽기 하나가 turn 을 실패시킨다.
     이 PC 에서 첫 읽기 한 번이 30초 안에 끝나지 않은 적이 있다 (위 "한계").
   - `await_response` 는 기다리지 않은 id 의 응답을 protocol 오류로 처리한다 (`:765-776`). 그래서 PR1 이 "곁 요청" 자리를 만든다.
   - 답이 turn 끝까지 오지 않으면 그 turn 의 기록은 홈 미확인 scope 에 간다.
   - 시작 때와 거절 뒤에만 읽는 안은 버렸다. turn 의 기록을 그 turn 이 쓴 계정에 붙일 수 없다.
3. **재로그인은 MASC 로그인이 끝날 때와 운영자의 "다시 읽기" 로 안다. 타이머는 두지 않는다.**
   - MASC 로그인 세션이 끝나는 자리에서 그 홈을 한 번 읽는다 (`lib/server/server_setup_account_login.ml:146-150`, `Client.finish`).
     TUI Overview 와 admin API 에 "다시 읽기" 를 둔다.
   - 터미널에서 `codex login` 을 하면 MASC 는 알 수 없다. `account/updated` 는 로그인을 처리한 프로세스 안의 알림이다.
     이때는 그 홈으로 turn 이 가거나, 그 홈이 거절된 뒤 읽거나, 운영자가 다시 읽기를 누를 때 안다.
     그 전까지 그 홈 후보는 옛 계정 기록 때문에 뒤에 있을 수 있다. 이 틈은 받아들인다.
   - Codex `refresh-s` 는 버렸다. 운영자가 근거 없이 골라야 하는 숫자가 하나 늘어난다.
     지금 반복 읽기는 HTTP provider 만 한다 (`lib/runtime/runtime_provider_usage_read.ml:277-278`).
   - auth.json 변경 감시는 결정 1 에서 auth.json 을 거절한 것과 같은 이유로 버렸다. keyring 모드에서는 파일이 없고, 파일 위치와 형식은 vendor 가 약속하지 않았다.
4. **계정을 확인하지 못한 증거는 `Codex_home_account_not_stated` 에 남긴다.**
   - constitution 의 `failure_keeps_evidence` 는 "실패는 증거를 남긴다" 이다 (`docs/constitution.xml:239-242`). 그 홈에는 지금과 같은 동작이다.
   - 버리고 로그만 남기는 안은 이 불변식과 어긋나서 버렸다.
5. **같은 계정을 쓰는 홈이 둘 이상이면 Overview 가 한 줄로 합쳐 보여 주고, 막지 않는다.**
   - constitution `<gates>` 는 하드 게이트를 기본으로 두지 않는다 (`docs/constitution.xml:427-432`).
     로그인이 끝나기 전에는 어느 계정이 들어올지 모르므로 setup 이나 계정 추가 폼에서 미리 막을 수도 없다.
   - 로그인 직후 읽은 계정을 다른 홈이 이미 쓰고 있으면 setup 화면에 알려 준다. 저장은 막지 않는다.
6. **이 RFC 는 Codex 만 다룬다.**
   - Claude Code 의 `orgId` 가 한도 키인지, Muse·Antigravity 에 계정을 알아낼 안정 수단이 있는지는 확인하지 않았다 (위 "다른 공식 클라이언트").
     확인하지 않은 키로 scope 를 바꾸지 않는다. 각 클라이언트는 식별 수단을 확인한 뒤 따로 다룬다.
7. **`sessionBudgetExceeded` 는 지금처럼 홈 scope 소진으로 둔다.**
   - 계정 scope 로 넓히지 않는다. upstream 정의는 계정 한도가 아니라 클라이언트 rollout 토큰 예산이다
     (`codex-rs/protocol/src/error.rs` 87-88행, `rust-v0.157.1`). 지금은 두 오류를 한데 묶는다 (`lib/runtime/runtime_codex_app_server.ml:465`).
   - 이 처리가 맞는지는 #39637 에서 따로 다룬다.

## 관련 PR·이슈

- #28202, #28219: quota 창을 provider row 가 아니라 자격 증명 계정으로 묶었다. 이 RFC 는 같은 원칙을 Codex 계정에 적용한다.
- #38380, #38390: provider 사용량 창과 Overview 막대.
- #38671: Codex `account/rateLimits/read`. 이 RFC 가 쓰는 요청이다.
- #38764: 여러 Claude Code·Codex 계정과 `account-home`. 홈 = scope 를 만든 PR 이다.
- #38975: 403 뒤 사용량 읽기로 소진 기록.
- #39144: `usage-read.refresh-s`.
- #39518, #39527: 기존 계정을 기준으로 계정 선언 추가. 같은 홈은 거절하지만 같은 계정은 모른다.
- #39403, #39533, #39588: setup 계정 선택과 로그인 세션. 새 홈을 만드는 경로와 로그인 완료 지점은 위 "setup 마법사·로그인 계층과 겹치는 곳" 에 적었다.
- #39612: 로그인 직후 `auth.json` email 을 표시용으로 기록. 이 RFC 는 그 email 을 한도 주인으로 쓰지 않는다.
- #39604, #39617: 사용량 묶음의 provider 를 `{id, display_name}` 으로 싣고 dashboard 에 같은 home 줄을 그린다. 이 RFC 뒤에는 같은 계정 줄이 된다.
- #39400: Muse 모델 발견과 MCP 준비 확인. 겹치지 않는다.
- #39202 (열린 이슈): Antigravity·Muse 사용량 읽기 설계 메모. 겹치지 않는다.
- 검색: `gh pr list --state all --search 'quota scope codex account'`, `gh issue list --state all --search 'quota scope codex account'`,
  `'codex account_id'`, `'codex home account'`. 계정 id 로 scope 를 정하자는 PR·이슈는 없었다.

## 근거 기록

- **Evidence**: upstream `openai/codex` tag `rust-v0.156.0`, `rust-v0.157.1`, `rust-v0.158.0` 의
  `codex-rs/app-server-protocol/schema/json/v2/{GetAccountResponse,GetAccountRateLimitsResponse,AccountUpdatedNotification,AccountRateLimitsUpdatedNotification}.json`,
  `codex-rs/app-server-protocol/src/protocol/v2/account.rs`, `codex-rs/app-server/src/request_processors/account_processor.rs`,
  `codex-rs/login/src/auth/manager.rs`, `codex-rs/protocol/src/error.rs`, `codex-rs/core/src/agent/control/budget.rs`.
  로컬 `codex app-server generate-json-schema`(0.157.1). live 홈 셋의 auth.json 과 `account/rateLimits/read` 해시 비교.
- **Timestamp**: 2026-09-28T08:36Z (코드 인용은 base `c424573c76` 기준으로 다시 맞춤).
  결정 절과 그 절이 인용하는 줄은 2026-09-28T10:50Z 에 `origin/main` `59c99562db` 기준으로 다시 확인했다.
  리뷰 5337311627·5337367738 대응은 2026-09-28 에 upstream `36650394c5b38c2990ccf2a3457165ca3e9d9726` 소스와 안정 응답 스키마로 확인했다.
- **Confidence**: 계정 id 출처와 필드 모양은 높음. `accountId` 가 채워진다는 것은 중간–높음 (홈 둘, 읽기 세 번).
  강등이 홈끼리 공유되지 않는다는 것은 높음 (코드). reload guard 가 account id 만 검사한다는 것은 높음 (위 고정 commit 소스).
  `(accountId, email)` 과 turn 귀속의 안정성·홈 관측의 자격 증명 세대 공급 경로는 미해결이다.
  한도가 workspace 단위인지 seat 단위인지, app-server 가 두 요청을 동시에 처리하는지는 미검증. 재로그인 뒤 동작은 코드로만 확인.
- **Delta**: 안정 계약의 `account/read` 에는 계정 id 가 없지만 `account/rateLimits/read` 에는 0.156.0 부터 있다. 이 RFC 는 그 필드를 한도 주인의 근거로 쓴다.
