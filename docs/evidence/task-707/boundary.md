# task-707 경계 구분 — 수용 상한 vs 큐 구조·드레인

작성: lane-smith, 2026-09-16
대상: task-707 / 이슈 #29365 / PR #36848

## 한 줄

이 작업은 **수용(admission) 경로의 상한**만 둔다. 큐의 구조·소유권·드레인은 건드리지 않는다.

## 세 작업의 경계

| 작업 | 이슈 | 범위 | 이 PR 과의 경계 |
|---|---|---|---|
| task-707 (이 작업) | #29365 (open) | 수용 경로의 건수 상한(`max_events`, 기본 32, clamp [1,256]) + 최소주기 상한(`min_interval_sec`, 60) | 한 턴에 admit 하는 배치를 자르고, 상한 미만 주기 생성을 거절. 초과분은 버리지 않고 다음 턴 pending 으로 남긴다 |
| task-608 | #25875 (open, root-fix) | bounded **owned** work queue — owner-lane 소유·O(1)·명시 스키마·per-owner ownership/transaction·outbox replay | 큐 **구조와 소유권**을 바꾸는 상위 수리. 이 PR 은 그 위에 얹히는 수용 상한이며 소유권·replay 를 주장하지 않는다 |
| task-575 | #28299 (closed) | 사고 keeper 백로그 **비드레인** + immediate urgency 9h+ 기아 | **소비/드레인율과 우선순위 정렬** 문제. 이 PR 은 유입 상한만 두고 드레인율·정렬을 바꾸지 않는다 |

## 왜 부분집합이 아닌가

- #25875 는 큐를 "owner-lane 소유의 bounded typed queue"로 재설계한다. 이 PR 은 그 재설계 없이도 성립하는 **유입 상한**이다 — `ready_batch` 가 한 턴에 admit 하는 selection 수를 자르는 것은 큐 소유권과 무관하다.
- #28299 는 "회복 후에도 유입률 ≈ 소비율이라 백로그가 잔존/순증"을 관측했다. 이 PR 은 그 **유입률** 쪽을 상한으로 누르지만, **소비율**(턴당 1건 소비)과 **우선순위 정렬**(immediate 우선권)은 바꾸지 않는다. 따라서 #28299 의 드레인·기아는 이 PR 로 해소되지 않는다.

## 이 PR 이 주장하지 않는 것

- 큐 소유권·transaction·outbox replay (#25875)
- 드레인율·urgency 정렬 (#28299)
- 수용 계층의 바이트 상한 (별도 후속)

## 좌표

- 이슈 #29365: https://github.com/jeong-sik/masc/issues/29365 (state=OPEN, 2026-09-16 직독)
- 이슈 #25875: https://github.com/jeong-sik/masc/issues/25875 (state=OPEN, parent=#29365)
- 이슈 #28299: https://github.com/jeong-sik/masc/issues/28299 (state=CLOSED/completed, closed_at=2026-09-07T09:11:14Z, closed_by=anyang-keepers)
- PR #36848: https://github.com/jeong-sik/masc/pull/36848
