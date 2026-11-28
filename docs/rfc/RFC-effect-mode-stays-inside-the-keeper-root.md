---
rfc: "effect-mode-stays-inside-the-keeper-root"
title: "Effect 명령도 자기 Keeper root 밖을 읽지 못한다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
related: []
---

# RFC effect-mode-stays-inside-the-keeper-root: Effect 명령도 자기 Keeper root 밖을 읽지 못한다

- 상태: **초안.** 방향은 운영자가 정했다(2026-11-27). #37324 의 11-05 댓글이 낸 세 길 가운데 (3) 「같은 endpoint 끼리는 믿고 닫는다」를 거절했다. 운영자 말은 「기계당 다른 계정일 수 있다고 본다」였다.
- 계기: #37324 의 남은 2층. 1층(요청 root 를 Keeper root 로 맞추기)은 #37325 로 병합됐다.
- 코드 좌표는 `origin/main` `424198d565789` 에서 읽었다.
- 운영 숫자는 운영 workspace 의 tool call 장부와 운영자가 만든 endpoint 설정을 2026-11-27 에 읽어 셌다. endpoint·Keeper·계정 이름은 이 문서에서 가린다.
- endpoint 에 접속하거나 명령을 돌리지 않았다. 토큰도 읽지 않았다.

## 0. 요약

- 같은 endpoint 의 Keeper 는 같은 Unix 계정으로 돈다. 각자의 GitHub 토큰은 `<remote_root>/<keeper>/.config/gh` 에 있다.
- shim 은 Effect 명령을 상자 없이 돌린다. 그래서 Keeper A 의 `cat` 이 Keeper B 의 토큰 파일을 읽는다.
- 이 RFC 는 여섯 가지를 정한다.
  1. Effect 도 Landlock 상자 안에서 돈다. 네트워크는 막지 않는다(D1).
  2. 상자는 허용 목록이다. 자기 Keeper root, `/tmp`, 시스템·toolchain 읽기 경로만 연다(D2).
  3. 운영자가 더하는 경로가 Keeper root 를 덮으면 shim 이 설정을 거절한다(D3).
  4. Effect 의 `HOME` 은 자기 Keeper root 다(D4).
  5. 상자를 못 만드는 호스트에서는 Effect 를 거절한다(D5).
  6. 상자는 transport 를 가리지 않는다. microVM guest 도 같은 규칙이다(D6).
- 이 결정은 RFC-0422 §3.1 의 `mode = Effect (* 지금과 같다. 제한 없음 *)` 를 뒤집는다(§2).

## 1. 지금 모습

### 1.1 결함 경로

- Keeper root 는 `<remote_root>/<keeper>` 다(`lib/keeper/keeper_sandbox_remote.ml:234`·`:246`).
- gh 설정은 그 안의 `.config/gh` 다(`:260`). 매 요청에 `GH_CONFIG_DIR` 로 실린다(`:528`).
- #37325 뒤로 요청의 `remote_root` 는 Keeper root 다(`:1548`). shim 은 cwd 가 그 안인지만 본다.
- shim 은 `Effect` 를 `Run_effect` 로 바꾼다(`lib/exec_shim/exec_shim.ml:604`·`:605`). 이 갈래는 상자를 만들지 않는다(`:1466`).
- `cat` 은 관측 명령 표에 있어 judge 없이 돈다(`lib/keeper/keeper_gate_readonly.ml:91`).
- 경로 검사는 쓰는 명령(`rm`·`cp`·`mv` 등)의 operand 만 본다(`lib/exec_policy/execute_script_paths.ml:300`). 이름을 못 붙인 operand 는 그냥 보낸다(`:23`).
- 그래서 `cat <remote_root>/<이웃>/.config/gh/hosts.yml` 은 judge 도 상자도 거치지 않는다.
- 쓰기도 막히지 않는다. 이웃 checkout 의 `.git/hooks` 에 파일을 쓰면, 이웃이 다음 `git commit` 에서 그 코드를 자기 토큰으로 돌린다.
- 운영 runbook 도 이 경계를 적는다. 「Every keeper on an endpoint logs in as the same unix account」(`docs/operations/ssh-endpoints-runbook.md:281`).
- 오늘 재현하지 않았다. 판정은 코드 읽기다.

### 1.2 운영 endpoint 의 모양

