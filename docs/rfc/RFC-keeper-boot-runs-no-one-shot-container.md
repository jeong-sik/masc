---
rfc: "keeper-boot-runs-no-one-shot-container"
title: "Keeper 부팅 경로에서 일회용 컨테이너를 띄우지 않는다"
status: Draft
created: 2026-10-21
updated: 2026-10-21
author: claude
related: ["keeper-build-output-returns-to-a-disposable-volume", "keeper-guest-survives-restart"]
---

# RFC: Keeper 부팅 경로에서 일회용 컨테이너를 띄우지 않는다

- 상태: 초안. 운영자 결정 전이라 코드는 바꾸지 않았다.
- 이슈: #44333. 처음에는 원인을 work volume 의 `fstrim` 으로 봤다. 2026-10-20~21 의 측정(§3)에서 원인은 `fstrim` 이 아니라 일회용 helper 컨테이너가 끝나는 일로 바뀌었다.
- 근거: 코드 사실은 `origin/main` `d69f303eb25` 에서 읽었다. 측정은 이 Mac(container 1.3.1, Homebrew, guest kernel 6.18.35)에서 `trimprobe-` 이름의 scratch 자원으로 했다. 원본 숫자는 #44333 에 있다.
- 앞선 문서: RFC-keeper-build-output-returns-to-a-disposable-volume. 그 RFC 의 §B 가 helper 가 하는 일 가운데 `_build` 제거를 정했다. 부팅 때 work volume 을 다루는 방법은 이 RFC 가 정한다(§8).

## 0. 요약

Apple backend 의 Keeper 가 새로 부팅할 때마다 masc 는 일회용 helper 컨테이너를 하나 띄운다. 이 컨테이너는 work volume 을 붙이고 세 가지 일을 한 뒤 끝난다.

1. ext4 의 `discard` 기본값을 켠다(`tune2fs -o discard`).
2. 진짜 `_build` 디렉토리를 지운다.
3. 볼륨 빈 공간 전체를 `fstrim` 한다.

이 컨테이너가 끝나면 `com.apple.container.apiserver` 가 40~65초 동안 다른 요청에 답하지 않는다. 그동안 다른 Keeper 의 `container exec` 와 `container ls` 는 기다리다가 `XPC timeout for request to com.apple.container.apiserver/containerList` 로 실패한다. 서버를 재시작하면 Keeper 마다 이 일이 한 번씩 일어난다(10-20 두 번의 재시작에서 21번, 18번). 그래서 배포할 때마다 15~22분 동안 도구 호출이 띄엄띄엄 실패한다.

이 RFC 는 부팅 경로에서 일회용 컨테이너를 없앤다. 세 가지 일은 이렇게 옮긴다.

- `discard` 기본값: 부팅 때 호스트가 볼륨 이미지의 superblock 을 읽어 확인만 한다. 기본값이 없는 볼륨(새로 만든 볼륨)에서만 helper 를 띄운다. 볼륨 하나에 한 번이다.
- `_build` 제거: 새로 띄운 게스트 안에서, 첫 턴을 받기 전에, Keeper 의 uid:gid 로 `exec` 한다. `exec` 는 컨테이너를 끝내지 않는다.
- `fstrim`: 지운다. 마운트할 때마다 빈 공간 전체를 다시 훑고, `discard` 가 켜져 있어서 돌려줄 블록이 거의 없다.

## 1. 결정

- D1. `Boot` 분기에서 일회용 컨테이너를 띄우지 않는다. 볼륨이 이미 `discard` 기본값을 가지고 있으면 게스트 자신의 `container run` 말고 다른 `container run` 은 없다.
- D2. `discard` 기본값은 부팅 때마다 호스트에서 읽어 확인한다. `container volume inspect` 가 주는 `source` 파일의 ext4 superblock 을 읽는다. 컨테이너를 띄우지 않는다. 값이 없으면 `tune2fs -o discard` 만 하는 helper 를 띄운다. helper 가 실패하거나 superblock 을 못 읽어도 부팅은 계속한다. 그 볼륨은 `discard` 기본값 없이 뜨고, sandbox 상태가 그 사실을 보인다(§4.1).
- D3. 진짜 `_build` 제거는 이 서버 프로세스가 게스트를 처음 넘길 때 게스트 안에서 한다. `ensure_microvm_build_links` 의 scan 보다 먼저, Keeper 의 uid:gid 로, exec-shim runner 를 거쳐 실행한다. 먼저 이름을 바꾸고 그다음 지운다(§4.2). 자리는 RFC-keeper-guest-survives-restart §11 Q4 의 결정(2026-10-21)으로 "새로 부팅한 게스트"에서 옮겼다. 재시작해도 게스트를 이어 쓰면 새 부팅이 드물어지기 때문이다. 이 RFC 는 그 RFC 뒤에 구현한다.
- D4. `fstrim` 과 `remount,nodiscard` 를 지운다. `CAP_DAC_OVERRIDE` 도 필요 없어진다(§4.3).
- D5. 하드 컷이다. 기존 work volume 34개는 모두 `discard` 기본값을 이미 가지고 있다(§6). 옮기는 코드나 운영자가 한 번 돌릴 명령은 없다.
- D6. 앞선 RFC 의 설명 가운데 helper 의 단계와 플래그를 적은 곳은 이 RFC 로 옮기고 그 자리에서 지운다(§8). 운영 가이드와 코드 주석은 구현 PR 에서 함께 바꾼다.

## 2. 지금 구조

`Keeper_turn_sandbox_runtime` 의 `Boot` 분기(`keeper_turn_sandbox_runtime.ml:1560-1592`)는 이 순서로 움직인다.

