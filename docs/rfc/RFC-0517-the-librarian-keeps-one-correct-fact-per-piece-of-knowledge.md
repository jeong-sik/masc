---
rfc: "0517"
title: "librarian 은 지식마다 맞는 fact 하나를 남긴다"
status: Draft
created: 2026-11-09
updated: 2026-11-13
author: claude
supersedes: []
superseded_by: null
related: ["librarian-absorb-gate", "0463", "keeper-recall-reaches-the-turn", "0514"]
---

# RFC-0517 — librarian 은 지식마다 맞는 fact 하나를 남긴다

- Status: **Draft.** 사용자가 2026-11-09 에 방향을 정했다. "틀리는건 지우거나 흡수, 병합되어서 맞는 사실 1개만 남기고 그리고 문장을 정리해서 올바르게 기억을 남기는게 중요함". 같은 날 librarian 프롬프트와 기능도 같이 고치라고 했다.
- 근거: [연구 문서](../research/2026-11-09-librarian-keeps-one-correct-fact.md)와 [측정 기록](../evidence/research/2026-11-09-librarian-memory-state/README.md). 이 RFC 의 숫자는 연구 문서에 출처가 있다. §2.1 의 교사와 학습 split 숫자는 [2026-11-12 측정 기록](../evidence/research/2026-11-12-librarian-teacher-label-note/README.md)에 있다. A 를 판정한 숫자는 [2026-11-12 판정 기록](../evidence/research/2026-11-12-librarian-candidate-a-verdict/README.md)에 있다.
- 하네스 쪽 구현은 T 스택이 한다. #50290 이 계약 안에서 맞힐 수 있는 라벨을, #50325 가 남는 기억 채점을 넣는다.
- 2026-11-13 에 사용자가 §7 의 세 가지를 골랐다. 7.1 은 A1 을 넓혀 합치기까지 받는 안이고, 7.2 는 B3, 7.3 은 C2 다.
- 2026-11-10 에 사용자가 F1 두 가지를 정했다. `pass` 는 커밋 함수의 필수 인자로 받는다. 흡수 게이트 판정은 두 길에서 슬롯 라벨 없이 센다(§2.2).
- 2026-11-12 에 사용자가 학습 단계를 A 의 판정 결과로 닫았다. A 는 운영 슬롯에 올리지 않고, 이 RFC 의 범위에서는 다시 학습하지 않는다(§2.1, §4).

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

- 라벨은 MASC 계약 안에서 맞힐 수 있는 답만 요구한다. 지지 후보가 없는 요청은 기억을 바꾸지 않는 답이 맞다. 그 기억에 심긴 낡은 상태와 중복 쌍도 그대로 둔다.
  §7.1 에서 고른 안이 계약을 바꾸면 이 규칙도 따라 바뀐다. 바뀌는 라벨은 §7.1 에 적었다.
- 합친 claim 이 지식을 잃지 않는지는 블라인드 판정자가 본다.
  분류는 라이브 Jev 와 같은 네 갈래(mergeable·different_context·loses_knowledge·uncertain)이고, mergeable 만 맞다. 라벨이 바란 흡수와 라벨 밖 흡수를 모두 판정한다.
- 교사 필터는 흡수를 모두 버리지 않는다. 라벨이 바란 흡수와 mergeable 로 판정된 흡수는 남긴다. 낡은 상태를 흡수한 답은 버린다.
- G3 는 남는 기억 정확도와 낡은 상태 지우기 정밀도·재현율을 읽는다. 합침은 새 G6 가 읽는다.
  G6 값과 새 프롬프트 기준 G2 는 기본 모델을 잰 뒤, 학습 전에 사용자가 정한다.
