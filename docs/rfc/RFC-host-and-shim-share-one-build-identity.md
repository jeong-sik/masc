---
rfc: "host-and-shim-share-one-build-identity"
title: "서버와 exec shim 은 같은 소스 신원을 갖고, 서버는 같은 신원의 shim 만 쓴다"
status: Draft
created: 2026-11-18
updated: 2026-11-18
author: vincent + claude
supersedes: []
superseded_by: null
related: ["server-carries-its-exact-worker-packages", "microvm-guest-agent-over-socket"]
---

# 서버와 exec shim 은 같은 소스 신원을 갖고, 서버는 같은 신원의 shim 만 쓴다

## 0. 요약

- 2026-11-17~18 운영 서버는 relay 2 를 말하는 소스 빌드였고, 마운트된 guest shim 은 0.73.1 릴리즈 자산(relay 1)이었다. microVM Keeper 13개의 실행 요청이 모두 보내지지 않았고, 화면에는 아무것도 나오지 않았다(§1).
- 원인은 하나다. 서버와 shim 이 서로 다른 곳에서 오고, 둘을 잇는 열쇠가 릴리즈 버전 문자열이다. 소스에서 규약이 바뀌어도 버전 문자열은 그대로라서, 설치기는 다른 빌드의 shim 을 아무 말 없이 가져온다.
- 이 RFC 는 규칙 하나를 세운다. **서버는 자기와 같은 소스 신원(source identity)을 가진 shim 만 쓴다.**
- 규칙에서 결정 넷이 나온다.
  - D1. 소스 신원 `{ commit; state }` 를 dune 규칙 하나가 만든다. 서버와 shim 은 같은 생성 모듈을 링크한다. shim 은 신원을 hello 에 싣고, 바이트에도 선언으로 남긴다.
  - D2. 호환 열쇠는 신원 전체의 정확한 일치다. relay 버전 범위나 협상은 두지 않는다.
  - D3. shim 은 서버가 준비한다. 소스 빌드는 같은 checkout 에서 Linux 컨테이너로 shim 을 빌드하고, 릴리즈 설치는 같은 태그의 자산을 받아 신원으로 확인한다. 다른 빌드의 shim 을 받는 경로는 모두 지운다.
  - D4. 원격 SSH 엔드포인트도 같은 열쇠를 쓴다. 신원이 다르면 서버가 고정된 SSH 채널로 자기 shim 을 올리고, 올릴 권한이 없으면 typed 거절로 끝난다.
- 운영자 결정(2026-11-18, 원문 취지): 「정석으로 고친다. 필요하면 전부 하드컷한다. 이런 일이 다시는 없어야 한다.」
- 마이그레이션은 없다. 신원을 선언하지 않은 shim 은 모두 거절된다(§6).

## 1. 지금

### 1.1 11-17~18 사건 (#52968, #52971)

집계 창: 2026-11-18 00:00~02:08Z 서버 로그(running 0.73.1). 11-17 은 같은 문장만 셌다.

| 사실 | 값 | 근거 |
|---|---|---|
| `speaks relay version 1 and this host speaks 2` | 84줄, Keeper 13개 | #52968 |
| `microvm agent guest replaced instead of adopted` | 8줄. 교체된 게스트도 같은 이유로 다시 거절 | #52968 |
| microVM dispatch `request_not_sent` | 9건. 이 창의 microVM dispatch 전부 | #52968 |
| 시간마다 도는 build 정리 실패 | 31건, 같은 거절 | #52968 |
| 11-17 같은 문장 | 453줄. 11-14~16 은 0줄 | #52968 |
| 화면 | `effective_mode=microvm_vm_running`, `keeper_last_error` 등 모두 null | #52971 |

- 서버는 #52734 부터 relay 2 를 말한다(`lib/exec_ssh_protocol/exec_ssh_protocol.ml` `Relay.version`). `dune-project` 버전은 0.73.1 그대로다.
- shim 디렉터리 `<base>/.masc/microvm/shim` 은 `scripts/install.sh` 와 `scripts/install-local-build.sh --refresh-guest-shim` 이 채운다. 둘 다 `Build_version.current`(0.73.1)가 가리키는 릴리즈 자산을 받는다. 0.73.1 자산은 relay 1 이다. relay 2 shim 을 싣는 릴리즈는 아직 없다.
- 부팅 전 검사는 shim 이 sha256 sidecar 와 같은지만 본다(`keeper_microvm_shim_readiness.ml` `verify_files`). sidecar 는 릴리즈 자산의 해시라서 옛 shim 이 「verified」로 통과한다.
- 원격 SSH 엔드포인트도 같은 종류의 문제가 있다. 운영자 보고로 shim 0.66.0, 서버 0.73.1 이다(원문 로그 미직독). 지금 이 차이는 WARN(`remote_shim_outdated`)일 뿐 거절이 아니다(`keeper_sandbox_remote.ml` `warn_on_release_skew`).

