# Librarian terminal unknown 수리 후보

**구현 완료, 독립 source 리뷰 및 OCaml 타입/실행 검증은 아직 미완료입니다.**

별도 detached worktree `/tmp/masc-librarian-terminal-unknown-repair-20261023`에서 main을 새로 fetch한 `f985fde683092953b33cfcab0884ef9f27d17ad9`를 base로 사용했습니다. 요청 시점의 fe1e8 이후 main이 이동했으므로 fresh fetch의 실제 SHA를 기록했습니다. base에서도 모든 Rejected를 active에서 제외하고 실제 terminal Outcome_unknown을 Refused로 반환하는 경계가 남아 있음을 직접 재확인했습니다. `fresh-main-finding-source.txt`에 원문을 남겼습니다.

## 바꾼 동작

- `durable_commit.validate`의 기존 strict host proof / original / preparation / Gate lineage / commit-marker 검증은 유지하고 결과를 닫힌 타입 `frontier = Unfinished | Settled`로 확장했습니다. 기존 검증이 decode하고 actual host terminal과 결속한 **같은 final 값**에서 `Outcome_unknown`만 Unfinished로 반환합니다. classification용 추가 저장소·registry·JSON 재decode는 없습니다.
- `durable_execution`은 검증에서 얻은 unfinished original들을 원래 순서로 유지합니다. 기존 generic progress-phase active 판정은 제거했습니다. Rejected라는 이유로 모두 차단하거나 모두 통과시키지 않습니다. Finished/known conflict/definite refusal은 기존 분류를 유지하고 strict successor-lineage 검증도 유지합니다.
- `durable_owner`는 shared submit-once의 terminal validation을 통과한 `Refusal (Exact.Outcome_unknown, original)`만 기존 `Pending (Worker_unknown, original)`으로 반환합니다. 실제 immutable Rejected/Outcome_unknown evidence는 그대로 남습니다. 첫 terminal 관측도 Pending이 되어 failed-range marker나 후속 Memory phase를 허가하지 않으며, 다음 wake도 같은 원본을 복구합니다.
- actual definite `Input_refused Invalid_request` 뒤 새 ID 선택은 그대로 허용합니다. RPC Sent_unknown은 기존 Dispatch_pending 관측으로 남고, Answered/Commit_unknown의 publication-only 복구 및 Off에서 로컬 정산하는 경로는 변경하지 않았습니다. 이미 immutable terminal unknown으로 끝난 host final을 새 추론으로 해소하는 기능은 추가하지 않았습니다.

MLI 3개를 먼저 수정한 다음 ML을 맞췄습니다. 기존 validate의 내부 호출 2개는 strict 검증 성공을 계속 요구하며 frontier 반환값만 버립니다. 새 필드, wire format, 공통 submit-once event, store schema, provider registry를 추가하지 않았습니다.

## 실제 상태를 검사하도록 강화한 회귀

기존 `test_keeper_librarian_durable_execution` target과 실제 Python worker / Runtime / host Exact HTTP / Memory lane fixture를 그대로 사용했습니다. 기존 purge/restart 테스트를 강화하고 같은 경계를 Mixed history에도 등록했습니다.

1. 실제 HTTP provider를 시작한 뒤 Memory lane purge로 취소·unwind를 확인하고 실제 worker를 재시작합니다. 원래 request ID/schema로 actual `Exact.observe_retained`를 읽어 **Retained_terminal Outcome_unknown**임을 먼저 확인합니다. transport unknown이나 fake result로 대신 통과하지 않습니다.
2. 첫 ordinary owner wake가 정확히 Consumer.Pending이고 그 terminal이 원래 Rejected/Execution evidence로 보존됐는지 확인합니다.
3. 공개 production `Refresh.submit_durable`로 두 번째·세 번째 wake를 실제 serialized Memory lane에 넣습니다. last_measurement가 Pending이어야 하며 새로운 original ID가 없어야 합니다.
4. Rejected/Outcome_unknown이 durable하게 남은 뒤 worker를 다시 Off/On 재시작하고 production wake를 넣습니다. Addon Off에서도 original owner는 로컬 Pending으로 복구돼야 합니다.
5. 매 경계에서 동일한 유일 원본 ID·완전 input/preparation·progress evidence·provider POST 수, atom progress, official cursor 및 prepared external cursor, Memory snapshot/journal/range WAL/publication receipt/continuity 상태를 실제 저장소에서 다시 읽어 비교합니다. 외부 evidence 1개가 실제 pending이고 ACK offset이 0임을 확인하며 새 absorption gate가 없어야 합니다.

