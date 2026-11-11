# 열린 이슈 지도의 근거 · 2026-11-11

[열린 이슈 1,094개 지도와 개선 계획](../../reports/2026-11-11-open-issue-map-and-plan.md)의 수치가 여기서 나왔다.

## 출처와 환경

- 저장소: `jeong-sik/masc`. 코드 기준은 `origin/main` `fe4399c0395a` 다.
- 이슈는 2026-11-11 19:50 KST 에 `gh api graphql` 로 받았다. 열린 이슈 1,094개는 본문까지, 닫힌 이슈 7,544개는 번호·시각·닫힌 이유·라벨만 받았다.
- PR 언급은 이슈 타임라인의 `CROSS_REFERENCED_EVENT` 와 `CONNECTED_EVENT` 를 이슈마다 앞에서 40개까지 받았다. 이슈 목록보다 조금 뒤에 받아서 그 사이 생긴 이슈 하나가 더 들어 있다.
- Ask 는 운영 중인 서버의 `<base-path>/.masc/keeper_ask/*.jsonl` 을 2026-11-11 22:21 KST 에 읽었다. 사건 종류와 시각만 셌다.
- 받은 이슈 원문과 Ask 기록은 여기에 넣지 않았다. 이슈는 GitHub 에서 다시 받을 수 있고, Ask 기록은 운영자의 런타임 데이터다.

## 파일

| 파일 | 하는 일 |
| --- | --- |
| `fetch_issues.py` | 열린 이슈(본문 포함)나 닫힌 이슈(메타만)를 JSONL 로 받는다 |
| `fetch_xrefs.py` | 열린 이슈마다 그 이슈를 언급한 PR 과 PR 의 상태를 받는다 |
| `measure.py` | 위 세 파일에서 보고서의 수치를 전부 뽑는다 |
| `ask_counts.py` | Ask 를 물은 수, 답한 수, 대기 수, 답까지 걸린 시간을 센다 |
| `clusters.json` | 제목 묶음별 이슈 번호, 약속에 닿는 이슈 번호, 많이 인용된 이슈 |
| `label-audit.json` | 라벨을 가리고 다시 매긴 표본 50개: 원래 `impact` 라벨, 다시 매긴 등급, 망설임 표시, 이유 한 줄 |
| `label-audit-rubric.md` | 2차 재판정에서 판정자에게 준 기준 |
| `label-audit-2.json` | 1·2순위 라벨이 붙은 106개를 두 판정자가 따로 다시 매긴 결과 |
| `classify-rubric.md` | 본문 분류에서 판정자에게 준 기준 |
| `body-classification.json` | 그 106개 밖의 열린 이슈를 본문을 읽고 매긴 결과: 일어난 일인지, 등급, 바라는 것, 묶음 |
| `close-verification.json` | 닫기 후보 가운데 검증을 마친 120개의 판정과 조치 |
| `audit_counts.py` | `label-audit-2.json` 과 `close-verification.json` 에서 보고서의 수를 다시 센다 |
| `classify_counts.py` | `body-classification.json` 에서 보고서의 수를 다시 센다 |
| `close_candidates.py` | `body-classification.json` 에서 보고서 10절 3번의 닫기 후보와 직접 읽을 표본을 다시 만든다 |
| `check_quotes.py`, `quote-check.json` | 보고서 6절의 인용문이 그 주소의 글에 글자 그대로 있는지 본다 |

## 명령

```sh
python3 fetch_issues.py open /tmp/open.jsonl
python3 fetch_issues.py closed /tmp/closed.jsonl
python3 fetch_xrefs.py /tmp/xrefs.jsonl
python3 measure.py /tmp/open.jsonl /tmp/closed.jsonl /tmp/xrefs.jsonl /tmp/clusters.json
python3 ask_counts.py <base-path>/.masc/keeper_ask
python3 audit_counts.py label-audit-2.json close-verification.json
python3 classify_counts.py body-classification.json
python3 close_candidates.py body-classification.json /tmp/open.jsonl /tmp/xrefs.jsonl
python3 check_quotes.py quote-check.json
```

보고서 4절의 Native Stack 42853 은 PR 번호가 아니라 스택 번호다. 그 스택의 PR 은 이렇게 읽었다.

```sh
gh api repos/jeong-sik/masc/stacks/42853 --jq '[.pull_requests[] | .number] | @csv'
```

