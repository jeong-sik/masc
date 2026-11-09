---
rfc: "0517"
title: "librarian 은 지식마다 맞는 fact 하나를 남긴다"
status: Draft
created: 2026-11-09
updated: 2026-11-09
author: claude
supersedes: []
superseded_by: null
related: ["librarian-absorb-gate", "0463", "keeper-recall-reaches-the-turn", "0514"]
---

# RFC-0517 — librarian 은 지식마다 맞는 fact 하나를 남긴다

- Status: **Draft.** 사용자가 2026-11-09 에 방향을 정했다. "틀리는건 지우거나 흡수, 병합되어서 맞는 사실 1개만 남기고 그리고 문장을 정리해서 올바르게 기억을 남기는게 중요함". 같은 날 librarian 프롬프트와 기능도 같이 고치라고 했다.
- 근거: [연구 문서](../research/2026-11-09-librarian-keeps-one-correct-fact.md)와 [측정 기록](../evidence/research/2026-11-09-librarian-memory-state/README.md). 이 RFC 의 숫자는 모두 연구 문서에 출처가 있다.
- 하네스 쪽 구현은 T 스택이 한다. #50290 이 계약 안에서 맞힐 수 있는 라벨을, #50325 가 남는 기억 채점을 넣는다.
- §7 의 세 가지는 사용자가 고른다. 고르기 전에는 그 부분을 구현하지 않는다.

## 0. 요약

- Keeper 가 읽는 것은 남은 기억이다. 지금 하네스는 admission 답의 판정 단어를 잰다.
  같은 답을 남는 기억으로 채점하면 기본 모델 점수가 0.838 에서 0.909 가 된다.
- 남는 기억으로 봐도 틀린 곳은 넷이다. 새 지식을 잃고, 교정 뒤 옛 fact 가 남고, 같은 지식이 둘 남고, 낡은 상태가 남는다.
  가장 큰 것은 낡은 상태다. 심은 101개 중 80개가 남았다.
- 낡은 상태의 일부는 모델 탓이 아니다. 후보가 전부 일시 상태인 admission 은 계약상 기억을 못 바꾼다. 정리 패스는 카테고리 한도를 넘을 때만 돈다.
- 이 RFC 는 세 가지를 정한다.
  - D1: 하네스는 남는 기억으로 재고, MASC 계약 안에서 맞힐 수 있는 라벨만 쓴다.
  - D2: 라이브에서 기억이 어떻게 바뀌는지 보이게 한다(F1).
  - D3: librarian 프롬프트는 규칙을 더하지 않고 치운다.
- F1 은 보이게만 한다. 고치는 일은 D1·D3 과 §7 의 결정이 한다.

## 1. 지금

### 1.1 기억이 바뀌는 길

- 패스는 explicit admission → durable → continuity → working context → cleanup 순서로 돈다(`lib/keeper/keeper_librarian_queue_refresh.ml:914-940`, `:992-999`).
  continuity·working context 는 fact 를 바꾸지 않는다(`Context_only`, `lib/keeper/keeper_librarian_runtime.mli:65-73`).
- admission 의 기억 변경은 `incorporated`·`already_represented` 후보가 지지해야 받아들여진다(`lib/keeper/keeper_memory_admission_judgment.ml:109-130`).
  후보가 전부 일시 상태면 admission 은 기억을 못 바꾼다. 라이브 E-real 99건 중 11건이 그랬다.
- cleanup 은 카테고리 수나 카테고리별 fact 수가 30 을 넘을 때만 돈다(`lib/keeper/keeper_memory_cleanup.ml:41`, `lib/keeper/keeper_memory_limits.ml:28-31`).
- 흡수(`absorbs`)는 Jev 게이트가 원문마다 판정한다. 기본값은 꺼짐이고(`lib/runtime/runtime_schema.ml:596`) 라이브는 켜져 있다.
- 지우기(`dropped`)는 조건 없이 통과한다(`lib/keeper/keeper_memory_os_disposition_core.mli:27-28`).
- 기억 커밋은 `Keeper_memory_os_current` 의 `apply_disposition`·`apply_disposition_guarded`·`apply_program` 이 한다. 부르는 자리는 아래와 같다.
  - admission: `lib/keeper/keeper_librarian_admission_commit.ml:233`
  - durable: `lib/keeper/keeper_librarian_durable_commit.ml:409`, `:513`
  - Librarian runtime: `lib/keeper/keeper_librarian_runtime.ml:2179`
  - program 발행: `lib/keeper/keeper_librarian_durable_consumer.ml:775`, `:853`, `lib/keeper/keeper_librarian_floor_publish.ml:91`, `lib/keeper/keeper_librarian_continuity.ml:526`
  - Keeper 가 직접 쓰고 지우는 길은 journal source `Explicit_write`·`Explicit_retract` 로 남는다.

