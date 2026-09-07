# MASC 최근 6시간 집중 개선 감사

**분석 창:** 2026-09-07 05:58:23–11:58:23 KST (UTC 2026-09-06T20:58:23Z–2026-09-07T02:58:23Z).

**범위:** ~/me/.masc/logs/system_log_2026-09-06.jsonl, system_log_2026-09-07.jsonl의 timestamp 기준 102,600행. INFO 92,944 / WARN 8,764 / ERROR 892. 다른 .masc 파일 전체의 모든 문장을 전수 집계했다는 뜻은 아니다. 로그는 원본 파일/행/seq를 보존해 window.jsonl로 동결했다.

**공개본 식별자:** `health-dashboard-recovered.json`과 `health-dashboard-relocated.json`의 조직 식별자는 `exampleorg`로 익명화했다. JSON 타입과 수치는 보존했다. 파일 안의 artifact 해시는 관측한 바이너리·자산의 식별자이며, 익명화한 JSON 파일 자체의 해시가 아니다.

**판정:** 아래 count는 대표 로그 이벤트 수이며 서로 독립인 사고 수가 아니다. provider 실패→pipeline 실패→Keeper 실패는 중첩한다. 최종 행은 health의 별도 live acceptance 상태다.

**실행 식별:** 첫 health binary b90d5f6182, 검토 source 8b804d8d5b. 다른 운영 작업이 진행 중이며 중간 재조회 binary는 8b804d8d5b. 이 초기 바이너리 교체는 본 세션이 수행하지 않았다. 이후 이 세션의 자산 적용과 ACK는 하단 시각별 증거로 구분한다.

| # | 개선 대상 | 대표 관측 | 진행 |
|---|---|---:|---|
| 1 | Claude quota 반복과 잘못된 effect fence | 1698 | quota-tested |
| 2 | GLM 요청 제한 | 617 | investigate |
| 3 | Librarian exact 실패와 주간 한도 | 48 | domain-failover-tested |
| 4 | DeepSeek tool-call 응답 누락 | 224 | code-fix |
| 5 | 중첩 tool-cycle checkpoint 저장 실패 | 21 | related-code-fix |
| 6 | 복합 도구는 성공하지만 실행 증거 저장 실패 | 5 | code-fix |
| 7 | 재개 후 반복 도구 루프 | 231 | direct-scope-tested-autonomous-pending |
| 8 | Provider 연결 장애 | 51 | tested-code-fix |
| 9 | 일반 문장의 @check·lint를 ID 오류로 기록 | 362 | code-fix |
| 10 | MCP 인증 누락·Dashboard token 불일치 | 373 | hint-fixed-client-pending |
| 11 | 삭제된 new-keeper의 종료 복구 반복 | 6 | live-ack-restart-observed |
| 12 | Board candidate ledger schema 불일치 | 12 | retention-merged-tested |
| 13 | Dashboard snapshot 장시간 갱신 | 111 | performance-merged |
| 14 | Dashboard build-stamp 누락 | 5 | distribution-stack |
| 15 | microVM sweep가 전체 Keeper 부팅을 막음 | 68 | tested-code-fix |
| 16 | microsandbox가 요구 격리 보장을 표현 못함 | 5 | backend-capability |
| 17 | 브라우저 live lane 미연결 | 12 | live-roundtrip-observed |
| 18 | Discord 삭제·권한 없는 channel 바인딩 | 28 | external-binding |
| 19 | WebSearch 전 provider 실패와 WebFetch HTTP 오류 | 19 | search-service-recovered |
| 20 | 실행 가능한 owner의 durable queue 정체 | health: pending33 oldest4893s at initial capture | batch-drain-observed |

## 항목별 증거와 다음 완료 조건

### 1. Claude quota 반복과 잘못된 effect fence

- 조치: API diagnostic와 exact CLI quota 수정은 이전에 관측한 binary fe702d71da에 포함. 후속 #33873 exact CLI11/11, HITL46/47; 기존1개 실패로 전체 CI는 FAIL. 실제 failover 연속성은 별도 검증 필요.
- 관련 코드/경계: `lib/runtime/runtime_claude_code.ml`
- 집계 주의: 1698 quota events; propagated fences are overlapping observations
- 최초 증거: `2026-09-06T21:05:47Z` / seq `25985026` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:267546`
> Claude Code subscription turn failed (kind=quota_blocked)
- 마지막 증거: `2026-09-07T02:58:01Z` / seq `26386234` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:43098`

### 2. GLM 요청 제한

- 조치: provider 반환 Retry-After·reset과 실제 후보 선택을 대조. 동시 호출/queued wake에 의한 재시도 증폭을 별도 재현해야 함.
- 관련 코드/경계: `lib/keeper/keeper_runtime_attempt.ml`
- 최초 증거: `2026-09-06T21:05:50Z` / seq `25985072` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:267592`
> [agent_core:http_client] {"event":"http_client_4xx_request_header_profile","url":"https://api.z.ai/api/coding/paas/v4/chat/completions","status":429,"response_server":null,"cf_ray":null,"request_header_count":4,"total_request_header_bytes":148,"max_single_header_bytes":73,"cdn_per_header_limit_bytes":8192,"header_sizes":[{"name":"Authorization","bytes":73},{"name":"Content-Type","bytes":32},{"name":"content-length","bytes":24},{"name":"connection","bytes":19}],"note":"4xx from an LLM endpoint. Header VALUES omitted (may carry credentials); sizes only. A cloudflare/RunPod edge rejects a single header line over cdn_per_header_limit_bytes with an opaque 400 before the origin — compare max_single_header_bytes."}
- 마지막 증거: `2026-09-07T02:53:00Z` / seq `26384954` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:41818`

### 3. Librarian exact 실패와 주간 한도

- 조치: Codex luna 후보 추가 후에도 Claude claim_schema_mismatch가 남은 후보를 막는 결함5건 확인. #33913의15b554f7a8에서63/63 동작 테스트 PASS. 외부 최종headcfc1f173d8의 필수 검사 PASS 후d16c83de17로 병합됐다. 실제 후속 후보 선택과 failover 연속성은 미검증.
- 관련 코드/경계: `lib/keeper/keeper_librarian_runtime.ml`
- 최초 증거: `2026-09-06T21:21:58Z` / seq `25990215` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:272735`
> memory os librarian failed lane=librarian_exact: librarian exact execution failed outward_effect=started cause=agent_core_execution_failed: slot=ollama_cloud.deepseek-v4-flash-0731 call_id=b64a83fb7e9e127ad4fdab36d5748219 cause=provider refused (http_status=429 refusal=rate_limited) raw_response={"error":"you (yousleepwhen) have reached your weekly usage limit, add extra usage: https://ollama.com/settings (ref: 329bef59-e725-4293-aa76-0e6556d9efec)"} ; flow=[slot=ollama_cloud.deepseek-v4-flash-0731 call_id=b64a83fb7e9e127ad4fdab36d5748219; slot=glm-coding.glm-5.3-flash call_id=66a83f8e233f25848cf44bbb48d40b33; advance=glm-coding.glm-5.3-flash->ollama_cloud.deepseek-v4-flash-0731 kind=execution_failed cause=provider refused (http_status=429 refusal=rate_limited) raw_response_sha256=41976dbd
- 마지막 증거: `2026-09-07T00:56:21Z` / seq `26159263` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:16127`

### 4. DeepSeek tool-call 응답 누락

- 조치: PR #33829: admission이 복구한 메시지를 resume checkpoint에도 전달. 모든 224회가 이 한 원인이라는 주장은 하지 않음.
- 관련 코드/경계: `lib/keeper/keeper_agent_run.ml`
- 최초 증거: `2026-09-06T20:59:04Z` / seq `25983915` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:266435`
> jazz-developer: keeper cycle FAILED runtime=glm-coding.glm-5.3 deferred_next_runtime=none max_context=524288 context_budget=524288 primary_budget=524288 requested_override=none system_and_user_bytes=26702 latency=3227ms error=Invalid request (unknown): An assistant message with 'tool_calls' must be followed by tool messages responding to each 'tool_call_id'. (insufficient tool messages following tool_calls message)
- 마지막 증거: `2026-09-07T02:04:06Z` / seq `26276260` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:33124`

