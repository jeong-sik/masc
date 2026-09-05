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

### 지금 실제로 뜨는 건 `apple_container` 하나다 (#32837)

세 값 다 TOML 에서 통과하지만, 부팅까지 가는 건 `apple_container` 뿐이다.
나머지 둘은 아래 이유로 부팅 자체를 거절한다. 거절 문구가 이유를 그대로 말한다.

| 값 | 부팅 결과 | 이유 |
|---|---|---|
| `apple_container` | 뜬다 | — |
| `microsandbox` | `microvm_constraint_unexpressible` | `msb 0.6.16` 에 `--cap-drop` 과 `--read-only` 가 없다. 프로필이 약속한 격리를 못 주면서 뜨느니 안 뜬다 |
| `nerdctl_kata` | `microvm_work_volume_unsupported` | `nerdctl volume create` 에 크기 플래그가 없어서 keeper 작업 볼륨(RFC-0400)을 만들 방법이 없다 |

이 표는 **이미지가 그 런타임 저장소에 있을 때** 나오는 답이다. 부팅은
이미지 확인 → 작업 볼륨 → 부팅 argv 순서로 가기 때문에, 이미지가 없으면 위
문구 대신 `microvm_image_missing` 이 먼저 나온다. `msb` 는 `msb image list
--format json`, `nerdctl` 은 `nerdctl images` 로 각자 저장소를 확인한다.
런타임마다 이미지 저장소가 따로라서, Docker 로 빌드해 둔 이미지는 셋 중
어디에도 보이지 않는다.

전에는 셋 다 뜨는 것처럼 보였는데, 그건 셋 다 Apple `container` 로 떴기 때문이다.
그래서 `microsandbox` 라고 적은 keeper 의 게스트를 `msb stop` 으로 내리려 하면
`sandbox not found` 가 났고, 실제로 떠 있는 게스트는 아무도 못 치웠다.
지금은 부팅이 런타임을 따라가고, 못 따라가면 부팅을 안 한다.

이 문서의 나머지는 `apple_container` 기준이다 — `container` 자리에 그 백엔드의
CLI 를 놓고 읽으면 된다. 아래 계약 표의 항목 1·2 는 백엔드마다 다르고, 3·4(shim
과 작업 볼륨)는 셋 다 같다.

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
| 2 | 게스트 이미지가 container 이미지 저장소에 있음 (`container image inspect masc-keeper-sandbox:local`) | `microvm_image_missing` |
| 3 | 정적 arm64 shim: `<base>/.masc/microvm/shim/masc-exec-shim` (실행 권한) | `microvm_shim_missing` — 부팅 거부 |
| 4 | 디스크 여유. 볼륨 상한은 `MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE` (기본 256g, sparse) | `microvm_work_volume_create_failed` |

shim 설정(`masc-exec-shim.conf`)은 서버가 부팅마다 같은 디렉터리에 다시
쓴다. 내용은 `remote_root=/masc-work`, `path=<이미지의 PATH>`
(`MASC_KEEPER_MICROVM_PAYLOAD_PATH`), `env_allowlist=MASC_BASE_PATH,
MASC_BASE_PATH_INPUT,MASC_CONFIG_DIR`, `scratch_root=/tmp`. 손으로 고칠 것이 없다.
마지막 줄은 프로토콜 3 shim 이 읽는 키다. 그보다 오래된 shim 은 모르는 키라며
거부하는데, 그 전에 부팅 probe 가 `remote_shim_version_skew` 로 그 shim 을
먼저 거부하므로, 운영자가 보는 것은 설정 오류가 아니라 "shim 을 다시 빌드하라"
는 메시지다.

게스트가 마운트하는 것: 설정 디렉터리(읽기 전용, `/tmp/masc-runtime/.masc/config`),
GitHub identity 스냅샷, 작업 볼륨(`masc-keeper-work-<keeper>` →
`/masc-work`), shim 디렉터리(읽기 전용, `/opt/masc-exec-shim`), 그리고
메모리 파일시스템 `/tmp`(`--tmpfs /tmp`). 마지막 것은 RFC-0422 의 관측 상자가
쓰는 스크래치 자리다. 루트는 읽기 전용이라 이게 없으면 상자 안의 명령은 아무
데도 쓸 수 없다. 크기는 커널 기본값(게스트 메모리의 절반, 기본 게스트에서
551M 실측)이고 게스트가 내려가면 사라진다. 그게 전부다.

## shim 만들기

```bash
# Docker 가 있으면
scripts/remote-ssh/build-shim.sh --arch arm64
# 결과 dist/remote-ssh/masc-exec-shim-linux-arm64 를 설치
mkdir -p ~/me/.masc/microvm/shim
cp dist/remote-ssh/masc-exec-shim-linux-arm64 ~/me/.masc/microvm/shim/masc-exec-shim
chmod +x ~/me/.masc/microvm/shim/masc-exec-shim
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
  -v ~/me/.masc/playground/microvm/<keeper>:/src:ro -v masc-keeper-work-<keeper>:/masc-work \
  masc-keeper-sandbox:local sh -c "mkdir -p -m 0777 /masc-work/<keeper> \
    && cp -a /src/. /masc-work/<keeper>/ && chown -R $U:20 /masc-work/<keeper>"

# 3c. 옮긴 뒤 검증은 서버와 같은 uid 로 실제 쓰기를 해 본다
container exec --user $U:20 masc-keeper-vm-<keeper>-<hash> \
  sh -c 't=$(mktemp /masc-work/<keeper>/.probe.XXXXXX) && unlink "$t" && echo ok'

# 4. 서버 재시작. 게스트는 공유 마운트 없이 다시 뜬다.

# 5. 이제 쓰이지 않는 빌드 볼륨 삭제
container volume list --format json | jq -r '.[].id' | grep masc-keeper-build- \
  | xargs -n1 container volume delete
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
