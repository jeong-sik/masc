#!/usr/bin/env python3
"""
상수 LLM 기반 감정 감지 (Claude API)

**Why LLM?**
- 키워드: "됐어" → dismissal (단순)
- LLM: "됐어 고마워" → validation (맥락 이해)

**11 Emotions**:
attack, breakdown, suicidal, sarcasm, logical_attack,
belittle, dismissal, curiosity, validation, empathy, neutral

**Usage**:
  python3 sangsu-llm-emotion-detector.py "아 아침부터 영화 얘기야"
  python3 sangsu-llm-emotion-detector.py --batch "msg1" "msg2" "msg3"
"""

import sys
import json
import os
from anthropic import Anthropic
from pathlib import Path

# Add utils to path for Microlog
sys.path.append(str(Path.home() / "me" / "utils"))
from microlog import get_logger, log_script_start, log_script_end

log = get_logger(__name__, level='INFO')


def detect_emotion_llm(user_message: str, context: dict = None) -> dict:
    """
    LLM 기반 감정 감지

    **Args**:
    - user_message: User 발언
    - context: 대화 맥락 (optional)
      - recent_emotions: 최근 감정 패턴
      - intimacy: 현재 친밀도
      - previous_message: 이전 발언

    **Returns**:
    {
      "emotion": str,  # 11-emotion
      "points": int,   # -5 ~ +5
      "confidence": float,  # 0.0 ~ 1.0
      "reason": str    # 왜 이 감정?
    }
    """
    client = Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

    # Context 준비
    context_str = ""
    if context:
        if context.get('recent_emotions'):
            context_str += f"\n최근 감정 패턴: {context['recent_emotions']}"
        if context.get('intimacy'):
            context_str += f"\n현재 친밀도: {context['intimacy']}"
        if context.get('previous_message'):
            context_str += f"\n이전 발언: {context['previous_message']}"

    prompt = f"""다음 발언의 감정을 분석하세요.

**발언**: "{user_message}"{context_str}

**캐릭터 컨텍스트**:
- 상수: 45세 독립영화 감독, 인정 욕구 극심, 방어적, 위선적
- User와 대화 중 (친구 관계 형성 중)

**11가지 감정 중 선택**:
1. attack (-5점): 직접적 공격, 모욕 ("너 멍청해", "쓰레기야")
2. breakdown (-4점): 상수를 무너뜨림 ("10년 동안 뭐했어?")
3. suicidal (-5점): 극단적 부정 (사용 드묾)
4. sarcasm (-2점): 비꼬기 ("하하 그렇겠네", "당연하지")
5. logical_attack (-3점): 논리적 공격 ("그건 말이 안 돼")
6. belittle (-3점): 깔보기 ("별로야", "시시해")
7. dismissal (-4점): 무시하기 ("됐어", "바빠", "나중에")
8. curiosity (+2점): 관심 ("어떻게?", "설명해봐")
9. validation (+5점): 인정 ("잘했어", "대단해")
10. empathy (+4점): 공감 ("힘들었겠다", "이해해")
11. neutral (0점): 중립적 일상 대화

**중요**:
- 맥락 고려! "됐어 고마워" = validation (dismissal 아님)
- "ㅋㅋ"는 맥락에 따라 sarcasm or neutral
- 짧은 대답 ("응", "어") = neutral

**출력 형식** (JSON only):
{{
  "emotion": "감정명",
  "points": 점수,
  "confidence": 0.0-1.0,
  "reason": "1-2문장 설명"
}}
"""

    try:
        response = client.messages.create(
            model=os.getenv("MASC_PERSONA_MODEL", "claude-sonnet-4-20250514"),
            max_tokens=300,
            messages=[{"role": "user", "content": prompt}]
        )

        result_text = response.content[0].text.strip()

        # Remove markdown if present
        if result_text.startswith("```"):
            result_text = result_text.split("```")[1]
            if result_text.startswith("json"):
                result_text = result_text[4:]
            result_text = result_text.strip()

        result = json.loads(result_text)

        return {
            "emotion": result.get("emotion", "neutral"),
            "points": result.get("points", 0),
            "confidence": result.get("confidence", 0.8),
            "reason": result.get("reason", "")
        }

    except Exception as e:
        log.warning(f"⚠️  LLM detection failed: {e}", file=sys.stderr)
        # Fallback to keyword-based
        return detect_emotion_keyword_fallback(user_message)


def detect_emotion_keyword_fallback(user_message: str) -> dict:
    """
    Fallback: 키워드 기반 감지 (LLM 실패 시)
    """
    user_lower = user_message.lower()

    if any(k in user_lower for k in ['멍청', '바보', '쓰레기']):
        return {'emotion': 'attack', 'points': -5, 'confidence': 0.7, 'reason': 'Keyword: attack'}

    if any(k in user_lower for k in ['됐어', '바빠', '나중에']):
        return {'emotion': 'dismissal', 'points': -4, 'confidence': 0.6, 'reason': 'Keyword: dismissal'}

    if any(k in user_lower for k in ['잘했', '대단', '훌륭']):
        return {'emotion': 'validation', 'points': +5, 'confidence': 0.7, 'reason': 'Keyword: validation'}

    if any(k in user_lower for k in ['힘들었', '이해해']):
        return {'emotion': 'empathy', 'points': +4, 'confidence': 0.7, 'reason': 'Keyword: empathy'}

    if '?' in user_message:
        return {'emotion': 'curiosity', 'points': +2, 'confidence': 0.5, 'reason': 'Keyword: question'}

    return {'emotion': 'neutral', 'points': 0, 'confidence': 0.5, 'reason': 'Fallback: neutral'}


def batch_detect(messages: list, context: dict = None) -> list:
    """
    여러 메시지 일괄 감지

    **Optimization**:
    - 대화 흐름 고려
    - 이전 감정 → 다음 감정 영향
    """
    results = []

    for i, msg in enumerate(messages):
        # Build context from previous
        msg_context = context or {}
        if i > 0:
            msg_context['previous_message'] = messages[i-1]
            msg_context['recent_emotions'] = [r['emotion'] for r in results[-3:]]

        result = detect_emotion_llm(msg, msg_context)
        results.append(result)

    return results


def main():
    log_script_start(log, "Sangsu Llm Emotion Detector")

    if len(sys.argv) < 2:
        print("Usage:")
        print('  python3 sangsu-llm-emotion-detector.py "메시지"')
        print('  python3 sangsu-llm-emotion-detector.py --batch "msg1" "msg2" "msg3"')
        sys.exit(1)

    if sys.argv[1] == "--batch":
        messages = sys.argv[2:]
        print("🧠 Batch Emotion Detection\n")

        results = batch_detect(messages)

        for i, (msg, result) in enumerate(zip(messages, results), 1):
            print(f"━━━ Message {i} ━━━")
            print(f'User: "{msg}"')
            print(f'Emotion: {result["emotion"]} ({result["points"]:+d})')
            print(f'Confidence: {result["confidence"]:.2f}')
            print(f'Reason: {result["reason"]}')
            print()

    else:
        message = sys.argv[1]
        print("🧠 LLM Emotion Detection\n")
        print(f'User: "{message}"')
        print()

        result = detect_emotion_llm(message)

        print(f'Emotion: {result["emotion"]}')
        print(f'Points: {result["points"]:+d}')
        print(f'Confidence: {result["confidence"]:.2f}')
        print(f'Reason: {result["reason"]}')


if __name__ == "__main__":
    main()
