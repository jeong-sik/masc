---
rfc: "browser-ego-goal-spaces"
title: "Goal 단위 ego 작업 공간"
status: Draft
created: 2026-10-30
author: vincent + claude
related: ["browser-live-ego"]
---

# RFC — Goal 단위 ego 작업 공간

## 1. 문제

운영자는 ego 공간이 "매번 사라졌다 아니었다 한다"고 본다. 측정값이 그 관찰을 뒷받침한다.

2026-10-28 ~ 10-30, `<base-path>/.masc/tool_calls/2026-10/*.jsonl` (실측 워크스페이스
base path `/Users/dancer/me`, 즉 `/Users/dancer/me/.masc/tool_calls/2026-10/*.jsonl`;
셸 홈 `~/.masc` 가 아님) 의 브라우저 영수증에서
같은 이름 `masc-keepers` 의 실제 공간 numeric ID 를 뽑았다.

| 날짜 | 공간 ID 변화 | 교체 수 |
|---|---|---|
| 10-28 | 99 → 100 → 101 → 103 → 107 → 109 | 5 |
| 10-29 | 111 → 113 → 114 → 115 → 117 → 118 → 119 → 122 | 7 |
| 10-30 | 123 → 135 → 8 → 12 | 3 |

함께 확인한 사실:

- 워커(서버)가 재시작해도 공간이 살아 있으면 같은 ID 로 이어 붙는다.
  10-29 에 114, 119, 122가 서로 다른 clientId 에서 같은 ID 로 이어졌다.
  그래서 서버·워커 재시작 자체가 공간을 없애지 않는다.
- 새 ID 가 생기는 순간은 이전 공간이 ego 앱 안에서 없어진 뒤다.
  MASC 는 닫은 적이 없다. 최근 5일간 `finish_space` 실제 호출은 0건이다.
- 10-30 14:39 에 ID 가 8로 리셋됐다. ego 앱이 그때 재시작했다. 16:54 의 8 → 12는
  앱 재시작 없이 공간이 사라진 케이스다. ego 쪽에서 무엇이 공간을 닫는지는
  아직 확인되지 않았다.
- 설치당 공간 1개라 모든 Keeper 가 하나를 공유한다. Keeper 들은 하루에
  `close_tab` 을 수십 번 부른다(10-29 30건). 한 Keeper 가 연 페이지를
  다른 Keeper 가 닫는다.

결과: Keeper 는 아무 신호 없이 빈 공간에 떨어지고, 이전 페이지는 사라진다.
누구도 소실을 보고받지 못한다.

## 2. 확인한 사실 (코드)

- 명령 스크립트마다 `taskSpace(space)` 를 연다(`Browser_ego_peer.script`).
  `taskSpace` 는 못 찾으면 만든다. 이름 열기 = 만들기 또는 이어 붙이기다.
- `listTaskSpaces` 로 열지 않고 목록과 소유를 읽을 수 있다.
- 워커 하나 = ego 연결 하나 = SDK 프로세스 하나. 공간 참조는 워커 CLI 인자다
  (`--live-ego-space` / `--live-ego-space-id`).
- `Browser_goal_space` 저장소(`bind_goal`)는 관측 메타데이터만 저장한다.
  공간을 만들지 않고, 재할당과 공간 공유를 거부한다.
- Goal 수명은 `Workspace_goals` 가 관리한다. `executing` → … → `completed` /
  `dropped`. `request_complete` 는 `verifying` 로 옮길 뿐이고, 증명 판정과
  운영자 `confirm_completion` 이 있어야 `completed` 가 된다.
- Goal ID 는 자동 생성 ID 또는 운영자 지정 ID 이다. 지정 ID 는 빈 값과
  앞뒤 공백만 거부하고 형식을 강제하지 않는다(`goal_store` 의
  `resolve_goal_id`). `goal-msx-play-token-cost` 는 관측된 예시이지
  계약이 아니다.
- ego 공간은 브라우저 프로필의 쿠키를 함께 쓴다. 공간이 계정을 나누지는
  않는다. 공간마다 로그인이 따로 놓이지는 않는다.

2026-10-30 프로브(`docs/evidence/2026-10-30-ego-goal-spaces-probes/`,
ego-browser 0.6.1.13)로 추가로 확인한 사실:

- 목록에는 user 공간 6개(10-25 생성 포함)와 agent 공간 1개가 있었다.
  사라진 agent 공간 99~135, 8 은 시체로 남지 않는다. 회수는 agent 공간에만
  일어난다.
