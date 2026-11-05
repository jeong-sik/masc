# first_event_timeout_sec 180 → 900 전후 턴 실패 집계

해석과 결론은 보고서에 있다:
[TTFT 전용 상한 폐지 · 2026-11-04](../../reports/2026-11-04-first-event-ttft-budget-collapse.html).
이 폴더에는 보고서 숫자를 낸 스크립트 둘과 그 실행 조건을 둔다.

## 바꾼 것

- 라이브 설정 `~/me/.masc/config/runtime.toml` `[turn]` 의 `first_event_timeout_sec` 를 180 에서 900.0 으로 바꿨다.
  `provider_call_deadline_sec` 900 과 같은 값이다.
- 2026-11-04 14:50:23Z 재시작(pid 27938, binary edab4133acb)부터 적용됐다.
  부팅 로그 `keeper first-event (TTFT/prefill) timeout resolved: 900.0s (source: toml)` 로 확인했다.
- 2026-11-05 00:41Z·02:17Z(0.67.0) 재시작 뒤에도 부팅 로그에 first_event 900·deadline 900 이 찍혔다.

## 입력

라이브 서버 로그 `~/me/.masc/logs/system_log_YYYY-MM-DD.jsonl` 이다. 날짜는 UTC 00:00 에 나뉜다.
로그 원본은 이 폴더에 넣지 않는다. 키퍼 대화와 호스트 경로가 들어 있어서 집계 숫자만 남긴다.

## 명령

턴 실패를 phase 별로 날짜마다 세고, 기준 시각 뒤의 실패 줄을 따로 보여 준다.

```sh
python3 -I docs/evidence/2026-11-04-first-event-ttft-budget-collapse/terminal_phases.py 2026-11-04T14:50:23Z \
  <(rg --no-filename 'turn terminal' ~/me/.masc/logs/system_log_2026-1*.jsonl)
```

요청 크기 구간별 first_token 컷 비율을 낸다. 컷마다 같은 키퍼가 6시간 안에 마지막으로 끝낸 요청의 `tokens=` 값을 크기로 쓴다.

```sh
python3 -I docs/evidence/2026-11-04-first-event-ttft-budget-collapse/size_vs_cut.py \
  <(rg --no-filename 'tokens=\d+ context_window|first_token' ~/me/.masc/logs/system_log_2026-1*.jsonl)
```

## 관측

기준 구간은 2026-10-28 ~ 2026-11-04 14:50:23Z 이다(턴 수, 2026-11-04 15:16Z 집계).

| 묶음 | 기준 8일 |
| --- | ---: |
| first_token | 45 |
| no_progress(wall_clock) | 6 |
| queue | 8 |
| stream_idle 세 갈래 합 | 18 |

적용 뒤 중간 집계(2026-11-05 02:20Z, 11.5시간)는 아래와 같다.

| 묶음 | 턴 |
| --- | ---: |
| first_token | 2 |
| no_progress(wall_clock) | 1 |
| queue | 0 |
| stream_idle 세 갈래 합 | 7 (공통 원인 6) |

stream_idle 공통 원인과 900초급 3턴의 사정은 보고서 5절에 있다.

## 다시 셀 때의 한계

- 10-28 서버 로그는 보존 기간이 지나 2026-11-05 에 이미 없다.
  10-29 ~ 11-04 는 2026-11-05 에 다시 돌려 보고서 표와 칸마다 같았다(first_token 34 = 45 − 10-28 의 11).
  기준 8일 중 10-28 몫(first_token 11, queue 6, stream_idle 2)은 다시 셀 수 없다.
- 두 스크립트는 로그 문구를 읽는다. `turn terminal`, `phase=`, `made no progress for`, `tokens=N context_window` 문구가 바뀌면 그 칸은 오류 없이 0 이 된다.
- `no_phase_timeout_text` 칸은 900초급 지표가 아니다. phase 가 없는 실패 중 메시지에 timeout 글자가 든 것을 모았다.
  Muse 침묵, agent_core 내부 오류, SSE 파싱 실패, 연결 시간 초과가 섞인다.
- 900초 상한 셋(admission, first_event, 진행 없음 watchdog)이 경합해서 같은 침묵이 first_token, wall_clock, queue 중 어느 이름으로도 찍힐 수 있다.
  그래서 세 칸을 합쳐서 본다. 어느 쪽이 얼마나 자주 이기는지는 재지 않았다.
- 크기 대리값은 컷 직전 요청의 크기가 아니라 같은 키퍼가 그전에 끝낸 요청의 크기다.