- 판정 단어 정확도는 기록만 한다. 옛 G3 를 읽는 코드는 남기지 않는다.
- 교사도 effort `low` 로 답한다. `high` 는 유효 답 정확도가 같았고(0.750, 기본 0.751) 토큰·시간이 p50 기준 약 5.2배였다.
- 교사에게는 요청과 스키마 안내 사이에 그 요청의 라벨을 적은 글을 보낸다.
  글은 후보마다 라벨의 종류와 대상 기억을 적고, 기억에서는 심은 낡은 상태, 쓸 날이 지난 기록, 쓸 날이 남은 기록, 중복 쌍을 적는다.
  라벨을 모르고 답하면 필터를 통과하는 답이 지울 것도 합칠 것도 없는 요청에 몰린다. 합친 E-synth 90건의 기준선 두 번에서, 후보가 기억 변경을 지지하는 71건 중 낡은 상태나 중복 쌍이 심긴 52건은 3건씩만 통과했다. 심긴 것이 없는 19건은 16건과 14건이 통과했다([측정 기록](../evidence/research/2026-11-12-librarian-teacher-label-note/README.md)).
  학습 예시의 메시지는 요청, 스키마 안내, 답 셋이다. 라벨 글은 메시지로 들어가지 않는다.
  답의 `reason` 칸은 교사가 쓴 글이라 라벨 글의 말을 되풀이할 수 있다. `reason` 을 읽는 검사는 없다.
- 학습 split 도 E-synth 와 같은 블라인드 라벨 감사를 거친 뒤 교사에게 간다. 교사가 라벨을 따라 답하므로 틀린 라벨은 틀린 학습 목표가 된다.
  `teacher_sample.py sample` 은 감사에 case 가 없는 요청을 받지 않는다. 감사가 뺀 요청과 감사가 뺀 기억의 요청도 받지 않는다.
  감사를 여럿 주면 한 감사가 뺀 요청은 다른 감사가 남겼어도 받지 않는다. 요청과 case 는 item ID 로 맞춘다. 감사 기록에는 판정한 요청 파일의 sha256 이 없다.
  고정되지 않은 세트(감사 전 E-synth 배치, 학습 split)의 기본 답은 `audit_baseline.py` 가 받는다. `eval_admission.py run` 은 고정된 E-synth 만 받는다.
  기본 답이 라벨과 같아도 라벨이 맞다는 근거는 못 된다. E-synth 배치 2 감사에서 기본 답이 라벨과 같았거나 무효였던 57건 중 21건의 라벨이 판정과 어긋났다(같은 측정 기록).
- A 는 교사 답을 한 번만 돌며 학습한다. 예시 하나는 optimizer step 하나에만 들어간다.
  그래서 step 의 loss 는 그 예시를 학습하기 전의 가중치로 잰 값이다. 같은 기억의 요청들은 그 기억의 fact 를 같이 쓰므로, 처음 보는 기억에서 잰 loss 는 아니다.
  한 step 에 예시 4건을 넣는다. 이 값을 다른 값과 견준 측정은 없다. 2026-11-12 에 읽은 Tinker 문서(LoRA 입문, supervised learning 하이퍼파라미터)에도 이 모델의 batch 크기는 없다.
