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
| 그때 원장 `workspace-memory/ledger.json` | 1,220,177 | — |
| 분류 원본의 요청 본문 (`lane-addons/tool-request-bodies/…`) | 5,769,793 | `work.ledger` 1,220,177. 내용이 그때의 `ledger.json` 과 같다(주장 791, 충돌 7, 사실 844) |
| 같은 원본의 실행 기록 입력 (`exact-lane-run-payloads-v7/<run>/input-*.json`) | 5,769,793 | 위 본문과 같은 바이트 |
| 그때 Briefing 상태 `workspace-memory/briefing.json` | 1,301,714 | — |
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

9 × 1,220,177 = 10,981,593 바이트다. 이 원본이 commit 하면 원장 사본으로만 이만큼 남는다. 1.1 의 원장 크기에 벌 수를 곱한 계산값이고, commit 뒤에 잰 값이 아니다.

정상 경로 밖에서 더 생기는 사본이 있다.

- commit 을 다시 시도하면 `commit_retry_observed.before` 에 지금 원장 전체가 들어간다(`server_workspace_memory_addon.ml:393`).
- 충돌이면 `commit_conflicted.observed` 에 그때 원장 전체가 들어가고(`:359`, `:378`, `:382`), 완료 영수증의 `result.observed` 로 한 번 더 복사된다(`workspace_memory_observation_receipt.ml:100-101`). 그래서 소유 기록과 실행 기록 출력에 같이 남는다.
- 크기 거절 뒤의 자식 캡처는 부모가 캡처한 원장을 다시 품는다(`workspace_memory_execution_capture.ml:300-307`). 자식은 새 본문과 새 실행 기록 입력을 따로 갖는다.

Briefing 원본도 모양이 같다. 원장 대신 Briefing 상태가 들어간다: 요청 본문 `work.batch.state`, `commit_intended` 전후, `commit_observed`, 완료 영수증 전후, 실행 기록 입력과 출력. Briefing 상태는 원장의 주장·충돌마다 (id, sha256) 와, 아직 쓰지 않은 출처의 `{id, kind, text}` 를 모두 갖는다. 새로 시작하는 패스라면 모든 주장·충돌의 본문이다.

### 1.3 이 사본이 드는 곳

- **기록을 다시 쓸 때.** 소유 기록은 진행 이벤트가 붙을 때마다 통째로 다시 쓴다(`lane_addon_tool_request_owner.ml:178-199`). `commit_intended` 뒤로는 쓸 때마다 원장 2벌, 3벌, 5벌을 함께 쓴다.
- **패스마다.** discover 는 할 일 있는 기록의 모든 이벤트를 디코드한다(`lane_addon_tool_request_owner.ml:119-135`). 디코드할 때 2~4번의 같음 비교를 다시 하고, 5·6번의 digest 를 다시 계산한다. 마지막으로 답을 받은 분류 사슬은 다음 묶음 크기의 근거라서 #45300 이 scope 에 남긴다(`workspace_memory_execution_capture.ml:447-451`). 그래서 패스마다 원장 5벌을 가진 기록 하나 이상을 디코드한다.
- **오래 남는 곳.** 끝난 원본은 #45300 이 날짜별 보관 위치로 옮기고 지우지 않는다. 실행 기록은 레인마다 끝난 실행을 최근 2,000개까지 남긴다(`exact_lane_run_registry.ml:339` `completed_retention = `Latest 2000`, `retention_group` 은 레인별). 입력 파일만 세어도 Curator 레인이 2,000 × 5.77MB ≈ 11.5GB 까지 쌓을 수 있다.
  - 2026-10-23 06:22Z 직전에 센 Curator 레인 실행 기록은 5개, 입력 파일은 모두 504,208,718 바이트였다.
  - 그중 485,927,971 바이트가 10-22 실행 하나의 입력이다. 그때의 캡처가 160MB 요청을 세 벌 품었다.
