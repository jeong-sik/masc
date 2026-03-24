#!/usr/bin/env python3
"""
상수 음성 대화 자동화 (Full Pipeline)

**Pipeline**:
User 음성 → STT → 감정 감지 → 응답 생성 → 업데이트 → TTS → User

**Usage**:
  python3 sangsu-voice-auto.py --start
  python3 sangsu-voice-auto.py --continue  # 이어서 대화
"""

import sys
import json
import subprocess
import os
from datetime import datetime
from neo4j import GraphDatabase


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


def detect_emotion_keyword(user_message: str) -> dict:
    """
    키워드 기반 감정 감지 (빠름)
    """
    user_lower = user_message.lower()

    # Attack
    if any(k in user_lower for k in ['멍청', '바보', '쓰레기', '못해', '형편없']):
        return {'emotion': 'attack', 'points': -5}

    # Dismissal
    if any(k in user_lower for k in ['됐어', '아침부터', '그만', '바빠', '가봐야', '나중에', '안돼', '싫어']):
        return {'emotion': 'dismissal', 'points': -4}

    # Belittle
    if any(k in user_lower for k in ['별로', '시시해', '그냥 그래', '뻔해']):
        return {'emotion': 'belittle', 'points': -3}

    # Sarcasm
    if any(k in user_lower for k in ['ㅋㅋ', '하하', '그렇겠네', '당연하지']):
        # Context needed - for now treat neutral
        return {'emotion': 'sarcasm', 'points': -2}

    # Validation
    if any(k in user_lower for k in ['잘했', '좋아', '멋져', '대단', '훌륭', '최고']):
        return {'emotion': 'validation', 'points': +5}

    # Empathy
    if any(k in user_lower for k in ['힘들었', '알아', '이해해', '괜찮아', '괜찮을 거야']):
        return {'emotion': 'empathy', 'points': +4}

    # Curiosity
    if '?' in user_message or any(k in user_lower for k in ['뭐', '어떻게', '왜', '설명']):
        return {'emotion': 'curiosity', 'points': +2}

    # Neutral
    return {'emotion': 'neutral', 'points': 0}


def get_living_state():
    """Living State 조회"""
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
        state = json.loads(record['state']) if record and record['state'] else {}
        traits = json.loads(record['traits']) if record and record['traits'] else {}

    driver.close()
    return state, traits


def generate_sangsu_response(user_message: str, emotion_data: dict) -> str:
    """
    상수 응답 생성

    **Logic**:
    1. Living State context
    2. Personality traits
    3. Emotion-based response pool
    4. Spontaneity (30%)
    """
    import random
from pathlib import Path

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')

    state, traits = get_living_state()

    emotion = emotion_data['emotion']
    mood = state.get('current_mood', 0.0)
    loneliness = state.get('loneliness', 0.5)
    energy = state.get('energy', 0.7)

    # Exhausted override
    if energy < 0.3:
        exhausted_responses = {
            'dismissal': "...알았어. 피곤해.",
            'attack': "...아 됐어. 자고 싶어.",
            'validation': "...응. 고마워.",
            'neutral': "...피곤해."
        }
        return exhausted_responses.get(emotion, "...피곤해.")

    # Lonely override (high loneliness)
    if loneliness > 0.7:
        lonely_responses = {
            'dismissal': "...아 그래? 좀 그렇네. 근데... 조금만 더 얘기할래?",
            'neutral': "...뭐해? 심심한데.",
            'validation': "진짜? ...고마워. 오랜만에 좋은 말 들었어.",
        }
        if emotion in lonely_responses:
            return lonely_responses[emotion]

    # Response pools by emotion
    response_pools = {
        'dismissal': [
            "...됐어. 어차피.",
            "아 그래? 네가 뭘 알아?",
            "...알았어.",
            "뭐 어때."
        ],
        'attack': [
            "야 왜 그래?",
            "...미안. 내가 뭐 잘못했어?",
            "아니 뭔 소리야?",
            "...그래. 나 그래."
        ],
        'validation': [
            "진짜?",
            "...고마워.",
            "아 됐어. 괜찮아.",
            "...알아줘서 고마워."
        ],
        'empathy': [
            "...알아줘서 고마워.",
            "진짜... 알아주는 사람이 없어서...",
            "응.",
            "...힘들었어."
        ],
        'curiosity': [
            "어? 뭐?",
            "아 그거? 음...",
            "설명하자면...",
            "관심 있어?"
        ],
        'neutral': [
            "응.",
            "그래.",
            "...뭐?",
            "어."
        ]
    }

    pool = response_pools.get(emotion, ["..."])

    # Spontaneity (30%)
    if random.random() < 0.3:
        spontaneous = [
            "야 근데 말이야...",
            "영화 한 편 볼래?",
            "...외롭네.",
            "너 배고파?"
        ]
        pool.extend(spontaneous)

    return random.choice(pool)


