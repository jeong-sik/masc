---
rfc: "idle-keeper-worktrees-are-swept-where-they-live"
title: "쓰고 남은 Keeper worktree 는 그 VM 안에서 치운다"
status: Draft
created: 2026-10-21
updated: 2026-10-21
author: claude
related: ["0400", "0468"]
---

# RFC: 쓰고 남은 Keeper worktree 는 그 VM 안에서 치운다

- Status: Draft. 좌표는 `origin/main` `e778d5306ef` 기준 `path:line`이다.
- 운영자 요청 (2026-10-21): "다 한 워크트리는 지워줘", "하드디스크 확보좀 하자 각종 쓰레기 파일좀 지워", "cleaner lane add on 같은거 있음 좋겠는데". 운영자 답: 범위는 필요한 만큼만, add-on 과 `/tmp` 도구는 넣지 않는다.

## 1. 문제

2026-10-21 이 세션에서 손으로 잰 값이다. 측정 스크립트와 로그는 저장소에 없다.

- 데이터 볼륨이 100% (여유 20 GiB) 까지 찼고, 정리 뒤 여유 453 GiB 가 됐다.
- 가장 큰 몫은 살아 있는 Keeper 의 작업 볼륨이었다. 실행 중인 VM 안에서 worktree 246개를 지워 약 105 GiB 를 돌려받았고, 작업 볼륨 합계는 587.9 GiB 에서 462.8 GiB 가 됐다. VM 안에서 지우면 호스트의 `volume.img` 가 바로 줄었다 (볼륨 하나 시험: 22.07 GiB 에서 19.66 GiB).
- 서버가 자동으로 치우는 것은 `_build` 뿐이다. worktree 는 문서가 일부러 따로 뒀다 (`docs/guides/KEEPER-VM-BUILD-CLEANUP.md:7`, `:24`). 살아 있는 Keeper 의 worktree 를 치우는 코드는 없다. `Keeper_bundle_worktrees.remove_keeper_worktrees` 는 지운 Keeper 에만 쓴다 (`lib/keeper/keeper_bundle_worktrees.mli:8`).
- 아직 남은 것은 수정 중인 worktree 약 192개, PR 이 없는 것 약 72개, 로컬 커밋만 있는 것 약 19개다.

## 2. 결정: `_build` 청소 옆에 worktree 단계를 둔다

서버가 Keeper 마다 `Keeper_owner_registry.run_maintenance_if_idle ~defer_to_chat:true` 안에서 `_build` 를 청소한다 (`lib/server/server_keeper_build_maintenance.ml:28`). 같은 호출 안에서 `_build` 다음에 worktree 단계를 부른다. 같은 주기, 같은 승인, 같은 방식 (이미 떠 있는 guest 에만 붙고, payload 를 `exec-shim` 으로 실행; `lib/keeper/keeper_turn_sandbox_runtime.ml:3045`) 이다.

설정은 `Runtime_settings` 에 둘 추가한다.

- `keeper_worktree_cleanup_mode`: `off | report | apply`. 처음 값은 `off`. 닫힌 enum (`register_enum`, `lib/runtime_settings.ml:109`). `report` 는 같은 보고서를 내고 아무것도 지우지 않는다.
- `keeper_worktree_cleanup_retention_sec`: 처음 값은 7일. `scripts/cleanup-stale-worktrees.sh:32` 의 `DAYS=7` 과 같다.

guest 안에서 아래를 모두 만족한 worktree 만 지운다. 하나라도 읽지 못하면 건너뛴다.