- **같은 판본의 반복.** 두 묶음 사이에 원장이 바뀌지 않았으면 두 원본이 같은 원장을 각자 갖는다. 14:51 KST 재시작 뒤의 뿌리 `b7c6f5…` 와 그 자식 `4ac65f…` 는 같은 원장(1,217,480 바이트)을 한 벌씩 품었다.

## 2. 지금 있는 것

- `RFC-shared-memory-appends-a-log-and-keepers-read-from-their-position.md`(Draft)는 원장이 바뀔 때마다 log 에 묶음을 덧붙인다. 묶음은 `before_revision`, `after_revision`, `seq_range`, `entries_sha256` 를 갖는다(§3.1).
  - Q6 2단계는 "다음 원장 snapshot을 불변 파일로 내구 저장하고, 현재 원장을 batch identity와 함께 원자적으로 게시한다. 이전 게시 snapshot도 보존한다"고 정한다.
  - §3.2 는 "각 게시 snapshot은 현재 살아 있는 id의 `subject_ref`도 보존한다"고 정한다.
  - 그래서 그 snapshot 은 원장 바이트에 더해 `subject_ref` 와 batch identity 를 갖는다.
- `lib/workspace_memory/workspace_memory_log.ml(.mli)` 는 그 RFC 의 1단계로 2026-10-14 에 들어왔다(`1b6a8f4fee3`).
  - 묶음 머리(`batch_header = { batch_id; author; started_at; expected_changes }`)에도, `Committed` 기록(`workspace_memory_log.mli:27`)에도 판본이 없다.
  - 이 log 를 읽는 것은 `Workspace_memory_reader` 뿐이다. 둘 다 운영 코드에서 부르는 곳이 없고 테스트만 부른다.
- 원장 digest 는 이미 있다. `ledger_sha256` 은 `Yojson.Safe.to_string (Ledger.to_json ledger)` 의 SHA-256 이다(`Workspace_memory_ledger.sha256`, `workspace_memory_ledger.ml:126`, `:364`).
  - 쓰는 곳은 원장 파일을 파싱한 뒤 다시 직렬화해서 이 값을 구한다(`workspace_memory_ledger_view.ml:9-13`). 파일을 해시하지 않는다.
  - `Ledger.save` 가 같은 바이트를 쓰기 때문에(`:320-325`) 지금은 `ledger.json` 파일의 SHA-256 과도 같다. 05:11Z 값은 `62d16978…`(1,220,177 바이트)였다.
  - ledger view, Keeper recall, Keeper 프롬프트, 대시보드가 이 값을 쓴다. Curator 실행 경로는 이 값을 계산하지도 저장하지도 않는다.
- 원본에 들어간 사본은 키를 정렬한 형태다(`lane_addon_action.ml:32-35`). 그래서 사본의 SHA-256 은 `ledger_sha256` 과 다르다.
- Briefing 요약도 상태 digest 를 이미 갖는다. `prepared_state_sha256` 은 키를 정렬한 `Brief.to_json` 바이트의 SHA-256 이다(`Workspace_memory_revision.of_briefing`, `workspace_memory_execution_capture.ml:228`).
  - 요약에 저장하고(`:185-186`) 여러 곳에서 비교한다(`:259-260`, `:447`, `server_workspace_memory_curator.ml:94-96`, `:161-165`).
  - `Briefing.save` 는 키를 정렬하지 않고 쓴다(`workspace_memory_briefing.ml:282-284`). 그래서 `briefing.json` 파일의 SHA-256 은 이 값과 다르다.
- 원장과 Briefing 상태는 둘 다 자기 종류를 `schema` 필드에 적는다(`workspace_memory_ledger.ml:23`, `workspace_memory_briefing.ml:184`). 진행 기록은 상태를 `{kind, state}` 로 싸서 넣는다(`server_workspace_memory_addon.ml:263`).

## 3. 결정

### 3.1 판본은 이미 있는 digest 를 쓴다

