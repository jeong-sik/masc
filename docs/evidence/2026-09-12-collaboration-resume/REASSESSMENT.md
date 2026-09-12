# 2026-09-12 작업 재점검

원래 목표는 사용자가 지적한 18개 문제를 해결하여 Keeper가 목표에 집중하고, 서로 협업하며, 기억과 작업을 이어가는 제품을 만드는 것이다. 아래 상태는 완료율이 아니다. 9월 10일 보존 기록과 9월 12일 실행 결과를 구분한다. 전체 목표는 진행 중이다.

## 현재 기준점 (2026-09-12 20:40 이후)

- 격리 서버: 포트 18951, source `2578d7fec3061b0a8a05301eb465ae0521ce5461`, PID 89912. CI Release #34690056205의 macOS 서버·UI 묶음을 설치해 실행했다. 실제 바이너리 SHA256 `ec8e45b98440645b975959060e81a1cb69495f78835d7e42c400ffd4c793e2ef`와 embedded source를 확인했고 교체 직전/직후 캡처한 22개 파일은 모두 일치했다. 후보 실행이며 출시 검증 완료는 아니다.
- 편집자의 기존 `kmsg-39825...`는 원본 checkpoint가 유실되었다는 실제 실패로 종결됐다. 대기하던 디자이너의 원천 확인 요청 `kmsg-290f...`와 새 수신 이미지 검수 `kmsg-3263...`는 실제 완료됐다. owner-store 오류는 사라졌으며 full health는 event backlog로 `warning`이다.
- 서버가 실제로 제공한 UI를 desktop/mobile에서 확인했다. 첫 검사 57개, 리뷰 반영 후 새 디렉터리에서 수행한 검사 56개 HTTP 자산이 설치 manifest 해시와 일치했다. Goal 5/5 확인 화면과 artifact 경고 부재를 확인했다. 쓰기·WebSocket은 차단했고 전체 Dashboard 정상이나 사람 확인을 주장하지 않는다.
- 새로운 결함: Codex designer의 답장 operation `kmsg-07110...`는 Gate checkpoint 소유권 조정 상태에 남는다. 공식 클라이언트는 native session/turn을 쓰지만 Gate suspend가 AGENT_CORE checkpoint만 검사한다. 실제 native authority를 연결하는 별도 수정 중이다. 승인 뒤 계산 replay는 성공했으며, 승인 전 독립 계산을 완료했다고 쓴 Board 문장은 시점을 구분해 정정했다.
- 최신 main 통합은 별도 worktree `/tmp/masc-collaboration-main-20260912`, Draft PR #35429, head `bac7df4369`다. native CI #34690665555에서 통계 metadata 함수의 `.mli` 공개 누락을 확인했고 `2cc4eb95b4`로 별도 수정했다. 두 수정을 함께 묶은 별도 stack PR #35440 (`e967bbeb88`)의 Test #34691732224와 Release #34691733430을 요청했다. 아직 통합 후보의 통과·실행을 주장하지 않는다.
- 원래 복구 source의 native Test 실패는 시나리오 간 `Runtime_lane_preference` 누수와 hook 예외 후 promise 미해결이었다. 별도 PR #35434 (`2626b3a16f`)에서 수정했다. 원래 2578에 이 테스트 변경만 적용한 `9a68af931e`의 CI #34691086194와 Release #34691087178도 요청했다. 제품 소스는 2578과 동일하나 테스트 결과는 별도 확인 대상이다.
- 전시 Goal은 같은 기준과 PDF/PNG의 5/5 검증 run `01a0953c-5e01-7000-9ed9-1003a66990c1`을 유지하며 `awaiting_confirmation`이다. 사람 최종 확인은 아직 없다.
- 다음 과제 `memory-garden-serial-fiction` / `task-003`을 생성했다. 세 편의 완결 소설·연속성·실제 동료 반론 반영·파일 증거의 네 기준을 명시했다. 디자이너를 `on_demand`에서 `autonomous`로 바꾸고 TOML 반영을 확인했다. 별도 직접 착수 요청은 보내지 않았다. 새 과제 생성 직후 디자이너 자율 턴 39는 “새 상태 변화나 남은 실행 작업이 없습니다”라고 답했다. 조립된 World State가 실제 native 세션에 전달되는지 조사 중이며 자발적 착수는 입증하지 못했다.
- 증거 worktree `/tmp/masc-collaboration-resume-20260912`, PR #35363. 루트 main 체크아웃은 수정하지 않았다.