결과는 `42847,42848,42849,42850,42878,42880,42884` 였고 일곱 개 모두 2026-10-13 에 병합됐다.

2026-11-01~11-10 의 병합 PR, 생긴 이슈, 닫힌 이슈는 검색으로 셌다.

```sh
gh api graphql -f query='{
  merged: search(query:"repo:jeong-sik/masc is:pr is:merged merged:2026-11-01..2026-11-10", type: ISSUE, first:1){ issueCount }
  created: search(query:"repo:jeong-sik/masc is:issue created:2026-11-01..2026-11-10", type: ISSUE, first:1){ issueCount }
  closed: search(query:"repo:jeong-sik/masc is:issue closed:2026-11-01..2026-11-10", type: ISSUE, first:1){ issueCount }
}'
```

결과는 `merged 3079, created 598, closed 300` 이었다. 같은 검색에 `base:main` 을 붙이면 병합 PR 은 1,811개였다(나머지는 스택의 위층이 아래층 브랜치로 병합된 것이다).

RFC 문서의 상태는 `origin/main` 의 `docs/rfc/*.md` 에서 첫 `status:` 줄을 셌다.

```sh
git grep -h -m1 '^status:' origin/main -- 'docs/rfc/*.md' | sed 's/status: *//; s/"//g' | awk '{print $1}' | sort | uniq -c | sort -rn
```

결과는 `Draft 344, Implemented 65, Active 45, Accepted 13, Dropped 4, Rejected 1, Proposed 1, Evidence 1` 이었다. 파일은 482개이고 그중 474개에 상태 줄이 있다.

예약 실행된 전체 시험의 결과는 이렇게 셌다.

```sh
gh run list --repo jeong-sik/masc --workflow Test --event schedule --limit 80 --json conclusion,createdAt
```

2026-09-04 부터 2026-11-10 까지 57번이고 `failure 52, success 4, cancelled 1` 이었다. 마지막 `success` 는 2026-09-27 이다.

MASC Task 수(열린 Task 554, 그중 배정 안 된 todo 448)는 2026-11-11 19:50 KST 에 `masc_status` 로 읽었다.

## 관측한 값

`measure.py` 의 출력:

```text
snapshot (latest updatedAt among open issues): 2026-11-11T10:37:31+00:00
== totals ==
open 1094 closed 7544
open by created month {'2026-08': 94, '2026-09': 268, '2026-10': 280, '2026-11': 452}
authors {'jeong-sik': 1047, 'anyang-keepers': 36, 'pangyo-preachers': 7, 'github-actions': 2, 'be-sleepers': 2}
comments == 0: 509
older than N days: {7: 782, 14: 579, 30: 422, 60: 138, 90: 25}

== labels ==
kind {'defect': 651, 'gap': 167, 'inquiry': 60, 'erosion': 54, 'capability': 43, 'perf': 1} none 118 issues with at least one 976
impact {'degrades': 502, 'blinds-operator': 187, 'internal': 173, 'breaks-continuity': 81, 'breaks-collab': 25} none 126 issues with at least one 968
area {'dashboard': 187, 'tools': 112, 'runtime': 110, 'persistence': 94, 'ci': 88, 'continuity': 72, 'verification': 64, 'transport': 63, 'turn': 63, 'observability': 56, 'connector': 32, 'goal-task': 18, 'collab': 14, 'streaming': 1, 'keeper': 1, 'board': 1, 'tui': 1} none 121 issues with at least one 973
root {'ssot': 166, 'boundary': 159, 'variant': 151, 'silent': 117, 'string': 46, 'telemetry': 43, 'det': 39, 'ndt': 37} none 366 issues with at least one 728
no label at all: 116 of which created after the newest labelled issue (2026-11-10T08:22:43Z): 60
touches promise (impact/breaks-continuity or breaks-collab): 106 = 9.7% of open, 11.0% of impact-labelled
must-do: 36 of which touch promise: 16

== title clusters: count / touch promise / created in November ==
tui 132 3 75
follow_up 82 9 37
failing_test 66 1 41
unbounded_growth 41 5 19
side_feature 31 2 8
old_data 31 11 16
n_of_m 31 2 12
in any title cluster: 366
n_of_m in title or body: 315

== #number references in title and body ==
cites another open issue: 180
cites a closed issue: 191
cites a number that is not an issue (a pull request): 731
cites nothing: 261
not linked to any other open issue: 804
most cited open issues: [(48724, 9), (50828, 6), (46477, 5), (47266, 5), (46413, 4), (46410, 3), (46472, 3), (35415, 3), (46507, 3), (47444, 3), (47452, 3), (47454, 3), (47482, 3), (47502, 3), (51199, 3)]

== merged pull requests that mention the issue ==
a later-numbered merged PR mentions it: 588 (with a closing keyword: 0 )
only earlier-numbered merged PRs mention it (the issue came out of a PR): 149
no merged PR mentions it: 357

== week (Monday): created closed backlog ==
2026-07-27 448 600 572
2026-08-03 362 75 859
2026-08-10 237 183 913
2026-08-17 242 322 833
2026-08-24 445 235 1043
2026-08-31 316 160 1199
2026-09-07 341 127 1413
2026-09-14 364 106 1671
2026-09-21 524 955 1240
2026-09-28 276 746 770
2026-10-05 129 86 813
2026-10-12 122 168 767
2026-10-19 287 308 746
2026-10-26 254 156 844
2026-11-02 379 241 982
2026-11-09 165 53 1094
closed stateReason: [('COMPLETED', 6205), ('NOT_PLANNED', 1271), ('DUPLICATE', 68)]
```

