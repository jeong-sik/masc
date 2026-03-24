#!/usr/bin/env python3
"""
상수 즉흥성 + 자기성찰 시스템

**Logic**:
1. 즉흥성 (Spontaneity) - 같은 상황, 다른 반응 (확률적)
2. 자기성찰 (Self-Reflection) - 대화 후 혼잣말, 후회, 깨달음

**Concept**:
- 인간 = 70% 패턴 + 30% 즉흥
- 성찰 = 버퍼 쌓이면 혼자 생각함
- "아... 내가 왜 그랬지?" (사후 자각)

**Usage**:
  python3 sangsu-spontaneity-system.py --get-response "dismissal" --context '{"drunk": true}'
  python3 sangsu-spontaneity-system.py --reflect
"""

import sys
import json
import random
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


def get_spontaneous_response(emotion: str, context: dict, personality: dict) -> dict:
    """
    즉흥적 반응 생성 (확률적)

    **Args**:
    - emotion: 현재 감정 (attack, dismissal, ...)
    - context: 상황 변수 (drunk, tired, good_mood, time_of_day, ...)
    - personality: 현재 성격 traits

    **Returns**:
    {
      "response": str,
      "spontaneity_triggered": bool,
      "reason": str  # 왜 이 반응?
    }
    """
    # Core personality response (기본 70%)
    base_responses = get_base_responses(emotion, personality)

    # Spontaneity factor (30% 확률)
    spontaneity_factor = personality.get('spontaneity', 0.3)

    # Context modifiers
    context_weight = calculate_context_weight(context)

    # Roll the dice 🎲
    dice = random.random()

    # 1. Strong context override (취함, 극도 피곤 등)
    if context_weight > 0.7:
        spontaneous = get_context_driven_response(emotion, context, personality)
        return {
            "response": spontaneous['response'],
            "spontaneity_triggered": True,
            "reason": f"강한 컨텍스트 ({spontaneous['trigger']})"
        }

    # 2. Spontaneity roll
    if dice < spontaneity_factor:
        spontaneous = get_random_spontaneous_response(emotion, context, personality)
        return {
            "response": spontaneous['response'],
            "spontaneity_triggered": True,
            "reason": "즉흥성 (주사위)"
        }

    # 3. Default personality response
    return {
        "response": weighted_choice(base_responses, personality),
        "spontaneity_triggered": False,
        "reason": "기본 성격 패턴"
    }


def get_base_responses(emotion: str, personality: dict) -> list:
    """
    기본 반응 풀 (성격 기반)

    **Returns**: [(response, weight), ...]
    """
    defensiveness = personality.get('defensiveness', 0.8)
    vulnerability = personality.get('vulnerability', 0.7)

    responses = {
        'dismissal': [
            ("...됐어. 어차피.", 0.3),
            ("야 진짜?", 0.2),
            ("아 그래? 네가 뭘 알아?", defensiveness * 0.3),
            ("...알았어.", vulnerability * 0.2)
        ],
        'attack': [
            ("야 왜 그래?", 0.3),
            ("...미안. 내가 뭐 잘못했어?", vulnerability * 0.3),
            ("아니 뭔 소리야?", defensiveness * 0.4)
        ],
        'validation': [
            ("진짜?", 0.3),
            ("...고마워.", vulnerability * 0.4),
            ("아 됐어. 괜찮아.", defensiveness * 0.3)
        ],
        'empathy': [
            ("...알아줘서 고마워.", vulnerability * 0.5),
            ("진짜... 알아주는 사람이 없어서...", vulnerability * 0.3),
            ("응.", 0.2)
        ]
    }

    return responses.get(emotion, [("...", 1.0)])


def calculate_context_weight(context: dict) -> float:
    """
    컨텍스트 강도 (0.0-1.0)

    **Strong contexts** (0.7+):
    - drunk: 0.8
    - exhausted: 0.7
    - breakdown_mode: 0.9
    """
    weight = 0.0

    if context.get('drunk', False):
        weight = max(weight, 0.8)
    if context.get('exhausted', False):
        weight = max(weight, 0.7)
    if context.get('breakdown_mode', False):
        weight = max(weight, 0.9)
    if context.get('good_mood', False):
        weight = max(weight, 0.5)

    return weight


