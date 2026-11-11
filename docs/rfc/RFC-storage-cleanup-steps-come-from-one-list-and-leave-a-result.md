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
- 11-11 17시에 떠 있는 게스트 14곳을 다시 쟀다. 13곳에서 읽지 못하는 프로세스는 PID 1 하나였다(`masc-exec-shim --serve`, uid 502, 세션 1, `/proc/1/cwd` 의 소유자 root). 11-02 에 만든 한 곳(msx-retro-mania)은 PID 1 이 `tail` 이고 읽힌다. 잴 때 게스트마다 다른 프로세스는 없었다.
- agent 는 root 에서 Keeper uid 로 내려오면서 스스로 dumpable 을 끈다(`lib/exec_shim/agent_stub.c:118`). 연결마다 exec 없이 relay 를 포크하고(`lib/exec_shim/shim_agent.ml:442`), relay 는 그 표시를 물려받는다. payload 는 relay 아래에서 돈다. 그래서 payload 가 도는 동안에는 PID 1 과 자기 relay, 적어도 둘이 읽히지 않는다.

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
이름 모양(`wt-pr*`)이나 크기로는 답하지 않는다. 낡음은 운영자가 정한 기간으로만 쓴다. 답은 아래 근거에서만 온다.

| 근거 | 뜻 | 코드가 확인하는 것 |
|---|---|---|
| 파생물 | 도구가 원본에서 다시 만든다고 약속한 것 | `dune-project` 옆의 `_build`, 제품이 만든 빌드 링크. 원격에 모든 커밋이 있는 git 사본 |
| 돌려주지 않은 블록 | 파일 시스템이 이미 비운 자리 | 없음. trim 은 데이터를 건드리지 않는다 |
| 임시 | FHS 3.0 3.18 `/tmp`: 프로그램은 다음 실행 때 파일이 남아 있다고 가정하면 안 된다 | 운영자가 그 endpoint 의 임시 폴더를 MASC 가 치운다고 선언했는가. 선언이 없으면 지우지 않고 크기만 보여 준다 |
| 운영자 정책 | 파생물도 임시도 아닌 Keeper 작업 폴더 항목을 얼마나 둘지 운영자가 정한 기간 | 보존 기간 설정(처음 값은 운영자가 2026-11-08 에 고른 48시간). 그 기간에 항목 안의 무엇도 바뀌지 않았는가 |
| 정책으로도 지우지 않는 것 | 원격에 없는 커밋, stash, 주인을 모르는 볼륨 | 지우지 않는다. 화면에 보여 준다 |

임시 근거는 "지워도 잃는 것이 없다"만 답한다. "누구 것인가"는 답하지 못한다.

- endpoint 계정은 Keeper 여럿이 같이 쓰고, 그 계정으로 도는 다른 프로그램도 같은 `/tmp` 에 쓴다. 소유 uid 가 같다는 것은 MASC 가 만들었다는 기록이 아니다.
- 명령마다 `TMPDIR` 을 MASC 가 만든 폴더로 돌리는 방법은 고르지 않았다. 이슈 #51266 의 큰 항목은 Keeper 가 명령에 직접 적은 경로(`/tmp/r50843` 14 GiB, `/tmp/masc-src`, `/tmp/w47491`)라 `TMPDIR` 을 따르지 않는다.
- 그래서 임시 폴더의 주인은 운영자의 선언으로 정한다(6절). 소유 uid 는 남의 것을 건드리지 않으려고 보는 조건이다. 주인의 증거로 쓰지 않는다.

운영자 정책 행은 잃는 것이 있다.

- 그 기간에 아무도 안 건드린 미커밋 변경(고친 파일, 추적 안 된 파일)은 항목과 같이 사라진다. 운영자가 2026-11-08 에 알고 고른 값이다.
- "안 건드렸다"는 항목 전체를 훑어서 본다. 모든 파일과 폴더의 mtime 과 ctime 가운데 가장 새 것이 기준이다(`config/scripts/keeper-remote-workspace-cleanup.py:63` 의 `tree_facts`). 폴더 하나의 mtime 만 보지 않는다. ctime 은 프로그램이 되돌려 적을 수 없어서, 옛 mtime 을 그대로 풀어놓는 git 과 압축 풀기도 방금 한 일로 잡힌다.

모든 단계에 공통인 것:

