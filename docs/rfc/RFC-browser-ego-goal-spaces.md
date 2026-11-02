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

- 10-29 관측에서는 114, 119, 122가 서로 다른 clientId 에서 같은 ID 로
  이어졌다. 이 표본에서 서버·워커 재시작이 공간 소실과 일치하지 않았다.
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
  관측한 사라진 agent 공간 99~135, 8 은 목록에 남지 않았다. 이 표본만으로
  모든 회수가 agent 공간에만 일어난다고 단정하지 않는다.
- 마지막 탭을 닫은 빈 공간은 2분 관찰 동안 목록에 남았다. 만든 SDK
  프로세스가 끝난 뒤에도 남았다. 이 표본에서는 즉시 회수되지 않았다.
- 서로 다른 두 공간에 동시 명령을 주면 간섭이 없다. 한쪽이 confirm
  대화상자를 붙잡은 동안 다른 쪽의 열기·이동·읽기가 266ms 안에 끝났다.
  이 프로브의 두 공간에서는 프로세스 간 차단이 관찰되지 않았다.
- 관리 밖 탭이 남은 공간은 `finish({keep:[]})` 로 닫히지 않고 소유가
  `user` 로 넘어간다.

## 3. 결정과 구현 보류

공간의 주인은 Goal 이며, Goal 에 연결된 Task 는 다른 Goal 과 공간을 공유하지 않는다.
이 문서는 목표 설계이지 현재 구현된 기능이 아니다. **자동 정리 구현은 보류**한다.
현재 ego 관측의 numeric ID·이름·ownership 만으로는 앱 재시작 후 ID 재사용을
구분하거나 `finish_space` 와 Goal 재개 사이의 외부 효과를 fence 할 수 없다.
아래 저장·식별·효과 조건을 구현하고 검증하기 전에는 이 RFC 만으로 자동
`finish_space` 를 배포하지 않는다. 일반 명령도 매번 numeric ID 로 공간을 다시
얻으므로, 앱 재시작·ID 재사용 뒤 기존 peer 가 다른 Goal 공간에 명령하지 않음을
보장하는 효과 결속 신원 검증 또는 효과 완료까지 교체·재사용을 막는 fence 가
입증되기 전에는 Goal 공간 라우팅 구현도 보류한다. 비동기 무효화 통지를 받는다는
사실이나 명령 전에 한 번 목록을 조회한 사실만으로는 그 경합을 막지 못한다. 이는 아직 재현된 런타임 사고가 아니라 확인되지 않은 경계다.

1. 공간 이름은 `masc-<goal_id>` 로 파생한다. Goal ID 의 형식이나 길이에
   임의의 가정을 두지 않는다. 알려진 로컬 이름 검증에 실패하면 이유를 포함해
   명시적으로 거부한다. ego 가 이름을 수락·정규화하는 범위와 서로 다른 Goal 이름의 일대일성은 아직
   미확인이다. 일대일성과 동시 생성 경쟁을 검증하기 전에는 분리를 보장하지 않는다.
   이름을 해시하거나 공유 공간으로 폴백하지 않는다.
2. Goal 링크가 정확히 하나인 Task 는 그 Goal 이 `Executing` 일 때만 Goal 공간을
   열 수 있다. 종착 Goal 과 그 외 phase 는 이유를 포함해 거부한다. 새 cycle 은
   Goal 생성 시 첫 cycle 을 만들고, 이후 새 cycle 은 종착 상태를 실제로 벗어날
   때만 생긴다. 이미 `Executing` 인 `Reopen` 은 no-op 이다.
3. Goal 없는 Keeper 는 기존 `[browser.live.ego] space` 공유 공간을 쓴다.
   여러 Goal 링크와 명시적 `lane`/`clientId` 는 기존 선택 규칙으로 대상을 고른다.
   명시적으로 고른 연결도 Goal 공간이면 같은 phase·admission 규칙을 적용하며,
   연결의 Goal 소유권을 확인하지 못하면 우회하지 않고 미확정으로 거부한다.
