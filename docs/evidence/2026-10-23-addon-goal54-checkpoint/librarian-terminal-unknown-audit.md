# Librarian unknown terminal 후속 감사

판정: **P2 경계가 현재 관측 head에서도 남음**. 실제 host가 보존한 `Exact.Outcome_unknown`이 original `Rejected`가 된 뒤, 다음 일반 wake에서 같은 unread source와 겹치는 입력을 **새 request ID와 새 provider 실행**으로 선택할 수 있습니다. 옛 ID 자체의 submit-once는 보존되지만 source 차원의 no-new-provider 불변식은 보존되지 않습니다. 이는 source 경로 판정이며, 이 감사에서 재현 실행을 한 것은 아닙니다.

## 정확한 관측 범위

- 최초 REST 관측: 2026-10-23T06:48:44Z, Stack #45095의 16개 open PR, top #45357 `ebd0ac219e541b68b035dec572f57e11c8fa0d4c`, 직접 base `fbd9be775387893c81373c44bf681f676045f109`.
- 감사 도중 원격이 이동하여 다시 수집했습니다. 현재 보고서의 근거는 `current-444ce2d5/vector.json`에 기록한 16개 REST head/base/stack metadata와 top #45357 `444ce2d57c7a2a74353fb3e8189cdde04d8f94b9`, 직접 base `76e6a04f69f5d3b810501ed4a43e67c6bff0a32a`입니다. stack main base는 `123f2f821a60f5c6d2250d6dbea7f049aec1faae`입니다. 이후 원격 이동에 대한 영구적인 현재성은 주장하지 않습니다.
- exact tree에 결속한 관련 source 28개를 동결했습니다. 최초 head의 27개도 그대로 보존했습니다. `source-manifest.json`은 파일마다 Git blob 및 SHA-256과 읽은 commit을 기록하며 모든 bytes를 재검증했습니다. 현재 head의 9개 변경 파일 delta를 별도 patch에 보존했습니다. 이는 16층 전체 diff의 완전한 독립 리뷰가 아닙니다.
- 기존 dbac 로컬, 사용자 checkout, production branch, stack, source를 수정하지 않았습니다. 원격 owner 세션은 Git author로 추정하지 않았습니다. 공식 source 승인, CI, OCaml 타입/빌드/시험, 설치 또는 실환경 성공 판정은 없습니다.

## P2: 실제 terminal unknown을 새 선택 허가로 처리

| 순서 | 현재 exact source와 경계 |
| --- | --- |
| 1. Unknown 발생 | `lane_addon_exact.ml:657–666`은 원래 started marker가 있으나 완료 proof가 없으면 actual host record에 `Outcome_unknown`을 보존합니다. `:725–746`의 call 예외도 같은 final을 보존할 수 있습니다. 이는 worker가 임의로 반환한 JSON을 신뢰한다는 주장이 아닙니다. |
| 2. 엄격한 원본 검증 | `keeper_librarian_durable_request.ml:307–331`은 원래 physical owner, exact request/schema, 실제 retained terminal의 일치를 확인합니다. 그 뒤 `Outcome_unknown` 자체는 허용합니다. `durable_commit.ml:233–241`도 Rejected Execution evidence를 decode하고 같은 actual terminal을 검증하여 정상으로 처리합니다. |
| 3. Refused가 됨 | `lane_addon_submit_once.ml:103–113`의 finish는 Answered 외 final을 `Progress.Refused { stage=Execution; evidence }`로 기록합니다. `request_progress.ml:186–190`에서 이것은 `Rejected`입니다. `durable_owner.ml:142–151`은 actual `Outcome_unknown`을 Refusal로 반환합니다. |
| 4. 첫 wake | `durable_execution.ml:248` 또는 `:315`는 이 Refused를 nonempty diagnostic인 `Memory_not_committed`/`Memory_refused`로 반환합니다. 메시지 descent와 capacity 권한을 주지 않는 것은 맞습니다. `durable_consumer.ml:1567–1578`은 Memory_refused에서 Memory 확인/외부 ACK/cursor advance를 실행하지 않습니다. |
| 5. 다음 wake의 선택 | `durable_execution.ml:72–75`는 **모든 Rejected**를 active에서 제외합니다. `:254–275`의 strict original 검증과 lineage 검사도 unknown을 unfinished로 복원하지 않습니다. 그래서 unknown original 하나만 있어도 `:303–316`의 `[],[]` 분기로 새 `Consumer.consume_one`과 capture에 도달합니다. |
| 6. 새 ID와 provider | `durable_request.ml:104–105`는 UUID 기반 fresh ID를 생성합니다. `durable_execution.ml:137–161`의 새 root capture는 predecessor 없이 현재 configured destination을 읽어 새 full original을 retain하고 resume합니다. `server_librarian_addon_validation.ml:29–68`은 이 새 original의 owner/digest/destination을 정상 검증하며 원래 unknown source와의 중복을 막는 별도 barrier는 없습니다. 같은 설정에서도 재호출이 가능하고, 허용된 설정 변경 뒤라면 새 original의 현재 route를 이용할 수 있습니다. 설정 교체가 필요조건은 아닙니다. |

