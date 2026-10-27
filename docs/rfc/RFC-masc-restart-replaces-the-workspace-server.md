---
rfc: "masc-restart-replaces-the-workspace-server"
title: "masc restart 는 떠 있는 서버를 정상 종료시키고 그 자리에 설치된 빌드를 띄운다"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: claude
related: ["0447", "0420"]
---

# masc restart 는 떠 있는 서버를 정상 종료시키고 그 자리에 설치된 빌드를 띄운다

## 1. 문제

새 빌드를 깔고 서버를 바꾸는 일을 한 명령으로 할 수 없다. 2026-10-27 11:00 KST 운영자 터미널에서 실제로 이렇게 했다.

1. `scripts/install-local-build.sh` 가 `~/.local/bin/masc` 를 새 빌드로 바꾼다.
2. `masc start` 는 `[FATAL] Base path /Users/dancer/me is locked. The lease records PID 45284 …` 를 찍고 바로 끝난다. 같은 문구가 "기록된 PID 에 시그널을 보내지 말라" 고 한다.
3. 운영자는 결국 `kill 45284` 를 네 번 쳤다. SIGTERM 을 받은 서버는 정리하는 동안 살아 있어서(`lib/shutdown.ml:28` `force_timeout_s = 10.0`) `kill` 이 계속 성공했다. 다 끝난 뒤에야 `no such process` 가 나왔다.
4. `nohup masc start > ~/me/.masc/logs/masc-start-$(date +%m%d-%H%M).log 2>&1 < /dev/null & disown` 으로 다시 띄웠다. 새 서버가 떴는지는 따로 확인해야 했다.

이미 있는 경로들은 이 일을 하지 못한다.

| 경로 | 하는 일 | 못 하는 이유 |
|---|---|---|
| `masc setup-stop-previous-owner` | 로그인과 lease 주인 확인을 거쳐 SIGTERM 을 한 번 보낸다 | `masc setup` 마법사 안에서만 쓰고, `--expected-version` 을 받아야 한다. 0.2초씩 25번(5초)만 보고 끝나서 10초 정리를 다 기다리지 못한다. 새 서버는 띄우지 않는다 |
| `scripts/masc-supervisor-control.sh` | 스크립트로 띄우고 멈춘다 | `start-masc.sh` 를 거쳐 체크아웃을 소스에서 빌드해 띄운다. 설치한 `~/.local/bin/masc` 를 쓰지 않는다. 다시 띄우는 명령이 없다 |
| `scripts/deploy.sh`, `scripts/stop-prod.sh` | 8945 포트를 PID 파일로 관리한다 | 운영 서버는 8935 하나다. 8945 에는 아무것도 없고 PID 파일도 없다 |

## 2. 설계

### 2.1 명령

```
masc restart [--base-path PATH] [--port PORT] [--host HOST] [--agent AGENT] [--log FILE]
```

base path·port·host 는 `masc start` 와 같은 방식으로 정한다. 코드는 `bin/masc_cli_restart.ml` 이다. 앞 서버와 새 서버 둘 다 `127.0.0.1` 로 확인하므로, 그 주소로 닿지 않는 `--host`(127.0.0.1·0.0.0.0 밖)는 아무것도 하기 전에 거절한다. `localhost` 같은 이름도 IP 주소가 아니라서 새 서버가 bind 할 수 없으므로 같은 자리에서 거절한다.

1. **떠 있는 것을 본다.** `127.0.0.1:<port>/health?full=1` 을 읽는다.

   | 관측 | 동작 |
   |---|---|
   | 이 workspace 의 서버가 답한다 | 2 로 간다 |
   | 다른 workspace 의 서버가 답한다 | 거절한다. 아무것도 멈추거나 띄우지 않는다 |
   | 답은 오는데 masc identity 가 아니다 | 거절한다 |
   | 답이 없고 lease 주인도 없고 포트가 비어 있다 | 멈출 서버가 없다. 3 으로 간다 |
   | 답이 없는데 lease 주인이 있다 | 거절한다. 인증된 종료 요청을 보낼 길이 없다. 정리 중이면 끝난 뒤 다시 하라고 알린다 |
   | 답이 없는데 포트를 누가 잡고 있다 | 거절한다 |