- 원장 판본(revision)은 `ledger_sha256` 이다. 타입 있는 원장을 `Ledger.to_json` 으로 쓴 바이트의 SHA-256 이다(`Workspace_memory_ledger.sha256`). 정규화를 새로 만들지 않는다.
- Briefing 상태 판본은 키를 정렬한 `Brief.to_json` 바이트의 SHA-256 이다(`Workspace_memory_revision.of_briefing`). Briefing 요약의 `prepared_state_sha256` 이 이미 쓰는 값이다.
- 판본은 늘 타입 있는 값에서 구한다. 게시된 파일(`ledger.json`, `briefing.json`)을 해시하지 않는다.
  - 같은 원장을 들여쓰기만 다르게 쓴 파일도 판본이 같다.
  - `briefing.json` 은 키 순서가 달라서 파일 해시가 판본과 다르다. commit 관찰은 파일을 파싱한 뒤 판본을 구한다. 지금 `server_workspace_memory_curator.ml:94-95` 가 하는 방식이다.
- 판본 파일의 바이트는 그 digest 가 해시하는 바이트 그대로다. 그래서 파일의 SHA-256 이 파일 이름과 같다.
- 기록에는 판본을 종류와 함께 `{"kind": "ledger" | "briefing", "sha256": "<64자>"}` 로 적는다. 지금 `{kind, state}` 를 쓰는 자리다.
  - 코드에서는 종류마다 다른 생성자를 가진 닫힌 variant 로 읽는다.
  - `sha256` 은 경로를 만들기 전에 64자 소문자 hex 인지 확인한다(`String_util.is_lowercase_sha256_hex`). 요청 본문 이름과 같은 검사다.

### 3.2 판본은 한 번만 저장한다

판본 파일은 종류마다 디렉터리를 나눈다.

- 원장: `<base>/.masc/workspace-memory/revisions/ledger/<sha256>.json`
- Briefing 상태: `<base>/.masc/workspace-memory/revisions/briefing/<sha256>.json`

판본 참조는 종류마다 다른 생성자라서, 읽는 쪽은 파일을 열기 전에 어느 파서로 읽을지 안다. 디렉터리가 그 생성자를 따른다.

쓰는 규칙은 다음과 같다.

- 실행 기록(run registry)이 payload 를 쓰는 함수로 쓴다(`Keeper_fs.save_bytes_durable_atomic`). 임시 파일에 쓰고 fsync 한 뒤 이름을 바꾸고, 새로 만든 디렉터리까지 fsync 한다.
  - `<base>` 를 소유 루트로 넘긴다. `<base>` 는 이미 있는 디렉터리여야 하고, 그 아래에 symlink 가 있으면 쓰지 않는다.
  - 읽을 때도 같은 루트로 읽는다(`Fs_compat.load_owned_regular_file`). 파일 자리에 symlink 나 디렉터리가 있으면 따라가지 않고 거절한다.
- 이름이 바이트의 digest 라 다시 써도 같은 파일이 된다. 그래서 파일이 있는지 먼저 보지 않고 늘 쓴다.
- 쓰다가 멈추면 임시 파일만 남는다. `<sha256>.json` 이 반쯤 쓰인 채로 남지 않는다.
- 판본을 기록에 처음 적는 쓰기가, 기록을 쓰기 전에 그 판본 파일을 쓴다. 판본의 상태를 메모리에 가진 곳이 셋이다.
  - 캡처: 작업이 품은 상태. 분류는 원장, Briefing 은 묶음의 상태다.
  - commit 의도: 이후 상태.
  - 충돌 관찰: 디스크에서 본 상태.
- 영수증, 실행 기록 출력, commit 관찰, 다시 시도 관찰은 기록에 이미 있는 판본만 옮겨 적는다. 판본 파일을 쓰지 않는다.

읽는 규칙은 다음과 같다.

