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
| A01 | 변경 TUI의 최소 검사와 정확한 소스의 실행 artifact 확보 | 고정6f68 및 수리d06fc922 native 각 TUI24+application5 PASS. matching 두 실행 파일 내장 SHA·해시·key reference와 clean 같은소스 Dashboard build 확인. 운영 설치와 구분 | `test_tui_lane_addons`·직접 관련 application 검사 결과, 실행 artifact의 source/build identity 확보 |
| A02 | 새 TUI로 On/Off/재연결 실제 화면 관측 | 6f68 실제 두 UI On→Off→On 및 Remove TOML+worker→재설치·세 incarnation/정리 확인. Evidence 직후 row 소실 #44895 수리 뒤 exactd06 실제 TUI에서 row/선택/원래 receipt/읽기실패 공존 및 정상 보존 확인. 새 후보 전체 lifecycle·운영 설치 별도 | 같은 설치의 이전/새 incarnation, 정리 상태, 원래 결과·receipt를 실제 화면과 API로 확인 |
| A03 | retained worker에 남는 Observe/Action 키 안내 정리 | #44721 main 병합. 고정 `7b16a917` 실제 TUI에서 retained 실행 키 미노출·수동 Observe 거절·이력 진입 확인; 전체 상세 새로고침 결함은 A02/G06에서 별도 추적 | 표시 가능한 행동과 실제 요청 허용 조건이 일치; 이력 조회·정리 조치는 보존 |
| A04 | MASC 코드·맥락 리뷰 대응 및 현재 head 판정 확인 | 공통 #44710·G01 #44803 및 G06 #44840의 6개 층 main 병합 확인. G06 병합 head와 이후 fragment-only branch head를 구분. Browser #44168 전체 현재 판정·남은 맥락 리뷰와 새 follow-up head의 재승인은 별도 | 실제 verdict를 읽고 P0–P2 해소, 바뀐 head/base/diff에 재결속 |
| A05 | Browser 스택의 후속 3개 층과 기존 증거 영향 검토 | 세 층의 전체 delta 직독; exact `76b741f` run `39555413943` 두 suite 14건 PASS, 독립 source delta 검토 PASS; 실제 앱·전체 스택 검증 별도 | #44695·#44698·#44702의 reply/download 정책 변경을 읽고 영향을 받는 경로만 검증 |
| A06 | 두 스택의 전체 통합 준비 | 공통·G01·G06 main 병합. pr-updater가 Browser67층 whole rebase/push 완료 보고; REST top #44702 aa0e05f6로 변경 확인. 현재 결속 승인0/67·old-head만43/최신승인부재24. top만dirty이며 로컬 main 비교에서도 작업표 문서 충돌 재현. Firefox 환경 전달 SOURCE PASS·실제 실행 별도 | REST stack 구성·각 head·독립 승인·미해결 리뷰·충돌 재확인; 병합은 전체 스택의 맨 위 PR로만 진행 |

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
| E01 | Candle Appraiser 판단 실행을 Addon으로 추출 | worker #44749·host wake #44750·identity #44768·production adapter #44769: export/공통 Exact host에서 원래 설치 결속·unknown 재실행 방지를 구현. 고정 d35의 worker 13건·compiled contract 2건·appraisal 24건 PASS와 실제 Docker 3개·동일 named volume의 원래 pending/answered/unknown 보존·변경 거절·정리 실측 및 독립 감사 증거를 보존. 현재 head의 실행 증거로 자동 이월하지 않으며 실제 host-managed Off/On·provider·원래 obligation 정산·두 UI는 미검증 | Grade/Relation/Weights와 typed 오류·trace 유지; 원장·중복 정산 방지는 host; Off 뒤 obligation 보존 및 재연결 후 정산까지 확인 |
| E02 | Workspace Curator의 모델 실행·작업 수명 추출 | 설계 필요 | fact intake·batch·briefing의 durable 상태와 commit 권한을 유지하며 중지·재개 확인 |
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
| G03 | 요청부터 종료·정리까지 원래 timeline/trace 연결 | 부분 구현; Dashboard가 버리던 host_requests를 원래 worker/incarnation에 결속해 보존·표시하는 후속 구현. 모델 lane/provider/operator/source 대기와 전달·기록 실패를 닫힌 타입으로 읽고, 손상 진단은 worker·결과와 분리. 전체 요청 이력·실제 화면·설치 검증 필요 | request/run/instance/revision, 대기 이유·결과·실패·정리 증거를 같은 원래 작업으로 추적 |
| G04 | 교체·경로/ID 변경·이전 소유자 이력 표시 | 후속 소스 구현: 같은 ID worker와 같은 TOML 경로의 다른 ID를 두 UI에서 분리. Dashboard 3파일62건·tsc PASS, TUI 관측 모델 parser PASS; 독립 리뷰·OCaml 실행·실제 UI 별도 | 새 worker와 과거 worker 구분, 다른 ID의 같은 파일 이전 owner 정리 기록도 별도 접근 |
| G05 | 에이전트 작업 중 표시와 현재 포인터/입력 활동 표시 | 범위별 재확인 필요 | 실제 동작 이벤트 기반으로 작업자·활동·포인터 위치 표시; 완료·중단·해제 때 표시 정리 |
| G06 | 두 UI의 편집·새로 읽기·부분 실패·workspace 변경 일관화 | 6f68 bare global Slice HTTP200·retained refresh·cross-run 거절·복구 관측. #44895 exactd06에서 Evidence 보존 뒤 원래 row/selection/receipt와 Slice EOF 유지·장애 해제 후 정상 보존 실측. application 관측 보존 독립 SOURCE PASS; 모든 workspace/revision 경계 미완료 | draft·원래 receipt 보존, 늦은 응답 거절, stale/unknown 표기, 화면에서 복구 경로 사용 가능 |


