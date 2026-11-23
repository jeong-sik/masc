# 운영자 퀴즈

운영자 퀴즈(`operator-quiz`)는 이 워크스페이스의 Board 글과 changelog 조각을 읽고, 운영자에게 선택형 문제와 서술형 문제를 내는 Lane Add-on 패키지다. 문제는 Approvals 에 나온다. 선택지로 고른 답은 바로 채점되고, 글로 쓴 답은 `grade` 출력이 채점한다. 틀린 문제는 다음 날 이후에 다시 나올 수 있다.

설계와 근거는 [운영자 퀴즈 RFC](../rfc/RFC-operator-quiz-lane.md)에 있다. 이 문서는 켜고, 시간을 정하고, 결과를 읽는 방법만 다룬다.

## 한 번의 퀴즈가 지나가는 길

1. Schedule 이 정한 시각에 `compose` 를 보낸다. 패키지는 세션을 하나 열고 `confirmed` 로 답한다.
2. 패키지가 host 에게 기록을 한 번에 하나씩 요청한다. 지난번에 질문까지 간 세션이 멈춘 자리부터 읽는다. 질문까지 가지 못하고 실패했거나 다음 세션으로 대체된 세션이 읽은 기록은 다시 읽는다.
3. 다 읽으면 `author` 출력을 한 번 요청한다. 읽은 기록, 지난 문제들의 풀이 기록, 문제 수, 언어를 함께 보낸다. 새 기록이 없어도 지난 문제가 있으면 요청한다. 이때 `author` 는 지난 문제를 그 출처 그대로 다시 낼 수 있다.
   - 요청 하나에 다 들어가지 않으면 가장 최근에 읽은 기록만 담는다. 그래서 worker 는 읽는 동안 결과의 요약(상태, cursor, 커밋과 경로)만 메모리에 두고, 본문은 이때 보관한 페이지에서 최근 것부터 요청에 들어가는 만큼만 다시 읽는다. 퀴즈를 오래 꺼 두었다가 다시 켜도 worker 메모리는 요청 하나 크기 근처에 머문다.
4. 돌아온 문제마다 확인한다. 선택형 문제는 선택지가 둘 이상인지, 정답 선택지가 선택지 안에 있는지, `single` 이 정답을 하나만 갖는지 본다. 서술형 문제(`text`)는 선택지와 정답 key 없이, 맞는 답이 말해야 할 점(rubric)을 갖는지 본다. 어느 쪽이든 인용문이 그 기록의 보관된 바이트에 글자 그대로 있는지 본다. 통과하지 못한 문제는 이유와 함께 버린다. 하나도 통과하지 못하면 세션은 `no_question_passed` 로 끝난다.
5. 통과한 문제와 정답을 로그에 먼저 쓴다. 그다음에 정답과 출처를 뺀 질문을 Approvals 에 낸다.
6. 운영자가 답하면 선택지로 바로 채점하고, Results 에 공개(reveal) 행이 생긴다.

## 켜기

### 1. 이미지 만들기

```sh
docker build -f addons/operator-quiz/Dockerfile -t masc-lane-operator-quiz:0.2.2 addons
```

설치 조정(reconcile)은 이미지를 만들지 않는다. MASC 가 쓰는 엔진에 먼저 올려 둔다.

### 2. 설치 선언

[`docs/examples/lane-addons/operator-quiz.toml`](../examples/lane-addons/operator-quiz.toml)을 `lane-addons/` 아래로 복사하고 `manifest_path` 를 맞춘다.

```toml
[binding]
language = "ko"
timezone = "Asia/Seoul"
sources = []

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
- `repository` 권한의 커밋 메시지도 문제 재료가 된다. `paths` 에는 `changelog.d/` 말고도 `CHANGELOG.md`, `docs/rfc/` 처럼 읽힐 파일이나 폴더를 더 적을 수 있다.
- `sources` 는 수업을 묶지 않으면 빈 배열이다. 수업을 묶는 법은 아래 「수업 뒤에 묻기」에 있다.

wiki 와 merge 된 PR 도 읽게 하려면 권한을 더한다.

```toml
[[binding.records]]
source_id = "wiki"
kind = "wiki"

