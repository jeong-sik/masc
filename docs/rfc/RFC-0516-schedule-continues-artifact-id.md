---
rfc: "0516"
title: "예약이 이어 쓸 아티팩트 id를 타입으로 가리킨다 — continues_artifact"
status: Draft
created: 2026-11-09
updated: 2026-11-09
author: sangsu
supersedes: []
superseded_by: null
related: []
implementation_prs: []
---

# RFC-0516 — 예약이 이어 쓸 아티팩트 id를 타입으로 가리킨다

- Status: **Draft.** #49165 완료 판정 1항목 — "예약(또는 Task)이 이어 쓸 아티팩트 id를 타입으로 가리킨다. RFC와 병합 PR 번호를 적는다" — 의 RFC 축이다. 구현은 후속 task-3267 이다(§6). 기록 문서 연속성은 Goal `goal-artifact-schedule-continuity-20261106` 이 잰다.
- 코드 좌표는 기준 head `15e8637a2d`(2026-11-09 main) 직독이다.

## 0. 요약

- 반복 예약(`masc.keeper_wake`)이 매일 같은 기록 문서를 이어 쓰려면, 이어 쓸 문서 id 가 예약에 타입으로 있어야 한다. 지금은 그 자리가 없어 사람이 읽는 문구(message)에만 들어가고, 턴이 바뀌거나 예약이 다시 만들어지면 연결이 끊긴다(#49165).
- 발행 저장소는 이어 쓰기를 이미 지원한다: `lib/published_artifact_store.ml` 에서 Create 는 새 random id(`artifact-` + 32 hex, :517-518)를 만들고, Revise 는 `expected_revision` CAS 로 revision 을 올린다(:531-536). 고장은 저장소가 아니라 "예약 ↔ 문서" 연결이다.
- 이 RFC 는 예약과 Task 에 선택 필드 **`continues_artifact`** 를 더한다. 있으면 wake 가 대상 id 를 구조화로 전달·기록하고, 없으면 오늘 동작 그대로, 대상 문서가 지워졌으면 발행이 저장소의 `Missing` 으로 거절된다. 발행을 강제하거나 되돌리지는 않는다 — "문서가 갈라져도 기록은 틀리지 않다"는 운영자 판단(11-06 재검토, §5)을 설계로 존중한다.

## 1. 문제와 실측

- 11-06 실측(#49165 본문): 게시 아티팩트 118개 중 85개가 revision 1 에서 멈춰 있다. 두 운영 예약이 하루에 하나씩 새 문서를 만들었다 — `sched-167d20eb4f437d985d7d6c99c72a9a85`(sangsu, 10-28~11-04), `sched-a2c0d8642c55c25029434946f216aa64`(kidsnote-job-manager, 10-20~10-27). 새 문서 생성 76번이 직전 발행과 **다른 턴**에서 일어났다. 턴이 바뀌면 Keeper 가 이어 쓸 문서 id 를 모른다.
- 연결은 오직 문구에만 있다. `masc_schedule_create` 파라미터(due/keeper/message/recurrence/source…) 어디에도 문서 id 자리가 없고, 예약 payload 는 `{ kind: string; body: object }` 불투명 봉투(`lib/schedule/schedule_domain.mli`)라 서버가 body 안 의미를 모른다. `config/prompts/keeper.md:89` 의 "기존 문서 id 먼저 확인" 안내는 비율을 줄이지 못했다 — 도구 설명 개선(#46814) 전후 Create 비율 41.6% → 45.5%(#46883).
- 측정도 안 된다. #49165 완료 판정 2항목의 "대상 id 가 **묶인** 예약 실행"에서 묶음이 문구 텍스트라 기계로 읽을 방법이 없다.

## 2. 제안

- 필드 하나: **`continues_artifact`** — 문자열, 형식 `artifact-<32 hex>`, 선택.
- 자리: (a) 예약 `masc.keeper_wake` payload body, (b) Task 레코드. 기록을 켜는 쪽이 골라 쓴다. #49165 의 실측 피해는 예약이므로 예약이 1순위다.
- 도구 표면: `masc_schedule_create`·`masc_schedule_update`·`masc_schedule_get` 에 같은 이름의 선택 파라미터/출력, `keeper_task_create` 에 선택 파라미터, 대시보드 예약 투영(`lib/server/server_dashboard_schedule_projection.ml`)에 표시.
- 분리 원칙: **지시(할 일)는 문구에, 정체성(어느 문서)은 필드에.** 필드는 지시문을 대체하지 않는다 — wake 전달 문서에 서버가 대상 id 를 한 줄로 렌더해 줄 뿐이다(§3.1).

## 3. 동작 규정

### 3.1 필드가 있을 때

- 설정: `masc_schedule_create`/`masc_schedule_update` 가 값을 받아 payload body 에 타입으로 저장한다. 형식이 `artifact-<32 hex>` 가 아니면 거절하고, 저장소에 없는 id 도 거절한다("continues_artifact: artifact or revision not found") — 오타를 실행 때까지 숨기지 않는다. 존재 검증은 설정 시점의 스냅일 뿐이고, 그 이후의 삭제는 §3.3 의 실행 시점 거절이 맡는다.
- 실행: wake payload 가 대상 id 를 구조화 필드로 전달하고, 전달 문서 끝에 서버가 한 줄을 덧붙인다 — "이 예약은 `artifact-…` 를 이어 쓴다. 새 문서를 만들지 않는다." Keeper 가 사람이 쓴 문구를 어기거나 잊어도 이 줄은 서버가 렌더하므로 항상 도착한다.
- 발행: Keeper 는 `keeper_artifact_publish` 에 `id` + `expected_revision`(CAS)을 쓴다. 도구 계약은 오늘 것 그대로다.
- 기록: wake 결과 스탬프에 전달한 대상 id 를 남긴다(`Schedule_payload_projection.set_keeper_wake_result_delivery` 선례). "묶인 예약 실행"이 조회 가능해져 #49165 판정 2항목의 실측이 서버 기록으로 가능해진다.
- 강제는 없다: Keeper 가 필드를 무시하고 새 문서를 만들어도 서버는 막지 않는다. 갈라짐은 §7 실측에 잡힌다.

### 3.2 필드가 없을 때

- 오늘과 완전히 같다. 새 문서 기본값도, 추론도 없다. 문구 안내는 폐기되지 않는다 — 여전히 유효한 지시 채널이다.
- 기존 예약에 소급 적용되지 않는다. 필드를 붙이는 것은 명시적 `masc_schedule_update` 다.

### 3.3 대상 문서가 지워졌을 때 (거절)

- 실행 시점에 문서가 없으면 Keeper 의 Revise 발행은 저장소의 `Missing` 오류("artifact or revision not found", `lib/published_artifact_store.ml:5·:16`)로 거절된다. 예약은 조용히 새 문서를 만들지 않고, 실패한 발행이 run 결과에 남는다.
- 예약을 자동 취소·만료시키지 않는다. 매일 같은 자리에서 보이는 반복 실패가 수리 신호다; 조용한 취소는 기록 자체를 멈춘다.
- 수리 경로: 예약 주인 Keeper(또는 그 예약이 깨우는 대상)가 `masc_schedule_update` 로 값을 고치거나 뺀다. 권한 규칙은 오늘 것 유지 — "a caller changes only the schedules it made or the ones that wake it"(11-06 운영자가 외부 MCP 세션의 update 거절에서 확인한 문구). 멈춰 있는 Keeper 의 예약은 운영자 화면·예약 메모(`masc_schedule_note_add`) 경로가 오늘처럼 남는다(§4).

### 3.4 revision 이 움직였을 때

- 기존 계약 그대로다. `expected_revision` 이 어긋나면 `Conflict { expected; actual }` 이 현재 revision 을 알려주고("When the revision has moved, the error reports the current revision", `config/tools/keeper_artifact_publish.toml`), Keeper 는 다시 읽어 재시도한다. 예약 수준의 조치는 없다.

## 4. 11-06 임시 조치와의 관계

- 운영자는 11-06 에 두 운영 예약의 **문구**에 고정 문서 id(`artifact-4f2be1bedca3555ac9d83897bf230f7c` 등)를 넣었다. 한 예약은 주인 Keeper 에게 메시지로 고쳐 달라 했고, 멈춰 있는 kidsnote-job-manager 쪽은 예약 메모로 남겼다. 같은 날 첫 실행이 대상 문서에 revision 2 를 만들었고(11:22:17Z), 같은 40분 창에서 새 v1 은 0 개였다 — 운영자 직독(#49165 댓글, 11-06 11:24Z).
- 이 임시 조치의 한계가 곧 §1 이다: 문구 의존이라 예약 재생성 때 사라지고, 서버가 id 를 모르고, 제3자는 권한 규칙 때문에 고칠 수 없었다.
- 이행 순서: 구현(task-3267)이 병합되면 (1) 두 예약에 필드를 설정한다 — sangsu 예약은 주인 Keeper 가, kidsnote 예약은 운영자 화면 경로로, (2) 두 예약의 문구·메모에서 id 안내를 뺀다. 그 때까지 문구가 작동하는 유일 경로다.

## 5. 대안 검토 — 운영자 11-06 20:09Z 재검토에 대한 답

운영자 재검토(#49165 댓글)는 "문구 평서문이면 충분하다"며 이슈를 닫기 후보로 묶었다. 세 근거에 하나씩 답한다.

1. **"이어 쓸 문서가 없어 새 문서가 생겨도 기록은 틀리지 않다"** — 동의한다. 그래서 이 설계는 발행을 강제하거나 되돌리지 않는다(§3.1 마지막 항). 필드의 목적은 기록 무결성이 아니라 (a) 연결의 생존(턴 경계·예약 재생성)과 (b) 측정 가능성이다.
2. **"payload 필드는 Keeper 가 할 일을 정하는 필드라 문구가 맞다"** — 절반 동의. 필드는 할 일이 아니라 **어느 문서인지**의 정체성이다. 지시문은 문구에 남고(§3.1), 서버가 렌더한 한 줄이 불완전한 문구를 보완한다. 반대로 정체성을 문구에만 두면 실측이 보여주듯 턴 경계에서 먼저 사라지고(새 문서 76번), 서버·대시보드가 연결을 알 방법이 없어 "묶인 예약"을 셀 수 없다 — 판정 2항목의 측정 주체 자체가 사라진다.
3. **"Revise 경로는 바꿀 것이 없다"** — 그대로 맞다. 이 RFC 는 `published_artifact_store` 를 한 줄도 바꾸지 않는다.

비용 비교: 임시 조치는 사람이 예약마다 문구를 편집한 뒤에야 동작했다. 새 기록 문서를 만들거나 예약을 다시 만들 때마다 같은 편집이 반복된다. 필드는 create 시점에 지정하는 예약의 속성이라 그 반복이 없다.

## 6. 구현 개요 (task-3267)

- `lib/schedule`: `masc.keeper_wake` body 스키마에 선택 필드 추가(생성 입장 경로 `Keeper_schedule_creation_admission` 과 payload 소비 경계에서 검증; `schedule_domain` 의 불투명 payload 계약은 유지). 저장은 payload 안 — 별도 컬럼 없음.
- `config/tools`: `masc_schedule_create`/`masc_schedule_update`/`masc_schedule_get` toml 파라미터·출력, `keeper_task_create` 선택 파라미터.
- wake 전달: `Schedule_payload_projection` 에 필드 투영 + 전달 문서 접미 한 줄 렌더 + 결과 스탬프에 대상 id.
- 대시보드: `server_dashboard_schedule_projection` 표시 + 운영자 편집 경로(§4 의 kidsnote 예약 이관용).
- Task: task 레코드에 같은 필드, `keeper_tasks_list` 투영. Task 발행은 기존 task_id/goal_id 링크와 별개로 `continues_artifact` 를 따른다.
- 테스트 4케이스: 필드 있음(대상 문서 revision 적립) / 없음(오늘 동작) / 대상 삭제(Missing 거절, 새 문서 없음, 예약 유지) / 형식 오류·부재 id(설정 거절).

## 7. 완료 판정

#49165 완료 판정과 1:1 이다.

- [ ] 예약(또는 Task)이 이어 쓸 아티팩트 id 를 타입으로 가리킨다 — 이 RFC 의 채택과 구현 PR 번호를 여기에 기입한다.
- [ ] 병합 뒤 3일 동안, 대상 id 가 묶인 예약 실행이 만든 새 revision 1 문서가 0 개다 — 실측: `<base>/.masc/published_artifacts/artifact-*.json` 에서 대상 id 의 revisions 길이 증가와 해당 Keeper 명의 새 문서 0 개를 집계하고, wake 결과 스탬프의 대상 id 와 대조한다. 명령과 결과를 #49165 댓글로 남긴다.
