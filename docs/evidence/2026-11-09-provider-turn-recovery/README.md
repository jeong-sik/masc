# Keeper provider 턴 실패 조사와 수정 근거

2026-11-09에 관측했다. 소스 기준은 `e3c6479ec1b100e2b2fa007e8a2676dd015de051` 위의 이 변경이다. 로컬 Dune 빌드, 전체 회귀, 설치, 서버 재시작은 하지 않았다.

## Antigravity

운영 로그에서 `actions_denied`로 끝난 턴을 CLI 원본 기록과 연결했다. 두 실패 대화의 마지막 호출은 작업 폴더 밖 `.agents/skills/<skill>/SKILL.md`를 읽는 `read_file(Path)`였다. `.masc` 디렉터리를 읽다가 실패했다는 근거는 없었다. 같은 대화에서 settings가 명시적으로 거부한 명령은 도구 오류를 돌려주고 다음 단계로 이어졌다.

Google의 [권한 문서](https://antigravity.google/docs/permissions?tab=cli)는 허용 규칙 밖 파일 접근의 기본값을 Ask로 설명한다. [훅 문서](https://antigravity.google/docs/hooks?tab=cli)는 `allow`가 기본 정책으로 위임하고, `deny`가 호출을 거부한다고 명시한다. 훅은 CLI의 `.gemini/config/hooks.json`에 둔다. [headless 문서](https://antigravity.google/docs/cli/headless/)는 승인할 수 없는 호출 뒤에도 실행이 이어진다고 설명하지만, 아래 1.5.3 관측에서는 훅 없는 운영 턴이 끝났다. 문서의 설명을 현재 바이너리의 동작 증명으로 쓰지 않는다.

실험은 별도의 HOME과 작업 폴더, 내용이 알려진 안쪽·바깥쪽 파일로 했다. 운영 대화를 재전송하지 않았다. 로그인 파일 사본은 0600으로 만들었고 종료 후 제거했다. 새 출력은 `artifacts/provider-recovery-20261109/`에 있다.

| 검사 | 관측 |
| --- | --- |
| CLI | `agy 1.5.3`, 모델 `gemini-3.8-flash-medium`, mode `plan`, 권한 우회 플래그 없음 |
| Python 진단 훅 | 바깥 파일 deny → 작업 파일 allow → 최종 `INSIDE-READ-PROVEN`, `SUCCESS`, `denied_actions` 없음 |
| 변경한 OCaml 훅 소스 | OCaml 인터프리터로 같은 CLI 검사 실행. 바깥 읽기 오류 뒤 작업 파일 내용으로 답변 완료, `SUCCESS`, `denied_actions` 없음 |
| 파일 경계 검사 | OCaml 소스를 인터프리터로 실행한 8개 검사 통과. 상대 경로, 비슷한 이름의 형제 폴더, `..`, symlink 탈출, 비밀 경로, 현재 대화의 큰 결과 파일, 잘못된 JSON·중복 Path·NUL·없는 파일을 포함 |

해당 OCaml 소스를 실제로 실행했지만, 배포용 네이티브 실행 파일을 빌드하거나 설치한 증거는 아니다. 훅 소스 SHA-256과 CLI 결과를 옆의 `observations.json`에 기록한다. `cli-events.sanitized.jsonl`은 원본 stdout에서 도구 종료·최종 결과를 골라 호스트 경로를 바꾼 파생본이다. 원본 stdout과 파생본의 해시는 서로 구분한다.

수정은 내장 `read_file`에만 적용한다. 작업 폴더·추가 작업 폴더·MASC 도구 schema와 현재 대화가 만든 결과·transcript 읽기는 기존 정책에 위임한다. 설정 폴더·로그인 토큰은 먼저 거부한다. 기존 Native_none 전체 읽기 거부, 쓰기·명령·네트워크 규칙은 유지한다. helper 실패의 fail-open/closed 동작은 재측정하지 않았으며, 보장하지 않는다. 예상 가능한 입력·경로 오류는 exit 0과 deny JSON으로 반환한다. helper가 없으면 Keeper를 띄우기 전에 준비가 실패한다.

이는 RFC-0490 전체 L3 구현이 아니다. 쓰기 훅, Native_none schema 개방, eager 제거는 포함하지 않는다.

## GLM 연결 종료

운영 로그에 `glm-coding.glm-5.3-flash`의 `Eio.Io Net Connection_reset Unix_error (Broken pipe, "writev", "")`를 확인했다. 오류는 EPIPE를 `End_of_file`로 분류한 typed 네트워크 실패다. 초기 health 관측의 요청 실패 3건은 모두 재사용 연결에서 발생했지만, 이것만으로 유휴 연결이나 공급자 중 어느 쪽이 원인인지 확정하지 않는다.

[Z.AI 오류 문서](https://docs.z.ai/api-reference/api-code)는 HTTP 상태와 응답 본문의 사업 오류를 설명한다. 여기에는 HTTP 응답을 받지 못한 이 TCP 종료의 원인을 판정할 정보가 없다. 공식 feedback 저장소의 [유사 사용자 신고 #1418](https://github.com/zai-org/feedback/issues/1418)는 다른 클라이언트·환경의 관측이며, 이 사례에 대한 공급자의 장애 확인이 아니다.

기존 RFC-0492에 따라 HTTP 계층은 POST를 다시 보내지 않는다. 상위 Keeper 실행에서 materialized Agent Core 후보의 typed EOF/reset이 스트림 이벤트·체크포인트·도구 효과 전에 발생하면, 같은 실행을 새 연결로 다시 시작한다. 재연결도 실패하면 그 결과를 그대로 반환한다. 공식 CLI 세션이나 이미 진행된 도구를 다시 실행하지 않는다. 동기 실행을 스트리밍으로 바꾸지 않는다.

GLM 변경은 독립 소스 리뷰와 구문 검사까지만 확인했다. 재연결 정책·캐시 배선의 OCaml 검사는 추가했지만 실행하지 않았다. 실제 GLM 공급자와의 복구, 빌드, 운영 적용은 미검증이다.

## 설치 검사와 남은 범위

- release bundle Python 검사 35개, macOS runtime 패키지 검사 21개, uninstall 검사 9개 통과.
- 로컬 설치에서 helper 복사와 build target을 확인한 변경 관련 검사 3개 통과.
- 로컬 설치 전체 34개 검사에서는 실패 11건이 남았다. 변경 전 기준 소스를 따로 추출해 같은 검사를 실행해도 같은 11개 subtest가 실패했다. 원인은 그 fixture가 `scripts/lib/install-workspace-dashboard.sh`를 복사하지 않는 것이다. 이 변경의 통과 결과로 계산하지 않는다.
- 변경한 OCaml 파일의 구문, shell 구문, workflow YAML 파싱과 `git diff --check` 통과.
- 독립 리뷰에서 발견한 stream 경계, Sync/Stream 선택, 개발 실행 helper 배치 문제를 반영했다. 이것은 GitHub의 독립 계정 승인이나 사람의 권한 경계 리뷰를 대체하지 않는다.