1. `git worktree list --porcelain` 에 등록되어 있고 메인 checkout 이 아니다.
2. 안에 다른 worktree (`.worktrees/`) 가 없고 `locked` 가 아니다.
3. 트리 파일의 가장 늦은 mtime (`.git` 제외, `_build` 포함) 이 `retention` 보다 오래됐다. 최근에 빌드했으면 쓰는 중으로 본다. 읽기만 한 worktree 는 mtime 이 안 바뀌어 미사용으로 판정된다. 치르는 값이 `git worktree add` 한 번이라 받아들인다. `_build` 가 바깥 symlink 이면 그 파일 자체의 mtime 만 보므로 오래된 트리로 오판할 수 있다. `report` 첫 실행에서 symlink `_build` 가 있는 worktree 를 따로 센다.
4. 살아 있는 프로세스의 cwd, exe, fd 가 그 안을 가리키지 않는다. 기존 `process_paths()` 검사를 쓰고, `/proc` 을 못 읽으면 아무것도 지우지 않는다 (`config/scripts/keeper-build-cleanup.py:35`). 제거 직전에 이 조건을 다시 읽는다.
5. 그 Keeper 가 현재 쓰는 worktree 가 아니다. sweep 전에 서버가 그 Owner 의 실행 상태와 현재 Task 를 읽는다. 실행 중·대기 중인 operation 이 이 worktree 를 쓰거나, 현재 Task (`current_task_id`, Keeper meta) 의 작업 경로가 이 worktree 이면 `skipped (keeper-in-use)` 로 보고한다. Keeper 는 턴 사이에 프로세스가 없으므로 조건 4 만으로는 이 판정이 안 된다. Task→작업경로 기록 형식은 payload 구현 PR 에서 고정한다.
6. ignore 된 파일이 알려진 산출물뿐이다. 제거 전에 `git -C <wt> status --ignored --porcelain` 으로 `!!` 항목을 모아, `_build/`, `_build_*/`, `node_modules/` allow-list 밖의 것이 하나라도 있으면 `skipped (ignored: <경로>)` 로 보고하고 지우지 않는다. git 은 ignore 된 파일을 거절 없이 함께 지우므로 (임시 저장소에서 직접 확인), `.masc/`, `*.db`, `config/keeper.env`, `.env` 같은 로컬 상태가 조용히 사라지지 않게 한다. `report` 모드에서는 그 목록을 그대로 출력한다.
7. `git worktree remove <path>` 로만 지운다. `--force` 는 쓰지 않는다. git 이 수정되었거나 untracked (단 ignore 되지 않은) 파일이 있는 트리를 거절하고, 거절은 `skip` 으로 보고한다.
8. HEAD 가 detached 이고 그 커밋이 어떤 ref 에도 없으면 지우지 않고 보고만 한다.
9. 브랜치는 지우지 않는다. 지워지는 것은 worktree 디렉터리뿐이고 커밋은 그대로다.

검사-제거 사이 창이 있다. 조건 4 를 다시 읽어도 그 읽기와 `git worktree remove` 사이에 프로세스가 들어오면 깨끗한 트리는 제거된다. 같은 Owner 의 턴과 sweep 은 Owner mailbox 로 직렬화되므로 (`run_maintenance_if_idle` 은 exclusive 시도, `lib/keeper/keeper_owner_registry.mli:69`) 그 Owner 가 sweep 중에 깨어나 같은 트리에 들어가는 경우는 닫혀 있다. 남는 창은 Owner 밖의 프로세스 (다른 사용자·에이전트) 뿐이고, 그 경우에도 조건 7·8·9 가 커밋 손실을 막는다.

PR 상태는 보지 않는다. 서버에 PR 판독은 있으나 (`lib/server/server_repository_pulls.ml`, RFC-0465) head 브랜치를 담지 않아 worktree 와 잇는 키가 없다 (`server_repository_pulls.mli:49-63` 에 `head_ref` 계열 필드가 없고, Keeper 판정은 마지막 커밋 author 로 잇는다, `:236-241`). 잇는 비용 (token·reader Keeper·GraphQL 실패 모드) 이 회수 이득보다 크므로 PR 상태 없이 간다. 브랜치가 남고 git 이 더러운 트리를 거절하므로 (조건 7·9) 판정 없이도 작업을 잃지 않는다. 치르는 값은 이렇다: PR 이 열려 있어도 `retention` 동안 아무도 만지지 않은 worktree 는 지워지고, Keeper 가 그 경로를 다시 쓰려면 `git worktree add` 를 다시 해야 한다.

보고서는 worktree 마다 경로, 브랜치, 결과 (`removed | skipped | failed`), 건너뛴 이유, 할당 바이트를 담고, 끝에 guest 여유 공간 변화를 적는다.

이 단계가 건드리지 않는 것: clone 과 임시 복사본, `_build` (기존 단계), 브랜치, stash, 이미지, 볼륨.

## 3. 하지 않는 것