2. **종료를 한 번 요청한다.** setup 의 stop 과 같은 함수(`Masc_cli_owner_upgrade.with_selected_owner`)를 쓴다. 로그인 → 관리자 토큰으로 `/api/v1/runtime/config/raw` 확인 → `capture_existing_owner` 가 F_GETLK 로 lease 주인을 잡음 → identity 를 다시 확인 → `Owner_process_identity.request_termination` 이 SIGTERM 을 한 번 보낸다. SIGKILL 은 없다. 버전 확인 값은 1 에서 읽은 값이다.
3. **새 서버를 띄운다.** `Posix_spawn_detached.spawn` 으로 `<이 실행 파일> start --wait-for-previous-owner --base-path B --port P --host H` 를 띄운다. 2 에서 아무것도 멈추지 않았으면 플래그 없는 `start` 를 띄운다. 그 사이 누가 lease 를 잡았다면 종료를 요청받지 않은 진짜 주인이라 기다리면 안 된다. 새 서버는 자기 프로세스 그룹에서 돌고, stdin 은 `/dev/null` 이다. stdout·stderr 는 로그 파일에 덧붙인다. 기본 로그는 `<base>/.masc/logs/masc-start-<UTC 시각>.log` 이고, 종료 요청 뒤에 연다. 그래서 거절된 restart 는 빈 로그를 남기지 않는다.
4. **새 서버는 lease 를 기다린다.** 2.2 에 적었다. 앞 서버가 끝나 descriptor 가 닫히는 순간 커널이 잠금을 넘긴다. 잠금이 비는 틈이 없어서 그 사이에 다른 프로세스가 끼어들 수 없다.
5. **준비될 때까지 본다.** `/health/ready` 가 200 이고 응답의 `pid` 가 3 에서 띄운 pid 와 같으면 준비된 것이다. 같은 포트에서 정리 중인 앞 서버도 200 을 줄 수 있어서 pid 로 가른다. 응답이 말하는 내용이 바뀔 때마다 한 줄씩 찍는다(`pid A is still answering`, `starting: <phase>`, 거절 사유). 요청마다 HTTP 클라이언트 풀을 새로 쓴다. 공유 풀은 연결이 한 번 실패한 host 를 5초 동안 다시 시도하지 않는데(`lib/masc_http_client/pool.ml` `connect_failure_cooldown_seconds`), 두 listener 사이 틈이 늘 그 실패를 만든다. 새 서버가 먼저 끝나면 종료 상태와 로그 끝 20줄을 보여주고 exit 1 한다.
6. **기한은 없다.** 종료를 요청받은 앞 서버는 자기 watchdog(`force_timeout_s`) 으로 반드시 끝난다. Ctrl-C 는 지켜보기만 멈춘다. 새 서버는 자기 그룹에 있어서 계속 돈다. 3 에서 이 사실과 로그 경로를 먼저 찍는다.

출력은 이렇다.

```
Asked masc 0.64.0 (pid 45284) on port 8935 to stop.
Started pid 8821. Log: /Users/dancer/me/.masc/logs/masc-start-20261027T020139Z.log
Waiting for it to become ready; Ctrl-C stops watching, not the server.
Ready after 14.2 s: masc 0.64.0 (d0c79a5d83a), pid 8821, serving /Users/dancer/me on port 8935.
```

### 2.2 `masc start --wait-for-previous-owner`

