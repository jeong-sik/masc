---
rfc: "remote-keeper-workspace-entries-are-swept-on-their-endpoint"
title: "remote_ssh Keeper 가 남긴 작업 폴더는 그 endpoint 에서 치운다"
status: Draft
created: 2026-11-08
updated: 2026-11-10
author: claude
related: ["idle-keeper-worktrees-are-swept-where-they-live"]
---

# RFC: remote_ssh Keeper 가 남긴 작업 폴더는 그 endpoint 에서 치운다

- Status: Draft. 좌표는 `origin/main` `7d90dc8cb284` 기준 `path:line` 이다.
- 운영자 요청(2026-11-08): "이거 디스크 개선좀", "기능으로도 만들어줘".
- 운영자 결정(2026-11-08):
  - 처음부터 켜 두고 바로 지운다(`apply`).
  - git 은 커밋만 지킨다.
- 운영자 결정(2026-11-10): 새것인 항목 안으로 들어가 오래된 하위 폴더도 지운다. `.git`·`dune-project` 가 있는 폴더는 한 덩어리로 본다(규칙 5).

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
- payload 시간 제한은 `keeper_remote_workspace_cleanup_timeout_sec`(처음 값 5분)다. 끝날 때까지 그 Keeper 는 다음 주기에서 건너뛴다. 11-08 report 실행은 가장 큰 루트 셋(항목 700~2,400개)에서 1~2초 걸렸다.

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
   - 같은 사용자의 읽지 못하는 프로세스는 root 프로세스가 이끄는 세션 안에 있을 때만 넘어간다.
     - 연결마다 뜨는 sshd 한 쌍이 그 세션이다. root 쪽 sshd 가 세션을 열고, Keeper 계정으로 권한을 내린 쪽(`sshd: be-sleepers@notty`)이 그 안에 남는다. 커널은 권한을 내린 프로세스를 읽지 못하게 막는다.
     - 이 payload 도 그런 sshd 아래에서 돈다. 이것까지 막으면 정리가 한 번도 돌지 못한다(11-08 report 실행에서 확인).
     - sshd 는 명령을 새 세션에서 띄운다. 프로세스는 세션을 떠날 수는 있어도 남의 세션에 들어갈 수는 없다. 그래서 Keeper 가 띄운 것은 root 가 이끄는 세션에 없다.
     - Keeper 가 띄운 프로그램이 스스로 들여다보기를 끈 경우(`prctl(PR_SET_DUMPABLE, 0)`, 예: `ssh-agent`)는 Keeper 계정이 이끄는 세션에 있다. 넘어가지 않는다.
     - 세션은 `/proc/<pid>/stat` 의 session 칸으로, 이끄는 프로세스의 사용자는 `/proc/<session>` 의 소유자로 읽는다. 이끄는 프로세스가 없으면 넘어가지 않는다.
   - 그 밖에 읽지 못하는 프로세스가 하나라도 있으면 아무것도 지우지 않는다.
     - 그 프로세스가 다른 사용자의 것이면 루트 권한 때문에 막힌 것이다. 이유에 루트 권한(예: `0755`)과 고치는 방법(bootstrap 다시 실행, `chmod go-rwx`)을 같이 적는다.
     - 11-09 wkbl endpoint 네 Keeper 의 루트가 `755` 라 매시간 이렇게 멈췄다. entrypoint 가 bind mount 로 폴더를 만들고 권한은 맞추지 않았다.
     - 권한 값은 bootstrap 의 `keeper_root_mode` 한 곳에 있다. 운영 절차는 `docs/operations/ssh-endpoints-runbook.md` 「Keeper directory mode」에 있다.
4. **안의 git 저장소가 모두 커밋을 잃지 않는다.** 트리 안 `.git` 마다 확인한다.
   - `.git` 자식이 없는 bare 저장소와 별도 Git 관리 디렉터리도 찾는다. 이 디렉터리는 커밋의 유일한 사본이거나 바깥 worktree 의 저장소일 수 있으므로, 이를 포함한 항목은 남긴다.
   - `stash list` 가 비어 있다.
   - HEAD 와 로컬 브랜치 끝이 하나도 빠짐없이 둘 중 하나다.
     - `rev-list --count <tip> --not --remotes` 가 0 이다.
     - `git ls-remote origin` 이 그 sha 를 광고한다. PR 사본이 여기에 해당한다. ls-remote 가 실패하면 건너뛴다.
   - 본 저장소(`.git` 이 폴더)이면, 그 저장소에 묶인 worktree 가 이 항목 밖에 없다. 연결된 worktree(`.git` 이 파일)는 지워도 커밋을 잃지 않는다. 커밋은 본 저장소에 있다.
   - git 명령마다 5초 제한을 둔다. 실패하거나 시간이 넘으면 건너뛴다.
