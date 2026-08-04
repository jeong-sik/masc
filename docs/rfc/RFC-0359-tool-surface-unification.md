# RFC-0359 — 도구 표면 단일화: SSOT 레지스트리 + 기본 동사 + ToolSearch 발견

- Status: Draft
- Created: 2026-08-04
- Author: Vincent (owner ruling) + Claude
- Related: RFC-0357 (Withdrawn, admission gate 숙청 — 같은 뿌리: 표면마다 재정의), #26737 (완료 판정 우회)

## 0. Owner ruling (이 RFC의 헌법)

- keeper 에게 **자율**을 준다. 제약이 아니다.
- 기본 동사(`Read`/`Grep`/`Write`/`Execute`)가 있고 나머지는 **검색으로 발견**하면 된다.
- tool profile(엔드포인트별 정적 필터)은 인증이 이미 경계이므로 **중첩 게이트 = 숙청 대상**.
- 죽은 개념·중복은 흔적을 남기지 않는다.

## 1. 실측 (2026-08-04, live localhost:8935 + activity-events)

### 1.1 개수: "150"은 유령. 표면마다 다르다

| 표면 | 실측 노출 | 근거 |
|---|---|---|
| `/mcp` (MCP 클라이언트) | **43** | live `tools/list`, `_meta.totalCount:43` |
| keeper 모델 표면 | **~61** | `keeper_tool_descriptor.ml` model_visible |
| `mcp_server_eio_tool_profile.ml` 주석 | "~150" | **낡은 주석 값 — 실재 안 함** |

SSOT 없음. 문서·표면·주석이 제각각.

### 1.2 이름: 한 표면 안에 4중 규칙

keeper 표면 도구 후보 109개 중:

| 개수 | 스타일 | 예시 |
|---|---|---|
| 46 | `keeper_*` | keeper_board_list, keeper_task_claim |
| 40 | `masc_*` | masc_status, masc_transition |
| 15 | `masc_keeper_*` (이중 접두어) | masc_keeper_up, masc_keeper_delegate |
| 8 | Bare-Verb | Read, Grep, Write, Edit, Execute, Search, WebFetch, WebSearch |

기본 동사 8개는 **이미 존재**한다. 없는 게 아니라 그 위에 100개가 얹혀 있다.

### 1.3 중복: 같은 기능이 두 이름으로

**명명 변주 12쌍** (접두어만 다른 동일 기능):
```
board_list    → keeper_board_list  + masc_board_list
board_post    → keeper_board_post  + masc_board_post
board_comment → keeper_board_comment + masc_board_comment
broadcast     → keeper_broadcast   + masc_broadcast
status        → masc_keeper_status + masc_status
reset         → masc_keeper_reset  + masc_reset
… (board 계열 8쌍 + 4)
```

**표면 간 완전 중복 23개**: `/mcp` 와 keeper 양쪽에 동일 이름 노출 (masc_status, masc_transition, masc_plan_* …).

### 1.4 실사용: 중복의 한쪽은 죽어 있다

keeper 어제 tool_exec 상위 (13종만 사용, 96%가 관측형):
```
1070 keeper_surface_read
1016 keeper_tasks_list
 857 keeper_board_list      ← masc_board_list: 0회
 522 masc_status            ← masc_keeper_status: 1회
  57 Execute                ← 유일 실행 도구, 1.6%
```

각 중복쌍에서 실제로 불리는 이름은 **하나뿐**. 다른 쪽은 노출만 되고 0회.

## 2. 근본 원인

board·task 등의 기능이 **두 소비자(MCP 클라이언트 / keeper 모델)를 위해 각 표면에서 자기 이름으로 재등록**한다. 하나의 SSOT 에서 두 표면으로 투영하는 대신 표면마다 재정의 → 이름 중복 + 개수 폭증 + 규칙 분열. RFC-0357 admission, tool_profile, #26737 완료판정이 전부 같은 병(SSOT 없이 표면마다 재정의)의 다른 얼굴.

## 3. 목표 상태

### 3.1 단일 레지스트리 (SSOT)

도구는 **한 곳에서 한 번** 정의된다: `{ id; verb; description; input_schema; capability; surfaces }`. 표면(MCP/keeper)은 이 레지스트리를 **투영**할 뿐 재정의하지 않는다. `keeper_board_list` / `masc_board_list` 는 하나의 `board.list` 로 수렴, 표면별 이름 재작명 금지.

