# 서버 재시작 앞뒤로 도구 호출 원장 비교하기 (2026-11)

도구 호출 원장(`~/me/.masc/tool_calls`)을 서버 부팅 시각 앞뒤의 같은 길이 두 창으로 나눠 같은 값을 세요. 결과 크기, Execute 가 붙든 시간, 샌드박스별 Execute 오버헤드, 실패, 디스크 바닥 거절, 백그라운드 Execute 를 한 번에 내요(`measure_before_after.py`).

`replay_preflight_ttl.py` 는 원격 SSH 점검 결과를 다시 쓰는 시간을 바꾸면 점검이 몇 번 도는지 원장으로 다시 놓아 세요(추정). 같은 폴더의 `measure_before_after.py` 를 가져다 써서 함께 둬요.

`queue_wait_overlap.py` 는 Keeper 의 채팅 작업이 큐에서 기다린 시간 중 얼마가 같은 Keeper 의 60초 이상 Execute 안에 들어 있었는지 세요. Execute 를 비동기로 돌려서 얻을 수 있는 몫의 크기를 보는 값이에요.

`idle_repeats.py` 는 같은 Keeper 가 같은 명령을 다시 돌려 같은 결과를 받은 Execute 호출을 세고, 시간대별로 나누고, 그 Keeper 의 모델 요청·입력 토큰과 나란히 놓아요.

`pr_state_reads.py` 는 `gh` 로 PR 을 읽는 Execute 호출을 세고, 턴을 붙든 시간과 모양(반복문, 기다림, 한 번 읽기)을 UTC 날짜별로 나눠요.

`pr_read_needs.py` 는 그 PR 읽기 가운데 명령 글자에 서버 PR 스냅숏에 없는 사실이 안 보이는 호출을 세요. 스냅숏이 답할 수 있는 시간의 어림이에요.

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

## 결과 2: #50012 뒤 첫 32분 (부팅 2026-11-08T23:07:04Z, UTC)

서버가 #49959·#49942·#50012 가 모두 든 빌드 `9c7452c0e208` 로 다시 떴어요. 뒤 창은 23:08:04Z ~ 23:40:00Z(부팅 60초 뒤부터), 앞 창은 같은 길이인 22:35:08Z ~ 23:07:04Z 예요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/measure_before_after.py \
  --base-path ~/me --boot 2026-11-08T23:07:04 --end 2026-11-08T23:40:00 --settle-s 60 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-boot-2026-11-08T23-07-04Z.json
```

| 항목 | 앞 | 뒤 |
|---|---|---|
| 호출 / Execute | 338 / 111 | 520 / 228 |
| 성공한 Execute 의 도구 쪽 오버헤드 | 0.054 h (109호출, 14.9%) | 0.025 h (224호출, 8.9%) |
| 오버헤드 5초 이상 | 8호출, 0.026 h | 0호출 |
| 원격(`remote_ssh`) Execute 오버헤드 | 0.050 h (94호출), 중앙값 0.158초 | 0.021 h (199호출), 중앙값 0.024초 |
| 원격 0.5초 이상 / 호출 | 46/94 (48.9%) | 26/199 (13.1%) |
| 그중 `auto` | 45/85 | 26/184 |
| 그중 `request_effect` | 0/5 | 0/13 |
| 그중 `unknown` | 1/4 | 0/2 |
| microvm 0.5초 이상 / 호출 | 2/15 | 5/25 |
| Execute 60초 이상 | 6호출, 0.208 h | 1호출, 0.017 h |
| `remote_ssh_disk_low` 실패 / `run_in_background` 시작 | 0 / 0 | 0 / 0 |
| 실패 | 2 | 6 |

- 원격 0.5초 이상 몫이 48.9%에서 13.1%로 줄었어요. 느린 호출은 두 창 모두 `auto` 가 거의 전부이고 `request_effect` 는 0건이에요. 호출이 94건과 199건이라 표본이 작고, 95% 구간(Wilson, 「스크립트 밖에서 센 값」)은 앞 39.1~58.9%, 뒤 9.1~18.5% 로 겹치지 않아요. 더 긴 기준선도 뒤 값보다 높아요. #50012 만 빠진 바로 앞 빌드 `d4f6c089c53d` 는 8.4시간(14:41:42Z ~ 23:07:04Z)에 1,764호출 중 777건(44.0%, 41.7~46.4%)이고(`result-boot-2026-11-08T14-40-42Z.json`), 더 앞 빌드의 19.7시간은 32.8%(31.3~34.4%)예요. 두 빌드 사이에서 `keeper_sandbox_remote.ml` 을 바꾼 병합은 #50012 하나예요.
- 두 창은 활동량이 달라요(Execute 111호출에서 228호출). 호출이 몰려서 느린 몫이 낮아졌을 수 있어서, 직전 호출과의 간격이 같은 호출끼리 견줬어요(`result-preflight-replay-2026-11-08T23-08-04Z_to_23-40-00Z.json` 의 `overhead_by_gap`). 옛 캐시 수명(60초)에서는 간격이 60초 이상인 호출이 모두 0.5초 이상이었어요(#50012 이전 19.7시간에 375/375). 뒤 창은 34호출 중 13호출이에요. 간격 60~120초는 6호출이 모두 빨랐고(옛 빌드 170/170 이 느렸어요), 120~600초는 25호출 중 10호출, 600초 이상은 3/3 이에요.
- 재생 추정과 어긋나지 않아요. 300초 수명이 점검을 59.5% 줄인다는 추정에 따라 19.7시간 기준선 32.8% 에 466/1,151 을 곱하면 13.3%, 바로 앞 빌드 기준선 44.0% 에 곱하면 17.8% 이고, 관측은 13.1%(9.1~18.5%)예요. 뒤 창 원장을 옛 수명(60초)으로 다시 놓으면 점검이 60번, 300초로는 40번이에요(원격 호출 247건).
- 뒤 창 26건 중 7건은 Keeper 가 창에서 처음 부른 Execute 예요. 새 프로세스의 빈 캐시에서 시작해서 점검을 한 번씩 돌렸어요. 이 7건을 빼면 19/192(9.9%)예요.
- #49959 와 #49942 는 가리지 못해요. `disk_low` 와 `background_starts` 가 두 창 모두 0 이에요.
- 뒤 창 실패 6건은 Execute 가 아니에요(「스크립트 밖에서 센 값」).

## 결과 3: #50012 뒤 2시간 56분 (부팅 2026-11-08T23:07:04Z, UTC)

결과 2와 같은 부팅이고 창만 길어졌어요. 뒤 창은 23:08:04Z ~ 02:04:00Z 예요. 끝은 다음 부팅(11-09T02:04:59Z, 커밋 `0a7164246935`) 직전이에요. 앞 창은 같은 길이인 20:11:08Z ~ 23:07:04Z 이고, #50012 가 빠진 빌드 `d4f6c089c53d` 가 돈 구간이에요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/measure_before_after.py \
  --base-path ~/me --boot 2026-11-08T23:07:04 --end 2026-11-09T02:04:00 --settle-s 60 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-boot-2026-11-08T23-07-04Z_to_11-09T02-04-00Z.json
python3 docs/evidence/tool-efficiency-before-after-2026-11/replay_preflight_ttl.py \
  --base-path ~/me --since 2026-11-08T23:08:04 --end 2026-11-09T02:04:00 --warmup-hours 0 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-preflight-replay-2026-11-08T23-08-04Z_to_11-09T02-04-00Z.json
```

