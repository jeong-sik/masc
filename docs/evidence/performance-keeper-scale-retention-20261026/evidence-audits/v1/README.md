# Completed native Keeper cohort evidence — independent audit

2026-10-26, reviewer `/root/concurrent_probe_review`.

**PASS: 완료된 2·30·300 cohort packet의 증거 정합성.** 원래 RPC에서 exact owner/operation ID, source/input/digests, 실제 held provider overlap, public terminal/reply, 보존 원본·backup DB와 기록된 cleanup까지 연결해 검산했다. 이 범위에서 P0/P1/P2 정합성 결함을 발견하지 않았다. 아래 성능 tail과 full-health 경계는 성공 개수와 함께 보존해야 한다.

처음 요청은 완료된 2·30에 한정됐고, root가 300의 완료를 알린 후 감사 범위를 확장했다. 검토자는 **새 workload/native 실행, Dune build, CI/API/live 서버 요청, 네트워크 변경을 하지 않았다.** 기존 root 실행에서 생성된 세 packet을 읽고 offline Python/SQLite 검산만 수행했다. 원래 harness exit0는 root의 실행 관측이며, 여기서 직접 검산한 것은 완료 packet의 원문·저장 데이터·기록된 native returncode/cleanup 및 재생성한 offline audit이다. 실행 중 공유 서버에 요청하지 않았다.

## 결속된 source와 native 자격

| 구분 | 정확 값 |
|---|---|
| app source | `c3cb3715e3a36b56ae17c23820b6b7c83914a602` |
| artifact workflow/builder source | `6a2d8dd6171e1d732ca15f918fb084e462e4d371` |
| 실제 candidate server/세 copied server SHA256 | `06ee93c99b31a6fca6786c2c6a676c8023b62b0fc854da6616518c21202ad3a8` |
| 실제 candidate TUI artifact SHA256 | `4541bb731d235e000388d8fdfac503d50777da70126869da128cca1be181c9ea` |
| 세 frozen runner SHA256 | `a6df19e949708fb6b44255e2a0623689c1ba9eb9e203c4a0eaf35f30ee537284` |
| 사용한 reviewed v3 reader SHA256 | `be6b0a62cf36d7174f43d2ff282285e8eb151fe8fe25583ee41c8c35c5976f9b` |
| release runtime fixture SHA256 | `ccbe65e399f47a3abddbf4299e15dd0fd55001dd785b2e0d75948ad86acf7cfd` |

`qualified-native-pair.json`, candidate `native-c3cb371/receipt.json`, `qualification/identity-commands.json`, `test-results.tsv`를 직접 읽었다. candidate server/TUI의 실제 파일을 해시하여 receipt/pair와 대조했다. 기록된 build-commit 두 결과는 c3cb/exit0이며 native 4-suite TSV·receipt는 모두 suite/log exit0이다. 이 명령들을 검토자가 다시 실행한 것은 아니다. [qualification-audit.json](qualification-audit.json)에 원본 receipt/qualification 해시와 검산 결과가 있다.

pair에 기록된 baseline source는 `1ce158d50d3eb48648e6deea7f668172f914fea3`이지만 이번 세 cohort는 모두 candidate c3cb이다. pair의 `comparison_executed:false`를 읽었으며 이 감사는 baseline 성능 비교를 수행하지 않았다. native receipt의 `installed_runtime_verified:false`, `visible_ui_verified:false`도 유지한다. private artifact의 identity/byte 자격과 공유 설치·보이는 UI 검증을 혼합하지 않는다.

## 원문부터 완료까지 검산한 것

[audit_packets.py](audit_packets.py)는 세 완료 packet 이름만 지정한다. 정확한 reviewed reader를 로드해 offline `audit(packet)`을 호출하되 **모든 derived write를 이 새 보고서 디렉터리로 우회**했다. 재생성된 각 `derived/post-run-audit.json`은 원래 문서와 값 전체가 같았다. 추가로 qualification, 건강 샘플 원문, raw provider timeline, RPC retry와 latency 산술을 별도로 검산했다. 검토 script exit0이며 새 MASC process는 0이다.