### 5. 중첩 tool-cycle checkpoint 저장 실패

- 조치: PR #33829와 연관. source repair 이후 provider resume 및 checkpoint sink 성공을 별도 검증.
- 관련 코드/경계: `lib/keeper/keeper_agent_run.ml`
- 최초 증거: `2026-09-07T00:28:10Z` / seq `26102003` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:8867`
> turn checkpoint sink failed stage=after_assistant_collected turn=2255 detail="checkpoint messages are structurally invalid: Keeper_transcript_unit.Overlapping_tool_cycle {message_index = 4908;\n  tool_use_id = \"call_10dfh9hh\"}"
- 마지막 증거: `2026-09-07T02:08:42Z` / seq `26277173` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:34037`

### 6. 복합 도구는 성공하지만 실행 증거 저장 실패

- 조치: PR #33833: batch ordinal을 batch 내부 크기와 비교하던 잘못된 검증 제거. 후속 serial/concurrent 4개 settlement 저장/재조회 테스트.
- 관련 코드/경계: `lib/keeper/keeper_skill_composition_evidence.ml`
- 최초 증거: `2026-09-06T23:52:22Z` / seq `26090362` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:322882`
> Skill composition evidence publication failed: tool=keeper_compose_work-intake run=01a07923-2506-7000-9582-5630270e717d error=invalid Skill composition evidence: every node must carry typed identity, schedule, and result
- 마지막 증거: `2026-09-07T02:52:25Z` / seq `26384752` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:41616`

### 7. 재개 후 반복 도구 루프

- 조치: 직접 요청 scope #33967은 97e3c224ad에서 scope11·host46·replay21·Codex2·Claude23·invocation11 PASS. 전체125개 중124 PASS/Antigravity 기존 전송 관측1 FAIL이며 외부8fd39e0069로 병합됐다. 그 실패 수정 #33982는 검증 중. 큐 binding #33984의 b9f30528ff는77/77 PASS, 후속9f79ffbb72는 lint용 주석1줄만 수정했다. 자율 실행·자식 부모 연결·official-client 재시작 영속화는 남아 있다.
- 관련 코드/경계: `lib/keeper/keeper_agent_run.ml`
- 최초 증거: `2026-09-06T21:00:25Z` / seq `25984123` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:266643`
> yielding repeated exact tool loop tool=Execute count=6
- 마지막 증거: `2026-09-07T02:58:09Z` / seq `26386295` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:43159`

### 8. Provider 연결 장애

- 조치: #33856 병합. DNS 모든 주소의 TCP 연결을 경합시키고 실패/취소 소켓 소유권 정리. 새10/10, 캐시19/19 PASS; broader HTTP suite는 기존 zero-length Eio read 사례1개 실패.
- 관련 코드/경계: `agent_core network transport / runtime failure route`
- 최초 증거: `2026-09-06T22:15:02Z` / seq `26004046` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:286566`
> pipeline stage failed stage=route error="[route] Network error: Eio.Io Net Connection_reset Unix_error (Connection reset by peer, \"readv\", \"\")"
- 마지막 증거: `2026-09-07T02:57:35Z` / seq `26386065` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:42929`

### 9. 일반 문장의 @check·lint를 ID 오류로 기록

- 조치: PR #33834: prose 후보는 순수 파싱. 외부 작성자 잘못된 ID 검증/경고는 그대로 유지. 재독 시 rejection count/timestamp 불변 테스트.
- 관련 코드/경계: `lib/board/board_audience.ml`
- 최초 증거: `2026-09-06T21:05:49Z` / seq `25985044` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:267564`
> Id_shape rejected input 'check·lint': identifier contains characters outside [A-Za-z0-9_:-]
- 마지막 증거: `2026-09-07T01:09:21Z` / seq `26162268` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:19132`

### 10. MCP 인증 누락·Dashboard token 불일치

- 조치: #33871: 잘못된 localStorage 안내를 실제 sessionStorage 키로 정정. 사용자 브라우저의 거절된 자격 증명은 아직 수정하지 않음.
- 관련 코드/경계: `lib/server/server_mcp_transport_http_respond.ml:149; lib/server/server_auth.ml`
- 집계 주의: MCP347 + dashboard26
- 최초 증거: `2026-09-06T21:02:53Z` / seq `25984474` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:266994`
> [silent:dashboard_actor_fallback] outcome=error token_hash_prefix=41ba75a6 err_kind=token_mismatch actor_hint=dashboard err=[AuthError] Invalid token: Token mismatch — request actor hint ignored. Remediation: clear the browser's stored dashboard token (localStorage masc_dashboard_token) or delete .masc/auth/dashboard.token so a fresh token is minted on the next dashboard load.
- 마지막 증거: `2026-09-07T02:09:56Z` / seq `26277375` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:34239`


### 11. 삭제된 new-keeper의 종료 복구 반복

- 조치: 도메인103/103·HTTP34/34 PASS 후08:27:04Z 실제 부재 ACK 적용. 외부08:37:36Z 재시작 뒤09:06:48Z revision5·operator_absence_acknowledged 유지, 시작 이후 해당 복구 오류0건. 09:39:25Z에도 ACK 유지 확인. 이 세션이 재시작한 것은 아니다.
- 관련 코드/경계: `lib/keeper/keeper_shutdown_finalize.ml`
- 최초 증거: `2026-09-06T23:26:03Z` / seq `26080010` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312530`
> shutdown recovery failed keeper=new-keeper operation=shutdown-15ad5365-6cf0-4880-b6d5-6b57e26441a7 error=Keeper shutdown admission release failed in operation shutdown-15ad5365-6cf0-4880-b6d5-6b57e26441a7: Keeper owner not found: new-keeper
- 마지막 증거: `2026-09-07T02:43:56Z` / seq `26382595` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39459`

### 12. Board candidate ledger schema 불일치

- 조치: 원본2파일30행 보존. 거부 행 자동 삭제를 막는 #33906은76/76 PASS 후11aa475082로 병합됐으며 잠시 실행한9c81559b에 포함. 원래17Pending·기존 파티션 재접수는 별도 미완료.
- 관련 코드/경계: `lib/keeper/keeper_board_attention_candidate.ml`
- 집계 주의: 2 files across 6 boots; not 12 distinct corrupted files
- 최초 증거: `2026-09-06T23:26:05Z` / seq `26080097` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312617`
> candidate ledger /Users/dancer/me/.masc/board_attention_candidates/gondolin-probe.jsonl: skipped 11 unreadable row(s); first is line 1: board attention candidate fields must be exactly [schema_version,candidate_id,keeper_name,signal,keeper_context,recorded_at,status], got [schema_version,candidate_id,keeper_name,signal,judgment_request,recorded_at,status]
- 마지막 증거: `2026-09-07T02:43:58Z` / seq `26382707` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39571`

### 13. Dashboard snapshot 장시간 갱신

- 조치: 선언 TOML을 요청당 한 번 읽어 fleet에 공유하는 #33877 병합. 새4개 포함90/91 PASS, 기존 identity scan 실패. 05:15Z 당시 fe702d71da에는 아직 없으므로 성능 개선 미측정.
- 관련 코드/경계: `lib/dashboard/dashboard_snapshot.ml`
- 집계 주의: shell_light70 among111; other18 slow render not added
- 최초 증거: `2026-09-06T23:26:05Z` / seq `26080100` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312620`
> dashboard_snapshot heavy refresh: component=activity_defaults elapsed_s=1.627 allocated_mb=664.8 ttl_s=10
- 마지막 증거: `2026-09-07T02:43:59Z` / seq `26382712` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39576`

### 14. Dashboard build-stamp 누락

- 조치: 설치 resolver56/56 PASS와 Linux x64/ARM64·macOS ARM64 실제 설치 smoke PASS. 운영6db68b4bea와 같은 소스의 별도 dashboard artifact34100510195를642파일 검증·백업 후08:29:52Z 적용해 HTTP200·health ok를 확인했다. 바이너리 설치·재시작은 하지 않았으며 설치 번들 방식의 운영 전환은 남아 있다. 09:35Z 외부 바이너리 변경 후 다시 stale/unbound이며 실행·디스크 바이너리 hash도 불일치했다.
- 관련 코드/경계: `scripts/build-dashboard-if-needed.sh`
- 최초 증거: `2026-09-07T00:47:21Z` / seq `26156709` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:13573`
> bundle build-stamp unavailable at /Users/dancer/me/workspace/yousleepwhen/masc/assets/dashboard/.build-stamp — dashboard assets may be missing or unbuilt; inspect /health dashboard_surface.recovery
- 마지막 증거: `2026-09-07T02:43:50Z` / seq `26382542` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39406`