1. 같은 이름의 옛 게스트를 `delete --force` 한다. 서버를 재시작하면 옛 서버의 게스트는 이 분기보다 먼저 startup sweep 이 모두 지운다. owner pid label 이 죽은 프로세스를 가리키기 때문이다(RFC-keeper-guest-survives-restart §2.1). 그래서 재시작 뒤에는 Keeper 마다 이 분기를 타고, 이 단계는 없는 이름에 대한 호출이 된다.
2. `microvm_guest_provisions`: work volume 을 확인하거나 만들고(`microvm_work_volume`, `:1016`), build volume 을 지우고 새로 만든다(`microvm_build_volume`, `:1046`).
3. `reclaim_work_volume_space`(`:1121`) → `Keeper_sandbox_microvm.reclaim_apple_work_volume`(`keeper_sandbox_microvm.ml:1267`):
   - 남은 helper 를 지우고 `container list --all` 로 없는지 확인한다(`remove_apple_work_volume_trim`, `:1224`).
   - helper 를 띄운다(`apple_work_volume_trim_argv`, `:1213`): `run --rm --name masc-keeper-work-<keeper>-trim --user 0 --cap-drop ALL --cap-add CAP_SYS_ADMIN --cap-add CAP_DAC_OVERRIDE --network none --read-only --entrypoint /bin/sh --volume <work volume>:/masc-trim <keeper image> -eu -c <script>`.
   - script(`work_volume_reclaim_script`, `:1167`)는 `findmnt` → `tune2fs -o discard` → `mount -o remount,nodiscard` → `build_output_removal_script`(`:1128`) → `fstrim -v /masc-trim` 순서다.
   - 끝나면 다시 지우고 `container list --all` 로 확인한다. 확인이 끝나야 "trimmed" 줄을 로그에 쓴다.
4. 게스트를 `container run` 한다. 그 뒤 work root 를 확인하고(`ensure_microvm_keeper_work_root`), `_build` 링크 scan 을 한 번 돌리고(`ensure_microvm_build_links`, `:1795`), 턴에 넘긴다.

helper 의 `-trim` 이름은 `Keeper_sandbox_container_name.Micro_vm_work_volume_trim`(`keeper_sandbox_container_name.ml:9, :112`)이 만든다.

## 3. 측정

### 3.1 trial 다섯 번

모두 `--rm --network none --entrypoint /bin/sh`, 이미지는 `masc-sandbox-ocaml:20260928T0216Z-c48e1e05` 다. "helper 플래그"는 `--user 0 --cap-drop ALL --cap-add CAP_SYS_ADMIN --cap-add CAP_DAC_OVERRIDE --read-only` 를 말한다. 막힌 시간은 컨테이너가 끝난 바로 뒤에 시작한 `trimprobe-peer` 대상 `container exec` 와 `container ls` 의 걸린 시간이다. 라이브 실패는 그 창 안에서 `shell_ir dispatch` 가 exit≠0 으로 끝난 것과 `Process_eio` timeout 이다. 어느 창에도 라이브 Keeper 의 부팅은 없었다.

| 회차 | 시각(KST) | helper 플래그 | 볼륨 | `fstrim` | 끝난 뒤 막힌 시간 | 같은 창의 라이브 실패 |
|---|---|---|---|---|---|---|
| 1 | 10-20 23:17 | 있음 | 256g, 새 볼륨 | 있음 | exec 47.1초, ls 46.1초 | 23:18:05 에 8건(28~45초) |
| 2 | 10-20 23:21 | 있음 | 256g, 1회차 볼륨 | 없음 | exec 42.4초, ls 42.2초 | 23:22:13 에 3건(16~40초), timeout 1건 |
| 3 | 10-21 00:04 | 없음 | 없음 | 없음 | exec 5.1초, ls 5.0초 | 없음 |
| A | 10-21 01:28 | 있음 | 없음 | 없음 | exec 42.7초, ls 43.2초 | 01:29:37 에 4건(14~52초), timeout 1건(44초) |
| B | 10-21 01:31 | 없음 | 256g, 새 볼륨 | 없음 | exec 65.4초, ls 65.5초 | timeout 5건(19~44초), 01:33:15 에 2건(65~86초) |

- 1회차의 `fstrim` 은 "252 GiB trimmed" 를 1.1초에 마쳤다. 막힘은 `fstrim` 이 끝나고 컨테이너가 끝난 뒤에 시작됐다.
- 기준선(컨테이너를 띄우지 않을 때)은 exec 평균 269~284 ms, 최대 1.3초였다.
- 호스트에서 4 MiB 를 쓰고 fsync 하는 시간은 1, 2, A 회차 내내 332 ms 를 넘지 않았다. 호스트 디스크가 막힌 것이 아니라 apiserver 가 답하지 않은 것이다.
- B 회차는 실행 중에도 exec 하나가 20초 걸렸고 fsync 가 6초까지 늘었다. 새 볼륨을 처음 마운트할 때 생기는 쓰기로 보인다. 라이브 helper 는 이미 쓰던 work volume 을 붙이므로, 실행 중의 이 부담은 B 보다 작을 것으로 본다. 재지는 않았다.

### 3.2 막히지 않은 것

| 작업 | 걸린 시간 | 라이브 실패 |
|---|---|---|
| `container volume create -s 256g` (두 번) | 21.3초, 22초 | 없음 |
| `container volume delete` | 5초 | 없음 |
| peer `container run -d` | 4초 | 없음 |
| 볼륨 없는 peer 의 `container delete --force` | 12초 | 같은 초에 11.5초짜리 2건이 끝났다. 12초쯤 막혔을 수 있다 |

이 숫자들로 보면, build volume 을 매 부팅마다 지우고 새로 만드는 일(§C of 앞선 RFC)은 이 문제의 원인이 아니다.

### 3.3 라이브 로그