- 원래 성공 enqueue RPC의 name/message, 반환 operation ID를 workload의 exact original message 문자열과 대조했다. 각 owner의 original ID 집합과 공개·durable ID 집합이 같고 중복/누락이 없다.
- dashboard principal, 15개 original source 필드, canonical input bytes, admission/execution 및 존재하는 member digest 규약을 확인했다. held operations와 batch membership의 저장 snapshot, public raw status, terminal snapshot을 연결했다. canonical 검증은 이전 리뷰와 같은 고정 ASCII/null/list/object fixture 범위다.
- 세 runtime은 서로 다른 owned-base와 runtime instance를 쓰며 health 기록은 owner fibers `0→N→N`이다. 모든 기록의 app commit/server hash/effective base가 identity와 맞는다. 실제 create RPC는 isolated on-demand/microVM 선언/network none/도구 호출 금지 인자와 일치한다.
- raw model request/outcome가 대응하고 marker/owner/original sequence가 각 owner `[1,2]`를 정확히 덮는다. release event 시점을 가로지르는 요청을 owner별로 재계산하여 N개의 실제 동시 요청을 확인했다. 전체 요청 interval에서도 peak N이 나온다.
- public terminal과 exact owner DB의 state/outcome/timestamps/reply를 연결했다. original·backup SQLite는 mode=ro, integrity_check 및 모든 operations/batch 열의 typed 값으로 재확인했다. 최종 모든 operation은 succeeded, input_json NULL이며 typed reply가 해당 원래 입력을 덮는다.
- 각 원본/backup DB와 known raw/verdict 파일의 감사 전후 해시가 같다. 새 SQLite sidecar가 남지 않았으며 감사 당시 세 cohort 모두 DB sidecar는 0개였다. 정상 종료가 WAL을 checkpoint/remove할 수 있으므로 WAL 파일 부재를 증거 손실로 판단하지 않는다.
- cleanup 원문은 모두 native `server_returncode:0`, reaped true, forced_kill false, sampler/provider stopped, active provider/handler 0 및 owned-base retained이다. 이는 **실행 시 기록된 cleanup** 검산이며 현재 live process에 새로 질의한 결과가 아니다.

입력 해시는 각 cohort 하위 `input-hashes.json`, 상세 재계산은 `audit-summary.json`, 종합은 [audit-result.json](audit-result.json)에 있다. credential 디렉터리나 실행파일 내용은 보고서에 복사하지 않았다. fake fixture credential의 일치 여부만 확인했고 실제 ephemeral token은 복사하지 않았다.

## 관측 개수와 latency

| 완료 packet cohort | 2 | 30 | 300 |
|---|---:|---:|---:|
| exact original/public/durable 성공 operations | 4 | 60 | 600 |
| scripted provider calls | 4 | 60 | 600 |
| raw interval peak / release crossing owners | 2 / 2 | 30 / 30 | 300 / 300 |
| held public Running / Queued | 2 / 2 | 30 / 30 | 300 / 300 |
| held / terminal batch member rows | 0 / 0 | 0 / 0 | 0 / 0 |
| valid / total live-health samples | 6 / 6 | 71 / 71 | 1041 / 1041 |
| live-health wire p50 ms | 0.583167 | 1.036875 | 1.219708 |
| live-health wire p95 ms | 0.750875 | 6.313583 | 6.663833 |
| live-health wire p99 ms | 0.750875 | 8.265709 | 22.441875 |
| **live-health wire max ms** | **0.750875** | **8.265709** | **3599.31575** |
| HTTP429 attempts | 0 | 5 | 70 |
| measured retry wait seconds | 0 | 5.033589668 | 70.389767666 |
| denied inventory / unclassified attempts | 2 / 0 | 2 / 0 | 602 / 0 |
| original created→completed p50 ms | 307.345867 | 5065.079927 | 66578.334093 |
| original created→completed max ms | 387.399912 | 6288.287163 | 87191.738844 |

분위수는 raw 값의 nearest-rank `ceil(q*N)`로 재계산했다. 위 live-health 표는 cohort 전체 sample 집계이므로 원래 summary의 **phase별** p95와 다를 수 있다. phase별 집계도 원문과 정확히 대조했다. 2 cohort는 짧은 held observation 구간에 live-health sample이 없지만 provider 동시 overlap과 exact held states는 별도 raw 증거로 확인된다.

세 native 실행 모두 batch member 0건이다. 정상 batch projection 수정은 source/Python 검증으로 확인됐으나 **이 세 native cohort가 그 분기를 실행했다는 증거는 아니다.** 다른 batch 시나리오까지 성공으로 확대하면 안 된다.

