# Tools 화면 "도구 실행 통계" 카드 스크린샷 (2026-11-05)

PR #48248 의 화면 증거예요.
배포된 서버에는 아직 `/api/v1/tool-metrics/series` 가 없어서 실서버 화면은 아니에요.

## 어떻게 찍었나

1. 실제 보존 기록 복사본(`tool-metrics.sqlite3`, 10-05 ~ 11-04, 80만 9천 행)에서 `Tool_metrics_store.read_series` 와 `Tool_metrics_series.to_json` 으로 응답 JSON 을 만들었어요.
   구간은 24시간·7일 시간별, 30일 일별이고, 각각 전체와 `tool_execute` 만 봤어요. 여섯 개예요.
   `public_names` 는 상위 도구 넷(Execute, Read, Write, Edit)만 채웠고 나머지는 빈 목록이에요. 화면에서는 도구 이름 버튼의 툴팁에만 써요.
2. `dashboard` 개발 서버(vite)에 `ToolSeriesPanel` 만 붙인 임시 페이지를 띄우고, 위 JSON 을 `/api/v1/tool-metrics/series` 응답으로 내줬어요. 패널과 스타일은 저장소 코드 그대로예요.
3. headless Chromium(Playwright 1.61.1, 시간대 Asia/Seoul)으로 열고, 구간 칩과 도구 이름 버튼을 누르는 대로 찍었어요.

패널이 보낸 요청은 네 번이고 모두 200 이었어요. 콘솔 오류와 경고는 없었어요.

- `since_hours=24&bucket=hour&utc_offset_min=540`
- `since_hours=168&bucket=hour&utc_offset_min=540`
- `since_hours=720&bucket=day&utc_offset_min=540`
- `since_hours=720&bucket=day&utc_offset_min=540&tool=tool_execute`

## 사진

| 파일 | 보여주는 것 |
|---|---|
| `series-day.png` | 24시간 · 시간별. 호출 20,545회, 실패 541회(2.6%), p50 926ms, p95 8.2s. 구간 25개 중 덜 찬 양 끝 2개를 빼고 23개를 그려요. |
| `series-week.png` | 7일 · 시간별. 호출이 없던 11개 시간은 p50·p95 그래프가 이어지지 않고 끊겨요(관측 156/167, 미관측 11). |
| `series-month-tool.png` | 30일 · 일별, `tool_execute` 만 보는 중. 표에 한 줄만 남고 위 합계도 그 도구 값이에요. |
| `series-month-tool-phone.png` | 같은 화면을 폭 420px 로 본 모습. 타일 값이 잘리지 않아요. |

## 못 본 것

- 로그인한 실서버의 Tools 페이지 전체. 엔드포인트가 배포되면 같은 카드를 실서버에서 다시 찍어야 해요.
- 그래프 가로축 글자(`2026. 11. 4. 오전 3:00:00`)는 공용 `ObservedMetricChart` 가 정해요. 이 PR 에서는 건드리지 않았어요.

## 2026-11-06: 배포된 서버의 응답으로 다시 확인

`/api/v1/tool-metrics/series` 가 12:08Z 부팅 서버(`261215cb506`)에 올라가서 위 "못 본 것"을 다시 봤어요. 임시 페이지 대신 실제 앱(`#/lab/tools`)을 Playwright 로 열어요. 로그인은 하지 않았고, 서버 응답은 `page.route` 로 내줘요.

- 시험: `pnpm --dir dashboard run test:e2e:tool-series`(`scripts/harness_dashboard_tool_series_e2e.sh`)가 vite 를 띄우고 `dashboard/e2e/tool-series.mjs` 를 돌려요. 고정 시각(2026-11-06T13:30Z)의 합성 응답을 내줘서 숫자와 그림이 매번 같아요.
- 확인하는 것: 통계 타일 6개, 그래프 3개의 선, 덜 찬 양 끝 구간을 빼고 안내 문장이 나옴(구간 25개 중 23개를 그려요), 호출이 없던 구간 하나가 호출 그래프에서는 0, 지연 그래프에서는 p50·p95 선을 둘로 가르는 끊김(`관측 22/23 · 미관측 1`, 선 4개), 표에 도구 4줄, 구간 칩이 `since_hours=168`·`720&bucket=day` 로 요청, 도구 이름 버튼이 `tool=tool_execute` 로 요청, 원본 관측값 표, 페이지 오류 없음, 폭 390px 에서 패널이 가로로 넘치지 않음.
- 변형 확인: `bucketReadings` 가 호출이 없던 구간을 null 대신 0 으로 채우게 바꾸면 이 시험이 두 곳에서 실패해요(끊김 문구와 선 개수).
- 배포된 서버의 실제 응답: 같은 시험에 `TOOL_SERIES_RECORDED_JSON` 으로 실서버의 `GET /api/v1/tool-metrics/series?since_hours=24&bucket=hour&utc_offset_min=540` 응답(호출 15,045회, 구간 25개)을 넣었어요. 스키마 해석, 요청과 응답 대조, 그래프 그리기까지 통과했어요(수정 뒤 5번 연속).

| 파일 | 보여주는 것 |
|---|---|
| `tool-series-24h.png` | 합성 응답, 24시간 · 시간별. 지연 그래프의 끊김과 덜 찬 구간 안내가 보여요. |
| `tool-series-tool-filter.png` | `tool_execute` 만 보는 중. 표에 한 줄만 남아요. |
| `tool-series-24h-paper.png` | 같은 화면을 `?theme=paper` 로 본 모습. |
| `tool-series-24h-phone.png` | 같은 화면을 폭 390px 로 본 모습. 타일이 두 줄로 쌓여요. 아래쪽은 앱의 고정 하단 바가 덮어요. |
| `tool-series-live-24h.png` | 실서버 응답, 24시간 · 시간별. 도구 이름과 숫자는 그 시각의 실제 값이에요. |

못 본 것:

- 로그인한 실서버의 Tools 페이지 전체(로그인은 사용자 몫이에요).
- 다른 요청은 일부러 막아서(프록시 대상 `127.0.0.1:9`) 페이지 위쪽에 서버 연결 오류 알림이 떠 있어요. 이 시험은 패널만 봐요.
- CI 에 넣지 않았어요. 위 명령으로 손으로 돌려요.