def update_systems(user_message: str, sangsu_response: str, emotion_data: dict):
    """
    모든 시스템 자동 업데이트

    1. Intimacy + Emotion (update-intimacy.py)
    2. Conversation turn (record-conversation-turn.py)
    3. Living State last_interaction
    """
    emotion = emotion_data['emotion']

    # 1. Update intimacy
    result = subprocess.run([
        'python3',
        os.path.expanduser('~/me/scripts/update-intimacy.py'),
        '--emotion', emotion,
        '--user', 'jeong-sik'
    ], capture_output=True, text=True)

    if result.returncode == 0:
        print("   ✅ Intimacy updated")
    else:
        print(f"   ⚠️  Intimacy update failed: {result.stderr[:100]}")

    # 2. Record turn
    result = subprocess.run([
        'python3',
        os.path.expanduser('~/me/scripts/record-conversation-turn.py'),
        '--user', user_message,
        '--sangsu', sangsu_response
    ], capture_output=True, text=True)

    if result.returncode == 0:
        print("   ✅ Turn recorded")
    else:
        print(f"   ⚠️  Turn recording failed: {result.stderr[:100]}")

    # 3. Update Living State
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        result = session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            RETURN c.living_state as state
        """)

        record = result.single()
        state = json.loads(record['state']) if record and record['state'] else {}

        # Update
        state['last_interaction'] = datetime.now().isoformat()
        state['loneliness'] = max(0.0, state.get('loneliness', 0.5) - 0.2)  # 대화하면 외로움 감소

        session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            SET c.living_state = $state
        """, state=json.dumps(state, ensure_ascii=False))

    driver.close()
    print("   ✅ Living state updated")


def voice_turn(sangsu_message: str, voice: str = "CwhRBWXzGAHq8TQ4Fs17") -> str:
    """
    음성 대화 1턴

    TTS → User 음성 입력 → STT → 반환
    """
    # TODO: MCP voicemode 호출
    # 현재는 간단히 input으로 대체
    print(f"\n🎤 Sangsu: \"{sangsu_message}\"")
    print("   (음성 재생 중...)")

    user_input = input("You: ").strip()
    return user_input


def conversation_session(use_voice: bool = False):
    """
    대화 세션

    **Args**:
    - use_voice: True면 VoiceMode, False면 텍스트
    """
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎬 Sangsu Auto Conversation")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

    # Get initial state
    state, traits = get_living_state()

    # Greeting
    loneliness = state.get('loneliness', 0.5)
    if loneliness > 0.7:
        greeting = "어! 있었어? ...기다렸어."
    else:
        greeting = "야, 뭐해?"

    turn = 0

    while True:
        turn += 1
        print(f"\n━━━ Turn {turn} ━━━")

        # Get user input
        if use_voice:
            if turn == 1:
                user_message = voice_turn(greeting)
            else:
                user_message = voice_turn(sangsu_response)
        else:
            if turn == 1:
                print(f"Sangsu: {greeting}")
            user_message = input("You: ").strip()

        if not user_message or user_message.lower() in ['quit', 'exit', '종료']:
            print("\n👋 대화 종료")
            break

        # Detect emotion
        emotion_data = detect_emotion_keyword(user_message)
        print(f"   📊 [{emotion_data['emotion']}, {emotion_data['points']:+d}]")

        # Generate response
        sangsu_response = generate_sangsu_response(user_message, emotion_data)

        if not use_voice:
            print(f"Sangsu: {sangsu_response}")

        # Update all systems
        update_systems(user_message, sangsu_response, emotion_data)


def main():
    log_script_start(log, "Sangsu Voice Auto")

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-voice-auto.py --start        # 텍스트 모드")
        print("  python3 sangsu-voice-auto.py --voice        # 음성 모드 (TODO)")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--start":
        conversation_session(use_voice=False)
    elif command == "--voice":
        print("🎙️  음성 모드")
        conversation_session(use_voice=True)
    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
