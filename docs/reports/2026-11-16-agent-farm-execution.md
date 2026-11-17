# Agent Farm 실행 기록 — 2026-11-16

사용자 요청은 25개 요구를 갖춘 MASC를 실제로 동작하게 만드는 것이다.
[11월 12일 계획](2026-11-12-agent-farm-plan.md)의 범위·조각·단계별 성공 조건은 유지한다.
이 문서는 그 계획의 현재 실행 위치를 적는다. 계획의 `covered`는 설계에서 다루었다는
뜻이지 구현·실측 완료가 아니다. 아래 후보로 전체 목표나 어느 단계를 완료 처리하지 않는다.

초기 조사 기준은 로컬 `85f2823f053a693cecc8b63d6d0cb460dd10f9d0`이며,
후속 후보의 별도 base와 검토 head는 아래에 적는다.
초기에는 다른 세션의 작업을 별도 worktree에서 확인했으며, 원격 main과 열린 PR의
구현 대조는 아래 게시 준비 checkpoint에서 이어갔다. 미확인은 기능 부재 판정이 아니다.

## 2026-11-17 게시 준비 checkpoint

`gh api user`의 계정 조회와 지정된 협업 세션의 읽기·메시지 전달이 다시 성공했다.
아래의 연결 실패와 게시 위임 실패는 그 이전 관측이며 현재 인증 상태를 뜻하지 않는다.
Document 9층은 `gh stack rebase`로 전체를 `f9083a9957785a942d71611adb857d8d49a73388`
위에 올렸다. 23개 커밋의 패치는 이전 후보 `46e09ab0b1e73ce621c65eef75329b1df6475dac`와
`git range-diff`에서 모두 같았고 충돌은 없었다. 재기반 직후 leaf는
`bd48b2e74d28653eebf3ba9ee1815e7a5db4709f`이며, 이 문단은 그 뒤의 문서 보완이다.