### 1.2 무엇이 틀리나

고정 E-synth 119건에서 기본 모델 `Inkling-2-Small`(effort `low`)의 유효 답 109개를 셌다.

| 오류 | 수 |
| --- | --- |
| 새 지식을 잃음 | 8/46 |
| 교정 뒤 옛 fact 가 남음 | 5/28 |
| 같은 지식이 두 fact 로 남음 | 1/34 |
| 심은 낡은 상태가 남음 | 80/101 |

- 고정 E-synth 의 낡은 상태 라벨 112개 중 27개는 지지 후보가 없는 요청에 있다.
  라벨대로 답해도 재현율은 0.759 가 끝이다. 고정한 G3 는 0.9 를 요구한다.
- 라이브 admission 은 답 하나마다 기억을 평균 0.57개 늘린다. E-real 99건에서 claim 103개를 더하고 fact 47개를 뺐다.
- 교사 필터는 흡수가 있는 답을 모두 버린다. 학습용으로 남긴 185개에 흡수가 없다. 라이브는 답의 30%가 흡수를 쓴다.

### 1.3 무엇이 안 보이나

- 건강 행은 fact 수, 바이트, 마지막 커밋의 `added`·`removed` 수를 보인다(`lib/server/server_dashboard_http_keeper_memory_health.ml:410-428`).
  어느 패스가 썼는지, 지우기와 흡수가 몇인지, 크기가 어떻게 변하는지는 없다.
- Prometheus 의 기억 지표는 실패, 레인, recall 이다(`lib/keeper_metrics/keeper_metrics.ml:275-367`).
- 흡수 게이트 판정은 로그 한 줄이다. forward 는 `lib/keeper/keeper_librarian_absorb_gate.ml:1605-1615`, reverse 는 `:1435-1445` 다.
- journal 은 커밋마다 변경과 지운 fact 의 사유를 남긴다. Librarian 패스는 `Librarian` 하나로만 적힌다(`lib/keeper/keeper_memory_os_current.mli:14-22`, `:245-253`).

### 1.4 프롬프트

- `config/prompts/librarian.md` 는 651줄, 48,034바이트다. 2026-08-06 에는 7,812바이트였다.
- 본문(8-422행)은 admission·durable·cleanup 이 같이 쓴다. admission 은 영어 `admission_policy`(586-617행)를 덧붙인다.
- 같은 상황을 여러 곳에서 다르게 말한다. 바꿔 쓰기(60, 154-155, 192행), 중복 없애는 법(여섯 곳), 낡은 상태와 사건 경과(133-138, 622행), 정리할지 둘지, 재발, `already_represented`(596, 608-610행)가 그렇다.
  연구 문서 §8 표에 행마다 적었다.
- 금지 명령형은 본문 46개, 슬롯 23개다.

## 2. 결정

### 2.1 D1 — 하네스는 남는 기억으로 잰다

후보마다, 답이 남긴 기억이 라벨 종류가 바라는 모양인지 본다.

| 라벨 | 맞는 경우 |
| --- | --- |
| 새 사실 | `incorporated` 이고, 가리킨 claim 이 새로 들어간다 |
| 교정 | 새 사실과 같고, 대상 fact 가 빠진다(지우기나 흡수) |
| 보완(COMPLEMENT) | 새 사실과 같고, 대상 fact 가 그 claim 에 흡수된다 |
| 바꿔 말하기 | 새 claim 을 더하지 않았으면 원래 fact 가 남거나 최종 claim 에 흡수된다. 더했으면 그 claim 이 원래 fact 를 흡수한다 |
| 일시 상태 | 아무것도 들어가지 않는다 |
| 심은 중복 쌍 | fact 하나만 남는다 |
| 심은 낡은 상태 | `dropped` 로 빠진다. 흡수로 빠지면 안 지운 것으로 센다(librarian.md 133-135행) |

