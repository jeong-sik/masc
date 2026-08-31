# Remote SSH Endpoint Runbook

어느 벤더의 리눅스 머신이든(Vultr / AWS / Azure / GCP / 사설 박스) masc
remote_ssh 엔드포인트로 붙이는 절차. 서버 preflight(`perform_preflight`,
`lib/keeper/keeper_sandbox_ssh.ml`)가 강제하는 계약을 그대로 따른다.
task-859에서 실측으로 확정했다.

## 계약: 원격 머신에 필요한 6가지

| # | 항목 | preflight 에러 코드 |
|---|------|---------------------|
| 1 | `masc-exec-shim`이 PATH에 (정적 바이너리) | `remote_ssh_probe_*` |
| 2 | `/etc/masc-exec-shim.conf`에 `remote_root=<절대경로>` | `remote_ssh_shim_config_error` (exec 시점) |
| 3 | `<remote_root>/<keeper>/` 디렉터리 (keeper마다, 자동 생성 안 됨) | `remote_ssh_keeper_root_missing` |
| 4 | `<remote_root>/<keeper>/.config/gh`에 GitHub identity | `remote_github_identity_missing` |
| 5 | `git` 설치 (`gh`도 — 4번 검증에 필요) | `remote_git_unavailable` |
| 6 | `ripgrep` 설치 (`Grep`이 원격에서 `rg` 실행) | `remote_ripgrep_unavailable` |

서버 쪽 절반: 엔드포인트 키(`.masc/ssh/<name>.key`), 핀된 호스트 키
(`.masc/ssh/known_hosts.d/<name>`), `runtime.toml`의
`[exec.ssh.endpoints.<name>]` 블록(host/user/remote_root 필수, port 기본 22).
엔드포인트 블록은 디스패치 때마다 다시 파싱되므로 서버 재시작이 필요 없다.

## 절차

```bash
# 1. shim 빌드 (아키텍처별 1회, 결과는 dist/remote-ssh/)
scripts/remote-ssh/build-shim.sh                 # amd64 + arm64
scripts/remote-ssh/build-shim.sh --arch arm64    # 한쪽만

# 2. 머신 프로비저닝 + 검증 (벤더가 준 기존 ssh 접근으로 진입)
scripts/remote-ssh/bootstrap-endpoint.sh \
  --name build-box --host 203.0.113.7 --user masc \
  --host-key-sha256 SHA256:<vendor-console-fingerprint> \
  --keeper rondo --keeper sangsu

# 3. keeper 전환 (keeper TOML)
#    sandbox_profile = "remote_ssh"
#    remote_endpoint = "build-box"
```

bootstrap 스크립트는 마지막에 서버가 쓰는 것과 같은 연결 모양(엔드포인트
키 + BatchMode + 핀된 호스트 키)으로 전체 preflight 계약을 재현해
검증한다. 호스트 키 fingerprint는 벤더 콘솔이나 이미 신뢰한 채널에서
확인한 값을 필수로 받으며, `runtime.toml`은 직접 수정하지 않고 검토할
블록만 출력한다. 여기서 통과하면 서버 디스패치도 통과한다.

## 벤더별 유의점

- **아키텍처**: shim은 musl 정적 링크라 배포판을 가리지 않지만 CPU는
  가린다. x86_64 인스턴스(대부분의 저가 티어)는 amd64 바이너리,
  Graviton/Ampere는 arm64. bootstrap이 `uname -m`으로 자동 선택한다.
- **호스트 키 핀**: `StrictHostKeyChecking=yes` 강제라 인스턴스를
  재생성하면 `.masc/ssh/known_hosts.d/<name>`을 지우고 다시 핀해야 한다.
- **`remote_root` 경로**: #31523 배포 전의 서버는 mac 호스트에 존재하는
  프리픽스(`/home` 등)를 로컬 firmlink로 치환해 배송하는 결함이 있다.
  그 전까지는 `/opt/masc-playground`처럼 mac에 없는 경로를 쓴다.
- **Execute 안의 gh identity**: preflight 검증과 별개로, exec 프레임에
  `GH_CONFIG_DIR`를 실어주는 것은 #31525부터다. 그 전 서버에서는 원격
  명령이 identity-blind로 돈다.
- **격리 수위**: 한 엔드포인트의 모든 keeper가 같은 unix user로 들어간다.
  keeper 간 경계는 디렉터리 jail이지 OS 경계가 아니다 — 신뢰하는 플릿
  전용이고, 더 강한 격리가 필요하면 keeper별로 user를 나눠 엔드포인트를
  여러 개 등록한다.
- **동시성**: 엔드포인트의 `max_concurrent_sessions` 세마포어를 그
  엔드포인트를 쓰는 모든 keeper가 공유한다.

## 검증을 믿는 법

keeper의 자가 보고가 아니라 원장을 본다: 승인 영수증은
`gate/replay-results.json`의 `outcomes`, 실행 결과 본문은
`<base-path>/.masc/tool_blobs/<sha2>/<sha256>`. blob의 `via`/`remote_endpoint`
필드가 실제로 SSH 레인을 탔는지 말해준다.
