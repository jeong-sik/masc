# Agent Farm 실행 기록 — 2026-11-16

사용자 요청은 25개 요구를 갖춘 MASC를 실제로 동작하게 만드는 것이다.
[11월 12일 계획](2026-11-12-agent-farm-plan.md)의 범위·조각·단계별 성공 조건은 유지한다.
이 문서는 그 계획의 현재 실행 위치를 적는다. 계획의 `covered`는 설계에서 다루었다는
뜻이지 구현·실측 완료가 아니다. 아래 후보로 전체 목표나 어느 단계를 완료 처리하지 않는다.

초기 조사 기준은 로컬 `85f2823f053a693cecc8b63d6d0cb460dd10f9d0`이며,
후속 후보의 별도 base와 검토 head는 아래에 적는다.
다른 세션의 작업은 별도 worktree에서 확인했다. 현재 원격 main 전체와 모든 열린 PR의
구현을 대조한 기록은 없다. 이 기록의 미확인은 기능 부재 판정이 아니다.

## 현재 후보와 담당

| 작업 | 확인한 산출물 | 증거와 남은 일 |
| --- | --- | --- |
| Schedule 저장 권위 | `921754a8947c89fc78ddb9992abd88c09d994c66`: 복구 mirror를 변경 근거로 쓰지 않으며 읽기 출처를 보존한다. 별도 스택 `fix/farm-schedule-authority-20261116` | 독립 소스 리뷰·구문 검사 기록. 동작 시험·PR 게시·병합·설치·원래 장애 회복 미확인. 증거는 별도 문서 커밋 `5b326829b1002244dd1cb4f7cb874b938c6ea823`의 `docs/evidence/2026-11-16-schedule-primary-authority/README.md` |
| WIM-S03 문서 입력 | Core `0ecf7bd04792cf97d0cab2ab07e61da09bac2445`, MASC `6b4589d360235b79b43b40dd6d4b379c836a8322`: 문서·혼합 입력 선언, H5 읽기, wire·크기 추정·재생의 문서 투영을 맞춘다 | [증거 기록](../evidence/2026-11-16-farm-document-input/README.md). 독립 소스 리뷰·구문 검사, Dashboard 타입 검사와 선택 decoder 시험 1건 통과. OCaml 동작 시험·실제 provider·PDF/STT·브라우저·설치 미확인 |
| TLJ-S01 위임 결과 | 협업 세션 `01a1e1b9…`, `.worktrees/farm-evolution-20261116`. 세 층 최종 head `e6ea78da93a1ebac6f6020aafb134631024ba769`, base `606e16f5ce8b5c69ad9d18e82f6bf076aaf7f13d`. canonical 종단 상태, 기동 재투영, 영속 전달 의도·답 원문·전달 영수증을 연결 | 두 P2였던 보관 기간 뒤 중복 전달과 fail-open journal 뒤 답 유실을 소스에서 수정했다. 재기반 후 독립 검토에서 미해결 P0/P1/P2 없음. 기존 세 패치와 range-diff가 같고 32개 후보 파일이 이전 최종 head와 일치함을 확인했다. 작성 세션의 OCaml 31개 구문 검사 기록이 있다. 타입·동작·CI·설치·원래 요청 회복·GitHub 정식 승인·게시 미확인 |
| WIM-S04 MCP 결과 | `fb6858311cc67bc743d7c0fcbe9165dbffc2dbc3`: 일반·승인 호출의 audience 투영, 미디어·일반 binary 보존, 공개 manifest·실제 승인 결과 원장·chat의 보관 소유권과 status 노출 경계를 연결 | [증거 기록](../evidence/2026-11-16-farm-mcp-content/README.md). 독립 소스 리뷰의 미해결 P0/P1/P2 없음, OCaml 38개 구문 검사 통과. 타입·동작 시험·실제 MCP/provider·재시작·GC 실행은 미확인 |
| IA-S13 공유 SSH 이름 | `.worktrees/farm-remote-namespace-20261116`, 시작점 `71a19f1c9030978d8ccf54e311782b6cfed6d1d5`. 공용 I/O `e85a523e115355e58c87283c6c6f3b8cc9a0a393`, 게시·복구 엔진 `c09c461ac91598e4e41c42f25c6ad88f1ec14352`, UID 생성기 `40605b3164e9efb88c3ba3d5f8f25dc89c36e26d`, SSH 경로·효과 준비 `d20ff52623871b22eacb705498356a84a6e1759d`, 생성 잠금 공유 `107ed0a199696cf27a8d1b18d47456bb459b54a4`를 커밋했다 | 게시·복구 엔진의 격리 시험 62개에는 기반 I/O 14개가 포함된다. 후속 UID·잠금 시험 15개도 실제 파일시스템에서 통과했고, 해당 7개 변경 파일의 독립 소스 검토에 미해결 P0/P1/P2가 없다. SSH 35개 파일은 독립 소스 리뷰와 구문 검사만 확인했다. 서버 시작·직접 Workspace 생성 연결, 실제 SSH, VM·volume GC 전환은 미완료. 원격 데이터 변경·삭제·설치 없음. `U02:IA-S13`은 승인 완료가 아님 |

본 세션은 저장·add-on·입력 경계와 이 실행 기록을 맡는다. TLJ-S01의 같은 구현을
다시 만들지 않고 해당 세션의 산출물을 현재 head에서 대조한다. 기록된 스택 게시 시도는
로컬 `gh stack` 인증 토큰 부재로 종료됐다고 각 증거 기록에 남아 있다. connector 조회가
가능하다는 사실은 native stack 게시 완료를 뜻하지 않는다. 원격 반영 전에 실제 main,
스택 구성과 겹치는 작업을 다시 확인한다.

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

협업 세션은 TLJ-S02의 E8 worker 교체 구현을 시작했다고 전달했다.
이는 일부 구현과 구문 검사에 관한 상대 세션의 보고다. 해당 후보의 독립 검토와
실제 동작은 이 기록에서 확인하지 않았으며, 완료로 집계하지 않는다.

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
| 16. 에이전트 개발을 전제로 CI·검사 병목 완화 | OD-S07·S09~S12·S14, POC-S14 | 작은 소스 단위와 독립 리뷰 사용. CI 기다림 없이 후속 구현 진행. 게시는 로컬 인증에서 막힘 | ready→review, fix→rereview, freeze→검증 시간과 미완료 표본. 기존 release 필수 검증을 빠뜨리지 않고 병목이 줄었는지 측정 |
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

워크스페이스 UID 생성을 서버 시작과 직접 Workspace 생성 경로에 연결하고,
별도 TLJ-S02 후보의 현재 상태를 받는다.
게시 가능한 시점에 두 기존 스택의 원격 head와 중복 작업을 다시 읽는다. 후보의 행동
시험·설치·격리된 실패 재현·장시간 행렬은 실제 실행 영수증을 얻은 순서대로 이 기록에
추가한다. 각 항목은 source/binary/config와 원본 증거 위치를 적고, 실행하지 않은 항목은
계속 미실행으로 남긴다. 원래 25개 요구를 전부 입증하기 전에는 목표를 닫지 않는다.