- `remote_ssh` Keeper 13명이 endpoint 4곳을 쓴다(4·4·3·2명).
- endpoint 는 운영자가 만든 Linux 컨테이너 둘에 있다.
  - 컨테이너 A: endpoint 셋이 Unix 계정 셋이다. 계정마다 GitHub 계정 하나를 쓴다. Keeper root 는 그 계정 소유 `0700` 이다. 계정이 다르면 OS 권한이 막는다.
  - 컨테이너 B: Unix 계정 하나에 Keeper 넷이다. 팀 공유 디렉터리 `/masc-shared/<team>`(`0775`)를 따로 둔다.
- 두 컨테이너 모두 `remote_root=/masc-work` 다. `remote_root` 는 어느 계정 `HOME` 아래에도 있지 않다.
- 두 shim 설정의 `path=` 는 `/home/opam/.opam/5.5/bin` 으로 시작한다. env 파일은 `OPAMROOT=/home/opam/.opam` 을 준다.
- 같은 계정의 Keeper 는 그 계정의 `HOME` 도 같이 쓴다.
- 최근 masc PR 에 나온 Keeper 리뷰 계정도 endpoint 마다 하나다. 운영자는 이 배치에 기대지 않기로 했다.
- 커널이 Landlock 을 켰는지는 **확인 필요**다. RFC-0422 §1.2 는 다른 Apple container guest 에서 커널 6.18.35 와 `lsm=…landlock…` 을 쟀다(2026-09-05). 이 두 컨테이너는 재지 않았다. shim probe 의 `capabilities` 에 `observe` 가 있으면 Landlock ABI 1 이상이다.

### 1.3 Effect 명령이 실제로 쓰는 것

창은 2026-11-26 09:00 ~ 11-27 13:00 KST 다. `tool=Execute`, `sandbox_profile=remote_ssh` 기록은 10,892건이다. shim 영수증 10,803개는 모두 `mode=effect` 다.

| 명령 글자에 나온 것 | 기록 수 |
|---|---|
| `gh` | 6,779 |
| `git` | 1,118 (`push` 47, `fetch`·`clone`·`pull` 296) |
| `python`·`python3` | 621 |
| `dune` | 365 |
| `npm`·`pnpm`·`npx`·`yarn` | 341 |
| `opam` | 75 |
| `/tmp` | 940 |
| `/masc-work/…` | 1,429 (자기 root 1,415, 이웃 root 5) |
| `/masc-shared/…` | 297 (컨테이너 B 만) |
| `$HOME`·`~/` | 9 |
| `.config/gh`·`hosts.yml`·`/proc/`·`/dev/shm` | 0 |

- 이 숫자는 명령 글자에 그 낱말이 나온 기록 수다. 프로그램이 실제로 연 파일 수가 아니다. 예를 들어 `gh` 는 `hosts.yml` 을 글자 없이 읽는다.
- 이웃 root 5건은 모두 컨테이너 B 다. 둘은 이웃 root 의 opam toolchain 을 빌려 썼다. 셋은 이웃이 모은 데이터를 읽었다.
- 이 5건(0.05%)은 상자가 들어가면 실패한다. 공유할 것은 Keeper root 밖으로 옮겨야 한다(§6 배포 전 준비).

### 1.4 microVM 과 Docker

- microVM guest 는 workspace 와 Keeper 한 쌍에 하나다. 이름은 `masc-keeper-vm-<keeper>-<network>-<base_path>` 다(`lib/keeper/keeper_sandbox_container_name.ml:110`).
- guest 에 붙는 것은 자기 identity(읽기 전용), 자기 work·build volume, shim(읽기 전용), workspace 설정(읽기 전용)이다(`lib/keeper/keeper_turn_sandbox_runtime_start_failure.ml:207`).
- 이웃 Keeper 의 토큰은 guest 안에 없다. microVM 에는 이 결함이 없다.
- Docker 는 이미 Effect 를 거절한다(`keeper_sandbox_remote.ml:1513` `docker_observe_mode_required`).

## 2. RFC-0422 이 Effect 를 열어 둔 이유

RFC-0422 는 #53438 숙청으로 지워졌다. 원문은 `git show 3027df8afc334^:docs/rfc/RFC-0422-the-executor-proves-observation-the-judge-sees-only-what-the-sandbox-refused.md` 로 읽는다.

RFC-0422 의 주제는 judge 를 건너뛸 관측 증명이었다. Effect 를 열어 둔 근거는 따로 쓰지 않았다. 본문에서 읽히는 근거는 넷이고, 지금 맞는지는 이렇다.

