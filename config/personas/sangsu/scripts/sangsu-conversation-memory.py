#!/usr/bin/env python3
"""
상수 대화 기억 시스템 (Conversation Memory)

**저장**:
- User 발언 + 상수 응답을 Neo4j에 저장
- recent_conversation_history (최근 10턴)
- 주제 자동 추출

**사용**:
python3 sangsu-conversation-memory.py add-turn \
  --user "나도 영화 좋아해" \
  --sangsu "오! 그래? 어떤 영화 좋아해?"

python3 sangsu-conversation-memory.py get-recent [N]
"""

import os
import json
import sys
from datetime import datetime
from neo4j import GraphDatabase
from pathlib import Path

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


def add_conversation_turn(user_message: str, sangsu_response: str, user_name: str = "jeong-sik"):
    """
    대화 턴 추가

    **Stored in**: KNOWS.conversation_history (JSON array)
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(os.environ['NEO4J_URI'],
                                  auth=(creds['username'], creds['password']))

    turn_entry = json.dumps({
        "timestamp": datetime.now().isoformat(),
        "user": user_message,
        "sangsu": sangsu_response
    }, ensure_ascii=False)

    with driver.session() as session:
        session.run("""
            MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
            SET k.conversation_history = coalesce(k.conversation_history, []) + [$turn_entry]
        """, user_name=user_name, turn_entry=turn_entry)

        log.info(f"✅ Turn saved:")
        print(f"   User: {user_message[:50]}...")
        print(f"   Sangsu: {sangsu_response[:50]}...")

    driver.close()


def get_recent_turns(n: int = 5, user_name: str = "jeong-sik") -> list:
    """
    최근 N턴 조회

    **Returns**: list of {timestamp, user, sangsu}
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(os.environ['NEO4J_URI'],
                                  auth=(creds['username'], creds['password']))

    with driver.session() as session:
        result = session.run("""
            MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
            RETURN k.conversation_history as history
        """, user_name=user_name)

        record = result.single()
        if not record or not record['history']:
            return []

        # Parse JSON strings
        turns = []
        for entry in record['history'][-n:]:
            try:
                turns.append(json.loads(entry))
            except:
                continue

    driver.close()
    return turns


def get_context_for_llm(user_name: str = "jeong-sik") -> dict:
    """
    LLM 프롬프트용 컨텍스트 생성

    **Returns**:
    - recent_turns (last 3)
    - sangsu_last_message
    - current_topic (most recent)
    """
    recent_turns = get_recent_turns(3, user_name)

    if not recent_turns:
        return {
            "recent_turns": [],
            "sangsu_last_message": "",
            "current_topic": "N/A"
        }

    # 마지막 상수 발언
    sangsu_last = recent_turns[-1].get('sangsu', '')

    # 현재 주제 추출 (간단하게: 최근 User 발언에서 키워드)
    user_last = recent_turns[-1].get('user', '')
    keywords = ['영화', '술', '여자', '연애', '일', '돈', '예술']
    current_topic = next((kw for kw in keywords if kw in user_last), 'casual')

    return {
        "recent_turns": recent_turns,
        "sangsu_last_message": sangsu_last,
        "current_topic": current_topic,
        "turn_count": len(recent_turns)
    }


def main():
    log_script_start(log, "Sangsu Conversation Memory")

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-conversation-memory.py add-turn --user '<msg>' --sangsu '<response>'")
        print("  python3 sangsu-conversation-memory.py get-recent [N]")
        print("  python3 sangsu-conversation-memory.py context")
        sys.exit(1)

    command = sys.argv[1]

    if command == "add-turn":
        # Parse --user and --sangsu
        user_msg = None
        sangsu_resp = None
        i = 2
        while i < len(sys.argv):
            if sys.argv[i] == "--user":
                user_msg = sys.argv[i+1]
                i += 2
            elif sys.argv[i] == "--sangsu":
                sangsu_resp = sys.argv[i+1]
                i += 2
            else:
                i += 1

        if not user_msg or not sangsu_resp:
            log.error(f"❌ Missing --user or --sangsu")
            sys.exit(1)

        add_conversation_turn(user_msg, sangsu_resp)

    elif command == "get-recent":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 5
        turns = get_recent_turns(n)
        print(f"\n📜 Recent {len(turns)} turns:\n")
        for i, turn in enumerate(turns, 1):
            print(f"Turn {i} ({turn['timestamp']}):")
            print(f"  User: {turn['user']}")
            print(f"  Sangsu: {turn['sangsu']}")
            print()

    elif command == "context":
        context = get_context_for_llm()
        print(json.dumps(context, ensure_ascii=False, indent=2))

    else:
        log.error(f"❌ Unknown command: {command}")


if __name__ == "__main__":
    main()
