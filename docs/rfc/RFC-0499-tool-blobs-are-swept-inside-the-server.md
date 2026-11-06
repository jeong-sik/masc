---
rfc: "0499"
title: "tool_blobs 정리는 서버 안에서 24시간마다 돈다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["durable-tool-result-markers", "0476"]
---

# RFC-0499: tool_blobs 정리는 서버 안에서 24시간마다 돈다

- 상태: 초안
- 이슈: #48964
- 근거: §2 의 수치는 2026-11-06 05시(KST) 운영 workspace 에서 쟀다. 파일 이름, 크기, mtime 만 셌다. blob 내용과 참조 기록 내용은 열지 않았다. §3 의 코드는 `origin/main` `f2d98655513` 이다.
- 앞선 결정: #28298(08-12)이 정리를 서버 시작에서 오프라인 helper 로 옮겼다. #26977 은 서버 시작 때의 정리가 29번 중 한 번도 끝나지 않았다고 적었다.

## 0. 요약

`<base>/.masc/tool_blobs` 에 blob 2,462,539개, 20.0GB 가 있다. 가장 오래된 파일은 07-28 이다. 8월 초에는 54MB 였다.

정리 코드 `Tool_blob_maintenance.run` 은 있다. 두 번 스캔 규칙도 있다. 앞 스캔의 후보이면서 이번 스캔에서도 참조가 없는 blob 만 지운다. 하지만 이 코드는 BasePath lease 를 잡은 오프라인 명령에서만 돈다. 운영 서버는 lease 를 늘 쥐고 있다. 이 명령을 부르는 스크립트도 없다. 그래서 08-12 이후 한 번도 돌지 않았다. 이 명령은 스캔을 끝낼 때마다 `<base>/.masc/tool_blob_maintenance/candidates.json` 을 쓴다(지우지 않는 모드도 같다). 운영 BasePath 에는 이 파일이 없다(11-06 확인, `tool_blobs/` 는 07-30 부터 있다).

이 RFC 는 같은 규칙을 서버 안에서 돌린다. 서버가 쓰는 중에도 지우면 안 되는 blob 을 지우지 않도록 두 가지를 더한다.

- 스캔 사이에 이 프로세스가 쓰거나 읽은 주소는 지우지 않는다.
- 지울 때는 파일을 먼저 다른 이름으로 옮긴 뒤 건드림 기록을 다시 본다. 그사이 누가 건드렸으면 되돌린다.

1층은 지우지 않는다. 지울 후보와 "지웠다면 깨졌을 참조"를 센다. 범위층은 스캔이 못 읽는 저장소를 범위에 넣는다. 2층은 운영자가 1층 수치를 본 뒤 지우기를 켠다.

## 1. 결정

- D1. 정리는 서버 안에서 돈다. 서버의 정리 fiber 가 앞 스캔이 시작된 뒤 24시간이 지나면 다음 스캔을 연다. 앞 스캔 시작 시각은 표지 파일의 mtime 이라서, 서버를 다시 켜도 주기가 처음부터 다시 시작하지 않는다.
- D2. 두 번 스캔 규칙은 그대로다. 지울 수 있는 것은 "앞 스캔의 후보 ∩ 이번 스캔의 후보"다.
- D3. 그 집합에서 "건드린 주소"를 뺀다. 건드린 주소는 둘이다. 이 프로세스가 앞 스캔을 열기 전부터(프로세스가 그 뒤에 떴으면 프로세스 시작 뒤) `Tool_blob_store` 의 쓰기·읽기 함수로 다룬 주소, 그리고 파일 mtime 이 앞 스캔 시작 뒤인 주소다(§4.2).
- D4. 지우기는 `written_addresses` 에서 주소를 빼고, 파일을 다른 이름으로 옮긴 뒤, 건드린 주소인지와 옮긴 파일이 확인한 그 파일인지(inode·mtime) 다시 본다. 하나라도 어긋나면 되돌리고, 아니면 지운다. 잠금은 쓰지 않는다(§4.3).
- D5. 스캔과 지우기는 Eio 메인 domain 밖에서 돈다. 스캔이 실패하면 지금처럼 후보를 기록하지 않고, 아무것도 지우지 않는다.
- D6. 1층은 지우지 않는다. 후보 수, 지울 수 있는 수와 크기, 지웠다면 깨졌을 참조 수, 스캔 시간, 실패 종류를 로그와 후보 기록에 남긴다(§5).
- D7. 오프라인 명령 `tool-blob-maintenance` 는 범위층의 `unreadable` PR 이 지운다. 그 명령은 서버 스윕과 같은 스캔으로 지우기 모드를 부른다. 스캔이 읽지 못한 것을 두고도 끝까지 돌게 되면, 그 모드가 더 작은 참조 집합으로 후보를 만들어 지울 수 있다. 그 뒤 2층이 서버 스윕에 처음으로 지우기를 켠다. 정리하는 곳은 서버 하나만 남는다.
  - 같은 PR 에서 `Tool_blob_maintenance.live_references` 의 결과를 닫힌 합타입으로 바꾼다: 다 읽은 스캔(`Complete`)과 읽지 못한 것이 남은 스캔(`Partial`, `unreadable`·`reader_pending` 을 가짐). 이 참조 집합으로 무언가를 지우는 소비자는 `Partial` 에서 지우지 않는다. 타입이 갈라져 있어서, 지금 소비자와 나중 소비자 모두 컴파일러가 이 선택을 요구한다(§5.3 소비자 표).
  - `Observe_only`·`Delete_previous_candidates`·`Tool_blob_maintenance.run` 을 쓰는 시험은 main 에 13개 파일이다(`git grep -l`, 11-06). `test_tool_blob_store` 가 가장 많다. 지우기 루프는 함수로 꺼내 2층 서버 스윕이 쓰고, 그 시험들은 꺼낸 함수로 옮긴다. 지우기 규칙의 시험을 지우고 다시 짜지 않는다.
  - 명령 이름을 가리키는 주석(`deployment_preflight_helper.ml` 430행, 1465행 근처)도 같은 PR 에서 고친다.
- D8. 2층보다 먼저 스캔 범위를 닫는다. 범위는 값 하나로 둔다. `.masc`·`lane-addons`·config `keepers` 아래 항목마다 "범위"나 "이유 있는 제외" 중 하나에 속하지 않으면 그 이름이 후보 기록의 `unclassified` 에 남고, 그 기록은 아무것도 지울 수 없다(§5.3).

## 2. 지금 모습

### 2.1 저장소

| 항목 | 값 |
|---|---:|
| blob 파일 | 2,462,539 |
| 크기 | 20.0GB |
| 1KB 미만 | 1,110,424 |
| 1KB~16KB | 1,190,667 |
| 16KB~256KB | 157,320 |
| 256KB~4MB | 3,903 |
| 4MB 이상 | 225 |
| 파일 목록을 훑는 시간(Python `os.walk` + `lstat`) | 211초 |

mtime 으로 센 주별 증가는 09-21 주가 3.41GB 로 가장 크다. 10-05 주부터는 주마다 1.25~2.76GB 다. mtime 은 만든 시각이 아니다. 한 프로세스에서 처음 `put` 하면 파일을 다시 쓰기 때문에, 오래된 blob 도 최근 주에 잡힌다.

이 장비 디스크는 96% 를 쓰고 있다(남은 공간 183GiB).

### 2.2 참조를 찾는 범위

`Tool_blob_maintenance.durable_consumer_basenames` 와 Board 글 파일이다.

| 위치 | 크기 |
|---|---:|
| `keepers` | 7,869MB |
| `tool_calls` | 6,411MB |
| `traces` | 1,440MB |
| `wire-capture` | 231MB |
| `keeper_chat` | 148MB |
| `skill-composition-evidence-v1` | 76MB |
| `board_posts.jsonl` | 24MB |
| `messages` | 15MB |
| `keeper_msg_requests` | 12MB |
| `published_artifacts` | 1MB |
| `gate` | 0MB |
| `lane-addons/broadcasts`, `artifact_project_sources`, `artifact_project_builds` | 없음 |