실제 생산 경로는 `keeper_librarian_queue_refresh.ml:295–299`의 `run_durable → durable_execution.consume_one`입니다. `:205–217`은 Memory_not_committed를 일반 Not_committed로 반환하고 `:854–861`은 후속 phase를 허용합니다. 다음 보통 queue signal 또는 `submit_durable`(`:964–975`)이 새 pass를 시작하면 위 fresh-selection 경로를 다시 탑니다. unknown refusal이 스스로 무한 wake를 만든다고 주장하지 않습니다. 후속 일반 wake 하나가 충분한 조건입니다.

기존 Request/host record는 소실되거나 덮이지 않습니다. 새 provider 호출은 **원래 ID의 재전송이 아니라 새로운 root ID의 별도 실행**이므로 per-ID submit-once만으로 막히지 않습니다. `durable_consumer.ml:1590–1621`의 process-local failed marker 때문에 다음 source가 항상 byte-identical이라는 주장은 하지 않습니다. 하나의 unread 단위면 같은 source가 다시 선택될 수 있고, 여러 단위면 first cut point로 좁아진 겹치는 source가 선택될 수 있습니다. 어느 경우도 unknown이 source 차원의 새로운 provider 권한을 부여하지 않아야 한다는 경계를 해결하지 않습니다.

## 안전하게 구분해야 하는 unknown 두 종류

- worker RPC의 `Sent_unknown`, waiting 또는 dispatched 뒤 absence는 `lane_addon_submit_once.ml:94–103`의 `Dispatch_pending (Outcome_unknown ...)` 관측으로 남습니다. 이 phase는 active이므로 fresh selection을 차단합니다. 이 경로를 위 결함과 혼동하지 않습니다.
- 실제 host **terminal** `Exact.Outcome_unknown`을 얻으면 위 finish가 `Rejected Execution`으로 저장합니다. 여기가 active=false이므로 다음 fresh selection이 열립니다. 정확한 terminal proof가 있다는 사실은 provider 효과의 성공/실패가 확인됐다는 뜻이 아닙니다.
- host `Commit_unknown`은 active로 남습니다. Memory publication unknown을 이 감사에서 같은 결함이라고 판정하지 않습니다.

## 기존 실제 회귀가 놓치는 경계

`test_keeper_librarian_durable_execution.ml:410–448`은 actual HTTP 400 `Input_refused Invalid_request` 뒤 새 root의 성공, old original 불변, 두 provider call을 검증합니다. 이는 **definite refusal**의 양성 사례이며 terminal Outcome_unknown의 안전성을 검증하지 않습니다. 이 positive case는 수리 후에도 별도로 보존해야 합니다.

`:716–746`의 purge/cancel + 실제 worker restart 사례는 unknown 복구에 의미가 있습니다. 그러나 restart 뒤 `run_worker`를 **한 번** 호출하고 `Pending | Memory_not_committed _`를 둘 다 허용합니다. 그 한 번이 terminal unknown을 Rejected로 정산한 경우에도 통과할 수 있고, **그 다음 보통 wake**에서 새 original을 생성하는지 검사하지 않습니다. 그래서 해당 테스트의 기존 no-new-provider assertion을 이번 two-wake 경계까지의 실행 증거로 확대할 수 없습니다. fixture의 provider join도 `:325–331`에서 모든 Rejected를 제외하여 새 동일-input original을 허용합니다.

## 필요한 typed 수리 port

1. 기존 source validation 뒤, actual host terminal의 닫힌 타입을 이용하는 **domain frontier disposition**을 한곳에서 정합니다. 예: `Resume_original | Await_original_outcome | Definite_refusal_finished | Finished | Superseded`. Rejected라는 progress phase만으로 모든 refusal을 끝난 frontier로 분류하지 않습니다. malformed/unknown evidence는 기존 strict 오류로 유지합니다.
2. actual `Exact.Outcome_unknown`은 immutable original과 unread source를 계속 점유합니다. 이미 디스크에 존재하는 Rejected/Outcome_unknown도 같은 typed 분류로 복구해야 합니다. 새 ID 생성, fresh source selection, 현재 provider로 fallback, successor subdivision 또는 source ACK를 허용하지 않습니다. 첫 관측과 이후 재시작 모두 `Consumer.Pending` 등 명시적인 pending 의미로 연결하여 unknown을 generic failed-range/descent 또는 후속 Memory phase 진행 허가로 바꾸지 않습니다.
3. definite `Input_refused Invalid_request` 등 fresh selection을 허용할 final은 constructor별로 정책을 명시합니다. 새 constructor나 diagnostic 문자열/substring/catch-all이 허가를 확대하지 않게 합니다. 기존 실제 definite-refusal 양성 회귀를 유지합니다. `Not_allowed`/`Request_id_reused`도 무조건 same-policy라고 묶지 말고 실제 authority/identity 의미를 판단해야 합니다.
4. 원래 host가 이미 immutable Outcome_unknown final로 끝났다면, 단지 provider의 늦은 답을 기다리거나 재전송해서 자동 복구할 수 있다고 약속하지 않습니다. recovery proof가 아직 unknown 보존 전 원래 started marker에 결속돼 있다면 기존 publication-only 경로를 사용합니다. 이미 확정 unknown의 해소는 별도 명시적 operator/domain resolution 증거가 필요하며, 새 provider 호출을 그 대용으로 만들지 않습니다.

