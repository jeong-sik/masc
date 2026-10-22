---
rfc: "keeper-volume-filesystem-repair"
title: "Keeper volume 의 ext4 손상을 보이게 하고, Keeper 가 한가할 때 고친다"
status: Draft
created: 2026-10-22
updated: 2026-10-22
author: claude
supersedes: []
superseded_by: null
related: ["0400", "0373", "keeper-build-output-returns-to-a-disposable-volume"]
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
- **확인한 것**: 이 볼륨들에는 journal 이 없다(`s_feature_compat` 0x0208, `HAS_JOURNAL` 비트 없음, 증거 §2).
  - journal 이 없는 ext4 는 마운트할 때 "깨끗이 풀림" 비트(`VALID_FS`, 0x0001)를 지우고, 깨끗이 풀 때만 다시 켠다.
  - 그래서 VM 이 강제로 꺼지면 "Errors detected" 비트 없이도 메타데이터가 어긋날 수 있다. 망가진 볼륨은 `container stop` 뒤에도 `VALID_FS` 가 꺼져 있었다. 적어도 한 번은 깨끗하지 않게 풀린 적이 있다는 뜻이다.
- **확인하지 못한 것**: 첫 쓰기가 왜 실패했는지. 그날 로그가 남아 있지 않다. 호스트 디스크가 찼을 수 있지만 증거가 없다.

원인을 모르는 쓰기 실패는 다시 날 수 있다. 그래서 이 RFC 는 예방이 아니라 감지와 복구를 다룬다.

## 3. 결정

### 3.1 감지: 커널이 superblock 에 적은 기록을 그대로 읽는다

- 이미지 경로는 `container volume inspect <volume>` 의 `configuration.source` 에서 얻는다. 경로를 코드에 적지 않는다. `configuration.format` 이 `ext4` 가 아니면 읽지 않는다.
- 호스트에서 이미지의 1024 byte 지점부터 1024 byte 를 읽기 전용으로 읽는다. 필드 위치는 커널 문서를 따른다(증거 §2).
  - 일반 파일이 아니면 읽지 않는다. named pipe 는 열 때 기다리지 않는다.
- 판단은 `s_state` 의 "Errors detected" 비트(0x0002) 하나다. 숫자 기준이나 로그 문구를 보지 않는다.
  - `VALID_FS` 는 판단에 쓰지 않는다. journal 이 없어서 게스트가 붙어 있는 동안에는 늘 꺼져 있다.
- 오류 수, 첫·마지막 오류의 시각·함수·줄·inode·block·원인 코드는 판단이 아니라 근거로 싣는다.
  - 함수 이름은 OCaml 식으로 escape 한다. C 식별자는 그대로이고, 망가진 바이트는 JSON 과 Board 글에 깨진 UTF-8 로 들어가지 않는다.
  - block 은 부호 없는 64-bit 정수로 낸다.
- 게스트 안에서 명령을 돌리지 않는다. 게스트가 도는 중에도 커널이 superblock 에 오류를 적는다는 것을 쟀다(증거 §2).
- 게스트가 쓰는 중에 읽으면 반쯤 쓰인 superblock 을 읽을 수 있다. 이 볼륨들은 `metadata_csum` 이 꺼져 있어서(`s_feature_ro_compat` 0x4a) 검사할 체크섬이 없다.
  - 그래서 수리를 정하는 읽기는 게스트를 지운 뒤에 한 번 더 한다(§3.3 4번). 감지 루프의 잘못된 읽기는 Board 글 하나로 끝나고 데이터를 바꾸지 않는다.

새 모듈 `Keeper_volume_filesystem`:

```ocaml
type error_site =
  { at : float; func : string; line : int; inode : int; block : int64; code : error_code }

type state =
  | Clean
  | Errors_recorded of { count : int; first : error_site option; last : error_site option }

type read_failure =
  | Not_ext4 of { magic : int }
  | Truncated of { bytes : int }
  | Not_regular_file of { kind : Unix.file_kind }
  | Unreadable of string

val of_superblock : string -> (state, read_failure) result   (* 순수 *)
val read_image : path:string -> (state, read_failure) result
val image_of_inspect : Yojson.Safe.t -> (image, inspect_failure) result
```

### 3.2 표시: 상태가 바뀔 때 한 번 알린다

