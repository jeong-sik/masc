---
rfc: "keeper-recall-reaches-the-turn"
title: "Keeper 기억이 턴에 닿게 한다 — 호스트가 이번 입력에 맞는 기억을 골라 싣는다"
status: Draft
created: 2026-10-28
updated: 2026-10-28
author: claude
supersedes: []
superseded_by: null
related: ["deferred-contextual-memory", "keepers-see-the-wiki-table-of-contents", "memory-search-beyond-substring", "0418", "0247"]
---

# RFC: Keeper 기억이 턴에 닿게 한다

- 상태: 초안. 판정 방식(D2)은 운영자가 2026-10-28 에 "LLM 판단 Jev 판단을 적극 사용"으로 정했다. 나머지는 §8 에 열려 있다.
- 날짜: 한국 시간(KST). Board 와 metrics 의 시각은 UTC 로 적고 `Z` 를 붙인다.
- 운영자 요청 (2026-10-28): 모든 Keeper 의 기억 Recall 이 턴 대화에서 쓰여야 한다. 지금은 사실상 쓰이지 않아 Librarian 이 의미를 잃는다. Skill 처럼 기억을 찾게 하고, 위계와 트리로 연결된 기억을 따라가게 하고, 기성 제품과 논문을 보고 빠진 구현을 채우라고 했다.
- 근거: 측정은 [기준선 증거](../evidence/keeper-recall-baseline-2026-10-28/README.md), 기성 제품·논문 대조는 [연구 r1](../research/2026-10-28-keeper-recall-prior-art-r1.md). 코드는 2026-10-28 `origin/main` `de5599529145`.

## 0. 요약

Keeper 의 기억 본문은 프롬프트에 없다. 모델이 `keeper_memory_search` 를 직접 불러야 나온다. 모델은 거의 부르지 않는다. 도구 호출 274,153건 중 기억 검색은 0.80% 이고, 검색의 28.3%는 아무것도 못 찾는다. Librarian 이 하루 1,000건 넘게 기억을 커밋한 날(10-12~22 중 8일)에 같은 날 검색은 커밋의 1/13~1/39 였다.

목록만 보이게 하는 방식으로는 부족하다. 목록이 매 턴 보이는 Skill 도구도 0.60% 만 불린다. 밖에서도 같은 결과가 나왔다(연구 r1 §3.1).

이 RFC 는 호스트가 이번 턴 입력을 보고 키퍼의 기억 중 필요한 것을 판정해 본문째 싣는 층을 만든다. 점수·키워드·상위 N개는 쓰지 않는다. 판정은 두 단계다. Jev(TypeSafe)가 후보 전체를 닫힌 선택으로 가려내고, in-house 레인 `memory_recall_exact` 가 고른 것만 이유와 함께 확정한다. Jev 를 못 쓰면 레인이 두 단계를 모두 맡는다. 결과는 새 프롬프트 블록 `Recalled_memory` 로 매 턴 보낸다. 제목·안정 id·연결·트리는 저장 계약을 바꾸는 일이라 이 RFC 에서 구현하지 않고 §5 에 방향만 적는다.

## 1. 결정

- **D1.** 기억을 모델이 찾아야만 나오는 구조를 그대로 두지 않는다. 호스트가 이번 턴에 맞는 기억을 골라 싣는다.
- **D2.** 고르는 일은 LLM 판단과 Jev 판단이다. 1단계는 Jev 가 후보 전체를 가려내고, 2단계는 in-house exact-output 레인 `memory_recall_exact` 가 고른 후보만 이유와 함께 확정한다. Jev 를 쓸 수 없는 Keeper(제외 목록, 스위치 꺼짐, 실패)는 레인이 1단계도 맡는다. 확신도 숫자로 단계를 가르지 않는다. 운영자가 정했다(2026-10-28, "LLM 판단 Jev 판단을 적극 사용").
- **D3.** 고른 기억은 새 블록 `Recalled_memory` 로 첫 라운드에만 싣는다. 공식 클라이언트에는 같은 바이트라도 매 턴 보낸다.
- **D4.** 스위치 `[memory_recall] enabled` 의 기본값은 꺼짐이다. 카나리 Keeper 로 먼저 켜고 측정한 뒤 넓힌다.
- **D5.** 측정은 질문 묶음 채점이 주 지표이고 도구 호출 수는 보조다(위키 목차 RFC 의 D5 와 같다).
- **D6.** 판정이 못 돌면 "없음"이 아니라 "판정 못 함"과 이유를 싣는다. 조용히 비우지 않는다.
- **D7.** 이 RFC 는 저장 계약(제목, 안정 id, 연결, 트리)을 바꾸지 않는다. 그 층은 §5 에서 따로 정한다.

