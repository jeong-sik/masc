# D-economy 감사 (Candle · 지급 · 초상화 · 아이템 · Play/DOS/MSX · Workspace Curator)

기준: origin/main (읽는 시점 b99c9d77b5, 브리프의 fb5344a25a 보다 조금 앞). 코드 읽기만 했고 아무것도 실행/수정하지 않았다.
라이브 데이터는 ~/me/.masc 의 개수·크기만 봤다. "World Curator" 는 코드에 그 이름이 없어서 `Workspace_curator`(workspace memory curator) 로 읽었다. 틀렸다면 알려 주세요.

## 1. 영역 지도

- Candle 돈 (lib/candle, candle_store, candle_config, candle_runtime): 원장 `.masc/candle-ledger.jsonl` 한 파일이 정본이다. 잔액·소유·착용은 파일에 따로 저장하지 않고 매번 처음부터 재생한다 (`Candle_balance.of_events`).
  - 이벤트 12종: Half_life_set, Snapshot, Payout_owed, Candidates, Unattributed, Paid, Purchased, Granted, Gifted, Gifted_item, Equipped, Payout_failed (`candle_event.ml:28-62`).
  - 쓰는 곳: 목표 검증기(Snapshot, Payout_owed), 지급 일꾼(Candidates, Paid), 키퍼 도구 5개(구매·장착·선물·잔액·카탈로그), 운영자 CLI `masc_candle_grant`.
- 지급 파이프라인 (논공행상): 목표 통과 → Snapshot → 운영자 확정 → Payout_owed → Candidates(완료 Task 담당 키퍼) → Opus 평가 3단계(등급, Task별 관련성, 키퍼별 가중치) → 산술(`candle_math`) → Paid 한 줄. 일꾼은 60초 maintenance tick 의 `pulse` 와 이벤트 `wake` 로 돈다 (`server_bootstrap_maintenance.ml:14,796`).
- 반감기: 발행 일정(issuance halving)은 없다. "half_life" 는 잔액 지수 감쇠 설정이다 (`candle_decay.ml`). 라이브는 `half_life = "off"`.
- 아이템: 타입 variant 18종 (`keeper_portrait_item.ml`), 가격은 `candle.toml [shop.prices_milli]`. 구매는 키퍼당 아이템당 1회.
- 초상화: `keeper_portrait_*` 렌더러(draw.ml 1352줄) + HTTP PNG (`server_dashboard_http_keeper_portrait.ml`, 8 MiB 바이트 예산 캐시) + TUI 모자이크.
- Play/DOS/MSX: 초대 = `Player` 역할 만료 토큰 (링크 `#token`), 좌석(`play_seat`), 패드(`play_pad`), 컨트롤러 인계(`keeper_dos_controller`). 머신 lane 은 호출 때만 돈다. 백그라운드 루프 없음.
- Workspace Curator (`server_workspace_memory_curator.ml`): 키퍼 메모리 커밋 알림이나 lane 설정 변경이 깨우면, 새 사실을 이웃 사실과 함께 모델에 보내 claim/conflict 로 분류한다. 라이브는 glm-5.3-flash.
- 키퍼 핵심 코드와의 결합: `keeper_candle_tools.ml`, `keeper_tool_surface.ml:95` (키퍼 목록에 장비 끼움), `keeper_tool_descriptor.ml:3066-3072`. 이 정도라 좁다.

## 2. 7일 흐름