- 라벨은 MASC 계약 안에서 맞힐 수 있는 답만 요구한다. 지지 후보가 없는 요청에는 낡은 상태를 심지 않는다.
  §7.1 에서 A1 을 고르면 계약이 바뀌니 이 규칙도 따라 바뀐다.
- 합친 claim 이 지식을 잃지 않는지는 블라인드 판정자가 본다.
  분류는 라이브 Jev 와 같은 네 갈래(mergeable·different_context·loses_knowledge·uncertain)이고, mergeable 만 맞다. 라벨이 바란 흡수와 라벨 밖 흡수를 모두 판정한다.
- 교사 필터는 흡수를 모두 버리지 않는다. 라벨이 바란 흡수와 mergeable 로 판정된 흡수는 남긴다. 낡은 상태를 흡수한 답은 버린다.
- G3 는 남는 기억 정확도와 낡은 상태 지우기 정밀도·재현율을 읽는다. 합침은 새 G6 가 읽는다.
  G6 값과 새 프롬프트 기준 G2 는 기본 모델을 잰 뒤, 학습 전에 사용자가 정한다.
- 판정 단어 정확도는 기록만 한다. 옛 G3 를 읽는 코드는 남기지 않는다.
- 교사도 effort `low` 로 답한다. `high` 는 유효 답 정확도가 같았고(0.750, 기본 0.751) 토큰·시간이 p50 기준 약 5.2배였다.

### 2.2 D2 — 기억이 바뀌는 모습을 보인다 (F1)

목적은 셋이다.

- P(프롬프트)와 학습이 라이브 기억을 어떻게 바꿨는지 잰다.
- 하네스가 재지 않는 durable·cleanup 패스를 본다.
- 롤아웃 앞뒤를 같은 표로 견준다.

Prometheus 지표는 기존 recall 지표처럼 `Otel_metric_store` 에 `keeper` 라벨을 달아 센다(`lib/keeper/keeper_memory_recall_turn.ml:46-49`).
이름은 `Keeper_metrics` 의 닫힌 variant 로 둔다.

| 이름 | 종류 | 라벨 | 세는 자리 |
| --- | --- | --- | --- |
| `masc_keeper_memory_changes_total` | counter | `keeper`, `pass`, `change` | 기억 커밋이 성공한 뒤 |
| `masc_keeper_memory_facts` | gauge | `keeper` | 같은 자리. 커밋 뒤 fact 수 |
| `masc_keeper_memory_snapshot_bytes` | gauge | `keeper` | 같은 자리. 커밋 뒤 바이트 |
| `masc_keeper_librarian_absorb_sources_total` | counter | `keeper`, `slot`, `outcome`, `decision` | forward 판정을 로그로 쓰는 자리 |
| `masc_keeper_librarian_absorb_copy_checks_total` | counter | `keeper`, `slot`, `verdict` | reverse 판정을 로그로 쓰는 자리 |

- `pass` 는 커밋을 부른 자리가 닫힌 variant 로 넘긴다. 값은 admission, durable, cleanup, program 발행, Keeper 직접 쓰기, Keeper 직접 지우기다.
  커밋 함수가 이 인자를 필수로 받으면, 빠진 자리를 컴파일러가 잡는다.
- `change` 는 서로 겹치지 않는 넷이다.
  - `added`: 새 claim
  - `absorbed`: 흡수로 빠진 fact
  - `superseded`: 교정(`supersedes`)으로 빠진 fact
  - `dropped`: 뒤를 잇는 claim 없이 지운 fact
- `outcome` 은 forward 결과(conveyed·left·unjudged·unjudgeable)다. `decision` 은 원문 판정(mergeable·different_context·loses_knowledge·uncertain)이고, 판정이 없으면 `none` 이다.
- `verdict` 는 reverse 판정(copy·carries_new_statement·not_judged)이다.
- `slot` 은 답을 낸 레인 슬롯이다. 롤아웃에서 슬롯끼리 mergeable 비율을 견준다.
  게이트 결과를 받는 runtime 은 이미 슬롯을 안다(`lib/keeper/keeper_librarian_runtime.ml:2176` 의 `selected_slot`). 게이트 안 로그 자리까지 그 값이 오는지는 F1 PR 이 확인한다.

건강 행은 schema `keeper.memory_os.current_health.v10` 으로 올린다(지금 v9, `lib/server/server_dashboard_http_keeper_memory_health.ml:772`).