| RFC-0422 의 근거 | 지금 |
|---|---|
| 승인된 요청은 replay 가 Effect 로 다시 돈다(§3.2). Effect 를 지키는 것은 표와 judge 다. | **맞지 않다.** 표와 judge 는 글자를 본다. `cat` 은 judge 없이 돈다. 경로는 커널만 강제한다. RFC-0422 도 상자를 「표나 파서가 틀릴 자리가 없다」고 골랐다. |
| guest 의 파일 쓰기는 호스트에 닿지 않고, 밖으로 나가는 길은 네트워크뿐이다(§1.2). | **microVM 에는 맞다.** §1.4 대로 guest 에 이웃이 없다. |
| Effect 는 네트워크와 쓰기가 필요하다(`gh pr create`, `git push`, `dune build`). Observe 상자는 둘 다 막는다. | **맞다.** 그래서 이 RFC 의 상자는 파일 시스템만 다룬다. 소켓은 막지 않는다. |
| 한 머신에 Keeper 계정이 여럿이면 「disposable guest」 전제가 성립하지 않을 수 있고, 성립시킬 의무도 없다(§1.2). 공유 계정은 §3.4 의 `private_home` 선언으로 `guest_local` 에서만 다뤘다. | **운영자가 뒤집었다**(2026-11-27). 같은 endpoint 의 Keeper 도 서로의 토큰을 읽지 못해야 한다. |

이 RFC 는 RFC-0422 §3.1 의 `mode = Effect (* 지금과 같다. 제한 없음 *)` 를 뒤집는다. Observe 와 Guest_local 의 상자는 그대로 둔다.

## 3. 결정

### D1. Effect 도 Landlock 상자 안에서 돈다

- 상자는 지금 Observe 상자와 같은 자리에서 건다. shim 이 fork 한 자식에서 exec 직전에 `no_new_privs` 와 Landlock ruleset 을 건다.
- `execution_plan` 의 `Run_effect` 는 없어진다. Effect 는 상자 있는 갈래 하나로만 돈다.
- seccomp 소켓 필터는 걸지 않는다. Effect 는 `gh`·`git` 으로 네트워크에 나가야 한다.
- 상자가 다루는 권한은 지금 Observe 와 같다. 커널 ABI 가 아는 파일 시스템 권한 전부다(`lib/exec_shim/observe_stub.c` `handled_fs_for_abi`).
- 상자의 root 는 요청의 `remote_root` 다. shim 은 이미 그것이 설정의 `remote_root` 안인지 본다.
- 서버가 endpoint root 로 보내는 요청이 둘 있다. 첫 `mkdir -p <keeper root>`(`:1777`)와 endpoint 점검(`:1947`)이다. 이 둘의 상자는 endpoint root 전체를 연다. 명령은 서버가 고정하고, Keeper 는 요청 root 를 고르지 못한다.

### D2. 상자는 허용 목록이다

| 경로 | 권한 |
|---|---|
| 요청 root(`<remote_root>/<keeper>`) | 상자가 다루는 권한 전부 |
| `/tmp` | 상자가 다루는 권한 전부 |
| `/usr` `/bin` `/sbin` `/lib` `/lib64` `/etc` `/opt` `/proc` `/sys` | 읽기·디렉터리 읽기·실행 |
| `/dev/null` | 읽기·쓰기(지금 상자와 같은 장치 번호 검사) |
| `/dev/zero` `/dev/urandom` `/dev/random` | 읽기 |
| shim 설정 `read_roots=` | 읽기·디렉터리 읽기·실행 |
| shim 설정 `write_roots=` | 상자가 다루는 권한 전부 |

- 그 밖에는 허용 규칙이 없다. 이웃 Keeper root 는 읽기도 쓰기도 안 된다.
- 호스트에 없는 내장 경로(예: `/lib64`)는 규칙을 만들지 않는다. 열 것이 없다.
- `/proc` 을 열어도 이웃 프로세스의 민감한 `/proc` 파일은 커널이 막는다. Landlock 은 도메인 밖 프로세스에 ptrace 계열 접근을 막는다(kernel 문서 「Ptrace restrictions」).
- 운영 컨테이너 둘은 `read_roots=/home/opam/.opam` 을 적는다. 컨테이너 B 는 `write_roots=/masc-shared/<team>` 을 적는다.

