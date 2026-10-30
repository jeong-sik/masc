# 2026-10-30: 최근 7일 핵심 기능 조사

이 문서는 완료 판정서가 아니라 **선별 조사와 남은 범위의 기능 매트릭스**다.
코드 기준은 `8ef0028e911dd83c78bc57362904e0787df72c3e`, 운영 바이너리는
`bac52cac7934ce3f75c315d474cc23f2561268c9`다. 두 SHA는 다르다. 런타임
자료는 읽기 전용으로 집계했으며, 개인 대화·프롬프트·비밀값은 싣지 않았다.
24시간 집계는 재시작을 가로지르므로 모든 실행을 현재 바이너리에 귀속하지 않는다.
[계측 방법과 집계](../evidence/2026-10-30-weekly-core-audit/README.md).

## 변경 흐름

2026-10-30 17:08:10 KST를 끝으로, 각 행은 직전 24시간의 first-parent
스냅샷 두 개를 비교한다. 파일 수와 증감은 문서와 테스트를 포함하고, rename
감지를 끈 집계라 이동된 파일을 삭제·추가로 각각 센다. 변경량은
검토한 코드의 양이나 결함 수가 아니다. 전체 SHA와 일별 집계는
[집계 파일](../evidence/2026-10-30-weekly-core-audit/diff-windows.json)에 있다.

| 기간 KST | first-parent 커밋 | 변경 파일 | 추가 / 삭제 줄 | 주요 조사 방향 |
| --- | ---: | ---: | ---: | --- |
| 10/23–24 | 180 | 1,797 | +74,530 / -17,680 | Goal publication 관측, memory 의존 상태와 Librarian health |
| 10/24–25 | 63 | 789 | +41,613 / -5,268 | checkpoint의 실제 provider binding, Runtime TUI |
| 10/25–26 | 179 | 2,333 | +177,611 / -16,837 | memory recall 저널과 Librarian absorption, HITL context 보존 |
| 10/26–27 | 154 | 3,517 | +153,694 / -59,114 | Librarian·Curator 작업 위치, runtime 관측과 TUI 갱신 |
| 10/27–28 | 175 | 2,933 | +175,428 / -16,868 | Librarian 범위 분할 설계, Goals 투영과 TUI |
| 10/28–29 | 143 | 1,398 | +89,793 / -12,287 | Librarian durable 복구, 한 Keeper turn 안의 recall 결과 재사용 |
| 10/29–30 | 135 | 1,547 | +73,929 / -14,822 | runtime 설정 검사, Board 수신자 선언, Librarian digest |

방향은 커밋 이력에서 고른 탐색 단서다. 1,029개 커밋 전체를 코드 리뷰했다는
뜻은 아니다. 아래 판정은 적힌 경로만 추적한 결과다.

18:24 KST경 다시 본 main은 `f5da935b2a6ed1891e02945dd08d2279d007d767`이다.
조사 기준 SHA 이후 first-parent 변경은 microVM probe 표현 수정 #46938, TUI 재개
ID 수정 #46951, retained-result와 Codex fixture 테스트 수정 #46899·#46900의
네 커밋이다. 이 main 관측은 운영 바이너리의 갱신을 뜻하지 않는다.

## 기능 매트릭스

`소스 확인`은 경로를 읽었다는 뜻이고 실행 성공은 아니다. `운영 관측`은 적힌
시점·바이너리·표본에만 적용된다. `미확인`은 실패나 성공 어느 쪽도 뜻하지 않는다.

