# 운영자 퀴즈

운영자 퀴즈(`operator-quiz`)는 이 워크스페이스의 Board 글과 changelog 조각을 읽고, 운영자에게 객관식 문제를 내는 Lane Add-on 패키지다. 문제는 Approvals 에 나오고, 답하면 바로 채점된다. 틀린 문제는 다음 날 이후에 다시 나올 수 있다.

설계와 근거는 [운영자 퀴즈 RFC](../rfc/RFC-operator-quiz-lane.md)에 있다. 이 문서는 켜고, 시간을 정하고, 결과를 읽는 방법만 다룬다.

## 한 번의 퀴즈가 지나가는 길

1. Schedule 이 정한 시각에 `compose` 를 보낸다. 패키지는 세션을 하나 열고 `confirmed` 로 답한다.
2. 패키지가 host 에게 기록을 한 번에 하나씩 요청한다. 지난번에 질문까지 간 세션이 멈춘 자리부터 읽는다. 실패했거나 다음 세션으로 대체된 세션이 읽은 기록은 다시 읽는다.
3. 다 읽으면 `author` 출력을 한 번 요청한다. 읽은 기록, 지난 문제들의 풀이 기록, 문제 수, 언어를 함께 보낸다. 새 기록이 없어도 지난 문제가 있으면 요청한다. 이때 `author` 는 지난 문제를 그 출처 그대로 다시 낼 수 있다.
4. 돌아온 문제마다 확인한다. 정답 선택지가 선택지 안에 있는지, `single` 이 정답을 하나만 갖는지, 인용문이 그 기록의 보관된 바이트에 글자 그대로 있는지 본다. 통과하지 못한 문제는 이유와 함께 버린다. 하나도 통과하지 못하면 세션은 `no_question_passed` 로 끝난다.
5. 통과한 문제와 정답을 로그에 먼저 쓴다. 그다음에 정답과 출처를 뺀 질문을 Approvals 에 낸다.
6. 운영자가 답하면 선택지로 바로 채점하고, Results 에 공개(reveal) 행이 생긴다.

## 켜기

### 1. 이미지 만들기

```sh
docker build -f addons/operator-quiz/Dockerfile -t masc-lane-operator-quiz:0.1.0 addons
```

설치 조정(reconcile)은 이미지를 만들지 않는다. MASC 가 쓰는 엔진에 먼저 올려 둔다.

### 2. 설치 선언

[`docs/examples/lane-addons/operator-quiz.toml`](../examples/lane-addons/operator-quiz.toml)을 `lane-addons/` 아래로 복사하고 `manifest_path` 를 맞춘다.

```toml
[binding]
sources = []
language = "ko"
timezone = "Asia/Seoul"

[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public", "unlisted"]

[[binding.records]]
source_id = "masc-repo"
kind = "repository"
repository_id = "masc"
paths = ["changelog.d/"]
```

- `language`: 문제를 쓰는 언어다.
- `timezone`: 운영자의 IANA 시간대다. R(아래)은 이 시간대의 날짜로 "다음 날 이후"를 센다.
- `records`: 읽을 기록이다. 운영자가 쓴 TOML 선언만 기록 권한을 가질 수 있다.
- `visibilities` 에 적은 공개 범위의 글은 `author` 출력에 묶인 slot 의 provider 에게 간다. `internal` 을 넣거나 `direct` 를 적기 전에, 그 provider 가 그런 글을 받아도 되는지 확인한다.
- Board 글은 공개 범위를 따로 정하지 않으면 `internal` 이다. `public`, `unlisted` 만 적으면 그렇게 정한 글만 읽으므로, 문제 재료가 거의 없을 수 있다.
- `repository` 권한은 등록된 저장소 clone 의 기본 브랜치를 읽고, fetch 하지 않는다. 새 changelog 조각을 문제로 내려면 그 저장소의 `auto_sync` 를 켜 둔다.
- `sources` 는 늘 빈 배열이다. 이 패키지는 관측 source 를 읽지 않는다.

### 3. `author` slot 묶기

`runtime.toml` 에 설치 선언 id 로 표를 둔다. 표의 키와 규칙은 [Lane Add-on TOML](lane-addon-toml.md)의 "패키지가 선언하는 exact output" 과 같다.

```toml
[runtime.addon_exact_lanes.operator-quiz.author]
slots = ["glm-coding.glm-5-3"]
max_output_tokens = 8192
```

표가 없으면 `author` 요청은 `lane_unconfigured` 로 기다린다. 다음 `compose` 가 그 세션을 대체한다.

### 4. 시간 정하기

`masc_schedule_create` 로 Lane action Schedule 을 만든다.

```json
{"installation_id": "operator-quiz",
 "action": {"kind": "compose", "questions": 5},
 "recurrence_kind": "daily", "recurrence_hour": 8, "recurrence_minute": 30,
 "recurrence_timezone": "Asia/Seoul"}
```

- `questions` 는 꼭 적는다. 패키지에는 기본 문제 수가 없다.
- 평일만 내려면 `recurrence_kind = "cron"`, `recurrence_cron = "30 8 * * 1-5"` 를 쓴다.
- 바로 한 번 내려면 Lane Add-on 화면의 action 메뉴에서 `compose` 를 고른다.

## 매일 쓰기

- 시간 바꾸기: `masc_schedule_update`.
- 멈추기: Schedule 을 취소하거나 선언을 `enabled = false` 로 둔다. 선언을 끄면 worker 는 내려가고 volume 은 남는다. 열린 질문은 Approvals 에 그대로 있고, 다음 worker 가 답을 받는다.
- 답하지 않은 질문: 기한도 개수 제한도 없다. `compose` 마다 질문이 하나씩 늘어난다. 아직 질문을 내지 않은 세션만 다음 `compose` 가 대체한다.
- 두 개 돌리기: 다른 선언 id 로 두 번 설치한다. volume, lane, Schedule 이 따로 생긴다.