### 15. microVM sweep가 전체 Keeper 부팅을 막음

- 조치: #33846 병합. 교정 head642df022c9 원격 sandbox55/55, startup85/85 PASS. 병합 head985f7dbac0는 main merge를 포함하며 대상 구현 diff는 없음. 05:15Z 당시 fe702d71da에 병합 커밋57ca6d5399 포함을 확인. 성공 VM 생성은 미검증.
- 관련 코드/경계: `lib/server/server_runtime_bootstrap.ml`
- 집계 주의: 68 wait lines, 23 WARN, max119.4s
- 최초 증거: `2026-09-06T23:26:08Z` / seq `26080169` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312689`
> autoboot: waiting for lazy startup tasks to finish before keeper boot [microvm_guest_sweep (running 5.1s)]
- 마지막 증거: `2026-09-07T02:45:22Z` / seq `26382956` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39820`

### 16. microsandbox가 요구 격리 보장을 표현 못함

- 조치: cap-drop/read-only-rootfs 보장을 지원하는 backend/버전이 필요. 옵션 무시나 보장 약화는 수리가 아님.
- 관련 코드/경계: `lib/keeper/keeper_sandbox_microvm.ml`
- 최초 증거: `2026-09-06T21:15:07Z` / seq `25987963` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:270483`
> tool tool_execute returned error result: {"error":"GitHub identity snapshot unavailable: microvm_start_failed: microvm_constraint_unexpressible: microsandbox cannot express drop_all_capabilities (msb 0.6.16 run has no --cap-drop. Its `--security restricted` is the only candidate and its help does not say what that drops, so it is not substituted for a guarantee asked for by name); read_only_rootfs (msb 0.6.16 run has no --read-only)","typed":true,"cmd":"sh -c hostname; id -un; uname -m; pwd; cat /proc/1/comm","cwd":"/Users/dancer/me/.masc/playground/msb-probe","execution_location":{"cwd":"/Users/dancer/me/.masc/playground/msb-probe","cwd_source":"explicit_cwd","scope":"playground_root","playground_root":"/Users/dancer/me/.masc/playground/msb-probe","relative_cwd":".","repo_name":null,"repo
- 마지막 증거: `2026-09-07T01:52:38Z` / seq `26274613` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:31477`

### 17. 브라우저 live lane 미연결

- 조치: native host 설치 후09:40:03Z 실제 live 확장으로 tabs.list와 page.read 왕복 성공: HTTP200, 탭9개, 본문515자. 본문·URL·제목은 증거에서 제외. 정확한 응답 host PID 및 여러 브라우저 구분은 미측정.
- 관련 코드/경계: `connectors/browser`
- 최초 증거: `2026-09-06T22:12:34Z` / seq `26003629` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:286149`
> keeper:analyst tool_call tool=BrowserTabs source=- params=[lane] input_shape=[lane=string:4] outcome=error out_len=341 failed_params={"lane":"live"} error_preview=no browser lane connected: the live lane needs the operator's browser running with the browser-lane extension and host (connectors/browser) failure_class=workflow_rejection — The current state does not admit this action; it is a rule, ...
- 마지막 증거: `2026-09-07T02:55:24Z` / seq `26385674` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:42538`

### 18. Discord 삭제·권한 없는 channel 바인딩

- 조치: 삭제 channel과 permission-denied channel 구분. 바인딩 소유자의 채널 의도·접근권을 확인 후 명시적 unbind/권한복구. 임의 대체 채널 전송 안 함.
- 관련 코드/경계: `Discord directory / configured channel binding`
- 집계 주의: 28: deleted12, inaccessible16
- 최초 증거: `2026-09-06T23:26:07Z` / seq `26080103` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312623`
> Discord directory bound channel 1356818755795157113 is deleted (10003); skipping                it until restart — unbind it to stop this warning
- 마지막 증거: `2026-09-07T02:44:03Z` / seq `26382801` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39665`

### 19. WebSearch 전 provider 실패와 WebFetch HTTP 오류

- 조치: 실제 WebSearch·WebFetch 성공과 원래13개 URL 오류는 구분한다. HTTP 실패 분류·코드 보존#33936은120422bb9b에서 WebFetch14/14·bridge20/20 및 필수 검사 PASS. 외부가c7fe4f67a1로 병합; 원래 URL 접근 복구·배포는 미검증.
- 관련 코드/경계: `lib/tool_misc_web_search.ml`
- 집계 주의: search6 + fetch13; one query may fail two providers
- 최초 증거: `2026-09-06T21:02:53Z` / seq `25984475` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:266995`
> tool masc_web_fetch returned error result: HTTP 404
- 마지막 증거: `2026-09-07T02:43:15Z` / seq `26332377` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39241`

### 20. 실행 가능한 owner의 durable queue 정체

- 조치: #33890은76/76 PASS와9c에서 batch 로그7회 관측. #33947은65개 번호 있는 테스트와 queue 시나리오 PASS 후 이 세션이d5e0685b38로 병합. #33938은 외부6a13f6a84a 병합 후 exact827803에서6개 suite PASS(156개 번호 있는 테스트와 queue·terminal-matrix 실행). 전체 FIFO 소비·장기 연속성은 미검증.
- 관련 코드/경계: `keeper_event_queue.work_liveness`
- 집계 주의: health: pending33 oldest4893s at initial capture

## 검증 경계

- [실제 dashboard screenshot](dashboard-before.png): missing build-stamp와 degraded queue 표시. Headless 독립 profile이므로 사용자 브라우저 token/session이나 Keeper live lane 증거가 아니다.
- 최초 health: `health-before.json`; 중간 health: `health-mid.json`. 중간 pending83, oldest5604s로 아직 개선 입증되지 않았다.
- INFO에도 Board exact failure978, runtime terminal failure925가 존재한다. 공급자 실패와 겹쳐 독립 후보 수로 더하지 않았다.
- 정상 journal_pruned410 8건 및 잘못된 artifact SHA/offset/보유 task claim 거절은 독립 runtime 결함으로 부풀리지 않았다.
- CI의 @check는 typecheck이며 behavioral test 실행과 다르다. test.yml targeted suite를 각 정확한 commit에 별도 dispatch했다. 결과는 완료 후만 PASS로 표기한다.
- DeepSeek 도구 결과 연결 계약: https://api-docs.deepseek.com/guides/tool_calls/

## 추적 이슈