## 2. 무슨 일이 났나

수치는 2026-10-28 라이브 base path 에서 `scripts/keeper-recall-baseline.py` 로 셌다. 10-02 이후 기록이고, 로그가 회전해서 모두 하한이다.

### 2.1 기억이 거의 안 읽힌다

- 도구 호출 274,153건 중 `keeper_memory_search` 2,193건(0.80%), Skill 도구 1,657건(0.60%), 위키 도구 248건(0.09%), `keeper_workspace_memory_read` 38건(0.01%). `keeper_memory_write` 는 4,788건(1.75%)이라 쓰기가 읽기의 두 배가 넘는다.
- 도구를 쓴 턴 100개당 검색한 턴은 `claude_code` 1.5, `codex` 5.1, `muse` 6.2, `glm-coding` 11.3, `antigravity` 12.9 다.
- 검색 2,190건 중 620건(28.3%)이 아무것도 못 찾았다. 없는 것을 찾았을 수도 있어서 품질의 상한선만 알려 준다.
- LLM 이 골라 주는 `keeper_memory_select` 는 호출이 1번뿐이다. `workspace_memory_selection_enabled` 의 기본값이 false 이고(`lib/runtime/runtime_schema.ml:577`) 라이브 설정에서 켜지 않았다.

### 2.2 왜 그런가