`ask_counts.py` 의 출력:

```text
asked 1145 answered 949 withdrawn 196 pending 0
first asked 2026-09-03T03:29 last asked 2026-11-11T10:40
hours from asked to answered: median 0.38 p75 2.32 p90 6.82 max 40.2
asked per week (Monday): {'2026-08-31': 28, '2026-09-07': 29, '2026-09-14': 65, '2026-09-21': 187, '2026-09-28': 146, '2026-10-05': 98, '2026-10-12': 117, '2026-10-19': 106, '2026-10-26': 108, '2026-11-02': 128, '2026-11-09': 133}
```

## 라벨 눈가림 재판정

`impact` 라벨이 믿을 만한지 보려고 표본 50개를 라벨을 가리고 다시 매겼다.

- 표본: 난수 씨앗 20261111 로 1·2순위 라벨(`breaks-continuity`, `breaks-collab`)에서 20개, 3~5순위 라벨에서 20개, `impact` 라벨이 없는 것에서 10개를 뽑았다.
- 가림: 본문에서 `masc-triage` 블록과 "분류" 절, `impact:` 같은 줄을 지웠다. 지운 뒤 본문에 라벨 낱말이 남은 것은 0개였다.
- 판정자: 저장소와 GitHub 을 보지 않는 독립 에이전트 하나. 번호·제목·본문만 받았다.
- 기준: 저장소 라벨 설명 다섯 등급. 두 규칙을 더했다. 본문이 실제로 일어났다고 적은 가장 무거운 결과로 고른다. 가정만 있고 일어난 기록이 없으면 한 등급 낮춘다. 망설여지면 가벼운 쪽을 고르고 표시한다.

| 원래 라벨 | 표본 | 다시 매겨도 1·2순위 | 이유에 "일어난 기록 없음"이 든 것 | 망설임 표시 |
| --- | --- | --- | --- | --- |
| 1·2순위 | 20 | 5 | 9 | 12 |
| 3~5순위 | 20 | 1 | 3 | 6 |
| `impact` 라벨 없음 | 10 | 2 | 2 | 2 |

라벨이 있는 40개에서 다섯 등급이 정확히 같은 것은 17개다.

읽을 때 주의할 점이 있다. 다시 매긴 기준에는 "일어난 기록이 없으면 낮춘다"가 있고 원래 라벨에는 그 규칙이 없었다. 그래서 이 차이는 라벨이 틀렸다는 뜻이 아니라, 1·2순위 라벨이 "일어날 수 있는 일"까지 담고 있다는 뜻이다. 판정자가 하나이고 표본이 작아서 전체 비율로 옮기면 폭이 넓다.

## 라벨 눈가림 재판정 2차

1차는 "일어났는가"와 "얼마나 무거운가"를 한 등급에 섞어 매겼다. 2차는 둘을 따로 물었다.

- 대상: 1·2순위 라벨이 붙은 열린 이슈 106개 전부.
- 가림: 1차와 같다. 본문에서 triage 블록, "분류" 절, 라벨 줄을 지웠다.
- 판정자: 저장소와 GitHub 을 보지 않는 독립 에이전트 둘. 서로의 결과를 보지 않았다. 둘은 같은 모델이다.
- 기준: `label-audit-rubric.md`. `observed` 는 본문에 로그·횟수·시각·재현 결과가 있는지, `impact` 는 일어났을 때 가장 무거운 결과다. `impact` 는 `observed` 로 낮추지 않는다.

