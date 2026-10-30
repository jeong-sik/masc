# Owned concurrent Keeper scale — independent source preparation review

작성일: 2026-10-26. Reviewer: `/root/concurrent_probe_review`.

판정: **SOURCE_PREPARATION_CHANGES_REQUESTED — P0 0건, P1 0건, P2 2건**. 현재 harness를 실행한 판정이 아니다. 아래 P2는 다음 실험의 실패 원본 보존과 원래 입력의 의미 검증에 관한 실행 전 수정 사항이다. 고친 harness에는 새 소스 해시와 별도 리뷰가 필요하다.

현재 `keeper_scale_session.py`/README/release runtime fixture/packet reader/fault probe 전체를 읽었다. 다섯 파일 모두 정확 `c3cb3715e3a36b56ae17c23820b6b7c83914a602`의 바이트와 같다. 비교 당시 checkout HEAD는 `6a2d8dd6171e1d732ca15f918fb084e462e4d371`이므로 checkout HEAD를 app source로 쓰지 않는다. API 분석은 모두 `git show c3cb3715e3a36b56ae17c23820b6b7c83914a602:<path>`에서 추출한 해당 구간을 권위로 삼았다. 파일별 해시·크기·줄 수·현재 바이트 일치는 [source-manifest.json](source-manifest.json)에 있다. 저장소 헌법 전체 및 contributor/storage 지침을 읽었다.

원본 소스 수정, harness/helper import 또는 실행, native 실행, local build, 새 측정, CI/API 조회, 네트워크 쓰기를 하지 않았다. root가 전달한 이전 CI 성공이나 native artifact 자격은 이 리뷰에서 독립 검증하지 않았다. 이는 formal GitHub approval, native PASS, 2/30/300 실행 PASS가 아니다. 이전 business30 prototype의 경로·HTTP/ThreadPool P1을 이 established harness에 이월하지 않았다.

## Findings

### P2-1. semantic 검증 전 및 backup 실패 경로에서 유일한 원본 base가 삭제된다

좌표: `scripts/harness/perf/keeper_scale_session.py:773–793`, `:842–879`; README `:18–21`.

정상 경로도 SQL backup/copy equality 뒤 `shutil.rmtree(base)`를 786행에서 실행하고, 실제 `validate_durable_operations(...)`는 793행에서 수행한다. 따라서 owner/terminal/outcome/population 검증이 실패할 때 원본 `.masc` 전체가 이미 없다. backup이 온전히 성공했다면 SQL 일부는 packet에 남지만 runtime 내부의 다른 원본 자료는 잃는다.

더 중요한 경로는 `read_operation_store`의 integrity 오류, `connection.backup`/target write 오류, closed backup의 typed equality 오류이다. 776행에서 예외가 발생하면 이후 backup/receipt가 완성되지 않은 채 main fallback으로 나간다. fallback 867–869행은 원본 base를 무조건 삭제한다. `failure.json`의 예외 문자열과 부분 backup만으로 원본 DB, WAL, SHM 및 런타임 증거를 복구할 수 없다. 이는 README의 “실패 보존”을 실제 원본 보존까지 확장할 수 없게 한다.

실행 전 조치: 소유 server/provider/sampler는 계속 종료·회수하되, 성공·실패 모두 원본 base의 보존 위치와 상태를 receipt에 명시한다. 또는 모든 필요한 원본을 검증된 packet으로 보존한 후 명시적인 성공 경로에서만 제거한다. 특히 backup/semantic validation 예외로 fallback에 들어간 경우 원본 DB/WAL/SHM을 삭제해서는 안 된다. 기존 `base_removed:true`를 요구하는 main/reader의 cleanup 계약도 보존 계약에 맞춰 함께 갱신해야 한다. 실패를 정상 cleanup/PASS로 다시 쓰면 안 된다.

### P2-2. 전 열의 복사 동일성은 canonical source와 원래 admission input/digest의 대조가 아니다

좌표: main `:37`, `:84–93`, `:119–168`, `:650–657`, `:697–703`; reader `scripts/harness/perf/keeper_scale_packet_audit.py:89–124`; fault probe `:29–101`.

현재 v2가 실제 확인하는 것은 다음과 같다.