5. **새것인 항목 안의 오래된 폴더도 같은 규칙으로 본다.** 11-10 에 더했다.
   - 항목이 규칙 2에 걸리면(48시간 안에 건드림) 그 안의 하위 폴더마다 규칙 0~4를 다시 적용한다. 하위 폴더도 새것이면 다시 그 안으로 들어간다.
   - 한 덩어리는 안으로 들어가지 않는다. 통째로 오래됐을 때만 지운다.
     - 한 덩어리: `.git` 이 있는 폴더(working tree, linked worktree), Git 디렉터리(`HEAD` 와 `objects` 또는 `commondir`), `dune-project` 가 있는 폴더.
     - 이유: 쓰는 중인 소스 트리에서 안 건드린 부분(`docs/`, 안 바뀐 pack)만 지우면 나머지가 깨진다.
   - 안에서는 폴더만 지운다. 파일, 점 폴더, symlink 는 남긴다. 디스크를 채우는 것은 사본 폴더다. 메모 같은 작은 파일은 아니다.
   - 보고에는 오래된 하위 폴더만 `memory/t05` 처럼 루트에서 본 경로로 적는다. 새것이라 지나간 폴더는 적지 않는다.
   - 치르는 값: `.git`·`dune-project` 가 없는 소스 트리(다른 언어 프로젝트를 압축만 푼 것)를 쓰는 중이면, 그 안에서 48시간 넘게 안 건드린 폴더가 지워질 수 있다. 리뷰 컨테이너의 사본은 모두 masc 소스라 `dune-project` 가 있다.
   - 시간: 가장 큰 루트(`code-reviewer-uncle`, 21 GB)의 report 실행이 21초에서 35초가 됐다(11-10). 제한은 5분이다.

규칙 5의 계기(11-10 00:2x KST 측정, 컨테이너 시각은 UTC):

- 11-09 손 apply 와 매시간 정리로 48시간 넘은 최상위 항목은 다 지워졌다. 그래도 사용률은 11-09 20:32 KST 50% 에서 11-10 00:22 KST 56% 로 올랐다. 시간당 약 1.8 GiB 다.
- 큰 사본은 Keeper 가 계속 메모를 쓰는 폴더 안에 있다.
  - `code-reviewer-uncle/memory` 는 17.6 GB 다. 리뷰 메모가 계속 새로 들어와 통째로는 늘 새것이다.
  - 그 안 `t05`(12.3 GB)에는 폴더 46개가 있고, 그중 15개가 masc 소스 사본이다.
  - 규칙 0~4만으로는 `memory` 가 새것인 한 이 사본들이 영영 남는다.
- 같은 날 이 규칙으로 report 를 돌렸다.
  - 48시간 기준으로는 안쪽 후보가 0.1 GiB 다. 사본들이 아직 48시간이 안 됐다.
  - 24시간 기준으로는 `code-reviewer-uncle` 안쪽 32개 6.2 GiB(`memory/tb` 3.4 GiB), `code-reviewer-brother` 안쪽 17개 6.25 GiB(`w/p113` 등 각 약 1 GiB)다.

지우는 방식과 보고:

