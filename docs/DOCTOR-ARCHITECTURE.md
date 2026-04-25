---
status: design
last_verified: 2026-04-23
code_refs:
  - sidecars/shared/gate_shared/doctor.py
  - sidecars/discord-bot/src/doctor.py
  - bin/main_eio.ml
  - lib/auth_doctor.ml
  - lib/doctor_dispatch.ml
  - lib/server/server_routes_http_routes_dashboard.ml
  - dashboard/src/components/doctor-panel.ts
  - dashboard/src/components/lab-inspector.ts
  - dashboard/src/tab-refresh.ts
---

# Doctor 아키텍처

MASC 의 각 런타임 계층(OCaml 서버 / Python sidecar / 대시보드)이
**동일한 진단 계약** 을 공유하도록 하는 설계 문서.

`flutter doctor`, `brew doctor`, `rustup check`, `npm doctor` 의 공통 패턴을
분해·일반화한 결과물이다.

## 왜 필요한가

운영 중 가장 자주 반복되는 질문은 언제나 같다:

- "왜 바인딩이 안 돼요?"
- "이 커넥터, 지금 살아있나요?"
- "이 설정 파일이 진짜 반영된 게 맞나요?"

현재는 각 질문마다 서로 다른 엔드포인트·로그·스크립트를 엮어서 설명해야 한다.
Doctor 아키텍처는 이 질문을 **정해진 형식의 하나의 명령**으로 압축한다:

```
$ ./run.sh doctor
# Discord Sidecar Doctor

[✓] python >= 3.11  (3.12.4)
[✓] discord.py installed  (2.4.0)
[!] DISCORD_ADMIN_ROLE_ID
    ↳ admin role 이 비어 있어 바인딩 명령 권한이 누구에게나 열립니다.
      hint: 서버에서 역할을 만들고 ID 를 복사해 env 에 기록
[✓] gate reachable  (http://localhost:8935/api/v1/gate/health → 200)
[✗] binding paths writable
    ↳ binding store: /var/gate (permission denied)
      hint: 상위 디렉터리 권한을 확인하거나 경로를 명시적으로 설정
      fix: 접근 권한이 없는 상위 디렉터리에 0755 시도
        auto-fix 가능: doctor --fix

summary: 3 ok, 1 warn, 1 error
```

## 계약

### Severity 5단계

| 단계 | 의미 | exit code 기여 |
|------|------|----------------|
| `ok` | 정상 | 0 |
| `info` | 참고 정보 | 0 |
| `warn` | 일부 기능 비활성 / 권장사항 누락 | 1 |
| `error` | 실행 불가 | 2 |
| `skip` | 전제가 부족해 검사를 건너뜀 | 0 |

우선순위: `error > warn > (ok, info, skip)`. 하나라도 `error` 가 있으면 exit 2.

### Check 데이터 모델

```python
@dataclass(frozen=True, slots=True)
class Check:
    name: str            # 화면에 표시할 짧은 이름
    severity: Severity
    message: str         # 사람이 읽는 설명 (warn/error 에서만 렌더됨)
    detail: str = ""     # 수치·경로·버전 같은 보조 정보
    hint: str | None = None        # 운영자가 직접 해야 할 조치
    auto_fix: AutoFix | None = None
    tags: tuple[str, ...] = ()
```

- `hint` = "이거 해라" (운영자가 직접).
- `auto_fix` = "내가 해주겠다" (doctor --fix 로 실행).

### AutoFix

```python
@dataclass(frozen=True, slots=True)
class AutoFix:
    description: str
    command: str | None = None      # 복붙용 쉘 예시
    callback: Callable[[], Awaitable[None]] | None = None
```

두 축 중 하나만 채워도 된다. `callback` 이 있으면 `doctor --fix` 에서
실제 실행되고, 동일한 doctor 가 다시 한 바퀴 돌면서 결과를 재검증한다.

## 출력 포맷

### pretty (default)

- `[✓]` / `[!]` / `[✗]` / `[i]` / `[·]` (skip)
- TTY 일 때만 ANSI 색. 파이프/리다이렉트면 plain.
- warn/error 만 세부 라인을 출력해서 정상 체크는 한 줄로 끝난다.

### json

```json
{
  "title": "Discord Sidecar Doctor",
  "checks": [
    {
      "name": "gate reachable",
      "severity": "ok",
      "detail": "http://localhost:8935/api/v1/gate/health → 200",
      "message": "",
      "hint": null,
      "auto_fix": null,
      "tags": []
    }
  ],
  "summary": {"ok": 4, "info": 0, "warn": 1, "error": 0, "skip": 0}
}
```

대시보드 패널과 CI 스모크 테스트가 이 포맷을 파싱한다.

## 현재 커버리지

