---
rfc: "keeper-volume-filesystem-repair"
title: "Keeper volume 의 ext4 손상을 보이게 하고, Keeper 가 한가할 때 고친다"
status: Draft
created: 2026-10-22
updated: 2026-10-22
author: claude
supersedes: []
superseded_by: null
related: ["0400", "keeper-build-output-returns-to-a-disposable-volume"]
---

# Keeper volume 의 ext4 손상을 보이게 하고, Keeper 가 한가할 때 고친다

실측: [docs/evidence/2026-10-22-keeper-volume-fsck/](../evidence/2026-10-22-keeper-volume-fsck/README.md)

## 1. 문제

Apple `container` 백엔드의 Keeper 는 자기 ext4 볼륨(`masc-keeper-work-<keeper>`, `masc-keeper-build-<keeper>`) 위에서 일한다(RFC-0400).
그 볼륨이 망가져도 MASC 는 알지 못했고, 고치는 길도 없었다.

2026-10-22 에 `e-masc-the-leader` 의 work volume 이 열흘째 망가져 있었다.

- 첫 오류는 10-12 07:06:40Z 의 블록 장치 쓰기 실패다. 그 뒤 커널이 오류를 31,027,637번 적었다.
- MASC 가 본 것은 저장소 상태 점검의 WARN 한 줄씩뿐이었다. 10-21 부터 115번 찍혔지만 운영자에게 닿지 않았다.
- 고치는 데 운영자 손이 다섯 번 들었다. Keeper 정지, VM 정지, 백업, `e2fsck` 두 번, resume 과 boot 다. 호스트에 `e2fsprogs` 도 새로 깔아야 했다.

## 2. 원인

- **확인한 것**: 손상은 호스트 쪽 쓰기 실패에서 시작했다(`ext4_check_bdev_write_error`). 두 곳에서 동시에 마운트한 것은 아니다. 게스트가 볼륨을 쓰는 동안 helper 가 붙지 못하는 것은 2026-10-06 에 쟀다(Virtualization.framework 가 두 번째 연결을 거부한다).
- **확인하지 못한 것**: 그 쓰기가 왜 실패했는지. 그날 로그가 남아 있지 않다. 호스트 디스크가 찼을 수 있지만 증거가 없다.

원인을 모르는 쓰기 실패는 다시 날 수 있다. 그래서 이 RFC 는 예방이 아니라 감지와 복구를 다룬다.

## 3. 결정

### 3.1 감지: 커널이 superblock 에 적은 기록을 그대로 읽는다

- 이미지 경로는 `container volume inspect <volume>` 의 `configuration.source` 에서 얻는다. 경로를 코드에 적지 않는다. `configuration.format` 이 `ext4` 가 아니면 읽지 않는다.
- 호스트에서 이미지의 1024 byte 지점부터 1024 byte 를 읽기 전용으로 읽는다. 필드 위치는 커널 문서를 따른다(증거 §2).
- 판단은 `s_state` 의 "Errors detected" 비트(0x0002) 하나다. 숫자 기준이나 로그 문구를 보지 않는다.
- 오류 수, 첫·마지막 오류의 시각·함수·줄·inode·block 은 판단이 아니라 근거로 싣는다.
- 게스트 안에서 명령을 돌리지 않는다. 게스트가 도는 중에도 커널이 superblock 에 오류를 적는다는 것을 쟀다(증거 §2).

새 모듈 `Keeper_volume_filesystem`:

```ocaml
type error_site = { at : float; func : string; line : int; inode : int; block : int64 }

type state =
  | Clean
  | Errors_recorded of { count : int; first : error_site option; last : error_site option }

type read_failure =
  | Not_ext4 of { magic : int }
  | Truncated of { bytes : int }
  | Unreadable of string

val of_superblock : string -> (state, read_failure) result   (* 순수 *)
val read_image : path:string -> (state, read_failure) result
val image_of_inspect : Yojson.Safe.t -> (image, string) result
```

### 3.2 표시: 상태가 바뀔 때 한 번 알린다

- 서버 maintenance 루프가 Apple 백엔드 Keeper 의 볼륨을 고정 maintenance pulse 간격으로 읽는다. 볼륨 하나에 1 KB 읽기다.
- 마지막 관측은 프로세스 안의 투영으로만 둔다. 권위는 superblock 이다.
- Keeper 상태의 `sandbox_live` 에 `volume_filesystem` 객체를 더한다. TUI Keeper 화면이 이를 보여 준다.
  - 상태 조회마다 CLI 를 띄우지 않도록, 상태 조회는 루프가 남긴 마지막 관측을 읽는다.
- 깨끗함 → 오류 있음으로 바뀔 때 Board 에 `System_post`(Internal) 하나를 남긴다. 매 pulse 마다 쓰지 않는다.
  - 같은 오류 기록(첫 오류 시각과 count)이면 다시 쓰지 않는다. 판단은 자기 receipt 를 다시 읽어서 한다.

### 3.3 수리: Keeper 가 한가할 때 자동으로 한다 (운영자 결정, 2026-10-22)

Owner 의 Maintenance 레인 `Keeper_owner_registry.run_maintenance_if_idle ~defer_to_chat:true` 안에서 한다.
이 레인은 그 Keeper 의 다른 턴과 동시에 돌지 않는다(`keeper_owner.mli` "At most one turn runs per Keeper").
`Busy` 면 다음 pulse 에 다시 본다.