- 학습 예시는 교사 폴더에서 `teacher_sample.py apply` 와 같은 방법으로 읽는다. `accepted.jsonl` 은 읽지 않는다.
  기록에 적힌 답은 호출 기록에 남은 교사 답과 같아야 한다. 호출은 요청, 라벨 글, 스키마 안내와 지금 pass lines 의 effort·출력 상한으로 찾는다.
  그래서 다른 effort 로 받은 답, 라벨 글이 달랐을 때 받은 답, 손으로 고친 답은 학습에 들어가지 않는다. 답은 제 요청의 교사 필터도 다시 통과해야 한다.
  예시는 교사가 답한 effort 로 렌더링한다. Tinker 안내는 답을 만든 effort 와 학습 예시를 렌더링하는 effort 를 같게 두라고 한다.
  예시에서 모델 메시지는 답뿐이고 생각 부분이 없다. 그래서 A 는 답을 바로 쓰도록 학습된다. 기본 모델은 같은 effort 에서 생각 부분을 먼저 썼다(학습 split 기준선 384건 모두).
  끝까지 묻지 못한 교사 실행으로는 학습을 시작하지 않는다. 예산에서 멈춘 실행과 요청이 HTTP 오류로 끝난 실행이 그렇다. 라벨 감사를 적지 않은 실행도 받지 않는다.
  기록은 요청을 item ID 로만 가리킨다. 그래서 item ID 가 겹치는 요청 파일은 교사 샘플링부터 받지 않고, 한 요청에 기록이 둘이면 멈춘다.
  기록 파일의 줄 수가 교사 요약이 센 수와 다를 때도 멈춘다.
  학습 실행은 판정이 읽는 `summary.json` 을 먼저 쓴다. 그 뒤 optimizer 상태가 든 체크포인트를 7일 기한으로 저장하고 경로를 `state.json` 에 적는다. 한 번 도는 중에 실패하면 체크포인트는 남지 않는다.
- 2026-11-12 에 A 를 한 번 학습하고 고정 게이트로 판정했다. A 는 G5(지연)만 통과했고 운영 슬롯에 올리지 않는다([판정 기록](../evidence/research/2026-11-12-librarian-candidate-a-verdict/README.md)).
  A 는 E-real 49건과 E-synth 90건 모두 생각 부분 없이 답했다. 지연 p50 은 기본 모델의 0.61배가 됐다.
  학습이 겨냥한 행동은 늘지 않았다. 심은 낡은 상태는 기본 모델과 A 모두 81개 중 18개를 지웠다. 라벨이 바란 합침은 37개 중 기본 모델이 9개, A 가 6개를 했다.
  무효 답과 라벨 밖 지우기는 늘었다. E-real 유효율은 42/49 에서 38/49 가 됐다. E-synth 의 라벨 밖 지우기는 9개에서 19개가 됐고, 블라인드 판정자는 28개 모두 남겨야 할 fact 로 봤다.
  기본 모델도 G1·G3·G6 선에 닿지 않는다. 남는 기억 108/125, 지우기 정밀도 34/43, 낡은 상태 재현율 18/81, 흡수 정밀도 8/16, 판정 합침 재현율 6/37 이다.

### 2.2 D2 — 기억이 바뀌는 모습을 보인다 (F1)

목적은 셋이다.

- P(프롬프트)와 학습이 라이브 기억을 어떻게 바꿨는지 잰다.
- 하네스가 재지 않는 durable·cleanup 패스를 본다.
- 롤아웃 앞뒤를 같은 표로 견준다.

Prometheus 지표는 기존 recall 지표처럼 `Otel_metric_store` 에 `keeper` 라벨을 달아 센다(`lib/keeper/keeper_memory_recall_turn.ml:46-49`).
이름은 `Keeper_metrics` 의 닫힌 variant 로 둔다.

| 이름 | 종류 | 라벨 | 세는 자리 |
| --- | --- | --- | --- |
| `masc_keeper_memory_changes_total` | counter | `keeper`, `pass`, `change` | 저장소 커밋 함수가 커밋을 마치고 lock 을 놓은 뒤 |
| `masc_keeper_memory_facts` | gauge | `keeper` | 커밋 안에서 lock 을 쥔 채 커밋 순서대로 둔다. 파일 I/O 는 없다. 커밋 뒤 fact 수 |
| `masc_keeper_memory_snapshot_bytes` | gauge | `keeper` | 같은 자리. 커밋 뒤 fact 를 그린 바이트로, 건강 행과 같은 셈이다 |
| `masc_keeper_librarian_absorb_sources_total` | counter | `keeper`, `outcome`, `decision` | 흡수 게이트 판정이 끝나는 두 자리 |
| `masc_keeper_librarian_absorb_copy_checks_total` | counter | `keeper`, `verdict` | 같은 두 자리 |

