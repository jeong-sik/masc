# 운영자 수업

운영자 수업(`operator-lesson`)은 이 워크스페이스의 Board 글, 커밋, wiki, merge 된 PR 을 읽고 짧은 수업 장면을 쓰는 Lane Add-on 패키지다. 장면은 Results 에 나온다. 문단마다 근거 기록의 글을 그대로 인용한다. 인용문이 그 기록에 없으면 그 장면은 버린다.

설계와 근거는 [운영자 수업 RFC](../rfc/RFC-operator-lesson-lane.md)에 있다. 이 문서는 켜고, 시간을 정하고, 결과를 읽는 방법만 다룬다.

## 한 번의 수업

1. Schedule 이나 운영자가 `compose` action 을 보낸다. 장면 수를 같이 적는다.
2. 패키지가 권한마다 새 기록을 읽는다.
3. `outline` 출력이 장면마다 제목, 요점, 인용할 기록을 정한다. 읽지 않은 기록을 가리킨 항목은 버린다.
4. `scene` 출력이 항목마다 장면 하나를 쓴다. 그 항목이 가리킨 기록만 받는다.
5. 패키지가 문단마다 인용문을 기록과 맞춰 본다. 통과한 장면이 Results 에 나온다.

운영자에게 묻는 것은 없다. Approvals 에 아무것도 생기지 않는다.

## 켜기

### 1. 이미지 만들기

```sh
docker build -f addons/operator-lesson/Dockerfile -t masc-lane-operator-lesson:0.1.0 addons
```

설치 조정(reconcile)은 이미지를 만들지 않는다. MASC 가 쓰는 엔진에 먼저 올려 둔다.

### 2. 설치 선언

[`docs/examples/lane-addons/operator-lesson.toml`](../examples/lane-addons/operator-lesson.toml)을 `lane-addons/` 아래로 복사하고 `manifest_path` 를 맞춘다.

```toml
[binding]
sources = []
language = "ko"
since = 1794441600

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

- `language`: 장면을 쓰는 언어다.
- `since`: Unix 시각(초)이다. 첫 수업은 이 시각부터 만든 기록을 읽는다. 꼭 적는다. 기본값이 없다. `date -u -j -f "%Y-%m-%d" 2026-11-12 +%s`(macOS)나 `date -u -d 2026-11-12 +%s`(Linux)로 얻는다.
- 다음 수업부터는 `since` 를 쓰지 않는다. outline 까지 간 마지막 수업이 멈춘 자리부터 읽는다.
- `records`: 읽을 기록이다. 운영자가 쓴 TOML 선언만 기록 권한을 가질 수 있다. 권한의 종류와 규칙은 [운영자 퀴즈](operator-quiz.md)의 "설치 선언"과 같다. wiki 와 `github_pulls` 권한도 같은 모양으로 더한다.
- `visibilities` 에 적은 공개 범위의 글은 `outline` 과 `scene` 출력에 묶인 slot 의 provider 에게 간다. `internal` 을 넣거나 `direct` 를 적기 전에, 그 provider 가 그런 글을 받아도 되는지 확인한다.
- `sources` 는 늘 빈 배열이다. 이 패키지는 관측 source 를 읽지 않는다.

### 3. `outline` 과 `scene` slot 묶기

`runtime.toml` 에 설치 선언 id 로 출력마다 표를 둔다. 표의 키와 규칙은 [Lane Add-on TOML](lane-addon-toml.md)의 "패키지가 선언하는 exact output" 과 같다.

```toml
[runtime.addon_exact_lanes.operator-lesson.outline]
slots = ["glm-coding.glm-5-3"]
max_output_tokens = 4096