4. 연결 하나 = 공간 하나 = SDK 프로세스 하나는 유지한다. 워커는 처음 필요할 때
   시작한다. 장시간 유휴 Goal 워커의 은퇴·자원 상한은 아직 결정되지 않았으며,
   동적 워커를 배포하기 전에 별도로 정하고 검증해야 한다.
5. 같은 호스트 프로세스에서 이전·새 numeric ID 를 모두 관측하면 교체 사실을
   영수증에 실는다. 재시작 뒤 이전 관측이 없으면 미확인으로 표시한다.
6. `Goal_document` 와 `Goal_store` 가 Goal 수명에 결속된 typed 브라우저 생애주기
   상태와 정리 의도를 한 Goal primary 문서에서 소유한다(§5). 예전 수동 매핑
   `Browser_goal_space` / `browser_goal_spaces.json` 을 되살리는 것은 아니다.
   이 소유권·스키마·트랜잭션은 새 구현 요구사항이며 현재 코드에 없다.
7. `bind_goal` / `goal_status` / `unbind_goal` 계열과 기존 수동 매핑 저장소의
   코드 삭제는 전환 계획의 일부다. 기존 데이터를 읽지 못한다는 이유로 새 상태를
   빈 값이나 「공간 없음」으로 만들지 않는다.

## 4. 다른 길

| 길 | 좋은 점 | 걸리는 점 |
|---|---|---|
| 워커 하나에 ego 연결 여러 개 | 프로세스 수가 줄어든다 | 연결=공간=프로세스 불변식을 깨고 client 행 모델을 다시 써야 한다 |
| 마지막 공간 숫자 ID 를 저장해 정확히 재개 | 관측한 ID 를 보존한다 | 앱 재시작으로도 공간이 사라질 수 있으므로 numeric ID 만으로 정확한 재개를 보장할 수 없다 |
| 지금 구조 유지 + 소실 보고만 | 변경이 가장 작다 | 운영자가 원한 "알아서"가 되지 않고, 공유 공간의 페이지 충돌도 그대로다 |

## 5. 동작

### 라우팅과 이름 열기

호스트는 Task 의 Goal 링크를 `<base-path>/.masc/tasks/goal_task_links.json` 의
권위 있는 링크 저장소에서, Goal phase 를 Goal 저장소에서 각각 읽는다. 두 문서는
원자적 스냅샷이 아니다. 링크 조회 실패·모호함을 무링크로 취급하거나 공유 공간으로
폴백하지 않는다. 링크와 Goal 의 일관된 admission 및 링크 변경과의 경쟁을 막는
revision/fence 계약을 구현·검증하기 전에는 두 읽기가 원자적이라고 가정하지 않는다.
현재 링크는 문자열 `goal_id` 만 보유하므로 삭제 후 같은 ID 의 Goal 을 새로 만들면
남은 옛 링크를 새 Goal 에 결속할 수 없다. 구현은 링크에도 Goal incarnation 을
결속하고 기존 링크의 명시적 전환·미확정 격리 또는 동등한 증명을 갖춰야 한다.
문자열 ID 의 일치만으로 예전 링크를 새 incarnation 에 자동 귀속하지 않는다.
링크가 하나이고 phase 가 `Executing` 일 때만 파생 이름으로 새 open 을 허가한다.
`Completed`, `Dropped`, `Verifying`, `Awaiting_confirmation`, `Paused`, `Blocked` 는
Goal 공간 open 을 명시적으로 거부한다. Goal 없는 경우에만 기존 공유 공간을 쓴다.
종착 이후에는 새로운 Goal 공간 open 을 허가하지 않는다. 같은 `goal_id` 의 이전
incarnation 이나 도입 전 공간이 같은 이름으로 남았을 수 있으면, 그 공간의 신원과
재사용 권한을 확정하기 전까지 이름 open 을 보류한다. 새 incarnation 이라는
로컬 기록만으로 같은 이름의 기존 ego 공간이 다른 공간이 되지는 않는다.

