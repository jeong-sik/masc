# HTML 아티팩트의 입력 저장

관련 목표: #45940. 이 층은 서버의 개인 입력 저장과 API를 구현합니다.
읽기 화면의 HTML 입력창·SDK 연결은 다음 층에서 붙입니다. 이 API만으로
기존 HTML 입력값이 자동 저장되지는 않습니다.

## 저장 범위

작업 공간, 아티팩트 ID, 게시 버전, 인증된 사용자마다 JSON 객체 하나를
저장합니다. 서로 다른 사용자·문서·게시 버전은 같은 입력을 덮어쓰지
않습니다. 게시한 HTML과 공동 편집 원고는 이 저장으로 바뀌지 않습니다.
다음 게시 버전에 이전 입력을 자동으로 옮기지 않습니다.

사용자는 기존 HTTP 인증에서 정합니다. 요청 본문에 `actor`를 넣을 수
없습니다. 같은 인증 주체를 공유하는 창은 같은 개인 입력을 읽습니다.
이 API는 기존 아티팩트와 같이 `CanAdmin` 권한이 필요하며, 문서별 권한을
대신하지 않습니다. 인증 정보나 다른 사용자 입력을 HTML에 주지 않습니다.

## API

`GET /api/v1/artifact-app-data/<artifact-id>?revision=<게시 버전>`은
해당 사용자의 입력을 읽습니다. 아직 저장하지 않은 경우 `version: 0`,
`data: {}`, `receipts: []`를 반환합니다. 존재하는 HTML 게시 버전만 받습니다.
손상된 상태를 빈 입력으로 바꾸지 않습니다.

`POST /api/v1/artifact-app-data`는 다음 객체를 받습니다.

```json
{
  "target": {"artifact_id": "artifact-…", "revision": 1},
  "id": "<canonical UUID v7>",
  "expected_version": 0,
  "data": {"memo": "다음 회의에서 확인", "answers": [true, 3]}
}
```

`data`는 UTF-8 문자열, 유한한 숫자, 불리언, null, 배열, 객체를 포함할 수
있습니다. 정수는 JavaScript에서 정확하게 표현할 수 있어야 합니다.
중복 키·알 수 없는 필드·빠진 필드는 거절합니다. 객체 키 순서는 요청
동일성에 영향을 주지 않습니다.

성공 시 `schema: masc.artifact_app_data.v1`, `target`, `actor`, `version`,
`data`, `receipts`를 반환합니다. 저장할 때 버전이 하나 증가합니다.
`expected_version`이 달라졌으면 HTTP 409와 `current`를 반환합니다.
클라이언트는 기존 입력을 보관하고 충돌을 보여줘야 합니다. 새 버전으로
조건만 바꿔 덮어쓰거나 자동 재시도하지 않습니다.

이미 저장한 `id`와 같은 요청은 현재 입력을 반환합니다. 그 뒤에 다른
요청이 저장됐어도 이전 값으로 되돌리지 않습니다. 같은 `id`로 다른
입력이나 조건을 보내면 HTTP 409를 반환합니다. `receipts`는 요청 ID,
기준 버전, 정규화한 입력의 SHA-256, 저장 시각을 기록합니다.

기존 workspace 읽기 헤더 검사를 통과해야 하며, POST의
`expected_workspace`도 저장 전에 검사합니다. 모든 응답은
`Cache-Control: private, no-store`입니다.

## 파일과 실패

`<effective MASC root>/artifact_app_data/`의 private 파일에 저장합니다.
파일명은 문서 ID·게시 버전·인증 주체의 SHA-256으로 정합니다. 파일을
읽은 뒤 저장된 문서·버전·사용자도 대조합니다. owned-path와 stable lock,
cursor 조건부 atomic rewrite를 사용합니다. 다른 창이 먼저 저장하면
그 상태에서 버전 조건과 요청 이력을 다시 확인합니다.

rename 이후 fsync나 잠금 해제가 실패하면 HTTP 503
`artifact_app_data_commit_uncertain`과 `attempted`를 반환합니다. 서버는
다시 쓰지 않습니다. GET으로 실제 저장 상태를 읽은 뒤 같은 요청의
receipt를 확인합니다. 손상된 파일, 안전하지 않은 소유권·권한, symlink는
거절하며 기존 바이트를 보존합니다.

검사: `scripts/dune-local.sh build test/test_artifact_app_data.exe` 후 해당
실행 파일을 실행합니다. 전체 빌드·브라우저·운영 배포 검사를 대신하지
않습니다.
