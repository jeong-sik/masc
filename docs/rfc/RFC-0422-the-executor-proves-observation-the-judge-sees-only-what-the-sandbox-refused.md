---
rfc: "0422"
title: "실행기가 관측을 증명한다 — judge 는 상자가 거부한 것만 본다"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
supersedes: []
superseded_by: null
related: ["0404", "0421", "0405"]
---

## 1. 문제

keeper 의 `tool_execute` 가 judge 를 건너뛰는 길은 지금 하나다. 명령 표(RFC-0404)와
셸 IR 분류(RFC-0421)가 "이 줄은 관측만 한다" 고 **예측**하면 바로 실행한다. 표 밖이면
judge 모델이 같은 텍스트를 보고 다시 **예측**한다. 둘 다 실행하기 전에 텍스트로
효과를 맞히는 방식이다.

### 1.1 예측이 닿지 못하는 곳 (2026-09-04 ~ 09-05, judge 로 간 microvm 요청 710건)

| 모양 | 건수 | 표·IR 로 되나 |
|---|---|---|
| 쓰기도 네트워크도 없음 (`for` 루프, `$(pwd)`, `awk` 줄 범위 출력, `python3 -c` 읽기, `jq`) | 137 | 안 된다. 루프·치환·다른 언어의 프로그램은 표로 판정할 수 없다 |
| 게스트 안 쓰기만 (`mkdir`, `dune build`, `git checkout` 로컬, `git config`) | 264 | 표 정의("파일시스템 효과 0") 밖이다 |
| 네트워크 읽기 (`gh pr list`, `git fetch`) | 178 | `gh` 읽기 동사는 표에 있다. `git fetch` 는 아니다 |
| 네트워크 쓰기 (`gh pr create`, `git push`) | 131 | judge 가 맞다 |

같은 이틀 remote_ssh(rondo) 133건은 명령을 보지도 않고 전부 judge 다. 그중 73건이
`pwd`, `ls`, `tail` 이었다.

RFC-0421 뒤에도 judge 트래픽의 절반 이상이 "표로는 영원히 못 말하는 것" 과
"보지 않기로 한 프로필" 이다. 표를 더 채워서 닿는 범위가 아니다.

### 1.2 게스트가 실제로 밖에 닿을 수 있는 길 (2026-09-05 실측, sangsu VM)

```
kernel 6.18.35   cmdline: lsm=lockdown,capability,landlock,yama,apparmor
landlock_create_ruleset(VERSION) = 7      seccomp RET_ERRNO / user_notif 가능
/            ext4 ro            (rootfs, /tmp 와 /home/opam 도 읽기 전용)
/masc-work   ext4 rw  /dev/vdc  (keeper 전용 볼륨 masc-keeper-work-<keeper>, 호스트 bind 아님)
/dev/shm     tmpfs rw 64M noexec
/opt/masc-exec-shim                         virtiofs ro
/tmp/masc-runtime/.masc/config              virtiofs ro
/tmp/masc-runtime/.masc/keepers/<k>/github-cli   virtiofs ro   (GitHub 자격증명)
```

쓰기 가능한 곳은 keeper 전용 볼륨과 64MB 의 `/dev/shm` 뿐이고, 호스트에서 온 마운트는
전부 읽기 전용이다. **게스트의 파일 쓰기는 호스트에 닿지 않는다.** 밖으로 나가는 유일한
길은 네트워크이고, 그 길에는 읽기 전용으로 마운트된 GitHub 자격증명이 실린다.
RFC-0421 §6 이 "`/masc-work` 가 호스트 playground 마운트" 라고 적은 것은 틀렸다.
이 RFC 가 그 문장을 고친다.

rondo 의 remote_ssh 대상(`sbx-sshd-probe`)은 같은 커널(6.18.35)이고, 계정 `rondo`·`sbxr`
이 한 머신에 있다. 운영자가 그리는 모양은 한 머신에 keeper 계정 여럿이다. 거기서
"disposable guest" 라는 전제는 계정마다 성립하지 않을 수 있고, 성립하게 만들 의무도 없다.

## 2. 판단

- 관측 여부는 예측하지 않고 **측정한다**. 아무것도 못 하는 상자에서 먼저 돌리고, 끝까지
  돌았으면 관측이다. 무엇을 하려다 막혔으면 그 기록을 judge 에 준다.