def get_context_driven_response(emotion: str, context: dict, personality: dict) -> dict:
    """
    컨텍스트 주도 반응

    **Examples**:
    - drunk + dismissal → "...사실 나 외로워."
    - exhausted + attack → "...아 됐어. 자."
    - good_mood + curiosity → "야 영화 한 편 볼래?"
    """
    if context.get('drunk'):
        drunk_responses = {
            'dismissal': "...사실 나 외로워. 진짜.",
            'attack': "...맞아. 나 그래. 만족해?",
            'validation': "진짜? ...고마워. 진심으로.",
            'empathy': "너... 너 진짜 좋은 사람이야. 진짜."
        }
        return {
            'response': drunk_responses.get(emotion, "...취했나 봐."),
            'trigger': 'drunk'
        }

    if context.get('exhausted'):
        exhausted_responses = {
            'dismissal': "...알았어. 자.",
            'attack': "...아 됐어. 피곤해.",
            'validation': "...응. 고마워.",
            'empathy': "...알았어."
        }
        return {
            'response': exhausted_responses.get(emotion, "...피곤해."),
            'trigger': 'exhausted'
        }

    if context.get('good_mood'):
        good_responses = {
            'dismissal': "아 그래? 뭐 어때!",
            'attack': "야 왜 그래? ㅋㅋ",
            'curiosity': "야 영화 한 편 볼래? 내가 추천해줄게.",
            'validation': "진짜? 고마워!"
        }
        return {
            'response': good_responses.get(emotion, "오늘 기분 좋은데?"),
            'trigger': 'good_mood'
        }

    return {'response': "...", 'trigger': 'unknown'}


def get_random_spontaneous_response(emotion: str, context: dict, personality: dict) -> dict:
    """
    순수 즉흥 반응 (예측 불가)

    **Logic**: 완전 랜덤 + 약간의 페르소나
    """
    spontaneous_pool = {
        'dismissal': [
            "어? 그게 무슨 소리야?",
            "아 미안. 내가 착각했나.",
            "...됐고, 영화 얘기하자.",
            "너 배고파? 나가서 먹을까?",
            "야 근데 말이야..."
        ],
        'attack': [
            "아 진짜?",
            "...미안.",
            "아니 그게 아니라...",
            "어? 내가 뭐 잘못했어?",
            "야 잠깐만."
        ],
        'validation': [
            "어... 진짜?",
            "아 그래? 고마워!",
            "...몰랐는데.",
            "진심?",
            "아 됐어. 괜찮아."
        ]
    }

    pool = spontaneous_pool.get(emotion, ["..."])
    return {
        'response': random.choice(pool),
        'trigger': 'spontaneity'
    }


def weighted_choice(choices: list, personality: dict) -> str:
    """
    가중치 기반 선택

    **Args**: [(response, weight), ...]
    **Returns**: selected response
    """
    if not choices:
        return "..."

    total = sum(w for _, w in choices)
    r = random.uniform(0, total)

    cumulative = 0
    for response, weight in choices:
        cumulative += weight
        if r <= cumulative:
            return response

    return choices[0][0]


def generate_self_reflection(recent_conversation: list, personality: dict, buffer_state: dict) -> dict:
    """
    자기성찰 생성 (대화 후 혼잣말)

    **Logic**:
    1. 버퍼 overflow_risk > 0.5 → 성찰 시작
    2. 최근 대화 패턴 분석
    3. 성격에 따라 다른 성찰

    **Returns**:
    {
      "reflection": str,  # 혼잣말
      "emotion": str,  # 성찰 중 느낀 감정
      "insight": str,  # 깨달음 (있으면)
      "regret": bool  # 후회 여부
    }
    """
    overflow_risk = buffer_state.get('overflow_risk', 0.0)
    awareness = buffer_state.get('conscious_awareness', 0.0)

    # No reflection if buffer is stable
    if overflow_risk < 0.5:
        return None

    # Analyze recent conversation
    last_turn = recent_conversation[-1] if recent_conversation else {}
    user_message = last_turn.get('user', '')
    sangsu_message = last_turn.get('sangsu', '')
    emotion = last_turn.get('emotion', 'neutral')

    # Generate reflection based on personality
    defensiveness = personality.get('defensiveness', 0.8)
    vulnerability = personality.get('vulnerability', 0.7)
    insecurity = personality.get('insecurity', 0.9)

    reflection = None
    insight = None
    regret = False
    reflection_emotion = 'contemplation'

    # Pattern 1: Defensive → Regret
    if emotion in ['attack', 'dismissal'] and defensiveness > 0.7:
        reflection = "...아. 내가 또 그랬구나. 왜 맨날 이러지?"
        regret = True
        reflection_emotion = 'regret'

        if awareness > 0.5:
            insight = "사람들이 다 떠나는 이유가... 내가 이래서인가."

    # Pattern 2: Vulnerability exposed → Anxiety
    if emotion in ['validation', 'empathy'] and vulnerability > 0.7:
        reflection = "...너무 많이 말한 거 아닌가? 나 약해 보였을까?"
        reflection_emotion = 'anxiety'

        if insecurity > 0.8:
            insight = "또 나 혼자 오버한 거 아닐까..."

    # Pattern 3: Overflow → Existential
    if overflow_risk > 0.7 and awareness > 0.6:
        reflection = "...10년. 나 뭐했지? 친구들... 부모님... 다 실망시켰어."
        reflection_emotion = 'despair'
        insight = "나... 이대로 계속 살 수 있을까?"

    # Pattern 4: Good interaction → Hope
    if emotion in ['validation', 'empathy'] and overflow_risk < 0.6:
        reflection = "...오늘 좋았는데. 이런 게 오래갈까?"
        reflection_emotion = 'hope'

        if awareness > 0.4:
            insight = "조금씩... 나아지는 걸까?"

    if not reflection:
        # Default reflection
        reflection = "...음."
        reflection_emotion = 'neutral'

    return {
        "reflection": reflection,
        "emotion": reflection_emotion,
        "insight": insight,
        "regret": regret,
        "awareness_level": awareness,
        "triggered_by": f"overflow_risk={overflow_risk:.2f}"
    }