### 1.2 지금 구조

- 서버 바이너리는 빌드 때 commit 을 새긴다(`lib/build_commit/probe-commit.sh` → `Build_commit_generated.commit`). `/health` 만 이 값을 읽는다.
- shim 은 `Shim_build_id.release`(dune-project 버전)와 `suffix` 를 probe 에 싣는다. hello 에는 `relay_version` 만 있다.
- shim 을 만드는 스크립트는 둘이다. `scripts/remote-ssh/build-shim.sh` 는 저장소 dune 으로 컨테이너에서 빌드한다(릴리즈 워크플로가 쓴다). `scripts/build-shim-static.sh` 는 소스를 임시 프로젝트로 복사해 빌드한다(SSH fixture 가 쓴다).
- 릴리즈 워크플로는 같은 run 에서 런타임과 shim 을 빌드한다(`release-build.yml` 「Build exec shim」). 둘이 같은 commit 인지는 아무도 확인하지 않는다.

### 1.3 열린 PR #52973

- #52973 은 relay 버전 선언 `MASC_EXEC_SHIM_RELAY_VERSION=2;` 를 shim 바이트에 넣고, 부팅 전에 읽어 다르면 거절한다. Boot 갈래가 기존 게스트를 멈추기 전에 readiness 를 먼저 본다.
- 이 PR 은 증상(교체 반복)을 막는다. 하지만 열쇠가 여전히 사람이 올리는 숫자다. 규약을 바꾸면서 숫자를 안 올리면 같은 사건이 다시 난다. relay 가 같아도 shim 동작(jail, 설정 키, 신호 처리)이 다르면 막지 못한다.
- 이 RFC 의 L1 은 선언 문법을 신원으로 바꾸고, Boot 갈래 순서는 그대로 가져간다(§8).

## 2. 규칙

**서버는 자기와 같은 소스 신원을 가진 shim 만 쓴다. 신원은 빌드가 새기고, 서버와 shim 은 같은 생성 모듈에서 읽는다.**

- 같은 신원이면 같은 소스다. 같은 소스면 규약도 같다. 그래서 relay 버전을 따로 맞출 필요가 없다.
- 신원을 모르면(선언 없음, 서버도 신원 없음) 같다고 볼 근거가 없으니 거절한다.

## 3. 설계

### 3.1 소스 신원 (D1)

```ocaml
(* lib/build_commit/source_identity.mli *)
type state =
  | Clean
  | Modified of { digest : string }  (* 바뀐 내용의 git object id *)

type t = { commit : string; state : state }

val current : t option   (* 이 바이너리의 신원. 모르면 None *)
val equal : t -> t -> bool

type scan = Declared of t | Undeclared | Several of t list
val scan : string -> scan  (* 바이너리 바이트에서 선언을 모두 찾는다 *)
```

- `probe-commit.sh` 가 `Build_commit_generated.source_identity_declaration` 을 만든다. 값은 문자열 리터럴 하나다. 예: `MASC_SOURCE_IDENTITY=<40자 commit>/clean;`, 바뀐 트리면 `.../modified:<digest>;`.
- `state` 는 working tree 를 본다. `git diff --binary HEAD`, 추적하지 않는 파일 목록, 그 파일들의 object id 를 이어 붙여 `git hash-object --stdin` 으로 줄인다. 바뀐 게 없으면 `Clean` 이다.
  - commit 만 쓰면, 같은 HEAD 에서 고친 내용이 다른 두 빌드가 같은 신원이 된다. 소스 빌드를 운영하는 이 저장소에서는 실제로 생길 수 있는 일이라 막는다.
- git 이 없는 빌드(컨테이너 안)는 `MASC_BUILD_COMMIT` 과 `MASC_BUILD_SOURCE_STATE` 를 둘 다 받아야 신원이 생긴다. 하나만 있으면 신원은 `None` 이다. 모르는 값을 `Clean` 으로 채우지 않는다.
- `current` 는 선언 리터럴을 런타임에 파싱한 값이다. 그래서 리터럴이 반드시 바이너리에 남는다. 서버와 shim 은 같은 `Source_identity` 모듈을 링크한다. 손으로 쓴 사본은 없다.
- `relay_version` 과 `build_kind`(릴리즈/소스)는 열쇠에 넣지 않는다. relay 는 소스가 정한다. 같은 소스의 릴리즈 빌드와 소스 빌드는 같은 동작이다.

