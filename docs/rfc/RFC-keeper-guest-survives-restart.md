---
rfc: "keeper-guest-survives-restart"
title: "서버를 재시작해도 Keeper 게스트를 지우지 않는다"
status: Draft
created: 2026-10-21
updated: 2026-10-21
author: claude
related: ["keeper-boot-runs-no-one-shot-container", "keeper-build-output-returns-to-a-disposable-volume"]
---

# RFC: 서버를 재시작해도 Keeper 게스트를 지우지 않는다

- 상태: 초안. 운영자 결정 전이라 코드는 바꾸지 않았다.
- 이슈: #44333(컨테이너가 끝날 때 apiserver 가 답하지 않는다), #36993(adopt 판정이 런타임이 아니라 프로세스 기억을 본다).
- 근거: 코드 사실은 `origin/main` `e778d5306ef` 에서 읽었다. 측정은 이 Mac(container 1.3.1)에서 했다. 10-21 의 서버 재시작 두 번(10:17, 11:34)의 로그와 `ps` 표본, 11:51~12:11 의 20분 sampler, 12:12 의 `container inspect` 한 번이다. 시각은 모두 KST 다. `<base>` 는 base path 이고, 라이브는 `~/me` 다.
- 앞선 문서: RFC-keeper-boot-runs-no-one-shot-container(#44426). 그 RFC 는 부팅 helper 만 다루고 게스트 교체는 따로 다루기로 했다(그 RFC §10 Q3). 이 RFC 가 그 일이다. 그 RFC 에서 측정과 어긋난 곳은 이 커밋이 고쳤다(§9).
- 사람 리뷰 필요: §4.3 은 GitHub 자격 증명 사본을 디스크 어디에 얼마나 오래 두는지 정한다. 보안 결정이라 운영자가 직접 읽고 정해야 한다(§11 Q1, Q2).

## 0. 요약

서버를 재시작하면 masc 는 Apple backend 의 Keeper 게스트를 모두 지우고 다시 띄운다. 10-21 11:34 재시작에서는 startup sweep 이 옛 게스트 20개를 하나씩 지웠고 756.5초가 걸렸다. 그동안 어떤 microvm Keeper 도 부팅하지 못했다. 그 뒤 새 부팅마다 helper 가 한 번씩 끝났다. 20분 동안 helper 12개가 끝났고, 그 가운데 11개 뒤에 `container ls` 가 11~63초 막혔다. 10:17 재시작에서는 이 일이 시작 뒤 67분까지 이어졌다.

게스트를 지우는 이유는 게스트가 망가져서가 아니다. 다음 서버 프로세스가 그 게스트를 확인할 방법이 없다고 보기 때문이다. 이유는 셋이다.

1. startup sweep 은 게스트의 owner pid label 이 죽은 프로세스를 가리키면 지운다. 재시작하면 모든 게스트가 여기에 걸린다.
2. GitHub 자격 증명 사본이 어디 있는지는 그 서버 프로세스의 메모리에만 있다. 사본 자체는 `$TMPDIR` 의 임의 이름 디렉토리다.
3. 게스트를 무엇으로 부팅했는지(이미지, 크기, policy 포트)도 메모리에만 있다.

그런데 3은 대부분 런타임이 이미 알려 준다. 12:12 에 살아 있는 게스트 하나를 `container inspect` 했더니 이미지, CPU, 메모리, 실행 사용자, 마운트, 격리 설정이 모두 나왔다. 2도 자리를 게스트 이름에서 정하면 다음 프로세스가 찾을 수 있다.

이 RFC 는 세 가지를 바꾼다.

- 게스트를 띄울 때 부팅 계획의 digest 를 label 로 붙인다. 같은 이름으로 떠 있는 게스트는 누가 띄웠는지가 아니라 이 label 과 런타임이 보고하는 내용으로 판정한다. 계획이 같고 런타임이 그 계획대로 보고하면 adopt 한다.
- GitHub 자격 증명 사본은 게스트에 묶는다. 자리는 `<base>/.masc/microvm/identity/<backend>/<게스트 이름>/` 다. 게스트를 띄울 때 만들고, 게스트가 없다는 것을 목록으로 확인한 뒤 지운다.
- startup sweep 은 지금 선언에서 나오지 않는 게스트만 지운다.

그러면 재시작 뒤에 지우는 게스트도, 새로 띄우는 게스트도, 끝나는 helper 도 0 이어야 한다. 계획이 바뀐 Keeper 는 예외다. 배포 뒤에 그 수를 센다(§8 V5).

## 1. 결정

- D1. 게스트를 띄울 때 부팅 계획(§4.1)의 SHA-256 을 label `masc.mcp.boot_plan` 으로 붙인다. 떠 있는 게스트를 adopt 할지는 이 label 과, start 가 이미 부르는 `container inspect` 의 출력으로 정한다. CLI 호출은 늘지 않는다.
  - label 이 없거나 지금 계획의 digest 와 다르면: 교체한다.
  - label 이 같고 런타임의 보고가 계획과 같으면: adopt 한다.
  - label 이 같은데 런타임의 보고가 계획과 다르거나 읽을 수 없으면: start 를 거절하고 게스트는 그대로 둔다.
- D2. Apple backend 에서 `microvm_boots` 표를 지운다. 그 표가 기억하던 것은 D1 의 label 과 런타임 보고가 맡는다. nerdctl 은 inspect 에서 `.State.Running` 하나만 묻는다. 그래서 nerdctl 은 지금처럼 이 프로세스의 부팅 기록으로만 adopt 한다(§4.6).
- D3. 새로 띄운 게스트도 `run` 바로 뒤의 inspect(지금도 부른다)에서 D1 과 같은 확인을 한다. 런타임의 보고가 계획과 다르면 턴에 넘기지 않고 부팅 실패로 돌려준다. 게스트는 내리지 않는다. 그래서 다음 start 는 D1 의 세 번째 경우로 거절되고, 같은 게스트를 다시 띄우지 않는다(§4.2).
- D4. 부팅 계획은 부작용 없이 계산한다. 볼륨을 만들거나 지우지 않고, 네트워크를 조회하거나 만들지 않고, 사본을 쓰지 않는다. 부작용이 있는 단계는 `Boot` 분기에서만 돈다(§4.1).
- D5. GitHub 자격 증명 사본은 게스트에 묶는다(§4.3, 사람 리뷰 필요). 사본을 지우는 것은 그 게스트가 없다는 것을 성공한 목록 호출로 확인한 뒤뿐이다. 프로세스 전역 표 `microvm_identity_snapshots` 는 지운다.
- D6. startup sweep 은 이 base path 의 `keeper-vm` 게스트 가운데, 지금 선언된 어떤 Keeper 의 선언(프로필, backend, 네트워크 모드)에서도 나오지 않는 이름의 게스트만 지운다. owner pid 는 보지 않는다. 지운 게스트의 사본과, 목록에 없는 게스트의 사본도 지운다(§4.4).
- D7. shim 확인(sidecar 대조)은 모든 endpoint 가 지나는 자리로 옮겨, 이 프로세스에서 게스트마다 한 번 한다. shim 설정 다시 쓰기는 서버 시작 때 한 번 한다(§4.5).
- D8. 하드 컷이다. 이 변경 전 바이너리가 띄운 게스트에는 `masc.mcp.boot_plan` label 이 없다. 그래서 그 Keeper 의 첫 start 에서 한 번 교체된다. 옛 사본을 위한 reader 는 없다(§7).

## 2. 지금 구조

### 2.1 재시작 뒤 게스트가 지워지는 길

서버를 멈출 때 게스트를 지우는 코드는 없다. Keeper 의 게스트를 아주 내리는 것은 Keeper 가 해체되거나 멈출 때 도는 shutdown finalization 이다(`keeper_shutdown_finalize.ml:977-1000`, registry unregister 뒤). 그래서 재시작하면 옛 게스트가 그대로 떠 있다. 다음 프로세스는 세 군데에서 이 게스트를 지운다.

1. startup sweep. 서버가 뜨면 `Microvm_guest_sweep` 을 fiber 로 띄운다(`server_runtime_bootstrap.ml:1448-1449`). 경로는 `startup_sweep_microvm_guests`(`server_runtime_startup_maintenance.ml:115`) → `sweep_abandoned_microvm_guests`(`keeper_turn_sandbox_runtime.ml:45-64`) → `Keeper_sandbox_microvm.sweep_abandoned_guests`(`keeper_sandbox_microvm.ml:2566`) 다.
   - 후보: label 이 이 base path 의 `keeper-vm` 이고, `masc.mcp.owner_pid` 가 죽은 프로세스를 가리키는 게스트(`sweep_candidates_of_json`, `keeper_sandbox_microvm.ml:2477-2515`). label 의 pid 는 게스트를 띄운 프로세스다(`keeper_sandbox_runtime_setup.ml:247`). 재시작하면 모든 게스트가 후보다.
   - 지우기: 후보마다 `container delete --force` 를 하나씩 기다린다(`sweep_one_backend`, `keeper_sandbox_microvm.ml:2542-2553`).
   - 잠금: 이 전체를 `microvm_lifecycle_mutex` 안에서 한다(`keeper_turn_sandbox_runtime.ml:51`). 서버에서는 모든 부팅과 adopt 도 같은 잠금을 잡는다(`keeper_turn_sandbox_runtime.ml:39-43, 1872-1876`). 그래서 sweep 이 끝날 때까지 어떤 microvm Keeper 도 시작하지 못한다. 이 함수의 문서 주석은 다른 Keeper 의 준비를 VM 종료에 기다리게 하지 않는다고 적는다(`server_runtime_startup_maintenance.ml:111-114`). microvm Keeper 는 기다린다(§3.2).
2. start, 사본이 없을 때. 게스트가 `Running` 인데 이 프로세스에 사본이 없으면 지우고 다시 띄운다(`keeper_turn_sandbox_runtime.ml:1530-1536`).
3. start, 부팅 기록이 없을 때. 사본이 있어도 `microvm_boots` 에 기록이 없으면 `Replace_running_guest [ Boot_not_recorded ]` 다(`keeper_turn_sandbox_runtime.ml:240-241`).

지금은 1이 먼저 모두 지우므로 2와 3은 `Absent` 를 보고 바로 `Boot` 로 간다(`keeper_turn_sandbox_runtime.ml:1539-1541`). 1만 고치면 2와 3이 같은 게스트를 지운다. 셋을 같이 바꿔야 한다.

`microvm_boot` 의 주석은 재시작을 넘으면 이 기록도 사본도 알 수 없다고 적는다(`keeper_turn_sandbox_runtime.ml:154-157`). 같은 주석이 `container list --format json` 이 `resources.cpus`, `resources.memoryInBytes`, `image.reference` 를 보고한다고도 적고, 그 일을 #36993 으로 넘겼다(`keeper_turn_sandbox_runtime.ml:159-163`).

### 2.2 게스트가 자기를 띄운 프로세스에 기대는 것

`Boot` 분기가 `container run` 에 넘기는 것(`keeper_sandbox_microvm.ml:755-819`, `keeper_turn_sandbox_runtime.ml:1676-1732`)과, 다음 프로세스가 그것을 사실로 읽을 수 있는지다. inspect 자리는 12:12 에 polisher 게스트에서 본 것이다(§3.5). 아래 표의 줄 번호는 따로 적지 않으면 `keeper_turn_sandbox_runtime.ml` 이다.

| 무엇 | 지금 있는 곳 | 다음 프로세스가 읽는 곳 |
|---|---|---|
| Keeper, 네트워크 모드, base path | 게스트 이름(`:919-924`)과 label | 이름. 지금과 같다 |
| 이미지 | `microvm_boots`(메모리, `:164-170`) | inspect `configuration.image.reference`. 넘긴 문자열 그대로 나왔다 |
| CPU, 메모리 | `microvm_boots` | inspect `configuration.resources.cpus`, `memoryInBytes` |
| policy proxy 포트 | `microvm_boots` | inspect `configuration.initProcess.environment` 의 `HTTPS_PROXY`. 실제 게스트 테스트가 이미 이 값을 읽는다(`test/test_keeper_sandbox_microvm.ml:3275-3297`). proxy 는 재시작 때 새 ephemeral 포트를 잡으므로 policy 게스트는 재시작 뒤에도 교체된다. 지금 선언된 34개 Keeper 는 모두 `inherit` 다 |
| GitHub 자격 증명 사본 | 메모리 표 `microvm_identity_snapshots`(`:22-30`)와 `$TMPDIR/masc-gh-tool-XXXXXX/`(`keeper_github_identity.ml:625`) | 출처 경로는 inspect `configuration.mounts[]` 에 나온다. 하지만 이름이 임의라서, 그것이 masc 가 이 게스트에 만든 사본인지 다음 프로세스는 알 수 없다. 사본을 지우는 함수(`snapshot_cleanup`, `keeper_github_identity.ml:596-622`)는 클로저라 프로세스와 같이 사라진다 |
| 실행 사용자 `--user uid:gid` | 서버 프로세스의 uid | inspect `configuration.initProcess.user`(`502:20`) |
| work volume, build volume | 이름 있는 볼륨(런타임) | inspect `mounts[].type.volume.name` |
| config 마운트 `<base>/.masc/config` | 호스트 디렉토리 | inspect `mounts[].source` |
| exec shim | `<base>/.masc/microvm/shim`. 모든 게스트가 같이 붙이는 읽기 전용 디렉토리다(`keeper_sandbox_microvm.ml:1357-1359`, `config_dir_resolver.ml:520-521`) | 파일 시스템. shim 설정은 부팅 때마다 다시 쓴다(`:1076-1110`). 배포가 shim 을 바꾸면 떠 있는 게스트도 다음 요청부터 새 shim 을 쓴다(`scripts/install-local-build.sh:245-252`) |
| exec 통로 | 요청마다 `container exec` 하나. 소켓이나 포트를 들고 있지 않다 | 이름만으로 만든다. `microvm_attached_endpoint`(`:2436-2450`)가 이미 그렇게 한다 |
| 격리 설정 `--cap-drop ALL --read-only --tmpfs /tmp --rm` | argv | inspect `capDrop`, `readOnly`, `mounts[]` 의 tmpfs. `--rm` 은 inspect 에서 보지 못했다 |
| masc 가 넘긴 환경 변수 | argv | inspect `initProcess.environment`. 이미지의 환경 변수와 한 목록으로 섞여 나온다. 어느 것이 masc 가 넘긴 것인지는 보고에서 가를 수 없다 |
| DNS(`inherit` 의 `--dns`) | 부팅 때 호스트에서 읽는다 | inspect `configuration.dns.nameservers`. 지금도 adopt 는 이 값을 보지 않는다(`:304-308`). 그대로 둔다 |
| owner pid, 시작 시각 label | label | inspect `labels`. D6 뒤에는 owner pid 를 아무도 판정에 쓰지 않는다 |
| work root 를 만들었는지 | `microvm_work_roots_ready`(메모리, `:101-127`) | 다시 만든다. `mkdir -p` 라 몇 번 해도 같다. 이 프로세스가 아직 넘기지 않은 게스트는 endpoint 가 한 번 만든다(`:2401-2422`) |
| 잠금 | `microvm_lifecycle_mutex`(프로세스) | 해당 없다. 한 base path 에는 서버가 하나만 뜬다(§4.4) |

다른 backend:

- Docker persistent 컨테이너는 이미 재시작을 넘어 adopt 된다(`keeper_sandbox_runtime_setup.ml:194-199`, `keeper_turn_sandbox_runtime.ml:2061-2077`). 사본 대신 Keeper 의 고정 로그인 디렉토리를 읽기 전용으로 붙인다(`keeper_github_identity.ml:774-806`).
- nerdctl/Kata 는 inspect 에서 `{{json .State.Running}}` 하나만 묻는다(`keeper_sandbox_microvm.ml:2106-2114`). 전체 inspect 모양은 이 Mac 에 nerdctl 이 없어 재지 못했다.
- microsandbox(`msb`)는 masc 아래에서 부팅하지 않는다. `Drop_all_capabilities` 와 `Read_only_rootfs` 를 표현하지 못해서 부팅 argv 를 만들 때 거절된다(`keeper_microvm_backend.ml:101-104, 138-144`, `keeper_turn_sandbox_runtime.ml:1731-1736`).

## 3. 측정

### 3.1 재시작 두 번(10-21, 로그)

`~/me/.masc/logs/masc-start-1021-1016.log` 과 `masc-start-1021-1134.log` 의 "startup maintenance" 줄, "startup sweep: removed" 줄, helper 의 "trimmed" 줄을 셌다.

| 서버 시작 | sweep | 걸린 시간 | 지운 게스트 | 끝난 helper | helper 가 끝난 때 |
|---|---|---|---|---|---|
| 10:17:15 | 10:17:36 ~ 10:27:27 | 590.9초 | 21 | 22 | 10:28:54 ~ 11:24:12 (시작 뒤 11~67분) |
| 11:34:18 | 11:34:31 ~ 11:47:07 | 756.5초 | 20 | 18 (12:05:09 까지 센 값) | 11:47:45 ~ 12:05:09 |

게스트 하나에 평균 28.1초(10:17), 37.8초(11:34)다. sweep 시간을 지운 수로 나눈 값이라 처음의 `container list` 시간이 들어 있다.

### 3.2 게스트 삭제(11:34 재시작, `ps` 표본)

11:44:02 ~ 11:47:07 의 1초 간격 `ps` 표본에 sweep 의 마지막 삭제 다섯 개가 잡혔다. 원자료는 세션 scratchpad 의 `guest-churn-0245.tsv` 다.

| 게스트 | 걸린 시간(`ps` etime) |
|---|---|
| goo-yang-bong | 71초 |
| tui-developer | 69초 |
| indie-geek-blue | 59초 |
| wkbl-front | 11초 |
| geek-scout | 15초 |

- 하나가 끝나면 1~2초 안에 다음이 시작했다. 한 번에 하나씩 지운다.
- geek-scout 삭제가 11:47:07 에 끝났고, 첫 부팅의 볼륨 작업(masc-pro-builder 의 build volume)이 11:47:08 에 시작했다. sweep 이 잠금을 놓자 부팅이 시작했다.
- polisher 게스트를 지우는 동안 호스트에서 `container ls -a` 하나가 64.8초 걸린 뒤 `XPC timeout for request to com.apple.container.apiserver/containerList` 로 실패했다. 그때까지 이 재시작에서 helper 는 하나도 돌지 않았다. 삭제 중에 막힌 시간을 잰 표본은 이 하나뿐이다.

### 3.3 부팅 구간(11:51:33 ~ 12:11:31, 20분 sampler)

2초마다 `container ls -a` 의 걸린 시간을 재고, 그때 떠 있던 컨테이너 수명 주기 프로세스(`delete`, `run`, `stop`, `volume`)를 적었다. 삭제가 끝난 뒤의 부팅 구간이다.

- `ls` 342번: 중앙값 0.24초, 최대 62.9초, 12번은 XPC timeout 으로 실패했다.
- 20초를 넘긴 7번(26.0, 62.9, 60.6, 61.6, 33.0, 37.1, 26.6초)은 모두 어떤 helper 가 끝나고 2.5초 안에 시작했다.
- 게스트 `run` 은 12번 보였다. 그 뒤에 막힌 것은 없었다.
- helper 는 12개가 끝났다. 11개는 이름으로 보였고 pr-updater 는 `/masc-trim` 실행으로만 보였다. 11개 뒤의 막힘은 26.0, 0.3, 62.9, 60.6, 14.6, 33.0, 11.4, 37.1, 19.6, 11.8, 26.6초였다. 10개가 11초 넘게, 6개가 20초 넘게 막았다. pr-updater 뒤는 61.6초였다.

### 3.4 앞선 측정(#44333)

- 컨테이너가 끝나면 apiserver 가 40~65초 답하지 않을 수 있다. helper 플래그나 볼륨 가운데 하나만 있어도 그랬다.
- 플래그도 볼륨도 없는 컨테이너는 한 번 재서 약 5초였다.
- 실행 중인 scratch 컨테이너를 지울 때 약 12초 막혔다.

3.2 와 3.3 을 같이 보면 막힘은 컨테이너가 끝날 때 생기고, 시작할 때는 생기지 않았다. 재시작 한 번에 끝나는 컨테이너는 옛 게스트 20~21개와 helper 18~22개다.

### 3.5 런타임이 보고하는 것(12:12:33, polisher 게스트 inspect 한 번)

`container inspect masc-keeper-vm-polisher-inherit-faea17a4` 는 0.03초에 답했다. 환경 변수는 이름만 봤다.

- `configuration.image.reference`: `masc-sandbox-ocaml:20260928T0216Z-c48e1e05`. `descriptor.digest` 도 있다.
- `configuration.resources`: `cpus` 4, `memoryInBytes` 8589934592.
- `configuration.initProcess.user`: `502:20`. `workingDirectory`, `executable`, `arguments` 도 있다.
- `configuration.initProcess.environment`: `GH_CONFIG_DIR`, `GIT_CONFIG_GLOBAL`, `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME` 와 이미지의 `OPAM*`, `PATH`, `HOME` 등이 섞여 있다.
- `configuration.mounts` 6개. `type` 객체의 키가 종류를 말한다.
  - `/tmp`: `tmpfs`
  - `/tmp/masc-runtime/.masc/config` ← `<base>/.masc/config`, `virtiofs`, `ro`
  - `/tmp/masc-runtime/.masc/keepers/polisher/github-cli` ← `$TMPDIR/masc-gh-tool-5dc88c`, `virtiofs`, `ro`
  - `/masc-work` ← `volume`, 이름 `masc-keeper-work-polisher`
  - `/masc-build` ← `volume`, 이름 `masc-keeper-build-polisher`
  - `/opt/masc-exec-shim` ← `<base>/.masc/microvm/shim`, `virtiofs`, `ro`
- `readOnly` true, `capDrop` `["ALL"]`, `capAdd` `[]`, `networks` 는 `default` 하나, `dns.nameservers` 하나.
- `labels`: base path hash, component, keeper, kind `keeper-vm`, `microvm_backend`, network, `owner_pid`, `started_at`.

`lib/lane_addon/lane_addon_engine.ml:127-159` 가 이미 같은 inspect 에서 `resources`, `readOnly`, `capDrop` 을 읽어 판정한다.

### 3.6 GitHub 자격 증명 사본(10-21 12:04, 파일 이름과 권한만 봤다)

- 서버의 `$TMPDIR`(0700)에 `masc-gh-tool-*` 디렉토리가 2,393개 있다. 309개는 `masc-gh-tool-empty-*` 다.
- 그 가운데 424개에 `hosts.yml` 이 있다(디렉토리 0500, 파일 0400). 가장 오래된 `hosts.yml` 은 10-18 15:48 에 쓰였고, 10-21 에 생긴 것이 98개다.
- 재시작으로 지워진 게스트의 사본은 아무도 지우지 않는다. sweep 도, 2.1 의 2번 길도 사본을 모른다. 10-21 에 서버는 여섯 번 떴고, 로그인한 Keeper 는 25개다(`<base>/.masc/keepers/*/github-cli/hosts.yml`). 사본을 만드는 다른 곳(Docker turn lane `keeper_sandbox_docker.ml:559`, 테스트)이 남긴 것과 나눠 세지는 않았다(U5).
- 고정 로그인 디렉토리 `<base>/.masc/keepers/<name>/github-cli/` 는 0700, 그 안의 `hosts.yml` 은 0600 이다. 같은 토큰이 원래 여기 있다.
- `tmutil isexcluded` 로 보면 `$TMPDIR` 은 백업에서 빠지고 `~/me/.masc` 는 빠지지 않는다. 이 Mac 에는 백업 대상이 설정되어 있지 않다.

### 3.7 build volume

- build volume 의 superblock 에는 `discard` 기본값이 없다(polisher, rondo 모두 `s_default_mount_opts` 가 0). work volume 은 있다(polisher `0x0400`).
- 그래서 build volume 은 게스트가 지운 블록을 호스트에 돌려주지 않는다. 지금은 새 부팅마다 build volume 을 지우고 다시 만드는 일이 그 공간을 돌려준다(`keeper_sandbox_microvm.ml:1758-1767`). 기본 크기는 128g 다(`env_config_sandbox.ml:278-280`).
- 지금 34개 build volume 의 호스트 크기는 0.02~0.38 GiB 다. 오늘 다시 만들어져서 작다. 게스트 하나가 며칠 사는 동안 얼마나 커지는지는 재지 않았다.

### 3.8 모르는 것

- U1. 게스트 삭제 중의 막힘은 한 번(64.8초) 쟀다. 삭제마다 막히는지는 모른다. 이 RFC 는 재시작 때의 삭제 자체를 없애므로, 답이 나와도 설계는 바뀌지 않는다.
- U2. nerdctl `inspect --mode dockercompat` 전체 문서의 모양은 재지 않았다.
- U3. 옛 서버의 턴이 게스트 안에 띄운 프로세스가 옛 서버가 죽은 뒤에도 사는지 재지 않았다. shim 은 transport EOF 에서 payload 의 process group 을 끝낸다(`docs/guides/KEEPER-VM-BUILD-CLEANUP.md`). `setsid` 로 빠져나간 프로세스는 남을 수 있다.
- U4. build volume 이 게스트 수명 동안 얼마나 커지는지(§3.7).
- U5. 하루 98개의 사본이 재시작 때문이라는 것은 크기만 맞춰 본 추정이다. 재시작마다 로그인한 Keeper 의 게스트 수만큼(많아야 25개) 남는다면 여섯 번에 많아야 150개이고, 98개는 그 안에 든다(§3.6).
- U6. inspect 가 timeout 으로 끝나도 `probe_microvm_container_state` 는 `Absent` 로 읽는다(§4.3). 지금도 이 때문에 `Boot` 분기가 떠 있는 게스트를 `delete --force` 하거나, 떠 있는 게스트가 붙인 사본을 지울 수 있다. 이 RFC 는 사본에 대해서만 "없다"의 뜻을 바꾼다. probe 자체는 따로 다룬다.

## 4. 설계

### 4.1 부팅 계획, label, 런타임 사실로 adopt 판정 (D1, D2, D4)

부팅 계획은 `container run` 에 넘길 값 가운데 호스트 상태에 따라 바뀌지 않는 것을 모은 record 다.

```ocaml
type guest_mount =
  | Tmpfs of { destination : string }
  | Host_dir of { source : string; destination : string; read_only : bool }
  | Named_volume of { name : string; destination : string }

type plan_network =
  | Plan_network_none
  | Plan_network_inherit                       (* DNS 값은 넣지 않는다 *)
  | Plan_network_policy of { network : string } (* gateway 와 포트는 넣지 않는다 *)

type boot_plan =
  { image : string
  ; guest_size : Keeper_microvm_guest_size.t
  ; user : string                              (* "uid:gid" *)
  ; working_directory : string
  ; command : string list
  ; mounts : guest_mount list
  ; isolation : Keeper_microvm_backend.guest_constraint list
  ; network : plan_network
  ; environment : (string * string) list       (* masc 가 넘기는 것만 *)
  ; labels : (string * string) list            (* owner pid, started_at, boot_plan 은 넣지 않는다 *)
  }
```

- argv 는 이 record 와, 부팅 때만 정하는 값(DNS 서버, policy gateway 와 포트)으로 만든다. 같은 것을 두 군데서 따로 만들면 둘이 어긋나기 때문이다.
- digest 는 이 record 를 키 순서가 정해진 JSON 으로 만든 뒤의 SHA-256 이다. label `masc.mcp.boot_plan` 의 값이 된다. 12:12 의 inspect 에서 label 은 넘긴 값 그대로 나왔다(§3.5).
- 계산에 부작용이 없다(D4). 볼륨은 이름만 쓴다(`work_volume_name`, `build_volume_name` 은 순수 함수다). 지금 `microvm_guest_provisions` 는 build volume 을 지우고 다시 만들고(`keeper_sandbox_microvm.ml:1767-1789`), `ensure_policy_network` 는 네트워크를 조회하거나 만들고(`keeper_turn_sandbox_runtime.ml:621-674`), `docker_args_for_tool` 은 사본을 쓴다. 이 셋은 계산에 쓰지 않고 `Boot` 분기에서만 부른다. git 연결 여부(`GIT_CONFIG_GLOBAL`)는 고정 로그인이 아니라 그 게스트의 사본 디렉토리에서 읽는다. 로그인이 바뀐 것은 revision 비교(§4.3)가 따로 맡기 때문이다.

런타임이 보고하는 사실은 start 가 이미 부르는 inspect 에서 읽는다. 지금 `probe_microvm_container_state` 는 같은 출력에서 `status.state` 만 읽는다(`keeper_turn_sandbox_runtime.ml:831-845`).

```ocaml
type guest_facts_reading =
  | Facts of
      { plan_label : string option
      ; image : string
      ; guest_size : Keeper_microvm_guest_size.t
      ; user : string
      ; working_directory : string
      ; command : string list
      ; mounts : guest_mount list
      ; read_only : bool
      ; cap_drop : string list
      ; cap_add : string list
      ; networks : string list
      ; environment : (string * string) list
      }
  | Not_reported of Keeper_microvm_backend.t  (* 이 backend 의 inspect 는 사실을 주지 않는다 *)
  | Unreadable of string                      (* 있어야 할 자리에 없거나 모양이 다르다 *)
```

마운트 종류는 Apple 의 `type` 객체 키(`tmpfs`, `virtiofs`, `volume`)로 나눈다. 모르는 키는 `Unreadable` 이다.

판정 순서:

1. `Unreadable`: start 를 거절한다(새 실패 `Guest_facts_unreadable`). 게스트는 지우지 않는다.
2. `plan_label` 이 없거나 지금 계획의 digest 와 다르다: `Replace_running_guest`. reason 에는 사실로 보이는 차이(이미지, 크기, 사용자, 마운트, 격리, 네트워크)를 모두 적고, 사실로 안 보이는 차이(환경 변수, `--rm`)는 `Plan_changed` 로 적는다.
3. policy 모드에서 `HTTPS_PROXY` 의 포트가 지금 lane 이 잡은 포트와 다르다: `Replace_running_guest [ Policy_route_stale ]`. 지금 `policy_route_holds`(`keeper_turn_sandbox_runtime.ml:194-203`)의 규칙과 같다.
4. 사본 디렉토리(§4.3)를 읽지 못한다: `Replace_running_guest [ Identity_unreadable ]`.
5. 사실이 계획과 다르다: start 를 거절한다(새 실패 `Runtime_reports_other_than_asked`, 다른 자리를 모두 적는다). 게스트는 지우지 않는다. 환경 변수는 계획의 이름마다 값이 같은지만 본다. 런타임 목록에는 이미지의 환경 변수가 섞여 있기 때문이다.
6. 모두 같다: `Adopt_running_guest`.

label 이 왜 필요한가. 사실만으로는 두 경우를 가를 수 없다.

- Keeper 가 다른 것을 요구하게 됐다(이미지가 바뀌었다). 교체해야 한다.
- masc 는 같은 것을 요구했는데 런타임이 다르게 보고한다(예: 메모리를 반올림했거나, 경로를 다른 모양으로 돌려준다). 교체하면 새 게스트도 같은 보고를 하고, 다음 start 가 또 교체한다. 교체마다 컨테이너가 하나씩 끝난다.

label 은 masc 가 그 게스트에 무엇을 요구했는지를 런타임 안에 남긴다. 그래서 2는 교체하고 5는 거절해서, 같은 게스트를 계속 다시 띄우지 않는다. 또 런타임 보고에서 가를 수 없는 사실(masc 가 넘긴 환경 변수, `--rm`)도 label 이 덮는다. 따로 저장하는 곳은 없다. label 은 게스트에 붙어 있고 게스트와 같이 없어진다.

같은 프로세스 안의 adopt 도 이 판정을 쓴다. 메모리 기록과 런타임 사실을 같이 두지 않는다. #36993 이 묻던 것은 Apple 에서는 이것으로 끝난다. `Not_reported`(nerdctl)는 §4.6 이다.

### 4.2 새로 띄운 게스트 확인 (D3)

`run` 이 0 으로 끝나면 지금은 `inspect_container_exists` 로 게스트가 있는지만 보고 출력은 버린다(`keeper_turn_sandbox_runtime.ml:813-827, 1780-1786`). 그 출력을 4.1 로 읽는다.

- 판정이 adopt 와 같다(label 이 계획과 같고 사실도 같다): 지금처럼 work root, `_build` 링크 scan 을 하고 넘긴다.
- 사실을 못 읽거나 계획과 다르다: 턴에 넘기지 않고 `Booted_guest_unusable { check = Runtime_reports_other_than_asked; ... }` 로 실패한다. 게스트는 내리지 않는다.

게스트를 내리지 않는 이유: 내리면 다음 start 가 `Absent` 를 보고 다시 띄우고, 같은 보고에 또 내린다. start 마다 `run` 과 `delete` 가 하나씩 생긴다. 남겨 두면 다음 start 는 4.1 의 5번으로 거절하고 컨테이너를 건드리지 않는다. 지금 `Adopted_guest_volume_unverified` 가 같은 이유로 게스트를 남겨 둔다(`keeper_turn_sandbox_runtime.ml:1545-1553`). 운영자가 게스트를 지우거나 코드가 고쳐지면 다음 start 가 다시 판정한다.

남겨 둔 게스트에도 읽기 경로(`microvm_attached_endpoint` 를 쓰는 곳)는 exec 할 수 있다. 지금 `Adopted_guest_volume_unverified` 로 남긴 게스트도 그렇다.

### 4.3 GitHub 자격 증명 사본 (D5) — 사람 리뷰 필요

이 절은 토큰 사본을 디스크에 두는 자리와 기간을 바꾼다. 운영자가 직접 읽고 정한다(§11 Q1, Q2). 이 절의 줄 번호는 따로 적지 않으면 `keeper_turn_sandbox_runtime.ml` 이다.

자리와 권한:

- 자리는 `<base>/.masc/microvm/identity/<backend>/<게스트 이름>/` 다. `<backend>` 는 `Keeper_microvm_backend.to_string`(`apple_container`, `nerdctl_kata`)이고 Keeper 의 meta 가 정한다. 게스트 이름은 Keeper, 네트워크 모드, base path hash 로 정해진다(`:919-924`). 그래서 다음 프로세스가 같은 자리를 계산한다. backend 를 경로에 넣는 이유는, 사본 정리(§4.4)가 어느 런타임의 목록과 맞춰 볼지 알아야 하기 때문이다. 자리를 정하는 함수는 `Config_dir_resolver.microvm_shim_dir` 옆에 둔다.
- `identity/` 와 `identity/<backend>/` 는 0700, 게스트 디렉토리는 0500, 파일(`hosts.yml`, `config.yml`, `gitconfig`)은 0400 이다. 주인은 서버 uid 다. 게스트 디렉토리와 파일의 권한은 지금 사본과 같다(`keeper_github_identity.ml:626-653`). `<base>/.masc/microvm` 은 지금 0755 이므로 `identity/` 의 0700 이 다른 사용자를 막는다.
- 자리가 임의 이름에서 정해진 이름으로 바뀐다. 그래서 쓰기 전에 `identity/` 와 `identity/<backend>/` 가 링크가 아닌 디렉토리이고, 주인이 서버 uid 이고, 권한이 0700 인지 `lstat` 으로 본다. 아니면 부팅을 거절한다.
- 내용은 지금 사본과 같다. 로그인한 Keeper 는 고정 로그인 디렉토리의 `hosts.yml`, `config.yml` 사본과, 거기서 만든 `gitconfig` 를 받는다. 로그인하지 않은 Keeper 는 빈 디렉토리를 받는다.
- 게스트에는 자기 디렉토리 하나만 읽기 전용으로 붙인다. 다른 게스트의 사본은 보이지 않는다. 지금과 같다.

"게스트가 없다"의 뜻: 사본을 지우거나 새로 쓰는 것은 그 게스트가 없을 때뿐이다. 그런데 지금 `probe_microvm_container_state` 는 inspect 가 0 이 아닌 값으로 끝나면 모두 `Absent` 로 읽는다(`:843-844`). `Process_eio` 의 timeout 도 상태 값(`WEXITED timeout_exit_code`, `process/process_eio.ml:156, 1185-1197`)으로 돌아오므로 `Absent` 가 된다. 3.2, 3.3 에서 잰 XPC timeout 이 바로 이 경우다. 자리가 정해진 이름이 되면, 이 잘못된 `Absent` 하나로 떠 있는 게스트가 붙인 디렉토리를 지우거나 덮어쓴다. 그래서 사본에 대해서는 "없다"를 이렇게 정한다. 그 Keeper 의 게스트 목록 호출(`list_live_containers_for`, `keeper_sandbox_microvm.ml:2435-2475`)이 성공했고, 그 목록에 그 이름이 없다. inspect 의 실패는 "없다"가 아니다. 목록 호출이 실패하면 사본은 그대로 둔다.

만들기(`Boot` 분기에서):

1. 위의 뜻으로 그 이름의 게스트가 없는지 본다. 있거나 모르면 부팅을 거절한다.
2. 같은 자리에 디렉토리가 남아 있으면 아래 "지우는 방법"으로 지운다. 그 이름의 게스트가 없으므로, 남은 것은 사라진 게스트의 것이다.
3. `identity/<backend>/<게스트 이름>.partial-XXXXXX` 를 만들어 파일을 쓰고 권한을 잠근 뒤, `identity/<backend>/<게스트 이름>` 으로 `rename` 한다. 쓰다가 서버가 죽으면 `.partial-*` 만 남는다.
4. `run` 이 실패하고 1 의 뜻으로 게스트가 없으면 지운다. 지금 `release_unmounted_identity`(`:1631-1638`)가 하는 일이다.

읽기(adopt 때):

- 4.1 의 마운트 비교와 label 이 그 게스트의 GitHub 마운트 출처가 이 자리인지 본다.
- 디렉토리를 파싱한다. 링크를 따라가지 않고 주인과 권한을 확인한다. 지금 `load_optional_config_file` 이 쓰는 `Fs_compat.load_owned_regular_file ~ownership_root` 방식이다. 결과는 셋이다. `Unconfigured`(파일이 없다), `Configured revision`(`hosts.yml` 이 있다. revision 은 지금처럼 `configured_tool_identity_revision` 으로 그 디렉토리에서 계산한다, `keeper_github_identity.ml:567-587`), `Unreadable`. 모르는 파일, 링크, 다른 권한은 `Unreadable` 이고 4.1 의 4번으로 교체된다.
- revision 이 고정 로그인과 다르면 게스트를 교체하는 일(`prepare_github_identity_secret_files`, `:2570-2650`)과, 출력에서 토큰을 가릴 파일 목록(`github_identity_secret_files`, `:361-369`)은 그대로다. 경로만 바뀐다.

지우기(누가 게스트를 지우든):

- masc 가 지울 때: 모든 길이 `stop_and_delete_microvm_container`(`:971-1008`)를 지난다. 이 함수는 지금 inspect 로 게스트가 없어졌는지 본 뒤에 work root 와 부팅 기록을 잊는다(`:985-989`). 사본은 그 뒤에, 위의 뜻(성공한 목록에 이름이 없다)으로 한 번 더 보고 지운다. 그러면 stale 모드 정리, 교체, 부팅 뒤 내리기, 경합에서 진 쪽, Keeper teardown(`:1961-1973`), 로그인 갱신(`:2515-2529`)이 모두 사본을 지운다. 지금 길마다 따로 부르는 `release_registered_microvm_identity` 는 없어진다. 목록 호출이 하나 늘지만, 게스트를 지우는 일 자체가 드물어진다.
- startup sweep 이 지울 때: 지운 게스트의 사본을 지운다(§4.4).
- 운영자가 `container delete` 로 지웠거나 호스트 재부팅으로 게스트가 사라졌을 때: 다음 서버 시작의 사본 정리(§4.4)나 그 이름의 다음 부팅(만들기 2)이 지운다. 그때까지는 남는다.

지우는 방법: 게스트 디렉토리는 0500 이라 그대로는 안의 파일을 지울 수 없다. `Fs_compat.remove_tree` 는 권한을 바꾸지 않는다(`fs_compat/fs_compat.ml:1659-1671`). 지금 `snapshot_cleanup` 은 만들 때 열어 둔 descriptor 로 먼저 `fchmod 0o700` 한다(`keeper_github_identity.ml:596-622`). 다른 프로세스가 지울 때는 그 descriptor 가 없다. 그래서 이렇게 한다.

1. `lstat` 으로 링크가 아닌 디렉토리이고 주인이 서버 uid 인지 본다.
2. 디렉토리를 열고 `fstat` 의 device·inode 가 1 과 같은지 본다.
3. 그 descriptor 로 `fchmod 0o700` 한 뒤 `Fs_compat.remove_tree` 로 지운다.

어느 단계든 실패하면 그 디렉토리는 남기고 WARN 한 줄을 쓴다. 부팅의 만들기 2에서 실패하면 그 부팅은 거절된다.

서버가 멈춘 동안 호스트 디스크를 읽을 수 있는 사람(같은 사용자나 root)이 얻는 것:

| | 지금 | 이 RFC 뒤 |
|---|---|---|
| 고정 로그인 `<base>/.masc/keepers/<name>/github-cli/hosts.yml` | 있다(25개) | 같다 |
| 떠 있는 게스트의 사본 | 게스트마다 하나, `$TMPDIR` | 게스트마다 하나, `<base>/.masc/microvm/identity/<backend>/` |
| 지워진 게스트의 사본 | 아무도 지우지 않는다. `hosts.yml` 이 든 것이 424개(10-21 12:04) | 게스트와 같이 지운다. 운영자가 손으로 지운 게스트의 것은 다음 서버 시작까지 남는다 |
| 사본 안의 토큰 | 사본을 만들 때의 로그인. 그 뒤 갱신된 옛 토큰도 남아 있다 | 떠 있는 게스트가 지금 쓰는 로그인 |
| 백업 | `$TMPDIR` 은 Time Machine 에서 빠진다 | base path 는 빠지지 않는다. 고정 로그인이 이미 base path 에 있다 |

새로 드러나는 토큰은 없다. 같은 토큰이 이미 고정 로그인 자리에 있다. 바뀌는 것은 사본이 서버 프로세스보다 오래 산다는 점이다. 지금도 사본은 서버보다 오래 살지만, 그때는 아무도 지우지 않는 채로 산다.

### 4.4 startup sweep (D6)

후보는 이 base path 의 `keeper-vm` 게스트(`masc.mcp.base_path_hash`, `masc.mcp.kind`, `masc.mcp.component` label. 지금 `keeper_sandbox_microvm.ml:2496-2503` 과 같다) 가운데, 이름이 지금 선언에서 나오지 않는 것이다.

- 선언은 `<keepers_dir>/*.toml` 을 서버가 Keeper 를 올릴 때 쓰는 loader(`Keeper_types_profile_toml_io.load_keeper_toml`, `keeper_types_profile_toml_io.ml:112-123`)로 읽는다. Keeper 이름은 파일 이름이 아니라 이 loader 가 주는 이름이다(`keeper.name` 이 있으면 그것).
- 선언마다 프로필, backend(`microvm_backend_of_profile_defaults`, `keeper_meta_contract.ml:252-256`), 네트워크 모드를 읽고, 프로필이 `microvm` 이고 backend 가 이 목록의 backend 이면 그 선언이 만드는 게스트 이름(`microvm_container_name`, `keeper_turn_sandbox_runtime.ml:919-924`)을 계산한다.
- 그 이름들에 없는 게스트가 후보다. 이렇게 하면 해체된 Keeper, 프로필이 Docker 나 remote_ssh 로 바뀐 Keeper, backend 가 바뀐 Keeper, 네트워크 모드가 바뀐 Keeper 의 옛 게스트가 모두 후보가 된다. 지금 sweep 은 재시작 때 이것들을 모두 지운다. 이 RFC 뒤에도 지운다.
- keepers 디렉토리를 못 읽으면 아무것도 지우지 않는다. 선언 하나를 못 읽으면 그 파일 이름의 Keeper label 을 단 게스트는 지우지 않는다.

owner pid 를 보지 않아도 되는 이유: 한 base path 에는 서버가 하나만 뜬다. 서버는 시작할 때 base path lease 를 잡고, 다른 서버가 이미 잡고 있으면 끝난다(`bin/main_eio.ml:587-600, 655-656`, `server_startup_takeover.ml:1616`). 그래서 이 base path hash 를 단 게스트는 지금 이 서버의 것이다. 다른 base path 의 서버가 같은 호스트에 있어도 hash 가 달라 후보가 되지 않는다. 지금과 같다.

선언과 이름은 맞는데 계획이 바뀐 게스트(이미지나 크기가 바뀌었다)는 sweep 이 지우지 않는다. 그 Keeper 의 첫 start 가 4.1 로 교체한다. sweep 에서 지워도 삭제 수는 같고, 그동안 모든 Keeper 의 시작이 잠금 뒤에서 기다린다.

사본 정리: sweep 은 backend 마다 이미 목록을 부른다(Apple 은 `container list -a --format json`). 목록을 읽은 backend 에 대해서만, 그 목록에 이름이 없는 `identity/<backend>/<이름>` 과 `identity/<backend>/*.partial-*` 를 지운다(§4.3 의 지우는 방법). 목록 호출이 실패했거나, CLI 가 PATH 에 없거나, 목록을 낼 수 없는 backend(`Listing_not_established`, `keeper_sandbox_microvm.ml:2283-2304`)의 사본은 지우지 않는다. 게스트가 없다는 것을 보이지 못했기 때문이다.

잠금은 그대로 잡는다. 후보가 없으면 목록 호출과 선언 읽기 동안만 잡는다. 목록 호출은 3.3 에서 중앙값 0.24초, 막힐 때 62.9초였다.

owner pid label: D6 뒤에는 keeper-vm 게스트의 `masc.mcp.owner_pid` 를 아무도 판정에 쓰지 않는다. adopt 된 게스트에서는 죽은 프로세스를 가리킨다. 그래서 keeper-vm 게스트에는 붙이지 않는다(§11 Q6). `docker_label_args` 를 부르는 곳은 넷이다(`keeper_sandbox_control.ml:239`, `keeper_sandbox_docker.ml:332`, `keeper_turn_sandbox_runtime.ml:1681, 2146`). turn/oneshot 컨테이너의 owner pid 는 이 RFC 범위 밖이다.

남는 것:

- 선언되어 있지만 재시작 뒤 다시 시작하지 못한 Keeper 의 게스트는 그 Keeper 가 시작하거나 선언이 바뀔 때까지 떠 있다. 지금은 sweep 이 지운다.
- 손으로 돌린 하네스가 라이브와 같은 base path 로 게스트를 띄우면, 서버는 그 게스트를 자기 것으로 본다. 하네스가 base path lease 를 잡는지는 확인하지 않았다.
- work volume 과 build volume 이름에는 base path hash 가 없다(`masc-keeper-work-<keeper>`). 다른 base path 의 같은 이름 Keeper 는 같은 볼륨을 쓴다. 지금도 그렇고, 이 RFC 는 바꾸지 않는다.

### 4.5 shim 확인 (D7)

부팅은 shim 바이너리가 sidecar 와 맞는지 보고, 맞지 않으면 거절한다. shim 설정도 부팅 때마다 다시 쓴다(`prepare_microvm_shim_dir`, `keeper_turn_sandbox_runtime.ml:1076-1110`). 새 부팅이 드물어지면 두 가지가 빈다.

- 서버가 멈춘 사이에 배포가 shim 을 바꿨을 수 있다(`scripts/install-local-build.sh:245-252`). adopt 된 게스트는 다음 요청부터 그 shim 을 쓰는데, 아무도 sidecar 와 대조하지 않는다.
- runtime 설정의 payload PATH 가 바뀌어도 아무도 설정을 다시 쓰지 않는다.

그래서:

- sidecar 대조는 모든 endpoint 가 지나는 `microvm_remote_endpoint_of_running_fields`(`keeper_turn_sandbox_runtime.ml:2316-2385`)로 옮긴다. 턴의 endpoint 와, `microvm_attached_endpoint` 를 쓰는 읽기 경로 셋(`keeper_sandbox_remote_lane.ml:85`, `keeper_tool_lane_status.ml:162`, idle build cleanup `keeper_turn_sandbox_runtime.ml:3059`)이 모두 여기를 지난다. 이 프로세스에서 게스트마다 한 번 한다. 한 번 했다는 것은 `microvm_work_roots_ready` 와 같은 프로세스 메모리에 둔다. 다시 계산할 수 있는 확인이라 프로세스와 같이 사라져도 된다.
- 설정 파일은 모든 게스트가 같이 붙이는 디렉토리에 있다. 서버 시작 때 sweep 과 같은 자리에서 한 번 다시 쓰고, 부팅 때도 지금처럼 쓴다.

work root 와 `_build` 링크 scan 은 지금도 이 프로세스가 처음 넘기는 게스트에 한 번 돈다(`keeper_turn_sandbox_runtime.ml:2405-2417`). 바꾸지 않는다.

체크아웃을 읽는 화면(`keeper_sandbox_remote_checkouts.ml:415-418`)은 이 프로세스가 넘긴 게스트만 본다. 그래서 재시작 뒤 첫 턴 전에는 떠 있는 게스트도 "없음"으로 보인다. 지금은 재시작 뒤 게스트가 정말 없으므로 같은 답이다. 이 RFC 는 이것을 바꾸지 않는다.

### 4.6 backend 별

- Apple container: 4.1~4.5 전부. 사실과 label 의 모양은 10-21 에 쟀다.
- nerdctl/Kata: inspect 를 바꾸지 않으므로 사실은 `Not_reported` 다. label 은 nerdctl 목록(`ps -a` 의 `LabelsMap`, `keeper_sandbox_microvm.ml:2300-2303`)에 나오지만 이 Mac 에서 재지 않았다. 그래서 nerdctl 은 지금처럼 이 프로세스의 부팅 기록과 비교하고, 기록이 없으면 `Boot_not_recorded` 로 교체한다. 재시작 뒤에는 지금처럼 교체된다. 사본 자리(4.3)와 sweep 규칙(4.4)은 같이 바뀐다. `microvm_boots` 는 nerdctl 을 위해서만 남는다(§11 Q7).
- microsandbox: 부팅하지 않으므로 해당 없다.
- Docker persistent: 이미 재시작을 넘는다. 바꾸지 않는다.

## 5. 새 부팅이 드물어지면 — #44426 과 build volume

이 RFC 뒤에 새 부팅은 이럴 때만 생긴다. 새 Keeper, 게스트가 죽었을 때, 부팅 계획이 바뀌었을 때(이미지, 크기, 마운트, 격리, masc 가 넘기는 환경 변수), 로그인이 바뀌었을 때, policy 게스트가 있는 서버의 재시작. 부팅 때만 하던 일도 그만큼 드물어진다.

#44426 의 결정별로 보면 이렇다.

- D1, D2(`discard` 기본값 확인, 새 볼륨에만 helper): 볼륨에 묶인 일이라 영향이 없다.
- D4(`fstrim` 제거): 영향이 없다.
- D3(진짜 `_build` 를 새 부팅에서 첫 턴 전에 지운다): 새 부팅이 드물어지면 진짜 `_build` 가 그만큼 오래 남는다. idle cleanup 만 있던 10-06 에 16개 게스트에 134 GB 가 쌓였다(그 RFC §5 A5). 지우는 자리를 "이 프로세스가 처음 넘길 때"(`keeper_turn_sandbox_runtime.ml:2405-2417`)로 옮기면 재시작마다 지운다. 그때 이 프로세스의 턴은 아직 그 게스트를 받지 않았고, 옛 서버의 payload 는 EOF 로 끝난다(U3). 같은 Keeper 의 두 턴이 동시에 처음 adopt 하는 경합은 #44426 §4.2 의 이름 바꾸기가 이미 다룬다.
- #44426 을 버리는 길도 있다. helper 는 새 부팅에서만 끝나기 때문이다. 하지만 이미지가 바뀌면 그 이미지를 쓰는 Keeper 가 한꺼번에 새로 부팅한다. 10-21 의 게스트는 09-28 이미지로 떠 있었다(§3.5). 그런 날마다 지금과 같은 막힘이 돌아온다.

build volume:

- build volume 은 새 부팅에서만 호스트 공간을 돌려준다(§3.7). 게스트가 며칠 살면 그동안 build volume 의 호스트 크기는 줄지 않는다. 기본 크기 128g 에 34개면 4.3 TB 다. 이 Mac 의 디스크는 4 TB 다. 실제로 얼마나 커지는지는 모른다(U4).
- 길은 셋이다.
  1. 받아들이고 잰다(V6).
  2. build volume 에도 `discard` 기본값을 준다. build volume 은 새 부팅마다 다시 만들어지므로, #44426 의 helper 가 새 부팅마다 돈다.
  3. build volume 을 다시 만들지 않는다. 한 번 `discard` 기본값을 준 뒤 계속 쓴다. 그러면 idle cleanup 이 지운 블록이 바로 돌아간다. RFC-keeper-build-output-returns-to-a-disposable-volume 의 "새 부팅마다 다시 만든다" 가 바뀐다.

§11 Q4, Q5 에서 묻는다.

## 6. 다른 방법과 고르지 않은 이유

- A1. 부팅 기록을 디스크에 저장한다(게스트마다 JSON 하나). 런타임이 이미 대부분의 값을 보고하고, 보고하지 않는 것은 label 이 게스트 안에 남긴다. 기록이 따로 있으면 운영자가 게스트를 손으로 지우거나 바꿨을 때 어느 쪽이 맞는지 다시 정해야 한다. 같은 사실을 두 군데 두지 않는다.
- A2. label 없이 런타임 사실만으로 판정한다. 런타임이 요구와 다르게 보고하는 게스트를 교체할지 거절할지 정할 근거가 없다. 교체하면 4.1 에서 본 반복이 생기고, 거절하면 이미지가 바뀐 게스트도 거절된다. masc 가 넘긴 환경 변수와 `--rm` 은 비교하지 못한다. §11 Q3 에서 묻는다.
- A3. 고정 로그인 디렉토리를 그대로 읽기 전용으로 붙인다. Docker persistent 와 같은 방식이다(`keeper_github_identity.ml:774-806`). 사본이 아예 없어진다. 로그인이 바뀌어도 게스트를 교체하지 않아도 되므로 컨테이너 종료가 하나 더 준다. 대신 호스트의 로그인 변경이 턴 도중에 게스트에 닿는다. 게스트가 그 디렉토리의 모든 파일을 본다(지금 사본은 두 파일만 옮긴다). 토큰이 갱신된 뒤 늦게 나온 출력에서 옛 토큰을 가릴 파일이 없어진다. microvm 이 사본을 고른 이유는 #31542 본문에 적혀 있지 않다. §11 Q1 에서 묻는다.
- A4. 사본을 `$TMPDIR` 에 두되 이름을 게스트 이름에서 정한다. `$TMPDIR` 은 서버 프로세스의 환경에서 온다. 서버를 띄우는 길(launchd, 셸 스크립트)마다 다를 수 있고, masc 가 그 디렉토리의 수명을 정하지 않는다.
- A5. sweep 을 잠금 밖에서 돌리거나, 여러 개를 동시에 지운다. 지우는 수와 컨테이너 종료 수는 같다. 그리고 2.1 의 2, 3번 길이 남아 있어서 sweep 을 고쳐도 start 가 같은 게스트를 지운다. 증상을 펴 바르는 일이라 고르지 않는다.
- A6. adopt 할 때 owner pid label 을 새 pid 로 바꾼다. label 은 `run` 때 정해진다. 실행 중인 게스트의 label 을 바꾸는 명령은 찾아보지 않았다. 있다 해도 마지막에 adopt 한 프로세스를 저장하는 일이고, base path lease 가 같은 답을 이미 준다.
- A7. 서버를 멈출 때 게스트를 모두 내린다. 다음 시작이 찾을 게스트가 없어진다. 컨테이너 종료 수는 같고 시점만 옮긴다.

## 7. 하드 컷

- 이 변경 전 바이너리가 띄운 게스트에는 `masc.mcp.boot_plan` label 이 없다. 4.1 의 2번으로 그 Keeper 의 첫 start 에서 한 번 교체된다. 배포 직후 한 번, 지금의 재시작 한 번과 같은 수의 삭제와 새 부팅이 생긴다. 이 게스트들은 선언에서 나오는 이름이라 sweep 은 지우지 않는다. 그래서 삭제는 Keeper 마다 첫 start 에 흩어진다.
- `$TMPDIR` 에 남은 옛 사본(§3.6)은 masc 가 읽지도 지우지도 않는다. 옛 데이터를 위한 reader 를 두지 않는다. 운영자가 한 번 지운다. 옛 바이너리가 띄운 게스트가 모두 교체된 뒤에 해야 한다. 그 전에 지우면 그 게스트의 `gh` 와 `git push` 가 실패한다. 디렉토리가 0500 이라 쓰기 권한을 먼저 준다.

  ```
  find "$TMPDIR" -maxdepth 1 -name 'masc-gh-tool-*' -type d -exec chmod -R u+w {} +
  find "$TMPDIR" -maxdepth 1 -name 'masc-gh-tool-*' -type d -exec rm -rf {} +
  ```

  `$TMPDIR` 은 서버 프로세스의 값이어야 한다. Docker turn lane 의 사본도 같은 이름이라, 그 lane 의 턴이 돌고 있으면 그것도 지운다. 지금 선언된 34개 Keeper 는 모두 `microvm` 이다.
- `identity/` 디렉토리는 아직 없다. 첫 부팅이 만든다.

## 8. 검증 계획

테스트는 화면 글자나 로그 문장을 고정하지 않는다. argv, 타입, 파일 시스템 상태로 본다.

- V1. start argv(가짜 `container` CLI 주입). 지금 테스트는 `PATH` 앞에 가짜 `container` 스크립트를 두고, 스크립트가 받은 argv 를 파일에 적고, 하위 명령마다 답을 정한다(`test/test_keeper_sandbox_microvm.ml:2436-2495`). 같은 방식으로 inspect 와 `list` 에 §3.5 모양의 JSON 을 답하게 한다. 환경 변수 값은 가짜로 바꾼다. 테스트마다 다른 Keeper 이름을 써서, 테스트 프로세스가 그 게스트를 띄운 적이 없게 한다. 테스트 전용 reset 은 만들지 않는다.
  - label 과 사실이 계획과 같고 사본 디렉토리가 있는 떠 있는 게스트: `stop`, `delete`, `run`, `volume`, `network` argv 가 없다. endpoint 가 돌아온다.
  - label 이 없거나 다를 때(이미지, CPU, 메모리, 마운트, masc 환경 변수 하나를 바꾼 계획): 그 이름의 `stop` 과 `delete --force` 가 한 번씩, 그 뒤 `run` 이 한 번이다. reason 은 로그 문장이 아니라 판정 함수가 돌려준 값으로 본다.
  - label 은 같은데 inspect 가 다른 메모리를 보고할 때: `delete` 도 `run` 도 없고 `Runtime_reports_other_than_asked` 로 거절한다. 두 번 불러도 같다.
  - 새 부팅 뒤 inspect 가 다른 메모리를 보고할 때: 실패로 돌아오고 `delete` 가 없다. 다음 start 는 `run` 없이 거절한다.
  - inspect 의 `configuration` 에 `mounts` 가 없을 때: `delete` 도 `run` 도 없고 `Guest_facts_unreadable` 로 거절한다.
  - 사본 디렉토리가 없거나, 모르는 파일이 있거나, 링크일 때: 교체.
  - inspect 가 timeout 상태로 끝나고 `list` 도 실패할 때: 사본 디렉토리가 그대로 있다.
  - 계획을 계산하는 동안 `volume`, `network` argv 가 없다(D4).
  - nerdctl: argv 가 지금과 같다.
- V2. 파서. §3.5 의 inspect 를 값만 가짜로 바꾼 fixture 로 `Facts` 가 나오는지 본다. 마운트 `type` 키가 모르는 것일 때와 `resources` 가 없을 때 `Unreadable` 인지 본다. 같은 계획이면 digest 가 같고, 계획의 칸 하나를 바꾸면 digest 가 바뀌는지 본다. DNS 서버와 policy 포트만 바꾸면 digest 가 같은지 본다.
- V3. 사본 디렉토리. 실제 임시 디렉토리로 본다.
  - 만들기: `.partial-` 뒤 `rename`, 권한 0700/0500/0400. `identity/` 가 링크이면 거절.
  - 읽기: `Unconfigured`, `Configured revision`, `Unreadable`(모르는 파일, 링크, 0700 인 게스트 디렉토리). revision 이 지금 사본과 같은 함수로 나오는지.
  - 지우기: 0500 디렉토리가 실제로 지워지는지. 바꿔치기한 링크를 따라가지 않는지. 목록에 이름이 있으면 지우지 않는지.
- V4. sweep. 임시 keepers 디렉토리와 가짜 목록에 (a) 선언된 Keeper 의 게스트(owner pid 는 죽은 값), (b) 선언되지 않은 Keeper 의 게스트, (c) 선언은 있지만 프로필이 `docker` 인 Keeper 의 게스트, (d) 네트워크 모드가 바뀐 Keeper 의 옛 이름 게스트, (e) 다른 base path hash 의 게스트를 넣는다. `delete --force` 는 (b)(c)(d)에만 간다. 그 셋의 사본, 목록에 없는 이름의 사본, `.partial-*` 가 지워진다. 목록 호출이 실패하면 `delete` 도 사본 삭제도 없다. 선언 하나를 못 읽으면 그 Keeper 의 게스트는 남는다.
- V5. 배포 뒤 라이브. 이 RFC 를 배포하는 재시작에서는 하드 컷 때문에 교체가 한 번 생긴다. 그래서 그다음 재시작을 잰다. 서버 시작부터 30분 동안 10-21 과 같은 sampler(2초마다 `container ls -a` 시간과 `delete`/`run`/`stop`/`volume` 프로세스)를 돌리고, 로그의 sweep 줄과 "replaced instead of adopted" 줄을 읽는다.

  | 재시작(KST) | sweep 걸린 시간, 지운 게스트 | 게스트 `delete` | 게스트 `run` | 끝난 helper | `ls` 가 20초 넘게 걸린 수, 가장 긴 것 | 그 가운데 시작 전 2.5초 안에 컨테이너가 끝난 것 | 교체 줄 수와 reason |
  |---|---|---|---|---|---|---|---|
  | 10-21 10:17 (비교용) | 590.9초, 21 | 21 (sweep) | 재지 않음 | 22 | 재지 않음 | 재지 않음 | 0 |
  | 10-21 11:34 (비교용) | 756.5초, 20 | 20 (sweep) | 12 (11:51~12:11 만 봤다) | 18 (12:05 까지) | 7, 62.9초 (11:51~12:11 만 봤다) | 7, 모두 helper | 0 |

  - 기대: 계획이 바뀐 Keeper 가 없으면 sweep 은 0개를 지우고 곧 끝난다. 게스트 `delete`, 게스트 `run`, helper 가 모두 0 이고, 20초 넘는 `ls` 도 0 이다.
  - App identity Keeper 는 토큰을 갱신할 때 로그인 revision 이 바뀌어 게스트가 교체된다(`keeper_turn_sandbox_runtime.ml:2576-2586, 2626-2631`). 지금 라이브에는 없다(`<base>/.masc/keepers/*/github-app` 이 없다). 생기면 그 수를 기대값에서 뺀다.
  - 0 이 아니면 그 줄의 reason 과 Keeper 를 적는다.
  - 같은 창에서 `<base>/.masc/microvm/identity/apple_container/` 의 디렉토리 수가 떠 있는 keeper-vm 게스트 수와 같은지, 권한이 0700/0500/0400 인지 본다.
- V6. build volume. 배포 뒤 하루, 사흘, 이레째에 build volume 이미지 34개의 호스트 크기(`du`)를 적는다(U4). §11 Q5 의 답이 이 숫자에 기댄다.

## 9. 앞선 RFC 와 문서에서 바뀌는 곳

RFC-keeper-boot-runs-no-one-shot-container 에서 이 커밋이 바꾼 곳(결정은 그대로 두었다):

| 자리 | 지금 쓰인 것 | 바꾼 것 |
|---|---|---|
| §2 1단계 | 재시작하면 옛 게스트가 snapshot 을 잃어 이 분기에서 교체된다 | 재시작 뒤의 옛 게스트는 그보다 먼저 startup sweep 이 지운다. 이 단계는 없는 이름에 대한 호출이 된다 |
| §3.4 U2 | 게스트 종료는 재지 않았고 helper 보다 짧은 것 같다 | 10-21 11:34 의 sweep 삭제 시간(20개, 756.5초, 마지막 다섯 개 11~71초)과 삭제 중의 `ls` 64.8초 한 번. 짧지 않다 |
| §7 V5 표 | 10-20 23:28 비교 줄 하나 | 10-21 11:34 비교 줄을 더한다(이 RFC §3.3 의 sampler 값) |
| §10 Q2 결정 | 재시작마다 약 25번이던 막힘이 새 볼륨마다 한 번으로 준다 | helper 가 만들던 막힘(재시작마다 18~22번)이 새 볼륨마다 한 번으로 준다. 옛 게스트를 지울 때의 막힘(재시작마다 20~21번)은 남는다. 결정(받아들인다)은 그대로다 |
| §10 Q3 | 교체 이유가 snapshot 을 잃어서 | 교체는 startup sweep 이 한다. 이 RFC 를 가리킨다. 결정은 그대로다 |
| frontmatter | `related` | 이 RFC 의 slug 를 더한다 |

구현 PR 에서 함께 바꾸는 곳(지금은 실제 동작을 맞게 적고 있다):

- `keeper_turn_sandbox_runtime.ml` 의 `:22-30`, `:129-163`, `:1531-1534`, `:1594-1596`, `:1694-1703`, `:1816-1825` 주석.
- `keeper_sandbox_microvm.ml:2128-2140` 의 sweep 문서 주석. `keeper_sandbox_microvm.ml:1758-1767` 의 build volume 주석은 §11 Q5 에 따라.
- `server_runtime_startup_maintenance.ml:111-114` 문서 주석.
- `keeper_sandbox_runtime_setup.ml:201-207` owner pid 주석은 §11 Q6 에 따라.
- #36993 은 Apple 에 한해 이 구현으로 닫는다.

## 10. 구현 범위

- `Keeper_sandbox_microvm`: `guest_mount`, `guest_facts_reading`, Apple inspect 파서. sweep 후보 규칙(`sweep_candidates_of_json`, `nerdctl_sweep_candidates_of_json_lines`)을 선언에서 나오는 이름 기준으로 바꾸고 `is_pid_alive` 인자를 지운다. 사본 정리.
- `Keeper_turn_sandbox_runtime`: `boot_plan` 과 digest, 부작용 없는 계획 계산, 4.1 의 판정(`microvm_adoption` 을 바꾼다), 4.2 의 부팅 뒤 확인(게스트를 남긴다), Apple 에서 `microvm_boots` 제거, `microvm_identity_snapshots` 와 claim/take/release 함수 제거, `stop_and_delete_microvm_container` 뒤의 사본 지우기(성공한 목록으로 없음 확인), 부팅 argv 에 `masc.mcp.boot_plan` label, endpoint 에서 shim sidecar 대조.
- `Keeper_github_identity`: 사본을 정해진 자리에 만드는 함수, 읽는 함수, 다른 프로세스가 지우는 함수(§4.3 의 지우는 방법). Docker turn lane 이 쓰는 `docker_args_for_tool` 은 그대로 둔다.
- `Config_dir_resolver`: `microvm_identity_dir ~base_path ~backend`.
- `Server_runtime_startup_maintenance`: sweep 에 선언에서 나오는 게스트 이름을 넘기고, shim 설정을 한 번 다시 쓴다.
- 테스트: V1~V4. 지금 `test/test_keeper_sandbox_microvm.ml` 의 adopt, 교체, 사본 테스트(`Boot_not_recorded`, `For_testing_microvm.microvm_identity_snapshot_registered` 를 쓰는 것)를 새 판정에 맞게 바꾼다.
- 바꾸기 전에 지우는 함수마다 호출하는 곳을 `git grep` 으로 모두 센다. module alias 로 부르는 곳도 센다.

## 11. 운영자에게 묻는 것

- Q1. (사람 리뷰 필요) GitHub 자격 증명을 게스트에 어떻게 줄지. (a) 게스트에 묶인 사본(§4.3). 게스트가 사는 동안 토큰이 바뀌지 않고, 로그인이 바뀌면 게스트를 교체한다. 사본이 서버보다 오래 산다. (b) 고정 로그인 디렉토리를 읽기 전용으로 붙인다(A3, Docker persistent 와 같다). 사본이 없어지고 로그인 변경이 교체 없이 닿는다. 대신 턴 도중에도 닿고, 게스트가 그 디렉토리의 모든 파일을 본다.
- Q2. (사람 리뷰 필요) Q1 이 (a)일 때 사본 자리를 `<base>/.masc/microvm/identity/<backend>/` 로 할지. base path 는 백업에서 빠지지 않는다. 고정 로그인이 이미 같은 base path 에 있다. `$TMPDIR` 에 남은 옛 사본 2,393개(토큰이 든 것 424개)를 §7 의 명령으로 지울지, 언제 지울지도 함께 묻는다.
- Q3. adopt 판정에 부팅 계획 label 을 붙일지(§4.1), 런타임 사실만 볼지(A2). label 을 붙이면 "요구가 바뀌었다"(교체)와 "런타임이 다르게 보고한다"(거절)를 가를 수 있고, masc 가 넘긴 환경 변수까지 덮는다. 대신 label 하나가 게스트에 늘고, 계획을 만드는 방식이 바뀌는 릴리즈마다 모든 게스트가 한 번 교체된다. 사실만 보면 label 이 없지만, 런타임이 다르게 보고하는 게스트를 교체할지 거절할지 정할 수 없다.
- Q4. #44426 을 어떻게 할지. (a) 그대로 구현한다. 진짜 `_build` 는 새 부팅에서만 지워져 오래 남는다. (b) D1, D2, D4 는 그대로 두고, D3 의 자리를 "이 프로세스가 처음 넘길 때"로 옮겨 구현한다. 재시작마다 지운다. 옛 서버가 게스트 안에 남긴 프로세스가 있으면 그 `_build` 를 잃는다(U3). (c) 버린다. 이미지가 바뀔 때마다 10-21 10:17 재시작과 비슷한 막힘(helper 22개, 67분)이 돌아온다. 어느 쪽이든 이 RFC 를 먼저 구현할지도 묻는다. 이 RFC 는 재시작 때의 helper 도 같이 없앤다.
- Q5. build volume 을 어떻게 할지(§5). (a) 새 부팅에서만 공간을 돌려받는 것을 받아들이고 V6 으로 잰다. (b) build volume 에도 `discard` 기본값을 준다. 새 부팅마다 helper 가 돈다. (c) build volume 을 다시 만들지 않고, 한 번 `discard` 기본값을 준 뒤 계속 쓴다. RFC-keeper-build-output-returns-to-a-disposable-volume 이 바뀐다.
- Q6. keeper-vm 게스트에서 `masc.mcp.owner_pid` label 을 뺄지. 빼면 sandbox 상태 화면에서 그 게스트의 owner pid 가 없어진다. 두면 adopt 된 게스트에서 죽은 pid 를 보인다.
- Q7. nerdctl 을 지금처럼 둘지(재시작마다 교체, `microvm_boots` 가 nerdctl 에만 남는다). 아니면 nerdctl 이 있는 호스트에서 `ps -a` 의 label 과 `inspect --mode dockercompat` 을 재고, Apple 과 같은 판정을 붙여 표를 지울지.