- 상자는 실행기가 만든다. 게스트 안에서 payload 를 `execvpe` 하는 `masc-exec-shim` 이
  자기 자신에 Landlock 과 seccomp 을 걸고 exec 한다. 둘 다 비특권으로 되고(no_new_privs),
  커널이 강제한다. 표나 파서가 틀릴 자리가 없다.
- 표(RFC-0404/0421)는 남는다. 실행 없이 답이 나오는 가장 싼 길이고, 네트워크 읽기
  (`gh pr list`)는 상자에서 돌릴 수 없으므로 표만이 답한다.
- "disposable guest 만" 이라는 전제는 **읽기 증명에는 필요 없어진다.** 쓰지도 못하고
  나가지도 못한 실행은 어디서 돌았든 관측이다. remote_ssh 도 같은 shim 이 돌므로 같은
  길을 탄다.
- 게스트 안 쓰기를 judge 없이 허용할지는 별도의 정책 스위치다(§3.4). 이 RFC 는 그
  스위치를 만들고 기본값은 끈다.

## 3. 설계

### 3.1 실행 모드

shim 요청(`Exec_ssh_protocol.request`, protocol v3)에 `mode` 를 더한다. 닫힌 variant.

```
mode = Effect        (* 지금과 같다. 제한 없음 *)
     | Observe       (* 파일 쓰기 없음, 네트워크 없음 *)
     | Guest_local   (* 네트워크 없음. 파일 쓰기는 상자 안 *)
```

`Observe` 에서 shim 은 fork 뒤 exec 앞에(`spawn`, `setsid` 와 `set_pdeathsig` 다음) 이렇게
한다.

1. `prctl(PR_SET_NO_NEW_PRIVS, 1)`.
2. Landlock: 모든 경로에 `READ_FILE | READ_DIR | EXECUTE`, 스크래치 디렉터리 한 곳에만
   `WRITE_FILE | MAKE_* | REMOVE_* | TRUNCATE`. 그 외 쓰기 권한은 어디에도 없다.
   `restrict_self`. ABI 1 로 충분하고, `TRUNCATE`(ABI 3) 는 게스트가 7 이라 같이 건다.
3. seccomp(BPF): `socket(2)` 을 어느 family 든 `EPERM`. TCP 만 막는 Landlock ABI 4 로는
   UDP(DNS) 가 남는다. ABI 10 의 UDP 제한은 6.18 에 없다. 그래서 소켓 자체를 막는다.
4. `HOME` 과 `TMPDIR` 을 스크래치로 바꿔 exec.

`Guest_local` 은 3 과 4 만 한다.

스크래치는 실행마다 새로 만들고 실행이 끝나면 지운다. microvm 에서는 VM 기동에
`--tmpfs /tmp` 를 더해(Apple `container run` 이 받는다, 2026-09-05 확인) 그 아래에 둔다.
remote_ssh 에서는 shim 설정(`scratch_root=`)이 계정 안의 디렉터리를 가리킨다.

### 3.2 게이트의 순서

```
tool_execute 요청
 ├─ 표·IR 이 관측이라 답하면              → 바로 실행 (지금과 같다)
 ├─ 네트워크 읽기 표에 있으면              → 바로 실행 (지금과 같다)
 ├─ 그 외, 프로필이 Observe 를 지원하면    → Observe 로 실행
 │     ├─ exit 0                          → 결과를 그대로 돌려준다. judge 없음
 │     └─ exit ≠ 0 또는 시그널             → judge 로. 상자의 stdout/stderr 를 붙인다
 └─ 지원 안 하면                           → judge (지금과 같다)
```

승인되면 지금의 replay 경로가 `Effect` 로 다시 실행한다. Observe 실행은 tool 의 시간
예산 안에서 돈다. 두 번째 실행은 새 예산이다.

exit 0 만 관측으로 친다. 상자 안에서 쓰기나 연결을 시도한 프로그램은 `EACCES`·`EPERM`
을 받고 대개 0 이 아닌 코드로 끝난다. 시도 뒤에도 0 으로 끝난 프로그램은 실제로 아무
효과를 남기지 못했으므로 그 출력을 돌려주는 것이 맞다. 효과가 없었다는 것은 커널이
보증한다.

### 3.3 judge 가 받는 것