- 파일의 SHA-256 이 이름과 같고 `schema` 가 디렉터리 종류와 같을 때만 받는다.
- 파일이 없거나 둘 중 하나가 다르면 타입 있는 오류를 낸다. 빈 원장이나 지금 원장으로 바꿔 읽지 않는다.
- 밖에서 망가진 파일은 같은 판본을 다시 쓰는 쪽이 같은 바이트로 바꿔 놓는다. 같은 원장을 다시 캡처하거나, 같은 이후 상태를 다시 만들거나, 같은 충돌을 다시 볼 때만 그렇다.
- 원장이 이미 바뀐 뒤의 옛 판본은 다시 쓰이지 않는다. 그런 파일이 망가지면 파일이 없을 때(6장 Q3)와 같다.

### 3.3 원본은 상태 대신 판본을 남긴다

1.2 의 사본마다 무엇으로 바꾸고, 읽는 곳이 무엇을 비교하게 되는지다. 판본 digest 는 상태 바이트의 SHA-256 이라, 상태가 같은지는 digest 가 같은지로 본다. 지금의 같음 비교가 하던 일을 그대로 한다.

| # | 지금 | 바꾼 뒤 | 읽는 곳 |
|---|---|---|---|
| 1 | `work.ledger` (원장 전체) | `work.ledger_revision` | 복원이 판본 파일을 읽어 확인한 뒤, 지금과 같은 검사를 한다(모델 입력 다시 만들기 `workspace_memory_request.ml:257-267`, 프롬프트 SHA, `Ledger.apply` 로 답 검사, commit 계획). 원본의 `request_digest` 가 캡처를 묶고, 캡처가 판본을 묶고, 판본이 파일 바이트를 묶는다 |
| 2, 3 | `commit_intended.before/after` | 판본 두 개 | 저장한 commit 과 다시 만든 계획을 맞춰 보는 비교(`server_workspace_memory_addon.ml:338-342`, `workspace_memory_observation_receipt.ml:50-53`)와, 뒤 이벤트가 저장한 commit 과 맞는지 보는 비교(`lane_addon_request_progress.ml:125-141`)를 digest 로 한다. 다시 commit 할 때 쓸 원장은 캡처와 판단으로 다시 만든다(`:337`, `:361`). 저장한 이후 판본 파일은 읽지 않는다. 그래도 commit 이 게시하는 상태의 증거라서 `commit_intended` 를 쓰기 전에 쓴다 |
| 4 | `commit_observed.after` | 판본 | 이후 판본과 같은지 본다 |
| 5, 6 | 완료 영수증 `commit.before/after` | 판본 두 개 | 영수증 digest 와 다시 만든 영수증의 같음 비교가 판본 digest 위에서 그대로 돈다 |
| 7 | 실행 기록 입력(캡처 바이트) | 바꾸지 않는다 | 캡처에서 원장이 빠지므로 입력도 그만큼 준다. 다시 복원한 캡처와의 같음 비교(`exact_lane_run_registry.ml:1162-1168`)도 그대로다 |
| 8 | 실행 기록 출력(영수증) | 바꾸지 않는다 | 영수증이 판본만 가지므로 출력도 준다 |

7번이 얼마나 주는지 라이브 입력 세 개로 쟀다. 원장 자리를 64자 판본으로 바꾸고 같은 방식(키 정렬, 공백 없음)으로 다시 썼다. 같은 방식으로 다시 쓴 원래 입력은 파일과 바이트까지 같았다.

| 실행 | 지금 | 바꾼 뒤 |
|---|---|---|
| `01a1672c-1969-…` (05:11Z 뿌리) | 5,769,793 | 4,549,691 |
| `01a16750-8886-…` (14:51 KST 뿌리) | 5,765,934 | 4,548,529 |
| `01a16750-bf53-…` (그 자식) | 5,439,504 | 4,222,099 |

줄어드는 몫은 실행 하나에 약 1.2MB, 21% 다. 나머지는 요청이다(6장 Q2).

정상 경로 밖의 사본도 같은 방식으로 바꾼다.

