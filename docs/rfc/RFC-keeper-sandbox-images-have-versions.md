---
rfc: "keeper-sandbox-images-have-versions"
title: "Keeper 샌드박스 이미지에 버전을 붙이고, 목록 한 곳에서 고른다"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0070"]
---

# Keeper 샌드박스 이미지에 버전을 붙이고, 목록 한 곳에서 고른다

## 0. 결정할 것

Keeper 는 `sandbox_image` 에 적힌 이미지 안에서 명령을 실행한다. 이 이미지에는
지금 버전이 없다. `masc-keeper-sandbox:local` 은 다시 빌드할 때마다 같은 이름을
덮어쓰고, 런타임은 그 이름만 기억한다. 다시 빌드해도 떠 있는 VM 은 옛 이미지로
계속 돈다. 이미지 안에 무엇이 있는지 적은 목록도 없어서, Keeper 는
`command not found` 를 보고서야 도구가 없다는 걸 안다.

이 RFC 는 다음을 정한다.

1. **태그는 덮어쓰지 않는다.** 태그는 `<이미지 이름>:<UTC 빌드 시각>-<레시피 입력 해시>`
   로 만들고, 같은 태그가 이미 있으면 빌드를 거절한다(§2.2).
2. **Keeper 는 목록의 이름을 고른다.** 이미지 이름(`base`, `ocaml`, `rust`,
   `postgres`, `media`)은 저장소가 정한다. 그 이름이 이 호스트에서 어떤 태그와
   digest 인지는 호스트의 라이브 목록이 정한다. Keeper TOML 의 `sandbox_image` 는
   이름만 받는다. 버전을 올리고 내릴 때는 라이브 목록 한 줄만 바뀐다(§2.3).
3. **런타임은 실제로 뜬 이미지의 digest 를 기록하고 보여 준다.** 설정한 이미지와
   실제 VM 이 다르면 그 차이를 typed 상태로 보여 준다. 다르다고 부팅을 막지는
   않는다(§2.4, §2.9).
4. **공통 도구는 모든 이미지에 넣고, 언어와 미디어 도구는 이미지를 나눈다.**
   2주 동안 Keeper 가 못 찾은 명령을 세어 정했다(§1.4, §2.5).
5. **이미지마다 도구 목록을 싣는다.** 빌드가 끝나면 Keeper 와 같은 제약으로 이미지를
   띄워 도구를 실행해 보고, 그 결과를 이미지에 넣는다. 실행이 실패하면 빌드가
   실패한다(§2.6).

첫 구현은 Apple `container` 저장소만 다룬다. microVM Keeper 의 실행 기록이
91,344건이고 docker 는 88건이다(§1.4 와 같은 기간). docker 저장소는 같은 모양으로
뒤따른다(§6). 턴 안에서 패키지를 설치하는 길은 이 RFC 가 열지 않는다(§3).

## 1. 기준선 (2026-09-24)

이 절의 `<base-path>/.masc` 는 라이브 store 다(`MASC_BASE_PATH` 로 지정).
코드 위치는 origin/main `2de9ddb8f5` 기준이다.

### 1.1 이미지는 두 벌이고, 레시피는 두 군데에 있다

| 이미지 | 레시피 | 누가 빌드하나 |
|---|---|---|
| `masc-sandbox:general` | `lib/keeper_sandbox_image/keeper_sandbox_image.ml` 안의 문자열 | `masc sandbox-image`. microVM 부팅 때 이 태그가 저장소에 **없으면** 런타임이 직접 빌드한다(`keeper_sandbox_microvm.ml:620-622`) |
| `masc-keeper-sandbox:local` | `Dockerfile.keeper-sandbox` | 운영자가 손으로. `scripts/build-keeper-sandbox-image.sh` 는 `docker build` 를 저장소 루트에서 돌린다 |

- main 의 `general` 레시피에는 #34959(09-10)부터 bash·curl·gh·git·python3·ripgrep 에
  더해 ffmpeg, pandoc, libreoffice-impress, poppler-utils, fonts-nanum,
  python3-pil·reportlab·cairosvg 가 들어 있다(`keeper_sandbox_image.ml:53-74`).
- `:local` 에는 opam, OCaml 5.5.1, masc 의존성, node 22, pnpm 10.31.0, jq, make, gcc 가
  있다. 베이스는 `ocaml/opam:ubuntu-24.04-ocaml-5.5` 다(`Dockerfile.keeper-sandbox:24`).

CI 는 `general` 만 빌드한다. `.github/workflows/sandbox-image.yml` 은 `general` 레시피와
그 검증 스크립트 경로가 바뀔 때만 돈다. 이 워크플로는 `ci-<sha>-<arch>` 태그와
`org.opencontainers.image.revision` 라벨, `manifest.json` 을 만든다. 런타임은
이 셋 중 어느 것도 읽지 않는다. `masc-keeper-sandbox` 는 CI 가 빌드하지 않는다.

### 1.2 이름이 같으면 내용이 달라도 모른다

`container image list --format json`, 09-24 11:30Z:

| 참조 | 만든 시각 | digest | `variants[].size` |
|---|---|---|---|
| `docker.io/library/masc-sandbox:general` | 09-07 10:14Z | `57293cbe…` | 64,594,084 |
| `masc-sandbox:general` | 09-07 13:40Z | `8f75d071…` | 85,530,634 |
| `masc-keeper-sandbox:local` | 09-21 05:17Z | `a57cd1df…` | 1,643,333,533 |