`audit_counts.py` 의 출력 앞부분:

```text
== label audit: issues 106 ==
judges saying it happened: 2 | top-two votes 2/1/0: [33, 1, 29]
judges saying it happened: 1 | top-two votes 2/1/0: [1, 0, 1]
judges saying it happened: 0 | top-two votes 2/1/0: [19, 2, 20]
same answer on observed: 104
same impact grade: 98
happened and top-two by both judges: 33 closed on 2026-11-11: [28612, 29552, 46398]
still open: [27944, 29578, 30673, 31364, 32504, 33057, 33841, 35309, 38068, 38700, 39677, 40586, 41087, 42017, 42636, 44787, 46120, 46505, 46602, 46691, 46722, 46747, 46863, 47679, 47789, 47799, 47993, 48031, 48996, 49549]
```

줄마다 "일어났다고 본 판정자 수"이고, 대괄호 안은 1·2순위로 본 판정자가 둘·하나·없음인 이슈 수다. 두 판정자가 모두 "일어났고 1·2순위"라고 본 것은 33개다. 그중 3개는 같은 날 닫아서 열린 것은 30개다.

두 판정자의 답이 같다는 것은 기준이 흔들리지 않는다는 뜻이다. 판정이 옳다는 뜻은 아니다. 둘은 같은 모델이고 같은 기준을 받았고, 본문에 적힌 것만 봤다. 본문에 로그를 붙이지 않은 실제 사건은 "기록 없음"으로 떨어진다.

## 본문 분류

1·2순위 라벨이 붙은 106개와 그때까지 닫은 이슈를 뺀 열린 이슈 940개를, 라벨을 가리고 본문을 읽혀 매겼다.

- 가림: 본문에서 triage 블록, "분류" 절, 라벨 줄을 지웠다. 그 밖에 남은 라벨 낱말 41곳은 `[라벨]` 로 바꿨다. 6,000자를 넘는 본문 23개는 6,000자에서 잘랐다.
- 나눔: 난수 씨앗 3333 으로 섞어 53개씩 18묶음으로 나눴다(마지막 묶음은 39개).
- 판정자: 묶음마다 독립 에이전트 하나(`claude-opus-5-5`). 자기 묶음의 기준 파일과 표본 파일만 읽었다. 에이전트 기록을 훑어 그 밖의 파일이나 GitHub 을 읽은 호출이 없는 것을 확인했다.
- 기준: `classify-rubric.md`. 일어난 기록이 있는가(`observed`), 일어났을 때 가장 무거운 결과(`impact`), 이슈가 바라는 것(`ask`), 무엇에 관한 것인가(`group`)를 매긴다.
- 재확인 1: 두 묶음 106개를 통째로 씨앗 4444 로 다시 섞어 다른 에이전트 둘에게 맡겼다. 파일에서 `recheck.set` 이 `random` 인 행이다.
- 재확인 2: 첫 판정이 1·2순위로 본 나머지 83개와, 1·2순위가 하나도 없던 묶음 하나(53개)를 씨앗 5555 로 섞어 에이전트 셋에게 맡겼다. `recheck.set` 이 `targeted` 인 행이다.

`classify_counts.py` 의 출력:

