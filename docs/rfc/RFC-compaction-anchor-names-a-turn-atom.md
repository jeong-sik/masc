---
rfc: "compaction-anchor-names-a-turn-atom"
title: "압축 지점은 목록 위치가 아니라 Keeper 턴 안의 atom을 가리킨다"
status: Proposed
created: 2026-11-26
updated: 2026-11-26
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC compaction-anchor-names-a-turn-atom: 압축 지점은 목록 위치가 아니라 Keeper 턴 안의 atom을 가리킨다

- 상태: **제안(2026-11-26).**
- 11-26 저녁 masc 서버가 CPU를 계속 점유해 운영자가 서버를 멈췄다(21:03 SIGTERM).
- 운영자는 원인을 근본에서 고치라고 했다(「제대로 찾아서 올바른 방향으로 개선 및 최적화를 부탁한다」).
- 고정 ID 방향(A안)을 승인했다(「이거 버그가 없게 행랴함 고고」).
- 코드 좌표는 `origin/main` `a26795cff182c`에서 읽었다.

## 0. 요약

- 압축 지점(compaction anchor)은 덮은 범위의 끝을 `atom-<번호>-<내용 해시 16자>`로 적는다.
- 번호는 생산자가 받은 목록 안의 위치다. 생산자는 일곱 곳이고 받는 목록이 서로 다르다.
- 매 턴 도는 소비자는 checkpoint 기록에서 이 번호를 찾는다. 위치가 맞지 않으면 번호 뒤 모든 atom을 JSON으로 직렬화하고 SHA-256으로 해시한다.
- ACP 압축 지점은 정식 턴 저장소에서 다시 만든 목록을 기준으로 한다. 실제 기록과 내용이 달라 해시가 절대 맞지 않는다. 그래서 매 턴 수만 개 atom을 해시하고도 아무것도 자르지 못한다.
- 이 RFC는 atom의 이름을 바꾼다. 이름은 「그 atom이 속한 Keeper 턴의 ID」와 「그 턴 안에서 몇 번째 atom인지」다.
- 턴 ID는 이미 메시지 메타데이터에 있다. 새로 찍는 값은 없다.
- 비교는 메타데이터만 읽고, 턴 ID가 같은지만 본다. 직렬화, 해시, 문자열 접두어 비교를 모두 없앤다.
- 옛 `atom-*` 압축 지점은 읽지 않는다(하드컷). 운영자가 두 SQLite 파일을 지운다(§7).

## 1. 관찰

### 1.1 CPU

- macOS `sample`로 서버를 떴다. OCaml 5 Eio fiber 경계에서 스택이 끊기므로 경계 아래 masc 프레임의 inclusive 샘플을 셌다.
- `Keeper_compaction.messages_after_anchor`의 우회 경로 람다 안에서 `atom_hash`가 164번 잡혔다. 바깥에서 부른 `atom_hash`는 없었다.
- 두 번째로 많은 곳은 `Llm_provider.Utf8_sanitize`(168)였다. 이 RFC의 범위가 아니다(§6).

### 1.2 기록 크기

- 리더(`e-masc-the-leader`)의 checkpoint `trace-1789804858308-00001`은 앞 구간에만 메시지 38,361개를 담는다(머리 JSON `history.segment.messages`).
- checkpoint 기록은 앞에서 잘리지 않는다. `keeper.checkpoint_history_retained`는 남길 스냅숏 수이고 메시지 수가 아니다(`keeper_checkpoint_store_history_files.ml`).

### 1.3 압축 지점

| Keeper | 최근 epoch | 덮은 끝 | 계기 | 생산자 |
|---|---|---|---|---|
| e-masc-the-leader | 47 | `atom-7-bdbc2c638bffc90d` | `provider_counted_window` | ACP |
| code-reviewer | 18 | `atom-1-fcf50975531502f1` | `provider_counted_window` | ACP |
| msx-retro-mania | 9 | `atom-9246-dce4c448704d2c4f` | `explicit_hard_limit` | Agent Core(API) |

- 리더 epoch 44~47은 각각 atom 11, 8, 6, 8개를 덮었다. 번호가 매번 0부터 다시 센다.

### 1.4 턴 ID가 실제로 있는 곳

msx의 보관 atom 15,606개를 셌다.

