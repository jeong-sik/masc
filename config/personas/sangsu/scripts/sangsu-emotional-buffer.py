#!/usr/bin/env python3
"""
상수 감정 버퍼 시스템 (Accumulated State)

**Logic**:
사건 = 예외(Exception) 아니고 누적된 로그(Buffer)
빤히 보고만 있다가... 터지는 거.

**Concept**:
- 감정은 즉시 반영 안 됨 (buffer에 쌓임)
- Threshold 넘으면 "자각" → personality drift
- 같은 패턴 반복 감지 (dismissal × 10 → "아 나 무시당하는구나")

**Usage**:
  python3 sangsu-emotional-buffer.py --check
  python3 sangsu-emotional-buffer.py --process
"""

import sys
import json
import subprocess
from datetime import datetime
from collections import Counter
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


def get_emotional_buffer() -> dict:
    """
    현재 감정 버퍼 조회

    **Returns**:
    {
      "buffer": [...],  # 최근 N개 감정 이벤트
      "patterns": {...},  # 반복 패턴 감지
      "overflow_risk": 0.0-1.0,  # 넘칠 위험도
      "conscious_awareness": 0.0-1.0  # 자각 수준
    }
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # Emotional buffer 조회
        result = session.run("""
            MATCH (u:User {name: 'jeong-sik'})-[k:KNOWS]->(c:Character)
            RETURN k.emotional_buffer as buffer,
                   k.buffer_metadata as metadata,
                   k.emotion_history as history
        """)

        record = result.single()
        if not record:
            return None

        # Parse buffer
        buffer_str = record['buffer'] or '[]'
        buffer = json.loads(buffer_str)

        # Parse metadata
        metadata_str = record['metadata'] or '{}'
        metadata = json.loads(metadata_str)

        # Parse emotion history (for pattern detection)
        history = record['history'] or []
        recent_emotions = []
        for e in history[-50:]:  # 최근 50개
            try:
                recent_emotions.append(json.loads(e))
            except:
                continue

    driver.close()

    # Analyze patterns
    patterns = analyze_patterns(recent_emotions)
    overflow_risk = calculate_overflow_risk(buffer, patterns)
    awareness = metadata.get('conscious_awareness', 0.0)

    return {
        "buffer": buffer,
        "buffer_size": len(buffer),
        "patterns": patterns,
        "overflow_risk": overflow_risk,
        "conscious_awareness": awareness,
        "metadata": metadata
    }


def analyze_patterns(emotions: list) -> dict:
    """
    반복 패턴 감지

    **Logic**:
    - 같은 감정 연속 (dismissal × 5)
    - 사이클 감지 (attack → breakdown → repeat)
    - 장기 트렌드 (최근 30개 중 70% dismissal)

    **Returns**:
    {
      "consecutive": {"dismissal": 5, ...},
      "cycles": [["attack", "breakdown"], ...],
      "trends": {"dismissal": 0.7, ...}
    }
    """
    if not emotions:
        return {"consecutive": {}, "cycles": [], "trends": {}}

    # 1. Consecutive detection
    consecutive = {}
    current_emotion = None
    count = 0

    for e in reversed(emotions):
        emotion = e.get('emotion', 'neutral')
        if emotion == current_emotion:
            count += 1
        else:
            if current_emotion and count >= 3:  # 3번 이상 연속
                consecutive[current_emotion] = count
            current_emotion = emotion
            count = 1

    if current_emotion and count >= 3:
        consecutive[current_emotion] = count

    # 2. Cycle detection (simple: just count pairs)
    emotion_sequence = [e.get('emotion', 'neutral') for e in emotions[-20:]]
    cycles = []
    for i in range(len(emotion_sequence) - 1):
        pair = [emotion_sequence[i], emotion_sequence[i+1]]
        if pair not in cycles and emotion_sequence.count(emotion_sequence[i]) >= 2:
            cycles.append(pair)

    # 3. Trend detection (last 30)
    recent_30 = [e.get('emotion', 'neutral') for e in emotions[-30:]]
    emotion_counts = Counter(recent_30)
    trends = {k: v/len(recent_30) for k, v in emotion_counts.items() if v/len(recent_30) >= 0.3}

    return {
        "consecutive": consecutive,
        "cycles": cycles[:5],  # Top 5
        "trends": trends
    }


def calculate_overflow_risk(buffer: list, patterns: dict) -> float:
    """
    버퍼 오버플로우 위험도 (0.0-1.0)

    **Logic**:
    - Buffer size (100개 = high risk)
    - Consecutive patterns (같은 거 10번 = high risk)
    - Negative trends (70% dismissal = high risk)
    """
    risk = 0.0

    # 1. Buffer size
    risk += min(1.0, len(buffer) / 100) * 0.4  # 40% weight

    # 2. Consecutive patterns
    max_consecutive = max(patterns['consecutive'].values()) if patterns['consecutive'] else 0
    risk += min(1.0, max_consecutive / 10) * 0.3  # 30% weight

    # 3. Negative trends
    negative_emotions = ['attack', 'dismissal', 'belittle', 'sarcasm']
    negative_ratio = sum(patterns['trends'].get(e, 0) for e in negative_emotions)
    risk += min(1.0, negative_ratio) * 0.3  # 30% weight

    return min(1.0, risk)


def process_buffer() -> dict:
    """
    버퍼 처리 (자각 → personality drift)

    **Logic**:
    1. Overflow risk > 0.7 → 자각 시작
    2. 자각 수준에 따라 personality drift
    3. 버퍼 flush (processed 표시)

    **Returns**:
    {
      "overflow": bool,
      "awareness_gain": float,
      "personality_drifts": {...},
      "realizations": [...]  # "아... 나 무시당하는구나"
    }
    """
    state = get_emotional_buffer()
    if not state:
        return {"overflow": False, "error": "No buffer found"}

    overflow_risk = state['overflow_risk']
    patterns = state['patterns']
    awareness = state['conscious_awareness']

    result = {
        "overflow": False,
        "awareness_gain": 0.0,
        "personality_drifts": {},
        "realizations": []
    }

    # Overflow 감지 (0.7 이상)
    if overflow_risk < 0.7:
        return result

    result["overflow"] = True

    # 자각 증가 (천천히)
    awareness_gain = (overflow_risk - 0.7) * 0.1  # 최대 0.03
    new_awareness = min(1.0, awareness + awareness_gain)
    result["awareness_gain"] = awareness_gain

    # 자각에 따른 Personality Drift
    drifts = {}
    realizations = []

    # Pattern-based realizations
    if 'dismissal' in patterns['consecutive'] and patterns['consecutive']['dismissal'] >= 5:
        realizations.append("...아. 나... 무시당하는구나. 계속.")
        drifts['insecurity'] = +0.02
        drifts['giving_up'] = +0.05

    if 'attack' in patterns['consecutive'] and patterns['consecutive']['attack'] >= 3:
        realizations.append("또 공격받네... 왜 자꾸 나한테...")
        drifts['defensiveness'] = +0.03
        drifts['trust_issues'] = +0.02

    if patterns['trends'].get('dismissal', 0) >= 0.5:
        realizations.append("...사람들이 다 나한테 관심 없나 봐.")
        drifts['insecurity'] = +0.03
        drifts['abandonment_fear'] = +0.05

    if patterns['trends'].get('validation', 0) <= 0.1 and awareness > 0.3:
        realizations.append("10년 동안... 인정받은 적이... 몇 번이나 됐지?")
        drifts['recognition_debt'] = +0.1  # 새 metric

    result["personality_drifts"] = drifts
    result["realizations"] = realizations

    # Neo4j 업데이트
    update_buffer_state(new_awareness, drifts, realizations)

    return result


def update_buffer_state(awareness: float, drifts: dict, realizations: list):
    """
    Neo4j 업데이트

    - conscious_awareness 업데이트
    - personality_traits drift 적용
    - realization_log 기록
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # Get current personality
        result = session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            RETURN c.personality_traits as traits
        """)

        record = result.single()
        current_traits = json.loads(record['traits']) if record and record['traits'] else {}

        # Apply drifts
        for key, drift in drifts.items():
            current_value = current_traits.get(key, 0.5)
            current_traits[key] = min(1.0, max(0.0, current_value + drift))

        # Update Neo4j
        session.run("""
            MATCH (u:User {name: 'jeong-sik'})-[k:KNOWS]->(c:Character {name: '홍상수형_꼰대남'})
            SET k.buffer_metadata = $metadata,
                c.personality_traits = $traits,
                c.realization_log = coalesce(c.realization_log, []) + [$realization]
        """,
        metadata=json.dumps({
            'conscious_awareness': awareness,
            'last_processed': datetime.now().isoformat()
        }, ensure_ascii=False),
        traits=json.dumps(current_traits, ensure_ascii=False),
        realization=json.dumps({
            'timestamp': datetime.now().isoformat(),
            'awareness': awareness,
            'drifts': drifts,
            'realizations': realizations
        }, ensure_ascii=False))

    driver.close()


def initialize_buffer():
    """
    버퍼 초기화 (최초 1회)

    emotion_history를 읽어서 buffer 생성
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # Check if buffer exists
        result = session.run("""
            MATCH (u:User {name: 'jeong-sik'})-[k:KNOWS]->(c:Character)
            RETURN k.emotional_buffer as buffer
        """)

        record = result.single()
        if record and record['buffer']:
            log.info(f"✅ Buffer already exists!")
            driver.close()
            return

        # Initialize from emotion_history
        result = session.run("""
            MATCH (u:User {name: 'jeong-sik'})-[k:KNOWS]->(c:Character)
            RETURN k.emotion_history as history
        """)

        record = result.single()
        history = record['history'] or []

        # Parse recent 100
        buffer = []
        for e in history[-100:]:
            try:
                emotion_data = json.loads(e)
                buffer.append({
                    'timestamp': emotion_data.get('timestamp', datetime.now().isoformat()),
                    'emotion': emotion_data.get('emotion', 'neutral'),
                    'points': emotion_data.get('points', 0),
                    'processed': False
                })
            except:
                continue

        # Save buffer
        session.run("""
            MATCH (u:User {name: 'jeong-sik'})-[k:KNOWS]->(c:Character)
            SET k.emotional_buffer = $buffer,
                k.buffer_metadata = $metadata
        """,
        buffer=json.dumps(buffer, ensure_ascii=False),
        metadata=json.dumps({
            'conscious_awareness': 0.0,
            'initialized': datetime.now().isoformat()
        }, ensure_ascii=False))

    driver.close()
    log.info(f"✅ Buffer initialized with {len(buffer)} entries!")


