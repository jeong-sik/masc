# Shared agent memory research R1

- 날짜: 2026-09-02
- 질문: keeper 별 Memory OS 위에 공용 지식 층을 둘지, 둔다면 어떤 모양인지. TUI Memory 탭을 상위에 둘지 Keepers 하위에 둘지에서 출발했다.
- 선행 결정: RFC-0251 §3 (미결, 선택지 둘), RFC-0247 (Board 를 keeper 간 정정 채널로 지정), RFC-0244 (문서는 삭제됨. RFC-0365:215 가 "per-keeper 격리는 RFC-0244 가 sandbox-containment 속성으로 명시 거부" 라고 인용).
- 이 문서는 결정하지 않는다. 결정은 RFC 가 한다. 근거와 확신 수준은 `2026-09-02-shared-agent-memory-evidence-record.md`.

## 1. 지금 masc 에 있는 것 (실측, 2026-09-02 19:20 KST)

| 항목 | 값 | 출처 |
|---|---|---|
| Memory OS 저장소 | keeper 당 셋: `memory-current`(ordinary), `memory-source-current`(source-bound), `memory-journal` | `<base-path>/.masc/config/keepers/` |
| 저장소 수 | 12 (살아 있는 keeper 9 + 은퇴 3: taskmaster, lab-sangsu, microvm-probe-829) | 같은 디렉터리 |
| 사실 수 | 711 | 12개 `memory-current.json` 합 |
| 분류 | lesson 324, fact 162, validated_approach 98, constraint 93, goal 13, preference 13, blocker 6, code_change 2 | 닫힌 8분류, `keeper_memory_os_types.mli:142-150` |
| 출처 | injected 656 (librarian 이 턴 기록에서 씀), authored 55 (keeper 가 `keeper_memory_write` 로 직접) | `origin.kind` |
| 강화(reinforcement) | 711건 전부 0 | 바이트 동일 재관측이 한 번도 없었다 |
| keeper 간 동일 claim | 0 (앞 40자 기준도 0) | 12 저장소 교차 |
| 다른 keeper 를 이름으로 언급하는 사실 | 113 (16%) | 예: "code-reviewer 의 축약 수정안은 … 컴파일 실패" (analyst, lesson) |
| Board 를 언급하는 사실 | 49. 그중 post/comment id 를 적은 것 12 (fact 10, lesson 1, constraint 1) | `p-…`/`c-…` 정규식 |
| 조정 문구(승인 id, task id, 회차, 보고, 인계)를 담은 사실 | 254 (36%). lesson 110, fact 74, validated_approach 33 | 정규식, 보수적 |
| masc 도구 사용법에 관한 lesson | 191 / 324 (59%) | `keeper_`, `masc_`, Execute, 샌드박스, Gate 등 |
| claim 길이 | 중앙값 226자, p90 444자, 최대 2,088자 | |
| Board 7일 | 글 1,363 / 댓글 1,763. system verification 624, automation ops 287, keeper 글 rondo 252·lane-smith 183·code-reviewer 104 | `board_posts.jsonl`, `board_comments.jsonl` |
| recall | 자르거나 순위 매기지 않고 전부 넣거나 아예 안 넣는다. source-bound 는 파일 바이트가 바뀌면 claim 대신 무효화 표시를 넣는다 | `keeper_memory_os_recall.mli` |
| 공용 층 | 없음. `_shared` 는 RFC-0251 §2 로 제거. Memory OS 코드에 `_shared` 참조 0 | `rg _shared lib/keeper/keeper_memory_os*.ml` |

과거 실측(RFC-0247, 2026-06-16): 사실 6,462건, `_shared` 승격 산출 17건이 17건 모두 조정 상투어, `stale_factor` 는 전부 0.0. 지금은 711건이다. 두 달 반 만에 9분의 1 로 줄었고 그 사이 RFC-0251 이 점수 층을 걷어냈다.

읽는 법. keeper 들은 서로에 대해 배운 것을 각자 저장소에 적는다(113건). 그러나 같은 문장을 둘 이상이 가진 경우는 없다. "여러 keeper 가 같은 것을 배웠으니 승격하자" 는 빈도 기준 공용화의 재료가 지금 데이터에 없다. Board 글을 출처로 적은 사실은 12건뿐이다. Board 가 7일에 1,363건을 흘려보내는데 저장소로 옮겨진 흔적은 그중 극히 일부다. "Board 가 곧 공용 지식" 이라고 하려면 이 전환율이 문제다. 저장소의 3분의 1은 조정 문구이고 lesson 의 6할은 masc 도구 사용법이다. 공유할 가치가 가장 분명한 부류가 이 "도구 사용법 lesson" 인데, keeper 의 역할과 무관하게 같은 도구를 쓰는 모두에게 맞는 지식이다.