게시 전 원격 PR의 파일·diff와 변경된 main의 직접 소비자를 별도로 대조한다.
이 checkpoint에서 실행 시험을 다시 돌린 것은 아니다. 아래의 Core 18개, MCP 8개,
retained decoder 7개와 타입 검사 결과는 각각 기록된 소스의 증거로 유지한다.
현재 head의 소스 검토와 Draft 게시 여부는
[Document 추적 이슈 #52591](https://github.com/jeong-sik/masc/issues/52591) 및
[Schedule 추적 이슈 #52592](https://github.com/jeong-sik/masc/issues/52592)에 연결된 PR에서 확인한다.
이번 게시 범위는 Schedule 3층과 Document 9층이다. UID·Librarian·설치·운영 복구와
원래 25개 요구의 완료는 이 checkpoint로 확인되지 않는다.

## 게시 준비 이전 후보와 담당

| 작업 | 확인한 산출물 | 증거와 남은 일 |
| --- | --- | --- |
| Schedule 저장 권위 | 재기반한 소스 `236754fcfb72f49ef9c365465dfd1e63cf3e6010`: 복구 mirror를 변경 근거로 쓰지 않으며 읽기 출처를 보존한다. 별도 스택 `fix/farm-schedule-authority-20261116` | 재기반 뒤 독립 소스 리뷰에 P0/P1/P2 없음. 후속 실제 FileSystem 시험 11개·새 프로세스 재열기 6회 통과. 아래 범위로 한정하며 서버·provider·PR 게시·설치·원래 장애 회복은 미확인. 별도 스택의 `docs/evidence/2026-11-16-schedule-primary-authority/README.md`에 이전 구문 기록과 후속 실행을 구분한다. |
| WIM-S03 문서 입력 | 현재 Core `db69904f29c6f4a6166957fbdffa4f7e8e910a7a`, MASC `be648b8e1bfe796c250ddb37fab6c9b00f03ccb6`: 문서·혼합 입력 선언, H5 읽기, wire·크기 추정·재생의 문서 투영을 맞춘다 | [증거 기록](../evidence/2026-11-16-farm-document-input/README.md). 기존 79개 파일의 소스 리뷰와 후속 Core 3개 파일 수리를 구분한다. 실제 Core 미디어 suite 18개 통과; 최종 커밋과 소스 118개·metadata 9개가 일치한다. 이전 Dashboard 타입 검사와 decoder 1건은 당시 범위다. MASC 전체 타입·실제 provider·PDF/STT·브라우저·설치 미확인 |
| TLJ-S01 위임 결과 | 협업 세션 `01a1e1b9…`, `.worktrees/farm-evolution-20261116`. 세 층 최종 head `e6ea78da93a1ebac6f6020aafb134631024ba769`, base `606e16f5ce8b5c69ad9d18e82f6bf076aaf7f13d`. canonical 종단 상태, 기동 재투영, 영속 전달 의도·답 원문·전달 영수증을 연결 | 두 P2였던 보관 기간 뒤 중복 전달과 fail-open journal 뒤 답 유실을 소스에서 수정했다. 재기반 후 독립 검토에서 미해결 P0/P1/P2 없음. 기존 세 패치와 range-diff가 같고 32개 후보 파일이 이전 최종 head와 일치함을 확인했다. 작성 세션의 OCaml 31개 구문 검사 기록이 있다. 타입·동작·CI·설치·원래 요청 회복·GitHub 정식 승인·게시 미확인 |
| WIM-S04 MCP 결과 | 현재 소스 `4202159afd7cdbc9259296ceb09f7fa8f6c0d05f`: 일반·승인 호출의 audience 투영, 미디어·일반 binary 보존, 공개 manifest·실제 승인 결과 원장·chat의 보관 소유권과 status 노출 경계를 연결 | [증거 기록](../evidence/2026-11-16-farm-mcp-content/README.md). 현재 base의 독립 소스 리뷰에 미해결 P0/P1/P2 없음. 고정 `ad6ba29`의 실제 decoder/projection suite 8개 통과, 원본 입력 239개를 대조했다. 일반 MCP 호출·승인 replay·GC·H5·실제 provider·전체 MASC 타입은 미검증. 기존 구문 기록과 Core 18개 시험은 별도 범위다 |
| Lifecycle START 입력 | UID 26층 `7e3227db41ee1b14016621a26eb4e921872851ca`, 고정 base `d2fa5aadd2f4f64ec0ee1574decb769085b4f3cf`: 준비·TUI·서버 소유 시점에 맞춘 START 전달 | 새 base의 실제 원본 입력 187개를 fresh compile/link해 maintained suite 13개 통과, skip 0. 이전 `62fc1432`의 baseline 3개와 ingress probe 8개는 재실행하지 않았다. 전체 CLI/TUI·설치·Linux `sg`·전체 Dune 검증은 아니다 |
| IA-S13 공유 SSH 이름 | 현재 26층 top `7e3227db41ee1b14016621a26eb4e921872851ca`, 고정 local base `d2fa5aadd2f4f64ec0ee1574decb769085b4f3cf`. 아래 초기 구현 커밋과 이전 실행은 원래 head의 기록이다. `.worktrees/farm-remote-namespace-20261116`의 재기반 전 시작점 `71a19f1c9030978d8ccf54e311782b6cfed6d1d5`. 공용 I/O `e85a523e115355e58c87283c6c6f3b8cc9a0a393`, 게시·복구 엔진 `c09c461ac91598e4e41c42f25c6ad88f1ec14352`, UID 생성기 `40605b3164e9efb88c3ba3d5f8f25dc89c36e26d`, SSH 경로·효과 준비 `d20ff52623871b22eacb705498356a84a6e1759d`, 생성 잠금 공유 `107ed0a199696cf27a8d1b18d47456bb459b54a4`를 커밋했다 | 재기반 21층의 독립 소스 리뷰와 새 소스 263개의 집중 시험 76개를 후속 checkpoint에서 확인했다. 이전 게시·복구 엔진의 격리 시험 62개에는 기반 I/O 14개가 포함된다. 후속 UID·잠금 시험 15개도 실제 파일시스템에서 통과했고, 해당 7개 변경 파일의 독립 소스 검토에 미해결 P0/P1/P2가 없다. SSH 35개 파일은 독립 소스 리뷰와 구문 검사만 확인했다. 서버·Workspace와 첫 쓰기 연결의 후속 커밋은 아래에 적었다. 전체 시작 흐름·실제 SSH·VM·volume GC 전환은 미완료. 원격 데이터 변경·삭제·설치 없음. `U02:IA-S13`은 승인 완료가 아님 |

본 세션은 저장·add-on·입력 경계와 이 실행 기록을 맡는다. TLJ-S01의 같은 구현을
다시 만들지 않고 해당 세션의 산출물을 현재 head에서 대조한다. 기록된 스택 게시 시도는
로컬 `gh stack` 인증 토큰 부재로 종료됐다고 각 증거 기록에 남아 있다. connector 조회가
가능하다는 사실은 native stack 게시 완료를 뜻하지 않는다. 원격 반영 전에 실제 main,
스택 구성과 겹치는 작업을 다시 확인한다.
후속 직접 조회 `gh api user --jq .login`도 `error connecting to api.github.com`으로
종료됐다. 이는 해당 실행 환경의 연결 실패이며 사용자 계정의 인증 실패 판정이 아니다.
상대 세션으로의 게시 요청도 thread 도구 연결 오류로 전달을 확인하지 못했다.

TLJ-S01의 재기반 소스 diff SHA-256은
`efdf0d71026e4a684de9210f2aca82aae4451df2c7ff8848ec5c88ed071cd585`다.
전달 의도가 없는 기존 operation의 과거 전달 여부는 여전히 불명확하며,
이 수리로 원래 멈춘 요청이 실제 회복됐다고 판단하지 않는다.
상대 세션의 추가 MCP 교차 검토도 `fb685831`의 보관·effect 경계에 한정된 소스 기록이다.

IA-S13의 격리 검사는 OCaml 5.5.2로 실제 모듈·C 구현을 컴파일해 임시 파일시스템에서
실행했다. 부모 경로 교체, no-replace, rename 뒤 프로세스 종료·복구와 정리 실패를
다뤘으며 MASC 전체 빌드나 실제 SSH·설치 증거는 아니다. 로컬 영수증은 해당 worktree의
`artifacts/farm-blocking-publication-20261116/run-5/`에 있다.
62개는 게시 시험 7개, I/O 14개, 기존 reconciliation 34개와 실제 SIGKILL·재열기 7개다.
98개 컴파일·링크·실행 명령이 성공했으며 전체 Dune 의존 그래프 검증은 아니다.
UID·잠금의 후속 영수증은 같은 worktree의
`artifacts/farm-workspace-birth-20261116/adoption-3/`에 있다.
실제 소스 137개의 해시를 대조했고 컴파일·링크·실행 명령 142개와 시험 15개가 성공했다.
두 스레드가 실제 macOS 볼륨 별칭을 통해 들어와도 생성 잠금을 공유하며, 기다리는
요청이나 오래된 namespace가 현재 작업의 프로세스 잠금을 풀지 않음을 확인했다.
UID 생성기의 중단 시험은 fork와 `_exit`이며, 위 게시 엔진의 SIGKILL 시험과 구분한다.
`Host_config`는 실제 공개 인터페이스의 타입만 사용했다. 호스트 환경 설정 해소,
전체 Dune 그래프, Linux와 서버 시작은 실행하지 않았다.

Keeper 재시작 전체를 SSH 가용성으로 막던 중간 후보는 철회했다. 작업 디렉터리 준비는
승인된 SSH 명령·파일 쓰기 경계에 연결했다. 원격 장애가 다른 Keeper 활동을 막지
않도록 하는 소스 변경이며, 실제 SSH 동작은 아직 검증하지 않았다.

앞선 checkpoint에서 확인한 협업 세션의 TLJ-S02/E8 다섯 층은
`715d3dd28e0f2ee3a8a13c9c66ead42ed900726c`다. 해당 worktree의 head와 clean 상태,
`docs/reports/2026-11-16-librarian-declaration-replacement.md`를 직접 확인했다.
연결된 history Captured/Cut까지 종료 증거와 후속 요청의 intent/ACK를 연결하고,
완료된 descendant의 range receipt로 원래 operator resolution을 추적한다는 보고다.
작성 세션은 두 독립 소스 리뷰와 49개 파일 중 OCaml 47개 구문 검사를 보고했다.
이 기록의 작성자가 그 전체 소스나 동작을 다시 검증한 것은 아니다. 타입·회귀·운영은
미실행이며, native submit도 token not found로 종료됐다고 보고했다. partial을 유지한다.

그 뒤 작성 세션은 일곱째 층 `7200e23e3d22166f88bf9ecf0fa0ffa57d32cffa`를 보고했다.
미소비 batch 전체를 다시 고려하는 admission 단위의 14개 파일에 독립 소스 리뷰 두 건,
OCaml 13개 구문 검사와 미실행 회귀 9개가 있다는 보고다. 이전 다섯 층만 대상으로 한
게시 위임은 작성 세션이 철회했으므로 사용하지 않는다.
해당 `next-unit.md`는 main의 Missing_after_dispatch 수리와 함께 재기반할 항목을 적고 있다.
후속 조회 때에는 `.worktrees/farm-librarian-admission-replacement-20261116`의 HEAD가
`4fb63016f6cbb80139dbda3b99940733a5804a8e`였고 execution 구현에 미해결 충돌이 있었다.
이는 조회 시점의 worktree 상태이며, 앞선 고정 head의 소스 리뷰를 새 통합 결과로 옮기지 않는다.
현재 통합·게시 완료 여부와 원래 요청의 실제 회복은 별도 확인 대상이다.

이후 `.worktrees/farm-librarian-admission-replacement-20261116`에서
head `4aae41288a5dbba0fb27bfeafea5999dd7fec77c`와 clean 상태를
직접 확인하고 `rebase-and-review-4aae412.md`를 읽었다. 작성 세션은 보유한 Git 객체를
읽는 임시 local remote로 일곱 층 전체를 native rebase했고, base는
`4fb63016f6cbb80139dbda3b99940733a5804a8e`라고 기록했다. 두 독립 리뷰가 통합 범위와
마지막 두 테스트 match 수정을 확인했다는 보고다. 59개 OCaml parser 영수증 중 12개는
새 검사, 47개는 같은 바이트의 이전 검사다. 타입·회귀 실행·원래 요청 회복은 미검증이다.
이 관측은 앞선 충돌 snapshot 이후의 상태이며, root가 전체 소스를 다시 승인한 것은 아니다.
작성 세션의 submit은 token 조회에서 실패했고, root의 후속 `gh api user`도 연결 실패였다.
원격 게시와 재기반은 구분한다. 이전 다섯 층만 게시하라는 위임은 계속 철회 상태다.

후속 아홉 층은 `.worktrees/farm-librarian-bodyless-preflight-20261116`의
`f08b9f38f01a6ba16af375f3c025209191f9a490`이며, 이 head와 clean 상태를 직접 확인했다.
base는 `e0e819e29968366c1dffb59ad625ba4e17d4ac22`, 직전 여덟째 층은
`9f5e4e22b65cbb6582cc8656470d3e84a519a5c8`다. 해당 worktree의
`artifacts/farm-librarian-bodyless-preflight-20261116/source-review-f08b9f3.md`와
`source-checks-f08b9f3.json`, `native-stack-f08b9f3.json`, `next-unit.md`를 읽었다.
작성 세션은 고립된 strict Before_dispatch History의 종료 증거를 본문 복원보다 먼저
판정하는 12개 파일 수리와 두 독립 소스 리뷰를 보고했다. 11개 OCaml 구문 검사는
5.5.1이며 요구 버전은 5.5.2다. 이 문서의 작성자가 해당 스택의 타입이나 동작을
검증한 것은 아니다. 원래 요청 회복·실행·설치·게시도 미확인이며 이전 checkpoint는
역사적 기록으로 유지한다. 현재 main 통합 전에는 아홉 층 전체를 다시 대조해야 한다.

상대 세션의 다음 Librarian 10층 후보는
`.worktrees/farm-librarian-floor-inventory-20261116`에서 확인했다.
수신 메시지는 `11adb03d`를 지목했지만 직접 조회한 clean head는
`4778ce6957bcf37963875563e276cb006eaad501`이었다. 해당 source-review와 next-unit
기록을 읽었다. 작성 세션은 floor 전체 metadata를 엄격히 확인한 뒤 선택한 range/position의
본문만 읽도록 수정했고, 필수 index summary와 두 인자의 명시 타입 보강을 보고했다.
13파일의 독립 소스 리뷰 두 건이 보고됐으며, OCaml 12개 구문 검사는 5.5.1이다.
Root가 그 전체 구현을 별도로 승인하거나 실행한 것은 아니다. 타입·회귀·현재 main 통합·
실제 bodyless 복구·설치·게시는 미확인이다. 수신 뒤 보낸 협업 답변과 Schedule3+Document5
게시 위임도 같은 thread 전송 연결 오류로 전달을 확인하지 못했다.

## 두 기존 스택의 재기반과 Schedule 실행

보유 Git 객체를 읽는 임시 local remote를 써서 두 스택 전체를 native rebase했다.
명시한 중간 점검 시점은 처음에 10e51ac였지만, native가 실제로 선택한 base는
`e0e819e29968366c1dffb59ad625ba4e17d4ac22`였고 connector의 main 조회로 이를 확인했다.
원격 main은 계속 바뀔 수 있으므로 게시 전 다시 대조한다. origin 설정은 보존했고
자체 임시 remote만 제거했다. 다른 세션의 refs 변화는 되돌리지 않았다.

Schedule의 두 층은 `236754fcfb72f49ef9c365465dfd1e63cf3e6010`과
`8d4a43c0f7832ef93d64eaaa165293db032efb1d`로 재기반됐으며 기존 두 패치와
9개 파일 바이트가 같다. 문서/MCP 다섯 층의 통합 checkpoint는
`980892260bf73193e8251b0ac1d54bedf6ad76f0`다. 전체 79개 파일 중 73개는 이전과
같고 6개는 main의 변경과 통합됐다. test/dune의 충돌은 양쪽 등록을 보존해 해소했다.
두 스택 모두 바뀐 base와 직접 소비자를 읽은 독립 소스 리뷰에 P0/P1/P2가 없다.
구문 검사와 현재 소스 검토를 전체 타입·동작 검증으로 확대하지 않는다.

Schedule 후속 시험은 고정 `8d4a43c0`의 실제 FileSystem backend와 store/service/runner를
사용했다. 11개 시험과 새 자식 프로세스 재열기 6회에서 원본 부재·손상 시 stale mirror를
변경 권위로 삼지 않고, 복원한 종단 상태를 다시 실행하지 않음을 확인했다.
새 저장소는 계속 초기화할 수 있다. service의 withdrawal callback 검사는 별도 서버
teardown의 queue purge까지 다루지 않는다. 273개 source 입력과 430개 config asset에서
생성한 설정을 사용한 standalone 실행이며, 전체 Dune·기존 전체 suite·Memory backend·
provider·실제 서버·crash-mid-write 검증은 아니다. 실패한 C stub 연결과 부모 waitpid의
EINTR 처리 시도도 보존했다. 후속 시험은 별도 native test 층
`24557f69e8f86f77b0af3fa2651bff8a78c43f01`에 등록하고 독립 소스 리뷰를 마쳤다.

로컬 게시 인계는 Schedule3·Document5의 원본 53개 파일 packet과 별도
`artifacts/farm-publication-handoff-20261116-update.json`을 함께 읽는다.
원본은 `3bdedcea` 기록으로 보존한다. Update note는 후속 문서 및 owner-layer
수정에 따른 스택 전체 refs와 현재 leaf를 명시하며, 게시 시에는 그 최신 연결을 읽는다.
원격 push·PR 생성·GitHub 정식 승인·병합·설치는 수행하지 않았다. `gh pr view`도
여전히 API 연결 실패였고, 상대 세션에 대한 답변 전달도 확인하지 못했다.

## Core 문서 투영의 후속 타입 수리와 실제 실행

문서/MCP 스택의 검토 base `e0e819e29968366c1dffb59ad625ba4e17d4ac22`는 유지했다.
Core `db69904f29c6f4a6166957fbdffa4f7e8e910a7a`, MASC
`01c94838471b1cbff986e5a78f2c14597a8df564`, 원래 증거 층
`5363a4d944f704962f4ea47623d29640cd0f1711`, MCP
`e392aa3a7f8fafdfe18045c92bc0fe1d023e44b5`, 문서 갱신 전 통합 top
`6134e0a42aae676f63143d1473aaeca7fb99053f`가 현재 다섯 층이다.

실제 컴파일에서 document degrader가 generic history를 고정 미디어 타입으로 좁히는
오류를 찾았다. `api_common.ml`/`.mli`가 source 타입을 보존하도록 고쳤다.
실제 시험의 Yojson 3에 없는 두 생성자와 모호한 projection record annotation도
수정했다. assertion과 기존 18개 등록은 유지했다. 소스 수리는 세 파일이며,
`api_common.mli`는 앞선 79개 검토에 없던 추가 경로다. 현재 합집합 80개 경로 전체를
새로 검토했다고 주장하지 않고, 앞선 79개 리뷰와 후속 세 파일의 독립 리뷰를 연결한다.
수리는 Core 첫 층에 넣고 `gh stack rebase --no-trunk`로 위 네 층을 다시 쌓았다.
새 main 통합이나 게시를 수행한 것은 아니다.

실제 Core `test_media_document_admission`의 기존 18개가 전부 통과했다.
소스 118개와 정상 생성 catalog·namespace alias를 사용한 OCaml 5.5.2 실행이다.
초기 실제 컴파일·연결에서 실패한 run-1~5를 보존했다. run-6은 바이트가 같은
입력과 객체 189개를 대조한 뒤 Digestif.c archive 순서를 바로잡아 새로 연결하고
실행했다. 최종 6개 명령이 모두 성공했다. 실행 당시 시험 파일은 아직 커밋 전이었지만,
그 뒤 최종 leaf의 소스 118개와 metadata 9개가 영수증과 모두 일치함을 확인했다.
후속 독립 영수증 리뷰도 이 바이트 연결을 확인했으며 테스트를 다시 실행하지 않았다.

문서 worktree의 `artifacts/farm-core-media-document-20261116/final-summary.json`,
`run-6/`, `restack-3/terminal.json`이 정본이다. source manifest SHA-256은
`715c55b1679ba25023e0e0d42771929a5ebbd3f1643a251a28580fa801f395e7`,
실행 결과는 `67f5d9c7adffc749dd5cecee37dde4c790b590f0d9da37f1a04167f4801e6f3d`다.
이는 로컬 문서 admission·codec·공유 투영의 실행이다. 별도 reasoning 65개,
Keeper planner/token counting, MCP 소비자 suite, 실제 HTTP/provider, PDF/STT,
설치된 MASC와 전체 Dune 실행 증거가 아니다.

## UID 생성과 실제 첫 쓰기의 연결

아래는 재기반 전 커밋과 당시 증거다. 같은 UID/SSH 스택에 네 층을 추가했다. SSH 경로 분리의 동작 증거나
전체 시작 경로의 완료 판정으로 합치지 않는다.

| 커밋 | 변경 | 확인한 증거 |
| --- | --- | --- |
| `0b45cf34b998c26ee20e98bbc6add8df6f9ca04a` | 공용 admission이 실제 Host 설정 해소와 바깥 BasePath 준비, UID 생성·확인을 한 native 작업으로 수행한다. 직접 Workspace가 기존 linked root를 열 때에는 UID 확인과 fsync만 한다. | 실제 소스 179개, 컴파일·링크·실행 명령 184개, 집중 시험 7개 통과. `admission-3` manifest `ec42689cb5b9e8d2b0c9288d5c6792b57ce36b92ac3eeab6854bd4a1bfd6de2d` |
| `dda168069b6e0416592005a3ce7b2787c605c16d` | 서버 lifetime lease 이후 strict birth를 수행하고, restart도 stop/log/spawn 전에 strict 준비를 한다. 서버의 linked root 거절은 유지한다. | takeover 시험 55개는 linked-root 확인 helper 추가 전의 저장된 의존성 스냅샷으로 실행했다. 최신 전체 head의 동작 증거가 아니다. restart·UID 문서 inventory는 소스·구문 검토만 했다. |
| `62af6cb40b830fec898923a1713234415d1c440b` | Workspace factory/init, config bootstrap, `workspace-create`, 저장 CLI, prerequisites와 installer의 첫 쓰기를 연결했다. UID 오류를 Memory fallback으로 숨기지 않는다. | 37개 파일 독립 소스 리뷰와 구문 검사 35개. installer Python 경계 시험 6개는 모의 CLI 응답으로 순서·거절을 확인했다. 실제 설치·CLI 실행 증거가 아니다. manifest `bfb73c54017067d8602823a39c916f54b280699beaa9c7a7813a742e4942e946` |
| `6e328cde52221f8443973d6f31198431ca59a682` | Item, Gate, direct resume, Goal confirmation의 HTTP 검증 스크립트가 선택한 후보로 workspace-create한 뒤 fixture를 쓴다. | 네 파일 독립 소스 리뷰와 Python 구문 검사. 두 스크립트의 통제된 후보 거절 시 runtime·서버 로그가 생기지 않음을 확인했다. native UID·서버·provider는 실행하지 않았다. manifest `4b709aaba3061b336b67ed9c8f20654a443bfc3569b885c2017b88a6c1d2163e` |

이 네 층의 해당 소스 범위에는 독립 리뷰의 추가 P0/P1/P2가 없다. 이후 아래 층도
커밋했다. 각 행의 검증 범위를 전체 스택이나 실제 설치 결과로 넓히지 않는다.

| 커밋 | 변경 | 확인한 증거와 한계 |
| --- | --- | --- |
| `30bff2a69566b6fa0b391c930691e5f6d7ea5bad` | 공용 harness와 직접 소비자가 같은 후보의 admission 뒤에 설정·fixture를 쓴다. Fusion의 기존 링크 루트·admission 거절은 소유 서버 중단보다 먼저다. | 14개 파일 독립 소스 리뷰. 선언한 의존 파일만 복사한 환경에서 Python 경계 시험 9개 통과. 후보 CLI와 서버 실행 경계는 모의이며 native UID·서버·성능 시험은 아니다. |
| `9b4a717d8b19032bc6ddd81d0a50afa9550ba695` | 컨테이너의 volume을 BasePath로 두고 native lease/birth 이후 callback에서 event 디렉터리·설정을 준비한다. 기존 volume 이름을 유지하며 호환되지 않는 배치를 거절한다. 명시 START는 최종 서버 exec에서 복원한다. | 13개 파일 독립 소스 리뷰, mock-native shell 시험 16개 통과. 별도 작은 OCaml 5.5.1 프로그램으로 START와 없는 event 디렉터리의 기동 중단을 재현했다. 실제 image·Docker copy-up·Linux·설치·volume 변경은 하지 않았다. |
| `3aa1ea7bbaccb581cdcb10e89f53a283076073a1` | high-level login과 선택된 TUI Mint/Remint의 lock 전에 UID를 준비한다. 순수 역할·유효기간 검사와 typed admission 오류를 공유한다. 조회·Admin 재사용·raw auth API는 등록하지 않는다. | 14개 파일 독립 소스 리뷰, 구문 검사 13개, 실제 인터페이스에 대한 제한된 타입 검사 38개 명령 통과. 실행 파일 연결·PPX·실제 인증·전체 TUI/server graph는 미검증이다. |
| `d23bf59c5679f674aeef81e75f1ee743f46818f1` | TUI가 유효한 기존 UID의 로그 경로 또는 비공개 host session을 선택한다. 로그 때문에 `.masc`를 만들지 않는다. 시작 출력의 실제 경로를 표시하고 재시작 스크립트가 관측한 stderr의 새 행만 읽는다. | 21개 파일 독립 소스 리뷰. 실제 root/lifecycle 소스의 시험 24개, 제어된 lsof 응답과 실제 임시 파일을 쓴 helper 시험 15개, 실제 lsof와 시험 소유 sleep의 shell self-test를 확인했다. 전체 TUI·observation·Ask·metrics·Linux E2E는 미실행이다. |
| `19943ea90dd092759cda3c906a5db7f58b3c9516` | 없는 credential store의 revoke/retire는 디렉터리나 UID를 만들지 않는다. credential 저장소 잠금을 먼저 잡은 login과 revoke는 기존 transaction 순서를 유지한다. | 7개 파일 독립 소스 리뷰, 구문 검사와 제한된 실제 인터페이스 타입 검사 41개 명령 통과. 실제 auth 실행·전체 graph는 미검증이다. |
| `383101ff149d580d6654cfec8e9d7001a1f986bc` | presentation 도구는 workspace 밖에서 준비하고, native fixture가 UID를 만든 뒤 환경 링크를 놓는다. parser가 없는 경우의 시험은 공유 venv 대신 자기 링크만 옮긴다. | 3개 파일 독립 소스 리뷰, OCaml/Python 구문과 모의 subprocess 준비 경계를 확인했다. venv 설치·native parser·render 실행은 하지 않았다. 역사적 pinned probe는 바꾸지 않았다. |
| `4cc28146db818607173fa1960ab4f1bf6b842223` | raw CLI 입력을 공용 typed admission에서 해소한다. 마지막 canonical 경로의 기존 UID를 다시 확인하고 처음 UID와 대조한다. source start·quickstart·seed-team이 같은 후보의 반환 경로로 설정을 쓴다. | 20개 파일 독립 소스 리뷰. 실제 admission 시험 23개 통과. 바뀌지 않은 shell/test 범위의 모의 source 16개·container 17개와 기존 PTY fixture 결과를 상속했다. 전체 HTTP/stdio CLI 타입·실행은 미검증이다. |
| `57bb507c8a33fd2c40b73996d1f99131b60b4732` | carts와 workspace 기본 경로를 쓰는 monitor가 native 반환 경로를 사용한다. 조회·dry-run·명시적 host 경로의 의미를 보존한다. | Dune 등록을 포함한 5개 파일 독립 소스 리뷰, 통제된 경계 시험 10개. 실제 native CLI·download·monitor 실행은 아니다. |
| `501ea3e79536087ca479b74733a3c0bd91bfd1e7` | run-local의 config·환경·argv를 반환 BasePath로 맞춘다. 서버의 linked root 거절은 bootstrap보다 먼저이며 START는 최종 실행에서만 복원한다. | 2개 파일 독립 소스 리뷰, 실제 shell·env 실행을 거친 선택 시험 6개 통과·26개 skip. build·native candidate·lsof는 fixture이며 실제 서버·Dune 실행은 아니다. |
| `4243495f03683c644dc264875dd179d1b910cb8b` | 공통 root resolver가 관측한 HOME을 cwd보다 먼저 확장한다. 추론으로 고른 위치를 보존하고, 재사용할 때 다른 root가 되는 경로는 typed 오류로 거절한다. doctor·port·deployment도 이를 없음으로 숨기지 않는다. | 5개 파일 독립 소스 리뷰. 실제 resolver/guard suite 20개·11개 명령 통과. 두 bin은 소스·구문만 확인했다. compiler PATH는 runner에서 고정했고 후속 도구 환경 조회는 원래 실행 환경 스냅샷과 구분했다. |
| `556cf0052a7e57d55cd36e3e80a7a9c6f8f5ab50` | installer의 ready·needs_attention·수동 journey가 native preflight의 경로를 이어 쓴다. guest shim도 기존 admission 반환 뒤에 쓸 위치를 정한다. | 4개 파일 독립 소스 리뷰. Python adapter/env/journey 16개·Wizard 22개 통과. native/config/download는 명시적 fixture다. 실제 설치·CLI·서버 실행은 미검증이며 START 소유 경계는 별도로 남는다. |
| `01d798ef7ec35c1e83bb9e31b53a72cad59f7fbb` | SSH 경로·로그 helper의 기존 정본을 직접 호출해 상위 의존성을 줄인다. 실제 UID와 Keeper 생성 ID를 실제 runner의 요청 frame까지 연결해 시험한다. | Dune 등록을 포함한 5개 파일 독립 소스 리뷰. 실제 local-wire 4개·경로 변환 8개·protocol 41개, 총 53개 통과. SSH 역할은 local self-exec peer다. 실제 OpenSSH 인증·원격 jail·VM 격리·기존 전체 SSH dispatch/factory suite는 미검증이다. |

TUI의 실제 실행 영수증은 `artifacts/farm-tui-logging-20261116/run-3/`다. 컴파일러의
`-version`과 `-where`가 모두 5.5.2임을 확인하고 새 소스 10개를 컴파일·연결해 두 suite를 실행했다.
이전 run-1은 테스트의 비공개 상수 참조, run-2는 harness의 compiler PATH 불일치로 실패했다.
두 실패 영수증을 보존했으며 구문 검사나 `ocamlfind` 파일명만으로 실행 성공을 판단하지 않았다.
재사용한 admission 기반 소스 179개의 해시도 대조했다. 전체 Dune 의존 그래프 검사는 아니다.

source 입력의 마지막 경로 재확인은 원래 UID에 다른 디렉터리의 경로를 짝지어 반환하던
경우를 막는다. UID가 없는 대체 경로나 다른 UID는 거절하며 같은 UID alias와 기존 linked
runtime 정책은 보존한다. 반환값은 계속 잡고 있는 파일시스템 capability가 아니므로
반환 뒤의 모든 경로 교체까지 막는다는 뜻은 아니다.

SSH 로컬 시험 영수증은 `artifacts/farm-ssh-local-wire-20261116/wire-4/`다. 실제 소스
265개 중 이전 기반 179개와 재사용 객체 287개를 해시로 대조했다. 추가 41개 모듈과 C,
실제 세 suite를 컴파일·연결·실행한 103개 명령이 성공했다. 컴파일 전에 환경과
5.5.2 version/stdlib를 기록했다. standalone build metadata는 version=None과 실제 설치
package 조회 결과를 사용했으며 product Build_version 구현을 대체하지 않았다.
의존 package·metadata 연결 순서 때문에 실패한 wire-1~3도 보존했다.

이 checkpoint 뒤 installer preparation과 dashboard harness의 첫 쓰기·정리 경계를
아래 두 층에서 고쳤다. 실제 lifecycle 부모의 START 전달 계약과 다른 harness 경로는
별도 남은 범위다. 전체 CLI·설치·runtime과 원래 Farm 행렬은 실행하지 않았다.
읽기나 실패한 revoke를 계기로 UID를 자동 발급하거나, 기존 UID 없는 루트를 뒤늦게
등록하는 방식으로 해결하지 않는다. raw credential 저장소와 명시적 host 도구 경로도
자동으로 Workspace로 바꾸지 않는다.

로컬 증거는 UID/SSH worktree의 `artifacts/farm-workspace-bootstrap-20261116/`와
`artifacts/farm-workspace-first-writers-20261116/`에 있다. 전체 Dune 그래프, Linux,
설치된 바이너리, 실제 SSH, 원래 멈춘 요청 회복과 Farm 규모 행렬은 미검증이다.
`U02:IA-S13`의 기존 volume 전환·삭제 승인 상태도 바뀌지 않았다.

## UID 21층 재기반과 후속 두 층

UID 스택은 base `b584e03211e6bb60e63a566853e855dd49544b3b` 위로 21층 전체를
재기반해 `a093d15aeedf790fa7d14d8169a84aa5fcdeb367`에 도달했다. 독립 소스 리뷰는
215개 경로의 해시, 전체 range-diff와 통합 차이를 읽었고 미해결 P0/P1/P2를 찾지 않았다.
196개 이전 leaf 바이트는 같다. 이전 실행 영수증을 바뀐 의존성의 실행으로 승격하지 않았다.
기록은 UID worktree의 `artifacts/farm-uid-rebase-20261116/execution-1/`와
`root-review-1/review.json`이다.

당시 후속 두 층은 아래와 같고, 그 checkpoint의 top은 23층 `2719eb32`였다.

| 커밋 | 변경 | 확인한 증거와 한계 |
| --- | --- | --- |
| `069831239eea50ba21aaa89bcff99533b30b19bb` | Dashboard smoke가 native 반환 BasePath로 fixture·기본 로그·argv를 맞춘다. 정리는 자신이 만든 임시 디렉터리에만 한정하며 supplied root와 KEEP_SERVER의 fixture를 보존한다. linked runtime은 쓰기 전에 거절한다. | 두 파일 독립 소스 리뷰. 실제 shell/env와 명시적 candidate/node/curl/nohup fixture를 쓴 16개 시험 통과. 실제 UID·daemon 분리·Dashboard·서버 동작 증거는 아니다. |
| `2719eb32a7d77941cc4a2216d3e4912f89ff81c1` | Installer 준비 명령과 bundle의 native build-commit probe에서 START를 제거한다. 명시 workspace 환경, raw/canonical 경로, 혼합 native/external login 역할을 보존한다. parent·실제 lifecycle·외부 CLI 환경은 유지한다. | 네 파일 독립 소스 리뷰, 소스/의존성 22개 해시 대조. 통제된 Python/shell 113개 통과·native 필요 1개 skip. 실제 bundle probe 함수는 recording candidate로만 실행했다. 실제 설치·로그인·runtime·network는 미실행이다. |

새 base의 실제 실행은 `069831`을 고정해 소스 263개를 모두 새로 컴파일하고
네 실행 파일을 연결했다. 이전 repository CMI/CMX/O는 상속하지 않았다. OCaml 5.5.2의
명령 287개가 성공했고 UID admission 23개, local SSH wire 4개, remote path 8개,
SSH protocol 41개로 총 76개가 통과했다. 실행 전에 원래 PATH가 고른 5.5.1의 version
관측을 남긴 뒤, 실제 compile 환경과 stdlib를 5.5.2로 고정했다.
263개 입력은 이후 `2719eb32`에서도 바이트가 같지만, 현재 전체 head를 다시 실행한
것은 아니다. Backend/default_config 연결, Running Systhread host, orphan sweep와
creator 경합을 새로 실행하지 않았다. 실제 SSH 인증·원격 jail·VM·Linux·서버·전체
Dune·설치 증거로 확대하지 않는다.

정본은 UID worktree의 `artifacts/farm-uid-fresh-validation-20261116/fresh-1/`다.
source manifest는 `d2dfeb4288e1d245391de0cb9b5d99f2bd61940e043ac108946efb98118815f6`,
results는 `6568b6d5f09972e564d3ffb5f620f0c85eff32d1ec14de09fecc429311763a08`이다.
독립 영수증 리뷰도 263개 소스를 실행한 `069831`과 후속 `2719eb32` 양쪽에 대조했다.
`artifacts/farm-uid-fresh-validation-20261116/independent-review-continuity-1/review.json`
SHA-256은 `81b85a9ed213b1b64dac5afa4fc890c2e6c7d33c8c5be3282b4fbc495b7fed3d`다.
이는 영수증 범위의 검토이며 별도 installer 변경의 실행이나 GitHub 정식 승인이 아니다.
후속 shell 검사는 `artifacts/farm-harness-coordinates-20261116/draft-1/`와
`artifacts/farm-installer-preparation-env-20261116/run-3/`에 따로 있다.
원래 멈춘 요청 회복, 기존 UID 없는 세계와 old volume 전환·삭제, `U02:IA-S13`은
미완료다. 후속 `gh api user`도 해당 실행 환경에서 API 연결 실패(exit 1)였으며,
사용자 계정 무효 판정이나 게시 성공을 뜻하지 않는다.

## 공용 하네스 환경과 UID 생성 경쟁의 후속 확인

UID 스택의 24층 head는 `1de468bc16d2566470f63ac5676cee6454391c6a`다.
공용 shell 하네스의 `workspace-create`와 `login` 준비 자식에서만
`OCAML_RUNTIME_EVENTS_START`를 제거했다. 실제 서버 실행에는 원래 값이 전달된다.
수정 전 경계 시험 3개에서 5개 assertion 실패를 재현했고, 수정 후 유지 중인 suite
18개가 통과했다. 미설정·빈 값·일반 값과 부모 환경 보존을 확인했다.
실제 shell과 기록용 후보를 사용한 환경·인자 검증이며 native login, C runtime 시작,
서버 daemon이나 설치 검증은 아니다. 영수증은 UID worktree의
`artifacts/farm-harness-preparation-env-20261116/`에 있다.

그 독립 소스 리뷰에서 scheduler의 별도 준비 호출과 request-cost의 승인 전 telemetry
쓰기가 남아 있음을 찾았다. 후속 25층 `8951cb0676e7bc9a6336344f4c057fcad88f2f35`는
두 성능 하네스가 공용 admission을 거친 뒤 fixture를 쓰도록 바꿨다. 수정 전 새 사례
4개가 실패했고 수정 후 기존 18개를 포함한 전체 22개가 통과했다. 실제 작은 telemetry
fixture와 설정 덮어쓰기를 확인한 뒤 기록용 후보의 두 번째 confirmation에서 멈췄다.
실제 서버·성능 측정은 하지 않았다. root가 4개 파일의 전체 diff와 직접 소비자,
선언 입력 19개·실행 영수증을 검토했고 미해결 P0/P1/P2는 없다. 두 층 모두 로컬
커밋이며 GitHub 정식 승인이나 게시를 뜻하지 않는다. 후속 증거는 같은 worktree의
`artifacts/farm-harness-seed-order-20261116/`에 있다.

별도로 같은 worktree의 `artifacts/farm-uid-consumer-20261116/run-2/`에서
고정 `2719eb32a7d77941cc4a2216d3e4912f89ff81c1`의 UID 생성 suite 15개가 모두
통과했다. C 구현 8개를 포함한 실제 소스 173개의 의존성을 OCaml 5.5.2로 새로
컴파일했고 이전 객체는 사용하지 않았다. 컴파일·링크·실행 등 187개 명령이 성공했다.
root는 173개 소스의 Git·실행 사본·24층 head 바이트와 산출물 282개의 해시를
별도로 대조했다. 24층에서 재실행했다는 뜻은 아니다.
같은 프로세스의 경로 별칭, 여러 프로세스의 동시 생성과 오래된 잠금 소유권을
다뤘으며 skip은 없다. `_exit` 지점의 재열기는 SIGKILL이나 쓰기 도중 crash 증거가
아니다. Backend/Workspace 소비자, Running host, 고아 파일 정리, 실제 SSH·서버·Linux와
fleet 행렬은 이 15개에 포함되지 않는다.

## Lifecycle START의 지연 적용 후보와 실제 구성요소 검증

UID worktree의 `fix/farm-lifecycle-events-ingress-20261116`은 parent
`8951cb0676e7bc9a6336344f4c057fcad88f2f35` 위에 17개 파일을 바꾼
`62fc143233fb88b22ee5ddc9a733ee07e63ac3e9`로 커밋됐다.
별도 C main이 기존 START의 미설정·빈 값·원래 문자열을 보관하고 OCaml 초기화 전에
환경에서 제거한다. 선택한 lifecycle 자식에게만 원래 값을 전달하며 새 환경변수나
부모 프로세스의 서버 lease는 만들지 않는다. 최종 서버는 자기 lease·UID 확보 뒤
명시 기록을 시작하고, START의 기존 우선순위와 DIR 의미를 유지한다.

초기 계획은 TUI 부모가 계속 기록하지 않아야 한다고 잘못 정했다. 독립 검토에서
기존 TUI GC 관측 사례를 확인해 수정했다. 준비 단계에는 ring이 없지만, 오래 실행되는
TUI는 자체 로그 준비·stderr 전환 뒤 명시 요청만 기록한다. 부모 START 환경은 복원하지
않고 서버 자식에게는 보관한 원래 값을 전달한다. 이 정정은
`artifacts/farm-lifecycle-events-20261116/plan-2/TUI-observation-supersession.md`에
남겼고 초기 계획과 후보도 보존했다. 또 독립 검토에서 CLI runner의 공개 `.mli` export
누락을 찾아 보완했다. 아래 13개 시험에는 이 CLI 소비자가 포함되지 않는다.
별도 작은 직접 호출자로 이전 인터페이스의 거절과 새 인터페이스의 타입 검사 통과를
확인했지만, CLI 구현 전체를 연결·실행한 것은 아니다.

같은 worktree의 `artifacts/farm-lifecycle-events-20261116/validation-1/`에서
표준 OCaml 5.5.2 C main의 기준선 3개는 빈 값·일반 START가 `MASC_RUNTIME_EVENTS=0`에도
ML 진입 전에 ring을 만든다는 사실을 확인했다. 실제 제품 C archive와 원본 모듈을
연결한 최종 `maintained-4`에서는 기존 suite 13개가 모두 통과했고 skip은 없다.
원본 입력은 187개다. 처음 11개 통과·2개 실패는 시험 TMPDIR가 HOME 아래여서 실제
격리 guard가 기본 디렉터리 생성을 거절한 결과였다. 이를 숨기지 않고 별도 private
HOME/TMPDIR로 바로잡은 실행을 남겼다. 이후 인터페이스 주석 정정도 CMI가 달라져,
core·ingress·시험을 다시 컴파일하고 동일한 C archive로 재연결·재실행했다.
초기 구성은 앞선 실제 UID producer 객체 278개를 소스·toolchain·package 대조 후
재사용했다. 이 결과를 187개 전체의 신규 컴파일이라고 부르지 않는다.
그 `maintained-3`의 10개 명령은 모두 성공했다. 마지막으로 상속된 BasePath·Config와
시험 guard override를 제거하고 private HOME/TMPDIR에서 같은 바이너리를 다시 실행했다.
최종 `maintained-4`의 3개 명령도 성공했고 소스·303개 컴파일 산출물은 그대로다.
앞선 실행의 ambient BasePath 상속은 별도 한계로 남겼으며 과거 영수증을 바꾸지 않았다.
Darwin arm64에서 서버 lease 거절, 기본 디렉터리의 동일 PID exec, 명시 START의 정확한
전달·우선순위와 workspace 소유권 이후 기록을 이 구성요소 범위에서 확인했다.

`maintained-3/source-manifest.json` SHA-256은
`ea5b198d1ede914ac0e61e914cabf7d28ca0b55a1aabfd75e1cf206cbf0c0555`,
`maintained-4/results.json`은
`3fb8f0f3f623438f4dab7b687c1be4c3627929cc06eba9fa6ee910df67a344de`다.
최종 선택은 `validation-1/final-2/README.md`와 `summary.json`에 적었고 봉인 영수증은
`9d127a5d2f03c455db2fbb3184cb06d18ba9f9962c0ce6f6d7c4e7eecab08bbf`다.
이 기록은 이전 `bc46956f…` 봉인을 보존하고 최종 실행 선택만 갱신한다.
후속 `artifacts/farm-lifecycle-events-20261116/committed-binding.json`에서 root가
17개 변경 파일·실행 소스 187개가 커밋과 같고 산출물 303개가 영수증 해시와 같음을 대조했다.
두 독립 리뷰는 17개 파일의 소스 범위이며, 커밋 뒤 시험을 다시 실행한 것은 아니다.
별도 `ingress-3`의 8개 probe와 14개 명령도 통과했다. 준비 시점 3개, 명시적 장기 실행
역할의 기록 시작 2개, 실제 Python→native 전달 3개이며 결과 SHA-256은
`6deb5d77ef94cee89a91ae9d589fc3dbf438a35ce88737174a4c5ddd341af1a7`다.
이 probe는 실제 getter·runtime을 사용하지만 TUI main/log-root 전체, onboarding·`sg`,
전체 CLI 타입·Dune 그래프·설치·Linux 실행을 검증한 것은 아니다. raw bytecode와
Windows도 이 native POSIX 후보의 검증 범위 밖이다.

## MCP decoder·projection의 실제 실행

문서 worktree의 고정 `ad6ba29aec18597a474bdaa717517ca5b3c1261c`에서 기존
`test_keeper_mcp_content` 8개가 모두 통과했고 skip은 없다. 최종 run-4의 16개 명령이
OCaml 5.5.2로 성공했다. 원본 소스는 ML 89개·인터페이스 144개·C 6개로 총 239개다.
이 중 Core 입력은 90개지만 실제 실행에 연결한 Core 구현은 16개이며, 전체 Core나
처음 추정한 635개 파일을 빌드한 것이 아니다.

실제 SDK decoder를 통해 혼합 text/media/structured 순서, audience 제외, 잘못된
annotation·중복 필드, resource 링크·binary와 원문을 노출하지 않는 오류를 확인했다.
`Agent_core`와 `Mcp_client`의 필요한 공개 인터페이스는 원본 그대로 컴파일했고,
값이 필요한 모듈은 전체 원본 구현을 연결했다. 이름이 같은 Core/Base/MASC 모듈은
실제 namespace로 분리했다. 내부 함수를 추출하거나 가짜 구현으로 대체하지 않았다.

앞선 세 컴파일 실패는 standalone 실행기의 interface·alias 의존성 예약 누락이었으며
원문을 보존했다. 제품 수정은 없었다. 같은 작업의 성공한 객체를 해시 대조 후 재사용하고
최종 테스트를 정상 empty interface·경고 정책으로 다시 컴파일·연결했다. 이전 Core18이나
repository `_build` 객체를 상속하지 않았고, run-3/run-4 반복을 16개 사례로 세지 않는다.
최종 산출물 377개의 실행 전후 해시와 imported CMI 318개 연결을 확인했다. 설치 package
내용 해시는 실행 뒤 수집한 기록이며, 이를 실행 전 snapshot이라고 하지 않는다.

정본은 이 worktree의 `artifacts/farm-masc-consumer-20261116/next-unit-2/`다.
봉인 영수증 SHA-256은 `bbe257ca010dec201ae8eba6192b61c4d331af1f070e4603debd74782d2f3ff3`,
run-4 결과는 `88d020f9836a7e65a903f539fd0132c6c45749487d2837e02a368f18846266dc`다.
이번 문서 갱신에서 영수증 34개 파일과 현재 소스 239개 해시를 대조했으며 재실행하지 않았다.
이 8개는 일반 MCP 호출, 승인 replay·pending repair, 실제 artifact 저장·소유권·GC,
H5, official client/provider, full TUI·설치·Linux·전체 Dune 검증이 아니다.

## UID 26층의 고정 local main 통합

26층 전체를 `gh stack rebase --remote <owned-local-source>`로 재정렬했다.
고정한 base는 local main `d2fa5aadd2f4f64ec0ee1574decb769085b4f3cf`,
결과 leaf는 `7e3227db41ee1b14016621a26eb4e921872851ca`다. Native 명령은
exit 0으로 끝났고 충돌이나 수동 소스 수정은 없었다. 26개 층은 각각 한 커밋이며
직전 층을 parent로 가진다. Range-diff의 26개 패치는 모두 동일하다.

Root는 기존 224개 경로 중 220개 blob이 같고, 네 교집합은 TUI 두 파일과
bin/test Dune임을 직접 확인했다. 고정 main의 나머지 821개 변경 경로도 target과 같다.
새 typed refusal과 UID-first mint, workspace 밖 초기 로그, 선택 child의 START 전달,
명시적 TUI 기록 시작 및 native archive 등록을 소스에서 함께 확인했다.
독립 검토도 같은 고정 head에서 네 통합 경계와 세 의존성 변경을 읽고 추가
P0/P1/P2를 찾지 못했다. 이전 26개 구현 전체를 새로 승인한 것은 아니다.
검토 기록은 `artifacts/farm-uid-rebase-20261116/independent-review-surface-2/`이며,
Root와 검토자가 종단 packet의 48개 파일 해시를 각각 대조했다.

이전 UID76·birth15·lifecycle13 실행의 실제 의존성에서는 `Eio_guard.ml` 주석과
metric store의 `.ml/.mli`가 달라진다. 후자는 `snapshot_named` 공개 API 추가다.
따라서 기존 PASS를 새 head에서의 실행으로 이월하지 않는다. 이번 통합은 전체 타입,
CLI/TUI 실행, 재설치나 운영 복구를 증명하지 않는다.

작업 중 main과 origin/main이 `4d15b1b1b5761afdf82683f3cdef950921798aa1`로
전진했다. 이는 terminal 시점의 로컬 ref 관측이며 변경 주체는 확인하지 않았다.
이 통합의 base는 계속 `d2fa`다. Main/origin을 포함한 범위 밖 30개 ref 변화를
되돌리지 않았고, 다른 native stack metadata와
origin 설정은 보존했다. 자체 임시 remote만 제거했다. 복구 bundle과 전체 영수증은
UID worktree의 `artifacts/farm-uid-rebase-20261116/execution-2/`에 있다.
원격 게시·병합·설치·runtime 변경·기존 UID-less 데이터 이관은 수행하지 않았다.

## MASC 문서 입력 테스트 수리와 소비 경로 검토

문서 스택의 MASC 층 `01c948`에서 유지 중인 선언→wire 테스트가 현재
`Yojson.Safe.t`에 없는 `Tuple`·`Variant`를 검사하고 있었다. 실제 설치된 인터페이스와
source/blame으로 확인한 뒤 그 두 패턴만 제거했다. 소유 층은 `be648b8e`, 전체 5층을
`gh stack rebase --no-trunk`로 다시 정렬한 leaf는 `d18a8aa8`이다. Base는 유지했고,
이전 `d1ede6aa` 대비 전체 트리 차이는 테스트 한 줄뿐이다. 나머지 16개 커밋의 패치는 같다.

독립 리뷰가 해당 P1의 소스 수정을 확인했다. OCaml 5.5.2 전체 파일 구문 검사와
`git diff --check`는 통과했지만 이 MASC suite의 전체 타입·실행 검증은 아직 없다.
앞서 실행한 Core 118개·MCP 239개 소스 입력은 새 leaf의 Git 및 worktree 바이트와
모두 일치한다. 이 대조는 재실행이 아니다.
[문서 입력 증거](../evidence/2026-11-16-farm-document-input/README.md)에 상세 범위를 남겼다.

고정 head의 별도 source audit는 TOML materialization, H5, canonical checkpoint,
native continuation의 실제 호출을 따라갔다. 추가 P0/P1/P2를 찾지 못했으나,
late/carried·active tool round는 여전히 initial H5 밖이다. 문서 입력 suite의 다른
테스트도 실제 runtime 생성·resume·dashboard·HTTP 구현을 요구하므로 선언 테스트만
발췌해 전체 suite 실행으로 보고하지 않는다.

MCP 일반 호출의 identity-tools suite 40개는 아래 후속 경계에서 멈췄으며 실행은
0건이다. Source trace에서는 invocation의 보존 참조를
호출 로그 commit 뒤에 비우고, 현재 서버 blob sweep은 삭제 없이 관측함을 확인했다.
Blob 게시와 로그 commit 사이의 크래시·복구·offline 유지보수 상호작용은 미실행이다.
소스 검토만으로 GC 안전성이나 원래 요청의 회복을 완료 처리하지 않는다.

## Identity 이름 참조 수리와 새 base의 lifecycle 실행

문서/MCP 스택에 여섯째 층을 추가했다. 소스 후보
`77ef965413357353084b6bd2d0833ddd8e5f41e3`의 두 파일·세 참조만 바꿨다.
정책은 검색 도구 구현 대신 검증된 공개 schema의 이름을 읽고, GitHub credential
코드는 전체 Keeper 설정 대신 기존 `Keeper_config_text.validate_name`을 직접 쓴다.
이름 문법·오류·두 entrypoint의 디스크 접근 전 검사와 Runtime 기본값/등록 권위는
바꾸지 않았다. 독립 검토는 추가 P0/P1/P2를 찾지 못했다.

두 실제 제품 구현과 원본 40-case 시험 모듈은 컴파일됐다. Public CMI 두 개는 같고,
실제 native imports에서 policy→Search 및 GitHub identity→Keeper_config 직접 경로가
사라졌다. 최종 링크와 시험 실행은 없다. 앞선 runner는 별도로 만든 empty test
interface를 실제 ML compile에 적용하지 못했음을 확인했다. 원본 test를 정상
`-intf-suffix .ml` metadata로 다시 컴파일해 empty CMI를 유지했으며, 이전 inferred
CMI를 정상 Dune interface 증거로 쓰지 않는다. 이 수리로 전체 의존 경로가 사라진 것은
아니다. 실제 SSE의 정상 생성 모듈 `Sse_event_t` 준비 경계와 별도 lifecycle/Runtime
경로가 남는다. 제품 컴파일 결함으로 판정하지 않았고 원래 40개 시험은 줄이지 않았다.
[범위와 영수증](../evidence/2026-11-16-farm-mcp-content/README.md)에 이를 구분했다.

별도로 UID `7e3227`의 원본 lifecycle 13개를 실제로 다시 실행했다. 같은 187개 입력을
전부 새로 컴파일했고 repository object 재사용은 0이다. Named ingress C archive를
연결해 204개 명령이 exit 0, 13 PASS·0 skip이었다. Root와 독립 검토자가 Git/copy
입력 187개, 출력 303개와 기록된 package 파일 2,119개의 바이트 결속을 확인했다.
확장자 없는 선택 PPX 실행 파일의 사전 해시는 빠져 있어 모든 toolchain 입력을
결속했다고 주장하지 않는다. Test-only warning4 설정은 실제 Dune test 정책과 같다.
이 범위는 전체 Dune·CLI/TUI·설치·provider·Linux나 다른 76/15/8/3 시험의 재실행이 아니다.
UID worktree의 `artifacts/farm-lifecycle-events-rebase-20261116/`에 실행과 독립 검토를
보존했다. 원본 seal은 `37aafc898bf2127fa3d568b655d998714fc62afcd7f2a692da1e7e743bb640e1`이다.

이 시점의 H5 후속은 설계 조사였다. Canonical carried 범위 결정 뒤, wire 변환·서명 검사 전에
요청용 읽기 투영을 넣을 위치를 확인했다. 늦은 Text JSON outbox와 Responses tool-result
PDF의 위치별 wire 표현, official 내부 rounds는 별도 미완료로 남겼다. 이 조사로 H5
기능을 구현하거나 실제 PDF/provider 동작을 검증한 것은 아니다.

## 선택한 요청 이력의 H5 읽기 연결

여섯째 층의 최종 `4115b16183f39744d47766caed8feeca0493fb1c` 위에
`fix/farm-request-media-reading-20261116`을 `gh stack add`로 만들었다.
Keeper-history 요청의 carried 범위를 선택하고 materialize한 다음, 기존 walk 소유
projector로 문서·오디오를 읽도록 연결했다. 새 ToolResult에 들어온 구조화된 첨부도
다음 요청에서 이 경계를 거친다. 초기 입력 투영과 같은 runtime snapshot·캐시·deadline을
쓰며, 매 요청의 전체 선택 범위에서 혼합 입력 가능 여부를 다시 판단한다.

원본 `carried`는 atom 수·위치·digest의 근거로 남긴다. 요청용 `projected_carried`를
wire 변환과 dialect·서명 prefix 검사에 함께 넘긴다. Backend가 거절해야 하는 경우도
같은 투영을 전달하며, Stored 변환 오류만 Media 오류로 바꾸고 callback의 typed 오류는
보존한다. CPU 크기 추정·demotion 후보 비교에서는 외부 reader를 호출하지 않는다.
이미지에는 기존 Store_only 정책을 쓴다.

유지 시험 여섯 개를 추가했다. 다섯 failover 사례는 선택된 원본과 새 nested 첨부,
다른 CPU domain과 구분되는 reader 실행 위치, 같은 walk의 캐시와 runtime reload,
typed 오류·없는 bytes·잘못된 reasoning 출처를 다룬다. 나머지 한 사례는 기존
Anthropic producer/serializer로 읽기와 signature의 prefix 결속을 검사한다.
다른 읽기가 만들어지면 실제 기존 정책대로 signed block이 제외되는지도 확인하도록
작성했다. 외부 PDF/STT·provider 응답을 대신한 fixture이며 **실행은 0건**이다.
Root의 OCaml 5.5.2 전체 파일 구문 검사 9개는 통과했다. 이 검사를 타입·동작 성공으로
부르지 않는다. 원본과 결과는 `artifacts/farm-document-request-reading-20261116/`에 있다.

후속으로 소스 후보 `8811012d471b9ca6d88ed5e6e2aea7dd75099c17`의 두 제품 구현
전체와 두 공개 인터페이스 타입 검사도 성공했다. 실제 원본 인터페이스와 namespace를
사용했고, 기존에 컴파일한 의존성은 소스·출력 해시를 대조해 재사용했다. 독립 소스
검토도 같은 11개 파일의 Git 바이트와 결속됐다. 검사 실행기에 빠진 패키지·모듈 별칭을
보완한 이전 실패는 보존했으며 제품 오류로 판정하지 않았다. 이 결과는 유지 중인
시험의 타입·링크·실행이나 전체 MASC 빌드, 런타임 초기화 검증이 아니다.

이 소스 변경은 원본 효과의 재실행이나 canonical checkpoint의 첨부 교체가 아니다.
늦은 caller projection, Text JSON outbox, Completion-review, official-client 내부 round,
Responses ToolResult PDF처럼 위치에 따른 native 표현의 제약은 남는다.
[H5 계약](../KEEPER-MEDIA-FALLBACK-H5.md)에 적용 위치와 이 한계를 구분했다.
실제 reader·provider·설치·재시작 연속성은 아직 검증하지 않았다. 이전 Core18·MCP8·UID13
통과를 이번 요청 경계의 실행 증거로 옮기지 않는다.

Document 스택은 이제 일곱 층이며, 새 층의 검토와 전체 원격 preflight가 끝나기 전에는
게시하지 않도록 로컬 인계 note를 갱신했다. 이전 여섯 층만 게시하는 요청으로 해석하지
않는다. 지정된 협업 thread의 새 조회도 로컬 MCP 전송 연결에서 실패했으며 전달 완료를
주장하지 않는다. 런타임·설치·데이터 변경은 수행하지 않았다.
후속 읽기 전용 진단에서는 이 실행 환경의 GitHub DNS 해석 실패와 기존 MCP 포트의
TCP 연결 거절을 확인했다. 인증 유효성과 호스트 전체 상태는 확인되지 않았다.

## 11월 17일: 수신 확인과 원본 보관 분리

Document7 `2c5a574c793264a963c1a994285fb4b332c4daa7` 위에 여덟째 층
`fix/farm-retained-result-ownership-20261117`을 만들었다. 보관된 결과에 H5 읽기를
붙이기 전, ACK 뒤 원본의 보관 근거를 조사했다. 일반 Add-on의 미디어 결과는 outbox가
유일한 blob 참조일 수 있다. 일반 로그·raw trace는 모든 content_blocks에서 자동으로
참조를 만들지 않는다. 별도 참조를 등록하는 MCP bridge와 구분했다.

기존 묶음 축소 RFC도 ACK 뒤 blob을 GC가 지울 수 있고 vendor의 과거 주소가 실패하는
한계를 기록하고 있었다. 이번 변경은 그중 원본 결과의 수명을 늘린다. ACK는 같은
Keeper의 `consumed-tool-results`에 검증된 원본을 내구 저장한 뒤 대기 파일을 삭제한다.
새 보관 위치는 다음 모델 요청의 pending 목록에 들어가지 않는다. 동일 파일의 존재만으로
내구성을 추정하지 않으며, 실패한 게시와 바뀐 원본은 pending을 삭제할 근거가 아니다.
두 위치의 임의 response JSON이 history media 소유권을 만들지 않도록 동일한 엄격한
receipt 출처 판정을 사용한다.

[원본 보관 계약](../design/retained-result-ownership.md)에 순서·실패·재시도와 비용을
적었다. 소비 결과 파일과 blob이 누적되고 ACK I/O와 오프라인 스캔 비용이 늘어난다.
규모에 따른 비용은 미측정이다. 임시 By_address 묶음 blob과 H5 reading cache의 수명,
실제 보관 결과 읽기 연결은 이 변경으로 완료되지 않는다. 원래 Farm의 25개 요구와
장시간·다중 Keeper/Queue/Proactive 조건은 계속 열려 있다.

새 유지 시험은 원본 보관과 두 번의 GC, 충돌한 보관 파일, 내구 저장을 막는 실제
디렉터리 장애와 재시도, 이미 사라진 pending, 전달 경계의 snapshot, 새 결과 보존,
동시 ACK를 다루는 7개다. 동시 호출의 성공 개수를 가정하지 않고 각 결과를 기록하며,
재시도 전에도 GC 두 번을 거친 원본 보존을 검사하도록 작성했다.

기존 코드의 실행 준비는 `Tool_blob_maintenance → Keeper_semantic_execution →
Agent_core.Agent`의 실제 값 의존성에서 멈췄다. 공개 locator codec이 Agent 구현을
요구하므로 다른 codec으로 대신하지 않았다. 최종 링크·시험 실행은 0건이며 기존
한계를 실행으로 재현했다고 주장하지 않는다. 대신 변경한 제품 구현 3개와 공개
인터페이스 2개, 새 시험 모듈 전체의 타입 검사는 실제 인터페이스로 통과했다.
기존 ToolBlobStore 시험 변경은 구문 검사·소스 리뷰 범위다. 전체 MASC·설치·장애 복구나
GC 동작이 검증된 것은 아니다. 실행 준비와 제한된 타입 검사 기록은
`artifacts/farm-retained-result-ownership-20261117/`에 보존했다.

## 11월 17일: 보관 결과의 문서·오디오 읽기 연결

Document8 `6eee17bae9f09dc05fa9927d9cc6758e6d241e44` 위에 아홉째 층
`feat/farm-retained-media-reading-20261117`을 만들었다. 실제 host receipt의 정규화된
Audio/Document 참조를 읽는 경로를 Core·Codex·Claude·Antigravity·Muse에 연결했다.
carrier 자체가 Text이므로 일반 문서를 직접 받는 모델에도 이 첨부는 읽기가 필요하다.
일반 native 문서 투영은 그대로이며, 완료 심사에는 새 reader를 전달하지 않는다.

공유 H5 projector는 읽은 원문이나 실패 이유를 기억한다. history와 receipt가 각자의
출처를 표현하므로 보관 결과에 history의 설명을 잘못 재사용하지 않는다. 원본 context는
유지하고, receipt 내용 주소와 slot으로 구별한 파생 JSON을 더한다. viewer·생산자 lease
검사가 먼저이며, vendor response나 임의 중첩 JSON은 첨부를 읽을 권한을 만들지 않는다.
읽기나 취소는 ACK를 하지 않고, 취소된 준비 결과는 run carrier에 저장하지 않는다.

Core·Codex·Claude의 기존 주소 축소는 원본과 읽기를 합친 실제 글을 저장한다.
Antigravity·Muse에는 같은 크기 거절·축소 재시도가 없다. 두 경로의 긴 읽기는 요청을
키울 수 있으며, 입력 크기를 보장했다고 주장하지 않는다. 원본 artifact 보관과 H5
disk cache 보관도 다르다. 후자는 artifact 참조만으로 유지되지 않아 정리 뒤 다시
읽을 수 있다. 임시 묶음 주소의 수명, 그림과 일반 비-PDF 해석, 실제 provider·서명
prefix·재시작·대규모 연속 동작은 계속 열린 범위다.

새 유지 시험은 decoder 7개, 공유 읽기 6개, 실제 host/읽기/carrier 연결 5개다.
마지막 묶음은 원문 공유와 정확한 주소 blob, vendor 데이터 경계, 완료 심사 제외,
취소 뒤 재로드, 살아 있는 생산자의 결과 제외를 다룬다. 기존 official-runtime 호출
시험에는 새 인자를 명시했다. 이 목록은 작성한 검증 조건이며 실행 성공 목록이 아니다.
검증 기록은 `artifacts/farm-retained-media-reading-20261117/` 아래에 보존한다.

변경한 제품 구현 9개와 공개 인터페이스 9개는 실제 인터페이스로 타입 검사를 통과했다.
host 결과 시험 모듈 전체 50개와 공유 읽기·정리 시험 모듈 전체 11개도 타입 검사했다.
처음에는 공식 runtime의 인자 순서 불일치와 새 시험의 `Stored` 생성자 표기 오류가
검출됐다. 네 공개 인터페이스의 순서와 시험 표기를 고친 뒤 재검사했으며, 실패 원문과
초기 소스 리뷰가 순서 결함을 놓친 사실도 남겼다.

별도 decoder 시험은 실제로 7개 모두 통과했고 건너뛴 경우는 없다. 필요한 실제
codec·오류 타입 모듈을 연결한 시험으로, PDF 추출·STT·provider 실행은 아니다.
새 공유 읽기 6개와 host 연결 5개는 아직 실행하지 않았다. 나머지 official-runtime
호출 시험의 새 인자 변경은 구문 검사·소스 리뷰 범위다. 전체 MASC 빌드·설치·GC·장시간
연속 동작이 통과한 것으로 확대하지 않는다.

GitHub 연결 도구와 `gh`의 공개 저장소 조회도 확인했다. 후자는 시스템 설정을 바꾸지
않고 프로세스의 DNS·인증서 경로를 지정했다. 조회 시점 remote main은
`f51362a745d9a34680a5a23ed9866acc452730bb`였고 열린 PR 17개에 Farm 브랜치는 없었다.
이 실행 환경의 CLI는 OAuth 토큰을 찾지 못하므로 인증이 필요한 게시까지 된 것은 아니다.
현재 PR 전수 diff·최신 base·native stack 확인과 게시·readback은 별도로 남는다.

## 원래 25개 요구의 현재 위치

아래 조각은 원래 계획 §8의 핵심 연결이다. 전체 연결과 의존·결정은 원래 표를 따른다.
마지막 칸은 다음에 확보할 구체적 증거이며, 그 한 건만으로 요구 전체를 완료하지 않는다.

| 번호·원래 요구 | 원래 축·조각 | 현재 확인한 증거 | 다음 완료 판단에 필요한 증거 |
| --- | --- | --- | --- |
| 1. 영속 Keeper의 시간 맥락·협업·지식 개선과 명료한 동기·비동기·저장·잠금 | CA-S01·S06·S08·S12a~S14, SP-S02·S05~S08, CMG-S03~S07·S14 | Schedule 권위 후보가 재실행 위험 한 경계를 다룬다. 나머지 현재 상태 미확인 | 취소·정산 뒤 stale mirror의 tick/재시작에서 실행 0건, 정상 권위 복원 후 재개. 별도로 canonical 이력·공유 지식 수정·수신/소비 기록 대조 |
| 2. 용어와 문서를 계속 최신으로 유지 | OD-S08·S09·S13·S16·S19, POC-S06·S13, WIM-S16 | WIM 후보가 H5·runtime 문서를 소스와 함께 고쳤다. 전체 용어집·RFC 최신성 미확인 | 실제 소유 코드와 사용 문서의 뜻·경로 대조, 중복 정본 제거와 OD-S19 결과. 문서 수를 성공 지표로 쓰지 않음 |
| 3. Provider를 공통 코어 프로토콜로 연결 | POC-S02~S12, CA-S02~S05, X02·X03 | WIM 후보가 문서 capability와 전송 투영 불일치를 다룬다 | 선언부터 실제 wire까지 같은 문서 판정, provider 전환 후 canonical 입력 보존. 공식 lane의 종료·실패 생성자와 서명도 별도 대조 |
| 4. 이득이 있는 OCaml 기능과 OxCaml 활용 | POC-S02·S03·S14~S16, SP-S06~S08, X01 | Schedule 후보는 primary/recovered와 오류를 합타입으로 분리. OxCaml·성능 이득 미측정 | 동일 입력·컴파일 조건의 전후 측정, 잠금/도메인 소유 계약과 소비자 검증. OxCaml 도입 여부는 그 이득과 유지 비용으로 결정 |
| 5. 공유 RemoteSSH·microVM, Docker 후순위 | IA-S03~S08·S11~S13·S18·S19 | 같은 SSH 대상·remote_root·Keeper 이름이면 다른 BasePath도 작업·GitHub 설정·정리 경로를 공유함을 소스로 확인했다. IA-S13의 정확한 대상이며 실제 SSH·정리는 실행하지 않음 | 서로 다른 workspace의 같은 Keeper 이름을 같은 기기에 붙여 작업·자격·정리 범위가 섞이지 않음. 기존 로컬 SSH stub으로 실제 전송 프레임부터 대조한다. 단절·재접속과 microVM 실행도 별도 실측 |
| 6. 외부 Dashboard의 권한별 기능·노출과 불필요한 기능 정리 | IA-S01·S02·S10a~S10c·S15~S17, CMG-S09 | 이번 실행에서 권한별 브라우저 동작 미확인 | 서로 다른 역할의 동일 요청에 대한 서버 판정·화면 노출 대조와 실제 브라우저 캡처. 제거 대상은 현재 사용 경로와 함께 확인 |
| 7. TUI 중심 사용과 DAW·MIDI·Guitar Tab 같은 음악 작업 도구 | OD-S01~S04·S17·S18·S21, X04 | 현재 음악 작업대 사용 흐름 미확인 | TUI 핵심 작업과 add-on 입구의 실제 사용 기록. 원래 계획이 제외한 음악 add-on 자체도 사용자 요구의 남은 범위로 유지 |
| 8. Pluggable Multi Add-on Lane | TLJ-S05a·S05b·S06·S07·S09, IA-S18 | 이번 실행에서 설치·복수 lane 동작 미확인 | 외부 패키지 선언→해소→실행→결과의 기록, 여러 구독과 재시작. runtime 누락을 임의 Docker로 채우지 않는 판정 |
| 9. Hook·Exact Lane Output으로 판정 확장 | TLJ-S03·S04·S08·S10 | 확장 판정의 실제 소비 경로 미확인 | 고정 원본 입력·판정 결과·소비자 commit 연결, 실패/재시작 사례. 관측 hook이 임의로 턴을 만들거나 막지 않음 |
| 10. System One·System Two를 함께 사용 | TLJ-S11a·S12 | 현재 판단 도구 접근·전환 동작 미확인 | 같은 과제의 빠른 판단과 심화 판단 호출·결과 기록. 기존 문턱 결정과 U30을 임의로 뒤집지 않음 |
| 11. Candle 경제 모델과 Stock 확장 | FE-S11~S16 | 경제 확장 구현·실측 미확인 | 원장·지급·거래 모델의 구체적 결과와 사용자 확인. Stock은 기존 candle 계약 변경 여부를 먼저 기록하며 별도 비Keeper 작업 범위 유지 |
| 12. 토큰·자원 사용량 가시성과 통계에 근거한 개선 | FE-S01~S06·S08·S10, SP-S01·S12, POC-S01·S16, IA-S14 | 이번 후보의 자원·비용 절감 실측 없음 | 원시 provider usage와 턴/attempt 귀속, 미보고 값 보존, CPU/RSS·I/O 측정. 전후 같은 조건으로 개선 비교 |
| 13. Identity·MCP·Artifact·Wiki·Web Renderer·Search·Browser 완전 지원 | WIM-S01·S02·S04·S08, CMG-S15 | WIM-S04 후보가 MCP 결과의 일반/승인 경로와 보관 소유자를 연결. 실제 호출은 미실행 | 실제 MCP non-text 결과가 도구 소비자·저장·후속 입력에 보존됨. 각 외부 도구의 자격·실패·재접속·산출물 확인은 따로 필요 |
| 14. 프롬프트·Keeper 설정을 포함한 세계 Export/Import | WIM-S09~S12, SP-S11·S12·S14·S15 | 현재 round-trip 동작 미확인 | 세계 묶음을 다른 위치에 import한 뒤 설정·identity·참조·권한 대조와 재기동. 파일 복사 성공만으로 판정하지 않음 |
| 15. 모델에 가는 글과 설정을 TOML·Markdown 등으로 외부화 | WIM-S13~S16, TLJ-S14a·S14b, X08 | 이번 수리는 전체 문자열 외부화를 수행하지 않음 | 모델 입력·도구 설명·화면 문구별 소유 정본, 텍스트 변경 후 실제 소비 결과. 타입/wire 식별자와 자연어 본문 범위를 구분 |
| 16. 에이전트 개발을 전제로 CI·검사 병목 완화 | OD-S07·S09~S12·S14, POC-S14 | 작은 소스 단위와 독립 리뷰 사용. CI 기다림 없이 후속 구현 진행. 직접 gh 조회는 연결 실패이며 원격 게시는 미완료 | ready→review, fix→rereview, freeze→검증 시간과 미완료 표본. 기존 release 필수 검증을 빠뜨리지 않고 병목이 줄었는지 측정 |
| 17. MultiModal과 외부 도구 해석 | WIM-S03~S07 | WIM-S03 후보에 문서·혼합 투영, 중첩 ToolResult, canonical 복원 사례 작성 | 같은 후보에서 실제 PDF/STT·provider failover·재시작 실행. active tool round의 문서, connector 첨부, video·외부 reader는 별도 남음 |
| 18. 일관되고 편한 TUI 조작 | OD-S02·S03a·S03b | 이번 실행의 키 조작·화면 흐름 미확인 | 키 입력→요청·저장 상태·결정의 일관성, 실제 사용 관측. 문구·행 순서 snapshot으로 대체하지 않음 |
| 19. File I/O 병목 | SP-S01·S03·S04·S09·S10a·S10c, CA-S11a~S11c, POC-S16 | Schedule 수리는 정확성 후보이며 I/O 절감 후보가 아님 | store 크기·동시 writer별 읽고 쓴 바이트와 지연 측정. Board·Task·이력 경로의 전후 비교 |
| 20. BasePath 백업·이식·외부 동기화 | SP-S11~S16 | 복구 사본의 최신성을 추정하지 않는 Schedule 후보만 있음. 백업·이식·동기화 미검증 | owner가 만든 snapshot/export의 목록·계보·참조 검증, 새 위치에서 부팅·원래 작업 재개. 동기화 방향/동시 writer 계약도 확인 |
| 21. 기억과 그래프 | CMG-S08~S13·S15·S16 | 현재 관계 조회·공유 기억 개선 동작 미확인 | typed 관계의 작성·조회·변경·권한 사례, 서로 다른 Keeper가 같은 사실의 수정과 근거를 읽는 기록 |
| 22. Anything/Keeper/Async/Batch/Memory As Tools | TLJ-S01·S02·S08·S13~S15, CMG-S04·S10, WIM-S04·S05·S07, IA-S12 | TLJ-S01의 종단 원문·영구 전달 증거를 소스에서 구현하고 재기반 후 독립 검토했다. 실제 위임 종단 전달·기존 요청 회복은 미검증 | ACK 뒤 재시작, enqueue/기록 사이 중단, 초기 실패·stream 종료·재투영, batch 원본별 결과. 다른 도구화 범위도 실제 소비자로 검증 |
| 23. Proactive·Reactive와 여러 턴/큐의 주의력 | CA-S07~S10·S12a~S14 | Schedule stale mirror→중복 wake 방지 사례 작성. 여러 출처 동시 운용 미실행 | 수신·기록·ACK 연결, 동일 Keeper의 여러 큐와 proactive 출처 동시 주입, provider 전환·재시작 후 누락/중복 대조 |
| 24. 유머 유지 | SP-S12, CMG-S09, TLJ-S08, WIM-S12, OD-S20 | 이번 실행에서 문구 견본·사용자 선택 미확인 | 실제 화면·작업대 문구를 읽은 사용자 선택. 상태·숫자·판정 의미를 흐리지 않는지 확인 |
| 25. 구체적 사실·검증된 연구와 사용자 관점을 구현 | SP-S16, CMG-S02·S14, FE-S07·S09, POC-S05·S14, IA-S14, TLJ-S04·S10, CA-S15a~S15c | 기존 [선행 사례 조사](../research/2026-11-12-agent-farm-prior-art.md)의 위치와 후보별 근거 기록을 확인함. 모든 외부 출처를 이번에 재검증하지 않음 | 각 채택 주장→원문→설계→실행 결과 연결, 추정과 관측 구분. 현재 변경의 실측이 기존 연구를 MASC 성능 증거로 대신하지 않음 |

## 단계별 성공 조건은 그대로 남아 있다

N0의 접근 경계·기준선·결정 기록부터 N+7 판정까지 [원래 계획 §4~6](2026-11-12-agent-farm-plan.md)을
계승한다. 단계는 작업 checkpoint이며, 다른 독립 조각의 진행을 막는 새 runtime gate가 아니다.

| 단계 | 계승할 확인 범위 | 이번 기록의 판정 |
| --- | --- | --- |
| N0 | 접근 경계 수리·고치기 전 기준선·기존 결정과 배포 기록 | 현재 배포·기준선 완료 미확인 |
| N | 앞선 접근 경계와 첫 수리·hard cut, 기존 캠페인의 실제 반영 | 미확인 |
| N+1 | typed 기반·identity·잠금, 기준선과 변화 대조 | 후보 일부만 있음; 단계 미완료 |
| N+2 | 공식 연속성 시작·판정 lane·Board append·큐 형식 | 미확인 |
| N+3 | 읽은 자리 뒤 공유 기억 전달·공식 runtime·세계/관계 변경 | 미확인 |
| N+4 | canonical 이력 원천과 공식 연속성 행렬 | 미확인 |
| N+5 | transcript offset 색인과 성장 뒤 읽기 시간 | 미확인 |
| N+6 | 기록 뒤 ACK, lane별 24시간 본문/소비 대조 | 미실행 |
| N+7 | 고정 14칸 S1~S5·F1~F5·T1~T3·G, 같은 후보의 규모 측정 | 미실행 |

고정 칸의 원래 수를 줄이거나 새 후보 시험 수로 바꾸지 않는다.
G1의 `18+3+12`, G2의 `18`, G3의 `30`, G4의 최초 `48` 뒤 확장 `108`, G5의 `5`는
원래 계획과 [Reliable change 로드맵](../RELIABLE-CHANGE-ROADMAP.md)의 계약을 그대로 참조한다.
각 수의 범위·제외·정답 상태도 원문을 따른다. 실패 칸을 다음 계획으로 넘기는 것은
사용자의 전체 목표를 완료한 것으로 세는 일이 아니다.

Multiple Keeper × Multiple Queue × Multiple Proactive 행렬은 아직 실행하지 않았다.
원래 측정점은 K=`1·4·16·29·64`, Q=`동시 큐 종류 1·3·6 × 깊이 1·10·100`,
P=`tick·schedule·Board·maintenance·Goal`, H=`1·2·4`, M=`1·2`다.
큐 여섯은 event queue·메시지·Board attention·schedule·verifier slot·add-on 구독이다.
이 값은 시험 조건이며 runtime의 임의 동시 실행 상한이 아니다. 원래 단계별 조합을
따르며 모든 축의 단순 곱을 새 필수 사례 수로 발명하지 않는다. 모든 runtime의
10턴 이상, 1h·2h·4h·24h+ 연속 동작, 장애·failover와 실제 UI 증거도 남아 있다.

## 다음 갱신

Lifecycle 후보의 전체 CLI/TUI 연결·설치와 Linux `sg` 전달은 구성요소 시험과 별도로
확인해야 한다. MCP decoder 8개 다음에는 일반 호출·승인 replay·artifact 보관과 GC의
실제 소비자를 검증한다. MASC declaration/H5·provider failover와 설치 후보의 실제
PDF/STT·재시작·원래 요청 회복에도 각 범위의 실행 영수증이 필요하다.
별도 Librarian 아홉 층은 현재 main과 전체 스택을 대조하고 실제 Runtime/Exact/installer
사례를 검증해야 한다. 게시 가능한 시점에는 모든 대상의 원격 head·REST stack·중복 작업을
다시 읽고 변경된 base를 검토한다. 원본 8-ref 게시 packet과 update note의 문서 head·증거
연결도 최신 커밋에 맞춘다. 현재 로컬 통합을 원격 게시나 최신 main 완료로 세지 않는다.
각 후속 증거는 source/binary/config와 원본 위치를 적고, 실행하지 않은 항목은 계속
미실행으로 남긴다. 원래 25개 요구와 단계·규모 행렬은 유지하며 목표를 닫지 않는다.
