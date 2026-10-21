# 전체 후속 작업 목록 · 2026-10-21

총 **60개**: 기존 Addon/Lane·Browser 작업 **54개(A–H)** + 이전 대화의 공통 후속 **6개(X)**.
기존 A01–H06 식별자는 유지한다. 이 수는 완료 건수나 완료율이 아니라 추적할 작업 범위다.

범위: 기존 Lane의 Addon 분리, 공통 연결 구조, Browser 기능, 에이전트 도구·Skill 접근,
Dashboard·TUI 관측, 실제 사용·복구·설치 검증과 이전 대화의 Pele·빌드·성능·Ollama·PR 운영 후속.
이미 구현된 기능은 다시 만드는 대신 남은 적용·검증 범위를 적었다. X의 저장소 전체 후속과
A의 이번 Addon 변경 닫기는 대상 범위가 다르며, 같은 수정이나 실측은 두 번 완료로 집계하지 않는다.

| 영역 | ID | 작업 수 |
| --- | --- | ---: |
| 현재 Addon 변경·검증·통합 | A01–A06 | 6 |
| 공통 연결·소유권·수명 | B01–B06 | 6 |
| Plugin·Deferred Tools·Skill·Hook | C01–C06 | 6 |
| 모델 route·Exact Output | D01–D06 | 6 |
| 기존 Lane·패키지별 추출·실사용 | E01–E12 | 12 |
| Browser 전체 행동군·engine 선택 | F01–F06 | 6 |
| Dashboard·TUI 관측·조작 | G01–G06 | 6 |
| 실제 앱·실패 복구·연속 사용·설치 | H01–H06 | 6 |
| Pele·빌드·성능·Ollama·PR 운영 | X01–X06 | 6 |
| **합계** | | **60** |

## 최초 기록의 기준점 (아래 재개 체크포인트에서 상태 갱신)

