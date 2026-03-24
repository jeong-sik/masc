#!/usr/bin/env python3
"""
상수 욕망 게이지 시스템

**4가지 욕망**:
1. recognition (인정받고 싶음) - 가장 강함!
2. connection (외로움, 관계 욕구)
3. validation (내가 맞다고 해줘)
4. escape (다른 거 하고 싶음)

**Usage**:
  python3 sangsu-desire-gauge.py --calculate
  python3 sangsu-desire-gauge.py --update <emotion_patterns>
"""

import sys
import json
import subprocess
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


def calculate_desire_gauge(emotion_patterns: dict, intimacy: int, stage: int) -> dict:
    """
    감정 패턴 기반 욕망 게이지 계산

    **Logic**:
    - recognition: 공격/비꼼 많을수록 UP (인정 못 받음)
    - connection: 친밀도 낮을수록 UP (외로움)
    - validation: 논리적 공격 많을수록 UP (내 말이 맞다고!)
    - escape: Stage 높아질수록 DOWN (관계 좋아지면 현실 만족)
    """
    total = emotion_patterns.get('total_conversations', 1)

    # 1. recognition (0-100)
    attack_ratio = (emotion_patterns.get('total_attacks', 0) / total) * 100
    sarcasm_ratio = (emotion_patterns.get('total_sarcasm', 0) / total) * 100
    validation_ratio = (emotion_patterns.get('total_validation', 0) / total) * 100

    # 공격/비꼼 많으면 인정 욕구 UP, 인정받으면 DOWN
    recognition = min(100, max(0,
        80 + (attack_ratio + sarcasm_ratio) * 2 - validation_ratio * 3
    ))

    # 2. connection (0-100)
    # 친밀도 낮으면 외로움 UP
    connection = max(0, 90 - intimacy)

    # 3. validation (0-100)
    belittle_ratio = (emotion_patterns.get('total_belittle', 0) / total) * 100
    validation = min(100, max(0,
        70 + belittle_ratio * 2 - validation_ratio * 2
    ))

    # 4. escape (0-100)
    # Stage 낮고 공격 많으면 현실 도피 욕구 UP
    escape = max(0, min(100,
        60 + (7 - stage) * 5 + attack_ratio
    ))

    return {
        "recognition": int(recognition),
        "connection": int(connection),
        "validation": int(validation),
        "escape": int(escape)
    }


def get_current_desires(user_name: str = "jeong-sik") -> dict:
    """
    현재 욕망 게이지 조회 (Neo4j)
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        result = session.run("""
            MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
            RETURN k.intimacy as intimacy,
                   k.stage as stage,
                   k.emotion_patterns as emotion_patterns,
                   k.desire_gauge as desire_gauge
        """, user_name=user_name)

        record = result.single()
        if not record:
            return None

        # emotion_patterns parse
        emotion_patterns = json.loads(record['emotion_patterns']) if record['emotion_patterns'] else {}

        # 현재 욕망 게이지 (없으면 계산)
        if record['desire_gauge']:
            current_desires = json.loads(record['desire_gauge'])
        else:
            current_desires = calculate_desire_gauge(
                emotion_patterns,
                record['intimacy'],
                record['stage']
            )

    driver.close()
    return {
        "intimacy": record['intimacy'],
        "stage": record['stage'],
        "emotion_patterns": emotion_patterns,
        "desire_gauge": current_desires
    }


def update_desire_gauge(user_name: str = "jeong-sik"):
    """
    욕망 게이지 재계산 + Neo4j 업데이트
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        result = session.run("""
            MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
            RETURN k.intimacy as intimacy,
                   k.stage as stage,
                   k.emotion_patterns as emotion_patterns
        """, user_name=user_name)

        record = result.single()
        if not record:
            log.error(f"❌ User not found!")
            driver.close()
            return

        emotion_patterns = json.loads(record['emotion_patterns']) if record['emotion_patterns'] else {}

        # 욕망 게이지 계산
        desires = calculate_desire_gauge(
            emotion_patterns,
            record['intimacy'],
            record['stage']
        )

        # Neo4j 업데이트
        desire_json = json.dumps(desires, ensure_ascii=False)
        session.run("""
            MATCH (u:User {name: $user_name})-[k:KNOWS]->(c:Character)
            SET k.desire_gauge = $desire_gauge
        """, user_name=user_name, desire_gauge=desire_json)

        log.info(f"✅ Desire Gauge Updated!")
        print(json.dumps({
            "user": user_name,
            "intimacy": record['intimacy'],
            "stage": record['stage'],
            "desires": desires
        }, ensure_ascii=False, indent=2))

    driver.close()


def main():
    log_script_start(log, "Sangsu Desire Gauge")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-desire-gauge.py --calculate")
        print("  python3 sangsu-desire-gauge.py --update")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--calculate":
        result = get_current_desires()
        if result:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            log.error(f"❌ No data found")

    elif command == "--update":
        update_desire_gauge()

    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