| 항목 | 앞 | 뒤 |
|---|---|---|
| 호출 / Execute | 1,717 / 628 | 3,416 / 1,753 |
| Execute 붙든 시간 | 1.883 h | 2.884 h |
| Execute 60초 이상 | 35호출, 1.024 h | 19호출, 0.747 h |
| 성공한 Execute 의 도구 쪽 오버헤드 | 0.284 h (611호출, 15.5%) | 0.172 h (1,683호출, 6.1%) |
| 오버헤드 5초 이상 | 38호출, 0.118 h | 14호출, 0.038 h |
| 원격(`remote_ssh`) Execute 오버헤드 | 0.268 h (533호출), 중앙값 0.161초 | 0.127 h (1,300호출), 중앙값 0.030초 |
| 원격 0.5초 이상 / 호출 | 264/533 (49.5%, 45.3~53.8%) | 142/1,300 (10.9%, 9.3~12.7%) |
| 그중 `auto` | 250/484 | 139/1,230 |
| 그중 `request_effect` | 2/22 | 1/30 |
| 그중 `unknown` | 12/27 | 2/40 |
| microvm 0.5초 이상 / 호출 | 11/78 (14.1%, 8.1~23.5%) | 40/383 (10.4%, 7.8~13.9%) |
| `remote_ssh_disk_low` 실패 | 0 | 0 |
| `run_in_background` 시작 | 0 | 2 (도구 이름을 알리는 문구 2) |
| 실패 | 15 | 34 |