- 마지막 탭을 닫은 빈 공간은 2분 관찰 동안 목록에 남았다. 만든 SDK
  프로세스가 끝난 뒤에도 남았다. 즉시 회수 가설은 기각이다.
- 서로 다른 두 공간에 동시 명령을 주면 간섭이 없다. 한쪽이 confirm
  대화상자를 붙잡은 동안 다른 쪽의 열기·이동·읽기가 266ms 안에 끝났다.
  프로세스 간 차단은 같은 공간에서만 성립한다.
- 관리 밖 탭이 남은 공간은 `finish({keep:[]})` 로 닫히지 않고 소유가
  `user` 로 넘어간다.

## 3. 결정

공간의 주인은 Goal 이다. 공간과 Goal 을 강결합으로 묶는다.

1. 공간 이름은 Goal 에서 파생한다: `masc-<goal_id>`. Goal ID 에 형식
   제한이 없으므로 파생 규칙은 특정 모양(kebab 등)을 가정하지 않는다.
   운영자 지정 ID 도 같은 규칙으로 파생한다. 바인딩 저장소를 따로
   두지 않는다. Goal 이 곧 공간 신원이다.
2. 호스트가 공간을 알아서 만들고 이어 붙인다. Keeper 의 현재 Task 가 Goal
   하나에 연결돼 있으면 그 공간으로 라우팅한다. 공간이 없으면 `taskSpace`
   이름 열기가 만든다. Keeper 는 공간을 의식하지 않는다.
3. Goal 없는 Keeper 는 지금처럼 `[browser.live.ego] space` 의 공유 공간을
   쓴다. 브라우저 접근에 Goal 조건을 붙이지 않는다.
4. 연결 하나 = 공간 하나 = SDK 프로세스 하나는 그대로 둔다. Goal 공간마다
   ego 워커가 하나 뜬다.
5. 공간 소실을 조용히 넘기지 않는다. Goal 공간 워커(단일 연결)가 직전 관측 ID 와
   새 ID 가 다름을 관측하면 영수증에 대체 사실을 실는다.
6. Goal 이 `completed` 나 `dropped` 로 전이하면 호스트가 그 전이 epoch 와
   관측 시 durable 하게 기록된 결속의 numeric `spaceId` 에 결속된 정리
   의도(cleanup intent)를 기록하고,
   Goal 이 여전히 그 종착 상태이고 살아 있는 관측 클라이언트에서 해당 numeric
   공간이 `agent` 소유임이 확인될 때만 `finish_space` 를 호출한다. `reopen`
   으로 `executing` 에 복귀하면 미실행 정리 의도는 즉시 폐기한다.
7. `bind_goal` / `goal_status` / `unbind_goal` 도구 액션과 `Browser_goal_space`,
   `browser_goal_spaces.json` 을 지운다. reader·converter 를 만들지 않는다.

원칙: 새 게이트를 두지 않는다. 런타임 관측 상태는 Goal 공간마다 관측 시
durable 하게 기록되는 관측 결속 하나와 종착 전이에 결속된 정리 의도
레코드(신원 미확정 상태 포함)만 둔다. 재할당 거부·인스턴스 고정·승인 절차
같은 의례를 만들지 않는다.

## 4. 다른 길

| 길 | 좋은 점 | 걸리는 점 |
|---|---|---|
| 워커 하나에 ego 연결 여러 개 | 프로세스 수가 줄어든다 | 연결=공간=프로세스 불변식을 깨고 client 행 모델을 다시 써야 한다 |
| 마지막 공간 숫자 ID 를 저장해 정확히 재개 | 앱 재시작 외 소실을 막는다 | ego 앱 재시작이 가장 흔한 소실인데 어차피 새 공간이다. ID 관리가 설정의 책임이 된다 |
| 지금 구조 유지 + 소실 보고만 | 변경이 가장 작다 | 운영자가 원한 "알아서"가 되지 않고, 공유 공간의 페이지 충돌도 그대로다 |

## 5. 동작

### 라우팅

- 호스트는 Keeper 의 현재 Task Goal 링크를 읽는 기존 경로를 쓴다.
  바인딩 조회 대신 이름을 파생한다.
- 연결된 Goal 이 정확히 하나면 그 Goal 공간으로 간다. 0개, 여러 개,
  명시적 `lane`/`clientId` 지정은 지금 선택 규칙을 그대로 따른다.
- 여러 Keeper 가 같은 Goal 에 붙으면 같은 공간을 공유한다. 연결의
  명령 직렬화가 이미 한 공간을 동시에 만지지 않게 한다.