- **라이브 `general` 에는 09-10 에 레시피에 넣은 도구가 하나도 없다.** 두 이미지 모두
  09-07 에 빌드됐고, 런타임은 이미지가 없을 때만 빌드한다. 그래서 레시피가 바뀌어도
  이미 있는 이미지는 그대로다. 09-24 에 이미지를 열어 보니 bash, curl, gh, git,
  python3, ripgrep 뿐이었다.
- `general` 이라는 이름이 서로 다른 이미지 둘에 붙어 있다. 둘 중 어느 이미지로
  뜨는지는 확인하지 않았다.
- 09-21 에는 `:local` 도 이미지 둘에 붙어 있었다(08-26 `cf916789…` 는 OCaml 5.5.0,
  09-21 `a57cd1df…` 는 5.5.1). `masc.opam` 은 5.5.1 을 요구하는데, geek-scout 와
  masc-pro-builder 가 옛 이미지로 떴다. 런타임은 아무것도 알리지 않았다. 이 사실은
  그날 운영자 세션이 `container image list` 로 본 것이고, 저장소 안에는 기록이 없다.
- 런타임은 VM 을 띄울 때 **요청한 태그 문자열**만 기록한다
  (`keeper_turn_sandbox_runtime.ml:164-168`, `microvm_boot.image`). 다음 턴에 VM 을
  다시 쓸지는 이 문자열끼리 비교해서 정한다(`:246-250`, `Image_changed`). 같은
  태그로 다시 빌드하면 문자열이 같으니 떠 있는 VM 은 옛 이미지 그대로다. 코드
  주석(`:159-163`)도 이 한계를 적고 #36993 으로 넘겼다. 서버를 재시작하면 떠 있던
  VM 은 비교 없이 새로 띄운다(`:1304-1316`). 그때 새 이미지가 들어간다.
- 실제 digest 는 읽을 수 있다. `container list --format json` 은 떠 있는 VM 마다
  `configuration.image.descriptor.digest`(image index 의 digest)를 준다. 09-24 에
  떠 있던 VM 15개가 모두 `sha256:a57cd1df…` 였다. 반면 CI 는 Docker 의
  `{{.Id}}`(config digest)를 읽는다(`pr-check.yml:393`). 저장소마다 digest 의 종류가 다르다.

### 1.3 오늘 일어난 일: 설정과 실제 VM 이 몇 분 동안 달랐다

#38572(09-24 09:56Z 병합)는 docker·microvm Keeper 가 `sandbox_image` 를 반드시
적게 했다. 라이브 Keeper TOML 19개 중 9개에 이 줄이 없어서, 10:29Z 부터 9명이
부팅을 거절당했다.

- 10:40:53Z 에 자동 부팅 재시도가 9명 모두 통과했다. 그 시점에 누군가 TOML 에 이미지
  줄을 넣었다는 뜻이다. 그 값은 에러 메시지가 권하는 `masc-sandbox:general` 이었다.
  누가 넣었는지는 확인하지 못했다.
- 10:43Z 에 운영자 세션이 설정 API 로 9개를 `masc-keeper-sandbox:local` 로 바꿨다.
- 그때 턴이 돌던 Keeper 7명은 턴이 시작할 때 받은 설정으로 VM 을 새로 띄웠다
  (`keeper_sandbox_factory.ml:44-72`). 그래서 10:43Z 에 만든 VM 은 `general` 이었다.
  같은 시각 `masc_keeper_status` 는 `configured_image = masc-keeper-sandbox:local`
  이라고 답했다.
- 다음 턴(10:45~10:51Z)에 `Image_changed` 로 VM 이 바뀌었다.

턴 도중에 바꾼 설정이 다음 턴부터 들어가는 건 설계대로다. 문제는 그 사이에
"지금 어떤 이미지로 도나"를 물으면 상태 조회가 설정값을 답한다는 점이다. 실제 VM
의 이미지는 `container list` 를 직접 봐야 알 수 있었다.

### 1.4 Keeper 가 못 찾은 명령 (2주)

`<base-path>/.masc/tool_calls/2026-09/DD.jsonl` 의 `Execute` 기록, 09-10 00:01Z ~
09-24 10:55Z. 두 번 센 값이 93,111건과 93,135건이다. 출력에 `X: not found` 가 있고
실행한 명령에도 X 가 있는 기록만 셌다. 오류를 인용만 한 PR 본문과 로그는 뺐다.
두 번 셀 때 줄마다 몇 건씩 차이가 났다(예: `jq` 27건과 32건). 아래 표는 작은 값이다.
L 은 그때 `masc-keeper-sandbox:local` 을 적은 Keeper, U 는 이미지를 적지 않아서
`general` 로 돈 Keeper 다.

| 없던 것 | 건수 | 주로 부른 Keeper | L / U | `:local` 에 있나 |
|---|---|---|---|---|
| `jq` | 27 | won-chik 8, e-masc-the-leader 6, glossary-maniac 5 | 0 / 27 | 있음 |
| `ip`, `ss`, `netstat`, `nslookup`, `dig` | 22 + 15 | rondo 5, won-chik 4, lane-smith 3 (9명) | 11 / 9 | 없음 |
| `file` | 20 | 12명 | 9 / 6 | 없음 |
| Python `yaml` | 15 | polisher, pr-updater, wkbl-web-leader | 11 / 4 | 없음 |
| `dune`, `opam`, `ocaml` | 13 + 11 | ocaml-agent-ic, tui-developer, wkbl-scout | 0 / 12 | 있음 |
| `masc` | 12 | won-chik 5, e-masc-the-leader 5 | 1 / 11 | 호스트 전용 |
| `cargo`, `rustc` | 11 + 3 | rust-hwp-guy 9, jazz-developer 2 | 2 / 9 | 없음 |
| `time` (`/usr/bin/time`) | 8 | jazz-developer 4 | 7 / 1 | 없음 |
| Postgres(`psycopg`, `pg8000`, `psql`, `pg_dump`) | 16 | wkbl-web-leader, wkbl-reviewer | 대부분 U | 없음 |
| `xxd` | 7 | 5명 | 4 / 3 | 없음 |
| Python `PIL`, `numpy` | 7 + 2 | msx-retro-mania | L | 없음 |
| `node` | 4 | wkbl-scout 3 | 0 / 4 | 있음 |