- 맨 앞 4,042개 atom에는 턴 ID가 없다. 메시지에 턴 ID를 찍기 전에 쌓인 기록이다.
- `user`/`conversation` 메시지 827개 중 87개만 턴 ID를 가진다. 나머지는 턴 중간에 들어온 사용자 메시지다(재시도 지시, 끼어든 입력 등).
- 턴을 여는 메시지에는 턴 ID가 있다. `keeper_run_prompt.ml`과 `keeper_agent_run.ml`이 사용자 입력에 `canonical_turn_id`를 넣는다.
- 공식 클라이언트 턴을 나중에 들여온 메시지에는 `masc.bridged_turn_ref`가 있다(`keeper_turn_bridge.ml`).

### 1.5 ACP 턴 ID는 압축 시점에 아직 임시 값이다

- ACP 런타임은 턴이 끝나면 정식 턴 행을 `acp:<session>:<turn_count>` ID로 쓴다(`provider_turn_identity`).
- 이 행은 finalize의 `bind_turn_ref`가 나중에 Keeper 턴 ID로 바꾼다.
- 롤오버 압축(`compact_for_rollover`)은 그 사이에 돈다. 그래서 압축이 받는 목록의 마지막 턴은 임시 ID를 단다.
- finalize가 세션을 `Settled`로 보지 못하면 행은 임시 ID로 남는다.

## 2. 원인

### 2.1 생산자마다 목록이 다르다

| 생산자 | 받는 목록 | 번호의 기준 |
|---|---|---|
| Agent Core(`keeper_turn_driver_try_provider.ml`) | 에이전트 기록 전체 | 전체 기록 |
| Claude Code·Codex·Antigravity | 시작 seed(`offered`) | seed |
| ACP 롤오버·overflow(`keeper_acp_runtime.ml`) | `load_handoff_context`가 정식 턴 저장소에서 다시 만든 목록 | 마지막 watermark 뒤의 턴 |

- ACP 목록의 메시지는 `messages_of_canonical_turn`이 만든다. 한 턴이 사용자 메시지 하나와 어시스턴트 요약 하나다. 실제 기록의 같은 턴과 내용이 다르다.

### 2.2 소비자는 매 턴 checkpoint 기록 전체를 훑는다

- `keeper_tools_agent_core_bundle.ml:807`이 `live_history_after_latest_anchor`를 부른다. 런타임과 상관없이 모든 Keeper가 매 턴 부른다.
- 결과는 도구 이어 붙이기(`History_carry`)에만 쓰지만, 배치 정책을 보기 전에 매 턴 계산한다.
- `messages_after_anchor`는 압축 지점의 번호 자리 atom 하나를 해시해 비교한다.
- 맞지 않으면 그 번호 뒤 모든 atom을 `encode_messages`(JSON)와 SHA-256으로 해시하며 찾는다. 결과를 저장하지 않아 다음 턴에 다시 한다.
- ACP 압축 지점은 다시 만든 목록의 해시라 실제 기록에서 절대 맞지 않는다. 리더는 매 턴 atom 수만 개를 해시하고 기록 전체를 그대로 돌려받는다.

### 2.3 같은 뿌리의 다른 증상

- 생산자도 부를 때마다 버린 atom 전부를 해시한다(`canonical_turns_of_evicted_messages`). msx는 요청마다 수천 개다.
- 해시가 겹치면 `-ep<epoch>-<n>` 꼬리를 붙인다. 이것을 문자열 접두어로 다시 가른다(`turn_id_matches_target`, `parse_atom_turn_id`).
- 정식 턴 저장소는 압축 지점을 정식 턴 번호(seq)로 바꿀 때 ID부터 비교한다. `atom-*`는 정식 턴 ID와 같을 수 없어 이 비교는 늘 실패한다. 그래서 메시지 글자를 차례로 맞춰 본다(`find_cutoff_seq_for_evicted_turns`의 `index_messages`·`match_turn_from`).
- 글자 비교는 턴의 사용자 메시지만 버려져도 그 턴의 행을 지운다. watermark는 행을 실제로 지운다(`prune_turns_through_seq_in_tx`). 요약에 없는 어시스턴트 답이 handoff에서 사라질 수 있다.
- 11-25 #54812는 정확 일치 단계만 줄였다. 같은 자리의 두 번째 성능 수정이라 구조를 바꾼다.

