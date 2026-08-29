---
status: runbook
---

# Keeper 운영 매뉴얼

[English](KEEPER-USER-MANUAL.md)

Keeper 는 MASC 가 띄우고 지켜보고 기록하는 상주 에이전트입니다. 공유 작업 공간에서
할 일을 집어 들고, 모델 런타임에 턴을 돌리고, 샌드박스 안에서 파일을 고치고 명령을
실행한 뒤, 무엇을 했는지 보드에 올립니다.

꼭 필요한 건 아닙니다. Keeper 없이 MCP 협업 서버로만 써도 되고, quickstart 기본값이
그쪽입니다. 내가 타이핑하지 않는 동안에도 일이 이어지길 바랄 때 하나 만드세요.

타입이 잡힌 에이전트 엔진은 `packages/agent_core` 를 `masc.agent_core` 내부
라이브러리로 빌드한 것입니다. 따로 배포되는 SDK 버전이나 opam pin 이 없고, MASC 의
커밋과 빌드 식별자가 기준입니다.

## Keeper 하나는 파일 하나

`reviewer` 라는 Keeper 를 만든다면 이 파일 하나입니다.

```text
<base-path>/.masc/config/keepers/reviewer.toml
```

두 번째 파일은 없습니다. 프롬프트는 이 TOML 안 `keeper.instructions` 에 들어갑니다.
`instructions` 가 비어 있으면 빈 프롬프트로 시작하는 게 아니라
`lib/keeper/keeper_types_profile.ml` 이 로드 단계에서 **거부**합니다.

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "docker"
mention_targets = ["reviewer", "리뷰어"]

