# Owned concurrent scale v3 — independent source re-review

2026-10-26, reviewer `/root/concurrent_probe_review`.

판정: **CHANGES_REQUESTED — P0 0건, P1 0건, 실행 전 수정할 P2 1건**. 이전 원본 삭제 P2는 해소됐다. canonical source/input/digest 검증도 실질 추가됐으나, 정상 batch follower의 공개 상태 투영을 잘못 비교하여 main과 reader가 정상 입력을 거부하는 새 회귀가 있다. 이 한 건 외에 이번 전체 diff에서 추가 blocker를 발견하지 않았다.

대상 worktree는 `.worktrees/perf-scale-evidence-retention-20261026`이며 HEAD/비교 parent는 `4ac6dce147d735d74440263ad79071da34d77878`이다. **uncommitted 4개 파일의 전체 diff**를 읽었다. runtime/API 권위는 `c3cb3715e3a36b56ae17c23820b6b7c83914a602`이며, 앞 리뷰에서 확인한 그 producer/decoder 계약과 비교했다. 저장소 헌법은 이미 전체 읽은 SHA256 `4076f6a42f563ba36c1be6549ecb473929f81f1342e2a65a3b1b293f4591ddc8`와 동일함을 확인했다.

결속된 [reviewed.diff](reviewed.diff)의 SHA256은 **`edbc65cd679a6a5c3d57da12136635a0b42cec832ee5d0d51c046f46f1b0ddeb`**이다. 생성 규약은 `git diff --no-ext-diff --no-textconv --no-color --binary <parent> -- <four files>`이며, 정확 파일 해시·크기·줄 수·parent 해시는 [source-manifest.json](source-manifest.json)에 있다.

## P2-1 — held follower의 public Running과 raw queued는 정상인데 둘의 일치를 강제한다

수정 대상 좌표:

- `scripts/harness/perf/keeper_scale_session.py:206–216`, 특히 **212행**.
- `scripts/harness/perf/keeper_scale_packet_audit.py:167–181`, 특히 **178행**.
- `scripts/harness/perf/keeper_scale_fault_probe.py:88–98`, 특히 **91행**의 synthetic state 생성.

c3cb의 `lib/keeper_chat_operations/keeper_chat_operation_store.ml:500–512`는 `project_batch_with_db`에서 각 member의 공개 `state`를 **leader.state**로 투영한다. `:1857–1878`에서 batch membership과 합친 leader input을 freeze하고, claim은 leader를 running으로 바꾼다. follower의 raw `operations.state`는 terminal settlement 전에는 queued로 남을 수 있다. terminal에서는 `:3010–3016`이 follower의 raw terminal 사실을 leader와 맞춘다.

따라서 provider가 hold된 정상 batch의 다음 상태는 유효하다.

| operation | raw operations.state | 공개 exact status.state | input/execution digest |
|---|---|---|---|
| batch leader | running | Running | 합친 execution input/digest |
| batch follower | queued | **Running** | 자기 original input/digest |

현재 main은 `status["state"].lower() == row["state"]`를 요구하므로 follower에서 예외를 낸다. reader도 같은 비교를 한다. 기본 keeper당 2 messages에서도 첫 claim 전 두 입력이 도착하면 batch가 가능하므로 batching 시나리오만의 이론적 문제가 아니다. 이 리뷰는 그러한 실제 native timing이 발생했는지 측정하지 않았다.

추가 fault probe의 synthetic 공개 상태는 raw stored state를 그대로 capitalize하여 follower를 Queued로 만든다. 이는 c3cb의 실제 projection을 재현하지 못해 24개 probe가 모두 성공해도 이 회귀를 탐지하지 않는다.

**필요한 보정:** main과 reader 모두 member의 공개 상태를 그 member의 leader raw state에 따라 검증한다. raw follower queued 및 original input/digest/member binding 검증은 보존한다. terminal raw 사실과 leader 일치도 유지한다. 단순히 state 비교를 삭제하거나 Queued/Running 아무 값이나 수용하면 안 된다. fault probe는 raw queued/public Running의 실제 projection을 positive case로 쓰고, 잘못된 public Queued 같은 projection drift를 negative case로 검증해야 한다.

[projection-fault-probe.py](projection-fault-probe.py)는 검토 소스에서 해당 순수 함수만 AST로 정확 추출하여 이 차이를 재현한다. MASC module 전체나 native를 실행하지 않는다. 결과는 [projection-fault-result.json](projection-fault-result.json)에 있다.

