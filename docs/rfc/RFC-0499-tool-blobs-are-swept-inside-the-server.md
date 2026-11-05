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

정리 코드 `Tool_blob_maintenance.run` 은 있다. 두 번 스캔 규칙도 있다. 앞 스캔의 후보이면서 이번 스캔에서도 참조가 없는 blob 만 지운다. 하지만 이 코드는 BasePath lease 를 잡은 오프라인 명령에서만 돈다. 운영 서버는 lease 를 늘 쥐고 있다. 이 명령을 부르는 스크립트도 없다. 그래서 08-12 이후 한 번도 돌지 않았다.

이 RFC 는 같은 규칙을 서버 안에서 돌린다. 서버가 쓰는 중에도 지우면 안 되는 blob 을 지우지 않도록 두 가지를 더한다.

- 스캔 사이에 이 프로세스가 쓰거나 읽은 주소는 지우지 않는다.
- 지울 때는 파일을 먼저 다른 이름으로 옮긴 뒤 건드림 기록을 다시 본다. 그사이 누가 건드렸으면 되돌린다.

1층은 지우지 않는다. 지울 후보와 "지웠다면 깨졌을 참조"를 센다. 2층은 운영자가 1층 수치를 본 뒤 지우기를 켠다.

## 1. 결정

- D1. 정리는 서버 안에서 돈다. 서버의 maintenance 루프가 앞 스캔이 시작된 뒤 24시간이 지나면 다음 스캔을 연다. 앞 스캔 시작 시각은 후보 기록 파일에 있어서, 서버를 다시 켜도 주기가 처음부터 다시 시작하지 않는다.
- D2. 두 번 스캔 규칙은 그대로다. 지울 수 있는 것은 "앞 스캔의 후보 ∩ 이번 스캔의 후보"다.
- D3. 그 집합에서 "건드린 주소"를 뺀다. 건드린 주소는 둘이다. 이 프로세스가 앞 스캔 시작 뒤(프로세스가 그 뒤에 떴으면 프로세스 시작 뒤) `Tool_blob_store` 의 쓰기·읽기 함수로 다룬 주소, 그리고 파일 mtime 이 앞 스캔 시작 뒤인 주소다(§4.2).
- D4. 지우기는 `written_addresses` 에서 주소를 빼고, 파일을 다른 이름으로 옮긴 뒤, 건드린 주소인지와 옮긴 파일이 확인한 그 파일인지(inode·mtime) 다시 본다. 하나라도 어긋나면 되돌리고, 아니면 지운다. 잠금은 쓰지 않는다(§4.3).
- D5. 스캔과 지우기는 Eio 메인 domain 밖에서 돈다. 스캔이 실패하면 지금처럼 후보를 기록하지 않고, 아무것도 지우지 않는다.
- D6. 1층은 지우지 않는다. 후보 수, 지울 수 있는 수와 크기, 지웠다면 깨졌을 참조 수, 스캔 시간, 실패 종류를 로그와 후보 기록에 남긴다(§5).
- D7. 2층은 지우기를 켜고, 오프라인 명령 `tool-blob-maintenance` 를 지운다. 정리하는 곳은 서버 하나만 남는다.

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

### 3.4 다른 정리 명령

`vision-kept-maintenance` 와 `media-reading-maintenance` 도 lease 를 잡는 오프라인 명령이고, 부르는 곳이 없다. 이 둘은 `tool_blobs` 가 아닌 다른 저장소를 지운다. 비전 보관 이미지(`config/keepers/<keeper>.vision`)는 지금 약 700MB 다. 이 RFC 의 범위가 아니다. #39331, #46721 이 다룬다.

## 4. 설계

### 4.1 언제 도나

서버의 maintenance 루프(`server_bootstrap_maintenance.ml`, 24시간 JSONL 보존 pass 가 있는 곳)가 tick 마다 후보 기록의 `scan_started_at` 을 본다. 24시간이 지났으면 정리 pass 를 연다. 후보 기록이 없으면 첫 tick 에 연다.

정리 pass 는 한 번에 하나만 돈다. 앞 pass 가 아직 돌면 tick 은 아무것도 하지 않는다.

### 4.2 건드린 주소

`Tool_blob_store` 가 프로세스 전역 값 하나를 둔다.

```
type touched = { current : Touch_map.t; previous : Touch_map.t }   (* sha256 -> { put : bool; read : bool } *)
val touched : touched Atomic.t
```