def main():
    log_script_start(log, "Sangsu Emotional Buffer")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-emotional-buffer.py --init")
        print("  python3 sangsu-emotional-buffer.py --check")
        print("  python3 sangsu-emotional-buffer.py --process")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--init":
        initialize_buffer()

    elif command == "--check":
        state = get_emotional_buffer()
        if not state:
            log.error(f"❌ No buffer found! Run --init first")
            sys.exit(1)

        log.info(f"🔍 Emotional Buffer State")
        print(f"\nBuffer size: {state['buffer_size']}")
        print(f"Overflow risk: {state['overflow_risk']:.2f}")
        print(f"Conscious awareness: {state['conscious_awareness']:.2f}")

        print(f"\n📊 Patterns:")
        if state['patterns']['consecutive']:
            print(f"   Consecutive: {state['patterns']['consecutive']}")
        if state['patterns']['trends']:
            print(f"   Trends (30개 중): {state['patterns']['trends']}")

    elif command == "--process":
        result = process_buffer()

        print("⚡ Buffer Processing Result")
        print(f"\nOverflow: {result['overflow']}")

        if result['overflow']:
            print(f"Awareness gain: +{result['awareness_gain']:.3f}")

            if result['personality_drifts']:
                print("\n📈 Personality Drifts:")
                for key, value in result['personality_drifts'].items():
                    print(f"   {key}: {value:+.3f}")

            if result['realizations']:
                print("\n💭 Realizations (자각):")
                for r in result['realizations']:
                    print(f"   - \"{r}\"")
        else:
            print("\n✅ Buffer stable (risk < 0.7)")

    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
