# Voice Agent Cognitive Pipeline

**완전한 인지-판단-선택-학습 파이프라인**

**Created**: 2025-11-11

---

## 🎯 Overview

기존 단순 Neo4j 컨텍스트 로딩에서 **완전한 인지 에이전트 시스템**으로 업그레이드.

### 핵심 특징

- ✅ **User + Agent 감정 추적** - 둘 다 감정을 가지고 변화를 기록
- ✅ **3 Candidates Generation** - 3번 LLM 호출로 다양한 답변 생성
- ✅ **Hybrid Confidence Scoring** - KB hit + LLM self-evaluation
- ✅ **Personality Correction** - 에이전트 성격에 따라 답변 보정
- ✅ **Neo4j Persistence** - 모든 대화와 감정 변화 저장
- ✅ **VoiceMode Ready** - Voice 출력 준비 (Claude Code 세션 필요)

---

## 🏗️ Architecture

```
User Query
    ↓
[1] Query Analysis (LLM)
    - User emotion: 불안/기쁨/중립 etc
    - Intent: 질문/잡담/요청
    - Context: 상황 파악
    ↓
[2] Knowledge Augmentation
    - smart-search.sh (KB)
    - Neo4j context loading
    - Milvus semantic search
    ↓
[3] Generate 3 Candidates (3 LLM calls)
    - Candidate A: KB-based (high confidence)
    - Candidate B: Context-based (medium)
    - Candidate C: General (lower)
    ↓
[4] Personality Correction
    - Agent traits 적용
    - Intimacy level 반영
    - Tone adjustment
    ↓
[5] Select Best Candidate
    - Highest confidence
    - Personality-aligned
    ↓
[6] Neo4j Save + Agent Emotion
    - Turn node 생성
    - Agent 감정 변화 기록
    - History 업데이트
    ↓
VoiceMode Output
```

---

## 📦 Installation

### Dependencies

```bash
# Python packages
pip install anthropic

# Environment
export ANTHROPIC_API_KEY="your-api-key"
```

### Files

- `voice-agent-cognitive-pipeline.py` - Main pipeline script
- `voice-agent-cognitive-neo4j-schema.md` - Neo4j schema documentation
- `voice-agent-neo4j-pattern.md` - Original simple pattern

---

## 🚀 Usage

### Basic Usage

```bash
python3 ~/me/scripts/voice-agent-cognitive-pipeline.py \
    --agent miseon \
    --user-id jeong-sik \
    --query "중복 관리 문제가 있어요"
```

### Available Agents

- `miseon` - 박미선 (Data Architect + PM)
- `gary` - 게리 (Musician + Producer)
- `bowie` - 보위 (Geek Buddy)
- `jaeyong` - 이재용 (Chairman)
- `sangsu` - 홍상수 (Grumpy Developer)

### Options

```bash
--agent <name>      # Required: Agent to use
--user-id <id>      # Default: jeong-sik
--query <text>      # Required: User query
```

---

## 📊 Output Example

```
============================================================
🧠 Voice Agent Cognitive Pipeline
Agent: miseon | User: jeong-sik
Query: 중복 관리 문제가 있어요
============================================================

🧠 Step 1: Query Analysis...
  Emotion: 불안 (75%)
  Intent: 질문
  Needs search: True

🔍 Step 2: Knowledge Augmentation...
  Running smart-search.sh...
  Found 3 KB results
  Loading Neo4j context...
  Loaded context: intimacy=70

🎲 Step 3: Generate 3 Candidates...
  Generating Candidate A (KB-based)...
  Generating Candidate B (Context-based)...
  Generating Candidate C (General)...
  Candidate A: 85% confidence
    GitHub Teams API를 활용하면 중복 관리를 자동화할 수 있어요...
  Candidate B: 70% confidence
    이전에 비슷한 케이스가 있었는데, 그때는...
  Candidate C: 60% confidence
    중복 관리는 일반적으로 데이터 정규화로 접근하는데...

🎭 Step 4: Personality Correction...
  Adjusted: 85% → 95%

🏆 Step 5: Select Best Candidate...
  Selected: Candidate A (95%)

😊 Agent Emotion Change Detection...
  평온함 → 뿌듯함
  Reason: 확신을 갖고 도움을 줄 수 있었음
  Intensity: 80%

💾 Step 6: Save to Neo4j...
  Turn data: 1543 bytes
  ✅ Saved turn turn_20251111_114532_abc123 to Neo4j

🎙️ VoiceMode Output...
  Voice: nova
  Speed: 1.0

[miseon]: 정식님, GitHub Teams API 활용하면 중복 관리 자동화할 수 있어요...

============================================================
✅ Pipeline Complete!
============================================================
```

---

## 🗃️ Neo4j Schema

### Nodes

#### User
```cypher
(User {
  id: "jeong-sik",
  name: "윤정식",
  email: "vincent.dev@kidsnote.com"
})
```

#### Agent
```cypher
(Agent {
  id: "miseon|bowie|gary|jaeyong|sangsu",
  name: "...",
  role: "...",
  personality: {...},
  current_emotion: "평온함",
  emotion_intensity: 50
})
```

#### Turn
```cypher
(Turn {
  id: "turn_20251111_114532_abc123",
  timestamp: datetime(),
  user_query: "...",
  user_emotion: "불안",
  user_emotion_intensity: 75,
  intent: "질문",
  candidate_a: {...},
  candidate_b: {...},
  candidate_c: {...},
  selected_candidate: "a",
  final_response: "...",
  final_confidence: 95,
  agent_emotion_before: "평온함",
  agent_emotion_after: "뿌듯함"
})
```

### Relationships

