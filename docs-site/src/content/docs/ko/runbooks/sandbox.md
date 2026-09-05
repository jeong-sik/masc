---
title: 명령어 안전 격리
description: Keeper 의 도구 명령을 Docker · microVM · 원격 SSH 로 격리합니다.
---

Keeper 의 셸 명령은 여러분 기기가 아니라 격리된 공간에서 돕니다. host 프로필은
없습니다. 허용된 `sandbox_profile` 없이 선언된 Keeper 는 부팅에서 거부되므로, 하나를
고르기 전에는 Keeper 를 띄울 수 없습니다.

## 격리 방식

- **`docker`** — Keeper 의 도구를 컨테이너 안에서 돌립니다. Docker 설치와 데몬 실행이
  필요합니다.
- **`microvm`** — 하이퍼바이저 경계 뒤에서 돌립니다. 빠져나가려면 공유 커널이
  아니라 하이퍼바이저를 넘어야 합니다. 이 방식을 말하는 런타임이 셋 있습니다.
  아래를 보세요.
- **`remote_ssh`** — `runtime.toml` 의 `[exec.ssh.endpoints]` 에 선언한 원격
  호스트에서 돌립니다. `remote_endpoint` 로 고릅니다.

## microVM 런타임 고르기

`microvm` 은 프로그램 이름이 아니라 방식입니다. MASC 는 셋 중 하나를 몹니다.

| 백엔드 | 프로그램 | 어디에 맞나 |
| --- | --- | --- |
| `apple_container` | Apple 의 `container` CLI | macOS 26+. 지금 `network_mode = "policy"` 를 지원하는 유일한 백엔드입니다. |
| `microsandbox` | `msb` | Linux 와 macOS. 게스트 사용자를 uid:gid 숫자가 아니라 이름으로 받고, 작업 볼륨이 디렉터리 종류입니다. |
| `nerdctl_kata` | Kata 런타임을 쓰는 `nerdctl` | Kata 컨테이너를 이미 쓰고 있는 Linux. |

macOS 기본값은 `apple_container` 입니다. `/System/Library/CoreServices/SystemVersion.plist`
가 있는지로 정합니다. **Linux 에는 기본값이 없습니다** — 백엔드를 직접 적지 않으면
Keeper 가 띄울 microVM 런타임이 없습니다.

## 샌드박스 이미지

MASC 는 이미지를 같이 배송하지 않습니다. 범용 이미지를 한 번 만듭니다.

```bash
masc sandbox-image
```

`masc-sandbox:general` 은 Debian slim 에 `bash`(턴이 `bash -l -s` 로 돕니다),
`ripgrep`(Grep 도구가 `rg` 없이는 거부합니다), `git`, `curl`, `ca-certificates`,
`less`, `procps`, `findutils` 를 담습니다. 그 이상은 가정하지 않습니다. 프로젝트의
툴체인은 그 프로젝트 이미지에 있어야 하고, Keeper 마다 `sandbox_image` 로 가리킵니다.

레시피는 바이너리 안에 있고 빌드 컨텍스트 없이 `docker build -` 로 넘어갑니다. 그래서
저장소를 받아본 적 없는 기계에서도 똑같이 만들어집니다. `masc sandbox-image --print`
는 빌드 대신 Dockerfile 을 표준출력으로 내보냅니다. `MASC_KEEPER_SANDBOX_DOCKER_IMAGE`
로 기본 태그를 바꾸면 `docker` 와 `microvm` 양쪽 게스트 경로가 같이 따릅니다.

## 설정

`masc keeper-create` 가 이 값들을 대신 써 줍니다(`--sandbox-profile` 과 필수 항목인
`--network-mode`). 만들어지는 `<base-path>/.masc/config/keepers/<name>.toml` 모양은
이렇습니다.

```toml
sandbox_profile = "docker"   # "docker" | "microvm" | "remote_ssh"
network_mode = "none"        # "none" | "inherit" | "policy"

# sandbox_profile = "remote_ssh" 일 때만:
# remote_endpoint = "worker-node-1"
```

`network_mode` 는 프로필과 별개이고 필수입니다. `none` 은 게스트에 네트워크를 전혀
주지 않습니다 — 웹 검색이나 `git push` 를 하는 Keeper 는 `inherit` 가 필요합니다.
`policy` 는 그 중간으로, 이 서버가 소유한 허용 목록 프록시에만 닿을 수 있습니다
(지금 이 모드를 실제로 지원하는 백엔드는 `apple_container` 마이크로VM뿐입니다).
`docker` 와 `microvm` 의 기본값은 `none` 이라, `masc keeper-create` 는 대신 정하지
않고 이 값을 안 주면 진행을 거부합니다.

---

## TUI에서 실시간 격리 백엔드 전환

실행 중인 TUI(`masc-tui`) 내에서 TOML 설정을 직접 편집하지 않고 키보드 단축키로 샌드박스 백엔드를 즉시 전환할 수 있습니다:

1. `Tab` 키로 **Keepers** 화면으로 이동합니다.
2. 목록에서 대상 Keeper를 선택하고 `Enter`를 눌러 **상세 뷰**로 진입합니다.
3. `[` / `]` 키로 **`Sandbox`** 탭을 선택합니다.
4. 다음 단축키를 눌러 원하는 격리 환경으로 즉각 재구성합니다:
   - **`d`**: **Docker** 컨테이너 격리로 전환
   - **`m`**: **MicroVM** 하이퍼바이저 격리로 전환
   - **`s`**: **Remote SSH** 원격 워커 격리로 전환

전환 명령은 서버에 즉시 전송 및 검증되며, 화면의 Sandbox 상태가 실시간으로 갱신됩니다.
