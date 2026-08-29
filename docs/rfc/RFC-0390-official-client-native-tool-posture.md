---
rfc: "0390"
title: "Official client 네이티브 도구를 keeper 별로 켜고 끈다"
status: Draft
created: 2026-08-24
updated: 2026-08-24
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC-0390: Official client 네이티브 도구를 keeper 별로 켜고 끈다

## 문제

CLI 구독 런타임(Claude Code, Codex, Antigravity)은 자기 도구를 들고
태어나는데, MASC 는 세 레인 모두에서 이 도구를 하드코딩된 자세로
누르고 masc tool surface 를 MCP 로 주입한다. 자세가 레인마다 다르고,
그 차이가 코드 상수로만 존재해서 운영자가 고를 수 없다.

| 런타임 | 현재 자세 | 근거 |
|---|---|---|
| Claude Code | 네이티브 전부 꺼짐 (`--tools ""`), 설정·스킬도 차단 (`--setting-sources=`) | `runtime_claude_code.ml:973,992` |
| Codex | 네이티브 유지, 읽기 전용 (`permissions=":read-only"`, `approvalPolicy="never"`) | `runtime_codex_app_server.ml:34-35` |
| Antigravity | 내장 도구 유지, `--mode plan` + `--sandbox` | `keeper_antigravity_runtime.ml:472-473` |