## 18개 문제의 진행 상태

| 번호 | 원래 문제 | 확보한 근거와 남은 조건 |
|---|---|---|
| 1 | Goal·Task 집중 | 전시 출판 Task 완료와 최신 Goal 5/5 승인까지 실측했다. Goal은 사람 최종 확인 대기다. 운영자 개입 없는 자율 완수와 다양한 과제 재현은 미완료다. |
| 2 | 중요한 결정에 Fusion 사용 | 이전 실행에서 명시적 요청에 따른 사용을 관측했다. Keeper 스스로 중요한 결정에 선택하는지는 미검증이다. |
| 3 | Goal·Task가 실제 목표로 작동 | 원래 기준의 검증 제출·반박·수정 후 증명·사람 확인 대기까지 실측했다. AGENT_CORE 직접 요청의 저장소 막힘은 2578 후보에서 실제 해소했다. 공식 클라이언트 Gate 대기는 별도로 수정 중이다. |
| 4 | 코드 작업 편중 | Keeper가 실제 전시 책자와 포스터를 만들었다. 세 편의 연작 소설 과제를 추가했으며 실제 착수·완수는 아직 미확인이다. |
| 5 | 다양한 표현·파일 형식 | PDF/PNG/GIF/WAV/MP3 실물 기록이 있다. 최신 내부 Goal 검증자는 PDF 원본·3페이지·실제 PNG를 검사해 5/5를 승인했다. 영상/PPT와 내부 음성 직접 청취 등은 남는다. |
| 6 | 적극성 | 운영자 질문·교정·후속 요청이 많이 필요했다. 자율적 완수를 증명하지 못했다. 새 과제는 개별 도구 지시 없이 Goal/Task에 올려 발견과 착수를 관측한다. |
| 7 | Owner에게 필요한 정보 요청 | 실제 Ask와 답변 반영을 관측했다. 이미 답한 내용을 재질문한 사례가 있어 장기 보존 검증이 남는다. |
| 8 | Keeper 간 위임 | 포스터와 정정 인계 문서가 실제 artifact로 전달되고 수신 해시가 일치했다. 후속 위임을 받은 편집자가 실제 원천의 232바이트 발췌·전체 15,999바이트·SHA256을 확인하고 답장을 전달했다. 디자이너 수신과 Board 게시도 확인했지만 답장 operation의 Gate 종결은 남는다. |
| 9 | 독립 검증자 맥락 | 설정된 Codex가 실제 PDF와 PNG를 읽어 Goal을 승인했고, 제작자와 수신 편집자 양쪽의 독립 image helper도 실제 포스터를 전사했다. 모델이 말한 검증·실측된 파일·사람 확인을 구별한다. 다른 runtime과 다양한 검증 맥락은 남는다. |
| 10 | 토큰 낭비·선명성 | 이전 기록에서 26개 decision과 비용 행의 토큰 합계를 대조했다. 반복과 낭비 감소 자체는 아직 측정하지 않았다. |
| 11 | 통계 표시 | 현재 Tools API 산술은 맞지만 분모와 원천 설명이 섞였음을 확인했다. 직접 핸들러 수를 전체 MCP 도구 수로 설명하고 SQLite 보존 집계를 재시작 시 초기화한다고 표시한 오류를 수정 중이다. TUI와 전면 통합 수용 검사는 남는다. |
| 12 | Tools·Skills 사용성 | 현재 CI preview와 실제 API에서 null 경로 처리·정확한 복사·원문 설명·키보드 펼침/접힘·모바일 전체 문장을 확인했다. 최초 높이 검사는 정수/분수 측정 차이의 false positive였으며 원본 측정과 캡처를 보존했다. Skills/TUI 전면 검사는 남는다. |
| 13 | 설정 반영 체감 | 실제 설정 preview/save의 applied, TOML 일치, Codex verifier와 standalone vision 실행을 확인했다. 이는 수동 후보 선택이며 자동 failover의 실증은 아니다. 전체 메뉴 반영 피드백은 남는다. |
| 14 | Preset 내용 보기 | CI 산출물을 이용한 실제 브라우저에서 246개 prompt 비교·전환·키보드·모바일 검사가 통과했다. TUI와 실제 모델 요청의 최종 조립 내용은 별도다. |
| 15 | Chat diff·LSP | 실제 Edit의 보존된 원본/수정본 바이트를 확인했고, 합성 입력으로 전체 Chat diff 브라우저 검사도 했다. 실제 자율 Edit→전체 Chat 연결과 LSP 관측은 남는다. |
| 16 | Workspace·메모·누적 이력 | 기억 조회 UI 일부를 구현·검사했다. 저장소 맥락·코드 주석·메모·누적 이력의 통합 IDE 흐름은 미완료다. |
| 17 | 공동 공간 기억 | 합성 자료의 저장·재시작 후 조회·실제 Keeper 재조회는 관측했다. 실제 두 Keeper 자료의 통합안을 model_proposed 초안으로 저장하고 서버 교체 후 동일 조회까지 확인했다. 의미 오류가 남아 검증된 지식으로 승격하지 않았고 편집자가 실제 조회·출처 대조·인계 문서 저장·Board/자기 기억 기록을 수행했고, 정정판을 디자이너가 받아 다시 읽었다. 첫 해석에는 오류가 있어 정정했고 동료 검토는 진행 중이다. |
| 18 | Local LLM 활용 | 실제 로컬 27B가 두 Keeper의 24개 출처를 처리해 10개 주장·2개 충돌을 작성했다. 실제 편집자 인계 문서와 디자이너의 원천 확인 요청에 재사용됐다. 운영자가 요청한 흐름이며, 의미 검증 완료와 자발적 채택은 남는다. |