## 2. 논문 (2025-12 ~ 2026-09)

### 2.1 직접 확인한 것 (abstract 또는 본문)

| 논문 | 무엇을 말하나 | masc 에 닿는 지점 |
|---|---|---|
| Governed Shared Memory for Multi-Agent LLM Systems (arXiv 2606.24535, 2026-06) | fleet memory 실패 4종: unauthorized leakage, stale propagation, contradiction persistence, provenance collapse. primitive 4종: scoped retrieval, temporal supersession, provenance tracking, policy-governed propagation. 스코프 agent-local / team-shared / tenant-global / restricted. MemClaw 구현. Table 2: 같은 fleet 가시성 117/120, 타 fleet 누출 0/80, 모순 감지 90/90. §9.2 near-duplicate 거부가 모순 감지 앞에서 절반을 가로챔. 승격 기준은 미정의(스코프는 쓸 때 정함) | 공용 층의 최소 요건. masc 는 provenance(origin.trace_id)와 supersession(RFC-0247 `Supersedes`)은 있고 scoped retrieval 과 policy-governed propagation 은 없다 |
| Scaling Teams or Scaling Time? LLMA-Mem (arXiv 2604.03295, 2026-03) | local / shared / hybrid 비교. Table 3(coding, Qwen3-32B): Local TS 49.68 > Shared 46.79 > Hybrid 46.52. §4.5.1 이유: 다른 역할이 만든 경험을 꺼내 쓰는 cross-role interference, hybrid 도 남음. Table 3(§4.5.2): 통합 간격 N=2/5/10/20 중 5가 최고, N=2 는 "충분한 증거 전에 절차화" | 역할이 뚜렷한 keeper 에게 keeper 별 저장소가 기본값이라는 유일한 정량 ablation. 승격을 서두르지 말라는 유일한 정량 힌트 |
| Learning to Share (arXiv 2602.05965, ICML 2026) | 병렬 팀의 중간 단계를 global bank 에 넣을지 RL 로 학습한 controller 가 결정 | 공유 여부를 "판단" 으로 정한다는 점에서 RFC-0251 (b). 다만 학습된 controller 는 masc 가 거부하는 LLM/학습 분류기 |
| Gated-Memory Routing (arXiv 2609.00237, 2026-08-31) | Write Gate 가 중복 아닌 단계만 기록, Retrieval Gate 가 각 agent 에 작은 부분집합. HumanEval 비용 31.9% 감소 | "전부 넣거나 안 넣는" masc recall 과 반대. 참고 |
| MAPLE-Guard (arXiv 2608.00426, 2026-08) | 한 번 심은 오염이 retrieval → 공용 승격 → 다른 agent 재사용으로 번진다. write·retrieval·promotion·cross-agent reuse 네 지점의 gate. LongMemEval 공격 성공률 38.2% → 0.9% | 공용 층은 오염 전파 경로다. 승격 지점에 판정이 있어야 한다. masc 의 Board 는 판정을 거친다 |
| MemGuard (arXiv 2608.21867, 2026-08) | verifier 결과를 일회성 필터가 아니라 reward·confidence·label·uncertainty 로 기억에 붙여 retrieval·충돌·요약·보관에 재사용. 16개 설정 전부 최고 | masc 의 verifier 판정을 기억에 붙이는 것은 "가치 매기기" 라 RFC-0251 과 충돌. 충돌 지점으로 기록 |
| Invalidation Contracts (arXiv 2609.00243, 2026-08-31) | 캐시된 복구 제안에 version stamp 와 cacheability hint 를 붙여 drift 때 행 단위로 무효화. 행 단위 eviction precision 1.00 | masc source-bound(파일 sha256 무효화)와 같은 원리. 공용 층에도 같은 계약이 필요 |
| Dual-Layer Agentic Memory (arXiv 2608.22215, 2026-08) | 쓰기 시 non-write / write-new / write-update 로 라우팅, 중복 68% 제거하며 QA EM 98% 유지 | librarian 의 "생략이 곧 삭제" 문제(RFC librarian-curator P-3)와 대비되는 명시적 쓰기 분류 |
| Selective Forgetting (arXiv 2608.28978, 2026-08) | 그래프 메모리는 flat retrieval 보다 못했고(F1 0.417 vs 0.468), 망각 모듈만 유효(9.8% 노드 제거, F1 변화 +0.001) | RFC-0247 의 그래프 부분엔 부정적, 망각 부분엔 긍정적 근거 |
| The Compaction Cliff (arXiv 2608.22752, 2026-08) | 컴팩션 한 번에 안전 규칙 53% 보존, 다섯 번이면 10%. 유형별 보존 정책(Knowledge Triage) | masc 의 2026-07-31 컴팩션 사고(librarian RFC §1)와 같은 현상. 분류별 보존 정책은 닫힌 8분류와 맞물린다 |
| Stage-Wise Utility-Risk (arXiv 2608.30177, 2026-08-31) | 쓰기 단계는 임계형 위험, 관리 단계는 정책에 따라 분리 가능, 검색 단계는 효용과 위험이 함께 는다 | 공용 층의 위험은 검색에서 커진다. scoped retrieval 이 필요한 이유 |
| Memory in the Age of AI Agents (arXiv 2512.13564, 2025-12) | 형태·기능·동역학 분류. §7.5 multi-agent 공유는 프론티어. §7.5.2 미해결: 충돌 해소, 일관성, 프라이버시, 노이즈, 쓰기 권한 | 학계도 아직 multi-agent 공유를 정리 못 했다 |

