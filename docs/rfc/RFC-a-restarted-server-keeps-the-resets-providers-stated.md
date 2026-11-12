---
rfc: "a-restarted-server-keeps-the-resets-providers-stated"
title: "다시 시작한 서버는 provider 가 말한 풀리는 시각을 잊지 않는다"
status: Draft
created: 2026-11-12
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["0433", "0370", "0449", "provider-path-rest", "exact-lane-waits-for-a-stated-reset", "a-restarted-server-reads-the-stored-usage-reports"]
---

# 다시 시작한 서버는 provider 가 말한 풀리는 시각을 잊지 않는다

## 0. 요약

provider 가 호출을 거절하면서 「이 계정은 이 시각에 풀린다」고 말하면, masc 는 그 시각까지 그 계정을 뒤로 미룬다(`Runtime_quota_window.note_exhausted`).
이 기록은 프로세스 메모리에만 있다. 서버가 다시 시작하면 사라지고, 그 계정은 한 번 더 거절당한 뒤에야 다시 미뤄진다.

제안하는 규칙은 하나다. **provider 가 말한 풀리는 시각은 디스크에 적고, 서버는 시작할 때 아직 앞에 있는 시각을 읽어 한도 표에 올린다.**

- 적는 것은 provider 가 말한 시각(`Until`)뿐이다. 시각 없는 거절(`Observed`)은 적지 않는다.
- 되읽은 뒤의 표는 「재시작하지 않았다면 갖고 있었을 표」의 `Until` 부분과 같다.
- 새 저장소가 하나 생긴다.

**먼저 정할 것이 있다.** 이 기록이 없어도 사실은 손상되지 않는다. 다음 거절이 같은 사실을 다시 가르친다. 얻는 것은 재시작마다 소진된 계정 하나당 거절 한 번을 줄이는 것이다. 그 값이 새 저장소의 대가보다 큰지는 5절의 측정으로 정한다. 측정 전에는 구현하지 않는다.

## 1. 지금 동작

### 1.1 계기 (2026-11-12)

- `code-reviewer-mother` 를 `claude_code_e664f266` 계정으로 옮겼다. 그 계정은 7일 한도가 찬 상태였고 11-13 23:00 KST 에 풀린다.
- 옮기기 49분 전에 서버가 다시 시작했다. 목록의 그 계정은 `quota_exhausted: false` 였다.
- Claude Code 는 턴 중에만 사용량을 보고한다. 턴이 없던 계정은 재시작 뒤 사용량도 비어 있었다.

RFC-a-restarted-server-reads-the-stored-usage-reports 는 사용량 창을 되읽는다. 그 계정의 7일 창 100% 가 목록에 다시 보인다. 그러나 Claude Code·Codex 의 사용량 보고는 계정을 쉬게 하지 않는다(`gate_coverage` 가 `None`). 그 계정들의 쉼은 거절에서만 오고, 거절은 저장되지 않는다.

### 1.2 코드

- `Runtime_quota_window` 는 scope 별로 `Until resets_at`(provider 가 말한 시각) 또는 `Observed`(시각 없는 거절·읽기, masc 가 정한 상한까지)를 메모리에 갖는다. 모듈 주석이 적는다: 「재시작은 표를 잊고, 다음 거절이 다시 가르친다.」
- `note_exhausted` 를 부르는 곳은 여섯이다: 거절(`Runtime_candidate_standing.observe` 의 `Hard_quota { resets_at = Some _ }`), 사용량 보고(`rest_scope`), 사용량 읽기(`runtime_provider_usage_read.ml`), Muse 사용량(`runtime_muse_usage.ml` 두 곳), lane Add-on sampling.
- `note_succeeded` 는 `Observed` 만 지운다. `Until` 은 성공 한 번으로 지워지지 않고 그 시각이 지나야 사라진다.
- Keeper walk 에서 이 표는 순서 선호다. 미뤄진 후보도 남은 후보가 없으면 부른다. exact lane 은 `Until` 인 후보를 그 시각 전에 부르지 않는다(RFC-exact-lane-waits-for-a-stated-reset).

### 1.3 실측

- 재시작: `~/me/.masc/logs/masc-start-*.log` 를 날짜별로 세면 11-06 부터 11-12 낮까지 59번이다(하루 3~15번).
- 재시작 뒤 첫 거절이 몇 번이었는지는 세지 않았다. 5절이 세는 법이다.

## 2. 규칙

- **R1** `note_exhausted` 가 scope 의 `Until` 을 새로 만들거나 더 늦은 시각으로 늘릴 때, `(scope_id, resets_at, noted_at)` 한 행을 날짜별 저장소에 덧붙인다. 같거나 이른 시각으로 다시 불리면 적지 않는다. 적는 자리는 표 하나다: 부르는 곳 여섯에 각각 넣지 않는다.
- **R2** 시각 없는 거절과 읽기(`note_observed_exhausted`, `note_read_without_reset`)는 적지 않는다. 그 쉼의 끝은 masc 가 정한 상한이고, 성공 한 번이 지운다. 저장하면 성공도 저장해야 한다.
- **R3** 서버는 runtime 이 호출을 시작하기 전에 저장소를 읽는다. 지금 설정에 있는 scope 마다 `resets_at` 이 가장 늦은 행을 고르고, 그 시각이 지금보다 앞이면 `note_exhausted` 를 부른다. 이때 R1 의 덧붙이기는 하지 않는다.
- **R4** 저장소를 못 읽으면 표는 빈 채로 시작한다. 시작을 막지 않고 로그에 남긴다. 읽지 못한 줄은 건너뛰고 센다.
- **R5** 저장 행은 scope 원본을 갖지 않는다. `Runtime_quota_window.scope_id` 의 digest 만 적는다(사용량 저장소와 같다).
- **R6** 읽는 범위는 최근 14일의 날짜 파일이다. 14일보다 전에 들은 시각이 아직 앞에 있으면 되읽지 않는다. 그 계정은 지금처럼 다음 거절로 배운다.

