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
덮어쓰고, 런타임은 그 이름만 기억한다. 그래서 "이 턴이 어떤 도구로 돌았나"를
답할 수 없고, 다시 빌드한 이미지가 이미 떠 있는 VM 에 들어가지도 않는다.
이미지 안에 무엇이 있는지 적은 목록도 없어서, Keeper 는 `command not found` 를
보고서야 도구가 없다는 걸 안다.

이 RFC 는 다음을 정한다.

1. **이미지 태그는 덮어쓰지 않는다.** 태그는 `<이미지 이름>:<UTC 빌드 날짜>-<레시피 입력 해시 8자>`
   로 만들고, 같은 태그가 이미 있으면 빌드를 거절한다(§2.2).
2. **Keeper 는 목록의 이름을 고른다.** `config/sandbox-images.toml` 한 파일이
   이름(`base`, `ocaml`, `rust`, `postgres`)마다 지금 쓸 태그와 digest 를 적는다.
   Keeper TOML 의 `sandbox_image` 는 이 이름만 받는다. 버전을 올릴 때는 이 파일의
   한 줄만 바꾼다(§2.3).
3. **런타임은 digest 를 기록하고 비교한다.** VM 을 띄울 때 실제 digest 를 기록하고,
   다음 턴에 목록의 digest 와 다르면 VM 을 새로 띄운다(§2.4).
4. **공통 도구는 모든 이미지에 넣고, 언어는 이미지를 나눈다.** 2주 동안 Keeper 가
   못 찾은 명령을 세어 공통 도구와 언어별 이미지를 정했다(§1.4, §2.5).
5. **이미지마다 도구 목록을 싣는다.** 레시피가 도구 목록을 선언하고, 빌드 뒤
   이미지 안에서 실제로 실행해 확인한다. 확인하지 못하면 빌드가 실패한다(§2.6).

턴 안에서 패키지를 설치하는 길은 이 RFC 가 열지 않는다(§3).

## 1. 기준선 (2026-09-24)

이 절의 `<base-path>/.masc` 는 라이브 store 다(`MASC_BASE_PATH` 로 지정).
코드 위치는 origin/main `2de9ddb8f5` 기준이다.

### 1.1 이미지는 두 벌이고, 레시피는 두 군데에 있다

| 이미지 | 레시피 | 누가 빌드하나 | 내용 |
|---|---|---|---|
| `masc-sandbox:general` | `lib/keeper_sandbox_image/keeper_sandbox_image.ml` 안의 문자열 | `masc sandbox-image`, 그리고 microVM 부팅 때 이 태그가 없으면 런타임이 직접(`keeper_sandbox_microvm.ml:620-622`) | bash, curl, gh, git, python3, ripgrep. pip·jq·make·gcc·node·opam 없음 |
| `masc-keeper-sandbox:local` | `Dockerfile.keeper-sandbox` | 운영자가 손으로. `scripts/build-keeper-sandbox-image.sh` 는 `docker build` 를 저장소 루트에서 돌린다 | opam, OCaml 5.5.1, masc 의존성, node 22, pnpm 10.31.0, jq, make, gcc |

CI 는 `general` 만 빌드한다. `.github/workflows/sandbox-image.yml` 은
`lib/keeper_sandbox_image/**` 가 바뀔 때만 돌고, `ci-<sha>-<arch>` 태그와
`org.opencontainers.image.revision` 라벨, `manifest.json` 을 만든다.
런타임은 이 셋 중 어느 것도 읽지 않는다.

`masc-keeper-sandbox` 는 CI 가 한 번도 빌드하지 않는다. Apple `container` 에서
저장소 루트를 빌드 컨텍스트로 쓰면 5분 넘게 멈춘다(09-21 실측). 그래서
운영자는 Dockerfile 이 `COPY` 하는 네 파일만 따로 모아서 빌드한다.

### 1.2 태그는 덮어써지고, 런타임은 이름만 비교한다

`container image list --format json`, 09-24 11:30Z:

| 참조 | 만든 시각 | digest | `variants[].size` |
|---|---|---|---|
| `docker.io/library/masc-sandbox:general` | 09-07 10:14Z | `57293cbe…` | 64,594,084 |
| `masc-sandbox:general` | 09-07 13:40Z | `8f75d071…` | 85,530,634 |
| `masc-keeper-sandbox:local` | 09-21 05:17Z | `a57cd1df…` | 1,643,333,533 |

