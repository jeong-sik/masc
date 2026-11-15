---
rfc: "operator-quiz-follows-lesson"
title: "수업 뒤 퀴즈: 퀴즈가 수업이 인용한 기록에서만 새 문항을 낸다"
status: Draft
created: 2026-11-14
updated: 2026-11-16
author: claude
related: ["operator-lesson-lane", "operator-quiz-lane"]
---

# RFC: 수업 뒤 퀴즈 (operator-quiz-follows-lesson)

- 상태: Draft. 결정 넷(§8)은 권하는 쪽으로 진행한다. 운영자는 2026-11-14 에 "go" 라고만 답했고 항목을 하나씩 고르지는 않았다.
- 앞 RFC: [operator-lesson-lane](RFC-operator-lesson-lane.md) §10 의 첫 항목이다.
- 좌표는 `파일:줄` 이다. `lib/` 와 `docs/` 는 main `3760a3a2a900`, `addons/` 는 아직 병합되지 않은 수업 스택(#51895, #51896, #51897, #51987)의 #51897 head `485c31fd9556` 기준이다. §9 에 읽은 범위를 적었다.
- 수업 스택이 병합된 뒤에 구현한다. 리뷰에서 수업의 행 모양이 바뀌면 §3.1 을 다시 쓴다.
- 2026-11-15 개정: 시험 설치에서 첫 퀴즈 세션이 수업의 인용 기록을 하나도 읽지 못했다(#52289). §3.8 에 첫 읽기 시작점을 더하고 결정 D5 를 더했다. 개정의 좌표는 main `36c2f465c9b2` 기준이다.

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

- `scenes` 의 항목은 `session_id`, `entry_id`, `cites` 다. `cites` 의 항목은 `kind`, `source_id`, `pin` 이고 `records.parse_pin` 으로 엄격하게 읽는다(`addons/records.py:240-248`). 행에 있는 `quote` 와 `sha256` 은 모양만 검사하고 적지 않는다. 퀴즈는 자기가 읽은 기록의 바이트로 인용문을 검사한다.
- `sha256` 은 host 가 그 관측에 붙인 evidence 의 값이다. 퀴즈가 무엇을 보고 적었는지 나중에 대조할 수 있다.
- `rows` 는 행마다 lane 과 `fields` 를 모아 낸 digest 다. `rows` 가 같은 출력은 한 번만 적는다. 수업은 장면을 쓰지 않을 때도 관측마다 출력을 완료하고, 그때마다 순번이 올라간다. 순번으로 가리면 같은 장면이 관측마다 log 에 쌓인다. host 가 행 id 에 순번을 넣으므로(`lane_addon_runtime.ml:956-960`) 행 전체가 아니라 lane 과 `fields` 로 가린다.
- 모양이 틀린 출력은 일부만 받지 않는다. 통째로 `LessonUnreadable` 이다. 틀린 행을 건너뛰면 어떤 장면이 빠졌는지 알 수 없다.
- `LessonUnreadable` 로 적힌 `rows` 가 다시 오면 다시 읽어 본다. 읽히면 `LessonSeen` 을 적는다. 패키지를 올린 뒤에 읽을 수 있게 된 출력을 버리지 않기 위해서다. 여전히 못 읽으면 더 적지 않는다.
- host 가 준 관측 자체가 host 의 모양이 아니거나 행을 JSON 으로 다시 쓸 수 없으면(NaN, 짝 없는 surrogate) 아무것도 적지 않고 관측 호출이 오류로 끝난다. host 가 같은 출력을 보내는 동안 퀴즈의 행도 나오지 않는다. 수업은 그런 글을 자기 log 에 못 적으므로 host 가 고장 났을 때만 일어난다.
- 관측이 log 에 쓰므로 `lane_observe` 도구의 `readOnlyHint` 를 거짓으로 바꾼다. host 는 이 값을 읽지 않는다.
- source 가 관측 없이 오면(`run_id` 가 다름, 수업 설치가 없음, 수업이 아직 출력을 낸 적 없음) 아무것도 적지 않는다. host 가 준 detail 을 `quiz/measures` 행에 그대로 보여 준다.
- 수업이 실패 중이어도 완료된 출력이 있으면 host 는 그 행을 준다(`lane_addon_runtime.ml:659-671`). 그 장면은 이미 쓴 장면이므로 적는다.

두 사건은 새 종류다. 지금 있는 사건의 필드는 바꾸지 않으므로 옛 log 는 그대로 읽힌다.

### 3.4 세션이 수업을 따르는지 적는 것

worker 가 `compose` action 을 받으면 binding 에서 수업 source 의 이름을 읽어 `Flow.compose` 에 넘긴다. 이름이 있으면 `SessionOpened` 와 같은 쓰기에 `FollowsLesson(session_id, source_id)` 를 더한다. 그 뒤의 일은 binding 없이 log 만 읽고 정한다. 두 사건은 한 번의 쓰기지만 두 줄이라, 쓰기가 사이에서 끊기면 `FollowsLesson` 만 빠질 수 있다. 같은 action 이 다시 오면, 세션이 아직 아무것도 읽지 않았을 때에 한해 빠진 줄을 적는다.

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
- 자료 없이 지난 문항만 실은 요청이 frame 에 안 들어가면 세션은 `author_request_exceeds_frame` 으로 끝난다. 지금 코드는 이 경우 끝나지 않고 돈다. 수업을 묶지 않은 퀴즈에도 있던 결함이고, 묶으면 자료가 비는 일이 흔해지므로 같이 고친다.

cursor 는 지금처럼 문항을 낸 세션만 옮긴다(`quiz_flow.py:191-200`). 문항을 하나도 못 낸 세션이 읽은 기록은 다음 세션이 다시 읽는다. 수업이 아직 그 기록을 다루지 않았다면 다음 번에 다시 맞대어 볼 기회가 생긴다.

`author` 프롬프트는 고치지 않는다. 모델에게 "수업에 나온 것을 먼저 물어라"고 시키지 않는다. 무엇이 자료에 들어가는지는 패키지가 정한다.

### 3.6 잃는 기록

퀴즈는 자기 cursor 로만 읽으므로, 두 Schedule 의 시각에 따라 빠지는 기록이 생긴다. 수업이 매일 09:00, 퀴즈가 매일 18:00 이라고 하자.

| 기록이 생긴 때 | 월요일 수업(09:00) | 월요일 퀴즈(18:00) | 결과 |
| --- | --- | --- | --- |
| 일 18:00 ~ 월 09:00 | 인용할 수 있다 | 읽는다 | 물을 수 있다 |
| 월 09:00 ~ 월 18:00 | 아직 못 봤다 | 읽는다 | 걸러진다. 퀴즈가 문항을 내면 cursor 가 지나가고, 화요일 수업이 인용해도 퀴즈는 다시 읽지 않는다 |

퀴즈를 수업 바로 뒤에 두면 빠지는 구간이 그 사이 시간으로 줄어든다. 가이드에 그렇게 적는다. 한 번도 자료에 실리지 않은 cite 의 수를 `quiz/measures` 에 보여 준다. 구간을 없애는 방법 둘은 §8 D2 에 적었다.

이 표는 질문을 낸 세션이 cursor 를 남긴 source 만 다룬다. cursor 가 없는 source 를 어디서부터 읽는지는 §3.8 이다.

### 3.7 행과 재는 값

- 수업을 묶은 설치는 `quiz/questions` 와 `quiz/review` 의 문항 행에 `taught` 를 더한다. 그 문항을 낼 때까지 적힌 `LessonSeen` 의 cite 가운데 문항의 출처와 같은 것이 하나라도 있으면 참이다. log 에서 계산하고 따로 저장하지 않는다.
- `quiz/measures` 에 `lesson` 을 더한다.
  - `scenes_seen`, `cites_seen`: 적은 장면과 cite 의 수.
  - `cites_unmatched`: 어떤 출제 요청의 자료에도 실리지 않은 cite 의 수. 요청이 커서 잘려 나간 기록도 여기에 든다.
  - `unreadable`: `LessonUnreadable` 의 수.
  - `source`: 마지막 관측에서 host 가 준 `complete` 와 `detail`.
  - `first_attempt`: 항목마다 가장 먼저 답한 채점된 시도를 `taught` 와 나머지로 나눈 수와 정답 수. 낸 순서가 아니라 답한 순서다.
- `lesson` 은 수업을 묶은 설치의 행에만 있다.

`first_attempt` 는 보고하는 값이다. 어떤 상태도 그 값을 읽지 않는다. 무작위 배정이 아니다. 묶은 뒤에는 새 문항이 모두 `taught` 이므로, 나머지 쪽은 묶기 전 문항과 다시 묻는 문항이다. 주제의 난이도와 시기 차이가 섞인다.

### 3.8 첫 읽기 시작점

수업을 따르지 않는 세션은 cursor 가 없는 source 를 퀴즈가 첫 세션을 연 시각부터 읽는다(`addons/operator-quiz/quiz_flow.py` `_next_read`). history 전체를 읽다 worker 가 메모리 부족으로 죽은 #44537 뒤에 정한 규칙이다. cursor 는 질문을 낸 세션만 옮긴다(§3.5). 그래서 질문을 낸 세션이 cursor 를 남길 때까지 모든 세션이 그 source 를 같은 시각부터 읽는다. 이 절을 정하기 전에는 수업을 따르는 세션도 그렇게 읽었다.

수업은 cursor 가 없는 source 를 binding 의 `since` 부터 읽는다. outline 까지 간 지난 세션이 cursor 를 남긴 source 는 그 cursor 부터 읽는다(`addons/records.py` `last_cursor`, `addons/operator-lesson/lesson_flow.py` `_next_read`). 둘을 맞대면 이렇게 됐다.

- 수업을 묶어 새로 설치한 퀴즈는 첫 퀴즈 세션보다 먼저 만들어진 기록을 읽지 못했다.
- 수업이 그 기록을 인용해도 §3.5 의 거르기에서 모두 빠졌다. 다시 물을 문항도 없으면 세션은 `no_material` 로 끝났다.
- 2026-11-15 시험 설치에서 그대로 일어났다(§7, #52289).

고친다.

- 수업을 묶은 퀴즈의 binding 은 `since` 를 받는다. 뜻은 수업의 `since` 와 같다: 지난 세션이 남긴 cursor 가 없는 기록 source 를 읽기 시작하는 Unix 시각(초)이다. 가이드는 수업 선언과 같은 값을 적으라고 쓴다.
- 수업 source 가 있으면 `since` 가 꼭 있어야 하고, 없으면 `since` 를 받지 않는다. binding 스키마를 object 의 `oneOf` 두 갈래로 쓴다: `sources` 가 빈 배열이고 `since` 가 없는 갈래, `sources` 가 하나이고 `since` 가 있는 갈래. host 의 검사기는 object 단위 `oneOf` 를 받고, 값이 갈래 하나에만 맞아야 통과시킨다(`lib/lane_addon/lane_addon_action.ml:82-85, 137-143`). 그래서 틀린 선언은 저장할 때 거절된다.
  - 갈래로 나누면 거절 문구가 `lane binding must match exactly one schema alternative` 하나가 된다. 검사기가 갈래마다의 거절 이유를 버려서다(#52319). 수업을 묶지 않은 선언의 실수(`timezone` 없음, 모르는 키)도 어느 칸이 틀렸는지 나오지 않는다. 통과와 거절은 그대로다.
- 값 검사는 수업과 같다. 정수나 실수이고, 유한하고, 0 이상이다. 수업의 `since_of_binding` 을 `addons/records.py` 로 옮겨 두 패키지가 같이 쓴다.
- `FollowsLesson` 에 `since` 를 더한다(`addons/operator-quiz/quiz_log.py:471-476`). 세션을 열 때 binding 에서 읽어 적고, 그 뒤에는 log 만 읽는다(§3.4).
- 첫 읽기는 기록 source 마다 이렇게 고른다.
  1. 앞서 질문을 낸 세션이 그 source 에 남긴 cursor 가 있으면 지금처럼 거기서부터 읽는다.
  2. 없고 이 세션이 수업을 따르면 자기 `FollowsLesson.since` 부터 읽는다.
  3. 둘 다 아니면 지금처럼 첫 세션을 연 시각부터 읽는다. 묶지 않은 퀴즈는 바뀌지 않는다.

읽는 양은 운영자가 정한 `since` 로 묶인다. 수업을 묶은 퀴즈의 첫 세션은 수업의 첫 세션과 같은 범위를 읽는다. history 전체를 읽던 #44537 의 경로로 돌아가지 않는다. 시험에서 수업은 11-13 부터 이틀 남짓의 기록을 256 MiB 안에서 읽었다. 256 MiB 는 시험 사본에서 올린 값이다. Apple `container` 가 200 MiB 미만을 거절해서 올렸다(#52244). 저장소의 두 매니페스트는 128 MiB 이고, 그 크기로는 읽어 보지 않았다. 같은 범위를 퀴즈가 읽어도 되는지는 구현 뒤 시험 설치로 확인한다.

`FollowsLesson` 의 모양이 바뀐다. 이 사건이 적힌 log 는 #52003 병합(2026-11-15) 뒤의 시험 설치 하나뿐이다. `since` 가 없는 `FollowsLesson` 은 읽지 않는다(hard cut). 시험 설치의 퀴즈 volume 은 지우고 다시 만든다. 옛 모양을 읽는 코드나 변환 코드는 만들지 않는다.

질문을 낸 세션이 남긴 cursor 를 쓸 수 있는 source 에는 `since` 를 다시 쓰지 않는다. 그때부터 빠지는 기록은 §3.6 이다. 쓸 수 있는 cursor 가 없는 source 는 `since` 부터 읽는다. 세 경우가 그렇다.

- 질문을 낸 세션이 아직 읽지 않은 source. 새로 설치한 퀴즈에서는 모든 source 가 그렇고, 처음 쓰는 `source_id` 로 더한 source 도 그렇다. cursor 는 `source_id` 로 찾는다. 뺐다가 같은 `source_id` 로 다시 더한 source 는 전에 남은 cursor 부터 읽는다.
- 질문을 낸 세션이 읽었는데 host 가 cursor 를 주지 않은 source. host 는 기록도 없고 지나친 항목도 없는 읽기에 cursor 를 주지 않는다(`lib/lane_addon/lane_addon_records.ml` `start_cursor`·`answer_page`). 그 source 는 다음 세션이 다시 `since` 부터 읽는다. `github_pulls` 는 기록이 없어도 cursor 가 남을 수 있다. host 는 병합한 PR 이 없는 commit 을 지나치면 지나친 자리를 cursor 로 준다(`take_page`). 그때는 다음 세션이 그 cursor 부터 읽는다.
- host 가 남은 cursor 를 모두 거절한 source(`addons/records.py` `last_cursor`).

이미 질문을 낸 퀴즈에 수업을 묶어도 같다. 묶기 전 세션이 cursor 를 남긴 source 는 그 cursor 부터 읽고, `since` 는 위 세 경우의 source 에만 쓰인다. 수업이 그 cursor 보다 앞선 기록을 인용하면 퀴즈는 그 기록을 읽지 않는다.

수업의 첫 읽기도 source 마다 같은 함수로 고른다. 수업에서는 outline 까지 간 세션이 cursor 를 남긴다.

## 4. 수업 출력의 크기가 먼저다

수업의 관측은 지금까지 쓴 모든 장면을 본문째 돌려줬다(#51941). 퀴즈가 받는 source 는 퀴즈의 `max_reply_bytes`(4 MiB) 안에 들어가야 한다(§2). 장면이 쌓여 4 MiB 를 넘으면 퀴즈는 그 source 를 못 읽고, `LessonSeen` 이 더 적히지 않는다. 그 뒤의 세션은 새 문항을 내지 못한다.

그래서 #51941 을 먼저 고친다. #51987 이 수업 스택의 넷째 층으로 고친다: `lesson/scenes` 는 최근 수업의 장면만 준다. 가장 늦은 장면을 쓴 세션을 연 시각 이후에 장면을 쓴 세션들이다(RFC operator-lesson-lane §4.6).

이 RFC 가 그 범위에 거는 조건은 하나다: 퀴즈가 떠 있는 동안 수업이 쓴 장면은 적어도 한 번의 확정 출력에 실려야 한다.

- host 는 수업의 출력을 장면마다가 아니라 host 요청 주기가 끝날 때 한 번 확정한다(`lib/lane_addon/lane_addon_runtime.ml:1556-1560`). 확정할 때마다 퀴즈의 관측이 불린다.
- 한 주기에 두 수업이 장면을 쓸 수 있다. `scene` slot 이 쉬는 동안 남은 수업과 그 뒤에 연 수업이다. #51987 의 범위는 그 두 수업을 모두 싣는다. 그래서 어떤 장면도 자기 주기의 확정 출력에서 빠지지 않는다.
- 퀴즈가 꺼져 있던 동안 범위 밖으로 나간 장면은 인용 집합에 들어가지 않는다.

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

### 6.1 첫 읽기 시작점(§3.8, 2026-11-15)

위 층은 모두 병합됐다. §3.8 은 새 native stack 으로 올린다.

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L0 | 이 개정 | |
| L1 | `since_of_binding` 을 `addons/records.py` 로 옮김, 퀴즈 binding 스키마의 `oneOf`, `FollowsLesson.since`, 첫 읽기 규칙, revision 올림, 두 이미지 태그 올림 | 아래 시험 |
| L2 | 가이드와 예제 선언에 `since`, `addons/README.md` | 예제 선언이 `test_lane_addon_config` 에서 읽힌다 |

`records.py` 는 패키지 폴더가 아니라 이미지에 들어 있다(각 `Dockerfile` 의 `COPY records.py /records.py`). 그래서 함수를 옮기면 수업과 퀴즈 이미지를 둘 다 새 태그로 만든다. 옛 이미지에서 새 worker 는 `since_of_binding` 을 찾지 못하고 시작하지 못한다.

L1 의 시험:

1. 수업을 묶고 질문을 낸 세션이 없으면 첫 읽기는 `FollowsLesson.since` 부터다.
2. 질문을 낸 세션이 cursor 를 남긴 source 는 `since` 와 상관없이 그 cursor 부터 읽는다.
3. 묶지 않은 퀴즈는 지금처럼 첫 세션을 연 시각부터 읽는다. 지금 있는 시험을 본문 수정 없이 통과한다.
4. 수업을 묶었는데 `since` 가 없거나, 묶지 않았는데 `since` 가 있으면 binding 스키마가 거절한다. 같은 경우를 OCaml 선언 시험(`test_lane_addon_config`)에도 둔다. 그 시험은 `since = 0` 과 소수 `since` 를 받고, 수업 source 둘을 거절하는 것도 본다. #52004 가 더한 수업 source 선언 case 에는 `since` 를 넣는다.
5. `since` 가 없는 `FollowsLesson` 줄은 log 오류로 읽지 않는다.
6. #52289 재현: 수업이 인용한 기록이 첫 퀴즈 세션보다 오래돼도, `since` 가 그보다 앞이면 그 기록이 자료에 남는다.
7. 수업의 `since` 시험은 함수를 옮긴 뒤에도 본문 수정 없이 통과한다.
8. 질문을 낸 세션이 읽은 source 는 cursor 부터, 그 뒤에 더한 source 는 `since` 부터 읽는다.
9. `since` 가 첫 세션을 연 시각보다 뒤여도 `since` 부터 읽는다.
10. 끊긴 opening 을 같은 compose 가 채울 때 `FollowsLesson.since` 는 binding 의 값이다.
11. 처음부터 수업을 묶은 설치에서, 질문을 낸 세션 다음의 세션은 `since` 없이 그 cursor 부터 읽는다. 수업을 따르는 세션도 cursor 를 옮긴다.
12. `since` 부터 읽었는데 기록이 하나도 없던 source 는 다음 세션도 `since` 부터 읽는다. 첫 세션을 연 시각부터가 아니다.
13. 운영자가 binding 의 `since` 를 바꾼 뒤 연 세션은 자기 `FollowsLesson.since` 부터 읽는다. 앞 세션에 적힌 값은 그대로다.

운영자가 하는 일: 수업을 묶은 퀴즈 선언에 수업과 같은 `since` 를 적어 저장한다. 지금 수업을 묶은 설치는 시험 설치 하나뿐이다.

## 7. 확인하지 못한 것

- 관측 중에 log 에 쓰는 것을 막는 규칙은 host 코드와 가이드에서 찾지 못했다. 다만 host 가 관측 응답을 거절해도(예: 크기 초과) 퀴즈의 쓰기는 남는다. `LessonSeen` 은 받은 사실만 적으므로 다시 불려도 같은 값이고, 한 번만 적힌다. L2 에서 실제 host 로 확인한다.
- 퀴즈의 관측 응답 `coverage` 가 묶인 source 를 언급해야 하는지 읽지 않았다. 지금 퀴즈는 빈 배열을 준다.
- `run_id` 를 바꾸면 Dashboard 묶음과 Goal binding 에 어떤 일이 생기는지 읽지 않았다. `/state` 가 유지된다는 것만 확인했다. worker 를 지울 때 named volume 이 남는다는 것은 Docker 의 동작에 기댄 추정이다(`docs/guides/machine-addon-state.md:32-38` 은 같은 말을 한다).
- 2026-11-15 시험 설치(Apple container, 모델 `glm-coding.glm-5.3-flash`, run_id `operator-study-trial`)에서 돌려 본 것:
  - 19:12 수업 compose(장면 2). outline 은 약 5분 40초 뒤 응답했다. 장면 하나는 서버 재시작으로 끊겨 `outcome_unknown`, 하나는 쓰였다. 쓰인 장면은 pin 14개를 인용했다.
  - 퀴즈의 관측은 그 장면을 받았다: `lesson.scenes_seen 1`, `cites_seen 14`.
  - 19:43 퀴즈 compose(문항 1)는 이 설치의 첫 세션이었고 `no_material` 로 끝났다(`cites_unmatched 14`). §3.8 의 경우다.
  - 그래서 출제 요청, Approvals 의 ask, 채점, `taught` 는 실제 설치로 확인하지 못했다.

## 8. 운영자 결정

| # | 질문 | 권하는 쪽 | 대가 |
| --- | --- | --- | --- |
| D1 | 묶은 퀴즈의 새 문항 범위 | 수업이 인용한 기록만(§3.5) | 수업이 다루지 않은 기록은 퀴즈가 묻지 않는다. 넓게 묻고 싶으면 묶지 않는다 |
| D2 | 빠지는 구간(§3.6)을 어떻게 하나 | v1 은 그대로 두고 수를 보여 준다 | 대안 셋. (다) 수업 장면을 자료로 쓴다(§5): 구간이 없어지지만 문항의 근거가 조각이 된다. (가) 퀴즈가 지난 세션의 보존된 page 에서도 찾는다: core 는 그대로지만 compose 마다 지난 page 를 모두 훑는다. (나) host 에 pin 으로 기록 하나를 읽는 요청을 더한다: 구간이 없어지지만 core 를 고치고 별도 RFC 가 필요하다 |
| D3 | #51941(수업 출력 크기)을 이 스택 앞에 고치나 | 고친다(§4). #51987 로 올렸다 | 지난 수업의 장면이 Results 에서 사라진다. 안 고치면 장면이 쌓인 뒤 퀴즈가 새 문항을 못 낸다 |
| D4 | 두 설치가 같이 쓸 `run_id` | 예제 둘을 `operator-study` 로 맞춘다 | 이미 설치한 퀴즈의 선언을 고쳐 저장해야 한다 |
| D5 | 질문을 낸 세션이 없는 묶은 퀴즈의 첫 읽기 시작점(§3.8) | 퀴즈 binding 에 수업과 같은 뜻의 `since` 를 두고, 묶으면 꼭 적게 한다 | 운영자가 두 선언의 `since` 를 맞춰야 한다. 어긋나도 퀴즈는 알 수 없고 `cites_unmatched` 로만 보인다. 대안 둘. (라) 수업의 `scenes` 행이 읽은 범위의 시작 시각을 싣고 퀴즈가 그 값부터 읽는다: 맞출 값이 없어지지만 다른 설치가 낸 값이 읽는 양을 정하므로 상한을 따로 정해야 하고, 수업의 행 모양이 바뀐다. (나) host 에 pin 으로 기록 하나를 읽는 요청을 더한다(D2 와 같다): 첫 읽기와 §3.6 의 구간이 함께 없어지지만 core 를 고치고 별도 RFC 가 필요하다 |

## 9. 읽은 범위와 확신

**직접 읽음:**
- `docs/guides/lane-output-composition.md`, `lane-output-ports.md` 전부. `lane-addon-toml.md:40-56, 505-525`.
- `addons/operator-quiz/quiz_flow.py:71-270, 391-425, 467-520`, `server.py:100-136`, `lane.toml` 의 binding 스키마. `quiz_log.py:296-340`.
- `addons/operator-lesson/lane.toml`, `lesson_projection.py:40-100`, `lesson_log.py:33-46, 77-90`. `addons/records.py:166-260, 372-552`.
- `addons/output-statistics/lane.toml`, `server.py:60-115`.

**2026-11-15 개정 때 직접 읽음(main `36c2f465c9b2`):**
- `addons/operator-quiz/quiz_flow.py:186-221, 327-349`, `quiz_log.py:466-480`, `lane.toml:35-78`.
- `addons/operator-lesson/lesson_flow.py:53-64, 118-147`.
- `lib/lane_addon/lane_addon_action.ml:62-160`, `lane_addon_config.ml:175-181`.
- #44537 본문. 시험 설치의 Lane 행과 exact 요청 기록.

**조사 보고에 기댐(읽기 전용 에이전트 한 번, 2026-11-14):**
- §2 표의 `lib/lane_addon/` 좌표 전부와 `test/test_lane_addon_composition.ml`. 직접 다시 읽지 않았다.

**확신:**
- core 를 고치지 않아도 된다: 높다. `lane_output` 은 다른 패키지가 이미 쓴다.
- 묶지 않은 퀴즈가 그대로 돈다: 높다. 새 사건은 source 가 있을 때만 적힌다.
- 빠지는 구간이 실제로 얼마나 큰가: 모른다. 수업이 무엇을 인용하는지에 달렸다. `cites_unmatched` 로 본다.
- 수업을 읽으면 정답이 늘어나는가: 모른다. §3.7 의 값은 비교군이 고르지 않다.
- §3.8 이 시험의 `no_material` 을 없애는가: 높다. 원인이 첫 읽기 시작점 하나이고, 수업이 인용한 기록은 모두 수업의 `since` 뒤에 있다.
- 묶은 퀴즈의 첫 세션이 `since` 부터 읽어도 메모리 안에 드는가: 모른다. 수업은 같은 범위를 256 MiB 안에서 읽었지만, 퀴즈의 읽기는 따로 재지 않았다. 256 MiB 는 시험 사본의 값이고, 매니페스트의 128 MiB 로는 수업도 퀴즈도 읽어 보지 않았다.