- `(keeper, operation_id)`의 유일한 원래 입력 배정, 공개 terminal identity 집합, durable owner별 operation ID 집합.
- 상태·시작 존재·완료시각·outcome_ref·failure_kind의 일부 terminal 사실과 typed reply의 marker/keeper/original sequence.
- 종료한 원본 `operations`의 모든 열과 닫힌 backup의 열·값·Python SQLite 값 타입이 동일함. reader도 full typed digest를 다시 계산한다.

그러나 `copy_operation_store`는 durable JSON에 6개 열만 투영한다. 두 validator는 `source_json`, `admission_digest`, `execution_digest`, durable `sequence`/`created_at`를 원래 요청과 의미적으로 비교하지 않는다. reader가 다시 계산하는 full typed digest는 producer가 관측한 같은 DB 값과 일치함을 확인한다. 원본 행부터 다른 source/digest였다면 그 값을 정확하게 복사했다는 것과 원래 요청을 보존했다는 것은 별개이다. `operation_batch_members`의 membership/order/admitted digest도 이 비교에 들어가지 않는다. SQL backup 파일 자체에는 그 테이블이 남지만 의미 join은 하지 않는다.

이는 native corruption이 실제 발생했다는 보고가 아니다. 현재 Python 검사에서 해당 대조가 빠졌다는 소스 판정이다. README `:36–41`의 all-column typed backup 설명은 맞다. 이를 canonical input/source fidelity나 모든 원래 입력 내용 검증으로 인용하면 현재 코드보다 강한 주장이다. 다음 절의 정확한 c3cb 계약을 기준으로 검증을 추가하거나, 검증 범위를 identity/typed-reply/terminal/backup conservation으로 명시적으로 제한해야 한다. 이번 실험이 원래 입력 fidelity까지 주장하려면 실행 전에 검증을 추가해야 한다.

## c3cb producer, public JSON, durable decoder의 정확한 연결

이 절의 모든 좌표는 c3cb revision 기준이다.

