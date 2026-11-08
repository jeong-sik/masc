# 서버 재시작 앞뒤로 도구 호출 원장 비교하기 (2026-11)

도구 호출 원장(`~/me/.masc/tool_calls`)을 서버 부팅 시각 앞뒤의 같은 길이 두 창으로 나눠 같은 값을 세요. 결과 크기, Execute 가 붙든 시간, 샌드박스별 Execute 오버헤드, 실패, 디스크 바닥 거절, 백그라운드 Execute 를 한 번에 내요(`measure_before_after.py`).

`replay_preflight_ttl.py` 는 원격 SSH 점검 결과를 다시 쓰는 시간을 바꾸면 점검이 몇 번 도는지 원장으로 다시 놓아 세요(추정). 같은 폴더의 `measure_before_after.py` 를 가져다 써서 함께 둬요.

`queue_wait_overlap.py` 는 Keeper 의 채팅 작업이 큐에서 기다린 시간 중 얼마가 같은 Keeper 의 60초 이상 Execute 안에 들어 있었는지 세요. Execute 를 비동기로 돌려서 얻을 수 있는 몫의 크기를 보는 값이에요.

`idle_repeats.py` 는 같은 Keeper 가 같은 명령을 다시 돌려 같은 결과를 받은 Execute 호출을 세고, 시간대별로 나누고, 그 Keeper 의 모델 요청·입력 토큰과 나란히 놓아요.

## 왜 재나요

도구를 고치고 배포한 뒤 "좋아졌다"고 말하려면 같은 정의로 앞뒤를 세야 해요. 정의를 쓸 때마다 바꾸면 값이 달라져도 이유를 알 수 없어요. 이 스크립트는 정의를 한 곳에 고정해요. 배포가 끝나면 부팅 시각만 넣어서 다시 돌려요.

## 결과 (부팅 2026-11-07T18:24:19Z, 끝 11-08T14:08:00Z, UTC)

앞은 11-06 22:45Z ~ 11-07 18:24Z, 뒤는 11-07 18:29Z ~ 11-08 14:08Z 로 둘 다 19.7시간이에요. 뒤 창은 부팅 5분 뒤부터예요.

| 항목 | 앞 | 뒤 |
|---|---|---|
| 호출 | 18,727 | 8,524 |
| 실패 | 170 | 116 |
| Grep 결과 100 KiB 이상 | 108/1,087, 최대 1,127,672 B | 0/147, 최대 10,552 B |
| `keeper_tools_list` 중앙값 | 282,958 B (81/81 이 100 KiB 이상) | 9,655 B (0/28) |
| BrowserTabs 중앙값 | 33,014 B (27/50 이 16 KiB 이상) | 7,901 B (0/8) |
| `masc_dashboard` 16 KiB 이상 | 36/36 | 3/6 |
| Execute 붙든 시간 | 13.30 h (7,238호출) | 7.03 h (4,186호출) |
| Execute 60초 이상 | 109호출, 6.12 h | 29호출, 2.14 h |
| `sleep N` 폴링(두 Keeper) | 71호출, 4.18 h (이 둘의 Execute 624호출) | 7호출, 0.28 h (228호출) |
| 성공한 Execute 의 도구 쪽 오버헤드 | 1.83 h (13.9%) | 1.27 h (18.5%) |
| 원격(`remote_ssh`) Execute 오버헤드 | 1.63 h (4,373호출), 0.5초 이상 1,828건 | 1.16 h (3,381호출), 0.5초 이상 1,110건 |
| microvm Execute 오버헤드 | 0.20 h (2,774호출), 0.5초 이상 219건 | 0.11 h (730호출), 0.5초 이상 107건 |
| `remote_ssh_disk_low` 실패 | 17 (Execute 17) | 53 (Execute 51, Grep 2) |
| `run_in_background` 시작 | 0 | 1 (도구 이름을 알리는 문구 0) |

- 호출 수가 54% 줄어서 비율은 같은 조건의 비교가 아니에요. 상한을 거는 수리는 최댓값으로 읽어요.
- 뒤 창의 `remote_ssh_disk_low` 53건은 `intent` 가 없는 Execute 49건, `request_effect` 2건, Grep 2건이에요.
- `sleep N` 폴링은 두 Keeper 의 Execute 호출이 같은 창에서 62% 줄어든 것(624에서 228)과 섞여 있어요. 호출당 폴링 몫은 11.4%(71/624)에서 3.1%(7/228)예요.

