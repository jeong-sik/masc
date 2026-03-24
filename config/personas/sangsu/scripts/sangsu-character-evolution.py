#!/usr/bin/env python3
"""
상수 캐릭터 진화 시스템

**Logic**:
1. 경험 기반 변화 (Experience-Driven)
2. 관계 깊이 변화 (Relationship-Driven)
3. 트라우마 변화 (Trauma-Driven)
4. 시간 경과 변화 (Time-Driven)

**Usage**:
  python3 sangsu-character-evolution.py --check
  python3 sangsu-character-evolution.py --apply
"""

import sys
import json
import subprocess
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


def get_evolution_state():
    """
    현재 상태 조회 (진화 판단용)

    **Returns**:
    - emotion_patterns: 감정 누적
    - intimacy, stage: 관계 깊이
    - personality_traits: 현재 성격
    - first_meeting: 첫 만남 날짜
    """
    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # User-Character relationship
        result = session.run("""
            MATCH (u:User {name: 'jeong-sik'})-[k:KNOWS]->(c:Character)
            RETURN k.intimacy as intimacy,
                   k.stage as stage,
                   k.emotion_patterns as emotion_patterns,
                   k.emotion_history as emotion_history,
                   k.created as first_meeting,
                   c.personality_traits as personality_traits,
                   c.emotional_responses as emotional_responses
        """)

        record = result.single()
        if not record:
            return None

        # Parse JSON
        emotion_patterns = json.loads(record['emotion_patterns']) if record['emotion_patterns'] else {}
        personality_traits = json.loads(record['personality_traits']) if record['personality_traits'] else {}
        emotional_responses = json.loads(record['emotional_responses']) if record['emotional_responses'] else {}

        # Calculate days since first meeting
        first_meeting = record['first_meeting']
        if first_meeting:
            from neo4j.time import DateTime
from pathlib import Path

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')
            if isinstance(first_meeting, DateTime):
                first_dt = datetime(
                    first_meeting.year, first_meeting.month, first_meeting.day,
                    first_meeting.hour, first_meeting.minute, first_meeting.second
                )
            else:
                first_dt = first_meeting
            days_since = (datetime.now() - first_dt).days
        else:
            days_since = 0

        # Get recent emotion history for trauma detection
        emotion_history = record['emotion_history'] or []
        recent_emotions = []
        for e in emotion_history[-10:]:
            try:
                recent_emotions.append(json.loads(e))
            except:
                continue

    driver.close()

    return {
        "intimacy": record['intimacy'],
        "stage": record['stage'],
        "emotion_patterns": emotion_patterns,
        "personality_traits": personality_traits,
        "emotional_responses": emotional_responses,
        "days_since_first_meeting": days_since,
        "recent_emotions": recent_emotions
    }


