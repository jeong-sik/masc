verdict: PASS head: b427c23667250e06ff4f85e235fe5716611c79f8 by: bidi_partial_failure_response

E01 derive-only 관측 계약 수리의 **독립 SOURCE 판정**이다. GitHub 정식 승인, native rebuild, 실제 재연결/provider/Paid 성공 또는 Browser67 전체 판정이 아니다.

## 정확한 범위

- Base: `eb484b0aabe699b46740bcb787a935fb67bbfa8e`
- Head: `b427c23667250e06ff4f85e235fe5716611c79f8`
- Detached checkout `/tmp/masc-candle-derive-observation-20261022`에서 실제 HEAD와 clean 상태를 읽었다.
- 전체 3파일 diff: `addons/candle-appraiser/server.py`, `README.md`, `addons/tests/test_candle_appraiser.py`, 20 additions / 23 deletions.
- 공통 Protocol ML/MLI, container worker connection 생성, Runtime의 instance/row namespace/관측 commit과 exported tool admission, 공통 Python schema/encoder와 Dockerfile을 직접 읽었다.
- 원래 actual failure capture52/53/54/56 및 isolated worker 교체 capture57, 기존 before/after 시험 로그를 읽었다. 직접 시험·모델 호출·Docker/API/운영 조작은 하지 않았다. 보고서 외 파일/refs/GitHub 변경도 하지 않았다.

## 원래 P2의 원인과 대응

P2는 실제 제품 경로에서 재현됐으며 수정 위치가 맞다.

- package `lane.toml:4,11–14`는 derive contribution이고 action tool이 없지만 exported tool은 별도 host_context 호출이다. 두 기능은 다른 계약이다.
- `lane_addon_worker_protocol.ml:141–156`은 `action_tool=None`일 때 observe 인자를 정확히 `binding,sources` 두 키로 만든다. `Some _`에서만 context를 추가한다. MLI `47–48`도 derive observe에 별도 context 인자를 받지 않는다.
- 기존 Candle worker가 관측에 `binding,context,sources`를 요구하므로 실제 첫 관측은 실패할 수밖에 없다. capture52는 action_schema/action_tool=null, observation_seq=0, phase/application failed와 같은 오류 문자열을 보여 준다.
- 새 worker `server.py:355–364`는 정확히 binding/sources만 허용하고, tools/list의 observe inputSchema는 기존 공통 `protocol.INPUT_SCHEMA`를 쓴다(`379–380`). 중복 context schema와 첫 관측의 self.context 저장을 제거했다. 공통 schema `protocol.py:210–213`의 required/closed top-level 키와 실제 host 생산자가 일치한다.
- 이것은 host가 보내지 않는 필수 키를 조용히 기본값으로 채우거나 양쪽 옛 계약을 동시에 받아들이는 호환 우회가 아니다. 잘못된/추가 context 키는 새 exact parser에서도 거절된다.

공통 INPUT_SCHEMA는 binding object와 sources array의 광고된 shape다. Candle의 observe는 source 값을 사용하지 않고 자신의 Store에서 counts/IDs를 읽는다. `exact`는 top-level 키만 확인하며 임의 내부 JSON을 schema 전체로 검증하는 엔진은 아니다. 이 수정이 그것을 full schema validator라고 주장하지 않으며, 실제 host는 binding manifest validation과 source acquisition을 거쳐 인자를 만든다. 새 권한 입력이나 I/O 경로는 생기지 않는다.

## incarnation guard 제거가 권한을 약화시키는가

관측의 기존 self.context는 worker가 첫 요청에서 받은 값을 기억한 로컬 문자열 비교였다. 현재 derive host에서는 그 값 자체가 오지 않는다. 원래 connection/instance authority의 정본은 해당 Python 값이 아니다.

유효한 host 경계는 그대로 유지된다.

1. `lane_addon_worker.ml:407–431`: host가 생성한 원래 instance_id로 Protocol을 만들고 검증한 container ID의 MCP connection을 initialize한다. package가 반환한 subject로 다른 worker connection을 고르지 않는다.
2. Protocol MLI `25–34`, ML `73–91,138–181`: Ready인 원래 client만 호출하고 revoke/취소 뒤 응답을 다른 connection에서 재소비하지 않는다. 이 수리는 Protocol/Native/container 경로를 바꾸지 않는다.
3. `runtime.ml:1217–1235`: 원래 entry e의 source_access/package/binding과 해당 connection c.observe를 사용해 output을 원래 e에 commit한다. `697–701`은 row id에 original instance/seq, lane_id에 original instance를 붙이고, `758–777`은 원래 instance의 store/seq로 영속화한다. entry JSON `434–444`의 instance/incarnation/authority도 host가 생성한다.
4. 새 `row.subject_id=TOOL_NAME`은 도메인 대상 `candle_appraise`의 이름이다. **subject 자체는 host가 instance namespace로 덮지 않는다.** host 권한은 별도 entry와 namespaced row/lane에 있다. 두 worker가 같은 subject를 내더라도 원래 row/lane/entry가 같아지는 것은 아니다. Candle은 kind=value이며 `machine_live`/input ledger를 공급하지 않으므로 machine screen의 별도 subject/incarnation 결합(`lane_addon_sources.ml:420–444`)과도 충돌하지 않는다.
5. exported `candle_appraise`는 여전히 host가 원래 owner를 확인한 뒤 `lane_call`의 admitted caller envelope로 부른다. Protocol `225–259`의 export membership/input hooks/invocation authority/output hooks와 Python `invoke`의 operator-only submit은 변경되지 않았다. `lane_host_requests/result`도 model-facing export가 아니며 기존 original-request/terminal-once 검사는 그대로다.