[[binding.records]]
source_id = "masc-prs"
kind = "github_pulls"
repository_id = "masc"
```

- `wiki` 는 page 마다 지금 본문을 읽는다. 인용 pin 은 `이름@revision` 이다.
- `github_pulls` 는 기본 브랜치 커밋을 merge 한 PR 과 그 리뷰, 리뷰 댓글을 GitHub 에서 읽는다. `[repositories] pr_reader` 가 GitHub 을 읽을 수 없으면 그 읽기는 `source_unavailable` 로 기다리고, 세션도 함께 기다린다.
- 인용 pin 은 기록 종류마다 모양이 정해져 있다: 커밋은 40자(또는 64자) SHA, PR 은 `번호@merge 커밋`, 리뷰는 `번호/r리뷰id`, 리뷰 댓글은 `번호/c댓글id`. 모양이 다른 pin 은 log 에 쓰지 않는다.

### 3. `author` 와 `grade` slot 묶기

`runtime.toml` 에 설치 선언 id 로 출력마다 표를 둔다. 표의 키와 규칙은 [Lane Add-on TOML](lane-addon-toml.md)의 "패키지가 선언하는 exact output" 과 같다.

```toml
[runtime.addon_exact_lanes.operator-quiz.author]
slots = ["glm-coding.glm-5-3"]
max_output_tokens = 8192

[runtime.addon_exact_lanes.operator-quiz.grade]
slots = ["glm-coding.glm-5-3"]
max_output_tokens = 2048
```

- `author` 표가 없으면 `author` 요청은 `lane_unconfigured` 로 기다린다. 다음 `compose` 가 그 세션을 대체한다.
- `grade` 표가 없으면 직접 쓴 답의 채점 요청이 같은 이유로 기다린다. 답은 그동안 `awaiting_judgment` 로 보인다. 선택지로 고른 답은 `grade` 없이 채점된다.

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

## 설치본 갱신과 출제 복구

저장소 소스가 바뀌어도 실행 중인 설치 패키지는 자동으로 바뀌지 않는다. 패키지의
`revision` 과 설치 경로, 실제 worker 원본을 함께 확인한다. 현재 패키지는 `0.6.2` 이고,
이미지 `0.2.2` 는 Python 과 공용 모듈 둘(`protocol.py`, `records.py`)을 담는 실행 환경이다. worker 코드는
설치한 패키지 폴더를 `/addon` 에 읽기 전용으로 붙여 실행한다. `0.3.0` 은 관측 row 에
`quiz/scorecard` 와 `quiz/review` 를 더했을 뿐 `log.jsonl` 의 모양은 그대로라, 아래
갱신 절차대로 올려도 log 를 옮기지 않는다. `0.3.1` 은 Results 에 보이는 값의 선언만
늘렸고, `0.3.2` 는 그 선언의 순서를 바꿔 Results 가 `quiz/scorecard` 부터 열리게 했다.
둘 다 row 와 log 는 그대로다. `0.3.3` 은 action 을 `kind` 별 갈래로 나누고, 이의를 걸 수
있는 질문 row 에 `dispute` 칸을 더해 Results 에서 바로 이의를 걸게 했다. log 는 그대로다.
`0.4.0` 은 기록 읽기와 log 파일 코드를 공용 모듈 `records.py` 로
옮겼다. row 와 log 는 그대로지만 이미지 `0.2.0` 이 있어야 뜬다. 이미지 `0.1.0` 에는
`records.py` 가 없어 worker 가 시작하지 못한다. 이미지를 먼저 만들고 설치본을 갱신한다.
`0.5.0` 은 수업 출력을 묶을 수 있게 했다(「수업 뒤에 묻기」). log 에 새 사건이 생기지만
`0.4.0` 이 쓴 log 는 그대로 읽힌다. 이미지는 `0.2.0` 그대로다. 수업을 묶은 뒤 `0.4.0` 으로
되돌리면 새 사건이 든 log 를 읽지 못한다.
`0.6.0` 은 수업을 묶은 선언에 `since` 를 받는다(「수업 뒤에 묻기」). 수업을 묶은 선언은
`since` 없이 저장되지 않고, 묶지 않은 선언은 `since` 를 받지 않는다. 바뀐 `records.py` 가
이미지 `0.2.1` 에 있어서 이미지를 먼저 만든다. 묶지 않은 설치의 log 는 그대로 읽힌다.
`0.5.0` 이 수업을 묶은 세션에 적은 `follows_lesson` 줄에는 `since` 가 없다. 그 줄이 하나라도
있으면 log 전체를 읽지 못한다. 그런 log 는 「정답 모양이 바뀐 revision 으로 올릴 때」처럼 옮겨 두고 빈 log 로 시작한다.
`0.6.1` 은 host 가 준 읽기 결과를 저장하기 전에 읽는다. 패키지가 읽는 칸이 빠진 결과는
거절하고, worker 는 같은 읽기를 다시 요청한다. row 와 log 는 그대로다. 바뀐 `records.py` 를
담은 이미지 `0.2.2` 가 있어야 뜬다. 이미지 `0.2.1` 의 `records.py` 로는 worker 가 시작하지 못한다.
`0.6.2` 는 manifest 의 `[world]` 에 Exact 규약 판 `exact_protocol = 1` 을 적는다. 판을 아는 서버는
판이 없거나 다른 패키지를 거절하고, 판을 모르는 서버는 `0.6.2` 를 거절한다. 서버를 멈추고 선언을
`0.6.2` 로 바꾼 뒤 새 서버를 띄운다. row 와 log, 이미지 `0.2.2` 는 그대로다.

1. 원본 로그와 요청 blob, 설치 선언 및 현재 instance/volume 식별자를 보관한다.
2. 검증한 패키지를 새 불변 경로에 설치한다. 실행 중인 패키지 폴더를 덮어쓰지 않는다.
3. `masc_lane_declaration_read` 의 revision으로 선언을 저장해 새 manifest 경로를 가리킨다.
   설치 `id`, `run_id`, package `id`, 기록 권한과 모델 바인딩은 유지한다. 같은 설치의
   영속 volume은 그대로 사용되며, 새 instance가 연결됐는지 확인한다.
4. 이력 조회와 호스트 요청 상태를 확인한다. `history_scope` 는 author 요청과 함께
   기록한 domain event에서 읽는다. 그 event가 없는 세션은 `null`(미기록)이고, 과거
   요청의 전송 형식을 다시 해석해 추정하지 않는다. 질문·답변·복습 이력은 그대로다.
5. 보관된 author 요청이 현재 호스트 형식에 맞지 않아 출제가 막혔다면, 새 request id로
   `compose` 를 한 번 보낸다. 기존 `writing` 세션만 `superseded` 로 남고 새 세션이
   시작된다. 열린 질문과 답한 세션은 이 동작으로 지워지지 않는다. 로그나 blob을
   고쳐 쓰거나 잘못된 전송 형식을 호스트에서 허용하지 않는다.
6. action의 `confirmed` 는 시작 영수증이다. 새 세션의 실제 출제 수와 Approvals의 질문,
   인용 근거까지 읽은 뒤에 출제 복구로 판단한다. 일일 Schedule은 별도로 유지한다.

새 domain event가 기록된 volume에는 그 event를 읽을 수 있는 패키지를 사용한다.
이전 reader를 다시 지정하는 것은 복구 절차가 아니다.

## 수업 뒤에 묻기

[운영자 수업](operator-lesson.md)을 같이 쓰면, 퀴즈가 수업에 나온 기록에서만 새 문항을 내게 할 수 있다. 묶지 않으면 퀴즈는 지금까지처럼 읽은 기록 전체에서 낸다.

퀴즈 설치 선언의 `[binding]` 에서 `sources = []` 를 지우고, 그 자리에 수업 선언의 `since` 와 수업 설치의 `scenes` 출력을 넣는다.

```toml
since = 1794441600

