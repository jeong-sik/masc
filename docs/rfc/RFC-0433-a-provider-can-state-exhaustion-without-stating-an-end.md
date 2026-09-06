---
rfc: "0433"
title: "고갈은 말하고 끝나는 때는 안 말하는 provider — 그래서 하루 종일 죽은 곳으로 보낸다"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent
supersedes: null
superseded_by: null
related: ["0370"]
---

## 1. 문제

2026-09-06, ollama.com 계정의 주간 한도가 소진됐다. 그 뒤 하루 동안:

```
librarian_exact       성공 77 / 실패 41
  실패 41 건 전부    slot=ollama_cloud.deepseek-v4-flash-0731
                     http_status=429 refusal=rate_limited
턴 (2시간)            성공 961 / 레이트리밋 실패 224 (19%)
ollama_cloud 경유     minimax-m3 0승 18패 · kimi-k3 0승 11패
                     gemma4 0승 11패 · gpt-oss 0승 6패
파생                  키퍼 백오프 600s, 운영자 TUI 대화 타임아웃
```

**이미 죽은 것이 확실한 곳으로 계속 보냈다.** 그리고 이것을 막으라고 만든 장치가
이미 있다 — `Runtime_quota_window` (RFC-0370 §3.3).

## 2. 왜 안 걸리는가

그 모듈은 provider 가 **재설정 시각을 말했을 때만** 기록한다.

> Windows are recorded only when the provider stated a reset time. A quota
> failure without `retry_after` records nothing: inventing a cooldown here
> would be a synthesized default the provider never reported.

원칙은 옳다. 없는 시간을 지어내는 것은 워크어라운드다.

문제는 **ollama.com 이 그 시각을 안 준다는 것**이다. 2026-09-06 직접 확인:

```
POST https://ollama.com/v1/chat/completions   → 429
응답 헤더:  Retry-After 없음, RateLimit-* 없음
응답 본문:  {"error":{"message":"you (yousleepwhen) have reached your
             weekly usage limit, add extra usage: ...", "type":"api_error"}}
```

**고갈은 분명히 말한다. 끝나는 때만 안 말한다.** 그래서 조건이 영원히 안 맞고,
장치는 있는데 한 번도 켜지지 않는다.

## 3. 제안 — 기간이 아니라 관찰을 기록한다

RFC-0370 이 거부한 것은 **지어낸 기간**이다. 이 RFC 는 기간을 만들지 않는다.
대신 **관찰된 사실**을 기록한다.

```
지금:   "이 scope 는 T 까지 고갈"        ← provider 가 T 를 말해야 성립
추가:   "이 scope 는 마지막 관찰에서 고갈"  ← 끝나는 때를 주장하지 않는다
```

두 번째는 지어낸 값이 없다. provider 가 실제로 한 말("한도에 도달했다")을
그대로 옮길 뿐이다.

### 3.1 언제 지워지는가

시계가 아니라 **다음 성공**이 지운다.

```
mark   : HardQuota 응답, retry_after 없음  → scope 를 "관찰된 고갈" 로 표시
demote : 표시된 후보는 순서 뒤로 (기존 demote_order 그대로)
clear  : 그 scope 로 어떤 호출이든 성공    → 표시 제거
```

한도가 리셋되면 그것을 알아내는 방법은 하나뿐이다 — 불러보는 것. 그리고
`demote_order` 는 이미 **배제가 아니라 순서**다:

> It is an ordering preference, not an admission gate — a demoted candidate
> is still attempted when it is all the lane has left.

그러므로 표시된 후보도 위가 전부 실패하면 시도되고, 성공하면 표시가 사라진다.
**닫히는 경로가 새로 생기지 않는다.**

### 3.2 굶는 경우

위 후보가 계속 성공하면 표시된 후보는 안 불리고 표시도 안 지워진다. 이것은
문제가 아니다 — 표시의 효과는 순서뿐이고, 필요해지는 순간(위가 실패) 시도되기
때문이다. 리셋을 미리 알 필요가 없다.

### 3.3 무엇이 달라지는가

오늘 사고에 적용하면: 첫 429 에서 네 레인의 ollama_cloud 슬롯이 전부 뒤로
가고, 이후 실패 40 건이 사라진다. 첫 실패 한 번은 남는다 — 그것이 사실을
알아낸 비용이다.

## 4. 운영자에게 보이는 것

지금은 무엇이 죽었는지 로그를 뒤져야 안다. `GET /api/v1/runtime/quota` 로
현재 상태를 낸다.

```json
{ "scopes": [
    { "scope": "OLLAMA_CLOUD_API_KEY",
      "state": "observed_exhausted",
      "since": "2026-09-06T04:12:31Z",
      "stated_reset": null,
      "runtimes": ["ollama_cloud.deepseek-v4-flash-0731", "..."],
      "demoted_in_lanes": ["librarian_exact", "verifier_exact", "..."] },
    { "scope": "api.z.ai", "state": "healthy" } ] }
```

