# Play room SSE 전환 증거

대상은 PR [#48678](https://github.com/jeong-sik/masc/pull/48678), production head `dd115df84b56ad6e51b887497d0747d663dc2f2b`다. Native Stack #48679의 parent는 #48677이다.

## 적용한 동작

- 실제 message/public membership transaction 변경만 `play_room` dataset으로 알린다. idempotent Say, seen_at-only renewal, 보이지 않는 raw-row churn은 알리지 않는다.
- Observer의 exact principal/client에 presence lease를 묶고, reconnect·stale disconnect·HTTP/tool Join/Leave 경쟁을 같은 `Play_room_presence` registry와 mutex로 막는다. tool Say는 verified caller와 speaker를 유지한다.
- 활성 Play room의 성공한 2초 polling을 제거하고, 진입·실제 변경·source loss·replay gap/reconnect·pending trailing·실패 retry에만 읽는다. hidden room은 읽지 않고 Leave와 Observer scope 해제를 유지한다.
- transcript는 machine 간 공유한다. `play_machine`은 room membership에만 쓰며 Watch/Control machine을 진행하지 않는다.

## 최종 head 검증

- tool lease RED [42076439238](https://github.com/jeong-sik/masc/actions/runs/42076439238): 기존 구현에서 tool Join이 기대한 `dos` 대신 `msx`로 presence를 옮기는 것을 재현했다.
- 선택 GREEN [42080641527](https://github.com/jeong-sik/masc/actions/runs/42080641527): 같은 `dd115df84b56…`에서 `test_play_room` 15개와 `test_server_play_room_events` 11개가 성공했다. 로그는 `artifacts/play-room-sse-20261105/tool-lease-green-42080641527/ci-run-tests.log`에 있다.
- type-check [42080646716](https://github.com/jeong-sik/masc/actions/runs/42080646716): 같은 head에서 성공했다.
- macOS native proof [42083317803](https://github.com/jeong-sik/masc/actions/runs/42083317803): 같은 head의 source/config/native behavior가 성공했다. artifact receipt의 `source_sha`, `workflow_sha`, `behavior_passed`를 확인했다.
- 29-suite 전체 회귀 [42083311064](https://github.com/jeong-sik/masc/actions/runs/42083311064): 같은 head에서 29/29 suite가 성공했고 failure/timeout은 없다. Test step은 900초였다. 개별 OK는 `artifacts/play-room-sse-20261105/full-42083311064/runner/ci-run-tests.log`에서 확인했다.

## 네이티브 PTY 실측

설치하지 않은 artifact `tui-macos-arm64-dd115df84b56ad6e51b887497d0747d663dc2f2b-42083317803/masc-tui`를 사용했다.

- 로컬에서 측정한 SHA-256: `43cfa49cc7fb75a87254cd0c6a604880fc8d59528e156f4ab2bb5d826a94f65e`로 receipt와 일치한다.
- `masc-tui --build-commit`: `dd115df84b56ad6e51b887497d0747d663dc2f2b`.
- `test_tui_play_room_push.PlayRoomPushTest`: 1개 테스트, 9.100초, 성공.
- 첫 Read 완료 후 2.4초 idle 동안 open phase의 Read는 1회에서 증가하지 않았다. pending Read를 붙잡은 채 세 Play event와 machine event를 적용한 trailing은 첫 Read와 마지막 정본 Read까지 정확히 2회다.

| phase | Play Read | Leave |
| --- | ---: | ---: |
| open + 2.4초 idle | 1 | 0 |
| cross-machine changed | 1 | 0 |
| pending burst + trailing | 2 | 0 |
| source loss | 1 | 0 |
| reconnect/replay gap | 1 | 0 |
| hidden | 0 | 0 |
| leaving | 0 | 1 |

원시 요청·응답 수는 `request-counts.json`, 실행 로그는 `artifacts/play-room-sse-20261105/native-pty-42083317803.log`에 있다. Observer 연결은 4회였다.

재현 명령:

```bash
PYTHONPATH=test python3 docs/evidence/tui-sse-transition-20261105/measure_suite_requests.py \
  test_tui_play_room_push PlayRoomPushTest \
  artifacts/play-room-sse-20261105/native-42083317803/masc-tui \
  artifacts/play-room-sse-20261105/request-counts.json
```

## 독립 리뷰

`agent-10`이 base `4479aab8c17…`부터 최종 head까지 45개 파일의 complete diff를 재검토했다. 이전 tool lease P1은 해소됐고 P0–P2는 없다. source verdict는 이 exact head 기준 ready다. GitHub reviewer `be-sleepers`도 `dd115df8`을 APPROVE했다.

P3 한계는 `Play_room_presence`가 Eio 전용이라는 점이다. raw Domain에서 직접 호출하면 Eio 밖에서 실패할 수 있지만, production MCP/Keeper dispatch는 Eio switch/fiber 안에 있어 확인된 production 결함은 아니다. 자세한 판정은 `independent-review.json`에 있다.

## 남은 범위와 하지 않은 작업

- Browser backend-native event는 별도 범위이며 Browser server sampling이 남아 있다. 따라서 **전체 native push/SSE Fully 전환 완료라고 부르지 않는다.** 이 증거는 Play room 전환과 선택한 TUI 회귀에 한정한다.
- spectator의 late Play scope attachment는 불완전한 initial replay를 보상하기 위해 bounded trailing machine Read 1회를 추가한다. 최종 29-suite와 같은 native binary의 별도 PTY(12.619초)에서 초기 MSX Read가 2회에서 멈춤을 확인했다. 이후 변경 MSX Read는 1회, 비가시 DOS Read와 Watch legacy tick은 0회다. 원시 수는 `spectator-request-counts.json`에 있다.
- parent #48677은 Draft다. merge/rebase, 운영 설치, `~/me/.masc` 변경은 하지 않았다.
- native receipt의 `installed_runtime_verified=false`, `visible_ui_verified=false`를 그대로 유지한다. PTY fixture 성공을 실운영 백엔드나 사람이 본 화면의 검증으로 과장하지 않는다.