G04 후속 [#44807](https://github.com/jeong-sik/masc/pull/44807) · 다른 설치 ID의 같은 TOML 경로

기존 connection detail은 같은 installation ID의 worker만 골랐다. TOML 파일에서 ID를 바꾸면 같은 경로의 예전 소유자와 정리 실패가 이 관련 상세에서 빠졌다. Dashboard는 같은 ID의 worker 목록을 유지하고, 같은 source_path에 있는 다른 설치 ID의 기록을 별도 펼침 영역으로 보여준다. TUI는 같은 read-only 분류 모델을 사용한다. 각 기록은 실제 installation ID·instance·incarnation·revision·phase·관측 sequence를 보존한다.

같은 ID는 경로 이동 후에도 같은 그룹이고, 다른 ID는 source_path가 정확히 같을 때만 별도 관계로 남는다. 제목·run·package나 파일 basename으로 연결하지 않는다. Manual attachment는 같은 instance/incarnation만 읽으며 None 경로끼리 연결하지 않는다. 다른 ID의 기록은 현재 선언의 application이나 실행 권한을 대신하지 않는다. 생성 시각을 추정해 이전/이후라고 단정하지 않으며 별도 설치 소유자로 표시한다.

실제 완료한 검사: Dashboard `lane-addon-connection`, `lane-installation-manager`, `lane-addons-panel` 3파일62건 PASS, `pnpm exec tsc --noEmit` PASS, 변경 ML/MLI3개 parser PASS. TUI 새 검사는 원래 관측 모델의 그룹 membership·incarnation·retained 실패를 확인하며 화면 문구·배치 assertion을 추가하지 않는다. 이 OCaml 테스트 실행과 실제 TUI/Dashboard 화면 검증은 아직 없다. 기존 G01 스택과 실행 후보를 이 G04 소스 증거로 대체하지 않는다.


## H. 실제 사용·운영·배포 검증 — 6개

| ID | 남은 작업 | 현재 상태 | 완료 기준 |
| --- | --- | --- | --- |
| H01 | 같은 후보의 API·worker·Dashboard·TUI 조합 검증 | 같은6f68의 API·실제 worker·Dashboard·TUI 조합으로 Off와 Remove TOML+worker를 구분하고 재설치/세 incarnation/원래 이력/정리를 관측. Evidence 후 row 소실 발견으로 전체 성공 판정은 보류; 수정 후보 실행과 다른 패키지/운영 설치 별도 | On/Off와 Remove TOML+worker→재설치를 구분해 실행; 정확한 source/build 조합을 기록하고 서로 다른 증거 층을 합쳐 완료로 세지 않음 |
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

### 2026-10-22 KST · 같은 소스의 실제 두 UI와 재설치 경계

- [고정6f68의 실제 API·Docker·Dashboard·TUI 증거](../docs/evidence/2026-10-22-addon-current-native/README.md)를 보존했다. native39626945820의 기존24+5 suite와 matching 두 실행 파일 내장 SHA/해시를 직독 확인했고, 깨끗한 같은 source checkout에서 Dashboard를 빌드했다. 운영 설치를 교체하지 않았다.
- Dashboard On→Off→On 뒤 TUI Remove TOML+worker와 Dashboard New TOML 재설치를 따로 실행했다. 같은 installation ID에서 실제 세 incarnation이 각각 원래 입력을 읽었다. Off는 파일을 보존했고 Remove는 파일을 실제 삭제했다. 최종 Slice에 원래 세 row가 남고, 기록된 같은 engine에서 세 원래 container가 모두 부재였다. 임시 server/TUI/proxy와 browser task를 종료했다.
- global `slice {}`는 끝의 `?` 없이 실제 HTTP200을 받았다. empty의 complete=false를 전체 coverage 성공으로 바꾸지 않았다. 실제 Slice EOF·원래 row/selection/receipt·cross-run 거절·복구도 관측했다.
- 같은 실측에서 Evidence 성공 직후 후속 inventory가 retained row를 지우는 결함을 발견했다. #44895의 d06fc9229f2d46597933526d06863e0473c87874는 Evidence receipt만 반영하고 Request 전 application 마지막 관측/실패를 suspend로 보존한다. 독립 적대적 소스 리뷰에서 처음 찾은 application 초기화 P2까지 해소해 잔여 P0–P2 없음 판정을 받았다. 실제 수정 UI와 정식 승인은 별도다.
- 수정 후보 native39631388009는 정확한 현재 full SHA를 원격 PR과 대조한 뒤 요청했다. 앞 요청39631235633에는 작성자가 잘못된 full SHA를 전달해 queued 관측 뒤 취소 요청했다. 잘못된 요청이나 요청 접수는 실행 성공 증거가 아니다.
- [Candle 실제 container/volume 원본 증거](../docs/evidence/2026-10-22-candle-container/README.md)는 고정d35의 실제 세 container와 같은 persistent volume을 사용했다. 실제 host Runtime Off/On, common Exact provider와 host Paid 원장을 통과한 것으로 합치지 않는다. E01의 원래 완료 기준은 남아 있다.
- pr-updater terminal 응답은 Browser67층 whole rebase/push를 보고했고 REST top은 d35에서 aa0e05f6fcdfb4d0e5d35650dbbe07f169515971로 바뀌었다. 업데이트 보고는 source/승인/build/runtime PASS가 아니며, 기존67개 head의 승인은 새 head로 이월하지 않는다. 현재 승인·충돌과 삭제된 Keeper Firefox 환경 scrub 대체 경계를 독립 재검토한다.
- 전체54개 ID·작업·완료 기준은 유지했다. 이 checkpoint는 A01/A02/G06/H01과 E01의 실제 증거를 늘리고 확인된 결함을 수리한 진척이며, 운영 설치·Browser67층 병합·E01 전체·54개 완료 판정이 아니다.

- Browser 재배치 뒤 독립 census는 현재 결속 승인0/67, 최신 formal승인 부재24/옛head만43이며 current FAIL/HOLD·CR·Draft·미해결 thread0을 확인했다. top44702만dirty다. 실제 main c3efec4 대 aa0e merge-tree도 작업표 한 파일 충돌을 반환해 단순 API 전파 지연으로 단정하지 않는다. Firefox 삭제 전·후 실행 sink의 환경 허용목록은 독립 SOURCE PASS이나 이 사실이 전체67층 승인·실제 Firefox 실행을 뜻하지 않는다.

### 2026-10-22 KST · Evidence 결함 수리의 같은 head 실행

- [수정 후보 d06fc922의 별도 원본 증거](../docs/evidence/2026-10-22-addon-evidence-fixed/README.md): native39631388009 실제 성공(TUI24+application5), 두 executable 실행 SHA/해시 및 clean 같은 source Dashboard build를 확인했다. 실제 브라우저는 새로 열지 않아 Dashboard의 두 UI lifecycle 실측은 이전6f68 범위로 남긴다.
- 원래 임시 workspace의 Off 선언을 유지해 worker를 시작하지 않고 matching 새 server/TUI를 실행했다. server 재시작 뒤에도 원래 세 binding/row가 읽혔다. 원래 첫 worker의 row를 골라 실제 Slice EOF 상태에서 Preserve only를 실행해 동일 selected row·receipt·기존 read failure가 즉시 함께 남음을 관측했다. 장애 해제 뒤 정상 상태의 두 번째 보존도 같은 행을 유지했다.
- 새 실행의 원래 stored Evidence는 이전과 동일 digest2ed0cb5e…이며 실제 파일 hash를 확인했다. Broadcast·LLM·오디오·provider·Candle 정산은 실행하지 않았다. 새 임시 server/TUI/proxy도 종료했고 원래 PID 부재와 두 port refusal을 기록했다.
- #44895는 current d06fc922의 독립 정식 APPROVED를 받았다. 이후 Native Stack 연결 메타데이터가 생겼으므로 전체 scope의 최신 guard와 상위 증거 PR 승인/병합은 별도로 확인한다. 같은 head 실행 성공은 그 병합의 완료가 아니다.
- 두 UI lifecycle6f68·수리후 TUI d06·Candle container d35·Browser 재배치 aa0e를 한 후보의 전체 검증으로 합치지 않는다. 54개 작업명·완료 기준은 그대로 유지한다.
