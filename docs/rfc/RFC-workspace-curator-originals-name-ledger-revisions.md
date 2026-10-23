---
rfc: "workspace-curator-originals-name-ledger-revisions"
title: "Curator 원본은 원장 판본을 digest 로 가리키고, 판본은 한 번만 저장한다"
status: Draft
created: 2026-10-23
updated: 2026-10-23
author: claude
related: ["workspace-curator-curates-changed-facts", "shared-memory-appends-a-log-and-keepers-read-from-their-position"]
---

# Curator 원본은 원장 판본을 digest 로 가리키고, 판본은 한 번만 저장한다

## 1. 문제

Workspace Curator 원본 하나는 원장 전체를 여러 벌 남긴다. 원장이 커지면 원본 하나가 남기는 바이트도 같이 커진다.

#41927 스택 A(#45199 → #45300)는 요청을 frame 안으로 줄였다. 요청 본문은 한 번만 쓰고, 끝난 원본은 패스가 읽지 않게 했다. 원장 사본은 그대로 두었다(`RFC-workspace-curator-curates-changed-facts.md` "남는 것"). 이 RFC 가 그 사본을 다룬다.

### 1.1 라이브에서 잰 값

2026-10-23 05:11Z, 스택 A 를 배포한 뒤 첫 분류 원본(`01a1672c-1969-…`)과 첫 Briefing 원본(`01a1672c-442c-…`)에서 쟀다.

| 무엇 | 바이트 | 그 안의 상태 사본 |
|---|---|---|
| 지금 원장 `workspace-memory/ledger.json` | 1,220,177 | — |
| 분류 원본의 요청 본문 (`lane-addons/tool-request-bodies/…`) | 5,769,793 | `work.ledger` 1,220,177. 내용이 그때의 `ledger.json` 과 같다(주장 791, 충돌 7, 사실 844) |
| 같은 원본의 실행 기록 입력 (`exact-lane-run-payloads-v7/<run>/input-*.json`) | 5,769,793 | 위 본문과 같은 바이트 |
| 지금 Briefing 상태 `workspace-memory/briefing.json` | 1,301,714 | — |
| Briefing 원본의 요청 본문 | 1,305,516 | `work.batch` 1,301,791. Briefing 상태 한 벌 |

이 원본은 아직 commit 하지 않았다. commit 뒤에 생기는 사본은 아래 1.2 의 코드 경로로 센 값이다.

### 1.2 원본 하나가 남기는 사본 (main `ed5cde5d230`)

분류 원본 하나가 정상으로 끝나면 원장 전체가 9벌 남는다. 이전 상태가 5벌, 이후 상태가 4벌이다. 결정에 쓰는 것은 1번 하나다. 나머지는 같음 비교, 무결성 확인, 증거, 화면에만 쓴다.

| # | 저장 위치 | 어느 원장 | 넣는 코드 | 읽는 곳 |
|---|---|---|---|---|
| 1 | 요청 본문 `work.ledger` | 캡처한 원장(= 이전) | `workspace_memory_execution_capture.ml:117-119` | 결정. 복원, 답 검사, commit 계획 |
| 2 | 소유 기록 `commit_intended.before` | 이전 | `workspace_memory_execution_capture.ml:470-472`, 게시 `server_workspace_memory_addon.ml:404` | 같음 비교만 (`lane_addon_request_progress.ml:125-129`) |
| 3 | 소유 기록 `commit_intended.after` | 이후(예상) | `workspace_memory_execution_capture.ml:473` | 같음 비교만 (`lane_addon_request_progress.ml:132-141`) |
| 4 | 소유 기록 `commit_observed.after` | 이후(디스크에서 다시 읽음) | `server_workspace_memory_addon.ml:357`, 복구 `:376` | 3번과 같은지만 본다 |
| 5, 6 | 소유 기록 `observer_completion_intended.receipt.payload.result.commit.before/after` | 이전, 이후 | `workspace_memory_observation_receipt.ml:96-99` | digest 다시 계산(`lane_addon_request_receipt.ml:19-30`), 같음 비교(`workspace_memory_observation_receipt.ml:134-136`) |
| 7 | 실행 기록 `input-<sha>.json` | 캡처한 원장 | `workspace_memory_observation_receipt.ml:15`, 쓰기 `exact_lane_run_registry.ml:1214` | 같음 비교(`exact_lane_run_registry.ml:1162-1168`), 화면 |
| 8 | 실행 기록 `output-<sha>.json` (2벌) | 이전, 이후 | `server_workspace_memory_addon.ml:703` | 같음 비교, 화면 |

