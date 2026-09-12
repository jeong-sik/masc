# 2026-09-12 작업 재점검

원래 목표는 사용자가 지적한 18개 문제를 해결하여 Keeper가 목표에 집중하고, 서로 협업하며, 기억과 작업을 이어가는 제품을 만드는 것이다. 아래 상태는 완료율이 아니다. 9월 10일 보존 기록과 9월 12일 실행 결과를 구분한다. 전체 목표는 진행 중이다.

## 최신 후속 진행 (2026-09-13, CLI 및 파일 맥락)

- 설치본은4324764이며 실제자율Edit Chat수용은유지한다. LSP전체IDE에서실제source가보이는데didOpen은빈문자열인기존버그를직접재현했다. [설치baseline](../2026-09-13-installed-ide-lsp-baseline/README.md).
- PR #35611은851f412a88로진행했다. 기존Chat/Fusion/Gate+원본검사+LSP통합에읽기전용inspect-file CLI가포함된다. 실제native실패를따라Dune fixture descriptor,Tool_result 직접의존성,fs-rooted CLI cwd,ReleaseFFmpeg준비를수정했다. 새Test/Release를요청했으며설치성공은아직아니다.
- #16의가짜Codeanchor를별도main PR #35654/f1cde78d14로제출했다. 실제설치fixture는fileevents0인데3anchors였고,수정source브라우저는repoA1/repoB1/일치없음0을확인했다. 74tests/tsc/ESLint와직접·독립리뷰통과. 설치수용·Memo작성/갱신·Board오류표시·이력pagination·global이벤트의repo근거는별도로남는다.
- 원본검사probe는PNG실제디코딩,전체argv및같은입력,rawstreamkind를대조하도록3개오판을수정했다.9개회귀검사통과는probe검증이며새CLI실행성공이아니다. statecapture는canonicaltasks/backlog.json을필수로포함하고부모symlink를거부한다. [probe준비와범위](../2026-09-13-installed-media-probe-preparation/README.md).
- 전체18개목표,세Goal사람확인,장기다중runtime/기억연속성은계속미완료다.

## 현재 판단과 다음 방향 (2026-09-13, 설치 Chat 수용 후)

목표는 계속 18개 문제와 첨부 계약 전체다. 아래가 최신 관측이며 이후 절은 당시 기록이다. 작업은 각각 별도 worktree에서 진행한다.

| 영역 | 현재 확인한 도달점 | 다음 완료 조건 |
| --- | --- | --- |
| 자율 협업·비코드 산출물 | 전시·연작·참여형 산출물과 동료 검토·Task 승인 기록. 운영자 보조가 포함됐으며 세 Goal 모두 사람 확인 대기 | 다른 과제와 runtime에서 자발적 판단·협업·기억 재사용 재현 |
| 자율 Edit Chat | 설치본4324764에서 실제 실행0129의 원본·manifest·화면 diff 일치, desktop/mobile 통과. 정확한 source의 Test/Release 모두 성공 | #15의 남은 LSP를 설치 IDE에서 확인 |
| 독립 원본 검증 | PPTX·MP4·Board/Fusion 소스를 통합한 #35589. 31bdf Test는 중복 Dune 선언으로 실패. 원격 수정7bd85f를 직접·독립 검토하고 Test34707024488/Release34707026611 요청 | 수정 head CI를 확인한 뒤 설치 검증자가 원본을 직접 검사한 기록 확보 |
| LSP·IDE | 별도 worktree83f311에서 실제 내용 동기화·진단 상태 및 동일 경로 workspace 전환 수정. 111 tests와 실제 Chromium/ocamllsp 진단2→0 | 설치 MASC proxy·전체 IDE·Keeper 사용은 별도 검증 |
| 통계·설정·Tools/Skills·Preset | 개별 구현과 일부 화면 근거 | 설치 Dashboard/TUI의 연결된 사용자 흐름 수용 |
| 공유 기억·Local LLM | 기존 24개 source에서 10개 claim/2개 conflict 제안 및 동료 재사용 관측 | 의미 정확성과 자발적 채택, 장기 기억 연속성 검증 |

다음은 독립 원본 검증과 LSP의 설치 수용을 먼저 끝내고, 자율 협업·기억·모든 runtime의 10턴 및 1/2/4/24시간 연속성 실측으로 이어간다. 새 산출물을 늘려 이 남은 조건을 대체하지 않는다. token 낭비 감소나 전체 완료율은 측정하지 않았으므로 주장하지 않는다.

설치 서버는4324764/포트18951이며 health ok와 바이너리 SHA를 다시 확인했다. 재시작 비교98파일 중96개 동일,2개 memory journal은 기존 바이트가 보존된 append다. 실제 Chat 증거·PNG·CI·Goal 상태는 [installed-chat-4324764](installed-chat-4324764/README.md)에 있다. 전체 목표와 세 Goal의 사람 확인은 계속 미완료다.

## Chat 통합 후보 진행 (2026-09-13 이전 관측)

- Chat 단독 a28e의 native 6 suite/149 tests와 macOS ARM Release job이 통과했다. 바이너리·companion4개·runtime archive와 paired manifest 일치도 확인했지만, 현재 설치본의 Fusion·Gate 수정이 빠져 있어 배포하지 않았다.
- 협업 부모 f81284 위에 Chat 실행 ID·오래된 출력·manifest·직접 의존성을 통합한 PR #35581의 head는4324764e95다. 설치본 관련 Fusion/Gate/Board 소스 보존을 직접·독립 리뷰했고 UI203건/타입/parse13/DET 통과다. Test34705063187 및 Release34705064645를 요청했다. 새 후보 설치와 실제 Chat diff 성공은 아직 아니다.
- 실제 Chat probe의 lazy 조회 순서를 수정했다. 실행 행을 화면에 가져온 뒤 snapshot을 기다리며, 합성 Chromium 3case로 중복·다른 실행의 결과가 성공으로 오인되지 않음을 확인했다.
- Board/Fusion의 foreign-workspace 실패는 실제 결함이었다. 환경변수와 메모리에 올라온 저장소의 소유 경로가 달랐다. PR #35536 head25847ebc는 실제 로딩 경로를 고정하고 검증 조회에 사용한다. Test34704870980을 요청했으며 일반 Board 쓰기 경로의 환경변수 의존성까지 해결했다고 세지 않는다.
- 현재 서버는 aad94이며 전체18개 목표는 진행 중이다. 근거: [통합 후보·CI·probe 검토](chat-integration-4324764/README.md).