### 2.2 에이전트 조사분 (원문 확인, 수치는 표·절 번호가 있는 것만)

| 논문 | 요지 |
|---|---|
| Governed Collaborative Memory as Artificial Selection (arXiv 2605.04264, 2026-05, Viewpoint) | agent-local(private by default) → shared institutional(증거·비준·append-mostly) → archive(출처만) 계층. "supersede-not-erase": 거부·보류·대체된 후보도 선택이 일어난 증거로 남긴다. 네 질문: 무엇이 변하나 / 어떻게 평가하나 / 누가 비준하나 / 무엇이 고정되나. 저자 스스로 §4 에서 인과 우위를 입증하지 않았다고 적음(12 이벤트, 통제 비교 아님) |
| A Survey of Agent Memory in the Second Half (arXiv 2602.06052, 2026-01) | MAS 메모리 구조 4종: private-only / shared-workspace / hybrid / orchestrated. 라우팅 3종: orchestrator / agent-initiated / memory-driven. 위험: 쓰기 통제, 일관성 피드백 루프, 무관 정보 누적 |
| A Survey on Long-Term Memory Security (arXiv 2604.16548, 2026-04) | 6단계 생명주기에 Share & Propagate 를 별도로 둠. 전파 3종: lateral(agent↔agent), vertical(개인 → 조직 승격), temporal. 방어는 "sparse". 원칙 5: write authorization, provenance visibility, principal-scoped retrieval, rollbackability, verified forgetting |
| Multi-Agent Memory from a Computer Architecture Perspective (arXiv 2603.10062, 2026-03) | 읽기 시 충돌 처리와 쓰기 가시성 시점이 핵심. "conflicts are often semantic". agent 간 접근 프로토콜 자체가 미정의 |
| G-Memory (arXiv 2506.07398, NeurIPS 2025) | insight/query/interaction 3계층 공유 그래프. insight 는 LLM 요약, 읽을 때 역할별 필터 Φ. Table 1(GPT-4o-mini): ALFWorld 88.81%(+11.20) |
| Multi-Agent Transactive Memory (arXiv 2606.19911, 2026-06) | producer 가 궤적을 공유 저장소에 넣고 consumer 가 검색. 승격은 성공 점수 임계값뿐. 본문: 중간 크기 인덱스에서 WebArena 성공률이 오히려 낮아짐("plausible but unhelpful trajectories") |
| Collaborative Memory (arXiv 2505.18279, 2025-05) | private fragment / shared fragment 2계층, fragment 마다 불변 provenance. 공유 여부는 write policy 가 자동 결정 |
| Organizational Memory for Agentic Business Process Execution (arXiv 2607.03228, 2026-07) | 문서 → Global Curator 품질·충돌 검사 → 부서 인간 전문가 승인. §6.2 정책 준수 88–95% vs RAG 70–80%. agent 경험의 자동 승격은 다루지 않음 |
| Shared Selective Persistent Memory (arXiv 2607.09493, 2026-07) | 과제 명세·스키마·도구 설정·출력 제약 4종만 남기고 추론 흔적은 버림. 96% vs 무메모리 79% vs 전체 히스토리 71% |
| No Attacker Needed (arXiv 2604.01350, 2026-04) | 악의 없는 교차 오염. 원시 공유 상태에서 오염률 57–71%. 텍스트 정화는 실행 산출물(코드·설정)엔 부족 |
| State Contamination (arXiv 2605.16746, 2026-05) | "memory laundering": 요약 뒤엔 검출기를 통과하면서 영향은 남음. 요약 전 정화만 효과 |
| GateMem (arXiv 2606.18829, 2026-06) | 다주체 공유 메모리에서 utility / access control / active forgetting 동시 평가. 어떤 방법도 셋을 동시에 만족 못 함 |
| GroupMemBench (arXiv 2605.14498, 2026-05) | 다자 대화 믿음 추적. 최고 시스템 평균 46%, BM25 가 대부분의 메모리 시스템과 같거나 나음 |
| How Much Coordination Gain Is Real? (arXiv 2606.20695, 2026-06) | 동일 설정 반복에서 +5pp 노이즈 바닥. 최근 조정 아키텍처 10편 중 7편의 헤드라인 효과가 그 아래 |
| ExpeL (arXiv 2308.10144, 2023-08) | 단일 agent. §4.2 ADD/UPVOTE/DOWNVOTE/EDIT 카운트, 0이면 삭제. 카운트만 분리한 ablation 은 없음 |