- `shutil.rmtree` 로 지운다.
- 보고에는 항목마다 이름, 할당 바이트, 결과(`removed | skipped | failed`), 건너뛴 이유를 담는다. 끝에 정리 전후의 여유 KiB 를 적는다.
- 서버는 정리할 때마다 Keeper 마다 로그 한 줄을 남긴다. 지운 것이 없어도 남긴다: `Keeper workspace cleanup keeper= removed= skipped= failed= freed_kib= available_kib=`
  - `freed_kib` 는 정리 뒤 여유 공간에서 정리 전 여유 공간을 뺀 값이다. 볼륨을 같이 쓰는 다른 Keeper 가 그사이 쓰면 음수일 수 있다.
  - payload 가 정리를 거절하거나(`skip`) 실패하면 경고 줄을 남긴다. 저장된 meta 가 없거나 저장된 profile 이 remote_ssh 가 아니어도 경고 줄을 남긴다.
  - 정리 주기마다 한 줄을 더 남긴다: `Keeper cleanup pass owners= without_meta= unreadable= no_step= switched_off= builds= workspaces= scheduled= still_running=`. 단계가 아예 안 돈 것과, 돌았지만 지울 것이 없던 것을 이 두 줄로 가른다.
    - `builds=`·`workspaces=` 는 그 단계를 고른 Keeper 수다. 앞선 시도가 아직 안 끝난 Keeper 도 들어간다. 이번 주기에 예약한 Keeper 수는 `scheduled=` 다. 끝난 결과는 Keeper 별 줄이 보여 준다. 예약한 시도가 서버 종료로 취소되면 Keeper 별 줄 없이 끝난다.
    - 단계는 TOML 을 반영한 meta 로 고르고, 실행할 때 meta 를 한 번 더 읽는다. 그 사이에 TOML 의 profile 이 바뀌면 작업 폴더 단계는 profile 불일치 경고를 남기고, 다음 주기가 새 profile 로 고른다.
  - 11-09 첫 주기 두 번(00:08Z, 03:25Z)은 아무 줄도 남기지 않았다. 리뷰 컨테이너의 shim 요청 기록에도 payload 요청이 없었다. 같은 날 04:05Z 에 같은 payload 를 손으로 `--apply` 로 돌려 13,581개를 지웠고, 사용률이 54% 에서 42% 로 내려갔다.
  - 원인은 단계 고르기였다. 서버는 owner projection 의 meta 로 단계를 골랐는데, 그 `sandbox_profile` 은 JSON 디코더가 늘 넣는 `Docker` 다(`lib/keeper/keeper_meta_json_parse.ml:336`). 그래서 모든 Keeper 가 `_build` 정리로 갔고, 그 단계는 Remote_ssh 를 `Ok None` 으로 넘겼다. 11-09 09:09Z 주기 줄: `owners=34 without_meta=0 switched_off=0 builds=34 workspaces=0`. 지금은 TOML 을 반영한 meta(`Keeper_cleanup_attempt.read_meta`)로 고른다.

커밋 안 한 변경과 untracked 파일은 보지 않는다. 운영자 결정이다.

- 치르는 값: 48시간 넘게 아무 파일도 안 건드린 미커밋 작업은 사라진다.
- 막는 것: 커밋, stash, 원격에 없는 브랜치는 남는다. 2번 조건 때문에 48시간 안에 건드린 파일이 하나라도 있으면 그 폴더는 남는다. 한 덩어리가 아니면 그 안의 오래된 하위 폴더는 규칙 5로 지운다.
- 이유: 반대로 정하면 위 `kej` 같은 리뷰 메모 사본이 영영 남는다. 측정한 11개 중 4개가 그렇다.

설정은 `Runtime_settings` 에 셋을 더한다.

- `keeper_remote_workspace_cleanup_enabled`: 처음 값은 `true` 다. 끄면 Remote_ssh Keeper 를 훑지 않는다.
- `keeper_remote_workspace_cleanup_retention_sec`: 처음 값은 48시간. 운영자가 11-08 에 고른 기준이다.
- `keeper_remote_workspace_cleanup_timeout_sec`: 처음 값은 5분. 넘기면 endpoint 가 payload 를 멈추고 그 Keeper 는 경고 줄을 남긴다. 그때까지 지운 항목은 돌아오지 않는다. 처음에는 코드 상수였는데, 루트 크기와 ls-remote 응답 시간이 endpoint 마다 달라 11-09 에 설정으로 옮겼다.
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
- 규칙 5: 새것인 폴더 안의 오래된 폴더는 지운다(두 단계 아래까지). 안쪽의 파일·점 폴더·symlink 는 남긴다. `.git`·`dune-project`·Git 디렉터리 폴더는 새것이면 안으로 들어가지 않고, 통째로 오래되면 지운다. 안쪽에서도 로컬 커밋과 살아 있는 프로세스는 지킨다.
- 보호 조건 하나를 빼면 해당 시험이 실패해야 한다. 규칙 5의 조건 9개를 하나씩 빼 보면 모두 시험이 실패한다(11-10).

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
- L3(11-10): 규칙 5. payload 와 Python 시험, 설정 설명.
