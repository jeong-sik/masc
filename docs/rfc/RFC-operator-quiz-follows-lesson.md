---
rfc: "operator-quiz-follows-lesson"
title: "수업 뒤 퀴즈: 퀴즈가 수업이 인용한 기록에서만 새 문항을 낸다"
status: Draft
created: 2026-11-14
updated: 2026-11-14
author: claude
related: ["operator-lesson-lane", "operator-quiz-lane"]
---

# RFC: 수업 뒤 퀴즈 (operator-quiz-follows-lesson)

- 상태: Draft. 결정 넷(§8)은 권하는 쪽으로 진행한다. 운영자는 2026-11-14 에 "go" 라고만 답했고 항목을 하나씩 고르지는 않았다.
- 앞 RFC: [operator-lesson-lane](RFC-operator-lesson-lane.md) §10 의 첫 항목이다.
- 좌표는 `파일:줄` 이다. `lib/` 와 `docs/` 는 main `3760a3a2a900`, `addons/` 는 아직 병합되지 않은 수업 스택(#51895, #51896, #51897, #51987)의 #51897 head `485c31fd9556` 기준이다. §9 에 읽은 범위를 적었다.
- 수업 스택이 병합된 뒤에 구현한다. 리뷰에서 수업의 행 모양이 바뀌면 §3.1 을 다시 쓴다.

## 0. 요약

지금 퀴즈와 수업은 같은 기록을 따로 읽는다. 퀴즈가 무엇을 물을지는 `author` 출력이 그때 고르고, 운영자가 그 주제를 먼저 읽었는지는 상관이 없다.

퀴즈 설치가 수업 설치의 출력을 `lane_output` source 로 묶으면 다음이 달라진다.

- 퀴즈가 수업 장면이 인용한 pin 을 자기 log 에 적는다.
- 새 문항의 자료는 퀴즈가 이번에 읽은 기록 가운데 수업이 인용한 것만이다.
- 다시 묻는 문항은 지금과 같다.
- `quiz/measures` 가 수업이 인용한 기록의 문항과 나머지 문항의 첫 시도 정답 수를 나란히 보여 준다.

묶지 않은 퀴즈는 지금과 똑같이 돈다. core 는 고치지 않는다. `author` 프롬프트와 스키마도 고치지 않는다.

## 1. 문제

1. 수업이 설명한 일과 퀴즈가 묻는 일이 겹친다는 보장이 없다. 두 패키지가 각자 cursor 로 읽고 각자 모델이 고른다(`addons/operator-quiz/quiz_flow.py:191-214`, `addons/operator-lesson/lesson_flow.py`).
2. 수업이 운영자의 이해를 높이는지 잴 값이 없다. 앞 RFC §8 은 그 값을 "퀴즈와 이은 뒤에 잰다"고 미뤘다.

## 2. host 가 주는 것과 주지 않는 것

설계를 정한 사실이다. 모두 코드에서 읽었다.

| 사실 | 좌표 |
| --- | --- |
| `lane_output` source 는 `lane_observe` 호출에만 온다. `lane_act`, `lane_host_requests`, `lane_host_result` 에는 오지 않는다 | `lib/lane_addon/lane_addon_worker_protocol.ml:239-242, 291-293, 370`, `lane_addon_action.ml:31-32` |
| producer 의 행은 `fields` 까지 통째로 온다. port 를 고르면 그 lane 의 행만 온다 | `lib/lane_addon/lane_addon_sources.ml:503-535`, `lane_addon_types.ml:151-157` |
| producer 와 consumer 의 `run_id` 가 다르면 source 는 `complete=false`, `observations=[]` 이고 detail 은 "upstream installation belongs to another run" 이다 | `lib/lane_addon/lane_addon_runtime.ml:713`, `test/test_lane_addon_composition.ml:272-284` |
| producer 가 출력을 commit 하면 consumer 의 `lane_observe` 가 새 source 로 불린다. consumer 의 host 요청 주기는 돌지 않는다 | `lane_addon_runtime.ml:724-727, 1565-1589, 2520-2521` |
| source 전체는 consumer 의 `max_reply_bytes` 안에 들어가야 한다. 넘으면 그 source 는 못 읽은 것으로 온다 | `lane_addon_sources.ml:522, 553-575` |
| 기록 하나를 pin 으로 읽는 host 요청은 없다. `read_file` 만 커밋과 경로로 파일 하나를 읽는다 | `lib/lane_addon/lane_addon_host_request.ml:135-150`, `lane_addon_records.ml:662-717` |
| `/state` volume 의 열쇠는 workspace, 설치 선언 `id`, 패키지 id 다. `run_id` 와 binding 은 열쇠가 아니다 | `lib/lane_addon/lane_addon_worker_state.ml:3-21`, `lane_addon_runtime.ml:333-348` |

두 가지가 따라 나온다.

- 퀴즈는 출제 요청을 `lane_host_result` 안에서 만든다. 그 자리에는 수업의 행이 없다. 그래서 관측 때 받은 pin 을 log 에 적어 두어야 한다.
- 퀴즈는 수업이 인용한 기록을 골라서 읽을 수 없다. 자기 cursor 로 읽은 기록과 수업의 pin 을 맞대어 볼 수 있을 뿐이다.

## 3. 설계

### 3.1 수업: 장면만 내보내는 port

`addons/operator-lesson/lane.toml` 에 port 하나를 더한다. 지금 있는 `lesson` port 는 세 lane 을 모두 싣는다(`lane.toml:21-22`).

```toml
[world.outputs.scenes]
lanes = ["lesson/scenes"]
```

장면 행은 이미 필요한 것을 싣는다(`addons/operator-lesson/lesson_projection.py:40-48`): `session_id`, `entry_id`, `written_at`, 그리고 `sources` 의 항목마다 `paragraph`, `kind`, `source_id`, `pin`, `quote`, `sha256`. 수업의 log 와 행은 고치지 않는다. 패키지 revision 만 올린다.

### 3.2 퀴즈 binding

`binding.sources` 는 지금 빈 배열로 고정돼 있다(`addons/operator-quiz/lane.toml:38-40`). 항목 하나까지 받게 한다.

```toml
[[binding.sources]]
source_id = "lesson"
kind = "lane_output"
installation_id = "operator-lesson"
output_id = "scenes"
selection = "latest_completed"
```

- `kind`, `output_id`, `selection` 은 스키마에서 `const` 다. 다른 port 나 다른 종류의 source 는 binding 검사에서 거절된다.
- 두 설치 선언의 `run_id` 가 같아야 한다. 예제 선언은 지금 서로 다르다(`docs/examples/lane-addons/operator-lesson.toml`, `operator-quiz.toml`). §8 D4.
- 두 선언이 같은 기록에 같은 `source_id` 를 써야 한다. pin 은 `kind`, `source_id`, `pin` 셋이 모두 같을 때만 같은 기록으로 본다. 저장소 파일의 pin 은 커밋과 경로뿐이라(`addons/records.py:184-191`) `source_id` 없이는 어느 저장소인지 알 수 없다.

### 3.3 관측 때 적는 것

퀴즈의 `observe` 는 지금 `sources` 를 받기만 하고 읽지 않는다(`addons/operator-quiz/server.py:107-126`). 묶은 source 에 관측이 있으면 다음 사건 하나를 log 에 더한다.

| 사건 | 필드 | 언제 |
| --- | --- | --- |
| `LessonSeen` | `instance_id`, `observation_seq`, `sha256`, `rows`, `scenes` | 행을 모두 읽었을 때 |
| `LessonUnreadable` | `instance_id`, `observation_seq`, `sha256`, `rows`, `reason` | 행 하나라도 모양이 틀렸을 때 |

- `scenes` 의 항목은 `session_id`, `entry_id`, `written_at`, `cites` 다. `cites` 의 항목은 `kind`, `source_id`, `pin` 이고 `records.parse_pin` 으로 엄격하게 읽는다(`addons/records.py:240-248`). 행에 있는 `quote` 와 `sha256` 은 모양만 검사하고 적지 않는다. 퀴즈는 자기가 읽은 기록의 바이트로 인용문을 검사한다.
- `sha256` 은 host 가 그 관측에 붙인 evidence 의 값이다. 퀴즈가 무엇을 보고 적었는지 나중에 대조할 수 있다.
- `rows` 는 행마다 lane 과 `fields` 를 모아 낸 digest 다. `rows` 가 같은 출력은 한 번만 적는다. 수업은 장면을 쓰지 않을 때도 관측마다 출력을 완료하고, 그때마다 순번이 올라간다. 순번으로 가리면 같은 장면이 관측마다 log 에 쌓인다. host 가 행 id 에 순번을 넣으므로(`lane_addon_runtime.ml:956-960`) 행 전체가 아니라 lane 과 `fields` 로 가린다.
- 모양이 틀린 출력은 일부만 받지 않는다. 통째로 `LessonUnreadable` 이다. 틀린 행을 건너뛰면 어떤 장면이 빠졌는지 알 수 없다.
- source 가 관측 없이 오면(`run_id` 가 다름, 수업 설치가 없음, 수업이 아직 출력을 낸 적 없음) 아무것도 적지 않는다. host 가 준 detail 을 `quiz/measures` 행에 그대로 보여 준다.
- 수업이 실패 중이어도 완료된 출력이 있으면 host 는 그 행을 준다(`lane_addon_runtime.ml:659-671`). 그 장면은 이미 쓴 장면이므로 적는다.

두 사건은 새 종류다. 지금 있는 사건의 필드는 바꾸지 않으므로 옛 log 는 그대로 읽힌다.

### 3.4 세션이 수업을 따르는지 적는 것

worker 가 `compose` action 을 받으면 binding 에서 수업 source 의 이름을 읽어 `Flow.compose` 에 넘긴다. 이름이 있으면 `SessionOpened` 와 같은 쓰기에 `FollowsLesson(session_id, source_id)` 를 더한다. 그 뒤의 일은 binding 없이 log 만 읽고 정한다.

`SessionOpened` 에 필드를 더하지 않는 이유: 옛 log 의 `SessionOpened` 를 읽지 못하게 된다.

### 3.5 자료 거르기

`FollowsLesson` 이 있는 세션은 읽기를 마친 뒤 자료를 거른다.

- 수업이 인용한 집합: 그때까지 log 에 있는 모든 `LessonSeen` 의 `cites`.
- 남기는 기록: 이번 세션이 읽은 기록 가운데 `kind`, `source_id`, `pin` 이 그 집합에 있는 것.
- 거른 뒤에 지금과 같은 순서로 간다. 요청이 frame 에 안 들어가면 새 절반만 남기는 규칙(`quiz_flow.py:254-270`)도 거른 자료에 건다.
- 출제 요청과 같은 쓰기에 `LessonScopeApplied(session_id, request_id, kept)` 를 적는다. `kept` 는 그 요청의 자료에 실린 기록의 cite 다. 읽은 기록 수는 적지 않는다. 퀴즈는 요청 하나에 들어갈 만큼만 디스크에서 다시 읽으므로(`quiz_flow.py:172-189`) 그 수를 세려면 모든 page 를 읽어야 한다.

남긴 기록이 없을 때는 지금의 규칙이 그대로 돈다(`quiz_flow.py:416-424`).

- 다시 물을 문항이 있으면 `author` 는 그 문항만으로 요청을 받는다.
- 그것도 없으면 세션은 `no_material` 로 끝난다.

cursor 는 지금처럼 문항을 낸 세션만 옮긴다(`quiz_flow.py:191-200`). 문항을 하나도 못 낸 세션이 읽은 기록은 다음 세션이 다시 읽는다. 수업이 아직 그 기록을 다루지 않았다면 다음 번에 다시 맞대어 볼 기회가 생긴다.

`author` 프롬프트는 고치지 않는다. 모델에게 "수업에 나온 것을 먼저 물어라"고 시키지 않는다. 무엇이 자료에 들어가는지는 패키지가 정한다.

### 3.6 잃는 기록

퀴즈는 자기 cursor 로만 읽으므로, 두 Schedule 의 시각에 따라 빠지는 기록이 생긴다. 수업이 매일 09:00, 퀴즈가 매일 18:00 이라고 하자.

| 기록이 생긴 때 | 월요일 수업(09:00) | 월요일 퀴즈(18:00) | 결과 |
| --- | --- | --- | --- |
| 일 18:00 ~ 월 09:00 | 인용할 수 있다 | 읽는다 | 물을 수 있다 |
| 월 09:00 ~ 월 18:00 | 아직 못 봤다 | 읽는다 | 걸러진다. 퀴즈가 문항을 내면 cursor 가 지나가고, 화요일 수업이 인용해도 퀴즈는 다시 읽지 않는다 |

퀴즈를 수업 바로 뒤에 두면 빠지는 구간이 그 사이 시간으로 줄어든다. 가이드에 그렇게 적는다. 한 번도 자료에 실리지 않은 cite 의 수를 `quiz/measures` 에 보여 준다. 구간을 없애는 방법 둘은 §8 D2 에 적었다.

### 3.7 행과 재는 값

- `quiz/questions` 와 `quiz/review` 의 문항 행에 `taught` 를 더한다. 그 문항을 낼 때까지 적힌 `LessonSeen` 의 cite 가운데 문항의 출처와 같은 것이 하나라도 있으면 참이다. log 에서 계산하고 따로 저장하지 않는다.
- `quiz/measures` 에 `lesson` 을 더한다.
  - `scenes_seen`, `cites_seen`: 적은 장면과 cite 의 수.
  - `cites_unmatched`: 어떤 출제 요청의 자료에도 실리지 않은 cite 의 수. 요청이 커서 잘려 나간 기록도 여기에 든다.
  - `unreadable`: `LessonUnreadable` 의 수.
  - `source`: 마지막 관측에서 host 가 준 `complete` 와 `detail`.
  - `first_attempt`: 항목마다 처음 채점된 시도를 `taught` 와 나머지로 나눈 수와 정답 수.
- `lesson` 은 수업을 묶은 설치의 행에만 있다.

`first_attempt` 는 보고하는 값이다. 어떤 상태도 그 값을 읽지 않는다. 무작위 배정이 아니다. 묶은 뒤에는 새 문항이 모두 `taught` 이므로, 나머지 쪽은 묶기 전 문항과 다시 묻는 문항이다. 주제의 난이도와 시기 차이가 섞인다.

## 4. 수업 출력의 크기가 먼저다

수업의 관측은 지금까지 쓴 모든 장면을 본문째 돌려줬다(#51941). 퀴즈가 받는 source 는 퀴즈의 `max_reply_bytes`(4 MiB) 안에 들어가야 한다(§2). 장면이 쌓여 4 MiB 를 넘으면 퀴즈는 그 source 를 못 읽고, `LessonSeen` 이 더 적히지 않는다. 그 뒤의 세션은 새 문항을 내지 못한다.

그래서 #51941 을 먼저 고친다. #51987 이 수업 스택의 넷째 층으로 고친다: `lesson/scenes` 는 가장 최근에 장면을 쓴 세션의 장면만 준다.

이 RFC 가 그 범위에 거는 조건은 하나다: 퀴즈가 떠 있는 동안 수업이 commit 한 장면은 적어도 한 번의 출력에 실려야 한다. 수업은 장면 하나를 쓸 때마다 commit 하고 그때마다 퀴즈의 관측이 불린다. 방금 쓴 장면은 늘 행으로 나온 세션에 있으므로 조건이 맞는다. 퀴즈가 꺼져 있던 동안 범위 밖으로 나간 장면은 인용 집합에 들어가지 않는다.

## 5. 고르지 않은 설계

- **수업 장면을 자료로 쓴다.** 퀴즈가 기록을 읽지 않고 장면 본문과 장면의 인용문에서 묻는다. 빠지는 구간이 없다. 장면 행에는 수업이 기록 바이트와 맞춰 본 인용문과 그 SHA-256 이 있어서, 문항의 인용문이 수업의 인용문 안에 있는지는 검사할 수 있다. 버린 이유는 둘이다. `author` 가 받는 글이 모델이 쓴 본문과 인용문 조각뿐이라, 정답의 근거가 기록 전체가 아니라 조각이나 모델의 글이 된다. 그리고 채점(`grade`)은 퀴즈가 보존한 page 에서 기록 글을 다시 읽는데(`quiz_flow.py:308-323`) 그 page 가 없다.
- **거르지 않고 표시만 한다.** 자료의 기록마다 "수업에 나옴"을 붙이고 프롬프트로 먼저 묻게 한다. 버린 이유: 얼마나 따르는지가 묶은 모델에 달린다.
- **수업 행에 기록 본문을 싣는다.** 버린 이유: Board 의 `internal` 글이 다른 lane 의 행으로 복사된다. 출력 크기도 더 빨리 넘는다.

## 6. 쪼개기

native stack 으로 올린다. 층마다 changelog 조각을 넣는다.

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L0 | 이 RFC | |
| L1 | 수업 `scenes` port, revision 올림 | `test_lane_addon_config` 의 수업 선언 case 가 새 port 를 읽는다 |
| L2 | 퀴즈: binding 스키마, 사건 넷(`LessonSeen`, `LessonUnreadable`, `FollowsLesson`, `LessonScopeApplied`), 관측에서 적기, 자료 거르기, 행 | 아래 시험 |
| L3 | 가이드, 예제 선언(`run_id` 맞춤), `addons/README.md` | 선언이 `test_lane_addon_config` 에서 읽힌다 |

L2 의 Python 시험(`addons/tests/`):

1. 묶지 않은 퀴즈는 지금 시험 116개를 본문 수정 없이 통과한다.
2. 같은 관측을 두 번 받으면 `LessonSeen` 은 하나다.
3. 행 하나의 pin 이 틀리면 `LessonUnreadable` 하나만 적히고 인용 집합은 그대로다.
4. 기록 셋을 읽고 수업이 하나를 인용했으면 출제 요청의 자료는 그 하나다.
5. 인용한 기록이 자료에 없고 다시 물을 문항도 없으면 `no_material` 이고, 다음 세션이 같은 기록을 다시 읽는다.
6. `source_id` 만 다른 같은 pin 은 맞지 않는다.
7. 옛 log(새 사건이 없는 log)를 그대로 읽는다.
8. 관측이 없는 source 는 아무것도 적지 않고 `quiz/measures` 에 detail 이 나온다.

운영자가 하는 일: 두 선언의 `run_id` 를 맞추고 퀴즈 선언에 source 를 더해 저장한다. 퀴즈 worker 는 새 instance 로 다시 뜨고 `/state` 는 그대로다(§2). 퀴즈 Schedule 을 수업 바로 뒤로 옮긴다.

## 7. 확인하지 못한 것

- 관측 중에 log 에 쓰는 것을 막는 규칙은 host 코드와 가이드에서 찾지 못했다. 다만 host 가 관측 응답을 거절해도(예: 크기 초과) 퀴즈의 쓰기는 남는다. `LessonSeen` 은 받은 사실만 적으므로 다시 불려도 같은 값이고, 한 번만 적힌다. L2 에서 실제 host 로 확인한다.
- 퀴즈의 관측 응답 `coverage` 가 묶인 source 를 언급해야 하는지 읽지 않았다. 지금 퀴즈는 빈 배열을 준다.
- `run_id` 를 바꾸면 Dashboard 묶음과 Goal binding 에 어떤 일이 생기는지 읽지 않았다. `/state` 가 유지된다는 것만 확인했다. worker 를 지울 때 named volume 이 남는다는 것은 Docker 의 동작에 기댄 추정이다(`docs/guides/machine-addon-state.md:32-38` 은 같은 말을 한다).
- 실제 설치로 돌려 본 것은 없다.

## 8. 운영자 결정

| # | 질문 | 권하는 쪽 | 대가 |
| --- | --- | --- | --- |
| D1 | 묶은 퀴즈의 새 문항 범위 | 수업이 인용한 기록만(§3.5) | 수업이 다루지 않은 기록은 퀴즈가 묻지 않는다. 넓게 묻고 싶으면 묶지 않는다 |
| D2 | 빠지는 구간(§3.6)을 어떻게 하나 | v1 은 그대로 두고 수를 보여 준다 | 대안 셋. (다) 수업 장면을 자료로 쓴다(§5): 구간이 없어지지만 문항의 근거가 조각이 된다. (가) 퀴즈가 지난 세션의 보존된 page 에서도 찾는다: core 는 그대로지만 compose 마다 지난 page 를 모두 훑는다. (나) host 에 pin 으로 기록 하나를 읽는 요청을 더한다: 구간이 없어지지만 core 를 고치고 별도 RFC 가 필요하다 |
| D3 | #51941(수업 출력 크기)을 이 스택 앞에 고치나 | 고친다(§4). #51987 로 올렸다 | 지난 수업의 장면이 Results 에서 사라진다. 안 고치면 장면이 쌓인 뒤 퀴즈가 새 문항을 못 낸다 |
| D4 | 두 설치가 같이 쓸 `run_id` | 예제 둘을 `operator-study` 로 맞춘다 | 이미 설치한 퀴즈의 선언을 고쳐 저장해야 한다 |

## 9. 읽은 범위와 확신

**직접 읽음:**
- `docs/guides/lane-output-composition.md`, `lane-output-ports.md` 전부. `lane-addon-toml.md:40-56, 505-525`.
- `addons/operator-quiz/quiz_flow.py:71-270, 391-425, 467-520`, `server.py:100-136`, `lane.toml` 의 binding 스키마. `quiz_log.py:296-340`.
- `addons/operator-lesson/lane.toml`, `lesson_projection.py:40-100`, `lesson_log.py:33-46, 77-90`. `addons/records.py:166-260, 372-552`.
- `addons/output-statistics/lane.toml`, `server.py:60-115`.

**조사 보고에 기댐(읽기 전용 에이전트 한 번, 2026-11-14):**
- §2 표의 `lib/lane_addon/` 좌표 전부와 `test/test_lane_addon_composition.ml`. 직접 다시 읽지 않았다.

**확신:**
- core 를 고치지 않아도 된다: 높다. `lane_output` 은 다른 패키지가 이미 쓴다.
- 묶지 않은 퀴즈가 그대로 돈다: 높다. 새 사건은 source 가 있을 때만 적힌다.
- 빠지는 구간이 실제로 얼마나 큰가: 모른다. 수업이 무엇을 인용하는지에 달렸다. `cites_unmatched` 로 본다.
- 수업을 읽으면 정답이 늘어나는가: 모른다. §3.7 의 값은 비교군이 고르지 않다.