## 필요한 actual-state 회귀

기존 real worker/host Exact/Memory-lane fixture를 사용하고 가짜 결과 enum만 넣는 테스트로 끝내지 않습니다.

1. 원래 실제 host call을 started 뒤 취소/예외로 끝내고 worker를 재시작합니다. actual `Exact.observe_retained`가 같은 request ID의 `Retained_terminal Outcome_unknown`을 반환하고 original이 그 terminal에 strict-bound된 상태임을 먼저 확인합니다. RPC Sent_unknown 또는 단순 Pending만으로 대체하지 않습니다.
2. terminal 관측 wake 뒤에 **두 번째 및 세 번째 보통 production wake**를 실행합니다. original ID/개수, request body/digest, progress evidence, provider POST 수가 증가하지 않고 original unknown이 fresh root로 대체되지 않아야 합니다. fixture helper도 unknown original을 새 provider join 대상에서 숨겨서 성공시켜서는 안 됩니다.
3. source checkpoint/official/external 위치와 prepared external pending, Memory/WAL/absorption journal을 reread하여 no ACK/no cursor advance/no Memory effect를 검사합니다. scope 전체 source validation과 lineage 오류는 계속 차단되어야 합니다.
4. worker restart, Off → On, 허용된 current destination/route 교체 뒤에도 같은 원본 pending이 유지되고 새 route 서버에 provider call이 0회여야 합니다. 이미 ACK된 child 손실 및 basis-supersession 회귀와 섞어서 unknown을 새 successor 권한으로 만들지 않습니다.
5. 별도로 definite Invalid_request 뒤 fresh-selection 성공, RPC Sent_unknown의 같은-ID read-only 복구, retained Answered/Commit_unknown의 publication-only 복구를 유지합니다. 새 typed 정책이 기존 정상 복구를 중단시키지 않음을 확인해야 합니다.

## 원래 54개 Goal의 판정 유지

| 항목 | 이 감사에서 확인한 경계와 남은 기준 |
| --- | --- |
| D03 | old original의 immutable identity/full capture는 보존되지만 source 차원의 unknown 뒤 새 root가 가능하므로 전체 완료 판정은 하지 않음. request/stage/input/schema/route/trace 후 one-dispatch 기준 유지. |
| D04 | RPC pending과 terminal unknown의 retry 의미가 다르게 처리되는 위 P2 미해결. transport/잘못된 출력/거절/효과 불확실을 typed로 구분하는 기준 유지. |
| D05 | host가 실제 original과 destination을 검증하는 경로를 읽었으나 credential 유출 여부, 실제 provider queue/cancel/concurrency 전체를 재검증하지 않음. 완료 승격 없음. |
| D06 | old terminal은 보존되지만 old unknown 뒤 새 current-route inference가 가능하므로 no-replay 경계 미충족. 설정/detach/late-response 전체 완료 판정 없음. |
| E03 | checkpoint·absorption·Memory lineage·pending·Keeper 기억 연속성 기준을 축소하지 않음. 현재 history owner의 특정 unknown 경계를 감사한 것이며 continuity/working-context/maintenance/history capacity descent 전체와 유료 provider/실제 UI/운영 설치 검증은 남아 있음. |

worklist의 기존 이름/54개 완료 기준과 pending 증거를 수정하지 않았습니다. 이 후속이 E03 또는 Stack45095 전체 승인을 의미하지 않습니다.

## 산출물과 증거 한계

- 최초 `stack.json`, `pr-*.json`, `vector.json`, exact source27 + manifest를 원본 그대로 보존했습니다.
- 새 `current-444ce2d5/stack.json`, 16개 `pr-*.json`, `vector.json`, exact GitHub `tree.json`, source28 + manifest 및 `audited-files-from-ebd0ac.patch`를 추가했습니다.
- 최초 bare audit fetch는 inherited object connectivity의 missing blob로 실패한 기록이 있습니다. 실제 source는 exact Git object 또는 GitHub exact blob을 읽고 Git blob 및 SHA-256을 검증했습니다. fetch 성공이나 완전한 checkout으로 포장하지 않습니다. 사용자 checkout/ref/stack은 변경하지 않았습니다.
- 별도 bare audit repo의 `refs/audit/current-444ce2d5-pr-*`에 16개 exact commit ref를 결속했습니다. 새 top fetch도 connectivity 오류로 종료했으므로 완전 fetch를 주장하지 않습니다. 필요한 exact commit object와 GitHub tree/blob 증거를 구분해 보존했습니다.
- 로컬 Dune/type/build/OCaml test, CI dispatch/watch, paid provider, runtime 설치와 UI 실행은 하지 않았습니다. source finding을 실행 실패/성공이나 공식 approval로 확대하지 않습니다.
