# TOML로 Lane Add-on 설치하기

이번 범위는 외부 관측 패키지를 파일로 설치·변경·제거하는 경로다. 기존 MSX 머신,
Browser 세션, Keeper의 실행과 도구를 재사용한다. 패키지 하나가 여러 관측·관계 Lane을
제공할 수 있다. MCP는 worker와 통신하는 규약이며, 설치 단위의 의미는 패키지가 제공하는
관측과 관계다. 이 문서는 구현 중인 계약을 설명한다. 통합 테스트의 CI 검증은 예정이며,
런타임 실측 합격 보고서는 아니다.

## 설치 위치와 예제

서버는 기존 config resolver가 선택한 `<resolved-config-root>/lane-addons/*.toml`을 읽는다.
기존 `MASC_CONFIG_DIR` 설정이 우선하며, 기본 위치는 `<base-path>/.masc/config/lane-addons/`다.
저장소의 `config/`를 실행 중 설정으로 자동 사용하지 않는다. Dashboard의 **TOML configuration**에
실제로 읽는 디렉터리가 표시된다.

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
현재 source 종류는 `snapshot_file`, `msx_capture`, `browser_document`다. 후자는 이미 열린
정확한 Browser 대상을 요구하며, 선언을 추가한다고 새 세션이나 탭을 만들지 않는다.
MSX 예제는 incarnation을 고정하지 않으므로 기존 머신의 load/restore를 구분해서 계속 관측한다.

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

현재 `Detach` 도구·Dashboard 동작도 TOML로 관리되는 설치라면 일치하는 선언 파일을 제거한다.
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
아래에 둔다. [MSX 관측 Skill](../../addons/msx-observer/skills/msx-observe/SKILL.md)은 실제 예제이며,
관측 좌표를 정리하는 스크립트와 프레임·게임 턴을 구분하는 참조 문서를 포함한다.

설치된 패키지의 source는 기존 Skill snapshot service에 read-only로 추가된다. 원래 설정한
Skill source와 순서를 보존하며 `runtime.toml`이나 Keeper instructions를 수정하지 않는다.
선언형 설치의 source identity는 선언 ID에 묶이므로 worker 교체로 새 이름을 만들지 않는다.
수동 설치는 해당 instance에 묶인다. 실제 선택에는 카탈로그가 돌려준 정확한 Skill reference를 쓴다.

Keeper는 기존 `keeper_skill`로 본문을 읽고, 같은 reference에 `file`을 지정해
`references/observations.md` 또는 `scripts/summarize.py`를 읽을 수 있다. 리소스 읽기에는 기존
`[skills].resource-read-max-bytes` 설정을 사용한다. 그 설정이 없으면 패키지 source의 이용 불가를
진단하며 임의의 한도를 만들지 않는다. 기존 Keeper의 Skill 선택과 도구 실행 제어는 그대로 적용된다.

`content_revision`은 정확한 `SKILL.md` bytes의 SHA-256이다. 스크립트·참조 파일은 이 revision에
포함되지 않고 요청 시 읽은 bytes와 별도의 SHA-256을 돌려준다. 읽기가 스크립트 실행이나 sandbox
mount 확장을 뜻하지 않는다. 예제 스크립트는 명시적으로 선택한 관측의 좌표만 출력하며 머신을
생성·조작하지 않는다.

잘못된 Skill 문서는 새 카탈로그에서 진단하고 제외하되 다른 Skill과 Keeper 활동을 막지 않는다.
detach가 확인되면 해당 source는 이후 discovery에서 빠진다. 이미 턴에 고정된 Skill 본문을
소급해서 지우지 않는다. 이것은 실제 모델의 Skill 활용·게임 플레이를 증명하는 조건과 별개다.
선언부터 카탈로그·원문 reader까지의 기능 테스트는 CI에서 검증하며, 실제 Keeper 활용은 후속 실측이다.

## 다음 구현 범위

현재 패키지는 TOML 설치와 Skill 본문·스크립트·참조 문서의 읽기를 연결한다. 패키지 실행 스크립트의
새 lifecycle, environment/world ports, MSX/DOS 실행·제어 환경, 다른 레이어 출력의 입력 연결과
통계·의미 연결은 후속 단계다. 설치 선언에 `skills`, `scripts`, `environment` 같은 최상위 필드를
추가해도 그 기능이 생기지 않는다. 지원하는 Skill 선언은 패키지 manifest의 `[world.skills]`다.
세계에 새로운 활동·판단 레이어를 쉽게 붙인다는 방향은 유지하며, 각 확장은 별도 실행·비간섭·효용
시험으로 증명한다. 현재 관측 설치를 완성된 세계 구성 엔진이라고 부르지 않는다.

구현 경계: [선언 loader](../../lib/lane_addon/lane_addon_config.mli),
[설치 runtime](../../lib/lane_addon/lane_addon_runtime.mli),
[전체 v0 계약](../design/lane-addon-v0.md).
