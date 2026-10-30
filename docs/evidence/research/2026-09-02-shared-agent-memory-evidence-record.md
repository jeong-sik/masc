# Shared agent memory evidence record

`2026-09-02-shared-agent-memory-research-r1.md` 의 근거. 확인 시각은 전부 2026-09-02 KST.

## 실측 (masc 라이브)

| Evidence | Timestamp | Confidence | Delta |
|---|---|---|---|
| `<base-path>/.masc/config/keepers/*.memory-current.json` 12개를 파싱해 사실 711건, 분류·출처·강화·교차 중복을 셈. 스크립트: python, 정규식은 보수적 | 19:20 | High (개수) / Medium (조정 문구·도구 lesson 분류는 정규식) | RFC-0247 의 06-16 실측 6,462건 대비 9분의 1. `_shared` 0 |
| `board_posts.jsonl`, `board_comments.jsonl` 7일 집계 | 19:22 | High | Board 가 keeper 간 채널로 실제 쓰인다(1,363/1,763) |
| `keeper_memory_os_recall.mli` 헤더, `keeper_memory_os_types.mli:142-210`, `keeper_memory_os_aggregate_lock.mli` | 19:05 | High | recall 은 전부-아니면-없음. aggregate lock 은 keeper_id 단위 |
| RFC-0251 §3, RFC-0247 §2.2·evidence 절, RFC-0365 §8, RFC-tui-operator-ia §3.1·§3.4 | 19:00 | High | RFC-0244 문서는 부재. 인용만 남음 |

## 논문 (직접 확인: arXiv abs/html 페이지)

| Evidence | Timestamp | Confidence | Delta |
|---|---|---|---|
| https://arxiv.org/abs/2606.24535 Governed Shared Memory (MemClaw) | 19:35 | High (abstract) | 실패 4종·primitive 4종 이름은 abstract 원문. Table 2 수치는 에이전트가 본문에서 읽음(Medium) |
| https://arxiv.org/html/2604.03295 LLMA-Mem | 19:40 | High (§4.5.1 인용) | Table 3 수치는 에이전트 확인(Medium) |
| https://arxiv.org/abs/2602.05965 Learning to Share | 19:37 | High | ICML 2026 표기는 검색 결과 기준(Medium) |
| https://arxiv.org/abs/2609.00237 Gated-Memory Routing | 19:35 | High | 31.9% 는 abstract |
| https://arxiv.org/abs/2608.00426 MAPLE-Guard | 19:35 | High | 38.2%→0.9% 는 abstract |
| https://arxiv.org/abs/2608.21867 MemGuard | 19:35 | High | |
| https://arxiv.org/abs/2609.00243 Invalidation Contracts | 19:35 | High | |
| https://arxiv.org/abs/2608.22215 Dual-Layer Agentic Memory | 19:42 | High | 68% / 98% 는 abstract |
| https://arxiv.org/abs/2608.28978 Selective Forgetting | 19:42 | High | F1 수치는 abstract |
| https://arxiv.org/abs/2608.22752 Compaction Cliff | 19:42 | High | 53% / 10% 는 abstract |
| https://arxiv.org/abs/2608.30177 Stage-Wise Utility-Risk | 19:42 | High | |
| https://arxiv.org/abs/2512.13564 Memory in the Age of AI Agents | 19:40 | High (abstract) / Medium (§7.5 내용은 에이전트) | |
| arXiv export API 질의 3건 (multi-agent+memory+shared / memory OS / survey), 2026-09-01 까지 | 19:33 | High | 목록만 |

## 논문 (에이전트 조사, 원문 확인 표기된 것만 채택)

arXiv 2605.04264 (Cuadros) · 2602.06052 (Huang) · 2604.16548 (Lin) · 2603.10062 (Yu) · 2506.07398 (G-Memory) · 2606.19911 (MATM) · 2505.18279 (Collaborative Memory) · 2607.03228 (Kirchdorfer) · 2607.09493 (Pedada) · 2604.01350 (No Attacker Needed) · 2605.16746 (State Contamination) · 2606.18829 (GateMem) · 2605.14498 (GroupMemBench) · 2606.20695 (Coordination Gain) · 2308.10144 (ExpeL) · 2606.01138 (memorywire) · 2606.30306 (Always-On Agents). 에이전트가 "확인 필요" 로 표기한 항목(일부 첫 저자, LoCoMo/LongMemEval id, 망각 논문 4편의 저자·수치)은 문서에 넣지 않았다. Confidence: 분류·기제 서술 High, 표·절 번호가 붙은 수치 High, 나머지 Medium.

## 제품 (에이전트 조사, 공식 문서 fetch)

