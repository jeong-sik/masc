#!/usr/bin/env python3
"""
상수 캐릭터 프로파일링 (LLM 기반)

**Logic**:
1. 최근 N턴 대화 조회
2. LLM으로 캐릭터 분석
3. Neo4j Character 노드 업데이트

**Usage**:
  python3 sangsu-character-profiler.py --analyze
  python3 sangsu-character-profiler.py --show-profile
"""

import sys
import json
import os
import subprocess
from neo4j import GraphDatabase
from anthropic import Anthropic
from pathlib import Path

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')


def get_neo4j_creds():
    """1Password에서 Neo4j 인증 정보 가져오기"""
    result = subprocess.run(
        ['op', 'item', 'get', 'Neo4j Docker', '--format', 'json'],
        capture_output=True, text=True
    )
    item = json.loads(result.stdout)
    creds = {}
    for field in item['fields']:
        if field['id'] == 'username':
            creds['username'] = field['value']
        elif field['id'] == 'password':
            creds['password'] = field['value']
    return creds


def get_conversation_sample(n_turns: int = 20) -> list:
    """
    최근 N턴 대화 조회
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # 대화 히스토리
        result = session.run("""
            MATCH (u:User {name: 'jeong-sik'})-[k:KNOWS]->(c:Character)
            RETURN k.conversation_history as history,
                   k.emotion_history as emotions
        """)

        record = result.single()
        if not record:
            return []

        # Parse conversations
        conversations = []
        history = record['history'] or []
        emotions = record['emotions'] or []

        for i, conv_str in enumerate(history[-n_turns:]):
            try:
                conv = json.loads(conv_str)

                # Get corresponding emotion if available
                emotion_data = None
                if i < len(emotions):
                    try:
                        emotion_data = json.loads(emotions[i])
                    except:
                        pass

                conversations.append({
                    "user": conv.get('user', ''),
                    "sangsu": conv.get('sangsu', ''),
                    "emotion": emotion_data.get('emotion', 'unknown') if emotion_data else 'unknown',
                    "points": emotion_data.get('points', 0) if emotion_data else 0
                })
            except:
                continue

    driver.close()
    return conversations


def analyze_character_profile(conversations: list) -> dict:
    """
    LLM으로 캐릭터 프로파일 분석

    **Returns**:
    {
      "personality_traits": {...},
      "speech_patterns": {...},
      "emotional_responses": {...},
      "obsessions": {...}
    }
    """
    client = Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

    # Conversation context
    conv_text = "\n\n".join([
        f"User: {c['user']}\nSangsu: {c['sangsu']}\n(Emotion: {c['emotion']}, Points: {c['points']})"
        for c in conversations
    ])

    prompt = f"""Analyze this character "상수" based on recent conversations.

**Conversations** (recent {len(conversations)} turns):
{conv_text}

**Character Background**:
- 45세 독립영화 감독
- 대표작 없음, 10년째 각본만
- 위선적, 자기합리화, 가스라이팅
- 인정 욕구 극심

Analyze and return JSON:
{{
  "personality_traits": {{
    "defensiveness": 0.0-1.0,  // 방어적 성향
    "narcissism": 0.0-1.0,     // 자기애
    "vulnerability": 0.0-1.0,   // 취약성 노출
    "gaslighting_tendency": 0.0-1.0,
    "insecurity": 0.0-1.0      // 불안감
  }},
  "speech_patterns": {{
    "avg_sentence_length": int,  // 평균 문장 길이
    "excuse_frequency": int,     // 변명 빈도 (10턴당)
    "art_theory_frequency": int, // 예술론 빈도
    "favorite_phrases": [...]    // 자주 쓰는 말 (최대 5개)
  }},
  "emotional_responses": {{
    "breakdown_threshold": 0-10,  // 무너지는 강도
    "main_trigger": "attack|dismissal|...",  // 주 트리거
    "recovery_speed": "fast|slow"  // 회복 속도
  }},
  "obsessions": {{
    "recognition": 0.0-1.0,  // 인정 욕구
    "movies": 0.0-1.0,       // 영화 집착
    "money": 0.0-1.0,        // 돈 불안
    "age": 0.0-1.0           // 나이 불안
  }},
  "insights": "2-3 sentences summarizing character evolution"
}}

Return ONLY JSON, no explanation."""

    try:
        response = client.messages.create(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=1000,
            messages=[{"role": "user", "content": prompt}]
        )

        result_text = response.content[0].text.strip()

        # Remove markdown code blocks if present
        if result_text.startswith("```"):
            result_text = result_text.split("```")[1]
            if result_text.startswith("json"):
                result_text = result_text[4:]
            result_text = result_text.strip()

        profile = json.loads(result_text)
        return profile

    except Exception as e:
        log.error(f"❌ LLM analysis failed: {e}", file=sys.stderr)
        return None


def update_character_profile(profile: dict):
    """
    Neo4j Character 노드 업데이트
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # Character 노드에 profile 저장
        profile_json = json.dumps(profile, ensure_ascii=False)

        session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            SET c.personality_traits = $traits,
                c.speech_patterns = $speech,
                c.emotional_responses = $emotions,
                c.obsessions = $obsessions,
                c.profile_insights = $insights,
                c.profile_updated = datetime()
        """,
        traits=json.dumps(profile['personality_traits'], ensure_ascii=False),
        speech=json.dumps(profile['speech_patterns'], ensure_ascii=False),
        emotions=json.dumps(profile['emotional_responses'], ensure_ascii=False),
        obsessions=json.dumps(profile['obsessions'], ensure_ascii=False),
        insights=profile['insights'])

    driver.close()
    log.info(f"✅ Character profile updated!")


def show_current_profile():
    """
    현재 Character 프로필 조회
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        result = session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            RETURN c.personality_traits as traits,
                   c.speech_patterns as speech,
                   c.emotional_responses as emotions,
                   c.obsessions as obsessions,
                   c.profile_insights as insights,
                   c.profile_updated as updated
        """)

        record = result.single()
        if not record or not record['traits']:
            log.error(f"❌ No profile found!")
            driver.close()
            return

        profile = {
            "personality_traits": json.loads(record['traits']) if record['traits'] else None,
            "speech_patterns": json.loads(record['speech']) if record['speech'] else None,
            "emotional_responses": json.loads(record['emotions']) if record['emotions'] else None,
            "obsessions": json.loads(record['obsessions']) if record['obsessions'] else None,
            "insights": record['insights'],
            "updated": str(record['updated'])
        }

        print(json.dumps(profile, ensure_ascii=False, indent=2))

    driver.close()


def main():
    log_script_start(log, "Sangsu Character Profiler")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-character-profiler.py --analyze [N]")
        print("  python3 sangsu-character-profiler.py --show-profile")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--analyze":
        n_turns = int(sys.argv[2]) if len(sys.argv) > 2 else 20

        print(f"📊 Analyzing recent {n_turns} turns...")
        conversations = get_conversation_sample(n_turns)

        if not conversations:
            log.error(f"❌ No conversations found!")
            sys.exit(1)

        log.info(f"✅ Found {len(conversations)} turns")
        print("🧠 Running LLM analysis...")

        profile = analyze_character_profile(conversations)

        if not profile:
            log.error(f"❌ Analysis failed!")
            sys.exit(1)

        print("\n📈 Analysis Result:")
        print(json.dumps(profile, ensure_ascii=False, indent=2))

        print("\n💾 Updating Neo4j...")
        update_character_profile(profile)

    elif command == "--show-profile":
        show_current_profile()

    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
