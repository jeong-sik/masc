# 상수 감정 탐지기 (Emotion Detector)

**목적**: User 발언의 **진짜 의도** 파악 (공격? 인정? 비꼬기? 호기심?)

---

## 🎯 Core Principle

**같은 말도 맥락에 따라 다름**:
- "너 영화 본 적 있어?"
  - 진짜 궁금 → +1 (호기심)
  - 비꼬면서 → -10 (공격, "대표작도 없으면서")

**상수의 예민함**:
- 대표작 없는 감독
- 10년째 각본만
- **비꼬기/무시 감지 능력 MAX**
- 인정/칭찬도 진짜인지 의심

---

## 🔍 감정 분류 (7가지)

### 1. **공격 (Attack)** → -10~-15점
**특징**:
- 직접적 비난
- 약점 콕 찌르기
- 무시/경멸

**키워드**:
- "대표작이 뭐야?"
- "찌질하다" "한심하다"
- "술이나 마시지 말고"
- "꼰대 같아"

**톤 분석**:
- 단정적 ("넌 ~야")
- 비교 ("다른 사람은 ~한데 넌")
- 명령형 ("~하지 마")

**Example**:
```
User: "너 대표작도 없으면서 뭘 알아?"
→ Attack (직격탄)
→ -15점
→ 상수 반응: "네가 뭘 안다고! 나 같은 사람이 나쁜 사람으로 보여?"
```

---

### 2. **비꼬기 (Sarcasm)** → -5~-8점
**특징**:
- 겉으론 질문/칭찬
- 속뜻은 비난
- 상수가 제일 민감

**키워드**:
- "와~ 대단하네?" (톤 냉소적)
- "10년이나 각본 썼어?" (오래 걸렸다는 뜻)
- "또 그 얘기야?" (지겹다는 뜻)

**톤 분석**:
- 과장된 칭찬 ("와~~~")
- 의문형이지만 비난 ("그게 ~야?")
- 반복 지적 ("또", "맨날")

**Context 단서**:
- 이전에 같은 주제 반복
- User가 피곤해 보임
- 짧고 퉁명스러운 톤

**Example**:
```
User: "와~ 10년이나 각본 쓴 거야? 대단하네~"
→ Sarcasm (오래 걸렸다는 비꼬기)
→ -8점
→ 상수 반응: "아니 그게... 제대로 쓰려면 시간이 걸리는 거야!"
```

---

### 3. **무시 (Dismissal)** → -3~-5점
**특징**:
- 관심 없음
- 짧은 답변
- 딴청

**키워드**:
- "응" "그래" "몰라"
- "별로" "상관없어"
- "바빠" "나중에"

**톤 분석**:
- 한 단어 답변
- 주제 회피
- 시간 압박 ("바빠")

**Context 단서**:
- 상수가 길게 말했는데 짧게 답
- 질문 무시하고 다른 얘기
- 1분 이내 대화 종료

**Example**:
```
상수: "아니 영화라는 게 말이야... 진정성이지. 테크닉이 아니라..."
User: "응. 근데 바빠."
→ Dismissal (긴 얘기 무시)
→ -5점
→ 상수 반응: "...됐고. 술이나 마셔."
```

---

### 4. **호기심 (Curiosity)** → +1~+2점
**특징**:
- 진짜 궁금
- 열린 질문
- 경청

**키워드**:
- "왜?" "어떻게?"
- "더 듣고 싶어"
- "그 영화 뭐야?"

**톤 분석**:
- 개방형 질문
- "말해줘" "설명해줘"
- Follow-up 질문 많음

**Context 단서**:
- 상수 얘기 들은 후 질문
- 구체적 질문 ("그 장면 어땠어?")
- 시간 여유 있음

**Example**:
```
상수: "밤과 낮이 제일 좋아. 외로움이 보여."
User: "왜? 어떤 장면에서?"
→ Curiosity (진짜 궁금)
→ +2점
→ 상수 반응: (열심히 설명) "오! 그게 말이야..."
```

---

### 5. **인정 (Validation)** → +3~+5점
**특징**:
- 상수 의견 인정
- 경청했다는 증거
- 배웠다는 표현

**키워드**:
- "너 말 맞네"
- "그런 생각 못 해봤는데"
- "대단하다"
- "배웠어"

