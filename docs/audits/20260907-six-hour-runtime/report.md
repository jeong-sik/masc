# MASC 최근 6시간 집중 개선 감사

**분석 창:** 2026-09-07 05:58:23–11:58:23 KST (UTC 2026-09-06T20:58:23Z–2026-09-07T02:58:23Z).

**범위:** ~/me/.masc/logs/system_log_2026-09-06.jsonl, system_log_2026-09-07.jsonl의 timestamp 기준 102,600행. INFO 92,944 / WARN 8,764 / ERROR 892. 다른 .masc 파일 전체의 모든 문장을 전수 집계했다는 뜻은 아니다. 로그는 원본 파일/행/seq를 보존해 window.jsonl로 동결했다.

**판정:** 아래 count는 대표 로그 이벤트 수이며 서로 독립인 사고 수가 아니다. provider 실패→pipeline 실패→Keeper 실패는 중첩한다. 최종 행은 health의 별도 live acceptance 상태다.

**실행 식별:** 첫 health binary b90d5f6182, 검토 source 8b804d8d5b. 다른 운영 작업이 진행 중이며 중간 재조회 binary는 8b804d8d5b. 본 세션이 배포했다고 주장하지 않는다.

| # | 개선 대상 | 대표 관측 | 진행 |
|---|---|---:|---|
| 1 | Claude quota 반복과 잘못된 effect fence | 1698 | diagnostic-fix |
| 2 | GLM 요청 제한 | 617 | investigate |
| 3 | Librarian exact 실패와 주간 한도 | 48 | external+investigate |
| 4 | DeepSeek tool-call 응답 누락 | 224 | code-fix |
| 5 | 중첩 tool-cycle checkpoint 저장 실패 | 21 | related-code-fix |
| 6 | 복합 도구는 성공하지만 실행 증거 저장 실패 | 5 | code-fix |
| 7 | 재개 후 반복 도구 루프 | 231 | investigate |
| 8 | Provider 연결 장애 | 51 | investigate |
| 9 | 일반 문장의 @check·lint를 ID 오류로 기록 | 362 | code-fix |
| 10 | MCP 인증 누락·Dashboard token 불일치 | 373 | client-repair |
| 11 | 삭제된 new-keeper의 종료 복구 반복 | 6 | data-reconciliation |
| 12 | Board candidate ledger schema 불일치 | 12 | data-reconciliation |
| 13 | Dashboard snapshot 장시간 갱신 | 111 | performance |
| 14 | Dashboard build-stamp 누락 | 5 | artifact-rebuild |
| 15 | microVM sweep가 전체 Keeper 부팅을 막음 | 68 | code-fix |
| 16 | microsandbox가 요구 격리 보장을 표현 못함 | 5 | backend-capability |
| 17 | 브라우저 live lane 미연결 | 12 | operator-connection |
| 18 | Discord 삭제·권한 없는 channel 바인딩 | 28 | external-binding |
| 19 | WebSearch 전 provider 실패와 WebFetch HTTP 오류 | 19 | external+client |
| 20 | 실행 가능한 owner의 durable queue 정체 | health: pending33 oldest4893s at initial capture | live-acceptance |

## 항목별 증거와 다음 완료 조건

### 1. Claude quota 반복과 잘못된 effect fence

- 조치: PR #33839: typed API error diagnostic frame를 실제 모델 응답과 분리. 실제 text/tool effect는 보존. 쿼터 자체와 exact-lane 재시도 전략은 별도 잔여.
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

- 조치: 48 failure events 중 46에 weekly quota. 새 스냅샷 commit 성공까지 확인; 실패했다고 기존 메모리를 지우면 안 됨.
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

- 조치: yield 자체는 보호 동작. 동일 Execute/surface/context 호출을 재개 뒤 반복하는 목적·툴 결과·후속 checkpoint를 함께 검증; 임의 횟수 cap 추가하지 않음.
- 관련 코드/경계: `lib/keeper/keeper_agent_run.ml`
- 최초 증거: `2026-09-06T21:00:25Z` / seq `25984123` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:266643`
> yielding repeated exact tool loop tool=Execute count=6
- 마지막 증거: `2026-09-07T02:58:09Z` / seq `26386295` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:43159`

### 8. Provider 연결 장애

