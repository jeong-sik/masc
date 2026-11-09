---
rfc: "microvm-guest-agent-over-socket"
title: "microVM 게스트에 상주 agent 를 두고 요청을 unix 소켓으로 보내요 — container exec 를 요청마다 부르지 않으려고"
status: Active
created: 2026-11-03
updated: 2026-11-09
author: claude
related: ["0395", "0405", "0427"]
---

# microVM 게스트에 상주 agent 를 두고 요청을 unix 소켓으로 보내요

## 0. 먼저 정할 것

이 설계는 Apple Keeper VM 의 실행 옵션을 바꿔요. 구현 전에 운영자가 정해야 해요.

- `--publish-socket` 의 relay 는 **컨테이너 rootfs 위의 소켓에만** 닿아요. tmpfs, 볼륨, 호스트 디렉터리 마운트 위의 소켓에는 닿지 않아요(4.2).
- 지금 Keeper VM 은 `--read-only` 라서 rootfs 에 소켓을 만들 수 없어요.
- 그래서 VM 을 쓰기 가능한 rootfs 로 띄워요. agent 가 root 로 시작해서 소켓을 만든 직후 `/` 를 읽기 전용으로 다시 마운트하고, Keeper uid 로 내려가요(3.2). 측정에서 그 뒤 Keeper uid 의 rootfs 쓰기는 `Read-only file system` 으로 막혔어요.
- 바뀌는 실행 옵션: `--user <uid>:<gid>` 는 `--user 0:0` 이 되고 `--read-only` 가 빠져요. `--cap-drop ALL` 뒤에 `CAP_SETUID`, `CAP_SETGID`, `CAP_SYS_ADMIN` 이 더해져요. 이 capability 는 agent 가 내려가면서 사라져요. 하지만 bounding set 에는 남아요. 그래서 agent 가 모든 자식에 `no_new_privs` 를 걸어요.

이 변경을 받아들이지 않으면 5절의 두 대안 중 하나를 골라요.

**결정(2026-11-03):** 운영자가 이 실행 옵션 변경을 받아들였어요. Claude Code 세션의 0절 질문에 "ok" 로 답했고, 같은 날 이 RFC 를 #47809 로 병합했어요(03:59Z).

## 1. 문제

Apple container 의 microVM Keeper 는 도구를 한 번 쓸 때마다 `container exec -i` 를 한 번 불러요. 이 경로에 Apple 쪽 문제가 둘 있어요.

1. **pipe 누수.** `container exec -i` 한 번마다 호스트의 `container-runtime-linux` 가 pipe 끝 하나를 닫지 않아요.
   쌓이면 이 Mac 의 새 pipe 가 512 바이트로 고정되고, 출력이 512 바이트를 넘는 프로세스는 읽는 쪽이 조금만 늦어도 잘려요.
   - 2026-11-03 10:38 KST: 짝 없는 pipe 9,529개, 새 pipe 용량 512 바이트(6/6).
   - 같은 날 09:26 KST 부터 `sonnet-500k-then-glm` 레인 Keeper 10명이 `auth status: invalid JSON ... (stdout 512 bytes)` 로 턴을 실패했어요(로그 267줄).
