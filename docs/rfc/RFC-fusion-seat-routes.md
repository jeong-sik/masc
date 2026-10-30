---
rfc: "fusion-seat-routes"
title: "Fusion seats name routes: failover per seat, per-run roster, typed editing"
status: Draft
created: 2026-09-22
updated: 2026-09-22
author: vincent
supersedes: []
superseded_by: null
related: ["0252", "0278", "0283", "0306", "cli-runtimes-as-lane-slots"]
---

# Fusion 자리는 경로 이름이다

## 1. 문제

Fusion 의 panel 한 명과 judge 는 각자 런타임 id 를 하나씩 들고 있다. 그 런타임이
막히면 넘어갈 곳이 없다. 운영자가 바꿀 곳도 `runtime.toml` 원문 하나뿐이다.

2026-09-22 에 잰 사실:

- 지금의 `trio` preset(09-18T23:01Z 부터)은 **5번 실행해 0번 성공**했다. 실패는
  전부 judge 자리 하나(`ollama_cloud.deepseek-v4-pro`)에서 났다.
  - 4번: 요청을 보내기 전에 masc 가 거절했다. 모델 행에
    `reasoning-uncontrolled = true` 만 있고 짝인 `thinking-control-format = "none"`
    이 빠져 있었다(live 설정은 09-22T09:20Z 에 고쳤다).
  - 1번: Ollama 주간 사용 한도.
- 그 전 14일 기록(15번)에서 `deepseek-v4-pro` 는 panel 로 나온 15번 중 12번
  실패했다(timeout 6, 사용 한도 2, 사전 거절 4). 같은 기간 `claude_code.claude-sonnet-5`
  panel 은 5번 중 0번 실패했다.
- judge 자리에 CLI 런타임을 적으면 매번 `Build_error` 였다. PR #37768 이 이것을 고친다.
- TUI 에는 Fusion 을 시작할 방법이 없다. 보기 전용이다.
- dashboard 설정 화면은 기본 preset 의 `enabled`·`default_preset`·`min_answered`·
  `panel`·`judge` 만 바꾼다. prompt·timeout·1차 judge·다른 preset 은 못 바꾼다.
  이 화면은 원문을 줄 단위로 고쳐 raw 저장하는데, raw 저장은 `[fusion]` 을 검사하지
  않는다. 틀린 값이 한 번 저장되면 그 뒤 모든 실행이 "fusion config invalid" 로
  막힌다. `[[...judges]]` 가 있는 preset 에서는 `min_answered` 를 엉뚱한 표 밑에
  붙인다.

## 2. 결정

### 2.1 자리는 경로 이름을 받는다

`panel = [...]`, `[[fusion.presets.<p>.panels]].models`, `judge`,
`[[fusion.presets.<p>.judges]].model` 의 값은 **경로 이름**이다. 경로 이름은 Keeper
배정과 똑같이 푼다: `Runtime.resolve_assignment`.

- `[runtime.lanes.<이름>]` 이 있으면 그 lane 이다. lane 이 먼저다.
- 없고 런타임 id 이면 후보 하나짜리 lane 이다. 지금 적힌 값은 전부 이 경우라 뜻이
  바뀌지 않는다.
- 둘 다 아니면 `Missing`, 카탈로그 행이 빠졌으면 `Unavailable` 이다. 둘 다 typed
  실패로 증거에 남는다. 기본 런타임으로 대신하지 않는다.

```toml
[runtime.lanes.fusion-judge]
candidates = [
  "ollama_cloud.deepseek-v4-pro",
  "claude_code.claude-sonnet-5",
]

[fusion.presets.trio]
panel = ["ollama_cloud.ollama-cloud-kimi-k3", "ollama_cloud.deepseek-v4-pro", "claude_code.claude-sonnet-5"]
judge = "fusion-judge"
```

HTTP 런타임과 CLI 런타임(Claude Code·Codex·Antigravity)은 같은 후보 목록에 섞어
적는다. exact-output lane 처럼 `slots` 와 `cli_slots` 를 나누지 않는다. exact lane 은
HTTP 요청 본문을 만드는 경로와 CLI 경로가 달라서 나눴지만, Fusion 은 두 종류를
이미 자리마다 같은 방식으로 실행한다.

