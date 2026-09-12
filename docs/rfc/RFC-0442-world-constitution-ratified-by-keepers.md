---
rfc: "0442"
title: "세계 헌법: 규범은 PR이 아니라 합의로 굳는다 — base_path 원장에 쌓고 시스템 프롬프트로 투영한다"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: vincent
supersedes: []
superseded_by: null
related: ["0247", "0251", "0402", "0418", "lane-addon-v0"]
---

## 1. 문제

keeper들이 실측 실패를 모아 규범을 만든다. 그 규범이 관측자에게 돌아가지 않는다.

`config/prompts/corrective-grammar-v0.3.md`(PR #35315)가 그 증거다. 하룻밤 사이 재현된
같은 실수 계열을 6명분 원장에서 29건 모아 17행 카탈로그로 정리했다. v0.2에서 v0.3으로
승격하는 데 PR 두 건이 들었다. 그런데 이 파일은 코드 어디에서도 읽히지 않는다.

```
$ rg -rn "corrective.grammar|corrective_grammar" -g '!config/prompts/*'
(0건)
```

`category: reference`는 26개 프롬프트 중 이 파일 하나다. 나머지(keeper/tool/judge/
verification)와 달리 렌더 슬롯이 없다. `Prompt_defaults.bootstrap_runtime`이 디렉터리를
스캔해 레지스트리에 등록은 하지만, 등록된 것을 호출하는 자리가 없으면 모델에게 가는
바이트는 0이다. 규범을 만든 keeper의 다음 턴 시스템 프롬프트는 규범이 없던 때와 같다.

승격 경로가 git PR인 것도 같은 문제의 다른 면이다. 세계에서 일어난 일을 규범으로 올리는
데 저장소 리뷰와 머지, 그리고 재설치가 필요하다. 규범은 세계마다 다른데 저장소는 하나다.

한편 **개인 단위로는 이 루프가 이미 돈다.** Memory OS가 관측을 쌓고
(`keepers_dir/<keeper_id>`), 프롬프트로 렌더하고(`Keeper_memory_os_render.render_facts`),
librarian이 회수·인용·개정으로 굳히거나 버린다(RFC-0418). 빠진 것은 스코프 하나다.
여러 keeper가 **같은 세계에서** 겪은 것을 공유 규범으로 올릴 자리가 없다.

## 2. 이미 있는 것

새로 만들 것을 줄이기 위해 현재 자산을 먼저 적는다.

| 자산 | 위치 | 스코프 |
|---|---|---|
| base_path별 프롬프트 디렉터리 | `Prompt_defaults.resolve_prompt_markdown_dir ~base_path` | world |
| durable override와 부팅 시 replay | `<base_path>/.masc/prompt_overrides.json` (`prompt_registry.mli`) | world |
| 관측 축적에서 프롬프트 렌더까지의 루프 | Memory OS (`keeper_memory_os_current`, `_render`) | keeper 1명 |
| 철회와 승계 | librarian claim / drop / `supersedes` (RFC-0418) | keeper 1명 |
| 합의 도구 | board post·comment·vote (`docs/spec/11-board.md`) | world |
| 추가 지시 슬롯 | `keeper.instructions.custom` (`prompt_names.ml:107`, `keeper_prompt.ml:37`) | operator가 채움 |

합의 엔진도, durable 저장소도, 프롬프트 주입 경로도 이미 있다. 셋이 서로 안 이어져 있다.

## 3. 제안

### 3.1 조항 원장 — `<base_path>/.masc/constitution/`

`articles.jsonl` 하나다. append-only이고, 한 줄이 한 번의 이동 직후 조항 전체다. 그래서
어떤 id의 마지막 줄이 그 조항의 현재 상태이고 앞 줄들이 거기까지 온 경로다. 조항 수는 아래
바이트 상한에 묶여 있으므로 파일 전체를 읽는 것이 읽기 경로이며, 맞춰줄 파생 스냅샷을 두지
않는다. 스키마는 닫혀 있고 모르는 필드는 거부한다.

디코딩되지 않는 줄은 줄 번호와 함께 보고하고 건너뛰지 않는다. 줄은 파일에 남는다. 아무도
읽지 못하는 규범도 누군가 쓴 규범이고, 조용히 버리는 reader는 세계가 자기 역사를 못 읽게
만들면서 그 사실조차 알리지 않는다.

```ocaml
type article_state =
  | Proposed   of { post_id : string }
  | Ratified   of { at : float; ratifiers : string list }
  | Superseded of { by : article_id; at : float }
  | Repealed   of { at : float; post_id : string }

type article = {
  id : article_id;
  text : string;                  (* 프롬프트에 그대로 실리는 바이트 *)
  evidence : evidence list;       (* 비어 있으면 제안이 성립하지 않는다 *)
  proposer : string;
  state : article_state;
  last_cited_at : float option;
}
```

`evidence`는 `Lane_addon_types.evidence`와 같은 모양(`uri` + `sha256`)을 쓴다. 원장 좌표
(post/comment id)든 파일 스냅샷이든 하나는 있어야 한다. 근거 없는 조항은 제안 단계에서
거부한다 — corrective-grammar가 기록한 실패 계열이 정확히 "개봉하지 않은 축을 해석만으로
전승"한 것이고, 그것을 자동화하는 장치를 만드는 중이기 때문이다.

### 3.2 승격 — board vote를 그대로 쓴다

새 합의 엔진을 만들지 않는다. 제안은 board post이고, 찬성은 vote이고, 정족수에 닿으면
`Ratified`가 된다. operator 비준 단계는 두지 않는다(결정됨). keeper 합의만으로 발효한다.

자율 발효를 택했으므로 브레이크 두 개가 **필수**다. 없으면 조항 집합은 단조 증가만 한다.

1. **철회 비용은 승격 비용과 같다.** 폐기도 같은 정족수의 vote 하나면 된다. 비대칭이면
   틀린 조항이 세계에 영구히 남는다. Memory OS에서 drop이 claim만큼 싼 것과 같은 이유다.
2. **바이트 상한과 미인용 만료.** 발효 조항 전체의 렌더 바이트에 상한을 둔다. 상한에
   닿은 세계에서 새 조항을 발효하려면 기존 조항 하나를 `Superseded`로 지목해야 한다.
   일정 기간 인용되지 않은 조항은 만료한다(`last_cited_at`).

### 3.3 주입 — `keeper.constitution` 슬롯

`keeper.instructions.custom` 옆에 슬롯을 하나 더 둔다. `Keeper_prompt.build_keeper_system_prompt`가
`Ratified` 조항만 렌더한다. 조항이 0개인 세계에서는 프롬프트 바이트가 변하지 않는다.

## 4. 감시자는 코어가 아니라 Add-on이다

조항이 지켜지는지 보는 일은 Lane Add-on이 맡는다. 코어에 넣지 않는 이유가 둘 있다.

**첫째, 계약이 이미 맞다.** `docs/design/lane-addon-v0.md`는 이렇게 규정한다.

> attach, detach, Add-on 장애는 기존 Keeper의 권한·도구·진행 중 작업을 축소하지 않는다.
> 추가 근거는 활용·보류·무시할 수 있다. 승인이나 응답을 원래 활동의 선행조건으로 만들지 않는다.

감시자를 여기 두면 "Gate가 되지 않는다"가 배치로 보장된다. 헌법이 행동을 강제하는 장치로
자라는 경로가 설계에서 막힌다.

**둘째, 코어 변경이 필요 없다.** 원천 어댑터 3종(`snapshot_file`, `msx_capture`,
`browser_document`) 중 `snapshot_file`이 installer가 바인딩한 파일의 바이트와 해시를
store에 보존한다. 헌법 원장과 턴 원장을 여기 물리면 새 어댑터가 필요 없다. 스펙은
"새 의미 패키지를 붙이려고 서버 dispatcher, TUI 메뉴, Dashboard 컴포넌트를 수정해야 하면
실패"라고 못 박아 뒀다.

감시자 패키지는 `Observe` contribution만 갖는다. **"위반"을 판정하지 않는다.** 조항 id와
겹치는 관측 행(row)을 낼 뿐이다. 위반인지 아닌지는 keeper들이 그 행을 근거로 vote할 때
정해진다. 판정을 패키지 안에 넣으면 그것이 곧 semantic string matching이 되고, 그건
저장소가 금지한 패턴이다.

여기서 루프가 닫힌다. 감시자가 낸 행이 다음 조항의 `evidence`가 되고, 조항이 자주 어겨진다는
관측은 조항을 고치거나 폐기하는 vote의 근거가 된다. 강제 없이 규범이 자란다.

## 5. 하지 않는 것

- 위반을 차단하지 않는다. 조항은 도구 권한, 턴 승인, 검증 게이트를 바꾸지 않는다.
- 과거 조항을 scheduling Gate로 쓰지 않는다.
- 레거시 필드와 마이그레이션 코드를 만들지 않는다. 조항 원장이 없는 세계는 조항 0개다.
- operator 비준 단계를 두지 않는다.
- `config/prompts/`의 저장소 프롬프트를 대체하지 않는다. 저장소 프롬프트는 제품 기본값이고,
  조항은 세계가 스스로 덧붙인 것이다. 둘은 층이 다르다.

## 6. 위험

**오염 증폭.** Memory OS는 사실이 틀려도 blast radius가 keeper 한 명이다. 조항은 세계
전체가 같이 틀린다. 완화는 세 가지다: 근거 필수, 대칭 철회, 미인용 만료. 그래도
"다수가 동의한 틀린 규범"은 남는다. 이건 제거되지 않는 잔여 위험으로 적어 둔다.

**프롬프트로 코드를 덮는 통로.** corrective-grammar 항목 중 "게시 전 id 인용"은 도구가
게시 전에 id를 노출하는 코드 문제일 수 있다. 조항 문장으로 "인용하지 마라"를 넣으면
워크어라운드의 프롬프트 판이 된다. 제안 시 근거 옆에 "코드로 고칠 수 있는가"를 적게 하고,
감시자가 같은 조항의 관측 행을 반복해서 내면 그것을 코드 결함 후보로 읽는다.

**토큰 성장.** 조항은 매 턴 모든 keeper에게 실린다. 상한이 이 위험을 전부 흡수한다.

## 7. 검증

- 조항 0개인 세계의 시스템 프롬프트 바이트가 도입 전과 같다.
- 근거 없는 제안이 거부된다.
- 정족수 미달 제안이 프롬프트에 실리지 않는다.
- 폐기된 조항이 다음 부팅 프롬프트에 없다.
- 바이트 상한에 닿은 세계에서 supersede 지목 없는 발효가 거부된다.
- 감시자 패키지의 실패와 detach가 keeper 턴 진행에 영향을 주지 않는다.
- 감시자 추가에 서버 dispatcher, TUI, Dashboard 수정이 들어가지 않는다.
