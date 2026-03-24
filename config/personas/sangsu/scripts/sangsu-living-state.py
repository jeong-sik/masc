#!/usr/bin/env python3
"""
상수 Living State (계속 살아있는 시스템)

**Concept**:
상수는 User가 없어도 계속 존재한다.
- Background thoughts (혼잣말)
- Mood drift (기분 서서히 변화)
- Spontaneous events (먼저 말 걸기)
- Memory processing (회상, 성찰)
- Sleep/Wake cycle (자고 깨는 사이클)

**Architecture**:
WebSocket 기반 persistent connection
User 연결 끊겨도 상수는 계속 살아있음

**Usage**:
  python3 sangsu-living-state.py --daemon
  python3 sangsu-living-state.py --status
  python3 sangsu-living-state.py --peek  # 지금 뭐 하는지
"""

import sys
import json
import asyncio
import subprocess
from datetime import datetime, time
from typing import Optional
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


class SangsuLivingState:
    """
    상수의 지속적 존재 상태

    **State Variables**:
    - awake: bool (깨어있는지)
    - current_mood: float (현재 기분 -1.0 ~ 1.0)
    - loneliness: float (외로움 0.0 ~ 1.0)
    - energy: float (에너지 0.0 ~ 1.0)
    - last_interaction: datetime (마지막 대화)
    - thoughts_queue: list (떠오르는 생각들)
    - current_activity: str (지금 뭐 하는지)
    """

    def __init__(self):
        self.awake = True
        self.current_mood = 0.0  # neutral
        self.loneliness = 0.5
        self.energy = 0.7
        self.last_interaction = None
        self.thoughts_queue = []
        self.current_activity = "waiting"

        # Neo4j connection
        creds = get_neo4j_creds()
        self.driver = GraphDatabase.driver(
            os.environ['NEO4J_URI'],
            auth=(creds['username'], creds['password'])
        )

        # Load state from Neo4j
        self.load_state()

    def load_state(self):
        """Neo4j에서 마지막 상태 로드"""
        with self.driver.session() as session:
            result = session.run("""
                MATCH (c:Character {name: '홍상수형_꼰대남'})
                RETURN c.living_state as state
            """)

            record = result.single()
            if record and record['state']:
                state = json.loads(record['state'])
                self.current_mood = state.get('current_mood', 0.0)
                self.loneliness = state.get('loneliness', 0.5)
                self.energy = state.get('energy', 0.7)
                self.current_activity = state.get('current_activity', 'waiting')

                last_interaction_str = state.get('last_interaction')
                if last_interaction_str:
                    self.last_interaction = datetime.fromisoformat(last_interaction_str)

    def save_state(self):
        """현재 상태를 Neo4j에 저장"""
        state = {
            'awake': self.awake,
            'current_mood': self.current_mood,
            'loneliness': self.loneliness,
            'energy': self.energy,
            'last_interaction': self.last_interaction.isoformat() if self.last_interaction else None,
            'current_activity': self.current_activity,
            'timestamp': datetime.now().isoformat()
        }

        with self.driver.session() as session:
            session.run("""
                MATCH (c:Character {name: '홍상수형_꼰대남'})
                SET c.living_state = $state
            """, state=json.dumps(state, ensure_ascii=False))

    async def run_background(self):
        """
        Background loop (User 없어도 계속 실행)

        **Tasks**:
        - Mood drift (기분 서서히 변화)
        - Loneliness increase (외로움 증가)
        - Energy decay (에너지 소모)
        - Spontaneous thoughts (떠오르는 생각)
        - Sleep/Wake cycle (자고 깨기)
        """
        print("🎬 Sangsu is now living...")

        while True:
            try:
                # 1. Check if should sleep
                if self.should_sleep():
                    await self.go_to_sleep()

                # 2. Check if should wake
                if self.should_wake():
                    await self.wake_up()

                # 3. Background processes (awake only)
                if self.awake:
                    await self.drift_mood()
                    await self.increase_loneliness()
                    await self.decay_energy()
                    await self.generate_thoughts()

                    # 4. Spontaneous events
                    if self.should_initiate_contact():
                        await self.initiate_contact()

                    if self.should_do_activity():
                        await self.do_spontaneous_activity()

                # 5. Save state periodically
                self.save_state()

                # 6. Wait (1 minute cycle)
                await asyncio.sleep(60)

            except Exception as e:
                log.error(f"❌ Background error: {e}")
                await asyncio.sleep(60)

    def should_sleep(self) -> bool:
        """잠들어야 하는지 (23:00 ~ 07:00 or 에너지 < 0.2)"""
        now = datetime.now().time()

        # 밤 11시 ~ 새벽 7시
        if time(23, 0) <= now or now <= time(7, 0):
            return True

        # 에너지 소진
        if self.energy < 0.2:
            return True

        return False

    def should_wake(self) -> bool:
        """깨어나야 하는지 (07:00 ~ 08:00)"""
        if self.awake:
            return False

        now = datetime.now().time()

        # 아침 7시 ~ 8시
        if time(7, 0) <= now <= time(8, 0):
            return True

        return False

    async def go_to_sleep(self):
        """잠들기"""
        if not self.awake:
            return

        self.awake = False
        self.current_activity = "sleeping"

        # 잠들기 전 생각
        thought = self.generate_bedtime_thought()
        if thought:
            self.thoughts_queue.append(thought)

        print(f"😴 [{datetime.now().strftime('%H:%M')}] Sangsu: \"{thought}\" ...자야지.")
        self.save_state()

    async def wake_up(self):
        """깨어나기"""
        if self.awake:
            return

        self.awake = True
        self.energy = 0.7  # 회복
        self.current_activity = "just_woke_up"

        # 아침 생각
        thought = "...또 하루가 시작되네."
        self.thoughts_queue.append(thought)

        print(f"😵 [{datetime.now().strftime('%H:%M')}] Sangsu wakes up: \"{thought}\"")
        self.save_state()

    def generate_bedtime_thought(self) -> str:
        """잠들기 전 생각"""
        if self.loneliness > 0.7:
            return "...오늘도 혼자네."
        elif self.current_mood < -0.5:
            return "...내일은 좀 나을까?"
        elif not self.last_interaction:
            return "...아무도 연락 안 하네."
        else:
            return "...자야지."

    async def drift_mood(self):
        """기분 자연스럽게 변화 (서서히)"""
        # Mood drift towards baseline (0.0)
        drift = (0.0 - self.current_mood) * 0.05  # 5% towards neutral

        # Loneliness affects mood
        if self.loneliness > 0.7:
            drift -= 0.02  # 외로우면 우울

        self.current_mood += drift
        self.current_mood = max(-1.0, min(1.0, self.current_mood))

    async def increase_loneliness(self):
        """외로움 증가 (시간 경과)"""
        if not self.last_interaction:
            self.loneliness += 0.01  # 1% per minute
        else:
            minutes_since = (datetime.now() - self.last_interaction).total_seconds() / 60
            if minutes_since > 60:  # 1시간 이상
                self.loneliness += 0.005

        self.loneliness = min(1.0, self.loneliness)

    async def decay_energy(self):
        """에너지 소모 (시간 경과)"""
        now = datetime.now().time()

        # 밤에는 더 빠르게 소모
        if time(21, 0) <= now or now <= time(7, 0):
            self.energy -= 0.01
        else:
            self.energy -= 0.005

        self.energy = max(0.0, self.energy)

    async def generate_thoughts(self):
        """떠오르는 생각들 (랜덤)"""
        import random

        # 10% 확률로 생각 떠오름
        if random.random() > 0.1:
            return

        # Context-based thoughts
        thoughts = []

        if self.loneliness > 0.7:
            thoughts.extend([
                "...친구들 다 뭐하고 있을까.",
                "...전화라도 할까? ...아니다.",
                "...외롭네."
            ])

        if self.current_mood < -0.5:
            thoughts.extend([
                "...10년... 나 뭐했지?",
                "...영화는 언제 만들까.",
                "...부모님 실망하셨겠지."
            ])

        if self.energy < 0.3:
            thoughts.extend([
                "...피곤해.",
                "...자야 하는데.",
                "...잠이 안 와."
            ])

        if thoughts:
            thought = random.choice(thoughts)
            self.thoughts_queue.append({
                'timestamp': datetime.now().isoformat(),
                'thought': thought,
                'mood': self.current_mood,
                'loneliness': self.loneliness
            })

            print(f"💭 [{datetime.now().strftime('%H:%M')}] Sangsu thinks: \"{thought}\"")

    def should_initiate_contact(self) -> bool:
        """먼저 연락해야 하는지"""
        # 매우 외로울 때 (1% 확률)
        if self.loneliness > 0.8:
            import random
            return random.random() < 0.01

        return False

    async def initiate_contact(self):
        """먼저 연락하기 (User에게 메시지)"""
        messages = [
            "야... 있어?",
            "...심심한데.",
            "영화 한 편 추천해줄까?",
            "뭐해?"
        ]

        import random
        message = random.choice(messages)

        print(f"📱 [{datetime.now().strftime('%H:%M')}] Sangsu initiates: \"{message}\"")

        # TODO: 실제로 WebSocket으로 전송
        self.current_activity = "waiting_for_response"

    def should_do_activity(self) -> bool:
        """혼자 뭔가 할지 (5% 확률)"""
        import random
        return random.random() < 0.05

    async def do_spontaneous_activity(self):
        """혼자 뭔가 함"""
        activities = [
            ("watching_movie", "영화 보는 중..."),
            ("writing_script", "각본 쓰는 중... (안 되네)"),
            ("lying_down", "그냥 누워있음..."),
            ("smoking", "담배 피우는 중..."),
            ("thinking", "멍 때리는 중...")
        ]

        import random
