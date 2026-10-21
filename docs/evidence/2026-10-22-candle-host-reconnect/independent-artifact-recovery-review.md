# E01 실제 guest 복구·정상 재제출 독립 검토

판정: **복구/재제출 경계와 새 artifact의 좁은 내용 계약은 확인. 위조·정상 verifier 우회·원래 Task 소유권 이탈을 입증하는 P0–P2는 발견하지 못함. E01 완료·Task 승인·Goal proof·Paid 판정은 아님.**

- 제품 source: `eb484b0aabe699b46740bcb787a935fb67bbfa8e`
- Task: `task-001`, assignee/producer `candle-host-qualifier`
- Goal: `goal-candle-host-eb484-source-qualification`
- 입력: session JSON이 가리킨 capture_directory의 19–31, 추가 허용된 32–37. 27/29는 원래 Task/실패 snapshot 좌표로 재확인했다.
- 읽기 전용 작업: 지정 캡처 JSON/txt/cells, exact source, 공개 source 계약, 격리 측정 파일, 격리 shim binary/sidecar의 digest만 읽었다. 비밀 credential 파일, private-server.log, raw private trace는 열지 않았다. API 요청·모델 호출·서버/컨테이너/CI/소스 변경·승인은 하지 않았다.

## 구체적으로 정정할 기록

1. **Write가 없었다는 요약은 사실과 다르다.** capture21에는 원래 operation `kmsg-ba2a0978a5163f54c139354cbea155f9`에 결속된 실제 Write tool-call이 있고, 별도 trace에는 Write err가 있다. assistant는 `microvm_shim_missing`을 보고했다. 이 캡처에는 첫 Write의 raw tool result 전체가 없으므로 그 문자열을 독립적으로 읽은 raw 오류 payload라고 바꾸어 적지는 않는다. 원래 artifact read가 실패한 실제 이유는 capture29의 `microvm_guest_not_running`이다. 두 사실을 구분해야 한다.
2. **복구가 첫 시도 하나로 끝났다는 Keeper 문구도 그대로 쓰면 안 된다.** capture33의 같은 recovery operation/turn에는 Write `exec-1792602557417-000c`, Write `exec-1792602568905-000d`, Read `exec-1792602571872-000e`가 있다. 첫 Write 인자는 blob preview, 두 번째는 400-byte JSON으로 보인다. 각 raw 결과가 없으므로 두 번의 성공한 파일 변경 또는 첫 호출의 사전 거절을 추정하지 않았다. 캡처가 증명하는 것은 두 번의 Write 호출과 한 번의 Read 호출, 최종 artifact 가독성이다.
3. **바이트 동일성은 실패하고 JSON 값 동일성은 성공한다.** capture36 artifact 400 bytes와 host 측정 파일 401 bytes는 마지막 newline 차이로 원문 bytes가 다르다. Keeper의 “바이트 단위로 정확히 일치”는 근거로 사용할 수 없다. 아래의 별도 직접 대조가 좁은 Task 계약의 근거다.

위 세 항목은 증거 설명의 정확성 문제이며, Task를 취소/대체하거나 판정을 우회할 이유는 아니다. 기존 실패와 잘못된 주장은 원본 기록으로 보존하고 후속 설명에서 정정하면 된다.

## 복구의 실제 관측과 아직 분리해야 할 것

- capture19의 Succeeded는 원래 chat operation 종료다. Write/Task 증거 성공이 아니며 원래 artifact_unreadable을 덮지 않는다.
- capture22는 오래된 MCP session ID에 대한 404다. capture23은 새 client session으로 같은 Task를 읽은 성공이다. 이를 Task 상실이나 반복 mutation으로 해석할 근거는 없다.
- capture24의 격리 shim은 binary SHA-256 `ca955b88245024c680868f5f803e9e3232e5458b87145c0e94ee9c0c1732c6d7`, 원래 sidecar와 일치한다. 본 검토에서도 **격리 destination** binary와 sidecar를 읽어 동일 digest와 executable permission을 확인했다. 운영 설정/비밀을 복사했는지에 대한 별도 파일 census는 하지 않았으며, 영수증의 명시 범위인 binary+sidecar를 넘어 읽지 않았다. 이 digest 일치만으로 release 서명·원격 출시 출처를 새로 인증한 것은 아니다.
- 이 dependency는 eb484에서 새로 빌드된 실행파일이 아니다. capture24가 이미 그 한계를 명시한다. eb484의 `keeper_turn_sandbox_runtime.ml:1065–1107`, `keeper_sandbox_microvm.mli:387–407`는 실제 binary/sidecar 검사와 부팅 때 별도 config 재생성을 지원한다. 원래 검사를 생략하거나 sidecar를 임의의 새 digest로 다시 만든 근거는 없다.
- capture25의 새로운 manual recovery admission과 26/31의 Running은 당시 진행 중인 상태였다. 추가 capture34가 동일 operation `kmsg-fd2c7def75116daeb030db0d5549f796`의 Succeeded와 원래 turn `trace-1792601812952-00000#3`를 기록한다. 이를 최초 요청의 결과로 섞지 않았다.
- capture32의 실제 server API는 같은 Keeper의 guest가 running, owner_pid=89650, network none, private qualification workspace에 속한다고 보고한다. 별도 kernel/process 재조회는 하지 않았으므로 독립 OS 소유권 관측이라고 부르지 않는다. capture33의 operation/turn-bound Write/Read와 capture36의 실제 guest artifact snapshot은 단순 assistant 성공 문장보다 강한 전달 증거다.
- capture30의 56×160 VT cells에서 문자를 재구성한 결과 txt의 모든 행과 정확히 같았다. 당시 UI는 configured off/0 active를 표시한다. 물리 desktop screenshot이나 이후 Off obligation/Paid 상태 증거는 아니다. capture37의 complete=true, issues=[], enabled=false, inactive, instances=[]가 뒤 시점의 독립 API 상태다.