| 순수 Python 반례 | frozen 소스 결과 |
|---|---|
| main: raw와 같은 synthetic Queued follower | 수용 |
| main: c3cb 계약에 맞는 projected Running follower | `ProbeError`로 거부 |
| reader: raw와 같은 synthetic Queued follower | 수용 |
| reader: c3cb 계약에 맞는 projected Running follower | `AssertionError`로 거부 |
| main: 모든 raw member가 settled된 terminal batch | 수용 |

이것은 Python validator의 행동 확인이며 native API/성능 실행 결과가 아니다.

## 이전 P2 및 변경 사항 판정

| 검토 항목 | 판정·근거 |
|---|---|
| 성공/실패 원본 삭제 | **해소.** main `:615–620`에서 `OUTPUT/owned-base`를 만들고 cleanup `:909–922` 및 fallback `:998–1008`에서 보존 상태/위치를 기록한다. 기존 두 rmtree 호출이 제거됐다. backup/validation 오류가 나도 원본 base를 삭제하는 경로가 이 diff에는 없다. |
| integrity/copy 예외 보존 | **추가 확인.** 허용된 probe는 injected sqlite3.DatabaseError에서 원본 DB/WAL/log의 synthetic bytes와 failure/cleanup receipt 보존을 확인한다(`fault_probe.py:207–232`). 실제 native SQLite WAL lifecycle/모든 OS 오류/cleanup 성공을 측정한 것은 아니다. |
| held 단일 snapshot | **적합.** `read_admission_snapshot :145–158`은 한 connection에서 BEGIN 후 operations와 operation_batch_members를 읽고 rollback/close한다. 이는 Keeper별 두 테이블의 하나의 read transaction이며 모든 Keeper/순차 public HTTP가 하나의 전역 transaction이라는 뜻은 아니다. |
| fresh operator principal | **적합.** main `:730–736`에서 기존 dev-token 응답의 actor dashboard/role admin을 확인하여 principal.json으로 보존한다. c3cb의 dashboard token producer 및 canonical MCP caller injection과 맞는다. 새 HTTP 호출을 더하지 않았다. |
| 원래 source/input/admission digest | **실질 보완.** original_payload `:131–142`의 15-field source와 exact message string input은 c3cb Agent ingress 계약에 맞는다. `:201–211`에서 canonical source/input/admission/execution 및 public source/digests/sequence/created_at를 검산한다. reader는 `:75–108`에서 원래 메시지를 workload와 성공 raw RPC에서 독립 재구성하고 admitted original과 대조한다. |
| batch leader/member | **digest/input 규칙은 적합; state projection은 위 P2.** `:173–193`은 각 original admitted digest/input, member identity/order/contiguity 및 합친 leader execution input을 구분한다. terminal input/admitted_input_json NULL은 c3cb의 삭제 규약에 맞다. follower의 original digest를 leader merged digest로 덮지 않는다. |
| 종료 원본/backup | **적합.** main `:899–908`은 닫힌 원본과 backup의 operations/batch snapshot 일치를 확인한다. 기존 operations 전체 typed backup도 유지한다. reader `:125–143`은 보존 원본과 backup을 mode=ro로 다시 열고 integrity 및 두 테이블의 full typed rows digest를 대조한다. |
| public raw RPC 대응 | **적합한 추가 계층.** reader `:109–120`은 queue-held/settlement 성공 raw RPC의 정확 operation status와 보존 public status를 결속한다. 기존 identity/terminal/outcome/reply 검증을 유지한다. 위 state 오해는 raw RPC를 읽어도 해소되지 않으므로 reader도 고쳐야 한다. |
| schema/기존 증거 | **적합.** writer/reader/probe/README를 v3로 맞추고 이전 v2 packet은 그 frozen reader/results를 유지한다고 명시한다. 기존 packet을 v3 성공으로 소급 승격하지 않는다. |

source/input/digest 검산은 현재의 고정 text fixture 범위에서 이전 누락을 보완한다. 기존 P2-2를 그대로 남아 있다고 중복 집계하지 않았다. 다만 정상 public projection을 수용하도록 고친 정확 소스를 다시 확인해야 이 preparation을 통과로 판정할 수 있다.

## 허용된 fault probe 및 canonical 증거 직독

검토 중 frozen worktree의 Python fault probe를 새 report output에 실행했다. `PYTHONDONTWRITEBYTECODE=1`, `-B`, report 안 TMPDIR를 사용했으며 MASC process는 0이다.