- `current`: 이번 스캔 시작 뒤 건드린 주소
- `previous`: 앞 스캔 시작부터 이번 스캔 시작까지 건드린 주소

스캔을 열 때 `{ current = empty; previous = old.current }` 로 한 번에 바꾼다(CAS). 두 집합을 따로 두고 옮긴 뒤 비우면, 그 사이에 기록된 건드림을 잃는다. 건드림 기록도 같은 값에 CAS 로 더한다. 프로세스가 앞 스캔 뒤에 떴으면 `previous` 는 비어 있고 `current` 가 프로세스 시작부터 채운 집합이다.

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
  touched += (h, Put)    (atomic)      touched += (h, Read)   (atomic)
  if written_addresses has h: return   read file h
  write file h (temp + rename)
  written_addresses += h

delete h:
  written_addresses -= h
  if h in touched: skip
  st1 = lstat h;  if st1.mtime >= previous_scan_started_at: skip
  rename h -> h.deleting
  st2 = lstat h.deleting
  if h in touched or st2.ino <> st1.ino or st2.mtime <> st1.mtime:
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

`touched` 는 §4.2 의 `Atomic` 값이다. OCaml 5 `Atomic` 은 순차 일관이라, 한 thread 의 기록이 다른 thread 의 확인에 순서대로 보인다.

서버가 `rename` 과 `unlink` 사이에 죽으면 `h.deleting` 이 남는다. 서버는 시작할 때, Keeper 와 요청을 받기 전에 남은 `h.deleting` 을 모두 `h` 로 되돌린다. 정리 pass 가 아니라 시작 단계에서 하는 이유는, 그 전에 오는 `fetch` 가 `Ok None` 을 받지 않게 하려는 것이다. 되돌린 주소는 다음 스캔에서 같은 규칙으로 다시 판정된다. blob 목록(`list_all_result`)은 `.deleting` 이름을 blob 으로 세지 않는다.

### 4.4 메인 domain 밖에서

스캔은 16GB 넘게 읽고 푼다. 메인 domain 에서 돌면 그동안 서버가 멈춘다. 정리 pass 전체를 system thread 에서 돌린다. 지금 `tool_blob_maintenance.ml` 은 Eio·Domain_pool·Mutex 를 부르지 않고 `Fs_compat` 의 blocking 함수와 Unix 호출만 쓴다. 그래서 그대로 system thread 에서 부를 수 있다. 구현 층에서 다시 확인한다.

### 4.5 후보 기록

후보 기록 파일은 새 이름 `<base>/.masc/tool_blob_maintenance/candidates-v2` 에 새 모양으로 쓴다. 옛 파일은 읽지 않는다. 옛 모양을 읽거나 옮기는 코드는 두지 않는다. 운영 workspace 에는 이 폴더가 없다. 다른 workspace 에 옛 파일이 있으면 지우고 설치한다(1층 changelog 의 Upgrade notes).

후보가 수백만 개일 수 있다. 그래서 JSON 배열 하나로 쓰지 않는다. 첫 줄은 머리, 그다음은 한 줄에 sha256 하나다.

```
{"schema_version":2,"scan_started_at":1793900000.0,"candidates":<n>,"deletable":<m>}
c <sha256>
d <sha256>
```

`c` 는 후보, `d` 는 D3 의 집합(후보이면서 지울 수 있는 것)이다. 머리의 개수와 줄 수가 다르면 그 파일을 읽지 않고 오류로 끝낸다. 1층은 `d` 를 지우지 않고 기록만 한다. 다음 스캔이 §5.2 의 수를 세는 데 쓴다.

## 5. 층

### 5.1 1층: 세기만

- §4.1~§4.5 를 넣는다. 지우는 줄만 없다.
- pass 가 끝나면 로그 한 줄을 남긴다: 스캔 시간, 살아 있는 참조 수, blob 수, 후보 수, `deletable` 수와 크기, §5.2 의 수.
- 실패하면 오류 종류(`Durable_source_read_failed`, `Durable_source_parse_failed` 등)와 경로를 남긴다. 서버가 쓰는 중이라 "읽는 도중 사라진 파일"이나 "덜 쓰인 끝 줄"로 멈추는 일이 생길 수 있다. 1층에서 얼마나 자주 생기는지 본다. 자주 생기면 그 규칙을 2층 전에 따로 정한다.

