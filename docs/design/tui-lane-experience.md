# TUI Lane 경험 설계

여러 Lane이 각자 진행하는 모습을 비교하고, 관측에서 연결·설정·행동으로 이동할 수 있어야 한다.
이 문서는 구현 목표와 실행 검증 기준이다. 체크리스트 자체는 구현·배포·실측의 증거가 아니다.
사용법은 [TUI Lane Add-ons 가이드](../guides/tui-lane-addons.md)에 둔다.

## 개념과 디자인 출발점

사용자 제공 `lane-layer-matrix.html`은 공유 환경, 관측 소스, Add-on의 관계와 비어 있는 계층을 보여준다.
`lane-timeline.html`은 수평 Lane·수직 시간, 독립적으로 진행하는 작업, 명시적인 연결을 보여준다.
두 파일은 디자인 출발점이다. 그림 속 시간 소스·이벤트 전달·ticker와 설치 상태를 현재 제품 기능으로 단정하지 않는다.

하나의 환경을 여러 Keeper가 관측해도 각각의 Lane은 독립적이다.
Add-on이 공개하는 출력과 그 출력을 읽는 다른 Add-on은 연결될 수 있다.
하지만 같은 시각에 기록됐다는 이유만으로 원인·결과 관계를 만들지 않는다.
UTC 관측 시각과 source clock은 다른 좌표다. source clock의 domain과 원래 값을 보존한다.

## 참고한 TUI 패턴

