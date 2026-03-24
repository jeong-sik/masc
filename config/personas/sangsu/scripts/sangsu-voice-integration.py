#!/usr/bin/env python3
"""
상수 Voice Integration (Living State + VoiceMode)

**Usage**:
  python3 sangsu-voice-integration.py --start

**Workflow**:
1. Living State에서 현재 상태 읽기
2. VoiceMode로 대화
3. 대화 내용 → Living State 업데이트
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


def get_living_state():
    """현재 Living State 조회"""
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
        if record and record['state']:
            return json.loads(record['state'])

    driver.close()
    return None


def update_interaction_time():
    """대화 시작 → last_interaction 업데이트"""
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # Load current state
        result = session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            RETURN c.living_state as state
        """)

        record = result.single()
        state = json.loads(record['state']) if record and record['state'] else {}

        # Update
        state['last_interaction'] = datetime.now().isoformat()
        state['loneliness'] = max(0.0, state.get('loneliness', 0.5) - 0.3)  # 외로움 감소

        # Save
        session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            SET c.living_state = $state
        """, state=json.dumps(state, ensure_ascii=False))

    driver.close()


def get_greeting_message(state: dict) -> str:
    """상태 기반 인사말"""
    if not state:
        return "야, 뭐해?"

    awake = state.get('awake', True)
    loneliness = state.get('loneliness', 0.5)
    mood = state.get('current_mood', 0.0)
    activity = state.get('current_activity', 'waiting')

    # 자고 있었으면
    if not awake:
        return "어? ...자고 있었는데. 뭐야?"

    # 매우 외로웠으면
    if loneliness > 0.7:
        return "어! 있었어? ...기다렸어."

    # 우울했으면
    if mood < -0.5:
        return "...어. 뭐해?"

    # 뭔가 하고 있었으면
    if activity == 'watching_movie':
        return "어? 영화 보고 있었는데. 뭐야?"
    elif activity == 'writing_script':
        return "각본 쓰고 있었어. 안 되네... 뭐?"

    # Default
    return "야, 뭐해?"


def start_voice_conversation():
    """VoiceMode로 대화 시작"""
    # 1. Living State 조회
    state = get_living_state()

    # 2. 인사말 생성
    greeting = get_greeting_message(state)

    # 3. 상태 정보 출력
    if state:
        print("📊 Current State:")
        print(f"   Awake: {state.get('awake', True)}")
        print(f"   Mood: {state.get('current_mood', 0.0):.2f}")
        print(f"   Loneliness: {state.get('loneliness', 0.5):.2f}")
        print(f"   Energy: {state.get('energy', 0.7):.2f}")
        print(f"   Activity: {state.get('current_activity', 'waiting')}")
        print()

    # 4. 대화 시작 알림
    print(f"🎤 Sangsu: \"{greeting}\"")
    print()

    # 5. last_interaction 업데이트
    update_interaction_time()

    # 6. VoiceMode 시작 (기존 스크립트 활용)
    # TODO: 실제 voicemode 호출
    print("🎙️  VoiceMode 연결 중...")
    print("(현재는 mock - 실제로는 voicemode MCP 호출)")


def main():
    log_script_start(log, "Sangsu Voice Integration")

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-voice-integration.py --start")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--start":
        start_voice_conversation()
    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
