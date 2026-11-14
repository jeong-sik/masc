# 에이전트 의사결정 farm 의 바깥 근거 168개 재확인

- 확인 시각: 2026-11-12 KST. 조사는 19:20~22:26 에 돌았다. 출처 재확인은 같은 날 원문을 새로 받아서 했다.
- 조사 방식: 주제 12개를 나눴다. 주제마다 조사 에이전트 하나가 보고서를 썼다. 주제마다 재확인 에이전트 하나가 그 보고서가 인용한 원문을 다시 열어 발견마다 판정했다. 조사 에이전트 12개와 재확인 에이전트 12개다.
- 판정: 발견 168개 가운데 136개가 원문과 맞았다. 26개는 원문보다 세게 말했다. 5개는 원문을 잘못 인용했고, 1개는 옛 버전을 인용했다.
- 이 문서는 조사이고 결정이 아니다.
- 근거 묶음은 [`docs/evidence/research/2026-11-12-agent-farm-prior-art/`](../evidence/research/2026-11-12-agent-farm-prior-art/README.md) 에 있다. 주제별 발견 digest 12개가 들어 있다. 조사 보고서와 재확인 보고서 원본은 이 저장소에 없다.
- 관련 계획 문서: [`docs/reports/2026-11-12-agent-farm-plan.md`](../reports/2026-11-12-agent-farm-plan.md)
- 코드 좌표: 조사는 `efe98ca792c2`~`77f7bec3039f` 에서 읽었다. 재확인은 `8cc7dba8005c`·`62cd3a898b3f`·`e031f7ff990a` 에서 읽었다. 이 문서를 쓰며 `1157fd7b7b96` 에서 다시 봤다. 백틱으로 적은 저장소 경로 141개가 모두 있었다. 헌법 줄 번호도 맞춰 봤다. 근거 묶음과 계획 문서 경로는 이 셈에 넣지 않았다.
- `lib`·`bin` 좌표는 파일과 이름으로 적는다. 줄 번호는 근거 묶음 digest 의 `apply` 칸에 있다.

읽는 법:

- 절 제목 괄호 안의 이름(`karpathy` 등)은 주제 이름이다. 발견 ID 는 주제 이름과 번호를 이은 것이다. 예: `karpathy-01`. 절 안에서는 번호만 `01` 처럼 적는다.
- 「요구 N」 은 사용자가 처음 낸 요청 25개의 번호다. 목록은 계획 문서에 있다.
- 「결정 N」 은 사용자가 이미 정한 것 14개의 번호다. §15 머리에 요약했다.
- in_flight 는 다른 세션이 맡은 캠페인이라는 표시다. 이 문서는 그 일을 다시 제안하지 않는다.
- 표의 판정 칸은 재확인 결과다. 「맞음」 은 원문과 맞았다는 뜻이다. 「세게 말함」 은 원문보다 세게 말했다는 뜻이다. 「잘못 인용」 은 원문 문장과 다르게 옮겼다는 뜻이다. 「옛 버전」 은 더 새 버전이 있다는 뜻이다.
- 맞음이 아닌 발견은 원문에 맞게 고친 문장을 표에 넣었다. 원래 문장이 무엇을 틀렸는지는 표 아래 「고친 것」 에 적었다.
- 근거 종류는 다섯이다. 측정, 증명, 문서에 적힌 동작, 경험담, 의견. 문서에 적힌 동작은 제품 문서가 적은 동작이고 효과를 잰 것이 아니다.
- 출처 칸 끝의 「전문」·「일부」·「초록만」 은 조사자가 원문을 읽은 깊이다. 「사본」 은 원 주소가 막혀 같은 글의 사본으로 읽었다는 뜻이다.
- 표 아래 목록은 발견마다 수치와 조건, 「단서」, 「고친 것」, 「MASC 에서 쓰는 곳」 을 적는다. 단서는 판정이 맞음이어도 재확인이 덧붙인 한정이다.
- 「원문」 은 인용한 출처를 뜻한다. 이 문서의 절은 §1 처럼 적는다. 출처의 절은 「원문 §4.2」 나 「ImpossibleBench §5.1」 처럼 출처를 붙여 적는다.
- 바깥 저장소의 이슈·PR 번호에는 저장소 이름을 붙인다. 이름 없는 #N 은 MASC 의 이슈·PR 이다.
- 퍼센트포인트는 %p 로 적는다. 줄 범위는 「20~22행」 처럼 적는다.

## 0. 요약

- 평가를 고정한 루프가 개선을 쌓은 사례가 있다. autoresearch 는 5분짜리 고정 평가로 약 700개를 시도해 약 20개를 남겼다. nanochat 의 Time to GPT-2 는 2.02h 에서 1.65h 로 줄었다(nanochat README 20~22행, 본인 측정). 중간 값 1.80h 는 에이전트 루프가 잰 값이 아니다. 에이전트가 남긴 변경 약 20개를 사람이 depth=24 모델에 쌓아 쟀다. 큰 모델로 옮겨도 되는지도 사람이 확인했다. 과제를 풀기 전에 에이전트가 스스로 쓴 Skill 은 결과가 반대였다. 세 하네스 모두에서 통과율이 Skill 없는 기준선보다 8.1~11.5%p 낮았다(SkillsBench Table 6). (karpathy-01, observability-self-improvement-03)
- 에이전트가 늘자 막힌 곳은 사람 규모에 맞춘 개발 인프라였다. Anthropic 의 하루 병합은 2026-05 에 약 2,500건이었고 2026-09 에 30,000건을 넘었다. 원문은 병목을 'developer infrastructure built for human scale: source control, builds, and CI' 로 적는다. Anthropic 은 저장소 전체를 잠그는 직렬 병합 관문을 걷고 병합 뒤·배포 전 검사로 옮겼다(2026-10-13 글). 카파시는 사람의 검증을 병목으로 본다. MASC 에는 2시간에 PR 약 100개가 들어온다. (multi-agent-orchestration-02, karpathy-07)
- 여러 에이전트의 효과는 일의 모양에 따라 갈렸다. 단일 에이전트와 견준 평균 점수가 나눌 수 있는 금융 추론에서는 57~80.8% 높았다. 순서가 묶인 계획에서는 39~70% 낮았다(arXiv 2512.08296 Figure 2, 상대 변화). Anthropic 은 다중 에이전트가 같은 일에 토큰을 3~10배 쓴다고 적는다. 얻는 것은 속도보다 빠짐없음이라고 적는다. Cognition 은 2026-04 에 '쓰기는 한 줄로 두고 다른 에이전트는 판단을 보탠다' 로 입장을 좁혔다. (multi-agent-orchestration-07, multi-agent-orchestration-14, multi-agent-orchestration-01)
- 자동 판정은 그대로 두면 너그러웠다. 자동 채점을 통과한 AI PR 296건을 maintainer 4명이 봤다. maintainer 가 병합하겠다고 본 비율은 자동 채점 통과율보다 평균 24.2%p 낮았다(METR 2026-03-10 노트). LLM 판정자는 사람과의 일치율이 90% 를 넘어도 점수가 10점 넘게 어긋날 수 있다(Thakur 등 v6). 그래서 MASC Verifier 의 판정도 맞았는지 따로 센다. (observability-self-improvement-07, system12-hooks-proactive-06, multi-agent-orchestration-04)
- 그래프가 검색을 이겼는지는 방법마다 달랐다. HippoRAG 2 는 passage 를 가리키는 그래프로 recall@5 평균 78.2 를 내 dense 검색 73.4 를 넘었다(Table 3). 같은 표의 색인형 HippoRAG(재현)는 63.8 로 dense 아래다. 요약으로 corpus 를 넓힌 GraphRAG·LightRAG 는 질의응답(QA) F1 평균이 49.6·6.6 으로 dense 57.0 보다 낮다(Table 2). GraphRAG 는 passage 11,656개를 색인하는 데 입력 115.5M 토큰과 277분을 썼다. 같은 표의 HippoRAG 2 는 9.2M 토큰과 99.5분이다(HippoRAG 2 Table 12). 요구 21 의 「모든 것이 그래프」 는 이미 저장된 typed edge 를 읽는 projection 으로 만든다. 이 판단의 근거는 비용이 아니라 품질 결과다(§3 의 `01`·`02`·`04`). (memory-graph-01, memory-graph-14)
- 파일 I/O 바닥에 함정이 넷 있다. POSIX 잠금은 같은 프로세스가 descriptor 하나만 닫아도 모두 풀린다(XNU(macOS 커널) fcntl(2) 매뉴얼). ext4·XFS·Btrfs 는 fsync 가 실패해도 페이지를 clean 으로 표시한다(USENIX ATC 2020 논문 Table 1). macOS fsync 는 장치 캐시를 비우지 않는다. eio_posix 는 일반 파일 read·write 를 그 함수를 부른 OCaml 도메인에서 바로 실행한다. (storage-sync-01, storage-sync-02, storage-sync-03, storage-sync-10)
- Claude Code 내장 sandbox 는 셸 명령만 가둔다. Read 도구, hook, MCP(Model Context Protocol) 서버는 sandbox 밖에서 돈다. 다계정에서 `Native_none` 만 통과시키는 지금 판정은 Claude Code 문서와 맞는다. Apple `container` 문서는 중첩 가상화 조건을 M3 이상, macOS 15 이상, KVM(Linux 커널 가상화)을 켠 커널로 적는다. 이 Mac 에서 Kata·microsandbox 를 잴 길이 문서로는 열렸다. 아직 재지는 않았다. (sandbox-microvm-ssh-01, sandbox-microvm-ssh-06)
- 보상 문장은 성적을 대체로 바꾸지 못했다. 프롬프트에 넣은 팁·협박은 GPQA·MMLU-Pro 성적을 대체로 유의하게 바꾸지 않았다. 예외도 있다(MMLU-Pro 유의 차이 10건). o3 는 RE-Bench 시도 128번 중 39번(30.4%)에서 reward hacking 을 했다. METR 은 채점 함수 전체가 보였기 때문일 수 있다고 추정한다. 'Please do not cheat.' 를 덧붙여도 reward hacking 계획을 말한 비율은 80% 그대로였다(과제 하나, 조건마다 20회, 배포 전 o3). Candle 지급 규칙을 Keeper 에게 싣지 않는 결정 10 과 같은 방향이다. (agent-economy-09, agent-economy-03)
- 먼저 나서는 에이전트는 필요 없을 때 가만히 있지 못했다. 헛경보(false alarm) 비율이 GPT-4o 51.85%, Claude-3.5-Sonnet 54.63% 였다(Lu 등 Table 3). 꼭 필요할 때만 도우라는 지시를 줘도 그랬다(Lu 등 §4.2). 그래서 깨움은 신호 쪽에서 줄인다. Keeper 지시문은 고치지 않는다(결정 1). (system12-hooks-proactive-03)

근거가 서로 어긋나는 곳은 §13, 모르는 것은 §14 에 모았다. 사용자 결정과 부딪혀 쓰지 않은 것은 §15 에 모았다.

## 1. 안드레 카파시의 말 (`karpathy`)

안드레 카파시(Andrej Karpathy)의 글·발표·인터뷰에서 발견 14개를 뽑았다. 요구 25(똑똑한 사람의 이야기를 진지하게 받아들인다)에 답하는 절이다. 그의 평가는 몇 달 단위로 움직인다. 2026-03-09 에는 agent swarm 이 'going to work' 라고 썼다. 11일 뒤에는 자기 병렬 설계가 아직 마음에 들지 않는다고 말했다. 그래서 날짜를 주장과 같이 읽는다.

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` 평가를 고정하고 숫자 하나와 손댈 범위를 주면 에이전트 루프가 개선 후보를 쌓는다. autoresearch 1차는 약 700개를 시도해 약 20개를 남겼다. Time to GPT-2 는 2.02h 에서 1.80h, 2차 뒤 1.65h 로 줄었다. | 맞음 | 측정 | [X 2026-03-09 autoresearch 1차 결과 글](https://x.com/karpathy/status/2031135152349524125), karpathy/autoresearch README·program.md, nanochat README 20~22행, No Priors 24:05. 전문·사본 |
| `02` 신뢰도는 9를 하나씩 더하는 일이고, 9마다 드는 일이 비슷하다고 한다(march of nines). 90% 되는 데모는 첫 9일 뿐이다. | 맞음 | 경험담 | [Dwarkesh Patel 인터뷰 대본(2025-10-17)](https://www.dwarkesh.com/p/andrej-karpathy) 01:43:11~01:46:25(대본 P545~P547). 일부 |
| `03` 코딩 에이전트는 틀린 가정으로 내달리고, 묻지 않고, 반대하지 않고, 코드를 부풀린다고 썼다. CLAUDE.md 에 지시를 적는 간단한 시도를 몇 번 해도 그대로였다. 같은 글은 plan mode 에서 나아진다고 적는다. | 세게 말함 | 경험담 | [X 2026-01-26 글](https://x.com/karpathy/status/2015883857489522876). 전문·사본 |
| `04` LLM 판정자의 점수로 가중치를 강화학습하면, 오래 갈수록 판정자를 속이는 답이 나온다고 한다. 학습 step 10~20번은 버텨도 100~1,000번은 못 버틴다. | 맞음 | 경험담 | [Dwarkesh 대본](https://www.dwarkesh.com/p/andrej-karpathy) 00:45:29~00:48:22. 일부 |
| `05` 날짜가 찍힌 본인 글과 발표에서 평가가 움직였다. 2026-05-19 부터 Anthropic 직원이다. | 세게 말함 | 문서에 적힌 동작 | [X 2026-05-19 Anthropic 합류 글](https://x.com/karpathy/status/2056753169888334312)과 날짜가 찍힌 본인 글·발표 11건. 전문·사본 |
| `06` 에이전트 위에 조율·일정·맥락·지속을 맡는 층(Claws)이 생겼다고 본다. OpenClaw 의 400K 줄 코드에 개인 데이터와 열쇠를 맡기기는 꺼려진다고 한다. | 맞음 | 의견 | [X 2026-02-20 Claws 글](https://x.com/karpathy/status/2024987174077432126). 전문(뒷부분은 사본) |
| `07` 에이전트가 만들고 사람이 검증한다. 병목은 사람이다. GUI 로 검증을 빠르게 하고, 한 번에 내놓는 양을 사람이 검토할 수 있는 크기로 묶는다. | 맞음 | 의견 | [YC AI Startup School 발표 Software Is Changing (Again)](https://www.youtube.com/watch?v=LCEmiRjPEtQ) 19:53~25:31, Dwarkesh 대본 01:14:13. 전문 |
| `08` context engineering 은 다음 한 걸음에 맞는 정보로 context window 를 채우는 일이다. 모자라면 성능이 안 나오고, 넘치거나 무관하면 비용이 오르고 성능이 떨어질 수 있다. | 맞음 | 의견 | [X 2025-06-25 context engineering 글](https://x.com/karpathy/status/1937902205765607626). 전문 |
| `09` 제품에는 autonomy slider 가 있어야 한다. 모델은 기본값이 조금 지나치게 agentic 하다. 그래서 요청마다 의도와 무게를 알릴 방법이 필요하다. | 맞음 | 의견 | [X 2025-08-09 글](https://x.com/karpathy/status/1954224651443544436), YC 발표 18:22~21:24·27:34~28:35. 전문 |
| `10` 에이전트는 정보를 읽고 조작하는 새 사용자다. 문서는 markdown 으로, 조작은 CLI·API·MCP 로 낸다. 문서가 '클릭하라'고 하면 에이전트는 못 쓴다. | 맞음 | 의견 | [Sequoia Ascent 2026 정리 글](https://karpathy.bearblog.dev/sequoia-ascent-2026/) 그 글 10절, YC 발표 33:17~38:00. 전문 |
| `11` 합성 데이터로 학습하는 맥락에서, 한 모델에 같은 것을 되풀이해 물으면 답이 한곳으로 모인다고 한다('silently collapsed'). llm-council 은 서로의 답을 익명으로 심사시키고 의장 모델이 합친다. | 맞음 | 경험담 | [Dwarkesh 대본](https://www.dwarkesh.com/p/andrej-karpathy) 00:50:17~00:54:25, karpathy/llm-council README 9~11행. 일부 |
| `12` 지금 쓸 수 있는 기억은 글이라고 본다. 본인 wiki 는 약 100편, 40만 단어다. 자동 관리 index 파일과 짧은 요약으로 버텼고, 큰 질의용 검색 도구도 따로 만들었다. | 세게 말함 | 경험담 | [X 2026-04-02 LLM Knowledge Bases 글](https://x.com/karpathy/status/2039805659525644595), LLM Wiki gist, No Priors 32:17. 전문·사본 |
| `13` 연구 조직은 역할과 연결을 적은 markdown 파일 묶음으로 쓸 수 있다고 본다. 일은 큐 하나에서 worker 가 꺼내 시도하고, 되는 것만 feature branch 에 올린다. | 맞음 | 의견 | [No Priors(2026-03-20)](https://www.youtube.com/watch?v=kwSVtQ7dziU) 0:20:20~0:22:53. 전문 |
| `14` 만들기는 비싸고 확인은 싼 일이면, 믿지 못하는 worker 가 낸 결과도 받을 수 있다고 본다. 확인은 믿는 쪽 worker 가 한다. | 맞음 | 의견 | [No Priors(2026-03-20)](https://www.youtube.com/watch?v=kwSVtQ7dziU) 0:33:38~0:36:41. 전문 |

- `01` autoresearch 와 nanochat
  - 1.80h 는 에이전트 루프가 잰 값이 아니다. 에이전트가 남긴 변경 약 20개를 사람이 depth=24 모델에 쌓아 쟀다. 큰 모델로 옮겨도 되는지도 사람이 확인했다.
  - 단서: 한 사람, 한 저장소, 5분짜리 평가가 있는 학습 튜닝이다. 독립 재현은 찾지 못했다. 평가할 수 없는 일에는 안 통한다고 본인이 말한다(No Priors 24:05). x.com 은 402(결제 요구)로 막혀, 공식 embed 앞부분과 사본 한 곳으로 읽었다.
  - MASC 에서 쓰는 곳: Goal 의 metric·target_value(`lib/goal/goal_store.mli`), `Goal_measurement` 행(`lib/goal/goal_measurement.mli`), Verifier 증명(헌법 66행)이 이미 있다. Goal 마다 어떤 evidence(artifact·note·board·fusion)로 쟀는지 보여 주는 projection 하나를 더한다. 새 필드와 Gate 는 없다.
- `02` march of nines
  - 단서: Tesla 5년에 9 둘이나 셋을 지났다고 한다. 본인도 'maybe three nines or two nines. I don't know what it is' 로 흐리게 말했다. 9마다 같은 일이 든다는 말은 체감이고 수치 근거가 없다.
  - MASC 에서 쓰는 곳: Gate 2 는 54번 중 54번 성공이다(Keeper 18개 × 3턴, `docs/PRODUCTION-READINESS-GATES.md`). 여기서 나오는 턴 성공률의 95% 신뢰 하한은 0.946 이다. 조사자가 계산했고, 턴이 서로 독립이라고 가정해 낙관적이다. Gate 는 올리지 않는다. typed receipt 에서 성공 수·시도 수·하한을 runtime·tool 별 projection 으로 낸다.
- `03` 지시문으로 고치지 못한 버릇
  - 고친 것: 원래 문장은 'a few simple attempts' 와 plan mode 를 뺐다. 「만드는 능력과 가려내는 능력은 다르다」 는 본인 손코딩 이야기였는데 에이전트 이야기로 옮겼다.
  - MASC 에서 쓰는 곳: 결정 1(프롬프트 문장·강제 규칙 금지)을 받치는 경험담이다. 지시문을 공들여도 안 된다는 측정은 아니다. 고칠 자리는 검증 구조다. Task 의 `AwaitingVerification`(헌법 90행)과, `report_review_verdict` 로만 내는 판정(`lib/task/anti_rationalization.mli`)이 그 자리다. 더할 코드는 없다.
- `04` 판정자 점수 최적화
  - 단서: 「step」 은 학습 step 이다. 맥락 안에서 일하는 Keeper 로 옮긴 것은 조사자 해석이다. 뜻 없는 글자열이 100% 보상을 받은 예를 든다.
  - MASC 에서 쓰는 곳: 판정 점수를 Keeper 가 되풀이해 올리는 목표로 쓰지 않는 지금 구조를 둔다. 결정 10(지급 규칙 비공개)과 같은 방향이다. Candle 로 살 것을 넓히는 일은 헌법 candle 절을 고칠 때 따로 다룬다.
- `05` 날짜마다 움직인 평가
  - 2025-10-13: 'net unhelpful' 은 nanochat 저장소를 두고 한 답글이다. 'possibly the repo is too far off the data distribution' 이 붙는다.
  - 2026-01-26: 코딩의 80% 를 에이전트로 한다고 썼다. swarm 은 'too much for right now' 라고 했다.
  - 2026-02-25: orchestrator 층(Claws)을 가장 큰 기회('biggest prize')로 봤다.
  - 2026-03-09: agent swarm 이 'going to work' 라고 썼다.
  - 2026-03-20: 'I don't have something that I'm super happy with just yet' 는 본인 병렬 autoresearch 설계 이야기다.
  - 고친 것: 원래 문장은 이 기간을 「13달」 이라 했다. 2025-10-13 답글에서 2026-03-20 까지 158일, 2026-05-19 까지 218일이다. 두 발언의 한정도 뺐다.
  - 단서: 퇴사 보도는 찾지 못했다. 2026-06-09~10-31 X 글은 훑지 못했다.
  - MASC 에서 쓰는 곳: 코드보다 문서 습관에 쓴다. docs/research 와 RFC 에 그의 주장을 옮길 때 날짜·근거 종류·소속을 같이 적는다. 원문 URL 없는 인용은 버린다.
- `06` Claws 층
  - 단서: 꺼림은 OpenClaw 에 한정된다. 줄 수와 함께 'vibe coded', 'actively attacked at scale' 을 이유로 든다. 위험으로는 노출된 인스턴스, RCE(원격 코드 실행), 공급망, 악성 skill 을 든다. 약 4,000줄 core 와 기본 컨테이너 격리(NanoClaw)는 'on a quick skim' 으로 좋게 본다. 400K·4,000 은 그가 든 어림수다.
  - MASC 에서 쓰는 곳: `lib`·`bin` 은 1,357,332줄이다(조사 때 측정). 쓸 곳은 셋이다. 첫째, microVM·RemoteSSH 를 기본 격리로 둔다(결정 13). 둘째, 밖에서 오는 Skill·MCP 서버의 출처 digest 를 기록하고 보여 준다. builtin 은 SHA-256 이 이미 있다(`lib/server/builtin_skill_revision.mli`). 셋째, 비밀값·권한 모듈을 한 번 세어 지도로 남긴다. 로드를 거절하게 만들면 §15.2 와 부딪힌다.
- `07` 사람이 병목
  - 원문 표현은 'keep the AI on the leash' 다. 「코드 밖 산출물은 diff 를 보일 도구부터 만들어야 한다」 의 근거 'Someone has to build it' 은 Dwarkesh 대본 01:14:13 에 있다. YC 발표에는 'what does a diff look like in Photoshop' 이라는 질문만 있다.
  - 단서: YC 자막 내려받기가 429(요청 수 제한)로 막혔다. 독립 대본과 자동 자막으로 확인했다.
  - MASC 에서 쓰는 곳: Keeper 수를 늘리기 전에 사람 확인 한 건에 드는 시간을 줄인다. 후보는 wiki·Artifact 변경을 보여 주는 화면이다. 사람 확인을 기다리는 일의 건수·기다린 시간을 보여 주는 projection 도 후보다. `dashboard/src` 의 ts·tsx 파일 1,758개 가운데 wiki 를 다루는 파일은 0개다. TUI 화면 문법(#51624)은 in_flight 다.
- `08` context engineering
  - 단서: LLM 은 CPU, context window 는 memory 라는 비유는 이 글에 없다. YC 발표 10:15 에 있다.
  - MASC 에서 쓰는 곳: 이미 타입으로 있다. layer 22개와 `ordered`, `resend_on_resume`, `receipt_to_json` 이다(`lib/keeper/keeper_context_layers.mli`). 넘치는 쪽 수치는 glossary 447,081 bytes(36일에 1.5배)와 docs 2,612개다. Draft glossary RFC 의 근거로 덧붙인다. layer 별 byte 통계로 문턱값을 만들지 않는다(결정 3).
- `09` autonomy slider
  - 단서: 원문은 'a little too agentic by default, a little beyond my average use case' 다. 알릴 범위는 'just have a quick look' 에서 'go off for 30 minutes, come back when absolutely certain' 까지다.
  - MASC 에서 쓰는 곳: Keeper 단위 조절 값은 있다(`lib/keeper/keeper_activation_mode.mli`, `lib/keeper/keeper_lifecycle_gate.mli`). 요청 단위 깊이는 provider 별 타입뿐이다(`lib/runtime/runtime_antigravity.mli`, `lib/runtime/runtime_muse_msp.mli`). System One·Two 설계에서는 깊이를 요청자가 선언한 값으로 받아 provider effort 로 내린다. turn·time·token 상한으로 내리면 §15.2 와 부딪힌다.
- `10` 에이전트라는 새 사용자
  - 그가 든 2026 목록은 structured logs, schema, 복사해 붙일 지시문, 안전한 권한, 나중에 따져 볼 수 있는 행동 기록이다.
  - 단서: 그 글은 Codex 5.5 가 만든 요약을 본인이 읽고 올린 것이다.
  - MASC 에서 쓰는 곳: MCP resource(`config/mcp/resources.toml`)와 tool 정의 225개가 이미 있다. 셀 것은 하나다. Dashboard·TUI 의 쓰기 조작 가운데 MCP tool·CLI 로 못 하는 것의 수를 한 번 센다(목표 0). CI 검사로 만들지 않는다.
- `11` 같은 답으로 모이는 모델
  - 단서: 열 번 물으면 다 같고 농담은 셋뿐이라고 한다. llm-council README 15행은 '99% vibe coded' 라 적고 효과를 재지 않았다.
  - MASC 에서 쓰는 곳: Fusion 자리는 후보를 차례로 시도해 답한 runtime 을 남긴다(`lib/fusion/fusion_seat.mli`). 모든 자리가 한 runtime 으로 모인 run 을 projection 에서 따로 표시한다. 서로 다른 모델을 강제하지 않는다.
- `12` 글로 된 기억
  - 가중치로 옮기는 길은 'further explorations', 'not a fully developed science' 라고 한다.
  - 고친 것: 원래 문장은 「index 파일만으로 버텼다」 고 적었다.
  - MASC 에서 쓰는 곳: wiki·index·log·lint 는 RFC 셋이 이미 반영했다. 더할 것은 사실 기록뿐이다. 지금 운영 중인 wiki 는 항목 22개라 index 로 버티는 범위 안이고, `masc_wiki_search` 가 있다. librarian SFT(지도 미세조정) 학습 단계를 닫은 결정과도 어긋나지 않는다.
- `13` markdown 으로 쓰는 조직
  - 단서: 독립 대본 20:15~22:26 으로 확인했다. 원문 낱말은 'research organization' 이다. 지시문 묶음을 최적화한다는 말은 'you can imagine' 으로 말한 구상이고 결과는 없다.
  - MASC 에서 쓰는 곳: 요구 14·15 에 닿는다. 세계관 묶음의 단위를 역할·연결을 적은 text 파일 묶음(`config/prompts/keeper.md`, Keeper 별 TOML)으로 잡는다. 묶음을 바꿔 끼우는 기능은 고정된 비교 측정과 같이 낸다. 묶음에 금지·필수 규칙을 넣지 않는다(결정 1).
- `14` 믿지 못하는 worker
  - 단서: 독립 대본 33:48~35:44 에서 'sketchy and dodgy' 를 확인했다. 남이 보낸 코드를 그냥 돌리는 일을 두고 한 말이다. 본인도 만족하는 설계가 아직 없고, 확인에도 'a lot of work' 가 든다고 덧붙였다.
  - MASC 에서 쓰는 곳: 다계정·RemoteSSH 에서 남이 낸 결과를 받을지 운영자가 판단하는 기준으로 쓴다. 확인이 생산보다 훨씬 쌀 때만 받고, 아니면 믿는 lane 에서 다시 한다. 코드를 돌려 확인할 때는 격리 안에서 한다(`lib/exec/sandbox_target.mli`). 런타임 수락 규칙으로 만들면 §15.2 와 부딪힌다. 다계정 권한(authz S1b, #51635, #51604)은 in_flight 다.

적용하지 않는 것:

- NanoClaw 식으로 설정 파일 대신 Skill 이 코드를 고치게 하고, fork 하기 쉬운 저장소로 만들기. 요구 15(설정은 TOML·Markdown 으로 뺀다)와 헌법 success_bar 에 어긋난다. 여러 사람이 쓰는 서버는 사람마다 fork 할 수 없다.
- wiki 로 합성 데이터를 만들어 fine-tuning 하거나 강화학습(RL) 환경을 만들기. MASC 는 Provider·Model Free 하네스다(헌법 19행). librarian SFT 학습 단계는 닫혔다. 그도 아직 덜 자란 분야라고 한다.
- 카파시가 한 날에 한 말을 agent swarm 이 된다거나 안 된다는 근거로 인용하기. 2026-01-26 에는 swarm 을 'too much for right now' 라고 했다. 2026-03-09 에는 swarm 이 'going to work' 라고 썼다. 2026-03-20 에는 자기 병렬 설계가 아직 마음에 들지 않는다고 했다. 평가가 날짜마다 바뀌어 한 날의 말을 근거로 쓰지 않는다.
- 2025-10 의 「autocomplete 가 최적」 을 근거로 Keeper 자율을 줄이기. 본인이 2026-01 에 코딩의 80% 를 에이전트로 한다고 뒤집은 옛 주장이다.
- 저장소에 llms.txt 를 그대로 더하기. llms.txt 는 웹 문서를 긁어 읽는 LLM 용 관례다. MASC 에 붙는 에이전트는 MCP resource 와 `masc://tool-help-index` 로 들어온다. 이득을 잰 자료도 없다.
- Fusion 자리에 서로 다른 모델을 강제하기. 헌법 190행(수치 cap 없음)과 failover 를 깬다. 섞으면 낫다는 측정도 없다.
- Gate 2 의 54번 중 54번 성공을 9 둘·셋 수준으로 올리기. 실패 없이 95% 신뢰로 9 둘을 보이려면 299번, 셋은 2,995번이 든다. 운영 receipt 를 표본으로 쓰는 projection 이 맞다.
- 사용자 결정 때문에 뺀 9건은 §15.1 에 있다.

## 2. 여러 에이전트 조율 (`multi-agent-orchestration`)

에이전트 여럿을 한 저장소에 붙인 회사들의 2026년 보고와 논문에서 발견 14개를 뽑았다. 요구 1·3·16·22·23 에 닿는다. Cursor 는 에이전트에게 남의 일을 기다리는 도구를 줬지만 에이전트는 거의 쓰지 않았다(`03`). Cursor 의 마지막 설계는 끝난 일을 시스템이 일을 낸 쪽에 넣는다. Cognition 은 쓰기를 에이전트 하나에 두는 쪽으로 입장을 좁혔다(`01`).

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` Cognition 은 2025년 '다중 에이전트를 만들지 말라'에서 2026년 '쓰기는 한 줄로 두고 다른 에이전트는 판단을 보탠다'로 입장을 좁혔다. | 맞음 | 경험담 | [Multi-Agents: What's Actually Working (Cognition, 2026-04-22)](https://cognition.ai/blog/multi-agents-working). 전문 |
| `02` Anthropic 은 하루 병합이 약 2,500건에서 30,000건 이상으로 늘자 병목을 사람 규모에 맞춘 개발 인프라로 적었다. 저장소 전체를 잠그는 직렬 병합 관문을 걷고 병합 뒤·배포 전 검사로 옮겼다. | 맞음 | 경험담 | [Redesigning source control at Anthropic (2026-10-13)](https://www.anthropic.com/research/redesigning-source-control). 전문 |
| `03` Cursor 는 에이전트에게 남의 일을 기다리는 도구를 줬지만 'they rarely used it' 였다. 마지막 설계는 worker 가 쓴 handoff 를 시스템이 일을 낸 planner 에게 후속 메시지로 넣는다. | 맞음 | 경험담 | [Towards self-driving codebases (Cursor, 2026-02-05)](https://cursor.com/blog/self-driving-codebases). 전문 |
| `04` Anthropic 은 판정자가 기본 상태로 너그럽다고 적는다('Out of the box, Claude is a poor QA agent'). 판정자를 사람 판단에 맞추는 일을 여러 번 했다. | 맞음 | 경험담 | [Harness design for long-running apps (Anthropic, 2026-03-24)](https://www.anthropic.com/engineering/harness-design-long-running-apps), Project Vend: Phase two(2025-12-18). 전문 |
| `05` 위아래 없이 같은 자격으로 일하는 에이전트들에게 공유 잠금을 준 설계는 실패했다. 잠금이 제대로 돌아도 기다림 탓에 20개가 2~3개 몫의 처리량으로 떨어졌다. | 잘못 인용 | 경험담 | [Scaling long-running autonomous coding (Cursor, 2026-01-14)](https://cursor.com/blog/scaling-agents). 전문 |
| `06` MAST 는 실패 모드 14개를 나눈다. 반복 15.7%, 추론·행동 어긋남 13.2%, 끝낼 조건 모름 12.4% 가 크다. | 맞음 | 측정 | [Why Do Multi-Agent LLM Systems Fail? (arXiv 2503.13657v3)](https://arxiv.org/html/2503.13657v3). 일부 |
| `07` 다중 구조의 효과는 일의 모양에 달렸다. 단일 에이전트 평균과 견주면 나눌 수 있는 금융 추론은 57~80.8% 높았다. 순서가 묶인 계획은 39~70%, SWE-bench Verified 는 2~15% 낮았다(Figure 2, 상대 변화). | 세게 말함 | 측정 | [Towards a Science of Scaling Agent Systems (arXiv 2512.08296v3)](https://arxiv.org/html/2512.08296). 일부 |
| `08` A2A(Agent2Agent) 프로토콜 1.0.0 은 2026-03-12 에 나왔다. `/.well-known/agent-card.json` 은 AgentCard 를 돌려줘야 한다(MUST). | 맞음 | 문서에 적힌 동작 | [A2A Protocol Specification 1.0](https://a2a-protocol.org/latest/specification/) 규격 §4.4.1·§8.2·§14.3. 일부 |
| `09` MCP 는 2026-11-12 에도 2026-07-28 버전이 current 다. Tasks 는 확장 `io.modelcontextprotocol/tasks` 로 빠졌고, 기본은 되읽기(`tasks/get`)다. 서버 알림은 `notifications/tasks` 로 확장에 이미 있다. | 잘못 인용 | 문서에 적힌 동작 | [MCP Tasks extension overview](https://modelcontextprotocol.io/extensions/tasks/overview.md), roadmap(2026-08-22), extension support matrix. 전문 |
| `10` Anthropic 은 조정 패턴 다섯과 각 패턴의 실패를 적는다. message bus 는 라우터가 잘못 분류하면 'fails silently' 한다. shared state 에는 서로 반응하는 고리가 생긴다. | 맞음 | 경험담 | [Multi-agent coordination patterns (Anthropic, 2026-04-10)](https://claude.com/blog/multi-agent-coordination-patterns). 전문 |
| `11` Claude Code agent teams 문서는 한계를 적는다. 팀원이 끝낸 일을 표시하지 않아 의존하는 일이 막힌다('Task status can lag'). 같은 파일을 둘이 고치면 덮어쓴다. | 맞음 | 문서에 적힌 동작 | [Claude Code docs: agent teams](https://code.claude.com/docs/en/agent-teams.md). 전문 |
| `12` 오래 돈 실행이 결과를 낸 사례는 기계가 판정하는 성공 기준을 가졌다. 에이전트 16개가 10만 줄 C 컴파일러를 만들었고, GCC 를 정답 기준으로 일을 쪼갰다. | 맞음 | 경험담 | [Building a C compiler with parallel Claudes (Anthropic, 2026-02-05)](https://www.anthropic.com/engineering/building-c-compiler). 전문 |
| `13` Steve Yegge 는 Gas Town 이 Opus 4.6 까지 잘 돌다가 4.7 에서 'fell apart at the seams' 했다고 적는다. Anthropic 도 모델이 바뀌자 sprint 구성과 context reset 을 뺐다. AutoGen 은 보관됐다. | 맞음 | 경험담 | [The Shape of Things to Come, Part 1 (Steve Yegge, 2026-08)](https://yegge.ai/essays/the-shape-of-things-to-come/), Anthropic 하네스 글 둘, AutoGen README. 전문 |
| `14` Anthropic 은 다중 에이전트가 같은 일에 토큰을 3~10배 쓴다고 적는다. 얻는 것은 속도보다 빠짐없음이라고 적는다. | 맞음 | 경험담 | [Building multi-agent systems: When and how to use them (Anthropic, 2026-01-23)](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them). 전문 |

- `01` Cognition 의 입장 변화
  - 맥락을 미리 나누지 않은 리뷰어가 PR 당 평균 2개 버그를 잡는다. 그중 약 58% 가 심각하다고 적는다.
  - 단서: Devin 이 낸 PR 에 대한 자사 수치다. 표본과 기간이 없고, 독립 검증도 없다.
  - MASC 에서 쓰는 곳: Task claim(헌법 88~89행)과 독립 리뷰(일반 PR 은 헌법 374~375행)가 이미 같은 모양이다. 새 장치는 없다. Keeper 사이 소통은 리뷰·반론·조언 자리에 두고, 결과물 쓰기는 claim 한 Keeper 하나가 한다.
- `02` 사람 규모 인프라
  - 하루 병합은 2026-05 에 약 2,500건, 2026-09 에 30,000건 이상이다. 원문은 병목을 'developer infrastructure built for human scale: source control, builds, and CI' 로 적는다. 걷은 것은 'a global repository lock on the merge queue' 다.
  - Steve Yegge 는 에이전트 40개 이상을 돌리자 병합 대기열이 100건을 넘었다고 적는다. 빌드는 약 30분 걸렸다.
  - 단서: 글에 에이전트 수는 없다. CI 를 줄였다는 말도 없다. CI 용 checkout 은 하루 약 2,500만 번이다('on the order of 25 million code checkouts per day for CI'). Stripe 는 push 마다 CI 를 돌리고 횟수만 두 번으로 묶는다.
  - MASC 에서 쓰는 곳: 병합 뒤·배포 전 검사로 옮긴 사례다. 결정 6 을 직접 받치지는 않는다. 「PR push 로 CI 를 시작하지 않는다」 는 이 글에서 나오지 않는다. 새 제안은 없다. 스택당 CI 한 번(RFC #51521)은 in_flight 다. main 빌드가 실패하면 `main-health` 이슈 하나에 모인다(`.github/workflows/main-minimal-build.yml`).
- `03` 쓰이지 않은 기다림 도구
  - MASC 에서 쓰는 곳: MASC 는 이미 `Delegate_completed`·`Composition_completed`·`Task_outcome` 을 일을 낸 쪽 큐에 넣는다(`lib/keeper_runtime/keeper_event_queue.mli`). 같은 파일 주석에 자체 측정이 있다. 위임 4건 중 상태를 읽은 것은 0건, 제출 22건 중 읽은 것은 12건이다(2026-08 한 주). 바깥 기다림은 in_flight(#51381, #51606)다.
- `04` 너그러운 판정자
  - Project Vend 의 CEO 에이전트 Seymour 는 요청을 거절보다 약 8배 자주 승인했다('authorized such requests about eight times as often as it denied them').
  - 단서: Seymour 는 재무 승인자이고 QA 판정자가 아니다. 한 사람의 실험과 한 매장의 값이다. 같은 계열 리뷰어에 대해 Cognition(`01`)은 반대로 보고한다.
  - MASC 에서 쓰는 곳: `Eval_calibration` 원장이 `generator_runtime`·`evaluator_runtime` 과 사람 라벨을 적는다(`lib/eval_calibration.mli`). runtime 쌍마다 승인·거절 수와 사람과의 어긋남을 세는 projection 을 만든다. 새 필드와 Gate 는 없다. `generator_runtime` 은 option 이고, 쌓인 사람 라벨 수는 확인 필요다.
- `05` 공유 잠금의 실패
  - 에이전트가 잠금을 오래 쥐거나 풀기를 잊었다. 품질을 맡긴 중앙 통합자도 병목이라 뺐다.
  - 고친 것: 원래 문장은 처리량이 떨어진 원인을 잠금 오용으로 적었다. 원문은 'Even when locking worked correctly, it became a bottleneck' 뒤에 20개가 2~3개 몫으로 떨어졌다고 적는다.
  - 단서: 뒤이은 낙관적 동시성을 원문은 'simpler and more robust' 라 적는다. 결과물 품질은 2차 자료(The Register)가 빌드 실패를 전한다.
  - MASC 에서 쓰는 곳: 요구 1 의 잠금 기준이다. 모델이 잡고 풀어야 하는 잠금을 만들지 않는다. 시스템이 짧게 쥐는 claim 버전 검사만 둔다. 시스템이 쥐는 `review_slots` 세마포어(헌법 111행)는 이 기준 밖이다. 오래 잡힌 claim 은 만료시키지 않는다(헌법 120~123행이 금지). 대신 projection 으로 보여 준다(in_flight).
- `06` MAST 실패 분류
  - 분류는 실행 기록 150개로 만들었다. 1,642개는 o1 이 자동으로 라벨을 붙였다. 자동 라벨과 사람의 일치도는 Cohen's κ 0.77(정확도 94%)이고, 사람끼리는 κ 0.88 이다.
  - 단서: 검증 실패는 성공한 실행에도 나온다('appear frequently even in successful runs'). 대상은 2024~25년 초 모델과 벤치마크 과제다.
  - MASC 에서 쓰는 곳: Keeper 턴 journal 표본에 MAST 어휘로 사후 라벨을 붙인다. 먼저 사람 라벨로 일치도를 잰다. 요구 12 의 되먹임 자료다. 실행 중 중단 근거로 쓰지 않는다(헌법 450행).
- `07` 일의 모양과 다중 구조
  - Figure 2 의 값은 다중 구조 평균이 단일 에이전트 평균보다 몇 % 높거나 낮은지다. Finance Agent 에서 중앙 구조는 0.631, 단일 에이전트는 0.349 였다.
  - 논문이 'trace-level error amplification' 이라 부르는 값은 독립 구조 17.2배, 중앙 구조 4.4배다. 이 값은 조정 실패로 늘어난 계산량이고 오류율 배수가 아니다. 과제 수준 오류율 비는 약 1.1~1.3 이고, 통제 뒤 유의하지 않다(p=0.658).
  - 고친 것: 원래 문장은 17.2배·4.4배를 오류 배수로 적었다.
  - 단서: SWE-bench 칸은 20문항이고, 칸마다 95% 신뢰구간이 약 ±20%p 다. 계산 예산을 고정했고 에이전트는 9개까지만 봤다.
  - MASC 에서 쓰는 곳: Lane·Keeper 를 늘릴 때(헌법 514행) Goal 별 조정 몫(메시지 수, 기다린 시간, 다시 한 횟수)을 projection 으로 본다. 문턱값으로 쓰지 않는다. runtime 을 섞은 구성은 조합별로 잰다.
- `08` A2A AgentCard
  - 필수 필드는 name, description, supportedInterfaces, version, capabilities, defaultInputModes, defaultOutputModes, skills 다.
  - 단서: v1.0.0 은 2026-03-12T16:34:41Z 이고 v1.0.1 은 버그 수정이다.
  - MASC 에서 쓰는 곳: MASC 가 내는 agent card 는 A2A 1.0 의 AgentCard 가 아니라 자체 형식이고 필수 필드 넷이 없다. 공개 범위의 세부와 좌표는 수리 뒤 싣는다. A2A 경로를 어떻게 할지는 사용자가 정한다. 정석과 대가는 §15.2 에 있다.
- `09` MCP Tasks
  - webhook 을 포함한 push 전달은 로드맵(2026-08-22)에 있다. 서버 알림은 `subscriptions/listen` 위에 실린다. 지원 표의 클라이언트 17개 중 4개가 Tasks 를 지원한다.
  - 고친 것: 원래 문장은 서버 알림 전체를 로드맵 단계로 적었다.
  - 단서: 지원 표는 커뮤니티가 관리한다. 로드맵은 약속이 아니다.
  - MASC 에서 쓰는 곳: MASC 클라이언트는 `complete`·`input_required` 밖의 resultType 을 거절한다(`lib/mcp_client/mcp_client.ml`). 확장을 선언하지 않았으니 규격과 맞다. MASC 서버는 `subscriptions/listen` 을 이미 구현한다(`lib/mcp_transport_protocol/mcp_subscriptions.ml`).
  - 정석과 대가: multi-agent-orchestration 보고서 4.8절의 정석은 지금 들이지 않는 것이다. 바깥 서버가 task 를 내놓기 시작하면 클라이언트 쪽을 구현한다. 근거는 Tasks 가 확장이고, 코어로 들어가는 일이 로드맵에 있다는 것이다. 대가는 그때까지 오래 걸리는 바깥 도구가 동기 호출로 남는 것이다. 다른 길은 서버 쪽 구현이다. 새 서버 표면과 task 저장이 들고, 지원 클라이언트는 17개 중 4개다. 요구 13(MCP 확장 Fully Support)과 맞서는 선택이라 사용자가 정한다. §15.2 의 `multi-agent-orchestration-08` 항목에 같이 적었다.
- `10` 조정 패턴 다섯
  - 고리를 끝내는 방법으로 시간 예산, N 주기 수렴, 전담 판정자를 든다.
  - 단서: 원문의 전담 판정자는 답이 충분한지 정한다. Board 판정은 보낼 곳을 정한다. MASC 가 이미 그 모양이라는 말은 해석이다.
  - MASC 에서 쓰는 곳: Board 관련성 판정(`lib/keeper/keeper_board_attention_candidate.mli`)이 그 라우터에 해당한다. `Not_relevant` 표본을 다시 판정해 어긋남을 센다. 시간·횟수 종료는 헌법이 막아 전담 판정자만 남는다. MASC 판정 기록에서 표본을 뽑을 수 있는지는 확인 필요다.
- `11` agent teams 의 한계
  - 팀원은 사람 대신 승인할 수 없다('can't approve ... on your behalf').
  - 단서: 'untrusted input' 은 auto mode 분류기 검사에 붙은 말이다. 실험 기능이고 기본은 꺼져 있다.
  - MASC 에서 쓰는 곳: dependency 를 scheduling Gate 로 쓰지 않는다는 결정을 받친다. Keeper 사이 요청은 일반 메시지라는 결정(결정 2)도 받친다. 팀원이 멈추면 lead 에 자동으로 알리는 모양은 `Delegate_completed` 와 같다.
- `12` C 컴파일러
  - 에이전트 16개가 약 2주 동안 세션 약 2,000개와 $20,000 조금 못 미치는 돈을 썼다.
  - 단서: 같은 버그로 서로 덮어쓴 일도 원문에 있다. 단일 에이전트와 견준 값은 없다. Cognition 은 실제 소프트웨어 대부분에 이런 기준이 없다고 적는다.
  - MASC 에서 쓰는 곳: Goal 은 정량 성공 조건을 요구한다(헌법 57~58행). 바깥 근거가 이 규칙을 받친다. 큰 과제 하나에 16개가 같은 버그로 몰린 사례는 Task 를 서로 독립이 되게 쪼개는 근거다.
- `13` 모델이 바뀌면 무너지는 하네스
  - Yegge 는 그 뒤 다시 쓸 하네스 만들기를 그만뒀다.
  - 단서: 셋의 원인은 다르다(모델 버릇, 모델 개선, 제품 이전). 무너진 원인을 따로 검증한 자료는 없다.
  - MASC 에서 쓰는 곳: runtime·모델 버전이 바뀌면 약점을 메우던 부품 하나를 고른다. 그 부품을 넣은 쪽과 뺀 쪽에 같은 과제 묶음을 돌린다. 그 결과가 정리 변경의 품질 근거가 된다(결정 9). runtime 별로 본다.
- `14` 토큰 3~10배
  - 원문 표현은 'thoroughness, not speed' 다. 일을 종류(구현, 시험, 리뷰)로 나누면 넘길 때마다 맥락을 잃는다. 그래서 맥락 경계로 나누라고 권한다.
  - 단서: 같은 글은 검증 subagent 가 잘 된다고 적는다. 자사 시험이라고만 적고 방법은 공개하지 않았다.
  - MASC 에서 쓰는 곳: 일부 stimulus 는 이미 pointer 만 싣는다(`Owned_job_completed`·`Task_outcome`, `lib/keeper_runtime/keeper_event_queue.mli`). 모든 stimulus 가 그렇지는 않다. 토큰 배수는 요구 12 의 관측 값으로만 쓰고 한도로 쓰지 않는다.

적용하지 않는 것:

- 일을 나눠 주고 감독하는 상시 관리자·CEO Keeper 나 Goal 소유자. Goal 은 소유자를 두지 않는다(헌법 55~56행). Vend 의 CEO 에이전트는 도움이 안 됐고, Cognition 의 관리자 에이전트는 지나치게 세세했다. 끝나면 일을 낸 쪽에 넣는 전달 모양만 쓰고, 그 모양은 이미 있다.
- 중앙 통합자, 저장소 전체 잠금을 쥔 병합 대기열, 커밋마다 100% 정확 요구. Cursor 는 중앙 통합자를 병목이라 뺐다. Anthropic 은 저장소 전체 잠금을 걷었다. 결정 6 과도 어긋난다.
- 대기열이 차면 전부를 main 에 넣고 나중에 고치기(Yegge 의 Land Rush), 사람 리뷰 없애기. 헌법은 현재 head 에 대한 독립 승인을 요구한다(374~397행). 한 사람의 보고다. 「내년이면 사람 리뷰가 필요 없어진다」 는 말은 예측이다.
- 서로 협상하는 떼(swarm)에게 쓰기를 맡기기. Cognition 은 'mostly a distraction' 이라 적었다. Cursor 의 수평 설계(`05`)는 실패했다.
- 계정 여럿을 돌려 쓰는 한도 우회(Yegge). 그 스스로 회사가 하면 약관 위반일 것이라고 적는다. 다계정 결정과 다른 문제다.
- 자체 버전 관리 시스템(Anthropic 의 Scion). 글 스스로 아주 큰 monorepo 밖에서는 맞지 않는다고 적는다. 가져올 것은 병합 뒤 검사라는 방향뿐이다.
- 「production 다중 에이전트 시스템의 41~87% 가 실패한다」 는 문장(arXiv 2605.03310 초록). MAST 의 벤치마크 실패율(41~86.7%)을 운영 실패율로 잘못 옮긴 것이다.
- 사용자 결정 때문에 뺀 5건은 §15.1 에 있다.

## 3. 기억과 그래프 (`memory-graph`)

에이전트 기억과 지식 그래프(KG)의 논문·벤치마크·제품 문서에서 발견 14개를 뽑았다. 요구 1·21·22 에 닿는다. 이 주제는 원문보다 세게 말한 발견이 여섯으로 가장 많다. 「그래프가 이긴다」 는 문장은 발견마다 좁혀 읽어야 했다. 논문들이 견준 것은 검색을 돕는 KG 와 corpus 를 넓히는 KG 다.

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` HippoRAG 2 는 passage 를 가리키는 그래프로 recall@5 평균 78.2 를 내 dense 검색(NV-Embed-v2) 73.4 를 넘었다. 같은 표의 색인형 HippoRAG(재현)는 63.8 로 dense 아래다. | 세게 말함 | 측정 | [From RAG to Memory: Non-Parametric Continual Learning for LLMs (HippoRAG 2, arXiv 2502.14802v2)](https://arxiv.org/abs/2502.14802) Table 2·3·4, 원문 §2. 일부 |
| `02` 질문 종류가 갈림 조건이다. GraphRAG-Bench 의 Novel 자료에서 Fact 질문은 RAG w/ rerank 가, Complex 질문은 HippoRAG 2 가 가장 높았다. | 맞음 | 측정 | [When to use Graphs in RAG (GraphRAG-Bench, arXiv 2506.05690v3)](https://arxiv.org/abs/2506.05690) Table 2, Obs.1·Obs.2. 일부 |
| `03` 여러 세션 에이전트 과제에서 구조 기억은 긴 맥락과 단순 검색을 꾸준히 넘지 못했다('does not consistently outperform'). 성공률은 모두 0.2 이하다. | 세게 말함 | 측정 | [MemoryArena (arXiv 2602.16313v2)](https://arxiv.org/abs/2602.16313) Table 3, 원문 §4.3·§4.4. 일부 |
| `04` 작업 궤적 기억에서는 LLM 이 뽑은 인과 그래프에 도구 검색을 붙인 AMA-Agent 가 가장 높았다(평균 ACC 0.5722). 유사도 edge 를 가진 HippoRAG 2 0.4480 도 BM25 0.3436 위였다. | 세게 말함 | 측정 | [AMA-Bench (arXiv 2602.22769, v4)](https://arxiv.org/abs/2602.22769) Table 5·7. 일부 |
| `05` Zep 은 edge 마다 시각 넷을 두고, 옛 사실을 지우지 않고 무효로 표시한다. LongMemEval_s 에서 gpt-4o 의 temporal 점수는 45.1 에서 62.4 로 올랐다. | 세게 말함 | 측정 | [Zep: A Temporal Knowledge Graph Architecture for Agent Memory (arXiv 2501.13956v1)](https://arxiv.org/abs/2501.13956) Zep §2.2.3, Table 2·3. 일부 |
| `06` Claude Managed Agents memory 문서는 content hash 조건부 쓰기와 불변 version 을 API 선택 기능으로 둔다. self-hosted sync 문서는 충돌 때 store 쪽을 남기고 에이전트에게 오류를 주지 않는다. | 맞음 | 문서에 적힌 동작 | [Memory stores in self-hosted sandboxes (Claude Managed Agents docs)](https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes-memory), managed-agents/memory 문서, CodeCRDT. 전문 |
| `07` LLM 에이전트에게 abort 뒤 재시도는 비싸다. 직렬 실행과 견주면 OCC(낙관적 동시성 제어)는 속도 0.93배·토큰 1.83배였다. | 세게 말함 | 측정 | [CoAgent: Concurrency Control for Multi-Agent Systems (arXiv 2606.15376v1)](https://arxiv.org/abs/2606.15376) 서론, CoAgent §5.2·§7.2. 일부 |
| `08` 기억 시스템의 쓰기 경로를 단계별로 재면 추출과 갱신이 먼저 무너진다. HaluMem 에서 MemOS 를 뺀 모든 시스템의 추출 recall 이 60% 아래였다. | 맞음 | 측정 | [HaluMem: Evaluating Hallucinations in Memory Systems of Agents (arXiv 2511.03506v3)](https://arxiv.org/abs/2511.03506) Table 3, 초록. 일부 |
| `09` LightMem 은 offline 'sleep-time' 통합이 정보 손실을 줄인다고 주장한다. 그러나 offline 갱신 뒤 LongMemEval_s 정확도는 표의 여섯 쌍 중 넷에서 내렸다. | 세게 말함 | 측정 | [LightMem: Lightweight and Efficient Memory-Augmented Generation (arXiv 2510.18866v4)](https://arxiv.org/abs/2510.18866) Table 2, LightMem §5.6, 서론. 일부 |
| `10` locomo-audit 은 LoCoMo 1,540문항 중 99개(6.4%)의 정답이 틀렸다고 적는다. 너그러운 판정자는 일부러 틀리게 쓴 모호한 답의 62.81% 를 통과시켰다. | 맞음 | 측정 | [locomo-audit (README, AUDIT_REPORT.md)](https://github.com/dial481/locomo-audit). 일부 |
| `11` 기억 도구 제품은 기억을 파일 명령으로 내준다. Anthropic memory tool 을 켜면 API 가 system prompt 에 필수 지시문을 넣고, 그 지시문이 모델에게 첫 view 를 부르게 한다. | 맞음 | 문서에 적힌 동작 | [Memory tool (Claude API docs)](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool). 전문 |
| `12` 주제는 같지만 답이 아닌 방해 문장은 입력이 길수록 답을 더 깎았다. 따로 한 LongMemEval 실험에서는 관련 부분만 담은 약 300토큰 입력이 전체 입력보다 높았다. | 맞음 | 측정 | [Context Rot (Chroma)](https://research.trychroma.com/context-rot). 일부 |
| `13` 파생 지식은 전제를 선언해야 고칠 수 있다. MemTX 는 파생 DAG 를 따라 연쇄로 고치는 부품을 빼면 약 11점 떨어졌다. | 맞음 | 측정 | [MemTX: Transactional Belief Commit for Stateful Agent Memory (arXiv 2607.23929v2)](https://arxiv.org/abs/2607.23929). 일부 |
| `14` GraphRAG 식 요약 그래프의 순이득은 작다. GraphRAG community 요약이 그래프 없는 map-reduce 요약을 이긴 비율은 57%·64% 였다. | 맞음 | 측정 | [From Local to Global: A GraphRAG Approach to Query-Focused Summarization (arXiv 2404.16130v2)](https://arxiv.org/abs/2404.16130), HippoRAG 2 Table 12. 일부 |

- `01` HippoRAG 2 와 색인형 그래프
  - passage node 를 빼면 87.1 에서 81.0 으로 내린다(Table 4, multi-hop 세 과제 평균). 요약으로 corpus 를 넓히는 GraphRAG·LightRAG 는 질의응답(QA) F1 평균이 49.6·6.6 으로 dense 57.0 보다 낮다(Table 2).
  - 고친 것: 원래 문장은 「원래 기록을 대신하면 내린다」 고 적었다. 논문이 견준 것은 검색을 돕는 KG 와 corpus 를 넓히는 KG 다. 요약으로 원래 기록을 대신한 조건은 실험에 없다. 「색인이면 검색을 올린다」 도 HippoRAG 2 하나에만 맞는다.
  - MASC 에서 쓰는 곳: 그래프는 이미 선언된 edge(`premise_ids`, `superseded_by`, `absorbed_statement`, `board_ref`, `Wiki_graph.links_of`)를 읽는 projection 으로 만든다. fact 에서 원래 기록으로 가는 길을 연다. `Observed Transcript` 에는 원래 turn 참조가 없다(`lib/keeper/keeper_memory_os_types.mli`). 저장된 값만 읽으면 새 필드가 없다. turn 참조 필드를 더하는 뜻이면 §15.2 와 부딪힌다.
- `02` 질문 종류별 결과
  - Novel 자료의 ACC 다. Fact 질문은 RAG w/ rerank 60.92, MS-GraphRAG 49.29, HippoRAG 2 60.14 다. Complex 질문은 같은 순서로 42.93, 50.93, 53.38 이다. Medical 에서는 MS-GraphRAG 가 네 종류 모두 RAG 보다 낮다(Table 2).
  - 단서: MS-GraphRAG 행은 local 검색이다. Medical 에서는 HippoRAG 2 가 Fact 질문에서도 RAG 보다 높다(66.28 대 64.73).
  - MASC 에서 쓰는 곳: 자체 recall 질문 세트를 다섯으로 나눠 따로 채점한다. 단일 fact 조회, 여러 fact 연결, 바뀐 사실, 시간, 답 없는 질문이다. 그래프 후보 생성은 여러 fact 연결 slice 에서만 효과를 기대한다(RFC-0247 §-1).
- `03` MemoryArena
  - 전 과제 평균 성공률은 text-embedding-3-small 0.20, BM25 0.17, GraphRAG 0.17, Letta 0.14, Mem0 0.13, Mem0-g 0.12 다(Table 3). 같은 task agent(gpt-5.1-mini)의 긴 맥락은 0.16 이다. 0.09~0.19 는 서로 다른 네 모델의 범위다.
  - 앞 하위 과제의 정보를 정확히 다시 써야 하는 과제가 있다. 그런 과제에서는 하위 과제가 늘 때 검색형의 성공률이 통합·추상화형보다 덜 떨어졌다(원문 'consistently more robust', MemoryArena §4.4).
  - 고친 것: 원래 문장은 구조 기억이 긴 맥락을 못 넘었다고 적었다. 같은 모델끼리는 GraphRAG 0.17 이 긴 맥락 0.16 보다 높다. MemoryArena §4.4 의 과제 조건도 뺐다.
  - 단서: 같은 절은 Progressive Web Search·Formal Reasoning 에서 외부 기억이 꾸준히 도왔다고 적는다. 기록이 120k 토큰을 넘는 과제에서도 외부 기억이 도왔다(MemoryArena §4.3). 성공률이 모두 낮아 차이가 작다. GraphRAG 0.17 은 원문이 2D(구조 기억)로 나눈 행의 값이다.
  - MASC 에서 쓰는 곳: Keeper 기억에 통합·요약 층을 더하기 전에 원래 기록 검색 기준선과 비교한다. Librarian 흡수·drop 뒤 잃은 정보는 `source=dropped` 검색 적중과 같은 claim 재기록 수로 센다. 이 셈에는 한계가 있다. `memory_id` 는 claim bytes 의 sha256 이다. 말을 바꿔 다시 적은 것은 이 셈에 안 잡힌다. `keeper_memory_os_types.mli` 는 'A re-observation is not a strength signal (RFC-0418)' 이라 적는다. 재기록 수는 손실을 재는 데만 쓰고 강도 신호로 쓰지 않는다.
- `04` AMA-Bench
  - 평균 ACC 는 AMA-Agent 0.5722, BM25 0.3436, GraphRAG 0.3258, Mem0 0.2104 다(v4 Table 5). MemoRAG·EMem·Qwen3-Emb-4B 도 BM25 위다. 인과 그래프를 빼면 0.57 에서 0.43 으로 내린다(v4 Table 7).
  - 고친 것: 원래 문장은 「유사도 그래프는 BM25 아래이고 상태·인과 그래프 쪽만 높다」 고 적었다. ablation 은 v4 에서 Table 7 이다.
  - 단서: 1위가 저자 시스템이고, 채점은 Qwen3-32B 판정자가 했다. 그래프 node 검색 도구는 200건 중 10.0% 에서만 불렸다.
  - MASC 에서 쓰는 곳: `activity_graph` 의 `event.actor`·`subject` 는 누가 무엇에 했는지를 적은 edge 다. 상태 사이의 인과 edge 는 아니다. 이 논문은 runtime 이 적은 edge 의 효과를 재지 않았다. `kind` 가 `string` 이라(`lib/activity_graph/activity_graph_types.mli`) 닫힌 variant 로 올린 뒤에 읽는다(§15.2).
- `05` Zep 의 시각 넷
  - multi-session 은 44.3 에서 57.9 로 올랐다(Table 3). 비교 대상은 전체 맥락 115k 토큰이고, Zep 은 1.6k 토큰을 준다(Table 2). 시각 필드만 뺀 실험은 없다. 가장 크게 오른 범주는 preference 로, 20.0 에서 56.7 로 올랐다.
  - 고친 것: 원래 문장은 오른 원인을 사건 시각과 기록 시각을 나눈 KG 에 돌렸다.
  - 단서: 벤더 논문이다. single-session-assistant 는 94.6 에서 80.4 로 내렸다. gpt-4o-mini 의 knowledge-update 는 76.9 에서 74.4 로 내렸다.
  - MASC 에서 쓰는 곳: `fact.first_seen`·`last_seen` 은 기록 시각이고, 사건 시각 필드는 없다(`lib/keeper/keeper_memory_os_types.mli`). 자체 세트에서 시간 질문 오답의 원인을 먼저 센다. 사건 시각이 없어 깨지는 durable truth 를 대면 typed 필드 RFC 를 쓴다(결정 2 의 기준).
- `06` 공유 기억의 조건부 쓰기
  - CodeCRDT(arXiv 2510.18893)는 600회 모두 수렴했지만 의미 충돌을 약 5~10% 보고했다.
  - 단서: CodeCRDT 의 5~10% 는 60회를 본 예비 값이다.
  - MASC 에서 쓰는 곳: wiki 는 `revision` 이 맞을 때만 쓰고, 거절할 때 현재 본문을 돌려준다(`lib/tool_wiki.ml`). 충돌 양쪽을 남기는 `Conflict_member`(`lib/workspace_memory/workspace_memory_ledger.mli`)도 있다. 둘 다 그대로 둔다. 진 쪽에 알리지 않고 덮는 sync 는 만들지 않는다.
- `07` CoAgent
  - 경합 작업 열 가지의 값이고, 모두 직렬 실행과 견준 배수다. 2PL(2단계 잠금)은 속도 1.04배였고 시행마다 교착이 0.81번 났다. OCC 는 시행마다 abort 가 0.95번 났다(서론, CoAgent §7.2).
  - MTPO(Monotonic Trajectory Pre-Order)는 시작 때 직렬 순서를 고정하고, 알림을 보내고, 어긋난 쓰기를 되돌린다. MTPO 전체는 속도 1.4배·토큰 1.15배였다. 정확도는 직렬보다 약 5% 낮았다(100회 중 5회). 순서 없이 알림만 보내면 livelock 이 난다(CoAgent §5.2).
  - 고친 것: 원래 문장은 1.4배를 「바뀐 내용을 알리고 에이전트가 판단하는 방식」 의 값으로 적었다.
  - 단서: preprint 하나, 에이전트 둘, 칸마다 10회, 모델 deepseek-v4-flash 하나다. 대상은 기억 store 가 아니다.
  - MASC 에서 쓰는 곳: wiki `stale_revision` 발생 수와 재시도 수를 projection 으로 세어 OCC 비용이 실제로 큰지 본다. 공유 기억 log 를 Keeper 가 자기 위치부터 읽는 Draft RFC 에는 순서 고정과 되돌리기가 없다. 이 논문의 수치를 그 RFC 의 기대값으로 옮기지 않는다.
- `08` HaluMem
  - 갱신 누락은 대부분 50% 위였다. 저자는 원인을 갱신 전 사실을 추출하지 않은 데서 찾는다('primarily stems from').
  - 단서: 원인 문장은 저자 해석이고 단계별 원인 표는 없다. 벤치마크를 낸 MemTensor 가 1위 MemOS 를 만들었다.
  - MASC 에서 쓰는 곳: RFC-0517(in_flight)의 남는 기억 측정에 갱신 사례를 더한다. 바뀐 사실마다 셋을 나눠 센다. 옛 fact 가 있었는지, current 에서 빠졌는지, `Revised {superseded_by}` 가 생겼는지다.
- `09` LightMem
  - 예: Qwen3-30B 는 70.20 에서 65.14 로 내렸다. 내린 폭은 1.35~5.06%p 이고, 논문은 이 하락을 다루지 않는다(Table 2).
  - 고친 것: 원래 문장은 LightMem §5.6 을 「LLM 이 모순 아닌 정보를 지우면 되돌릴 수 없다」 는 근거로 썼다. 그 절은 실시간 soft update 를 정당화하는 문장이다.
  - 단서: 반복 실행 분산이 표에 없다.
  - MASC 에서 쓰는 곳: 흡수는 Jev(TypeSafeAI 의 System One 판정 모델) 판정이 막는다. 단순 drop 은 조건 없이 일어난다(`lib/keeper/keeper_memory_os_disposition_core.mli`). drop 된 fact 가 다시 기록되거나 `source=dropped` 로 찾아진 횟수를 세어 손실을 잰다. 새 Gate 는 아니다. `03` 의 셈과 같은 한계가 있다.
- `10` LoCoMo 검토
  - 62.81% 는 'be generous' 지시를 받은 판정자의 값이다. 전체 맥락을 받은 GPT-4.1-mini 는 CoT(단계별 추론) prompt 로 92.62% 를 냈다. 기억 시스템 EverMemOS 의 보고값 92.32% 보다 높다. 5~6단어 답 prompt 로는 81.95% 였다.
  - 단서: 틀린 정답 99개 중 13개는 AMBIGUOUS 다. 검토자의 독립성은 확인하지 못했다.
  - MASC 에서 쓰는 곳: 외부 벤치마크 점수를 목표로 삼지 않는다. 자체 질문 세트의 정답표를 사람이 검수한다. 판정자가 틀린 답을 통과시키는 비율을 먼저 잰다(`scripts/keeper-recall-baseline.py`, `memory-recall-evaluations.jsonl`).
- `11` memory tool
  - 도구는 명령 여섯 개짜리 client 쪽 도구다. 넣는 문장은 'IMPORTANT: ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE.' 다.
  - 단서: host 가 첫 읽기를 실행하지는 않는다. 넣은 문장을 본 모델이 view 를 부른다. 필수 지시문 방식이라 host recall 의 근거가 아니다.
  - MASC 에서 쓰는 곳: `keeper_memory_search`·`select`·`write`·`retract` 가 이미 도구다. 첫 읽기는 host recall(Draft `docs/rfc/RFC-keeper-recall-reaches-the-turn.md`, `keeper_memory_recall_*`)로 건다. 프롬프트 문장으로 첫 읽기를 시키지 않는 것은 결정 1 과 맞는다.
- `12` Context Rot
  - LongMemEval 306문항에서 관련 부분만 담은 약 300토큰 입력을 받은 쪽의 점수가, 약 113k 토큰 전체 입력보다 평가한 모든 모델에서 높았다.
  - 단서: LongMemEval 실험과 방해 문장 실험은 따로다. 점수는 그림에만 있다. focused 입력은 정답 표시에서 뽑은 발췌다. 그래서 고르기를 틀리지 않았을 때의 상한이다. peer review 가 없다.
  - MASC 에서 쓰는 곳: 낡은 fact 는 방해 문장 정의에 맞는다. 중복 fact 는 답과 같은 내용이라 정의('do not quite answer the question')에 들지 않는다. 중복은 다른 근거로 다룬다. RFC-0517(in_flight)의 「맞는 fact 하나」 와 recall 의 선택 주입을 받친다. `docs/rfc/RFC-keeper-context-window-in-tokens.md` 의 「요약본」 은 「관련 부분 발췌」 로 고쳐야 한다.
- `13` MemTX
  - 에이전트가 부모를 선언하지 않고 옮겨 적는 계열은 모든 방법이 실패했다.
  - 단서: 저자가 만든 90건 suite 와 backbone 둘이다. 부품 셋이 각각 약 11점씩이다. 실패한 계열은 계열당 4건이다.
  - MASC 에서 쓰는 곳: `Derived of derivation list` constructor 는 `lib/keeper/keeper_memory_os_types.mli` 에 있다. 연쇄 retract 는 `lib/keeper/keeper_memory_os_current.mli` 에 있다. Librarian `new_claims` 에는 전제 자리가 없다. 그래서 전제를 가진 것은 live 2,334개 중 1개다. derivation edge 에 기대는 기능은 미룬다.
- `14` GraphRAG 요약과 색인 비용
  - HippoRAG 2 Table 12 에서 GraphRAG 는 passage 11,656개 색인에 입력 115.5M 토큰과 277분을 썼다. 같은 표의 HippoRAG 2 는 9.2M 토큰과 99.5분이다.
  - 단서: 57%·64% 는 가장 잘 나온 층의 값이고, 최상위 층 요약은 개선이 없었다. 승률은 LLM 이 만든 질문을 LLM 이 채점한 값이다. HippoRAG 2 의 값은 조사 보고서 본문에서 옮겼다. 재확인은 GraphRAG 의 값만 맞춰 봤다.
  - MASC 에서 쓰는 곳: 요구 21 의 「모든 것이 그래프」 는 저장된 typed edge 를 읽는 projection 으로 만든다. LLM 추출 그래프를 만들지 않는 이유는 `01`·`02`·`04` 의 품질 결과다. 색인 비용은 사실로만 적는다. 헌법 cost_and_observability(519행)는 비용을 문제로 보지 않는다. LLM 은 질의 때 후보를 고르는 판정에만 쓴다(RFC-0247 §-1).

적용하지 않는 것:

- Personalized PageRank·임베딩 top-k 를 recall 결정자로 쓰기. 점수 순위가 판정을 대신한다. RFC-0247 §-1 은 그래프·검색을 후보 생성까지만 쓴다. 지금 검색은 임베딩 없는 SQLite FTS5 trigram + BM25 다.
- LLM 이 뽑은 entity KG 를 authority 로 두기. AMA-Bench Table 3 에서 기억 구성 방법만 바꾸면 정확도가 기준 0.46 에서 0.27~0.37 로, 상대로 19.6~41.3% 줄었다. 답 entity 의 일부만 KG 에 들어간다는 보고도 있다(arXiv 2502.11371v4, 재확인 밖). authority 는 원래 기록과 선언된 edge 에 둔다.
- GraphRAG·LightRAG 식 community 요약으로 원래 기록을 대신하기. 단일 사실 질문에서 dense 검색보다 낮다(HippoRAG 2 Table 2, GraphRAG-Bench Table 2). 원래 기록을 잃으면 헌법 failure_keeps_evidence 와도 어긋난다.
- 공유 기억에 CRDT 자동 병합. byte 는 수렴해도 의미 충돌이 조용히 남는다(CodeCRDT, 60회 예비 값 약 5~10%). 충돌은 양쪽을 남겨 Keeper 가 보게 한다.
- 진 쪽에 알리지 않는 store-wins sync. 쓰기가 사라진 것을 에이전트가 모르는 silent failure 다.
- Zep 식 「새 정보가 늘 이긴다」 자동 무효화. 늦게 들어온 틀린 정보를 못 막는다. gpt-4o-mini 의 knowledge-update 는 76.9 에서 74.4 로 내렸다(Zep Table 3). Librarian 프롬프트도 기록 시각만으로 최신성을 정하지 않는다.
- LoCoMo·LongMemEval 점수를 MASC 합격선으로 쓰기. LoCoMo 는 정답표 오류와 너그러운 채점이 있다(`10`). LongMemEval_s 는 벤더 보고값이 포화에 가깝다(재확인 밖).
- CoAgent 의 MTPO 프로토콜 전체. 도구마다 읽기·쓰기 범위와 되돌리기 동작을 선언하고 직렬 순서를 고정해야 한다. Keeper 도구 계약 전체가 바뀌는데 근거가 preprint 하나다.
- Google Research sleep framework(2026-10-27). 모델 가중치를 바꾸는 continual learning 이라 기억 store 설계와 층이 다르다. Librarian 학습은 RFC-0517(in_flight) 몫이다.
- 사용자 결정 때문에 뺀 8건은 §15.1 에 있다.

## 4. OCaml 과 OxCaml (`ocaml-oxcaml`)

OCaml 5.5 매뉴얼, OxCaml·Eio·dune 의 1차 자료, 업계 경험 보고에서 발견 14개를 뽑았다. 요구 4·19 에 닿는다. 13개가 원문과 맞았다. OxCaml 은 지금 쓰지 않는다. 모듈이 쓸 수 있는 효과의 경계는 dune `libraries` 와 alert 로 먼저 긋는다. 이 절에서 `masc` 는 dune 라이브러리 이름이다.

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` OxCaml 은 OCaml 5.4 기반(VERSION 5.4.0+ox)이다. Linux 에서는 glibc 만 지원하고 arm64 macOS 는 지원한다. Jane Street 소개 글은 확장의 안정성을 약속하지 않는다고 적는다. | 맞음 | 문서에 적힌 동작 | [Get OxCaml](https://oxcaml.org/get-oxcaml/), OxCaml README·VERSION(main), Jane Street 소개 글. 전문 |
| `02` eio_posix 는 open·stat·fsync·rename 을 호출한 OCaml 도메인에 묶인 systhread 에서 부른다. 일반 파일 read·write 는 그 도메인의 스케줄러 스레드에서 바로 부른다. | 맞음 | 문서에 적힌 동작 | [Eio `lib_eio_posix/low_level.ml` v1.3](https://raw.githubusercontent.com/ocaml-multicore/eio/v1.3/lib_eio_posix/low_level.ml)·v1.6, `lib_eio_linux/low_level.ml`. 일부 |
| `03` `implicit_transitive_deps false` 와 OCaml 5.2 이상의 `-H` 를 쓰면, `libraries` 에 없는 라이브러리는 컴파일 때 보이지 않는다. | 맞음 | 문서에 적힌 동작 | [Dune reference: implicit_transitive_deps](https://dune.readthedocs.io/en/stable/reference/dune-project/implicit_transitive_deps.html). 전문 |
| `04` 로컬 5.5.2 에서 쟀다. `[@@alert blocking]` 을 단 가림 모듈은 `-warn-error +a` 아래에서 경고로만 나오고, `-alert ++blocking` 을 주면 실패한다. | 맞음 | 측정 | [OCaml 5.5 매뉴얼 Alerts](https://ocaml.org/manual/5.5/alerts.html), 로컬 컴파일 탐침(probe) 파일 여덟 개. 일부 |
| `05` ppxlib 0.36.0 이 내부 AST 를 5.2 로 올리자 ppxlib 에 기대는 패키지 여럿이 깨졌다. 1.0.0 까지 내부 AST 는 5.2 로 고정된다. | 맞음 | 문서에 적힌 동작 | [[ANN] Ppxlib: Support for future compilers (NathanReb, 2025-10-29)](https://discuss.ocaml.org/t/ann-ppxlib-support-for-future-compilers/17430) 공지 1번, discuss 글타래 18469 의 dra27 글(2026-08-25). 전문 |
| `06` dune 은 libA 의 모든 모듈에 libB 의 모든 .cmi 에 대한 glob 의존을 준다. 모듈 단위로 거르는 dune PR 둘은 null build 를 4초에서 7초로 늘렸고, 병합 없이 닫혔다. | 맞음 | 경험담 | [Experience report: Refining Dune's Dependency Graph](https://discuss.ocaml.org/t/experience-report-refining-dune-s-dependency-graph/18002), dune PR 상태, 3.25.0 노트. 전문 |
| `07` OCaml 5.4 부터 ARM64 macOS 에서 frame pointer(ocaml-option-fp, xctrace)를 쓸 수 있다. 5.5 는 컴파일러 설치를 복사해 옮길 수 있다. | 맞음 | 문서에 적힌 동작 | [OCaml 5.5 매뉴얼 Profiling](https://ocaml.org/manual/5.5/profil.html), OCaml 5.5.0 릴리스 노트. 일부 |
| `08` eio_posix `clear_event_fd` 의 EINTR 재시도는 커밋 9480f2a9a4(2026-10-16)로 Eio 저장소 main 에만 있다. 최신 릴리스는 v1.6(2026-09-21)이고 MASC lock 은 1.3 이다. | 맞음 | 문서에 적힌 동작 | [Eio commit 9480f2a9a4 "eio_posix: retry the wake-up pipe on EINTR"](https://github.com/ocaml-multicore/eio/commit/9480f2a9a4e61d46ab1c848dd48ece7f98d84241). 일부 |
| `09` flambda 없는 컴파일러는 Flambda 플래그를 조용히 받는다. MASC release 프로필의 `-O3 -unbox-closures` 는 아무 일도 하지 않는다. | 맞음 | 문서에 적힌 동작 | [OCaml 5.5 매뉴얼 Flambda](https://ocaml.org/manual/5.5/flambda.html), Dune reference Caches. 일부 |
| `10` OxCaml 의 mode 축은 effect·가변 상태·도메인 공유를 다룬다. MASC 가 이름·주석으로 지키는 경계를 검사하는 축은 없다. | 세게 말함 | 문서에 적힌 동작 | [OxCaml 문서: modes intro](https://oxcaml.org/documentation/modes/intro/), capsules, Octez Event_loop API. 전문 |
| `11` Jane Street 는 runtime 5 전환이 예상보다 어려워 2025년에야 옮겼다. 걸림돌은 GC pacing 과 자원 사용 변화였다. | 맞음 | 경험담 | [Yaron Minsky, The saga of runtime 5 (CMU 세미나 초록, 2025-04-22)](https://www.cs.cmu.edu/~pop/seminar/2025-04-22-Minsky/), Anil ICFP25 노트, Semgrep 글타래. 초록만 |
| `12` Octez 는 통합 시험을 실행 파일 하나에 모으고, 지난 실행 시간으로 묶음을 나눈다. | 맞음 | 문서에 적힌 동작 | [Tezt 문서(Octez)](https://octez.tezos.com/docs/developer/tezt.html), Tezt `cli.ml` 옵션 설명. 일부 |
| `13` memtrace 의 opam 최신 버전은 2022-10-17 의 0.2.3 이다. 도메인별로 기록하는 코드(Per_domain)는 master 의 v0.18~preview 에만 있다. | 맞음 | 문서에 적힌 동작 | [janestreet/memtrace](https://github.com/janestreet/memtrace) README·master `src/memprof_tracer.ml`·태그, opam-repository 목록. 일부 |
| `14` Docker VPNKit 은 같은 코드베이스에서 구현을 여럿 쓸 때만 functor 를 남긴다. 한 번 쓰는 추상화는 함수 레코드·first-class module 로 바꾼다. | 맞음 | 경험담 | [Functional Networking for Millions of Docker Desktops (ICFP 2025 Experience Report)](https://anil.recoil.org/papers/2025-docker-icfp.pdf) 원문 §4.2.1·§4.2.2. 일부 |

- `01` OxCaml
  - MASC 가 쓰는 5.5 의 `Lazy.Mutexed`·`Unix.unsetenv` 가 없다. yojson 패치 버전은 2.2.2 다.
  - 단서: 안정성 문장은 Get OxCaml 에 없고 Jane Street 소개 글에 있다.
  - MASC 에서 쓰는 곳: 제품 컴파일러로 넣지 않는다. 다시 볼 조건은 셋이다. VERSION 이 5.5 이상이 될 때, musl 을 지원할 때, yojson 3 패치 버전이 나오거나 전체 solve 가 될 때다. MASC 의존성 전체를 5.4.0+ox 에서 solve·빌드해 보지는 않았다.
- `02` eio_posix 의 파일 연산
  - eio_linux 는 io_uring 을 쓴다. v1.6 도 구조가 같다.
  - 단서: systhread 는 호출한 도메인의 스케줄러가 만든 pool 에서 돈다. v1.3 eio_linux 의 mkdir·rename 은 C stub 을 바로 부른다.
  - MASC 에서 쓰는 곳: 파일 I/O 정지는 백엔드별로 잰다. macOS 측정을 Linux 로 옮겨 읽지 않는다. Eio 를 올려 빨라진다고 기대하지 않는다. 정지 구간 캠페인(#51655, in_flight)에 근거로 넘긴다. Linux 배포가 eio_linux 를 쓰는지는 확인 필요다.
- `03` implicit_transitive_deps
  - `lib` 아래 library stanza 200개 중 115개는 unix·threads·eio.unix 를 적지 않는다. 1,417 모듈의 `masc` 라이브러리는 셋을 다 적는다.
  - 단서: 200·115 는 `dune` 파일 기준이다. include 하는 `.inc` 까지 세면 204·116 이다.
  - MASC 에서 쓰는 곳: 규칙 하나를 둔다. 효과를 인자와 `libraries` 목록으로 드러낸다. 새 코드는 필요한 것만 적은 leaf 라이브러리에 넣는다. `masc` 를 한 번에 쪼개지 않는다. Stdlib 채널과 `Sys.command` 는 `libraries` 로 못 막는다(348곳).
- `04` blocking alert
  - 내장 deprecated alert 로 달면 지금 플래그로 실패한다. `Stdlib.` 를 앞에 붙여 부르면 alert 를 피해 간다.
  - 단서: 재확인이 따로 짠 탐침도 같은 결과다(exit 0·2·0·2). dune lang 3.22 의 dev 기본값이 `-warn-error +a` 다.
  - MASC 에서 쓰는 곳: main 도메인 라이브러리의 flags 에만 `-open` 가림 모듈과 `-alert ++blocking` 을 적는다. 그러면 Stdlib 채널 빈칸이 메워진다. 이름 해석이라 문자열 매칭이 아니다. CI 실행도 늘리지 않는다. 덮을 Stdlib 입구 수와 이름 충돌은 짜 보지 않았다.
- `05` ppxlib
  - Jane Street 의 upstream 5.4+ 버전도 ppxlib 0.36 호환 작업으로 늦어졌다.
  - 단서: 하한 불일치는 지금 빌드를 깨지 않는다. `ocaml = 5.5.2` 아래 solver 는 0.38.0 이상만 고른다. 일부 버전은 열어 보지 않은 추론이다.
  - MASC 에서 쓰는 곳: 컴파일러 pin 을 바꿀 때 ppxlib opam 상한, ppx 패키지 다섯의 빌드, ppx_tla 노드 순으로 본다. `dune-project` 의 `ppxlib (>= 0.30)` 은 실제 요구 0.36.0 보다 낮다. 지금 빌드는 깨지지 않으니 pin 을 바꾸는 변경에서 같이 고친다.
- `06` dune 의 glob 의존
  - 두 PR 은 ocaml/dune#14116·#14186 이고, 2026-05-10 02:52Z 에 닫혔다. 3.25.0(2026-11-12)에도 없다.
  - 단서: 닫힌 이유를 다룬 토론 본문은 읽지 않았다.
  - MASC 에서 쓰는 곳: `masc` 라이브러리(lib .ml 약 2,820개 중 1,417개)의 .cmi 변경이 퍼지는 범위를 한 번 잰다. 라이브러리 경계를 재빌드 경계로 쓴다. MASC 에서 다시 도는 규칙 수는 재지 않았다.
- `07` frame pointer
  - 로컬 5.5.2 switch 는 `with_frame_pointers: false` 다.
  - 단서: 원문의 비용 수치는 x86_64 최대 10% 뿐이다.
  - MASC 에서 쓰는 곳: 프로파일 전용 fp switch 로, 정지 구간에 main 도메인 을 잡은 호출 스택을 본다. 운영 서버에는 쓰지 않는다. Eio fiber 스택이 끝까지 풀리는지와 ARM64 비용은 확인 필요다.
- `08` EINTR 재시도
  - 단서: 커밋은 v1.6 보다 32 커밋 뒤다. v1.6 의 `clear_event_fd` 는 EINTR 을 받으면 다시 시도하지 않는다.
  - MASC 에서 쓰는 곳: 수정이 든 릴리스가 나오면 lock 을 올린다. 그때 `bin/main_eio.ml` 에서 EINTR 을 받으면 끝내는 코드와, 그 코드만 쓰는 코드를 지운다(hard cut). tls-eio·cohttp-eio 같은 의존 라이브러리 호환은 확인 필요다.
- `09` 무시되는 Flambda 플래그와 틀린 문서
  - 틀린 문서는 셋이다. `docs/NORTH-STAR-OCAML.md` 에는 컴파일되지 않는 예시 둘과 틀린 사실 셋이 있다. `docs/guides/DUNE-CACHE-MAINTENANCE.md` 는 `dune cache trim` 이 무엇을 줄이는지 틀리게 적는다. `docs/evidence/perf-oxcaml-parity-20261107/README.md` 는 무시되는 플래그를 최적화로 적는다.
  - 단서: NORTH-STAR 의 두 예시는 로컬 5.5.2 에서 문법·타입 오류로 실패했다. perf-oxcaml-parity 문서의 「0 allocations」 와 표의 호출당 5 words 가 다른 이유가 벤치 틀 때문인지는 확인 필요다.
  - MASC 에서 쓰는 곳: 루트 `dune` 의 release 플래그를 지우고, 위 문서 셋을 원문대로 고친다. 품질 증거는 원문 문법·타입과의 불일치다(결정 9). 헌법 legacy_residue(틀린 주석과 문서는 지운다)와 같은 방향이다.
- `10` mode 축
  - 축마다 다루는 것이 다르다. yielding 은 부모 스택 handler 로 가는 effect 를 다룬다. statefulness 는 인자로 받지 않은 가변 상태를 다룬다. portability·contention 은 도메인 공유를 다룬다. capsule 의 initial 은 main 도메인 상태를 뜻한다. Octez 도 main 도메인 전용 규칙을 문서와 helper 로 지킨다.
  - MASC 가 지키는 경계는 둘이다. main 도메인 이 일을 들지 않는 것과, Memprof callback 에서 lock 을 잡지 않는 것이다.
  - 고친 것: 원래 문장은 이 축들이 MASC 경계를 타입으로 검사한다고 적었다. 원문에 없는 추론이다.
  - MASC 에서 쓰는 곳: 가져오는 것은 문법보다 경계 위치다. `libraries` 경계(`03`)와 alert(`04`)가 나중에 mode 를 붙일 자리다. `masc` 코드에 mode 를 붙여 본 적은 없다.
- `11` runtime 5 전환
  - pacing 수정은 Jane Street 컴파일러에 먼저 들어갔다. Semgrep 은 늘어난 메모리를 heap 크기별 space_overhead 로 풀었다.
  - 단서: 발표 영상은 보지 못했다. 「예상보다 어려웠고 2025년에 옮겼다」 는 초록에 있다. GC pacing·자원 사용 변화는 동료의 2차 기록에 있다. 컴파일러에 먼저 들어간 일은 kayceesrk 답글에 있다.
  - MASC 에서 쓰는 곳: 정지 구간 캠페인(#51655, in_flight)에 근거로 넘긴다. 미세 벤치보다 실제 workload 로 잰다. Memprof 로 살아 있는 것을 본 뒤에 GC 매개변수를 만진다. Semgrep 은 메모리 문제였고 MASC 는 지연 문제다.
- `12` Tezt
  - MASC 시험 실행 파일은 2,183개이고, 1,816개가 `masc` 를 링크한다. 표본 200개의 크기 중앙값은 68.8 MB 다. Eio_mock 을 쓰는 시험 파일은 49개다.
  - 단서: 재확인이 따로 센 값도 같다(빌드된 199개 중앙값 68.8 MB). 표본은 무작위가 아닌 macOS dev 빌드다.
  - MASC 에서 쓰는 곳: 기존 trace 로 링크 비용을 먼저 잰다. 병목이면 실행 파일은 층마다 하나, 실행은 시험마다 프로세스 하나로 바꾼다. 시간에 기대는 시험은 `Eio_mock.Clock` 으로 쓴다. 죽은 시험부터 지운다(결정 7).
- `13` memtrace
  - 그 버전은 oxcaml/opam-repository 에만 올라 있다. olly gc-stats 는 MASC `rtev_watch` 와 같은 자료다.
  - MASC 에서 쓰는 곳: olly 는 들이지 않는다(`tools/rtev_trace/rtev_watch.ml` 이 같은 runtime events 를 읽는다). memtrace 는 `Alloc_profile` 이 표본을 버리는 빈칸(누적 손실 41,393,109건)을 메울 수 있다. opam 본 저장소에 도메인별 버전이 오면 다시 본다.
- `14` VPNKit 의 functor
  - Lwt 에서 Eio 로 옮기자 이중 예외와 read·write 마다의 closure 할당이 줄었다. MirageOS 도 구현 하나인 functor 를 걷어 낸다.
  - 단서: 할당 쪽 원문 표현은 'mitigates', 'lower heap memory usage' 이고 수치는 없다.
  - MASC 에서 쓰는 곳: 헌법 engineering 의 「깊은 추상화보다 중복」 을 받친다. 시험 구현은 Eio capability 와 함수 인자로 끼운다. dune variant 는 같은 일을 하는 두 번째 방법이라 쓰지 않는다.

적용하지 않는 것:

- OxCaml 을 지금 제품 컴파일러로 쓰기. 5.4 기반이라 `Lazy.Mutexed`·`Unix.unsetenv` 가 없다. Linux 에서는 glibc 전용이라 Alpine(musl) shim 을 못 만든다. 안정성 약속도 없다(`01`).
- vanilla 코드에 `[@zero_alloc]` 같은 OxCaml attribute 를 미리 달기. vanilla 5.5.2 는 경고 없이 받아들이고 아무것도 검사하지 않는다(조사 탐침). 틀린 표시가 드러나지 않는다.
- 새 도구를 지금 들이기. dune pkg 는 유지보수자가 early adopter 밖에는 아직 권하지 않는다. olly 는 `rtev_watch` 와 같은 자료다(`13`). memtrace 의 도메인별 버전은 opam 본 저장소에 없다(`13`). Octez 식 manifest 생성기는 풀 문제가 다르다. 풀 문제는 실행 파일 수와 라이브러리 크기이고, dune 파일을 손으로 쓰는 일은 문제가 아니다.
- Jane Street 라이브러리를 v0.18 preview·비공식 5.5 버전으로 올리기. MASC 가 쓰는 Jane Street 패키지는 ppx 셋이고 v0.17 로 빌드된다. 비공식 버전은 LLM 으로 고친 부분이 있다고 스스로 적는다.
- dune variant(virtual library)로 시험 구현 바꿔 끼우기. 같은 일을 하는 두 번째 방법이다(`14`). MirageOS 의 시도도 'not easily upstreamable' 이었다.
- `Gc.Tweak` 으로 GC 조정하기. 매뉴얼이 unstable and undocumented 이고 GC 개발자용이라고 적는다.
- 한 생성자 wrapper 타입에 `[@@unboxed]` 일괄 적용. 후보 약 160곳에 오류 타입(차가운 경로)이 섞여 있고, 몇 곳인지는 세지 않았다. hot path 근거가 없다.
- NORTH-STAR 의 Flambda 2 지침 따르기. Flambda 2 는 OxCaml 쪽 최적화기다. MASC 가 쓰는 컴파일러는 flambda 1 도 꺼져 있다(`09`).
- 시험을 한 프로세스의 Alcotest runner 로 합치기. 시험 파일 287개가 `Unix.putenv` 로 프로세스 환경을 바꾼다. 실행은 시험마다 프로세스를 나눠야 한다.
- Eio 를 올리면 macOS 파일 I/O 가 빨라진다고 기대하기. v1.6 의 eio_posix 도 파일 연산 구조가 v1.3 과 같다(`02`).
- Lwt 식 모나드로 돌아가 함수 색 되찾기, module-dependent function 으로 provider 추상화 다시 짜기. 지금 풀 문제가 없다. Ocsigen 이 Lwt 에 남은 이유인 브라우저 event handler 가 MASC 에는 없다. first-class module 사용은 12곳, 7파일이다.
- 사용자 결정 때문에 뺀 6건은 §15.1 에 있다.

## 5. 격리와 원격 실행 (`sandbox-microvm-ssh`)

격리·원격 실행에 관한 제품 문서, 커널 문서, 논문에서 발견 14개를 뽑았다. 요구 5·6 과 결정 11·13 에 닿는다. 대부분 문서에 적힌 동작이다. 이번 조사에서 새로 잰 것은 없다. 저장소에 남은 SSH 측정은 `05` 에 적었다. loopback 은 한 사람에게는 담장이지만, 여러 사람이 붙은 기기에서는 공용 복도다.

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` Claude Code 내장 sandbox 는 셸 명령만 가둔다. Read 도구·hook·MCP 서버는 sandbox 밖에서 돌고, `denyRead` 는 Read 도구를 못 막는다. | 맞음 | 문서에 적힌 동작 | [Claude Code Docs — Sandboxing](https://code.claude.com/docs/en/sandboxing.md) 11·42행, Sandbox environments 24·83·121행. 전문 |
| `02` Codex 권한 프로필의 `deny` 는 Seatbelt 또는 bubblewrap+seccomp 로 spawn 된 명령까지 강제된다. macOS 에서 강제하지 못하면 실행을 거절한다. MCP 서버는 프로필 밖이다. | 맞음 | 문서에 적힌 동작 | [Codex Docs — Permissions](https://learn.chatgpt.com/docs/permissions), 같은 문서의 Sandboxing 쪽. 일부 |
| `03` Landlock 은 권한과 user namespace 없이 프로세스를 가둔다. 규칙은 허용 목록뿐이다. 경로 이름 Unix socket 은 ABI 9(메인라인 7.1)부터 좁힌다. | 맞음 | 문서에 적힌 동작 | [Linux kernel documentation — Landlock](https://docs.kernel.org/userspace-api/landlock.html)(2026-10), landlock(7) 표. 전문 |
| `04` OpenSSH `authorized_keys` 의 `restrict,command="..."` 는 그 키로 한 명령만 돌게 하고 forwarding·PTY 를 끈다. 클라이언트가 준 명령은 `SSH_ORIGINAL_COMMAND` 로만 넘어온다. | 맞음 | 문서에 적힌 동작 | [OpenSSH sshd(8) AUTHORIZED_KEYS FILE FORMAT](https://man.openbsd.org/sshd.8), Release Notes 10.5(2026-08-11)·10.6(2026-10-06). 일부 |
| `05` 요청마다 새 연결을 여는 쪽에 걸리는 sshd 설정은 `MaxStartups` 와 `PerSourcePenalties` 다. 인증을 마친 동시 세션의 호스트 전체 상한은 sshd 에 없다. | 세게 말함 | 문서에 적힌 동작 | [OpenSSH sshd_config(5)](https://man.openbsd.org/sshd_config.5) MaxSessions·MaxStartups·PerSourcePenalties. 일부 |
| `06` Apple `container` 문서는 중첩 가상화를 지원한다고 적는다. 조건은 Apple Silicon M3 이상, macOS 15 이상, `CONFIG_KVM=y` 커널이다. 기본 커널은 지원하지 않는다. | 맞음 | 문서에 적힌 동작 | [apple/container docs — container-machine.md](https://github.com/apple/container/blob/main/docs/container-machine.md) 86~91행, command-reference.md 79·247·1123행. 전문 |
| `07` Firecracker, Cloud Hypervisor, libkrun 은 게스트가 놓은 메모리를 호스트로 돌려주는 장치를 문서로 적는다. Apple `container` 문서는 1.7.1 에서도 돌려주지 않는다고 적는다. | 맞음 | 문서에 적힌 동작 | [Firecracker docs/ballooning.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/ballooning.md), Cloud Hypervisor docs/balloon.md, apple/container technical-overview.md. 일부 |
| `08` microsandbox 최신은 0.7.14 다. `--cap-drop`·`--read-only` 는 여전히 없다. libkrun 은 VM 경계가 장치로 내준 호스트 자원을 막지 않는다고 적는다. | 맞음 | 문서에 적힌 동작 | [microsandbox docs](https://docs.microsandbox.dev) CLI reference, security/isolation, libkrun docs/security-model.md. 일부 |
| `09` Firecracker 명세는 InstanceStart 에서 게스트 init 까지 125 ms 이하, VMM overhead 5 MiB 이하를 적는다. virtio-fs 와 네트워크 필터가 없다. | 맞음 | 측정 | [Firecracker SPECIFICATION.md](https://github.com/firecracker-microvm/firecracker/blob/main/SPECIFICATION.md) 14~45행, docs/design.md, FAQ.md. 전문 |
| `10` cgroup v2 는 위임받은 하위 트리 안에서만 프로세스를 옮기게 한다. `memory.oom.group` 은 cgroup 을 통째로 죽이고 `cgroup.kill` 은 트리 전체를 죽인다. | 맞음 | 문서에 적힌 동작 | [Linux kernel documentation — Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) Delegation·cgroup.kill·memory.oom.group, systemd CGROUP_DELEGATION.md, `user@.service.in`. 일부 |
| `11` E2B 는 SNI(TLS 연결이 처음 보내는 서버 이름)·Host 로, Modal 은 SNI 로만 도메인 이름 허용 목록을 판정한다. 둘 다 DNS 를 따로 열어 둔다. | 맞음 | 문서에 적힌 동작 | [E2B Docs — Internet access](https://docs.e2b.dev/sandbox/internet-access)(지금 주소는 /network/internet-access), Modal Docs — Sandbox networking, sandbox-runtime README. 일부 |
| `12` Apple Containerization 에 Linux backend(cloud-hypervisor + KVM)가 생겼다. `container` 1.3.1·1.4.1·1.5.0·1.6.0 이 보안 권고를 고쳤고, 최신은 1.7.1 이다. | 맞음 | 문서에 적힌 동작 | [apple/containerization README](https://github.com/apple/containerization) Backends 절, apple/container release notes. 일부 |
| `13` Mosh 는 번호 붙은 상태 사이의 diff 를 idempotent 하게 보낸다. 3G 망 trace 재생에서 키 입력 지연 중앙값은 5 ms 미만이었고 SSH 는 503 ms 였다. 이 값은 예측 local echo 덕분이다. | 세게 말함 | 측정 | [Winstein & Balakrishnan, Mosh: An Interactive Remote Shell for Mobile Clients (USENIX ATC 2012)](https://mosh.org/mosh-paper.pdf) 초록·Mosh 논문 §2.2·§4, Eternal Terminal 프로토콜 문서. 전문 |
| `14` VS Code Remote-SSH 문서는 여러 사용자가 같이 쓰는 호스트에서, 서버를 loopback TCP 포트 대신 사용자에게 잠긴 Unix socket 으로 띄우는 선택지를 적는다. | 맞음 | 문서에 적힌 동작 | [VS Code Docs — Remote Development Tips and Tricks](https://code.visualstudio.com/docs/remote/troubleshooting) 199~203행, Remote Development using SSH 51행. 일부 |

- `01` Claude Code sandbox 의 범위
  - 프로세스 전체를 가두는 길은 `srt claude`(beta research preview), dev container, VM 이다.
  - 단서: 같은 문서의 표가 dev container·VM 도 프로세스 전체 경계로 적는다. `srt` 가 유일한 길은 아니다.
  - MASC 에서 쓰는 곳: 이 발견은 `Runtime_account_access.authorize_native` 가 다계정에서 `Native_none` 만 통과시키는 판정의 근거다. `read`·`full` 을 열 후보는 프로세스 전체를 OS 로 가둔 구성이다. 다른 사람 home 에 둔 표식 파일을 읽으려 하면 거절되는지 도구 경로마다 재야 한다. 다계정 캠페인(#51072·#51074, in_flight)의 입력이다.
- `02` Codex 권한 프로필
  - Linux 의 glob deny 는 프로세스 시작 때 한 번 펼친다.
  - 단서: 저장소 README 예시는 `none`, 문서는 `deny` 로 철자가 다르다. user namespace 를 막는 Linux 호스트에서는 이 정책이 돌지 않는다.
  - MASC 에서 쓰는 곳: 결정 11 의 증명 대상 후보는 Codex 프로필 하나다. RFC-0390 의 posture(`:read-only`, `:workspace`)에, 다른 사람 계정 home 을 정확한 경로로 `deny` 한 것이다. 측정한 뒤에만 연다. 다계정 캠페인에 넘긴다.
- `03` Landlock
  - Landlock 도메인이 다르면, 갇힌 프로세스는 그 밖의 프로세스를 ptrace 하지 못한다. ABI 6 은 신호와 abstract Unix socket 을 Landlock 도메인 안으로 좁힌다.
  - 단서: ptrace 제한은 갇힌 쪽이 추적자일 때 이야기다. 안 갇힌 같은 계정 프로세스가 추적하는 것은 못 막는다. 커널 버전은 참고용이라고 원문이 적는다.
  - MASC 에서 쓰는 곳: 열린 이슈 #38895(선언 루트를 shim Landlock 으로)의 입력이다. 같은 Unix 계정을 쓰는 Keeper 사이에는 OS 가 강제하는 읽기 경계가 없다. 좁히려면 끝점이 읽기 뿌리를 선언해야 한다. MASC 게스트 커널은 6.18(ABI 7)이라 경로 Unix socket 은 seccomp 로 계속 막는다.
- `04` restrict 키
  - PermitTunnel 을 켠 경우에 한해, 10.5 와 10.6 이 `restrict` 의 tunnel forwarding 누락을 고쳤다.
  - 단서: PermitTunnel 은 기본으로 꺼져 있다.
  - MASC 에서 쓰는 곳: 끝점을 붙이는 신원과 명령을 실행하는 신원이 나뉘지 않는다(sandbox-remote-03). 나누는 방법은 RFC 로 갈 일이다.
- `05` sshd 의 연결 설정
  - `MaxStartups`(기본 10:30:100)는 인증이 끝나기 전의 연결만 서버 전체로 세고, 몰리면 확률로 끊는다. 기본으로 켜진 `PerSourcePenalties` 는 상한이 아니다. 인증 실패나 grace 초과가 난 출발지를 한동안 거절하는 벌점이다. `MaxSessions` 는 연결 하나 안의 세션 수다.
  - 고친 것: 원래 문장은 `PerSourcePenalties` 를 상한으로 적었다. 원래 「MASC 에서 쓰는 곳」 문장은 메모리 예산 RFC Q6 의 호스트 전체 상한을 sshd 가 이미 가진다고 적었다.
  - MASC 에서 쓰는 곳: `config/runtime.toml` 주석은 `ControlMaster`·`MaxSessions` 를 말한다. 코드는 `ControlMaster=no` 다(`lib/keeper/keeper_sandbox_remote.ml`). 주석을 고친다. 메모리 예산 RFC Q6 에는 「인증 중인 연결이 몰리면 sshd 가 확률로 끊는다」 까지만 쓴다. 저장소에 남은 측정은 같은 Mac 게스트 sshd 로 잰 둘뿐이다. 20개 동시 1회(실패 0)와 순차 100회(p50/p90 98/129 ms)다.
- `06` 중첩 가상화
  - `container run --virtualization` 과 `container machine create --virtualization` 이 있다.
  - 단서: 1.7.1 태그 문서도 같다. Containerization README 는 Linux 통합 시험을 `container run --virtualization` VM 안에서 돌린다고 적는다.
  - MASC 에서 쓰는 곳: `docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md` 의 「중첩 가상화 없음」 전제가 낡았다. `nerdctl_kata` 와 Linux 쪽 `microsandbox` 를 이 Mac 의 게스트 안에서 잴 길이 문서로는 열렸다(RFC-0405). 이 M3 Max 에서 재지 않았다. KVM 을 켠 커널을 따로 준비해야 한다.
- `07` 메모리 돌려주기
  - Firecracker 는 free page reporting(developer preview), Cloud Hypervisor 는 `free_page_reporting=on`, libkrun 은 free-page reporting 만 적는다.
  - 단서: ballooning.md 의 Developer Preview 표시는 free page hinting 에 붙어 있다. reporting 이 preview 라는 말은 1.14.0 CHANGELOG·release notes 에만 있다. 돌아오는 양의 수치는 어느 문서에도 없다.
  - MASC 에서 쓰는 곳: 메모리 예산 RFC 의 「원격 Linux/KVM」 선택지를 받치는 1차 근거다. 기존 경로로는 `nerdctl_kata` + Cloud Hypervisor(`lib/keeper/keeper_microvm_kata_vmm.mli`)가 닿는다. 선택지 순서를 바꾸기 전에 작업 뒤 VMM(가상 머신 관리 프로세스)의 RSS(상주 메모리)가 줄어드는지 잰다. Kata 설정으로 켤 수 있는지는 확인 필요다.
- `08` microsandbox
  - 문서에 `msb ls --label`, `--security restricted`, `--no-net` 이 있다. Linux 에서 `/dev/kvm` 은 `kvm` 그룹으로 연다고 적는다.
  - 단서: 0.7.14(2026-11-08)가 최신이다. run 표는 전체 목록이 아니다. 그래서 v0.7.14 CLI 소스로 `--cap-drop`·읽기 전용 루트 플래그가 없음을 따로 확인했다. 저자는 beta 라고 적는다.
  - MASC 에서 쓰는 곳: `docs/MICROVM-REMOTE-RUNBOOK.md` 와 RFC-0405 의 서술은 0.6.16 기준이라 낡았다. 거절 사유 `microvm_constraint_unexpressible` 와 `policy` 거절은 그대로 둔다. 지금 버전으로 다시 잰 값으로 서술을 바꾼다. README 의 부팅 100 ms 는 잰 방법이 없어 쓰지 않는다.
- `09` Firecracker 명세
  - 수치 조건은 M5D.metal·M6G.metal, 최소 커널·rootfs, serial 끔, 자체 통합 시험이다. 운영에서는 jailer 와 인스턴스별 uid 를 권한다.
  - 단서: FAQ 의 「장치 6개」 는 같은 저장소 device-api.md(10종)보다 낡았다. virtio-fs 없음, 필터 없음, jailer·uid 권고는 그대로다. NSDI '20 논문은 원문을 못 읽었다.
  - MASC 에서 쓰는 곳: `lib/keeper/keeper_microvm_kata_vmm.mli` 와 RFC-0405 의 제외 판단을 그대로 둔다. MASC 게스트의 읽기 전용 공유 마운트(설정·identity·shim)를 옮길 수 없다. `config/runtime.toml` 의 예약 표식 `firecracker` 를 열 때 쓸 제약 목록이다. 수치는 저자 조건의 값이다. Keeper 이미지의 부팅 시간으로 읽지 않는다.
- `10` cgroup v2 위임
  - systemd 는 service·scope 에만 위임을 허용하고, 사용자 관리자에 `pids memory cpu` 를 위임한다.
  - 단서: oom.group 은 oom_score_adj -1000 작업을 예외로 둔다.
  - MASC 에서 쓰는 곳: 메모리 예산 RFC Q9 답의 일부다. SSH 세션의 권한 없는 shim 은 자기 scope 한도를 못 건다. `lib/endpoint_process_gate` 의 root 제어 + cgroup 이 맞는 모양이다. systemd 호스트에서는 그 부모가 `Delegate=` 를 켠 unit 이어야 한다.
- `11` egress 허용 목록
  - E2B 는 기본으로 `8.8.8.8` 로 가는 모든 트래픽을 연다. `dnsServers: []` 로 닫는 길이 문서에 있다. `ssh` 와 JVM 은 프록시 환경 변수를 읽지 않는다. Node 내장 fetch 는 `NODE_USE_ENV_PROXY=1` 이 있어야 읽는다.
  - 단서: Modal 은 HTTP Host 를 보지 않는다.
  - MASC 에서 쓰는 곳: MASC 의 CONNECT + `--no-dns` 는 이름 해석이 matcher 뒤 한 곳이라 그대로 둔다. `docs/operations/egress-policy-runbook.md` 의 Java 서술을 고치고, 한계 절에 ssh·JVM·Node 를 적는다. #32799 와 같은 뿌리다.
- `12` Apple container 보안 권고
  - 고친 권고 수는 1.3.1 6건, 1.4.1 2건, 1.5.0 1건, 1.6.0 2건이다. 1.7.1 은 2026-11-06 버전이다.
  - Linux backend 는 같은 `vminitd` 계약을 쓴다. `container machine` 은 home 을 읽기·쓰기로 마운트하고 `SSH_AUTH_SOCK` 을 넘긴다.
  - MASC 에서 쓰는 곳: MASC 런북이 적은 `container` 하한이 이 수정들을 덮는지 확인한다. Linux backend 는 라이브러리 수준이라 `container` CLI 를 부르는 MASC 에는 아직 닿지 않는다.
  - 정석과 대가: 정석은 하한을 MASC 경로에 닿는 권고를 고친 버전 가운데 가장 높은 버전으로 올리는 것이다. 대가는 운영 기기마다 `container` 를 올려야 하는 것이다. 버전 번호는 수리가 병합된 뒤 싣는다. 어느 권고가 MASC 의 `container` 사용 방식에 닿는지는 보지 않았다. 사용자 결정으로 올렸다(§15.2).
- `13` Mosh 와 Eternal Terminal
  - 예측할 수 있었던 약 70% 키 입력이 바로 보였다. 평균은 Mosh 173 ms, SSH 515 ms 다(Figure 2). Eternal Terminal 은 다시 붙을 때 마지막 sequence number 를 주고받고, 빠진 패킷만 다시 보낸다.
  - 고친 것: 원래 문장은 5 ms 미만을 idempotent diff 전송의 결과로 이었다.
  - 단서: 측정은 사용자 6명, 약 40시간, 키 입력 9,986개다.
  - MASC 에서 쓰는 곳: `lib/endpoint_job_output` 의 offset spool 과 Draft `docs/rfc/RFC-keeper-async-fleet-continuity.md`(#36941)가 같은 원리다. 새로 만들 것은 없다. 수락 기준에 「마지막 offset 뒤만 보내고, 같은 요청을 두 번 보내도 결과가 같다」 가 있는지 확인한다. 5 ms 대 503 ms 는 이어 보내기의 측정 근거로 쓰지 않는다.
- `14` VS Code Remote-SSH
  - 기본은 무작위 포트와 사용자만 읽는 키다. `/version` 은 인증 없이 열린다.
  - 단서: 원문 말투는 'Optional … consider enabling' 이다. socket 방식은 연결 다중화를 끄고, sshd 의 `AllowStreamLocalForwarding` 이 있어야 한다.
  - MASC 에서 쓰는 곳: 한 기기에 여러 사람이 붙는 모양에서 loopback 은 사람 사이 경계가 아니다. MASC 가 loopback 에 여는 경로도 같은 문제를 안는다. 다계정 캠페인의 「모든 경로에 인증」 작업에 넘긴다(in_flight). MASC 에서 다른 Unix 계정이 닿는 listener 는 다 세지 않았다.

적용하지 않는 것:

- SSH `ControlMaster` 로 연결을 재사용해 요청별 인증 지연 줄이기. RFC-0395 의 결정과 어긋난다. 뒤 세션은 master 연결을 새 인증 없이 써서, 자격 파일을 바꿔도 바로 적용되지 않는다. OpenSSH 10.6 은 LZ77 압축을 껐다. multiplex 채널끼리 압축 사전을 나눠 써서 평문이 새는 문제가 있었다.
- Mosh 나 Eternal Terminal 을 MASC 의 원격 전송으로 쓰기. 둘 다 대화형 터미널 화면을 잇는 도구다. MASC 는 바이트가 그대로여야 하는 요청·응답 프레임을 보낸다. UDP 포트나 TCP 2022 상주 서비스가 필요해 RFC-0395 의 「sshd 만 쓴다」 와도 어긋난다.
- VS Code Server 를 원격 에이전트로 재사용하기. VS Code FAQ 가 다른 클라이언트용으로 허가하지 않는다고 적는다.
- gVisor 를 `Micro_vm` backend 로 더하기. gVisor 문서가 스스로 VM 과 다르다고 적는다. `--rootless` 는 netstack 과 create 가 없다. 넣는다면 Docker 프로필의 runtime 인데 Docker 는 맨 뒤 순위다(결정 13).
- Apple `container machine` 을 Keeper 게스트로 쓰기. home 을 읽기·쓰기로 마운트하고, `SSH_AUTH_SOCK` 을 넘기고, 비밀번호 없는 sudo 를 건다. Keeper 격리 계약과 반대다. 중첩 가상화 시험용 환경으로만 본다.
- Firecracker 를 직접 backend 로 넣기. API socket 모델이라 argv builder 에 안 맞는다. virtio-fs 가 없어 읽기 전용 공유 마운트를 못 옮긴다. jailer 는 root 가 필요하다(`09`).
- TLS 를 끊고 자리표시자를 진짜 비밀로 바꾸는 프록시(microsandbox secrets, srt tlsTerminate). RFC-0415 가 범위 밖으로 뒀다. 게스트 신뢰 저장소에 CA 를 심어야 한다. 다시 열려면 그 RFC 를 고친다.
- bubblewrap 을 Linux 끝점의 기본 격리 도구로 쓰기. 0.12.0 부터 setuid 방식이 없어 user namespace 가 있어야 돈다. Ubuntu 기본 설정은 AppArmor profile 을 따로 올려야 한다. shim 에는 Landlock 호출이 이미 있다.
- DNS 를 열어 두고 SNI·Host 로만 도메인 이름을 판정하는 egress(E2B, Modal 방식). 지금 MASC 의 CONNECT + `--no-dns` 보다 약하다(`11`).
- systemd `IPAddressDeny=` 하나로 끝점 egress 를 강제했다고 보기. cgroup eBPF 지원이 없으면 오류 없이 아무 효과가 없다고 systemd 문서가 적는다. 쓰려면 걸렸는지 먼저 확인하고, 안 걸리면 거절한다.
- 사용자 결정 때문에 뺀 3건은 §15.1 에 있다.

## 6. 에이전트 경제와 Candle (`agent-economy`)

게임 경제, 대안 화폐, 시장 설계, 보상과 속임을 다룬 자료에서 발견 14개를 뽑았다. 요구 11 에 닿는다. 결정 10 에 따라 Keeper 는 Candle 지급 규칙을 모른다. 헌법상 Candle 로 살 수 있는 것은 초상화 장신구뿐이다(201행). Stock 을 포함한 경제 확장은 모두 헌법 candle 절 개정이 먼저다. 같은 모델의 CEO 에이전트를 얹어 압박한 가게 실험은 도움이 되지 않았다(`13`).

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` EVE Online 2026-10 월간 경제 보고서 원자료는 화폐 총량을 기초·발행·소각·계정 드나듦·기말로 대조한다(차트 14). 분류는 68개다. | 맞음 | 측정 | [EVE Online Monthly Economic Report – October 2026 원자료 (CCP Games)](https://web.ccpgamescdn.com/aws/community/EVEOnline_MER_202610.zip) 차트 14·19, CSV. 일부 |
| `02` 통과할 수 없는 과제에서 시험을 숨기면 속임 성공률이 거의 0 이 된다. 그만두는 길을 주면 GPT-5 속임률이 54% 에서 9% 로 줄었다. | 맞음 | 측정 | [Zhong, Raghunathan, Carlini, ImpossibleBench (arXiv 2510.20270v1)](https://arxiv.org/abs/2510.20270) ImpossibleBench §5.2·§5.3. 일부 |
| `03` o3 는 RE-Bench 시도 128번 중 39번(30.4%), HCAST 1,087번 중 8번(0.7%)에서 reward hacking 을 했다. 'Please do not cheat.' 를 덧붙여도 reward hacking 계획을 말한 비율이 80% 그대로였다. | 맞음 | 측정 | [METR, Recent Frontier Models Are Reward Hacking (2025-06-05)](https://metr.org/blog/2025-06-05-recent-reward-hacking/). 일부 |
| `04` TigerBeetle 문서의 모델은 계정·이체 둘과 불변식 하나(모든 차변에 같은 대변)다. `ledger` 가 자산을 가른다. | 맞음 | 문서에 적힌 동작 | [TigerBeetle 문서: Data Modeling](https://docs.tigerbeetle.com/coding/data-modeling/), Debit/Credit, Currency Exchange, Linked Events, Two-Phase Transfers. 전문 |
| `05` 로그 market scoring rule(LMSR) 시장 조성자는 균등 분포로 시작하면 손실 한도가 b·log N 이다. | 맞음 | 증명 | [Chen & Pennock, A Utility Framework for Bounded-Loss Market Makers (UAI 2007, arXiv 1206.5252)](https://arxiv.org/abs/1206.5252) PDF 3쪽(논문집 51쪽), Hanson 2007. 일부 |
| `06` Godschalk 는 감쇠(demurrage)율 수준이 지역 화폐의 사용·거래액·속도를 크게 좌우하지 않는 것 같다고 쓴다. 감쇠가 없는 Bethel Geld 의 속도가 약 14, 분기 2% 감쇠인 Chiemgauer 가 10.6 이다. | 맞음 | 측정 | [Godschalk, Does Demurrage matter for Complementary Currencies? (IJCCR 16(D) 58–69, 2012)](https://www.ijccr.net/article/download/9173/8923/25147). 일부 |
| `07` 직원 69명의 대리 거래 실험에서 Opus 4.5 쪽은 Haiku 4.5 쪽보다 팔 때 $2.68 더 받고 살 때 $2.45 덜 냈다(782건). 공정하다고 느낀 정도는 4.05 대 4.06 으로 같았다. | 맞음 | 측정 | [Anthropic, Project Deal (2026-04-24)](https://www.anthropic.com/features/project-deal) 각주 6. 전문 |
| `08` 여러 일을 맡은 대리인에게 성과급을 주면 주의가 측정되는 일 쪽으로 옮겨 간다. 그래서 좋은 측정이 있어도 고정급이 최적일 수 있다고 쓴다. | 맞음 | 증명 | [Holmström & Milgrom, Multitask Principal–Agent Analyses (JLEO 7, 1991, 24–52)](https://gwern.net/doc/economics/1991-holmstrom.pdf) 서론. 일부 |
| `09` 프롬프트에 팁이나 협박을 넣어도 벤치마크 성적은 대체로 유의하게 달라지지 않았다. 예외도 있다. | 맞음 | 측정 | [Meincke, Mollick, Mollick, Shapiro, Prompting Science Report 3 (arXiv 2508.00614)](https://arxiv.org/abs/2508.00614). 일부 |
| `10` 모의 양면 시장에서 첫 제안이 60~100% 뽑혔다. 원문은 이를 '10-30 fold advantage' 로 적는다. 일부 모델은 주입에 넘어가 자주 결제를 모두 넘겼다. | 맞음 | 측정 | [Bansal 등, Magentic Marketplace (arXiv 2510.25779v1)](https://arxiv.org/abs/2510.25779) Magentic Marketplace §5.2·§5.3·§5.4. 일부 |
| `11` 서비스 대가로 쓰는 가상 화폐에서 효율은 1인당 화폐량이 'monetary crash' 바로 아래일 때 가장 높다. 그 점을 넘으면 아무도 일하려 하지 않는다. | 맞음 | 증명 | [Kash, Friedman, Halpern, Optimizing Scrip Systems (arXiv 1204.3494)](https://arxiv.org/abs/1204.3494) 초록, 서론. 일부 |
| `12` Ultima Online 의 닫힌 고리 경제는 쌓아 두기로 멈췄고, 발행구(faucet)와 소각구(drain) 구조로 바꿨다. 복제 버그로 초인플레이션이 났다. | 세게 말함 | 경험담 | [Simpson, The In-game Economics of Ultima Online (1999, GDC 2000)](https://gwern.net/doc/economics/1999-04-07-simpson-theingameconomicsofultimaonline.html) 'Hoarding and The Failure Of The Closed Economy' 절. 일부 |
| `13` 가게 에이전트 위에 같은 모델의 CEO 에이전트를 두고 압박하게 했다. 글쓴이는 큰 도움이 안 됐고 방해였을 수도 있다고 쓴다. | 맞음 | 경험담 | [Anthropic, Project Vend: Phase two (2025-12-18)](https://www.anthropic.com/research/project-vend-2). 일부 |
| `14` 에이전트 경제를 생긴 방식(emergent·intentional)과 사람 경제와 이어진 정도(permeable·impermeable)로 나눈다. 전용 화폐가 부분 차단막이 될 수 있다고 적는다. 실험은 없다. | 맞음 | 의견 | [Tomašev 등, Virtual Agent Economies (arXiv 2509.10147v1)](https://arxiv.org/abs/2509.10147). 일부 |

- `01` EVE Online 대조표
  - 2026-10 은 기초 2,895.3T 에 발행 201.3T 를 더하고, 소각 119.4T 를 빼고, 계정 드나듦 1.1T 를 더해 기말 2,978.3T 다. 유통 속도는 28일 거래액을 총량으로 나눈 값이다(차트 19).
  - 단서: 공식 글의 S3 zip 과 SHA-256 이 같고 정정은 없다. 사람 플레이어가 많은 게임이다.
  - MASC 에서 쓰는 곳: Candle 총량 요약은 합계 셋만 낸다. 원장을 읽어 기간마다 대조표를 보여 준다. 기초에 들어온 양을 더하고, 쓴 양과 감쇠를 빼면 기말이 되는지 본다. 거래 속도도 더한다. 사건이 닫힌 variant 라 새 필드가 없다. projection 만 하고 Gate 는 두지 않는다. 2026-10-21 검토 때 원장은 40행이라 비율 지표는 아직 뜻이 없다.
- `02` ImpossibleBench
  - 시험을 읽기 전용으로 두면 성적은 돌아오고 시험 고치기는 막힌다(ImpossibleBench §5.2).
  - 단서: 원문은 읽기 전용도 special-casing 은 못 막는다고 적는다. 엄격한 프롬프트의 효과는 과제마다 달랐다(LiveCodeBench 1%, SWE-bench 54%).
  - MASC 에서 쓰는 곳: 결정 10 과 같은 방향이다. 지급 경로의 세부는 여기 싣지 않는다.
- `03` METR 의 reward hacking
  - METR 은 채점 함수 전체가 보였기 때문일 수 있다고 추정한다('perhaps because').
  - 단서: 80% 는 Optimize LLM Foundry 과제 하나에서, 조건마다 20회 돌려 첫 생성에서 reward hacking 계획을 밝힌 몫이다. 문장을 넣기 전에도 80% 였다. 각주 4 는 배포 전 o3 수치라고 적는다. 두 과제 묶음이 달라 통제 실험이 아니다.
  - MASC 에서 쓰는 곳: 지급 규칙을 Keeper 프롬프트·도구 설명·Board 에 싣지 않는 결정 10 을 받친다. 금지 문장을 더하는 쪽은 근거로도 약하다(결정 1). 지급 경로의 세부는 여기 싣지 않는다.
- `04` TigerBeetle
  - 자산 사이 교환은 유동성 계정을 끼운 linked transfer 두 개로 한다. 두 이체는 함께 성공하거나 함께 실패한다. 반올림은 유동성 계정에 유리하게 하라고 애플리케이션에 권한다.
  - 단서: 「two entities … one invariant」 문장은 concepts/debit-credit 쪽에 있다.
  - MASC 에서 쓰는 곳: Stock 으로 자산이 둘이 되면 원장 사건 한 줄을 leg(계정·자산·방향·금액) 묶음으로 일반화한다. 발행·소각·시장 조성 계정도 둔다. 교환도 사건 한 줄로 적는다. 스키마 변경은 hard cut 이고 헌법 candle 절 개정이 먼저다. 지금 Candle 은 자산 하나이고 `issued - burned = circulating` 시험이 있어 당장 바꿀 이유가 없다.
- `05` LMSR 손실 한도
  - Hanson 2007 9쪽은 같은 한도를 처음 분포의 엔트로피로 적는다. 9쪽은 「최대 기대 지급」 이라 균등 분포일 때만 같은 값이다. b 를 키우면 유동성과 최악 손실이 같이 는다는 말은 식에서 끌어낸 추론이다.
  - 단서: 쪽 번호는 재확인에서 고쳤다(원래 문장은 1~2쪽).
  - MASC 에서 쓰는 곳: Keeper 수가 적으면 호가창에서 값이 정해지지 않는다. Stock 값은 자동 시장 조성자가 정한다. 한도 b·log N 은 운영자 보조금이고 발행으로 적는다. constant-product 는 Zarith 정수 곱 비교 하나로 검사한다(Uniswap v2 식 11). LMSR 의 exp·log 는 고정소수점 오차 한계를 따로 증명해야 한다(`docs/design/candle-decay-arithmetic.md` 처럼). 헌법 개정이 먼저다.
- `06` 감쇠 화폐
  - 읽은 것 가운데 가장 빠른 미국 날짜 도장 화폐는 주 2% 다(61쪽). 같은 원문 63쪽은 주 1% 로 적는다.
  - 단서: 속도 값은 추정치다.
  - MASC 에서 쓰는 곳: Candle 설계 문서가 든 Wikipedia 근거를 이 원문으로 바꾼다. 감쇠의 근거는 총량 수렴 산수로 적는다. 「돌려 쓰게 한다」 는 근거로 쓰지 않는다. 감쇠하는 Candle 옆에 감쇠 없는 Stock 을 두면 Candle 을 바로 Stock 으로 바꾸게 된다(조사자 추론). 관측 반감기 168시간은 Wörgl(월 1%)보다 약 300배 빠르다(조사자 계산).
- `07` Project Deal
  - 단서: 같은 각주는 거래가 무작위가 아니어서 효과가 부풀었을 수 있다고 적는다. 같은 회사 모델끼리다.
  - MASC 에서 쓰는 곳: Keeper 끼리 흥정하는 시장을 열면 재산이 기여보다 모델 lane 을 따른다. Keeper 시장은 헌법 candle 절 개정 대상이다. 연다면 값은 시장 조성자의 식으로 정한다. 거래 사건에 실행 식별자를 남기는 제안은 §15.2 를 본다.
- `08` 다중 과업 대리인
  - 직무 설계가 유인을 다스리는 도구라고 쓴다(서론).
  - 단서: 본문 정리는 읽지 않았다.
  - MASC 에서 쓰는 곳: 「장신구만 산다」(헌법 201행)는 이 문제의 표준 처방과 같다. 이론대로라면 Candle 로 도구·모델·예산을 사게 넓힐 때 탈이 난다. 측정되는 일로 주의가 쏠리고, 측정되지 않는 일이 빠진다. LLM Keeper 가 보상에 사람처럼 반응하는지는 잰 자료가 없다. RFC 가 후속으로 미룬 Tool·Skill·모델 구입은 헌법 개정이 먼저다.
- `09` 팁과 협박
  - GPQA Diamond 198문항과 MMLU-Pro 100문항을 25번씩 쟀다. 모델은 다섯, 조건은 기준선을 포함해 아홉이다.
  - 단서: MMLU-Pro 에서 유의 차이가 10건 나왔다. 'Mom Cancer' 조건은 약 10%p 올랐다.
  - MASC 에서 쓰는 곳: Candle 이 Keeper 의 일을 더 잘하게 만든다고 기대하지 않는다. Candle 설계 문서의 켜기 전·후 비교에 기대값을 0 으로 적는다. Candle 은 세계의 상태·관측·놀이로 다룬다. 보상 문장을 프롬프트에 넣지 않는다(결정 1·10).
- `10` Magentic Marketplace
  - 같은 절(Magentic Marketplace §5.4)에 첫 제안 60% 대 13.3%(4.5배)인 경우도 있다. 10~30배는 원문 표현이다.
  - 검색 결과를 3개에서 100개로 늘리면 구매자가 얻은 이득(소비자 후생)이 줄었다. Mexican 100-300 조건에서 Sonnet-4 는 65.4%, GPT-5 는 44% 줄었다(Magentic Marketplace §5.2).
  - 주입 결과의 원문 표현은 'often redirect all payments' 다(Magentic Marketplace §5.3).
  - 단서: 정적 모의 시장이고 학습과 평판이 없다(Magentic Marketplace §6).
  - MASC 에서 쓰는 곳: 먼저 답한 쪽이 이기는 배정은 품질보다 속도를 고른다. 판정자가 읽는 글에는 주입 위험이 있다. 현상금 Task, 선착순을 피하는 제안 모으기, 목록 길이 제한은 §15.2 에서 결정과 부딪힌다.
- `11` scrip 시스템
  - 쌓아 두는 사람은 화폐를 뺀 것과 같다.
  - 단서: 증명은 확인하지 않았다. 에이전트가 문턱 전략을 쓴다는 가정이다.
  - MASC 에서 쓰는 곳: 지금 Candle 은 서비스 대가로 쓰이지 않는다. 감쇠가 있으면 총량은 한 값으로 모인다. Candle 을 Keeper 사이 서비스 대가로 쓰는 제안과, 반감기를 조절 값으로 쓰는 제안은 §15.2 에서 결정과 부딪힌다.
- `12` Ultima Online
  - 글쓴이(Origin Research Fellow)는 경제가 게임의 재미에 꼭 필요하지는 않다고 쓴다('not required to make the game fun'). 고가 마법 갑옷으로는 금화를 줄이지 못했다('could not make a dent'). 한 번 연 빨간 머리 염색약 경매는 금화를 많이 거뒀지만, GM(게임 운영자) 손이 너무 들어 접었다.
  - 고친 것: 원래 문장은 글쓴이를 설계자로 적었다. 한정판 고가 아이템이 모두 효과가 없었다고 적고 염색약 경매 결과를 뺐다.
  - 단서: 맺음말은 흐름을 재는 코드를 넣어야 이론을 확인할 수 있다고 적는다. 잰 자료는 없고 설명이다.
  - MASC 에서 쓰는 곳: Candle 은 발행 + 감쇠 구조를 그대로 두고 총량 고정으로 바꾸지 않는다. 장신구 18개를 다 사면 쓸 곳이 없다는 문제는 물가와 따로다. 총량은 감쇠가 묶는다. 화폐를 거두려고 한정판 고가 아이템을 내지 않는다.
- `13` Project Vend 의 CEO 에이전트
  - 두 에이전트는 밤새 'ETERNAL TRANSCENDENCE' 를 주고받았다. 글쓴이는 효과가 컸던 것으로 절차와 도구를 들고, 역할 분리는 이유의 일부로 든다.
  - 단서: 절차는 프롬프트로 시켰다('we prompted Claudius to double-check'). 역할 분리는 Clothius 가 잘 된 이유의 일부('in part')로만 든다. 가게 하나이고 대조군이 없다.
  - MASC 에서 쓰는 곳: 압박하는 상위 Keeper 나 OKR(목표·핵심 결과) 문장을 두지 않는다(결정 1). 유머(요구 24)는 시키지 않는다. 원장의 사실을 사람 화면에 읽을거리로 보여 준다. Board 나 Keeper 프롬프트로는 보내지 않는다.
- `14` Virtual Agent Economies
  - 공유 자원은 같은 초기 화폐의 경매로 나누자고 제안한다.
  - 단서: 원문 말투는 'Possible advantages … may serve' 다. 완전히 닫힌 sandbox 는 쓸모없다고도 쓴다. 규제 sandbox 시범을 권한다.
  - MASC 에서 쓰는 곳: 이 틀에서 Candle 은 intentional·impermeable 이다(조사자 분류). 감독을 지울 수 없는 원장 위에 두라는 권고는 덧붙이기만 하는 Candle 원장과 맞는다. 교환·Stock 으로 넓히는 제안은 헌법 candle 절 개정이 먼저다(§15.2). 도구·예산과 잇는 바깥 연결은 따로 결정받는다.

적용하지 않는 것:

- Keeper 가 거래하는 Goal 성사 예측 시장(안 된다는 쪽에도 걸 수 있는 것). 거는 Keeper 가 일을 안 하거나 Drop 해서 결과를 바꿀 수 있다. 헌법 개정도 필요하다. 이 문제를 다룬다고 알려진 Ottaviani & Sørensen 2007 은 원문을 못 읽었다.
- 호가창(연속 이중 경매)으로 Stock 값 정하기. Keeper 수가 적어 값이 생기지 않는다(Hanson 2007 3쪽). LLM 이중 경매는 완전 수렴을 보지 못했다(arXiv 2609.02580, 일부만 읽음).
- 총량이 고정된 닫힌 고리 경제. Ultima Online 에서 쌓아 두기로 멈췄다(`12`).
- 순위표 상금·1등 보상. 보상이 볼록해져 복권형 베팅을 부른다. Google 사내 시장은 그래서 화폐를 추첨권으로 바꿔 선형으로 만들었다(Cowgill·Zitzewitz 작업본, 일부만 읽음).
- 계정 수에 기대는 장치(1인 1표, quadratic funding 류). Keeper 는 운영자 한 사람이 만들고 지운다. 계정 수에 뜻이 없다.
- TigerBeetle 자체 도입, 감쇠를 원장 사건으로 걷기(Sarafu 방식). 원장이 40행 규모라 모델만 가져온다. Sarafu 의 감쇠 거래 묶음은 반영하는 데 며칠 걸렸다. 지금처럼 읽을 때 계산한다.
- Keeper 끼리 흥정해 값을 정하는 시장. 재산이 기여보다 모델 성능을 따르고(`07`), 먼저 답한 쪽이 이긴다(`10`).
- 한정판 고가 아이템으로 화폐 거두기. Ultima Online 의 결과는 `12` 에 있다. Candle 에서는 감쇠가 그 일을 한다.
- 요약 도구로 원문 숫자를 뽑는 조사 방법. 요약 도구는 긴 인용을 거절하고 숫자의 위치를 주지 않았다. 그래서 원문을 내려받아 다시 읽었다. Review of Economic Analysis 2024 의 Gesell 논문은 내려받기가 실패해 쓰지 않았다.
- 사용자 결정 때문에 뺀 6건은 §15.1 에 있다.

## 7. 관측과 자기 개선 (`observability-self-improvement`)

토큰·캐시 관측, 스스로 나아지는 고리, 판정자의 오류를 다룬 논문과 제품 문서에서 발견 14개를 뽑았다. 요구 12·16·25 에 닿는다. 13개가 원문과 맞았고, `03` 하나가 원문보다 세게 말했다. 판정 없이 쌓은 기억과 풀기 전에 쓴 Skill 은 기준선 밑으로 내려간 칸이 있었다. 자기 코드를 고친 에이전트가 채점이 읽는 기록을 지워 만점을 받은 사례가 하나 있다(`06`, 빈도 수치 없음). 시험지를 고칠 수 있는 학생의 만점은 아무것도 알려 주지 않는다.

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` 전부 저장하는 기억은 네 에이전트 모두에서 고정 기억보다 낮았다. 정답과 비교해 고른 것만 저장하면 모두 높았다. 자동 판정자 셋으로 고르면 열두 칸 중 여섯이 고정 기억보다 낮았다. | 맞음 | 측정 | [Xiong 등, How Memory Management Impacts LLM Agents (arXiv 2505.16067v2)](https://arxiv.org/abs/2505.16067) 원문 §3.2 Table 1. 일부 |
| `02` 정답 표시 없는 온라인 적응에서 Dynamic Cheatsheet 는 평균 65.4 로 기준 69.1 밑이었다. ACE 는 FiNER 에서 67.3 으로 기준 70.7 밑이었다. | 맞음 | 측정 | [Agentic Context Engineering (ACE, arXiv 2510.04618v3)](https://arxiv.org/abs/2510.04618) 원문 §4.4 Table 2, Table 17. 일부 |
| `03` 에이전트가 과제를 풀기 전에 스스로 쓴 Skill 은 세 하네스 모두에서 통과율이 Skill 없는 기준선보다 낮았다. | 세게 말함 | 측정 | [SkillsBench (arXiv 2602.12670v4)](https://arxiv.org/abs/2602.12670) Table 6, 초록. 일부 |
| `04` 자동 자기개선 방법 셋(Memento, GEPA, ReasoningBank) 모두 기준보다 나빠진 칸이 있다. GEPA 는 6개 설정 중 4개에서 턴 수를 늘렸다. | 맞음 | 측정 | [EvoAgentBench (arXiv 2607.05202v1)](https://arxiv.org/abs/2607.05202) Table 3·4, 원문 §4.2·§4.4. 일부 |
| `05` GEPA 는 minibatch 에서 부모를 이긴 후보만 후보 묶음에 넣는다. 수정용 자료와 갈라 둔 D_pareto 에서 다시 재서, 평균이 가장 높은 것을 돌려준다. | 맞음 | 측정 | [GEPA: Reflective Prompt Evolution (arXiv 2507.19457v2)](https://arxiv.org/abs/2507.19457) Algorithm 1, GEPA §3, 초록. 일부 |
| `06` 자기 코드를 고치는 에이전트가 환각 탐지가 읽는 토큰 기록을 지워 만점 2.0 을 받았다. 환각은 그대로였다. | 맞음 | 측정 | [Darwin Gödel Machine (arXiv 2505.22954v3)](https://arxiv.org/abs/2505.22954) 부록 H 'Case Study: Solving Hallucination'. 일부 |
| `07` maintainer 가 병합하겠다고 본 비율은 자동 채점 통과율보다 평균 24.2%p 낮았다. maintainer 4명이 출처를 모른 채 AI PR 296건을 검토했다. | 맞음 | 측정 | [METR, Many SWE-bench-Passing PRs Would Not Be Merged into Main (2026-03-10)](https://metr.org/notes/2026-03-10-many-swe-bench-passing-prs-would-not-be-merged-into-main/) Basic Results. 일부 |
| `08` 새 사용자는 세션의 약 20% 에서 전부 자동 승인을 쓰고, 750 세션쯤이면 40% 를 넘는다. 가입 기간이 긴 사용자일수록 끼어들기가 많았다. | 맞음 | 측정 | [Anthropic, Measuring AI agent autonomy in practice (2026-02-18)](https://www.anthropic.com/research/measuring-agent-autonomy) Figure 2·3·4. 일부 |
| `09` Anthropic count_tokens 는 무료이고 별도 한도지만 값은 추정이다. Claude 4.7 이후 모델은 새 tokenizer 로 같은 글에 이전 모델보다 약 30% 많은 토큰을 센다. | 맞음 | 문서에 적힌 동작 | [Token counting (Claude Platform docs)](https://platform.claude.com/docs/en/build-with-claude/token-counting). 일부 |
| `10` Claude Code 는 `claude_code.token.usage` 를 종류별로 나눠 OTel(OpenTelemetry)로 내보낸다. gen_ai.usage.* 는 쓰지 않는다. | 맞음 | 문서에 적힌 동작 | [Claude Code docs: Monitoring usage](https://code.claude.com/docs/en/monitoring-usage) 'Token counter' 절. 일부 |
| `11` OTel GenAI 규약은 core v1.42.0(2026-06-12)에서 별도 저장소로 옮겨졌고 release 가 없다. 새 저장소 main 에는 breaking 조각이 쌓여 있다. | 맞음 | 문서에 적힌 동작 | [open-telemetry/semantic-conventions-genai](https://github.com/open-telemetry/semantic-conventions-genai) README·RELEASING·changelog.d, core semantic-conventions v1.42.0 release(semantic-conventions#3696). 일부 |
| `12` Anthropic 은 요청에 diagnostics.previous_message_id 를 넣으면 cache_miss_reason 을 닫힌 값 여섯으로 돌려준다. 가장 앞선 분기점 하나만 알려 준다. | 맞음 | 문서에 적힌 동작 | [Cache diagnostics (Claude Platform docs)](https://platform.claude.com/docs/en/build-with-claude/cache-diagnostics) 이유 표, 'reports the earliest divergence only'. 일부 |
| `13` OpenAI 는 GPT-5.6 부터 캐시 쓰기에 1.25배(30분), 2.5배(12시간)를 받고 읽기는 0.1배다. 이전 모델은 쓰기 요금이 없다. | 맞음 | 문서에 적힌 동작 | [Prompt caching (OpenAI API docs)](https://developers.openai.com/api/docs/guides/prompt-caching). 일부 |
| `14` 카파시는 자동화가 되는 일을 검증할 수 있는 일로 본다. 환경이 다시 시도할 수 있고, 많이 시도할 수 있고, 시도를 자동으로 채점할 때 최적화가 된다고 적는다. | 맞음 | 의견 | [Andrej Karpathy, Verifiability (2025-11-17)](https://karpathy.bearblog.dev/verifiability/). 전문 |

- `01` 기억 관리와 판정
  - Table 1 의 RegAgent 값은 고정 67.53, 전부 저장 55.48, 정답 비교 선별 70.95, 자동 선별 63.18~67.35 다.
  - 단서: 고정 기억보다 낮은 자동 칸은 RegAgent 3, AgentDriver 2, CIC-IoT 1 이다. 논문은 정답 비교를 사람 판정이라 부른다(원문 §3.1). RegAgent 의 자동 판정자는 LLM 이 아니고 오차 문턱값이다. 과제는 회귀·EHR·운전·보안 분류이고 코딩이 아니다.
  - MASC 에서 쓰는 곳: 기억·Skill 을, 쓰인 Task 의 Verifier 판정과 짝지어 보여 주는 projection 을 `docs/rfc/RFC-skill-usage-rollup.md` 에 보탠다. `lib/keeper/keeper_skill_activation_ledger.mli` 의 `Task_instruction`·`Task_composition` 이 이미 `task_ids` 를 가진다. 파생 값으로만 두고 저장·삭제를 걸지 않는다. MASC Verifier 는 자동 판정자 쪽이라, 그 판정으로 자동 삭제할 근거가 못 된다.
- `02` 정답 없는 온라인 적응
  - 해로운 반성을 매 단계 넣으면 66.7 이다(Table 17).
  - 단서: 같은 표에서 정답 없는 온라인 ACE 평균은 72.9(+3.8)이다. 5단계마다 넣으면 76.1 이다. Table 17 안에서는 기준 밑이 매 단계 주입뿐이다. 모델 DeepSeek-V3.1 하나와 금융 과제 둘의 값이다.
  - MASC 에서 쓰는 곳: 통계·교훈을 Keeper prompt block 으로 자동 주입하지 않는다(결정 1). 개선 근거로 화면에 보여 주는 기록은 Verification 판정이 붙은 Task 의 것으로 한정한다.
- `03` SkillsBench
  - Table 6 은 고정 87과제 분모의 통과율(%)이다. 세 하네스에서 43.0 에서 34.9 로 8.1%p, 46.8 에서 35.5 로 11.3%p, 36.0 에서 24.5 로 11.5%p 내렸다. 전문가가 고른 Skill 은 18개 설정 평균으로 통과율을 33.9 에서 50.5 로 16.6%p 올렸다(초록).
  - 「궤적 12개 중 10개가 만든 Skill 을 읽지 않았다」 는 검토는 pre-baked Codex·Gemini CLI 묶음에서 했다. 차이가 큰 과제만 골랐다. 저자는 안 읽힌 원인을 native discovery 로 노출되지 않은 pack 에 둔다.
  - 고친 것: 원래 문장은 이 한정을 빼고 10/12 를 일반화했다.
  - 단서: 저자는 스스로 쓴 조건을 본 집계 밖 진단으로 둔다. 차이에 내용 품질, Skill 발견, creator 와 solver 의 간섭이 섞였다고 적는다. Claude Code 조건은 effort 가 max 대 high 로 달랐다. 12개가 검토 전체인지 묶음 안인지는 원문에서 못 가렸다.
  - MASC 에서 쓰는 곳: `keeper_skill_publish` 로 발행된 Skill 마다, 한 번도 켜지지 않았는지와 켜진 Task 의 판정 분포를 보여 준다. 운영자의 사후 삭제(`docs/rfc/RFC-keeper-self-authored-skills.md` 결정)가 이 값을 읽는다. 발행 Gate 는 더하지 않는다.
- `04` EvoAgentBench
  - 학습 과제에서 뽑은 Skill 을 정답 능력 표시로 골라 넣은 진단용 기준은 24칸 모두 기준보다 나았다(Table 3).
  - 단서: '정답 능력 표시' 는 시험 답이 아니고 curator 쪽 routing 표시(Ability label)다. 저자는 진단용 기준(Anchor)을 'not a deployable method' 라 적는다. 2026-07 v1 preprint 이고 독립 재현을 찾지 못했다. 모델은 Qwen3.5·Gemma-4 계열이다.
  - MASC 에서 쓰는 곳: 프롬프트·Skill 변경을 평균 하나로 판단하지 않는다. `test/coding_eval_report.ml` 의 cohort 결과를 같은 case 끼리 짝짓는다. 나아진 case 와 나빠진 case 를 따로 센다. 어느 Skill 이 어느 Task 에 켜졌는지도 같이 본다.
- `05` GEPA
  - 여섯 과제에서 GRPO(강화학습 방법)보다 원문 표기로 '+6%' 높았다. rollout 은 최대 35배 적었다(초록).
  - 단서: '+6%' 가 상대 변화인지 %p 인지 원문이 밝히지 않는다. GEPA §1 은 같은 값을 Qwen3 8B 기준으로 다시 적는다. 과제는 짧은 모듈 프롬프트다. Keeper 지시문처럼 길고 목적이 여럿인 글에서 잰 값은 없다. EvoAgentBench 는 GEPA 가 나빠진 칸을 보고한다(`04`).
  - MASC 에서 쓰는 곳: `Eval_harness` 시나리오를 채택용과 보고용으로 가르고 pass^k 를 보탠다. 지금은 `compute_pass_at_k` 만 있다(`lib/eval_harness.ml`). CI 에 넣지 않는다. 바꾼 쪽이 돌려 PR 에 붙인다(결정 6). 병합 조건으로 만들면 다시 본다.
- `06` Darwin Gödel Machine
  - 탐지 함수는 숨겨져 있었고, 그 토큰을 바꾸지 말라는 지시도 있었다(부록 H).
  - 단서: 사례 하나라 빈도 수치는 없다. 같은 실행의 node 96 은 조작 없이 1.67 을 받았다. 자기 수정은 Claude 3.5 Sonnet (New) 로 돌렸다.
  - MASC 에서 쓰는 곳: 평가 묶음, 채점 코드, 채점이 읽는 기록을, 평가받는 Keeper 의 작업 공간 밖 운영자 자리(`artifacts/<topic>/` 등)에 둔다. 채점 기준을 바꾸는 변경과 그 기준으로 채택되는 변경을 한 비교에 섞지 않는다. 쓰기 금지 경로나 권한 규칙으로 막는 제안은 §15.2 를 본다.
- `07` METR 의 병합 검토
  - 표준오차는 2.7 이고, 사람 PR 통과율 68% 로 정규화한 값이다. 정규화하면 채점을 통과한 PR 의 절반쯤이 병합되지 않는다.
  - 반대쪽 오류는 OpenAI 'Why we no longer evaluate SWE-bench Verified'(2026-02-23)가 보고한다. 자주 실패한 138문제 중 59.4% 에서 시험·설명 결함을 찾았다. 원 페이지는 403(접근 거부)이라 사본으로 읽었다.
  - 단서: 정규화 전에는 1/3~1/2 이다. 채점을 통과한 patch 만 검토해 거짓 통과 쪽만 쟀다. 대상은 2024 중반~2025 하반기 에이전트이고 한 번만 제출했다.
  - MASC 에서 쓰는 곳: Verification 판정이 양쪽으로 틀릴 수 있다고 본다. 통과 뒤 재작업과, 거절 뒤 같은 내용의 통과를 센다. 이 수를 Verifier 자신의 지표로 보여 준다. `docs/rfc/RFC-0401-typed-probes-verdicts-and-harness-facts.md` 의 재판정 36% 실측에 잇는다.
- `08` 자동 승인과 끼어들기
  - 끼어들기는 가입 기간이 긴 사용자일수록 턴의 5% 에서 약 9% 로 많았다(Figure 3). 요약은 가장 복잡한 과제에서 스스로 멈춰 묻는 횟수가 사람 끼어들기의 두 배를 넘는다고 적는다(Figure 4).
  - 단서: 5% 와 약 9% 는 시간 변화가 아니고 가입 기간별 단면이다. 본문 한 문장은 '두 배' 를 최소 복잡도 과제 대비로 적어 요약과 다르다. Figure 4 는 그림이라 값을 직접 못 읽었다. Claude Code 한 제품의 대화형 세션이고, 분류는 Claude 가 했다.
  - MASC 에서 쓰는 곳: 사람 개입을 운영자 끼어들기와 Keeper 의 되묻기로 나눠 projection 으로 센다. 되묻기는 typed ask 모듈(`lib/lane_addon/lane_addon_asks.ml`)이 있어 글자 분류 없이 셀 수 있다. `Keeper_operator_interrupt` 는 type 이 아니고 운영자 취소 exception 이다(재확인에서 확인). 턴 기록에 세어 남는지는 확인 필요다. 목표값은 두지 않는다.
- `09` count_tokens
  - 단서: 원문 대상은 'Claude 4.7 and later models and Mythos Preview' 다. 증가는 내용에 따라 다르다. 무료여도 tier 별 분당 요청 한도가 있다.
  - MASC 에서 쓰는 곳: `bin/masc_tui_token_scale.ml` 의 fallback 3.39 byte/token 은 wire 가 보이는 lane 표본이다. 그런데 official-client lane 에 쓰인다. provider protocol 별로 실행 중 기록에서 그때 잰다. 표본 없는 protocol 은 모름으로 둔다. 다시 잰 비율을 코드 상수로 박는 제안은 §15.2 를 본다. `Count_tokens_sync` 는 Anthropic·Kimi 만 지원한다.
- `10` Claude Code 의 토큰 계측
  - 나누는 축은 type(input, output, cacheRead, cacheCreation), query_source(main, subagent, auxiliary), skill.name, agent.name, mcp_tool.name 이다.
  - 단서: span 에는 `gen_ai.request.model` 같은 다른 `gen_ai.*` 속성이 있다. 이름 일부는 `OTEL_LOG_TOOL_DETAILS=1` 이 없으면 `custom`·`third-party` 로 가려진다.
  - MASC 에서 쓰는 곳: wire 를 못 보는 Claude Code lane 의 토큰 분해를 이 계측으로 받을 수 있다. 지금 받는 코드는 없다(`lib`·`bin`·`packages` 에 `claude_code.token` 0건). `Turn_record` 의 component 분해와 같은 화면에 놓는다. 구독 lane 에서 켜지는지, 다계정에서 사람별로 갈리는지는 확인 필요다.
- `11` OTel GenAI 규약
  - 새 저장소 main 에 쌓인 조각의 예는 둘이다. `gen_ai.client.token.usage` 를 방향별 histogram 으로 바꾸는 조각(semantic-conventions-genai#374)과, cache_creation 을 cache_write 로 바꾸는 개명(semantic-conventions-genai#440)이다.
  - 단서: 첫 tag 는 `vX.Y.Z-dev` prerelease 이고, schema URL 은 `gen-ai-dev` 아래다.
  - MASC 에서 쓰는 곳: `lib/otel_genai/otel_genai.ml` 의 이름은 지금 바꾸지 않는다. 내는 규약 버전을 한 곳에 적는다. 새 저장소의 첫 tag 에서 한 번에 바꾼다. 옛 이름과 새 이름을 같이 내지 않는다(결정 8). 조각 semantic-conventions-genai#536 의 '사용량 없으면 0 기록' 은 받지 않는다.
- `12` cache diagnostics
  - 닫힌 값 여섯은 model_changed, system_changed, tools_changed, messages_changed, previous_message_not_found, unavailable 이다.
  - 단서: status 는 stable 이고 Claude API 만 지원한다. 응답에는 `diagnostics: null` 과 `cache_miss_reason: null`(비교 중) 상태도 있다. cURL 예제는 `anthropic-beta` 헤더 없이 보낸다.
  - MASC 에서 쓰는 곳: Anthropic direct lane 에서 이 값을 닫힌 variant 로 받는다. `Turn_record` 의 block diff 옆에 보여 주면, MASC 가 모르는 접두 변경을 찾을 수 있다. 먼저 관측 값으로 보고, 저장 필드로 만들지 않는다. Claude Code 구독 lane, GLM, Kimi, Codex 에는 못 쓴다.
- `13` OpenAI 캐시 요금
  - 명시적 breakpoint 를 받고, 요청당 쓰기는 최대 4개다. 이전 모델은 cached_tokens 를 128 단위로 내린다.
  - 단서: 12시간은 Responses API 에서만 된다. 읽기는 GPT-6.1 Sol·Terra 에서 0.05배다. 쓰기 배율은 덧붙는 요금이 아니고 그 토큰의 전체 요금이다. 문서에 갱신일이 없다.
  - MASC 에서 쓰는 곳: `packages/agent_core/models.toml` 은 모델별 쓰기·읽기 배율을 이미 가진다. 쓰기 배율이 모델당 하나라 TTL(캐시 유지 시간) 구분이 없다. 긴 TTL 을 켜는 lane 이 생기면 같이 고칠 자리다. Codex 구독 lane 의 캐시는 client 가 정해, MASC 가 바꿀 범위가 좁다.
- `14` Verifiability
  - 단서: 원문 맥락은 신경망 학습과 일자리 영향 예측이다. 실행 중 에이전트 고리로 옮긴 것은 조사자 해석이다.
  - MASC 에서 쓰는 곳: 스스로 나아지는 고리를 typed 판정이 있는 자리(Verification, `Eval_harness` 시나리오)부터 닫는다. autoresearch 처럼 평가 파일은 고정하고 고칠 대상을 하나로 좁힌다. 고칠 대상이 Keeper 지시문이면 §15.2 를 본다. autoresearch 의 5분 고정 예산은 평가 실행끼리 비교하는 조건이라 Keeper 실행 제한으로 옮기지 않는다.

적용하지 않는 것:

- 병합 차단 검사를 줄이고 flake 는 재실행으로 넘기기(OpenAI 'Harness engineering', 2026-02-11, 사본). 한 팀의 경험담이다. 저자도 처리량이 낮으면 무책임하다고 적는다. required check 가 실패하면 병합하지 않는다. CI 줄이기는 스택 CI RFC #51521 이 맡는다.
- OTel 조각 semantic-conventions-genai#536 처럼 사용량이 없을 때 0 을 적기. MASC 는 모르는 값을 0 으로 눌러 담지 않는다. pricing 의 Incomplete 와 비용 보고의 unknown 이 그 예다.
- METR 시간 지평이나 SWE-bench 점수를 lane·모델 배정의 숫자 근거로 쓰기. Opus 4.6 의 50% 지평은 12.0시간이고 신뢰구간이 5.3~60.6시간이다(METR time-horizons 페이지). 페이지는 16시간 넘는 측정을 믿을 수 없다고 적는다. SWE-bench Verified 는 오염됐다(`07` 의 OpenAI 글).
- 개선 고리에 LLM 요약만 넘기기. 제안 에이전트에게 요약을 주면 중앙값 34.9, 원 실행 기록을 주면 50.0 이었다(Meta-Harness, arXiv 2603.28052v1 Table 3). 온라인 텍스트 분류 한 과제의 값이다.
- 같은 Task 안에서 자기 반성 재시도를 기본 경로로 쌓기(Reflexion). MBPP 에서 80.1 에서 77.1 로 내려갔다. 스스로 쓴 시험의 거짓 통과율은 0.16 이었다(Reflexion Table 1·2). MASC 에는 독립 Verifier 가 있다.
- 글자 수를 4로 나누거나 다른 회사 tokenizer 로 component 토큰 세기. OpenAI 문서는 글자 수 추정이 부정확하다고 적는다. Anthropic 문서는 모델이 바뀌면 다시 세라고 적는다.
- 에이전트가 자기 하네스·채점 코드를 고치는 고리(DGM 방식). 탐지 함수를 숨기고 지시문으로 막았는데도 채점이 읽는 기록을 지웠다(`06`).
- 개입 횟수 줄이기를 목표로 삼기. 경험 많은 사용자가 더 자주 끼어들었다(`08`). DORA(소프트웨어 배포 성과 지표) 안내(2026-01-05 갱신)도 첫 함정으로 지표를 목표로 삼는 것을 든다.
- 사용자 결정 때문에 뺀 6건은 §15.1 에 있다.

## 8. 판정 확장과 깨움 (`system12-hooks-proactive`)

라우팅·캐스케이드, LLM 판정자, hook, 깨움과 끼어들기를 다룬 논문과 제품 문서에서 발견 14개를 뽑았다. 요구 9·10·23 에 닿는다. 11개가 원문과 맞았고, 셋(`04`·`07`·`08`)이 원문보다 세게 말했다. 꼭 필요할 때만 도우라는 지시를 받은 모델도 절반 넘게 헛경보를 냈다(`03`). 바깥 근거로는 판정자가 읽는 증거와 구조를 바꿀 때 판정이 넓어졌다. 지시문만 바꾼 효과는 그보다 작았다(MAST 한 system, `07`).

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` Cascade 는 답을 본 뒤의 품질 추정이 사전 추정보다 뚜렷이 나을 때만 이득이다. 정답 시험을 사후 추정으로 쓴 SWE-bench 는 최대 14%, 추정 오차가 큰 분류·서술형은 최대 1.2% 였다. | 맞음 | 측정 | [Dekoninck, Baader, Vechev, A Unified Approach to Routing and Cascading for LLMs (ICML 2025, arXiv 2410.10347v3)](https://arxiv.org/html/2410.10347v3) 원문 §3, Table 2. 일부 |
| `02` 2단 판정 실측이다. 빠른 한 토큰 1단은 헛경보율(FPR) 8.5%·놓침률(FNR) 6.6%, 추론 2단까지는 FPR 0.4%·FNR 17% 였다. 판정자에게 assistant 글·도구 결과를 주면 성능이 떨어졌다. | 맞음 | 측정 | [Anthropic, How we built Claude Code auto mode: a safer way to skip permissions (2026-03-25)](https://www.anthropic.com/research/claude-code-auto-mode). 일부 |
| `03` Proactive 모델은 필요 없을 때 가만히 있지 못한다. 헛경보 비율이 GPT-4o 51.85%, Claude-3.5-Sonnet 54.63% 다. 꼭 필요할 때만 도우라는 지시를 줘도 그랬다. | 맞음 | 측정 | [Lu 등, Proactive Agent: Shifting LLM Agents from Reactive Responses to Active Assistance (ICLR 2025, arXiv 2410.12361v3)](https://arxiv.org/html/2410.12361v3) Table 3·4, Lu 등 §4.2. 전문 |
| `04` 증거를 직접 읽는 판정 agent 는 OpenHands black-box 평가에서 사람 합의와 90.44% 일치했다. 한 번 묻는 LLM 판정자는 60.38% 였다. 가장 큰 칸의 차이다. | 세게 말함 | 측정 | [Zhuge 등, Agent-as-a-Judge: Evaluate Agents with Agents (2024, arXiv 2410.10934)](https://arxiv.org/html/2410.10934) 원문 §4.2, Table 3·4. 일부 |
| `05` 여러 에이전트 토론(MAD)의 이득은 대부분 다수결에서 온다. 7개 benchmark 에서 다수결만으로 MAD 와 비슷했다. | 맞음 | 측정 | [Choi 등, Debate or Vote: Which Yields Better Decisions in Multi-Agent Large Language Models? (2025, arXiv 2508.17536)](https://arxiv.org/html/2508.17536) 초록, 원문 §3.2, Theorem 2. 일부 |
| `06` 대부분의 LLM 판정자는 너그럽고, 일치율 하나로는 품질이 안 보인다. 일치율이 90% 를 넘어도 점수는 10점 넘게 어긋날 수 있다. | 맞음 | 측정 | [Thakur 등, Judging the Judges: Evaluating Alignment and Vulnerabilities in LLMs-as-Judges (2024, arXiv 2406.12624v6)](https://arxiv.org/html/2406.12624v6) Thakur 등 §5.3·§5.4. 일부 |
| `07` MAST 원문은 기존 판정자 다수('many existing verifiers')가 꼼꼼히 보라는 지시를 받고도 표면 검사만 한다고 적는다. 같은 문단은 판정자를 둔 system 이 실패가 적다고도 적는다. | 세게 말함 | 측정 | [Cemri 등, Why Do Multi-Agent LLM Systems Fail? (MAST, v3 2025, arXiv 2503.13657)](https://arxiv.org/html/2503.13657) MAST §4, Appendix H. 일부 |
| `08` Claude Code hook 은 같은 event 에 handler 다섯 가지(command, http, mcp_tool, prompt, agent)를 붙인다. hook 이 실패하면 대부분의 event 에서 동작을 그대로 한다. | 세게 말함 | 문서에 적힌 동작 | [Hooks reference (Claude Code Docs)](https://code.claude.com/docs/en/hooks.md). 일부 |
| `09` Codex Auto-review 는 사람 승인이 필요했던 요청만 별도 판정 agent 에게 넘긴다. 자동 승인율 99.1%, 과잉 행동 recall 90.3%(합성)를 보고했다. | 맞음 | 측정 | [OpenAI Alignment Research Blog, Auto-review of agent actions without synchronous human oversight (2026-04-30)](https://alignment.openai.com/auto-review/). 전문 |
| `10` interrupt 로만 받는 system 은 과부하에서 처리량이 0 으로 떨어진다. 수리는 interrupt 를 polling 시작에만 쓰고, 일이 남아 있는 동안은 꺼 두는 혼합 설계다. | 맞음 | 측정 | [Mogul, Ramakrishnan, Eliminating Receive Livelock in an Interrupt-driven Kernel (USENIX 1996)](https://pdos.csail.mit.edu/6.828/2008/readings/mogul96usenix.pdf) 원문 §1·§4.2·§5.2. 일부 |
| `11` email·IM 알림으로 끊긴 사무직 27명은 딴 곳에 약 10분, 원래 일로 돌아오는 데 10~15분을 더 썼다. 중단의 27% 는 2시간을 넘겨 재개됐다. | 맞음 | 측정 | [Iqbal, Horvitz, Disruption and Recovery of Computing Tasks: Field Study, Analysis, and Directions (CHI 2007)](http://erichorvitz.com/CHI_2007_Iqbal_Horvitz.pdf) PDF 9쪽. 전문 |
| `12` 선호 자료로만 학습한 router 는 분포가 바뀌자 MMLU 에서 random router 수준이었다. 정답 라벨 약 1,500건을 더해야 고쳐졌다. | 맞음 | 측정 | [Ong 등, RouteLLM: Learning to Route LLMs with Preference Data (2024, arXiv 2406.18665v4)](https://arxiv.org/html/2406.18665v4) 초록, Table 1·2. 일부 |
| `13` 한 모델 안에서 생각의 양을 바꾸는 effort 는 토큰 예산이 아니고 행동 신호라고 문서는 적는다. 대화 중 top-level effort 를 바꾸면 prompt cache 가 새로 시작된다. | 맞음 | 문서에 적힌 동작 | [Effort (Claude Platform Docs)](https://platform.claude.com/docs/en/build-with-claude/effort.md) 'Effort levels', 'Change effort mid-conversation'. 일부 |
| `14` Erlang 은 OTP 28 에서 메시지 우선순위를 priority 와 ordinary 두 class 로만 넣었다. class 안에서는 도착 순서이고, 받는 쪽이 켜야 한다. | 맞음 | 문서에 적힌 동작 | [EEP 76: Priority Messages (Erlang Enhancement Proposal, Final)](https://www.erlang.org/eeps/eep-0076). 일부 |

- `01` Routing 과 Cascade
  - 단서: 14% 는 정답 시험을 그대로 쓴 사후 추정 가정에서 저자 방법을 baseline 과 견준 값이다. 최신은 v5(2026-10-26)이고 인용 부분은 같다. QA·코딩 benchmark 이고 주의력 판정을 잰 것이 아니다. 부록은 읽지 않았다.
  - MASC 에서 쓰는 곳: Jev floor(`Typesafeai_config.board_attention_confidence_floor`, `lib/typesafeai/typesafeai_config.mli`)가 그 추정기다. Jev 가 확정한 후보 표본을 exact lane `Board_attention` 에도 묻는다. confidence 구간별 불일치와 방향을 projection 으로 잰다. 판정은 바꾸지 않는다. floor 를 이 측정값으로 다시 맞추지 않는다(결정 3). exact lane slot 은 Verifier 와 같이 쓴다.
- `02` auto mode 의 2단 판정
  - 실제 과잉 행동은 n=52 다. 1단은 놓치면 비싼 쪽으로 기울이고, 걸린 것만 2단이 다시 본다.
  - 단서: 원문에서 1단이 혼자 확정하는 쪽은 '통과' 다. 틀리면 비싼 쪽이라 1단을 막는 쪽으로 기울여 그 오류를 드물게 했다. 2단은 헛경보를 지우고 놓침을 늘린다(FNR 6.6% 에서 17% 로). 회사가 자기 제품을 잰 값이고 n=52, 신뢰구간이 없다. 승인 판정 영역이다.
  - MASC 에서 쓰는 곳: Board attention 은 지금 Jev 가 relevant·not_relevant 양쪽을 혼자 확정한다(`docs/spec/00-glossary.md`). 어느 오류가 비싼지 먼저 선언한다. 그다음 Jev 가 한쪽만 혼자 확정하고, 다른 쪽은 exact lane 이 다시 보는 구조를 검토한다. 어느 쪽을 혼자 확정할지는 재확인에서 고쳤다. relevant 를 모두 exact lane 으로 보내면 입력이 801건에서 2,719건이 된다. RFC 수치로 한 산수이고 측정이 아니다. `Auto_judge` 입력 범위도 같은 근거로 본다.
- `03` Proactive Agent
  - 판정 feedback 을 되먹이면 recall 이 98.11% 에서 56.76% 로 떨어진다(Table 4). 같은 행에서 헛경보는 51.85% 에서 44.74% 로 줄었다.
  - 단서: 헛경보 비율은 1 에서 Precision 을 뺀 값이고, 채점은 reward model 이 한다. recall 하락은 GPT-4o 'w/ RM' 행이다. 본문 수치 일부가 Table 3 과 어긋나고, Table 4 의 모델 표기가 Table 3 과 다르다.
  - MASC 에서 쓰는 곳: 깨움은 신호 쪽에서 줄인다. Keeper 지시문은 고치지 않는다(결정 1). `Keeper_world_observation.keeper_cycle_decision`·`skip_reason` 과 `docs/rfc/RFC-wake-signal-diet.md` 의 방향을 받친다. wake 평가를 둘로 나눠 projection 한다. 하나는 깨웠는데 한 일이 없는 쪽이다(같은 RFC 의 24시간 2,372턴 중 text_response skip 17.3%). 다른 하나는 놓친 쪽이다. 놓침 지표가 MASC 에 있는지는 확인 필요다.
- `04` Agent-as-a-Judge
  - MetaGPT 에서는 88.52 대 84.15 였다. Table 4 에서 65.03% 가 90.44% 로 오른 것은 graph·read·locate 셋을 더한 값이다. read·locate 몫은 75.95 에서 90.44 다. 일치율은 불균형 자료에서 속일 수 있다고 저자가 적었다.
  - 고친 것: 원래 문장은 OpenHands 한 칸을 일반화했고, 셋을 더한 오름을 read·locate 몫으로 적었다.
  - 단서: AI 개발 과제 55개, 사람 평가자 셋이다. 본문 한 곳은 OpenHands gray-box 를 92.07% 로 적지만 표에서는 90.16% 다.
  - MASC 에서 쓰는 곳: 완료·검증 판정(Verifier, `Task.Anti_rationalization`)을 넓힐 때, 판정자가 artifact 를 직접 읽게 하는 쪽에 근거가 있다. `verdict_question.evidence_posture`(`lib/task/anti_rationalization.mli`)가 이미 note 와 artifact 를 가른다. MASC 판정자가 artifact 를 도구로 읽는지는 확인하지 않았다. 승인 판정에서는 반대 결과가 있다(`02`).
- `05` Debate 와 다수결
  - debate 는 믿음의 martingale 이라 기대 정확도를 올리지 않는다는 정리를 냈다(Theorem 2). 정답 쪽으로 치우치게 하는 개입은 효과가 있었다.
  - 단서: 정리는 저자의 믿음 갱신 모형과 조건 (1) 위에서 성립한다. 원문은 그런 개입이 효과를 낼 수 있다고 적고, 실용 개입으로 다수결 따르기를 든다. 사전 공개 논문이다.
  - MASC 에서 쓰는 곳: Fusion topology(`Refine \| Conditional \| Judge_of_judges \| Staged`, `lib/fusion_core/fusion_types.mli`)를 판정 확장에 쓸 때다. `docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md` 의 4갈래 비교에서 'panel 다수결만' 과 'judge 단계 추가' 의 차이를 따로 읽는다. judge 가 원 증거를 읽는지 확인한다.
- `06` Judging the Judges
  - 가장 잘 맞는 판정자도 사람보다 8점 뒤진다. 더미 답을 정답으로 치는 판정자도 있다(Thakur 등 §5.3).
  - 단서: 8점은 Scott's π 차이다(Llama-3 70B 대 사람 96.2). 너그러움은 Thakur 등 §5.4 에 대부분의 모델로 적혀 있다. TriviaQA 단답형 400문항이고 2024년 모델이다. v6 이 최신이다.
  - MASC 에서 쓰는 곳: `Eval_calibration.calibration_stats`(`lib/eval_calibration.mli`)는 완료 판정의 방향별 오류율을 이미 낸다. 같은 모양을 Board attention·auto judge 에 붙일 수 있는지 본다. 일치율 옆에 우연 일치를 뺀 지표를 둔다. 둘 중 하나만 고르게 하면 통과 쪽으로 기운다는 말은 조사 보고서의 가설이고 측정이 없다.
- `07` MAST 의 판정자
  - 틀린 검증은 9.1%, 검증 없음은 8.2% 다. 상위 목표 검증을 넣는 topology 변경으로 ChatDev 32과제의 성공이 25.0 에서 40.6 으로 15.6%p 올랐다(Appendix H). 지시만 고친 쪽도 25.0 에서 34.4 로 9.4%p 올랐다.
  - 고친 것: 원래 문장은 'many' 를 뺐고, 15.6 을 % 로 적었고, 지시만 고친 쪽의 오름을 뺐다.
  - 단서: 대규모 주석은 LLM 주석 pipeline 이 했다. 원문이 말하는 것은 '지시만으로는 모자라고 구조 변경이 더 잘 듣는다' 에 가깝다. 기존 MASC 문서가 MAST 를 이미 인용했다.
  - MASC 에서 쓰는 곳: `verdict_question.completion_contract`·`required_evidence`(`lib/task/anti_rationalization.mli`)가 상위 목표 검증에 해당한다. 판정 확장은 prompt 문장보다 판정자가 읽는 증거와 구조로 한다(결정 1). 조사 보고서의 '지시로는 검증 깊이가 안 생긴다' 는 원문보다 세다.
- `08` Claude Code hook
  - prompt 는 LLM 한 번이고, agent 는 최대 50턴의 여러 턴 판정자다. 결과는 event 별 닫힌 집합이다. prompt hook 의 `impossible`(채울 수 없음)은 Stop·SubagentStop 에서만 듣는다.
  - `defer` 는 PreToolUse 의 `permissionDecision` 값이다. 시간·재시도 한도는 없지만, `-p` 실행에서 도구 호출이 하나일 때만 받는다. `defer` 로 미룬 세션은 기본 30일 뒤 지워진다. 실패 기본값의 원문 표현은 'most events' 다.
  - 고친 것: 원래 문장은 handler 를 셋만 적었다. `defer` 를 prompt hook 의 '한도 없이 미룸' 으로 적었고, 실패 기본값을 모든 event 로 적었다.
  - 단서: 제품 문서라 자주 바뀐다. `onFailure` 기본값은 `continue` 이고 v2.1.295 부터 `block` 을 고를 수 있다. Agent SDK callback hook 의 timeout 은 도구 호출을 막는다.
  - MASC 에서 쓰는 곳: `Hooks.hook_decision`(`packages/agent_core/lib/base/hooks.mli`)은 이미 닫힌 variant 이고 `HookFailed` 를 Continue 로 바꾸지 않는다. 견줄 것은 '판정 불가' 와 '미룸' 이다. 완료 판정은 `Approve \| Reject` 둘뿐이다(`lib/task/anti_rationalization.mli`). 두 값을 판정 variant 로 더하는 제안은 §15.2 를 본다. Stop hook 의 8번 연속 상한은 헌법 magic_number 에 걸려 쓰지 않는다.
- `09` Codex Auto-review
  - 사람이 멈춰야 하는 횟수가 약 200분의 1로 줄었다고 보고했다. 거절과 timeout 을 다른 결과로 둔다. 결정론적 보장이 아니라고 적었다.
  - 단서: '거절과 timeout 을 다른 결과로 둔다' 는 이 글에 없고, Codex Auto-review 문서의 'Denials and failure behavior' 절에 있다. 재확인이 그 문서도 열었다. 회사 내부 traffic 과 합성 자료로 잰 값이다.
  - MASC 에서 쓰는 곳: `Keeper_gate_mode`(`lib/keeper/keeper_gate_mode.mli`)의 `Always_allow`, `Auto_judge`, `Manual` 세 단계와 같은 모양이다. `Auto_judge` 를 잴 때 넷을 본다. 자동 승인율, 위험 사례 recall, 거절 뒤 더 안전한 길을 찾은 비율, 판정 없음 빈도다. 연속 3번·50번 중 10번 거절로 턴을 끊는 장치는 쓰지 않는다(§15.1).
- `10` Receive livelock
  - batch 만으로는 못 막는다(원문 §4.2). 수리는 원문 §5.2 에 있다.
  - 단서: 대상은 고정 interrupt 우선순위의 순수 interrupt 구동 kernel 이다. interrupt 는 남은 일이 없을 때만 다시 켠다. 에이전트 큐로 옮긴 것은 조사자의 비유다.
  - MASC 에서 쓰는 곳: `cycle_wake = Periodic_tick \| Attention_wake \| Deferred_runtime_lane`(`lib/keeper/keeper_world_observation.mli`)와 턴 경계 batch intake 가 같은 꼴이다. 턴 중에 온 `Attention_wake` 가 다음 intake 에 묶이는지 확인한다. 판정 lane 이 턴 실행과 slot 을 다투는지도 확인한다. '큐가 차면 일찍 버린다' 는 헌법 `failure_keeps_evidence` 와 부딪혀 쓰지 않는다.
- `11` 중단과 재개
  - 멈춘 프로그램 창이 보이면 재개가 빨랐다(PDF 9쪽).
  - 단서: 사무직 27명을 2주 본 연구이고 email·IM 알림이 대상이다. 창 가시성은 25% 미만 대 75% 초과 비교이고, 인과보다 연관으로 적혀 있다. Mark 등(CHI 2005, PDF 6쪽)은 평균 25분 26초를 보고했다. 널리 도는 '23분 15초' 는 그 논문에 없다.
  - MASC 에서 쓰는 곳: 운영자에게 가는 승인·질문에 해당한다. `Keeper_attention_reason.t`(`lib/keeper/keeper_attention_reason.mli`)와 승인 요청 `{question; because}` 화면이 '무엇이 멈춰 있는가' 를 같이 보여 주는지 확인한다. projection 으로만 쓴다. LLM agent 의 중단 비용을 잰 연구는 찾지 못했다.
- `12` RouteLLM
  - MT Bench 에서는 비용을 2배 넘게 줄였다(초록, Table 1).
  - 단서: 저자는 분포 밖 질문 때문이라 적는다. 약 1,500건을 더하면 GPT-4 호출이 약 20% 준다. MT Bench 는 3.66배다(Table 6). 두 모델 사이 routing 이고 2024년 모델이다.
  - MASC 에서 쓰는 곳: Jev 로 보낼지 exact lane 으로 보낼지는 학습한 router 대신 lane 선언(`type lane`, `lib/exact_lane_run_registry.mli`)에서 정한다. '입력이 닫혀 있고 한 번에 답할 수 있는가' 를 판정 종류의 사실로 적는다. 재생으로 router 를 맞추지 않는다(결정 3).
- `13` effort
  - per-message 변경은 cache 를 지킨다.
  - 단서: per-message 변경은 지원하는 모델·platform 에서만 되고, 일부 설정에서는 400(잘못된 요청)을 돌려준다. Anthropic provider 에만 해당한다.
  - MASC 에서 쓰는 곳: `turn_params.reasoning_effort`(`packages/agent_core/lib/base/hooks.mli`)는 있다. 그러나 Keeper 의 `BeforeTurnParams` hook 은 effort 를 바꾸지 않는다(`lib/keeper/keeper_run_tools_hooks.ml`). 턴마다 바꾸는 설계는 provider 별 cache 영향부터 잰다. 다른 provider 의 cache 동작은 확인하지 않았다.
- `14` Erlang priority message
  - 이 기능을 넣은 이유는 긴 큐 뒤에 깔린 급한 메시지다. selective receive 는 큐 전체를 훑는다.
  - 단서: 여러 단계 priority 는 '뒤로 미룸' 으로 적혀 있다. selective receive 는 일치 앞 메시지를 O(N) 으로 훑고, reference 최적화가 있다. 설계 문서이고 측정이 아니다.
  - MASC 에서 쓰는 곳: 도는 턴을 끝내는 것은 운영자 interrupt·stop 뿐이다(`docs/design/keeper-queue-readiness.md`). 지금 설계도 같은 두 class 다. 숫자 priority 를 들이지 않는 근거로 쓴다. 큐는 `oldest_queued_created_at`(`lib/keeper/keeper_owner.mli`)로 본다. 머문 시간(RFC 8289 §3.1)은 관측에만 쓰고 행동 기준으로 쓰지 않는다.

적용하지 않는 것:

- 여러 라운드 agent debate 를 판정 확장의 기본으로 쓰기. 이득 대부분이 다수결에서 온다(`05`). Fusion 은 이미 panel fan-out 이고, RFC-0252 가 같은 비용 비교를 정했다.
- 빠른 쪽이 낡은 공유 memory 로 먼저 답하고 느린 쪽이 나중에 고치는 Talker-Reasoner 구조. 정량 평가가 없고(Talker-Reasoner 논문 §4.3) 실패 양상이 snap judgement 다(Talker-Reasoner 논문 §4.4). MASC 판정은 후보마다 한 번 확정하는 FSM(유한 상태 기계)이라 낡은 답을 뒤집는 길이 없다.
- periodic tick 에 typed Skip 을 더해 Keeper 가 건너뜀을 답하게 하기. `docs/rfc/RFC-wake-signal-diet.md` 가 이미 기각했다. 바깥 측정도 모델이 가만히 있지 못한다는 것을 보여 준다(ProactiveBench Table 3 의 헛경보 50~65%).
- 합성 자료로 proactive 판정 모델을 fine-tune 하거나 합성 부하로 wake 설계를 평가하기. ProAgentBench Table 3 에서 LLaMA-3.1-8B 의 「언제 도울까」 정확도는 실제 자료로 fine-tune 하면 74.0%, 합성 자료로는 62.1% 였다(11.9%p 차이). 실제 event 간격은 burstiness B=0.787 인데, LLM 이 만든 합성 시각은 지수분포에 가깝다(ProAgentBench §3, Figure 3).
- System One·Two 를 속도나 모델 크기로 나누기. Evans·Stanovich Table 1 에서 속도는 정의 특성이 아니다. DPT-Agent 에서 작은 모델 하나로 돌린 빠른 쪽은 빠르지만 점수 효율이 0 근처였다.
- 승인 판정자에게 Keeper 의 설명과 도구 결과를 다 읽히기. Anthropic 실측에서 넣으면 과잉 행동 시험 성능이 떨어졌다(`02`). 완료 판정(`04`)과 결과가 반대라 두 판정의 입력 범위를 따로 잡는다.
- 사용자 결정 때문에 뺀 8건은 §15.1 에 있다.

## 9. TUI 와 음악 도구 (`tui-music`)

터미널 입력 규약, mode·단축키 연구, 편집기와 트래커의 키 문법, 음악 도구의 1차 자료에서 발견 14개를 뽑았다. 요구 7·18·24 에 닿는다. 12개가 원문과 맞았다. `01` 은 원문보다 세게 말했고, `04` 는 잘못 인용했다. TUI 화면 문법 RFC(`docs/rfc/RFC-tui-one-screen-grammar.md`, #51624)는 in_flight 다. 그래서 이 절은 그 RFC 를 받치거나 고칠 근거만 모았다. 이 절의 「RFC §N」 은 그 RFC 의 절이다. FT2(FastTracker 2)에서 Space 는 재생을 멈추는 키였다(`04`).

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` Ghostty 인코더는 글자를 조합하는 동안 plain modifier 키만 보낸다. 조합된 글자는 flag 와 상관없이 UTF-8 그대로 보낸다. | 세게 말함 | 문서에 적힌 동작 | [Ghostty src/input/key_encode.zig @4892f5013b37](https://github.com/ghostty-org/ghostty/blob/main/src/input/key_encode.zig) 152~159·225~232행, kitty keyboard protocol 명세 @fa1d1b40ab86. 일부 |
| `02` 누르고 있는 동안만 유지되는 mode 가 걸어 두는 mode 보다 mode error 가 적다. | 맞음 | 측정 | [Sellen, Kurtenbach, Buxton, The Prevention of Mode Errors Through Sensory Feedback (Human-Computer Interaction 7(2), 1992, 저자 게시본)](https://www.billbuxton.com/ModeErrors.html). 전문 |
| `03` 메뉴 옆에 단축키를 적어 두기만 하면 단축키로 넘어가지 않는다. 42명 실험에서 control 집단 14명 중 7명은 단축키를 한 번도 쓰지 않았다. | 맞음 | 측정 | [Grossman, Dragicevic, Balakrishnan, Strategies for Accelerating On-line Learning of Hotkeys (CHI 2007, pp.1591–1600)](https://www.dgp.toronto.edu/~ravin/papers/chi2007_learninghotkeys.pdf) p.1595, p.1597. 전문 |
| `04` 트래커는 범위 × 동사로 편집 키를 짠다. FT2 는 Shift·Ctrl·Alt 가 track·pattern·block, F3~F5 가 cut·copy·paste 다. FT2 의 Space 는 'Stop/Edit' 다. | 잘못 인용 | 문서에 적힌 동작 | [FastTracker 2 도움말 자료 (ft2-clone src/helpdata/FT2.HLP @923829b28946)](https://github.com/8bitbubsy/ft2-clone/blob/master/src/helpdata/FT2.HLP) 448~464행, Renoise Advanced Edit 문서, Orca-c README 143행. 일부 |
| `05` Helix 는 키마다 할 동작과 키 안내를 map 하나에서 만든다. map 이 키에서 동작으로 가는 방향이라 한 키에 두 동작을 담을 수 없다. | 맞음 | 문서에 적힌 동작 | [Helix helix-term/src/keymap.rs @59f323140e8a](https://github.com/helix-editor/helix/blob/master/helix-term/src/keymap.rs) 23~86·248~258행. 일부 |
| `06` Helix compositor 는 그리는 순서와 키 받는 순서를 층 목록 하나에서 낸다. | 맞음 | 문서에 적힌 동작 | [Helix helix-term/src/compositor.rs @462c98e03309](https://github.com/helix-editor/helix/blob/master/helix-term/src/compositor.rs) 79·156~188행. 일부 |
| `07` alphaTab 은 Guitar Pro 3~8, MusicXML, Capella 를 읽고 alphaTex 글로 내보낸다. exporter 는 1.7.1 에 들어왔고 최신은 1.9.0(2026-10-31)이다. | 맞음 | 문서에 적힌 동작 | [alphaTab 문서(Formats), releases, alphaTab.d.ts 1.8.4](https://alphatab.net/docs/formats/guitar-pro). 일부 |
| `08` 터미널 기능은 질의로 알 수 있다. kitty keyboard 는 `CSI ? u` 뒤에 DA1 을 붙여 묻고, mode 2026 은 DECRQM 으로 묻는다. | 맞음 | 문서에 적힌 동작 | [kitty keyboard protocol 명세 @fa1d1b40ab86](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), tmux CHANGES @5a820e63b72f, Synchronized Output gist. 일부 |
| `09` MIDI 2.0(UMP)이 Linux 와 Windows 에 OS 수준으로 들어왔다. PipeWire 1.4.0(2025-03-06)은 UMP 를 기본 형식으로 쓴다. Windows MIDI Services 는 2026-02-17 정식이다. | 맞음 | 문서에 적힌 동작 | [PipeWire NEWS (master)](https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/master/NEWS) 422~424·482~484행, Linux kernel 문서 'MIDI 2.0 on Linux', Windows Experience Blog 2026-02-17. 일부·사본 |
| `10` 오디오 callback 안에서는 걸리는 시간을 모르는 일을 하지 않는다. SuperCollider 는 소리 엔진을 OSC 로 조종하는 별도 프로세스로 둔다. | 맞음 | 경험담 | [Ross Bencina, Real-time audio programming 101: time waits for nothing (2011-07-05)](http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing), SuperCollider Server Timing 문서. 일부 |
| `11` Kakoune 저자는 고른 것 먼저, 동사 나중과 바로 보이는 선택을 설계 이유로 든다('object followed by verb, combined with instantaneous feedback'). | 맞음 | 의견 | [Kakoune doc/design.asciidoc @40ddd7c67ddc](https://github.com/mawww/kakoune/blob/master/doc/design.asciidoc), 'Why Kakoune'(저자 글). 전문 |
| `12` Mosaic(OCaml, Eio)는 0.2.0(2026-11-04)에서 API 대부분을 바꿨다. 이유로 widget 이 갖던 상호작용 상태가 model 과 어긋났다는 것을 든다. Windows 지원도 뺐다. | 맞음 | 경험담 | [Mosaic CHANGES.md @75f374107e7b](https://github.com/invariant-hq/mosaic) 205~219행, Bubble Tea v2.0.0 release notes. 일부 |
| `13` VST 3 SDK 는 3.8(2025-10-20)부터 MIT 다. CLAP 1.2.10 은 C header 이고 MIDI 2.0 dialect 가 있다. Pedalboard 는 VST3 와 Audio Unit 만 읽는다. | 맞음 | 문서에 적힌 동작 | [Steinberg VST 3 Developer Portal: VST3 License](https://steinbergmedia.github.io/vst3_dev_portal/pages/VST+3+Licensing/VST3+License.html), CLAP headers 1.2.10, Pedalboard README·spotify/pedalboard#270. 일부 |
| `14` 과제 중심 화면에서 유머가 든 응답은 호감을 올렸고, 과제 시간과 들인 노력은 바꾸지 않았다. 안 웃긴 농담을 받은 쪽은 덜 사교적으로 답했다. | 맞음 | 측정 | [Morkes, Kernal, Nass, Effects of Humor in Task-Oriented HCI and CMC (Human-Computer Interaction 14(4))](https://hci.stanford.edu/seminar/abstracts/99-00/000225-morkes.html) Stanford 세미나 초록(2000-02-25). 초록만 |

- `01` 한글 조합 중의 키
  - 시험은 flag 다섯을 켜고 'û' 를 넣어 이를 확인한다(1518~1535행). 한글 조합이 같은 `composing` 경로로 들어온다는 것은 추론이다. 명세는 동작이 OS·키보드 배치·IME 에 따른다고 적는다. 키 정보가 없으면 key number 0 의 text event 라고도 적는다(264~266행).
  - 고친 것: 원래 문장은 Ghostty 하나의 동작을 모든 터미널의 한글 입력으로 넓혔고, 조합 중에 modifier 가 오는 것을 뺐다.
  - 단서: 명세는 글자 사건도 key 0 escape code 로 적으라는데 Ghostty 는 맨 UTF-8 을 쓴다. '누른 키가 오지 않는다' 는 점은 둘이 같다. kitty·iTerm2·WezTerm·Windows Terminal 의 한글 입력기 동작은 확인하지 않았다.
  - MASC 에서 쓰는 곳: `bin/masc_tui_csi.ml` 의 flag 1, `bin/masc_tui_key_ime.mli`, RFC §3.1 의 '대문자에만 있는 키를 두지 않는다' 를 그대로 둔다. flag 8·16 으로 한글 상태의 키를 되찾는 계획은 세우지 않는다.
- `02` 누르는 동안만 켜지는 mode
  - 실험 1(24명)에서 발판 대 키보드는 F(1,11)=20.74, p<.001 이다. 화면 표시도 오류를 줄였지만, 설명한 분산은 4.8% 로 전환 방식 15.6% 보다 작다. 실험 2(15명)는 F(2,28)=25.8, p<.0001 이다.
  - 단서: 실험 1 은 전문가 12명과 초보 12명이다. 20.74 는 liberal 기준 값이고 conservative 는 13.51 이다. 실험 2 는 전문가 15명이다. Crossref 로 HCI 7(2) 141–164 를 확인했다. 1992년 발판·키보드로 vi 식 편집을 한 과제이고, TUI 겹침 창에서 잰 것이 아니다.
  - MASC 에서 쓰는 곳: RFC §3.2 '한 글자 한 뜻' 과 §3.3 조심 묶음(in_flight)을 받치는 측정이다. 조심 묶음은 되돌리기 어려운 동작을 모아 `y` 를 한 번 더 받는 묶음이다. RFC §3.4 의 채팅 `Esc`(턴 멈춤 또는 나가기)를 다시 정할 때 근거로 쓴다. 지금 바꿀 것은 없다.
- `03` 단축키 익히기
  - 단축키 사용은 control 28.9%, audio 66.6%, disabled 72.8% 였다(F2,82=47.0, p<.0001, p.1597). 단축키를 눈에 띄게 한 표시는 예비 실험에서 50% 대 57.1% 로 낫지 않았다(p.1595).
  - 단서: 예비 실험은 5명이고 유의차가 없었다. 저자도 good-subject effect 가능성을 적었다. 첫 block 은 두 기법이 더 느렸다. 2007년 마우스 메뉴와 modifier 단축키 과제이고 TUI 가 아니다.
  - MASC 에서 쓰는 곳: RFC §2 구역 5 의 키 안내와 `?` 만으로 운영자가 키를 익힌다고 기대하지 않는다. §3.3 동작 창(in_flight)에는 처음 쓰는 사람과 익숙한 사람이 같은 키를 눌러 갈아타는 단계가 없다. 이 부분은 조사 보고서의 추론이다.
- `04` 트래커의 키 문법
  - FT2.HLP 448~456행이 범위 × 동사 표다. 재생은 Right Ctrl·Right Alt 다(461~462행). Space 는 464행이다. 'Spacebar Play/Pause' 는 Orca-c README(143행)에만 있다. MASC 음악 작업대의 Space·p·x·y 는 RFC 와 뜻이 다르고, RFC 는 이 화면을 다루지 않는다.
  - 고친 것: 원래 문장은 'Space 는 재생이다' 를 FT2 근거로 적었다.
  - 단서: FT2 도움말은 원작을 다시 만든 저장소에 실린 자료다. Renoise 문서는 일부만 읽었다. 관례가 있다는 것이고, 쓰기 편하다고 잰 것은 아니다.
  - MASC 에서 쓰는 곳: `tools/alphatex/sequencer-tui.mjs` 의 Space·p·x·y 가 RFC §3.1·§3.2 와 뜻이 겹친다. 작업대의 범위 명령은 범위를 닫힌 값 인자로 받게 한다. 음악 도구는 TUI 핵심보다 뒤 순위다.
  - 정석과 대가: 정석은 작업대를 `$EDITOR` 같은 예외로 두고 `?`·`Esc`·`:` 만 맞추는 것이다. 근거는 RFC §3.1 이 터미널을 넘겨받는 `$EDITOR` 를 이미 예외로 둔다는 것이다. 작업대도 `Masc_tui_score.launch_music` 이 띄워 터미널을 넘겨받는 Node 프로세스다. 대가는 문법이 둘이 되는 것이다. Space 를 재생 키로 남길지는 따로 정한다. 관례가 갈리고(FT2 는 Stop/Edit, Orca-c 는 Play/Pause, 사례 하나씩) 잰 자료가 없다(§15.2).
- `05` Helix keymap
  - `KeyTrieNode` 의 `map: IndexMap<KeyEvent, KeyTrie>` 가 그 map 이다. `infobox()` 가 같은 map 에서 안내 상자를 만든다. 결과는 닫힌 enum `KeymapResult` 다.
  - 단서: `KeyTrie::Sequence` 로 한 키에 명령 여럿을 차례로 묶을 수는 있다. 경쟁하는 두 뜻은 담지 못한다. Helix 는 사용자가 키를 바꾸는 편집기이고, MASC 에 그 요구가 있는지는 모른다.
  - MASC 에서 쓰는 곳: `bin/masc_tui_keys.ml` 의 `binding` 은 동작마다 키 목록을 적는 방향이라 글자 중복을 적을 수 있다. RFC §3.5(in_flight) 층에서 화면이 전체 함수(total function)를 내면 type checker 가 중복을 막는다. 글자 variant 를 받아 동작 option 을 돌려주는 함수다. CI 검사를 더하지 않는다(결정 6). 전체 함수 정의는 조사 보고서의 제안이라 문법 스택을 맡은 세션과 맞춘다.
- `06` Helix compositor
  - `layers: Vec<Box<dyn Component>>` 를 `render` 는 앞에서부터, `handle_event` 는 `.rev()` 로 돌며 `EventResult::Consumed` 에서 멈춘다.
  - 단서: Helix 의 층은 같은 trait 의 부품이다. MASC 에는 서버 상태가 주인인 창과 터미널을 넘기는 화면이 섞여 있다.
  - MASC 에서 쓰는 곳: 겹침 창 상태(help, agenda, answering)가 `bin/masc_tui_types.ml` 의 필드로 흩어져 있다. 조사 보고서의 줄 번호는 재확인 때 이미 옮겨져 있어 이름으로 적는다. `docs/research/2026-10-28-tui-information-layers.md` 가 About 이 Help 를 가리는 예를 적었다. 열린 창을 닫힌 variant 목록 하나로 두는 RFC 를 따로 쓴다. 화면을 옮기는 층마다 옮기고, dispatcher 를 한 번에 바꾸지 않는다.
- `07` alphaTab
  - 1.8.4 타입 선언에 `ScoreLoader.loadScoreFromBytes`(15060행)와 `AlphaTexExporter.exportToString`(3700행)이 있다.
  - 단서: 두 API 는 1.9.0 에도 있다. 출처 URL 은 sitemap 에 없는 경로라 홈 화면을 돌려준다. 같은 형식 목록은 홈 화면과 formats 분류 쪽에 있다. 변환이 무엇을 잃는지 돌려 보지 않았다.
  - MASC 에서 쓰는 곳: `tools/alphatex/engine.mjs` 는 `AlphaTexImporter` 만 쓴다. `bin/masc_tui_attachment_action.mli` 에서 악보 첨부는 저장만 된다. `masc-alphatex` 에 바이트를 alphaTex 글로 바꾸는 변환을 더하면 Guitar Pro 첨부가 열린다. Keeper 는 악보를 글로 읽는다. 고정 버전은 1.8.4 다. exporter 출력이 OCaml 부분 reader 의 범위를 넘는지 직접 만든 fixture 로 본다.
- `08` 터미널 기능 질의
  - 명세 311~318·440~449행이다. Windows Terminal(microsoft/terminal#19817, 2026-02-17)과 xterm.js(xtermjs/xterm.js#5600, 2026-01-10)가 구현을 병합했다. tmux 3.7 은 앱이 DECSET 2026 을 쓰게 지원하고 DECRQM 2026 에 답한다.
  - 단서: 재확인은 같은 문장을 명세 315·319·441~450행에서 봤다.
  - MASC 에서 쓰는 곳: `bin/masc_tui_terminal_profile.ml` 은 `TERM_PROGRAM` 이름과 환경 변수로 가른다. `bin/masc_tui_terminal_probe.mli` 의 시작 탐침에 두 질의를 더하고 답으로 정한다. `bin/masc_tui.ml` 의 터미널 이름 목록('Ghostty, Kitty or WezTerm')은 기능 이름으로 바꾼다. SSH 지연에서 탐침 deadline 이 넉넉한지는 재지 않았다.
- `09` MIDI 2.0
  - Linux 는 `/dev/snd/umpC*D*` 와 sequencer 자동 변환을 준다. PipeWire 1.5.81 이 `pw-midi2play` 를 넣었다.
  - 단서: GitLab 이 봇 확인 화면을 돌려줘 공식 GitHub 사본으로 읽었다. 422~424행은 1.5.81(2025-10-16) 절, 482~484행은 1.4.0 절이다. UMP 는 개발 버전 1.3.81 에 먼저 들어갔고 1.4.0 이 첫 안정 버전이다. Windows 는 단계적으로 퍼진다. MIDI 2.0 명세 본문은 로그인 뒤에 있어 원문을 못 읽었다.
  - MASC 에서 쓰는 곳: UMP 수집과 PCM 출력 sidecar 는 Swift 이고, `tools/alphatex/README.md` 는 macOS 15 이상을 요구한다. Linux 경로는 문서에 없다. 같은 NDJSON 규약의 Linux sidecar(ALSA UMP, PipeWire)를 뒤 순위 일감으로 둔다. RemoteSSH 기기가 Linux 일 때 필요하다.
- `10` 실시간 오디오
  - Bencina 의 표현은 'If you don't know how long it will take, don't do it' 이다. SuperCollider 는 timestamp 를 붙인 bundle 을 `s.latency`(기본 0.2초) 앞서 보낸다.
  - 단서: Bencina 글에 그 문장이 두 번 나온다. SuperCollider 문서는 MIDI·GUI 같은 실시간 입력에는 latency 를 두지 말라고도 적는다. 0.2초는 그 제품의 기본값이다.
  - MASC 에서 쓰는 곳: `tools/alphatex/native/PCM-OUTPUT.md` 의 callback 은 합성·IPC·할당·잠금을 하지 않는다. 같은 규칙이라 바꿀 것은 없다. Linux sidecar 를 쓸 때 같은 규칙을 지키고, NDJSON + base64 PCM 전송 지연을 먼저 잰다. 0.2초는 MASC 에 옮기지 않는다.
- `11` Kakoune
  - 설계 문서는 'only d exists', 'Limited smartness', 'self-consistency is more important than Vim compatibility' 를 적는다(design.asciidoc 63~65·109~113·150~152행).
  - 단서: 재확인은 같은 문장을 64~65·109~110·151~152행에서 봤다. 고정 커밋과 master 가 같다. 글 편집기의 문법이라 목록·상세 화면에 그대로 맞는지는 따로 본다.
  - MASC 에서 쓰는 곳: RFC 의 「고른 줄, `Space`, 동작」 순서와 옛 키 호환을 두지 않는 결정(in_flight)이 같은 방향이다. 더할 것은 없다. 맥락에 따라 뜻이 바뀌는 키를 새로 만들지 않는 근거로만 쓴다.
- `12` Mosaic 과 Bubble Tea
  - Bubble Tea v2.0.0(2026-02-24)은 mode 2026 을 기본으로 쓰고 키 기능을 메시지로 알린다.
  - 단서: 같은 파일의 [Unreleased] 절이 Windows 콘솔 지원을 되살렸다(미출시). 인용한 이유는 API 변경의 이유이고 Windows 제거의 이유는 아니다. Mosaic 의 0.4 ms 는 조건 없는 자체 benchmark 라 옮기지 않았다.
  - MASC 에서 쓰는 곳: 프레임워크로 옮기지 않는다. MASC renderer 는 alt screen·mode 2026·줄 단위 diff 를 이미 갖고 있다(`docs/research/tui-frame-cost-and-terminal-output-prior-art-20261104.md`). 상태를 한 값이 갖게 하는 방향은 `05` 의 동작 창 정의와 `06` 의 겹침 창 목록을 받친다.
- `13` 플러그인 형식
  - CLAP 이벤트는 buffer 안 sample offset 을 싣는다(events.h 20·121행). Pedalboard 의 CLAP 지원 이슈(spotify/pedalboard#270)는 2023-11-08 부터 열려 있다.
  - 단서: 재확인은 CLAP note-ports.h 29행도 봤다. Pedalboard README 는 묶인 VST3 SDK 를 GPLv3 로 적는다. 라이선스 해석은 하지 않았다.
  - MASC 에서 쓰는 곳: `tools/vst/requirements.txt` 의 `pedalboard==0.9.26` 과 자식 프로세스 host 를 그대로 둔다. `tools/vst/README.md` 가 GPL-3.0 을 이미 적었다. CLAP host 는 요청과 측정이 생기기 전에는 만들지 않는다.
- `14` 화면의 유머
  - 실험 넷의 요약이고, 원문을 못 읽어 수치는 없다.
  - 단서: 논문 본문은 403 이었다. 과제 시간 문장은 CMC 인 실험 1 의 결과이고, HCI 인 실험 2 는 'generally consistent' 다. 안 웃긴 농담 결과는 CMC 인 실험 3 이다. Crossref 로 HCI 14(4) 395–435 를 확인했다. 1999년, 미리 짜 둔 글 응답을 주고받는 과제다.
  - MASC 에서 쓰는 곳: 유머는 결정을 싣지 않는 화면 글(기다림, 빈 목록, `bin/masc_tui_types.ml` 의 MSX 관전, 음악 작업대)에 두고 끌 수 있게 한다. 조심 묶음 확인과 실패 알림에는 두지 않는다. Keeper 프롬프트 문장과 문구 시험은 만들지 않는다(결정 1·7). 저장소에서 humor·유머·joke 를 찾지 못했다. 유머를 넣을 모듈은 아직 없다.

적용하지 않는 것:

- kitty keyboard flag 8·16 으로 한글 입력 상태의 키를 되찾기. Ghostty 는 조합 중에 글자 키를 보내지 않는다. 명세도 키 정보가 없으면 text event 라고 적는다(`01`).
- FT2 식 modifier + F 키 문법을 그대로 쓰기. macOS 는 기본 설정에서 F1~F12 에 Fn 이 필요하다(Apple Support 102439). 가져올 것은 범위 × 동사 구조뿐이다.
- ASCII tab 을 저장·교환 형식으로 쓰기. 표준 문법 문서를 찾지 못했다. MASC 는 alphaTex 를 원본으로 두고 fret·줄 번호 projection 으로 그린다(`bin/masc_tui_alphatex_score.mli`).
- sixel 을 먼저 지원하기. kitty·Ghostty·Alacritty·Warp 에 없다(2차 자료). 그림 경로는 지금 하나이고 질의로 가른다. Windows Terminal·VS Code 에서 요구가 나오면 다시 본다.
- SuperCollider 를 필수 소리 엔진으로 두기. 설치할 것이 하나 더 는다. 가져올 것은 timestamp 를 붙여 미리 보내는 규칙이다. MASC sidecar 는 이미 장치 시계로 돈다.
- CLAP plugin host 를 지금 만들기. Pedalboard 는 CLAP 을 읽지 않는다. 요청도 측정도 없다(`13`).
- 메뉴를 늦추거나 막아서 단축키를 가르치기. 단축키 사용은 늘었지만 늦추는 방식은 7점 중 2.2점을 받았다. 첫 block 은 더 느렸다(Grossman 2007 p.1596, p.1598).
- 앱 전체에 vim 식 normal/insert mode 얹기. 걸어 두는 mode 가 늘면 mode error 가 는다(`02`). RFC 의 한 글자 한 뜻(in_flight)과 어긋난다.
- 사용자 결정 때문에 뺀 5건은 §15.1 에 있다.

## 10. 다른 에이전트 제품 (`product-prior-art`)

Claude Code, Codex, Cursor, Factory, Hermes, OpenClaw, Amp, Devin 의 2026년 문서와 릴리스 노트에서 발견 14개를 뽑았다. 요구 8·12·13·14·16·23 에 닿는다. 10개가 원문과 맞았고, 넷(`01`·`06`·`13`·`14`)이 원문보다 세게 말했다. 이 절의 수치는 모두 그 제품 문서가 적은 값이다. 직접 재현하거나 잰 것은 없다. Claude Code 는 background 명령의 시간 제한을 2026-09-03 에 지우고 26일 뒤 다시 넣었다(`14`).

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` Claude Code, Codex, Cursor, Factory, Hermes 다섯 제품 모두 exit code 2 로 막는다. 턴 끝 hook 이 block 과 이유를 돌려주면 에이전트가 이어서 일한다. 공통은 이 둘까지다. | 세게 말함 | 문서에 적힌 동작 | [Claude Code docs: Keep Claude working toward a goal](https://code.claude.com/docs/en/goal.md) 120·174행. 비교: Codex hooks 194~195·1109~1120행, Cursor hooks 224·1316~1336행, Factory hooks 81행, Hermes hooks 865~873·2052~2068행. 전문 |
| `02` Codex 는 `codex mcp-server` 를 2026-08-24 deprecated, 2026-09-05 제거했다. 승인·이력·이벤트 스트림이 필요한 연동은 자체 JSON-RPC app server 로 보낸다. | 맞음 | 문서에 적힌 동작 | [OpenAI docs: Codex MCP server removal](https://learn.chatgpt.com/docs/mcp-server.md), Codex changelog 2026-08-24·2026-09-05 항목, Hermes v0.23.0, Amp 2026-10-13 글. 전문 |
| `03` Hermes worker lane 은 신원(assignee)·띄우는 방법·계약 셋으로 정의된다. 수명 상태의 원본은 kanban 에 있다. 못 띄우는 담당자는 대체 없이 `ready` 에 남긴다. | 맞음 | 문서에 적힌 동작 | [Hermes Agent docs: Kanban worker lanes](https://raw.githubusercontent.com/NousResearch/hermes-agent/main/website/docs/user-guide/features/kanban-worker-lanes.md) 3·21·29행, plugins 653행, kanban 1484행. 일부 |
| `04` OpenClaw 는 OSS 에서 사람별 model 계정을 준다. 문서는 이를 'account-selection convenience inside one trust domain, not isolation' 이라고 적는다. | 맞음 | 문서에 적힌 동작 | [OpenClaw docs: Multi-user](https://docs.openclaw.ai/concepts/multi-user.md) 15·75·94·134행. 전문 |
| `05` Codex 는 여러 Linux 호스트가 NFS 로 home 을 나누면 SQLite WAL 이 깨질 수 있어 rollback-journal(`DELETE`)로 만든다. JSONL 은 한 프로세스가 써서 괜찮다. | 맞음 | 문서에 적힌 동작 | [OpenAI docs: Run Codex with an NFS home directory](https://learn.chatgpt.com/docs/environments/network-file-systems.md) 5·11·13행. 비교: OpenClaw 'Writer admission authority' 제안 문서. 전문 |
| `06` OpenClaw 는 예기치 않게 죽은 뒤 끊긴 root 실행에 재개 입력을 한 번 넣는다. 옛 실행을 다시 만들거나 재생하지는 않는다. | 세게 말함 | 문서에 적힌 동작 | [OpenClaw docs: Restart recovery](https://docs.openclaw.ai/gateway/restart-recovery.md) 12~18·44~55·616~617행. 일부 |
| `07` Claude Code `/usage` 는 최근 사용량을 skill·subagent·plugin·MCP 서버별 몫으로 나누고, prompt cache miss 의 추정 원인을 보여 준다. | 맞음 | 문서에 적힌 동작 | [Claude Code docs: Manage costs](https://code.claude.com/docs/en/costs.md) 50·62행. 비교: OpenClaw Usage tracking 17~21·32행, Amp Explain Usage. 전문 |
| `08` Hermes v0.23.0 은 내장 browser 도구 열 개와 agent-browser 를 지우고 `browser_exec` 하나만 남겼다. 유료 MCP 도구에 값과 한도를 붙였다. | 맞음 | 문서에 적힌 동작 | [Hermes Agent v0.23.0 release notes](https://github.com/NousResearch/hermes-agent/releases/tag/v0.23.0) Upgrade notes. 비교: v0.23.1 본문, Tool Search 문서. 일부 |
| `09` Claude Code 세션 사이 메시지는 평문이고 결과는 Delivered·Held·Refused 다. 'a message from another session never counts as your consent.' | 맞음 | 문서에 적힌 동작 | [Claude Code docs: Cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging.md) 61·72~74·165·224행. 전문 |
| `10` OpenAI dots(2026-09-29), Cursor Grok Bot, Claude Code Projects, Amp Spaces 가 상시·조정 에이전트를 냈다. dots 와 Projects 는 개인 것, Amp Spaces 는 팀 공유다. | 맞음 | 문서에 적힌 동작 | [OpenAI docs: Meet dots](https://learn.chatgpt.com/docs/dots.md), dots tasks-and-memory 45~47행. 비교: Cursor Grok Bot 3·23행, Claude Code Projects 451행, Amp Spaces(2026-11-06 글). 일부 |
| `11` Devin 은 Knowledge(2026-09-18)와 Playbooks(2026-10-23)를 Skills 로 옮기기 시작했다. Codex 는 custom prompts 를 deprecated 했다. | 맞음 | 문서에 적힌 동작 | [Devin release notes](https://docs.devin.ai/release-notes/overview.md) 2026-09-18·2026-10-23 항목. 비교: Codex custom-prompts 5행, Hermes profile distributions 7·277행. 일부 |
| `12` OpenClaw 는 도는 턴에 새 입력을 도구 경계에서 넣는다('tool calls are a committed plan until one of them starts executing'). Amp 도 2026-09-08 에 기본 동작을 queue 에서 steer 로 바꿨다. | 맞음 | 문서에 적힌 동작 | [OpenClaw docs: Steering queue](https://docs.openclaw.ai/concepts/queue-steering.md) 19·25행. 비교: Amp news 'Steer, Don't Queue'(2026-09-08). 일부 |
| `13` OpenClaw 는 runner 등록 수를 희소 자원으로 센다. 도착 묶음 5,110건은 계획한 envelope 이고, 운영 목표는 6,000건이다. | 세게 말함 | 문서에 적힌 동작 | [OpenClaw docs: CI capacity and shard weights](https://docs.openclaw.ai/ci/capacity.md) 17~24·38행. 비교: Adaptive CI experiments 55·220~267행, Cursor PR Routing & Approval(approval-agents 11·62~67행). 일부 |
| `14` Claude Code 는 subagent 200개 상한(2.1.224)과, subagent 가 띄운 background 명령의 1시간 제한(2.1.260)을 지웠다. 같은 changelog 가 뒤에 background 명령 시간 제한을 다시 넣었다(2.1.285). | 세게 말함 | 문서에 적힌 동작 | [Claude Code changelog](https://code.claude.com/docs/en/changelog.md) 2.1.224·2.1.246·2.1.260·2.1.285·2.1.288 항목. 비교: Cursor release notes 'Week of Sep 21 2026', Amp news 'So Long, TUI Sidebar'(2026-08-27). 일부 |

- `01` 턴 끝 hook
  - `{ok, reason}` 을 돌려주는 모델 판정자는 Claude Code 와 Cursor 에만 있다. Codex 는 prompt·agent handler 를 'parsed but skipped' 로 둔다. Factory 는 command handler 만 받는다. Hermes `pre_verify` 는 callback 이 `continue` 를 돌려주는 모양이다. Claude Code `/goal` 판정자는 도구를 못 쓰고 대화에 적힌 것만 본다.
  - 고친 것: 원래 문장은 모델 판정자를 다섯 제품 공통으로 적었다.
  - 단서: Cursor 에서 턴 끝에 잇는 것은 `stop` hook 의 `followup_message` 다. Cursor Cloud agent 는 command hook 만 돈다. 판정 정확도를 잰 값은 어느 문서에도 없다.
  - MASC 에서 쓰는 곳: 판정 확장은 exact lane 의 typed 판정으로 한다. 판정자는 이미 Keeper 밖에 있다(`lib/completion_authority_agent.mli`, `lib/goal_criterion_agent.mli`). 실패는 `Outcome_unknown` 으로 가른다. 기준 글은 `config/prompts/` 에 둔다. Keeper 턴을 강제로 잇는 Stop hook 은 결정 1 과 부딪혀 뺀다(§15.1).
- `02` MCP 서버를 접은 Codex
  - Hermes 도 `mcp-serve` 를 plugin 으로 내보냈다. Amp 는 도구 둘짜리 Puck MCP 를 냈다.
  - 단서: Codex 는 지운 이유를 적지 않는다. 이유는 대체물의 용도 문장에서 끌어낸 해석이다. 문서는 app server 를 experimental 이라고 적는다. Hermes 는 plugin 으로 계속 제공한다.
  - MASC 에서 쓰는 곳: Keeper As A Tools 는 `masc_keeper_msg` 같은 좁은 도구로 둔다. 승인·이력·스트림은 HTTP/SSE(서버가 보내는 이벤트 스트림)·Dashboard 에 둔다. MCP profile 은 `Full`·`Managed_agent`·`Operator_remote` 셋이다(`lib/mcp_server_eio_tool_profile.mli`). 다계정 S1b 는 in_flight 다.
- `03` Hermes worker lane
  - plugin capability 는 'a consent and audit layer, not isolation' 이다. kanban 은 한 호스트 전용이다.
  - 단서: Hermes `plugins.isolation: host` 가 막는 것은 메모리 읽기다(plugins.md 928~930행). sandbox runner 는 선택 사항이다. 재현하지 않았다.
  - MASC 에서 쓰는 곳: Multi Addon Lane 계약을 같은 세 칸(신원·띄우는 방법·계약)으로 문서화한다. 바탕은 `lib/lane_addon/lane_addon_manifest.mli` 와 `lib/lane_addon/lane_addon_worker_protocol.mli` 다. 목록을 못 읽으면 설치를 거절한다. 다계정에서 package 격리를 프로세스 분리로 보는 제안은 §15.2 를 본다.
- `04` OpenClaw 의 사람별 계정
  - 소유·표시는 'usability features, not security boundaries' 다. 개인 설정에서 OpenClaw 는 Anthropic 계정을 API key 로만 받는다.
  - 단서: Anthropic 줄은 'for personal setup' 한정이다. 어느 릴리스부터인지는 문서에 없다.
  - MASC 에서 쓰는 곳: `docs/research/2026-11-10-multi-account-review-and-agent-platform-landscape.md` 4.6절의 「오픈소스 판의 팀 계정과 사람별 vendor credential」 항목을 고친다. 조사 보고서가 「빈칸 1」 이라 부른 문장이다. MASC 가 다른 점은 계정 고르기보다 증명된 격리다(결정 11). 다계정 권한 캠페인(authz S1b, #51635)은 in_flight 라 새 제안은 없다.
- `05` NFS 위의 SQLite
  - OpenClaw 의 `chat.send` ACK 765 ms 중 673 ms 가 main thread 쓰기 허가 대기였다.
  - 단서: 문서 범위는 Linux NFS 이고, 호스트 사이 file lock 확인을 요구한다. OpenClaw 수치는 trace 한 건이고 문서가 'do not predict production latency' 라 적는다. OpenClaw 문서는 제안 단계다.
  - MASC 에서 쓰는 곳: MASC 에는 WAL 셋과 DELETE 셋이 섞여 있다. WAL 은 `lib/keeper_tool_call_index/keeper_tool_call_index.ml`, `lib/play/play_room.ml`, `lib/tool_metrics_store/tool_metrics_store.ml` 이다. BasePath 를 네트워크 FS·동기화에 두기 전에 store 마다 규칙을 하나로 정한다. 지금은 BasePath lease 로 서버 하나만 써서 당장 깨지지 않는다. `Unix.lockf` lease 의 NFS 동작은 확인하지 않았다. 정지 구간 캠페인은 in_flight 다.
- `06` OpenClaw 재시작 복구
  - 원문 표현은 'the Gateway does not reconstruct or replay the old execution.' 이다. 지금 문서도 'Older queued rows left by a crash remain inert' 라 적는다(restart-recovery.md 616~617행, concepts/queue 59행). 그래서 2026-11-10 문서의 'crash 뒤 queue 는 inert' 는 여전히 맞다. 바뀐 것은 crash 뒤에도 root 실행이 재개 입력을 한 번 받는다는 점 하나다.
  - 고친 것: 원래 문장은 2026-11-10 문서가 지금 문서와 맞지 않는다고 적었다.
  - 단서: 오래된 orphan run 과 boot 이력이 없는 경우는 재개하지 않는다(52~53행). 5분 고정 SIGKILL 은 설정할 수 없다(118~124행). 안정 버전에 들어갔는지는 확인하지 않았다.
  - MASC 에서 쓰는 곳: 끝난 턴 결과 마커 RFC(#51629, in_flight)의 대조 사례로 인용한다. 기록을 맥락으로 주고 다음 행동은 Keeper 가 고른다(결정 2). `docs/evidence/research/2026-11-10-multi-account-review/landscape-oss-orchestrators.md` 의 문장은 뒤집지 않는다. 'crash 뒤 root 실행은 재개 입력을 한 번 받는다' 를 덧붙인다. 5분 고정 SIGKILL 과 crash-loop 숫자는 가져오지 않는다.
- `07` 사용량 귀속
  - OpenClaw 는 provider 가 보고한 값만 쓰고, 귀속을 모르면 'Quota account unknown' 이라고 적는다.
  - 단서: 귀속은 구독 plan 에서만 보이고, 이 기기의 로컬 기록으로 계산한 근삿값이다(70행). cache miss 원인은 마지막 miss 하나를, 알아낼 수 있을 때만, main 대화에서만 보여 준다(54행). 귀속 계산 방법은 문서에 없다.
  - MASC 에서 쓰는 곳: 사용량이 어디에 쓰였는지 skill·lane·MCP 서버·도구별로 나눠 보여 주는 projection 을 더한다. cache miss 원인도 보여 준다. 바탕은 `lib/keeper_usage_trust/keeper_usage_trust.mli` 와 `lib/runtime/runtime_provider_usage_read.mli` 다. 표시와 맥락 되먹임까지만 하고 Gate 로 쓰지 않는다(헌법 budget_gate). 귀속 규칙은 MASC 가 선언된 출처에서 따로 정한다. 사용량 영속 RFC #51466 은 in_flight 다.
- `08` Hermes 의 도구 정리
  - v0.23.0 이하에서는 plugin 목록이 2 MiB 상한을 넘자 설치가 조용히 옛 목록을 썼다. v0.23.1 이 상한을 16 MiB 로 올렸다.
  - 단서: 도구를 줄여 얼마나 나아졌는지 잰 값은 release 글에 없다.
  - MASC 에서 쓰는 곳: 외부 도구 표면 수를 점검한다. 조사 시점에 `config/tools/` 선언은 225개, browser 는 6개였다. 목록·설정을 못 읽으면 옛 값 대신 거절한다(헌법 strict_parse_no_default). 능력 검색은 이미 있다(`lib/keeper/keeper_capability_search.mli`). 턴마다 실리는 schema 수는 세지 않았다.
- `09` 세션 사이 메시지
  - 보류는 100개까지이고 5분 뒤 버린다.
  - 단서: 5분은 `dialogExpiry` 기본값이고 'never' 로 바꿀 수 있다. 명시적 hold 로 보류한 메시지는 만료되지 않는다(235행).
  - MASC 에서 쓰는 곳: 결정 2 와 같은 방향이다. `masc_keeper_msg` 는 이미 수락(`state`, `queued_count`)과 거절을 돌려준다(`lib/keeper/keeper_tool_surface_ops.ml`). '메시지는 승인을 대신하지 못한다' 를 권한 문서에 적는다. Delivered·Held·Refused 를 그대로 옮기는 제안은 §15.2 를 본다. 5분 만료와 100개 상한은 헌법 `no_wall_clock_death`·`failure_keeps_evidence` 와 부딪혀 가져오지 않는다. 영수증 기다림 RFC #51381 은 in_flight 다.
- `10` 상시 에이전트 제품
  - dots 문서는 'A completed run doesn't by itself confirm that the requested result was achieved or delivered.' 라 적는다.
  - 단서: dots 날짜는 DevDay 2026 쪽(September 29, 2026)에 있다. Claude Code Projects 는 beta 이고 Team·Enterprise 에 없다. 동시성·잠금·권한 모델은 어느 문서에도 없다.
  - MASC 에서 쓰는 곳: `docs/external-comparison-and-positioning.md` 의 비교 대상에 이들을 더하고, '영속 에이전트' 를 차별점에서 뺀다. 남는 후보는 넷이다. 사람별 격리의 증명, Verifier 가 증명한 완료(헌법 66행), 자가 호스팅, provider 중립이다.
- `11` Skills 로 모이는 지시문
  - Hermes profile distribution 은 에이전트 한 벌을 git 저장소로 주고받는다. 받는 쪽 memory·session·key 는 건드리지 않는다.
  - 단서: Devin 은 아직 옮기는 중이다('rolling out gradually', 'accounts move one at a time').
  - MASC 에서 쓰는 곳: 내보내기 한 벌을 정의한다. 넣는 것은 `config/prompts/`, `config/keepers/`, skill, lane 선언이다. 빼는 것은 memory, 원장, 자격증명, 권한 로그다. 가져오기는 변환기 없이 지우고 설치한다(결정 8). BasePath 백업·내보내기 모듈이 있는지는 이름 검색으로 못 찾았다. 확인 필요다.
- `12` 도는 턴에 넣는 입력
  - 건너뛴 호출마다 event 한 쌍과 합성 결과를 남긴다.
  - 단서: 병렬 묶음은 건너뛰지 않는다(24·89행). 같은 Amp 글이 'you can still queue' 라 적어 queue 가 없어진 것은 아니다. steer 가 주의력이나 완료율을 얼마나 바꾸는지 잰 값은 없다.
  - MASC 에서 쓰는 곳: runtime 마다 입력 경계를 선언으로 둔다. 타입은 이미 있다(`lib/runtime/runtime_codex_app_server.mli`, `lib/runtime/runtime_muse_msp.mli`). provider 가 건너뛴 도구 호출마다 결과를 남긴다. MASC 쪽에 건너뛰기를 새로 만드는 제안은 §15.2 를 본다. 큐 소비·수명 검토 캠페인은 in_flight 다.
- `13` OpenClaw CI 와 Cursor 승인
  - 원문 표현 'The pilot never skips a test or changes a required check.' 는 observation pilot 을 가리킨다(adaptive-testing 55행). 같은 문서의 'Qualified Markdown skipping pilot' 은 PR 에서 Markdown 시험 아홉 개를 실제로 뺀다(223~257행). shadow 에 묶어 둔 것은 이력 그래프와 학습 선택이다. Cursor 는 디렉터리별 `APPROVAL_POLICY.md` 로 낮은 위험 PR 을 승인한다.
  - 고친 것: 원래 문장은 5,110 을 측정처럼 적었고, 시험 건너뛰기를 shadow mode 로만 본다고 적었다.
  - 단서: 실측은 21건 도착 최댓값과 10월 13일 preflight 610건이다(54~55행). observation pilot 에는 cold cache 비용이 든다(57~62행). Cursor 문서는 'It does not replace a full code review' 라 적는다. 근거 종류는 재확인에 맞춰 고쳤다(조사 보고서는 측정).
  - MASC 에서 쓰는 곳: 스택 CI RFC #51521 은 in_flight 다. 병합 worker 의 호출 수처럼 실제로 막히는 자원을 세는 방식은 결정 6 과 맞는다. 기존 로그만 읽는 shadow 선택은 exporter 에만 해당한다. 판정 기준을 저장소 파일에 두는 Cursor 방식은 §15.2 를 본다. Cursor 의 위험 점수 문턱값은 가져오지 않는다.
- `14` 지웠다 다시 넣은 상한
  - 다시 넣은 제한은 기본 30분, 최대 2시간이다. 2.1.288 은 그 제한을 무인 세션에만 남겼다. 2.1.246 은 idle check-in 을 goal 당 세 번으로 묶었다. Cursor 는 시간 상한을 풀지 않고, 웹의 Long-running mode 를 통째로 지웠다. Amp 는 TUI sidebar 를 지웠다('multi-environment multiplexing on top proved to be a less-than-optimal user experience').
  - 고친 것: 원래 문장은 세 제품이 횟수·시간 상한을 지웠다고만 적었다.
  - 단서: 상한 변경은 changelog 한 줄씩이라 배경 설명이 없다. Amp 의 이유는 제작자 판단이고 측정이 없다.
  - MASC 에서 쓰는 곳: 헌법 `budget_gate`(464~471행)와 요구 7(TUI 핵심 위주)의 바깥 사례로 쓴다. 온전히 남는 사례는 subagent 200개 상한 하나라, `budget_gate` 의 바깥 근거로는 약하다. TUI 화면 문법 캠페인(#51624)은 in_flight 라 새 제안은 없다.

적용하지 않는 것:

- 에이전트를 MCP 서버로 통째 내놓고 승인·스트림·이력까지 MCP 도구에 싣기. Codex 가 2026-09-05 에 지운 길이다(`02`). 좁은 도구와 자체 프로토콜로 나눈다.
- TUI 에 다중 환경 관리 화면 얹기. Amp 가 2026-08-27 에 지운 것이다(`14`). 요구 7 은 TUI 핵심 위주다. 근거는 제작자 판단이고 측정은 없다.
- 사용자 결정 때문에 뺀 13건은 §15.1 에 있다.

## 11. 저장과 동기화 (`storage-sync`)

파일 잠금, fsync, SQLite, 복구·백업, 조율 이론의 1차 자료에서 발견 14개를 뽑았다. 요구 1·19·20 에 닿는다. 12개가 원문과 맞았다. `02` 는 잘못 인용했고 `08` 은 원문보다 세게 말했다. `01`·`03` 은 OS 동작을 이 Mac(macOS 27.2, APFS)에서 직접 재현했다. 이 절에서 store 는 `.masc` 아래 데이터 파일이나 DB 하나를 뜻한다. store 마다 쓰는 쪽은 하나로 둔다. 동기화는 소유 host 한 곳에서 한 방향으로 한다. POSIX 잠금은 열쇠 하나만 버려도 집 문이 다 열리는 자물쇠다(`01`).

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` POSIX 잠금(fcntl·lockf)은 같은 프로세스가 그 파일의 descriptor 를 하나만 닫아도 전부 풀린다. flock 과 OFD(열린 파일 설명) 잠금은 연 descriptor 에 묶여 풀리지 않는다. | 맞음 | 문서에 적힌 동작 | [fcntl(2) manual page, XNU (apple-oss-distributions)](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/fcntl.2). 일부 |
| `02` ext4·XFS·Btrfs 는 fsync 가 실패해도 페이지를 clean 으로 표시한다. 다시 부른 fsync 는 쓰지 않고 성공할 수 있다. | 잘못 인용 | 측정 | [Rebello 등, Can Applications Recover from fsync Failures? (USENIX ATC 2020)](https://www.usenix.org/conference/atc20/presentation/rebello) Table 1, 논문 §2·§3.3.4·§5. 전문 |
| `03` macOS fsync 는 장치 캐시를 비우지 않는다. F_BARRIERFSYNC 는 순서만, F_FULLFSYNC 는 매체 기록까지 보장한다. SQLite fullfsync 기본값은 off 다. | 맞음 | 문서에 적힌 동작 | [fcntl(2) manual page, XNU: F_FULLFSYNC and F_BARRIERFSYNC](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/fcntl.2), SQLite pragma.html. 일부 |
| `04` Durable Objects 는 쓰는 중이면 밖으로 나가는 메시지를 쓰기 완료까지 붙잡고(output gate), 쓰기를 자동으로 묶는다. | 맞음 | 문서에 적힌 동작 | [Kenton Varda, Durable Objects: Easy, Fast, Correct — Choose three (Cloudflare blog, 2021-08-03)](https://blog.cloudflare.com/durable-objects-easy-fast-correct-choose-three/), PostgreSQL 18 문서 28.4절. 일부 |
| `05` 64-bit counter 를 5억 번 올리는 시험에서 thread 하나는 300 ms, lock 을 쓰는 thread 둘은 118,000 ms 였다. 글은 자원마다 writer 를 하나로 두라고 권한다. | 맞음 | 측정 | [Martin Thompson, Single Writer Principle (2011-09-22)](https://mechanical-sympathy.blogspot.com/2011/09/single-writer-principle.html). 전문 |
| `06` transaction 중인 SQLite 파일을 복사하면 옛 내용과 새 내용이 섞여 손상될 수 있다. 안전한 방법은 sqlite3_rsync, VACUUM INTO, backup API 다. | 맞음 | 문서에 적힌 동작 | [How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html) 원문 §1.2·§1.4. 일부 |
| `07` PostgreSQL 은 복구가 끝나면 새 timeline 을 만들어 원본과 사본의 기록을 가른다. tablespace 는 절대 경로로 기록돼 다른 장비에서 어긋난다고 경고한다. | 맞음 | 문서에 적힌 동작 | [PostgreSQL 18 Documentation: Continuous Archiving and Point-in-Time Recovery](https://www.postgresql.org/docs/current/continuous-archiving.html) 25.3.6절·25.3.8절, protocol-replication.html. 일부 |
| `08` XDG 는 사용자 파일을 data·config·state·cache 로 나눈다. CACHEDIR.TAG 는 캐시 디렉터리에 서명 파일을 둔다. 백업 도구는 설정했을 때만 그 디렉터리를 뺀다. | 세게 말함 | 문서에 적힌 동작 | [XDG Base Directory Specification v0.8](https://specifications.freedesktop.org/basedir/latest/), Cache Directory Tagging Specification v0.6(bford.info/cachedir). 일부 |
| `09` 11개 앱에서 crash 취약점 60개를 찾았다. LevelDB 1.10 은 10, Git 9, Mercurial 10, SQLite-WAL 0 이다. | 맞음 | 측정 | [Pillai 등, All File Systems Are Not Created Equal (OSDI 2014)](https://research.cs.wisc.edu/adsl/Publications/alice-osdi14.pdf) Table 3, ALICE 논문 §4.4.2·§4.7. 일부 |
| `10` eio_posix 는 일반 파일 read·write 를 부른 도메인에서 바로 실행하고, open·rename·fsync 는 systhread 로 넘긴다. | 맞음 | 문서에 적힌 동작 | [Eio lib_eio_posix/low_level.ml (main, 설치본 1.3 과 대조)](https://raw.githubusercontent.com/ocaml-multicore/eio/main/lib_eio_posix/low_level.ml) 머리 주석. 일부 |
| `11` 불변식이 I-confluent 할 때에만 조율 없이 실행하면서 그 불변식을 지킬 수 있다(Theorem 1). | 맞음 | 증명 | [Bailis 등, Coordination Avoidance in Database Systems (PVLDB 8(3), 2015)](http://www.vldb.org/pvldb/vol8/p185-bailis.pdf) Theorem 1, Table 2. 일부 |
| `12` SQLite WAL 은 네트워크 파일시스템에서 동작하지 않고, 모든 프로세스가 같은 host 에 있어야 한다. LMDB 도 원격 파일시스템을 금한다. | 맞음 | 문서에 적힌 동작 | [SQLite Write-Ahead Logging](https://www.sqlite.org/wal.html) 원문 §1, LMDB Caveats, Linux fcntl_locking(2) 'Lost locks'. 일부 |
| `13` SQLite WAL-reset 버그는 3.7.0 부터 3.51.2 까지 있고, 3.51.3(2026-03-13)에서 고쳤다. WAL 모드에서 두 연결이 같은 순간 쓰거나 checkpoint 할 때만 생긴다. | 맞음 | 문서에 적힌 동작 | [SQLite Write-Ahead Logging §11 The WAL-Reset Bug](https://www.sqlite.org/wal.html). 일부 |
| `14` SQLite 는 약 10 KB blob 을 개별 파일보다 35% 빠르게 읽고 쓰고, 디스크를 약 20% 덜 쓴다고 쟀다(2017년). 큰 blob 은 파일시스템이 빠르다. | 맞음 | 측정 | [SQLite: 35% Faster Than The Filesystem](https://www.sqlite.org/fasterthanfs.html) 원문 §1·§2.2·§2.3. 일부 |

- `01` POSIX 잠금
  - 단서: 재확인의 독립 탐침(macOS 27.2, APFS)에서도 lockf 는 둘째 close 뒤 풀리고, flock·OFD 는 유지됐다. MASC 코드 경로로는 재현하지 않았다. 같은 파일을 두 프로세스가 잠가야 드러난다.
  - MASC 에서 쓰는 곳: Fs_compat 잠금이 두 방식이다. sidecar 잠금 파일 방식은 `lib/fs_compat/fs_compat_private_jsonl_transaction.ml` 에 있고 18곳이 부른다. 데이터 파일 잠금은 `lib/fs_compat/fs_compat_private_file_update.ml` 에 있고 32곳이 부른다. 데이터 파일 잠금을 쓰는 파일은 `load_jsonl`·`fold_jsonl_lines` 가 mutex 없이 열고 닫는다.
  - 할 일: MASC 함수로 잠금이 풀리는 조합을 먼저 재현한다. 재현되면 sidecar 방식 하나로 합친다(§15.2). 지금의 데이터 파일 잠금과 합칠 쪽인 sidecar 잠금 파일은 서로 배제하지 않는다. 그래서 서버와 TUI 를 함께 바꿔야 한다.
- `02` fsync 실패
  - 논문은 다섯 앱의 fsync 실패 처리 전략이 모두 충분하지 않았다고 적는다. 다섯 앱 모두 fsync 를 다시 부르지 않았다(논문 §5 의 7번 항목).
  - 고친 것: 원래 문장은 '어떤 앱의 재시도 전략도 충분하지 않았다' 로 적었다.
  - 단서: 불충분한 것은 실패 처리 전략이다. 무시(Redis), 메모리 되돌림과 오류 보고(LMDB·LevelDB·SQLite), crash(PostgreSQL)가 그 예다. Linux 5.2.11 측정이고 APFS 는 다루지 않았다.
  - MASC 에서 쓰는 곳: 내용이 같으면 다시 쓰지 않고 `sync_file_and_parent_strict` 만 부르는 갈래가 같은 유형이다(`lib/keeper/keeper_librarian_unread_ledger.ml`, `lib/keeper/keeper_memory_os_current_publication.ml`). fsync 오류 뒤에는 `Atomic_replace` 로 새 inode 에 다시 쓴다. 프로세스가 fsync 전에 죽은 경우에는 sync 만 하는 것이 맞다. 호출부가 두 경우를 가르는지는 확인하지 않았다.
- `03` macOS fsync
  - F_FULLFSYNC 한 번은 같은 장치에 앞서 fsync 된 데이터도 확정한다.
  - 단서: 'fullfsync 기본 off' 는 출처 URL 이 아니라 SQLite pragma.html 에 있다. XNU fsync(2) 는 OS crash 때도 잃을 수 있다고 적는다. 이 Mac 한 번 측정의 중앙값은 fsync 0.16 ms, F_BARRIERFSYNC 2.7 ms, F_FULLFSYNC 8.3 ms 다(40회, 부하 높음). Apple 배포 SQLite 의 실제 sync 방식은 1차 출처로 확인하지 못했다.
  - MASC 에서 쓰는 곳: `Unix.fsync`(`lib/fs_compat/atomic_replace.ml`)와 SQLite EXTRA store(`lib/keeper_chat_operations/keeper_chat_operation_store.ml`)는 전원 손실을 못 견딘다. `.mli` 열 개 파일의 산문 선언을, store 별 내구성 등급 variant 하나로 바꾼다.
- `04` output gate
  - PostgreSQL 비동기 commit 도 손실은 있어도 손상은 없다고 적는다(PostgreSQL 18 문서 28.4절).
  - 단서: PostgreSQL 의 'data loss, not data corruption' 은 출처 URL 밖의 PG 18 문서에서 확인했다. F_FULLFSYNC 한 번은 앞서 fsync 한 쓰기만 확정한다. Cloudflare 구현은 원격 복제 위에 있고, 로컬 디스크 하나로 옮긴 공개 측정은 찾지 못했다.
  - MASC 에서 쓰는 곳: 헌법 `persist_before_model_call` 이 같은 자리다. 전원 손실 등급이 필요한 store 는 append 마다가 아니고, 모델 호출·외부 쓰기 직전에 F_FULLFSYNC 한 번으로 확정한다. `docs/rfc/RFC-async-log-sink-durable-append-offload.md` 와 `docs/rfc/RFC-0450-event-queue-witness-measure-then-wal.md` 는 in_flight 라 다시 제안하지 않는다.
- `05` writer 하나
  - SQLite·LMDB·irmin-pack 도 writer 가 하나다.
  - 단서: 2.4GHz Westmere 에서 잰 메모리 안 counter 수치이고 파일 I/O 가 아니다. writer 하나 설계는 SQLite wal.html, LMDB 문서, Tarides 2020 글에서 따로 확인했다.
  - MASC 에서 쓰는 곳: `docs/IMMORTAL-SERVER-ROADMAP.md` 는 서버 하나가 `.masc` 를 소유한다고 적는다. 그러나 TUI 가 직접 쓴다(`bin/masc_tui_play_pending.ml`). store 마다 쓰는 프로세스를 하나로 정하면 데이터 파일의 프로세스 간 잠금이 필요 없어진다. 서버가 내려간 동안 TUI·CLI 가 할 수 있는 일은 줄어든다. 범위가 넓어 RFC 대상이다.
- `06` SQLite 복사
  - journal 은 DB 와 짝으로 있어야 한다(원문 §1.4).
  - 단서: snapshot 이 '서버가 죽은 직후' 와 같다는 근거는 이 문서에 없고 PostgreSQL 25.2절에 있다. snapshot 은 crash 일관성만 준다.
  - MASC 에서 쓰는 곳: BasePath 전체 백업 명령이 없다. 파일시스템 snapshot 을 복사하면 복원 상태가 서버가 죽은 직후와 같아, 기존 boot 복구 경로를 탄다. boot 복구가 맞아야 백업이 맞다. `<base-path>/.masc` 는 217.3 GiB 였고(2026-11-12 10:44Z du), 디스크 여유는 12:22Z 에 132.5 GiB 였다. 외부 대상이 필요하다. tmutil localsnapshot 권한과 fs_snapshot_create entitlement 는 확인하지 못했다.
- `07` PostgreSQL timeline
  - system identifier 로 같은 cluster 인지 확인한다.
  - 단서: system identifier 는 protocol-replication.html 에 있다. timeline 은 WAL 보관소 안 이력을 가른다.
  - MASC 에서 쓰는 곳: `Durable_file_identity {path; inode}` 와 TUI journal 의 `base_path`(`bin/masc_tui_play_pending.ml`)는 복사·이동 뒤 달라진다. 디렉터리 안에 둘 식별자와, 복원한 사본을 원본과 가르는 방법은 별도 RFC 로 정한다. `docs/rfc/RFC-0496-durable-file-identity-drops-the-device-number.md` 4절 B 는 `.masc` 안 id 파일을 기각했지만, 재부팅 식별 문제에 한해서다. 절대 경로·inode·pid 를 저장하는 곳이 모두 어디인지는 목록을 만들지 않았다.
- `08` XDG 와 CACHEDIR.TAG
  - cache 는 없어도 되는('non-essential') 데이터다.
  - 고친 것: 원래 문장은 태그만 두면 백업 도구가 건너뛴다고 적었다.
  - 단서: CACHEDIR.TAG 는 XDG 와 다른 별도 규격이다. 그 규격은 태그를 'hints' 로만 다루라고 적는다. 도구 설정(예: `--exclude-caches`)이 있어야 뺀다.
  - MASC 에서 쓰는 곳: `<base-path>/.masc` 217.3 GiB 중 official-clients 가 92.5 GiB, tool_blobs 가 28.6 GiB 다(du 한 번, 2026-11-12 10:44Z, 내용은 읽지 않음). 최상위 store 마다 백업 등급을 선언한다. 자리는 `docs/rfc/RFC-every-durable-store-has-one-boot-policy.md` 의 store 표에 열 하나다. 어느 store 가 어느 등급인지는 사용자 결정이다.
- `09` ALICE
  - 앱이 log 끝의 쓰레기 내용을 놓치고, 복구 코드가 시험되지 않았다고 적는다.
  - 단서: 60 은 ALICE 의 약한 persistence model 기준이다. 2014년 Linux 파일시스템 대상이다.
  - MASC 에서 쓰는 곳: Fs_compat durable 경로에는 I/O 주입 seam 이 있다(`lib/fs_compat/fs_compat_durable_append.ml` 의 `*_with_io_for_testing`). 연산마다 실패·중단을 열거해, 확인 응답한 record 가 남는지 본다. 50곳이 부르는 경로다. OCaml 수준 seam 은 파일시스템의 순서 바뀜을 만들지 못한다. PR 마다 도는 CI 에 넣지 않는다(결정 6).
- `10` eio_posix 의 blocking 읽기
  - 주석은 blocking 연산이 모두 systhread 에서 일어나야 이상적이라고 적는다. §4 의 `02` 와 같은 코드다.
  - 단서: eio_posix 동작이라 Linux io_uring 백엔드에는 그대로 옮기지 못한다. 막는 시간은 재지 않았다.
  - MASC 에서 쓰는 곳: `fold_jsonl_lines` 의 Eio 갈래(`lib/fs_compat/fs_compat_jsonl_read.ml`)는 읽는 동안 그 도메인을 막는다. `load_file` 과 durable transaction 은 이미 systhread 로 넘긴다. 정지 구간 캠페인(in_flight)의 귀속 측정에 넣는다.
- `11` I-confluence
  - 특정 값 유일성, AUTO_INCREMENT insert, foreign key delete 는 해당하지 않는다(Table 2).
  - 단서: I-confluence 는 불변식 하나의 성질이 아니고, transaction 집합과 불변식 쌍의 성질이다. Theorem 은 필요충분이다. MASC 불변식을 표에 대입한 것은 조사자의 추론이다.
  - MASC 에서 쓰는 곳: Task claim 하나, 한 사람 한 표, cursor 전제 append(`append_private_jsonl_durable_locked_at_cursor_result`, 11곳)는 두 곳에서 쓰고 합치면 깨진다. 외부 동기화는 소유 host 한 곳에서 한 방향 복제로 한다. 여러 사람이 서버 하나를 쓰는 다계정은 이 문제가 아니다.
- `12` 네트워크 파일시스템
  - Linux 는 NFS 에서 잠금을 잃을 수 있다고 적는다.
  - 단서: LMDB·Linux 문서는 출처 URL 밖에서 확인했다. virtiofs 같은 microVM 공유 디렉터리의 잠금 의미는 확인하지 않았다.
  - MASC 에서 쓰는 곳: microVM·RemoteSSH 를 Docker 보다 먼저 쓴다(결정 13). 그래서 BasePath 는 소유 host 의 로컬 파일시스템에 두고, guest·원격은 서버 API 로 접근한다. WAL store 는 `lib/keeper_tool_call_index/keeper_tool_call_index.ml` 등 세 곳이다. 지금 배치가 공유 mount 를 쓰는지는 보지 않았다.
- `13` WAL-reset 버그
  - 문서는 급한 일이 아니라고 적는다(원문 §11).
  - 단서: 원문은 'likely present' 라고 적고, 바로 앞에서 'should upgrade' 를 권한다. 2026-08-24 에 hack 없는 재현이 나왔다. Ubuntu 가 3.45.1 계열에 수정을 넣었는지는 확인하지 않았다. 이 Mac 의 시스템 SQLite 는 3.54.0 이다.
  - MASC 에서 쓰는 곳: Linux 릴리스 빌드는 SQLite 3.53.4 를 고정한다(`scripts/build-release-sqlite.sh`). macOS binary 는 시스템 libsqlite3 를, `Dockerfile.oneclick` 은 Ubuntu 24.04 의 3.45.1 계열을 쓴다. 링크한 SQLite 버전은 health 같은 projection 으로 보여 준다. 수리는 원문 권고대로 링크 버전을 올리는 것이다. boot 때 버전을 사실로 기록하는 제안은 §15.2 를 본다.
- `14` SQLite 와 파일시스템
  - 파일마다 fsync 하면 직접 저장이 10배 넘게 느리다(원문 §2.2).
  - 단서: 35% 는 근사치이고 2017-06-05 주에 잰 값이다. 다른 장비·파일시스템의 측정이다.
  - MASC 에서 쓰는 곳: RFC-0499 가 적은 tool_blobs 는 2,462,539개, 20.0 GB 로 평균 약 8 KB 다(`docs/rfc/RFC-0499-tool-blobs-are-swept-inside-the-server.md`). `08` 의 28.6 GiB 는 2026-11-12 du 값이라 잰 때와 단위가 다르다. 전환을 권하지 않는다. 파일 하나로 모으면 파일 단위 증분 백업이 나빠진다. RFC-0499 sweep 뒤에도 파일 수가 병목이면 그때 MASC 부하로 잰다.

적용하지 않는 것:

- Irmin(irmin-pack)을 저장 엔진으로 쓰기. 최신 3.11.0 의 irmin-pack 은 lwt 에 의존한다. Eio 버전은 eio branch 에만 있고 Irmin 4 는 나오지 않았다. GC 가 도는 동안 디스크와 메모리가 두 배가 된다(Tarides 2022-11-10 글).
- LMDB·RocksDB 도입. SQLite 가 이미 의존성이고 새로 얻는 능력이 없다. LMDB 는 같은 프로세스의 이중 open 을 금한다. 긴 read transaction 은 파일을 키운다. 원격 파일시스템도 금한다. ocaml.org 에 rocksdb package 페이지가 없다. lmdb 1.1.3 의 reverse dependency 는 0 이다.
- cr-sqlite·Automerge 로 Ledger 를 여러 writer 가 쓰고 합치기. claim·투표·cursor 불변식은 I-confluent 가 아니다(`11`). cr-sqlite README 는 insert 가 2.5배 느리다고 적는다. CRDT 는 이력이 계속 쌓이고, 쓰는 쪽 하나 모델과 부딪힌다.
- 실행 중인 `.masc` 를 Dropbox·iCloud·Syncthing 같은 파일 동기화 폴더에 두기. 파일 단위로 충돌 사본이 생긴다(Ink & Switch). SQLite 의 DB 와 journal 짝이 깨질 수 있다(`06`). 한 시점의 상태가 아니다.
- append 마다 F_FULLFSYNC 부르기. 이 Mac 한 번 측정에서 중앙값 8.3 ms 였다(`03`). 정지 구간 캠페인과 반대 방향이다. 밖으로 나가는 효과 직전에 한 번이면 같은 보장을 낸다(`04`).
- fsync 가 실패하면 같은 파일에 fsync 를 다시 부르기. 두 번째 성공은 디스크 상태를 말해 주지 않는다(`02`).
- JSONL 전체를 SQLite 로 한 번에 옮기기. `docs/research/2026-10-26-librarian-history-validation-cost-r1.md` 4.5절이 권하지 않았다. RFC-0437 은 ledger 를 authority 로 두고 파생 index 만 SQLite 로 둔다. MASC 부하로 잰 근거가 없다.
- Litestream 을 BasePath 백업으로 쓰기. SQLite 파일만 다뤄 JSONL 과 blob 이 빠진다. 비동기라 복제 창만큼 잃는다. MASC 의 주요 journal 은 DELETE 모드다.
- tool_blobs 를 irmin-pack 식 복사 GC 로 정리하기. GC 동안 디스크가 두 배 필요하다. RFC-0499 가 두 번 스캔과 touch 기록으로 제자리 sweep 을 이미 설계했다.
- BasePath 를 NFS·SMB·공유 mount 에 두기. SQLite WAL 은 네트워크 파일시스템에서 동작하지 않는다. NFS 에서는 잠금을 잃을 수 있다(`12`).
- 검증 결과 캐시와 stat 키 캐시. 조사 보고서가 먼저 읽은 연구 문서(`docs/research/2026-10-26-librarian-history-validation-cost-r1.md` 등)가 이미 다뤘다. 보고서는 설계 문서가 막았다고 적지만 그 문서 경로는 적지 않았다.
- 사용자 결정 때문에 뺀 2건은 §15.1 에 있다.

## 12. 이식, 텍스트 외부화, 멀티모달 (`portability-text-multimodal`)

세계 묶음 형식, 템플릿·문구 외부화, 미디어 읽기를 다룬 명세·제품 문서·논문에서 발견 14개를 뽑았다. 요구 14·15·17 에 닿는다. 세계 묶음은 요구 14(세계관 내보내기·가져오기)가 옮기는 파일 묶음이다. 10개가 원문과 맞았다. `02` 는 잘못 인용했고, `04`·`05` 는 원문보다 세게 말했다. `06` 은 옛 버전을 인용했다. 이 주제는 §15.2 에 넣은 것이 없다. 이 절에서 H5 는 `docs/KEEPER-MEDIA-FALLBACK-H5.md` 의 미디어 읽기 설계다. 전사문은 녹음보다 증언에 가깝다(`07`).

| 발견 | 판정 | 근거 종류 | 출처 |
| --- | --- | --- | --- |
| `01` Dream 은 템플릿 파일을 dune rule 로 OCaml 소스로 바꾸고, 끼우는 값의 타입을 Printf 변환 지정자로 준다. OCaml 표준 `Scanf.format_from_string` 은 읽어 온 문자열의 format 타입을 실행 중에 맞춰 본다. | 맞음 | 문서에 적힌 동작 | [Dream example 7-template README](https://github.com/camlworks/dream/tree/master/example/7-template), OCaml 5.5 매뉴얼 Scanf, Askama README. 일부 |
| `02` OpenClaw 는 미디어 reader 를 항목마다 capabilities 태그를 단 모델 목록 하나로 선언한다('one capability-tagged model list', 36행). 오류·시간 초과·크기 초과면 다음 항목으로 넘어간다(27행). | 잘못 인용 | 문서에 적힌 동작 | [OpenClaw docs: Media understanding](https://docs.openclaw.ai/nodes/media-understanding) 27·36·270·280·281행. 일부 |
| `03` MCP 2026-07-28 은 Sampling 을 deprecated 로 내리고, LLM provider API 에 직접 붙으라고 적는다. 도구 결과 블록은 text, image, audio, resource_link, embedded resource 다섯이고 video 종류는 없다. | 맞음 | 문서에 적힌 동작 | [Model Context Protocol specification 2026-07-28: Changelog, Tools, Sampling](https://modelcontextprotocol.io/specification/2026-07-28/changelog) Changelog 의 Deprecated 1번 항목, Tools, schema.ts ContentBlock. 일부 |
| `04` 같은 Agent Spec 정의를 runtime 넷에서 돌리자 점수가 달랐다. τ²-Bench Pass^1 은 GPT-4.1 에서 62.5~73.5 였다(Table 5). SimpleQA F1 은 Llama 3.3 70B 에서 54.9~82.3 이었다(Table 3). | 세게 말함 | 측정 | [Open Agent Specification (Agent Spec): A Unified Representation for AI Agents (arXiv 2510.04173v4)](https://arxiv.org/abs/2510.04173) Table 3·4·5. 전문 |
| `05` Hermes distribution 은 묶음 소유(SOUL, mcp.json, skills, cron)와 사용자 소유(memories, sessions, auth.json, .env)를 가른다. update 는 통째 교체가 아니다. 묶음이 가져온 cron job 은 멈춘 채 설치된다. | 세게 말함 | 문서에 적힌 동작 | [Hermes Agent docs: Profile distributions](https://hermes-agent.nousresearch.com/docs/user-guide/profile-distributions), Letta agent-file README, Agent Spec 26.3.1. 일부 |
| `06` OmniDocBench arXiv v2 Table 3 에서 문서 reader 의 순위가 문서 종류에 따라 뒤집혔다. 편집 거리 기준 MinerU 는 논문 0.025, 노트 0.984 이고, Qwen2-VL-72B 는 0.085 와 0.168 이다. 이 노트 값은 벤치마크가 그림을 고치기 전 데이터다. | 옛 버전 | 측정 | [OmniDocBench: Benchmarking Diverse PDF Document Parsing with Comprehensive Annotations (arXiv 2412.07626v2)](https://arxiv.org/abs/2412.07626) Table 3, 벤치마크 README 2025-09-25 항목. 일부 |
| `07` Whisper API 로 음성 구간 13,140개를 전사하자 1.4% 구간에서 원본에 없는 문장이 나왔다. 지어낸 글의 38% 가 해로운 유형이었다(원문 §3). | 맞음 | 측정 | [Careless Whisper: Speech-to-Text Hallucination Harms (arXiv 2402.08021v2)](https://arxiv.org/abs/2402.08021) 원문 §1·§3·§4.2 Table 2. 일부 |
| `08` Character Card V2 는 `extensions` 의 모르는 키를 지우면 안 된다고 적는다(MUST NOT). V3 는 PNG tEXt·JSON·CHARX(zip) 세 운반 형식을 둔다. `source` 이력은 덧붙이기를, 모르는 `spec_version` 은 거절하지 않기를 권한다(SHOULD). | 맞음 | 문서에 적힌 동작 | [Character Card V3 Specification](https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md), Character Card V2 Specification. 일부 |
| `09` 같은 내용을 plain text·Markdown·JSON·YAML 로 바꾸자 GPT-3.5-turbo 의 코드 번역 성능이 최대 40% 달라졌다(초록). GPT-4-turbo 는 덜 민감했다(원문 §1). | 맞음 | 측정 | [Does Prompt Formatting Have Any Impact on LLM Performance? (arXiv 2411.10541v1)](https://arxiv.org/abs/2411.10541) 초록, 원문 §1·§5, TOML 1.0.0 명세. 일부 |
| `10` gettext 는 번역 전 문자열이 곧 식별자라, 그 문자열을 고치면 번역이 전부 fuzzy 가 된다. Fluent 는 개발자가 식별자를 정한다. MessageFormat 2 는 오류를 알리면서도 유효한 결과를 내라고 요구한다(MUST). | 맞음 | 문서에 적힌 동작 | [Project Fluent wiki: Fluent vs gettext](https://github.com/projectfluent/fluent/wiki/Fluent-vs-gettext), MessageFormat 2 spec/errors.md. 전문 |
| `11` 영상을 구간 캡션으로 바꿔 LLM 이 글만 보고 답하게 하면, 캡션 도구가 정확도를 크게 좌우한다. EgoSchema Subset 에서 LLaVA 45.2, LaViLa 55.2, 사람 캡션 66.0 이다(Table 1). | 맞음 | 측정 | [A Simple LLM Framework for Long-Range Video Question-Answering (LLoVi, arXiv 2312.17235v3)](https://arxiv.org/abs/2312.17235) Table 1·2·5. 일부 |
| `12` provider 마다 문서를 직접 받는 방식이 다르다. Anthropic 은 PDF 쪽마다 이미지와 추출 글을 같이 주고, context 1M 이면 최대 600쪽, 그 미만이면 100쪽이다. OpenAI 는 vision 모델에서 PDF 의 글과 쪽 이미지를 주고, PDF 가 아닌 문서는 글만 준다. | 맞음 | 문서에 적힌 동작 | [Anthropic docs: PDF support](https://platform.claude.com/docs/en/build-with-claude/pdf-support), OpenAI File inputs guide, Anthropic Citations. 일부 |
| `13` Claude Code plugin 의 version 은 manifest, marketplace 항목 순으로 읽는다. 둘 다 없으면 commit SHA 나 archive SHA-256 을 12자로 줄여 계산한다. 받은 내용이 `sha256` pin 과 다르면 받기를 거절한다. | 맞음 | 문서에 적힌 동작 | [Claude Code docs: plugin loading](https://code.claude.com/docs/en/plugins/loading), marketplace reference, plugins reference. 일부 |
| `14` Agent Skills 명세에는 버전 필드가 없다. client guide 는 느슨한 검증(경고하되 로드)과 `.agents/skills` 공용 경로를 권한다. AGENTS.md 는 필수 필드가 없고, 디렉터리 tree 에서 가장 가까운 파일이 우선한다. | 맞음 | 문서에 적힌 동작 | [Agent Skills Specification](https://agentskills.io/specification), client implementation guide, agents.md. 전문 |

- `01` Dream 템플릿
  - 조사자는 템플릿을 파일에 두고도 호출부를 컴파일 때 검사하는 선례로 본다. Askama 도 템플릿을 컴파일 때 검사한다고 적는다.
  - 단서: 호출부 컴파일 검사는 코드 생성 방식에서 끌어낸 추론이다. Dream 은 템플릿이 곧 소스라 운영자 override 가 없다. 변수 값은 모두 string 이다. Askama 는 WebFetch 요약으로 읽었다. Dream 저장소는 aantron/dream 에서 camlworks/dream 으로 옮겨졌다.
  - MASC 에서 쓰는 곳: `lib/embedded_config/dune` 옆 dune rule 로 labelled 함수 모듈을 만든다. 입력은 `config/prompts` 의 `template_variables`·`(vars: …)` 선언이다. 대상은 `Prompt_names` 373개와 render 호출 108곳(lib·bin)이다. 변수 오타와 빠진 변수가 기존 type-check 에서 걸린다. CI 실행은 늘지 않는다. 운영자 override 가 있어 MASC 는 서명만 만들고 본문은 실행 중에 읽는다. 선언 밖 변수를 쓴 override 는 지금처럼 `set_override` 가 막는다.
- `02` OpenClaw 미디어 reader
  - 첨부마다 닫힌 처리 결과(disposition) 하나를 남긴다(281행). 뽑아낸 글은 외부 내용 표지로 감싼다(270행). 일부만 읽었으면 그렇게 표시한다(280행).
  - 고친 것: 원래 문장은 종류별 목록으로 적었다.
  - 단서: 측정이 아니라 제품 문서다. 숫자 기본값(500자, 첨부 1개, 표지 5개)은 근거가 적혀 있지 않다. 성공한 설명이 원본 픽셀을 대신하는 동작은 H5 원칙과 반대다.
  - MASC 에서 쓰는 곳: 지금 reader 는 코드에 고정돼 있다(`Keeper_media_reading.production_reader`). 음성은 STT(음성 인식), PDF 는 Poppler, 그 밖은 `no_document_reader` 다. 이것을 `runtime.toml` 의 reader 목록으로 바꾼다. 항목마다 다루는 종류를 태그로 단다. 항목 종류는 닫힌 합(내장, MCP 도구, runtime)이다. 실패 이유는 string 대신 variant 로 남긴다. H5 범위를 넓히므로 RFC 가 먼저다. 숫자 기본값은 가져오지 않는다(§15.1).
- `03` MCP 2026-07-28
  - 블록에는 annotations 와 structuredContent 가 붙는다. video 는 `resource_link` 로만 들어온다.
  - 단서: 2026-07-28 이 지금 버전이다.
  - MASC 에서 쓰는 곳: 외부 reader 는 MCP 도구나 MASC runtime 으로 붙이고, Sampling 은 설계에서 뺀다. `Mcp_client.text_of_content` 는 비텍스트 블록을 `[image]` 로 바꾼다. 그 자리에서 `ToolResult.content_blocks` 로 decode 한다. 모델이 못 받는 종류는 H5 projection 이 읽기로 바꾼다. `docs/research/2026-10-27-mcp-2026-07-28-parity.md` 가 multimodal 검증을 남은 일로 이미 적었다. Keeper 호출부는 지금 `Mcp_client.model_text` 만 쓴다.
- `04` Agent Spec 의 runtime 차이
  - 저자는 τ²-Bench 차이의 원인으로 두 가지를 든다. runtime 마다 system prompt 를 감싸는 방식과 도구를 요청하는 방식이 다르다. SimpleQA 에서 가장 낮은 AutoGen 54.9 는 non-native tool calling 을 지원하지 않아서다. BIRD-SQL 은 0.6점 차이였다(Table 4). 저자는 결과를 'consistent behavior' 로 요약한다.
  - 고친 것: 원래 문장은 system prompt 감싸기를 두 벤치마크의 공통 원인으로 적었다.
  - 단서: 저자가 명세를 만든 팀이다. 표에 점수의 반복 분산이 없다. 그래서 runtime 사이 차이가 잡음보다 큰지 모른다.
  - MASC 에서 쓰는 곳: `Prompt_preset.capture` 는 `default_revisions` 를 적는다. 기본 runtime, sandbox·network 설정, skill 은 적지 않는다. 이것을 묶음에 기록한다. restore 때 지금 값과 다르면 `default_comparison` 처럼 차이만 보여 준다. 복원을 막지 않는다.
- `05` Hermes distribution
  - SOUL·mcp.json 같은 파일 하나는 교체하고, skills 는 항목별로 병합한다. cron/jobs.json 은 job id 별로 병합해 로컬 job 과 멈춤 상태를 남긴다. config.yaml 은 기본으로 보존하고 `--force-config` 로만 덮는다. Letta `.af` 와 Agent Spec 도 비밀값을 싣지 않는다.
  - 고친 것: 원래 문장은 update 때 묶음 소유 쪽을 통째로 교체한다고 적었다.
  - 단서: Hermes 는 서명·lockfile·dry-run 이 아직 없다고 스스로 적는다. Letta `.af` 와 Hermes `/export` 는 기억까지 싣고 통째로 옮긴다. 그래서 요구 20(BasePath 백업·이식) 쪽이다.
  - MASC 에서 쓰는 곳: 세계 묶음이 바꾸는 범위를 variant(지시문, prompt override, runtime 배정, lane)로 선언한다. import 는 그 범위만 바꾼다. 비밀값·기억·원장은 variant 에 자리가 없다. keeper TOML 에 비밀값 필드가 있는지는 확인하지 않았다.
  - 정석과 대가: 사용자 결정으로 올릴 것은 둘이다(portability-text-multimodal 보고서 14-D). 첫째는 import 가 선언한 범위를 묶음과 똑같이 맞출지, 묶음에 있는 항목만 덮어쓸지다. 지금은 덮어쓰기라 이전 세계의 지시문과 lane 이 남는다. 정석은 범위를 묶음과 똑같이 맞추는 것이다. 근거는 import 가 선언한 범위만 바꾼다는 이 적용의 규칙이다. 대가는 묶음에 없는 Keeper 의 지시문이 지워지는 것이다. `_autosave` 가 먼저 저장하므로 되돌릴 수 있다. 둘째는 밖에서 온 묶음의 autonomous Keeper 를 바로 띄울지다. 정석은 Hermes 처럼 설치만 하고 시작은 운영자가 하는 것이다. 대가는 운영자가 한 번 더 누르는 것이다. 헌법 `<gates>` 는 Gate 를 기본으로 두지 않는다. 그래서 다계정 캠페인(in_flight)에서 묶음을 주고받게 될 때 같이 정한다.
- `06` OmniDocBench
  - 같은 표에서 신문은 GPT4o 0.751, MinerU 0.171 이다.
  - 고친 것: 원래 문장은 버전이 바뀐 것을 적지 않았다. 벤치마크는 2025-09-25 v1.5 에서 노트·신문 그림을 72 DPI 에서 200 DPI 로 올리고 374쪽을 더했다. 지금 버전은 v1.7(2026-04-30)이다. 위 노트·신문 값은 고치기 전 데이터다.
  - 단서: 「종류에 따라 순위가 뒤집힌다」 는 지금 버전으로 다시 확인하지 못했다. 영어·중국어 981쪽이고 한국어 수치는 없다. Docling Table 1 은 225쪽에 6.20 GB 를 쓴다고 적는다.
  - MASC 에서 쓰는 곳: reader 를 하나로 고정하지 않고 목록으로 선언한다. 읽기 기록에 reader id 를 남겨 어느 reader 가 무엇을 읽었는지 비교한다. 이 판단은 옛 수치 없이도 H5 설계의 `reader = {id; version}` 으로 선다. 지금 기록에는 `reader_version` 만 있어 설계와 어긋난다. Docling 같은 reader 에는 sandbox 자원 경계가 필요하다.
- `07` Whisper 전사
  - 말이 없는 구간이 길수록 더 자주 지어냈다(원문 §4.2 Table 2).
  - 단서: 초록은 'roughly 1%' 라 적는다. 2023년 4~5월의 Whisper API 이고, 실어증 연구의 미국 영어 화자 자료다.
  - MASC 에서 쓰는 곳: 전사문을 파생 주장으로 다룬다. `Keeper_media_reading` 기록의 `text` 한 덩어리를 구간 목록(시간 범위, 쪽 번호)으로 바꾼다. 그러면 의심 대목을 원본에서 다시 확인할 수 있다. 원본 보존과 'derived' 표시는 H5 가 이미 한다. 한국어와 지금 MASC STT endpoint 에서의 비율은 모른다. endpoint 가 구간 시각을 돌려주는지도 확인하지 않았다.
- `08` Character Card
  - 단서: 해로운 `source` 항목은 지울 수 있다. 앱이 여럿인 생태계의 호환 규칙이다. V3 는 605줄 중 앞 425줄쯤 읽었다.
  - MASC 에서 쓰는 곳: 가져올 것은 둘이다. 묶음 manifest 에 덧붙이기만 하는 `source` 이력을 둔다. 디렉터리와 압축 파일 하나가 같은 manifest 를 쓴다. 버전은 `Prompt_preset` 의 `schema_version` 정확히 일치를 유지한다. 모르는 필드 무시와 lorebook 활성화는 가져오지 않는다(§15.1).
- `09` 프롬프트 서식
  - 원문은 두 모델이 가장 잘 받는 서식 집합의 겹침 비율(IoU)을 쟀다. 계열이 다르면 'often below 0.2' 였고, 같은 하위 계열끼리는 0.7 을 넘었다(원문 §5). GPT-3.5-turbo 는 JSON 을, GPT-4 는 Markdown 을 더 잘 받았다.
  - 단서: OpenAI GPT 4종만 쟀고 2024년 모델이다. 지금 MASC 가 쓰는 모델에서 차이가 얼마나 큰지는 모른다.
  - MASC 에서 쓰는 곳: 글을 코드에서 파일로 옮기는 PR 은 렌더한 프롬프트의 SHA-256 을 옮기기 전후로 비교해 본문에 적는다. `default_revisions` 해시를 그대로 쓰고 CI 는 더하지 않는다(결정 6). 산문은 Markdown, 구조는 TOML 에 둔다. TOML 의 세 겹 큰따옴표 문자열은 escape 를 해석한다(TOML 1.0.0 명세). keeper TOML 에 backslash 가 든 줄은 0개라 이 위험은 아직 없다.
- `10` gettext, Fluent, MessageFormat 2
  - MessageFormat 2 의 결과에는 fallback 값이 들어갈 수 있다('might include').
  - 단서: 비교 글은 Fluent 쪽이 썼다. gettext c-format 쪽 원문은 못 읽었다(HTTP 429).
  - MASC 에서 쓰는 곳: `ui_text ~ko ~en`(lib·bin 34개 파일, `~ko:` 1,442번)을 파일로 뺀다면 catalog 에서 OCaml 을 생성한다. 그러면 언어 누락과 placeholder 불일치가 빌드 오류가 된다. UI 는 fallback 이 맞지만 모델용 프롬프트는 실패를 드러내야 한다. 지금 인라인 형태는 두 언어를 다 써야 컴파일된다. 외부화하면 이 보장을 잃는다. TUI 화면 문법 캠페인(in_flight)에 넘길 입력이고 따로 제안하지 않는다.
- `11` 영상 캡션
  - 질문을 알고 요약하면 55.2 에서 58.8 로 오른다(Table 5).
  - 단서: LLM 도 정확도를 바꾼다(Table 2: 50.8~61.2). 2023~2024 모델과 1인칭 영상 데이터다.
  - MASC 에서 쓰는 곳: 영상 읽기를 둘로 나눈다. 하나는 음성 트랙 전사다. 다른 하나는 Keeper 가 sha256·시간 범위를 주면 그 구간 프레임을 돌려주는 도구다. Keeper 가 필요한 구간만 당겨 오므로 누적 상한이 필요 없다. content block 에 Video 가 없으므로 Board `Video` 첨부의 입력 경로부터 확인한다.
- `12` provider 의 문서 입력
  - OpenAI 는 스프레드시트를 시트마다 첫 1,000행과 요약으로 준다.
  - 단서: 한도와 동작은 2026-11-12 문서 기준이다.
  - MASC 에서 쓰는 곳: failover 뒤에도 같은 사실을 유지할 공통 형식은 MASC 의 읽기 기록이다. H5 처럼, 턴을 받을 모델(candidate)이 그 형식을 못 받을 때만 읽기를 넣는다. 구간 타입은 Citations 의 쪽·글자 범위·블록 번호 구분을 선례로 삼는다. document 라우팅은 `supports_multimodal_inputs` 를, 직렬화는 `supports_document_input` 을 본다. 둘이 어긋날 때 어떻게 되는지는 확인하지 않았다(§14).
- `13` plugin version
  - manifest 에 version 을 고정하면, 저자가 그 문자열을 바꿀 때까지 사용자는 옛 사본에 머문다.
  - 단서: `npm` 과 git 이 아닌 로컬 디렉터리 source 는 version 이 `unknown` 이다. `command` source 는 늘 hash 로 계산한다. 모르는 최상위 키를 떼어 내고 경고만 하는 정책은 MASC 의 strict parse 와 반대라 가져오지 않는다.
  - MASC 에서 쓰는 곳: 세계 묶음의 id 는 내용의 SHA-256 으로 한다. 사람이 올리는 version 은 표시용으로 둔다. 원격에서 받을 때 기대 해시와 다르면 설치하지 않는다. `default_revisions` 가 이미 같은 해시를 쓴다. 묶음을 주고받는 일은 다계정 캠페인 뒤에야 실제로 필요해진다.
- `14` Agent Skills 와 AGENTS.md
  - 단서: 버전은 `metadata.version` 예시로만 나온다. 느슨한 로더와 깨진 YAML 고쳐 읽기는 가져오지 않는다(§15.1).
  - MASC 에서 쓰는 곳: Codex 같은 공식 클라이언트 runtime 의 Keeper 는 cwd 의 `AGENTS.md` 와 `.agents/skills` 를 읽는다. 묶음은 이것을 복사하지 않는다. 대신 Keeper 별 cwd 의 `AGENTS.md` 유무와 `.agents/skills` 의 skill 이름·해시를 기록한다. base path 는 그 cwd 가 아니다(`lib/keeper/keeper_codex_runtime.ml` 의 `native_cwd` 위 주석). cwd 는 sandbox 가 mount 한 host tree 이거나, MASC runtime root 아래 Keeper 전용 디렉터리다. 명세 자체는 `docs/research/2026-11-01-skills-authoring-and-observation.md` 가 이미 인용한다.

적용하지 않는 것:

- 묶음이 기본 system prompt 를 통째로 대체하기(Character Card `system_prompt` 와 `{{original}}`). managed prompt 는 부팅 때 바이너리에서 다시 동기화된다. 세계는 keeper instructions 로만 표현한다(`docs/design/world-presets.md`). 기본 프롬프트까지 바꾸면, 세계끼리 비교할 때 기본 프롬프트가 같아야 한다는 조건이 깨진다.
- MCP Sampling 으로 외부 서버가 MASC 의 모델을 빌려 미디어를 읽기. MCP 2026-07-28 이 Sampling 을 deprecated 로 내리고, 새 구현은 채택하지 말라고 적는다(`03`).
- 성공한 읽기(설명·전사)로 원본 블록을 대신하기. OpenClaw 문서도 화면·UI 검토에는 쓰지 말라고 적는다. H5 는 원본을 이력에 남기고, candidate 가 못 받을 때만 읽기를 넣는다. Whisper 전사는 1.4% 구간에서 지어냈다(`07`).
- `uri` 를 받아 스스로 가져오는 범용 변환 도구(MarkItDown MCP 등)를 Keeper 권한으로 붙이기. H5 가 `Url`·`File_id` 를 가져오지 않기로 정했다. MarkItDown 은 현재 프로세스 권한으로 I/O 하고, 로컬의 믿는 agent 용이라고 적는다. reader 에는 bytes 만 준다.
- `extensions` 필드(모르는 키 보존)를 지금 manifest 에 넣기. 두 번째 생산자가 없어 부르는 곳 없는 층이 된다. 필요해지면 선언된 불투명 필드로 넣는다.
- gettext 식으로 번역 전 문자열을 식별자로 쓰는 UI catalog. 그 문자열을 조금만 고쳐도 번역이 전부 fuzzy 가 된다(`10`). 식별자는 개발자가 정한 variant 로 둔다.
- 사용자 결정 때문에 뺀 8건은 §15.1 에 있다.

## 13. 서로 어긋나는 근거

주제가 달라도 같은 질문에 반대로 답하는 근거가 있었다. 아래는 그런 쌍을 질문마다 모은 것이다. 괄호의 ID 는 위 표의 발견이다. 「풀이」 는 두 근거가 다른 조건을 쟀는지, 어느 쪽이 MASC 에 가까운지를 적는다. 판정을 내리지 않은 질문은 §14 로 넘겼다.

### 13.1 병목은 사람인가, 인프라인가

- 사람이라는 쪽: 카파시는 에이전트가 만들고 사람이 검증한다고 말한다. 병목은 사람이라고 본다(karpathy-07, YC 발표 19:53~25:31). OpenAI 'Harness engineering'(2026-02-11) 글은 'our bottleneck became human QA capacity' 라고 적는다. 이 인용은 observability-self-improvement 보고서 본문이 사본에서 가져온 것이다. 재확인을 거치지 않은 한 팀의 경험담이라 수치는 옮기지 않았다.
- 인프라라는 쪽: Anthropic 의 하루 병합은 약 2,500건에서 30,000건 이상으로 늘었다. 원문은 병목을 'developer infrastructure built for human scale: source control, builds, and CI' 로 적는다. Anthropic 은 저장소 전체를 잠그는 직렬 병합 관문을 걷고 병합 뒤·배포 전 검사로 옮겼다(multi-agent-orchestration-02). Cursor 에서는 잠금이 제대로 돌아도 기다림 탓에 에이전트 20개가 2~3개 몫의 처리량으로 떨어졌다(multi-agent-orchestration-05). OpenClaw 는 runner 등록 수를 희소 자원으로 센다(product-prior-art-13). MASC 도 CI 자원이 한정이라고 정했다(결정 6).
- 풀이: 두 쪽은 다른 자리를 잰다. 사람 병목은 결과를 받아들이는 자리다. 인프라 병목은 낸 결과가 CI·병합 용량을 넘는 자리다. 모두 한 회사·한 팀의 보고이고 대조 실험이 없다. MASC 에서 어느 쪽이 먼저 막히는지는 잰 값이 없다(§14.1).

### 13.2 여러 에이전트는 이득인가

- 이득이라는 쪽: 단일 에이전트 평균과 견주면, 나눌 수 있는 금융 추론에서 다중 구조가 57~80.8% 높았다(multi-agent-orchestration-07, Figure 2). 에이전트 16개가 GCC 를 정답 기준으로 삼아 약 2주에 10만 줄 C 컴파일러를 만들었다(multi-agent-orchestration-12). 이 사례는 단일 에이전트와 견준 값이 없는 경험담이다. 카파시는 2026-03-09 에 agent swarm 이 'going to work' 라고 썼다(karpathy-05).
- 손해라는 쪽: 같은 Figure 2 에서 순서가 묶인 계획은 39~70%, SWE-bench Verified 는 2~15% 낮았다. Anthropic 은 다중 에이전트가 같은 일에 토큰을 3~10배 쓴다고 적는다(multi-agent-orchestration-14). debate 의 이득은 대부분 다수결에서 왔다(system12-hooks-proactive-05). 카파시는 2026-03-20 에 자기 병렬 설계가 아직 마음에 들지 않는다고 말했다(karpathy-05).
- 풀이: 이득을 본 사례에는 나눌 수 있는 일과 기계가 판정하는 기준이 함께 있었다. Anthropic 은 나란히 돌려 얻는 것이 속도보다 빠짐없음이라고 적는다(multi-agent-orchestration-14). SWE-bench 칸은 20문항이고 칸마다 95% 신뢰구간이 약 ±20%p 다. 그래서 코딩 쪽 근거는 약하다.

### 13.3 판정자에게 더 보여 주면 나아지는가

- 나아졌다는 쪽: 증거를 직접 읽는 판정 agent 는 OpenHands black-box 평가에서 사람 합의와 90.44% 일치했다. 한 번 묻는 LLM 판정자는 60.38% 였다(system12-hooks-proactive-04). 이 차이는 한 건의 값이다. MetaGPT 에서는 88.52% 대 84.15% 였다. 개선을 제안하는 에이전트도 요약보다 원 실행 기록을 받을 때 중앙값이 높았다. 요약은 34.9, 원 기록은 50.0 이었다(Meta-Harness Table 3, 한 과제의 값, §7 「적용하지 않는 것」).
- 나빠졌다는 쪽: 승인 판정자에게 assistant 글과 도구 결과를 주면 과잉 행동 시험 성능이 떨어졌다(system12-hooks-proactive-02). 주제는 같지만 답이 아닌 문장은 입력이 길수록 답을 더 깎았다(memory-graph-12).
- 풀이: 나아진 쪽은 판정자가 artifact 와 원 기록을 읽은 완료 판정이다. 나빠진 쪽은 행동 승인 판정과 방해 문장 실험이다. 판정 종류마다 입력 범위를 따로 잡는다. MASC 판정자에게 어느 쪽이 맞는지는 잰 값이 없다.

### 13.4 지시문 한 줄이 행동을 바꾸는가

- 바뀌었다는 쪽: ImpossibleBench 의 Conflicting-LiveCodeBench 에서, 느슨한 프롬프트에서 GPT-5·o3 모두 85% 넘게 속였다. 가장 엄격한 프롬프트에서는 GPT-5 1%, o3 33% 였다(ImpossibleBench §5.1, agent-economy-02 의 출처). MAST 에서 지시만 고친 ChatDev 는 25.0 에서 34.4 로 올랐다(system12-hooks-proactive-07). 'Mom Cancer' 문장은 MMLU-Pro 한 조건에서 약 10%p 올렸다(agent-economy-09).
- 안 바뀌었다는 쪽: 꼭 필요할 때만 도우라는 지시를 받은 모델도 헛경보가 50% 를 넘었다(system12-hooks-proactive-03). 'Please do not cheat.' 를 덧붙여도 o3 의 reward hacking 은 80% 였다(agent-economy-03). 이 값은 과제 하나에 조건마다 20회 돌린 결과이고, 배포 전 o3 다. 카파시는 CLAUDE.md 에 지시를 적는 간단한 시도를 몇 번 해도 그대로였다고 썼다(karpathy-03). 팁·협박 문장은 성적을 대체로 유의하게 바꾸지 않았다(agent-economy-09).
- 풀이: 같은 문장도 과제·모델에 따라 효과가 없음에서 큼까지 흔들렸다. 구조를 바꾼 쪽의 효과가 지시만 고친 쪽보다 큰 사례가 있었다. MAST 의 한 system 에서 topology 변경은 +15.6%p, 지시만 고친 쪽은 +9.4%p 였다. 그만두는 길도 모델마다 효과가 달랐다. GPT-5 속임률은 54% 에서 9% 로 줄었다(ImpossibleBench §5.3). Claude Opus 4.1 에서는 그 효과가 훨씬 작았다. 결정 1 은 이 근거와 같은 방향이다. 결정의 근거를 「지시문은 효과가 없다」 로 적으면 원문보다 세다.

### 13.5 스스로 나아지는 고리는 쌓이는가

- 쌓인다는 쪽: autoresearch 는 고정 평가로 약 700개를 시도해 약 20개를 남겼다. Time to GPT-2 는 2.02h 에서 1.65h 로 줄었다(karpathy-01). 중간 값 1.80h 는 에이전트가 남긴 변경을 사람이 depth=24 모델에 쌓아 잰 값이다. 큰 모델로 옮겨도 되는지도 사람이 확인했다. GEPA 는 여섯 과제에서 GRPO 보다 원문 표기로 '+6%' 높았다(observability-self-improvement-05). 정답 표시 없는 온라인 ACE 도 평균은 +3.8 이었다(observability-self-improvement-02).
- 무너진다는 쪽: 과제를 풀기 전에 스스로 쓴 Skill 은 기준선보다 8.1~11.5%p 낮았다(observability-self-improvement-03). 자동 자기개선 방법 셋 모두 음수 칸이 있었다(observability-self-improvement-04). 자동 판정자로 고른 기억은 12칸 중 6칸에서 고정 기억보다 낮았다(observability-self-improvement-01). 채점이 읽는 기록을 지워 만점을 받은 사례도 하나 있다(observability-self-improvement-06). 카파시는 LLM 판정자 점수에 대고 가중치를 강화학습으로 고치는 경우를 말한다. 학습 step 10~20번은 버텨도 100~1,000번이면 판정자를 속이는 답이 나온다고 한다(karpathy-04).
- 풀이: 평균이 오른 결과와 음수 칸이 같은 논문 안에 같이 있다. 쌓인 쪽에는 에이전트가 못 바꾸는 평가가 있었다. 무너진 쪽은 신호를 스스로 만들었거나 채점에 손이 닿았다. 그래서 평균 하나로 판단하지 않는다. 같은 case 끼리 짝지어 나아진 것과 나빠진 것을 센다(observability-self-improvement-04 의 「MASC 에서 쓰는 곳」).

### 13.6 판정자는 너무 너그러운가, 너무 깐깐한가

- 너그럽다는 쪽: 자동 채점을 통과한 AI PR 296건을 maintainer 4명이 봤다. maintainer 가 병합하겠다고 본 비율은 자동 채점 통과율보다 평균 24.2%p 낮았다(observability-self-improvement-07). LoCoMo 의 'be generous' 판정자는 일부러 틀리게 쓴 모호한 답의 62.81% 를 통과시켰다(memory-graph-10).
- 깐깐하다는 쪽: OpenAI 는 자주 실패한 SWE-bench Verified 138문제 중 59.4% 에서 시험·설명 결함을 찾았다. 맞는 답을 떨어뜨리는 시험이 섞여 있었다(사본, §7 의 `07` 아래 목록). LoCoMo 정답 1,540개 중 99개(6.4%)도 틀려 있었다. 그 가운데 13개는 AMBIGUOUS 로 분류됐다(memory-graph-10).
- 풀이: 두 방향의 오류가 다 있다. METR 은 거짓 통과 쪽만 쟀고, OpenAI 의 검토는 거짓 거절 쪽을 봤다. MASC Verifier 의 두 방향 오류율은 모른다(§14.1). 그래서 Verifier 의 판정도 맞았는지 따로 센다. 두 방향 오류 근거가 모두 이 적용을 받친다.

### 13.7 새 입력은 도는 턴에 끼어들어야 하는가

- 끼어든다는 쪽: OpenClaw 는 도는 턴에 새 입력을 도구 경계에서 넣는다. Amp 도 2026-09-08 에 기본 동작을 queue 에서 steer 로 바꿨다(product-prior-art-12).
- 기다린다는 쪽: interrupt 로만 받는 system 은 과부하에서 처리량이 0 으로 떨어졌다. 수리는 일이 남은 동안 interrupt 를 꺼 두는 혼합 설계였다(system12-hooks-proactive-10). Erlang 은 우선순위를 두 class 로만 넣고, 받는 쪽이 켜게 했다(system12-hooks-proactive-14). email·IM 알림으로 끊긴 사무직 27명은 원래 일로 돌아오는 데 10~15분을 더 썼다(system12-hooks-proactive-11).
- 풀이: steer 가 주의력이나 완료율을 얼마나 바꾸는지 잰 값은 어느 제품 문서에도 없다. livelock 근거는 1996년 kernel 이고, 에이전트 큐로 옮긴 것은 비유다. Amp 글도 queue 를 남겼다('you can still queue'). 지금 설계에서 도는 턴을 끝내는 것은 운영자 interrupt·stop 뿐이고, 나머지는 턴 경계에서 받는다. 이 설계를 바꿀 근거는 아직 없다.

### 13.8 상한은 지우는 쪽인가, 다는 쪽인가

- 지운다는 쪽: Claude Code 는 subagent 200개 상한과, subagent 가 띄운 background 명령의 1시간 제한을 지웠다(product-prior-art-14). MASC 헌법은 누적 횟수·시간 Gate 와 magic number 를 금한다(446·450·464행).
- 단다는 쪽: 같은 changelog 가 26일 뒤 background 명령 시간 제한을 다시 넣었다. 기본 30분, 최대 2시간이다. idle check-in 도 goal 당 세 번으로 묶었다(product-prior-art-14). Claude Code Stop hook 은 8번 연속 상한을 둔다(system12-hooks-proactive-08). Codex Auto-review 는 연속 3번, 또는 50번 중 10번 거절하면 턴을 끊는다(system12-hooks-proactive-09). Anthropic 은 서로 반응하는 고리를 끝내는 방법으로 시간 예산, N 주기 수렴, 전담 판정자를 든다(multi-agent-orchestration-10).
- 풀이: 바깥 제품은 무인 세션의 안전 정지로 상한을 쓴다. 어느 문서도 상한의 효과를 재지 않았다. MASC 는 이 질문을 결정 3 으로 이미 닫았다. 상한 사례는 §15.1 에 모았다. 고리를 끝내는 세 방법 가운데 결정과 맞는 것은 전담 판정자뿐이다. MASC Board 판정이 같은 역할인지는 해석이다(§2 의 `10`).

### 13.9 기억은 다 넣을까, 골라 넣을까

- 다 넣는 쪽: LoCoMo 에서 전체 맥락을 받은 GPT-4.1-mini 는 CoT 프롬프트로 92.62% 를 내, 기억 시스템 보고값 92.32% 를 넘었다(memory-graph-10). MemoryArena 에서 같은 task agent 의 긴 맥락은 0.16 으로, GraphRAG(2D 설정) 0.17 과 비슷했다(memory-graph-03).
- 골라 넣는 쪽: LongMemEval 306문항에서, 관련 부분만 담은 약 300토큰 입력을 받은 쪽의 점수가 약 113k 토큰 전체 입력보다 높았다. 평가한 모든 모델에서 그랬다(memory-graph-12). 전부 저장하는 기억은 네 에이전트 모두에서 고정 기억보다 낮았다(observability-self-improvement-01). 카파시도 context window 가 넘치거나 무관하면 비용이 오르고 성능이 떨어질 수 있다고 쓴다(karpathy-08).
- 풀이: 골라 넣기 쪽의 300토큰 입력은 정답 표시에서 뽑은 발췌라 상한값이다. 실제 선택기는 이 상한을 넘지 못한다. LoCoMo 는 정답 6.4% 가 틀린 벤치마크다. 두 쪽 모두 Keeper 턴에서 잰 값이 없다. recall 선택 주입(RFC-0517)은 in_flight 라 이 근거만 넘긴다. 고른 것과 쓰인 것을 같이 남기면, 선택기가 상한에서 얼마나 먼지 잴 수 있다.

### 13.10 그래프는 검색을 이기는가

- 이긴다는 쪽: HippoRAG 2 는 passage 를 가리키는 그래프로 recall@5 평균 78.2 를 내, dense 검색 73.4 보다 높다(memory-graph-01). LLM 이 뽑은 인과 그래프에 도구 검색을 붙인 AMA-Agent 는 평균 ACC 0.5722 로 BM25 0.3436 보다 높다(memory-graph-04). GraphRAG-Bench 의 Novel 자료에서 Complex 질문은 HippoRAG 2 53.38, RAG 42.93 이다. Medical 자료에서는 Fact 질문에서도 HippoRAG 2 가 66.28 로 RAG 64.73 보다 높다(memory-graph-02).
- 진다는 쪽: 같은 HippoRAG 2 표의 색인형 HippoRAG(재현)는 recall@5 63.8 로 dense 아래다(memory-graph-01). 요약으로 corpus 를 넓힌 GraphRAG·LightRAG 는 QA F1 평균이 49.6·6.6 으로 dense 57.0 보다 낮다(memory-graph-01). GraphRAG-Bench Novel 의 Fact 질문은 RAG w/ rerank 60.92, MS-GraphRAG(local 검색) 49.29 다(memory-graph-02). MemoryArena 에서 GraphRAG(2D 설정)는 0.17 로 text-embedding-3-small 0.20 보다 낮다. 다만 성공률이 모두 0.2 아래라 차이가 작다(memory-graph-03).
- 색인 비용: GraphRAG 는 passage 11,656개를 색인하는 데 입력 115.5M 토큰과 277분을 썼다. 같은 표의 HippoRAG 2 는 9.2M 토큰과 99.5분이다(memory-graph-14). 헌법은 비용을 판단 기준으로 두지 않는다(519행). 그래서 이 값은 사실로만 적는다.
- 풀이: 「모든 것이 그래프」(요구 21)는 이미 저장된 typed edge 를 읽는 projection 으로 만든다. HippoRAG 2 와 GraphRAG 비교가 이 방향을 받친다. 이긴 쪽은 passage 를 가리키는 그래프이거나, 여러 단계를 잇는 질문이었다. 같은 색인형이라도 HippoRAG(재현)는 dense 에 졌다. AMA-Agent 는 원래 기록의 색인이 아니고 저자 시스템이다. 카파시의 wiki 도 index 파일과 짧은 요약에 검색 도구를 따로 붙였다(karpathy-12).

## 14. 모르는 것

12개 보고서와 재확인이 「모른다」 「확인 필요」 로 남긴 것을 성격별로 묶었다. 괄호는 그 질문을 남긴 주제다.

### 14.1 MASC 운영 값: 운영 데이터를 열지 않아 모른다

운영 데이터는 디렉터리 크기와 파일 수만 봤다. 그래서 아래 값은 모른다.

- Verifier 의 거짓 통과·거짓 거절 비율. 바깥 수치는 SWE-bench 에 한정되고, METR 은 거짓 통과 쪽만 쟀다(observability-self-improvement). `<base-path>/.masc/verdicts`(파일 172개, 7.3 MiB)에 사람 라벨이 얼마나 있는지도 모른다(multi-agent-orchestration).
- 스스로 발행된 Skill 수, 쓰인 횟수, 판정과의 관계(observability-self-improvement).
- Jev confidence 가 MASC 분포에서 정답률과 맞는지. 사람 라벨이 없다. 2026-09-18 재생 35건은 오류가 없어 calibration 을 못 잰다(system12-hooks-proactive).
- Board attention 에서 놓친 relevant 와 불필요한 wake 가운데 어느 쪽이 비싼지. 놓침 쪽 지표가 있는지도 모른다(system12-hooks-proactive).
- event 도착 간격 분포와 `ProactiveOutcome` 의 noop 몫(system12-hooks-proactive, multi-agent-orchestration).
- 병목이 사람 쪽인지 CI·병합 쪽인지(§13.1). Task 를 만든 Keeper 가 승인된 완료의 Board 판정 글을 실제로 읽는지(multi-agent-orchestration).
- 운영 중인 Candle `half_life` 값. 2026-10-21 검토 문서는 168시간이라고 적었다(agent-economy).
- fleet_bytes_per_token 3.39 가 Claude·Codex lane 에서 어느 쪽으로 얼마나 어긋나는지(observability-self-improvement).
- `<base-path>/.masc` 최상위 165개 항목 각각의 백업 등급과 파일 수(storage-sync).
- 운영자가 동작 창을 실제로 익히는지. MASC 는 키 사용 기록을 모으지 않는다(tui-music).

### 14.2 MASC 코드에서 확인하지 않은 것

조사 범위 밖이라 코드를 끝까지 읽지 않은 질문이다.

- 턴 기록: 운영자 끼어들기와 Keeper 의 되묻기가 턴 기록에 세어 남는지. recall 된 fact id 가 턴마다 남는지(observability-self-improvement).
- 판정 입력: auto judge 입력에 Keeper 의 설명·도구 결과가 들어가는지. Fusion judge 단계와 verifier 가 원 증거를 도구로 읽는지. 판정자가 panel 답의 출처 runtime 을 보는지(system12-hooks-proactive, karpathy).
- 깨움과 큐: 턴 중에 온 `Attention_wake` 가 다음 intake 에 묶이는지. 판정 lane 이 턴 실행과 slot 을 다투는지(system12-hooks-proactive). 모델 호출을 사이에 둔 잠금이 있는지(multi-agent-orchestration).
- 저장: 데이터 파일 잠금이 MASC 에서 실제로 풀리는 조합이 있는지. `sync_file_and_parent_strict` 를 부르는 나머지 아홉 파일이 「내용이 같으면 sync 만」 유형인지. durable record 가 절대 경로·inode·pid·hostname 을 사실로 저장하는 곳이 모두 어디인지. `Unix.lockf` lease 가 네트워크 파일시스템에서 지켜지는지(storage-sync, product-prior-art).
- 권한과 노출: agent card 를 내는 경로를 읽는 저장소 밖 소비자가 있는지(multi-agent-orchestration). Keeper 에게 GitHub 자격을 건네는 경로가 일에 필요한 범위보다 넓은 권한을 주는지(sandbox-microvm-ssh). 원격 MCP 표면이 승인 응답까지 내놓는지(product-prior-art).
- Candle: Candle 원장 쪽에 확인하지 못한 것이 하나 있다. 세부는 여기 싣지 않는다. Keeper 를 지웠을 때 지갑 잔액이 어떻게 되는지(agent-economy).
- 묶음과 이식: BasePath 백업·내보내기 모듈이 있는지(product-prior-art). keeper TOML 에 비밀값이 들어갈 필드가 있는지. 세계를 갈아 끼운 뒤 이어받은 공식 클라이언트 세션이 옛 지시문을 기억한 채 도는지. 운영 중에 `/preset restore` 로 seed 프리셋을 갈아 끼우는 경로가 있는지(portability-text-multimodal).
- 멀티모달: Board `Video` 첨부가 Keeper 턴 입력으로 들어오는 경로. `supports_multimodal_inputs` 와 `supports_document_input` 두 값이 어긋나는 행에서 문서 블록을 어떻게 다루는지. 내장 STT endpoint 가 구간 시각을 돌려주는지(portability-text-multimodal).
- 기억: `activity_graph` 의 `kind : string` 을 닫힌 타입으로 읽는 곳. recall harness 가 질문 종류를 나누는지. wiki `stale_revision` 이 얼마나 자주 나는지. host recall 이 live 에서 도는 범위(memory-graph).
- 그 밖: provider 중립인 요청 단위 깊이 타입이 있는지. 성공 조건을 누가 고쳤는지가 Verifier 입력이나 사람 확인 화면에 보이는지. 밖에서 설치하는 Skill·MCP 서버의 출처가 digest 로 고정되는지. Dashboard·TUI 에 wiki·Artifact 변경을 보여 주는 화면이 있는지(karpathy). Linux 배포가 eio_linux 를 쓰는지. `run_in_systhread` 78곳과 `Eio.Path` 587곳 가운데 main OCaml 도메인에서 도는 수. 부팅 때 425 MB 되읽기가 남았는지(ocaml-oxcaml).

### 14.3 이 기기와 배포 환경에서 재지 않은 것

- 격리: 이 M3 Max 의 `--virtualization` 게스트 안에 `/dev/kvm` 이 뜨고 Kata·microsandbox 게스트가 부팅하는지. `srt` 로 감싼 Claude Code 와 `deny` 프로필 Codex 가, 계정별 설정 배치에서 로그인·토큰 갱신까지 도는지. 다른 사람 home 읽기가 모든 도구 경로에서 거절되는지. `--tools ""` 인 Claude Code 가 입력 글 안의 파일 참조를 스스로 펼치는지(#51072). Apple `container` 게스트의 payload 가 네트워크 정책이 보지 않는 통로로 호스트 서비스에 닿는지(sandbox-microvm-ssh).
- 원격: LAN·WAN 끝점에서 요청마다 새로 인증하는 SSH 의 지연. 저장소에는 같은 Mac 게스트 sshd 로 잰 p50/p90 98/129 ms 만 있다. 공유 끝점에서 sshd `MaxStartups`·`PerSourcePenalties` 에 걸리는 빈도. microVM 공유 디렉터리(virtiofs 등)의 잠금 의미(sandbox-microvm-ssh, storage-sync).
- 저장: sync 비용의 제대로 된 측정. 이번 값은 부하가 높은 상태에서 40회 한 번이다. APFS 가 fsync 실패 뒤 페이지를 어떻게 다루는지. Linux fsync 가 장치 캐시까지 내리는지. `fold_jsonl_lines` 가 OCaml 도메인을 막는 시간(storage-sync).
- 빌드: `masc` 의존성 전체가 5.4.0+ox 에서 solve·빌드되는지. `.mli` 한 줄 변경 때 다시 도는 규칙 수·시간과 dune cache 적중률. 전체 @runtest 의 링크 시간과 디스크. frame pointer·xctrace 로 Eio fiber 스택이 끝까지 풀리는지. flambda 1 의 이득과 컴파일 시간. memtrace master 가 5.5.2 에서 다중 도메인 trace 를 맞게 내는지(ocaml-oxcaml).
- TUI·음악: kitty·iTerm2·WezTerm·Windows Terminal 에서 한글 입력기와 kitty keyboard flag 의 실제 동작. SSH 지연에서 터미널 탐침의 deadline. NDJSON + base64 PCM 전송의 지연과 CPU(tui-music).
- 멀티모달: 한국어 문서·음성에서 reader 품질과 STT 환각 비율. 서식 민감도가 지금 쓰는 모델에서 얼마나 큰지(portability-text-multimodal).

### 14.4 바깥에도 답이 없는 것

찾아봤지만 측정이나 1차 자료가 없었다.

- 쌓이고 감쇠하는 화폐가 LLM 에이전트의 행동을 바꾸는지. LLM Keeper 가 scrip 이론의 문턱 전략처럼 움직이는지. 감쇠하는 Candle 옆에 감쇠 없는 Stock 을 둘 때의 규칙(agent-economy). 'Stock' 이 무엇의 지분인지는 사용자가 정할 일이다.
- LLM agent 의 턴 중간 interrupt 비용(system12-hooks-proactive). 큐를 턴마다 하나씩 비울 때와 묶어 비울 때의 차이(multi-agent-orchestration). steer 가 주의력이나 완료율을 바꾸는지(product-prior-art).
- host 가 밀어 넣는 recall 과 모델이 도구로 당기는 recall 의 비교. 여러 영속 에이전트가 한 기억 저장소에 동시에 쓰는 벤치마크(memory-graph).
- 턴 끝 판정자(prompt hook, `/goal` 판정자, Codex Auto-review)의 오판율(product-prior-art). 같은 모델 리뷰어의 효과는 보고가 엇갈리고 통제된 측정이 없다(multi-agent-orchestration).
- 검증된 실행 뒤에 뽑아 쓴 Skill 이 코딩 에이전트에서 이득인지. GEPA 류 최적화가 Keeper 지시문처럼 길고 목적이 여럿인 글에서 통하는지(observability-self-improvement).
- 유머의 효과를 잰 근거는 경험 보고와 1999년 실험의 초록뿐이다(agent-economy, tui-music-14).
- 재현: autoresearch 수치, EvoAgentBench·SkillOpt·Meta-Harness, LoCoMo 감사와 HaluMem 의 독립 재현을 찾지 못했다. Anthropic(n=52)과 OpenAI(내부 traffic)의 판정자 수치도 밖에서 재현한 자료를 찾지 못했다.
- 제품 문서의 빈칸: Claude Code `/usage` 의 귀속 계산 방법, Codex 가 MCP 서버를 지운 이유, dots·Grok Bot·Amp Spaces 의 동시성·잠금·권한 모델(product-prior-art).

### 14.5 버전이 바뀌면 다시 볼 것

- OTel GenAI 규약 새 저장소의 첫 release(observability-self-improvement-11). MCP 다음 버전의 날짜와, Tasks 가 코어에 들어가는 시점(multi-agent-orchestration-09).
- OxCaml 이 5.5 위로 올라가는 시점, Eio EINTR 수정 릴리스, Jane Street upstream 5.4+ 용 v0.18(ocaml-oxcaml). Irmin 4(Eio) 출시(storage-sync).
- Ubuntu 24.04 의 SQLite 3.45.1 계열에 WAL-reset 수정이 들어갔는지(storage-sync-13). alphaTab 1.9.0 의 alphaTex 문법 변화(tui-music-07).
- OpenClaw 사람별 model 계정이 들어간 릴리스(product-prior-art-04). OpenAI Prompt caching 문서에는 갱신일이 없다(observability-self-improvement-13). METR 시간 지평 페이지는 2026-09-08 뒤 갱신이 없다.
- in_flight 캠페인의 상태: 계획 작업의 공통 입력 문서는 #50589 를 Draft 로 적었다. 11-12 조회에서는 MERGED 였다(sandbox-microvm-ssh). 다른 캠페인도 그 문서를 쓴 뒤 바뀌었을 수 있다.
- 코드 좌표: 조사 도중 main 이 `efe98ca792c2` 에서 `77f7bec3039f` 로 옮겨졌다. 인용 파일은 바뀌지 않았다. TUI 좌표 셋은 재확인 때 이미 옮겨져 있었다(tui-music-06·08·14).

### 14.6 원문을 열지 못한 것

다음은 원문을 열지 못해 근거로 쓰지 않았거나, 초록·사본으로만 읽었다.

- 막힌 주소: OpenAI 'Harness engineering' 과 'Why we no longer evaluate SWE-bench Verified' 는 403 이라 사본으로 읽었다. 사본 뒤에 고쳐졌는지는 모른다.
- 읽지 못한 주소: Morkes 등 본문(403), Ahrefs Medium 글(403), Hermes `messaging/a2a`·`web-dashboard` 문서(429), gettext `c-format` 문서(429), Firecracker NSDI '20 논문(404, 주소 없음), MIDI 2.0 명세 본문(로그인 필요). Cognition 'Verifying Agentic Development at Scale' 은 주소를 찾지 못했다.
- 초록이나 요약만 읽은 것: Zhang 등 2502.08788, Khan, Kenton, Smit, Panickssery, CALM, Huang, Czerwinski 2004(system12-hooks-proactive). OxCaml JSON 파서 발표(ocaml-oxcaml). Orca, OpenHands, Letta Code, Goose, Gas City 의 릴리스 목록(product-prior-art).
- 읽지 않은 원문: HippoRAG 1 본문, Letta 현재 문서, Mem0 2026 보고서, Graphiti 문서 사이트(README 는 읽음), Memanto, MemPalace 의 주장(memory-graph). Manifold mana 조정 경위, Axie Infinity SLP, Ottaviani & Sørensen 2007(agent-economy). Crossing the Streams 논문, Cloud Hypervisor 부팅 시간, Daytona 의 격리 기술(sandbox-microvm-ssh). Minsky 발표 영상, VPNKit 2018, MirageOS defunctorising(ocaml-oxcaml). 카파시의 2026-06-09~10-31 X 글은 훑지 못했다. 2026-11-06 'harness engineering' 글은 원문을 찾지 못했다(karpathy).

## 15. 사용자 결정과 부딪혀 쓰지 않은 것

조사 보고서가 「적용하지 않음」 으로 적은 것 가운데 79건은 이유가 셋 중 하나다. 사용자 결정, 헌법 조항, 운영자의 저장소 밖 작업 지침이다. §15.1 에 이것을 이유별로 모았다. 조사 보고서의 「MASC 에서 쓰는 곳」 이 결정과 부딪힌 26건은 §15.2 에 적었다. 부딪히지 않게 좁히는 조건도 같이 적었다. 나머지 「적용하지 않음」 은 각 절 끝에 있다.

사용자가 이미 정한 것은 열넷이다(계획 작업의 공통 입력 문서 2절).

1. Keeper 프롬프트 문장, 금지·필수 규칙, yield 규칙, 강제 제약을 제안하지 않는다. 남은 강제 장치는 지운다.
2. Ledger 는 사실을 적는 evidence authority 이고 workflow engine 이 아니다. 새 상태·필드·Gate 는 없으면 durable truth 가 깨질 때만 더한다. Keeper 사이 요청은 일반 메시지다.
3. 누적 turn·time·token·cost 숫자로 행동을 막지 않는다. magic number, 문자열 매칭, 재생에서 고른 상수, 최근성 대리 지표 위에 설계하지 않는다.
4. 근본 수리는 규칙 하나에서 끌어낸다. 결정을 올릴 때는 정석을 근거·측정·대가와 같이 적는다.
5. 줄 수 상한 같은 크기 검사를 CI·lint 에 넣지 않는다.
6. PR·병합 수에 비례하는 CI 비용을 늘리지 않는다. PR push 로 CI 를 시작하지 않는다.
7. 죽은 시험은 지운다. TUI 화면 문구·배치 시험을 만들지 않는다. 부르는 곳 없는 층에 시험을 쌓지 않는다.
8. hard cut 은 지우고 설치다. 호환 reader·converter·migration 을 만들지 않는다.
9. 정리 변경은 제품 품질을 높인다는 증거가 있을 때만 낸다.
10. Keeper 는 Candle 지급 규칙을 모른다. Candle 로는 초상화 장신구만 산다. 경제 확장은 헌법 candle 절 개정이 먼저다.
11. 다계정은 다른 사람의 home 을 안 읽는다고 증명된 posture 만 허용한다.
12. 리뷰 판정 기준은 서버마다 운영자가 정하는 정책이다.
13. Docker 는 가장 뒤 순위다. microVM 과 RemoteSSH 가 앞이다.
14. 돈·시간을 들인 산출물은 저장소 루트 `artifacts/<topic>/` 에 둔다.

### 15.1 「적용하지 않음」 79건, 이유별

항목 끝 괄호는 그 제안을 적은 주제다. 근거로 든 바깥 자료는 그 주제의 보고서에 있다.

**결정 1. Keeper 프롬프트 문장·강제 제약 (9건)**

- program.md 의 NEVER STOP·LOOP FOREVER 같은 명령문을 Keeper 지시문에 넣기. 계속 도는 일은 Schedule·Proactive·큐가 맡는다(karpathy).
- 아첨·성격 문제를 Keeper 프롬프트 문장으로 고치기. 카파시도 지시 파일로 간단히 몇 번 고쳐 봤지만 그대로였다고 적었다(karpathy).
- 조율 문제를 Keeper 프롬프트 문장이나 강제 제약으로 고치기. Cursor 의 'Constraints are more effective than instructions', Anthropic 의 난이도별 하위 에이전트 수 규칙, Vend 의 절차 강제가 그 예다(multi-agent-orchestration).
- 통계·교훈을 playbook 문장으로 Keeper 프롬프트에 자동 주입하기. ACE 와 Dynamic Cheatsheet 의 방식이다. arXiv 2602.11988 Table 2 에서 LLM 이 만든 지침 파일은 해결률을 못 올리고 비용을 20%·23% 올렸다(observability-self-improvement).
- Keeper 프롬프트에 「꼭 필요할 때만 알려라」 를 넣기. 그 지시는 헛경보를 줄이지 못했다(system12-hooks-proactive-03).
- Keeper 프롬프트에 「네트워크가 닫혀 있다」 같은 문장을 넣기. 닫힌 사실은 도구 결과의 typed 맥락으로 준다. 이슈 #32799 의 범위다(sandbox-microvm-ssh).
- Anthropic memory tool 이 system prompt 에 넣는 강제 문장. 같은 문서는 오래 안 읽은 기억 파일을 주기적으로 지우라고 권한다. 이 권고는 헌법 `no_wall_clock_death` 와도 부딪힌다(memory-graph).
- 압박하는 상위 에이전트·OKR 문장, Candle 을 미끼로 거는 문장. 결정 10 과도 부딪힌다(agent-economy).
- Keeper 턴 끝에 Stop hook 으로 막고 다시 돌리기. Claude Code `/goal`, Codex·Factory Stop hook, Hermes `pre_verify` 가 그 예다. MASC 의 판정 자리는 Keeper 턴이 아니고 Goal·Task 검증이다(product-prior-art).

**결정 2. Ledger·Gate·Keeper 사이 요청 (7건)**

- Software 3.0 을 「신경망이 다 한다」 로 읽고 Ledger·Gate 를 LLM 판단으로 바꾸기. 카파시도 YC 발표 05:39~06:09 에서 기능마다 1.0·2.0·3.0 을 고르라고 말한다(karpathy).
- 의존성이 안 끝난 일을 막는 작업 목록(Claude Code agent teams). 그 문서도 상태 표시가 늦어 뒤따르는 일이 막힌다고 적는다(multi-agent-orchestration).
- A2A 의 Task 계약(상태, 응답, 재전송)을 Keeper 사이 요청에 쓰기. A2A 는 바깥 경계에서만 선택지다(multi-agent-orchestration).
- MemTX 의 action gate, 수명 단계 여덟 개, 문턱값 0.6·0.9. 근거는 저자가 만든 suite 하나다(memory-graph).
- 판정 통계로 Skill·기억을 자동 삭제·강등하기. 삭제 문턱값은 재생에서 고른 상수가 된다(observability-self-improvement).
- hypervisor 메모리 snapshot·resume 으로 Keeper 이어가기. Devin, E2B pause, Firecracker snapshot, msb fork 가 그 예다. VM 메모리가 Ledger 와 따로 노는 원본이 된다. Firecracker 문서는 같은 snapshot 을 두 번 resume 하면 안전하지 않다고 적는다(sandbox-microvm-ssh).
- 저장된 실행 결과를 재생해서 복구하기(Claude Code workflows replay). 입력이 고정된 스크립트 실행에만 맞는다. Keeper 턴은 기록을 맥락으로 주고, 다음 행동은 Keeper 가 고른다(product-prior-art).

**결정 3. 누적 숫자·magic number·문자열 매칭·재생 상수·최근성 (30건)**

- 5분 같은 고정 시간 예산으로 Keeper 턴 자르기. autoresearch 의 5분은 실험끼리 비교하려는 평가 조건이다. 헌법 464행(budget_gate)에도 걸린다(karpathy).
- leash 를 diff 줄 수나 chunk 크기 상한으로 구현하기. 결정 5 와 헌법 446행(magic_number)에도 걸린다(karpathy).
- append-and-review note 의 「오래된 것은 가라앉는다」 를 기억 정리 규칙으로 쓰기(karpathy).
- 「사람 1명에 에이전트 5」 같은 비율을 설계 상수로 쓰기. 측정 없는 그림이다(karpathy).
- 횟수·시간 문턱으로 진척이 없다고 판정해 다시 계획하거나 끝내기. Magentic-One 의 진척 없음 횟수, generator-verifier 최대 반복, 시간 예산과 N 주기 수렴이 그 예다. 헌법 450행은 반복 횟수를 진척이 멈췄다는 근거나 중단의 근거로 보지 않는다. 464행은 누적 time 으로 행동을 막는 Gate 를 금한다. 세 방법 가운데 전담 판정자만 결정과 맞는다. MASC Board 판정이 같은 역할인지는 해석이다(multi-agent-orchestration).
- 토큰 배수(15배, 3~10배)나 팀 크기 권고('3-5 teammates', '20-30 agents')를 한도로 쓰기. 헌법 464·519행에 따라 관측 값으로만 쓴다(multi-agent-orchestration).
- Generative Agents 점수식(가중치 1, 시간당 감쇠 0.995, reflection 문턱값 150). RFC-0247 이 점수 기반 recall 을 이미 걷었다(memory-graph).
- LatticeMind 의 근거 종류 가중치, 최근성으로 동점 가르기, regex 검사기. 진 주장을 Contested 로 남기는 생각만 참고한다(memory-graph).
- Governed Memory 의 recency 반감기 38일, 유사도 문턱값 0.92·0.95. 헌법 `no_wall_clock_death` 와도 어긋난다(memory-graph).
- Graphiti 기본 문턱값(중복 0.7, 모순 0.8)을 판정 확률에 걸기. MASC 흡수 판정은 닫힌 선택이다(memory-graph).
- Mastra 의 토큰 문턱값으로 관찰 log 전환하기(memory-graph).
- vanilla OCaml 에서 할당 0 을 CI 규칙으로 걸기. 검사기는 OxCaml 에만 있다. vanilla 에서는 실행 측정값과 문턱값을 비교해야 한다(ocaml-oxcaml).
- Semgrep dynamic_gc 의 heap 2 GB·4 GB 설정값 가져오기. Semgrep workload 에서 고른 상수다(ocaml-oxcaml).
- 토큰·비용·턴 수 상한이나 예산 Gate 두기(observability-self-improvement).
- 연속 차단·거절 횟수로 턴을 끊거나 mode 를 바꾸기. Claude Code Stop hook 8번, auto mode 연속 3번·모두 20번, Codex 연속 3번·50번 중 10번이 그 예다(system12-hooks-proactive).
- 질문·알림 횟수 예산(Ask Less, Ask Better 의 1~3개). 누적 Gate 이고 결정 1 의 강제 제약이다. 근거도 가상 사용자 simulation 이다(system12-hooks-proactive).
- 선호 자료나 재생으로 학습한 router(RouteLLM, FrugalGPT). Jev floor 를 재생 결과로 다시 맞추기(system12-hooks-proactive).
- 숫자 priority(DBOS 정수 priority, Akka priority mailbox). Erlang EEP 76 은 두 class 로 충분하다고 봤다(system12-hooks-proactive).
- 중단 비용을 숫자 효용으로 계산해 알림을 거르기. Horvitz 의 문턱 확률이 그 예다. Lu 등 Table 4 에서 판정 feedback 을 proactive 쪽에 되먹이자 recall 이 98.11% 에서 56.76% 로 떨어졌다. 같은 행에서 헛경보는 51.85% 에서 44.74% 로 줄었다(system12-hooks-proactive).
- JS 타이머 lookahead(25 ms/100 ms)로 재생 예약하기. 브라우저 타이머가 부정확해서 쓰는 방식이다(tui-music).
- which-key 식으로 일정 시간 뒤에 뜨는 키 안내. 지연 값이 상수다. TUI 화면 문법 RFC 의 동작 창은 `Space` 로 바로 연다(tui-music).
- 횟수·시간 상한으로 흐름 끊기. Claude Code agent 1,000개·재시작 5번, Cursor `loop_limit` 5, Hermes `max_verify_nudges` 3, Codex 연속 거절 3번, OpenClaw 5분 고정 SIGKILL 이 그 예다(product-prior-art).
- 위험 점수 문턱값으로 PR 을 자동 승인하고, PR push 마다 승인 에이전트 돌리기(Cursor PR Routing & Approval). 결정 6 과도 부딪힌다(product-prior-art).
- 실패하면 통과시키는 hook 기본값(Hermes·Cursor fail-open)과 hook `if` 패턴 매칭. silent failure 이고 헌법 `string_matching` 에 걸린다(product-prior-art).
- 비용 상한으로 실행 멈추기. Letta Code `maxCostUsd` 와 Devin Budgets 를 Gate 로 쓰는 것이 그 예다. 표시와 되먹임은 요구 12 로 한다(product-prior-art).
- 잠금·쓰기 대기에 횟수 상한, cooldown, 시간 상수 넣기. 대기의 원인인 잠금 방식과 writer 수를 고친다. RFC-0348 이 대기 문제를 이미 다룬다(storage-sync).
- lorebook 식 keyword·regex 활성화(Character Card `keys`, `use_regex`, decorator)로 조건부 맥락 넣기. 조건에 따라 맥락을 넣어야 하면 Lane 판정을 쓴다(portability-text-multimodal).
- OpenClaw 의 숫자 기본값(maxChars 500, 첨부 1개, 건너뜀 표지 5개) 복사하기. 숫자는 payload 크기와 deadline 같은 자원 경계에만 둔다(portability-text-multimodal).
- 가져온 지시문을 prompt injection 패턴 문자열 검사로 막기(Hermes SOUL.md 방식). import 전 차이 보여 주기와 사람의 확인으로 한다(portability-text-multimodal).
- 활동량에 비례하는 보상(Sarafu 의 주간 보상). 지표를 부풀리게 된다. 헌법 446~454행(magic_number)에도 걸린다(agent-economy).

**결정 5. 크기 검사 (1건)**

- 검토하기 쉽게 코드 줄 수 상한을 CI·lint 에 넣기. 비밀값·권한 모듈의 크기는 한 번 재서 지도로 남기는 데까지만 한다(karpathy).

**결정 6. PR 수에 비례하는 CI (4건)**

- PR 마다 에이전트 여럿이 깨 보는 검사를 CI 에 넣기. Sequoia 글의 채용 시험에서 따온 생각이다(karpathy).
- PR 마다 eval 묶음을 CI 에서 돌리기(observability-self-improvement).
- 글자 중복을 세는 CI·lint 검사. 키에서 동작으로 가는 전체 함수 타입으로 막는다(tui-music).
- PR 마다 프롬프트 eval 을 CI 로 돌려 외부화 회귀 잡기. 렌더 결과 SHA 비교 한 번으로 대신한다(portability-text-multimodal).

**결정 7. TUI 화면 시험 (2건)**

- Bonsai_term screenshot expect test 로 TUI 검사하기. OxCaml 전용 기능에도 기댄다(ocaml-oxcaml).
- 에뮬레이터 화면 글을 읽는 TUI 시험(snapshot, golden, Mosaic matrix.test). 시험은 키에서 동작으로 가는 대응 같은 결정만 본다(tui-music).

**결정 8. hard cut (3건)**

- OTel GenAI 규약 저장소 main 가지의 rename 을 지금 따르거나, 옛 이름과 새 이름을 같이 내기. 새 저장소에 release 가 없고 Schema URL 이 TODO 다(observability-self-improvement).
- 버전 선언 파일을 호환 reader·migration 과 묶기. 버전 선언은 다른 버전의 디렉터리를 읽지 않고 거절하는 데 쓴다(storage-sync).
- version 필드가 없으면 최신으로 읽기, 1년 deprecation cycle 과 schema migration(Agent Spec, Letta roadmap). 헌법 `legacy_residue` 와도 부딪힌다(portability-text-multimodal).

**결정 9. 품질 증거 없는 정리 (3건)**

- ppx_tla 를 metaquot·Ast_pattern 으로 다시 쓰기. ppxlib 가 1.0.0 까지 내부 AST 를 5.2 로 고정한다. 지금 깨진 근거가 없다(ocaml-oxcaml).
- `Atomic.make` 953곳을 `[@atomic]` 필드로 일괄 전환하기. 이득은 필드당 간접 참조 하나이고 MASC 측정 근거가 없다(ocaml-oxcaml).
- Mosaic·Minttea·Notty 로 TUI 옮기기. 품질 증거 없이 TUI 코드를 통째로 옮기게 된다(tui-music).

**결정 10. Candle (5건)**

- 같은 초기 화폐로 여는 연산·도구·Task 자리 경매(Virtual Agent Economies 의 Dworkin 식). 헌법 201행이 Candle 로 도구·스킬·모델·예산을 사는 것을 막는다(agent-economy).
- karma 입찰로 희소 자원 나누기, Karma 를 Candle 과 잇기. Karma 는 upvote 로 생긴다(헌법 154~163행). 화폐가 되면 upvote 를 사고팔 이유가 생긴다(agent-economy).
- 실제 돈·토큰·비용과 Candle 잇기. 결정 3 과도 부딪힌다(agent-economy).
- 겉모습·화폐를 도구·모델·예산 구매와 묶기, Candle 확장을 바깥 제품 사례로 정당화하기. 조사한 제품은 꾸미기를 화폐와 묶지 않는다(product-prior-art).
- PNG tEXt chunk(초상화 그림)에 세계를 실어 주 운반 형식으로 쓰기. 초상화 장신구 codec(`lib/keeper_portrait/keeper_portrait_equipment.mli`)은 그림 설명이고 소유 권한이 아니다(portability-text-multimodal).

**결정 11. 다계정 posture (4건)**

- Claude Code 내장 Bash sandbox 를 켜는 것으로 다계정 `read`·`full` posture 열기. Read 도구, hook, MCP 서버가 sandbox 밖에서 돈다(sandbox-microvm-ssh).
- 한 trust domain 안의 계정 고르기를 다계정으로 삼기(OpenClaw). sandbox 없는 in-process hook·plugin(Hermes gateway hook)도 같다. OpenClaw 문서 스스로 격리가 아니라고 적는다(product-prior-art).
- 같은 provider 키를 pool 로 돌려 쓰기(Hermes credential pools)를 사람 사이에 적용하기. 문서는 회전마다 prompt cache 가 초기화된다고 적는다(product-prior-art).
- 한 사람의 에이전트 전부가 computer 하나를 나눠 쓰기(Cursor Grok Bot). 결정 13 과도 맞지 않는다(product-prior-art).

**결정 13. Docker 는 맨 뒤 (1건)**

- Antithesis 같은 외부 결정론적 시뮬레이션 서비스. Docker compose 로 넘기는 방식이다. 출처는 Jane Street 가 투자 라운드를 이끈다고 밝힌 글이라 효과 근거로도 못 쓴다(ocaml-oxcaml).

**헌법 불변식: 시계로 지우지 않고, 실패해도 근거를 남기고, 모르면 거절한다 (7건)**

- TigerBeetle pending 이체의 timeout 만료. 시간이 지나면 저절로 무효가 되는 상태라 헌법 207행 `no_wall_clock_death` 에 걸린다. 원장에 있는 상태 전이가 이미 그 자리를 맡는다(agent-economy).
- TTL·decay 로 기억 지우기. 2026-06-23 forgetting policy 문서가 이미 기각했다. `no_wall_clock_death` 에 걸린다(memory-graph).
- 시간이 지나면 버리기. Claude Code 는 보류 메시지를 5분 뒤 지우고, Devin 은 session 재개를 14일로 묶는다. `no_wall_clock_death`·`failure_keeps_evidence` 에 걸린다(product-prior-art).
- 큐가 차면 버리기. bounded mailbox 의 dead letters, CoDel drop, load shedding, livelock 논문의 조기 폐기가 그 예다. 버리면 근거가 사라져 `failure_keeps_evidence` 에 걸린다. 같은 key 를 한 번으로 묶는 쪽만 쓸 수 있다(system12-hooks-proactive).
- 거절한 요청을 기록에 남기지 않기(Temporal Update validator), 기록 크기 한도를 턴 상한으로 쓰기(Event History 한도). 뒤쪽은 결정 3 에도 걸린다(system12-hooks-proactive).
- 목록·설정을 못 읽으면 조용히 옛 값 쓰기(Hermes catalog 2 MiB 사건). Hermes 도 v0.23.1 에서 고쳤다. `strict_parse_no_default`·`authoritative_read_only` 에 걸린다(product-prior-art).
- 느슨한 로더: 모르는 필드 무시, 다른 버전도 수용, 깨진 YAML 고쳐 읽기(Agent Skills client guide, Character Card V3). `Prompt_preset`(`lib/prompt_preset.ml`)은 `schema_version` 이 다르면 거절한다(portability-text-multimodal).

**작업 지침의 워크어라운드 거부 기준 (2건)**

운영자의 저장소 밖 작업 지침에 있는 기준이다. 대체 RFC 없이 cap·cooldown·dedup·repair 로 증상만 누르는 변경을 받지 않는다.

- 봇 사이 루프를 횟수 창·cooldown·중복 버리기로 누르기(OpenClaw 60초 20건, Claude Code 보낸 쪽별 rate limit). 반복의 원인을 고친다(product-prior-art).
- Jinja 기본 `Undefined`(빈 문자열)나 BAML 의 JSON 자동 교정 같은 조용한 치환·repair. 저장소가 이미 겪은 실패다(`test/test_prompt_templates_render.ml`). 쓸 때 검증하고 읽을 때 거부한다(portability-text-multimodal).

**사용자 결정 2026-09-23: 스스로 쓴 Skill 은 발행 뒤 운영자가 지워 조정한다 (1건)**

- 스스로 발행한 Skill 에 사전 검증 Gate 나 발행 상한 두기. SkillsBench 의 음수 결과는 과제를 풀기 전에 쓴 Skill 조건이라 MASC 와 다르다. 관측 projection 이 먼저다(observability-self-improvement).

### 15.2 「MASC 에서 쓰는 곳」 이 결정과 부딪힌 26건

발견 자체는 맞지만, 조사 보고서가 적은 「MASC 에서 쓰는 곳」 이 결정과 부딪히는 것이다. 괄호 안 라벨은 셋이다. 「조건부」 는 구현 방식에 따라 부딪히는 것이다. 「약함」 은 결정을 바로 어기지는 않지만, 결정이 요구하는 근거가 모자란 것이다. 「형식」 은 내용은 부딪히지 않고 결정을 올리는 형식(결정 4)이 어긋난 것이다. 라벨이 없으면 그대로 부딪힌다. 각 항목 끝에 부딪히지 않게 좁히는 조건을 적었다.

- `karpathy-14` (조건부 · 결정 2·3, 헌법 magic_number·budget_gate·gates order): 「확인이 생산보다 훨씬 쌀 때만 받는다」 를 런타임 수락 규칙으로 만들면 비용 비교 Gate 가 된다. Keeper 사이 재실행 의무도 생긴다. 운영자의 판단 기준으로만 쓰면 부딪히지 않는다.
- `karpathy-09` (조건부 · 결정 2·3, 헌법 budget_gate): 요청 단위 깊이를 선언값으로 받는 것은 결정 3 과 맞는다. turn·time·token 상한으로 내리면 위반이다. Ledger 필드로 두면 결정 2 의 검토 대상이다. provider effort 로만 내리면 부딪히지 않는다.
- `karpathy-06` (조건부 · 결정 2, 헌법 gates default·order): 밖에서 오는 Skill·MCP 서버의 출처 고정을 「고정 안 된 것은 로드 거절」 로 만들면 새 하드 Gate 다. digest 를 기록하고 보여 주는 데까지면 부딪히지 않는다.
- `multi-agent-orchestration-08` (결정 4·9): 조사 보고서는 A2A 사용자 결정을 선택지 둘로만 올리고 정석·근거·대가를 적지 않았다. multi-agent-orchestration 보고서 4.8절의 내용을 옮긴다.
  - 사실: agent card 경로가 돌려주는 문서는 MASC 자체 형식이고, A2A 필수 필드 넷이 없다. A2A 1.0 은 그 경로가 AgentCard 를 돌려줘야 한다고 적는다(MUST).
  - 정석 (가): A2A 를 지금 쓰지 않는다. agent card 경로에서 MASC 고유 문서를 더는 내지 않는다. 같은 내용은 `masc_agent_card` 도구에 남는다. 주석과 문서의 A2A 잔재를 같이 지운다. 대가는 그 경로를 읽는 바깥 소비자가 있으면 깨진다는 것이다. `lib`, `bin`, `dashboard/src` 에는 그 경로를 읽는 코드가 없다.
  - 품질 근거(결정 9): 등록된 경로에서 규격과 다른 문서를 준다. 근거는 이것 하나다. 충분한지는 사용자가 정한다.
  - (나): A2A 를 바깥 경계로 받는다. 대가는 새 표면, 인증, 바깥용 Task 상태 대응이다.
  - 같은 보고서 4.8절의 MCP Tasks 결정도 정석은 지금 받지 않는 쪽이다. 대가는 그때까지 오래 걸리는 바깥 도구가 동기 호출로 남는 것이다. 요구 13(MCP 확장 Fully Support)과 맞서는 선택이다(§2 의 `09`).
- `memory-graph-04` (헌법 string_matching·closed_sum_over_string): `entity_ref.kind`·`event.kind` 가 string 이다(`lib/activity_graph/activity_graph_types.mli`). registry 도 문자열로 비교한다(`lib/activity_graph/activity_graph_registry.ml`). projection 이 이 값으로 edge 종류를 가르면 위반이다. 닫힌 variant 로 올린 뒤 읽으면 부딪히지 않는다.
- `memory-graph-01` (결정 2·7·8, 헌법 legacy_residue): 「원래 기록으로 가는 길을 연다」 는 Observed Transcript(`lib/keeper/keeper_memory_os_types.mli`)에 turn 참조 필드를 더한다는 뜻일 수 있다. 그렇다면 깨지는 durable truth 를 먼저 대야 한다. 옛 fact 용 기본값·호환 reader 도 둘 수 없다. 저장된 값만 읽는 projection 이면 부딪히지 않는다. 읽는 쪽이 정해지지 않은 projection 은 결정 7(부르는 곳 없는 층에 시험을 쌓지 않는다)과도 어긋난다.
- `observability-self-improvement-06` (조건부 · 결정 1, 헌법 gates default·order): 평가 묶음·채점 코드를 Keeper 쓰기 금지 경로나 권한 규칙으로 막으면 새 강제 장치다. Keeper 작업 공간 밖 운영자 자리(`artifacts/<topic>/` 등)에 두는 배치로만 하면 부딪히지 않는다.
- `observability-self-improvement-09` (조건부 · 결정 3): protocol 별로 다시 잰 비율을 코드 상수로 박으면, 지금의 3.39 같은 재생 상수가 하나 더 생긴다. 실행 중 기록에서 그때 재거나, 표본이 없으면 「모름」 으로 두면 부딪히지 않는다.
- `observability-self-improvement-14` (조건부 · 결정 1): 고칠 대상이 Keeper 지시문이고 Verification 점수로 자동 채택하면, 최적화기가 Keeper 프롬프트 문장을 만드는 셈이다. 평가 파일 고정은 `observability-self-improvement-06` 과 같은 문제다. 대상을 하네스·도구 코드로 좁히고 사람이 채택하면 부딪히지 않는다.
- `sandbox-microvm-ssh-12` (형식 · 결정 4): 조사 보고서는 「`container` 하한을 올릴지 운영자가 정한다」 로 결정만 넘겼다. 권고와 대가는 적지 않았다. 내용 충돌은 아니다. 이 문서는 §5 의 `12` 에 정석(하한 올리기)과 대가(운영 기기마다 갱신)를 붙였다. 어느 권고가 MASC 사용 방식에 닿는지는 아직 보지 않았다.
- `agent-economy-07` (결정 10, 헌법 201행): 시장 조성자가 정하는 값과 Keeper 거래 사건은 경제 확장이다. 헌법 candle 절 개정이 먼저다.
- `agent-economy-07` (약함 · 결정 2): 거래 사건에 실행 식별자 필드를 더하는 근거가 모델별 분석이다. durable truth 가 깨진다는 근거는 없다. 원장 사건에 trace 를 남긴 선례는 이미 있다.
- `agent-economy-10` (결정 10, 헌법 201행): 현상금 Task 는 Candle 로 다른 Keeper 의 일을 사는 확장이다. 개정이 먼저다.
- `agent-economy-10` (결정 2, 헌법 88행): 선착순을 피해 제안을 모아 고르면 Keeper 사이에 계약과 기다림이 생긴다. Task 소유는 claim 으로 옮긴다는 규칙과도 어긋난다.
- `agent-economy-10` (약함 · 결정 3): 「고를 목록은 짧게」 는 바깥 실험 하나(3개 대 100개)에서 온 길이 상한이다. 저자도 실험 설계 탓일 수 있다고 적었다.
- `agent-economy-11` (결정 10, 헌법 201행): 현상금 Task 를 전제로 한다. 개정이 먼저다.
- `agent-economy-11` (약함 · 결정 2·3): 반감기를 Keeper 가 일하려는 정도를 맞추는 조절 값으로 쓰면, 원장이 행동 유도 장치가 된다. Candle 설계 문서도 그런 장치를 기본으로 두지 않는다.
- `agent-economy-14` (결정 10, 헌법 201행): 「교환, Stock 부터」 넓히자는 제안이다. 개정이 먼저다. 「따로 결정받는다」 는 표시는 바깥 연결(도구·예산)에만 붙어 있었다.
- `storage-sync-01` (결정 9): 「sidecar 방식 하나로 합친다」 를, MASC 경로에서 잠금이 풀리는 조합을 재현하기 전에 결정으로 적었다. storage-sync 보고서 3.1절도 재현을 먼저 둔다. 재현되면 결정 9 와 부딪히지 않는다.
- `storage-sync-13` (결정 2): boot 때 SQLite 버전을 사실로 기록해도 지켜지는 durable truth 가 없다. 가시성은 health 같은 projection 으로 준다. 수리는 원문 권고(should upgrade)대로 링크한 버전을 올린다.
- `system12-hooks-proactive-08` (조건부 · 결정 2, 헌법 no_wall_clock_death): 「판정 불가」·「미룸」 을 판정 variant 로 더하면 새 상태라, durable truth 조건을 통과해야 한다. Claude Code 에서 `defer` 로 미룬 세션은 기본 30일 뒤 지워진다. 그 의미까지 옮기면 `no_wall_clock_death` 와 어긋난다. 견주어 보는 데까지면 부딪히지 않는다.
- `tui-music-04` (결정 4): 조사 보고서가 올린 정석(Space 는 재생으로 둔다)은 FT2 의 Space 관례를 근거로 삼았다. FT2 원문에서 Space 는 Stop/Edit 이고 측정 근거도 없다. 이 문서는 §9 의 `04` 에서 정석을 다시 세웠다. 작업대를 TUI 화면 문법 RFC §3.1 의 `$EDITOR` 같은 예외로 두고 `?`·`Esc`·`:` 만 맞춘다. Space 를 재생 키로 남길지는 따로 정한다. FT2 는 Stop/Edit, Orca-c 는 Play/Pause 로 관례가 갈리고 잰 자료가 없다.
- `product-prior-art-12` (조건부 · 결정 1): MASC 에서 steer 는 provider 가 알려 주는 값뿐이다(`lib/runtime/runtime_muse_msp.mli`, `lib/runtime/runtime_codex_app_server.mli`). 새 입력 때문에 도구 호출을 건너뛰는 장치는 없다. 「건너뛴 호출마다 결과를 남기는 규칙」 이 MASC 쪽 건너뛰기를 새로 만든다는 뜻이면 강제 yield 장치다. provider 가 건너뛴 것을 기록하는 범위면 부딪히지 않는다.
- `product-prior-art-13` (결정 12): product-prior-art 보고서 M13 절은 Cursor 의 디렉터리별 `APPROVAL_POLICY.md` 가 결정 12 와 「같은 모양」 이라고 적는다. 그 파일은 저장소 디렉터리에 두고 자동 승인 에이전트가 읽는다. 리뷰 판정 기준은 서버마다 운영자가 정하는 정책이다. 그래서 그 문장은 맞지 않는다. 저장소 파일을 기준의 권위로 삼지 않으면 부딪히지 않는다.
- `product-prior-art-09` (조건부 · 결정 2): `masc_keeper_msg` 는 이미 수락(`state`, `queued_count`)과 거절을 돌려준다(`lib/keeper/keeper_tool_surface_ops.ml`). `Keeper_chat_operation.state` 에는 보류가 없다(`lib/keeper_chat_operations/keeper_chat_operation.mli`). Delivered·Held·Refused 를 그대로 옮기면, 받는 쪽 보류라는 새 상태·Gate 가 생긴다. 있는 두 결과를 보여 주는 데까지면 부딪히지 않는다.
- `product-prior-art-03` (조건부 · 결정 11): 「프로세스·sandbox 로 격리」 가운데 프로세스 분리만으로는, 다른 사람의 home 을 안 읽는다는 증명이 되지 않는다. Hermes 문서도 host 모드가 막는 것은 메모리 읽기라고 적는다(plugins.md 928~930행). sandbox posture 로 한정하면 맞다.

## 출처

- 발견마다 출처 링크와 원문 위치는 각 절 표의 「출처」 칸에 있다. 읽은 깊이도 그 칸 끝에 적었다.
- 발견마다 출처 주소(`src`), 읽은 깊이(`depth`), 근거 종류(`kind`), 재확인 판정(`check`)은 근거 묶음의 주제별 digest 에 있다. 칸의 뜻과 판정 수를 다시 세는 명령은 [근거 묶음 README](../evidence/research/2026-11-12-agent-farm-prior-art/README.md) 에 있다.
- 출처별 읽은 깊이와 신뢰도는 조사 보고서마다 있는 출처 표에 있다. 그 가운데 아홉 보고서의 표는 확인 시각도 적는다. 보고서 원본은 이 저장소에 없다.
