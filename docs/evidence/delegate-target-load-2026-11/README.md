# 위임 대상 큐 읽기: 필요한 만큼인지 재 본 기록

`masc_keeper_delegate_targets` 는 위임하기 전에 후보 Keeper의 큐와 진행 중인 턴을 읽는 도구다.
이 문서는 도구를 넣기 전 상태를 저장된 기록으로 다시 계산한 결과다. 도구를 배포한 뒤의 효과는 아직 재지 않았다.

## 결론

- 2026-11-08 00:00Z ~ 11-09 05:00Z(29시간)에 `code-reviewer` 가 리뷰어 5명에게 한 위임은 340건이다. 대기 합계는 4.278시간이다.
- 60초 이상 기다린 위임은 29건(4.114시간)이다. 그중 18건(2.449시간)은 같은 순간에 큐가 비어 있는 다른 리뷰어가 있었다.
- 그 18건의 프롬프트를 읽었다. 9건(1.295시간)은 특정 GitHub 계정의 판정을 요구해서 다른 리뷰어에게 옮길 수 없다. 6건(0.647시간)은 검토 관점만 정했고, 3건(0.507시간)은 아무것도 정하지 않았다.
- 옮길 수 있는 대기의 상한은 2.449시간이다. 계정이 고정된 건을 빼면 1.154시간이고, 아무것도 정하지 않은 건만 남기면 0.507시간이다.

## 쟀던 방법

- 입력: Keeper별 `chat-operations.sqlite3` 의 `created_at`, `started_at`, `completed_at`, `source_json.sender_keeper`. 읽기 전용이고 서버를 부르지 않는다.
- 규칙: 큐는 선입선출이고 한 번에 한 작업만 돈다. 시각 t 에 만든 작업은 t 이전에 만든 작업 중 실제로 시작한 것이 모두 끝난 뒤에 시작한다.
- 위임마다 같은 순간에 다섯 리뷰어 각각에 넣었다면 몇 초 기다렸을지 계산한다.
- 받은 리뷰어에게도 같은 계산을 해서 저장된 실제 대기와 견준다. 차이가 5초 이하면 계산이 기록과 맞는다고 본다.
- 후보 다섯은 brother, father, mother, sister, uncle 이다. `context-reviewer` 는 같은 창에서 위임을 12건만 받은 별도 리뷰어라 후보에서 뺐다. 넣으면 비어 있던 후보가 있는 긴 대기가 27건(2.948시간)으로 늘어난다.

재현:

```
python3 -I docs/evidence/delegate-target-load-2026-11/measure_delegate_target_load.py \
  --since 2026-11-08T00:00:00Z --until 2026-11-09T05:00:00Z \
  --family code-reviewer-brother,code-reviewer-father,code-reviewer-mother,code-reviewer-sister,code-reviewer-uncle \
  --long-waits --out baseline-2026-11-08_to_09.json
```

`--long-waits` 는 긴 대기마다 프롬프트 앞부분을 stderr 에 표로 낸다. 아래 이름표를 붙일 때 이 표를 읽었다. 프롬프트 본문은 JSON 에 넣지 않았다.

## 결과

| 값 | 실제 | 가장 비어 있던 리뷰어에게 보냈다면 |
|---|---:|---:|
| 위임 | 340 | 340 |
| 대기 합계(시간) | 4.278 | 0.33 |
| p50(초) | 0.0 | 0.0 |
| p90(초) | 37.1 | 0.0 |
| 최대(초) | 3763.6 | 235.7 |
| 60초 이상 | 29 | 8 |
| 600초 이상 | 5 | 0 |

- 받은 리뷰어별 위임 수: sister 77, brother 73, uncle 73, father 69, mother 48.
- 계산 검증: 받은 리뷰어에 같은 계산을 했을 때 저장된 대기와 5초 안에 맞은 위임이 340건 중 319건이다. 절대 오차 p50 0.0초, p90 0.2초다. 5초를 넘은 21건은 원인을 따로 보지 않았다.
- 오른쪽 열은 위임마다 대기가 가장 짧은 후보를 골랐을 때의 값이다. 보낸 사람이 그 순간의 큐를 안다는 가정이 들어 있다.

## 큐가 비어 있는 리뷰어가 있던 긴 대기 18건

이 작업을 한 에이전트(Claude)가 프롬프트 전체를 읽고 붙인 이름표다. 스크립트가 만든 값이 아니다.

