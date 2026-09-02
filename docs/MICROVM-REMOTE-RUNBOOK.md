# MicroVM Remote Lane Runbook

Apple `container` 게스트가 자기 작업 트리를 가지는 구조(RFC-0400)의 운영
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
MASC_BASE_PATH_INPUT,MASC_CONFIG_DIR`. 손으로 고칠 것이 없다.

게스트가 마운트하는 것: 설정 디렉터리(읽기 전용, `/tmp/masc-runtime/.masc/config`),
GitHub identity 스냅샷, 작업 볼륨(`masc-keeper-work-<keeper>` →
`/masc-work`), shim 디렉터리(읽기 전용, `/opt/masc-exec-shim`). 그게 전부다.

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