이름 검증은 실제 호출 전 실패와 호출 뒤의 미확정을 구분한다. 현재 로컬 검증은
비공백만 확인하며 ego 의 길이·문자 허용 범위는 아직 알려지지 않았다.
`taskSpace(name)` 은 없으면 공간을 만드는 효과가 있다. 호출 전 검증 실패는
미호출로 보고할 수 있지만, 호출 뒤 오류·타임아웃은 생성되지 않았다는 증거가
아니다. 이름 자체나 현재 다른 공간의 numeric ID 로 이전 효과를 추정하지 않는다.
운영자 소유·위임된 같은 이름의 공간은 Goal 공간으로 사용하거나 닫지 않는다.
목록이 불명확하면 소유권을 추정하지 않는다. 호출 전에 충돌을 확정한 경우에는
미호출로 거부하고, 이름 open 이후 충돌·오류가 관측된 경우에는 원래 attempt 의
효과를 미확정으로 보존한다. 선행 목록 조회만으로 소유권 경합이 없다고 보장하지
않으며, 소유권 판단을 실제 효과에 결속하는 계약이 필요하다.

### Goal 소유 상태와 전환

구현에서는 `<base-path>/.masc/goals.json` 의 `Goal_document` 스키마를 확장해
브라우저 lifecycle 레코드를 닫힌 타입으로 저장한다. `Goal_store` 가 그 스키마,
유일 primary 저장과 `<base-path>/.masc/goals.json.last-good` 복구 사본을 소유한다.
레코드는 `(goal_incarnation, goal_cycle)` 로 식별하고 원래 `goal_id` 를 함께 둔다.
같은 ID 의 Goal 삭제 후 재생성은 새 incarnation, 실제 종착→실행 전이는 새
cycle 이다. `Completed` 의 criterion 변경도 `Executing` 으로 돌아갈 수 있으므로
명시적 `Reopen` 과 같은 전이 규칙으로 다룬다. 이미 `Executing` 인 `Reopen` 은
새 cycle 을 만들지 않는다.

각 cycle 은 도입 전 사용 권위 `Unknown_before_adoption | Tracked` 와 고유한
`open_attempt_id` 별 개방 상태 `Never_dispatched | May_have_opened | Observed` 를
가진다. 동시에 여러 open 이 허가될 수 있으므로 한 시도의 `Observed` 가 다른
시도의 미결·불확실 상태를 지우지 않는다. 종착 시 정리 상태는
`No_space_observed | Pending_identity_reconciliation | Pending_cleanup |
Uncertain_preserved | Finished | Superseded` 의 닫힌 변형이다. `Finished` 는
네이티브 receipt 와 `closedSpace=true` 인지, user 소유로 공간이 남았는지를 함께
기록하며 단순 성공 응답을 공간 삭제로 해석하지 않는다. 닫힘이 확인되지 않은
browser-backed 파일은 보존한다. 각 `Observed` 는 관측 ID 와 증명된 외부
incarnation 이 각각 있는지 기록한다. numeric ID 만 있거나
외부 incarnation 을 확인하지 못하면 식별은 미확정이다. 종착 전이 번호는 해당
전이를 커밋한 `Goal_store.state.version` 정수 하나로 정의하며, 증가할 수 없으면
전이를 거부한다. 시각은 전이 순서나 신원으로 쓰지 않는다.

Goal phase·cycle·개방 상태·정리 의도의 변경은 같은 Goal 문서의 단일 primary
replacement 로 커밋한다. 저장된 write 성공 전에 외부 open 또는 finish 를
디스패치하지 않는다. 현재 `Goal_store` 의 파일 잠금과 일반 backend 쓰기는 이
계약을 아직 충족하지 않는다. 구현 PR 은 최소한 다음을 갖춰야 한다.