행 2의 Fusion 관측은 이전 세션 요약에 기반하며 이번 점검에서 원시 실행 기록을 다시 열지 않았다. 다른 과거 결과는 아래 보존 문서를 읽어 확인했으며 현재 배포의 재실행 결과로 간주하지 않는다.

## 다음 순서와 방향

1. **공식 클라이언트 Gate 연속성을 고친다.** 원래 runtime checkpoint 유실로 인한 저장소 막힘은 해소됐고, 다음 장애는 Codex의 native session을 AGENT_CORE checkpoint처럼 취급하는 경계다. 원래 operation과 실제 승인 replay의 identity를 유지해 이어가야 한다.
2. **연작 소설 과제로 자발적 행동을 관측한다.** task-003을 누가 발견·claim하고, 어떤 판단을 맡기며, 동료 반론을 어떻게 본문에 반영하는지 원시 기록과 실물로 확인한다. 필요한 조건을 요청하고 기억을 활용하는지도 관측한다.
3. **준비된 통계·설정·UI를 최신 main에서 통합 수용한다.** 컴파일 interface 누락과 fixture 격리 수정은 별도로 추적한다. 실행 중인 2578 UI 증거를 최신 main 후보의 증거로 재사용하지 않는다.
4. **기억의 정확성과 지속성을 넓힌다.** 실제 로컬 27B 제안의 재사용과 출처 대조는 확인했고, 추론과 실측을 혼동한 문장은 정정했다. 다음 창작에 이 기억이 유용하게 이어지는지 확인한다.
5. **남은 제품 범위를 유지한다.** 자발적 Fusion·Owner 요청·모든 runtime의 10턴 및 1/2/4/24시간·자연스러운 failover, TUI/Skills/IDE/LSP/코드 주석·누적 이력의 통합 사용은 여전히 미완료다. 전시 Goal의 사람 최종 확인은 별도 대기다.

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
