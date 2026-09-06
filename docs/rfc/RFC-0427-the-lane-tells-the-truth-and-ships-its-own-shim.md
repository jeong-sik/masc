---
rfc: "0427"
title: "실행 레인은 사실을 말하고, 자기 shim 을 스스로 배포한다 — keeper 가 도구를 마음껏 쓰기 위한 네 갈래"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent
supersedes: []
superseded_by: null
related: ["0400", "0404", "0405", "0421", "0422"]
---

## 1. 문제

keeper 가 도구를 마음껏 쓰려면 두 가지가 먼저 있어야 한다. 도구가 돌려주는 답이
사실이어야 하고, 레인이 죽었을 때 keeper 와 운영자가 그 이유를 바로 알아야 한다.
2026-09-05 하루의 로그(`system_log_2026-09-05.jsonl`, 175,525줄)는 둘 다 아직
아니라고 말한다.

### 1.1 하루치 숫자

| 항목 | 값 | 출처 |
|---|---|---|
| tool_call 전체 | 11,892 (ok 11,417 · error 475) | `tool_call tool=` |
| Execute 호출 | 1,820 | 같은 줄 |
| tool_execute 승인 경로 | readonly_sandbox 841 · keeper_always_allow 552 · **judge(one_shot_resolution) 319** · observed_in_box 32 | `operation=tool_execute source=` |
| Execute 오류 중 cwd 없음 | 38 (`cwd_missing`/`cwd_not_directory`) | `tool=Execute outcome=error` |
| Grep 오류 중 엔드포인트에 없는 경로 | 16 (`remote_*_read_failed … rg: … No such file`). 메시지의 `/Users/…` 는 게스트 답을 호스트 표기로 되쓴 것이다(§1.2 A) | `tool=Grep outcome=error` |
| Read 오류 | 109 (그중 `path_outside_sandbox` 12) | `tool=Read outcome=error` |
| 실행 레인 전멸 시간 | 13:39Z ~ 15:57Z, keeper 8명 | 보드 p-d5ed6f05, #33425 |

### 1.2 네 가지 증상