### D3. 설정이 Keeper root 를 덮으면 shim 이 거절한다

- Landlock 은 허용만 한다. 허용한 부모 아래의 경로 하나를 뺄 방법이 없다(kernel 문서). 그래서 겹침은 설정에서 막는다.
- `read_roots`·`write_roots` 의 항목이 `remote_root` 와 같거나, 그 조상이거나, 그 안이면 `remote_ssh_shim_config_error` 다.
- 내장 경로도 같은 검사를 받는다. 예를 들어 `remote_root` 가 `/opt` 아래면 설정을 거절한다.
- `path=` 의 항목이 허용 목록 밖이면 거절한다. 실행 때 `EACCES` 로 알기 전에 설정을 읽을 때 안다.
- 컨테이너 B 의 이웃 root 사용 5건은 이 규칙 때문에 설정으로 풀 수 없다. 공유할 것은 Keeper root 밖에 둔다.

### D4. Effect 의 `HOME` 은 자기 Keeper root 다

- 같은 계정의 Keeper 는 `HOME` 을 같이 쓴다(§1.2). `HOME` 이 같이 쓰기 가능하면 상자를 돌아가는 길이 생긴다.
  - A 가 `~/.gitconfig` 에 `core.hooksPath`·`credential.helper`·`core.fsmonitor` 를 적는다.
  - B 의 다음 `git` 이 그 명령을 B 의 상자 안에서 돌린다. 그 상자는 B 의 토큰을 읽는다.
- `HOME` 을 읽기 전용으로 두면 `npm`(341건)과 `~/.cache` 를 쓰는 도구가 깨진다.
- 그래서 Effect 의 `HOME` 은 요청 root 다. `TMPDIR` 은 `<요청 root>/.tmp` 다. shim 이 없으면 `0700` 으로 만든다.
- gh 는 바뀌지 않는다. `GH_CONFIG_DIR` 은 이미 `<요청 root>/.config/gh` 이고, 이것이 새 `~/.config/gh` 다.
- git 은 계정 `HOME` 의 `.gitconfig` 를 더 읽지 않는다. bootstrap 은 지금 `gh auth login` 만 한다(`bin/masc_exec_ssh_bootstrap.ml:624`). 같은 자리에서 `HOME=<keeper root>` 로 `gh auth setup-git` 을 돌려 credential helper 를 Keeper root 에 둔다.
- 캐시도 Keeper 마다 따로 생긴다. 디스크를 더 쓰고 첫 빌드가 느려진다. 대신 이웃이 캐시를 바꿔치기할 수 없다.

### D5. 상자를 못 만들면 Effect 를 거절한다

- shim 은 Landlock ABI 가 3 미만이면 Effect 요청을 거절한다. 오류 코드는 `effect_box_unsupported` 다. ABI 1·2 에서는 truncate 를 막지 못해 Keeper A 가 Keeper B 의 토큰 파일을 비울 수 있고, ABI 1 에서는 자기 root 안에서도 디렉터리를 넘는 rename 이 실패한다.
- 지금 규칙과 같다. `plan_for_mode` 는 「a box the kernel cannot build is a refusal, never a quiet fall back to running unboxed」 다(`exec_shim.ml:602`). Observe·Guest_local 은 `observe_unsupported`, Docker Effect 는 `docker_observe_mode_required` 로 거절한다. runbook 머리말도 「The lane is fail-closed」다.
- 상자 없이 돌리면 운영자가 거절한 (3)과 같아진다.
- probe 는 새 capability `effect_box` 를 광고한다. Observe 의 `observe` 와 따로 둔다. Effect 상자는 seccomp 가 없어도 된다.
- 서버는 probe 에 `effect_box` 가 없는 shim 에 Effect 를 보내지 않는다. 옛 shim 은 Effect 를 상자 없이 돌리기 때문이다. 거절은 typed 갈래로 오고 endpoint 점검이 보여 준다.
- 상자를 걸다 실패하면 지금처럼 거절 영수증으로 온다. payload 는 시작하지 않는다.

### D6. 상자는 transport 를 가리지 않는다

- shim 은 요청의 mode 와 커널의 답으로만 정한다. Effect 는 어디서 돌든 상자 안이다.
- microVM guest 는 이웃이 없어도 같은 규칙을 탄다. 규칙이 둘이면 둘째 규칙이 어느 날 remote_ssh 로 샌다.
- guest shim 설정은 masc 가 쓴다(`lib/keeper/keeper_sandbox_microvm_shim.ml:111`). 그 설정에 build volume `/masc-build` 를 `write_roots` 로, 이미지 toolchain 을 `read_roots` 로 적는다.
- Docker 는 지금처럼 Effect 를 거절한다.

