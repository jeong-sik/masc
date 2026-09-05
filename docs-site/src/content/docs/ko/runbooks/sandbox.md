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
network_mode = "none"        # "none" | "inherit"

# sandbox_profile = "remote_ssh" 일 때만:
# remote_endpoint = "worker-node-1"
```

`network_mode` 는 프로필과 별개이고 필수입니다. `none` 은 게스트에 네트워크를 전혀
주지 않습니다 — 웹 검색이나 `git push` 를 하는 Keeper 는 `inherit` 가 필요합니다.
`docker` 와 `microvm` 의 기본값은 `none` 이라, `masc keeper-create` 는 대신 정하지
않고 이 값을 안 주면 진행을 거부합니다.