- 공통 관측 구현 [#44707](https://github.com/jeong-sik/masc/pull/44707):
  `566b98b5d1645d6312d518bf2810f3e5e0626586`. 서버 application/source revision/runtime presence를
  Dashboard가 보존하고, TUI에서 retained worker의 새 Observe/action 및 오래 열린 메뉴 제출을 거절한다.
- 관측 증거 [#44709](https://github.com/jeong-sik/masc/pull/44709):
  `cc4529a905bb66db977785ee61894bea00d16ac1`.
  실제 Docker/MCP worker를 Dashboard에서 On → Off → On으로 조작했고,
  이전 관측 보존·새 incarnation·새 입력 결과를 확인했다. 입력은 synthetic phrase snapshot이다.
- Dashboard 8개 suite 145건 및 TypeScript 검사 통과. OCaml은 parser 검사만 수행했다.
  두 PR의 독립 source/evidence 검토는 PASS이며, 정식 GitHub 승인·병합·설치와 구분한다.
- 위 두 PR과 A03 수정 #44721, 경계·작업표 #44726은 Native Stack #44710의 4개 층이며, 2026-10-21 06:45:33–37 UTC에 모두 main으로 병합됐다. CI 개선 #44727·changelog #44731은 별도 Native Stack #44732다.
- Browser Addon의 기존 6개 요구사항은 구현 및 범위를 고정한 분리 실측을 마쳤다.
  Deferred Tools·Hook 선택·host Exact Output도 그 범위에 포함된다.
  기존 완료 영수증 이후 Native Stack #44168이 67층으로 늘었으며,
  현재 마지막 PR은 [#44702](https://github.com/jeong-sik/masc/pull/44702),
  head `d35d2559c56814b38615545a5f4f081304bccc05`이다 (2026-10-21 재개 조회).
  기존 완료 기록의 #44653은 현재 64번째 층이다. 최신 추가 3층과 전체 통합을 별도로 재판정해야 한다.
- MSX/DOS는 이미 별도 worker Addon이다. Fusion 패키지도 존재한다.
  VST Phrase는 현재 관측 패키지이며 실제 VST/audio 실행 소유와 구분한다.
- Standalone model Lane은 Librarian, HITL Auto Judge, Board Attention, Workspace Curator,
  Verifier, Browser Stagehand, Candle Appraiser의 7종이다.
  Board Attention과 HITL Auto Judge는 현재 Required다. Addon 포장 여부와 필수 서비스 의무를 분리한다.

상태 표기는 실제 완료 근거를 따른다. `구현됨·검증 필요`는 미구현과 다르고,
`접수/진행`은 성공 판정이 아니다. 아래 우선순위는 실행 순서이며 결함의 P0/P1 심각도 등급이 아니다.

## A. 현재 변경을 닫기 — 6개, 가장 먼저

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| A01 | 변경 TUI의 최소 검사와 정확한 소스의 실행 artifact 확보 | 고정 d9 native24+5건·matching identity 성공 유지. e6 Keeper 오류·main4d25 TUI warning4로 각각 FAIL. 기존 #44864 및 #44874/#44875 수리를 재사용한003f52 native39625447860 접수; 결과·matching artifact 미확인 | `test_tui_lane_addons`·직접 관련 application 검사 결과, 실행 artifact의 source/build identity 확보 |
| A02 | 새 TUI로 On/Off/재연결 실제 화면 관측 | 고정 7b16a917 실제 On→Off→On에서 retained refresh 결함 재현. 고정 d9b62724 실제 TUI에서 원래 row/selection·읽기 실패·실제 Evidence receipt 공존, 잘못된 run 입력 거절·복구·same-run empty 관측. lifecycle 수리·운영 설치·같은 후보 Dashboard는 별도 | 같은 설치의 이전/새 incarnation, 정리 상태, 원래 결과·receipt를 실제 화면과 API로 확인 |
| A03 | retained worker에 남는 Observe/Action 키 안내 정리 | #44721 main 병합. 고정 `7b16a917` 실제 TUI에서 retained 실행 키 미노출·수동 Observe 거절·이력 진입 확인; 전체 상세 새로고침 결함은 A02/G06에서 별도 추적 | 표시 가능한 행동과 실제 요청 허용 조건이 일치; 이력 조회·정리 조치는 보존 |
| A04 | MASC 코드·맥락 리뷰 대응 및 현재 head 판정 확인 | 공통 #44710·G01 #44803 및 G06 #44840의 6개 층 main 병합 확인. G06 병합 head와 이후 fragment-only branch head를 구분. Browser #44168 전체 현재 판정·남은 맥락 리뷰와 새 follow-up head의 재승인은 별도 | 실제 verdict를 읽고 P0–P2 해소, 바뀐 head/base/diff에 재결속 |
| A05 | Browser 스택의 후속 3개 층과 기존 증거 영향 검토 | 세 층의 전체 delta 직독; exact `76b741f` run `39555413943` 두 suite 14건 PASS, 독립 source delta 검토 PASS; 실제 앱·전체 스택 검증 별도 | #44695·#44698·#44702의 reply/download 정책 변경을 읽고 영향을 받는 경로만 검증 |
| A06 | 두 스택의 전체 통합 준비 | 공통·G01·G06 main 병합. Browser67층 d35는 현재 head/base/diff 결속 승인29, 부재/과거승인38; REST #44192 dirty. whole-stack 현 main 재배치·일괄push를 pr-updater에 요청(queued), 실제 수행 미확인. 증거 #44851도 open | REST stack 구성·각 head·독립 승인·미해결 리뷰·충돌 재확인; 병합은 전체 스택의 맨 위 PR로만 진행 |

빌더 요청: `kmsg-2ada1cdc54884c58aa6736a80b598868`는 기존 `566b98b` 대상이다. 후속 exact 후보 `7f9e34b`는 native run `39555509454`로 요청했다. 중복 시작을 피하도록 빌더에게 대체 안내 `kmsg-1974c332ed1abfed8b4bde992b686e8f`를 보냈으며 안내 접수는 원래 작업 취소·실행 여부의 증거가 아니다.
코드 리뷰: `kmsg-f7fecd527b3870306df62a4079c30ad8` 완료 및 #44707 review `5595612747` APPROVED 직독. head `566b98b5d1645d6312d518bf2810f3e5e0626586`, reviewed base `b95d927e30c6718e0fe656d3019c6cf39766c02c`, diff `ff95fe2ecb2658cee6da5b251d2b119c825270116c978246de762b5374e336c2`. 한 층의 소스 승인이다. #44721 후속 요청 `kmsg-dc966b86727baccd78eaa31700ef384e`는 queued 접수다.
맥락 리뷰: `kmsg-c21fe89d785931223c73349f52b88475` (queued).
이는 해당 조회의 요청 상태이며 검사·승인 완료를 뜻하지 않는다.

## B. 공통 연결 구조 — 6개

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| B01 | 각 Lane의 입력·판정·효과·저장소·자원 소유 경계 작성 | 실제 인터페이스·호출자 경계 문서 작성, 독립 source/response 검토 PASS; 적용·통합 별도 | 옮길 실행과 host에 남을 authority를 실제 `.mli`/호출자에 연결 |
| B02 | 기존 등록·호출 경로로 연결을 통일하고 중복 glue 정리 | 기존 기반 있음 | 새로운 도메인마다 server 분기·중복 singleton·별도 registry를 추가하지 않고 필요한 typed port로 연결 |
| B03 | 설치 ID·instance·incarnation·request·revision·run 연결 일관화 | 일부 구현 | 원래 대상·결과를 조인할 수 있고 교체 worker에 이전 권한/응답을 넘기지 않음 |
| B04 | Off·Detach·Drain·Cancel·실제 정리의 의미를 통일 | 기존 lifecycle 있음 | 새 호출 중지와 진행 중 호출의 종료/불확실 상태, 자원 정리 완료를 각각 기록 |
| B05 | 상태·자원 소유권 및 다른 workspace/설치와의 분리 검증 | 기반 있음 | profile/process/container/volume/artifact의 정확한 owner만 해제; 보존 상태의 재연결 정책 명시 |
| B06 | 설정·패키지 교체와 잘못된 계약의 적용 경계 정리 | 기반 있음 | 검증 전 실행 없음, 원래 revision 보존, 불완전 목록으로 제거하지 않음, 실패/미확인 표시 |

원장 반영, Task/Goal 상태 전이, 승인, 최종 정산, credential과 artifact 권한은 host가 소유한다.
어떤 Lane이 Required인지는 별도 제품 계약으로 유지한다. 모든 것을 임의로 끌 수 있게 바꾸지 않는다.

## C. Plugin 사용성과 에이전트 접근 — 6개

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| C01 | 패키지 발견·설치·활성화·비활성화·제거 흐름 통일 | 공통 경로 있음 | 같은 manifest/declaration을 API·Dashboard·TUI가 사용하고 저장/적용/관측 결과를 구분 |
| C02 | Deferred Tools를 다른 Addon에도 실제 적용 검증 | Browser 범위 구현·검증 | 검색→원래 schema 로드→같은 Agent에서 호출, 설치 없을 때 미노출 |
| C03 | 끄기·교체 뒤 tool inventory 갱신과 기존 호출 처리 | 기반 있음 | 신규 발견은 갱신되고 이미 시작된 호출은 원래 소유자/receipt로 종료; 오래된 export로 새 실행 불가 |
| C04 | 번들 Skill·본문·참조·스크립트의 발견과 해제 검증 | 기반 있음 | 설치별 정확한 Skill reference·revision으로 읽고 해제 뒤 새 discovery에서 제외 |
| C05 | 입력 Hook과 출력 Hook의 독립 선택·적용 검증 확장 | Browser 범위 구현·검증 | 선언·override·off 조합이 실제 호출에 반영되고 원래 효과/실패 정보 보존 |
| C06 | 필수 authority 검사와 선택 Hook을 분리 | Browser 경계 있음 | Hook을 꺼도 caller·workspace·incarnation·권한·결과 기록 검사가 유지됨 |

## D. 모델·Exact Output 연결 — 6개

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| D01 | Addon별 모델 route와 기능 활성화의 독립 선택 검증 확장 | Browser broker 있음 | LLM 없는 동작은 독립 실행되고, 설치/출력별 선택 모델이 실제 호출에 반영 |
| D02 | 기존 요청별 schema grant를 Candle에 재사용하는 계약 확정 | [#44768](https://github.com/jeong-sik/masc/pull/44768)·[#44769](https://github.com/jeong-sik/masc/pull/44769)에 원래 요청 identity·grant·완전 domain decode·terminal unknown 처리 source 구현. 독립 source/response 검토 PASS; OCaml 실행 검사는 아직 미완료 | `Consumer_request_schema` 권한·package baseline·요청 digest 재사용; Grade enum·keeper 집합·weight 상한은 Candle 완전 domain decode로 검증 |
| D03 | 모델 호출 전 요청 보존 및 원래 identity 결속 | 기반 있음 | request·stage·input·schema·route·trace를 보존한 뒤 한 번 dispatch |
| D04 | 오류·거절·불확실 결과의 typed 처리 일관화 | 도메인별 차이 있음 | transport 불가/잘못된 출력/실행 거절/효과 불확실의 재시도 의미를 유지 |
| D05 | credential·provider admission·동시 실행 권한을 host에 유지 | Browser 검증 있음 | worker/child에 비밀 유출 없음; 실제 provider별 queue·취소·동시성 동작 확인 |
| D06 | 설정 교체·detach 중 늦은 모델 응답 처리 | Browser 범위 검증 있음 | 원래 요청의 terminal 증거를 보존하고 새 worker에 오적용하거나 같은 효과를 재생하지 않음 |

Fusion 패널 답변은 기존 free text 계약을 유지한다. 모든 Lane의 결과를 임의로 Exact JSON으로 통일하지 않는다.
Browser 최신 스택에는 요청별 schema와 부분 shape 검사가 이미 있다. 이 기반이 main에 통합됐다고
가정하지 않으며, Candle의 완전한 schema/domain 검증을 대신한다고도 보지 않는다.
Browser Stagehand는 기존 Addon 모델 경로를 B01·D01/D06·F에서 재사용·재검증한다.
별도의 중복 Stagehand 실행기를 만드는 작업으로 잡지 않는다.

## E. 기존 Lane·패키지별 작업 — 12개

| ID | 대상과 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| E01 | Candle Appraiser 판단 실행을 Addon으로 추출 | 실제 eb484 host에서 초기 attach 계약 오류 재현·#44911 worker 수리. 실제 Verifier Task/Goal→Off 원래 Owed 보존→On 실제 provider Grade/Relation/Weights→Paid 1건→다시 Off/On 후 3결과·원장 바이트 동일 실측. native eb484+worker b427 혼합 조건. native #44168 68/68 편입 확인. 승인·운영 설치와 나머지 오류 경계는 별도 | Grade/Relation/Weights와 typed 오류·trace 유지; 원장·중복 정산 방지는 host; Off 뒤 obligation 보존 및 재연결 후 정산까지 확인 |
| E02 | Workspace Curator의 모델 실행·작업 수명 추출 | exact866의8-suite126건·generic observer cf7의52건·typed observer28b5의4-suite65건 실제 PASS. 실제 eligibility conflict wrapper 수리를 af699에 반영하고 독립 소스 재검토 PASS, 새 선택39686436649 4-suite68건 실제 PASS. production 재시작 전 complete forest 검증·기존 child intent local 복구 #44974의4af20 4-suite76건 실제 PASS, 최종641 정식 소스 승인. public owner 전환·fresh Runtime admission·실제 Python/MCP/Exact loopback fixture 소스 후속 중. 같은 commit_plan을 settlement/관측에서 재사용하고 unknown timing/extended usage는 부재로 보존. 새 production compiled 실행·registry reconcile/delivery·실제 provider/두 UI/설치는 남음 | fact intake·batch·briefing의 durable 상태와 commit 권한을 유지하며 중지·재개 확인 |
| E03 | Librarian 실행의 Addon 경계 검토·추출 | 조사·설계 | checkpoint·absorption·memory lineage·pending 작업을 보존하고 Keeper 기억 연속성 검증 |
| E04 | HITL Auto Judge 실행의 Addon 경계 검토·추출 | 조사·설계, Required | 승인 요청·판정 권한을 host에 유지하고 필수 판단 기능의 가용성 계약 보존 |
| E05 | Board Attention 실행의 Addon 경계 검토·추출 | 조사·설계, Required | durable candidate→판단→전달/소비·quarantine·복구 의미와 필수 서비스 계약 보존 |
| E06 | Verifier 실행의 Addon 경계 검토·추출 | 조사·설계 | 증거 검증과 Goal/Task 최종 전이를 분리하고 위조·이전 실행 증거 오적용 없이 재개 |
| E07 | Fusion compute/results/report의 실제 조합 사용 검증 | 패키지 존재 | native/container/provider 계산·원래 run·immutable 결과 연결·명시적 전달·실제 Agent 읽기 확인 |
| E08 | MSX/DOS의 설치·상태 복원·실제 게임 사용 검증 | 별도 worker·image 검증 있음 | `msx-machine`·`dos-machine`·`dos-world`의 설치 On/Off/교체·명시적 checkpoint 복원·기존 media/save 보존과 실제 화면/입력 확인 |
| E09 | Voice·VST 실행 소유 경계 분리 | VST는 관측만, Voice는 설계 필요 | TTS/STT/realtime/session/player/device 수명과 결과·오류를 분리; 실제 입출력과 해제 정리 확인 |
| E10 | Slack/Discord Connector의 선택적 Addon 경계 정리 | 조사·설계 | polling/cursor/subscription/인증/재접속·중복 전달 방지·host 메시지 권한 유지 |
| E11 | Web Search의 provider·cache·credential 경계 추출 | 조사·설계 | 실제 검색/fallback/취소/출처 보존; provider credential을 host에 유지 |
| E12 | 나머지 패키지의 공통 계약 적합성·실사용 점검 | 패키지 존재 | output-statistics, value-difference, frame-progress, web-project, wkbl-score-runs, operator-quiz, msx-observer의 설치/도구/Skill/출력 연결을 실제 검증 |

E03–E06은 무조건 모두 외부 프로세스로 옮긴다는 확정안이 아니다. B01 조사 후
모델 실행과 host authority를 분리할 실익·수명 계약을 확인하고 각 추출 범위를 확정한다.
단순 wrapper를 만들어 기능 전체를 떼어냈다고 부르지 않는다.

## F. Browser의 기능 범위 — 6개

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| F01 | Firefox/Chrome/Safari와 연결 방식의 능력 표 및 자동 선택 | 부분 구현, 후속 필요 | 필요한 동작·실제 연결·profile/세션 권한으로 선택; 미지원은 명확히 표시하고 임의 중복 세션을 만들지 않음 |
| F02 | 탭·창·context·이동·frame/shadow DOM 경계 검증 | 기존 구현 있음 | 새 탭/전환/닫기·navigation·frame 전환에서 원래 target identity와 문서 상태 보존 |
| F03 | 포인터 행동의 완성도와 좌표·대상 정확성 검증 | 기존 hover/drag 경로 있음 | hover, click, double/right click, down/up, drag/drop을 실제 UI 변화로 확인; stale 좌표 거절 |
| F04 | 키보드·텍스트·스크롤·확대축소의 일관된 지원 | 전수 확인 필요 | focus, 입력/선택/편집, 조합키/IME, 영역 스크롤, zoom 및 화면 좌표 변환 확인 |
| F05 | 파일·클립보드·dialog·popup·권한 상호작용 범위 점검 | 파일 일부 실측 있음 | upload/download와 artifact 보존, clipboard, dialog, popup, browser 권한 화면의 지원/운영자 개입 경계 명시 |
| F06 | Browser 읽기·진단·출력 기능의 능력별 점검 | 일부 구현 | screenshot/PDF, console/network, cookie/storage, history·성능 관측 등을 engine별로 검증; 미지원 기능은 성공으로 응답하지 않음 |

Browser의 기존 완료 범위는 [기존 범위의 공개 증거 영수증](https://github.com/jeong-sik/masc/pull/44653#issuecomment-6308198140)에 있다.
Safari 및 넓은 행동군 후속은 기존 #44023과 연결해 중복 구현을 피한다.
위 목록은 모든 브라우저가 모든 프로토콜 기능을 동일하게 제공한다는 보장이 아니다.

## G. Dashboard·TUI 관측 — 6개

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| G01 | 패키지·설치·worker·모델·도구·Skill의 연결을 한곳에서 보기 | Stack #44803의 #44801·#44802·#44830 main 병합 확인(770ca204·912f1108·1a8c3744). host application 연결과 historical62/후속92건 증거 구분 보존. 새 main 조합의 native/UI·설치 증거는 별도 | 원하는 설정/실제 적용/연결 존재/실행/관측 준비/실패를 구분하고 원래 상세로 이동 |
| G02 | 입력→Hook→worker→모델→출력/소비자의 연결 관계 표시 | 일부 Flow 있음 | 실제 연결 reference에 근거해 표시; 관측 그래프를 실행 허가로 사용하지 않음 |
| G03 | 요청부터 종료·정리까지 원래 timeline/trace 연결 | Candle 동일 종단 재조회가 elapsed를 덮는 실제 결함을 #44920에서 수리: 첫 receipt 보존·실패 append 재시도·읽기 불가 payload 보존. source 독립 PASS, exact b8a160 선택 검사 transport10+contract2+flow24 합36건 PASS. 부분 구현; Dashboard가 버리던 host_requests를 원래 worker/incarnation에 결속해 보존·표시하는 후속 구현. 모델 lane/provider/operator/source 대기와 전달·기록 실패를 닫힌 타입으로 읽고, 손상 진단은 worker·결과와 분리. 전체 요청 이력·실제 화면·설치 검증 필요 | request/run/instance/revision, 대기 이유·결과·실패·정리 증거를 같은 원래 작업으로 추적 |
| G04 | 교체·경로/ID 변경·이전 소유자 이력 표시 | 후속 소스 구현: 같은 ID worker와 같은 TOML 경로의 다른 ID를 두 UI에서 분리. Dashboard 3파일62건·tsc PASS, TUI 관측 모델 parser PASS; 독립 리뷰·OCaml 실행·실제 UI 별도 | 새 worker와 과거 worker 구분, 다른 ID의 같은 파일 이전 owner 정리 기록도 별도 접근 |
| G05 | 에이전트 작업 중 표시와 현재 포인터/입력 활동 표시 | 범위별 재확인 필요 | 실제 동작 이벤트 기반으로 작업자·활동·포인터 위치 표시; 완료·중단·해제 때 표시 정리 |
| G06 | 두 UI의 편집·새로 읽기·부분 실패·workspace 변경 일관화 | d9의 run-scope 거절·원래 결과/실패/영수증·복구·same-run empty 실측 유지. global-query 수리 main 포함이나 수리 후보 두 native는 별도 컴파일 오류로 FAIL. 기존 TUI 수리 포함003f52 native 요청; corrected HTTP/화면·모든 경계 미완료 | draft·원래 receipt 보존, 늦은 응답 거절, stale/unknown 표기, 화면에서 복구 경로 사용 가능 |


G04 후속 [#44807](https://github.com/jeong-sik/masc/pull/44807) · 다른 설치 ID의 같은 TOML 경로

기존 connection detail은 같은 installation ID의 worker만 골랐다. TOML 파일에서 ID를 바꾸면 같은 경로의 예전 소유자와 정리 실패가 이 관련 상세에서 빠졌다. Dashboard는 같은 ID의 worker 목록을 유지하고, 같은 source_path에 있는 다른 설치 ID의 기록을 별도 펼침 영역으로 보여준다. TUI는 같은 read-only 분류 모델을 사용한다. 각 기록은 실제 installation ID·instance·incarnation·revision·phase·관측 sequence를 보존한다.

같은 ID는 경로 이동 후에도 같은 그룹이고, 다른 ID는 source_path가 정확히 같을 때만 별도 관계로 남는다. 제목·run·package나 파일 basename으로 연결하지 않는다. Manual attachment는 같은 instance/incarnation만 읽으며 None 경로끼리 연결하지 않는다. 다른 ID의 기록은 현재 선언의 application이나 실행 권한을 대신하지 않는다. 생성 시각을 추정해 이전/이후라고 단정하지 않으며 별도 설치 소유자로 표시한다.

실제 완료한 검사: Dashboard `lane-addon-connection`, `lane-installation-manager`, `lane-addons-panel` 3파일62건 PASS, `pnpm exec tsc --noEmit` PASS, 변경 ML/MLI3개 parser PASS. TUI 새 검사는 원래 관측 모델의 그룹 membership·incarnation·retained 실패를 확인하며 화면 문구·배치 assertion을 추가하지 않는다. 이 OCaml 테스트 실행과 실제 TUI/Dashboard 화면 검증은 아직 없다. 기존 G01 스택과 실행 후보를 이 G04 소스 증거로 대체하지 않는다.


## H. 실제 사용·운영·배포 검증 — 6개

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| H01 | 같은 후보의 API·worker·Dashboard·TUI 조합 검증 | 일부 분리 실측 | On/Off와 Remove TOML+worker→재설치를 구분해 실행; 정확한 source/build 조합을 기록하고 서로 다른 증거 층을 합쳐 완료로 세지 않음 |
| H02 | 실제 LLM·실제 앱에서 작업 완주 | Browser 모델 일부는 scripted | fixture 검증과 구분해 실제 Agent의 discovery→Skill→선택→실행→결과 확인을 수행; hover toolbar/drag 등 원래 증상 해결 확인 |
| H03 | 실패·중단·재시작·설정 교체 복구 검증 | 부분 시나리오 있음 | 실행 중 Off, 지연/유실 응답, 부분 생성, 죽은 worker, 정리 실패·engine 변경·lease 거절에서 중복 효과/잘못된 삭제 없이 복구 |
| H04 | 반복 연결과 장시간 연속 사용 검증 계획·실측 | 후속 실측 계획 | 제품의 10턴 이상·1/2/4/24h+ 목표에 연결한 시나리오·실측 범위를 정하고 연속성·누수·복구 근거 수집; 매 작은 PR에 전체 장기 검증을 반복하는 gate로 삼지 않음 |
| H05 | 반응 속도·자원·동시 작업 영향 측정 | 후속 실측 | 동일 작업 조건의 전후 latency·queue·CPU·memory 및 TUI/Dashboard 반응을 측정; 다른 Keeper 영향 확인 |
| H06 | 사용 안내·최종 통합·설치 후 확인 | PR 단계 | manifest/예제/운영·개발 가이드 갱신, 승인된 스택 통합, 선택된 실제 설치본의 identity 및 UI 재확인; Release/Tag라면 해당 전체 검증 별도 수행 |

## X. 이전 대화의 공통 후속 — 6개

이 영역의 오래된 보고서는 당시 기록이다. 이번 목록 작성에서 live 설정·현재 main 빌드·전체 PR을
새로 전수 검증하지 않았다. 현재 확인하지 않은 증상을 진행 중인 확정 장애로 표시하지 않는다.

| ID | 남은 작업 | 현재 확인 범위 | 완료 기준 |
| --- | --- | --- | --- |
| X01 | Pele 기반 TUI diagram/chart 도입 범위와 실제 사용 완성 | 현재 로컬 main 소스에 `masc_tui_pele.ml`, `Ctrl-O` preview와 설치 안내가 있음. 최초 도입을 다시 하는 작업은 아님 | 설치본의 renderer/helper identity, 실제 Mermaid 입력→이미지 표시, terminal 폭·theme·오류 처리, 지원 diagram/chart 종류와 미지원 경계를 확인. 속도·bundle 수치는 실제 동일 조건 측정 후 기록 |
| X02 | 현재 main의 빌드 고장 및 후속 인터페이스·의존성 오류 수리 | 과거 컴파일 오류 수리 보고서 존재. A01은 이번 Addon TUI 후보에 한정; 현재 main 전체 빌드 성공은 이번에 미확인 | 최신 main 최소 빌드의 실제 실패 로그를 기준으로 수리하고 직접 소비자를 확인. source/parser, 최소 실행 파일 빌드, Release 전체 검증을 구분하고 설치본에서도 대상 명령 시작 확인 |
| X03 | TUI·Dashboard 공통 로딩·채팅·새로고침 지연 개선 | 이전 관련 조사 있음. 새 후보의 설치·동일 조건 실측은 별도 | 같은 서버에서 HTTP refresh·observer SSE·Dashboard 경로, queue와 처리 시간을 함께 측정하고 병목별 전후 결과를 비교. UI 한쪽의 성공을 다른 쪽의 복구로 간주하지 않음 |
| X04 | Ollama Cloud 동시성 4 및 foreground/background 공정성의 실제 효과 확인 | 10/19 보고서에 2→4 적용과 queue 지배 지연 기록. fairness 구현 PR 기록은 있으나 이번 live 설정·설치 여부는 미확인 | 현재 설정·실행본을 읽고 Keeper의 대기/첫 응답/도구 후속/최종 응답과 Librarian 진행을 함께 측정. tool-only 응답과 진짜 빈 completion, provider 오류를 구분. 동시성 상향만으로 복구 완료 판정하지 않음 |
| X05 | pr-updater·assignee·reviewer 요청의 실제 처리 상태 관측과 복구 | 사용자가 반응 지연을 제보. 이번에는 worker별 live 상태 미조사 | 원래 요청 ID로 queued→실행→응답/실패를 추적하고 미배달·정지·권한·용량 대기를 구분. 처리 주체·다음 조치·응답이 Dashboard/TUI에서 보이고 중복 재요청 없이 회복 |
| X06 | 저장소 전체 PR의 리뷰 대응·충돌·Ready 재점검 | 과거 전체 sweep 보고서 다수. 이번 REST 확인은 Addon 관련 지정 PR에 한정 | 현재 open PR 전수 목록과 REST stack을 읽고 최신 head/base/diff, 미해결 리뷰·충돌·draft 상태를 정리. 필요한 대응과 독립 재리뷰를 수행하고 Native Stack 전체 단위로 통합 가능 상태 기록; 병합·배포는 별도 결과로 기록 |

참조(로컬 전용·Git 미추적 자료이며 이 PR의 공개 artifact가 아님):

- 과거 빌드·TUI 대응: `/Users/dancer/me/workspace/yousleepwhen/masc/reports/tui-build-ux-response-20261019.md`
- Ollama 동시성 변경: `/Users/dancer/me/workspace/yousleepwhen/masc/reports/ollama-concurrency-4-20261019.md`
- DeepSeek 지연 분석: `/Users/dancer/me/workspace/yousleepwhen/masc/reports/ollama-deepseek-contention-analysis-20261019.md`
- Fairness 구현·검증 한계: `/Users/dancer/me/workspace/yousleepwhen/masc/reports/ollama-admission-fairness-implementation-20261019.md`

외부 검토에서 읽을 수 없는 로컬 기록을 공개 실행 증거로 취급하지 않는다. X 항목을 실제로 수행할 때
현재 상태를 다시 확인하고 필요한 근거를 비밀정보가 없는 공개 PR 자료로 연결한다.

## 권장 순서와 완료 정의

1. X02에서 실제 확인된 main 빌드 장애가 있으면 먼저 좁혀 수리한다. A01–A06으로 현재 관측 변경의 실행·Browser 추가 범위·통합을 닫는다. 검사 대기 중에는 독립 작업을 진행한다.
2. B01–B06에서 host authority와 실제 실행의 경계를 확정하고, C/D의 기존 공통 경로를 재사용한다.
3. 첫 실제 추출은 E01 Candle Appraiser를 기준 사례로 삼는다. D02에서 기존 요청별 schema grant를
   재사용할 범위와 Candle의 host decode·실행 추적 계약을 먼저 확정한다. 필요한 Browser 공통 기반의
   통합 또는 명시적인 스택 의존성을 기록하고 새 중복 broker를 만들지 않는다.
4. Candle에서 On/Off/재연결/새 판단/중복 없는 정산을 G/H 화면·증거까지 완주한 뒤 E02 Curator로 확장한다.
5. E03–E12는 의존성과 효과 소유권에 따라 별도 작은 스택으로 진행한다. Browser F와 공통 G는 독립적으로 병행 가능하다.
6. X01/X03–X06은 별도 변경 단위로 진행한다. 이 목록 작성만으로 live 설정 변경, 서버 교체, browser profile 재생성, 전체 PR 병합을 실행한 것으로 보지 않는다.
7. 각 대상을 `구현 → 독립 리뷰 → 최소 실행 → 실제 화면/결과 → 통합 → 설치본 확인`으로 나누어 기록한다.

**대상별 완료:** 설정 저장, 실제 적용, worker 준비, 새 작업 성공, 원래 결과 보존,
Dashboard·TUI의 원래 근거 표시를 각각 확인한다. Optional은 Off 후 정리와 On 후 새 incarnation의
성공을 확인한다. Required는 필수 서비스 의무를 보존하는 교체·drain·복구 및 미처리 작업 승계를
확인한다. Required 서비스를 임의로 Off 할 수 있게 바꾸는 것은 이 계획의 완료 조건이 아니다.
설정 스위치·테스트 PASS·요청 queued·단일 happy path를 전체 기능 완료로 대신하지 않는다.

## 2026-10-21 구현 후속

- A03: #44721, head `7f9e34bab08484124bb18a477ecb5e5ba0fb5769`, base `cc4529a905bb66db977785ee61894bea00d16ac1`. retained/unknown worker의 실행 키 안내에 handlers와 같은 `can_observe`를 사용한다. 이력·정리·원래 receipt 조회를 보존했다. OCaml parser와 diff 검사 PASS; 독립 source/response 리뷰 PASS. 후속 native artifact 게시를 확인했지만 새 TUI 실제 화면 증거는 아직 없다.
- B01/D02 경계 문서: [lane-addon-extraction-boundaries.md](https://github.com/jeong-sik/masc/blob/959eda39beb54bd1111e3d71aa2520822545bd82/docs/design/lane-addon-extraction-boundaries.md). 현재 소스와 unmerged Browser 의존성, 옮길 실행/host authority, Candle의 단계별 요청 identity 및 typed 불확실 결과의 빈 경계를 명시했다. 문서가 실제 추출 완료를 뜻하지 않는다.
- #44707 코드 리뷰의 추가 P3는 G01에 보존한다. 단일 PR 승인을 전체 Native Stack 승인으로 확대하지 않는다.
- A01: [native run 39555509454](https://github.com/jeong-sik/masc/actions/runs/39555509454), source `7f9e34bab08484124bb18a477ecb5e5ba0fb5769`, workflow `cccb1fc4808435ed06ece3e586095f37d8dd449c`, scenario `addon-lifecycle`. 별도 CI PR #44727의 두 독립 source 검토는 최종 head PASS다. 두 기존 suite와 matching server/TUI/key generator를 선택했으며 초기 조회에서는 syntax job 성공·native job 실행 중이었다. 재개 시 완료 로그와 artifact를 직독한 결과 native job `119074243862`는 컴파일 FAIL이며 artifact `12325452640`에는 `build-targets.txt`·`build.log`만 있다. 실행 바이너리·성공 receipt는 없다. 기존 TUI suite는 presentation assertion도 포함하는 mixed suite다. artifact 생성은 실제 화면 검증과 구분한다.
- A05: #44695 전체 delta는 built-in/Addon action reply 정책 공유, #44698은 session/navigation 정책까지 같은 `Browser_lane.reply_timeout_sec`로 연결한다. #44702는 download의 remote claim 보유자를 무한히 기다리지 않고 local preparation만 join하며, 남은 claim이 있으면 파일·grant 상태를 보존한 sticky cleanup 실패를 남긴다. 입력 행동군이나 Safari 지원을 추가한 변경은 아니다.
- A05 실행 요청: [run 39555413943](https://github.com/jeong-sik/masc/actions/runs/39555413943), source `76b741f8816f074249baef3166ca152d9c9d2c13`, `minimal=true`, `eio_backend=posix`, suites `test_browser_addon_reply_policy,test_browser_addon_downloads`. 기존 28-case 영수증을 최신 변경의 성공으로 재사용하지 않고 두 영향 경로만 새로 선택했다. 완료된 job `119073936227` 로그를 직독해 exact source와 `MINIMAL_CHECK=true`, 두 selected suite, `TARGET_EIO_BACKEND=posix`를 확인했다. reply policy 1건·downloads 13건, 총 14건 PASS다. 실제 브라우저·provider·전체 회귀 실행은 이 두 suite의 범위가 아니다.

## 재개할 때 읽을 자료

- 공통 관측 소스/증거: #44707, #44709 / Native Stack #44710.
- Browser 기존 완료 및 한계: [#44653 공개 영수증](https://github.com/jeong-sik/masc/pull/44653#issuecomment-6308198140). 이 영수증은 이전에 고정한 실행 범위이며 현재 67층 전체의 실행 증거가 아니다.
- 현재 Browser 후속: #44695, #44698, #44702 / Native Stack #44168.
- 실제 On/Off/재연결 기록: `docs/evidence/2026-10-21-addon-reconnect/` (공통 관측 worktree/PR).
- 공통 계약: `lib/lane_addon/`, `docs/guides/lane-addon-toml.md`, `docs/design/lane-addon-model-boundary.md`.
- Lane 의무: `lib/runtime/standalone_lane.mli`와 `.ml`.
- MSX/DOS의 소스·image 검증과 실사용 한계: `docs/guides/machine-addon-state.md`.

PR head, 스택 크기, 리뷰·빌더 상태는 2026-10-21 이번 조회의 값이다. 실행을 재개할 때 다시 읽는다.


## 2026-10-21 재개 체크포인트 · G01 후속

이 단락은 최초 기록을 대체하는 현재 상태다. 54개 항목과 각각의 완료 기준은 유지한다.

- 공통 Stack #44710의 #44707·#44709·#44721·#44726은 main 병합 완료다. 이것은 설치본과 실제 TUI 동작의 증거가 아니다.
- A01 원래 실패는 `bin/masc_tui_lane_addons.ml`의 `connection_worker_lines`가 instance list를 declaration list로 추론한 타입 오류다. C의 SecKeychain 경고 6개는 중단 원인이 아니다. main의 `9f6db24a35796a19f2b70ea2c0519309d2de7b86`은 snapshot/item 타입을 명시했지만, 이 수리를 포함한 실행 artifact 성공은 아직 확인하지 않았다.
- G01의 구체 결함은 `instances.length`를 기준으로 Off 적용 상태를 추측한 것이다. 같은 빈 worker 목록에서도 host의 `Inactive`, `Cleaning_workers`, `Failed`, `Unknown`은 다른 상태다. 기존 Inspect의 `Lane_addon_application.observe` 계산을 공통 inventory에서도 공유하고, 서버는 현재 선언과 관측의 id·source_path·source_revision·desired_revision·enabled가 모두 일치할 때만 application을 연결한다. 누락·중복·불완전 읽기·새 revision은 Unknown이다. 조회는 manager를 생성하거나 worker를 시작/정리하지 않는다.
- 직접 소비자: `Lane_addon_runtime.inventory` → `Server_lane_inventory.snapshot`/wire → `Tui_decode_lane_inventory`/TUI 및 Dashboard parser/panel. 변경한 record·엄격 디코더·fixture를 함께 맞췄다. 원래 상세 이동·worker 이력·Exact output 연결은 보존한다.
- 로컬 실제 검증: Dashboard `lane-inventory`, `lane-inventory-panel`, `lane-addon-connection`, `lane-declarations`, `lane-navigation`, `lane-navigation-flow` 6개 파일 62건 PASS; `pnpm exec tsc --noEmit` PASS. 변경 OCaml 10개 ML/MLI parser PASS. 이는 OCaml 타입/실행·native build·실제 브라우저/TUI 완료 증거가 아니다. 독립 미커밋 소스 리뷰는 P0–P2 없음이며 최종 공개 head에 재결속해야 한다.
- 다음 최소 실행 범위: 같은 공개 후보 SHA의 native `addon-lifecycle` artifact와 직접 변경한 `test_lane_addon_reconcile,test_server_lane_inventory,test_tui_lane_inventory`를 선택한다. 접수 뒤 CI watch/대기를 하지 않고 독립 작업을 계속한다. 성공 run·artifact·실제 TUI 관측은 각각 따로 확인한다.
- Browser Stack #44168은 이번 REST 조회에서 67층 open, top #44702 `d35d2559c56814b38615545a5f4f081304bccc05`다. 그 tree의 `Server_candle_appraiser.run_with`는 host에 intent를 보존한 뒤 원래 요청을 read/submit하고 `Candle_appraisal.decode`를 거쳐 결과를 정산 호출자에게 돌린다. worker는 `addons/candle-appraiser`에 존재한다. 따라서 E01을 미구현으로 되풀이하지 않는다. 이 소스 확인은 전체 스택 재리뷰·provider 성공·원장 중복 방지의 실제 재연결·Dashboard/TUI·main 통합 증거를 대신하지 않는다.
- 아직 필요한 실제 사용: A02의 TUI On/Off/재연결, Candle의 실제 LLM 판단과 host 정산, 같은 후보 H01 조합 및 H02–H06. G01 후속 하나로 전체 연결 그래프·모든 Lane 추출·54개 완료를 선언하지 않는다.


### G01 컴파일 실행 피드백

직접 소비자 run [39592343953](https://github.com/jeong-sik/masc/actions/runs/39592343953), product `5840bab469e8277194e405e6f2ec2cd712fc614e`는 `Lane_addon_runtime.attach_entry`에서 `configuration_application option`과 `configuration_owner option`이 맞지 않아 컴파일 FAIL로 종료했다. 새 관측 record의 id/source_path가 기존 record 추론을 가린 구현 결함이다. 관측 record가 기존 `configuration_owner`를 `owner` 필드로 보관하도록 고쳐 중복 owner 필드를 제거했다. 서버는 원래 owner의 ID·path·desired revision과 source revision·enabled를 여전히 모두 대조한다. 기존 성공 Dashboard/parser 결과는 이 실패를 대체하지 않는다. 수리 후 OCaml 실행·native artifact는 별도 확인해야 한다.

## 2026-10-21 완료 실행 영수증 · A01 / G01

- `docs/evidence/2026-10-21-addon-native-artifact/`에 완료된 native 영수증·두 suite 로그·내려받은 바이너리 identity/hash 대조 및 직접 관련 3suite 실행 로그 발췌를 보존한다. 실행 제품은 `7b16a9175711aefe744c5c704e038a42fd5b6b7b`, workflow는 `97468f95df78f35a35bb3fe14a9670240cced930`다. 이 문서 층의 head를 실행 소스로 바꾸어 적지 않는다.
- A01의 이전 실패·수리 후 미실행 표기는 당시 관측으로 남긴다. 새 native run `39595834943`은 완료 성공이고 실제 TUI/server의 build identity와 receipt 해시도 일치했다. `test_tui_lane_addons` 20건과 `test_lane_addon_application` 5건을 실행했다. 별도 direct run `39594048964`는 reconcile52·server inventory13·TUI inventory13건 PASS다. 전체 회귀는 이번 후보에서 미실행이다.
- A02의 실제 화면·운영 설치본 변경은 미실행이다. G04 #44807/#44809와 G03 #44824/#44828은 별도 후보이므로 이 artifact가 해당 후속들을 검증했다고 세지 않는다. H01–H06과 전체 54개 완료는 남아 있다.


## 2026-10-21 실제 native TUI 관측 · A02 후속

- [실측·실패 영수증](../docs/evidence/2026-10-21-addon-native-ui/README.md): 고정 제품 `7b16a9175711aefe744c5c704e038a42fd5b6b7b`의 실제 TUI/서버와 Docker/MCP observer로 On → Off → On을 조작했다. 같은 설치의 이전/새 incarnation, 새 입력 결과, 원래 row/evidence 보존과 두 컨테이너 해제를 확인했다. 수동 PTY 원문/cell capture와 그로부터 렌더한 PNG이며 물리 데스크톱 스크린샷은 아니다. Synthetic phrase 입력이고 오디오·모델·action 실행 증거가 아니다.
- A02는 완료가 아니다. 원래 상세에서 수동/visible cadence Inspect가 retained slice를 누락해 화면 결과를 지우는 P2를 재현했다. #44838은 조회 시 원래 instance/incarnation을 보존하고 effect/status 영수증은 기존대로 유지하는 소스 수리이며, 독립 source PASS·parser PASS와 새 native 실행을 구분한다.
- G06에는 Inspect 성공+retained Slice 실패 시 이전 결과를 덮는 소스 경로도 남았다. 실패와 성공한 빈 결과를 구분해 보존하고 직접 검증해야 한다. 원래 54개 요구와 완료 기준, 같은 후보 Dashboard 조합·실제 모델/앱·장기/성능·운영 설치 검증은 유지한다.

## 2026-10-21 고정 d9 실제 관측과 global Slice 후속

- [고정 d9의 실제 요청·원래 결과·영수증·복구 기록](../docs/evidence/2026-10-21-addon-slice-scope/README.md)을 공개한다. native run [39614788834](https://github.com/jeong-sik/masc/actions/runs/39614788834)의 matching server/TUI·24+5 검사와 실제 A composer의 거절·복구를 분리해 기록한다. 과거2c·15478 실행과 새 main/rebase 후보의 실행으로 합치지 않는다.
- 실제 same-run 빈 필터는 정상 empty로 받아 원래 행을 비우고 receipt를 유지했다. 다른 run·생략·blank·duplicate 입력은 전송 전에 거절됐다. 공개 trace의 거절 구간과 이후 직접 API 비교 구간을 분리해, 나중에 보낸 other-run API를 거절 구간에 잘못 세지 않는다.
- 추가 P2: 목록의 `slice {}`는 typed admission을 통과하지만 `/slice?`를 보내 실제400을 받았다. 같은 서버의 `/slice`는200이었다. [#44868](https://github.com/jeong-sik/masc/pull/44868)은 빈 query만 bare endpoint로 조립한다. nonempty 인코딩·필드 순서/중복·Detail의 원래 run 검증은 보존했다. parser·diff·독립 source PASS이며, corrected binary 실행은 아직 증명하지 않았다.
- 새 고정 제품 `e6c7521a0b709de79ed8997d204cd5924f395dbb`의 native [39620100070](https://github.com/jeong-sik/masc/actions/runs/39620100070)은 접수됐다. 결과·matching artifact·실제 global-query 성공은 후속으로 읽는다. CI watch/대기나 중복 dispatch는 하지 않는다.
- G01의 세 merged 상태와 병합 커밋은 확인했다. G06 충돌 수리는 새 main의 G01 기록과 기존 A02/G06 실측 기록을 모두 보존했다. 54개 ID·작업 내용·완료 기준은 바꾸지 않았다. 새 head의 MASC 재리뷰·전체 통합·설치가 남는다.
- E01은 미구현이 아니다. 기존 Browser 후보 d35d2559의 package·Server_candle_appraiser 입력 보존/원래 요청 read/authoritative Absent submit/완전 domain decode 경계를 직접 읽었다. 실제 provider와 Off 후 obligation/재연결·정산 및 두 UI는 미검증이다. 기존 구현을 기준으로 그 경계를 검증한다.
- 실측용 프로세스3개·포트2개와 정확한 이전 컨테이너2개의 부재를 종료 후 별도로 확인했다. private 로그인·credential·server log는 공개하지 않았다. 현재 54개 목표는 진행 중이다.

## 2026-10-22 재개 · 실제 병합과 실패 결과 정정

- [원래 실패·병합·새 요청 영수증](../docs/evidence/2026-10-22-addon-verification-resume/README.md)을 보존한다. G06 #44840의 6층은 실제 병합됐다. REST의 이전 head를 전파 지연으로 추정했던 것은 잘못이며, 병합 뒤의 fragment-only 두 branch head와 병합 당시 PR head를 분리한다. 이 세션이 해당 병합을 제출한 것은 아니다.
- e6 native run 39620100070은 결과 미확인이 아니라 컴파일 FAIL이다. Keeper record 추론 오류 두 건은 이후 병합된 #44864가 수리했다. 기존 수리를 재사용하며, 수리 소스가 있다는 사실을 성공 바이너리로 바꾸어 세지 않는다.
- 현재 main `4d25f9e175120740de2a0c254693c4bd73fbd534`의 addon-lifecycle [39623698078](https://github.com/jeong-sik/masc/actions/runs/39623698078)을 한 번 요청했다. 목적은 G06 수리와 기존 Keeper 수리가 함께 있는 matching server/TUI 확보다. 두 기존 suite 범위이며, 실행 결과·artifact 해시·실제 global Slice 성공과 화면은 아직 미확인이다. CI를 watch하거나 반복 조회하지 않는다.
- Browser #44168(top #44702, d35d2559, 67층)과 repaired-native 증거 #44851은 이번 REST 조회에서도 open이다. 현재 main의 native 후보가 unmerged Browser/Candle Addon 경로나 전체 54개를 실행한다고 주장하지 않는다. 54개 ID·작업·완료 기준은 유지한다.

### E01 worker 원본 실행 영수증 공개

- [Candle worker 13건의 원본 로그·source receipt](../docs/evidence/2026-10-22-candle-worker/README.md)를 보존했다. 고정 d35d2559 source의 기존 Python suite를 실제 MCP subprocess와 durable state로 실행한 결과다. 이번 문서 후속에서 재실행하지 않았다.
- incarnation 값 변경과 worker process 재시작은 실제 host-managed Addon Off/On과 다르다. 응답은 scripted이며 일부 persistence/nesting 검사는 direct import와 fault injection을 쓴다. OCaml host·실제 provider·원장 정산·실제 두 UI·운영 설치 성공을 뜻하지 않는다.
- E01은 기존 package와 host adapter를 유지하며 host 소비자와 원래 obligation/정산을 연결하는 최소 실행 범위를 검토한다. worker-only 성공으로 E01을 완료 표시하거나 E02로 순서를 건너뛰지 않는다.

- E01 host 소비자 최소 검사 [39624635082](https://github.com/jeong-sik/masc/actions/runs/39624635082)는 같은 d35 source의 기존 `test_candle_appraiser_contract,test_candle_appraisal_flow`를 선택했다. 첫 run identity를 확인했으며 결과는 아직 읽지 않았다. actual worker→host Grade 검사와 scripted Addon port→실제 payout worker 정산 검사는 각각의 범위이고, 둘을 실제 host Off/On 정산 완주로 합치지 않는다.

### 뒤이은 실행 경계 · TUI 컴파일 수리 재사용과 Browser 승인 조사

- 첫 결과 조회에서 native39623698078은 main4d25의 TUI warning4 세 건으로 FAIL이었다. #44874/#44875가 두 원래 함수의 명시적 생성자 분기로 실제 병합돼 현재003f52에 포함된다. 승인된 대안 #44873은 병합 guard 이후 실제 GitHub 병합 요청이 dirty로 거절됐고 병합되지 않았다. 동일 수리를 중복 작성하지 않았다.
- [새 native39625447860](https://github.com/jeong-sik/masc/actions/runs/39625447860)은 exact003f52의 addon-lifecycle 요청이다. 원래 실패와 별도 새 후보이며 결과·artifact·실제 corrected global Slice는 미확인이다.
- 독립 Browser67층 census는 현재 head/base/canonical diff/footer 결속 승인29층, 유효 승인 부재24층·이전head만14층을 확인했다. 현재 structured FAIL/HOLD·정식 CR·draft·미해결 thread는0이지만 #44192가 REST dirty다. 이는 전체 소스 리뷰나 merge-guard PASS가 아니다. 조사 당시 main4d25 이후 main이003f52로 움직였으며 whole restack 뒤 다시 판정해야 한다. pr-updater 요청 `kmsg-7f4585ddeacd43ac2a42f3e1b98cfc15`는 queued이고 실제 rebase/push 완료는 확인하지 않았다.
- E01 두 compiled suite는 요청39624635082에서 진행 중이었다. worker/host 계약과 payout 정산을 잇는 기존 통제된 검사를 실제 host-managed Off/On·실제 provider·원래 ledger 완주와 구분하며, 실제 격리 재연결 경계는 계속 남아 있다. 54개 요구와 완료 기준은 유지한다.

### E01 compiled 소비자 완료 결과

- 요청39624635082를 다음 publication 경계에서 처음 결과 확인했고, exact d35·minimal true·posix·선택된 두 suite의 실제 로그를 읽었다. `test_candle_appraiser_contract` 2건(0.527s), `test_candle_appraisal_flow` 24건(1.450s), 합26건 PASS다. [원본 실행 발췌·terminal API·해시 영수증](../docs/evidence/2026-10-22-candle-worker/README.md)을 보존한다.
- 실제 Python stdio/restart+host Grade와 production payout worker+scripted Addon 정산의 각각을 검증했다. actual host-managed container Off/On, common Exact 실제 provider 및 원래 obligation 정산을 하나로 이은 증거는 아니다. 실제 provider·두 UI·운영 설치·전체67층 또는54개 완료로 세지 않는다.

### 2026-10-22 E01 실제 host 연결·원래 지급 의무 실측

- [원본 실행·실패·복구·두 UI 증거](../docs/evidence/2026-10-22-candle-host-reconnect/README.md)를 공개했다. eb484 native run39636870206의 실제 server/TUI identity와 matching Dashboard, 실제 guest artifact·Task/Goal model 검증, test-only 관리자 confirmation API, Off의 원래 Owed, 실제 provider 3단계와 Paid 1건을 하나의 격리 workspace에서 연결했다. confirmation API의 human_confirmed라는 상태명을 실제 사람 확인이나 전체54 완료로 바꾸어 쓰지 않는다.
- On 첫 연결은 worker가 derive-only host 관측 입력에 없는 action context를 요구해 실패했다. #44911은 공통 schema로 수리하며 수정 전 실제 입력 검사 1FAIL, 수정 후13PASS다. 동일 설치의 Off→교체→On 후 정산, 정산 후 다시 Off→On에서도 원래3개 결과·같은 원장과 Paid1건을 확인했다. runtime은 native eb484+worker b427의 명시된 혼합 조건이며 새 전체 native build라고 부르지 않는다.
- G03 후속 결함: 원래 성공한 Grade를 다음 단계에서 다시 읽으면 관측 elapsed_s가 60.03초(공개 영수증 68)에서 180.05초(72)로 덮였다. 모델 중복 실행 근거는 없고, 원래 종단 시각을 보존하는 수리가 필요하다. 이 항목을 현재 잔여 작업으로 유지한다.
- Browser #44168 67층 eb484의 이전 독립 census는 모든 층 mergeable·현재 범위 결속 승인0/67이었다. 이 과거 census를 현재 승인으로 이월하지 않는다. #44911의 첫 게시에서는 installed gh stack link의 append가 실패해 기존 top #44702를 base로 둔 일반 branch였다. pr-updater의 후속 처리 뒤 현재 REST census에서 native #44168의 68/68 membership을 확인했다. 편입은 각 층의 현재 승인이나 병합 완료가 아니다. 기존67층을 개별 병합하거나 기존 top을 retarget하지 않는다.
- 54개 항목·완료 기준은 유지한다. E02–E12, 넓은 Browser 능력·실제 Agent 접근·모든 실패 경계·운영 설치·현재 head의 전체 통합/승인은 이 제한된 E01 실측의 성공 범위 밖이다.


### G03 종단 관측 수리와 E02 다음 실행 경계

- #44920 source `8057614cc68a1901f140a5190d4b0d6d38581263`는 E01 실제 영수증 68/72에서 드러난 재조회 시 elapsed 덮어쓰기를 수리했다. 현재 원래 worker read·권한·전체 domain decode를 유지하고, 동일한 durable receipt는 다시 append하지 않는다. 읽기 불가 payload는 typed 실패로 남기며 같은 persistence failure의 최초 elapsed로 기록만 재시도한다. replay-only restart marker는 실제 결과로 교체 가능하다.
- 독립 source 검토는 위 4파일 delta에 P0–P2 없이 PASS다. 이어진 `b8a16015e47f3ea355f434f3ce67d86d19fa57af`는 changelog만 추가한다. parser3개·diff-check PASS는 compile이나 실행 PASS가 아니다. 실제 전체 스택/설치 증거는 이 소스로 이월하지 않는다.
- exact b8a160 branch의 선택 실행 [39646732161](https://github.com/jeong-sik/masc/actions/runs/39646732161)을 한 번 요청했다. `test_candle_appraiser_transport,test_candle_appraiser_contract,test_candle_appraisal_flow`, minimal true, posix 범위다. 신규 3개를 포함한 transport10건의 실행 결과와 전체 선택 suite 결과는 아직 미확인이다. CI를 watch하거나 반복 조회하지 않는다.
- E02는 별도 추출 계약에서 현재 API의 실질 갭을 명시했다. request-owner binding은 digest/destination만 저장해 원래 batch 복구를 대신하지 못하고, 기존 generic execution failure는 pending/unknown을 표현하지 못하며, Addon On/result가 현재 Curator owner를 깨운다는 증거도 없다. 추가 독립 대조에서 현재 HTTP/CLI candidate의 host semantic validation과 Reject_and_advance가 common Addon schema-only runner에는 아직 연결되지 않은 점을 확인했다. schema-valid/domain-invalid 답을 terminal로 먼저 고정하지 않도록 원래 flow 안의 trusted semantic validation port도 구현해야 한다. 이 경계를 구현하기 전에 단순 callback 교체로 추출 완료라 부르지 않는다.
- 기존 A01–H06의 54개 작업과 완료 기준은 그대로 유지한다. 이번 수리와 설계 문서는 E02 실제 추출·나머지 행동군·현재 stack 승인·운영 설치를 완료한 것이 아니다.

### 2026-10-22 E02 원래 요청 저장·복원 기반

- 기존 request-owner 저장소를 재사용해 complete canonical input을 immutable destination/digest와 함께 보존하고 known-ID strict load를 추가했다. 손상·불일치·읽기 실패는 absent로 바꾸지 않는다. 실제 Curator 생산 경로는 아직 전환하지 않는다.
- 분류 batch는 원래 selected/remaining과 전체 row·related ledger prose를 복원하며, 이미 처리한 fact와 같은 Keeper neighbor를 거절한다. Briefing은 원래 ordered unconsumed partition과 prior summary를 검증해 복원만 수행한다. 독립 초기 리뷰의 두 P2(처리 fact 복원·같은 Keeper neighbor 허용)를 수정하고 실제 저장소 재개 검사에 넣었다.
- G03 선택 실행 [39646732161](https://github.com/jeong-sik/masc/actions/runs/39646732161)은 정확한 b8a16015e47f3ea355f434f3ce67d86d19fa57af에서 completed/success다. 실제 로그에서 transport10건(0.047s), contract2건(0.364s), flow24건(1.092s), 합36건을 직독했다. 새 E02 소스의 검사 결과나 실제 설치/UI 증거로 이월하지 않는다.
- E02의 trusted host capture provenance·물리 workspace binding·restart enumeration·accepted-work/commit journal·semantic validation port·Addon wake·실제 worker/두 UI는 계속 남는다. 원래 A01–H06의 54개 작업과 완료 기준은 유지한다.

### E02 host capture와 원래 판단 경계

- host가 제공한 원래 설치·source/config revision, opaque request ID, descriptor로 관측한 physical workspace, resolved prompt와 분류/briefing snapshot을 typed capture로 묶었다. 정규화된 JSON에서 원래 prompt를 새로 만들지 않고 actual input substitution bytes를 별도로 보존·검증한다.
- strict original-owner load 뒤 capture의 원래 scope/ID/destination·현재 관측 root identity·domain schema·당시 template/input/rendered bytes를 함께 확인한다. 기존 domain decode/apply 또는 decode/accept로 expected state만 계산하며 실제 저장·게시·observer 완료는 하지 않는다.
- 새 5개 시나리오는 실제 owner-store 보관과 새 handle 읽기, override 변경 뒤 원래 입력/판단, 잘못된 provenance/owner/schema, physical root copy/replacement, briefing 조기 publication 거절과 enclosing descriptor scope의 최종 검사를 다룬다. parser7개 PASS와 초기 독립 source 검토는 compiled execution과 별도다.
- host metadata를 실제 owner에서 수집해 이 factory에 연결하는 것, accepted-work 발견/수명·uncertain commit·semantic flow·Addon wake·worker/두 UI는 계속 구현해야 한다. 원래 54개 완료 기준은 유지한다.

- [#44926](https://github.com/jeong-sik/masc/pull/44926)의 host capture 후속 작성 중 initial #44924 exact3e2a 선택 검사39651355908이 compile 단계에서 실패했다. [원본 실패 발췌](../docs/evidence/2026-10-22-curator-capture/initial-compile-failure.log)는 shared fact 필드로 assignment가 추론된 실제 P2를 보여 준다. 원래3층에 pending_fact 타입을 명시한77c88c3을 추가하고4층전체를 local restack했다. 초기 source PASS는 typing 증거가 아니며 독립 검토 보고서도 이 누락을 정정했다. corrected exact top 실행 성공은 아직 미확인이다.

### 2026-10-22 E02 원래 요청 progress 후속

- corrected exact d4d54edcd444d46c0405505e9808d684e18f1d5b의 선택 실행39653626146은 completed/success다. host capture5·request capture5·request5·ledger14·briefing9·host cycle44·Candle transport10, 합92건의 실제 로그를 읽고 [원본 발췌·해시 영수증](../docs/evidence/2026-10-22-curator-capture/corrected-selected-execution.json)을 보존했다. 초기3e2a의 실제 compile 실패는 그대로 남긴다.
- 같은 original owner record에 capture+Captured를 한 번에 저장하고 [host progress](../docs/design/addon-original-request-progress.md)를 누적한다. immutable retain은 이력을 보존하고, advance는 전체 expected record와 정확한 next tail만 구분한다. Stored/Already_stored/Unconfirmed를 나눠 ACK를 새 RPC 허가로 쓰지 않으며, worker absence와 unknown은 재-dispatch를 허용하지 않는다.
- 원래 judgment·before/after를 commit 의도에 보존하고 uncertain 뒤 exact 관측만 기록한다. 실제 Store의 새 handle·stale writer·late original result·commit recovery·terminal conflict/refusal·손상 history·사라진 original을 다루는 6개 시나리오를 추가했다. 새 progress의 parser/source 검토와 compiled execution, 실제 domain save/worker 재개는 구분한다.
- strict restart inventory와 물리 record/durability 결속, production owner capture·원래 semantic acceptance·Addon wake·worker/두 UI 및 54개 전체 완료는 계속 남는다. 원래 A01–H06의 작업 이름·완료 기준은 변경하지 않는다.

### 2026-10-22 E02 원래 요청 발견 후속

- 정확한 c231ab19f12981429a7442696c9f2c02c81104d5의 progress 선택 실행39657204150은 completed/success다. 실제 로그에서 progress6·request capture5·host capture5·host cycle44·Candle transport10, 합70건을 확인하고 [원본 발췌·해시 영수증](../docs/evidence/2026-10-22-curator-progress/selected-execution.json)을 보존했다. 이 성공을 새 discovery source에 이월하지 않는다.
- [원래 요청 발견](../docs/design/addon-original-request-discovery.md)은 기존 owner namespace의 전체 발행 기록을 엄격하게 읽고 scope/ID/hash filename/input/progress를 검사한다. 기존 Fs traversal의 callback 전체에 root·모든 ancestor descriptor를 유지하고, 같은 no-follow file/parent FD에서 실제 read→fsync→동일 bytes/final identity 검증을 한다. known-ID load도 같은 경계를 쓴다.
- 처음 없는 child만 owned ancestor settlement 후 빈 관측이며, missing/unsafe anchor·listed 소실·심볼릭 링크·다중 hardlink·비정규 파일·sync/read/parse 실패는 오류다. 새 handle의 원래 input/progress·scope, 실제 파일/부모 교체와 권한 변경 등 7개 검사 시나리오를 추가했다. canonical staging만 미발행으로 제외하고 별도 registry나 읽기 중 디렉터리를 만들지 않는다.
- 이것은 atomic multi-record snapshot이나 실제 process/worker 재시작 증거가 아니다. known-ID도 현재 namespace 이름 읽기 비용을 내며 실제 효과 전에 원래 owner의 fresh authority/record 검증이 필요하다. production Curator metadata·원래 semantic acceptance·uncertain domain commit·wake/worker/두 UI와 A01–H06의 전체 완료는 남아 있다.

### E02 발견 선택 실행의 기존 worker fixture 수리

- exact61c6014의 [8-suite39660035294](https://github.com/jeong-sik/masc/actions/runs/39660035294)는 completed/failure다. `test_lane_addon_worker.ml:537`의 기존 exact output에 필수 `request_schema`가 없어 컴파일에서 멈췄으며, 선택된 발견 검사도 실행되지 않았다. [실제 실패 발췌와 원본 해시](../docs/evidence/2026-10-22-curator-discovery/initial-compile-failure.json)를 보존한다.
- 기존 worker-port fixture는 요청별 schema를 사용하지 않으므로 `request_schema=Types.Package_schema_only`를 명시했다. 파싱 성공을 compiled 실행으로 세지 않으며, 같은8-suite의 수정 후보 결과를 별도로 확인한다. A01–H06의54개 작업과 완료 기준은 유지한다.

### E02 원래 semantic acceptance의 공통 Exact 연결

- 기존 공통 Exact owner에 trusted `validate_request`를 필수 인자로 연결했다. Runtime은 기존 runner와 함께 등록하고 server bootstrap은 원래 host capture·물리 workspace·canonical installation/package/tool·전체 Exact request digest를 검증하는 authority를 제공한다. 같은 capture를 다른 package로 바꾸어도 우회하지 않는다. package/request 스키마 뒤 원래 classification decode/apply 또는 briefing decode/accept를 HTTP/CLI candidate acceptance 전에 검사하고, retained answer도 fresh authority로 재검증한다.
- 실제 loopback HTTP와 기존 CLI walk의 5시나리오를 추가했다. 완전 fact 분류·없는 claim으로 join하는 판단·briefing 공백·capture/installation/package/physical workspace 불일치·schema-only terminal 재전달을 다룬다. 파싱과 source review를 compiled 실행으로 세지 않는다. 모든 Exact 요청에 strict Curator namespace lookup이 추가되며 malformed authority는 다른 package에서도 absent로 바꾸지 않는다.
- [설계와 명시적 한계](../docs/design/workspace-curator-semantic-validation.md): production Curator metadata/owner·worker·commit recovery·wake·실제 두 UI/Off/On은 남아 있다. 원래 A01–H06의54개 작업 이름과 완료 기준은 그대로다.

- 발견 수리 exact `fab00b72a44b65a611bb97bddfa56c45f78e8a4e`의 [39661318402](https://github.com/jeong-sik/masc/actions/runs/39661318402)는 completed/success다. 실제 checkout·minimal/posix·8개 suite 원문과 성공행에서 발견7·progress6·request capture5·execution capture5·host cycle44·Candle transport10·fs_compat42·worker71, 합190건을 확인했다. [발췌·원문 해시](../docs/evidence/2026-10-22-curator-discovery/corrected-selected-execution.json)를 보존했다. 이 결과는 새 semantic port 소스나 production/실제 재시작/UI 성공으로 이월하지 않는다.


### E02 semantic 선택 실행의 실제 실패와 fixture 수리

- exact `8b7b57b580c083c8f89fa5143af205c2ece669cd`의 [39662676800](https://github.com/jeong-sik/masc/actions/runs/39662676800)은 completed/failure다. [원래 실패 발췌·해시](../docs/evidence/2026-10-22-curator-semantic/initial-selected-failure.json)를 보존한다. runner18건 중 roles1·Curator4가 실패했고, 별도로 worker71건 중 selected-hooks case5가 기존 Docker create 1초 timeout으로 실패했다. worker timeout의 원인은 아직 확정하지 않았다.
- 실제 common Exact는 Json_syntax에서 원래 대화 뒤 schema instruction User를 붙인다. fixture가 원래 모든 role/text prefix와 정확한 지시문을 검사하도록 수정했다. Curator baseline도 fieldless object가 아닌 실제 Decision/Briefing 출력 스키마로 선언했다. schema-only terminal 사례는 seed가 실제 Answered임을 먼저 확인해 거짓 양성을 막는다. production validator·provider·timeout은 바꾸지 않는다.
- 파싱·독립 소스 대조와 수정된 compiled 실행은 구분한다. 수정 후보 결과·production Curator owner/metadata/commit/wake·실제 두 UI와 54개 전체 완료는 남아 있다. 원래 A01–H06의 작업 이름·완료 기준은 유지한다.

### E02 실제 Curator worker와 공통 보존 코어

- Candle의 실제 Store·pending/terminal·host request/result·stdio 구현을 `addons/exact_worker.py`로 옮겨 Curator와 공유했다. Candle의 기존 namespace·v1 record·canonical digest·관측 row ID를 유지하며, 새 공통 모듈을 포함하도록 image revision/tag를0.1.1로 올렸다. 두 Dockerfile과 실제 Dune sandbox deps에 공통 파일을 포함했다.
- 새 `workspace-curator` 패키지는 host capture factory가 만든 full Exact request를 변경하지 않고 보존·재열거한다. classification/briefing을 분리하며 provider나 ledger 권한을 갖지 않는다. Python 실제 subprocess/restart·role/system/schema/ID 변경 거절·불확실 sync 후 원래 terminal 재관측·패키지 mount layout6건과 기존Candle13건이 PASS다.
- 새 `test_workspace_curator_addon_contract` 두 시나리오는 host capture retain→실제 worker의 재시작 RPC/Hook→production semantic authority+common Exact loopback(원래 domain-invalid 후보 거절)→종단 보존/재조회→전체 domain 검증·partial briefing 미게시·provider 재실행 없음까지 잇도록 작성했다. 로컬 Dune는 실행하지 않았고 새 compiled 결과를 별도로 확인해야 한다. 실제 production Curator owner·metadata·commit recovery·Addon wake·provider/두UI·운영 설치 및 나머지54개 요구는 계속 남는다.


### E02 원래 admission consumer와 실제 Runtime provenance

- exact `1a8070efd200661476e17fc31e895f83cdd41cfd`의 [39665945395](https://github.com/jeong-sik/masc/actions/runs/39665945395)는 completed/success다. [checkout·선택 suite·원문 해시](../docs/evidence/2026-10-22-curator-shared-worker/selected-execution.json)에서 Curator 실제 계약2·Candle 계약2·transport10·semantic runner18·host cycle44·worker71, 합147건을 확인했다. 앞선 worker timeout은 이번에는 재현되지 않았지만 원인 해결로 단정하지 않는다.
- 원래 Runtime action serializer 안에서 live export·enabled declaration·package·semantic revision을 확인한 뒤 실제 source/config revision으로 host capture를 만들고 같은 owner record에 retain한다. 새 Curator consumer는 물리 workspace/원래 capture를 fresh load하고 read→새 intent→원래 submit을 잇는다. 명시적 capacity non-admission만 같은 ID로 재접수 가능하며 pending/unknown/dispatch 뒤 absence/불확실 journal/Already_stored는 재submit하지 않는다. 완전 domain judgment와 terminal refusal/unknown은 원래 progress로 보존해 worker 없이 복원한다.
- 실제 worker contract2건이 새 consumer를 경유하도록 바꾸고, capacity→reply lost→absence→late original answer·terminal unknown no-replay2건, Runtime 실제 provenance/Off/reserved 거절1건, 원래 Store capacity-vs-unknown1건을 추가했다. exact `6aba6ec2ec9b97663397f1dd5cc952e89d281fc9`의 [39668138137](https://github.com/jeong-sik/masc/actions/runs/39668138137)은 completed/failure다. 실제 Curator 계약4건은 PASS지만 host-cycle 새 provenance fixture가 원래 factory JSON과 canonical 저장 JSON을 구조 동등 비교하여 실패했다. 키 순서를 무시하는 `Yojson.Safe.equal`로 fixture를 수리하며 제품 canonicalization/권한은 바꾸지 않는다. 전체 성공으로 기록하지 않는다. production scheduler 전환·domain commit/recovery·scoped wake·typed size/narrow successor·실제 provider/두 UI/운영 설치와 원래54개 전체 완료는 계속 남아 있다. A01–H06의 이름·완료 기준은 유지한다.

### E02 원래 domain commit과 불확실 저장 복구

- 같은 Curator adapter에 실제 Ledger/Briefing commit consumer를 추가했다. 원래 물리 workspace·full capture·Answered judgment를 fresh load해 before/after를 다시 계산하고 progress의 값을 교차 검증한다. fresh after를 먼저 확인해 재쓰기를 피하며 새 Stored intent/retry만 한 번의 실제 save를 허용한다. 복구된 intent는 unknown→fresh before→새 retry 기록을 거치며 다른 state는 conflict로 보존한다. save 성공도 fresh after 확인과 별개다.
- classification selected source 읽기·원래 fact와 기존 ledger reconciliation을 확인하며, briefing은 `prepare`와 같은 fixed target/현재 contract 규칙을 쓴다. 추가 source는 다음 pass로 남기고 삭제·수정·contract 변경은 원래 judgment로 덮지 않는다. 일부 chunk는 기존 게시본을 유지한다. `capture_briefing`은 원래 prepared-state 선행 저장의 fresh 확인을 요구하며 모델 후에 준비 state를 발명하지 않는다.
- 실제 Keeper source·원래 host journal 재열기·domain save/read를 사용하는 15시나리오를 작성했다. save-edge 실패/저장 후 응답 유실·예외는 명시적 경계 주입이며 실제 atomic rename 단계 장애나 취소 실측이 아니다. 원래 domain malformed 읽기를 uncertainty로 보존하며 같은 오류의 반복이 이력을 늘리지 않는지도 확인하도록 작성했다. 파싱·독립 소스 검토·새 compiled 실행 결과를 분리한다. production owner wiring·initial-save/capture 중단 복구·observer receipt·scoped wake·typed size successor·실제 provider/두 UI/운영 설치와 원래54개 전체 완료는 남아 있다. A01–H06의 이름·완료 기준을 유지한다.
- PR44944의 현재 head6aba에 대한 정식 code-reviewer 변경 요청은 동일 pending/unknown 관측마다 전체 journal을 다시 쓰는 P2였다. 후속 consumer는 현재 phase의 마지막 typed 관측과 의미상 같은 증거이면 append/replace하지 않는다. 새 worker 계약 시나리오는 실제 journal 파일 identity/bytes를 비교하고 변경된 증거·상태 재등장은 남기도록 한다. capacity 접수·terminal unknown·fresh 권위 읽기와 전체 실제 I/O 비용은 기존 의미를 유지한다. 이 수리는 원래44944의 공식 승인 해소나 새 실행 성공을 대신하지 않는다.


### E02 scoped owner wake와 실제 compile 실패 수리

- 원래 #44944의 반복 관측 P2 수리와 실제 journal identity/bytes fixture를 그 PR 자체에 옮겨 전체 스택을 재배치했다. 중간 head `e3d28089451b475ae5c475ae017528ab9e84a591`는 정식 source Approved였으나, 그 뒤 타입 수리 head의 승인은 별도로 받아야 한다.
- 실제 [선택 실행39671034185](https://github.com/jeong-sik/masc/actions/runs/39671034185)는 `ea9f86ff1f5b5b46cd5375f39885dbb71e5b212a`에서 테스트 실행 전 compile FAIL이다. `observe` 인자의 `Owner.retained` 타입 표기를 #44944에서 수리하고, #44948의 같은 형태 `uncertain` 인자도 명시했다. 이전 SOURCE PASS를 compiled 성공으로 이월하지 않는다.
- Runtime은 served workspace Store root와 package에 결속된 export/configuration/accepted Exact-result hint 구독을 추가했다. 기존 MCP bridge를 유지하고 configuration metadata 게시 뒤 알린다. worker ready가 먼저 온 경우도 이후 metadata가 원래 owner를 깨운다. 원래 요청의 fresh/Restore 전달 모두 RPC 반환·accepted=true·현재 authority 확인 뒤 알리며, subscriber 실패와 publisher 취소를 구분한다.
- 실제 host-cycle 7사례를 등록했다. scope 분리·MCP 공존·metadata 순서·원래 결과 재전달·subscriber 오류/별도 취소·거절/잘못된/유실 수신 확인·non-Exact 거절·새 memory commit 없이 실제 Curator owner 깨우기를 다룬다. controlled enabled predicate와 model 답변은 fixture다. parser와 독립 source 검토는 통과했지만 새 compiled 실행은 별도이며, production scheduler는 아직 기존 실행 경로다.
- 다음은 같은 직렬 owner에서 원래 accepted-work 발견/Off 상태 recovery·typed size successor·initial prepared save/capture 복구·observer receipt를 실제 Addon consumer로 연결하는 것이다. 실제 provider/두 UI/운영 설치 및 원래 A01–H06 54개 작업과 완료 기준은 유지한다.


### E02 원래 wake·commit 실행 성공과 typed size 후속

- [실제 선택 실행39674624863](https://github.com/jeong-sik/masc/actions/runs/39674624863)은 exact `af9e1eeefe9b8b17fe82c643e9344aa3df87416a`에서 completed/success다. commit15·실제 worker 계약5·Curator lane34·briefing9·progress7·discovery7·host-cycle52·runner18, 총147건을 원문 로그에서 확인했다. host-cycle에는 새 wake7건이 포함된다. [공개 선택 실행 영수증](../docs/evidence/2026-10-22-curator-owner-wakes/selected-execution.json)은 과거 compile FAIL과 수리 후 성공을 구분하며 현재 size 후속이나 실제 provider/UI/설치 성공을 뜻하지 않는다.
- 새 typed size 후속은 실제 `Output_limit_reached`를 일반 invalid output과 분리하고 OCaml/공통 Python worker/별도 Operator Quiz/Candle/Browser consumer까지 연결한다. token 측정·유효 증거가 없다는 상태는 input-size 거절이 아니라 Transient로 보존한다. 기존 transient/config/auth 우선순위와 원래 terminal no-replay를 유지한다.
- Python Curator7·Candle14·Quiz Flow68 총89건이 실제 subprocess/도메인 fixture에서 PASS다. 새 ML/MLI는 parser 검사이며 compiled 선택 실행은 별도다. 실제 provider나 official-client 프로세스 실행을 fixture 성공으로 바꾸어 쓰지 않는다.
- production owner의 original accepted-work 발견/Off 복구·전체 batch successor의 durable predecessor 연결·initial prepared save/capture·observer receipt·실제 provider/두 UI/운영 설치와 원래54개 완료는 남는다. A01–H06 이름과 완료 기준은 유지한다.


## E02 successor 재개 체크포인트 · 2026-10-22

- 부모의 원래 typed size terminal을 보존하고, 전체 자식 capture와 ID를 부모 intent에 먼저 저장한다. 자식 retain/read 확인 뒤 부모 ACK를 기록한다. ACK 전 child resume·direct Exact를 거절하며, ACK 후 사라진 child는 재생성하지 않는다.
- strict capture v2의 predecessor로 원래 template·workspace·ledger·destination·whole prefix/remainder와 완전 ancestry를 재검증한다. Briefing input-only policy와 동일 prepared state를 유지한다. production scheduler·observer·도메인 write를 새로 만들지 않는다.
- 실제 저장소의 중단 경계·같은 ID 재개·자식 유실·충돌·부모 유실/순환·중첩 후속·prefix commit·Briefing을 위한 15개 새 시나리오를 추가했다. parser PASS와 독립 source review, compiled 실행은 구분한다. 이 기록은 54개 완료 판정이 아니다.
- 이전 typed-size805의39676761394는 실제 FAIL이다. 만료·미래 증거는 측정 전에 거절되어 HTTP 0건이 맞고, Candle 목록은 summary이므로 detail 조회가 필요하다. 두 fixture의 총 3건 실패를 owning layer c18에서 수리했으며 실패 로그와 영수증을 보존한다. 수리와 새 후속의 compiled 성공은 아직 미확인이다.


## E02 원래 host 결과의 읽기 경계 · 2026-10-22

- Off로 worker/export가 사라져도 이미 완료된 host Exact의 원래 terminal을 확인할 수 있도록 읽기 전용 포트를 추가했다. 원래 declaration·요청 전체·digest·schema·attempt/final을 엄격히 읽고, 진행 중 결과를 unknown으로 발명하지 않는다.
- Curator의 Dispatch_pending에서 원래 capture·ancestry를 복원한 뒤 이 포트를 먼저 읽는다. 저장된 terminal은 기존 완전 domain validator를 통과해야 하며, 손상 기록은 worker fallback 없이 거절한다. 새 admission은 여전히 live export를 요구한다.
- 기존 successor062의 실행39679636091은 실제 복구3건 FAIL이었다. 새 capture와 복원 capture의 내부 JSON 키 순서가 달라진 문제를 owning layer709에서 수리했다. 원래 parent substitution bytes는 보존하며 내부 work만 canonical snapshot으로 고정한다. 앞선4ac 실행39679243670은 직접 MCP 의존성 결손으로 컴파일 FAIL이었고062에서 수리됐다. 현재 소스 승인과 새 실행 성공을 각각 재확인해야 한다.
- 이 변경은 기존 production owner를 아직 교체하지 않는다. observer의 최초 start/terminal receipt를 원래 원장에 독립 보존하고, Off accepted-work/initial prepared save/capture를 처리한 뒤 기존 direct provider 경로를 교체하는 작업이 남는다. 원래54개 완료 기준은 유지한다.


## E02 원래 관측 receipt 보존 후속 · 2026-10-22

- [정확한866 선택 실행](../docs/evidence/2026-10-22-curator-retained-host-read/selected-execution.json)은 run39682010920 completed/success이며 8개 suite126건의 실제 원문 성공행과 source/hash를 보존했다. consumer34에는 이전062의 successor 복구3건이 포함되며, runner31·Candle11은 이전805 fixture 수리도 확인한다. 새 observer 소스나 실제 provider/Off/UI/production 전환의 성공으로 이월하지 않는다.
- #44961 head709와 #44965 head866의 새 정식 source Approved 본문 첫 줄과 approve-guard footer를 직독했다. 이는 각각의 현재 source 판정이며 전체 Native Stack 병합이나 설치 승인이 아니다.
- [독립 관측 축](../docs/design/addon-original-observer-receipts.md)은 원래 owner record에 registration/completion의 최초 시각·전체 canonical payload/digest를 intent→ACK로 보존한다. registration ACK 전에 completion intent를 보존할 수 있고, terminal ACK에는 원래 registration ACK가 필요하다. primary phase를 바꾸거나 RPC·도메인 save·successor 권한을 만들지 않는다.
- 실제 Store의 재열기·domain terminal과 pending 관측 공존·ACK 유실 시 원래 파일 bytes/identity 유지·refusal/link·손상 history를 다루는4개 새 시나리오 소스를 추가했다. 파싱과 소스 검토를 새 compiled 성공으로 세지 않는다. Curator typed receipt/domain 검증·registry 잠금 안 compare/reconcile·synthetic restart terminal/retention 정책·production owner 교체·실제 provider/두 UI/설치와 A01–H06 전체 완료는 계속 남는다. 원래54개의 이름·완료 기준은 바꾸지 않는다.


## E02 Curator typed observer 준비 후속 · 2026-10-22

- generic observer exactcf7의 [선택 실행39683131079](../docs/evidence/2026-10-22-addon-observer-receipts/selected-execution.json)은 completed/success이며 progress11·consumer34·discovery7 총52건의 실제 원문과 해시를 보존했다. #44967 현 headcf7의 정식 source Approved5606779915 본문/결속 footer도 직독했다. 이 성공·승인을 새 typed receipt 소스에 이월하지 않는다.
- [Curator typed receipt](../docs/design/workspace-curator-observer-receipts.md)는 원래 configured installation·package/tool·full capture/input·request digest·결정적 run ID를 registration에 결속한다. 실제 Finished/Conflicted/Refused의 원래 judgment/완전 before/after를 검증하고, settlement와 같은 pure commit_plan을 재사용한다. Judged/uncertain commit을 성공으로 만들지 않고 parent refusal과 child 결과를 분리한다.
- 기존 실제 host adapter에 fresh original/physical workspace/ancestry 복원 뒤 intent만 준비하는 포트를 추가했다. pending/ACK receipt의 원래 시간과 내용을 다시 검증해 쓰기 없이 재사용하며, 새 intent에만 시계를 읽는다. 모델·worker·domain save·registry ACK는 호출하지 않는다. 실제 보고된 slot/basic usage는 보존하고 cache/cost/provider start/duration은 발명하지 않는다.
- 실제 Store/domain9개 새 시나리오 소스와 parser 검사를 추가했다. 새 compiled 실행·정식 리뷰는 별도이며, registry의 atomic compare/ensure·strict durability/partial replay·closed replay provenance·nullable elapsed와 통계/UI 소비자·retention ACK 정책·production owner 교체 및 원래54개 전체 완료는 계속 남는다. A01–H06의 이름과 완료 기준은 유지한다.


## E02 실제 eligibility conflict 관측 수리 · 2026-10-22

- [typed observer28b5 선택 실행](../docs/evidence/2026-10-22-curator-typed-observer/selected-execution.json)은 run39685010894 completed/success이며 consumer43·capture5·progress11·worker contract6 총65건이다. 이 head는 실제 source/contract eligibility conflict의 `{state, reason}` wrapper를 거절하는 P2가 있었으며, 기존 root-conflict fixture의 성공은 그 경로를 증명하지 않았다. 직전 독립 source PASS는 이 발견으로 FAIL로 정정했다.
- 해당 owning PR #44971에서 root `{kind, state}`와 exact `{state, reason:string}`만 허용하고, 두 경로 모두 원래 도메인의 완전 Ledger/Briefing decode·kind·canonical equality를 유지하도록 수리했다. reason은 opaque 진단으로 보존한다. 실제 source 변경과 Briefing 계약 변경의 settle→prepare→reopen 및 임의 진단 보존3건을 추가하고 손상 경계를 확장했다. 수리 head의 독립 검토와 새 compiled 실행은 별도다.
- registry compare/reconcile·delivery·nullable timing/통계·production owner 교체·실제 provider/두 UI/설치와 원래54개 전체 완료는 계속 남는다. A01–H06의 이름과 완료 기준은 유지한다.


## E02 production 전환 전 원래 forest 복구 경계 · 2026-10-22

- #44971의 실제 eligibility conflict 수리를 af699에 반영했고 독립 bounded source 재검토 PASS를 받았다. 이전28b5의65건 성공과 구분해 새4-suite 선택 실행39686436649를 요청했다. 후속 원문 확인에서 [새 실행39686436649](../docs/evidence/2026-10-22-curator-eligibility-observer/selected-execution.json)의 consumer46·capture5·progress11·worker contract6 총68건 실제 성공을 확인했다. 정식 code-reviewer5606997933도 첫 줄/approve-guard footer의 af699 결속을 직독했다. 이를 새 forest 복구 포트의 실행·승인으로 이월하지 않는다.
- `Capture.recoverable_successors`는 complete original inventory의 물리 workspace·모든 capture·전체 parent/child derivation을 먼저 검증한다. 부모 ACK 전 자식은 정확한 initial Captured 상태만 허용하며 실행 가능한 capture로 내주지 않는다. 손상된 무관 항목·dangling/duplicate/cyclic/충돌·ACK 뒤 자식 유실은 전체 오류다.
- `Server_workspace_memory_addon.discover`는 검증 후 기존 Subdividing intent만 같은 child ID로 retain/read/ACK하고, 다시 complete discovery와 보통 strict restore를 거쳐 전체 관측을 반환한다. 단순 Rejected에서 새 successor를 만들지 않고 worker/모델/domain save/observer를 호출하지 않는다. 원래 workspace lease/직렬화는 호출자의 의무다. 부분 복구 뒤 오류도 성공 목록으로 반환하지 않는다.
- 실제 Store의 retain 전/ACK 전 중단·반복 파일 bytes 보존·ACK 뒤 유실·무관 손상 전 무쓰기·충돌/조기 실행 자식·중첩 chain·부모 유실·foreign workspace·duplicate ID·빈 목록/원래 거절 보존12개 새 시나리오를 정의했다. 새 compiled 실행·독립 검토와 실제 Off lifecycle은 별도다. 이 source port는 아직 기존 production scheduler를 교체하지 않았으며 new child의 Runtime authority 선형화·source별 frontier·registry 전달·실제 provider/두 UI/설치 및 원래54개 전체 완료는 계속 남는다. A01–H06의 이름과 완료 기준은 유지한다.


## E02 Addon production owner 전환 후속 · 2026-10-22

- original forest 선택 실행39687420511은 실제 completed/success로 consumer58·capture5·discovery7·worker contract6 총76건이다. [공개 영수증](../docs/evidence/2026-10-22-curator-original-discovery/selected-execution.json)은 실행 head4af20과 미사용 binding만 제거한 최종641을 구분한다. #44974 정식 code-reviewer5607084878의 현재641 첫 줄·결속 footer를 직독했다. 이를 새 production 소스의 성공으로 이월하지 않는다.
- [production owner](../docs/design/workspace-curator-production-owner.md)는 public start에서 complete forest 발견/기존 intent 복구→원래 capture/resume/settle/narrow를 사용한다. 기존 직접 HTTP/CLI 실행과 결과 주입 테스트 API를 제거했다. classification/Briefing을 별도 진척시키고 실제 Addon·출력 route 알림으로 같은 owner를 깨운다.
- 새 요청은 configuration→action 직렬화 안에서 실제 선언 전체를 fresh하게 읽는다. 저장한 Off가 reconcile 전 cached export를 빌리지 못하며, 새 child는 원래 semantic worker input을 확인한다. raw source provenance는 보존하고 기존 intent·accepted host terminal·domain 복구는 Off-local로 둔다. 저널 callback 오류/예외는 공유 잠금을 오염시키거나 새 ID의 근거가 되지 않는다.
- 새 actual fixture는 public owner·설정 Runtime·persistent Python/MCP worker·공통 Exact·loopback HTTP를 연결한다. 컨테이너 자원 시작/정리는 대체했고 size/crash journal 경계와 유실 delivery는 명시적으로 제어한다. parser·독립 source review·새 compiled 실행·실제 provider/두 UI/설치는 별도다. 이전 injected34건을 새 production 실행 증거로 세지 않는다.
- 완료 fact의 과거 selected만 영구 제외하면 실제 삭제 후 같은 fact 재추가가 막히는 P2를 독립 리뷰에서 확인했다. 현재 strict ledger의 pending 의미로 회복하고 원래 거절/unknown no-replay는 유지하는 수리와 실제 owner 시나리오를 추가했다. 과거/현재 config의 size terminal을 함께 세어 현재 후속을 막는 별도 P2도 발견했다. fresh semantic destination·current domain/source 관련성으로 후보를 좁히고 실제 narrow에서는 권한을 다시 확인하는 수리 및 별도 actual fixture를 추가했다. 실행 증거는 이후 선택 결과로 기록한다.
- typed observer는 아직 intent-only다. 옛 direct executor의 registry write도 제거되어 registry compare/reconcile·delivery·ACK와 nullable 통계/UI 연결이 끝나기 전 관측 공백이 남는다. 실행 소유권을 잃은 builtin Curator route/config·UI projection도 같은 통합 후속에서 제거하거나 실제 Addon 연결로 명확히 정리해야 한다. 이를 숨기려고 직접 실행 경로를 유지하지 않는다. E02 완료·운영 설치·A01–H06 전체 완료는 선언하지 않는다. 원래54개 이름·완료 기준은 유지한다.


## 2026-10-22 E02 production compile repair and observation foundation

PR #44979 c4f796a5aa6670f95aad986f4ba4d8052ee4443f의 실제 선택 CI
[39692088763](https://github.com/jeong-sik/masc/actions/runs/39692088763)는
`test_workspace_memory_curator_lane.ml:406`의 미사용 `current` binding 경고26으로
컴파일 실패했다. 기존 소스 승인과 실행 결과를 구분한다. 원래 journal seed 효과는
`ignore (seed_size_refusal store current_capture)`로 보존했고, whole-stack 재배치·push 후
새 head는 `1a7d67fc6a538f320be3b5ff5cd43e6319a75084`다. 새 선택 CI
[39693756145](https://github.com/jeong-sik/masc/actions/runs/39693756145)와 독립 재리뷰를
요청했으며 이 기록 시점 결과는 미확인이다. 네 suite는 실제 public owner, host cycle,
원래 commit, worker contract이며, 실제 provider·두 UI·설치를 증명하지 않는다.

관측 후속은 [origin/timing 계약](../docs/design/exact-observation-origin-and-timing.md)에
따라 v7의 closed completion origin과 nullable 측정 시간, 엄격한 전체 usage 계약을
연결한다. 측정된 완료 순서는 유지하고 미측정 결과의 등록 시각은 명시적인 정렬 기준으로만
사용한다. 미측정 결과를 p50이나 완료 시각으로 만들지 않으며, 같은 문자열 오류의
실제 Producer 결과를 재시작 관측으로 오인하지 않는다. 원래 receipt의 registry 전달·
조건부 durable reconcile·ACK, 실제 provider·화면·설치는 여전히 후속이다.

A01–H06의 원래 54개 작업명과 완료 기준은 변경하지 않았다. 이 foundation만으로
E02·G03 또는 전체 목표의 완료를 선언하지 않는다.

추가 관측: 위 새 production run39693756145는 컴파일 후 실행에서 실패했다.
public owner 11건 중 9건 통과·2건 실패이며, 두 fixture의 대기 predicate가 owner idle 확인보다
먼저 엄격한 original inventory를 읽다 directory-change 거절을 받았다. 나머지 host-cycle
51건·commit 58건·worker-contract 6건은 실제 통과했다. 실패 원문을 보존하며 조사·수리하고,
이 결과를 전체 production 성공으로 합산하지 않는다.

관측 foundation [#44985](https://github.com/jeong-sik/masc/pull/44985)는 Native Stack44922의
19번째 층이다. Dashboard 직접 관련 3파일94건과 TypeScript 검사는 실제 PASS이며 공개
[검사 영수증](../docs/evidence/2026-10-22-exact-observation-timing/dashboard-verification.json)에
범위와 source hash가 있다. OCaml parser/source 확인은 컴파일·실행과 구분한다.
독립 draft 리뷰에서 발견한 세대 간 payload 정리, 재시작 뒤 합성 duration, 불가능한 failed
overlay fixture는 수리했으며 frozen-head 재검토와 선택 실행 증거가 필요하다.


## 2026-10-22 whole-stack restack and executed observation response

상위 Browser target이 1b189f483e5b1879b4e1bc4f1c85507bc683381b로 바뀐 뒤
Native Stack44922의 19층 전체가 재배치됐다. 기존 로컬19 head를 보존하고, 공개된
remote vector와 각 층의 patch를 대조해 채택했다. 재배치 직후 #44979는9a0ce9e8,
#44985는91e2199c다. 이전 head의 승인·실행을 새 승인·실행으로 취급하지 않는다.

기존 c7b42a1590974b99ebd87380c75cb248535364df의 선택 CI
[39694884916](https://github.com/jeong-sik/masc/actions/runs/39694884916)는 실제 컴파일 후
registry 36/37·projection17·Candle14·Librarian55건 통과, 전체 FAIL이었다. 실패는
NaN을 Safe JSON writer로 직렬화하다 codec 전에 예외가 난 fixture 오류다. 테스트만
Raw Floatlit 입력으로 바꿔 NaN/Infinity/-Infinity가 실제 finite decoder에 도달하는지
검사하며, production codec과 writer의 strict finite 거절은 유지한다. 이 수정의 새 실행
결과는 아직 미확인이다. 원래54개 항목명·완료 기준과 실제 provider/UI/설치 미완료 경계는
그대로 유지한다.
