---
rfc: "a-restarted-server-reads-the-stored-usage-reports"
title: "다시 시작한 서버는 저장된 마지막 사용량 보고를 읽는다"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["0433", "0370", "provider-path-rest", "exact-lane-waits-for-a-stated-reset"]
---

# 다시 시작한 서버는 저장된 마지막 사용량 보고를 읽는다

## 0. 요약

서버가 다시 시작하면 계정별 사용량 표와 한도 표가 빈다.
계정이 다시 보고할 때까지 runtime 목록은 그 계정을 「시작 뒤 보고 없음」으로 보여 준다.
그런데 같은 보고는 이미 디스크에 날짜별로 남아 있다(`provider_usage_history`).

규칙은 하나다. **서버는 시작할 때 저장된 보고에서 계정의 창마다 가장 최근 값을 읽어 표에 올린다.**

- 올린 값은 원래 관측 시각을 그대로 갖는다. 화면은 그 시각을 보여 준다.
- 쉬게 할지는 살아 있는 보고와 같은 함수(`rest_scope`)가 지금 시각으로 정한다. 그 함수가 `Spent_until t` 를 내고 `t` 가 앞일 때만 그 계정을 `t` 까지 쉬게 한다. 찬 창이 하나 있다는 것만으로는 쉬지 않는다:
  - 모델 호출을 막지 않는 창(`counts_other_use`, 예: Z.AI `TIME_LIMIT`)은 100%여도 세지 않는다.
  - Antigravity 는 모델 호출을 막는 창이 전부 찼을 때만 쉰다. 하나라도 남으면 쓸 수 있다.
  - 살아 있는 보고가 쉬게 하지 않는 source(Claude Code, Codex)는 되읽어도 쉬게 하지 않는다. 그 계정들은 화면의 사용량만 돌아온다.
- 풀리는 시각 없이 찼다는 보고는 쉬게 하지 않는다. 화면에만 올린다.
- 새 저장소는 없다. 저장 행에 필드 하나(`role`)가 는다(R0).

## 1. 지금 동작

### 1.1 실측 (2026-11-12)

서버가 00:26:23Z 에 다시 시작했다(`/health` 의 `build.started_at`).

`claude_code_e664f266` 계정:

- 저장된 마지막 보고: `seven_day` 100%, 풀리는 시각 2026-11-13T14:00Z. 재시작 8.4시간 전 관측.
- 재시작 뒤 첫 보고: 49분 뒤(01:16Z).
- 그 49분 동안 `/api/v1/runtime/resolved` 는 이 계정을 `not_reported_since_start` 로, 그 runtime 들을 `quota_exhausted: false` 로 냈다.
- 운영자는 그 사이에 Keeper 하나를 이 계정으로 옮겼다. 첫 턴이 `Claude Code quota blocked (spent windows=seven_day …)` 로 실패했고, 그제야 목록이 소진으로 바뀌었다.

같은 시각 다른 Claude Code 계정 셋(`8d7c2775`, `ac22c1f2`, `8ad4ff55`)도 저장 기록에 `seven_day` 100%·풀리는 시각 앞이 있었다.
이 셋은 재시작 2~4분 뒤에 다시 보고가 왔다.

셈 범위: `provider_usage_history/2026-10/*`, `2026-11/*` 의 창 행 중 `observed_at` 이 재시작 시각보다 앞인 것. 계정·source·창 종류마다 최신 행을 봤다.
셈 스크립트와 결과: `docs/evidence/2026-11-12-usage-reports-at-restart/`.

### 1.2 코드

- `Runtime_provider_usage_window.record` 가 보고를 메모리 표에 올리고, 관측자(`set_record_observer`)를 부른다.
- `Server_provider_usage_history.install` 이 그 관측자로 보고를 `Dated_jsonl` 날짜 파일에 덧붙인다. 한 줄은 보고 하나이고, 창마다 행이 하나씩 든다. 행에 `scope_id`, `source`, `kind`, `observed_at`, `resets_at`, `unit`, `value` 가 있다. 한 보고의 행들은 `observed_at` 이 같다. 창을 다 실은 보고는 `complete_snapshot` 행을 앞에 둔다.
- 한 계정의 창들은 서로 다른 때에 보고된다. 1.1 의 `e664f266` 은 `seven_day` 가 8.4시간 전, `five_hour` 가 67.3시간 전 값이었다.
- `Runtime_provider_usage_window.rest_scope` 가 보고에서 「찼고 풀리는 시각이 있다」를 읽으면 `Runtime_quota_window.note_exhausted` 를 부른다.
- 표 둘 다 프로세스 메모리다. `runtime_quota_window.mli` 는 「a restart forgets it and the next refusal teaches it again」이라고 적는다.
- `/api/v1/runtime/resolved` 는 `provider_usage_windows_since`(프로세스 시작 시각)와 계정별 `state` 를 낸다. 시작 뒤 보고가 없으면 `not_reported_since_start` 다.