## 재점검과 다음 작업 준비 (2026-09-13, 현재 상태 직접 조회)

전체 목표는 18개 문제와 첨부 계약의 제품 동작이다. 지금은 구현·검증 인프라의 진전과 사용자에게 보이는 완료 사이에 간격이 있다. 다음 작업은 실제 자율 Edit의 Chat 표시와 독립 원본 검사에 집중한다. 18개 항목의 완료율을 산출하지 않는다.

- 원래 목표: Goal/Task에 집중하는 Keeper 팀이 비코드 산출물을 만들고, Fusion·동료 반론·기억을 실제 판단에 사용하며, 그 과정을 Dashboard/TUI/IDE에서 볼 수 있어야 한다. 모든 runtime의 10턴 및 1/2/4/24시간 연속성도 포함한다.
- 누적 시나리오: 전시·연작·참여형 전시 산출물과 동료 검토 기록을 확보했다. 현재 저장소에서 세 Goal 모두 `awaiting_confirmation`을 다시 확인했다. task-004의 승인 기록은 있지만 원본 PPTX/MP4 Read 실패 뒤 렌더/제작자 검사 로그를 이용한 승인이다. 독립 바이너리 검사를 완료했다고 세지 않는다.
- 현재 설치본: 포트18951은 `aad94bbf3fb90a4600496bf56d7590f02ff385ad`, version0.35.14, health ok다. 새 Chat 조회·Board/Fusion 검증·PPTX prerequisite 변경은 이 바이너리에 설치되지 않았다.
- Chat: 실행 식별자 연결 #35547 및 오래된 출력/manifest 조회 #35567 구현을 제출했다. 이전 UI 191건/타입 검사 기록은 존재하지만, `26ee98cf40`의 Test34702833667과 Release34702835195는 `Keeper_tool_call_index` unbound module로 실패했다. 현재 원격 #35567은 다른 세션의 부모 병합을 포함한 `72bd4de4ee`이며 검사 진행/대기였다. 이 새 head의 성공은 아직 확인하지 않았다.
- Board/Fusion 검증: `206c447685`의 Test34702739701은 foreign workspace source 조회가 예상과 달리 성공하는 case에서 6건 중 1건 실패했다. 단순 fixture 문제로 단정하지 않는다. 원격 #35536은 `707680884f`로 변경돼 있어 수정 전에 원격 구현과 대조해야 한다.
- PPTX prerequisite: #35565 `449743276f`의 Test34702828002는 CLI 구현의 `base_path` 인자와 mli 선언 불일치로 실패했다. Python 검사 통과만으로 native 기능 완료를 선언하지 않는다. 실제 PPTX 원본 파서와 렌더 기반 독립 검사는 별도 미완료다.
- MP4: #35532 `60f948bd80`의 PR build/release-check/typecheck는 성공, lint는 실패 상태였다. 이전 feature Test 성공과 현재 PR 전체 성공을 구별한다. 설치된 검증자의 실제 MP4 검사 증거는 아직 없다.
- 증거 #35363의 이전 push는 성공했다. 원격과 로컬 `b6f0aa4b34`를 확인했으며 다른 세션의 main 병합을 보존했다. 제품 소스 변경은 각각 worktree에 있다.

### 실행 순서와 완료 조건

1. **Chat 사용자 흐름 완결.** #35567 현재 원격 변경을 먼저 수용·검토하고 실제 직접 라이브러리 의존성을 확인한다. 같은 source의 Test/Release 산출물로 소유한 격리 설치본을 교체한 뒤, 실제 자율 Edit의 execution_id → 출력 manifest → before/after SHA → 화면 diff가 이어지는지 desktop/mobile 스크린샷과 로그로 확인한다. 기존 실패한 전체 펼침 검사를 동일하게 반복하지 않는다.
2. **독립 검증 완결.** Board/Fusion foreign-source 실패의 제품/fixture 원인을 분리한다. PPTX CLI 계약을 맞추고 workspace 관리 parser와 렌더를 연결한다. 설치된 검증자가 실제 PPTX를 파싱하고 실제 MP4를 디코딩하며 원문 Board/Fusion을 읽은 기록을 확보한다. 기존 task-004 승인을 뒤집거나 동일 증거를 재제출할 이유로 삼지 않는다.
3. **남은 제품 경험 확장.** 11–14 통계·Tools/Skills·설정·Preset의 설치본/TUI 통합 수용, 15–16 LSP·Workspace·주석·메모·누적 이력의 IDE 흐름, 17–18 공유 기억의 의미 정확성·Local LLM 결과의 자발적 재사용을 진행한다. 1–10의 자율 협업을 다른 runtime과 과제에서 재현하고 장기 연속성과 failover 조건을 별도 측정한다.

기존 산출물을 다시 만드는 새 과제보다 위 완료 조건을 먼저 닫는다. 사람 최종 확인은 세 시나리오 모두 별도이며 이번 gogo를 완료 확인으로 기록하지 않았다. 이번 점검에서 runtime 교체나 새로운 제품 소스 수정은 하지 않았다.

직접 조회 근거: [설치본과 세 Goal](reassessment-20260913-next/runtime-and-goals.json), [Chat Test 실패](reassessment-20260913-next/ci-34702833667-failure-excerpt.txt), [Chat Release 실패](reassessment-20260913-next/ci-34702835195-failure-excerpt.txt), [Board/Fusion 실패](reassessment-20260913-next/ci-34702739701-failure-excerpt.txt), [PPTX prerequisite 실패](reassessment-20260913-next/ci-34702828002-failure-excerpt.txt). 아래 절은 각각 당시 관측이며 이 절의 현재 CI 결과를 대신하지 않는다.

## 현재 구현과 시나리오 상태 (2026-09-13 00:45 KST)

