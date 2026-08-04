# RFC-0359 — 도구 표면 단일화: 단일 레지스트리 SSOT 와 표면 투영

- Status: Draft
- Created: 2026-08-04
- Author: Vincent (owner ruling) + Claude
- Related: RFC-0357 (Withdrawn, admission gate 숙청 — 같은 뿌리: 표면마다 재정의), #26737 (완료 판정 우회)

## 0. Owner ruling (이 RFC의 헌법)

- keeper 에게 **자율**을 준다. 제약이 아니다.
- 기본 동사(`Read`/`Grep`/`Write`/`Execute`)가 있고 나머지는 **검색으로 발견**하면 된다. — 단 이 발견 능력은 **현재 코드에 존재하지 않는다**(§3.2 실측). 신규 빌드 대상이며 토큰 비용 측정이 정당화할 때만 착수한다(Stage 5, 조건부). 이 RFC 의 확정 범위는 SSOT 투영(Stage 1–3)이다.
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

### 3.2 기본 동사 + 발견 (측정으로 재정의됨, 2026-08-04)

> **거짓 전제 정정**: 이 절의 초안은 "`keeper_tool_search` 는 **이미 표면에 존재**한다 (인프라 있음, 정리만 안 됨)"고 적었다. **실측 결과 거짓.** `keeper_tool_search` 는 발견 도구가 아니라 **이번 턴에 이미 노출된 집합(`keeper_tools`)을 Jaccard 유사도로 re-rank 하던 visible-set 필터**였다 — 핸들러가 모든 결과에 `"already_visible": true` 를 하드코딩했다. 8월 keeper 호출 **0회**. 랭킹은 `Text_similarity.jaccard_similarity` = 하드코딩 휴리스틱(교리 위반).
>
> **현재 상태 (2026-08-04)**: 이 vestige 는 **#26785 (`3ac0b0b87e`) 로 이미 제거되어 main 에 없다.** `already_visible` / `rank_tool_schemas` / `ranked_tool_schema` / `keeper_tool_search_schema` / `Tool_tool_search` 전부 `origin/main` 기준 0건. 따라서 아래 3개 신규 능력은 "고칠 것"이 아니라 **처음부터 만들 것**이다.