- lease 소유권 재확인과 publication fencing, strict staged file fsync → rename →
  parent fsync 및 rename 이후 실패의 재관측. 이 근거는 프로세스 재시작 복구에
  한하며 하드웨어·전원 손실 보장을 주장하지 않는다.
- 모든 Goal 생성·삭제·종착·실제 재개·criterion 수정 경로가 같은 트랜잭션 규칙을
  사용한다. 미결·불확실한 예전 cycle 은 삭제·재생성이나 새 cycle 이 덮어쓰지
  않고 별도 레코드로 보존한다. 해결된 기록의 정리는 명시적 보존 정책과 증거가
  정해질 때까지 수행하지 않는다.
- 기존 Goal·이름 공간은 도입 전 사용 여부가 `Unknown_before_adoption` 이다.
  한 attempt 의 `Never_dispatched` 는 그 attempt 의 미호출만 증명하며, 빈 attempt
  목록도 도입 전이나 이전 cycle 공간의 부재를 증명하지 않는다. 열린 공간이 없다는 긍정적 증거가
  없으면 `Pending_identity_reconciliation` 으로 남긴다.
- 현재 구버전 decoder 는 `goals.json` 최상위의 모르는 필드를 무시하고 재기록할 수
  있다. 기존 문서와 recovery 사본에 대한 명시적 스키마 전환, 이전 writer 차단,
  실패 시 원본 보존을 구현·검증한다. 구버전 writer 와 혼용하지 않는다.
- 현재 last-good 사본은 primary 뒤 별도로 best-effort 기록되므로 최신 상태의
  자동 권위가 아니다. 명시적 복원·롤백 시 이력 연속성을 증명하지 못하면 과거
  미호출·정리 완료·전이 번호 단조를 가정하지 않고 신원을 미확정으로 둔다.
  복원 전 불확실한 효과를 재생하지 않는다.

### 관측과 종착 후 정리

워커는 이름 기반 open 을 허가하기 전에 해당 attempt 의 `May_have_opened` 를
커밋한다. 응답의 numeric ID·이름·ownership 을 검증한 뒤 `Observed` 로 승격하며,
강한 외부 incarnation 증거는 별도로 기록한다. 증거가 없으면 이 관측은 자동 정리
권한이 없다. 늦은 open 응답은 원래 incarnation·cycle 에만 기록하고 재개된 cycle 의
결속이나 정리 대상을 덮어쓰지 않는다. 확정된 미호출 증거 없이 `Never_dispatched`
로 되돌리지 않는다. 이미 허가된 open 은
종착 커밋 이후 실제 실행될 수 있으므로 그 효과가 확정될 때까지 미결로 보존한다.
단일 파일 잠금만으로 네트워크의 외부 효과까지 직렬화됐다고 주장하지 않는다.

Goal 이 `Completed` 또는 `Dropped` 로 전이하면 같은 primary replacement 에
해당 Goal incarnation·cycle·전이 번호·관측 신원에 결속된 정리 의도를 남긴다.
외부 신원이 미확정이고 Goal 문서가 정상적으로 커밋되면
`Pending_identity_reconciliation` 으로 남긴다. Goal 저장소를 읽을 수 없거나
rename 전 쓰기가 실패하면 전이는 미커밋이며 기존 primary 를 보존하고 오류를
보고한다. rename 뒤 오류나 lease 결과가 불확실하면 새 primary 가 이미 보일 수
있으므로 전이 성공·실패 어느 쪽도 단정하지 않는다. fenced 재관측과 필요한 sync 로
결과를 확인하기 전까지 외부 효과를 금지하고 기존 증거를 보존한다. 기록할 수 없는
저장소에 새 미결 상태가 이미 저장됐다고 주장하지 않는다. `No_space_observed` 는 이 incarnation 의 과거와 현재 cycle 에
닫아야 할 공간이 없다는 긍정적 증거가 있을 때만 쓴다.