### 5.2 지웠다면 깨졌을 참조

앞 스캔의 `d` 중 이번 스캔에서 참조되는 주소를 센다. 2층이었다면 이 주소들은 앞 스캔 끝에 지워졌다. 그 뒤에 무슨 일이 있었는지로 셋으로 나눈다.

- 다시 썼다: 이 프로세스의 `touched_previous`·`touched_current` 에 `Put` 이 있거나, 파일 mtime 이 앞 스캔 시작 뒤다. 2층이었어도 `put` 이 파일을 다시 써서 괜찮았다.
- 읽으려 했다: `Read` 만 있다. 2층이었다면 `fetch` 가 `Ok None` 을 돌려줘서 그 기능이 눈에 보이게 실패했다(Board 첨부면 `Missing_artifact`).
- 아무 흔적이 없다: 2층이었다면 파일 없이 참조만 남았다. §3.3 의 "blob 을 쓰지 않고 참조를 다시 쓰는 길"이 실제로 있다는 뜻이다.

서버를 다시 켜면 건드림 집합이 비므로, 앞 프로세스가 읽은 경우는 "아무 흔적이 없다"로 셈한다. 위험 쪽으로 더 센다.

이 셈의 한계:

- 참조를 기록하지 않고 메모리에서만 쓰고 버린 경우는 이번 스캔에 나타나지 않는다. 그래서 `d` 중 `Read` 가 기록된 주소는 참조가 있든 없든 따로 센다. 2층이었다면 그 `fetch` 가 모두 `Ok None` 을 받았다.
- 1층은 앞 스캔 끝의 `d` 로 센다. 2층은 지우는 순간에 건드림과 mtime 을 다시 본다. 그래서 2층이 실제로 지우는 수는 `d` 보다 적거나 같다.

셋째 묶음은 sha256 과, 그 주소를 가리키는 기록 경로를 로그에 남긴다. 그 경로로 어느 producer 인지 찾는다. 내용은 남기지 않는다.

### 5.3 2층: 지우기

- 운영자가 1층 수치를 보고 켠다. 코드에 켜는 기준값을 두지 않는다. 2층 PR 이 1층 수치를 근거로 든다. §5.2 의 "읽으려 했다"나 "아무 흔적이 없다"가 나오면, 그 producer 를 먼저 고치고 2층을 낸다.
- §4.3 의 `delete` 와 `h.deleting` 되돌리기를 넣는다.
- 오프라인 명령 `tool-blob-maintenance` 와 그 lease 경로를 지운다. `Tool_blob_maintenance.mode` 도 지운다.
- 이미 쌓인 20GB 는 2층이 켜진 뒤 첫 스캔이 `deletable` 로 기록하고, 24시간 뒤 다음 스캔이 지운다.

## 6. 받아들이지 않은 것

- 배포 틈에 오프라인 명령을 돌리기. 코드는 거의 그대로다. 하지만 배포마다 16GB 넘게 읽는 동안 서버가 뜨지 않는다. 처음 지우려면 배포가 두 번 필요하다.
- 지금처럼 운영자가 가끔 서버를 내리고 돌리기. 08-12 이후 한 번도 돌지 않았다.
- 후보가 어떤 수보다 적으면 두 번째 스캔을 건너뛰기. 기준값이 근거 없이 정해진다. 스캔 비용은 1층에서 재고, 비용이 문제면 스캔 자체를 줄이는 방법을 따로 정한다.
- 지우기와 쓰기를 stdlib `Mutex` 로 줄 세우기. §4.3 에 이유를 적었다.
- 후보 표본을 `fetch` 해서 확인하기. 후보는 디스크에 있는 blob 이라 `fetch` 는 늘 성공한다. 재려는 위험(지운 뒤 다시 생기는 참조)을 재지 못한다. §5.2 가 그것을 바로 센다.
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

## 8. 열린 질문

없음. 2층을 켤지는 1층 수치를 본 뒤 정한다.

## 9. 범위 밖

- 비전 보관 이미지와 media reading 저장소의 정리(§3.4).
- 디스크 96%. 이 RFC 의 1층과 상관없이 운영자가 공간을 확보해야 할 수 있다. 오프라인 명령을 서버를 내린 틈에 한 번 돌리는 방법도 있지만, §3.3 의 위험을 재기 전이라 권하지 않는다.