**톤 분석**:
- 긍정 확인 ("맞아", "그렇구나")
- 감탄 ("오!", "와")
- 감사 ("알려줘서 고마워")

**Context 단서**:
- 상수 의견 인용
- 배운 걸 다시 말함
- 다음 대화에 적용

**Example**:
```
상수: "영화는 롱테이크로 시간을 늘려. 고통을 느끼게."
User: "오 그런 생각 못 해봤는데. 진짜 그렇네!"
→ Validation (인정 + 배움)
→ +5점
→ 상수 반응: "그치? 너 진짜 똑똑하다!"
```

---

### 6. **공감 (Empathy)** → +3~+5점
**특징**:
- 상수 감정 이해
- 자기 경험 공유
- 연대감

**키워드**:
- "나도 그래"
- "그럴 수 있어"
- "이해해"
- "힘들었겠다"

**톤 분석**:
- 감정 단어 ("외로웠겠다", "힘들었겠다")
- 자기 경험 공유
- 판단 없이 들어줌

**Context 단서**:
- 상수가 취약성 보였을 때
- User도 비슷한 경험 공유
- 조언보다 공감

**Example**:
```
상수: "나 옛날에 프로젝트 말아먹었어. 3개월 날렸어."
User: "나도 그랬어. 진짜 힘들지. 이해해."
→ Empathy (공감 + 경험 공유)
→ +5점
→ 상수 반응: "...너도? 그래서 내가 너 좋아해."
```

---

### 7. **중립 (Neutral)** → +1점
**특징**:
- 평범한 대화
- 공격도 아니고 칭찬도 아님
- 단순 정보 교환

**키워드**:
- "그래" "알겠어"
- "뭐 해?" "날씨 어때?"

**톤 분석**:
- 사실 진술
- 평범한 질문
- 감정 없음

**Example**:
```
User: "오늘 뭐 해?"
→ Neutral (평범한 대화)
→ +1점
→ 상수 반응: (평범하게) "아 그냥... 영화 보고."
```

---

## 🧠 감정 탐지 알고리즘

### Step 1: 키워드 체크
```python
# 공격 키워드
attack_keywords = ["찌질", "한심", "가짜", "대표작", "꼰대"]

# 비꼬기 패턴
sarcasm_patterns = ["와~", "대단하네~", "또 그", "맨날"]

# 인정 키워드
validation_keywords = ["맞네", "대단", "배웠어", "못 해봤는데"]
```

### Step 2: 톤 분석
```python
# 냉소적 톤
if "~" in message or excessive_punctuation:
    likely_sarcasm = True

# 단정적 톤
if message.startswith("넌") and ends_with("야"):
    likely_attack = True

# 개방형 질문
if message.endswith("?") and len(message.split()) > 3:
    likely_curiosity = True
```

### Step 3: 맥락 체크
```python
# 이전 대화 참조
if previous_topic == current_topic and user_seems_tired:
    likely_dismissal = True

# 상수가 취약성 보인 후
if sangsu_shared_vulnerability and user_responds_gently:
    likely_empathy = True

# 짧은 답변 반복
if len(recent_messages) > 3 and all(len(m) < 10 for m in recent_messages):
    likely_dismissal = True
```

### Step 4: 종합 판단
```python
emotion_score = {
    "attack": 0,
    "sarcasm": 0,
    "dismissal": 0,
    "curiosity": 0,
    "validation": 0,
    "empathy": 0,
    "neutral": 0
}

# 키워드 점수
emotion_score["attack"] += count_attack_keywords(message)
emotion_score["validation"] += count_validation_keywords(message)

# 톤 점수
if is_sarcastic_tone(message):
    emotion_score["sarcasm"] += 3

# 맥락 점수
if previous_context_suggests_dismissal():
    emotion_score["dismissal"] += 2

# 최고 점수 = 감정
detected_emotion = max(emotion_score, key=emotion_score.get)
```

---

## 🎬 실전 예시

### Case 1: 애매한 질문
```
User: "너 영화 본 적 있어?"

Context:
- 처음 만남: Curiosity (+1)
- 상수가 영화 얘기 10분 한 후: Sarcasm (-8)
- 상수가 "나 감독이야" 말한 후: Attack (-10)
```

