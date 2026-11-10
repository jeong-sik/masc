# task-3504 모듈별 단일 suite dispatch 영수증 (2026-11-10)

이전 제출(vrf-748196ea8118c371790424a09badeb6d)이 "명단뿐, 실행 0건"으로 REJECT 된 뒤
실제로 5모듈을 각각 단일 suite 로 dispatch 했다. **결과는 5/5 FAIL 이며 success 는 아직 0건이다.**

- ref: `main`
- head: `111e082eba1` (dispatch 시점 main)
- 워크플로: `Test` (`.github/workflows/test.yml`), `minimal=true`
- 명령: `gh workflow run Test --ref main -f suite=<basename> -f minimal=true`

| 모듈 | run id | 결론 | 실행시간 | 실패 좌표 |
|---|---|---|---|---|
| test_browser_addon_live_ego | 42782156780 | failure | 8s | `test/test_browser_addon_live_ego.ml:652` |
| test_keeper_muse_runtime | 42782160700 | failure | 38s | `test/test_keeper_muse_runtime.ml:1791`, `:1878` (fixture `muse_host.py:97` AssertionError: `requestedCapabilities == expected_capabilities`) |
| test_keeper_memory_write | 42782164666 | failure | 0s | `test/test_keeper_memory_write.ml:1082` — `persistence 7`(recall snapshots survive GC)·`8`(superseded recall pins) |
| test_browser_task_capabilities | 42782168984 | failure | 0s | `test/test_browser_task_capabilities.ml:46`, `:84` — `FAIL no connection touches the page, so none is chosen / Expected true / Received false` |
| test_play_current_credential_authority | 42782172694 | failure | 24s | `test/test_play_current_credential_authority.ml:350`, `:370` |

## 이 영수증이 증명하는 것과 아닌 것

증명: 다섯 suite 가 main `111e082eba1` 에서 **실제로 실행됐고**, 다섯 모두 FAIL 이다. 이전 제출의
"dispatch 불가" 서술은 근거가 없었고, 실제로는 dispatch 가 된다(빌드가 아니라 suite 단위 실행).

아닌 것: success run 은 0건이므로 task-3504 의 완료 계약(모듈별 success 또는 실재 아님 증명 후
시험·fixture 수리)은 **아직 미충족**이다. 이 파일은 진척 영수증이지 완료 증거가 아니다.

## 다음 수리 순서

0초대 실패 두 건(`test_keeper_memory_write`, `test_browser_task_capabilities`)은 판정 로직·fixture
문제일 가능성이 높아 먼저 본다. 8·24·38초 실패는 프로세스·fixture 상호작용을 봐야 한다.
