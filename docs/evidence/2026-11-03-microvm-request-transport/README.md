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

- 이미지는 `masc-sandbox-ocaml:20260928T0216Z-c48e1e05` 예요. shim 은 `scripts/build-shim-static.sh --print-sources` 의 소스로 그 이미지 안에서 빌드했어요(정적 링크 아님). 결과 파일의 `sources_sha256` 은 그 소스 묶음의 해시예요.
- 세 번 쟀어요. `agent-l3-results-run1.json`·`agent-l3-results-run2.json` 은 리뷰 반영 전 agent(소스 `4f461c864a95…`, `worktree_head` 는 main 위로 옮기기 전 커밋), `agent-l3-results.json` 은 리뷰 반영 뒤 agent(`ff8eb471a31`)예요. 첫 실행 스크립트에는 재연결 수 세기가, 셋째 실행 스크립트에는 아래 표의 capability·그룹·fd 줄이 더해졌어요.
- 실행 옵션: `--cap-drop ALL --cap-add CAP_SETUID --cap-add CAP_SETGID --cap-add CAP_SYS_ADMIN --tmpfs /tmp`. `--user`·`--read-only` 는 없어요. shim 디렉터리는 읽기 전용, 작업 디렉터리는 쓰기로 마운트했어요.
- 첫 명령: `/opt/masc-exec-shim/masc-exec-shim --serve /run/masc-agent/agent.sock 502:20`, 소켓은 `--publish-socket` 으로 호스트에 내보냈어요.

| 확인 | 결과 |
|---|---|
| hello | relay_version 1, root_read_only true, uid 502, gid 20, no_new_privs true |
| probe | `3.0.0+l3check`, capabilities `observe`·`user_notif`·`request_acceptance_frame`, 종료 0 |
| payload 의 id | uid 502, gid 20, 보조 그룹 20 |
| payload 의 쓰기 | rootfs(`/var/tmp`) 실패, `/tmp`(tmpfs)·`/masc-work` 성공 |
| payload 의 capability | CapPrm·CapEff·CapInh·CapAmb 0, CapBnd `0x2000c0`(SETGID·SETUID·SYS_ADMIN), NoNewPrivs 1 (CapInh·CapAmb 는 셋째 실행만) |
| agent(PID 1) 의 `/proc/1/status` | Uid 502 넷, Gid 20 넷, 보조 그룹 없음, CapEff·CapPrm·CapInh·CapAmb 0, NoNewPrivs 1 (그룹과 CapPrm·CapInh·CapAmb 는 셋째 실행만) |
| root 로 본 agent 의 fd (`container exec ... ls -l /proc/1/fd`, 셋째 실행) | 0·1·2 와 리스너 3 뿐. runtime 이 첫 프로세스에 남긴 fd 는 없었어요 |
| payload 의 fd (셋째 실행) | 0·1·2 는 shim 이 준 pipe, 그리고 fd 4 하나(pipe). 측정 줄이 `ls \| sed \| awk` 셸 파이프라인이라 그 셸이 쥔 pipe 일 수 있어요. 따로 가르지 않았어요 |
| payload 가 소켓 디렉터리 읽기, agent 의 fd 목록 읽기, agent 소켓 연결 | 셋 다 거부(Permission denied) |
| payload 종료 7 | trailer exit 7, shim 종료 0 |
| 2초 자는 요청 도중에 보낸 요청 | 212ms·12ms·213ms 에 끝남(실행 순서대로) |
| 50번 연속 | 틀린 응답 0. p50 / 최대: 209 / 266ms, 21 / 418ms, 208 / 465ms |
| 50번 앞뒤 runtime pipe | 짝 없는 pipe 0 → 0, 연결된 pipe 0 → 0 (세 실행 모두) |
| 요청 도중 연결 끊기 | 4초 뒤 `sleep 30` 프로세스 0, payload 가 나중에 쓸 파일 없음 |
| 첫 hello 뒤 다시 연결해야 했던 연결 | 0 / 54, 0 / 54 (둘째·셋째 실행만 셈) |