## 배포 뒤에 다시 재는 법

서버 부팅 시각은 `/health` 의 `build.started_at` 이에요. #49959 와 #49942 를 담은 빌드가 뜨면 그 시각을 넣어요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/measure_before_after.py \
  --base-path ~/me --boot <build.started_at, UTC, 초까지> --end <지금, UTC> \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-boot-<부팅 시각>.json
```

- #49959(읽기 호출은 디스크 바닥 검사를 건너뛴다): `after.disk_low.by_tool` 에 `Grep` 이 없고 `execute_by_intent` 에 `auto` 가 없어야 해요. `request_effect` 는 남을 수 있어요.
- #49942(시작 결과가 상태 읽기·취소 도구 이름을 알린다): `after.background_starts.naming_both_handle_tools` 가 `calls` 와 같아야 해요.
- #50012(읽기 호출은 통과한 점검 결과를 300초 동안 다시 쓴다): `after.execute_overhead_by_sandbox.remote_ssh.slow_calls` 가 호출 수에 견줘 줄어야 해요. 뒤 창(11-07 18:29Z ~ 11-08 14:08Z, #50012 이전)은 3,381호출 중 1,110건(32.8%)이에요. 아래 재생 추정은 점검 횟수가 60% 안팎으로 준다고 말해요.
- `--hours-before` 로 앞 창 길이를, `--settle-s` 로 부팅 직후를 뺀 시간을, `--sleep-keepers` 로 폴링을 셀 Keeper 를 바꿔요.

## 원격 점검 캐시 재생 (`replay_preflight_ttl.py`)

원격 SSH 점검 한 번은 SSH 연결을 단계마다 새로 열어요(정상이면 8개). `keeper_sandbox_remote.ml` 의 캐시는 점검 결과를 호출 종류별로 정해진 시간 동안 다시 써요. 같은 원장을 Keeper별로 다시 놓고, 그 시간을 바꾸면 점검이 몇 번 도는지 세요. 서버를 돌려 잰 값이 아니라 추정이에요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/replay_preflight_ttl.py \
  --base-path ~/me --since 2026-11-07T18:29:19 --end 2026-11-08T14:08:00 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-preflight-replay-2026-11-07_11-08.json
```

결과(11-07 18:29Z ~ 11-08 14:08Z): 캐시를 쓰는 원격 호출 3,752건 중 읽기 3,561건, 쓰기 191건이에요.

