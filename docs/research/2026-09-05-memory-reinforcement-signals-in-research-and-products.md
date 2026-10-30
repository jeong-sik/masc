# 기억은 무엇으로 굳는가: 연구와 기성 제품이 쓰는 강화 신호, 그리고 masc 에 없는 것

- 확인 시각: 2026-09-05 (KST)
- 확신: Medium. 제품 문서와 2025–2026 논문의 초록·공식 블로그를 읽었고, 논문 본문의 수치는 인용한 곳에서만 조건과 함께 적었다. 본문을 끝까지 읽지 않은 논문은 그렇게 표시했다.
- 앞선 문서: `docs/research/2026-06-23-what-to-forget-keeper-memory-forgetting-policy.md` (잊기 정책), `docs/research/2026-08-13-counterpart-relationship-memory.md` (작은 store 의 설계 검토). 이 문서는 그 둘이 다루지 않은 한 질문만 본다.

## 0. 질문

RFC-0418 은 `reinforcement` 카운터를 걷어내고 회수·인용·개정 **사건**을 기록하자고 한다. 그 전에 묻는다. 현대 연구와 기성 제품은 "이 기억이 강화됐다" 를 무엇으로 판단하는가, 그 신호를 어디서 얻는가, 그리고 masc 에는 그중 무엇이 없는가.

## 1. 인지과학이 말하는 자리 (요약, RFC-0418 §2 와 같음)

꺼내 쓸 때 굳고(retrieval practice), 간격을 두고 굳고(spacing), 꺼낼 때 바뀌며(reconsolidation), 예상된 반복은 신호가 없다(prediction error). 재노출은 강화가 아니다. 6월 문서 §5 의 "re-injection ≠ re-observation (ACT-R 함정)" 이 같은 말이다.

## 2. 제품과 연구 시스템이 실제로 쓰는 신호

| 시스템 | "강화/유지" 를 정하는 신호 | 어디서 얻나 | 사용 사건을 기록하나 |
|---|---|---|---|
| **MemoryBank** (Zhong 외 2023) | Ebbinghaus 곡선. 회수될 때 strength 증가, 안 쓰면 감쇠 | 회수 시점 | 예 (회수 = 강화) |
| **Generative Agents** (Park 외 2023) | recency × importance × relevance 점수. importance 는 LLM 이 매김 | 쓰기 시점(importance) + 읽기 시점(recency) | 부분 (last_accessed 갱신) |
| **Mem0** | 새 사실마다 LLM 이 ADD / UPDATE / DELETE / **NOOP** 결정. 반복이면 NOOP | 쓰기 시점, 유사 후보를 벡터로 뽑아 LLM 에게 | 아니오. 반복은 기록 없이 버려진다 |
| **Zep / Graphiti** | 사실(edge)에 `valid_at`/`invalid_at` 두 시간축. 새 사실이 옛 것을 **무효화**하고 옛 edge 는 남긴다. **Fact Ratings**: 운영자가 준 지시문으로 LLM 이 사실마다 0–1 점을 매기고, 회수 때 최소 점수로 거른다 | 쓰기 시점 | 아니오 |
| **Letta / MemGPT** | 점수 없음. core memory block 은 agent 가 직접 고치고, recall/archival 은 도구로 검색. sleep-time agent 가 유휴 시간에 정리 | agent 의 편집, 백그라운드 정리 | 아니오 (검색 로그는 있으나 사실 단위 강화 개념 없음) |
| **A-MEM** (Xu 외 2025) | 새 노트가 들어올 때 LLM 이 기존 노트와 연결하고 기존 노트의 문맥 설명을 **진화**시킨다 | 쓰기 시점 | 아니오 |
| **LangMem** | semantic / episodic / procedural 세 종류. 핫패스 도구 + 백그라운드 관리자. 강도 개념 없음 | — | 아니오 |
| **TiMem** (2026-01, 초록만) | 시간·계층 통합(consolidation). 세부 접힘 | 통합 pass | 확인 안 됨 |
| **Control-plane placement 연구** (2026-06, 초록·요약) | LLM 을 저장 시점에 두느냐 **변경(삭제·대체) 시점**에 두느냐로 13 구성 비교. 변경 시점 hook 이 의도 인식 삭제를 78–85% 회복, 전체 91.7–93.2%. 결정론 규칙만은 정규화 실패(식별자 난독 5%, 교차언어 0%) | — | "생산 장애는 회수 실패가 아니라 **잊기 실패**" |
| **Memory 서베이** (2026-03, 초록) | write–manage–read 루프. "continual consolidation" 과 "learned forgetting" 을 미해결로 명시 | — | — |

읽는 법:

