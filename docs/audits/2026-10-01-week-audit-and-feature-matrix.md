# 주간 감사와 기능 표 (2026-09-29 ~ 10-01)

`origin/main` e1f1429890(10-01 02:23 KST)을 기준으로, 앞선 감사 [주간 변경 감사와 기능 표](2026-09-29-week-audit-and-feature-matrix.md)의 기준 커밋(91c24caa05, 09-29 20:58 KST) 이후 변경을 코드와 라이브 동작으로 확인했다.
그 사이 커밋 163개, 파일 1,251개(+65,353 −40,809줄)가 바뀌었다. 코드 렌즈 세 개(X1·X2·X3)는 09-23 이후 추가된 줄 전체를 봤다.
이 문서는 다음 세션이 같은 조사를 다시 하지 않도록 남기는 기록이다. 발견 하나하나의 위치와 고치는 방향은 [발견 목록](2026-10-01-week-audit-findings.md)에, 작은 것들과 확인 못 한 것은 [작은 것들](2026-10-01-week-audit-small-items.md)에 있다.

## 0. 읽는 법

- 감사는 두 번 돌렸다. 1차는 영역 14개와 09-29 발견 161건의 현재 상태 확인, 2차는 TUI·대시보드, Terminal-Bench, Keeper 프롬프트, Glossary, 배선 점검 3개, 관점별 점검 4개, Multi Lane, 도메인 결합 14개다. 감사관 138명이 일했고, 발견마다 검증 한두 명이 코드 경로를 다시 따라갔다.
- 발견 id 는 영역 접두어를 붙인다. `D` 도메인, `L` 라이브 실측, `W` 배선, `X` 관점별 점검. 영역 이름은 [발견 목록](2026-10-01-week-audit-findings.md)의 절 제목에 있다.
- 심각도: **P0** 기본 흐름이 지금 깨짐, **P1** 실제 결함, **P2** 정리 대상, **P3** 작은 것. 표의 값은 검증 뒤 값이고, 감사관이 붙인 값보다 낮아진 것이 많다.
- "확인"은 검증 두 명 이상이 코드 경로를 직접 따라갔다는 뜻이다. "라이브"는 `<base-path>/.masc` 의 로그나 상태 파일로 확인했다는 뜻이다. 확인하지 못한 것은 "확인 못 함"이라고 적었다.
- 감사관은 로컬 빌드와 서버 재시작을 하지 않았다(저장소 `execution_protocol`). 이 감사에서 연 PR 의 시험 방법은 각 PR 본문에 있다.
- 라이브 서버가 감사 중에 여러 번 다시 떴다(10-01 02:30 e1f1429890, 09:22 fda7ada7f6). 라이브 값은 감사관이 본 시각의 값이다.
- 이 문서는 위 고정 커밋과 당시 관측의 기록이며 현재 main 이나 현재 배포 상태의 검증 결과가 아니다. 기준 이후 main 에 76개 커밋이 더 들어갔다. 표의 "열린 PR" 은 스냅샷 기준이다.

## 1. 한눈에

- 09-29 감사의 P0 2개는 모두 고쳐졌다. P1 38개 중 14개가 닫혔고, P2 120개 중 7개가 닫혔다(3절). 간격이 30시간이라 많이 열려 있는 것은 당연하다.
- 이번에 새로 나온 P0 는 하나이고 이미 복구됐다(리더 Keeper 의 채팅 저장이 막힘, D5-01). P1 은 14개이고, 같은 결함을 둘 이상의 영역이 따로 잡은 것을 합치면 열 가지다(4절). 그중 둘은 고치는 PR 이 머지됐고(continuity 저장 거절, Codex 프레임 신원 불일치), 하나는 운영자가 복구했다(채팅 행).
- 되풀이되는 원인은 여섯 가지다(5절). 지운 것이 디스크에 남아 읽는 쪽을 막는 것, 쓰는 쪽과 읽는 쪽이 따로 바뀌는 것, 이름만 있고 동작이 없는 것, 끝나지 않는 고리, 슬롯 하나, 측정이 없는 것이다.
- Terminal-Bench 는 head 로 돌려 본 기록이 0건이다(마지막 09-22, task 1개). 설정을 렌더해 릴리스 서버에 올려 보는 사전 점검은 이번에 만들어 직접 돌렸다. arm b·e·f·h 가 통과한다(11절).
- 라이브 Keeper 26명은 저장소의 `keeper.md` 가 아니라 운영자 override 를 읽는다(D15-01). 저장소에서 프롬프트를 고쳐도 override 를 정리하기 전에는 Keeper 에게 닿지 않는다.

## 2. 기능 표

상태는 다섯 가지로 적는다. **동작**: 만들고, 저장하고, 읽는 길이 이어져 있고 라이브에서도 돈다. **일부**: 이어져 있지만 알려진 결함이 있다. **깨짐**: 기본 흐름이 실패한다. **미연결**: 코드는 있지만 부르는 곳이 없거나 설계상 아직 없다. **미구현**: 코드가 없다.