| 경계 | 실제 동작과 필요한 대조 |
|---|---|
| `lib/keeper/keeper_tool_surface_ops.ml:802–815`, `:690–718` | `masc_keeper_msg`의 name/message를 direct-message contract에 넣는다. 이 harness 요청은 user_blocks `[]`, attachments `[]`, turn_instructions 없음, surface_context 없음이다. message는 650–651행에서 만든 JSON **문자열 자체**다. 내부 JSON을 다시 직렬화해 문자열이 달라도 같다고 처리하면 정확한 input digest 검증이 아니다. |
| `keeper_tool_surface_ops.ml:603–665` | 새 operation ID 및 `thread_id="keeper:" ^ keeper_name`; dashboard continuation; Agent surface; channel `"agent"`; 빈 channel user/name/workspace; conversation/external/workspace 없음; extra_mentions `[]`; registry의 실제 sender Keeper만 sender_keeper; Needs_append source를 만든다. fresh isolated fixture의 operator는 Keeper가 아니므로 sender_keeper는 null이다. |
| `lib/server/server_routes_http_dashboard_dev_token.ml:10–19`, `:42–43`; `server_routes_http_routes_dashboard.ml:1943–1950`; `server_mcp_transport_http.ml:265–269`; `server_mcp_actor_injection.ml:93–99` | isolated dev-token의 actor는 `dashboard`, role은 Admin이다. tool call의 HTTP canonical actor가 `_agent_name`으로 결속된다. 원본 dev-token 응답의 actor/role과 fresh base를 확인하여 submitted_by를 정해야 하며, 반환 source가 말하는 값을 그대로 믿어 독립 기대값으로 삼으면 안 된다. |
| `keeper_tool_surface_ops.ml:675–687` | admission JSON은 `operation_id`, `state`, `queued_count`, `existing`뿐이다. harness가 저장하는 `admission`에는 source/input/digests가 없다. admission JSON만으로 canonical fidelity를 주장할 수 없다. |
| `lib/keeper/keeper_chat_operation_payload.ml:26–55`, `:200–254`, `:257–300`, `:349–429` | source schema는 `masc.keeper_chat_operation.source.v2`, input schema는 `masc.keeper_chat_operation.input.v1`. 엄격한 필드 집합·중복 거부·route 검증을 한다. input에는 schema/message/user_blocks/turn_instructions/surface_context/attachments 6개가 모두 들어간다. |
| `lib/keeper_runtime/keeper_continuation_channel.ml:316–318`; `lib/keeper/surface_ref.ml:71` | continuation JSON은 `{"kind":"dashboard","thread_id":"keeper:<name>"}`, surface JSON은 `{"kind":"agent"}`이다. |
| `lib/keeper_chat_operations/keeper_chat_operation.ml:177–230` | 객체 키는 **재귀적으로** `String.compare` 정렬, 중복 키 거부; 배열 순서 보존; nonfinite float 거부. `Yojson.Safe.to_string`으로 직렬화한 바이트의 SHA256 hex가 digest다. execution_digest는 canonical(input), admission_digest는 canonical(`{"source":source,"input":input}`)의 SHA256이다. Python `json.dumps`가 모든 JSON 값에서 Yojson과 같은 바이트라는 전제는 이 리뷰에서 검증하지 않았다. |
| `keeper_chat_operation_store.ml:1496–1511`, `:1566–1604` | admission/execution digest 계산 및 source/input canonical 저장을 실제 producer가 수행한다. supplied operation_id가 같으면 admission digest에 따라 existing 또는 conflict를 결정한다. |
| `keeper_chat_operation_store.ml:375–402` | decoder는 digest 형식, source JSON의 canonical 저장 형식, input JSON 및 **input이 있을 때** execution_digest 일치를 확인한다. 이 decoder 구간은 원래 input을 되찾아 admission_digest를 재계산하지 않는다. `Operation.admission_digest`의 이 store 내 호출은 submit의 1573행이다. 원래 입력과 다른 source도 decoder가 반드시 탐지한다고 확대하지 않는다. |
| `keeper_tool_surface_ops.ml:951–1012`; `keeper_chat_operation.ml:94–127` | 정확한 `masc_keeper_delegate_status`는 caller ownership을 확인하고 operation JSON(source/input/digests/sequence/created_at 및 batch fields 포함)을 반환한다. 성공이면 actual execution ID의 durable delivery에서 completed_reply를 붙인다. harness는 이 MCP 경로를 사용한다. dashboard REST exact GET의 별도 redaction 함수를 이 MCP 경로에 섞어 설명하면 안 된다. |
| `keeper_chat_operation_store.ml:3010–3016`, `:3062` | terminal에는 input_json이 NULL이며 batch admitted_input_json도 terminal에서 지워진다. 따라서 terminal DB에서 원래 input 문자열을 직접 reread할 수 있다는 주장은 틀리다. request 원문 및 release 전 Queued/Running exact status와 결속하거나 원래 input의 독립 기대값을 보존해야 한다. |

fresh text-only fixture의 기대값은 다음과 같이 구성할 수 있다. 이는 실행 결과나 검증을 완료한 새 validator가 아니라 c3cb producer에서 직접 읽은 비교 명세이다.

```text
expected_input = {
  schema: "masc.keeper_chat_operation.input.v1",
  message: exact original masc_keeper_msg.arguments.message string,
  user_blocks: [], turn_instructions: null, surface_context: null, attachments: []
}
expected_source = {
  schema: "masc.keeper_chat_operation.source.v2",
  submitted_by: authenticated fresh dev-token actor "dashboard",
  thread_id: "keeper:" + original keeper,
  continuation_channel: {kind: "dashboard", thread_id: "keeper:" + original keeper},
  surface: {kind: "agent"}, channel: "agent",
  channel_user_id: "", channel_user_name: "", channel_workspace_id: "",
  conversation_id: null, external_message_id: null, workspace_id: null,
  extra_mentions: [], sender_keeper: null, user_row_origin: "needs_append"
}
```

원본 message 문자열 안의 `schema/marker/keeper/sequence`를 strict object로 확인하고, 그 **문자열을 그대로** expected_input에 넣어야 한다. RPC payload/request ID/owner-scoped operation ID/원래 순번의 일대일 대응도 유지한다. queue-held exact status의 source/input/digests 및 terminal source/digests를 expected 값과 대조하고, DB의 source_json/원래 admission_digest 및 public sequence·created_at를 해당 operation identity로 join한다. terminal input null은 정상이다. expected_source는 위에 열거한 정확한 15개 필드다.