- 계정: 특정 GitHub 계정의 판정이나, 그 리뷰어가 앞서 남긴 리뷰의 재검토를 요구한다. 다른 리뷰어에게 보내면 일이 달라진다.
- 관점: 검토 관점만 정했다. 관점을 프롬프트에 실어 다른 리뷰어에게 보낼 수는 있지만 리뷰어마다 다른 시각이 사라진다.
- 없음: 계정도 관점도 정하지 않았다.

| 시각(UTC) | 받은 리뷰어 | 대기(초) | 큐가 비어 있던 리뷰어 | 프롬프트가 정한 것 |
|---|---|---:|---|---|
| 11-08 09:33 | uncle | 78 | brother, father, sister | 없음 |
| 11-08 14:00 | uncle | 504 | brother, father, mother, sister | 관점 |
| 11-08 14:12 | uncle | 260 | father, mother, sister | 관점 |
| 11-08 15:47 | father | 871 | brother, mother, sister | 계정 |
| 11-08 21:34 | father | 99 | brother, mother | 관점 |
| 11-08 22:45 | father | 84 | brother, mother, sister | 관점 |
| 11-09 00:38 | mother | 1629 | father, uncle | 없음 |
| 11-09 02:07 | mother | 1097 | father, sister, uncle | 관점 |
| 11-09 02:27 | father | 120 | brother, sister | 없음 |
| 11-09 02:28 | mother | 145 | sister | 계정 |
| 11-09 02:42 | mother | 287 | uncle | 관점 |
| 11-09 03:11 | uncle | 133 | father, sister | 계정 |
| 11-09 03:21 | sister | 242 | brother, uncle | 계정 |
| 11-09 03:38 | father | 390 | sister, uncle | 계정 |
| 11-09 03:48 | uncle | 179 | father, sister | 계정 |
| 11-09 03:48 | mother | 2437 | father | 계정 |
| 11-09 03:52 | uncle | 167 | sister | 계정 |
| 11-09 03:53 | uncle | 97 | sister | 계정 |

| 이름표 | 건수 | 대기 합계(시간) |
|---|---:|---:|
| 계정 | 9 | 1.295 |
| 관점 | 6 | 0.647 |
| 없음 | 3 | 0.507 |

## 한계

- 상한이다. 일을 옮기면 받은 리뷰어의 다른 일이 늦어지는데, 그 간섭은 세지 않았다.
- 저장소에는 채팅 작업만 있다. 자기 틱 같은 다른 턴 때문에 리뷰어가 바빴어도 기록에 없다. 비어 있다고 계산한 리뷰어가 실제로는 바빴을 수 있다.
- 이름표는 읽은 쪽의 판단이다. 다른 사람이 읽으면 다르게 붙일 수 있다. 표에 시각과 대기를 모두 남겼으니 이름표만 바꿔 다시 합산할 수 있다.
- 보낸 사람이 큐를 알았을 때 무엇을 고를지는 모른다. 옮기는 대신 묶음을 나누거나 기다리는 쪽을 고를 수 있다.
- 도구를 쓰는 비율도 모른다. 보낸 사람이 쓸 수 있는 `masc_keeper_list` 는 Keeper 이름과 모델·컨텍스트 요약만 주고 큐는 주지 않는다.
- 60초 미만의 대기와 위임이 아닌 일반 채팅 작업은 보지 않았다.

## 배포 뒤 같은 정의로 다시 잴 때

```
python3 -I docs/evidence/delegate-target-load-2026-11/measure_delegate_target_load.py \
  --since <재시작 시각 UTC> --until <지금 UTC> \
  --family code-reviewer-brother,code-reviewer-father,code-reviewer-mother,code-reviewer-sister,code-reviewer-uncle \
  --ledger --long-waits --out after.json
```

비교할 값:

- `ledger.targets_reads` 와 `ledger.delegate_calls`: 도구를 읽은 턴 수와 위임 수. 0이면 쓰이지 않은 것이다.
- `ledger.informed` 와 `ledger.uninformed`: 같은 턴에서 후보를 읽은 뒤 한 위임과 읽지 않고 한 위임의 대기. 두 집단을 서술할 뿐 인과는 아니다.
- `long_waits`: 기준선은 29시간에 29건(4.114시간)이다. 창 길이가 다르면 시간당으로 환산해서 견준다.
- `model_check_on_actual_target.within_5s`: 기준선은 340건 중 319건이다. 크게 내려가면 계산이 기록과 어긋난 것이라 위 값을 믿지 않는다.
