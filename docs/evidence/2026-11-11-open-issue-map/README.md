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

## 명령

```sh
python3 fetch_issues.py open /tmp/open.jsonl
python3 fetch_issues.py closed /tmp/closed.jsonl
python3 fetch_xrefs.py /tmp/xrefs.jsonl
python3 measure.py /tmp/open.jsonl /tmp/closed.jsonl /tmp/xrefs.jsonl /tmp/clusters.json
python3 ask_counts.py <base-path>/.masc/keeper_ask
```

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
kind {'defect': 651, 'gap': 167, 'inquiry': 60, 'erosion': 54, 'capability': 43, 'perf': 1} none 118
impact {'degrades': 502, 'blinds-operator': 187, 'internal': 173, 'breaks-continuity': 81, 'breaks-collab': 25} none 126
area {'dashboard': 187, 'tools': 112, 'runtime': 110, 'persistence': 94, 'ci': 88, 'continuity': 72, 'verification': 64, 'transport': 63, 'turn': 63, 'observability': 56, 'connector': 32, 'goal-task': 18, 'collab': 14, 'streaming': 1, 'keeper': 1, 'board': 1, 'tui': 1} none 121
root {'ssot': 166, 'boundary': 159, 'variant': 151, 'silent': 117, 'string': 46, 'telemetry': 43, 'det': 39, 'ndt': 37} none 366
no label at all: 116
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

## 확인하지 않은 것

- 묶음은 제목 정규식으로 셌다. 본문만 보고 알 수 있는 같은 종류는 빠졌다.
- 라벨은 2026-11-10 08:22Z 까지 다른 세션이 붙인 것이다. 라벨이 맞는지는 다시 보지 않았다.
- "나중에 열려 병합된 PR 이 언급한 이슈"는 PR 번호가 이슈 번호보다 큰지로 갈랐다. 언급이 수리인지 단순 인용인지는 가르지 못한다.
- 이전 판정 장부(2026-11-05 시작)는 세션 메모에 있고 저장소에 없다. 보고서 2절의 판정별 수는 그 메모에서 셌다.
- Ask 가 0건 대기라는 것은 읽은 시각의 값이다.