[runtime.addon_exact_lanes.operator-lesson.scene]
slots = ["glm-coding.glm-5-3"]
max_output_tokens = 4096
```

- `outline` 표가 없으면 outline 요청이 `lane_unconfigured` 로 기다린다. 다음 `compose` 가 그 세션을 대체한다.
- `scene` 표가 없으면 장면 요청이 같은 이유로 기다린다. 그 세션은 `writing` 으로 남고, 다음 `compose` 가 대체하지 않는다. 표를 묶으면 밀린 장면이 쓰인다.
- 모델 호출은 수업 하나에 장면 수 + 1 번이다.

### 4. 시간 정하기

`masc_schedule_create` 로 Lane action Schedule 을 만든다.

```json
{"installation_id": "operator-lesson",
 "action": {"kind": "compose", "scenes": 3},
 "recurrence_kind": "daily", "recurrence_hour": 8, "recurrence_minute": 0,
 "recurrence_timezone": "Asia/Seoul"}
```

- `scenes` 는 꼭 적는다. 패키지에는 기본 장면 수가 없다.
- 바로 한 번 쓰려면 Lane Add-on 화면의 action 메뉴에서 `compose` 를 고른다.
- 기본으로 만들어지는 Schedule 은 없다.

## 결과 읽기

| lane | 행 하나 | 보는 것 |
| --- | --- | --- |
| `lesson/scenes` | 가장 최근 수업의 장면 | 본문, 출처(pin, 인용문, 보존된 페이지의 SHA-256) |
| `lesson/sessions` | `compose` 하나 | 상태, 장면 수(요청·outline·씀·거절·대기), 버린 항목과 장면의 이유, 실패 이유 |
| `lesson/measures` | 하나 | 상태별 세션 수, 쓴 장면 수, 장면이 나온 세션(`shown_session`), 이유별 거절 수 |

`lesson/scenes` 에는 가장 최근에 장면을 쓴 수업 하나만 나온다. 새 수업의 첫 장면이 쓰이면 지난 수업의 장면은 Results 에서 사라진다. 지난 수업은 `export` 한 log 에 있다.

세션 상태는 다섯이다.

| 상태 | 뜻 |
| --- | --- |
| `reading` | 기록을 읽거나 outline 을 기다린다 |
| `writing` | outline 이 끝났고 장면을 기다린다 |
| `written` | 모든 항목이 쓰였거나 거절됐다. 장면이 0 개여도 `written` 이다 |
| `failed` | outline 전에 끝났다. `failure` 에 이유가 있다 |
| `superseded` | `reading` 중에 다음 `compose` 가 왔다 |

자주 보는 이유:

- `no_material`: 읽을 새 기록이 없었다. `since` 뒤로, 또는 지난 수업 뒤로 기록이 없다. Board 글이 `internal` 인데 `visibilities` 에 없을 때도 이렇다.
- `quote_not_in_record`: 장면이 기록에 없는 글을 인용했다. `lesson/measures` 에서 이 수가 많으면 `scene` 에 묶은 모델이 인용을 지어낸다.
- `source_not_read`: outline 이 읽지 않은 기록을 가리켰다.
- `not_allowed`: host 가 요청을 거절했다. 설치 선언의 `exact_outputs` 가 그 출력을 고르지 않았거나 기록 권한이 없다.
- `outcome_unknown`: 모델 호출의 결과를 알 수 없다. 그 장면은 다시 요청하지 않는다. 다음 `compose` 가 새 수업을 쓴다.

거절된 장면은 다시 쓰지 않는다. 수업은 시간이나 횟수로 끝나지 않는다.

## 기록 보관

장면과 거절 이유는 설치 volume 의 `/state/operator-lesson/log.jsonl` 에만 있다. volume 을 잃으면 함께 사라진다. host 에는 읽은 페이지와 exact 요청·결과가 남는다.

`export` action 은 log 전체를 host Lane store 에 artifact 로 보관하고 그 SHA-256 을 돌려준다.

```json
{"installation_id": "operator-lesson", "action": {"kind": "export"}}
```

## 하지 않는 것

- 운영자에게 묻지 않는다. 읽었는지 받지 않는다.
- Keeper 를 부르지 않고, Keeper 의 일을 막지 않는다.
- 퀴즈와 이어져 있지 않다. 수업이 다룬 기록에서 퀴즈를 내는 일은 따로 설계한다(RFC §10).