| 계층 | Doctor | 구현 상태 |
|------|--------|-----------|
| OCaml 서버 | `masc-mcp doctor config` — 베이스 경로 / 활성 config root | 운영 중 (`docs/CONFIG-DOCTOR.md`) |
| OCaml 서버 | `masc-mcp doctor auth` — auth mode / admin bearer readiness / role mismatch / Codex MCP bearer env | 운영 중 (`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`) |
| Discord sidecar | `masc-mcp doctor sidecar discord` ↔ `python -m src doctor` | 운영 중 |
| Slack sidecar | `masc-mcp doctor sidecar slack` ↔ `python -m src doctor` | 운영 중 |
| Telegram sidecar | `masc-mcp doctor sidecar telegram` ↔ `python -m src doctor` | 운영 중 |
| iMessage sidecar | `masc-mcp doctor sidecar imessage` ↔ `python -m src doctor` | 운영 중 |
| CLI connector | `masc-mcp doctor sidecar cli` ↔ `python -m src doctor` | 운영 중 |
| 전 계층 fan-out | `masc-mcp doctor all` (+ `--json` envelope) | 운영 중 |
| 대시보드 Backend | `GET /api/v1/dashboard/doctor` | 운영 중 (phase 1 subprocess) |
| 대시보드 Frontend | Lab → inspector → Doctor sub-tab | 운영 중 |

### Dispatch

```
masc-mcp doctor                     # default → config (backward-compat)
masc-mcp doctor config              # base path / config root 진단
masc-mcp doctor auth                # auth/bearer/role mismatch + Codex MCP bearer env 진단
masc-mcp doctor sidecar <name>      # python -m src doctor 를 해당 sidecar 디렉터리에서 실행
masc-mcp doctor sidecar <name> --json
masc-mcp doctor all                 # config + 5 sidecar 연쇄 실행 + aggregate 요약
```

지원 sidecar 이름: `discord`, `slack`, `telegram`, `imessage`, `cli`.

`doctor all` 은 현재 `config + registered sidecars` aggregate 만 포함한다.
`auth` 는 로컬 operator 증상(`cannot CanAdmin`, dev-token bootstrap, worker/admin role drift)
을 다루는 명시적 서브커맨드로 유지한다.

구현은 `lib/doctor_dispatch.ml` (pure mapping + `aggregate_exit_code`) +
`bin/main_eio.ml` 의 `doctor_sidecar_exit` / `doctor_all_exit`. Python 실행
파일은 `MASC_PYTHON` env 로 override 할 수 있고, 기본값은 `python3`.
stdout/stderr 은 그대로 forward 되며 exit code 도 그대로 전달된다.

`doctor all` 은 각 Doctor 의 stdout 을 그대로 흘려보낸 뒤 마지막에

```
========================================
합계: 6 Doctor · 정상 3 · 경고 2 · 오류 1
config=정상 · discord=경고 · slack=경고 · telegram=오류 · imessage=정상 · cli=정상
========================================
```

형태의 aggregate 요약을 붙인다. 종합 exit code 는 `max(all rcs)`
(`error>warn>ok`) 로 계산되며, 종료 신호나 알 수 없는 rc (`<0` 또는 `>2`) 는
`error` 로 상향 처리된다.

`doctor all --json` 은 envelope 형태로 모든 Doctor 의 원본 JSON shape 을
보존한 채 취합한다. 대시보드 `/api/v1/dashboard/doctor` 패널에서 이 포맷을
파싱한다:

```json
{
  "title": "MASC Doctor (전 계층)",
  "doctors": [
    {
      "name": "config",
      "kind": "config",
      "exit_code": 1,
      "payload": { "status": "warn", "init_state": "initialized", ... }
    },
    {
      "name": "discord",
      "kind": "sidecar",
      "exit_code": 2,
      "payload": { "title": "Discord Sidecar Doctor", "checks": [...], "summary": {...} }
    }
  ],
  "summary": { "total": 6, "ok": 3, "warn": 2, "error": 1 },
  "exit_code": 2
}
```

- `kind` 는 `"config"` | `"sidecar"` 2종 — UI 가 payload shape 을 구분.
- `payload` 는 각 doctor 의 기존 JSON 을 그대로 담는다 — client 가 기존
  schema 를 재활용할 수 있게.
- sidecar 가 비-JSON stdout 을 뱉거나 subprocess 가 crash 하면 payload 는
  `{"raw": ..., "parse_error": ...}` 또는 `{"error": ...}` 로 degrade 된다
  (exit_code 는 2).

## Discord Sidecar Doctor 체크 목록

