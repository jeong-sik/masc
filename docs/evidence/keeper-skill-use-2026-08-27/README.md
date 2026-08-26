# Keeper Skill 실제 사용 증거

- 날짜(ISO8601): `2026-08-27T01:23:21+09:00`
- 작성자: `Codex`
- 결정 ID: `keeper-skill-use-proof-20260827`
- 적용 대상: `skill-proof-keeper`, `glm-coding.glm-5-turbo`
- 결정 상태: `확정`

## 근거 (Evidence)

- 항목: Keeper가 Skill을 실제로 호출하고, 반환값을 다음 Agent Core 턴에 전달받은 뒤 Skill 지시에 따른 도구를 호출했다.
- 출처: exact-head 서버 `GET /health?full=1`, `GET /api/v1/dashboard/tools?keeper=skill-proof-keeper`, durable activation ledger, Dashboard 브라우저 캡처
- 확인일시: `2026-08-27T01:23:21+09:00`
- 신뢰도: `High`
- 제한조건: 격리 base path `/private/tmp/masc-skill-proof.NVbd5m`, 서버 포트 `9600`, 런타임 `glm-coding.glm-5-turbo`

## 실행 정체성

| 항목 | 값 |
|---|---|
| source HEAD | `ccf58176ab2ff10f0daee1932c4e171ba3daaadd` |
| embedded binary commit | `ccf58176ab2ff10f0daee1932c4e171ba3daaadd` |
| runtime repo HEAD | `ccf58176ab` |
| executable | `.worktrees/feat-skill-dashboard-timeline/_build/default/bin/main_eio.exe` |
| effective base path | `/private/tmp/masc-skill-proof.NVbd5m` |
| effective MASC root | `/private/tmp/masc-skill-proof.NVbd5m/.masc` |
| Skill ledger revision | `92dfef0eee0c9fcb406cb1c5c71bc9e696eb87796ed3b3dea790dfdd5f258e9c` |

## 정량 결과

| 단계 | 횟수 | 직접 증거 |
|---|---:|---|
| Agent Core에 제공된 instruction Skill | 1 | `effective_keeper_surface.instruction_skills` |
| `keeper_skill` 호출 | 5 | ledger activation 5건 |
| Skill 본문 반환 | 3 | `served_content.kind = skill_body` |
| 지연 로드한 Skill 리소스 반환 | 2 | `served_content.kind = skill_resource` |
| 다음 Agent Core 턴에 반환값 전달 | 5 | activation 5건 모두 `delivery` 존재 |
| 전달된 턴에서 후속 도구 행동 | 2 | `keeper_time_now` action 2건 |
| 잘못된 상태 전이 | 0 | `summary.invalid_transitions` |

두 리소스 호출은 모두 `references/PROOF.md`의 37바이트를 반환했다. 두 호출의 SHA-256은 `753444375cdae636cedba8ca38acd0e55f5865c4ef9bad5e63525ffbc0305598`로 같았다.

첫 실행은 Agent Core 5턴에서 본문을 읽고 7턴에서 리소스를 읽었다. 리소스 결과가 8턴에 전달되자 같은 8턴에서 `keeper_time_now`를 호출했다. 두 번째 실행도 10턴 본문 호출, 11턴 리소스 호출, 12턴 전달 및 `keeper_time_now` 호출 순서로 끝났다.

## 검증 (Verification)

- 1차: [Agent Skills specification](https://agentskills.io/specification)의 progressive disclosure 단계와 [Pi Skills 문서](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md)를 코드 계약과 대조했다.
- 2차: `curl -fsS 'http://127.0.0.1:9600/health?full=1'`로 source, binary, server, base path가 같은 실행인지 확인했다.
- 3차: `curl -fsS 'http://127.0.0.1:9600/api/v1/dashboard/tools?keeper=skill-proof-keeper'`와 durable ledger를 대조하고 브라우저에서 같은 숫자를 확인했다.
- 재현 결과: 성공. Dashboard의 `data-testid=skill-use-summary`는 `offered 1 invoked 5 bodies 3 resources 2 delivered 5 actions 2 invalid 0 compositions 0/0/0`을 표시했다.

브라우저 캡처: [dashboard-skill-use.png](dashboard-skill-use.png)  
캡처 SHA-256: `d0f439e28fe4b5cebbe1bc79895b46b1df808dde3198f3d3ae13c8f7b2a77ea7`

## TUI exact-head 재검증

TUI의 `--base-path`와 부모 셸의 `MASC_BASE_PATH`가 다를 때 저장소 읽기가 부모 환경으로 새는 문제를 #30904로 재현했다. `29511933ac362e4d2669176144d2835e34da0de3`에서 CLI가 정한 경로를 프로세스의 단일 base path로 확정한 뒤 다시 측정했다.

| 항목 | 값 |
|---|---|
| source HEAD | `29511933ac362e4d2669176144d2835e34da0de3` |
| server embedded commit | `29511933ac362e4d2669176144d2835e34da0de3` |
| runtime repo HEAD | `29511933ac` |
| server executable SHA-256 | `592765ba13144bb33d117baff6a2f4b8095206251eedc2e443cdc0b2ce304603` |
| TUI executable SHA-256 | `4ffa5035fdd6c46d99f57663d58e6bd79ba1ac16b5f6167990ceb46dd1b51ab7` |
| effective base path | `/private/tmp/masc-skill-proof.NVbd5m` |
| running Keeper | `skill-proof-keeper` (1/1) |

재현 회귀는 부모 환경의 별도 base path에 `env-only` Keeper만 두고 CLI 작업공간에는 `alpha`, `beta`만 둔다. `test_tui_keyboard_input.py ... cli-base-path` 실행은 CLI 작업공간의 `alpha`를 선택했고 `env-only`를 표시하지 않아 통과했다.

같은 HEAD의 서버와 TUI를 ttyd로 연결한 브라우저 실측에서는 `skill-proof-keeper` 한 명을 선택했다. Tools 화면은 `offered=1 invoked=5 bodies=3 resources=2 delivered=5 actions=2 invalid=0`과 다섯 호출의 ID, Agent Core 턴, 본문/리소스 SHA-256, 전달 턴, 후속 `keeper_time_now` 행동을 표시했다.

TUI 캡처: [tui-skill-use.png](tui-skill-use.png)
캡처 SHA-256: `cd272f2f349f89d399d876911957fef790b71371e50e7553898b25161620b050`

## 불확실성 (Uncertainty)

- 미확인 항목: 이 기록은 GLM 런타임 한 개의 실제 Keeper 실행을 증명한다. 다른 provider/runtime 조합은 이 기록의 범위가 아니다.
- 영향: provider별 공식 클라이언트가 ToolResult를 다르게 전달하면 별도 실행 증거가 필요하다.
- 추가 확인 필요: 런타임 매트릭스 검증은 각 provider의 exact-head 실행 기록으로 따로 쌓는다.

## 적용범위 (Scope)

- 영향 받는 영역: Skill 호출 원장, 지연 리소스 읽기, Agent Core 전달 관측, 후속 행동 관측, Dashboard 표시
- 제약/배제: 이 원장은 행동을 허용하거나 막는 Gate가 아니다. 관측된 사실만 저장한다.
- 롤백 조건: source, binary, server, base path 중 하나라도 다른 실행으로 확인되면 이 증거를 폐기하고 다시 측정한다.