- 서버 maintenance 루프가 Apple 백엔드 Keeper 의 볼륨을 maintenance pulse 마다 읽는다.
  - 어느 Keeper 가 Apple 백엔드인지는 Keeper TOML 을 덮은 meta 로 정한다. Owner 투영의 meta 는 저장된 meta 라서 `sandbox_profile` 이 자리표시값이다.
  - 이미지 경로는 처음 읽을 때와 읽기가 실패한 뒤에만 `container volume inspect` 로 얻는다. 평소에는 볼륨 하나에 1 KB 읽기만 한다.
- 마지막 관측은 프로세스 안의 투영으로만 둔다. 권위는 superblock 이다.
- Keeper 상태의 `sandbox_live` 에 `volume_filesystem` 목록을 더한다. 볼륨마다 마지막 관측과, 수리 백업이 있으면 그 경로를 싣는다.
  - 상태 조회는 루프가 남긴 마지막 관측을 읽는다. 상태 조회마다 CLI 를 띄우지 않는다.
- 볼륨이 오류를 기록하기 시작하면 Board `sandbox` hearth 에 `System_post`(Internal) 하나를 남긴다. 매 pulse 마다 쓰지 않는다.
  - "시작"은 서버가 뜬 뒤 첫 읽기, 또는 깨끗했거나 실패한 읽기 다음이다.
  - 그래서 서버를 다시 띄우면 아직 망가진 볼륨은 한 번 더 알린다. 알림을 놓치는 것보다 한 번 더 쓰는 편이 낫다.

### 3.3 수리: Keeper 가 한가할 때 자동으로 한다 (운영자 결정, 2026-10-22)

**언제 시도하나**

- 관측이 `Errors_recorded` 인 볼륨에서, 이번 오류 구간에 아직 수리를 돌리지 않았으면 시도한다. 깨끗한 읽기가 나오면 그 구간이 끝난다.
  - 이 기억은 프로세스 안에만 있다. 서버를 다시 띄우면 한 번 더 시도하고, 그때는 아래 2번(백업이 있으면 멈춤)에서 끝난다.
- Owner 의 Maintenance 레인 `Keeper_owner_registry.run_maintenance_if_idle ~defer_to_chat:true` 안에서 돈다. `Busy` 면 다음 pulse 에 다시 시도한다.
- 수리는 Keeper 마다 자기 fiber 에서 돈다. 수리 하나가 오래 걸려도 다른 Keeper 의 감지는 멈추지 않는다.

**순서 (레인 안)**

1. helper 이미지를 고른다. trim helper 와 같이 그 Keeper 자신의 `sandbox_image` 다. 고르지 못하면 아무것도 바꾸지 않고 끝난다(`Helper_unavailable`).
   - 지금 쓰는 두 이미지(`masc-sandbox:general`, `masc-sandbox-ocaml`)에 `e2fsck`, `findmnt`, `umount` 가 다 있다(2026-10-22 측정). 도구가 없는 이미지면 스크립트가 `umount` 전에 멈춘다.
2. `<source>.pre-repair` 가 이미 있으면 수리하지 않는다(`Backup_present`).
   - 백업은 운영자 것이다. 서버는 백업을 덮어쓰거나 지우지 않는다.
   - 수리가 실패하거나 끊겨도 처음 망가진 원본이 그대로 남는다. 운영자가 확인하고 지우면, 다음 오류 구간에서 다시 자동으로 고친다.
