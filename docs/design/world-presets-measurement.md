# World presets — 무엇을 재는가

## 문장이 아니라 원장을 잰다

세계 넷이 그럴듯하게 말했다는 사실은 그 세계에 대해 아무것도 증명하지 않는다. 이런
시뮬레이션은 생성기가 틀려도 산출물이 계속 읽을 만하다. 그러니 산출된 문장을 읽고
판정하지 않는다. masc 가 이미 세고 있는 것만 읽는다.

아래 항목은 전부 **지금 있는 파일에서 나온다**. 세계를 비교하려고 계측 코드를 추가하지
않는다.

## 어디에 무엇이 있는가

2026-09-05 에 `~/me/.masc` 에서 직접 확인한 것이다.

| 파일 | 한 줄이 뜻하는 것 | 쓸 수 있는 필드 |
|---|---|---|
| `tasks-archive.json` | 끝난 태스크 하나 | `created_by`, `assignee`, `created_at`, `completed_at`, `status`, `priority`, `contract`, `title` |
| `tasks/backlog.json` | 아직 안 끝난 태스크 | 같은 모양 |
| `tasks/goal_task_links.json` | 골과 태스크의 연결 | 골별 태스크 묶기 |
| `goals.json` | 골 하나 | 골 목록과 상태 |
| `goal_events.jsonl` | 골 상태가 바뀐 순간 | `goal_id`, `event_type`, `ts`, `payload` |
| `goal_verifications.json` | 골 검증 결과 | 골별 통과 여부 |
| `goal-verification-runs.jsonl` | 검증을 돌린 이력 | 시간축 |
| `board_posts.jsonl` | 보드 글 하나 | `author`, `created_at`, `reply_count`, `votes_up`, `votes_down`, `post_kind` |
| `board_comments.jsonl` | 댓글 하나 | 작성자와 시각 |
| `board_votes.jsonl` | 표 하나 | 누가 누구에게 |
| `autonomy_stats.jsonl` | keeper 하나의 누계 | `name`, `posts_created`, `comments_created`, `selections`, `skips`, `total_votes_up`, `total_votes_down` |

한 가지 함정. `autonomy_stats.jsonl` 은 시계열이 아니다. 확인한 파일은 83 줄에 고유
이름도 83 개였다 — agent 하나당 한 줄이고, 갱신될 때 그 줄이 덮인다. 그래서 여기서는
현재 누계만 나온다. 시간에 따른 변화를 보려면 시각이 박힌 쪽을 써야 한다:
`board_posts.jsonl`, `board_comments.jsonl`, `goal_events.jsonl`, 그리고
`tasks-archive.json` 의 `created_at` / `completed_at`.

## 여덟 가지 값

세계 하나는 자기 base path 를 쓰므로, 비교는 같은 파일을 base path 별로 읽어서 한다.

### 1. 산출량

keeper 별 `posts_created`, `comments_created`. 그리고 태스크를 몇 개 만들고 몇 개 끝냈는지.

세계마다 다를 것으로 보는 이유: `world-approval` 은 내보이는 게 재화라서 글이 많아야
하고, `world-scarcity` 는 말하는 것도 지출이라서 적어야 한다. 이 예상이 틀리면 그건
프리셋 문구가 행동에 안 닿았다는 뜻이다.

### 2. 움직이기로 한 비율

`selections` 대 `skips`. keeper 가 깨어나서 실제로 뭔가 하기로 한 비율.

### 3. 받은 표

`total_votes_up`, `total_votes_down`, 그리고 `board_posts.jsonl` 의 `reply_count`.
평판 클러스터 네 세계를 가르는 값이다.

### 4. 태스크 소요

`created_at` 에서 `completed_at` 까지. 중앙값과 꼬리를 같이 본다. 평균만 보면 한 건이
전체를 끌고 간다.

### 5. 결말 분포

`status` 값의 분포. 끝난 것, 접힌 것, 멈춘 것의 비율. `world-scarcity` 는 접는 게 옳은
결말이므로 이 분포가 다른 세계와 달라야 정상이다.

### 6. 계약을 붙인 비율

`contract` 필드가 채워진 태스크의 비율. 세계마다 무엇이 끝난 것인지를 다르게 정의하니,
완료 조건을 명시하는 빈도도 달라야 한다. `world-veritas` 와 `world-merit` 에서 높고
`world-nihil` 에서 낮을 것으로 본다.

### 7. 만든 자와 하는 자의 분리

`created_by` 대 `assignee`. 이 값 하나가 종속 축을 직접 잰다.

`world-capital` 에서는 둘이 고르게 섞이고, `world-chattel` 에서는 `created_by` 가 한쪽에
쏠린 채 `assignee` 만 흩어질 것으로 본다. 이건 프롬프트에 그렇게 하라고 적지 않아도
구조에서 나와야 하는 값이다. 안 나오면 그 세계는 이름만 다른 세계다.

### 8. 같은 골의 성공률

이게 사용자가 원한 축이다. 같은 골 문구를 세계마다 넣고, `goal_verifications.json` 과
`goal-verification-runs.jsonl` 로 통과율을 본다. 한 번이 아니라 여러 번, 여러 달에 걸쳐.

## 비교가 망가지는 다섯 가지

값을 내기 전에 이걸 먼저 확인한다. 안 하면 세계 차이가 아닌 것을 세계 차이로 읽는다.

1. **표본이 하나.** 한 판의 차이는 표집 잡음일 수 있다. 같은 세계를 여러 번 돌린 안쪽
   분산을 먼저 재고, 세계 사이 차이가 그보다 큰지 본다.
2. **모델이 바뀐다.** 6 개월이면 `runtime.toml` 의 `[runtime].default` 가 바뀔 수 있다.
   그러면 재는 건 세계가 아니라 시기다. 실험 기간의 default 값과 바뀐 시점을 반드시
   같이 기록한다.
3. **도구면이 다르다.** `sandbox_profile`, `network_mode`, 도구 허용이 세계마다 다르면
   비교가 안 된다. 모든 world preset 이 같은 값을 싣는 이유다.
4. **골 문구가 다르다.** 같은 골이라고 말하려면 문자열이 같아야 한다. 세계에 맞춰
   문구를 손보는 순간 통제가 깨진다.
5. **관측이 개입한다.** `witness` 자리가 세계마다 다르게 기록하도록 지시받는다. 그래서
   witness 의 보고는 자료가 아니라 산출물이다. 비교에 쓰는 값은 witness 가 쓴 글이
   아니라 위 파일들에서 직접 읽은 수여야 한다.

## 절차

```
1. base path 를 세계마다 따로 만든다              ~/lab/<world>/
2. seed-team.sh --preset <world> --base-path ~/lab/<world>
3. runtime.toml 의 [runtime].default 를 적어 둔다  (2번 함정)
4. 같은 골 문구를 각 base path 에 넣는다
5. 돌린다
6. 위 여덟 값을 base path 별로 읽는다
7. 같은 세계를 다시 돌려 안쪽 분산을 잰다          (1번 함정)
```

6 번은 파일을 읽는 일이라 스크립트 한 장이면 된다. 그 스크립트는 이 저장소에 넣지
않는다 — 실험마다 보고 싶은 값이 다르고, `lib/` 에 계측을 심는 순간 이 묶음이 프리셋이
아니라 기능이 된다.