## 결과 읽기

Results 에 다섯 lane 이 나온다.

| lane | 한 행 | 보는 것 |
|---|---|---|
| `quiz/sessions` | `compose` 하나 | 상태, 맞음·틀림·건너뜀·채점 대기·열림 수, 실패 이유 |
| `quiz/questions` | 답한 문제 하나 | 내 답, 정답, 판정, 출처의 인용문과 hash |
| `quiz/topics` | 주제 하나 | 문제 수, 풀이 수, 놓친 수, 아직 못 맞힌 문제와 그 출처 |
| `quiz/items` | 복습 항목 하나 | 풀이 기록, 마지막 판정, 연속으로 맞힌 횟수 |
| `quiz/measures` | 하나 | R, P, 점수, 버린 문제 수, 실패한 세션 수(이유별) |

- 답하기 전의 문제는 `quiz/questions` 에 행이 없다. 정답이 먼저 보이는 일은 없다.
- 건너뛴 문제는 놓친 문제로 센다. 직접 쓴 답은 아직 채점하지 않고 `awaiting_judgment` 로 남는다. 서술형 채점은 다음 단계(`grade` 출력)에서 들어온다.
- 출처의 `sha256` 은 host 가 Lane store 에 보관한 바이트의 이름이다. 글이 나중에 고쳐지거나 changelog 조각이 릴리스에서 지워져도, 인용한 바이트를 그대로 확인할 수 있다.

### R 과 P

- **R(다시 물었을 때 맞힌 비율)**: 놓친 뒤 다른 날 다시 푼 적이 있는 복습 항목 수가 d 다. 그중 처음 다시 푼 날 맞힌 항목 수가 n 이다. 같은 날 다시 맞힌 것은 세지 않는다.
- **P(참여)**: 채점된 풀이 수를 낸 문제 수로 나눈 값이다.
- 둘 다 n/d 로만 보인다. 통과·실패를 말하는 필드는 없고, 어떤 상태도 이 숫자로 바뀌지 않는다.
- RFC 의 목표는 30일 운영 뒤 d ≥ 20, n/d ≥ 2/3 이다. 비교할 기준 없이 정한 첫 제안이고, 첫 달을 본 뒤 다시 정한다. 판단은 운영자가 한다.

## 세션이 실패하는 이유

세션은 아래 이유 중 하나로만 실패한다. 이유는 `quiz/sessions` 행의 `failure` 에 있다.

| `kind` | 뜻 |
|---|---|
| `not_allowed` | host 가 규칙으로 요청을 거절했다(권한이 없는 기록, 선언하지 않은 출력, `[world.asks]` 없음). 질문을 낸 세션도 그 질문이 거절되면 여기서 끝난다. |
| `no_material` | 모든 권한을 읽었지만 새 기록이 없었고, 전에 낸 문제도 없었다. 아직 문제를 낸 세션이 없으면 퀴즈를 켠 뒤(첫 세션이 열린 뒤) 생긴 기록만 읽으므로, 켜자마자 보낸 `compose` 는 이렇게 끝나기 쉽다. |
| `author_invalid_output` | `author` 답이 schema 에 맞지 않았다. |
| `author_input_refused` | provider 가 입력이 크다고 거절했고, 줄일 것이 더 없었다. |
| `author_outcome_unknown` | 호출이 갔는지 알 수 없다. |
| `author_request_exceeds_frame` | 기록 하나만으로도 요청이 패키지 frame 을 넘었다. |
| `result_exceeds_frame` | `author` 답이나 질문의 답이 frame 을 넘었다. |
| `no_question_passed` | 돌아온 문제가 모두 확인을 통과하지 못했다. |

`author_outcome_unknown` 은 최종 결과다. 패키지는 같은 요청을 다시 내지 않는다. 같은 `request_id` 로 다시 시도하면 host 가 이미 가진 결과를 다시 줄 뿐이다. 다음 `compose` 가 새 세션과 새 `request_id` 로 다시 시도한다.

입력이 크다고 거절되면 패키지는 먼저 아직 못 맞힌 문제만 풀이 기록으로 보낸다(`history_scope = open_debt_only`). 그래도 크면 자료를 새것 절반으로 줄이고, 거절될 때마다 다시 반으로 줄인다. 빠진 오래된 절반은 이 세션에서 묻지 않는다. 요청이 frame 보다 클 때도 같은 방식으로 줄인다.

## 백업과 volume

정답, 풀이 기록, 판정은 설치 volume 의 `/state/operator-quiz/log.jsonl` 에만 있다. volume 을 잃으면 함께 사라진다. host 에 남는 기록(질문, 답, 보관한 페이지, exact 결과)으로는 정답을 다시 만들 수 없다.

`export` action 은 로그 전체를 host Lane store 에 artifact 로 보관하고 그 SHA-256 을 돌려준다. 주기적으로 받으려면 `{"installation_id": "operator-quiz", "action": {"kind": "export"}}` Schedule 을 따로 만든다. 기본으로 만들어지는 Schedule 은 없다. 내보낸 로그로 패키지를 되살리는 기능은 아직 없다.

## 지금의 한계

- 기록 종류는 Board 글·댓글과 `repository` 권한의 파일이다. wiki, PR, 커밋 인용은 다음 단계다.
- 서술형 문제와 채점, 이의 제기(`dispute`)는 다음 단계다.
- 관측 출력은 쌓인 모든 행을 담는다. 문제가 아주 많이 쌓여 `max_reply_bytes` 를 넘으면 관측이 실패로 보인다.