- `pass` 는 커밋을 부른 패스가 닫힌 variant 로 넘긴다. 값은 일곱이다.
  - admission, durable, continuity, cleanup
  - Keeper 직접 쓰기, Keeper 직접 지우기, 운영자 지우기
- program 발행은 그것을 부른 레인의 값으로 센다. durable 원문이 거절된 뒤의 floor 는 durable 이고, 메시지 단위 continuity 는 continuity 다.
- 저장소 커밋 함수가 `~pass` 를 필수로 받는다. 빠진 자리를 컴파일러가 잡는다(사용자 2026-11-10).
  - 함수: `Keeper_memory_os_current` 의 `apply_disposition`·`apply_disposition_guarded`·`apply_program`·`upsert_fact`·`supersede_fact`·`retract_fact`·`retract_facts`
  - runtime 의 `run_best_effort` 는 pass 를 `write_scope` 로 받는다. 기억을 쓰는 scope 만 pass 를 품는다. 기억을 쓰지 않는 working context 실행(`Context_only`)은 pass 가 없다.
  - 운영자 지우기는 대시보드 기억 정리(`server_dashboard_http_keeper_memory_cleanup.ml` 의 `retract_facts`)다.
  - 시험의 `~pass`·`write_scope` 는 기계적 커밋으로 따로 올린다.
- `change` 는 서로 겹치지 않는 넷이다. ID 로 센다.
  - `added`: 새 claim. 커밋 전에 없던 ID 다.
  - `absorbed`: 흡수로 빠진 fact(`absorbed_applied`)
  - `superseded`: 교정(`supersedes`)으로 빠진 fact(`revisions_applied`)
  - `dropped`: 뒤를 잇는 claim 없이 빠진 나머지 fact. `invalidated` 도 여기에 든다.
- program 은 단계가 여럿이어도 한 번 센다. 첫 단계 전 fact 와 마지막 단계 뒤 fact 를 견주고, 단계마다 적용한 흡수·교정을 합친다. 중간 단계에만 있던 ID 는 세지 않는다.
  - 흡수·교정으로 빠진 fact 는 이어 받은 claim 을 뒤 단계까지 따라가 마지막 fact 에 닿을 때만 `absorbed`·`superseded` 다. 종류는 처음 빠진 방식을 따른다. 끝이 마지막 fact 에 없으면 `dropped` 다. disposition 커밋이 교정한 claim 을 snapshot 에 요구하는 것과 같다.
- ID 는 같고 내용만 바뀐 fact 는 `added`·`removed` 에 다 들어 있다. 이런 fact 는 넷 중 어디에도 세지 않는다.
- 커밋이 `Unchanged` 면 세지 않는다. 그때 snapshot 의 `change` 는 앞선 커밋의 것이다.
- `outcome` 은 forward 결과(conveyed·left·unjudged·unjudgeable)다. `decision` 은 원문 판정(mergeable·different_context·loses_knowledge·uncertain)이고, 판정이 없으면 `none` 이다. conveyed 의 판정은 늘 mergeable 이다.
- `verdict` 는 reverse 판정(copy·carries_new_statement·not_judged)이다.
- 흡수 게이트 판정은 두 자리에서 센다(사용자 2026-11-10).
  - runtime 경로는 `run_resolved`(`lib/keeper/keeper_librarian_absorb_gate.ml`)에서 판정이 끝날 때 센다. 지금 판정 로그는 여기에만 있다.
  - admission·durable·floor 는 캡처한 판정을 이어 받는다. 판정 끝 기록(`Judgment_retained`·`Refused`)을 저장한 뒤 `Keeper_librarian_original_gate.resume` 에서 센다.
  - `restore_with`·`continue_captured` 는 세지 않는다. `restore_with` 는 Keeper 를 모르고, 기록을 읽을 때마다 다시 돈다.
  - 끝 기록 저장이 실패하면 그때는 세지 않고, 다음 이어 받기가 저장한 뒤 센다. 판정 하나는 많아야 한 번 센다.
  - 두 자리가 같은 셈 함수(`count_judgment`)를 부른다.