- `jq`, `dune`, `node` 는 `:local` 에 있다. `general` 로 돈 Keeper 만 막혔다. 이미지를
  잘못 고른 경우이고, #38572 이후로 Keeper 는 이미지를 반드시 고른다.
- `file`, `xxd`, `time`, `ip` 계열, Python `yaml` 은 두 이미지 모두에 없다. 12명이
  `file` 을 불렀다. 언어와 관계없는 공통 도구다.
- Rust 와 Postgres 는 특정 Keeper 만 부른다.
- `masc` CLI 는 호스트 운영 도구라 이미지에 넣지 않는다. `Dockerfile.keeper-sandbox`
  도 같은 이유로 뺐다.

L/U 판정의 신뢰도: e-masc-the-leader, tui-developer, indie-geek-blue 는 09-24 10:45Z 까지
`general` 이었음을 로그로 확인했다. 나머지 6명의 날짜별 이미지는 확인하지 못했다.
`:local` 은 09-21 05:17Z 에 다시 빌드됐고, 그전 내용은 기록이 없다. 기록이 없다는
것 자체가 §2.6 이 필요한 이유다.

### 1.5 턴 안에서 설치하려던 시도

| 시도 | 횟수 | 결과 |
|---|---|---|
| `apt-get install` | 8 | 전부 실패. root 아님 3, passwd 에 사용자 없음 2, 읽기 전용 파일시스템 1 |
| `pip install` | 13 | 1건 성공. pip 자체가 없음 8, 읽기 전용 1 |
| `opam install`/`init` | 126 | 이미지의 switch lock 에 쓸 권한 없음 17. 성공 24건은 Keeper 가 OPAMROOT 를 자기 폴더에 따로 복사한 경우 |
| `rustup` | 42 (rust-hwp-guy, 09-16~17) | 기본 HOME 이 읽기 전용이라 실패, 1,800초·2,400초 제한에 4번 걸림. 결국 `playground/.toolchain` 에 1.93.1 을 따로 깔았다 |
| uv 설치 스크립트 | 2 (goo-yang-bong) | 읽기 전용 `/home/opam/.local` 에 막혔다가 다시 시도해서 성공 |

루트 파일시스템은 읽기 전용이다(`keeper_microvm_backend.ml:135`, `--read-only`).
Keeper 는 막히면 자기 작업 폴더에 도구를 따로 깐다. 이렇게 깐 도구는 어떤 버전인지
어디에도 남지 않고, Keeper 마다 다르다.

## 2. 제안

### 2.1 레시피는 저장소의 파일이고, 입력을 스스로 밝힌다

```
sandbox-images/
  common-packages.txt    # 모든 이미지에 까는 apt 패키지 (§2.5)
  base/Dockerfile        # Ubuntu 24.04 + common-packages. 지금의 general 을 대신한다
  base/tools.toml        # 이 이미지가 약속하는 도구 (§2.6)
  ocaml/Dockerfile       # ocaml/opam 베이스 + common-packages + masc 의존성 + node·pnpm
  ocaml/tools.toml
  ocaml/inputs           # 빌드 컨텍스트에 넣을 파일: masc.opam, masc.opam.locked,
                         #   scripts/opam-pin-from-lock.sh
  rust/Dockerfile        # FROM base. rustup 으로 고정한 toolchain 하나
  postgres/Dockerfile    # FROM base. psql, pg_dump, python3-psycopg
  media/Dockerfile       # FROM base. 지금 general 레시피의 ffmpeg·pandoc·libreoffice·PIL 등
  (rust, postgres, media 에도 tools.toml)
```

- `inputs` 에 적힌 파일과 `common-packages.txt` 만 빌드 컨텍스트로 복사한다.
  저장소 루트를 컨텍스트로 쓰지 않는다. Apple `container` 에서 루트를 컨텍스트로
  쓰면 5분 넘게 멈췄다(09-21 운영자 실측). `COPY` 하는 파일이 `inputs` 에 없으면
  빌드가 실패한다.
- `ocaml` 은 `base` 위에 쌓지 않는다. `base` 위에서 opam 으로 컴파일러를 빌드하면
  빌드마다 20~40분이 더 든다(`Dockerfile.keeper-sandbox` 주석). 그래서 지금처럼
  `ocaml/opam` 이미지에서 시작하고, 공통 도구는 같은 `common-packages.txt` 로 깐다.
  대가로 `ocaml` 과 `base` 는 레이어를 나눠 쓰지 못한다. 디스크를 얼마나 더 쓰는지는
  재지 않았다.
- `base` 레시피는 지금처럼 바이너리 안에도 들어간다. 저장소 없이 설치한 바이너리도
  `base` 를 빌드할 수 있어야 하기 때문이다(`keeper_sandbox_image.mli` 의 이유 그대로).
  정본은 `sandbox-images/base/Dockerfile` 과 `common-packages.txt` 이고, 바이너리는
  dune rule 로 두 파일을 읽어 넣는다. 지금처럼 OCaml 문자열로 한 번 더 적지 않는다.
