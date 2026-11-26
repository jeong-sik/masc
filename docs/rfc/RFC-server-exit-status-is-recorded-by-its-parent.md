---
rfc: "server-exit-status-is-recorded-by-its-parent"
title: "서버가 어떻게 끝났는지는 서버를 띄운 부모가 받아 적는다"
status: Draft
created: 2026-11-16
updated: 2026-11-26
author: claude
supersedes: []
superseded_by: null
related: ["masc-restart-replaces-the-workspace-server"]
---

# 서버가 어떻게 끝났는지는 서버를 띄운 부모가 받아 적는다

2026-11-16 운영 서버가 00:42 와 11:01(KST) 두 번 종료 절차 줄 없이 끝났다.
두 번 모두 무엇이 서버를 끝냈는지 가를 수 없었다. 서버의 종료 상태를 받아 적는 프로세스가 없어서다.
이 RFC 는 `masc restart` 가 서버와 자신 사이에 기다리기만 하는 부모(`masc exit-witness`)를 두자고 제안한다.
그 부모는 서버가 끝나면 exit code 나 신호 이름을 시작 로그에 한 줄 남긴다.

- 다루는 것: `masc restart` 로 띄운 서버가 끝난 방식을 남기는 일(#52385).
- 다루지 않는 것: 두 정지의 원인을 고치는 일. 이 기록으로 원인을 찾은 뒤 따로 고친다. 종료 절차 없이 끝난 뒤 Keeper 메시지가 실패하는 일(#52341). TUI·`masc setup` 이 띄우는 서버(§7, #52405). 종료 문구를 만드는 여러 곳을 하나로 모으는 일(§4.3).
- 근거 기준: 코드는 `origin/main` `706704b625a5` 에서 읽었다. 관측은 운영 저장소 `~/me/.masc` 와 macOS 시스템 기록을 읽기만 했다.
- 바꾸는 계약: RFC-masc-restart-replaces-the-workspace-server 와 `docs/guides/server-startup-ownership.md:51-61` 의 띄우기·준비 확인 단계(§6).
- 표시: **[사실]** 코드·문서·데이터에서 확인한 것, **[제안]** 이 RFC 가 내놓는 것, **[확인 필요]** 모르는 것.

## 1. 지금 동작

### 1.1 `masc restart`

- **[사실]** `replace` 는 먼저 앞 서버에 멈추라고 한다(`bin/masc_cli_restart.ml:375-392`). 그다음 같은 실행 파일의 `start … --wait-for-previous-owner` 를 `Posix_spawn_detached.spawn` 으로 띄운다(`:394-403`).
- **[사실]** 자식은 자기 프로세스 그룹을 갖는다(`lib/process/posix_spawn_stubs.c:189-200`, SETPGROUP). 세션은 restart 와 같다. 출력은 `O_APPEND` 로 연 시작 로그다(`masc_cli_restart.ml:233-236`).
- **[사실]** 준비 확인은 커널에 묻는다. 포트의 announcement byte 를 쥔 pid 가 restart 가 띄운 pid 와 같아야 준비로 본다(`lib/server/server_upgrade_preparation.ml:370-378`, `masc_cli_restart.ml:296-324`, HIGH-RISK-UNREVIEWED). `watch` 에는 기한이 없다(`:326-339`).
- **[사실]** 준비 전에 자식이 끝나면 restart 가 `pid N was killed by SIGKILL before it was ready` 처럼 알리고 로그 끝 줄을 보여 준다(`:415-419`). 신호 이름 표는 restart 에만 있는 9개짜리다(`:252-257`).
- **[사실]** 준비되면 restart 는 `Started pid` 와 `Ready … pid` 줄을 남기고 끝난다(`:406-414`). 그 뒤 서버는 launchd(pid 1)가 거둔다. 11-16 11:08 에 띄운 지금 서버의 부모도 launchd 다(`ps -o pid,ppid,pgid`).

### 1.2 서버가 스스로 남기는 것

- **[사실]** SIGTERM·SIGINT 처리기는 서버 루프 안에서 단다(`bin/main_eio.ml:651-656`). 받으면 `[MASC] Received SIGTERM, shutting down gracefully` 줄을 남긴다(`:678`). 그 전, 기동 중에 온 신호는 기본 동작으로 프로세스를 끝낸다(`:570-574` 주석).
- **[사실]** `--wait-for-previous-owner` 로 기다리는 동안에도 그렇다. "stopping this process ends the wait" 라고 알린다(`:259-262`).
- **[사실]** SIGPIPE 는 Eio_posix 가 무시로 바꾼다(`eio_posix.ml:22-23`, opam switch 5.5.2).
- **[사실]** 기동 중 직접 `exit` 하는 갈래는 stderr 에 이유 한 줄을 쓰고 끝난다(`:438-441`, `:492-495`, `:498-501`, `:506-509`).
- **[사실]** 서버까지 올라온 OCaml 예외는 cmdliner 가 잡아 `internal error, uncaught exception` 을 쓰고 125 로 끝난다(`:5113` `exit (Cmd.eval' cmd)`, `:563-568` 주석).
- 그 밖의 종료 신호(SIGHUP, SIGKILL 등)는 줄 없이 프로세스를 끝낸다.

### 1.3 부모만 종료 상태를 받는다

- **[사실]** macOS `kqueue(2)` 의 `NOTE_EXITSTATUS` 는 "Valid only on child processes" 다(`man 2 kqueue`, macOS 27.2). `waitpid(2)` 도 자식만 기다린다.
- 그래서 종료 상태를 받으려면 서버가 끝날 때까지 서버의 부모가 살아 있어야 한다. restart 는 준비되면 끝나야 하므로 그 부모가 될 수 없다.

## 2. 관측 (11-16)

| 끝난 시각(KST) | 시작 로그 | 빌드 | 돈 시간 | 마지막 서버 로그 |
|---|---|---|---|---|
| 00:42:29 | `masc-start-20261115T103255Z.log` | `fa710fcc23ae` | 5시간 10분 | Keeper 하나가 official client 런타임을 시작하던 중 |
| 11:01:04 | `masc-start-20261115T170602Z.log` | `0b295ab59550` | 8시간 55분 | Board 판정 정리와 Dashboard Shell 새로 고침 사이 |

- **[사실]** 두 시작 로그 모두 `Received SIGTERM`·`Received SIGINT`·`[FATAL]`·`uncaught exception` 줄이 0개다(`rg -c`). `internal error` 를 담은 줄 16개는 모두 Keeper 턴의 provider 오류 문구다.
- **[사실]** 두 로그의 마지막 줄은 `browser cleanup unconfirmed: …` 하나씩이다. 서버가 아니라 서버의 자식인 browser add-on worker 가 쓴 줄이다(`bin/masc_browser_addon_worker.ml:41-48`). worker 는 정리 scope 를 나갈 때 이 줄을 쓴다(`:41-50`). 서버와 잇는 stdin 이 닫히거나, SIGINT·SIGTERM 을 받거나(`:58-67`), 예외로 나갈 때다. 줄에 시각은 없다. 서버가 먼저 끝났다는 것과 맞지만, 서버가 어떻게 끝났는지는 말하지 않는다. 지금 도는 서버의 시작 로그에는 이 줄이 없다.
- **[사실]** masc 서버의 crash report 는 없다. 11:02:16 Jetsam 보고는 다른 프로세스 하나만 끝냈다. 서버는 이미 그 목록에 없었다.
- **[사실]** 같은 시각 다른 작업 세션의 `kill`·`pkill` 은 그 세션의 dune 빌드를 겨눴다. 서버 pid 와 겹치지 않는다.
- 남은 후보는 서버가 처리기를 달지 않은 종료 신호, 또는 로그 없이 끝나는 다른 길이다. 어느 쪽인지, 누가 보냈는지는 지금 구조로 알 수 없다.

## 3. 문제

`masc restart` 로 띄운 서버가 준비된 뒤 종료 절차 없이 끝나면, 어떻게 끝났는지 masc 어디에도 남지 않는다.
같은 정지가 다시 나도 원인을 가를 기록이 없다.

## 4. 제안

### 4.1 `masc exit-witness` 가 서버의 부모로 남는다

- **[제안]** restart 는 `masc exit-witness -- <지금의 masc start argv>` 를 지금과 같은 `Posix_spawn_detached.spawn` 으로 띄운다. 실행 파일은 지금처럼 `Sys.executable_name` 이다. 새 실행 파일은 없다.
- **[제안]** witness 는 SIGHUP·SIGINT·SIGTERM 에 아무것도 하지 않는 처리기를 단다. 무시(`Signal_ignore`)로 두지 않는다. 무시는 exec 를 지나 서버에 그대로 남지만, 처리기는 exec 때 기본 동작으로 돌아간다. spawn stub 은 신호 기본값을 다시 정하지 않는다(`posix_spawn_stubs.c:189-200` 은 SETSIGMASK 와 SETPGROUP 만 켜고 SETSIGDEF 는 켜지 않는다).
- **[제안]** witness 는 서버를 `Process_eio_detached.spawn_detached_writing_to` 로 띄운다. TUI 가 서버를 띄우는 함수와 같다. 서버는 새 세션에 들고(fork + setsid), 그룹 번호는 서버 pid 다. stdin 은 `/dev/null`, 출력은 witness 가 받은 시작 로그 fd 다.
  - 서버를 새 세션에 두는 이유: witness 가 같은 세션에 있으면 서버의 프로세스 그룹이 고아(orphaned)가 아니게 된다. 그러면 SIGTSTP·SIGTTIN·SIGTTOU 가 지금처럼 버려지지 않고 서버를 멈춘다. 새 세션이면 부모가 다른 세션에 있으므로 서버의 그룹은 지금처럼 고아다.
  - fork 는 domain 이 여럿인 프로세스에서 거절된다(`posix_spawn_detached.mli:1-9`). witness 는 `Eio_main` 도 스레드도 띄우지 않는다. **[확인 필요]** `masc` 실행 파일의 모듈 초기화가 domain 이나 스레드를 띄우지 않는지 구현 때 시험으로 확인한다.
  - fork 경로는 posix_spawn 경로가 주던 두 가지를 주지 않는다. posix_spawn stub 은 0~2 밖의 fd 를 모두 닫고(`posix_spawn_stubs.c:89-92`) 신호 mask 를 비운다(`:189-195`). `spawn_detached_writing_to` 는 fork + `execvpe` 라서, 서버는 witness 가 close-on-exec 없이 연 fd 와 fork 한 스레드의 mask 를 물려받는다(`process_eio_detached.ml:110-112` 는 자기가 연 fd 만 약속한다).
  - 그래서 witness 는 fork 전에 열린 fd 가 0~2 뿐인지 확인한다. 아니면 서버를 띄우지 않고 이유 한 줄과 함께 1 로 끝난다. witness 는 신호 mask 를 바꾸지 않는다. restart 의 spawn 이 비운 mask 그대로다.
- **[제안]** witness 는 서버를 띄운 직후 `[masc exit-witness] started server pid S` 한 줄을 남긴다. 서버가 끝나면 `Unix.waitpid` 로 받은 상태를 한 줄 더 남기고 exit 0 으로 끝난다.
  - no-op 처리기가 신호를 받으면 `Unix.waitpid` 는 `EINTR` 로 끝난다. witness 는 그때 다시 기다린다. 저장소의 다른 기다림도 같다(`bin/deployment_preflight_helper.ml:213-215` `waitpid_nointr`, `lib/process/process_eio_detached.ml:26-28`). 다시 기다리지 않으면 `kill -HUP W` 가 witness 를 cmdliner 의 125 로 끝내고 서버의 끝은 남지 않는다.
  - 예: `[masc exit-witness] server pid 35051 was killed by SIGKILL`
  - 예: `[masc exit-witness] server pid 71832 exited with status 0`
- **[제안]** witness 의 exit code 는 witness 자신의 일만 말한다. 서버를 띄우지 못하면 이유 한 줄과 함께 1 이다. 서버의 종료 상태를 128+신호 번호 같은 숫자로 옮기지 않는다. 서버가 그 숫자로 직접 끝난 경우와 구별되지 않기 때문이다.

### 4.2 restart 의 준비 확인은 "쥔 프로세스의 부모" 를 커널에 묻는다

- **[제안]** `lib/process` 에 `parent_pid : int -> int option` 을 더한다.
  - Darwin: `sysctl` `KERN_PROC_PID` 로 `kp_eproc.e_ppid` 를 읽는다. `masc_process_start_time` 이 이미 같은 호출을 한다(`posix_spawn_stubs.c:428-437`).
  - Linux: `/proc/<pid>/stat` 의 넷째 칸을 읽는다. `Process_group_members` 가 같은 칸을 이미 읽는다(`process_group_members.ml:51-59`).
  - 그 밖의 플랫폼은 `None` 이다.
- **[제안]** `replacement_sighting` 은 announcement byte 를 쥔 pid 의 `parent_pid` 가 restart 가 띄운 witness pid 일 때만 `Replacement_serves` 다. `None` 이나 다른 부모는 `Another_process_announces` 다.
- **[사실]** byte 를 쥐는 곳은 서버 프로세스 안이다(`lib/server/server_runtime_bootstrap.ml:2169`, 계정 서버는 `lib/server/server_accounts.ml:322`). 기동 중 다시 실행은 `Unix.execve` 라서 pid 와 부모가 바뀌지 않는다(`lib/core/masc_runtime_events.ml:88`). 그래서 쥔 프로세스는 witness 의 손자가 아니라 자식이다.
- **[사실]** `watch` 가 도는 동안 witness 는 restart 가 거두지 않은 자식이다. witness 가 끝나면 서버의 부모는 1 이 되므로, 다른 프로세스가 witness 의 pid 를 부모로 갖게 되는 일은 없다.
- **[제안]** `parent_pid` 를 읽을 수 없는 플랫폼에서는 restart 가 앞 서버에 멈추라고 하기 전에(`check_host` 자리) 거절한다. 멈추게 한 뒤에 거절하면 워크스페이스에 서버가 없게 된다.
- **[제안]** 출력 문구는 아는 것만 말한다.
  - `Started exit witness pid W. Log: …`
  - 준비되면 `Ready after … pid S …`. S 는 커널이 알려 준 서버 pid 다.
  - 준비 전에 witness 가 끝나면, 끝난 방식과 상관없이 같은 문장 하나다: `exit witness pid W <종료 문구> before the server was ready. See <log> for the server's pid and how it ended.` 와 로그 끝 줄. `<종료 문구>` 는 §4.3 의 함수가 만든다.
  - witness 가 exit 0 이면 서버가 끝난 뒤 witness 줄을 남긴 경우다. 1 은 서버를 띄우지 못한 경우, 125 는 witness 의 예외, 신호는 witness 가 먼저 끝난 경우다. 신호면 서버는 계속 기동할 수 있고, 그 서버의 종료 상태는 남지 않는다. restart 는 어느 경우든 1 로 끝난다.
  - 로그 끝 줄에 witness 줄이 없을 수 있다. Add-on worker 는 서버의 직접 자식이고 자기 그룹에 있어서(`posix_spawn_process_mgr.ml:293`, `native_addon_lease.ml:495`) 서버가 끝난 뒤에도 같은 로그에 쓴다(§2). witness 줄은 로그 안에 남는다.
- 이 바꿈은 HIGH-RISK-UNREVIEWED 코드다. 사람 리뷰를 받는다.

### 4.3 종료 문구는 leaf 모듈 하나에서 만든다

- **[사실]** `lib/process/process_eio.ml:187-200` 의 `signal_name` 은 OCaml 신호 상수 28개를 이름으로 바꾸고, 모르는 신호는 호스트 번호로 쓴다. `.mli:53` 에 열려 있다. 저장소가 고정한 OCaml 5.5.2 의 `Sys` 는 상수 30개를 둔다. 5.4 에서 더한 `sigio`·`sigwinch` 가 표에 없어 `signal -29`·`signal -30` 으로 나온다.
- **[사실]** 이 표를 `Posix_spawn_detached` 에서 부를 수 없다. `Process_eio` 가 `Posix_spawn_process_mgr` 를 쓰고(`process_eio.ml:1105`), 그것이 `Posix_spawn_detached` 를 쓴다(`posix_spawn_process_mgr.ml:91`). 같은 라이브러리 안에서 순환이 된다.
- **[제안]** 신호 표와 `Unix.process_status` 문구를 의존이 없는 leaf 모듈 하나(`lib/process/process_exit_text.ml`)로 옮긴다. `Process_eio.signal_name` 을 부르던 6곳(`lib/` 5곳, `test/test_browser_addon_live_ego.ml:69`)은 이 모듈을 부른다. restart 의 9개짜리 표와 `exit_description` 은 지우고 이 모듈을 쓴다. witness 도 같은 모듈을 쓴다. 표는 `Sys` 상수 30개를 모두 담는다.
- **[사실]** 같은 일을 하는 곳이 이 밖에도 많다. `rg 'WSIGNALED .*sprintf'` 로 20곳이 넘는다. 예: `bin/masc_tui_server_lifecycle.ml:184-187`(`killed by OCaml signal -7` 처럼 OCaml 내부 번호를 보임), `lib/process/with_process.ml:24`, `lib/build_identity.ml:112`, `lib/process/forked_map.ml:6-13`, `bin/masc_tui.ml:260-264`. 시험 몇 개가 지금 문구를 본다.
- 이 정리는 몇 곳만 손으로 고치면 AGENTS.md 가 금지하는 N-of-M 이 된다. 그래서 이 RFC 에서는 leaf 모듈만 만들고, 나머지는 `rg` 목록 전체를 한 번에 옮기는 이슈로 남긴다.

### 4.4 대가

- **[사실]** 설치된 `masc --version` 한 번의 peak memory footprint 는 50,840,176 B 와 50,872,944 B(약 48.5 MiB)였다. 최대 RSS 는 약 93 MiB 지만, 그 차이는 대부분 서버와 같은 실행 파일의 file-backed 쪽이다(`/usr/bin/time -l`, 11-16, 2회).
- witness 는 서버가 떠 있는 내내 그 정도를 쓴다. 기다리는 동안의 값은 §8 에서 다시 잰다. 헌법은 비용을 지금 따지지 않는다(`docs/constitution.xml` `cost_and_observability`).
- restart 한 번에 실행 파일이 한 번 더 뜬다. `masc --version` 의 real 은 0.09~0.43 초였다.
- witness 가 SIGKILL 로 먼저 끝나면 그 서버의 종료 상태는 지금처럼 남지 않는다. 서버는 launchd 가 거둔다.

## 5. 고르지 않은 길

- **작은 별도 실행 파일:** 메모리는 덜 쓴다(재지 않음). 대신 설치하고 배포하는 목록에 실행 파일이 하나 는다. `scripts/install.sh:1138`, `scripts/install-local-build.sh:104-106`, `scripts/install-smoke.sh:124`, release·probe·Add-on 워크플로, 패키징 스크립트 둘, `bin/dune`, 헌법 `build_and_ci` 의 "실행 파일 4개" 가 그 목록이다. 하위 명령은 서버와 같은 경로의 실행 파일이라 이 목록이 그대로다. 그 사이에 설치가 바뀌면 빌드가 다를 수 있지만, 서버도 기동 중에 같은 경로로 다시 exec 한다(`main_eio.ml:476-479`). 그 성질은 지금과 같다.
- **witness 가 서버 pid 를 파이프로 restart 에 알리기:** 커널이 답할 수 있는 것을 메시지로 믿는다. 추가 fd 를 넘기려면 spawn stub 도 바꿔야 한다.
- **서버를 witness 의 프로세스 그룹에 두기:** 서버가 그룹 대표가 아니게 되어 "자식 pid = 자식 그룹" 계약(`posix_spawn_detached.mli` `pid`)이 바뀐다.
- **서버를 witness 와 같은 세션의 새 그룹에 두기(`Posix_spawn_detached`):** §4.1 처럼 서버의 그룹이 고아가 아니게 된다. witness 가 멈춘 서버를 둔 채 끝나면 POSIX 는 새로 고아가 된 그룹에 SIGHUP 과 SIGCONT 를 보내고, 서버는 기록 없이 끝난다.
- **launchd 작업으로 띄우기:** `~/me/AGENTS.md` 는 `launchd`·`launchctl` 을 사용자가 요청할 때만 쓰게 한다. Linux 에는 없다.
- **다음 기동이 "지난 인스턴스가 종료 절차 없이 끝났다" 고 적기:** 어떻게 끝났는지는 여전히 모른다. witness 기록이 있으면 필요 없다.
- **SIGHUP 도 종료 절차로 받기(#52385 의 B):** 원인이 SIGHUP 인지 아직 모른다. 하려면 재시작 뒤 로그를 다시 읽을 때 신호 줄을 글자로 가르는 분류기(`lib/masc_log/log.ml:805-829`)를 늘리거나, JSONL 이 종류를 담게 하고 dashboard 로그 스키마(`dashboard/src/api/schemas/logs.ts:262-288`, 모르는 키 거절)도 바꿔야 한다. 앞쪽은 헌법 `string_matching` 에 걸린다. witness 기록에서 처리할 수 있는 신호가 나오면 그 근거로 다시 연다.
- **witness 줄을 masc 로그 저장소에 typed 로 넣기:** witness 줄은 시작 로그의 평문이다. 지금 원인을 가르는 데는 사람이 읽는 한 줄로 족하다. 읽는 쪽이 생기면 그때 형식을 정한다.

## 6. 계약에 닿는 곳

| 계약 | 바뀐 뒤 |
|---|---|
| lease 가 적는 pid | 서버 pid 그대로 |
| `--wait-for-previous-owner` | 서버 pid 를 기다리는 것 그대로. 서버는 SIGTERM·SIGINT 기본 동작을 받으므로 기다리는 중에 멈출 수 있는 것도 그대로 |
| 서버의 프로세스 그룹 | 서버 자신 그대로. 그룹이 고아인 것도 그대로 |
| 서버의 세션 | restart 의 세션 → 서버 자신의 새 세션 |
| 서버가 물려받는 fd·신호 mask | posix_spawn 이 0~2 만 남기고 mask 를 비움 → witness 가 fork 전에 0~2 만 열린 것을 확인하고, restart 가 비운 mask 를 그대로 넘김 |
| restart 준비 확인 | 쥔 pid == 띄운 pid → 쥔 pid 의 `parent_pid` == 띄운 witness pid |
| restart 출력 | `Started` 는 witness pid, `Ready` 는 서버 pid, 준비 전 종료는 witness 종료 + 로그 끝 줄 |
| 시작 로그 | witness 가 같은 fd 로 두 줄 더한다 |
| 계정 서버(`This_account_server`) | 같은 `replace` 를 타므로 같이 바뀐다 |
| 터미널에서 직접 `masc start` | 바뀌지 않는다. 셸이 부모다 |
| TUI·`masc setup` 이 띄우는 서버 | 바뀌지 않는다(§7) |

같이 고칠 문서와 시험:

- `docs/guides/server-startup-ownership.md:51-61` 의 3·4단계, RFC-masc-restart-replaces-the-workspace-server 의 준비 확인 문장.
- `test/test_server_upgrade_preparation.ml:427-445`: `~child_pid` 대신 부모를 읽는 함수를 넘긴다.
- `test/test_onboarding_journey.py:1577`, `test/test_model_independent_owner.py:168`: `Started pid` 에서 서버 pid 를 읽어 끝날 때 SIGTERM 을 보낸다(`:1608`, `:206`). `Ready … pid S` 줄에서 S 를 읽게 바꾼다. witness pid 로 바꾸면 witness 가 SIGTERM 을 받아 넘기지 않으므로 서버가 남는다.
- `test/test_setup_cli.py:644` 의 `assertNotIn('Started pid', …)` 는 문구가 바뀌면 늘 통과한다. 바뀐 문구로 고친다.

- **[사실]** `bin/main_eio.ml`, `lib/server/`, `lib/process/`, `lib/shutdown.ml` 에 `getppid` 호출은 없다(`rg`). 부모가 launchd 에서 witness 로 바뀌어도 서버의 판단은 달라지지 않는다.
- **[사실]** masc 에는 `masc stop` 이 없다. 운영자는 서버 pid 에 SIGTERM 을 보내거나 `masc restart` 로 바꾼다.

## 7. TUI·`masc setup` 이 띄우는 서버

- **[사실]** 둘은 `Process_eio_detached` 로 서버를 새 세션에 띄우고, 자기가 살아 있는 동안 종료 상태를 받아 보여 준다(`bin/masc_tui_server_lifecycle.ml:113-128`, `:189-205`, `bin/masc_cli_setup.ml:263-270`, `bin/masc_tui.ml:2917`).
- **[사실]** TUI 는 서버를 멈추지 않는다. 준비되면 "it stays running when the TUI closes" 를 알린다(`bin/masc_tui.ml:2959`). `masc setup --no-tui` 는 서버를 놓고 끝난다(`bin/masc_cli_setup.ml:461`). 두 경로 모두 띄운 쪽이 끝나면 restart 와 같은 빈자리가 생긴다.
- **[사실]** `masc setup` 이 TUI 를 연 경우는 TUI 가 끝난 뒤 setup 이 서버를 프로세스 그룹째 멈춘다(`bin/masc_cli_setup.ml:387-392`, `bin/masc_tui_server_lifecycle.ml:249-250` `tree_kill ~pgid`). witness 가 서버를 새 세션에 두면 이 신호는 witness 의 그룹에만 닿고 서버는 남는다.
- 그래서 이 경로에 witness 를 쓰려면 setup 이 멈추는 대상을 함께 정해야 한다. 이 RFC 에서는 정하지 않고 #52405 로 남긴다.

## 8. 검증

격리 서버(`env -i`, 임시 HOME·base path·포트)로 한다. 운영 서버는 건드리지 않는다. 같은 시험을 macOS 와 Linux 에서 돌린다.

1. restart 로 띄운 뒤 서버 pid 에 `kill -KILL` → 시작 로그에 서버 pid S 를 말하는 witness 줄이 있고, witness 는 exit 0 으로 끝난다. 마지막 줄인지는 보지 않는다(Add-on worker 가 뒤에 쓸 수 있다).
2. 서버 pid 에 `kill -HUP` → witness 줄이 SIGHUP 을 말한다.
3. 서버 pid 에 `kill -TERM` → `Received SIGTERM` 줄 뒤에 witness 의 `exited with status` 줄이 있다.
4. witness pid 에 `kill -HUP`·`-INT`·`-TERM` → witness 와 서버가 계속 돈다. 그 뒤 서버 pid 에 `kill -KILL` 을 보내면 witness 줄이 남는다.
5. 앞 서버가 있는 상태에서 restart → 기다리는 새 서버에 `kill -TERM` 을 보내면 새 서버가 끝나고 witness 줄이 SIGTERM 을 말한다. 같은 상황에서 `kill -INT` 도 본다.
6. restart 가 `Ready` 를 알리고, 그 pid 가 lease 의 pid 와 같다. 다른 프로세스가 byte 를 쥐면 지금처럼 `pid N holds the announcement` 를 알린다. `watch` 에 기한이 없으니 시험이 기한을 둔다.
7. 서버가 기동 중 `exit 1` 로 끝나면 restart 가 witness 종료 문장과 로그 끝 줄을 보여 주고, 로그에 서버의 이유 줄과 witness 줄이 있다.
8. 서버 pid 에 `kill -TSTP` → 서버가 멈추지 않는다(고아 그룹은 이 신호를 버린다).
9. 서버의 열린 fd 를 나열하면 0~2 와 서버가 스스로 연 것뿐이다. witness 에 0~2 밖의 fd 를 하나 열어 두면 witness 가 서버를 띄우지 않고 1 로 끝난다.
10. `replacement_sighting` 단위 시험: 쥔 pid 의 부모가 witness, 다른 pid, `None` 인 세 경우.
11. 변형 시험
    - witness 가 종료 상태를 버리면 1·2 가 실패한다.
    - witness 가 `EINTR` 뒤 다시 기다리지 않으면 4 가 실패한다.
    - witness 가 처리기 대신 `Signal_ignore` 를 쓰면 2·5 가 실패한다. 3 은 서버가 자기 SIGTERM 처리기를 달아 통과한다.
    - 준비 확인을 "쥔 pid == 띄운 pid" 로 되돌리면 6·10 이 실패한다.
    - witness 가 서버를 같은 세션에 두면 8 이 실패한다.
    - witness 가 fd 확인을 건너뛰면 9 가 실패한다.
12. 기다리는 witness 의 footprint 를 `footprint <pid>` 로 재서 PR 에 적는다.

시험은 문구 대신 값을 본다. witness 줄은 같은 함수가 같은 `Unix.process_status` 로 만든 줄과 같은지 본다.

## 9. 층

1. 문구: `lib/process/process_exit_text.ml` 을 만들고, `Process_eio.signal_name` 과 restart 의 표를 옮긴다. 문장 모양은 그대로다. restart 는 예전 표 9개 밖의 신호도 이름으로 쓰고, 모든 호출처가 `SIGIO`·`SIGWINCH` 를 이름으로 쓴다.
2. 부모 읽기: `parent_pid`(Darwin·Linux)와 단위 시험.
3. witness: `masc exit-witness` 하위 명령.
4. restart: witness 를 띄우고, 준비 확인을 `parent_pid` 로 바꾸고, 문서와 시험을 고친다(HIGH-RISK).

RFC 를 맨 아래 층으로 두는 native stack 으로 쌓는다.

## 10. 정한 것 (운영자, 2026-11-16)

1. **witness 는 `masc` 하위 명령이다(§4.1).** 설치·배포 목록이 그대로다. 대가는 서버가 떠 있는 동안 약 48.5 MiB 다(§4.4). 고르지 않은 길은 작은 별도 실행 파일이다(§5).
2. **restart 준비 확인은 "쥔 프로세스의 커널 부모 == 띄운 witness" 다(§4.2).** `parent_pid` 를 읽을 수 없는 플랫폼은 앞 서버를 멈추기 전에 거절한다. HIGH-RISK 코드라 사람 리뷰를 받는다. 고르지 않은 길은 witness 가 파이프로 서버 pid 를 알리는 것이다(§5).
3. **서버는 witness 와 다른 새 세션에 띄운다(§4.1).** 서버의 그룹이 지금처럼 고아로 남는다. 고르지 않은 길은 같은 세션의 새 그룹이다(§5).
4. **SIGHUP 종료 절차(#52385 의 B)는 witness 기록 뒤로 미룬다.** witness 기록에서 처리할 수 있는 신호가 나오면 그 근거로 다시 연다(§5).
5. **TUI·`masc setup` 경로는 이 RFC 밖이다.** #52405 로 남긴다(§7).

## 11. 열린 질문

### 11.1 새 세션도 posix_spawn 으로 만들기 (2026-11-26, #52124)

§10 3번(서버는 새 세션)은 그대로다. 이 질문은 새 세션을 만드는 방법만 바꾼다. 운영자가 정하기 전까지 §4.1 이 그대로 기준이다.

- **[사실]** §4.1 의 witness 는 서버를 fork 로 띄운다(`Process_eio_detached.spawn_detached_writing_to`). 자식은 exec 전에 OCaml 코드로 `setsid`, 표준 fd 연결, 준비 byte 쓰기를 한다(`lib/process/process_eio_detached.ml:65-84`).
- **[사실]** masc 소유 stub 은 지금 새 그룹만 만든다. `own_group` 이면 `POSIX_SPAWN_SETPGROUP` 을 켠다(`lib/process/posix_spawn_stubs.c:189-199`). `Posix_spawn_detached` 는 자식이 "a process group of its own (not a session of its own)" 에서 돈다고 적는다(`posix_spawn_detached.mli:1-9`).
- **[사실]** 두 플랫폼 모두 posix_spawn 에 새 세션 flag 가 있다.
  - macOS: `POSIX_SPAWN_SETSID`(0x0400)가 SDK 헤더의 Darwin 전용 flag 묶음에 있다(`MacOSX.sdk/usr/include/sys/spawn.h:61`). 설치된 man page `posix_spawnattr_setflags(3)` 에는 이 flag 가 없다.
  - glibc: 2.26 부터 있다. 근거는 glibc `NEWS` 2.26 절("posix_spawnattr_setflags now supports the flag POSIX_SPAWN_SETSID", BZ #21340), `posix/spawn.h:62`(`__USE_GNU` 아래 0x80), man-pages `posix_spawn(3)` 의 "POSIX_SPAWN_SETSID (since glibc 2.26)" 다. stub 은 이미 `_GNU_SOURCE` 를 정의한다(`posix_spawn_stubs.c:14`).
- **[사실]** glibc 의 Linux 구현은 `setsid` 다음에 `setpgid` 를 부른다(`sysdeps/unix/sysv/linux/spawni.c:159-166`). 세션 대표는 `setpgid` 로 그룹을 바꿀 수 없다. 그래서 새 세션 mode 는 `SETPGROUP` 없이 `SETSID` 만 켠다. `setsid` 가 자식을 새 그룹의 대표로도 만들므로 "자식 pid = 자식 그룹" 계약(`posix_spawn_detached.mli` `pid`)은 그대로다.
- **[후보]** stub 에 새 세션 mode 를 더한다. 그룹 mode 와 같은 함수이고 flag 만 다르다. 그러면 fork 와 exec 사이에 도는 OCaml 코드가 없어진다.

§4.1 witness 설계에 생기는 일:

- fork 를 쓰지 않으니 "domain 이 여럿이면 fork 가 거절된다" 는 제약과 그 **[확인 필요]**(모듈 초기화가 domain·스레드를 띄우는지)가 없어진다.
- stub 은 0~2 밖의 fd 를 닫고(`posix_spawn_stubs.c:86-92`, `:125-128`) 신호 mask 를 비운다(`:189-195`). 그래서 witness 의 "fork 전에 열린 fd 가 0~2 뿐인지 확인하고, 아니면 1 로 끝난다" 단계가 없어진다. §8 9번 뒤 문장은 "witness 에 0~2 밖의 fd 를 하나 열어 두어도 서버의 열린 fd 는 0~2 와 서버가 연 것뿐이다" 로 바뀐다. §8 11번의 "fd 확인을 건너뛰면" 변형 시험도 없어진다.
- exec 실패를 posix_spawn 이 바로 돌려준다. glibc 는 자식의 errno 를 부모에게 넘긴다(`spawni.c:306`, `:451`). macOS man page `posix_spawn(2)` 는 "If an error occurs, they return a non-zero error code ... and no child process is created" 라고 적는다. 그래서 fork 경로의 준비 byte 와 exit 127 이 필요 없다.
- 그대로인 것: 서버가 새 세션에 드는 것(§10 3번), 서버 그룹이 고아로 남는 것, §8 8번(`kill -TSTP`), witness 의 no-op 처리기. stub 은 `SETSIGDEF` 를 켜지 않으므로 처리기와 무시의 차이(§4.1)는 지금과 같다. stdin 도 `/dev/null` 그대로다(stub 은 터미널 stdin 을 `/dev/null` 로 바꾼다, `posix_spawn_stubs.c:205`).
- **[확인 필요]** macOS 에서 `SETSID` 로 띄운 자식이 실제로 새 세션의 대표가 되는지. man page 에 없으니 자식의 `getsid` 를 보는 작은 시험으로 확인한다. `SETSID` 와 `SETPGROUP` 을 같이 켠 경우는 읽지 않았다. 새 세션 mode 는 둘을 같이 켜지 않는다.
- 이 길을 고르면 §4.1 의 fork 문단과 §8 9·11번을 고친다. TUI·`masc setup` 경로도 같은 mode 로 옮길 수 있지만 §10 5번대로 이 RFC 밖이다(#52405).

## 12. 관련

- #52385 서버가 종료 절차 없이 끝나도 어떻게 끝났는지 남는 곳이 없다.
- #52405 TUI·`masc setup --no-tui` 가 띄운 서버도 띄운 쪽이 끝나면 어떻게 끝났는지 남지 않는다.
- #52397 종료 문구를 만드는 곳이 25곳이고, 몇 곳은 OCaml 내부 신호 번호를 보인다(§4.3).
- #52341 종료 절차 없이 끝난 뒤 다시 띄우면 걸려 있던 Keeper 메시지가 turn counter 불일치로 실패한다.
- task-3306 서버가 SIGTERM 으로 멈출 때 자기 native Lane Add-on instance 를 Detach 해 둔다.
- RFC-masc-restart-replaces-the-workspace-server: 이 RFC 가 준비 확인 규칙을 바꾼다.
