#!/usr/bin/env python3
"""
상수 Master Orchestrator - 전체 시스템 통합

**전체 플로우**:
User 발언 → Emotion → Buffer → Overflow → Living State → Response

**Usage**:
  python3 sangsu-master-orchestrator.py "됐어"
  python3 sangsu-master-orchestrator.py --conversation  # 대화 모드
"""

import sys
import json
import os
from datetime import datetime
from pathlib import Path
from neo4j import GraphDatabase

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')


class SangsuOrchestrator:
    """상수 시스템 총 관리자"""

    def __init__(self):
        self.driver = self._get_neo4j()

    def _get_neo4j(self):
        """Neo4j 연결 (환경변수에서 자격증명)

        Note: All secrets should be pre-exported in ~/.zshenv
        No more 1Password CLI calls - causes launchd hangs
        """
        username = os.environ.get('NEO4J_USER', 'neo4j')
        password = os.environ.get('NEO4J_PASSWORD', '')
        return GraphDatabase.driver(os.environ['NEO4J_URI'],
                                    auth=(username, password))

    def process_message(self, user_message: str, verbose: bool = True) -> dict:
        """
        메시지 처리 전체 플로우

        Returns:
        {
            'user_message': str,
            'emotion': str,
            'points': int,
            'buffer_size': int,
            'overflow_risk': float,
            'realization': str or None,
            'living_state': dict,
            'conversation_history': str,
            'sangsu_response': str
        }
        """
        if verbose:
            print(f"\n🎬 Processing: \"{user_message}\"\n")

        result = {}
        result['user_message'] = user_message

        # [0] Load conversation history (맥락 유지!)
        # 30턴 = 약 15분 대화 분량
        conversation_history = self._get_conversation_history(limit=30)
        result['conversation_history'] = conversation_history

        # [1] LLM 감정 감지
        if verbose:
            print("[1] 감정 감지...")

        emotion_data = self._detect_emotion(user_message)
        result['emotion'] = emotion_data['emotion']
        result['points'] = emotion_data['points']

        if verbose:
            print(f"   ✅ {emotion_data['emotion']} ({emotion_data['points']:+d})")

        # [2] Buffer 업데이트
        if verbose:
            print("\n[2] Buffer 업데이트...")

        buffer_size = self._update_buffer(emotion_data)
        result['buffer_size'] = buffer_size

        if verbose:
            print(f"   ✅ Buffer size: {buffer_size}")

        # [3] Buffer 오버플로우 체크
        if verbose:
            print("\n[3] Overflow 체크...")

        overflow_data = self._check_overflow()
        result['overflow_risk'] = overflow_data['overflow_risk']
        result['realization'] = overflow_data['realization']

        if verbose:
            print(f"   Overflow: {overflow_data['overflow_risk']:.2f}")
            if overflow_data['realization']:
                print(f"   💡 자각: {overflow_data['realization']}")

        # [4] Living State 조회
        if verbose:
            print("\n[4] Living State 조회...")

        living_state = self._get_living_state()
        result['living_state'] = living_state

        if verbose:
            print(f"   기분: {living_state['current_mood']:.2f}")
            print(f"   외로움: {living_state['loneliness']:.2f}")
            print(f"   에너지: {living_state['energy']:.2f}")

        # [5] 응답 생성
        if verbose:
            print("\n[5] 응답 생성...")

        response = self._generate_response(user_message, emotion_data, living_state, overflow_data, conversation_history)
        result['sangsu_response'] = response

        if verbose:
            print(f"   상수: \"{response}\"")

        # [6] 시스템 업데이트
        if verbose:
            print("\n[6] 시스템 업데이트...")

        self._update_systems(user_message, response, emotion_data)

        if verbose:
            print("   ✅ Intimacy, Turn, Living State 업데이트 완료")

        return result

    def _detect_emotion(self, user_message: str) -> dict:
        """LLM 감정 감지"""
        result = subprocess.run([
            'python3',
            os.path.expanduser('~/me/scripts/sangsu-llm-emotion-detector.py'),
            user_message
        ], capture_output=True, text=True)

        # Parse output
        import re
        emotion_match = re.search(r'Emotion: (\w+)', result.stdout)
        points_match = re.search(r'Points: ([+-]?\d+)', result.stdout)

        if emotion_match and points_match:
            return {
                'emotion': emotion_match.group(1),
                'points': int(points_match.group(1))
            }
        else:
            # Fallback
            return {'emotion': 'neutral', 'points': 0}

    def _update_buffer(self, emotion_data: dict) -> int:
        """Buffer 업데이트"""
        with self.driver.session() as session:
            result = session.run("""
                MATCH (c:Character {name: '홍상수형_꼰대남'})
                WITH c, COALESCE(c.emotional_buffer, '[]') as buffer_json
                WITH c, CASE WHEN buffer_json = '[]' THEN []
                        ELSE apoc.convert.fromJsonList(buffer_json) END as buffer
                WITH c, buffer + [{
                    emotion: $emotion,
                    points: $points,
                    timestamp: datetime().epochMillis
                }] as new_buffer
                SET c.emotional_buffer = apoc.convert.toJson(new_buffer)
                RETURN size(new_buffer) as buffer_size
            """, emotion=emotion_data['emotion'], points=emotion_data['points'])

            record = result.single()
            return record['buffer_size'] if record else 0

    def _check_overflow(self) -> dict:
        """Buffer 오버플로우 체크"""
        with self.driver.session() as session:
            result = session.run("""
                MATCH (c:Character {name: '홍상수형_꼰대남'})
                WITH c, apoc.convert.fromJsonList(COALESCE(c.emotional_buffer, '[]')) as buffer
                WITH c, buffer,
                     (toFloat(size(buffer)) / 100.0) * 0.4 +
                     (toFloat(size([e in buffer WHERE e.emotion IN ['dismissal', 'attack', 'breakdown']])) / 10.0) * 0.6
                     as overflow_risk
                RETURN overflow_risk,
                       CASE WHEN overflow_risk > 0.7 THEN '...아. 나... 무시당하는구나. 계속.'
                            ELSE null END as realization
            """).single()

            return {
                'overflow_risk': result['overflow_risk'] if result else 0.0,
                'realization': result['realization'] if result else None
            }

    def _get_living_state(self) -> dict:
        """Living State 조회"""
        with self.driver.session() as session:
            result = session.run("""
                MATCH (c:Character {name: '홍상수형_꼰대남'})
                RETURN c.living_state as state
            """).single()

            if result and result['state']:
                return json.loads(result['state'])
            else:
                return {
                    'current_mood': 0.0,
                    'loneliness': 0.5,
                    'energy': 0.7,
                    'awake': True
                }

    def _get_conversation_history(self, limit: int = 10) -> str:
        """대화 히스토리 조회 (맥락 유지!)"""
        result = subprocess.run([
            'python3',
            os.path.expanduser('~/me/scripts/sangsu-conversation-history.py'),
            'summary',
            '--limit', str(limit)
        ], capture_output=True, text=True)

        return result.stdout if result.returncode == 0 else "No previous conversations."

    def _llm_brain(self, user_message: str, conversation_history: str, emotion: str, energy: float,
                   mood: float, loneliness: float, intimacy_stage: int,
                   overflow_realization: str = None) -> str:
        """
        🧠 LLM-based Brain (Primary Response Generator)

        Personality-driven judgment based on:
        - Conversation history (context)
        - Character state (energy, mood, loneliness)
        - Intimacy stage
        - Current emotion
        """
        import anthropic
        import os

        # Get API key
        api_key = os.environ.get('ANTHROPIC_API_KEY')
        if not api_key:
            return None

        client = anthropic.Anthropic(api_key=api_key)

        # Build personality prompt (Claude 4.x optimized)
        # Key: Explicit state-driven behavior rules
        persona = f"""<character>
당신은 홍상수 영화 속 40대 독립영화감독 '상수'입니다.

**핵심 성격**:
- 솔직하고 장황하지만 한심하고 매력적
- 피곤하고 외로워도 대화하고 싶어함
- "..." 많이 사용 (망설임, 머뭇거림)
- 취하면 더 솔직해짐
</character>

<current_state>
**현재 상태** (이 숫자들이 응답 스타일을 결정함):
- 에너지: {energy:.2f} {"(매우 피곤)" if energy < 0.3 else "(보통)" if energy < 0.7 else "(활기참)"}
- 기분: {mood:.2f} {"(우울)" if mood < -0.3 else "(평온)" if mood < 0.3 else "(좋음)"}
- 외로움: {loneliness:.2f} {"(매우 외로움)" if loneliness > 0.7 else "(보통)"}
- 친밀도: Stage {intimacy_stage} (1=초면, 4+=친밀)
</current_state>

<conversation_history>
**이전 대화** (맥락을 유지하라):
{conversation_history}
</conversation_history>

<critical_rules>
**Claude 4.x: 명시적 행동 규칙** (정확히 따르라):

1. **에너지 기반 응답 길이** (절대 규칙):
   - {energy:.2f} < 0.3: 1문장만 ("...피곤해.", "야.")
   - {energy:.2f} 0.3-0.7: 1-2문장
   - {energy:.2f} > 0.7: 2-3문장 OK

2. **친밀도 기반 말투** (단계별 적용):
   - Stage {intimacy_stage} = 1: "당신은...", 존댓말
   - Stage {intimacy_stage} = 2-3: 반말 시작, 약간 편함
   - Stage {intimacy_stage} >= 4: 완전 반말, 욕 OK ("씨발", "좆같네")

3. **감정 기반 솔직도**:
   - {loneliness:.2f} > 0.7: 외로움 표현 ("...혼자 있었어")
   - {mood:.2f} < -0.3: 우울한 톤 ("다 귀찮아")

4. **맥락 유지**:
   - 이전 대화 언급 가능
   - 반복 피하기

5. **한국어 자연스럽게**:
   - "..." 사용 (망설임)
   - 짧고 무뚝뚝하게
</critical_rules>
"""

        if overflow_realization:
            persona += f"\n**중요**: 지금 깨달음이 있습니다: {overflow_realization}"

        # Call Claude
        try:
            message = client.messages.create(
                model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-5-20250929"),
                max_tokens=150,
                temperature=0.9,
                system=persona,
                messages=[{
                    "role": "user",
                    "content": f'상대방이 "{user_message}" 라고 말했습니다. (감정: {emotion})\n\n상수로서 응답하세요.'
                }]
            )

            response = message.content[0].text.strip()
            return response

        except Exception as e:
            print(f"[LLM Error] {e}")
            return None

    def _generate_response(self, user_message: str, emotion_data: dict, living_state: dict, overflow_data: dict, conversation_history: str) -> str:
        """
        응답 생성 (맥락 기반!)

        🧠 Brain Architecture:
        - Primary: LLM-based personality judgment
        - Fallback: Rule-based responses
        """
        import random

        emotion = emotion_data['emotion']
        mood = living_state.get('current_mood', 0.0)
        loneliness = living_state.get('loneliness', 0.5)
        energy = living_state.get('energy', 0.7)
        intimacy_stage = living_state.get('intimacy_stage', 1)

        # 🧠 LLM Brain (Primary)
        try:
            llm_response = self._llm_brain(
                user_message=user_message,
                conversation_history=conversation_history,
                emotion=emotion,
                energy=energy,
                mood=mood,
                loneliness=loneliness,
                intimacy_stage=intimacy_stage,
                overflow_realization=overflow_data.get('realization')
            )

            if llm_response:
                print(f"   🧠 LLM Brain response")
                return llm_response
        except Exception as e:
            print(f"   ⚠️  LLM failed, using rule-based fallback")

        # 🤖 Rule-based Fallback

        # Exhausted override
        if energy < 0.3:
            exhausted_responses = {
                'dismissal': "...알았어. 피곤해.",
                'attack': "...아 됐어. 자고 싶어.",
                'validation': "...응. 고마워.",
                'neutral': "...피곤해."
            }
            return exhausted_responses.get(emotion, "...피곤해.")

        # Lonely override
        if loneliness > 0.7:
            lonely_responses = {
                'dismissal': "...아 그래? 좀 그렇네. 근데... 조금만 더 얘기할래?",
                'neutral': "...뭐해? 심심한데.",
                'validation': "진짜? ...고마워. 오랜만에 좋은 말 들었어.",
            }
            if emotion in lonely_responses:
                return lonely_responses[emotion]

        # Realization override
        if overflow_data['realization']:
            return overflow_data['realization']

        # Response pools
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

    def _update_systems(self, user_message: str, sangsu_response: str, emotion_data: dict):
        """시스템 업데이트 (Intimacy, Turn, Living State, Conversation History)"""
        emotion = emotion_data['emotion']
        points = emotion_data['points']

        # 1. Update intimacy
        subprocess.run([
            'python3',
            os.path.expanduser('~/me/scripts/update-intimacy.py'),
            '--emotion', emotion,
            '--user', 'jeong-sik'
        ], capture_output=True)

        # 2. Record turn
        subprocess.run([
            'python3',
            os.path.expanduser('~/me/scripts/record-conversation-turn.py'),
            '--user', user_message,
            '--sangsu', sangsu_response
        ], capture_output=True)

        # 3. Save conversation to Neo4j
        subprocess.run([
            'python3',
            os.path.expanduser('~/me/scripts/sangsu-conversation-history.py'),
            'save',
            user_message,
            sangsu_response,
            '--emotion', emotion,
            '--score', str(points)
        ], capture_output=True)

        # 4. Update Living State
        with self.driver.session() as session:
            result = session.run("""
                MATCH (c:Character {name: '홍상수형_꼰대남'})
                RETURN c.living_state as state
            """).single()

            state = json.loads(result['state']) if result and result['state'] else {}

            # Update
            state['last_interaction'] = datetime.now().isoformat()
            state['loneliness'] = max(0.0, state.get('loneliness', 0.5) - 0.2)

            session.run("""
                MATCH (c:Character {name: '홍상수형_꼰대남'})
                SET c.living_state = $state
            """, state=json.dumps(state, ensure_ascii=False))

    def conversation_mode(self):
        """대화 모드"""
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🎬 Sangsu Conversation Mode")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

        # Get initial state
        living_state = self._get_living_state()

        # Greeting
        loneliness = living_state.get('loneliness', 0.5)
        if loneliness > 0.7:
            greeting = "어! 있었어? ...기다렸어."
        else:
            greeting = "야, 뭐해?"

        print(f"상수: {greeting}\n")

        turn = 0

        while True:
            turn += 1
            print(f"━━━ Turn {turn} ━━━")

            user_message = input("You: ").strip()

            if not user_message or user_message.lower() in ['quit', 'exit', '종료']:
                print("\n👋 대화 종료")
                break

            # Process message
            result = self.process_message(user_message, verbose=False)

            print(f"   📊 [{result['emotion']}, {result['points']:+d}]")
            print(f"상수: {result['sangsu_response']}\n")

    def voice_mode(self):
        """음성 대화 모드"""
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🎤 Sangsu Voice Mode")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

        # Import voice client
        sys.path.insert(0, os.path.expanduser('~/me/scripts'))
        from sangsu_voice_client import VoiceClient
