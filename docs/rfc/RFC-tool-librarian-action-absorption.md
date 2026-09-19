---
rfc: "tool-librarian-action-absorption"
title: "Tool Librarian: 도구 호출 궤적을 읽어 반복 패턴을 컴포지션으로 흡수(Absorb)한다"
status: Draft
created: 2026-09-17
updated: 2026-09-19
author: jeong-sik
supersedes: ["keeper-writes-own-compositions"]
superseded_by: null
related: ["skills-as-tools", "tools-as-shell-commands", "0418", "keeper-writes-own-compositions"]
implementation_prs: []
---

# RFC: Tool Librarian — 도구 호출 궤적의 컴포지션 흡수 (Action Absorption)

## 0. Summary

Memory OS의 Librarian이 파편화된 개별 관측(`m1`, `m2`)을 읽어 하나의 상위 기억으로 묶어 **흡수(Absorb / Consolidate)**하고 옛 ID를 `dropped`로 처리하듯, 도구 레이어에서도 **Tool Librarian (독립 메타 분석 에이전트)**이 키퍼들의 실행 로그(`tool_calls`)를 분석하여 반복되는 다단계 도구 호출 사슬을 **단일 컴포지션(`keeper_compose_*`)으로 흡수(Action Absorption)**한다.

이 RFC는:
1. `tools-as-shell-commands` (Shell IR)의 실패(16일간 59,500회 호출 중 채택률 0%)와,
2. `keeper-writes-own-compositions`의 우려(일하는 키퍼의 집중 분산, 1회성 과적합)

를 모두 극복하고, **데이터 기반의 오프라인 마이닝 + 샌드박스 사전 검증(Dry-run) + HITL 승인**을 거쳐 살아있는 고효율 컴포지션 카탈로그를 유지하는 아키텍처를 정의한다.

---

## 1. 배경과 실측 증거

### 1.1 범용 셸 문법 접근법(Shell IR)의 침묵과 실패
- `RFC-tools-as-shell-commands`는 모델에게 셸 스크립트 문법(`masc <tool>`)을 주고 런타임이 이를 0ms 인프로세스로 가로채려 했다.
- **실측 (2026-09-02 ~ 09-17)**:
  - `Execute` 호출 59,500건 중 `masc` 명령 시도는 단 6건(0.01%), 실제 도구 연결 성공은 **0건**.
  - 원인: 키퍼의 `Execute` 입력 중 85% 이상이 `sh -c "<text>"` 형태로 단일 포장되어 Shell IR 가로채기 자체가 발동하지 않았으며, 키퍼들은 파이프(`| head`)와 플래그(`--limit`)를 기대했으나 파서는 이를 거부했다.
  - 범용 문법 조합은 LLM의 비정형 셸 입력 앞에서 완전히 실패했다.

### 1.2 스킬 컴포지션의 실증과 '작성의 병목'
- 반면 고정된 DAG를 단일 도구로 패키징한 **스킬 컴포지션(`keeper_compose_*`)**은 실전에서 강력한 절감 효과를 입증했다.
- **실측 (2026-09-01 ~ 09-17, 총 2,164건)**:
  - `msx-observe`: 813건 (화면 캡처 즉시 비전 분석 직결)
  - `work-intake`: 735건 (아침 조회 7개 도구를 28.5ms 만에 1턴으로 완료)
  - `what-arrived`: 342건
- **한계와 문제점**:
  1. **작성의 병목**: 지금까지 카탈로그는 12개뿐이며, 전부 사람이 손으로 100~200줄의 TOML을 작성했다.
  2. **검증 부재로 인한 지뢰 도구 배포**: 사람이 손으로 짠 `run-and-read`는 샌드박스 경계 검증을 거치지 않아, `microvm`에서 `keeper_spawn` 정책 거부(`policy_rejection`)로 **오늘 호출된 5건 모두 실패**했다.

### 1.3 일하는 Keeper가 직접 만들 때의 우려 (`keeper-writes-own-compositions` 검토)
`RFC-keeper-writes-own-compositions`는 일하는 키퍼가 런타임에 `keeper_compose_save`로 제안하자고 했다. 이 RFC가 보는 우려는 둘이다. `keeper_compose_save`는 구현된 적이 없어서 둘 다 잰 값은 없다.
1. **작업 방해(Task Distraction)**: 코딩/디버깅 턴에 복잡한 TOML DAG를 조립하느라 에이전트의 주의력과 토큰이 그쪽으로 샐 수 있다.
2. **1회성 과적합(Catalog Pollution)**: 단 한 번 마주친 특수 상황을 컴포지션으로 제안하여 시스템 프롬프트의 Tool Definition을 불릴 수 있다.

