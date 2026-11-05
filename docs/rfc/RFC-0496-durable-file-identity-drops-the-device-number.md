---
rfc: "0496"
title: "재부팅을 넘는 파일 identity 는 device 번호를 담지 않는다 — Fs_compat.Durable_file_identity 는 path 와 inode 다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["46997"]
---

# RFC-0496 — 재부팅을 넘는 파일 identity 는 path 와 inode 다

## 0. 요약

- 10-31, 11-02, 11-03 에 Curator 가 멈췄다. system log 의 `Curator request belongs to another physical workspace` 는 10-31 374건, 11-02 3480건, 11-03 1210건이다. 10-29·10-30·11-01·11-04·11-05 는 0건이다.
- 이 Mac 은 재부팅하면 APFS volume 의 `st_dev` 가 16777234 와 16777231 사이에서 바뀐다. Data volume UUID 와 inode 는 그대로다.
- Curator 는 BasePath 의 `(path, st_dev, st_ino)` 를 durable 기록에 적는다. 재부팅 뒤에는 지금 관측한 `st_dev` 가 기록과 달라서, 남은 기록 전체를 "다른 workspace 것" 으로 거절한다.
- 제안: 재부팅을 넘는 기록에 쓰는 파일 identity 타입 `Fs_compat.Durable_file_identity` 를 둔다. 담는 것은 `path` 와 `inode` 뿐이다. 프로세스 안에서 짧게 비교하는 `(st_dev, st_ino)` 검사는 그대로 둔다.
- 첫 층은 Curator 다. 나머지 durable 기록은 층마다 읽는 곳을 확인한 뒤 같은 타입으로 옮긴다.

## 1. 지금

### 1.1 무엇이 바뀌나

- 이 Mac 은 10-31 11:26 과 11-02 11:01(KST)에 재부팅했다(`last reboot`). 지금 BasePath 의 `st_dev` 는 16777234 다.
- Curator 기록에 적힌 device 를 기록 시각별로 세면 이렇다(11-06, 정리된 기록 1088개 중 앞 64KB 에서 device 를 찾은 544개).
  - 10-26 ~ 10-31, 11-02 ~ 11-06: 16777234 (389개)
  - 11-01 02:07 ~ 11-02 10:07: 16777231 (155개)
- 그래서 오류는 두 번 났다.
  - 10-31: 재부팅 전 기록(16777234)을 16777231 로 관측했다.
  - 11-02 ~ 11-03: 그 사이 기록(16777231)을 다시 16777234 로 관측했다.
- 11-04 부터 0건인 것은 16777231 로 적힌 기록이 진행 중 폴더에서 빠졌기 때문이다. 지금 진행 중 기록 10개는 모두 16777234 다. 다음 재부팅에서 값이 바뀌면 다시 멈춘다.
- `st_dev` 는 커널이 마운트 순서에 따라 매기는 번호다. 같은 volume 이라도 재부팅마다 같은 값을 받는다는 보장이 없다.
- APFS 와 ext4 의 inode 번호는 파일시스템에 저장된다. 재부팅해도 바뀌지 않는다.

### 1.2 Curator 가 비교하는 곳

- `Workspace_memory_execution_capture.observe_workspace` 가 `{path; device; inode}` 를 만든다(`lib/workspace_memory/workspace_memory_execution_capture.ml:22-27`).
- capture 기록과 Curator summary 는 이 셋을 JSON 에 적는다(`workspace_json`, 같은 파일 57행).
- 재시작 뒤 두 곳이 기록의 값과 지금 관측한 값을 비교한다.
  - `restore_record`(같은 파일 261-262행): 다르면 그 요청을 복원하지 않는다.
  - `recoverable_successors`(같은 파일 376행): 기록 하나라도 다르면 전체가 `Error` 다. 이 함수는 Curator 를 돌릴 때마다 진행 중인 기록 전체를 본다(`lib/server/server_workspace_memory_addon.ml:506`). 그래서 한 건이 아니라 Curator 전체가 멈춘다.

### 1.3 라이브 기록(11-06 측정)

Curator scope(`workspace-curator`)의 lane add-on 기록이다. 모두 `"device"` 를 담는다.

| 폴더 | 파일 | 크기 |
|---|---|---|
| `tool-request-owners/<scope>` | 10 | 8.5 MB |
| `tool-request-bodies/<scope>` | 13 | 27.9 MB |
| `tool-request-owners-settled/<scope>` | 1088 | 3.6 GB |

`recoverable_successors` 가 읽는 것은 앞의 둘이다(`Lane_addon_tool_request_owner.discover` 는 `tool-request-owners` 만 본다).

## 2. 제안

### 2.1 타입

```ocaml
(* lib/fs_compat *)
module Durable_file_identity : sig
  type t = private { path : string; inode : int }
  val of_stat : path:string -> Unix.stats -> t
  val equal : t -> t -> bool
  val to_json : t -> Yojson.Safe.t      (* {"path":…,"inode":…} *)
  val of_json : Yojson.Safe.t -> (t, string) result  (* 두 field 정확히, 상대 경로 거절 *)
end
```