| 이름 | 심각도 결정 기준 |
|------|------------------|
| `python >= 3.11` | 3.11 미만이면 error |
| `discord.py installed` | 미설치 error, 2.4 미만 warn |
| `DISCORD_BOT_TOKEN` | 미설정 error, 40자 미만 warn |
| `GATE_BASE_URL` | 정보 표시 (항상 ok) |
| `GATE_API_TOKEN policy` | 비-loopback 인데 토큰 없으면 error |
| `DISCORD_ADMIN_ROLE_ID` | 빈 값이면 warn (권한 가드 없음) |
| `DISCORD_KEEPER_MAP parses` | JSON 오류 error, 빈 맵 warn |
| `gate reachable` | 연결 실패 error, 4xx warn |
| `keeper names exist` | gate keepers 목록에 없는 이름이면 error |
| `binding paths writable` | 쓰기 불가 error (`--fix` 로 chmod 시도) |
| `legacy runtime paths` | `.masc/connectors/discord/*` 잔존 시 warn (자동 이관 안내) |

## 확장 규칙

새 Doctor 를 추가할 때 지켜야 하는 원칙:

1. **독립성**: 각 체크는 다른 체크의 성공을 가정하지 않는다.
   전제가 부족하면 `Severity.skip` 을 돌려준다.
2. **읽기 전용이 기본**: `--fix` 가 오기 전까지 어떤 체크도
   파일을 쓰거나 env 를 변경하지 않는다.
3. **민감정보는 마스크**: 토큰·비밀번호는 앞뒤 4자만 노출한다.
4. **네트워크 타임아웃은 3초**: 체크 하나가 run 전체를 막지 않도록.
5. **한국어 설명 우선**: hint/message 는 운영자가 바로 따라할 수 있는
   구체적인 행동으로 쓴다 ("설정 확인" 같은 모호한 문장은 금지).

## 대시보드 패널

### Backend endpoint (phase 1 — 운영 중)

`GET /api/v1/dashboard/doctor` 가 `masc-mcp doctor all --json` 과 동일한
envelope 을 반환한다 (참조: [Dispatch 섹션](#dispatch)).

```
GET /api/v1/dashboard/doctor
→ 200
{
  "title": "MASC Doctor (전 계층)",
  "doctors": [{name, kind, exit_code, payload}, ...],
  "summary": {total, ok, warn, error},
  "exit_code": 0|1|2
}
```

구현은 단순한 subprocess forward 로 시작했다:
- Server handler 가 `Sys.argv.(0) doctor all --json` 을 `Unix.open_process_in`
  으로 spawn 해 stdout 을 HTTP body 에 그대로 전달.
- Server 는 repo root 에서 실행돼야 CLI 가 `sidecars/` 를 찾을 수 있다.
  이는 phase 2 에서 library 추출 + Eio.Process ~cwd 로 제거 예정.
- 실패 시 `{error, hint}` 로 5xx 반환 — 운영자가 원인 즉시 확인 가능.

### Frontend panel (운영 중 — phase 1)

Lab 탭 → inspector → **Doctor** sub-tab 에서 확인한다. 구현:

- `dashboard/src/components/doctor-panel.ts` — types (`DoctorEnvelope`,
  `DoctorEntry`, `DoctorSummary`), pure helpers (`severityLabel`,
  `severityChipClass`, `summaryLine`, `doctorHeading`), async resource
  (`loadDoctor` / `refreshDoctor`), React 컴포넌트
  (`<DoctorPanel />`, `<DoctorEntryCard />`).
- `dashboard/src/components/lab-inspector.ts` — "Doctor" sub-tab 등록.
- `dashboard/src/tab-refresh.ts` — inspector refresh 파이프라인에
  `refreshDoctorSurface` 합류. 사용자가 Lab 돌아올 때 자동 갱신.

현재 UI:

- Summary header — "N Doctor · 정상 X · 경고 Y · 오류 Z" + 새로고침 버튼
- 6 doctor grid (config + 5 sidecar) — 각자 severity chip + exit code

Follow-up (phase 2):

- Drill-down — sidecar `checks[]` / config `warnings[]` 펼침 (`kind`
  discriminator 로 payload 분기)
- `--fix` 버튼 — `callback_available` 인 check 한해 AutoFix trigger
- SSE live update — 현재는 inspector 복귀 시 refresh

### Phase 2 (후속 — in-process)

- `bin/main_eio.ml` 의 envelope 조립 로직을 `lib/doctor_dispatch.ml` 로
  추출 (`build_envelope ~base_path ()`)
- `capture_sidecar_json` 의 `Sys.chdir` 을 `Eio.Process.spawn ~cwd` 로 교체
  (server 멀티스레드에서 chdir race 방지)
- Server endpoint 가 subprocess 대신 in-process 함수 호출 → PATH / cwd 의존
  제거 + latency 절감

## 참고

- `docs/CONFIG-DOCTOR.md` — OCaml 쪽 doctor SSOT
- `docs/CONNECTOR-CONFIG-SCHEMA.md` — env 필드 레퍼런스
- `docs/CONNECTOR-UI-DESIGN.md` — 대시보드 UX 가이드
