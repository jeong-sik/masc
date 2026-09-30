# 주간 감사 발견 목록 (2026-09-22 ~ 09-29)

기준 `origin/main` 91c24caa05. 요약·기능 표·결정 목록은 [주간 변경 감사와 기능 표](2026-09-29-week-audit-and-feature-matrix.md)에 있다.
id 접두어: `RT-` Runtime·Lane·Schedule, `MM-` Memory·Librarian·Skills·Context, `DM-` Board·Task·Goal·HITL·Candle·Play, `TU-` TUI·대시보드.
"들어온 커밋"이 8439213b70 이면 이 감사용 clone 의 가장 오래된 커밋이라 실제 출처는 그 이전이다.
152는 표 행 수이며 묶음 ID도 한 행으로 센다. MM-W6~W10은 보고된 묶음으로, 보존된 primary file:line 위치가 없어 확인된 개별 소스 결함으로 세지 않는다.

## Runtime · Lane · Schedule · 토큰

| id | sev | class | file:line | 만든 PR | 한 줄 결함 | 확신 |
|---|---|---|---|---|---|---|
| RT-R1 | P1 | N-of-M · open loop | `lib/runtime/runtime_provider_usage_read.ml:73-81`, `lib/keeper/keeper_codex_runtime.ml:296-310,503-511`, `lib/fusion/fusion_official_client.ml:357-360` | #38671 (gap: #38975·#39810 가 다른 경로만 고침) | Codex 사용량 거절 뒤 읽어 온 리셋 시각을 쉼에 안 써서, 다 쓴 계정을 15분마다 다시 부른다 | High |
| RT-S1 | P1 | open loop · 과거 이력 판정 | `lib/keeper/keeper_reaction_ledger.ml:1487-1495`, `lib/keeper/keeper_registry_event_queue.ml:871-883` | #39189·#39521 | `Turn_started` 행 하나로 "이미 가져간 wake"로 판정해서, ACK 없이 끝난 턴마다 schedule pending 이 1개씩 늘고 취소도 못 거둔다 | High |
| RT-C1 | P1 | waste · N-of-M | `lib/keeper/keeper_codex_runtime.ml:1017-1022`, `lib/keeper/keeper_turn_driver.ml:2793` | #38822 | Codex resume 이 block 단위 held 없이 carrier 통째로 비교해서, 매 턴 ~170KB 를 다시 보낸다(09-29 243MB) | High · **열린 PR #39972 가 다룸** |
| RT-C2 | P1 | correctness | `lib/runtime/runtime_codex_app_server.ml:944-945,154-159`, `lib/keeper/keeper_codex_runtime.ml:1504-1536` | #38822 | Codex 턴 중간 compaction 뒤에도 held 를 유지해서, 바뀌지 않은 맥락이 빠진 채 resume 한다 | 메커니즘 High · 빈도 Medium |
| RT-C3 | P1 | waste | `lib/keeper/keeper_run_tools_hooks.ml:971-996`, `lib/keeper/keeper_memory_os_recall.ml:21-27` | #38986 | recall 과 Librarian index 가 한 block 이라 fact 하나만 바뀌어도 90-377KB 를 다시 보낸다 | Medium-High |
| RT-A1 | P1 | 두 검증기 불일치 | `lib/runtime/runtime_account_removal_setup.ml:63-86` vs `:88-106`, `lib/runtime/runtime.ml:3673-3681` | #39634·#39659 | 계정 제거 미리보기는 Fusion 자리·필수 lane 을 안 봐서 "removable" 인데 실제 저장은 400 으로 거절된다 | High (live 는 아직 해당 없음) |
| RT-A2 | P1 (잠복) | 회귀 | `lib/server/server_workspace_memory_curator.ml:149-156` | #39858 (vs #39622) | writer·TUI·projection 은 curator CLI 슬롯을 받는데 실행은 lane 전체를 거절한다 | High (live lane 미선언) |
| RT-R2 | P1 (설계) | waste | `lib/keeper/keeper_turn_driver.ml:708-718,986-988` | RFC-provider-path-rest Phase 2 미설계 | 제공자가 리셋 시각을 말한 후보도 걷는 도중 매번 부른다 | 동작 High · 판정 Medium |
| RT-R3 | P2 | SSOT · sticky | `lib/runtime/runtime_candidate_backpressure_state.ml:44-50`, `lib/keeper/keeper_turn_driver.ml:213-216`, `lib/runtime/runtime_exact_lane_backpressure.ml:25-52` | 주 이전 명세 + #39077 | 힌트 없는 429 는 Keeper 에선 성공 전까지, exact lane 에선 60초만 쉰다 | Medium |
| RT-R4 | P2 | N-of-M | `lib/browser_stagehand_model.ml:241-247,642-676` | #38708 (#39077 미적용) | Stagehand exact lane 만 429 기억(order/observe)을 안 쓴다 | High |
| RT-R5 | P2 | wiring | `lib/runtime/runtime_provider_usage_read.ml:314-339` | #39144 | `refresh-s` 반복 읽기 대상이 부팅 때 고정된다 | High |
| RT-R6 | P2 (설계) | open loop · 재시작 | `lib/runtime/runtime_quota_window.ml` 전체(프로세스 로컬) | 명세 | 재시작마다 다 쓴 계정을 한 번씩 다시 부른다(09-29 부팅 20회) | High |
| RT-R7 | P2 | legacy residue | `lib/runtime/runtime.ml:1315-1329` | #39020 | "used to ... the old comment here" 이력 문장 | High |
| RT-S2 | P2 | wiring | `lib/keeper/keeper_registry_event_queue.ml:720-728` | 주 이전 (#39189 가 새 소비자) | 취소 commit 뒤 registry mirror·broadcast 가 안 나간다 | 코드 High · 영향 Low |
| RT-S3 | P2 | 무한 증가 | `lib/keeper/keeper_reaction_ledger.ml:168-230,658-663` | #38765 | 회차 영수증 파일이 끝난 occurrence 마다 쌓인다(pr-updater 888개) | High |
| RT-S4 | P2 | magic number gate | `lib/keeper/keeper_owner.ml:438,1286` | #38963 | `autonomous_deferral_debt_cap = 3` | Medium |
| RT-S5 | P2 | legacy residue | `lib/tool_schedule.ml:749-768` | #39451 | recurrence 생략 호환 경로 (제거는 이슈 #39511 OPEN) | High |
| RT-S6 | P2 | stub | `lib/server/server_schedule_consumers.ml:398-417` | 주 이전 | `resolve_keeper_wake_target` 가 항상 입력을 돌려준다 | High |
| RT-S7 | P2 | unwired | `lib/keeper/keeper_registry_event_queue.ml:860-862` | #39521 | `cancel_scheduled_wakes_result` 가 테스트에서만 불린다 | High |
| RT-S8 | P2 | 무한 증가 | `lib/schedule_runner.ml:135` | 주 이전 | `schedules/signals` 하루 1.2-1.6MB, retention 없음 | High |
| RT-C4 | P2 | 관측 오류 | `Host.carried_start_range` 호출부 (Codex #38882·#38822) | #38882·#38822 | resume 에서 안 보낸 크기를 `transmitted_bytes` 로 적는다 | High |
| RT-A3 | P2 | 동시 쓰기 유실 | `bin/masc_tui.ml:20350-20372,18232-18251` | #39518·#39577 | 계정 선언이 revision 없이 파일 전체를 덮어쓴다 | 코드 High |
| RT-A4 | P2 | SSOT · string 분류 | `bin/masc_tui_account_login.ml:75-80,190-192` 외 5곳 | #39518 외 | 4-client 목록이 6곳, `_ -> None` 문자열 분류 | High |
| RT-A5 | P2 | SSOT · hardcoded default | `lib/runtime/runtime_quota_window.ml:108-134` 외 4곳 | #38764 | inherited home 계산이 4-5곳에서 서로 다르다 | High |
| RT-A6 | P2 | catch-all · legacy | `lib/runtime/runtime_toml.ml:~2521,786-791` | 주 이전 + #39559·#39518 | `[runtime.<table>]` 조용히 무시, `provider-name` 별칭 3곳 | High |
| RT-A7 | P2 | 잔재 | `lib/runtime/runtime_account_removal.ml:281` | #39634 | 계정 제거 뒤 계정 전용 모델 표가 남는다 | Medium |
| RT-A8 | P2 | 두 검증기 불일치 | `lib/runtime/runtime_toml.ml:2724-2745` vs `runtime_exact_output_registry.ml:149-159` | 주 이전 | slots·cli_slots 중복을 파서는 놓치고 registry 는 부팅에서 raise | Medium |

열린 PR 과 겹침: C1 → #39972(OPEN). C2 → lead 가 #39972 에 이미 리뷰 코멘트로 남김. C3 → lead 가 "바뀌지 않은 Librarian commit" PR 을 따로 진행 중. S5 → 이슈 #39511(OPEN, PR 아님). 나머지는 `open-prs.txt` 에 해당 PR 이 없다.


## Memory · Librarian · Skills · Context

| id | sev | class | file:line | 도입 | 결함 한 줄 | conf |
|---|---|---|---|---|---|---|
| MM-M1 | P1 | waste / open loop | `lib/keeper/keeper_memory_os_recall.ml:21-28,121-131`, `keeper_run_tools_hooks.ml:996-999`, `keeper_official_client_host.ml:256-296` | 헤더는 주 이전(8439213b70). 비용 경로는 #38986(09-26)·#38822(09-27) | recall block 머리글에 memory revision 이 들어 있어, 내용이 그대로인 커밋에도 digest 가 바뀝니다. 그래서 resume 마다 140~440 KB block 을 벤더 세션에 다시 보냅니다. | High |
| MM-M2 | P1 | N-of-M | `lib/keeper/keeper_codex_runtime.ml:1017-1022` vs `keeper_claude_code_runtime.ml:719-723` | #38822 (97ed4b9f50) | Codex resume 에 `?composed_context` 를 넘기지 않습니다. 그래서 carrier 전체를 digest 하나로 보고, 매 턴 바뀌는 temporal 줄 때문에 전체를 매번 다시 보냅니다. | High |
| MM-C1 | P1 | happy path | `keeper_agent_run.ml:2106-2124`, `keeper_agent_run_finalize_response.ml:17-25,365-372`, `keeper_librarian_range.ml:121-129` | #38809 (461847627b, 09-25) | Agent Core stage save 가 atom 을 더해도 끝 줄이 `No_atom_history` 로만 남을 수 있습니다. 그러면 atom Librarian 위치와 continuity 가 멈추고 purge 도 영구히 거절됩니다. | High(경로) / Medium(범위) |
| MM-M3 | P1(예측) | open loop + gate | `keeper_memory_os_render.ml:40-51`, `keeper_librarian_durable_consumer.ml:1335-1356`, `keeper_librarian_runtime.ml:1474-1478` | #39755 (79139d09e2) | 기억이 수렴하지 않고 계속 늘어, 2~3일 안에 512 KiB gate 에 닿습니다. 닿으면 거절된 range 로 턴마다 모델을 다시 부르고, continuity 게시도 멈춥니다. | Medium |
| MM-W1 | P1(잠복) | wiring | `lib/server/server_workspace_memory_curator.ml:130-137,149-192` | #39858 | lane 이 `max_output_tokens` 를 선언하지 않으면 실행 준비가 늘 실패합니다. 실패가 run 기록 전에 나서 ERROR 로그만 남습니다. | High |
| MM-W2 | P1(잠복) | SSOT / N-of-M | curator `:154-155`, `runtime.ml ~5279`, `runtime.mli:1288-1309` | #39622 → #39858 | CLI slot 허용 규칙이 writer 와 executor 에서 서로 반대입니다. | High |
| MM-W3 | P1(잠복) | waste / HOL | curator `:224-227,280-295`, `workspace_memory_request.ml:81-92` | #39858 | 모델이 거절한 묶음을 기억하지 않아, commit 이 올 때마다 같은 입력으로 다시 부릅니다. | Medium |
| MM-W4 | P1(잠복) | main-domain | `workspace_memory_request.ml:78-151`, curator `:176-186` | #39846·#39858 | FTS 색인과 O(n²) 렌더링이 daemon fiber 에서 inline 으로 돕니다. | High(위치) |
| MM-W5 | P1(잠복) | unbounded read | `workspace_memory_ledger_view.ml:17-62,111-162`, `config/prompts/keeper.md:548-553` | #39865 | `keeper_workspace_memory_read {}` 가 원장 전체를 돌려줍니다. 도구 설명은 "bounded" 라고 합니다. | Medium |
| MM-M4 | P2 | typed / forbidden | `keeper_memory_os_render.ml:40-51`, `keeper_memory_os_current.ml:2754`, `keeper_tool_memory_runtime.ml:1593`, `keeper_librarian_runtime.ml:99`, `keeper_librarian.ml:304-318`, `env_config_keeper.ml:323-344` | #39755 | 예산 거절이 문자열이라 "persistence failed" 로 보입니다. Librarian 에게 보여 주는 크기에는 source 바이트가 빠집니다. 한도는 고정 매직넘버이고 env 로만 바꿀 수 있습니다. | High |
| MM-M5 | P2 | waste / open loop | `lib/keeper/keeper_muse_runtime.ml:516-523` | #39393 (1ec425d4a3) | Muse resume 은 `held:[]` 라서 carried context 를 전부 매번 보냅니다(평균 132 KB). 호스트 세션은 이것을 계속 쌓습니다. | High |
| MM-M6 | P2 | contract drift | `lib/keeper/keeper_librarian_context.ml:79,95-110` | 주 이전(미확인) | 이전 pocket 을 보여 주는 필드(`context_id`·`source_count`·`completeness`)와 출력에 허용되는 필드가 다릅니다. 그래서 "object fields mismatch" 로 매일 약 20건 거절됩니다. | Low-Med |
| MM-C2 | P2 | unwired | `keeper_turn_driver.ml:1670,1631-1640,1760-1775`, `keeper_turn_driver_try_provider.ml:400,2043` | 8439213b70, #38822 | `?recovery_view` 를 만드는 production 호출이 0곳입니다. `Some` 분기는 모두 죽은 코드입니다. | High |
| MM-C3 | P2 | waste | `keeper_agent_run.ml:1573-1620`, `keeper_checkpoint_store.ml:164-189`, `runtime_settings.ml:279-288` | 주 이전 | stage save 마다 canonical checkpoint(85 MB)를 통째로 다시 씁니다. history 3칸도 한 턴 안에서 다 찹니다. | High |
| MM-C4 | P2 | open loop | `keeper_turn_boundaries.ml:368-399` | 주 이전 | `turn-boundaries.jsonl` 은 회전 없이 계속 늘고, 턴마다 3회 이상 전체를 decode 합니다. | High |
| MM-C5 | P2 | 틀린 주석 | `keeper_official_client_host.ml:89-97` | 주 이전 | 주석은 "resume 에도 --system-prompt 에 합친다"고 하지만 실제 동작과 다릅니다. | High |
| MM-S1 | P2 | waste | `keeper_run_tools_hooks.ml:483-520`, `keeper_skill_activation_ledger.ml:2342-2383` | 주 이전(#39862 가 그대로 둠) | Skill 을 쓰지 않은 step 도 checkpoint lock 을 잡고 tail read 를 합니다. | High |
| MM-S2 | P2 | open loop | `keeper_skill_activation_ledger.ml:2091-2106,2229-2260`, `keeper_skill_activation_discovery.ml:160-305` | #39862 | `session_logs` 캐시를 버리지 않습니다. reader 는 요청마다 파일 전체를 다시 읽습니다. | High |
| MM-S3 | P2 | residue | `<base-path>/.masc/traces/*/skill-activations.json` | #39862 | 아무도 읽지 않는 옛 snapshot 25개(9.6 MB)가 남아 있습니다. Python reader 는 #39881(open)이 고칩니다. | High |
| MM-S4 | P2 | wiring | `keeper_durable_store.ml:759-779` | #39862 | 새 event log 가 durable store registry 와 preflight 에 없습니다. 행 하나가 깨지면 그 세션의 `keeper_skill` 이 모두 실패합니다. | Medium |
| MM-S5 | P2 | residue | `lib/skill_config/skill_source_config.ml:182-203,393-402` | #39285 | `resource-read-max-bytes` 호환 경로가 남아 있습니다(#39284 에서 추적). | High |
| MM-S6 | P2 | string control | `keeper_skill_observability.ml:31,204,225,305,311`, `workspace_skill_publish.mli:38-62` | 주 이전 + #39517 | `kind : string` 을 `"composition"` 과 비교하고, 진단도 문자열로 적습니다. | High |
| MM-S7 | P2 | 잠재 | `keeper_run_tools_setup.ml:405-407`, `keeper_task_skill_turn.ml:33-60` | 주 이전(#31130) | Task 에 고정된 Skill 이 지워지거나 revision 이 바뀌면 그 Keeper 의 모든 턴이 막힙니다. | High(경로) |
| MM-W6~W10 | P2 | residue / catch-all / 효율 | 위치 미확인(묶음 보고) | #39800~#39865 | 문구 잔재, 문서와 다른 배선, 이름만 있는 variant, 묶음 끝 품질 저하 | 보고됨 · 위치 미확인 |


## Board · Task · Goal · HITL · Candle · Portrait · Play

| id | 심각도 | 분류 | 위치 | 들어온 곳 | 결함 한 줄 | 확신 |
|---|---|---|---|---|---|---|
| DM-BD-1 | P1 | 1·3 N-of-M | `lib/keeper/keeper_board_attention_worker.ml:1775-1799` | #39186/#39301 에서 도달 가능, #39784 가 한 쌍만 고침 | 예상 밖 (partition 상태 × quarantine phase) 한 쌍이 keeper 의 Board attention worker 전체를 멈춘다. 재시작도 없다 | High (재확인) |
| DM-PL-01 | P1 | 1 | `lib/keeper/keeper_dos_controller.ml:46-60` | #38438, #39915 까지 이어짐 | meta 를 지우고 멈춘 Keeper 가 서버 재시작 전까지 DOS controller 를 쥔다. 운영자가 풀 경로도 없다. purge 는 credential 까지 지워 인증 필수 모드에서 풀리지만, `remove_meta` 종료와 supervisor 정리는 만료 없는 Worker credential 을 남긴다 | High (09-30 라이브 credential 확인), **열린 #40045 가 고침** |
| DM-PT-1 | P1 | 1 | `lib/keeper_portrait/keeper_portrait_draw.ml:216` | #39803 | 짧은 초에서 메달이 frame 아래로 잘린다(몸 약 25%) | High, **열린 #39961 이 고침** |
| DM-PT-2 | P1 | 1 | `lib/keeper/keeper_portrait_read.ml:81` | #39869 | "durable" 초상화 PNG 를 500개·20MB 회전 frame 캐시에 넣어 다른 frame 에 밀려난다 | Medium (재확인), **열린 #39957 이 고침** |
| DM-BD-4 | P2 (lane 을 켜면 P1) | 1·2 | `lib/server/server_workspace_memory_curator.ml:224-245`, `workspace_memory_request.ml:81-92` | #39858 | 실패한 batch 가 앞 prefix 로 매번 다시 뽑혀서 curation 전체가 막힌다 | Medium |
| DM-BD-3 | P2 | 2 | `keeper_board_attention_exact_flow.ml:576-606`, worker `:2318-2350` | Jev-first + #39186 | deferral 뒤 재시도마다 Jev 를 다시 부르고, 60초 pulse 로 모든 HTTP 슬롯을 다시 돈다 | High (09-29 `deferred_lane_exhausted` 12,974건 재확인) |
| DM-PL-02 | P2 | 1 | `lib/server/server_routes_http_routes_play.ml:179` | #39730 | `Eio.Mutex.use_rw ~protect:true` 안에서 예외가 나면 mutex 가 poison 돼서, 재시작 전까지 초대 발급·회수가 전부 막힌다 | High(기전), Low(빈도) (재확인) |
| DM-BD-5 | P2 | 5 | `server_workspace_memory_curator.ml:154-155` | #39622 ↔ #39858 | TUI 로 curator 에 CLI 슬롯을 넣으면 load 는 되고, curator 는 매 commit 마다 거절한다 | High (재확인) |
| DM-BD-2 | P2 | 5·2 | `keeper_board_attention_partition.ml:1225-1248` | #39841 | `ready_confirmation` 행이 부팅마다 쌓이고 compaction 도 지우지 않는다. 읽는 곳도 없다 | High |
| DM-GT-01 | P2 | 5 | `lib/goal/goal_store.ml:748-766, 813`, 주석 `lib/workspace_goals.ml:550-552, 709-712` | #39758 | owner 는 생성 때만 정해지고 바꿀 경로가 없다. 주석은 운영자가 바꿀 수 있다고 적는다. 라이브 Goal 19개 중 18개가 unknown 이라 알림이 가지 않는다 | High (재확인), **열린 #39975 가 owner 전제를 없앰** |
| DM-GT-02 | P2 | 1·3 설계 | `lib/workspace_goals.ml:1226-1232` | #39922 | `after_confirmation` 이 Error 를 내면 확정은 기록되고 phase 는 안 옮겨진다. Goal 완료 앞에 새 게이트가 생긴다 | Medium. #39917·#39979 가 의도한 설계 |
| DM-GT-04 | P2 | 2 tick | `lib/workspace_goals.ml:877` | #39922 로 도달 가능 | `Human_confirmed` + `Awaiting_confirmation` 상태는 재시작해도 수렴하지 않고 사람이 다시 확정해야 한다 | Medium |
| DM-GT-03 | P2 | 3 | `lib/workspace_goals.ml:829-834` | #39922 | step 이 optional 인자라 호출자가 빠뜨려도 컴파일러가 못 잡는다. Persist_failed 뒤 replay 에서 step 이 다시 돈다(mli 와 다름) | Medium |
| DM-PL-03 | P2 | 5 | `server_routes_http_routes_play_page.ml:443-466`, `server_routes_http_routes_play.ml:95` | #39739 계열 | 떠난 holder 를 누가 움직일 때까지 "X 님 차례예요"로 보여 준다 | High |
| DM-PL-05 | P2 | 5 N-of-M | `lib/mcp_server_eio_execute.ml:451` | #39821 | `/mcp`·`/mcp/play` 조작과 revoke 해제는 add-on 에 `Machine_changed` 를 알리지 않는다 | Medium |
| DM-PL-06 | P2 | 3 SSOT | `lib/play/play_invite.ml:121`, `auth_credential_token.ml:256,620`, `Auth_token_inventory.classify` | #39915 | credential 만료 판정이 네 곳, 규칙이 둘(`>` vs `<=`) | High |
| DM-PL-07 | P2 | 3 | `lib/play/play_seat.ml:10-18` vs `keeper_dos_controller.ml:56` | #39915 | 누가 기계 앞에 있는지를 두 곳이 다르게 정한다 | High, 만료 부분은 **#39962** |
| DM-PL-08 | P2 | 1 | `lib/play/play_invite.ml:93-97`, `lib/auth/auth.ml:11-47` | #39730 | 같은 이름의 Keeper 가 나중에 생기면 부팅 때 Player credential 을 Worker 로 덮어쓴다 | Medium |
| DM-PL-04 | P2 | 3 잔재 | `lib/dos_lane/dos_lane.ml:774` | #39083 | 떠난 이유를 알면서 활동 기록에 `"released (idle)"` 를 쓴다. idle 해제는 없다 | High |
| DM-PL-09 | P2 | 1 | `bin/masc_tui.ml:14519-14525` | #39861 | 1회용 초대 링크(토큰 포함)가 채팅 행·세션 로그·클립보드로 새어 나간다 | High, **열린 #39877 이 고침** |
| DM-PT-3 | P2 | 3 | `bin/masc_tui_keeper_portrait.ml:57`, `server_dashboard_http_keeper_portrait.ml:116`, `keeper_portrait_read.ml:56-57` | #39869 | 이름 → 외형 결정이 세 곳이다. Candle RFC 는 두 곳이라고 적고 두 곳만 착용으로 바꾸려 한다 | High (재확인) |
| DM-PT-4 | P2 | 2 | `lib/keeper_portrait/keeper_portrait_look.ml:227-253` | #39765 #39773 #39803 | 목록 길이로 index 를 골라서, 아이템이 하나 늘 때마다 대부분 Keeper 의 기본 장신구가 바뀐다 | High |
| DM-PT-5 | P2 | 3 SSOT | 512·160 이 `draw.ml:65`, `keeper_portrait_read.ml:6-7`, TOML, `server_…_portrait.ml:10`, 대시보드에 있다 | #39925 | 크기 한도와 기본값이 여러 곳에 복사돼 있다. handler 검사는 TOML 검증과 중복이다 | Medium-High |
| DM-PT-6 | P2 | 3 | `keeper_portrait_read.ml:61-77` vs HTTP `:115-117` | #39869 | MCP 는 RGB 평탄화, HTTP 는 RGBA 다. MCP 는 systhread 에서, HTTP 는 CPU pool 에서 그린다 | High(차이) |
| DM-PT-7 | P2 | 3 | `server_dashboard_http_keeper_portrait.ml:161-167` | #39715 | `keeper_meta_path` 에 부작용(ensure_dir)이 있어 경로를 손으로 다시 만든다 | High |
| DM-BD-6 | P2 | 3 | `board_votes.ml:675-684` vs `:811`, `board_core_persist.ml:162` | #39479 #39522 | successor 는 close 때만 검사한다. successor 를 지우거나 TTL 로 쓸어 내면 없는 글을 가리킨다 | High |
| DM-BD-7 | P2 | 3 | `board_tool_handlers.ml:62-126` | #39691 | moderator 목록을 호출마다 디스크에서 따로 파싱한다. 키 오타가 나면 기본값 `["e-masc-the-leader"]` 로 조용히 떨어진다 | High |
| DM-BD-8 | P2 | 3 env | `board_types.ml:325` | #39491 | comment cap 이 env 로만 바뀐다(`MASC_BOARD_COMMENT_COUNT_CAP`, 기본 100). 0 이하면 cap 이 꺼진다 | High |
| DM-BD-9 | P2 | 3 SSOT | `workspace_memory_ledger_view.ml:9-15, 75-163` | #39865 | curator 원장 진입점이 둘이다. view 가 자기 JSON 을 문자열 kind 로 다시 읽고, 요청마다 전체 memory 를 읽는다 | High |
| DM-BD-10 | P2 | 3 잔재 | `lane_manifest.ml:22-24`, `board_types.ml:192`, `masc_tui_loader.ml:644-660` | #39865 #39522 | 없어진 proposals 설명과 옛 행 관용 디코더가 남아 있다 | High |
| DM-GT-05 | P2 | 3 string | `bin/masc_tui_overview_goals.ml:98-101`, `lib/tui_decode.ml:7019-7026` | #39758 | Overview 는 `Some "proof_refuted"` 문자열로, Planning 은 typed decoder 로 같은 필드를 읽는다 | High |
| DM-GT-06 | P2 | 1·3 | `goal_store.ml:758-761`, `tool_args.ml:32-35`, `bin/masc_tui_types.ml:2363-2368` | #39923 이 남긴 틈 | 기한을 지울 방법이 없다. #39923 이전에 저장된 읽을 수 없는 값은 알림에서 조용히 빠진다. Planning 은 원문 문자열로 정렬한다 | High |
| DM-GT-07 | P2 | 3 silent | `lib/workspace_goals.ml:672, 716` | #39758 | Goal 저장소를 못 읽으면 두 알림 scan 이 아무 기록 없이 넘어간다 | High |
| DM-GT-09 | P2 | 3·5 | `dashboard/src/components/internal-agents-monitor.ts:174-175, 512-517` | #39871 | 더는 만들지 않는 `exact_source_resolved` 에 분기하고, 새 종료는 `output.reason` 문자열로 알아본다 | High |
| DM-GT-08 | P2 | 3 잔재 | `lib/types/types_core.ml:420-425` | #39572 | 지운 `intent` 필드 이름이 decoder 에 남아 있다. 라이브 행은 0개 | High |
| DM-GT-10 | P2 | 3 magic | `server_routes_http_keeper_stream.ml:301`(180s), `keeper_late_approval.ml`(900s) | 이번 주 이전 | 메모리 안 도구 승인 대기와 늦은 답의 시간 한도가 코드 상수이고, 재시작하면 사라진다 | High |
| DM-GT-12 | P2 | 3 SSOT | `lib/workspace_goals.ml:567-571` | #39758 | 새 화자 문자열 `"goal-verifier"` 를 반박·기한 초과 알림 둘 다에 쓴다. verifier id(`verifier_exact`)가 이미 있다 | Medium |
| DM-CD-1 | P2 | 3 문서 | `docs/rfc/RFC-goal-candle-ledger.md` 3.1 · 3.2 · 2장 | #39863 | main 의 RFC 가 병합된 코드와 다르다. append 함수가 다르고(at_end_offset vs cursor), PayoutOwed 를 쓰는 주체가 다르고(일꾼 vs `after_confirmation`), 초상화 호출부 수가 다르다(2 vs 3) | High. 앞의 둘은 **#39917**, 호출부는 미해결 |
| DM-CD-2 | P2 | 5 설계 | 열린 #39928 `candle_config.ml` `of_toml_string` | #39928 | 빈 `candle.toml` 이 `Enabled` 다. RFC 3.9 는 필수 키가 없으면 `Disabled` 라고 한다. #39978 이 이 위에 쌓이면 빈 파일 하나로 Snapshot 이 모든 Goal 통과 앞의 게이트가 된다 | High(코드), 스택은 열려 있음 |
| DM-CD-3 | P2 | 2 tick | 열린 #39978 `candle_status.mli` | #39978 | 복구는 프로세스당 한 번이다. 그 뒤에 잘린 꼬리가 생기면 재시작 전까지 모든 Goal 통과가 거절된다(mli 가 스스로 적음) | Medium |
| DM-CD-4 | P2 | 3 telemetry-as-fix | `keeper_hooks_agent_core_cost_events.ml:386-395`, `keeper_turn_spend_commit.ml:40-51` | 09-21 (이번 주 전, 열린 채 남음) | meta 합계는 먼저 commit 되고, cost event 쓰기가 실패하면 counter 와 로그만 남는다. 두 값이 어긋난다 | High |


## TUI · 대시보드

중복은 하나로 합쳤습니다(예: S1 = R7, S2 = R5, W1 = R9, W8 = U4, W15 = S1(lanes)).
심각도: P0 = 정상 경로에서 표면이 안 됨, P1 = 실제 결함, P2 = 냄새·표현.

| id | 심각도 | 분류 | file:line (양쪽) | 들어온 커밋 | 한 줄 결함 | 확신 |
|---|---|---|---|---|---|---|
| TU-F01 | P0 (web) | TS↔OCaml 디코드 | `dashboard/src/api/board.ts:288-311,176` ↔ `lib/keeper/keeper_approval_queue.ml:2501-2530` | 주간 이전 | 웹 Gate가 대기 승인 행을 모두 버립니다(`goal_ids` 키 개수 불일치). **#39991이 고치는 중** | High (재확인) |
| TU-F02 | P0 (web) | TS↔OCaml 디코드 | `dashboard/src/api/schemas/runtime-probe.ts:23-29,177` ↔ `lib/server/server_dashboard_http_runtime_info.ml:1191-1210`, `lib/types/health_status.ml:68-76` | 주간 이전 | 서버는 `ok/idle/degraded/unavailable`을 보내는데 웹 스키마는 옛 단어만 받습니다. 건강한 fleet이면 schema drift 예외가 납니다 | High (재확인) |
| TU-F03 | P1 | 키 충돌 | 푸터 `bin/masc_tui_render_chat.ml:3521,3660`, `bin/masc_tui_types.ml:11754`, `bin/masc_tui_keys.ml:492` ↔ `bin/masc_tui.ml:16966,20567`(마우스 토글이 먼저 받음), 죽은 분기 `bin/masc_tui.ml:1897` | 주간 이전 | 채팅의 `Ctrl-T:queue`는 대기열을 열지 않고 마우스 추적만 끕니다 | High (재확인) |
| TU-F04 | P1 | 필드 이름 | `lib/server/server_dashboard_schedule_projection.ml:1176` (`next_due_at`) ↔ `bin/masc_tui_loader.ml:1029-1038` (`next_due_at_iso`, 없으면 `Ok None`) | 주간 이전 | Schedules 머리의 "Next due"가 한 번도 안 그려집니다. 웹은 맞는 이름을 읽습니다 | High (재확인) |
| TU-F05 | P1 | 태그 누락 | `lib/keeper/keeper_memory_os_current.ml:1391-1398,3042` ↔ `bin/masc_tui_keeper_chat_history.ml:781-785` | 주간 이전 | 격리된(`quarantined`) 기록 행을 "읽지 못한 행"으로 셉니다 | High |
| TU-F06 | P1 | 잘못된 파생 | `lib/keeper/keeper_gate_mode.ml:223-231`(`stricter`) · 라우트 `lib/server/server_routes_http_routes_dashboard.ml:2961-2975` ↔ `bin/masc_tui_types.ml:408-420` | 주간 이전 | Keeper 상세는 저장된 override를 보여 주고, 실제로 적용되는 더 엄격한 모드는 안 보여 줍니다. `"workspace"` 문자열 비교도 있습니다 | High (재확인) |
| TU-F07 | P1 | 조용한 기본값 · 디코더 둘 | `lib/goal/goal_verification.ml:398` ↔ `lib/tui_decode.ml:7019-7027`, `bin/masc_tui_overview_goals.ml:99-101` (Planning의 `decode_goal_proof` `tui_decode.ml:2150-2185`와 다름) | d7fd475ba5 #39758 (주간) | 증명 원장을 못 읽으면 GOALS에서 "refuted" 표시가 말없이 사라집니다 | High |
| TU-F08 | P1 | 필드 무시 | `lib/keeper/keeper_gate_mode.ml:81-111` (`state`, `read_error`) ↔ `lib/tui_decode.ml:8742`, `bin/masc_tui_render.ml:2044-2047` | 주간 이전 | Auto Judge가 못 도는데도 "Workspace: Auto Judge"라고 그립니다. 모드 파일이 깨져도 이유 없이 "Manual"입니다 | High |
| TU-F09 | P1 | 한 단어에 두 뜻 | `lib/server/server_standalone_lane_projection.ml:710-711` ↔ `lib/tui_decode.ml:7316,7329`, `bin/masc_tui_render.ml:5739` | 2b81bb54f5 #38708 (주간) | 슬롯이 있어도 admission error가 있으면 "configured, but no slot admitted"라고 씁니다 | High (재확인) |
| TU-F10 | P1 | 이유 버림 | `lib/server/server_setup_account_login.ml:168` ↔ `bin/masc_tui_account_login.ml:612`, `bin/masc_tui_http.ml:3386`, `bin/masc_tui.ml:4392` | 98e6812685 #39403 | /login 로그인 흐름이 실패하면 서버가 말한 이유를 버리고 고정 문구만 보여 줍니다. #39695는 Save만 고쳤습니다 | High |
| TU-F11 | P1 | 거절 응답 모양 4개 | 서버 `server_routes_http_routes_activity.ml:69-71,176-185`, `server_routes_http_routes_msx.ml:110,171-195`, `server_routes_http_routes_play.ml:21`, `server_dashboard_http_keeper_chat_operations.ml:80-84`, `server_routes_http_keeper_stream.ml:183-187` ↔ `lib/tui_decode.ml:1782-1789` | 주간 이전 | TUI는 문자열 `error` 모양 하나만 읽습니다. 나머지는 원문 240바이트 자르기나 코드만("HTTP 409: not_ready") 보여 줍니다 | High, **09-30 결정: `{error: 문장, code}` 하나로. 1단계 열린 #40050** |
| TU-F12 | P1 | 조용한 실패 | `lib/server/server_routes_http_routes_msx.ml:131-141` ↔ `bin/masc_tui.ml:19495-19498` (`Ok _ \| Error _ -> ()`), `bin/masc_tui_http.ml:614` (`with _ -> Ok 0`) | 주간 이전 | MSX 키가 거절돼도 아무 표시가 없습니다 | High |
| TU-F13 | P1 | N-of-M | `bin/masc_tui.ml:5518-5528` ↔ `lib/tui_decode.ml:6029-6037,6560-6567` | 2208a835f9 #38049, 8e96d16e6c #39038 (주간) | Memory 전체 Keeper 보기가 거절된 Keeper의 fact를 읽지도 세지도 않습니다. #39038이 막으려던 바로 그 경우입니다 | High |
| TU-F14 | P1 | 쓰기가 값을 덮음 | `lib/server/server_routes_http_routes_activity.ml:158-162`, `lib/tool_schedule.ml:742-743` ↔ TUI 수정 폼(`result_delivery` 안 보냄) | 주간 이전 | TUI에서 스케줄을 고치면 `result_delivery`가 `none`으로 바뀝니다(Slack에서 만든 `reply_to_origin`이 사라짐) | Medium (코드 경로만) |
| TU-F15 | P1 | 키 뜻이 행마다 다름 | `bin/masc_tui.ml:23486-23492`, `approval_row_reference` `:8843` | 주간 이전 | Approvals의 `Y`는 대부분 행에서 복사, reference 없는 운영자 행에서는 승인(Confirm)입니다. 두 번 눌러야 하긴 합니다 | High(경로) / Medium(빈도) |
| TU-F16 | P1 | 푸터와 다른 키 | 푸터 `bin/masc_tui_render.ml:16901` ↔ `bin/masc_tui.ml:20553`(quit 먼저), 죽은 분기 `:21265`, `:21184` | 주간 이전 | Patch review 푸터는 `Esc/q:close`인데 `q`는 종료를 준비하고 한 번 더 누르면 TUI가 꺼집니다 | High |
| TU-F17 | P1 (web) | TS 스키마 누락 | `dashboard/src/api/dashboard-skills.ts:670-684,950-953` ↔ `lib/keeper/keeper_msg_async.ml:2817` | 주간 이전 | 요청이 하나라도 있으면 웹 async-requests 칸이 실패합니다(`request_context`) | Medium-High |
| TU-F18 | P1 (web) | TS union 누락 | `dashboard/src/api/schemas/keeper-chat-delivery-provenance.ts:22-39`, `dashboard/src/keeper-state.ts:1682` ↔ `lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml:96-131` | d7fd475ba5 #39758 (`goal_notification`, 주간) | 웹 채팅이 도구 행 3종을 버립니다 | High |
| TU-F19 | P1 (web) | 필드 무시 | `dashboard/src/api/dashboard-keeper-cost.ts:86-140` ↔ `lib/dashboard/dashboard_http_keeper_feeds.ml:190,232` | b30bd451e5 #38373, 4a91c9ed20 #38728 (주간) | 웹 비용 화면이 읽기 실패를 "턴 0개"로, 하한값을 정확한 값으로 보여 줍니다. TUI는 맞게 다룹니다 | High |
| TU-F20 | P2 | 되읽는 문자열 분류기 | `bin/masc_tui_render_chat.ml:361-420` ↔ `bin/masc_tui_keeper_chat_transcript.ml:697-704` | 기존, b46758f25c #39430 (주간)이 늘림 | 타입(`Never_returned` 등)으로 만든 글자를 다시 substring으로 읽어 색을 정합니다. `outcome unrecorded`는 경우가 없고, 이름에 "failed"가 들어간 도구는 색이 틀립니다 | High (직접 확인) |
| TU-F21 | P2 | 조용한 기본값 | `lib/tui_decode.ml:5019-5029` ↔ `server_dashboard_runtime_resolved_json.ml:100` | 주간 이전 | `quota_exhausted`가 없으면 "여유 있음"으로 읽습니다. 주석은 반대로 말합니다 | High |
| TU-F22 | P2 | 문자열 검사 | `lib/tui_decode.ml:5101` ↔ `server_dashboard_runtime_resolved_json.ml:338` | 주간 이전 | `source`가 경로 문자열과 같지 않으면 문서 전체를 거절합니다 | High |
| TU-F23 | P2 | 여러 원인을 한 bool로 | `lib/keeper/keeper_exact_lane_preference.ml:162-173` ↔ `lib/tui_decode.ml:8900` | 263b51fbc2 #39037, 7c27ea1e36 #39091 (주간) | registry 미게시·게시 중·해석 실패가 모두 "not offered"로 보입니다 | High |
| TU-F24 | P2 | 캐시 키 | `server_routes_http_routes_dashboard.ml:3124`, `server_dashboard_http.ml:804,849` | 40a66d1819 #38784 (주간, 다른 두 키만 바꿈) | Planning 목록이 확정 뒤 최대 60초 옛 phase를 보여 줍니다 | High |
| TU-F25 | P2 | 행 버림 | `lib/runtime/runtime_account_email.ml:147-153` ↔ `bin/masc_tui_account_login.ml:143-156` | 8a8afd4d4f #39694 (주간) | 이메일을 못 읽은 계정이 이유 없이 빈칸으로 보입니다 | High |
| TU-F26 | P2 | 필드 무시 | `lib/server/server_dashboard_http_cache.ml:121-138`, `server_dashboard_http_execution_surfaces.ml:525-532` ↔ `lib/tui_decode.ml:10749` | 주간 이전 | Transport가 stale을 현재 값처럼 그리고, 준비 중에는 "missing required field 'summary'"라고 씁니다 | High |
| TU-F27 | P2 | "다 못 읽음" 신호 무시 | `dashboard_verification.ml:244-248`(`unreadable_total`), `dashboard_goals.ml`(`coverage`), `server_dashboard_http_keeper_api.ml:1435,1547`(`events_unreadable_lines`) ↔ `tui_decode.ml:6626-6670, 6951-6955` 외 | 주간 이전 | 일부를 못 읽었는데 목록이 완전한 것처럼 보입니다(세 곳 같은 모양) | High |
| TU-F28 | P2 | 캐시된 나이 | `lib/keeper/keeper_approval_queue.ml:2511` + 120초 캐시 `server_dashboard_http.ml:160-196` ↔ `lib/tui_decode.ml:8709` | 주간 이전 | Gate 행의 기다린 시간이 최대 120초 멈춰 있습니다(`requested_at`을 안 씀) | High |
| TU-F29 | P2 | 엄격 목록 | `lib/tui_decode.ml:12308-12318` | 603d3e8ff2 #38620 (주간) | 모르는 hold `kind` 하나가 Schedules 목록·Automation 탭·agenda를 한꺼번에 지웁니다 | High (빌드가 다를 때만) |
| TU-F30 | P2 | 추론 | `server_keeper_oauth.ml:189,276,289` ↔ `bin/masc_tui_loader.ml:1945-1974` | 주간 이전 | Identity 탭이 `attached` 대신 `tools` 키가 있는지로 연결을 판단합니다 | High |
| TU-F31 | P2 | 원인 뭉개기 | `server_dashboard_http_keeper_chat_operations.ml:93-127` ↔ `bin/masc_tui_keeper_chat_log.ml:395-406` | 주간 이전 | 채팅 이벤트 503(`store_unavailable`, `owner_stopping`)이 "본문을 못 읽음"으로 보입니다 | Medium |
| TU-F32 | P2 | 실패를 빈 목록으로 | `lib/server/server_routes_http_routes_provider_runs.ml:236-241` | f2b68bacd7 #39205 (주간) | Keeper 이름 조사가 실패하면 `[]` → Team 행이 모두 "? tok"이고 이유가 없습니다 | High |
| TU-F33 | P2 | 표현 | `server_dashboard_runtime_resolved_json.ml:325` ↔ `bin/masc_tui_render.ml:12510` | 212e63edc3 #38764 (주간) | 응답마다 매긴 번호 `account:N`을 계정 이름처럼 그립니다 | High |
| TU-F34 | P2 | 한 행이 섹션을 지움 | `bin/masc_tui_loader.ml:1206-1209`, `bin/masc_tui_overview_providers.ml:517-526` | #39526 (주간)이 흔한 경우로 만듦 | assignment 행 하나가 깨지면 모든 계정이 "소진 아님"이 되고, 사용량 행이 없으면 소진 안내도 사라집니다 | High |
| TU-F35 | P2 | 서버 상태 코드 | `server_routes_http_routes_lane_addons.ml:45-49` | 주간 이전 | Lane Add-on의 모든 실패가 400이라, 거절과 결과 모름을 구분하지 못합니다 | High |
| TU-F36 | P2 | 접두사 매칭 | `lib/lane_addon/lane_addon_runtime.ml:219` ↔ `bin/masc_tui_lane_addons.ml:211` | 7e2af89e42 #39859 (주간)이 의존을 늘림 | 행 주인을 `instance_id ^ "/"` 접두사로 되찾습니다 | Medium |
| TU-F37 | P2 | 200 + 오류 본문 | `server_dashboard_http.ml:664-669` ↔ `lib/tui_decode.ml:11519` | 주간 이전 | 없는 Goal이 "no timeline"으로 보입니다 | High |
| TU-F38 | P2 | 기본값 "ok" | `lib/dashboard/dashboard_briefing.ml:210`, `lib/operator/operator_digest.ml:296` ↔ `bin/masc_tui_loader.ml:540-555` | 주간 이전 | digest가 실패하거나 초기화 전이어도 health가 "ok"입니다 | High |
| TU-F39 | P2 | 문자열 디코드 | `lib/tui_decode.ml:8659-8690`, `bin/masc_tui_loader.ml:527-538` | 주간 이전 | Gate phase·재시도 코드를 문자열로 읽습니다. 타입 reader(`keeper_approval_queue_rules_types.ml:114-140,582-660`)가 이미 있습니다 | High |
| TU-F40 | P2 | 서버 문자열 재조립 | `bin/masc_tui.ml:3788`(`"keeper:" ^ name`), `bin/masc_tui_render_memory.ml:583-595`(`_ -> "fleet"`), `[masc_agent_core_error]` 표시 검색 | 주간 이전 | 서버가 만든 문자열을 TUI가 다시 만들거나 쪼갭니다 | Medium |
| TU-F41 | P2 | 필드 무시 | `lib/dashboard/dashboard_http_keeper_snapshot.ml:122-133` ↔ `bin/masc_tui_keeper_config.ml:584` | 주간 이전 | 설정을 못 읽은 이유(`config_error`)를 안 보여 주고 "not observed"만 씁니다 | High |
| TU-F42 | P2 | 푸터·키 | 푸터 `bin/masc_tui_keys.ml:1324` ↔ `bin/masc_tui.ml:12479` | eea95f0720 #39531 (주간, 라벨만 키움) | Board 읽기 화면에 `v / V`가 보이지만 투표하지 않습니다 | High |
| TU-F43 | P2 | 푸터·키 | `bin/masc_tui_keys.ml:355` ↔ `bin/masc_tui.ml:25846` | 주간 이전 | Board 목록에 `c:reply`가 보이지만 읽기 화면에서만 됩니다 | High |
| TU-F44 | P2 | 대소문자 | `bin/masc_tui_render_prim.ml:2514` ↔ `bin/masc_tui.ml:22596,26213,23364,23347` | 주간 이전 | GitHub 탭이 `p:pause`를 보여 주지만 `p`는 토큰 입력을 엽니다. Sandbox 탭 `S`/`s`/`l`도 같은 원인입니다 | High |
| TU-F45 | P2 | 하위 상태 푸터 | `bin/masc_tui_render.ml:6018,6293`, `:12911` ↔ `bin/masc_tui.ml:21700,21577,21680` | dae899d581 #38898 | Lanes 슬롯 편집기와 Runtime media_failover 편집기가 바깥 표면 푸터를 그립니다 | High |
| TU-F46 | P2 | 입력 중 키 | `bin/masc_tui_lane_addons.ml:1028`, `bin/masc_tui_render.ml:17329` ↔ `bin/masc_tui.ml:~20120,20027` | 7e2af89e42 #39859 (주간) | Add-on 이름 입력 줄이 글자로 입력될 키를 단축키로 적습니다. **#39892와 겹침** | High |
| TU-F47 | P2 | 안 먹는 키 | `bin/masc_tui_account_login.ml:527` ↔ `:448` | 98e6812685 #39403 | /login Loading·Saving 중 푸터의 r/e/n이 아무 일도 안 합니다. **#39971과 겹침** | High |
| TU-F48 | P2 | 뒤 목록을 움직임 | `bin/masc_tui.ml:22704-22736` (상세 분기 `:22751`보다 먼저) | 주간 이전 | Memory fact 상세에서 c/C/s/S/a가 뒤 목록 커서를 옮겨 다른 fact가 뜹니다 | High |
| TU-F49 | P2 | 안 보이는 키 | `bin/masc_tui.ml:25589,22186,22195,22669,25904`, `bin/masc_tui_keys.ml:1579` | 주간 이전 · #39162 revert | Keepers `d`, Runs 탭 j/k/Enter, Tools Enter, Overview task `x`가 푸터·도움말에 없습니다 | High |
| TU-F50 | P2 | 두 번째 키 목록 | `bin/masc_tui_render_prim.ml:2514`, `bin/masc_tui_footer.ml:359` | 주간 이전 | Keepers 목록 푸터가 표에서 투영되지 않고, `right/enter`가 대소문자 때문에 "절대 안 뺌" 규칙을 못 받습니다 | High |
| TU-F51 | P2 | 위치 문자열 | `bin/masc_tui_render.ml:1488,1574,12745,12749` | 6f76edb0bf #38486 | #38820 뒤에도 `[rows a-b/n]`이 힌트 문자열 안에 남아 뺄 수 있는 키처럼 처리됩니다 | High |
| TU-F52 | P2 | 안 쓰는 코드 | `bin/masc_tui_http.ml:1590`(`fetch_keeper_chat_operation`), `:3213`(`submit_keeper_ask_answer`), run-next `interrupt_token` | 8333ac6ff8 #37709 이후 | 호출 없는 함수와 두 번째 인코더가 남아 있습니다 | High |
| TU-F53 | P2 | 연결 안 된 라우트 | `server_routes_http_routes_channel_gate.ml:763`, `server_dashboard_http_delete_actions.ml:1027,1035`, `server_routes_http_routes_dashboard.ml:3159,3591`, `server_dashboard_http_keeper_api.ml:1361`, `server_dashboard_http_keeper_memory_cleanup.ml:25`, `server_routes_http_routes_dos.ml:34` | #39830, #39479, #38784, #39514, #37594, #39726 | 이번 주에 추가된 라우트 7개를 TUI도 대시보드도 부르지 않습니다(테스트만) | High |
| TU-F54 | P2 | 라우트 표 둘 | `lib/server/server_h2_gateway.ml`(손으로 관리), `lib/server/server_routes_http.ml:22,43`(workspace 두 번 등록), `bin/masc_tui_http.ml:781,803,822,1273-1276`(query에 path 인코더) | 주간 이전 | h2 게이트웨이에 keeper-costs·standalone-lanes 등이 없습니다. TUI는 HTTP/1.1이라 영향 없음. h2c 사용 여부는 unverified | Medium |
| TU-F55 | P2 | 낭비 | `bin/masc_tui.ml:11575-11593` (tool-approvals·gate·turns·schedules를 모든 표면에서 2초마다), 조건부 GET 없음(`bin/masc_tui_http.ml`에 ETag 없음) | 기존 + schedules는 agenda 도입 때 | 바뀌지 않은 응답도 2초마다 받아서 다시 디코드합니다. schedules는 agenda의 "다음 wake" 하나 때문에 페이지 전체(주석 측정치 12.4 kB gzip)를 받습니다 | High (코드) / 비용은 미측정 |
| TU-F56 | P2 (근본) | 읽기 상태 N-of-M | `bin/masc_tui_types.ml`: `*_error : string option` 59개, `Masc_tui_fetched.t` 12개, `Snapshot_read.t` 3개, `_inflight/_loading` 22개, 모듈별 재발명 5개(`masc_tui_agenda.mli:87`, `masc_tui_overview_tasks.mli:137`, `masc_tui_render_memory.mli:46`, `masc_tui_lane_addons.mli:55`, `masc_tui_render_schedule.mli:744`) | 1719dcfb16 #39209가 틀을 만들고 12곳만 옮김 | "안 읽음 ≠ 0"과 "이유는 한 번만" 수정이 반복되는 원인입니다(5절) | High (직접 확인) |
| TU-F57 | P2 (근본) | 키 SSOT N-of-M | 투영 57곳 ↔ `masc_tui_render.ml` 손글씨 36개(21개 함수), 자체 hint 빌더를 가진 모듈 약 10개. `masc_tui_keys.mli` 머리 주석: "Dispatch mostly stays the ordered match in masc_tui.ml" | #39945, #39799 (주간) | 바인딩에 동작이 없어서, 디스패치와 푸터를 따로 맞춥니다(5절) | High |
| TU-F58 | P2 | 표현 · 행 버림 | `bin/masc_tui_account_login.ml:75-81,214-218` | #39751 (주간) | /login만 한국어 문장이고 TUI 나머지는 영어입니다. 모르는 protocol·origin이나 이름 없는 행은 말없이 빠집니다 | Medium (의도 확인 필요) |

| TU-F59 | P2 | 원문 JSON 노출 | `bin/masc_tui_lane_declaration.ml` `decode_response`의 `HTTP %d: %s` 대체 ↔ `with_tool_actor_auth` 401/403(`code` 없음) | 주간 이전 | Lane 선언 화면에서 인증 거절이 원문 JSON으로 보이고 `Masc_tui_http.refusal`을 거치지 않습니다. F11과 같은 뿌리 | High |
| TU-F60 | P2 | 이유 섞임 | `bin/masc_tui_runtime_config_receipt.ml:473-489` ↔ `lib/keeper_runtime/keeper_runtime_config.ml:319,364` | 45ca036fd1 #39577 (주간) | runtime.toml `Cannot_save` 이유에 warning 등급 항목까지 붙습니다. `severity = "error"`만 걸러야 합니다 | Medium |

웹 전용 P2(요약): `gate/connectors`가 `guild_id`를 요구해 Slack·iMessage 기록을 버립니다(`schemas/gate-connectors.ts:56` ↔ `channel_gate_binding_store.ml:259`). 웹 memory-health는 Keeper 행 하나가 깨지면 전체를 버립니다(`dashboard-misc.ts:611-620`). 사용량 퍼센트를 웹은 `Math.trunc`(28%), TUI는 반올림(29%)합니다(`runtime-stats.ts:36` ↔ `masc_tui_overview_providers.ml:97-104`). 웹 runtime-resolved는 `rate_limited`/`quota_*`를 버려 #39815의 상태가 웹에 안 보입니다.

---
