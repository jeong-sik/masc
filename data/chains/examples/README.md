# Chain Examples - 예제 구성 가이드

## 🚀 Quick Start

`masc-mcp` is now the canonical chain runtime. These examples target the native chain server on port `8935`; older `model-mcp` `8932` references are retired.

### 1. Mermaid DSL로 바로 실행
```bash
# 터미널에서
curl -X POST http://localhost:8935/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain.run","arguments":{"mermaid":"graph LR\n    A[MODEL:ollama \"Hello\"]"}}}'
```

### 2. 파일로 실행
```bash
chain.run --file examples/login-screen.mermaid
```

---

## 📦 프리셋 예제

### 예제 1: Simple Pipeline (3 nodes)
```mermaid
graph LR
    A[MODEL:stub "input"] --> B[MODEL:ollama "process: {{A}}"] --> C[MODEL:ollama "summarize: {{B}}"]
```

### 예제 2: MAGI 합의 (5 nodes)
```mermaid
graph LR
    Input[Tool:echo "code to review"]
    Input --> M[MODEL:codex "bugs: {{Input}}"]
    Input --> B[MODEL:claude "clarity: {{Input}}"]
    Input --> C[MODEL:gemini "arch: {{Input}}"]
    M --> V{Merge:concat}
    B --> V
    C --> V
```

### 예제 3: 프로토타입 생성 (iOS/Android/Web)
```mermaid
graph LR
    Design[Tool:echo "Button 120x48 blue rounded"]
    Design --> Web[MODEL:claude "React: {{Design}}"]
    Design --> iOS[MODEL:codex "SwiftUI: {{Design}}"]
    Design --> Android[MODEL:gemini "Compose: {{Design}}"]
    Web --> M{Merge:concat}
    iOS --> M
    Android --> M
```

### 예제 4: 에러 복구 (Fallback)
```mermaid
graph LR
    Q[Tool:echo "complex query"]
    Q --> Primary[MODEL:gemini "answer: {{Q}}"]
    Q --> Backup[MODEL:ollama "answer: {{Q}}"]
    Primary --> F{Fallback}
    Backup --> F
```

### 예제 5: 투표 합의 (Quorum 2/3)
```mermaid
graph LR
    Q[Tool:echo "Is this code safe?"]
    Q --> A[MODEL:ollama "YES or NO: {{Q}}"]
    Q --> B[MODEL:ollama "YES or NO: {{Q}}"]
    Q --> C[MODEL:ollama "YES or NO: {{Q}}"]
    A --> V{Quorum:2}
    B --> V
    C --> V
```

---

## 🎨 커스텀 구성

### 노드 타입 Quick Reference

| 타입 | 문법 | 예시 |
|------|------|------|
| MODEL | `[MODEL:model "prompt"]` | `[MODEL:claude "Summarize: {{A}}"]` |
| Tool | `[Tool:name "args"]` | `[Tool:echo "data"]` |
| Merge | `{Merge:strategy}` | `{Merge:concat}` |
| Quorum | `{Quorum:N}` | `{Quorum:2}` |
| Fallback | `{Fallback}` | `{Fallback}` |

### 모델 옵션

| 모델 | 설명 | 비용 |
|------|------|------|
| `stub` | 테스트용 (입력 그대로 반환) | 무료 |
| `ollama` | 로컬 MODEL | 무료 |
| `claude` | Claude (Anthropic) | $$ |
| `codex` | Codex (OpenAI) | $$ |
| `gemini` | Gemini (Google) | $ |
| `haiku` | Claude Haiku (빠름) | $ |

### 변수 참조

```mermaid
graph LR
    A[MODEL:stub "hello"] --> B[MODEL:ollama "input was: {{A}}"]
    %% {{A}} = A 노드의 출력값
```

---

## 🔧 조합 패턴

### 순차 (Sequential)
```
A --> B --> C
```

### 병렬 (Fanout)
```
A --> B
A --> C
A --> D
```

### 합류 (Fan-in)
```
B --> M
C --> M
D --> M
```

### Diamond (순차+병렬)
```
A --> B --> D
A --> C --> D
```

---

## 💡 Tips

1. **테스트 먼저**: `stub`이나 `ollama`로 패턴 검증 후 클라우드 MODEL 사용
2. **타임아웃**: 복잡한 체인은 `timeout` 늘리기 (기본 60초)
3. **비용 절감**: 중간 결과 확인용 노드에는 `haiku` 사용
4. **디버깅**: `Tool:echo`로 중간 값 확인
