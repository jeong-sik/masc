---
rfc: "microvm-guest-agent-over-socket"
title: "microVM 게스트에 상주 agent 를 두고 요청을 unix 소켓으로 보내요 — container exec 를 요청마다 부르지 않으려고"
status: Draft
created: 2026-11-03
updated: 2026-11-03
author: claude
related: ["0395", "0405", "0427"]
---

# microVM 게스트에 상주 agent 를 두고 요청을 unix 소켓으로 보내요

## 1. 문제

Apple container 의 microVM Keeper 는 도구를 한 번 쓸 때마다 `container exec -i` 를 한 번 불러요.
이 호출 경로에 Apple 쪽 버그가 둘 있고, masc 는 요청마다 그 경로를 지나서 두 버그를 그대로 떠안아요.

1. **pipe 누수.** `container exec -i` 한 번마다 호스트의 `container-runtime-linux` 가 pipe 끝 하나를 닫지 않아요.
   쌓이면 이 Mac 의 새 pipe 가 512 바이트로 고정돼요. 그러면 출력이 512 바이트를 넘는 프로세스가, 읽는 쪽이 조금만 늦어도 잘려요.
   - 2026-11-03 10:38 KST: 짝 없는 pipe 9,529개, 새 pipe 용량 512 바이트(6/6).
   - 같은 날 09:26 KST 부터 `sonnet-500k-then-glm` 레인 Keeper 10명이 `auth status: invalid JSON ... (stdout 512 bytes)` 로 턴을 실패했어요. 로그에 이 문구가 267줄 있어요.
