# 2026-09-12 작업 재점검

원래 목표는 사용자가 지적한 18개 문제를 해결하여 Keeper가 목표에 집중하고, 서로 협업하며, 기억과 작업을 이어가는 제품을 만드는 것이다. 아래 상태는 완료율이 아니다. 9월 10일 보존 기록과 9월 12일 실행 결과를 구분한다. 전체 목표는 진행 중이다.

## 현재 기준점 (2026-09-12 21:35 KST)

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
| 2 | 중요한 결정에 Fusion 사용 | 이전 실행에서 명시적 요청에 따른 사용을 관측했다. Keeper 스스로 중요한 결정에 선택하는지는 미검증이다. |
| 3 | Goal·Task가 실제 목표로 작동 | 원래 기준의 검증 제출·반박·수정·증명과 사람 확인 대기를 실측했다. 연작에서는 Task 완료 뒤 Goal 제출도 스스로 이어갔다. AGENT_CORE 저장소 막힘은 실제 해소했고 native Gate 수정의 배포 수용은 남는다. |
| 4 | 코드 작업 편중 | 전시 책자·포스터와 정확히 세 편의 완결 연작 소설 실물이 있다. 연작에는 동료의 반론 10건과 본문 실질 수정이 남아 있고 Task와 Goal 검증이 승인됐다. |
| 5 | 다양한 표현·파일 형식 | PDF/PNG/GIF/WAV/MP3 실물 기록이 있다. 최신 내부 Goal 검증자는 PDF 원본·3페이지·실제 PNG를 검사해 5/5를 승인했다. 영상/PPT와 내부 음성 직접 청취 등은 남는다. |
| 6 | 적극성 | 연작에서 개별 착수 지시 없이 발견·claim·작성·위임·비평 반영·Task 제출·Goal 검증 요청을 관측했다. 다른 runtime과 반복 실행에서의 일반화는 미완료다. |
| 7 | Owner에게 필요한 정보 요청 | 실제 Ask와 답변 반영을 관측했다. 이미 답한 내용을 재질문한 사례가 있어 장기 보존 검증이 남는다. |
| 8 | Keeper 간 위임 | 실제 파일 전달·수신 해시 일치·원천 확인 답장·Board 게시 및 연작 초고의 상호 검토를 확인했다. authority 없는 과거 답장은 명시 취소했으며 새 native Gate 연속성은 CI/라이브 수용 대기다. |
| 9 | 독립 검증자 맥락 | 설정된 Codex가 실제 PDF와 PNG를 읽어 Goal을 승인했고, 제작자와 수신 편집자 양쪽의 독립 image helper도 실제 포스터를 전사했다. 모델이 말한 검증·실측된 파일·사람 확인을 구별한다. 다른 runtime과 다양한 검증 맥락은 남는다. |
| 10 | 토큰 낭비·선명성 | 이전 기록에서 26개 decision과 비용 행의 토큰 합계를 대조했다. 반복과 낭비 감소 자체는 아직 측정하지 않았다. |
| 11 | 통계 표시 | 분모와 원천 설명을 분리하고 SQLite 집계가 재시작 시 초기화된다는 오류를 수정해 e967 통합 CI를 통과했다. 실제 새 후보의 Dashboard/TUI 수용 검사는 남는다. |
| 12 | Tools·Skills 사용성 | 현재 CI preview와 실제 API에서 null 경로 처리·정확한 복사·원문 설명·키보드 펼침/접힘·모바일 전체 문장을 확인했다. 최초 높이 검사는 정수/분수 측정 차이의 false positive였으며 원본 측정과 캡처를 보존했다. Skills/TUI 전면 검사는 남는다. |
| 13 | 설정 반영 체감 | 실제 설정 preview/save의 applied, TOML 일치, Codex verifier와 standalone vision 실행을 확인했다. 이는 수동 후보 선택이며 자동 failover의 실증은 아니다. 전체 메뉴 반영 피드백은 남는다. |
| 14 | Preset 내용 보기 | CI 산출물을 이용한 실제 브라우저에서 246개 prompt 비교·전환·키보드·모바일 검사가 통과했다. TUI와 실제 모델 요청의 최종 조립 내용은 별도다. |
| 15 | Chat diff·LSP | 실제 자율 Edit의 원본/수정본과 receipt를 확인했다. 합성 Chat diff 검사는 통과했지만 실제 전체 Chat 검사는 JS 429로 실패했다. quota 수정 후 재검사하며 LSP 관측은 별도로 남는다. |
| 16 | Workspace·메모·누적 이력 | 기억 조회 UI 일부를 구현·검사했다. 저장소 맥락·코드 주석·메모·누적 이력의 통합 IDE 흐름은 미완료다. |
| 17 | 공동 공간 기억 | 합성 자료의 저장·재시작 후 조회·실제 Keeper 재조회는 관측했다. 실제 두 Keeper 자료의 통합안을 model_proposed 초안으로 저장하고 서버 교체 후 동일 조회까지 확인했다. 의미 오류가 남아 검증된 지식으로 승격하지 않았고 편집자가 실제 조회·출처 대조·인계 문서 저장·Board/자기 기억 기록을 수행했고, 정정판을 디자이너가 받아 다시 읽었다. 첫 해석에는 오류가 있어 정정했고 동료 검토는 진행 중이다. |
| 18 | Local LLM 활용 | 실제 로컬 27B가 두 Keeper의 24개 출처를 처리해 10개 주장·2개 충돌을 작성했다. 실제 편집자 인계 문서와 디자이너의 원천 확인 요청에 재사용됐다. 운영자가 요청한 흐름이며, 의미 검증 완료와 자발적 채택은 남는다. |

행 2의 Fusion 관측은 이전 세션 요약에 기반하며 이번 점검에서 원시 실행 기록을 다시 열지 않았다. 다른 과거 결과는 아래 보존 문서를 읽어 확인했으며 현재 배포의 재실행 결과로 간주하지 않는다.

## 다음 순서와 방향

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

통합 Test 첫 요청 #34694052046은 하위 디렉터리의 두 suite를 bare name으로 지정한 운영 실수를 확인해 대기 중 취소 요청했다. 실제 `keeper_chat_operations/` 경로로 교정해 같은 head의 #34694177184를 요청했다. Release #34694053454는 그대로 유지한다.

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