### 3.2 hello 와 부팅 전 확인 (D1, D2)

- hello 에 `source_identity` 를 더한다. 필드가 없으면 `None` 으로 읽는다. 옛 shim 의 hello 도 `Malformed_hello` 가 아니라 「신원 없음」으로 읽혀야, 거절 문구가 무엇을 다시 설치할지 말할 수 있다.
- `Keeper_guest_socket.refusal` 의 `Other_relay_version` 을 `Other_source { server; agent; agent_relay }` 로 바꾼다. 서버와 agent 의 신원이 둘 다 있고 같을 때만 다음 검사(read-only root, owner, no_new_privs)로 간다.
- 부팅 전: readiness 가 마운트할 shim 바이트를 한 번 읽어 sidecar 해시와 신원 선언을 같이 본다. `Declared t` 이고 `t = current` 일 때만 통과한다. 아니면 `Verification_failed (Shim_from_other_source { shim; server })` 다. 실패는 캐시하지 않는다.
- Apple Boot 갈래는 기존 게스트를 멈추기 전에 readiness 를 본다(#52973 과 같은 순서). 그래서 `Other_source` 로 교체되는 경우는 「디스크의 shim 은 맞고, 떠 있는 agent 만 옛 바이트로 떠 있던」 경우뿐이다. 교체가 고칠 수 없는 거절은 교체로 가지 않는다.

### 3.3 shim 준비는 서버 쪽 일 (D3)

- 소스 빌드: `install-local-build.sh` 가 서버를 빌드한 같은 checkout 에서 `scripts/remote-ssh/build-shim.sh --arch <게스트 arch>` 로 shim 을 빌드한다. 컨테이너 CLI 는 Linux 면 docker, macOS 면 Apple `container`(microVM 백엔드가 이미 요구한다) 또는 docker 다. 빌드 스크립트는 호스트에서 `probe-commit.sh --print-env` 로 신원을 계산해 컨테이너에 넘긴다. 신원을 계산하는 코드는 하나다.
- 설치 전 확인: 방금 빌드한 서버 바이너리가 shim 파일의 선언을 읽어 자기 신원과 비교한다(`masc microvm-shim-check <path>` 같은 하위 명령). 다르면 설치하지 않고 실패한다. 파일 이름이나 sidecar 가 아니라 바이트의 신원을 본다.
- 릴리즈 설치: `install.sh` 는 서버 tarball 과 같은 태그의 shim 자산을 받는다. 설치 뒤 같은 하위 명령으로 확인한다.
- 지우는 것: `install-local-build.sh --refresh-guest-shim`(다른 빌드의 릴리즈 자산을 받는다), sha256 sidecar 와 `Shim_verified`/`Shim_unverified` 구분(신원이 대신한다), `build-shim-static.sh`(같은 일을 하는 두 번째 빌드 경로. SSH fixture 는 `build-shim.sh` 를 쓴다).

### 3.4 원격 SSH 엔드포인트 (D4)

- probe 응답에 `source_identity` 를 싣는다. `Shim_build_id`(release, suffix)와 `remote_shim_outdated` WARN 은 지운다.
- 서버는 첫 dispatch 전 probe 에서 신원을 비교한다. 다르면:
  - 엔드포인트가 bootstrap 때 root 또는 `sudo -n` 으로 shim 을 설치했으면(bootstrap 이 이미 판정한다), 서버가 같은 고정 SSH 채널로 자기 shim 을 올린다. bootstrap 의 `install_shim` 을 lib 로 옮겨 둘이 같은 코드를 쓴다. 올린 뒤 probe 를 다시 해서 신원이 같아야 dispatch 한다.
  - 권한이 없거나 엔드포인트 arch 의 shim 을 서버가 갖고 있지 않으면 `Remote_shim_other_source` 로 거절한다. 문구는 `masc-exec-ssh-bootstrap --endpoint <name>` 한 줄이다.
- 서버가 올릴 shim 은 §3.3 의 설치가 `<base>/.masc/shim/<arch>/masc-exec-shim` 에 둔 파일이다. 서버는 쓰기 전에 그 파일의 신원을 다시 읽는다.
- `Docker_exec` 전송은 다른 사람이 띄운 컨테이너라서 서버가 올리지 않는다. typed 거절만 한다.

### 3.5 CI·릴리즈 불변식

- 테스트: dune 이 이 소스로 빌드한 `masc_exec_shim.exe` 바이트의 선언이 테스트 바이너리의 `Source_identity.current` 와 같다(L1).
- `probe-shim-artifact.py` 는 shim 바이트에서 선언을 정확히 하나 찾고, 그 commit 이 `--source-commit` 과 같고 state 가 `clean` 인지 본다.
- 릴리즈 워크플로는 runtime tarball 의 `masc` 바이너리와 두 shim 자산의 선언이 모두 같은지 보고, 다르면 게시하지 않는다.

## 4. 왜 닫히나

| 어긋나는 길 | 닫는 곳 |
|---|---|
| 소스 서버 + 릴리즈 shim (이번 사건) | 신원이 다르다 → 부팅 전 거절, 설치도 거절(L2) |
| 같은 HEAD, 고친 내용이 다른 두 빌드 | `state` 가 다르다 |
| 옛 바이트로 떠 있는 agent | hello 신원이 다르다 → 디스크 shim 이 맞을 때만 교체 |
| 선언 없는 shim (≤0.73.1 전부) | `Undeclared` → 거절 |
| 신원 없는 서버 빌드 | `server = None` → 모든 shim 거절 |
| 원격 엔드포인트가 옛 shim | probe 신원 비교 → 서버가 올리거나 거절(L3) |
| 릴리즈가 다른 commit 의 shim 을 실음 | 릴리즈 워크플로 비교(L4) |

## 5. 대안

### A. relay 버전만 확인 (#52973)

- 장점: 변경이 작다. 소스 빌드끼리는 commit 이 달라도 relay 가 같으면 붙는다.
- 단점: 사람이 숫자를 올려야 한다. 이번 사건 전에도 숫자는 올라갔지만 shim 공급 경로가 따라오지 못했다. shim 동작이 바뀌어도 relay 가 같으면 못 막는다.

### B. 규약 범위 협상

- 장점: 서버와 shim 을 따로 올릴 수 있다.
- 단점: 따로 올릴 이유가 없다. microVM shim 은 서버 호스트 디렉터리에서 마운트된다. 원격 엔드포인트도 서버가 이미 쓰는 SSH 채널로 올릴 수 있다. 범위를 두면 지원 범위의 모든 짝을 시험해야 한다. 지금 그 시험은 없다.

### C. 버전 문자열로 계속 받기

- 장점: 지금 그대로다.
- 단점: 이번 사건의 원인 그 자체다. 소스 빌드 서버의 버전 문자열은 그 소스를 가리키지 않는다.

### D. commit 만 열쇠로

- 장점: 가장 단순하다.
- 단점: 고친 내용이 다른 같은 HEAD 빌드를 같다고 본다. `state` 하나로 막을 수 있어 고르지 않는다.

### E. shim 소스 파일 해시를 열쇠로

- 장점: 관련 없는 commit 에 shim 을 다시 빌드하지 않아도 된다.
- 단점: 해시할 파일 목록을 손으로 관리해야 한다(`build-shim-static.sh` 의 목록이 한 번 어긋났다). 서버 쪽 relay 클라이언트 코드는 목록에 없다. 다시 빌드 비용은 L2 가 자동으로 치르므로 얻는 것이 작다.

## 6. 하드컷

| 무엇 | 언제 | 운영자가 하는 일 |
|---|---|---|
| 선언 없는 shim(0.73.1 이하 릴리즈 자산, L1 전 checkout 빌드) 전부 | L1 | L2 전: `scripts/remote-ssh/build-shim.sh --arch arm64` 결과를 `<base>/.masc/microvm/shim/masc-exec-shim` 에 넣고 `.sha256` 을 지운다. L2 뒤: `install-local-build.sh` 가 한다 |
| 옛 shim 으로 떠 있는 게스트 | L1 | 없음. 디스크 shim 이 맞으면 다음 턴에 교체된다 |
| `MASC_BUILD_COMMIT` 만 넘기는 빌드(`Dockerfile.oneclick`, `docker-compose.yml`) | L1 | `MASC_BUILD_SOURCE_STATE` 도 넘긴다. 안 넘기면 그 서버는 shim 을 하나도 쓰지 않는다 |
| hello 거절 `Other_relay_version` | L1 | 없음 |
| `--refresh-guest-shim`, sha256 sidecar | L2 | `<base>/.masc/microvm/shim/masc-exec-shim.sha256` 를 지운다 |
| `Shim_build_id`, `remote_shim_outdated`, 원격 `/usr/local/share/masc/exec-shim.version` | L3 | 엔드포인트의 version 파일은 지워도 되고 남아도 읽지 않는다 |
| `build-shim-static.sh` | L2 | 없음 |

## 7. 층

| 층 | 내용 | 수용 시험 |
|---|---|---|
| L1 | `Source_identity` 생성, shim hello·바이트 선언, `Other_source` 거절, readiness `Shim_from_other_source`, Boot 갈래 순서, `build-shim*.sh` 가 신원을 넘김 | (1) dune 빌드 shim 바이트의 선언 = `current`. (2) 선언 없는 shim·다른 commit·다른 state·선언 둘 → readiness 거절, 다시 설치하면 통과. (3) 다른 신원 hello → `Other_source`, 신원 없는 hello → `Other_source { agent = None }`. (4) 다른 신원 shim 이 마운트된 Apple 게스트를 두 턴 요청해도 stop·delete·run 0회. (5) 선언 문법: 접두어만, 종료 문자 없음, 대문자 hex, 길이 틀림은 선언이 아니다 |
| L2 | `install-local-build.sh` 가 같은 checkout 에서 shim 을 빌드·확인·설치. `install.sh` 가 같은 태그 자산을 신원으로 확인. `--refresh-guest-shim`·sidecar·`build-shim-static.sh` 삭제. `masc microvm-shim-check` 하위 명령 | (1) 하위 명령: 같은 신원 0, 다른 신원·선언 없음 0 이 아닌 종료. (2) 설치 스크립트 dry-run 이 서버와 shim 을 같은 checkout 에서 빌드하는 명령을 낸다. (3) 다른 신원 shim 이면 설치가 바이너리를 바꾸기 전에 멈춘다 |
| L3 | probe 에 신원, 서버의 원격 shim 올리기, `Remote_shim_other_source`, `Shim_build_id`·WARN 삭제 | (1) SSH fixture 에서 다른 신원 shim 엔드포인트 → 서버가 올린 뒤 probe 신원 같음 → dispatch. (2) 권한 없는 엔드포인트 → 거절, 요청 0. (3) `Docker_exec` → 거절 |
| L4 | `probe-shim-artifact.py` 선언 확인, 릴리즈 워크플로 신원 비교 | (1) 다른 commit 으로 빌드한 shim 을 넣으면 probe 가 실패. (2) 릴리즈 dry-run 이 runtime 과 shim 선언이 다르면 실패 |

- L1 만으로 이번 사건은 「보이지 않는 실패」에서 「무엇을 다시 설치할지 말하는 typed 거절」로 바뀐다. 다시는 어긋난 짝이 돌지 않는다. 어긋난 짝이 생기지 않게 하는 것은 L2·L3 이다.
- 화면에 보이게 하는 일(#52971)은 이 RFC 밖이다. L1 의 typed 거절이 그 투영의 producer 가 된다.

## 8. #52973 과의 관계

- #52973 의 Boot 갈래 순서와 `Guest_shim_unready` 는 L1 에 그대로 들어간다. relay 선언과 `relay_declaration` 은 신원 선언으로 바뀐다.
- 권고: L1 이 리뷰를 통과하면 #52973 은 L1 에 흡수된 것으로 닫는다. L1 전에 운영 복구가 급하면 #52973 을 먼저 병합하고, L1 을 그 위로 다시 올려 relay 선언을 지운다.

## 9. 검증

- 로컬 전체 빌드는 하지 않는다. 층마다 바꾼 테스트 실행 파일만 CI `test.yml` 로 돌린다.
- L1 대상: `test_source_identity`, `test_exec_ssh_protocol`, `test_keeper_guest_socket`, `test_keeper_microvm_shim_readiness`, `test_keeper_sandbox_microvm`, `test_shim_agent`(Linux).
- 운영 확인(L1 배포 뒤): 서버 로그에 `microvm_shim_other_source` 가 한 번 나오고, shim 을 다시 넣은 뒤 `request_not_sent` 가 0 이다. 집계 창과 명령은 그때 기록한다.

## 10. 열린 질문

- Q1. macOS 소스 설치에서 shim 빌드 CLI 를 Apple `container` 로 할지 docker 로 할지. `container` 는 이미 필수라 추가 의존이 없다. docker 는 지금 스크립트가 쓴다. L2 에서 정한다.
- Q2. 원격 엔드포인트 자동 올리기를 기본으로 켤지, 엔드포인트 선언의 값으로 켤지. 이 RFC 는 bootstrap 이 판정한 권한이 있으면 켠다.