- 오래된 자율턴 출력과 blob-backed 편집 manifest를 연결한 PR #35567 head `26ee98cf40`를 제출했다. Keeper별 정확한 execution_id GET 조회, 없음404·중복409·저장소503, 취소/동시Keeper 캐시 경계, 검증된 manifest의 before/after로 원본 버튼 표시를 구현했다. UI191개·Dashboard 타입 검사·선택 ESLint·OCaml파싱·독립 리뷰를 통과했고 Test34702833667과 Release34702835195를 요청했다. 설치본브라우저 수용은 남는다.
- 부모 Chat `f75aa4`의 Test34701658049는 통과했다. 원격 #35547에는 다른 main 병합 `2bb237b`가 추가돼 voice 타입 오류가 있으며, 이를 통과한 부모 커밋이나 새 branch26ee 검증으로 섞지 않는다.
- 실제 Edit0129는 manifest에서 before5237…12602B → after18e0…12641B다. artifact_refs 배열은 반대 순서이며 전후 방향의 계약이 아니다. 검사 스크립트가 배열 순서에 의존하던 오류를 수정하고 실제 파일·manifest 해시/길이와 잘못된 참조 거부를 확인했다. 이전 실패 기록은 유지한다.
- PPTX workspace prerequisite는 PR #35565 head449743276f, Test34702828002 요청까지 완료했다. Python56통과/12native필요skip, OCaml7parse·독립리뷰 통과다. 실제 PPTX 검사기는 아직 없다. MP4 #35532 head60f948은 PR-check의 build·editedtests·release·typecheck가 통과했지만 부모lint/version 문제는 남는다. Board/Fusion #35536은 Directfixture 문제를206c447685로 수정하고 Test34702739701을 요청했다.
- **시나리오의 현재 상태:** task004가15:23:06Z에Done이 됐고 세Goal 모두awaiting_confirmation이다. 하지만 승인 registry에서 PPTX·MP4 원본 Read가 모두failed였음도 확인했다. PDF/PNG 직접검사와 제작자manifest/decode/identity로그로 승인한 것이므로 독립PPTX파싱·MP4디코딩 완료로는 세지 않는다. 작업 상태와 실제 검증 범위는 별도로 유지한다. 새기능PR들은 아직 이 서버에 설치하지 않았다.

현재파일·Task·선택된검증registry·Goalphase와 실제원본은 [task004-completion-aad94](task004-completion-aad94/README.md)에 보존했다. 다음은 CI산출물의 실제Chat수용과 독립PPTX검사기다. 전체18개 목표와 사람확인·장기runtime·IDE·기억품질 조건은 계속 미완료다.

## 이전 구현 진척 (2026-09-13 00:18 KST)

- Chat 실패의 구체적인 원인을 실제 API 원문에서 확인했다. 자율턴428의 raw activity는 Edit2건의 이름·시간·성공만 전달하고 canonical execution_id를 버렸다. 원장에는 실행 ID와 전후 원본이 보존돼 있었다. 단순 접힘 재시도를 중단하고 원천 projection을 수정했다.
- 별도 main 기반 PR #35547, head `ae1290d076800ad02e12bd2f96926acfcc9ae0f7`를 제출했다. exact raw start sequence와 invocation turn/planned_index를 보존하고 TurnRecord가 선언한 실행 ID를 원장 전체에서 조회·검증해 Chat에 연결한다. 같은 provider ID의 병렬 호출·역순 완료·중복 시작·중복 원장 ID가 서로 다른 증거로 오귀속되지 않도록 수정했다. Raw reasoning·도구 입력/결과·provider ID는 이 Chat projection에 싣지 않는다.
- 파싱 검사, DET gate, 자율 Edit를 실제로 펼치는 컴포넌트 테스트(1 passed/165 skipped)와 독립 리뷰를 통과했다. 증거 로그의 끝 공백만 정리한 현재 head는 `f75aa4f193`이며 Test34701658049를 요청했다. 구현 head의 Test34701476206과 구별한다. 현재 네이티브 통과·설치·실제 브라우저 성공은 아직 아니다. 기존 설치본은 aad94다. 최근200건 밖 출력 hydration은 별도 남은 문제이며, 다음 의존 worktree `/tmp/masc-autonomous-chat-output-lookup-20260913`를 해당 head에서 준비했다.
- Board/Fusion #35536은 `ebab73c4`로 pagination과 첫 타입 오류를 수정·push했고 lint는 통과했다. 하지만 native Test34700788141이 추가 테스트 fixture의 `origin.turn_ref` 문자열/Ids.Turn_ref.t 타입 불일치로 실패했다. 이 오류도 후속 수정 대상이며 검증 도구 완료로 세지 않는다. MP4 #35532의 PR-check FFmpeg 의존성 수정은 `60f948bd809d2f4d8716d1242e11f6eec620dfcd`로 push했고 PR-check34701570972를 요청했다. 라이브 설치는 하지 않았다.

전체18개 목표는 진행 중이다. 원래 전시·연작의 사람 확인, task004 독립 재검증, 장기runtime·통합IDE·기억 품질 조건은 유지한다. 관련 소스·실측 기록은 #35547의 `docs/evidence/2026-09-13-autonomous-chat-execution/`에 있다.

## 이전 판단과 다음 작업 (2026-09-12 23:52 KST)

이번 요청은 기존 목표·실제 진행·다음 방향의 재점검이다. 루트 체크아웃은 읽기만 했고, 증거와 검사 스크립트는 기존 worktree `/tmp/masc-collaboration-resume-20260912`에서 정리했다. 아래 최신 판단이 이전 시점의 상태 설명보다 우선한다.

### 무엇을 하려 했고 어디까지 했는가

