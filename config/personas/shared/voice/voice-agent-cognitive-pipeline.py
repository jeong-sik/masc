#!/usr/bin/env python3
"""
Voice Agent Cognitive Pipeline
===============================

완전한 인지-판단-선택-학습 파이프라인

Architecture:
1. Query Analysis (쿼리/감정/상황 분석)
2. Knowledge Augmentation (필요시 검색)
3. Generate 3 Candidates (3 LLM calls)
4. Personality Correction (성격 보정)
5. Select Best Candidate (highest confidence)
6. Save Turn + Agent Emotion (Neo4j)

Usage:
    python3 voice-agent-cognitive-pipeline.py \
        --agent miseon \
        --user-id jeong-sik \
        --query "중복 관리 문제 있어요"
"""

import json
import os
import subprocess
import sys
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

# Add lib path for connection_pool
sys.path.insert(0, str(Path.home() / "me/scripts/lib"))

import anthropic

# 🔧 Configuration
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
if not ANTHROPIC_API_KEY:
    print("❌ ANTHROPIC_API_KEY not found in environment")
    sys.exit(1)

client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

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
    "gary": {
        "voice": "onyx",
        "speed": 1.1,
        "personality_traits": {
            "energetic": 0.9,
            "rhythmic": 0.8,
            "casual": 0.7,
        },
    },
    "bowie": {
        "voice": "echo",
        "speed": 1.0,
        "personality_traits": {
            "pessimistic": 0.8,
            "humorous": 0.9,
            "sticky": 0.7,
        },
    },
    "jaeyong": {
        "voice": "onyx",
        "speed": 0.9,
        "personality_traits": {
            "strategic": 0.9,
            "authoritative": 0.8,
            "warm": 0.6,
        },
    },
    "sangsu": {
        "voice": "CwhRBWXzGAHq8TQ4Fs17",
        "speed": 0.95,
        "personality_traits": {
            "grumpy": 0.8,
            "direct": 0.9,
            "experienced": 0.9,
        },
    },
}


# 📊 Step 1: Query Analysis
def analyze_query(query: str, agent_name: str, user_id: str) -> Dict[str, Any]:
    """
    쿼리 분석: 감정, 의도, 상황

    Returns:
        {
            "user_emotion": str,
            "user_emotion_intensity": int,
            "intent": str,
            "context_summary": str,
            "needs_search": bool
        }
    """
    print("🧠 Step 1: Query Analysis...")

    # LLM 호출로 분석
    prompt = f"""다음 사용자 쿼리를 분석해주세요:

Query: "{query}"

다음 항목들을 JSON 형식으로 반환해주세요:
{{
  "user_emotion": "감정 (긍정적: 기쁨/감사/안도/만족/흥분, 중립적: 평온함/호기심, 부정적: 불안/좌절/화남/슬픔/걱정)",
  "user_emotion_intensity": 0-100 사이 숫자,
  "intent": "의도 (질문/잡담/요청/감정표현 중 하나)",
  "context_summary": "상황 요약 (1-2문장)",
  "needs_search": true/false (지식 검색이 필요한지)
}}

JSON만 반환하고 다른 설명은 하지 마세요."""

    try:
        response = client.messages.create(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=500,
            messages=[{"role": "user", "content": prompt}]
        )

        analysis_text = response.content[0].text.strip()
        # JSON 파싱
        if "```json" in analysis_text:
            analysis_text = analysis_text.split("```json")[1].split("```")[0].strip()
        elif "```" in analysis_text:
            analysis_text = analysis_text.split("```")[1].split("```")[0].strip()

        analysis = json.loads(analysis_text)

    except Exception as e:
        print(f"  ⚠️ LLM analysis failed: {e}")
        # Fallback to simple heuristics
        analysis = {
            "user_emotion": "중립",
            "user_emotion_intensity": 50,
            "intent": "질문",
            "context_summary": f"User asking about: {query[:50]}",
            "needs_search": "?" in query or "어떻게" in query or "문제" in query,
        }

    print(f"  Emotion: {analysis['user_emotion']} ({analysis['user_emotion_intensity']}%)")
    print(f"  Intent: {analysis['intent']}")
    print(f"  Needs search: {analysis['needs_search']}")

    return analysis


