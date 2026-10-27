# Owned concurrent scale — projection delta review

2026-10-26, independent reviewer `/root/concurrent_probe_review`.

**PASS — 이번 delta에서 P0/P1/P2 및 새 blocker 미발견.** v2에서 지적한 정상 batch follower 공개 상태 투영 결함이 main과 reader 모두에서 해소됐다. 기존 raw source/input/admission/execution/member digest 검사는 유지됐다. 이 판정은 아래 정확한 frozen delta의 소스 및 허용된 순수 Python 검증에 한정한다.

v2 보고서의 `reviewed.diff`를 parent `4ac6dce147d735d74440263ad79071da34d77878` 소스에 메모리 내 적용하여 이전 4파일을 복원했다. 모두 v2 frozen manifest 해시와 일치했다. 이 복원 소스와 현재 worktree의 4파일을 직접 비교했다. README는 같고 main/reader/fault probe 3파일에만 이번 delta가 있다. 대상 소스 수정은 하지 않았다.

- 이전 full diff SHA256: `edbc65cd679a6a5c3d57da12136635a0b42cec832ee5d0d51c046f46f1b0ddeb`
- [이번 delta](reviewed-delta.diff) SHA256: **`06c0ee130da45524d71e694253839124520755669a8c37a3b6eeca1443314699`**
- [parent 대비 현재 full diff](reviewed-full.diff) SHA256: `d40158cb9438fab13b8ce23776ec05421f6129bb032a763134a796654abce584`
- [source-manifest.json](source-manifest.json)에 비교 규약과 정확 파일 해시를 결속했다. API 권위는 계속 `c3cb3715e3a36b56ae17c23820b6b7c83914a602`이다.

## 판정 근거

| delta | 소스 판정 |
|---|---|
| `keeper_scale_session.py:201–219` | 검증한 batch member의 `execution_id`로 leader raw state를 찾아 공개 state와 비교한다(`:204`, `:216`). follower raw queued/public Running을 허용하되 아무 Queued/Running이나 수용하도록 완화하지 않았다. raw source/input/digests 및 public original payload, sequence/created_at, member binding 검사는 그대로다. |
| `keeper_scale_packet_audit.py:172–182` | 독립 reader도 같은 c3cb projection 규약을 적용한다(`:173`, `:180`). 자기 row의 input/digest 비교는 계속 유지한다. member의 execution ID가 같은 owner snapshot에 존재하는지 앞선 검사에서 확인하므로 다른 owner나 없는 leader를 새로 허용하지 않는다. |
| `keeper_scale_fault_probe.py:93–103` | positive fixture의 batch follower 공개 상태를 Running으로 고치고, 잘못된 public Queued를 거부하는 negative case를 추가했다. raw follower는 queued로 유지한다. terminal 입력 삭제 및 original/member digest 검증 case도 유지된다. |
| `keeper_scale_packet_audit.py:370–373` | derived report에 실행한 auditor 파일의 SHA256을 추가했다. 기존 original failure 보존과 original FAIL/PASS 경계는 바꾸지 않았다. quiescent reviewed source가 실행된다는 기존 자격 조건은 계속 필요하다. |

c3cb의 `keeper_chat_operation_store.ml:500–512`는 member 공개 state를 leader.state로 투영하고, `:3010–3016`은 terminal raw member 사실을 leader와 맞춘다. 이번 변경은 그 소스 규약과 일치한다. original input은 follower 자신의 입력이며 leader만 merged execution input이라는 검사를 state projection과 혼동하지 않는다.

## 독립 확인

v2의 소스 추출 순수 Python 반례를 새 출력에서 기대값만 반전하여 재실행했다. 현재 main/reader 파일 전체 해시가 manifest와 같은지 실행 전 확인하고 해당 순수 함수만 AST로 추출했다. [projection-check.py](projection-check.py), [projection-check-result.json](projection-check-result.json)에 스크립트와 실제 결과가 있다. exit 0, MASC process 0이다.

| 관측 | 결과 |
|---|---|
| main: raw queued/public Running follower | 수용 |
| main: 잘못된 public Queued follower | 거부 |
| reader: raw queued/public Running follower | 수용 |
| reader: 잘못된 public Queued follower | 거부 |
| main: raw member가 terminal로 settled되고 input이 지워진 batch | 수용 |

root가 만든 `keeper-scale-evidence-v3-faults-projection-fixed.json`도 직접 읽었다. 25 cases/passed true/MASC process 0이며 harness·fault probe 해시가 이번 source와 일치한다. [root-fault-receipt-audit.json](root-fault-receipt-audit.json)에 원본 receipt SHA와 대조 결과가 있다. 검토자는 전체 25-case probe를 재실행하지 않았다. 위 5-case main/reader projection 확인은 별도로 직접 실행했다.

이전 v2에서 해소를 확인한 owned-base 성공/실패 보존, held 두 테이블 단일 read transaction, fresh dashboard principal, canonical fixture subset 증거, 원본/backup 및 raw RPC 결속은 이번 delta에서 바뀌지 않았다. 해당 범위와 한계는 v2 리뷰를 이월하며, 과거 보고서 해시를 새 source 해시로 소급하지 않는다.

이것은 native 실행·성능 PASS, 2→30→300 성공, native artifact qualification, CI 또는 formal GitHub approval이 아니다. Dune/native/CI 조회/네트워크 변경/대상 소스 수정을 하지 않았다. 이후 native2의 실제 실행 결과는 이 소스 판정과 별도로 보존해야 한다.

## 현재 정확 파일 해시

| 파일 | SHA256 |
|---|---|
| scripts/harness/perf/README-keeper-scale-session.md | `0ab3b926cde79ef7cd325733b489fc5d2cd2d7cddc18fd324367d6ff1ec8b36e` |
| scripts/harness/perf/keeper_scale_fault_probe.py | `d8d2bb4540bd888ea89b96d9bfc275b5733cba339aa95a0b06845f0c418d2f4b` |
| scripts/harness/perf/keeper_scale_packet_audit.py | `be6b0a62cf36d7174f43d2ff282285e8eb151fe8fe25583ee41c8c35c5976f9b` |
| scripts/harness/perf/keeper_scale_session.py | `a6df19e949708fb6b44255e2a0623689c1ba9eb9e203c4a0eaf35f30ee537284` |
