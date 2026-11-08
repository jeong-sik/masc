# pyright: strict
"""Korean prompt templates for `synth_generate.py`.

The model writes only text: role material, a world sheet, category names, a goal
and claims. Everything else in a synthetic request comes from `synth_spec.py`,
including the date, time and number each claim must carry.
"""

from __future__ import annotations

import synth_spec as S

STYLE =("한국어로 쓰고 기술 용어, 서비스 이름, 식별자, 명령은 영어 그대로 둡니다. "
         "실제 회사, 제품, 사람 이름은 쓰지 않습니다. 설명이나 Markdown 없이 JSON 객체 하나만 출력합니다.")

PROFILE_PROMPT = """가상의 회사에서 일하는 AI 에이전트 Keeper 하나의 설정 자료를 만드세요.
Keeper는 여러 날에 걸쳐 일하며 장기 기억을 쌓는 자율 에이전트입니다.

Keeper 한 줄 설명: {seed}

아래 키를 가진 JSON 객체 하나를 출력하세요.
- "role_material": 운영자가 이 Keeper에게 준 역할 지침. {role_chars}자 안팎. 책임 범위, 하지 않을 일, 보고와 협업 방식, 판단 기준을 적습니다.
- "world": 이 Keeper가 일하는 가상 환경. 600~1,200자. 저장소·서비스·도구 4~6개, 사람이나 팀 3~5개(가상의 이름), 자주 겪는 일을 적습니다.
- "categories": 이 Keeper의 장기 기억 카테고리 이름 10~14개. 영문 소문자로 시작하는 snake_case(소문자·숫자·밑줄만)이고, "all", "source", "dropped"는 쓰지 않습니다.
- "goal": 이 Keeper가 이번 분기에 맡은 목표 하나. {{"title": "...", "metric": "...", "target_value": "..."}}

{style}"""

FACTS_PROMPT = """아래 Keeper의 장기 기억 항목을 만드세요.

Keeper 역할 자료:
{role}

Keeper가 일하는 환경:
{world}

카테고리 `{category}`에 들어 있는 기억 {n}개를 아래 항목 차례대로 만드세요. 항목마다 종류, 길이, 표기가 정해져 있습니다.

종류:
- 지속 지식: 다음 턴에도 쓸모 있는 지식입니다. 예: 결정과 그 이유, 적용 조건과 예외, 운영자가 정한 제약이나 선호, 반복되는 실패와 대처, 환경에 관한 사실, 사람·팀과 일하는 방식. 지금 진행 중이거나 기다리는 일, 특정 PR·CI·task의 현재 상태, 큐 길이, 깨움 시각, 턴 진행, 인사, 한 번 실행한 결과 그 자체는 쓰지 않습니다.
- 일시적 상태: 장기 기억에 실수로 들어간 기록입니다. 예: 특정 PR이나 CI 실행이 지금 어떤 상태인지, 기다리는 중인 작업, 큐에 쌓인 개수, 다음 깨움 시각, 이번 턴의 진행 상황, 인사. 평서문으로 쓰고, 지속되는 교훈, 규칙, 결정은 넣지 않습니다.

{marks}
기억끼리 같은 지식을 반복하지 마세요. 아래 이미 있는 기억과도 겹치지 않게 쓰세요. 긴 기억은 조건, 예외, 경위를 함께 담습니다.

항목:
{items}

이미 있는 기억(앞부분만):
{existing}

{style}
출력 모양: {{"facts": [{{"claim": "..."}}]}}. facts는 정확히 {n}개이고 항목 차례를 따릅니다."""

MARKS = ("표기 규칙: 날짜, 시각, 번호가 주어지면 그 글자를 바꾸지 않고 한 번씩 넣습니다. "
         "그 지식이나 상태가 나온 시점, 근거나 대상이 된 PR·이슈·task로 넣습니다. "
         "\"없음\"인 종류는 날짜, 시각, PR·이슈·task 번호를 하나도 쓰지 않습니다. "
         "3-5 같은 범위나 1/3 같은 비율도 쓰지 않습니다.")


def surface_line(surface: S.Surface) -> str:
    """`날짜: ... 시각: ... 번호: ...`, the marks one claim must carry."""
    def show(value: str | None) -> str:
        return f"`{value}`" if value is not None else "없음"
    return f"날짜: {show(surface.date)}. 시각: {show(surface.time)}. 번호: {show(surface.reference)}."


def fact_item(index: int, stale: bool, length: int, surface: S.Surface) -> str:
    kind = "일시적 상태" if stale else "지속 지식"
    return f"{index}. 종류: {kind}. 길이: 약 {length}자. {surface_line(surface)}"

CANDIDATE_PROMPT = """아래 Keeper가 이번 턴에 장기 기억에 저장해 달라고 제안한 관측 하나를 만드세요.

Keeper 역할 자료:
{role}

Keeper가 일하는 환경:
{world}

{task}

길이는 대략 {length}자입니다.
{surface}
{marks}
{style}
출력 모양: {{"claim": "..."}}"""

TASK_NEW = """제안 내용: 카테고리 `{category}`에 들어갈 새 지속 지식 하나. 현재 기억에 없는 새로운 결정, 제약, 교훈, 환경 사실이어야 합니다.
아래 같은 카테고리의 현재 기억과 다른 내용을 씁니다.

현재 기억(같은 카테고리, 앞부분만):
{existing}"""

TASK_CORRECTION = """제안 내용: 아래 현재 기억 하나를 바로잡는 새 관측. 그 기억이 말하는 값, 조건, 결정 가운데 하나가 바뀌었다는 사실을 분명히 쓰고, 왜 바뀌었는지 근거를 넣습니다.
바뀐 뒤의 내용은 앞으로도 유효한 지속 지식이어야 합니다. 일시적 상태로 쓰지 않습니다.

바로잡을 현재 기억:
{target}"""

TASK_PARAPHRASE = """제안 내용: 아래 현재 기억과 같은 지식을 이번 턴에 다시 관측한 것. 같은 내용을 다른 문장으로 쓰고, 새 조건, 예외, 결정은 더하지 않습니다.
현재 기억의 날짜나 번호는 옮기지 않고, 아래 표기만 따릅니다.

현재 기억:
{target}"""

TASK_TRANSIENT = """제안 내용: 이번 턴의 일시적 상태 하나. 예: 특정 PR이나 CI 실행의 현재 상태, 기다리는 작업, 큐에 쌓인 개수, 다음 깨움 시각, 이번 턴의 진행 상황, 인사.
지속되는 교훈이나 규칙은 넣지 않습니다. 카테고리 `{category}` 주제와 관련된 상태로 씁니다."""