- **원안 (base 세트 ~8 + 나머지 숨김/검색발견)** 을 구현하려면 지금 **없는 능력 3개를 신규 빌드**해야 한다:
  1. `search_fn` 이 노출분(`keeper_tools`)이 아니라 **전체 카탈로그**를 랭킹.
  2. 런타임이 **턴에 없던 descriptor 를 dispatch** (현재 dispatch 는 번들 내 descriptor 매칭 → 숨은 도구는 찾아도 못 부름).
  3. lazy-load + 휴리스틱 아닌 랭킹 (`already_visible:true` 하드코딩은 #26785 로 이미 소멸).
- 즉 base+search 는 config 조정이 아니라 **실기능 빌드**이며, 정당성은 per-turn 스키마 토큰 비용 측정에 달렸다(§6). 미측정 상태로 빌드 = "벤치마크 먼저" 원칙 위반.
- **과잉노출 자체는 크지 않다**: keeper 월 distinct **54/61(89%)** 사용, per-day **13~43**(바쁜 날 39~43). "안 써서 숨긴다"는 성립 안 함. 유일한 실 비용은 per-turn 스키마 컨텍스트(미측정).

### 3.3 명명 단일화

한 규칙만: `<domain>.<verb>` (또는 `<domain>_<verb>`). `masc_` / `keeper_` / `masc_keeper_` 접두어 삼중 폐지. `masc_keeper_*` 이중 접두어 15개 우선 제거.

### 3.4 tool_profile 폐지

`/mcp` `/mcp/managed` `/mcp/operator` 라우트는 유지하되(인증이 경계), 도구 필터는 **레지스트리의 `surfaces` 필드 투영**으로 대체. `Full|Managed_agent|Operator_remote` variant + `?profile` 배관(execute/call_tool/protocol 20+ 파일) 소멸.

## 4. 비목표

- keeper 실행 의미 변경 없음 (Execute/Read 동작 그대로).
- 인증·권한(operator CanAdmin) 변경 없음.
- 레거시 도구명 하위호환 별칭을 **영구 유지하지 않는다** — 죽은 이름은 삭제 (owner: 흔적 남기지 않음).
  - 단 §6 실측상 중복 12쌍의 이름은 **죽지 않았다** (코드 소비자 3~10개 라이브). 따라서 Stage 1 의 "두 이름이 한 레지스트리 엔트리를 투영"은 사실상 **한시적 별칭 기간**이다.
  - 이 기간은 **소비자 전수 이관 완료 시점까지**로 한정하고, 각 쌍의 제거 목표를 Stage 1 PR body 에 `removal target: <PR 또는 date>` 로 명시한다. 기한 없는 이중 투영은 지금 없애려는 그 중복이 된다.

## 5. 단계 (각 단계 독립 머지 가능)

> **측정 정정 (2026-08-04)**: 1단계를 "죽은 중복 삭제"로 시작하려 했으나 실측 결과 **안전 삭제 가능한 중복 이름 = 0개**. 12개 후보 전부 코드 소비자 3~10개(`mcp_tool_runtime`, `tool_bridge`, `dashboard`)가 라이브 — keeper 호출이 0회여도 다른 소비자가 쓴다. 따라서 1단계는 **삭제로 시작 불가**, 반드시 SSOT 수렴(두 이름이 한 정의를 투영)이 선행. 이 refactor 없이는 어떤 이름도 못 지운다.

1. **명명 SSOT 도입 + 중복쌍 수렴**: 12 변주쌍이 하나의 레지스트리 엔트리를 투영하게. 삭제는 소비자 전수 이관 **후**에만. (실측: 각 쌍은 keeper 기준 한쪽만 라이브지만 코드 소비자는 양쪽 다 라이브 → 삭제-먼저 금지)
2. **`masc_keeper_*` 이중 접두어 15개 정리**: `keeper_*` 또는 도메인 규칙으로.
3. **tool_profile → surfaces 투영**: variant + 배관 제거 (별도 PR, execute/call_tool/protocol).
4. ~~**`keeper_tool_search` vestige 제거**~~ — **완료: #26785 (`3ac0b0b87e`)**. 랭커(`rank_tool_schemas`/`ranked_tool_schema`/`keeper_tool_search_schema`) + `Tool_tool_search` variant + `search_fn` 배관 제거됨. `find_similar_names`(`tool_dispatch.ml:316`, unknown-tool 오타 제안)와 `Text_similarity.jaccard_similarity` 는 별개 정당 용도로 **유지됨**(main 4파일 라이브).
   - **잔여 (미완)**: 제거 후 소비자 스윕이 끝나지 않았다. `scripts/harness_tool_call_quality.sh` 의 벤치마크 케이스 3개(`read_search_prompt_fingerprint`, `recovery_after_failed_read`, `multi_step_board_update`)가 `tool_name == "keeper_tool_search"` 호출 유무로 `completed` 를 판정한다(`derive_final_result` :471/:507/:520 → `task_success_from_final_result`). 도구가 없으므로 keeper 는 그 호출을 낼 수 없고 세 케이스는 **품질과 무관하게 영구 실패**한다. 4케이스 중 남는 건 `text_only_triage`(도구 0회 요구) 하나. 이 스크립트는 `docs/BENCHMARK-RUNBOOK.md` / `docs/INTEGRATED-BENCHMARK-RUNBOOK.md` 가 지목하는 라이브 경로다. → 별도 이슈로 추적.
5. **(조건부) base+search 실발견 빌드**: §3.2 의 3개 신규 능력 구현. **선행 게이트**: per-turn 스키마 토큰 비용 측정이 빌드를 정당화할 때만. 아니면 drop.

## 6. 검증 / 미해결

- [x] `masc_board_*` (keeper 0회) 소비자 실측 → **살아 있음**. `mcp_tool_runtime*`, `tool_bridge.ml`, `sdk_tool_contract.ml`, dashboard TS 다수가 소비. **결론: "삭제-먼저" 금지.** 1단계는 삭제가 아니라 **SSOT 수렴** — 두 이름(`keeper_board_list`/`masc_board_list`)이 하나의 레지스트리 엔트리를 가리키게 한 뒤, 표면 투영에서 이름을 하나로. keeper가 0회여도 MCP 클라이언트 경로는 라이브다.
- [ ] `/mcp/operator` `/mcp/managed` 의 실외부 소비자 유무 (surfaces 투영 전환 전 확인).
- [x] tool_search 발견 품질 → **측정 완료: 발견 불가.** `keeper_tool_search` 는 visible-set 필터(`already_visible:true` 하드코딩), 숨은 도구 도달 경로 없음. 8월 keeper 호출 0회. 결론: 승격 대상 아니라 **제거 대상** → **#26785 로 제거 완료**.
- [ ] **제거 후 소비자 스윕 미완**: `harness_tool_call_quality.sh` 3케이스가 삭제된 도구명을 성공 조건으로 요구 (Stage 4 잔여 항목). 문자열 비교라 컴파일러·CI 어디에도 red 로 드러나지 않는다.
- [ ] **repo 밖 도구명 하드코딩 실측** (Stage 1–3 개명의 실제 폭발 반경). 현재까지 확인분:
  - dashboard TS 도구명 리터럴 **유니크 124개** (`dashboard/src`)
  - MCP 클라이언트 설정의 permission allowlist (`mcp__masc__masc_*` 형태) — 저장소 밖이라 CI 가 못 잡는다. 표본 1개 환경에서 17개.
  - 개명은 이 경로들을 **조용히** 깬다. Stage 1–3 착수 전 이 목록이 닫혀야 한다.
- [ ] per-turn 스키마 토큰 비용 측정 (base+search 실빌드 정당성 게이트, Stage 5 조건).
- [ ] 단계별 CI green (도구 등록 테스트 + 랭커 제거 회귀).

근거 데이터: `scratchpad/census.py`, `keeper_census.py`, `dup_census.py` + activity-events 2026-08-04.