- 이름에 "durable" 을 넣어, 재부팅을 넘는 기록에 쓰는 타입임을 드러낸다.
- 프로세스 안의 TOCTOU 검사는 이 타입을 쓰지 않는다. 열기 전과 연 뒤를 비교하는 곳은 지금처럼 `(st_dev, st_ino)` 를 본다. 그 사이에는 재부팅이 없다.

### 2.2 inode 재사용

- 약점: 폴더를 지우고 같은 경로에 다시 만들면, 새 폴더가 옛 inode 번호를 받을 수 있다. 그러면 identity 가 같아 보인다.
- Curator 의 경우 기록은 그 BasePath 의 `.masc` 아래에 있다. BasePath 를 지우면 기록도 같이 지워진다. 옛 기록이 새 폴더를 만나는 길이 없다.
- 다른 기록도 옮기기 전에 같은 질문을 한다. 기록이 가리키는 대상과 기록이 같이 지워지는가. 아니면 그 층에서 다른 방법을 정한다.

### 2.3 범위

| 층 | 대상 | 확인한 것 |
|---|---|---|
| L1 | Curator capture·summary(`workspace_memory_execution_capture.ml`), stored ledger(`workspace_memory_revision.ml` 의 `stored_ledger.workspace`) | 이 문서 §1.2·§1.3 |
| 다음 층 | librarian durable request(`keeper_librarian_durable_request.ml:28`), admission capture(`keeper_librarian_admission_capture.ml:45`) | 조사 에이전트 보고. 층을 열 때 재확인 |
| 다음 층 | owned job(`keeper_owned_job_backend.ml:291`), event queue quarantine intent(`keeper_runtime/keeper_event_queue_quarantine.ml:105`) | 라이브 기록 0개(11-06) |
| 다음 층 | capability recovery(`fs_compat/capability_recovery_reconciler.ml:242`·`:1347`), endpoint job registry·output seal, tool-call continuity(`keeper_tool_call_index.ml:141`·`:567`), build provenance sidecar | 조사 에이전트 보고. 층을 열 때 재확인 |

- 브라우저 add-on 기록(`browser_addon_socket.ml`, `browser_addon_downloads.ml`, `browser_addon_live_bidi.ml`)은 브라우저 작업과 같이 본다.
- 옮기지 않는 것:
  - 클라이언트가 들고 있다가 돌려주는 cursor(`task_history_page.ml`, `keeper_chat_history_page.ml`). 재부팅 뒤 cursor 가 틀리면 처음부터 다시 읽는다.
  - 재부팅 뒤 스스로 다시 만들어지는 것(tool-call index 재검사, lane add-on host delivery, owner lease 파일 이름).
- 층마다 producer → store → consumer 를 따라가 재부팅 뒤 실제로 비교하는지 확인한다. 비교하지 않으면 옮기지 않는다.

### 2.4 hard cut

- 옛 기록을 읽는 호환 코드는 두지 않는다. Curator capture schema 와 summary schema 의 버전을 올린다.
- 옛 기록은 새 reader 가 거절한다. `recoverable_successors` 는 하나라도 거절하면 전체가 멈추므로 Fresh state 가 필요하다.
- L1 Fresh state: 서버를 멈추고 `.masc/lane-addons` 아래 Curator scope 폴더 셋(`tool-request-owners`, `tool-request-bodies`, `tool-request-owners-settled` 의 `<sha256("workspace-curator")>`)을 지운 뒤 설치한다.
- 지워도 Curator ledger 의 사실은 남는다. 아직 분류하지 않은 사실은 다음 Curator 턴이 다시 잡는다.

## 3. 완료 조건

- L1 배포 뒤 `st_dev` 가 바뀌는 재부팅을 한 번 지나고, system log 의 `belongs to another physical workspace` 가 0건이다.
- 재부팅 전후 `st_dev` 를 같이 적는다. `st_dev` 가 안 바뀐 재부팅은 이 조건을 확인하지 못한다.

## 4. 고르지 않은 것

- B. `.masc` 안에 처음 한 번 만든 무작위 workspace id 파일. 읽기 실패 경로가 하나 늘고, 그 파일의 수명이 `.masc` 와 같아서 A 와 막는 것이 같다.
- C. durable identity 비교를 지우고 path 만 본다. 같은 경로의 폴더를 바꿔치기하면 못 잡는다. A 는 inode 로 이것을 잡는다.
- D. volume UUID(`getattrlist`). C stub 이 필요하고 macOS 전용이다. Linux 는 따로 짜야 한다.

## 5. 논의

- masc-productor-owner 와 11-06 에 정했다. A 를 채택하고 타입 이름에 TOCTOU 경계를 드러내기로 했다. Curator 를 먼저 hard cut 하고, 재부팅 뒤 0건 관측을 완료 조건으로 둔다.