- `Dockerfile.keeper-sandbox` 와 `scripts/build-keeper-sandbox-image.sh` 는 `ocaml/` 로
  옮기고 지운다.

### 2.2 태그: `<이름>:<UTC 빌드 시각>-<입력 해시>`

예: `masc-sandbox-ocaml:20260924T1130Z-3f9a1c07`

- 입력 해시는 `Dockerfile`, `tools.toml`, `common-packages.txt`, `inputs` 가 가리키는
  파일 내용, 부모 이미지의 digest 를 순서대로 이어 붙인 SHA-256 이다. 태그에는 앞
  8자를 쓴다. 이 길이는 코드에서 이름 붙은 상수로 둔다. 전체 해시는 라벨에 남긴다.
- 모든 `FROM` 은 digest 로 고정한다(`ubuntu:24.04@sha256:…`,
  `ocaml/opam:ubuntu-24.04-ocaml-5.5@sha256:…`). `rust`·`postgres`·`media` 의 `FROM` 은
  빌드 인자로 받는다. 빌드 명령이 라이브 목록에서 `base` 의 ref 와 digest 를 읽어
  넘긴다. 부모 digest 가 해시에 들어가므로, `base` 가 바뀌면 자식 태그도 바뀐다.
- 시각을 넣는 이유: 레시피가 같아도 `apt-get` 은 그날의 패키지를 받는다. 해시만
  쓰면 내용이 다른 두 빌드가 같은 태그를 갖는다. 시각은 분 단위다.
- 같은 태그가 이미 저장소에 있으면 빌드를 거절한다. 덮어쓰기는 하지 않는다.
  두 빌드가 같은 분에 같은 레시피로 겹치면 확인과 태그 붙이기 사이에 한쪽이 이길
  수 있다. 이 경우에도 `promote` 는 저장소에 실제로 남은 digest 를 읽으므로, 목록이
  다른 내용을 가리키지는 않는다.
- 라벨: `org.opencontainers.image.version`(태그 값), `.revision`(저장소 커밋),
  `.created`, `.base.name`, `.base.digest`, `masc.sandbox.inputs_sha256`(해시 전체).

### 2.3 목록: 이름은 저장소가, 버전은 호스트가

저장소의 `config/sandbox-images.toml` 은 이름과 레시피 위치만 적는다. digest 는
적지 않는다. 레지스트리를 쓰지 않으니 digest 는 그 digest 를 빌드한 호스트에서만
맞기 때문이다.

```toml
# 저장소: config/sandbox-images.toml
[images.base]
recipe = "sandbox-images/base"

[images.ocaml]
recipe = "sandbox-images/ocaml"
```

호스트의 라이브 목록(`<base-path>/.masc/config/sandbox-images.toml`)은 이 호스트에서
빌드해 올린 버전을 저장소별로 적는다.

```toml
# 라이브
[images.ocaml.apple_container]
ref      = "masc-sandbox-ocaml:20260924T1130Z-3f9a1c07"
digest   = "sha256:…"          # container 가 VM 마다 보고하는 image index digest
previous = { ref = "masc-sandbox-ocaml:20260921T0517Z-9b04e6d1", digest = "sha256:…" }
```

타입:

```ocaml
type image_name = private string                 (* 저장소 목록의 키. 파싱에서만 만든다 *)
type store = Apple_container                      (* docker 는 §6 의 G 단계에서 더한다 *)
type promoted =
  { ref : Oci_ref.t
  ; digest : Oci_digest.t
  ; previous : (Oci_ref.t * Oci_digest.t) option  (* promote 가 채운다 *)
  }
type version =
  | Unpromoted                                    (* 저장소 목록에는 있고 이 호스트에서 아직 올리지 않음 *)
  | Promoted of promoted
type catalog = (image_name * (store * version) list) list
```

- Keeper TOML 은 이름만 적는다: `sandbox_image = "ocaml"`. 이 필드는 태그를 받지 않는다.
  저장소 목록에 없는 이름이면 #38572 와 같은 자리에서 로드를 거절한다.
- 파서는 모르는 키, 빈 digest, digest 모양이 아닌 값을 에러로 돌려준다. 빈 값을
  기본값으로 채우지 않는다.
- 특정 Keeper 만 옛 버전에 묶어야 하면 저장소 목록에 이름을 하나 더 만든다. 어떤
  이미지든 목록에서 보인다.
- `MASC_KEEPER_SANDBOX_DOCKER_IMAGE` 와 내장 기본값 `masc-sandbox:general` 은
  지운다(`env_config_sandbox.ml:61-64`). `image_source` 타입도 통째로 지운다.
  이미지는 목록에서만 오므로 출처를 구분할 필요가 없다. TUI 쪽 같은 합타입과
  `test_the_reader_accepts_every_image_source_the_server_can_name` 도 함께 지운다.
- 저장소 안에서 `sandbox_image = "` 를 쓴 파일은 98개다(배포 Keeper TOML 82개:
  `config/keepers` 4, `config/keepers-default` 1, preset 76, e2e fixture 1. 나머지는
  테스트·문서·스크립트). 이 밖에 `config/tools/masc_keeper_up.toml`, INSTALL 문서,
  지울 환경 변수를 쓰는 `scripts/keeper-docker-multikeeper-isolation-smoke.sh` 도
  바꾼다. 손으로 고치지 않고 스크립트 하나로 바꾼다(§6 의 B2). 옛 값을 읽어 주는
  호환 코드는 두지 않는다.

