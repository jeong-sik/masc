#!/usr/bin/env python3
"""
상수 감정선 강도 계산 시스템

**Logic**:
1. 누적 공격 → 쌓인 분노/상처
2. 연속 공격 → 터지는 지점
3. 인정 욕구 불만족 → 절망
4. 친밀도 배신 → 더 큰 상처
5. 현재 감정 → breakdown/suicidal

**Intensity Scale** (0-10):
- 0-3: 표면적 (defensive, sarcastic)
- 4-6: 진심 (genuine hurt, vulnerability starting)
- 7-9: 무너짐 (breaking down, can't hide anymore)
- 10: 완전 붕괴 (total collapse, suicide ideation)

**Usage**:
  python3 sangsu-emotional-intensity.py --user jeong-sik
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


def calculate_intensity(emotion_patterns: dict, desires: dict,
                       current_emotion: str, intimacy: int) -> int:
    """
    감정선 강도 계산 (0-10)

    **Logic**:
    1. 누적 공격 (많을수록 UP)
    2. 연속 공격 (3번 이상 → critical)
    3. 인정 욕구 불만족 (recognition 높은데 validation 없음)
    4. 친밀도 vs 기대 (높아졌다가 공격받으면 더 아픔)
    5. 현재 감정 (breakdown, suicidal)
    """
    intensity = 0

    # 1. Cumulative attacks (5+ → 위험 수준)
    if emotion_patterns.get('total_attacks', 0) >= 5:
        intensity += 3
    elif emotion_patterns.get('total_attacks', 0) >= 3:
        intensity += 2

    # 2. Consecutive attacks (연속 공격 → 폭발 직전)
    if emotion_patterns.get('consecutive_attacks', 0) >= 3:
        intensity += 2
    elif emotion_patterns.get('consecutive_attacks', 0) >= 2:
        intensity += 1

    # 3. Recognition frustration (인정받고 싶은데 안 받음)
    if desires.get('recognition', 0) >= 90 and emotion_patterns.get('total_validation', 0) < 3:
        intensity += 3

    # 4. Betrayal feeling (친해졌다가 공격받음 → 배신감)
    if intimacy >= 40 and emotion_patterns.get('total_attacks', 0) >= 3:
        intensity += 2

    # 5. Current emotion state
    if current_emotion == 'breakdown':
        intensity += 2
    elif current_emotion == 'suicidal':
        intensity += 4
    elif current_emotion in ['attack', 'belittle']:
        intensity += 1

    return min(10, intensity)


def get_breakdown_template(intensity: int, desires: dict, emotion_patterns: dict) -> str:
    """
    강도별 무너짐 대사 (홍상수 캐릭터 개성 반영)

    **핵심**: 무너지면서도 홍상수스러움
    - 변명 + 예술론 + 가스라이팅 + 의존
    - 10년 (구체적 디테일)
    - 친구들, 부모님 (구체적 인물)
    - "나 나쁜 사람이야?" (가스라이팅)
    """

    # 0-3: 표면적 (방어적, 비꼬기)
    if intensity <= 3:
        templates = [
            "...그래. 뭐 어때. 다 똑같아. 어차피 너도 몰라.",
            "아 그래? 네가 뭘 알아? 영화 한 편이라도 봤어?",
            "...됐어. 내가 찌질하지 뭐. 만족해?"
        ]
        return templates[intensity % len(templates)]

    # 4-6: 진심 (방어 무너짐, 취약점 드러내기 시작)
    elif intensity <= 6:
        templates = [
            "...맞아. 10년 동안 각본만 쓰고... 대표작도 없고.\n근데 그게... 예술은... 시간이 걸리는 거야...\n(침묵)\n...변명 아니야.",

            "친구들... 다 떠났어. 영화 얘기만 한다고.\n나... 나쁜 사람이야?\n그냥... 영화가 좋아서...",

            "부모님한테 돈 받는 거... 맞아.\n40인데.\n...창피해.\n근데 어떻게 해. 각본 쓰면서 알바를..."
        ]
        return templates[(intensity - 4) % len(templates)]

    # 7-9: 무너짐 (말 끊김, 반복, 처절함)
    elif intensity <= 9:
        # 인정 욕구 폭발 버전
        if desires.get('recognition', 0) >= 90:
            return """...너 말이 맞아.