panel 정체성(`panelist_id`)은 지금처럼 라벨 + 적힌 값이다. lane 을 적으면 lane
이름이 정체성이 된다. 실제로 답한 런타임은 정체성과 따로 기록한다(2.3).

### 2.2 자리 안에서 후보를 차례로 시도한다

한 자리는 후보를 적힌 순서로 하나씩 시도하고, 쓸 수 있는 답이 나오면 멈춘다.

- panel: 비어 있지 않은 글이 나오면 답이다.
- judge: `Fusion_judge_parse.of_string` 을 통과한 종합이 나오면 답이다. 파싱 실패도
  다음 후보로 넘어간다.
- 실패는 종류와 상관없이 다음 후보로 넘어간다. Fusion 자리는 질문에 답만 하고 밖에
  효과를 남기지 않으므로, Keeper 턴처럼 "효과가 났을 수 있는 실패" 를 가를 필요가 없다.
- timeout 은 후보 한 번에 적용한다. 자리 전체에 걸리는 새 시간 제한은 만들지 않는다
  (헌법: Fusion 은 fan-out timeout 을 합성하지 않는다).
- 실패한 시도가 쓴 토큰도 그 자리의 usage 에 더한다.
- 자리들은 지금처럼 동시에 돈다. 한 자리 안의 후보만 차례로 돈다.

### 2.3 증거는 누가 답했고 누구를 거쳤는지 남긴다

- `panel_answer` 에 `runtime`(답한 후보)과 `failed_attempts`(그 전에 실패한 후보들)를
  더한다.
- `panel_error` 에 `attempts`(시도한 후보 전부, 순서대로)를 더한다. `reason` 은 마지막
  시도의 실패다.
- `judge_node` 와 `judge_error_node` 도 같은 두 칸을 갖는다.
- 경로를 못 푼 자리는 새 갈래 `Unknown_route` / `Route_unavailable` 로 실패한다.
- Board meta 와 dashboard·TUI 상세는 "X 가 답함 (Y·Z 실패 뒤)" 를 보여준다.

기존 실행 기록은 새 형식으로 읽히지 않는다. 헌법의 `legacy_residue` 대로 호환
reader 는 만들지 않는다. 이전 실행의 상세는 replay gap 으로 보인다.

### 2.4 실행마다 명단을 바꿀 수 있다

`masc_fusion` 도구와 `POST /api/v1/keepers/<name>/fusion` 이 두 칸을 더 받는다.

- `judge`: 경로 이름 하나. preset 의 judge 자리를 이번 실행만 바꾼다.
- `panel`: 경로 이름 목록. preset 의 panel 명단을 이번 실행만 바꾼다. 새 명단은
  그룹 하나이고, prompt·web_tools·출력 예산·timeout 은 preset 첫 그룹 값을 쓴다.

나머지(prompt, `min_answered`, 1차 judge, topology 규칙)는 preset 그대로다.

- 경로는 제출할 때 푼다. 못 푸는 이름은 실행을 만들지 않고 typed 로 거절한다.
- 바꾼 명단으로 preset 검사(`Validated_preset.of_preset`)를 다시 돌린다.
  `min_answered` 가 새 명단보다 크면 거절한다. 조용히 줄이지 않는다.
- 실제로 쓴 명단(judge 경로, panel 경로들)을 실행 기록과 전달 약속
  (`Fusion_delivery_obligation`)에 적는다. 서버가 다시 떠도 같은 명단으로 이어간다.
- JOJ 1차 judge 명단은 이 RFC 에서 바꾸지 않는다.

### 2.5 설정은 typed 로 편집한다 (RFC-0306 이어받기)