승격 기준을 통제 비교한 논문은 없다. 카운트(ExpeL), 성공 임계값(MATM), 누적 간격(LLMA-Mem), LLM 판정(G-Memory, Mem0, Zep), 학습된 게이트(Learning to Share), 시스템 정책(Collaborative Memory, MemClaw), 인간 비준(Cuadros, Kirchdorfer, memorywire 2606.01138)이 공존한다. Cuadros §5 가 이 공백을 명시했다.

## 3. 제품 (공식 문서, 2026-09-02 접근)

| 제품 | scope | private→shared 이동 | 출처·충돌 | 잊기 | 운영자 UI | 소유 |
|---|---|---|---|---|---|---|
| Letta | agent 별 block/archival/MemFS. 공유는 한 block 을 여러 agent 에 attach. 최신 문서는 이 방식을 legacy 로 부르고 Git 저장소형 "shared memory repositories" 로 안내 | 자동 승격 없음. 개발자가 attach 하거나 agent 가 commit+push. dreaming 은 승인 없이 갱신 | block 은 writer 기록 없음. `memory_rethink` 는 last-writer-wins, 동시 쓰기 시 "lost updates" 를 문서가 인정. MemFS 는 git commit | 글자 수 `limit` 뿐 | ADE 코어 메모리 패널 | block 은 agent 와 독립 객체. 지우면 attach 된 모든 agent 에서 사라짐 |
| Mem0 | `user_id`/`agent_id`/`app_id`/`run_id` 태그 | 승격 없음. 공유는 검색 시 filter OR 합성. user 와 agent 둘 다 붙은 레코드는 기본 경로가 만들지 않음 | history API(old/new, ADD/UPDATE/DELETE, 계기 대화). 충돌은 add 시 LLM 판단 | expiration 은 숨김, decay 는 랭킹 편향 | 대시보드 필터 | store(project) 중심 |
| Zep / Graphiti | user graph vs standalone graph, `group_id` | 앱이 어느 graph 에 쓸지 정함 | edge 마다 created/valid/invalid/expired 4 시각. 모순은 삭제 대신 무효화 + 새 사실 둘 | edge 삭제. TTL 없음 | Graph 뷰 | store 중심, 어떤 agent 에도 속하지 않음 |
| LangGraph / LangMem | thread vs cross-thread Store, namespace tuple(org, user, …) | 코드가 namespace 선택. 승격 없음 | created/updated 만. writer 없음. 충돌은 LLM | TTL(`default_ttl`, refresh_on_read) | 없음(확인 필요) | store 는 graph 와 독립 |
| CrewAI | 단일 Memory + 경로형 scope(`/project/alpha`, `/agent/researcher`). crew 전체 공유가 기본 | scope 를 안 주면 LLM 이 배치. `private=True` 로 비공개 | `source` 필드. 유사도 ≥0.85 면 LLM 판단, ≥0.98 은 뒤 것을 조용히 버림 | reset 만 | `crewai memory` TUI | 경로 중심 |
| Google ADK / Memory Bank | session 상태 접두사(`user:`, `app:`, `temp:`), Memory Bank 는 scope dict | 명시 호출 또는 비동기 생성. 승격 없음 | consolidation 결과 CREATED/UPDATED/DELETED, 삭제 사유 "contradictory" | TTL 문서 없음 | 확인 필요 | app/user 귀속 |
| OpenAI Agents SDK | session 하나. 여러 agent 가 같은 session 공유 가능 | 해당 없음 | 해당 없음 | 해당 없음 | 없음 | session 은 agent 와 독립 |
| Claude Code | managed(org) / user / project(`CLAUDE.md`, git 공유) / local 4단 + repo 별 auto memory(machine-local, 첫 200줄/25KB) | 사람이 "CLAUDE.md 에 넣어" 로 옮김. 사람 승인형 | `modified` 시각 | 없음 | `/memory` | project 는 version control 로 공유 |
| MS Agent Framework / Foundry Memory | context provider, `scope` 문자열. Foundry 는 store + scope 격리, 100 scopes/store | 코드가 scope 선택 | LLM | `default_ttl_seconds`, remember/forget 즉시 명령 | 포털에서 item CRUD (Build 2026) | store 중심 |
| TencentDB Team Memory (2026-08, 보도자료) | private → team-wide, user/role/agent 별 권한 | "reviewed and then shared" | 자산마다 owner·version·status·usage history | 확인 필요 | Memory Hub 콘솔 | team 자산 |
| Weaviate Engram (2026-06) | project / user / property scope, add·query 양쪽 강제 | 코드 | 확인 필요 | 확인 필요 | 확인 필요 | store |
| Hindsight (vendor 가이드, 2026-04) | bank 를 user/project/team 으로 나눔. "진짜 서로 배워야 하는 actor 사이에서만 공유" | retain-first | 다루지 않음 | 다루지 않음 | 다루지 않음 | bank |