이 RFC는 이 두 우려를 근거로 **"일하는 키퍼"와 "도구를 흡수/합성하는 분석자"를 나누자고 제안한다.**

---

## 2. 핵심 원리: 기억의 흡수(Memory OS)에서 행동의 흡수(Action OS)로

MASC의 Memory OS에서 Librarian은 이미 완벽한 흡수 메커니즘을 수행하고 있다 (`RFC-0418`, `config/prompts/librarian.md:32-36`):

> *"반복되는 개념이나 주제에 대한 정보면, 그 주제를 중심으로 묶어서 하나로 다시 쓰세요...  
> 묶어서 쓴 기억을 `new_claims`에 넣고, 재료가 된 기억의 ID는 모두 `dropped`에 넣습니다."*

이 원리는 절차적 행동(도구 실행)과 1:1로 대응된다:

| 비교 차원 | Librarian의 기억 흡수 (Memory Consolidation) | Tool Librarian의 행동 흡수 (Action Absorption) |
| :--- | :--- | :--- |
| **원시 재료** | 턴마다 쏟아지는 파편적 관측·사실들 (`m1`, `m2`) | 턴마다 쏟아지는 파편적 도구 호출들 (`tool_a`, `tool_b`) |
| **시스템 엔트로피** | 기억 개수 증가로 인한 컨텍스트 한도(16KB) 초과 | 턴 수 증가로 인한 LLM 왕복 시간(Roundtrip) 및 토큰 낭비 |
| **판정 기준** | "반복되는 주제인가? 결정론적 팩트인가?" | "반복되는 시퀀스인가? 중간 판단 없이 인자가 직결되는가?" |
| **흡수(Absorb) 행위** | 재료 기억을 `dropped`하고, 묶은 새 claim 발행 (`supersedes`) | 재료 도구 호출 턴들을 제거하고, 묶은 새 `composition` 발행 |
| **결과** | 고밀도 장기 기억 스냅샷 (400개 사실로 수렴) | 고밀도 1턴 컴포지션 도구 (20~30ms 초고속 실행) |

---

## 3. Tool Librarian 아키텍처

Tool Librarian은 실시간 턴을 방해하지 않는 **오프라인/스탠드얼론 분석 파이프라인**으로 동작한다.

```
 [<base-path>/.masc/tool_calls/ 프로덕션 로그 (수만 건)]
                       ↓
 [1단계: 미흡수 궤적(Unabsorbed Trace) 시퀀스 마이닝]
   - N-gram 빈도 분석 (예: Tool A → Tool B)
   - 데이터 의존성 분석 (Tool A의 output이 Tool B의 input으로 직결되는가)
                       ↓
 [2단계: Tool Librarian 합성 판정]
   - "중간에 LLM의 주관적 추론이 필요 없는 결정론적 DAG인가?"
   - TOML 컴포지션 초안 자동 생성 (Param 바인딩 & Output Pointer 연결)
                       ↓
 [3단계: 샌드박스 Dry-Run 검증 게이트 (필수 Invariant)]
   - 실제 격리 환경(host, microvm)에서 자동 생성된 컴포지션 실행 테스트
   - exit code 0, timeout 미발생, wire size 16KB 이하 검증
                       ↓
 [4단계: Staged 제안 및 사람 승인 (HITL)]
   - "지난 7일간 420회 반복된 패턴, Dry-run 통과 완료, 420턴 절감 예상"
   - PR 또는 TUI/Board 제안 카드로 발행 → 사람 승인 후 반영
```

### 3.1 흡수 판정 조건 (Absorption Criteria)
Tool Librarian은 다음 3가지 조건을 모두 충족할 때만 컴포지션 후보로 선별한다:
1. **재사용성 (Frequency Floor)**: 최근 7일간 복수의 서로 다른 키퍼에게서 최소 30회 이상 동일 시퀀스가 반복 관측됨.
2. **결정론적 데이터 흐름 (Deterministic Pipelining)**:
   - Tool A의 출력 필드가 Tool B의 필수 입력 필드에 명확한 JSON Pointer(`pointer = "/id"`)로 사상될 수 있어야 함.
   - 중간에 LLM의 복잡한 자연어 추론이나 분기 선택이 개입해야 하는 경우는 흡수 대상에서 제외.
3. **크기 안전성 (Size Ceiling)**:
   - 결합된 노드 결과의 합산 크기(90% 백분위수)가 `Common.max_tool_result_wire_bytes` (16,384 bytes)를 초과하지 않아야 함.

