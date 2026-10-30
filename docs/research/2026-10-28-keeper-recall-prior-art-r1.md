# Keeper 기억 recall: 기성 제품과 논문 대조, 우리 구현의 빠진 곳 (r1)

- 날짜: 2026-10-28 (KST). 외부 자료는 같은 날 확인했다.
- 범위: Keeper 의 기억(Memory OS)이 턴 대화에 닿게 하는 방법. 저장·흡수·교체는 다루지 않는다.
- 방법: 외부 제품은 공식 문서·공식 저장소·릴리즈 노트를 조사 에이전트가 직접 읽었다. 논문은 arXiv 본문의 표를 확인한 것(본)과 초록만 본 것(초)을 구분했다. 우리 구현은 현재 `origin/main` 의 코드와 라이브 설정·로그를 읽어 셌다. 측정은 [기준선 증거](../evidence/keeper-recall-baseline-2026-10-28/README.md) 에 있다.
- 확신도: H 는 공식 문서·소스를 직접 읽음, M 은 이슈 보고자 측정이나 간접 근거, L 은 제3자 글이나 추정.
- 이 문서는 제안이 아니라 조사다. 결정은 [RFC-keeper-recall-reaches-the-turn](../rfc/RFC-keeper-recall-reaches-the-turn.md) 에 있다.

## 1. 요약

- 색인만 싣고 본문은 모델이 도구로 당기게 한 제품 대부분에서 "모델이 안 당긴다"는 보고가 있다. 우리 측정도 같은 방향이다.
- 본문까지 호스트가 골라 싣는 곳은 OpenClaw, Hermes 의 외부 provider, 예전 Claude Code 뿐이다. 이 중 점수와 임계값으로 고르는 방식은 우리 헌법과 충돌해서 가져올 수 없다.
- "하나를 당기면 이웃이 딸려 오는" 탐색은 어느 제품 코어에도 없다. 플러그인에 있는 것도 효과를 잰 자료가 없다.
- 공개 벤치마크는 대부분 대화 내용을 맞히는지를 잰다. 도구를 쓰는 과제에서 기억 활용을 재는 것은 있다(Mem2ActBench, [r2](2026-10-28-keeper-recall-prior-art-r2.md)의 MERIT). 기억이 필요하다는 것을 스스로 알아차려 도구를 불렀는지를 따로 재는 것은 못 찾았다.
- 우리 쪽에는 약속만 있고 코드가 없는 층이 있다. 호스트가 고르는 판정 층, recall 평가 하네스, 사실 사이의 연결이다.

## 2. 기성 제품

버전은 확인 시점이다. OpenClaw v2026.10.8, Hermes v0.22.5, Pi v1.4.0, Codex rust-v0.164.0, Claude Code v2.1.311.