- **Lane Add-on.** worker 는 "guest 네트워크를 닫고 root filesystem을 읽기 전용으로 연결하며 capability를 제거한" 컨테이너다 (`docs/guides/lane-addon-toml.md`, 실행기 선택 절). 호스트 worktree 와 Keeper 볼륨에 닿지 않고, `lane_act` 도 그 안에서 돈다 (`docs/guides/lane-world-actions.md`). 지우는 add-on 은 이 격리를 깨야 한다. 보여주기만 하는 add-on 은 호스트 쪽에 snapshot 을 쓰는 프로그램이 따로 필요해서, 화면이 필요해질 때 만든다.
- **호스트 worktree 청소기.** `scripts/cleanup-stale-worktrees.sh`, `scripts/cleanup-merged-worktrees.sh` 가 이미 있다. 이 스크립트를 읽다가 결함 두 개를 찾아 따로 고쳤다 (#44659).
- **`/private/tmp` 청소기.** 오늘 지운 복사본은 지울 때마다 사람이 판정했다. gitfile 이 가리키는 곳이 없는 디렉터리 46개 (22.7 GiB) 는 어느 저장소의 것인지 몰라서, push 안 된 작업이 있는지 증명할 수 없다. 원인은 세션이 `.tmp/` 나 scratchpad 대신 `/tmp` 에 복사본을 만든 것 (`CLAUDE.md` Temporary File Protocol) 이라, subagent brief 에서 막는다. 이건 지시일 뿐 강제가 아니다.
- **PR 상태 판정, 자동 승급, detached 태그 보관, 호스트 주기 실행.** 위 규칙으로 작업을 잃지 않으므로 필요하지 않다.
- **dune cache.** `docs/guides/DUNE-CACHE-MAINTENANCE.md` 의 운영자 절차에 둔다.

## 4. 검증

화면 문구나 행 순서는 고정하지 않는다.

guest payload (Python, `test/test_keeper_vm_build_cleanup.py` 방식의 fixture): 깨끗하고 오래된 worktree 는 지워지고 브랜치는 남는다. 수정된 파일, untracked 파일, allow-list 밖 ignored 파일 (`skipped (ignored: ...)`), 안의 worktree, `locked`, 최근 mtime, 안에 있는 프로세스 cwd, 현재 Task 의 작업 경로, 읽을 수 없는 `/proc`, 어떤 ref 에도 없는 detached HEAD 는 각각 건너뛴다. 메인 checkout 은 지우지 않는다. 실행한 argv 에 `--force` 가 없다. 보호 조건 하나씩을 빼는 변이가 해당 시험을 실패시켜야 하고, 결과를 PR 에 적는다.

untracked 파일은 임시 저장소에서 확인했다. `git diff --quiet` 와 `git diff --cached --quiet` 는 둘 다 종료 코드 0 인데 `git worktree remove` 는 `contains modified or untracked files` (종료 코드 128) 로 거절한다. 거절은 git 이 한다. ignore 된 파일은 거꾸로 확인했다. `.gitignore` 에 든 `.env`·`state.db` 는 `status --porcelain` 에 뜨지 않고 `git worktree remove` 는 종료 코드 0 으로 디렉터리째 지운다. 그래서 조건 6 이 `status --ignored` 로 먼저 본다.

OCaml (`test/test_server_keeper_build_maintenance.ml` 옆): `off` 면 부르지 않고, `report` 는 `apply=false`, `apply` 는 `apply=true` 로 부른다. Owner 가 바쁘면 건너뛴다.

실제 환경: `report` 로 한 번 돌려서 후보가 위의 192개와 겹치지 않는지 본다. 그 뒤 Keeper 한 곳만 `apply` 로 올리고 `volume.img` 크기 전후를 잰다.

## 5. 단계와 질문

- P0 (끝남): 호스트 스크립트 결함 수정, #44659.
- P1: guest payload, 설정 둘, 서버 호출. 기본 `off`.
- P2: 운영자가 `report` 를 읽고 `apply` 로 올린다. 코드 변경이 아니라 설정이다.

운영자께 묻는 것:

1. `retention` 7일이 맞나. 오늘 손으로 한 정리는 24시간에 PR 병합·종료 기준이었다.
2. Keeper 안의 clone 과 임시 복사본 (오늘 22.5, 36, 7.8, 11.3 GiB) 은 이번에 안 건드린다. 큰 것만 `report` 에 나열할까.

모르는 것: guest 이미지의 git 버전 (오늘 `git worktree remove` 가 VM 안에서 동작했지만 기록하지 않았다), worktree 수백 개인 Keeper 에서 mtime 걷기와 `/proc` 검사가 sweep 한 번에 걸리는 시간 (`report` 로 처음 잰다), 오늘 센 192개 등의 숫자 (한 번의 손 측정이라 `report` 와 맞춰 본다). `cleanup_attached_builds` 본문과 `exec-shim` timeout 계약은 읽지 않았다. 조건 5 의 Task→작업경로 기록 형식도 payload 구현 PR 에서 고정한다.
