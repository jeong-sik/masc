# 저작한 세계 설정 내보내기

[English](world-configuration-portability.md)

관리자는 서버가 사용하는 세계의 Runtime TOML, Keeper TOML 전체 선언과 영속 prompt
override를 JSON 응답 하나로 받을 수 있습니다. instructions만 담는 프리셋에서 빠지는
도구·Skill의 빈 목록, false 값, 생략된 필드도 원문 그대로 보존합니다.

현재 경로는 설정 문서를 내보냅니다. Import, 의존 자산, CLI 명령과 Dashboard 조작은
[이슈 #52824](https://github.com/jeong-sik/masc/issues/52824)에서 이어갑니다.
Export만으로 다른 세계가 만들어지거나 Keeper를 다른 기기에서 실행할 수 있게 되지는 않습니다.

## 요청과 권한

대상 MASC 서버에 `GET /api/v1/world/configuration/export`를 요청하고
`Authorization: Bearer <admin-token>` 헤더를 보냅니다. Workspace 인증의
`enabled`와 `require_token`이 true이고 토큰에 `CanAdmin` 권한이 있어야 합니다.
strict HTTP 인증을 꺼도 공개 조회가 되지 않습니다.

기존 workspace 읽기 전제조건을 사용할 수 있습니다. `expected_base_path`와
`expected_masc_root` 쿼리 값을 함께 보내면 다른 workspace를 사용하는 서버의 응답을
거절합니다. 이 값은 읽는 서버를 확인하며, 다른 세계를 Export 원본으로 선택하지 않습니다.
셸의 현재 디렉터리 대신 실제 서버가 해소한 경로를 사용합니다.

성공하면 HTTP 200을 돌려줍니다.

```json
{
  "ok": true,
  "scope": "authored_configuration_documents",
  "bundle": {
    "schema_version": 1,
    "origin": {
      "base_path": "/workspace/a",
      "config_root": "/workspace/a/.masc/config"
    },
    "runtime": null,
    "overrides": null,
    "keepers": []
  },
  "lock_warnings": []
}
```

이 예시는 config root가 존재하고 읽을 수 있지만 설정 문서가 없는 경우입니다.
존재하는 문서는 `{"content":"...","sha256":"..."}`로 담습니다.
Keeper 행은 `{"name":"alpha","declaration":{"content":"...","sha256":"..."}}`입니다.
digest는 원문 바이트를 식별합니다. `null`은 파일 부재, 빈 Keeper 목록은 수집할 선언이
없었다는 뜻입니다. 읽기 실패를 무시했다는 뜻으로 사용하지 않습니다. 원본 경로는 출처이며,
받는 기기의 같은 경로에 쓸 권한이 아닙니다.

저작한 Runtime·Keeper 문서 자체에 기밀 값이 있을 수 있습니다. Export는 원문을 보존하며
비밀 값을 지우거나 가리지 않습니다. 캡처와 캡처 오류 응답에 `Cache-Control: no-store`를
붙이고 bundle 본문을 로그로 남기지 않습니다. 내려받은 응답은 비공개로 보관합니다.
Export는 게시나 공유를 수행하지 않습니다.

## 캡처가 보장하는 범위

config root는 `MASC_CONFIG_DIR`를 포함한 기존 resolver가 정합니다. 서로 다른 BasePath도
같은 config root를 사용할 수 있습니다. prompt override는 공유 config root 대신 명시한
서버 workspace의 `.masc/prompt_overrides.json`에서 읽습니다. `origin`에 두 위치를 남깁니다.

Runtime 설정 잠금과 이 프로세스의 prompt 변경 잠금을 잡고 원문을 복사합니다.
잠금을 푼 뒤 복사한 바이트의 hash와 문서를 검사합니다. Runtime TOML은 문법을 검사하고,
Keeper 선언은 파일명과 이름의 일치 및 필수 instructions를 포함한 기존 엄격 검증을
사용합니다. override는 기존 버전별 영속 형식을 검증하고 저작 출처를 보존합니다.

이 잠금을 사용하는 writer는 캡처 중 변경하지 못합니다. 수동 파일 편집이나 다른 프로세스의
prompt 쓰기는 직렬화하지 않습니다. writer가 나눠 수행하는 여러 transaction도 하나의
세계 transaction으로 합치지 않습니다. 전체 BasePath 백업이나 runtime 상태의 원자적
snapshot이 아닙니다.

config root 부재, 읽을 수 없는 선언, symlink와 잘못된 문서는 Export 오류입니다.
문제가 있는 Keeper를 빼고 줄어든 팀을 성공으로 반환하지 않습니다. Runtime·override 파일
부재는 그대로 남깁니다. Keeper 디렉터리 부재는 기존 config root를 정상적으로 읽을 수
있을 때만 빈 저작 목록으로 나타냅니다. config root를 새로 만들지는 않습니다.
잠금을 잡는 과정에서 기존 방식의 lock 파일이 생길 수 있습니다.

캡처 실패 응답은 `{"ok":false,"error":"..."}`입니다. 잘못된 BasePath는 HTTP 400,
원본 부재·읽기·검증 오류는 422, 설정 잠금 진입 실패는 409입니다. 인증, workspace
전제조건과 서버 준비 상태는 기존 응답을 유지합니다. `lock_warnings`는 캡처 성공 뒤
Runtime 잠금 해제에서 관측한 경고입니다. 설정 반영이나 영속 commit 영수증이 아닙니다.

참조하는 Skill, package, 도구, exact-worker 자산, 이미지와 호스트 경로는 복사하거나
실행 가능 여부를 확인하지 않습니다. 로그인·credential 저장소, Memory, 원본 요청과
진행 중인 효과도 포함하지 않습니다. 설정을 설치하거나 활성화하지 않습니다.
선언과 runtime 데이터의 경계는 [Keeper 파일 모델](../KEEPER-FILE-MODEL.md)을 참고합니다.
