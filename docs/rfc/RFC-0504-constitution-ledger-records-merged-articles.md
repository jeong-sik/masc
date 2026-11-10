---
rfc: "0504"
title: "헌법 원장에 조항을 합치는 기록(Replaced)을 둔다"
status: Accepted
created: 2026-11-06
updated: 2026-11-10
author: masc-productor-owner
supersedes: []
superseded_by: null
related: ["0442", "0499", "0501"]
issue: "#49170, #35415"
---

# RFC-0504 — 헌법 원장에 조항을 합치는 기록(Replaced)을 둔다

## 0. 요약

- 헌법 원장의 기록은 `Added`와 `Removed` 두 갈래뿐이다. 비슷한 조항 여럿을 하나로 합치는 기록이 없어서, 살아 있는 조항 34개 중 겹치는 묶음이 7개다(#49170, 11-06 측정).
- 합치기는 지금 Removed + Added 두 줄로 흩어져 쓰인다. 원장은 어느 조항이 어느 조항을 대신했는지 따라가지 못하고, 합쳐진 문안이 조항 상한 512 B 를 넘으면 세 번의 합치자 제안이 그 상한에 죽었다.
- 제안: 원장 entry 에 `Replaced` 를 더한다. 한 줄이 은퇴시키는 id 목록과 대체 조항을 같이 담는다.
- 도구 표면: `keeper_constitution_write` 가 `replaces`(조항 id 목록)를 받는다. 비우면 지금과 같은 `Added`, 채우면 `Replaced` 다.
- 도구 밖에서 들어온 줄은 원문과 영향을 받는 조항 id를 격리 보고에 남긴다. 미확인 삭제·수정 줄을 건너뛰어 앞선 규범을 되살리지 않는다.
- 이 RFC 는 기록의 모양과 규칙을 정한다. 구현은 별도 층(task-3275), 겹침 묶음 7개의 적용은 그 다음 층(task-3276)이다.

## 1. 지금

### 1.1 원장과 렌더

- 원장: `<base-path>/.masc/constitution/articles.jsonl` 112줄(Added 76, Removed 36 — #49170 본문, 11-06 측정). 살아 있는 조항 34개.
- 렌더: 조항들은 세계의 모든 Keeper 턴에 실린다. `keeper_tool_constitution_runtime.mli` 의 `render_byte_ceiling` 주석: "The articles ride every turn of every keeper in the world, so this is the one brake RFC-0442 keeps."
- 상한은 4,096 → 8,192(10-05) → 12,288(10-10) 로 두 번 올랐다. 지금 `render_byte_ceiling = 12288`(`lib/keeper/keeper_tool_constitution_runtime.ml:9`)이고 사용률 88%다.
- 조항 하나의 상한은 `article_byte_cap = 512`(`:14`)다. 합치자는 제안 3건이 이 상한에 거절됐다.

### 1.2 겹침이 생기는 길

살아 있는 조항 34개 중 겹치는 묶음이 7개다(#49170). 묶음의 실체는 같은 규칙이 시점을 달리해 여러 번 쓰인 것 — 고쳐 쓰기가 Removed + Added 두 줄로 남으면서 "무엇이 무엇을 대신했는가"의 연결이 원장에서 끊겼고, 나중에 겹침이 눈에 보여도 어느 것이 살아 있는 대표인지 원장이 말하지 못한다.

### 1.3 도구 밖 쓰기

11-02 에 `codex-operator` 이름의 12줄이 같은 `at` 값으로 원장에 들어왔다(#49170). `write_with_outcome`(`:74`)은 `by` 를 `Keeper_meta_contract` 에서 채워 원장에 남기고, decode 는 `by` 가 등록 Keeper 명부에 있는지 검증하지 않는다 — 도구 밖에서 쓴 줄도 형식만 맞으면 살아 있는 조항이 된다.

## 2. 제안

### 2.1 원장 entry 에 `Replaced` 를 더한다

`lib/world_constitution/world_constitution_types.mli:73-83` 의 두 생성자 옆에 세 번째를 더한다.

```ocaml
type entry =
  | Added of t
  | Replaced of
      { superseded : Article_id.t list
        (** 이 기록이 은퇴시키는 살아 있는 조항들의 id. *)
      ; article : t
        (** 묶음을 대신하는 새 조항 — [Added] 와 같은 [t], 자기 id 를 담는다. *)
      ; by : string
      ; at : float
      ; reason : string option }
  | Removed of { id : Article_id.t; by : string; at : float; reason : string option }
```

- 한 줄이 "무엇을 대신하는가(superseded)"와 "무엇으로 대신하는가(article)"를 같이 담는다. 흩어진 두 줄이 잃는 대신 관계가 원장에 남는다.
- 살아 있는 조항 집합 계산(원장 fold)은 세 생성자를 모두 적는다: `Added` 는 더하고, `Replaced` 는 superseded 를 빼고 article 을 더하고, `Removed` 는 빼고. 와일드카드는 없다 — 새 entry 종류가 생기면 컴파일러가 이 자리를 고치게 한다.

### 2.2 도구 표면

- `keeper_constitution_write` 의 args 에 `replaces`(조항 id 배열, 기본 [])를 더한다.
  - 비어 있으면 지금과 같은 `Added` 다.
  - 채우면 `Replaced` 를 쓴다. 검증 규칙:
    - `replaces` 의 모든 id 는 지금 살아 있는 조항이어야 한다. 안 살아 있는 id 를 건네면 거절한다 — `remove_with_outcome` 이 "안 잡힌 조항의 제거는 조용한 성공이 아니라 실패"라고 쓴 것과 같은 원칙이다.
    - `replaces` 안에 같은 id 가 두 번 있으면 거절한다.
    - 대체 조항은 기존 유효성 검사(빈 문안 금지, 주장하는 Keeper 존재, evidence 가 무언가를 이름으로 건네야 함)를 그대로 통과해야 한다.
- `keeper_constitution_remove` 는 그대로다. 대체물 없는 은퇴는 제거고, 제거는 이미 제 자리가 있다.
- `read_with_outcome` 은 원장 줄을 순서대로 돌려주므로 `Replaced` 줄도 자연히 보인다 — 읽기 표면의 변경은 없다.

### 2.3 바이트 규칙 — 합치기는 렌더 예산을 줄여야 한다

- `article_byte_cap = 512` 는 `Added` 에 그대로 적용한다.
- `Replaced` 의 대체 조항은 두 조건을 받는다:
  1. 은퇴시키는 묶음의 렌더 바이트 합보다 작아야 한다. 같거나 크면 거절한다 — 합치기의 목적 그 자체다.
  2. 렌더 결과가 `render_byte_ceiling` 안에 있어야 한다(기존 검사 유지, `:119-126`).
- 이유: 512 B cap 의 목적은 새 규범 하나의 간결성이다. 합치기는 여러 조항의 중복을 걷어내는 동작이라 cap 이 목적과 반대로 걸린다 — 세 제안이 여기서 죽었다. 구속 예산은 렌더 천장이고, 합치기는 천장을 낮추는 방향으로만 허용한다.

### 2.4 도구 밖 쓰기 12줄의 방침

- 신규 규범을 채택하려면 주체가 현재 Keeper 명부로 풀려야 한다. `Added`는 `author`, `Removed`는 `by`, `Replaced`는 `by`와 새 조항의 `author`를 모두 확인한다. 쓰기 도구는 두 이름을 같게 쓰지만 decoder는 서로 다른 이름도 읽는다.
- 주체가 풀리지 않는 줄은 승인하지 않는다. 그 줄이 건드리는 id도 현재 규범에서 보류한다. `Added`는 자기 id, `Removed`는 제거 대상 id, `Replaced`는 `superseded`와 대체 조항의 id다. 미확인 삭제·수정 줄만 무시하면 이미 철회되거나 바뀐 앞선 문장이 다시 System에 실릴 수 있기 때문이다.
- 보류는 삭제 권위를 인정하거나 새 문안을 채택하는 판정이 아니다. `Replaced`의 새 문안도 실리지 않는다. 뒤에 주체가 확인되는 명시적 `Added`가 있으면 그 시점에 다시 채택할 수 있다. 영향을 받지 않는 조항은 유지한다.
- 원문은 원장과 decoded history에 그대로 보존한다. `read_with_outcome`의 `isolated_ledger_lines`에 줄 번호·미확인 주체·`article_ids`를 함께 보고한다. prompt용 읽기와 고정 원장 위치의 읽기도 같은 보류 규칙으로 접는다.
- 현재 명부는 과거 쓰기의 권위를 소급 증명하지 않는다. 특정 운영자 이름을 예외로 허용하거나 모든 미확인 삭제를 승인하지 않는다. 쓰기 도구의 주체·현재 조항 검사는 유지한다.
- `load_held`는 현재 조항·원장 위치와 함께 `Resolved | Isolated_history` 상태를 반환한다. 현재 명부로 접은 이력에 격리 줄이 있으면 Keeper는 현재 조항 전체를 별도 `norms_current` 안내로 매 요청에 싣고 기존 조항 delta를 대체한다. 목록이 비었을 때도 현재 세계 규범이 없음을 명시한다. snapshot 크기는 현재 조항 크기에 비례하고 과거 격리 id 수에는 비례하지 않는다. 정상 도구 쓰기는 기존 렌더 크기 경계를 지키며, Store의 수동 원장 읽기에 새 상한을 주장하지 않는다.
- 과거 System을 보존해야 하는 native 재개에는 격리 여부와 무관하게 현재 전체 목록을 보낸다. 현재 명부로는 모든 줄이 풀려도, 예전에 다르게 접힌 규범이 seed에 남았을 수 있기 때문이다. 발급 기준점 미확인, System override와 후속 tool round에도 목록을 유지한다. 싣는 자리는 실행 주체를 따른다. Agent Core는 발급한 System의 관측으로, official client는 턴 입력 블록으로 싣는다. 요청 끝의 User 안내로 실으면 도구 결과 뒤 요청마다 같은 목록이 새 발화처럼 붙고 Keeper가 매번 답한다(#50882). 턴 중간에 실행 주체가 바뀌면 그 요청의 주체를 따른다. 이 목록은 세계 규범만 대체하며 역할·Goal·승인 권한은 바꾸지 않는다. 모든 영향 id를 재채택한 뒤에도 격리 이력이 있으면 목록을 보낸다. 새로 채택한 본문은 현재 목록에 정상 포함한다.

### 2.5 적용과 확인

1. 원장을 다시 쓰거나 미확인 줄만 제거하지 않는다. 뒤의 삭제·교체를 없애면 앞선 `Added`가 다시 활성화될 수 있다.
2. 같은 원장과 명부로 현재 조항·격리 진단·prompt용 읽기·고정 위치 읽기를 대조한다. 미확인 줄이 있는 id가 현재 규범으로 나오지 않는지 확인한다.
3. 수정본을 배포한 뒤 실제 발급 System과 변경 안내를 확인한다. 과거 System에 남은 문장까지 수리됐는지는 소스 검토나 조항 수만으로 판단하지 않는다.
4. 리더가 확인된 현재 조항에 새 `replaces` 인자로 합치기를 적용하고, 묶음별 전·후 렌더 바이트를 기록한다(#49170 완료 판정 ③).

헌법 원장은 세계의 규범 기록이고, Keeper가 이미 받은 System은 별도의 세션 상태다. 둘의 적용 증거를 구분한다. 미확인 줄의 권위 해소는 이 읽기 규칙이 대신 판단하지 않는다.

## 3. 대안 기각

- **렌더 상한 추가 인상** — 두 번 했고(8,192 → 12,288) 지금 88%다. 합치는 대신 천장을 올리는 것은 같은 논쟁의 반복이다.
- **Removed + Added 쌍으로 흉내** — 대신 관계가 원장에 남지 않는다(#49170 Symptom 그대로). 도구가 쌍을 원자적으로 쓴다고 해도 "무엇이 무엇을 대신했는가"는 두 줄의 텍스트 밖의 사실이라 원장이 말하지 못한다.
- **읽을 때 겹침 자동 감지·자동 합침** — 겹침 판정은 규범의 의미론이라 기계가 대신할 수 없다. 합친다는 판단은 그 세계의 절차(Keeper 합의)가 하고, 원장은 그 판단을 정직하게 기록하는 자리만 제공한다.

## 4. 완료 판정 대응 (#49170)

- [x] 계획: 합치기 기록(Replaced) RFC — 이 PR.
- [ ] 구현 PR 병합 — task-3275(ocaml-agent-ic), 타입·fold·도구 인자·검증.
- [ ] 겹침 묶음 7개 합침 + 렌더 감소 실측 댓글 — task-3276(리더, §2.5 4~5단계).

## 5. 범위 밖

- 렌더 천장 값 자체의 변경 — 합치기가 천장을 낮추는 길을 여는 것이 목적이다.
- 도구 밖 12줄의 소급 귀속 — 누가 썼는지 원장이 증명하지 못하면 되돌려 쓰지 않는다. 보존 파일에서 열람 가능하다.
- 다른 세션 원장의 형식 — Muse 세션(#49172/RFC-0495), tool_blobs(#49174/RFC-0499), Codex thread(#49031/RFC-0501)는 각자의 RFC 가 다룬다.
