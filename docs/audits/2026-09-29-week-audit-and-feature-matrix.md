# 주간 변경 감사와 기능 표 (2026-09-22 ~ 09-29)

`origin/main` 91c24caa05(09-29 20:58 KST)을 기준으로, 09-22 00:00 KST 직전 기준 커밋(3ffc7eab09) 이후 들어온 변경을 코드와 라이브 동작으로 확인했다.
한 주에 커밋 1,566개, 파일 4,851개가 바뀌었다.
집계는 `git rev-list --count 3ffc7eab09dc8b39bf5f452ecd8891d9e867d9e0..91c24caa0537d055af7cbcd6392bd2b809e590b0`의 1,566건이다. 하한에서 도달 가능한 커밋은 제외하고 상한은 포함한 전체 도달 가능 커밋이며, §2 일별 표는 같은 범위를 KST committer 날짜로 나눈 것이다.
이 문서는 다음 세션이 같은 조사를 다시 하지 않도록 남기는 기록이다.

## 0. 읽는 법

- 발견 id 는 영역 접두어를 붙인다. `RT-` Runtime·Lane·Schedule, `MM-` Memory·Librarian·Skills·Context, `DM-` Board·Task·Goal·HITL·Candle·Play, `TU-` TUI·대시보드.
- 심각도: **P0** 기본 흐름이 지금 깨짐, **P1** 실제 결함, **P2** 정리 대상.
- "확인"은 코드 경로를 직접 따라갔다는 뜻이다. "라이브"는 `<base-path>/.masc`의 로그나 상태 파일로 확인했다는 뜻이다. 여기서 base-path는 관측 대상 서버의 유효 workspace 경로이며 `MASC_BASE_PATH` 또는 `--base-path`로 명시할 수 있다. 둘 다 아니면 "보고만"이라고 적는다.
- 로컬 빌드와 테스트는 돌리지 않았다(저장소 `execution_protocol`).
- 이 문서는 위 고정 커밋과 당시 관측의 기록이며 현재 main이나 현재 배포 상태의 검증 결과가 아니다.
- `DM-verifier` 계측 범위: 이 PR에는 재시도 집계의 원본 로그/원장 좌표, 시작·종료 시각, 중복 제거 조건, 집계 명령이 없다. 따라서 정확한 재시도 횟수와 장애 규모는 확인 불가로 표기한다. 이미지 제출 거절·확정 건수도 당시 보고 수치이며 여기서 독립 재계측하지 않았다. 슬롯 구성과 429 재시도 관측 보고를 분리해 읽고, 슬롯 변경은 횟수가 아니라 권위 있는 설정과 현재 실패 경로를 확인한 뒤 판단한다.

## 1. 기능 표

상태는 네 가지로 적는다. **동작**: 만들고, 저장하고, 읽는 길이 이어져 있고 라이브에서도 돈다. **일부**: 이어져 있지만 알려진 결함이 있다. **깨짐**: 기본 흐름이 실패한다. **미연결**: 코드는 있지만 부르는 곳이 없거나, 설계상 아직 없다.