### 3.2 샌드박스 Dry-Run 검증 (The Verification Invariant)
사람이 손으로 짠 `run-and-read`가 실패했던 전철을 밟지 않기 위해, **Dry-run 통과는 기계적으로 강제**된다:
- 생성된 TOML을 임시 등록하고, 테스트 샌드박스(`microvm` 타깃 포함)에서 모의 입력을 넣어 실제 실행.
- `policy_rejection`, `unresolved_pointer`, 스키마 검증 실패가 단 1건이라도 발생하면 즉시 기각하고 로그를 남긴다.

---

## 4. 흡수율(Absorption Rate) 계측과 자동 퇴역

컴포지션은 한 번 등록되고 끝나는 정적 자산이 아니다. 생명주기를 가진다:

$$\text{Absorption Rate} = \frac{\text{컴포지션 호출 횟수}}{\text{컴포지션 호출 횟수} + \text{해당 원자적 도구들의 개별 연속 호출 횟수}}$$

1. **카나리 관측 (1~2주)**:
   - 컴포지션 배포 후 키퍼들이 실제로 이 컴포지션을 채택하는지 계측한다.
2. **퇴역(Sunset) 기준**:
   - 도입 후 14일 동안 흡수율이 10% 미만이거나 (아무도 안 씀),
   - 런타임 실패율이 5%를 초과하면(지뢰 도구),
   - 카탈로그 오염을 막기 위해 **자동으로 Deprecate 후보로 분류하고 사람에게 제거 PR을 제출**한다.

---

## 5. 단계별 구현 계획

### Phase 1: 시퀀스 마이너 도구 (`scripts/tool-call-sequence-miner`)
- `<base-path>/.masc/tool_calls/*.jsonl`을 스캔하여 키퍼별 연속 도구 호출 쌍(Pair) 및 삼중(Triplet) 빈도와 실패율을 집계하는 CLI 작성.
- 오늘 당장 드러난 상위 호출 도구들의 실제 결합 빈도를 정량화.

### Phase 2: 컴포지션 Dry-Run 테스트 러너 (`test_keeper_composition_dry_run`)
- 임의의 `[[compositions]]` TOML 조각을 받아 현재 등록된 `microvm` / `host` 러너에서 실제로 파싱 및 시험 실행을 해보는 테스트 하네스 구축.

### Phase 3: Tool Librarian 프롬프트 및 파이프라인
- `config/prompts/tool_librarian.md` 작성.
- Phase 1의 마이닝 결과와 Phase 2의 검증기를 엮어, 매주 1회 상위 1~2개의 고효율 컴포지션을 자동 제안하는 주기적 메타 워크플로 안착.

---

## 6. 반론과 답

- **Q: 샌드박스 내부의 `masc` CLI Shim 방식과 상충하는가?**
  - **A: 상호 보완적이다.**
  - CLI Shim은 키퍼가 `Execute` 안에서 임의의 셸 파이프(`masc ... | jq`)를 자유롭게 치게 하는 **'동적 실행 레일'**이다.
  - Tool Librarian은 셸을 칠 필요조차 없는 정형화된 반복 패턴을 1턴짜리 고속 RPC로 묶어주는 **'정적 턴 흡수 레일'**이다. 둘은 충돌하지 않으며 서로 다른 최적화 지점을 담당한다.

- **Q: 카탈로그가 너무 많아지면 도구 선택 장애(Tool Choice Confusion)가 오지 않는가?**
  - **A: 철저한 흡수율 기반 퇴역 정책으로 카탈로그 상한을 유지한다.**
  - 흡수율이 낮거나 호출되지 않는 컴포지션은 즉시 폐기되며, 활성 컴포지션은 상시 10~15개 이내의 고효율 도구로만 엄격히 통제된다.

---

## 7. 결론

"셸 문법을 주면 모델이 알아서 엮어 쓰겠지"라는 가정(Shell IR)은 16일간 성공률 0%로 사망했다.  
"사람이 손으로 완벽한 컴포지션을 미리 다 짜놓겠다"는 가정 역시 12개에 멈춘 채 샌드박스 에러를 냈다.

진짜 정답은 **"Librarian이 기억을 흡수하듯, 프로덕션 로그를 보고 검증된 행동을 컴포지션으로 흡수하는 자동화 루프"**다. 이 RFC는 MASC가 가진 가장 우아한 기억 통섭의 철학을 도구와 실행 레이어로 확장하는 자연스러운 귀결이다.