합계 16GB 가 넘는다. 스캔은 파일마다 통째로 읽어 JSON 으로 푼다.

## 3. 코드가 하는 일

### 3.1 정리 규칙

`Tool_blob_maintenance.run` 은 이 순서로 돈다.

1. 참조 범위를 모두 읽어 살아 있는 sha256 집합을 만든다.
2. 앞 후보 기록을 읽는다.
3. blob 목록을 읽는다.
4. "목록 − 살아 있는 집합"을 이번 후보로 기록한다.
5. `Delete_previous_candidates` 면 "앞 후보 ∩ 이번 후보"를 지운다.

못 읽는 행, 깨진 참조, 읽는 도중 사라진 파일은 모두 오류로 끝난다. 그러면 후보를 기록하지 않고 지우지 않는다.

### 3.2 누가 부르나

- `bin/deployment_preflight_helper.ml` 의 `tool-blob-maintenance` 명령만 부른다.
- 이 명령은 `Server_startup_takeover.acquire_base_path_lock` 으로 lease 를 잡는다. 서버가 떠 있으면 `Base_path_already_owned` 로 끝난다.
- `scripts/` 의 어떤 스크립트도 이 명령을 부르지 않는다. container entrypoint 의 `lease-handoff` 는 배포 gate 만 준비 명령으로 돌린다.
- 운영 workspace 에 후보 기록 `<base>/.masc/tool_blob_maintenance/` 가 없다.

### 3.3 서버가 쓰는 중에 생기는 문제

오프라인에서는 쓰는 쪽이 없다. 서버 안에서 돌면 두 가지가 생긴다.

- `put` 은 이 프로세스가 이미 쓴 주소면 파일을 다시 쓰지 않는다(`written_addresses`). 정리가 그 파일을 지운 뒤 같은 본문을 `put` 하면, 파일 없이 참조만 남는다.
- 참조는 blob 을 쓰지 않고도 생긴다. Board 첨부(`board_tool_attachment.ml`)와 composition 초안(`keeper_composition_draft.ml`)은 `fetch` 로 blob 을 읽은 뒤 `Tool_output.make_artifact_ref` 로 참조를 만든다. 기록에서 푼 참조를 다시 쓰는 길도 있다. `normalized_artifact_ref_of_json` 과 `decode_from_agent_core` 는 여러 소비자가 부른다.

- 서버 밖 프로세스도 같은 저장소에 쓴다. `bin/masc_librarian_continuity.ml` 은 `--publish-base-path` 를 받으면 서버가 떠 있어도 `put_durable` 로 보고서 사본을 쓴다(294줄, 426줄). 이 쓰기는 서버의 건드림 기록에 남지 않는다. `bin/` 에서 `Tool_blob_store` 를 직접 여는 곳은 이것과 lease 를 잡는 helper 뿐이다. `bin/` 이 `lib/` 를 거쳐 여는 경로는 이 검색에 안 잡힌다. 어느 경로든 서버 밖 쓰기는 §4.2 의 mtime 조건이 덮는다.

두 번째 경우는 오프라인 정리에도 있다. 두 오프라인 실행 사이에 서버가 옛 참조를 다시 쓰면 같은 결과가 난다. 이 RFC 는 그 위험을 새로 만들지 않는다. 대신 1층에서 얼마나 생기는지 잰다(§5.2).

### 3.4 스캔이 못 읽는 참조

