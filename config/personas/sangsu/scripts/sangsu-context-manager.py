#!/usr/bin/env python3
"""
상수 대화 컨텍스트 매니저 (통합 시스템)

**Features**:
1. 대화 컨텍스트 메모리 (주제 추적)
2. 술 레벨 시스템 (0-3)
3. 시간대 반영 (낮/밤)
4. 친밀도 이벤트 트리거
"""

import os
import json
import sys
from datetime import datetime
from pathlib import Path
from neo4j import GraphDatabase

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')


def get_neo4j_creds():
    """Get Neo4j credentials from environment.

    Note: All secrets should be pre-exported in ~/.zshenv
    No more 1Password CLI calls - causes launchd hangs
    """
    return {
        'username': os.environ.get('NEO4J_USER', 'neo4j'),
        'password': os.environ.get('NEO4J_PASSWORD', '')
    }


def get_context(user_name: str = "jeong-sik") -> dict:
    """
    현재 대화 컨텍스트 조회

    **Returns**:
    - intimacy, stage
    - drunk_level (0-3)
    - time_of_day (day/night)
    - recent_topics (list)
    - emotion_history (last 5)
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(os.environ['NEO4J_URI'],
                                  auth=(creds['username'], creds['password']))

    with driver.session() as session:
        # Ensure drunk_level is initialized (0 if NULL)
        session.run("""
            MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
            WHERE k.drunk_level IS NULL
            SET k.drunk_level = 0
        """, user_name=user_name)

        result = session.run("""
            MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
            RETURN k.intimacy as intimacy,
                   k.stage as stage,
                   k.drunk_level as drunk_level,
                   k.recent_topics as recent_topics,
                   k.emotion_history as emotion_history,
                   k.conversations as conversations,
                   k.last_interaction as last_interaction
        """, user_name=user_name)

        record = result.single()
        if not record:
            return None

        # 시간대 판단 (현재 시각)
        hour = datetime.now().hour
        time_of_day = "night" if hour >= 18 or hour < 6 else "day"

        # 최근 5턴 emotion history
        emotion_history = record['emotion_history'] or []
        recent_emotions = []
        for entry in emotion_history[-5:]:
            try:
                recent_emotions.append(json.loads(entry))
            except:
                continue

        # Convert Neo4j DateTime to ISO string for JSON serialization
        last_interaction = record['last_interaction']
        if last_interaction:
            from neo4j.time import DateTime
            if isinstance(last_interaction, DateTime):
                last_interaction = datetime(
                    last_interaction.year,
                    last_interaction.month,
                    last_interaction.day,
                    last_interaction.hour,
                    last_interaction.minute,
                    last_interaction.second
                ).isoformat()

        context = {
            "user": user_name,
            "intimacy": record['intimacy'],
            "stage": record['stage'],
            "drunk_level": record['drunk_level'] or 0,  # Now always initialized to 0
            "time_of_day": time_of_day,
            "recent_topics": record['recent_topics'] or [],
            "recent_emotions": recent_emotions,
            "conversations": record['conversations'],
            "last_interaction": last_interaction
        }

    driver.close()
    return context


def update_context(user_name: str, updates: dict):
    """
    컨텍스트 업데이트

    **Updates**:
    - drunk_level (0-3)
    - recent_topics (append)
    - user_gender (male/female) - affects tone
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(os.environ['NEO4J_URI'],
                                  auth=(creds['username'], creds['password']))

    with driver.session() as session:
        # drunk_level 업데이트
        if 'drunk_level' in updates:
            session.run("""
                MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
                SET k.drunk_level = $drunk_level
            """, user_name=user_name, drunk_level=updates['drunk_level'])
            print(f"🍺 Drunk level updated: {updates['drunk_level']}")

        # recent_topics 추가
        if 'add_topic' in updates:
            session.run("""
                MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
                SET k.recent_topics = coalesce(k.recent_topics, []) + [$topic]
            """, user_name=user_name, topic=updates['add_topic'])
            print(f"📝 Topic added: {updates['add_topic']}")

        # user_gender 설정
        if 'user_gender' in updates:
            session.run("""
                MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
                SET k.user_gender = $gender
            """, user_name=user_name, gender=updates['user_gender'])
            print(f"👤 User gender set: {updates['user_gender']}")

    driver.close()


def get_response_modifier(context: dict) -> dict:
    """
    컨텍스트 기반 응답 modifier

    **Modifiers**:
    - drunk_level → 말투 변화
    - time_of_day → 에너지 레벨
    - user_gender → 톤 변화
    - stage → 대사 필터링
    """
    modifiers = {
        "speech_style": "normal",
        "energy_level": "medium",
        "tone": "neutral",
        "quote_stage_max": context['stage']
    }

    # Drunk level
    drunk = context['drunk_level']
    if drunk == 0:
        modifiers['speech_style'] = "formal"
    elif drunk == 1:
        modifiers['speech_style'] = "relaxed"
    elif drunk == 2:
        modifiers['speech_style'] = "emotional"
    else:  # 3
        modifiers['speech_style'] = "confessional"

    # Time of day
    if context['time_of_day'] == "night":
        modifiers['energy_level'] = "low"
        modifiers['mood'] = "reflective"
    else:
        modifiers['energy_level'] = "medium"
        modifiers['mood'] = "casual"

    # Stage-based events
    if context['intimacy'] >= 20 and context['stage'] == 1:
        modifiers['event'] = "stage_up"  # Stage 1 → 2!
    elif context['intimacy'] == 0:
        modifiers['event'] = "rock_bottom"  # 최저점
    elif context['intimacy'] >= 80:
        modifiers['event'] = "deep_bond"  # 진짜 친구

    return modifiers


def main():
    log_script_start(log, "Sangsu Context Manager")

    """CLI: Get context or update"""
    if len(sys.argv) < 2:
        # Get context
        context = get_context()
        if context:
            print(json.dumps(context, ensure_ascii=False, indent=2))
        else:
            log.error(f"❌ Context not found")
        return

    # Update context
    command = sys.argv[1]

    if command == "drink":
        # Increase drunk level
        context = get_context()
        new_level = min(3, context['drunk_level'] + 1)
        update_context("jeong-sik", {"drunk_level": new_level})
        print(f"🍺 Sangsu drinks! Level: {new_level}/3")

    elif command == "sober":
        update_context("jeong-sik", {"drunk_level": 0})
        print("💧 Sangsu sobered up")

    elif command.startswith("topic:"):
        topic = command.split(":", 1)[1]
        update_context("jeong-sik", {"add_topic": topic})

    elif command == "modifiers":
        context = get_context()
        modifiers = get_response_modifier(context)
        print(json.dumps(modifiers, ensure_ascii=False, indent=2))

    else:
        print("Usage:")
        print("  python3 sangsu-context-manager.py          # Get context")
        print("  python3 sangsu-context-manager.py drink    # Increase drunk")
        print("  python3 sangsu-context-manager.py sober    # Reset drunk")
        print("  python3 sangsu-context-manager.py topic:영화  # Add topic")
        print("  python3 sangsu-context-manager.py modifiers # Get modifiers")


if __name__ == "__main__":
    main()