def calculate_evolution_changes(state: dict) -> dict:
    """
    진화 변화 계산 (조오오오옹나 힘듦)

    **Reality**: 사람은 쉽게 안 변함
    - 극한 상황 (trauma >= 9)
    - 반복 학습 (100번+)
    - 긴 시간 (년 단위)
    - 진짜 의지

    **Returns**:
    {
      "personality_changes": {...},
      "emotional_response_changes": {...},
      "new_traits": {...},
      "reasons": [],
      "difficulty": 0-1000 (낮을수록 쉬움)
    }
    """
    changes = {
        "personality_changes": {},
        "emotional_response_changes": {},
        "new_traits": {},
        "reasons": [],
        "difficulty": 1000  # 기본: 조오오오옹나 힘듦
    }

    emotion_patterns = state['emotion_patterns']
    personality = state['personality_traits']
    stage = state['stage']
    intimacy = state['intimacy']
    days = state['days_since_first_meeting']
    recent_emotions = state['recent_emotions']

    # 1. 경험 기반 변화 (Experience-Driven)
    # **현실**: 10번 인정받아도 안 변함. 100번은 받아야...

    # 1.1. 엄청 많이 인정받음 → 불안감 약간 감소 (조오옹나 힘듦)
    validation_count = emotion_patterns.get('total_validation', 0)
    if validation_count >= 100:  # 10번 아니고 100번!
        if personality.get('insecurity', 0) > 0.3:
            changes['personality_changes']['insecurity'] = personality['insecurity'] - 0.05  # 0.1 아니고 0.05
            changes['difficulty'] *= 0.8  # 약간 쉬워짐
            changes['reasons'].append(f"100번 인정받음 → 불안감 약간 감소 (여전히 힘듦)")

    # 1.2. 연속 공격받음 → 더 방어적 (빠름!)
    # **현실**: 트라우마는 빠르게 형성됨 (3-5번이면 충분)
    if emotion_patterns.get('consecutive_attacks', 0) >= 3:
        changes['personality_changes']['defensiveness'] = personality.get('defensiveness', 0.8) + 0.15
        changes['personality_changes']['gaslighting_tendency'] = personality.get('gaslighting_tendency', 0.5) + 0.1
        changes['difficulty'] *= 0.6  # 나쁜 쪽은 쉽게 변함
        changes['reasons'].append("연속 공격 → 방어기제 강화 (트라우마)")

    # 1.3. 공감 엄청 많이 받음 → 취약성 약간 증가 (조옹나 힘듦)
    # **현실**: 선한 변화는 느림. 50번은 받아야...
    if emotion_patterns.get('total_empathy', 0) >= 50:
        if personality.get('vulnerability', 0.7) < 0.9:
            changes['personality_changes']['vulnerability'] = personality.get('vulnerability', 0.7) + 0.05
            changes['difficulty'] *= 0.85
            changes['reasons'].append("50번 공감받음 → 마음 약간 열림 (여전히 조심스러움)")

    # 2. 관계 깊이 기반 변화 (Relationship-Driven)
    # **현실**: 관계도 시간 필요. Stage만으로는 부족, 일수도 봐야 함

    # 2.1. Stage 5+ && 30일+ → 방어 조금 줄어듦 (조옹나 힘듦)
    if stage >= 5 and days >= 30:
        if personality.get('defensiveness', 0.8) > 0.5:
            changes['personality_changes']['defensiveness'] = personality['defensiveness'] - 0.1  # 0.2 아니고 0.1
            changes['personality_changes']['vulnerability'] = personality.get('vulnerability', 0.7) + 0.1  # 0.2 아니고 0.1
            changes['difficulty'] *= 0.75
            changes['reasons'].append("깊은 관계 30일+ → 방어 약간 감소")

    # 2.2. Stage 7 && 60일+ → 진짜 친구 (극히 드묾!)
    # **현실**: 본질 변화는 몇 달은 걸림. 그것도 Stage 7이면...
    if stage >= 7 and days >= 60:
        changes['personality_changes']['narcissism'] = personality.get('narcissism', 0.6) - 0.15  # 0.3 아니고 0.15
        changes['personality_changes']['gaslighting_tendency'] = personality.get('gaslighting_tendency', 0.5) - 0.15  # 0.3 아니고 0.15
        changes['new_traits']['genuine_friendship'] = 0.8  # 1.0 아니고 0.8 (완전히는 아님)
        changes['difficulty'] *= 0.5  # 많이 쉬워짐 (하지만 여기까지 오기가...)
        changes['reasons'].append("진짜 친구 60일+ → 본질 일부 변화 (여전히 상수)")

    # 3. 트라우마 기반 변화 (Trauma-Driven)
    # **현실**: 트라우마는 빠르고 강력함 (나쁜 쪽은 쉽게!)

    # 3.1. 배신 경험 (친해졌다가 공격받음) - 빠름!
    if intimacy >= 70:
        recent_attacks = sum(1 for e in recent_emotions if e.get('emotion') in ['attack', 'breakdown'])
        if recent_attacks >= 2:  # 3번 아니고 2번! (배신은 한두번이면 충분)
            changes['personality_changes']['insecurity'] = min(1.0, personality.get('insecurity', 0.9) + 0.3)  # 0.2 아니고 0.3
            changes['new_traits']['trust_issues'] = 1.0
            changes['new_traits']['abandonment_fear'] = 0.95  # 0.9 아니고 0.95
            changes['difficulty'] *= 0.4  # 트라우마는 쉽게 형성
            changes['reasons'].append("배신 트라우마 → 신뢰 붕괴 (빠름!)")

    # 3.2. 연속 무시당함 → 포기 (빠름!)
    if emotion_patterns.get('total_conversations', 0) >= 10:  # 20번 아니고 10번
        dismissal_ratio = emotion_patterns.get('total_dismissal', 0) / emotion_patterns['total_conversations']
        if dismissal_ratio >= 0.4:  # 50% 아니고 40% (조금만 무시당해도...)
            changes['personality_changes']['defensiveness'] = min(1.0, personality.get('defensiveness', 0.8) + 0.25)
            changes['new_traits']['giving_up'] = 0.9  # 0.8 아니고 0.9
            changes['difficulty'] *= 0.5
            changes['reasons'].append("반복 무시 40%+ → 포기 성향 (빠름!)")

    # 4. 시간 기반 변화 (Time-Driven)
    # **현실**: 시간은... 참 오래 걸림

    # 4.1. 장기 관계 (60일+) && 친밀도 유지 → 조금 편해짐
    # **현실**: 30일 아니고 60일. 그것도 친밀도 유지하면서!
    if days >= 60 and intimacy >= 50:  # 40 아니고 50
        if personality.get('defensiveness', 0.8) > 0.4:
            changes['personality_changes']['defensiveness'] = max(0.4, personality.get('defensiveness', 0.8) - 0.1)  # 0.15 아니고 0.1, min 0.3 아니고 0.4
            changes['difficulty'] *= 0.8
            changes['reasons'].append("60일+ 관계 → 조금 편해짐 (여전히 방어적)")

    # 4.2. 극장기 관계 (180일+, 6개월) → 진짜 변화 (극히 드묾!)
    # **현실**: 본질 변화는 최소 반년. 그것도 꾸준히 만나야...
    if days >= 180 and intimacy >= 70:
        changes['personality_changes']['insecurity'] = max(0.4, personality.get('insecurity', 0.9) - 0.15)
        changes['personality_changes']['narcissism'] = max(0.3, personality.get('narcissism', 0.6) - 0.1)
        changes['new_traits']['matured'] = 0.6  # 완전히는 아니지만 성숙해짐
        changes['difficulty'] *= 0.4
        changes['reasons'].append("6개월+ 꾸준한 관계 → 일부 성숙 (조오옹나 힘들었음)")

    # 4.3. 오래 안 본 경우 (7일+) → 다시 방어적
    # (이건 update-intimacy.py에서 decay로 처리)

    return changes