## 정상 재제출이 원래 authority를 보존하는가

exact eb484 `workspace_task_lifecycle.ml:184–206`은 AwaitingVerification에서도 같은 assignee가 재제출하도록 명시한다. started_at은 유지하고 새로운 verification_id를 만든다. 같은 파일 `230–257`은 늦게 도착한 옛 ID의 verdict를 Verification_id_mismatch로 거절한다.

`workspace_task_transitions.ml:309–365`는 생성된 AwaitingVerification의 실제 assignee/새 ID에 새 제출 request를 준비한다. `workspace_task_verification.ml:29–45`는 artifact refs와 설명 note를 구분해 수집한다. 즉 설명 note만 추가해 원래 unreadable snapshot을 새 artifact로 바꾸는 흐름이 아니다.

실제 캡처도 이 계약을 따른다.

- capture27의 같은 Task는 원래 producer/assignee와 `vrf-ccff94341a405e50b3fb9fda29c82e6c`를 갖는다.
- capture29의 그 원래 ID는 여전히 `artifact_unreadable`과 guest-not-running 원인을 보존한다.
- capture35는 authenticated `candle-host-qualifier` identity로 같은 Task에 `submit_for_verification`을 사용한다. 결과는 AwaitingVerification→AwaitingVerification, 새 ID `vrf-5ee2e4f6674a8ccda7adaa075d60da5b`, diagnostics=[]이다. Task 생성/취소/강제 완료나 수동 원장 rewrite가 아니다.
- capture36은 그 **새 ID**의 request.worker/producer가 같은 Keeper이고 실제 artifact가 포함됨을 보여 준다. `authority_kind=human_operator`, `authority_actor=local-admin`인 이 evidence-read 영수증을 Task 승인 verdict로 세면 안 된다.
- capture28 시점 Goal은 Executing, verification=null이다. 37까지의 자료에는 새 Task 독립 verdict, Goal proof, operator confirmation, Payout_owed/Paid가 없다.

## 새 measurement의 좁은 계약 대조

직접 수행한 읽기/대조 결과(제품 동작 시험이 아닌 파일 검토):

| 항목 | 확인 결과 |
|---|---|
| 새 snapshot artifact bytes | 실제 UTF-8 400, 선언 bytes=400, truncated=false |
| host measurement | 401 bytes; artifact와 raw equality=false, JSON equality=true |
| source_commit | eb484b0aabe699b46740bcb787a935fb67bbfa8e |
| source_path | lib/server/server_candle_appraiser.ml |
| checkout 전체 bytes와 해당 exact Git blob | 동일 |
| 두 source bytes의 SHA-256 | b4e3984bdbf0fb70cf065c9313e8fa31b0f943cc403d3731a95c997447981078 |
| artifact.sha256 | 위 직접 계산과 일치 |
| verified_count/task_id | 정수 1 / task-001 |

capture27의 좁은 completion contract는 정확한 source_commit/SHA-256을 기록하고 complete checkout 대 Git blob 비교 후 verified_count=1을 갖는 것이다. **그 값과 source identity 계약은 충족한다.** 이 값은 host가 측정했고 Keeper가 guest에 보존했으며, 독립 review에서 source 대조를 다시 확인했다. Keeper가 guest 안에서 독립 비교를 수행했다거나, JSON의 method/performed_at만으로 과거 실행을 입증했다는 뜻은 아니다. 그러므로 이 보고서 자체를 Task 승인 API나 Goal verifier 결과 대신 쓰지 않는다.

향후 평가에는 새 immutable artifact와 host 수행/guest 보존의 구분을 그대로 전달해야 한다. 모델 Grade가 외부 판단으로 이어지더라도 이 한 파일의 source identity 측정이 Browser 기능·전체54·67층 품질을 증명하는 것으로 확대되면 안 된다.

## 다음 절차의 타당한 경계

새 artifact에 대해 원래 Task의 독립 completion authority 판정을 받고, 별도의 Goal verifier proof를 얻은 뒤 exact request/run/criterion에 대한 operator confirmation을 하는 순서는 정상 경로다. 운영자가 지금 provenance와 source bytes를 감사하는 것과 실제 Task/Goal 승인 권한을 행사하는 것은 별개다. 승인이나 확인이 성공했다고 미리 쓰지 않는다.

Addon이 Off인 채 유효한 Candle policy 아래 Snapshot/Owed가 기록되는지 확인한 다음 같은 logical installation을 On으로 바꿔 실제 common Exact/provider→worker retained result/ACK→host domain decode→원래 Owed에 Paid 1회를 관측하는 계획은 기존 source 권한 경계와 맞는다. 이 단계들은 37까지 **미실행/미확인**이다. 최신 source #44391 Replay 수리의 포함/실행 여부도 eb484의 성공으로 바꿀 수 없다.

결론: 현재 복구·정상 재제출의 구체적인 권한 우회 finding은 없다. 문구상 “Write 없음/첫 시도/바이트 동일” 세 표현은 위 증거대로 정정해야 한다. 실제 Task verdict→Goal proof→operator confirmation→Off obligation→On provider/Paid-once와 원래 자원 정리는 별도 원본 영수증이 도착한 범위에서만 판정해야 한다.
