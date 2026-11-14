# 에이전트 Farm 계획: 요구 25개, 감사 빈틈 199건, N0~N+7 단계

2026-11-12~13 에 쓴 계획이다. 이 보고서가 병합하는 코드는 없다. 설계가 인용한 좌표(파일 경로와 줄 번호)는 `2ed0170118fd` 에서 읽었다. 그 뒤 main 이 `aa1ff9233691` 로 움직였지만 인용한 파일은 바뀌지 않았다(14절). PR·이슈 상태는 11-13 16:00 KST 에 다시 확인했다.

## 한눈에

- 사용자가 낸 요구는 25개다. MASC 를 17개 영역으로 나눠 감사했고 빈틈 199건을 찾았다. 검증 뒤 등급은 P1 32건, P2 97건, P3 70건이다.
- 설계는 아홉 축으로 나눠 지었다. 축마다 반박을 둘씩 받았다. 통합본은 완성도 검토를 둘 받고 한 번 마무리했다.
- 조각은 164개이고 보류가 셋이다. 크기는 PR 수로 센다. 합은 358 PR 이다.
- 단계는 N0 부터 N+7 까지다. 단계는 Gate 가 아니다. 앞 단계가 다 끝나지 않아도 다음 단계의 조각을 시작한다. 단계는 진행을 세는 checkpoint 다.
- N0 은 보안 수리 둘, 고치기 전 기준선, 결정 요청이다(18조각, PR 33). `/health` 세 층의 배포가 다른 모든 배포보다 먼저다.
- 가장 긴 길은 공유 기억 사슬이다. X01 → CMG-S03 → CMG-S04 → CMG-S07 → CA-S11c → CA-S14 로 간다. 길이는 24걸음이다(PR 16 + 사건 8).
- 사용자 결정은 31개다. 결정 하나를 조각마다 따로 묻는 경우가 있어 묻는 행은 52개다. 행마다 그 조각이 준비될 때 묻는다. '아니오'면 빠지는 조각을 행마다 적었다.
- 운영자 할 일은 133건이다. 결정 행 50(보류인 U29·U30 두 행은 뺐다), hash 승인 11, 사람 리뷰 PR 41, 배포 창 17 이 대부분이다. 운영 조치 2건은 MASC 를 공개 주소로 내는 설치에만 해당한다.
- 기준선은 measure lane 이 잰다. measure lane 의 주인은 조각을 짓는 lane 의 주인과 다르다. 운영자가 그 hash 를 첫 수리 PR 전에 승인한다.
- N+7 은 고정 칸 열넷의 pass/fail 로 끝난다. fail 칸은 원인과 함께 다음 계획으로 넘긴다.
- 두 가지는 종류만 적었다. 아직 고치지 않은 접근 경계의 세부(9절)와 Candle 지급 경로 조각이다. Keeper 가 이 저장소를 읽기 때문이다.

## 1. 무엇을 어떻게 봤나

- 2026-11-12 19:20~22:45 KST 에 MASC 를 17개 영역으로 나눠 감사했다. 영역마다 agent 셋이 돌았다.
  감사 agent 가 빈틈을 적었다. 코드 검증 agent 와 진행 중 작업 검증 agent 가 그것을 반박하려고 다시 읽었다.
- 빈틈은 199건이다. 검증 뒤 등급은 P1 32건, P2 97건, P3 70건이다. 반박돼 빠진 것은 없다.
  코드 검증은 확인 113건, 일부 확인 86건이다. 일부 확인은 대부분 등급을 낮추거나 근거를 좁힌 것이다.
- 진행 중 작업과 견주면 아무도 안 다루는 빈틈이 110건, RFC 만 있는 빈틈이 58건이다.
  사용자 결정이나 헌법과 부딪히는 방향이 20건이다. 이 20건은 7절에서 결정으로 올린다.
- 외부 근거는 12개 주제로 따로 조사했다. 주장 168건 가운데 136건이 원문과 맞았다.
  26건은 원문보다 세게 말했고 5건은 잘못 인용했고 1건은 낡았다. 계획은 맞은 주장만 근거로 쓴다.
- agent 는 읽기만 했다. 빌드·시험·서버 실행은 하지 않았다. 규모 서술은 코드 구조에서 읽은 추정이다.
- 설계는 아홉 축으로 나눴다. 축 이름과 약어는 아래 표와 같다.
  축마다 초안 하나에 반박 둘(규칙 위반, 실행 가능성)을 받고 final 을 냈다.
- 아홉 final 을 하나로 합쳤다. 통합본은 완성도 검토 둘(요구 덮음, 회의적 검토)을 받았다. 그 뒤 한 번 마무리했다.
  고친 내용은 14절에 있다.
- 마무리한 설계는 조각 164개와 보류 셋, 358 PR, 결정 31개(행 52개)다.
  단계·스택·가장 긴 길·'아니오'면 빠지는 조각은 스크립트가 계산했다. PYTHONHASHSEED 0~15 에서 결과 hash 가 하나다. 조각 사이에 순환은 없다.
- 근거 묶음은 [감사](../evidence/2026-11-12-agent-farm-plan/)와 [외부 근거](../evidence/research/2026-11-12-agent-farm-prior-art/)에 있다.
  접근 경계 영역의 세부는 수리 전까지 싣지 않았다(9절).

| 약어 | 축 | 판정을 낸 요구 |
| --- | --- | --- |
| CA | 연속성·주의력(continuity-attention) | 1, 3, 10, 19, 23, 24 |
| SP | 저장·이식(storage-portability) | 1, 2, 4, 12, 14, 16, 19, 20, 24, 25 |
| CMG | 협업·기억·그래프(collab-memory-graph) | 1, 21, 22, 24, 25 |
| FE | 되먹임·경제(feedback-economy) | 11, 12, 24 |
| IA | 격리·접근(isolation-access) | 5, 6, 24(하지 않음) |
| OD | 운영자·개발 루프(operator-devloop) | 2, 7, 16, 18, 24, 25 |
| POC | provider·OCaml 코어(provider-ocaml-core) | 2, 3, 4, 12, 16, 19, 25 |
| TLJ | 도구·lane·판정(tools-lanes-judgement) | 8, 9, 10, 22, 24 |
| WIM | 세계·입출력·멀티모달(world-io-multimodal) | 13, 14, 15, 17, 19, 22, 24 |

X 로 시작하는 조각은 축 사이 빈자리에 통합 단계가 더한 것이다(4절).

## 2. 요구 25개와 지금 MASC

