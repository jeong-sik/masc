# `librarian` 으로 찾은 닫힌 PR

- 조건: 2026-11-17 22:10 KST 무렵의 GitHub 상태다. 제목이나 본문에 `librarian` 이 있으면 잡힌다.
- 검색 하나가 1,000개에서 잘려, 만든 날짜로 일곱 구간에 나눠 받았다.
- 달은 PR 을 만든 달이다.
- 만든 명령: README 의 「닫힌 PR」.

specified command (limit 300): 300 closed PRs returned, 10 with mergedAt null; newest-first so it covers created 2026-09-23..2026-11-17 by closedAt
full set via created: date slices (each slice < 1000): 1912 closed PRs, 163 closed without merge (8.5%), 1749 merged

| created month | closed PRs | unmerged | unmerged share |
|---|---:|---:|---:|
| 2026-03 | 3 | 1 | 33% |
| 2026-05 | 6 | 0 | 0% |
| 2026-06 | 174 | 23 | 13% |
| 2026-07 | 162 | 45 | 28% |
| 2026-08 | 136 | 17 | 12% |
| 2026-09 | 546 | 43 | 8% |
| 2026-10 | 443 | 23 | 5% |
| 2026-11 | 442 | 11 | 2% |

unmerged by title prefix: {'fix': 63, 'feat': 42, 'docs': 16, 'refactor': 12, 'test': 7, 'chore': 5, 'perf': 4, 'memory': 2, 'task': 1, 'rfc': 1}

15 newest unmerged:
- #52808 closed 2026-11-17: docs(rfc): #52618 병합 뒤 P3 다섯 건을 RFC 정본에 반영해요
- #52432 closed 2026-11-16: perf(librarian): Librarian 작업은 domain 1개짜리 자기 pool 에서 돌아요
- #52380 closed 2026-11-16: docs(rfc): 흡수 시도의 중복 저장은 다음 gate 형식 변경 때 빼고, 다시 묻기는 그대로 둬요
- #52042 closed 2026-11-15: fix(exact): 원본 실행 증명이 요청 본문을 다시 싣지 않고 ID 와 digest 로 가리켜요
- #51337 closed 2026-11-11: fix(lane-addon): a guard refusal before a CLI dispatch leaves the Exact request open
- #50859 closed 2026-11-10: test(memory): attention 표시 시험을 지운다
- #50599 closed 2026-11-09: fix(ci): dead-tool gate counts addon registry errors; pin python 3.11
- #50263 closed 2026-11-09: fix(keeper): Codex input_too_large에서는 남은 결과 묶음을 바꾸지 않아요
- #49027 closed 2026-11-06: fix(tui): the Features key hints break between hints and not inside one
- #48171 closed 2026-11-05: perf(keeper): turn 세대 바닥값은 boundary 저장소가 바뀔 때만 다시 읽어요
- #48169 closed 2026-11-05: perf(memory): Librarian 저널 결과는 늘어난 줄만 읽어서 구해요
- #46143 closed 2026-10-27: perf(keeper): reuse one gate inventory per history validation
- #45989 closed 2026-10-25: test(librarian): cover the walk-failure combination algebra
- #45669 closed 2026-10-24: fix(librarian): restore review and evaluation library boundaries
- #45539 closed 2026-10-24: chore(release): prepare v0.64.0 frozen candidate