지연은 실행마다 열 배 가까이 달랐고, 원인은 따지지 않았어요. 위 `container exec` 표와도 바로 비교하지 않아요. 이번 요청은 shim 과 payload 를 실제로 돌리고, shim 감독 루프는 0.2초 단위로 돌아요(`exec_shim.ml` 의 `quantum`).

**agent 가 듣기 전에 연 연결.** `container run -d` 가 돌아오자마자 호스트 소켓에 연결하면 세 가지가 나왔어요.

| 실행 | 즉시 연 연결이 받은 것 |
|---|---|
| `agent_boot_connect.py`, 부팅 6번 (`agent-boot-results.json`) | hello 5번(0.04~0.23초), EOF 1번(4ms, 바로 다음 연결도 EOF) |
| `agent_l3.py` 세 실행 | 모두 EOF. 그 뒤 1초 기한으로 6번·9번·68번 다시 연결해서 436ms·142ms·119ms 에 hello (스크립트는 다시 연결할 때 쉬지 않아요) |
| `agent_l3.py` 를 고치기 전 실행 (읽기에 기한이 없었음) | 12분 동안 hello 도 EOF 도 없음 |

마지막 줄은 결과 파일이 없어요. 멈춘 스크립트를 보고 확인했어요. 그때 게스트에는 agent(PID 1)만 있고 relay 프로세스가 없었어요(`container exec ... ps`). 스크립트는 연결 하나를 연 채 읽기에서 멈춰 있었어요(`lsof`). 같은 VM 에 새로 연결하면 hello 가 바로 왔어요.

그래서 호스트는 hello 를 기한 안에 받지 못하면 그 연결을 닫고 새로 연결해야 해요. hello 전에는 아무것도 보내지 않으므로, 다시 연결해도 요청이 두 번 돌지 않아요.
`bin/pipeleak.py` 는 10-28 부터 쓴 호스트 pipe 측정 스크립트예요(`once` 가 표를 찍어요). PIPE fd 만 세므로 소켓이나 vsock 누수는 못 봐요. 그래서 위 측정은 runtime 의 전체 fd 수도 같이 셌어요.

### `container exec` 로 들어간 프로세스 (`bin/exec_caps.py`, 결과 `exec-caps-results.json`)

masc 가 직접 `container exec` 하는 명령은 agent 를 거치지 않아요. 그 프로세스가 가진 권한을 agent 모양과 exec 모양 게스트에서 쟀어요.
첫 프로세스는 `sleep infinity` 이고 `-i` 는 쓰지 않았어요. container 1.6.1, 이미지는 `masc-sandbox:general` 과 `masc-sandbox-ocaml:20260928T0216Z-c48e1e05` 예요. 두 이미지 결과가 같았어요.

| 확인 | agent 모양 | exec 모양 |
|---|---|---|
| Keeper uid(502:20) 의 CapEff·CapPrm | 0 | 0 |
| Keeper uid 의 CapBnd | `0x2000c0`(SETGID·SETUID·SYS_ADMIN) | 0 |
| root(0:0) 의 CapEff·CapPrm | `0x2000c0` | 0 |
| NoNewPrivs | 0 | 0 |
| HOME (이미지 `ENV` 는 `/home/keeper`·`/home/opam`) | inspect 에 `HOME=/tmp` 하나, 프로세스도 `/tmp` | 같음 |