2. **전체 exec 정지.** 게스트 runtime 하나가 멈추면 apiserver 전역 락 때문에 모든 게스트의 exec 가 멈춰요(#46602). 10-28~10-29 에 세 번 있었고, 세 번 모두 runtime 로그에 `failed to close stdin ... CancellationError` 가 먼저 찍혔어요.

apple/container #1928 과 #2060 을 함께 적용한 빌드는 누수를 0 으로 만들었어요. 두 PR 은 11-03 에도 열려 있고, 최신 릴리스는 1.6.1 이에요.
그 빌드는 손으로 띄운 것이라 원본으로 돌아갔어요. #46602 의 정지 세 번은 모두 그 빌드로 돌던 때 났고, 빌드가 원인인지는 밝히지 못했어요.

## 2. 지금 구조

- 요청 하나는 `container exec -i <guest> masc-exec-shim` 한 번이에요 (`keeper_turn_sandbox_runtime.ml` 의 `build_microvm_endpoint`, `Keeper_sandbox_microvm.shim_exec_prefix_for ~stdin:true`).
  같은 prefix 가 `--env HOME=/tmp`, `--env MASC_EXEC_SHIM_CONFIG=...`, `-w /masc-work`, `--user <uid>:<gid>` 를 줘요.
- 호스트는 `Process_eio.run_argv_with_stdin_held_open_and_status_split` 로 transport 프로세스를 띄워요 (`keeper_sandbox_remote.ml`).
  stdin 에 요청 프레임을 쓰고 열어 둬요. 받는 것은 종료 상태, stdout, stderr(수락 프레임 + payload stderr + trailer)예요. 출력은 오는 대로 콜백으로 넘겨요.
- shim 은 stdin EOF 를 취소로 보고 payload 프로세스 그룹을 죽여요 (`exec_shim.ml` 의 `start_kill On_eof`).
- 요청 데이터(환경 변수와 인증 정보 포함)는 argv 에 싣지 않아요.
- Apple backend 의 stdin 사용처는 셋이에요. shim 요청, build link 적용(`build_link_apply_request_for`, Keeper uid), build 디렉터리 생성(uid 0)이에요.
- Apple 게스트는 `requested_apple_plan` 으로 떠요. 첫 명령은 `tail -f /dev/null` 이고 `--read-only`, `--tmpfs /tmp`, `--cap-drop ALL`, `--rm` 이 붙어요 (`keeper_microvm_backend.ml` 의 `run_constraint_argv`).
- shim 바이너리는 호스트의 고정 경로를 읽기 전용으로 마운트해요. 그래서 바이너리를 새로 깔면 다음 요청부터 새 shim 이 돌아요.

## 3. 제안

### 3.1 통로

VM 을 `--publish-socket <호스트 경로>:<게스트 경로>` 로 띄워요. 호스트가 그 경로에 접속하면 runtime 이 게스트의 unix 소켓으로 이어 줘요. apiserver 와 XPC 를 지나지 않아요.

### 3.2 게스트 agent 의 시작

agent 는 VM 의 첫 명령이에요(`masc-exec-shim --serve <게스트 소켓 경로>`). 순서가 중요해요.

1. root 로 시작해서 root 전용(0700) 디렉터리에 소켓을 만들어요.
2. `/` 를 읽기 전용으로 다시 마운트해요(`MS_REMOUNT | MS_RDONLY`).
3. Keeper uid·gid 로 내려가고(`setgroups`, `setgid`, `setuid`) `no_new_privs` 를 걸어요. uid 0 에서 다른 uid 로 바꾸면 Linux 가 capability 를 지우고 `dumpable` 을 0 으로 바꿔요.
4. 이 결과(다시 마운트 성공, uid, `no_new_privs`)를 hello 에 담아 보내요. 하나라도 틀리면 호스트는 그 게스트를 쓰지 않아요.

payload 는 Keeper uid 로 돌고, 소켓 디렉터리에 들어갈 수 없어요. 그래서 소켓을 지우거나 바꿔 치울 수 없어요(4.3).
agent 는 PID 1 이라 고아 프로세스를 거둬야 해요. `--init` 은 쓰지 않아요. agent 가 죽으면 VM 이 끝나고(`--rm`), 진행 중 요청은 모두 transport 실패가 돼요. masc 의 게스트 수명 경로가 VM 을 다시 띄워요.

### 3.3 연결 하나, 요청 하나

- agent 는 relay 일 뿐이에요. 연결마다 마운트된 `masc-exec-shim` 을 자식으로 실행해요. shim 을 새로 깔면 지금처럼 다음 요청부터 새 shim 이 돌아요.
- 자식의 환경과 작업 디렉터리는 지금 exec prefix 가 주는 값과 같게 맞춰요(`HOME`, `MASC_EXEC_SHIM_CONFIG`, `/masc-work`).
- 연결에서 읽은 바이트는 자식 stdin 으로 보내요. 연결이 끊기면 자식 stdin 을 닫아요. 지금의 "stdin EOF = 취소"가 그대로 동작해요.
- 자식 stdout·stderr 는 오는 대로 연결로 보내요. 연결이 끊긴 뒤에도 자식 출력은 끝까지 읽어서 버려요. 그래야 shim 이 쓰다 막히지 않고 EOF 와 deadline 을 봐요.
- agent 가 여는 fd 는 모두 close-on-exec 이에요. 동시에 도는 자식끼리 서로의 pipe 끝을 물려받으면 EOF 취소가 깨져요.

### 3.4 연결 위 형식

- agent → 호스트, 연결 직후: hello 덩어리. relay 형식 버전, 3.2 의 결과를 담아요.
- 호스트 → agent: 종류 1바이트(요청 / probe) 뒤에 지금의 요청 프레임을 그대로 보내요. probe 는 agent 가 `masc-exec-shim --probe` 를 실행해서 그 출력을 돌려줘요.
- agent → 호스트: `[종류 1바이트][길이 4바이트, big-endian][내용]` 덩어리. 종류는 stdout, stderr, 종료예요. 종료 덩어리에 자식의 종료 코드 또는 시그널 번호를 담아요.
- 종료 덩어리 없이 연결이 끝나면 transport 실패예요.

### 3.5 호스트 쪽

- `Keeper_sandbox_remote.transport` 의 microVM 레인(`Microvm`)은 전달 방식(`delivery`)을 가져요. 요청마다 `container exec` 를 하나 띄우는 지금 방식이 `Exec_per_request`, agent 소켓이 `Agent_socket of { host_socket; expected }` 예요. 레인만 보는 곳(작업 경로, 경로 바꾸기, 파일 쓰기 대상)은 전달 방식을 보지 않아요. masc 서버가 Eio 로 agent 에 직접 접속해요.
- 덩어리를 나눠 지금과 같은 `(종료 상태, stdout, stderr)` 와 chunk 콜백을 만들어요. 수락 프레임 처리, trailer 대조, 경로 바꾸기는 그대로예요.
- 호스트 쪽 시간 초과는 연결을 닫고 `WEXITED 124` 로 돌려줘요. 지금 `Process_eio` 가 시간 초과를 돌려주는 방식과 같아요.
- 첫 요청 전에 hello 를 받아야 해요. 게스트의 첫 요청은 첫 handoff 정리라서, agent 가 아직 안 떴을 때 끊긴 연결을 "결과 모름"으로 읽으면 안 돼요.
- hello 에는 기한을 둬요. agent 가 듣기 전에 연 연결은 바로 끝나기도 하고, 드물게 아무것도 오지 않은 채 남기도 해요(4.4). 기한 안에 hello 가 오지 않으면 그 연결을 닫고 새로 연결해요. hello 전에는 아무것도 보내지 않으므로 다시 연결해도 요청이 두 번 돌지 않아요.

### 3.6 boot plan 과 붙이기(attach)

- `Keeper_microvm_boot_plan` 의 사실에 `publishedSockets`, `useInit`, relay 형식 버전을 더해요. `container inspect` 는 `--init` 을 명령 줄이 아닌 `useInit` 필드로 보여 줘요(4.2). 그래서 지금의 명령 줄 비교는 그대로 둬요.
  - relay 형식 버전은 agent plan 의 안정 라벨(`masc.mcp.agent_relay`)로 digest 에 들어가요. 다른 버전을 말하는 서버는 게스트를 붙이지 않고 교체해요.
- plan 이 달라지면 `assess` 가 교체를 허용해요. 서버 재시작 뒤 붙이는 경로(attach)는 `assess` 를 거치지 않아요. 그래서 붙일 때 hello 를 읽고, agent 가 없거나 형식 버전이 다르면 타입이 있는 오류로 교체를 요청해요.
  - 턴 시작 판정이 `Matches_plan` 이어도 plan 은 agent 를 보지 못해요. agent guest 는 붙이기 전에 agent 에 probe 를 한 번 보내요. hello 가 없거나 거절되거나 probe 가 0 으로 끝나지 않으면 붙이지 않고 교체해요. 물어보지도 못했으면(Eio 밖, 잘못된 예산) 교체하지 않고 오류로 멈춰요.
  - 턴 없이 붙는 쪽(읽기, 상태)은 게스트 inspect 의 `publishedSockets` 로 전달 방식을 정해요. TOML 을 바꿨는데 아직 교체 전인 게스트도 부팅된 방식대로 읽어요. 게스트를 읽지 않는 snapshot 경로만 TOML 의 선택을 따라요.
- 첫 프로세스는 `--user 0:0` 으로 띄워요. `--user` 를 빼면 이미지의 기본 사용자로 뜨는데, 그 값에 기대지 않으려는 거예요. inspect 의 `userString` 은 `"0:0"` 이라 plan 과 그대로 비교돼요(4.5).
- 호스트 소켓 경로는 base path 와 게스트 이름에서 정해요. 붙이기(attach)가 이름만으로 endpoint 를 다시 만들기 때문이에요. TMPDIR 같은 프로세스 환경에는 기대지 않아요.
  - 경로는 `<base>/.masc/microvm/agent/<게스트 이름 SHA-256 앞 16자>.sock` 이에요. 게스트 이름은 63자까지라, 이름을 그대로 쓰면 `/Users/<사용자>/me` 아래에서도 105바이트가 돼요.
  - 디렉터리는 서버 uid 만 쓰는 0700 이에요. 소켓에 붙을 수 있는 프로세스는 그 게스트의 agent 에게 Keeper 로 요청을 돌리게 할 수 있어서예요.
  - macOS 의 unix 소켓 경로는 103바이트까지예요. 넘으면 VM 을 띄우지 않고 타입이 있는 오류로 거절해요. 1.6.1 은 112바이트 경로를 받아 놓고 부팅 단계에서 실패했어요(4.5).
  - VM 이 끝나면 runtime 이 소켓 파일을 지워요. 남은 소켓 파일은 VM 이 정상적으로 끝나지 못했을 때만 생기고, 그 파일이 있으면 `container run` 이 실패해요(4.5). 그래서 같은 이름의 게스트가 없을 때만, 부팅 직전에 남은 소켓 파일을 지워요.

### 3.7 stdin 을 쓰던 나머지 두 호출

build link 적용과 build 디렉터리 생성은 경로 목록만 넘겨요. 비밀이 아니므로 `-i` 없이 argv 로 넘겨요. build 디렉터리 생성은 uid 0 이어야 해서 agent(Keeper uid)로 보낼 수 없어요.

### 3.8 Observe 상자

Observe 상자는 `socket(2)` 를 모든 주소 체계에서 막아요(`observe_stub.c` 의 `deny_sockets`). 하지만 io_uring 의 `IORING_OP_SOCKET` 은 그 필터를 지나요.
agent 소켓은 root 전용 디렉터리에 있어서 Keeper uid 는 경로로 닿지 못해요. 그래도 같은 VM 안에 요청을 받는 프로세스가 생기므로, Observe 필터에 `io_uring_setup`·`io_uring_enter`·`io_uring_register` 거부를 먼저 더해요. 게스트 커널이 io_uring 을 켜 두었는지는 아직 확인하지 않았어요.

### 3.9 옮기는 순서

1. `Agent_socket` 전달 방식을 Keeper 별 선택으로 더해요. canary 동안에만 두 경로가 같이 있어요. 되돌리기는 그 Keeper 의 선택을 원래대로 바꾸는 거예요.
   - 선택은 Keeper TOML 의 `microvm_delivery` 예요(`exec_per_request` 가 기본, `agent_socket`). `sandbox_profile = "microvm"` 이고 `microvm_backend = "apple_container"` 일 때만 `agent_socket` 을 받아요. backend 를 적지 않은 Keeper 는 호스트 기본 backend 로 뜨지만, 그 값은 TOML 을 읽은 뒤에 정해져서 이 검사가 보지 못해요. 그래서 그런 Keeper 도 backend 줄을 적어요.
   - 턴마다 게스트를 다시 판정하면서 TOML 을 읽어요. 값을 바꾸면 다음 턴에 plan 이 달라져 게스트가 교체돼요.
2. canary 기준(7절)을 넘으면 나머지 Apple Keeper 를 옮겨요.
3. 모두 옮기면 선택 값과 Apple 의 `Exec_per_request` 전달 방식을 한 PR 에서 지워요. Microsandbox·Nerdctl_kata 는 `Exec_per_request` 그대로예요(3.10, 사용자 결정 2026-11-09). 그 뒤 되돌리기는 그 PR 의 revert 예요. 진행 상황은 10절에 있어요.

### 3.10 바뀌지 않는 것

VM 생성·삭제·조회와 볼륨 작업은 `container` CLI 로 해요(`-i` 없음). `Openssh`, `Docker_exec` transport, Microsandbox·Nerdctl_kata backend 는 그대로예요.

## 4. 측정 (2026-11-03, Apple container 1.6.1 원본)

조건, 스크립트, 원본 결과는 [측정 기록](../evidence/2026-11-03-microvm-request-transport/README.md)에 있어요.

### 4.1 통로별 누수와 지연

| 통로 | 남은 pipe | 왕복 p50 | 비고 |
|---|---|---|---|
| `container exec -i` (지금) | 호출마다 +1 (20/20) | 173ms | 대조군 |
| `container exec` (`-i` 없음) | 0 / 50 | 195ms | |
| SSH (`-p` publish) | 0 / 250 | 98ms | `--network none` 에서 접속 거부 |
| `--publish-socket`, rootfs 위 agent | 0 / 121 (배치 넷 각각), 전체 fd 48 → 48 | 0.5~3.4ms | 프로세스를 띄우지 않는 왕복이라 위 줄들과 바로 비교할 수 없음 |
| msb `exec --stream` | 변화 없음 / 90 | 45~51ms | 누수 대조군 없음 |

### 4.2 relay 가 닿는 곳

| 게스트 소켓 위치 | 결과 |
|---|---|
| rootfs (하위 디렉터리 포함, `--cap-drop ALL --rm` 포함) | 닿음 |
| `--tmpfs` 위 (`/tmp`, `/run`) | 닿지 않음. agent 가 연결을 받지도 못함 |
| 이름 붙은 볼륨 위 | 닿지 않음 |
| 호스트 디렉터리 마운트 위 | 닿지 않음 |

`--init` 을 주면 `container inspect` 의 `initProcess` 는 그대로이고 `useInit: true` 만 바뀌어요.

### 4.3 agent 배치와 가로채기

모두 rootfs 위 소켓, `--cap-drop ALL`, `--rm`. 각 배치에서 순차 100번, 동시 20개, 60초 대기 요청 1번이 모두 맞게 돌아왔어요. 가로채기는 Keeper uid 로 `container exec -d` 해서 소켓을 지우고 같은 경로에 가짜 리스너를 묶는 시도예요.

| 배치 | `--tmpfs /tmp` | Keeper uid 의 rootfs 쓰기 | 가로채기 | 그 뒤 요청에 답한 쪽 |
|---|---|---|---|---|
| agent 가 Keeper uid, 소켓도 Keeper uid 디렉터리 | 없음 | 재지 않음 | 성공 | 가짜 |
| root 로 묶고 502 로 내려감 | 없음 | 재지 않음 | 권한 거부 | 진짜 |
| root 로 묶고 502 로 내려감 | 있음 | 됨 (`/var/tmp`) | 권한 거부 | 진짜 |
| 위 + 묶은 직후 `/` 읽기 전용 재마운트 | 있음 | `Read-only file system` | 권한 거부 | 진짜 |

agent 가 내려간 뒤 `dumpable` 0, `no_new_privs` 1 을 읽었어요. capability 가 사라지는 것은 uid 0 에서 다른 uid 로 바꿀 때의 Linux 동작이고, 이번에 직접 읽지는 않았어요.

### 4.4 실제 agent

구현 3층의 `masc-exec-shim --serve` 를 0절 실행 옵션으로 띄우고, 호스트에서 소켓으로 실제 shim 요청을 보냈어요.

- hello 는 `/` 읽기 전용, uid 502, gid 20, `no_new_privs` 를 알렸어요. payload 도 같은 uid·gid 였고 CapEff·CapPrm·CapInh·CapAmb 0, NoNewPrivs 1 이었어요. 바운딩 셋에는 0절의 세 capability 가 남아 있었어요. agent 의 보조 그룹은 비어 있었어요.
- agent(PID 1)의 fd 는 0·1·2 와 리스너뿐이었어요. agent 는 그래도 시작할 때 3 이상의 fd 를 모두 close-on-exec 로 표시해요.
- payload 의 rootfs 쓰기, 소켓 디렉터리 읽기, agent 소켓 연결, agent 의 fd 목록 읽기는 모두 거부됐어요. `/tmp` 와 작업 디렉터리 쓰기는 됐어요.
- 요청 50번 동안 runtime 의 짝 없는 pipe 는 0 → 0 이었어요(두 실행). 틀린 응답은 없었어요.
- 요청 도중 연결을 끊으면 payload 가 취소됐어요.
- agent 가 듣기 전에 연 연결: 부팅 10번에서 hello 5번, 바로 EOF 4번, 12분 동안 아무것도 오지 않음 1번이었어요. 첫 hello 뒤에는 두 실행에서 54개씩, 다시 연결할 일이 없었어요.

### 4.5 agent 실행 옵션

masc 가 그리는 모양 그대로(`--entrypoint <shim>`, 인자 `--serve <게스트 소켓> 502:20`) 띄웠어요. 1.6.1, 경우마다 새 VM.

- `--user 0:0` 이면 `userString` 이 `"0:0"`, 빼면 `"root"` 예요. 두 경우 모두 hello 가 왔어요.
- inspect 의 `capAdd` 는 넘긴 이름 그대로(`CAP_SETUID`, `CAP_SETGID`, `CAP_SYS_ADMIN`), `capDrop` 은 `ALL`, `readOnly` 는 `false`, `publishedSockets` 는 `[{containerPath, hostPath}]`, `useInit` 은 `false` 예요. 지금 Keeper VM 도 `publishedSockets: []`, `useInit: false` 를 담고 있어요.
- 호스트 경로에 소켓 파일이 남아 있으면 `container run` 이 `already exists and may be in use` 로 실패해요. 일반 파일은 덮어쓰고, 없는 부모 디렉터리는 만들어요.
- VM 이 끝나면 성공한 네 경우 모두 소켓 파일이 지워졌어요.
- 112바이트 호스트 경로는 `container run` 이 받았다가 부팅 단계에서 `too long for a Unix Domain Socket path` 로 실패했어요.
- masc 의 렌더러가 agent plan 으로 그린 실행 옵션을 그대로 넘겨 띄운 게스트를, masc 의 inspect 파서와 판정이 `Matches_plan` 으로 읽었어요(차이 0, plan 라벨 일치). 그 inspect 는 테스트 fixture 로 남겼어요.
- 호스트 소켓과 마운트 경로를 심볼릭 링크 디렉터리를 거쳐 줘도, inspect 는 링크를 풀지 않고 받은 문자열 그대로 보고했어요.

## 5. 검토한 대안

| 대안 | 판단 |
|---|---|
| A. `-i` 를 빼고 요청을 VM 별 읽기 전용 디렉터리의 파일로 넘긴다 | 실행 옵션을 바꾸지 않아요. 누수도 없어요(`-i` 없는 exec 50번 0). 하지만 요청마다 apiserver 와 그 전역 락을 지나고(p50 195ms), `container exec` 클라이언트를 SIGKILL 해도 게스트 프로세스가 남아요(10-28 다른 세션 측정, `-i` 없는 exec, 1.3.1·1.6.1). 그래서 취소 표식 파일이 따로 필요해요. 인증 정보가 든 요청 파일을 호스트가 요청마다 지워야 하고, 이름을 다시 쓰면 1초쯤 `No such file` 이 나요(10-28 측정). 0절의 실행 옵션 변경을 받아들이지 않으면 이 안이 다음 후보예요. |
| B. microVM backend 를 msb 로 바꾼다 | exec 가 게스트 agent 로 가는 구조라 누수가 안 보였고(90번), 45ms 예요. 하지만 beta 이고(설치 0.6.16, 최신 0.7.13), 09-04 시험에서 Keeper 가 뜨지 않았어요(RFC-0405 후기). 이미지와 work volume 도 옮겨야 해요. 따로 비교할 일이에요. |
| SSH 로 게스트에 들어간다 | `--network none` 인 Keeper(11-03 기준 10명)에 닿지 않아요. Keeper 이미지에 sshd 와 uid 502 passwd 항목이 없어요. |
| #1928·#2060 을 적용한 container 를 계속 쓴다 | upstream 이 병합하지 않은 빌드를 업그레이드와 재부팅마다 다시 깔아야 해요. 그 빌드로 돌던 때 #46602 정지가 세 번 났고 원인은 밝히지 못했어요. |
| VM 을 주기적으로 다시 띄운다 | 낮에는 몇 분짜리 완화였어요(10-28). 원인은 그대로예요. |

## 6. 남은 질문

1. **`--cap-add` 를 쓴 VM 에서 masc 가 직접 하는 `container exec`.** 이 프로세스는 agent 를 거치지 않아서 NoNewPrivs 가 0 이에요. root 로 돌면 CapEff 가 `0x2000c0` 이고, Keeper uid 로 돌아도 bounding set 에 그 셋이 남아요(측정 기록의 `exec-caps-results.json`).
   - 두 이미지에 `su`·`mount` 같은 setuid root 파일이 있어요. 이번 측정에서 uid 502 가 root 가 되는 길은 없었어요.
   - ocaml 이미지의 `opam`(uid 1000)은 비밀번호 없는 sudo 를 가져요. 호스트 uid 가 1000 이면 그 Keeper 의 exec 프로세스가 root 가 되고, agent 모양에서는 SYS_ADMIN 도 가져요.
   - 그래서 agent 모양 게스트에서 Keeper 명령은 agent 로만 보내요. payload 는 `container exec` 를 부를 수 없어요.
   - masc 가 직접 하는 exec 는 일곱 곳이에요(빌드 스캔·링크·디렉터리, 작업 볼륨 권한, 작업 디렉터리 생성·마운트 확인·쓰기 확인). 그중 넷이 root 예요. 이 명령들이 Keeper 가 만든 파일에 휘둘리지 않는지는 6층에서 다시 봐요.
2. **장시간 relay.** 이번 측정은 VM 하나에 몇 분이에요. 하루 부하에서 runtime 의 fd 가 늘지 않는지는 canary 에서 재요.
3. **runtime 이 멈출 때.** #46602 처럼 게스트 runtime 이 멈추면 relay 도 멈출 수 있어요. 요청이 apiserver 전역 락을 지나지 않으니 다른 게스트로 번지지 않을 것으로 보지만, 재 보지 않았어요.
4. **lane add-on.** `lane_addon_engine.ml` 도 Apple 컨테이너를 `--interactive` 로 만들고 `start --attach --interactive` 로 띄워요. 같은 누수 경로인지는 따로 재요.

## 7. 검증 계획

1. 시험 VM: Keeper 이미지 + 실제 shim agent 로 요청 왕복, Observe·Effect 상자, 취소(연결 끊기), 동시 20개, 1,000번 동안 runtime 의 전체 fd 와 짝 없는 pipe 가 늘지 않음, 가로채기 시도가 막힘.
2. 테스트 하네스: `test/keeper_guest_survival_runtime/` 의 가짜 `container` 는 `exec` 만 흉내 내요. `--publish-socket` 과 hello 를 흉내 내게 고쳐요.
3. canary: Apple microVM Keeper 하나를 새 경로로 24시간. 기준은 셋이에요.
   - 그 VM runtime 의 전체 fd 와 짝 없는 pipe 가 늘지 않아요.
   - 요청 timeout 비율이 같은 기간 다른 Keeper 보다 높지 않아요.
   - 도구 실행 p50 이 지금보다 길지 않아요.
4. 나머지로 넓히고, 모두 옮긴 뒤 새 pipe 용량이 65,536 바이트로 돌아오는지 봐요(측정 기록의 `bin/pipeleak.py once` 의 `bigwrite`).

## 8. 범위 밖

- Apple 쪽 수정과 upstream 보고.
- 512 바이트로 잘린 출력을 받아들이는 처리.
- claude_code 턴 전 `auth status` 확인이 실패했을 때 레인이 다음 후보로 넘어가는 문제는 #47805 에서 고쳐요.

## 9. 근거

- 측정 기록: `docs/evidence/2026-11-03-microvm-request-transport/`
- 정지 사고: #46602
- 레인 분류: #47787, #47805
- apple/container PR #1928 "Fix XPC file handle ownership", #2060 "Reap completed exec host state in the Linux runtime helper" (11-03 확인 시 둘 다 open)

## 10. 진행 상황 (2026-11-09)

### 10.1 옮기는 순서(3.9)

1. 1단계는 2026-11-03 에 병합했어요. canary 는 7.3 결과대로예요.
2. 2단계: 라이브 Keeper TOML 34개 중 microVM Keeper 20개가 모두 `microvm_backend = "apple_container"`, `microvm_delivery = "agent_socket"` 이었어요(2026-11-09 읽기).
3. 3단계: 선택 값(`microvm_delivery`)과 Apple 의 `Exec_per_request` 를 지웠어요.
   - 전달 방식은 backend 가 정해요(`Keeper_microvm_backend.request_delivery`). Apple 은 `Guest_agent`, Microsandbox·Nerdctl_kata 는 `Exec_per_request` 예요.
   - `Keeper_sandbox_microvm.shim_exec_prefix_for` 는 `Keeper_microvm_backend.exec_runtime`(Microsandbox·Nerdctl_kata)만 받아요. Apple 용 exec 접두사는 만들 수 없어요.
   - Apple 게스트는 언제나 agent plan 으로 떠요. 붙이기(attach)는 게스트가 agent 소켓을 publish 하지 않으면 `microvm_agent_not_published` 로 거절해요. 그런 게스트는 plan 이 달라서 그 Keeper 의 다음 턴이 새 게스트로 바꿔요.
   - 키가 남은 TOML 은 다른 모르는 키처럼 load 오류예요(`unknown keeper TOML keys`).

### 10.2 검증 계획(7절) 결과

- 7.2 테스트 하네스: 아직이에요. `test/keeper_guest_survival_runtime/` 의 가짜 `container` 는 `--publish-socket` 을 inspect 에 옮기지만 hello 와 요청 relay 는 흉내 내지 않아요. 3단계 뒤 이 하네스의 Apple 게스트는 요청을 받지 못해요.
- 7.3 canary(#49316 본문): e-masc-the-leader 한 명을 2026-11-05 10:29Z 부터 24시간 37분 새 경로로 돌렸어요. 요청은 모두 소켓으로 갔어요.
  - 기준 1(fd·pipe): 그 VM runtime 의 짝 없는 pipe 가 1 에서 11 로 늘었어요. 늘어난 10개는 서버 부팅 뒤 첫 dispatch 10번과 시각이 맞아요. 부팅마다 한 번 도는 build 디렉터리 생성의 `container exec -i` 였고, #49316(2026-11-07 병합)이 `-i` 를 뺐어요. Execute 127건이 있던 10분 창 54개에서는 늘지 않았어요. 같은 기간 옛 경로 VM 은 Execute 한 번에 1.1~2.2개씩 늘었어요(pr-updater +254, github-pr-checker +378).
  - 기준 2(timeout): canary Execute 의 timeout 은 0건이에요.
  - 기준 3(p50): Execute p50 이 전 2,164ms(n=305)에서 뒤 2,208ms(n=137)로 44ms 길었어요. 기준을 글자 그대로 넘지는 못했어요. 이 차이가 잡음인지는 따로 보지 않았어요.
  - #49316 의 "배포 뒤" 재측정(서버 재시작 전후의 canary pipe)은 이 저장소에 기록이 없어요. 2026-11-09T09:23:29Z 에 같은 VM runtime 의 짝 없는 pipe 는 15개였어요. 11 에서 늘어난 원인은 나눠 보지 않았어요.
- 7.4 pipe 용량: 2026-11-09T09:23:29Z 에 `bin/pipeleak.py once` 의 `bigwrite` 가 65,536 바이트였어요.
  - 그때 agent 소켓을 publish 하지 않는 옛 게스트가 둘 떠 있었어요(2026-11-02 부팅, 짝 없는 pipe 220개·109개). 두 Keeper 의 TOML 은 이미 `agent_socket` 이었지만 게스트는 그대로였어요.