- 조치: IPv6 connect timeout, DNS/reset을 구분. 아래 별도 HTTP4/HTTP6 read-only 측정은 새로운 관측이며 과거 원인 확정 아님.
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

- 조치: 인증 거절은 정상. 오래된 client credential의 주체를 확인하고 해당 client에서 갱신; 서버 인증 완화로 해결하지 않음.
- 관련 코드/경계: `lib/server/server_mcp_transport_http_respond.ml:149; lib/server/server_auth.ml`
- 집계 주의: MCP347 + dashboard26
- 최초 증거: `2026-09-06T21:02:53Z` / seq `25984474` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:266994`
> [silent:dashboard_actor_fallback] outcome=error token_hash_prefix=41ba75a6 err_kind=token_mismatch actor_hint=dashboard err=[AuthError] Invalid token: Token mismatch — request actor hint ignored. Remediation: clear the browser's stored dashboard token (localStorage masc_dashboard_token) or delete .masc/auth/dashboard.token so a fresh token is minted on the next dashboard load.
- 마지막 증거: `2026-09-07T02:09:56Z` / seq `26277375` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:34239`


### 11. 삭제된 new-keeper의 종료 복구 반복

- 조치: operation은 retain_meta인데 실제 owner/meta 부재. Remove_meta용 기존 성공 경로를 재사용하면 계약 위반. 명시적인 retired-owner reconciliation 절차 필요.
- 관련 코드/경계: `lib/keeper/keeper_shutdown_finalize.ml`
- 최초 증거: `2026-09-06T23:26:03Z` / seq `26080010` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312530`
> shutdown recovery failed keeper=new-keeper operation=shutdown-15ad5365-6cf0-4880-b6d5-6b57e26441a7 error=Keeper shutdown admission release failed in operation shutdown-15ad5365-6cf0-4880-b6d5-6b57e26441a7: Keeper owner not found: new-keeper
- 마지막 증거: `2026-09-07T02:43:56Z` / seq `26382595` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39459`

### 12. Board candidate ledger schema 불일치

- 조치: gondolin-probe 11행, k3think-probe19행 원본 보존. 활성 owner/미소비 의도를 판정한 뒤 명시적 quarantine; 호환 파서 추가나 무단 삭제하지 않음.
- 관련 코드/경계: `lib/keeper/keeper_board_attention_candidate.ml`
- 집계 주의: 2 files across 6 boots; not 12 distinct corrupted files
- 최초 증거: `2026-09-06T23:26:05Z` / seq `26080097` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312617`
> candidate ledger /Users/dancer/me/.masc/board_attention_candidates/gondolin-probe.jsonl: skipped 11 unreadable row(s); first is line 1: board attention candidate fields must be exactly [schema_version,candidate_id,keeper_name,signal,keeper_context,recorded_at,status], got [schema_version,candidate_id,keeper_name,signal,judgment_request,recorded_at,status]
- 마지막 증거: `2026-09-07T02:43:58Z` / seq `26382707` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39571`

### 13. Dashboard snapshot 장시간 갱신

- 조치: 실측 구간의 component별 시간·할당량으로 좁혀야 함. TTL=0 자체만 보고 cache를 강제로 늘리면 fresh 상태가 달라짐.
- 관련 코드/경계: `lib/dashboard/dashboard_snapshot.ml`
- 집계 주의: shell_light70 among111; other18 slow render not added
- 최초 증거: `2026-09-06T23:26:05Z` / seq `26080100` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:312620`
> dashboard_snapshot heavy refresh: component=activity_defaults elapsed_s=1.627 allocated_mb=664.8 ttl_s=10
- 마지막 증거: `2026-09-07T02:43:59Z` / seq `26382712` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39576`

### 14. Dashboard build-stamp 누락

- 조치: health와 실제 browser에서 missing 확인. 정식 bundle artifact 빌드·배포 provenance가 필요. 이 세션은 constitution의 로컬 빌드 금지를 유지.
- 관련 코드/경계: `scripts/build-dashboard-if-needed.sh`
- 최초 증거: `2026-09-07T00:47:21Z` / seq `26156709` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:13573`
> bundle build-stamp unavailable at /Users/dancer/me/workspace/yousleepwhen/masc/assets/dashboard/.build-stamp — dashboard assets may be missing or unbuilt; inspect /health dashboard_surface.recovery
- 마지막 증거: `2026-09-07T02:43:50Z` / seq `26382542` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39406`