- 플래그 없는 `masc start` 는 지금처럼 바로 거절한다. 정상으로 도는 서버는 기다려도 끝나지 않는다. 거절 문구에 `masc restart` 를 더한다.
- 플래그를 주면 `Server_startup_takeover.acquire_base_path_lock_after_owner_exits` 로 lease 를 얻는다. 먼저 `F_TLOCK` 으로 한 번 시도하고, 잡혀 있으면 lease 파일에 적힌 pid 를 로그에 한 줄 남긴 뒤 `lockf F_LOCK` 으로 잠든다. 폴링하지 않는다. 기다리는 쪽은 아무에게도 시그널을 보내지 않는다.
- lease 파일은 앞 서버가 끝나도 지워지지 않는다(`release_base_path_lease` 는 unlock 과 close 만 한다). 그래서 같은 inode 를 기다리면 된다. 잠금을 받은 뒤의 identity 확인은 플래그 없는 경로와 같다.
- 한 workspace 를 기다리는 프로세스는 하나다. 기다리기 전에 lease 옆 `<lease>.waiter` 를 `F_TLOCK` 으로 잡고 자기 pid 를 적는다. 이미 잡혀 있으면 `Another_replacement_waits` 로 바로 끝난다. 이게 없으면 Ctrl-C 뒤 restart 를 한 번 더 했을 때 두 번째 후임이 첫 번째 후임 뒤에 줄을 서고, 나중에 첫 번째 후임이 멈출 때 아무도 부르지 않은 옛 빌드가 서버가 될 수 있다.
- 기다리는 도중 `.masc` 를 만들거나 무엇을 쓰지 않는다. lease 를 받은 뒤에야 기존 기동 순서가 시작된다.

### 2.3 `/health/ready` 의 `pid`

`/health/ready` 의 200·503 응답 둘 다 `pid` 를 싣는다. 이 응답을 읽는 곳(`scripts/install-smoke.sh`, `scripts/check-installed-dashboard.py` 등)은 모두 `ready` 필드만 보므로 필드가 늘어도 깨지지 않는다.

### 2.4 pg_ctl restart 와 다른 점