### 2.4 런타임: 이름 → 버전 → 실제 VM

1. 턴을 받을 때 Keeper 의 `sandbox_image` 이름으로 라이브 목록을 찾는다.
   - `Promoted` 면 그 `ref` 와 `digest` 가 턴의 샌드박스 설정에 들어간다.
   - `Unpromoted` 면 턴을 거절한다. 사유는 `Image_not_built_on_host { name }` 이고,
     운영자가 칠 명령(`masc sandbox-image build <이름>` 과 `promote`)을 함께 적는다.
   - 라이브 목록을 읽지 못하면 `Image_catalog_unreadable` 로 거절한다. 권위 있는
     저장소를 못 읽으면 진행하지 않는다(constitution `authoritative_read_only`).
   - 로드한 뒤에 이름이 목록에서 빠지면 다음 턴에 모르는 이름과 같이 거절한다.
2. 백엔드가 `ref@digest` 로 실행을 받으면 digest 로 띄운다. nerdctl 은 이미 받는다
   (`keeper_sandbox_microvm.ml:532-546`). Apple `container` 는 확인하지 않았다(§8).
   받지 않으면 `ref` 로 띄운다.
3. VM 이 뜨면 `container list` 가 보고하는 실제 digest 를 `microvm_boot` 에 기록한다.
   `Image_changed` 도 이 digest 와 목록의 digest 를 비교한다(#36993 의 image 축을 이
   RFC 가 가져온다). 서버 재시작 뒤에는 지금처럼 VM 을 새로 띄우므로 따로 비교할
   곳이 없다.
4. 실행 영수증, `masc_keeper_status` 의 `sandbox_live`, TUI 는 세 값을 함께 보여 준다.
   목록 이름, 목록의 digest, **실제로 뜬 VM 의 digest** 다. 둘이 다르면
   `Image_drift { configured; running }` 상태로 보여 준다. §1.3 의 몇 분이 이렇게 드러난다.

이미지 저장소에 목록의 `ref` 가 없으면 VM 을 띄우지 않고 `Image_missing_from_store
{ name; ref }` 로 거절한다. 지금 런타임이 `general` 을 직접 빌드하는 경로
(`keeper_sandbox_microvm.ml:620-651`)는 지운다. 그 경로로는 목록의 `ref`(시각이
들어간 태그)도, 목록의 digest 도 만들 수 없다. 처음 설치한 호스트에서는 sandbox
마법사(`sandbox_readiness.ml`)가 `base` 의 빌드와 promote 를 운영자에게 묻고 실행한다.
INSTALL 문서도 이 순서로 고친다.

### 2.5 이미지 구성

| 이름 | 베이스 | 담는 것 | 근거 (§1.4) | 쓸 Keeper |
|---|---|---|---|---|
| `base` | Ubuntu 24.04 | `common-packages.txt`: bash, curl, gh, git, python3, ripgrep, `jq`, `file`, `xxd`, `time`, `iproute2`, `dnsutils`, `procps`, `make`, `python3-pip`, `python3-venv`, `python3-yaml` | `file` 12명, `ip` 계열 9명, `yaml` 15건, `jq` 27건 | 코드를 빌드하지 않는 Keeper |
| `ocaml` | `ocaml/opam` | common + 지금 `:local` 의 내용 전부 | `dune`·`opam` 24건 | masc 저장소에서 빌드·테스트하는 Keeper |
| `rust` | `base` | rustup 으로 고정한 stable 하나, `wasm32-unknown-unknown` target | `cargo`·`rustc` 14건 | rust-hwp-guy |
| `postgres` | `base` | `postgresql-client`, `python3-psycopg` | 16건 | wkbl 레인 |
| `media` | `base` | 지금 `general` 레시피의 ffmpeg, pandoc, libreoffice-impress, poppler-utils, fonts-nanum, python3-pil·reportlab·cairosvg, 그리고 `python3-numpy` | #34959 의 문서·멀티미디어 작업, `PIL`·`numpy` 9건 | msx-retro-mania, 문서·음악을 만드는 Keeper |

- libreoffice 와 ffmpeg 를 `base` 에서 뺀다. `base` 에 두면 `rust`·`postgres` 에도 전부
  내려간다. §4 가 큰 이미지 하나를 버린 이유와 같다.
- `general` 과 `:local` 은 Debian 과 Ubuntu 로 베이스가 달랐다. 새 구성은 모두
  Ubuntu 24.04 다.
- wkbl 레인은 node·pnpm 과 Postgres 가 함께 필요하다. `postgres` 를 어디에 쌓을지는
  §8 에 남긴다.
- 이미지 크기는 `base` 말고는 재지 않았다. 단계 D 에서 빌드하며 잰다.

### 2.6 이미지 안의 도구 목록

`tools.toml` 은 이미지가 약속하는 도구와, 그 도구를 실행해 볼 명령을 적는다.
버전 숫자는 적지 않는다.

```toml
[tools.jq]
probe = ["jq", "--version"]

[tools.ocaml]
probe = ["ocaml", "-vnum"]
```

- 빌드가 끝나면 Keeper 와 같은 제약으로 이미지를 띄워 모든 `probe` 를 실행한다.
  제약은 `--read-only`, `--network none`, `--cap-drop ALL`, 이미지에 계정이 없는
  uid 로 `--user`, `/tmp` 만 tmpfs 다. §1.5 의 권한 실패가 여기서 걸린다. 하나라도
  실패하면 빌드가 실패하고 태그를 남기지 않는다.