이 자세는 사고에서 나온 의도된 설계다 — 레인마다 허용 범위가 몰래
달라지는 일을 겪고 전부 masc 승인 게이트로 수렴시켰다
(`keeper_official_client_host.mli` 의 "Silence is how one lane came to
offer a decision the other refused"). 그 수렴은 지킨다. 문제는 두 가지다.

1. **능력 손실이 조절 불가.** 특히 Claude Code 는 모델이 학습한
   네이티브 하네스(Read/Glob/Grep/WebSearch, 스킬)를 전부 잃고 낯선
   MCP 스키마만 받는다. 도구 호출 품질이 떨어질 수 있는데 되돌릴
   손잡이가 없다.
2. **비대칭이 숨은 기본값.** Codex 는 읽기 가능, Claude Code 는 읽기도
   불가 — 어느 쪽도 선언된 적 없는 차이다.

## 결정

keeper profile TOML 의 `[keeper.tools]` (
자리)에 키 하나를 추가한다.

```toml
[keeper.tools]
native = "read"   # "none" | "read" | "full"
```

### 3단계 의미

| 단계 | 뜻 | Claude Code | Codex | Antigravity |
|---|---|---|---|---|
| `none` | 읽기·효과 전부 masc 도구로만 | `--tools ""` (현행) | **선언 불가** — admission 에서 typed 거부 | **선언 불가** — admission 에서 typed 거부 |
| `read` | 네이티브 읽기 허용, 효과는 masc 도구로만 | `--tools "Read,Glob,Grep"` | `:read-only` (현행) | `--mode plan` + `--sandbox` (현행) |
| `full` | 네이티브 효과까지 허용 | `--tools "default"` | `workspace-write` | `--mode accept-edits` + `--sandbox` 유지 |

- 키가 없으면 **각 런타임의 현행 자세 유지** (Claude Code = `none`,
  Codex = `read`, Antigravity = `read`). 기본값을 하나로 통일하면
  어느 레인의 동작이 조용히 바뀐다 — 그 방식은 택하지 않는다.
- 알 수 없는 값은 TOML 로드를 실패시킨다 (같은
  결). 그 런타임이 실현할 수 없는 값(`none` on Codex/Antigravity — 두
  CLI 는 내장 도구를 끄는 스위치가 없다)은 profile 로드를 실패시키지
  않는다 — keeper↔runtime 배정은 runtime.toml 소관이라 profile 로드
  시점에는 어떤 런타임인지 알 수 없다. 대신 lane admission 시점에
  판정한다.
- Codex `danger-full-access` 와 Antigravity `--sandbox` 해제는 이
  RFC 범위 밖. sandbox 는 도구 가용성과 별개의 안전 바닥으로 남긴다.

### 승인 게이트와의 결합 (핵심 제약)

네이티브 도구 호출은 `ElicitToolApproval` 을 **타지 않는다** — CLI 가
자기 프로세스 안에서 실행하고 MASC 는 stream 이벤트로 사후 관측만
한다. 따라서:

- `full` 은 해당 keeper 의 tool approval mode 가 `Yolo`
  (`keeper_tool_approval_mode`, #30067) 일 때만 레인 admission 을
  통과한다. `Auto` keeper 가 `full` 레인에 배정되면 **그 턴은 죽지
  않는다** — 자세를 `read` 로 낮춰 돌리고, 선언된 `full` 이 이번
  실행에 반영되지 않았다는 사실을 typed 이벤트
  (`masc.keeper.native_posture_degraded`)로 남긴다. 조용한 강등은
  없다는 뜻이지 fail-closed 라는 뜻은 아니다. `read` 는 `full` 보다
  안전하므로 턴을 정지시켜 가며 지킬 가치가 없다. 승인 모드가
  프로세스 메모리 기본값(`Auto`)으로 돌아가는 재시작 상황에서
  `full` keeper 가 매번 턴을 거부당하는 일도 막는다. 승인 모드는
  턴 상태이므로 이 갈래의 이벤트는 **영향받는 턴마다** 발행된다.
- `none` 이 끌 수 없는 클라이언트(Codex/Antigravity)에 배정된 경우는
  성질이 다르다: 턴마다 달라지는 상태가 아니라 profile(선언)과
  runtime.toml(배정)의 **정적 모순**이다. 자세는 클라이언트의
  `read` 바닥으로 돌아가되, 이벤트는 프로세스당 (keeper, client)
  쌍마다 **최초 1회** 발행되고 그 후 조용하다(#30408 리뷰). 모순이
  해소된 해석(선언이 존중되는 해석)이 오면 게이트가 재장전되어,
  다시 생긴 모순은 새로 보고된다.
- `read` 는 효과가 없으므로 `Auto` 에서도 허용한다. 승인 게이트는
  효과를 지키는 장치지 읽기를 지키는 장치가 아니다.
- 네이티브 호출도 transcript/timeline 에는 남는다 (Claude Code
  `tool_use` 이벤트, Codex command execution 이벤트, agy tool step).
  기록에는 **native 출처 표시**를 붙여 masc 게이트를 거친 호출과
  구분한다. 이것은 기존 transcript 표면에 사실을 적는 것이지 새
  카운터가 아니다.

### 세션 정체성

official client 세션 재개는 `tool_surface_sha256` 으로 표면 일치를
검증한다 (`Session_store.reconcile_tool_surface`). native 자세도 세션
정체성의 일부다 — 자세가 바뀐 재개는 같은 세션을 이어받으면 안 되므로
해시 입력 또는 세션 필드에 자세를 접는다.

## 구현 범위

1. `keeper_types_profile_toml_parser` — `native` 키 파싱 + 값·실현
   가능성 검증 (fail-closed).
2. `runtime_claude_code.command` — `none`/`read`/`full` 에 따른
   `--tools` 인자 분기. `--setting-sources=` 는 유지 (스킬 복원은
   별도 논의 — 스킬은 도구가 아니라 프롬프트 표면이다).
3. `runtime_codex_app_server` — `permissions` 프로파일 분기.
   app-server 프로토콜의 `":workspace-write"` 문자열 형태는 구현에서
   공식 문서로 확증한다 (CLI 는 `-s workspace-write` 로 존재 확인됨).
4. `keeper_antigravity_runtime` — `execution_mode` 분기.
5. lane admission 에 approval mode × `full` 결합 검사.
6. 세션 정체성에 자세 반영.

## 검증

- 파서 테스트: 3값 왕복, unknown 값 거부. admission 테스트: 실현 불가
  조합의 typed 거부.
- admission 테스트: `Auto` keeper + `full` 레인 = `read` 로 하향되고
  `masc.keeper.native_posture_degraded` 이벤트 발생(런타임 호출은
  성공, **턴마다**), `Yolo` + `full` = 통과. `none` on
  Codex/Antigravity = `read` 로 하향 + 이벤트 **프로세스당 1회**
  (같은 (keeper, client) 쌍의 후속 턴은 조용; 선언이 존중되는 해석이
  게이트를 재장전).
- 효과 측정: `tool_call_quality_benchmark` 로 같은 과제를
  API 레인 / Claude Code `none` / Claude Code `read` 에 돌려 도구
  호출 성공률·재시도율 비교. "네이티브를 껐더니 멍청해졌는가"는 이
  숫자로 판정하고, 결과에 따라 기본 자세 변경을 별도 RFC 로 올린다.

## 하지 않는 것

- 기본 자세 변경 (측정 전).
- Claude Code 스킬/`--setting-sources` 복원.
- Codex `danger-full-access`, Antigravity sandbox 해제.
- 네이티브 호출을 승인 게이트에 태우는 프록시 — CLI 내부 실행을
  가로챌 수 없으므로 만들 수 없고, 있는 척하는 장식을 만들지 않는다.