### 15. microVM sweep가 전체 Keeper 부팅을 막음

- 조치: PR #33846: Keeper 필수 startup barrier에서 분리하되 기존 microVM lifecycle lock으로 listing→delete 전부 보호. 같은 guest 이름 재생성 경합을 독립 리뷰에서 발견.
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

- 조치: operator 브라우저 extension과 host의 연결 완료가 필요. 진단용 headless screenshot은 Keeper live lane 연결의 증거가 아님.
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

- 조치: 검색 endpoint curl7 + Ollama429. fetch401/404는 주소/인증 원인도 존재. 대체 검색 provider readiness와 URL 정확성을 독립 검증.
- 관련 코드/경계: `lib/tool_misc_web_search.ml`
- 집계 주의: search6 + fetch13; one query may fail two providers
- 최초 증거: `2026-09-06T21:02:53Z` / seq `25984475` / `/Users/dancer/me/.masc/logs/system_log_2026-09-06.jsonl:266995`
> tool masc_web_fetch returned error result: HTTP 404
- 마지막 증거: `2026-09-07T02:43:15Z` / seq `26332377` / `/Users/dancer/me/.masc/logs/system_log_2026-09-07.jsonl:39241`

### 20. 실행 가능한 owner의 durable queue 정체

- 조치: 운영 목표: 실제 FIFO 소비·다음 턴 성공·outbox 결과 수신. queued 감소만으로 소비 성공 판정하지 않음. 현재 해결 미확인.
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

## 네트워크 수정 검토 결과

http_client 및 exact_output_measurement_transport가 getaddrinfo 첫 주소만 고르는 점은 source로 확인했다. 단순 순차 fallback을 넣으면 설치 Eio_posix에서 실패한 connect socket이 caller switch에 남아 cache 종료까지 쌓일 수 있다. 요청 replay 없이 연결만 대체하고, 실패 socket 수명을 정리하는 설계/측정이 함께 필요해 이 변경은 적용하지 않았다. IPv6 blackhole 대기시간 문제도 별도이다.

## 다섯 번째 수정

[PR #33846](https://github.com/jeong-sik/masc/pull/33846), head cd7c2ffe3e. microVM 정리를 전체 Keeper 준비 단계에서 분리하고 같은 lifecycle lock으로 목록 조회부터 삭제까지 보호한다. fake CLI를 사용한 실제 boot 진입 대기, live owner 보존, 실패 후 lock 재사용, switch 소유 취소 테스트를 추가했다. 보호된 sweep 자체의 취소는 해당 pass가 끝날 때까지 지연된다. 성공적인 VM 생성은 이 테스트가 검증하지 않는다. [targeted CI 34079859096](https://github.com/jeong-sik/masc/actions/runs/34079859096) 결과 확인 전.

두 원본 system JSONL 파일을 전체 스캔한 결과 JSON 파싱 실패0행, timestamp 누락0행이었다. CI summary 파일은 해당 실행 로그의 판정 줄을 추출하고 후행 공백만 정리했다.

## 새 운영 재조회 (서로 길이가 다른 관측 창)

03:32Z 재조회 binary148a773ff8의 Git ancestry에는 #33829/#33833/#33834/#33839 네 변경이 실제 포함된다. 이 배포와 merge는 다른 작업 주체가 진행했으며 본 세션이 실행하지 않았다. 03:22:10Z–03:32:26Z 약10분, 4,391행에서 insufficient-tool-message cycle error0, overlapping checkpoint0, composition evidence failure0, check·lint warning0, Claude quota13이 관측됐다. 전체6시간 대비 단순 감소율이나 완치율로 비교할 수 없다. 해당 경로가 실제 충분히 실행됐는지와 concurrent 변경 영향이 남는다.

가장 최근 health는 runnable pending61, oldest2292초(약38분)이며 여전히 stalled/degraded이다. 직전 관측 pending115/oldest6471초에서 줄었지만 감소만으로 FIFO 소비·효과 전달 성공을 판정하지 않는다. dashboard stamp는 여전히 missing. 최신 health-final.json과 post-deployment-observation.json 참고.