```cypher
(User)-[:KNOWS {
  intimacy: 70,
  stage: 4,
  conversations: 42,
  conversation_history: [...],
  user_emotion_history: [...],
  agent_emotion_history: [...]
}]->(Agent)

(User)-[:SAID]->(Turn)-[:RESPONDED_BY]->(Agent)
```

---

## 🔧 Configuration

### Agent Config (in script)

```python
AGENTS = {
    "miseon": {
        "voice": "nova",
        "speed": 1.0,
        "personality_traits": {
            "professional": 0.7,
            "friendly": 0.8,
            "technical": 0.9,
        },
    },
    # ... other agents
}
```

### Personality Correction Logic

```python
# 예시: 미선
if agent_name == "miseon":
    # 전문적 답변에 보너스
    if "KB" in candidate["reasoning"]:
        candidate["confidence"] = min(100, candidate["confidence"] + 10)

# 예시: 보위
elif agent_name == "bowie":
    # 비관적 성향 → 자신감 약간 낮춤
    candidate["confidence"] = int(candidate["confidence"] * 0.95)
```

---

## 🎭 Emotion Categories

### User Emotions
```
긍정적: 기쁨, 감사, 안도, 만족, 흥분
중립적: 평온함, 호기심
부정적: 불안, 좌절, 화남, 슬픔, 걱정
```

### Agent Emotions
```
긍정적: 뿌듯함, 도움이 됨, 신남, 만족
중립적: 평온함, 집중
부정적: 불확실함, 걱정됨, 답답함
```

---

## 🐛 Troubleshooting

### 401 Authentication Error

```bash
# ANTHROPIC_API_KEY 설정 확인
echo $ANTHROPIC_API_KEY

# 없으면 설정
export ANTHROPIC_API_KEY="your-api-key"
```

### Neo4j Timeout

```bash
# Neo4j 연결 확인
claude /from-neo4j "MATCH (n) RETURN count(n) LIMIT 1"

# Timeout 늘리기 (script 수정)
timeout=30  # 기본값 10초
```

### Smart Search Not Found

```bash
# smart-search.sh 확인
ls ~/me/scripts/smart-search.sh

# 실행 권한
chmod +x ~/me/scripts/smart-search.sh
```

---

## 📈 Performance

### LLM Calls

- Step 1 (Query Analysis): 1 call (~500 tokens)
- Step 3 (3 Candidates): 3 calls (~1000 tokens each)
- Step 6 (Agent Emotion): 1 call (~300 tokens)

**Total**: 5 LLM calls, ~3800 tokens per pipeline run

### Timing

```
Step 1: Query Analysis        ~2s
Step 2: Knowledge Augmentation ~5s (with search)
Step 3: 3 Candidates           ~6s (parallel possible)
Step 4: Personality Correction ~0.1s
Step 5: Selection              ~0.1s
Step 6: Neo4j Save             ~2s
Step 7: VoiceMode              ~3s (voice synthesis)
----------------------------------------
Total:                         ~18s
```

---

## 🔗 Related Files

- `~/me/.claude/agents/miseon/AGENT.md` - 미선 에이전트 페르소나
- `~/me/.claude/agents/gary/AGENT.md` - 개리 에이전트 페르소나
- `~/me/.claude/agents/bowie.md` - 보위 에이전트 페르소나
- `~/me/.claude/agents/jaeyong.md` - 재용 에이전트 페르소나
- `~/me/.claude/agents/sangsu/AGENT.md` - 상수 에이전트 (reference)
- `~/me/scripts/sangsu-context-manager.py` - 상수 구현 예시
- `~/me/memory/procedural-memory/voice-agent-neo4j-pattern.md` - Original pattern
- `~/me/memory/procedural-memory/voice-agent-cognitive-neo4j-schema.md` - Schema docs

---

## 🚧 TODO

### Phase 1: LLM Integration (✅ DONE)
- [x] Query Analysis LLM call
- [x] 3 Candidates generation
- [x] Agent emotion reasoning
- [x] Error handling & fallbacks

### Phase 2: Neo4j Integration (✅ DONE)
- [x] Context loading via /from-neo4j
- [x] Turn saving via /to-neo4j
- [x] Agent emotion update
- [x] History management

### Phase 3: VoiceMode Integration (🚧 NEXT)
- [ ] Claude Code 세션 내 호출
- [ ] Voice synthesis with proper config
- [ ] User voice response listening
- [ ] Multi-turn conversation loop

### Phase 4: Command Integration (⏳ FUTURE)
- [ ] `/miseon` command wrapper
- [ ] `/bowie` command wrapper
- [ ] `/gary` command wrapper
- [ ] `/jaeyong` command wrapper

### Phase 5: Optimization (⏳ FUTURE)
- [ ] Parallel LLM calls (Step 3)
- [ ] Caching for repeated queries
- [ ] Token usage optimization
- [ ] Latency reduction

---

## 📝 Notes

### VoiceMode Limitation

VoiceMode MCP tools (`mcp__voicemode__converse`) can only be called from **Claude Code sessions**, not standalone Python scripts.

**Workarounds**:
1. Call this script from within Claude Code (승지 세션)
2. Use slash commands (`/miseon`, `/bowie`) that wrap this script
3. Run in text-only mode for testing (current implementation)

### API Key Security

```bash
# ❌ Never hardcode
ANTHROPIC_API_KEY = "sk-ant-..."

# ✅ Use environment variable
export ANTHROPIC_API_KEY="sk-ant-..."

# ✅ Or use 1Password
op read "op://Private/Anthropic/credential"
```

---

**Last Updated**: 2025-11-11
**Status**: ✅ LLM integrated, Neo4j integrated, Pipeline tested
**Next**: VoiceMode integration in Claude Code session