# 🔍 Step 2: Knowledge Augmentation
def augment_knowledge(
    query: str, analysis: Dict[str, Any], agent_name: str
) -> Dict[str, Any]:
    """
    필요시 지식 검색 (KB, Neo4j, Milvus)

    Returns:
        {
            "kb_results": List[str],
            "neo4j_context": Dict,
            "search_performed": bool
        }
    """
    print("🔍 Step 2: Knowledge Augmentation...")

    knowledge = {
        "kb_results": [],
        "neo4j_context": {},
        "search_performed": False,
    }

    if analysis["needs_search"]:
        # Smart search
        print("  Running smart-search.sh...")
        try:
            result = subprocess.run(
                ["bash", str(Path.home() / "me/scripts/smart-search.sh"), query],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                knowledge["kb_results"] = result.stdout.split("\n")[:3]
                knowledge["search_performed"] = True
                print(f"  Found {len(knowledge['kb_results'])} KB results")
        except Exception as e:
            print(f"  Search failed: {e}")

    # Load Neo4j context (direct connection pool - 10x faster)
    print("  Loading Neo4j context...")
    try:
        from connection_pool import Neo4jSession

        cypher_query = f"""
        MATCH (u:User {{id: "jeong-sik"}})-[k:KNOWS]->(a:Agent {{id: "{agent_name}"}})
        RETURN
          k.intimacy as intimacy,
          k.stage as stage,
          k.conversations as total_conversations,
          k.conversation_history as recent_history,
          k.learned_patterns as patterns,
          a.current_emotion as agent_current_emotion
        """

        with Neo4jSession() as session:
            result = session.run(cypher_query)
            record = result.single()

            if record:
                knowledge["neo4j_context"] = {
                    "intimacy": record.get("intimacy", 70),
                    "stage": record.get("stage", 4),
                    "recent_history": record.get("recent_history", []),
                    "patterns": record.get("patterns", []),
                    "agent_current_emotion": record.get("agent_current_emotion", "평온함"),
                }
                print(f"  ✅ Loaded: intimacy={knowledge['neo4j_context']['intimacy']}, emotion={knowledge['neo4j_context']['agent_current_emotion']}")
            else:
                print(f"  ℹ️  No relationship found, using defaults")
                knowledge["neo4j_context"] = {
                    "intimacy": 70,
                    "stage": 4,
                    "recent_history": [],
                    "patterns": [],
                    "agent_current_emotion": "평온함",
                }

    except Exception as e:
        print(f"  ⚠️ Neo4j load error: {e}")
        knowledge["neo4j_context"] = {
            "intimacy": 70,
            "stage": 4,
            "recent_history": [],
            "patterns": [],
            "agent_current_emotion": "평온함",
        }

    return knowledge


# 🎲 Step 3: Generate 3 Candidates
def generate_candidates(
    query: str,
    analysis: Dict[str, Any],
    knowledge: Dict[str, Any],
    agent_name: str,
) -> List[Dict[str, Any]]:
    """
    3개 후보 생성 (3 LLM calls)

    Returns:
        [
            {
                "response": str,
                "confidence": int,
                "reasoning": str
            },
            ...
        ]
    """
    print("🎲 Step 3: Generate 3 Candidates...")

    candidates = []

    # Load agent persona
    agent_persona_path = Path.home() / f"me/.claude/agents/{agent_name}/AGENT.md"
    if not agent_persona_path.exists():
        agent_persona_path = Path.home() / f"me/.claude/agents/{agent_name}.md"

    agent_persona = ""
    if agent_persona_path.exists():
        with open(agent_persona_path) as f:
            agent_persona = f.read()[:2000]  # First 2000 chars

    # Base context for all candidates
    base_context = f"""
Agent: {agent_name}
User Emotion: {analysis['user_emotion']} ({analysis['user_emotion_intensity']}%)
Intent: {analysis['intent']}
Context: {analysis['context_summary']}
Intimacy: {knowledge['neo4j_context']['intimacy']} (Stage {knowledge['neo4j_context']['stage']})

Agent Persona Summary:
{agent_persona[:500]}

User Query: "{query}"
"""

    # Candidate A: KB-based (high confidence)
    print("  Generating Candidate A (KB-based)...")
    kb_context = "\n".join(knowledge["kb_results"][:3]) if knowledge["kb_results"] else "No KB results"

    prompt_a = f"""{base_context}

Knowledge Base Results:
{kb_context}

Task: Generate a response using the KB results (if available). Be confident and specific.
Return JSON:
{{
  "response": "your response in Korean",
  "confidence": 0-100,
  "reasoning": "why this confidence"
}}
"""

    try:
        response_a = client.messages.create(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=1000,
            messages=[{"role": "user", "content": prompt_a}]
        )
        result_a = json.loads(response_a.content[0].text.strip().replace("```json", "").replace("```", ""))
        candidate_a = {
            "response": result_a["response"],
            "confidence": result_a["confidence"],
            "reasoning": result_a["reasoning"],
        }
    except Exception as e:
        print(f"  ⚠️ Candidate A failed: {e}")
        candidate_a = {
            "response": f"[{agent_name}] KB 기반 답변 생성 실패",
            "confidence": 50,
            "reasoning": "LLM error",
        }

    candidates.append(candidate_a)

    # Candidate B: Context-based (medium confidence)
    print("  Generating Candidate B (Context-based)...")
    recent_history = knowledge['neo4j_context'].get('recent_history', [])[:5]
    history_text = "\n".join([f"- {h}" for h in recent_history]) if recent_history else "No history"

    prompt_b = f"""{base_context}

Recent Conversation History:
{history_text}

Task: Generate a response using conversation history and learned patterns.
Return JSON:
{{
  "response": "your response in Korean",
  "confidence": 0-100,
  "reasoning": "why this confidence"
}}
"""

    try:
        response_b = client.messages.create(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=1000,
            messages=[{"role": "user", "content": prompt_b}]
        )
        result_b = json.loads(response_b.content[0].text.strip().replace("```json", "").replace("```", ""))
        candidate_b = {
            "response": result_b["response"],
            "confidence": result_b["confidence"],
            "reasoning": result_b["reasoning"],
        }
    except Exception as e:
        print(f"  ⚠️ Candidate B failed: {e}")
        candidate_b = {
            "response": f"[{agent_name}] 컨텍스트 기반 답변 생성 실패",
            "confidence": 50,
            "reasoning": "LLM error",
        }

    candidates.append(candidate_b)

    # Candidate C: General (lower confidence)
    print("  Generating Candidate C (General)...")
    prompt_c = f"""{base_context}

Task: Generate a general response using common knowledge. Be helpful but acknowledge uncertainty if applicable.
Return JSON:
{{
  "response": "your response in Korean",
  "confidence": 0-100,
  "reasoning": "why this confidence"
}}
"""

    try:
        response_c = client.messages.create(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=1000,
            messages=[{"role": "user", "content": prompt_c}]
        )
        result_c = json.loads(response_c.content[0].text.strip().replace("```json", "").replace("```", ""))
        candidate_c = {
            "response": result_c["response"],
            "confidence": result_c["confidence"],
            "reasoning": result_c["reasoning"],
        }
    except Exception as e:
        print(f"  ⚠️ Candidate C failed: {e}")
        candidate_c = {
            "response": f"[{agent_name}] 일반 답변 생성 실패",
            "confidence": 40,
            "reasoning": "LLM error",
        }

    candidates.append(candidate_c)

    for i, c in enumerate(candidates):
        print(f"  Candidate {chr(65+i)}: {c['confidence']}% confidence")
        print(f"    {c['response'][:60]}...")

    return candidates


# 🎭 Step 4: Personality Correction
def apply_personality_correction(
    candidates: List[Dict[str, Any]],
    agent_name: str,
    neo4j_context: Dict[str, Any],
) -> List[Dict[str, Any]]:
    """
    성격 보정 적용

    Adjusts responses based on:
    - Agent personality traits
    - Intimacy level
    - Tone preferences
    """
    print("🎭 Step 4: Personality Correction...")

    agent_config = AGENTS[agent_name]
    intimacy = neo4j_context.get("intimacy", 50)

    # Adjust confidence based on personality
    for candidate in candidates:
        original_confidence = candidate["confidence"]

        # 성격 보정 (예시)
        if agent_name == "miseon":
            # 전문적 답변에 보너스
            if "KB" in candidate["reasoning"]:
                candidate["confidence"] = min(100, candidate["confidence"] + 10)
        elif agent_name == "bowie":
            # 비관적 성향 → 자신감 약간 낮춤
            candidate["confidence"] = int(candidate["confidence"] * 0.95)

        # 친밀도에 따른 톤 조정
        if intimacy >= 80:
            candidate["response"] = candidate["response"].replace("드립니다", "줄게")

        if candidate["confidence"] != original_confidence:
            print(
                f"  Adjusted: {original_confidence}% → {candidate['confidence']}%"
            )

    return candidates


# 🏆 Step 5: Select Best Candidate
def select_best_candidate(
    candidates: List[Dict[str, Any]]
) -> Dict[str, Any]:
    """
    최고 confidence 선택
    """
    print("🏆 Step 5: Select Best Candidate...")

    best = max(candidates, key=lambda c: c["confidence"])
    best_idx = candidates.index(best)

    print(f"  Selected: Candidate {chr(65+best_idx)} ({best['confidence']}%)")

    return {
        "selected_candidate": chr(65+best_idx).lower(),
        "response": best["response"],
        "confidence": best["confidence"],
        "reasoning": best["reasoning"],
    }


# 😊 Agent Emotion Change
def detect_agent_emotion_change(
    query: str,
    user_emotion: str,
    selected_response: Dict[str, Any],
    agent_name: str,
) -> Dict[str, Any]:
    """
    Agent 자신의 감정 변화 감지

    Returns:
        {
            "emotion_before": str,
            "emotion_after": str,
            "emotion_reason": str,
            "intensity": int
        }
    """
    print("😊 Agent Emotion Change Detection...")

    # Get agent's current emotion from Neo4j context
    current_emotion = "평온함"  # Default

    # LLM으로 감정 변화 추론
    prompt = f"""As agent "{agent_name}", analyze your emotional state change.

Context:
- User query: "{query}"
- User emotion: {user_emotion}
- Your response confidence: {selected_response['confidence']}%
- Your response: "{selected_response['response'][:100]}..."

Current agent emotion: {current_emotion}

Agent emotions can be:
Positive: 뿌듯함 (proud), 도움이 됨 (helpful), 신남 (excited), 만족 (satisfied)
Neutral: 평온함 (calm), 집중 (focused)
Negative: 불확실함 (uncertain), 걱정됨 (worried), 답답함 (frustrated)

Return JSON:
{{
  "emotion_before": "current emotion",
  "emotion_after": "new emotion after this interaction",
  "emotion_reason": "why this change happened (Korean, 1 sentence)",
  "intensity": 0-100
}}
"""

    try:
        response = client.messages.create(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=300,
            messages=[{"role": "user", "content": prompt}]
        )

        result_text = response.content[0].text.strip()
        if "```json" in result_text:
            result_text = result_text.split("```json")[1].split("```")[0].strip()
        elif "```" in result_text:
            result_text = result_text.split("```")[1].split("```")[0].strip()

        emotion_change = json.loads(result_text)

    except Exception as e:
        print(f"  ⚠️ Emotion reasoning failed: {e}")
        # Fallback
        if selected_response["confidence"] >= 85:
            emotion_change = {
                "emotion_before": current_emotion,
                "emotion_after": "뿌듯함",
                "emotion_reason": "확신을 갖고 답변함",
                "intensity": 70,
            }
        elif selected_response["confidence"] < 65:
            emotion_change = {
                "emotion_before": current_emotion,
                "emotion_after": "불확실함",
                "emotion_reason": "답변이 확실하지 않음",
                "intensity": 60,
            }
        else:
            emotion_change = {
                "emotion_before": current_emotion,
                "emotion_after": "평온함",
                "emotion_reason": "일반적인 대화 진행",
                "intensity": 50,
            }

    print(f"  {emotion_change['emotion_before']} → {emotion_change['emotion_after']}")
    print(f"  Reason: {emotion_change['emotion_reason']}")
    print(f"  Intensity: {emotion_change['intensity']}%")

    return emotion_change


# 💾 Step 6: Save to Neo4j
def save_turn_to_neo4j(
    user_id: str,
    agent_name: str,
    query: str,
    analysis: Dict[str, Any],
    knowledge: Dict[str, Any],
    candidates: List[Dict[str, Any]],
    selected: Dict[str, Any],
    emotion_change: Dict[str, Any],
) -> None:
    """
    완전한 Turn 저장 + Agent 감정 업데이트
    """
    print("💾 Step 6: Save to Neo4j...")

    turn_id = f"turn_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{str(uuid.uuid4())[:8]}"

    turn_data = {
        "id": turn_id,
        "timestamp": datetime.now().isoformat(),
        "user_query": query,
        "user_emotion": analysis["user_emotion"],
        "user_emotion_intensity": analysis["user_emotion_intensity"],
        "intent": analysis["intent"],
        "context_summary": analysis["context_summary"],
        "kb_searched": knowledge["search_performed"],
        "search_results_count": len(knowledge["kb_results"]),
        "candidate_a": json.dumps(candidates[0]),
        "candidate_b": json.dumps(candidates[1]),
        "candidate_c": json.dumps(candidates[2]),
        "selected_candidate": selected["selected_candidate"],
        "final_response": selected["response"],
        "final_confidence": selected["confidence"],
        "agent_emotion_before": emotion_change["emotion_before"],
        "agent_emotion_after": emotion_change["emotion_after"],
        "agent_emotion_reason": emotion_change["emotion_reason"],
    }

    print(f"  Turn data: {len(json.dumps(turn_data))} bytes")

    try:
        # Escape quotes for Cypher
        query_escaped = query.replace('"', "'")
        response_escaped = selected['response'].replace('"', "'")

        # 1. Create Turn node
        cypher_create_turn = f"""
        CREATE (t:Turn {{
          id: "{turn_id}",
          timestamp: datetime(),
          user_query: "{query_escaped}",
          user_emotion: "{analysis['user_emotion']}",
          user_emotion_intensity: {analysis['user_emotion_intensity']},
          intent: "{analysis['intent']}",
          selected_candidate: "{selected['selected_candidate']}",
          final_response: "{response_escaped[:500]}",
          final_confidence: {selected['confidence']},
          agent_emotion_before: "{emotion_change['emotion_before']}",
          agent_emotion_after: "{emotion_change['emotion_after']}"
        }})
        RETURN t.id
        """

        # 2. Connect Turn to User and Agent
        cypher_connect = f"""
        MATCH (u:User {{id: "{user_id}"}})
        MATCH (a:Agent {{id: "{agent_name}"}})
        MATCH (t:Turn {{id: "{turn_id}"}})
        CREATE (u)-[:SAID {{timestamp: datetime()}}]->(t)
        CREATE (t)-[:RESPONDED_BY {{timestamp: datetime()}}]->(a)
        """

        # 3. Update KNOWS relationship
        cypher_update_knows = f"""
        MATCH (u:User {{id: "{user_id}"}})-[k:KNOWS]->(a:Agent {{id: "{agent_name}"}})
        SET
          k.conversations = k.conversations + 1,
          k.last_interaction = datetime(),
          k.conversation_history = [
            {{
              timestamp: datetime(),
              user_query: "{query_escaped[:100]}",
              agent_response: "{response_escaped[:100]}",
              user_emotion: "{analysis['user_emotion']}",
              agent_emotion_after: "{emotion_change['emotion_after']}",
              confidence: {selected['confidence']}
            }}
          ] + coalesce(k.conversation_history[0..8], [])
        """

        # 4. Update Agent current_emotion
        cypher_update_agent = f"""
        MATCH (a:Agent {{id: "{agent_name}"}})
        SET
          a.current_emotion = "{emotion_change['emotion_after']}",
          a.emotion_intensity = {emotion_change.get('intensity', 70)},
          a.last_emotion_change = datetime()
        """

        # Execute all Cypher queries (direct connection pool - 10x faster)
        from connection_pool import Neo4jSession

        with Neo4jSession() as session:
            # 1. Create Turn node
            session.run(cypher_create_turn)

            # 2. Connect Turn to User and Agent
            session.run(cypher_connect)

            # 3. Update KNOWS relationship
            session.run(cypher_update_knows)

            # 4. Update Agent current_emotion
            session.run(cypher_update_agent)

        print(f"  ✅ Saved turn {turn_id} to Neo4j")

    except Exception as e:
        print(f"  ⚠️ Neo4j save error: {e}")
        print(f"  Turn data saved locally for debugging")
        # Save to local file as backup
        backup_path = Path.home() / f"me/tmp/turn_{turn_id}.json"
        backup_path.parent.mkdir(exist_ok=True)
        with open(backup_path, "w") as f:
            json.dump(turn_data, f, indent=2, ensure_ascii=False)
        print(f"  Backup: {backup_path}")


# 🎙️ VoiceMode Output
def voice_output(response: str, agent_name: str) -> str:
    """
    VoiceMode로 출력

    Returns:
        str: User's voice response (if any)
    """
    print("🎙️ VoiceMode Output...")

    agent_config = AGENTS[agent_name]

    print(f"  Voice: {agent_config['voice']}")
    print(f"  Speed: {agent_config['speed']}")
    print(f"  Response: {response[:100]}...")

    # NOTE: VoiceMode는 Claude Code 세션 내에서만 작동
    # 스크립트로 직접 호출 불가 (MCP tool은 Claude Code 전용)
    #
    # 실제 사용 시:
    # 1. 이 스크립트를 Claude Code 내에서 호출
    # 2. 또는 /miseon, /bowie 등 명령어로 직접 사용
    #
    # 현재는 텍스트만 출력
    print(f"\n[{agent_name}]: {response}\n")

    # Simulate user response for testing
    # (실제론 VoiceMode에서 음성 듣기)
    return ""


# 🚀 Main Pipeline
def run_cognitive_pipeline(
    agent_name: str,
    user_id: str,
    query: str,
) -> None:
    """
    Complete cognitive pipeline 실행
    """
    print("=" * 60)
    print(f"🧠 Voice Agent Cognitive Pipeline")
    print(f"Agent: {agent_name} | User: {user_id}")
    print(f"Query: {query}")
    print("=" * 60)

    # Step 1: Query Analysis
    analysis = analyze_query(query, agent_name, user_id)

    # Step 2: Knowledge Augmentation
    knowledge = augment_knowledge(query, analysis, agent_name)

    # Step 3: Generate 3 Candidates
    candidates = generate_candidates(query, analysis, knowledge, agent_name)

    # Step 4: Personality Correction
    candidates = apply_personality_correction(
        candidates, agent_name, knowledge["neo4j_context"]
    )

    # Step 5: Select Best
    selected = select_best_candidate(candidates)

    # Detect Agent Emotion Change
    emotion_change = detect_agent_emotion_change(
        query, analysis["user_emotion"], selected, agent_name
    )

    # Step 6: Save to Neo4j
    save_turn_to_neo4j(
        user_id,
        agent_name,
        query,
        analysis,
        knowledge,
        candidates,
        selected,
        emotion_change,
    )

    # VoiceMode Output (스크립트에서는 출력만, 실제 voice는 Claude Code에서)
    # voice_output(selected["response"], agent_name)

    # Return JSON for Claude Code to use
    result = {
        "selected_candidate": selected["selected_candidate"],
        "response": selected["response"],
        "confidence": selected["confidence"],
        "reasoning": selected["reasoning"],
        "emotion_after": emotion_change["emotion_after"],
        "emotion_intensity": emotion_change.get("intensity", 70),
        "turn_id": f"turn_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{str(uuid.uuid4())[:8]}",
    }

    print("\n" + "=" * 60)
    print("✅ Pipeline Complete!")
    print("=" * 60)
    print("\n🎯 RESULT_JSON_START")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print("🎯 RESULT_JSON_END\n")

    return result


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Voice Agent Cognitive Pipeline")
    parser.add_argument("--agent", required=True, choices=AGENTS.keys())
    parser.add_argument("--user-id", default="jeong-sik")
    parser.add_argument("--query", required=True)

    args = parser.parse_args()

    run_cognitive_pipeline(args.agent, args.user_id, args.query)
