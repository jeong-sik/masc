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
- **`microvm`** — 하이퍼바이저 경계 뒤에서 돌립니다. macOS 에서는 Apple 의
  `container` CLI 를 쓰므로 먼저 설치하세요.
- **`remote_ssh`** — `runtime.toml` 의 `[exec.ssh.endpoints]` 에 선언한 원격
  호스트에서 돌립니다. `remote_endpoint` 로 고릅니다.

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