- 실행 결과(도구 이름, 출력한 버전 문자열)를 `/etc/masc/image.json` 에 담아 이미지의
  마지막 레이어로 굽는다. Keeper 는 VM 안에서 이 파일을 읽어 쓸 수 있는 도구를
  확인한다. 운영자는 `masc sandbox-image show <이름>` 과 `sandbox_live` 로 같은 내용을
  본다. `show` 는 자식 이미지의 `base.digest` 가 지금 목록의 `base` digest 와 같은지도
  보여 준다. `base` 를 올린 뒤 다시 빌드하지 않은 자식이 여기서 보인다.
- `scripts/check-sandbox-ocaml-version.sh`, `check-sandbox-dune-version.sh` 는 남긴다.
  두 스크립트는 모든 PR 의 lint 에서 돌고(`scripts/ci/run-lint-suite.sh:478,482`),
  `masc.opam` 만 바꾼 PR 에서도 이미지와 저장소의 어긋남을 잡는다. 가리키는 파일만
  `sandbox-images/ocaml/Dockerfile` 로 바꾼다.

### 2.7 빌드, 올리기, 되돌리기

- `masc sandbox-image build <이름> [--runtime apple_container]`: `inputs` 만 담은
  컨텍스트로 빌드하고 §2.6 확인을 돌린 뒤, 태그와 digest 를 출력한다. 목록은 고치지
  않는다.
- `masc sandbox-image promote <이름> <태그>`: 저장소에서 그 태그의 digest 를 읽어 라이브
  목록의 한 줄을 바꾸고, 바뀌기 전 값을 `previous` 에 남긴다. 설정 API 를 거치므로
  다른 설정 쓰기와 같은 CAS 규칙을 따른다. 바뀐 이미지는 각 Keeper 의 다음 턴에
  들어간다(§2.4 의 3).
- `masc sandbox-image rollback <이름>`: 지금 값과 `previous` 를 맞바꾼다. 새 이미지로
  턴이 깨지면 운영자가 이 명령 하나로 되돌린다. 자동으로 되돌리지는 않는다. 부팅
  실패는 이미 typed 사유로 남으니, 사람이 그 사유를 보고 정한다.
- CI 는 `sandbox-images/**`, 모든 `inputs` 가 가리키는 파일(`masc.opam`,
  `masc.opam.locked`, `scripts/opam-pin-from-lock.sh`), `dune-project` 중 하나라도 바뀌면
  영향받는 이미지와 그 자식을 amd64·arm64 로 빌드하고 §2.6 확인을 돌린다. 지금
  `sandbox-image.yml` 이 `general` 에 하는 일을 모든 이미지로 넓힌다. CI 가 테스트용으로
  이미지를 직접 빌드하는 곳(`pr-check.yml:392`, `test.yml:277,483`)은 빌드한 이미지를
  테스트용 라이브 목록에 promote 한 뒤 쓴다. CI 가 만든 이미지를 운영 호스트로 옮기는
  일은 이 RFC 에 넣지 않는다(§3).

### 2.8 오래된 이미지 정리

- `masc sandbox-image prune` 은 `masc.sandbox.inputs_sha256` 라벨이 있는 이미지만
  후보로 본다. 이름 앞부분으로 고르지 않는다. 그중 라이브 목록의 `ref`·`previous`
  어디에도 없고, 떠 있는 VM 도 쓰지 않는 이미지를 지운다.
- 기본은 지울 목록만 보여 준다. `--yes` 가 있을 때만 지운다. 자동으로 지우지 않고,
  "최근 N개만 남긴다" 같은 개수 기준도 두지 않는다.
- 한계: 이미지 저장소는 호스트에 하나지만 라이브 목록은 base path 마다 있다. 같은
  호스트의 다른 base path 가 쓰는 이미지는 이 명령이 모른다. 그래서 기본을 목록
  보여 주기로 둔다.
- 라벨이 없는 `masc-sandbox:general` 두 개와 `masc-keeper-sandbox:local` 은 prune 이
  보지 않는다. 단계 B 에서 운영자가 한 번 손으로 지운다.

### 2.9 이 RFC 가 더하는 거절과 그 이유

constitution `<gates>` 는 하드 게이트를 기본으로 두지 말라고 한다. 이 RFC 가 더하는
거절은 넷이다.

| 거절 | 어디서 | 없으면 생기는 일 | 판단 |
|---|---|---|---|
| 같은 태그가 있으면 빌드 거절 | 운영자 빌드 명령 | 태그가 다시 덮어써진다. §1.2 의 사고가 그대로 남는다 | 둔다. 이것이 "덮어쓰지 않는다"의 정의다 |
| 도구 실행 실패면 빌드 실패 | 운영자 빌드 명령 | 약속한 도구가 없는 이미지가 목록에 올라간다 | 둔다. Keeper 턴이 아니라 빌드 시점이라 Keeper 흐름을 막지 않는다 |
| 모르는 이름, 올리지 않은 이름, 목록을 못 읽음 → 턴 거절 | 턴 받을 때 | 예전처럼 아무 이미지로 조용히 뜬다 | 둔다. #38572 와 같은 자리이고, constitution `strict_parse_no_default`·`authoritative_read_only` 를 따른다 |
| 목록의 digest 와 실제 digest 가 다르면 부팅 거절 | VM 띄울 때 | 다른 이미지로 뜬다 | **두지 않는다.** 실제 digest 를 기록하고 `Image_drift` 로 보여 주면 무엇으로 돌았는지 남는다. 막으면 태그 경쟁 하나로 Keeper 가 턴을 못 돈다 |

## 3. 하지 않는 것