- `commit_retry_observed.before` 는 판본이 된다. 이 이벤트는 지금 원장이 이전 상태일 때만 쓴다(`server_workspace_memory_addon.ml:386-396`). 그래서 새 판본 파일이 생기지 않는다.
- 자식 캡처는 부모와 같은 판본을 가리킨다. 원장을 다시 품지 않는다.
- 진행 기록을 통째로 비교하는 곳(`lane_addon_tool_request_owner.ml:97-101` `same_listed`, `server_workspace_memory_curator.ml:41` `changed`)은 바꾸지 않는다. 비교하는 값이 상태에서 digest 로 바뀔 뿐이다.

충돌 증거는 닫힌 variant 로 바꾼다. 지금은 모양이 둘이다. 상태 그대로(`:359`, `:378`)와, 상태에 이유 문자열 "Original sources or contract changed" 를 붙인 `{state, reason}`(`:382`)이다.

- `Moved of revision`: 지금 상태가 이전도 이후도 아니다. 본 판본을 담는다. 그 판본 파일을 먼저 쓰고 이벤트를 쓴다.
- `Sources_changed`: 상태는 이전 그대로인데, 원본의 출처나 계약이 바뀌었다. 본 상태가 이전 판본이라 판본을 따로 담지 않는다. 지금의 이유 문자열 자리다.
- 본 판본 파일을 쓰지 못하면 충돌로 적지 않는다. 원장을 읽지 못했을 때처럼(`:355`) `Commit_uncertain` 으로 적고, 다음 복구가 다시 본다.
- 영수증을 만들 때의 충돌 검사(`workspace_memory_observation_receipt.ml:54-77`)는 지금 본 상태를 파싱해서 종류를 확인한다. 바꾼 뒤에는 `Moved` 판본이 이전·이후 판본과 다른지 보고, 캡처 종류의 디렉터리에 그 파일이 있고 SHA-256 이 맞는지 본다. 그래서 충돌 증거가 나중에도 읽힌다.
- 이유 문자열을 그대로 보존하는지 보는 테스트(`test/test_workspace_curator_addon_commit.ml:908`)는 `Sources_changed` 가 영수증까지 그대로 가는지 보는 테스트가 된다.

캡처를 만드는 `make` 는 지금 순수 함수다. 작업을 JSON 으로 바꿨다가 다시 읽고, 다시 읽은 작업을 캡처의 작업으로 쓴다. 그래서 새 캡처와 복원한 캡처는 같은 작업을 갖고 같은 자식으로 줄어든다. 그 위에서는 렌더한 프롬프트와 계약만 확인한다(`workspace_memory_execution_capture.ml:143-153`). 작업 JSON 에 판본만 남으면, 다시 읽을 때 판본을 상태로 바꿔야 한다.

- 작업을 다시 읽는 함수가 판본을 상태로 바꾸는 함수를 인자로 받는다.
- `make` 는 메모리의 상태를 돌려주는 함수를 넘긴다. 그래서 순수 함수로 남는다.
- 복원은 판본 저장소를 읽는 함수를 넘긴다.

바뀐 뒤에는 기록을 다시 쓰거나 디코드하는 비용이 원장 크기와 상관없다. 상태 전체를 읽는 곳은 복원과 `Moved` 충돌 검사뿐이다.

### 3.4 RFC-shared-memory 와는 digest 를 같이 쓴다

- 그 RFC 의 묶음 `before_revision`·`after_revision` 은 이 판본 digest 다. 판본은 `Ledger.to_json` 바이트에서 구한다. batch identity 가 `Ledger.to_json` 밖에 있으면 판본은 그대로다. 원장 스키마를 바꿔 그 안에 넣으면 판본도 그 값을 포함한다.
- 그 RFC 의 게시 snapshot 은 원장 바이트에 더해 살아 있는 id 의 `subject_ref` 와 batch identity 를 갖는다. 그래서 원장 바이트만 담은 이 RFC 의 판본 파일과 같은 파일이 아니다.
- snapshot 의 모양은 그 RFC 가 정한다. snapshot 이 원장 바이트를 복사하지 않고 이 판본을 가리키면, 원장 바이트는 한 번만 저장된다. 그렇게 할지도 그 RFC 에서 정한다.
- `Ledger.of_json` 은 모르는 필드를 거절한다(`workspace_memory_ledger.ml:136-142`, `:252-253`). batch identity 를 `ledger.json` 안에 넣으려면 원장 스키마를 바꿔야 한다. 이 RFC 는 그 자리를 정하지 않는다.
- log 의 묶음 머리와 `Committed` 기록에는 판본이 없다. 그 RFC 의 스택을 이어갈 때 넣는다. 지금 쓰는 곳이 없어서 옛 log 를 읽는 코드는 필요 없다.