[`pg_ctl restart`](https://www.postgresql.org/docs/current/app-pg-ctl.html)(2026-10-27 확인)도 멈춘 뒤 띄우고, `-l` 로 로그 파일에 덧붙이고, `-w` 로 준비될 때까지 기다린다. 다른 점은 셋이다.

- pg_ctl 은 멈춤과 준비 둘 다 PID 파일을 짧은 간격으로 다시 읽고, `-t`(기본 60초)가 지나면 포기한다. masc 는 멈춤 쪽을 커널 잠금 대기로 바꿨다. 기한은 앞 서버의 watchdog 이 진다. 준비 쪽은 pg_ctl 처럼 `/health/ready` 를 짧은 간격으로 다시 읽는다.
- pg_ctl 은 앞 인스턴스의 명령줄 옵션을 저장했다가 다시 쓴다. masc restart 는 `masc start` 와 같은 방식으로 base path·port·host 를 새로 정한다. 앞 서버를 다른 `--host` 로 띄웠다면 그 값을 다시 줘야 한다.
- pg_ctl 의 기본 종료(fast)는 클라이언트를 기다리지 않고 끊는다. masc 는 SIGTERM 을 받은 서버의 정상 종료 순서를 그대로 따른다.

### 2.5 지우는 것

겹치는 옛 경로는 같은 스택에서 지운다.

- `scripts/deploy.sh`, `scripts/stop-prod.sh`, 그리고 deploy.sh 만 쓰던 `deployment_preflight_helper` 의 `--prepared-file`.
- `scripts/masc-supervisor-control.sh`, `scripts/start-masc-supervised.sh`, `scripts/start-loopback.sh`, 그리고 supervisor 만 쓰던 `start-masc.sh` 의 LKG 코드와 `scripts/lib/runtime-artifact-contract.sh` 의 해당 부분.

남기는 것: `start-masc.sh` 는 quickstart 가 쓴다. `lease-handoff` 는 컨테이너 진입점이 쓴다. `scripts/check-runtime-deployment-preflight.sh` 는 설치와 릴리스 검사가 쓴다.

## 3. RFC-0447 과의 관계

RFC-0447 §2.3 은 "모든 `masc start` 가 앞 서버가 알린 기한까지 lease 를 기다리고, 종료 요청은 `masc setup` 의 stop 한 곳만 한다" 고 했다. 이 RFC 는 둘을 바꾼다.

- 기다림은 종료를 요청한 뒤에만 뜻이 있다. 그래서 플래그 없는 start 는 바로 거절하고, 기다림은 restart 가 띄우는 `--wait-for-previous-owner` 로만 한다. 기한은 두지 않는다.
- 종료를 요청하는 곳은 setup 의 stop 과 restart 둘이다. 둘 다 `with_selected_owner` 하나를 거친다.

RFC-0447 §2.3·§3·§4·§5 를 이 내용으로 고쳤다.

## 4. 판정 기준

- R1 교체: 이 workspace 의 서버(pid A)가 떠 있을 때 `masc restart` 가 exit 0 이다. 출력에 A 와 새 pid B 가 있다. A 는 SIGTERM 한 번으로 끝나고, B 가 `/health/ready` 200 에 `pid` B 를 준다. B 의 로그에 `Waiting for the previous owner … PID A` 가 한 줄 있다.
- R2 빈 workspace: 서버가 없을 때 종료 요청 없이 띄우고 exit 0 이다.
- R3 다른 workspace: 포트를 다른 workspace 서버가 잡고 있으면 exit 1 이다. 그 서버는 그대로 돌고, 아무것도 띄우지 않는다.
- R4 기동 실패: 새 서버가 준비 전에 끝나면(예: RFC-0420 의 저장소 거부) exit 1 이고 로그 끝부분이 나온다.
- R5 대기 단위 검사: `test_server_startup_takeover` 의 "a waiting start takes the lease when the owner exits". `on_wait` 안에서만 주인에게 끝내라고 알려, 대기가 잠금을 쥔 동안 시작되고 주인이 스스로 끝나는 순간 끝남을 보인다. 주인의 종료 상태가 0 이라 시그널을 받지 않았음도, 받은 lease 를 다른 프로세스가 커널에서 잡지 못함도 보인다.
- R6 두 번째 대기자: 같은 파일의 "a second waiter is refused while one waits". 첫 대기자가 기다리는 동안 두 번째는 첫 대기자의 pid 를 담은 `Another_replacement_waits` 를 받고, 주인이 끝나면 첫 대기자가 lease 를 받는다. waiter 잠금을 빼면 이 검사가 실패한다.
- R7 손이 닿지 않는 host: `--host 10.9.9.9` 는 exit 1 이고 아무것도 멈추거나 만들지 않는다.

## 5. 단계

한 스택이다.

1. 이 RFC 와 RFC-0447 수정.
2. `masc start --wait-for-previous-owner`, `/health/ready` 의 `pid`, 거절 문구. 판정 R5.
3. `masc restart`. 판정 R1–R4.
4. deploy.sh·stop-prod.sh 와 `--prepared-file` 정리.
5. supervisor·start-loopback·LKG 정리.

## 6. 남는 한계

- 준비 확인과 종료 요청은 `127.0.0.1` 로만 묻는다. setup 의 stop 도 같다. 그래서 `::1` 이나 다른 주소에 붙는 서버는 restart 로 바꾸지 못하고 거절된다(RFC-0447 PR-3 범위).
- 읽을 수 없는 `--host` 를 받은 서버가 loopback 에 붙는 버그(#46352)는 #46376 이 따로 고친다. IPv6 `--host` 로 기동하지 못하는 버그는 #46375 다.
- 새 서버는 자기 프로세스 그룹에서 돌지만 같은 session 에 남는다. stdin·stdout·stderr 가 터미널이 아니라서 터미널을 닫아도 영향이 없다.
