#!/usr/bin/env python3
"""
상수 자동 대화 처리 (Voice → Emotion → Update)

**Workflow**:
1. User 음성 → STT
2. Sangsu 응답 생성 (spontaneity + personality)
3. 감정 자동 감지
4. Neo4j 업데이트 (intimacy, emotion, buffer)
5. TTS → User

**Usage**:
  python3 sangsu-auto-conversation.py --start
"""

import sys
import json
import subprocess
from datetime import datetime
from neo4j import GraphDatabase
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


def detect_emotion(user_message: str) -> dict:
    """
    감정 자동 감지 (간단한 키워드 기반)

    **TODO**: LLM으로 더 정교하게
    """
    user_lower = user_message.lower()

    # Attack patterns
    attack_keywords = ['멍청', '바보', '쓰레기', '못해', '형편없']
    if any(k in user_lower for k in attack_keywords):
        return {'emotion': 'attack', 'points': -5}

    # Dismissal patterns
    dismissal_keywords = ['됐어', '아침부터', '그만', '바빠', '가봐야', '나중에']
    if any(k in user_lower for k in dismissal_keywords):
        return {'emotion': 'dismissal', 'points': -4}

    # Validation patterns
    validation_keywords = ['잘했', '좋아', '멋져', '대단', '훌륭']
    if any(k in user_lower for k in validation_keywords):
        return {'emotion': 'validation', 'points': +5}

    # Empathy patterns
    empathy_keywords = ['힘들었', '알아', '이해해', '괜찮아']
    if any(k in user_lower for k in empathy_keywords):
        return {'emotion': 'empathy', 'points': +4}

    # Curiosity patterns
    curiosity_keywords = ['?', '뭐', '어떻게', '왜', '설명']
    if any(k in user_lower for k in curiosity_keywords):
        return {'emotion': 'curiosity', 'points': +2}

    # Default: neutral
    return {'emotion': 'neutral', 'points': 0}


def update_emotion_and_intimacy(user_message: str, emotion_data: dict):
    """
    감정 + 친밀도 자동 업데이트

    **Calls**:
    - update-intimacy.py
    """
    emotion = emotion_data['emotion']
    points = emotion_data['points']

    print(f"📊 Detected: {emotion} ({points:+d} points)")

    # Call update-intimacy.py
    result = subprocess.run([
        'python3',
        '~/me/scripts/update-intimacy.py'.replace('~', subprocess.os.path.expanduser('~')),
        '--emotion', emotion,
        '--user', 'jeong-sik'
    ], capture_output=True, text=True)

    if result.returncode == 0:
        log.info(f"✅ Intimacy updated")
    else:
        log.warning(f"⚠️  Update failed: {result.stderr}")


def generate_response(user_message: str, emotion_data: dict) -> str:
    """
    상수 응답 생성 (spontaneity + personality)

    **Calls**:
    - sangsu-spontaneity-system.py
    - Living State context
    """
    emotion = emotion_data['emotion']

    # Get living state
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        result = session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            RETURN c.living_state as state,
                   c.personality_traits as traits
        """)

        record = result.single()
        living_state = json.loads(record['state']) if record and record['state'] else {}
        personality = json.loads(record['traits']) if record and record['traits'] else {}

    driver.close()

    # Context from living state
    context = {
        'mood': living_state.get('current_mood', 0.0),
        'loneliness': living_state.get('loneliness', 0.5),
        'energy': living_state.get('energy', 0.7),
        'drunk': False,  # TODO: 실제 감지
        'exhausted': living_state.get('energy', 0.7) < 0.3
    }

    # Call spontaneity system
    result = subprocess.run([
        'python3',
        '~/me/scripts/sangsu-spontaneity-system.py'.replace('~', subprocess.os.path.expanduser('~')),
        '--get-response', emotion,
        '--context', json.dumps(context)
    ], capture_output=True, text=True)

    if result.returncode == 0:
        response_data = json.loads(result.stdout)
        return response_data['response']
    else:
        # Fallback
        return "...어."


def record_turn(user_message: str, sangsu_response: str):
    """
    대화 턴 기록

    **Calls**:
    - record-conversation-turn.py
    """
    result = subprocess.run([
        'python3',
        '~/me/scripts/record-conversation-turn.py'.replace('~', subprocess.os.path.expanduser('~')),
        '--user', user_message,
        '--sangsu', sangsu_response
    ], capture_output=True, text=True)

    if result.returncode == 0:
        log.info(f"✅ Turn recorded")
    else:
        log.warning(f"⚠️  Recording failed: {result.stderr}")


def conversation_loop():
    """
    메인 대화 루프

    **Flow**:
    1. User input (voice or text)
    2. Emotion detection
    3. Response generation
    4. Update systems
    5. Output response
    """
    print("🎤 Sangsu Auto Conversation")
    print("━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    turn = 0

    while True:
        turn += 1
        print(f"\n━━━ Turn {turn} ━━━")

        # 1. User input
        user_message = input("You: ").strip()

        if not user_message:
            continue

        if user_message.lower() in ['quit', 'exit', '종료', '끝']:
            print("\n👋 대화 종료")
            break

        # 2. Emotion detection
        emotion_data = detect_emotion(user_message)

        # 3. Response generation
        sangsu_response = generate_response(user_message, emotion_data)

        # 4. Output
        print(f"Sangsu: {sangsu_response}")
        print(f"   └─ [{emotion_data['emotion']}, {emotion_data['points']:+d}]")

        # 5. Update systems
        update_emotion_and_intimacy(user_message, emotion_data)
        record_turn(user_message, sangsu_response)

        # 6. Check for reflection trigger
        # TODO: 버퍼 체크 → 성찰 생성


def main():
    log_script_start(log, "Sangsu Auto Conversation")

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-auto-conversation.py --start")
        print("  python3 sangsu-auto-conversation.py --voice  # TODO")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--start":
        conversation_loop()
    elif command == "--voice":
        print("🎙️  Voice mode TODO")
        # TODO: VoiceMode integration
    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