| 읽기 TTL (쓰기는 60초) | 점검 횟수 |
|---|---|
| 60초 (#50012 이전) | 1,151 (읽기 1,073, 쓰기 78) |
| 120초 | 760 |
| 300초 (#50012) | 466 (-59.5%) |
| 600초 | 344 |
| 1800초 | 236 |

관측 쪽은 `overhead_by_gap` 이에요. 성공한 원격 Execute 의 오버헤드를, 같은 Keeper 의 직전 호출과의 시작 간격으로 나눠요. 간격이 60초를 넘는 호출은 모두 오버헤드가 0.5초 이상이에요.

| 직전 호출과 간격 | 호출 | 오버헤드 중앙값 | 0.5초 이상 |
|---|---|---|---|
| 10초 안 | 635 | 0.015초 | 37 |
| 10~30초 | 1,910 | 0.015초 | 450 |
| 30~60초 | 461 | 1.04초 | 248 |
| 60~120초 | 170 | 2.52초 | 170 |
| 120~600초 | 119 | 2.71초 | 119 |
| 600초 넘음 | 86 | 2.53초 | 86 |

- 간격이 길수록 비싼 호출의 몫이 올라가고, 60초(현재 TTL)를 넘으면 전부 비싸요. 비용은 명령이 아니라 점검에서 와요.
- 모델의 가정이 넷이에요.
  - 호출 시작은 `ts - duration_ms` 로 잡아요(원장 줄은 호출이 끝날 때 쓰여요).
  - 모든 점검은 읽기를 통과시킨다고 봐요. 점검이 읽기를 거절하는 구간(GitHub 로그인 없음 등)은 60초를 그대로 써요.
  - 캐시 항목은 Keeper 이름 하나로 나눠요. 서버의 키는 `(identity, keeper_name, gh_config_dir, injected_env)` 네 개예요. 한 Keeper 안에서 뒤 둘이 바뀌면 서버는 항목을 따로 두니 실제 점검이 재생보다 많아요. 바뀌는지는 확인하지 않았어요.
  - 원장에 남지 않는 캐시 변화가 둘이라 재생에 없어요. GitHub 로그인 lane(`keeper_github_login_lane.ml`)은 로그인 단계마다 `invalidate_preflight` 로 항목을 지워요. Keeper를 올릴 때(`keeper_turn_up_args.ml`)는 캐시를 보지 않고 점검을 돌려요(`~force:true`). 실패한 도구 호출은 항목을 지우지 않아요.
- 재생 60초 횟수 1,151은 같은 창의 `remote_ssh` Execute 오버헤드 0.5초 이상 1,110건과 가까워요. 앞은 캐시를 쓰는 원격 도구 전체이고 뒤는 명령 시간이 남은 Execute만이라 같은 집합은 아니에요.

## 큐 대기와 긴 Execute 가 겹친 몫 (`queue_wait_overlap.py`)

Keeper 하나는 채팅 작업을 한 번에 하나만 돌려요(`chat-operations.sqlite3` 의 `operations_single_running`). 돌고 있는 동안 들어온 작업은 `created_at` 부터 `started_at` 까지 큐에서 기다려요. 이 스크립트는 그 대기 중 몇 초가 같은 Keeper 의 60초 이상 Execute(원장에서 `[ts - duration, ts]`) 안에 들어 있었는지, 그 Execute 시간 중 대기하는 작업이 있던 시간이 얼마인지 세요. Keeper 가 명령이 도는 동안 기다리는 작업을 하나 처리할 수 있었을 시간의 크기예요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py \
  --base-path ~/me --since 2026-11-05T00:00:00 --end 2026-11-08T15:30:00 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-queue-wait-overlap-2026-11-05_11-08.json
python3 docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py \
  --base-path ~/me --since 2026-11-07T18:29:19 --end 2026-11-08T15:30:00 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-queue-wait-overlap-2026-11-07_11-08.json
```

| 항목 | 11-05 00:00Z ~ 11-08 15:30Z (87.5 h) | 11-07 18:29Z ~ 11-08 15:30Z (21.0 h) |
|---|---|---|
| 60초 이상 Execute | 585호출, Keeper 20, 46.92 h | 38호출, Keeper 8, 2.55 h |
| 그 시간 중 기다리는 작업이 있던 시간 | 2.97 h (6.3%) | 0.47 h (18.4%) |
| 시작한 채팅 작업 | 981개 | 132개 |
| 큐 대기 합계(작업 수 × 시간) | 122.10 h | 2.10 h |
| 그중 같은 Keeper 의 60초 이상 Execute 안에 든 시간 | 3.53 h (2.9%) | 0.47 h (22.3%) |

- 첫 창은 11-07 18:24Z 배포 앞의 `sleep N` 폴링 시기가 섞여 있어요. 둘째 창이 지금 모습에 가까워요. 둘째 창에서 겹친 0.47 h 중 sangsu 한 Keeper 가 0.38 h(긴 Execute 19호출, 1.71 h)예요. 나머지 0.09 h 는 `code-reviewer-uncle` 이고 다른 여섯 Keeper 는 0이에요.
- 첫 창의 `code-reviewer-uncle` 은 큐 대기가 43.22 h 인데 겹친 시간은 0.26 h 예요. 이 대기가 왜 길었는지는 보지 않았어요.
- 정의는 스크립트 머리말에 있어요. 같은 Keeper 의 긴 Execute 끼리 겹치면 겹친 초를 한 번만 세요. 큐 대기는 작업 수 × 시간이라 두 작업이 같이 기다리면 두 번 세고, "기다리는 작업이 있던 시간"은 벽시계 시간이라 한 번 세요.
- 이 값은 상한도 하한도 아니에요. 세지 않은 효과가 둘이고 방향이 반대예요.
  - 더할 것: 긴 Execute 가 끝난 뒤에 들어와서, 그 때문에 밀린 큐를 같이 기다린 작업.
  - 뺄 것: 명령 뒤에 이어 가는 턴. 이 턴은 모델 시간을 다시 써요.
- `~/me/.masc/keepers/tool_usage` 는 Keeper 가 아니라 Keeper별 사용량 JSON 을 모아 둔 폴더예요. 마지막으로 바뀐 때가 9월 1일인 0바이트 `chat-operations.sqlite3` 가 있어서 두 창 모두 `unreadable_stores` 에 `tool_usage` 가 나와요. 스크립트는 읽지 못한 저장소를 숨기지 않고 이렇게 알려요.

## 같은 명령이 같은 결과로 되풀이된 호출 (`idle_repeats.py`)

Keeper 가 무언가를 기다리며 같은 명령을 계속 돌리면 한 번 돌 때마다 모델 요청이 한 번 나가요. 이 스크립트는 원장에서 새 정보가 없던 Execute 호출을 세요. 모델 요청은 턴 기록(`.masc/keeper_turn_events/<keeper>/*.jsonl`)의 `usage` 이벤트(`agent_core_stream_message_delta`)에서 읽어요. 읽기만 하고 아무것도 쓰지 않아요.

- 되풀이: 같은 Keeper 가 같은 명령(`input` 글자 전체)을 직전 실행이 끝난 뒤 30분(`--gap-s`) 안에 다시 돌려 같은 결과를 받은 호출이에요. 결과는 `execution_time_ms` 를 뺀 JSON 객체가 같은지 봐요(키 순서는 무시, JSON 객체가 아니면 글자 그대로). 창의 첫 실행은 되풀이가 아니에요.
- 연속(streak): 같은 명령이 같은 결과로 이어진 실행이에요. 12는 첫 실행 1번과 되풀이 11번이에요. 결과가 바뀌거나 간격이 30분을 넘으면 끊겨요.
- `hourly`: 모든 Keeper 의 Execute 호출과 되풀이를 호출이 끝난 시각의 UTC 시로 나눠요. 되풀이는 그 되풀이가 일어난 시에 세요. 호출이 없는 시는 빠져요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/idle_repeats.py \
  --base-path ~/me --since 2026-11-06T00:00:00 --end 2026-11-08T19:00:00 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-idle-repeats-2026-11-06_11-08.json
```

| 항목 | 11-06 00:00Z ~ 11-08 19:00Z | 11-08 00:00Z ~ 10:40Z | 11-08 14:41Z ~ 19:00Z (재시작 뒤) |
|---|---|---|---|
| Execute 호출 | 20,396 | 2,556 | 1,239 |
| 되풀이 호출 | 4,241 (20.8%) | 1,802 (70.5%) | 13 (1.1%) |
| 되풀이가 턴을 붙든 시간 | 3.36 h | 1.92 h | 0.03 h |
| 되풀이 결과 크기 합 | 5.03 MiB | 3.25 MiB | 0.01 MiB |
| 되풀이가 있는 Keeper | 13 | 5 | 5 |
| 모델 요청(`usage` 가 있는 Keeper 수) | 19,643 (21) | 2,466 (8) | 1,154 (5) |
| 입력 토큰 | 8.06 G | 776 M | 302 M |

가장 많이 되풀이한 Keeper 는 `context-reviewer` 예요.

| 창 | Execute | 되풀이 | 가장 긴 연속 | 모델 요청 | 입력 토큰(전체 Keeper 대비) | 요청당 되풀이 |
|---|---|---|---|---|---|---|
| 11-06 00:00Z ~ 11-08 19:00Z | 4,135 | 2,410 (58.3%) | 901 | 4,208 | 16.5 억 (20.5%) | 0.573 |
| 11-08 00:00Z ~ 10:40Z | 1,628 | 1,574 (96.7%) | 901 | 1,667 | 6.62 억 (85.3%) | 0.944 |

- 되풀이한 명령은 `context-reviewer` 가 열린 PR 목록 읽기(`gh api "repos/jeong-sik/masc/pulls?state=open&sort=updated&direction=desc..."` 두 가지, 1,935회와 411회), `sangsu` 가 같은 `grep`(676회)과 Actions run 읽기(194회), `kidsnote-incoming-dd-manager` 가 시계 읽기(`date -u +%Y-%m-%dT%H:%MZ`, 552회)예요. 위 표 첫 창의 `top_keepers[].top_commands` 에 Keeper별 세 가지씩 들어 있어요.
- 시간대는 `hourly` 에 있어요. 첫 창의 66개 시(UTC) 가운데 되풀이가 100회 이상인 시는 17개예요. 되풀이 몫은 11-06 하루 7.0%(546/7,840), 11-07 하루 22.8%(1,879/8,242), 11-08 00:00Z ~ 08:59Z 87.0%(1,785/2,051), 09:00Z ~ 13:59Z 2.6%(18/687), 14:00Z ~ 18:59Z 0.8%(13/1,576)예요.
- `context-reviewer` 의 되풀이는 첫 창 안에서 11-06 05:20Z 에 처음 나오고 11-08 09:13:35Z 에 멈춰요. 그 뒤 7시간 넘게 0이다가 16:39Z, 17:14Z, 17:39Z 에 3호출이 있어요. 아는 부팅 시각(11-07 18:24Z, 11-08 11:04Z, 14:40Z)과 멈춘 시각이 안 맞아요. 멈춘 이유는 가리지 못했어요.

세는 방식에서 알아 둘 점이 있어요.

- 요청 하나가 호출을 여러 개 내기도 하고 하나도 안 내기도 해서 `repeats_per_model_request` 는 몫이 아니라 비율이에요.
- 입력 토큰은 요청마다 보낸 본문 전체의 양이에요. 첫 창은 캐시 읽기가 94.8%(7,643,222,505/8,059,317,079)라서 비용으로 바꾸지 않았어요.
- 턴 기록에 `usage` 이벤트가 없는 레인은 모델 요청이 0 으로 나오고 `repeats_per_model_request` 는 `null` 이에요. 11-08 14:41Z 뒤 `context-reviewer` 의 턴 기록 12개에는 `usage` 가 든 줄이 없었고(이벤트 종류는 `model_content_activity`, `text_delta`, `native_tool_*`, `tool_call_*`), 셋째 창에서 `context-reviewer`·`pr-updater`·`code-reviewer` 의 요청이 0 이에요.
- `date -u +%Y-%m-%dT%H:%MZ` 처럼 결과가 분 단위로 같은 명령은 기다림이 아니어도 되풀이로 세요. 반대로 초 단위 시각이 결과에 들어가는 명령은 되풀이로 안 세요.
- 창을 잘라서 따로 돌리면 창 시작 30분 안의 되풀이는 첫 실행으로 세요. 시간대별 값은 창을 한 번 훑은 뒤 나눠서 이 문제가 없어요.

## 시험

```bash
python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
```

합성 원장으로 세는 법을 확인하는 시험 96개예요. 창과 부팅 직후 제외, 크기 중앙값과 상한, `sleep` 폴링의 정의, 백그라운드 호출, 오버헤드(샌드박스별 포함), 디스크 바닥 거절의 의도별 구분, 회전 파일 읽기, 점검 재생의 읽기·쓰기 구분과 시작 시각, 간격별 오버헤드, 겹친 구간 합치기와 자르기, 60초 문턱(포함), 시작하지 않은 작업 제외, 읽지 못한 저장소 알림을 봐요. 되풀이 쪽은 같은 결과의 정의(`execution_time_ms` 제외, 키 순서 무시, JSON 이 아니면 글자 비교), 30분 간격(포함, 마지막 실행부터 잼), 연속 횟수와 10회 문턱, Keeper별로 따로 세기, 모델 요청 읽기(창 끝 제외, 다른 이벤트 제외), UTC 시 나누기를 봐요.

## 못 잰 것

- 앞뒤 차이의 원인. 창마다 활동량이 달라서 수리 효과와 활동 변화를 가르지 못해요.
- `sleep N` 폴링은 명령에 `sleep` 과 숫자가 있는 호출만 세요. `argv` 배열로 나눠 쓴 `sleep` 은 놓쳐요.
- 오버헤드는 출력에 `execution_time_ms` 가 남은 성공 호출만 세요. 출력이 잘려 이 값이 없는 호출은 빠져요.
- 모델이 본 크기가 아니라 도구가 낸 크기(`result_bytes`)예요.