- **목표:** 18개 문제와 첨부 계약 전체. Keeper가 Goal·Task를 스스로 이어가고, 동료·Fusion·독립 검증을 활용하며, 실제 산출물과 Dashboard에서 행동을 확인할 수 있게 만드는 것이다. PR 수나 서버 시작을 완료 기준으로 삼지 않는다.
- **실제 도달:** 전시와 연작 협업·산출물·독립 검증 기록이 있다. 현재 저장소를 다시 읽어 전시 Goal과 연작 Goal이 모두 `awaiting_confirmation`, 연작 task-003이 `done`임을 확인했다. 사람 확인은 남는다. 관객 참여형 PPTX·MP4 Goal은 `executing`, task-004는 다시 `in_progress`다. 이전 제출물 제작과 독립 재검증 성공을 구분한다.
- **설치본:** 격리 포트 18951/PID42175는 `aad94bbf3fb90a4600496bf56d7590f02ff385ad`다. 실제 바이너리 SHA256은 `8942a20752f9312b31c0d0be18d29918a6f8e810839492b960cd833cac231a74`. full health는 status/overall_status 모두 `ok`, config error 0, operator_action_required false였다. 이 커밋의 Test34697880885(18 suite)와 Release34697882117 성공을 GitHub에서 재확인했다. 이전 문서의 “라이브는 2578, aad94는 미설치” 상태는 갱신됐다.
- **원격 PR은 별개:** 현재 #35515는 `3d3c094ab7e83f8985c61a185f6a1052462ae16b`, base `main`으로 바뀌었다. 그 PR check에는 Fusion 설명 첫줄 잘림과 schema 크기 검사 실패가 있다. aad94 설치본의 성공을 현재 PR head의 성공으로 옮겨 적지 않는다. 기존 worktree는 aad94에 그대로 있으며, 다른 세션의 원격 변경을 덮어쓰지 않았다.
- **Chat 수용은 미완료:** 처음 실제 API receipt를 받았어도 접힌 자율턴 내부 행을 기다려 실패했다. 실제 펼침 동작을 추가한 검사도 183개 펼침 뒤 대상 snapshot 행을 찾지 못했다. 최신 시도는 실제 API에서 exact Edit receipt 1개, manifest와 일치한 자산83개, HTTP/page 오류0을 기록했지만 표시 원본·diff 검사는 도달하지 못했다. 원인은 단순 접힘만으로 설명되지 않는다. 원본 데이터 부재나 diff 구현 고장으로 단정하지 않고, 로드된 이력의 갱신·trace 실행ID·receipt 결합·화면 표시를 다음 조사 대상으로 둔다. 두 실패의 원문 receipt·화면·스크린샷을 보존했다.
- **MP4 검증 도구:** #35532 `e45362b5`는 원본 바이트에 대한 FFprobe 메타데이터·FFmpeg 전체 A/V 디코딩 구현과 exact Test34699728493 성공까지 도달했다. 현재 PR check 환경의 FFmpeg 누락과 부모 lint/version 문제는 남고, 라이브 검증자에는 미설치다. 영상의 의미·시각·접근성 판정 전체를 통과했다는 뜻도 아니다.
- **Board/Fusion 검증 도구:** #35536 `bc39fb61`에 실제 원문 조회와 권한·오류 분류가 구현됐다. 현재 자체 테스트의 `Board.post` 타입 추론 오류와 pagination의 기본값 처리 lint 실패가 있어 완료된 후보가 아니다. PPTX prerequisite 작업은 `/tmp/masc-presentation-prerequisites`의 수정·신규9개 파일 상태이며 미커밋·미완성이다. PPTX 독립 검사 전체도 아직 없다.

### 방향 조정과 바로 다음 작업

1. **기존 설치본의 Chat 사용자 흐름을 먼저 확인한다.** 실제 target turn을 현재 이력과 연결하고, 화면 갱신 뒤 유지되는지 확인한 후 원본 두 개의 SHA·표시 diff·desktop/mobile을 검증한다. 동일한 전체 펼침 재시도를 반복하지 않는다. native 승인 후 원래 세션 재개는 별도 수용 조건이다.
2. **이미 드러난 독립 검증 공백을 완성한다.** Board/Fusion의 자체 타입·pagination 오류를 수정하고 MP4의 PR-check 의존성을 연결한다. 기존 부모/통합 PR 변경은 현재 head와 조정한 뒤 반영한다. PPTX는 prerequisite 초안 검토와 실제 원본 파서·렌더 검사까지 이어간다. 제작자가 만든 검사 JSON만으로 독립 검증을 대체하지 않는다.
3. **task-004를 정확한 최종 산출물로 재검증한다.** 후속 Chat 피드백에는 원천 동료/Fusion 근거 접근과 PPTX·MP4의 Q3 선택지 불일치가 지적돼 있다. 해당 최신 verifier 원문과 실물의 직접 대조는 다음 작업에 남는다. 원문 검증 결과·최종 파일·SHA를 대조해 각 반려 축을 해소해야 한다. 서버 교체나 검사 도구 구현만으로 Task 완료를 선언하지 않는다.
4. **그 다음 남은 제품 범위를 넓힌다.** 통계·설정·Tools/Skills의 설치본/TUI 통합 사용성, Workspace·LSP·주석·메모의 IDE 흐름, 공동 기억의 의미 정확성, 모든 runtime의 10턴 및 1/2/4/24시간 연속성은 남아 있다. 전시·연작 Goal의 사람 확인도 별도로 유지한다.

이번 재점검에서 새 과제·새 Gate·새 runtime 배포를 추가하지 않았다. 작업 우선순위는 기존 실제 시나리오의 사용자 흐름과 독립 검증 완결로 좁힌다. 전체 Goal은 진행 중이다.

근거: [현재 설치본](reassessment-aad94/runtime.json), [Goal·Task 현재 상태](reassessment-aad94/domain-status.json), [GitHub 조회](reassessment-aad94/github.json), [독립 CI 감사와 실패 로그](reassessment-aad94/ci-audit/README.md), [접힘 수정 뒤 실제 Chat 실패](reassessment-aad94/chat-expanded-failure/receipt.json), [실제 화면](reassessment-aad94/chat-expanded-failure/failure.png). 아래 18개 표는 누적 근거이며 최신 상태는 이 절을 따른다.

## 이전 판단과 다음 작업 (2026-09-12 23:06 KST)

