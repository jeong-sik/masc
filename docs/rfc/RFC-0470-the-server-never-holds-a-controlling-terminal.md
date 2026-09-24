---
rfc: "0470"
title: "masc 서버는 어떻게 띄워도 제어 터미널을 갖지 않는다"
status: Draft
created: 2026-09-24
updated: 2026-09-25
author: vincent + claude
supersedes: []
superseded_by: null
related: ["#38700", "#38633"]
implementation_prs: ["#38633"]
---

# RFC-0470 — masc 서버는 어떻게 띄워도 제어 터미널을 갖지 않는다

## 1. 문제

2026-09-24 16:29:43 KST 부터 로컬 서버가 14분 동안 멈췄다(#38700).

- `masc start` 는 터미널의 백그라운드 작업이었고, 포그라운드는 `masc-tui` 였다.
- Keeper `rondo` 의 agy 가 로그인 토큰을 갱신하지 못했다. 그 순간 DNS 가 실패했다. agy 는
  대화형 로그인으로 넘어가면서 `/dev/tty` 를 열었다.
- 백그라운드 작업이 제어 터미널을 읽거나 설정을 바꾸면, 커널은 그 작업의 프로세스 그룹 전체에
  SIGTTIN·SIGTTOU 를 보낸다. 기본 동작은 정지다.
- 서버는 자식을 자기 그룹에 둔다. 그래서 서버와 공식 클라이언트 자식 9개가 모두 `T` 가 됐다.

masc-tui 가 띄운 서버에서는 이 일이 생기지 않는다. masc-tui 는 서버를 `fork` + `setsid` 로
띄운다(`lib/process/process_eio_detached.ml`). 서버는 새 세션의 리더가 되고 제어 터미널이 없다.
자식이 `/dev/tty` 를 열면 ENXIO 로 실패한다. 프롬프트는 멈춤이 아니라 실패로 끝난다.

터미널에서 `masc start` 로 띄우면 서버와 모든 자식이 그 터미널을 제어 터미널로 갖는다.
`masc-stdio` 도 부른 쪽의 세션과 터미널을 그대로 물려받는다.

## 2. 지켜야 할 것

- **I1.** 서버와 그 자손은 제어 터미널을 갖지 않는다. 터미널을 가리키는 파일 디스크립터도
  물려받지 않는다. 새 세션의 리더가 나중에 터미널 장치를 열어야 한다면 `O_NOCTTY` 로 열어
  제어 터미널을 새로 얻지 않는다.
- **I2.** 서버의 프로세스 그룹을 끄면 자손이 모두 끝난다. 이 그룹을 끄는 곳은 여럿이다.
  - masc-tui 와 `masc setup` 의 `Masc_tui_server_lifecycle.stop`: TERM 을 보내고 5초 뒤 KILL 한다.
  - launchd 의 그룹 종료.
  - 운영자의 `kill -- -<pgid>`.
- **I3.** 터미널에서 띄운 서버도 Ctrl+C 와 터미널 닫힘에 정리 종료한다.
- **I4.** 신호 처리 방식(disposition)을 바꿔서 막지 않는다. 자식 프로그램이 그 신호를 어떻게
  다루는지는 masc 가 정할 수 없다(§3.2).

## 3. 버린 방법

#38633 검토 과정에서 아래 셋을 재 보고 버렸다. #38633 의 현재 변경은 §4.4 의
터미널 stdin 처리만 담고 있으며, 아래 신호 무시 방식은 담지 않는다. RFC 의 서버 분리,
감독, `masc-stdio`, SIGPIPE 계약은 아직 구현되지 않았다.

### 3.1 자식마다 새 세션 (`POSIX_SPAWN_SETSID`)

자식은 `/dev/tty` 를 열지 못하게 된다. 하지만 I2 가 깨진다.

- 자식이 서버 그룹을 떠나서, 그룹을 끄는 신호가 자식에게 닿지 않는다.
- `masc setup` 은 TERM 뒤 5초에 KILL 한다. 서버 정리는 10초까지 걸릴 수 있다. 그 사이에 서버가
  KILL 되면 자식은 고아로 남는다. 적대적 리뷰에서 ppid 1 인 고아를 재현했다.
- 터미널 hangup, launchd 의 그룹 종료도 자식을 놓친다. 손자 프로세스는 신호를 아예 받지 못한다.

### 3.2 서버가 SIGTTIN·SIGTTOU 무시

무시한 신호는 fork·exec 를 거쳐도 그대로 물려진다. 터미널 읽기는 EIO 로 끝나고 설정 변경은
허용된다. 하지만 I4 의 이유로 깨진다.

- ssh·ssh-keygen·sudo 는 `readpassphrase` 로 비밀번호를 묻는다. 이 함수는 두 신호를 직접 잡는다.
  신호를 받으면 물려받은 무시로 되돌리고, 신호를 다시 보내고, 처음부터 다시 묻는다. 무시 상태에서는
  끝나지 않는다. macOS 에서 3초에 "Enter passphrase" 를 44,788번 썼다.
- Keeper exec 자식은 자기 프로세스 그룹에서 돈다. 서버가 포그라운드여도 이 자식은 백그라운드 작업이라
  위 루프에 들어간다. exec 제한 시간(600초) 동안 터미널이 프롬프트로 덮인다.
- Node 는 물려받은 무시를 시작할 때 기본값으로 되돌린다. 그룹의 다른 자식이 터미널을 건드리면 커널은
  그룹 전체에 신호를 보낸다. 그러면 터미널을 건드리지 않은 Node LSP 자식까지 멈춘다.
- macOS `/bin/stty` 도 SIGTTOU 를 기본값으로 되돌린다.

### 3.3 서버가 `TIOCNOTTY` 로 터미널을 내려놓기

세션 리더가 아닌 프로세스는 `ioctl(TIOCNOTTY)` 로 제어 터미널을 내려놓을 수 있다. 그 뒤 띄운 자식도
터미널이 없다. 하지만 I3 이 깨진다. macOS 는 터미널이 보내는 신호를 제어 터미널이 있는 그룹 구성원에게만
보낸다. pty 에서 재 보니, 내려놓은 프로세스는 ^C 를 받지 못했다.

## 4. 제안

### 4.1 masc-tui 가 띄우는 서버

바꾸지 않는다. 이미 I1·I2 를 지킨다.

### 4.2 터미널에서 띄우는 `masc start`

`masc start` 는 서버 소유권 잠금과 Eio 런타임을 시작하기 전에 `/dev/tty` 를 `O_CLOEXEC` 로
열어 본 뒤 닫는다. 감지용 파일 디스크립터는 서버에 넘기지 않는다.

- 열리지 않으면 제어 터미널이 없다. 지금처럼 그대로 서버로 돈다.
- 열리면 `masc start` 는 감독 프로세스가 된다.
  1. masc-tui 의 `Masc_tui_server_lifecycle.start` 가 쓰는 시작 경로를 공용 라이브러리로 옮겨
     함께 쓴다. 이 경로는 `open_startup_output` 으로
     `<base_path>/.masc/logs/masc-server-<port>.log` 를 열고,
     `Process_eio_detached.spawn_detached_writing_to` 로 `masc start` 자식을 `fork` + `setsid` 한다.
     자식에게는 제어 터미널이 없으므로 위의 직접 서버 경로로 들어가며, 서버 소유권 잠금은 자식만 잡는다.
  2. 서버의 stdin 은 `/dev/null`, stdout·stderr 는 같은 시작 출력 파일이다. 파일은 서버가 직접
     `O_APPEND` 로 쓰고, 감독은 별도 읽기 디스크립터로 처음부터 따라 읽어 자기 stdout 에 보여 준다.
     서버와 감독 사이에는 파이프가 없다. 감독이 SIGTSTP·SIGTTOU 로 멈춰도 서버는 파일에 계속 쓰고,
     감독이 다시 돌면 밀린 출력을 읽는다. 시작 출력 파일을 열 수 없으면 기존 masc-tui 경로처럼
     서버는 `/dev/null` 로 시작하고 감독은 포그라운드 로그가 없다는 오류를 알린다.
  3. 감독이 SIGINT·SIGTERM·SIGHUP·SIGQUIT 를 받으면 서버 그룹에 SIGTERM 을 보낸다. 서버는 지금처럼
     정리 종료한다(I3). SIGTSTP·SIGTTIN·SIGTTOU 는 감독의 터미널 작업 제어에 맡긴다.
  4. 서버가 끝나면 감독은 서버의 종료 코드로 끝난다.
  5. 감독이 서버보다 먼저 사라져도 출력 파일을 열었던 서버는 그 파일에, 열지 못한 서버는
     `/dev/null` 에 계속 쓴다. 서버가 스스로 쓰는 `system_log_<날짜>.jsonl` 도 계속 기록된다.
     끊길 출력 파이프가 없어 SIGPIPE·EPIPE 전환이 필요 없다.

자식 spawn 은 바꾸지 않는다. 자식은 서버 그룹에 남는다(I2).

감독이 KILL 로 죽으면 서버는 남는다. masc-tui 가 KILL 로 죽을 때와 같다. 그 서버는
`<run_dir>/masc-<port>.pid` 의 pid 로 끄거나, 새 서버를 띄워 밀어낸다
(`lib/server/server_startup_takeover.ml`).

### 4.3 `masc-stdio`

`masc-stdio` 는 MCP 클라이언트의 자식이다. stdin·stdout 은 MCP 전송이라 터미널이 아니다.
런타임·소유권 잠금을 시작하기 전에 한 번 `fork` 한다. 자식은 새 프로세스 그룹의 리더가 아니므로
`setsid()` 로 새 세션을 만든 다음, 물려받은 MCP stdin·stdout·stderr 로 서버를 시작한다.
부모는 자기 쪽 MCP 파일 디스크립터를 닫고 자식을 `waitpid` 하며 종료 상태만 클라이언트에 전달한다.
부모는 MCP 프로토콜 바이트를 쓰지 않는다. 그룹 리더도 직접 `setsid()` 하면 `EPERM` 이라는
[POSIX 조건](https://www.man7.org/linux/man-pages/man3/setsid.3p.html)이 있어서, 시작 방식에 따라
직접 호출과 fork 를 고르지 않는다. `fork` 나 자식의 `setsid` 가 실패하면 터미널이 있는 상태로
계속 실행하지 않고 시작을 실패시킨다.

클라이언트가 stdin 쓰기 쪽을 닫으면 자식이 EOF 를 받고 끝난다. 부모는 클라이언트의 그룹에
남으므로 SIGINT·SIGTERM·SIGHUP·SIGQUIT 를 받으면 자식의 새 프로세스 그룹에 SIGTERM 을 전달한다.
부모가 SIGKILL 로 먼저 죽었을 때는 신호를 전달할 수 없으므로, 클라이언트가 stdin 쓰기 쪽을
닫아야 자식의 EOF 종료를 보장한다.

### 4.4 spawn 스텁의 stdin 규칙

`lib/process/posix_spawn_stubs.c` 는 지금 자기 그룹에 있는 자식에게만 터미널 stdin 을
`/dev/null` 로 바꿔 준다. 이 규칙을 모든 자식으로 넓힌다. 서버에는 터미널이 없어지지만, `masc setup`
같은 CLI 는 터미널을 가진 채 같은 스텁으로 자식을 띄우기 때문이다. 이 stdin 변경은
#38633 의 현재 head 에 있다. §3.2 의 SIGTTIN·SIGTTOU 무시는 그 PR 에 포함되지 않는다.

같은 스텁은 자식의 SIGPIPE 를 기본값으로 되돌린다 (`POSIX_SPAWN_SETSIGDEF`). 지금은 신호 마스크만 비운다
(`POSIX_SPAWN_SETSIGMASK`). Eio 의
[`eio_linux`](https://github.com/ocaml-multicore/eio/blob/main/lib_eio_linux/eio_linux.ml) 와
[`eio_posix`](https://github.com/ocaml-multicore/eio/blob/main/lib_eio_posix/eio_posix.ml)는
둘 다 시작할 때 SIGPIPE 를 무시한다. 자식이 이 설정을 물려받지 않게 하는 독립적인 spawn 계약이다.
파이프 앞쪽 명령이 SIGPIPE 로 끝나지 않고 쓰기 오류를 받는 문제를 막는다. 서버의 콘솔 출력에는
파이프를 쓰지 않으므로 서버에 새 SIGPIPE 무시 설정은 넣지 않는다.

## 5. 검증

#38633 의 pty 하네스(`test/test_process_group_terminal_stdin.py`)를 쓴다. 이 하네스는 fixture 를
pty 의 백그라운드 작업으로 띄울 수 있다.

1. `masc start` 를 pty 의 백그라운드 작업으로 띄운다. 서버 pid 의 세션은 감독과 다르고, 서버에는
   제어 터미널이 없다. 서버의 stdout·stderr 가 `masc-server-<port>.log` 를 가리키고 감독만
   그 파일을 읽는지 확인한다. 터미널 없이 띄운 `masc start` 는 새 감독을 만들지 않는다.
2. 서버가 띄운 자식이 `/dev/tty` 를 열면 ENXIO 를 받는다. 암호가 걸린 키로 `ssh-keygen -y` 를 돌리면
   프롬프트를 쏟지 않고 곧바로 실패한다. `SSH_ASKPASS` 와 화면 환경을 비워 대체 암호 창이
   결과를 바꾸지 못하게 한다.
3. 포그라운드로 띄우고 ^C 를 보낸다. 서버가 정리 종료하고 자식이 모두 끝난다.
4. pty 를 닫는다(hangup). 3 과 같은 결과가 나온다.
5. 서버의 `fork` + `setsid` 를 뺀 대조 fixture 는 1 의 조건에서 서버와 자식이 멈추는지 확인한다.
6. 감독을 SIGTSTP 로 멈추고 서버에 64 KiB 를 넘는 로그를 쓰게 한다. 감독이 읽지 않는 동안에도
   `/health?full=1` 이 응답하고 시작 출력 파일이 자라는지 확인한다. SIGCONT 뒤 감독이 밀린
   출력을 읽는지도 본다. `stty tostop` 을 켠 pty 에서 감독을 백그라운드로 띄워 SIGTTOU 로
   멈추게 한 뒤 같은 검사를 한다. 리눅스와 macOS 둘 다에서 본다.
7. 감독을 SIGKILL 로 죽인 뒤 서버가 로그를 쓰게 한다. 서버가 살아 있고 시작 출력 파일과
   `system_log` 에 계속 쓰는지 본다. 출력 파이프는 없어야 한다.
8. `masc-stdio` 를 클라이언트의 프로세스 그룹 리더로 띄운다. MCP 요청·응답이 이어지고 서버
   자식의 세션이 달라졌는지 본다. 클라이언트가 stdin 쓰기 쪽을 닫으면 EOF 로 끝나고,
   클라이언트 그룹에 TERM 을 보내면 부모가 자식 그룹을 종료하는지도 본다. `fork` 또는 `setsid`
   실패를 주입하면 MCP 서버가 터미널을 가진 채 계속 돌지 않는지도 확인한다.
9. 서버가 띄운 자식의 SIGPIPE 가 기본값인지 본다.

`process-groups` 워크플로(`.github/workflows/process-groups.yml`)에 이 pty 테스트를 더해
Linux·macOS 둘 다에서 돌린다.

## 6. 정한 것 (운영자, 2026-09-24)

1. 터미널 모드는 감독이다 (§4.2). 감독이 시작 출력 파일을 따라 읽어 포그라운드 로그와 ^C 를
   유지한다. 감독이 멈춰도 서버 쓰기를 막는 파이프는 없다.
2. `masc-stdio` 는 `fork` 한 자식에서 `setsid()` 로 클라이언트의 프로세스 그룹을 떠난다 (§4.3).
   부모는 MCP 파일 디스크립터를 닫고 자식을 기다린다. 클라이언트가 stdin 을 닫거나 부모에
   종료 신호를 보내면 자식도 끝난다.
3. 감독이 먼저 사라져도 서버의 출력 대상은 바뀌지 않고 `system_log` 도 계속 쓴다 (§4.2 의 5).

## 7. 범위 밖

- 자식 프로그램의 프롬프트를 없애는 일. agy 의 대화형 로그인이 그 예다. 서버에 터미널이 없으면
  프롬프트는 실패로 끝난다. 그 실패를 Keeper 가 어떻게 보고 다음 후보로 넘어갈지는 별개다.