`stated_reset` 이 `null` 인 것과 값이 있는 것을 **구분해서 낸다.** 그것이 이
RFC 가 만든 두 상태의 차이이고, 운영자가 "언제 돌아오나"를 물었을 때
"provider 가 말하지 않았다"가 정직한 답이다.

## 5. 비용 순서는 이 RFC 가 하지 않는다

처음에는 "가격표가 없어서" 라고 적었는데, provider 를 전수 분류해 보니 이유가
그것보다 정확했다. **8 개 중 계량 요금제가 하나뿐이다** (2026-09-06 확인, 근거
기록 `memory/procedural-memory/2026-09-06-fleet-cost-classes-evidence-record.md`).

| 클래스 | provider | 한계 비용 |
|---|---|---|
| 로컬 | `ollama` (localhost) | 0 — 생성 2.65~3.05 t/s |
| 정액 plan | `glm-coding`, `kimi_coding` | 0 (한도 내) |
| 구독 CLI | `claude_code`, `codex_subscription`, `antigravity_subscription` | 0 (한도 내) |
| 주간 쿼터 | `ollama_cloud` | 0 (소진 전) |
| **계량** | **`deepseek`** | **토큰당 과금** |

그러므로 가격표를 만들어도 **행 하나에만 실수치가 들어가고 나머지는 전부 0 이나
미상**이다. 그 표로 정렬하면 결과는 하나로 수렴한다 — "계량을 마지막에".

즉 비용 순서의 실질은 **정액으로 이미 산 용량을 먼저 쓰고, 종량제를 마지막에
두는 것**이고, 그 분류는 `runtime.toml` 의 protocol·endpoint·command 에서 이미
유도된다. 새로 낡을 데이터를 만들 필요가 없다.

이 RFC 가 그것까지 하지 않는 이유는 따로다. 3 절의 표시는 **관찰된 사실**을
옮기는 것이고, 비용 클래스 정렬은 **정책**이다. 정책은 "고갈된 것을 뒤로" 와
독립적으로 판단되어야 하므로 별개 RFC 로 둔다. 이 RFC 안에서 순서는 선언 순서
그대로다.

(`cost_usd` 는 `dashboard_agent_core_bridge` 에 provider 보고 사후 관측치로만
존재한다. 정액 provider 에는 값이 없으므로 그것으로도 위 결론은 안 바뀐다.)

## 6. 무엇을 하지 않는가

- **쿨다운을 만들지 않는다.** 기간을 지어내는 순간 RFC-0370 이 거부한 그것이 된다.
- **후보를 배제하지 않는다.** 표시는 순서에만 작용한다.
- **provider 를 자동으로 끄지 않는다.**
- **가격으로 정렬하지 않는다** (5절).
- **문자열로 분류하지 않는다.** mark 조건은 `Llm_provider.Error.HardQuota` 라는
  typed 값이지 메시지 문자열이 아니다.

## 7. 검증

| 무엇 | 어떻게 |
|---|---|
| retry_after 있는 경우가 안 바뀐다 | 기존 `Runtime_quota_window` 테스트 그대로 통과 |
| retry_after 없는 고갈이 표시된다 | `HardQuota { retry_after = None }` 이후 `demote_order` 가 뒤로 보낸다 |
| 성공이 표시를 지운다 | 표시 후 그 scope 성공 → `demote_order` 가 원래 자리로 |
| 배제가 아니다 | 표시된 후보가 유일할 때 여전히 시도된다 |
| 시각을 지어내지 않는다 | 표시된 항목의 `stated_reset` 이 `null` |

네 번째가 이 RFC 의 안전선이다. 표시가 배제로 바뀌면 provider 하나의 일시적
장애가 레인을 통째로 죽인다.

## 8. 위험

**표시가 오래 남는다.** 위 후보가 계속 성공하면 표시가 안 지워진다. 효과가
순서뿐이라 해는 없지만, 4절의 상태 조회가 "실제로는 살아났는데 표시가 남은
것"을 보여줄 수 있다. `since` 를 같이 내는 이유다.

**한 번의 실패는 남는다.** 사실을 알아내려면 한 번은 맞아야 한다. 이것은
비용이지 결함이 아니다.

## 9. 측정 근거

전부 2026-09-06, 이 워크스페이스.

```
ollama.com 429 응답    Retry-After 헤더 없음 (직접 확인)
                      본문에도 재설정 시각 없음
librarian_exact       성공 77 / 실패 41, 실패 전부 429
턴 (2시간)             성공 961 / 레이트리밋 224
ollama_cloud 모델      minimax-m3 0/18 · kimi-k3 0/11 · gemma4 0/11 · gpt-oss 0/6
같은 모델 다른 경로     deepseek.com 직접 130승 0패
                      ollama 경유 0승 10패
```

마지막 두 줄이 이 문제의 성격을 말한다. 모델이 아니라 **경로**가 죽었고,
그 경로만 뒤로 보내면 된다.