| 기능 | 상태 | 핵심 근거 | 관련 발견 |
|---|---|---|---|
| Runtime Failover (후보 걷기) | 일부 | 429·403·402·timeout·5xx·빈 답·context 초과는 모두 다음 후보로 넘어간다. 배정 27명 중 15명(Codex)은 넘어갈 lane 이 없다. 쉼 기록은 프로세스 메모리에만 있어 재시작마다 소진된 계정을 다시 부른다. Codex 프레임 신원 불일치는 #40364 로 원인을 줄였다 | D1-02 D1-03 D1-06 |
| Multi Lane / exact lane | 일부 | exact lane 호출자 6곳 중 Librarian 이 쉬는 슬롯을 pass 마다 전부 다시 부른다. 판정 lane 3개와 verifier 는 슬롯이 하나(glm-5.3-flash)다. 쉼 규칙이 lane 마다 다르다 | D1-01 D1-09 L2-04 D11-02 D11-03 D11-05 D11-07 D11-08 |
| Lane Add-on · Fusion | 일부 | 선언(typed code) → reconcile → 설치 → worker → observation → act(멱등) 길이 이어져 있다. 라이브는 선언 2개 active 0 (이미지 없음, 마지막 관찰 09-17). snapshot_file 소스는 모든 도구 완료에 깬다(잠복). 경계 검사는 preview 에만 있다. | D11-02 D11-03 D11-05 D11-07 D11-08 |
| 계정·모델 선언 (runtime.toml 편집) | 일부 | lane·assignment 참조는 로드 때 typed 로 거절한다. provider 표의 모르는 key 는 조용히 무시한다. 저장 검사는 표 11개 중 4개 안팎만 본다. 라이브 runtime.toml 에 아무도 읽지 않는 key 가 2개 있다 | D1-10 W2-01 W2-08 |
| Schedule | 일부 | 만들기·저장·발화·hold·취소가 이어져 있고 하루 dispatch 1,000건 안팎이 성공한다. TUI·대시보드에서 일정을 고치면 `result_delivery` 가 `none` 이 된다. `resolve_keeper_wake_target` 은 입력을 그대로 돌려주는 stub 이다(#40407) | D5-10 D5-11 D5-02 |
| Drain Queue | 일부 | 큐 깊이는 대부분 0~3이고 turn 당 최대 32개씩 비운다. 큐 상태 파일 무게의 86%가 안 쓰는 옛 행이고 회차 영수증은 지우는 코드가 없다 | D5-03 D5-04 D5-06 |
| 자율 (Autonomous / Proactive) | 일부 | 09-29 turn 3,607개 중 자율이 1,149개이고, 도구를 하나도 안 부른 자율 turn 이 748개(전체 turn 의 21%)다. `autonomous_deferral_debt_cap = 3` 은 5분 주기 시절 숫자인데 지금은 wake 개수를 센다. Keeper 가 CI·PR 상태를 일정으로 기다려 하루 약 210 turn 을 깨운다 | D5-08 D5-12 X2-01 |
| Keeper 한 명의 context 생명주기 | 일부 | Codex resume 이 중앙값 200KB 에서 19KB 로 줄었다. continuity 저장 거절(#40359·#40373 머지)과 Codex 턴 중간 compaction 뒤 신원 불일치(#40364 머지)가 이번에 닫혔다. 조립한 context 의 크기를 맡은 곳은 아직 없다 | D2-01 D2-02 D2-03 D2-05 |
| Runtime 을 넘지 않는 순환 (compaction·shrink) | 일부 | Agent Core 후보는 후보마다 원본에서 다시 잘라 작은 창으로 넘어가도 안전하다. Codex 는 `max-prompt-bytes` 선언이 없어 용량 확인을 건너뛰고, recall 이 고정이라 벤더 compaction 만 완충이다. recall block 과 도구 스키마가 Codex 창의 95%를 채워 세 Keeper 가 2~3턴마다 compaction 한다 | D2-02 D2-04 L1-08 |
| Librarian | 일부 | Memory 회차는 돈다(09-30 커밋 2,738건). #40001 뒤 사실이 안 바뀐 commit 의 revision 상승은 100%에서 0.2%로 줄었다. 실행의 55%는 기억을 안 바꾸는 보조 회차이고 회차마다 facts 전체를 다시 보낸다. 오늘 호출은 시간당 약 620번이고 답은 전부 CLI 슬롯에서 온다 | D3-02 D3-04 L1-01 D1-01 |
| Memory 생산·합성·흡수 | 일부 | 생산은 하루 114~387건 명시 쓰기와 Librarian 새 claim 으로 돈다. 합성(absorb)은 이어져 있으나 09-30 아침부터 0건이다(원인 미확인, 5-6절) | D3-03 |
| Memory 소거·감쇠·강화·반감기 | 일부 | 소거(Librarian dropped 하루 397건, 명시 철회, absorb)는 돈다. 감쇠·강화·반감기 코드는 없고 헌법과 RFC 가 시간 감쇠를 거부한다. facts 한도 512 KiB 는 관측 최대치 바로 위로 정했다 | D3-05 X2-04 |
| World (Workspace) Curator | 깨짐(잠복) | 라이브 lane 이 꺼져 있다(09-28 결정). 켜면 준비 단계가 `cli_slots` 가 하나라도 있으면 lane 전체를 거절한다 | RT-A2 MM-W1 MM-W2 (09-29) |
| Skills 발행·활성화 | 일부 | Keeper 발행 6건이 모두 성공했고 활성화 2,957건의 원장이 정상이다. 라이브 builtin Skill 6개가 릴리스보다 낡았다. 발행 근거가 30일 뒤 사라진다 | D4-04 D4-07 D4-05 |
| Skills 재생성 | 미구현 | 되풀이된 풀이를 알아보는 코드가 없다. 있는 것은 프롬프트 한 문단과 발행 도구다 | D4-03 D4-07 |
| Board | 동작 | 글·댓글 저장과 스냅숏 flush 가 돈다. 수정·고정·닫기·다시 열기·삭제 뒤 목록 캐시가 15초 남던 것은 #40451 이 고친다. 댓글 상한 100 은 근거 없이 정했고 Keeper 댓글 27건을 거절했다 | D12-01 X2-02 |
| Board attention | 일부 | 후보 저장 → Jev → LLM → consumed 가 이어져 있다. 처리 속도가 도착을 못 따라가 09-30 후보의 71%가 pending 이고 처리 중앙값이 12.9시간이다. 요청이 나가지 못한 DNS 실패 1,154개가 입력 문제로 굳었다(#40397). 판정 단위를 신호 하나로 바꾸는 RFC #40450 이 머지됐다 | D6-01 D6-02 D6-05 D6-06 |
| Task | 일부 | claim → 제출 → 판정 → Done 이 돈다(09-30 승인 14, 반려 4). awaiting_verification 35개 중 5개는 이미지 증거를 판정기가 못 읽어 못 끝낸다. GC 는 손으로만 돌고 backlog 에서 먼저 지운 뒤 archive 에 붙이던 순서는 #40427 이 고친다 | D6-09 D6-11 |
| Cross-Verification / Judge | 일부 | 판정 저장·commit 경로는 돈다. 슬롯이 하나라 하루 469번 시도에 판정 18건, 900초 무응답이 330번이다. 운영자 결정(슬롯 추가 또는 capabilities)이 그대로 대기 중이다 | D6-03 D6-08 D1-09 |
| Goal | 일부 | 만들기·수정·검증·확정이 돈다(22개: Executing 5, Verifying 2, Completed 5, Dropped 10). 검증기 슬롯 하나 때문에 Goal 2개가 33~43시간 Verifying 이다. 하드컷 데이터 정리는 09-30 23:26 에 했다. 라이브 Goal 하나의 기한이 읽을 수 없는 형식이다 | D7-01 D7-02 D8-12 |
| HITL (Gate 승인·질문) | 일부 | Gate 는 typed·durable 이고 부팅 때 replay 한다. 라이브가 always_allow 라 Manual·Auto Judge 경로는 라이브에서 돌지 않았다. 질문 답변 route 가 Worker 권한으로 열려 있다 | D7-03 |
| Access Control | 일부 | 상태를 바꾸는 route 는 `CanAdmin` 또는 도구 actor 인증을 거친다. Keeper 경로는 `required_permission` 을 읽지 않아 `masc_gc`·`masc_board_cleanup` 을 권한 없이 부른다(09-20 메시지 3,462개 삭제 1회). 만료 판정이 4곳에 규칙 2개다(#40171 이 다룬다) | W1-01 D7-05 D7-06 |
| Candle 원장 | 일부 | 만들고 읽는 길이 main 에 이어져 있고 이중 지급은 막혀 있다. 라이브는 Off(`candle.toml` 없음)다. 상태·원장·지급 대기를 볼 곳이 없다(#40024 열림). 재시도가 부분 결과를 기억하지 않는다 | D8-05 D8-07 D8-08 D8-11 |
| 논공행상 분배 | 일부 | `Candle_math.split` 이 몫의 합을 총액과 같게 지킨다. 코드는 있고 라이브 Off 라 지급은 일어나지 않았다 | D8-06 |
| Economy (turn spend·cost) | 일부 | 시도 → meta·cost 원장 경로는 돈다. Usage 24시간 표가 실패한 시도의 토큰을 빼서, 24시간 합계로는 Fleet 의 4.8%, Keeper 하나(jazz-developer)는 32%가 빠진다(09-28 에는 91%). 비용을 모르는 lane 의 합계가 0.0 으로 굳는다. cost 원장의 80.5%는 아무도 안 읽는 raw 줄이다 | D8-01 D8-02 D8-03 |
| 반감기 | 미구현 | 감소 코드와 설정 키가 없다. 헌법 `<candle>` 규칙 3 은 현재형이다 | D8-09 |
| Portrait | 일부 | HTTP·TUI·MCP 도구가 이어져 있고 메달 잘림·보관 PNG 문제는 닫혔다. 모자이크 축약 그림이 눈·장신구를 버린다. 용어집과 주석이 없는 화면(시작 화면, 상단 바 축약 캔들)을 설명한다 | D9-03 D9-04 D9-05 |
| Item Slot · 착용 · 구매 | 미구현 | 스냅샷 기준 main 에 착용을 저장하거나 구매하는 코드가 없다. 구현은 #40365(스냅샷 뒤 10-01 06:34 머지)와 그 위 PR 38개에 있다. 외형은 이름 해시로 매번 계산한다 | D8-10 D9-01 D9-02 |
| Play Invite | 일부 | 발급·회수·목록 route 와 `/play` 가 등록돼 있다. 발급 조건의 "공개 주소 있음" 검사가 켜질 수 없어 링크가 127.0.0.1 로 나간다. TUI 는 옛 거절 모양을 읽어 거절 이유를 못 보여 준다 | D10-01 D10-04 |
| DOS·MSX 기계 조작 | 일부 | 세 문(HTTP, Keeper 도구, `/mcp`)이 모두 조종권 확인을 거친다. msx saves 2,075개 10.4GB 에 상한이 없다. 복원 못 하는 DOS autosave 를 복원하라고 안내한다 | D10-02 D10-03 |
| TUI | 일부 | TUI 가 부르는 경로 161개는 모두 서버 route 에 닿고 디코더 15개 중 어긋난 것은 하나다. 운영 세션의 메인 루프가 15.5% 멈춘다. Home 은 부분 읽기 실패를 전체 실패로 읽어 결정 카드를 숨긴다. 푸터와 실제 동작이 어긋난 곳이 남아 있다 | D13a-01 D13a-02 D13b-01~06 |
| 웹 대시보드 | 일부 | 09-29 의 승인 대기·probe 상태·request_context·delivery kind 문제는 고쳐졌다. 번들이 09-29 11:52 커밋에 멈춰 부팅마다 경고한다 | L2-08 D13a-08 |
| Keeper 프롬프트·도구 설명 | 일부 | 기본 `keeper.md` 의 도구 이름·인자는 대부분 구현과 맞다. 라이브 Keeper 26명은 override 를 읽고 기본값과 6곳 다르다. 모든 Keeper 가 읽는 줄이 없는 도구를 가리킨다(#40510). 시스템 본문이 한 주에 55% 늘었다 | D15-01 D15-02 D15-03 D15-06 |
| 설정 (TOML·환경변수) | 일부 | Keeper TOML 키 23개는 모두 읽힌다. 새 `MASC_*` 환경변수는 0개(280개 그대로)이다. runtime.toml 로 줄 수 있다는 Keeper 설정 키 8개는 서버가 뜰 때 계산된 값만 읽는다. `MASC_AUTH_STRICT=strict` 는 거절하지 않고 로그만 남긴다 | W2-02 W2-04 W2-06 W2-07 |
| 저장 용량·보존 | 일부 | 30일 정리가 tool_calls·costs·audit 등에 걸려 돈다. `.masc` 116GB, worktree 1,041개(10-01 오전), 정리하는 코드가 없는 옛 홈 약 50GB(antigravity 33.2GB, codex 17.2GB)가 쌓여 있다. 파티션 원장은 하루 1.9만 개씩 는다 | L3-01~13 W3-02 |
| Terminal-Bench 준비 | 일부 | 어댑터는 main 인터페이스와 맞고 v0.48.0 서버가 head 로 렌더한 arm b·e·f·h 설정으로 `keeper_up` 까지 간다. head 로 돌린 기록은 0건이고 GPU 3개와 자원 초과 10개는 이 호스트에서 못 돌린다. 돌리기 전에 서버를 띄워 보는 사전 점검(#40509)과 trial 기록에 설정 출처를 남기는 변경(#40518)을 올렸다 | D14-01~05 |


영역별로 더 자세한 판정(기능마다 근거와 발견 id)은 [발견 목록](2026-10-01-week-audit-findings.md)의 "기능 판정" 절에 있다.

## 3. 09-29 발견의 현재 상태

09-29 감사의 발견 161건을 감사관 다섯 명이 코드에서 다시 확인했고, 닫혔다고 한 것과 열려 있다고 한 것은 재확인 검증을 한 번 더 거쳤다(맞다 54, 틀렸다 1, 확인 못 함 7).

| 심각도 | 고쳐짐 | 일부만 | 그대로 열림 | 위치를 못 찾음 | 없어진 코드 |
|---|---|---|---|---|---|
| P0 | 2 | 0 | 0 | 0 | 0 |
| P1 | 14 | 4 | 20 | 0 | 0 |
| P2 | 7 | 11 | 94 | 6 | 2 |
| 그 밖 | 0 | 0 | 0 | 1 | 0 |

- 닫힌 P0 2개와 P1 14개는 이렇다. #39972(Codex resume 을 block 단위로, RT-C1·C2·C3·MM-M1·M2), #40006(schedule wake 회수, RT-S1), #40019(atom 끝 줄, MM-C1), #40003(Board 판정 쌍, DM-BD-1), #40045(DOS 조종권, DM-PL-01), #39961·#39957(Portrait, DM-PT-1·2), #39991(웹 Gate 승인 대기, TU-F01), #39996(대시보드 decoder, TU-F02·F17·F18), #39998(TUI 다음 일정, TU-F04).
- 일부만 고쳐진 것은 RT-R1(#39997 이 Keeper Codex 경로만 고침), MM-M3(#40001 이 같은 사실의 commit 을 건너뜀, 늘기만 하는 쪽은 그대로), TU-F11·F19 등이다.
- P1 중 그대로이거나 일부만 고쳐진 것은 24개다. 대부분은 두 묶음이다. Curator·Librarian 쪽 잠복 결함(RT-A2, MM-W1~W5)과, TUI 가 서버의 "못 읽음"을 정상값으로 그리는 묶음(TU-F05~F16)이다.

## 4. 이번 감사의 P0·P1

같은 결함을 영역 둘이 따로 잡은 것은 한 줄씩 남겼다. D5-01·D7-01·L2-02 는 같은 채팅 행이고, D2-01·D3-01·L2-01 은 같은 저장 거절이다.

| id | sev | 결함 | 확인 | 처리 |
|---|---|---|---|---|
| D5-01 | P0 | 리더 Keeper 의 대화 저장이 막혔어요: 지운 goal_notification 종류가 디스크에 1줄 남아 있어요 | 확인 · High | 운영자가 10-01 01:31 에 채팅 파일을 옮겨 복구. 옛 종류를 되살리는 #40337 은 닫힘 |
| D1-02 | P1 | Codex 프레임의 threadId/turnId 가 active 와 다르면 turn 전체를 프로토콜 오류로 끝낸다 | 확인 · Medium | #40364 머지(sub-agent 를 못 띄우게 해서 원인을 줄임). 신원 불일치 자체는 남음 |
| D1-03 | P1 | 배정 27명 중 15명은 lane 이 없다. failover 가 no-op 이다 | 확인 · High | 운영자 결정(lane 설정, 12절) |
| D2-01 | P1 | #40019 뒤 continuity 스냅샷 commit 이 매번 거절돼 Librarian 모델 답이 버려진다 | 확인 · High | #40359 머지 |
| D2-03 | P1 | Codex 턴 중간 compaction 뒤 item/started 신원 불일치가 치명 오류가 돼, 효과 차단과 새 Start(약 876KB)로 이어진다 | 확인 · Medium | #40364 머지(D1-02 와 같은 원인) |
| D3-01 | P1 | Continuity 회차가 모델을 부른 뒤 저장에 실패하고 같은 입력으로 반복한다 (#40019 의 나머지 절반) | 열린 PR 이 다룸 · High | #40359·#40373 머지 |
| D6-01 | P1 | 요청이 나가지도 못한 DNS 실패가 입력 문제로 분류돼 Board attention 파티션이 Blocked 로 굳는다 | 확인 · High | #40397 (소스 리뷰 PASS) |
| D6-02 | P1 | Board attention 대기열이 줄지 않는다: 처리까지 중앙값 13초 → 12.9시간 | 확인 · High | RFC #40450 머지(판정 단위를 신호 하나로). 구현은 아직 |
| D6-03 | P1 | verifier_exact 재시도가 닫히지 않는다: 하루 469번 시도, 판정 18건, 900초 무응답 330번 | 확인 · High | 운영자 결정(슬롯 추가, 12절) |
| D7-01 | P1 | #39975 가 지운 goal_notification 행이 e-masc-the-leader 대화 파일에 남아 그 Keeper 의 저장이 전부 막힌다 | 확인 · High | D5-01 과 같음 |
| L2-01 | P1 | #40019 뒤로 Librarian 이어받기(continuity) 저장이 20명 Keeper 에서 매번 실패해요 | 확인 · High | #40359 머지 |
| L2-02 | P1 | 지워진 goal_notification 행 한 줄이 e-masc-the-leader 채팅 저장과 멘션 전달을 막고 있어요 | 열린 PR 이 다룸 · High | D5-01 과 같음 |
| D10-01 | P1 | 초대 발급의 '공개 주소 있음' 검사가 켜질 수 없다. 링크가 127.0.0.1 로 나간다 | 확인 · High | 보류(12절) |
| L3-01 | P1 | 여유 공간이 시간당 수십 GiB 줄고, 줄이는 장치가 자동으로 돌지 않는다 | 확인 · Medium | 운영자 결정(정리, 12절) |
| X4-01 | P1 | Stagehand '라이브 활성화' 증거는 fixture 한 번의 성공이고, 그 뒤 Keeper 호출 10건은 전부 실패했어요 | 확인 · High | 운영자 결정(슬롯 시간 배분, 12절 19번). 열린 PR 은 없다 |

이번에 검증이 P1 에서 P2 로 낮춘 것 중 눈여겨볼 것은 넷이다.

- W1-01: Keeper 가 `masc_gc`, `masc_board_cleanup` 을 권한 확인 없이 부른다. 도구 목록은 둘을 `admin_tool`(CanAdmin)로 적지만 Keeper 경로는 `required_permission` 을 읽지 않는다. 09-20 에 `code-reviewer` Keeper 가 `masc_gc {days:1}` 로 메시지 파일 3,462개를 지웠다(Task 477개는 보관함으로 이동). 9월 한 달 실호출은 이 한 번이다. 낮춘 이유는 호출이 한 번이고 영구 손실이 레거시 메시지 파일뿐이어서다. `masc_gc` 를 Operator 전용으로 내리면 GC 를 부를 운영자 경로가 있어야 한다(D6-11 에 스케줄이 없다). `masc_board_cleanup` 은 RFC-keeper-skill-peer-signal 이 Keeper 사용을 전제하고 시험(`test_keeper_tool_policy_masc_surface.ml`)이 보이는 상태를 단언해서, 운영자 뜻을 먼저 물어야 한다.
- W3-01: 배포 전 검사(`validate-stores`) 목록 18개에 못 읽는 행 하나가 쓰기를 막는 저장소가 빠져 있다. 채팅은 #40402·#40423 이 다룬다. 남은 것은 파티션 원장, Board 댓글·투표·반응, Candle 원장이다. 저장소마다 못 읽는 행에서 멈추는지를 RFC(every-durable-store-has-one-boot-policy §1 (c))의 기준으로 먼저 정해야 한다.
- D13a-02: 실제 운영 TUI 의 메인 루프가 자주 멈춘다. 세션 하나(pid 80035, 02:12 시작, 약 5시간 55분)에서 멈춘 시간이 3,296초(15.5%)이고 중앙값 1.8초, 최대 79.5초다. 멈춘 동안 폴링 요청 다섯 개가 같은 시각에 같은 시간으로 끝난다. 검증 넷 중 둘은 P1 으로 확인했고 둘은 증상만 확인하고 원인은 못 가렸다고 했다(이슈 #39763). 프레임을 동기 `write`+`flush` 로 쓰는 것이 의심스럽지만 증명하지 못했다. 고치기 전에 `MASC_TUI_FRAME_TIMING` 으로 프레임 쓰기와 flush 시간을 먼저 재야 한다.
- D14-01: head 기준 Terminal-Bench 측정이 0건이다. 결함이 아니라 측정이 안 된 상태라서 P2 로 낮췄다(11절).

## 5. 되풀이되는 원인

한 번 고친 곳이 다른 모양으로 다시 나온다. 이번에 나온 것을 원인으로 묶으면 여섯 가지다.

### 5-1. 지운 것이 디스크에 남아 읽는 쪽을 막는다

- D5-01: 지운 `goal_notification` 종류 한 줄이 리더 Keeper 의 채팅 저장 전부를 막았다. 복구는 운영자가 파일을 옮겨서 했다(10-01 01:31).
- X3-01·X3-02: `front_atom_digest` 를 지운 뒤(#38822) 옛 TurnRecord 행 하나가 raw-trace 청소 전체를 멈췄다. 읽는 곳 7개가 제각각 반응해서 경고 14.8만 줄이 찍혔다.
- D6-08·L2-03: 지운 variant 의 `operator_routed` 19줄이 원장 압축을 4일째 막고 있다.
- D16a-05: 하루 살다 지운 Goal `owner` 가 RFC, 대시보드 디코더, fixture 에 남아 있고, Goal 저장소가 하드컷(09-30 23:26 KST) 전까지 `schema_rejected(owner)` 로 읽히지 않았다.
- W3-01: 배포 전 검사가 이런 저장소를 다 읽지 않는다.
- 뿌리: 저장소마다 못 읽는 행에 반응하는 규칙이 다르고(경고만, 건너뜀, 쓰기 거절), 배포 전에 모든 저장소를 같은 디코더로 읽어 보는 장치가 없다. 하드컷은 읽는 코드를 만들지 않는 정책이라서, 배포 전 검사가 그 몫을 해야 한다.

### 5-2. 쓰는 쪽과 읽는 쪽이 따로 바뀐다

- D13a-01·D10-04: #40050 이 play 거절 모양을 `{error, code, missing, taken_by}` 로 바꿨는데 TUI 의 `play_invite_refusal` 은 옛 `message` 를 읽어서 항상 None 이다.
- D13a-08: TUI 디코더 시험의 JSON 이 서버 encoder 가 아니라 손으로 쓴 값이라, TU-F04 같은 사고가 이번 주 두 번 났다.
- D2-01: #40019 가 atom 을 끝 줄 없이 저장하게 하자 continuity 스냅샷 commit 이 매번 거절됐다.
- D8-08: Paid 디코더가 산수를 다시 계산해서, 산식을 고치면 옛 줄 때문에 원장 전체를 못 읽는다.
- 뿌리: 같은 모양을 서버와 클라이언트가 각자 쓴다. RFC #40000(클라이언트 decoder 는 서버가 쓴 fixture 로 시험)이 방향이다.

### 5-3. 이름은 있는데 동작이 없다

- W2-02: runtime.toml 로 줄 수 있다고 안내하는 Keeper 설정 키 8개가 서버가 뜰 때 계산된 값만 읽는다. 바꿔도 효과가 없는데 설정 화면은 적용됐다고 한다.
- W2-04: `MASC_AUTH_STRICT=strict` 는 요청을 거절하지 않고 로그만 남긴다. 2026-04 부터 "다음 단계"로 미뤄 둔 상태다.
- W1-01: 도구의 `admin_tool` 표시가 Keeper 경로에서는 아무 효과가 없다.
- D16a-02·D16a-03: `Context_measured` 이벤트를 만드는 곳이 없어 `context_handoff_needed` 는 늘 false 이고, 에이전트 적합도의 handoff 값은 "핸드오프가 없으면 만점"이라 늘 100% 다.
- D15-02: 모든 Keeper 가 읽는 World State 줄이 없는 도구 `keeper_status` 를 가리킨다(요청의 34.7%). #40510 이 고친다.
- 뿌리: 이름을 더할 때 읽는 곳을 같이 만들지 않고, 지울 때 같이 지우지 않는다. 컴파일러가 못 잡는 자리(문자열 설정 키, 프롬프트 글, route)에서 특히 그렇다.

### 5-4. 끝나지 않는 고리

- D6-02: Board attention 대기열이 줄지 않는다. 처리까지 중앙값이 13초에서 12.9시간이 됐고 09-30 후보의 71% 가 pending 이다. 오늘 `board_attention_exact` lane 호출은 시간당 약 4,300번이다(10-01 02:07~06:49, `exact-lane-runs-v6.jsonl` 20,093건). RFC #40450 이 판정 단위를 (신호, Keeper) 쌍에서 신호 하나로 바꾸자고 한다.
- D6-03·L2-04: 슬롯이 하나인 lane 은 쿼터가 막혀도 쉼이 순서만 바꿔서 계속 부른다. verifier 는 하루 469번 시도해 판정 18건을 냈고 900초 무응답이 330번이다.
- D1-01: Librarian 이 쉬는 슬롯을 pass 마다 다시 부른다. 오늘 Librarian lane 호출은 시간당 약 620번이고 답은 전부 CLI 슬롯(Claude Code, Codex)에서 온다(09-30 23:20~10-01 06:50, 4,651건).
- W3-02·D6-06·D5-03·D5-04·D10-02: 파티션 원장 81,534개(97% settled, 하루 1.9만 개 증가), attention 후보 원장 307MB, 큐 상태의 옛 행 86%, 회차 영수증, msx saves 10.4GB. 늘리는 코드는 있고 줄이는 코드는 없다.
- 뿌리: 생산자는 있고 소비와 소거에 규칙이 없다. 막히면 무엇을 하는지(기다림, 건너뜀, 멈춤)를 저장소와 lane 마다 따로 정했다.

### 5-5. 슬롯 하나

- D1-03: 배정 27명 중 15명(Codex)은 넘어갈 lane 이 없어서 failover 가 아무 일도 안 한다.
- D1-09·D6-03·D7-02: 판정 세 기능(verifier, Board attention, Goal 검증기)이 `glm-5.3-flash` 한 슬롯에 몰려 있다. 운영자가 정할 일이다(12절).

### 5-6. 측정이 없다

- D14-01: Terminal-Bench 를 head 로 돌린 기록이 없다.
- D3-03: Memory 합성(absorb)이 09-30 아침부터 0건인데 원인을 못 가렸다. 하루 400건 안팎이던 것이 09-30 에 54건, 10-01 06:40 까지 2건이다. 프롬프트·스키마·코드는 그대로이고 입력에는 `m1` 같은 짧은 ID 가 있다. Ollama 슬롯 실패가 09-30 08시(KST)에 몰린 뒤 Librarian 답이 전부 CLI 슬롯에서 온다는 시각 상관만 있다. Ollama 주간 한도가 풀려 그 슬롯이 다시 답할 때 absorb 가 돌아오는지 보면 가를 수 있다.
- L1-04·L1-05·L1-09·D8-02: exact lane 호출은 token 사용량을 어디에도 남기지 않고, 비용을 모르면 0.0 을 적는다.

## 6. 시간축 (1 → N tick)

| 고리 | 1 tick | N tick | 닫힘? |
|---|---|---|---|
| Codex 다 쓴 계정 (RT-R1, D1-06) | 사용량 거절 → 리셋 시각까지 쉼(#39997, Keeper 경로만) | 쉼 기록이 프로세스 메모리에만 있어 재시작마다 다시 부른다. Fusion 경로는 안 쉰다 | 반쯤 |
| Librarian lane 호출 (D1-01, L1-01) | pass 가 slot 을 차례로 부른다 | 쉬는 slot 도 pass 마다 다시 부른다. 시간당 약 620번, 답은 전부 CLI 슬롯 | 열림 |
| Board attention 대기열 (D6-02) | 후보 저장 → Jev 판정 | 도착이 처리보다 빨라 09-30 후보의 71%가 pending, 중앙값 12.9시간. lane 호출 시간당 약 4,300번 | 열림 |
| verifier 재시도 (D6-03) | 판정 요청 | 슬롯 하나, 하루 469번 시도에 판정 18건, 900초 무응답 330번 | 열림 |
| continuity 저장 (D2-01) | 모델 호출 → 스냅샷 commit | commit 이 매번 거절돼 모델 답이 버려졌다(13시간 2,151회). #40359 로 닫혔다 | 닫힘 |
| 파티션 원장 (W3-02) | 파티션마다 행 하나 | settled 행을 지우지 않아 81,534개 중 97%가 settled, 하루 약 1.9만 개 늘고 파일이 76MB | 열림 |
| attention 후보 원장 (D6-06) | 후보마다 Board 본문 전체를 저장 | 줄어드는 길이 없어 307MB | 열림 |
| 회차 영수증·signal (D5-04, D5-06) | 회차가 끝날 때마다 영수증 파일 하나, signal 은 하루 1.6~1.9MB | 둘 다 지우는 코드가 없다. signal 을 읽는 곳은 최근 20행뿐이다 | 열림 |
| 옛 TurnRecord 행 (X3-01, X3-02) | `front_atom_digest` 를 지운 뒤 옛 행 하나 | raw-trace 청소가 Keeper 마다 며칠 멈췄고 경고 14.8만 줄이 찍혔다 | 열림 |
| Memory facts 크기 (D3-05, X2-04) | fact 추가 | 감쇠가 없다. 한도 512 KiB 에 가까운 Keeper 가 2명이고, 닿으면 같은 range 로 모델을 신호마다 다시 부른다(잠복) | 반쯤 |
| msx saves (D10-02) | 저장마다 같은 디스크 이미지를 되풀이 저장 | 2,075개 10.4GB, 상한과 삭제가 없다 | 열림 |
| TUI 갱신 (D13a-02, D13a-05) | 2초마다 같은 묶음을 받아 파싱 | 안 바뀐 응답 약 190KB 를 매번 받는다. 메인 루프는 세션의 15.5%(최대 79.5초) 멈춘다 | 열림 |
| 채팅 열기 → runtime.toml 기록 (D13b-07) | Keeper 채팅을 연다 | 방문마다 운영자 소유 파일 전체(64KB)를 검증하고 다시 쓴다. #40137 이 일부러 정한 동작이라는 검증도 있다 | 열림 |
| Task GC (D6-11) | backlog 에서 지운 뒤 archive 에 붙이던 순서 | 순서는 #40427 이 고친다. GC 를 돌리는 스케줄은 여전히 없다 | 반쯤 |
| Board 판정 미룸 (09-29 DM-BD-3) | lane 쉼 → 후보를 미룸 | 09-29 미룸 12,974건이 148건으로, glm 429 는 684건에서 36건으로 줄었다 | 닫힘 |


위 표는 확인한 고리의 사례다. 전체 고리별 상태와 출처를 갖춘 인벤토리가 없어 총수와 열림·반쯤·닫힘의 전수 합계는 제시하지 않는다. 개별 발견과 근거는 [발견 목록](2026-10-01-week-audit-findings.md)에 있다.

## 7. 낭비

| 종류 | 크기 | 원인 |
|---|---|---|
| Librarian lane 호출 | 시간당 약 620번(09-30 23:20~10-01 06:50, 4,651건). 실행의 55%는 기억을 안 바꾸는 보조 회차 | D1-01 D3-04 L1-01 |
| Board attention lane 호출 | 시간당 약 4,300번(10-01 02:07~06:49, 20,093건) | D6-02 |
| verifier 재시도 | 하루 469번 시도에 판정 18건 | D6-03 |
| recall block 재전송 | fact 하나가 바뀌면 recall block 140~450KB 전체를 다시 보낸다. 이어받기의 12%가 바이트의 55% | D2-06 L1-07 |
| Codex 창 | recall block 과 도구 스키마가 창의 95%를 채워 세 Keeper 가 2~3턴마다 compaction | L1-08 |
| continuity 모델 호출 | 728회가 저장 단계에서 전부 실패했다(#40359 로 닫힘) | D2-01 L1-02 |
| Keeper 프롬프트 | 시스템 본문이 9,112B 에서 14,110B 로 55% 늘었고 늘어난 양의 절반이 PR 승인·병합 절차다. 요청 한 번은 시스템 25KB, 도구 배열 148KB, 추가 컨텍스트 195KB(중앙값)라서 글을 줄여서 얻는 몫은 작다 | D15-06 D15-07 |
| TUI 폴링 | 2초마다 안 바뀐 응답 약 190KB 를 다시 받아 파싱한다. 서버는 이미 304 를 준다 | D13a-05 |
| GitHub 폴링 | 서버가 60초마다 저장소 3개의 열린 PR 을 읽는데 읽는 화면이 없다. GraphQL 한도의 약 4%를 쓴다(#38801 이 TUI 의 PR 줄을 지운 뒤. 서버 PR 조회 API 는 운영자가 남기기로 한 것이다) | W3-03 D13a-06 |
| 스케줄 파일 쓰기 | 회차 하나에 `schedules.json` 을 통째로 3번, 2개 파일에 다시 쓴다 | D5-02 |
| cost 원장 | 80.5%가 아무도 안 읽는 raw 줄이고 보관 기한이 없다 | D8-03 |
| 로그 | WARN/ERROR 가 09-28 22,848줄, 09-29 43,387줄. 진짜 오류는 일부이고 대부분 quota_blocked·turn_failed·long-turn 소음이다 | L2 |
| 저장소 | `.masc` 116GB, worktree 1,041개(병합·닫힌 PR 것도 지우는 주체가 없다), 정리하는 코드가 없는 옛 홈 약 50GB, msx saves 10.4GB, `.git` 안 실행 파일 4.7GB, 여유 공간이 시간당 수십 GiB 줄던 때가 있었다 | L3-01~13 D10-02 |
| 증거 원본 | `docs/evidence/` 의 압축 파일 두 개 56.5MB 는 읽는 곳이 없고 모든 worktree 가 받는다. 효과가 없다고 스스로 적은 perf PR 3개가 압축 파일 60MB 를 git 에 넣었다 | L3-11 D12-04 |


## 8. 와이어링 누락

- **쓰기만 하고 읽지 않는 것.** `ready_confirmation` 행(3,157행, 1.2MB, W3), 라이브 runtime.toml 의 `[health]`·`[tui]` 같은 키 2개(W2-01), `healthcheck.path`(설정 마법사가 모든 HTTP provider 에 적고 로드 때 검사까지 하지만 상태 확인에 쓰는 곳이 없다, W2-09), 읽는 코드가 없거나 읽고 버리는 환경변수 3개(라이브 프로세스는 읽는 곳 없는 `MASC_KEEPER_BOOTSTRAP_ENABLED` 를 쥐고 있다, W2-06).
- **쓰는 코드가 없는데 읽는 route 만 남은 것.** `mention_inbox`, Keeper response feedback(W3-04).
- **부르는 곳이 없는 것.** `Candidate_fault.of_transport_error`, `Runtime_muse_msp.turn_interrupt_request`(W3). 측정 콜백 두 개는 lib 의 모든 호출자에서 `fun _ -> Ok ()` 다(X3-08). `?recovery_view` 를 만드는 production 호출이 0곳이라 `Some` 분기가 죽은 코드다(D2-08). 입력을 그대로 돌려주는 stub `resolve_keeper_wake_target`(D5-11, X3-03, #40407).
- **이름만 있고 동작이 다른 것.** runtime.toml 로 줄 수 있다고 한 Keeper 설정 키 8개는 서버가 뜰 때 계산한 값만 읽는다(W2-02). 설정 화면의 effective_value 는 `Runtime_params` 를 안 봐서 같은 설정 7개가 실제와 다를 수 있다(W2-03). `MASC_AUTH_STRICT=strict` 는 거절하지 않고 로그만 남긴다(W2-04). `Context_measured` 이벤트를 만드는 곳이 없어 `context_handoff_needed` 는 늘 false 다(D16a-02). `admin_tool` 표시가 Keeper 경로에서 효과가 없다(W1-01).
- **화면이 못 읽는 것.** TUI `play_invite_refusal` 이 옛 거절 모양을 읽어 항상 None 이다(D13a-01). ask 로그를 못 읽으면 서버가 질문 0개로 답하고 Home 이 "결정 기다리는 것 없음"이라고 그린다(D13a-04). Home 승인 줄이 '아직 안 읽음'·'읽기 실패'·'옛 값'·'사용 불가'를 같은 문구로 그린다(D13b-03). `/login` 모델 선택의 `a:전체` 는 context 를 모르는 모델을 안내 없이 건너뛴다(D13b-08). TUI 에서 MSX 키를 눌러도 서버가 거절한 결과를 버린다(X3-04).
- **볼 곳이 없는 것.** Candle 상태·원장·지급 대기 목록(D8-11, #40024 열림). `failed_attempt` 마크와 exact lane 쉼(D1-08). 서버가 60초마다 읽는 GitHub PR 목록(W3-03, 서버 PR 조회 API 는 운영자가 남기기로 했다).
- **도구 지표.** 도구 지표 저장소가 한 도구를 모델 이름과 내부 이름 두 줄로 쪼개고(W1-03), Skill·Composition·`tool_search`·외부 MCP 호출은 기록하지 않아 도구 호출의 4.3%가 빠진다(W1-04).
- **죽은 개념이 남은 곳.** 10절에 따로 적었다.
- 이어진 것: 도구 registry 와 핸들러 사이에서 이름이 어긋난 곳은 못 찾았다. descriptor 의 `runtime_handler` 는 exhaustive match 이고, 태그 없는 도구가 있으면 서버가 뜨지 않는다. TUI 와 대시보드가 부르는 도구·route 이름은 전부 서버에 있다(W1).


## 9. 도메인 결합

- 09-23 감사가 제안한 결합 해소 5건은 지금도 모두 열려 있다. TUI Agenda 가 서버를 건너뛰고 backlog 를 직접 읽는다(D16b-04). Librarian 이 Keeper meta 와 checkpoint 저장소를 직접 읽는다(D16b-05). Runtime 라이브러리가 `keeper_runtime`·`keeper_registry` 를 쓴다(lane 이름은 닫힌 타입 `Standalone_lane.t` 로 바뀌었고 이것은 RFC 가 정한 설계다). Board 판정 후보가 `board_signal` 을 통째로 저장해서 Board 타입이 바뀌면 Keeper 쪽 저장 파일 모양이 바뀐다(D16b-06). Schedule 소비자가 Keeper 내부 모듈 15개를 이름으로 부른다. `server_schedule_consumers.ml` 한 파일에 136번이고(09-23 158, 09-29 136, 지금 136), 09-29 문서의 96은 같은 방식으로 재현하지 못했다(D16b-03).
- dune 그래프에 순환은 없다. 라이브러리 357개 중 `lib/` 아래 165개이고, 새 라이브러리 9개(candle, candle_store, candle_config, candle_runtime, keeper_portrait, lane_activity, machine_checkpoint, machine_live_publication, runtime_toml_namespace)는 모두 아래로만 의존한다. 문제는 반대쪽이다. `lane_addon`, `lane_registry`, `world_constitution`, `play`, `keeper`(541파일 23만 줄), `fusion` 은 dune 파일이 없어 본체 `masc` 라이브러리 하나(약 32만 줄) 안에 있다. 이 안의 결합은 dune 이 막지 못한다(D16b-02).
- 이름으로 부른 횟수가 큰 쌍은 Keeper → Workspace 652(Workspace 퍼사드 570), Keeper → Board 286, Keeper → Memory 277, Librarian → Keeper 237, Keeper → Lane 228, HITL → Keeper 225, Keeper → HITL 293이다. Board·Goal·Task 에서 Keeper 로 가는 참조는 0이다.
- 큰 파일: `.ml` 300줄 넘는 것이 867개, 2,000줄 넘는 것이 71개다. `bin/masc_tui.ml` 은 26,710줄이고 `main` 한 함수가 9,953줄이며 열린 PR 의 34%가 이 파일을 건드린다(D16b-01). `lib/tui_decode.ml` 은 10,651줄이고 분리 중이다. 공급자 런타임 4개가 같은 모양의 830~925줄 함수와 33~43개 labelled 인자를 각자 갖는다(D16b-07). `run_named` 는 분해 RFC 가 Active 인데 1,109줄에서 1,491줄로 늘었다(D16b-08). 경로 도우미 하나 때문에 Board·Schedule·Candle 저장소 등 5개 라이브러리가 Task 저장소 라이브러리 전체에 링크된다(D16b-09).
- 09-29 가 남긴 판단은 그대로다. Karma·Candle·turn spend 는 입력도 코드도 따로라 같은 개념이 아니므로 합치지 않는다. Goal ← Candle 방향은 맞다. 확정 step 의 Error 가 Goal 완료를 막는 문제(DM-GT-02)는 운영자 결정이 필요하다.


## 10. Glossary와 죽은 개념

- **크기.** `docs/spec/00-glossary.md` 가 246,223B 이고 항목이 208개다(09-29 감사 때 239KB, 204개). 하루에 6.5KB, 항목 4개씩 늘고, 09-29 이후 이 파일을 고친 커밋이 17개다. 항목 크기는 중앙값 922B, 90백분위 2,328B 이고 2KB 를 넘는 항목이 31개, PR 번호가 든 항목이 50개(97곳)다. 가장 큰 항목은 Exact-output route 7,252B, Carried Front 6,197B, Dropped/Supersedes/Absorbs 5,099B 다. 10-01 13시 기준 열린 glossary PR 5개 가운데 #40471·#40382·#40318 이 항목을 더한다. 줄일지는 12절의 결정이다. 줄이면 항목마다 한두 문장 정의와 코드 링크만 두고 값 이름·PR 번호·route 는 `.mli` 와 RFC 로 넘긴다. Exact-output route 는 7,252B 에서 약 300B 가 된다(D16a-13).
- **죽은 개념.** 09-23 이후 지운 개념 19개를 조사했고 14개는 `lib`·`bin`·`dashboard`·`config` 에 잔재가 없다. 남은 것은 다섯이다. 죽은 개념은 폐기 표시를 남기지 않고 지운다.
  - Keeper handoff: 대시보드의 "핸드오프 임박" 문구와 설정, `Context_measured` 를 만드는 곳이 없어 늘 false 인 `context_handoff_needed`, 늘 100% 인 적합도 handoff 값, Agent Core 의 handoff 모듈이다(D16a-01·02·03·07). 아직 고치는 PR 이 없다. Agent Core handoff 는 운영자가 정한다.
  - #38801 이 지운 Overview Team 블록의 계산과 타입이다(D16a-04). #40516 이 지운다.
  - 하루 살다 지운 Goal `owner` 의 RFC-0362 와 디코더·fixture 다(D16a-05). RFC-0362 는 다른 RFC 다섯 개가 본문에서 가리켜서 한 번에 못 지운다(12절).
  - 지운 CI 스캐너 96개를 가리키는 문서와 주석, 읽는 곳 없는 설정 파일이다(D16a-06). X4-05 는 같은 문제를 43개 파일로 셌다. #40517 은 그 가운데 살아 있는 지침·주석·목록 파일을 고쳤고, RFC·감사 문서·`docs/evidence` 는 그 시점의 기록이라 두었다. 감사가 지우자던 `scripts/lint/` 의 "주인 없는 스크립트 2개"는 읽어 보니 주인이 있어서 지우지 않았다(`harness-connector-env-ratchet.sh --self-test` 가 부르는 selftest 와, 남은 검사기의 대상 목록을 보는 guard).
  - `resource-read-max-bytes`(09-29 MM-S5)다.
  - Glossary 안에는 "지웠다"고 설명하는 문장과 없는 항목을 가리키는 문장이 있었다(D16a-08). 현재 main 에는 문장 둘과 참조 둘이 남았고 #40515 가 고친다.
- **한 단어가 여러 뜻.** `lane` 은 8가지 이상(`.mli` 47개), `격리` 는 6가지다. TUI 첫 화면은 Overview·Dashboard·Home 세 이름이고, "이번 tick 에 보내지 않고 둔다"는 한 가지 일을 hold·held·defer·보류 네 이름으로 부른다. 개정안은 `lane` 을 Standalone Lane(모델을 한 번 불러 답만 받는 작업 다섯 가지의 고정 경로), Runtime Lane(Keeper turn 이 실패할 때 차례로 시도할 runtime 후보 목록), Machine Lane(DOS·MSX·Browser 기계 하나), Lane Add-on(기계 위에 붙는 패키지)으로 가르고, `격리` 는 "다시 시도하지 않고 보관한 항목" 하나로 정의하는 것이다(D16a-09·10). TUI 첫 화면 이름은 운영자가 하나를 골라야 한다(D16a-11).
- **정의가 없는 말.** Access Control, Keeper Owner(09-23 부터 지적됨, `owner` 가 4가지 뜻으로 쓰인다), Worker, Workspace Curator, Item, Player credential(D16a-14, D7-06).
- **어려운 표현.** 가장 어려운 표현 30개와 쉬운 대안을 [발견 목록](2026-10-01-week-audit-findings.md)에 적었다(D16a-15). 새 글에서는 "걸음" 대신 "순회", "사정" 대신 "원인", "후계" 대신 "대신 쓰는"을 쓴다. 코드 이름과 필드 이름은 영어 그대로 둔다.


## 11. Terminal-Bench

Terminal-Bench 4.0.0(2026-08-26 릴리스, 66 task)을 head 로 돌려 본 기록은 0건이다. 마지막 실행은 09-22 의 task 1개 trial 7건(통과 1건, dist 0.35.22)이다. 스펙 5.4 의 확인런(전체 66 task × arm a,b × k=1)은 한 번도 돌지 않았다(D14-01).

- **어댑터.** `masc login` 인자, Keeper 도구 이름·인자, approval-mode REST, 작업 상태 이름, runtime.toml 키가 main 과 맞고 끝까지 이어져 있다. harbor 0.23.0 이 최신 안정판이다. 릴리스 v0.48.0 의 linux-x64 바이너리는 GLIBC 2.35 이하이고 deps.sh 가 필요한 라이브러리를 깐다(D14).
- **이번에 직접 돌려 본 것(2026-10-01, 이 Mac, Docker Desktop, v0.48.0).** head 로 렌더한 arm b·e·f·h 설정으로 서버가 뜨고, arm 이 선언한 keeper 전부(b·e 1명, f 4명, h 8명)의 `keeper_up` 과 승인 모드 설정까지 간다. 에뮬레이션 amd64 에서 b 49초, e 51초, f 83초, h 89초이고 `claude_code/claude-sonnet-5` 로 arm e 도 116초에 통과한다. 모델은 부르지 않았다. #39020 때의 렌더(HTTP runtime 을 `cli_slots` 에 둠)를 되살리면 같은 릴리스에서 `masc_keeper_up` 이 "Model setup required" 로 실패한다. 이 확인을 실행 전에 자동으로 하는 `preflight_arms.py` 를 #40509 로 올렸다. `run_matrix.sh` 가 데이터셋을 받기 전에 부른다(D14-03). 적대적 리뷰가 "keeper 를 하나만 올려서 trial 과 다르다"(P1)와 `GH_TOKEN`·modal·SIGTERM 정리 빠짐(P2)을 짚어서 고쳤고, 시험이 못 잡던 고장 24가지를 일부러 넣어 모두 잡히게 했다. trial 과 남은 차이 셋(f·h 의 keeper 를 trial 은 `run_episode.sh` 가 90초 제한으로 올린다, 태스크 Skills, 태스크 이미지)은 README 에 적었다.
- **릴리스의 `validate-runtime-config` 는 이 설정을 거절한다.** 두 exact lane(`hitl_auto_judge`, `board_attention_exact`)의 slot 이 provider `claude` 에 `exact-body-timeout-s` 가 없어 빠지기 때문이다. 서버는 이 상태로도 부팅과 `keeper_up` 이 되고 로그에 ERROR 한 줄이 남는다. 벤치는 이 lane 을 걷지 않아서 이 판정을 gate 로 쓰지 않았다.
- **못 한 것.** 모델이 실제로 답하는지(스모크가 필요하고 비용이 든다), 태스크 이미지 자체(사용자, PATH, 배포판), 이 호스트 docker 로는 66개 중 53개만 돌릴 수 있고 GPU 3개와 자원 초과 10개는 못 돌린다는 점, Modal 경로(자격 없음, 실행 이력 없음)다. 에뮬레이션 amd64 점수는 리더보드와 비교할 수 없다.
- **설정 출처.** 바이너리는 최신 릴리스에서, 설정과 프롬프트는 체크아웃 head 에서 와서 두 출처가 어긋나고(v0.48.0 이후 183 커밋, `config/`·`skills/`·`models.toml` 15개 파일 +528 −82줄), trial 기록에는 설정을 만든 커밋·렌더한 runtime.toml·effort 가 남지 않았다(D14-02). #40518 이 체크아웃 커밋, runtime.toml 과 설정 디렉터리의 sha256, effort 를 trial 기록(`config_provenance`)에 남긴다. 어떤 설정이 도는지는 바꾸지 않고 남기기만 한다. 릴리스 태그의 config 로 고정하는 안이나 바이너리에 내장된 config 만 읽는 안은 운영자 결정이 필요하다.
- **리더보드 규칙.** 4.0 제출 요건(trial 수, ATIF, trajectory 공개)의 공식 문장을 못 찾았다. harbor 0.23.0 CLI 에는 `leaderboard submit` 이 없다. 2.1 문서 기준 기억(task 당 5회 이상, trajectory 공개)은 4.0 도 같은지 확인 필요다(D14-04).
- **성능 벤치 스크립트.** `benchmarks/quick-bench.sh` 와 `benchmark.sh` 가 어디에도 없는 도구 `masc_agents` 를 부르고 기본 URL 이 운영 서버(8935)였다. 호출이 거절되면 중단되지만 그 앞의 `masc_start`·`masc_status` 는 운영 서버에 닿았고, `masc_broadcast` 는 운영 서버 Board 에 진짜 글을, `masc_runtime_verify` 는 모든 endpoint 에 진짜 chat completion 을 보낸다. #40512 가 `MASC_URL` 을 필수로 하고(격리한 서버, 포트 9400 이상) `masc_agents` 줄을 지웠다(D14-05). 리뷰에서 `benchmark.sh` 의 빈 `bench_a2a` 가 이슈 #40514 로 남았다.
- **비용(메모리 기록 기준 추정, 코드로 확인하지 못함).** 6 arm × 24 task × 3회(432 trial)에 $7,987, 평균 trial $18.5 다. 기본값(arm a,b,c,e,f,h × 53 task × k=5, 1,590 trial)을 단순 환산하면 약 $29k 이고 상한 장치가 없다. trial 마다 올리는 바이너리(약 116MB)만 1,590 trial 에 약 184GB 다.


## 12. 운영자 결정이 필요한 것

1. **Glossary 를 짧은 정의로 줄일지.** 줄이면(권장) 항목마다 한두 문장과 코드 링크만 두고, glossary-maniac Keeper 의 지시도 같이 바꾼다. 그대로 두면 이 속도로 일주일 뒤 약 290KB 가 된다(추정). 아직 정해지지 않았다(D16a-13).
2. **라이브 `keeper` 프롬프트 override 정리.** 라이브 Keeper 26명이 저장소 `keeper.md` 대신 override 를 읽고 기본값과 6곳 다르다. 의도해서 뺀 문장 둘을 정하고, Native Stack 문장은 #40389 로 머지하고, `<board>` Vote 블록은 worldview 의 Vote 문단과 합친 뒤 override 를 지운다. 지운 뒤 부팅 WARN 이 사라지는지, wire-capture 의 system prompt 가 기본 문장이 되는지 본다(D15-01).
3. **Keeper 의 `masc_gc`·`masc_board_cleanup` 권한.** (a) `masc_gc` 만 Operator 전용으로 내린다. GC 를 부를 운영자 경로나 스케줄을 먼저 정해야 한다. (b) "되돌릴 수 없는 삭제"를 도구 descriptor 의 typed 값으로 두고 승인 정책이 그 값이면 Ask 한다. (c) 지금처럼 둔다. `masc_board_cleanup` 은 RFC-keeper-skill-peer-signal 이 Keeper 사용을 전제하고 시험이 보이는 상태를 단언한다(W1-01).
4. **판정 lane 의 슬롯.** Codex Keeper 15명에게 failover lane 을 줄지(D1-03). verifier·Board attention·Goal 검증기가 `glm-5.3-flash` 한 슬롯에 몰려 있는데 다른 provider 슬롯을 하나씩 더할지, 이미지 입력 선언을 추가할지(D1-09, D6-03, D7-02, D6-09).
5. **Board attention.** RFC #40450(판정 단위를 신호 하나로)을 구현에 옮길지와, Jev 가 `not_relevant` 로 답한 것을 다시 판정하는 것(하루 4,257번)을 어떻게 할지(D6-02, D6-10).
6. **초대 링크가 127.0.0.1 로 나가는 문제.** 보류 중이다. 권장안은 운영자가 넣은 `MASC_HTTP_BASE_URL` 만 boot 첫머리에서 따로 보관해 초대·안내 경로만 읽게 하는 것이다(D10-01).
7. **Terminal-Bench.** 설정 사전 점검(#40509)과 trial 기록의 설정 출처(#40518)를 먼저 올렸다. 다음은 이 호스트에서 task 1개 스모크(arm b, k=1, v0.48.0, 에뮬레이션 amd64)를 돌릴지(모델 호출 비용이 든다), 리더보드와 비교할 amd64 환경(Modal 등)과 그 비용, 설정 출처를 릴리스 태그로 고정할지(D14-01, D14-02), 4.0 제출 요건을 공식 문서에서 확인한 기록을 남길지(D14-04)다.
8. **TUI 멈춤 원인 가르기.** 운영 TUI 를 `MASC_TUI_FRAME_TIMING` 을 켠 채 한 세션 쓰면 프레임 쓰기와 flush 시간이 로그에 남는다. 막히면 터미널 출력을 다른 스레드로 옮기는 고침이고, 안 막히면 동기 파일 읽기를 본다(D13a-02, 이슈 #39763).
9. **웹 검색.** `masc_web_search` 가 일주일째 모든 provider 에서 실패한다. searxng(127.0.0.1:8888)는 닫혀 있고 Ollama 는 주간 한도 429 다. searxng 를 띄우거나, 쓰지 않으면 provider 목록에서 빼서 도구 설명이 실패할 도구를 광고하지 않게 한다(L2-09).
10. **운영 데이터.** `verification-runs.jsonl` 의 읽을 수 없는 19행이 원장 압축을 막고 있다. `cut-run-registries --execute` 를 정지 구간에 돌리고 네 원장은 먼저 백업한다(D6-08, L2-03). 라이브 Goal 하나의 기한이 읽을 수 없는 형식이다(D8-12). #40397 이 배포되면 DNS 로 굳은 후보 약 1,154개를 다시 큐에 넣는다.
11. **디스크.** worktree 1,041개, `.masc` 116GB, 정리하는 코드가 없는 옛 홈 약 50GB(antigravity 33.2GB, codex 17.2GB), msx saves 10.4GB, `.git` 안 실행 파일 4.7GB. 지우는 것은 승인이 필요하다(L3, D10-02).
12. **배포 전 검사 목록.** 파티션 원장, Board 댓글·투표·반응, Candle 원장을 `validate-stores` 에 더하기 전에 저장소마다 못 읽는 행이 Keeper turn 을 멈추는지(RFC §1 (c))를 먼저 정한다. 채팅은 #40402 가 `Preflight_only` 로 뒀는데 그 기준으로는 `Refuse_boot` 후보다(W3-01).
13. **일정 수정과 `result_delivery`.** TUI·대시보드에서 일정을 고치면 `result_delivery` 가 `none` 이 된다. update 에서 빠진 값은 저장된 값을 유지하게 할지 정한다. 빈도는 낮아 보인다(Keeper 가 만든 `reply_to_origin` 일정을 TUI 에서 고칠 때, D5-10).
14. **work-intake 가 Keeper 글을 빼는 의도.** work-intake 의 보드 칸이 Keeper 가 쓴 글을 전부 뺀다(D4-01).
15. **큰 파일 분리와 본체 라이브러리 분할.** `bin/masc_tui.ml` main 한 함수가 9,953줄이고 Keeper 541파일이 본체 라이브러리 안에 있다. 열린 분리 스택이 있어서 새 dune 라이브러리 경계를 RFC 로 정할지 묻는다(D16b-01, D16b-02).
16. **TUI 첫 화면 이름.** Overview·Dashboard·Home 중 하나를 고른다. 설정 값 `overview` 를 바꾸면 runtime.toml 이 깨지므로 설정 이름은 따로 정한다(D16a-11).
17. **`scripts/lint/` 에 남은 검사기 19개.** `run-lint-suite.sh` 를 지운 뒤로 이 검사기들을 돌리는 곳이 `.github` 에 없고 `scripts`·`test` 에는 서로 부르는 것뿐이다. 남길지, 지울지, 돌리는 곳을 만들지 정한다. `docs/architecture/functional-core-effect-boundary.md` 는 지운 `ocaml-boundary-ratchet.sh` 를 CI 가 돌린다고 적는데 `tools/ocaml_boundary_audit` 는 남아 있어서, 이 도구를 살릴지에 따라 문서를 고친다(D16a-06, #40517).
18. **구현된 RFC 에 남은 지운 파일 인용.** RFC-0132 표와 RFC-0240 세 곳이 지운 `keeper_rollover.ml` 을, RFC-0465 가 지운 `pr_history` 를 가리킨다. 시점 인벤토리라 줄 수와 번호가 얽혀 있어 고치지 않았다. 지운 Goal `owner` 의 RFC-0362 는 RFC-0387·0444·0446·0448·goal-candle-ledger 가 본문에서 가리켜서 한 번에 못 지운다. 옛 RFC 는 기록으로 두는지, 지운 것을 가리키는 줄을 뺄지 정한다(D16a-05).
19. **Stagehand 호출의 슬롯 시간 배분.** Stagehand 문장 하나의 마감은 120초다(`browser_stagehand_wire.ml` 의 `sentence_timeout`). Browser lane 의 첫 슬롯 `glm-coding` 은 provider 본문 마감이 1,200초이고 둘째 `ollama_cloud` 는 180초다(`runtime.toml`). 첫 슬롯이 멈추면 120초에 호출 전체가 끊겨서 둘째 슬롯은 시도도 못 한다. 활성화 뒤 `BrowserInstruct` 10건 중 8건이 120.0초에 끝났고 성공은 0건이다. 정할 것: (가) 호출 마감을 슬롯 수로 나눠 슬롯마다 준다, (나) lane 설정에 슬롯별 마감을 둔다, (다) 슬롯 순서만 바꾼다. RFC-exact-lane-walks-one-slot-list 는 슬롯 한 번의 시간 한도를 provider 의 `exact-body-timeout-s` 에 두고 "lane 전체의 시간 한도는 지금도 없고, 이 RFC 도 만들지 않는다"고 적었다. (가)와 (나)는 이 구분을 바꾸므로 RFC 에 먼저 적는다(X4-01).


## 13. 이번 감사에서 연 PR

상태는 10-01 13시 기준이다.

| PR | 상태 | 닫는 것 |
|---|---|---|
| #40359 | 머지(09-30 23:01Z) | continuity 스냅샷을 official-client 시작 상태로도 저장·복원(D2-01, D3-01, L2-01) |
| #40364 | 머지 | Codex 클라이언트가 sub-agent 를 못 띄우게 해서 프레임 신원 불일치의 원인을 줄임(D1-02, D2-03) |
| #40373 | 머지 | continuity 전용 회차가 스냅샷 거절이면 Failed 로 기록(D3-02) |
| #40427 | Ready, APPROVED | Task GC 가 archive 에 먼저 붙인 뒤 backlog 에서 지움(D6-11) |
| #40397 | Ready, 소스 리뷰 PASS | 요청이 나가기 전에 네트워크가 실패한 후보는 격리하지 않고 기다림(D6-01) |
| #40407 | Ready, 소스 리뷰 PASS | 아무것도 고르지 않는 wake 대상 resolver 삭제(D5-11, X3-03) |
| #40451 | Ready, 소스 리뷰 PASS | Board 수정·thread·고정·닫기·다시 열기·삭제 뒤 목록 캐시를 비움(D12-01) |
| #40453 | 머지 | changelog 조각 40028 에 PR 번호를 적어 릴리스 assemble 이 멈추지 않게 함 |
| #40509 | Draft, 리뷰 대기 | Terminal-Bench 를 돌리기 전에 arm 마다 서버를 띄워 arm 이 선언한 keeper 전부를 `keeper_up` 까지 올려 봄(D14-03). 적대적 리뷰의 P1·P2 를 반영했다 |
| #40512 | Ready, 소스 리뷰 PASS | `quick-bench.sh`·`benchmark.sh` 가 `MASC_URL` 을 받아야 돌고(기본값이 운영 서버였다), 없는 `masc_agents` 호출을 지움(D14-05) |
| #40510 | Ready, 소스 리뷰 PASS | Keeper 가 읽는 글에서 없는 도구와 지운 개념 삭제(D15-02, D15-03) |
| #40518 | Draft, 리뷰 대기 | Terminal-Bench trial 기록에 체크아웃 커밋·설정 sha256·effort 를 남김(D14-02) |
| #40515 | Ready, 소스 리뷰 PASS | 용어집에서 지운 일을 설명하는 문장 둘과 없는 항목을 가리키는 참조 둘을 고침(D16a-08) |
| #40516 | Ready, 소스 리뷰 PASS | 지운 Overview Team 블록이 쓰던, 아무도 읽지 않는 계산과 `keeper_phase_band` 삭제(D16a-04) |
| #40517 | Draft, 리뷰 대기 | 지운 CI 스크립트를 가리키던 문서·주석과, 읽는 곳 없는 목록 파일 3개 정리(D16a-06) |

리뷰 코멘트: 이슈 #40404(Librarian witness_line 세대 문제)에 fallback 시작 줄이 `R.select` 와 다르다는 관찰을 적었다.
