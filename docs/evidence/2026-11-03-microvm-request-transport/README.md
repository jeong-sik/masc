# microVM 요청 통로 비교 측정 (2026-11-03)

[RFC microvm-guest-agent-over-socket](../../rfc/RFC-microvm-guest-agent-over-socket.md) 의 근거예요.
같은 Mac 에서, 운영 중인 Keeper VM 은 건드리지 않고 시험용 컨테이너만 띄워서 쟀어요.

## 환경

- macOS, Apple container 1.6.1 (brew 원본, `/opt/homebrew/Cellar/container/1.6.1`). 11-02 재부팅 뒤 이 빌드로 돌고 있었어요.
- 측정 시각의 호스트: 새 pipe 용량 512 바이트(6/6), Keeper VM runtime 들의 짝 없는 pipe 9,529개, load average 59~75.
- msb 0.6.16 (brew).

## 세는 방법

- 각 시험 컨테이너의 `container-runtime-linux start ... --uuid <이름>` 프로세스에서 `lsof -n -w -p <pid>` 를 읽어요.
- `PIPE` 행 가운데 NAME 칸이 없는 행(7칸)을 "짝 없는 pipe"로 세요. 상대 끝이 닫힌 pipe 가 이렇게 찍혀요.
- 모든 시험에 `container exec -i` 를 일부러 부르는 대조군을 넣었어요. 대조군이 늘지 않으면 세는 방법이 틀린 거예요.
  첫 실행에서 칸 수를 8로 잘못 적어 대조군도 0 이 나왔고, 7로 고쳐 다시 쟀어요. 아래는 고친 뒤 결과예요.

## 결과

### `bin/measure.py` — SSH 와 `container exec` (결과: `ssh-and-exec-results.json`, 스크립트가 쓰는 이름은 `results.json`)

이미지 `masc-ssh-wkbl-team:20261028`, `-p 127.0.0.1:22299:22`, 게스트 sshd 는 `kit/entrypoint.sh`.

| 단계 | 호출 | 남은 pipe | p50 / p90 ms |
|---|---|---|---|
| ssh `true` | 100 | 0 | 98 / 129 |
| ssh + stdin 2 KiB | 100 | 0 | 94 / 121 |
| ssh stdout 70,000 B | 30 | 0 | 117 / 167 |
| `container exec` (`-i` 없음) | 50 | 0 | 195 / 369 |
| `container exec -i` (대조군) | 20 | +20 | 173 / 294 |
| ssh 20개 동시 | 20 | 0, 실패 0 | 345 / 370 |
| ssh 클라이언트 SIGKILL 뒤 게스트가 stdin EOF 를 봄 | 10 | 0 | 10/10 |
| ssh 클라이언트 SIGTERM 뒤 게스트가 stdin EOF 를 봄 | 10 | 0 | 10/10 |

70,000 B 응답의 길이는 이 스크립트에서 검사하지 않았어요.

### `bin/variants.py` — SSH 가 Keeper VM 모양에서도 닿는지

실행 당시 출력을 옮긴 거예요.

| 경우 | 결과 |
|---|---|
| root sshd, `--network none`, `-p 127.0.0.1:22297:22` | 게스트 sshd 는 떴지만 호스트 접속은 `Connection refused` |
| `--user opam` 비루트 sshd, 기본 네트워크, `-p 127.0.0.1:22296:2222` | 로그인 성공, sshd 가 PID 1 |
| 위와 같고 `--network none` | `Connection refused` |

로그에 접속 주소가 `192.168.64.1` 로 찍혀요. `-p` 는 게스트의 vmnet 주소로 넘겨서, 네트워크가 없는 게스트에는 닿지 않아요.
Keeper 이미지 `masc-sandbox-ocaml:20260928T0216Z-c48e1e05` 와 `masc-sandbox:general` 에는 sshd 도, uid 502 의 passwd 항목도 없었어요.

### `bin/socket_relay.py` — `--publish-socket` (게스트 리스너: `kit/sockserver.py`)

Keeper 이미지 `masc-sandbox-ocaml:20260928T0216Z-c48e1e05`, Keeper 와 같은 `--user 502:20`. 실행 당시 출력을 옮긴 거예요.

| 단계 | `--network none` | 기본 네트워크 |
|---|---|---|
| 2 KiB 요청·응답 100번: 남은 pipe, p50 / p90 / 최대 ms, 틀린 응답 | 0, 1 / 2 / 3, 0 | 0, 2 / 11 / 120, 0 |
| 70,000 B 응답 30번: 길이가 틀린 응답 | 0 | 0 |
| 응답을 읽지 않고 끊은 연결 10번: 게스트가 EOF 를 본 수 | 10 (131 → 141) | 10 (131 → 141) |
| 같은 컨테이너에 `container exec -i` 20번 (대조군) | +20 | +20 |