| 제품 | 항상 들어가는 것 | 구조 | 무엇을 가져올지 정하는 쪽 | 약점 보고 |
|---|---|---|---|---|
| OpenClaw | MEMORY.md·USER.md(파일당 20,000자, 전체 60,000자), 시스템 프롬프트의 Memory Recall 지시문 | 코어는 평평한 파일. 위키 플러그인에만 관계(종류·가중치·확신도)와 백링크가 있고, 프롬프트 요약은 기본 꺼짐 | 호스트(쓸 때 달아 둔 trigger·importance 점수 0.65 이상 최대 3개), 답 전에 블로킹 서브에이전트(Active Memory), 모델의 `memory_search` 호출 | 찾아볼 줄 모르면 영영 못 찾는다(#38847), 이전 작업 질문에서 검색을 건너뜀(#137221), 회상 패턴이 5개 언어뿐이라 독일어는 안 켜짐(#151766) |
| Hermes Agent | MEMORY.md 2,200자·USER.md 1,375자 고정 스냅샷, 스킬 색인(카테고리 트리) | 메모리는 평평한 항목, 스킬은 카테고리 트리. 제3자 OpenViking 은 L0→L1→L2 단계 로딩 | 모델(스킬은 "MUST load", 과거 대화는 `session_search`), 외부 provider 는 호스트가 매 턴 전에 prefetch | 에이전트가 주입된 provider 블록보다 `session_search` 를 먼저 부름(#46955) |
| Pi | 메모리 기능 없음. AGENTS.md, 스킬 이름·설명 | 링크·색인 없음 | 모델이 `read` 로 SKILL.md 를 읽음. 공식 문서: "A model might fail to load a relevant skill" | 이름이 read·bash 인 도구가 없으면 스킬 목록이 경고 없이 빠짐(#9874) |
| Codex | `memory_summary.md`(2,500토큰, 넘으면 중간을 자름) | 요약 → 포인터 줄("무엇이 들었고 언제 필요한지 한 문장") → rollout 요약 | 모델. v1 지침은 "애매하면 기억을 훑어라", v2 는 "추측성 검색 금지" | 요약이 조용히 중간에서 잘림(#48679, 약 60% 손실 보고), 반복 검색(#41621), 백그라운드 통합이 한도를 깎음(#51177) |
| Claude Code | MEMORY.md 앞 200줄 또는 25KB, 스킬 이름 | 한 줄 색인과 토픽 파일. 링크 없음 | 모델이 파일 도구로 고름 | 관련 노트 4개를 미리 넣었는데 114턴 동안 읽기 0회(#78795), 색인 끝이 조용히 잘림(#99403) |
| Claude API memory tool | 켜면 "ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE" 지시문이 시스템 프롬프트에 자동으로 붙음 | `/memories` 디렉터리 | 모델 | Anthropic 내부 평가 +39%(과제 수·기준선 비공개) |
| 예전 Claude Code 소스(참고용) | 색인 전문(200줄·25,000자) 또는 플래그가 켜지면 색인 없음 | 파일 하나가 기억 하나, frontmatter `name`·`description`·`type` | 플래그 on 이면 턴마다 별도 모델이 목록(이름·시각·description)만 보고 최대 5개를 고름 | 기억끼리 링크를 따라가는 코드 없음 |

출처와 확신도는 H 가 기본이다. 이슈 번호의 수치는 보고자가 잰 값이라 M 이다.

가져올 것:

- 색인 한 줄은 "무엇이 들었고 언제 필요한지"를 말한다. Codex v2 와 예전 Claude Code 의 `description` 이 같은 역할이다. 쓰는 시점에 쓰는 쪽이 적는다.
- 넘칠 때 조용히 자르지 않는다. Hermes 는 항목을 지우지 않고 설명만 줄이고, Claude Code 스킬 목록은 덜 쓴 스킬의 설명부터 뺀다. 반대 사례가 Codex #48679 와 Claude Code #99403 이다.
- 측정을 먼저 만든다. Hermes 는 프로그램 오라클로 3회씩 A/B 하고, Codex 는 읽은 파일 종류별로 사용량을 센다.

가져오지 않을 것:

- OpenClaw 의 점수 0.65 와 최대 3개, 언어별 회상 패턴. 헌법의 `magic_number`·`string_matching` 과 충돌하고, 패턴은 실제로 독일어에서 깨졌다(#151766).
- 예전 Claude Code 의 최대 5개, 세션 누적 60KB 중단. 숫자 상한으로 흐름을 정하는 방식이다.

## 3. 논문과 벤치마크

표기: 본은 본문·표를 확인, 초는 초록만 확인. 수치는 본으로 확인한 것만 적었다.

### 3.1 pull 만 두면 안 불린다는 증거

| 자료 | 내용 | 확신 |
|---|---|---|
| Vercel, 2026-01-27 (블로그) | Next.js 16 평가에서 skill 은 56% 케이스에서 한 번도 호출되지 않았다. AGENTS.md 에 8KB 색인을 항상 넣은 쪽은 통과율 100%, skill 기본은 53%. 벤더 자체 평가 1건이고 모델명·케이스 수는 페이지에 없다 | M |
| Delivery, Not Storage (arXiv 2607.20972, 단독 저자, 초) | 미리 채운 저장소에서도 자발적 기억 사용이 거의 0("0 memory operations in 114 turns"). 하네스가 넣으면 모든 실행에서 전달됨. 단 넣는 큐가 결정론이라 우리 제약과 충돌 | L |
| Alibaba Cloud, 2026-08-05 (블로그) | 모델이 먼저 기억 도구를 부르는 일이 드물다. 별도 Recall Agent(LLM)가 고르게 하니 오프라인 평가 회상 성공이 40%에서 77%로 올랐다 | M |
| Letta, Anthropic memory tool | pull 이 잘 된 사례에도 첫 호출 강제가 붙어 있다 | H |

우리 측정과 같은 방향이다. 기억 검색은 도구 호출의 0.80% 였다. Skill 목록이 쓰이는지는 이 로그로 알 수 없다. 쓰는 도구(`keeper_skill`)는 호출이 0건이었고, 처음에 세었던 0.60%(1,657건)는 만드는 도구(`keeper_skill_validate`, `keeper_skill_publish`)였다.

### 3.2 계층·트리·그래프 기억

| 자료 | 핵심 | 우리 제약과의 관계 |
|---|---|---|
| MemTree (2410.14052, 본) | 노드마다 LLM 이 요약을 쓰지만 검색은 임베딩 코사인 top-k. 표1 MSC 정확도 MemTree 84.8, 전체 이력 95.6 | 충돌(점수). 트리 모양만 참고 |
| A-MEM (2502.12110, 본) | 새 노트에 LLM 이 링크 여부를 판단하고, 질의하면 링크된 기억이 딸려 옴 | 부분 충돌. 링크를 LLM 이 판단하는 점은 맞고, 후보 검색이 임베딩이라 안 맞음 |
| Zep/Graphiti (2501.13956, 본) | 쌍시간 지식그래프. 표2 LongMemEval 전체 컨텍스트 60.2%, Zep 71.2% | 순위가 점수라 충돌. 사실마다 유효 구간·교체 연결을 두는 구조는 참고 |
| HippoRAG 2 (2502.14802, 본) | LLM 이 triple 을 뽑고 순위는 PageRank | 충돌(점수) |
| Mem0 (2504.19413, 본) | 쓸 때 LLM 이 ADD·UPDATE·DELETE·NOOP 를 고름. 표2 LOCOMO 전체 컨텍스트 72.90%, Mem0 66.88% | 쓰기는 맞음. 전체 컨텍스트가 더 높음 |
| MIRIX (2507.07957, 본) | LLM 이 현재 topic 을 쓰면 시스템이 검색해 주입. 표2 전체 컨텍스트 87.52, MIRIX 85.38 | push 와 pull 의 절충 사례 |
| ReadAgent (2402.09727, 본), MemWalker (2310.05029, 본) | LLM 이 보이는 목록·요약 트리를 읽고 직접 고름. 유사도 없음. MemWalker 는 오판이 누적됨 | 제약과 맞음. 깊이는 3단 이내가 안전 |

사실이 키퍼당 4~121개면 LoCoMo(대화 평균 9K 토큰)와 비슷하거나 작다. 이 규모에서는 전체 노출이 기준선이고, 계층은 길 찾기가 아니라 표시 묶음으로 쓴다. 링크를 따라가는 방식이 링크 없는 목록보다 낫다는 비교 연구는 찾지 못했다.

### 3.3 평가

- LongMemEval (2410.10813, 본): 검색 지표(Recall@k)와 답 정확도를 따로 잰다. 이 분리를 쓸 수 있다.
- Ground Truth First (2607.21962, 단독, 초): 사실을 먼저 심고 질문을 만들어 정답이 구성상 보장되게 하고, 무기억 대조군과 반복을 둔다.
- MemoryAgentBench (2507.05257, 본), Mem2ActBench (2601.19935, 초): 능동 활용은 전반적으로 약하다.
- 편향된 기억이 도구 인자를 흔든다(Memory-Induced Tool-Drift, 2605.24941, 초). 무조건 주입하면 해가 될 수 있어서 싣기 전에 판정이 필요하다.

공개 벤치마크는 "필요할 때 도구를 불렀나"를 따로 재지 않는다. 우리가 직접 재야 한다. Claude Code 는 `claude plugin eval` 의 `tool_used: Skill` 채점기로 호출 여부를 재는데, 같은 모양을 기억 검색에 옮길 수 있다.

## 4. 우리 구현과 대조

현재 `origin/main` 과 라이브 설정을 읽은 결과다. 구현 여부는 코드로 확인했고, 라이브 여부는 설정과 로그로 확인했다.

| 약속 | 출처 | 상태 | 빠진 것 |
|---|---|---|---|
| 호스트가 턴 입력으로 기억을 고른다 | [RFC-memory-search-beyond-substring](../rfc/RFC-memory-search-beyond-substring.md) 단계 2 | 코드 없음 | 호스트가 고르는 판정 층. 대신 RFC 없이 TypeSafe 후속 판정이 기본 검색 안에 들어갔다 |
| 입력 연관 recall | [RFC-memory-os-recall-selection](../rfc/RFC-memory-os-recall-selection.md) (61KB, Draft) | 타입이 하나도 없음 | 전제였던 전량 주입이 10-01~02 에 사라졌다 |
| recall 가치를 judge 로 잰다 | [RFC-0247](../rfc/RFC-0247-memory-os-associative-graph-forgetting-brain.md) §-1 | 수식 파일과 수동 스크립트뿐 | 정답 세트와 기준선. "Value never measured"는 지금도 맞다 |
| 회수·개정 사건을 기록한다 | [RFC-0418](../rfc/RFC-0418-memory-is-reinforced-when-it-is-retrieved-not-reobserved.md) | 기록한다. 읽는 결정 경로는 없다 | 설계상 gate 가 아니라서 맞지만, 쓸 곳이 없다 |
| 근거 사실로 파생 결론을 잇는다 | [Memory support retraction](2026-09-01-memory-support-retraction-design-r1.md) | `keeper_memory_write` 만 쓸 수 있다 | live 에서 현재 사실 2,334개 중 1개. 읽는 곳은 철회 계산뿐 |
| 개인 기억에 위키 목차 같은 색인 | [RFC-keepers-see-the-wiki-table-of-contents](../rfc/RFC-keepers-see-the-wiki-table-of-contents.md) | 위키에만 있음 | 개인 기억용 색인은 어느 RFC 에도 없다 |
| 사실 사이의 연결, 안정 id | 적대 감사 G4 ([보고서](../reports/MASC-LIBRARIAN-MEMORY-OS-ADVERSARIAL-AUDIT-2026-07-30.md)) | 없음 | 기억 id 가 claim 의 해시라 다시 쓸 때마다 바뀐다 |

기준선에서 나온 사실:

- 프롬프트에 닿는 것은 "사실 N개" 안내문(약 1.1KB)과 working-context 포인터(약 0.35KB)뿐이다.
- 개인 기억을 호스트가 고르는 길이 없다. `Keeper_memory_select` 는 모델이 부르는 도구뿐이고 `workspace_memory_selection_enabled` 기본값은 false 다. `Keeper_workspace_memory_host_recall` 은 공용 기억용이다.
- 기본 `keeper_memory_search` 안의 후속 기억 판정이 기억 원문을 TypeSafe(`jev-latest`)로 보낸다. 별도 스위치가 없고 레인 스위치만 본다. [TypeSafe Jev 적용 연구](2026-09-18-typesafe-jev-masc-applicability-r1.md) §5 의 데이터 반출 위험에 해당한다.
- 공식 클라이언트는 같은 바이트의 블록을 다시 보내지 않는다(`Prompt_block_id.resent_when_held`). 안내문이 새로 전송되는 비율이 클라이언트마다 다르다.

## 5. 확인하지 못한 것

- 기억 도구 호출률을 모델별로 잰 학술 논문은 찾지 못했다. 과소 사용의 증거는 벤더 블로그 2건과 단독 저자 프리프린트 1건이다.
- Codex 공식 문서 페이지에는 크기·임계값이 없어 소스 코드로 대체했다. 문서와 소스가 다를 수 있다.
- OpenClaw 하이브리드 가중치의 공식 수치, Claude Code auto memory 의 시스템 프롬프트 원문, Pi 의 현재 프롬프트 토큰 수.
- 사실 121개 이하에서 "LLM 이 링크를 따라가는 탐색"과 "링크 없는 전체 목록"을 비교한 연구.
- 예전 Claude Code 소스의 `tengu_*` 플래그가 실제로 켜졌는지, 현행 버전과 얼마나 다른지.

## 6. 출처 (확인 2026-10-28)

- OpenClaw: https://docs.openclaw.ai/concepts/memory , https://docs.openclaw.ai/concepts/active-memory , https://docs.openclaw.ai/plugins/memory-wiki , https://github.com/openclaw/openclaw/issues/38847
- Hermes: https://hermes-agent.nousresearch.com/docs/user-guide/features/memory , https://github.com/NousResearch/hermes-agent/issues/46955
- Pi: https://pi.dev , https://github.com/earendil-works/pi/issues/9874
- Codex: https://github.com/openai/codex/tree/main/codex-rs/memories , https://github.com/openai/codex/issues/48679
- Claude Code: https://code.claude.com/docs/en/memory , https://code.claude.com/docs/en/skills , https://github.com/anthropics/claude-code/issues/78795
- Claude API: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool , https://claude.com/blog/context-management , https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Vercel: https://vercel.com/blog/agents-md-outperforms-skills-in-our-agent-evals
- Alibaba Cloud: https://alibabacloud.com/blog/proactive-memory-agent-the-agents-second-brain_603429
- 논문: arXiv 2410.14052, 2502.12110, 2501.13956, 2502.14802, 2504.19413, 2507.07957, 2402.09727, 2310.05029, 2410.10813, 2507.05257, 2607.21962, 2605.24941, 2601.19935, 2607.20972