9 × 1,220,177 = 10,981,593 바이트다. 이 원본이 commit 하면 원장 사본으로만 이만큼 남는다(1.1 의 원장 크기에 벌 수를 곱한 계산값).

정상 경로 밖에서 더 생기는 사본이 있다.

- commit 을 다시 시도하면 `commit_retry_observed.before` 에 지금 원장 전체가 들어간다(`server_workspace_memory_addon.ml:393`).
- 충돌이면 `commit_conflicted.observed` 에 그때 원장 전체가 들어가고(`:359`, `:378`, `:382`), 완료 영수증의 `result.observed` 로 한 번 더 복사된다(`workspace_memory_observation_receipt.ml:100-101`). 그래서 소유 기록과 실행 기록 출력에 같이 남는다.
- 크기 거절 뒤의 자식 캡처는 부모가 캡처한 원장을 다시 품는다(`workspace_memory_execution_capture.ml:300-307`). 자식은 새 본문과 새 실행 기록 입력을 따로 갖는다.

Briefing 원본도 모양이 같다. 원장 대신 Briefing 상태가 들어간다: 요청 본문 `work.batch.state`, `commit_intended` 전후, `commit_observed`, 완료 영수증 전후, 실행 기록 입력과 출력. Briefing 상태는 원장의 주장·충돌마다 (id, sha256) 와, 아직 쓰지 않은 출처의 `{id, kind, text}` 를 모두 갖는다. 새로 시작하는 패스라면 모든 주장·충돌의 본문이다.

### 1.3 이 사본이 드는 곳

- **기록을 다시 쓸 때.** 소유 기록은 진행 이벤트가 붙을 때마다 통째로 다시 쓴다(`lane_addon_tool_request_owner.ml:178-199`). `commit_intended` 뒤로는 쓸 때마다 원장 2벌, 3벌, 5벌을 함께 쓴다.
- **패스마다.** discover 는 할 일 있는 기록의 모든 이벤트를 디코드한다(`lane_addon_tool_request_owner.ml:119-135`). 디코드할 때 2~4번의 같음 비교를 다시 하고, 5·6번의 digest 를 다시 계산한다. 마지막으로 답을 받은 분류 사슬은 다음 묶음 크기의 근거라서 #45300 이 scope 에 남긴다(`workspace_memory_execution_capture.ml:447-451`). 그래서 패스마다 원장 5벌을 가진 기록 하나 이상을 디코드한다.
- **오래 남는 곳.** 끝난 원본은 #45300 이 날짜별 보관 위치로 옮기고 지우지 않는다. 실행 기록은 레인마다 끝난 실행을 최근 2,000개까지 남긴다(`exact_lane_run_registry.ml:339` `completed_retention = `Latest 2000`, `retention_group` 은 레인별). 입력 파일만 세어도 Curator 레인이 2,000 × 5.77MB ≈ 11.5GB 까지 쌓을 수 있다. 지금 Curator 레인 실행 기록은 3개, 470MB 다(대부분 10-22 의 160MB 요청).
- **같은 판본의 반복.** 두 묶음 사이에 원장이 바뀌지 않았으면 두 원본이 같은 1.2MB 를 각자 갖는다.

## 2. 지금 있는 것

- `RFC-shared-memory-appends-a-log-and-keepers-read-from-their-position.md`(Draft)는 원장이 바뀔 때마다 log 에 묶음을 덧붙인다. 묶음은 `before_revision`, `after_revision`, `seq_range`, `entries_sha256` 를 갖는다(§3.1). Q6 2단계는 "다음 원장 snapshot을 불변 파일로 내구 저장하고 … 이전 게시 snapshot도 보존한다"고 정한다. 판본을 이름으로 하는 불변 파일을 이미 전제한다.
- `lib/workspace_memory/workspace_memory_log.ml(.mli)` 는 그 RFC 의 1단계로 2026-10-14 에 들어왔다(`1b6a8f4fee3`). 묶음 머리에 판본이 없다(`batch_header = { batch_id; author; started_at; expected_changes }`). 운영 코드에서 부르는 곳이 없고, 테스트만 있다(`test/test_workspace_memory_log_reader.ml`).
- 원장 digest 는 이미 있다. `ledger_sha256` 은 `Yojson.Safe.to_string (Ledger.to_json ledger)` 의 SHA-256 이다(`workspace_memory_ledger.ml:362-363`). `Ledger.save` 가 `ledger.json` 에 쓰는 바이트가 바로 이것이라(`:318-323`), `ledger.json` 파일의 SHA-256 과 같다. 라이브 값은 `62d16978…`(1,220,177 바이트)다. ledger view(`workspace_memory_ledger_view.ml:9-15`), Keeper recall, Keeper 프롬프트, 대시보드가 이 값을 쓴다. Curator 실행 경로는 이 값을 계산하지도 저장하지도 않는다.
- 원본에 들어간 사본은 키를 정렬한 형태다(`lane_addon_action.ml:32-35`). 그래서 사본의 SHA-256 은 `ledger_sha256` 과 다르다.
- Briefing 에는 앞선 예가 있다. `briefing_state_sha256` 은 정규화한 `Brief.to_json` 의 SHA-256 이다(`workspace_memory_execution_capture.ml:222-223`). 요약에 `prepared_state_sha256` 으로 저장하고(`:186`, `:229-231`) 여러 곳에서 비교한다(`:261-263`, `:449`, `server_workspace_memory_curator.ml:93-95`, `:160-164`).