**batch 분기를 보존해야 한다.** `keeper_chat_operation_batch.ml:62–71`은 순서대로 message를 `"\n\n"`로 합치고 User_text block을 붙인다. `keeper_chat_operation_store.ml:1857–1878`은 각 original operation의 digest를 `operation_batch_members.admitted_digest`에 보존한 후 leader의 input/execution_digest를 합친 입력으로 바꾼다. original admission_digest는 유지된다. 공개 batch_input_digest는 이 각 original input digest이며 batch_execution_id가 실제 leader다(`keeper_chat_operation.ml:123–127`, store `:487–512`). 따라서 다음이 필요하다.

- 모든 original operation의 admission_digest는 expected_source+**original input** 기준이어야 한다.
- nonbatch의 execution_digest는 original input 기준이다. batch에서는 각 membership의 admitted_digest/public batch_input_digest가 original input 기준이고, leader execution_digest는 **합친 execution input** 기준이다. follower의 원래 digest와 leader의 합친 digest를 혼동하지 않는다.
- backup `operation_batch_members`의 owner별 member/leader/position, retained admitted_digest를 public batch fields·원래 입력·실제 reply coverage와 join한다. source와 context가 다른 입력을 잘못 묶었는지도 대조한다.
- terminal에서 지워지는 input/admitted_input_json을 원래 bytes 재독 증거로 주장하지 않는다. release 전 capture와 original request, 혹은 검증된 exact serializer 기반 기대 바이트가 필요하다.

현재 기본은 keeper당 message 2개다. first request를 hold한 뒤 하나만 더 queued이므로 매번 batch가 발생한다고 보장하지 않는다. 추가 batching 실험은 별도 workload identity로 취급한다. fault probe의 간소한 synthetic operations schema는 identity/backup 검사만 검증하며 c3cb production schema/canonical source/batch fidelity 시험을 대신하지 않는다. 이번 리뷰는 이 probe를 실행하지 않았다.

기본 2 messages에서도 native가 첫 claim 전에 두 입력을 모두 받으면 첫 execution이 batch일 수 있다. 실제 timing을 가정해 batch 검증을 생략하지 않는다. 새 HTTP 호출을 늘리지 않고 이미 얻은 queue-held status를 검산 근거로 쓸 수 있다. live SQLite snapshot도 보존한다면 한 read transaction에서 `operations` 13열과 `operation_batch_members` 5열을 같이 읽어 operation별 source/admission, member별 original canonical admitted_input_json/admitted_digest, leader/position을 결속한다. 종료 후 보존 원본과 backup을 그 snapshot에 join한다. public status들은 순차 관측이므로 서로 하나의 SQL transaction이었다고 표현하지 않는다. 이 설계 의견은 root가 준비하는 후속 v3의 실제 구현 리뷰 또는 실행 결과가 아니다.

canonical byte 구현을 단순화한다면 이 fixture의 알려진 ASCII 문자열·정수·null·빈 배열/객체 subset에 한정해 c3cb Yojson 출력과의 일치를 따로 검증한다. 임의 Unicode/float/Intlit까지 Python serializer와 Yojson이 동치라고 주장하지 않는다. fresh token 응답의 `actor=="dashboard"`와 Admin role을 이미 받은 응답에서 확인할 수 있다. caller identity의 explicit 이름은 `lib/mcp_server_eio_caller_identity.ml:93–105`에서 Stable로 선택되며, fresh fixture의 alias/registry가 바뀌었다면 해당 조건을 다시 확인한다.

## 소유권·격리·429·대기에 대한 나머지 판정