### 워커 생애

- 서버가 Goal 공간 워커를 동적으로 선언하고 시작한다. 첫 브라우저 명령
  때 뜨고, 워커 은퇴나 서버 재시작으로 연결은 사라진다.
- 공간은 연결과 무관하게 ego 앱에 남는다. 다음 명령 때 같은 이름으로
  이어 붙는다.
- 유휴 제거(eviction) 로직을 두지 않는다. Goal 이 끝나는 것이 공간의
  끝이다.

### 소실 보고

- Goal 공간마다 워커(연결)가 하나뿐이므로, 마지막 관측 numeric ID 의 갱신 주체도
  그 Goal 공간 워커 하나로 고정된다. 여러 Keeper 가 같은 Goal 공간을 공유해도
  직렬화된 단일 워커가 관측 ID 를 갱신하므로 연결 간 역전 경쟁이 생기지 않는다.
- 호스트는 Goal 공간의 마지막 관측 numeric ID 를 들고 있다가(원장이 아닌
  메모리 관측값), 연 결과의 ID 가 다르면 영수증에 이전 ID 와 새 ID 를
  함께 실는다. Keeper 는 페이지가 사라졌음을 알고 재작업을 판단한다.
- 메모리 관측값은 호스트 재시작과 함께 사라진다. 재시작 뒤 첫 관측은
  새 ID 만 알 수 있으므로 이전 ID 없이 「이전 ID 미확인」으로 보고한다.
  이전 ID·새 ID 영수증은 같은 호스트 프로세스가 둘 다 관측한 경우에만
  보장한다(best-effort).
- 관측 ID 를 갱신하는 주체는 그 관측을 Goal 실행 주기와 함께 durable 하게
  기록한다(관측 결속). 관측 결속이 종착 전이가 읽는 신원의 원천이다.
  이전 ID·새 ID 영수증용 메모리 관측값은 호스트 재시작으로 사라져도 관측
  결속 기록은 남는다. 재개(Reopen)는 여전히 이름 열기로 이어 붙는다. 관측
  결속은 정리 대상 신원의 원천일 뿐 공간을 ID 로 되찾는 재개 수단이
  아니다(§4 에서 거절한 길과 다르다).

### 완료와 재개(Reopen) 경계

- Goal 이 종착 상태(`completed` — 증명 판정과 운영자 `confirm_completion` 이
  끝난 상태 — 또는 `dropped`)로 전이하면, `Workspace_goals` 전이 경로는 단순
  이름이 아니라 **`(goal_id, terminal_transition_seq, target_space_id)` 에
  결속된 durable 정리 의도(cleanup intent)** 를 기록한다.
  - `terminal_transition_seq` 는 해당 종착 전이의 단조 증가 revision/시각이다.
  - `target_space_id` 는 그 Goal 주기가 종착되기 직전까지 관측된 실제 numeric
    `spaceId` 다. 전이 경로는 호스트 메모리 관측값이 아니라 관측 결속 기록에서
    이 값을 읽고, 세 갈래로 정리 의도를 만든다.
    1. 관측 결속이 있으면 그 `target_space_id` 로 정리 의도를 기록한다.
       호스트가 재시작해도 결속 기록에서 읽는 한 기존 공간 신원은 유지된다.
    2. 결속 기록이 온전히 읽히고 해당 주기의 결속이 없으면, 그 주기는
       브라우저 공간을 한 번도 열지 않은 것이다(첫 관측 때 기록이 만들어지므로
       기록 없음 = 미관측). 닫을 공간도 없으므로 정리 의도는 즉시
       `No_space_observed` 로 종결되며, 정리를 위해
       `taskSpace("masc-<goal_id>")` 를 이름으로 열어 새 공간을 만드는 일은
       절대 하지 않는다.
    3. 결속 기록을 읽지 못했거나 미관측임을 긍정적으로 확정할 수 없으면(관측
       사실이 있는데 결속이 없는 경우 포함) 신원을 확정할 수 없다. 정리 의도를
       `Pending_identity_reconciliation` 로 미해결로 남긴다. 이 상태는 이름으로
       새 공간을 열지 않고, 이름 조회로 붙잡은 대체 공간을 닫지도 않는다. 다음
       실행 주기의 첫 관측 또는 운영자 판정으로만 해소한다.