3. 그 Keeper 의 게스트를 멈추고 지운다(`teardown_keeper_sandbox_by_name`). 다음 턴이 첫 도구 호출에서 새 게스트를 띄운다(지금의 lazy boot 그대로).
4. superblock 을 다시 읽는다. 붙은 게스트가 없으니 이 읽기가 권위다. `Clean` 이면 끝난다(`Not_needed`).
5. 이미지를 APFS 복제(`cp -c`)로 `<source>.pre-repair` 에 백업한다. 복제가 되지 않으면 **수리하지 않고** 끝난다(`Backup_unavailable`).
6. one-shot helper `masc-keeper-work-<keeper>-repair` 를 돌린다.
   - 권한: `--user 0 --cap-drop ALL --cap-add CAP_SYS_ADMIN --network none --read-only --tmpfs /tmp`. trim helper 와 달리 `CAP_DAC_OVERRIDE` 는 없다. 파일을 지우지 않기 때문이다.
   - 고정 스크립트: `findmnt --mountpoint` 로 장치를 찾고 → `umount` → 풀렸는지 `findmnt --mountpoint` 로 확인 → `e2fsck -f -y` → `e2fsck -f -n`. 마운트가 풀리지 않으면 `e2fsck` 를 돌리지 않는다.
   - `container` 에는 볼륨을 블록 장치로만 붙이는 옵션이 없어서, helper 는 볼륨을 한 번 마운트했다가 푼다. 그 마운트가 orphan 정리로 쓰기를 할 수 있지만, 백업이 그 앞에 있다. 마운트가 실패하면 helper 가 시작하지 못하고 `Helper_refused` 로 끝난다.
   - `e2fsck` 는 끝날 때까지 기다린다. 타임아웃이 없다. 중간에 끊는 것이 더 해롭다. 그동안 레인을 잡고 있으므로 그 Keeper 는 턴을 돌지 않는다.
   - 시작할 때 Board 에 helper 이름과 백업 경로를 쓴다. 진행은 `container logs <helper>` 로 보고, `container stop <helper>` 로 끝낼 수 있다고 같이 적는다. 운영자가 끝내면 helper 가 0 이 아닌 상태로 끝나고(`Helper_refused`) 백업이 남는다.
   - helper 정리에는 지금의 remove 타임아웃을 쓴다.
7. superblock 을 다시 읽어 결과를 정한다. `Clean` 이면 `Repaired`, 아니면 `Repair_incomplete` 다. helper 의 종료 코드는 근거로만 싣는다(오류 비트만 지운 경우에도 0 이었다, 증거 §4).
   - 호스트 디스크가 차 있으면 `e2fsck` 의 쓰기가 실패한다. 그 출력이 receipt 에 남고 결과는 `Repair_incomplete` 다.
8. receipt 를 남기고 Board 에 결과를 쓴다. 되돌리는 방법을 같이 적는다: 게스트가 없을 때 백업을 원래 이름으로 옮긴다.

`Repair_incomplete` 여도 게스트 boot 를 막는 Gate 를 만들지 않는다. 지금처럼 다음 턴이 게스트를 띄우고, 운영자에게는 Board 글과 백업이 남는다.

**수리가 끊길 때**

- Keeper shutdown 이나 서버 종료가 레인을 끊으면, switch 정리가 helper 를 지운다. `e2fsck` 는 중간에 멈춘다. 백업은 남고 receipt 는 없다. "receipt 없는 백업"이 끊긴 수리의 흔적이다. 다음 시도는 2번에서 멈춘다.
- 서버가 죽으면 정리가 돌지 못하고 helper VM 이 `e2fsck` 를 계속 돌 수 있다. 그동안 게스트 boot 는 두 번째 연결 거부로 실패한다(§2). 같은 볼륨이 두 번 붙지 않는다. helper 가 끝나면(`--rm`) boot 가 다시 된다.

**수리 창에 볼륨에 붙을 수 있는 것**

| 진입점 | 언제 도나 | 수리 창에서 |
|---|---|---|
| 게스트 boot (`Keeper_sandbox_factory`, lazy) | 턴 안 | 레인이 턴을 막는다 |
| trim helper | 게스트 boot 안 | 위와 같다 |
| `cleanup_attached_builds` | Maintenance 레인 | 레인은 하나만 돈다. 그리고 이미 도는 게스트에만 exec 한다 |
| `sweep_abandoned_microvm_guests` | 서버 시작 | 게스트를 지우기만 하고 붙이지 않는다 |
| 끊긴 수리의 helper | 서버가 죽은 뒤 | 위 "수리가 끊길 때" |

receipt: `<masc dir>/keeper-volume-repairs/keeper-<sha256 keeper>/<repair id>.json`, schema `masc.keeper.volume_repair.v1`.
필드는 repair id, keeper, volume, image, 시작·끝 시각, 게스트를 지운 뒤 읽은 state, 백업 경로, helper 종료 상태와 출력 전체, 결과다.

work volume 과 build volume 을 같은 길로 고친다. build volume 은 버려도 되는 출력이지만, 다시 만드는 길(볼륨 삭제와 boot 때 재생성)을 따로 두면 실패하는 방식이 하나 더 생긴다.

## 4. 다른 방법