- D-7→D-6 (09-29→09-30, 14커밋): Candle 이 사실상 이 구간에 새로 들어왔다. 설정 로더, Snapshot, Payout_owed, Candidates, 지급 산술을 "Canonical foundation" 으로 다시 짠 리팩터(#40004), 구매 레이어를 두 번 복구(`581bfafc0b`, `d5dc7c068f`). Play 쪽은 초대 링크를 받은 에이전트 착석, 자격증명 갱신과 컨트롤러 복구의 직렬화.
- D-6→D-5 (09-30→10-01, 10커밋): 지급 산술 보존(#40392, #40066), 영구 거절된 평가가 pulse 마다 재시도되던 것 막기(#40566), 정확한 지갑 잔액·공급량 표시(#40024), 아이템 장착(#40010), 계정/초상화 뷰를 현재 워크스페이스에 묶기(#40393). Play 는 현재 자격증명 해석과 대상 자격 직렬화(#40395, #40577).
- D-5→D-4 (10-01→10-02, 8커밋): 평가 실패 분류가 또 고쳐졌다 (#40581 영구 실패 분류, #40670 평가 lane 바뀐 뒤 복구, #40595 닫힌 variant 로). 지급 기록과 영수증 재생 수리(#40302), 비활성 상태에서 빚 보존(#40303).
- D-4→D-3 (1커밋): 초상화 얼굴 아이콘만.
- D-3→D-2 (2커밋): 등급·분배 정책을 candle.toml 로 설정화(#40848), 요청 거절을 execution rejection 으로 분류(#41008).
- D-2→D-1: 이 경로 커밋 없음.
- D-1→HEAD (10-05→10-07, 11커밋): 운영자 Granted(#41371), 키퍼 간 돈·아이템 선물(#41409), 시험에서만 쓰던 함수 3개 삭제(#41325), 상점 JSON 한 곳으로(#41461). curator 는 설정 공개 뒤 재개 수리 3건(#40902, #41000, #41178). Candle 라이브 시작은 10-06 (`candle.toml` 주석, 원장 첫 행 10-06 07:52Z).
- 변화량: candle 경로는 7일간 54파일 +4866/-20 (사실상 신규), candle/play/portrait 테스트 +16126/-488. `fix(candle)` 커밋 22개.
- 이탈(churn): 같은 곳(지급 평가 실패 분류 + 지급 영수증 산술)을 D-6~D-4 사이에 최소 8번 고쳤다 (#40066 #40392 #40302 #40303 #40566 #40581 #40670 #40595 #41008). 아래 D3 에서 뿌리를 짚는다. Play 컨트롤러/자격증명 경합도 5번 (#39986 #40395 #40577 #40896 #41001).

## 3. 기능 매트릭스

| 기능 | 정상 경로 | 경계·코너 | N-Tick 순환 | 관측성 | TUI 연결 | 테스트 | 판정 | 근거 | 제안 | 크기 |
|---|---|---|---|---|---|---|---|---|---|---|
| Candle 원장·잔액 (지갑, issue/burn/supply) | 재생으로 잔액·발행·소각 계산, 발행-소각=유통 (`candle_balance.ml:92-98`) | 행 하나 잘못되면 전체 재생 실패 → Candle 전체 Disabled | 닫힘 (공급 보존 성립: 감쇠·구매는 burn, 선물은 이동) | 공급량 표시, 읽기 오류는 문장으로 | `masc_tui_candle.ml` 공급 3줄 | 예시 테스트 18건, 속성(무작위 N연산) 테스트 없음 | 정상 | candle_balance.ml, test_candle_balance.ml:84-135 | 둠. 보존 속성 테스트 추가 | S |
| 반감기(감쇠) | 구간별 128비트 정확 연산, Half_life_set 경계에서 먼저 advance | 매 구간 내림이라 접촉 횟수에 따라 1 milli 단위 차이, 재생은 결정적 | 라이브는 off 라 실질 미가동 | 없음 | 없음 | decay/math 테스트 있음 | 정상(미가동) | candle_decay.ml:44-77 | 둠 | - |
| 지급 (논공행상) | Paid 한 줄에 분배 전체 기록, 목표당 1회 (`paid_goals`) | 같은 goal_id 는 재통과해도 다시 안 줌. due_date 못 읽으면 영구 Failed | 닫힘이 의도, 평가 실패 재시도는 열림 (D3) | 일꾼 로그 4종, run 영수증 | 거의 없음 | payout 32, worker 18건 | 의심 | candle_payout.ml, candle_appraise.ml, 라이브 평가 run 0건 | 평가 분류 정리 (D3), 라이브 1건 증명 | M |
| 후보·평가 근거 | 완료된 연결 Task 의 담당 키퍼만 후보 | 근거는 제목뿐 (목표 title/metric/target, Task title) | 닫힘 | Candidates 행에 Task 상태 보존 | 없음 | 있음 | 의심 | candle_payout.ml:150-175, candle_appraisal.ml:30-34 | 근거 범위가 충분한지 운영자 판단 필요 | - |
| 구매·상점 | 가격은 설정, 중복 구매 거절, 부족 거절 | 0원 아이템이 있음, 가격 변경은 과거 기록에 영향 없음 | 닫힘 (아이템당 1회) | 에러 코드 분류 | 아이템 패널 | purchase_flow 있음 | 정상 | candle_shop.ml:79-110 | 둠 | - |
| 402 처리 | provider 402 = 요청 거절로 분류, pulse 재시도 안 함 | Candle 의 402 가 아니라 평가 lane provider 의 결제 필요 | 일꾼은 이벤트 대기 | run 영수증 | 없음 | classify 테스트 있음 | 정상 | server_candle_appraiser.ml:67,106 | 분류 로직은 D3 | - |
| 선물(돈/아이템, #41409) | 이동은 공급 불변, 중복키 (보낸이,받는이,reason) | 받는 이름이 실재 키퍼인지 검사 안 함 (D2), reason 길이 제한 없음 | 닫힘 | 에러 코드 | 없음 | gift 22건 | 결함 | candle_gift.ml:58-109, keeper_candle_tools.ml:134-151 | 받는 키퍼 존재 검사 추가 | S |
| 운영자 grant | (키퍼,reason) 중복키로 재실행 안전 | `--base` 없으면 cwd 기준 (candle.toml 이 있는 cwd 일 때만 성공) | 닫힘 | 영수증 출력 | 없음 | grant_cli 있음 | 정상 | masc_candle_grant.ml:88-95 | 둠 | - |
| 장착(아이템 슬롯) | 소유+슬롯 일치만 허용, 같은 선택은 기록 안 함 | 선물로 받은 아이템 장착 해제 처리 있음 | 닫힘 | changed 플래그 | 아이템 패널 | 있음 | 정상 | candle_balance.ml:215-246 | 둠 | - |
| Candle 가용성 게이트 | 평가 lane 이 풀려야 Enabled | 구매·선물·장착·잔액·장비 읽기까지 평가 lane 상태에 묶임 (D1) | 열림 (lane 장애 = 지갑 장애) | Disabled 사유 표시 | "Candle disabled" 로 보임 | status 테스트 있음 | 결함 | candle_status.ml:62-66, candle_shop.ml:53, candle_gift.ml:37, candle_equipment.ml:30 | 읽기·상점은 `for_recording` 계열로 | S |
| 초상화 렌더·HTTP | 이름→몸, 원장→장비, PNG 캐시(8MiB, etag) | 요청마다 원장 전체 재생, 캐시는 그 뒤 | 닫힘 (바이트 예산 eviction) | etag, 오류 코드 | 모자이크, 채팅 | portrait 3종 + pty | 정상 | server_dashboard_http_keeper_portrait.ml:129-143, 217 | 둠 (원장 재생 캐시는 후순위) | S |
| 아이템 계정 HTTP | `expected_workspace` 로 다른 워크스페이스 거절(409) | 파라미터가 선택이라 안 주면 검사 안 함 | 닫힘 | account_revision(SHA) | TUI/대시보드 모두 파라미터 보냄 | 있음 | 정상 | server_dashboard_http_keeper_items.ml:44-58, bin/masc_tui.ml:3698, dashboard keeper-items.ts:8 | 서버에서 필수화 검토 | S |
| Play 초대 | 만료 필수 Player 토큰, 링크 `#` 뒤에 토큰, 이름 충돌 검사 | 키퍼 이름은 파일명 기준으로 비교 | 닫힘 (만료·폐기) | 목록 API | 초대 화면 | invite 16, routes 있음 | 정상 | play_invite.ml:71-102 | 둠 | - |
| 컨트롤러 인계(DOS) | 키퍼/자격증명 이탈 시 다음 이동에서 풀림 | 계속 Running 인 키퍼가 쥐고 있으면 유휴 제한 없음 | 열림 (유휴 임대 없음) | 발표(announce) | 있음 | 있음 | 의심 | keeper_dos_controller.ml:25-29 (설계 주석), tool_misc_dos_lane.ml 에 lease/idle 없음 | 운영자 해제로 충분한지 판단 | M |
| DOS/MSX lane | 호출 단위, 단계 수 상한 (DOS 4,000,000, MSX 300프레임) | 활성 꺼도 상태 유지(#41199) | 닫힘 (루프 없음) | 화면 변화 | MSX tick | 있음 | 미확인 (깊이 안 봄) | dos_lane.ml:73, msx_lane.ml:55 | - | - |
| 패드 레이아웃 | 워크스페이스 TOML 우선, 내장은 삼국지3 하나 | 게임 이름이 lib 에 박혀 있음 | 닫힘 | 파싱 오류 문장 | 플레이 페이지 | 있음 | 정상(하드코딩 1건) | play_pad.ml:172-209 | 내장을 워크스페이스 파일로 | S |
| Workspace Curator | 메모리 알림→사실 분류→원장 저장 | 모델이 일부 사실을 빠뜨리면 실패 (10-07 완료 87회 중 19회 실패) | 천천히 닫힘 (밀린 사실 4874→3823, 시간당 약 -75) | run 영수증 | 있음 | 있음 | 의심 | 아래 D6, 낭비 1 | 이웃 사실 상한·점수 컷 | M |

판정 집계: 정상 9 · 의심 4 · 결함 2 · 미확인 1 (행 16개, 일부 합산).

## 4. 결함 목록

**D1 (P2, 신뢰도 높음) 평가 lane 이 풀리면 지갑·상점·장착·장비 읽기도 같이 꺼진다.**
- 위치: `candle_status.ml:62-66` `configured` 가 `appraiser_check`(= `Server_candle_appraiser.available`, 평가 lane 해석 성공 여부)를 요구한다. 이것을 쓰는 곳은 `candle_shop.ml:53`(구매·카탈로그), `candle_gift.ml:37`, `candle_equipment.ml:30`, `observed_view` 가 부르는 `enabled`(읽기 경로 전부, 키퍼 목록 장비 `keeper_tool_surface.ml:95` 포함).
- 시나리오: Exact lane 을 끄거나(#41162 는 설정은 남기고 새 작업만 막음) `candle_appraiser` slot 이 admitted 되지 않으면, 키퍼의 `keeper_candle_purchase/gift/equip/balance` 가 `candle_disabled` 로 거절되고 키퍼 목록 초상화가 Unavailable 이 된다. 구매·선물·장착은 평가가 필요 없다.
- `candle_grant.ml` 주석이 이미 "a gift needs no appraisal" 이라며 `for_recording` 을 쓴다. 같은 이유가 나머지에도 맞다.
- 최소 수정: 평가가 필요한 지급 일꾼만 `configured` 를 쓰고, 상점·선물·장착·읽기는 `for_recording` 계열로 바꾼다.

**D2 (P2, 신뢰도 높음) 선물은 받는 이름이 실재하는 키퍼인지 검사하지 않는다.**
- 위치: `keeper_candle_tools.ml` 의 Gift 분기는 `Keeper_name.of_string` 으로 문법만 본다. `candle_gift.ml` 에도 존재 검사가 없다. `candle_tasks.ml` 에 `is_keeper` 가 이미 있다.
- 시나리오: 키퍼(LLM)가 이름을 오타내서 `gift {to:"rondoo", amount_milli:700, reason:"thanks"}` 를 부르면 성공 영수증이 나오고, 돈은 아무도 못 쓰는 지갑으로 간다. 되돌리기 없음. 공급량에는 계속 "유통" 으로 잡힌다. 아이템 선물(`gift_item`)도 같다.
- 최소 수정: 선물 대상이 키퍼 디렉터리에 있는지 `Candle_tasks.is_keeper` 로 확인하고 `Invalid_gift` 로 거절한다. grant CLI 에도 같은 검사.

**D3 (P2, 신뢰도 중간) 지급 평가 실패 분류가 불리언 세 개와 기본값으로 되어 있고, 같은 곳이 8번 이상 고쳐졌다.**
- 위치: `server_candle_appraiser.ml` 의 `execute_http` 안 `rejected/retryable/refused` ref 3개, `terminal_error` 마지막 `else Execution_rejected`.
- 시나리오 1: provider 402(`Payment_required`)는 `request_refused` 에서 true 라서 "이벤트가 올 때까지 대기" 가 된다. 결제를 복구해도 깨우는 이벤트가 없다. 깨우는 것은 지급 확정, 프롬프트 override(`server_prompt_override_mutation.ml:21`), lane 선언 변경(`appraiser_declaration_changed`)뿐이다. 서버를 다시 띄우기 전까지 그 목표 지급이 멈춘다 (코드 읽기 근거, 실제로 겪은 적은 없음).
- 시나리오 2: `Retry_later` 는 등급, Task별 관련성(N번), 가중치를 처음부터 다시 부른다. 단계 결과를 저장하지 않는다 (`candle_appraise.ml` `decide`). 마지막 단계 실패가 반복되면 호출 2+N 번이 60초마다 헛돈다.
- 뿌리: Exact 가 원인을 variant 로 주는데 여기서 불리언 3개로 다시 접는다. 분류를 `Exact` 의 disposition 한 곳에서 하고 일꾼 스케줄 정책 variant 하나로 받고, 기본 분기를 없애는 게 맞다. `software-development.md` 의 "두 번째 fix → 근본 수정" 규칙을 이미 넘겼다.

**D4 (P3, 신뢰도 높음) "읽기 전용 관측은 정책을 발행하지 않는다" 는 용어집 문장과 코드가 다르다.**
- `keeper_candle_balance` 는 `Candle_shop.account` → `Candle_status.current_view` → `Candle_ledger.update` 로 가고, 설정의 half_life 가 원장과 다르면 `Half_life_set` 행을 쓴다. 그래서 `keeper_tool_descriptor.ml:3068` 에서 `~readonly:false` 다.
- 영향은 정책이 바뀐 직후 첫 호출 한 번이다. 용어집(`00-glossary.md` 잔액 감쇠 규범 항목)이나 코드 중 하나를 고쳐야 한다.

**D5 (P3, 신뢰도 높음) 초상화(그림)가 돈 원장의 재생 성공에 의존한다.**
- `Candle_equipment.read_persisted` 는 원장 전체를 읽고 잔액까지 재생한 뒤 장비만 쓴다. 재생이 깨지면 모든 키퍼의 초상화 API 가 503(`Lookup_failed`)이다.
- 행은 쓸 때 검증되므로 확률은 낮다. 영향 범위가 크다. 장비(소유·착용)와 돈(잔액·감쇠) 재생을 나누면 끊긴다.

**D6 (P2, 신뢰도 높음, 라이브 근거) curator 가 약 9분마다 884 KB 프롬프트를 24시간 돌리고, 완료 실행의 약 22%가 실패한다.** 5장 낭비 1 참고.

**D7 (P3, 신뢰도 중간) 돈 선물의 중복키가 reason 문자열이다.**
- `candle_balance.ml` 의 `Gift_key = (보낸이, 받는이, reason)`. 같은 사람에게 같은 이유로 두 번째 선물을 하면 `Duplicate_gift` 로 영구 거절된다. 키퍼가 매번 고유한 reason 을 지어내야 한다. reason 길이 제한도 없어서 원장 한 줄이 임의로 커질 수 있다 (`candle_gift.ml`).
- 멱등 키(요청 id)와 설명(reason)을 나누는 게 맞다. 지금은 한 필드가 두 뜻이다.

**D8 (P3, 신뢰도 중간) 컨트롤러 유휴 임대가 없다.** `keeper_dos_controller.ml` 헤더 주석의 규칙으로는 Running 키퍼가 쥔 컨트롤러가 그 키퍼의 `pass` 나 운영자 해제 없이는 초대 플레이어에게 넘어가지 않는다. `tool_misc_dos_lane.ml` 에 lease/idle 개념이 없는 것을 grep 으로 확인했다. 의도일 수 있어서 확인이 필요하다.

## 5. 낭비

1. **curator 이웃 사실 전송 (가장 큼).** 라이브 10-07 00:00~14:20, 88회 시작, 평균 559초, 연속 가동.
   - 실행당 프롬프트 약 884 KB (사실 약 20개, 모델 호출 1번). 이 중 이웃 사실이 약 1.1 MB/1.75 MB (기록 파일 기준)이고 새 사실 본문은 약 20 KB 라서, 바이트의 약 97%가 이웃이다. 기록 파일은 `actual_input` 과 `prompt.rendered` 가 같은 내용을 두 번 담아서 프롬프트의 약 2배 (1.75 MB) 다.
   - 원인: `workspace_memory_request.ml` 이 사실마다 이웃을 `neighbor_limit = 키퍼수-1`(약 28) 개까지 BM25 점수 컷 없이 채운다 (`server_workspace_memory_curator.ml` 의 `run` 이 `owner_count - 1` 을 넘긴다).
   - 규모: 밀린 사실이 4874(00:26)에서 3823(14:19)으로 줄었다. 시간당 순감소 약 75개라서 다 비우는 데 약 50시간 걸린다 (새 사실이 시간당 약 20개 들어오는 것을 반영한 값). 10-07 하루 기록된 입력 합계는 약 153 MB.
   - 실패: 완료 87회 중 19회 실패. "모든 사실을 한 번씩 분류해야 한다" 12, 실행 오류 6, 모르는 claim 1. 취소 4회는 별도. 같은 묶음을 다음 실행이 다시 보낸다. 실패 한 번이 약 9분과 884 KB 다.
   - 제안: (a) 이웃은 점수 컷과 사실당 상한 3~5 로 줄이고, (b) 빠뜨린 사실만 다시 요청하고, (c) 기록 파일의 중복 필드 하나를 없앤다. 효과는 측정해 봐야 안다 (신뢰도 중간).
2. **지급 평가 호출 수.** 목표 하나에 Opus 5.5 CLI 호출이 2+N 번 (샘플 목표는 연결 Task 6개라서 최대 8번). 지급 상한은 목표당 1.000 Candle. 현재 `candle.toml` 에서 medium/large/epic 이 모두 1000 milli 라서 이 세 등급을 가르는 모델 판단은 지급액을 바꾸지 못한다. `weight_max = 1` 이라 가중치도 0/1 뿐이다. 라이브 평가 호출은 아직 0번이라 실제 비용은 측정하지 못했다.
3. **60초 tick 마다 원장 전체를 두 번 이상 읽는다** (`candle_candidates.ml` `drain_once`, `candle_appraise.ml` `pending`). 현재 32행이라 무시할 크기다. 행이 수천이 되면 매번 파싱과 검증이 쌓인다. 지금 고칠 일은 아니다.
4. **초상화 GET 마다 원장 전체 재생.** 캐시는 그 뒤에 있다. 위와 같은 이유로 지금은 무시할 크기.
5. **도구 스키마.** candle 6개 약 3.9 KB, DOS 11개 약 8.0 KB, MSX 12개 약 8.0 KB (`config/tools/*.toml` 바이트 합). 키퍼 도구 면에 항상 실리는지는 확인하지 못했다.

## 6. 용어·결합

- 용어집이 코드보다 뒤처졌다. `00-glossary.md` Candle 항목은 사건이 9종이고 "`Paid` 지급과 `Purchased` 구매를 재생" 이라 쓰지만, 코드는 12종이다. Granted/Gifted/Gifted_item 이 더 있다 (#41371, #41409).
- "반감기": 코드는 `half_life`(잔액 감쇠)다. 발행 반감(issuance halving)은 없다. 대화나 문서에서 "반감기" 가 발행 일정을 뜻하는지 확인이 필요하다.
- 용어집 Candle 첫 줄 "Goal 완료에 대해 받는 보상 화폐" 가 선물·grant 경로와 맞지 않는다.
- "Workspace Curator" 이름이 `Workspace_curator`, 프롬프트 `workspace_memory_curator`, lane `workspace_curator_exact` 로 흩어져 있다. 한 이름으로 모으자.
- 결합 분리 제안: 한 원장에 (a) 목표 지급 기록(Snapshot…Payout_failed), (b) 지갑(Paid 결과·Granted·Gifted·Purchased), (c) 아이템(소유·착용)이 섞여 있다. `candle_payout.ml` 은 12개 variant 를 7군데에서 나열한다 (`is_settled`, `last_owed`, `failed_run`, `waiting`, `find_pass`, `candidates_of`, `validate_settlement`). 새 variant 가 생길 때마다 이 줄들을 전부 고쳐야 한다 (#41371, #41409 가 실제로 그랬다). `Candle_event.body` 를 `Payout_record | Wallet_record | Policy` 의 두 단계로 나누면 지급 코드가 지갑 이벤트를 나열하지 않아도 된다.
- 의존 방향: `lib/candle` 이 `Keeper_portrait_item`(장신구)을 참조한다. 돈 쪽이 그림 쪽 타입을 안다. 큰 일이라 보류해도 된다.

## 7. 지울 것

- `candle_payout.ml` 의 12 variant 반복 나열 (6장). 지우기보다 구조 변경이다.
- `server_candle_appraiser.ml` 의 ref 3개와 기본 분기 (D3).
- `play_pad.ml` 내장 삼국지3 레이아웃: 워크스페이스 `dos/pads/samguk3.toml` 로 옮기면 lib 에서 게임 이름이 사라진다.
- curator 기록의 `actual_input` + `prompt.rendered` 중복.
- 지금 설정에서 값을 못 가르는 평가 단계: 등급 3개가 같은 1000, 가중치 0/1. 설정을 바꾸든 단계를 줄이든 운영자 결정이 필요하다.

## 부록: 라이브 수치 (읽기 전용)

- `candle-ledger.jsonl`: 32행, 4.1 KB. granted 28 ("welcome gift", 키퍼당 10 milli), half_life_set 1 (off), purchased 1 (glasses, 0 milli), equipped 1, snapshot 1 (10-07 02:50Z). Paid/Payout_owed/Candidates/Gifted 는 0행. 평가 lane 실행 0회라서 지급 파이프라인은 라이브로 한 번도 끝까지 돌지 않았다.
- 설정: half_life off, 등급 100/700/1000/1000/1000 milli, weight_max 1, 아이템 18개 가격 합 5000 milli. 한 키퍼가 전부 사면 5 Candle 에서 쓸 곳이 없고, half_life off 라서 남는 돈은 줄지 않는다. 지급이 쌓이면 공급이 계속 늘기만 한다 (소각처가 유한).
- curator 실행: 221회 (09-28 134회, 10-07 88회). 09-28 실패는 context_overflow 83 + rate_limited 51. 기록 디렉터리 curator 분 약 1.3 GB (보존은 개수 기준 prune, 바이트 기준 아님).