반복되는 것.
1. scope 는 객체가 아니라 태그다. 쓸 때 붙이고 읽을 때 거른다. 예외는 Letta block(객체 attach)과 파일형(Claude Code, MemFS).
2. private→shared 자동 승격은 어느 제품에도 없다. 빈도나 점수로 올리는 제품을 못 찾았다. 이동은 코드가 scope 결정, 사람 검토(Tencent, Claude Code), agent 자기 갱신(Letta dreaming) 셋뿐이다.
3. 출처는 두 계열. bi-temporal 그래프(Zep) 또는 변경 로그(Mem0 history, MemFS git). LangGraph·ADK·Letta block·Foundry 는 writer 식별이 없다.
4. 충돌 처리 넷. LLM 판단, 시간축 무효화(Zep), last-writer-wins(Letta block), git merge(MemFS).
5. 잊기는 삭제보다 숨김·감쇠가 많다. 진짜 만료는 LangGraph TTL 과 Foundry 뿐.
6. 소유는 거의 store 다. store 가 agent 보다 오래 살고 두 agent 가 한 store 를 쓴다.

문서가 스스로 인정한 미해결. Mem0 "두 agent 가 한 사실에 대해 다르게 말하면?" 에 답 없음. Letta 동시 `memory_rethink` 는 update 유실. MemClaw 는 실운영에서 sub-tenant scope 우회를 발견. Always-On Agents 서베이(arXiv 2606.30306)는 문헌이 "쌓고 꺼내기" 에 몰려 있고 "통제·복구·놓아주기" 는 드물다고 적었다.

## 4. 정리

**정착된 것.**
1. private / shared / hybrid 3분법과 agent-local → team → org 어휘. 공유 층이 거버넌스 부담을 가장 크게 진다.
2. 역할이 다른 agent 사이의 무차별 공유는 해롭다. LLMA-Mem(local > shared > hybrid), Shared Selective Persistent Memory(전체 히스토리 71% < 무메모리 79%), No Attacker Needed(오염 57–71%)가 독립적으로 보고. keeper 별 저장소는 기본값으로 맞다.
3. 모순은 지우지 않고 시간축으로 대체한다(Zep, MemClaw, Cuadros). provenance 는 공유 층의 필수 메타데이터.
4. 공용 층을 두면 최소 넷이 필요하다. 범위 있는 검색, 시간 순 대체, 출처, 정책으로 통제되는 전파(MemClaw). 승격 지점에 gate(MAPLE-Guard).
5. 빈도로 승격하는 것에 근거가 없다. 제품 어디에도 없고, masc 실측에서도 동일 claim 이 0건이라 재료 자체가 없다.

