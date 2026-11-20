---
rfc: "tui-hand-written-counts-fail-the-pr-check"
title: "TUI 소스에 손으로 적은 개수와 부호는 PR 검사에서 막힌다"
status: Draft
created: 2026-11-20
updated: 2026-11-20
author: claude
supersedes: []
superseded_by: null
related: ["tui-one-screen-grammar", "stack-type-check-runs-at-the-top"]
implementation_prs: []
---

# RFC: TUI 소스에 손으로 적은 개수와 부호는 PR 검사에서 막힌다 (tui-hand-written-counts-fail-the-pr-check)

## 0. 요약

RFC tui-one-screen-grammar §6.3 은 수를 이렇게 적는다.

- 잘린 개수는 `외 3` / `3 more` 다.
- 늘어난 값은 `+3`, 줄어든 값은 `−2`(U+2212)다.

`Masc_tui_value.Count` 의 `more`, `increase`, `decrease` 가 이 글자를 만든다.
2026-11-20 에 손으로 적은 표기를 이 함수로 옮겼다.
같은 날 다른 PR 셋이 손으로 적은 표기를 다시 넣었다. 열린 PR 하나도 다시 넣는다(§1).

이 RFC 는 필수 검사 `changes` job 에 단계 하나를 더한다.
그 단계는 PR 이 바꾼 `bin/masc_tui*.ml` 의 문자열 literal 을 읽는다.
손으로 적은 개수나 부호가 있으면 job 이 실패한다.

대가는 §5 에 있다. 사용자가 정할 것은 §7 에 있다.

## 1. 배경 (측정)

### 1.1 정리한 표기가 다시 생겼다

- #53800~#53841 이 잘린 개수 `+N more`·`외 N명` 과 하이픈 감소 `-N` 을 `Count` 로 옮겼다.
- 08:28Z 에 병합된 PR 셋이 같은 표기를 다시 넣었다.

| PR | 파일 | 다시 생긴 글자 |
|---|---|---|
| #53848 | `bin/masc_tui_render_keepers.ml` | ` 외 %d명` / ` +%d more` |
| #53849 | `bin/masc_tui_memory_recall_form.ml` 외 1 | `(외 %d건)` / `(+%d more)` |
| #53850 | `bin/masc_tui_keeper_chat_diff.ml` | `(일치당 +%d -%d)` |
| #53850 | `bin/masc_tui_render_lanes.ml` | `… %d more %s not rendered` |

- 열린 #53932 는 Keepers 상태 칸에 ` (+%d)` 를 더했다. stack 을 다시 쌓을 때 고쳤다.
- 출처는 `git log -S'<글자>' origin/main -- <파일>` 로 찾았다.

### 1.2 지금 남은 수

§3.2 규칙을 main `b9ac941a` 에 돌린 결과다. 시제품 스크립트는 문자열 literal 만 읽는다.

| 규칙 | main | #53934 병합 뒤 |
|---|---|---|
| `cut-off` | 11 | 6 |
| `plus` | 15 | 7 |
| `hyphen-minus` | 6 | 0 |

#53934 뒤에 남는 13곳은 §4.1 에 있다.

## 2. 문제

표기 규칙은 RFC 와 `Count` 에만 있다. PR 이 지켰는지는 사람이 읽어야 안다.
2026-11-19 하루에 PR 이 286개 열렸다(`gh api search/issues`, `created:2026-11-19`).
1.1 의 넷은 모두 다음 정리 때 이 세션이 찾았다.
찾을 때마다 고치는 PR 이 하나씩 더 생긴다.

## 3. 제안

### 3.1 무엇을 읽나

- 파일: PR 의 merge commit 에서 바뀐 `bin/masc_tui*.ml`.
- 글자: OCaml 문자열 literal(`"…"`, `{|…|}`). 주석 안의 문자열은 읽지 않는다.
- 문자 literal `'"'` 는 문자열의 시작이 아니다.

### 3.2 규칙

| 규칙 | 찾는 글자 | 대신 쓸 것 |
|---|---|---|
| `cut-off` | `%d more`, `+%d more`, `(+%d)`, 낱말 첫머리의 `외 %d` | `Count.more` |
| `plus` | 문자열 처음이나 공백·`(`·`[`·`/` 뒤의 `+%d`, `+%s` | `Count.increase` |
| `hyphen-minus` | 같은 자리의 `-%d`, `-%s` | `Count.decrease` |

`%d` 자리에는 `%s` 도 들어간다. `제외 %d` 의 `외` 는 낱말 첫머리가 아니라서 걸리지 않는다.

### 3.3 예외 표지

개수가 아닌 `+%d` 가 있다. vim 명령 `edit +12` 의 줄 번호가 그렇다.
이런 literal 은 같은 줄이나 바로 앞 줄에 표지를 단다.

```ocaml
(* tui-value: vim 줄 번호 인자다, 화면에 그리지 않는다 *)
Printf.sprintf "execute('edit +%d ' . fnameescape(%s))" line path
```

- 표지는 `(* tui-value: <이유> *)` 다. 이유가 비면 검사가 실패한다.
- 표지는 자기가 걸친 줄과 그다음 줄에서 시작하는 literal 만 풀어 준다. 파일 전체를 풀어 주는
  표지는 없다. `next_run` 처럼 한 줄에 한국어·영어 literal 이 같이 있으면 표지 하나가 둘을 푼다.

### 3.4 어디서 도나

`changes` job 에 Python 단계를 하나 더한다.