- 원격 0.5초 이상 몫이 49.5%에서 10.9%로 줄었어요. 두 95% 구간(Wilson, 「스크립트 밖에서 센 값」)은 겹치지 않아요. 결과 2의 첫 32분(48.9%에서 13.1%)과 같은 방향이고, 호출이 533건과 1,300건으로 늘어서 구간이 좁아졌어요. #50012 가 빠진 기준선은 세 개이고(32.8%, 44.0%, 이 표의 49.5%) 모두 뒤 값보다 높아요.
- 활동량이 달라요(Execute 628호출에서 1,753호출). 직전 호출과의 간격이 같은 호출끼리 견줘도 줄었어요(`result-preflight-replay-2026-11-08T23-08-04Z_to_11-09T02-04-00Z.json` 의 `overhead_by_gap`). 옛 캐시 수명(60초)에서는 간격 60초 이상 호출이 모두 느렸어요(#50012 이전 19.7시간에 375/375). 뒤 창은 간격 60초 이상 202호출 중 89호출(44.1%, 37.4~51.0%)이 느려요. 60~120초는 10/61(16.4%, 9.2~27.6%), 120~600초는 54/116(46.6%, 37.7~55.6%), 600초 이상은 25/25 예요. 60초 미만은 45/1,088(4.1%, 3.1~5.5%)이에요.
- 재생 추정과 어긋나지 않아요. 뒤 창 원장을 읽기 수명 60초로 다시 놓으면 점검이 387번이고, 300초(#50012)로는 182번이에요(-53.0%, 원격 도구 호출 1,549건 중 읽기 1,455, 쓰기 94). 관측한 느린 원격 Execute 142건은 점검 182번보다 적어요. 재생은 원격 도구 호출 전체를 세고 관측은 성공한 Execute 만 세서 같은 집합은 아니에요.
- #49942 는 이 창에서 가려져요. `background_starts` 2건의 시작 결과가 모두 상태 읽기·취소 도구 이름을 알렸어요(`naming_both_handle_tools` 2/2). #49959 는 `disk_low` 가 두 창 모두 0 이라 여전히 못 가려요.
- 실패는 15건에서 34건이에요. `failed_by_tool` 은 상위 넷만 담아서(앞 14/15, 뒤 19/34) 나머지는 이 결과에 없어요. 11-09 하루 전체 실패는 `docs/evidence/tool-efficiency-days-2026-11/README.md` 에 있어요.
- 새 프로세스의 빈 캐시에서 시작한 첫 호출이 142건에 섞여 있어요. 뒤 창에서 Keeper 10명의 첫 원격 Execute 10건 중 8건이 느렸고, 이 10건을 빼면 134/1,290(10.4%)이에요(「스크립트 밖에서 센 값」).

## 결과 4: #50012 뒤 5.2시간 (부팅 2026-11-08T23:07:04Z, UTC)

결과 3과 같은 부팅이고 뒤 창만 04:20:00Z 까지 늘렸어요. 뒤 창은 23:08:04Z ~ 04:20:00Z, 앞 창은 같은 길이인 17:55:08Z ~ 23:07:04Z 예요(둘 다 5.2시간). 읽은 때는 2026-11-09T04:20Z 쯤이에요. 뒤 창은 다음 부팅(11-09T02:04:59Z)을 넘어요. 02:04:59Z 빌드 `0a7164246935` 와 라이브 빌드 `57b928783c0b`(11-09T02:16:44Z 커밋)는 둘 다 `git merge-base --is-ancestor` 로 #50012 를 담은 것을 확인했어요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/measure_before_after.py \
  --base-path ~/me --boot 2026-11-08T23:07:04 --end 2026-11-09T04:20:00 --settle-s 60 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-boot-2026-11-08T23-07-04Z_to_11-09T04-20-00Z.json
```

| 항목 | 앞 | 뒤 |
|---|---|---|
| 호출 / Execute | 3,280 / 1,300 | 9,003 / 5,322 |
| Execute 붙든 시간 | 3.841 h | 9.042 h |
| Execute 60초 이상 | 68호출, 1.768 h | 62호출, 2.962 h |
| 성공한 Execute 의 도구 쪽 오버헤드 | 0.557 h (1,274호출, 15.0%) | 0.485 h (5,158호출, 5.5%) |
| 오버헤드 5초 이상 | 73호출, 0.239 h | 45호출, 0.096 h |
| 원격(`remote_ssh`) Execute 오버헤드 | 0.524 h (1,004호출), 중앙값 0.164초 | 0.359 h (3,591호출), 중앙값 0.043초 |
| 원격 0.5초 이상 / 호출 | 497/1,004 (49.5%, 46.4~52.6%) | 373/3,591 (10.4%, 9.4~11.4%) |
| 그중 `auto` | 478/937 | 354/3,443 |
| 그중 `request_effect` | 2/26 | 11/52 |
| 그중 `unknown` | 17/41 | 8/96 |
| microvm 0.5초 이상 / 호출 | 32/270 (11.9%, 8.5~16.3%) | 165/1,567 (10.5%, 9.1~12.1%) |
| microvm 오버헤드 | 0.033 h (270호출) | 0.126 h (1,567호출) |
| `remote_ssh_disk_low` 실패 | 0 | 0 |
| `run_in_background` 시작 | 0 | 11 (도구 이름을 알리는 문구 11) |
| 실패 | 25 | 96 |

- 원격 0.5초 이상 몫이 49.5%에서 10.4%로 줄었어요. 두 95% 구간(Wilson)은 겹치지 않아요. 원격 호출당 오버헤드 평균은 1.88초(0.524 h ÷ 1,004)에서 0.36초(0.359 h ÷ 3,591)로, 중앙값은 0.164초에서 0.043초로 줄었어요.
- #50012 와 상관없는 microvm 도 호출당 오버헤드 평균이 0.44초(0.033 h ÷ 270)에서 0.29초(0.126 h ÷ 1,567)로 줄었어요. 0.5초 이상 몫은 11.9%에서 10.5%로 거의 같아요. 원격의 감소 중 일부는 전반적인 변화일 수 있어요. 평균 줄어든 비율은 원격 0.19배, microvm 0.66배라서 microvm 을 대조군으로 두면 원격 몫의 감소는 약 0.29배(0.19÷0.66)예요. 대조군 한 개의 평균 비율이라서 인과로 읽지 않아요.
- 활동량이 달라요(Execute 1,300호출에서 5,322호출). 결과 3의 `overhead_by_gap` 비교는 이 창으로 다시 하지 않았어요.
- 60초 이상 붙든 Execute 는 68호출 1.768 h 에서 62호출 2.962 h 로 줄지 않았어요. #50012 는 이 몫을 건드리지 않아요.
- `run_in_background` 시작 11건은 Keeper 5명이 냈고(`goo-yang-bong` 4, `ocaml-agent-ic` 4, `glossary-maniac` 1, `polisher` 1, `rondo` 1) 시작 결과 11건이 모두 상태 읽기·취소 도구 이름을 알렸어요(`naming_both_handle_tools` 11/11).
- 실패 25건에서 96건의 내역은 `failed_by_tool` 에 있어요(상위 넷만 담아요).

## 배포 뒤에 다시 재는 법

서버 부팅 시각은 `/health` 의 `build.started_at` 이에요. #49959 와 #49942 를 담은 빌드가 뜨면 그 시각을 넣어요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/measure_before_after.py \
  --base-path ~/me --boot <build.started_at, UTC, 초까지> --end <지금, UTC> \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-boot-<부팅 시각>.json
```

- #49959(읽기 호출은 디스크 바닥 검사를 건너뛴다): `after.disk_low.by_tool` 에 `Grep` 이 없고 `execute_by_intent` 에 `auto` 가 없어야 해요. `request_effect` 는 남을 수 있어요.
- #49942(시작 결과가 상태 읽기·취소 도구 이름을 알린다): `after.background_starts.naming_both_handle_tools` 가 `calls` 와 같아야 해요.
- #50012(읽기 호출은 통과한 점검 결과를 300초 동안 다시 쓴다): `after.execute_overhead_by_sandbox.remote_ssh.slow_calls` 가 호출 수에 견줘 줄어야 해요. #50012 이전 뒤 창(11-07 18:29Z ~ 11-08 14:08Z)은 3,381호출 중 1,110건(32.8%)이고, 재시작 뒤 첫 32분은 199호출 중 26건(13.1%)이에요(위 「결과 2」). 읽기·쓰기 몫은 같은 칸의 `by_intent` 에 있어요. 활동량 차이를 빼려면 같은 창으로 `replay_preflight_ttl.py --warmup-hours 0` 을 돌려 `overhead_by_gap` 을 봐요. 간격이 60초 이상인 호출이 여전히 모두 느리면 수리가 일하지 않은 거예요.
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
- 같은 턴: 되풀이의 직전 실행이 같은 턴에 있던 경우예요. 턴은 원장 줄의 `trace_id` 와 `keeper_turn_id` 한 쌍이고, `keeper_turn_id` 가 없는 줄은 어느 줄과도 같은 턴이 아니에요. `repeat_same_turn_calls` 가 전체와 Keeper별로 세요.
- 간격: 되풀이 직전 실행이 끝난 때부터 되풀이가 끝난 때까지의 초예요. 되풀이가 도는 시간이 안에 들어 있어요. Keeper의 되풀이를 작은 것부터 세워 `n // 2` 번째와 `n * 9 // 10` 번째 값을 `repeat_interval_p50_s`, `repeat_interval_p90_s` 로 내요. 위치 규칙은 `measure_before_after.py` 의 p50 과 같아요.
- 실행 수: `top_commands[].runs` 는 그 명령 머리로 돈 Execute 호출을 모두 세요. 첫 실행과 결과가 바뀐 실행도 들어 있고, `repeats` 는 되풀이만 세요.
- `hourly`: 모든 Keeper 의 Execute 호출과 되풀이를 호출이 끝난 시각의 UTC 시로 나눠요. 되풀이는 그 되풀이가 일어난 시에 세요. 호출이 없는 시는 빠져요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/idle_repeats.py \
  --base-path ~/me --since 2026-11-06T00:00:00 --end 2026-11-08T19:00:00 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-idle-repeats-2026-11-06_11-08.json
```

| 항목 | 11-06 00:00Z ~ 11-08 19:00Z | 11-08 00:00Z ~ 10:40Z | 11-08 14:41Z ~ 19:00Z (재시작 뒤) |
|---|---|---|---|
| Execute 호출 | 20,396 | 2,556 | 1,239 |
| 되풀이 호출 | 4,241 (20.8%) | 1,802 (70.5%) | 13 (1.05%) |
| 그중 직전 실행과 같은 턴 | 4,095 (96.6%) | 1,740 (96.6%) | 1 (7.7%) |
| 되풀이가 턴을 붙든 시간 | 3.36 h | 1.92 h | 0.03 h |
| 되풀이 결과 크기 합 | 5.03 MiB | 3.25 MiB | 0.01 MiB |
| 되풀이가 있는 Keeper | 13 | 5 | 5 |
| 시계 읽기(명령 전체가 `date` 한 번인 호출) | 2,537 (12.4%) | 8 (0.3%) | 0 |
| 모델 요청(`usage` 가 있는 Keeper 수) | 19,643 (21) | 2,466 (8) | 1,154 (5) |
| 입력 토큰 | 8.06 G | 776 M | 302 M |

가장 많이 되풀이한 Keeper 는 `context-reviewer` 예요.

| 창 | Execute | 되풀이 | 가장 긴 연속 | 모델 요청 | 입력 토큰(전체 Keeper 대비) | 요청당 되풀이 |
|---|---|---|---|---|---|---|
| 11-06 00:00Z ~ 11-08 19:00Z | 4,135 | 2,410 (58.3%) | 901 | 4,208 | 16.5 억 (20.5%) | 0.573 |
| 11-08 00:00Z ~ 10:40Z | 1,628 | 1,574 (96.7%) | 901 | 1,667 | 6.62 억 (85.3%) | 0.944 |

- 되풀이는 대부분 턴 하나가 열려 있는 동안 일어나요. `context-reviewer` 는 2,410호출 중 2,322호출(96.3%), 11-08 00:00Z ~ 10:40Z 의 1,574호출 중 1,519호출(96.5%)이 직전 실행과 같은 턴이에요. 재시작 뒤 창(셋째 열)에서는 13호출 중 1호출뿐이고 `context-reviewer` 3호출은 모두 다른 턴이에요.
- 11-08 00:00Z ~ 10:40Z 에 `context-reviewer` 가 가장 많이 돌린 명령은 열린 PR 12개 목록과 감시 PR 읽기예요. 1,573번 돌았고(`runs`) 그중 1,565번이 되풀이(`repeats`)예요. 이 Keeper 의 되풀이 간격은 중앙값 13.9초, p90 34.6초예요. 첫 창 전체에서는 중앙값 13.5초, p90 34.1초예요.
- 되풀이한 명령은 `context-reviewer` 가 열린 PR 목록 읽기(`gh api "repos/jeong-sik/masc/pulls?state=open&sort=updated&direction=desc..."` 두 가지, 1,935회와 411회), `sangsu` 가 같은 `grep`(676회)과 Actions run 읽기(194회), `kidsnote-incoming-dd-manager` 가 시계 읽기(`date -u +%Y-%m-%dT%H:%MZ`, 552회)예요. 위 표 첫 창의 `top_keepers[].top_commands` 에 Keeper별 세 가지씩 들어 있어요.
- 시계 읽기는 `wkbl-front` 1,293회(그 Keeper Execute 1,419호출의 91.1%), `kidsnote-incoming-dd-manager` 1,059회(1,241호출의 85.3%), `wkbl-data` 171회(172호출의 99.4%)가 거의 전부예요. 하루로 나누면 11-06 2,106회(그날 Execute 7,840호출의 26.9%), 11-07 423회(5.1%), 11-08 8회예요. `date_callers` 는 많은 순 여섯 Keeper 만 싣고, 첫 창의 합 2,533 은 `date_calls` 2,537 보다 4 작아요(나머지 Keeper 의 호출). `wkbl-front` 은 Execute 호출 대부분이 시계 읽기라서 시간을 알아내려는 호출보다 기다리는 방식으로 보이지만 이유는 못 봤어요(추정).
- 시간대는 `hourly` 에 있어요. 첫 창의 66개 시(UTC) 가운데 되풀이가 100회 이상인 시는 17개예요. 되풀이 몫은 11-06 하루 7.0%(546/7,840), 11-07 하루 22.8%(1,879/8,242), 11-08 00:00Z ~ 08:59Z 87.0%(1,785/2,051), 09:00Z ~ 13:59Z 2.6%(18/687), 14:00Z ~ 18:59Z 0.8%(13/1,576)예요. 14:00Z 시에는 재시작(14:40Z) 앞 40분이 들어 있어서, 재시작 뒤 14:41Z ~ 19:00Z 만 세면 13/1,239 = 1.05%예요(위 표 셋째 열).
- `context-reviewer` 의 되풀이는 첫 창 안에서 11-06 05:20Z 에 처음 나오고 11-08 09:13:35Z 에 멈춰요. 그 뒤 7시간 넘게 0이다가 16:39Z, 17:14Z, 17:39Z 에 3호출이 있어요. 아는 부팅 시각(11-07 18:24Z, 11-08 11:04Z, 14:40Z)과 멈춘 시각이 안 맞아요. 멈춘 이유는 가리지 못했어요.

세는 방식에서 알아 둘 점이 있어요.

- 요청 하나가 호출을 여러 개 내기도 하고 하나도 안 내기도 해서 `repeats_per_model_request` 는 몫이 아니라 비율이에요.
- 입력 토큰은 요청마다 보낸 본문 전체의 양이에요. 첫 창은 캐시 읽기가 94.8%(7,643,222,505/8,059,317,079)라서 비용으로 바꾸지 않았어요.
- 턴 기록에 `usage` 이벤트가 없는 레인은 모델 요청이 0 으로 나오고 `repeats_per_model_request` 는 `null` 이에요. 11-08 14:41Z 뒤 `context-reviewer` 의 턴 기록 12개에는 `usage` 가 든 줄이 없었고(이벤트 종류는 `model_content_activity`, `text_delta`, `native_tool_*`, `tool_call_*`), 셋째 창에서 `context-reviewer`·`pr-updater`·`code-reviewer` 의 요청이 0 이에요.
- `date -u +%Y-%m-%dT%H:%MZ` 처럼 결과가 분 단위로 같은 명령은 기다림이 아니어도 되풀이로 세요. 반대로 초 단위 시각이 결과에 들어가는 명령은 되풀이로 안 세서, 시계 읽기를 따로 세요(`execute.date_calls`, `date_callers`). 두 값은 겹칠 수 있어서 더하지 않았어요. 시계 읽기는 명령 전체가 `date` 하나(`command` 나 `argv`, 파이프·`;`·치환 없음)인 호출만 세요.
- 창을 잘라서 따로 돌리면 창 시작 30분 안의 되풀이는 첫 실행으로 세요. 시간대별 값은 창을 한 번 훑은 뒤 나눠서 이 문제가 없어요.

## PR 을 읽는 Execute (`pr_state_reads.py`)

Keeper 가 `gh pr view`·`gh pr list`·`gh pr checks`·`gh pr status`, 또는 `/pulls` 나 `pullRequest` 를 부르는 `gh api` 로 PR 을 읽는 Execute 호출을 세어요. 정의는 스크립트 머리말에 있어요. 호출 모양은 셋이에요. 반복문(`fan_out`)은 `gh` 가 만든 목록을 돌면서 하나씩 읽는 호출이고, 기다림(`wait`)은 `sleep N` 이나 `--watch` 가 든 호출이고, 나머지는 한 번 읽기(`single`)예요. 한 호출은 맞는 첫 모양에 들어가요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/pr_state_reads.py \
  --base-path ~/me --since 2026-11-06T00:00:00 --end 2026-11-09T00:00:00 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-pr-state-reads-2026-11-06_11-08.json
```

| 날짜 (UTC) | Execute | PR 읽기 | Execute 시간 중 몫 | 반복문 | 기다림 | 한 번 읽기 |
|---|---|---|---|---|---|---|
| 11-06 | 7,840호출, 23.283 h | 2,334호출, 6.885 h (Keeper 15명) | 29.6% | 280호출, 1.563 h | 48호출, 2.094 h | 2,006호출, 3.228 h |
| 11-07 | 8,242호출, 15.362 h | 4,340호출, 8.597 h (13명) | 56.0% | 838호출, 2.140 h | 99호출, 2.544 h | 3,403호출, 3.913 h |
| 11-08 | 5,617호출, 12.162 h | 3,935호출, 8.905 h (13명) | 73.2% | 1,891호출, 4.944 h | 82호출, 1.445 h | 1,962호출, 2.516 h |
| 합계 | 21,699호출, 50.807 h | 10,609호출, 24.387 h | 48.0% | 3,009호출, 8.648 h | 229호출, 6.082 h | 7,371호출, 9.657 h |

PR 읽기가 붙든 시간은 하루 6.9 ~ 8.9 h 로 비슷해요. 나머지 Execute 시간이 16.4 h 에서 3.3 h 로 줄어서 몫이 올랐어요. Keeper 별로는 3일 합계로 아래가 가장 커요.

| Keeper | PR 읽기 | 그중 반복문 |
|---|---|---|
| `code-reviewer` | 1,412호출, 4.714 h | 424호출, 3.387 h, 중앙값 13.4초 |
| `context-reviewer` | 3,779호출, 4.291 h | 2,061호출, 2.648 h, 중앙값 3.2초 |
| `github-pr-checker` | 423호출, 4.017 h | 2호출, 0.008 h |
| `pr-updater` | 789호출, 3.236 h | 260호출, 1.664 h, 중앙값 14.9초 |
| `sangsu` | 205호출, 1.629 h | 4호출, 0.006 h |
| `code-reviewer-uncle` | 888호출, 1.520 h | 36호출, 0.168 h, 중앙값 10.5초 |

- 이 시간은 Keeper 턴을 붙든 시간이에요. 서버가 PR 을 한 번 읽어 두고 Keeper 가 그 값을 읽게 되면 이만큼 준다는 뜻은 아니에요. `gh` 를 띄우는 시간과 GitHub 응답 시간이 섞여 있어요.
- 글자 맞춤이라 오차가 양쪽으로 있어요. 명령을 인용만 한 호출, PR 본문이나 댓글을 읽는 호출이 들어가요. `gh pr diff` 와 `curl`·MCP 로 GitHub 를 읽는 호출은 빠져요.
- `RFC-keeper-world-state-shows-open-work` 가 이 읽기를 서버 PR 스냅숏(RFC-0465)과 Keeper 도구(`keeper_pull_requests_list`)로 바꾸자고 적었어요. 위 표는 Keeper 가 `gh` 로 PR 을 직접 읽던 측정 창의 값이에요. 서버 스냅숏의 공용 타입·JSON 투영은 #50213 으로 main 의 `Repository_pulls` 에 옮겨졌고, Keeper 도구 `keeper_pull_requests_list` 는 #50259 에서 검토 중이에요(2026-11-09 확인).
- 그 RFC 의 M6 은 `gh pr view`·`gh pr list`·`gh pr checks` 의 하루 수예요. 위 표는 `gh pr status` 와 `/pulls` 를 부르는 `gh api` 도 세므로 M6 보다 넓어요. 같은 정의로 앞뒤를 견줄 때는 이 스크립트를 다시 돌려요.

## 스냅숏이 답할 수 있는 PR 읽기 (`pr_read_needs.py`)

위 PR 읽기 가운데 명령 글자에 서버 PR 스냅숏에 없는 사실이 안 보이는 호출을 세요. 스냅숏은 열린 PR 마다 번호, 제목, draft 여부, checks 상태, 리뷰 결정, 병합 가능 여부, head 커밋, 계정별 마지막 리뷰(계정, 판정, 커밋), 가장 새 커밋의 git 작성자를 가져요. 명령이 이 밖의 사실이나 쓰기를 가리키면 그 "필요"를 불렀다고 세요. 필요는 열한 가지고, 글자 패턴은 스크립트의 `NEEDS` 에 있어요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/pr_read_needs.py \
  --base-path ~/me --since 2026-11-06T00:00:00 --end 2026-11-09T00:00:00 \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-pr-read-needs-2026-11-06_11-08.json
```

창(UTC 11-06 00:00 ~ 11-09 00:00), Execute 21,699호출 50.807 h, PR 읽기 10,609호출 24.387 h 는 위 표의 합계와 같아요. 필요를 하나도 안 부른 호출은 683호출 3.057 h 예요. PR 읽기 시간의 12.5%, Execute 시간의 6.0% 예요. 모양별로는 반복문 201호출 2.421 h, 기다림 1호출 0.017 h, 한 번 읽기 481호출 0.619 h 이고, Keeper 별로는 `code-reviewer` 375호출 2.567 h, `context-reviewer` 87호출 0.174 h, `code-reviewer-mother` 42호출 0.074 h 순이에요.

필요마다 센 값이에요. 한 호출이 여러 필요를 불러서 둘째 열은 더할 수 없어요. 셋째 열은 그 필요 하나만 부른 호출이에요.

| 필요 | 그 필요를 부른 호출 | 그 필요만 부른 호출 |
|---|---|---|
| `times` (`updated_at`·`created_at`·`submitted_at`·`sort=updated`) | 4,118호출, 5.513 h | 2,793호출, 2.984 h |
| `check_detail` (`statusCheckRollup`·`gh pr checks`·`check-runs`) | 1,101호출, 4.643 h | 167호출, 1.455 h |
| `files_or_diff` (`/files`·`gh pr diff`·diff 헤더·`compare`) | 2,314호출, 3.849 h | 609호출, 0.803 h |
| `refs_or_author_login` (브랜치 이름, PR 작성자) | 3,320호출, 7.153 h | 357호출, 0.801 h |
| `writes` (`POST`·`PUT`·`PATCH`·`DELETE`, `-f`·`-F` 필드, `gh pr merge` 등, GraphQL mutation) | 1,495호출, 3.060 h | 671호출, 0.631 h |
| `ci_run_or_main_tip` (`actions/runs`·`gh run`·`commits/main`·`git fetch`) | 1,117호출, 5.862 h | 97호출, 0.631 h |
| `closed_or_merged` (`.merged`·`mergedAt`·`--state closed`) | 1,968호출, 6.036 h | 268호출, 0.344 h |
| `merge_state_detail` (`mergeable_state`·`mergeStateStatus`) | 944호출, 3.582 h | 51호출, 0.341 h |
| `search` | 429호출, 0.897 h | 71호출, 0.139 h |
| `body_or_comments` | 1,117호출, 1.966 h | 88호출, 0.078 h |
| `labels_or_requests` | 500호출, 2.022 h | 5호출, 0.013 h |

- 칸을 하나 더해서 줄일 수 있는 필요는 `times`, `check_detail`, `refs_or_author_login`, `merge_state_detail`, `labels_or_requests` 예요. `writes` 는 읽기 도구가 대신할 수 없어요. `ci_run_or_main_tip` 은 CI run 과 main 끝을 보는 호출이고, 시간의 60.6% 가 `sleep N` 이 든 기다림이라 일정 감시(RFC-0379 §6.6)의 몫이에요(「스크립트 밖에서 센 값」). `closed_or_merged` 는 스냅숏이 열린 PR 만 가져서 칸으로 풀리지 않아요.
- 글자 맞춤이라 오차가 양쪽으로 있어요. 명령을 인용만 한 호출은 필요를 부른 것으로 세서 값이 낮아지고, 패턴이 모르는 사실을 묻는 호출은 "필요 없음"에 들어와 값이 높아져요.
- 3.057 h 는 스냅숏이 답할 수 있는 시간의 어림이에요. Keeper 가 도구를 부르게 된다는 뜻은 아니에요. 도구를 안 부르면 줄지 않으므로, 병합과 재시작 뒤에는 원장에서 `keeper_pull_requests_list` 호출 수를 보고, 같은 명령으로 "필요 없음" 호출이 줄었는지 견줘요.
- 위 절의 PR 읽기 10,609호출 중 1,495호출 3.060 h 는 `writes` 도 불러요. 대부분 리뷰를 게시하는 호출이고, 게시 전에 head 를 한 번 읽어요. `pr_state_reads.py` 가 `/pulls` 를 부르는 `gh api` 를 읽기와 쓰기 구분 없이 세서 그래요.

## 실패한 호출과 같은 Keeper 의 재호출 (`retry_diff.py`)

도구 호출이 실패한 뒤 같은 Keeper 가 같은 도구를 다시 부르는 모양을 세요. 실패는 원장 줄의 `disposition` 이 `failed` 인 호출이에요. 실패를 (도구, 오류 머리글)로 묶어요. 오류 머리글은 출력 앞 90자에서 숫자를 `N`, 12자 이상 16진수를 `H` 로 바꾼 글자예요. 재호출은 같은 Keeper 가 같은 도구를 300초 안에 다시 부른 첫 호출이에요. 재호출 입력이 첫 입력에서 더한 키(`+`), 뺀 키(`-`), 값이 바뀐 키(`~`)를 `+x -- ~-` 꼴로 적고, 재호출이 `completed` 로 끝났는지 세요.

한 묶음의 재호출이 대부분 같은 키만 고치고 끝나면 도구 계약 함정 후보예요. Keeper 가 혼자 인자를 고쳤으니 계약을 배울 수 있었어요. 후보일 뿐이에요. 실패한 호출이 같은 계획(plan) 안에서 앞 호출의 결과를 기다리던 호출이면 재호출은 어차피 다음 라운드에 나가서 왕복이 늘지 않아요(아래 `keeper_artifact_read`). 재호출이 없거나 또 실패하는 묶음은 인자를 고쳐서 풀리는 오류가 아니에요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/retry_diff.py \
  --base-path ~/me --since 2026-11-08T07:45 --until 2026-11-09T07:45
```

창(UTC 11-08 07:45 ~ 11-09 07:45)의 도구 호출 26,915건 중 301건(1.1%)이 실패했어요. 읽을 수 없는 줄은 0이에요. 실패가 5건 이상인 묶음이에요.

| 도구: 오류 | 실패 | 재호출이 끝남 | 가장 흔한 재호출 입력 차이 (건수) |
|---|---|---|---|
| `keeper_artifact_read`: `artifact does not exist` | 25 | 21 | `sha256` 값만 바뀜 (21), 재호출 없음 (2) |
| `Execute`: `remote_ssh_disk_low`, 끝점 `apple-review-be` | 22 | 0 | 재호출 없음 (10), `command` 대신 `argv` (5) |
| `BrowserTabs`: `No compatible browser is available` | 20 | 1 | 재호출 없음 (19) |
| `Execute`: `remote_ssh_disk_low`, 끝점 `apple-review-anyang` | 17 | 1 | 재호출 없음 (10), `command` 대신 `argv` (2) |
| `Execute`: `remote_ssh_disk_low`, 끝점 `apple-review-pangyo` | 12 | 1 | 재호출 없음 (6), `command` 값 바뀜 (4) |
| `Execute`: `The execution request was not sent to the endpoint` | 12 | 0 | 재호출 없음 (11) |
| `BrowserInteract`: `effect is unknown` | 11 | 7 | `target` 대신 `selector` (2), `selector` 대신 `target` (2) |
| `Edit`: `old_string not found` | 9 | 7 | `old_string`·`new_string` 값 바뀜 (5) |
| `masc_schedule_create`: `due_at_unix, due_at_iso, due_in_sec is required` | 8 | 6 | `due_in_sec` 더함 (3) |
| `BrowserInteract`: `x must be a JavaScript-safe integer` | 7 | 7 | `x` 더함 (6), `expectedUrl`·`x` 더함 (1) |
| `BrowserTabs`: `Browser command was refused before any effect` | 5 | 1 | 재호출 없음 (3), 같은 입력 (1) |
| `Read`: `microvm_remote_read_transport_failed` | 5 | 0 | 재호출 없음 (4), `limit` 값 바뀜 (1) |

- 재호출이 대부분 끝난 묶음은 `keeper_artifact_read`, `BrowserInteract` x 누락, `masc_schedule_create` 예요. x 누락 7건은 모두 `x` 를 더해 다시 불렀어요(PR #50513 이 이 거절을 다뤄요).
- `keeper_artifact_read` 는 계약 함정이 아니었어요. 재호출이 쓴 sha 21개는 모두 같은 Keeper 의 `Execute` 가 저장한 blob 이에요. 그중 17개는 실패한 읽기와 같은 `keeper_turn_id`·`turn` 에서 `planned_index` 가 앞선 `Execute` 가 만들었어요. Keeper 가 `Execute` 와 읽기를 한 계획에 같이 내서, 아직 모르는 sha 를 지어낸 거예요. 이 읽기는 다음 라운드에 나갈 호출이라 왕복이 늘지 않고, 짧은 오류가 붙은 호출 하나만 더 들어요. 나머지 4개는 다음 라운드에서 틀린 sha 를 넣은 3건(`Execute` 3.7 ~ 12.1초 뒤)과 `Execute` 가 읽기보다 뒤에 저장된 1건이에요. 실패 30건 중 27건의 sha 는 `tool_blobs` 에 파일이 없어요. 그 27개 중 24개는 가장 가까운 저장 blob 과 맞는 앞 글자 수가 4 ~ 6자라서 무작위 64자리 16진수와 같아요(저장 blob 약 258만 개일 때 무작위 중앙값이 5자예요). 이 문단의 값은 손으로 센 값이라 스크립트에 없어요.
- `Execute` 디스크 부족 51건(끝점 셋)은 재호출 2건이 끝났고, `BrowserTabs` 브라우저 없음 20건은 1건이 끝났어요.
- 묶음이 오류 머리글 90자라서 id 길이가 다르면 같은 오류가 둘로 갈려요. `masc_board_post_get` 의 `Post not found` 는 12자 이상 16진수 id 와 8자 id 로 7건씩 두 묶음이 됐고(재호출이 끝난 것 3건과 7건), 위 표에는 넣지 않았어요.
- 재호출은 "같은 Keeper 가 부른 같은 도구의 다음 호출"이라서 목적이 다른 호출도 세요. 입력 차이는 묶음마다 상위 둘만 보여요. `completed` 는 도구가 오류 없이 끝났다는 뜻이고 원하는 결과를 얻었다는 뜻은 아니에요.
- 배포 뒤에는 같은 명령으로 `x must be a JavaScript-safe integer` 묶음이 사라졌는지 봐요.

## 부팅 직후와 그 뒤의 Execute 오버헤드 (`cold_start_split.py`)

한 창에 서버 부팅이 여러 번 들어 있으면 부팅 직후의 느린 호출이 느린 호출의 몫에 섞여요. 이 스크립트는 `measure_before_after.py` 와 같은 정의(성공한 Execute 중 출력에 `execution_time_ms` 가 남은 호출, 오버헤드는 `duration_ms` 에서 그 값을 뺀 값, 500 ms 이상이면 느림)로 호출을 부팅 구간과 샌드박스로 나누고, 부팅 후 300초 안(cold)과 그 뒤(warm)를 따로 세요. 첫 부팅 앞의 호출은 warm 이에요. 부팅 시각은 서버 `/health` 의 `build.started_at` 이에요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/cold_start_split.py \
  --base-path ~/me --since 2026-11-09T01:58:31 --end 2026-11-09T08:00:00 \
  --boot 2026-11-09T02:04:59 --boot 2026-11-09T04:57:31 --boot 2026-11-09T05:43:36 \
  --boot 2026-11-09T06:39:44 --boot 2026-11-09T07:36:21
```

창(UTC 11-09 01:58:31 ~ 08:00:00)에서 센 호출은 9,056건이에요. 샌드박스 둘(`microvm`, `remote_ssh`)을 합친 값이에요.

| | 호출 | 느림(500 ms 이상) | 오버헤드 평균 |
|---|---|---|---|
| cold | 344 | 92 (26.7%) | 1,091 ms |
| warm | 8,712 | 1,153 (13.2%) | 405 ms |

cold 는 호출의 3.8% 이고 느린 호출의 7.4% 이며 오버헤드 시간 1.083 h 의 9.6% 예요. 샌드박스별로는 `microvm` 의 cold 가 127건 중 40건(31.5%)과 평균 1,314 ms, warm 이 2,966건 중 379건(12.8%)과 334 ms 예요. `remote_ssh` 의 cold 는 217건 중 52건(24.0%)과 961 ms, warm 은 5,746건 중 774건(13.5%)과 441 ms 예요.

부팅 구간별로 샌드박스를 합친 값이에요.

| 부팅 (UTC) | cold 호출 | cold 느림 | warm 호출 | warm 느림 |
|---|---|---|---|---|
| 첫 부팅 앞 | 0 | - | 153 | 11 (7.2%) |
| 02:04:59 | 121 | 13 (10.7%) | 4,115 | 533 (13.0%) |
| 04:57:31 | 89 | 18 (20.2%) | 951 | 82 (8.6%) |
| 05:43:36 | 62 | 14 (22.6%) | 1,315 | 175 (13.3%) |
| 06:39:44 | 31 | 16 (51.6%) | 1,613 | 242 (15.0%) |
| 07:36:21 | 41 | 31 (75.6%) | 565 | 110 (19.5%) |

- cold 의 느린 몫은 부팅 순서대로 오르고, 04:57:31 이후 구간의 warm 몫도 8.6% 에서 19.5% 로 올라요. 구간마다 cold 호출이 31 ~ 121건이고 마지막 구간은 창이 24분에서 끊겨서, 원인이 부팅인지 그 시각의 호스트 부하인지는 가르지 못했어요.
- 02:04:59 구간의 `remote_ssh` cold 는 90건 중 6건(6.7%)으로 warm(13.1%)보다 낮아서 모든 구간이 같은 모양은 아니에요.
- 원격 점검 캐시(`keeper_sandbox_remote.ml` 의 `preflight_cache`)는 서버 프로세스 메모리의 `Hashtbl` 이라 부팅하면 비어요. `remote_ssh` 의 cold 에 이 캐시가 빈 비용이 들어 있을 수 있어요(「원격 점검 캐시 재생」). `microvm` 의 cold 원인은 보지 않았어요.
- 부팅 시각을 사람이 `--boot` 로 넣어요. 빠뜨린 부팅이 있으면 그 직후 호출이 warm 으로 들어가요. 기본값 300초는 정한 값이고 측정으로 고른 값이 아니에요(`--cold-s`).
- 같은 창으로 부팅 앞뒤를 견줄 때는 cold 를 빼고 warm 끼리 견줘요.

## 스크립트 밖에서 센 값

이 폴더의 스크립트가 만들지 않는 값이 있어요. 결과 JSON 의 개수로 손계산한 값과, 원장을 `measure_before_after.read_calls` 로 읽어 센 값이에요.

**sangsu 분해**(보고서 「Execute 가 붙드는 시간」 끝). 다시 만들 때는 아래 조건으로 읽어요.

- 구간: `result-boot-2026-11-07T18-24-19Z.json` 의 뒤 창 `after`(11-07 18:29:19Z ~ 11-08 14:08:00Z).
- 호출: `Execute` 중 `duration_ms` 가 60,000 이상인 29호출(2.142 h, 결과 JSON 의 `after.execute.held_60s_or_more_calls`). Keeper 별로는 `sangsu` 14호출 1.413 h, `github-pr-checker` 0.275 h, `wkbl-web-leader` 0.238 h 순이에요.
- 명령: `input` 의 `command`, 없으면 `argv` 가 `["sh", "-c", 스크립트]` 일 때 그 스크립트예요.
- `sangsu` 14호출을 명령이 시작하는 말로 나누면 `gh run watch` 5호출 0.443 h, `sleep` 8호출 0.886 h(`sleep 300`~`480` 뒤에 `gh pr view`, 그중 2호출은 `gh pr checks` 도 들어 있어요), 그 밖의 1호출 0.084 h(`git commit`)예요.

**`code-reviewer` 의 PR 훑기**(「PR 을 읽는 Execute」)

- 구간: 11-08 17:30Z ~ 11-09 00:00Z(23:07Z 재시작을 가로질러요). `code-reviewer` 의 Execute 는 190호출 1.96 h 이고, 그중 60초 이상이 67호출 1.68 h 예요. 67호출이 모두 `for n in $(gh pr list -R jeong-sik/masc --state open --limit 100 ...); do` 로 시작하는 반복문이에요.
  앞 230자가 같은 세 모양이 18호출 0.58 h(중앙값 116.3초), 23호출 0.58 h(89.1초), 26호출 0.52 h(70.4초)예요.
- 한 번 훑을 때 PR 마다 `gh pr view` 한 번과 `gh api repos/jeong-sik/masc/pulls/$n/reviews` 두 번을 불러요. 열린 PR 이 N개면 `gh` 를 1 + 3N번 불러요. 출력에 `total=` 이 있는 44호출에서 열린 PR 수는 39 ~ 67개라서 118 ~ 202번이에요.
- 서버는 열린 PR 의 draft·checks·review·mergeable 을 60초마다 GraphQL 한 번으로 읽어 둬요. `RFC-keeper-world-state-shows-open-work` §3.2 가 2026-09-27 에 열린 PR 89개 한 페이지로 잰 그 쿼리의 cost 는 2 예요.

**`times` 만 부르는 호출**(「스냅숏이 답할 수 있는 PR 읽기」)

- 구간: 위와 같아요. 호출: `pr_read_needs.needs_of(명령)` 이 `("times",)` 인 PR 읽기 2,793호출 2.984 h 예요. 모양은 `pr_state_reads` 정의로 반복문 1,998호출 2.491 h, 한 번 읽기 795호출 0.494 h 예요.
- Keeper 별로 `context-reviewer` 가 2,634호출 2.815 h(94.3%)이고, 다음은 `code-reviewer` 49호출 0.080 h 예요.
- 3자리 이상 숫자를 지우고 앞 150자가 같은 명령으로 묶으면 가장 큰 묶음은 `gh api "repos/jeong-sik/masc/pulls?state=open&sort=updated&direction=desc&per_page=12" --jq '.[]|select(.updated_at>"시각")|"번호 draft head 시각 제목"'` 모양이에요. 1,990호출 2.452 h 이고, `per_page=6` 인 같은 모양이 488호출 0.197 h 예요.
- 앞의 `per_page=12` 모양은 `context-reviewer` 가 11-07 418호출, 11-08 1,574호출이고 중앙값 3.2초, p90 5.8초예요(1,992호출, 2.453 h. 묶음 기준이 앞 150자라서 1,990호출과 2건 차이가 나요).

**`ci_run_or_main_tip` 을 부른 호출의 모양**(「스냅숏이 답할 수 있는 PR 읽기」)

- 구간: 위와 같아요. 호출: `pr_read_needs.needs_of(명령)` 에 `ci_run_or_main_tip` 이 든 PR 읽기 1,117호출 5.862 h 예요. `pr_state_reads` 의 모양으로 나누면 기다림 106호출 3.550 h(60.6%), 한 번 읽기 833호출 1.446 h, 반복문 178호출 0.867 h 예요.

**#50012 첫 측정**(「결과 2」)

- 95% 구간: Wilson 점수 구간(z = 1.96)을 개수로 계산했어요. 원격 0.5초 이상은 앞 46/94 → 39.1~58.9%, 뒤 26/199 → 9.1~18.5% 예요. `auto` 만 보면 앞 45/85 → 42.4~63.2%, 뒤 26/184 → 9.8~19.9% 이고, #50012 이전 19.7시간 1,110/3,381 → 31.3~34.4%, 바로 앞 빌드 8.4시간 777/1,764 → 41.7~46.4% 예요.
- 예측: 32.8% × 466/1,151 = 13.3%, 44.0% × 466/1,151 = 17.8% 예요. 466 과 1,151 은 `result-preflight-replay-2026-11-07_11-08.json` 의 300초와 60초 점검 횟수예요.
- 처음 부른 호출: 원격 Execute 199건 가운데 `overhead_by_gap` 의 192건을 뺀 7건이에요. 그 창에서 Keeper 가 처음 부른 캐시 호출이라 직전 호출이 없어요. `code-reviewer` 계열 여섯과 `context-reviewer` 이고, 오버헤드는 2.45~4.16초로 모두 0.5초 이상이에요.
- 뒤 창 실패 6건은 `BrowserAct` 3, `BrowserGoto` 1, `BrowserTabs` 1, `keeper_artifact_read` 1 이에요. 앞 창 2건은 모두 `BrowserTabs` 예요. 두 창 모두 Execute 실패는 0건이에요.

**#50012 2시간 56분**(「결과 3」)

- 95% 구간: Wilson 점수 구간(z = 1.96)을 개수로 계산했어요. 원격 0.5초 이상은 앞 264/533 → 45.3~53.8%, 뒤 142/1,300 → 9.3~12.7% 예요. `auto` 만 보면 앞 250/484 → 47.2~56.1%, 뒤 139/1,230 → 9.7~13.2% 이고, microvm 은 앞 11/78 → 8.1~23.5%, 뒤 40/383 → 7.8~13.9% 예요.
- 간격별 구간: 60~120초 10/61 → 9.2~27.6%, 120~600초 54/116 → 37.7~55.6%, 600초 이상 25/25 → 86.7~100%, 60초 이상 전체 89/202 → 37.4~51.0%, 60초 미만 45/1,088 → 3.1~5.5% 예요. 개수는 `overhead_by_gap` 의 `slow_calls` 와 `calls` 예요.
- 처음 부른 호출: 뒤 창의 성공한 원격 Execute 1,300건을 시각 순으로 읽어 Keeper 마다 첫 호출을 가렸어요. Keeper 10명의 첫 호출 10건 중 8건이 오버헤드 0.5초 이상이고, 나머지 1,290건 중에는 134건(10.4%)이에요. 창 시작이 부팅 60초 뒤라서, 그 60초 안에 먼저 부른 Keeper 의 호출은 첫 호출로 잡히지 않아요.

**background Execute 5건**(원장에는 시작 결과만 남고 끝난 줄이 없어서 요청 기록으로 세요)

- 대상: `~/me/.masc/keeper_msg_requests/terminal/` 에서 `request_context.execute_background` 가 있는 기록 전부예요. 5건이고 11-08T09:26Z ~ 11-09T02:16Z 에 시작했어요(읽은 때 11-09T02:34Z).
- 명령이 돈 시간: 기록의 `completed_at` 에서 `submitted_at` 을 뺀 값이에요. 시작 호출: 원장에서 같은 Keeper 의 `Execute` 줄 중 `ts` 가 `submitted_at` 에서 30초 안인 줄의 `duration_ms` 예요.
- 런타임: 시작 호출 줄의 `runtime_contract.runtime_profile` 이에요. `muse_…muse-spark-1.3` 이 4건(Muse), `claude_code_…claude-sonnet-5-5` 가 1건(Claude Code)이에요.
- 시작한 턴: 그 줄과 `keeper_turn_id` 가 같은 줄이에요. 끝난 뒤 호출 수는 그중 `ts` 가 `completed_at` 보다 늦은 줄이고, 마지막 호출은 그 줄들 중 가장 늦은 `ts` 예요. 다음 턴의 첫 호출은 같은 Keeper 가 `completed_at` 뒤에 처음 쓴 줄 중 `keeper_turn_id` 가 다른 줄이에요. 영수증은 그 턴의 첫 모델 요청에 실리므로 그 줄은 전달 시각의 상한이에요.

| Keeper | 런타임 | 명령이 돈 시간 | 시작 호출 | 끝난 뒤 시작한 턴의 호출 | 그 턴의 마지막 호출 | 다음 턴의 첫 호출 |
|---|---|---:|---:|---:|---:|---:|
| sangsu | Muse | 4.3초 | 5.6 ms | 10 | +72초 | +155초 |
| code-reviewer-father | Claude Code | 142.5초 | 42.1 ms | 12 | +356초 | +391초 |
| glossary-maniac | Muse | 197.1초 | 25.7 ms | 12 | +74초 | +130초 |
| ocaml-agent-ic | Muse | 15.8초 | 31.4 ms | 24 | +314초 | +472초 |
| polisher | Muse | 5.5초 | 17.7 ms | 104 | +1,034초 | 읽은 때까지 없음 |

- 시작 호출은 5건 모두 43 ms 이내에 결과를 돌려줬어요. 명령이 4.3초·5.5초·15.8초에 끝난 3건은 foreground 로 돌렸으면 그 시간에 결과를 받았어요. background 로는 시작한 턴이 끝난 뒤 다음 턴에서 받고, 그 턴의 첫 호출은 끝난 뒤 130~472초에 나왔어요(상한).
- 영수증은 실행 중인 턴에 닿지 않아요. `Keeper_client_tool_outbox.run_carrier_load` 는 턴의 첫 호출에서 outbox 를 읽고 그 snapshot 을 턴 끝까지 돌려줘요(`keeper_client_tool_outbox.mli` 의 주석). 위 5건은 명령이 끝난 뒤에도 시작한 턴이 10~104번 도구를 더 불렀어요. 그 턴이 결과를 보는 길은 요청 ID 로 `keeper_composition_status` 를 묻는 것이고, 5건 중 `polisher` 한 건만 끝난 뒤 94초에 물어서 봤어요(11-09T02:18:16Z, 3 ms). 11-07~09 원장에서 이 도구의 호출은 그 한 번이에요.

**한 계획 안의 Execute 를 동시에 돌렸을 때 줄어드는 시간**(한계만 잡았어요)

- 대상: 11-06T00:00Z ~ 11-09T03:00Z 원장에서 `planned_index` 가 정수인 줄이에요. `Execute` 24,382줄(55.094 h)이 모두 `execution_mode` 가 serial 이고 `batch_size` 가 1 이에요.
- 계획: 같은 Keeper·`keeper_turn_id`·`trace_id` 의 줄을 시작 시각(`ts` 에서 `duration_ms` 를 뺀 값)순으로 늘어놓고, `planned_index` 가 0 이거나 직전 줄 이하이면 새 계획으로 잘랐어요.
- 하한: 연속한 `planned_index` 의 Execute 끼리, 앞 줄이 끝난 뒤 2초 안에 시작한 묶음이 829개예요. 직렬 합 1.907 h 를 가장 긴 호출만큼으로 줄이면 1.335 h 라서 0.573 h(Execute 시간의 1.04%)예요.
- 가운데: 한 계획 안에 `gh` PR 읽기 Execute(`pr_state_reads.PR_READ`, 쓰기 표지 없음)가 둘 이상인 계획이 1,117개이고, 직렬 합에서 가장 긴 호출을 뺀 값이 2.09 h(Execute 시간의 3.8%)예요. 글자 맞춤이라 읽기만 한다는 보장은 없어요. `gh pr view`, `git log`, `cat`, `rg` 같은 읽기 프로그램을 파이프로만 이은 한 줄 명령(`cd … &&` 나 `;` 가 없는 것)으로 좁히면 130개 계획 0.07 h 예요.
- 상한: 줄이 둘 이상인 계획 5,986개 중 Execute 가 든 3,863개의 실행 시간(마지막 끝에서 처음 시작을 뺀 값)이 38.84 h 이고, 가장 긴 호출 하나만큼으로 줄이면 25.72 h 예요. 호출끼리 순서에 기대는지 원장에 없어서 이 값은 상한이에요.

## 시험

```bash
python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
```

합성 원장으로 세는 법을 확인하는 시험 208개예요. 창과 부팅 직후 제외, 크기 중앙값과 상한, `sleep` 폴링의 정의, 백그라운드 호출, 오버헤드(샌드박스별과 그 안의 의도별 포함), 디스크 바닥 거절의 의도별 구분, 회전 파일 읽기, 점검 재생의 읽기·쓰기 구분과 시작 시각, 간격별 오버헤드, 겹친 구간 합치기와 자르기, 60초 문턱(포함), 시작하지 않은 작업 제외, 읽지 못한 저장소 알림을 봐요. 되풀이 쪽은 같은 결과의 정의(`execution_time_ms` 제외, 키 순서 무시, JSON 이 아니면 글자 비교), 30분 간격(포함, 마지막 실행부터 잼), 연속 횟수와 10회 문턱, Keeper별로 따로 세기, 모델 요청 읽기(창 끝 제외, 다른 이벤트 제외), UTC 시 나누기, 시계 읽기로 세는 명령과 세지 않는 명령(`;`·파이프·치환·`argv` 변형), 같은 턴(직전 실행과 비교, 턴 번호가 없는 줄은 제외, Keeper별과 전체 합)과 원장 줄의 턴 읽기(추적 번호와 턴 번호 한 쌍, 정수가 아닌 값 제외, Execute 만), 되풀이 간격(끝에서 끝까지, 마지막 실행부터 잼)과 p50·p90 위치 규칙, 명령 머리별 실행 수(되풀이가 아닌 실행 포함, Keeper별)를 봐요. PR 읽기 쪽(37개)은 명령 글자 읽기(`command`, `argv`, `sh -c`, JSON 이 아닌 입력), PR 읽기로 세는 명령과 세지 않는 명령(`gh pr diff`, 단어 경계, 파이프), 모양 셋과 우선순위(반복문의 세 가지 목록 만들기, 목록 없는 반복문, `sleep` 에 숫자 없음), UTC 날짜 경계, 날짜별 몫과 합계, 순위와 이름순 동률, 여섯 명 제한, 반복문 중앙값, 창 거절을 봐요. 필요 쪽(25개)은 열한 가지 필요마다 명령 예시, 필요 없는 명령, 여러 필요의 표 순서, `--state open`, 이름에 필요 단어만 든 필드(`bodyHTML`), `-f` 필드가 쓰기인 경우와 GET·GraphQL 이라 아닌 경우, `mutation`, `-f` 가 아닌 플래그, 호출 모양과 Keeper 담기, 필요 없는 호출의 몫과 모양, 필요별 호출 수(부른 호출과 그것만 부른 호출), 몫의 0 나누기, 순위와 여섯 명 제한, 창 거절을 봐요. 실패 재호출 쪽(18개)은 오류 머리글(숫자와 긴 16진수를 가려 묶기, 90자 자르기, 줄바꿈 없음), 입력 차이(더한 키·뺀 키·바뀐 키, 같은 입력, 객체가 아닌 입력), 재호출 찾기(같은 Keeper 의 같은 도구, 300초 경계 포함, 다른 Keeper·도구 제외, `since` 포함·`until` 제외, 창 밖 실패와 창 밖 재호출, 도구 호출이 아닌 줄, 다시 실패한 재호출), 창 안 호출 수, 표 만들기(최소 횟수, 큰 묶음 먼저), 읽을 수 없는 줄 세기를 봐요. 부팅 구간 쪽(8개)은 부팅 후 300초 안(cold)과 그 뒤(warm)의 경계, 첫 부팅 앞 호출, 둘째 부팅 뒤 구간, 느림 문턱(500 ms 포함), 샌드박스별 따로 세기, 실패한 호출·다른 도구·`execution_time_ms` 가 없는 호출 제외, 오버헤드 합, 구간 이름을 봐요.

## 못 잰 것

- 앞뒤 차이의 원인. 창마다 활동량이 달라서 수리 효과와 활동 변화를 가르지 못해요.
- `sleep N` 폴링은 명령에 `sleep` 과 숫자가 있는 호출만 세요. `argv` 배열로 나눠 쓴 `sleep` 은 놓쳐요.
- 오버헤드는 출력에 `execution_time_ms` 가 남은 성공 호출만 세요. 출력이 잘려 이 값이 없는 호출은 빠져요.
- 모델이 본 크기가 아니라 도구가 낸 크기(`result_bytes`)예요.
- #50012 값은 32분 창 하나예요(원격 Execute 199호출). 하루 넘게 쌓인 뒤 같은 명령으로 다시 재야 해요. 쓰기 호출(`request_effect`)의 점검 몫은 5건과 13건이라 값이 없어요.
