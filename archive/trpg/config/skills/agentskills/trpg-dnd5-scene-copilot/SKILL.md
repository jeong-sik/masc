---
name: trpg-dnd5-scene-copilot
description: "TRPG(DnD5-lite) 턴에서 actor traits/skills를 읽고 액션 3개와 권장 판정(능력치/DC)을 제안하는 코파일럿 스킬. Trigger: trpg skill, dnd5 action, 턴 추천, 전투 선택."
metadata:
  short-description: TRPG DnD5 action copilot
---

# TRPG DnD5 Scene Copilot

## When to use
- DnD5-lite TRPG 장면에서 플레이어/DM이 다음 액션을 빠르게 고를 때
- "이 스킬로 지금 뭘 해야 해?" 같은 질문이 나올 때
- traits/skills를 게임 텍스트로 바로 연결해야 할 때

## Source of truth
- Skill catalog: `config/trpg/skills/agent_skills.json`
- Character presets: `config/trpg/presets/character.json`

## Workflow
1. 현재 actor의 `skills`, `traits`, `hp/mp`, `phase`, `recent outcome`을 먼저 요약한다.
2. 카탈로그에서 actor가 가진 스킬 1-2개를 우선 선택한다.
3. 액션 후보 3개를 제시한다:
- `safe`: 리스크 낮음, 성공 확률 우선
- `tempo`: 흐름 전환 시도
- `high-risk`: 고보상, 실패 리스크 큼
4. 각 후보마다 DnD5-lite 권장 판정을 붙인다:
- Ability check (예: DEX Stealth, CHA Persuasion)
- 권장 DC (10/13/15/18 중 하나)
- 실패 시 비용 한 줄
5. 출력은 짧고 즉시 실행 가능한 문장으로 마무리한다.

## Output template
```text
[TURN PLAN]
1) SAFE - <action>
   - Skill: <skill>
   - Check: <ability/skill>, DC <n>
   - Cost on fail: <one line>

2) TEMPO - <action>
   - Skill: <skill>
   - Check: <ability/skill>, DC <n>
   - Cost on fail: <one line>

3) HIGH-RISK - <action>
   - Skill: <skill>
   - Check: <ability/skill>, DC <n>
   - Cost on fail: <one line>
```

## Guardrails
- meta 설명보다 "지금 행동"을 우선한다.
- 없는 스킬 이름을 새로 만들지 않는다.
- 결과가 반복되면 같은 skill이어도 접근(대상/위치/타이밍)을 바꿔 제안한다.
