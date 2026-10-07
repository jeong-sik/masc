---
rfc: "tui-decisions-out-of-the-executable"
title: "TUI 의 결정을 실행 파일 밖으로 꺼내 단위 테스트로 확인하고, PTY 는 터미널이 필요한 것만 남긴다"
status: Draft
created: 2026-10-07
updated: 2026-10-07
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: TUI 의 결정을 실행 파일 밖으로 (tui-decisions-out-of-the-executable)

## 0. 요약

TUI 가 "무엇을 거절하고, 무엇을 보내고, 어디로 가는가"를 정하는 코드는 대부분
`bin/masc_tui.ml`(27,548줄)과 `bin/masc_tui_render.ml`(14,218줄)에 있다. 두 파일은
실행 파일 `masc_tui` 에 묶여 있어서(`bin/dune` 의 `(executable (name masc_tui) …)`)
단위 테스트가 가져다 쓸 수 없다. 그래서 이 결정은 진짜 TUI 를 가짜 터미널(PTY)에
띄우는 테스트로만 확인한다.

PTY 테스트는 느리고, 머신 부하에 따라 결과가 바뀌고, 화면을 그리는 방식이 바뀌면
동작이 멀쩡해도 같이 깨진다. v0.50.0 은 이 때문에 막혔다.

이 RFC 는 결정을 순수 함수로 꺼내 라이브러리에 두고 단위 테스트로 확인한다.
같은 결정이 여러 군데 복사돼 있으면 함수 하나로 모은다. 단위 테스트가 확인하게 된
주장은 PTY 에서 지우고, PTY 에는 진짜 터미널이 필요한 것만 남긴다.

## 1. 실측 (2026-10-07)

| 잰 것 | 값 | 출처 |
|---|---|---|
| TUI PTY 테스트 파일 | 107개 | `test/test_tui_*_pty.py` |
| PTY 107개를 하나씩 돌린 합계 | 2,023초(33.7분) | main `03053945bd`, 로컬 6개 병렬 |
| 그중 오래 걸리는 20개의 몫 | 53% | 같은 측정 |
| 로컬 부하(load average 약 125)에서 실패 | 107개 중 24개 | 같은 측정 |
| v0.50.0 RC 에서 실패한 테스트 파일 | 21개 | run `37547627776`, `test-suite.log` |
| 그 21개 중 P0·P1 제품 결함 | 0개 | 아래 판정 |
| 그 21개 중 지금 바로 지울 수 있는 것 | 0개 | 아래 판정 |
| `masc_tui.ml` 에 복사된 작업공간 신원 확인 | 22곳 | `workspace_identity <> Workspace_identity_match` |
| `masc_tui.ml` 에 복사된 Task 상세 스크롤 초기화 | 10곳 | `task_detail_scroll <- 0` |

RC 실패 21개를 하나씩 읽은 결과다.

- 단위 테스트는 데이터를 읽고 해석하는 층만 확인한다. 화면에 무엇을 그리는지,
  키를 누르면 무엇을 하는지, 신원이 확인되지 않았을 때 무엇을 거절하는지는
  실행 파일 안에 있어서 PTY 만 확인한다. 그래서 21개 모두 PTY 에만 있는 주장이
  하나 이상 있었다.
- 실패 원인은 대부분 테스트 쪽이다. 화면이 그대로면 TUI 는 아무것도 다시 쓰지
  않는데(`masc_tui_frame_presenter.ml` 의 `Unchanged`) 테스트가 새 프레임을
  기다렸거나, 화면 형식·팔레트 이름이 바뀌었는데 예전 글자를 찾았다.
- PTY 가 실제 결함을 잡은 경우도 있다. 모두 P2 이하다.

| 테스트 | 잡은 결함 | 등급 | 고친 곳 |
|---|---|---|---|
| `answering_layout` | 부팅 직후 Answering 이 최대 60초 "아직 안 읽음" | P2 | #41478 |
| `runtime_status` | 80×16 에서 선택한 줄이 가려짐 | P2 | #41452 (단위 테스트는 추가되지 않음) |
| `home_failure_task`, `home_queue_identity` | 신원 읽기가 한 번 실패하면 열린 채팅이 닫힘 | P2 | #41520 |
| `review_verdict_layout` | 30칸 너비에서 위치 표시가 없음 | P3 | 없음 |
| `candle_currency` | 부팅 중 Candle 이 "사용 불가"로 보임 | P3 | 없음 |

## 2. 문제

1. **결정이 실행 파일 안에 있다.** 단위 테스트가 닿지 못하니, 한 줄짜리 판단도
   TUI 전체를 띄워서 확인한다.