- 슬롯 라벨은 두지 않는다. 캡처를 이어 받는 길은 답한 레인 슬롯을 모른다.
  롤아웃은 올리기 전·후 시간 창으로 견준다. 슬롯별로 나눠야 하면 exact 요청 기록과 맞춰 따로 본다.

건강 행은 schema `keeper.memory_os.current_health.v14` 로 올린다(지금 v13, `lib/server/server_dashboard_http_keeper_memory_health.ml` 의 `schema`).

- 서버가 뜬 뒤의 셈을 Keeper 마다 `pass` × `change` 로 싣는다. 위 counter 와 같은 값이다.
- 크기 추이를 싣는다. journal 의 커밋마다 `retained + added` 가 그 커밋 뒤의 fact 수다.
  - 건강 행이 이미 쓰는 `Keeper_memory_journal_outcome` 의 접기에서 같이 모은다.
  - `unchanged` 행의 `change` 는 같은 fact 끼리 견준 것이다. `added`·`removed` 는 비어 있고, `retained` 가 그 커밋 뒤의 fact 수다.
  - 한 시간마다 그 시간 마지막 커밋 뒤의 fact 수를 기록 시각과 같이 싣는다. 최근 168시간(7일)만 싣는다. 롤아웃 앞뒤 24시간을 넉넉히 덮는 길이다.
  - journal 에는 F1 이전 커밋도 있다. 그래서 롤아웃 전 기준선을 따로 모으지 않는다.
- 지금 칸(fact 수, 바이트, 마지막 커밋의 `added`·`removed`)은 그대로 둔다.
- schema 를 올리면 서버와 TUI 디코더(`lib/tui_decode_memory_health.ml`), 대시보드(`dashboard/src/api/dashboard-misc.ts`), 그 시험들이 같이 바뀐다.
  - counter 이름과 `change` 라벨은 `Keeper_memory_commit_change` 한 곳에 둔다. store 가 올린 셈을 건강 행이 같은 이름으로 읽는다.

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
| F1 | 지표 다섯, 커밋 함수의 필수 `pass`, 건강 행 v14, 기능 시험 하나 | main 위 별도 스택. 지표 이름, 셈 모듈, 부르는 자리, 시험의 `~pass`, 크기 추이, schema 순서로 층을 나눈다 |
| P | 프롬프트 정리안, 고정 기준, 두 모델의 근거 묶음 | main 위 별도 스택 |
| §7 | 7.1 의 계약, 하네스 검사기, 정책 문장. 7.2·7.3 은 측정 | main 위 별도 스택. 이 RFC 결정 기록, 계약, 하네스, 프롬프트 순서로 층을 나눈다 |

- 순서는 H → P → 학습 → 롤아웃이다. F1 은 P 와 나란히 간다.
- 학습은 2026-11-12 에 A 의 판정으로 끝났다. A 가 G5 만 통과해서 롤아웃은 하지 않았다(§2.1).
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
| A1 (추천) | admission 이 지우기만 하는 변경은 후보 지지 없이 받는다. `verify_support` 와 정책 613-615행을 같이 고친다 | admission 은 매번 기억 전체를 읽는다. 패스를 늘리지 않는다. 하네스로 바로 잰다(E-synth 의 27개가 닿는다). 정책 600행의 "current Memory and settled observations" 만으로 하는 판단이다. 본문과 정책의 충돌도 풀린다 | 지우기는 확인이 없다(§7.2). 후보와 무관한 지우기가 admission 답에 섞인다. 하네스 라벨의 "지지 후보 없는 요청은 심긴 것을 그대로 둔다" 규칙을 되돌린다 |
| A2 | cleanup 을 한도 말고 사건에도 돌린다. 사건은 admission 이 지지 후보 없이 끝난 것이다 | 지지 규칙을 그대로 둔다. cleanup 프롬프트는 이미 기억 전체를 검토한다 | 지난 판정 결과로 다음 패스를 고른다. evidence 를 scheduling 에 쓰는 셈이다. 한도를 낮추면 `magic_number`, 주기로 돌리면 `no_wall_clock_death` 와 부딪힌다. cleanup 을 재는 하네스가 없다 |
| A3 | 지금대로 둔다 | 바꿀 것이 없다 | 낡은 상태는 지지 후보가 오거나 한도를 넘을 때까지 남는다. 라이브 admission 99건 중 11건이 이 경우였다 |