### 3.5 하드컷

캡처, 진행 기록, 영수증, 충돌 증거의 모양이 바뀐다. 옛 기록을 읽는 코드는 만들지 않는다.

배포 전에 서버를 멈추고 Curator scope 의 원본을 `lane-addons/` 밖으로 옮긴다. scope 디렉터리 이름은 `sha256("workspace-curator")` 인 `5e5665b7…` 다(`lane_addon_store.ml:333-334`, `:632-633`). 옮길 곳은 셋이다.

- 진행 중 기록: `lane-addons/tool-request-owners/5e5665b7…/`
- 요청 본문: `lane-addons/tool-request-bodies/5e5665b7…/`
- 보관 위치: `lane-addons/tool-request-owners-settled/5e5665b7…/<YYYY-MM-DD>/{records,bodies}/`

실행 기록의 옛 입력·출력 파일은 닫힌 실행의 증거라 그대로 둔다. 2,000개 보존 규칙에 따라 차례로 빠진다.

### 3.6 판본 파일은 지우지 않는다

이 RFC 는 판본 파일을 지우지 않는다. 끝난 원본의 보관 위치를 지우지 않는 것과 같다.

- 판본 파일은 Curator 기록이 처음 적는 판본에만 생긴다(3.2). 원장이 바뀔 때마다 생기지 않는다.
  - 사라진 사실을 정리하는 쓰기(`server_workspace_memory_curator.ml:127`)는 기록을 남기지 않아서 판본 파일도 만들지 않는다. 그 판본을 다음 캡처가 가리키면 그때 생긴다.
  - 라이브에서도 2026-10-23 14:51:33 KST 에 commit 없이 원장이 바뀌었다(`62d16978…` → `a3ba012a…`, 사실 844 → 842).
  - Briefing 의 정리 쓰기(`:182`)도 같다.
