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

MASC 는 이미지를 같이 배송하지 않습니다. Keeper 는 `sandbox_image` 에 이미지
이름을 적습니다. 이름은 바이너리에 든 `config/sandbox-images.toml` 에 있는 것이어야
합니다. 아무것도 빌드하지 않는 Keeper 는 `base`, MASC 를 빌드하는 Keeper 는
`ocaml` 입니다. 이 호스트의 빌드 목록
`<base-path>/.masc/config/sandbox-image-builds.toml` 은
이미지 저장소(Docker, 또는 microVM 런타임마다 따로 있는 저장소)별로 각 이름이 이
호스트에서 어떤 빌드인지 적어 둡니다. `masc setup` 은 설정하는 저장소에 `base`
빌드가 목록에 없으면 빌드해서 목록에 올립니다(promote).

손으로 할 때는 이렇게 합니다.

```bash
masc sandbox-image                          # base 를 빌드하고 masc-sandbox-base:<UTC 분>-<입력 해시> 를 출력
masc sandbox-image promote base <그 태그>    # base Keeper 의 다음 턴부터 이 빌드로 뜸
masc sandbox-image rollback base            # 바로 전 빌드로 되돌림
```

다른 레시피는 저장소 체크아웃에서 읽습니다.
`masc sandbox-image --recipe ocaml --source <checkout>` 입니다. microVM 런타임의
저장소를 쓰려면 명령마다 `--runtime <backend>` 를 붙입니다. 이미 저장소에 있는 태그는
거절하므로, 한 태그 아래에서 빌드가 바뀌는 일은 없습니다.

목록에 없는 이름을 적었거나, 이름은 있는데 그 저장소에 promote 된 빌드가 없는
Keeper 는 컨테이너를 띄우지 않습니다. 거절 메시지에 위 명령이 함께 나옵니다. 턴은
처음 컨테이너가 필요할 때 이름을 한 번 찾습니다. 그래서 promote 는 다음 턴부터
닿고, 한 턴이 두 빌드로 갈리지 않습니다.

`base` 에 무엇이 들었는지는 `sandbox-images/base/Dockerfile` 에 있습니다.
바이너리가 이 레시피를 품고 있고, 빌드 컨텍스트 없이 `docker build -` 로 넘깁니다.
그래서 저장소를 받아본 적 없는 기계에서도 똑같이 만들어집니다.

**microVM 키퍼는 Docker 스토어를 보지 않습니다.** 런타임마다 자기 이미지 스토어가
따로라, 위 명령으로 만든 이미지는 microVM 게이트에 안 보입니다. 그 스토어에 만들려면
런타임을 지목합니다.

```bash
masc sandbox-image --runtime apple_container
```

`apple_container` 는 `container build` 가 `-` 를 안 받고 컨텍스트 디렉터리를 받으므로
레시피를 임시 디렉터리에 파일로 써서 `-f` 로 지목합니다. `nerdctl` 은 Docker 문법이라
같은 stdin 경로를 씁니다. `microsandbox`(`msb`)는 `build` 자체가 없어서 — `pull`,
`load`, `save` 뿐입니다 — 다른 데서 만들어 OCI 아카이브로 `msb load` 해야 하고,
이 명령이 그렇게 알려줍니다. `masc sandbox-image --print`
는 빌드 대신 Dockerfile 을 표준출력으로 내보냅니다.

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