- 스크립트는 `scripts/ci/pr_tui_value_strings.py` 다.
- 앞의 두 단계(`pr_changelog_fragments.py`, `pr_no_merge_commits.py`)처럼 merge commit 에서 스크립트를 읽는다.
- 바뀐 파일만 가져온다. 이미 받은 blobless fetch 에 파일 내용만 더한다.
- stack 의 아래층도 따로 읽는다. 아래층이 꼭대기보다 먼저 병합될 수 있어서다.
- 실패 줄은 `파일:줄: 규칙: 글자 -> 대신 쓸 함수` 로 찍는다.
- 같은 단계가 merge commit 의 단위 시험(`scripts/ci/tests/test_pr_tui_value_strings.py`)을 먼저 돌린다.
  읽는 부분이 틀리면 모든 TUI PR 이 막히므로, 시험이 실패하면 검사를 돌리지 않고 단계가 실패한다.

`type-check` job 이 아니라 `changes` 에 두는 이유는 둘이다.
`type-check` 는 소스가 바뀐 PR 에서만 돌고, 몇 분씩 걸린다.
`changes` 는 모든 PR 에서 돌고, 이미 같은 모양의 검사를 두 개 돌린다.

### 3.5 순서

| 층 | 하는 일 | 확인 |
|---|---|---|
| L1 | main 에 남은 hit 를 고치고, 예외에 표지를 단다 | 시제품 스크립트가 main 에서 0 을 낸다 |
| L2 | 스크립트, `scripts/ci/tests/` 단위 시험, workflow 단계 | 일부러 넣은 hit 하나로 `changes` 가 실패하는 실행 하나 |

L2 는 `.github/workflows/` 를 바꾼다. 승인 worker 는 이런 PR 을 병합하지 않는다. 운영자가 병합한다.

## 4. 범위

### 4.1 L1 이 고칠 곳 (#53934 병합 뒤)

| 파일 | 글자 | 처리 |
|---|---|---|
| `bin/masc_tui_keeper_chat_diff.ml` 세 곳 | `(%d more recorded …)` | `Count.more` |
| `bin/masc_tui_lane_addons.ml` | `%s %d more` | `Count.more` |
| `bin/masc_tui_render_lanes.ml` | `… %d more %s not rendered` | `Count.more` |
| 붙여넣기 알림 | `%d more were dropped` | `Count.more` |
| `bin/masc_tui_exit_reason.ml` | `[+%d bytes]` | 잘린 개수다. `Count.more` |
| `bin/masc_tui_render_board.ml` | 투표 `+%d` / 음수 `%d` | `Count.increase` / `Count.decrease` |
| `bin/masc_tui.ml` | 편집기 `+%d` 줄 인자 | 표지 |
| `bin/masc_tui_editor_jump.ml` | vim `edit +%d` | 표지 |
| `bin/masc_tui_keeper_memory_reading.ml` | 지난 시각 `+%s` | 표지 |
| `bin/masc_tui_keeper_next_run.ml` 두 곳 | `늦음 +%s` / `late +%s` | §7 D2 |

### 4.2 하지 않는 것

- 1,000 이상 쉼표(`%d bytes` → `Count.grouped`)는 넣지 않는다. `revision %d` 처럼 작은 수가 확실한 자리와 글자로 가를 수 없다. 거짓 실패가 많아진다.
- 한국어 갈래만 있는 표기(`필드 %d개 더 있음`)는 찾지 않는다. 같은 자리의 영어 갈래가 `%d more` 로 걸린다.
- 대시보드(`dashboard/`)와 서버 문자열은 읽지 않는다.

## 5. 대가

- 글자만 보는 검사다. `"+" ^ string_of_int n` 처럼 literal 을 쪼개면 지나간다. 이 몫은 리뷰에 남는다.
- 바뀐 파일 전체를 읽는다. PR 이 손대지 않은 줄의 hit 도 그 PR 을 막는다. L1 이 main 을 0 으로 만든 뒤에 L2 를 켜는 이유다.
- `changes` 는 필수 검사다. 스크립트가 잘못 실패하면 모든 TUI PR 이 막힌다. 그래서 문자열을 읽는 부분(주석 중첩, escape, `'"'`, `{|…|}`)을 단위 시험으로 고정한다.
- 표지가 늘면 검사가 헐거워진다. 스크립트는 통과할 때도 표지 수를 찍는다.

## 6. 검증

- 단위 시험: 규칙마다 걸리는 literal 하나와 안 걸리는 literal 하나, 표지, 빈 이유 표지, 주석 안 문자열, `'"'`, `{|…|}`.
- L1 PR: 시제품 스크립트를 PR head 에 돌린 출력(규칙별 0)을 본문에 적는다.
- L2 PR: hit 하나를 넣은 커밋에서 `changes` 가 실패한 실행 링크와, 되돌린 커밋에서 통과한 실행 링크를 본문에 적는다.

## 7. 사용자가 정할 것

- **D1. 읽는 범위.** 바뀐 파일 전체(제안) / PR 이 더한 줄만.
  더한 줄만 읽으면 L1 없이 켤 수 있다. 대신 diff 를 줄 번호로 다시 맞추는 코드가 더 생긴다.
- **D2. 늦은 시간 `늦음 +5m`.** 표지로 둔다(제안) / `5m 늦음` 처럼 부호 없이 바꾼다.
  여기서 `+` 는 늘어난 값이 아니라 "예정보다 뒤" 를 뜻한다. 개수 변화가 아니라서 표지로 둘 수 있다.
  부호를 빼면 §6.3 과 부딪칠 글자가 아예 없어진다.
