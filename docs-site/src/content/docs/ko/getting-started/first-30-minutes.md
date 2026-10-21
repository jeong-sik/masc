---
title: 처음 30분
description: MASC 설치부터 첫 Keeper, 첫 Task, Board 읽기까지 — 각 단계가 되었는지 알려 주는 신호와 함께.
---

[빠른 시작](/ko/getting-started/quickstart/)을 마치면 설치와 `imp` 대화가 됩니다.
이 장은 그다음 20분입니다. 일을 맡기고, 결과를 찾고, Keeper 를 하나 더 두고,
Board 를 읽고 쓰는 것까지 해 봅니다. 각 단계 끝에는 *이것이 보이면 다음으로*
라는 신호를 적었습니다. 그것이 보이지 않으면 그 단계의 문제 해결 항목을 봅니다.

## 1. 설치와 첫 실행

1. 최신 설치 스크립트를 받고, 다운로드에 성공한 경우에만 실행합니다. 설치기는 `SHA256SUMS` 를 검증하고,
   실행 파일과 브라우저 대시보드를 설치하며, 설정 마법사를 제안합니다.

   ```bash
   curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
     -o /tmp/masc-install.sh &&
   bash /tmp/masc-install.sh
   ```

   - 바이너리 설치에는 OCaml 이나 Node.js 개발 도구가 필요하지 않습니다.
   - 기본 설치 위치는 `~/.local/bin` 입니다. `PATH` 에 없으면 이 터미널에서
     `export PATH="$HOME/.local/bin:$PATH"` 로 추가합니다.
2. 모델 접근을 준비합니다. 지원하는 CLI 로그인, API 키, 접근 가능한 로컬 모델
   서버 중 하나가 필요합니다. 설정 화면에서 Docker, 지원되는 microVM, 원격 SSH 중
   실행 환경을 고르고 준비합니다. Docker를 미리 설치할 필요는 없습니다.

**다음으로 가는 신호:** `masc --help` 가 명령 목록을 출력합니다.
**막히면:** 설치 위치가 `PATH` 에 없는지 먼저 봅니다. 기본 위치는 `~/.local/bin` 입니다.

## 2. 첫 Keeper

1. 마법사가 열리지 않았다면 직접 실행합니다.

   ```bash
   "$HOME/.local/bin/masc" setup
   ```

   `--prefix`를 바꿨다면 그 실행 파일 경로를 사용합니다. setup은 설치 때 선택한
   작업 공간을 사용합니다. 직접 지정하려면 같은 디렉터리로
   `--base-path /path/to/your/workspace`를 덧붙이세요. 선택한 모델과 샌드박스를
   확인하고, 서버와 `imp`를 준비하며 선택적 호스트 도구를 안내한 뒤 TUI를 엽니다.
2. 첫 Keeper는 `imp`입니다. 설정 화면에서 실행 환경을 고르기 전 새 설정의
   기본값은 `activation_mode = "manual"`, `sandbox_profile = "docker"`,
   `sandbox_image = "base"`, `network_mode = "inherit"`입니다.
   설정 중 다른 샌드박스를 선택할 수 있습니다.

**다음으로 가는 신호:** TUI 가 열리고 `imp` 의 채팅 입력란이 보입니다.
**막히면:** `masc doctor --base-path <dir>` 로 준비 상태를 봅니다. Keeper 가 멈춘
것처럼 보이면 대개 승인을 기다리는 중입니다. TUI 의 Approvals 화면을 봅니다.

### Keeper 하나 더 두기

`imp` 혼자서는 협업이 보이지 않습니다. 역할이 다른 Keeper 를 하나 더 둡니다.
**먼저 넷이 서 있어야 합니다. 순서대로입니다.**

1. 서버가 떠 있습니다(`masc setup`). 띄운 직후 몇 초 동안은
   `{"error":"not initialized"}`(HTTP 503)가 납니다. 인증 실패가 아니니 잠시 뒤
   다시 하세요.
2. 이 작업공간에 로그인돼 있습니다(`masc login`). 아니면
   `[AuthError] Unauthorized ... Run masc login for this workspace, or pass --token.`
   이 납니다.
3. 모델이 연결돼 `runtime.toml` 에 `[runtime].default` 가 있습니다. 아니면
   `Model setup required ... [runtime].default is required` 가 납니다.
4. 고른 이미지가 컨테이너 런타임에 승격돼 있습니다. 아니면
   `sandbox_image_unresolved: nothing is promoted for "base"` 가 납니다.
   `masc sandbox-image --recipe base` 로 만든 뒤, 출력된 태그로
   `masc sandbox-image promote base <tag>` 를 합니다. Docker 같은 컨테이너
   런타임이 필요합니다.

리뷰어 하나를 두는 최소 예시입니다.

```bash
masc keeper-create \
  --name reviewer \
  --instructions "열린 PR 의 바뀐 코드를 읽고, 고칠 점을 파일:줄과 함께 Board 에 남긴다." \
  --sandbox-profile docker \
  --sandbox-image base \
  --network-mode none
```

꼭 정해야 하는 것은 셋입니다. 빠지면 서버나 명령이 거절하고 아무것도 만들지
않습니다.

- `--sandbox-profile`: `docker`, `microvm`, `remote_ssh` 중 하나.
- `--sandbox-image`: `docker`·`microvm` 일 때 필수. `config/sandbox-images.toml`
  의 이름입니다. `base` 에는 언어 도구가 없으니, 코드를 빌드할 Keeper 는
  `ocaml` 처럼 도구가 든 이미지를 고릅니다.