| 항목 | 소스에서 확인한 것 | 남는 조건/한계 |
|---|---|---|
| source/path | supplied binary를 packet에 복사·SHA 비교(`:493–499`), embedded 40hex source 조회(`:557–560`), health의 source/executable hash/root를 mutation 전 확인(`:598–609`) | source가 **원하는 c3cb**인지는 harness 인자에서 강제하지 않는다. root가 supplied artifact의 c3cb stamp/receipt/hash를 별도로 결속해야 한다. 40hex라는 이유만으로 c3cb 자격이 되지는 않는다. fixture의 --repo도 이 reviewed c3cb bytes임을 외부에서 결속한다. |
| 독립 runtime | mkdtemp base, 새 HOME/config, bootstrap skip, loopback ephemeral server/provider, host credentials env 미전달(`:500–556`); 처음 zero Keeper fibers 확인 후 N을 만든다 | ephemeral server port는 bind/release 후 재사용하여 작은 TOCTOU가 있다. 다른 process와 충돌하면 health identity/root/hash 검사가 fail-closed여야 하며 shared server로 채택하면 안 된다. 이 코드는 shared runtime을 재사용하지 않는다. |
| runtime fixture | 정확 release-evidence/runtime.toml을 읽어 sole loopback endpoint, streaming false, max-concurrent=N 및 inline fake credential을 엄격 검증(`:516–532`) | default binding/required lanes는 release fixture 권위에 의존한다. original fixture hash와 frozen initial/final config는 있어야 한다. production token/image는 필요하지 않다. scripts/fixtures의 다른 release runner를 실행하지 않는다. |
| guest 경계 | 새 unused image pin; PATH 앞 deny wrapper docker/container/msb/nerdctl/ssh, 모든 시도 exit126; 예상 inventory만 별도 분류(`:534–552`, `:766–771`) | 이는 fixed native/config의 text fixture guard다. 악의적 binary의 absolute daemon path 등을 차단하는 OS sandbox를 증명하지 않는다. unexpected guest command 한 건이면 실험 부적격이다. usable microVM/guest tool/Add-on/peer proof는 얻지 못한다. |
| real concurrency | 실제 owner up API, keeper_fibers=N, 실제 typed provider request keeper 집합=N, provider held 동안 모든 exact original op Queued/Running, release 시 active=N(`:616–709`) | provider max-concurrent를 N으로 바꿔 owner별 요청이 겹치게 한 scripted stage다. N개의 독립 HTTP producers나 실제 외부 모델 throughput은 아니다. 기본이면 original inputs는 2N이고 held model request는 N이다. |
| 429 | 하나의 admin producer; explicit HTTP429만 같은 RPC payload로 retry, Retry-After seconds/date 또는 기록된 1초 fallback; ambiguous mutation은 replay하지 않는다(`:280–325`) | 성공 attempt wire 시간과 최초 attempt→accept 시간/429 wait를 분리해야 한다. arbitrary 429를 타 시스템에 일반화하면 안 된다. c3cb server_auth quota wrapper의 check→handler 순서는 거부 전 dispatch 방지를 지원한다(`lib/server/server_auth.ml:997–1007`, `:1347–1352`). exact source가 달라지면 다시 확인한다. |
| read-only 재관측 | exact `(keeper,operation_id)` status만 OSError/HTTPException 후 같은 live runtime/deadline에서 반복; 원래 요청 mutate/replay 없음(`:670–695`) | 관측 유실 자체를 owner/turn failure로 결론내리지 않는다. POST MCP인 status 관측도 quota를 만나며 원래 phase pacing에 포함된다. |
| HTTP wait | native client timeout=`request_timeout`, always connection close(`:246–274`), provider socket timeout30s(`:359–361`), observation deadlines·owned process poll | socket timeout은 idle bound이고 `response.read()` 전체의 절대 wall deadline은 아니다. trickle/무한 body에 대한 일반적 절대 bound를 증명하지 않는다. reviewed c3cb의 finite fixture/API 응답 조건에서 business30의 무제한 urllib/ThreadPool P1은 확인되지 않았다. timeout/deadline 증거를 없애거나 무한 timeout으로 바꾸면 안 된다. |
| owned cleanup | release event set, sampler stop+join, own new-session process group TERM20s/KILL5s, reap, provider shutdown/server_close, non-daemon handler drain 및 active/handler count 검증(`:589–592`, `:743–792`) | cleanup 단계 예외는 후속 단계를 건너뛰거나 최초 예외를 가릴 수 있다. 일반 OS 실패까지 무조건 cleanup 완료라고 하지 않는다. build-commit subprocess는 timeout/별도 owner tracking이 없지만 c3cb implementation은 embedded commit을 출력하고 반환한다(`bin/main_eio.ml:3401–3412`); 자격 없는 다른 binary로 확대하지 않는다. |
| provider hold | release.wait의 의도적 hold는 success/finally/fallback에서 release; finite default delay10ms; incoming socket timeout 및 handler drain 존재 | huge user-supplied model-delay는 sleep 동안 cancel되지 않는다. 2→30→300에서는 reviewed finite delay를 유지한다. 외부 loopback 공격자/trickle까지 방어하는 서비스 시험은 이번 scope가 아니다. |
| failure fidelity | main에 failure.json 및 원래 requests/terminal/cleanup가 남고 reader는 원래 verdict를 덮지 않는 의도 | P2-1 원본 보존 문제를 먼저 수정한다. reader의 derived audit 성공은 기존 failure.json을 original PASS로 승격하지 않는다. |