| 기능 | 확인한 경계와 현재 판단 | 남은 검증 |
| --- | --- | --- |
| Runtime failover | 소스 확인: 후보 실패를 분류하고 요청 해결 의무·effect 관측을 확인한 뒤 다음 후보로 진행한다. [driver](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_turn_driver.ml), [runtime 시도](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_turn_driver_try_runtime.ml). | 재시작 후 표본에서 실패 뒤 다른 후보가 완료한 사례는 확인하지 못했다. 실제 failover 성공과 중복 effect 방지는 미검증. |
| Keeper microVM 준비 | 17:46 KST경 독립 리뷰를 요청한 한 Keeper에서 Execute 4건이 명령 실행 전 준비 단계에서 거절됐다. 최초 작업 루트 쓰기 확인은 25초에 시간 초과했고, 이후 3건은 guest 프로세스 생성 실패로 볼륨 mount 확인을 마치지 못했다. | 설치본은 첫 시간 초과를 쓰기 불가로 표현한다. 이후 병합된 [#46938](https://github.com/jeong-sik/masc/pull/46938)은 이를 확인 실패로 정정했으나 설치본 반영은 확인되지 않았다. 당시 mount 부재나 timeout의 원인은 미확인이다. |
| SSH shim 설정 읽기 | 9월 28일 원본을 가리키는 [공개 마스킹 증거](../evidence/2026-09-29-runtime-errors/d2-top5-sanitized.jsonl)의 Read 11건은 원격 shim의 설정 파일 읽기 실패까지만 확인된다. [당시 소스](https://github.com/jeong-sik/masc/blob/651e7d62c3c81edb9d847114679576122955c899/lib/exec_shim/exec_shim.ml#L439-L449)는 Unix 오류 세부를 버렸고, 다음 날 병합된 [#39788](https://github.com/jeong-sik/masc/pull/39788)은 이후 오류에 OS 작업과 설명을 보존하도록 바꿨다. | 10월 30일 확인에서 [조사 문서](../evidence/2026-09-29-runtime-errors/README.md)가 지정한 9월 28일 운영 원본은 해당 경로에 없었고 사용자는 삭제 가능성을 언급했다. 당시 errno·근본 원인과 현재 원격 shim 배포 및 Read 복구는 미확인이다. shim 제거에는 이를 대체할 원격 실행과 안전 경계의 검토가 필요하다. |
| Keeper context 생명주기 | 운영 관측: 6개 Keeper에서 전송 전 직렬화한 본문을 저장한 기록 16건은 411,840–1,926,598 B, 메시지 270–4,387개다. 가장 큰 기록에는 assistant 2,186개와 tool 2,186개가 있고 동일 role·artifact 참조의 반복은 첫 항목을 제외하면 12개다. 외부화된 도구 결과의 마커와 호출 구조도 다수 남았다. | 저장 시각으로 고른 각 turn의 마지막 관측이며 그 시간에 발송된 모든 요청은 아니다. artifact 참조가 다르다고 의미가 다른 것은 아니고 이 중복 수는 wire 절약량이 아니다. 크기 자체가 장애 증거는 아니다. 여러 turn의 보존·삭제를 검증해야 한다. [익명 집계](../evidence/2026-10-30-weekly-core-audit/largest-provider-input-aggregate.json). |
| Tool schema / result / cache | 위 16건의 도구 스키마는 40–49개, 저장된 스키마 artifact 합의 중앙값은 91,665 B다. 도구 결과 outbox는 이 표본의 마지막 입력에는 없었다. | artifact 길이는 wire 분해나 토큰 수가 아니다. provider가 보고한 cache read도 요청마다 다르므로 전체를 미캐시 비용으로 계산하지 않는다. |
| Retained tool result 신뢰 경계 | 소스 확인: 외부 도구 결과가 재전달 설명과 같은 높은 우선순위 입력에 들어가는 경로가 있다. [outbox](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_client_tool_outbox.ml). | 공격 성공은 미검증. 모델·공식 클라이언트별 role과 ACK·재실행 방지 계약을 함께 검증해야 한다. |
| Librarian 입력과 cursor | 소스 확인: 공식 client turn의 fragment가 전부 없거나 태그가 없으면 별도 채팅 구간을 읽기 전에 위치를 넘기는 분기가 있다. [consumer](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_librarian_durable_consumer.ml). | 같은 구간의 speaker 채팅이 있는 재현과 다음 tick·실패 재시도·external offset 검증이 필요하다. 운영 발생 빈도는 미확인. |
| Librarian prompt와 상대 관측 | 기준 main `50011c4550cb` 소스: 선택된 메시지나 도구 관측이 있어 처리가 진행되는 범위에서 상대 관측이 [입력으로 캡처](https://github.com/jeong-sik/masc/blob/50011c4550cb49153c189586f60bee6438b2f232/lib/keeper/keeper_librarian_durable_consumer.ml#L1507-L1557)되고 [변수로 조립](https://github.com/jeong-sik/masc/blob/50011c4550cb49153c189586f60bee6438b2f232/lib/keeper/keeper_librarian.ml#L345-L369)돼도, `librarian` [override의 변수 검증](https://github.com/jeong-sik/masc/blob/50011c4550cb49153c189586f60bee6438b2f232/lib/prompt_registry/prompt_registry.ml#L848-L866)은 [미선언 변수](https://github.com/jeong-sik/masc/blob/50011c4550cb49153c189586f60bee6438b2f232/lib/prompt_registry/prompt_registry.ml#L721-L728)만 거부하므로 `{{counterpart_observations}}`가 빠져도 허용될 수 있고, 이 경우 worker에게 렌더된 질문에서 상대 관측이 빠질 수 있다. 변수 누락에 따른 메타데이터 불일치는 [경고](https://github.com/jeong-sik/masc/blob/50011c4550cb49153c189586f60bee6438b2f232/lib/prompt_registry/prompt_registry.ml#L781-L815)하며 [렌더](https://github.com/jeong-sik/masc/blob/50011c4550cb49153c189586f60bee6438b2f232/lib/prompt_registry/prompt_registry.ml#L820-L830)는 템플릿에 있는 변수만 치환한다. 정상 결과가 Memory에 commit되면 [외부 ACK와 cursor가 전진](https://github.com/jeong-sik/masc/blob/50011c4550cb49153c189586f60bee6438b2f232/lib/keeper/keeper_librarian_durable_consumer.ml#L1569-L1582)할 수 있다. 미병합 [#46950](https://github.com/jeong-sik/masc/pull/46950)의 후보 `ad99c312cd64` [분기](https://github.com/jeong-sik/masc/blob/ad99c312cd64fd9b4ac9e391de2ccb65f21af5d5/lib/keeper/keeper_librarian_durable_consumer.ml#L1562-L1588)는 counterpart만 있는 범위도 처리하도록 넓히므로 같은 prompt 경계를 함께 확인해야 한다. | 2026-10-30 19:25 KST경 localhost:8935의 `librarian` registry 조회에서는 `source=file`, `has_override=false`와 해당 placeholder의 존재를 관측했다. 같은 리스너의 별도 health 조회는 binary commit `bac52cac7934ce3f75c315d474cc23f2561268c9`를 보고했으나 두 조회는 원자적으로 결속되지 않았다. 과거 frozen 원본·이전 override와 실제 유실·복구는 미확인이다. |
| Librarian synthesis / 복구 | 범위 영수증, progress와 continuity가 별도 상태다. 운영 24시간 표본에서 standalone 등록 63건은 모두 완료됐고 기록된 입력 사용량 합계는 137,702 tokens다. | 이 표본은 전체 fleet·실패 재시도 사용량이 아니다. clock 역전 시 이전 trace와 chat 구간의 구분, counterpart만으로 한 turn이 한도를 넘을 때 원본을 보존하는 분할·복구가 미해결이다. |
| Memory recall | 운영 관측: 4개 Keeper의 보존 저널 8개 파일에서 모델 응답 878건이 입력 16,349,641 tokens를 보고했다. 시간 판정 후보 5,935건은 Keeper별 중복을 제거하면 240개다. [recall flow](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_memory_recall_flow.ml). | 동일 후보라도 배치·상대 시간·모델 판본이 달라질 수 있다. 단순 캐시나 임의 개수 제한의 품질·무효화 안전성은 미검증. |
| Memory 생성·철회·강화 | 소스 확인: Librarian 제안은 영수증과 입력 검사를 거쳐 [Memory OS](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_memory_os_current.mli)를 변경한다. 일반 사실 recall과 source-bound 사실의 재검증·조회는 별도다. | 생성→합성→철회/대체→흡수와 복구의 전체 성공·실패 순환과 의미 품질은 미확인. |
| World Curator | 운영 24시간 표본에서 등록 46건 중 45건이 완료됐고 그중 32건 성공·13건 실패로 기록됐다. 실패에는 context 초과 4건과 결과 불명 5건이 포함된다. 입력 사용량이 기록된 35건의 합은 11,316,415 tokens, p95는 863,201 tokens다. 10건은 사용량이 없고 1건은 캡처 시 미완료다. [Curator](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/server/server_workspace_memory_curator.ml). | 등록 수는 provider 요청 수가 아니다. 소스는 초과 시 나눈 뒤 성공한 root가 가득 차면 다음 크기를 두 배로 늘린다. 표본 중 관련 요청 6건을 UUIDv7로 정렬하면 86개 초과→자식 43개 성공→나머지 43개에 대한 결과 불명 2건→나머지 43개 성공→86개 초과다. 완료·dispatch 순서, 각 실행의 바이너리와 당시 전체 상태가 확인되지 않아 원인으로 단정하지 않는다. 입력 필요성과 합성 품질도 미검증이다. [익명 집계](../evidence/2026-10-30-weekly-core-audit/curator-overflow-chain.json). |
| Skills 생성·사용 | 소스 확인: Skill은 Memory Fact와 별도이며 Keeper가 절차를 판단해 [publish 도구](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_skill_publish.ml)를 호출하는 경로가 있다. 보존된 last-prompt 중 `skill_compositions` 블록 29개의 중앙값은 303 B다. | 이 블록은 Skill의 전체 입력·실행 비용이 아니다. 자동 반복 발견, 추출·중복·적용·폐기와 토큰 비용은 미확인. |
| Skill 목록과 schema 크기 | 운영 표본 16건 모두 `keeper_skill` schema artifact의 기록된 길이가 26,364 B였고 참조가 같았다. 각 기록의 전체 schema artifact 길이 합에서 해당 artifact가 차지한 비율은 24.96–31.57%다. 소스는 instruction Skill 목록과 설명을 이 도구의 설명에 넣는다. [schema 조립](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_tool_composition_surface.ml). | 기록된 artifact 길이와 wire token·cache miss는 다르며, 같은 참조는 사용하지 않는 Skill이라는 뜻이 아니다. Skill body는 호출과 별도 Task 경로를 포함해 추가 확인이 필요하다. |
| Skill 발행 감사 | 감사 기준 `8ef0028e` 소스에서는 Keeper 발행의 생성·카탈로그 갱신 결과와 쓰기 결과 불명에 대해 행위자와 evidence의 감사 기록을 시도하나 일반 예외는 경고만 내고 발행 결과에 알리지 않았다. [발행](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/server/server_keeper_skill_publish.ml), [감사](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/server/server_skill_write_audit.ml). 이후 [#46972](https://github.com/jeong-sik/masc/pull/46972)는 감사 호출을 시도한 Keeper 발행 결과에 `audit_status`를 추가해 호출 반환과 일반 예외를 각각 [`audit_call_returned`와 `unconfirmed`](https://github.com/jeong-sik/masc/blob/6424eab4d9db421bd4067d163c840c1c6d95780a/lib/keeper/keeper_skill_publish.ml#L95-L97)로 알린다. 사전 거절 등 감사 호출이 없는 결과에는 필드가 없을 수 있다. | `audit_call_returned`는 감사 행의 존재나 내구성을 증명하지 않고, `unconfirmed`도 행의 부재를 뜻하지 않는다. [HTTP 편집기](https://github.com/jeong-sik/masc/blob/6424eab4d9db421bd4067d163c840c1c6d95780a/lib/server/server_routes_http_routes_dashboard.ml#L833-L841)는 감사 상태를 응답에 싣지 않는다. 특히 [HTTP create의 오류 분기](https://github.com/jeong-sik/masc/blob/6424eab4d9db421bd4067d163c840c1c6d95780a/lib/server/server_routes_http_routes_dashboard.ml#L2289-L2300)는 감사 호출 없이 응답한다. 일부 `Write_failed`는 [디렉터리 생성 뒤 fsync나 파일 저장·정리 과정](https://github.com/jeong-sik/masc/blob/6424eab4d9db421bd4067d163c840c1c6d95780a/lib/server/server_skill_editor.ml#L756-L800)에서도 발생하므로 효과 부재를 증명하지 않는다. 실제 운영 발생은 미확인이다. 이미 생성된 Skill을 일반 실패로 돌려 중복 발행하게 해서는 안 된다. |
| Board visibility / 접근 제어 | 소스 확인: 제한 공개 글의 주소 없는 댓글이 비참여 Keeper의 semantic attention 후보가 될 수 있다. 기존 [#37152](https://github.com/jeong-sik/masc/issues/37152)는 viewer 없는 읽기 등 더 넓은 문제를 추적한다. [audience](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_board_audience.ml), [dispatch](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/board/board_dispatch.ml). | 새 후보 차단만으로 이미 기록된 Pending/Judged 후보, Direct 명시 수신자·broadcast, 읽기·HTTP/cache 권한이 해결되지는 않는다. 실제 유출 발생은 미확인. |
| Board 수신과 재기동 | 소스 후보: metadata는 남고 registry에는 없는 Keeper에게 지정된 글을 쓸 때 durable 수신과 재시작 후 재생이 누락될 수 있다. 만료된 부모 댓글 때문에 같은 글의 뒤쪽 댓글 재생이 중단될 수도 있다. 주소로 기록된 별칭은 당시 Keeper를 식별하지 않고, 재생은 저장된 별칭을 현재 Keeper 설정의 대상 ID와 대조한다. | 중지·retire·재기동 계약과 실제 재현을 확인해야 한다. 별칭이 다른 Keeper에게 옮겨간 기록은 옛 수신자를 그 기록만으로 복원할 수 없다. 이미 큐에 든 attention의 소비 경계도 남는다. |
| Goal / Task | 소스 확인: 모든 진행 가능한 Goal의 기준·review note·측정치를 Keeper turn의 공유 Goal 목록으로 조립한다. 보존된 last-prompt 31개에서 해당 블록 중앙값은 53,522 B다. | 공유 Goal은 의도된 계약이다. 관련성·계속 증가하는 크기와 task 링크 실패를 측정한 뒤 개선해야 하며 크기만으로 임의 삭제하지 않는다. |
| HITL / 접근 권한 | 소스 확인: 승인 요청을 저장하고 결정을 저널에 남긴다. 일회 승인 소비 시 Keeper·도구·입력 지문을 대조하며, 승인과 효과 적용을 별도로 기록한다. 소비 후 결과가 없으면 결과 불명으로 남기는 경로도 있다. [승인 큐](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_approval_queue.ml), [효과 재개](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_gate_replay.ml). | 실제 승인 생성→전달→결정→효과의 전체 성공, 중간 재시작, actor와 capability 적용은 미검증이다. Board read 권한은 별도로 남는다. |
| Schedule / drain | 소스 확인: 일부 반복 예약의 다음 발화나 명시적 취소가 이미 turn에 선택된 발화를 철회할 수 있다. 그 turn은 이미 받은 입력을 계속 실행할 수 있으며, 해당 발화의 ACK를 시도하면 철회된 항목으로 처리된다. [취소](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_registry_event_queue.ml), [turn 정산](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_heartbeat_loop.ml). | 결과 전달 없는 Interval은 대상 큐에서 이전 미소비 발화가 관측되면 다음 due 발화를 hold한다. 기존 [#40006](https://github.com/jeong-sik/masc/pull/40006)은 철회를 의도했지만, 감사 기준 Glossary에는 이전 보존 정책이 남았다. 취소·대체와 실행 증거의 계약 및 실제 운영 발생을 확인해야 한다. |
| Multi Lane / 인계 | 소스 확인: Task claim은 파일 잠금 안에서 소유자를 정하고 각 Keeper의 turn은 자체 owner 슬롯을 공유한다. 비동기 composition은 요청별 원본과 완료 outbox를 결속하고, 완료 증거 확인 후 submitter 큐에 결과를 전달한다. 재시작 시 owner를 잃은 Queued/Running 요청은 Lost로 정리하고 일반적인 결과 불명 effect를 재실행하지 않는다. [claim](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/workspace/workspace_task_claim.ml), [완료 전달](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_composition_completion_wake.ml). | 같은 Task를 명시한 별도 실행 전체가 전역적으로 한 번만 수행된다는 보장은 이 경로에서 확인되지 않는다. 큐 전달과 모델이 결과를 읽은 것은 다르다. 실제 병렬 실행·재시작 복구는 미검증이다. |
| Drain queue | 18:26 KST경 health는 실행 가능한 Keeper에 속한 대기 18건, 일시정지·중지 대상 대기 71건을 보고했다. 해당 Keeper의 오래된 `ask_answered` 하나는 같은 source의 ledger에 시작·종료 물리 행이 각각 4개 있고, 종료 disposition은 `checkpointed` 2개와 `failed` 2개다. 시작 기록은 provider dispatch 이전에 남는다. | 각 kind의 행은 같은 event ID를 공유한다. 실제 모델 수신 횟수나 실패 원인을 이 기록만으로 단정할 수 없다. 다른 소스의 start/finish 기록 정책도 다르다. 등록·부재·취소·재개와 projection의 중복 제거를 검증해야 한다. |
| Queue 반응 시각 | 운영 관측: 위 `ask_answered`의 조회 API는 ledger의 뒤쪽 시작·종료 행보다 이른 시각을 반환했다. 소스는 같은 stimulus의 각 turn 시작·종료에 같은 event ID를 쓰며, 조회는 이미 본 ID를 건너뛴다. [기록과 조회](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_reaction_ledger.ml). | 해당 reaction 행에는 재기록과 새 시도를 구별할 turn ID가 없어 최댓값만 취하면 서로 다른 시작·종료를 한 시도로 잘못 묶을 수 있다. API 시각은 최신 시도의 증거가 아니며, 기존 기록과 새 시도의 식별 계약이 필요하다. |
| TUI Queue 재개 | 소스 확인: 서버가 재개 기록을 저장하고 상태 반영에 실패한 202를 반환해도 TUI가 성공으로 해석하고 보류 입력을 푸는 경로가 있다. [서버 응답](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/server/server_dashboard_http_keeper_api_post.ml), [TUI 분류](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/bin/masc_tui_keeper_control.ml). | 기록과 반영을 구분해야 한다. 이전 영수증의 무조건 재전송은 이후 새 pause를 해제할 수 있고, 미등록 Keeper의 Boot는 202 뒤 별도 단계가 필요하다. 실제 입력 유실·운영 발생은 미확인. |
| TUI Queue–Keepers 재개 연결 | 후속 조사 기준 `5a75969f2a07` 소스 확인: 같은 TUI에서 Queue pause가 입력을 [`Retained_after_stop`으로 보류](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/bin/masc_tui_types.ml#L15835-L15875)한 뒤, 등록된 paused owner에 대한 Keepers 화면의 Resume 요청이 [200](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/lib/server/server_dashboard_http_keeper_api_post.ml#L1752-L1761)·[`projection=running`](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/lib/server/server_dashboard_http_keeper_api_post.ml#L1639-L1661)으로 끝나도 [Keepers 완료](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/bin/masc_tui.ml#L20589-L20646)는 [Queue의 입력 해제 확인](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/bin/masc_tui.ml#L19384-L19402)에 연결되지 않는다. 직접 Resume은 독립 조회의 시차 등으로 로컬 `paused=true`와 roster `keepalive_running=true`가 겹칠 때 노출된다. 최신 `Paused`/false에서는 Boot를 제안하며, 그 409 복구 중에도 Resume을 보낸다. [동작 선택](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/bin/masc_tui_keeper_control.ml#L235-L274), [복구 실행](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/bin/masc_tui.ml#L17789-L17839). | 이후 `/queue resume`은 `Retained_after_stop`이 있으면 [로컬 preflight 대상이 아니어서](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/bin/masc_tui_types.ml#L15775-L15780) 권한·전송 조건이 충족되면 [새 Resume 요청을 보내고](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/bin/masc_tui.ml#L10350-L10453), owner가 여전히 [active](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/lib/keeper/keeper_paused_work_resume_transaction.ml#L135-L144)이면 [409로 거부](https://github.com/jeong-sik/masc/blob/5a75969f2a07866c5abe845593862c797cdaa563/lib/server/server_dashboard_http_keeper_api_post.ml#L1612-L1621)될 수 있다. 해당 보류 입력의 운영 재현·유실·수신은 미확인이다. 200과 running 투영은 fiber 실행이나 입력 수신의 증거가 아니며, 위 202 분류 문제와 별도다. |
| TUI Keeper 상태와 조작 | 소스 확인: 서버의 `keepalive_running`은 현재 phase에서 turn 실행 가능 여부이고 Paused도 false다. TUI는 이 false를 fiber 부재와 동일하게 취급해 Boot를 제안한다. [상태](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/keeper/keeper_status_runtime.ml), [조작](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/bin/masc_tui_keeper_control.ml). | 정지·미등록·살아 있는 paused lane을 구분하고 재개 결과의 새 관측을 받아야 한다. workspace 조건을 추가하는 로컬 후보는 이전 서버의 무타입 409 처리에 회귀가 있어 보류 중이다. |
| TUI Keeper 삭제 | 감사 기준 소스 확인: TUI가 workspace를 확인한 뒤 purge를 요청하지만, 요청에는 확인한 workspace가 포함되지 않는다. 서버는 수신 시점의 workspace와 Keeper 이름으로 삭제를 접수한다. [클라이언트](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/bin/masc_tui_http.ml), [서버](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/lib/server/server_dashboard_http_delete_actions.ml). | 확인과 전송 사이 서버 workspace가 바뀌고 같은 이름이 존재하면 다른 대상에 요청할 수 있다. 실제 발생은 미확인이다. [#46959](https://github.com/jeong-sik/masc/pull/46959)가 새 서버와 새 TUI 조합의 조건 검사를 main에 추가했다. 구버전 조합과 별도 재시도 API, 운영 적용은 미해결이다. |
| TUI 연결 / 가시성 | 감사 기준 소스에서는 Queue의 Schedule 정의 행에서 순서를 바꾸려 할 때 예정 시각에 작업이 실행된다고 안내했다. [#46973](https://github.com/jeong-sik/masc/pull/46973)은 [이 한 안내](https://github.com/jeong-sik/masc/blob/d44ffd874b064f40875c8d91f64b799fadef9441/bin/masc_tui.ml#L10648-L10653)를 여기서 순서를 바꿀 수 없고 예정된 작업이 기다릴 수 있다고 정정했다. 별도의 pending Event 행에 대한 같은 조작은 `Immediate` 또는 `Low` urgency [변경 요청](https://github.com/jeong-sik/masc/blob/d44ffd874b064f40875c8d91f64b799fadef9441/bin/masc_tui.ml#L10454-L10465) 경로로 간다. | 실제 TUI 렌더링과 운영 적용은 미검증이다. Event 요청의 실제 수락·소비와 다른 Queue·Goal·HITL·Runtime·Memory의 stale/unknown/실패 표시와 실제 조작도 미검증이다. |
| Terminal-Bench | 저장소에 [4.0 Harbor adapter](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/benchmarks/terminal_bench/README.md)가 있다. 데이터셋 격리 계획 2개와 설정 렌더링 8개 Python 테스트가 기준 코드에서 통과했다. | 로컬 Harbor는 0.22.0이고 문서의 환경은 0.23.0 고정이다. 실제 태스크·점수·전체 세트는 실행하거나 검증하지 않았다. |

## 시간축과 용어 경계

용어는 [Glossary](https://github.com/jeong-sik/masc/blob/8ef0028e911dd83c78bc57362904e0787df72c3e/docs/spec/00-glossary.md)를 따른다. Keeper **cycle**은 관측과
실행 여부의 한 회차이며 반드시 모델을 부르지 않는다. Keeper **turn**은 하나의
작업 시도이고, Agent Core run과 그 안의 turn은 다른 단위다. Librarian의
boundary·range receipt·progress는 이 turn들을 읽어 기억을 갱신할 때의 별도
증거다. Memory recall은 저장 기억을 현재 요청으로 가져오는 선택이며 원본 삭제와
동일하지 않다. Goal은 공유 의도, Task는 구체적인 작업, Board는 대화·발견
표면이고 각자의 저장 권위를 가진다.

정상적인 반복에서 살펴볼 질문은 다음과 같다. N번째 turn의 결과와 외부 입력이
영속적으로 구분되는가, Librarian이 읽은 범위의 기억 commit 전에 cursor를
넘기지 않는가, 다음 turn의 context가 회수된 결과와 유지해야 하는 의무를 함께
보존하는가, 실패나 재시작 뒤 N+1번째 turn이 같은 외부 effect를 다시 실행하지
않는가. 위 매트릭스의 Librarian 분기는 첫 두 질문의 경계에서 발견한 결함이다.
나머지는 실제 성공·실패·복구를 여러 tick에 걸쳐 검증해야 한다.

## 조사에서 분리한 변경

2026-10-30 조사 중 [TUI 재개 ID](https://github.com/jeong-sik/masc/pull/46951)는
독립 소스 승인과 가드 확인 후 main의 `865bbe5e0490bf5861e56ff1057da8f35ed970e0`에
병합됐다. 이 수정은 위 202와 pause 세대 경합을 해결하지 않는다.
[삭제 workspace 조건](https://github.com/jeong-sik/masc/pull/46959)은 같은 절차로
`d528b7e0c150f84ca07c25064339a3461f8e7208`에 병합됐다.
[예약 발화 용어](https://github.com/jeong-sik/masc/pull/46952)는
`01667b098a5ea1166e82888eb95878cced9f5bca`에 병합됐다.
[Skill 발행 감사 관측](https://github.com/jeong-sik/masc/pull/46972)은
`6424eab4d9db421bd4067d163c840c1c6d95780a`에,
[Queue Schedule 안내](https://github.com/jeong-sik/masc/pull/46973)는
`d44ffd874b064f40875c8d91f64b799fadef9441`에 병합됐다.
[Board 후보](https://github.com/jeong-sik/masc/pull/46949)와
[Librarian 범위](https://github.com/jeong-sik/masc/pull/46950)는 남은 경계가 있어
보류했으며, Librarian PR에는 독립 리뷰의 변경 요청이 있다. 병합은 설치·운영 적용의
증거가 아니다.

## 우선순위

1. 제한 공개 댓글의 비참여자 fanout, Librarian의 무태그 범위 채팅 누락,
   TUI Queue 재개의 잘못된 성공 판정을 각각 작은 변경으로 재현·수정한다.
   Board에 이미 남은 후보와 전체 read ACL도 별도로 확인한다.
2. 실제 provider input, history marker, recall 판정의 증가 원인과 Curator의
   크기 복귀 정책을 각각 추적한다. 정확한 신뢰 경계와 유효기간이 정의되기
   전에는 기억이나 도구 결과를 버리거나 모델 판정을 재사용하지 않는다. 초과
   뒤 크기를 영구 고정하면 작은 묶음에 장기간 갇힐 수 있으므로 처리량과 안전한
   재증가 근거도 검증해야 한다.
3. 중지 Keeper 주소 지정, HITL, schedule/drain, TUI 조작의 운영 계약과 실패
   복구를 검증한다. 이후 설치된 동일 SHA로 실제 Terminal-Bench 결과를 수집한다.