- `general` 이라는 이름이 서로 다른 이미지 둘에 붙어 있다. 어느 쪽이 뜨는지는
  런타임이 이름을 어떻게 정규화하느냐에 달렸다.
- 09-21 에는 `:local` 도 두 이미지에 붙어 있었다. 옛 이미지는 OCaml 5.5.0,
  새 이미지는 5.5.1 이었다. `masc.opam` 이 5.5.1 을 요구하는데도 Keeper 둘이
  옛 이미지로 떴고, 런타임은 아무것도 알리지 않았다.
- 런타임은 VM 을 띄울 때 **요청한 태그 문자열**만 기록한다
  (`keeper_turn_sandbox_runtime.ml:164-168`, `microvm_boot.image`). 다음 턴에 VM 을
  다시 쓸지는 이 문자열끼리 비교해서 정한다(`:246-250`, `Image_changed`).
  같은 태그로 다시 빌드하면 문자열이 같으니, 떠 있는 VM 은 서버를 재시작하기
  전까지 옛 이미지 그대로다. 코드 주석(`:159-163`)도 이 한계를 적고 #36993 으로
  넘겨 두었다.
- 실제 digest 는 읽을 수 있다. `container list --format json` 은 떠 있는 VM 마다
  `configuration.image.descriptor.digest` 를 준다(09-24 실측,
  `masc-keeper-vm-tui-developer-…` → `sha256:a57cd1df…`).

### 1.3 오늘 일어난 일: 이름과 실제 이미지가 따로 놀았다

#38572(09-24 09:56Z 병합)는 docker·microvm Keeper 가 `sandbox_image` 를 반드시
적게 했다. 라이브 TOML 9개에는 이 줄이 없어서 10:29Z 부터 9명이 부팅을 거절당했다.

- 10:40Z 쯤 누군가 9개 TOML 에 에러 메시지가 권하는 줄
  (`sandbox_image = "masc-sandbox:general"`)을 넣었다. 누가 넣었는지는 확인하지 못했다.
- 10:43Z 에 운영자 세션이 설정 API 로 9개를 `masc-keeper-sandbox:local` 로 바꿨다.
- 그때 턴이 돌던 Keeper 7명은 턴이 시작할 때 받은 설정으로 VM 을 새로 띄웠다
  (`keeper_sandbox_factory.ml:44-72`). 그래서 10:43Z 에 만든 VM 은 `general` 이었고,
  같은 시각 `masc_keeper_status` 는 `configured_image = masc-keeper-sandbox:local`
  이라고 답했다.
- 다음 턴(10:45~10:51Z)에 `Image_changed` 로 VM 이 바뀌었다.

동작 자체는 설계대로다. 문제는 사람이 이 사이의 몇 분 동안 "지금 어떤 이미지로
도나"를 물으면, 상태 조회가 설정값을 답한다는 점이다. 실제로 뜬 이미지는
`container list` 를 직접 봐야 알 수 있었다.

### 1.4 Keeper 가 못 찾은 명령 (2주)

`<base-path>/.masc/tool_calls/2026-09/DD.jsonl` 의 `Execute` 기록 93,135건,
09-10 00:01Z ~ 09-24 10:55Z. 없는 이름이 그 명령 안에도 나오는 기록만 셌다
(오류를 인용만 한 PR 본문·로그는 뺐다). L 은 그때 `masc-keeper-sandbox:local` 을
적은 Keeper, U 는 적지 않아서 `general` 로 돈 Keeper 다.

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

- `jq`, `dune`, `node` 는 `:local` 에 있다. `general` 로 돈 Keeper 만 막혔다.
  이 셋은 이미지를 잘못 고른 문제였고, #38572 이후에는 Keeper 가 이미지를 반드시
  고른다.
- `file`, `xxd`, `time`, `ip` 계열, Python `yaml` 은 두 이미지 모두에 없다.
  Keeper 12명이 `file` 을 불렀다. 특정 언어와 관계없는 공통 도구다.