- 판본 파일 하나를 여러 곳이 가리킨다. 진행 중 기록, 보관 위치의 기록, 요청 본문, 실행 기록 입력과 출력이다. 실행 기록 입력은 캡처 바이트라 `work.ledger_revision` 을 갖고, 실행 기록을 맞춰 볼 때 다시 비교된다(`exact_lane_run_registry.ml:1162-1168`). 14:51 KST 뒤의 뿌리 `b7c6f5…` 와 자식 `4ac65f…` 도 같은 원장을 가리킨다.
- 그래서 진행 중 기록이 가리키지 않는다고 버려진 파일이 아니다. 기록 없는 요청 본문(#45320)처럼 모으지 않는다.
- 지우려면 이 참조를 모두 세야 한다. 판본을 쓰는 쪽과 같은 직렬화 아래에서 지워야 한다. 쓰는 쪽이 파일을 쓴 뒤 기록을 쓰기 전에 지우면, 기록이 없는 판본을 가리키게 된다. 6장 Q1 로 남긴다.

## 4. 다른 방법과 비교

| 방법 | 원본 하나가 남기는 원장 바이트 | 좋은 점 | 나쁜 점 |
|---|---|---|---|
| 지금 | 원장 크기 × 9벌 | 원본 파일만 보면 다 있다 | 원장이 커질수록, 원본이 쌓일수록 늘어난다. 같은 판본을 원본마다 반복한다. 기록을 다시 쓸 때마다 같이 쓴다 |
| 원본 안에서 압축 | 압축한 원장 × 9벌 | 고칠 곳이 적다 | 여전히 원본마다 원장 크기에 비례한다. 디코드할 때마다 푼다 |
| 변경분만 남기고 판본 파일은 두지 않는다 | 변경분 | 가장 작다 | 어떤 판본을 다시 만들려면 처음부터 변경분을 다시 적용해야 한다. 복원 비용이 이력 길이에 비례하고, 처음 상태를 따로 둬야 한다 |
| 이 RFC: 판본 파일 + digest | 64자 digest 몇 개 | 판본 하나를 한 번만 저장한다. 이미 쓰는 digest 를 그대로 쓴다. RFC-shared-memory 와 같은 digest 를 쓴다 | 원본만으로는 증거가 다 차지 않아서 판본 파일을 같이 봐야 한다. 판본 파일을 지우는 규칙이 따로 필요하다. 실행 기록 화면에서 원장 본문 대신 digest 가 보인다 |

## 5. 나눠 올리는 순서

스택으로 올린다. 층마다 draft PR 이다.

1. 판본 저장소. 종류별 판본 참조, 원자적 쓰기, SHA-256·`schema` 를 확인하는 읽기. 쓰는 곳은 아직 없다.
2. 캡처가 원장 판본을 가리킨다. 작업을 다시 읽는 함수가 판본을 상태로 바꾸는 함수를 받는다. 자식 캡처도 같다.
3. commit 전후, 다시 시도, 충돌이 판본을 쓴다. 충돌 증거를 `Moved`·`Sources_changed` 로 바꾼다.
4. 완료 영수증이 판본을 쓴다.
5. Briefing 상태에 같은 일을 한다.

RFC-shared-memory 의 log 묶음이 같은 판본을 쓰는 일은 그 RFC 의 스택에서 한다.

## 6. 정할 것

- **Q1. 판본 파일 지우기.** 진행 중 기록, 보관 위치, 요청 본문, 실행 기록 입력과 출력, log 가 가리키는 판본을 어떻게 셀지. 판본을 쓰는 쪽과 어떻게 직렬화할지.
  - 권고: 이 RFC 에서는 지우지 않는다. 보관 위치를 지우는 규칙을 정할 때 같이 정한다.
  - 요약에 판본을 두면 본문을 열지 않고 셀 수 있다. 그것도 그때 정한다.
- **Q2. 실행 기록 입력.** 원본 본문을 통째로 다시 싣지 않고 본문 digest 만 실을지.
  - 판본으로 줄어드는 몫은 실행 하나에 약 1.2MB(21%)다. 2,000개를 남기면 약 11.5GB 가 약 9.1GB 가 된다.
  - 나머지는 요청이다. 본문 digest 만 실으면 요청 몫도 빠진다.
  - 권고: 이번에는 하지 않는다. 실행 기록에는 대시보드 같은 다른 읽는 곳이 있다.
- **Q3. 판본 파일이 없을 때.** 진행 중인 원본이 가리키는 판본 파일이 없으면 어떻게 할지.
  - discover 는 기록과 요약을 읽는다(`server_workspace_memory_addon.ml:590-605`). 분류 요약에는 판본이 없다.
  - 판본을 읽는 곳은 복원이다. resume, settle, 자식 만들기, 관찰 영수증 배달, authorize 가 복원한다.
  - discover 도 한 곳에서 복원한다. 자식 의도만 적고 멈춘(`Subdividing`) 부모를 다시 이을 때다(`:608-629` → `recover_successor` `:514-517`).
  - 그 원본을 복원하는 순간 타입 있는 오류가 난다. 요청 본문이 없을 때와 같고, 영향 범위도 같다.
    - 그 원본이 `Subdividing` 부모이면 discover 자체가 실패한다. 두 도메인 패스가 모두 처음에서 멈춘다(`server_workspace_memory_curator.ml:191`). 관찰도, 보관도, 새 일도 없다.
    - 그 원본에 관찰할 일이 남았으면, 관찰 배달이 패스마다 복원에 실패한다. 그때 `observe` 가 "새 일 없음"을 돌려준다(`:70-83`). 두 도메인 패스가 모두 이 값을 쓰므로 둘 다 새 일을 받지 않는다.
    - 그 원본이 도메인의 할 일이면 그 도메인 패스가 매번 같은 오류로 멈춘다.
  - 배포 전 저장소 검사(`validate-stores`, `lane_addon_store_preflight.ml:276-290`)는 기록과 그 본문만 본다. 판본은 캡처를 열어야 이름을 알 수 있어서 보지 않는다.
  - 권고: 요청 본문이 없을 때와 같이 둔다. 건너뛰거나 원본을 자동으로 거절하지 않는다. 오류에 원본 id 와 판본을 적는다.
  - 다시 돌리려면 운영자가 그 원본의 사슬을 통째로 옮긴다. 자식은 부모와 같은 판본을 가리키고, discover 는 부모나 자식이 빠진 사슬을 거절한다(`workspace_memory_execution_capture.ml:365-366`, `:396-397`).
- **Q4. 실행 기록 화면.** 입력·출력에서 원장 본문 대신 digest 가 보인다. 화면에서 판본 파일을 따라가 보여 줄지.
  - 권고: 이 스택에서는 하지 않는다. 필요하면 화면 쪽에서 따로 정한다.

## 7. 검증

모델 없이 테스트하는 것:

- 분류·Briefing 원본 하나가 끝까지 돈 뒤, 소유 기록, 요청 본문, 실행 기록 입력·출력 어디에도 원장이나 Briefing 상태 전체가 없다. 판본 digest 만 있다.
- 같은 판본을 가리키는 두 원본이 판본 파일 하나를 같이 쓴다.
- 원장 판본 파일과, 그 원장을 `Ledger.save` 가 쓴 `ledger.json` 이 바이트까지 같다. 들여쓰기만 다른 `ledger.json` 도 같은 판본이 된다.
- Briefing 판본은 타입 있는 상태에서 구한다. `briefing.json` 의 키 순서와 상관없이 commit 관찰이 끝난다.
- 판본 파일을 쓰다가 멈추면 `<sha256>.json` 이 생기지 않는다. 다음 쓰기가 파일을 만든다.
- 판본 파일의 SHA-256 이 이름과 다르거나, `schema` 가 디렉터리 종류와 다르면 복원을 거절한다. 64자 소문자 hex 가 아닌 판본은 경로가 되지 않는다.
- 판본 파일이 없으면 Q3 에서 정한 대로 동작한다.
- commit 복구가 판본만으로 지금과 같은 결론을 낸다.
  - 지금 원장이 이후 판본이면 끝난 것이다.
  - 이전 판본이고 출처와 계약이 그대로면 다시 commit 한다. `Committing` 에서 멈춘 원본은 `Commit_uncertain` 을 거쳐 다시 commit 한다.
  - 이전 판본인데 출처나 계약이 바뀌었으면 `Sources_changed` 충돌이다.
  - 둘 다 아니면 `Moved` 충돌이다. 본 판본 파일이 남는다.
  - 본 판본 파일을 쓰지 못하면 `Commit_uncertain` 이다. 다음 복구가 다시 본다.
- 원장을 두 배로 키워도 원본 하나의 기록·본문 바이트는 늘지 않는다. 늘어나는 것은 판본 파일 하나다.

라이브에서 재는 것 (1장의 값과 비교):

- 원본 하나의 요청 본문, 소유 기록, 실행 기록 입력·출력 바이트.
- 판본 파일 수와 바이트, 그 판본을 가리키는 원본 수.
- 패스 하나가 디코드하는 기록의 바이트.

## 8. 다루지 않는 것

- 실행 기록의 보존 개수(2,000).
- 이웃 수 K 와 BM25 이웃 검색.
- 기록 없는 요청 본문 모으기(#45320). 판본 파일은 3.6 대로 모으지 않는다.
- RFC-shared-memory 의 snapshot 모양과 Keeper 전달(위치, pending, 조각 나누기).