지금 judge 는 요청 텍스트를 받는다. 이 RFC 뒤에는 Observe 실행의 종료 코드와 stderr
가 붙는다. `mkdir: cannot create directory 'gh-cache6': Permission denied` 나
`fatal: unable to access 'https://github.com/…': Could not resolve host` 같은 줄이다.
무엇을 하려 했는지 추측하지 않고 본다.

### 3.4 정책 스위치: 게스트 안 쓰기

프로필별 설정 `observation_run = "observe" | "guest_local"`. 기본 `observe`.

`guest_local` 은 §1.2 의 사실 위에 선다. microvm 의 쓰기는 keeper 전용 볼륨 밖으로
못 나간다. 그래서 `dune build`, `mkdir`, 로컬 `git checkout`, `git config` 가 네트워크만
안 쓰면 judge 없이 돈다. 이틀치로 401건(microvm judge 의 56%)이다. 잃는 것은 keeper
가 자기 작업 트리를 스스로 망가뜨릴 때 judge 가 그것을 막아 줄 기회다. 그 손실은 다시
clone 하면 복구된다. 이 스위치를 켤지는 운영자가 프로필마다 정한다. remote_ssh 는
계정의 홈이 그 계정만의 것이라고 운영자가 선언할 때만 `guest_local` 을 받는다. 그 선언은
runtime.toml 의 해당 `[exec.ssh.endpoints.<name>]` 에 `private_home = true` 로 쓴다(기본 false).
선언이 없는 엔드포인트에서 `guest_local` 요청은 상자를 만들지 않고 judge 로 간다.

### 3.5 shim 이 못 하는 곳

Linux 가 아니거나 Landlock 을 못 만들면(`landlock_create_ruleset` 이 `ENOSYS`·
`EOPNOTSUPP`) shim 은 `Observe` 요청을 `shim_error = "observe_unsupported"` 로 거절한다.
게이트는 그것을 "지원 안 함" 으로 읽고 judge 로 보낸다. 조용히 `Effect` 로 바꾸지 않는다.

## 4. 판정 기준

1. 게스트에서 `Observe` 로 `sh -c 'echo x > /masc-work/<k>/probe'` 를 돌리면 0 이 아닌
   코드로 끝나고 파일이 없다. `curl https://github.com` 은 소켓에서 `EPERM` 으로 끝난다.
   `for f in a b; do echo $f; done` 과 `python3 -c 'print(open("x").read())'` 는 0 으로
   끝나고 결과가 keeper 에 그대로 간다.
2. 이틀치 judge 요청(§1.1)을 다시 흘리면, `observe` 에서 microvm 137건 + remote_ssh
   73건이 judge 를 건너뛰고, `guest_local` 에서 microvm 401건이 건너뛴다. 새로
   건너뛴 요청 중 네트워크에 닿은 것은 0 이다(소켓이 없으므로 구조적으로 0).
3. `test_exec_shim` 에 모드별 케이스. Landlock 없는 호스트(macOS 개발 빌드)에서는
   `observe_unsupported` 거절을 고정한다.
4. 배포 뒤 이틀, judge 로 간 tool_execute 가 하루 300 안팎에서 100 안팎으로 내려간다.
   남는 것은 네트워크 쓰기와 `git fetch/clone` 이어야 한다. #33356 의 gh HOME 우회
   스크립트가 0 이 된다(스크래치 HOME 이 생기므로 만들 이유가 없다).

## 5. 위험과 반론

- **읽기 전용 아래에서 다르게 행동하는 도구.** `git status` 는 index 를 갱신하려다
  실패해도 상태를 출력한다. `gh` 는 캐시를 스크래치에 쓴다. 읽기 도구가 0 이 아닌
  코드로 끝나면 judge 로 가는 것뿐이라 퇴행이 아니다. 어떤 도구가 그러는지는 §4-2
  의 재생이 알려 준다.
- **두 번 실행.** 쓰는 명령은 상자에서 한 번 실패하고 승인 뒤 다시 돈다. 첫 실행은 첫
  쓰기나 첫 소켓에서 끝나므로 보통 몇 밀리초다. `dune build` 처럼 오래 걸린 뒤 쓰는
  것은 `Observe` 에서는 `_build` 첫 쓰기에서 죽고, `guest_local` 에서는 아예 judge 를
  안 탄다.