## 300에서 숨기면 안 되는 tail과 readiness 경계

300의 `running_model_released` live-health는 485 samples, p50 0.9575ms, p95 7.548458ms, **max 3599.31575ms**다. `health-after.json`의 scheduler는 interval100ms/최근60초 window에서 600 samples, p99 114.004084ms, **max 1158.108ms, stall 1회**, over50ms 8회/over200ms 5회다. 이는 그 저장된 scheduler window의 집계이며 전체 runtime에 대한 연속 원시 trace나 전 구간 최대 보장은 아니다.

더 긴 control-plane tail도 있다. raw settlement exact-status RPC는 **13209.662667ms**까지 걸렸다. 일부 느린 status 응답은 해당 operation의 durable 완료 뒤까지 이어진 것으로 인접 wall/perf anchor에서 보인다. 따라서 느린 status wire 시간을 turn 계산 시간으로 동일시하면 안 된다. cross-clock alignment는 정확한 clock synchronization 증거가 아니다.

300의 70개 HTTP429는 create 8, enqueue 14, held exact-status 24, settlement status 24이다. 모두 기록된 explicit429 뒤 같은 RPC payload를 retry했고 마지막 attempt는200이며 ambiguous mutation replay는 없다. Retry-After가 없어 모두 기록된 1초 fallback을 사용했다. 실제 대기는 각각 8.053156125/14.092755209/24.132651083/24.111205249초다. create 대기는 workload phase 시작 전이다. phase 시간이나 operation lifetime에서 대기를 단순히 빼서 CPU 처리시간을 만들 수 없다.

300의 602개 inventory는 container list1, nerdctl ps1, expected work/build volume inspect600이다. 다섯 guard 파일의 retained source가 각각 동일한 refuse126 프로그램임을 확인했다. volume inspect600의 첫/마지막 attempt timestamp span은 **18039.991ms**, phase별583회 held/17회 released다. 이 span은 concurrent scheduling을 포함하며 각 subprocess의 독립 비용 합이나 tail의 단일 원인 증명이 아니다. 실제 daemon/guest를 실행한 증거는 얻지 못한다.

**모든 live-health sample valid는 full readiness를 의미하지 않는다.** 세 cohort의 held/after full-health는 모두 `overall_status:degraded`, `operator_action_required:true`, 사유 `keeper_memory_execution:addon_unattached`이다. [full-health-boundary.json](full-health-boundary.json)에 직접 읽은 상태를 보존했다. 이는 text-only/Add-on 미부착 fixture 범위와 일치하지만 “300 전체 healthy”, “Addon 준비 완료”로 인용할 수 없다.

## 해석 제한

이 증거가 지지하는 것은 fixed native c3cb와 scripted loopback provider/delay10ms에서 실제 N Keeper owners와 queued inputs를 만들고, 의도적으로 N provider calls를 hold한 뒤 4/60/600 original operations의 완료와 기록된 cleanup을 보존했다는 범위다. provider concurrency cap도 각 N으로 설정됐다. workload phase duration은 submitting/held/released 각각 2에서171.181/22.021/278.333ms, 30에서1981.537/2317.499/3268.195ms, 300에서28994.952/30496.616/57032.920ms다. startup/create 및 종료·backup 등 전체 실행 시간과 동일하지 않다.

health sampler는 응답을 받은 뒤 sample interval을 기다리는 단일 closed-loop 관측자다. 긴 응답 중 균일한 주기로 새 요청을 생성하지 않으므로 1041 valid samples와 p99만으로 stall 구간을 지우거나 독립 사용자 fleet의 tail을 추정할 수 없다. wire 시간에는 client/OS/transfer 비용이, operation lifetime에는 hold/admission pacing/queue/runtime/I/O가 포함된다.

각 population은 shared host에서 한 번 관측됐다. 독립 HTTP producers, 외부 모델 throughput, 실사용 guest tool/peer/Add-on 업무, UI, production fleet, causal scaling/speedup 또는 전체 0.1ms 목표를 증명하지 않는다. 특히 이번 workload는 Add-on을 실행하지 않아 retained verification 변경의 실제 Add-on 성능 개선 비교로 사용할 수 없다. 후속 baseline/원인 분리 실험은 이 감사 범위에 포함하지 않았다. 이는 formal GitHub approval이나 새 native 성능 측정이 아니다.