회귀는 **작성하고 parser만 확인했습니다. 실행 PASS가 아닙니다.** 기존 definite Invalid_request 뒤 새 original 성공, 실제 Answered/Memory receipt 실패 뒤 Off 복구, 알려진 basis supersession 회귀는 지우거나 assertion을 완화하지 않았습니다. RPC Sent_unknown 공용 회귀 target도 그대로 있습니다.

## 직접 소비자 및 검증 대상

| 변경 파일 → 인터페이스 | 직접 소비자 | 실제 검증 target / 현재 결과 |
| --- | --- | --- |
| `keeper_librarian_durable_commit.ml/.mli` → validate의 frontier 반환 | Execution inventory fold 1곳, commit.publish 내부 strict 검증 2곳 | `test/test_keeper_librarian_durable_execution.exe`; source inspection + parser만, 실행 미실행 |
| `keeper_librarian_durable_owner.ml/.mli` → 검증된 unknown을 기존 Pending으로 반환 | Execution의 first capture / retained resume, 같은 target의 real owner settlement fixture | 위 같은 실제 target; parser만, 실행 미실행 |
| `keeper_librarian_durable_execution.ml/.mli` → validated frontier를 이용한 retained selection | `keeper_librarian_queue_refresh.run_durable`, 실제 fixture의 public submit_durable | 위 target의 Atoms/Mixed unknown + production queue 경계; parser만, 실행 미실행 |
| 기존 공통 submit-once 미변경 | Librarian Owner | `test/test_lane_addon_submit_once.exe`, sent unknown never submits again; 이번 작업에서 실행하지 않음 |

`consumer-inspection.txt`는 직접 module/validate 호출 전수 검색 원문입니다. `test/dune`의 기존 `test_keeper_librarian_durable_execution` stanza 및 actual Python worker source deps를 유지했습니다. 기존 actual target을 우회하는 fixture 전용 target을 만들지 않았습니다.

다음 실행 경계에서 권한이 있다면 focused 검증 대상은 기존 `dune exec ./test/test_keeper_librarian_durable_execution.exe`와 `dune exec ./test/test_lane_addon_submit_once.exe`입니다. 이 명령들은 여기서 실행하지 않았습니다. 로컬 Dune/type/build/test는 parent 지시에 따라 금지되어 있습니다.

## 원문 결과와 freeze

- `validation-raw.json`: OCaml 5.5.1 `ocamlc -stop-after parsing`으로 변경 ML/MLI 7개 parser PASS, `git diff --check` PASS. 타입·exhaustiveness·link·동작 검증을 뜻하지 않습니다.
- `librarian-terminal-unknown-repair-frozen-20261023.json`: base SHA, 7개 파일의 base blob/SHA256 및 최종 blob/SHA256, patch bytes/hash, 검사 범위를 결속했습니다.
- `librarian-terminal-unknown-repair-20261023.patch`: 22,366 bytes, SHA256 `c77acbc2f30141b2518f3a495f15c2c2ba06b8f50f83968ebd1da7dc416e3cc8`.
- commit, push, PR 생성, merged stack ref 수정, CI 요청·watch, 설치·실제 UI 실행은 없습니다. 사용자 dirty checkout과 다른 세션 source는 수정하지 않았습니다.

이번 후보는 원래 54개 Goal 중 E03/D03–D06의 특정 terminal-unknown frontier 수리입니다. checkpoint·absorption·Memory lineage·pending·실제 Keeper 기억 연속성이라는 원래 완료 기준과 나머지 Librarian 목적/전체 Addon 전환의 미완료 상태를 유지합니다. 독립 리뷰 다음에 권한 있는 focused 실행에서 actual terminal·반복 wake·restart fixture가 실제로 target 경계에 도달하는지 확인해야 합니다.
