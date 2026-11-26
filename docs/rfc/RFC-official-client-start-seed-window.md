---
rfc: "official-client-start-seed-window"
title: "Cut an official client's fresh-session seed to the runtime window only where the Librarian has read"
status: Draft
created: 2026-11-21
updated: 2026-11-21
author: vincent
related: ["keeper-context-window-in-tokens", "librarian-lifecycle"]
---

# RFC: 공식 클라이언트의 새 세션 첫 메시지는 Librarian 이 읽은 자리에서만 창에 맞춰 자른다

- 상태: Draft. §1 은 운영자가 정할 것, §2~§4 는 실측과 지금 코드, §5 는 제안, §6 은 열린 질문, §7 은 켜기 전 판정 기준이다.
- 코드 기준: origin/main `cca8f352d558`. 실측: 2026-11-21 운영(`~/me`), 빌드 `453be664` → `57ed971f`(13:48:10Z 재시작).
- 관련: `RFC-keeper-context-window-in-tokens.md`(이하 창 RFC), `RFC-librarian-lifecycle.md`, #54320.

## 1. 정할 것 (운영자)

1. 공식 클라이언트(Claude Code, Codex 등)가 새 세션을 열 때도 masc 가 runtime 의 `max-context` 로 첫 메시지를 줄이는가.
2. 줄인다면, 버리는 자리는 Librarian 이 읽은 끝(`Librarian_point_at_max_context`)일 때만인가. 턴 경계(`Turn_start_at_max_context`)에서도 자르는가.
3. 켜는 때는 Librarian 컷을 설치한 뒤인가.

이 RFC 의 제안은 1 = 예, 2 = Librarian 지점일 때만, 3 = 컷 설치 뒤다(§5).

## 2. 무슨 일이 있었나

Claude Code 구독 Keeper 가 토큰을 많이 썼다. 원인은 둘이었다.

