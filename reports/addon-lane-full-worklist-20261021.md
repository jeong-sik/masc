# Lane Addon 전체 작업 목록 · 2026-10-21

범위: 기존 Lane의 Addon 분리, 공통 연결 구조, Browser 기능, 에이전트 도구·Skill 접근,
Dashboard·TUI 관측, 실제 사용·복구·설치 검증. 이전 대화의 무관한 기능 개발이나 저장소 전체 PR 정리는 포함하지 않는다.
아래 54개는 남은 구현·설계·검증·통합 작업이다. 이미 구현된 기능은 다시 만드는 대신 남은 적용·검증 범위를 적었다.

## 현재 확보한 기준점

- 공통 관측 구현 [#44707](https://github.com/jeong-sik/masc/pull/44707):
  `566b98b5d1645d6312d518bf2810f3e5e0626586`. 서버 application/source revision/runtime presence를
  Dashboard가 보존하고, TUI에서 retained worker의 새 Observe/action 및 오래 열린 메뉴 제출을 거절한다.
- 관측 증거 [#44709](https://github.com/jeong-sik/masc/pull/44709):
  `cc4529a905bb66db977785ee61894bea00d16ac1`.
  실제 Docker/MCP worker를 Dashboard에서 On → Off → On으로 조작했고,
  이전 관측 보존·새 incarnation·새 입력 결과를 확인했다. 입력은 synthetic phrase snapshot이다.
- Dashboard 8개 suite 145건 및 TypeScript 검사 통과. OCaml은 parser 검사만 수행했다.
  두 PR의 독립 source/evidence 검토는 PASS이며, 정식 GitHub 승인·병합·설치와 구분한다.
- 위 두 PR과 A03 수정 #44721, 경계·작업표 #44726은 Native Stack #44710의 4개 층이며, 2026-10-21 후속 조회에서 모두 Ready/open/unmerged였다. CI 개선 #44727·changelog #44731은 별도 Native Stack #44732다.
- Browser Addon의 기존 6개 요구사항은 구현 및 범위를 고정한 분리 실측을 마쳤다.
  Deferred Tools·Hook 선택·host Exact Output도 그 범위에 포함된다.
  기존 완료 영수증 이후 Native Stack #44168이 67층으로 늘었으며,
  현재 마지막 PR은 [#44702](https://github.com/jeong-sik/masc/pull/44702),
  head `76b741f8816f074249baef3166ca152d9c9d2c13`이다.
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
| A01 | 변경 TUI의 최소 검사와 정확한 소스의 실행 artifact 확보 | exact `7f9e34b` native run `39555509454` 실행 중; syntax job PASS, native artifact 미완료 | `test_tui_lane_addons`·직접 관련 application 검사 결과, 실행 artifact의 source/build identity 확보 |
| A02 | 새 TUI로 On/Off/재연결 실제 화면 관측 | 미실행 | 같은 설치의 이전/새 incarnation, 정리 상태, 원래 결과·receipt를 실제 화면과 API로 확인 |
| A03 | retained worker에 남는 Observe/Action 키 안내 정리 | #44721 `7f9e34b` 소스 수정·독립 검토 2건 PASS; parser PASS, 새 TUI 미실행 | 표시 가능한 행동과 실제 요청 허용 조건이 일치; 이력 조회·정리 조치는 보존 |
| A04 | MASC 코드·맥락 리뷰 대응 및 현재 head 판정 확인 | #44707 현재 head 정식 승인 확인; #44721 재리뷰 접수, 맥락 queued | 실제 verdict를 읽고 P0–P2 해소, 바뀐 head/base/diff에 재결속 |
| A05 | Browser 스택의 후속 3개 층과 기존 증거 영향 검토 | 세 층의 전체 delta 직독; exact `76b741f` run `39555413943` 두 suite 14건 PASS, 독립 source delta 검토 PASS; 실제 앱·전체 스택 검증 별도 | #44695·#44698·#44702의 reply/download 정책 변경을 읽고 영향을 받는 경로만 검증 |
| A06 | 두 스택의 전체 통합 준비 | open/unmerged | REST stack 구성·각 head·독립 승인·미해결 리뷰·충돌 재확인; 병합은 전체 스택의 맨 위 PR로만 진행 |

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
| D02 | 기존 요청별 schema grant를 Candle에 재사용하는 계약 확정 | 기존 grant 재사용·완전 domain decode·단계별 ID·불확실 결과 계약 source/response 검토 PASS; 적용 구현 필요 | `Consumer_request_schema`의 권한·package baseline·요청 digest를 재사용; Grade enum·keeper 집합·weight 상한은 Candle의 완전한 domain decode로 검증 |
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
| E01 | Candle Appraiser 판단 실행을 Addon으로 추출 | 미구현, runner seam 확인 | Grade/Relation/Weights와 typed 오류·trace 유지; 원장·중복 정산 방지는 host; Off 뒤 obligation 보존 및 재연결 후 정산까지 확인 |
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
| G01 | 패키지·설치·worker·모델·도구·Skill의 연결을 한곳에서 보기 | 일부 구현; MASC 리뷰 P3: lane-inventory-panel의 instances.length 추측 표기를 host application으로 연결 필요 | 원하는 설정/실제 적용/연결 존재/실행/관측 준비/실패를 구분하고 원래 상세로 이동 |
| G02 | 입력→Hook→worker→모델→출력/소비자의 연결 관계 표시 | 일부 Flow 있음 | 실제 연결 reference에 근거해 표시; 관측 그래프를 실행 허가로 사용하지 않음 |
| G03 | 요청부터 종료·정리까지 원래 timeline/trace 연결 | 부분 구현 | request/run/instance/revision, 대기 이유·결과·실패·정리 증거를 같은 원래 작업으로 추적 |
| G04 | 교체·경로/ID 변경·이전 소유자 이력 표시 | 후속 소스 구현: 같은 ID worker와 같은 TOML 경로의 다른 ID를 두 UI에서 분리. Dashboard 3파일62건·tsc PASS, TUI 관측 모델 parser PASS; 독립 리뷰·OCaml 실행·실제 UI 별도 | 새 worker와 과거 worker 구분, 다른 ID의 같은 파일 이전 owner 정리 기록도 별도 접근 |
| G05 | 에이전트 작업 중 표시와 현재 포인터/입력 활동 표시 | 범위별 재확인 필요 | 실제 동작 이벤트 기반으로 작업자·활동·포인터 위치 표시; 완료·중단·해제 때 표시 정리 |
| G06 | 두 UI의 편집·새로 읽기·부분 실패·workspace 변경 일관화 | 기반/일부 검증 있음 | draft·원래 receipt 보존, 늦은 응답 거절, stale/unknown 표기, 화면에서 복구 경로 사용 가능 |


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

## 권장 순서와 완료 정의

1. A01–A06으로 현재 관측 변경과 Browser 추가 범위를 닫는다. 검사 대기 중에는 독립 작업을 진행한다.
2. B01–B06에서 host authority와 실제 실행의 경계를 확정하고, C/D의 기존 공통 경로를 재사용한다.
3. 첫 실제 추출은 E01 Candle Appraiser를 기준 사례로 삼는다. D02에서 기존 요청별 schema grant를
   재사용할 범위와 Candle의 host decode·실행 추적 계약을 먼저 확정한다. 필요한 Browser 공통 기반의
   통합 또는 명시적인 스택 의존성을 기록하고 새 중복 broker를 만들지 않는다.
4. Candle에서 On/Off/재연결/새 판단/중복 없는 정산을 G/H 화면·증거까지 완주한 뒤 E02 Curator로 확장한다.
5. E03–E12는 의존성과 효과 소유권에 따라 별도 작은 스택으로 진행한다. Browser F와 공통 G는 독립적으로 병행 가능하다.
6. 각 대상을 `구현 → 독립 리뷰 → 최소 실행 → 실제 화면/결과 → 통합 → 설치본 확인`으로 나누어 기록한다.

**대상별 완료:** 설정 저장, 실제 적용, worker 준비, 새 작업 성공, 원래 결과 보존,
Dashboard·TUI의 원래 근거 표시를 각각 확인한다. Optional은 Off 후 정리와 On 후 새 incarnation의
성공을 확인한다. Required는 필수 서비스 의무를 보존하는 교체·drain·복구 및 미처리 작업 승계를
확인한다. Required 서비스를 임의로 Off 할 수 있게 바꾸는 것은 이 계획의 완료 조건이 아니다.
설정 스위치·테스트 PASS·요청 queued·단일 happy path를 전체 기능 완료로 대신하지 않는다.

## 2026-10-21 구현 후속

- A03: #44721, head `7f9e34bab08484124bb18a477ecb5e5ba0fb5769`, base `cc4529a905bb66db977785ee61894bea00d16ac1`. retained/unknown worker의 실행 키 안내에 handlers와 같은 `can_observe`를 사용한다. 이력·정리·원래 receipt 조회를 보존했다. OCaml parser와 diff 검사 PASS; 독립 source/response 리뷰 PASS. 새 실행 바이너리·화면 증거는 아직 없다.
- B01/D02 경계 문서: [lane-addon-extraction-boundaries.md](../docs/design/lane-addon-extraction-boundaries.md). 현재 소스와 unmerged Browser 의존성, 옮길 실행/host authority, Candle의 단계별 요청 identity 및 typed 불확실 결과의 빈 경계를 명시했다. 문서가 실제 추출 완료를 뜻하지 않는다.
- #44707 코드 리뷰의 추가 P3는 G01에 보존한다. 단일 PR 승인을 전체 Native Stack 승인으로 확대하지 않는다.
- A01: [native run 39555509454](https://github.com/jeong-sik/masc/actions/runs/39555509454), source `7f9e34bab08484124bb18a477ecb5e5ba0fb5769`, workflow `cccb1fc4808435ed06ece3e586095f37d8dd449c`, scenario `addon-lifecycle`. 별도 CI PR #44727의 두 독립 source 검토는 최종 head PASS다. 두 기존 suite와 matching server/TUI/key generator를 선택했으며 실행 조회에서 source/config syntax job 성공, native job `119074243862` 실행 중을 확인했다. 완료 artifact는 아직 없다. 기존 TUI suite는 presentation assertion도 포함하는 mixed suite다. artifact 생성은 실제 화면 검증과 구분한다.
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