## 3. 결정

### D1. atom의 이름은 턴 ID와 턴 안 순번이다

```ocaml
type name =
  | Leading of int
      (* 목록 맨 앞, 어떤 턴 ID보다 앞선 atom. 0부터 센다. *)
  | In_turn of { turn : Ids.Turn_id.t; ordinal : int }
      (* turn 안에서 ordinal번째 atom. 0부터 센다. *)
```

- atom 경계는 지금처럼 `Runtime_model_input_tail_window.annotate`가 정한다. Pinned 메시지는 atom이 아니다.
- atom을 여는 메시지의 메타데이터에서 턴 ID를 읽는다. `canonical_turn_id`를 먼저 보고, 없으면 `masc.bridged_turn_ref`를 본다. 공백이 아닌 문자열만 턴 ID다.
- 턴 ID는 같은지만 비교한다. `Ids.Turn_ref`로 읽지 않는다. ACP 임시 ID(§1.5)도 Keeper 턴 ID와 같은 규칙으로 다룬다.
- 턴 ID가 있으면 그 턴의 다음 순번이다. 순번은 목록 안에서 턴마다 따로 센다. 같은 턴이 뒤에서 다시 나와도 이어서 센다. 그래서 한 목록 안에서 이름이 겹치지 않는다.
- 턴 ID가 없으면 바로 앞 atom의 턴에 붙어 다음 순번이 된다. 앞에 턴이 없으면 `Leading`이다.

**처음 승인한 A안과 다른 점**

- A안은 agent_core가 메시지를 붙일 때 단조 번호를 찍는 안이었다.
- ACP 목록은 정식 턴 저장소에서 다시 만든 메시지라 그 번호가 없다. 다시 만든 목록과 실제 기록에 함께 있는 값은 턴 ID뿐이다.
- 그래서 새로 찍지 않고 있는 값을 쓴다. agent_core는 바꾸지 않는다.
- 턴 번호(`absolute_turn`)로 앞뒤를 가리는 안도 버렸다. ACP 임시 ID에는 그 번호가 없다.
- 장점: 이미 쌓인 기록 대부분(msx는 4,042번째 atom부터)이 바로 이름을 가진다. 기록을 다시 쓰지 않는다.
- 단점: 턴 안 순번은 표현마다 다르다. 실제 기록의 3번째 atom과 다시 만든 목록의 1번째 atom은 다른 것이다. §5.1에서 다룬다.

### D2. 압축 지점은 「앞에서부터 이어 덮은 끝」과 「그 뒤에 따로 보관한 atom」을 적는다

```ocaml
type extent =
  | Whole_turn
  | Up_to of { ordinal : int; settled : Ids.Turn_id.t option }

type through =
  | Through_leading of int
  | Through_turn of { turn : Ids.Turn_id.t; extent : extent }

type coverage =
  { through : through option  (* 목록 앞에서부터 이어서 덮은 끝 *)
  ; beyond : name list        (* through 뒤에 있지만 이미 보관한 atom *)
  }
```

- 생산자는 자기 목록과 함께 버린 atom을 넘긴다. 앞에서부터 이어진 개수(`prefix`)와 그 뒤에서 따로 버린 번호(`later`)다.
- 앞에서부터 이어진 부분의 마지막 atom이 `through`다.
- 그 다음 atom이 있고 다른 턴이면 `Whole_turn`이다. 다음 atom이 없거나 같은 턴이면 `Up_to`다. 진행 중인 턴을 다 덮었다고 하지 않는다.
- `Up_to`의 `settled`는 모든 atom이 덮인 마지막 턴이다. 경계 턴 바로 앞의 턴이다. 정식 턴 저장소가 이 값으로 cutoff를 정한다(D6).
- `Whole_turn`이면 경계 턴 자체가 settled다.
- 이어지지 않는 나머지는 `beyond`에 적는다. Agent Core는 크기 거절 뒤 현재 턴의 끝난 도구 왕복을 골라 버린다(`droppable_current_turn_tool_atoms`). 이 atom들이 여기로 간다.
- 새 경계가 이전 경계보다 앞이면 이전 경계를 그대로 둔다. 덮은 범위는 줄지 않는다.
- 새 경계가 덮게 된 `beyond` 항목은 지운다. 지금 목록에 없는 `beyond` 항목도 지운다.