[20개 항목 추적 #33841](https://github.com/jeong-sik/masc/issues/33841).

## 현재 네트워크 재측정

IPv4 api.z.ai: HTTP301, connect 0.030s. IPv6: curl7 연결 실패. 인증 없는 root URL 요청으로 연결만 확인했으며 모델 inference 성공이나 과거 48회 원인 확정이 아니다. provider-network-probe.json 참고.

## 정확한 commit의 behavioral CI

| 수정 | commit | suite 결과 | 실행 |
|---|---|---|---|
| 재개 transcript #33829 | df247b1926 | 41/41 PASS | [34078900162](https://github.com/jeong-sik/masc/actions/runs/34078900162) |
| 복합 실행 증거 #33833 | 356a6908d9 | durable save/load scenario 1 PASS, 4 settlements | [34078814610](https://github.com/jeong-sik/masc/actions/runs/34078814610) |
| CLI diagnostic #33839 | 546a4234cd | runtime_claude_code 62/62 PASS, 새10개 포함 | [34078902054](https://github.com/jeong-sik/masc/actions/runs/34078902054) |
| Board prose 파싱 #33834 | 778b244b6e | Board dispatch85/85, validation20/20 PASS | [34078816312](https://github.com/jeong-sik/masc/actions/runs/34078816312) |

마지막 두 실행 전체는 FAIL이다. 함께 실행한 기존 test_keeper_claude_code_runtime15/23은 run_keeper_turn fixture가 system_prompt를 넘기지 않아 CLI 진입 전에 실패한다. 기존 validation_coverage2/44는 agent.name 및 '.'를 거절해야 한다는 기대값인데, 현재 parser는 두 값 모두 허용하며 이번 변경은 그 acceptance를 바꾸지 않았다. 새 test의 PASS와 이 broader failure를 합쳐 전체 green으로 표시하지 않는다. 이 두 기존 suite를 변경하거나 baseline branch에서 재실행하지 않았으므로 baseline 실행 비교는 미측정이며, preexisting 판정은 변경 전후 source 비교 근거다.

로컬 Dune build/test는 constitution에 따라 실행하지 않았다. Test workflow의 원격 runner가 실제로 컴파일하고 실행했다.

## 추가 수정의 원격 검증

- #33846: head642df022c9, [34082014565](https://github.com/jeong-sik/masc/actions/runs/34082014565), sandbox55/55 및 startup85/85 PASS. 이후 main merge head985f7dbac0에서 대상 구현은 동일하며 PR은57ca6d5399로 병합됐다. 성공 VM 생성은 미검증.
- #33857: headec07fcf653, [34083036685](https://github.com/jeong-sik/masc/actions/runs/34083036685), 현재 실행 증거 분리 포함 outcome39/39 PASS. 기존 hooks48개 중 paused adoption1개 실패하므로 실행 전체는 FAIL.
- #33856: headb812ea7266, [34083423286](https://github.com/jeong-sik/masc/actions/runs/34083423286), 새 연결/취소/FD10개와 캐시19개 PASS. quota13개도 PASS. 기존 HTTP43개 중 zero-length buffer를 Eio.Flow.single_read에 넘기는1개가 Eio precondition에서 실패, 전체 실행 FAIL. 해당 기존 함수는 이번 diff 밖이며 기준 실행 비교는 미측정.
- #33855/#33873: Claude UUID, Antigravity usage/TOML timeout/OAuth/cwd, Claude assistant model 등의 fixture 누락을 고쳤다. 최종 후속 heada92c1b6859의 [34084021921](https://github.com/jeong-sik/masc/actions/runs/34084021921): exactCLI11/11 PASS, HITL46/47 PASS. 새 quota/실행 식별자 사례는 통과했고, 기존 pre-bind cancellation payload identity1개가 실패하여 전체 FAIL이다. 기준 실행 비교는 미측정이다.
- #33877: headde33f2c50f의 [34084240453](https://github.com/jeong-sik/masc/actions/runs/34084240453): 새4개 포함90/91 PASS. 기존 repository-wide concrete Keeper identity scan이 이번 diff 밖12개 문자열을 지적해 전체 FAIL. 지연 개선은 아직 미측정.

두 원본 system JSONL 파일을 전체 스캔한 결과 JSON 파싱 실패0행, timestamp 누락0행이었다. CI summary 파일은 해당 실행 로그의 판정 줄을 추출하고 후행 공백만 정리했다.

## 새 운영 재조회 (서로 길이가 다른 관측 창)

03:32Z 재조회 binary148a773ff8의 Git ancestry에는 #33829/#33833/#33834/#33839 네 변경이 실제 포함된다. 이 배포와 merge는 다른 작업 주체가 진행했으며 본 세션이 실행하지 않았다. 03:22:10Z–03:32:26Z 약10분, 4,391행에서 insufficient-tool-message cycle error0, overlapping checkpoint0, composition evidence failure0, check·lint warning0, Claude quota13이 관측됐다. 전체6시간 대비 단순 감소율이나 완치율로 비교할 수 없다. 해당 경로가 실제 충분히 실행됐는지와 concurrent 변경 영향이 남는다.

03:32Z 당시 health는 runnable pending61, oldest2292초(약38분)이며 여전히 stalled/degraded이다. 직전 관측 pending115/oldest6471초에서 줄었지만 감소만으로 FIFO 소비·효과 전달 성공을 판정하지 않는다. dashboard stamp는 여전히 missing. 최신 health-final.json과 post-deployment-observation.json 참고.

동일한 새 배포 관측 창에서 started_at이 배포 이후이고 recorded_at이 창 종료 이전인 영수증도 별도 조회했다. polisher1, rondo7, geek-scout12, pr-updater6개의 receipt_done이 있었다. jazz-developer는 같은 조건의 완료 영수증0개여서 재개 완료로 선언하지 않는다. 이 결과는 응답 품질·기억 연속성·모든 pending event 소비 증명과 다르다. post-deployment-receipts.json에 원본 파일/행과 terminal 필드를 기록했다.

## 04:25–04:40Z 운영 조치와 남은 경계

Board/Librarian/HITL의 기존 두 CLI 후보는 같은 Claude 계정이었다. 독립 Codex luna의 실호출 schema2/2 성공과 무스키마 대조를 확인하고, 세 목록에 luna를 추가했다. 서버 preview 유효, durable commit order4, revision5fbae10e…와 디스크/GET 재조회가 일치했다. HTTP raw-save API는 호출자 CAS를 지원하지 않으므로 적용 직전 원문 일치 확인만 했으며 CAS라고 주장하지 않는다. 원문 설정/인증 토큰은 이 보고서에 포함하지 않는다.

이후 관측한 Board 판정은 GLM/Ollama HTTP 후보였다. Codex 새 경로가 해당 판정을 성공시켰다고 주장하지 않는다. 04:26:33Z Librarian snapshot revision1239 commit도 있었으나 새 CLI 구성과의 인과는 미확인이다.

설정된 검색 endpoint localhost8888에는 listener가 없었다. [공식 SearXNG 설치 문서](https://docs.searxng.org/admin/installation-docker)에 따라 digest55e1fa15…의 서비스를 loopback8888에 복구했다. 직접 검색은37결과/2.355초. 두 upstream engine CAPTCHA/parse 오류는 응답에 보존돼 있다. 공개 MCP40개 목록에는 WebSearch가 없어 내부 도구 경유 성공까지 주장하지 않는다. 서비스 구성은 runtime services/searxng에 영속했고 영수증에 digest를 기록했다.

해당 시점 health04:40:49Z binary1ec84be0a4, started04:39:48Z. 배포는 다른 작업 주체가 수행했다. 이 바이너리에 이번 추가 수정 전체가 들어갔다고 주장하지 않는다. runnable backlog27, oldest4595초이며 dashboard stamp도 missing이다. 20항목 전체 해결/연속 턴/기억/표면 전달 완료는 아직 아니다.

## 04:55–05:00Z 브라우저와 원격 artifact

#33881 headc3a85dac8e: native host를 checkout 외부에 설치하고 GUI base·토큰 파일 읽기를 고쳤다. Node의 실제 자식 프로세스/가짜 HTTP·native peer 테스트5/5 PASS. 운영 Mozilla NativeMessagingHosts에 설치한 파일 해시는 검토한 소스와 일치하고 기존 토큰 bytes/hash 및0600권한을 보존했다. 원본 토큰은 증거에 없다.

사용자가 확장을 새로 추가했다고 알려준 뒤, Firefox70838의 자식 host86997이8935에 TCP 연결한 것을 확인했다. 검증용 다른 Firefox85089의 host85483도 같은 live lane에 연결돼 있다. 프로세스·TCP 증거는 실제 탭/본문 왕복 성공 및 어느 브라우저가 응답했는지를 증명하지 않는다.

WebSearch의 공개 MCP 직접 호출은 unregistered tool 정책으로 거절됐다. 이를 우회하지 않았으며 SearXNG 직접검색37결과와 MASC 내부 도구 검증의 경계를 유지한다.

#33867의 필수 @check·lint·dashboard typecheck와 충돌 확인 뒤 이 세션이 병합했다. merge e4c5bdc2cafe12028b091d7180d97c71602c266f를 verify/dashboard-artifact-e4c5bdc2로 고정해 [Dashboard artifact34085143698](https://github.com/jeong-sik/masc/actions/runs/34085143698)를 실행했다. 이 첫 artifact 실행은 성공했으며 이후 새 서버 커밋과 맞춘 재빌드·배포 증거는 아래에 기록했다.


## 05:15Z 대시보드 실제 복구

#33867 병합 뒤 첫 artifact를 배포했지만, 그 사이 다른 작업 주체가 서버를 fe702d71da로 갱신해 빌드 시각 기준 stale이었다. stamp를 임의 갱신하지 않고 실제 서버 커밋 fe702d71daefc1f87de1434202e4c9de17d7711c로 [34085743562](https://github.com/jeong-sik/masc/actions/runs/34085743562)를 다시 실행했다. production bundle 테스트3개 및 빌드 성공, 642개 파일을 검증했다.

05:15:17Z에 이 세션이 dashboard assets를 적용했다. index SHA256은 8e3b1f76c3619a1ea72494125e462bd1b3b4c49d72ba8fd5cf5c0870b35adb61, 실제 artifact build-stamp mtime을 보존했다. 기존 참조 가능 hashed assets와 교체 전 파일을 보존했으며 서버 재시작은 하지 않았다. 서버 HTTP index와 artifact 해시가 같고 health dashboard_status=ok다. [배포 영수증](dashboard-deploy-receipt.json), [health](health-dashboard-recovered.json), [새 화면](dashboard-after.png)을 함께 확인했다. 화면에 실행 중 Keeper14/19가 표시되고 missing/stale 배너가 없어졌다. 전체 health는 queue 때문에 degraded이며 이 UI 복구와 구별한다.

fe702d71da의 Git ancestry에 병합 커밋 기준으로 startup57ca6d5399, network367aa0822b, tool observation7729144ae7, exact quota2666e8e9fd가 포함된다. 원 PR head는 squash로 ancestry가 없어 배포 판정에 사용하지 않았다. #33877 성능 변경은05:11Z 병합돼 이 서버 커밋에는 포함되지 않는다.

## durable queue 원인과 실제 소비 증거

05:02Z pending30은 글로벌 FIFO deadlock을 뜻하지 않는다. pr-updater의 첨부 증거의 기존 incarnation1213/1214 두 건은04:50:25Z terminal ACK와 성공에 정확히 결합되고, polisher의 원래 항목도04:58:57Z terminal ACK가 있다. 새 schedule/HITL 유입은 구분했다. jazz는 timeout 뒤 다음 턴을 수행 중이고 provider 실패는 항목을 보존한다.

별도 병목은 Board 판정 완료 후 전달이다. code-reviewer 후보는02:59:55Z 판정 완료,04:48:30Z 전달로 약109분이 걸렸다. owner turn당 첫 Relevant 뒤 중단하는 정책을 제거하고 시작 시점의 completed snapshot을 FIFO로 처리하는 #33890을 작성했다. 첫 targeted34085985444는 비공개 yield helper 참조로 컴파일 실패하여 행동 테스트는 실행되지 않았다. 다른 작업 주체가 동일 공개 helper 수정ac8005c3를 반영했고, [34086843337](https://github.com/jeong-sik/masc/actions/runs/34086843337)에서 worker40/40, candidate21/21, partition15/15 총76개가 통과했다. 그 검증 시점에는 live 개선을 관측하지 않았다. 이후 짧은 실행 관측은 아래에 별도로 기록했다.

health의 oldest 값은 후보 source timestamp를 사용해 실제 큐 입장 전 지연도 포함한다. queue-owned first_admitted_at을 영속해 두 시간을 구분하는 변경은 아직 없다. 감소한 수치만으로 나머지 pending 전체의 소비와 효과 전달을 완료 처리하지 않는다.

05:12:44Z 추가 확인: geek-scout의 실제 `WebSearch` 도구 호출이 `outcome=ok`, 출력23,844자로 기록됐다. [원본 seq와 메시지](keeper-web-search-success.json)는 SearXNG 직접 질의와 별도로 Keeper 경유 성공을 증명한다. 로그가 선택 provider를 식별하지 않으므로 SearXNG에 성공 원인을 단정하지 않는다. 앞선 MCP policy 거절은 해당 운영자 도구 표면의 검증 제한이며 실제 Keeper 실패가 아니다.

증거 검토 보정: 첨부 terminal join이 직접 증명하는 pr-updater 항목은1213/1214 두 건이다. 후보 첫 사례의 판정→전달은약109분이며 첨부 표본의 최대 지연은6,654.176초(약111분)이다.


## 05:33–05:45Z 설치 바이너리 경로 변경과 재복구

다른 작업 주체가 `~/.local/bin/masc`362f55b1을 cwd`~/me`에서05:33:14Z 시작했다. unbound dashboard 해석 경로가 `~/me/assets/dashboard`로 바뀌어 indexmissing이 재발했다. 05:37Z 기존 검증 번들을 새 경로에 원자적으로 복원한 뒤, 현재 바이너리와 같은362f55b1의 [원격artifact34087501979](https://github.com/jeong-sik/masc/actions/runs/34087501979) 성공 산출물을05:44:58Z 적용했다.642파일과 HTTPindex해시를 재검증했고 dashboard=ok다. [새 배포 영수증](dashboard-relocated-deploy-receipt.json), [health](health-dashboard-relocated.json), [화면](dashboard-relocated.png). 실제 stampmtime 보존, 원래 assets 보존, 서버 재시작 없음. 전체runtime은 여전히degraded다.

소스 조사에서 release는 dashboard를 빌드하지만 설치 패키지에 배송하지 않고, 설치 binary의 unbound 실행은 cwd에서assets를 추측하는 결함을 확인했다. 이 반복 문제는 바이너리와 대시보드의 함께 배포 및 검증된 설치 바인딩으로 수정 중이다. 이번 수동 복구를 설치 경로의 근본 수정 완료로 계산하지 않는다.

#33890은 다른 작업 주체가21889e3253으로05:34Z 병합했다. 당시362f55b1 바이너리는 그 이전 커밋이므로 해당 시점의 Board drain 배포를 주장하지 않는다.

## 05:40Z 해석 불가 후보의 원본 보존

원래 gondolin-probe11행과k3think-probe19행은 schema5이고17Pending을 포함한다. 다음 정상 쓰기에서 해석 가능한 후보만 압축하면서 거부 행을 삭제하는 데이터 유실 경로를 발견했다. 먼저 두 원본을 runtime recovery 디렉터리에0600으로 보존하고 원문SHA256이 일치함을 확인했다. liveledger는 변경하지 않았다. [원문 없이 해시·경로만 담은 영수증](candidate-schema-backup-receipt.json).

[수정#33906](https://github.com/jeong-sik/masc/pull/33906) head30a3b7500c은 거부 행이 있는 ledger의 압축을 보류하고 정상 append는 유지한다. 새 schema를 수용하거나Pending을Consumed로 변경하지 않는다. [원격CI34087951889](https://github.com/jeong-sik/masc/actions/runs/34087951889)는76/76 PASS로 완료됐다. 기존 Ready/Running/Completed 파티션과17Pending의 재접수는 별도 조정이 필요하다.


## 추가 도메인 실패와 exact-head 검증

Claude의 JSON이 파싱돼도 Librarian 선택 스키마를 만족하지 않으면 기존 CLI walk는 나머지 후보를 시도하지 않았다. 오늘5건의 거부 로그, 마지막05:41:34Z claim_schema_mismatch를 [별도 원문](librarian-domain-failover-before.json)으로 보존했다. #33913은 후보 내부에서 도메인 검증을 수행하고 실패를 한 번 관측한 뒤 다음 후보로 간다. [34089352622](https://github.com/jeong-sik/masc/actions/runs/34089352622) head15b554f7a8: CLI11/11, Librarian3/3, Board exact9/9, worker40/40 총63/63 PASS. 최초7a8360300a CI는 public formatter 선언 누락으로 컴파일 실패했으며 수정 후 결과와 구분한다.

후보 원문 보존#33906의 [34087951889](https://github.com/jeong-sik/masc/actions/runs/34087951889), head30a3b7500c: candidate21/21, worker40/40, partition15/15 총76/76 PASS. 다른 작업 주체가11aa475082로05:52:45Z 병합했다. 두 CI summary는 검증 로그의 실제 suite 결과만 추출했다.

## 06:11–06:14Z 실제 서버 시작과 외부 종료

8935listener와 기존 servingPID가 없고 다른 MASC 프로세스도 없는 것을 확인해 이 세션이 설치된9c81559b를 같은 base path~/me로06:11:09Z 시작했다. PID54584, health warming·정확한root를 확인했다. 바이너리 파일 교체는 이 세션이 수행하지 않았다.9c81559b에는 병합 커밋 기준으로 Boarddrain21889e3253와 원문보존11aa475082가 모두 포함된다.

해당3분 동안 completed_snapshot_settled 로그7개가 있고 일부count2를 포함한다. 실제 후보 ledger에는pr-updater b26569ab… 전달이 기록됐다. 이것만으로 전체 pending 소비·provider 턴 완료·장기 연속성을 증명하지 않는다. 같은 창에 반복 도구 yield2개, 마지막 Execute count934가 있어 원래7번은 미해결이다.

06:14:10Z 서버가 외부SIGTERM을 수신해 종료 절차를 시작했고, 이후 PID54584의 부재를 확인했다. [프로세스 전환 관측](server-process-transition-observation.json). 종료 완료 로그나 exit code는 확보하지 못했으므로 graceful completion까지 증명하지 않는다. [종료 원문](external-sigterm-evidence.txt), [시작 영수증](server-recovery-start.json), [3분 관측](root-recovery-three-minute-observation.json). 누가 신호를 보냈는지는 미확인이다. 다른 세션의 의도적 중지와 충돌하지 않도록 사용자에게 운영 의도를 질문했고 추가 시작은 보류했다. 그 종료 뒤 관측과 이후 새 프로세스의 시작은 아래에 구분한다.

#33914 설치 배송과 #33922 자동 receipt 검증은 별도 stack이다. 형식·소스 검토와 Python 배송11/11검증은 있으나 실제 설치 binary의 원격 smoke 완료는 아직 미측정이다.9c81559b용 [artifact34089782304](https://github.com/jeong-sik/masc/actions/runs/34089782304)는 성공했고642파일을 해시 검증해 준비했지만 서버 종료 후에는 적용하지 않았다.

종료 기록 관리자 ACK는 #33910 이후 follow-up#33926(662aa5ad4d)과 HTTP#33920(daaf3bbfa8)으로 검증 중이다. 앞선 원격 실행에서 actual HTTPauth2/2와 chatHTTP9/9는 통과했지만 공통 경쟁 fixture1개가 실패했다. 실제 잠금 획득 callback으로 fixture를 고쳤다. [34091021247](https://github.com/jeong-sik/masc/actions/runs/34091021247)는 head662aa5ad4d에서 ownerless23·settlement4·purge4·heartbeat61·chatstore11 총103/103 PASS, [34091040339](https://github.com/jeong-sik/masc/actions/runs/34091040339)는 headdaaf3bbfa8에서 HTTP2·ownerless23·chatHTTP9 총34/34 PASS다. 두 PR의 별도 필수 lint 실패는 조사 중이므로 전체 필수 검증 완료로 표시하지 않는다. 원래new-keeper 종료 파일은 수정하지 않았다.


06:36:53Z 추가 재조회: 다른 작업이 시작한 PID21975 서버가06:32:35Z부터 응답하고 있다. commit17077da501, cwd는다시repo, effective_base_path는~/me, dashboardstale·overallwarming이다. 이 재시작과 바이너리 교체는 이 세션이 수행하지 않았다. 앞선PID54584의종료와 새PID의가동을 하나의 연속운영으로 계산하지 않는다. [현재 재조회](health-external-return.json). 준비한9c용artifact는 이 새커밋의 배포 증거가 아니며 적용하지 않았다.


## 최신 CLI 소비자와 CI 실행 거절

#33913의 targeted63개가 통과한15b554f7a8 뒤, 전체 @check는 별도 bin/masc_lane_cli_probe.ml의 새 failure variant 분류 누락을 발견했다.31213cbd8c20a8165fb9664e48eabc3686c9fdb9에서 해당 소비자를 수정했다. 라이브러리와 테스트 구현은63개 통과 head와 동일하다. 최신 [34092089284](https://github.com/jeong-sik/masc/actions/runs/34092089284)는 세 job 모두 steps가 없고, GitHub annotation이 계정 결제 실패 또는 spending limit 때문에 시작하지 못했다고 명시한다. 새 head의 컴파일 성공은 미검증이며 이는 실행된 코드 실패와 구분한다. 사용자에게 계정 상태 확인을 요청했고 동일 CI 재시도는 보류했다.


## 추가 소스 수정과 실행되지 않은 검증

종료 ACK의 필수 lint 실패는 lifecycle reservation 잠금 키 보존용 ignore에 설명 주석이 없는 한 항목이었다. 실제 의미를 설명하는 주석·서식을 보완해 #33926은ad2af057c9, HTTP#33920은21500fe6d6로 갱신했다. 해당 로컬 lint와 문법 검사는 통과했고 두 변경의 이전103/34 동작 검증 head와 동작 코드 차이는 없다. 새 필수 CI34092799870/34092834504는 결제·한도 때문에 zero steps로 거절됐으므로 최신 head의 원격 PASS라고 표시하지 않는다.

설치 resolver#33922의 malformed numeric fixture를3d3695a1f3에서 수정하고 원격 head를 확인했다. targeted34092646837은 동일 결제·한도 문제로 zero steps다. 이전87c20671e5의 installed16/17·Web39/39 결과와 구분하며 전체 실행은 FAIL이었다. 새 fixture의 동작 검증과 실제 release installer smoke는 아직 없다.

원래 WebFetch 실패13건을 정확한 tool 필드로 재분류했다. HTTP401 네 건·404 아홉 건인데 모두 runtime_failure로 표시됐다. [status와 원본 seq](web-fetch-upstream-status-observation.json). #33936 head120422bb9b는 외부 표현을 얻지 못한 응답을 Dependency_unavailable로 분류하고 정확한 upstream_http_status를 모델까지 보존한다. 상태별 안내는401/403의 인증·권한,404의 부재 또는 비공개 불확실성,410·429·5xx를 구별한다. 자동 재시도와 계정 인증정보 추가는 없다. 여섯 handler→bridge 시나리오를 작성하고 문법·prompt 일치·diff·variant 정적 검사를 통과했지만 동작 실행은 미검증이다. 이 PR의 필수 검사34093512926도 세 job 모두 zero steps이며 계정 결제·한도 거절 annotation을 확인했다. [RFC9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.5)에 맞춰404를 삭제 확정으로 안내하지 않는다.

06:36:00Z WebSearch 및06:36:37Z WebFetch의 실제 성공도 추가 관측했다. 두 성공은 원래 실패했던 URL들에 대한 재조회가 아니므로 접근 문제가 해결됐다는 근거로 사용하지 않는다.

[추가 health 관측](health-followup-observation.json)은 같은17077da501 바이너리의 started_at이06:59:41Z임을 기록한다. 이 세션이 시작하거나 바이너리를 교체하지 않았으며 앞선06:32 프로세스와 연속 uptime으로 계산하지 않는다. 이 영수증은 overall warming·queue warming·dashboard stale을 기록한다. counts_complete=false이므로 표시된 pending_count0을 빈 큐의 증거로 사용하지 않는다. 상태는 영수증의 관측 시각에 한정한다.


## 큐 시간의 의미 수정

#33938 head827803c9827d2d39a5de57197d702fcec3a1c32c는 pending의 source timestamp를 실제 큐 체류 시간으로 판단하던 두 경로(keeper_event_queue health, reaction-ledger)를 수정한다. source age는 계속 표시하고, 실제 체류 시간은 typed Unknown·JSON null과 사유로 표시한다. runnable backlog는 warning/backlogged로 드러나며 독립적인 소유자·격리·저장소 오류는 유지한다. 원래 큐 drain 수정이나 전체 큐 소비 완료와는 다른 진단 정확성 수정이다.

첫 독립 리뷰가 reaction-ledger의 중복 오판정 경로를 찾았고 수정 후 재검토에서 차단 사항이 없었다. 문법·소스 검사는 통과했지만 동작 테스트·실제 화면·배포는 미검증이다. 영속 queue/state codec은 변경하지 않았다. queue-summary fixture는 raw snapshot bytes 보존, reaction-ledger fixture는 파싱된 JSON 상태 보존을 검사하도록 작성됐으며 아직 실행하지 않았다.

이 변경으로 쓰지 않게 되는 health.durable_queue_stale_sec가 운영 runtime.toml42행에 한 건 있다. 배포 시 정상 설정 경로로 해당 값과 운영 의도를 정리해야 한다. 이 세션은 운영 설정을 변경하지 않았다. 현재 파서는 소유 namespace에서 제외된 값을 적용하지 않으므로 제거 누락이 반드시 startup failure를 낸다고 주장하지 않는다.


## 재개 인과관계 조사와 큐 원문 보존 선행 수정

반복 도구 감지는 session history 전체의 matched tool call을 seed한다. direct operation의 영속 ID는 이미 있지만 claimed operation에서 실행 인자로 전달되지 않는다. autonomous selection은 payload-only Woken으로 축약되고, admitted_revision과 source_snapshot_ref는 defer/reprioritize 중 바뀐다. HITL은 여러 turn의 같은 요청을 기존 grant에 접으며, Ask/Delegate/Composition에도 재시작 뒤 부모 scope를 복원할 공통 영속 연결이 없다. 이 경계를 명시한 [소스 조사 문서](https://github.com/jeong-sik/masc/blob/5e1f4673d405499248fb7209c523040d72a55902/docs/design/keeper-repetition-scope-boundaries.md)는 설계·후속 검증 요건이며 반복 문제 해결 증거가 아니다.

조사 중 queue loader가 문법상 유효하지만 schema/domain을 해석할 수 없는 primary를 빈 상태로 반환하고, 다음 쓰기에서 pending과 disposition 증거를 대체할 수 있음을 확인했다. [#33947](https://github.com/jeong-sik/masc/pull/33947) head5e1f4673d4는 present-invalid를 Error로 반환해 snapshot·WAL을 유지한다. 실제 primary 부재에 한해서만 기존 WAL-only 복원을 유지한다. 별도 캐시 경합도 수정해, 읽은 바이트 전후의 동일한 파일 식별자에만 상태를 연결하고 쓰기 후 첫 읽기는 재파싱한다. 이후 변경 없는 읽기는 다시 캐시를 사용한다. 추가 파싱의 운영 성능 영향은 미측정이다.

정상 owner 등록·작업 접수, malformed orphan의 Demand_unknown, 실제 completion WAL 보존·primary 부재 뒤 sibling/중복 처리 복원, dangling primary, decode 직후 파일 교체 경합 시나리오를 작성했다. 문법5파일·diff·variant 정적 검사 및 독립 재검토는 통과했다. 동작 테스트·빌드·배포는 아직 없으며 운영 큐를 변경하지 않았다. 두 원본 날짜의 system 로그를 새로 조회한 결과 fail-open 메시지는0건이었다. 이 수정은 source에서 발견한 데이터 보존 결함이며 원래 로그 카운트를 늘리거나 새 유실 사고를 관측했다고 주장하지 않는다.


## 07:28–07:31Z 원격 검증 재개

#33947의 PR check34095606842에서 lint·dashboard 타입 검사 SUCCESS와 실제 OCaml job 실행을 확인했다. GitHub 계정 문제의 해결 원인은 확인하지 않았지만, CI가 다시 실행 가능한 상태라는 직접 증거다. 과거 zero-step 거절 기록은 해당 attempt의 이력으로 유지한다.

이 세션은 queue/state/durable-demand/reaction-ledger [34095821638](https://github.com/jeong-sik/masc/actions/runs/34095821638), WebFetch/bridge [34095824585](https://github.com/jeong-sik/masc/actions/runs/34095824585)를 각5e1f4673d4/120422bb9b에서 새로 dispatch했다. 설치 resolver는3d3695a1f3의 [34095776029](https://github.com/jeong-sik/masc/actions/runs/34095776029)가 실제 초기 단계를 실행 중이다. 모두 동작 테스트 결과는 아직 pending이다.

기존#33936/#33938 필수 검사34093512926/34094034436은 다른 작업 주체가 이미 attempt2로 재실행했다. 이 세션의 추가 재실행 요청은 already running으로 거절돼 중복 실행되지 않았다. 해당 attempt2는 정확한 원 head에서 lint·dashboard SUCCESS, @check 진행 중임을 재확인했다. ACK와 CLI의 기존 필수 검사도 실제 실행 중이며 중복 재실행하지 않았다.


## 07:34–08:02Z 실제 테스트 완료와 병합

큐 원문 보존의 exact5e1f4673d4 [34095821638](https://github.com/jeong-sik/masc/actions/runs/34095821638)은 event-queue 시나리오 실행 PASS와 state31/31·durable-demand6/6·reaction-ledger28/28 PASS다. 번호가 있는65개와 별도 event-queue 실행으로 표현하며, 모놀리식 실행의 assertion 수를 임의의 테스트 수로 바꾸지 않는다. [결과 요약](queue-primary-retention-ci-summary.txt). 필수 @check·lint·dashboard도 모두 PASS했고 충돌·변경 요청이 없음을 확인한 뒤 이 세션이 #33947을07:55:23Z에d5e0685b38로 squash 병합했다.

WebFetch의 exact120422bb9b [34095824585](https://github.com/jeong-sik/masc/actions/runs/34095824585)은14/14·bridge20/20 총34 PASS, 필수 검사도 PASS다. [결과 요약](web-fetch-upstream-ci-summary.txt). 다른 작업 주체가07:39:38Z에#33936을c7fe4f67a1로 병합했다. 이 세션의 병합으로 표시하지 않는다.

ACK의 exact ad2af057c9 [34095886814](https://github.com/jeong-sik/masc/actions/runs/34095886814)는103/103 PASS, exact21500fe6d6 [34095899962](https://github.com/jeong-sik/masc/actions/runs/34095899962)는34/34 PASS다. 이후 외부 병합은 각각cdae490f8774와8ac44f2af180이다. HTTP 최종head81c9f393967e는 관련 파일이 동일하고 필수 검사가 통과했지만21500의 targeted를81c9 exact 결과로 이동시키지 않는다. 이 08:01Z 관측 시점에는 실제 운영 ACK를 수행하지 않았다. 08:27Z 적용 결과는 아래 후속 절에 기록했다.

설치 resolver의3d3695a1f3 [34095776029](https://github.com/jeong-sik/masc/actions/runs/34095776029)는 installed17/17·Web39/39 PASS다. 외부에서 관련 파일이 동일한8a67c07c99를c328dbe8로 병합하고 feature branch를 삭제했다. 이 세션은 branch를 복구하지 않고 검증된3d를 가리키는 verify/installed-dashboard-3d3695에서 [Release34098251245](https://github.com/jeong-sik/masc/actions/runs/34098251245)를 dispatch했다. non-tag workflow_dispatch라 공개 release 단계는 실행 대상이 아니다. Linux x64/ARM64 실제 설치 smoke는 SUCCESS다. 당시 macOS ARM64는 진행 중이었다. 이후 실제 SUCCESS는08:31Z 절과 통합 증거에 기록했다. 운영 설치·재시작은 하지 않았다.

반복 scope 기반 [#33950](https://github.com/jeong-sik/masc/pull/33950) head72deb19a38는 당시 별도 draft였다. constructor·decoder의 공통 검증, Fresh 멱등성, A/B/A 보존, unknown Resume 거부, target 복원 충돌을 구현했고 실제 checkpoint codec과 기존 detector를 잇는6개 대상 [34098406950](https://github.com/jeong-sik/masc/actions/runs/34098406950)에서6/6 PASS를 확인했다. 이후 main 충돌을 해결한bdc8852ccc는 구현·인터페이스·테스트·stanza가 동일하며 당시 필수 PR check34099857999가 진행 중이었으며 이후 PASS·병합 결과는 아래에 기록했다. runtime caller·영속 자식-parent linkage·official-client 저장 연결은 아직 없으므로 원래7번을 해결로 표시하지 않는다.

08:01:52Z health 재조회는 binary1f7ec8a587·started07:56:05Z·base~/me·masc_root~/me/.masc·dashboardstale·overalldegraded, pending10/counts_complete=true를 반환했다. 이 서버 시작과 바이너리 교체는 이 세션이 수행하지 않았다. 이 커밋은 최근 병합된 변경들의 운영 반영 증거가 아니다.


### 08:20Z checkpoint 저장 경계와 설치 검증 후속

[#33953](https://github.com/jeong-sik/masc/pull/33953) exact e19fd32c2c는 최종 메시지와 turn_count가 같더라도 Context·설정·도구·usage 등이 달라졌으면 새 체크포인트를 저장한다. 기존 코드는 이전 값을 재사용해 Context-only 관측이 유실될 수 있었다. 메시지 본문은 재직렬화하지 않으며, 나머지 replay 상태는 소유 codec으로 비교한다. 실제 디스크 저장·복원 시나리오를 추가했고 독립 리뷰에서 차단할 정확성 문제는 없었다. metadata 비교 비용은 크기에 비례하며 성능은 미측정이다. [targeted34100025761](https://github.com/jeong-sik/masc/actions/runs/34100025761)은 당시 진행 중이었다. 이후21/21 PASS·병합 결과는08:31Z 절에 있으며 운영 배포나 반복 문제 전체 해결을 뜻하지 않는다.

Release34098251245의 Linux x64와 ARM64는 checkout 밖에서 설치 서버를 실행해 정확한 commit·index와 참조 자산3개를 확인하고, index 손상·receipt 누락 시503을 확인했다. 다운로드한 x64 artifact10009693579도 binary·receipt·dashboard642개 파일의 해시/크기를 독립 검증했다. [패키지 검증](release-linux-x64-verification.json). 이08:20Z 관측 때는 macOS 성공이 확인되지 않았고, 이후08:31Z 절에 실제 성공 결과를 추가했다. 이 검증용3d 바이너리는 운영 서버에 설치하지 않았다.

CLI 도메인 failover #33913은 외부 최종 head cfc1f173d8의 필수 검사 SUCCESS 후d16c83de17로 병합됐다. 기존63개 대상 검증은15b554f7a8의 결과이며 최종 head 전체 테스트로 재표기하지 않는다.


### 08:31Z 실제 ACK·대시보드 복구와 코드 병합

운영6db68b4bea에서 GET preview를 새로 읽고, 부재 ACK endpoint에 정확한 revision4/backlog4459로 요청했다. 서버가 모든 권위 있는 guard를 통과시킨 뒤08:27:04Z acknowledged를 반환했다. 독립 GET은 revision5의 operator_absence_acknowledged를 반환하며 이전 finalization·cleanup_intent·owned_task_ids·revision·updated_at을 보존한다. 기존 dashboard Admin 자격증명의 actor는dashboard이며 사람이 직접 API를 누른 것으로 표시하지 않는다. [실제 ACK 증거](absence-ack-live-proof.json). 재시작은 수행하지 않았다.

[#33950](https://github.com/jeong-sik/masc/pull/33950)은 충돌을 해결한bdc8852ccc에서 필수 검사 모두 통과 후 이 세션이08:28:23Z cf63fd467d로 병합했다. 기반6개 동작 검증은 코드가 동일한72deb19a38의 결과다. [#33953](https://github.com/jeong-sik/masc/pull/33953)은 e19fd32c2c의21/21 동작 테스트와 필수 검사 모두 PASS 후 이 세션이08:30:51Z 8685db2478로 병합했다. 둘 다 운영6db 바이너리에 포함됐다는 증거는 없고, 원래 반복 문제의 caller 연결은 아직 남아 있다. [반복 실측 후속](repetition-live-followup.json)의08:03:36Z Execute count959도 실패한 독립 작업959개라는 뜻이 아니다.

#33938 exact827803의 [34099718437](https://github.com/jeong-sik/masc/actions/runs/34099718437)은 health6·reaction28·bootstrap85·runtime TOML37=156개 번호 있는 테스트와 별도 queue 실행, terminal reason matrix147200건 mismatch0을 통과했다. 대시보드 UI 동작이나 실제 queue residence를 새로 측정한 결과는 아니다.

Release34098251245의 macOS 실제 job도 SUCCESS이며 공개 release job은 SKIPPED다. [3개 플랫폼 설치 검증](installed-release-ci-proof.json). 별도로 운영 서버의 source commit6db68b4bea와 정확히 같은 [Dashboard artifact34100510195](https://github.com/jeong-sik/masc/actions/runs/34100510195)를 빌드하고, archive/index/642파일을 검증해 백업 후08:29:52Z 적용했다. HTTP index SHA a0d3037ff9d3e0e6d8b09219d54aeb9691ebee1fe2a75d076946a30f14de48c6과 health dashboard_surface.ok를 확인했다. [적용 영수증](dashboard-6db-deployment-receipt.json). 바이너리 설치·재시작은 없었으며 운영은 여전히 checkout 자산을 참조한다.

실제 브라우저에서도08:30:43Z MASC Overview가 렌더됐고 실행 중 Keeper13/19가 표시됐다. 캡처 구간 page error0·HTTP4xx/5xx0을 관측했다. [화면](dashboard-6db-dashboard.png) · [브라우저 관측](dashboard-6db-browser-proof.json). 전체 런타임은 warning이며 probe와 paused Keeper 항목이 남아 있어 대시보드 자산 정상화와 fleet 전체 정상화를 구별한다.

ACK 이후08:32:41Z까지5분37초의 로그에서 해당 new-keeper shutdown recovery 오류0건을 확인했다. [후속 로그 관측](absence-ack-post-apply-observation.json). 같은 프로세스의 짧은 구간이며 재시작 성공 증거로 확대하지 않는다.


## 09:40Z 검증 갱신: 실제 브라우저 왕복과 재시작 뒤 ACK

[실측 증거](runtime-readonly-refresh-20260907T0940Z.json)는 읽기 전용 관측이다. 09:40:03Z live 확장 route가 탭 9개와 본문 515자를 반환했다. host 연결 여부만 확인하던 단계를 넘어 실제 tabs.list → page.read 왕복을 측정했다. 본문·URL·제목·자격증명 값은 저장하지 않았다. 응답한 정확한 host PID는 프로토콜에 없으므로 두 Firefox의 구분까지 증명하지 않는다.

[재시작 이후 증거](absence-ack-after-external-restart.json)에서 외부 08:37:36Z 시작 후 09:06:48Z에도 ACK revision5가 유지되고, 해당 shutdown recovery 오류는 0건이다. 09:39:25Z 파일 재조회도 ACK 상태를 확인했다. 이 세션의 재시작은 없었다.

09:35Z 실행 바이너리는 embedded a4e6603311, 대시보드는 다시 stale/unbound다. 09:37Z 제공 index·디스크 index·health index hash는 일치하지만, 실행 health와 디스크 바이너리 hash는 다르다. 08:30Z 자산 복구 성공은 당시 관측이며 현재 일치하는 설치 릴리스의 증거로 확대하지 않는다.

[직접 scope CI](direct-repetition-ci-summary.json)는 exact 97e3c224ad의 125개 중124 PASS/1 FAIL이다. #33967은 외부 세션이 필수 검사 후 병합했다. 새 scope/host 테스트는 통과했고, 실패는 Antigravity가 spawn 전 입력을 전달했다고 보고하는 기존 source 불일치다. 별도 baseline 실행은 하지 않았다. #33982는 전체 stdin 쓰기·EOF 후에만 보고하도록 고치며, #33984는 큐 식별자 보존 및 불확실한 rename 이후 동기화 재확인을 보강한다. 두 후속의 원격 동작 검증과 자율 실행 연결은 아직 완료 증거가 아니다.


09:43:44Z에 추가로 [후속 로그 구간](runtime-pattern-followup-0940.json)을 동결했다. 외부 시작08:37:36Z 이후22,486행(INFO20,726/WARN1,483/ERROR277)에서 원래 exact-tool 반복 경고는11건이 남았다. 선택한 기존 누락 tool-results·중첩 checkpoint·composition 증거 실패·new-keeper 종료 복구·browser lane 부재·Librarian 실패·Claude quota 문자열은0건이다. 각 경로의 실제 실행 횟수를 측정하지 않았으므로0건을 해결이나 통제된 전후 개선율로 해석하지 않는다.


큐 binding의 [원격77/77 PASS 증거](queue-binding-ci-summary.json)는 b9f30528ff의 queue36/scope11/cancellation7/source-terminal11/transfer12다. 실제 After_rename 실패 후 재시도의 동기화 확인 테스트도 통과했다. 필수 lint가 지적한 새 ignore 호출 설명은9f79ffbb72에서 주석1줄로 보완했으며, 그 후속 head에서77개를 다시 실행했다고 주장하지 않는다. 자율 실행 연결은 별도 작업이다.