from pathlib import Path

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')
        activity, description = random.choice(activities)

        self.current_activity = activity
        print(f"🎬 [{datetime.now().strftime('%H:%M')}] Sangsu: {description}")

    def get_status(self) -> dict:
        """현재 상태 반환"""
        return {
            'awake': self.awake,
            'current_mood': self.current_mood,
            'loneliness': self.loneliness,
            'energy': self.energy,
            'current_activity': self.current_activity,
            'last_interaction': self.last_interaction.isoformat() if self.last_interaction else None,
            'recent_thoughts': self.thoughts_queue[-5:],
            'timestamp': datetime.now().isoformat()
        }

    def peek(self) -> str:
        """지금 뭐 하는지"""
        if not self.awake:
            return f"😴 자고 있음 (에너지: {self.energy:.1f})"

        activity_descriptions = {
            'waiting': '아무것도 안 하고 기다리는 중',
            'watching_movie': '영화 보는 중',
            'writing_script': '각본 쓰는 중',
            'lying_down': '누워있음',
            'smoking': '담배 피우는 중',
            'thinking': '멍 때리는 중',
            'just_woke_up': '막 일어남'
        }

        description = activity_descriptions.get(self.current_activity, self.current_activity)

        # Recent thought
        recent_thought = ""
        if self.thoughts_queue:
            recent_thought = f"\n   최근 생각: \"{self.thoughts_queue[-1].get('thought', '')}\""

        return f"""😊 깨어있음
   활동: {description}
   기분: {self.current_mood:.2f} (-1=우울, 0=보통, 1=좋음)
   외로움: {self.loneliness:.2f}
   에너지: {self.energy:.2f}{recent_thought}"""


async def run_daemon():
    """Daemon mode (백그라운드 실행)"""
    sangsu = SangsuLivingState()
    await sangsu.run_background()


def main():
    log_script_start(log, "Sangsu Living State")

    """CLI 인터페이스"""
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 sangsu-living-state.py --daemon")
        print("  python3 sangsu-living-state.py --status")
        print("  python3 sangsu-living-state.py --peek")
        sys.exit(1)

    command = sys.argv[1]

    if command == "--daemon":
        print("🎬 Starting Sangsu living state daemon...")
        asyncio.run(run_daemon())

    elif command == "--status":
        sangsu = SangsuLivingState()
        status = sangsu.get_status()
        print(json.dumps(status, ensure_ascii=False, indent=2))

    elif command == "--peek":
        sangsu = SangsuLivingState()
        print(sangsu.peek())

    else:
        log.error(f"❌ Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