- [fault-probe-execution.json](fault-probe-execution.json): exit 0, **24 cases**, passed true, MASC process 0.
- [fault-probe.json](fault-probe.json): 각 원래 case의 실제 결과. 24개 성공은 위 projection 회귀를 커버하지 않는다.
- [projection-fault-result.json](projection-fault-result.json): 별도 5개 순수 Python 관측에서 잘못된 상태 모델과 실제 c3cb projection의 차이를 확인했다.

`artifacts/runs/extreme-perf-20261026/keeper-scale-canonical-subset-v1`의 probe.ml/inputs.json/stdout/stderr/receipt를 모두 직접 읽었다. c3cb의 canonical_json 함수 구간이 probe에 정확 포함되고 전체 production file hash가 receipt와 맞는지 확인했다. Python sorted compact encoding을 독립 계산하여 저장된 OCaml stdout 8줄 및 8개 SHA256과 대조했으며 모두 같았다. [canonical-evidence-audit.json](canonical-evidence-audit.json)에 원본 5개 파일 해시와 대조 결과가 있다.

이 증거의 한계는 그대로다. **8개 값**은 original source/input/admission 및 merged input의 알려진 ASCII/null/list/object 형태이고 source 값 두 개는 같다. 모든 JSON 값에 대한 Python/Yojson 동치 증명이 아니다. 숫자 sequence는 payload 안에서 message 문자열에 포함되며, 이 canonical payload 함수는 직접 int/bool/float 같은 확장을 거부한다. 검토자는 OCaml interpreter를 다시 실행하지 않았다. 기존 receipt의 OCaml 5.5.1/installed Yojson/returncode0을 파일 증거로 확인했으며 native/local Dune build와 혼합하지 않았다.

## 소유권·측정 경계와 후속 입장 조건

child process group TERM/KILL/reap, provider release-on-cleanup, socket timeout 및 handler drain, sampler stop, explicit pre-dispatch429 retry와 ambiguous mutation no replay는 이전 리뷰 범위를 이월한다. 이번 diff가 해당 기본 동작을 약화한 변경은 발견하지 않았다. cleanup 단계 자체의 OS 예외가 최초 예외를 가릴 수 있다는 기존 일반 한계와 socket idle timeout이 absolute body deadline은 아니라는 경계도 남는다. 이 둘을 이 diff의 새 blocker나 기존 business30 P1로 재분류하지 않았다.

원본 base 영구보존은 copied executable·ephemeral credential·runtime 상태를 포함하므로 README의 local/private packet 경계가 계속 필요하다. 성공/실패 후 디스크 보존과 owned processes/listeners 종료는 서로 다른 사실이며, 파일이 남았다는 이유로 cleanup이 성공했다고 하지 않는다. SQLite가 정상 종료 중 WAL을 checkpoint하거나 제거할 수 있으므로 모든 성공 packet에 WAL 파일이 반드시 존재함을 보장하지도 않는다.

위 P2를 main/reader/fault fixture에서 고친 뒤 정확 delta 해시로 재검토하면 된다. source review와 순수 Python probe 성공은 2→30→300 native 성공, 300 resource ceiling, throughput/latency, guest tool/Add-on/peer 업무, installed artifact qualification, CI 또는 formal GitHub approval을 의미하지 않는다. root가 별도로 전달한 baseline/candidate artifact 자격과 CI는 이 리뷰의 독립 확인 대상이 아니다. 본 리뷰에서는 MASC native 실행, local Dune build, CI/API 조회, 네트워크 변경, 대상 소스 수정을 하지 않았다.

## Frozen file hashes

| 파일 | SHA256 |
|---|---|
| scripts/harness/perf/README-keeper-scale-session.md | `0ab3b926cde79ef7cd325733b489fc5d2cd2d7cddc18fd324367d6ff1ec8b36e` |
| scripts/harness/perf/keeper_scale_fault_probe.py | `bb788cb70fe91301f922b5b8aedc257f039e92b5a87fefebe3b6beb0e34b5822` |
| scripts/harness/perf/keeper_scale_packet_audit.py | `e355de804fbf64d9f52237f9ffdb3ba0e1c04fe424a1874f674fb6fad2b739f0` |
| scripts/harness/perf/keeper_scale_session.py | `c9e8f173d4e69b4c63d3472c15d8b7377501875d4b6f455028e899288662f9da` |