### 헌법과의 관계

- `budget_gate` 는 안전·자원 경계를 금지 대상에서 뺀다. 이 상자는 그 경계다.
- 숫자나 문자열로 Keeper 흐름을 막지 않는다. 커널이 파일 접근을 거절하고, 명령은 `EACCES` 를 받는다.
- `gates/order` 는 게이트 추가를 success_bar 뒤로 미룬다. 이 상자는 흐름 게이트가 아니라 파일 권한 경계다. 운영자가 11-27 에 (3)을 거절하며 정했다.

## 4. 고르지 않은 길

### 4.1 endpoint 마다 Keeper 하나(#37324 의 (2))

- Keeper 마다 Unix 계정과 endpoint 를 따로 둔다. runbook 이 지금 권하는 길이다(`:284`).
- 장점:
  - 커널 DAC 가 막는다. Landlock 이 필요 없다.
  - Landlock 이 못 막는 것도 막는다. `chmod`·`stat`·신호·`/tmp` 바꿔치기다(§5).
  - 허용 목록을 관리하지 않는다.
- 단점:
  - endpoint 4개가 13개가 된다. 계정·SSH 키·host key pin·세션 상한도 13벌이다.
  - masc 는 두 endpoint 가 같은 Unix 계정인지 모른다. 설정 검사로 「Keeper 하나」를 강제해도 이름만 본다.
  - 공유 디렉터리는 그룹 권한으로 다시 짜야 한다.
- 이 RFC 는 이 길을 막지 않는다. 더 강한 분리를 원하는 운영자는 계정을 나눌 수 있다. 상자는 그 위에서도 그대로 돈다.

### 4.2 같은 endpoint 끼리는 믿고 닫는다(#37324 의 (3))

- 할 일이 없다.
- 운영자가 거절했다. 같은 기계의 Keeper 가 서로 다른 GitHub 계정일 수 있다.
- 읽기만의 문제가 아니다. 이웃의 `.git/hooks` 에 쓰면 이웃의 토큰으로 코드가 돈다(§1.1).

### 4.3 경로 검사표를 넓힌다

- `cat`·`find`·`python3` 의 operand 를 표에 더한다.
- #37324 본문이 이미 거절했다. 변수·glob·다른 언어 안의 경로는 이름을 못 붙이고, 표는 그때 통과시킨다(`execute_script_paths.ml:23`).
- 헌법 `string_matching` 과도 맞지 않는다.

## 5. 남는 위험

- **공유 `/tmp`.** 같은 uid 라 sticky bit 와 `protected_symlinks` 가 막지 못한다. A 가 `/tmp` 의 파일을 바꾸고 B 가 그것을 실행하면 B 의 상자 안에서 B 의 토큰을 읽는다. B 가 직접 실행해야 열리는 길이다. 열린 질문 1.
- **Landlock 이 못 막는 호출.** `chdir`·`stat`·`flock`·`chmod`·`chown`·`setxattr`·`utime`·`fcntl`·`access` 다(kernel 문서 「Current limitations」). A 는 이웃 파일이 있는지 알고, 모드를 바꿀 수 있다. 내용은 읽지 못한다.
- **신호.** 같은 uid 라 A 는 이웃 프로세스를 죽일 수 있다. 토큰 문제는 아니다. 열린 질문 3.
- **이름이 같은 Keeper.** 다른 workspace 의 같은 이름 Keeper 가 한 endpoint 를 쓰면 Keeper root 가 같다. 이 RFC 는 그것을 나누지 않는다.

## 6. 층

- 한 native stack 에 쌓는다. 맨 아래 층만 `main` 을 base 로 삼는다. 한 층이 20k token 출력을 넘으면 더 나눈다.
- 제안 순서:
  1. shim 설정이 `read_roots=`·`write_roots=` 를 읽고 D3 의 겹침을 거절한다. 아무도 이 키를 쓰지 않으므로 동작은 그대로다. `lib/exec_shim/exec_shim.ml` 의 `config`·`render_config`, `test/test_exec_shim.ml`.
  2. shim 의 Effect 상자. `observe_stub.c` 에 허용 목록 ruleset, `plan_for_mode` 의 Effect 갈래, `effect_box_unsupported`, probe 의 `effect_box`, D4 의 `HOME`·`TMPDIR`, D3 의 `path=` 검사. Linux 전용 시험(§9).
  3. 서버. probe 에 `effect_box` 가 없으면 Effect 를 거절한다(`runner_for_root`, interactive `prepare`, endpoint 점검 문구). microVM guest 설정에 D6 의 경로. bootstrap 의 `gh auth setup-git`.
  4. 문서(§10).