- **권한·소유권·휴지(quiescence) 확인 (`RFC-browser-live-ego` §279–312 준수)**:
  - `finish_space` 는 살아 있는 관측 클라이언트(`clientId`)와 그 클라이언트에
    결속된 numeric `target_space_id` 가 있어야만 부를 수 있다.
  - 호스트 reconciler 는 실행 직전에 Goal 전이/라우팅 잠금 아래에서 다음 네
    가지를 원자적으로 재확인한다:
    1. **권위 있는 Goal 상태 재확인**: `Workspace_goals` 의 현재 상태가 여전히
       종착(`Completed` 또는 `Dropped`)이고 현재 전이 번호가 정리 의도의
       `terminal_transition_seq` 와 일치해야 한다.
    2. **워커 휴지(quiescence) 확인**: 같은 Goal 워커에서 진행 중인 Keeper
       브라우저 명령이 없어야 한다(워커의 단일 명령 직렬화 큐에서 일반 명령과
       같은 순서로 실행).
    3. **네이티브 상태·소유권 확인 (`space_status`)**: 이름을 열지 않고
       관측된 `clientId` 의 `space_status`(`listTaskSpaces` 의 numeric
       `target_space_id` 조회)로 공간 존재와 네이티브 `ownership` 을 확인한다.
       - 목록에 `target_space_id` 가 이미 없으면 `Already_absent` 로 종결하고
         `finish_space` 를 부르지 않는다.
       - `ownership` 이 `user` 이거나 운영자 위임/제어 대기 중이면 파괴적 정리를
         수행하지 않고 `Skipped_non_agent_ownership` 으로 기록·보존한다.
    4. **명시적 1회 호출**: 위 조건이 모두 맞을 때만 해당 `(clientId,
       target_space_id)` 에 `finish_space`(`keepPages` 기본값 `[]`)를 정확히
       한 번 호출한다.
- **`Reopen` 경쟁 직렬화와 지연 정리 차단 (`lib/goal/goal_phase.ml:135–144`)**:
  - `Completed` 와 `Dropped` 는 모두 `Reopen` 액션으로 다시 `Executing` 이 될 수
    있다. 브라우저 호스트가 내려가 있거나 워커가 없는 동안 종착 전이가 일어났고,
    정리가 실행되기 전에 Goal 이 `Reopen` 되어 Keeper 가 `masc-<goal_id>` 에서
    작업을 재개한 경우, 뒤늦게 살아난 reconciler 가 예전 종착 이벤트를 보고
    현재 작업 중인 공간을 닫으면 안 된다.
  - 이를 막기 위해 `Workspace_goals` 의 `Reopen` 전이는 같은 Goal 잠금 아래에서
    미결 정리 의도를 즉시 `Superseded_by_reopen` 으로 무효화(폐기)하고 전이
    revision 을 올린다.
  - 설령 reconciler 가 큐에 있던 옛 이벤트를 늦게 읽더라도, 실행 직전
    `terminal_transition_seq` 및 현재 Goal phase(`Executing`) 재확인에서
    불일치가 감지되어 `finish_space` 호출이 거부된다.
  - 반대로 `finish_space` 호출이 이미 워커 큐에 들어가 실행 중일 때 `Reopen` 이
    들어오면, 해당 RPC 경계가 끝난 뒤 새 실행 주기가 시작되며 이전
    `target_space_id` 의 정리 의도는 새 주기에 재실행되지 않는다.
- **불확실 결과 보존 (재생 금지)**:
  - `finish_space` 호출이 타임아웃·연결 끊김·프로토콜 오류로 불확실하게 끝나면
    기존 `RFC-browser-live-ego` 규칙대로 의도를 `Uncertain_preserved` 로 남기고
    재시도(replay)하지 않으며 브로커 파일도 보존한다. 이후 Goal 이 `Reopen`
    되더라도 불확실한 이전 `finish_space` 를 재생하지 않는다.

### 사용자 소유 이름 충돌

- 파생 이름이 운영자 소유 공간과 겹치면 지금과 같이 워커가 거부하고
  이유를 남긴다. 새 규칙을 만들지 않는다.

## 6. 실패

| 상황 | 결과 |
|---|---|
| ego 앱 재시작 | 모든 Goal 공간이 사라진다. 다음 명령 때 새 공간 + 소실 보고. 페이지 복구는 ego 한계 |
| 호스트 재시작 뒤 재관측 전 종착 | 관측 결속의 기존 ID 만 정리한다. 미관측임을 확정하지 못하면 미해결로 남기고 대체 공간을 닫지 않는다 |
| 두 Goal 공간에 동시 명령 | 간섭 없음을 측정했다(2026-10-30 프로브). 프로세스 간 차단은 같은 공간에서만 성립한다 |
| finish 불확실 | 기존 `finish_space` 규칙 상속. 재생 금지, 파일 보존 |
| 관리 밖 탭이 남은 Goal 공간 | `finish` 가 닫지 못하고 소유가 `user` 로 넘어간다(프로브 관찰). Goal 완료 뒤에도 공간이 남을 수 있다 |
| Goal 링크가 여러 개 | 지금처럼 명시적 선택 요구. 새 게이트 아님 |