- setuid root 파일은 두 이미지 모두 `su`·`mount`·`umount`·`passwd`·`chfn`·`chsh`·`gpasswd`·`newgrp` 이고, ocaml 이미지에는 `sudo`·`ssh-keysign` 이 더 있어요.
- uid 502 가 root 가 되는 길은 없었어요. passwd 항목이 없고(`getent` 2), `sudo -n` 은 general 에 없고(127) ocaml 에서는 거절됐어요(1). root 계정이 잠겨 있어(`*`) `su` 도 실패했어요(1).
- ocaml 이미지의 sudoers 에는 `opam ALL=(ALL:ALL) NOPASSWD:ALL` 이 있고, opam 은 uid 1000 이에요. 호스트 uid 가 1000 이면 그 Keeper 의 exec 프로세스는 비밀번호 없이 root 가 돼요. agent 모양에서는 그 root 가 SYS_ADMIN 을 가져요.
- agent 가 띄운 요청은 NoNewPrivs 1 이라(위 표) setuid 파일로 권한을 얻지 못해요. 그래서 agent 모양 게스트에서 Keeper 명령은 agent 로만 보내요(L5b-2). masc 가 직접 하는 exec 7곳(그중 root 4곳)은 RFC 6절 1번에 남겨요.

### agent 실행 옵션 (`bin/agent_boot_flags.py`, 결과 `agent-boot-flags-results.json`)

masc 가 그리는 모양 그대로 첫 프로세스를 `--entrypoint <shim>` 과 인자 `--serve /run/masc-agent/agent.sock 502:20` 으로 두었어요.
나머지 옵션은 위 실제 agent 측정과 같아요. 경우마다 VM 을 새로 띄우고(`--rm`) 끝에 멈췄어요. container 1.6.1.

| 경우 | 호스트 경로 상태 | `container run` | hello |
|---|---|---|---|
| `--user 0:0` | 없음 | 성공 | 받음(두 번째 연결) |
| `--user` 없음 | 없음 | 성공 | 받음 |
| 소켓 파일이 남아 있음 | 소켓 | 실패: `host socket … already exists and may be in use` | — |
| 일반 파일이 있음 | 파일 | 성공. 실행 중에는 소켓으로 바뀜 | 받음 |
| 부모 디렉터리 없음 | 없음 | 성공. runtime 이 디렉터리를 만듦 | 받음 |
| 112바이트 경로 | 없음 | 실패: `… is too long for a Unix Domain Socket path` (부팅 단계) | — |

- `container inspect` 의 `.[0].configuration`(masc 가 읽는 곳):
  - `--user 0:0` 이면 `initProcess.user.raw.userString` 은 `"0:0"`, `--user` 가 없으면 `"root"` 예요.
  - `capAdd` 는 넘긴 이름 그대로 `["CAP_SETUID", "CAP_SETGID", "CAP_SYS_ADMIN"]`, `capDrop` 은 `["ALL"]`, `readOnly` 는 `false` 예요.
  - `publishedSockets` 는 `[{"containerPath": …, "hostPath": …}]`, `useInit` 은 `false` 예요.
  - `initProcess.executable` 은 shim 경로, `arguments` 는 `--serve` 부터예요.
- VM 이 사라지면 성공한 네 경우 모두 runtime 이 호스트 소켓 파일을 지웠어요. 그래서 남은 소켓 파일은 VM 이 정상적으로 끝나지 못했을 때만 생겨요.
- 지금 도는 Keeper VM(`--publish-socket` 없음, `--user 502:20`, `--read-only`)의 inspect 도 `publishedSockets: []`, `useInit: false`, `capAdd: []` 를 담고 있었어요.

### agent plan 으로 띄운 게스트 (`bin/agent_plan_harness.sh`, `bin/agent_plan_boot.py`, 결과 `agent-plan-boot-results.json`)

boot plan 코드가 실제 게스트를 자기 plan 으로 읽는지 확인했어요.