- 배포 전 준비(운영자):
  - 각 endpoint 의 probe `capabilities` 를 읽어 Landlock 을 확인한다.
  - 두 컨테이너의 shim 설정에 D2 의 `read_roots`·`write_roots` 를 적는다.
  - 컨테이너 B 에서 이웃 root 를 쓰던 toolchain 과 데이터를 Keeper root 밖으로 옮긴다.
- 배포 순서: 1층 shim 상태 유지 → shim 설정의 `read_roots=`·`write_roots=` 키 추가와 2층 shim 교체를 같은 배포 창에 묶는다 → 서버(3층). 키만 먼저 쓰면 1층 shim 이 모르는 키라서 모든 요청을 거절하고, 2층 shim 만 먼저 깔면 키가 없어 `path=` 의 opam 경로가 허용 목록 밖이라 역시 거절되므로 둘을 같은 창에 묶어야 한다. 서버가 먼저 가면 옛 shim 의 endpoint 에서 Effect 가 모두 거절된다.
- 2층 shim 만 깔려도 보호는 시작된다. shim 은 서버 버전과 상관없이 Effect 를 상자에 넣는다.

## 7. 열린 질문

1. **`/tmp` 를 나눌지.** 940건(8.6%)이 `/tmp` 를 글자로 쓴다. 후보는 셋이다.
   - 그대로 같이 쓴다(이 RFC 의 기본). §5 의 길이 남는다.
   - 요청마다 mount namespace 로 `/tmp` 를 `<요청 root>/.tmp` 에 붙인다. 비특권 user namespace 가 필요하다. 두 컨테이너가 허용하는지 확인해야 한다.
   - `/tmp` 를 목록에서 빼고 `TMPDIR` 만 둔다. 글자로 `/tmp` 를 쓰는 명령이 실패한다.