1. **본문이 프롬프트에 없다.** 라이브 프롬프트에 닿는 기억 정보는 "사실 N개" 안내문(`lib/keeper/keeper_memory_os_recall.ml:115`, 약 1.1KB)과 working-context 포인터 약 0.35KB 뿐이다. 본문은 10-01~02 에 뺐다(#40473, #40782). 당시 기억 블록이 조립된 88,177B 중 51,518B 였고 캐시 비용이 컸다(`lib/types/prompt_block_id.mli` 의 측정 주석).
2. **개인 기억을 호스트가 고르는 길이 없다.** 선택기(`lib/keeper/keeper_memory_select.ml`)는 모델이 도구로 불러야만 돈다(`lib/keeper/keeper_tool_runtime.ml:362`). 호스트가 턴마다 고르는 `Keeper_workspace_memory_host_recall`(`lib/keeper/keeper_run_tools_hooks.ml:1061`)은 공용 기억용이고, 읽기 도구가 없을 때만 붙는다.
3. **공식 클라이언트는 같은 내용을 다시 받지 않는다.** `Prompt_block_id.resent_when_held`(`lib/types/prompt_block_id.ml:102`)가 `Memory_os_recall` 에 false 다. 이미 보낸 바이트는 건너뛰므로(`lib/keeper/keeper_official_client_context_projection.ml:351`, `:559`) 안내문이 세션 깊숙이 한 번만 있다. 프롬프트 텍스트에 안내문이 새로 실린 실행의 비율은 Claude Code 5%, Codex 5~29%, Muse 31%, Antigravity 100% 다. 같은 모델 `muse-spark-1.3` 안에서 새로 실린 실행은 13.7%, 아닌 실행은 2.2% 검색했다. `claude-sonnet-5-5` 는 새로 실려도 0/39 였다. 그래서 전달 횟수가 한 원인이고 전부는 아니다. API 레인이 매 턴 첫 라운드에 받는다는 것은 코드 주석을 읽어 안 것이고 잰 것은 아니다.
4. **기억의 이름이 자주 바뀐다.** 기억 id 는 claim 의 SHA-256 이다(`lib/keeper/keeper_memory_os_types.ml:734`). Librarian 이 문장을 다시 쓰면 id 가 바뀐다. 개정 사건 11,693건이 쌓였고 회수 이벤트 19,214건 중 16,240건(84.5%)이 이미 없는 id 를 가리킨다. 사용 이력도, 연결도 이 id 에 걸 수 없다.
5. **밖에서도 같다.** OpenClaw, Hermes, Pi, Codex, Claude Code 모두 "색인과 모델의 도구 호출" 구조에서 안 당긴다는 보고가 있다. 본문까지 호스트가 넣는 곳은 OpenClaw, Hermes 외부 provider, 예전 Claude Code 뿐이다(연구 r1 §2).

### 2.3 이미 있는 것과 빠진 것

- 있다: 후보 전체를 한 번에 판정하는 타입 있는 선택기(`lib/keeper/keeper_workspace_memory_selection.ml:99` `assess_batch`, 용량 거절 시 절반으로 나눠 재시도, 입력과 응답을 호출 전후에 기록). 선택 역할이 닫힌 합타입이다(`current_decision`, `comparison`, `inspect_source`, `not_needed`).
- 없다: 개인 기억에 이 선택기를 호스트가 부르는 길. 검색 RFC 단계 2 가 약속한 "로컬 판정 lane". recall 가치를 재는 정답 세트.
- 스위치 없이 있다: 기본 `keeper_memory_search` 안의 후속 기억 판정이 기억 원문을 TypeSafe 로 보낸다(`lib/keeper/keeper_memory_successor_selection.ml:79`). 다른 기능은 기능마다 스위치가 있는데 이 경로는 레인 스위치만 본다. 검색 RFC 는 "본문 외부 반출 금지"로 정했지만 운영자가 Jev 판단을 적극 쓰기로 했으므로(D2), 빠진 것은 반출이 아니라 기능별 스위치다. 이 RFC 는 그 경로를 바꾸지 않고 §5 의 정리 층으로 넘긴다.

## 3. 지금 구조

- 첫 라운드 조립: `lib/keeper/keeper_run_tools_hooks.ml` 의 `Keeper_memory_os_recall.render_if_enabled`(1109)와 `record_block Memory_os_recall`(1121). 후속 라운드에는 다시 넣지 않는다(`injected_on_post_tool_round`, `prompt_block_id.ml:93`).
- 공용 기억의 호스트 recall 은 턴마다 한 번 준비해 재시도 때 같은 선택을 쓴다(`host_memory` 참조, `keeper_run_tools_hooks.ml:645`). 용량 거절이 나면 고른 항목 수를 줄인다(`Keeper_workspace_memory_host_recall.defer_for_capacity`). Muse·Antigravity 는 이 재시도 경로가 없다(`config/runtime.toml` 의 `workspace_memory_selection_enabled` 주석).
- 블록 정체성은 닫힌 합타입이다(`prompt_block_id.ml`). 새 블록을 더하면 컴파일러가 빠진 자리를 알려 준다.
- 판정 레인은 `Standalone_lane` 과 `Lane_run_identity` 의 닫힌 변형이고 설정은 `[runtime.exact_output_lanes.<이름>]` 이다. 판정 레인은 `Priority`, Librarian 은 `Background` 로 허가 대기열을 쓴다(`lib/runtime/standalone_lane.mli`).

## 4. 설계

### 4.1 흐름

```text
턴 입력 + 월드 프레임 ──┐
키퍼의 현재 사실 전체 ──┴─> memory_recall_exact 판정 (배치 1회)
                              │  후보마다 닫힌 선택 + 이유
                              v
                    Selected / Not_needed / Deferred(이유)
                              v
            Recalled_memory 블록 (첫 라운드, 매 턴 전달)
```

### 4.2 후보와 입력

- 후보는 키퍼의 현재 일반 사실과 검증된 출처 결속 사실 전체다. 미리 걸러 내지 않는다. 낱말 겹침이나 점수로 줄이는 것은 헌법의 `string_matching`·`magic_number` 에 걸린다.
- 후보 한 줄: id, category, claim, first_seen, last_seen, origin. 내용 단서가 claim 문장뿐이라 입력이 크다. 키퍼 40개의 claim 바이트는 중앙값 약 65KB, 상위 10% 약 149KB, 최대 약 181KB 다. 층 2 의 제목이 이 크기를 줄인다(§5.2).
- 목적(purpose)은 공용 기억의 호스트 recall 과 같은 모양이다: 이번 턴 입력, 이번 요청의 문맥(월드 프레임), 키퍼 지침, 턴 참조. 자율 턴에서는 입력 자리에 자율 턴 프롬프트가 들어가고 문맥에 목표와 과업이 있다.
- 안정 부분(지침, 후보)을 앞에, 턴마다 바뀌는 목적을 뒤에 둔다. 제공자의 프롬프트 캐시를 쓰기 위해서다.

### 4.3 판정

- 선택 역할은 기존 선택기의 닫힌 선택을 그대로 쓴다. 이번 결정에 직접 쓰이는 기억(`current_decision`), 다른 사건·환경이지만 비교에 쓰이는 기억(`comparison`), 출처를 더 봐야 하는 기억(`inspect_source`), 필요 없음(`not_needed`)이다.
- **1단계, Jev.** 후보마다 질문 하나를 한 요청에 담아 보낸다(`assess_batch` 와 같고, 용량 거절이면 절반으로 나눠 다시 보낸다). 빠르고 싸다(평균 0.66초, 호출당 약 $0.00006, [TypeSafe Jev 연구](../research/2026-09-18-typesafe-jev-masc-applicability-r1.md) §4). 이유 문장은 못 낸다.
- **2단계, in-house 레인.** Jev 가 `not_needed` 가 아닌 것으로 답한 후보만 받는다. 후보마다 닫힌 선택과 이유 문장 하나를 낸다. 출처 결속 사실의 파일 검증은 이 단계에서 고른 것에만 붙인다. 모든 사실을 매 턴 재검증하지 않는다. 1단계가 넓게 고르고 2단계가 줄이므로 2단계가 후보를 더하는 일은 없다. 이유는 감사 기록이 된다.
- **Jev 를 못 쓸 때.** 그 Keeper 가 `[typesafeai] excluded_keepers` 에 있거나, `[typesafeai] memory_recall` 스위치가 꺼져 있거나, Jev 요청이 실패하면 레인이 후보 전체를 1단계로 받는다. 레인도 못 쓰면 `unavailable`(§4.4)이다.
- **Jev 로 가는 것.** 이번 턴 입력, 이번 요청의 문맥(월드 프레임), Keeper 지침, 후보의 id·category·claim·시각. 회사 데이터를 다루는 Keeper 를 제외할지는 운영자가 정한다(§8).
- **확신도는 기록하고, 단계를 가르는 데 쓰지 않는다.** Jev 응답의 확률과 확신도는 평가 기록에 남긴다. 응답 해석(`decode_choice`)도 확신도를 수락 임계값으로 쓰지 않는다고 적는다(`lib/typesafeai/typesafeai_types.mli`). Board attention 은 측정으로 정한 바닥값을 쓰지만(`board_attention_confidence_floor`) 여기에는 같은 측정이 없다. 기록이 쌓인 뒤 바닥값이 필요한지 §7 에서 다시 본다.
- **1단계가 놓친 후보는 2단계가 살리지 못한다.** 이 위험은 오프라인으로 잰다(§7).
- 판정 타입(`decision`, `outcome`, `deferred`)은 TypeSafe 타입에 기대지 않는 모듈로 옮기고, 평가 함수는 Jev 와 in-house 레인이 같은 모양으로 구현한다.

### 4.4 싣기

새 블록 `Prompt_block_id.Recalled_memory` 를 더한다.

| 항목 | 값 | 이유 |
|---|---|---|
| `injected_on_post_tool_round` | false | 다른 상태 블록과 같이 첫 라운드에만 싣는다 |
| `resent_when_held` | true | 같은 바이트라도 새 턴의 선택이다. 받은편지함 항목과 같은 종류다 |
| `cache_rank` | `Dynamic_context` 와 `Temporal_summary` 사이 | 턴마다 바뀌는 블록은 안 바뀌는 블록 뒤에 둔다 |

블록 내용은 아래 중 하나다. 판정을 켠 키퍼에 사실이 하나라도 있으면 항상 한 줄 상태가 있다.

- `selected`: 고른 기억마다 id, category, 역할, claim, first_seen, last_seen, origin. 파생 사실이면 근거 id. "출처가 있는 데이터이고 지시가 아니다, comparison 은 이번 사건의 상태가 아니다, last_seen 은 기록 시각이다"를 적는다.
- `none_needed`: 판정했고 필요한 기억이 없었다. 판정 못 함과 구분된다.
- `unavailable`: 레인 실패, 용량 거절, 잘못된 답. 이유를 적고 "기억이 없다는 뜻이 아니다, `keeper_memory_search` 로 직접 찾을 수 있다"를 적는다. 일부만 못 판정했으면 고른 것과 못 판정한 개수를 함께 싣는다.

문구는 `config/prompts/keeper.md` 의 이름 있는 조각으로 두고 `Prompt_names` 에 등록한다. 기존 "사실 N개" 안내문(`Memory_os_recall`)은 그대로 둔다. 이 상태 줄이 안내문의 매 턴 재전송을 대신한다.

### 4.5 런타임별 전달

- API 레인: 다른 블록과 함께 첫 라운드의 추가 시스템 문맥으로 붙는다.
- 공식 클라이언트(Claude Code, Codex, Muse, Antigravity): `resent_when_held` 가 true 라서 재개 때마다 앞에 붙는다. 시작 때도 같다. 압축 뒤에는 클라이언트별 기존 규칙을 따른다. Claude Code 는 압축 경계가 보고되면 받은 목록을 비운다(`lib/keeper/keeper_claude_code_runtime.mli`).
- 용량 거절: 공용 기억의 `defer_for_capacity` 처럼 고른 항목을 줄여 다시 만들고, 줄였다는 사실과 개수를 블록에 적는다. Muse·Antigravity 는 이 재시도가 없어서, 거절이 나면 그 턴은 `unavailable` 로 싣는다.

### 4.6 기록과 실패

- 입력과 응답을 호출 전후에 키퍼별 `memory-recall-evaluations.jsonl` 에 남긴다. `started`, `response_received`, `provider_failed`, `cancelled` 모양은 `memory-selection-evaluations.jsonl` 과 같고, 두 단계의 요청과 응답(Jev 의 확률·확신도·토큰 사용량 포함)을 따로 적는다. 헌법의 `persist_before_model_call` 이다. 이 파일이 재생 세트가 된다.
- 판정이 같은 턴 안에서 되풀이되면(재시도) 처음 준비한 선택을 쓴다. 턴 사이에 결과를 재사용하지 않는다. 같은 입력이 반복돼도 사실이 바뀌었을 수 있기 때문이다.
- 타임아웃을 새로 만들지 않는다. 레인의 기존 실패 처리와 역압이 `unavailable` 의 이유가 된다.
- 지표: `masc_keeper_memory_recall_total{outcome}`(selected, none_needed, unavailable), 판정 입력 바이트, 고른 개수, 호출 지연. 기존 `Keeper_metrics` 방식이다.

### 4.7 스위치와 레인

- `config/runtime.toml` 에 `[memory_recall]` 을 더한다. `enabled = false` 가 기본이다. `keepers = []` 가 비어 있으면 켜졌을 때 모든 키퍼이고, 이름을 적으면 그 키퍼만이다. 설정 레지스트리에 행을 더한다(위키 목차의 `wiki_contents` 와 같은 방식).
- `[typesafeai]` 에 `memory_recall = false` 를 더한다. 데이터를 TypeSafe 로 보내는 기능마다 스위치를 따로 두는 기존 방식이다(`absorb_gate`, `skill_applicability`, `workspace_memory_selection_enabled`). 꺼져 있으면 1단계도 레인이 맡아서 아무것도 TypeSafe 로 가지 않는다. 그래서 카나리는 레인만으로 먼저 켜고, Jev 는 따로 켤 수 있다.
- `[runtime.exact_output_lanes.memory_recall_exact]` 에 `slots`·`cli_slots` 를 둔다. 레인은 `Optional` 이라 슬롯이 없어도 서버는 뜨고 블록이 `unavailable` 이 된다. 허가 대기열은 `Priority` 다.
- 레인이 쓰는 슬롯은 키퍼들이 이미 쓰는 제공자의 슬롯이다. 2단계에는 Jev 가 고른 후보만 간다.
- 라이브 설정은 이 RFC 의 PR 이 바꾸지 않는다. 카나리를 켤 때 운영자가 정한다.

## 5. 다음 단계 (이 RFC 에서 구현하지 않는다)

### 5.1 층 1 이후 순서

- 층 1a: 블록, 설정 스위치, 닫힌 판정 타입, 레인 변형. 기본 꺼짐이라 동작이 안 바뀐다.
- 층 1b: 판정 흐름, 기록, 지표, 블록 렌더. 단위 테스트(요청과 결정).
- 층 1c: 카나리 Keeper 에서 켜고 §7 을 잰다.

### 5.2 층 2 — 이름, 제목, 연결

측정 뒤에 정한다. 방향만 적는다.

- **안정 id.** 처음 넣을 때 정한 `fact_id` 가 다시 써도 유지된다. 지금의 `memory_id`(claim 해시)는 내용 확인용으로 남긴다. 이력과 연결을 걸 끈이 먼저 있어야 한다.
- **제목과 "언제 꺼낼지".** Librarian 과 `keeper_memory_write` 가 쓸 때 같이 쓴다. 지금 `title` 은 도구 인자로 받아 claim 앞에 `**title**` 로 접힌다(`lib/keeper/keeper_tool_memory_validation.ml:466`). 판정 후보를 짧게 만들고 색인 줄이 된다. 한 줄은 "무엇이 들었고 언제 필요한지"다(Codex v2 요약, 예전 Claude Code `description`).
- **타입 있는 연결.** 근거(`Derived`), 교체(`Supersedes`), 흡수(`Absorbs`), 관련(`Related`, 이유 포함)을 닫힌 합타입으로 둔다. 점수는 두지 않는다. 연결 후보는 임베딩 검색이 아니라 새 사실마다 키퍼의 기존 사실 전체를 판정에 올려 정한다(A-MEM 이 링크 판단을 LLM 에 맡기는 것과 같다). Jev 가 후보를 가려내고 `Related` 의 이유는 레인이 쓴다. 지금 Derived 는 2,434개 중 1개이고 흡수 계보의 88.6%가 끊겼다(감사 측정).
- **트리.** category(사용자 정의 포함) 아래 사실. 깊이는 3단 이내. 넘치면 설명만 접고 항목은 지운다. 조용히 자르지 않는다(Hermes 방식, Codex #48679 와 반대).
- **고구마줄기.** 판정이 고른 사실의 이웃을 후보로 다시 판정에 올리고, 모델도 `id` 로 이웃을 열 수 있게 한다. 링크를 따라가는 쪽이 링크 없는 전체 목록보다 낫다는 비교 연구가 없다. §7 의 대조군으로 직접 잰다.
- 저장 계약이 바뀐다. 백업을 확인한 뒤 hard cut 한다. 운영자 승인이 필요하다(§8).

### 5.3 층 3 — 정리

- `RFC-memory-os-recall-selection`(61KB, 구현 0, 전제 소멸)과 `RFC-0247` §2(연상·수면 통합·TTL, 코드 없음)를 지운다. 죽은 개념은 지운다.
- 기본 검색 안의 TypeSafe 후속 판정에 스위치를 달고 기본값을 정한다.
- 검색 RFC 단계 2 를 이 RFC 로 대체한 것으로 닫는다.

## 6. 대안과 버린 이유

| 대안 | 버린 이유 |
|---|---|
| 목록만 보이게(Skill 식) | 목록이 매 턴 보이는 Skill 도구가 0.60% 만 불린다. "찾아볼까"를 모델에게 맡기는 점이 같다 |
| 안내문만 매 턴 재전송 | 효과가 Muse 에서만 뚜렷했다. 안내문 재전송은 `Memory_os_recall` 의 "이미 받았으면 건너뜀" 규칙을 바꾸는데, 이 블록의 이름을 쓰는 테스트 파일이 13개이고 Codex·Claude Code·Muse·Antigravity 런타임과 세션 저장소의 재전송 테스트가 그 안에 있다. `Recalled_memory` 의 상태 줄이 같은 역할을 한다 |
| 사실 전체를 항상 싣기 | 10-01 이전 설계다. 키퍼당 claim 이 최대 약 181KB 라 관련 없는 기억이 주의를 흩고 도구 인자를 흔들 수 있다(Memory-Induced Tool-Drift). 단 작은 저장소에서는 전체 노출이 기준선이라는 논문 표가 여럿 있어서 §7 에서 대조군으로 같이 잰다 |
| 점수·키워드·상위 N개로 고르기 | 헌법의 `magic_number`·`string_matching`. OpenClaw 의 회상 패턴은 독일어에서 안 켜졌다(#151766) |
| Jev 를 유일한 판정자로 | 빠르고 싸지만(평균 0.66초) 이유를 못 내고, early-access 단독 벤더라 SLA 가 없고 한 모델이며 능력이 고르지 않다([TypeSafe Jev 연구](../research/2026-09-18-typesafe-jev-masc-applicability-r1.md) §3.2, §5). 그래서 Jev 를 1단계로 쓰고 이유와 확정, 그리고 Jev 를 못 쓸 때의 대체는 레인이 맡는다 |
| 확신도 바닥값으로 두 단계를 가르기(Board attention 방식) | Board attention 은 측정으로 바닥값(0.3)을 정했다. 여기에는 그 측정이 없고 헌법의 `magic_number` 에 걸린다. 기록을 쌓은 뒤 다시 본다 |
| in-house 레인만 | 후보 목록이 키퍼당 최대 약 181KB 라 매 턴 레인에 통째로 보내면 지연과 구독 용량 부담이 크다. Jev 로 먼저 좁히면 레인은 고른 후보만 본다. 레인만으로 켜는 구성은 카나리의 첫 단계로 남긴다 |
| Librarian 레인 재사용 | `Background` 대기열이라 턴 지연을 부른다. 정체성도 다르다 |

## 7. 검증

단위 테스트는 보낸 요청과 결정만 본다. 문구는 보지 않는다.

- 스위치가 꺼져 있으면 판정 호출도 블록도 없다. 사실이 없으면 호출이 없다.
- 후보는 키퍼의 현재 사실 전체이고, 판정 요청에 그 id 가 모두 있다.
- 선택된 항목만 블록에 실리고, 역할이 요청한 선택과 같다.
- 레인 실패·용량 거절·잘못된 답이 `unavailable` 의 서로 다른 이유가 된다. 빈 블록이 되지 않는다.
- 공식 클라이언트 재개에서 같은 바이트의 `Recalled_memory` 가 다시 실린다. 같은 조건에서 `Skill_compositions` 는 계속 건너뛴다.
- 후속 라운드에는 실리지 않는다.
- 입력과 응답이 호출 전후에 기록된다.
- 제외 목록의 Keeper 와 `[typesafeai] memory_recall` 이 꺼진 설정에서는 Jev 요청이 없고 레인이 후보 전체를 받는다.
- Jev 요청이 실패하면 레인이 1단계를 맡는다. 둘 다 실패하면 이유가 다른 `unavailable` 이다.
- 2단계 요청에는 Jev 가 `not_needed` 로 답한 후보가 없고, 2단계 답마다 이유가 있다.

배포 전후를 잰다. 질문 묶음과 정답은 PO(masc-productor-owner)가 고정하고 채점한다. 방식은 위키 목차 RFC §7 을 따른다.

- 질문 묶음: 카나리 Keeper 한 명의 현재 사실에서 나이와 category 가 고르게 되도록 사실을 골라, 그 사실이 있어야 답할 수 있는 질문을 만든다(정답이 구성상 보장된다). 같은 수의 대조군 질문은 기억이 필요 없다. 문항당 정답 2점, 부분 1점, 오답 0점이고 "모른다"는 따로 표시한다.
- 팔 넷: (A) 기억 안내 없음, (B) 지금(안내문만), (C) 이 RFC(호스트 판정), (D) 사실 전체 노출. 같은 Keeper 에 같은 문장, 세 번씩 반복한다. 런타임이 다른 카나리 셋(공식 클라이언트 둘, API 하나 이상)에서 한다.
- 가설: (1) C 가 B 보다 "기억이 필요한 질문"의 점수가 오른다. (2) 대조군 점수와 도구 호출 정확도는 떨어지지 않는다. (3) 판정이 대조군 질문에서 `none_needed` 로 답한다. (4) D 와 C 의 차이를 본다. D 가 C 이상이면 작은 저장소는 전체 노출이 낫다는 뜻이고 이 RFC 의 크기 기준을 다시 정한다.
- 합격선 숫자는 미리 정하지 않는다. 팔 A~D 를 잰 뒤 운영자가 값을 보고 정한다.
- 채점 보조: 정답지와 답을 Jev(점수 질문)와 in-house LLM 두 판정자가 따로 매기고, 둘이 갈린 문항과 무작위 표본을 PO 가 본다. 최종 점수는 PO 가 정한다. LLM 판정자의 순위가 F1 순위와 갈린다는 보고가 있어서(Anatomy of Agentic Memory, arXiv 2602.19320 표3, 조사 에이전트가 본문에서 확인) 판정자만으로 점수를 확정하지 않는다.
- Jev 가 놓치는 정도: 평가 기록의 후보 전체를 레인이 1단계로 다시 판정해, Jev 가 `not_needed` 로 보냈는데 레인이 고르는 후보를 센다. 숫자 합격선은 두지 않고 목록을 PO 가 읽는다. 놓침이 보이면 Jev 의 질문 문구를 고치거나 1단계를 레인으로 돌린다.
- 확신도 기록으로 바닥값이 필요한지 본다. Jev 의 확신도 분포와 Jev·레인의 불일치가 겹치는 구간이 있는지 확인하고, 겹칠 때만 Board attention 처럼 측정으로 정한 값을 RFC 로 따로 제안한다.
- 보조 지표: `scripts/keeper-recall-baseline.py` 를 같은 조건으로 다시 돌려 검색 비율, 0건 비율, 도구 호출 비중을 비교한다. 판정 호출 수, 입력 바이트, 지연, 레인 거절 수, `none_needed`·`unavailable` 비율. 같은 claim 을 다시 쓰는 비율(`explicit_write`)은 recall 실패의 간접 신호다.
- 한계: 키퍼와 문항이 적고 회차당 한 번이다. 통계가 아니라 사례다. 전후 차이에는 그사이 다른 변화가 섞인다.

## 8. 운영자 결정

- 결정됨 (2026-10-28): 판정은 LLM 판단과 Jev 판단을 적극 쓴다(D2). 처음 제안한 "in-house 레인만"을 이 결정으로 바꿨다.
- 열려 있음 1 — Jev 로 가는 범위. 이번 턴 입력, 월드 프레임, Keeper 지침, 후보 전체가 간다. 회사 데이터를 다루는 Keeper(`kidsnote-incoming-dd-manager`, `kidsnote-job-manager`, `kidsnote-qa-hub-manager`, `kidsnote-slack-reader`)를 `[typesafeai] excluded_keepers` 에 둘지. 지금 제외 목록에는 `kidsnote-slack-context-collector` 하나만 있다. 제안은 이 넷도 두는 것이다. 그러면 이 Keeper 들은 레인만으로 판정한다.
- 열려 있음 2 — 층 2 의 hard cut. 안정 id·제목·연결은 저장 계약을 바꿔서 백업 후 기억을 다시 쓴다.
- 열려 있음 3 — 기본 검색 안의 TypeSafe 후속 판정(§2.3). 기능별 스위치를 달고 기본값을 정한다.
- 열려 있음 4 — MASC Goal·Task. 만들면 모든 Keeper 프롬프트의 `active_goals` 에 들어간다. 만들기 전에 묻는다.

## 9. 구현 순서

1. 이 RFC 와 아래층의 기준선(연구, 증거, 스크립트).
2. 층 1a, 1b, 1c(§5.1). 한 층에 PR 하나, 층마다 20k 토큰 이하.
3. 층 1c 의 결과를 이 RFC 에 덧붙인다. 그 값을 보고 층 2 를 정한다.

## 10. 확신도

- 문제(§2.1, §2.2의 1~4): 높음. 라이브 로그와 코드를 직접 읽고 셌다.
- "전달 횟수가 한 원인이다"(§2.2의 3): 중간. 같은 모델 안의 비교는 Muse 에서만 뚜렷하고 Claude Code 는 0/39 다.
- "호스트 판정이 recall 을 올린다": 중간 이하. 벤더 블로그 2건과 단독 저자 프리프린트 1건이 근거이고 우리 키퍼에서는 아직 안 쟀다. §7 이 그 측정이다.
- "Jev 1단계가 필요한 후보를 놓치지 않는다": 모름. Board attention 에서 기존 judge 와 맞았다는 연구는 있지만(17/17, 대조군 10/10) 후보가 사실 수십~백여 개이고 질문 모양이 다르다. 오프라인 재생(§7)으로 잰다.
- "연결을 따라가는 탐색이 낫다": 낮음. 제품과 논문 어디에도 비교가 없다.
- 판정 지연과 레인 부하: 모름. 입력이 최대 약 181KB 라 측정 전에는 말할 수 없다.