## 3. 결정

### 3.1 판본은 이미 있는 digest 를 쓴다

- 원장 판본(revision)은 `ledger_sha256` 이다. 정규화를 새로 만들지 않는다. `ledger.json` 의 SHA-256 이 곧 판본이라, 지금 원장의 판본은 파일을 해시하면 나온다.
- Briefing 상태 판본은 `briefing_state_sha256` 이다.
- 판본 파일의 바이트는 그 digest 가 해시하는 바이트 그대로다. 그래서 파일의 SHA-256 이 파일 이름과 같다. 원장 판본 파일은 그 판본일 때의 `ledger.json` 과 바이트까지 같다.

### 3.2 판본은 한 번만 저장한다

판본 파일은 상태 종류마다 디렉터리를 나눈다. 종류를 파일 안에 적으면 파일의 SHA-256 이 digest 와 달라지기 때문이다.

- 원장: `<base>/.masc/workspace-memory/revisions/ledger/<sha256>.json`
- Briefing 상태: `<base>/.masc/workspace-memory/revisions/briefing/<sha256>.json`

쓰고 읽는 규칙은 다음과 같다.

- 판본을 이름으로 쓰는 기록을 쓰기 전에, 그 판본 파일과 디렉터리를 fsync 한다. #45228 의 "본문 먼저, 기록 나중"과 같은 순서다. 판본을 기록에 처음 적는 쪽이 파일을 쓴다.
- 이미 있는 판본은 다시 쓰지 않는다. 파일의 SHA-256 이 이름과 같은지만 확인한다.
- 판본 파일만 있고 가리키는 기록이 없으면 쓰다 멈춘 흔적이다. 기록 없는 요청 본문(#45320)과 같은 종류라, 모으는 일도 같이 정한다.
- 읽는 쪽은 파일의 SHA-256 이 이름과 같을 때만 받는다. 파일이 없거나 digest 가 다르면 타입 있는 오류를 낸다. 빈 원장이나 지금 원장으로 바꿔 읽지 않는다.

### 3.3 원본은 상태 대신 판본을 남긴다

1.2 의 사본마다 무엇으로 바꾸고, 읽는 곳이 무엇을 비교하게 되는지다. 판본 digest 는 상태 바이트의 SHA-256 이라, 상태가 같은지는 digest 가 같은지로 본다. 지금의 같음 비교가 하던 일을 그대로 한다.

| # | 지금 | 바꾼 뒤 | 읽는 곳 |
|---|---|---|---|
| 1 | `work.ledger` (원장 전체) | `work.ledger_revision` | 복원이 판본 파일을 읽어 SHA-256 을 확인한 뒤, 지금과 같은 검사를 한다(모델 입력 다시 만들기 `workspace_memory_request.ml:257-267`, 프롬프트 SHA, `Ledger.apply` 로 답 검사, commit 계획). 원본의 `request_digest` 가 캡처를 묶고, 캡처가 판본을 묶고, 판본이 파일 바이트를 묶는다 |
| 2, 3 | `commit_intended.before/after` | `before_revision`, `after_revision` | 다시 시도할 때 이전 판본이 같은지, 관찰한 판본이 이후 판본과 같은지, 충돌이면 다른지를 digest 로 본다(`lane_addon_request_progress.ml:125-141`). 이후 판본 파일은 `commit_intended` 를 쓰기 전에 저장한다. 다시 commit 할 때 그 파일을 읽는다 |
| 4 | `commit_observed.after` | `observed_revision` | 이후 판본과 같은지 본다 |
| 5, 6 | 완료 영수증 `commit.before/after` | 판본 두 개 | 영수증 digest 와 다시 만든 영수증의 같음 비교가 판본 digest 위에서 그대로 돈다 |
| 7 | 실행 기록 입력(캡처 바이트) | 바꾸지 않는다 | 캡처에서 원장이 빠지므로 입력도 그만큼 준다. 다시 복원한 캡처와의 같음 비교(`exact_lane_run_registry.ml:1162-1168`)도 그대로다 |
| 8 | 실행 기록 출력(영수증) | 바꾸지 않는다 | 영수증이 판본만 가지므로 출력도 준다 |

정상 경로 밖의 사본도 같은 방식으로 바꾼다.

- `commit_retry_observed.before` 와 `commit_conflicted.observed` 는 판본 digest 가 된다. 충돌할 때 본 원장은 Curator 가 쓴 판본이 아니어도 판본 파일로 저장한다. 그래야 충돌의 증거가 나중에도 읽힌다.
- 자식 캡처는 부모와 같은 `ledger_revision` 을 갖는다. 원장을 다시 품지 않는다.
- 진행 기록을 통째로 비교하는 곳(`lane_addon_tool_request_owner.ml:97-101` `same_listed`, `server_workspace_memory_curator.ml:41` `changed`)은 바꾸지 않는다. 비교하는 값이 상태에서 digest 로 바뀔 뿐이다.

바뀐 뒤에는 기록을 다시 쓰거나 디코드하는 비용이 원장 크기와 상관없다. 원장을 읽는 곳은 복원 하나이고, 지금 본문 안의 원장을 파싱하던 일을 판본 파일에서 한다.

### 3.4 RFC-shared-memory 와 저장소 하나를 쓴다

- 그 RFC 의 묶음 `before_revision`·`after_revision` 은 이 판본이다.
- Q6 2단계의 "불변 snapshot 파일"은 이 저장소의 원장 판본 파일이다. Curator commit 이 이후 판본 파일을 먼저 저장하고 원장을 게시하는 순서도 같다. 두 RFC 가 같은 파일을 두 번 만들지 않는다.
- `Workspace_memory_log` 의 묶음 머리에는 판본이 없다. 그 RFC 의 스택을 이어갈 때 이 판본을 넣는다. 지금 쓰는 곳이 없어서 옛 log 를 읽는 코드는 필요 없다.

### 3.5 하드컷

캡처, 진행 기록, 영수증의 스키마가 바뀐다. 옛 기록을 읽는 코드는 만들지 않는다.

- 배포 전에 서버를 멈추고 Curator scope 의 원본을 `lane-addons/` 밖으로 옮긴다. 진행 중인 원본(`tool-request-owners/<scope>/`, `tool-request-bodies/<scope>/`)과 보관 위치(`tool-request-owners-settled/<scope>/`)를 모두 옮긴다.
- 실행 기록의 옛 입력·출력 파일은 닫힌 실행의 증거라 그대로 둔다. 2,000개 보존 규칙에 따라 차례로 빠진다.

### 3.6 판본 파일은 지우지 않는다

이 RFC 는 판본 파일을 지우지 않는다. 끝난 원본의 보관 위치를 지우지 않는 것과 같다.

- 판본 파일은 원장이 바뀔 때마다 하나 생긴다. Curator commit 과 사라진 사실을 정리하는 쓰기(`server_workspace_memory_curator.ml:127`)가 원장을 바꾼다. 같은 판본을 가리키는 원본들은 파일 하나를 같이 쓴다.
- 날짜별로 지우려면 원본, 보관 위치, log 가 가리키는 판본을 세는 참조 목록이 있어야 한다. 6장 Q1 로 남긴다.

## 4. 다른 방법과 비교

| 방법 | 원본 하나가 남기는 원장 바이트 | 좋은 점 | 나쁜 점 |
|---|---|---|---|
| 지금 | 원장 크기 × 9벌 | 원본 파일만 보면 다 있다 | 원장이 커질수록, 원본이 쌓일수록 늘어난다. 같은 판본을 원본마다 반복한다. 기록을 다시 쓸 때마다 같이 쓴다 |
| 원본 안에서 압축 | 압축한 원장 × 9벌 | 고칠 곳이 적다 | 여전히 원본마다 원장 크기에 비례한다. 디코드할 때마다 푼다 |
| 변경분만 남기고 판본 파일은 두지 않는다 | 변경분 | 가장 작다 | 어떤 판본을 다시 만들려면 처음부터 변경분을 다시 적용해야 한다. 복원 비용이 이력 길이에 비례하고, 처음 상태를 따로 둬야 한다 |
| 이 RFC: 판본 파일 + digest | 64자 digest 몇 개 | 판본 하나를 한 번만 저장한다. 이미 쓰는 digest 를 그대로 쓴다. RFC-shared-memory 와 같은 파일을 쓴다 | 원본만으로는 증거가 다 차지 않아서 판본 파일을 같이 봐야 한다. 판본 파일을 지우는 규칙이 따로 필요하다. 실행 기록 화면에서 원장 본문 대신 digest 가 보인다 |

## 5. 나눠 올리는 순서

스택으로 올린다. 층마다 draft PR 이다.

1. 판본 저장소. 쓰기, 읽기, SHA-256 확인, 종류별 디렉터리. 쓰는 곳은 아직 없다.
2. 캡처가 원장 판본을 가리킨다. 복원은 저장소에서 판본을 읽는다. 자식 캡처도 같다.
3. commit 전후, 다시 시도, 충돌이 판본을 쓴다.
4. 완료 영수증이 판본을 쓴다.
5. Briefing 상태에 같은 일을 한다.

RFC-shared-memory 의 log 묶음이 같은 판본을 쓰는 일은 그 RFC 의 스택에서 한다.

## 6. 정할 것

- **Q1. 판본 파일 지우기.** 원본, 보관 위치, log 가 가리키는 판본을 어떻게 셀지. 권고: 이 RFC 에서는 지우지 않는다. 보관 위치를 지우는 규칙을 정할 때 같이 정한다.
- **Q2. 실행 기록 입력.** 원본 본문을 통째로 다시 싣지 않고 본문 digest 만 실을지. 권고: 이번에는 하지 않는다. 실행 기록은 대시보드 같은 다른 읽는 곳이 있고, 원장이 빠지면 입력도 같이 준다.
- **Q3. 판본 파일이 없을 때.** 진행 중인 원본이 가리키는 판본 파일이 없으면 어떻게 할지. 권고: 그 원본을 읽는 discover 가 타입 있는 오류로 실패하고 운영자 화면에 보인다. 조용히 건너뛰지 않는다.
- **Q4. 실행 기록 화면.** 입력·출력에서 원장 본문 대신 digest 가 보인다. 화면에서 판본 파일을 따라가 보여 줄지. 권고: 이 스택에서는 하지 않는다. 필요하면 화면 쪽에서 따로 정한다.

## 7. 검증

모델 없이 테스트하는 것:

- 분류·Briefing 원본 하나가 끝까지 돈 뒤, 소유 기록, 요청 본문, 실행 기록 입력·출력 어디에도 원장이나 Briefing 상태 전체가 없다. 판본 digest 만 있다.
- 같은 판본을 가리키는 두 원본이 판본 파일 하나를 같이 쓴다.
- 원장 판본 파일과, 그 판본일 때 `Ledger.save` 가 쓴 `ledger.json` 이 바이트까지 같다.
- 판본 파일을 쓴 뒤 그 판본을 가리키는 기록을 쓰기 전에 멈추면, 기록 없는 판본 파일만 남는다. 다음 쓰기는 같은 파일을 다시 쓰지 않는다.
- 판본 파일의 SHA-256 이 이름과 다르면 복원을 거절한다.
- 판본 파일이 없으면 Q3 에서 정한 대로 동작한다.
- commit 복구가 판본만으로 지금과 같은 결론을 낸다. 지금 원장이 이후 판본이면 끝난 것이고, 이전 판본이면 다시 commit 하고, 둘 다 아니면 충돌이다. 충돌할 때 본 원장이 판본 파일로 남는다.
- 원장을 두 배로 키워도 원본 하나의 기록·본문 바이트는 늘지 않는다. 늘어나는 것은 판본 파일 하나다.

라이브에서 재는 것 (1장의 값과 비교):

- 원본 하나의 요청 본문, 소유 기록, 실행 기록 입력·출력 바이트.
- 판본 저장소의 파일 수와 바이트, 원장을 바꾼 횟수와의 비.
- 패스 하나가 디코드하는 기록의 바이트.

## 8. 다루지 않는 것

- 실행 기록의 보존 개수(2,000).
- 이웃 수 K 와 BM25 이웃 검색.
- 기록 없는 요청 본문과 판본 파일 모으기(#45320).
- RFC-shared-memory 의 Keeper 전달(위치, pending, 조각 나누기).