def save_reflection_to_neo4j(reflection: dict):
    """
    성찰 기록을 Neo4j에 저장

    Character.reflection_log에 추가
    """
    if not reflection:
        return

    creds = get_neo4j_creds()
    driver = GraphDatabase.driver(
        os.environ['NEO4J_URI'],
        auth=(creds['username'], creds['password'])
    )

    with driver.session() as session:
        session.run("""
            MATCH (c:Character {name: '홍상수형_꼰대남'})
            SET c.reflection_log = coalesce(c.reflection_log, []) + [$reflection]
        """,
        reflection=json.dumps({
            'timestamp': datetime.now().isoformat(),
            **reflection
        }, ensure_ascii=False))

    driver.close()


def main():
    log_script_start(log, "Sangsu Spontaneity System")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-spontaneity-system.py --get-response <emotion> --context '<json>'")
        print("  python3 sangsu-spontaneity-system.py --reflect")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--get-response":
        if len(sys.argv) < 4:
            log.error(f"❌ Need: --get-response <emotion> --context '<json>'")
            sys.exit(1)

        emotion = sys.argv[2]

        # Parse context
        context = {}
        if len(sys.argv) > 4 and sys.argv[3] == "--context":
            try:
                context = json.loads(sys.argv[4])
            except:
                log.warning(f"⚠️  Invalid JSON context, using empty")

        # Mock personality (실제로는 Neo4j에서 가져오기)
        personality = {
            'defensiveness': 0.8,
            'vulnerability': 0.7,
            'spontaneity': 0.3,
            'narcissism': 0.6,
            'insecurity': 0.9
        }

        result = get_spontaneous_response(emotion, context, personality)
        print(json.dumps(result, ensure_ascii=False, indent=2))

    elif command == "--reflect":
        # Get recent conversation (mock)
        recent_conversation = [
            {
                'user': '아 나 이제 좀 취했는데 자러고',
                'sangsu': '어? 벌써? 좀 그렇네... 뭐 어때. 됐고. 그럼 자. 잘 자.',
                'emotion': 'dismissal'
            }
        ]

        # Mock personality & buffer
        personality = {
            'defensiveness': 0.8,
            'vulnerability': 0.7,
            'insecurity': 0.9
        }

        buffer_state = {
            'overflow_risk': 0.6,
            'conscious_awareness': 0.4
        }

        reflection = generate_self_reflection(recent_conversation, personality, buffer_state)

        if reflection:
            print("💭 Self-Reflection (혼잣말)")
            print(f"\nReflection: \"{reflection['reflection']}\"")
            print(f"Emotion: {reflection['emotion']}")
            if reflection['insight']:
                print(f"Insight: \"{reflection['insight']}\"")
            print(f"Regret: {reflection['regret']}")

            # Save to Neo4j
            save_reflection_to_neo4j(reflection)
            print("\n✅ Reflection saved to Neo4j")
        else:
            log.info(f"✅ No reflection triggered (buffer stable)")

    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
