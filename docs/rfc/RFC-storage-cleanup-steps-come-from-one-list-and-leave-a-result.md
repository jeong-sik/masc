---
rfc: "storage-cleanup-steps-come-from-one-list-and-leave-a-result"
title: "저장 공간 정리는 한 목록의 단계가 돌고, 시도마다 결과를 남긴다"
status: Draft
created: 2026-11-11
updated: 2026-11-11
author: claude
related: ["remote-keeper-workspace-entries-are-swept-on-their-endpoint", "idle-keeper-worktrees-are-swept-where-they-live", "keeper-build-output-returns-to-a-disposable-volume", "0122"]
---

# RFC: 저장 공간 정리는 한 목록의 단계가 돌고, 시도마다 결과를 남긴다

- Status: Draft. 좌표는 `origin/main` `0b365126d3b3` 기준 `path:line` 이다.
- 운영자 요청(2026-11-11): "수동으로 worktree, orphan 등을 찾아 청소하는 작업(masc 로 인해)을 더이상 하지 않을 수 있도록 … 시스템 자체를 개선", "가시성 있게 tui 등등에 표시도 되고 동작함이 확인되어야".
- 운영자 조건(같은 날): 휴리스틱과 하드코딩이 아니라, 코드가 판정할 것과 판단이 필요한 것의 경계에서 고친다.

## 1. 문제

### 1.1 지금 있는 정리 장치

정리 장치가 없는 것은 아니다. 다섯 개가 따로 돈다.

| 장치 | 치우는 것 | 언제 | 결과가 남는 곳 |
|---|---|---|---|
| `Server_keeper_build_maintenance` | Apple 게스트의 `_build`, remote_ssh Keeper 의 작업 폴더 | 1시간마다. 기동 뒤 1시간을 먼저 기다린다 | 서버 로그 줄 |
| `Server_sandbox_volume_gc_report` | 떠난 Keeper 의 볼륨(판정만, 삭제는 운영자가 TUI 에서) | 기동 60초 뒤, 그다음 6시간마다 | TUI Tools 화면의 볼륨 읽기(`V`) |
| 게스트 첫 연결 때 `_build` 삭제 | Apple 게스트의 `_build` | 서버 프로세스마다 볼륨당 한 번 | 서버 로그 줄 |
| 날짜별 JSONL 정리 | `.masc` 의 날짜별 기록 | 기동 때와 24시간마다 | 서버 로그 줄 |
| `Server_tool_blob_sweep` | 지울 수 있는 blob 을 판정해 기록만 한다. 지우지 않는다 | 하루마다 | 관측 기록, 서버 로그 줄 |

### 1.2 잰 값

2026-11-11 15시 KST 에 `<base-path>/.masc/logs/masc-start-*.log` 와 실행 중인 게스트에서 쟀다. 시각은 모두 KST 다.

**`_build` 정리는 이틀 넘게 한 번도 성공하지 못했다.**