- **제품 소스:** Task·Goal 원문 자동 전달(#35501), run_id로 전체 Fusion 원문 조회 및 Keeper 선택 분리(#35511), Board 조회의 거짓 성공·만료 추정 제거(#35510), 잘못된 Gate binding을 저장소 손상으로 분류한 오류(#35516)를 통합했다. 다음 후보는 #35515 head `aad94bbf3f`, Test #34697880885(18개 suite), Release #34697882117이다. 직접·독립 리뷰와 파싱 검사를 통과했으며 CI와 라이브 설치 수용은 남는다.
- **확인한 CI:** c45 Test #34696911670은 fusion_decision 4개, fusion_wake 17개 case를 통과했다. 부모 2855는 13개 suite 통과, Gate suite 7개 case 통과·1개 실패였다. 오류 분류 수정 a484를 다음 후보에 반영했다. 2855의 macOS 바이너리·자산·runtime·companion과 embedded source를 별도 임시 prefix에 설치·검증했지만 서버로 시작하지 않았다. 라이브 서버는 여전히 2578이다.
- **운영 장애 해소:** HITL auto-judge만 Kimi에서 Codex 전용으로 바꾸고 실제 저장·적용(13:49:13Z)·재조회 일치를 검증했다. 다른 TOML 의미는 동일하다. 이후 실제 52–55 판정은 모두 Codex가 완료·승인했다. 실행 결과는 별도다. 52의 검증은 exit 1, 53은 exit 0, 54는 프레임 추출, 55는 LibreOffice 변환과 PDF 출력을 관측했다. 55의 shell pipeline은 soffice 단독 종료 코드를 보존하지 않았다. 이전 Kimi quarantine 건의 자동 복구는 입증하지 않았다.
- **피드백 반영:** 운영자 피드백 operation `kmsg-dde4ba1ab7ab0e26456f6aa511e74704` 뒤 편집자가 올바른 Board body를 직접 읽었다. 패널 3/3·verdict_insufficient·TTL 소실·A+C 귀속 및 잘못된 접근성 전제를 정정하고, 자기 결정을 Fusion 권고와 구별했다. 전체 패널 원문 읽기나 `masc_fusion_decision`의 typed 기록은 아직 없다. 이는 기존 2578에서의 운영자 보조 정정이며, 자발적 정정이나 새 코드의 배포 효과가 아니다. 또한 full durable wake는 full model input의 증거가 아니다. 실제 모델 입력에는 480B preview 경로가 있고 최초 provider extra-context 본문은 보존되지 않았다.
- **실물 검증:** 최초 PPTX의 중복 관계 ID 2개와 잘못된 노트 경로 8개를 지적한 뒤 수정됐으며, 독립 관계 검사에서 오류 0을 확인했다. LibreOffice가 만든 8페이지 PDF를 모두 렌더해 한국어·허구 고지와 뚜렷한 잘림·겹침이 없음을 확인했다. 최신 PPTX는 25,462B/SHA4e0099d6…, PDF는 57,307B/SHAd2c682cd…다. MP4 초판 ac2f…는 디코딩·재생에 성공했어도 선택 기호가 깨져 있었다. 편집자가 고친 최신 345,612B/SHAe9f26dde…를 별도로 전체 디코딩하고 브라우저에서 재생했다. 115초·1920×1080과 31/58/85초의 정상 기호를 확인했다. 이 영상 검사는 Dashboard 수용을 대신하지 않는다.
- **독립 검증은 거절:** task-004는 14:05:31Z verifier `vrf-2d9391952b71da543a6b8ac9143af3f5`가 거절해 in_progress다. evidence/review의 예전 SHA, 완료·보류 상태 혼재, 검수 이미지의 파일명·크기·SHA 누락은 실제 제출 오류다. 동시에 검증자의 PPTX·MP4 원본 Read가 invalid_utf8로 실패하고 Board·Fusion 조회 도구도 없어 제품 공백이 드러났다. Keeper는 제출물을 보완하고, 다음 제품 작업에서는 검증자의 바이너리·미디어·원천 기록 조회를 보완한다. 검증 불가를 완료로 바꾸거나 같은 증거를 재제출하지 않는다.

전체 18개 목표는 미완료다. 다음은 ① 새 통합 후보의 실제 Chat·native 재개 수용 ② 검증자의 PPTX·MP4·Board/Fusion 원천 조회 ③ task-004의 정확한 최종 증거와 재검증이다. 이후 통합 UX·IDE·LSP, 공유 기억 품질과 모든 runtime의 연속성 조건으로 넓힌다. 원래 전시·연작 Goal의 사람 확인은 별도로 남는다.

근거: `fusion-feedback-candidate.json`, `ci-2855-gate-admission/`, `candidate-install-2855.json`, `hitl-codex-live-2578.json`, `codex-gate-correction-2578/`, `adaptation-feedback-2578/`의 초기 관측·Task 거절, 그리고 그 안의 `revision-2/` 최신 파일·브라우저 기록. 다음 검증 도구 작업의 진입점·권한·의존성은 `verifier-inspection-gap/proposal.md`에 정리했다.

## 이전 판단과 다음 작업 (2026-09-12 22:40 KST)

목표는 계속 18개 문제와 첨부 계약 전체다. 가장 강한 제품 증거는 전시 산출물과 연작의 자발적 착수·동료 반론·수정·Task 완료·Goal 검증이다. 두 Goal 모두 사람 확인 대기이며 전체 목표는 미완료다.

이번에 방향을 조정한다. 새 과제나 파일 형식 확대보다 **이미 실행한 결정의 정확한 소비와 설치본의 실제 사용자 흐름**을 먼저 완결한다.

1. **Fusion의 원문 전달과 소비를 각각 고친다.** 자율 턴408이 Fusion을 선택했고 GLM·Codex 두 패널이 answered, GLM judge가 synthesized했다. 그러나 Task·Goal ID가 생략되어 실제 계약이 전달되지 않았고, 듣지 못하는 접근성 상황을 소리를 내면 안 되는 환경으로 바꾸어 질문했다. 자동 원문 맥락 전달은 PR #35501, head `c45f51353e`, Test #34696911670 요청까지 완료했다. 미설치다.
2. **Fusion 완료를 판단 성공으로 세지 않는다.** 원본 Board post `p-c0bb49d30e7a617ea6596d100e845215`는 존재하며 두 패널과 실제 판정이 보존돼 있다. 편집자의 decision.md는 패널3/3, verdict_insufficient, TTL 만료 소실과 A+C 권고를 기록했으나 원본은 C 주+B 무음 보조 권고다. 정확한 결과와 ID는 전달·ack됐지만, 턴411이 ID를 잘못 조회한 후 세 번의 성공한 Edit로 오해를 문서화했고 턴414의 review.md에도 반복됐다. 조회·수신·문서 반영 경계에서 정확한 출처와 판단을 이어주는 작업을 다음 제품 우선순위로 둔다. 자동 Task 맥락 수정만으로 이 소비 실패가 해결된다고 주장하지 않는다.
3. **통합 후보에서 실제 Chat와 native 재개를 검사한다.** #35462의8fd Test는 quota만 통과하고13개 OCaml suite는 fixture의 직접 라이브러리 의존성 누락으로 실행 전 중단됐다. 독립 리뷰한 한 줄 수정0269010b89을 통합한 새 head는 `2855bbad1d`, Test #34696913204와 Release #34696914912를 요청했다.8fd의 macOS 배포 산출물은 내려받았지만 설치하지 않았다. 성공한 CI 산출물에서 native 현재 맥락·승인 후 동일 세션 재개·실제 연작 Edit의 Chat diff를 검사한다.
4. **현재 PPTX·MP4 과제의 실물을 끝낸다.** task-004는 생성53초 뒤 자율 claim했다. 결정·스토리보드·리뷰와 생성/검사 스크립트가 있지만 최신 파일 관측에서는 PPTX·MP4 완성본이 아직 없었다. 잘못 적힌 Fusion 판정부터 분리해 다룬다.
5. **이후 통합 UX와 기억 품질로 넓힌다.** Tools/Skills/TUI, IDE·LSP·주석·누적 이력, 공유 기억의 의미 정확성 및 모든 runtime의 장기 연속성은 여전히 제품 작업으로 남는다.

최신 full health는 source2578/PID89912/동일 binary SHA, overall_status=ok, uptime7765초였다. 실제 Kimi 실패→GLM 성공과 다음 턴 GLM 직접 성공도 확인했다. 이는 제한된 failover 사례이며 모든 runtime의10턴/1·2·4·24시간 성공을 대신하지 않는다. compact API가 lane_attempt_count를 빠뜨린 표시 수정은 별도 PR #35495다.

근거: `fusion-consumption-2578/receipt.redacted.json`, `spontaneous-fusion-result-2578.json`, `adaptation-decision-misread-2578.md`, `runtime-failover-2578.json`, `reassessment-health-2240.json`, `integration-candidate.json`, `fusion-active-context-candidate.json`.

## 이전 기준점 (2026-09-12 21:35 KST)

- 원래 목표는 18개 문제와 첨부 계약 전체다. 기능 소스·CI·설치 바이너리·실제 Keeper 행동·브라우저·사람 확인을 별도로 평가한다. 전체 목표는 미완료다.
- 격리 서버 포트 18951은 source `2578d7fec3061b0a8a05301eb465ae0521ce5461`, PID 89912, binary SHA256 `ec8e45b98440645b975959060e81a1cb69495f78835d7e42c400ffd4c793e2ef`다. 새 full health는 `ok`, uptime 3836초다. 이 서버 관측만으로 모든 runtime의 장기 연속성을 입증하지 않는다.
- 2578 교체 직전/직후 22개 파일 일치, 편집자의 원본 유실 operation 실패 종결, 뒤따른 동료 요청과 실제 수신 이미지 검수의 성공을 보존했다. 설치된 UI 자산 56개와 Goal 화면의 desktop/mobile 검사도 통과했다. 전체 Dashboard 검사는 아니다.
- 연작 소설 Task `task-003`은 개별 착수 지시 없이 편집자가 발견·claim·작성·실제 파일 전달·디자이너의 반론 10건 수신·실질 수정·제출을 수행했고 11:56:08 UTC에 Codex 검증자로 Done이 됐다. 원문 10,891B와 연속성·리뷰 문서의 실제 바이트/SHA256을 독립 대조했다.
- 편집자가 12:24:18 UTC에 연작 Goal 검증도 직접 요청했다. run `01a09593-60b3-7000-8ad3-40e51e183242`은 원래 criterion `46694c469406f3422f1f87d93f22ccfa`의 4/4를 승인했고 12:26:51에 `awaiting_confirmation`으로 전이했다. 원래 전시 Goal도 5/5 검증 후 같은 확인 대기다. 사람 최종 확인은 두 Goal 모두 없다.
- 과거 디자이너 답장 `kmsg-07110...`는 원래 native Gate session authority가 저장되지 않았다. 취소 전 요청·진단·승인 결과와 SQLite 사본을 보존하고 기존 운영 API로 명시 취소했다. POST와 별도 GET은 Cancelled, SQLite semantic은 Settled(Cancelled)다. 복구 성공이나 시간 만료로 표현하지 않는다.
- native Codex 재개 시 현재 맥락이 실제 세션에 전달되지 않는 결함을 소스와 native history로 확인했다. PR #35444 head `3b794b7e9b`의 Test #34693095605는 7개 suite(2/82/2/3/49/13/3 tests)가 통과했다. 수정은 아직 격리 서버에 설치하지 않았다.
- 실제 Chat 이력의 자율 Edit diff 검사를 시도했으나 Dashboard 요청이 operation quota를 소비하여 JS 모듈까지 429가 났다. PR #35447은 관측 GET/HEAD와 자산을 작업 quota에서 분리한다. 이전 CI는 자산 60회·인증 조회 4회 뒤 readiness 503에서 실패했고, 공식 `/health/ready`로 fixture를 수정한 head `7f8dd1a5ff`의 CI를 요청했다. 전체 burst와 실제 Chat 성공은 아직 미확인이다.
- 원래 2578 제품에 테스트 격리 수정만 적용한 `9a68af931e`의 Test #34691086194는 6개 case 통과다. 최신 main 통합 수정 `e967bbeb88`의 Test #34691732224도 12개 대상 suite가 통과했다. 이 CI를 새 native Gate 후보의 증거로 대체하지 않는다.
- 다음 실행 후보는 별도 worktree `/tmp/masc-collaboration-native-gate-20260912`, Draft PR #35462, head `94e98970f45971d8e9c5d17247e0b5a83a504e0a`다. #35450의 current-context/UI 수정 위에 #35449 native Gate, #35459 원본 source 재조정, quota fixture 수정을 통합했다. 원래 native session/operation/tool surface 유지, 원본 SHA retention과 CAS, 쓰기/읽기 scope 일치 및 context 주입 순서를 직접·독립 리뷰했다. Test #34694177184와 Release #34694053454를 요청했으며 결과·설치는 대기다.
- 증거 worktree `/tmp/masc-collaboration-resume-20260912`, PR #35363. 루트 main 체크아웃은 수정하지 않았다.

## 18개 문제의 진행 상태

| 번호 | 원래 문제 | 확보한 근거와 남은 조건 |
|---|---|---|
| 1 | Goal·Task 집중 | 전시 Goal 5/5, 연작 Task Done 및 편집자 자신의 Goal 제출→4/4 검증→사람 확인 대기를 실측했다. 다양한 과제·runtime 재현은 미완료다. |
| 2 | 중요한 결정에 Fusion 사용 | 자율 턴408의 실제 호출과 GLM·Codex 두 응답, GLM 판정이 보존됐다. 원래 계약 누락과 첫 문서 반영은 실패했다. 운영자 피드백 후 원문body조회·문서정정을 확인했고, 원문맥락 PR #35501은 CI통과, 전체원문조회 #35511은 통합CI요청이다. 자발적정정·typed선택기록은미확인이다. |
| 3 | Goal·Task가 실제 목표로 작동 | 원래 기준의 검증 제출·반박·수정·증명과 사람 확인 대기를 실측했다. 연작에서는 Task 완료 뒤 Goal 제출도 스스로 이어갔다. AGENT_CORE 저장소 막힘은 실제 해소했고 native Gate 수정의 배포 수용은 남는다. |
| 4 | 코드 작업 편중 | 전시 책자·포스터와 정확히 세 편의 완결 연작 소설 실물이 있다. 연작에는 동료의 반론 10건과 본문 실질 수정이 남아 있고 Task와 Goal 검증이 승인됐다. |
| 5 | 다양한 표현·파일 형식 | PDF/PNG/GIF/WAV/MP3 실물 기록이 있다. 최신 내부 Goal 검증자는 PDF 원본·3페이지·실제 PNG를 검사해 5/5를 승인했다. 추가PPTX8슬라이드/PDF렌더와115초MP4실물·디코딩·브라우저재생도확인했다. task004는제출증거불일치와검증도구공백으로거절됐고, 내부음성직접청취등도남는다. |
| 6 | 적극성 | 연작에서 개별 착수 지시 없이 발견·claim·작성·위임·비평 반영·Task 제출·Goal 검증 요청을 관측했다. 다른 runtime과 반복 실행에서의 일반화는 미완료다. |
| 7 | Owner에게 필요한 정보 요청 | 실제 Ask와 답변 반영을 관측했다. 이미 답한 내용을 재질문한 사례가 있어 장기 보존 검증이 남는다. |
| 8 | Keeper 간 위임 | 실제 파일 전달·수신 해시 일치·원천 확인 답장·Board 게시 및 연작 초고의 상호 검토를 확인했다. authority 없는 과거 답장은 명시 취소했으며 새 native Gate 연속성은 CI/라이브 수용 대기다. |
| 9 | 독립 검증자 맥락 | 설정된 Codex가 실제 PDF와 PNG를 읽어 Goal을 승인했고, 제작자와 수신 편집자 양쪽의 독립 image helper도 실제 포스터를 전사했다. 모델이 말한 검증·실측된 파일·사람 확인을 구별한다. task004검증에서PPTX/MP4원본Read의invalid_utf8와Board/Fusion조회부재가확인되어다음제품작업으로올렸다. 다른runtime과다양한검증맥락도남는다. |
| 10 | 토큰 낭비·선명성 | 이전 기록에서 26개 decision과 비용 행의 토큰 합계를 대조했다. 반복과 낭비 감소 자체는 아직 측정하지 않았다. |
| 11 | 통계 표시 | 분모와 원천 설명을 분리하고 SQLite 집계가 재시작 시 초기화된다는 오류를 수정해 e967 통합 CI를 통과했다. 실제 새 후보의 Dashboard/TUI 수용 검사는 남는다. |
| 12 | Tools·Skills 사용성 | 현재 CI preview와 실제 API에서 null 경로 처리·정확한 복사·원문 설명·키보드 펼침/접힘·모바일 전체 문장을 확인했다. 최초 높이 검사는 정수/분수 측정 차이의 false positive였으며 원본 측정과 캡처를 보존했다. Skills/TUI 전면 검사는 남는다. |
| 13 | 설정 반영 체감 | 실제 설정 preview/save의 applied, TOML 일치, Codex verifier와 standalone vision 실행을 확인했다. 이는 수동 후보 선택이며 자동 failover의 실증은 아니다. 전체 메뉴 반영 피드백은 남는다. |
| 14 | Preset 내용 보기 | CI 산출물을 이용한 실제 브라우저에서 246개 prompt 비교·전환·키보드·모바일 검사가 통과했다. TUI와 실제 모델 요청의 최종 조립 내용은 별도다. |
| 15 | Chat diff·LSP | 실제 자율 Edit의 원본/수정본과 receipt를 확인했다. 합성 Chat diff 검사는 통과했지만 실제 전체 Chat 검사는 JS 429로 실패했다. quota 수정 후 재검사하며 LSP 관측은 별도로 남는다. |
| 16 | Workspace·메모·누적 이력 | 기억 조회 UI 일부를 구현·검사했다. 저장소 맥락·코드 주석·메모·누적 이력의 통합 IDE 흐름은 미완료다. |
| 17 | 공동 공간 기억 | 합성 자료의 저장·재시작 후 조회·실제 Keeper 재조회는 관측했다. 실제 두 Keeper 자료의 통합안을 model_proposed 초안으로 저장하고 서버 교체 후 동일 조회까지 확인했다. 의미 오류가 남아 검증된 지식으로 승격하지 않았고 편집자가 실제 조회·출처 대조·인계 문서 저장·Board/자기 기억 기록을 수행했고, 정정판을 디자이너가 받아 다시 읽었다. 첫 해석에는 오류가 있어 정정했고 동료 검토는 진행 중이다. |
| 18 | Local LLM 활용 | 실제 로컬 27B가 두 Keeper의 24개 출처를 처리해 10개 주장·2개 충돌을 작성했다. 실제 편집자 인계 문서와 디자이너의 원천 확인 요청에 재사용됐다. 운영자가 요청한 흐름이며, 의미 검증 완료와 자발적 채택은 남는다. |

행2는 이번에 실제 원시 Board 결과와 편집자의 decision.md를 직접 대조했다. 다른 과거 결과는 아래 보존 문서를 읽어 확인했으며 현재 배포의 재실행 결과로 간주하지 않는다.

## 이전 계획 (22:40 재점검에서 위 순서로 조정)

1. **통합 후보의 실제 사용자 흐름을 먼저 닫는다.** #35462의 같은 head Test와 paired Release를 확인하고, 기존 설치 도구로 바이너리·자산·source identity를 검증한 뒤 소유한 격리 runtime을 교체한다. native 최신 맥락 반영, Gate 승인 뒤 원래 세션 재개, 실제 연작 Edit의 Chat diff와 429 해소를 검사한다.
2. **자율 협업은 확보한 경로를 기준으로 넓힌다.** 연작은 운영자 kickoff 없이 Goal 검증까지 이어졌다. 다음에는 자연스러운 Fusion 선택, 필요한 Owner 질문과 기억 재사용을 다른 과제에서 관측한다. 이미 확보한 소설을 다시 만드는 지시로 반복하지 않는다.
3. **통계·설정·도구의 통합 수용을 진행한다.** 기능별 preview나 CI 통과에 머물지 않고 설치된 Dashboard와 TUI에서 실제 동작을 확인한다. Skills·IDE·LSP·코드 주석·메모·누적 이력은 별도 제품 작업으로 유지한다.
4. **기억의 정확성과 runtime 연속성을 확장한다.** 로컬 27B 초안의 실제 재사용은 관측했지만 검증된 공유 지식으로의 승격과 모든 runtime의 10턴/1·2·4·24시간, 자연스러운 failover는 남는다.
5. **완료 판단을 분리한다.** 전시·연작 Goal은 사람 확인 대기이며 전체 18개 목표는 미완료다. CI 결과를 timer로 기다리지 않고 다음 제품 작업과 증거 검토를 진행한다.

## 근거

- [9월 10일 실제 협업·산출물·통계 및 브라우저 기록](../2026-09-10-collaboration-baseline/README.md)
- [9월 12일 업그레이드·쿼터 실패·전달 실패·로컬 기억 검토](README.md)
- [Preset의 CI 산출물 브라우저 검사](../2026-09-10-prompt-preset-content/README.md)
- [실제 Keeper Edit의 원본 증거](../2026-09-10-keeper-edit-live/README.md)
- [전체 Chat diff의 합성 입력 브라우저 검사](../2026-09-10-chat-edit-originals/README.md)
- [공간 기억 저장·재시작·Keeper 조회](../2026-09-10-workspace-memory-roundtrip/README.md)
- [공간 기억 조회 UI의 합성 입력 검사](../2026-09-10-workspace-memory-view/README.md)

이전 35be4 브라우저 기록의 실제 checkout은 GitHub merge commit 9f72a01f이다. 해당 검사는 실제 backend GET을 사용했고 WebSocket과 쓰기 요청을 차단했다. 이후 53203 후보로 교체하여 원래 Goal을 다시 검증한 기록은 아래 최신 증거에 별도로 보존한다.

이전 53203 증거는 `goal-approved-53203.json`, `runtime-upgrade-53203.json`, `official-vision-live-53203.json`, `goal-browser-53203/`, `tools-browser-53203/`에 있다. 당시에는 CI preview에 실제 API를 연결했으며 UI 설치 증거가 아니었다.

현재 증거는 `runtime-installed-2578.json`, `installed-ui-2578-reviewed/` (`probe_passed: true`), `editor-image-inspection-2578.json`, `peer-recovery-2578/`, `gate45-replay-and-correction.json`, `serial-fiction-start.json`이다. 첫 `installed-ui-2578/`도 실제 실행 결과지만, 리뷰가 지적한 명시적 성공·실패 기록 및 이전 스크린샷 혼입 방지를 보완한 재검사는 별도 reviewed 디렉터리에 보존했다. `peer-recovery-2578/`의 승인 대기 관측 뒤 실제 Gate45 계산이 실행된 후속 증거도 별도로 구분한다.

최신 추가 증거: `serial-autonomy-2578/`의 원문·동료 비평·Task 승인·Goal proof, `operator-cancel-op071.json`, `reassessment-health-2130.json`, `ci-verified-slices.json`. 과거 `task-completion.json`의 Goal executing은 당시 관측이며, 이후 `goal-proof.json`의 확인 대기 전이가 최신이다.

통합 Test 첫 요청 #34694052046은 하위 디렉터리의 두 suite를 bare name으로 지정한 운영 실수를 확인해 대기 중 취소 요청했다. 이후21:37 KST에 실제 `keeper_chat_operations/` 경로로 교정해 같은 head의 #34694177184를 요청했다. Release #34694053454는 그대로 유지한다.

## 21:57 KST 후속 진행

- Fusion collaboration 설정을 실제 preview/save API로 변경했다. panel은 GLM·Codex, judge는 GLM이며 commit/routing applied와 전체 TOML 의미 일치, GET readback을 확인했다. 기존 prompt와 다른 설정을 보존했다. 두 panel 실제 응답과 자연 failover는 아직 증거가 없다(`fusion-available-config.json`).
- 실제 설치 Chat probe를 추가했고 실행 ID·provider tool id·자율 턴·입력·출력·artifact 참조와 화면 원문/patch를 함께 검증하도록 독립 리뷰를 반영했다. Node 구문과 실제 보존 파일의 diff/patch 왕복만 검사했고, 설치된 후보의 브라우저 성공은 아직 아니다(`CHAT-ACCEPTANCE.md`).
- 다음 Goal `memory-garden-participatory-adaptation`과 `task-004`를 생성했다. 독자 선택권과 접근성의 표현 방식을 비교·논의한 뒤 실제 PPTX·MP4를 만든다. 개별 착수 또는 Fusion 도구 호출 지시는 보내지 않았다. 현재 생성/연결만 확인했으며 자발적 수행 증거는 추후 검사한다.
- native Gate 후보의 Release는 새 상태 분기의 warning4로 실패했다. `d2dbe6d297`에서 명시적 패턴으로 정정해 통합했고, 별도 native fixture runtime 초기화 수정 `da66b0a64d`도 통합했다. 최초 replay 기록과 재조회 기록의 문구 차이, setup의 입력 보정 보존에 관한 source 수정/리뷰가 진행 중이므로 새 배포 성공을 주장하지 않는다.
- 9월10일 디자이너의 다른 두 operation에도 original authority 없는 Gate binding이 남아 있음을 새로 확인했다. 이들은 이번에 취소하거나 복구하지 않았다. `remaining-original-gate-bindings.json`에 기록했으며 server health ok와 전체 queue 완결은 구별한다.

## 22:10 KST 작업 경계

- 실제 자율 턴 406이 task-004를 조회하고 12:56:58 UTC에 claim/start했으며 run_init까지 수행했다. task 생성부터 53초다. 해당 API 실행 receipt 세 건을 `participatory-adaptation-claim.json`에 보존했다. 13:00:46 UTC Fusion registry는 0건이어서 자발적 Fusion 성공은 아직 아니다.
- quota의 stateless MCP fixture에 필요한 Mcp-Name을 보완했고, CI-built942765 macOS 바이너리로 H1 전체 검사를 통과했다. 자산60회·인증GET4회 후 MCP4회200/5번째429, mutation429, GET유지, invalidtoken401, IP429가 실제 raw log와 일치한다. 독립 fixture이며 실제 Chat 브라우저 증거를 대체하지 않는다.
- Gate의 최초 replay 문구·paste correction·거절 identity 문제를 보완한 최종 통합 head는 `8fd8d20b3cf5a9f27c8c67024dd41b121277cd1e`다. PR #35462에 push했고 14개 실제 suite 경로를 확인해 Test #34695701869와 Release #34695703145를 요청했다. 직전94e Test는 실패 종결됐다. 새 후보의 native 실행과 설치 수용은 아직 확인 전이다.