| 기능 | 상태 | 핵심 근거 | 관련 발견 |
|---|---|---|---|
| Runtime Failover (후보 걷기) | 일부 | 403·Muse 는 리셋 시각까지 쉰다. Codex 만 15분마다 다 쓴 계정을 다시 부른다 | RT-R1, RT-R2, RT-R3, RT-R6 |
| Multi Lane / exact lane | 일부 | exact lane 5개 중 Stagehand 만 429 기억을 안 쓴다. 라이브 판정 lane `verifier_exact` 는 슬롯이 하나다 | RT-R4, DM-verifier |
| Schedule | 일부 | 실패한 turn 이 남긴 wake 를 취소·대체가 못 거둔다. TUI 에 "Next due" 가 안 보인다. TUI 에서 고치면 `result_delivery` 가 `none` 이 된다 | RT-S1, RT-S2, TU-F04, TU-F14 |
| Drain Queue (event queue) | 일부 | 회차 영수증과 signal 파일이 끝없이 쌓인다. Board 판정 미룸이 60초마다 Jev 를 다시 부른다 | RT-S3, RT-S8, DM-BD-3 |
| Keeper 한 명의 context 생명주기 | 일부 | Codex 턴 중간 compaction 뒤에도 사라진 문맥을 "보냄"으로 든다. official-client Keeper 9명의 continuity 가 09-28 새벽에 멈췄다 | RT-C2, MM-C1 |
| Librarian | 일부 | Memory 소화는 돈다(09-29 커밋 2,312건). 그중 67% 는 facts 가 그대로인데 revision 만 올린다. atom 진도는 멈춘 Keeper 가 있다 | MM-M1, MM-C1 |
| Memory 생산·합성·흡수 | 동작 | 생산·absorb(161건/일)·검색은 이어져 있다 | — |
| Memory 소거·감쇠·강화·반감기 | 미연결 | 감쇠·강화 코드가 없다. e-masc 는 한 주에 facts 54개 → 398개로 늘었다. 512 KiB 한도까지 2~3일 남은 Keeper 가 있다 | MM-M3, MM-M4 |
| Skills 재생성 | 미연결 | 되풀이된 풀이에서 Skill 을 자동으로 만드는 경로는 없다. publish·activation 은 동작 | MM-S1~S7 |
| Board | 동작 | close/reopen·moderator 는 동작. 부팅 대조의 상태 쌍 하나가 그 Keeper 의 Board 판정 전체를 멈출 수 있다 | DM-BD-1 |
| Task | 일부 | 라이브 판정 슬롯의 설정에 이미지 입력 선언이 없어 이미지 증거 제출이 멈춘다(09-29 50건). 그 슬롯 하나의 429 재시도가 보고됐다. 확정 15건은 당시 보고 수치이며, 재시도 횟수는 확인 불가(§0 계측 범위 참고) | DM-verifier |
| Goal | 동작 | 생성·측정·검증·확정 경로가 이어져 있다. owner 개념은 #39975 가 걷어내는 중 | DM-GT-01~12 |
| HITL (Gate 승인·질문) | 일부 | 웹 대시보드가 승인 대기를 하나도 못 받았다(#39991 로 수정). TUI 는 서버가 unavailable 이라 해도 "Auto Judge" 로 보인다 | TU-F01, TU-F06, TU-F08 |
| Access Control | 일부 | 모든 TUI 호출이 인증 헤더를 보낸다. 지운 Keeper 가 DOS 조작권을 서버 재시작까지 쥔다 | DM-PL-01, DM-PL-02 |
| Candle 원장 | 미연결(계획대로) | 코덱·원장은 테스트만 쓴다. 결함은 못 찾았다. 열린 스택 #39978~#39981 | DM-CD-2, DM-CD-3 |
| 논공행상 분배 | 미구현 | 분배 산식(최대 나머지)은 합이 총액과 같다. 코드는 열린 #39981 | — |
| Economy (turn spend) | 동작 | attempt 기록 → meta·cost 원장 → Usage 화면. 웹은 읽기 실패를 0 으로 그린다 | TU-F19 |
| 반감기 | 미구현 | RFC 만 있다. 헌법 개정 #39902 가 먼저다 | — |
| Portrait | 일부 | HTTP·TUI 는 동작. 메달 잘림(#39961), 보관 PNG 가 회전 캐시에 들어감(#39957) | DM-PT-1~7 |
| Item Slot / 착용 | 미연결 | 착용을 저장하는 코드가 없다. 외형은 이름 hash 로 매번 계산한다 | DM-PT-3, DM-PT-4 |
| World (Workspace) Curator | 깨짐(잠복) | 라이브 lane 이 꺼져 있다. 켜면 준비 단계가 매번 실패한다 | MM-W1, MM-W2, RT-A2, DM-BD-4 |
| Play Invite | 일부 | 발급·회수는 동작. lock 안 예외 한 번에 재시작 전까지 발급·회수가 막힌다 | DM-PL-02, DM-PL-08 |
| TUI 와이어링 | 일부 | 178개 (method, path) 호출은 모두 서버 route 에 닿는다. "못 읽음" 신호를 정상 기본값으로 그리는 곳이 여럿 있다. 키 안내와 실제 동작이 어긋난다 | TU-* |

## 2. 일자별 흐름

| 날 | 커밋 | 많이 바뀐 곳 |
|---|---|---|
| 09-22 | 187 | TUI 20+19, keeper 17, RFC 9, Glossary 8 |
| 09-23 | 337 | TUI fix 70, Glossary 50, keeper 28, Librarian 14 |
| 09-24 | 184 | TUI 31, keeper 26, Glossary 24 |
| 09-25 | 203 | TUI 36, keeper 16, RFC 8 |
| 09-26 | 156 | TUI 14, keeper 14, runtime 4, browser 4 |
| 09-27 | 138 | TUI 20+9, runtime 7, perf(tui) 6 |
| 09-28 | 209 | TUI 27+12+11, muse 10, Glossary 9 |
| 09-29 | 152 | TUI 10+7, play 5, runtime 5 |

- 줄 수로는 `docs/evidence/` 가 대부분이다. 한 주에 파일 1,042개, 70.3 MB 가 들어왔다. `raw.tar.gz` 두 개(43 MB #39412, 13.5 MB #39392)는 git 이력에 영구히 남는다.
- 코드 줄 수는 `lib/keeper` +35k, `lib/runtime` +15k, `lib/server` +12k, `dashboard/src` +13k, `bin/masc_tui*.ml` 약 +12k 순이다.
- Glossary 는 36 KB(용어 88개)에서 239 KB(용어 204개)가 됐다. 한 항목이 최대 7 KB 다.

## 3. 먼저 볼 P0·P1

### P0

| id | 결함 | 확인 | 처리 |
|---|---|---|---|
| TU-F01 | 웹 Gate 가 승인 대기 행을 전부 거절했다. 허용 키 목록에 서버가 #29256 에서 뺀 `goal_ids` 가 남아 있었고, 키 개수를 정확히 맞추게 했다 | 확인 | #39991 |
| TU-F02 | 대시보드 runtime-probe schema 가 서버가 보내는 `ok`·`idle`·`unavailable` 을 거절한다(`dashboard/src/api/schemas/runtime-probe.ts:23-29` vs `server_dashboard_http_runtime_info.ml:1191-1210`) | 확인 | #39996 |

### P1

| id | 결함 | 확인 | 처리 |
|---|---|---|---|
| DM-verifier | 라이브 `verifier_exact` 는 `glm-coding.glm-5.3-flash` 하나다. 카탈로그는 이 모델이 이미지를 읽는다고 적지만, 라이브 `[models."glm-5.3-flash"]` 에 `capabilities` 표가 없다. 적지 않은 media 입력은 false 로 닫히므로(#37435) 이미지 증거 제출은 판정 전에 거절된다(09-29 50건). 나머지는 같은 슬롯의 429 로 60초마다 다시 시도한다고 보고됐다. 확정 15건은 당시 보고 수치이며, 재시도 횟수는 확인 불가 | 코드 확인·라이브 계측 보고 | 운영자 설정 |
| RT-R1 | Codex 가 "사용량 다 씀"으로 거절하면 리셋 시각을 읽어 오고도 쉼에 쓰지 않는다. 403(#38975)·Muse(#39810) 경로만 고쳐진 N-of-M. 한 계정을 15분마다, 새 thread 약 620 KB 로 다시 부른다 | 확인·라이브 | #39997 |
| RT-S1 | 이 wake 로 시작한 turn 이 한 번이라도 있으면 "가져간 wake"로 본다. 그 turn 이 끝났는지는 보지 않는다. 실패한 turn 의 wake 는 취소·대체가 못 거두고, 취소한 schedule 이 나중에 실행될 수 있다. 판정마다 33~35 MB ledger 를 훑는다 | 확인 | #40006 |
| RT-C2 | Codex 턴 중간 compaction 은 마지막 frame 만 보고 판단한다. 그래서 사라진 문맥을 계속 "보냄"으로 들고 있다가 다음 resume 에서 뺀다 | 확인 | #39972 에 코멘트 |
| RT-C1 / MM-M2 | Codex resume 이 block 단위가 아니라 carrier 전체로 비교해 매 턴 약 170 KB 를 다시 보낸다(09-29 243 MB) | 보고만 | 열린 #39972 |
| MM-M1 | Librarian 커밋의 67% 가 facts 는 그대로인데 revision 만 올린다. recall 머리글에 revision 이 들어가 140~440 KB block 을 resume 마다 다시 보낸다(09-29 Codex 263.5 MB, Claude Code 182.6 MB) | 보고·라이브 수치 | #40001 |
| MM-C1 | Agent Core 가 atom 을 저장한 뒤 turn 끝 줄이 `no_atom_history` 로만 남으면 Librarian atom 진도가 멈춘다. pr-updater 는 turn 이 atom 15839 에서 시작하는데 진도는 15803 에 멈췄다. `librarian-continuity.json` 은 09-28 02:25 가 마지막이다 | 확인·라이브 | #40019 |
| MM-M3 | 기억이 수렴하지 않는다. 감쇠·강화가 없고 512 KiB 한도에 2~3일 안에 닿는 Keeper 가 있다 | 보고·라이브 수치 | RFC |
| DM-BD-1 | 부팅 대조에서 예상 못 한 (partition × quarantine) 쌍 하나가 그 Keeper 의 Board 판정 worker 를 멈추고, 다시 띄우지 않는다. #39784 는 한 쌍만 고쳤고 같은 표가 quarantine 명령에 복사돼 있다. 09-28 로그 279줄 | 보고·라이브 | #40003 |
| DM-PL-01 | 지우면서 멈춘 Keeper 는 만료 없는 Worker credential 이 남아 DOS 조작권을 서버 재시작까지 쥔다. 회수 route 는 409/400 | 보고 | #40045 (종료 마무리에서 풀기) |
| RT-A1 | 계정 제거 미리보기는 "removable" 인데 실제 저장은 Fusion 자리 검사로 400 이 난다 | 보고(코드 재확인은 audit) | 후보 |
| RT-A2 / MM-W1·W2 | curator 는 `cli_slots` 가 있으면 lane 전체를 거절한다. 쓰는 쪽·TUI 는 받아들인다. `max_output_tokens` 도 없다 | 보고 | curator 를 다시 켜기 전 필수 |
| TU-F04 | Schedules 의 "Next due" 가 안 보인다. 서버는 `next_due_at`, TUI 는 `next_due_at_iso` 를 읽는다. fixture 가 TUI 철자라 테스트가 못 잡는다 | 보고 | #39998 |
| TU-F11 | 거절 응답 모양이 넷인데 TUI 공용 reader 는 하나만 읽는다. #39877 은 play 하나만 고친다(N-of-M) | 보고 | `Server_refusal` 스택, 1단계 #40050 |
| TU-F06·F07·F08 | Overview 가 판정 ledger 를 못 읽어도 "판정 없음"으로 그린다. Gate lane 이 unavailable 이어도 "Auto Judge" 로 그린다. Keeper 상세가 실제로 적용되는 Gate 모드 대신 저장된 override 를 보여 준다 | 보고 | 후보 |
| TU-F03·F16 | Chat 의 `Ctrl-T:queue` 는 마우스 토글이 먼저 잡는다. Patch 창의 두 번째 `q` 는 앱을 끈다 | 보고 | RFC(아래 4-3) |

발견표 152행은 [발견 목록](2026-09-29-week-audit-findings.md)에 있다. 위치가 있는 행은 file:line을 적었으며, MM-W6~W10 묶음 행은 위치 미확인 보고다.

## 4. 되풀이되는 원인

한 주의 결함 대부분이 아래 다섯 모양 중 하나다. 한 곳씩 고치면 같은 모양이 다시 생긴다.

### 4-1. "못 읽음"을 정상 기본값으로 그린다

- 서버는 `ledger_error`·`state`·`read_error`·`unreadable_total`·`quarantined`·`metrics_read` 로 "못 읽었다"를 따로 보낸다.
- 클라이언트 decoder 는 모르는 값이나 빠진 키를 `None`·`false`·`0`·"ok" 로 받는다. TUI 와 웹을 합쳐 10곳이 넘는다(TU-F04, F05, F07, F08, F13, F17, F18, F19, F21, F27, F38, F41).
- TUI 는 읽기 상태를 `*_error : string option` 쌍 59개로 들고 있다. 공용 `Masc_tui_fetched` 를 쓰는 필드는 12개뿐이고, 같은 합타입을 모듈마다 5번 새로 만들었다(TU-F56). 이번 주 "안 읽음이 0 으로 보임" 수정 약 17건, "이유를 두 번 씀" 약 12건이 여기서 나왔다.
- 테스트는 서버 인코더가 아니라 손으로 쓴 fixture 로 돈다. 그래서 서버와 다른 철자가 서로 맞는다(TU-F01, TU-F04). wire 모양 수정 약 15건이 이 때문이다.
- 근본 수정(RFC): 서버 인코더가 테스트용 JSON fixture 를 만들고 TUI·웹 decoder 테스트가 그것을 읽는다. 읽기 상태는 모두 `Masc_tui_fetched.t` 로 옮긴다.
- 근본 수정: fixture 를 서버 인코더로 만든다. decoder 는 빠진 키를 `Error` 로 돌려준다. 헌법 `strict_parse_no_default` 를 클라이언트에도 적용한다.

### 4-2. N-of-M: 같은 규칙을 한 곳만 고친다

- 하나의 규칙이 여러 곳에 있고, PR 은 그중 한 곳만 고친다.
- 사례:
  - Codex 만 빠진 host 종료 로그(#39983 으로 정리)
  - Codex 만 빠진 리셋 시각 쉼(RT-R1)
  - Stagehand 만 빠진 429 기억(RT-R4)
  - 한 쌍만 고친 Board reconcile(DM-BD-1)
  - play 만 고친 거절 모양(TU-F11)
  - Claude Code 만 연결된 block 단위 held(RT-C1)
- 근본 수정: 규칙을 공용 모듈의 함수 하나로 두고 모든 경로가 그것을 부른다. 새 경로를 더할 때 컴파일러가 강제하도록 필수 인자나 exhaustive match 로 만든다.

### 4-3. TUI 키 안내와 실제 동작이 따로 산다

- 키 바인딩 표에는 "무슨 동작"이 없다. 실제 동작은 대소문자를 접어 가며 순서대로 비교하는 별도 match 가 정한다.
- footer 를 만드는 자리는 약 57곳이다. `render.ml` 에는 손으로 쓴 안내 문자열 36개와 자체 안내 builder 10여 개가 있다.
- 이번 주 bin 의 `fix(tui)` 중 약 26건이 이 어긋남을 한 곳씩 고친 것이다. 예: #39945 #39799 #39044 #39531 #39024 #39063 #39162 #39818. 폭·자르기·열 빼기 수정도 약 30건이고, `detail_heading` 은 하루에 같은 원인으로 4번 고쳤다(#39684→#39698→#39712→#39720).
- 근본 수정(RFC): 바인딩을 `{ keys; action }` 로 만들고, 상태에서 문맥 하나를 계산해 그 문맥으로 키를 분류한다. footer 는 그 표를 그린다. 모든 문맥에 대해 "footer 의 키는 모두 동작한다, 중복이 없다, 동작하는 키는 모두 footer 에 있다"를 한 번에 검사한다.

### 4-4. 같은 내용을 매 턴 다시 보낸다

- 두 원인이 겹친다. 하나는 Librarian 이 facts 가 그대로여도 revision 을 올리는 것이다(MM-M1). 다른 하나는 digest 가 block 단위가 아닌 lane 이 있는 것이다(RT-C1).
- 09-29 하루 resume 재전송은 Codex 263.5 MB, Claude Code 182.6 MB 다.
- 기억 자체도 수렴하지 않아(MM-M3) 한 block 이 계속 커진다.

### 4-5. 쉼과 대기 상태가 프로세스 메모리에만 있다

- 리셋 시각까지 쉰다는 기록은 재시작하면 사라진다(RT-R6).
- 09-29 에 부팅이 20번 있었다. 부팅 직후마다 다 쓴 계정이 한 번씩 다시 거절당했고, 새 세션 사유 1위는 `provider_rejected` 152건이다.

## 5. 시간축(1 → N tick)

| 고리 | 1 tick | N tick | 닫힘? |
|---|---|---|---|
| Codex 다 쓴 계정(RT-R1) | 거절 → `Observed` | 15분마다 같은 계정 start ~620 KB, 제공자 리셋(10-04)까지 | 열림 |
| lane 걷기(RT-R2) | 머리 후보 쉼 | 쉼이 끝날 때마다 리셋 시각을 말한 후보까지 전부 다시 부름. 09-27 이미 쉬는 Kimi 를 183번 부름 | 열림(설계 대기) |
| schedule wake(RT-S1) | turn 시작 기록 | ACK 없이 끝난 turn 마다 pending +1 | 열림 |
| 회차 영수증·signal(RT-S3·S8) | 파일 1개 | 끝난 회차·하루마다 증가, 지우는 코드 없음 | 열림 |
| Librarian 커밋(MM-M1) | revision +1 | 67% 가 내용 없이 revision 만 증가, resume 재전송 | 열림 |
| 기억 크기(MM-M3) | fact 추가 | 감쇠 없이 증가, 512 KiB 한도 도달 후 range 보류·continuity 막힘 | 열림 |
| atom 진도(MM-C1) | 끝 줄 `no_atom_history` | 진도 고정, continuity 고정 | 열림 |
| Board 판정 미룸(DM-BD-3) | lane 쉼 → Ready | 60초마다 Jev 재호출. 09-29 `deferred_lane_exhausted` 12,974건 대비 drained 1,037건 | 반쯤(비쌈) |
| 후보 backpressure 셀 | 실패 기록 | 성공이나 힌트 기한으로 지워짐 | 닫힘 |
| Muse 429 루프 | — | #39810 뒤 09-29 01Z 60건 → 1건 | 닫힘 |
| Codex shrink ladder | — | 09-26 212회 → 09-29 1회 | 닫힘 |
| turn_record 엄격 reader | 버전 다른 행 거절 | 같은 행을 읽을 때마다 경고. 09-27 127,704줄, 09-29 08:10Z 이후 0 | 닫힘(배포 뒤) |

## 6. 낭비

| 종류 | 크기(09-29) | 원인 |
|---|---|---|
| resume 재전송 | Codex 263.5 MB, Claude Code 182.6 MB | MM-M1, RT-C1, RT-C3 |
| 다 쓴 Codex 계정 재호출 | 3 Keeper × 15분 × ~620 KB | RT-R1 |
| 판정 슬롯 429 재시도 | 횟수 확인 불가 | 슬롯 하나(설정) + 리셋 시각 미사용 |
| Board 판정 미룸 재호출 | Jev 답 11,910회 / 후보 1,682개 | DM-BD-3 |
| 무의미한 WARN | Codex host 종료 123줄(#39983 로 정리), turn_record 09-27 127,704줄 | 로그 분류 |
| TUI 폴링 | tool-approvals·gate·turns·schedules 를 어느 화면에서든 2초마다 다시 읽고 decode, 조건부 GET 없음 | TU-F55, 비용은 아직 안 잼 |
| 로그 부피 | 하루 100~127 MB | INFO `shell_ir dispatch` 21,643줄 등 |
| 저장소 | `docs/evidence/` 한 주 70.3 MB, tar.gz 56.5 MB | 증거 원본을 git 에 넣음 |

## 7. 와이어링 누락

- 이번 주 추가됐지만 TUI·대시보드 어디서도 부르지 않는 route(TU-F53): `gate/keeper-shims`(#39830), `board/close`·`reopen`(#39479), `goals/measurements`(#38784), `keepers_bulk/event-queue`(#39514), working-context·source-retractions(#37594), `dos/step`(#39726). 도구나 MCP 로만 쓰려는 의도라면 그렇다고 적어야 한다.
- 쓰기만 하고 읽지 않는 값: `events_unreadable_lines`(TU-F27), #39189 가 더한 취소 필드(인코딩 안 됨), 라이브 runtime.toml `[health]`(RT-A6).
- 부르는 곳이 테스트뿐인 함수: `cancel_scheduled_wakes_result`(RT-S7), `fetch_keeper_chat_operation`(TU-F52). 입력을 그대로 돌려주는 stub: `resolve_keeper_wake_target`(RT-S6).
- workspace route 가 두 번 등록된다(`server_routes_http.ml:22`, `:43`, TU-F54).

## 8. 도메인 결합

- Karma·Candle·turn spend 는 입력도 코드도 따로라 같은 개념이 아니다. 합치지 않는다.
- Goal ← Candle 은 방향이 맞다(Candle 이 step callback 으로 들어온다). 다만 확정 step 의 Error 가 Goal 완료를 막는 것은 Candle 이 Goal 완료 조건에 끼어드는 것이다(DM-GT-02, #39978 의 복구 1회 문제와 같은 뿌리). 운영자 결정이 필요하다.
- Play ↔ Keeper 는 얽혀 있다. "누가 앉아 있나"를 두 곳이 판단한다. Keeper lifecycle 이벤트(`Keeper_removed`) 하나로 Seat 가 받게 하면 DM-PL-01 도 같이 닫힌다.
- 09-23 감사가 제안한 결합 해소 5건은 하나도 닫히지 않았다. Schedule 소비자는 Keeper 내부 모듈을 이름으로 96번 부른다(`Keeper_event_queue_state` 49번).

## 9. Glossary

- 파일 링크 209개는 모두 살아 있고, 모듈 이름도 거의 다 코드에 있다. `scripts/check-doc-truth.sh` 가 지킨다.
- 문제는 크기다. 한 주에 6.6배가 됐고, 한 항목이 wire 필드·route·PR 번호(97개)까지 담는다. 용어집이 아니라 설계 문서가 됐다. 같은 내용이 `.mli` 에도 있어서 둘이 어긋날 자리가 두 배다.
- 결정이 필요하다. (A) 항목을 "한두 문장 정의 + 코드 링크"로 줄이고 상세는 `.mli` 에 둔다. (B) 지금 형태를 유지한다. glossary-maniac Keeper 가 이 파일을 계속 늘리고 있어서, A 를 고르면 그 Keeper 의 지시도 바꿔야 한다.
- 정의가 없는 말: `Access Control`, `Keeper Owner`(09-23 감사 지적, 아직 없음).

## 10. 운영자 결정이 필요한 것

1. 라이브 `verifier_exact` 설정. 두 가지 중 하나를 고른다.
   - `[models."glm-5.3-flash".capabilities]` 에 `supports-image-input = true`, `supports-multimodal-inputs = true` 를 적는다. 카탈로그는 이 모델이 이미지를 읽는다고 적는다.
   - 저장소 기본 설정처럼 이미지 입력을 선언한 두 번째 슬롯을 더한다. 기본 설정은 `deepseek-v4-1-flash` 가 이미지 입력을 선언해 이미지 제출이 그쪽으로 넘어간다.
   이미지가 판정기까지 닿게 고친 뒤([verifier-image-evidence-ingress](verifier-image-evidence-ingress.md))부터 이 차이가 드러났다. 슬롯이 하나라서 429 때도 넘어갈 곳이 없다.
2. 제공자가 리셋 시각을 말한 후보를 걷는 도중 건너뛸지(RT-R2, RFC-provider-path-rest Phase 2, #39190 과 같은 질문).
3. 쉼 기록을 재시작에도 남길지(RT-R6).
4. 기억 수렴 경계(MM-M3). 감쇠를 둘지, 한도를 설정으로 옮길지.
5. Candle 확정 step 이 Goal 완료를 막아도 되는지(DM-GT-02·04, #39978 CD-3).
6. Glossary 를 짧은 정의로 되돌릴지(9절).
7. `docs/evidence/` 에 원본 tar.gz 를 넣지 않는 규칙을 둘지.
8. TUI 키 바인딩 RFC(4-3).

## 11. 이번 감사에서 연 PR

| PR | 닫는 것 |
|---|---|
| #39983 | Codex host 종료를 실패 대신 종료로 적음(N-of-M 정리) |
| #39991 | 웹 Gate 승인 대기 표시(TU-F01, P0) |
| #39996 | 대시보드 decoder 셋: runtime-probe 상태 단어(TU-F02, P0), async-requests `request_context`(TU-F17), 채팅 delivery kind(TU-F18) |
| #39998 | TUI Schedules·Agenda 다음 일정(TU-F04) |
| #39997 | Codex 사용량 거절 뒤 리셋 시각까지 쉼(RT-R1). 소진된 limit 이 여럿이면 쉼을 정하지 않음. Fusion 경로는 남음 |
| #40001 | facts 가 그대로인 Librarian pass 는 snapshot·revision 을 새로 쓰지 않음(MM-M1 근본) |
| #40003 | Board 판정 reconcile 쌍을 한 분류로, 불일치는 그 구역만 Blocked(DM-BD-1) |
| #40006 | schedule 취소·대체가 실패한 turn 의 wake 도 거둠, dispatch 직전 철회는 그 source 만 뺌(RT-S1) |
| #40019 | 끝 줄 없이 저장된 atom 도 다음 turn 의 시작 위치까지 읽음(MM-C1) |
| #40000 | RFC: 클라이언트 decoder 는 서버가 쓴 fixture 로 시험 |

리뷰 코멘트: #39972(RT-C2), #39928(DM-CD-2), #39978(DM-CD-2·CD-3).