- **턴 안 패키지 설치를 지원하지 않는다.** §1.5 처럼 Keeper 가 자기 폴더에 도구를
  까는 일은 지금도 되고, 막지 않는다. 다만 그 경로를 위한 환경 변수나 폴더를 만들지
  않는다. 필요한 도구는 레시피에 넣고 버전을 올린다.
- **레지스트리에 올리지 않는다.** 이미지는 운영 호스트의 저장소에만 있다. 그래서
  저장소 목록에는 digest 가 없다(§2.3).
- **Keeper 별 버전을 자동으로 올리지 않는다.** 목록을 바꾸는 건 운영자다.
- **턴 도중 설정 변경이 다음 턴부터 들어가는 동작은 바꾸지 않는다.** 그 사이의
  차이를 보이게 하는 것까지만 한다(§2.4 의 4).

## 4. 다른 선택지

| 선택지 | 좋은 점 | 나쁜 점 | 판단 |
|---|---|---|---|
| Keeper TOML 마다 전체 태그를 적는다 | 새 파일·새 개념이 없다 | 버전을 올릴 때 라이브 TOML 19개를 고쳐야 하고, 하나를 빠뜨리면 그 Keeper 만 옛 이미지에 남는다 | 버림. 같은 변환을 여러 곳에서 따로 하게 된다 |
| 태그는 그대로 두고 digest 만 비교한다(#36993) | 가장 작다 | 옛 버전으로 되돌릴 이름이 없고, 어떤 버전이 언제 쓰였는지 남지 않는다 | §2.4 에 흡수. 이것만으로는 부족하다 |
| 모든 도구를 넣은 이미지 하나 | 목록이 한 줄이다 | Rust·Postgres·libreoffice 가 모든 Keeper VM 에 들어간다. `:local` 이 이미 1.6GB 급이다 | 버림 |
| 턴 안 설치를 공식 지원한다(`/masc-work` 에 prefix) | Keeper 가 스스로 해결한다 | 무엇이 깔렸는지 재현할 수 없다. §1.5 의 opam 복사본 같은 것이 Keeper 마다 생긴다 | 버림(§3) |
| 저장소 목록에 digest 까지 넣는다 | 목록이 한 파일이다 | 레지스트리가 없으니 다른 호스트와 CI 에서 모든 Keeper 가 부팅을 거절당한다 | 버림(§2.3) |

## 5. 비슷한 제품 사례

모두 2026-09-24 에 1차 출처를 열어 확인했다.

| 설계 | 사례 | 무엇을 하나 | 출처 |
|---|---|---|---|
| §2.2 해시 태그 | Nixpkgs `dockerTools` | `tag` 를 비우면 derivation 해시를 태그로 쓴다. `created` 를 고정해 같은 입력이 같은 이미지를 만든다 | [dockertools.section.md](https://raw.githubusercontent.com/NixOS/nixpkgs/master/doc/build-helpers/images/dockertools.section.md) |
| §2.2 시각 | GitHub Actions `runner-images` | 이미지 릴리스를 날짜로 부른다(`20260920.143`). 사용자는 `ubuntu-latest` 같은 움직이는 이름을 쓴다 | [actions/runner-images](https://github.com/actions/runner-images) |
| §2.2 덮어쓰기 금지 | Docker Hub immutable tags | 켜면 그 태그를 덮어쓰거나 지울 수 없다. 레지스트리가 막는다 | [docs.docker.com](https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/) |
| §2.2 `FROM` 고정 | Docker 빌드 권장 사항 | "Image tags are mutable". `FROM` 을 digest 로 고정하라고 권한다 | [best-practices](https://docs.docker.com/build/building/best-practices/) |
| §2.3 이름 → 버전 | Kustomize `images:` | 이미지 이름을 `newTag` 나 `digest` 로 바꿔 끼운다. 한 파일에서 바꾸면 모든 참조가 따라간다 | [kustomize images](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/) |
| §2.4 실제 digest 기록 | Kubernetes `ContainerStatus.imageID` | 스펙에 적은 이미지와 다를 수 있다고 명시하고, 런타임이 실제로 푼 값을 따로 보여 준다 | [pod-v1](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/) |
| §2.4 교체, §2.7 되돌리기 | Podman `auto-update` | 떠 있는 컨테이너의 digest 와 저장소의 digest 가 다르면 다시 띄운다. 실패하면 이전 이미지로 자동으로 되돌린다 | [podman-auto-update](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html) |
| §2.4 digest 읽기 | Apple `container` | `image inspect` 가 `configuration.descriptor.digest`(index)와 `variants[].digest`(플랫폼별)를 준다. 소스 1.4.1 과 main `dc276ee` 에서 확인 | [ImageResource.swift](https://github.com/apple/container/blob/main/Sources/ContainerResource/Image/ImageResource.swift) |
| §2.5 공통 + 나눈 이미지 | Dev Container Features | 어떤 베이스 이미지 위에든 도구를 레이어로 얹는다. `devcontainer-lock.json` 이 feature 의 digest 를 고정한다(베이스 이미지는 고정하지 않는다) | [features](https://containers.dev/implementors/features/), [lockfile](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainer-lockfile.md) |
| §2.6 이미지를 실행해 목록 만들기 | `runner-images` `Generate-SoftwareReport.ps1` | 빌드한 이미지 안에서 `git --version` 같은 명령을 돌려 `software-report.json` 을 만든다. 레시피(`toolset-*.json`)와 결과를 따로 둔다 | [docs-gen](https://github.com/actions/runner-images/tree/main/images/ubuntu/scripts/docs-gen) |
| §2.6 | BuildKit SBOM | Dockerfile 이 아니라 마지막 이미지를 스캔해 SPDX 를 붙인다 | [sbom](https://docs.docker.com/build/metadata/attestations/sbom/) |
| §2.2 라벨 | OCI annotations | `created`, `version`, `revision`, `source`, `base.name`, `base.digest` | [annotations.md](https://github.com/opencontainers/image-spec/blob/main/annotations.md) |

반대 근거도 있다.

- **큰 운영자는 움직이는 이름을 택했다.** `runner-images` 는 사용자가 개별 빌드를
  고정할 수 없게 하고, `-latest` 를 1~2달에 걸쳐 옮긴다. 수많은 사용자를 한 이름으로
  모으는 데는 맞다. MASC 는 운영자 한 명이 Keeper 스무 명의 이미지를 고르고, §1.2
  처럼 이름이 같은 채 내용이 바뀌어 사고가 났다. 그래서 고정 쪽을 택한다.
- **에이전트 제품은 대개 이미지 버전을 관리하지 않는다.** `openai/codex-universal` 은
  여러 언어를 넣은 큰 이미지 하나를 `:latest` 로만 낸다
  ([README](https://github.com/openai/codex-universal)). Claude Code 의 dev container
  feature 버전은 설치 스크립트만 고정하고 CLI 버전은 고정하지 않는다
  ([devcontainer](https://code.claude.com/docs/en/devcontainer)). 샌드박스 digest 가
  바뀌면 VM 을 바꾸는 에이전트 제품은 찾지 못했다.
- **해시 태그는 읽기 어렵다.** Nix 는 이 비용을 받아들였고, devcontainers 이미지는
  `5.2.1-24` 처럼 semver 와 Node 버전을 붙인다. 이 RFC 는 시각을 앞에 두어 언제
  빌드했는지는 읽히게 하고, 무엇으로 빌드했는지는 해시와 `/etc/masc/image.json` 으로
  확인하게 한다.
- **Podman 은 자동으로 되돌린다.** 이 RFC 는 되돌리기를 명령 하나로 두고, 자동으로는
  하지 않는다(§2.7).

## 6. 단계

한 PR 이 20k token 을 넘지 않도록 나눈다. 앞 단계에 의존하면 stacked PR 로 올린다.

| 단계 | 내용 | 의존 |
|---|---|---|
| A | `sandbox-images/` 레시피·`common-packages.txt`·`tools.toml`, 태그 계산, `masc sandbox-image build`, §2.6 확인, 바이너리에 `base` 레시피를 dune rule 로 넣기 | — |
| B1 | 저장소·라이브 목록 파서와 타입, 턴 받을 때 이름 해석과 typed 거절, env·내장 기본값·`image_source`·자동 빌드 삭제, sandbox 마법사의 `base` 빌드·promote | A |
| B2 | `sandbox_image = "` 98곳과 관련 스크립트·문서를 이름으로 바꾸는 스크립트와 그 결과 | B1 |
| C | 실제 digest 기록·비교, `Image_drift`, 상태·영수증·TUI 표시(#36993 image 축) | B1 |
| D | `rust`, `postgres`, `media` 이미지, 크기 실측 | A |
| E | CI 트리거 확장, 모든 이미지 빌드·확인, CI 의 테스트용 이미지를 목록으로 쓰기 | A, B1 |
| F | `promote`, `rollback`, `prune` | B1 |
| G | docker 저장소를 `store` 에 더하기 | C |

## 7. 확인 방법

- A: 레시피 입력 하나를 바꾸면 태그가 바뀌고, 안 바꾸면 해시가 같다. 같은 태그로
  다시 빌드하면 거절된다. `tools.toml` 의 `probe` 가 실패하는 이미지는 태그가 남지
  않는다. 쓰기 권한이 필요한 `probe` 는 Keeper 제약에서 실패한다.
- B1: 저장소 목록에 없는 이름, 태그 문자열, 빈 digest 를 적은 설정은 로드가 거절된다.
  `Unpromoted` 이름을 쓴 Keeper 는 턴이 `Image_not_built_on_host` 로 거절되고, 사유에
  칠 명령이 있다.
- C: 같은 태그를 다른 이미지로 덮어쓴 뒤 턴을 돌리면 VM 은 뜨고, 상태는
  `Image_drift` 에 두 digest 를 보여 준다. 목록의 digest 를 바꾸면 다음 턴에 VM 이
  바뀐다.
- 운영 실측: 목록을 바꾼 뒤 `container list` 의 digest 와 `sandbox_live` 의 digest 가
  모든 Keeper 에서 같은지 확인하고, TUI 스크린샷을 남긴다.
- 효과: 적용 2주 뒤 §1.4 와 같은 방법으로 다시 센다. 공통 도구 행이 0 이 되는지 본다.

## 8. 열린 질문

1. wkbl 레인은 node·pnpm 과 Postgres 가 함께 필요하다. `postgres` 를 `ocaml` 위에
   쌓을지, node 만 담은 `web` 이미지를 따로 둘지.
2. `/etc/masc/image.json` 을 Keeper 프롬프트에 넣을지, VM 안 파일로만 둘지. 넣으면 매
   턴 바이트가 늘고, 안 넣으면 Keeper 가 파일을 읽어야 안다.
3. Apple `container` 가 `ref@sha256:…` 형태로 실행을 받는지 확인하지 않았다. 받으면
   §2.4 의 2 에서 digest 로 직접 띄운다.
4. 같은 호스트에 base path 가 여럿이면 `prune` 이 다른 base path 의 이미지를 모른다
   (§2.8). 호스트 단위 목록이 필요한지.