- 저장 행에는 창의 `role` 이 없다. `role`(`gates_model_calls` · `counts_other_use` · `unclassified_limit`)은 provider 응답의 다른 값에서 정해진다: Z.AI 는 `type`, Ollama 는 구매 잔액이 0보다 큰지. source 와 창 종류만으로는 되살릴 수 없다. `rest_scope` 는 `gates_model_calls` 창만 읽는다.
- `rest_scope` 는 `gate_coverage` 가 있는 source 에만 불린다. Claude Code 이벤트와 Codex 는 `None` 이다(`runtime_provider_usage_window.ml` 의 `gate_coverage`): 말한 창만 갖고 있어서, 찬 창이 거절된 호출의 모델을 덮는지 알 수 없다. 이 계정들의 `quota_exhausted` 는 거절(`Hard_quota`)에서만 온다. 1.1 의 `e664f266` 이 그 경우다.

저장은 이미 하고, 읽기는 14일 추이 화면(`Server_provider_usage_history.read`)만 한다. 시작할 때 표로 되읽는 길이 없다.

## 2. 규칙

- **R0** 저장 행에 `role` 을 적는다(`record_json`). 되읽기는 `role` 이 있는 행만 고른다. `role` 없는 옛 행을 위한 추정이나 변환은 두지 않는다: R0 이 설치되기 전에 저장된 행은 되읽지 않는다. 14일 추이 읽기는 이 필드를 보지 않는다.
- **R1** `install` 은 관측자를 달기 전에 저장 기록을 읽는다. 지금 설정에 있는 quota scope 마다, `scope_id` 가 같은 행을 source 와 창 종류(`kind`, `limit_id`)별로 나누고 각각 `observed_at` 이 가장 늦은 행을 고른다. 계정 하나에서 가장 늦은 행 하나를 고르지 않는다: 자주 보고되는 창이 오래된 소진 창을 가린다. 더 늦은 `complete_snapshot` 보고가 싣지 않은 창은 고르지 않는다(`read` 가 하루치를 접는 규칙과 같다). 범위는 `read` 가 이미 접는 14일이다.
- **R2** 고른 행들을 각자의 원래 `observed_at` 으로 메모리 표에 올린다. 이때 관측자는 부르지 않는다(같은 보고를 다시 저장하지 않는다).
- **R3** 올린 창 전체에 `rest_scope` 를 지금 시각으로 적용한다. `Spent_until t` 이고 `t` 가 앞이면 `note_exhausted` 다. 살아 있는 보고가 타는 것과 같은 함수이고, 같은 source 에만 적용한다(`gate_coverage` 가 `None` 인 source 는 건너뛴다).
- **R4** `Spent_without_reset` 은 `note_read_without_reset` 을 부르지 않는다. 그 쉼은 「관측한 순간부터 상한까지」인데, 관측한 순간이 재시작 전이다. 재시작 뒤에 그 길이를 다시 재면 masc 가 고른 시각으로 계정을 막게 된다.
- **R5** 풀리는 시각이 이미 지난 창도 표에는 올린다. 쉬게 하지는 않는다. 화면은 관측 시각으로 오래된 값임을 보여 준다.
- **R6** 계정 `state` 에 「저장 기록에서 읽음」을 더한다(`reported` · `not_reported_since_start` 옆의 세 번째 값). 시작 뒤 첫 보고가 오면 `reported` 가 된다. `provider_usage_windows_since` 의 뜻은 그대로다.
- **R7** 저장 기록을 못 읽으면 표는 빈 채로 시작한다. 시작을 막지 않는다. 못 읽은 사실은 로그에 남기고, `state` 는 `not_reported_since_start` 그대로다. 읽지 못한 줄은 `read` 와 같이 건너뛰고 센다.

## 3. 이 규칙이 하지 않는 것

- **Claude Code·Codex 계정을 쉬게 하기.** 되읽은 사용량은 화면에 「계정 한도 소진」으로 보이지만 `quota_exhausted` 는 `false` 로 남고 후보 순서도 그대로다. 1.1 의 계정은 재시작 뒤에도 한 번 거절당한 다음에야 쉰다. 운영자가 목록에서 찬 계정을 알아보는 것까지가 이 RFC 가 그 계정에 주는 것이다.
- **거절만 있고 보고가 없는 한도.** API provider 의 402·HardQuota 가 말한 풀리는 시각은 사용량 보고가 아니라서 저장 기록에 없다. 재시작하면 지금처럼 잊는다. 이것까지 남기려면 거절을 저장하는 새 기록이 필요하고, 이 RFC 범위 밖이다.
- **한 번도 보고한 적 없는 계정.** 1.1 의 시각에 다섯 계정(`mistral`, `claude`, `claude_vincent`, `opencode_go`, `tinker`)은 저장 기록이 0건이었다. 사용량을 묻는 경로가 없는 provider 다.
- **인증 거절.** 스택 #51460 이 행에 따로 싣는다. 재시작하면 잊는다.
- **14일 넘게 보고가 없던 창.** R1 의 범위 밖이라 올라오지 않는다. 지금 저장 기록의 창 종류는 `five_hour`, `seven_day`, provider 가 이름 붙인 창(`provider:…`) 여섯 가지, `duration_0m` 이다(`2026-10`·`2026-11` 전체를 셈). 풀리는 시각이 14일보다 먼 창이 있는지는 세지 않았다.
- **턴 없이 Claude Code 사용량 묻기.** `runtime_provider_usage_read.mli` 는 Claude Code 가 모델 턴 중에만 보고한다고 적는다.