- Rust 와 Postgres 는 특정 Keeper 만 부른다.
- `masc` CLI 는 호스트 운영 도구라 이미지에 넣지 않는다.
  `Dockerfile.keeper-sandbox` 도 같은 이유로 뺐다.

L/U 판정의 신뢰도: e-masc-the-leader, tui-developer, indie-geek-blue 는 09-24 10:45Z
까지 `general` 이었음을 로그로 확인했다. 나머지 6명의 날짜별 이미지는 확인하지
못했다. `:local` 은 09-21 05:17Z 에 다시 빌드됐고, 그전 내용은 기록이 없다.
기록이 없다는 것 자체가 §2.6 이 필요한 이유다.

### 1.5 턴 안에서 설치하려던 시도

| 시도 | 횟수 | 결과 |
|---|---|---|
| `apt-get install` | 8 | 전부 실패. root 아님 3, passwd 에 사용자 없음 2, 읽기 전용 파일시스템 1 |
| `pip install` | 13 | 1건 성공. pip 자체가 없음 8, 읽기 전용 1 |
| `opam install`/`init` | 126 | 이미지의 switch lock 에 쓸 권한 없음 17. 성공 24건은 Keeper 가 OPAMROOT 를 자기 폴더에 따로 복사한 경우 |
| `rustup` | 42 (rust-hwp-guy, 09-16~17) | 기본 HOME 이 읽기 전용이라 실패, 1,800초·2,400초 제한에 4번 걸림. 결국 `playground/.toolchain` 에 1.93.1 을 따로 깔았다 |
| uv 설치 스크립트 | 2 (goo-yang-bong) | 읽기 전용 `/home/opam/.local` 에 막혔다가 다시 시도해서 성공 |

루트 파일시스템은 읽기 전용이다(`keeper_microvm_backend.ml:135`, `--read-only`).
그래서 Keeper 는 막히면 자기 작업 폴더에 도구를 따로 깐다. 이렇게 깐 도구는
어떤 버전인지 어디에도 남지 않고, Keeper 마다 다르다.

## 2. 제안

### 2.1 레시피는 저장소의 파일이고, 입력을 스스로 밝힌다

```
sandbox-images/
  base/Dockerfile        # 공통 도구. 지금의 general 을 대신한다
  base/tools.toml        # 이 이미지가 약속하는 도구 목록 (§2.6)
  ocaml/Dockerfile       # FROM base. opam, OCaml, masc 의존성, node, pnpm
  ocaml/tools.toml
  ocaml/inputs           # 빌드 컨텍스트에 들어갈 파일: masc.opam, masc.opam.locked,
                         #   scripts/opam-pin-from-lock.sh
  rust/Dockerfile        # FROM base. rustup 으로 고정한 toolchain 하나
  rust/tools.toml
  postgres/Dockerfile    # FROM base. psql, pg_dump, python3-psycopg
  postgres/tools.toml
```

- `inputs` 에 적힌 파일만 빌드 컨텍스트로 복사한다. 저장소 루트를 컨텍스트로
  쓰지 않으니 §1.1 의 멈춤이 생기지 않는다. `COPY` 하는 파일이 `inputs` 에 없으면
  빌드가 실패한다.
- `base` 레시피는 지금처럼 바이너리 안에도 들어간다. 저장소 없이 설치한
  바이너리도 `base` 를 빌드할 수 있어야 하기 때문이다(`keeper_sandbox_image.mli`
  의 이유 그대로). 다만 정본은 `sandbox-images/base/Dockerfile` 하나이고,
  바이너리는 dune rule 로 이 파일을 읽어 넣는다. 지금처럼 OCaml 문자열로 한 번 더
  적지 않는다.
- `Dockerfile.keeper-sandbox` 와 `scripts/build-keeper-sandbox-image.sh` 는
  `ocaml/` 로 옮기고 지운다.

### 2.2 태그: `<이름>:<UTC 날짜>-<입력 해시>`

예: `masc-sandbox-ocaml:2026.09.24-3f9a1c07`

- 입력 해시는 `Dockerfile`, `tools.toml`, `inputs` 가 가리키는 파일 내용,
  그리고 부모 이미지의 digest 를 순서대로 이어 붙인 SHA-256 의 앞 8자다.
  부모 digest 가 들어가므로 `base` 가 바뀌면 자식 이미지 태그도 바뀐다.
