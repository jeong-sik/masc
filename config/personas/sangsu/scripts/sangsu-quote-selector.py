#!/usr/bin/env python3
"""
상수 대사 선택기 - 홍상수 영화 명대사 점프

**Logic**:
1. 현재 intimacy_stage에 맞는 Quote 기본 선택
2. emotion + desire_gauge 기반 theme 필터링
3. 맥락 전환 (dramatic jump)

**Usage**:
  python3 sangsu-quote-selector.py --stage 3 --emotion validation --desire recognition:96
"""

import sys
import json
import subprocess
import random
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


def select_quote(stage: int, emotion: str, desires: dict, context: dict = None) -> dict:
    """
    맥락 기반 Quote 선택

    **Jump Logic**:
    - recognition >= 90 + validation → Stage 7 점프 (진심 모드)
    - attack/sarcasm + stage <= 2 → gaslighting 대사
    - empathy + connection >= 80 → vulnerability 대사
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    # 🔥 Dramatic Jump 조건
    target_stage = stage
    theme_filter = None

    # Jump 1: 인정받고 싶어서 미침 + User가 인정해줌
    if desires.get('recognition', 0) >= 90 and emotion in ['validation', 'empathy']:
        target_stage = 7  # 최고 단계로 점프!
        theme_filter = ['solitude', 'giving_up', 'general']  # 진심 테마들
        jump_reason = "인정 욕구 폭발 → 진심 모드"

    # Jump 2: 공격받음 + 초반 → 가스라이팅
    elif emotion in ['attack', 'sarcasm'] and stage <= 2:
        target_stage = 1
        theme_filter = ['art', 'age', 'dismissive']  # 방어 테마들
        jump_reason = "공격받음 → 방어 모드"

    # Jump 3: 외로움 + 공감받음 → 취약점 드러냄
    elif desires.get('connection', 0) >= 80 and emotion == 'empathy':
        target_stage = min(7, stage + 2)  # 2단계 점프
        theme_filter = ['solitude', 'vulnerability']
        jump_reason = "외로움 + 공감 → 마음 열림"

    # Jump 4: 무시당함 → 예술론 늘어놓기
    elif emotion in ['dismissal', 'belittle']:
        target_stage = stage
        theme_filter = 'art'
        jump_reason = "무시당함 → 예술가 과시"

    else:
        jump_reason = "normal flow"

    # Query
    with driver.session() as session:
        if theme_filter:
            result = session.run("""
                MATCH (q:Quote)-[:FROM_MOVIE]->(m:Movie {director: "홍상수"})
                WHERE q.intimacy_stage = $stage AND q.theme IN $themes
                RETURN q.text as text, q.theme as theme, q.intimacy_stage as stage
            """, stage=target_stage, themes=theme_filter)
        else:
            result = session.run("""
                MATCH (q:Quote)-[:FROM_MOVIE]->(m:Movie {director: "홍상수"})
                WHERE q.intimacy_stage = $stage
                RETURN q.text as text, q.theme as theme, q.intimacy_stage as stage
            """, stage=target_stage)

        quotes = [dict(record) for record in result]

    driver.close()

    if not quotes:
        return {
            "quote": None,
            "stage": target_stage,
            "theme": theme_filter,
            "jump_reason": jump_reason,
            "available": False
        }

    # 랜덤 선택
    selected = random.choice(quotes)

    return {
        "quote": selected['text'],
        "stage": selected['stage'],
        "theme": selected['theme'],
        "jump_reason": jump_reason,
        "available": True,
        "original_stage": stage,
        "jumped": (target_stage != stage)
    }


def main():
    log_script_start(log, "Sangsu Quote Selector")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-quote-selector.py --stage 3 --emotion validation --desire recognition:96,connection:85")
        sys.exit(1)

    # Parse args
    stage = 1
    emotion = "neutral"
    desires = {}

    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == "--stage":
            stage = int(sys.argv[i+1])
            i += 2
        elif sys.argv[i] == "--emotion":
            emotion = sys.argv[i+1]
            i += 2
        elif sys.argv[i] == "--desire":
            # Parse "recognition:96,connection:85"
            for pair in sys.argv[i+1].split(','):
                k, v = pair.split(':')
                desires[k] = int(v)
            i += 2
        else:
            i += 1

    result = select_quote(stage, emotion, desires)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
