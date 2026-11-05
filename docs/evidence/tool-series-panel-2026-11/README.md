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