- `base` 의 `FROM` 도 digest 로 고정한다(`ubuntu:24.04@sha256:…`). 태그로 적으면
  같은 레시피가 다른 날 다른 Ubuntu 위에 빌드되는데, 해시는 그대로다.
- 날짜를 넣는 이유: 레시피가 같아도 `apt-get` 은 그날의 패키지를 받는다.
  해시만 쓰면 내용이 다른 두 빌드가 같은 태그를 갖는다. 날짜가 있으면 다른 날 한
  빌드는 태그가 갈린다.
- 같은 태그가 이미 저장소에 있으면 빌드를 거절한다. 같은 날 같은 레시피로 다시
  빌드해야 하면 `.2` 를 붙인다(`2026.09.24-3f9a1c07.2`). 덮어쓰기는 어떤 경우에도
  하지 않는다.
- 이미지에 OCI 라벨을 붙인다: `org.opencontainers.image.version`(태그 값),
  `.revision`(저장소 커밋), `.created`, `masc.sandbox.inputs_sha256`(해시 전체).

### 2.3 목록: `config/sandbox-images.toml`

```toml
[images.base]
ref    = "masc-sandbox-base:2026.09.24-a1b2c3d4"
digest = "sha256:…"

[images.ocaml]
ref    = "masc-sandbox-ocaml:2026.09.24-3f9a1c07"
digest = "sha256:…"
parent = "base"
previous = { ref = "masc-sandbox-ocaml:2026.09.21-9b04e6d1", digest = "sha256:…" }

[images.rust]
ref    = "masc-sandbox-rust:2026.09.24-77e0d2aa"
digest = "sha256:…"
parent = "base"
```

- 저장소의 `config/sandbox-images.toml` 은 배포 기본값이고, 라이브 값은
  `<base-path>/.masc/config/sandbox-images.toml` 이다. Keeper TOML 과 같은 규칙이다.
- Keeper TOML 은 이름만 적는다: `sandbox_image = "ocaml"`. 이 필드는 태그를
  받지 않는다. 목록에 없는 이름이면 #38572 와 같은 자리에서 로드를 거절한다.
- 특정 Keeper 만 옛 버전에 묶어야 하면 목록에 이름을 하나 더 만든다
  (`[images.ocaml-2026-09-21]`). 어떤 이미지든 목록 한 곳에서 보인다.
- 타입:

  ```ocaml
  type image_name = private string          (* 목록의 키. 파싱에서만 만든다 *)
  type image_entry =
    { ref : Oci_ref.t                        (* 이름:태그 *)
    ; digest : Oci_digest.t                  (* sha256:<64 hex> *)
    ; parent : image_name option
    ; previous : (Oci_ref.t * Oci_digest.t) option   (* promote 가 채운다 *)
    }
  type catalog = image_entry Image_name_map.t
  ```

  파서는 모르는 키, 빈 digest, 목록에 없는 `parent` 를 에러로 돌려준다.
  빈 값을 기본값으로 채우지 않는다.
- `MASC_KEEPER_SANDBOX_DOCKER_IMAGE` 와 내장 기본값 `masc-sandbox:general` 은
  지운다(`env_config_sandbox.ml:61-64`). `image_source` 의 `Workspace_env`,
  `Built_in` 도 함께 지운다. 이미지는 목록에서만 온다.
- 배포에 들어 있는 Keeper TOML 82개(`config/keepers` 4, `config/keepers-default` 1,
  preset 76, e2e fixture 1)와 테스트 8곳은 `sandbox_image = "base"` 로 바꾼다.
  라이브 TOML 은 운영자가 한 번에 바꾼다. 옛 값을 읽어 주는 호환 코드는 두지 않는다.
- `digest` 는 이미지 index 의 digest 다. `container image inspect` 의
  `configuration.descriptor.digest` 이고, `container list` 가 떠 있는 VM 마다 주는
  값과 같은 종류다(§1.2 에서 `a57cd1df…` 가 양쪽에서 같았다). 플랫폼별 manifest
  digest(`variants[].digest`)는 쓰지 않는다.

### 2.4 런타임: 이름 → 태그 → digest

