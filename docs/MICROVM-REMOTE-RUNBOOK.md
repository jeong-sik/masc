# MicroVM Remote Lane Runbook

게스트가 자기 작업 트리를 가지는 구조(RFC-0400)의 운영 절차.

## 어느 런타임이 게스트를 주는가 (RFC-0405)

`sandbox_profile = "microvm"` 은 트리가 하이퍼바이저 뒤 게스트에 있다는 뜻이고,
그 게스트를 **누가 주는지는 keeper TOML 이 정한다.**

```toml
sandbox_profile = "microvm"
microvm_backend = "apple_container"   # | "microsandbox" | "nerdctl_kata"
```

| 값 | CLI | 어디서 |
|---|---|---|
| `apple_container` | `container` | macOS 26+ (기본값) |
| `microsandbox` | `msb` | macOS · Linux(KVM) · Windows(WHP) |
| `nerdctl_kata` | `nerdctl` + `--runtime io.containerd.kata.v2` | Linux (containerd) |

생략하면 macOS 는 `apple_container` 를 쓰고, **그 밖의 호스트는 부팅을 거절한다**
(`microvm_backend_unresolved`). 선언한 것과 다른 격리를 조용히 주지 않는다.

### 백엔드별 부팅과 작업 볼륨 계약

세 값 다 TOML 에서 통과하지만, 백엔드마다 작업 볼륨과 격리 플래그 지원이 다르다.

| 값 | 부팅 결과 | 작업 볼륨·격리 동작 |
|---|---|---|
| `apple_container` | 뜬다 | sparse ext4 작업 볼륨(`masc-keeper-work-<keeper>`)과 부팅마다 새로 만드는 빌드 볼륨(`masc-keeper-build-<keeper>`)을 붙인다. Keeper 해산 시 소유권을 확인할 수 없으면 볼륨 자동 삭제를 건너뛴다 |
| `nerdctl_kata` | 뜬다 (`network_mode = "none"` 또는 `"inherit"`) | `nerdctl volume create` + `inspect` 로 호스트 관리형 디렉터리 볼륨을 확인해 붙인다 (`capacity_enforced=false; host filesystem capacity applies`). `network_mode = "policy"` 는 지원하지 않는다 |
| `microsandbox` | `microvm_constraint_unexpressible` | 작업 볼륨(`msb volume create --kind dir`)은 준비되지만, `msb 0.6.16` 에 `--cap-drop` 과 `--read-only` 가 없어 프로필이 요구하는 격리 플래그를 줄 수 없으므로 부팅을 거절한다 |

현재 볼륨 이름에는 작업 공간이 포함되지 않는다. 같은 런타임 저장소에서 서로
다른 작업 공간의 Keeper가 같은 이름을 쓰면 같은 작업 볼륨을 재사용할 수 있다.
Apple 빌드 볼륨은 새 게스트 부팅 때 재생성되므로 같은 이름을 공유하는 구성을
피해야 한다. 실행 중인 게스트 목록이 비어 있어도 중지된 Keeper의 소유권을 알 수
없다. Apple 볼륨 자동 정리는 소유권 확인 기능이 생길 때까지 건너뛰며, 남은 볼륨은
디스크를 차지할 수 있다.

이 표는 **이미지가 그 런타임 저장소에 있을 때** 나오는 답이다. 부팅은
이미지 확인 → 작업 볼륨 → 부팅 argv 순서로 가기 때문에, 이미지가 없으면 위
문구 대신 `microvm_image_missing` 이 먼저 나온다. `msb` 는 `msb image list
--format json`, `nerdctl` 은 `nerdctl images` 로 각자 저장소를 확인한다.
런타임마다 이미지 저장소가 따로라서, Docker 로 빌드해 둔 이미지는 셋 중
어디에도 보이지 않는다.