| 요구 | 지금 | 검증 뒤 P1 |
| --- | --- | --- |
| 1 Keeper 의 시간 맥락·협업·지식 개선, 저장·잠금 | Agent Core 는 턴마다 checkpoint 를 쓴다. 공식 클라이언트 lane 은 쓰지 않아 lane 을 오가면 이력이 갈린다. 지금 시각은 턴의 첫 요청에만 간다. 공유 기억은 Keeper 가 도구를 불러야 턴에 닿는다 | 5 |
| 2 용어·문서 최신 | 문서를 최신으로 지키는 장치는 글로 쓴 규칙 하나뿐이다. 틀린 문장 24곳, 용어집 정의 306개, RFC 493개 중 Draft 351개다 | 1 |
| 3 provider 공통 프로토콜 | API lane 은 codec 여섯이 닫힌 타입으로 맞춘다. 공식 클라이언트 lane 다섯은 오류를 옮기는 규칙과 stop reason 을 따로 짠다 | 1 |
| 4 OCaml 을 끝까지 | 하위 library 는 200개다. catch-all 금지는 지켜지고 `Obj.magic` 은 0건이다. production 45만 줄이 library `masc` 하나에 있다. blocking·domain 소속·실패는 관례로만 지킨다 | 0 |
| 5 RemoteSSH·여러 사람·microVM, Docker 는 뒤 | 실행 자리는 다섯이고 SSH 경로는 운영 기록이 있다. 한 운영자·한 신뢰 범위를 전제로 한다 | 4 |
| 6 외부 Dashboard 와 권한별 노출 | 사람 신원이 있는 계정 서버에는 Dashboard 가 없고, Dashboard 가 있는 서버에는 사람 신원이 없다 | 3 |
| 7 TUI 와 음악 취향 | run_loop 하나 약 11,000줄, 상태 레코드 칸 1,011개다. 음악은 TUI 안 작은 기능 넷과 따로 까는 Node 도구로 갈린다 | 0 |
| 8 Pluggable Add-on lane | 저장소 밖 패키지는 TOML 의 manifest_path 로 꽂힌다 | 1 |
| 9 Hook·Exact Output 판정 | Hook 은 schema 검사 두 값뿐이다. 판정 계약이 셋(Fusion, verifier, exact output)으로 갈렸다 | 1 |
| 10 System-One·Two | Keeper 에게는 System Two(Fusion)만 보인다. 느린 판정으로 넘기는 규칙은 숫자 문턱 하나다 | 2 |
| 11 Candle 경제·Stock | 원장은 돈다. 자산은 하나다. 거래·주문·가격 사건이 없다. 헌법이 장신구만 사게 한다 | 3 |
| 12 사용량 가시성·되먹임 | 턴 사용량과 마지막 요청 구성은 보인다. 통계가 Keeper 맥락으로 돌아가는 경로는 opt-in 하나다. 그것을 켠 설정은 없다 | 1 |
| 13 Identity·MCP·Artifact·Wiki·Search·Browser | 각 도구는 돈다. MCP 확장은 빌드 때 선언에 묶이고 다계정에서는 외부 도구가 닫혔다 | 5 |
| 14 세계 Export·Import | 세계를 한 묶음으로 꺼내고 들이는 경로가 없다. preset 형식이 둘이다 | 2 |
| 15 글은 TOML·Markdown | system prompt 와 도구 스키마는 TOML·Markdown 으로 옮겼다. 60자 넘는 literal 이 8,711개 남았고 감사한 날(11-12)에도 늘었다 | 2 |
| 16 agent 가 일하는 전제, 검증 병목 | 리뷰 승인이 restack 마다 층 수×2 만큼 사라져 리뷰가 CI 보다 먼저 막힌다. 헌법 CI 계약과 실제 CI 가 다르다 | 1 |
| 17 MultiModal 과 외부 해석 | 이미지·음성·PDF 는 타입 있는 block 으로 턴에 닿는다. video, PDF 밖 문서, MCP 결과의 non-text 는 못 읽는다 | 5 |
| 18 TUI 조작 일관성 | 키는 문자열로 읽혀 순서 있는 match 316갈래를 지난다. 화면 문법 RFC 의 키 variant 는 코드에 없다 | 0 |
| 19 File I/O 병목 | Tasks(5.2 MB)·Schedule(12.3 MB)은 변경마다 문서를 두 번 통째로 쓴다. Board 는 comment 한 건마다 94.6 MB 를 다시 읽는다 | 3 |
| 20 BasePath 백업·이식·동기화 | 내보내고 들이는 경로가 없다. 백업 단위가 217.2 GiB, 파일 365만 개 전체다. 저장 기록이 절대 경로·inode 를 담는다 | 5 |
| 21 기억과 그래프 | Activity_graph 는 이벤트 log 이고 관계를 묻는 API 가 없다 | 1 |
| 22 Anything As A Tool | 도구 선언은 TOML 227개를 한 곳에서 읽는다. 위임이 끝났다는 사실이, 스트림이 닫히거나 서버가 재시작하면 물은 Keeper 에게 가지 않는다 | 1 |
| 23 Proactive·Reactive, 큐와 주의력 | Keeper 마다 큐 둘, 턴 슬롯 하나다. 주기 tick 은 조건 없이 턴을 연다. 실패한 턴은 받은 행을 하나도 지우지 않는다 | 0 |
| 24 유머 | 초상화 장신구와 음악 기능이 있다. Candle 잔액이 가장 싼 유료 장신구 값에 닿지 못한다(#49173) | 3 |
| 25 사실·논문·연구자 | 외부 근거 168건 확인(1절) | - |

P1 칸은 그 요구를 맡은 영역에서 나온 P1 건수다. 요구 1·10·24 는 영역 둘 이상이 나눠 맡아 겹쳐 센다.
전체 P1 은 32건이다. `counts.py` 가 요구별로 다시 센다.

## 3. 근본 규칙

조각은 아래 규칙에서 나온다. 규칙 하나가 여러 축의 조각을 묶는다. G14 는 통합 검토에서 더했다.
헌법 칸의 `:N` 은 `docs/constitution.xml` 의 줄 번호다. 축 규칙 칸의 R·D 번호는 그 축 설계의 규칙·결정 번호다.
이 글의 `brief §2.N` 은 사용자가 이미 정한 것 열넷의 번호다. 목록은 [선행 사례 조사](../research/2026-11-12-agent-farm-prior-art.md) §15 머리에 있다.

| 규칙 | 뜻 | 헌법 | 축 규칙 |
|---|---|---|---|
| G1. 사실 하나에 원장 하나 | 같은 사실을 담는 다른 저장소는 지우고 다시 만들 수 있는 파생뿐이다. | authoritative_read_only :232-235 | CA R1, SP R1·R5, CMG R1, FE R2, WIM R4 |
| G2. 기록 먼저, 효과 뒤 | 모델에 보내기 전에 기록한다. 큐 행은 기록에 남은 뒤에만 떠난다. 밝힌 사실은 그 뒤 답으로 지우지 않는다. | persist_before_model_call :227-230, failure_keeps_evidence :237-240 | CA R1·R3, POC R1, SP R7, TLJ R1 |
| G3. 닫힌 합(closed sum type), 문자열은 경계에서만 | 판정·종료 사유·호출자·block·설정 key 는 닫힌 합으로 흐른다. 모르는 값은 버리지 않고 '모름'을 뜻하는 타입 값으로 남긴다. | closed_sum_over_string :215-219, strict_parse_no_default :221-225, string_matching :456-462 | CA R2, POC R2·R3, IA R5, TLJ R2, WIM R1·R5, OD R5, FE R3 |
| G4. 숫자 비교·시간 창·누적 숫자로 흐름을 정하지 않는다 | 순서는 payload 종류와 기록 순서에서, 해제는 실제 자원 사실에서 나온다. | magic_number :446-454, budget_gate :464-471, no_wall_clock_death :207-213 | CA R4, SP R1, IA R4, FE R1·R7, TLJ R4 |
| G5. 변경 한 건의 비용은 store 크기와 무관하다 | 전체 읽기·쓰기는 부팅 압축·정리 pass·export·운영자 명령에만 있다. | success_bar :257 | SP R2, CMG R1, CA-S11a~S11c, FE-S03a·S03b |
| G6. 읽기는 Present·Missing·Unreadable, 실패는 값 | Unreadable 위에는 쓰지 않고, 잠금 안 예외는 푼 뒤 다시 던진다. | failure_keeps_evidence :237-240 | SP R3·R4, FE R3, OD R7 |
| G7. 이름과 자격은 주체에서 | Keeper 식별은 닫힌 합이다(운영자 TOML Keeper \| 사람 Keeper(owner, keeper_id)). 실행 자리 이름은 작업공간과 Keeper 를 만들 때 붙인 UID 에서 나온다. | hardcoded_path :479-484 | IA R3, SP R6, FE R4, X01 |
| G8. 요청 하나는 판정 함수 하나를 지나 typed 호출자 하나 | 판정 함수가 읽기를 주지 않은 요청에는 운영자 값이 나가지 않는다. /health 는 그 요청에 공개 probe 다섯 칸만 답한다. | board visibility :139(U09 로 고침) | IA R5·R6, IA-S02·S10a~S10c |
| G9. 측정은 일하는 에이전트가 못 바꾼다 | 기준선은 measure lane 이 잰다. 그 주인은 조각을 짓는 lane 의 주인과 다르다. 운영자가 hash 를 첫 수리 PR 전에 승인하고, 수리 PR 끝 조건이 그 hash 를 인용한다. 같은 sha 끼리만 비교한다. | evidence :532-536, testing :524-530 | CA R5, POC R5·R6, OD R6, FE R6, CMG R4 |
| G10. 판정 확장은 턴을 만들거나 막지 못하는 자리에만 붙인다 | 결과는 기록과 다음 턴 투영(projection)으로만 가고 턴을 만들거나 막지 않는다. 사람을 기다리는 건수도 행동을 막지 않는다. | gates :503-508 | TLJ R3·R5, CMG R4, OD R1 |
| G11. 글과 사실은 원천 한 곳 | 문서는 그 자리를 가리키거나 렌더하고 개수를 베끼지 않는다. | legacy_residue :492-499 | WIM R2a·R4, TLJ R2, OD R4 |
| G12. Keeper 사이 요청은 일반 메시지 | 응답·대기·재시도 의무가 없고 과거 사실을 scheduling Gate 로 쓰지 않는다. | brief §2.2 | TLJ R1, CMG R1, U21 |
| G13. 앞 결정이 선 곳은 그대로 | System One 문턱과 media 재전송은 사용자의 앞 결정을 유지한다. 달라진 사실만 사용자에게 한 번 알린다. | magic_number :446-454(부딪힘 기록) | U30 |
| G14. 입력 초과는 기록된 부분 경계에서 나눈다 | 턴 입력이 typed 입력 초과로 끝나면 입력을 기록된 부분 단위로 나눈다. 부분 단위는 받은 행, 기억 항목 같은 것이다. 나눈 입력은 같은 턴 안에서 다시 투영한다. 혼자서도 넘치는 부분은 typed 거절로 기록한 뒤 ACK 한다. 숫자 상한·반씩 나누기·운영자 격리 상태는 없다. | failure_keeps_evidence :237-240, budget_gate :464-471, magic_number :446-454 | CA D10·S14, CMG-S04, CA-S12b(반씩 나누기 삭제 근거), U18a |

## 4. 단계표

조각은 자기 기다림과 결정 행이 풀리면 바로 시작한다.
단계는 조각을 세는 자리다. 조각은 병합되거나 결정 '아니오'로 빠질 때 그 단계에서 센다.
단계 번호는 조각 사이 의존의 깊이에서 나왔다. 사건 노드는 깊이를 더하지 않는다.
N0 은 사용자가 정한 보안 수리 둘과, 기다릴 것 없는 기준선·결정 요청이다.
X01 은 첫 소비자 CMG-S03 과 한 스택이라 N+1 에서 센다. 단계마다 조각·PR 수는 아래 크기 표에, 규모 목표는 6절 표에 있다.
checkpoint 는 모두 '그 단계의 조각이 병합됐거나 결정 아니오로 빠졌다(결정 기록 위치를 적는다)'로 시작한다. 표에는 그 밖의 조건만 적었다.

| 단계 | 이름 | 목표 | checkpoint |
|---|---|---|---|
| N0 | 보안 둘·기준선·결정 요청 | 자격 없는 `/health` 응답을 수리 세 층(L1·L2·L3)에 걸쳐 줄인다(L1 → D0a → L2·L3 → D0). `/ws` 뒤에 남은 판정 층(IA-S02)을 고친다. 고치기 전 기준선을 sha 와 함께 남긴다. 지금 준비된 결정 행을 묻는다. | D0 뒤 strict 서버의 자격 없는 `/health` 는 server·version·live·ready·phase 만 답한다(임시 설치 시험). 운영자가 기준선 hash 일곱을 승인했다. OD-S11 이 승인 공급 A 와 push 수 π 를 쟀다(뜻은 13절). D0a 전에는 어떤 배포도 하지 않는다. |
| N | 기다림 없는 수리·RFC·첫 hard cut | D0 뒤에 연다. 기다릴 것 없는 고장 수리와 RFC 개정을 낸다. hard cut 넷(FE-S06, IA-S13, IA-S15, WIM-S16)을 설치한다. 다른 캠페인 창(E1·E2·E4·E8·E9)에 걸린 조각은 그 병합 뒤 main 위에서 시작한다. | hard cut 넷을 창마다 하나씩 설치했다. 운영자가 TLJ-S09·OD-S17 기준선 hash 를 승인했다. |
| N+1 | 닫힌 타입과 기반 층 | Keeper 식별 합(X01)을 첫 소비자인 공유 기억 writer(CMG-S03)와 한 스택으로 넣는다. 공식 decoder, 잠금 라이브러리, tool-call 색인 개정, add-on 소비 지점 주인, 서버 identity 저장소도 넣는다. 뒤 조각은 문자열 대신 타입을 읽는다. | SP-S01 bench 로 잰 잠금 전후 차이가 H-SP-S01 기준선 잡음 안이다. tool-call 색인 bump 는 계획 전체에서 한 번이다(U11 '예'면 FE-S04, '아니오'면 FE-S03b). 운영자가 CA-S15b·CMG-S14 판정 hash 를 승인했다. 스크린샷: IA-S01, WIM-S05, WIM-S08. |
| N+2 | 공식 연속성 시작·판정 lane·원장 한 줄 | Claude Code 공식 턴을 canonical 에 쓰기 시작한다(U01). 판정 lane 주인, Board 원장 한 줄 쓰기, 큐 형식 hard cut(CA-S13), typed 호출자 tool-call 행(FE-S04)을 넣는다. | O-CA-S02: Claude Code 공식 턴 atom 이 24시간 빠짐 없이 canonical 에 있다. Board append 한 건이 읽는 바이트가 원장 크기와 무관하다(SP-S01). IA-S07 전후 swap 을 임시 설치에서 IA-S14 로 쟀다(M-IA-S07). 스크린샷: CMG-S09, FE-S14. |
| N+3 | 읽은 자리 뒤 전달과 남은 hard cut | 공유 기억 전달을 읽은 자리 뒤부터 읽기로 바꾼다(CMG-S04, G14). 읽은 자리는 Keeper 마다 "어디까지 받았나"를 적은 seq 와 byte offset 이다. 남은 공식 runtime 셋을 넣는다. 자격 없이 권한을 주는 갈래를 지운다(IA-S17). 세계·Candle·관계 hard cut 을 넣는다. | broadcast 한 건이 transcript 에 한 번 쓰인다(CMG-S14 A/B). Codex·Muse·Antigravity 턴 atom 이 canonical 에 있다. 공개 주소로 내는 설치의 권고 OP-02 는 9절에 있다. 스크린샷: CMG-S11, IA-S17, WIM-S11. |
| N+4 | 이력 원천 하나 | 공식 세션 정책을 하나로 줄인다(CA-S06). fleet 이 메시지 흐름을 읽은 자리 뒤부터 읽는다(CMG-S07). 연속성 매트릭스의 공식 칸을 채운다(CA-S15c). | select_official 과 공식 조각 갈래가 없다. CA-S15c 공식 칸이 H-CA-S15b 판정으로 pass/fail 을 낸다. briefing 합성은 CMG-S04 전달 대조가 빠짐 0 일 때만 지운다(U28). 스크린샷: WIM-S12. |
| N+5 | transcript offset 색인 | transcript 를 offset 색인으로 읽는다(CA-S11c). 받은 행을 external_message_id 로 찾는 길이 생긴다. 지금 chat store 에는 그 색인이 없고 select 전체 훑기뿐이다. | 경계 로그를 65일 뒤 크기(K=29)로 키운다. 그때 턴 경로 읽기 시간과 K=1 때의 차이가 H-CA-S11a 기준선 잡음 안이다(같은 반복 수). |
| N+6 | 받은 행은 기록 뒤 ACK | 받은 큐 행은 이어지는 입력 기록에 남은 뒤에만 떠난다. 연속성 사슬이 여기서 닫힌다. 혼자 넘치는 행은 G14 대로 typed 거절로 기록한 뒤 ACK 한다. | CA-S14 가 병합되고 D-CA-S14 창에서 설치됐거나 빠졌다. O-CA-S14 24시간: lane 부류마다 ACK 된 행 본문이 canonical 에 있다(빠짐 0). 성공 턴 뒤 ACK 안 된 받은 행이 0 이다. 운영자 격리 상태는 없다. |
| N+7 | 규모 판정 | 고정 칸 열넷을 같은 sha 의 측정점마다 돌려 pass/fail 로 판정한다. 새 조각은 넣지 않는다. | 칸마다 pass/fail 과 근거가 있다. 로드맵 G4 는 worker 1·2·4·8 의 48칸을 잰 뒤 16·32·64 를 잰다. |

표에 나오는 사건 이름은 이렇게 읽는다.

- D0a 는 L1 병합 뒤 재시작, D0 은 L2·L3 병합 뒤 재시작이다. `D-<조각>` 은 그 조각의 배포 창이다.
- `H-<조각>` 은 운영자의 hash 승인, `R-<조각>` 은 사람 리뷰, `O-<조각>` 은 24시간 관찰 창, `M-<조각>` 은 전후 측정이다.
- E1~E9 는 다른 캠페인의 병합이나 측정 창이다(5절). E7 은 쓰지 않는다. `U<번호>` 는 사용자 결정이다(7절).
- OP-01 과 OP-02 는 MASC 를 공개 주소로 내는 설치에만 해당하는 운영 조치다(9절). `J-N7` 은 N+7 규모 판정의 시작이다.

### 크기·운영자 할 일·멈출 조건

크기는 PR 수로만 센다. 조각의 PR 수는 네 근거를 차례로 봐서 정했다. 조각 글에 적힌 PR 수(둘 이상일 때), 층 표기, 글에 나온 단서, 축이 정한 크기다. 축이 정한 크기는 CMG 가 S1/M2/L4, 나머지가 S1/M2/L3 이다.
운영자 할 일은 결정 행, hash 승인, 사람 리뷰 PR, 배포 창, 운영 조치, 유료 실행, Goal 확인의 합이다.
관찰 창과 바깥 기다림은 할 일이 아니라 기다림이다.

| 단계 | 조각 | PR | 결정 행 | hash 승인 | 사람 리뷰 PR | 배포 창 | 운영 조치 | 유료 실행 | Goal 확인 | 운영자 할 일 | 관찰 창 | 바깥 기다림 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| N0 | 18 | 33 | 11 | 7 | 7 | 2 | 1 | 1 | 1 | 30 | 0 | - |
| N | 48 | 90 | 0 | 2 | 1 | 4 | 0 | 0 | 1 | 8 | 0 | E1, E2, E4, E8, E9 |
| N+1 | 43 | 90 | 17 | 2 | 18 | 3 | 0 | 2 | 1 | 43 | 0 | E1, E2, E3, E4 |
| N+2 | 28 | 78 | 10 | 0 | 10 | 2 | 0 | 0 | 1 | 23 | 3 | - |
| N+3 | 19 | 49 | 8 | 0 | 5 | 4 | 1 | 0 | 1 | 19 | 1 | E4 |
| N+4 | 6 | 14 | 3 | 0 | 0 | 1 | 0 | 0 | 1 | 5 | 0 | - |
| N+5 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 | 0 | - |
| N+6 | 1 | 3 | 1 | 0 | 0 | 1 | 0 | 0 | 1 | 3 | 1 | - |
| N+7 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 | 0 | - |
| 합 | 164 | 358 | 50 | 11 | 41 | 17 | 2 | 3 | 9 | 133 | 5 |  |

멈출 조건은 모든 단계에 같다.

1. 같은 sha 측정에서 앞 checkpoint 의 칸이 그 기준선 잡음 밖으로 나빠지면 새 lane 을 열지 않는다. 원인 PR 부터 고친다.
2. 잰 승인 공급으로 L_open = min(⌊A/(2π)⌋, K_build) 가 0 이면 열린 스택만 마친다. 새 lane 은 열지 않는다(식과 기호는 13절).
3. 운영자 할 일이 밀려 다음에 열 조각이 모두 결정·hash·리뷰를 기다리면 조각을 덜어 낸다. 덜어 낸 조각은 좌표와 함께 이 계획에서 뺀다.

덜어 낼 순서(멈춤 3)는 네 기준으로 정한다. N+7 고정 칸이 읽지 않는 조각부터 덜어 낸다. 그다음은 덮는 요구 수가 적은 조각, 늦은 단계, id 순이다.
N0 과 사용자가 정한 보안 수리 둘은 덜지 않는다. 고정 칸이 읽는 조각은 덜지 않고 다음 계획으로 미룬다. 고정 칸이 읽는 조각의 선행 조각도 덜지 않는다. N0 밖에서 덜지 않는 조각은 71개다(표시 칸에 칸이 있는 28개와 그 선행 조각 43개).
아래가 그 순서다. 왼쪽부터 먼저 덜어 낸다.

- 요구 1개를 덮는 조각 58개 — N+4: CA-S06, CMG-S06 → N+3: CA-S10, CMG-S13, FE-S05, FE-S15, SP-S03, WIM-S06 → N+2: CMG-S05, FE-S10, FE-S13, IA-S05, IA-S11, IA-S19, OD-S20, POC-S11, SP-S02, SP-S09, TLJ-S06, TLJ-S16, WIM-S15, X02 → N+1: CMG-S12, FE-S09, IA-S03, IA-S04, OD-S12, OD-S21, POC-S04, POC-S12, POC-S15, SP-S10a, TLJ-S12, WIM-S02, WIM-S14, X05 → N: CMG-S16, FE-S02, IA-S06, IA-S08, IA-S13, IA-S16, OD-S01, OD-S04, OD-S08, OD-S10, OD-S13, OD-S14, OD-S17, OD-S18, OD-S19, POC-S13, SP-S05, TLJ-S02, TLJ-S03, TLJ-S09, TLJ-S15, X04
- 요구 2개를 덮는 조각 15개 — N+4: WIM-S07 → N+3: CMG-S10, CMG-S15 → N+2: IA-S12, SP-S08 → N+1: IA-S18, OD-S02, OD-S03b, OD-S09, POC-S03, SP-S16, TLJ-S14b → N: OD-S03a, POC-S02, SP-S04
- 요구 3개를 덮는 조각 2개 — N+2: TLJ-S08, WIM-S04

모두 75개다.

### N+7 고정 칸

| 칸 | 헌법 | 하네스 | 판정 |
|---|---|---|---|
| S1 | success_bar :256 모든 Runtime 10턴 이상, 1h·2h·4h·24h+ | CA-S15c 공식 칸 매트릭스(runtime × 사건, 판정 hash H-CA-S15b) | 모든 runtime 칸 pass |
| S2 | success_bar :257 연속 동작 중 성능 유지 | SP-S01 bench, IA-S14 턴별 CPU·RSS, POC-S16, CA-S11a bench(CA-S11b 뒤), FE-S08 보고서를 같은 sha 로 | 24h+ 동안 각 기준선 잡음 안 |
| S3 | success_bar :258 Runtime Failover | CA-S15c lane 전환 칸, POC-S05 driver failover 표, POC-S09 서명 | lane 전환 뒤 이력 빠짐 0, 종료 사유가 닫힌 합 |
| S4 | success_bar :259 설정을 직접 하고 TOML 이 반영된다 | WIM-S16·IA-S15 재시작 대조: TOML 을 바꾸고 재시작한 뒤 읽은 값과 대조, WIM-S09·OD-S16 | 주인 없는 key 0, 대조 불일치 0 |
| S5 | success_bar :260 브라우저 실측 Dashboard | 화면을 바꾼 조각(CMG-S09·S11, FE-S14, IA-S01·S17, WIM-S05·S08·S11·S12)의 브라우저 실측과 스크린샷 | 화면마다 축 final 끝 조건의 기대값과 같다 |
| F1 | failure_conditions :247 턴을 못 돈다 | CA-S15c 칸, POC-S07 종료 사유 | 턴 못 도는 칸 0 |
| F2 | failure_conditions :248 턴이 이어지지 않는다 | CA-S15c 이어짐 칸, CA-S14 ACK 대조 | 이어짐 빠짐 0 |
| F3 | failure_conditions :249 10턴 전 자기 행동을 모른다 | CA-S07 자기 행동 목록, CA-S09 바뀐 것 층 | 10턴 전 행동 질의에 tool_calls 원장과 같은 답 |
| F4 | failure_conditions :250 Keeper 끼리 소통하지 않는다 | CMG-S04·S07 전달 대조, TLJ-S01 위임 끝 사실, CA-S13 큐 | Keeper 사이 전달 빠짐 0 |
| F5 | failure_conditions :251-253 출력 자리를 판단하지 못한다 | CA-S15a '출력 자리' 사건: Keeper_continuation_channel(keeper_continuation_channel.mli:17-47) typed 값 대조, CA-S13 Surface_ref | 시작한 자리와 이어진 자리가 같다. 먼저 말할 때 고른 자리가 맥락의 자리와 같다 |
| T1 | target_scenarios :287 협업·PoC | CMG-S14 틀, 채점 기준 hash 운영자 먼저 승인(H-CMG-S14) | 승인된 채점표 기준 |
| T2 | target_scenarios :294 웹 검색을 포함한 연구·기고문 | CMG-S14 틀, WIM-S05 붙인 서비스 도구 reader | 승인된 채점표 기준 |
| T3 | target_scenarios :295 상호 반론·변론·피드백 | CMG-S14 틀, TLJ-S07 판정 lane 주인 | 승인된 채점표 기준 |
| G | 로드맵 G1~G5 | CA-S15c, CMG-S14, IA-S14, POC-S16, SP-S01 | G1(18+3+12), G2(18), G3(30), G4(48 뒤 108), G5(5) 칸 |

고정 칸이 읽는 조각은 5절 조각 표의 표시 칸에 `칸 S1` 처럼 적었다. 덜어 낼 때 이 조각들은 덜지 않는다.

칸마다 pass/fail 과 로그·실측·브라우저 스크린샷(evidence :532-536)을 `artifacts/<topic>/` 에 남긴다.
fail 칸은 원인과 함께 다음 계획으로 넘긴다. 이 계획에는 새 조각을 넣지 않는다.

### 가장 긴 길

길이는 시간이 아니다. 조각은 PR 수로 센다. 사건(결정 행, hash 승인, 사람 리뷰, 배포 창, 관찰 창, 운영 조치, 바깥 기다림)은 하나를 1 로 센다. 동점이면 작은 id 가 이긴다.

- 가장 긴 길은 14 노드, 24걸음이다(PR 16 + 사건 8).
- 길: X01 Keeper 식별 합(PR 2, N+1) → R-X01 사람 리뷰 → U02:CMG-S03 결정 행 → CMG-S03 공유 기억 writer 하나(PR 4, N+1) → D-CMG-S03 배포 창 → U05 결정 행 → CMG-S04 읽은 자리 뒤 전달(PR 4, N+3) → CMG-S07 fleet 읽은 자리 뒤 읽기(PR 2, N+4) → CA-S11c transcript offset 색인(PR 1, N+5) → U02:CA-S14 결정 행 → CA-S14 기록 뒤 ACK(PR 3, N+6) → D-CA-S14 배포 창 → O-CA-S14 관찰 창 → J-N7 규모 판정 시작
- 여유가 0 인 조각은 스물이다: CA-S02, CA-S03, CA-S04, CA-S05, CA-S06, CA-S11c, CA-S12a, CA-S12b, CA-S13, CA-S14, CMG-S03, CMG-S04, CMG-S07, FE-S04, IA-S10a, IA-S10b, IA-S10c, POC-S05, POC-S10, X01.
- 네 사슬이 같은 길이로 나란히 간다.
  - 공유 기억: 위 길.
  - 공식 연속성: POC-S05 → POC-S10 → U01 → CA-S02 → O-CA-S02 → CA-S03~S05 → CA-S06.
  - 큐 형식: CA-S12a → CA-S12b → U18b·U02:CA-S13 → CA-S13 → D-CA-S13 → 배포 창 사슬. E3(여유 1)과 O-CA-S13(여유 3)은 이 길 옆에서 CA-S12b 와 CA-S14 를 기다리게 한다.
  - `/health`: IA-S10a → D0a → IA-S10b·S10c → D0 → 배포 창 사슬.
- 시계로 가장 긴 기다림은 넷이다. E3(영수증 관찰 창, 11-15)과 24시간 관찰 창 셋(O-CA-S02, O-CA-S13, O-CA-S14)이다. E3·O-CA-S02·O-CA-S13 은 CA-S14 앞에 있고, O-CA-S14 는 CA-S14 배포(D-CA-S14) 뒤 J-N7 앞에 있다.
- 배포 창은 한 번에 하나만 연다. 준비된 창 가운데 뒤에 남은 길이 긴 것부터 연다. 사슬은 이렇다: D0 → D-CMG-S03 → D-SP-S12 → D-SP-S14 → D-FE-S04 → D-CA-S13 → D-WIM-S16 → D-WIM-S11 → D-FE-S06 → D-CMG-S11 → D-CMG-S13 → D-FE-S15 → D-CA-S06 → D-IA-S13 → D-CA-S14 → D-IA-S15.

### 합친 것

| 남긴 쪽 | 합친 것 | 이유 |
|---|---|---|
| TLJ-S11b(보류) | CA-S16 | 같은 비교(lib/keeper/keeper_board_attention_fanout.ml:129)와 같은 키 board_attention_confidence_floor 다. 결정 CA D9 와 TLJ D7 도 하나다. 지금은 U30 으로 보류한다. |
| POC-S10 | CA-S02 PR1 decoder 닫힌 variant, CA-S03~S05 의 decoder variant 몫 | 어댑터 넷(runtime_claude_code·codex_app_server·muse_serve·antigravity)은 POC 가 쥔다. CA 는 atom 매핑·전달 기록·finalize 만 쥔다. 같은 파일 사슬이라 한 단계 안에서는 한 스택에 쌓는다. |
| WIM-S13 | TLJ-S14 PR1(RFC 개정), WIM-S15 의 도구 설명 몫 → TLJ-S14b | 같은 파일 docs/rfc/RFC-prompts-and-tool-definitions-outside-ocaml.md 를 두 축이 고친다. RFC 개정은 한 번, Keeper_tool_descriptor·config/tools 는 TLJ, Model_text.t·config/prompts 는 WIM 이 쥔다. |
| FE-S03b(U11 '예'면 FE-S04) | CA-S07 의 턴 식별 칸, SP-S10 PR-3 의 RFC-0437 message 절 | lib/keeper_tool_call_index/keeper_tool_call_index.ml:13 의 schema_version 이 하나다. 칸을 따로 더하면 약 6.1 GB 재구축이 두 번이다. U11 '예'면 FE-S04 의 Fresh state bump 한 번에 싣는다. |
| CA-S11b | SP-S10 PR-2 turn-boundaries cursor | 같은 reader 다(keeper_turn_boundaries.ml:396 예산 상수). 경계 범위 읽기는 한 조각이 쥔다. |
| SP-S10c | CMG-S07 의 typed audience·멘션 결과(commit 때 정함, Passive 포함) | messages 색인 쓰기는 한 자리에서 한다. CMG-S07 은 그 색인을 읽은 자리 뒤부터 읽기만 한다. |
| X01 | CMG-S03·S04·S07, FE-S04, SP-S10c 가 Keeper 식별을 쓴다. CA-S10 은 '자기 큐만' 읽는 데 쓴다 | 여러 조각이 같은 닫힌 합을 원한다. 짓는 방법은 아래 더한 조각 표에 있다. |
| CMG-S09 | X07(보는 사람 역할 범위를 typed scope 로) | 그 범위의 첫 소비자가 CMG-S09 Dashboard Goal 상세다. 역할 타입은 lib/auth/authz_invite_event.mli:26 에 있다. 따로 두면 부르는 곳 없는 층이다. |
| IA-S13 | SP 쪽 Keeper_volume_gc 에 이름 함수가 필요하다는 요청 | lib/keeper/keeper_volume_gc*.ml 이 같은 Subject 이름 함수를 읽게 하는 일을 IA-S13 hard cut 한 번에 넣는다. SP 에는 이 모듈 조각이 없다. |
| 결정 U02(행마다 따로 답한다) | CA D11, SP D6, CMG D5·D6·D8, FE-S04·S06·S15 Fresh state 행, IA-S13·S15 행, SP-S14 Curator WAL 행, WIM-S11·S16 행 | 모두 '운영 데이터를 지우고 설치해도 되나'다. 질문 틀은 하나이고, 답은 행마다 그 조각이 준비될 때 받는다. |
| 결정 U18a(G14) | CA D10 입력 초과 행 격리, CMG-S04 넘침 같은 턴 재투영, CA-S12b 의 반씩 나누기 삭제 근거 | 같은 입력 초과에 규칙이 셋이었다. 기록된 부분 경계에서 같은 턴 안에 나누는 규칙 하나로 한 번 묻는다. |
| 결정 U21 | IA D4, TLJ D1 | 같은 RFC(RFC-keeper-async-fleet-continuity) 수락이다. 두 설계가 한 번에 묻자고 적었다. |
| 결정 U30 | CA D9, TLJ D7, WIM D13, OD D3 | 넷 다 사용자의 앞 결정(10-01, 08-25, 11-11)을 뒤집는다. 다시 묻지 않고 달라진 사실만 한 번 알린다. |

나눈 것도 있다. CA-S11, CA-S12, CA-S15, FE-S03, IA-S10, SP-S10 은 PR 단위로 나눴다. 기준선 PR 은 measure lane 으로, 다른 캠페인을 기다리는 PR 은 뒤 단계로 갔다.
TLJ-S05·S11·S14 와 OD-S03 은 결정 없이 되는 PR 과 결정 뒤 PR 로 나눴다. 나눈 몫은 5절 조각 표의 내용 칸에 `/ PR1` 처럼 적었다.

### 축 사이 빈자리에 더한 조각

| 조각 | 주인 | 내용·근거 | 단계 |
|---|---|---|---|
| X01 | 이 계획의 CMG lane(다계정 캠페인이 리뷰) | Keeper 식별 닫힌 합. lib/runtime/runtime_account_access.mli:169-205 의 request(Keeper_turn{owner; keeper_id} \| Operator_keeper_turn{keeper_name})에서 꺼낸다. 첫 소비자 CMG-S03 과 한 스택이다. | N+1 |
| X02 | POC | vendor 내장 도구 구간에 받은 행을 싣는 provider hook. 지금 공식 클라이언트에 MASC 가 쓴 줄이 닿는 자리는 도구 결과 하나다(lib/keeper/keeper_official_client_host.ml:1740-1749). | N+2 |
| X03 | POC | RFC-AC-041 context_placement 로 받은 행을 provider 마다 그린다. 좌표는 CA 설계 인용이고 이 checkout 에서는 찾지 못했다(확인 필요). | N+2 |
| X04 | OD | TUI loader 가 backlog 를 서버 API 로 읽는다. 지금은 Workspace_backlog 로 파일을 읽는다(bin/masc_tui_loader.ml:224-226). | N |
| X05 | IA | sandbox 가 backlog·board 를 MCP 로 읽는다. 지금 방식의 세부는 수리가 병합된 뒤 싣는다. | N+1 |
| X08 | WIM lane(TUI 화면 문법 캠페인과 key 형식을 맞춤) | 사람 화면 문구 TOML 표. U12 답과 WIM-S13 RFC, TUI 스택 남은 층(E4) 뒤. 새 화면 문구는 이 표의 key 로 쓰자고 그 캠페인에 일반 메시지로 알린다. | N+1 |
| IA-S18 | IA | lane.toml 의 runtime 키를 필수로 읽고 없으면 typed 거절한다. 지금은 없으면 Docker 로 채우고(lib/lane_addon/lane_addon_manifest.ml:321-322), addons/ 의 lane.toml 19개 중 18개가 runtime 을 적지 않는다. 18개에 IA-S08 추천 순서로 적는다. | N+1 |
| IA-S19 | IA | microVM·RemoteSSH 실행 자리에 자격 증명을 넘긴다. 자격 증명은 Keeper 가 사는 동안만 유지되는 holder 가 쥔다. 감사 항목 external-tools-multimodal-01 의 수리다(종류는 9절). WIM-S02 서버 identity 저장소 뒤다. | N+2 |
| OD-S19 | OD | 용어집 docs/spec/00-glossary.md(447,081 B)를 한 줄 색인과 도메인 파일로 나눈다(RFC-glossary-one-line-index-and-domain-files, U17d). | N |
| OD-S20 | OD | 유머 자리 RFC 와 config 문구 표 항목(splash·빈 목록·세계 보고서 첫 줄). 끝 조건은 운영자가 견본을 읽고 고른 기록이다(U17c, X08 뒤). | N+2 |
| OD-S21 | OD | TUI 팔레트에 add-on 입구 하나를 둔다. 첫 항목은 이미 있는 음악 작업대다. 작업대 안에서는 ?·Esc·: 만 화면 문법을 따른다(U31, TLJ-S05a manifest 뒤). | N+1 |

X07 은 첫 소비자 CMG-S09 에 합쳤다. 따로 두지 않는다(합친 것 표).

## 5. 단계별 조각

조각 표는 이렇게 읽는다.

- 종류는 measurement, fix, feature, rfc, removal, research, decision_request 가운데 하나다.
- 주인은 그 조각의 lane 을 맡는 역할이다. build 는 짓는 Keeper 다. measure 는 기준선과 측정을 맡는 Keeper 다. 그 조각을 짓는 Keeper 와 달라야 한다. review 는 RFC 와 결정 요청 글을 쓴다. build-ci 는 CI 개선 스택을 맡는 역할이다(헌법 :320). non-keeper 는 Keeper 가 아닌 코딩 세션이다.
- 여유는 그 스택이 늦어져도 가장 긴 길이 늘지 않는 걸음 수다. 0 이면 그 스택에 가장 긴 길 위의 조각이 있다. 조각 하나의 여유가 0 인 것은 4절의 스물이다. 같은 스택이라 0 으로 보이는 조각은 일곱이다(CA-S10, CMG-S15, POC-S03, POC-S04, POC-S09, X02, X03).
- 기다림과 결정이 `-` 이면 지금 시작할 수 있다. 사건 이름은 4절에 있다.
- 표시 칸의 `칸` 은 그 조각을 읽는 N+7 고정 칸, `창` 은 hard cut 배포 창이다. `hash 승인` 은 운영자가 그 조각의 기준선 hash 를 승인한다는 뜻이다. `유료` 는 돈이 드는 실행이다.

접근 경계 조각 가운데 아직 고치지 않은 것은 종류와 수리 규칙만 적었다. 세부는 수리가 병합될 때까지 이 저장소에 싣지 않는다(9절).
Candle 지급 경로 조각(FE-S11~S15)과 Candle 경제 확장 조각(FE-S16)은 id 와 종류 이름만 적었다. Keeper 가 아닌 코딩 세션이 사용자, 독립 리뷰어와 함께 짓는다. 세부는 이 저장소에 싣지 않는다.

### lane 과 스택

- lane 은 단계 안에서 같은 파일을 고치는 조각 사슬 하나다. lane 하나가 Native Stack 하나다.
- 층 순서는 이른 시작 순서다. 의존이 이미 그 순서를 지킨다.
- 층은 시작할 때 올린다. 결정이나 바깥 기다림이 안 풀린 조각은 층으로 올리지 않는다.
- 스택은 올린 층 전체를 맨 위 PR 로 한 번에 병합한다(헌법 :400). 다음 단계 조각은 main 위 새 스택이다.
- 조각이 하나뿐인 스택은 조각 표의 행이 곧 스택이다. 조각이 둘 이상인 스택만 단계마다 따로 적었다.
- 동시에 여는 lane 수는 잰 승인 공급에서 나온다(13절). OD-S11 이 재기 전에는 N0 lane 만 연다.
- 여는 순서는 여유가 작은 lane 부터다. 같으면 id 순이다.
- 어댑터 넷, turn_driver, unified_prompt, runtime_toml, tool_descriptor 를 고치는 조각은 그 단계의 hotspot 스택 하나에만 있다.
- measure lane 은 운영과 떨어진 자리에서 잰다. SP-S01 은 임시 base path, IA-S14 는 임시 설치와 M=2 끝점, POC-S14 는 toolchain lane, OD-S17 은 PTY 와 가짜 서버, FE-S03a 는 색인 사본이다. 돌고 있는 서버의 route 는 부르지 않는다.

이 계획은 다른 캠페인의 일 여덟을 기다린다. 끝나는 때는 그 캠페인이 정한다. 번호 E7 은 쓰지 않는다.

- E1: #51614 수리 병합(이슈 OPEN, 병합 worker 의 linked issue 경합) → OD-S10, OD-S12
- E2: #51655 수리 병합(이슈 OPEN, Librarian 원본 재검증 GC. #51667 은 병합) → TLJ-S09, CA-S11b
- E3: 영수증 72시간 관찰 창(11-15)과 Delegate 보고 → CA-S12b
- E4: TUI 화면 문법 스택의 남은 층 병합(11-13 16:00 KST 기준 42~50층, 그 뒤 붙는 층 포함. 1~41층은 11-13 14:37 KST 에 main) → OD-S01, OD-S02, OD-S03a, OD-S16, OD-S17, WIM-S11, X08, OD-S21
- E5: RFC-0517 기준 실행(Librarian 캠페인) → U25 를 묻는 때
- E6: exact L2 설치 → TLJ-S11b
- E8: #51278 수리(이슈 OPEN, 교체된 선언의 대기 요청) → TLJ-S02
- E9: #51546 측정 창 끝(11-15) → TLJ-S01
- 병합돼서 기다림에서 뺀 것: #51712(CA-S08 은 main 위), #51691(WIM-S14), #51718·#51720·#51636·#51616(다계정), #51466·#51544(POC-S01), #51422·#51427(SP-S06), #51667, #51657·#51710(U01 전제), #51746(IA-S02 의 `/ws` 몫), #51381·#51606·#51546·#51521·#51600.
- #51256 은 SSE 스택의 번호다. 스택은 닫혔고 86층이 11-11 17:57~11-12 15:48 KST 에 모두 병합됐다(REST stacks 조회). POC-S10 은 기다리지 않는다. 시작 전에 masc_status 로 겹침만 확인한다.
- IA-S10a(#51807)는 11-13 15:59 KST 에 병합됐다. IA-S10b(L2)는 짓는 중이다. 이 계획은 그 결과를 L2 로 받는다.

### N0 — 보안 둘·기준선·결정 요청

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| CA-S11a | 날이 갈수록 커지는 해석 캐시 둘에서 reader 가 밝힌 범위만 읽는다 / PR1 bench(고치기 전 기준선) | measurement | 1 | measure | 13 | - | - | hash 승인 |
| CA-S15a | 연속성 매트릭스 하네스(runtime × 사건) / 틀·scratch base path 캡처·Agent Core 칸. 사건에 '출력 자리'를 더한다 | measurement | 1 | measure | 5 | - | - | - |
| CMG-S01 | Curator 원장 정지 원인과 운영 기준선을 잰다 | measurement | 2 | measure | 1 | - | - | - |
| FE-S03a | tool-call 색인에 칸을 더하고 masc-trace 가 턴의 날짜 파일만 읽는다 / PR0 coverage 표(고치기 전 기준선) | measurement | 1 | measure | 3 | - | - | hash 승인 |
| IA-S02 | 모든 전송이 판정 함수 하나를 지나 typed 호출자가 된다(/ws 업그레이드 몫은 #51746 병합, 남은 층) | fix | 4 | build | 12 | - | - | 사람 리뷰 |
| IA-S10a | /health L1: 단일 사용자 서버가 포트를 커널 잠금으로 알린다(#51807, 11-13 병합) | fix | 1 | build | 0 | - | - | 사람 리뷰 |
| IA-S14 | 측정 도구와 고치기 전 기준선 | measurement | 2 | measure | 11 | - | - | hash 승인, 칸 S2·G |
| OD-S07 | 자동 CI 를 정한 결정 기록이 어디 있는지 운영자에게 묻기(D1) | decision_request | 1 | review | 19 | - | - | - |
| OD-S11 | 승인 공급과 restack 승인 해제를 고정 창에서 재기 | measurement | 1 | measure | 22 | - | - | - |
| POC-S01 | 한도 거절을 사건 순서로 나누는 기준선을 고정하고 센다 | measurement | 3 | measure | 16 | - | - | hash 승인 |
| POC-S05 | 판정 비교 표를 작업 전에 main 에 고정한다 | measurement | 2 | measure | 0 | - | - | hash 승인, 칸 S3 |
| POC-S14 | 재빌드 범위와 release 플래그를 같은 커밋 변형끼리 잰다 | measurement | 3 | measure | 16 | - | - | - |
| POC-S16 | K 가 늘 때 둘째·셋째로 깨지는 자리를 운영에서 잰다 | measurement | 3 | measure | 20 | - | - | 칸 S2·G |
| SP-S01 | 저장 bench, store 를 읽고 쓰는 곳 전수 조사, 고정 기준선 | measurement | 3 | measure | 1 | - | - | hash 승인, 칸 S2·G |
| TLJ-S10 | AI 판정을 재는 고정 평가 묶음을 먼저 만든다 | measurement | 2 | measure | 17 | - | - | hash 승인, 유료 |
| TLJ-S11a | Board attention 숫자 문턱을 지우고 not-relevant 를 System Two 로 보낸다 / PR1 고정 창 측정 | measurement | 1 | measure | 22 | - | - | - |
| IA-S10b | /health L2: CLI 다섯 흐름이 커널 알림으로 서버를 찾고 그 주인에게만 자격을 보낸다 | fix | 1 | build | 0 | D0a | - | 사람 리뷰 |
| IA-S10c | /health L3: 자격 없는 /health 는 공개 probe 만 답한다 | fix | 1 | build | 0 | R-IA-S10b | - | 사람 리뷰 |

조각이 둘 이상인 스택(층 순서대로):

- /health L2·L3: IA-S10b → IA-S10c (PR 2)

### N — 기다림 없는 수리·RFC·첫 hard cut

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| CA-S01 | 공식 턴을 canonical 에 쓰는 RFC 개정(Claude Code 부터) | rfc | 2 | review | 6 | - | - | - |
| CA-S08 | 시간 사실 한 타입과 행마다 기록 시각 | fix | 3 | build | 18 | - | - | - |
| CA-S12a | 입력 순서·ACK RFC 개정과 큐 모델 정정 / 스택 A 주석·문서·TLA 모델 정정 | rfc | 2 | review | 0 | - | - | - |
| CMG-S02 | 외부 발견 연구 문서와 공유 기억 RFC 2단계 개정 | rfc | 2 | review | 1 | - | - | - |
| FE-S01 | Keeper 가 자기 context 점유를 읽고, 매 턴 통계 주입을 지운다 | fix | 2 | build | 6 | - | - | - |
| FE-S02 | 증거 원장 두 큐가 차면 부른 쪽이 순서대로 비우고 쓴다 | fix | 2 | build | 21 | - | - | - |
| FE-S07 | 외부 근거를 연구 문서로 옮긴다 | research | 1 | measure | 6 | - | - | - |
| IA-S06 | RFC-0395 보강: 원격 실행 경계 세 가지 | rfc | 1 | review | 15 | - | - | - |
| IA-S08 | 백엔드 경계 기록 하나에서 네트워크 표·readiness·추천 순서가 나온다 | fix | 2 | build | 18 | - | - | - |
| OD-S04 | 막고 기다리는 Unix 자식 대기를 EINTR 에 끊기지 않는 함수 하나로 | fix | 3 | build | 20 | - | - | - |
| OD-S08 | 결정 없이 고칠 틀린 안내 문장 지우기 | fix | 2 | build | 21 | - | - | - |
| OD-S14 | 부르는 곳 없는 검사기: 빠진 연결인지 보고 지우기 | removal | 1 | build-ci | 22 | - | - | - |
| OD-S18 | roadmap IDE 를 RFC 하나로 구체화하기 | rfc | 1 | review | 22 | - | - | - |
| POC-S02 | 답은 그 요청을 보내기 전에 적힌 provider 사실만 지운다(#50837) | fix | 2 | build | 18 | - | - | - |
| POC-S06 | 종료 사유 RFC 를 HEAD 에 다시 맞추고 PR-0 으로 catch-all 을 걷는다 | fix | 3 | build | 8 | - | - | - |
| POC-S08 | 공식 클라이언트 서명 RFC | rfc | 2 | review | 14 | - | - | - |
| POC-S13 | 거짓 검사 문장과 낡은 문서를 지운다 | removal | 2 | build | 21 | - | - | - |
| SP-S04 | RFC: Tasks·Board 변경 한 건은 줄 하나 | rfc | 1 | review | 18 | - | - | - |
| SP-S05 | 닫힌 읽기 결과 | fix | 3 | build | 20 | - | - | - |
| SP-S06 | RFC-0239 개정: 잠금 종류·자리와 되돌아가지 않게 막는 검사 | rfc | 1 | review | 9 | - | - | - |
| SP-S11 | RFC 개정 둘: BasePath 전체 목록과 계보 | rfc | 2 | review | 3 | - | - | - |
| SP-S13 | 설정과 worktree 가 절대 경로를 적지 않는다 | fix | 1 | build | 17 | - | - | - |
| TLJ-S03 | Agent Core 에 호출자 실행 observer 칸을 두고 실행 관측을 승인 gate 밖으로 옮긴다 | fix | 2 | build | 18 | - | - | - |
| TLJ-S04 | 연구 문서와 판정 RFC(소비 지점 주인, 필수 검사, verifier 판정 계약, 관측 요청량, System One 방향) | rfc | 2 | review | 16 | - | - | - |
| TLJ-S05a | add-on lane 선언을 타입으로 읽는다 / PR1·PR2 manifest 키·dispatch 거절 | feature | 2 | build | 16 | - | - | - |
| TLJ-S13 | Keeper 도구 dispatch 사실을 타입으로: 표 하나, 승인 종류, recall 이름 | fix | 3 | build | 6 | - | - | - |
| TLJ-S14a | 도구 등록 RFC 를 고치고 한 이름 한 계약, descriptor 필수 필드로 간다 / PR2 resolve 가 읽은 파일 | feature | 1 | build | 16 | - | - | - |
| WIM-S01 | 외부 도구·media reader 를 연구 → RFC 로 정하고 문서 drift 를 고친다 | rfc | 3 | review | 6 | - | - | - |
| WIM-S03 | 문서 판정과 한 턴 여러 modality 판정을 선언된 사실 하나씩으로 나눈다 | fix | 2 | build | 7 | - | - | - |
| WIM-S09 | preset restore 가 공용 쓰기 길과 typed 부수 효과를 쓴다 | fix | 2 | build | 7 | - | - | 칸 S4 |
| WIM-S13 | RFC-prompts 개정: render 함수, Model_text.t sink 타입, 옮기기 전 기준선 | rfc | 3 | review | 14 | - | - | - |
| X04 | TUI loader 가 backlog 를 서버 API 로 읽는다 | fix | 2 | build | 19 | - | - | - |
| CMG-S16 | 기억을 내보낼 destination 은 gate 만 만든다 | fix | 2 | build | 6 | - | U23 | - |
| FE-S06 | 턴 spend 를 cost reading 하나로 모은다 | fix | 2 | build | 12 | - | U02:FE-S06 | 창 D-FE-S06 |
| IA-S13 | 실행 자리 이름을 작업공간과 Keeper 를 만들 때 붙인 UID 에서 만든다(hard cut) | fix | 2 | build | 17 | - | U02:IA-S13 | 창 D-IA-S13 |
| IA-S15 | durable Keeper meta 에서 TOML 소유 필드 열한 개를 뺀다(#27357) | fix | 1 | build | 21 | - | U02:IA-S15 | 창 D-IA-S15, 칸 S4 |
| IA-S16 | 쓰는 곳 없는 둘째 읽기 API 와 그 화면 자산을 지운다 | removal | 1 | build | 21 | - | U09 | 사람 리뷰 |
| OD-S01 | TUI 첨부·이미지 캐시의 임시 폴더 다루기를 고친다(종류만 적는다) | fix | 1 | build | 19 | E4 | - | - |
| OD-S03a | 사람 결정을 기다리는 Gate / PR1 Gate_human_required 를 agenda 값에 넣는다 | feature | 1 | build | 19 | E4 | - | - |
| OD-S10 | 승인 수 상수 하나와 닫힌 승인 판정 | fix | 2 | build-ci | 19 | E1 | - | - |
| OD-S13 | RFC status 를 닫힌 값으로, 낡은 도구 RFC 셋 포함 | fix | 2 | build | 20 | - | U17a | - |
| OD-S17 | TUI 루프 멈춤 기준선을 고정 매개변수로 재기 | measurement | 1 | measure | 18 | E4 | - | hash 승인 |
| OD-S19 | 용어집(docs/spec/00-glossary.md)을 한 줄 색인과 도메인 파일로 나눈다 | fix | 2 | build | 20 | - | U17d | - |
| TLJ-S01 | 위임 끝 사실을 settle 과 시작 재투영에서 한 번만 보낸다 | fix | 2 | build | 20 | E9 | - | 칸 F4 |
| TLJ-S02 | cut 원본에 Keeper 가 물러난 원인을 남긴다. 기다림은 외부 사건 원인만 끝낸다 | fix | 2 | build | 18 | E8 | - | - |
| TLJ-S09 | add-on host 를 잰다: 설치 잠금 대기와 판정 처리량 기준선 | measurement | 2 | measure | 20 | E2 | - | hash 승인 |
| TLJ-S15 | Compatibility_meta 를 hard cut 한다 | removal | 2 | build | 20 | - | U26 | - |
| WIM-S16 | 설정 로더가 주인 없는 table·key 를 이름을 대며 setup-required 로 거절한다 | fix | 2 | build | 7 | - | U02:WIM-S16 | 창 D-WIM-S16, 칸 S4 |

조각이 둘 이상인 스택(층 순서대로):

- hotspot tool_descriptor+tool_memory_runtime: FE-S01 → TLJ-S13 → CMG-S16 (PR 7)
- WIM-S03 스택: WIM-S03 → WIM-S09 → WIM-S16 (PR 6)
- OD-S01 스택: OD-S01 → OD-S03a (PR 2)

### N+1 — 닫힌 타입과 기반 층

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| X01 | Keeper 식별 닫힌 합을 Runtime_account_access.request 에서 꺼내 첫 소비자 CMG-S03 과 한 스택으로 | feature | 2 | build | 0 | - | - | 사람 리뷰 |
| CMG-S14 | Keeper 효과 A/B 하네스 | measurement | 2 | measure | 5 | CA-S15a | - | hash 승인, 유료, 칸 T1·T2·T3·G |
| FE-S09 | RFC-skill-usage-rollup 을 고친다 | rfc | 1 | review | 19 | FE-S07 | - | - |
| FE-S12 | Candle 지급 경로 조각 | rfc | 1 | non-keeper | 6 | FE-S07 | - | - |
| CA-S11b | 해석 캐시 범위 읽기 / PR2 경계 로그를 reader 가 밝힌 범위만(SP-S10 PR-2 흡수) | fix | 1 | build | 13 | E2, H-CA-S11a | - | 칸 S2 |
| CA-S12b | 입력 순서·ACK RFC 개정 / 스택 B RFC-0373·admit-all-ready 개정과 R3 절 | rfc | 1 | review | 0 | CA-S12a, E3 | - | - |
| CA-S15b | 연속성 매트릭스 하네스 / 판정 스크립트·hash 승인 | measurement | 1 | measure | 18 | CA-S15a | U04 | hash 승인, 유료, 칸 F5 |
| CMG-S08 | 관계 그래프 RFC | rfc | 1 | review | 7 | CMG-S02 | - | - |
| IA-S18 | add-on lane.toml 의 runtime 을 필수로 읽고 없으면 typed 거절한다. lane.toml 18개에 runtime 을 적는다 | fix | 2 | build | 19 | IA-S08, TLJ-S05a | - | - |
| OD-S09 | D1 뒤 CI 정책을 헌법 한 자리로 | fix | 2 | build-ci | 19 | OD-S07 | U03 | - |
| WIM-S10 | World_bundle RFC: 세계는 묶음 값이고 장비 설정과 사람 Keeper 는 밖이다 | rfc | 2 | review | 7 | SP-S11 | - | - |
| CA-S09 | wake-signal-diet RFC 개정: 직전 기록된 턴 뒤 바뀐 것 층 | rfc | 1 | review | 19 | CA-S08 | - | 칸 F3 |
| CMG-S12 | 기억 사실의 fact_id·빠진 사실의 계보·원천 시각을 쓸 때 정한다 | feature | 4 | build | 8 | CMG-S02 | U25 | 창 D-CMG-S13 |
| FE-S03b | tool-call 색인 칸과 masc-trace / PR1 RFC-0437 개정·PR2 masc-trace 날짜 파일 읽기 | feature | 2 | build | 3 | H-FE-S03a | U11 | - |
| FE-S11 | Candle 지급 경로 조각 | fix | 3 | non-keeper | 13 | FE-S01, TLJ-S13 | - | - |
| IA-S01 | 교차 출처 요청을 서버가 가려 받는다 | fix | 2 | build | 18 | H-IA-S14 | - | 사람 리뷰, 칸 S5 |
| IA-S03 | Keeper 별 egress 정책은 그 Keeper 의 연결만 받는다 | fix | 1 | build | 18 | H-IA-S14 | - | 사람 리뷰 |
| IA-S04 | 끝점을 붙이는 신원과 명령을 실행하는 신원을 나눈다 | fix | 2 | build | 13 | H-IA-S14, IA-S06 | - | 사람 리뷰 |
| OD-S02 | Board 첨부 열기와 예약 양식 전송을 키 경로 밖 job 으로 | fix | 2 | build | 18 | E4, H-OD-S17 | - | - |
| OD-S03b | 사람 결정을 기다리는 Gate / PR2 새 id 를 poll 마다 한 번 알린다 | feature | 1 | build | 18 | OD-S03a | U17b | - |
| OD-S12 | 병합 worker 의 Hold 이유를 닫힌 값으로 내고 sweep 요약에 싣기 | fix | 1 | build-ci | 19 | E1, OD-S10 | - | - |
| OD-S21 | TUI 팔레트에 add-on 입구 하나를 둔다. 첫 항목은 이미 있는 음악 작업대다 | feature | 2 | build | 18 | E4, TLJ-S05a | U31 | - |
| POC-S04 | slot 대기 만료와 Muse 침묵을 lane 공통 생성자로 옮긴다 | fix | 2 | build | 0 | H-POC-S05 | - | - |
| POC-S10 | 공식 lane 의 stop reason 과 스트림 블록 종류를 provider 값의 닫힌 타입으로 | feature | 5 | build | 0 | H-POC-S05 | - | - |
| SP-S12 | 목록 구현과 masc doctor 분실물 칸 | feature | 3 | build | 3 | SP-S11 | U02:SP-S12, U14 | 창 D-SP-S12 |
| TLJ-S05b | add-on lane 선언 / PR3 소비 지점 주인 키 | feature | 1 | build | 6 | TLJ-S04, TLJ-S05a | U10 | - |
| TLJ-S12 | System One codec 을 하나로 모으고 masc_decide 를 Keeper 에게 연다 | feature | 2 | build | 18 | H-TLJ-S10 | U10 | - |
| WIM-S05 | media_type·실패 이유를 닫고 reader 를 선언해 붙인 서비스 도구가 읽게 한다 | feature | 3 | build | 6 | WIM-S01, WIM-S03 | - | 칸 S5·T2 |
| WIM-S08 | 운영자 폴더 선언을 boot 때 한 번 읽고 원격 브라우저에서 loopback provider 를 붙인다 | feature | 2 | build | 18 | WIM-S01 | - | 칸 S5 |
| WIM-S14 | 모델 글 옮기기 1: 도구·기억·영수증 모듈의 sink 를 Model_text.t 로 | feature | 2 | build | 16 | WIM-S13 | - | - |
| CMG-S03 | 원장 writer 하나가 typed batch 를 붙이고 원장을 다시 시작한다 | feature | 4 | build | 0 | CMG-S01, CMG-S02, R-X01 | U02:CMG-S03 | 창 D-CMG-S03 |
| POC-S07 | 종료 사유 PR-1: 공식 클라이언트 실패를 닫힌 타입 하나로 | feature | 4 | build | 8 | H-POC-S05, POC-S06 | U08 | 칸 F1 |
| POC-S12 | masc 내부 오류를 문자열에서 되읽는 live 갈래를 지운다 | fix | 2 | build | 8 | H-POC-S05, POC-S06 | U08 | - |
| POC-S15 | keeper 묶음 하나를 하위 library 로 옮긴다 | feature | 3 | build | 16 | POC-S14 | U27 | - |
| SP-S10a | 덧붙인 만큼만 읽기 / PR-1 dated registry | fix | 1 | build | 3 | H-SP-S01 | - | - |
| SP-S16 | 전원 손실 등급과 도는 서버의 한 시점 사본 | research | 1 | measure | 18 | H-SP-S01 | - | - |
| TLJ-S14b | 도구 등록: 한 이름 한 계약 / PR3·PR4 | feature | 2 | build | 14 | TLJ-S14a, WIM-S13 | U12 | - |
| WIM-S02 | 서버가 쓰는 외부 서비스 자격을 서버 identity 저장소로 옮긴다 | fix | 4 | build | 11 | WIM-S01 | U16e | 사람 리뷰 |
| X08 | 사람 화면 문구 TOML 표(요구 15, 화면 문법 캠페인과 함께) | feature | 2 | build | 14 | E4, WIM-S13 | U12 | - |
| POC-S03 | Keeper step 마다 보내기 전 쉼 Gate 를 둔다(U20 이 '예'일 때) | feature | 2 | build | 0 | H-POC-S01, POC-S02 | U20 | - |
| SP-S07 | 잠금 라이브러리를 만들고 지금 잠금의 구현을 그 위로 옮긴다 | fix | 3 | build | 6 | H-SP-S01, SP-S06 | U07 | - |
| SP-S14 | 계보 id 를 만든다. 한 번만 나가는 효과는 합집합으로 판정한다. 경로·inode 로 비교하던 기록 셋은 계보 id 를 쓴다 | feature | 3 | build | 1 | H-SP-S01, SP-S11 | U02:SP-S14, U14 | 사람 리뷰, 창 D-SP-S14 |
| X05 | sandbox 가 backlog·tasks·board 를 MCP 로 읽는다 | fix | 2 | build | 12 | R-IA-S02 | - | - |

조각이 둘 이상인 스택(층 순서대로):

- POC-S04 스택: POC-S04 → POC-S10 → POC-S03 (PR 9)
- X01 스택: X01 → CMG-S03 (PR 6)
- SP-S12 스택: SP-S12 → SP-S10a (PR 4)
- hotspot runtime_toml: TLJ-S05b → WIM-S05 (PR 4)
- POC-S07 스택: POC-S07 → POC-S12 (PR 6)
- hotspot rfc_prompts+tool_descriptor: TLJ-S14b → X08 (PR 4)
- IA-S01 스택: IA-S01 → IA-S03 (PR 3)
- OD-S02 스택: OD-S02 → OD-S03b (PR 3)

### N+2 — 공식 연속성 시작·판정 lane·원장 한 줄

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| FE-S10 | skill 롤업을 구현한다 | feature | 2 | build | 19 | FE-S09 | - | - |
| CMG-S09 | Entity_ref·Relation·neighbors 와 Dashboard Goal 상세 (X07 흡수: 보는 사람 역할 범위를 typed scope 로) | feature | 3 | build | 7 | CMG-S08 | - | 칸 S5 |
| CA-S13 | Keeper 메시지와 urgency 를 한 번의 큐 형식 hard cut 으로 | feature | 8 | build | 0 | CA-S12b | U02:CA-S13, U18b | 창 D-CA-S13, 칸 F4·F5 |
| CMG-S05 | 충돌 당사자의 Workspace_memory 층에 열린 충돌 행을 싣는다 | feature | 1 | build | 16 | CMG-S01, H-CMG-S14 | - | - |
| FE-S13 | Candle 지급 경로 조각 | fix | 2 | non-keeper | 6 | R-FE-S12 | U24 | - |
| TLJ-S06 | HITL 원본을 add-on 판정 lane 으로 보내고 결과를 검증·commit 한다 | feature | 2 | build | 16 | H-TLJ-S10, TLJ-S02, TLJ-S05b | U10, U23 | - |
| TLJ-S07 | Board attention·verifier 소비 지점이 lane 주인을 받는다 | feature | 3 | build | 16 | H-TLJ-S10, TLJ-S04, TLJ-S05b | U10, U23 | 칸 T3 |
| TLJ-S08 | 패키지 판정 관측 지점과 예시 '말리지 않는 오리' | feature | 3 | build | 16 | H-TLJ-S10, TLJ-S03, TLJ-S04, TLJ-S05b | U10 | - |
| WIM-S15 | 모델 글 옮기기 2: 도구 설명과 다른 언어 본문 | feature | 2 | build | 16 | WIM-S13, WIM-S14 | U12 | - |
| IA-S11 | SSH Execute: TTL 캐시를 빼고 인증 전 동시 수를 끝점 sshd 값에서 얻는다 | fix | 2 | build | 15 | H-IA-S14, R-IA-S04 | - | - |
| TLJ-S16 | 도구 문서·설명을 코드에 맞추고 행동 지시 문장을 지운다 | fix | 3 | build | 14 | TLJ-S14b | U12 | - |
| WIM-S04 | history media 를 handle·읽기 기록으로 보내고 도구 결과가 block 을 잃지 않게 한다 | feature | 3 | build | 6 | WIM-S01, WIM-S03, WIM-S05 | - | - |
| FE-S14 | Candle 지급 경로 조각 | feature | 3 | non-keeper | 13 | R-FE-S11, R-FE-S12, X08 | - | 칸 S5 |
| IA-S05 | 공유 SSH 끝점의 게스트 안 실행은 OS 가 강제하는 사실이 있을 때만 연다 | fix | 2 | build | 14 | R-IA-S04 | U22 | 사람 리뷰 |
| IA-S12 | SSH Execute 를 root 소유 cgroup 에서 돌리고 끊긴 뒤 결과를 덧붙인다 | feature | 3 | build | 13 | R-IA-S04 | U21 | - |
| OD-S20 | 유머 자리 RFC 와 config 문구 표 항목(splash·빈 목록·세계 보고서 첫 줄) | feature | 2 | build | 14 | X08 | U17c | - |
| POC-S09 | 서명을 구현한다: 어댑터 넷, driver 가지 하나, effect 규칙, 다른 호출처 | feature | 7 | build | 0 | H-POC-S05, POC-S07, POC-S08, POC-S10 | - | 칸 S3 |
| POC-S11 | provider 오류도 Candidate_fault 로 판정한다 | feature | 2 | build | 13 | H-POC-S05, POC-S07 | U08 | - |
| SP-S02 | 서버 store 의 key TTL lease 와 LockContention 을 지운다 | fix | 3 | build | 10 | H-SP-S01, SP-S07 | U07 | - |
| SP-S08 | codemod 와, 되돌아가면 컴파일이 실패하는 검사 | fix | 3 | build | 10 | SP-S07 | U07 | - |
| SP-S10c | 덧붙인 만큼만 읽기 / PR-3 messages seq 색인 + typed audience | fix | 1 | build | 5 | CMG-S03, FE-S03b, H-SP-S01 | - | - |
| X02 | vendor 내장 도구 구간에 받은 행을 싣는 provider hook | feature | 2 | build | 0 | POC-S10 | - | - |
| X03 | RFC-AC-041 context_placement 로 받은 행을 provider 마다 그린다 | feature | 2 | build | 0 | POC-S10 | - | - |
| CA-S02 | Claude Code 공식 턴을 canonical atom 으로 저장 | feature | 3 | build | 0 | CA-S01, POC-S10 | U01 | - |
| FE-S04 | tool-call 행이 typed 호출자를 들고 Keeper 가 자기 도구 행을 읽는다 | feature | 2 | build | 0 | CMG-S03, FE-S01, FE-S03b | U02:FE-S04, U11 | 창 D-FE-S04 |
| IA-S07 | microVM 메모리: 호스트 예산과 시간 상수를 쓰지 않는 해제 규칙 | fix | 3 | build | 6 | H-IA-S14, SP-S07 | U19 | - |
| IA-S19 | microVM·RemoteSSH 실행 자리에 자격 증명을 넘긴다. 자격 증명은 Keeper 가 사는 동안만 유지되는 holder 가 쥔다 | feature | 3 | build | 11 | IA-S08, R-IA-S04, R-WIM-S02 | - | 사람 리뷰 |
| SP-S09 | Board 변경을 줄 append 로 | feature | 3 | build | 10 | H-SP-S01, SP-S04, SP-S07, X05 | U13 | - |

조각이 둘 이상인 스택(층 순서대로):

- hotspot adapters+turn_driver: POC-S09 → X02 → X03 → CA-S02 (PR 14)
- SP-S02 스택: SP-S02 → SP-S08 → SP-S09 (PR 9)
- hotspot unified_prompt: CMG-S05 → TLJ-S08 (PR 4)
- TLJ-S06 스택: TLJ-S06 → TLJ-S07 (PR 5)

### N+3 — 읽은 자리 뒤 전달과 남은 hard cut

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| CMG-S10 | Graph As A Tool: keeper_relations 도구 | feature | 2 | build | 7 | CMG-S09, H-CMG-S14 | - | - |
| CMG-S11 | Activity_graph 를 닫힌 타입으로 hard cut 하고 키 짐작을 지운다 | removal | 2 | build | 7 | CMG-S09 | U02:CMG-S11 | 창 D-CMG-S11, 칸 S5 |
| CMG-S13 | 원장 소속을 fact_id 로 건다 | feature | 2 | build | 6 | CMG-S12, D-CMG-S03 | U25 | 창 D-CMG-S13 |
| FE-S15 | Candle 지급 경로 조각 | fix | 3 | non-keeper | 5 | CMG-S03, R-FE-S12, R-FE-S13 | U02:FE-S15, U24 | 창 D-FE-S15 |
| CA-S10 | 남은 입력을 모든 runtime 의 Keeper 에게 typed 투영으로 | feature | 2 | build | 0 | CA-S08, CMG-S03, X02 | - | - |
| CMG-S04 | 턴이 읽은 자리 뒤 변경을 받고, 넘치면 같은 턴 안에서 나눈다 | feature | 4 | build | 0 | CMG-S01, CMG-S03, D-CMG-S03, H-CMG-S14 | U05, U18a | 칸 F4 |
| CMG-S15 | wiki lint 를 commit 때 돌리고 마지막으로 쓴 Keeper 에게 보여 준다 | feature | 4 | build | 0 | CMG-S01, CMG-S02, D-SP-S12, H-CMG-S14 | U23 | - |
| WIM-S06 | connector 첨부가 block 으로 들어온다 | feature | 3 | build | 6 | WIM-S03, WIM-S04 | U16b | - |
| SP-S03 | Tasks backlog 를 snapshot+WAL 로 | feature | 2 | build | 10 | SP-S02, SP-S04, X04, X05 | U13 | - |
| SP-S15 | 멈춘 서버의 export/import | feature | 2 | build | 7 | D-SP-S12, D-SP-S14, SP-S13 | U14 | - |
| WIM-S11 | World_bundle 타입·capture·restore 를 hard cut 으로 넣고 보고서를 운영자에게만 낸다 | feature | 2 | build | 1 | D-SP-S12, E4, WIM-S09, WIM-S10 | U02:WIM-S11, U05, U15 | 창 D-WIM-S11, 칸 S5 |
| FE-S05 | 따로 세던 도구 카운터의 소비자를 reading 으로 옮기고 카운터를 지운다 | removal | 5 | build | 6 | D-FE-S04 | U11 | - |
| CA-S03 | Codex 공식 턴을 canonical atom 으로 저장 | feature | 2 | build | 0 | O-CA-S02 | U01 | - |
| CA-S04 | Muse 공식 턴을 canonical atom 으로 저장 | feature | 2 | build | 0 | O-CA-S02 | U01 | - |
| CA-S05 | Antigravity 공식 턴을 canonical atom 으로 저장 | feature | 2 | build | 0 | O-CA-S02 | U01 | - |
| CA-S07 | 자기 행동 목록을 tool_calls 원장에서 턴 단위로 읽기 | fix | 2 | build | 8 | D-FE-S04 | U04, U06 | 칸 F3 |
| IA-S17 | 자격 없이 권한을 주는 갈래를 지운다(U09 구현) | fix | 2 | build | 6 | H-IA-S14, M-IA-S07, R-IA-S02 | U09, U19 | 사람 리뷰, 칸 S5 |
| OD-S16 | candidate order 이름을 운영자의 두 단계로 바꾸기 | fix | 4 | build | 5 | D-WIM-S16, E4 | - | 칸 S4 |
| FE-S08 | 설정 근거를 다시 내는 사용량 보고서, 측정 명령 sha 고정 | measurement | 2 | measure | 5 | D-FE-S04, D-FE-S06, H-IA-S14 | - | 칸 S2 |

조각이 둘 이상인 스택(층 순서대로):

- CA-S03 스택: CA-S03 → CA-S04 → CA-S05 (PR 6)
- hotspot run_tools_hooks+unified_prompt: CA-S10 → CMG-S04 → CMG-S15 (PR 10)
- CMG-S10 스택: CMG-S10 → CMG-S11 (PR 4)

### N+4 — 이력 원천 하나

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| CMG-S07 | fleet layer 가 message 흐름을 읽은 자리 뒤부터 읽는다 | fix | 2 | build | 0 | CMG-S02, CMG-S03, CMG-S04, SP-S10c | U05 | 칸 F4 |
| WIM-S07 | Video block 과 video 읽기를 한 스택 세 층으로 낸다 | feature | 3 | build | 6 | WIM-S01, WIM-S04, WIM-S05, WIM-S06 | U16a | - |
| CA-S15c | 연속성 매트릭스 하네스 / 공식 칸 | measurement | 1 | measure | 7 | CA-S03, CA-S04, CA-S05, H-CA-S15b | - | 칸 S1·S3·F1·F2·F5·G |
| WIM-S12 | export·import 와 저장소에 실은 세계 | feature | 3 | build | 5 | D-WIM-S11, SP-S15 | U05, U15 | 칸 S5 |
| CA-S06 | 공식 lane 세션 정책을 하나로 줄이고 두 번째 이력 길을 지운다 | removal | 3 | build | 0 | CA-S03, CA-S04, CA-S05 | U01, U02:CA-S06 | 창 D-CA-S06 |
| CMG-S06 | briefing 합성을 지운다 | removal | 2 | build | 5 | CMG-S01, CMG-S04 | U28 | - |

### N+5 — transcript offset 색인

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| CA-S11c | 해석 캐시 범위 읽기 / PR3 transcript offset 색인 | fix | 1 | build | 0 | CA-S11b, CMG-S07 | - | - |

### N+6 — 받은 행은 기록 뒤 ACK

| 조각 | 내용 | 종류 | PR | 주인 | 여유 | 기다림 | 결정 | 표시 |
|---|---|---|---|---|---|---|---|---|
| CA-S14 | 받은 행을 이어지는 입력에 실은 뒤 ACK, 혼자 넘치는 행은 typed 거절로 기록한 뒤 ACK(G14) | feature | 3 | build | 0 | CA-S03, CA-S04, CA-S05, CA-S11c, CA-S12b, O-CA-S13, X03 | U02:CA-S14, U04, U18a, U18b | 창 D-CA-S14, 칸 S1·F2 |

### 보류 (3)

| 조각 | 내용 | 종류 | PR | 보류 이유 |
|---|---|---|---|---|
| FE-S16 | Candle 경제 확장 조각(요구 11 의 Stock) | rfc | 1 | U29(헌법 candle 개정 전) |
| OD-S15 | TUI-KEYS.md 를 커밋하지 않고 렌더 | removal | 2 | U30(11-11 결정 유지) |
| TLJ-S11b | Board attention 숫자 문턱 / PR2 문턱 삭제(CA-S16 흡수) | fix | 1 | U30(10-01 결정 유지, 다시 열면 exact L2 설치 E6 뒤) |

### N+7 — 규모 판정

새 조각은 없다. measure 주인이 앞 단계 하네스를 다시 쓴다: CA-S15c, CMG-S14, IA-S14, SP-S01, POC-S01, POC-S16, TLJ-S10, OD-S11, OD-S17, FE-S08, CA-S11a.

## 6. 규모 표

측정점은 하네스에 넘기는 시험 매개변수다.

- K 는 Keeper 수다. 운영 Keeper TOML 은 11-13 14:4x 에 29개다(파일 수만 셌다).
- Q 는 동시에 찬 큐 종류 수 × 큐마다 깊이다. 종류는 여섯이다: event queue, 메시지, Board attention 후보, schedule(keeper_wake), verifier slot, add-on 구독.
- P 는 먼저 깨우는 출처다. 다섯이다: tick, schedule, Board, maintenance, Goal.
- H 는 서버당 사람 수, M 은 기계 수다.

| 단계 | K | Q | P | H | M | 먼저 깨지는 것 | 하네스 |
|---|---|---|---|---|---|---|---|
| N0 | 1·4·16·29(운영 29) | 지금 값(종류·깊이 기준선) | 다섯 출처 그대로 | 1 | 1·2(IA-S14 임시 끝점) | 단일 사용자 서버의 /health 가 인증 없이 host 경로와 빌드 기록을 답한다(이슈 #51075). 공식 이력이 거절·세션 끊김·lane 전환에서 사라진다(운영 trace 29 중 18). 쉬는 provider scope 를 부른 턴이 7.25일 동안 2,113번 실패했다(2,089번은 provider 가 다시 열리는 시각을 알려 줬다). | SP-S01 bench·전수 조사, POC-S01·S05·S14·S16, IA-S14(턴별 CPU·RSS 포함), CMG-S01, CA-S11a, CA-S15a, TLJ-S10·S11a, FE-S03a, OD-S11 |
| N | 1·4·16·29 | 종류 1·3 × 깊이 1·10 | 그대로 | 1 | 1 | 증거 원장 큐가 차면 authority 행을 버린다(FE-S02). 공식 클라이언트 답이 보내기 전 사실까지 지운다(#50837, POC-S02). | TLJ-S09·OD-S17 기준선, SP-S01 전후 |
| N+1 | 1·4·16·29 | 종류 1·3 × 깊이 1·10·100 | 그대로 | 1·2 | 1 | key lease 가 50회 뒤 포기하고 backlog 를 두 번 쓴다(가설, SP-S01 이 판정한다). tool-call 색인 재구축이 약 6.1 GB 다. | SP-S01 bench 전후, CA-S15b 판정 hash, CMG-S14 A/B, FE-S03b 재구축 시간 |
| N+2 | 4·16·29 | 종류 3·6 × 깊이 1·10·100 | Board·Goal | 1·2 | 1·2 | exact lane 이 설치마다 직렬이다(요청당 평균 478초, Keeper 25명 대기). microVM 게스트 23·상한 178 GiB 에서 swap 96~97%(문서 측정). | TLJ-S10 고정 묶음, IA-S14(M-IA-S07, 임시 설치), CA-S15b Claude Code 칸, SP-S01 |
| N+3 | 29 | 종류 6 × 깊이 10·100 | 다섯 출처 | 1·2·4 | 1·2 | broadcast 한 건이 transcript 를 K 번 쓰고 공유 기억 log 를 통째로 읽는다. | CMG-S14 A/B, CA-S15b, IA-S14, FE-S08 보고서 |
| N+4 | 29·64(65일 성장 모의) | 종류 1·6 × 깊이 100 | tick·schedule | 1 | 1 | 경계 해석 캐시 128 MiB 가 K=29 에서 약 65일 뒤 넘는다(keeper_turn_boundaries.ml:396). | CA-S11a bench(반복 수 고정), CA-S15c 공식 칸 |
| N+5 | 1·29·64 | 종류 1 × 깊이 1·10·100 | tick | 1 | 1 | 받은 행을 external_message_id 로 찾는 색인이 없어 transcript 를 훑는다(keeper_chat_store.mli:635 load_captured_result). | CA-S11a bench, CA-S15a~S15c 매트릭스 |
| N+6 | 64 | 종류 1·3·6 × 깊이 1·10·100(받은 행 바이트) | 다섯 출처 모두 | 1 | 1 | Keeper 메시지가 사람 채팅 줄을 채운다(자율 턴을 끊은 채팅 215 중 207 이 Keeper 메시지, #51221 본문). | CA-S15a~S15c 매트릭스, wire capture 전후 |
| N+7 | 1·4·16·29·64 | 종류 1·3·6 × 깊이 1·10·100(첨부 1·10·100 은 깊이 칸) | tick 300 s·schedule·Board·maintenance·Goal | 1·2·4 | 1·2 | K=64 에서 2 GiB·60 GiB 예산이면 30 동시·34 대기. SSH semaphore 8·MaxStartups. 운영자 Ask 가 주 100~190. | 로드맵 G1(18+3+12), G2(18), G3(30), G4(48 뒤 108), G5(5), 고정 칸 열넷, CA-S15c, CMG-S14, IA-S14 |

## 7. 사용자 결정

- 결정 행은 그 행이 여는 조각이 준비될 때 묻는다. 아래 순서는 첫 행을 묻는 때의 순서다(묻는 단계 → 이른 시작 → id).
- 행이 여럿인 결정은 행마다 따로 답한다. U02 행의 배포 창 이름은 `D-<조각>` 이다. 묻는 때는 그 조각의 기다림(5절)이 풀린 때다.
- '아니오'면 그 조각과 뒤따르는 조각이 이 계획에서 빠진다.
- 결정마다 정석 하나와 그 대가만 적는다(brief §2.4). 괄호 안의 D 번호는 그 축 설계의 결정 번호다.
- U24·U29 는 MASC Ask 로 묻지 않는다. Keeper 가 아닌 코딩 세션이 사용자에게만 묻는다. 두 결정은 종류만 적었다.
- U09·U22 와 U19 의 한 몫은 아직 고치지 않은 접근 경계를 다룬다. 종류와 수리 규칙만 적었다. 세부는 수리가 병합될 때까지 이 저장소에 싣지 않는다.

### 7.1 U02 — hard cut 조각 열넷의 운영 데이터를 그 조각의 배포 창에서 지우고 설치할까, 행마다 따로 답한다 (CA D11, SP D6, CMG D5·D6·D8, FE·IA·WIM 행)

- 정석: 행마다 그 조각이 준비될 때 묻고, 배포 창 하나에 hard cut 하나로 지우고 설치한다. 창은 모두 D0 뒤이고 한 번에 하나다(CMG-S12·S13 은 U25 의 한 창). 보관 단계·수 세기·호환 읽기는 없다. 창 직전에 운영자가 한 번 더 확인한다. CMG D6 행은 CMG-S01 이 옛 schema 를 원인으로 짚을 때만 쓴다.
- 대가: 창마다 서버 정지·지움·설치와 운영자 확인이 한 번씩 든다. 창은 열다섯이다(U02 행 열넷과 U25 의 한 창). 단계마다 한 창으로 묶으면 창은 여섯으로 준다. 그 대신 실패한 hard cut 하나를 따로 되돌릴 수 없다. 창도 그 단계의 가장 늦은 조각을 기다린다. '아니오'인 행은 그 조각과 뒤따르는 조각이 빠진다.
- 헌법: 개정 없음. legacy_residue :492-499, AGENTS 위험한 작업(삭제 확인)

| 행 | 지우는 것 | 묻는 때 | 아니오면 빠짐 |
|---|---|---|---|
| U02:FE-S06 | costs | N0 | FE-S06, FE-S08 |
| U02:IA-S13 | 옛 이름 볼륨 | N0 | IA-S13 |
| U02:IA-S15 | durable Keeper meta 의 TOML 소유 필드 열한 개 | N0 | IA-S15 |
| U02:WIM-S16 | 옛 설정 key | N0 | OD-S16, WIM-S16 |
| U02:SP-S12 | `<base-path>/.masc` 잔재(hardcut 보관 셋 약 2 GB, 최상위 chat-operations.sqlite3 등) | N+1 | CMG-S15, SP-S12, SP-S15, WIM-S11, WIM-S12 |
| U02:CMG-S03 | 공유 기억 원장·판본 | N+1 | CA-S11c, CA-S14, CMG-S03, CMG-S04, CMG-S06, CMG-S07, CMG-S13 |
| U02:SP-S14 | Curator·event queue WAL | N+1 | SP-S14, SP-S15, WIM-S12 |
| U02:CA-S13 | 큐 대기 행·keeper_wake 일정 | N+2 | CA-S13, CA-S14 |
| U02:FE-S04 | tool_calls 약 6.8 GB | N+2 | CA-S07, FE-S04, FE-S05, FE-S08 |
| U02:CMG-S11 | activity-events 532 MB | N+3 | CMG-S11 |
| U02:FE-S15 | Candle 지급 경로 조각의 운영 데이터(세부는 싣지 않는다) | N+3 | FE-S15 |
| U02:WIM-S11 | 옛 preset 형식 | N+3 | WIM-S11, WIM-S12 |
| U02:CA-S06 | 공식 턴 경계 로그·Librarian 위치(select_official 갈래) | N+4 | CA-S06 |
| U02:CA-S14 | Keeper meta 의 checkpoint_source_policy·message_scope_ack_id·transcript watermark | N+6 | CA-S14 |

CMG-S12·S13 의 Memory OS snapshot·원장은 U25 가 묻고 창 D-CMG-S13 하나에서 지운다.

### 7.2 U09 — 자격 없이 권한을 주는 갈래와 쓰는 곳 없는 둘째 읽기 API 를 지울까 (IA D2·D6)

- 정석: 지운다. 모든 요청이 자격을 든다. 쓰는 곳 없는 둘째 읽기 API 도 함께 지운다. 운영 서버를 찔러 보지 않고 고친다. 임시 설치에서 돌린 시험으로 확인한다(사용자 11-12). 갈래 목록과 좌표는 수리가 병합될 때까지 이 저장소에 싣지 않는다.
- 대가: 자격 없이 부르던 로컬 스크립트와 hook 이 거절된다. 인증을 끄는 길이 사라진다. 그 읽기 API 의 화면을 쓰던 사람은 화면을 잃는다. 저장소 밖 소비자는 확인 필요.
- 여는 조각(아니오면 빠짐): IA-S17, IA-S16 · 헌법: Board visibility 주석(:139)을 고친다 · 묻는 때: N0 · 지금

### 7.3 U17 — 운영자 화면·문서 규칙 넷(a RFC status Accepted, b '◆ 조치 N' 배지가 세는 것, c 유머 자리 RFC, d 용어집 분리)을 행마다 받을까 (OD D4·D9·D7·D8)

- 정석: a Accepted 를 더한다(14파일이 이미 쓴다). b 배지는 사람 결정을 기다리는 typed 집합(보류 호출, Ask, 확인할 Goal, Gate_human_required)을 센다. 새 id 는 poll 마다 한 번 알린다. c 유머는 결정·숫자 없는 문구에만 넣는다. RFC 를 먼저 쓰고 운영자가 견본을 골라 정한다(OD-S20). d 용어집을 한 줄 색인과 도메인 파일로 나눈다(OD-S19).
- 대가: status 값이 여섯이 되고 31파일을 맞춘다. K=64 면 poll 마다 배너가 날 수 있다. 두 언어 문구와 RFC 하나가 든다. 용어집 분리 PR 이 열린 스택과 부딪힌다.
- 헌법: 개정 없음. strict_parse_no_default :221-225

| 행 | 내용 | 여는 조각 | 묻는 때 | 아니오면 빠짐 |
|---|---|---|---|---|
| U17a | a RFC status Accepted | OD-S13 | N0 · 지금 | OD-S13 |
| U17b | b '◆ 조치 N' 배지 | OD-S03b | N+1 · OD-S03a 뒤 | OD-S03b |
| U17c | c 유머 자리 RFC | OD-S20 | N+2 · X08 뒤 | OD-S20 |
| U17d | d 용어집 분리 | OD-S19 | N0 · 지금 | OD-S19 |

### 7.4 U23 — 새 판정·내보내기 기능을 어떤 기본값으로 낼까: wiki lint, 기억 후속 판정 내보내기, HITL·verifier 판정 주인 (CMG D3·D4, TLJ D8)

- 정석: 꺼짐·내장으로 낸다. wiki lint 는 [wiki] enabled 뒤 기본 꺼짐이고 CMG-S14 로 잰 뒤 운영자가 켠다. 내보내기는 꺼짐이고 켤 때 Keeper 범위를 같이 적는다. 판정 주인은 내장이고 운영자가 TLJ-S10 일치 표를 보고 바꾼다. 다계정 서버 Addon HITL 주인은 증명 전까지 typed 거절이다.
- 대가: 켜기 전까지 finding 은 부를 때만 보이고 후속 판정은 typed 미해결로 남는다. 운영 증거는 운영자가 바꾼 뒤에 생긴다. A/B 유료 호출이 든다. 기본값 결정이라 '아니오'여도 빠지는 조각은 없다.
- 여는 조각: CMG-S15, CMG-S16, TLJ-S06, TLJ-S07 · 헌법: 개정 없음. 판정 기준은 서버마다 운영자 정책 · 묻는 때: N0 · 지금 · 아니오면 빠짐: 없음(기본값 결정)

### 7.5 U26 — 부르는 곳 없는 Compatibility_meta(#50438)를 지울까 (TLJ D3)

- 정석: 지운다. Compatibility_meta 는 admission 을 건너뛰는 공개 생성자다. 그 생성자로 만든 meta 는 admission 판정을 거치지 않는다. 그래서 지우면 품질이 오른다는 근거가 있다. 운영은 쓰지 않는다.
- 대가: compat 를 쓰는 시험 9파일을 고치거나 지운다. Slack poll lane 삭제는 품질 근거가 '읽는 모듈 0개'뿐이라 이 결정에서 뺐다.
- 여는 조각(아니오면 빠짐): TLJ-S15 · 헌법: 개정 없음. legacy_residue :492-499 · 묻는 때: N0 · 지금

### 7.6 U03 — 결정 기록 없는 자동 CI 일곱(PR 검사 다섯, main push, 야간 test.yml)을 헌법대로 걷어 내고 정책을 헌법 한 자리에 적을까 (OD D1)

- 정석: 걷어 낸다. PR 검사 다섯은 pull_request 를 빼고 dispatch 와 출시 전 목록에 둔다. model-catalog 중복 검사는 출시 전 목록과 main 30분 cron 의 한 줄로 옮긴다. main 은 30분 cron 과 dispatch 만 둔다(:331). test.yml 은 운영자 요청 기록이 있을 때만 그 기록 위치를 적어 남긴다.
- 대가: 실패를 늦게 안다(#44060, 열린 #42280). model-catalog 중복은 서버를 부팅에서 죽인다(.github/workflows/model-catalog-uniqueness.yml:3-7, #48151). 그 검사는 OD 가 잰 창에서 한 번도 돌지 않았다. 그래서 걷어 내도 CI 실행은 줄지 않는다. 지금 cron 은 실행 파일만 지어 이 실패를 못 잡으므로 cron 한 줄이 든다. 문서·workflow 약 15파일을 고친다.
- 여는 조각(아니오면 빠짐): OD-S09 · 헌법: build_and_ci :330-340·merge :394-396 을 정책 한 자리로 고친다(OD-S09) · 묻는 때: N0 · OD-S07 결정 요청이 묻는다

### 7.7 U11 — FE-S03a coverage 표 뒤, bump PR 전에: tool_calls 원장 하나를 authority 로 두고 Keeper 아닌 MCP 호출도 typed 호출자로 적은 뒤 Tool_metrics SQLite·Tool_called 쓰기를 지울까 (FE D1)

- 정석: 넓혀서 하나로 둔다. 처리된 dispatch 마다 원장 행 하나, 호출자는 닫힌 합(Keeper 합 | 비Keeper MCP client)이다. '예'면 CA-S07 턴 칸을 FE-S04 의 Fresh state bump 에 싣고 FE-S03b 의 재구축을 뺀다. bump 는 한 번이다.
- 대가: tool_calls 이력 약 6.8 GB 를 지우고 새로 시작한다. 비Keeper 호출만큼 원장이 는다. #50692 observer 와 #51380 스키마를 버린다. 진행 중 Goal(task-3268)의 방향이 바뀐다. FE-S05 에 PR 다섯이 든다.
- 여는 조각: FE-S04, FE-S05 · 헌법: 개정 없음. RFC-0437 을 고친다 · 묻는 때: N0 · H-FE-S03a 뒤 · 아니오면: FE-S04, FE-S05 가 빠지고 CA-S07·FE-S08 은 FE-S03b 위에 남는다.

### 7.8 U04 — 연속성 하네스가 칸마다 구조 판정으로 pass/fail 을 내고 운영 base path 의 캡처·canonical 을 읽어도 될까 (CA D3·D13)

- 정석: 낸다, 읽는다. 판정은 typed 메시지의 atom digest·tool_use id 로 한다. 기준 파일·판정 스크립트 hash 를 운영자가 먼저 승인하고 다르면 멈춘다. artifacts/ 에는 id·개수·hash 만 남기고 원문은 base path 에 둔다.
- 대가: '턴 입력에 보였다'까지만 판정한다. 'Keeper 가 알고 답했다'는 판정하지 못한다. 시나리오 실행은 유료다. 측정 창 동안 wire capture 를 켜고 max_bytes 를 넓힌다. 원문은 retention_days 동안 남는다.
- 여는 조각: CA-S15b, CA-S07, CA-S14 · 헌법: 개정 없음. evidence :532-536, testing :524-530 · 묻는 때: N+1 · CA-S15a 뒤 · 아니오면 함께 빠짐: CA-S15c

### 7.9 U10 — 판정 RFC(TLJ-S04)를 수락하고 masc_decide(System One)를 Keeper 도구로 열까 (TLJ D5·D2)

- 정석: 수락한다. 소비 지점마다 runtime.toml 이 lane 주인을 고르고 필수 검사는 그 지점에 주인이 있는지로 한다. verifier 판정은 닫힌 타입 하나다. masc_decide 는 codec 을 합친 뒤(TLJ-S12 PR1) Deferrable 로 연다. 판정 lane 의 Priority 줄은 열지 않는다(사용자 10-27 결정, TLJ D6).
- 대가: runtime.toml 에 소비 지점 주인 키가 는다. Keeper 표면에 deferred 도구가 하나 는다. 운영자가 key 있는 destination 을 선언하면 질문 글이 그 vendor 로 나간다.
- 여는 조각(아니오면 빠짐): TLJ-S05b, TLJ-S06, TLJ-S07, TLJ-S08, TLJ-S12 · 헌법: 개정 없음. feature_surface :267-278, gates :503-508 · 묻는 때: N+1 · TLJ-S04·TLJ-S05a 뒤

### 7.10 U14 — BasePath 계보 id·기기 기록·보존 variant·export 묶음을 이식 계약으로 둘까 (SP D4·D5·D9·D11)

- 정석: 둔다. Fresh_bootstrap 이 계보 id 를 만든다. install record·external store 는 그 id 를 키로 쓴다. 한 번만 나가는 효과는 BasePath 사본과 기기 기록의 합집합으로 판정한다. 이식 단위는 export 묶음이고 외부 동기화는 소유 기기에서 내보내는 한 방향 묶음 복제다. Secret·Host_bound 는 묶음에서 빼고 다시 묶을 목록만 적는다.
- 대가: 부팅 때 파일 하나를 더 읽는다. HIGH-RISK authz_install_record.ml 을 바꿔 사람 리뷰가 든다. 기기를 오가려면 export→import 이고 계정마다 다시 로그인한다. 옮긴 뒤 첫 턴은 새 vendor 세션이라 그 세션에만 있던 맥락이 사라진다. 끝난 예약을 7일 동안 보여 주던 동작이 사라진다.
- 여는 조각: SP-S12, SP-S14, SP-S15 · 헌법: 개정 없음. hardcoded_path :479-484, no_wall_clock_death :207-213 · 묻는 때: N+1 · SP-S11 뒤 · 아니오면 함께 빠짐: CMG-S15, WIM-S11, WIM-S12

### 7.11 U25 — 기억 식별자(fact_id)·빠진 사실의 계보·원천 시각을 recall 층 0·1c 결과 전에 넣고 Memory OS snapshot 과 원장을 지우고 설치할까 (CMG D2)

- 정석: 넣는다. RFC-0517 기준 실행 뒤 한 창(D-CMG-S13)에서 지우고 설치한다. 제품은 옛 기록을 읽지 않는다. 근거: recall 이벤트 id 의 15.5% 만 현재 사실이고 32.5% 는 계보 없이 빠졌다.
- 대가: Keeper 40명의 현재 사실 2,338개가 지워져 빈 기억에서 다시 시작한다(:248-249). recall RFC 순서가 바뀌고 RFC-0517 claim id 비교가 끊긴다.
- 여는 조각(아니오면 빠짐): CMG-S12, CMG-S13 · 헌법: 개정 없음. legacy_residue :492-499 · 묻는 때: N+1 · CMG-S02·E5 뒤

### 7.12 U31 — TUI 팔레트에 add-on 입구 하나를 두고 음악 도구를 TUI 핵심 경로 밖 add-on 으로 꽂을까 (OD D6)

- 정석: 둔다. 팔레트에 TLJ-S05a manifest 로 add-on 을 나열하는 입구 하나를 둔다. 첫 항목은 이미 있는 음악 작업대다. 작업대 안에서는 ?·Esc·: 만 화면 문법을 따른다. DAW 시퀀서·MIDI Player·Guitar Tab 은 그 입구로 꽂는 add-on 이다.
- 대가: 핵심 경로 고장 증거 없이 TUI core 를 고치지 않으므로 add-on 은 core 단축키·배치를 바꾸지 못한다. 팔레트 입구 하나와 manifest 항목 하나가 는다. 음악 add-on 자체는 이 계획의 조각이 아니다.
- 여는 조각(아니오면 빠짐): OD-S21 · 헌법: 개정 없음. 요구 7·8. 열린 이슈 지도 결정 5 는 곁가지 버그 이슈를 라벨로 옮긴 결정이지 새 기능 금지가 아니다 · 묻는 때: N+1 · E4·TLJ-S05a 뒤

### 7.13 U08 — 종료 사유 RFC 의 Q1·Q2·Q5 를 정하고 Candidate_fault 가 provider 오류도 판정하게 할까 (POC PD2·PD3)

- 정석: 정한다. Q1 은 RFC 권고 A 를 따른다. Q2 는 PR-2a~2c 가 투영을 맡고, 문자열 되읽기 목록은 POC-S12 가 지운다. Q5 는 §3.8 막힘 표를 받는다. Candidate_fault.of_provider_error 를 catch-all 없이 만들고 숫자 비교 갈래를 지운다. 출처 모르는 오류는 Unattributed 다.
- 대가: PR 11개, 약 150k 토큰(RFC §4 합). receipt·decision log 는 hard cut 이라 옛 줄을 읽지 않는다. agent_core 공개 API 가 하나 는다. 대시보드 receipt 색·라벨이 바뀐다.
- 여는 조각: POC-S07, POC-S11, POC-S12 · 헌법: 개정 없음. closed_sum_over_string :215-219, magic_number :446-454 · 묻는 때: N+1 · H-POC-S05·POC-S06 뒤 · 아니오면 함께 빠짐: POC-S09

### 7.14 U12 — 도구 하나에 이름 하나·계약 하나로 RFC-prompts 를 수락하고, 운영자가 도구 설명을 바꾸게 하며, 화면 글도 요구 15 에 넣을까 (TLJ D4, WIM D10·D9)

- 정석: 그렇게 한다. 필수 필드에 기본값을 두지 않는다. enum·한계값 schema 는 닫힌 타입에서 만든다. TOML 사본과 동기화 시험은 지운다. 도구 설명은 prompt 와 같은 override 층에서 부팅 때만 읽는다. 화면 글은 X08 표 key 로 쓰고 옮길 순서는 TUI 화면 문법 캠페인과 맞춘다.
- 대가: 이름이 바뀌는 외부 MCP 도구는 별칭 없이 끊긴다. by_tool 통계가 그 시점에서 갈린다. 서버마다 도구 schema 가 달라질 수 있고 바꾸면 재시작한다. 화면 글을 옮기는 일이 TUI 캠페인에 생긴다.
- 여는 조각: TLJ-S14b, TLJ-S16, WIM-S15, X08 · 헌법: 개정 없음. closed_sum_over_string :215-219, strict_parse_no_default :221-225 · 묻는 때: N+1 · TLJ-S14a·WIM-S13 뒤 · 아니오면 함께 빠짐: FE-S14, OD-S20

### 7.15 U16 — 외부 도구·미디어 RFC 의 다섯 답(a video 닫힌 block, b Slack files:read, c Web Renderer 정의, d MRTR, e 서버 identity 저장소)을 행마다 받을까 (WIM D1·D2·D3·D11·D12)

- 정석: a video 를 Agent Core 닫힌 block 으로 받는다. b files:read 를 더해 다시 승인한다. c Web Renderer 는 로그인 없는 렌더링 읽기다. d MRTR 을 받아 한 호출 안에서 이어 붙인다. e Keeper 를 키로 쓰는 서버 identity 저장소를 만든다(사람 리뷰). c·d 는 e 와 같이 묻고 답은 WIM RFC 에 적는다.
- 대가: backend serializer 와 match 를 모두 고친다. Slack app 을 다시 승인한다. headless 브라우저가 하나 더 들 수 있다. identity 를 digest v2 로 다시 붙이고 다시 승인하며, 다계정에서 그 키가 바뀌면 한 번 더 붙인다.
- 헌법: 개정 없음. RFC-0392 비목표(:127)를 고친다

| 행 | 내용 | 여는 조각 | 묻는 때 | 아니오면 빠짐 |
|---|---|---|---|---|
| U16a | a video 닫힌 block | WIM-S07 | N+4 · WIM-S01·WIM-S04·WIM-S05·WIM-S06 뒤 | WIM-S07 |
| U16b | b Slack files:read | WIM-S06 | N+3 · WIM-S03·WIM-S04 뒤 | WIM-S06, WIM-S07 |
| U16c | c Web Renderer 정의(e 와 같이 묻는다) | 없음 | N+1 · WIM-S01 뒤 | 없음 |
| U16d | d MRTR(e 와 같이 묻는다) | 없음 | N+1 · WIM-S01 뒤 | 없음 |
| U16e | e 서버 identity 저장소 | WIM-S02 | N+1 · WIM-S01 뒤 | IA-S19, WIM-S02 |

### 7.16 U27 — POC-S14 측정 뒤: RFC-0215 의 keeper 하위 library 이동(Workspace facade 이름 바꾸기 약 40파일)을 시작할까 (POC PD4)

- 정석: 세 창에서 이동이 스택당 type-check 시간이나 Keeper lane 재빌드 시간을 줄일 때만 옮긴다. dune 은 의존 방향만 지킨다. 병합 창을 운영자와 맞춘다.
- 대가: Workspace 를 쓰는 열린 스택이 다시 올라간다. 옮긴 library 의 .mli 를 고치면 기대는 모듈이 모두 다시 컴파일된다. 10파일 넘는 동시 수정이라 확인을 받는다.
- 여는 조각(아니오면 빠짐): POC-S15 · 헌법: 개정 없음. facade :306-308 · 묻는 때: N+1 · POC-S14 뒤

### 7.17 U07 — 잠금 기다림은 잠금을 얻거나 취소될 때만 끝내고(시한·시도 상한 없음) 잠금 종류를 정적 규칙으로 정할까 (SP D1·D10)

- 정석: 그렇게 한다. RFC-0348 을 닫는다. 프로세스 안 기다림은 FIFO 이고 프로세스 죽음은 커널 lease 가 안다. Leaf_mutex 를 쥔 채 멈추는 자리는 두 가지로 정한다. SP-S08 codemod 의 정적 규칙과, 줄 번호 근거를 붙여 손으로 만든 목록이다. health 는 기다리는 잠금과 쥔 쪽을 보여 준다.
- 대가: 쥔 쪽이 안 놓으면 기다리는 fiber 가 계속 선다. RFC-0348 의 60초 바닥과 환경변수, 200회 뒤 오류 갈래가 사라진다. 정적 규칙이 놓친 자리는 domain 교착으로 드러난다.
- 여는 조각: SP-S02, SP-S07, SP-S08 · 헌법: 개정 없음. budget_gate :464-471, gates :503-508 · 묻는 때: N+1 · H-SP-S01·SP-S06 뒤 · 아니오면 함께 빠짐: IA-S07, IA-S17, SP-S03, SP-S09

### 7.18 U20 — POC-S01 결과 뒤: provider 가 밝힌 시각(리셋·Retry-After) 안의 후보를 부르지 않는 보내기 전 쉼 Gate 를 넣을까 (POC PD1)

- 정석: POC-S01 의 피할 수 있는 실패 칸 합이 첫 거절 칸보다 크면 넣고, 아니면 넣지 않는다. 넣을 때도 범위는 밝힌 시각뿐이고 시각 없는 소진은 순서만 바꾼다.
- 대가: gates 순서(success_bar 뒤)를 사용자 예외로 넘는다. #31958 규칙과 RFC-0433 안전선을 밝힌 시각에 한해 바꾼다. 짧은 Retry-After 를 되풀이하는 throttle 에서 Keeper 가 여러 번 쉰다.
- 여는 조각(아니오면 빠짐): POC-S03 · 헌법: gates :504·:507 에 대한 사용자 예외 · 묻는 때: N+1 · H-POC-S01·POC-S02 뒤

### 7.19 U18 — a 입력 초과 규칙 G14 하나를 CMG-S04 와 CA-S14 에 같이 쓸까. b CA-S12b(스택 B) 뒤 Keeper 메시지를 event queue 로 옮기는 큐 형식 hard cut 과 ACK 근거 '기록에 남았다'를 받을까 (CA D4·D5·D10)

- 정석: a 쓴다. 넘치면 같은 턴 안에서 기록된 부분 경계로 나눠 다시 투영한다. 혼자 넘치는 부분은 typed 거절로 기록한 뒤 ACK 한다. 숫자 상한·반씩 나누기·운영자 격리는 없다. b 채팅 줄은 사람의 직접 입력만 앞에 서고 나머지는 도착 순서다. 받은 행은 Schedule_due·Ask_answered 가 가는 user message 로 모두 싣고 그 뒤 ACK 한다.
- 대가: a 혼자 넘치는 행은 모델에 다시 실리지 않는다(본문은 기록에 남는다). 나눈 몫만큼 같은 턴 안 모델 호출이 는다(재지 않음). b 메시지 하나에 답하는 전용 턴이 없어진다. 일정 도구 스키마가 바뀐다. 기록이 받은 행만큼 커지고 prefix cache 적중이 줄 수 있다(재지 않음).
- 헌법: 개정 없음. failure_keeps_evidence :237-240, keeper_attention :165-184

| 행 | 내용 | 여는 조각 | 묻는 때 | 아니오면 빠짐 |
|---|---|---|---|---|
| U18a | a 입력 초과 규칙 G14 | CMG-S04, CA-S14 | N+3 · CMG-S01·CMG-S03·D-CMG-S03·H-CMG-S14 뒤 | CA-S11c, CA-S14, CMG-S04, CMG-S06, CMG-S07 |
| U18b | b 큐 형식 hard cut 과 ACK 근거 | CA-S13, CA-S14 | N+2 · CA-S12b 뒤 | CA-S13, CA-S14 |

### 7.20 U24 — Candle 지급 경로 결정

- Candle 지급 경로 조각 FE-S13·FE-S15 를 여는 결정이다. MASC Ask 로 묻지 않는다. Keeper 가 아닌 코딩 세션이 사용자에게만 묻고, 사용자와 독립 리뷰어가 함께 다룬다.
- 정석과 대가는 이 저장소에 싣지 않는다(13절 Candle 예외).
- 여는 조각: FE-S13, FE-S15 · 헌법: 개정 없음 · 묻는 때: N+2 · R-FE-S12 뒤 · 아니오면 빠짐: FE-S13, FE-S15

### 7.21 U21 — RFC-keeper-async-fleet-continuity 를 고쳐 수락할까 (TLJ D1 = IA D4, 한 번에)

- 정석: §5 의 host yield 문단, 완료 우선순위 문장, A08 을 지운다. §6 을 '위임은 일반 메시지, 응답·대기 의무 없음'으로 맞춘다. 그 뒤 수락한다. 끊겨도 남아야 하는 일은 root 감독자가 쥔다. 첫 작동 경로는 SSH Execute(IA-S12)다.
- 대가: §9 증거 범위(300 Keeper cohort, backend 다섯)가 계약이 된다. 끝점마다 root 감독자를 설치한다. 잰 수요는 60초 넘는 Execute 중 빌드·시험 8.1%(하루 약 1시간)다.
- 여는 조각(아니오면 빠짐): IA-S12 · 헌법: 개정 없음. failure_keeps_evidence :237-240, legacy_residue :492-499 · 묻는 때: N+2 · R-IA-S04 뒤

### 7.22 U22 — SSH 끝점의 신뢰 단위와 Apple container 하한을 무엇으로 볼까 (IA D3·D7)

- 정석: 원격 유닉스 계정 하나가 신뢰 영역 하나다. 게스트 안 실행은 OS 가 강제하는 사실이 있을 때만 연다. 어떤 사실인지는 수리가 병합된 뒤 싣는다. container 하한은 MASC 경로에 닿는 보안 권고를 고친 판 가운데 가장 높은 판이다. 세부는 수리가 병합될 때까지 이 저장소에 싣지 않는다.
- 대가: 계정을 같이 쓰던 Keeper 는 게스트 안 실행을 잃는다. OS 가 강제하지 않는 경계 선언은 hard cut 으로 지운다. 옛 container 판을 쓰던 사람은 판을 올려야 microVM 을 쓴다.
- 여는 조각(아니오면 빠짐): IA-S05 · 헌법: 개정 없음 · 묻는 때: N+2 · R-IA-S04 뒤

### 7.23 U01 — CA-S01 RFC 개정 뒤 공식 클라이언트 턴을 canonical 에 쓰는 일(CA-S02~S06)을 시작할까 (CA D1·D12·D2)

- 정석: 시작한다. 전달 기록은 vendor 에 쓰기 전, atom 은 턴 끝에 쓴다. 사람의 Keeper 도 같다: S1b-3c Purge 목록에 그 대화의 canonical atom·Librarian 입력을 더한다. 묶인 이어가기(Gate·direct·Retry_previous 로 같은 vendor 세션을 잇는 경우)가 없으면 canonical 씨앗으로 새 세션을 연다. 씨앗·마커 수리(#51657·#51710)는 이미 병합됐다. 근거: 운영 trace 29 중 18 이 canonical 이 늦거나 없다.
- 대가: frame 을 atom 으로 바꾸는 설계가 든다. checkpoint 가 커진다. 진행 중 스택을 다시 올린다. S02~S05 전까지 공식 fleet 은 Gate 2(docs/PRODUCTION-READINESS-GATES.md)를 못 넘는다. 새 세션은 resume cache 를 잃고 씨앗을 턴마다 보낸다(중앙값 374,876 토큰, 09-15 값).
- 여는 조각: CA-S02, CA-S03, CA-S04, CA-S05, CA-S06 · 헌법: 개정 없음. failure_conditions :248-249, persist_before_model_call :227-230 · 묻는 때: N+2 · CA-S01·POC-S10 뒤 · 아니오면 함께 빠짐: CA-S14, CA-S15c

### 7.24 U13 — Board·Tasks 원장을 한 줄 쓰기로 바꾸고 헌법 goal_link 의 복구 스냅샷 문장을 고칠까 (SP D2·D3·D7·D8)

- 정석: 바꾼다. Board 는 cursor(device, inode, end_offset) append 와 마지막 줄이 이기는 log 다. Tasks 는 snapshot+WAL 이고 옛 backlog.json 이 빈 WAL 의 snapshot 이라 변환이 없다. goal_link 는 'backlog 를 읽지 못하면 승인하지 않는다'로 고치고 .last-good 사본을 지운다.
- 대가: 같은 길이 제자리 편집은 다음 부팅 전체 읽기까지 못 잡는다(#47224 선택을 뒤집는다, 사용자 선택이었는지 확인 필요). TUI·sandbox 가 API·MCP 로 옮긴다(X04·X05). 부팅 시간이 WAL 길이·원장 크기를 따른다.
- 여는 조각(아니오면 빠짐): SP-S03, SP-S09 · 헌법: goal_link :130-131 을 고친다 · 묻는 때: N+2 · H-SP-S01·SP-S04·SP-S07·X05 뒤

### 7.25 U19 — IA-S14 측정 뒤: success_bar 전에 새 admission 둘(microVM 메모리 예산 IA-S07, 자격 없는 요청 거절 IA-S17)을 넣을까, 어떤 순서로 (IA D8·D5)

- 정석: 하나씩 넣는다. 이미 주장하던 경계를 참으로 만드는 거절(IA-S01~S05)은 지금 넣는다. 새 admission 은 IA-S07 → IA-S17 순서이고 하나마다 임시 설치에서 IA-S14 로 전후를 잰다. 예산은 사용자 config 폴더 한 곳에 두고 턴·Execute 없는 게스트를 상한 큰 것부터 내린다. 시간 상수는 없다.
- 대가: K=64×2 GiB 면 30 동시·34 대기다. 내린 Keeper 는 다음 턴에 다시 부팅한다. 자격 없는 로컬 호출이 거절된다.
- 여는 조각(아니오면 빠짐): IA-S07, IA-S17 · 헌법: gates :504-507 에 대한 사용자 예외(문장 개정은 U05 한 줄) · 묻는 때: N+2 · H-IA-S14·SP-S07 뒤

### 7.26 U05 — 주인이 둘 이상인 서버에서 무엇이 사람 경계를 넘나들까 (IA D1, CMG D7, WIM D6)

- 정석: 여러 사람이 쓰는 설치는 Multi_account 로만 돈다(문장은 IA-S17 병합 뒤 더한다). 공유 기억 변경과 broadcast 는 주인이 같은 Keeper 끼리만 받는다. 세계 restore·import 는 CanAdmin 만 하고 base path 설정과 운영자 Keeper 만 바꾼다. 읽은 자리·audience 는 (주인, 이름)으로 적는다.
- 대가: 한 기기를 같이 쓰려면 OIDC 계정 서버가 든다. 사람 사이 공유 지식이 없다. 같은 base path 에서 세계를 바꾸면 운영자 Keeper 가 앞 세계를 기억한다. 한 사람 서버는 바뀌는 것이 없다.
- 여는 조각: CMG-S04, CMG-S07, WIM-S11, WIM-S12 · 헌법: gates/order :507 옆에 한 문장을 더한다(IA D1) · 묻는 때: N+3 · CMG-S01·CMG-S03·D-CMG-S03·H-CMG-S14 뒤 · 아니오면 함께 빠짐: CA-S11c, CA-S14, CMG-S06

### 7.27 U15 — 세계 묶음에 무엇이 들고 restore 는 바꾸기인가, presets/world-* 18개를 새 형식으로 다시 쓸까 (WIM D5·D7·D8)

- 정석: 세계의 뜻만 든다: Worldview, prompt override, Keeper 선언, wake prompt, Candle 정책 id. Candle 정책 본문은 묶음 밖 한 곳에 둔다. 묶음은 id 만 가리키고, 없는 id 는 typed setup-required 로 거절한다. 장비는 Machine_posture 다. 헌법·기억·원장·비밀·권한 로그는 넣지 않는다. restore 는 U05 범위 안에서 바꾸기다. preset 18개를 다시 쓴다.
- 대가: Keeper key 를 두 무리로 가르는 타입 변경이 든다. 묶음에 없는 운영자 Keeper 는 TOML 이 지워지고 기억은 남는다(확인 화면). 세계를 바꿔도 Candle 정책 본문은 따로 바꾼다. 근거는 Keeper 가 Candle 지급 규칙을 모르게 한다는 결정이다(brief §2.10).
- 여는 조각(아니오면 빠짐): WIM-S11, WIM-S12 · 헌법: 개정 없음. brief §2.10, budget_gate :464-471 · 묻는 때: N+3 · D-SP-S12·E4·WIM-S09·WIM-S10 뒤

### 7.28 U06 — 턴 입력에 자기 행동 목록(direct 턴 포함)과 '직전 기록 턴 뒤 바뀐 것' World State 층을 실을까 (CA D6·D7)

- 정석: 싣는다. 자기 행동은 턴 종류와 무관한 같은 사실이다. 바뀐 것 층의 기준점은 경계 줄의 recorded_at 이다. World State 를 받은 직전 턴 가운데 atom 이 저장된 턴의 것을 쓴다. 없으면 모름이다. 층 제목은 지시 없는 명사다.
- 대가: direct 프롬프트가 턴당 중앙값 1.6 KB×10 만큼 는다. direct 경로에 tool_calls 원장 색인 읽기가 생긴다. World State 층 하나가 는다.
- 여는 조각: CA-S07 · 헌법: 개정 없음. failure_conditions :249 · 묻는 때: N+3 · D-FE-S04 뒤 · 아니오면 함께 빠짐: CA-S09

### 7.29 U28 — CMG-S04 전달이 확인된 뒤 briefing 합성(Curator Synthesis, briefing.json, view=briefing)을 지울까 (CMG D1)

- 정석: 지운다. 지우기 전에 같은 창에서 briefing 이 Stale·Pending 으로 실린 턴 몫, view=briefing 호출 수, 합성 시간 몫을 남긴다. CMG-S04 전달 대조가 빠짐 0 이 아니면 지우지 않는다.
- 대가: Keeper 가 읽던 전체 요약 글이 사라진다. 주제별 정리본은 wiki 쪽에서 다시 정한다. addon 이미지와 TUI World 줄을 같이 바꾼다.
- 여는 조각(아니오면 빠짐): CMG-S06 · 헌법: 개정 없음. evidence :532-536 · 묻는 때: N+4 · CMG-S01·CMG-S04·O-CMG-S04 뒤

### 7.30 U29 — Candle 경제 확장 결정(보류)

- Candle 경제 확장 조각 FE-S16 을 여는 결정이다. 지금은 묻지 않는다. 물을 때는 Keeper 가 아닌 코딩 세션이 사용자에게만 묻는다.
- 헌법 candle 절(:199-203)은 Candle 로 초상화 장신구만 사게 한다. 경제 확장은 그 절을 고친 뒤에만 시작한다. 요구 11 의 Stock 도 여기에 든다.
- 대가: FE-S16 과 Stock 코드는 이 계획 동안 시작하지 않는다. 요구 11 의 Stock 은 설계 글로만 남는다. 그 밖의 세부는 이 저장소에 싣지 않는다.
- 여는 조각: FE-S16 · 헌법: candle :199-203(지금은 개정하지 않는다) · 묻는 때: 보류

### 7.31 U30 — 앞 결정을 뒤집는 세 설계를 어떻게 둘까: Board 확신 문턱 삭제(10-01), history media 재전송 규칙(08-25), TUI-KEYS.md 렌더(11-11) (CA D9·TLJ D7, WIM D13, OD D3)

- 정석: 앞 결정을 유지한다. 달라진 사실 셋만 한 번 알린다. 문턱 위 not-relevant 의 2.3% 가 뒤집혔다(TLJ 감사 창). #48999 가 media 재전송 비용을 쟀다. TUI-KEYS.md 가 7일에 57번 바뀌었다. 사용자가 다시 열면 TLJ-S11b 는 exact L2 설치 뒤, OD-S15 는 바로 넣는다.
- 대가: 확신 문턱이 Keeper 를 깨울지 정하는 숫자 비교로 남는다(magic_number :446-454). media 원본이 뒤 요청마다 다시 간다. 생성물 사본과 일치 시험이 남는다.
- 여는 조각: TLJ-S11b, OD-S15 · 헌법: 개정 없음 · 묻는 때: TLJ-S11a 뒤 알림 한 번


## 8. 요구 지도

덮음 칸은 스크립트가 축 판정과 남은 몫에서 냈다. 남은 몫이 없고 축 하나가 covered 일 때만 covered 다.
남은 몫이 있으면 partial 로 적고 그 몫을 쓴다. covered 는 요구 3·14·19·20·21·23 여섯이다.

| 요구 | 조각 | 덮음 |
|---|---|---|
| 1 | CA-S01, CA-S06, CA-S08, CA-S12a, CA-S12b, CA-S13, CA-S14, SP-S02, SP-S04, SP-S05, SP-S06, SP-S07, SP-S08, CMG-S01, CMG-S03, CMG-S04, CMG-S05, CMG-S06, CMG-S07, CMG-S14, X01 | partial: 시간 사실 하나·큐 순서·잠금 종류·공유 기억 한 번 쓰기. 남은 몫: 지식 자산이 끊임없이 고쳐지는지는 CMG-S14 A/B 와 N+7 T1 칸 전까지 모른다 |
| 2 | POC-S06, POC-S13, OD-S08, OD-S09, OD-S13, OD-S16, OD-S19, TLJ-S16, WIM-S16 | partial: 틀린 문서는 그 파일을 고치는 조각이 지우고 용어집은 OD-S19 가 나눈다. 남은 몫: '늘 최신'은 사본을 없애는 방식만 쓴다(문서 검사기 없음, 헌법 :358). 키 문서 렌더 OD-S15 는 보류(U30) |
| 3 | POC-S02, POC-S03, POC-S04, POC-S05, POC-S06, POC-S07, POC-S08, POC-S09, POC-S10, POC-S11, POC-S12, CA-S02, CA-S03, CA-S04, CA-S05, X02, X03 | covered: provider 사건 하나가 lane 과 무관하게 닫힌 생성자 하나다. CA 가 넘긴 몫은 POC 가 받는다 |
| 4 | POC-S02, POC-S03, POC-S14, POC-S15, POC-S16, SP-S06, SP-S07, SP-S08, X01 | partial: 잠금 경계를 타입으로 밝히고 서명은 module type 으로 둔다. 남은 몫: OxCaml·flambda 는 POC-S14 측정이 이득을 보이기 전에는 들이지 않는다 |
| 5 | IA-S03, IA-S04, IA-S05, IA-S06, IA-S07, IA-S08, IA-S11, IA-S12, IA-S13, IA-S18, IA-S19, X05 | partial: microVM·RemoteSSH 먼저, Docker 기본값은 IA-S18 이 지우고 실행 자리 자격 증명은 IA-S19 가 넘긴다. 남은 몫: 사람 Keeper 도구와 lane 목록은 다계정 캠페인 몫이고, 끊겨도 남는 비동기 작업은 U21 답 뒤다 |
| 6 | IA-S01, IA-S02, IA-S10a, IA-S10b, IA-S10c, IA-S15, IA-S16, IA-S17, CMG-S09 | partial: 외부 노출은 판정 함수 하나와 공개 probe 로 맞춘다. 남은 몫: 권한별 화면은 다계정 캠페인(#51718·#51720 병합)이 낸다 |
| 7 | OD-S01, OD-S02, OD-S03a, OD-S03b, OD-S04, OD-S17, OD-S18, OD-S21, X04 | partial: TUI 핵심 경로를 고치고 취향 도구는 add-on 입구로 꽂는다. 남은 몫: 음악 add-on 자체는 이 계획의 조각이 아니다. U31 '예'면 팔레트 입구 하나만 둔다 |
| 8 | TLJ-S05a, TLJ-S05b, TLJ-S06, TLJ-S07, TLJ-S09, IA-S18 | partial: add-on 선언을 타입으로 읽고 runtime 은 필수 키다. 남은 몫: 설치 단위 도구 이름(TLJ 가 넘긴 요청)은 받는 조각이 없다 |
| 9 | TLJ-S03, TLJ-S04, TLJ-S08, TLJ-S10 | partial: 판정 확장은 턴을 만들거나 막지 못하는 자리에 붙고 기록·다음 턴으로만 간다. 남은 몫: 운영 반영은 TLJ-S10 고정 평가를 본 운영자 결정 뒤다 |
| 10 | TLJ-S11a, TLJ-S12 | partial: masc_decide 를 연다. 남은 몫: Board 숫자 문턱은 10-01 결정을 유지한다(U30) |
| 11 | FE-S11, FE-S12, FE-S13, FE-S14, FE-S15 | partial: Candle 지급 경로 조각은 Keeper 가 아닌 코딩 세션이 짓는다. 남은 몫: Stock 은 헌법 candle 개정 뒤다(U29) |
| 12 | FE-S01, FE-S02, FE-S03a, FE-S03b, FE-S04, FE-S05, FE-S06, FE-S08, FE-S10, SP-S01, SP-S12, POC-S01, POC-S16, IA-S14, CA-S07 | partial: 집계는 투영, 고침은 PR, 같은 sha 끼리 비교. 남은 몫: 턴별 프로세스 CPU·RSS 는 IA-S14 가 재고 FE-S08 이 같은 sha 로 읽는다. 그 전까지 자원 몫은 비어 있다 |
| 13 | WIM-S01, WIM-S02, WIM-S04, WIM-S08, CMG-S15 | partial: Identity·MCP 를 고친다. 남은 몫: Web Renderer 뜻·MRTR 은 U16 답 뒤다. Agent Browser profile 은 11-06 결정 유지, Wiki 색인은 미측정이라 뺐다 |
| 14 | WIM-S09, WIM-S10, WIM-S11, WIM-S12, SP-S11, SP-S12, SP-S14, SP-S15 | covered: 세계는 닫힌 타입 값(Candle 정책은 id 만), 이식은 export 묶음 |
| 15 | WIM-S13, WIM-S14, WIM-S15, WIM-S16, TLJ-S14a, TLJ-S14b, X08 | partial: 모델 글·도구 정의는 코드 밖으로 옮긴다. 남은 몫: 화면 글은 X08 표 key 로 TUI 화면 문법 캠페인과 맞춘다. env 로만 바뀌는 설정은 #50889 몫이다 |
| 16 | OD-S07, OD-S09, OD-S10, OD-S11, OD-S12, OD-S14, POC-S14 | partial: PR·병합마다 CI 를 더하지 않고 동시 lane 수를 잰 승인 공급에서 끌어낸다. 남은 몫: 시간당 실행 수는 U03 답이 바꾼다. 스택 CI 캠페인(#51521·#51600 병합) 몫은 인용만 한다 |
| 17 | WIM-S03, WIM-S04, WIM-S05, WIM-S06, WIM-S07 | partial: 모든 입구가 같은 닫힌 block 이다. 남은 몫: 내보내는 첨부는 미룬다(WIM). 재전송 규칙은 08-25 결정 유지 |
| 18 | OD-S02, OD-S03a, OD-S03b | partial: 키 사건 하나가 의도 0개나 1개로 끝난다. 남은 몫: 키 문법은 TUI 화면 문법 캠페인(스택 #51624) 몫이다. OD-S15 는 11-11 승인 유지로 보류 |
| 19 | SP-S01, SP-S03, SP-S04, SP-S09, SP-S10a, SP-S10c, CA-S11a, CA-S11b, CA-S11c, WIM-S05, WIM-S08, POC-S16, FE-S03b | covered: 변경 한 건의 바이트가 store 크기와 무관하다. 다른 축이 넘긴 File I/O 는 SP 가 받는다 |
| 20 | SP-S11, SP-S12, SP-S13, SP-S14, SP-S15, SP-S16 | covered: 이식은 export 묶음, 외부 동기화는 소유 기기에서 내보내는 한 방향 묶음 복제다(SP D4). 살아 있는 폴더 동기화는 lockf 가 한 커널 안만 막아 지원하지 않는다고 적는다 |
| 21 | CMG-S08, CMG-S09, CMG-S10, CMG-S11, CMG-S12, CMG-S13, CMG-S15, CMG-S16 | covered: 관계는 쓸 때 닫힌 참조로 적고, 식별자는 사실을 만들 때 정한다 |
| 22 | TLJ-S01, TLJ-S02, TLJ-S08, TLJ-S13, TLJ-S14b, TLJ-S15, CMG-S04, CMG-S10, WIM-S04, WIM-S05, WIM-S07, IA-S12 | partial: 위임 끝 사실·도구 사실·기억·관계·media 를 도구로 다룬다. 남은 몫: async fleet 은 U21 답 뒤다. 묶음 위임 도구는 #51546(병합)이 냈다 |
| 23 | CA-S07, CA-S08, CA-S09, CA-S10, CA-S12a, CA-S12b, CA-S13, CA-S14 | covered: 큐 행은 기록 뒤 ACK, 순서는 payload 종류, 넘침은 G14 |
| 24 | SP-S12, CMG-S09, TLJ-S08, WIM-S12, OD-S20 | partial: 결정·숫자 없는 사람 화면 문구 자리. 남은 몫: 문구는 OD-S20 RFC 와 운영자가 고른 견본 뒤에만 넣는다. Keeper 에게 가는 글과 결정·숫자 문구에는 넣지 않는다 |
| 25 | SP-S16, CMG-S02, CMG-S14, FE-S07, FE-S09, POC-S05, POC-S14, IA-S14, TLJ-S04, TLJ-S10, OD-S11, CA-S15a, CA-S15b, CA-S15c | partial: 연구 → RFC → 구현, 측정은 sha 와 artifacts. 축 final 이 선행 사례 조사의 karpathy 항목 아홉을 쓰고 TLJ-S04 가 09·11·14 번을 근거나 기각 사유로 더 적는다. 헌법 prior_art 다섯 대조는 선행 사례 조사 §10 에 있다. 남은 몫: karpathy 항목 06(OpenClaw 한정 꺼림)·13(측정 없는 구상)은 쓰지 않는다. prior_art 다섯 중 Orca 는 원문 대신 릴리스 목록으로만 읽었다 |

### feature_surface 대조

헌법 feature_surface(:264-283)는 전수 검사 대상이다. 항목마다 이 계획의 조각이나 칸을 적었다.
이 계획이 바꾸지 않는 항목에는 기존 시험 자리를 적었다.

| 무리 | 항목 | 조각·칸 또는 기존 시험 |
|---|---|---|
| domain | Task | SP-S03(snapshot+WAL), X04·X05(API·MCP 로 읽기) |
| domain | Board | SP-S04·S09(줄 append), TLJ-S11a(attention 측정) |
| domain | Goal | CMG-S09(Dashboard Goal 상세) |
| domain | Comment | SP-S09(Board 원장 append, comments 65 MB) |
| domain | Candle | FE-S11~S15(Candle 지급 경로 조각, Keeper 가 아닌 코딩 세션), U24 |
| judgement | Fusion | 안 바뀜. 기존 시험 test/test_fusion_metrics.ml |
| judgement | Judge | TLJ-S04·S06·S07 |
| judgement | Judge of Judge | N+7 T3 칸(상호 반론). 기존 시험 test/test_fusion_metrics.ml |
| judgement | Karma | 안 바뀜. 기존 시험 test/test_board_karma_ledger.ml |
| judgement | Cross-Verification(verifier_exact) | TLJ-S07·S10·S11a |
| cognition | Thinking | 안 바뀜. 기존 시험 test/test_keeper_thinking_observation.ml |
| cognition | CoT | 전용 모듈 없음(헌법 :269-270). Thinking 과 같은 시험 자리 test/test_trajectory.ml |
| cognition | MultiTurn | CA-S02~S05, N+7 S1 칸 |
| cognition | MultiModal | WIM-S03~S07 |
| cognition | Reasoning 관측 | TLJ-S03·S08 |
| io | Connector | WIM-S06, N+7 F5 칸(CA-S15a 출력 자리) |
| io | Dashboard | N+7 S5 칸(CMG-S09·S11, FE-S14, IA-S01·S17, WIM-S05·S08·S11·S12 스크린샷) |
| io | Broadcast | CMG-S07, N+7 F4 칸 |
| io | Discord | N+7 F5 칸(Keeper_continuation_channel 대조). 기존 시험 test/test_keeper_chat_discord.ml |
| io | Slack | WIM-S06(files:read, U16b), N+7 F5 칸 |
| io | File System | SP-S01·S10a·S10c, CA-S11a~S11c, 요구 19 |
| autonomy | Autonomous | CA-S10(남은 입력의 typed 투영) |
| autonomy | Proactive | CA-S09, 규모 표 P. 기존 시험 test/test_proactive_refresh_changes.ml |
| autonomy | Schedule Job | CA-S13(keeper_wake 일정) |
| autonomy | Drain Queue | CA-S13·S14, G14 |
| tools | Multitools | TLJ-S13·S14a·S14b |
| tools | AsyncTools | TLJ-S01, IA-S12(U21 뒤) |
| tools | Batch Tools | TLJ-S08 관측 묶음. 묶음 위임 도구는 #51546(병합) |
| tools | Parallel Tool | 안 바뀜. parity B4 시험 자리는 확인 필요 |
| tools | Sandbox | IA-S03~S07·S18·S19, X05 |
| runtime | Multi Runtime | POC-S09·S10, CA-S02~S05, N+7 S3 칸 |
| runtime | Model Free·Provider Free | POC-S07·S11(provider 오류를 닫힌 합으로) |
| runtime | Multi Lane·병렬 레인 | TLJ-S05a·S05b, IA-S18 |
| ops | Observability | FE-S03a~S06·S08 |
| ops | Log | CA-S11a~S11c, SP-S10a |
| ops | Github Credential | 안 바뀜. 기존 시험 test/test_keeper_identity_tools.ml |
| ops | Memory | CMG-S03·S04·S12·S13 |
| ops | Librarian | TLJ-S02, CA-S06, CMG-S12 |

## 9. 접근 경계

접근 경계 두 영역(원격 실행 자리, Dashboard 권한)과 다른 영역의 접근 경계 항목은 세부를 근거 묶음에서 가렸다.
가린 것은 빈틈 26건, 리뷰어 추가 9건, 지울 후보 12건, 결정 11건이다. 수리가 main 에 들어가면 공개한다.
이 절과 조각 표는 종류와 수리 규칙만 적는다. 세부는 그때까지 이 저장소에 싣지 않는다.

규칙은 둘이다.

- 자격 없이 온 요청에는 서버가 누구인지만 답한다. 내부 상태는 자격을 확인한 뒤에 준다.
- 자격을 보내기 전에 상대가 이 workspace 의 서버인지 커널에 묻는다. HTTP 답은 아무나 쓸 수 있어서 신원의 증거가 못 된다.

N0 에서 이 두 규칙으로 두 곳을 고친다.

| 조각 | 설계 | 상태(11-13 16:00 KST) | 내용 |
| --- | --- | --- | --- |
| `/ws` 판정 | IA-S02 의 한 층 | #51746 병합(11-13 00:46 KST) | 업그레이드가 `/mcp` POST 와 같은 검사 둘(다른 사이트 `Origin` 거절, 자격 판정)을 같은 순서로 지난다 |
| `/health` L1 | IA-S10a | #51807 병합(11-13 15:59 KST). 반박 검증에서 나온 수리를 담았다 | 단일 사용자 서버도 계정 서버처럼 포트를 커널 잠금으로 알린다 |
| `/health` L2 | IA-S10b | 구현 중. L1 을 배포한 뒤 연다 | CLI 가 자격을 보내기 전에 상대가 이 workspace 의 서버인지 커널에 묻는다. 커널이 그렇다고 답할 때만 자격을 보낸다 |
| `/health` L3 | IA-S10c | 설계 중. L2 와 함께 또는 L2 뒤에 병합한다 | 자격 없는 `/health` 에는 공개 probe 만 답한다(#51075) |

- #51746 은 설계보다 넓게 고쳤다. 설계는 서버 모드 하나에서만 `/ws` 를 바꾼다고 적었다.
  #51746 은 모드와 무관하게 `/ws` 를 POST `/mcp` 와 같게 맞췄다. 같은 MCP 요청이 전송만 다르기 때문이다.
- 다섯 흐름은 모두 같은 기기 안에서 묻는다. 흐름 이름은 L2 가 병합된 뒤 싣는다.
- 순서를 지켜야 한다. L3 가 먼저 들어가면 CLI 가 돌고 있는 서버를 못 알아본다. 세부는 L2·L3 가 병합된 뒤 싣는다.
- L1 은 알림 파일을 서버 종류마다 하나씩 둔다. 계정 서버의 `<lease>.account-server` 는 이름을 그대로 둔다.
  이름을 바꾸면 새 CLI 가 옛 계정 서버의 알림을 못 읽는다. 그러면 CLI 흐름 하나가 그 서버를 찾지 못한다.
- L2 는 서버 종류를 커널에서 읽는다. lease 주인이 어느 파일에 포트를 알렸는지가 종류다.
  로컬 설정이나 포트의 답으로 정하지 않는다. 재시작 명령은 이미 이렇게 stop 방법을 고른다.
- 알림이 없는 lease 주인에게는 자격을 보내지 않는다. 아직 포트를 묶기 전이거나, 끝나는 중이거나, 127.0.0.1 로 닿지 않는 주소에 묶였거나, L1 전의 서버다.
  명령은 그 pid 를 밝히고 거절한다. 옛 서버를 위한 대체 조회 경로는 두지 않는다.
- 그래서 배포는 두 번이다. L1 을 병합해 서버를 다시 띄운 뒤(D0a) L2·L3 을 연다.
  L1 과 L2 가 함께 들어가면 첫 재시작에서 새 CLI 가 알림 없는 옛 서버를 만난다. 그러면 재시작 명령이 거절된다.
- L3 는 strict 인증으로 뜬 서버에서 #51075 를 닫는다. strict 의 뜻은 `docs/spec/09-server-transport.md` 에 있다.
  strict 가 아닌 서버는 자격 없이 온 같은 기기의 요청을 운영자로 다룬다(같은 문서). 그 서버의 `/health` 답은 U09 의 수리(IA-S17) 뒤에 줄인다.

조각 표에서 종류와 수리 규칙만 적은 조각은 아래와 같다. 수리 규칙은 5절 조각 표의 내용 칸에 있다.

| 조각 | 문제의 종류 |
| --- | --- |
| IA-S01 | 교차 출처 요청을 서버가 가려 받지 않는다 |
| IA-S02 | 같은 요청의 인증 판정이 transport 마다 다르다 |
| IA-S03 | Keeper 별 egress 정책이 다른 Keeper 의 연결까지 받는다 |
| IA-S04 | 끝점을 붙이는 신원과 명령을 실행하는 신원이 나뉘지 않는다 |
| IA-S05 | 공유 SSH 끝점에서 Keeper 사이에 OS 가 강제하는 경계가 없다 |
| IA-S16 | 쓰는 곳 없는 둘째 읽기 API 가 남아 있다 |
| IA-S17 | 자격 없이 권한을 주는 갈래가 있다 |
| IA-S19 | 자격 증명 투영이 소비자를 구분하지 않는다(external-tools-multimodal-01) |

browser 로그인 profile 의 주인(external-tools-multimodal-07)은 이 계획이 고치지 않는다. 11-06 결정을 유지한다.

MASC 를 공개 주소로 내는 설치에는 두 가지를 권한다. 이 글은 특정 설치의 지금 상태를 말하지 않는다.

- OP-01: L3 를 배포할 때까지 MASC 앞단에서 `/health` 를 닫는다.
- OP-02: 닫아 둔 바깥 경로는 이 절의 수리가 모두 배포된 뒤 다시 연다.

## 10. 하지 않는 것

| 항목 | 이유 |
|---|---|
| OxCaml 도입 | POC-S14 측정이 스택당 type-check 나 재빌드 시간 이득을 보이기 전에는 근거가 없다. 이득이 보이면 연구 → RFC 로 연다. |
| Docker 경로를 먼저 다지기 | 사용자 규칙: microVM·RemoteSSH 먼저, Docker 는 마지막이다. IA-S18 은 Docker 기본값을 지우는 일이다. Docker 전용 owned job 은 U21 뒤 다음 층에서 감독자 위로 옮긴다. |
| Stock 과 FE-S16 | 헌법 candle 절(:199-203) 개정이 먼저다(U29). 그 전에는 시작하지 않는다. |
| 음악 도구 자체(DAW 시퀀서·MIDI Player·Guitar Tab 구현) | U31 이 '예'면 팔레트 add-on 입구 하나만 둔다(OD-S21). TUI core 는 고장 증거 없이 고치지 않는다. |
| PR·병합마다 도는 CI 추가 | 2시간에 PR 약 100개, CI 자원 한정(사용자 11-12). PR push 는 CI 를 시작하지 않는다(헌법 :330). model-catalog 검사는 30분 cron 한 줄이라 PR 수와 무관하다. |
| 줄 수 상한 같은 크기 검사 | 사용자 11-06. 큰 파일은 중복을 지워 줄인다. |
| TUI 글자·배치·행 순서 시험, 지운 TUI 시험 되살리기 | 헌법 :358-359 와 사용자 11-06 결정이다. 리뷰가 권해도 되살리지 않는다. |
| hard cut 의 보관 단계·행 수 세기·호환 reader·converter·migration | hard cut 은 지우고 설치다. 공유 기억 기준 스냅샷 소급도 converter 라 만들지 않는다. |
| Keeper 프롬프트 문장·강제 제약·양보 규칙 | 사용자 규칙. 남은 강제 문장은 지운다(TLJ-S16, CMG-S04, async-fleet RFC §5). |
| 누적 turn·time·token·cost Gate, 재생으로 고른 상수, 최근성 대리 지표 | 헌법 budget_gate :464-471·magic_number :446-454, 사용자 11-11. 시간 기준 게스트 내리기(60초·30초·hibernate_after)도 넣지 않는다. |
| 돌고 있는 서버의 route 를 자격 없이 찔러 보기 | 사용자 11-12 선택이다. /health 를 먼저 줄인다. 시험은 임시 설치에서만 돌려 같은 사실을 확인한다. |
| 앞 결정을 뒤집는 셋: TLJ-S11b(CA-S16 흡수), WIM-S04 의 R6 투영, OD-S15 | 10-01·08-25·11-11 결정을 다시 묻지 않는다(U30). 측정 사실만 한 번 알린다. |
| 큐를 byte 로 자르기, tool_calls 원장 큐 backpressure | byte 자르기는 10-06 운영자 규칙과 부딪힌다(provider 가 세고 MASC 는 typed 거절에 반응한다). backpressure 는 #20677 fleet freeze 수리를 되돌린다. |
| 일곱 판정 지점의 공통 타입 | 부르는 곳 없는 층에 타입을 쌓지 않는다(사용자 11-07). 소비 지점마다 주인만 둔다. |
| 살아 있는 BasePath 폴더 동기화(NFS·동기화 서비스) | lockf 는 한 커널 안에서만 막는다. 외부 동기화는 소유 기기에서 내보내는 한 방향 묶음 복제다(U14). |
| 로드맵 G4 의 worker 16·32·64 를 먼저 재기 | 로드맵 순서다. 1·2·4·8 의 48칸을 잰 뒤에 연다. |
| microsandbox 삭제 | 사용자 11-09 결정으로 유지한다. |
| 이미 고쳐진 gap 다시 고치기 | 경계 로그 통째 읽기(#51195), Keeper 수만큼 판정·깨움(10-01·10-08 push 경로), /ws 업그레이드 자격 판정(#51746)은 이미 고쳐졌다. |
| 단계 Gate(앞 단계 전부 병합을 다음 단계 조건으로) | 결정 '아니오' 하나가 뒤 단계를 영영 닫는다. 단계는 checkpoint 로만 둔다. |
| 입력 초과 행의 운영자 격리 상태 | G14 가 typed 거절 기록 뒤 ACK 로 durable truth 를 지킨다. 운영자 손이 드는 새 상태는 필요하지 않다(brief §2.2). |
| Slack poll lane 삭제 | 근거가 '읽는 모듈 0개, 기본 꺼짐'뿐이다. 품질 증거 없는 정리는 내지 않는다(brief §2.9, 사용자 11-10). |
| 다른 캠페인 PR 위에 쌓기, 아래 층 먼저 병합, 수동 retarget | 그 캠페인 병합을 바깥 기다림(E1~E9)으로 두고 main 위에서 연다. 헌법 merge :400·:403. |
| Candle 조각을 Keeper Task·Goal·Board·broadcast·Ask 에 올리기 | Keeper 는 지급 규칙을 알면 안 된다(brief §2.10). Keeper 가 아닌 코딩 세션이 짓는다. |
| target_scenarios 나머지 여섯(:288-:293) | 세 칸(T1~T3)의 채점 틀과 hash 승인이 먼저다. 그 결과를 본 뒤 다음 계획에서 같은 틀로 연다. |
| N+7 fail 칸을 이 계획 안에서 고치기 | 새 조각을 넣지 않는다. fail 칸은 원인과 함께 다음 계획으로 넘긴다. |

## 11. 지울 것

지우는 근거는 품질이다: 틀린 답, 잃는 행, 두 벌 사실, 문자열·숫자 판정, 강제 문장.
부르는 곳이 없다는 것만으로는 지우지 않는다.
접근 경계 행은 종류만 적었다. 세부는 수리가 병합될 때까지 이 저장소에 싣지 않는다.
Candle 지급 경로 행도 종류만 적었다(13절 Candle 예외).

| 무엇 | 왜 | 조각 |
|---|---|---|
| 옛 연속성 하네스 넷과 가리키는 문서 네 곳 | 통과할 수 없는 검사가 release runbook 에 연속성 검증으로 걸려 있다. 새 하네스가 같은 칸을 덮는다. | CA-S15b |
| '없음'을 나타내려고 쓴 max_int 와 meta last_ts·last_visible_ts 의 0.0, [Temporal] 첫 요청의 앞 턴 값 | 없음을 숫자로 눌러 담았다(strict_parse_no_default). 시간 사실 하나와 option 으로 바꾼다. | CA-S08, CA-S14 |
| select_official, Keeper_librarian_official_progress, No_atom_history, 공식 조각 갈래 | 이력 원천이 둘이다. CA-S02~S05 뒤에만 지운다. | CA-S06 |
| typical_calls_per_turn 과 264행 창 | 표본에서 고른 상수가 긴 턴의 Keeper 에게 턴을 덜 보여 준다. 턴 식별자로 자기 행동을 읽는다. | CA-S07 |
| decoded_store_budget_bytes(keeper_turn_boundaries.ml:396)와 transcript 전역 Hashtbl | reader 가 밝힌 범위만 쥐면 예산 상수가 필요 없다. Hashtbl 은 색인만 쥔다. | CA-S11b, CA-S11c |
| 틀린 주석·문서 다섯, KeeperBacklogPreemption.tla, tla-check.sh:145-149 | 지운 장치를 계속 검사하고 틀린 맥락을 다시 만든다. | CA-S12a |
| Normal/Low 번갈이, 호출 자리 urgency, 일정 urgency 인자, msg 의 채팅 작업 제출 경로 | 호출 자리가 고른 등급이 사람의 Ask 답을 Keeper broadcast 뒤에 세운다. | CA-S13 |
| intake 바이트 예산·개수 상한 32 | 숫자로 받을 행을 정한다(magic_number). 준비된 행 전부를 payload 등급 순서로 받는다. 삭제 근거는 CA-S12b RFC 에 적는다. | CA-S13 |
| 입력 초과 때 반씩 나누기 | 넘친 원인과 무관하게 숫자로 줄인다. G14 가 기록된 부분 경계에서 같은 턴 안에 나눈다. | CA-S14, CMG-S04 |
| checkpoint_source_policy 두 갈래, message_scope_ack_id, transcript watermark 층 | 받은 행이 기록에 남으면 지우는 근거는 하나면 된다. | CA-S14 |
| RFC-official-client §5.7 의 토큰 W | Active context-window RFC §1.1(창 크기를 숫자로 정하지 않는다)과 부딪힌다. | CA-S01 |
| key TTL lease 묶음, LockContention, create_backend 의 Memory 갈래 | BasePath lockf lease 가 이미 프로세스를 가른다. 2분 시계·50회 포기·조용한 메모리 store 가 사라진다. | SP-S02 |
| lossy JSON helper 일곱, backend_cleanup_pubsub | 읽기 실패가 빈 값이 되고 쓰기 실패가 로그 한 줄로 끝나는 길이 닫힌다. | SP-S05 |
| Fs_compat.append_jsonl_batch·subdirectory_names, Config_dir_resolver.credentials_dir | 제품이 안 쓰는 진입점이거나 틀린 답을 준다. | SP-S08, SP-S13 |
| Board flush_dirty 와 MASC_BOARD_FLUSH_INTERVAL_SEC | 모든 Board 변경이 줄 append 가 되면 다시 쓸 원장이 없다. | SP-S09 |
| backlog .last-good 쓰기, 복구 읽기, recovery_non_authoritative | snapshot 은 부팅 압축의 atomic rename 으로만 바뀐다. goal_link 개정(U13) 뒤. | SP-S03 |
| briefing 합성(Curator Synthesis, briefing.json, view=briefing, TUI World 줄) | CMG-S04 뒤 기본 턴이 읽지 않는 글을 모델로 다시 만든다. 품질 값 셋을 남기고 U28 뒤. | CMG-S06 |
| keeper.fleet.messages.max·최신 N 자르기, ?max_entries, acknowledged_seq 기본값 0 | 최근성으로 전달을 대신한 숫자다. 읽은 자리 뒤 읽기가 대신한다. | CMG-S04, CMG-S07 |
| 'Shared memory bodies are deferred' 첫 문장과 'Do not enumerate…' 금지문 | 본문이 실리면 틀린 말이고 금지문이다. | CMG-S04 |
| fleet 보낸 이 lowercase·trim 비교, broadcast transcript 복사본 K 개 | 다음 로직을 글자로 정한다. broadcast 한 건을 K 번 쓴다. | CMG-S07 |
| activity 문자열 kind·registry 문자열 filter | 관계와 걸러 읽기를 문자열로 정한다(string_matching). | CMG-S11 |
| destination 을 직접 돌려주는 조회 | 부르는 쪽이 gate 를 거치게 상태만 돌려준다. | CMG-S16 |
| Keeper_terminal_reason.of_wire·접두어 분류, classify_masc_internal_error 문자열 되읽기 | 닫힌 사실을 문자열로 저장했다가 접두어로 다시 가른다(:456-460). | POC-S07, POC-S12 |
| provider_error_to_http_error 와 Runtime_attempt_fsm 의 408·409·429 비교 | typed 오류를 지어낸 HTTP 숫자로 접는다. RateLimit 과 HardQuota 가 한 생성자가 된다. | POC-S11 |
| 공식 attempt_outcome 셋·driver 가지 셋, Fusion client 별 관측, EndTurn 상수 9곳, content_type 문자열 비교 | 같은 수정이 네 벌로 들어가고(30일 91커밋 중 20) provider stop 을 버린다. | POC-S09, POC-S10 |
| Antigravity Spawn_failed 문자열과 Muse 낡은 effect 주석, 답이 기록을 지우는 공개 호출 | MASC 대기 만료가 후보 실패 증거가 되고, 보낸 순번 없는 지움이 #50837 을 다시 만든다. | POC-S04, POC-S02 |
| lib/workspace.ml facade, force_link, release -O3 -unbox-closures | 빌드 도달용 facade 와 링크 순서 등록이다. 플래그는 flambda 없이 아무 일도 안 한다. 측정 뒤. | POC-S15, POC-S14 |
| NORTH-STAR 낡은 수치, 'CI 가 돈다' 문장 셋, parity README 틀린 결론 | 부르는 곳 없는 검사를 돈다고 적고 5.5.2 에서 안 되는 예시를 둔다. | POC-S13 |
| 교차 출처 처리의 한 갈래 | (9절) `/ws` 몫은 #51746 이 이미 고쳤다. | IA-S01 |
| /mcp 자격 판정 셋의 늘 None 인 'a option(이슈 #51752) | 부른 쪽이 버리는 값이라 판정 결과가 타입에 없다. typed 호출자 값이 대신한다. | IA-S02 |
| 자격 없는 /health 의 상세 답 갈래와, CLI 가 HTTP 답으로 서버를 가리던 조회 | 단일 사용자 서버의 /health 가 인증 없이 host 경로와 빌드 기록을 답한다(이슈 #51075). CLI 는 커널 알림으로 서버를 찾고 그 주인에게만 자격을 보낸다. | IA-S10b, IA-S10c |
| lane.toml runtime 이 없을 때의 Docker 기본값(lib/lane_addon/lane_addon_manifest.ml:321-322) | 모르는 값을 기본값으로 채운다(strict_parse_no_default :221-225). add-on 18개가 Docker 로 돈다(brief §2.13 과 반대). | IA-S18 |
| SSH 끝점의 신원·경계 선언 가운데 OS 가 강제하지 않는 것 | (9절) | IA-S04, IA-S05 |
| Execute preflight TTL 캐시, semaphore 기본 8 | 최근성 대리 값과 근거 없는 상수다. 끝점 sshd 값으로 바꾼다. | IA-S11 |
| 옛 이름 철자 호환·keeper_id option, durable meta 열한 필드, agent_core_env | hard cut 에 호환 읽기를 두지 않는다. meta reset 은 한 번에 묶는다. | IA-S13, IA-S15 |
| 쓰는 곳 없는 둘째 읽기 API 와 그 화면 자산 | (9절) U09 뒤. | IA-S16 |
| 자격 없이 권한을 주는 갈래 | U09·U19 뒤. 모든 요청이 자격을 든다. (9절) | IA-S17 |
| stream adapter 안의 Delegate_* 생산 | 스트림이 닫히면 물은 Keeper 가 답을 못 받는다. 끝 행 투영 함수 하나로 둔다. | TLJ-S01 |
| 손으로 쓴 hook introspection 여덟 칸 | 실제 hooks record 와 다르게 보인다. record 에서 끌어낸다. | TLJ-S08 |
| 두 번째 System One codec·상수·env 직접 읽기 | 설정이 두 곳이라 한쪽만 고쳐진다. | TLJ-S12 |
| 두 번째 관리 도구 dispatch 표와 그에 딸린 승인 경로, control 이름 String.equal 다섯 | 같은 도구가 두 길로 갈리고 승인 종류를 문자열로 가른다. | TLJ-S13 |
| Compatibility_meta·Compatibility 모듈 | admission 을 건너뛰는 공개 생성자다. U26 뒤. | TLJ-S15 |
| 이름만 다른 도구 TOML 사본, enum·한계값 TOML 사본·동기화 시험, 도구 설명의 행동 지시 약 20줄 | 한 이름에 계약이 둘이고 강제 문장이다. U12 뒤. | TLJ-S14b, TLJ-S16 |
| telemetry_feedback 주입(keeper_turn.ml:715-747) | 매 턴 통계를 프롬프트에 넣고 창 상수를 쓴다. keeper_context_status 도구가 대신한다. | FE-S01 |
| 증거 원장 큐의 drop 갈래·카운터, Tool_metrics·Tool_unified·Tool_called 쓰기 | authority 행을 버리고 같은 사실의 둘째 숫자를 둔다. | FE-S02, FE-S05 |
| keeper-costs metrics 턴 행 읽기, runtime_unknown·unmetered 상수 | 실패 턴 spend 가 빠진다. #27945 잔재다. | FE-S06 |
| Candle 지급 경로의 지울 것 | (13절 Candle 예외) U24 뒤. | FE-S13, FE-S15 |
| strip_unsupported_modality_*·media_degrade_note·degrade_unavailable·H5 공유 budget·MIME 목록 | 못 받는 block 은 reader 기록이 된다. 공유 budget 은 budget_gate 다. | WIM-S03, WIM-S05 |
| override 부수 효과의 String.equal 분기, preset 복원이 부수 효과를 직접 부르는 자리 | registry typed key match 한 곳에서 부른다. | WIM-S09 |
| 옛 key 인식·ignored_legacy_keys·obsolete_top_level_namespaces, 옛 preset 형식 | 소비자 없는 key 는 이름을 대며 거절한다. preset 은 World_bundle 로 hard cut. | WIM-S16, WIM-S11 |
| 키 경로의 attachment run 동기 받기, TUI 첨부 캐시의 임시 폴더 다루기(종류만 적는다), EINTR 를 처리하지 않는 waitpid | 키 하나가 loop 를 최대 10초 멈추고 좀비를 남긴다. | OD-S02, OD-S01, OD-S04 |
| 'nothing plays or draws them' 문장 셋, hook 우회 지시, issue-taxonomy-core.cjs, local-review 넷 | 틀린 설명을 Keeper 가 턴마다 읽고 없는 자동화를 있다고 읽는다. | OD-S08, OD-S14 |
| REQUIRED_APPROVALS 사본, RFC status 기본값 Draft, 결정 기록 없는 자동 트리거 | 승인 수가 두 자리에 있고, 모르는 값을 조용히 채우고, 헌법 :330·:335 와 다르다. | OD-S10, OD-S13, OD-S09 |
| 옛 이름 Runtime_lane 과 [runtime.lanes] | 한 개념에 이름이 둘이다. | OD-S16 |

## 12. 위험

| 위험 | 줄이는 법 |
|---|---|
| hotspot 파일(keeper_turn_driver, runtime_toml, keeper_unified_prompt, 어댑터 넷, keeper_tool_descriptor)에 2시간 PR 약 100개가 몰려 rebase 가 되풀이된다. | 단계 안 같은 파일 사슬마다 스택 하나다. 다른 스택은 그 파일을 고치지 않는다. 층은 시작할 때 올리고, 결정이 안 풀린 조각은 층으로 올리지 않는다. 스택 맨 아래 PR 만 Core 빌드를 확인한다(:340). |
| hard cut 창 열다섯이 운영 데이터를 지운다. | U02 행마다 그 조각이 준비될 때 묻는다. 창 하나에 hard cut 하나다. 창 직전에 운영자가 한 번 더 확인한다. 보관 단계는 없다(7.1). |
| 유료 측정(CA-S15b 시나리오, CMG-S14 A/B, TLJ-S10)이 돈과 시간을 쓴다. | 운영자 확인 뒤 sha 를 박고 한 번 돈다. 결과는 저장소 루트 `artifacts/<topic>/` 에 둔다. |
| exact lane 이 설치마다 직렬이라(요청당 평균 478초, Keeper 25명 대기) 판정 몫이 늘면 밀린다. | Board 문턱은 유지한다(U30). max_exact_in_flight 는 L2 설치까지 1 이다(사용자 11-12). 판정 주인 전환은 TLJ-S10 표를 본 뒤다. |
| success_bar 전 새 거절 셋(IA-S07, IA-S17, POC-S03)이 헌법 gates 순서를 넘는다. | U19·U20 의 명시 예외로만 넣는다. 하나 넣을 때마다 임시 설치에서 IA-S14·POC-S01 로 전후를 잰다. |
| Keeper 식별 합(X01)이 소비자 없이 병합되거나 소비자마다 다른 타입이 생긴다. | X01 은 이 계획의 CMG lane 이 CMG-S03 과 한 스택으로 짓고 다계정 캠페인은 리뷰만 한다. 다른 소비자는 그 스택이 병합된 main 위에서 시작한다. U02:CMG-S03 이 '아니오'면 X01 은 다음 소비자와 스택을 짓는다. |
| 일하는 Keeper 가 판정 스크립트나 기준 파일을 고쳐 통과시킨다. | 기준선 열한 조각은 measure lane 이 짓는다. 운영자가 hash 를 첫 수리 PR 전에 승인한다. hash 가 다르면 하네스가 멈춘다(13절). |
| 진행 중 캠페인과 같은 파일을 고친다: TUI 화면 문법 스택의 남은 층, #51614·#51655·#51278 수리, 영수증 창 11-15, exact L2. | 그 병합을 바깥 기다림 E1~E9 로 두고 main 위에서 연다. 다른 캠페인 PR 위에 쌓지 않는다. 시작 전 masc_status 로 같은 일을 찾고 masc_broadcast 로 알린다. |
| 운영자 한 명이 결정 행 50개, hash 승인 열하나, 사람 리뷰 PR 41개, 배포 창 열일곱, 유료 실행 셋을 맡는다(지금도 주에 Ask 100~190건을 받는다). | 결정 행은 그 조각이 준비될 때만 묻는다. 단계마다 운영자 할 일 수를 단계표에 적었다. 할 일이 밀려 다음 조각이 모두 서면 멈춤 3 으로 덜어 낸다. |
| tool-call 색인 재구축(약 6.1 GB)이 bump 마다 든다. | U11 을 bump PR 앞에서 묻는다. '예'면 bump 는 한 번이다(7.7). |
| 승인 공급이 모자란다(리뷰어 7이 계정 3을 나눔 #46691). push 가 승인을 푼다. | 동시에 여는 lane 수를 잰 승인 공급에서 정한다(13절). OD-S11 이 재기 전에는 N0 lane 만 연다. |
| Workspace facade 이름 바꾸기(POC-S15, 약 40파일)가 열린 스택을 다시 올리게 한다. | POC-S14 가 type-check 이득을 보일 때만 하고 병합 창을 운영자와 맞춘다. |
| L3 를 배포하기 전에는 자격 없는 /health 의 답이 줄지 않는다(이슈 #51075). | L1 → D0a → L2·L3 → D0 를 다른 모든 배포보다 먼저 한다. MASC 를 공개 주소로 내는 설치는 그때까지 앞단에서 /health 를 닫는다(OP-01). 닫아 둔 바깥 경로를 다시 여는 때는 9절에 있다(OP-02). |
| L2 는 알림 파일 없는 주인을 pid 와 함께 거절한다(되돌림 없음). 순서를 틀리면 CLI 흐름이 서버를 못 찾는다. | L1 병합 → D0a → L2·L3 순서를 지킨다(9절). |
| 공개 저장소 PR 글이 보안 재현 경로를 드러낸다. | PR 본문·커밋은 종류 수준으로 쓰고 재현 경로를 적지 않는다. 인증 코드에는 HIGH-RISK-UNREVIEWED 를 단다. |
| masc Draft PR 은 몇 분 안에 묶음으로 Ready 가 되고 자동 병합이 켜진다. 사람 리뷰가 든 PR 이 사람 판정 없이 병합될 수 있다. | 보안 PR 과 Candle PR 은 열자마자 사용자에게 PR 번호와 자동 병합 상태를 알린다. Draft 로 되돌려 다투지 않는다. |
| Candle 지급 규칙이 Keeper 에게 샌다. | Candle 지급 경로 조각과 U24·U29 는 Keeper Task·Goal·Board·broadcast·Ask 에 올리지 않는다. Keeper 가 아닌 코딩 세션이 사용자, 독립 리뷰어와 함께 짓는다. 이 보고서에는 종류만 적는다. |
| 결정 '아니오' 하나가 뒤따르는 조각을 함께 뺀다(U02:CMG-S03·U05 는 일곱, U07 도 일곱). | 결정 표에 행마다 빠지는 조각을 적었다. 빠진 조각과 좌표를 Task 에 남기고 다음 계획의 입력으로 둔다. |
| IA-S14 가 운영 중인 기기에서 돌면 측정이 운영을 흔든다. | 임시 설치와 M=2 끝점에서 잰다. 돌고 있는 서버의 route 는 부르지 않는다. |

## 13. 실행 방법

- 등록: 단계마다 Goal 하나를 연다. 확인 방법은 그 checkpoint 의 측정 명령으로 적는다. 조각마다 Task 하나를 연다.
  Task 본문에는 축 final 의 끝 조건·작동 경로, lane, 기다림, 결정 행, 읽는 고정 칸 id, 스크린샷이 드는지를 적는다.
  담당은 lane 주인 Keeper 다. Goal 확인은 운영자가 한다.
- Candle 예외: FE-S11~S15 와 U24·U29 는 Keeper Task·Goal·Board·masc_broadcast·Ask 에 올리지 않는다.
  Keeper 가 아닌 코딩 세션이 사용자, 독립 리뷰어와 함께 짓는다. 세부는 이 저장소에 싣지 않는다.
  그 글을 Keeper 가 보는 프롬프트·도구 설명·Board 로 옮기지 않는다. 이 조각들의 스택은 통째로 Keeper 가 아닌 코딩 세션에서 짓는다.
- 결정: 결정 행은 그 조각이 준비될 때 Ask 로 묻는다(U24·U29 는 Keeper 가 아닌 코딩 세션이 묻는다). 답은 RFC·설계 문서와 Task 에 적는다.
  '아니오'면 그 조각과 뒤따르는 조각을 결정 기록 위치와 함께 이 계획에서 뺀다. U30 은 알림 한 번이다.
- 스택: 규칙은 5절에 있다. 수동 retarget 은 하지 않는다(헌법 :403). 다른 캠페인 PR 위에 쌓지 않는다.
  CI 개선 조각(OD-S09·S10·S12·S14)은 자기 스택이다(:320). 부르는 곳 없는 층(X01)은 첫 소비자(CMG-S03)와 한 스택이다.
- 동시 lane 수: L_open = min(⌊A/(2π)⌋, K_build) 다.
  - A 는 이 계획이 쓸 수 있는 서로 다른 리뷰 계정의 시간당 승인 수다.
  - π 는 열린 스택 하나의 시간당 push 수다. 층 수 D 와 restack 수 r 로 D·(r+1) 을 구해 병합까지 걸린 시간으로 나눈다.
  - push 마다 승인이 풀리고, 병합에는 서로 다른 계정의 승인 둘이 든다(:386). 그래서 2π 다.
  - K_build 는 toolchain 이 있는 쉬는 Keeper 수다.
- 배포: D0a(L1 병합 뒤 재시작) → IA-S10b·S10c 한 스택 → D0(재시작) 순서다. D0 전에는 다른 배포나 hard cut 창을 열지 않는다.
  hard cut 창의 순서는 서버 정지 → 지움 → 설치다. 직전에 운영자가 확인한다.
  찔러 보기와 측정은 임시 설치에서만 한다(사용자 11-12). 운영 조치 OP-01·OP-02 는 9절에 있다.
- 측정: 기준선 열한 조각은 measure lane 이 짓는다. SP-S01, CA-S11a, POC-S01·S05, IA-S14, TLJ-S09·S10, OD-S17, FE-S03a, CA-S15b, CMG-S14 다.
  운영자가 hash 를 첫 수리 PR 전에 승인한다. 수리 PR 의 끝 조건이 그 hash 를 인용한다. hash 가 다르면 하네스가 멈춘다.
  원자료는 저장소 루트 `artifacts/<topic>/` 에, 요약은 `docs/evidence` 에 둔다. 유료 실행 셋은 운영자 확인 뒤 한 번 돈다.
- 리뷰: 현재 head 를 짓지 않은 서로 다른 두 계정이 본다(:386). 인증 코드는 HIGH-RISK-UNREVIEWED 를 달고 사람이 본다.
  Candle PR 은 사용자와 독립 리뷰어가 본다.
  보안 PR 과 Candle PR 은 열자마자 사용자에게 PR 번호와 자동 병합 상태를 알린다(12절).
  리뷰 기준은 서버마다 운영자 정책이다. GitHub 절차는 skill 에 있다.
- CI 비용: PR·branch push 는 CI 를 시작하지 않는다(:330). main 은 30분 cron 하나가 실행 파일 넷만 본다(:331).
  다른 주기 CI 는 운영자 요청 없이 더하지 않는다(:335). 스택 맨 아래 PR 만 Core 빌드를 확인한다(:340).
  U03 이 '예'면 model-catalog 중복 검사 한 줄이 cron 에 붙는다. 이 계획은 PR·병합 수에 비례하는 실행을 더하지 않는다.
- 여러 Keeper × 여러 큐 × 깨우는 출처: 깨어난 Keeper 는 자기 lane 의 다음 Task 를 고른다. 우선순위·양보 규칙은 두지 않는다(사용자 10-27).
  Keeper 사이 요청은 일반 큐 메시지이고 답할 의무가 없다.

## 14. 설계 검토에서 고친 것

통합본은 검토 둘을 받았다. 요구 덮음 검토의 지적은 F 번호, 회의적 검토의 지적은 '반박' 번호다.
blocker 셋은 모두 반영했다. major 도 모두 반영했다. 그 가운데 반박 8 만 틀을 바꿔 반영했다(메뉴 대신 정석과 대가). minor 넷은 모두 반영했다.

blocker 셋은 이렇게 고쳤다.

- [F1·반박 2] Candle 지급 경로 조각과 U24·U29 를 Keeper 가 아닌 코딩 세션으로 옮겼다. FE-S11 은 Candle 지급 경로 조각이라 Keeper lane 에서 뗐다.
- [F2·반박 1] 단계 Gate 를 없앴다. 결정 행 52개마다 '아니오'면 빠지는 조각을 계산했다. 묶은 결정 U02·U16·U17·U18 은 행마다 답한다.
- [반박 3] 스택 단위를 lane 에서 '단계 안 같은 파일 사슬'로 바꿨다. CI 개선 조각 넷은 자기 스택이다.

그 밖에 반영한 것은 아래와 같다.

- 판정: N+7 고정 칸 열넷과 feature_surface 표를 넣었다(F3·F4·F5·반박 10). 덮음은 남은 몫이 없을 때만 covered 다(F13). Q 를 '큐 종류 수 × 깊이'로 정의했다(F15).
- 조각: IA-S18, IA-S19, OD-S19, OD-S20, OD-S21 을 더했다(F6·F7·F12·반박 14). X01 은 CMG-S03 과 한 스택이고 X07 은 CMG-S09 에 합쳤다(F9·반박 11).
- 결정: OD D6 을 U31 로 되살렸다(F7). U01 과 U15 를 고쳐 묻는다(F8·F10). U11 은 bump PR 앞에서 묻는다(반박 15). U03 대가에 서버가 부팅에서 죽는 문제(#48151)를 다시 적었다(반박 13).
- 순서: 진행 중 캠페인을 바깥 노드 E1~E9 로 넣었다(F8). IA-S10 을 세 층으로 나누고 OP-01·OP-02 를 넣었다(반박 4). 사건을 노드로 넣고 가장 긴 길을 다시 구했다(반박 5).
- 크기: PR 수 하나로 셌다. N 을 N0 과 N 으로 나눴다. 멈출 조건과 덜어 낼 순서를 적었다(반박 6). 동시 lane 수를 잰 승인 공급에서 끌어낸다(반박 7). 단계마다 운영자 할 일 수를 적었다(반박 8).
- 측정: 기준선 열한 조각을 measure lane 으로 옮겼다(반박 9). FE-S08 이 IA-S14 hash 승인 뒤로 갔다(F11).
- 규칙: 입력 초과 규칙 하나를 G14 로 넣었다. 운영자 격리 상태는 넣지 않는다(반박 12). Slack poll lane 삭제는 뺐다(반박 13).

설계를 마무리하는 동안 바뀐 사실도 반영했다.

- #51746 이 11-13 00:46 KST 에 병합됐다. IA-S02 는 남은 층(PR 4)만 쥔다.
- 이슈 #51752 의 늘 None 인 `'a option` 을 IA-S02 의 typed 호출자 값이 대신한다.
- `/health`(이슈 #51075)를 세 층으로 넣었다. L1 #51807 은 11-13 15:59 KST 에 병합됐다.
- TUI 화면 문법 스택 1~41층이 11-13 14:37 KST 에 main 에 들어갔다. 남은 42~50층(#51766~#51829, 11-13 16:00 KST 기준)을 E4 로 뒀다.
- 좌표는 HEAD `2ed0170118fd` 에서 다시 읽었다. 그 뒤 main 이 `aa1ff9233691`(#51789)로 움직였다.
  이 커밋이 바꾼 파일 여섯은 이 보고서가 인용한 좌표 파일 15개와 겹치지 않는다(git diff 로 확인).

## 근거

- 감사 근거 묶음: [`docs/evidence/2026-11-12-agent-farm-plan/`](../evidence/2026-11-12-agent-farm-plan/). 빈틈 199건, 영역 17개, 리뷰어 추가, 지울 후보, 결정 목록, `counts.py` 가 있다.
- 외부 근거 묶음: [`docs/evidence/research/2026-11-12-agent-farm-prior-art/`](../evidence/research/2026-11-12-agent-farm-prior-art/). 주제별 digest 12개가 있다.
- 선행 사례 조사: [`docs/research/2026-11-12-agent-farm-prior-art.md`](../research/2026-11-12-agent-farm-prior-art.md). 주장 168건의 재확인 결과다.
- 축별 설계, 반박, 통합본, 가린 세부의 원문은 이 저장소에 없다. 이 보고서는 그 파생본이다.
