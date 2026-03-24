# Personas Directory

## Overview

~/me/personas/에 모든 페르소나 관리

## Structure

```
personas/
├─ seungji/         # 승지 (기본 AI, Executor)
├─ jaeyong/         # 재용 (회장 스타일)
├─ sangsu/          # 상수 (40대 남자)
├─ miseon/          # 미선 (데이터 전문가)
├─ bowie/           # 보위 (Voice 대화)
├─ gary/            # 게리 (뮤지션)
└─ shared/          # 공통 템플릿/설정
```

## Persona Files

### Required
- `profile.md` - 페르소나 정의 (필수)

### Optional
- `profile.json` - 구조화된 데이터
- `context/` - 컨텍스트 파일들
- `memory/` - 대화 기록/메모리
- `voice/` - Voice agent 설정
- `text/` - Text agent 설정

## Creating New Persona

1. **디렉토리 생성**
   ```bash
   mkdir -p personas/[name]/{memory,context}
   ```

2. **프로필 작성**
   - `shared/persona-template.md` 복사
   - 페르소나 정의 작성

3. **Agent/Skill 연동**
   - `.claude/skills/` 또는 `.claude/agents/`
   - Trigger keywords 설정

4. **CLAUDE.md 업데이트**
   - personas/ 참조 추가

## Active Personas

| Name | Role | Mode | Status |
|------|------|------|--------|
| 승지 (Seungji) | Executor AI | Text | Active (Default) |
| 재용 (Jaeyong) | Chairman | Text | Active |
| 상수 (Sangsu) | 40대 남자 | Text | Active |
| 미선 (Miseon) | Data Expert | Text + Voice | Active |
| 보위 (Bowie) | Voice Chat | Voice | Active |
| 게리 (Gary) | Musician | Text | Active |

## Integration Points

### .claude/skills/
- miseon-text/
- miseon-voice/
- gary-chat/

### .claude/agents/
- sangsu/
- miseon-agent/

### CLAUDE.md
- Persona definitions
- Trigger keywords
- Usage instructions

## Git Management

- ✅ Git tracked: ~/me/personas/
- ❌ Git ignored: .claude/agents/ (local only)

---

**Created**: 2025-11-12
**Purpose**: Central persona management