Letta S1–S7 · Mem0 S8–S15 · Zep/Graphiti S16–S25 · LangGraph/LangMem S26–S29 · CrewAI S30 · Google ADK/Memory Bank S31–S34 · OpenAI Agents SDK S35 · Claude memory tool / Claude Code S36–S38 · AutoGen/AG2/Semantic Kernel/Agent Framework/Foundry S39–S46 · Tencent(보도자료) S47 · Weaviate Engram(블로그) S48 · Hindsight(가이드) S49 · Tabnine(블로그) S50 · Mem0 블로그 S52–S53.

- S1 https://docs.letta.com/guides/agents/memory-blocks
- S2 https://docs.letta.com/v1-sdk/memory/shared-memory
- S3 https://docs.letta.com/concepts/shared-memory
- S4 https://docs.letta.com/guides/agents/architectures/sleeptime
- S5 https://docs.letta.com/concepts/memfs
- S6 https://docs.letta.com/v1-sdk/memory/archival-memory
- S7 https://docs.letta.com/guides/ade/core-memory/
- S8 https://docs.mem0.ai/core-concepts/memory-types
- S9 https://docs.mem0.ai/platform/features/entity-scoped-memory
- S10 https://docs.mem0.ai/api-reference/organizations-projects
- S11 https://docs.mem0.ai/api-reference/memory/history-memory
- S12 https://docs.mem0.ai/core-concepts/memory-operations
- S13 https://docs.mem0.ai/platform/features/memory-expiration
- S14 https://docs.mem0.ai/platform/features/memory-decay
- S15 https://docs.mem0.ai/platform/features/v2-memory-filters
- S16 https://help.getzep.com/concepts
- S17 https://help.getzep.com/graphiti/core-concepts/graph-namespacing
- S18 https://help.getzep.com/architecture-patterns
- S19 https://help.getzep.com/cookbook/how-to-share-memory-across-users-using-graphs
- S20 https://help.getzep.com/facts
- S21 https://help.getzep.com/searching-the-graph
- S22 https://github.com/getzep/graphiti
- S23 https://help.getzep.com/governance
- S24 https://help.getzep.com/users-and-user-graphs
- S25 https://blog.getzep.com/knowledge-graph-explorer/
- S26 https://docs.langchain.com/oss/python/langgraph/memory
- S27 https://langchain-ai.github.io/langmem/concepts/conceptual_guide/
- S28 https://docs.langchain.com/oss/python/langgraph/stores
- S29 https://docs.langchain.com/langsmith/configure-ttl
- S30 https://docs.crewai.com/en/concepts/memory
- S31 https://adk.dev/sessions/state/
- S32 https://adk.dev/sessions/memory/
- S33 https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/memory-bank/generate-memories
- S34 https://docs.cloud.google.com/vertex-ai/generative-ai/docs/agent-engine/memory-bank/manage-memories
- S35 https://openai.github.io/openai-agents-python/sessions/
- S36 https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
- S37 https://code.claude.com/docs/en/memory
- S38 https://code.claude.com/docs/en/sub-agents
- S39 https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/memory.html
- S40 https://docs.ag2.ai/latest/docs/use-cases/notebooks/notebooks/agentchat_memory_using_mem0/
- S41 https://learn.microsoft.com/en-us/semantic-kernel/concepts/vector-store-connectors/
- S42 https://learn.microsoft.com/en-us/agent-framework/agents/conversations/context-providers
- S43 https://learn.microsoft.com/en-us/agent-framework/integrations/by-component/context-providers/
- S44 https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/what-is-memory
- S45 https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/memory-usage
- S46 https://devblogs.microsoft.com/foundry/memory-build2026/
- S47 https://www.prnewswire.com/apac/news-releases/tencentdb-agent-memory-tops-20-000-github-stars-in-90-days-launches-team-memory-for-multi-agent-collaboration-302850576.html
- S48 https://weaviate.io/blog/engram-deep-dive
- S49 https://hindsight.vectorize.io/guides/2026/04/21/guide-building-multi-agent-systems-with-shared-memory
- S50 https://www.tabnine.com/blog/shared-memory-for-multi-agent-development/
- S52 https://mem0.ai/blog/multi-agent-memory-systems
- S53 https://mem0.ai/blog/state-of-ai-agent-memory-2026

Confidence: 공식 문서 인용 High, 블로그·보도자료 Medium, "확인 필요" 표기 항목 Low. 에이전트가 Letta 튜토리얼 일부는 fetch 실패로 v1-sdk 페이지로 대체했고, Mem0 대시보드 상세·Zep TTL·Memory Bank TTL·LangGraph 운영 UI 는 문서를 못 찾았다.

## 접근 못 한 것

- Hugging Face MCP 연결 끊김. arXiv API 로 대체.
- PAKDD 2026 서베이 "Memory in LLM-based Multi-agent Systems" (Springer 10.1007/978-981-92-1468-6_10, techrxiv 176539617): 두 곳 모두 403/로그인. 본문 미확인이라 문서에 넣지 않았다.