## 4. 대가

- R0 이 설치된 뒤 첫 재시작은 그 사이에 보고된 창만 되읽는다. 그 전의 행은 `role` 이 없다.

- 시작할 때 날짜 파일을 최대 14일치 읽는다. 2026-11-11 하루 파일이 1.7 MB 였다. `read` 가 이미 같은 파일을 접어 두므로, 같은 접힌 결과를 쓰면 추가 읽기는 없다.
- 재시작 전에 계정 주인이 한도를 올렸거나 credential 을 바꿨으면, 저장된 「찼다」가 틀릴 수 있다. R3 은 provider 가 말한 시각까지만 쉬게 하고, Keeper walk 는 쉬는 후보도 남은 후보가 없으면 부른다(`Runtime_quota_window`: ordering preference). exact lane 은 그 시각까지 기다린다(RFC-exact-lane-waits-for-a-stated-reset). 살아 있는 보고가 틀렸을 때와 같은 대가다.
- scope 는 credential 위치의 digest 다. 같은 위치에 다른 계정의 키를 넣으면 옛 계정의 보고가 새 계정에 올라간다. 지금도 14일 추이가 같은 방식으로 섞인다.

## 5. 저장소 주인이 정할 것

1. R4: 풀리는 시각 없는 「찼다」를 재시작 뒤에 쉬게 하지 않는다. 대가는 그 계정이 재시작 뒤 한 번 더 거절당하는 것이다.
2. R6: `state` 에 세 번째 값을 더한다. 더하지 않고 `reported` 로 내면 화면은 관측 시각만으로 구분해야 한다. 더하면 TUI·Dashboard 디코더의 닫힌 합타입이 같은 층에서 바뀐다. 옛 TUI 는 모르는 `state` 를 받으면 디코드를 실패시킨다(strict_parse_no_default). 서버를 먼저 올리면 옛 TUI 의 사용량 표가 다시 띄울 때까지 읽히지 않는다.
3. 3절의 「거절만 있고 보고가 없는 한도」와 「Claude Code·Codex 계정을 쉬게 하기」를 따로 RFC 로 다룰지. 둘 다 거절을 저장해야 풀린다.

## 6. 구현 순서

0. `record_json` 이 `role` 을 적는다(R0). 이 층만 먼저 설치돼도 된다.
1. `Server_provider_usage_history`: 접힌 14일 결과에서 scope 별 최신 보고를 꺼내는 읽기. 시험: 날짜 파일 둘을 쓴 뒤 서버 상태를 새로 만들어 표와 한도 표를 읽는다. 한 계정에 창이 둘이고 더 오래 전에 보고된 창이 소진인 경우를 넣는다.
2. `Runtime_provider_usage_window`: 관측자를 부르지 않고 올리는 진입점, `state` 의 세 번째 값, `/api/v1/runtime/resolved` 와 TUI·Dashboard 디코더.
3. 설치 뒤 실측: 서버를 다시 시작하고 1분 안에 `/api/v1/runtime/resolved` 를 읽는다. 기대값은 저장 기록의 창을 계정·source 별로 `scope_room` 에 넣어 미리 계산한다.
   - `Spent_until t` 이고 `t` 가 읽는 시각보다 앞인 계정: `quota_exhausted: true`, `quota_resets_at` 이 `t`.
   - 모델 호출을 막지 않는 창만 찬 계정(Z.AI `TIME_LIMIT` 100%): `quota_exhausted: false`.
   - 창 일부만 찬 Antigravity 계정: `quota_exhausted: false`.
   - 풀리는 시각 없이 찬 계정(`Spent_without_reset`): `quota_exhausted: false`(R4).
   - Claude Code·Codex 계정: `quota_exhausted` 는 보지 않는다. `provider_usage_windows` 에 그 창이 원래 `observed_at` 으로 있는지만 본다.
   - 해당 계정이 저장 기록에 없는 갈래는 「사례 없음」으로 적고, 그 갈래는 1번의 시험이 덮는다.