- **부작용 있는 읽기.** 0 으로 끝났는데 뭔가 남았을 가능성은 커널 강제 위에서 없다.
  남는 것은 스크래치이고 실행 뒤 지운다. CPU·시간은 tool 예산이 막는다.
- **소켓을 전부 막는 것.** AF_UNIX 로 로컬 데몬에 말하는 도구가 있으면 `Observe` 에서
  실패해 judge 로 간다. 게스트에는 그런 데몬이 없다. remote_ssh 에서는 있을 수 있고,
  그때는 judge 가 지금처럼 본다.
- **seccomp 을 게스트에 거는 것.** `container run` 은 `--security-opt seccomp` 을
  받지 않는다(주석: "the guest kernel is the boundary"). 이 RFC 의 seccomp 은 shim 이
  자기 프로세스에 거는 것이라 런타임 옵션이 필요 없다.
- **shim 이 정적 musl 바이너리.** C stub 은 `prctl_stub.c` 처럼 `foreign_stubs` 로 붙고
  `scripts/build-shim-static.sh` 가 그대로 빌드한다. Landlock 과 seccomp 은 raw syscall
  이라 libc 지원이 필요 없다.

## 6. 이 RFC 가 정하지 않는 것

- `git fetch`·`git clone` 을 judge 없이 허용할지. 네트워크를 쓰는 읽기라 상자에서
  돌릴 수 없고, 표에 넣는 것은 자격증명을 실은 네트워크 요청을 허용하는 결정이다.
  RFC-0421 §6 그대로.
- judge 모델의 지연.

## 7. 구현 순서

1. `Exec_ssh_protocol` v3: `mode`. shim: Landlock·seccomp C stub, `Observe`/`Guest_local`
   분기, `observe_unsupported`. `test_exec_shim`. Linux 컨테이너에서의 실측을 PR 코멘트에.
2. microvm 기동에 `--tmpfs /tmp`. Apple 과 nerdctl 은 같은 Docker 문법으로 표현하고, msb 는 `Not_expressible` 로 기록.
3. 게이트(`Keeper_gate`)에 Observe 단계. 둘로 나눈다.
   - 3a: `decide ?observe` 콜백, exit 0 이면 새 출처 `observed_in_box` 로 allow, 그 외는
     지금과 같은 defer. 상자가 있는지는 shim 의 `--probe` `capabilities` 로 판단하고
     엔드포인트마다 한 번 기억한다. replay 는 `Effect`.
   - 3b: 거부된 실행의 종료 코드·stderr 를 approval 행(`request_context`)에 붙여 judge 가
     본다. 프로필 설정 `observation_run`(`guest_local` 스위치).
4. 재생 측정(§4-2)과 canary(keeper 하나, 하루) 뒤 기본 켬.

## 8. 고치는 것

RFC-0421 §6 의 "`/masc-work` 가 호스트 playground 마운트" 문장을 §1.2 의 사실로 바꾼다.

## 출처

- 게스트 실측 2026-09-05 12:5x UTC: `container exec masc-keeper-vm-sangsu-inherit-faea17a4`
  에서 `uname -r`, `/proc/cmdline`, `/proc/mounts`, `landlock_create_ruleset(NULL,0,VERSION)`
  (python3 ctypes, syscall 444), `seccomp(GET_ACTION_AVAIL)`. `sbx-sshd-probe` 에서
  `uname -r`, `/etc/passwd`.
- Landlock 문서 <https://docs.kernel.org/userspace-api/landlock.html> (2026-09-05 확인):
  ABI 1 파일시스템(5.13), 3 TRUNCATE, 4 TCP bind/connect, 6 abstract unix·signal 범위,
  7 audit 플래그, 10 UDP. 비특권 사용은 no_new_privs 필요.
- `container run --help` (Apple container 1.3.x): `--tmpfs`, `--read-only`, `--mount`, `--user`.
- `lib/exec_shim/exec_shim.ml` `spawn`, `lib/exec_shim/prctl_stub.c`, `lib/exec_ssh_protocol/`,
  `lib/keeper/keeper_sandbox_microvm.ml` (work volume, shim mount, `mount_args` 주석),
  `lib/keeper/keeper_microvm_backend.ml`.
- 집계: `~/me/.masc/tool_calls/2026-09/04.jsonl`, `05.jsonl` (`tool=Execute`,
  `disposition=deferred`), 쓰기·네트워크 여부는 명령어 토큰으로 근사.