R1~R3 이 지키는 것: 재시작 직후의 표에서 `Until` 인 scope 의 집합과 시각은, 재시작 없이 같은 시각까지 돌았을 표와 같다(R6 의 14일 밖은 뺀다). `Until` 은 메모리에서도 시각이 지나야만 사라지므로, 되읽기가 메모리가 하지 않았을 일을 하지 않는다.

## 3. 이 규칙이 하지 않는 것

- **시각 없는 거절을 남기기.** R2.
- **인증 거절·호출 제한(429)을 남기기.** 다른 표(`Runtime_credential_refusal`, `Runtime_candidate_backpressure`)이고 scope 의 한도 사실이 아니다.
- **Keeper 를 막기.** 표의 뜻은 그대로다. Keeper walk 에서는 순서 선호다.
- **목록 화면 바꾸기.** 행은 지금도 `quota_exhausted` 와 `quota_resets_at` 을 싣는다. 값이 재시작 직후부터 채워질 뿐이다.

## 4. 대가

- 새 날짜별 저장소 하나(`Dated_jsonl.Store.Root` 의 새 갈래)와 그 읽기·쓰기 코드. masc 는 「없으면 사실이 손상될 때만 새 상태를 더한다」고 정했다. 이 기록은 그 기준에 닿지 않는다: 없어도 다음 거절이 같은 사실을 준다. 이 RFC 를 받는다면 그 기준의 예외로 받는 것이다.
- 재시작 전에 계정 주인이 한도를 올렸거나 credential 을 바꿨으면 저장된 시각이 틀리다. 재시작이 없었어도 표는 같은 시각까지 틀렸을 것이다. 다만 지금은 재시작이 그 틀린 값을 지워 주는 부수 효과가 있고, 이 RFC 는 그것을 없앤다. exact lane 은 그 시각까지 그 계정을 부르지 않는다.
- scope 는 credential 위치의 digest 다. 같은 위치에 다른 계정의 키를 넣으면 옛 계정의 시각이 새 계정에 올라간다.
- RFC-a-restarted-server-reads-the-stored-usage-reports 의 R3(사용량 보고로 쉬게 하기)과 같은 표를 두 길로 채우게 된다. `note_exhausted` 가 더 늦은 시각만 받으므로 결과는 하나지만, 이 RFC 를 받으면 그 R3 은 없어도 된다(사용량 보고가 부른 `note_exhausted` 도 R1 이 적는다). 그 RFC 의 화면 되읽기(R1·R2·R5)는 그대로 필요하다.

## 5. 먼저 재는 것

구현 전에 최근 7일에서 센다.

1. 재시작 시각 목록(`masc-start-*.log`).
2. 각 재시작 뒤 첫 30분 안에 `Hard_quota` 이고 `resets_at` 이 있는 거절 중, 그 scope 가 재시작 직전에 `Until` 로 쉬고 있었던 것. 이것이 이 RFC 가 없앨 호출 수다.
3. 그 거절 하나가 만든 것: 실패로 끝난 Keeper 턴 수, exact lane 요청의 실패 수, 다음 후보로 넘어가는 데 걸린 시간.

2번이 하루 몇 번이고 3번이 「다음 후보로 바로 넘어감」뿐이면 이 RFC 는 닫는다. 재시작마다 Keeper 턴이나 exact lane 요청이 실패로 끝났다면 구현한다.

거절 기록이 어디에 어떤 모양으로 남는지는 아직 읽지 않았다. 재는 스크립트를 쓰기 전에 그것부터 확인한다.

## 6. 저장소 주인이 정할 것

1. 5절의 측정을 먼저 하고 그 결과로 정할지, 측정 없이 닫을지.
2. 받는다면 4절 넷째 항목: 사용량 RFC 의 R3 을 남길지 뺄지.
3. R6 의 범위 14일. 풀리는 시각이 14일보다 먼 provider 가 있는지는 세지 않았다.

## 7. 구현 순서 (받는 경우)

1. `Runtime_quota_window`: `Until` 이 늘 때 부르는 sink 진입점 하나(`set_stated_reset_observer`)와, sink 를 부르지 않고 올리는 진입점. 시험: 같은 시각을 두 번 말하면 한 행.
2. 서버: 저장소 갈래, 덧붙이기, 시작할 때 읽기. 시험: 행을 쓴 뒤 표를 비우고 읽어 `rest` 가 `Reset_stated` 인지, 지난 시각은 안 올라오는지, 설정에 없는 scope 는 안 올라오는지.
3. 설치 뒤 실측: 한도가 찬 계정이 있는 상태에서 서버를 다시 시작하고 1분 안에 `/api/v1/runtime/resolved` 를 읽는다. 그 계정이 `quota_exhausted: true` 이고 `quota_resets_at` 이 재시작 전과 같은지 본다.