**다투는 것.**
1. 승격 판단을 누가 하나. 통제 비교가 없다. LLMA-Mem 의 "N=2 는 너무 이르다" 가 유일한 정량 힌트. 인간 비준은 병목(Cuadros).
2. 무엇을 공유하나. LLMA-Mem hybrid 는 절차·팀 통계만 공유하고 episodic 은 사유. masc 분류로 옮기면 validated_approach·constraint·lesson(특히 도구 사용법)은 공유 후보, fact(대개 지금 상태)·goal·preference 는 사유.
3. hybrid 가 local 보다 나은가. 서베이는 권하고 유일한 ablation 은 hybrid 를 최하위로 둔다.
4. 공유 이득의 측정. GateMem·GroupMemBench 는 실패를 재고 이득을 재는 팀 벤치마크는 없다. 조정 이득의 노이즈 바닥이 +5pp.

**masc 의 모양을 문헌에서 부르는 이름.** "governed collaborative memory"(Cuadros): agent-local 은 private by default, 후보는 증거·평가·명시적 결과를 거쳐 shared institutional 로 고정. 구조 어휘로는 Huang 서베이의 hybrid + agent-initiated routing, MemClaw 의 policy-governed propagation. 읽기 측 보완은 G-Memory 의 역할별 필터 Φ. masc 는 이미 (i) keeper 별 store, (ii) 승격 없음, (iii) writer=origin.trace_id, (iv) source-bound 바이트 무효화, (v) verifier·Board 판정, (vi) 닫힌 8분류를 갖고 있다. 제품군 기본값과 다른 점은 recall 이 "전부 아니면 없음" 이라는 것 하나다. 공용 층을 두면 Tencent 의 "검토 후 공유" 와 MemClaw 의 primitive 넷이 가장 가까운 선례다.

**RFC-0251 §3 두 선택지에 대한 함의.**
- (a) 공용 층 없음, Board 로 공유. 지금 Board 가 이미 명시적이고 판정을 거친 전파 채널이다(7일 1,363건). 부족한 것은 Board 글이 기억으로 남지 않는다는 점. keeper 가 Board 에서 읽은 것은 자기 저장소에 사실로 적을 때만 남고(Board 출처 12건), 그 전환은 librarian 의 판단에 맡겨져 있다. (a) 를 택하면 "Board → 저장소" 전환을 측정하고 필요하면 librarian 계약에 Board 출처 필드를 두는 것이 다음 일이다.
- (b) 판정으로 승격하는 공용 층. MemClaw 의 primitive 넷을 masc 타입으로 세워야 한다. 승격은 keeper 의 명시적 쓰기(authored)이고 빈도·점수는 쓰지 않는다. 읽기 측에 역할 필터가 없으면 LLMA-Mem 의 cross-role interference 가 그대로 온다. 공유 후보를 분류로 제한(validated_approach·constraint·lesson)하는 것이 그 필터의 가장 싼 형태다.

**TUI 질문의 답은 어느 쪽이든 같다.** 상위 Memory 탭은 저장소 브라우저(은퇴 keeper 의 저장소가 남는 것이 그 증거), Keepers 하위는 "이 keeper 가 다음 턴에 아는 것". 공용 층이 생기면 그 브라우저에 한 줄이 더 생긴다. RFC-tui-operator-ia §3.4 와 같다.

## 5. 다음

1. RFC-0251 §3 를 결정하는 RFC 한 편. 이 문서가 그 입력.
2. 결정 전 측정 둘. (i) Board 글이 keeper 저장소로 옮겨지는 비율과 지연(오늘 표본 12/711). (ii) 도구 사용법 lesson 191건 중 둘 이상의 keeper 가 같은 도구에 대해 각자 배운 것이 몇 건인지(공용 층의 첫 내용물 후보).
3. 결정과 무관하게 필요한 것. Board 출처를 사실에 typed 로 남기는 것(지금은 claim 본문의 `p-…` 문자열뿐). MemClaw 의 provenance collapse 가 이 자리다.