### D3. 목록에서 덮인 앞부분을 찾는다

- `Through_leading k`: 맨 앞 무명 atom 중 `Leading j`(`j ≤ k`)가 덮인다.
- `Through_turn {turn = b; extent}`: 목록에서 `b`의 첫 atom을 찾는다.
  - 찾지 못하면 아무것도 덮이지 않는다.
  - 찾으면 그 앞의 atom은 모두 덮인다. 기록은 뒤에 붙기만 하므로 `b`보다 앞선 atom은 `b`보다 먼저 버려졌다.
  - `b`의 이어진 atom 중 `Whole_turn`이면 전부, `Up_to {ordinal = k}`이면 순번 `k`까지 덮인다.
- `beyond`에 있는 atom은 생산자에게만 덮인 것이다. 소비자는 잘라 내지 않는다(D5).
- 경계 턴이 목록에 없으면 덮인 것이 없다고 본다. 잘못 자르는 쪽으로는 가지 않는다(§5.4).

### D4. 생산자는 새로 버린 atom만 인코딩한다

- 생산자 일곱 곳은 `~evicted_messages` 대신 `~messages`와 버린 atom(`prefix`, `later`)을 넘긴다.
- 이름 짓기는 목록 전체를 한 번 훑는다. 메타데이터만 읽는다.
- 이전 압축 지점이 덮은 atom과 `beyond`에 있는 atom은 건너뛴다. 새로 버린 atom이 없으면 `Ok None`이다.
- 새로 버린 atom만 JSON으로 인코딩해 보관한다.
- 쓰지 않던 `?blob_store` 인자를 없앤다. 생산자가 그 값을 만들려고 부르던 `require_reader` 확인도 없어진다.

### D5. 소비자는 메타데이터만 한 번 훑는다

- `messages_after_anchor`는 D3의 덮인 구간 끝과 inline 압축 지점 위치 중 뒤쪽 바로 다음부터 돌려준다.
- `beyond` atom은 잘라 내지 않는다. 덮인 구간 뒤에 있으므로 지금 epoch의 기록이다.
- 직렬화, 해시, 문자열 접두어 비교를 하지 않는다.

### D6. 정식 턴 저장소의 cutoff는 settled 턴으로 정한다

- cutoff는 `turn_id`가 압축 지점의 settled 턴과 같은 행의 seq다.
- settled 턴이 없거나 그 행이 없으면 cutoff를 바꾸지 않는다.
- 보관 atom을 읽지 않고 메시지 글자를 맞춰 보지 않는다. `find_cutoff_seq_for_evicted_turns`와 `load_handoff_context`의 보관 atom 우회 경로를 지운다.

### D7. 저장소를 하드컷한다

- `<keeper>.compaction.db`에 `PRAGMA user_version`을 둔다. 표가 있는데 값이 다르면 `Schema_not_current`로 거절한다.
- 표: `compaction_epochs(epoch_id, anchor_json, trigger_json, previous_epoch_id)`, `archived_atoms(epoch_id, sequence_ord, atom_json, messages_json)`. 기본 키는 `(epoch_id, sequence_ord)`다. 해시가 겹칠 일이 없어 `-ep` 꼬리를 붙이지 않는다.
- `covers_through_turn` 열, `evicted_turn_ids_json` 열, `active_microcompacted_handles` 표를 지운다. 앞의 둘은 `anchor_json`과 `archived_atoms`에서 얻는다. 마지막 표는 운영 경로가 쓰지 않는다(D8).
- `<keeper>.canonical-turns.db`에도 `user_version`을 둔다. 이 저장소의 `history_resets.reset_after_anchor_epoch`, `compaction_watermarks.epoch_id`, `canonical_turns.compaction_epoch_id`는 압축 epoch 번호를 기억한다. 압축 DB만 새로 만들면 epoch가 1부터 다시 세어진다. 그러면 새 압축 지점이 리셋 전 것으로 무시되고, 같은 번호의 옛 watermark와 섞인다.
- 정식 턴 저장소에 남은 옛 열 추가 코드(`ALTER TABLE ... last_turn_id`)도 지운다.
- 옛 파일을 고치거나 옮기는 코드는 만들지 않는다.

### D8. 운영 경로가 부르지 않는 압축 파이프라인을 지운다