| 공식 자료 | 적용할 판단 |
| --- | --- |
| [btop 기능과 화면](https://github.com/aristocratos/btop#features) | 전체 흐름과 선택 항목 상세를 함께 읽는다. 그래프에는 실제 측정값만 쓴다. |
| [lazygit 키바인딩](https://github.com/jesseduffield/lazygit/blob/master/docs/keybindings/Keybindings_en.md) | 화면 선택 키와 항목 이동 키를 구분하고 현재 맥락의 행동을 안내한다. |
| [tokio-console 문서](https://docs.rs/tokio-console/latest/tokio_console/) | 관측 데이터와 선택 항목 상세를 연결한다. 진행률을 모르는 작업에 임의의 진행 막대를 붙이지 않는다. |

오른쪽 열은 자료에서 도출한 MASC 디자인 판단이다. 해당 프로젝트가 Lane 계약을 제공한다는 뜻은 아니다.

[근거]

- Evidence: 위 공식 저장소와 API 문서를 직접 열어 확인.
- Timestamp: 2026-09-13T02:03:57Z
- Confidence: High (자료 확인), Medium (MASC에 적용하는 디자인 판단).
- Delta: 기존 설치 목록 중심 화면에 관측 비교와 연결 탐색을 첫 진입 경험으로 추가한다.

## 화면과 조작 계약

메인 `Lanes`는 standalone Lane 목록과 실행 상세를 유지한다. `A`는 Add-ons를 연다.
Add-ons 첫 진입은 현재 설치 목록이다. 설치된 이름·할 수 있는 일·최근 결과를 읽고
Enter로 선택한 항목을 연다. `h`는 현재 설치와 묶인 보존 이력을 전환한다.
실행 중·실패한 worker와 보존된 이력을 구분하고 조작 대상을 정확한 instance에 묶는다.
상세 화면은 `1` Results, `2` Links, `3` Installation, `4` Records이며
`Tab`도 이 순서로 순환한다. `D`는 선택한 결과·worker의 원문 상세를 펼친다.
`f`는 선언된 입력과 Add-on 층위 연결을 보여준다.

Results는 선택한 보고서·분석 본문을 먼저 보여주고 아래에 Activity timeline을 둔다.
완료된 관측이 아직 없는 경우, 완료됐지만 결과가 빈 경우, 받은 조회 범위에 결과가
없는 경우를 구분한다. 모델·입력 실패는 빈 결과나 정상 완료로 바꾸지 않는다.

Timeline은 Lane 열을 좌우로, 서로 다른 관측 UTC 시각을 위아래로 배치한다.
동일한 시각은 같은 행에 놓는다. 한 셀에 여러 사건이 있으면 개수를 표시하고 개별 선택을 허용한다.
`j/k`는 시간순 사건을 이동한다. `←/→`는 이웃 Lane에서 현재 시각 이상의 첫 사건으로 이동한다.
그런 사건이 없으면 해당 Lane의 마지막 사건을 선택한다. 이동한 시각을 상세에 명시한다.
줄 간격은 일정하며 duration·진행률·인과관계를 암시하지 않는다.

Lane 제목은 읽을 수 있는 local 이름을 먼저 보여주고 식별 정보를 덧붙인다.
전체 ID는 상세에서 확인한다. 선택 셀, event/value/relation 종류, 근거 선택 표시는 서로 구별한다.
긴 목록은 선택 위치를 따라 표시 범위가 이동하고 전체 대비 현재 범위를 보여준다.
색을 구분하지 못해도 문자·기호·제목으로 선택과 상태를 읽을 수 있어야 한다.

선택 상세에는 날짜를 포함한 UTC 시각, 원래 row ID, actor, subject, source clock, 필드를 표시한다.
`related_ids`만 관계로 보여주고 slice 밖 대상은 확인할 수 없는 대상이라고 표시한다.
Coverage는 complete·partial·unknown을 구분한다. 전체 slice 범위인지 선택 worker 범위인지 명시한다.
관측이 없거나 조회에 실패한 상태를 정상 종료나 완전한 관측으로 바꾸지 않는다.
새로고침 중 보존한 이전 데이터를 새 응답처럼 표현하지 않는다.

Links와 연결 보기는 선언된 외부 입력 → worker 층위 → named outputs를 보여준다.
같은 층의 항목은 서로의 출력을 요구하지 않으며, 후속 층은 확인된 생산자의 출력을 소비한다.
입력 미확인·모호한 생산자·없는 포트·순환 관계는 층위를 확정하지 않는다.
층위는 선언 구조이며 병렬 실행 성공이나 전달 성공을 뜻하지 않는다.
Browser 입력은 반환된 binding에 있는 mode·target·환경 정보를 표시한다.
선언된 연결과 실제 전달 기록은 구분한다. 연결만 보고 전달 성공을 표시하지 않는다.
설치 목록과 상세에서는 실제 capability와 action schema에 맞는 조작을 안내한다.
TOML 저장, worker 적용, action 접수, action 결과 확인은 각각의 결과를 읽을 수 있어야 한다.

`Space`는 Results와 Records에서 근거 행을 표시한다. 표시 수와 export 대상 인스턴스를 보여준다.
`e`는 선택한 인스턴스를 대상으로 근거를 내보낸다. 관측 Lane 선택과 인스턴스 선택을 혼동시키지 않는다.
설치·관측·행동·제거는 기존 기능에 연결하며 시각화를 위해 새로운 런타임 제약을 추가하지 않는다.
마지막 근거 영수증은 세션 기록으로 표시하며 보존 주체·선택한 행·대상 Keeper를 읽을 수 있어야 한다.
보존, Keeper 수락, Broadcast 저장, 열람, 실제 작업 활용은 별도 단계다.
다른 항목으로 이동해도 과거 영수증을 새 항목의 공유 기록으로 바꾸지 않는다.

## 실행 검증 증거 체크리스트

현재 구현 확인 위치는 `bin/masc_tui_lane_addons.ml`, `bin/masc_tui.ml`,
`bin/masc_tui_render.ml`, `bin/masc_tui_types.ml`이다.
아래 항목은 최종 검증 head의 실행 증거로 확인한다. 코드 읽기만으로 완료 표시하지 않는다.
일반 스택의 소스 승인에는 이 실행 체크리스트를 CI 게이트로 요구하지 않는다.
미해결 P0/P1/P2가 없으면 소스 리뷰를 승인하고 P3는 모아 처리한다.
Core 빌드와 Release/Tag 전체 검증의 실행 시점은
[MASC 개발 워크플로](../AGENTIC-WORKFLOW.md)를 따른다.

- [ ] 실행한 TUI에서 메인 Lanes와 `A` 진입, 설치 목록·묶인 이력·선택한 상세의 네 화면과 숫자·Tab 전환을 캡처한다.
- [ ] 여러 Lane, 같은 시각의 여러 사건, 다른 source clock을 포함한 Timeline을 캡처한다.
- [ ] `j/k`, `←/→` 전후 선택 row ID를 확인하고 좁은 터미널에서도 선택 셀이 보이는지 확인한다.
- [ ] 날짜가 바뀌는 관측과 긴 ID·한글 이름·긴 상세를 읽는다. 잘린 제목은 상세에서 확인한다.
- [ ] 빈 응답, 조회 오류, 새로고침 중 보존 데이터, partial·unknown coverage를 구별한다.
- [ ] slice 밖 관계를 표시하고, 시각이 같지만 관계가 없는 사건에 연결을 만들지 않는지 확인한다.
- [ ] 입력·worker·출력이 있는 Connections와 Browser binding 상세를 실제 화면에서 읽는다.
- [ ] Space 표시·해제, 선택 수, export 대상과 근거 영수증의 row ID가 일치하는지 확인한다.
- [ ] 설치 선언 편집·저장 결과, 적용 상태, 관측 결과, 지원되는 action 결과, 제거 대상이 일치하는지 확인한다.
- [ ] 일반 스택의 최종 head 소스 리뷰와 남은 실행 검증 범위를 기록한다.
- [ ] Release/Tag 검증에서는 최종 head의 Full CI Cycle과 관련 runtime 결과를 확인한다.

실행 증거에는 commit, 바이너리 출처, 터미널 크기, 데이터 출처, 조작 로그와 화면을 함께 남긴다.
Fixture로 실행했다면 명시한다. Fixture 화면은 실제 환경의 worker 실행을 증명하지 않는다.
CI 통과, 실제 TUI 화면, GitHub 병합 상태는 각각 확인해야 한다.
