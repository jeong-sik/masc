---
rfc: "0504"
title: "헌법 원장에 조항을 합치는 기록(Replaced)을 둔다"
status: Accepted
created: 2026-11-06
updated: 2026-11-06
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
- 11-02 에 도구 밖에서 들어온 12줄(codex-operator, 같은 at)은 격리 보고와 배포 재부호화로 정리한다.
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

- 라이브셋 계산과 렌더는 `by` 가 Keeper 명부(또는 시스템이 등록한 주체)로 풀리는 줄만 센다. 풀리지 않는 줄은 살아 있는 조항에서 빠지고, `read_with_outcome` 의 rejected-lines 진단과 같은 자리에 "격리 줄"로 보고된다 — 조용히 사라지게 하지 않는다.
- 배포 때 한 번 정리한다(§2.5). 11-02 의 12줄(codex-operator, 같은 at)은 이 절차로 원장에서 빠지고, 줄 수와 사실이 기록으로 남는다.
- 재발 방지: `keeper_constitution_write` 가 아니면 원장 줄이 생길 수 없는 구조를 유지한다. decode 가 `by` 소속을 검증하지 않는 지점에 §2.4 첫 항의 격리 검사를 두는 것으로 닫는다 — 원장 파일을 손으로 고치는 길은 열어 두되 그 줄이 규범이 되지는 못하게 한다.

### 2.5 배포 절차(1.0 전 저장 상태 하드컷 허용, #49170)

1. 서버를 멈춘다.
2. `articles.jsonl` 을 `articles.jsonl.pre-0504` 로 이름을 바꿔 보존한다(삭제하지 않는다 — 감사 추적용).
3. 구 ledger 을 decode 하고 §2.4 격리 규칙을 통과하는 줄만 새 ledger 에 순서대로 재기록한다. 격리된 줄 수(예상 12)와 대표 원문을 이슈 #49170 댓글로 남긴다.
4. 새 버전으로 서버를 띄운다. 살아 있는 조항 수·렌더 바이트를 재측정해 같은 댓글에 덧붙인다.
5. 리더가 새 `replaces` 인자로 겹침 묶음 7개를 하나씩 `Replaced` 하고, 묶음별 전·후 렌더 바이트를 댓글로 남긴다(#49170 완료 판정 ③).

Codex/Muse 세션과 달리(#49069·RFC-0495 사례) 헌법 조항은 세션 상태가 아니라 세계의 규범 원장이라, 재부호화 뒤 Keeper 쪽 복구 비용은 없다. 겹침 묶음이 아니라 살아 있는 대표 조항은 재기록되어 그대로 렌더된다.

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