macOS 의 unix 소켓 경로 제한(104 바이트) 때문에 호스트 소켓은 저장소의 짧은 `.tmp/sp/` 아래에 두었어요. 측정 뒤 지웠어요.
이 시험의 클라이언트는 요청을 보낸 뒤 쓰기 쪽을 닫았어요(`shutdown(SHUT_WR)`). 쓰기 쪽을 열어 둔 요청은 아래 `agent_shape.py` 측정에서 따로 쟀어요.
이 시험의 원본 출력 파일은 없어요. 표는 실행 당시 출력을 옮긴 거예요.

### `bin/msb_exec.py` — msb `exec`

alpine 샌드박스 하나. 세는 대상은 이름에 msb·krun 이 들어간 호스트 프로세스예요. 샌드박스 프로세스는 `msb sandbox --name <이름>` 하나였어요.
같은 이름 패턴에 걸린 Apple vmnet 프로세스(38076)도 함께 세었어요. 실행 당시 출력을 옮긴 거예요.

| 단계 | 호출 | 남은 pipe (앞 → 뒤) | p50 ms |
|---|---|---|---|
| `msb exec --stream ... -- true`, stdin `/dev/null` | 30 | 1 → 1 | 51 |
| `msb exec --stream ... -- cat`, stdin 2 KiB | 30 | 1 → 1 | 47 |
| `msb exec ... -- true` | 30 | 1 → 1 | 45 |

msb 쪽은 누수를 일부러 일으키는 대조군이 없어요.

### Keeper VM 조건의 agent (`bin/agent_shape.py`, `bin/relay_flags.py`, `kit/agent_probe.py`, `kit/hijack.py`)

리뷰에서 앞 측정이 Keeper VM 조건(`--read-only`, `--tmpfs /tmp`, `--cap-drop ALL`, `--rm`)이 아니라는 지적을 받고 다시 쟀어요.
게스트 쪽은 python stand-in(`kit/agent_probe.py`)이에요. 요청은 4 바이트 길이 + 본문이고, 호스트는 응답을 받을 때까지 쓰기 쪽을 열어 둬요.

1. `agent-shape-results.json`: Keeper 조건 그대로(`--read-only --tmpfs /tmp`, 소켓은 `/tmp` 또는 `--tmpfs /run` 위). 세 경우 모두 agent 는 떴지만 호스트 요청이 응답 전에 닫혔어요.
   같은 파일에 `container inspect` 결과가 있어요. `--init` 은 `initProcess` 를 바꾸지 않고 `useInit` 만 `true` 로 바꿔요. `publishedSockets` 도 inspect 에 나와요.
2. `relay-flags-results.json`: 옵션을 하나씩 바꿔서 원인을 찾았어요. 소켓이 tmpfs 위에 있을 때만 relay 가 agent 에 닿지 않아요(agent 연결 로그가 비어 있음). rootfs 하위 디렉터리, `--cap-drop ALL --rm`, 쓰기 쪽을 열어 둔 요청은 모두 됐어요.
3. `relay-mounts-results.json`: `--read-only` 에서 소켓을 이름 붙은 볼륨이나 호스트 디렉터리 마운트 위에 두어도 닿지 않았어요.
4. `agent-rootfs-results.json`: `--cap-drop ALL --rm`, rootfs 위 소켓. `agent_shape.py` 의 `KEEPER_FLAGS`·`CASES` 를 이 두 경우로 바꿔 실행했어요.
   - Keeper uid agent + Keeper uid 디렉터리: 순차 100(p50 3.4ms)·동시 20·60초 대기 정상, 전체 fd 48 → 48. Keeper uid 의 가로채기가 성공했고 다음 요청에 가짜가 답했어요.
   - root 로 0700 디렉터리에 묶고 502 로 내려감(`--cap-add CAP_SETUID --cap-add CAP_SETGID`): 같은 요청 정상(p50 0.5ms), 가로채기는 unlink·bind 모두 권한 거부, 다음 요청에 진짜가 답했어요.