- `compact_and_project`, `project_for_provider`, `microcompact_turns`, `commit_epoch`, `list_epochs`, `load_archived_turn`과 이것만 쓰는 타입·표를 지운다.
- `keeper_compaction.mli`도 「운영 턴 드라이버는 `compact_evicted_messages`를 쓴다」고 적는다. `lib/`·`bin/`에서 부르는 곳이 없다(시험만 부른다).
- D6 뒤에는 `load_archived_turns_for_epoch`도 운영에서 부르는 곳이 없다. 같이 지운다.
- 이름 타입이 바뀌므로, 지우지 않으면 아무도 부르지 않는 코드를 새 타입에 맞춰 고쳐야 한다.

## 4. 바뀌는 동작

- 리더처럼 ACP로 도는 Keeper는 압축 지점 앞의 도구 호출을 더 이상 이어 붙이지 않는다. 지금은 해시가 맞지 않아 기록 전체의 도구를 이어 붙인다. `History_carry`의 원래 뜻(「압축 경계를 넘으면 깨끗하게 다시 시작한다」, `keeper_identity_tool_search.mli`)으로 돌아간다.
- 모델이 보는 압축 지점 글의 `covers_through=`와 `[turn:…]` 표시가 `covers=`와 `[atom:…]`로 바뀐다.
- 대시보드 API의 `covers_through_turn` 필드는 문자열로 남는다. 내용만 새 이름의 표시 문자열로 바뀐다. TUI는 이 문자열을 그대로 보여 준다.
- 턴 일부만 버린 압축은 그 턴의 정식 턴 행을 지우지 않는다(§2.3의 마지막 증상이 없어진다).

## 5. 경계 조건과 한계

### 5.1 표현이 다른 목록 사이의 부분 덮음

- 턴 하나를 다 덮었는지는 표현과 상관없이 맞는다(`Whole_turn`).
- 턴 일부만 덮었으면 순번은 그 압축 지점을 만든 표현에서의 값이다. 다른 표현의 소비자는 자기 목록의 순번으로 비교한다.
- 예: Agent Core가 턴 T의 4번째 atom까지 덮은 뒤 ACP로 넘어갔다. ACP 목록의 T는 atom 둘(사용자, 어시스턴트 요약)이다. 둘 다 덮였다고 본다. T의 나머지 작업은 이 압축 지점의 요약에 들어가지 않는다. T의 행은 settled가 아니라서 정식 턴 저장소와 handoff에 그대로 남는다.
- 같은 턴 안에서 런타임을 바꾼 Keeper의 압축 요약이 덜 자세해진다. 행이 남으므로 handoff에서는 사라지지 않는다.

### 5.2 턴 중간의 참조 없는 사용자 메시지

- 지금 턴의 다음 순번이 된다(§1.4의 740개).
- 턴 ID 없이 시작한 턴이 있다면 앞 턴의 atom으로 센다. 생산자와 소비자는 같은 메시지를 같은 규칙으로 읽으므로 같은 목록에서는 이름이 어긋나지 않는다.

### 5.3 맨 앞 무명 atom

- 턴 ID를 찍기 전의 기록이다. 새 기록의 사용자 입력은 모두 턴 ID를 단다.
- 이름은 목록 맨 앞에서부터의 위치다. 같은 기록을 받는 생산자와 소비자는 같은 위치를 본다. Pinned 메시지는 세지 않는다. 그래서 공식 클라이언트가 앞에 붙이는 과거 작업 참조(System 메시지)는 위치를 바꾸지 않는다.

### 5.4 경계 턴이 목록에 없을 때

- 소비자는 아무것도 자르지 않는다. 생산자는 이전 압축 지점이 덮은 것이 없다고 보고 버린 atom을 모두 보관한다.
- 덜 자르거나 한 번 더 보관할 수는 있어도, 덮지 않은 것을 잘라 내지는 않는다.
- 이런 경우가 있다.
  - 기록을 비운 뒤: 새 기록에는 옛 경계 턴이 없다. 자르지 않는 것이 맞다.
  - ACP가 다시 만든 목록: watermark 뒤의 행만 담는다. 경계 턴이 다 덮였으면 목록에 없다. 목록의 행은 모두 덮이지 않은 것이므로 맞다.
  - 공식 클라이언트 seed가 경계 턴보다 뒤에서 시작할 때: 버린 atom을 한 번 더 보관한다. 지금(`drop_covered_turns`가 못 찾으면 전부 보관)과 같다.

