---
rfc: "remote-keeper-workspace-entries-are-swept-on-their-endpoint"
title: "remote_ssh Keeper 가 남긴 작업 폴더는 그 endpoint 에서 치운다"
status: Draft
created: 2026-11-08
updated: 2026-11-09
author: claude
related: ["idle-keeper-worktrees-are-swept-where-they-live"]
---

# RFC: remote_ssh Keeper 가 남긴 작업 폴더는 그 endpoint 에서 치운다

- Status: Draft. 좌표는 `origin/main` `7d90dc8cb284` 기준 `path:line` 이다.
- 운영자 요청(2026-11-08): "이거 디스크 개선좀", "기능으로도 만들어줘".
- 운영자 결정(2026-11-08):
  - 처음부터 켜 두고 바로 지운다(`apply`).
  - git 은 커밋만 지킨다.

## 1. 문제

2026-11-08 리뷰어 공유 컨테이너(`masc-ssh-review-team`, `127.0.0.1:22268`)에서 잰 값이다.

- 엔드포인트 셋(`apple-review-be`·`apple-review-anyang`·`apple-review-pangyo`)은 볼륨 `/masc-work`(126 GiB)를 같이 쓴다.
- 이 볼륨이 100% 찼다. 남은 공간은 968,904 KiB 였다.
- preflight 는 1 GiB 아래면 거절한다(`lib/keeper/keeper_sandbox_remote.ml:1684-1691`, `Env_config_sandbox.Preflight.ssh_disk_free_min_kib` 기본 1,048,576 KiB). 그래서 리뷰어 Keeper 의 `Execute` 가 `remote_ssh_disk_low` 로 막혔다.
  - `code-reviewer` 와 `code-reviewer-brother` 는 PR #49923 리뷰를 냈지만 PR 에 올리지 못했다.
- 사용량은 계정 하나에서 `du -xsk /masc-work/*` 를 한 번 돌려 쟀다.
  - 가장 큰 폴더: `code-reviewer-uncle` 38.5 GiB, `context-reviewer` 26.8 GiB, `code-reviewer-mother` 18.3 GiB, `code-reviewer-brother` 18.0 GiB.
  - 대부분은 PR 마다 하나씩 만든 0.6~1 GB 소스 사본이다. 이름은 `p48503`, `t47807`, `v72src`, `r48110` 같은 식이다.
- 운영자 승인 뒤 48시간 넘게 안 바뀐 50 MB 이상 폴더 97개를 손으로 지웠다. 사용률은 22% 가 됐다(남은 공간 104,095,988 KiB).
- 볼륨은 10-29 에 만들었다. 열흘 남짓 만에 찼으니 그대로 두면 다시 찬다.
- 서버는 원격 Keeper 의 작업 폴더를 치우지 않는다. 서버의 정리 단계 `Keeper_turn_sandbox_runtime.cleanup_attached_builds` 는 Apple microVM 의 `_build` 만 다룬다. Remote_ssh 에는 `Ok None` 을 돌려준다(`lib/keeper/keeper_turn_sandbox_runtime.ml:4378`).

남은 사본 11개의 git 모양(같은 날 읽기만 함):

- HEAD 가 detached 인 사본이 7개다.
- HEAD 커밋이 원격 추적 ref 에 없는 사본이 3개다. `fetch pull/N/head` 로 받은 PR head 로 보인다.
- `git status` 가 비지 않은 사본이 4개다. 그중 `code-reviewer-brother/w/kej` 는 index 가 비어 29,722개가 `D ` 로 보이고, 나머지 25개는 리뷰 메모(`body-49051.md`, `dph.ml`)다. 진행 중인 코드 작업이 아니다.

## 2. 결정: `_build` 정리 옆에 원격 작업 폴더 단계를 둔다

서버의 같은 정리 주기에서 단계를 하나 더 부른다. 이 단계는 Keeper 가 쉬기를 기다리지 않는다.

- 정리 주기는 `lib/server/server_keeper_build_maintenance.ml` 이 돌린다.
- `_build` 정리만 `Keeper_owner_registry.run_maintenance_if_idle ~defer_to_chat:true` 로 Owner 승인을 받는다. 그 Keeper 의 턴과 빌드 잠금을 같이 쓰기 때문이다.
- 작업 폴더 단계는 Keeper 의 턴 옆에서 돈다. 턴이 쓰는 폴더는 아래 규칙 2(최근에 건드림)와 3(살아 있는 프로세스)이 남긴다.
  - 11-09 첫 주기(00:08Z)에 idle 승인을 거쳤을 때는 하나도 못 지웠다. 켜진 리뷰어 7명 중 최소 5명이 그 순간 턴 중이었다. 리뷰어는 턴을 거의 쉬지 않고 잇는다.
  - 같은 날 손으로 돌린 report 는 리뷰어 9명 모두에서 지울 후보를 찾았다(합계 13,525개). 사용률은 40% 였다.
  - 한 Keeper 에 두 정리가 겹치지 않게 막는 것은 서버의 Keeper 별 예약이다.
  - 남는 위험: 턴이 48시간 안 건드린 폴더를 명령 두 번 사이에 다시 쓰면, 그 사이에 지워질 수 있다. 다음 명령이 실패하고 Keeper 가 다시 받는다. 커밋과 stash 는 규칙 4가 지킨다.