2. **같은 결정이 복사돼 있다.** 신원 확인 22곳, Task 상세를 열 때의 초기화 10곳.
   한 곳을 고치면 나머지는 그대로 남는다. PTY 는 그중 몇 경로만 지난다.
3. **PTY 테스트는 화면 출력에 묶여 있다.** 보호하려는 동작(예: "신원이 확인되지
   않으면 POST 하지 않는다")은 멀쩡한데, 그 앞의 "새 프레임을 기다림"이 깨져서
   테스트가 실패한다.
4. **그 실패가 릴리스를 막는다.** 릴리스는 전체 테스트가 초록이어야 하고, 전체
   테스트는 릴리스 때만 돈다. main 에서 깨진 PTY 테스트가 릴리스 때 한꺼번에
   드러난다.

## 3. 결정

### 3.1 결정은 순수 함수로, 라이브러리에

"상태와 입력을 받아 무엇을 할지 돌려주는" 함수로 꺼낸다. 화면을 다시 그리거나
요청을 보내는 일은 `masc_tui.ml` 에 남고, 그 함수의 결과를 실행만 한다.

```ocaml
(* 예: 결정을 내려도 되는가. 22곳이 이 함수 하나를 부른다. *)
type refusal =
  | Identity_unread
  | Identity_mismatch

val decision_authority
  :  workspace_identity:workspace_identity
  -> server_identity:server_identity option
  -> (server_identity, refusal) result
```

- 결과는 닫힌 variant 다. 거절 문구는 호출한 쪽이 `refusal` 을 받아 만든다.
- 모듈은 지금 저장소 방식대로 `bin/dune` 에 라이브러리로 둔다
  ("A library so a test can drive it").

### 3.2 복사본은 함수 하나로

같은 결정의 복사본을 모두 그 함수 호출로 바꾼다. 일부만 바꾸고 나머지를 다음 PR 로
미루지 않는다. 한 PR 이 한 결정의 모든 자리를 바꾼다.

### 3.3 주장이 옮겨지면 PTY 에서 지운다

- 단위 테스트가 어떤 주장을 확인하게 되면, 같은 주장을 보던 PTY 단언을 지운다.
- 파일의 보호 주장이 모두 옮겨지면 파일을 지운다. `test/dune` 의 규칙과 그 파일을
  import 하는 다른 PTY 파일도 같이 정리한다.
- 제품 코드를 옮기는 PR 과 PTY 를 지우는 PR 을 나눈다. 옮기는 PR 은 동작을 바꾸지 않는다.
- 테스트만 고치는 조각(1~4번)은 한 PR 에서 옮기고 지운다. 리뷰어가 새 확인과 지운 확인을
  나란히 봐야 같은 주장인지 판단할 수 있다.
- 지우기 전에 그 파일만 누르던 키가 있는지 찾는다. 있으면 남는 PTY 파일로 옮긴다.
  1번에서 접힘 키(`d`)와 출력 칸의 Home 이 그랬다.

### 3.4 PTY 에 남기는 것

진짜 터미널이 있어야만 확인할 수 있는 것만 남긴다.

- 터미널에 보내는 원시 이스케이프: Kitty 그림 배치와 제거.
- 터미널 크기 변화에 대한 반응 자체(크기별 내용은 단위 테스트로 그린다).
- `$EDITOR` 에 터미널을 넘겼다 돌려받는 왕복 하나.
- 화면마다 "켜지고, 키 하나가 닿는다"를 보는 짧은 시나리오 하나.

### 3.5 화면 그리기도 터미널 없이 확인한다

여러 PTY 테스트가 "이 너비에서 이 칸이 다 보인다"를 확인한다. 이건 그리는 함수에
상태와 너비를 주고 줄 목록을 받아 확인하면 된다. 지금 저장소에 같은 방식의 테스트가
있다(`test_tui_chat_queue_wiring.ml` 이 `Terminal_size_cache.refresh` 뒤 `render_*` 의
`frame.lines` 를 읽는다). 실행 파일에 묶인 그리기 함수(`task_detail_lines`,
`verification_detail_lines`, `measurement_*_lines` 등)는 라이브러리 모듈로 옮긴다.

## 4. 다른 방법과 비교

| 방법 | 좋은 점 | 나쁜 점 |
|---|---|---|
| PTY 테스트를 하나씩 고친다 | 바로 초록이 된다 | 같은 고침을 파일마다 반복한다. 화면이 바뀌면 또 깨진다 |
| 하네스의 "기다리기"를 느슨하게 바꾼다 | 한 번에 여러 파일이 통과한다 | 키를 누르기 전에 있던 글자로 통과해서, 보호하던 것이 사라질 수 있다 |
| PTY 테스트를 그냥 지운다 | 가장 빠르다 | 21개 모두 PTY 에만 있는 주장이 있었다. P2 결함 넷을 잡은 테스트도 지워진다 |
| **결정을 꺼내 단위 테스트로 옮긴다 (이 RFC)** | 밀리초 단위, 부하에 안 흔들림, 복사본이 사라짐 | `masc_tui.ml` 을 여러 세션이 동시에 고쳐서 충돌이 잦다. 조각을 작게 나눠야 한다 |

## 5. 나눠 올리는 순서

조각 하나가 PR 하나다. `masc_tui.ml` 을 건드리지 않는 조각부터 한다.

| 순서 | 조각 | `masc_tui.ml` 수정 | 끝나면 지울 수 있는 것 |
|---|---|---|---|
| 1 | Librarian: 진짜 생산자 JSON 을 `Tui_decode` 로 읽는 단언을 기존 OCaml 테스트에 추가 (#41626) | 없음 | `test_tui_librarian_absorb_gate.py`, `test_tui_librarian_context_review.py` |
| 2 | Home: `masc_tui_home` 의 순수 함수(`home_decision_rows`, `home_selected_action`, `home_decision_window`, `reconcile_home_request_detail`)에 `test_tui_home.ml` 추가 | 없음 | `home_decision_cards` 의 선택·창·중복 주장 |
| 3 | Answering: `overlay ~width` 에 긴 이름·CJK 단위 테스트 | 없음 | `answering_layout` 의 너비 주장 |
| 4 | Runtime: 권한 칸이 4줄인 픽스처로 짧은 화면 단위 테스트(#41452 가 고친 결함의 재발 방지) | 없음 | `runtime_status` 의 선택 줄 주장 |
| 5 | 신원 확인 22곳을 `decision_authority` 하나로 | 있음(22곳) | `home_identity_decision`, 여러 파일의 "신원 미확인이면 거절" 주장 |
| 6 | Task 상세 열기 10곳을 `open_task_detail` 하나로, 빈 사유 취소 결정 꺼내기 | 있음 | `task_metadata_viewport` 의 따라가기·빈 사유 주장 |
| 7 | Goal 두 번 누르기(확인 뒤 POST 한 번) 결정 꺼내기 | 있음 | `goal_detail_viewport` 의 POST 주장 |
| 8 | Answering·Home 키 처리 단계를 순수 step 함수로 | 있음 | `answering_layout`, `home_*` 의 키 주장 |
| 9 | Keeper 만들기: `decide`·`after_receipt` 꺼내기 | 있음 | `keeper_create_journey` |
| 10 | 상세 화면 그리기 함수를 라이브러리로 옮기고 너비별 단위 테스트 | 있음(`masc_tui_render.ml`) | `measurement`, `review_verdict_layout`, `task_metadata`, `goal_detail` 의 "다 보인다" 주장 |

5번 이후는 지금 열려 있는 신원 관련 PR(#41518, #41520)이 들어간 뒤에 시작한다.
같은 줄을 고치기 때문이다.

## 6. 정할 것

1. 5번의 `refusal` 을 호출한 쪽 문구("Cannot decide", "Cannot send" 등 11종)와
   어떻게 잇는가. 호출한 쪽이 동작 이름을 넘기는 방식을 제안한다.
2. 남기는 "화면마다 짧은 PTY 하나"의 목록을 누가 정하는가.
3. 새 PTY 테스트를 받을 때 리뷰에서 "터미널이 왜 필요한가"를 묻는 것으로 충분한가.
   자동 검사는 만들지 않는다.

## 7. 검증

조각마다 PR 본문에 아래를 적는다.

- 옮긴 주장과 그것을 확인하는 단위 테스트 이름.
- 그 단위 테스트가 주장을 깨뜨린 코드에서 실패하는지(일부러 망가뜨려 확인).
- 지운 PTY 단언·파일 수와, 줄어든 PTY 실행 시간(초).

전체 목표는 숫자로 본다. PTY 파일 수(지금 107), PTY 합계 시간(지금 2,023초),
릴리스 RC 에서 PTY 로 인한 실패 수(지금 21).

## 8. 다루지 않는 것

- 테스트 실행 파일 1,765개를 영역별로 묶는 일. 링크 시간을 줄이는 별개 작업이고,
  CI 에서 컴파일·링크·실행 시간을 나눠 재는 것(#41589)부터 한다.
- PTY 하네스의 기다리는 방식을 바꾸는 일.
- TUI 화면 구성이나 키 배치를 바꾸는 일.