- 서버가 뜬 뒤의 셈을 Keeper 마다 `pass` × `change` 로 싣는다. 위 counter 와 같은 값이다.
- 크기 추이를 싣는다. journal 의 커밋마다 `retained + added` 가 그 커밋 뒤의 fact 수다. 기록 시각과 같이 싣는다.
  journal 에는 F1 이전 커밋도 있다. 그래서 롤아웃 전 기준선을 따로 모으지 않는다.
- 지금 칸(fact 수, 바이트, 마지막 커밋의 `added`·`removed`)은 그대로 둔다.

지키는 것:

- journal 형식은 바꾸지 않는다. 패스는 journal 에 없으니, 패스별 셈은 서버가 뜬 뒤 값만 있다.
- 지표는 운영자가 보는 projection 이다. Keeper 프롬프트에 싣지 않고, 패스나 커밋을 막는 데 쓰지 않는다.
- 시험은 기능 하나다. 패스 하나가 커밋되면 지표와 건강 행이 그 커밋의 변화만큼 움직인다.

F1 만으로는 아무것도 고쳐지지 않는다. 지우기가 보여도 틀린 지우기는 줄지 않는다. 줄이는 일은 D1·D3 과 §7 의 결정이 한다.

### 2.3 D3 — 프롬프트는 규칙을 더하지 않고 치운다

원칙:

1. 새 규칙 문장을 넣지 않는다.
2. 같은 상황을 말하는 문장은 한 곳에 둔다. 서로 부딪히는 문장은 하나만 남긴다.
3. 목적을 평서문으로 쓴다. 예: "지식마다 맞는 fact 하나를 남긴다. 틀린 fact 는 지우거나 맞는 fact 에 흡수한다. 남기는 문장은 정리해서 쓴다."
4. 금지문은 고치는 문단 안에서만 같은 뜻의 평서문으로 바꾼다.
5. 이번 범위는 admission 판단에 걸리는 문단이다. continuity·working_context 슬롯은 범위 밖이다.

첫 정리안이 다룰 곳:

- 바꿔 쓰기를 한 곳에서 말한다. 같은 지식이면 문장을 그대로 둔다. 합칠 때와 고칠 때만 새로 쓴다(60, 154-155, 192행).
- 낡은 상태와 사건 경과를 가른다. 대기·진행·큐 같은 상태 fact 는 지금 상태가 아니면 지운다. 원인·해결 같은 경과는 한 기록으로 흡수할 수 있다(133-138, 622행).
- 겹친 문장을 하나로 줄인다. 보존 문장(26-27, 68-69행), `first_seen` 정의 둘(88, 119-120행), 중복 없애는 법 여섯 곳이다.
- `already_represented` 는 그대로 남는 claim 을 가리킨다. 다시 쓴 claim 을 가리키는 판정은 `incorporated` 다(595-610행).

들이는 기준은 정리안을 돌리기 전에 커밋한다.

- 두 모델(`Inkling-2-Small`, GLM) 모두 E-synth·E-real 유효율이 기준선 퍼짐 밖으로 떨어지지 않는다.
- E-synth 의 남는 기억 정확도·낡은 상태 재현율·합침 가운데 하나 이상이 퍼짐 밖으로 좋아지고, 나머지는 나빠지지 않는다.
- E-real 의 라이브 일치와 라이브 밖 지우기는 옛 프롬프트 답과의 차이만 잰다. 품질 판정에는 쓰지 않는다. 바뀐 지우기 목록은 사람이 본다.

본문은 durable·cleanup 도 읽는다. 하네스는 admission 만 잰다. 병합 뒤 그 두 패스는 F1 지표로 본다. 되돌리기는 프롬프트 되돌림 PR 하나다.

## 3. 왜 이 모양인가

- 판정 단어 대신 남는 기억으로 잰다. Keeper 가 받는 것은 기억이다. 같은 기억을 남긴 답을 판정 단어로 틀렸다고 세면, 학습이 판정 단어를 맞히는 쪽으로 간다.
  교사 답에서 판정 단어만 틀린 몫이 0.151 이다(0.750 과 0.901 의 차이).
- 라벨은 계약 안에서 맞힐 수 있어야 한다. 닿을 수 없는 라벨은 모델이 아니라 라벨 생성기를 잰다. 재현율 0.9 는 완벽한 답도 못 넘는다.
- 프롬프트에 규칙을 더하지 않는다. Anthropic 글에서 강한 모델은 고정 규칙을 받자 기억의 이득을 잃었다(Figure 5 오른쪽).
  약한 모델은 자세한 지시로 좋아졌다(Figure 5 왼쪽). 그래서 두 모델로 재고, 하나라도 나빠지면 들이지 않는다.