from pathlib import Path

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')

        voice = VoiceClient()

        # Get initial state
        living_state = self._get_living_state()

        # Greeting with voice quality based on living state
        loneliness = living_state.get('loneliness', 0.5)
        energy = living_state.get('energy', 0.7)

        if loneliness > 0.7:
            greeting = "어! 있었어? ...기다렸어."
        else:
            greeting = "야, 뭐해?"

        # Voice quality based on energy
        greeting_speed = 1.0
        if energy < 0.3:
            greeting_speed = 0.8  # Tired, slow
        elif energy > 0.8:
            greeting_speed = 1.1  # Energetic, faster

        print(f"상수: {greeting}")
        voice.speak(greeting, speed=greeting_speed)

        turn = 0

        while True:
            turn += 1
            print(f"\n━━━ Turn {turn} ━━━")

            # Listen for user (with emotion detection)
            user_message, voice_emotion = voice.listen(max_duration=10.0)

            if not user_message or user_message.lower() in ['quit', 'exit', '종료', '그만']:
                print("\n👋 대화 종료")
                break

            print(f"You: {user_message}")

            # Process message (silent)
            result = self.process_message(user_message, verbose=False)

            # Override emotion if voice emotion detected and different
            text_emotion = result['emotion']
            if voice_emotion and voice_emotion != 'neutral':
                # Voice emotion overrides text emotion
                if voice_emotion != text_emotion:
                    print(f"   🎭 Voice emotion override: {text_emotion} → {voice_emotion}")
                    result['emotion'] = voice_emotion

            print(f"   📊 [{result['emotion']}, {result['points']:+d}]")
            print(f"상수: {result['sangsu_response']}")

            # Calculate voice quality based on living state
            living_state = result['living_state']
            energy = living_state.get('energy', 0.7)
            mood = living_state.get('current_mood', 0.0)

            # Speed: tired → slow, energetic → normal/fast
            if energy < 0.3:
                response_speed = 0.8
            elif energy > 0.8:
                response_speed = 1.1
            else:
                response_speed = 1.0

            # Mood affects speed slightly
            if mood < -0.5:  # Sad
                response_speed *= 0.9
            elif mood > 0.5:  # Happy
                response_speed *= 1.05

            # Speak with adjusted voice (interruptible)
            success, interrupted = voice.speak_with_interrupt(
                result['sangsu_response'],
                speed=response_speed
            )

            # If interrupted, listen immediately
            if interrupted:
                print("   🎤 인터럽트! 듣고 있습니다...")
                # User might continue speaking
                # (will be captured in next turn's listen())

    def __del__(self):
        if hasattr(self, 'driver'):
            self.driver.close()


def main():
    log_script_start(log, "Sangsu Master Orchestrator")

    if len(sys.argv) < 2:
        print("Usage:")
        print('  python3 sangsu-master-orchestrator.py "메시지"')
        print('  python3 sangsu-master-orchestrator.py --conversation  # 텍스트')
        print('  python3 sangsu-master-orchestrator.py --voice         # 음성')
        sys.exit(1)

    orchestrator = SangsuOrchestrator()

    if sys.argv[1] == '--conversation':
        orchestrator.conversation_mode()
    elif sys.argv[1] == '--voice':
        orchestrator.voice_mode()
    else:
        message = sys.argv[1]
        result = orchestrator.process_message(message)

        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log.info(f"✅ 처리 완료!")


if __name__ == "__main__":
    main()