5. `agent-remount-results.json`: 위 root 배치에 `--tmpfs /tmp` 를 더하고, 한 경우는 `CAP_SYS_ADMIN` 을 더해 묶은 직후 `/` 를 `MS_REMOUNT|MS_RDONLY` 로 다시 마운트했어요.
   - 다시 마운트하지 않은 경우: Keeper uid 가 `/var/tmp` 에 썼어요.
   - 다시 마운트한 경우: 다시 마운트가 성공했고, Keeper uid 의 같은 쓰기는 `Read-only file system` 이었어요. 요청은 모두 정상(p50 0.6ms), 가로채기는 권한 거부였어요.
   - 두 경우 모두 agent 가 내려간 뒤 `dumpable` 0, `no_new_privs` 1 이에요. capability 값은 읽지 않았어요.

`bin/agent_shape.py` 는 2번 측정 뒤 연결 로그를 남기게, `kit/agent_probe.py` 는 5번 측정 전에 `root-drop-ro` 모드와 rootfs 쓰기 확인을 더하게 고쳤어요. 저장소의 파일은 마지막 상태예요.

### 실제 agent (`bin/agent_l3.py`, `bin/agent_boot_connect.py`)

구현 3층의 `masc-exec-shim --serve` 를 RFC 0절 실행 옵션으로 띄워서 쟀어요. 위 python stand-in 이 아니라 실제 agent 와 실제 shim 이에요.

- 이미지는 `masc-sandbox-ocaml:20260928T0216Z-c48e1e05` 예요. shim 은 `scripts/build-shim-static.sh --print-sources` 의 소스로 그 이미지 안에서 빌드했어요(정적 링크 아님). 결과 파일의 `sources_sha256` 은 그 소스 묶음의 해시이고(`4f461c864a95…`), 이 측정을 더한 PR 의 shim 소스와 같아요. `worktree_head` 는 main 위로 옮기기 전 커밋이에요.
- 실행 옵션: `--cap-drop ALL --cap-add CAP_SETUID --cap-add CAP_SETGID --cap-add CAP_SYS_ADMIN --tmpfs /tmp`. `--user`·`--read-only` 는 없어요. shim 디렉터리는 읽기 전용, 작업 디렉터리는 쓰기로 마운트했어요.
- 첫 명령: `/opt/masc-exec-shim/masc-exec-shim --serve /run/masc-agent/agent.sock 502:20`, 소켓은 `--publish-socket` 으로 호스트에 내보냈어요.

`agent-l3-results.json`(두 번째 실행)과 `agent-l3-results-run1.json`(첫 실행). 첫 실행은 스크립트에 재연결 수 세기를 더하기 전이에요.

| 확인 | 결과 |
|---|---|
| hello | relay_version 1, root_read_only true, uid 502, gid 20, no_new_privs true |
| probe | `3.0.0+l3check`, capabilities `observe`·`user_notif`·`request_acceptance_frame`, 종료 0 |
| payload 의 id | uid 502, gid 20, 보조 그룹 20 |
| payload 의 쓰기 | rootfs(`/var/tmp`) 실패, `/tmp`(tmpfs)·`/masc-work` 성공 |
| payload 의 capability | CapPrm·CapEff 0, CapBnd `0x2000c0`(SETGID·SETUID·SYS_ADMIN), NoNewPrivs 1 |
| agent(PID 1) 의 `/proc/1/status` | Uid 502 넷, Gid 20 넷, CapEff 0, NoNewPrivs 1 |
| payload 가 소켓 디렉터리 읽기, agent 의 fd 목록 읽기, agent 소켓 연결 | 셋 다 거부(Permission denied) |
| payload 종료 7 | trailer exit 7, shim 종료 0 |
| 2초 자는 요청 도중에 보낸 요청 | 212ms(첫 실행), 12ms(두 번째)에 끝남 |
| 50번 연속 | 틀린 응답 0. p50 209ms / 최대 266ms(첫 실행), p50 21ms / 최대 418ms(두 번째) |
| 50번 앞뒤 runtime pipe | 짝 없는 pipe 0 → 0, 연결된 pipe 0 → 0 (두 실행 모두) |
| 요청 도중 연결 끊기 | 4초 뒤 `sleep 30` 프로세스 0, payload 가 나중에 쓸 파일 없음 |
| 첫 hello 뒤 다시 연결해야 했던 연결 | 0 / 54 (두 번째 실행만 셈) |

지연은 두 실행에서 열 배 가까이 달랐고, 원인은 따지지 않았어요. 위 `container exec` 표와도 바로 비교하지 않아요. 이번 요청은 shim 과 payload 를 실제로 돌리고, shim 감독 루프는 0.2초 단위로 돌아요(`exec_shim.ml` 의 `quantum`).

**agent 가 듣기 전에 연 연결.** `container run -d` 가 돌아오자마자 호스트 소켓에 연결하면 세 가지가 나왔어요.