자동 `finish_space` 를 구현하려면, 실제 효과 직전에 Goal 의 종착 전이와 cycle,
외부 앱 및 공간의 재사용 불가능한 incarnation, 네이티브 agent 소유권, 워커
휴지를 확인하고 그 신원에 조건부로만 finish 되는 계약이 필요하다. 재개 전이와
이미 수락된 finish 가 경합할 때도 새 cycle 의 공간을 닫지 않는 effect fence 또는
동등한 증명이 필요하다. 숫자 ID·동일 이름·MASC worker/client incarnation 은
그 증거가 아니다. 현재 SDK 는 요구되는 앱/공간 incarnation 과 조건부 finish 를
제공하는 것으로 확인되지 않았다. 현재 `space_status` 의 ID 부재 오류도
`Already_absent` 의 증거가 아니다. 이 조건을 충족하지 못하면 의도는 미결로 두고
호출하지 않는다.

재개 전이는 이전의 미실행 확정 정리 의도를 무효화하면서 이전의 미확정 상태를
보존한다. finish 호출 결과가 타임아웃·연결 끊김 등으로 불확실하면
`Uncertain_preserved` 로 보존하고 자동 재생하지 않는다. 결과 미확정의 재생을
금지하는 durable 전송 경계 역시 구현과 크래시 검증이 필요하다.

## 6. 실패

| 상황 | 결과 |
|---|---|
| 종착 또는 실행 외 phase 의 Goal 에 새 open | 이유를 실어 거부; 공유 공간으로 폴백하지 않음 |
| 이름 사전 검증 실패 또는 호출 전 user 소유 충돌 확정 | 호출 전 거부; ego 호출 뒤 오류·소유 충돌은 원 attempt 의 미확정 보존 |
| 공간 소유권 확인 불가 | 소유권을 추정하지 않고 open·정리 보류 |
| ego 앱 재시작 또는 ID 재사용 가능성 | 이전 숫자 ID 만으로 정리하지 않고 신원 미확정 보존 |
| 종착 당시 이전 open 이 진행 중 | `Pending_identity_reconciliation`; 늦은 효과를 없었다고 단정하지 않음 |
| 기존 Goal 또는 이전 cycle 의 사용 여부 미상 | `Unknown_before_adoption` 또는 미결 기록 보존; 같은 이름의 새 incarnation open 보류 |
| Goal 링크 조회 실패·변경 경합 | 무링크나 공유 공간으로 판단하지 않고 오류·미확정 보존 |
| Goal 저장의 rename 전 실패 | 전이 미커밋, 기존 primary 보존 및 오류 보고; 외부 정리 금지 |
| rename 후 또는 lease 결과 불확실 | 성공·실패 단정 금지; fenced 재관측과 sync 전 외부 정리 금지 |
| 신원 검증 실패 | 커밋 가능한 경우 미결 의도 보존; 외부 정리 금지 |
| finish 결과 불확실 | `Uncertain_preserved`; 자동 재생 금지 |
| 관리 밖 탭으로 user 소유가 된 공간 | 자동 정리하지 않고 관측 결과 보존 |
| Goal 링크 여러 개 | 기존 명시적 선택 규칙 적용 |

## 7. 설정

- 새 키를 추가하지 않는다. `[browser.live.ego] space` 는 Goal 없는
  공유 공간 이름으로 그대로다.
- 지우는 것: `bind_goal` / `goal_status` / `unbind_goal` 액션,
  `browser_goal_spaces.json`.

## 8. 검사

1. Goal 링크 0·1·여러 개와 모든 Goal phase 의 라우팅을 검증한다. 종착 뒤 새
   admission 은 거부하되 이전에 허가된 늦은 open 은 미결로 남기는 경합을 검사한다.
   명시적 lane/client 선택도 Goal phase 검사를 우회하지 않아야 한다. Goal 삭제 뒤
   prune 실패로 옛 Task 링크가 남고 같은 ID 가 재생성되는 경우에도 이전 링크가
   새 incarnation 으로 자동 귀속되지 않아야 한다.