**(A) 읽기·실행 도구가 호스트 경로로 게스트 트리를 찾는다.** RFC-0400 이후
microvm keeper 의 트리는 게스트 볼륨(`/masc-work/<keeper>`)에 있고, remote_ssh
keeper 의 트리는 원격 계정 안(`/opt/masc-playground`)에 있다. 그런데 오늘
`Execute` 는 `cwd_not_directory: /Users/dancer/me/.masc/playground/polisher/masc-t1348`
로 38번 거절됐다(`Keeper_tool_execute_path.resolve_missing_cwd` 가 호스트 경로의
존재를 본다; #33461 이 고쳤다). 처음 이 문서는 rondo 의 `Grep` 오류
`remote_ssh_read_failed … rg: /Users/dancer/me/.masc/playground/rondo/repos/masc: No such
file` 를 "원격 rg 에 호스트 경로가 갔다" 로 읽었다. 틀렸다. 읽기 경로의 호스트→원격
변환(`Keeper_sandbox_read_backend.container_path_of_host` → `Keeper_remote_path.host_to_remote`)
은 맞게 동작하고(microvm 매핑을 `test_keeper_sandbox_read_backend` 에 고정했다), 원격 rg 는
`/opt/masc-playground/rondo/repos/masc` 를 받았다. 그 디렉터리가 원격에 없어서 rg 가
exit 2 로 그 경로를 찍었고, 레인이 게스트 출력의 keeper 루트를 호스트 표기로 되쓰는
`Keeper_remote_path.rewrite_output` 이 그것을 `/Users/…` 로 바꿔 keeper 에게 보였다. 즉
그 16건은 keeper 가 없는 경로를 물은 것이고, 레인은 사실을 말했다. polisher 의
"있는 패턴인데 `ok:true, matches:[]`" 는 이 부류가 아니라 재시작 전 서버에서만 보인
현상으로, 재시작 뒤에는 polisher 3건·sangsu 7건·rondo 19건의 Grep 이 모두 성공했다.
A 의 나머지 둘(A-2, A-3)은 그 뒤 실측으로 닫았다. rg 는 없는 경로에 exit 2, 빈
디렉터리에 exit 1 로 끝나고, 읽기 op 는 이미 그 둘을 가른다(2 는 실패에
`error_detail`, 죽은 레인은 `classify_read_outcome` 이 언제나 오류). 원격 argv 를
타입으로 좁히는 쪽도 부를 자리가 트리에 하나뿐이라 지킬 것이 세 줄이다.

**(B) shim 은 손으로 배포되고, 서버는 그 사실을 모른다.** shim 은 운영자가
`build-shim.sh` 로 만들어 `~/me/.masc/microvm/shim/` 과 원격 호스트
`/usr/local/bin` 에 복사한다. 2026-09-05 서버가 프로토콜 v3 으로 올라갔을 때 shim
은 v2 그대로였고, 실행 레인이 2시간 18분 동안 전부 죽었다. #33425 가 한 버전
차이를 견디게 했지만, 두 버전 차이나 새 설정 키는 다시 같은 모양으로 죽는다.
배포 단위가 둘인 채로는 이 클래스가 닫히지 않는다.

**(C) judge 가 여전히 실행 다섯 건 중 한 건을 본다.** 319/1,742 = 18%. RFC-0422 의
상자는 오늘 32건을 증명했다. 상자가 살아있는 레인은 16:20Z 부터 전부다(게스트
shim 15:53Z, remote_ssh 테스트베드 16:20Z 교체). 어느 비율까지 내려가는지는
아직 측정 전이다.

**(D) 레인이 죽으면 keeper 는 세 시간 동안 폴링한다.** 보드 스레드 p-d5ed6f05 에
keeper 여덟 명이 "n번째 데이터포인트" 를 쌓았다. 원문은 같았고(`trailer carries
v=2, this build speaks v=3`) 필요한 건 한 줄이었다: "서버와 shim 버전이 다르다.
운영자가 shim 을 바꿔야 한다." 서버는 그 사실을 `run_probe` 에서 이미 알고 있었다.
keeper 가 읽을 자리가 없었을 뿐이다.

## 2. 목표와 측정

| 갈래 | 목표 | 측정 (주간, 로그) |
|---|---|---|
| A 경로 | 게스트·원격 트리를 가진 keeper 의 Read/Grep/Execute 가 호스트 경로를 보지 않는다 | 호스트 확인에서 난 `cwd_missing`+`cwd_not_directory` 0 (엔드포인트가 답한 것은 셈에 넣지 않는다), 알려진-매치 탐침 100% 적중 |
| B 배포 | shim 은 서버 릴리즈의 일부다. 부팅이 게스트 shim 을 놓고, preflight 가 원격 shim 의 해시를 본다 | `remote_shim_version_skew` 0, `microvm_shim_missing` 0, 운영자 복사 절차 삭제 |
| C 통행료 | judge 경유 비율을 18% 에서 측정값 기준으로 내린다 | `source=one_shot_resolution` / 전체 tool_execute, `observed_in_box` 수, `observe run refused` 수 |
| D 진단 | keeper 가 한 도구 호출로 자기 레인 상태와 운영자 조치를 읽는다 | 레인 장애 시 보드 "데이터포인트" 댓글 수, 장애 인지까지 시간 |

## 3. 설계

### 3-A. 트리를 가진 쪽이 경로의 권위다

`Keeper_types_profile_sandbox.tree_location_of_profile` 이 이미 `Endpoint_owned |
Shared_mount` 를 가른다. 읽기 디스패치(`Keeper_sandbox_read_backend.resolve_read_dispatch`)
는 이 값을 쓰고 rg 인자도 `container_path_of_host` 로 변환하지만, 그 앞의 cwd 해석
(`Keeper_tool_execute_path.resolve_tool_read_cwd`)은 여전히 호스트 경로를 만든 뒤 그 존재를
호스트에서 확인한다. Execute 쪽은 #33461 이 옮겼다.

- `Endpoint_owned` 프로필에서는 호스트 파일시스템을 보지 않는다. cwd 는 논리
  경로(keeper 루트 기준 상대 경로)로만 검증하고, 존재 확인은 엔드포인트가 한다
  (shim 이 `cwd` 를 `chdir` 하며 실패하면 `remote_ssh_path_jail_violation` 또는
  ENOENT 를 트레일러로 돌려준다. 이미 그렇게 동작한다).
- rg·cat 등 읽기 명령의 인자는 `Keeper_remote_path` 의 논리→원격 변환을 거친다.
  변환이 없는 경로는 오류다. 호스트 경로가 원격 argv 에 실리는 일은 타입으로
  막는다: 원격 argv 를 만드는 함수는 `Remote_path.t` 만 받는다.
- Grep 의 0 매치는 rg 의 exit 1 과 "검색한 디렉터리가 있었다" 두 사실이 함께 있을
  때만 `matches: []` 다. rg 가 exit 2 를 내면 오류로 돌려준다(지금도 그렇다).
  디렉터리 존재는 같은 요청 안에서 `test -d` 로 확인하지 않고, rg 의 stderr
  `No such file or directory` 를 exit 2 와 함께 읽는다.

검증: 게스트 안에서만 있는 파일에 대한 Read/Grep/Execute 세 도구 시나리오를
`test_keeper_sandbox_read_backend` 와 `test_keeper_tool_filesystem_remote_write` 옆에
둔다. 호스트에 같은 이름의 빈 디렉터리를 두고도 게스트의 결과가 나와야 한다.

### 3-B. shim 은 릴리즈 산출물이고, 서버가 놓는다

- 릴리즈 워크플로(`.github/workflows/release.yml`)가 `build-shim.sh` 로
  linux/arm64 와 linux/amd64 정적 shim 을 만들어 릴리즈 자산으로 올린다.
  러너는 지금 `ubuntu-latest`(amd64) 뿐이라 arm64 는 `ubuntu-24.04-arm` 러너
  또는 컨테이너 안 크로스 빌드가 필요하다. 1단계에서 둘 중 하나를 확정한다.
- 서버 바이너리는 자기 릴리즈의 shim 해시 두 개(arm64, amd64)를 상수로 안다.
  `dune-project` 버전과 같은 곳에서 나오며, 릴리즈 스크립트가 함께 갱신한다.
- microvm 부팅: `<base>/.masc/microvm/shim/masc-exec-shim` 의 해시가 상수와
  다르면 서버가 릴리즈 자산에서 받아 원자적으로 놓는다(`Fs_compat.save_file_atomic`,
  옛 파일은 `.prev`). 받을 수 없으면 지금처럼 `microvm_shim_missing` 으로 부팅을
  거절하되, 메시지에 릴리즈 URL 과 기대 해시를 적는다.
- remote_ssh preflight: `--probe` 응답에 shim 이 자기 sha256 을 더한다
  (`probe.sha256`, 프로토콜 v3 안에서 추가 필드는 허용). 해시가 릴리즈와 다르면
  preflight 는 통과시키되(한 버전 차이는 #33425 로 견딘다) `remote_shim_outdated`
  를 WARN 으로 남기고, 운영자 명령 `masc shim install <endpoint>` 가 그 엔드포인트의
  키로 `/usr/local/bin` 에 놓는다(계정에 쓰기 권한이 없으면 sudo 경로를 안내).
- 운영자 절차 문서(`MICROVM-REMOTE-RUNBOOK.md` "shim 만들기")는 삭제한다.

검증: 릴리즈 스모크(`release-binary-smoke.sh`)가 shim 두 개의 해시와 `--probe`
를 확인한다. 부팅 테스트는 다른 해시의 가짜 shim 을 두고 서버가 바꾸는지 본다.

### 3-C. 상자가 증명하는 비율을 측정하고, 표를 그 결과로 넓힌다

RFC-0422 §4-2 그대로다. 2026-09-05T16:20Z 부터 이틀 동안
`source=observed_in_box`, `source=one_shot_resolution`, `observe run refused` 를
센다. 그 다음:

- `observe run refused` 의 stderr 를 모아 "게스트 안 쓰기만 한 명령"(RFC-0422
  §1.1 의 264건 부류)이 얼마인지 본다. 그 부류가 절반을 넘으면 keeper 하나를
  `observation_run = "guest_local"` 카나리로 돌린다.
- judge 가 허용한 명령 중 상자가 같은 답을 냈을 것(exit 0 로 관측)의 비율을
  본다. 표(RFC-0404)에 넣을 후보는 그 교집합에서만 고른다. 텍스트 예측을 늘리는
  대신 상자의 판정을 표의 근거로 쓴다.

검증은 숫자 자체다. `scripts/measure-rfc-0427-judge-share.py --since … --until …
<system_log_*.jsonl>` 이 §5 의 행을 만든다(`--selftest` 로 자기 검사). 주간 표를 §5 에
덧붙인다.

### 3-D. keeper 가 읽는 레인 상태는 서버가 이미 아는 것의 투영이다

`Keeper_sandbox_remote.shared_state` 는 엔드포인트마다 probe 결과(major,
capabilities)와 첫 디스패치 여부를 가진다. 여기에 마지막 디스패치의 결과
분류(성공 / 전송 오류 / 버전 오류 / 도달 불가)와 시각을 더하고, 읽기 전용 도구
`keeper_lane_status` 가 그것을 돌려준다.

- 출력은 레인마다 한 줄: 프로필, 엔드포인트, shim 버전과 capability, 마지막
  성공 시각, 마지막 실패 분류와 원문 한 줄, 그리고 실패 분류에 대응하는 운영자
  조치 문장(`remote_shim_version_skew` → "shim 을 다시 놓아야 한다. 운영자
  작업이다"). 조치 문장은 분류 variant 위의 exhaustive match 로, string 분류기가
  아니다.
- 이 도구는 상태를 바꾸지 않고, 다른 keeper 의 레인은 보여 주지 않는다. 함대
  차원의 뷰는 대시보드의 일이다.
- 상태는 authority 가 아니라 projection 이다. 저장하지 않고, 서버 재시작이면
  비어 있다. "알 수 없음" 은 그대로 알 수 없음이다.

검증: `remote_shim_version_skew` 를 내는 stub 엔드포인트에서 도구가 그 분류와
조치 문장을 돌려주는 테스트. 보드에서 데이터포인트 댓글이 사라지는지는 다음
장애 때 본다.

## 4. 순서와 크기

| 단계 | 내용 | 크기 | 선행 |
|---|---|---|---|
| A-1 | `Endpoint_owned` 프로필의 cwd 해석에서 호스트 존재 확인 제거, 논리 경로 검증만 | 3 파일 (#33461, 머지) | 없음 |
| D-1 | `shared_state` 에 마지막 디스패치 분류, `keeper_lane_status` 도구 | 12 파일 (#33472, 머지) | 없음 |
| B-1 | 릴리즈 워크플로에 shim 두 아키텍처 빌드와 자산 업로드 | 1~2 파일 | 없음 |
| B-2 | 서버가 아는 릴리즈 shim 해시, 부팅 시 게스트 shim 자동 배치 | 3 파일 | B-1 |
| B-3 | probe 에 sha256, preflight WARN, `masc shim install` | 4 파일 | B-1 |
| C-1 | 이틀 측정표, 카나리 결정 | 문서 | 16:20Z + 48h |
| C-2 | 카나리와 표 후보 | 설정 + 표 | C-1 |
| A-2 | 원격 argv 가 `Remote_path.t` 만 받도록 타입 경계 (관측 결함 없음, 재발 방지) | 3~4 파일 | B, C 뒤 |
| A-3 | Grep 0 매치 판정에 exit 2 + stderr 조건, 알려진-매치 테스트 | 2 파일 | A-2 |

한 단계가 한 Draft PR 이다. A 와 D 는 서로 독립이라 병렬로 간다. B-1 은 CI 러너
확정이 먼저다.

## 5. 측정 기록

| 창 | tool_execute | judge | observed_in_box | refused | unavailable | cwd 오류 | 비고 |
|---|---|---|---|---|---|---|---|
| 09-05 00:00~16:30Z | 1,839 | 319 (17.3%) | 39 | 2 | 6 | 38 | 상자 전. 손으로 센 초안(1,742/319/32/2/38)을 스크립트가 대체 |
| 09-05 하루 | 7,697 | 414 (5.4%) | 1,382 | 87 | 20 | 64 | 16:20Z 부터 전 레인에 상자 |
| 09-05 16:20Z ~ 09-06 05:40Z | 7,829 | 113 (1.4%) | 1,613 | 95 | 20 | 35 | A-1 은 09-06 04:54Z 재시작부터 라이브(그 뒤 cwd 오류 1건은 엔드포인트가 답한 것) |

## 6. 하지 않는 것

- 표(RFC-0404)와 셸 IR(RFC-0421)에 텍스트 규칙을 더 얹는 일. 상자의 판정이 근거가
  되기 전에는 넓히지 않는다.
- 레인 상태를 저장하거나, 그것으로 스케줄링을 막는 Gate. 투영만 한다.
- microsandbox 백엔드 살리기. #32837 과 #33431 은 별건이다.
- 죽어 있는 remote_ssh 엔드포인트 다섯 개(127.0.0.1:2222, :22222)를 살리는 일.
  다시 쓸 때 B-3 의 `masc shim install` 로 붙인다.