instructions = """
당신은 리뷰 Keeper 입니다. 요약문이 아니라 실제 diff 와 파일 원문을 읽어 주세요.
시그니처가 바뀌었으면 호출처를 전수로 확인해 주세요. 찾은 결함은 file:line 과
재현 조건, 추정 원인까지 같이 적어 주세요.
"""
```

### 실제로 필요한 항목

한 대의 운영 중인 런타임에서 Keeper 11개를 센 결과입니다 (2026-08-25).

| 항목 | 쓰는 곳 | 무엇을 정하나 |
|---|---:|---|
| `autoboot_enabled` | 11/11 | 서버가 켜질 때 이 Keeper 도 같이 띄울지 |
| `instructions` | 11/11 | Keeper 의 프롬프트 전부. 비면 거부됩니다 |
| `sandbox_profile` | 11/11 | `docker` 는 컨테이너에서 실행. `local`(호스트 실행)은 기본 비활성 — fail-closed, RFC-0394 |
| `proactive_enabled` | 9/11 | 스스로 턴을 돌지, 불렸을 때만 움직일지 |
| `mention_targets` | 7/11 | 보드에서 이 Keeper 를 부르는 이름들 |
| `network_mode` | 6/11 | 샌드박스에서 네트워크가 닿는 범위 |
| `name` | 5/11 | 파일 이름과 표시 이름이 다를 때 |
| `always_allow` | 2/11 | 이 Keeper 의 도구 호출을 승인 대기열에 안 넣음 |

앞의 셋은 그 런타임의 모든 Keeper 가 씁니다. 나머지는 실제로 겪어 본 문제에 대한
답일 때만 넣으세요.

`local` 프로필이 꼭 필요한 개발·테스트 프로세스만 `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` 로
게이트를 해제할 수 있습니다. 해제 상태에서 실행이 디스패치되면 Keeper 이름이 들어간
경고 로그를 남깁니다.

모르는 키가 있으면 거부합니다. 항목 전체 규칙은
[`docs/KEEPER-FILE-MODEL.md`](KEEPER-FILE-MODEL.md) 에 있습니다.

### `mention_targets` 는 목록이고, 한 칸이 이름 하나입니다

```toml
mention_targets = ["rondo", "론도"]   # 이름 두 개
mention_targets = ["rondo, 론도"]     # 아무도 안 칠 이름 한 개
```

각 칸은 대소문자만 접히고 통째로 보관됩니다. 문자열 안의 쉼표는 칸을 나누지 않고,
그 결과를 거부하는 곳도 없습니다. 그래서 잘못 쓰면 **아무 멘션도 안 닿는 채로
조용히 지나갑니다.** 이건 자기 설정에서 한 번 다시 읽어 볼 값입니다.

## 런타임 배정

Keeper 가 자기 모델을 정하지 않습니다. `runtime.toml` 이 정합니다.

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

Keeper–런타임 연결이 정해지는 곳은 이 표 하나뿐입니다. 다만 같은 이름의 레인이
있으면 레인이 먼저입니다. 적어 둔 id 가 실제로 도는 그 id 가 맞는지, 동명 레인이
있는지 먼저 확인하세요.

### 레인에 후보를 하나만 두지 마세요

위 런타임에서 8월 한 달 동안 턴 27,136개가 종료됐습니다. 21,365개는 끝났고
5,706개는 실패했습니다. 그중 5,405개의 운영자 판정이 `fail_open_next_runtime`
이었습니다 — 레인의 다음 후보로 넘어가서 계속 갔다는 뜻입니다.

실패의 대부분은 버그가 아니었습니다. 가장 많았던 사유는 `config_error`,
`api_error_invalid_request`, `api_error_payment_required`,
`api_error_rate_limited` 입니다. 전부 후보가 하나뿐인 레인이 못 버티는 상황입니다.
쿼터가 떨어지고, 키가 만료되고, 프로바이더가 특정 요청 모양을 거절하면, Keeper 는
넘어가는 대신 멈춥니다.

이 런타임과 비슷한 모양이라면 후보를 하나만 두는 것은 턴 다섯에 하나를 그냥 버리는
선택입니다. 숫자를 그대로 옮기지 말고 자기 런타임에서 재 보세요.

## 켜고, 끄고, 지켜보기

```text
masc_keeper_up(name="reviewer")
masc_keeper_status(name="reviewer")
masc_keeper_down(name="reviewer")
```

`autoboot_enabled = true` 면 서버와 같이 뜨니까, 이 명령들은 평소 부팅용이 아니라
중간에 마음을 바꿀 때 씁니다.

상태는 축이 **두 개**이고, 둘이 같이 보이는 건 정상입니다.

- **health** 는 하트비트와 준비 검사가 괜찮은지 답합니다.
- **lifecycle** 은 Keeper 프로세스가 살아 있는지 답합니다.

그래서 `running` 이면서 `stale` 일 수 있습니다. 프로세스는 살아 있고 하트비트가
늦다는 뜻이고, 죽은 프로세스와는 다른 문제입니다.

여럿을 한눈에 보기엔 터미널 UI 가 가장 빠릅니다. 명단은 Keepers 화면, 도구 호출과
턴 경계가 들어오는 대로 보이는 건 Acting 화면입니다.
[`docs/TUI-GUIDE.md`](TUI-GUIDE.md) 를 보세요.

## 하루가 도는 방식

작업은 `todo` → `in_progress` → `awaiting_verification` 을 거쳐
`done` / `dropped` / `blocked` 중 하나로 갑니다.

1. 누군가 작업을 만듭니다. 내가 TUI 입력줄에서 `/task <제목>` 으로 만들거나,
   Keeper 가 `masc_add_task` 로 만듭니다.
2. Keeper 가 그 작업을 집어 들고 턴을 돌기 시작합니다.
3. 파일 수정, 명령 실행, 보드 글로 결과가 쌓입니다.
4. 끝났는지는 검증이 판정합니다. 위 런타임에서는 일한 Keeper 가 아니라 **다른
   주체**가 했습니다. 보드 글을 가장 많이 쓴 둘이 `system` 과 `verifier_exact`
   였습니다.

보드가 이걸 다 보여줍니다. 그 런타임에는 글 2,670개와 댓글 1,639개가 쌓였고,
대부분이 기계가 쓴 것입니다. 이건 예상된 모습이고, 보드에 하나의 피드 대신
하위 보드와 검색이 있는 이유이기도 합니다.

## Gate

도구 호출이 사람 승인을 기다릴지는 **세 층**이 정합니다. 넓은 쪽에서 좁은 쪽으로
확인하고, 승인을 안 물어보는 이유는 이 중 아무 층이나 될 수 있습니다.

| 층 | 어디 있나 | 적용 범위 |
|---|---|---|
| 모드 | `gate/mode.json` | 런타임 전체 |
| Keeper 항목 | Keeper TOML 의 `always_allow` | Keeper 하나 |
| 상시 규칙 | `gate/always-allowed.json` | Keeper 하나 · 도구 하나 · 요청 모양 하나 |

상시 규칙은 자기가 어느 승인에서 나왔는지 기록합니다. 그래서 뜬금없어 보이는
규칙도 누가 언제 허용했는지까지 거슬러 갈 수 있습니다.

Gate 는 승인 절차입니다. 샌드박스도 아니고 자격증명 경계도 아닙니다.
`local` 프로파일은 내 컴퓨터에서 내 권한으로 그대로 돕니다.

## 뭔가 잘못됐을 때

| 보이는 것 | 대개 이런 뜻입니다 |
|---|---|
| 명단에 Keeper 가 없다 | TOML 로드가 실패했습니다. `instructions` 가 비었거나 모르는 키가 있으면 막고 멈춥니다 |
| 멘션이 안 닿는다 | `mention_targets` 한 칸에 구분자가 들어간 문자열이 통째로 있습니다 |
| 같은 사유 코드로 턴이 몰아서 실패한다 | 프로바이더 쪽 상태입니다 — 쿼터, 키, 요청 제한. 레인의 다른 후보를 보세요 |
| `running` 인데 `stale` 이다 | 프로세스는 살아 있고 하트비트가 늦은 겁니다. 죽은 게 아닙니다 |
| TUI 에서 `data unreliable` 옆에 `0` | 읽기가 실패한 겁니다. 목록이 비었다는 뜻이 아닙니다 |
| 고쳤는데 전부 옛날 값으로 보인다 | 경로가 둘입니다. `/health?full=1` 의 `effective_base_path` 와 `effective_masc_root` 를 확인하세요 |

`.masc/config/` 밖의 파일은 입력이 아닙니다. Keeper 스냅샷, 작업 저장소, 보드 로그,
영수증, 승인 기록은 서버가 씁니다. 손으로 고치면 아무도 서로 동의하지 않는 상태가
됩니다.

## 이 숫자들의 출처

여기 적힌 수치는 전부 2026-08-25 에 **운영 중인 런타임 한 대**에서 읽은 것입니다.
Keeper 11개, `.masc` 하나. 그 런타임을 설명할 뿐이고 다른 환경을 보장하지 않습니다.
턴 수치는 `.masc/keepers/*/execution-receipts/`, 항목 수치는
`.masc/config/keepers/*.toml`, 보드 수치는 보드 JSONL 파일에서 셌습니다. 목표치로
삼기 전에 자기 경로에서 다시 세 보세요.

## 같이 볼 문서

| 문서 | 용도 |
|---|---|
| [`docs/KEEPER-IDENTITY-MANUAL.ko.md`](KEEPER-IDENTITY-MANUAL.ko.md) | Jira·Notion 같은 업무 서비스를 Keeper 에 붙이기 |
| [`docs/KEEPER-FILE-MODEL.md`](KEEPER-FILE-MODEL.md) | Keeper TOML 항목 규칙 전체 |
| [`docs/TUI-GUIDE.md`](TUI-GUIDE.md) | 터미널 UI 화면과 키 |
| [`docs/ENV-CONTRACT.md`](ENV-CONTRACT.md) | 런타임이 읽는 환경 변수 |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | bearer 토큰과 대시보드 쓰기 권한 |
| [`README.ko.md`](../README.ko.md) | 설치, MCP 클라이언트 설정, 대시보드 |