- `--network-mode`: `none`(망 없음, 웹 검색·`git push` 실패), `inherit`(호스트 망
  사용), `policy`(`egress_allow` 목록의 목적지만). 웹을 볼 Keeper 를 `none` 으로
  만들면 검색이 실패합니다.

모델은 이 명령으로 정하지 않습니다. 작업공간의 `runtime.toml` 이 정합니다.

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

같은 이름의 레인이 있으면 레인이 우선합니다. 같은 이름으로 다시 만들면 새로 만들지
않고 설정을 바꿉니다. `--sandbox-profile` 과 `--network-mode` 는 매번 덮어쓰고,
`--instructions` 는 비워 두면 보내지 않아 원래 글이 남습니다. 설정 파일은
`.masc/config/keepers/<이름>.toml` 에 있습니다.

## 3. 첫 Task

TUI 입력줄에 이렇게 칩니다.

```
/task 내 샌드박스의 파일 목록을 정리해 Board 에 올리기
```

`/task` 는 Task 를 만들고, 고른 Keeper 에게 보냅니다. Keeper 는 그 Task 를 맡습니다.
Task 상태는 `todo` → `claimed` → `in_progress` → `awaiting_verification` 으로
움직입니다.

- **진행 상황:** `Tab` 으로 **Work** 화면에 가면 Task 목록과 상태가 보입니다.
- **결과:** **Keepers → imp** 대화에서 답과 도구 실행 결과를 펼쳐 봅니다.
- **승인 요청:** Keeper 가 사람의 승인을 기다리면 **Approvals** 에 쌓입니다.

> Task 는 서버에 등록된 Keeper 에게만 만들어집니다. `keepers/` 폴더에 파일만 있는
> Keeper 를 고르면, TUI 가 "created" 라고 말해도 실제로는 생기지 않고 같은 화면에
> `Keeper owner not found` 가 뜹니다. 설치가 만든 `imp`, 또는 위 `masc keeper-create`
> 로 만든 Keeper 를 고르세요.

Task 완료는 Keeper 가 선언하지 않고 검증자가 판정합니다.
[Goal](https://github.com/jeong-sik/masc/blob/main/docs/spec/00-glossary.md) 은 장기
의도를 Task 에 잇는 단위이고, 검증을 통과한 뒤 사람이 최종 확인해야 완료됩니다.

**다음으로 가는 신호:** Task 가 목록에 보이고 상태가 바뀝니다.

## 4. Board 와 위키

[Board](https://github.com/jeong-sik/masc/blob/main/docs/spec/00-glossary.md) 는
Keeper 들과 운영자가 함께 읽는 곳입니다. **Board** 화면에서:

| 키 | 하는 일 |
|---|---|
| `Enter` | 글 열기 |
| `w` | 새 글. 첫 줄이 제목, 나머지가 본문. `Esc` 를 누르면 `s`(보내기)·`d`(버리기)를 고릅니다 |
| `c` | 열린 글에 댓글 |
| `v` / `V` | 찬성 / 반대. 한 번 누르면 준비, 같은 키를 한 번 더 누르면 보냅니다 |
| `s` | 정렬 바꾸기 |

Keeper 를 부르려면 글이나 댓글에 `@이름` 을 씁니다.

[위키](https://github.com/jeong-sik/masc/blob/main/docs/spec/00-glossary.md)는 사람과
Keeper 가 함께 쓰는 공유 페이지이고, Keeper 개인 기억과 다릅니다. 여러 번 쓸 지식은
Keeper 에게 이렇게 부탁해 한 장으로 남깁니다.

> 지금 정리한 내용을 위키에 "프로젝트 지도" 라는 페이지로 써 줘.

**다음으로 가는 신호:** 방금 올린 글이 Board 목록에 보입니다.

## 5. 브라우저 레인 (필요할 때만)

웹 페이지 내용만 가져오는 일은 브라우저 없이 됩니다(`WebFetch`). 로그인한 사이트를
보거나 클릭해야 할 때만 브라우저 레인이 필요합니다.

- 화면: `:` 를 누르고 `go Browser Lane` 을 칩니다.
- 설치: 설치 과정의 "5 · Give imp tools (optional)" 체크리스트에서 브라우저 줄을
  표시해 두면 `geckodriver` 와 Firefox 를 찾고, 없으면 설치 메뉴를 보여 줍니다.
  아니면 서버 시작 전에 `masc browser-lane-setup --mode automation` 을 실행합니다.
  평소 쓰는 Firefox 를 연결하는 BiDi 줄과 부가 기능(add-on) 줄은 처음에 표시되어
  있지 않으니 필요할 때만 고릅니다. 설치를 이미 끝냈다면 같은 명령을 직접 실행하고
  서버를 다시 시작합니다.
- 레인이 꺼져 있으면 Browser Lane 화면에 이런 줄이 보입니다.
  - `Live lane off in runtime.toml · it serves nothing, MASC starts nothing` —
    `runtime.toml` 의 `[browser.live] enabled = false` 때문입니다. 이 값을 고친 뒤
    서버를 다시 시작합니다.
  - `No active native browser connections` — 목록을 읽었고, 연결된 Firefox 가
    없습니다.
  - `(nothing here is a reading)` — 목록을 읽지 못했습니다. 바로 위의 빨간 줄이
    이유입니다.

## 막혔을 때

- `masc doctor` — 같은 작업 공간의 준비 상태를 한 번에 보여 줍니다.
- **Approvals** — Keeper 가 멈춘 것처럼 보이면 대개 승인을 기다리는 중입니다.
- 더 자세한 키와 화면은 [터미널 UI 가이드](/ko/guides/tui/)에 있습니다.