1. **사용(회수)을 사실 단위로 기록하는 시스템은 거의 없다.** MemoryBank 만 회수를 강화로 세고, 나머지는 쓰기 시점의 LLM 판단(Mem0 UPDATE, Zep rating, GA importance, A-MEM evolve)이거나 강도 개념이 없다(Letta, LangMem). 쓰기 시점 판단은 "이 문장이 중요한가" 를 묻는 것이고, "실제로 쓰였나" 는 다른 질문이다.
2. **"같은 뜻, 다른 문장" 은 쓰기 시점의 LLM 통합이 처리한다.** Mem0 의 UPDATE, A-MEM 의 evolve, Graphiti 의 invalidate 가 그 자리다. masc 의 librarian 이 정확히 이 자리에 있고, 6월 연구의 결론(변경 시점 LLM hook)과 2026-06 논문의 결과가 맞는다. 빠진 것은 "새 사실이 옛 사실을 잇는다" 는 **연결**이다. Graphiti 는 옛 edge 를 남기며 무효화 사유와 시각을 든다. masc 는 `dropped.reason` 은 있지만 새 claim 이 어느 옛 claim 을 대체했는지가 없다.
3. **점수는 두 번 실패했다.** Generative Agents 식 importance 는 RFC-0247 이 걷어냈고(6월 문서 §4), Zep 의 Fact Ratings 는 운영자 지시문으로 LLM 점수를 매기는 방식이라 같은 계열이다. 이 저장소가 다시 갈 길이 아니다.
4. **감쇠는 신호가 있어야 계산할 수 있다.** MemoryBank 식 곡선도 회수 시각이 있어야 그린다. 6월 문서 §7 이 L3 백스톱을 "recency-of-use 인식" 으로 두라고 했는데, masc 에는 **use 를 기록하는 곳이 없다**. 사건 기록이 그 전제 조건이다. 감쇠 상수는 여전히 넣지 않는다(6월 문서 §6: "이론에서 도출되지 않는다").

## 3. masc 에 있는 것, 없는 것

| | masc 지금 | 비교 대상 | 판단 |
|---|---|---|---|
| 회수 사건 기록 | 없음. `keeper_memory_search` 는 decision-log 에 query 와 match_count 만 남긴다(`keeper_tool_memory_runtime.ml:377-388`) | MemoryBank | **빠짐. 단순.** 결과 `fact_match` 가 이미 `memory_id` 를 든다(`:52-60`) |
| 인용 사건 | 없음 | — | 빠짐. 단순. `memory_id` 를 받는 도구는 `keeper_memory_retract` 하나 |
| 개정 연결(supersedes) | 없음. `dropped.reason` 만 | Graphiti 의 invalidation + 옛 edge 보존, Mem0 UPDATE | **빠짐. 단순.** librarian 답에 선택 필드 하나 |
| 쓰기 시점 LLM 통합 | 있음. librarian retain/drop/new (변경 시점 hook) | Mem0, A-MEM, Graphiti | 있음. 2026-06 논문이 가장 좋다고 본 배치 |
| 두 시간축 | 부분. `first_seen`/`last_seen` 은 관측 시각. "언제까지 참이었나" 는 dropped 시각으로 간접 | Graphiti bi-temporal | 사건 기록으로 `Revised` 시각이 생기면 실질적으로 채워진다 |
| 강도 점수 | 없음(의도). `reinforcement` 는 dedup 카운트 | GA importance, Zep rating | 넣지 않는다. 기록을 보여 준다 |
| 회수 순위 | 없음. 매 턴 현재 스냅샷 전체를 주입(`keeper_memory_os_recall.ml:36-45`) | Letta core block 과 같은 방식 | 그대로. 사건은 순위에 쓰지 않는다 |
| 백그라운드 정리 | 있음. librarian pass | Letta sleep-time agent | 있음 |
| 기억 품질 평가 | `eval_memory_os_value.ml`, `memory_os_judge_eval.py` 가 있다 | 서베이가 말하는 multi-session 평가 | 사건 기록이 들어오면 "회수된 사실이 답에 쓰였나" 를 평가에 더할 수 있다 |

## 4. 결론

- RFC-0418 의 방향(사건 기록, 카운터·라벨 제거, 투영)은 연구와 제품 어느 쪽과도 어긋나지 않고, 대부분의 제품이 비워 둔 자리(사용 기록)를 채운다.
- 단순한 개선 셋이 전부 사건 기록 하나에 걸려 있다: (a) 검색 결과의 `memory_id` 를 사건으로 남기기, (b) librarian `supersedes`, (c) 죽은 `reinforcement` 와 라벨 제거. 셋 다 새 점수·상수·임계값이 없다.
- 하지 않을 것: importance/rating 점수, 감쇠 상수, 임베딩 유사도 재관측, 회수 순위. 6월 문서와 RFC-0247 이 이미 닫은 문이다.

## 5. 출처

- Roediger & Karpicke (2006) *Test-Enhanced Learning*; Cepeda 외 (2006) spacing 메타분석; Nader, Schafe & LeDoux (2000) reconsolidation; Rescorla & Wagner (1972); Schultz 외 (1997). 고전 문헌, 수치 인용 없음.
- MemoryBank: Zhong 외 (2023) arXiv:2305.10250. Generative Agents: Park 외 (2023) arXiv:2304.03442.
- Mem0: <https://docs.mem0.ai/core-concepts/memory-operations/update>, <https://www.emergentmind.com/papers/2504.19413>
- Zep / Graphiti: <https://arxiv.org/abs/2501.13956>, <https://blog.getzep.com/announcing-zep-fact-ratings/>, <https://help.getzep.com/v2/facts>
- Letta: <https://www.letta.com/blog/memory-blocks/>, <https://www.letta.com/blog/agent-memory/>, Sleep-time compute <https://arxiv.org/abs/2504.13171>
- A-MEM: <https://arxiv.org/abs/2502.12110>
- LangMem: <https://www.langchain.com/blog/langmem-sdk-launch>, <https://docs.langchain.com/oss/python/concepts/memory>
- TiMem: <https://arxiv.org/abs/2601.02845> (초록)
- Control-Plane Placement Shapes Forgetting: <https://arxiv.org/abs/2606.15903> (초록·요약)
- Memory for Autonomous LLM Agents 서베이: <https://arxiv.org/abs/2603.07670> (초록)
- Always-On Agents 서베이: <https://arxiv.org/abs/2606.30306> (목록만 확인)