- 대상은 `sandbox_profile = remote_ssh` 인 Keeper 다.

payload 는 `config/scripts/keeper-remote-workspace-cleanup.py` 다. 동작:

- 바이너리에 넣고(`Embedded_config`), stdin 으로 넘겨 `python3 -` 로 돌린다. `Keeper_sandbox_remote.runner` 를 거치고, 실행 위치는 Keeper 루트 `remote_root/<keeper>` 다.
- endpoint 는 `Keeper_sandbox_ssh.resolve_endpoint` + `Keeper_sandbox_ssh.create` 로 만든다. `attached_guest_endpoint` 는 `ready` 에서 디스크 preflight 를 돌리기 때문에, 이 단계가 꼭 필요할 때 거절당한다.
- 서버는 늘 `--apply` 로 부른다. `--apply` 가 없으면 지우지 않고 보고만 한다. 운영자는 같은 파일을 ssh 로 손으로 돌려 후보를 본다.
- payload 시간 제한은 5분이다. 끝날 때까지 그 Keeper 는 다음 주기에서 건너뛴다. 11-08 report 실행은 가장 큰 루트 셋(항목 700~2,400개)에서 1~2초 걸렸다.

Keeper 루트 바로 아래 항목마다 아래를 모두 만족해야 지운다. 하나라도 읽지 못하면 건너뛰고 이유를 보고한다.

0. **이름이 `.` 으로 시작하지 않는다.** Keeper 루트에는 masc 가 쓰는 상태가 있다.
   - Keeper 의 GitHub 로그인 `.config/gh` 가 있다(`lib/keeper/keeper_sandbox_remote.ml:260` `gh_config_dir`).
   - 원격 쓰기 도구의 임시 파일 `.masc-write.*` 가 있다(`lib/keeper/keeper_tool_filesystem_remote_write.ml:34`).
   - 그래서 점 항목은 크기와 나이에 상관없이 남긴다.
1. **symlink 가 아니다.** 실제 경로가 Keeper 루트 안에 있다.
2. **오래됐다.** 트리 안 모든 inode 의 `max(mtime, ctime)` 이 retention 보다 오래됐다. symlink 는 따라가지 않는다.
   - ctime 도 보는 이유: `git archive`·tar 로 푼 사본은 mtime 이 커밋 시각이라, 방금 만든 사본도 오래돼 보인다. ctime 은 풀 때의 시각이다.
3. **쓰는 프로세스가 없다.** 살아 있는 프로세스의 cwd·exe·열린 파일이 그 안을 가리키지 않는다. `/proc` 를 못 읽으면 아무것도 지우지 않는다.
   - Keeper 루트가 group·other 에 search 권한을 주지 않을 때가 있다(11-08 리뷰 컨테이너는 모두 `700`). 그러면 다른 사용자의 프로세스는 넘어간다.
     - root 프로세스도 넘어간다. Keeper 계정은 root 프로세스를 읽을 수 없다(11-08 `/proc/1/cwd` Permission denied). root 셸이 Keeper 폴더에 있다면 운영자가 한 일이다.
   - 같은 사용자의 프로세스라도 `/proc` 링크 소유자가 root 이면 넘어간다.
     - 권한을 내린 프로그램이나 setuid 프로그램이 이렇다. 커널이 그 프로세스를 읽지 못하게 막는다.
     - 이 payload 를 실어 나르는 sshd 세션(`sshd: be-sleepers@notty`)이 그런 프로세스다. 이것까지 막으면 정리가 한 번도 돌지 못한다(11-08 report 실행에서 확인).
     - Keeper 작업(셸, git, 빌드)은 읽을 수 있는 프로세스로 돈다.
   - 그 밖에 읽지 못하는 프로세스가 하나라도 있으면 아무것도 지우지 않는다.
4. **안의 git 저장소가 모두 커밋을 잃지 않는다.** 트리 안 `.git` 마다 확인한다.
   - `.git` 자식이 없는 bare 저장소와 별도 Git 관리 디렉터리도 찾는다. 이 디렉터리는 커밋의 유일한 사본이거나 바깥 worktree 의 저장소일 수 있으므로, 이를 포함한 항목은 남긴다.
   - `stash list` 가 비어 있다.
   - HEAD 와 로컬 브랜치 끝이 하나도 빠짐없이 둘 중 하나다.
     - `rev-list --count <tip> --not --remotes` 가 0 이다.
     - `git ls-remote origin` 이 그 sha 를 광고한다. PR 사본이 여기에 해당한다. ls-remote 가 실패하면 건너뛴다.
   - 본 저장소(`.git` 이 폴더)이면, 그 저장소에 묶인 worktree 가 이 항목 밖에 없다. 연결된 worktree(`.git` 이 파일)는 지워도 커밋을 잃지 않는다. 커밋은 본 저장소에 있다.
   - git 명령마다 5초 제한을 둔다. 실패하거나 시간이 넘으면 건너뛴다.