## 6. 하지 않는 것

- `hydrate_missing_turns`의 글자 비교는 압축 지점을 읽지 않는다. 별도 이슈로 남긴다.
- ACP 정식 턴 행을 처음부터 Keeper 턴 ID로 쓰는 일. ACP 런타임에 턴 ID를 넘기는 경로가 없어 따로 다룬다. 이 RFC는 임시 ID와 함께 동작한다(§1.5).
- `Utf8_sanitize`가 요청마다 전체 문자열을 훑는 문제(§1.1 두 번째)는 따로 다룬다.
- checkpoint 저장 1회 320 ms(재디코드, 소유 파일 `lstat` 연쇄)는 따로 다룬다.
- `History_carry` 계산을 배치 정책 확인 뒤로 미루는 일. D5로 비용이 작아져 이 RFC에서는 하지 않는다.

## 7. Fresh state required

서버를 모두 멈춘 뒤 Keeper마다 아래 파일을 지운다.

- `<base>/.masc/config/keepers/<keeper>.compaction.db`와 옆의 `-wal`, `-shm`, `-journal`
- `<base>/.masc/config/keepers/<keeper>.canonical-turns.db`와 옆의 `-wal`, `-shm`, `-journal`

지우면 이렇게 된다.

- 모든 Keeper가 압축 요약을 잃는다.
- Agent Core와 Claude Code·Codex·Antigravity Keeper는 다음 압축 때 checkpoint 기록에서 요약을 다시 만든다. checkpoint 기록은 앞에서 잘리지 않았다(§1.2).
- ACP Keeper는 정식 턴 저장소에서 이미 정리된 턴의 요약을 되찾지 못한다. 새 턴부터 다시 쌓는다. ACP 에이전트 자신의 세션은 그대로다.
- 아직 덮이지 않은 정식 턴 행(11-26 기준 리더 3행, code-reviewer 1행, msx 18행)이 사라진다.

지우지 않으면 새 빌드는 두 저장소를 `Schema_not_current`로 거절하고 경고를 남긴다. 압축은 커밋되지 않는다. 소비자는 기록을 자르지 않는다. 서버는 멈추지 않는다. blob 정리는 옛 압축 DB에서 멈춘다(참조를 읽지 못하면 지우지 않는다).

## 8. 검증

### 8.1 feature 시험

- 다시 만든 목록(ACP)으로 만든 압축 지점이 실제 기록을 그 턴 뒤에서 자른다.
- ACP 임시 ID를 단 마지막 턴이 있는 목록도 압축된다. 경계는 그 앞 턴이다.
- Agent Core의 현재 턴 도구 왕복 버리기(앞부분이 아닌 버리기) 뒤 같은 목록으로 다시 커밋하면 `Ok None`이다. 다음 앞부분 버리기는 이미 보관한 atom을 다시 보관하지 않는다.
- 경계 턴이 목록에 없으면 소비자는 자르지 않는다.
- 턴을 다 덮은 압축 지점은 정식 턴 저장소의 그 턴 행까지 지운다. 일부만 덮었으면 바로 앞 턴까지다.
- 옛 형식(`user_version` 0, 표 있음) 압축 DB와 정식 턴 저장소는 `Schema_not_current`로 거절된다.
- 맨 앞 무명 atom만 버린 뒤 턴 atom을 버리면 무명 atom을 다시 보관하지 않는다.

### 8.2 측정

- 수정 전: §1.1의 `sample` 결과.
- 수정 후: 같은 Keeper 구성으로 서버를 띄운 뒤 같은 명령으로 30초를 뜬다. `messages_after_anchor` 아래 inclusive 샘플 수와 `atom_hash` 유무를 비교한다.
- 명령: `sample <masc pid> 30 -file <out>`. 운영자가 새 빌드를 설치하고 Fresh state를 마친 뒤 돌린다.

## 9. 순서

1. 이 RFC.
2. D1~D8: atom 이름, 생산자 일곱 곳, 소비자, 정식 턴 저장소, 하드컷, 쓰지 않는 파이프라인 삭제, 시험, changelog. D8을 따로 내면 같은 시험 파일을 두 번 고쳐야 해서 한 PR에 둔다.
