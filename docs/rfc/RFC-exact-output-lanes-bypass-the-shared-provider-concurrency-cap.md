---
rfc: "exact-output-lanes-bypass-the-shared-provider-concurrency-cap"
title: "Exact 레인은 glm-coding 계정 동시성 상한을 우회한다 — Keeper 턴은 4 로 막는데 Exact 는 안 막는다"
status: Draft
created: 2026-09-26
updated: 2026-09-26
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0370-provider-profile-ssot-and-rotation-eligibility", "0433-a-provider-can-state-exhaustion-without-stating-an-end"]
implementation_prs: []
---

# Exact 레인은 glm-coding 계정 동시성 상한을 우회한다

## 1. 문제

2026-09-25, `glm-coding.glm-5.3-flash` 로 가는 요청이 하루 3,175건의 `429`
(`{"code":"1302","message":"Rate limit reached for requests"}`)를 받았다.
keeper cycle 실패로 좁혀도 479건, 그중 `ocaml-agent-ic` 하나가 245건이다.

Z.AI 요금제는 Max (2026-09-25 확인, 운영자 진술). 문서상 세 등급 중 가장
높다. 공식 문서(`docs.z.ai/devpack/usage-policy`, 2026-09-25 fetch)는 등급별
동시성 상한이 있다고만 하고 숫자는 안 준다. 응답 헤더에도 `Retry-After`,
`RateLimit-*` 가 없다 — 직접 `curl` 로 열 번, 스무 번 확인했다(2026-09-25).

### 1.1 개입 실험 (2026-09-25 22:56–23:19 KST)

`librarian_exact` 레인의 `slots` 에서 `glm-coding.glm-5.3-flash` 하나만 빼고
(admin raw API, `routing.status: applied, requires_restart: false`), 30초
간격으로 별도 ping(`max_tokens=8`, 같은 계정 키)을 계속 보내며 masc 가
`api.z.ai` 로 연 커넥션 수를 같이 쟀다.

```
phase     round  pass  open(연결수)
baseline    4    0/4   9
changed(0–3분) 3  0/3   8–9   (이미 나간 librarian 요청이 아직 안 끝남)
changed(3–16분) 23 22/23  9 → 3~4 로 감소
restored    6    6/6   4~7   (아직 예전 부하로 안 돌아온 상태)
```

원복 후 3분은 부하가 낮은 채였다는 한계는 있지만, **레인 하나에서 슬롯
하나를 뺐을 뿐인데 0/7 에서 22/23 으로 갈렸다.** 우연으로 보기 어렵다.

## 2. 왜 안 걸리는가

masc 에는 provider 압박을 다루는 장치가 이미 셋 있다. 셋 다 이 사고를 안
잡는다.

### 2.1 `Runtime_quota_window` (RFC-0370 §3.3, RFC-0433) — 순서만, credential 단위

`lib/runtime/runtime_quota_window.mli`: hard quota(402, 또는 이유를 말한
429)를 credential scope 단위로 기록하고 `demote_order` 로 후보 순서만
뒤로 민다. mli 자체가 명시한다 — "Coarse HTTP 429 / Provider.RateLimit does
not establish credential ownership; it belongs to
`Runtime_candidate_backpressure`'s candidate-only observation instead."
Z.AI 의 1302 는 이유를 안 말하는 coarse 429 라 이 모듈이 아니라 다음
모듈로 간다.

### 2.2 `Runtime_candidate_backpressure` (RFC-0370 §3.3, RFC-0433) — 순서만, candidate 단위

`lib/runtime/runtime_candidate_backpressure.mli`: 1302 는 여기로 간다.
그런데 이것도 "an ordering preference ... demoted behind its lane
siblings, never excluded" 라고 mli 에 직접 적혀 있다. **다음 dispatch 가
이 candidate 를 뒤로 미룰 뿐, 지금 몇 개가 동시에 나가 있는지는 안 본다.**
순서 장치 둘 다 동시성 게이트가 아니다.