### 3.2 기본 동사 + ToolSearch 발견

- **상시 노출 (기본 세트, ~8개)**: `Read` `Grep` `Write` `Edit` `Execute` `Search` + 관측 2개(`surface_read`, `surface_post`) + `tool_search`.
- **나머지는 숨김**: `tool_search "board 에 글쓰기"` → 관련 도구 스키마를 그 턴에만 로드. `keeper_tool_search` 는 **이미 표면에 존재**한다 (인프라 있음, 정리만 안 됨).
- 효과: 매 턴 컨텍스트 43~61 도구 → ~8. keeper 과부하(96% 관측형 회귀 = 수동성)의 공급측 완화.

### 3.3 명명 단일화

한 규칙만: `<domain>.<verb>` (또는 `<domain>_<verb>`). `masc_` / `keeper_` / `masc_keeper_` 접두어 삼중 폐지. `masc_keeper_*` 이중 접두어 15개 우선 제거.

### 3.4 tool_profile 폐지

`/mcp` `/mcp/managed` `/mcp/operator` 라우트는 유지하되(인증이 경계), 도구 필터는 **레지스트리의 `surfaces` 필드 투영**으로 대체. `Full|Managed_agent|Operator_remote` variant + `?profile` 배관(execute/call_tool/protocol 20+ 파일) 소멸.

## 4. 비목표

- keeper 실행 의미 변경 없음 (Execute/Read 동작 그대로).
- 인증·권한(operator CanAdmin) 변경 없음.
- 레거시 도구명 하위호환 별칭 유지 **안 함** — 죽은 이름은 삭제 (owner: 흔적 남기지 않음). 외부 소비자 있으면 §6에서 실측.

## 5. 단계 (각 단계 독립 머지 가능)

> **측정 정정 (2026-08-04)**: 1단계를 "죽은 중복 삭제"로 시작하려 했으나 실측 결과 **안전 삭제 가능한 중복 이름 = 0개**. 12개 후보 전부 코드 소비자 3~10개(`mcp_tool_runtime`, `tool_bridge`, `dashboard`)가 라이브 — keeper 호출이 0회여도 다른 소비자가 쓴다. 따라서 1단계는 **삭제로 시작 불가**, 반드시 SSOT 수렴(두 이름이 한 정의를 투영)이 선행. 이 refactor 없이는 어떤 이름도 못 지운다.

1. **명명 SSOT 도입 + 중복쌍 수렴**: 12 변주쌍이 하나의 레지스트리 엔트리를 투영하게. 삭제는 소비자 전수 이관 **후**에만. (실측: 각 쌍은 keeper 기준 한쪽만 라이브지만 코드 소비자는 양쪽 다 라이브 → 삭제-먼저 금지)
2. **`masc_keeper_*` 이중 접두어 15개 정리**: `keeper_*` 또는 도메인 규칙으로.
3. **tool_profile → surfaces 투영**: variant + 배관 제거 (별도 PR, execute/call_tool/protocol).
4. **기본 세트 축소 + tool_search 승격**: 상시 노출을 ~8개로, 나머지 hidden + 검색 발견.

## 6. 검증 / 미해결

- [x] `masc_board_*` (keeper 0회) 소비자 실측 → **살아 있음**. `mcp_tool_runtime*`, `tool_bridge.ml`, `sdk_tool_contract.ml`, dashboard TS 다수가 소비. **결론: "삭제-먼저" 금지.** 1단계는 삭제가 아니라 **SSOT 수렴** — 두 이름(`keeper_board_list`/`masc_board_list`)이 하나의 레지스트리 엔트리를 가리키게 한 뒤, 표면 투영에서 이름을 하나로. keeper가 0회여도 MCP 클라이언트 경로는 라이브다.
- [ ] `/mcp/operator` `/mcp/managed` 의 실외부 소비자 유무 (surfaces 투영 전환 전 확인).
- [ ] 단계별 CI green (도구 등록 테스트 + tool_search 발견 회귀).
- [ ] tool_search 발견 품질: keeper 가 숨은 도구를 검색으로 실제 도달하는지 (harness 측정).

근거 데이터: `scratchpad/census.py`, `keeper_census.py`, `dup_census.py` + activity-events 2026-08-04.
