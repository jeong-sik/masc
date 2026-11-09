# 기능 경로 추가 점검 · 2026-11-09

앞선 [주간 코드 점검 PR](https://github.com/jeong-sik/masc/pull/50179)은 취소와 데이터 보존에 집중했다.
이번에는 공개된 기능의 입력부터 처리·저장·응답·사용자 소비 경로를 따라갔다.
기준 소스는 `66cb2c7317b21c4e12281cc37846ce5e20177415`다.
전체 기능의 정상 판정이나 새로 생긴 결함만의 목록은 아니다.

## 확인하고 수정한 기능 오류

| 기능 | 실패 조건과 결과 | 수정 | PR |
| --- | --- | --- | --- |
| HTTPS Dashboard 실시간 연결 | 새 세션이 HTTP/2로 `GET /ws`를 보내 연결 정보를 읽으면 Router가 업그레이드 capability 부재만으로426을 반환한다. 클라이언트는 재시도만 하고 `new WebSocket`에 도달하지 못한다. | 일반 연결 정보 조회는200으로 처리하고, 실제 미지원 업그레이드만426으로 거절한다. 기존 인증·Origin 검사는 유지한다. | [#50251](https://github.com/jeong-sik/masc/pull/50251) |
| Grep 정규식 | 입력을 `String.trim`해서 `needle `가 `needleX`까지 찾고, 공백만 있는 유효한 regex는 거절한다. 앞의 개행도 지워져 잘못된 패턴을 정상 검색으로 바꾼다. | descriptor의 기존 `-i` 변환 뒤 패턴 바이트를 그대로 rg에 전달한다. 빈 문자열은 계속 거절한다. | [#50252](https://github.com/jeong-sik/masc/pull/50252) |
| GitHub 실행 완료 감시 | one-shot 행을 읽어 감시를 허용한 뒤 다른 호출이 반복 일정으로 바꾸면, 첫 호출이 반복 일정에 감시를 저장하고 성공한다. 감시기는 one-shot만 읽어 실행하지 않는다. | 감시를 붙이는 update만 검사한 instance에 결속한다. 저장소 잠금 안에서 이미 있는 CAS로 거절한다. 일반 update의 최신 timing 유지 동작은 보존한다. | [#50253](https://github.com/jeong-sik/masc/pull/50253) |

HTTP/2 오류는 이번 주의 공용 경로 표 도입 뒤의 누락이다. GitHub 감시의 경합은
[RFC-0379](../rfc/RFC-0379-keeper-monitor-event-wake.md) §6.5에 이미 알려져 있었지만 수리되지 않은 동작이다.
Grep 패턴 변경은 이전부터 있던 결함이며 이번 주에 도입됐다고 주장하지 않는다.

### 재현·검증 범위

- **HTTPS:** 같은 실행 중 TLS 리스너에서 HTTP/2 `/ws`는426, HTTP/1.1 `/ws`는200과 `wss` URL을 반환하는 것을 읽기 요청으로 확인했다.
  운영 Router/handler를 그대로 추출한 전후 실행은 일반 discovery426→200, 미지원 upgrade426→426, capability가 있는 upgrade101→101이었다.
  이 실행의 인증·attachment·wire sink는 stub이므로 실제 TLS WebSocket 연결 증거는 아니다.
  실제 production H2 gateway를 통하는 회귀 시험을 추가했고 파싱했다. 실행·브라우저 캡처·배포는 하지 않았다.
- **Grep:** 실제 Safe_ops·descriptor와 변경 전후 패턴 추출을 사용한 OCaml 실행 후 `rg`를 실행했다.
  앞·뒤·공백만인 패턴, `-i`, 개행의 다섯 조건을 확인했고 독립 리뷰어도 같은 rg 기대 결과를 확인했다.
  public descriptor→원격 요청 frame→캡처한 argv→rg fixture를 잇는 회귀 시험도 추가했지만, 전체 sandbox suite를 실행한 것은 아니다.
- **스케줄:** 실제 public tool 호출 두 개를 기존 admission callback에서 교차시키는 시험 세 개를 추가했다.
  timing 유지, due 명시와 recurrence 유지, 감시 없는 일반 수정의 대조군이다. 새 시험의 검증은 파싱까지다.
  실제 경합의 실행 전후 결과·전체 타입 검사·CI·운영 일정 변경은 수행하지 않았다.
- 세 변경은 서로 다른 세션의 소스 리뷰를 거쳤다. 소스 리뷰는 GitHub 정식 승인이나 미실행 테스트의 통과 증거가 아니다.

## 계약·설계에 남아 있는 미구현 기능

### Goal 생성 시 성공조건의 실현 가능성 심사

[Goal 생성](../../lib/workspace_goals.ml)은 `Goal_store.upsert_goal_with_events`를 부르고,
[저장소 계약](../../lib/goal/goal_store.mli)은 title·metric·target의 비어 있지 않음만 입력 불변식으로 검사한다고 명시한다.
성공조건이 현실에 존재하고 도달 가능한지를 모델이 생성 시 심사하는 경로는 없다.
[헌법](../constitution.xml)의 B2도 이 갭을 명시한다. 완료 시 proof 검증과는 별도의 기능이다.
이번 세 PR은 생성 시 심사를 구현하지 않는다.

### Board Direct의 수신자 기반 읽기 권한

[Board 조회 도구](../../lib/board_tool_adapter/board_tool_post.ml)는 목록에 reader를 받지 않고,
상세의 viewer는 투표 표시에 쓴다. Keeper의 list/get 경로도 수신자 기반 읽기 판정을 넘기지 않는다.
따라서 일반 Board 읽기 권한을 가진 다른 identity가 Direct 본문을 읽지 못한다고 보장하는 구현은 미완성이다.
이미 [Draft RFC](../rfc/RFC-board-read-access-follows-visibility.md)가 공용 조회·SSE·활동 기록까지의 변경을 설계한다.
`Members_only`·`Owner_only`는 게시 권한이므로 다른 사람이 읽을 수 있다는 사실만으로 결함으로 분류하지 않는다.
이번 세 PR은 Board 권한 설계를 변경하지 않는다.

## 후속 단계로 명시된 범위

- **TUI의 직접 HTTPS 연결:** 클라이언트 URL은 아직 HTTP를 사용한다.
  [RFC-0512](../rfc/RFC-0512-one-route-table-serves-http1-and-http2.md)가 외부 클라이언트 스택 연동을 후속으로 둔다.
  서버의 일반 `/ws` discovery가 HTTP/2에서 실패하는 위 결함과 구분한다.
- **Vibe의 Keeper 턴·이미지·output schema:** [Vibe RFC](../rfc/RFC-vibe-official-client-lane.md) L3는 Fusion과 probe만 연결한다.
  Keeper 턴은 사전 거절하고 exact-output 후보에 들어가지 않는다. 공개된 단계와 구현이 일치하는 미완성 범위다.

Goal·Board 두 갭과 이 후속 범위를 해결했다고 보고하지 않는다. 이번 추가 결과는 재현하거나
정확한 경합 경로를 확인한 세 기능 오류의 PR과, 남은 기능 범위를 명시한 이 보고서다.