따라서 이번 context 제거는 입력/정산 권한을 약화시키는 것으로 판단하지 않았다. README `67–72`의 설명은 이 실제 분리와 맞다. 관측 rows는 실행 허가·Paid 영수증이 아니며 worker가 주장한 subject도 authority가 아니다.

## 기존 회귀와 dependency/packaging

실제 host 인자를 쓰도록 기존 재시작 사례를 수정한 것은 타당하다. `test_candle_appraiser.py:48–52,80–103`은 첫 실제 Python 프로세스의 context 없는 observe가 pending=0이고 다음 프로세스의 동일 store observe가 pending=1인지 확인한다. 이 assertions는 `isError`를 검사하는 기존 helper를 지나므로 예전 오류를 무시하는 시험이 아니다. 원래 listing equality, terminal answer/usage/slot 보존, 같은 terminal 재ACK, 재listing 없음도 유지한다.

기존 나머지 검사는 변경되지 않았다: changed-input/terminal overwrite 거절, distinct Relation task IDs, unknown 종단 보존, operator authority, corrupt/missing/replaced Store 거절, persistence uncertainty, 최초 parent fsync, frame capacity와 JSON nesting 오류. action incarnation 입력을 더 이상 보내지 않는 것은 해당 host가 생성하지 않는 가짜 인자를 없앤 것이며 실제 action/host ownership fixture를 약화시킨 것이 아니다.

저장된 실행 로그를 직접 읽었다.

- `candle-derive-host-contract-before-fix.log`: 13건 중 기존 재시작 사례 1 FAIL, 첫 observe에 `observation fields must be exactly ['binding', 'context', 'sources']`.
- `candle-derive-host-contract-after-fix.log`: 13건, 0.738초, OK.

이것은 읽은 기존 Python subprocess/scripted-model 시험 로그이며 본 reviewer가 재실행한 결과가 아니다. OCaml host 타입/링크·native rebuild·실제 provider/Paid 증거도 아니다. before/after 로그에는 독립 실행 manifest/SHA가 없으므로 로그를 별도 release receipt처럼 부풀리지 않는다.

새 import는 원래부터 import하던 `protocol`에서 이미 정의된 INPUT_SCHEMA만 추가한다. Dockerfile이 이미 같은 `protocol.py`를 `/protocol.py`로 넣으며 실제 host가 readonly mounted `/addon/server.py`를 실행한다. 새 Python dependency나 ML/MLI/Dune 소비자는 생기지 않는다. 전체 diff의 diff-check도 통과했다.

## 원래 failure와 mixed-candidate 증거

- capture53은 원래 Task 새 verification 승인, Goal verifier commit, 원래 unreadable Task의 infrastructure_unavailable 이력을 보여 준다. **Candle appraisal provider 성공은 아니다.**
- capture54에는 같은 Goal/request/run의 Snapshot(`17:12:39Z`)과 Payout_owed(`17:13:00Z`) 두 행만 있다. 관측 실패가 그 원래 의무를 소비하거나 Paid로 덮지 않았다.
- capture56은 same installation이 enabled=false/inactive이고 실패한 원래 instance가 runtime_presence=retained, detached, 원래 engine/container release receipt를 갖는 상태다. 이는 안전하게 다음 source를 교체하기 전에 원래 worker의 cleanup 경계를 확인한 실제 API 영수증이다. 별도 OS/Docker 조회로 재확인한 증거는 아니다.
- capture57은 **native source eb484 + isolated readonly-mounted worker source만 b427 수리**라는 혼합 조건을 명시한다. before worker SHA `93fc380…8c02`, after `c4099ecc5b50b0b267d2654a4e235cfa732df87e53d743b667da47d65f1e3e04`. 본 검토에서도 실제 isolated mounted server.py의 digest가 after와 같은 것을 확인했다.

이후 같은 installation/state를 On으로 돌린 실제 관측 성공·원래 Owed settlement/provider result/Paid-once는 새 영수증이 생긴 범위에서 별도로 판정해야 한다. unchanged native eb484를 b427 native artifact라고 부르거나, 이 worker-only 수리를 이전 eb484 전체 실행 성공으로 소급할 수 없다. pr-updater 접수/답변도 게시·review·merge 완료가 아니다.

## 결론

원래 derive observation P2는 정확한 생산/소비 계약에 맞춰 수리됐다. 전체 3파일 변경과 필요한 host authority 소비자를 직접 읽은 범위에서 새 P0–P2는 없다. 나머지 E01 실제 On/provider/원래 정산/Paid-once·후속 Off/cleanup·현재 게시 SHA의 승인 여부는 이 SOURCE PASS에 포함하지 않는다.