- **쓰기 API.** `POST /api/v1/runtime/config/fusion`(CanAdmin). preset 만들기·고치기·
  지우기·이름 바꾸기와 `enabled`·`default_preset`·`staged_judge_group_size` 를 받는다.
  preset 의 모든 칸(그룹, 라벨, prompt, web_tools, 출력 예산, timeout, judge 자리,
  1차 judge, `min_answered`)을 쓴다. `Toml_line_editor` 로 주석을 지키며 고치고,
  저장 전에 파일 전체를 `Runtime.validate_config_text` 와 `Fusion_config.of_toml` 로
  검사하고, 모든 자리의 경로를 `Runtime.resolve_assignment` 로 푼다. 실패는
  `Fusion_config.config_error` 갈래를 그대로 JSON 으로 돌려준다.
- **raw 저장도 `[fusion]` 을 검사한다.** `POST /api/v1/runtime/config/raw` 와 preview 가
  `Fusion_config.of_toml` 을 돌린다. 틀린 `[fusion]` 은 저장되지 않는다.
- **lane 은 기존 routing API 로 고친다.** 새 lane 편집기를 만들지 않는다.
- **dashboard.** 줄 단위로 고치던 `fusion-settings.ts` 쓰기를 지우고 쓰기 API 위의
  구조화 폼으로 바꾼다. 자리 고르기 목록은 런타임 카탈로그와 lane 목록에서 온다.
  저장 뒤 typed 설정을 다시 읽는다. 실행 폼에 judge·panel 바꾸기를 더한다.
- **TUI.** Fusion 화면에서 새 실행을 시작하는 폼(Keeper, preset, topology, 질문,
  web_tools, judge·panel 바꾸기)과 preset 편집 화면을 더한다. 둘 다 위 API 를 쓴다.

## 3. 하지 않는 것

- 사용 한도가 찬 런타임을 뒤로 미루는 순서 조정. 한도 거절은 빨리 돌아오므로
  첫 판에서는 적힌 순서대로 시도한다. 실측에서 느리면 따로 다룬다.
- JOJ 1차 judge 의 실행별 바꾸기.
- CLI judge 의 출력 schema 채널(`--json-schema`, `outputSchema`).

## 4. PR 순서

| 순서 | 내용 | 기반 |
|---|---|---|
| 1 | CLI 런타임 judge (#37768) | main |
| 2 | 이 RFC | main |
| 3 | 자리 경로 풀기 + 후보 차례 시도 + 증거 칸 | 1 |
| 4 | 실행별 명단 바꾸기 (도구·HTTP·실행 기록·전달 약속) | 3 |
| 5 | typed 쓰기 API + raw 저장의 `[fusion]` 검사 | main |
| 6 | dashboard 구조화 편집 폼 + 실행 폼 바꾸기 + 증거 표시 | 4, 5 |
| 7 | TUI 실행 폼 + preset 편집 화면 + 증거 표시 | 4, 5 |

## 5. 검증

- 3: judge lane 의 첫 후보가 실패하고 둘째가 답하는 입력, 전부 실패하는 입력,
  lane 이 아닌 런타임 id 입력이 서로 다른 증거를 내는지 본다. 첫 후보가 답하면
  둘째는 실행되지 않는지 가짜 CLI 표식으로 본다.
- 4: 바꾼 명단이 실행 기록과 전달 약속에 남고, 재시작 뒤 복원에서도 같은 명단이
  쓰이는지 본다. 못 푸는 경로와 `min_answered` 초과는 실행을 만들지 않는지 본다.
- 5: 각 편집(그룹 추가·삭제, 1차 judge 추가·삭제, preset 이름 바꾸기)에서 주석 줄이
  바이트 그대로인지 본다. 틀린 `[fusion]` 이 raw 저장에서 거절되는지 본다.
- 6·7: 배포 뒤 dashboard 브라우저 스크린샷과 TUI PTY 시나리오로 preset 편집 → 실행 →
  "답한 후보" 표시까지 한 바퀴를 남긴다.
- 배포 뒤 `trio` 를 judge lane(`deepseek-v4-pro` → `claude_code.claude-sonnet-5`)으로
  바꿔 실제 실행 기록을 남긴다.