- 10-20 21:58 재시작(`masc-start-1020-2158.log`): 22:07~22:29 사이에 helper 가 21번 끝났다. 20초를 넘겼거나 실패한 exec 36건이 모두 어느 helper 의 "trimmed" 줄과 같은 초에 끝났다(#44333).
- 10-20 23:28 재시작(`masc-start-1020-2328.log`): 23:41:48~23:56:49 사이에 helper 가 18번 끝났다. 20초 넘게 걸리고 실패한 dispatch 8건이 모두 "trimmed" 줄과 같은 초에 끝났다(23:43:22, 23:45:03, 23:47:30, 23:48:55, 23:52:04 두 건, 23:55:55 두 건).
- 같은 초에 끝나는 이유: "trimmed" 줄은 helper 가 끝난 뒤의 `container list --all` 확인이 돌아와야 써진다. 그 호출도 같은 apiserver 에서 같이 기다렸다가 같이 풀린다.
- 볼륨마다 찍히는 숫자는 빈 공간 크기다. polisher 는 22:28:55 와 23:52:04 에 두 번 다 229.9 GiB, rondo 는 두 번 다 251.2 GiB 였다. 1회차에서 같은 마운트 안의 두 번째 `fstrim` 은 0 B 였다. ext4 는 trim 한 자리를 마운트하는 동안만 기억한다. 그래서 helper 가 새로 마운트할 때마다 빈 공간 전체를 다시 trim 한다.

재시작 한 번에 helper 가 18~21번 끝나고 한 번에 40~65초가 막히면, 15~22분 동안 막힌 시간을 다 더하면 12~23분쯤 된다. 측정이 아니라 위 숫자로 계산한 값이다.

### 3.4 모르는 것

- U1. 3회차(플래그도 볼륨도 없음)만 5초로 짧았다. 이것만 보면 "플래그나 볼륨 둘 중 하나만 있어도 길게 막힌다" 로 읽힌다. 한 번뿐이라 운 좋게 짧았을 수도 있다. 둘을 가를 측정은 없다.
- U2. Keeper 게스트 자신이 끝날 때(work volume 과 build volume 이 붙은 채 delete)도 짧지 않다. 10-21 11:34 재시작에서 startup sweep 이 옛 게스트 20개를 하나씩 `delete --force` 했고 756.5초가 걸렸다. `ps` 표본에 잡힌 마지막 다섯 개는 71, 69, 59, 11, 15초였다. polisher 게스트를 지우는 동안(그때까지 helper 는 하나도 돌지 않았다) 호스트의 `container ls -a` 하나가 64.8초 걸린 뒤 `XPC timeout` 으로 실패했다. 삭제 중에 막힌 시간을 잰 표본은 이 하나다. 재시작 뒤 게스트를 지우는 것은 `Boot` 분기 1단계가 아니라 그보다 먼저 도는 startup sweep 이다(RFC-keeper-guest-survives-restart §3.2). 이 RFC 는 이 종료를 없애지 않는다(§10 Q3).
- U3. apiserver 가 왜 멈추는지는 모른다. Apple 쪽 코드를 읽지 않았다.
- U4. 게스트 안에서 `discard` 를 켠 채 많이 지울 때 apiserver 가 막히는지는 재지 않았다. Keeper 가 게스트 안에서 지우는 일은 지금도 `discard` 를 켠 채 일어나고, 그것과 맞춰진 막힘은 보지 못했다. 구현 전에 확인한다(§7 V4).

## 4. 세 가지 일을 어디로 옮기나

### 4.1 `discard` 기본값

이 값이 있어야 게스트가 지운 블록이 그때그때 호스트에 돌아간다(`docs/evidence/2026-10-02-ext4-discard-reclaim.md`). 값은 superblock 에 남으므로 볼륨마다 한 번만 쓰면 된다. 매 부팅마다 쓸 이유가 없다.

볼륨을 만들 때 넣을 방법은 container 에 없다. `container volume create` 의 `--opt` 는 `size` 와 `journal` 만 읽는다(apple/container `main` 의 `VolumesService.swift`. 1.3.1 소스는 한 줄씩 대조하지 않았다). 게스트도 쓸 수 없다. 게스트의 capability 는 비어 있고, 블록 장치를 쓰려면 root 권한이 필요하다.

그래서 확인과 쓰기를 나눈다.

- 확인: 부팅 때마다 호스트가 `container volume inspect` 의 `configuration.source`(볼륨 이미지 파일)를 열어 superblock 을 읽는다. 오프셋 1024 의 superblock 에서 magic(`0xEF53`, 오프셋 `0x38`)과 `s_default_mount_opts`(오프셋 `0x100`)의 `EXT4_DEFM_DISCARD`(`0x0400`)를 본다. 이 시점에는 어떤 게스트도 볼륨을 붙이고 있지 않다(§2 의 1단계 뒤). 결과는 타입으로 나눈다. `Discard_default_set | Discard_default_absent | Superblock_unreadable of string`.
- 쓰기: `Discard_default_absent` 일 때만 helper 를 띄운다. 지금 argv 에서 `CAP_DAC_OVERRIDE` 를 빼고 script 는 `findmnt` 와 `tune2fs -o discard` 만 한다. 새 Keeper 의 첫 부팅에서 한 번 일어나고, 그때는 40~65초 막힘이 한 번 생긴다. 다른 게스트가 볼륨을 붙이고 있으면 helper 는 시작하지 못한다. Virtualization.framework 는 VM 이 붙인 이미지를 다시 붙이지 않는다(10-06 측정, "The storage device attachment is invalid"). 그래서 helper 가 살아 있는 게스트의 볼륨을 두 번째로 마운트하는 일은 없다.
- 실패해도 부팅은 계속한다(Q7). helper 는 그 부팅에서 한 번만 돈다. helper 가 실패하면 WARN 로그 한 줄에 볼륨 이름, 종료 상태, 출력을 남기고, 게스트는 `discard` 기본값 없이 뜬다. `Superblock_unreadable` 이면 helper 를 띄우지 않고 부팅한다. 고칠 수 있는 볼륨인지 모르기 때문이다. 파일 시스템이 깨졌다면 게스트의 mount 가 실패하고, 그 실패는 지금의 다른 시작 실패와 같은 길로 보인다. 볼륨을 만든 직후 서버가 죽어 기본값 없이 남으면, 다음 새 부팅이 helper 를 띄워 고친다(Q1).
- 반복이 생기지 않는 이유: 부팅이 끝났으므로 다음 도구 호출은 그 게스트를 adopt 한다. superblock 확인과 helper 는 다음 새 부팅(서버 재시작이나 게스트 교체)에서 다시 일어난다. 그래서 helper 가 계속 실패하는 볼륨 하나는 새 부팅마다 40~65초 막힘을 한 번 만든다. 그 반복을 멈추는 상태는 두지 않는다.
- 잃는 것: 그 볼륨에서는 게스트가 지운 블록이 호스트에 돌아가지 않는다. 호스트의 `volume.img` 가 게스트 사용량보다 커지고, 볼륨 크기(256g)까지 갈 수 있다.
- 보이는 곳: Keeper 의 sandbox 상태(`Keeper_sandbox_control.live_status_json`, TUI sandbox 패널)에 `work_volume_discard_default` 를 보인다. 값은 superblock 확인 결과(`set`, `absent`, `unreadable` 과 그 이유)다. `guest_size_error` 처럼 읽을 때마다 superblock 을 새로 읽어 만들고, 저장하지 않는다. 운영자가 고치면 다음 읽기에서 바로 바뀐다.
- 운영자가 고치는 법과 잃는 것:
  1. `container volume inspect <volume>` 의 `source` 를 읽기만 해서 확인한다. `xxd -s 1080 -l 2 -p` 가 `53ef` 이고 `xxd -s 1280 -l 4 -p` 의 둘째 바이트에서 `0x04` 비트가 켜져 있으면 flag 가 있다. 지금 34개는 모두 `00040000` 이다.
  2. flag 만 없으면 helper 와 같은 argv 를 손으로 한 번 돌린다. `tune2fs` 가 있는 이미지(`masc-sandbox:general` 은 있다)를 쓴다. 볼륨을 붙인 게스트가 있으면 helper 가 시작하지 못하므로, 그 Keeper 의 게스트를 먼저 멈춘다. 잃는 것은 없고, 40~65초 막힘이 한 번 생긴다.
  3. superblock 을 못 읽거나 파일 시스템이 깨졌으면, 먼저 이미지를 복사해 둔다(`cp -c <source> <백업>`, APFS clone 이라 바로 끝난다). 그다음 일회용 컨테이너에서 `e2fsck` 를 돌리고, 고쳐지면 2로 간다.
  4. 그래도 안 되면 `container volume delete <volume>` 뒤 `masc_keeper_sandbox_start` 를 부른다. 다음 부팅이 새 볼륨을 만들고 helper 를 띄운다. 이때 `/masc-work/<keeper>` 전체를 잃는다. checkout, push 하지 않은 커밋, 커밋하지 않은 변경, Keeper 가 쓴 task·문서 파일이 다 사라진다. 3의 복사본이 남는 유일한 자료다. 복사본에서 파일을 꺼내는 방법은 이 RFC 범위 밖이다(Q7).

`Created` 결과(`ensure_work_volume_for`)에만 helper 를 띄우는 방법도 있다. 이 방법은 superblock 을 읽지 않는다. 대신 만든 직후 서버가 죽으면 기본값 없는 볼륨이 남고 아무도 고치지 않는다. 그래서 확인을 고른다(§10 Q1).

### 4.2 진짜 `_build` 제거

앞선 RFC §B 가 이 일이 필요한 이유를 적었다. Keeper 는 작업마다 worktree 를 만들고 같은 세션 안에서 빌드한다. 그래서 링크가 생기기 전에 진짜 `_build` 가 먼저 생긴다. 지우지 않으면 그 checkout 은 build volume 에 링크되지 않고 계속 work volume 에 쓴다. 지금 helper 가 볼륨을 떼어 놓고 지우는 이유는 둘이다.

- 지우는 동안 그 `_build` 를 쓰는 빌드가 없어야 한다. 살아 있는 게스트 안의 scan 이 진짜 디렉토리를 지우지 않는 이유도 같다.
- helper 는 uid 0 으로 돈다. capability 를 다 버린 uid 0 은 서버 uid 의 0755 트리에서 "other" 권한밖에 없다. 10-06 에 502:20 이 umask 022 로 만든 `_build` 를 `CAP_SYS_ADMIN` 만 가진 uid 0 이 지우려 하자 `rm` 이 "Permission denied" 를 냈고 아무것도 지우지 못했다. `CAP_DAC_OVERRIDE` 를 더하자(`CapEff` 0000000000200002) 지워졌다.

새로 부팅한 게스트 안에서 첫 턴을 받기 전에 지우면 두 조건이 거의 다 맞는다.

- 이 서버 프로세스가 아직 어떤 턴에도 넘기지 않은 게스트에서만 지운다. 그 게스트에서는 이 프로세스의 빌드가 돌 수 없다. 앞선 서버 프로세스의 턴이 남긴 빌드가 게스트 안에서 아직 돌고 있으면 그 `_build` 를 잃는다(RFC-keeper-guest-survives-restart U3). 운영자가 Q4 에서 받아들였다. 이 프로세스가 이미 넘긴 게스트를 다시 adopt 할 때는 지우지 않는다. scan 이 진짜 디렉토리를 거절하는 것도 그대로 둔다.
- 트리 주인은 서버 uid 이고, 게스트 안 exec 는 그 uid:gid(`t.uid`/`t.gid`, 라이브 argv 에서는 `--user 502:20`)로 돈다. 주인이 지우므로 `CAP_DAC_OVERRIDE` 가 필요 없다. 같은 사용자로 도는 idle build cleanup(`Server_keeper_build_maintenance` → `cleanup_attached_builds`, #40751)이 이미 게스트 안에서 `_build` 를 지운다.

"거의" 인 이유가 하나 있다. 한 Keeper 의 두 턴이 같은 이름으로 동시에 부팅하려 하면, 진 쪽은 `run` 이 실패한 뒤 이긴 쪽 게스트를 adopt 한다(`keeper_turn_sandbox_runtime.ml:1807-1845`). 진 쪽은 work volume 이 마운트됐는지만 보고 넘어가므로, 이긴 쪽이 아직 지우는 동안 진 쪽 턴이 빌드를 시작할 수 있다. 그래서 지우기를 두 단계로 나눈다.

1. 이름 바꾸기: 옮길 자리는 한 곳으로 정한다. Keeper root 바로 아래의 `.masc-build-removing` 디렉토리다(`/masc-work/<keeper>/.masc-build-removing`). 지울 `_build` 마다 그 아래에 `mktemp -d` 로 새 디렉토리를 하나 만들고, `_build` 를 그 안으로 `mv` 한다. 같은 볼륨 안의 `rename` 이라 checkout 하나에 밀리초 단위다. 이 단계가 끝나면 `_build` 자리는 비고, scan 이 같은 부팅에서 링크를 만든다. scan 은 `_build` 라는 이름만 찾으므로 이 디렉토리를 보지 않는다.
2. 지우기: `.masc-build-removing` 아래를 모두 지운다. 이번 부팅에 옮긴 것과 앞선 부팅에서 지우다 끊긴 것이 같은 자리에 있으므로 규칙은 하나다: 새 부팅의 2단계가 `.masc-build-removing` 아래를 비우고, 비면 그 디렉토리도 지운다. 그래서 이 디렉토리는 지우기가 끊긴 뒤에만 남아 보인다. Keeper root 자체가 checkout 인 Keeper 라면 그때 그 `git status` 에 보일 수 있다. 어떤 빌드도 이 자리를 쓰지 않으므로, 진 쪽 턴의 빌드와 겹쳐도 그 빌드에는 닿지 않는다.

경합이 남는 구간은 `container run` 부터 1단계가 끝날 때까지다. 그 사이에 진 쪽 빌드가 시작되면 그 빌드는 `_build` 를 잃고 실패한다. 잃는 것은 빌드 결과물이고 소스가 아니다.

실행 방법은 이렇다.

- 위치: `Boot` 분기의 `ensure_microvm_keeper_work_root` 뒤, `ensure_microvm_build_links` 앞이다(`keeper_turn_sandbox_runtime.ml:1788-1795`).
- 내용: `build_output_removal_script` 의 찾기 범위를 그대로 쓴다. 깊이, `dune-project` 표시, `.git` 건너뛰기, `.masc-keep-build`, `-exec` 로 경로 넘기기가 같다. 뿌리만 `/masc-trim/<keeper>` 에서 `keeper_work_root`(`/masc-work/<keeper>`)로 바뀌고, `rm -rf` 가 위의 두 단계로 바뀐다.
- 통로: idle cleanup 처럼 exec-shim runner(`Keeper_sandbox_remote.runner`)로 보낸다. runner 의 게스트 쪽 타이머와 transport EOF 는 payload 의 process group 을 끝낸다(`docs/guides/KEEPER-VM-BUILD-CLEANUP.md`).
- 비용: 볼륨이 `discard` 기본값으로 마운트되어 있으므로 지운 만큼 그 자리에서 호스트에 돌아간다. 10-06 측정(container 1.3.1, `masc-sandbox:general`, scratch 볼륨에 80 MB 파일 250개와 작은 파일 20,000개, 모두 20 GB): `discard` 를 켜고 지우면 7.7초, 끄고 지우면 0.07초였고, 끄고 지운 뒤의 `fstrim` 이 7.4초였다. 어느 쪽이든 `volume.img` 는 20 GB 에서 15 MB 가 됐다. 호스트 discard 는 GB 당 약 0.37초다. 그 Keeper 의 부팅이 그만큼 기다린다. 다른 Keeper 는 기다리지 않는다. `exec` 는 컨테이너를 끝내지 않는다. 10-21 01:10~01:29 에 라이브 dispatch 가 299번(분당 15번쯤) 있었고, 기준선 측정 때 exec 는 300 ms 안팎이었다(§3.1).
- 실패: timeout 이나 실패는 로그에 남기고 부팅은 계속한다. 1단계가 끝났으면 checkout 은 이번 부팅에서 링크되고, 남은 트리는 다음 새 부팅이 지운다. 그때까지 그 공간은 호스트에 돌아가지 않는다. 1단계가 실패한 checkout 은 지금처럼 scan 이 거절한다.

`_build` 제거를 아예 하지 않고 idle cleanup 에 맡기는 방법은 고르지 않았다(§5 의 A5).

### 4.3 `fstrim`

지운다. 같이 있던 `mount -o remount,nodiscard` 도 지운다. 그 단계는 helper 가 `_build` 를 지우는 비용을 `fstrim` 으로 옮기려고 있었는데, 이제 helper 가 `_build` 를 지우지 않는다.

- 이제 모든 마운트가 `discard` 로 붙는다. 게스트도, 남는 tune2fs helper 도 그렇다. 지운 블록은 지울 때 돌아간다.
- ext4 는 trim 한 자리를 마운트하는 동안만 기억한다. 그래서 `fstrim` 은 부팅마다 빈 공간 전체(183~252 GiB)를 다시 보낸다(§3.3).
- 새 볼륨에서 "252 GiB trimmed" 가 실제로 돌려준 양은 많아야 34 MB 였다. trim 전 이미지가 차지한 호스트 공간이 34 MB 였다. 라이브 볼륨에서 돌려준 양은 재지 않았다.
- 기본값이 켜지기 전(10-02 전)에 지운 블록은 그 뒤 helper 의 `fstrim` 이 이미 돌려줬다. 34개 볼륨 모두에 기본값이 있다는 것은 각 볼륨이 tune2fs 와 그 뒤의 `fstrim` 을 한 번 이상 거쳤다는 뜻이다. 그 `fstrim` 이 시간 안에 끝났는지는 볼륨마다 확인하지 않았다.

## 5. 다른 방법과 고르지 않은 이유

- A1. helper 는 두고 §B 의 조건이 맞을 때만 띄운다(진짜 `_build` 가 있을 때). 호스트는 볼륨 안을 볼 수 없다. 조건을 알려면 지난 게스트의 scan 결과를 기억해야 하는데, 그것은 지나간 증거로 행동을 정하는 gate 다. 게다가 Keeper 는 작업마다 worktree 를 만들기 때문에 대부분의 부팅에서 조건이 맞을 것이다. 막힘이 거의 그대로 남는다.
- A2. 부팅을 줄 세우거나 helper 사이에 간격을 둔다. 막힘은 helper 가 끝날 때마다 한 번씩 생긴다. 줄을 세워도 재시작 한 번의 막힌 시간을 다 더한 값은 같다. 증상을 펴 바르는 cooldown 이고, 프로젝트 규칙(`software-development.md` 의 워크어라운드 거부 기준)에 걸린다.
- A3. `container exec` 의 timeout 을 늘리거나 XPC timeout 에서 다시 시도한다. 도구는 여전히 40~65초를 기다린다. 실패가 늦게 보일 뿐이다. 같은 규칙에 걸린다.
- A4. Apple 이 고치기를 기다린다. 가장 가까운 보고는 apple/container#1884 다(1.0.0, 짧게 사는 컨테이너가 많을 때 컨테이너별 XPC 작업이 줄줄이 막힘). 이 Mac 의 1.3.1 에서는 컨테이너 하나가 끝날 때마다 `containerList` 가 42~65초 막힌다. 아직 아무것도 올리지 않았다. 올릴 가치는 있지만, 이 RFC 가 기다릴 일은 아니다.
- A5. 부팅 때 `_build` 를 지우지 않고 idle cleanup(24시간 동안 안 쓴 `_build`, 한 시간마다)에 맡긴다. idle cleanup 은 10-02 부터 돌았는데도 10-06 에 16개 게스트에 진짜 `_build` 가 134 GB 있었다(앞선 RFC §B). 그래서 §B 가 생겼다. 이 방법은 그때로 돌아간다.
- A6. 호스트에서 e2fsprogs 로 이미지 파일의 기본값을 직접 쓴다. 남는 helper 하나도 없앨 수 있다. 하지만 호스트 의존성이 새로 생기고(이 Mac 에는 `tune2fs` 가 없다), Apple 이 관리하는 이미지 파일을 masc 가 직접 고쳐 쓰게 된다. 읽기(§4.1)는 받아들이고 쓰기는 받아들이지 않는다(§10 Q2).
- A7. Keeper 게스트에 `CAP_SYS_ADMIN` 을 줘서 게스트가 직접 `fstrim`/`tune2fs` 를 하게 한다. Keeper 권한이 커진다. 고르지 않는다.

## 6. 하드 컷

- 2026-10-21 01:4x KST 에 호스트에서 `masc-keeper-work-*` 볼륨 이미지 34개의 superblock 을 읽었다. 읽기만 했다. 34개 모두 magic 이 `0xEF53` 이고, `s_default_mount_opts` 가 `0x00000400`(`EXT4_DEFM_DISCARD`)이다.
- 그래서 기존 볼륨을 위한 코드는 없다. §4.1 의 확인은 지금 상태를 읽는 것이지, 옛 데이터를 위한 reader 가 아니다. 새로 만든 볼륨도 같은 길을 탄다.
- 지금 work volume 에 남은 진짜 `_build` 는 구현을 배포한 뒤 첫 새 부팅에서 §4.2 가 지운다. 범위는 지금과 같다.

## 7. 검증 계획

테스트는 화면 글자나 로그 문장을 고정하지 않는다. argv 와 타입으로 본다.

- V1. 부팅 argv(가짜 container CLI 를 주입한 테스트). 기본값이 있는 work volume 으로 새로 부팅하면 `run` argv 는 게스트의 것 하나뿐이다. helper 이름이 들어간 argv 가 없다. `fstrim` 을 실행하는 script 도 없다. 게스트 대상 `exec` 하나가 Keeper 의 uid:gid 로 제거 script 를 나른다. 앞선 서버 프로세스가 띄운 게스트를 이 프로세스가 처음 넘길 때도 제거 `exec` 를 하나 보낸다. 이 프로세스가 이미 넘긴 게스트를 다시 adopt 하면 보내지 않는다.
- V2. superblock 읽기. 실제 ext4 레이아웃 바이트로 만든 작은 파일로 `Discard_default_set`, `Discard_default_absent`, `Superblock_unreadable`(짧은 파일, magic 이 다른 파일)을 본다. `Discard_default_absent` 일 때만 helper argv 가 나가는지 본다. helper 가 실패한 뒤에도, `Superblock_unreadable` 일 때도 게스트의 `run` argv 가 나가는지, `Superblock_unreadable` 이면 helper argv 가 없는지 본다. 같은 게스트를 adopt 하는 다음 시작은 helper argv 를 내지 않는지, sandbox 상태 JSON 의 `work_volume_discard_default` 가 그때 읽은 superblock 결과와 같은지도 본다.
- V3. 제거 script. 지금 있는 실제 임시 트리 테스트를 새 뿌리(`/masc-work/<keeper>`)로 옮긴다. 지우는 것과 남기는 것의 경우는 지금과 같다. 더할 것: 1단계 뒤 `_build` 자리가 비고 옮긴 트리가 `<keeper root>/.masc-build-removing/<mktemp 이름>/` 에 있는지, 2단계 뒤 `.masc-build-removing` 이 없어지는지, 앞선 부팅이 남긴 `.masc-build-removing/<이름>` 도 지우는지, 1단계 뒤에 새로 생긴 `_build` 는 건드리지 않는지, 같은 checkout 이름이 두 번 나와도 `mktemp` 이름이 겹치지 않는지.
- V4. 구현 전에 한 번 잰다. 살아 있는 게스트 하나에서 `discard` 를 켠 채 큰 `_build` 를 지우는 동안 다른 컨테이너의 exec/ls 가 막히는지 본다(U4). 같은 때 그 트리에 Keeper uid 가 아닌 주인의 파일이나 쓸 수 없는 디렉토리가 있는지도 센다. `find <root> -name _build -prune ...` 를 읽기만 한다. 둘 중 하나라도 나쁘면 §4.2 를 다시 정한다.
- V5. 배포 뒤 라이브. 재시작부터 마지막 새 부팅 뒤 5분까지 센다.
  - masc 가 띄운 일회용 컨테이너: 2초마다 `container ls -a --format json` 을 뽑아 helper 종류의 이름이 나타난 횟수를 센다. 새 Keeper 가 없으면 0 이어야 한다.
  - 같은 초에 몰린 실패: 20초를 넘기고 exit≠0 으로 끝난 `shell_ir dispatch` 의 수와 그것들이 끝난 초, 그리고 `container exec`/`container list` 에 대한 `Process_eio` timeout 의 수. 10-20 23:28 재시작(같은 기준으로 8건, timeout 3건)과 비교한다.
  - 게스트 교체(U2, Q3 에 따라 따로 잰다): 재시작 창 동안 2초마다 `container ls -a --format json` 을 부르는 sampler 를 돌린다. sampler 는 호출마다 시작·끝 시각과 각 `masc-keeper-vm-*` 이름의 생성 시각을 적는다. `ls` 자신이 막히면 그 호출의 걸린 시간이 곧 막힌 구간이다. 결과는 재시작 한 번에 한 줄씩 아래 표에 채운다.

    | 재시작(KST) | 새로 부팅한 게스트 N | 옛 게스트가 사라진 순간 수 | `ls` 가 20초 넘게 걸린 구간 수, 가장 긴 것 | 그 구간 가운데 끝 2초 안에 옛 게스트가 사라진 것 | 20초 넘고 exit≠0 인 dispatch | 그 가운데 끝난 초가 막힌 구간 끝과 같은 것 | `Process_eio` timeout |
    |---|---|---|---|---|---|---|---|
    | 10-20 23:28 (helper 있음, 비교용) | 18 (helper 줄 수) | 재지 않음 | 재지 않음 | 재지 않음 | 8 | 8 (helper 끝과 같은 초) | 3 |
    | 10-21 11:34 (helper 있음, 비교용. sampler 는 11:51:33~12:11:31 의 부팅 구간만 봤다) | 12 (sampler 가 본 게스트 `run`) | 0 (sweep 이 그 앞 11:34:31~11:47:07 에 20개를 지웠다) | 7, 62.9초 | 0 (7개 모두 helper 가 끝나고 2.5초 안에 시작했다) | 세지 않음 | 세지 않음 | 세지 않음 |

    - N: 재시작 뒤 생성 시각이 바뀐 `masc-keeper-vm-*` 이름의 수.
    - 옛 게스트가 사라진 순간: 옛 생성 시각으로 마지막에 보인 sample 과, 그 이름이 처음 안 보인 sample 사이.
    - 막힌 구간의 끝 2초 안에 옛 게스트가 사라진 것이 많으면, 게스트 교체가 막힘을 만든다는 측정이 된다. 그때의 구간 길이가 U2 의 값이다.
- V6. 호스트 디스크. 하루 뒤 Keeper 세 개의 `volume.img` 호스트 크기(`du`)가 게스트 안의 사용량과 비슷한지 본다. `fstrim` 없이도 블록이 돌아가는지 확인하는 것이다.

## 8. 앞선 RFC 와 문서에서 바뀌는 곳

RFC-keeper-build-output-returns-to-a-disposable-volume 에서 이 커밋이 바꾼 곳:

| 자리 | 지금 쓰인 것 | 바꾼 것 |
|---|---|---|
| Problem 끝 | "the trim runs at boot instead (§ Work volume trim at boot)", "a guest delete returns host disk only once something with `CAP_SYS_ADMIN` trims the volume" | 작업 볼륨의 `discard` 기본값은 이 RFC 가 정한다. 게스트가 지운 블록은 ext4 마운트가 discard 할 때 돌아간다 |
| Design | "Removing a real directory is the boot helper's job, while no guest holds the volume (§B)" | 새 부팅이 첫 턴 전에 지운다(§B) |
| "Work volume trim at boot" 절 | helper 의 이미지, 플래그, script 단계, 정리 확인 | 절을 지우고 §B 에서 이 RFC 를 가리킨다 |
| §A 마지막 | "§B removes it before the next guest starts" | 다음 새 부팅이 scan 전에 지운다 |
| §B | helper 의 4단계, 볼륨을 붙인 게스트가 없다는 단락, `CAP_DAC_OVERRIDE` 단락, "Step 2 decides where the time goes" 단락 | 측정된 문제(134 GB, 경고 수)와 지우는 범위만 남기고, 어디서 어떻게 지우는지는 이 RFC 를 가리킨다. 10-06 의 권한 측정과 제거 비용 측정, 두 번째 연결 거절 측정은 이 RFC §4.1, §4.2 로 옮겼다 |
| §D | "Helper end to end (§B, 2026-10-06)" 항목 | 지운다. 같은 script 가 두 이미지에서 같은 결과를 냈다는 사실은 "Unit (§B)" 항목에 이미 있다 |
| frontmatter | `related` | 이 RFC 의 slug 를 더한다 |

구현 PR 에서 함께 바꾸는 곳(지금은 실제 동작을 맞게 적고 있다):

- `docs/guides/KEEPER-VM-BUILD-CLEANUP.md` 의 첫 단락과 "Guest space versus host disk space" 절.
- `lib/keeper/keeper_sandbox_microvm.ml` 의 `:1073`, `:1154-1166`, `:1683` 주석과 `.mli` 의 `:335`, `:372`, `:463`, `:579`, `:634` 문서 주석.
- `lib/keeper/keeper_turn_sandbox_runtime.ml` 의 `reclaim_work_volume_space` 문서 주석(`:1112-1120`)과 `ensure_microvm_build_links` 문서 주석(`:1261-1282`).
- `lib/keeper/keeper_sandbox_container_name.ml:112-113` 의 `-trim` 이름 주석. helper 가 tune2fs 만 하게 되면 이름 종류도 하는 일에 맞게 바꾼다.

## 9. 구현 범위

- `Keeper_sandbox_microvm`: `work_volume_reclaim_script`, `fstrim_guest_path`, `mount_guest_path`, `reclaim_apple_work_volume` 를 지운다. `apple_work_volume_trim_argv` 는 tune2fs 만 하는 helper argv 로 바꾸고 `CAP_DAC_OVERRIDE` 를 뺀다. `build_output_removal_script` 는 게스트 경로를 받는다. superblock 읽기와 그 결과 타입을 더한다.
- `Keeper_turn_sandbox_runtime`: `Boot` 분기에서 `reclaim_work_volume_space` 를 superblock 확인(+필요할 때만 helper)으로 바꾼다. helper 실패와 `Superblock_unreadable` 은 WARN 한 줄을 남기고 부팅을 이어 간다. 새 부팅 뒤 `ensure_microvm_build_links` 앞에 게스트 안 제거 `exec` 를 넣는다.
- `Keeper_sandbox_control.live_status_json` 에 `work_volume_discard_default` 를 더한다. 읽을 때마다 superblock 을 읽어 만든다.
- 테스트: `test/test_keeper_sandbox_microvm.ml` 의 trim argv/script/정리 테스트(`:2114-2263`)를 V1~V3 에 맞게 바꾼다.
- 바꾸기 전에 지우는 함수마다 호출하는 곳을 `git grep` 으로 모두 센다.

## 10. 운영자에게 묻는 것

- Q1. `discard` 기본값 확인을 호스트에서 이미지 superblock 을 읽어서 할지(§4.1), 아니면 `Created` 일 때만 helper 를 띄울지. 앞쪽은 Apple 이 `inspect` 로 알려 주는 이미지 파일을 masc 가 읽는다. 뒤쪽은 만든 직후 서버가 죽은 볼륨을 고치지 못한다.
  - 결정(2026-10-21, 운영자): superblock 을 읽는다. 서버가 중간에 죽어도 다음 부팅이 flag 없는 볼륨을 고친다.
- Q2. 새 Keeper 의 첫 부팅에서 생기는 한 번의 40~65초 막힘을 받아들일지. 받아들이지 않으면 남는 길은 호스트 e2fsprogs(A6)나 Apple 의 수정(A4)이다.
  - 결정(2026-10-21, 운영자): 받아들인다. helper 가 만들던 막힘(재시작마다 18~22번)이 새 볼륨마다 한 번으로 준다. 재시작 때 옛 게스트를 지우면서 생기는 막힘(재시작마다 20~21번, U2)은 이 RFC 로 줄지 않는다.
- Q3. 서버를 재시작할 때마다 모든 게스트를 교체하는 일(startup sweep 이 옛 서버의 게스트를 모두 지운다)은 이 RFC 범위 밖이다. 그 교체도 컨테이너 종료다(U2). 따로 재고 따로 다룰지.
  - 결정(2026-10-21, 운영자): 따로 재고 따로 다룬다. 이 RFC 는 helper 만 다룬다. 게스트 교체는 RFC-keeper-guest-survives-restart 가 다룬다.
- Q4. 큰 `_build` 를 30초 I/O 시간 안에 다 못 지우면, 이름을 바꾼 트리가 다음 새 부팅까지 공간을 잡고 있다(§4.2). 하루 두 번쯤의 부팅을 기다려도 될지, 아니면 이 트리도 idle cleanup 이 지우게 할지.
  - 결정(2026-10-21, 운영자): 다음 새 부팅까지 둔다. idle cleanup 은 이 트리를 지우지 않는다.
- Q5. 이름 바꾸기 단계(§4.2)를 둘지. 빼면 script 는 지금처럼 `rm -rf` 하나로 단순해진다. 대신 같은 이름의 부팅 경합에서 진 쪽 턴의 빌드가 지워지는 `_build` 위에서 돌 수 있고, timeout 으로 끊기면 반쯤 지운 `_build` 가 dune 이 쓰는 자리에 남는다.
  - 결정(2026-10-21, 운영자): 이름을 바꾼 뒤 지운다(§4.2 그대로).
- Q6. apple/container 에 이 측정(1.3.1, 컨테이너 하나 종료 → `containerList` 42~65초 막힘)을 올릴지.
  - 결정(2026-10-21, 운영자): 올리지 않는다. masc 쪽에서 helper 를 부팅 경로에서 빼는 일을 먼저 한다.
- Q7. helper 가 실패하거나 superblock 을 못 읽을 때 부팅을 막을지. 막으면 같은 볼륨으로 다시 시작할 때마다 같은 결과가 나오므로, 그 반복을 멈추는 상태가 하나 더 있어야 한다. 막지 않으면 그 볼륨은 지운 블록을 호스트에 돌려주지 않는다. 볼륨을 지우기 전에 떠 둔 복사본에서 파일을 꺼내는 방법을 정할지도 함께 묻는다. `container volume` 에는 이미지를 들여오는 명령이 없다.
  - 결정(2026-10-21, 운영자): 막지 않고 부팅한다. 새 상태는 두지 않고, sandbox 상태가 superblock 결과를 보인다(§4.1). 복사본에서 파일을 꺼내는 방법은 이 RFC 범위 밖이다.
