# RFC-0367 — librarian cadence 는 기제가 아니라 수확 파라미터다

**Status**: Draft
**Author**: Claude Opus 5 (1M context)
**Date**: 2026-08-08
**관련**: #27380 (taskmaster idle-spin), #27537 (레인 폴백 계약), `RFC-memory-os-bounded-context-and-librarian-curator.md` §3.3 · §6

## 1. 배경

librarian 은 keeper 턴 뒤에 cadence 마다 돌면서 memory snapshot 을 큐레이션한다.
cadence 는 순수 턴 카운터다 (`keeper_librarian_runtime.ml:19-49`, 기본 3).

fleet 전체 실측 (`memory os librarian committed ... added=N removed=N` 집계):

| 날짜 | commits | no-op | added | removed |
|---|---|---|---|---|
| 08-06 | 793 | 701 (88%) | 56 | 61 |
| 08-07 | 2,529 | 2,453 (96%) | 28 | 111 |
| 08-08 | 1,126 | 1,095 (97%) | 12 | 34 |

**08-07~08 이틀에 3,655 회의 LLM 큐레이션 패스가 fact 40 추가 / 145 제거를 만들었다.**
`rondo` 는 08-08 에 74 패스 전부가 no-op 이었다. 패스 수는 늘고 산출은 줄어 no-op
비율이 88% → 97% 로 오르는 중이다.

각 패스는 keeper persona (~11KB) + 대화 슬라이스를 실은 full LLM 왕복이다.

## 2. 문제

no-op 이 결함이라는 주장이 **아니다**. 97% 에서 "추가할 것 없음" 은 대체로 옳은
판단이고, librarian 은 그 판단을 정확히 내리고 있다. 문제는 **그 판단을 얻는
단가**다.

핵심 관측: 한 패스가 커버하는 턴 수에 따라 수확이 크게 갈린다. 아래는 오늘·어제
journal commit 을 그 사이 turn-record 개수로 묶은 것이다.

| 커버한 턴 | 패스 | 변경한 패스 | 수확률 | facts/패스 |
|---|---|---|---|---|
| 1 | 5 | 0 | 0.0% | 0.000 |
| 2–3 | **3,105** | 40 | **1.3%** | 0.014 |
| 4–6 | 273 | 9 | 3.3% | 0.077 |
| 7–12 | 50 | 13 | **26.0%** | 0.400 |
| 13–24 | 26 | 5 | 19.2% | 0.385 |
| 25+ | 26 | 9 | **34.6%** | 1.769 |

2–3 턴 창의 수확률은 7–12 턴 창의 **1/20** 이고, facts/패스로는 **1/28** 이다.
cadence = 3 이 **전체 패스의 89% (3,105/3,485) 를 최저 수확 구간에 배치**한다.

## 3. 제안

**cadence 값을 올린다. 새 기제를 도입하지 않는다.**

`librarian_cadence_turns` 를 3 에서 상향한다 (측정 구간상 7–12 이 후보). 코드
변경은 없거나 기본값 한 줄이다.

근거는 이 저장소가 이미 세워둔 방침과 같다 —
`RFC-memory-os-bounded-context-and-librarian-curator.md` §6:

> coalesce 드랍의 실제 커버리지 손실 크기 — 기제 추가가 아니라 journal 실측으로
> 확인하고, **필요하면 cadence만 조정한다.**

같은 RFC §3.3 은 재시도 비용을 "다음 cadence(**3 meaningful 턴**)" 로 적는다.
구현은 meaningful 을 정의하지 않고 raw 턴을 센다. 본 RFC 는 그 간극을 새 술어를
발명해 메우는 대신, **창을 넓혀 같은 효과를 얻는다**.

### 3.1 부작용과 그 크기

cadence 를 올리면 한 패스의 입력 슬라이스가 길어진다.
`prompt_max_messages = max_messages * cadence` (`keeper_librarian_runtime.ml:71-73`)
이므로 cadence 3 → 10 은 프롬프트 상한을 72 → 240 메시지로 늘린다. 패스 수는
~3.3× 줄고 패스당 입력은 최대 ~3.3× 늘어, **총 입력 토큰은 대략 보존되고 왕복
횟수와 고정 오버헤드(persona 11KB × 패스 수)가 줄어든다.**

즉 절감의 주된 출처는 토큰 총량이 아니라 **패스당 재전송되는 고정 블록**과 왕복
지연이다. 이 값은 배포 후 측정으로 확인한다 (§5).

지연 손실: 어떤 사실이 memory 에 들어가기까지 최대 cadence 턴을 기다린다. 3 → 10
이면 최악 7 턴 늦는다. 위 RFC §3.2 는 이 성질을 이미 수용한다 — "librarian 이
cadence 사이에 무언가를 놓치면 그것은 다음 판단이 다룰 일이지 기제가 막을 일이
아니다."

## 4. 검토했으나 채택하지 않은 것