```text
== body classification: issues 940 ==
observed true: 472 false: 468
impact: {'degrades': 463, 'blinds-operator': 195, 'internal': 185, 'breaks-continuity': 68, 'breaks-collab': 29}
ask: {'fix': 501, 'decide': 182, 'build': 92, 'measure': 78, 'cleanup': 48, 'track': 39}
unsure: 579
happened / touches promise: 48
happened / lighter: 424
no record / touches promise: 49
no record / lighter: 419
== group: issues | happened | touches promise | both | fix decide measure build cleanup track ==
tui 137 78 0 0 | 73 36 7 17 0 4
tests-ci 127 104 1 0 | 81 14 13 13 3 3
swallowed-error 118 25 14 3 | 84 16 2 2 9 5
context 82 39 32 17 | 43 13 14 8 1 3
tools-sandbox 72 33 5 3 | 34 14 8 8 2 6
dashboard 59 24 0 0 | 27 14 0 14 0 4
auth-boundary 53 12 5 1 | 27 13 6 3 1 3
provider 52 28 11 6 | 27 11 5 7 0 2
growth 47 31 0 0 | 30 9 3 4 0 1
stall 45 31 5 3 | 26 7 10 0 0 2
docs-refactor 36 5 0 0 | 0 4 0 0 30 2
review-collab 28 20 14 8 | 8 9 5 6 0 0
turn-loop 28 20 6 5 | 17 6 2 1 0 2
side-feature 24 11 0 0 | 7 7 2 7 0 1
other 18 3 1 0 | 9 5 1 2 0 1
old-data 14 8 3 2 | 8 4 0 0 2 0
== happened and touches promise, by group ==
context 17 [32802, 35971, 37079, 38418, 38548, 39191, 39195, 42073, 42597, 44102, 46507, 46556, 48999, 49165, 49435, 49910, 50828]
review-collab 8 [26914, 28401, 39782, 41311, 41343, 45003, 49171, 51232]
provider 6 [40765, 40793, 42672, 47009, 47020, 49686]
turn-loop 5 [29064, 30803, 42666, 46210, 50927]
swallowed-error 3 [28072, 38402, 50804]
tools-sandbox 3 [29962, 40915, 50995]
stall 3 [36195, 51261, 51273]
old-data 2 [45126, 48087]
auth-boundary 1 [46719]
== no record and lighter: 419 ==
ask: {'fix': 206, 'decide': 67, 'build': 59, 'cleanup': 42, 'track': 25, 'measure': 20}
impact: {'degrades': 248, 'blinds-operator': 99, 'internal': 72}
== impact label the issue carried: issues | happened | touches promise | both | same grade as the label ==
degrades 469 253 64 34 315
blinds-operator 179 91 7 4 119
internal 168 74 4 1 113
none 124 54 22 9 0
== recheck of two whole batches in a new order: issues 106 ==
same observed: 103
same impact grade: 93
same side of the promise line: 102
same ask: 104
same group: 100
== every recheck, by first-pass cell: issues | second pass says happened and touches promise ==
happened / lighter 66 2
happened / touches promise 48 37
no record / lighter 79 0
no record / touches promise 49 0
happened and touches promise in both passes: 37 [26914, 28072, 29064, 29962, 30803, 32802, 35971, 36195, 38402, 38418, 39195, 40793, 41311, 41343, 42073, 42597, 42666, 42672, 44102, 45003, 45126, 46210, 46507, 46556, 46719, 47020, 48087, 48999, 49435, 49686, 49910, 50804, 50828, 50927, 50995, 51261, 51273]
first pass only: 11 [28401, 37079, 38548, 39191, 39782, 40765, 40915, 47009, 49165, 49171, 51232]
second pass only: 2 [47257, 48214]
== in both passes, by group ==
context 13 [32802, 35971, 38418, 39195, 42073, 42597, 44102, 46507, 46556, 48999, 49435, 49910, 50828]
turn-loop 5 [29064, 30803, 42666, 46210, 50927]
review-collab 4 [26914, 41311, 41343, 45003]
provider 4 [40793, 42672, 47020, 49686]
swallowed-error 3 [28072, 38402, 50804]
stall 3 [36195, 51261, 51273]
tools-sandbox 2 [29962, 50995]
old-data 2 [45126, 48087]
auth-boundary 1 [46719]
of those, closed after classification: []
impact label they carried: {'degrades': 25, 'none': 7, 'blinds-operator': 4, 'internal': 1}
```

읽을 때 주의할 점이 있다.

- 판정자는 본문만 읽었다. "일어난 기록이 없다"는 "본문에 기록이 적혀 있지 않다"이다. 로그를 붙이지 않은 실제 사건은 "기록 없음"으로 떨어진다.
- 일치율은 재확인 1에서만 읽는다. 재확인 2는 약속에 닿는 쪽을 골라 모은 표본이라 비율을 전체로 옮길 수 없다.
- 다시 매기지 않은 698개에도 두 번째 판정이 "일어났고 약속에 닿는다"로 올릴 것이 있을 수 있다. 다시 매긴 가벼운 쪽 145개 가운데 2개가 그랬다.
- `unsure` 는 579개에 붙었고 묶음마다 12~42개로 고르지 않다. 판정자마다 쓰는 정도가 달라서 집계에 쓰지 않았다.
- 2차 재판정의 판정자는 `claude-fable-5-2` 둘이고 본문 분류의 판정자는 `claude-opus-5-5` 다. 보고서 8절의 67개는 두 모델의 목록을 합친 것이다.
- `label` 은 그 이슈에 붙어 있던 `impact` 라벨이다. 판정자는 보지 못했다. `closed_after` 는 분류한 뒤에 닫은 이슈다.

