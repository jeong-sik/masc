# feat 뒤 7일 안에 같은 파일을 건드린 fix

- 조건: feat 232개마다, 그 뒤 7일(시작 제외, 끝 포함) 안에 파일이 하나라도 겹치는 fix 를 셌다.
- 비교값(control)은 그 앞 7일에 같은 방법으로 센 값이다.
- 민감도(sensitivity)는 `lane_addon_runtime.ml(i)` 와 `keeper_librarian_runtime.ml(i)` 를 겹침에서 뺀 값이다.
- 2026-09-21 과 10-21 ~ 10-22 의 feat 은 W39, W43 의 fix 몰림과 창이 겹친다. feat 마다의 수는 서로 독립이 아니다.
- 만든 명령: README 의 「feat 뒤의 fix」.

feat commits 232
fixes on same files within 7d AFTER feat: mean 6.41, median 4.0, p90 19, max 48, share>=1 83% (192/232)
control: fixes on same files within 7d BEFORE feat: mean 4.35, median 2.0, p90 11, max 28, share>=1 71% (165/232)

| feat month | feats | mean fixes after (7d) | share >=1 | mean fixes before (7d, control) |
|---|---:|---:|---:|---:|
| 2026-06 | 13 | 6.46 | 100% | 5.46 |
| 2026-07 | 2 | 1.50 | 100% | 2.00 |
| 2026-08 | 9 | 3.00 | 100% | 1.22 |
| 2026-09 | 47 | 5.94 | 68% | 2.51 |
| 2026-10 | 118 | 7.82 | 85% | 5.49 |
| 2026-11 | 43 | 3.98 | 84% | 3.67 |

sensitivity, hub files lane_addon_runtime.ml(i) and keeper_librarian_runtime.ml(i) excluded from the overlap: mean 2.34, median 1.0, p90 6, max 32, share>=1 57% (132/232)

Top 12 feats by fixes-after (7d):
| date | feat | files | fixes after 7d | example fixes |
|---|---|---:|---:|---|
| 2026-09-21 | feat(librarian): read official-client turns from their history fragments (#37527) | 13 | 48 | fix(librarian): keep memory range pending on absorb judgment failure (; fix(librarian): keep owner and failure wording at one boundary (#39302 |
| 2026-09-21 | feat(librarian): 묶은 claim 이 전하지 못하는 원문은 흡수하지 않는다 (Jev 관문) (#37369) | 3 | 35 | fix(librarian): keep owner and failure wording at one boundary (#39302; fix(librarian): 연속성 회차가 저장한 기억은 durable 회차가 다시 보내지 않아요 (#39179) |
| 2026-09-21 | feat(librarian): review received-work context before publishing it (#37512) | 3 | 31 | fix(librarian): keep memory range pending on absorb judgment failure (; fix(librarian): keep owner and failure wording at one boundary (#39302 |
| 2026-10-21 | feat(lane-addon): 권한 있는 저장소의 커밋과 파일을 읽어 줘요 (#44241) | 9 | 31 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 읽기는 커밋된 순번에서 멈춰요 (#46434) |
| 2026-09-21 | feat(memory-health): expose Librarian backlog from the existing Memory lane (#37557) | 7 | 29 | fix(librarian): keep memory range pending on absorb judgment failure (; fix(librarian): 연속성 회차가 저장한 기억은 durable 회차가 다시 보내지 않아요 (#39179) |
| 2026-10-22 | feat(addons): integrate Candle appraisal and download retirement (#44702) | 6 | 28 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 읽기는 커밋된 순번에서 멈춰요 (#46434) |
| 2026-10-21 | feat(lane-addon): host 를 기다리는 패키지의 host 요청 주기를 돌려요 (#44216) | 3 | 27 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 쓰기가 성공했을 때만 관측을 공개해요 (#46430) |
| 2026-10-21 | feat(lane-addon): 권한 있는 Board 의 기록을 page 단위로 읽어 줘요 (#44240) | 5 | 26 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 쓰기가 성공했을 때만 관측을 공개해요 (#46430) |
| 2026-10-21 | feat(lane-addon): 운영자 선언의 binding 에서 기록 읽기 권한을 읽어요 (#44239) | 3 | 26 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 쓰기가 성공했을 때만 관측을 공개해요 (#46430) |
| 2026-10-21 | feat(lane-addon): 기록 읽기가 시각부터 시작할 수 있어요 (#44537 아래층) (#44540) | 5 | 26 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 쓰기가 성공했을 때만 관측을 공개해요 (#46430) |
| 2026-10-21 | feat(lane-addon): github_pulls 기록 권한으로 merge 된 PR 과 리뷰를 읽어요 (퀴즈 RFC L10) (#44588) | 4 | 26 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 쓰기가 성공했을 때만 관측을 공개해요 (#46430) |
| 2026-10-21 | feat(lane-addon): 패키지가 host 요청으로 운영자에게 물어요 (퀴즈 RFC L4c-1) (#44280) | 8 | 25 | fix(lane-addon): 인스턴스 하나만 필요할 때 binding 파일 하나만 읽어요 (#46442); fix(lane-addon): binding 쓰기가 성공했을 때만 관측을 공개해요 (#46430) |

sensitivity control (BEFORE, hubs excluded): mean 1.41, median 0.0, p90 4, max 19, share>=1 38% (88/232)