2. 이름의 로컬 검증 실패는 미호출이며, ego 호출 후 오류와 응답 유실은
   `May_have_opened` 로 남는지 확인한다. 여러 open 중 한 응답이 도착해도 다른
   미결 attempt 가 지워지지 않아야 한다. 확인되지 않은 길이·문자·정규화
   규칙을 가정하지 않고, 서로 다른 Goal 이름의 일대일성과 동시 생성을 검증한다.
   user 소유·위임된 이름 충돌은 호출 전 확정과 호출 후 미확정을 구분한다.
   `May_have_opened` 기록 뒤 공간 생성 직후 응답 유실, 응답 수신 뒤 `Observed`
   커밋 전 크래시, 각각의 재시작·종착·재개 경합에서 미결 효과를 보존한다.
   반대로 해당 incarnation 의 모든 관련 attempt 미호출·미결 없음과 이전 공간
   부재가 모두 증명된 경우에만 `No_space_observed` 가 가능한지 확인한다.
3. Goal 생성·종착·명시적 재개·criterion 변경·삭제 후 같은 ID 재생성에서
   incarnation, cycle, 단조 정수 전이 번호, 미결 이전 기록 보존을 검증한다.
   이미 실행 중인 `Reopen` 은 새 cycle 을 만들지 않아야 한다.
4. 이전 cycle 의 공간이 남아 있고 새 cycle 에서 open 을 한 적이 없는 경우와
   전환 이전 Goal 의 공간 사용 여부를 모르는 경우에 `No_space_observed` 로
   결론내리지 않는지 검증한다. 같은 ID 의 Goal 삭제·재생성 및 도입 전 같은
   이름 공간이 남은 경우 이전 incarnation 에 새 Goal 이 결속되지 않아야 한다.
5. Goal primary replacement 의 실패 단계, 프로세스 재시작, lease 만료·takeover,
   stale writer, 뒤처진 recovery 사본·복원 후 revision 재사용 및 구버전 writer
   차단을 검증한다. 복원만으로 미호출·완료를 추정하거나 효과를 재생하지 않으며,
   저장 성공 전에 외부 효과가 시작되지 않아야 한다.
6. 앱 재시작 후 숫자 ID 가 재사용되고 소유권도 agent 인 대체 공간은 닫지 않는다.
   외부 incarnation·조건부 finish·Goal 재개 effect fence 가 실제로 제공·검증되기
   전에는 자동 finish 를 시작하지 않는다. 기존 peer 의 일반 페이지 명령도 재사용된
   다른 공간에 적용되지 않아야 한다. 명령 직전 검사 후 ID 재사용과 지연된
   무효화 통지도 검사한다. ID 부재 오류도 부재 확정으로 바꾸지 않는다.
7. 늦은 `Reopen`/criterion 변경과 진행 중 finish, 미확정 finish 뒤 재시작을 각각
   검사한다. 새 cycle 을 닫거나 미확정 외부 효과를 자동 재생하지 않아야 한다.
   `closedSpace=false` 또는 닫힘 미확정은 삭제 완료가 아니며 receipt 와 파일을 보존한다.
8. 같은 호스트 프로세스에서 ID 교체를 관측하면 이전·새 ID 를 영수증에 넣고,
   재시작 뒤 이전 ID 를 모르면 미확인으로 남긴다.
9. 서로 다른 두 Goal 공간의 동시 명령은 SDK 프로브만 확인됐다. 구현 뒤 MASC 동적
   워커의 비간섭, 유휴 은퇴 및 자원 상한을 별도로 검증한다.

## 9. 순서

1. 이 RFC 와 미결 신원·worker 자원 정책 결정.
2. Goal 저장·전환·스키마 이행 및 open admission 계약을 구현하고 검증.
3. 그 계약을 사용하는 Goal 파생 라우팅·동적 워커·소실 보고와 기존 수동 매핑 제거.
4. 외부 신원·조건부 finish·effect fence 를 구현하고 검증한 뒤에만 자동 정리 연결.
5. 실사용 증거와 Keeper 안내 문구.
