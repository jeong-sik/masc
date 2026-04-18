---
status: runbook
last_verified: 2026-04-18
code_refs:
  - lib/keeper/
  - docs/KEEPER-USER-MANUAL.md
  - docs/KEEPER-FILE-MODEL.md
---

# Docker Sandbox Quickstart

이 문서는 keeper Docker sandbox를 가장 짧게 켜는 경로만 남긴 문서다.

처음에는 아래 세 줄만 기억하면 된다:

- 기본값: `sandbox_profile="docker_hardened"` + `network_mode="none"`
- 네트워크가 꼭 필요할 때만: `network_mode="inherit"`
- Docker 자체가 문제일 때만: `sandbox_profile="legacy_local"`

이 문서에서 말하는 sandbox는 **keeper 실행용 Docker sandbox**다.
`OAS_CODEX_SANDBOX` 같은 CLI sandbox와는 다른 레이어다.

## 0.5 어디를 고치나

```text
config/personas/watchdog/profile.json   -> 누구인지 / 어떤 역할인지
config/keepers/watchdog.toml            -> 여기서 어떻게 태울지
<basepath>/.masc/keepers/watchdog.json  -> 지금 어떤 상태인지
<basepath>/.masc/keepers/watchdog/      -> 로그, 메트릭, 흔적
```

짧은 암기:

- `profile.json` = who
- `keeper.toml` = where/how
- `keeper.json` = current runtime state
- `keeper/` directory = detailed history

## 1. 고르기

| 상황 | 권장 설정 | 왜 |
| --- | --- | --- |
| 코드 읽기, 테스트, 패치, 로컬 빌드 | `docker_hardened` + `none` | 가장 보수적인 기본값 |
| 패키지 설치, 원격 API 호출, git fetch 같은 네트워크 필요 작업 | `docker_hardened` + `inherit` | Docker 격리는 유지하고 네트워크만 연다 |
| Docker가 아예 없거나, 지금 디버깅 대상이 Docker 자체 | `legacy_local` + `inherit` | escape hatch |

피해야 하는 조합:

- `legacy_local` + `none`
- 처음부터 `legacy_local`로 시작하기
- private playground 대신 arbitrary shared writable path를 열기

## 2. 제일 많이 쓰는 복붙 예시

### 안전한 기본값

```json
{
  "name": "analyst",
  "goal": "Review incoming issues and prepare safe changes",
  "execution_scope": "workspace",
  "sandbox_profile": "docker_hardened",
  "network_mode": "none",
  "shared_memory_scope": "room",
  "tool_access": {
    "kind": "preset",
    "preset": "coding",
    "also_allow": [
      "masc_team_memory_read",
      "masc_team_memory_write",
      "masc_team_memory_search"
    ]
  }
}
```

### 네트워크가 필요한 빌드/설치

```json
{
  "name": "builder",
  "goal": "Install dependencies and run the required build",
  "execution_scope": "workspace",
  "sandbox_profile": "docker_hardened",
  "network_mode": "inherit",
  "shared_memory_scope": "room",
  "tool_access": {
    "kind": "preset",
    "preset": "coding"
  }
}
```

### keeper TOML overlay

```toml
[keeper]
persona_name = "analyst"
execution_scope = "workspace"
sandbox_profile = "docker_hardened"
network_mode = "none"
shared_memory_scope = "room"
tool_also_allow = [
  "masc_team_memory_read",
  "masc_team_memory_write",
  "masc_team_memory_search",
]
```

### 실제 canary 예시: watchdog

이 브랜치에는 Docker-born 감시 keeper 예시가 같이 들어 있다:

```text
config/personas/watchdog/profile.json
config/keepers/watchdog.toml
```

역할:

- awaiting_verification 상태를 훑는다
- stale verification이나 빠진 evidence를 찾는다
- assignee / verifier에게 다시 돌릴 명령과 필요한 artifact를 남긴다
- 같은 reminder를 상태 변화 없이 반복하지 않는다

재기동 확인:

```bash
# admin token + dashboard URL bootstrap
~/me/scripts/masc dashboard-admin --no-open

# restart only the watchdog keeper
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/watchdog/shutdown \
  -H "Authorization: Bearer $MASC_OPERATOR_TOKEN" \
  -H "X-MASC-Agent: ${MASC_OPERATOR_AGENT:-codex-local-admin}"

curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/watchdog/boot \
  -H "Authorization: Bearer $MASC_OPERATOR_TOKEN" \
  -H "X-MASC-Agent: ${MASC_OPERATOR_AGENT:-codex-local-admin}"
```

## 3. 의미

`docker_hardened`는 keeper shell을 ephemeral Docker sandbox로 돌린다.
운영자가 보통 기억해야 하는 건 이것뿐이다:

- private playground만 writable
- rootfs는 read-only
- `/tmp`는 tmpfs
- `cap-drop=ALL`
- `no-new-privileges`
- 기본 네트워크는 `none`

즉, 처음엔 `docker_hardened`를 켜고, 정말 필요한 경우에만 `network_mode`를 올리면 된다.

## 4. 자주 헷갈리는 것

### `docker_hardened` vs `OAS_CODEX_SANDBOX`

- `docker_hardened`: keeper shell 실행을 Docker로 격리
- `OAS_CODEX_SANDBOX`: `codex exec -s ...`에 들어가는 Codex CLI 자체 sandbox

둘은 독립적이다. 하나를 켰다고 다른 하나가 자동으로 바뀌지 않는다.

### 왜 shared memory는 path가 아니라 tool인가

keeper는 임의 shared writable directory를 여는 대신 typed lane만 쓴다.
공유가 필요하면 `shared_memory_scope="room"`과 `masc_team_memory_*` 도구를 쓴다.

## 5. 운영 규칙

- 시작은 항상 `docker_hardened` + `none`
- 실제 실패 원인이 네트워크 부족일 때만 `inherit`
- Docker가 깨져 있거나, Docker 자체를 디버깅할 때만 `legacy_local`

상세 필드 설명은 [KEEPER-USER-MANUAL.md](./KEEPER-USER-MANUAL.md)와 [KEEPER-FILE-MODEL.md](./KEEPER-FILE-MODEL.md)를 본다.