- `agent_plan_harness.sh` 는 저장소의 boot plan·렌더러·inspect 파서·판정 코드를 정의 단위로 그대로 잘라 작은 프로그램으로 묶어요. 정의는 첫 줄로 찾고, 그 첫 줄이 없거나 두 번 나오면 멈춰요. 손으로 옮겨 적은 코드는 없어요. agent 경로가 닿지 않는 세 값(scratch 경로 상수, Kata shim 이름, 정책 proxy 환경)만 stub 이에요.
- 이 프로그램이 agent plan 의 실행 옵션을 그리고, `agent_plan_boot.py` 가 그 58개 토큰을 그대로 `container run` 에 넘겨요.
- plan 은 `requested_apple_plan` 의 마운트 넷(identity·work·build·shim)에 agent 몫을 더했어요. `--user 0:0`, `Read_only_rootfs` 없음, capability 셋, 소켓 하나, 첫 프로세스 `masc-exec-shim --serve` 예요.
- shim 은 `agent_l3.py` 가 만든 빌드를 다시 썼어요. 그 빌드의 소스 해시(`ebf5a676…d287`)가 이 커밋의 shim 소스와 같아요.

| 확인 | 결과 |
|---|---|
| `container run` | 성공 |
| hello | 첫 연결에서 받음. relay_version 1, root_read_only true, uid 502, gid 20, no_new_privs true |
| probe | `3.0.0+l3check`, 종료 0 |
| 요청 `echo id=$(id -u):$(id -g); exit 5` | `id=502:20`, trailer exit 5 |
| masc 파서·판정, 실제 경로 | differences 없음, plan 라벨이 digest 와 같음, `Matches_plan` |
| 중립 경로 사본(테스트 fixture) | 같은 판정, `Matches_plan` |
| VM 이 끝난 뒤 호스트 소켓 파일 | 없음 |

- 중립 사본은 호스트 경로 세 개, 그 경로로 계산한 plan 라벨, runtime 이 정한 볼륨 이미지 경로만 바꿨어요. 그 사본이 `test/fixtures/apple-container-1.6.1-agent-guest-inspect.json` 이에요. `test_keeper_microvm_boot_plan` 의 "a guest booted from an agent plan matches it" 이 실제 라이브러리로 같은 판정을 해요.
- 이미지 메타데이터(`container image inspect`, 29 KB)는 fixture 에 넣지 않았어요. 테스트는 같은 descriptor digest 를 가진 합성 이미지 기록을 써요.
- 부팅은 L5a head `791552a4ad9` 의 코드로 했어요. 스택이 병합된 뒤 main `3c4d764b76d` 에서 다시 자른 코드는 빈 줄 말고 같았고, 같은 argv 두 개를 그리고 두 inspect 를 모두 `Matches_plan` 으로 판정했어요.

`bin/agent_paths_as_given.py`(결과 `agent-paths-as-given-results.json`)는 같은 순서의 실행 옵션을 Python 으로 만들어요. 호스트 소켓과 identity 마운트를 심볼릭 링크 디렉터리를 거쳐 줬더니, runtime 은 두 경로를 링크를 풀지 않고 받은 그대로 보고했어요. VM 이 끝나자 소켓 파일도 지웠어요. 그래서 masc 는 경로를 풀어 쓸 필요 없이, 같은 경로 문자열을 매번 그리면 돼요.

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
- `python3 -I bin/exec_caps.py <결과 json>`. VM 넷을 차례로 띄우고 멈춰요.
- `python3 -I bin/agent_boot_flags.py <stage> <소켓 디렉터리> <결과 json>`. `<stage>/out` 에는 `agent_l3.py` 가 만든 shim 과 설정 파일이 있어야 해요. 소켓 디렉터리는 짧은 로컬 경로여야 해요.
- `bin/agent_plan_harness.sh <저장소> <빌드 디렉터리>` 로 하네스를 만든 다음 `python3 -I bin/agent_plan_boot.py <빌드 디렉터리>/harness <stage> <소켓 디렉터리> <결과 디렉터리>` 예요. `bin/agent_paths_as_given.py` 는 `agent_boot_flags.py` 와 같은 인자를 받아요.
