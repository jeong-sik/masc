---
title: Keeper 샌드박스 격리 런북
description: Docker 및 MicroVM을 활용하여 Keeper의 쉘 명령 실행을 안전하게 격리하는 방법
---

자율 에이전트가 임의의 쉘 명령어를 실행할 때 호스트 머신의 파괴적 변경을 방지하기 위해 MASC는 샌드박스(Sandbox) 실행 모드를 지원합니다.

## 격리 백엔드 (Isolation Backends)

MASC는 3가지 샌드박스 프로파일을 지원합니다 (호스트 직접 실행 프로파일은 지원되지 않으며, 프로파일이 없으면 Keeper 기동이 거부됩니다):

1. **Docker (`docker`)**: 로컬 Docker 데몬을 통해 전용 컨테이너 내부에서 격리 실행
2. **MicroVM (`microvm`)**: 하이퍼바이저 경계를 통한 격리 (macOS에서는 `microvm_backend = "apple_container"`)
3. **Remote SSH (`remote_ssh`)**: `runtime.toml`의 `[exec.ssh.endpoints]`에 등록된 원격 격리 호스트로 명령어 포워딩

---

## 설정 예시

`.masc/config/keepers/<keeper-name>.toml`에 샌드박스 프로파일을 지정합니다:

```toml
[keeper]
autoboot_enabled = true
sandbox_profile = "docker" # "docker" | "microvm" | "remote_ssh"
# microvm 사용 시 (macOS):
# microvm_backend = "apple_container"
# remote_ssh 사용 시:
# remote_endpoint = "worker-node-1"
```

---

## 동작 검증

TUI 상에서 Keeper가 `run_command` 도구를 호출할 때 `[sandbox:docker]` 배지가 표시되며, 컨테이너 내부 격리된 환경에서 명령이 안전하게 평가됩니다.