### 4.1 텍스트 유무 게이트 — 측정상 무용

`is_noop_cycle ~has_text ~tools_used` (`keeper_unified_metrics_support.ml:261`) 을
cadence 조건으로 쓰는 안. 실측에서 갈리지 않는다:

| | 변경 패스 (76) | no-op 패스 (3,406) |
|---|---|---|
| 창 안에 출력이 있는 턴 존재 | **100%** | **100%** |
| 창 전체가 무출력 | 0% | 0% |

keeper 는 거의 매 턴 출력을 낸다 (오늘 4,222 턴 중 `output_tokens = 0` 은 14%).
이 술어로는 게이트가 사실상 발화하지 않는다.

### 4.2 도구 실행 게이트 — 신호는 있으나 손실이 크다

| | 변경 패스 | no-op 패스 |
|---|---|---|
| 창 안에 도구 실행 존재 | **56%** | **12%** |

4.7× 로 갈리지만, 이걸로 게이팅하면 패스는 ~87% 줄고 **변경의 44% 를 함께
버린다**. 이미 희소한 신호를 절반 가까이 잃는 거래다.

(오늘 turn-record 기준 도구 실행 없는 턴은 88%. `lane-smith`·`taskmaster` 는
100%, `sangsu` 는 11% 로 keeper 간 편차가 크다.)

### 4.3 문자열 중요도 분류기 — 규칙상 금지

"이 턴이 중요해 보이는가" 를 텍스트로 판정하는 방향. CLAUDE.md 워크어라운드 거부
기준 §2 (문자열/부분문자열 분류기 추가) 에 정면으로 걸린다. 기존
`has_substantive_tool_calls` 가 존재 여부만 세고 이름을 보지 않는 이유와 같다:

```ocaml
(** A cycle is empty only when it emitted neither text nor a tool call. Tool
    meaning is not inferred from its name. *)
```

### 4.4 연속 no-op 후 backoff — 워크어라운드 시그니처

"K 회 연속 no-op 이면 cadence 를 올린다". CLAUDE.md 의 cap/cooldown/dedup/repair
패턴이며 symptom 억제다. 창 크기가 수확을 결정한다는 §2 측정이 있으므로 상태를
들고 다닐 이유가 없다 — 파라미터 하나로 충분하다.

## 5. 검증

배포 전후를 같은 방법으로 잰다. 계측기는 이미 있다.

```bash
# 패스 수와 no-op 비율 (keeper 별)
#  주의: 성공 줄에는 lane= 이 없고 실패 줄에만 있다
#  (keeper_librarian_runtime.ml:500 vs :524). lane= 으로 필터하면 실패만 세게 된다.
rg -c 'memory os librarian committed' ~/me/.masc/logs/system_log_<DAY>.jsonl
rg -c 'memory os librarian failed'    ~/me/.masc/logs/system_log_<DAY>.jsonl
```

수용 기준:

1. 패스 수가 cadence 비율만큼 감소한다 (3 → N 이면 약 N/3 배 감소).
2. **일간 added + removed 총량이 유지되거나 증가한다.** 감소하면 되돌린다 —
   이게 이 변경의 실패 조건이다.
3. no-op 비율이 §2 표의 해당 구간 수확률에 근접한다.
4. `librarian failed` 비율이 악화되지 않는다 (프롬프트가 길어져 컨텍스트 한계나
   truncation 을 새로 유발하지 않는지 확인 — 특히 `local_llama_server` 슬롯).

최소 3 일 관측 후 판단한다. 하루는 keeper 활동량 편차에 묻힌다.

## 6. 열린 질문

- **교란**: §2 의 넓은 창은 cadence 설정이 아니라 coalescing 드랍이나 keeper
  유휴로 자연 발생한 것이다. 넓은 창이 수확이 높은 이유가 *창 폭* 때문인지
  *그 시기에 실제로 많은 일이 있었기 때문*인지 이 데이터로는 분리되지 않는다.
  후자라면 조용한 시기에 cadence 를 올려도 빈 창이 넓어질 뿐이다. §5 의 수용
  기준 2 가 이 경우를 잡는다.
- cadence 를 keeper 별로 둘 것인가. `sangsu` (도구 실행 89%) 와 `lane-smith`
  (0%) 는 활동 성격이 다르다. 전역 값으로 먼저 재고, 편차가 남으면 그때 논의한다.
- `prompt_max_messages` 상한이 cadence 에 선형으로 묶여 있는 것이 맞는가
  (`max_messages * cadence`). cadence 를 크게 올리면 이 곱이 슬롯의 컨텍스트
  예산을 넘길 수 있다. §5 기준 4 가 이를 관측한다.

## 7. 비제안

- librarian 계약 (`retained` / `new_claims` / `dropped` 총체성) 변경 없음.
- memory journal 스키마 변경 없음.
- 새 게이트 모듈·새 상태·새 카운터 없음.
- 레거시 데이터 마이그레이션 코드 없음.