2. **`/dev/shm` 을 열지.** 창 안에서 0건이다. 열면 `/tmp` 와 같은 공유 길이 하나 더 생긴다.
3. **ABI 6 의 범위 제한을 같이 걸지.** ABI 6 은 범위 제한 둘을 준다. 도메인 밖 프로세스에 보내는 신호와 abstract unix socket 연결을 막는다. ABI 6 미만 커널에서는 걸지 못한다.
4. **Landlock 없는 호스트에 Keeper 하나만 둔 endpoint.** 이웃이 없어도 D5 는 거절한다. 예외를 두면 「이 endpoint 는 혼자다」라는 선언을 다시 믿어야 한다.
5. **거절 영수증의 갈래 이름.** 지금 Landlock 실패는 `Refused_write` 로 온다. Effect 상자는 읽기도 막으므로 이름이 맞지 않는다. 새 갈래를 둘지 2층에서 정한다.
6. **서버 `allowed_paths` 와 shim `write_roots` 를 어떻게 이을지(#38895).** 선언 루트는 지금 두 군데에 따로 적힌다.
   - 서버: `runtime.toml` endpoint 의 `allowed_paths` 다. 경로 문자열로 판정한다(`keeper_sandbox_remote_lane.ml` `extra_root_match`). 운영 endpoint 하나가 `["/masc-shared/wkbl"]` 을 쓴다.
   - shim: D2 의 `write_roots=` 다. 커널이 판정한다.
   - 둘이 맞는지 보는 곳이 없다. `allowed_paths` 에만 있는 루트는 서버가 통과시키고 커널이 거절한다.
   - 후보는 셋이다.
     - 서버가 probe 로 받은 `write_roots` 를 읽고, 두 목록이 다르면 endpoint 점검이 보여 준다.
     - 서버가 요청에 쓰기 루트를 실어 보낸다. shim 은 자기 목록 안의 것만 받는다.
     - `allowed_paths` 를 지우고 shim 설정을 하나뿐인 원본으로 둔다.
   - 선언 루트 자체가 링크인 경우도 남는다. D3 은 Keeper root 와 겹치는지만 본다.

## 8. 하지 않는 것

- Observe·Guest_local 상자와 judge·표는 바꾸지 않는다.
- Effect 의 네트워크를 막지 않는다.
- Keeper 마다 Unix 계정을 만드는 자동화를 만들지 않는다(§4.1).
- 이웃 root 를 쓰던 5건을 위해 예외를 두지 않는다. 운영자가 옮긴다.
- `/proc` 을 숨기거나 PID namespace 를 만들지 않는다.
- 이름이 같은 Keeper 를 workspace 로 나누지 않는다.

## 9. 검증

- shim 시험(`test/test_exec_shim_effect_box.ml`, `test/dune` 에 `(enabled_if (= %{system} linux))`):
  - 임시 endpoint root 아래 `a/` 와 `b/.config/gh/hosts.yml` 을 만든다. `hosts.yml` 에는 표식 문자열을 넣는다.
  - 요청 root `a` 의 Effect 로 `cat <root>/b/.config/gh/hosts.yml` 을 돌린다. exit 가 0 이 아니고, stderr 에 `Permission denied` 가 있고, stdout 에 표식이 없다.
  - 같은 요청의 `ls <root>/b` 와 `sh -c 'echo x > <root>/b/x'` 도 실패한다. `b/x` 는 생기지 않는다.
  - 같은 요청의 `cat <root>/a/.config/gh/hosts.yml`, `a` 와 `/tmp` 쓰기, `sh -c 'echo ok'` 는 성공한다.
  - 같은 요청의 `sh -c ': > <root>/b/.config/gh/hosts.yml'` (기존 파일 truncate) 도 실패해야 한다. ABI 3 미만에서는 성공해 버린다.
  - B 의 cwd 를 가진 프로세스를 띄우고 A 의 Effect 로 `cat /proc/<pid>/cwd/.config/gh/hosts.yml` 을 돌린다. 실패해야 한다. 이 결과는 시험이 정한다. 문서로 확인하지 못했다.
  - `HOME` 과 `TMPDIR` 이 D4 대로 오는지 본다.
- shim 설정 시험(`test/test_exec_shim.ml`): `read_roots` 가 `remote_root` 와 겹치면 거절, `path=` 가 목록 밖이면 거절.
- 서버 시험: probe 에 `effect_box` 가 없으면 Effect 요청을 보내지 않고 typed 거절을 낸다.
- 실측(운영자, 배포 뒤):
  - 같은 계정의 Keeper A 로 `cat <remote_root>/<B>/.config/gh/hosts.yml` 을 돌린다. tool call 장부에 `Permission denied` 와 상자 영수증이 남는다.
  - A 의 `gh pr view`, `git fetch`, `git push`, `dune build`, `npm ci` 가 성공한다.
  - 하루 뒤 같은 방법으로 장부를 센다. Effect 실패 가운데 자기 root 밖 경로의 `EACCES` 를 따로 센다.

## 10. 바뀌는 문서

이 PR 은 문서를 고치지 않는다. 구현 층에서 같이 고친다.

- `docs/operations/ssh-endpoints-runbook.md`: 「What one endpoint separates, and what it does not」(`:279`), 「Tools and environment the host declares」의 `HOME`·`TMPDIR`·`read_roots`·`write_roots`, 오류 표에 `effect_box_unsupported`.
- `docs/KEEPER-USER-MANUAL.md`·`.ko.md`: `remote_ssh` 절의 같은 내용.

## 출처

- RFC-0422 원문: 위 §2 의 `git show` 명령.
- Landlock 문서 <https://docs.kernel.org/userspace-api/landlock.html> (2026-11-27 확인): 허용만 하는 모델, Ptrace restrictions, Current limitations 의 호출 목록, ABI 6 범위 제한.
- 운영 숫자: 운영 workspace `.masc/tool_calls/2026-11/26*.jsonl`·`27*.jsonl`. `tool=Execute`, `sandbox_profile=remote_ssh`, 위 창의 `ts`. 명령 글자는 `input.command` 또는 `input.argv`, 영수증은 `execution_evidence.shim_execution_evidence.receipts[].receipt.mode`.
- endpoint 모양: 운영 workspace `.masc/ssh/` 아래 두 컨테이너의 entrypoint 와 `masc-exec-shim.conf`, env 파일의 변수 이름과 `OPAMROOT`. 토큰 파일과 키는 열지 않았다.