1. superblock 을 다시 읽는다. 이미 `Clean` 이면 아무것도 하지 않는다.
2. 그 Keeper 의 게스트를 멈추고 지운다(`teardown_keeper_sandbox_by_name`). 다음 턴이 첫 도구 호출에서 새 게스트를 띄운다(지금의 lazy boot 그대로).
3. 이미지를 APFS 복제로 백업한다(`<source>.pre-repair`). 복제가 되지 않으면(APFS 가 아닌 볼륨 등) **수리하지 않고** Board 에 알린 뒤 끝낸다.
   - 백업은 볼륨마다 하나만 둔다. 새 복제가 성공한 뒤 이전 것을 바꾼다.
4. one-shot helper 를 돌린다. trim helper 와 같은 이미지·권한이다(`--user 0 --cap-drop ALL --cap-add CAP_SYS_ADMIN --network none --read-only`).
   - 고정 스크립트: `findmnt --mountpoint` 로 장치를 찾고 → `umount` → 풀렸는지 `findmnt --mountpoint` 로 확인 → `e2fsck -f -y` → `e2fsck -f -n`.
   - 마운트가 풀리지 않으면 `e2fsck` 를 돌리지 않는다.
   - `e2fsck` 는 끝날 때까지 기다린다. 중간에 끊는 것이 더 해롭다. helper 정리에만 지금의 remove 타임아웃을 쓴다.
5. superblock 을 다시 읽어 결과를 정한다. `Clean` 이면 `Repaired`, 아니면 `Repair_incomplete` 다. helper 의 종료 코드는 근거로만 싣는다(오류 비트만 지운 경우에도 0 이었다, 증거 §4).
6. receipt 를 남기고 Board 에 결과를 쓴다. 되돌리는 방법(백업을 원래 이름으로 옮기기)을 같이 적는다.

`Repair_incomplete` 여도 게스트 boot 를 막는 Gate 를 만들지 않는다. 지금처럼 다음 턴이 게스트를 띄우고, 운영자에게는 Board 글이 남는다.

receipt: `<masc dir>/keeper-volume-repairs/keeper-<sha256 keeper>/<repair id>.json`, schema `masc.keeper.volume_repair.v1`.
필드는 keeper, volume, image, 수리 전 state, 백업 경로, helper 종료 상태와 출력 파일, 수리 후 state, 시작·끝 시각이다.

## 4. 다른 방법

| 방법 | 장점 | 단점 |
|---|---|---|
| 호스트 `e2fsck` (Homebrew `e2fsprogs`) | 오늘 실제로 썼다. 빠르다 | macOS 에 별도 설치가 필요하다. 설치 경로를 코드가 알아야 한다 |
| 게스트 `dmesg` 를 읽어 감지 | 실시간 | 도는 게스트에 exec 해야 한다. 문구를 읽어야 한다. 멈춘 볼륨은 못 본다 |
| 같은 WARN 이 N번 나면 알림 | 범용 | 숫자 기준이다(헌법 `magic_number`). 이번 WARN 은 원인을 말해 주지 않았다 |
| 감지만 하고 운영자가 수리 | 데이터 손실 결정을 사람이 한다 | 운영자 결정으로 고르지 않았다. 백업 복제로 되돌릴 수 있다 |

## 5. 바꾸지 않는 것

- trim helper 와 boot 순서. 수리는 boot 경로 밖, Maintenance 레인에서 한다.
- nerdctl·Microsandbox 백엔드. 그쪽 볼륨은 호스트 디렉터리라 이 문제가 없다.
- 게스트 boot 를 막는 새 Gate.

## 6. 검증

- `of_superblock`: 직접 만든 superblock 바이트로 Clean, 오류 있음(필드 전부), magic 불일치, 짧은 입력을 본다.
- `image_of_inspect`: 실제 `container volume inspect` 출력 모양으로 본다.
- helper argv·스크립트: trim helper 테스트와 같은 방식으로 argv 를 본다.
- 실측: 배포 뒤 임시 Keeper 하나의 work volume 에 호스트 `debugfs` 로 오류 비트를 켜고, 감지 → Board 글 → 한가할 때 수리 → `Clean` → 다음 턴 새 게스트 boot 까지 로그와 receipt 로 남긴다.

## 7. 구현 순서

한 스택, 세 층이다.

1. 감지: `Keeper_volume_filesystem` 과 테스트.
2. 표시: maintenance 루프의 관측, `sandbox_live.volume_filesystem`, TUI 표시, 상태가 바뀔 때의 Board 글.
3. 수리: Maintenance 레인의 수리 흐름, helper, receipt, 결과 Board 글.

## 8. 남은 질문

- 같은 볼륨이 수리 뒤 곧 다시 망가지면 수리가 되풀이된다. 되풀이를 숫자로 막지 않는다. 그때는 Board 에 receipt 가 쌓이므로 원인(호스트 쓰기 실패)을 운영자가 볼 수 있다. 이것으로 충분한지는 실제로 되풀이될 때 다시 본다.
- build volume 은 버려도 되는 빌드 출력이다. 수리 대신 볼륨을 다시 만드는 편이 나은지는 3층에서 정한다.