[[binding.sources]]
source_id = "lesson"
kind = "lane_output"
installation_id = "operator-lesson"
output_id = "scenes"
selection = "latest_completed"
```

`since`, `language`, `timezone` 은 `[[binding.sources]]` 보다 위에 둔다. 아래에 두면 TOML 이 그 줄을 source 항목의 키로 읽어 선언이 저장되지 않는다.

host 는 선언을 저장하기 전에 `[binding]` 을 아래 순서로 본다. 걸리면 저장하지 않고, 처음 걸린 문구 하나만 낸다.

| 순서 | host 가 보는 것 | 걸리는 예 | 문구 |
| --- | --- | --- | --- |
| 1 | 파일이 TOML 로 읽히는가 | `sources = []` 를 지우지 않고 바로 아래에 `[[binding.sources]]` 를 더했다 | `table [binding.sources] is duplicated by an array of tables [[binding.sources]]` |
| 2 | 값을 JSON 으로 옮길 수 있는가 | `since = 2026-11-12` | `binding.since: TOML date/time values are unsupported; use an explicit string` |
| 2 | | `since = nan`, `since = inf` | `binding.since: non-finite numbers are not supported` |
| 3 | `sources` 항목의 모양 | `since`·`language`·`timezone` 이 `[[binding.sources]]` 아래에 있다 | `lane_output contains duplicate or unknown fields` |
| 3 | | `selection` 이 없다 | `lane_output selection must be latest_completed` |
| 3 | | `sources` 가 없거나 배열이 아니다 | `binding.sources requires an array of observation sources` |
| 4 | `records` 항목의 모양 | Board 항목에 `visibilities` 가 없다 | `binding.records: visibilities requires a non-empty array` |
| 4 | | `wiki` 항목에 `paths` 가 있다 | `binding.records: a record grant has no key paths` |
| 4 | | 두 항목의 `source_id` 가 같다 | `binding.records: records names the same source_id twice` |
| 5 | `[binding]` 이 패키지의 스키마에 맞는가 | 아래 목록 | `lane binding must match exactly one schema alternative` |

1 번 문구는 TOML 을 읽는 라이브러리(Otoml)가 낸다. 같은 실수라도 줄의 자리에 따라 문구가 다르다. `[[binding.sources]]` 를 `[[binding.records]]` 둘 뒤에 더하면 `otoml internal error` 로 시작하는 문구가 나온다.

5 번 문구는 어느 칸이 틀렸는지 말하지 않는다(#52319). 이럴 때 나온다.

- `since` 가 없다. 문자열이다. 0 보다 작다.
- 수업을 묶지 않은 선언에 `since` 가 있다.
- `timezone` 이 없다. 패키지가 읽지 않는 키가 있다. `output_id` 가 `scenes` 가 아니다.

`since` 는 Unix 시각(초)을 숫자로 적는다. 2 번 문구는 문자열로 적으라고 하지만, 문자열로 적은 `since` 는 5 번에서 걸린다.

`records` 항목은 스키마보다 먼저 host 가 4 번에서 본다(#52373). 종류에 맞는 칸이 다 있는지, 그 종류에 없는 칸이 섞이지 않았는지, `source_id` 가 겹치지 않는지, `paths` 가 저장소 안을 가리키는지다. `records` 가 없거나 빈 배열이면 5 번에서 걸린다. 돌던 퀴즈의 선언 파일을 직접 고쳐 4 번에 걸리면 고친 선언은 반영되지 않는다. 거절 이유는 `configuration.issues` 에 선언 파일 경로와 함께 나온다. 돌던 worker 는 내려가지 않는다. 그 대신 파일을 고칠 때까지 운영자 호출·예약 실행·Detach 가 거절된다.

맞춰야 하는 것이 넷이다.

- 퀴즈 선언의 `since` 를 수업 선언과 같게 둔다. `since` 를 빼면 선언이 저장되지 않는다. 수업을 묶지 않은 선언에 `since` 를 적어도 저장되지 않는다. 퀴즈가 읽기 시작하는 곳은 `records` 의 항목마다 따로 정해진다.

  | 그 항목에 | 읽기 시작하는 곳 |
  | --- | --- |
  | 질문을 낸 세션이 멈춘 자리(cursor)가 남아 있다 | 그 자리 |
  | 남은 자리가 없다 | `since` |

  남은 자리가 없는 항목은 셋이다.

  - 질문을 낸 세션이 읽은 적 없는 항목. 질문을 낸 적 없는 퀴즈는 모든 항목이 그렇다. 나중에 새 `source_id` 로 더한 항목도 그렇다.
  - `since` 부터 읽었는데 기록이 하나도 없던 항목. 다음 세션이 다시 `since` 부터 읽는다. `github_pulls` 항목은 다를 수 있다. 그 사이에 PR 의 병합 커밋이 아닌 커밋(브랜치에 바로 올린 커밋, rebase 병합의 앞쪽 커밋)이 있으면 host 가 그 커밋을 지나친 자리를 준다. 그 세션이 질문을 냈으면 다음 세션은 그 자리부터 읽는다.
  - 남은 자리를 host 가 모두 거절한 항목. 저장소·`github_pulls` 항목은 그 커밋이 기본 브랜치에 더는 없을 때, wiki 항목은 `log.md` 가 다시 쓰여 그 자리의 줄이 달라졌을 때 거절된다. Board 항목은 모양이 맞는 자리면 지운 글의 자리도 받는다. 거절당한 세션은 실패로 끝나고, 다음 세션은 그보다 앞서 남은 자리부터 읽는다. 그런 자리도 없으면 `since` 부터 읽는다.

  자리는 `source_id` 로 찾는다. 뺐다가 같은 `source_id` 로 다시 더한 항목은 전에 멈춘 자리부터 읽는다. 다만 뺄 때 그 항목을 다 읽지 않은 세션은 그 항목을 읽으려다 host 에게 거절당하고 실패한다(#52372). 그 항목을 이미 다 읽은 세션은 다시 읽지 않으므로 실패하지 않는다. 실패한 세션의 읽기가 앞 세션이 멈춘 자리를 물었으면, 다시 더한 항목은 그보다 앞서 남은 자리나 `since` 부터 읽는다. 그렇게 읽은 세션이 질문을 내면 다음 세션은 그 세션이 멈춘 자리부터 읽는다. 거절된 자리와 같은 자리에서 멈췄어도 그렇다(#52417). 저장소 항목에서 거절된 것이 파일 읽기면 세션은 실패하지 않는다. 지운 파일처럼 건너뛰어 커밋 기록만으로 묻고, 그 파일은 다시 읽지 않는다.

  쓰던 `source_id` 를 다른 기록에 다시 쓰지 않는다. 새 기록이 옛 자리를 이어받는다. host 가 그 자리를 받으면 새 기록은 그 자리 뒤부터 읽혀, `since` 부터는 읽지 않는다. host 가 거절하면 거절할 때마다 세션이 하나씩 실패한다.

  질문을 낸 적 없는 퀴즈는 첫 수업과 같은 시각부터 읽으므로, 수업이 인용한 기록을 퀴즈도 읽는다. 다만 수업이 인용한 뒤 퀴즈가 읽기 전에 wiki 페이지를 고치면, 퀴즈는 그 페이지를 새 revision 으로 읽는다. 인용 pin 은 revision 까지 같아야 맞으므로, 그 페이지로는 새 문항이 나오지 않는다. 이미 질문을 낸 퀴즈에 수업을 묶으면 퀴즈는 전에 멈춘 자리부터 읽는다. 수업이 그 자리보다 앞선 기록을 인용해도 퀴즈는 그 기록을 읽지 않는다.
- 두 설치 선언의 `run_id` 가 같아야 한다. 다르면 퀴즈는 수업 출력을 받지 못하고, `quiz/measures` 의 `lesson.source.detail` 에 `upstream installation belongs to another run` 이 나온다. `run_id` 를 바꿔 저장하면 worker 는 다시 뜨지만 volume 과 log 는 그대로다.
- 두 선언이 같은 기록에 같은 `source_id` 를 써야 한다. 수업이 `board` 라고 부른 기록을 퀴즈가 `notes` 라고 부르면 같은 글이어도 맞지 않는다.
- 퀴즈 Schedule 을 수업 Schedule 바로 뒤에 둔다. 이유는 아래 표에 있다.

묶은 뒤에 달라지는 것:

- 수업이 장면을 쓸 때마다 퀴즈가 그 장면이 인용한 기록의 pin 을 log 에 적는다. 인용문이나 본문은 적지 않는다.
- 새 문항의 자료는 퀴즈가 이번에 읽은 기록 가운데 수업이 인용한 것뿐이다. 다시 묻는 문항은 그대로다.
- 수업이 인용한 기록이 이번에 읽은 것 가운데 없으면 새 문항이 없다. 다시 물을 문항도 없으면 세션은 `no_material` 로 끝나고, 다음 퀴즈가 같은 기록을 다시 읽는다.
- 문항 행(`quiz/questions`, `quiz/review`)에 `taught` 가 붙는다. 그 문항을 내기 전에 수업이 그 문항의 출처를 인용했으면 참이다.

퀴즈가 묻지 못하는 기록이 생긴다. 수업이 매일 09:00, 퀴즈가 매일 18:00 이면 이렇게 된다.

| 기록이 생긴 때 | 월요일 수업 | 월요일 퀴즈 | 결과 |
| --- | --- | --- | --- |
| 일 18:00 ~ 월 09:00 | 인용할 수 있다 | 읽는다 | 물을 수 있다 |
| 월 09:00 ~ 월 18:00 | 아직 못 봤다 | 읽는다 | 묻지 못한다. 화요일 수업이 인용해도 퀴즈는 이미 지나갔다 |

퀴즈를 수업 직후에 두면 빠지는 구간이 그 사이 시간으로 줄어든다.

`quiz/measures` 의 `lesson` 에서 보는 값:

| 값 | 뜻 |
| --- | --- |
| `scenes_seen`, `cites_seen` | 퀴즈가 받은 장면과 인용된 기록의 수 |
| `cites_unmatched` | 인용됐지만 어떤 출제 요청에도 실리지 않은 기록의 수. 위 표의 빠진 구간이 여기에 든다 |
| `unreadable` | 퀴즈가 읽지 못한 수업 출력의 수. 한 행이라도 모양이 틀리면 그 출력 전체를 받지 않는다 |
| `source` | 마지막 관측 때 host 가 수업 출력에 대해 말한 것 |
| `first_attempt` | 항목마다 처음 채점된 시도를 `taught` 와 나머지로 나눈 정답 수 |

`first_attempt` 로 "수업을 읽으면 더 잘 맞힌다"고 말할 수는 없다. 묶은 뒤의 새 문항은 모두 `taught` 라서, 나머지는 묶기 전 문항이다. 시기와 주제가 다르다.

수업 출력은 최근 수업의 장면만 담는다([운영자 수업](operator-lesson.md) 「결과 읽기」). 퀴즈가 꺼져 있는 동안 지나간 수업은 받지 못한다.

## 매일 쓰기

- 시간 바꾸기: `masc_schedule_update`.
- 멈추기: Schedule 을 취소하거나 선언을 `enabled = false` 로 둔다. 선언을 끄면 worker 는 내려가고 volume 은 남는다. 열린 질문은 Approvals 에 그대로 있고, 다음 worker 가 답을 받는다.
- 답하지 않은 질문: 기한도 개수 제한도 없다. `compose` 마다 질문이 하나씩 늘어난다. 아직 질문을 내지 않은 세션만 다음 `compose` 가 대체한다.
- 두 개 돌리기: 다른 선언 id 로 두 번 설치한다. volume, lane, Schedule 이 따로 생긴다.

## 결과 읽기

Results 에 일곱 lane 이 나온다.

| lane | 한 행 | 보는 것 |
|---|---|---|
| `quiz/scorecard` | 창 하나(마지막 응답 날·최근 7일·30일·전체) | 창 안의 채점된 답 수, 맞음·틀림·건너뜀, 점수, 창 기준일, 놓친 주제 상위 |
| `quiz/review` | 아직 못 맞힌 복습 항목 하나 | 마지막으로 낸 문제와 내 답, 정답, 판정 기록, 출처 |
| `quiz/measures` | 하나 | R, P, G, 점수, 버린 문제 수, 실패한 세션 수(이유별) |
| `quiz/sessions` | `compose` 하나 | 상태, 맞음·틀림·건너뜀·채점 대기·열림 수, 실패 이유 |
| `quiz/questions` | 답한 문제 하나 | 내 답, 정답(선택형은 `choices`, 서술형은 `rubric`), 판정과 판정한 쪽(`key` 또는 `judgment`), 판정 기록, 채점 상태, 출처의 인용문과 hash |
| `quiz/topics` | 주제 하나 | 문제 수, 풀이 수, 놓친 수, 아직 못 맞힌 문제와 그 출처 |
| `quiz/items` | 복습 항목 하나 | 풀이 기록, 마지막 판정, 연속으로 맞힌 횟수 |

- 답하기 전의 문제는 `quiz/questions` 에 행이 없다. 정답이 먼저 보이는 일은 없다.
- `quiz/scorecard` 의 창은 마지막으로 답한 날(운영자 시간대)에 붙어 있다. 같은 로그에서 관측을 다시 하면 같은 행이 나온다. 답이 하나도 없으면 이 lane 들은 행을 내지 않는다.
- `quiz/review` 는 마지막 풀이가 틀림이나 건너뜀인 항목만 낸다. 서술형 답이 채점을 기다리는 동안에는 이 행에 들어가지 않는다.
- 건너뛴 문제는 놓친 문제로 센다.
- 직접 쓴 답은 답이 들어올 때 `grade` 요청을 하나 만든다. 결과가 오기 전까지 `awaiting_judgment` 이고, `grading` 에 기다리는 요청이 보인다. 판정도 요청도 없는 직접 쓴 답(이 기능이 들어오기 전에 받은 답 등)은 다음 `compose` 때 요청한다.
- `grade` 가 판정할 수 없는 결과(형식이 틀린 출력, 입력이 크다는 거절, 호출 결과를 모름 등)로 끝나면 `grading` 에 그 실패가 남는다. 패키지는 그 실패에 바로 다시 요청하지 않고, 다음 `compose` 때 한 번 다시 요청한다.
- `void` 판정은 문제나 정답이 잘못됐다는 뜻이다. 그 문제는 풀이로 세지 않는다.
- 출처의 `sha256` 은 host 가 Lane store 에 보관한 바이트의 이름이다. 글이 나중에 고쳐지거나 changelog 조각이 릴리스에서 지워져도, 인용한 바이트를 그대로 확인할 수 있다.

### R, P, G

- **R(다시 물었을 때 맞힌 비율)**: 놓친 뒤 다른 날 다시 푼 적이 있는 복습 항목 수가 d 다. 그중 처음 다시 푼 날 맞힌 항목 수가 n 이다. 같은 날 다시 맞힌 것은 세지 않는다.
- **P(참여)**: 채점된 풀이 수를 낸 문제 수로 나눈 값이다.
- **G(판정이 바뀐 비율, `changed_grades`)**: 문제가 이미 가진 판정(정답 key 로 낸 것이나 앞선 판정)을 바꾼 판정 수를, 채점된 풀이 수로 나눈 값이다. 직접 쓴 답의 첫 판정은 바꾼 것이 아니어서 세지 않는다. RFC 의 목표는 1/20 이하이고, R 의 목표와 같은 지위다.
- 모두 n/d 로만 보인다. 통과·실패를 말하는 필드는 없고, 어떤 상태도 이 숫자로 바뀌지 않는다.
- RFC 의 목표는 30일 운영 뒤 d ≥ 20, n/d ≥ 2/3 이다. 비교할 기준 없이 정한 첫 제안이고, 첫 달을 본 뒤 다시 정한다. 판단은 운영자가 한다.

## 세션이 실패하는 이유

세션은 아래 이유 중 하나로만 실패한다. 이유는 `quiz/sessions` 행의 `failure` 에 있다.

| `kind` | 뜻 |
|---|---|
| `not_allowed` | host 가 규칙으로 요청을 거절했다(권한이 없는 기록, 선언하지 않은 출력, `[world.asks]` 없음). 질문을 낸 세션도 그 질문이 거절되면 여기서 끝난다. |
| `no_material` | 모든 권한을 읽었지만 새 기록이 없었고, 전에 낸 문제도 없었다. 아직 문제를 낸 세션이 없으면 퀴즈를 켠 뒤(첫 세션이 열린 뒤) 생긴 기록만 읽으므로, 켜자마자 보낸 `compose` 는 이렇게 끝나기 쉽다. 수업을 묶은 설치는 binding 의 `since` 부터 읽는다. 읽은 기록 가운데 수업이 인용한 것이 없고 전에 낸 문제도 없으면 이렇게 끝난다. |
| `author_invalid_output` | `author` 답이 schema 에 맞지 않았다. |
| `author_input_refused` | provider 가 입력이 크다고 거절했고, 줄일 것이 더 없었다. |
| `author_outcome_unknown` | 호출이 갔는지 알 수 없다. |
| `author_request_exceeds_frame` | 기록 하나만으로도 요청이 패키지 frame 을 넘었다. |
| `result_exceeds_frame` | `author` 답이나 질문의 답이 frame 을 넘었다. |
| `no_question_passed` | 돌아온 문제가 모두 확인을 통과하지 못했다. |

`author_outcome_unknown` 은 최종 결과다. 패키지는 같은 요청을 다시 내지 않는다. 같은 `request_id` 로 다시 시도하면 host 가 이미 가진 결과를 다시 줄 뿐이다. 다음 `compose` 가 새 세션과 새 `request_id` 로 다시 시도한다.

입력이 크다고 거절되면 패키지는 먼저 아직 못 맞힌 문제만 풀이 기록으로 보낸다(`history_scope = open_debt_only`). 그래도 크면 자료를 새것 절반으로 줄이고, 거절될 때마다 다시 반으로 줄인다. 빠진 오래된 절반은 이 세션에서 묻지 않는다. 요청이 frame 보다 클 때도 같은 방식으로 줄인다.

## 판정에 이의 제기하기

판정이 틀렸다고 보면 `dispute` action 을 보낸다. 선택지로 채점된 답도, `grade` 가 판정한 답도 낼 수 있다.

```json
{"kind": "dispute", "ask_id": "s-…-ask", "question_id": "q1", "note": "그 글은 계획도 기록한다고 적혀 있다"}
```

- 이의를 걸 수 있는 `quiz/questions` 행에는 `dispute` 칸이 있고, 그 안에 `ask_id` 와 `question_id` 가 있다. 그 질문의 `grade` 요청이 아직 결과를 기다리면 이 칸이 없다.
- Keeper 는 `masc_lane_act` 로 이 action 을 보낸다.
- 패키지는 `Disputed` 를 남기고 `grade` 요청을 하나 낸다. 이 요청에는 메모, 지금의 판정, 패키지가 읽어 둔 출처 원문이 들어간다.
- 결과는 새 `Judged` 다. 정답 key 로 낸 판정보다 앞서고, 판정 기록에 모두 남는다. 이미 있던 판정을 바꾸면 G 에 센다.
- 같은 action 을 다시 보내도 아무것도 쓰지 않고 같은 요청을 가리킨다. 그 질문에 아직 결과를 기다리는 `grade` 요청이 있거나, 답한 질문이 아니거나, 메모가 비어 있으면 `failed_before_effect` 로 거절한다.
- 판정이 최종 실패로 끝난 질문도 `dispute` 로 바로 다시 채점을 요청할 수 있다.

## 백업과 volume

정답, 풀이 기록, 판정은 설치 volume 의 `/state/operator-quiz/log.jsonl` 에만 있다. volume 을 잃으면 함께 사라진다. host 에 남는 기록(질문, 답, 보관한 페이지, exact 결과)으로는 정답을 다시 만들 수 없다.

`export` action 은 로그 전체를 host Lane store 에 artifact 로 보관하고 그 SHA-256 을 돌려준다. 주기적으로 받으려면 `{"installation_id": "operator-quiz", "action": {"kind": "export"}}` Schedule 을 따로 만든다. 기본으로 만들어지는 Schedule 은 없다. 내보낸 로그로 패키지를 되살리는 기능은 아직 없다.

### 정답 모양이 바뀐 revision 으로 올릴 때

서술형 문제가 들어오면서 `posed` 의 정답이 `{"kind": ...}` 객체로 기록된다. 그 전 package 가 쓴 `log.jsonl` 은 새 package 가 읽지 못한다. 읽지 못한 log 로는 답도 관측도 받지 않는다. 그래서 새 revision 을 설치하기 전에 log 를 옮겨 두고 빈 log 로 시작한다.

1. 남겨 둘 기록이 있으면 먼저 `export` action 으로 host Lane store 에 보관한다.
2. 설치 선언에 `enabled = false` 를 적고, 그 설치의 worker 가 detached 가 될 때까지 기다린다.
3. 설치 volume 안의 `/state/operator-quiz` 를 다른 이름으로 옮긴다. volume 이름은 마지막 worker 컨테이너(`GET /api/v1/lane-addons` 의 `container_id`)의 mount 에서 읽는다.

   ```sh
   docker inspect <container_id> --format '{{range .Mounts}}{{.Name}} {{end}}'
   docker run --rm -v <volume>:/state --entrypoint mv masc-lane-operator-quiz:0.2.2 /state/operator-quiz /state/operator-quiz-<날짜>
   ```

4. `manifest_path` 를 새 package 로 바꾸고 `enabled = false` 를 지운다.
5. 바로 `compose` 를 한 번 보낸다. 아직 문제를 낸 세션이 없으면 첫 세션이 열린 시각부터 기록을 읽는다. 그래서 이 세션은 `no_material` 로 끝나기 쉽지만, 다음 세션은 이 시각부터 쌓인 기록을 읽는다. 보내지 않으면 다음 정기 `compose` 가 첫 세션이 되어, 그 시각 전의 기록은 읽지 않는다. 수업을 묶은 설치는 첫 세션을 연 시각이 아니라 binding 의 `since` 부터 읽는다. `records` 의 항목마다, 질문을 낸 세션이 멈춘 자리를 남길 때까지 세션마다 그 시각부터 읽는다. 그래서 `since` 가 오래될수록 한 번에 읽는 기록이 많다.

- 옮긴 log 는 volume 안에 그대로 남는다. 새 package 는 그 파일을 읽지 않는다.
- 옮기기 전에 답한 문제의 풀이와 판정은 옮긴 log 에만 있다. 새 package 의 R, G, P 는 빈 log 에서 다시 센다.
- 옮기기 전에 열려 있던 질문은 Approvals 에 남는다. 질문은 그 질문을 낸 package 만 거둘 수 있는데, 새 package 는 그 질문을 모른다. 답해도 새 log 에 들어가지 않고 채점되지 않는다.

## 지금의 한계

- 관측 출력은 쌓인 모든 행을 담는다. 문제가 아주 많이 쌓여 `max_reply_bytes` 를 넘으면 관측이 실패로 보인다.