> **주의 — 두 `runtime.toml` 이 다르다.** 이 절의 레인·바인딩 값은 이
> 저장소에 커밋된 시드(`config/runtime.toml`)가 아니라 **운영 중인 인스턴스가
> 쓰는 라이브 설정**(`<base-path>/.masc/config/runtime.toml` — 이 조사에서
> `base-path` 는 `MASC_BASE_PATH`/`--base-path` 가 가리키는 운영 인스턴스
> 경로다, admin API 로만
> 고침 — `edit-the-live-runtime-toml-through-the-admin-raw-endpoint-not-the-file`
> 메모리 참고)에서 읽었다. 시드는 다르다: exact 레인 4개가 전부
> `glm-coding.glm-5-3` 를 쓰고(`glm-5.3-flash` 아님), `cli_slots` 폴백이
> 아예 없다(`config/runtime.toml:114-129`, 이 저장소 기준). 라이브 설정은
> 매일 바뀌는 파일이라 아래 값은 **줄 번호 대신 테이블 이름으로** 인용한다.

### 2.3 `Provider_admission` (Slot_scheduler) — 진짜 게이트지만 keeper 턴에만 연결됨

`packages/agent_core/lib/llm_provider/provider_admission.ml:12-17`
(`key_of_config`)는 `(provider_kind, base_url, secret identity)` 로
세마포어 키를 잡는다 — **모델이 아니라 계정 단위다.** 라이브 설정의
`[glm-coding."glm-5.3-flash"]` 와 `[glm-coding.glm-5-3]` 바인딩이 둘 다
`max-concurrent = 4` 를 선언해서, 같은 glm-coding 계정으로 가는 keeper
턴은 실제로 모델에 상관없이 `with_admission`(`provider_admission.ml:68-69`)
한 세마포어 4 슬롯을 공유한다. 여기까지는 설계대로 동작한다.

문제는 exact 레인이다. `packages/agent_core/lib/llm_provider/
exact_output_ready_admission.ml:306` 이 exact 요청 설정을 지을 때
`max_concurrent_requests = None` 으로 고정하고, `exact_output_plan.ml:467`
은 `Option.is_some config.max_concurrent_requests` 면 아예
`Global_admission_not_allowed` 로 거절한다. exact 레인은 이 세마포어를
**구조적으로 못 받는다** — 값을 깜빡한 게 아니라 코드가 막아 둔다.

라이브 설정의 exact 레인 4개(`verifier_exact`, `librarian_exact`,
`hitl_auto_judge`, `board_attention_exact`)가 전부 `glm-coding.glm-5.3-flash`
를 첫 슬롯으로 쓴다. `librarian_exact` 하나만도 2026-09-25 오후 평균 동시
4.1건, 최대 5~8건을 계정에 얹었다(운영 중인 `exact-lane-runs-v6.jsonl`
집계, `registration.lane`/`completion.selected_slot`/`completion.
elapsed_s` 로 구간을 겹쳐 셈 — 이 파일은 저장소가 아니라 운영 데이터라
재현하려면 §5 링크를 봐야 한다).

**결과**: keeper 턴은 4로 막히는데, 같은 계정으로 exact 레인 4개가
무제한으로 더 나간다. masc 자신이 만드는 총 동시 요청이 계정 상한을
넘을 수 있는 구조다. 개입 실험은 그중 한 레인만 줄여도 통과율이 뒤집힘을
보여준다 — masc 자신의 기여가 지배적이라는 뜻이다.

### 2.4 왜 `Global_admission_not_allowed` 가 있는지는 못 찾았다