`network_mode = "inherit"` 인 게스트에서 호스트 `/etc/resolv.conf` 가 루프백(`127.0.0.1`, `::1`), 링크 로컬, 미지정 주소만 담고 있으면 게스트 안에서 DNS 해석이 실패하므로 부팅을 거절한다. 이 경우 `runtime.toml` 의 `[sandbox] microvm_dns` 또는 환경변수 `MASC_KEEPER_MICROVM_DNS` 에 게스트에서 도달 가능한 업스트림 DNS 서버 목록을 지정한다 (#43254).

전에는 셋 다 Apple `container` 로 떴기 때문에 `microsandbox` 라고 적은 keeper 의
게스트를 `msb stop` 으로 내리려 하면 `sandbox not found` 가 났고, 실제로 떠 있는
게스트는 아무도 못 치웠다. 지금은 부팅이 선언된 런타임을 그대로 따라가고, 조건을
만족하지 못하면 부팅을 거절한다.

이 문서의 나머지는 `apple_container` 기준이다 — `container` 자리에 그 백엔드의
CLI 를 놓고 읽으면 된다. 아래 계약 표의 항목 1·2 는 백엔드마다 다르고, 3·4(shim
과 작업 볼륨)는 공통이다.

---

아래는 Apple `container` 게스트 기준의 운영
절차. 게스트는 호스트 playground 를 마운트하지 않는다. 트리는 게스트마다
하나씩 있는 ext4 볼륨(`/masc-work`)에 있고, 명령은 호스트가 게스트 안의
`masc-exec-shim` 에 `container exec` 로 넣어 준다. OpenSSH 엔드포인트와 같은
프로토콜, 다른 전송이다.

## 계약: 호스트에 필요한 것

| # | 항목 | 없으면 |
|---|------|--------|
| 1 | `container` CLI 1.3+ 와 실행 중인 container system | `microvm_cli_unavailable` / `microvm_image_probe_failed` |
| 2 | Keeper 의 `sandbox_image` 이름에 이미지 목록(`<base-path>/.masc/config/sandbox-image-builds.toml`)이 `apple_container` 빌드를 올려 두었고, 그 태그가 container 이미지 저장소에 있음 (`container image inspect <목록의 reference>`) | 목록에 없으면 `sandbox_image_unresolved`, 저장소에 없으면 `microvm_image_missing` |
| 3 | 정적 arm64 shim: `<base>/.masc/microvm/shim/masc-exec-shim` (실행 권한). 옆의 `masc-exec-shim.sha256` 은 설치기가 쓴 릴리즈 해시이며, 있으면 부팅이 바이너리와 맞춰 본다 | `microvm_shim_missing` — 부팅 거부. 해시가 다르면 `microvm_shim_hash_mismatch` — 부팅 거부 |
| 4 | 디스크 여유. 볼륨 상한은 `MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE` (기본 256g, sparse) | `microvm_work_volume_create_failed` |

shim 설정(`masc-exec-shim.conf`)은 서버가 부팅마다 같은 디렉터리에 다시
쓴다. 내용은 `remote_root=/masc-work`, `path=<이미지의 PATH>`
(`MASC_KEEPER_MICROVM_PAYLOAD_PATH`), `env_allowlist=MASC_BASE_PATH,
MASC_CONFIG_DIR`. 손으로 고칠 것이 없다. `scratch_root=` 는
쓰지 않는다. shim 은 그 줄이 없으면 `/tmp` 를 쓰고, 부팅은 거기에 tmpfs 를 올린다.
한 상수를 양쪽이 같이 읽는다.
서버와 shim 은 따로 배포되므로 한 버전 차이는 서로 참는다. 서버는 첫 실행 전에
shim 을 `--probe` 해서 그 shim 이 말하는 프로토콜 major(v2 또는 v3)로 프레임을
보내고, shim 은 받은 major 로 답한다. 그래서 서버만 먼저 올려도, shim 만 먼저
바꿔도 tool_execute 는 끊기지 않는다. 다만 v2 shim 은 관측 상자(RFC-0422)를
만들 수 없어서 그 요청들은 예전처럼 judge 로 간다. shim 은 모르는 설정 키를
거부하므로, 서버는 모든 shim 이 아는 키만 설정에 쓴다. 두 major 밖의 shim 만
`remote_shim_version_skew` 로 거부된다.

shim 이 서버와 다른 릴리즈에서 나온 것이면 서버는 `remote_shim_outdated` WARN 을
남기고 계속 돈다. 그 줄에는 이 호스트에서 바꿀 파일 경로가 적혀 있다
(`<base>/.masc/microvm/shim/masc-exec-shim` 과 옆의 `.sha256`). 바꾸는 방법은 아래
"shim 받기"다. SSH 엔드포인트용 `masc-exec-ssh-bootstrap` 은 게스트에 쓰지 않는다.
게스트는 이 디렉터리를 마운트로 읽고 서버는 요청마다 shim 을 새로 실행하므로
(`Keeper_sandbox_remote.transport_argv`), 켜져 있는 게스트도 다음 요청부터 새 shim 을
쓴다. 2026-10-13 에 0.49.0 을 0.52.0 으로 바꿨을 때 재시작 없이 게스트 18개가 새
릴리즈로 답했다(#42726). 다만 서버는 probe 답을 프로세스가 사는 동안 들고 있고
게스트는 다시 probe 하지 않는다. 그래서 `keeper_lane_status` 의 `shim_release` 와 이
WARN 은 서버를 다시 띄운 뒤에야 새 shim 을 반영한다.

바이너리와 `.sha256` 은 파일 두 개라, 하나만 바뀐 순간에 부팅하는 게스트는
`microvm_shim_hash_mismatch` 로 한 번 거절된다. 둘 다 같은 디렉터리의 임시 이름으로
받아 놓고 `mv` 두 번으로 바꾸면 그 순간이 가장 짧다.

게스트가 마운트하는 것: 설정 디렉터리(읽기 전용, `/tmp/masc-runtime/.masc/config`),
GitHub identity 스냅샷, 작업 볼륨(`masc-keeper-work-<keeper>` →
`/masc-work`), shim 디렉터리(읽기 전용, `/opt/masc-exec-shim`), 그리고
메모리 파일시스템 `/tmp`(`--tmpfs /tmp`). 마지막 것은 RFC-0422 의 관측 상자가
쓰는 스크래치 자리다. 루트는 읽기 전용이라 이게 없으면 상자 안의 명령은 아무
데도 쓸 수 없다. 크기는 커널 기본값(게스트 메모리의 절반, 기본 게스트에서
551M 실측)이고 게스트가 내려가면 사라진다. 그게 전부다.

## shim 받기

shim 은 서버 릴리즈의 자산이고(RFC-0427 B-1), 설치기가 놓는다(B-2). 릴리즈마다
`masc-exec-shim-linux-arm64` 와 `masc-exec-shim-linux-amd64` 가 서버 바이너리
옆에 올라오고, 릴리즈 워크플로가 같은 아키텍처의 러너에서 정적으로 빌드해
`--probe` 까지 확인한 것이다. 게스트는 arm64 다.

`scripts/install.sh` 가 서버 바이너리와 같은 태그의 shim 을
`<base>/.masc/microvm/shim/masc-exec-shim` 에 놓고, 옆에 릴리즈 `SHA256SUMS` 의
해시를 `masc-exec-shim.sha256` 으로 남긴다. 부팅은 그 두 파일을 맞춰 보고,
다르면 `microvm_shim_hash_mismatch` 로 거절한다. 따로 할 일은 없다. microvm
keeper 를 돌리지 않는 호스트는 `--no-guest-shim` 으로 건너뛴다.

로컬 빌드로 배포할 때는 `scripts/install-local-build.sh` 가 이미 있는 릴리즈 shim 을
맞춘다. 새로 놓지는 않는다. workspace 에 바이너리와 sidecar 가 둘 다 있으면, 빌드한
서버가 말하는 버전의 릴리즈에서 같은 자산을 받아 `SHA256SUMS` 와 맞춰 보고 두 파일을
바꾼다. 어느 자산(arm64, amd64)인지는 sidecar 에 적힌 이름에서 읽는다. `--no-guest-shim`
을 주면 이 단계를 건너뛴다.

| 경우 | 하는 일 |
|---|---|
| shim 이 없다 | 아무것도 안 한다 |
| shim 이 이미 그 릴리즈의 것 | 받지 않는다 |
| sidecar 가 없다 (손으로 빌드한 shim) | 건드리지 않는다 |
| sidecar 에 릴리즈 자산 이름이 없다 | shim 을 그대로 두고 WARN 한 줄, 설치는 계속 |
| 릴리즈를 읽을 수 없거나, 릴리즈에 그 자산이 없다 | shim 을 그대로 두고 WARN 한 줄(curl 이 말한 이유 포함), 설치는 계속. 다음 설치 때 다시 받는다 |
| 받은 자산이 `SHA256SUMS` 와 다르다 | 아무것도 설치하지 않고 멈춘다 |

켜져 있는 게스트는 다음 요청부터 새 shim 을 쓴다. 서버는 옛 shim 이 probe 에 답한
릴리즈와 기능 목록을 다시 띄울 때까지 들고 있다.

설치기 없이 자산만 바꿔 넣을 때는 sidecar 도 같이 바꾼다. 안 바꾸면 다음 부팅이
옛 해시와 새 바이너리를 보고 거절한다.

서버가 shim 을 찾는 자리는 `<base path>/.masc/microvm/shim` 이다
(`Config_dir_resolver.microvm_shim_dir`). 아래 명령은 그 경로를 `MASC_BASE_PATH`
에서 만든다 — 서버를 띄울 때 쓰는 값과 같아야 하고, 다르면 shim 을 깔아도 서버가
못 찾는다.

```bash
shim_dir="${MASC_BASE_PATH:?set it to the same base path the server runs with}/.masc/microvm/shim"

# 서버와 같은 태그의 자산을 받는다
gh release download vX.Y.Z -R jeong-sik/masc -p masc-exec-shim-linux-arm64 -p SHA256SUMS -D /tmp/shim
mkdir -p "$shim_dir"
install -m 755 /tmp/shim/masc-exec-shim-linux-arm64 "$shim_dir/masc-exec-shim"
grep ' masc-exec-shim-linux-arm64$' /tmp/shim/SHA256SUMS > "$shim_dir/masc-exec-shim.sha256"
```

서버와 shim 은 한 major 차이를 서로 참으므로(위 계약 표 아래 문단) 순서는 상관없다.
릴리즈 없이 지금 트리로 만들어야 할 때만 아래처럼 직접 빌드한다. 손으로 빌드한
shim 에는 sidecar 가 없어야 한다. 없으면 부팅이 검증 없이 돌리고 로그에 그렇게
적는다.

```bash
# Docker 가 있으면
scripts/remote-ssh/build-shim.sh --arch arm64
# 결과 dist/remote-ssh/masc-exec-shim-linux-arm64 를 설치
shim_dir="${MASC_BASE_PATH:?set it to the same base path the server runs with}/.masc/microvm/shim"
mkdir -p "$shim_dir"
cp dist/remote-ssh/masc-exec-shim-linux-arm64 "$shim_dir/masc-exec-shim"
chmod +x "$shim_dir/masc-exec-shim"
rm -f "$shim_dir/masc-exec-shim.sha256"
```

Docker 없이 Apple container 로 빌드할 때: 빌드 컨테이너에 `--dns` 를
줘야 opam 이 패키지를 받고, `/out` 바인드 마운트는 게스트 안에서 root
소유라 호스트 쪽에서 `chmod 777` 을 먼저 한다. opam 버전 핀은 이미지의
스위치와 어긋나 실패(exit 40)하므로 핀 없이 설치한다.

## 전환 절차 (공유 마운트 → 볼륨)

공유 마운트로 돌던 게스트에서 커밋 안 된 작업이 있는 keeper 는, 새 서버로
재시작하기 전에 트리를 볼륨으로 복사한다. 옛 게스트는 둘 다
마운트하고 있으므로 게스트 안에서 `cp` 하면 된다.

```bash
# 1. 옛 게스트 이름 확인
container list --format json | jq -r '.[].configuration.id' | grep masc-keeper-vm

# 2. keeper 마다 트리 복사 (게스트 안). uid 는 서버 프로세스의 것 — 서버는
#    Unix.getuid 로 게스트에 들어가므로 `id -u` 값(이 맥에서는 502)을 쓴다.
#    다른 uid 로 복사하면 그 디렉터리에 서버가 못 쓴다(mktemp: Permission denied).
#    옛 게스트에는 keeper root 가 없을 수 있어 root 로 먼저 만든다.
U=$(id -u)
container exec --user 0:0 masc-keeper-vm-<keeper>-<hash> \
  sh -c 'mkdir -p -m 0777 /masc-work/<keeper>'
container exec --user $U:20 masc-keeper-vm-<keeper>-<hash> \
  sh -c 'cp -a /home/keeper/playground/<keeper>/. /masc-work/<keeper>/'

# 3. 옛 _build 심볼릭 링크 제거 (볼륨에 실제 _build 를 dune 이 만든다)
container exec --user $U:20 masc-keeper-vm-<keeper>-<hash> \
  sh -c 'find /masc-work/<keeper> -maxdepth 4 -name _build -type l -delete'

# 3b. 게스트가 이미 없으면 호스트 디렉터리와 볼륨을 같이 붙인 일회용 컨테이너로
container run --rm --user 0:0 \
  -v "$MASC_BASE_PATH/.masc/playground/microvm/<keeper>":/src:ro -v masc-keeper-work-<keeper>:/masc-work \
  <Keeper 이미지의 reference> sh -c "mkdir -p -m 0777 /masc-work/<keeper> \
    && cp -a /src/. /masc-work/<keeper>/ && chown -R $U:20 /masc-work/<keeper>"

# 3c. 옮긴 뒤 검증은 서버와 같은 uid 로 실제 쓰기를 해 본다
container exec --user $U:20 masc-keeper-vm-<keeper>-<hash> \
  sh -c 't=$(mktemp /masc-work/<keeper>/.probe.XXXXXX) && unlink "$t" && echo ok'

# 4. 서버 재시작. 게스트는 공유 마운트 없이 다시 뜬다.

# 5. 기존 빌드 볼륨은 자동으로 일괄 삭제하지 않는다.
#    같은 이름의 Keeper가 다른 작업 공간에서 쓰고 있을 수 있다.
```

호스트의 `.masc/playground/microvm/<keeper>/` 는 더 이상 읽히지 않는다.
복사가 확인되면 지운다. 서버는 이후 `.masc/playground/<keeper>/` 를
장부(telemetry, workspace view)로만 쓴다.

## 확인

```bash
# 게스트가 공유 마운트 없이 떴는지
container exec masc-keeper-vm-<keeper>-<hash> sh -c 'mount | grep -E "masc-work|playground"'
#  → /masc-work 만 보이고 playground 는 없어야 한다

# shim 이 답하는지
container exec --env MASC_EXEC_SHIM_CONFIG=/opt/masc-exec-shim/masc-exec-shim.conf \
  masc-keeper-vm-<keeper>-<hash> /opt/masc-exec-shim/masc-exec-shim --probe

# 호스트 fd 가 파일 수를 따라가지 않는지 (게스트 VM 프로세스)
lsof -p <vm pid> | wc -l     # 활동 중에도 100 안쪽
```

## 못 하는 것

- 게스트 안에서 파일로 리다이렉트(`cmd > file`)는 거절된다. OpenSSH
  엔드포인트와 같다. Write 도구로 쓴다.
- `spawn` 은 게스트를 넘지 않는다. Execute 로 실행한다.
- 파이프라인은 stage 마다 한 연결로 돈다. 호스트 쪽 파이프로 잇지 않는다.
