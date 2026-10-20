# TOML로 Lane Add-on 설치하기

Web의 패키지 선택·필드 입력·초안 저장은 [Web 설치 안내](web-lane-addons.md)를 참고한다.

Lane Add-on은 패키지를 파일로 설치·변경·제거하는 경로다. 기존 MSX 머신,
Browser 세션, Keeper의 실행과 도구를 재사용한다. 패키지 하나가 여러 관측·관계 Lane을
제공할 수 있다. MCP는 worker와 통신하는 규약이며, 설치 단위의 의미는 패키지가 제공하는
관측과 관계다. 이 문서는 구현된 설치 계약을 설명한다. 자체 환경과 선택적 행동을 가진
패키지도 같은 경로로 연결하며, 실제 검증 범위는 [행동 계약](lane-world-actions.md#qualification-boundary)과
[출력 연결](lane-output-composition.md)의 고정 revision별 기록으로 구분한다.

## 설치 위치와 예제

서버는 기존 config resolver가 선택한 `<resolved-config-root>/lane-addons/*.toml`을 읽는다.
기존 `MASC_CONFIG_DIR` 설정이 우선하며, 기본 위치는 `<base-path>/.masc/config/lane-addons/`다.
저장소의 `config/`를 실행 중 설정으로 자동 사용하지 않는다. Dashboard의 **TOML configuration**에
실제로 읽는 디렉터리가 표시된다.

Dashboard의 **New TOML / Edit TOML**과 Keeper의 선언 편집 도구도 같은 파일을
읽고 저장한다. 원문 편집·충돌 확인·저장 영수증은
[공통 선언 편집 가이드](lane-declaration-editor.md)를 따른다.

[MSX 설치 예제](../examples/lane-addons/msx-frames.toml)는 현재 지원하는 형식이다.
다음 순서로 설치한다.

1. 기존 MSX Lane에서 관측할 머신을 준비한다. 이 선언은 머신을 생성하거나 게임 입력을 보내지 않는다.
2. [MSX 패키지 manifest](../../addons/msx-observer/lane.toml)가 가리키는 worker 이미지를 준비한다.
   이미지 구성은 [패키지 안내](../../addons/README.md)를 따른다. 설치 선언이 이미지를 빌드하지 않는다.
3. 예제를 활성 config root의 `lane-addons/` 바로 아래에 복사하고, `manifest_path`를 실제 패키지
   manifest의 절대 경로나 **설치한 선언 파일 기준** 상대 경로로 바꾼다. 예제의 상대 경로는 저장소 내
   예제 위치에서 유효하므로 복사 후 그대로 사용하지 않는다.
4. 다른 설치와 겹치지 않는 `id`와 관측 묶음의 `run_id`를 정하고 저장한다. Dashboard를 새로 읽어
   설정 적용 상태와 인스턴스의 관측 상태를 각각 확인한다.

설치 선언의 최상위 필드는 `id`, `run_id`, `manifest_path`, `[binding]` 네 가지다.
패키지의 `lane.toml`은 image·command·contributions·worker 자원 한도를 정의하는 별도 문서다.
설치 선언의 `id`는 유지할 설치의 식별자이며, 패키지 ID나 실행 인스턴스 ID와 구분한다.

`manifest_path`와 `binding.sources`의 `snapshot_file.path`는 선언 파일이 있는 디렉터리를 기준으로
해석한다. 그 밖의 package-specific binding 문자열을 파일 경로로 추측하거나 확장하지 않는다.
현재 source 종류는 `snapshot_file`, `msx_capture`, `browser_document`, `lane_output`, `fusion_run`이다.
`fusion_run`은 정확한 Fusion run ID의 현재 상태와 Board 근거를 호스트에서 캡처한다.
Fusion 상태 갱신 시 해당 run을 연결한 설치만 다시 관측한다. 모델 계산·인증·기존 전달 수명은 바꾸지 않는다.
결과는 발표 시점의 보존 캡처이며 Board 카드의 나중 편집을 자동 추적하지 않는다.
`lane_output`은 같은 run의 다른 설치가 완료한 출력을 읽는다. `browser_document`는 이미 열린
정확한 Browser 대상을 요구하며, 선언을 추가한다고 새 세션이나 탭을 만들지 않는다.
MSX 예제는 incarnation을 고정하지 않으므로 기존 머신의 load/restore를 구분해서 계속 관측한다.

## 실행기 선택

패키지 `lane.toml`에 `runtime = "apple_container"`를 선언하면 Apple `container`의 전용 microVM에서 실행한다. 생략하면 기존 Docker 실행을 유지한다. 이미지도 선택한 실행기의 저장소에 준비해야 한다. Docker에만 있는 이미지는 Apple 실행기가 읽을 수 없다.

```toml
runtime = "apple_container"
# 나머지 package 필드
[resources]
cpus = 1
memory_bytes = 268435456
max_reply_bytes = 16777216
```

Apple에서는 정수 vCPU와 정확한 MiB 단위 메모리를 사용하고 `pids`를 생략한다. Docker의 PID·swap·no-new-privileges 제한과 같은 보장이라고 표시하지 않는다. 두 실행기 모두 guest 네트워크를 닫고 root filesystem을 읽기 전용으로 연결하며 capability를 제거한다. Keeper의 작업 디스크·토큰을 Addon에 연결하지 않는다.

`world.state.mode = "persistent"`인 기존 설치의 runtime을 바꿀 때는 새 설치 ID를 사용한다. 서로 다른 실행기의 같은 이름 volume은 동일한 데이터가 아니다. 기존 설치의 runtime 전환을 거절하여 빈 상태로 교체되는 일을 막고, 과거 worker 정리는 저장된 원래 runtime으로 수행한다.

`runtime = "host_process"`는 설치한 MCP stdio 실행 파일을 호스트에서 실행한다.
`command`는 패키지 디렉터리에서 실행하며 `image`를 쓰지 않는다. `[resources]`에는
`max_reply_bytes`만 선언한다. 컨테이너 격리나 CPU·메모리·PID 한도를 제공하지 않는다.
`masc-native-addon-launcher`가 MASC 실행 파일 옆이나 PATH에 설치돼 있어야 한다.

호스트는 설치 ID별 private 실행 슬롯을 준비하고, 정리 권한을 기록한 뒤 실행한다.
해제 영수증은 원래 프로세스와 실행 그룹의 종료·슬롯 정리를 확인한 뒤 남긴다.
서버 재시작 후에도 같은 실행 기록으로 복구하며, 정리를 확인하기 전에는 새 실행을
겹치지 않는다. 현재 native 실행은 `ephemeral` 상태와 모델 호출 없는 패키지를 지원한다.
`persistent` 상태와 observation sampling은 해당 호스트 계약을 연결하기 전까지 거절한다.
브라우저 실행기의 Add-on 분리는 아직 구현 중이다.

## 도구 Hook 선택

패키지의 `[world.tools]`에 `hooks = ["validate_input", "validate_output"]`을
선언하면 도구 호출 전 입력과 호출 후 성공 응답을 각각 검증한다. 설치 TOML의
최상위 `tool_hooks` 배열로 그 설치만 덮어쓸 수 있다.

```toml
id = "checked-browser"
run_id = "browser-work"
manifest_path = "../packages/browser/lane.toml"
tool_hooks = ["validate_input", "validate_output"]

[binding]
sources = []
```

키를 생략하면 패키지 선택을 따르고, `tool_hooks = []`이면 두 선택 검사를 끈다.
각 Hook은 따로 선택할 수 있다. 입력 검사는 dispatch 전에 거절한다. 출력 검사는
성공 응답의 `structuredContent`를 해당 worker가 광고한 `outputSchema`와 비교한다.
응답이 잘못됐으면 이미 수행된 조작의 결과는 불확실하며 재전송하지 않는다.
실패 응답은 원래 실패·효과 metadata를 유지한다.

선택한 Hook의 스키마는 기존 Add-on 행동 계약의 닫힌 subset을 사용한다.
선택한 출력 검사가 있으면 **모든 export 도구**에 지원되는 `outputSchema`가 있어야
장착할 수 있다. 임의 JSON Schema 전체 지원을 뜻하지 않는다. Hook 변경은 설치
revision과 worker 교체에 반영된다. 이 선택은 LLM을 호출하거나 모델 route를 바꾸지
않는다. 브라우저 실행기와 모델 Hook의 분리 진행은
[설계](../design/browser-addon-lifecycle.md)와 [#44150](https://github.com/jeong-sik/masc/issues/44150)에서 추적한다.

## 반영 시점과 화면 읽기

서버 시작 시 한 번 읽고, 기존 maintenance cadence를 쓰는 독립 Pulse에서 다시 읽는다.
기본 간격은 60초이며 기존 `MASC_MAINTENANCE_PULSE_INTERVAL_SEC` 설정을 재사용한다.
소유한 worker의 정리가 끝나면 추가 재조정을 알린다. 파일 저장 즉시 실행되는 watcher나
Keeper 턴의 필수 선행조건은 없다. Dashboard의 Refresh는 현재 결과를 읽는 동작이다.
worker 시작이나 복구 의존성이 실패하면 기존 maintenance cadence에서 다시 시도하며,
실패 자체로 즉시 재시도 루프를 만들지 않는다.

| 표시 | 의미 |
|---|---|
| `desired_revision` | 읽기에 성공한 선언·해석된 패키지·binding의 의미적 revision |
| `applied_revision` | 현재 인스턴스에 연결된 설치 revision. 없으면 아직 적용 전 |
| `phase` | 해당 인스턴스의 attached / observing / failed / detaching / detached 상태 |
| `configuration.complete` | 설정 파일 목록과 읽기의 완전성. 모든 선언의 유효성이나 관측 성공을 뜻하지 않음 |
| `configuration.issues` | source 파일 경로와 함께 표시하는 읽기·파싱·검증·적용 오류 |

원하는 revision이 적용돼도 관측은 실패할 수 있다. 파싱 오류는 파일 자체를 읽은 경우
`complete=true`와 함께 나타날 수 있다. 오류가 있는 파일은 원하는 선언 목록에서 빠져도
이전에 설치한 인스턴스와 그 설정 경로·revision은 계속 표시된다.

## 변경과 제거

같은 디렉터리에서 파일 이름, 주석, 테이블 키 순서만 바꾸면 설치 revision은 유지된다.
배열 순서, binding, run ID, 해석된 package 변경은 revision에 반영된다. 코드나 이미지 내용의
변경은 manifest의 revision과 이미지 참조에 명시해야 한다. 선언 해시는 관측 결과나 산출물 해시가 아니다.

잘못된 TOML·알 수 없는 필드·잘못된 source는 오류로 남기고 해당 기존 설치를 보존한다.
같은 `id`가 여러 파일에 있으면 임의의 파일을 선택하지 않는다. 디렉터리나 파일을 읽지 못한
불완전한 목록으로 삭제를 추론하지 않는다. binding에는 문자열·정수·유한 실수·불리언·배열·테이블을
쓸 수 있다. TOML 날짜·시각 값은 직접 지원하지 않으므로 필요한 경우 명시적인 문자열로 쓴다.

유효한 설정 변경은 기존 관측 worker를 제거하고 정리를 확인한 뒤 새 인스턴스로 반영한다.
그동안 기존 Keeper·MSX·Browser owner는 계속 자신의 lifecycle을 유지한다. 새 관측 worker의
시작이나 관측 성공까지 이전 worker가 유지되는 무중단 교체를 보장하는 것은 아니다.

선언 파일을 제거하면 다음 완전한 설정 읽기에서 해당 설치를 detach한다. 디렉터리 자체가 없는
경우도 비어 있는 설정으로 취급한다. 제거 대상은 그 선언이 소유한 관측 worker이며, 기존 환경
owner나 다른 설치를 종료하지 않는다. 과거 관측과 이미 보존한 선택 근거는 남는다.

`masc_lane_detach` 도구와 Dashboard의 **Remove TOML + worker**도 TOML로 관리되는 설치라면 일치하는 선언 파일을 제거한다.
그래야 다음 재조정에서 다시 설치되지 않는다. 선언이 이미 다른 revision으로 바뀌었거나 ID가
중복되어 소유권이 불명확하면 그 파일을 임의로 지우지 않고 오류를 반환한다. 잘못된 선언도 먼저
수정하거나 파일을 제거해야 한다. 제거 중 새로 저장된 파일을 이전 revision으로 간주해 지우지
않도록, 실제 제거 대상을 분리한 뒤 검증한다. 수동 Attach로 만든 설치는 TOML 관리 대상으로
편입되지 않는다.

서버 재시작 후에는 보존한 인스턴스의 worker 정리를 확인한 뒤 선언을 다시 적용한다.
create 영수증에 container ID가 남지 않았어도 해당 인스턴스의 정확한 container 이름으로 찾고
소유권 label과 ID를 검증한다. Docker 조회가 실패하거나 소유권을 확인할 수 없으면 정리 완료로
표시하지 않는다. 재시작 복구가 관측 이력의 삭제를 뜻하지는 않는다.

## 패키지에 포함된 Skill

패키지의 `lane.toml`은 선택적으로 다음 선언을 지원한다. 설치 파일의 `[binding]`에 쓰는 설정은 아니다.

```toml
[world.skills]
directory = "skills"
```

`directory`는 패키지 루트 아래의 Skill source 디렉터리다. 각 Skill은 기존 MASC 파서가 읽는
`skills/<skill-name>/SKILL.md` 구조를 따른다. 본문이 참조하는 스크립트와 문서는 그 Skill 디렉터리
아래에 둔다. [MSX 관측 Skill](../../addons/msx-observer/skills/msx-observation-rows/SKILL.md)은 실제 예제이며,
관측 좌표를 정리하는 스크립트와 프레임·게임 턴을 구분하는 참조 문서를 포함한다.

설치된 패키지의 source는 기존 Skill snapshot service에 read-only로 추가된다. 원래 설정한
Skill source와 순서를 보존하며 `runtime.toml`이나 Keeper instructions를 수정하지 않는다.
선언형 설치의 source identity는 선언 ID에 묶이므로 worker 교체로 새 이름을 만들지 않는다.
수동 설치는 해당 instance에 묶인다. 실제 선택에는 카탈로그가 돌려준 정확한 Skill reference를 쓴다.

Keeper는 기존 `keeper_skill`로 본문을 읽고, 같은 reference에 `file`을 지정해
`references/observations.md` 또는 `scripts/summarize.py`를 읽을 수 있다. 리소스 읽기에는 기존
`[skills].resource-read-max-bytes` 설정을 사용한다. 그 설정이 없으면 패키지 source의 이용 불가를
진단하며 임의의 한도를 만들지 않는다. 기존 Keeper의 Skill 선택과 도구 실행 제어는 그대로 적용된다.

`content_revision`은 정확한 `SKILL.md` bytes에서 기존 Skill 규칙으로 만든 불투명한 식별자다.
도메인 구분을 포함한 해시이므로 원문만의 SHA-256과 같다고 해석하지 않는다. 스크립트·참조 파일은 이 revision에
포함되지 않고 요청 시 읽은 bytes와 별도의 SHA-256을 돌려준다. 읽기가 스크립트 실행이나 sandbox
mount 확장을 뜻하지 않는다. 예제 스크립트는 명시적으로 선택한 관측의 좌표만 출력하며 머신을
생성·조작하지 않는다.

잘못된 Skill 문서는 새 카탈로그에서 진단하고 제외하되 다른 Skill과 Keeper 활동을 막지 않는다.
detach가 확인되면 해당 source는 이후 discovery에서 빠진다. 이미 턴에 고정된 Skill 본문을
소급해서 지우지 않는다. 이것은 실제 모델의 Skill 활용·게임 플레이를 증명하는 조건과 별개다.
선언부터 카탈로그·원문 reader까지의 기능 테스트는 CI에서 검증하며, 실제 Keeper 활용은 후속 실측이다.

## 패키지가 선언하는 exact output

패키지는 host 에게 받고 싶은 답의 모양을 이름 붙여 선언할 수 있다. 답의 JSON Schema 는 패키지 안의 파일이다.

```toml
[world.exact_outputs.author]
schema = "schemas/author.json"
```

- 이름은 `a-z`, `0-9`, `_` 로 쓰고 소문자로 시작한다.
- `schema` 는 패키지 루트 기준 상대 경로다. symlink 를 풀어도 패키지 안이어야 한다.
- 파일은 [세계 행동 계약](lane-world-actions.md)의 action schema 와 같은 검사를 통과하고 object 를 설명해야 한다. object 마다 `additionalProperties: false` 가 필요하다.
- schema 는 패키지 값에 들어간다. 선언을 추가·수정·삭제하면 설치 revision 이 바뀐다. 이 표가 없는 패키지는 revision 이 그대로다.

어떤 모델로 답을 받을지는 운영자가 `runtime.toml` 에서 설치마다 정한다.

```toml
[runtime.addon_exact_lanes.operator-quiz.author]
slots = ["glm-coding.glm-5-3"]
cli_slots = ["claude-code"]
max_output_tokens = 8192
```

- 첫 키는 설치 선언의 `id`, 둘째 키는 출력 이름이다. 선언 `id` 가 bare key 가 아니면 따옴표로 감싼다.
- 표의 키와 규칙은 `[runtime.exact_output_lanes.<lane>]` 와 같다. `enabled`, `slots`, `cli_slots`, `max_output_tokens`, `thinking` 을 쓰고, body deadline 이 없는 provider 의 slot 과 output-schema 채널이 없는 CLI slot 은 같은 방식으로 거절된다.
- add-on lane 은 필수가 아니다. `enabled = false` 로 꺼도 서버는 시작하고, 그 lane 은 `Exact_lane_off` 로 답한다.
- `runtime.toml` 은 설치 선언보다 먼저 읽힌다. 그래서 선언에 없는 이름의 표도 로드된다. 선언된 출력에 표가 없으면 그 lane 은 `Exact_lane_unconfigured` 로 답한다.
- TUI Lanes 목록의 패키지 행은 출력마다 상태를 보여 준다: bound(slot 이 있음), unbound(표가 없음), off, 그리고 패키지가 선언하지 않은 이름의 표. `[ / ]` 로 출력을 고르고 `e` 를 누르면 그 출력의 표가 runtime.toml 편집기에서 열린다. 표가 아직 없으면 그렇다고 알려 주고, 거기서 `e` 로 표를 더한다.
- 계정을 제거하면 이 표의 slot 도 함께 빠지고, 켜진 lane 을 비우는 제거는 거절된다. prompt preset 도 이 표를 저장하고 되돌린다.

### host 에게 요청하기

exact output 을 선언한 패키지의 worker 는 비공개 도구 둘을 한 번씩 광고해야 한다. 하나라도 없으면 worker 가 시작하지 않는다. 두 도구는 export 할 수 없다.

- `lane_host_requests`: 인자가 없다. 패키지가 기다리는 요청 전부를 `{"requests": [...]}` 로 돌려준다.
- `lane_host_result`: `{"request_id", "result"}` 를 받고 `{"accepted": bool}` 로 답한다. 결과를 소비하는 기록을 패키지가 디스크에 쓴 뒤에만 `true` 로 답한다.

요청 하나는 다음과 같다. 다른 키, 빈 id, 메시지가 없는 요청은 거절된다.

```json
{"kind": "exact_output", "request_id": "r-17", "output": "author",
 "system": "선택", "messages": ["사용자 메시지", "..."]}
```

- 지금 host 가 아는 종류는 `exact_output`, `read_records`, `read_file`, `read_result`, `ask`, `withdraw_ask` 다. 모르는 종류가 하나라도 있거나, 같은 `request_id` 가 두 번 나오면 그 목록 전체를 읽지 않고 instance 에 `listing_refused` 를 보인다.
- host 는 다섯 사건에만 묻고 시계로 묻지 않는다. 지금 걸린 사건은 넷이다: worker 초기화가 끝났을 때, 그 instance 의 action 이 끝난 receipt 를 남겼을 때, 그 설치의 add-on lane 표가 바뀌어 게시됐을 때, 설치 질문에 운영자가 답했을 때. 선언이 바뀌면 worker 가 다시 떠서 첫 사건이 된다.
- 한 주기는 목록을 받아 순서대로 처리한다. host 가 이미 최종 결과를 가진 요청은 모델을 부르지 않고 그 결과를 준다. 없으면 한 번 시도하고, 결과가 최종이면 준다. 최종이 아니면 다음 사건까지 기다린다. 결과를 준 목록이 있으면 다시 목록을 받고, 아무것도 주지 않은 목록에서 끝난다. 끝나면 관측을 한 번 한다.
- 같은 주기에 이미 준 요청이 다시 나오면 주기를 끝내고 `relisted_delivered_request` 를 보인다.
- 결과를 담은 전체 인자가 `max_reply_bytes` 보다 크면 원래 결과 JSON 바이트와 요청·instance·현재 grant 권한을 먼저 디스크에 저장한다. 성공한 뒤에만 `{"status": "result_exceeds_frame", "original_request_id", "source_id", "retained_sha256", "bytes", "encoding": "json-utf8", "complete": false}` 를 준다. 기록 페이지의 `next_cursor` 도 이 응답에 남는다. 저장 실패는 instance 의 `result_delivery_failed` 이며 참조를 보내지 않는다.
- 최종 결과의 `status` 는 `answered`(`output`, `slot`, 선택 `usage`), `invalid_output`, `input_refused`(`kind`), `outcome_unknown`, `not_allowed`, `request_id_reused` 다. 자세한 뜻은 [운영자 퀴즈 RFC](../rfc/RFC-operator-quiz-lane.md) §4.3–4.4 에 있다.
- 마지막 주기는 Inspect 의 instance 마다 `host_requests` 로 보인다: 주기 수, 최종이 아니어서 기다리는 요청과 그 이유, 주기를 멈춘 이유.

큰 결과는 다음 요청으로 이어 읽는다. `source_id` 는 원래 기록·파일 요청의 값이고 `exact_output`, `ask`, `withdraw_ask` 이면 `null` 이다. SHA만 아는 것으로 다른 instance 나 요청의 결과를 읽을 수 없다.

```json
{"kind": "read_result", "request_id": "r-17-part-0", "original_request_id": "r-17",
 "source_id": null, "sha256": "<retained_sha256>", "offset": 0}
```

`result_chunk` 는 `content`(base64), `offset`, `next_offset`, `eof`, 원본의 `bytes` 와 `sha256` 을 돌려준다. 각 결과 인자 전체가 프레임 안에 들어간다. 패키지는 base64를 풀어 `eof` 까지 바이트를 합치고 원본 SHA-256을 확인한 뒤 JSON을 읽어야 한다. 그 뒤에 원본의 페이지 완료 여부와 `next_cursor` 를 적용한다. 같은 원래 요청을 다시 올리면 처음 저장한 결과를 받는다. 선언이나 grant가 바뀌면 이전 결과의 이어읽기는 거절된다. 변경 없는 저장 파일은 범위만 읽으며, 같은 SHA의 파일이 다시 게시돼 식별 정보가 바뀌면 전체 SHA를 재검증한 뒤 식별 정보를 저장한다.

### 운영자에게 묻기

manifest 에 `[world.asks] operator = true` 가 있는 패키지는 운영자에게 질문할 수 있다. 질문하는 쪽은 설치(선언 id 와 패키지 제목)이고, Keeper 를 깨우지 않는다.

- 요청: `{"kind": "ask", "request_id", "questions", "context"}`. `questions` 는 Keeper 질문과 같은 모양이다(`question_id`, `header`, `prompt`, `choices`, `mode`, `free_text`). `request_id` 가 질문 id 다.
- host 는 같은 `request_id` 의 질문을 한 번만 기록한다. 같은 id 로 다른 질문을 내면 `request_id_reused` 다.
- 운영자가 답할 때까지 결과는 주지 않고 `awaiting_operator` 로 기다린다. 답하면 그 설치의 주기가 돌아 `{"status": "answered", "answers", "responder", "answered_at"}` 를 준다. worker 가 내려가 있으면 답은 저장돼 있다가 다음 worker 가 질문을 다시 낼 때 전달된다.
- 철회는 패키지만 한다: `{"kind": "withdraw_ask", "request_id", "ask_id", "reason"}`. 결과는 `withdrawn` 이고, 이미 답한 질문이면 `already_answered` 다. 그 뒤 질문 자체도 `{"status": "withdrawn"}` 로 끝난다.
- 열린 질문은 `GET /api/v1/lane-addons/asks` 로 본다. 답한 질문과 철회한 질문까지 보려면 `include_resolved=true` 를 붙인다. 질문과 상태는 Keeper 질문 목록과 같은 모양이고, 각 줄에 `declaration_id` 와 `title` 이 붙는다.
- 답은 `POST /api/v1/lane-addons/ask-answer` 에 `{"declaration_id", "ask_id", "answers", "session_id"}` 로 보낸다. `answers` 는 Keeper 질문에 답할 때와 같다. 운영자(admin) 토큰만 답할 수 있고, Keeper 토큰은 403 이다. 없는 질문은 404, 이미 답했거나 철회된 질문은 409, 질문에 맞지 않는 답은 400 이다.
- `[world.asks]` 가 없는 패키지나 수동 Attach 의 질문은 `not_allowed` 다.
- 기한은 없다. 열린 질문은 답하거나 철회할 때까지 열려 있다.

### 기록 읽기

운영자가 쓴 TOML 선언은 `binding.records` 로 패키지가 읽을 기록을 정한다. 수동 Attach 나 Keeper 가 소유한 설치가 이 키를 쓰면 instance 를 띄우기 전에 거절된다.

```toml
[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public", "unlisted"]
```

- `kind` 는 지금 `board`, `repository`, `wiki`, `github_pulls` 다(아래). `board` 는 `visibilities` 가 꼭 있어야 하고 Board 의 값(`public`, `unlisted`, `internal`, `direct`)을 소문자로 쓴다. 기본값은 없다. `direct` 는 적었을 때만 읽는다.
- 이 visibility 의 글은 패키지의 exact output 에 묶인 slot 의 provider 에게 갈 수 있다. `internal` 을 넣기 전에 그 provider 가 내부 글을 받아도 되는지 확인한다.
- 요청은 `{"kind": "read_records", "request_id", "source_id", "after"}` 다. `after` 는 이전 결과의 `next_cursor` 이거나, 처음부터 읽을 때는 없거나 `null` 이다.
- 아직 커서가 없는 패키지는 `after` 대신 `since`(Unix 시각, 초)를 보내 그때부터 만든 기록만 읽는다. Board 는 글·댓글을 쓴 시각, `repository` 는 커밋 시각, `github_pulls` 는 그 PR 을 merge 한 커밋의 커밋 시각, `wiki` 는 `log.md` 에 찍힌 분으로 판다. 둘을 같이 보내면 그 요청은 잘못된 요청이다. 그 시각 뒤로 기록이 없으면 `records` 는 비고 `next_cursor` 는 `null` 이다.
- 결과는 `{"status": "records", "source_id", "records", "next_cursor", "complete", "sha256"}` 다. 오래된 것부터, frame 에 들어가는 만큼 담는다. Board 기록은 글(id, 작성자, 작성·수정 시각, visibility, 제목, 본문)과 그 글의 댓글(id, 글 id, 작성자, 작성 시각, 본문)이다.
- host 는 답하기 전에 `records` 배열을 Lane store 에 blob 으로 보존한다. `sha256` 은 그 blob 이름이라, 나중에 글이 고쳐지거나 만료돼도 인용한 바이트를 확인할 수 있다.
- 권한이 없는 `source_id` 나 host 가 준 적 없는 커서는 `not_allowed` 다. Board 를 읽을 수 없으면 최종이 아니고 `source_unavailable` 로 다음 사건을 기다린다.

`repository` 권한은 등록된 저장소의 기본 브랜치를 읽는다.

```toml
[[binding.records]]
source_id = "masc-repo"
kind = "repository"
repository_id = "masc"
paths = ["changelog.d/", "CHANGELOG.md"]
```

- `paths` 는 저장소 루트 기준 상대 경로다. `/` 로 끝나면 디렉터리, 아니면 파일 하나다. `..` 와 절대 경로는 거절된다.
- `read_records` 는 기본 브랜치의 first-parent 커밋을 오래된 것부터 준다: SHA, 작성자 이름, 커밋 시각, 제목, 본문, 첫 부모 대비 바뀐 경로. 결과의 `head` 는 읽은 브랜치 끝이고, 커서는 커밋 SHA 다. 그 끝이 닿지 않는 커서는 `not_allowed` 다.
- `read_file` 은 `{"kind": "read_file", "request_id", "source_id", "commit", "path"}` 다. 기본 브랜치 끝이 닿는 커밋에서, `paths` 안의 파일 하나의 바이트를 `{"status": "file", "source_id", "commit", "path", "encoding", "content", "bytes", "sha256"}` 로 준다. 텍스트면 `encoding` 이 `utf-8`, 아니면 `base64` 다. 바이트는 blob 으로 먼저 보존한다.
- `paths` 밖의 파일, 기본 브랜치가 닿지 않는 커밋, 그 커밋에 없는 파일은 `not_allowed` 다. 등록되지 않았거나 읽을 수 없는 저장소는 `source_unavailable` 로 기다린다.

`wiki` 권한은 이 workspace 의 wiki 를 읽는다. `source_id` 와 `kind` 말고 다른 키는 없다.

```toml
[[binding.records]]
source_id = "wiki"
kind = "wiki"
```

- wiki 는 page 마다 본문을 하나만 두고, 고치면 그 본문을 바꾼다. 쓴 순서는 `log.md` 에만 남는다.
- 그래서 `read_records` 는 page 를 그 page 의 마지막 `log.md` 줄 자리에서 한 번씩 준다: 이름, revision, 제목, 요약, 작성자, 지금 본문. 커서 뒤에 고친 page 는 새 revision 으로 다시 나온다.
- 지난 revision 의 본문은 그때 읽어 보존한 blob 에만 있다. page 가 지워졌거나 header 를 읽을 수 없으면 그 줄은 기록을 내지 않는다.
- 커서는 `log.md` 줄 하나를 위치와 page, revision 으로 가리킨다. 지금 log 의 그 위치에 같은 줄이 없으면 `not_allowed` 다. `log.md` 가 없는 wiki 는 기록이 없고, 파일을 읽을 수 없으면 `source_unavailable` 로 기다린다.
- `since` 는 page 의 마지막 `log.md` 줄에 찍힌 분으로 판다. log 는 분까지만 찍으므로 그 시각보다 1분 안쪽 앞에 쓴 page 도 같이 읽는다. 찍힌 시각을 읽을 수 없는 줄은 읽지 못한 줄로 세고 기록을 내지 않는다.
- `read_file` 은 `wiki` 를 읽지 않는다(`not_allowed`).

`github_pulls` 권한은 등록된 저장소에 merge 된 pull request 를 GitHub 에서 읽는다.

```toml
[[binding.records]]
source_id = "masc-prs"
kind = "github_pulls"
repository_id = "masc"
```

- GitHub 은 merge 된 pull request 를 만든 시각이나 고친 시각 순으로만 나열한다. 그래서 순서는 등록된 checkout 의 기본 브랜치 first-parent 커밋에서 가져온다. 커서도 `repository` 처럼 커밋 SHA 다.
- host 는 커밋마다 그 커밋을 merge commit 으로 가진 pull request 를 GitHub 에 묻는다. 기록 하나는 그 pull request 다: 번호, 제목, 본문, merge commit, merge 시각, 작성자, 그리고 review 전부(id, 작성자, 제출 시각, 상태, 본문)와 review 마다의 댓글(id, 작성자, 시각, 경로, 줄, 본문). review 와 댓글은 page 를 끝까지 넘겨 읽는다.
- pull request 가 merge 하지 않은 커밋(브랜치에 바로 올린 커밋, rebase merge 의 앞쪽 커밋)은 기록을 내지 않고 커서만 지나간다. 시각은 GitHub 이 쓴 그대로이고, 지운 계정의 작성자는 `null` 이다.
- GitHub 은 runtime.toml `[repositories] pr_reader` Keeper 의 token 으로 읽는다. PR 개요가 쓰는 것과 같은 reader 다. reader 가 없거나 준비되지 않았거나, GitHub 이 rate limit·인증 거절·오류로 답하면 `source_unavailable` 로 다음 사건을 기다린다.
- `read_file` 은 `github_pulls` 를 읽지 않는다(`not_allowed`).

## 세계와 연결되는 통로

패키지는 TOML 설치, Skill 본문·스크립트·참조 문서 읽기, Docker 환경, 선택적인 행동 포트를 연결한다.
[출력 연결](lane-output-composition.md)의 `lane_output` source를 통해 다른 설치의 완료된 관측을
통계 패키지 입력으로 전달한다. [세계 행동 계약](lane-world-actions.md)의 `[world.actions]`는
패키지가 광고한 행동을 자신의 worker에서 실행하고 영속 receipt와 근거를 반환한다.
[DOS 패키지](../../addons/dos-world/README.md)는 자체 환경·프로그램·Skill을 포함하는 예제다.
관측 전용 MSX·Browser 패키지는 기존 환경의 소유권을 유지한다.

설치 선언에 임의의 `skills`, `scripts`, `environment` 최상위 필드를 추가하는 방식은 지원하지 않는다.
Skill과 행동은 패키지 manifest의 `world`에, 실행 환경은 image·command에, 입력 연결은 설치의
binding에 선언한다. 이미지를 준비하는 작업과 TOML 설치는 구분한다. 설치하면 패키지의 command를
worker에서 실행하지만, Skill helper 스크립트는 본문이나 파일을 읽는 것만으로 실행되지 않는다.
각 패키지의 실행·비간섭·행동 활용은 별도 실측으로 검증한다. 이 계약은 machine checkpoint·fork나
생산성 향상을 보장하지 않는다.

구현 경계: [선언 loader](../../lib/lane_addon/lane_addon_config.mli),
[설치 runtime](../../lib/lane_addon/lane_addon_runtime.mli),
[전체 v0 계약](../design/lane-addon-v0.md).
