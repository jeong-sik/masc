---
status: draft
date: 2026-08-25
source_revision: 75caa128eff993417752883e6a72f976fca804cc
scope: official-client native tools, effective Keeper tool surface, Skills, runtime TOML, Goal hierarchy, Context truth
---

# Official Client Tool and Context Truth

## One sentence

Claude Code, Codex, Antigravity가 실제로 받은 native/MASC tool surface와 실제로
관측한 context usage를 같은 typed evidence로 남기고, TUI가 전역 선언이 아니라
선택한 Keeper의 effective truth를 보여주게 한다.

## Why now

2026-08-25 source + live-state audit에서 실행 제한 자체는 확인됐다.

| Runtime | Keeper default | Runtime enforcement |
|---|---:|---|
| Claude Code | `native = "none"` | `--tools ""`; `read`는 `Read,Glob,Grep`; `full`은 `default` |
| Codex app-server | `native = "read"` | `permissions=:read-only`; `full`은 `:workspace` (아래 주) |
| Antigravity | `native = "read"` | `--mode plan --sandbox`; `full`은 `accept-edits --sandbox` |

> 주 (2026-09-04, masc#33065): 이 표는 원래 `full`을 `:workspace-write`로 적었고
> 코드도 그 값을 보냈다. 그 값은 profile id가 아니라 `SandboxMode`라서 어느
> 프로필도 가리키지 않는다. codex-cli 0.153.2의 `permissionProfile/list`가 답하는
> id는 `:read-only`, `:workspace`, `:danger-full-access` 셋뿐이다. `full`을 쓰는
> keeper가 없어 라이브에서 드러난 적은 없다.

그러나 다음 projection은 실행 truth를 잃는다.

1. Native tool call은 MASC dynamic-tool callback을 지나지 않아 transcript/timeline에서
   사라진다.
2. Antigravity의 conversation 누적 usage가 마지막 요청의 context occupancy로
   투영된다. Live `analyst`는 최근 8개 완료 턴에서 `795.7% -> 831.1%`로 증가했다.
3. `/api/v1/dashboard/tools?actor=...`는 actor를 cache key에만 사용하고 inventory
   생성에서는 버린다. TUI Tools는 Keeper별 `tools.groups`, `native`, Skills composition을
   보여주지 않는다.
4. Keeper config API는 `tools.groups`와 `tools.native`를 편집할 수 없고,
   structured runtime protocol 목록은 Antigravity를 숨긴다.
5. Goal은 더 이상 parent를 저장하지 않는데 `masc_goal_upsert` help는 parent linkage를
   지원한다고 말한다.
6. Task skill 이름은 존재 여부와 단일 path-segment 문법을 검증하지 않는다.
7. TUI Context는 로컬 `base_path`, Config/Tools는 loopback server의 base path에서 읽지만
   두 path의 일치를 검증하지 않는다.

## Truth hierarchy

동일 사실이 여러 표면에 나타날 때 아래 순서로 판정한다.

1. **Provider event / CLI self-report**: provider가 실제 실행·사용량으로 보고한 값.
2. **Turn-scoped normalized observation**: MASC가 provider event를 typed event로 정규화한 값.
3. **Durable turn evidence**: raw trace, TurnRecord, official-client session record.
4. **Effective Keeper projection**: profile + runtime assignment + skill catalog + descriptor surface.
5. **Operator UI**: 위 authority를 읽는 projection. 독립 기본값이나 추정치를 만들지 않는다.

`runtime.toml`, Keeper TOML, tool descriptor, SKILL.md는 각각 선언 authority다. 이들이
실행됐다는 증거는 provider event/TurnRecord에서만 나온다.

## Architecture

```text
Keeper TOML tools.native/tools.groups       runtime.toml assignment
                 |                                  |
                 +------------ resolve ------------+
                                      |
SKILL.md catalog -> composition tools -> Effective_keeper_tool_surface
                                      |
                                      +--> provider request digest
                                      +--> Tools API/TUI
                                      +--> session tool_surface_sha256

Official CLI stream
  +-- text ---------------------------------> assistant stream
  +-- MASC dynamic/MCP tool ----------------> masc_tool event
  +-- native tool --------------------------> native_tool event
  +-- usage --------------------------------> usage classification
                                                    |
                                   per_request / cumulative / unavailable
                                                    |
                                      TurnRecord + Context projection
```

## Decisions

### D1. Native tools become typed observation events

각 runtime adapter의 stream event에 native tool 시작/종료를 추가한다.

```ocaml
type native_tool_event =
  { call_id : string option
  ; tool_name : string
  ; input_summary : Yojson.Safe.t option
  ; output_summary : string option
  }

type stream_event +=
  | Native_tool_started of native_tool_event
  | Native_tool_finished of native_tool_event
```

- `origin = native`는 event variant에서 파생한다. 문자열 휴리스틱으로 추론하지 않는다.
- secret/raw output 전체를 새로 저장하지 않는다. provider가 제공한 bounded summary만
  기록한다.
- MASC MCP/dynamic tool은 기존 event를 유지한다.
- native `full`도 승인 gate를 거쳤다고 표시하지 않는다. 관측과 승인은 다른 축이다.
- provider가 tool identity를 주지 않는 경우 가짜 이름을 만들지 않고 typed
  `Native_tool_observation_unavailable`을 남긴다.

### D2. Usage semantics must be explicit

Provider usage는 다음 closed sum으로 정규화한다.

```ocaml
type usage_scope =
  | Per_request
  | Conversation_cumulative
  | Usage_scope_unavailable
```

Context occupancy는 `Per_request`인 `input_tokens`만 사용한다.

- Antigravity가 cumulative만 제공하면 우선 occupancy를 `not_observed`로 내린다.
- 이전 cumulative sample과 같은 durable session identity가 있을 때만 delta 계산을
  허용한다. restart/resume 경계에서 delta를 이어 붙이지 않는다.
- `input_tokens > context_window`를 clamp하지 않는다. contract violation 또는 cumulative
  evidence로 분류하고 원값을 diagnostics에 보존한다.
- Codex처럼 usage를 제공하지 않는 runtime은 `turn_record_without_usage`를 유지한다.

### D3. Tools screen has two named products

1. **Registered Catalog**: 전역 descriptor/config inventory.
2. **Effective Keeper Surface**: 선택 Keeper의 현재 turn에 들어갈 표면.

Effective projection은 아래를 함께 반환한다.

- Keeper name and trace identity
- runtime id and official-client kind
- resolved native posture and whether `none/full` is admissible
- declared tool groups and resulting model-visible descriptors
- instruction skills named by the current task
- composition skills materialized as tools
- direct/public/keeper/native origin
- digest equal to the session store's `tool_surface_sha256`

Actor query를 지원할 수 없으면 actor parameter를 제거한다. actor별 cache key만 남기는
형태는 금지한다.

### D4. Configuration editing follows ownership

- `runtime.toml`: provider/model/binding/assignment만 편집한다.
- Keeper TOML: `tools.groups`, `tools.native`, instruction/profile fields를 편집한다.
- Keeper config API에 typed nested tools patch를 추가한다.
- `native = full` 저장 전에는 현재 approval mode가 Yolo인지 preview에 표시한다. 저장
  자체가 실행 승인으로 읽히지 않게 실제 admission은 계속 runtime 시작 시 검사한다.
- Antigravity structured editor는 file credential, timeout, agent, effort를 모두 표현할 수
  있을 때만 노출한다. 부분 materialization은 하지 않는다.

### D5. Goal hierarchy language is hard-cut to current truth

현재 Goal schema가 flat이면 `parent linkage` 문구와 dead depth calculation을 제거한다.
Hierarchy를 다시 제품 기능으로 만들지는 않는다. parent field를 되살리는 것은 별도 RFC다.

### D6. Skill references are validated at authoring and turn admission

- Task authoring: skill name은 non-empty single path segment여야 한다.
- task create 시 존재하는 `SKILL.md`와 name agreement를 확인한다.
- 기존 task의 skill이 이후 삭제될 수 있으므로 turn admission에서도 typed error를 낸다.
- instruction skill을 읽으라는 prompt가 있으면 effective surface에 `keeper_skill`이 있어야
  한다. 본문은 이 전용 도구가 카탈로그에서 직접 서빙한다.
- 모든 unrelated skill을 매 turn 실패시키는 global coupling은 별도 task로 측정 후 결정한다.

### D7. TUI refuses mixed workspace truth

`/health?full=1`의 effective base path와 TUI local base path를 canonicalize해 비교한다.
다르면 Context/metrics/local mutation을 로드하지 않는다. 거절은 읽는 자리마다
(`load_local_workspace_if_safe`, `load_live_context_if_safe`,
`load_keeper_logs_if_safe`, `handle_composer_key`, `handle_paste`) 일어나고,
이전에 읽어둔 것은 `clear_local_workspace`가 비운다.

화면 전체를 blocker로 덮지 않는다. 덮으면 Overview·Keepers·Board·Changes 처럼
서버 응답만 읽는 화면까지 같이 사라지는데, 그 화면들은 이 로컬 파일 시스템을
건드리지 않는다. 불일치는 surface header 배지(`[workspace mismatch]`)와 footer의
`MISMATCH local <path>` 로 알린다. 키 입력도 막지 않는다 — 로컬을 건드리는 동작은
위 다섯 자리에서 이미 거절되고, 나머지는 서버가 답한 사실이다.

## Work packages and MASC tasks

### WP1 — Native tool provenance

- Claude `tool_use`, Codex command/file-change item, Antigravity tool step를 typed native event로
  낮춘다.
- Keeper stream bridge와 raw trace/TurnRecord evidence에 `origin=native`를 보존한다.
- `native=read/full` fixture에서 native tool 1회가 보이고 MCP tool과 혼동되지 않는 테스트.

**Completion trigger**: 세 runtime fixture 각각에서 native tool count `1`, MASC tool count
`0` 또는 별도 expected count, unknown-origin count `0`; `full` event에 approval-passed 표기가
없다.

### WP2 — Context usage scope

- usage scope를 runtime result와 TurnRecord boundary에 전달한다.
- Antigravity cumulative usage를 occupancy에서 제외하거나 same-session delta로 변환한다.
- TUI는 unavailable reason과 raw cumulative diagnostics를 구분한다.

**Completion trigger**: 모든 measured Context ratio가 `[0.0, 1.0]`; 범위 밖 raw sample은
clamp 없이 typed unavailable; live `analyst`의 `831.1%`가 다시 나타나지 않는다.

### WP3 — Effective Tools/Skills projection

- selected Keeper effective surface API와 decoder/render를 추가한다.
- global catalog와 effective surface를 명시적으로 분리한다.
- composition skill tools와 instruction skill의 전용 `keeper_skill` 표면을 포함한다.

**Completion trigger**: 서로 다른 `tools.groups/native/skills` fixture 두 Keeper가 서로 다른
tool rows와 서로 다른 digest를 보이며, runtime bundle의 actual names와 projection names가
정확히 같다.

### WP4 — Typed config editing

- Keeper tools patch schema/preview/save/readback.
- Antigravity structured provider materialization 또는 명시적 unsupported reason.

**Completion trigger**: `none/read/full` round-trip, invalid value rejection, Codex/Antigravity
`none` admission rejection, Auto+full rejection, Yolo+full acceptance가 API fixture에서 증명된다.

### WP5 — Hierarchy and Skill contract cleanup

- flat Goal help/render cleanup.
- skill path segment/existence/readability validation.

**Completion trigger**: Goal help에 parent claim `0`; `../x`, missing skill, mismatched
frontmatter, Read-withheld conflict가 각각 typed rejection; valid skill task succeeds.

### WP6 — Workspace identity guard

- local/server base path compare, per-read refusal, and a header/footer notice.

**Completion trigger**: matching paths load Context; mismatched paths perform zero local
Context/metrics reads and display both canonical paths.

## Measurement commands

Focused checks only; full suite belongs to PR CI.

```bash
scripts/dune-local.sh build \
  test/test_runtime_claude_code.exe \
  test/test_runtime_codex_app_server.exe \
  test/test_keeper_antigravity_runtime.exe \
  test/test_keeper_context_observation_projection.exe \
  test/test_tui_decode.exe

scripts/dune-local.sh exec test/test_runtime_claude_code.exe
scripts/dune-local.sh exec test/test_runtime_codex_app_server.exe
scripts/dune-local.sh exec test/test_keeper_antigravity_runtime.exe
scripts/dune-local.sh exec test/test_keeper_context_observation_projection.exe
```

Live evidence query:

```bash
tail -n 20 <base>/.masc/keepers/analyst/turn-records/YYYY-MM/DD.jsonl \
  | jq -s 'map({turn_ref,input_tokens,context_window,ratio:
      (if (.input_tokens != null and .context_window > 0)
       then (.input_tokens/.context_window) else null end)})'
```

The live trigger requires a newly built exact-revision binary and newly completed Antigravity
turns. Historical rows remain evidence of the prior bug and are not rewritten.

## Rollout order

1. WP1 native observation and WP2 usage scope.
2. WP3 effective surface projection.
3. WP4 editor support.
4. WP5 stale hierarchy and skill validation.
5. WP6 workspace guard.
6. Exact-head CI, then an isolated live Keeper run and TUI screenshot/evidence bundle.

## Non-goals

- Native tool calls를 MASC approval proxy로 가로채는 것.
- historical TurnRecord rewrite or migration.
- Goal parent field 복원.
- Claude/Codex/Antigravity 기본 native posture 변경.
- provider가 주지 않은 usage/tool identity를 추정해 채우는 것.
- global full Dune suite를 각 work package마다 반복하는 것.

## Completion authority

이 설계의 완료는 코드 존재가 아니라 아래 evidence bundle로만 선언한다.

1. exact source revision and binary digest
2. focused tests per work package
3. CI required checks green
4. newly generated official-client raw trace + TurnRecord
5. effective tool surface API/TUI capture for at least Claude, Codex, Antigravity Keeper
6. all completion triggers above recorded as pass/fail, with no `unknown`