## 본문 분류에서 고른 닫기 후보

보고서 10절 3번의 236개다. `close_candidates.py` 는 `body-classification.json` 에서 일어난 기록이 없고 약속에 닿지 않으며 바라는 것이 `fix` 나 `cleanup` 인 이슈를 고른다. 거기서 `must-do` 라벨이 붙은 것과 열린 PR 이 언급한 것을 뺀다.

- 열린 PR 은 2026-11-11 22:00 KST 에 받은 `xrefs.jsonl` 의 상태다. 그 뒤에 열린 PR 은 들어 있지 않다. 닫기 직전에 `fetch_xrefs.py` 를 다시 돌려 후보를 다시 만든다.
- 표본은 씨앗 7777 로 20개를 뽑았다.

```text
== no record and lighter, ask fix or cleanup: 248 ==
left out, must-do label: 3 [31826, 35295, 41925]
left out, mentioned by an open PR: 9 [50058, 50837, 50838, 51096, 51220, 51278, 51311, 51321, 51332]
candidates: 236
group: {'swallowed-error': 62, 'tui': 32, 'docs-refactor': 24, 'tools-sandbox': 19, 'auth-boundary': 17, 'context': 13, 'dashboard': 12, 'growth': 12, 'stall': 11, 'provider': 10, 'tests-ci': 7, 'other': 6, 'turn-loop': 4, 'side-feature': 3, 'old-data': 3, 'review-collab': 1}
sample of 20 with seed 7777: [27833, 33108, 35573, 37435, 38755, 42214, 43373, 45164, 46015, 46476, 46725, 47321, 47322, 47502, 47536, 47568, 49021, 50258, 50483, 50889]
candidate numbers: [26606, 26702, 26984, 27596, 27712, 27751, 27792, 27831, 27833, 30730, 30783, 31177, 31630, 32439, 32910, 33044, 33108, 33286, 34094, 34601, 34768, 35415, 35472, 35573, 35579, 35591, 35656, 35699, 35824, 36274, 36908, 36911, 36989, 36993, 37072, 37435, 37436, 38133, 38215, 38411, 38436, 38450, 38452, 38471, 38553, 38609, 38611, 38656, 38662, 38669, 38755, 38848, 39054, 39078, 39096, 39097, 39099, 39100, 39194, 39284, 39630, 39696, 40682, 40895, 41262, 41323, 41928, 42172, 42180, 42214, 42216, 42270, 42632, 42801, 42805, 42836, 42909, 42913, 42987, 42992, 43005, 43056, 43100, 43373, 44069, 44122, 44264, 44317, 44322, 44413, 44433, 44577, 44853, 44855, 44858, 44860, 44862, 45031, 45117, 45164, 45172, 45189, 45220, 45299, 45320, 45436, 45527, 46015, 46237, 46362, 46466, 46470, 46471, 46476, 46500, 46516, 46540, 46662, 46721, 46725, 46769, 46915, 47112, 47244, 47273, 47288, 47314, 47321, 47322, 47352, 47386, 47444, 47454, 47482, 47494, 47502, 47507, 47533, 47536, 47552, 47555, 47556, 47568, 47607, 47647, 47663, 47756, 47769, 47770, 47771, 47773, 47775, 47776, 47777, 47782, 47783, 47784, 47796, 47828, 47830, 47834, 47837, 47838, 47839, 47841, 47842, 47911, 47973, 48053, 48084, 48265, 48441, 48486, 48500, 48510, 48571, 48695, 48738, 48840, 48907, 49001, 49021, 49209, 49274, 49370, 49371, 49374, 49375, 49450, 49455, 49494, 49596, 49785, 49940, 49951, 49979, 50019, 50057, 50075, 50105, 50107, 50206, 50207, 50208, 50211, 50250, 50258, 50480, 50481, 50483, 50484, 50486, 50488, 50514, 50515, 50520, 50567, 50672, 50705, 50862, 50870, 50889, 50908, 50910, 50917, 51002, 51034, 51053, 51104, 51120, 51131, 51174, 51235, 51329, 51330, 51331]
```

표본 20개는 내가 본문 전체를 읽었다.