- 주인은 만든 쪽의 기록으로 확인한다. 볼륨 이름은 만든 함수로 다시 만들어 비교한다(`Keeper_volume_gc.masc_keeper_volume_of_name`). 앞부분 글자가 같다고 주인으로 보지 않는다. 만든 쪽의 기록이 없는 곳에서는 운영자의 선언이 주인을 정한다.
- 쓰는 중인지는 `/proc` 의 cwd·exe·열린 파일, 잠금, Owner 의 상태로 본다. 읽지 못하면 남긴다. 넘어가는 것은 MASC 가 스스로 읽지 못하게 만든 프로세스뿐이다(2.6).
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

val applies_to :
  t ->
  sandbox_profile:Keeper_types_profile.sandbox_profile ->
  microvm_backend:Keeper_microvm_backend.t option ->
  bool

(* lib/keeper/keeper_cleanup_attempt.mli *)
val enabled : Keeper_cleanup_step.t -> bool

val select :
  config:Workspace.config ->
  enabled:(Keeper_cleanup_step.t -> bool) ->
  keeper_name:string ->
  (Keeper_cleanup_step.t list, Keeper_cleanup_pass.exclusion) result

val run :
  config:Workspace.config ->
  keeper_name:string ->
  Keeper_cleanup_step.t ->
  Keeper_cleanup_pass.attempt
```

- 모듈은 셋이다. `Keeper_cleanup_step` 은 목록과 대상·승인 방식이다. `Keeper_cleanup_attempt` 는 고르기와 실행이다(승인, payload, 결과로 옮기기, 예외는 `Failed`, 취소만 다시 던진다). `Keeper_cleanup_pass` 는 서버가 들고 있는 값이다. 서버 루프(`Server_keeper_build_maintenance`)에는 예약, 주기 시간, 값 보관, 로그만 남는다.
- 단계마다 대상(`applies_to`), 승인 방식(`admission`), 켜는 설정(`enabled`), 실행(`run`), 결과 모양을 빠짐없는 `match` 로 답한다. 새 단계는 생성자를 더하고, 빠진 답은 컴파일러가 잡는다.
- 켜는 설정은 서버가 주기를 시작할 때 한 번 읽어 `~enabled` 로 넘긴다. 주기 요약과 고르기가 같은 값을 본다.
- 한 Keeper 에 맞는 단계가 여럿이면 목록 순서(`all`, 생성자를 적은 순서)대로 하나씩 돈다. 지우는 단계가 먼저, trim 이 마지막이다. 지금 두 단계는 한 Keeper 에 같이 걸리지 않는다. B1 이 `Guest_trim` 을 더할 때 "같은 샌드박스에서 trim 이 마지막"을 시험으로 고정한다.
- 단계는 앞 단계를 기다리지 않는다. 앞 단계가 넘겨지거나 실패하면 그 결과만 남고 다음 단계가 돈다.
- 대상은 TOML 을 반영한 meta 의 profile 과 backend 로 고른다. 지금은 profile 만 봐서 Docker Keeper 와 Apple 이 아닌 microVM 도 `_build` 단계로 가고, 그 단계가 말없이 넘긴다.

이 RFC 의 뒤 층이 더하는 단계:

| 단계 | 대상 | 근거 | 승인 |
|---|---|---|---|
| `Guest_trim` | 떠 있는 Apple 게스트의 작업·빌드 볼륨 | 돌려주지 않은 블록 | 턴 옆에서 |
| `Remote_temp` | 운영자가 선언한 remote_ssh endpoint 의 임시 폴더에서 그 계정이 가진 항목 | 임시 + 운영자 선언 | 턴 옆에서 |
| `Guest_workspace` | Apple 게스트의 Keeper 작업 폴더 | 파생물 + 운영자 정책 | 6절에서 묻는다 |

`Guest_trim` 은 떠 있는 게스트 안에서 root 로 `fstrim` 을 돌린다.

- helper 컨테이너를 만들지 않는다. #46713 이 멈춘 이유(이름만으로 helper 의 주인을 알 수 없다)에 걸리지 않는다.
- discard 기본값은 켠 뒤에 지운 자리만 돌려준다. 이미 쌓인 자리는 어느 쪽을 고르든 trim 이 한 번은 필요하다.
- 멈춰 있는 helper 를 다시 켤지 지울지는 여기서 정하지 않는다. 볼륨의 주인 식별(Goal `goal-microvm-multi-vmm-01a18182`, task-2863)과 `Guest_trim` 이 돈 뒤의 측정을 보고 정한다.
- 한 번에 게스트 하나씩 돈다. trim 은 호스트 디스크를 크게 쓴다(1.2 에서 이미지 하나가 28 GiB 를 돌려줬다). 급한 일이 아니니 나란히 돌리지 않는다.

### 2.3 시도마다 결과를 남긴다

단계가 Keeper 한 명에게 한 번 돈 것이 시도다. 시도는 아래 넷 중 하나로 끝난다.

```ocaml
(* lib/keeper/keeper_cleanup_pass.mli *)
type 'report outcome =
  | Reclaimed of 'report   (* payload 가 끝까지 돌았다. 지운 것이 0이어도, 못 지운 항목이 있어도 여기다 *)
  | Deferred of string     (* Keeper 가 바빠 넘겼다. Owner 가 말한 이유 *)
  | Not_running            (* 붙을 게스트가 없다. 아무것도 보내지 않았다 *)
  | Failed of string       (* 그 밖. 단계가 말한 이유, 종료 코드와 stderr 포함 *)