| 방법 | 장점 | 단점 |
|---|---|---|
| 호스트 `e2fsck` (Homebrew `e2fsprogs`) | 오늘 실제로 썼다. 빠르다. 마운트하지 않는다 | macOS 에 별도 설치가 필요하다. 설치 경로를 코드가 알아야 한다 |
| 게스트 `dmesg` 를 읽어 감지 | 실시간 | 도는 게스트에 exec 해야 한다. 문구를 읽어야 한다. 멈춘 볼륨은 못 본다 |
| 같은 WARN 이 N번 나면 알림 | 범용 | 숫자 기준이다(헌법 `magic_number`). 이번 WARN 은 원인을 말해 주지 않았다 |
| 감지만 하고 운영자가 수리 | 데이터 손실 결정을 사람이 한다 | 운영자 결정으로 고르지 않았다. 첫 백업이 남으니 되돌릴 수 있다 |
| 실패하면 다음 pulse 에 다시 수리 | 손이 덜 간다 | 실패할 때마다 게스트를 지운다. 백업을 덮으면 원본을 잃는다 |

## 5. 바꾸지 않는 것

- trim helper 와 boot 순서. 수리는 boot 경로 밖, Maintenance 레인에서 한다.
- nerdctl·Microsandbox 백엔드. 그쪽 볼륨은 호스트 디렉터리라 이 문제가 없다.
- 게스트 boot 를 막는 새 Gate.

## 6. 검증

- `of_superblock`: 모든 필드에 서로 다른 값(32-bit 필드는 2^31 위, 64-bit 필드는 2^32 위)을 넣은 superblock, 실제 superblock 두 개, `VALID_FS` 만 켜진 상태, 원인 코드 표 전체, magic 불일치, 짧은 입력을 본다. 필드 위치와 마스크를 하나씩 바꾼 변이 16개가 모두 테스트에 걸려야 한다.
- `read_image`: named pipe 와 디렉터리를 기다리지 않고 거절하는지 본다.
- `image_of_inspect`: 실제 `container volume inspect` 출력 모양과 거절 갈래 각각을 본다.
- 볼륨 이름: 저장된 meta 와 Keeper TOML 에서 work·build 볼륨이 나오는지 본다.
- 수리 흐름: 효과를 가짜로 넣고 결과 갈래마다 순서와 백업·helper 호출 여부를 본다.
- helper argv·스크립트: trim helper 테스트와 같은 방식으로 argv 를 본다.
- 실측(배포 뒤):
  - 임시 Keeper 하나의 work volume 에 호스트 `debugfs` 로 오류 비트를 켜고, 감지 → Board 글 → 한가할 때 수리 → `Clean` → 다음 턴 새 게스트 boot 까지 로그와 receipt 로 남긴다.
  - 오늘의 실제 손상 백업(`volume.img.pre-fsck-20261022`)의 복제를 임시 볼륨에 넣고 같은 수리를 돌린다. 망가진 파일시스템을 helper 가 마운트할 수 있는지, `e2fsck` 가 helper 의 기본 메모리 안에서 끝나는지를 잰다.

## 7. 구현 순서

한 스택, 세 층이다.

1. 감지: `Keeper_volume_filesystem` 과 테스트.
2. 표시: maintenance 루프의 관측, `sandbox_live.volume_filesystem`, 오류가 시작될 때의 Board 글.
3. 수리: Maintenance 레인의 수리 흐름, helper, receipt, 시작·결과 Board 글.

TUI 화면 표시는 이 스택 뒤에 따로 한다.

## 8. 남은 질문

- 같은 볼륨이 수리 뒤 다시 망가지면, 백업이 남아 있는 한 자동 수리는 2번에서 멈춘다. 운영자가 백업을 지우는 일이 매번 필요한지는 실제로 되풀이될 때 다시 본다.
- 쉴 새 없이 일하는 Keeper 는 한가한 pulse 가 오지 않을 수 있다. Owner 슬롯 넘김이 공평하지 않다는 것은 RFC-0373 에서 쟀다. 가장 바쁜 Keeper 가 한가한 pulse 를 얼마나 자주 갖는지 재고, 필요하면 운영자가 바로 수리를 시키는 길을 따로 정한다.
- journal 없는 볼륨은 VM 이 강제로 꺼질 때마다 어긋날 수 있다(§2). 볼륨을 만들 때 journal 을 켤 수 있는지, 또는 게스트가 없을 때 `VALID_FS` 가 꺼진 볼륨도 수리 대상으로 볼지는 따로 정한다.
- helper 의 메모리는 `container` 기본값이다. 큰 볼륨의 `e2fsck` 가 그 안에서 끝나는지는 §6 실측으로 본다.