2. **stdin 을 닫다가 생기는 정지.** 10-28~10-29 에 게스트 runtime 하나가 멈추고, apiserver 전역 락 때문에 모든 게스트의 exec 가 멈춘 일이 세 번 있었어요(#46602). 세 번 모두 runtime 로그에 `failed to close stdin ... CancellationError` 가 먼저 찍혔어요.

두 PR(apple/container #1928, #2060)을 함께 적용한 빌드는 누수를 0 으로 만들었어요. 하지만 두 PR 은 11-03 에도 병합되지 않았고 최신 릴리스는 1.6.1 이에요.
그 빌드는 손으로 띄운 것이라 재부팅·업그레이드 뒤 원본으로 돌아갔어요. 위 정지 세 번은 모두 그 빌드로 돌던 때(10-28 12:03 KST 이후) 났어요. 빌드가 원인인지는 밝히지 못했어요.
masc 가 고칠 수 있는 근본은 요청 경로에서 Apple exec 의 stdin 을 쓰지 않는 거예요.

## 2. 지금 구조

- 요청 하나는 `container exec -i <guest> masc-exec-shim` 한 번이에요 (`keeper_turn_sandbox_runtime.ml` 의 `build_microvm_endpoint`, `Keeper_sandbox_microvm.shim_exec_prefix_for ~stdin:true`).
- 호스트는 `Process_eio.run_argv_with_stdin_held_open_and_status_split` 로 transport 프로세스를 띄워요 (`keeper_sandbox_remote.ml`).
  stdin 에 요청 프레임을 쓰고 닫지 않고 둬요. 돌려받는 것은 세 가지예요. 종료 코드, stdout(payload 출력), stderr(수락 프레임 + payload stderr + trailer)예요.
- shim 은 프레임을 읽은 뒤에도 stdin 을 지켜봐요. EOF 가 오면 취소로 보고 payload 프로세스 그룹을 죽여요 (`exec_shim.ml` 의 `start_kill On_eof`).
- 요청 데이터는 argv 에 싣지 않아요. 환경 변수와 인증 정보가 `ps` 에 보이지 않게 하려고요.
- Apple backend 에서 `-i` 를 쓰는 곳은 셋이에요. shim 요청, build link 적용(`build_link_apply_request_for`), build 디렉터리 생성이에요.
- 게스트의 첫 명령은 `tail -f /dev/null` 이고 `--user <uid>:<gid>` 로 돌아요 (`turn_start_argv_for`).

## 3. 제안

### 3.1 통로는 `--publish-socket`

VM 을 띄울 때 `container run --publish-socket <호스트 경로>:<게스트 경로>` 를 줘요.
호스트가 그 경로에 접속하면 runtime 이 게스트 쪽 unix 소켓으로 이어 줘요. apiserver 와 XPC 를 지나지 않아요.
네트워크를 끈 VM(`--network none`)에서도 돼요(4절).

### 3.2 게스트 agent

- `masc-exec-shim --serve <게스트 소켓 경로>` 가 VM 의 첫 명령이 돼요. `tail` 자리를 대신해요.
  `container run --init` 을 같이 줘서, 고아가 된 프로세스는 init 이 거둬요.
- 연결 하나가 요청 하나예요. agent 는 연결마다 지금의 `masc-exec-shim` 을 자식 프로세스로 띄워요.
  연결에서 읽은 바이트는 자식의 stdin 으로, 자식의 stdout·stderr 는 연결로 보내요.
- 연결이 끊기면 자식의 stdin 을 닫아요. 지금의 "stdin EOF = 취소"가 바뀌지 않고 동작해요.
- 요청 프레임 해석, 상자(Observe·Effect) 적용, 수락 프레임, trailer 는 지금 shim 코드를 그대로 써요. agent 는 바이트만 옮겨요.
- agent 는 Keeper 와 같은 uid 로 돌아요. 권한 모델은 지금과 같아요.
  - 게스트 안의 Effect payload 가 agent 에 접속해도, 이미 같은 uid 로 할 수 있는 일 이상은 못 해요.
  - Observe payload 는 `socket(2)` 가 모든 주소 체계에서 막혀서 agent 에 닿지 못해요 (`observe_stub.c` 의 `deny_sockets`).
  - agent 의 리스너와 연결 fd 는 close-on-exec 으로 열어서 자식에게 넘어가지 않게 해요.

### 3.3 연결 위 형식

- 호스트 → 게스트: 첫 바이트로 종류(요청 / probe)를 알려요. 요청이면 지금의 요청 프레임을 그대로 이어서 보내요.
- 게스트 → 호스트: `[종류 1바이트][길이 4바이트, big-endian][내용]` 덩어리를 이어 보내요. 종류는 stdout, stderr, 종료 셋이에요.
  종료 덩어리에는 자식의 종료 코드 또는 시그널 번호를 담아요. Docker attach stream 과 같은 모양이에요.
- 종료 덩어리 없이 연결이 끝나면 transport 실패예요. 지금 `ssh` 가 255 로 끝나는 경우와 같은 자리예요.

### 3.4 호스트 쪽

- `Keeper_sandbox_remote.transport` 에 `Guest_socket of { host_socket : string; ... }` 를 더해요.
- masc 서버가 Eio 로 소켓에 직접 접속해요. 덩어리를 나눠서 지금과 같은 `(종료 상태, stdout, stderr)` 를 만들어 돌려줘요.
  그래서 위쪽의 수락 프레임 처리, trailer 대조(`Trailer_disagreement`), 경로 바꾸기는 그대로예요.
- 시간 초과와 취소는 연결을 닫아서 해요. 요청마다 호스트 프로세스와 pipe 가 생기지 않아요.
- 동시에 열 연결 수는 지금의 `remote_max_concurrent_sessions` 를 그대로 써요.

### 3.5 stdin 을 쓰는 나머지 두 호출

build link 적용과 build 디렉터리 생성도 agent 연결로 보내요. 둘 다 입력을 stdin 으로 넘기는 일회성 명령이라 같은 통로에 맞아요.
그 뒤 Apple backend 에는 `container exec -i` 호출이 남지 않아요.

### 3.6 바뀌지 않는 것

- VM 생성·삭제·조회와 볼륨 작업은 지금처럼 `container` CLI 로 해요. 이 호출들은 `-i` 를 쓰지 않아요.
- `Openssh`, `Docker_exec` transport 와 Microsandbox·Nerdctl_kata backend 는 그대로예요.

### 3.7 전환

- 게스트의 첫 명령과 `--publish-socket` 이 boot plan 에 들어가요. plan 이 달라지면 `Keeper_microvm_boot_plan.assess` 가 교체를 허용해서, masc 가 다음 턴 시작 때 VM 을 새로 띄워요.
- 하드컷이에요. Apple backend 의 `Container_exec` 요청 경로는 지워요. 옛 VM 을 위한 읽기 경로나 변환 코드는 만들지 않아요.

## 4. 측정 (2026-11-03, Apple container 1.6.1 원본)

자세한 조건과 스크립트는 [측정 기록](../evidence/2026-11-03-microvm-request-transport/README.md)에 있어요.
모든 시험에 `container exec -i` 대조군을 넣어서, 세는 방법이 누수를 잡는지 같이 확인했어요.

| 통로 | 남은 pipe | 한 번 왕복 p50 | 끊었을 때 게스트가 EOF 를 봄 | `--network none` |
|---|---|---|---|---|
| `container exec -i` (지금) | 호출마다 +1 (20/20) | 173ms | SIGKILL 로는 안 닿음(10-28 측정) | 됨 |
| `container exec` (`-i` 없음) | 0 (50번) | 195ms | 해당 없음(stdin 없음) | 됨 |
| SSH (`-p` publish) | 0 (250번) | 98ms | 10/10 (SIGKILL·SIGTERM 각각) | **안 됨** (connection refused) |
| `--publish-socket` | 0 (140번) | 1~2ms | 10/10 | 됨 |
| msb `exec --stream` | 0 (90번) | 45~51ms | 미측정 | 미측정 |

- `--publish-socket` 의 70,000 바이트 응답 30번은 모두 길이가 맞았어요.
- Keeper 이미지(`masc-sandbox-ocaml`, `masc-sandbox:general`)에는 sshd 가 없어요.

## 5. 검토한 대안

| 대안 | 왜 아닌가 |
|---|---|
| #1928·#2060 을 적용한 container 를 계속 쓴다 | 누수는 0 이 됐어요. 하지만 upstream 이 병합하지 않은 빌드를 brew 업그레이드와 재부팅마다 다시 깔아야 해요. 그 빌드로 돌던 때 전체 정지가 세 번 났고, 원인은 밝히지 못했어요. |
| `-i` 를 빼고 요청을 파일로 넘긴다 | 누수는 없어요. 하지만 요청마다 apiserver 와 그 전역 락을 지나고(약 200ms), 클라이언트를 죽여도 게스트 프로세스가 안 죽어서 취소 표식 파일이 따로 필요해요. 토큰이 든 요청 파일을 호스트가 지워야 해요. |
| SSH 로 게스트에 들어간다 | `--network none` 인 Keeper(11-03 기준 10명)에 닿지 않아요. 이미지마다 sshd, passwd 항목, 키, known_hosts 를 관리해야 해요. |
| microVM backend 를 msb 로 바꾼다 | 누수가 없고 빨라요. 하지만 beta 이고(설치 0.6.16, 최신 0.7.13), 09-04 시험에서 Keeper 가 뜨지 않았어요(RFC-0405 후기). 이미지와 work volume 도 옮겨야 해요. 따로 비교할 일이에요. |
| VM 을 주기적으로 다시 띄운다 | 낮에는 몇 분짜리 완화였어요(10-28). 원인은 그대로예요. |

## 6. 남은 질문

1. **호스트 소켓 경로.** macOS 의 unix 소켓 경로는 104 바이트까지예요. base path 가 길면 `<base-path>/.masc/` 아래에 둘 수 없어요.
   후보는 `Filename.get_temp_dir_name ()` 아래 workspace·Keeper 해시 디렉터리(0700)예요. 그래도 넘치면 VM 을 띄우지 않고 타입이 있는 오류로 거절해요.
2. **relay 의 장시간 동작.** 140번 연결로는 하루 부하를 대신하지 못해요. relay 가 연결마다 fd 를 남기는지 canary 에서 재요.
3. **runtime 이 멈출 때.** #46602 처럼 게스트 runtime 이 멈추면 relay 도 멈출 수 있어요. 요청이 apiserver 전역 락을 지나지 않으니 다른 게스트로 번지지는 않을 거예요. 아직 재 보지 않았어요.
4. **agent 가 죽을 때.** 접속이 거절되면 transport 실패로 돌려주고, VM 교체는 지금의 guest 확인 경로가 맡아요. 이 경로가 접속 거절을 어떻게 읽는지 구현 전에 정해요.
5. **probe.** 지금 `--probe` 는 stdin 없이 argv 로 불러요. 3.3 의 종류 바이트로 옮기면서 protocol major 보고는 그대로 둬요.

## 7. 검증 계획

1. 시험 VM: Keeper 이미지 + agent 로 실제 shim 요청 왕복, Observe·Effect 상자, 취소, 동시 20개, 1,000번 동안 남은 pipe 0.
2. canary: Apple microVM Keeper 하나를 새 경로로 24시간 돌려요. 기준은 셋이에요.
   - 그 VM runtime 의 짝 없는 pipe 가 늘지 않아요.
   - 요청 timeout 비율이 같은 기간 다른 Keeper 보다 높지 않아요.
   - 도구 실행 p50 이 지금보다 길지 않아요.
3. 나머지 Apple microVM Keeper 로 넓혀요. 전부 옮긴 뒤 새 pipe 용량이 65,536 바이트로 돌아오는지 봐요(`pipeleak.py once` 의 `bigwrite`).

## 8. 범위 밖

- Apple 쪽 수정과 upstream 보고.
- 512 바이트로 잘린 출력을 받아들이는 처리. 잘림은 고칠 대상이지 받아들일 대상이 아니에요.
- claude_code 턴 전 `auth status` 확인이 잘렸을 때 레인이 다음 후보로 넘어가는 문제는 #47805 에서 고쳐요.

## 9. 근거

- 측정 기록: `docs/evidence/2026-11-03-microvm-request-transport/`
- 정지 사고: #46602
- 레인 분류: #47787, #47805
- apple/container PR #1928 "Fix XPC file handle ownership", #2060 "Reap completed exec host state in the Linux runtime helper" (11-03 확인 시 둘 다 open)