**이어 쓰는 세션 (#54320 이 고쳤다).**
- 운영 Claude Code 바인딩 26개가 모두 `max-context = 400000` 을 적는다. 그런데 CLI 는 창 값 없이 떠서, 1M 모델 기본값인 약 967K 에서 압축했다.
- #54320 이 해결된 창을 `--autocompact <tokens>` 로 넘긴다. runtime 마다 다른 값이고, 지금은 모두 400,000 이다.
- 같은 집계로 잰 값은 아래와 같다. 요청 하나의 문맥은 input + cache_read + cache_creation 토큰이다. 초과는 그 요청을 보낸 runtime 의 창과 비교했다.

| 구간 (UTC) | 요청 | 요청당 평균 | p90 | 자기 창 초과 | 압축 |
|---|---|---|---|---|---|
| 11:48~13:48 (배포 전) | 298 | 506K | 768K | 67% | 2 |
| 13:48~14:22 (배포 뒤) | 50 | 164K | 352K | 8% | 3 |

배포 뒤 구간은 34분이라 표본이 작다. 시간당 요청 수도 149 → 88 로 달라서 시간당 토큰은 비교하지 않는다.

**새로 여는 세션 (이 RFC).**
- 배포 뒤 창을 넘은 요청 4건은 모두 한 Keeper(아래 Keeper A)가 새로 연 세션 둘의 요청이다(594K, 595K, 599K, 599K). 첫 메시지(seed)는 메시지 498개다.
- CLI 는 첫 요청을 보내기 전에 압축하지 않는다. 그래서 `--autocompact` 는 새 세션에 아무 일도 못 한다.
- 11-21 하루 Claude Code 새 세션 18건 중 6건이 첫 요청부터 자기 창(400,000)을 넘었다: Keeper A 444K·594K·599K, Keeper B 570K·615K, Keeper C 445K.

## 3. 지금 코드

- `Keeper_turn_driver_try_provider.input_limit_of_runtime` 은 Agent Core 와 ACP(`Acp _`)에 입력 상한을 준다. ACP 의 상한은 운영자가 선언한 창이다. `Codex_app_server`, `Antigravity_cli`, `Claude_code` 는 `None` 이다.
- `past_max_context` 는 `input_limit` 이 `None` 이면 바로 `None` 이다. 시작점이 움직이지 않고, seed 는 carried range 전체다.
- `past_max_context` 는 `Keeper_model_input_ledger` 의 `next_turn_peak` 이나 `last_input_tokens` 로 창을 넘었는지 본다. 이 원장을 쓰는 곳은 둘이다. Agent Core `AfterTurn` hook 안의 `Table.observe`(`keeper_turn_driver_try_provider.ml`)와, 새 세션에서 보낸 범위와 사용량이 둘 다 있을 때 적는 ACP 런타임의 `Table.observe`(`keeper_acp_runtime.ml`)다. Claude Code·Codex·Antigravity 턴은 둘 다 지나지 않는다. 그래서 이 셋은 상한만 주면 원장이 비어 있어 판정은 여전히 `None` 이다.
- 공식 클라이언트가 이어 쓰는 세션의 창은 클라이언트가 세고 압축한다(창 RFC §4.1 의 4·5·6, 운영자 결정 2026-10-06). 이 RFC 는 그 결정을 바꾸지 않는다. 새 세션의 첫 메시지는 masc 가 고르므로 masc 몫이다.

## 4. 왜 지금 숫자 상한을 넣지 않나

창 RFC §1 의 1 은 창 크기를 숫자로 정하지 않는다. 요청은 Librarian 이 마지막으로 흡수한 지점부터 싣는다. 첫 메시지가 594K 라는 것은 그 지점이 한참 뒤에 있다는 뜻이다.

2026-11-21 14:3xZ 에 최근 48시간 안에 턴을 돈 Keeper 17개를 쟀다. 비교는 마지막 턴이 이력을 싣기 시작한 atom(`turn-boundaries.jsonl` 의 `history_at_start.start_atom`)과 Librarian 이 읽은 끝(`librarian-progress.json` 의 `end_atom`)이다.

| 본 것 | Keeper 수 |
|---|---|
| Librarian 이 읽은 끝이 창 시작보다 뒤 | 0 |
| Librarian 이 읽은 위치가 없음 (Keeper A·B 포함) | 6 |
| 위치가 있지만 창 시작보다 앞이고, 마지막 갱신이 37~52시간 전 | 11 |

- §2 에서 첫 요청이 창을 넘은 6건 중 5건이 위치가 없는 Keeper(A·B)에서 나왔다. 나머지 1건(Keeper C)은 위치가 창 시작보다 앞이다.
- 지금 운영에는 `librarian_memory` lane 표가 없어서, 새로 쓰는 쪽이 Librarian 을 부르지 않는다.
- 이 비교에 쓴 두 파일(`turn-boundaries.jsonl`, `librarian-progress.json`)은 Librarian 컷이 지운다. 컷 뒤에는 읽은 곳의 끝(`Keeper_covered_point` → continuity `Covered`, `librarian_point_of`)과 턴 기록의 창 시작으로 견준다(§7).
- 그래서 조건 없이 상한을 넣으면 대부분 `Turn_start_at_max_context` 가 된다. 기억에 없는 턴을 masc 가 버리는 것이다. 지금 CLI 압축은 적어도 그 턴을 요약한다.
- 새 세션 첫 메시지가 큰 뿌리는 Librarian 이 멈춘 것이다. 상한은 컷 설치 뒤에 남는 안전장치다.

## 5. 제안

결정론과 비결정론의 경계는 이렇게 둔다.
- masc 가 정한다(결정론): 창 값(runtime.toml), 첫 메시지의 시작 atom, 그 자리가 Librarian 이 읽은 곳인지.
- 클라이언트가 정한다(비결정론): 이어 쓰는 세션의 압축 요약.
- Librarian 이 정한다(비결정론): 창 밖으로 나간 것 중 무엇이 기억에 남는지.

제안은 다섯이다.

1. **상한.** `input_limit_of_runtime` 이 공식 클라이언트에도 해결된 창(`Runtime_instance.max_context_of_runtime`)을 준다. #54320 이 `--autocompact` 에 넘기는 값과 같다.
2. **비교 대상.** 새 세션을 열 때는 보낼 첫 메시지의 크기와 창을 견준다. 원장의 마지막 관측과 견주지 않는다. 11-21 새 세션 18건에서 첫 요청 ÷ 직전 세션 마지막 요청은 0.25~3.79 로 흩어졌다. 6건 중 1건(Keeper C, 직전 117K → 첫 요청 445K)은 직전 값이 창 아래였다. 이어 쓰는 세션이 400K 에서 압축되면 직전 값은 대개 창 아래가 되고, 놓치는 경우가 늘어난다.
3. **자르는 자리.** 공식 클라이언트의 새 세션은 `Librarian_point_at_max_context` 일 때만 자른다. Librarian 이 읽은 끝이 창 시작보다 앞이면 자르지 않고 보낸다.
   - 자르지 않고 보내는 상태는 W2 경보가 이미 본다. W2 는 「Keeper 의 가장 최근 요청이 읽은 곳의 끝보다 뒤에서 시작했다」이다(`RFC-librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line.md` §12.2 경보 표, 요청 시작점의 원리는 같은 파일 §11.2). 새 관측을 만들지 않고 W2 를 따른다.
   - 공식 클라이언트의 읽은 곳의 끝은 fragment offset 이다. 자를 atom 은 `first_atom_at_or_after` 로 정한다.
4. **원장 쓰는 곳은 하나.** 공식 클라이언트의 관측을 원장에 넣어야 한다면, Agent Core 가 부르는 `Table.observe` 를 같이 부른다. 두 번째 쓰는 함수를 만들지 않는다. 두 곳이 서로 다르게 셀 수 있기 때문이다.
5. **켜는 때.** Librarian 컷(native stack #54329)을 설치하고 W2 를 켠 뒤다. 컷 설치 안내에 이 RFC 를 켜는 순서를 한 줄 넣는다.

새 durable 필드는 없다. `Keeper_model_input_ledger` 는 프로세스 메모리다.

## 6. 열린 질문

1. 보내기 전에 첫 메시지의 토큰 수를 무엇으로 아는가. 후보는 셋이다: atom 별로 이미 잰 토큰(`known_tokens`·`unmeasured_atoms`), 그 Keeper 의 지난 새 세션 첫 요청 관측, provider 의 token count.
2. CLI 가 붙이는 시스템 프롬프트와 도구 설명 몫을 어떻게 더하는가. 새 세션 첫 요청은 seed 에 이 몫이 붙은 크기다.
3. CLI 가 압축한 뒤에 보고하는 usage 는 masc 의 carried range 를 설명하는가. 오늘 압축 바로 다음 요청은 135.6K 였다. 압축 뒤의 관측을 원장에 넣으면, atom 범위와 맞지 않는 값이 들어갈 수 있다.

## 7. 켜기 전 판정 기준

켜기 전과 켠 뒤를 같은 길이 구간으로 잰다. 각 값은 runtime 마다 그 runtime 의 창과 비교한다.

켜기 전 측정은 컷 설치, `librarian_memory` lane 켜기, Librarian 따라잡기가 끝난 뒤에 다시 한다. §4 의 0/17 은 컷 전 파일로 잰 값이라 켤지 정하는 근거가 아니다.

- 새 세션 첫 요청이 자기 창을 넘은 비율 (11-21: 18건 중 6건)
- 요청당 평균 문맥 토큰
- 같은 파일을 다시 읽은 횟수: 잘라 낸 내용을 Keeper 가 다시 찾는지
- 캐시 적중률
- 첫 턴 실패 수

다시 읽기나 첫 턴 실패가 늘면 끈다.

## 8. 범위 밖

- Agent Core 경로는 바꾸지 않는다. 이미 `past_max_context` 로 움직인다.
- 깨우는 쪽의 겹침은 따로 다룬다. 주기 시계와 예약 시계를 하나로 묶는 일은 #54338 이 맡는다.
