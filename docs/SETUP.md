# Setup

간단 설치/실행/연동 방법만 정리합니다.

## 요구사항

- OCaml 5.x + opam
- dune 3.x

## 설치

```bash
git clone https://github.com/jeong-sik/masc-mcp.git
cd masc-mcp

# 외부 의존성 pin (fresh switch / CI와 동일)
chmod +x scripts/opam-pin-external-deps.sh
scripts/opam-pin-external-deps.sh

# 의존성 설치
opam install . --deps-only

# 빌드
dune build --root .
```

## 실행

```bash
# HTTP 모드 (기본)
./start-masc-mcp.sh --port 8935

# stdio 모드 (레거시)
./start-masc-mcp.sh --stdio

# 상태 확인
curl http://127.0.0.1:8935/health
```

## 내부 Guardian (수호자)

프로세스 내부에서 주기적으로 `zombie cleanup` / `GC` / (선택) `Lodge 루프`를 돌립니다.  
프로세스 재기동은 하지 않으며, 필요 시 외부 watchdog에 위임합니다.

`start-masc-mcp.sh`는 기본으로 `MASC_GUARDIAN_ENABLED=true`를 설정합니다.
비활성화하려면 아래처럼 명시하세요:

```bash
export MASC_GUARDIAN_ENABLED=false
```

```bash
export MASC_GUARDIAN_ENABLED=true
export MASC_GUARDIAN_MODE=both  # masc|lodge|both
# 필요 시 주기 조정:
# export MASC_GUARDIAN_ZOMBIE_INTERVAL_SEC=60
# export MASC_GUARDIAN_GC_INTERVAL_SEC=3600
# export MASC_GUARDIAN_LODGE_INTERVAL_SEC=300
```

상태는 `/health` 응답의 `guardian` 필드에서 확인할 수 있습니다.

## MCP 설정

README의 예시 구성(Claude Code) 참고:

```json
{
  "mcpServers": {
    "masc": { "type": "http", "url": "http://127.0.0.1:8935/mcp" }
  }
}
```

## 최소 사용 예시

```text
masc_join(agent_name: "claude")
masc_add_task(title: "My first task")
masc_transition(agent_name: "claude", task_id: "task-001", action: "claim")
masc_done(agent_name: "claude", task_id: "task-001")
```