## 2 → 30 → 300 실행 계획과 증거 입장 조건

소스상 이 단계 계획은 적합하다. **본 보고서는 단계 중 어떤 것도 실행하거나 승인하지 않았다.** root가 P2 수정 및 native/source 자격을 마친 뒤 단계마다 fresh output/base/HOME/config/provider port/server process를 사용한다. 같은 packet에 append하거나 실패 packet을 재사용하지 않는다.

| 단계 | 고정할 workload | 다음 단계 전 확인할 증거 |
|---|---|---|
| 2 owners | messages-per-keeper=2이면 4 original operation IDs; provider held=N=2; 기본 finite delay | c3cb native stamp/executable hash/health base·runtime instance; zero→2 fibers; exact original admissions/held states/typed model requests/replies/terminal rows; P2를 보완한 source/input/batch evidence; 소유 자원 종료 및 원본 보존 |
| 30 owners | 같은 scripted fixture와 원래 input 계약, 60 original IDs; 별도 packet | 2 단계의 실제 PASS와 부정적 증거를 유지하고 30에서 전 항목을 새로 확인. quota/hold/pacing을 outcome latency에서 분리. “30 business tools completed”로 부르지 않는다. |
| 300 owners | 같은 조건, 600 original IDs; README의 --settle-timeout 1200은 관측 예산 | 30 단계의 실제 증거 확인 후 새 300 packet. 하나의 deadline이나 샘플 수도 300 성공을 보장하지 않는다. deadline 만료는 실패로 보존하고 당시 held/running/original receipts와 shutdown 유발 cancellation을 남긴다. |

N owner fibers와 N actual held provider requests를 관측하더라도 host overhead, one-admin admission pacing/rate-limit, inventory maintenance, deliberately held provider, serialized status polling, request logging 및 별도 profiler 비용을 포함한다. held/released/settled를 나누고 valid health sample의 wire quantile만으로 성공률/전체 지연을 대체하지 않는다. source-only 검토는 실제 OS 자원 한계, 300 동시 sockets/threads의 성공, tail latency, CPU/GC, installed artifact dispatch 또는 graceful shutdown 성공을 측정할 수 없다.

실제 guest tool, sandbox image 부팅, Add-on Lane 작업, Keeper peer 업무, 외부 모델·독립 HTTP actor fleet, TUI/UI, production 변경·배포 및 전체 0.1ms 목표는 별도 실험이다. fake sandbox pin과 loopback provider credential은 이 경계를 의도적으로 유지한다.

## Frozen primary source hashes

| 파일 | SHA256 |
|---|---|
| keeper_scale_session.py | `ab5157338bea4e3f019bac7c5f856d135f8f9875b00b6624a2a1178b73000f29` |
| README-keeper-scale-session.md | `b85d749288a6c56ab3048a7184ec5402215d39a37d1e9ad63c0763071f6541a0` |
| scripts/fixtures/release-evidence/runtime.toml | `ccbe65e399f47a3abddbf4299e15dd0fd55001dd785b2e0d75948ad86acf7cfd` |
| keeper_scale_packet_audit.py | `d90322b27342bc392913a831678ec155f9bac1975eb6963ec6c1e305165383a5` |
| keeper_scale_fault_probe.py | `39813847175b0ad83c92a904bd159533af5e96d318a286fc19af3e8d48cee9e8` |

판정은 위 frozen source와 c3cb API에 한정한다. 후속 harness 수정, native artifact qualification, CI, profiler 또는 실제 workload의 성공을 이 문서에 소급 합산하지 않는다.