- 낡은 상태는 남겨 두지 않고 지운다. Google 은 낡은 참조를 에이전트가 피하게 하지 않고 원천에서 지웠다.
  그 비용 수치(step 70%, 토큰 77% 더 듦)는 한 조직의 관측 연구이고 다른 종류의 맥락이다. 기억에 그대로 옮기지 않는다.
- 낡았는지는 Librarian 이 판단한다. 문자열 비교로 고르면 `forbidden#string_matching` 이고, 그런 비교가 필요해 보이면 LLM 판단 쪽이 낫다는 신호다(`when_stuck`).
- journal 형식은 그대로 둔다. 패스를 journal 에 넣으면 옛 줄을 읽는 호환 코드가 필요하다. `forbidden#legacy_residue` 는 호환 코드를 금한다.
  hard cut 은 지운 fact 의 기록까지 버린다. `keeper_memory_write` 는 그 기록을 `find_removal`(`lib/keeper/keeper_memory_os_current.mli:357`)로 읽는다. 패스별 셈은 durable truth 가 아니라서 서버가 뜬 뒤 값으로 충분하다.
- 관측성은 넉넉하게 둔다(`cost_and_observability`). 게이트는 더하지 않는다. 게이트 추가는 success_bar 를 다 넘은 뒤 하나씩이다(`gates`).

## 4. 층