지우는 방식과 보고:

- `shutil.rmtree` 로 지운다.
- 보고에는 항목마다 이름, 할당 바이트, 결과(`removed | skipped | failed`), 건너뛴 이유를 담는다. 끝에 정리 전후의 여유 KiB 를 적는다.
- 지우거나 실패한 항목이 있으면 서버는 Keeper 마다 로그 한 줄을 남긴다: `Keeper workspace cleanup keeper= removed= skipped= failed= freed_kib= available_kib=`
  - `freed_kib` 는 정리 뒤 여유 공간에서 정리 전 여유 공간을 뺀 값이다. 볼륨을 같이 쓰는 다른 Keeper 가 그사이 쓰면 음수일 수 있다.
  - payload 가 정리를 거절하거나(`skip`) 실패하면 경고 줄을 남긴다.

커밋 안 한 변경과 untracked 파일은 보지 않는다. 운영자 결정이다.

- 치르는 값: 48시간 넘게 아무 파일도 안 건드린 미커밋 작업은 사라진다.
- 막는 것: 커밋, stash, 원격에 없는 브랜치는 남는다. 2번 조건 때문에 48시간 안에 건드린 파일이 하나라도 있으면 항목 전체가 남는다.
- 이유: 반대로 정하면 위 `kej` 같은 리뷰 메모 사본이 영영 남는다. 측정한 11개 중 4개가 그렇다.

설정은 `Runtime_settings` 에 둘을 더한다.

- `keeper_remote_workspace_cleanup_enabled`: 처음 값은 `true` 다. 끄면 Remote_ssh Keeper 를 훑지 않는다.
- `keeper_remote_workspace_cleanup_retention_sec`: 처음 값은 48시간. 운영자가 11-08 에 고른 기준이다.
- 점검 주기는 `keeper_build_cleanup_interval_sec`(1시간)를 같이 쓴다.
- report 모드 설정은 두지 않는다. `Runtime_params` 에는 enum 을 등록하는 도구가 없고, 보고만 볼 때는 payload 를 손으로 돌리면 된다.

## 3. 하지 않는 것

- **microVM worktree:** `RFC-idle-keeper-worktrees-are-swept-where-they-live` 의 범위다.
- **Docker playground:** `scripts/cleanup-docker-playground-worktrees.sh` 가 이미 있다.
- **PR 상태 판정:** 커밋을 지키는 규칙만으로 작업 손실을 막는다.
- **보관 표지와 Keeper 지침 변경:** Keeper 가 무엇을 남길지 정하게 하는 장치는 넣지 않는다.
- **endpoint 볼륨 확장:** 컨테이너 운영의 일이다.

## 4. 검증

payload(Python, `test/test_keeper_remote_workspace_cleanup.py`, `test/test_keeper_vm_build_cleanup.py` 방식의 fixture):

- 지워지는 것: 오래되고 깨끗한 clone, 오래된 dirty·untracked clone, 원격이 광고하는 detached PR head, 오래된 비-git 폴더.
- 남는 것: 점 항목(`.config/gh`), 원격에 없는 로컬 커밋, ls-remote 실패, stash, 최근 ctime, 안쪽 저장소의 로컬 커밋, symlink 항목, 밖에 묶인 worktree, 살아 있는 프로세스 cwd, 읽을 수 없는 `/proc`.
- report 모드는 아무것도 지우지 않는다.
- 보호 조건 하나를 빼면 해당 시험이 실패해야 한다.

OCaml:

- 보고 JSON 을 typed record 로 파싱한다.
- 설정이 꺼져 있으면 부르지 않는다. microVM·Docker Keeper 는 빌드 정리 설정을, Remote_ssh Keeper 는 이 설정을 따른다.
- 서버는 늘 `--apply` 로 부른다.

실제 환경:

- 배포 전에 payload 를 리뷰 컨테이너에서 손으로 report 로 돌려 후보를 본다.
  - 11-08 결과: Keeper 10명, 지울 후보 14,486개, 약 12.7 GiB.
  - 대부분은 `code-reviewer-uncle` 의 오래된 `.tgz`(각 약 330 MB)다.
  - 남긴 이유: 48시간 안에 건드림 1,124개, 점 항목 20개, symlink 1개.
- 배포 뒤 첫 주기의 로그 줄과 `df -Pk /masc-work` 를 본다.

## 5. 단계

- L0: 이 문서.
- L1: payload 와 Python 시험.
- L2: OCaml 모듈, 설정 둘, 서버 호출, changelog.