| 본문에 적힌 것 | 수 | 이슈 |
| --- | --- | --- |
| "재현하지 않았다"거나 "소스에서 따진 것"이라고 직접 적었다 | 12 | #38755, #42214, #45164, #46015, #46725, #47321, #47322, #47502, #47536, #47568, #50258, #50889 |
| 소스를 읽어 따진 조건이나 소스에서 센 수만 있다 | 8 | #27833, #33108, #35573, #37435, #43373, #46476, #49021, #50483 |

- 일어난 사건의 기록(로그, 횟수, 재현 결과)이 있는 것은 0개다. #37435 는 운영 중인 설정에서 버려지는 줄을 전부 찾았고, 모두 카탈로그와 같은 값이라 동작이 달라진 것은 없다고 적었다.
- 5개(#33108, #35573, #43373, #46725, #50483)는 PR·RFC 가 남긴 후속 일감이다. #46725 는 수정을 만들었지만 push 하지 않았다고 적혀 있다.

## 닫기 검증

- 대상은 둘이다. 이전 판정 장부의 닫기 후보 120개(`set` 이 `ledger`. 그중 100개의 검증이 끝났고 20개는 진행 중이다)와, 병합된 PR 제목에 그 번호가 적힌 열린 이슈(`pr-title`)다. 뒤쪽은 25개이고 장부 후보와 겹치는 5개를 뺀 20개를 전부 봤다.
- 판정자는 저장소와 GitHub 을 읽기만 하는 독립 에이전트(`claude-fable-5-2`)다. 20개씩 맡아 이슈 본문·댓글, 인용된 PR, `origin/main` `fe4399c0395a` 를 읽고 `CLOSE_FIXED`, `CLOSE_NOT_PLANNED`, `KEEP_OPEN` 가운데 하나를 냈다. 애매하면 `KEEP_OPEN` 이다.
- 닫기 판정은 내가 근거를 다시 읽고, 닫는 댓글을 고친 뒤 닫았다. 닫기 직전에 이슈가 열려 있는지와 스냅숏 뒤에 댓글 수가 바뀌었는지 봤다.
- `close-verification.json` 의 `action` 은 넷이다. `closed_completed`, `closed_not_planned`, `held_for_operator`(닫기 판정이지만 닫지 않았다. 이유는 `note`), `left_open`.

`audit_counts.py` 의 출력 뒷부분:

```text
== close verification: ledger 100 ==
verifier verdict: {'CLOSE_FIXED': 44, 'CLOSE_NOT_PLANNED': 18, 'KEEP_OPEN': 38}
action: {'closed_completed': 40, 'closed_not_planned': 17, 'held_for_operator': 5, 'left_open': 38}
== close verification: pr-title 20 ==
verifier verdict: {'CLOSE_FIXED': 2, 'KEEP_OPEN': 18}
action: {'closed_completed': 2, 'left_open': 18}
```

- #47357 은 검증이 끝나기 전의 중간 결과를 읽고 닫았다가 다시 열었다. 최종 판정이 `KEEP_OPEN` 이어서 표에는 `left_open` 으로 들어 있다.
- 닫은 59개 가운데 40개는 근거로 든 심볼과 파일을 `git grep` 으로 `origin/main` 에서 직접 찾아봤다. 나머지는 검증 에이전트가 적은 근거를 읽고 닫았다.

## 확인하지 않은 것

- 보고서 2절의 제목 묶음은 제목 정규식으로 셌다. 본문만 보고 알 수 있는 같은 종류는 빠졌다. 본문 분류의 묶음과는 나누는 기준이 달라서 수가 다르다.
- 라벨은 2026-11-10 08:22Z 까지 다른 세션이 붙인 것이다. 다시 매긴 것은 `impact` 축뿐이다. `kind`, `area`, `root` 라벨이 맞는지는 보지 않았다.
- 판정이 옳은지는 재지 않았다. 잰 것은 같은 기준으로 두 번 매겼을 때 답이 같은지다.
- "나중에 열려 병합된 PR 이 언급한 이슈"는 PR 번호가 이슈 번호보다 큰지로 갈랐다. 언급이 수리인지 단순 인용인지는 가르지 못한다.
- 이전 판정 장부(2026-11-05 시작)는 세션 메모에 있고 저장소에 없다. 보고서 2절의 판정별 수는 그 메모에서 셌다.
- Ask 가 0건 대기라는 것은 읽은 시각의 값이다.