| 실행 | 즉시 연 연결이 받은 것 |
|---|---|
| `agent_boot_connect.py`, 부팅 6번 (`agent-boot-results.json`) | hello 5번(0.04~0.23초), EOF 1번(4ms, 바로 다음 연결도 EOF) |
| `agent_l3.py` 두 실행 | 둘 다 EOF. 그 뒤 1초 기한으로 6번·9번 다시 연결해서 436ms·142ms 에 hello |
| `agent_l3.py` 를 고치기 전 실행 (읽기에 기한이 없었음) | 12분 동안 hello 도 EOF 도 없음 |

마지막 줄은 결과 파일이 없어요. 멈춘 스크립트를 보고 확인했어요. 그때 게스트에는 agent(PID 1)만 있고 relay 프로세스가 없었어요(`container exec ... ps`). 스크립트는 연결 하나를 연 채 읽기에서 멈춰 있었어요(`lsof`). 같은 VM 에 새로 연결하면 hello 가 바로 왔어요.

그래서 호스트는 hello 를 기한 안에 받지 못하면 그 연결을 닫고 새로 연결해야 해요. hello 전에는 아무것도 보내지 않으므로, 다시 연결해도 요청이 두 번 돌지 않아요.
`bin/pipeleak.py` 는 10-28 부터 쓴 호스트 pipe 측정 스크립트예요(`once` 가 표를 찍어요). PIPE fd 만 세므로 소켓이나 vsock 누수는 못 봐요. 그래서 위 측정은 runtime 의 전체 fd 수도 같이 셌어요.

## 로그 집계 (`<base-path>/.masc/logs/system_log_<날짜>.jsonl`)

날짜는 UTC 예요. 명령은 `rg -c '<문구>' system_log_<날짜>.jsonl` 이에요.

| 날짜 | `stdout 512 bytes` | `Claude Code turn starting` | `Timeout after` | `operation=tool_execute` |
|---|---|---|---|---|
| 10-27 | 191 | 819 | 37 | 14,581 |
| 10-28 | 11 | 648 | 1,741 | 11,185 |
| 10-29 | 0 | 1,401 | 522 | 8,811 |
| 10-30 | 0 | 426 | 348 | 13,403 |
| 10-31 | 0 | 7 | 87 | 1,918 |
| 11-01 | 24 | 61 | 2 | 20,315 |
| 11-02 | 0 | 38 | 12 | 25,606 |
| 11-03 (02:20Z 무렵까지) | 267 | 365 | 0 | 1,399 |

- 10-28 03:03Z 부터 #1928·#2060 을 적용한 빌드가 돌았어요. 그날 잘림 11건은 모두 01:18Z 의 것이에요.
- 11-01 10:19Z 부터 잘림이 다시 나와요. 언제 원본 빌드로 돌아갔는지는 확인하지 못했어요(시스템 로그 보존 기간 밖).
- `Timeout after` 가운데 `container exec -i` 호출은 10-28 에 1,273/1,741, 10-29 에 353/522, 10-30 에 29/348 이에요.
  10-30 의 나머지는 대부분 `container list --all`(131)과 `container inspect`(82 이상)예요. 요청 경로가 아니라 apiserver 응답 자체가 늦었어요.
- 같은 기간에 호스트 부하(load 38~60, VM 23개)와 masc 배포도 달랐어요. 그래서 이 숫자로 두 빌드의 안정성을 비교할 수는 없어요.

## 다시 돌리는 법

- `bin/*.py` 는 이 디렉터리 구조(`bin/`, `kit/`)를 가정해요. `client/id_probe` 키는 저장소에 없어요.
  `ssh-keygen -t ed25519 -N '' -f client/id_probe` 로 만들고 `client/id_probe.pub` 를 `kit/authorized_keys` 로 복사해요.
- `python3 -I bin/measure.py`, `python3 -I bin/variants.py`, `python3 -I bin/socket_relay.py`, `python3 -I bin/msb_exec.py`.
  모두 시험 컨테이너를 만들고 끝나면 지워요.
- `socket_relay.py`, `agent_shape.py`, `relay_flags.py` 의 `SOCK_DIR` 은 소켓 경로 제한 때문에 짧은 로컬 경로로 고쳐 써야 해요.
- `python3 -I bin/agent_shape.py`, `python3 -I bin/relay_flags.py` 도 같은 방식이에요. 4·5번 측정은 위에 적은 대로 `KEEPER_FLAGS`·`CASES` 를 바꿔 실행했어요.
