# Keeper work volume 손상 실측 · 2026-10-22

RFC [keeper-volume-filesystem-repair](../../rfc/RFC-keeper-volume-filesystem-repair.md) 의 근거다.
호스트는 macOS, `container` CLI 1.3.1 이다. 시각은 UTC.

## 1. 무엇이 고장 났나

`e-masc-the-leader` 의 work volume(`masc-keeper-work-e-masc-the-leader`, 256 GB sparse ext4, 실사용 42 GB)이 손상돼 있었다.

- 게스트 `dmesg`:
  ```
  EXT4-fs (vdc): error count since last fsck: 31027563
  EXT4-fs (vdc): initial error at time 1791788800: ext4_check_bdev_write_error:227
  EXT4-fs (vdc): last error at time 1792665084: ext4_find_extent:944: inode 1417672
  ```
  첫 오류는 2026-10-12 07:06:40Z 의 블록 장치 쓰기 실패다.
- 서버 로그의 저장소 상태 점검이 같은 볼륨에서 실패했다.
  `repository freshness scan unavailable keeper=e-masc-the-leader: ... OSError: [Errno 117] Structure needs cleaning: './wt-backport/bin/.git'`
  10-21 09:28Z 부터 86건, 10-22 에 29건. 모두 WARN 한 줄씩이었고 운영자에게는 닿지 않았다.
- 같은 시각 실행 중이던 다른 Keeper VM 다섯 대의 `dmesg` 에는 ext4 오류가 없었다.
- 10-12 의 서버 로그는 이미 지워졌고, macOS 통합 로그에도 그 시각의 디스크 부족 기록은 남아 있지 않다. 쓰기 실패의 원인은 확인하지 못했다.

## 2. 호스트에서 superblock 만 읽어도 커널 기록이 보인다

이미지 경로는 `container volume inspect <name>` 의 `configuration.source`, 형식은 `configuration.format` (`ext4`)에서 얻는다.
superblock 은 1024 byte 지점의 1024 byte 다. 필드 위치는 커널 문서
<https://www.kernel.org/doc/html/latest/filesystems/ext4/super.html> 을 따랐다
(`s_magic` 0x38, `s_state` 0x3A, `s_error_count` 0x194, `s_first_error_time` 0x198 + `_hi` 0x278,
`s_first_error_func` 0x1A8, `s_first_error_line` 0x1C8, `s_last_error_time` 0x1CC + `_hi` 0x279,
`s_last_error_line` 0x1D4, `s_last_error_func` 0x1E0, "Errors detected" 비트 0x0002).

수리 전에 떠 둔 APFS 복제본과 수리한 이미지를 읽기 전용으로 읽은 결과:

| 이미지 | magic | Errors detected | s_error_count | 첫 오류 | 마지막 오류 |
|---|---|---|---|---|---|
| `volume.img.pre-fsck-20261022` | 0xef53 | 켜짐 | 31,027,637 | 2026-10-12T07:06:40Z `ext4_check_bdev_write_error`:227 | 2026-10-22T10:59:31Z `ext4_find_extent`:944 |
| 수리한 `volume.img` | 0xef53 | 꺼짐 | 0 | 없음 | 없음 |

게스트가 볼륨을 쓰고 있는 동안에도 커널이 오류를 superblock 에 적었다.
마지막 오류 시각(10:59:31Z)은 게스트를 멈추기(11:05Z) 직전이다.

같은 방식으로 `container volume ls` 의 ext4 볼륨 74개를 읽었다. 수리 뒤에는 오류가 기록된 볼륨이 없었다.

## 3. 운영자가 돌린 수리

세션 스크립트로 이렇게 했다. Keeper shutdown → `container stop` → `lsof` 로 이미지를 잡은 프로세스가 없는지 확인 → `cp -c` APFS 복제 → 호스트 `e2fsck` 1.47.4 `-f -y` → `-f -n`.

- `-f -y` 종료 코드 1(고침), `-f -n` 종료 코드 0(깨끗함). 두 번 합쳐 25초 걸렸다.
- 3,944개 inode 를 `lost+found` 로 옮겼고, 디렉터리 133개가 망가져 있었다.
- 손상된 항목의 경로는 거의 다 `/e-masc-the-leader/wt-backport` 안이었다(`docs` 463건, `lib` 22건). git worktree 라서 원격에서 다시 받을 수 있다.
- shutdown 은 Keeper 를 운영자 일시정지로 남겼다. 다시 올릴 때는 `directive` 로 `resume` 을 보낸 뒤 `boot` 해야 했다(`boot` 만 보내면 409).

## 4. 게스트 이미지 안에서도 수리할 수 있다

1 GB 임시 볼륨 `masc-fsck-probe-20261022` 로 쟀다. 실제 Keeper 볼륨은 건드리지 않았다.

1. 호스트 `debugfs -w -R "ssv state 3"`, `-R "ssv error_count 7"` 로 "clean with errors / FS Error count 7" 을 만들었다.
2. trim helper 와 같은 권한으로 helper 하나를 돌렸다.
   ```
   container run --rm --user 0 --cap-drop ALL --cap-add CAP_SYS_ADMIN --network none
     --read-only --tmpfs /tmp --entrypoint /bin/sh
     --volume masc-fsck-probe-20261022:/masc-fsck masc-sandbox:general -u -c '...'
   ```
   출력:
   ```
   dev=/dev/vdc
   e2fsck=/usr/sbin/e2fsck umount=/usr/bin/umount
   umount_rc=0
   e2fsck 1.47.0 (5-Feb-2023)
   ... /dev/vdc: 11/65536 files (0.0% non-contiguous), 4116/262144 blocks
   repair_rc=0
   ... verify_rc=0
   ```
   `e2fsck` 는 마운트 경고 없이 돌았다.
3. 호스트 `dumpe2fs -h` 로 다시 읽으니 "Filesystem state: clean", 오류 수 줄이 사라졌다.

배운 점:
- 오류 비트만 켜진 경우 `e2fsck -f -y` 는 비트를 지우고도 0 으로 끝났다. 무엇이 고쳐졌는지는 종료 코드가 아니라 수리 전후 superblock 을 호스트에서 읽어 판단해야 한다.
- 마운트가 풀렸는지는 `findmnt --mountpoint` 로 본다. `findmnt --target` 은 마운트가 풀리면 상위 파일시스템을 찾아 성공한다.
- `container run` 1.3.1 에는 볼륨을 마운트하지 않고 블록 장치로만 붙이는 옵션이 없다(`--volume`, `--mount type=...` 뿐).