1. 턴을 받을 때 Keeper 의 `sandbox_image` 이름을 목록에서 찾아 `ref` 와 `digest` 를
   얻는다. 이 값이 턴의 샌드박스 설정에 들어간다(지금 태그가 들어가는 자리).
2. VM 을 띄우기 전에 이미지 저장소에서 `ref` 의 digest 를 읽는다. 목록의 `digest`
   와 다르면 띄우지 않고 거절한다. 거절 사유에는 두 digest 를 모두 적는다.
   이러면 누가 같은 태그를 덮어써도 다른 이미지로 뜨지 않는다.
3. `microvm_boot` 에는 태그 대신 digest 를 기록한다. `Image_changed` 도 digest 로
   비교한다. 서버를 재시작한 뒤에는 기록이 없으므로 `container list` 가 주는 실제
   digest 로 비교한다(#36993 의 image 축을 이 RFC 가 가져온다).
4. 실행 영수증, `masc_keeper_status` 의 `sandbox_live`, TUI 에는 세 값을 함께
   보여 준다: 목록 이름, 태그, **실제로 뜬 VM 의 digest**. §1.3 처럼 설정과 VM 이
   다를 때는 둘 다 보여서 그 차이가 드러난다.

Docker 프로필도 같은 목록을 쓴다. 컨테이너 이름에 태그 대신 digest 앞 12자를 넣는다.

### 2.5 이미지 구성

| 이름 | 부모 | 담는 것 | 근거 (§1.4) | 쓸 Keeper |
|---|---|---|---|---|
| `base` | Ubuntu 24.04 | 지금 `general` 의 도구 + `jq`, `file`, `xxd`, `time`, `iproute2`, `dnsutils`, `procps`, `make`, `python3-pip`, `python3-venv`, `python3-yaml` | `file` 12명, `ip` 계열 9명, `yaml` 15건, `jq` 27건 | 코드 빌드가 없는 Keeper |
| `ocaml` | `base` | 지금 `:local` 의 내용 전부 | `dune`·`opam` 24건 | masc 저장소에서 빌드·테스트하는 Keeper |
| `rust` | `base` | rustup 으로 고정한 stable 하나, `wasm32-unknown-unknown` target | `cargo`·`rustc` 14건 | rust-hwp-guy |
| `postgres` | `base` | `postgresql-client`, `python3-psycopg` | 16건 | wkbl 레인 |

- 부모는 Ubuntu 24.04 로 통일한다. 지금 `general` 은 Debian 이고 `:local` 은 Ubuntu
  라서, 두 이미지의 패키지 이름과 버전이 다르다.
- wkbl 레인은 node·pnpm 과 Postgres 가 함께 필요하다. `postgres` 를 `ocaml` 위에 쌓을지,
  node 만 담은 `web` 이미지를 따로 둘지는 §8 에 남긴다.
- Python `PIL`·`numpy`(msx-retro-mania 9건)는 이번 구성에 넣지 않는다. 한 Keeper 만
  쓰고, docker 프로필에서 돌았다. 요청이 다시 쌓이면 이미지를 하나 더 만든다.
- Rust toolchain 크기와 `ocaml` 위에 `postgres` 를 쌓았을 때 크기는 재지 않았다.
  Phase D 에서 빌드하며 잰다.

### 2.6 이미지 안의 도구 목록

`tools.toml` 이 이미지가 약속하는 도구를 적는다.

```toml
[tools.jq]
probe = ["jq", "--version"]

[tools.ocaml]
probe = ["ocaml", "-vnum"]
expect = "5.5.1"           # masc.opam 핀과 같아야 한다
```

- 빌드가 끝나면 그 이미지를 `--network none --read-only` 로 띄워 모든 `probe` 를
  실행한다. 하나라도 실패하거나 `expect` 와 다르면 빌드가 실패하고 태그를 남기지
  않는다.
- 실행 결과(도구, 버전 문자열)를 `/etc/masc/image.json` 에 담아 이미지의 마지막
  레이어로 굽는다. Keeper 는 VM 안에서 이 파일을 읽어 자기 도구를 확인한다.
  운영자는 `masc sandbox-image show <이름>` 과 `sandbox_live` 로 같은 내용을 본다.
- 지금 `scripts/check-sandbox-ocaml-version.sh`, `check-sandbox-dune-version.sh` 는
  Dockerfile 글자와 `masc.opam` 글자를 비교한다. 이미지를 빌드해서 확인하지는
  않는다. `expect` 를 `masc.opam`·`dune-project` 에서 읽어 채우면 두 스크립트가
  하던 일을 실제 이미지로 확인하게 되므로, 두 스크립트는 지운다.

### 2.7 빌드와 올리기

- `masc sandbox-image build <이름> [--runtime apple_container]` — `inputs` 만 담은
  컨텍스트로 빌드하고, §2.6 확인을 돌리고, 태그와 digest 를 출력한다. 목록은 고치지
  않는다.
- `masc sandbox-image promote <이름> <태그>` — 저장소에서 그 태그의 digest 를 읽어
  라이브 목록의 한 줄을 바꾸고, 바뀌기 전 값을 `previous` 에 남긴다. 설정 API 를
  거치므로 다른 설정 쓰기와 같은 CAS 규칙을 따른다. 바뀐 이미지는 각 Keeper 의
  다음 턴에 들어간다(§2.4 의 3).
- `masc sandbox-image rollback <이름>` — `ref`·`digest` 와 `previous` 를 맞바꾼다.
  새 이미지로 턴이 깨지면 운영자가 이 명령 하나로 되돌린다. 자동으로 되돌리지는
  않는다. 부팅 실패는 이미 typed 사유로 남으니, 사람이 그 사유를 보고 정한다.
- CI 는 `sandbox-images/**` 가 바뀌면 바뀐 이미지와 그 자식을 amd64·arm64 로 빌드하고
  §2.6 확인을 돌린다. 지금 `sandbox-image.yml` 이 `general` 에 하는 일을 모든
  이미지로 넓힌다. CI 가 만든 이미지를 운영 호스트에 가져오는 일은 이 RFC 에
  넣지 않는다(§3).

### 2.8 오래된 이미지 정리

- `masc sandbox-image prune` 은 목록의 `ref`·`previous` 어디에도 없고 떠 있는 VM 도
  쓰지 않는 `masc-sandbox-*` 이미지를 지운다. 지울 것을 먼저 보여 주고, `--yes` 가 있을 때만 지운다.
- 자동으로 지우지 않는다. "최근 N개만 남긴다" 같은 개수 기준도 두지 않는다.
  남길지는 목록이 정한다.

## 3. 하지 않는 것

- **턴 안 패키지 설치를 지원하지 않는다.** §1.5 처럼 Keeper 가 자기 폴더에 도구를
  까는 일은 지금도 가능하고 막지 않는다. 다만 그 경로를 위한 환경 변수나 폴더를
  만들지 않는다. 필요한 도구는 레시피에 넣고 버전을 올린다.
- **레지스트리에 올리지 않는다.** 이미지는 운영 호스트의 저장소에만 있다.
  CI 산출물을 호스트로 옮기는 일은 필요가 생기면 따로 다룬다.
- **Keeper 별 버전을 자동으로 올리지 않는다.** 목록을 바꾸는 건 운영자다.
- **§1.3 의 "턴 도중 설정 변경은 다음 턴부터" 동작은 바꾸지 않는다.** 그 사이의
  차이를 보이게 하는 것까지만 한다(§2.4 의 4).

## 4. 다른 선택지

| 선택지 | 좋은 점 | 나쁜 점 | 판단 |
|---|---|---|---|
| Keeper TOML 마다 전체 태그를 적는다 | 새 파일·새 개념이 없다 | 버전을 올릴 때 TOML 19개를 고쳐야 하고, 하나를 빠뜨리면 그 Keeper 만 옛 이미지에 남는다 | 버림. 같은 변환을 여러 곳에서 따로 하게 된다 |
| 태그는 그대로 두고 digest 만 비교한다(#36993) | 가장 작다 | 옛 버전으로 되돌릴 이름이 없고, 어떤 버전이 언제 쓰였는지 남지 않는다 | §2.4 에 흡수. 이것만으로는 부족하다 |
| 모든 도구를 넣은 이미지 하나 | 목록이 한 줄이다 | Rust·Postgres 가 모든 Keeper VM 에 들어간다. `:local` 이 이미 1.6GB 급이다 | 버림 |
| 턴 안 설치를 공식 지원한다(`/masc-work` 에 prefix) | Keeper 가 스스로 해결한다 | 무엇이 깔렸는지 재현할 수 없다. §1.5 의 opam 복사본 같은 것이 Keeper 마다 생긴다 | 버림(§3) |

## 5. 비슷한 제품 사례

모두 2026-09-24 에 1차 출처를 열어 확인했다.

| 설계 | 사례 | 무엇을 하나 | 출처 |
|---|---|---|---|
| §2.2 해시 태그 | Nixpkgs `dockerTools` | `tag` 를 비우면 derivation 해시를 태그로 쓴다. `created` 를 고정해 같은 입력이 같은 이미지를 만든다 | [dockertools.section.md](https://raw.githubusercontent.com/NixOS/nixpkgs/master/doc/build-helpers/images/dockertools.section.md) |
| §2.2 날짜 | GitHub Actions `runner-images` | 이미지 릴리스를 날짜로 부른다(`20260920.143`). 사용자는 `ubuntu-latest` 같은 움직이는 이름을 쓴다 | [actions/runner-images](https://github.com/actions/runner-images) |
| §2.2 덮어쓰기 금지 | Docker Hub immutable tags | 켜면 그 태그를 덮어쓰거나 지울 수 없다. 레지스트리가 막는다 | [docs.docker.com](https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/) |
| §2.2 `FROM` 고정 | Docker 빌드 권장 사항 | "Image tags are mutable". `FROM` 을 digest 로 고정하라고 권한다 | [best-practices](https://docs.docker.com/build/building/best-practices/) |
| §2.3 이름 → 버전 | Kustomize `images:` | 이미지 이름을 `newTag` 나 `digest` 로 바꿔 끼운다. 한 파일에서 바꾸면 모든 참조가 따라간다 | [kustomize images](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/) |
| §2.4 실제 digest 기록 | Kubernetes `ContainerStatus.imageID` | 스펙에 적은 이미지와 다를 수 있다고 명시하고, 런타임이 실제로 푼 값을 따로 보여 준다 | [pod-v1](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/) |
| §2.4 digest 가 바뀌면 교체, §2.7 되돌리기 | Podman `auto-update` | 떠 있는 컨테이너의 digest 와 저장소의 digest 가 다르면 다시 띄운다. 실패하면 이전 이미지로 자동으로 되돌린다 | [podman-auto-update](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html) |
| §2.4 digest 읽기 | Apple `container` | `image inspect` 가 `configuration.descriptor.digest`(index)와 `variants[].digest`(플랫폼별)를 준다. 소스 1.4.1 과 main `dc276ee` 에서 확인 | [ImageResource.swift](https://github.com/apple/container/blob/main/Sources/ContainerResource/Image/ImageResource.swift) |
| §2.5 공통 + 언어별 | Dev Container Features | 어떤 base 이미지 위에든 도구를 레이어로 얹는다. `devcontainer-lock.json` 이 feature 의 digest 를 고정한다(base 이미지는 고정하지 않는다) | [features](https://containers.dev/implementors/features/), [lockfile](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainer-lockfile.md) |
| §2.6 이미지를 실행해 목록 만들기 | `runner-images` `Generate-SoftwareReport.ps1` | 빌드한 이미지 안에서 `git --version` 같은 명령을 돌려 `software-report.json` 을 만든다. 레시피(`toolset-*.json`)와 결과를 따로 둔다 | [docs-gen](https://github.com/actions/runner-images/tree/main/images/ubuntu/scripts/docs-gen) |
| §2.6 | BuildKit SBOM | Dockerfile 이 아니라 마지막 이미지를 스캔해 SPDX 를 붙인다 | [sbom](https://docs.docker.com/build/metadata/attestations/sbom/) |
| §2.2 라벨 | OCI annotations | `created`, `version`, `revision`, `source`, `base.digest` | [annotations.md](https://github.com/opencontainers/image-spec/blob/main/annotations.md) |

반대 근거도 있다.

- **큰 운영자는 움직이는 이름을 택했다.** `runner-images` 는 사용자가 개별 빌드를
  고정할 수 없게 하고 `-latest` 를 1~2달에 걸쳐 옮긴다. 수많은 사용자를 한 이름으로
  모으는 데는 맞다. MASC 는 운영자 한 명이 Keeper 스무 명의 이미지를 고르고,
  §1.2 처럼 이름이 같은 채 내용이 바뀌어서 사고가 났다. 그래서 고정 쪽을 택한다.
- **에이전트 제품은 대개 이미지 버전을 관리하지 않는다.** `openai/codex-universal`
  은 여러 언어를 넣은 큰 이미지 하나를 `:latest` 로만 낸다
  ([README](https://github.com/openai/codex-universal)). Claude Code 의 dev container
  feature 버전은 설치 스크립트만 고정하고 CLI 버전은 고정하지 않는다
  ([devcontainer](https://code.claude.com/docs/en/devcontainer)). 샌드박스 digest 가
  바뀌면 VM 을 바꾸는 에이전트 제품은 찾지 못했다.
- **해시 태그는 읽기 어렵다.** Nix 는 이 비용을 받아들였고, devcontainers 이미지는
  `5.2.1-24` 처럼 semver 와 Node 버전을 붙인다. 이 RFC 는 날짜를 앞에 두어 언제
  빌드했는지는 읽히게 하고, 무엇으로 빌드했는지는 해시와 `/etc/masc/image.json`
  으로 확인하게 한다.
- **Podman 은 자동으로 되돌린다.** 이 RFC 는 되돌리기를 명령 하나로 두고 자동으로는
  하지 않는다(§2.7).

## 6. 단계

한 PR 이 20k token 을 넘지 않도록 나눈다. 앞 단계에 의존하면 stacked PR 로 올린다.

| 단계 | 내용 | 의존 |
|---|---|---|
| A | `sandbox-images/` 레시피와 `tools.toml`, 태그 계산, `masc sandbox-image build`, §2.6 확인 | — |
| B | `config/sandbox-images.toml` 파서와 타입, Keeper TOML 의 `sandbox_image` 를 이름으로 hard cut, env·내장 기본값 삭제, 배포 TOML 82개 변경 | A |
| C | 런타임이 digest 를 기록·비교, 상태·영수증·TUI 표시(#36993 image 축) | B |
| D | `rust`, `postgres` 이미지 추가, 크기 실측 | A |
| E | CI 가 모든 이미지를 빌드·확인 | A |
| F | `promote`, `rollback`, `prune` | B |

## 7. 확인 방법

- A: 레시피 입력 하나를 바꾸면 태그가 바뀌고, 안 바꾸면 같다. 같은 태그로 다시
  빌드하면 거절된다. `tools.toml` 에 없는 도구를 `probe` 에 넣으면 빌드가 실패한다.
- B: 목록에 없는 이름, 태그 문자열, 빈 digest 를 적은 Keeper TOML 은 로드가
  거절된다.
- C: 같은 태그를 다른 이미지로 덮어쓴 뒤 턴을 돌리면, VM 이 뜨지 않고 두 digest 를
  적은 거절이 남는다. 목록의 digest 를 바꾸면 다음 턴에 VM 이 바뀐다. 서버를
  재시작한 뒤에도 같다.
- 운영 실측: 목록을 바꾼 뒤 `container list` 의 digest 와 `sandbox_live` 의 digest 가
  모든 Keeper 에서 같은지 확인하고, TUI 스크린샷을 남긴다.
- 효과: 적용 2주 뒤 §1.4 와 같은 방법으로 다시 센다. 공통 도구 행이 0 이 되는지 본다.

## 8. 열린 질문

1. wkbl 레인은 node·pnpm 과 Postgres 가 함께 필요하다. `postgres` 를 `ocaml` 위에
   쌓을지, `web`(node+pnpm) 위에 쌓을지.
2. `/etc/masc/image.json` 을 Keeper 프롬프트에 넣을지, VM 안 파일로만 둘지.
   넣으면 매 턴 바이트가 늘고, 안 넣으면 Keeper 가 파일을 읽어야 안다.
3. Apple `container` 가 `ref@sha256:…` 형태로 실행을 받는지 확인하지 않았다.
   받으면 §2.4 의 2 에서 digest 로 직접 띄울 수 있다.