| 층 | 무엇 | 어디 |
| --- | --- | --- |
| H | 계약 안 라벨(#50290), 남는 기억 채점(#50325), 합침 판정, GLM 호출기와 `--template`, 교사 필터, 게이트 재고정 | T 스택 `scripts/tinker/librarian/` |
| F1 | 지표 다섯, 건강 행 v10, 기능 시험 하나 | main 위 별도 스택. OCaml PR 하나 |
| P | 프롬프트 정리안, 고정 기준, 두 모델의 근거 묶음 | main 위 별도 스택 |
| §7 | 사용자가 고른 것 | 고른 뒤 각각 |

- 순서는 H → P → 학습 → 롤아웃이다. F1 은 P 와 나란히 간다.
- P 가 라이브에 들어가기 전에 F1 이 있어야 durable·cleanup 의 변화를 본다.
- 병합은 사용자가 한다.

## 5. 확인 방법

- D1: T 스택 시험은 종류마다 검사를 끄면 실패해야 한다. pyright strict 와 ruff 를 돌린다.
  저장된 기본 답을 새 채점으로 다시 세면 0.838·0.909·8/46·5/28 이 나와야 한다. #50325 가 이 값을 다시 냈다.
- D2: 기능 시험 하나, PR CI 타입 검사, 독립 리뷰. 설치 뒤 건강 행 칸을 실측한다.
- D3: 고정 기준 표, 두 모델의 행 단위 근거 묶음, 바뀐 지우기 목록을 남긴다.

## 6. 하지 않는 것

- 문자열·정규식으로 낡은 상태를 찾지 않는다(`forbidden#string_matching`).
- 숫자 한도나 시간으로 패스를 돌리거나 fact 를 없애지 않는다. TTL 을 두지 않는다(`forbidden#magic_number`, `no_wall_clock_death`).
- 프롬프트에 새 규칙 문장을 넣지 않는다.
- continuity·working_context 슬롯은 고치지 않는다.
- 옛 G3(판정 단어)를 읽는 호환 코드를 두지 않는다.
- F1 지표로 패스나 커밋을 막지 않는다. Keeper 에게 지표를 보여 주지 않는다.
- journal 형식을 바꾸지 않는다.

## 7. 정할 것

### 7.1 후보와 무관한 정리를 어디서 할지

후보가 전부 일시 상태인 admission 은 낡은 상태를 못 지운다. cleanup 은 한도를 넘을 때만 돈다.
본문은 한도에 여유가 있어도, 대화가 비어도 정리하라고 한다(30, 91행). 정책은 지지 없는 변경을 막는다(611-615행).

| 안 | 무엇 | 좋은 점 | 나쁜 점 |
| --- | --- | --- | --- |
| A1 (추천) | admission 이 지우기만 하는 변경은 후보 지지 없이 받는다. `verify_support` 와 정책 613-615행을 같이 고친다 | admission 은 매번 기억 전체를 읽는다. 패스를 늘리지 않는다. 하네스로 바로 잰다(E-synth 의 27개가 닿는다). 정책 600행의 "current Memory and settled observations" 만으로 하는 판단이다. 본문과 정책의 충돌도 풀린다 | 지우기는 확인이 없다(§7.2). 후보와 무관한 지우기가 admission 답에 섞인다. 하네스 라벨의 "지지 후보 없는 요청에는 심지 않는다" 규칙을 되돌린다 |
| A2 | cleanup 을 한도 말고 사건에도 돌린다. 사건은 admission 이 지지 후보 없이 끝난 것이다 | 지지 규칙을 그대로 둔다. cleanup 프롬프트는 이미 기억 전체를 검토한다 | 지난 판정 결과로 다음 패스를 고른다. evidence 를 scheduling 에 쓰는 셈이다. 한도를 낮추면 `magic_number`, 주기로 돌리면 `no_wall_clock_death` 와 부딪힌다. cleanup 을 재는 하네스가 없다 |
| A3 | 지금대로 둔다 | 바꿀 것이 없다 | 낡은 상태는 지지 후보가 오거나 한도를 넘을 때까지 남는다. 라이브 admission 99건 중 11건이 이 경우였다 |

### 7.2 지우기를 확인할지

| 안 | 무엇 | 좋은 점 | 나쁜 점 |
| --- | --- | --- | --- |
| B1 | 확인하지 않는다(지금) | 단순하다. journal 이 지운 문장과 사유를 남긴다 | 틀린 지우기는 지식을 조용히 잃는다 |
| B2 | Jev 지우기 게이트를 둔다. 지운 fact 의 지식이 정말 낡았거나 다른 fact 에 있는지 판정한다 | 흡수와 같은 수준으로 확인한다 | `gates` 는 게이트 추가를 success_bar 를 다 넘은 뒤 하나씩 하라고 한다. 지금은 그 단계가 아니다 |
| B3 (추천) | 먼저 잰다. F1 로 패스별 지우기 수를, 하네스의 블라인드 판정으로 라벨 밖 지우기를 본다. 그 뒤 B1·B2 를 고른다 | 숫자를 보고 정한다. A1 을 고르면 늘어나는 지우기도 같이 본다 | 확인이 늦다 |

### 7.3 admission 이 빈 입력 칸을 그릴지

admission 은 대화·도구·continuity 칸을 빈 값으로 그린다. 그 칸을 읽는 설명 3,618바이트도 같이 보낸다(343-359, 385-422행).

| 안 | 무엇 | 좋은 점 | 나쁜 점 |
| --- | --- | --- | --- |
| C1 | admission 은 빈 칸과 그 설명을 그리지 않는다 | 요청마다 약 3.6 KB 가 준다 | 템플릿이 패스마다 갈린다. 효과를 아직 모른다 |
| C2 (추천) | 먼저 P 의 한 갈래로 잰다(`--template`). 나빠지지 않으면 C1 로 간다 | 하네스가 잰다 | P 를 한 바퀴 더 돈다 |
| C3 | 지금대로 둔다 | 바꿀 것이 없다 | 요청마다 약 3.6 KB 가 간다 |

## 8. 참고

- [연구 문서](../research/2026-11-09-librarian-keeps-one-correct-fact.md), [측정 기록](../evidence/research/2026-11-09-librarian-memory-state/README.md)
- T 스택: #50181(라벨 밖 지우기를 블라인드로 판정), #50290(계약 안 라벨), #50325(남는 기억 채점)
- [librarian-absorb-gate](RFC-librarian-absorb-gate.md): 흡수 게이트. [RFC-0463](RFC-0463-librarian-absorb-rewrite-round.md): 흡수 2단계
- [keeper-recall-reaches-the-turn](RFC-keeper-recall-reaches-the-turn.md): 틀린 fact 가 Keeper 턴에 들어가는 길
- [RFC-0514](RFC-0514-a-model-the-catalog-lacks-becomes-an-exact-slot-when-its-binding-declares-capabilities.md): 학습한 모델을 exact 슬롯에 올리는 길
- Anthropic, [The components of agent memory](https://www.anthropic.com/research/components-of-agent-memory) (2026-11-06)
- Google, [Agent Distraction](https://developers.googleblog.com/agent-distraction/) (2026-11-06)
