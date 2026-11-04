# Delegate 상태 조회 응답 줄이기: 재생 측정 (11-01 ~ 11-04)

`masc_keeper_delegate_status` 의 결과에서 호출한 Keeper 가 이미 아는 것을 뺐을 때 크기가 얼마나 줄어드는지, 기록 원장으로 다시 재 본 값이에요.

## 무엇을 뺐나

결과는 위임 요청 하나의 저장된 기록 전체였어요. 호출한 Keeper 는 그 요청을 직접 보냈기 때문에 아래는 다시 받을 이유가 없어요.

| 뺀 필드 | 내용 |
|---|---|
| `input` | 보낸 요청 본문(`input.message`) |
| `source` | 보낸 Keeper, 답을 돌려받을 채널, thread id |
| `admission_digest`, `execution_digest` | 해시 두 개 |
| `schema`, `sequence`, `batch_input_digest` | 저장소 내부 값 |

남긴 것은 `operation_id`, `created_at`, `state`, `started_at`, `completed_at`, `outcome_ref`, 실패 사실(`failure_kind`, `failure_detail`), 묶음 실행 id(`batch_execution_id`), 성공 뒤의 `completed_reply` 예요.

## 방법

- 원장: `~/me/.masc/tool_calls/2026-11/` 의 11-01 ~ 11-04 날짜 파일을 11-04T19:10Z 까지 읽었어요. 도구 호출 기준선(#48223)과 같은 시각이에요.
- 대상: `masc_keeper_delegate_status` 164호출.
- 이전: 호출마다 원장의 `result_bytes`, 모델이 받은 결과의 크기예요. 원장은 긴 글을 잘라서 저장하기 때문에(잘린 객체에 `"_truncated": true` 가 붙어요) 저장된 `output` 만으로 결과 크기를 재면 성공한 위임의 답 길이가 모자라게 나와요. 164호출 중 29호출이 저장된 `output` 길이와 `result_bytes` 가 달랐어요.
- 뺀 바이트: 저장된 `output` 을 compact JSON 으로 직렬화한 크기에서, 남기는 필드만 고른 크기를 뺀 값이에요. 뺀 필드는 요청 되풀이라서 답이 잘렸는지와 상관없어요.
- 이후: 이전 − 뺀 바이트.
- 필드 이름으로만 고르고 본문은 읽지 않아요.
- 재현: `replay.py` 한 줄이고, 결과는 `replay-2026-11-01_11-04.json` 에 있어요.

```bash
python3 -I docs/evidence/delegate-status-projection-2026-11/replay.py --base-path ~/me \
  --from-date 2026-11-01 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z
```

## 결과

| 상태 | 호출 | 이전 B | 이후 B | 줄어든 비율 | 호출당 평균 이전 → 이후 |
|---|---:|---:|---:|---:|---|
| Queued | 51 | 121,340 | 7,405 | 93.9% | 2,379 → 145 |
| Running | 64 | 136,256 | 14,785 | 89.1% | 2,129 → 231 |
| Succeeded | 27 | 153,148 | 133,308 | 13.0% | 5,672 → 4,937 |
| Failed | 19 | 19,635 | 6,005 | 69.4% | 1,033 → 316 |
| 상태 없음(오류 응답) | 3 | 427 | 427 | 0% | 142 → 142 |
| 합계 | 164 | 430,806 | 161,930 | 62.4% | 2,627 → 987 |

- Queued 와 Running 은 아직 끝나지 않은 위임을 확인한 호출이고, 115호출(164호출의 70%)이에요. 이 호출은 257,596 B 에서 22,190 B 로 줄어요(91.4%).
- Succeeded 는 `completed_reply`(전체 답)를 남기기 때문에 거의 줄지 않아요. 답 자체가 이 도구 결과 바이트의 대부분이에요.

## 읽을 때 주의

- "이후"는 코드를 배포하기 전에 필드를 골라 계산한 값이에요. 배포 뒤에는 같은 명령을 같은 일수로 다시 돌려서 `before_result_bytes`(이때는 새 결과의 크기)를 이 표의 "이후"와 맞춰 봐요.
- 호출 수는 이 변경으로 줄지 않아요. 위임 한 건당 상태를 몇 번 확인하는지는 이 값이 말해 주지 않아요.
- 도구 결과의 소비자는 모델이에요. `Chat_operation.to_json` 을 읽는 다른 곳(librarian 문맥, blob 정리, 시험)은 그대로 `to_json` 을 써요. 상태 조회를 부르는 시험은 `state` 와 `completed_reply` 만 읽어요.