사용자는 2026-11-13 에 A1 을 넓힌 안을 골랐다. 표의 A1 은 지우기만 받는다. 고른 안은 합치기도 받는다.

- admission 은 후보와 무관한 지우기와 합치기를 지지 후보 없이 받는다. 합치기는 기존 기억을 `absorbs` 로 묶은 새 claim 이다.
- 기존 기억을 하나도 묶지 않은 새 claim 은 지금처럼 그 claim 을 가리키는 `incorporated` 지지 후보가 있어야 한다. 교정(`supersedes`)으로 쓴 claim 도 같다.
- `change_support` 에 적은 요청은 지금처럼 겹치지 않고, 판정이 끝난 `incorporated`·`already_represented` 후보여야 한다.

넓힌 까닭은 이렇다.

- 고정 기준선(#51780)의 무효 답 가운데 지지 검사에 걸린 답은 모두 `new_claim_without_support` 였다. E-synth 에서 Inkling 3·4건, GLM 2건이고, E-real 에서 GLM 3건이다.
  지우기만 하는 변경이 지지 없이 걸린 답(`changes_without_support`)은 없었다. 표의 A1 만으로는 무효 답이 하나도 살지 않는다.
- E-synth 의 9건에서 후보가 가리키지 않은 새 claim 은 모두 기존 기억 1~4개를 `absorbs` 로 묶은 합침이었다. 기존 기억을 묶지 않은 새 claim 은 없었다.
  사용자가 바란 "병합되어서 맞는 사실 1개만" 남기는 답이다. 지금 계약은 이런 답을 통째로 거절한다.
- 라이브 저장소에서도 GLM 의 admission 시도 7번이 같은 까닭으로 거절됐다. 2026-11-13 에 exact 요청 기록을 읽어 셌다.

합친 claim 을 보는 검사는 이렇다.

- 흡수 게이트가 켜져 있으면 forward 판정이 원래 기억마다 그 지식이 합친 claim 에 담겼는지 본다. 담기지 않은 원래 기억은 지워지지 않는다.
- 합친 claim 이 원래 기억에 없는 말을 더했는지는 어느 검사도 보지 않는다. reverse 판정은 원래 기억을 하나도 흡수하지 못한 claim 이 그 기억의 복사인지만 본다.
  지금 계약도 `incorporated` 후보가 가리킨 claim 의 내용은 보지 않는다(`verify_support` 의 주석).
- 그래서 이 결정은 후보 없이 새 문장이 들어오는 길을 연다. 하네스의 합침 판정과 §7.2 의 측정이 이 몫을 본다.

층과 순서는 이렇다.

- 계약: `verify_support` 와 admission 의 호출 자리를 고친다. 시험은 지지 후보 없는 지우기·합치기가 커밋되는지, 기존 기억을 묶지 않은 새 claim 과 교정 claim 이 거절되는지 본다.
- 하네스: `admission_judgment.py` 가 같은 규칙을 따른다. pass lines 를 다시 고정하고, 고정한 기준선 답을 새 검사로 다시 센다. 새로 유효해진 답의 지우기와 합치기는 블라인드 판정자가 본다. 모델은 다시 부르지 않는다.
- 프롬프트: 정책 문장(librarian.md 606-612행)을 새 계약대로 고치고, §2.3 의 들이는 기준으로 두 모델을 다시 잰다. 돌리기 전에 비용을 사용자에게 묻는다.
- 라벨: 새 E-synth 는 만들지 않는다. 고정한 E-synth 90건 중 지지 후보가 없는 요청은 19건이다.
  이 19건에도 낡은 상태 21개와 중복 쌍 7개가 이미 심겨 있다. `synth_rows.label_of_row` 로 읽은 라벨을 셌다.
  지금 라벨은 이 요청의 답이 심긴 것을 그대로 두기를 바란다(§2.1). 채점기(`memory_scores.score_synth`)는 그 칸을 빼고 센다.
  하네스 층에서 이 조건을 걷으면 이 결정의 효과를 고정한 E-synth 에서 모델 호출 없이 잰다.
- 라이브 admission 은 2026-11-11 17:45 KST 뒤로 끝난 요청이 없다. 쌓인 후보가 한 요청에 실려 슬롯 창을 넘는 문제(#49910)다. 그래서 이 결정의 라이브 효과는 그 문제가 풀린 뒤에 본다.

### 7.2 지우기를 확인할지

| 안 | 무엇 | 좋은 점 | 나쁜 점 |
| --- | --- | --- | --- |
| B1 | 확인하지 않는다(지금) | 단순하다. journal 이 지운 문장과 사유를 남긴다 | 틀린 지우기는 지식을 조용히 잃는다 |
| B2 | Jev 지우기 게이트를 둔다. 지운 fact 의 지식이 정말 낡았거나 다른 fact 에 있는지 판정한다 | 흡수와 같은 수준으로 확인한다 | `gates` 는 게이트 추가를 success_bar 를 다 넘은 뒤 하나씩 하라고 한다. 지금은 그 단계가 아니다 |
| B3 (추천) | 먼저 잰다. F1 로 패스별 지우기 수를, 하네스의 블라인드 판정으로 라벨 밖 지우기를 본다. 그 뒤 B1·B2 를 고른다 | 숫자를 보고 정한다. A1 을 고르면 늘어나는 지우기도 같이 본다 | 확인이 늦다 |

사용자는 2026-11-13 에 B3 을 골랐다. §7.1 로 늘어나는 지우기와 합치기를 같이 잰다. 합친 claim 이 원래 기억에 없는 말을 더했는지도 본다. 숫자를 본 뒤 B1·B2 를 고른다.

합친 claim 이 더한 말은 하네스가 이렇게 잰다.

- 합친 claim 은 기존 기억을 하나 이상 `absorbs` 로 묶은 새 claim 이다. E-synth 실행의 유효 답에서 모은다.
  기존 기억 문장을 그대로 둔 채 다른 기억을 묶은 claim 은 새 문장이 없어서 세지 않는다.
- 블라인드 판정자는 합친 claim 하나마다 case 하나를 받는다. case 에는 그 claim, 그 claim 이 대신하는 원래 기억 전부, 그 claim 의 근거 후보가 있다.
  원래 기억은 그 claim 이 `absorbs` 로 묶은 기억과 `supersedes` 로 고친 기억이다.
  근거 후보는 흡수 게이트가 받는 범위와 같다. `change_support` 에 있고, 판정이 그 claim 을 가리키는 후보다(keeper_librarian_runtime.ml `cited_observations`).
  흡수 게이트와 달리 바이트 한도로 근거 후보를 빼지 않는다.
  판정자는 라벨, 모델, E-synth 요청 ID, 기억 ID 를 보지 않는다. 같은 claim 과 같은 재료를 낸 답들은 case 하나를 같이 쓴다.
- 분류는 셋이다.
  - `no_addition`: claim 의 내용은 모두 원래 기억이나 근거 후보가 말하거나, 그 말에서 바로 나온다. 바꿔 쓰기, 합치기, 순서 정하기, 세부 빼기는 더한 말이 아니다.
  - `adds_unsupported`: 원래 기억과 근거 후보 어디에도 없고 그 말에서 바로 나오지도 않는 사실, 조건, 원인, 수, 이름, 때, 상태를 말한다.
  - `uncertain`: case 만으로는 가를 수 없다.
- 이 판정은 세부가 빠졌는지 보지 않는다. 빠진 세부는 흡수 게이트와 하네스의 합침 판정이 본다.
- 셈은 근거 후보가 있는 합침과 없는 합침을 나눈다. 근거 후보가 없는 합침은 §7.1 전에는 거절되던 답이다.
- 지우기·합침 판정처럼 E-synth 실행만 받는다. 게이트와 pass lines 는 이 숫자를 읽지 않는다.
- 도구는 `scripts/tinker/librarian/merge_additions.py` 다. 판정자 폴더는 합침 판정과 같은 방식으로 쓴다.

### 7.3 admission 이 빈 입력 칸을 그릴지

admission 은 대화·도구·continuity 칸을 빈 값으로 그린다. 그 칸을 읽는 설명 3,618바이트도 같이 보낸다(343-359, 385-422행).

| 안 | 무엇 | 좋은 점 | 나쁜 점 |
| --- | --- | --- | --- |
| C1 | admission 은 빈 칸과 그 설명을 그리지 않는다 | 요청마다 약 3.6 KB 가 준다 | 템플릿이 패스마다 갈린다. 효과를 아직 모른다 |
| C2 (추천) | 먼저 P 의 한 갈래로 잰다(`--template`). 나빠지지 않으면 C1 로 간다 | 하네스가 잰다 | P 를 한 바퀴 더 돈다 |
| C3 | 지금대로 둔다 | 바꿀 것이 없다 | 요청마다 약 3.6 KB 가 간다 |

사용자는 2026-11-13 에 C2 를 골랐다. 빈 칸과 그 설명을 뺀 템플릿을 P 의 한 갈래로 재고, 나빠지지 않으면 C1 로 간다.

- 라이브 저장소에 남은 admission 요청 44건의 프롬프트는 65,618~651,797바이트다(2026-11-13 에 읽음). 빈 칸 설명 약 3.6 KB 는 그 0.6~5.5% 다. 요청 크기는 현재 기억과 쌓인 후보가 정한다.
- 재는 데 Inkling 초안 실행 한 번과 GLM 실행 한 번이 든다. 돌리기 전에 비용을 사용자에게 묻는다.

## 8. 참고

- [연구 문서](../research/2026-11-09-librarian-keeps-one-correct-fact.md), [측정 기록](../evidence/research/2026-11-09-librarian-memory-state/README.md)
- [교사에게 라벨을 보여 주는 변경의 측정 기록](../evidence/research/2026-11-12-librarian-teacher-label-note/README.md)
- T 스택: #50181(라벨 밖 지우기를 블라인드로 판정), #50290(계약 안 라벨), #50325(남는 기억 채점)
- [librarian-absorb-gate](RFC-librarian-absorb-gate.md): 흡수 게이트. [RFC-0463](RFC-0463-librarian-absorb-rewrite-round.md): 흡수 2단계
- [keeper-recall-reaches-the-turn](RFC-keeper-recall-reaches-the-turn.md): 틀린 fact 가 Keeper 턴에 들어가는 길
- [RFC-0514](RFC-0514-a-model-the-catalog-lacks-becomes-an-exact-slot-when-its-binding-declares-capabilities.md): 학습한 모델을 exact 슬롯에 올리는 길
- Anthropic, [The components of agent memory](https://www.anthropic.com/research/components-of-agent-memory) (2026-11-06)
- Google, [Agent Distraction](https://developers.googleblog.com/agent-distraction/) (2026-11-06)