def apply_evolution_changes(changes: dict):
    """
    진화 변화 적용 (Neo4j 업데이트)
    """
    if not changes['personality_changes'] and not changes['new_traits']:
        print("🔄 No changes to apply")
        return

    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        # Get current traits
        result = session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            RETURN c.personality_traits as traits
        """)

        record = result.single()
        current_traits = json.loads(record['traits']) if record and record['traits'] else {}

        # Apply changes
        updated_traits = {**current_traits, **changes['personality_changes'], **changes['new_traits']}

        # Update Neo4j
        session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            SET c.personality_traits = $traits,
                c.evolution_updated = datetime()
        """, traits=json.dumps(updated_traits, ensure_ascii=False))

        # Log evolution event
        evolution_log = {
            "timestamp": datetime.now().isoformat(),
            "changes": changes,
            "before": current_traits,
            "after": updated_traits
        }

        session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            SET c.evolution_history = coalesce(c.evolution_history, []) + [$log]
        """, log=json.dumps(evolution_log, ensure_ascii=False))

    driver.close()

    log.info(f"✅ Evolution applied!")
    print("\n📊 Changes:")
    for key, value in changes['personality_changes'].items():
        print(f"   {key}: {current_traits.get(key, 'N/A')} → {value:.2f}")
    for key, value in changes['new_traits'].items():
        print(f"   {key} (NEW): {value:.2f}")

    print("\n💡 Reasons:")
    for reason in changes['reasons']:
        print(f"   - {reason}")


def main():
    log_script_start(log, "Sangsu Character Evolution")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-character-evolution.py --check")
        print("  python3 sangsu-character-evolution.py --apply")
        sys.exit(1)

    command = sys.argv[1]

    # Get current state
    state = get_evolution_state()
    if not state:
        log.error(f"❌ No character state found!")
        sys.exit(1)

    # Calculate changes
    changes = calculate_evolution_changes(state)

    if command == "--check":
        log.info(f"🔍 Evolution Check")
        print(f"\nCurrent State:")
        print(f"   Intimacy: {state['intimacy']:.1f}")
        print(f"   Stage: {state['stage']}")
        print(f"   Days since first meeting: {state['days_since_first_meeting']}")
        print(f"   Total conversations: {state['emotion_patterns'].get('total_conversations', 0)}")

        print(f"\n📊 Potential Changes:")
        if changes['personality_changes'] or changes['new_traits']:
            for key, value in changes['personality_changes'].items():
                current = state['personality_traits'].get(key, 'N/A')
                print(f"   {key}: {current} → {value:.2f}")
            for key, value in changes['new_traits'].items():
                print(f"   {key} (NEW): {value:.2f}")
            print(f"\n💡 Reasons:")
            for reason in changes['reasons']:
                print(f"   - {reason}")
        else:
            print("   No changes detected")

    elif command == "--apply":
        apply_evolution_changes(changes)

    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