- 마지막 성공 줄은 11-09 00:41:37(sangsu)이다.
- 11-09 10:00 부터 11-11 14:40 까지 성공 줄은 0개다. 같은 기간 경고는 `command failed` 127줄(Keeper 8명), `dune unavailable` 39줄, `transport failed` 30줄이다.
- 게스트 대부분은 11-09 10:21~12:25 에 다시 만들어졌다(`container list` 의 STARTED). 첫 실패는 그 직후 주기(12:25)다.
- 경고에는 종료 코드와 stderr 가 없다(`lib/keeper/keeper_turn_sandbox_runtime_maintenance.ml:190`, 이슈 #50266). 그래서 로그만으로는 원인을 알 수 없다.
- 추정 원인: 게스트 네 곳(polisher, you-never-change, glossary-maniac, rondo)에서 Keeper uid 로 본 `/proc/1/cwd` 의 소유자가 root 다. PID 1 은 권한을 내린 exec-shim agent 다. payload 의 `process_paths` 는 `FileNotFoundError` 만 잡는다(`config/scripts/keeper-build-cleanup.py:35-58`). `PermissionError` 는 잡지 않으니 payload 가 예외로 끝난다. 이 경로는 후보 `_build` 가 하나라도 있을 때만 탄다. 확정은 종료 코드와 stderr 를 남긴 뒤에 한다.

**주기가 재시작마다 처음부터 다시 기다린다.**

- 루프는 간격만큼 잔 뒤에 첫 주기를 돈다(`lib/server/server_keeper_build_maintenance.ml:191`).
- 11-09 18:09 부터 11-11 14:39 까지 44시간 반 동안 주기는 29번 돌았다. 11-10 하루는 24번 중 13번이다.
- 서버는 11-09 에 15번, 11-10 에 8번 다시 떴다(로그 파일 이름의 UTC 날짜로 셌다).

**돌았는지, 무엇을 했는지 구분되지 않는다.**

- 주기 줄 하나: `owners=29 builds=16 workspaces=13`.
- `_build` 단계 16건 중 줄을 남기는 것은 실패·거절 5~6건뿐이다. 나머지는 줄이 없다. Keeper 가 바빠서 넘어간 것(`:169`), 지운 것이 없는 것(`:114`), 게스트가 꺼져 있던 것이 모두 같은 침묵이다.
- 작업 폴더 단계는 Keeper 마다 줄을 남긴다. 11-09 18:00 뒤로 362줄, 지운 항목 1,261개, 실패 20개다.

**단계가 없는 곳.**

- 돌려주지 않은 블록: 게스트에서 파일을 지워도 볼륨 이미지가 호스트에서 차지한 자리가 줄지 않는다.
  - 2026-09-27 부터 서버는 게스트를 띄우기 전에 helper 컨테이너로 ext4 discard 기본값을 켰다(#39283). 켜진 볼륨은 지운 자리가 바로 돌아온다(이슈 #44655 의 10-21 측정).
  - 10-29 에 #46713 이 helper 실행을 멈췄다. helper 컨테이너 이름에 workspace 가 없어서, 같은 이름의 남의 helper 를 지울 수 있었기 때문이다. 그 뒤 helper 함수(`reclaim_apple_work_volume`, `lib/keeper/keeper_sandbox_microvm_work_volume.ml:273`)는 시험만 부른다. 제품 코드에 `fstrim` 은 없다.
  - 11-11 16시에 작업 볼륨 이미지 20개의 superblock 을 읽었다. discard 기본값이 있는 것은 4개고, 모두 10-29 11:58 까지 만든 볼륨이다. 없는 16개는 모두 10-29 12:00 뒤에 만들었다. 호스트에서 차지한 자리는 있는 쪽이 61 GiB, 없는 쪽이 95 GiB 다.
  - 같은 날 게스트 셋을 손으로 trim 해서 38 GiB 를 돌려받았다(you-never-change 54→26, github-pr-checker 16→8.1, sangsu 31→28 GiB). 셋 다 discard 기본값이 없는 볼륨이다.
- 게스트 작업 볼륨 안의 남은 worktree 와 사본: e-masc-the-leader 45 GiB, sangsu 28 GiB, you-never-change 26 GiB(11-11). 치우는 단계가 없다. `RFC-idle-keeper-worktrees-are-swept-where-they-live` 는 Draft 이고 구현되지 않았다.
- remote_ssh endpoint 의 임시 폴더: 명령은 endpoint 의 `TMPDIR`(없으면 `/tmp`)를 같이 쓰고(`lib/exec_shim/exec_shim.ml:165`) 아무도 치우지 않는다. 리뷰 컨테이너 `/tmp` 는 83 GiB 였고 하루에 26 GiB 씩 자랐다(이슈 #51266). 게스트와 Docker 의 `/tmp` 는 tmpfs 라 디스크를 쓰지 않는다.
- 디스크 여유: 서버는 재고 있지만(`lib/keeper_runtime/keeper_disk_pressure.mli`) 웹 대시보드에만 나온다. TUI 에는 없다. 11-11 15시에 126 GiB 가 남았다(3,722 GiB 중 97% 사용).

### 1.3 뿌리

저장 공간을 만드는 길은 여럿이다. 정리는 길마다 따로 붙었고, 결과를 남기는 방식도 제각각이다.

- 단계의 목록이 없다. 빠진 곳이 있어도 코드가 알려 주지 않는다.
- 결과가 값으로 남지 않는다. 단계가 이틀 동안 실패해도 화면에 나오지 않는다.

그래서 디스크가 차면 사람이 손으로 찾아 지운다.

## 2. 결정

### 2.1 지워도 되는 근거는 계약에서 온다

정리 코드는 항목마다 세 가지를 답한다. 누구 것인가, 지워도 잃는 것이 없는가, 지금 쓰는 중인가.
이름 모양(`wt-pr*`), 크기, "오래돼 보인다"로는 답하지 않는다. 답은 아래 근거에서만 온다.

| 근거 | 뜻 | 코드가 확인하는 것 |
|---|---|---|
| 파생물 | 도구가 원본에서 다시 만든다고 약속한 것 | `dune-project` 옆의 `_build`, 제품이 만든 빌드 링크. 원격에 모든 커밋이 있는 git 사본 |
| 돌려주지 않은 블록 | 파일 시스템이 이미 비운 자리 | 없음. trim 은 데이터를 건드리지 않는다 |
| 임시 | FHS 3.0 3.18 `/tmp`: 프로그램은 다음 실행 때 파일이 남아 있다고 가정하면 안 된다 | 항목의 소유 uid, 다른 사용자가 쓸 수 있는 권한 |
| 운영자 정책 | 위 근거가 없는 남은 것을 얼마나 둘지 운영자가 정한 기간 | 보존 기간 설정. 처음 값은 운영자가 2026-11-08 에 고른 48시간 |
| 근거 없음 | 커밋 안 된 커밋, stash, 주인을 모르는 볼륨 | 지우지 않는다. 화면에 보여 준다 |

모든 단계에 공통인 것:

- 주인은 만든 쪽의 기록으로 확인한다. 볼륨 이름은 만든 함수로 다시 만들어 비교한다(`Keeper_volume_gc.masc_keeper_volume_of_name`). 앞부분 글자가 같다고 주인으로 보지 않는다.
- 쓰는 중인지는 `/proc` 의 cwd·exe·열린 파일, 잠금, Owner 의 상태로 본다. 읽지 못하면 남긴다.
- 보존 기간은 "지워도 되는가"의 근거가 아니다. 근거가 있는 것을 방금 쓴 사람에게서 뺏지 않으려고 두는 여유다. 근거가 없는 남은 것에는 운영자가 정한 정책 값이다.

판단이 필요한 것은 코드가 추측하지 않는다. 화면에 주인과 크기를 보여 주고, 운영자가 정한다. 떠난 Keeper 의 볼륨을 TUI 에서 두 번 눌러 지우는 지금 방식이 이 모양이다.

### 2.2 단계는 한 목록에 있다

정리 단계를 닫힌 합타입 하나로 둔다. `Dated_jsonl.Store` 가 날짜별 기록의 보존 기간을 한 목록에서 받는 것과 같은 방식이다.

```ocaml
(* lib/keeper/keeper_cleanup_step.mli *)
type t =
  | Guest_builds       (* Apple 게스트의 _build *)
  | Remote_workspace   (* remote_ssh Keeper 의 작업 폴더 *)
[@@deriving enumerate]

type admission =
  | Idle_owner     (* Keeper 가 쉴 때만. 턴과 같은 잠금을 쓴다 *)
  | Beside_turns   (* 턴 옆에서. payload 가 쓰는 중인 것을 남긴다 *)

val admission : t -> admission
val applies_to : t -> Keeper_meta_contract.keeper_meta -> bool
```

- 단계마다 대상(`applies_to`), 승인 방식(`admission`), 켜는 설정, 결과 모양을 빠짐없는 `match` 로 답한다. 새 단계는 생성자를 더하고, 빠진 답은 컴파일러가 잡는다.
- 한 Keeper 에 맞는 단계가 여럿이면 목록 순서대로 하나씩 돈다. 지우는 단계가 먼저, trim 이 마지막이다.
- 대상은 TOML 을 반영한 meta 의 profile 과 backend 로 고른다. 지금은 profile 만 봐서 Docker Keeper 와 Apple 이 아닌 microVM 도 `_build` 단계로 가고, 그 단계가 말없이 넘긴다.

이 RFC 의 뒤 층이 더하는 단계:

| 단계 | 대상 | 근거 | 승인 |
|---|---|---|---|
| `Guest_trim` | 떠 있는 Apple 게스트의 작업·빌드 볼륨 | 돌려주지 않은 블록 | 턴 옆에서 |
| `Remote_temp` | remote_ssh endpoint 의 임시 폴더에서 그 endpoint 사용자가 가진 항목 | 임시 + 운영자 정책 | 턴 옆에서 |
| `Guest_workspace` | Apple 게스트의 Keeper 작업 폴더 | 파생물 + 운영자 정책 | 6절에서 묻는다 |

`Guest_trim` 은 떠 있는 게스트 안에서 root 로 `fstrim` 을 돌린다.

- helper 컨테이너를 만들지 않는다. #46713 이 멈춘 이유(이름만으로 helper 의 주인을 알 수 없다)에 걸리지 않는다.
- discard 기본값은 켠 뒤에 지운 자리만 돌려준다. 이미 쌓인 자리는 어느 쪽을 고르든 trim 이 한 번은 필요하다.
- 멈춰 있는 helper 를 다시 켤지 지울지는 여기서 정하지 않는다. 볼륨의 주인 식별(Goal `goal-microvm-multi-vmm-01a18182`, task-2863)과 `Guest_trim` 이 돈 뒤의 측정을 보고 정한다.

### 2.3 시도마다 결과를 남긴다

단계가 Keeper 한 명에게 한 번 돈 것이 시도다. 시도는 아래 넷 중 하나로 끝난다.

```ocaml
(* lib/keeper/keeper_cleanup_pass.mli *)
type outcome =
  | Reclaimed of reclaim   (* payload 가 끝까지 돌았다. 지운 것이 0이어도 여기다 *)
  | Deferred of string     (* Keeper 가 바빠 넘겼다. Owner 가 말한 이유 *)
  | Not_running            (* 붙을 게스트가 없다. 아무것도 보내지 않았다 *)
  | Failed of string       (* 그 밖. 단계가 말한 이유, 종료 코드와 stderr 포함 *)
```

- 서버는 Keeper·단계마다 가장 최근 시도와, 가장 최근에 `Reclaimed` 로 끝난 시각을 값으로 들고 있다. 주기마다 주기 요약(시작 시각, 훑은 Keeper 수, 예약한 수)도 둔다.
- 이 값은 서버 메모리에만 있다. 서버를 다시 띄우면 비어서 시작하고 첫 주기가 다시 채운다. 기록의 원본은 지금처럼 서버 로그와 audit 이다. 새 저장소를 만들지 않는다.
- 값은 `GET /api/v1/dashboard/tools` 의 `keeper_cleanup` 칸으로 나간다. 볼륨 GC 보고(`sandbox_volume_gc_report`)와 같은 길이다. 서버와 TUI 가 같은 모듈로 쓰고 읽는다.
- 로그 줄은 그대로 둔다. `_build` 단계도 작업 폴더 단계처럼 지운 것이 0일 때 줄을 남긴다.
- `Failed` 의 이유는 사람이 읽는 문장이다. 어떤 코드도 그 문장으로 갈래를 나누지 않는다.

### 2.4 첫 주기는 기동 직후에 돈다

- 루프는 maintenance pulse 한 번(처음 값 60초)을 기다린 뒤 첫 주기를 돌고, 그다음부터 간격마다 돈다. 볼륨 GC 보고와 같다(`lib/server/server_sandbox_volume_gc_report.ml:47`).
- 치르는 값: 서버를 자주 다시 띄우면 주기도 그만큼 더 돈다. 단계는 여러 번 돌아도 같은 결과다. 단계마다 쓰는 중인 것과 보존 기간 안의 것을 남긴다.
- 마지막 주기 시각을 디스크에 적어 두고 이어 가는 방법은 고르지 않았다. 새 저장소가 생기고, 얻는 것은 재시작 직후의 주기 한 번을 아끼는 것뿐이다.

### 2.5 TUI 에 저장 공간 읽기를 둔다

Tools 화면에 읽기 하나를 더한다. 세 가지를 보여 준다.

- 호스트 디스크: 남은 공간과 전체. `runtime_resolution.disk_observation` 을 그대로 쓴다. 서버 쪽 변경은 없다.
- 마지막 정리 주기: 언제 돌았고 Keeper 몇 명을 훑었는지. 서버가 뜬 뒤 아직 안 돌았으면 그렇게 말한다.
- Keeper 별 행: 단계, 마지막 시도의 결과와 숫자, 마지막으로 끝까지 돈 때. 실패가 먼저 나온다.

시험은 보낸 요청, 읽은 값, 행을 고르는 판정만 본다. 문구와 배치는 고정하지 않는다.

### 2.6 `_build` 정리 payload 를 고친다

이 RFC 와 따로 올린다. 고장은 지금 나 있고, 위 층들과 파일이 겹치지 않는다.

- `process_paths` 는 작업 폴더 payload 와 같은 규칙을 쓴다. 우리 uid 의 프로세스인데 `/proc` 링크가 root 것이면 넘어간다. 커널이 권한을 내린 프로그램을 그렇게 만든다. Keeper 작업(셸, git, 빌드)은 읽을 수 있는 프로세스로 돈다.
- 그 밖에 읽지 못하는 프로세스가 있으면 지금처럼 아무것도 지우지 않는다. 다만 예외로 죽지 않고 이유를 `skip` 으로 보고한다.
- 서버의 실패 경고에 종료 상태와 가린 stderr 를 붙인다(#50266).

## 3. 하지 않는 것

- **이름으로 주인이나 낡음을 추측해서 지우기.** constitution 의 `string_matching` 이 막는 방식이다. 이슈 #44655 도 같은 이유로 `wt-*` 번호 모양을 보고 지우는 길을 닫았다.
- **PR 상태 판정.** 앞의 두 RFC 가 뺀 이유가 그대로다. 커밋을 지키는 규칙으로 작업을 잃지 않는다.
- **Keeper 지침, 보관 표지, 정리를 시키는 메시지.** Keeper 가 무엇을 남길지 정하게 만드는 장치는 넣지 않는다.
- **디스크 여유로 Keeper 의 턴을 막는 게이트.** `Keeper_disk_pressure` 는 관측만 한다. 그 결정을 뒤집지 않는다.
- **떠난 Keeper 의 작업 볼륨 자동 삭제.** 볼륨 이름에 workspace 와 Keeper 의 생성 식별자가 없다. 이름만 보고 지우면 다른 workspace 의 같은 이름 Keeper 를 지울 수 있다. `docs/research/2026-10-26-keeper-volume-lifecycle.md` 의 다음 스택(자원 식별자, 삭제 의무 기록)이 먼저다. 그때까지는 판정을 보여 주고 운영자가 누른다.
- **제품이 만들지 않은 것.** dune 캐시, Docker 빌드 캐시, 코딩 세션의 임시 폴더, 저장소의 `.worktrees`. 이슈 #40747 의 `/private/tmp/masc-*` 도 제품 코드가 만든 것이 아니다(저장소 전체에서 그 이름을 만드는 코드는 없다).
- **`.masc` 안의 호스트 저장소 보존.** `official-clients`, tool blob, vision 보관 이미지는 주인이 서버다. 근거가 다르니 따로 다룬다. 2.2 의 목록은 Keeper 샌드박스의 단계다.

## 4. 검증

- 단계 목록: profile 과 backend 의 모든 조합에서 `applies_to` 가 고르는 단계. 설정을 끄면 그 단계만 빠진다.
- 결과 값: 시도가 끝나는 길마다 맞는 `outcome` 이 남는다. 바쁜 Owner 는 `Deferred`, 꺼진 게스트는 `Not_running`, payload 거절과 실패는 `Failed` 다. 지운 것이 0인 시도도 `Reclaimed` 로 남는다.
- JSON: 쓴 값을 그대로 읽는다. 모르는 칸, 모르는 결과 이름, 빠진 칸은 거절한다.
- TUI: Tools 를 읽을 때 `keeper_cleanup` 을 읽는다. 실패가 있는 Keeper 가 먼저 온다.
- payload(Python): 권한을 내린 같은 uid 프로세스는 넘어간다. 다른 사용자의 읽지 못하는 프로세스가 있으면 아무것도 지우지 않고 이유를 보고한다.
- 실제 환경: 배포 뒤 첫 주기(기동 약 60초 뒤)에 TUI 읽기에 Keeper 29명의 결과가 나오는지 본다. `_build` 단계의 `Reclaimed` 가 다시 나오는지, 실패가 남으면 이유 문장이 무엇인지 적는다.

## 5. 단계

스택 A(보이게 한다):

- A0: 이 문서.
- A1: 단계 목록, 시도 결과 값, `keeper_cleanup` 칸, 기동 직후 첫 주기.
- A2: TUI 저장 공간 읽기.

따로(2.6): `_build` 정리 payload 와 실패 경고.

스택 B(더 치운다). A 위에 올린다.

- B1: 볼륨 이미지가 호스트에서 차지한 바이트를 재고, `Guest_trim` 을 더한다. trim 전후의 차이가 돌려받은 양이다.
- B2: `Remote_temp`. 같은 endpoint 사용자를 쓰는 Keeper 가 여럿이면 주기마다 한 번만 돈다.
- B3: `Guest_workspace`. 6절의 답을 받은 뒤.
- B4: `/health` 의 운영자 요약에 정리 실패를 올린다. 모든 화면의 footer 가 그 요약을 보여 준다.

## 6. 운영자께 묻는 것

**게스트(microVM) Keeper 의 작업 폴더에 remote_ssh 와 같은 규칙을 쓸까.**

- 추천: 같은 규칙을 쓴다. 2026-11-08 에 운영자가 remote_ssh 작업 폴더에 정한 것이다. 48시간 동안 아무도 안 건드렸고, 쓰는 프로세스가 없고, 원격에 없는 커밋과 stash 가 없으면 지운다. remote_ssh 에는 리뷰어와 개발 Keeper(wkbl-*, ocaml-agent-ic)가 같이 있고, 이 규칙이 11-09 18:00 뒤로 1,261개를 지웠다.
- 게스트에 맞춰 하나를 더한다. 게스트에는 본 저장소 폴더 안에 놓인 작업 폴더가 많다(예: `<keeper>/masc/wt-pr48070-fix`). 본 저장소는 늘 쓰는 중이라 지금 규칙은 그 안을 보지 않는다. payload 가 `git worktree list` 로 등록된 연결 worktree 를 찾아 하나씩 따로 본다. 연결 worktree 를 지워도 브랜치와 커밋은 본 저장소에 남는다. HEAD 가 어느 ref 에도 없는 커밋이면 남긴다.
- 치르는 값: 48시간 넘게 아무 파일도 안 건드린 미커밋 변경은 사라진다.
- 다른 길: 깨끗하고 원격에 다 있는 사본(파생물)만 지운다. 잃는 것은 없다. 대신 리뷰 메모가 섞인 사본과 압축을 푼 폴더는 영영 남고, 손 정리가 다시 필요해진다.
