# Keeper chat 인증과 TUI 검증 기록

## 공통 헤더

- `날짜(ISO8601)`: `2026-09-13T03:16:27.704812+09:00`
- `작성자`: `Codex`
- `결정 ID`: `keeper-chat-20260913`
- `적용 대상`: `providers.claude_code, TUI Keeper chat`
- `결정 상태`: `추적 필요`
- Delta: 상속된 API 키를 구독 CLI에서 제거해 인증을 복구했다. TUI 변경은 별도로 CI와 실제 화면 확인이 필요하다.

## 근거 (Evidence)

- `항목`: Claude 구독 인증 복구와 현재 턴 표시
- `출처`: https://code.claude.com/docs/en/env-vars 및 auth-runtime.json의 실제 호출 기록
- `확인일시`: `2026-09-13T03:16:27.704812+09:00`
- `신뢰도`: `High`
- `제한조건`: 인증 복구는 실측했지만 새 TUI 화면은 아직 배포하지 않았다.

## 검증 (Verification)

- `1차`: 공식 문서에서 비대화형 CLI의 ANTHROPIC_API_KEY 우선 사용을 확인했다.
- `2차`: 환경변수를 제외한 claude auth status가 기존 Max 구독을 표시했다. wrapper의 sh -n 검사도 통과했다.
- `3차`: 같은 모델의 claude -p 호출이 3254ms에 OK를 반환했다. runtime raw-save는 2026-09-12T17:38:45Z에 재시작 없이 적용됐으며 실제 Keeper에서 Claude 도구 호출과 반환을 관찰했다.
- `재현 결과`: 인증은 복구됐다. 코드 문법과 diff 검사는 통과했고 TUI CI와 화면 검증은 미완료다.

## 불확실성 (Uncertainty)

- `미확인 항목`: 간헐적인 history GET 지연의 단일 원인과 새 TUI의 실제 렌더링.
- `영향`: 10초 조회 실패는 02:27:21, 02:27:32 뒤에도 02:31:07에 발생했다. 서버 시작 지연만으로 설명할 수 없다.
- `추가 확인 필요`: CI 상태 테스트 통과, CI 산출물로 TUI 화면·키 입력 검증, history cold-read 프로파일.

## 적용범위 (Scope)

- `영향 받는 영역`: 이 배포의 Claude provider command, 현재 턴 관찰, 정확한 중단, 사용자 메시지 우선순위.
- `제약/배제`: 스케줄·Board·다른 Keeper 입력의 내용을 변경하지 않는다. 승인·재시도 대기 조건을 우회하지 않는다.
- `롤백 조건`: 구독 호출 실패 시 기존 runtime.toml 백업의 provider command를 복원하고 raw-config API로 적용한다. 백업에는 다른 비밀값이 있을 수 있어 공개하지 않는다.