1층 PR(#48968)에서 참조를 쓰는 곳을 따라가 봤다. 다섯 곳은 스캔이 읽지 않는 곳에 참조를 쓴다. 앞의 셋은 #48971 에서, 뒤의 둘은 11-06 두 번째 측정에서 찾았다. 11-06 운영 workspace 에서 문자열 개수만 셌다.

| 쓰는 곳 | 위치 | 참조가 있는 파일 | 스캔이 못 읽는 이유 |
|---|---|---:|---|
| Librarian 요청 본문(`keeper_librarian_durable_request.ml`, `keeper_librarian_durable_capture.ml`) | `lane-addons/tool-request-bodies`, `tool-request-owners` | 184, 2 | 스캔은 `lane-addons/broadcasts` 만 읽는다. 본문은 캡처를 `Yojson.Safe.to_string` 으로 바꾼 문자열이라 폴더를 더해도 참조를 못 찾는다 |
| 완료 검토 journal(`verifier_review_execution.ml`) | `verifier-executions/<digest>/.masc/keepers/…/request-executions` | 18 | 검토 Keeper 의 `base_path` 가 `verifier-executions/<digest>` 다. media 는 workspace 저장소에 있다 |
| Librarian 작업 맥락(`keeper_librarian_context.ml`) | `<config>/keepers/<k>.working-context.json` | 0 | config 폴더는 범위가 아니다. media 가 있는 채팅 기록을 통째로 쓴다 |
| Librarian 작업 맥락 색인(`keeper_librarian_context_recall.ml:14`) | `<config>/keepers/<k>.working-context-recall.json` | 43 | config 폴더는 범위가 아니다. 색인이 blob 주소를 구조(`_blob`)로 들고 있고, 그 주소로 blob 을 꺼낸다(`:149`) |
| Exact 요청·호스트 결과·증거(`lane_addon_store.ml:55`, `:290`) | `lane-addons/exact-requests`, `host-results`, `evidence` | 9, 9, 1 | 스캔은 `lane-addons/broadcasts` 만 읽는다. addon 이 보낸 요청(캡처 포함)과 그 답이 표시를 문자열로 들고 있다 |

뒤의 둘은 이렇게 셌다. 작업 맥락 색인은 `_blob` 객체를 가진 파일 수다. Exact 기록은 `[masc:blob sha256=<64자> bytes=` 모양 표시를 가진 파일 수다. 표시 이름만 적은 설명 글은 세지 않는다.

- 작업 맥락 색인 43개가 blob 29개를 가리킨다. 모두 디스크에 있다. 34개는 범위 안 `keepers/<k>/librarian-recall-current.json` 에도 같은 주소가 있다. 남은 9개는 색인만 붙잡는다. blob 이 없으면 `repair` 가 스냅숏에서 다시 쓴다(`keeper_librarian_context_recall.ml:161`). 그래서 지워도 맥락은 돌아오지만, 그 턴은 다시 쓰는 비용을 낸다.
- Exact 기록 19개는 같은 sha256 하나를 가리킨다. 그 주소는 범위 안 `tool_calls`(10-27 행)와 `keeper_chat` 에도 있다. 그 행들이 보존 기간을 넘기면 Exact 기록만 남는다. Exact 호스트는 표시를 풀지 않는다(`lane_addon_exact.ml` 에 blob 읽기가 없다).
- 크기: `exact-requests` 2,194MB, `host-results` 2,595MB, `evidence` 6,382MB(11-06 `du -sm`). 범위에 넣으면 스캔이 16GB 에서 27GB 로 는다.

스캔 폴더 목록은 `vision_artifact_reference.ml` 에도 손으로 베껴져 있고, 13개 중 7개만 있다. 범위를 목록으로 들고 있는 한 새 저장소가 생길 때마다 이렇게 어긋난다.

1층의 `deletable` 은 그래서 상한이다. §5.2 도 이 경우를 세지 못한다. "지금 참조된다"를 스캔이 읽는 곳에서만 알기 때문이다.

### 3.5 다른 정리 명령

`vision-kept-maintenance` 와 `media-reading-maintenance` 도 lease 를 잡는 오프라인 명령이고, 부르는 곳이 없다. 이 둘은 `tool_blobs` 가 아닌 다른 저장소를 지운다. 비전 보관 이미지(`config/keepers/<keeper>.vision`)는 지금 약 700MB 다. 그 저장소를 언제 어떻게 정리할지는 이 RFC 의 범위가 아니다. #39331, #46721 이 다룬다.

다만 둘 다 이 RFC 가 바꾸는 스캔을 입력으로 쓴다.

- `media-reading-maintenance` 는 `live_references ~scope:Server_tool_blob_scope.scope` 로 참조 집합을 만들고, `holds_history_media` 에 걸리지 않는 기록을 두 번 스캔의 교집합으로 지운다(`keeper_media_reading_maintenance.ml` `run`). 범위층이 스캔을 "읽지 못해도 끝까지 돈다"로 바꾸면, 이 명령도 더 작은 참조 집합으로 지울 수 있다. 그래서 D7 의 합타입이 이 명령에도 걸린다. `Partial` 이면 오류로 끝난다.
- `vision-kept-maintenance` 는 `consumer_paths` 의 파일과 트리를 통째 바이트로 읽어 handle 문자열을 찾는다. 범위층이 범위에서 빼는 곳(CLI 홈 등)은 이 목록에서도 빠진다. 그래서 빼는 PR 은 그곳에 vision handle 이 몇 개 있는지 같이 센다. journal 같은 바이너리 파일에서 문자열 찾기가 맞는지는 확인하지 않았다. 이 명령의 문제이고, 이 RFC 는 그 목록에 무엇을 더하거나 빼는지만 적는다.

### 3.6 1층 스캔이 끝나지 않는다

1층(#48968)과 범위층 첫 조각(#49226)이 배포된 뒤 첫 스캔은 11-06 08:54:55Z 에 기록 없이 끝났다. `gate/late-approval.log.jsonl.lock` 을 풀지 못했다. 스캔은 범위 안 트리의 모든 일반 파일을 JSON 문서, JSONL 행, 표시 행 중 하나로 읽는다. 같은 규칙으로 범위 안 트리를 흉내 내 셌다(11-06 11시 UTC, 운영 workspace, 내용은 열지 않음).

| 원인 | 위치 | 파일 |
|---|---|---:|
| 잠금 파일. private JSONL 잠금은 표시 바이트 `\xA5` 하나를 쓴다 | `gate/*.jsonl.lock` 2, `traces/*/skill-activation-events.jsonl.lock` 36 | 38 |
| 실행 journal. `Execution_event_store` 의 `MACE` 프레임 이진 파일이다 | `keepers/*/request-executions/*/journal/events.v1.wal` 11,298, `traces/*/native-executions/*/events.v1.wal` 4,742 | 16,040 |
| Keeper 폴더 안에 공식 CLI 가 쓰는 자기 홈 | `keepers/<k>/official-client-runtime/muse-storage/**` 956, `keepers/<k>/github-cli/*.yml` 54 | 1,010 |
| macOS Finder 파일 | 트리 안 `.DS_Store` | 12 |
| 만드는 코드가 없는 파일 | `wire-capture/*/manual-*.sse.txt` | 1 |

- 실행 journal 은 blob 을 가리킨다. 표시를 가진 WAL 이 `keepers` 725개, `traces` 230개다. `_blob` 객체를 가진 WAL 은 1,049개, 275개다. 바이트 검색으로 셌고 프레임은 풀지 않았다. 그래서 범위에서 뺄 수 없다.
- 큰 tool 결과의 표시는 `ToolResult` 내용으로 journal 에 들어간다(`execution_journal.ml` `Event.Tool_result`). 끝나지 않은 native 실행은 재개할 때 그 결과를 읽고 blob 을 열어 확인한다(`keeper_direct_native_continuation.ml` `restore` → `Keeper_native_repetition_recovery.reconcile` → `Keeper_tool_progress_identity.digest_tool_io` → `Keeper_tool_answer.verified_stored_answer`). blob 이 없으면 이 확인은 `None` 이고, 반복 판정의 identity 가 답 대신 blob 주소로 바뀐다. 재개는 이어지지만 같은 호출을 같은 호출로 알아보지 못한다. 끝난 journal 을 다시 읽는 곳은 verifier 뿐이고, blob 은 읽지 않는다. 하지만 끝났는지 알려면 journal 을 읽어야 하고, 읽는 곳이 없다는 것은 주인이 아니라는 증거가 못 된다.
- 실행 journal 의 reader 는 `Execution_event_store.read_only_snapshot ~codec ~dir` 이다. `Eio.Path` 와 `Eio.Switch` 를 쓰고, codec 은 runtime 의 codec pool 을 쓴다. 스캔은 `Systhread_host.run` 으로 Eio 밖 system thread 에서 돈다(§4.4). 그 자리에서는 이 reader 를 부를 수 없다.
- `keepers` 와 `traces` 는 범위에 통째로 `Tree` 로 들어 있다. 닫힌 분류는 세 곳의 직속 항목만 나눈다. 그래서 그 아래의 비기록 파일은 분류도 경고도 없이 스캔을 끝낸다.
- `keepers/<k>/` 바로 아래 이름은 137가지, `traces/<t>/` 는 13가지다(11-06).

## 4. 설계

### 4.1 언제 도나

서버가 정리용 fiber 하나를 띄운다(`server_tool_blob_sweep.ml`, `start_background_maintenance` 에서 시작). 이 fiber 는 표지 파일 `<base>/.masc/tool_blob_maintenance/scan-opened` 의 mtime 을 본다. 표지가 없거나 mtime 에서 24시간이 지났으면 정리 pass 를 연다. 아니면 그때까지 잔다. 서버를 다시 띄워도 같은 표지를 보므로 하루를 건너뛰거나 두 번 돌지 않는다.

pass 는 표지를 가장 먼저 쓴다. 그래서 앞 기록을 못 읽거나 스캔이 실패한 pass 도 연 것으로 친다. 다음 pass 는 그 pass 를 연 때부터 24시간 뒤다. 표지조차 못 쓴 pass 뒤에는 하루를 자고 다시 연다.

pass 는 한 fiber 안에서 차례로 돌므로 한 번에 하나만 돈다.

### 4.2 건드린 주소

`Tool_blob_store` 가 프로세스 전역 값 하나를 둔다.

```
type touch = { put : bool; read : bool }
type touches = { current : touch Touch_map.t; previous : touch Touch_map.t }   (* sha256 -> touch *)
val touch_ledger : touches Atomic.t
```

- `current`: 마지막 후보 기록을 쓴 뒤 건드린 주소
- `previous`: 그 앞 기록을 쓴 뒤부터 마지막 기록을 쓸 때까지 건드린 주소

스캔이 후보 기록을 다 쓴 뒤 `{ current = empty; previous = old.current }` 로 한 번에 바꾼다(CAS). 기록을 못 쓰고 끝난 스캔은 바꾸지 않는다. 그래서 두 집합을 합치면 늘 앞 스캔을 열기 전부터 건드린 주소를 덮는다. 스캔을 열 때 바꾸면, 실패한 스캔 하나가 그 앞 세대를 버려 다음 스캔이 앞 스캔 사이의 건드림을 못 본다. 두 집합을 따로 두고 옮긴 뒤 비우면, 그 사이에 기록된 건드림을 잃는다. 건드림 기록도 같은 값에 CAS 로 더한다. 프로세스가 앞 기록 뒤에 떴으면 `previous` 는 비어 있고 `current` 가 프로세스 시작부터 채운 집합이다.

건드림을 기록하는 함수는 `put`, `put_addressed`, `put_durable`, `put_durable_reuse`, `put_file_durable*`, `fetch`, `fetch_bounded`, `fetch_range` 다. 쓰기는 `put`, 읽기는 `read` 표시를 켠다. 한 주소의 표시는 덮지 않고 합친다. 읽은 뒤 쓴 주소가 `read` 로만 남으면 §5.2 의 분류가 틀어진다. 기록은 파일을 보기 **전에** 한다. 이 모듈 밖에서 blob 파일 경로를 직접 쓰거나 읽는 코드는 lib·bin 에 없다(`root_dir` 은 시험에서만 쓴다).

다른 프로세스의 쓰기는 파일로 본다. 한 프로세스에서 처음 `put` 하면 파일을 다시 쓰고, `put_durable` 은 매번 다시 쓴다. 그래서 다른 프로세스가 앞 스캔 시작 뒤에 쓴 blob 은 mtime 이 앞 스캔 시작 뒤다.

지울 수 있는 집합은 "앞 후보 ∩ 이번 후보 − `previous` − `current` − mtime 이 앞 스캔 시작 뒤인 것" 이다. 이것은 나이 기준이 아니다. 앞 스캔 뒤에 누가 그 파일을 썼다는 흔적이다.

이 범위로 충분한 이유:

- 이 프로세스가 지금 쥐고 있는 주소는 앞 스캔 시작 뒤에 쓰거나 읽은 것이다. 그보다 먼저 읽고 24시간 넘게 기록하지 않은 채 쥐는 경로가 있으면, 그것이 §5.2 가 재는 경우다.
- 앞 프로세스가 쥐고 있던 주소는 그 프로세스와 함께 사라졌다. 앞 프로세스가 그 참조를 기록했으면 이번 스캔이 읽는다. 단, 이 논증은 스캔 범위(`durable_consumer_basenames`)가 참조를 기록하는 곳을 모두 덮을 때만 맞다. 1층 PR 에서 producer 마다 쓰는 곳을 대조한다(§7).
- 서버 밖 프로세스가 쓴 주소는 mtime 으로 빠진다. 서버 밖 프로세스가 읽기만 하고 참조를 쓰는 경로는 `bin/` 에 없다.

메모리: 2026-09-15 에 하루 52,077개를 썼다고 `tool_blob_store.ml` 주석에 적혀 있다. 주소 하나가 약 160바이트라 두 집합을 합쳐도 하루 수십 MB 안쪽이다. 1층에서 실제 크기를 잰다.

### 4.3 지우는 순서

잠금은 쓰지 않는다. `put` 은 Eio fiber 와 system thread 양쪽에서 불리고, 파일을 쓰는 동안 fiber 가 양보할 수 있다. 그 사이 같은 domain 의 다른 fiber 가 stdlib `Mutex` 를 기다리면 domain 이 멈춘다. 그래서 순서로 막는다.

```
put h:                               fetch h:
  mark_put h             (atomic)      mark_read h            (atomic)
  if written_addresses has h: return   read file h
  write file h (temp + rename)
  written_addresses += h

delete h:
  written_addresses -= h
  if touch_of h <> None: skip
  st1 = lstat h;  if st1.mtime >= previous_scan_started_at: skip
  rename h -> h.deleting
  st2 = lstat h.deleting
  if touch_of h <> None or st2.ino <> st1.ino or st2.mtime <> st1.mtime:
    rename h.deleting -> h; skip
  unlink h.deleting
```

`lstat`·`rename`·`unlink` 은 지금 `Tool_blob_store.delete` 와 같이 소유 경로, 일반 파일, 같은 parent 를 확인하고 잡아 둔 parent 기준으로 한다.

`previous_scan_started_at` 은 `Unix.gettimeofday` 가 아니라, 스캔을 열 때 후보 기록 폴더(`tool_blob_maintenance/`)에 쓴 표지 파일의 mtime 으로 정한다. 이 폴더와 `tool_blobs` 는 같은 `<base>/.masc` 아래에 있어 같은 파일시스템 시계끼리 비교한다. 표지 파일을 blob 폴더에 두지 않는 것은 blob 목록에 섞이지 않게 하려는 것이다. `rename` 은 mtime 을 바꾸지 않으므로, 되돌린 blob 은 옛 mtime 그대로 다음 스캔에서 다시 판정된다.

경우를 나누면:

- 건드림이 첫 확인 전에 기록됐으면 `delete` 가 건너뛴다.
- `fetch` 가 첫 확인과 옮기기 사이에 기록하고 파일을 읽었으면, 두 번째 확인이 그것을 보고 되돌린다. 읽은 바이트와 파일이 같이 남는다.
- `fetch` 가 옮긴 뒤에 읽었으면 파일이 없다. 지금처럼 `Ok None` 을 돌려주고 주소를 잊는다. 조용히 지나가지 않는다.
- `put` 이 "이미 썼다"를 봤으면, 그 확인은 `delete` 가 `written_addresses` 에서 빼기 전이다. 그 앞에 건드림을 기록했으므로 `delete` 가 첫 확인이나 두 번째 확인에서 본다.
- `put` 이 `written_addresses` 에서 빠진 뒤에 왔으면 파일을 새로 쓴다. 두 번째 확인이 건드림을 보면 `h.deleting` 을 `h` 로 되돌린다. 같은 sha256 이라 내용이 같다. 두 번째 확인 뒤에 왔으면 `unlink` 는 `h.deleting` 만 지우고 새 `h` 는 남는다.
- 서버 밖 프로세스가 `lstat` 과 `rename` 사이에 파일을 바꿔 썼으면, 옮긴 파일의 inode 나 mtime 이 첫 `lstat` 과 다르다. 되돌린다. `rename` 뒤에 썼으면 새 `h` 가 생기고 `unlink` 는 `h.deleting` 만 지운다.
- `rename` 과 되돌리기 사이에 온 `fetch` 는 파일이 없어 `Ok None` 을 받는다. 되돌린 뒤에도 그 `fetch` 의 답은 바뀌지 않는다. 눈에 보이는 실패지만 지우지 않은 blob 에서 생긴다. 2층은 되돌린 횟수를 로그에 남겨 이 창이 얼마나 생기는지 잰다.

`touch_ledger` 는 §4.2 의 `Atomic` 값이다. OCaml 5 `Atomic` 은 순차 일관이라, 한 thread 의 기록이 다른 thread 의 확인에 순서대로 보인다.

서버가 `rename` 과 `unlink` 사이에 죽으면 `h.deleting` 이 남는다. 서버는 시작할 때, Keeper 와 요청을 받기 전에 남은 `h.deleting` 을 모두 `h` 로 되돌린다. 정리 pass 가 아니라 시작 단계에서 하는 이유는, 그 전에 오는 `fetch` 가 `Ok None` 을 받지 않게 하려는 것이다. 되돌린 주소는 다음 스캔에서 같은 규칙으로 다시 판정된다. blob 목록(`list_all_result`)은 `.deleting` 이름을 blob 으로 세지 않는다.

### 4.4 메인 domain 밖에서

스캔은 16GB 넘게 읽고 푼다. 메인 domain 에서 돌면 그동안 서버가 멈춘다. 1층은 정리 pass 전체를 `Systhread_host` 의 system thread 에서 돌린다. 그때 `tool_blob_maintenance.ml` 은 Eio·Domain_pool·Mutex 를 부르지 않고 `Fs_compat` 의 blocking 함수와 Unix 호출만 썼다.

실행 journal(§3.6)을 읽으면 이 전제가 바뀐다. journal reader 는 Eio 경로를 받는다.

- 스캔은 두 단계다. 지금 system thread 가 일반 파일을 읽으면서 실행 journal 디렉터리는 열지 않고 목록만 모은다. 그다음 서버가 넘긴 reader 가 그 목록을 읽는다.
- 스캔이 journal 을 읽은 뒤 그 journal 에 쓰인 사건은 이번 스캔에 보이지 않는다. 다음 스캔이 읽는다. 그 사이 사건이 가리키는 blob 은 건드린 주소로 빠진다(§4.2). 사건을 쓴 쪽은 서버 안에서 `Tool_blob_store` 의 쓰기 함수로 blob 을 다뤘다. 같은 sha256 이 이미 있어 파일을 다시 쓰지 않을 때도 `put` 은 쓰기를 건너뛰기 전에 건드림 표시를 남긴다(`tool_blob_store.ml` `mark_put`). blob 을 쓰지 않고 참조만 옮겨 쓰는 길은 §5.2 의 `u` 가 잰다.
- reader 는 메인 domain 이 아닌 domain 의 Eio 루프 위 fiber 로 돈다. 메인 domain 은 스캔을 기다리지 않는다(D5).
- reader 는 runtime 의 codec 으로 journal 을 읽고, 사건을 정규 JSON 인코딩으로 바꿔 돌려준다. 스캔은 그 JSON 에서 지금 규칙대로 참조를 찾는다. 사건 종류를 골라 필드를 꺼내지 않는다. 그래야 사건 종류가 늘어도 참조를 놓치지 않고, tool 결과 밖(요청 snapshot, checkpoint)에 있는 표시도 같은 길로 잡힌다.
- `read_only_snapshot` 은 모든 사건을 목록으로 쥔다. 큰 journal 1만 6천 개를 날마다 그렇게 읽지 않도록, agent_core 가 확정된 사건을 하나씩 흘려 주는 함수를 내보낸다. commit authority 규칙은 `read_only_snapshot` 과 같은 코드를 쓴다.
- blob 저장소 라이브러리는 agent_core 의 실행 저장소를 직접 부르지 않는다. 작업 맥락 디코더(§5.3)와 같은 방향이다.
- reader 가 들어오는 PR 부터 reader 는 scope 의 필수 값이다. reader 없이 만든 scope 는 없다. 그래서 "reader 대기" 는 그 PR 이 지운다.
- journal 하나를 읽는 시간에 상한을 둔다. 넘기면 그 journal 은 `unreadable`(시간 초과)로 남는다. 상한값은 reader 가 들어오기 전에 journal 읽기 시간 분포를 재고 정한다(§7).
- 나머지 파일은 지금처럼 `Fs_compat` 로 읽는다.

### 4.5 후보 기록

후보 기록 파일은 새 이름 `<base>/.masc/tool_blob_maintenance/candidates-v2` 에 새 모양으로 쓴다. 옛 파일 `candidates.json` 은 읽지 않는다. 옛 모양을 읽거나 옮기는 코드는 두지 않는다. 1층까지는 오프라인 명령이 옛 파일을 계속 쓴다. 범위층이 그 명령을 지우면(D7) 옛 파일은 아무도 읽지 않으므로 지우고 설치한다(그 PR changelog 의 Upgrade notes). 운영 workspace 에는 이 폴더가 없다.

후보가 수백만 개일 수 있다. 그래서 JSON 배열 하나로 쓰지 않는다. 첫 줄은 머리, 그다음은 한 줄에 sha256 하나다.

```
{"schema_version":2,"scan_started_at":1793900000.0,"candidates":<n>,"deletable":<m>,"untouched_live":<k>}
c <sha256>
d <sha256>
u <sha256>
```

`c` 는 후보, `d` 는 D3 의 집합(후보이면서 지울 수 있는 것), `u` 는 §5.2 의 "아무 흔적이 없다" 주소다. 머리의 개수와 줄 수가 다르면 그 파일을 읽지 않고 오류로 끝낸다. 1층은 `d` 를 지우지 않고 기록만 한다. 다음 스캔이 §5.2 의 수를 세는 데 쓴다.

범위층(§5.3)은 머리에 두 칸을 더한다. 기록 이름은 `candidates-v3`, `schema_version` 은 3 이다.

- `unreadable`: 트리 안에서 읽지 못한 파일과 journal 수다. 본문에 한 줄에 하나씩 `x <사유> <base 기준 경로>` 로 적는다. 사유는 닫힌 variant 의 이름이다(기록으로 풀지 못함, 읽기 실패, reader 거부). 운영자가 그 경로로 원인을 찾는다.
- `reader_pending`: reader 가 들어오기 전에 읽지 않고 넘긴 journal 디렉터리 수다. 경로는 적지 않는다. 그 규칙에 든 디렉터리 전부라서 목록이 더 알려 주는 것이 없다.
- `unclassified` 가 비지 않았거나 `unreadable`·`reader_pending` 이 0 이 아니면 `deletable` 은 0 이다. 머리를 풀 때 이 규칙을 어긴 기록은 거부한다. 지금 `unclassified` 를 검사하는 자리(`tool_blob_sweep.ml`)와 같다.
- 앞 기록이 이 규칙으로 깨끗하지 않았으면 이번 기록의 `deletable` 도 0 이다. 머리만 읽는 쪽도 "지울 수 있다"로 읽지 않는다.
- `candidates-v2` 는 읽지 않는다. 범위층의 Upgrade notes 에 "지우고 설치"로 적는다. 그 뒤 롤백한 서버는 앞 기록이 없는 것으로 보고 새로 시작한다. 잃는 것은 §5.2 비교 하루치다.

## 5. 층

### 5.1 1층: 세기만

- §4.1~§4.5 를 넣는다. 지우는 줄만 없다.
- pass 가 끝나면 로그 한 줄을 남긴다: 스캔 시간, 살아 있는 참조 수, blob 수, 후보 수, `deletable` 수와 크기, §5.2 의 수.
- 실패하면 오류 종류(`Durable_source_read_failed`, `Durable_source_parse_failed` 등)와 경로를 남긴다. 서버가 쓰는 중이라 "읽는 도중 사라진 파일"이나 "덜 쓰인 끝 줄"로 멈추는 일이 생길 수 있다. 1층에서 얼마나 자주 생기는지 본다. 자주 생기면 그 규칙을 2층 전에 따로 정한다. 범위층부터는 트리 안 파일 하나를 풀지 못해도 스캔이 끝나지 않고 그 파일이 `unreadable` 에 남는다(§5.3).

### 5.2 지웠다면 깨졌을 참조

앞 스캔의 `d` 중 이번 스캔에서 참조되는 주소를 센다. 2층이었다면 이 주소들은 앞 스캔 끝에 지워졌다. 그 뒤에 무슨 일이 있었는지로 셋으로 나눈다.

- 다시 썼다: 이 프로세스의 `previous`·`current` 에 `put` 표시가 있거나, 파일 mtime 이 앞 스캔 시작 뒤다. 2층이었어도 `put` 이 파일을 다시 써서 괜찮았다.
- 읽으려 했다: `read` 표시만 있다. 2층이었다면 `fetch` 가 `Ok None` 을 돌려줘서 그 기능이 눈에 보이게 실패했다(Board 첨부면 `Missing_artifact`).
- 아무 흔적이 없다: 2층이었다면 파일 없이 참조만 남았다. §3.3 의 "blob 을 쓰지 않고 참조를 다시 쓰는 길"이 실제로 있다는 뜻이다.

서버를 다시 켜면 건드림 집합이 비므로, 앞 프로세스가 읽은 경우는 "아무 흔적이 없다"로 셈한다. 위험 쪽으로 더 센다.

이 셈의 한계:

- 참조를 기록하지 않고 메모리에서만 쓰고 버린 경우는 이번 스캔에 나타나지 않는다. 그래서 `d` 중 `read` 표시가 있는 주소는 참조가 있든 없든 따로 센다. 2층이었다면 그 `fetch` 가 모두 `Ok None` 을 받았다.
- 1층은 앞 스캔 끝의 `d` 로 센다. 2층은 지우는 순간에 건드림과 mtime 을 다시 본다. 그래서 2층이 실제로 지우는 수는 `d` 보다 적거나 같다.

셋째 묶음은 sha256 을 후보 기록 파일에 `u <sha256>` 줄로 남긴다. 스캔이 모으는 참조에는 어느 파일에서 나왔는지가 없다. 그래서 운영자가 그 sha256 으로 참조 범위를 검색해 어느 producer 인지 찾는다. 내용은 남기지 않는다.

### 5.3 범위층: 스캔 범위를 닫는다

2층보다 먼저 낸다. 1층과 같은 서버 스캔을 쓰고, 지우지 않는다.

- 범위를 `Tool_blob_maintenance` 가 내보내는 값 하나로 둔다. `vision_artifact_reference.ml` 의 사본은 지우고 이 값을 쓴다.
- 닫힌 분류: 스캔을 열 때 세 곳의 직속 항목을 모두 나열한다. `<base>/.masc`, `lane-addons/`, config 의 `keepers/` 다. 항목마다 "범위" 또는 "제외(이유를 적은 variant)" 중 하나여야 한다. 어느 쪽에도 없는 항목이 있어도 스캔은 끝까지 돌고 후보 기록을 쓴다. 기록 머리에 그 이름을 `unclassified` 목록으로 적고, 그 기록의 `deletable` 은 0 이다. 스캔마다 그 이름을 경고 로그에 남긴다. 새 저장소를 만든 PR 은 이 경고로 분류를 정하게 된다.
  - 측정을 멈추지 않는 까닭: 분류에 없는 항목은 스캔이 읽지 않는 곳이다. 그래서 지우기만 멈추면 안전하다. 측정까지 멈추면 1층 수치와 `u` 줄이 쌓이지 않고, 건드림 기록도 회전하지 않는다. 운영 장비에는 사람이 둔 파일이 다시 생긴다.
  - 폴더는 이름으로 분류한다. 이름은 만드는 모듈이 내보내는 상수를 쓴다(`Lane_addon_store.tool_request_archive_directory` 등). 이름이 바뀌면 컴파일이 깨진다.
  - config `keepers/` 의 파일은 접미사로 분류한다. 예: `.toml` 은 제외(설정), `.vision` 은 제외(다른 저장소, §3.5), `.working-context.json` 은 범위.
  - 이름이 날마다 바뀌는 파일과 임시 파일도 규칙으로 적는다. 예: 날짜 파일 이름 규칙, 기존 `Atomic_temp_name` 판정. 적지 않으면 평소에 생기는 임시 파일 때문에 스캔이 계속 오류로 끝난다.
- Librarian 요청: owner 기록 안에 참조 목록을 구조로(`normalized_artifact_ref_to_json`) 둔다. 본문과 owner 기록은 다른 파일이고 본문이 먼저 게시된다. 그래서 조건은 "owner 기록이 보이면 그 안에 목록이 있다"다. 문자열 안을 훑어 참조를 찾는 코드는 두지 않는다. RFC-0498 이 settle 때 본문을 지우므로 보관 위치는 범위에 넣지 않는다.
  - 이미 있는 owner 기록에는 이 목록이 없다. 목록이 없는 살아 있는 기록을 만나면 스캔을 오류로 끝낸다.
  - 그런 기록이 하나라도 남으면 스캔이 기록을 쓰지 못한다. 그래서 이 층 PR 이 세 길 중 하나를 고른다. 지우고 설치한다. 끝난 요청이 settle 되기를 기다린다. 기존 typed decoder 로 캡처를 풀어 목록을 한 번 채운다.
- 완료 검토 journal: `verifier-executions/*/.masc/keepers/*/request-executions` 를 고정된 깊이로 나열해 범위에 넣는다. 그 깊이의 디렉터리를 나열하지 못하면 스캔 오류다. review_root 안에 따로 저장소가 있으면 그것은 이 정리의 범위가 아니다.
  - 이 journal 도 실행 journal 이다. 아래 "트리 안의 파일" 의 reader 로 읽고, 읽지 못한 journal 도 같은 규칙으로 다룬다.
  - media 는 workspace 저장소에 있다. 검토 실행이 `~media_store:(Tool_blob_media_store.of_base_path ~base_path)` 로 workspace 저장소를 넘긴다(`workspace_metric_hooks.ml`, 11-06 확인).
  - `verifier-executions` 를 지우는 코드는 없다(11-06 확인, 운영 462개). 그래서 그 참조는 blob 을 계속 붙잡는다. 안전한 쪽이다.
- Librarian 작업 맥락: config 폴더의 `*.working-context.json` 을 범위에 넣는다. 참조는 같은 모듈의 디코더(`Keeper_librarian_context.read_committed_file`)로 꺼낸다. 풀리지 않는 바이트는 주인이 격리하고 원본 입력에서 다시 만드는 파생 바이트라 참조를 붙잡지 않는다. 읽기 실패는 스캔 오류다(#49294).
- Librarian 작업 맥락 색인: 범위에서 뺀다. 이유는 `Repairable_pointer` 다(#49294).
  - 색인이 가리키는 게시본은 범위 안 recall pin(`keepers/<k>/librarian-recall-current.json`)과 날짜별 recall 기록이 붙잡는다.
  - 게시본이 없으면 recall 이 확정된 작업 맥락에서 다시 쓴다(§3.4).
  - 색인을 주인으로 읽으면 퇴역한 맥락이 기록 보존 기간 뒤에도 남는다. 기존 시험 `confirmed empty context releases current pin after history retention` 이 이를 막는다.
- 트리 안의 파일(§3.6): 범위 안 트리 아래의 파일도 기록이 아닌 것은 이름 규칙으로 나눈다.
  - 잠금 파일은 읽지 않는다. 이름은 `Fs_compat.lock_suffix` 로 판정한다. private JSONL 잠금과 `File_lock_eio` 가 이 상수 하나를 쓴다(#49297).
  - `.DS_Store` 는 트리 안에서도 읽지 않는다. 이름은 scope 의 Finder 항목과 같은 상수를 쓴다.
  - 실행 journal 디렉터리는 §4.4 의 reader 로 읽는다. 그 안의 파일을 하나씩 기록으로 읽지 않고, 프레임 바이트를 문자열로 훑지 않는다.
  - journal 디렉터리는 `Execution_event_store` 가 내보내는 판별 함수 하나로 알아본다. 이 판별은 디렉터리로 내려가기 전에 한다. 그래서 `.writer.lock` 은 잠금 이름 규칙보다 먼저 journal 표지로 읽힌다. 저장소가 쓰는 이름은 다섯이다: `events.v1.wal`, `events.v1.wal.initializing`, `events.v1.commit`, `events.v1.commit.initializing`, `.writer.lock`. 지금 `.mli` 는 이 이름을 내보내지 않는다. 함수는 다섯을 모두 덮는다. 초기화 중 이름만 있는 디렉터리도 journal 이다. 하나라도 빠지면 그 디렉터리가 일반 트리로 내려가 읽히고, 같은 증상으로 스캔이 끝난다.
  - 읽지 못한 것 하나가 스캔 전체를 끝내지 않는다. 대상은 트리 안에서 기록으로 풀리지 않는 일반 파일과 reader 가 거부한 journal 이다. 옛 형식, 깨진 저장소, 초기화가 덜 된 저장소, 읽는 중에 사라진 저장소, 만드는 코드가 없는 잔여 파일이 섞여 있을 수 있다. 하나 때문에 스캔이 끝나면 지금 증상이 다른 파일로 옮겨 갈 뿐이다.
    - 스캔은 끝까지 돌고 기록을 쓴다. 그 파일은 기록의 `unreadable` 에 사유와 경로로 남고, 그 기록의 `deletable` 은 0 이다(§4.5).
    - 디렉터리를 나열하지 못하는 것은 그대로 스캔 오류다. 범위 안 트리의 하위 디렉터리도 같다(`EACCES` 등). 그 안에 무엇이 있는지 모르면 `unreadable` 에도 적을 수 없다.
    - 쓰는 중인 파일의 덜 쓰인 끝 줄은 "기록으로 풀지 못함" 으로 남는다. 그날 기록은 지울 수 없고, 다음 스캔은 다 쓰인 파일을 읽는다. 따로 사유를 둘지는 1층의 사유별 개수를 보고 정한다.
    - `unreadable` 이 비지 않는 한 2층은 지우지 않는다. 출구는 둘이다. 주인이 그 모양을 읽게 고치거나, 운영자가 그 파일을 지운다. 스캔이 읽지 못한 파일을 스스로 범위에서 빼지 않는다.
  - reader 가 들어오기 전 중간 단계: 실행 journal 디렉터리를 "reader 대기" 범위로 분류한다. 스캔은 그 디렉터리를 읽지 않고 끝까지 돌며, 기록의 `reader_pending` 에 디렉터리 수를 남기고 `deletable` 을 0 으로 두고 경고를 남긴다. `Excluded` 와 다른 분류다. `Excluded` 는 "읽지 않아도 안전하다"는 뜻이고, 이 분류는 "2층 전에 반드시 읽어야 한다"는 뜻이다. 둘을 합치면 2층이 켜질 때 journal 이 붙잡는 blob 을 지울 수 있다.
  - `keepers/<k>/` 와 `traces/<t>/` 의 직속 항목도 닫힌 분류에 넣는다. 주인 폴더 이름은 바뀌므로 "각 주인 폴더의 직속 항목" 한 단계를 더한다.
  - 공식 CLI 가 쓰는 자기 홈(`official-client-runtime` 안의 CLI 저장소, `github-cli`)은 새 제외 이유로 뺀다. CLI 가 쓰는 자기 설정과 상태라 MASC 기록이 아니다. `official-client-runtime` 의 outbox 영수증은 범위에 남는다.
  - `wire-capture/*/manual-*.sse.txt` 는 만드는 코드가 없다. 남아 있는 동안 `unreadable` 에 남는다. Upgrade notes 에 적고 운영자가 지운다.
  - 작업 맥락이 격리한 `<keeper>.working-context.json.invalid-<hash>` 는 주인이 다시 읽지 않는다. 지금 운영에 0개다. 생기면 `unclassified` 로 남아 지우기를 계속 막는다. 이름 규칙을 주인이 내보내고, 다시 읽지 않는 사본이라는 제외 이유로 분류한다.
  - 순서: 잠금 → Finder → `unreadable` 기록·journal "reader 대기"·주인 폴더 한 단계 분류·오프라인 명령 삭제(D7) → journal reader. 셋째가 들어가면 1층 스캔이 끝까지 돌아 기록이 쌓인다. 넷째가 들어가고 잔여 파일이 지워져야 `deletable` 이 0 을 벗어난다.
  - `live_references` 소비자 표(D7). 범위층 PR 은 이 표의 모든 줄을 같은 PR 에서 고친다.

    | 소비자 | 입력 | `Partial` 일 때 |
    |---|---|---|
    | 서버 스윕(`tool_blob_sweep.ml`) | `live_references` | 기록을 쓰고 `deletable` 은 0. 2층도 지우지 않는다 |
    | `tool-blob-maintenance` | `live_references` | 명령을 지운다(D7) |
    | `media-reading-maintenance` | `live_references` | 오류로 끝나고 아무것도 지우지 않는다 |
    | `vision-kept-maintenance` | `consumer_paths` | 해당 없음. 목록이 바뀌는 것만 §3.5 대로 센다 |
- Exact 기록: `lane-addons/exact-requests`, `host-results`, `evidence` 를 범위에 넣는다. Exact 호스트는 표시를 풀지 않는다. 하지만 지금 범위의 규칙은 "표시를 담은 기록은 살아 있는 동안 그 blob 을 붙잡는다"이고, `traces`·`wire-capture` 도 그 규칙으로 들어 있다. 같은 규칙을 따른다.
  - 비용: 스캔이 11GB 늘어 27GB 가 된다(§3.4). 1층 로그가 저장소마다 스캔 시간을 따로 남기게 이 층 PR 이 고친다. 시간이 문제면 먼저 `evidence`(6.4GB)를 줄인다. 이 폴더의 파일은 sha256 으로 이름 지은 불변 파일이라, 한 번 읽은 이름의 참조를 기억하면 다음 스캔은 새 파일만 읽는다. `exact-requests`·`host-results` 는 기록이 바뀌어서 이 방법이 맞지 않는다. 그쪽은 Librarian 요청처럼 owner 쪽 구조 목록으로 바꾼다. 범위에서 빼는 것으로 풀지 않는다(§6).
- 제외는 이유를 variant 로 적는다. 11-06 에 확인한 것:
  - `trajectories`: 도구 결과를 500바이트로 자른 사본이다(`trajectory.ml:107`). 잘린 표시가 남고, 표시를 푸는 코드가 없다. 범위에 넣으면 잘린 표시 때문에 스캔이 오류로 끝난다. 스캔이 잘린 표시를 건너뛰게 하지 않는다. 그러면 다른 저장소의 진짜 깨진 표시도 같이 덮인다. trajectory 가 참조를 붙잡아야 한다면, 쓸 때 표시를 자르지 않게 고친 뒤 범위에 넣는다.
  - `lane-addons/tool-request-owners-settled`: 보관 위치다. 543개 파일에 표시가 있지만 보관 본문을 읽는 코드가 없다(RFC-0498 §3.1).
  - `.DS_Store`: macOS Finder 가 만든다. 세 곳 모두에 생길 수 있다.
  - `tool_blobs`, `tool_blob_maintenance`: 이 정리가 다루는 저장소와 그 후보 기록이다.
- 이름에 붙는 접미사는 원래 이름의 분류를 따른다. `.lock`(`File_lock_eio.lock_file_path`), `.last-good`(`goal_measurement.ml:100` 등), SQLite 의 `-wal`·`-shm` 이다. `antigravity-<owner>.prepare.lock`(`runtime_antigravity_home.ml:581`)처럼 이름 가운데가 바뀌는 것은 규칙 하나로 적는다.
- 분류는 코드가 만드는 이름을 모두 적는다. 지금 운영에 없는 것도 적는다. 예: `lane-addons/fleet-delivery`(`lane_addon_runtime.ml`), `lane-addons/broadcasts`.
- 만드는 코드가 없는 운영 잔여 항목은 분류에 넣지 않는다. 그 항목이 남아 있으면 후보 기록의 `unclassified` 에 이름이 남고, 2층은 지우지 않는다. 이 층 PR 의 Upgrade notes 에 목록을 적는다. 운영자가 지우거나 `.masc` 밖으로 옮기면 그다음 스캔부터 지울 수 있다. 11-06 목록:
  - 폴더: `accountability`, `browser-downloads`, `gondolin-work`, `keeper-wake-payload`, `services`, `hardcut-46247-archive-20261027-131821`, `hardcut-46397-archive-20261028-021939`, `hardcut-aside-20261102`
  - 파일: `autonomy_stats.jsonl`, `board_posts.initialized.jsonl`(와 `.lock`), `tui-keeper-chat-recovery.json`(와 잠금 둘), `verify-after-restart.sh`, `verify-feedback-ratio.py`
  - `lane-addons/quiz-measure` 는 이름을 그대로 쓰는 코드가 없다. 이 층 PR 이 namespace 로 만드는지 확인한다.
- 끝 조건은 둘이다.
  - 운영 workspace 의 후보 기록에서 `unclassified` 가 빈다.
  - 새로 넣은 저장소마다 스캔이 참조를 찾은 파일 수를, 같은 시각에 따로 센 수와 맞춰 본다. 따로 셀 때는 두 모양(`[masc:blob sha256=<64자> bytes=` 표시와 `_blob` 객체)과 그 escape 된 모양을 모두 센다.
  - 따로 세는 명령을 이 층 PR 본문에 적어서 다시 돌릴 수 있게 한다.
  - §3.4 의 수는 크기를 보여 줄 뿐 기준값이 아니다. 저장소는 계속 바뀐다. 11-06 에 `tool-request-bodies` 를 다시 세니 모양에 따라 20~157개였고, 첫 측정의 184개는 다시 나오지 않았다.
  - 단위는 참조 개수가 아니라 참조를 하나라도 가진 파일 수다.
- `u` 줄(§5.2)은 보조 지표다. 0 이어도 범위가 닫혔다는 증거가 아니다. 스캔이 읽지 않는 곳에만 참조가 있는 blob 은 "참조됨"으로 보인 적이 없어서 `u` 에 나타나지 않는다. 범위를 고친 직후 첫 스캔에서는 처음 보이는 참조 때문에 `u` 가 0 이 아닐 수 있다.

저장소마다 자기 참조를 돌려주는 함수를 등록하는 방식(§6)으로 나중에 바꿀 수 있다. 범위 값이 저장소 목록이라, 그 값을 함수 목록으로 바꾸면 된다.

### 5.4 2층: 지우기

- 범위층의 두 끝 조건을 채운 뒤에 낸다.
- 이번 스캔과 앞 기록 모두 `unclassified` 가 비고 `unreadable`·`reader_pending` 이 0 일 때만 지운다. 앞 기록이 읽지 않은 곳을 두고 만든 후보는 그곳의 참조를 몰랐을 수 있다. 2층 PR 은 두 기록 중 하나라도 이 조건을 어기면 아무것도 지우지 않는 시험을 둔다.
- 운영자가 1층 수치를 보고 켠다. 코드에 켜는 기준값을 두지 않는다. 2층 PR 이 1층 수치를 근거로 든다. §5.2 의 "읽으려 했다"나 "아무 흔적이 없다"가 나오면, 그 producer 를 먼저 고치고 2층을 낸다.
- §4.3 의 `delete` 와 `h.deleting` 되돌리기를 넣는다.
- 오프라인 명령과 `Tool_blob_maintenance.mode` 는 범위층에서 이미 지웠다(D7). 2층은 서버 스윕에 지우기를 넣는다.
- 이미 쌓인 20GB 는 2층이 켜진 뒤 첫 스캔이 `deletable` 로 기록하고, 24시간 뒤 다음 스캔이 지운다.

## 6. 받아들이지 않은 것

- 배포 틈에 오프라인 명령을 돌리기. 코드는 거의 그대로다. 하지만 배포마다 16GB 넘게 읽는 동안 서버가 뜨지 않는다. 처음 지우려면 배포가 두 번 필요하다.
- 지금처럼 운영자가 가끔 서버를 내리고 돌리기. 08-12 이후 한 번도 돌지 않았다.
- 후보가 어떤 수보다 적으면 두 번째 스캔을 건너뛰기. 기준값이 근거 없이 정해진다. 스캔 비용은 1층에서 재고, 비용이 문제면 스캔 자체를 줄이는 방법을 따로 정한다.
- 지우기와 쓰기를 stdlib `Mutex` 로 줄 세우기. §4.3 에 이유를 적었다.
- 후보 표본을 `fetch` 해서 확인하기. 후보는 디스크에 있는 blob 이라 `fetch` 는 늘 성공한다. 재려는 위험(지운 뒤 다시 생기는 참조)을 재지 못한다. §5.2 가 그것을 바로 센다.
- 스캔이 못 읽는 다섯 곳(§3.4)을 일시 저장으로 보고 범위에서 빼기. Librarian 재시도와 완료 검토 재개가 blob 을 읽는다. 그 저장이 얼마나 오래 사는지 코드가 정하지 않는다.
- 저장소마다 자기 참조를 돌려주는 함수를 등록하고, GC 는 그 합집합만 쓰기. 방향은 맞다. 하지만 지금은 16곳을 모두 바꿔야 해서 2층이 오래 막힌다. 범위층의 닫힌 분류가 "등록하지 않은 저장소"를 실행 시점에 잡는다.
- 스캔이 잘린 표시를 건너뛰고 `trajectories` 를 범위에 넣기. 다른 저장소의 진짜 깨진 표시까지 덮는다(§5.3).
- 사람이 둔 파일을 받는 운영자 폴더를 `.masc` 아래에 새로 두기. `unclassified` 목록이 이미 측정을 이어 가게 한다. 새 폴더는 새 약속을 하나 더 만든다. 잔여 항목이 계속 생기는지 1층 경고 로그로 본 뒤 정한다.
- 실행 journal 을 Eio 없이 푸는 reader 를 agent_core 에 하나 더 두기. 같은 형식의 reader 가 둘이 되면 commit authority 검사와 프레임 규칙이 어긋날 수 있다.
- WAL 바이트에서 표시 문자열을 찾기. 프레임 안 JSON 은 escape 될 수 있고, commit authority 밖의 꼬리까지 읽는다.
- 실행 journal 을 범위에서 빼기. 표시나 `_blob` 객체를 가진 WAL 이 1,000개 넘게 있다(§3.6).
- 오래된 blob 만 지우기(나이 기준). 나이는 참조 여부를 말하지 않는다. §4.2 의 mtime 조건은 나이가 아니라 "앞 스캔 뒤에 누가 썼다"는 흔적이라, 오래됐다고 지우지 않고 새로 썼으면 남긴다.

## 7. 확인할 것

- 1층 배포 뒤 첫 두 스캔이 끝나는지, 실패하면 무엇 때문인지.
- 스캔 시간과 그동안의 메인 domain 지연. 1층 로그와 기존 지연 측정을 같은 시간대로 맞춰 본다.
- §5.2 의 수.
- 두 건드림 집합의 크기와, pass 동안의 서버 RSS(후보 집합을 메모리에 든다).
- `fetch` 마다 건드림을 CAS 로 더하는 비용. 스캔 중과 스캔 밖의 `fetch` 지연을 같이 잰다.
- `bin/` 이 `lib/` 를 거쳐 `Tool_blob_store` 에 쓰는 경로. 쓰기는 mtime 조건이 덮지만, 읽기만 하고 참조를 쓰는 서버 밖 경로가 있는지 같이 본다.
- 스캔 범위 대조: 참조(`Tool_output` marker, `Stored` media source)를 기록하는 producer 마다 쓰는 위치가 `durable_consumer_basenames` 나 Board 글 파일 안에 있는지. 1층 PR 본문에 표로 남긴다.
- `list_all_result` 가 sha256 이 아닌 이름(`.deleting`, 임시 파일)을 어떻게 다루는지.
- 실행 journal 읽기 비용. WAL 은 3.4GB 다(11-06). 끝난 journal 은 덧붙이기만 하므로 바뀌지 않는다. `(경로, scope_id, correlation_id, committed_offset, last_seq)` 가 같으면 앞 스캔에서 꺼낸 참조를 다시 쓰는 방법은 1층 수치를 본 뒤 정한다. authority 가 뒤로 가거나 identity 가 바뀌었으면 다시 읽는다. 저장소가 이미 이 둘을 오류로 나눈다(`Commit_authority_regressed`, `Commit_authority_identity_changed`).
- reader 를 메인 domain 밖에서 부를 때 codec pool 이 다른 domain 의 호출을 받는지.
- `unreadable` 의 사유별 개수와, 끝나지 않은 journal 의 개수.
- journal 하나를 읽는 시간의 분포. §4.4 의 상한값을 여기서 정한다.

## 8. 열린 질문

- 스캔의 Eio 루프를 어느 domain 에서 돌릴지(§4.4). domain 수는 #49274 와 같이 본다. 후보는 셋이다.
  - 스캔만 하는 domain 을 하나 더 둔다.
  - `Systhread_host` 의 host domain 에 reader fiber 를 붙인다. 그 domain 은 이미 자기 Eio 루프를 돈다(`systhread_host.ml` `serve`). domain 은 늘지 않는다. 그 루프는 모든 system thread 작업을 받아 넘기는 자리라서, 사건을 푸는 동안 다른 작업 접수가 늦어지는지 재야 한다. 그 루프는 `env` 를 버리므로 reader 가 쓸 경로를 넘기는 방법도 정해야 한다.
  - 이미 있는 다른 domain(Domain_pool)을 쓴다.

2층을 켤지는 1층 수치를 본 뒤 정한다. 2층이 `unlink` 대신 하루 동안 `h.deleting` 으로 두어 되돌릴 여지를 남길지는 2층 PR 에서 정한다. 디스크 사용률이 96% 라 기간이 비용이다.

## 9. 범위 밖

- 비전 보관 이미지와 media reading 저장소의 정리(§3.5).
- 디스크 96%. 이 RFC 의 1층과 상관없이 운영자가 공간을 확보해야 할 수 있다. 범위층이 오프라인 명령을 지우기 전에는(D7) 서버를 내린 틈에 그 명령을 한 번 돌리는 방법도 있지만, §3.3 의 위험을 재기 전이라 권하지 않는다.