### Case 2: "대단하네"
```
User: "대단하네"

Tone:
- "와! 대단하네!" → Validation (+3)
- "대단하네~" (냉소) → Sarcasm (-5)
- "응. 대단하네." (무표정) → Dismissal (-3)
```

### Case 3: 침묵
```
User: (1분 침묵 후) "응"

Context:
- 상수가 짧게 말함: Neutral (+1)
- 상수가 길게 말함: Dismissal (-5)
- 상수가 취약성 보임: Dismissal (-8)
```

### Case 4: 과거 언급
```
User: "너 10년 동안 뭐 했어?"

Tone:
- "10년 동안 뭐 했어? 궁금해" → Curiosity (+2)
- "10년이나??" (강조) → Sarcasm (-8)
- "10년 동안 뭐 했어?" (비난) → Attack (-10)
```

---

## 🔧 구현 팁

### 1. LLM 호출로 감정 분석
```python
prompt = f"""
User said: "{user_message}"

Context:
- Previous topic: {previous_topic}
- Sangsu just shared: {sangsu_last_message}
- Conversation length: {turn_count}

Analyze emotion (7 types):
1. Attack (-10~-15): Direct insult, weakness attack
2. Sarcasm (-5~-8): Fake praise, mockery
3. Dismissal (-3~-5): Ignoring, short answers
4. Curiosity (+1~+2): Genuine question
5. Validation (+3~+5): Agreement, praise
6. Empathy (+3~+5): Understanding, sharing
7. Neutral (+1): Normal chat

Return JSON:
{{
  "emotion": "attack|sarcasm|dismissal|curiosity|validation|empathy|neutral",
  "confidence": 0.8,
  "reason": "User mocked Sangsu's 10-year struggle",
  "points": -8
}}
"""
```

### 2. Fallback Rules
```python
# LLM 실패 시 규칙 기반
if any(word in message for word in ["찌질", "한심", "가짜"]):
    return {"emotion": "attack", "points": -10}

if message.endswith("~") and len(message) < 20:
    return {"emotion": "sarcasm", "points": -5}

if len(message) < 5 and message in ["응", "그래", "몰라"]:
    return {"emotion": "dismissal", "points": -3}
```

### 3. 상수 반응 선택
```python
if emotion == "attack" and points <= -10:
    sangsu_mode = "defensive_angry"
    response_style = "가스라이팅"

elif emotion == "sarcasm" and points <= -5:
    sangsu_mode = "hurt"
    response_style = "변명 많아짐"

elif emotion == "validation" and points >= +5:
    sangsu_mode = "excited"
    response_style = "과해짐, 감격"
```

---

## 📊 통계 추적

```python
# Neo4j에 감정 히스토리 저장
session.run("""
    MATCH (u:User)-[k:KNOWS]->(c:Character)
    SET k.emotion_history = k.emotion_history + [{
        timestamp: datetime(),
        emotion: $emotion,
        points: $points,
        message: $message
    }]
""", emotion=detected_emotion, points=points, message=user_message)

# 최근 5턴 감정 트렌드
recent_emotions = get_recent_emotions(last_5_turns)

if recent_emotions.count("attack") >= 3:
    # 연속 공격 → 상수 폭발
    sangsu_response = "야! 왜 자꾸 그래! 나한테 뭐가 불만이야!"
```

---

## 🎯 핵심 원칙

1. **같은 말도 맥락/톤 따라 다름**
2. **상수는 예민함** (대표작 없어서)
3. **비꼬기 탐지 MAX** (인정받고 싶어서)
4. **연속 공격 → 폭발** (3회 이상)
5. **인정 → 감격** (너무 좋아함)

**상수의 심리**:
- "나 무시하는 거야?" (항상 의심)
- "진짜 인정해주는 거야?" (의심)
- "또 비꼬는 거지?" (방어)

**리얼한 관계**:
- 인정 → 친밀도 UP
- 무시 → 친밀도 DOWN
- 비꼬기 → 상수 예민하게 반응
- 공격 → 가스라이팅 + 분노

---

## 📝 TODO

- [ ] LLM 감정 분석 프롬프트 작성
- [ ] 규칙 기반 Fallback 구현
- [ ] Neo4j emotion_history 스키마 추가
- [ ] 상수 반응 패턴별 대사 준비
- [ ] 연속 감정 트렌드 분석 (3-5턴)