## 7. 설정

- 새 키를 추가하지 않는다. `[browser.live.ego] space` 는 Goal 없는
  공유 공간 이름으로 그대로다.
- 지우는 것: `bind_goal` / `goal_status` / `unbind_goal` 액션,
  `browser_goal_spaces.json`.

## 8. 검사

1. 파생 라우팅: Task 의 Goal 링크가 1개·0개·여러 개일 때 각각 선택 경로.
2. 소실 보고: 가짜 워커로 이전 ID 와 다른 ID 를 답하게 하고 영수증 확인.
3. 완료 연결과 소유권 확인: Goal 이 종착(`completed` — 증명 판정과 운영자
   `confirm_completion` 이 끝난 상태 — 또는 `dropped`)에 도달한 뒤, 관측된
   `clientId` 와 numeric `target_space_id`, `ownership = agent` 를 확인해
   `finish_space` 를 호출하고 영수증을 남기는지 검사한다. `request_complete` 는
   `verifying` 만 만들므로 완료 판정 기준이 아니며, 관측된 공간이 없을 때 이름으로
   새 공간을 열지 않는지도 함께 확인한다.
4. 지연 완료 뒤 `Reopen` 경쟁 차단: 브라우저 호스트가 내려간 상태에서 Goal 이
   `completed` 또는 `dropped` 가 되어 정리 의도가 기록된 뒤, 클라이언트가 복구되기
   전에 `reopen`(`goal_phase.ml:139,144`)으로 `executing` 에 돌아와 Keeper 가
   `masc-<goal_id>` 공간을 다시 쓰는 시나리오를 검사한다. 뒤늦게 클라이언트가
   연결됐을 때 이전 정리 의도가 `Superseded_by_reopen` 및 phase/revision 불일치로
   거부되어 활성 공간과 탭이 닫히지 않아야 한다. 또한 `finish_space` 가 불확실하게
   끝난 뒤에는 재생되지 않음을 확인한다.
5. 동시성: 서로 다른 두 Goal 공간에 동시 명령 — SDK 수준의 두 공간 간 비간섭은
   2026-10-30 프로브로 확인 완료(`docs/evidence/2026-10-30-ego-goal-spaces-probes/`).
   구현 뒤 MASC 호스트의 동적 워커 두 개가 같은 조건을 유지하는지 다시 잰다.
6. 이름 경계: goal_id 로 만든 이름의 길이·문자가 ego 에서 받아들여지는지 구현 PR 의
   단위/통합 시험으로 검증한다.
7. 회수 주체와 성공 기준: agent 공간만 사라지는 근거를 분당 관찰자(프로브 README)로
   잡는다. 소실 보고 설계는 주체와 무관하게 들어가며, 구현 뒤에는 Goal 공간 간
   타 Keeper `close_tab` 간섭 0건과 공간 교체 시 영수증 보고 누락 0건을 확인한다.
8. 호스트 재시작 뒤 종착: Goal 주기에서 공간을 관측한 뒤 호스트가 재시작하고,
   재관측 명령이 오기 전에 Goal 이 종착에 도달하는 시나리오. 정리 의도가 관측
   결속의 기존 ID 에만 결속되는지, 복구 뒤 정확히 그 ID 만 정리하고 이름으로
   새 공간을 열지 않는지 확인한다.
9. 신원 미확정 종착: 관측 결속 기록을 읽지 못하거나 미관측임을 긍정적으로
   확정할 수 없는 채 종착에 도달하는 시나리오. 정리 의도가
   `Pending_identity_reconciliation` 로 남고 이름 열기와 대체 공간 닫기가
   모두 일어나지 않는지 확인한다.

## 9. 순서

1. 이 RFC.
2. `Browser_goal_space`·`bind_goal` 계열 삭제, Goal 파생 라우팅으로 교체.
3. Goal 공간 워커 동적 선언 + 소실 보고.
4. Goal 완료·중단 전이의 `finish_space` 연결.
5. 실사용 증거와 Keeper 안내 문구.