`eaddf336b6`(#27619, "import MASC agent core", 2026-08-08)로 `agent_core`
패키지 전체가 한 번에 들어올 때부터 있던 값이다. masc 쪽 커밋 이력이나
docs 에서 이 거절의 이유를 설명하는 글을 못 찾았다. 의도적 설계일 수도,
"exact 는 짧고 싸니 계정 게이트가 필요 없다"는 당시 가정일 수도 있다 —
**확인 필요**로 남긴다. 이 이유를 모르는 채로 단순히 값만 채워 넣으면
다른 불변식을 깰 수 있다.

## 3. 제안 (구현 방식은 미확정 — 운영자 판단 필요)

### 옵션 A — exact 레인도 같은 account 세마포어를 거치게 한다

`Provider_admission` 을 exact 경로에서도 쓰도록 `exact_output_plan.ml`
의 거절을 풀고, exact config 에도 `max_concurrent_requests` 를 흘려
보낸다. 근본 해결에 가깝다. 대신 §2.4 를 먼저 풀어야 한다 — exact 요청은
`connect-timeout-s`/`exact-body-timeout-s` 로 이미 마감이 촘촘히 계산돼
있어서(라이브 설정의 `[providers.glm-coding]`, #38573 관련), 세마포어 대기 시간을
그 마감 계산에 넣지 않으면 exact 요청이 permit 을 기다리다 자기 마감을
넘겨버릴 수 있다. `with_admission_until` (permit 대기에 `deadline_at` 을
받는 버전)이 이미 있어서 이 경로가 유력해 보이지만, exact 쪽 배선은
확인이 더 필요하다.

### 옵션 B — 계정 단위로 전체 in-flight 를 세는 별도 게이트

exact 레인 전용으로, keeper 세마포어와 별개인 계정 단위 동시성 카운터를
하나 더 둔다. exact 의 마감 계산을 안 건드려도 되는 대신, "계정 동시성"
이라는 개념이 두 군데(keeper 세마포어, exact 카운터)로 쪼개져서 나중에
둘이 다른 숫자를 볼 위험이 생긴다.

**권고**: A 가 개념적으로 더 맞다 — "계정 동시성"은 하나의 사실이어야
한다. 다만 실행 전에 §2.4 의 원래 이유를 확인하고, exact 마감 계산과의
상호작용을 설계해야 한다. B 는 그 확인 없이 빨리 막아야 할 때의 대안이다.

### 하지 않을 것

`librarian_exact` 에서 glm flash 를 빼고 codex/antigravity/claude CLI 로
돌리는 것만으로 끝내지 않는다. 이번 실험에서 그게 통과율을 올린다는 건
증명됐지만, 다른 exact 레인 3개는 그대로 glm 계정을 무제한으로 쓰고,
근본 원인(exact 레인이 계정 게이트를 못 받는 구조)은 그대로 남는다.
`software-development.md` 의 워크어라운드 거부 기준(증상 억제, 대체 RFC
없는 회피)에 걸린다.

## 4. 검증 방법

- 변경 후 같은 개입 실험을 반대 방향으로: exact 레인에 세마포어를 걸고
  keeper 턴 없이 exact 요청만 동시에 여러 개 넣어, `max-concurrent` 값을
  넘지 않는지 직접 관찰한다.
- 배포 후 하루 동안 `system_log_*.jsonl` 의 `keeper cycle FAILED ...
  Rate limit reached` 건수와 `exact-lane-runs-v6.jsonl` 의 `outcome !=
  succeeded` 비율을 배포 전날과 비교한다.
- exact 레인의 `completion.elapsed_s` p90/p99 가 세마포어 대기 때문에
  늘지 않는지 같이 본다 — 늘었다면 마감 계산에 대기 시간이 빠진 것이다.

## 5. 관련

- RFC-0370, RFC-0433 — 이 RFC 가 다루는 것과 다른 실패 모양(이유가 있는
  hard quota, 그리고 candidate 순서 데모션)을 다룬다. 이 RFC 는 그 둘을
  대체하지 않고, 그 둘이 원래도 처리 대상으로 안 삼은 "동시성 자체"를
  다룬다.
- 개입 실험 원본 로그: 이 세션의 scratchpad(`intervene-1302.log`,
  `observe-1302.log`, `paired-1302.log`, `sparse-1302.log`) — 세션 종료
  후 휘발되므로, 이 문서의 §1.1/§2.3 수치가 유일한 기록이다.