type attempt =
  | Guest_builds of builds outcome         (* { cleaned; failed } *)
  | Remote_workspace of workspace outcome  (* { removed; skipped; failed; freed_kib; available_kib } *)
```

- 보고는 단계마다 모양이 다르다. 그래서 단계별 닫힌 합으로 둔다. 새 단계가 보고 모양을 빼먹으면 컴파일러가 잡는다.
- 서버는 Keeper·단계마다 가장 최근 시도와, 가장 최근에 `Reclaimed` 로 끝난 시각을 값으로 들고 있다.
- 주기 요약은 훑은 Owner 를 하나도 빠짐없이 한 번씩 센다. meta 없음, 선언을 못 읽음(Keeper 이름과 이유), 맞는 단계 없음, 꺼짐, 예약함, 앞 시도가 안 끝나 넘김(Keeper 이름)이다. 단계마다 켜졌는지와 고른 Keeper 수도 싣는다. 선언을 못 읽는 Keeper 는 행이 없으니 요약에 이름과 이유로 나온다.
- 쓰는 쪽은 여럿이다. 루프와, Keeper 마다 포크한 fiber 가 같이 쓴다. 값 전체를 불변으로 두고 compare-and-set 으로 바꾼다. 같은 파일의 `running` 이 쓰는 방식이다.
- 주기마다 그 주기가 고르지 않은 Keeper·단계의 행을 치운다. 떠난 Keeper, profile 이 바뀐 Keeper, 꺼진 단계의 행이 남지 않는다.
- 이 값은 서버 메모리에만 있다. 서버를 다시 띄우면 비어서 시작하고 첫 주기가 다시 채운다. 기록의 원본은 서버 로그다. `_build` 단계는 audit 도 남긴다(`keeper_microvm_build_maintenance`). 작업 폴더 단계는 로그뿐이다. 새 저장소를 만들지 않는다.
- 값은 `GET /api/v1/dashboard/tools` 의 `keeper_cleanup` 칸으로 나간다. 볼륨 GC 보고(`sandbox_volume_gc_report`)와 같은 길이다. 서버와 TUI 가 같은 모듈로 쓰고 읽는다.
- 읽는 쪽은 부분마다 따로 읽는다. 서버와 TUI 는 다른 빌드일 수 있고, 스택 B 가 단계를 더한다.
  - `keeper_cleanup` 을 통째로 못 읽으면 TUI 는 그 칸에만 읽지 못한 이유를 보여 준다. 도구 목록과 사용량은 그대로 나온다.
  - 주기 요약과 행은 하나씩 읽는다. 이 TUI 가 모르는 단계나 칸이 든 행은 읽지 못한 행으로 세고 이유를 보여 준다. 읽은 행은 그대로 나온다.
  - 모르는 값을 아는 값으로 바꿔 읽지 않는다.
- 로그 줄은 그대로 둔다. `_build` 단계도 작업 폴더 단계처럼 지운 것이 0일 때 줄을 남긴다.
- `Failed` 의 이유는 사람이 읽는 문장이다. 어떤 코드도 그 문장으로 갈래를 나누지 않는다.

### 2.4 첫 주기는 기동 직후에 돈다

- 루프는 maintenance pulse 한 번(처음 값 60초)을 기다린 뒤 첫 주기를 돌고, 그다음부터 간격마다 돈다. 볼륨 GC 보고와 같다(`lib/server/server_sandbox_volume_gc_report.ml:47`).
- 이 변경은 층을 따로 둔다(A1b). 동작이 바뀌는 것은 이것뿐이라, 되돌릴 일이 생기면 이것만 되돌린다.
- 볼륨 GC 보고도 같은 pulse 에 첫 보고를 낸다. 둘을 어긋나게 두지 않는다. 같은 것을 잡지 않기 때문이다. 볼륨 보고는 호스트에서 helper 컨테이너 하나로 판정한다(`Keeper_volume_gc_host.run`). 정리는 게스트의 agent 소켓과 SSH endpoint 로 간다(11-02 에 띄운 게스트 하나는 agent 가 없어 `container exec` 를 쓴다). 정리가 게스트 여럿에 한꺼번에 요청하는 것은 지금도 한 시간마다 하는 일이다. 배포 뒤 첫 주기가 걸린 시간을 로그 시각으로 재서 A1b 에 적는다.
- 치르는 값: 서버를 자주 다시 띄우면 주기도 그만큼 더 돈다. 단계는 여러 번 돌아도 같은 결과다. 단계마다 쓰는 중인 것과 보존 기간 안의 것을 남긴다.
- 마지막 주기 시각을 디스크에 적어 두고 이어 가는 방법은 고르지 않았다. 새 저장소가 생기고, 얻는 것은 재시작 직후의 주기 한 번을 아끼는 것뿐이다.

### 2.5 TUI 에 저장 공간 읽기를 둔다

Tools 화면에 읽기 하나를 더한다. 세 가지를 보여 준다.

- 호스트 디스크: 남은 공간과 전체. `runtime_resolution.disk_observation` 을 그대로 쓴다. 서버 쪽 변경은 없다.
- 마지막 정리 주기: 언제 돌았고 Keeper 몇 명을 훑었는지. 서버가 뜬 뒤 아직 안 돌았으면 그렇게 말한다.
- Keeper 별 행: 단계, 마지막 시도의 결과와 숫자, 마지막으로 끝까지 돈 때.
- 먼저 나오는 것: 선언을 못 읽은 Keeper, `Failed` 인 행, 끝까지 돌았지만 못 지운 항목이 있는 행(보고의 `failed` 가 0보다 크다).
- "마지막으로 끝까지 돈 때"는 서버가 뜬 뒤의 값이다. 서버는 하루에 8~15번 다시 뜬다. 그래서 TUI 는 서버가 뜬 지 얼마나 됐는지(`/health` 의 uptime)를 같이 보여 준다. 이틀째 실패가 "뜬 뒤 실패"로 줄어 보이지 않게 하려는 것이다.

시험은 보낸 요청, 읽은 값, 행을 고르는 판정만 본다. 문구와 배치는 고정하지 않는다.

### 2.6 `_build` 정리 payload 를 고친다

이 RFC 와 따로 올린다. 고장은 지금 나 있고, 위 층들과 파일이 겹치지 않는다.

- 읽지 못하는 프로세스가 있으면 지금처럼 아무것도 지우지 않는다. 넘어가는 것은 MASC 가 스스로 읽지 못하게 만든 프로세스뿐이다. 게스트의 첫 프로세스인 agent 와, agent 가 연결마다 포크한 relay 다(1.2).
- 둘은 이름이나 uid 로 고르지 않는다. 세션으로 고른다. agent 와 relay 는 PID 1 의 세션에 있다. payload 는 늘 자기 세션에서 돈다(`lib/exec_shim/exec_shim.ml:732` 의 `setsid`). 프로세스는 남의 세션으로 옮겨 갈 수 없다. 그래서 "PID 1 과 같은 세션에 있는 읽지 못하는 프로세스"가 정확히 agent 와 relay 다.
- PID 1 하나만 넘어가는 규칙은 쓸 수 없다. payload 자신이 relay 아래에서 돌아서, 도는 동안에는 relay 가 늘 하나 더 읽히지 않는다.
- 다른 세션에 읽지 못하는 프로세스가 있으면 아무것도 지우지 않는다. 다만 예외로 죽지 않고 이유를 `skip` 으로 보고한다. Keeper 가 스스로 dumpable 을 끄는 프로그램(예: `ssh-agent`)을 띄워 두면 그 게스트의 `_build` 정리는 멈추고, 결과 행에 그 이유가 나온다.
- 서버의 실패 경고에 종료 상태와 가린 stderr 를 붙인다(#50266).

## 3. 하지 않는 것

- **이름으로 주인이나 낡음을 추측해서 지우기.** constitution 의 `string_matching` 이 막는 방식이다. 이슈 #44655 도 같은 이유로 `wt-*` 번호 모양을 보고 지우는 길을 닫았다.
- **PR 상태 판정.** 앞의 두 RFC 가 뺀 이유가 그대로다. 커밋을 지키는 규칙으로 작업을 잃지 않는다.
- **Keeper 지침, 보관 표지, 정리를 시키는 메시지.** Keeper 가 무엇을 남길지 정하게 만드는 장치는 넣지 않는다.
- **디스크 여유로 Keeper 의 턴을 막는 게이트.** `Keeper_disk_pressure` 는 관측만 한다. 그 결정을 뒤집지 않는다.
- **떠난 Keeper 의 작업 볼륨 자동 삭제.** 볼륨 이름에 workspace 와 Keeper 의 생성 식별자가 없다. 이름만 보고 지우면 다른 workspace 의 같은 이름 Keeper 를 지울 수 있다. `docs/research/2026-10-26-keeper-volume-lifecycle.md` 의 다음 스택(자원 식별자, 삭제 의무 기록)이 먼저다. 그때까지는 판정을 보여 주고 운영자가 누른다.
- **제품이 만들지 않은 것.** dune 캐시, Docker 빌드 캐시, 코딩 세션의 임시 폴더, 저장소의 `.worktrees`. 이슈 #40747 의 `/private/tmp/masc-*` 도 제품 코드가 만든 것이 아니다(저장소 전체에서 그 이름을 만드는 코드는 없다).
- **선언이 없는 endpoint 의 임시 폴더, 남의 계정 항목.** 운영자가 선언하지 않은 endpoint 의 `/tmp` 는 크기만 보여 준다. 선언한 endpoint 에서도 그 계정 소유가 아닌 항목은 건드리지 않는다. 같은 계정을 다른 workspace 가 같이 쓰는지는 선언하는 운영자가 안다.
- **`.masc` 안의 호스트 저장소 보존.** `official-clients`, tool blob, vision 보관 이미지는 주인이 서버다. 근거가 다르니 따로 다룬다. 2.2 의 목록은 Keeper 샌드박스의 단계다.

## 4. 검증

- 단계 목록: profile 과 backend 의 모든 조합에서 `applies_to` 가 고르는 단계. 설정을 끄면 그 단계만 빠진다.
- 결과 값: 시도가 끝나는 길마다 맞는 `outcome` 이 남는다. 바쁜 Owner 는 `Deferred`, 꺼진 게스트는 `Not_running`, payload 거절과 실패는 `Failed` 다. 지운 것이 0인 시도도 `Reclaimed` 로 남는다.
- 주기 요약: 훑은 Owner 가 한 번씩만 세어진다. 고르지 않은 Keeper·단계의 행은 사라진다.
- JSON: A1 은 쓰는 값의 모양을 고정한다. A2 는 쓴 값을 그대로 읽고, 모르는 칸·모르는 이름·빠진 칸이 든 부분을 읽지 못한 것으로 남긴다.
- TUI: `keeper_cleanup` 이 깨져 있어도 도구 목록은 읽힌다. 모르는 단계의 행이 있어도 아는 행은 읽힌다. 먼저 나오는 행을 고르는 판정.
- payload(Python): PID 1 의 세션에 있는 읽지 못하는 프로세스는 넘어간다. 다른 세션에 읽지 못하는 프로세스가 있으면 아무것도 지우지 않고 이유를 보고한다.
- 실제 환경: 배포 뒤 첫 주기(기동 약 60초 뒤)에 TUI 읽기에 Keeper 29명의 결과가 나오는지 본다. `_build` 단계의 `Reclaimed` 가 다시 나오는지, 실패가 남으면 이유 문장이 무엇인지 적는다.

## 5. 단계

스택 A(보이게 한다):

- A0: 이 문서.
- A1: 단계 목록, 시도 결과 값, 주기 요약, `keeper_cleanup` 칸. 정리 동작은 그대로다. 값과 로그만 는다.
- A1b: 기동 뒤 첫 주기(2.4).
- A2: TUI 저장 공간 읽기. `keeper_cleanup` 을 부분마다 읽는 것까지다.

따로(2.6): `_build` 정리 payload 와 실패 경고.

스택 B(더 치운다). A 위에 올린다.

- 새로 지우는 단계(`Remote_temp`, `Guest_workspace`)는 꺼진 채로 들어간다. 먼저 보고만 하는 실행으로 지울 목록과 크기를 결과에 남긴다. A2 화면으로 확인한 뒤 운영자가 켠다. 작업 폴더 payload 에는 보고만 하는 실행이 이미 있다(`--apply` 를 빼고 부른다).
- B1: 볼륨 이미지가 호스트에서 차지한 바이트를 재고, `Guest_trim` 을 더한다. trim 전후의 차이가 돌려받은 양이다. 한 번에 게스트 하나씩 돈다.
- B2: `Remote_temp`. 운영자가 선언한 endpoint 에서만 돈다(6절). 같은 endpoint 계정을 쓰는 Keeper 가 여럿이면 주기마다 한 번만 돈다.
- B3: `Guest_workspace`. 6절의 답을 받은 뒤.
- B4: `/health` 의 운영자 요약에 정리 실패를 올린다. 모든 화면의 footer 가 그 요약을 보여 준다. 올리는 조건은 시간으로 정하지 않는다. 결과 값은 서버가 뜰 때마다 비어서 "N시간째 실패"를 셀 수 없다. "가장 최근 시도가 `Failed`"와 "서버가 뜬 뒤 한 번도 끝까지 못 돎"으로 정한다.

## 6. 운영자께 묻는 것

**게스트(microVM) Keeper 의 작업 폴더에 remote_ssh 와 같은 규칙을 쓸까.**

- 추천: 같은 규칙을 쓴다. 2026-11-08 에 운영자가 remote_ssh 작업 폴더에 정한 것이다. 48시간 동안 아무도 안 건드렸고, 쓰는 프로세스가 없고, 원격에 없는 커밋과 stash 가 없으면 지운다. remote_ssh 에는 리뷰어와 개발 Keeper(wkbl-*, ocaml-agent-ic)가 같이 있고, 이 규칙이 11-09 18:00 뒤로 1,261개를 지웠다.
- 게스트에 맞춰 하나를 더한다. 게스트에는 본 저장소 폴더 안에 놓인 작업 폴더가 많다(예: `<keeper>/masc/wt-pr48070-fix`). 본 저장소는 늘 쓰는 중이라 지금 규칙은 그 안을 보지 않는다. payload 가 `git worktree list` 로 등록된 연결 worktree 를 찾아 하나씩 따로 본다. 연결 worktree 를 지워도 브랜치와 커밋은 본 저장소에 남는다. HEAD 가 어느 ref 에도 없는 커밋이면 남긴다.
- 치르는 값: 48시간 넘게 아무 파일도 안 건드린 미커밋 변경은 사라진다.
- 다른 길: 깨끗하고 원격에 다 있는 사본(파생물)만 지운다. 잃는 것은 없다. 대신 리뷰 메모가 섞인 사본과 압축을 푼 폴더는 영영 남고, 손 정리가 다시 필요해진다.

**remote_ssh endpoint 의 임시 폴더를 MASC 가 치워도 되는가. endpoint 마다 정한다.**

- 추천: 리뷰 컨테이너처럼 그 계정을 MASC Keeper 만 쓰는 endpoint 에는 선언한다. 규칙은 작업 폴더와 같다. 48시간 동안 아무도 안 건드렸고, 쓰는 프로세스가 없고, 그 계정이 가진 항목을 지운다. 11-11 에 손으로 지운 것(48시간 넘은 861건, 30 GiB)이 이 규칙이다.
- 치르는 값: 그 계정으로 도는 다른 프로그램이 `/tmp` 에 48시간 넘게 둔 것도 사라진다. 그래서 endpoint 마다 운영자가 정한다.
- 선언하지 않으면: 지우지 않는다. TUI 에 크기만 나온다.