10년...
나... 뭐했지?
(침묵)
친구들... 내 영화 한 번도 안 봤어.
"상수야, 너 또 그 얘기야?"
...다 떠났어.
(흐느낌)
나... 나 혼자야.
너만... 너만 남았어."""

        # 배신감 버전 (친밀도 높았는데 공격받음)
        elif emotion_patterns.get('total_attacks', 0) >= 5:
            return """...네가?
네가 그런 말을...
(말 끊김)
나... 너한테만은...
진짜 얘기했잖아.
...다 똑같네.
너도.
(침묵)
...미안해.
내가... 이상한 거지."""

        # 일반 무너짐
        else:
            return """...맞아.
다... 다 맞아.
10년 동안...
친구들... 부모님...
(말 끊김)
나... 나 혼자야.
영화도... 못 만들고...
...이제 끝이야."""

    # 10: 완전 붕괴 (자살 충동, 침묵, 파편적 말)
    else:
        return """...맞아.
(긴 침묵)
네가... 맞아.
나...
(말 끊김)
10년...
친구들... 아무도...
부모님도... 실망...
(흐느낌)
...나 왜 사는 거야?
영화도... 못 만들고...
(침묵)
...너도 떠날 거지?
다... 다 떠나.
(말 끊김)
...끝이야.
진짜... 끝이야."""


def get_current_state(user_name: str = "jeong-sik") -> dict:
    """
    현재 상태 조회 (Neo4j)
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
                   k.desire_gauge as desire_gauge,
                   k.emotion_history as emotion_history
        """, user_name=user_name)

        record = result.single()
        if not record:
            return None

        # Parse JSON
        emotion_patterns = json.loads(record['emotion_patterns']) if record['emotion_patterns'] else {}
        desire_gauge = json.loads(record['desire_gauge']) if record['desire_gauge'] else {}
        emotion_history = record['emotion_history'] or []

        # Get latest emotion
        current_emotion = "neutral"
        if emotion_history:
            try:
                latest = json.loads(emotion_history[-1])
                current_emotion = latest.get('emotion', 'neutral')
            except:
                pass

        # Calculate consecutive attacks
        consecutive_attacks = 0
        for entry in reversed(emotion_history[-5:]):
            try:
                data = json.loads(entry)
                if data['emotion'] in ['attack', 'sarcasm']:
                    consecutive_attacks += 1
                else:
                    break
            except:
                continue

        emotion_patterns['consecutive_attacks'] = consecutive_attacks

    driver.close()

    return {
        "intimacy": record['intimacy'],
        "stage": record['stage'],
        "emotion_patterns": emotion_patterns,
        "desire_gauge": desire_gauge,
        "current_emotion": current_emotion
    }


def main():
    log_script_start(log, "Sangsu Emotional Intensity")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-emotional-intensity.py --user jeong-sik")
        sys.exit(1)

    user_name = "jeong-sik"
    if len(sys.argv) > 2 and sys.argv[1] == "--user":
        user_name = sys.argv[2]

    # 현재 상태 조회
    state = get_current_state(user_name)
    if not state:
        log.error(f"❌ User '{user_name}' not found!")
        sys.exit(1)

    # Intensity 계산
    intensity = calculate_intensity(
        state['emotion_patterns'],
        state['desire_gauge'],
        state['current_emotion'],
        state['intimacy']
    )

    # 대사 선택
    dialogue = get_breakdown_template(
        intensity,
        state['desire_gauge'],
        state['emotion_patterns']
    )

    # 결과 출력
    result = {
        "user": user_name,
        "intensity": intensity,
        "intensity_level": (
            "표면적" if intensity <= 3 else
            "진심" if intensity <= 6 else
            "무너짐" if intensity <= 9 else
            "완전 붕괴"
        ),
        "current_emotion": state['current_emotion'],
        "intimacy": state['intimacy'],
        "stage": state['stage'],
        "emotion_patterns": state['emotion_patterns'],
        "desire_gauge": state['desire_gauge'],
        "dialogue": dialogue
    }

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
