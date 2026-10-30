# 주간 감사 발견 목록 (2026-09-29 ~ 10-01)

요약·기능 표·결정 목록은 [주간 감사와 기능 표](2026-10-01-week-audit-and-feature-matrix.md)에 있고, 작은 것들과 확인 못 한 것은 [작은 것들](2026-10-01-week-audit-small-items.md)에 있다.
id 접두어는 감사 영역이다. `D` 도메인 감사, `L` 라이브 실측, `W` 배선 점검, `X` 관점별 점검.
심각도는 적대적 검증 뒤 값이다. 감사관이 붙인 값과 다르면 표의 `sev` 칸에 `←감사관값`으로 적었다.
판정 칸: 확인 = 검증 둘 이상이 코드 경로를 따라가 맞다고 했다. 검증 갈림 = 확인과 반박이 섞였다. 열린 PR 이 다룸 = 같은 결함을 고치는 PR 이 이미 있다.
기각된 발견(이미 고쳐짐·설계대로·반박됨)은 이 표에 없고 [dropped](#기각된-발견)에 사유와 함께 있다.

## D1 Runtime Failover · Lane · 계정·한도

Keeper 걷기 자체는 맞게 돈다. 429·403·402·timeout·5xx·빈 답·context 초과 모두 다음 후보로 넘어간다(Candidate_fault + Runtime_attempt_fsm). 문제는 그 바깥이다. (1) exact lane 은 쉬는 slot 을 빼지 않는다. 09-30 Librarian 이 세 slot(Ollama 주간 한도, Claude Code 429, Codex 사용량 한도)이 모두 막힌 채 2,275 pass 를 돌렸고, 그 뒤에도 매 pass 가 소진된 Ollama 를 먼저 부른다. CLI 가 답하면 실패가 로그에 안 남는다. (2) GPT-6.1 Sol 계정에서 Codex 프레임의 threadId/turnId 가 다르면 turn 을 프로토콜 오류로 끝낸다. jazz-developer 는 07Z 이후 19 cycle 중 14회 실패했다(원인 미확인). (3) 배정 27명 중 15명은 lane 없이 런타임 하나에 묶여 failover 가 없다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D1-02 | P1 | `lib/runtime/runtime_codex_app_server.ml:998-1005,1198-1204,1439-1441,1466-1468` |  | Codex 프레임의 threadId/turnId 가 active 와 다르면 turn 전체를 프로토콜 오류로 끝낸다 | 1) 오류 문구에 받은 threadId, turnId, item.type 을 넣는다(값 노출이 아니라 식별자). 2) 실패 turn 하나의 raw trace 로 하위 thread 여부를 확인한다. | 확인 · Medium |
| D1-03 | P1 | `<base-path>/.masc/config/runtime.toml:129-160,1899-1990` |  | 배정 27명 중 15명은 lane 이 없다. failover 가 no-op 이다 | 운영자 설정: 15명 각각에 [runtime.lanes."<런타임 id>"] 를 두거나 sol-*-then-glm 같은 기존 lane 으로 배정을 옮긴다. | 확인 · High |
| D1-01 | P2 ←P1 | `lib/keeper/keeper_librarian_runtime.ml:389-416,773-800,822-946` | 09-29 RT-R2 | exact lane 이 쉬는 slot 을 pass 마다 전부 다시 부른다 (Librarian). 성공 경로가 실패를 가린다 | 쉬는 slot 을 걷기에서 뺀다. 1) runtime_quota_window.ml: note_observed_exhausted 의 시그니처는 두고 안에서 noted_at 을 기록해 Observed 도 끝나는 때(noted_at + path_rest_sec)를 갖게 한다. | 검증 갈림 · High |
| D1-09 | P2 | `<base-path>/.masc/config/runtime.toml:96-127` | 09-29 DM-verifier | 판정 3개 기능이 glm-5.3-flash 한 slot 에 몰려 있다. verifier 는 900초 stall 이 하루 191번 | 운영자: 세 lane 에 다른 provider 의 slot 을 하나씩 더한다(HTTP 나 CLI). 코드: TUI Gate 와 Overview 가 slot 이 1개인 lane 을 '넘어갈 곳 없음'으로 그린다(D1-03 과 같은 화면 항목). 900초 stall 의 원인은 별도 조사 대상. | 확인 |
| D1-06 | P3 | `lib/runtime/runtime_quota_window.ml:23-25` | 09-29 RT-R6 | 쉼 기록이 프로세스 메모리에만 있다. 부팅 직후마다 소진된 계정을 다시 부른다 | provider 가 말한 reset 시각(Until)만 .masc/quota-windows.json 에 쓰고 부팅 때 keeper 시작 전에 읽는다. 명시된 시각은 프로세스보다 오래 가는 사실이다. Observed 는 저장하지 않는다(끝이 없는 추측이라서). 지난 시각은 읽을 때 버린다. | 확인 |
| D1-08 | P3 | `lib/server/server_dashboard_runtime_resolved_json.ml:18-39,77-110` | 09-29 RT-R3 | failed_attempt 마크와 exact lane 쉼이 /runtime/resolved 에 안 나온다 | resolved 의 runtime 행에 failed_attempt(종류, noted_at, 기록한 keeper)와 exact lane 쉼이 끝나는 때를 추가하고 TUI 가 '건너뜀: timeout 10:03 by rondo' 를 그린다. 테스트: 마크가 있으면 행에 나온다. | 확인 |
| D1-10 | P3 | `lib/runtime/runtime_toml.ml:777-950,2460-2490,2975-2986` | 09-29 RT-A6 | [providers.*] 표의 알 수 없는 key 를 조용히 무시한다. #40096 의 model-set 오타가 계정을 바인딩 0개로 만든다 | parse_provider 뒤에 unknown_table_keys ~path ~expected:provider_keys 를 호출한다. 허용 key 목록은 parse_provider 와 transport 파서가 읽는 key 에서 모은다. 테스트: model_set 오타가 load 오류가 된다. | 확인 |

## D2 Keeper 한 명의 Context 생명주기 · Runtime 초과를 만들지 않는 순환

기준: 스냅샷 727fc53123. 이 도메인 파일은 라이브 소스 4b881ab570 과 차이가 없어서 아래 라이브 숫자는 그대로 스냅샷에도 해당한다. 시각은 로그 기준 UTC 이고, 부팅은 10:20 KST(68295b, #39972 없음)와 12:43 KST(dc57509, #39972·#39973·#40007 포함)로 나눠 셌다. [한 줄 결론] #39972 는 효과가 있다. Codex resume 입력의 중앙값이 약 200KB 에서 19KB 로 줄었다(병합 전 129건·403건 구간 중앙값 209KB·196KB, 병합 후 1050건·155건·274건 구간 중앙값 19KB·19KB·20KB). 평균은 202~222KB 에서 66~85KB 로 줄었다. 하지만 resume 의 25%(260/1050)가 아직 100KB 넘게 다시 나가고, 그 25%가 전체 바이트의 81%(71.5/88.1MB)를 쓴다. 병합 뒤 새로 드러난 큰 문제는 셋이다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D2-01 | P1 | `lib/librarian_continuity_snapshot.ml:186-206` | 09-29 MM-C1 | #40019 뒤 continuity 스냅샷 commit 이 매번 거절돼 Librarian 모델 답이 버려진다 | 규칙을 한 함수로 모은다. '이 위치를 말하는 줄이 어느 것인가'를 keeper_turn_boundaries.ml 의 witness_line 하나가 답하게 하고, capture_range 도 그 결과(끝 줄 또는 시작 줄)를 쓴다. 지금은 cut_lines·witness_line 과 capture_range 가 각자 찾는다. | 확인 · High |
| D2-03 | P1 | `lib/runtime/runtime_codex_app_server.ml:998-1004` |  | Codex 턴 중간 compaction 뒤 item/started 신원 불일치가 치명 오류가 돼, 효과 차단과 새 Start(약 876KB)로 이어진다 | 추측으로 검사를 풀지 않는다. 1단계로 protocol_error 에 기대한 id 와 받은 id, item 종류를 typed 필드로 담는다(오류 문장 한 곳). | 확인 · Medium |
| D2-02 | P2 ←P1 | `lib/keeper/keeper_codex_runtime.ml:94-116` | 09-29 MM-M3 | Codex 에는 조립한 context 의 크기를 맡은 곳이 없어서, 창을 넘는 Start 와 compaction 반복이 생긴다 | 작은 PR 로 끝나지 않는다. 먼저 RFC 로 'recall block 크기의 주인'을 정한다. | 열린 PR 이 다룸 · Medium |
| D2-04 | P2 | `lib/keeper/keeper_codex_runtime.ml:1035` | 09-29 RT-C2 | Codex 의 host stop 종료는 held 를 항상 비워서 #39972 가 넣은 compaction 관측을 쓰지 않는다 | keeper_codex_runtime.ml:1326 을 ~held_context:!settled_held_context 로 바꾸고 낡은 주석을 지운다. host stop 이 compaction 없이 끝난 턴 뒤에 다음 resume 이 held 를 유지하는지 보는 4-tick 테스트를 하나 더한다. 한 줄 수정이다. | 확인 |
| D2-05 | P2 | `lib/keeper/keeper_codex_runtime.ml:669-690` |  | Codex 는 거의 모든 실패에서 벤더 세션을 버려서 다음 턴이 전체 범위를 Start 로 다시 보낸다 | 오류마다 세션이 어떤 상태인지를 typed 로 말하게 한다. Timeout/Process_exited 는 turn_accepted=false 이면 Pre_dispatch_failed 로, Rpc_error 는 단계(account/read, thread/start 전)를 필드로 받아 같은 규칙에 태운다. 문자열로 오류를 나누지 않는다. | 확인 |
| D2-06 | P2 | `lib/keeper/keeper_memory_os_recall.ml:32-47` | 09-29 RT-C3 | fact 하나가 바뀌면 recall block 전체(140~450KB)가 다시 나간다 | D2-02 의 RFC 안에서 함께 정한다. block 을 fact 단위로 나누면 '이 snapshot 이 이전 것을 대체한다'는 현재 문구의 뜻이 바뀌므로, 사라진 fact 를 어떻게 알릴지(withdrawn)도 같이 설계해야 한다. 작은 PR 로 나누지 않는다. | 확인 |
| D2-07 | P2 | `lib/keeper/keeper_agent_run.ml:1573-1620` | 09-29 MM-C3 | stage save 마다 canonical checkpoint 를 통째로 쓰고 history 3칸이 한 턴 안에 다 찬다 (Agent Core 레인) | 차이만 쓰는 저장(append-only 한 segment)이나 stage save 를 턴당 한 번으로 줄이는 방향을 RFC 로 정한다. history 3칸이 진짜 '이력'이 되는지 아닌지도 같이 정한다. 먼저 Agent Core 레인의 저장 횟수와 바이트를 세는 것은 이번 결함의 원인을 고치지 않으므로 단독 PR 로 하지 않는다. | 확인 |
| D2-08 | P3 | `lib/keeper/keeper_turn_driver.ml:1631-1640` | 09-29 MM-C2 | ?recovery_view 를 만드는 production 호출이 여전히 0곳이라 Some 분기가 전부 죽은 코드다 | Keeper_recovery_transmission 에서 require_reader 만 남기고 (또는 그 자리로 옮기고) 나머지와 ?recovery_view 인자·Runtime_agent.recovery_view·Runtime_recovery_projection 을 지운다. 다른 곳에서 부르는지 모듈 별칭까지 다시 확인한 뒤 지운다. | 확인 |
| D2-09 | P3 | `lib/keeper/keeper_official_client_host.ml:818-857` | 09-29 RT-C4 | resume 이 보내지 않은 범위를 'transmitted_bytes' 로 적는다 (라이브에서 9~12배 부풀려짐) | resume 이면 실제 보낸 범위(held 에서 뺀 뒤 남은 block 바이트)를 재서 넘기고, Start 만 범위 바이트를 넘긴다. 로그 이름도 뜻에 맞게 나눈다(범위 크기 대 전송량). 09-29 RT-C4 와 같다. | 확인 |

## D3 Librarian · Memory (생산·합성·소거·흡수·강화·반감기) · World Curator

가장 큰 결함은 #40019 가 남긴 Continuity(하던 일 저장본) 회차 고장입니다. 19/27 Keeper 는 저장본 다음 자리가 "끝 줄 없는 시작 위치"인데, 저장 코드는 끝 줄만 찾습니다. 그래서 모델을 부른 뒤에야 "no completed history range from a witnessed restart"로 저장이 거절되고, 다음 신호마다 같은 입력을 다시 보냅니다. 09-30 이 경고가 4,316건입니다(09-26~29 는 0건). 17시 이후 Librarian 실행 3,078건 중 약 1,070건(35%)이 같은 입력의 반복이고, 한 입력(284 KB)은 79번 갔습니다. 그 실행은 레지스트리에 모두 succeeded 로 남아 화면만 봐서는 안 보입니다. 반면 #40001(내용이 그대로면 snapshot 유지)은 잘 돕니다. 12:43 재시작 뒤 빈 커밋 1,444건 중 revision 이 오른 것은 3건입니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D3-01 | P1 | `lib/librarian_continuity_snapshot.ml:186-206` | 09-29 MM-C1 | Continuity 회차가 모델을 부른 뒤 저장에 실패하고 같은 입력으로 반복한다 (#40019 의 나머지 절반) | '끝 줄'과 '시작 위치'를 한 함수로 다룬다. | 열린 PR 이 다룸 · High |
| D3-02 | P2 | `lib/keeper/keeper_librarian_runtime.ml:1350-1372` |  | continuity 저장에 실패한 실행이 lane 기록에는 succeeded 로 남는다 | continuity 만 쓰는 실행은 publish_continuity 의 결과가 그대로 실행 결과가 되게 한다: 저장 실패면 Failed{code="continuity_not_committed"}. | 확인 |
| D3-03 | P2 | `lib/keeper/keeper_memory_os_current.ml:2613-2650` |  | 합성(absorb)이 09-30 07시부터 17시간 동안 0건이다 (원인 미확인) | 코드를 고치기 전에 원인을 가른다. 저장된 memory 회차 입력(exact-lane-run-payloads/*/input-*.json)을 같은 슬롯에 다시 돌려 absorbs 제안 수를 세는 재생 하네스를 먼저 만든다. 09-30 07시 전 입력과 뒤 입력을 같은 모델에 넣어 본다. 임계값이나 점수는 넣지 않는다. | 확인 |
| D3-04 | P2 | `lib/keeper/keeper_librarian_queue_refresh.ml:537-575` | 09-29 MM-M1 | Librarian 실행의 55% 는 기억을 바꾸지 않는 보조 회차이고, 회차마다 facts 전체를 다시 보낸다 | 자르기 전에 측정한다. continuity 와 working_context 답이 current_memory 없이도(또는 fact id 목록만으로) 같은 품질인지, 저장된 입력 payload 를 재생해 JEV 로 채점하는 하네스로 본다. 결과가 같을 때만 프롬프트 변수를 줄인다. | 확인 |
| D3-05 | P3 | `lib/keeper/keeper_memory_os_render.ml:40-51` | 09-29 MM-M3 | facts 한도(512 KiB)에 가까운 Keeper 2명이 있고, 한도에 닿으면 같은 range 로 모델을 신호마다 다시 부른다 (잠복) | 오류를 문자열이 아닌 닫힌 variant(Over_budget{actual; maximum; previous})로 바꾸고(MM-M4), 한도 위의 무변화 회차는 kept 비교를 먼저 하도록 순서를 바꾼다. | 확인 |

## D4 Skills 발행·발견·활성화와 재생성 (되풀이 풀이 → Skill)

기본 흐름은 돈다. 09-29 16시(KST)에 들어온 이벤트 원장은 31.5시간 동안 활성화 2,957건, 행 8,759개(4.2 MB), 경고 0건이다. 도구 로그와 건수도 맞는다(keeper_skill 성공 445 대 원장 439, 실패한 compose 호출도 기록됨). Keeper 가 직접 발행한 Skill 은 6건(09-23~29)이고 거절 0건이다. 라이브에서 지금 일어나는 문제는 하나다. 가장 많이 도는 Skill(work-intake, 활성화의 63%)의 보드 칸이 Keeper 가 쓴 글을 전부 뺀다(D4-01, P2). 나머지 항목의 최종 심각도는 아래 표를 따른다. 물음별 답. 1) 되풀이 풀이를 Skill 로 자동으로 묶는 기능: 코드가 없다. 판정은 미구현이다(09-29 표의 미연결은 라벨 정정). 있는 것은 프롬프트 한 문단(config/prompts/keeper.md:66), 발행 도구 keeper_skill_publish, 활성화 원장이다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D4-01 | P2 ←P1 | `skills/work-intake/SKILL.md:19,138-143` |  | work-intake 의 보드 칸이 Keeper 가 쓴 글을 전부 뺀다 | skills/work-intake/SKILL.md 한 파일 PR. board 노드에서 exclude_automation 줄을 지우고 exclude_system=true 를 넣어 영수증을 뺀다. 자기 글 되읽기가 걱정이면 composition param 하나(keeper_name)를 만들어 exclude_author 에 넘긴다. | 확인 · High |
| D4-02 | P2 | `lib/keeper/keeper_skill_activation_projection.ml:27-36` | #40242, #40263, #40325, #40328 (bin/masc_tui_render_tools.ml 를 같이 고침); 09-29 MM-S2 (같은 뿌리: 원장을 읽는 길이 늘수록 다시 계산) | 활성화 원장이 대시보드·TUI 응답에 통째로 실리고, 요약은 활성화 수의 제곱으로 계산된다 | 작게 나눈다. PR1: summarize_by_scope 를 Hashtbl 로 한 번 훑게 고친다(ledger.ml 한 파일). PR2: TUI 는 디코드할 때 요약을 한 번만 계산해 상태에 두고 그릴 때는 읽기만 한다. | 확인 |
| D4-04 | P2 | `lib/server/builtin_skill_judgement.ml:60-96` | #40044 (defer 된 composition 시험, 같은 defer 경로) | 라이브 builtin Skill 6개가 release 보다 낡았다. skill-authoring 은 'Keeper 발행 불가'라고 적혀 있다 | 운영자: masc skills-refresh skill-authoring browser-navigate-read browser-live-follow-read browser-lanes sangokushi-3 sangokushi-3-end-month 를 돌리고, dos-play 는 라이브 사본이 옛것이면 같은 명령으로 바꾼다(백업이 남는다). | 확인 |
| D4-07 | P2 | `docs/rfc/RFC-keeper-skill-peer-signal.md (제안 1, 결정 2026-09-24)` |  | Accepted 된 발행 근거 RFC 가 코드 0줄이라 Keeper 가 낸 발행 근거가 30일 뒤 사라진다 | 작게 나눈다. PR1: 발행 성공 뒤 같은 폴더에 publication.json(발행자, evidence, reference)을 쓴다. 실패해도 발행은 막지 않고 결과에 typed 로 싣는다. PR2: 편집기 삭제가 SKILL.md 와 함께 옮긴다. | 확인 |
| D4-03 | P3 | `scripts/skill-usage-stats.py:50-123,175` | 09-29 MM-S3 | Skill 사용량을 세 곳이 세 기준으로 세고, 스크립트는 '한 번도 안 쓴 Skill'을 잘못 알려 준다 | 스크립트: 출력에 '창: 첫 활성화 시각 ~ 마지막'을 찍고 문구를 '이 창에서 활성화 없음'으로 바꾼다(scripts 한 파일). 서버·TUI: Skill 신원 기준 합계를 맨 위에 보이고 revision 별은 그 아래에 둔다. 세 곳의 계산은 RFC 단계 2(OCaml rollup 하나)로 합친다. | 확인 |
| D4-05 | P3 | `lib/keeper/keeper_durable_store.ml:735-779` | 09-29 MM-S4 | 원장 파일이 부팅 검사 목록에 없고, 원장 쓰기가 실패하면 Skill 읽기와 합성 실행이 막힌다 | PR1: Keeper_durable_store.Id 에 Skill_activation_events 를 더하고 Preflight_only 로 traces/*/skill-activation-events.jsonl 을 load_existing_read_only_from_root 로 읽는다(모든 match 를 컴파일러가 확인한다). | 확인 |
| D4-09 | P3 | `lib/keeper/keeper_agent_run.ml:1795-1800` | 09-29 MM-S1 | 모델 응답마다 Skill 과 상관없이 원장 잠금과 파일 읽기를 한다 | observe_delivery 가 먼저 프로세스 안 복사본(remembered_session_log)에서 이 turn_ref 의 미전달 활성화가 있는지 본다. 없으면 잠금 없이 돌아간다. 이 프로세스의 활성화 기록은 모두 그 복사본에 들어가므로 판정은 같다. 복사본이 없으면 지금 경로를 탄다. | 확인 |
| D4-11 | P3 | `lib/keeper/keeper_skill_observability.ml:31,204,225,305,308,311` | 09-29 MM-S6 | Skill 종류와 실행 방식이 문자열로 저장되어 같은 파일 안에서 다시 문자열로 비교된다 | Workspace_skill_publish 에 type kind = Instruction_skill \| Composition_skill 을 두고 profile 도 typed 필드로 바꾼다. 문자열은 to_yojson 에서만 만든다. 두 PR 로 나눈다: profile, 발행 결과. | 확인 |

## L1 토큰·캐시·Skills·재전송 낭비 실측 (라이브)

측정 시각 09-30 23:30~23:50 KST. 로그·turn-records·metrics 는 UTC 날짜 파일이다(09:00 KST 에 넘어감). 표의 09-30 은 00:00Z~14:30Z, 14.5시간이다. 코드는 스냅샷 727fc53123, 라이브 소스는 4b881ab570. [1] 재전송. 09-29 감사의 Codex 263.5 MB / Claude Code 182.6 MB 는 `Codex|Claude Code turn composition: mode=resume prompt_bytes` 의 합이고, 09-29 00:00Z~약 12:35Z 부분 하루였다(그 시각까지 합이 257.8/176.5 MB 에서 이어져 맞는다). 전체 UTC일은 Codex 424.2 MB, Claude Code 200.7 MB 다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| L1-01 | P2 | `lib/keeper/keeper_librarian_queue_refresh.ml:537-565` | 열린 PR 없음 | Librarian 이 깨어날 때마다 모델을 최대 세 번 부르고, 세 번 모두 저장된 사실 전체를 다시 보낸다 | 한 번 깨울 때 한 번만 부른다. 출력 스키마 하나에 memory 처분, working context, continuity 상태를 함께 받는다. 세 호출이 같은 입력을 세 번 만드는 구조가 원인이다. 합치면 실패가 서로 묶이는 비용이 있어, 합치기 전에 continuity 실패(L1-02)를 먼저 고친다. | 확인 |
| L1-02 | P2 ←P1 | `lib/librarian_continuity_snapshot.ml:145-206` | 열린 PR 없음 | continuity 회차 모델 호출 728회가 저장 단계에서 전부 실패한다 (D3-01 의 비용) | D3-01 의 원인 수정(범위 시작 위치 계산)이 먼저다. 그와 별개로 저장 가능 여부(`source_range` 판정)를 모델 호출 전에 확인한다. 저장할 수 없는 회차는 호출하지 않고 `Uncovered_history` 를 그 회차의 결과로 남긴다. 저장 실패를 registry outcome 에 반영한다. | 확인 · High |
| L1-03 | P2 ←P1 | `lib/keeper/keeper_lane_cli_oneshot.ml:222-247` | 열린 PR 없음 (#40172, #40139 은 같은 파일을 건드리지만 주제가 다름); 09-29 RT-R1 | Librarian 이 소진된 계정 세 곳을 회차마다 다시 불러 3시간 동안 2,274회 실패했다 | 소진 기록(Runtime_quota_window.active_until/is_exhausted)이 있는 슬롯을 walk 에서 건너뛰고, 남은 슬롯이 없으면 그 회차를 `Rested` 로 끝내 호출하지 않는다. 다음 성공이나 창 끝에서 다시 시작한다. 절충: 모듈 문서가 일부러 관문으로 만들지 않았다. | 검증 갈림 · High |
| L1-04 | P2 | `lib/exact_lane_run_registry.mli` | 열린 PR 없음 | exact lane 모델 호출은 token 사용량을 어디에도 남기지 않는다 | exact lane 응답의 provider usage(입력, 출력, 캐시 읽기)를 완료 기록에 그대로 적는다. 없으면 null 로 적고 0 으로 채우지 않는다. 별도 모델 호출 집계기를 새로 만들지 않는다. L1-01 의 수정 효과도 이 값으로 잰다. | 확인 |
| L1-05 | P2 | `lib/keeper/keeper_unified_metrics_snapshot.ml:48-80` | 열린 PR 없음 | metrics 의 usage 라벨은 turn 결과에서, 숫자는 사용량 해석에서 와서 같은 행이 숫자는 있는데 unavailable/missing 이라고 적는다 | scope 와 trust 를 usage_resolution 에서만 만든다. run_result.usage_scope 는 해석이 없을 때만 쓰고, 두 곳에서 정하는 지금 구조를 없앤다. delta 가 있는 행은 그 basis 의 scope 로 적는다. 소비자는 라벨을 다시 보지 않게 한다. | 확인 |
| L1-08 | P2 | `lib/keeper/keeper_memory_os_recall.ml` | 열린 PR 없음; 09-29 MM-M3 | recall block 과 도구 스키마가 Codex 창의 95% 를 채워 세 Keeper 가 2~3턴마다 compaction 한다 | recall 에 넣는 사실을 창 안에서 고르는 기준을 Librarian 이 사실마다 남기는 상태(현재/과거/약함)로 정한다. 크기 상한으로 자르지 않는다. 지우지 않고 계속 자라는 원인은 D3 가 다룬다. 도구 표면은 defer_loading 을 더 쓴다. 이 세 수치는 한 원인의 세 얼굴이라 각각 고치지 않는다. | 확인 |
| L1-09 | P2 | `lib/keeper/keeper_hooks_agent_core_cost_events.ml:21-25` | 열린 PR 없음 | costs 원장은 비용을 모를 때 0.0 을 적고 그 값을 보고 출처를 정한다 | Cost_ledger 의 cost_usd 를 option 으로 바꾸고 모르면 null 로 적는다. 출처는 값이 아니라 usage_resolution.status 에서 가져온다. 합산기는 null 을 0 으로 더하지 않는다. | 확인 |
| L1-06 | P3 | `lib/keeper/keeper_official_client_host.ml:1144-1152` | #40172·#40139 이 인접 파일을 건드리나 이 필드는 안 고침; 09-29 RT-C4 | `transmitted_bytes` 는 이어받기 요청이 보낸 크기가 아니라 carried range 크기다 (RT-C4 열림) | 이어받기 레인은 보낸 바이트를 요청 본문(prompt + 새로 보낸 block)에서 재고, carried range 크기는 다른 이름 필드로 분리한다. 같은 이름으로 두 뜻을 섞은 것이 원인이다. 소비자(forecast, continuity 관찰, TUI 띠)는 보낸 크기 하나만 읽게 한다. | 확인 |

## D5 Schedule · Event queue · Drain Queue · 자율(Autonomous/Proactive)

Schedule 은 하루 약 1,000회 발화하고 dispatch 실패는 하루 1건 이하예요. interval + delivery none 이 큐에서 곱해지던 문제는 self-clock hold 와 supersede 로 막혀 있어요(큐 깊이 최대 13, schedule_due 는 Keeper 당 1개). #40006 으로 RT-S1·S2·S7 이 닫혔고 #39998 로 TU-F04 가 닫혔어요. #40022·#40026·#40034 캐시는 틀린 곳을 못 찾았어요. 가장 큰 새 결함은 D5-01 이에요. #39975 가 goal_notification 종류를 지운 뒤 e-masc-the-leader 의 대화 저장이 통째로 막혀서 4시간 넘게 DM·멘션·TUI 메시지를 못 받아요(수정 PR #40337 은 미병합, 서버가 23:08 에 다시 떴어도 15:11Z 까지 계속). 나머지는 낭비와 끝없이 느는 파일이에요.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D5-01 | P0 | `lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml:188` | #40337 (ready, 09-30 13:41Z, 미병합, 라이브 미배포). 방식은 지운 종류의 디코더를 되살리는 거예요. | 리더 Keeper 의 대화 저장이 막혔어요: 지운 goal_notification 종류가 디스크에 1줄 남아 있어요 | 1) 지금: #40337 을 병합하거나, 운영자가 그 1줄을 정리해요(라이브 파일은 감사에서 안 건드렸어요). 2) 근본: 종류를 지우는 PR 은 디스크에 남은 그 종류의 행을 같이 정리하게 하고, append 와 load_all 이 못 읽는 줄을 같은 규칙으로 다루게 해요(둘 다 그 줄만 버리고 로그·지표로 남기기). | 확인 · High |
| D5-02 | P2 | `lib/schedule/schedule_store.ml:438` |  | schedules.json 을 회차 하나에 3번, 통째로, 2파일에 다시 써요 | PR 1) 노트를 원장에서 빼서 append-only 파일로 옮겨요(원장 -2.2MB). PR 2) 끝난 wake 도 같은 방식으로 옮겨요(코드 주석도 '끝난 wake 는 이력이지 상태가 아니다'라고 적어요). PR 3) 같은 tick 에 바로 dispatch 하는 일정은 Due 를 쓰지 않고 start 한 번에 처리해요. | 확인 |
| D5-03 | P2 | `lib/keeper_runtime/keeper_event_queue_state.ml:422-451` | 09-29 RT-S3(관련, #38765 이 새 행만 막음) | 큐 상태 파일 무게의 86%가 더는 안 쓰는 옛 행이고, 전이마다 통째로 다시 써요 | mark_transition_projected 가 새 행에 쓰는 규칙(같은 operation id 의 paused-work 영수증이 있는 행만 유지)을 남은 목록 전체에 적용해요. 새 숫자도 문자열도 없고 이미 있는 판정 함수를 재사용해요. | 확인 |
| D5-04 | P2 | `lib/keeper/keeper_reaction_ledger.ml:168-180` | 09-29 RT-S3 | 회차 영수증 파일이 계속 쌓이고 지우는 코드가 없어요 | Schedule_runner 가 signal_keys 를 정리할 때 쓰는 '현재 회차 키' 규칙을 재사용해서, 어느 일정의 현재 회차도 아닌 occurrence 의 영수증을 지워요. 새 상수가 필요 없어요. | 확인 |
| D5-07 | P2 | `lib/schedule/schedule_store.ml:905-925` |  | 취소만 되고 한 번도 안 돈 일정, 원장에서 사라진 일정의 노트가 영원히 남아요 | 취소 시각을 취소 기록에 넣어서 같은 7일 규칙에 태워요(새 필드는 fresh-state 기준이라 지금 있는 340행은 운영자가 prune_completed 로 한 번 정리). 노트는 D5-02 의 노트 파일 분리로 비용을 없애요. 노트 개수 cap 은 만들지 않아요. | 확인 |
| D5-08 | P2 | `lib/keeper/keeper_owner.ml:438` | 09-29 RT-S4 | autonomous_deferral_debt_cap = 3 은 5분 주기 시절 숫자이고 지금은 wake 개수를 세요 | RFC-0373 방향 1 로 가요. 이미 있는 autonomous_lost_slot(자율 lane 이 막혔다는 사실)을 release 때 읽어 자율 lane 에 먼저 슬롯을 줘요. 숫자 없이 typed 값 하나로 판정해요. 로그는 실제로 chat 을 보류한 때만 찍어요. | 확인 |
| D5-10 | P2 | `lib/server/server_routes_http_routes_activity.ml:159-162` | 09-29 TU-F14 | TUI·대시보드에서 일정을 고치면 result_delivery 가 none 으로 바뀌어요 | update 에서 payload 에 result_delivery 가 없으면 저장된 값을 그대로 두는 함수 하나를 만들고, 지우려면 명시적으로 none 을 보내게 해요. HTTP 와 keeper·MCP 세 곳이 같은 함수를 써요. | 확인 |
| D5-11 | P2 | `lib/server/server_schedule_consumers.ml:403-417` | 09-29 RT-S6 | resolve_keeper_wake_target 은 아무것도 안 하는데 agent_name 연결을 한다고 적혀 있어요 | 함수와 죽은 분기를 지우고 body_keeper_name 을 그대로 써요. 연결이 필요해지면 그때 typed 로 설계해요. | 확인 |
| D5-12 | P2 | `lib/tool_schedule.ml:742-743` |  | Keeper 가 CI·PR 상태를 자기 일정으로 기다려요: 하루 약 210 turn 을 깨워요 | CI 완료·PR 변경을 큐 자극으로 넣는 producer 를 board_signal 처럼 하나 만들어요. 큰 설계라서 RFC 먼저 쓰고 Keeper 별 폴링 일정은 그 뒤에 줄여요. 일정 개수를 막는 cap 은 만들지 않아요. | 확인 |
| D5-05 | P3 | `lib/keeper/keeper_reaction_ledger.ml:158` |  | reaction ledger 는 보존 기간이 없고, 처음 보는 stimulus id 마다 전체를 처음부터 읽어요 | wake 의 상태는 큐 상태와 회차 영수증으로 답하고, ledger 는 wake 보존 기간(runtime param schedule_terminal_retention_days)에 맞춰 retention 을 둬요. 설계가 걸려 있어서(#33798 의 'already_acked 는 오래전 stimulus') RFC 에 먼저 적는 게 좋아요. | 확인 |
| D5-06 | P3 | `lib/schedule/schedule_runner.ml:135` | 09-29 RT-S8 | schedules/signals 는 하루 1.6~1.9MB 씩 늘고 읽는 곳은 최근 20행뿐이에요 | signals 저장을 없애고 대시보드가 wakes 에서 그리게 해요. 남기려면 보존 기간을 runtime param schedule_terminal_retention_days 로 이어요. | 확인 |
| D5-09 | P3 | `lib/keeper/keeper_heartbeat_loop.ml:834-838` |  | chat 에 막혀 미뤄진 cycle 이 30분 자율 경계를 써 버리고, 풀렸다는 wake 는 자율 turn 없이 Skip 돼요 | 경계를 그냥 남기면 periodic_remaining 이 0 이 되어 chat 이 도는 동안 cycle 이 바쁘게 돌아요. 그래서 Turn_busy 일 때만 '경계가 밀렸다'는 typed 표시를 남기고(periodic_cadence 에 variant 하나 추가), 다음 Woken cycle 을 Periodic_tick 으로 취급해요. | 확인 못 함 |

## D8 Candle 원장 · 논공행상 분배 · 반감기 · Economy(turn spend·cost ledger)

Candle 은 라이브에서 꺼져 있다. candle.toml 이 없고, 23:45 부팅 로그(masc-start-0930-2345.log:124)에 `candle: off (no candle.toml)` 가 찍혔다. 라이브 서버는 브리프의 4b881ab570 이 아니라 23:45 에 ccef0a8dab 으로 다시 떴다. D8 파일은 스냅샷 727fc53123 과 그 소스가 같다(달라진 것은 헌법·용어집뿐이다). 돈이 나가는 코드(Snapshot → PayoutOwed → Candidates → 모델 판정 → Paid/Unattributed/Payout_failed → 잔액)는 main 에 이어져 있다. 이중 지급, 몫 합계, 오버플로, 수령 자격은 코드로 따라가 봤고 새 결함을 못 찾았다. 열린 결함은 다섯 가지다. (1) Disabled 하나에 '꺼 둠'과 '지금 못 읽음'이 섞여서 Goal 이 Snapshot 없이 통과할 수 있다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D8-01 | P2 ←P1 | `lib/dashboard/dashboard_http_keeper_feeds.ml:130-175` |  | Usage 24시간 표가 실패한 시도의 토큰을 뺀다 | Usage 표의 원천을 한 곳으로 모은다. 서버의 keeper-costs 가 cost 원장(`Cost_ledger.of_json` 로 읽고 raw 줄은 건너뜀)의 `resolved_delta` + `resolved_attempt_delta` 를 창 안에서 더하게 한다. 미보고 비용은 지금처럼 null 로 둔다. | 확인 · High |
| D8-02 | P2 | `lib/keeper/keeper_hooks_agent_core_cost_events.ml:106-107` |  | 비용이 없는 lane 을 '보고 안 됨'으로만 적고, 합계는 0.0 으로 굳힌다 | 둘 중 하나로 정한다. (가) runtime 선언에 과금 종류(닫힌 variant)를 두고 거기서 `Cost_known_free` 를 내보낸다. (나) 쓰지 않을 변형과 상수 인자를 지운다. 어느 쪽이든 `cost_usd` 는 `float option` 으로 두고, meta 합계는 '아는 비용의 합 + 모르는 횟수' 두 값으로 저장한다. | 확인 |
| D8-05 | P2 | `lib/candle_runtime/candle_status.ml:47-57` | #40302 (lane 확인 일시 실패 (가)만 for_recording 으로 고침. (나)(다)는 그대로. Draft, 컴파일 미확인) · 이슈 #40054, #40061 | Disabled 하나에 '꺼 둠'과 '지금 못 읽음'이 섞여 Goal 이 Snapshot 없이 통과한다 | 닫힌 sum 으로 나눈다: `Off \| Enabled \| Misconfigured of reason`. 기록 경로는 Off 만 건너뛰고 Misconfigured 는 전이를 거절한다(원장 읽기 실패가 이미 전이를 거절하는 것과 같다). lane 확인은 기록 경로에서 아예 빼고 지급 경로에서만 본다. | 열린 PR 이 다룸 |
| D8-06 | P2 | `docs/rfc/RFC-goal-candle-ledger.md:361-408` |  | 모델 판정이 돈이 되는데 RFC 가 요구한 반복·주입 시험이 main 에 없다 | 켜기 전에 하네스를 만든다. 같은 입력을 여러 번 넣은 결과와 지시문을 넣은 입력의 결과를 표로 남겨 사람이 읽고 판단한다. 판단 자리에 합격 숫자를 붙이지 않는다. 결과는 docs/evidence 에 둔다. lane 슬롯이나 프롬프트를 바꾸면 다시 돌린다. | 확인 |
| D8-07 | P2 | `lib/candle_runtime/candle_appraise.ml:39-77` | #40302 는 '거절된 요청을 pulse 로 다시 깨우지 않음'만 다룸(부분 결과 기억과 영구 실패는 안 다룸) | 재시도가 부분 결과를 기억하지 않고, 영구 실패에는 나갈 길과 보이는 곳이 없다 | (가) 판정 결과를 `Candidates` 처럼 단계마다 원장 사실로 남기거나(등급 → 관계 → 가중치), 한 번에 끝나게 묶는다. 캐시나 cooldown 은 근본 수정이 아니다. | 확인 |
| D8-08 | P2 | `lib/candle/candle_payment.ml:44-67` | #40302 (Draft, 컴파일 미확인) · #40066 (base 가 열린 스택 브랜치); 09-29 이슈 #40056 | Paid 디코더가 산수를 다시 계산해서, 산식을 고치면 옛 줄 때문에 원장 전체를 못 읽는다 | 읽을 때는 영수증 불변식(몫 합 = 총액, 범위, 0 가중치 몫 0)만 검사하고 산식을 다시 돌리지 않는다. 산식 검증은 새 줄을 쓸 때만 한다. #40302 의 `validate_receipt` 와 `validate_for_append` 가 이 모양이다. | 열린 PR 이 다룸 |
| D8-11 | P2 | `lib/candle_runtime/candle_status.ml:59-63` | #40024 (잔액·발행량, base 가 열린 스택 브랜치) | Candle 상태·원장·지급 대기 목록을 볼 곳이 하나도 없다 | 읽기 전용 route 하나로 `Candle_status.current` 의 답, 지급 대기 Goal 과 마지막 실패 이유를 내보내고 TUI 는 그것을 그린다(상태를 새로 저장하지 않는 projection). 원장 잔액·발행량 화면은 #40024 가 이미 있다. | 확인 |
| D8-12 | P2 | `lib/goal/goal_due.ml:28-52` |  | 라이브 Goal 하나의 기한이 읽을 수 없는 형식이라, 켜면 지급이 실패하고 지금도 지연 표시가 안 뜬다 | 코드 수정이 아니라 데이터 정리다. 켜기 전에 `masc_goal_upsert` 로 due_date 를 `2026-09-29` 로 고친다(제목·metric·target 이 안 바뀌면 phase 가 그대로다). 지금 Goal 전체에서 읽을 수 없는 기한이 더 없는지 같이 본다. | 확인 |
| D8-03 | P3 | `lib/keeper/keeper_hooks_agent_core.ml:207-225` |  | cost 원장의 80.5%가 아무도 읽지 않는 raw 줄이고 보관 기한도 없다 | raw 줄이 맞는지 검증하는 용도인지, 연구 자료인지 먼저 정한다. 검증 용도면 raw 로 resolved 줄을 다시 계산해 맞는지 보는 시험과 읽는 코드를 만든다. 아니면 raw 줄을 별도 store 로 옮기고 보관 일수를 준다. 판정 근거가 없는 상태로 계속 쌓지 않는다. | 확인 |
| D8-04 | P3 | `lib/keeper/keeper_turn_spend_commit.ml:26-52` | 09-29 DM-CD-4 | DM-CD-4 상태: meta 를 먼저 커밋하고 원장 쓰기가 실패하면 카운터와 로그만 남는다 | 카운터를 더하지 않는다. meta 총합을 원장에서 계산하게 해 세는 곳을 하나로 줄이거나, 원장 쓰기 결과를 `Result` 로 올려 meta 커밋과 함께 판정한다. D8-01 의 Usage 표 통합과 같은 PR 묶음에서 다룬다. | 확인 |
| D8-10 | P3 | `lib/candle/candle_balance.ml` | #40365 (root, Item 스택 38개 위에 쌓임) | 구매·지갑·착용 코드가 main 에 없고, keeper 는 지급받은 것을 알 길이 없다 | 스택을 작게 나눠 아래부터 머지한다. #40365 를 먼저 리뷰하고 그 위 PR 은 리뷰로만 진행한다(MASC 실행 규약). 잔액은 keeper 가 도구로 조회할 때만 보이게 한다는 RFC 3.7 을 지키고, 지급 알림은 keeper queue 의 일반 메시지로 한다(의무나 재시도 없이). | 열린 PR 이 다룸 |

## D6 Board 주의(attention) · 판정(verification) · Task 완료 루프

발견 11개(P1 3, P2 8). 핵심은 셋입니다. (1) Board attention 대기열이 닫히지 않습니다. 09-30 에 만든 후보 18,829개 중 13,329개(71%)가 아직 pending 이고, 만든 뒤 처리까지 걸린 시간 중앙값이 09-27 13초에서 09-30 12.9시간으로 늘었습니다. (2) 요청이 나가지도 못한 DNS 실패(`not sent`)가 입력 문제처럼 분류돼 파티션이 Blocked 로 굳고, 운영자가 후보마다 한 번씩 풀어야 합니다. 지금 1,154개입니다. (3) 판정 lane(`verifier_exact`)은 슬롯이 하나라서, 09-30 에 판정 못 낸 시도가 469번(그중 330번은 900초 무응답)이고 판정은 18건뿐입니다. 판정을 기다리는 Task 는 35개입니다. Q1 의 `operator_routed` 는 회귀가 아니라 #39244 가 지운 variant 의 찌꺼기입니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D6-01 | P1 | `packages/agent_core/lib/llm_provider/exact_output.ml:1926-1943 (execution_cause_is_binding_rest, NetworkError/TimeoutError 는 dispatch 를 보지 않고 false)` | 09-29 DM-BD-3 | 요청이 나가지도 못한 DNS 실패가 입력 문제로 분류돼 Board attention 파티션이 Blocked 로 굳는다 | PR1 (작게): `execution_cause_is_binding_rest` 가 `Completion_failed { dispatch = No_generation_dispatch }` 를 '지금 못 보냄'으로 보게 하고(exhaustive match 유지), `lane_disposition` 이 그 경우… | 확인 · High |
| D6-02 | P1 | `lib/keeper/keeper_board_audience.ml:80-110 (Discoverable → Judge_discoverable, board_interests 가 있으면 전원)` |  | Board attention 대기열이 줄지 않는다: 처리까지 중앙값 13초 → 12.9시간 | 코드를 고치기 전에 RFC 로 두 질문을 정합니다. (a) 판정 단위를 (신호, keeper) 쌍이 아니라 신호 하나로 바꿀 수 있는가. 디코더가 verdicts 목록을 이미 받으므로 한 호출에 여러 keeper 의 후보를 넣는 방향이 자연스럽습니다. (b) Jev 의 not_relevant 를 끝으로 볼 것인가(D6-10). | 확인 · High |
| D6-03 | P1 | `lib/completion_authority_agent.ml:1039-1088 (retry_delay_of_path_rest, schedule_retry)` | 09-29 DM-verifier | verifier_exact 재시도가 닫히지 않는다: 하루 469번 시도, 판정 18건, 900초 무응답 330번 | 운영자 결정 두 가지는 그대로입니다: 슬롯을 하나 더 두거나 capabilities 를 적는 것. 코드 쪽은 RFC 로 '슬롯이 하나뿐인 lane 의 재시도를 무엇이 닫는가'를 정합니다. 타이머(pulse)가 아니라 상태 변화(다른 슬롯 성공, 운영자 조치)로 닫는 쪽을 검토합니다. | 확인 · High |
| D6-04 | P2(조사 우선순위) | `config/prompts/judge.md (#39970, 2줄)` |  | 하루 300건대 격리를 관측했다. #39970 프롬프트 수정의 효과는 측정하지 못했다 | 효과를 판단하려면 같은 길이의 전후 관측 구간, 전체 시도 수, 같은 분류 기준의 invalid-output 수, 요청에 실제 적용된 프롬프트 revision(override 포함)과 모델을 확인한다. PR 병합 시각만으로 적용 여부나 실패율 변화를 판단하지 않는다. | 관측값 유지 · 프롬프트 효과 확인 필요 |
| D6-05 | P2 | `lib/board/board_audience.ml:93-110` |  | 판정 정체 알림이 producer 에게 주소를 붙이지 않아 keeper 전원이 판정 비용을 낸다 | 알림 본문 첫 줄에 producer 를 `@<assignee>` 로 적어 `Explicit_targets` 가 되게 합니다(Board_addressing 문법이 이미 처리). Goal 알림도 같은 방식으로 owner 를 적습니다. board_audience.ml 주석은 실제 동작에 맞게 고칩니다. | 확인 |
| D6-06 | P2 | `lib/keeper/keeper_board_attention_candidate.ml:1752-1761 (compaction_ratio = 2, needs_compaction), 1788-1800` |  | attention 후보 원장이 줄어드는 길 없이 커진다: 307MB, 후보마다 Board 본문 전체 | RFC 로 정합니다. 후보는 (post_id, comment_id, 내용 revision)을 참조하고 본문은 Board 에서 읽는 쪽, 그리고 consumed 후보를 판정 증거만 남기고 live 집합에서 빼는 쪽입니다. '먼저 영속화한다'는 헌법 규칙은 참조로도 지켜집니다. 삭제된 글의 판정 증거 보존 방식이 정해져야 합니다. | 확인 |
| D6-08 | P2 | `lib/verification_run_registry.ml:226, 285 (unknown verification outcome)` |  | verification-runs.jsonl 의 `operator_routed` 19줄이 원장 압축을 4일째 막고 있다 | 운영자 작업 한 번: 서버를 멈추고 네 원장(exact-lane-runs-v6, fusion-runs, verification-runs, goal-verification-runs)을 백업한 뒤 `cut-run-registries` 를 dry-run 으로 본 다음 `--execute`. | 확인 |
| D6-09 | P2 | `lib/keeper/keeper_tool_task_runtime.ml:277-290 (크기만 미리 검사)` | 09-29 DM-verifier | 제출할 때는 받아 주고 판정할 때는 못 읽는 이미지 증거가 Task 를 AwaitingVerification 에 세워 둔다 | 제출 경계에서 lane 이 선언한 능력을 보고 거절합니다(task-540 크기 검사와 같은 자리, 같은 방식). 제출자가 바로 이유를 받고 텍스트 증거로 다시 낼 수 있습니다. 판정 쪽 코드는 바꾸지 않습니다. | 확인 |
| D6-11 | P2 | `lib/workspace/workspace_gc.ml:81-129 (write_backlog 114-123 → append_archive_tasks 129)` |  | Task GC 는 backlog 에서 먼저 빼고 archive 에 나중에 붙이며, GC 를 돌리는 스케줄도 없다 | 순서를 뒤집습니다: archive 에 먼저 붙이고 그다음 backlog 에서 뺍니다. 죽어도 두 곳에 남고 `append_archive_tasks` 가 id 로 중복을 없앱니다(락 두 번). 별도로 GC 를 언제 돌릴지 운영자와 정합니다(스케줄 없음). | 확인 |
| D6-07 | P3 | `lib/operator/operator_control_snapshot.ml:654-668` |  | 운영자 스냅숏의 quarantines 칸이 4초 걸린다 | 먼저 시간이 어디서 드는지 잽니다. 그다음 격리 목록을 파티션 원장의 Blocked 행에서 읽는 쪽을 검토합니다(후보 원장을 읽지 않음). D6-01 이 격리를 줄이면 같이 줄어듭니다. | 확인 못 함 |

## D7 Goal · HITL(Gate·승인·질문) · Access Control(auth·credential)

새 결함 6개(P0 1, P1 1, P2 4)와 P3 10개를 찾았습니다. 1) P0. #39975 가 Goal 알림 변형(goal_notification)을 지웠는데 e-masc-the-leader 대화 파일 3390줄에 그 행이 남아 있습니다. 그 Keeper 는 19:56 KST 부터 메시지를 저장하지 못하고, 지금(00:22 KST) 도 새 서버(ccef0a8dab)에서 같은 실패가 1분마다 납니다. #39975 changelog 가 요구한 데이터 정리 두 가지 중 goals.json 만 23:26 KST 에 끝났습니다. 열린 #40337 은 읽기용 변형을 다시 넣는 방식이라 하드컷 결정과 어긋납니다. 2) P1. Goal 검증기 lane(verifier_exact)은 슬롯이 하나(glm-5.3-flash)입니다. 멈춘 Goal 2개가 33~43시간째 Verifying 이고, 어떤 Goal 의 wake 든 멈춘 Goal 전부의 검토를 다시 돌립니다(deferred 36회, 900초 타임아웃 23회).

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D7-01 | P1 ←P0 | `lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml:123-190` | #40337 (draft, 호환 reader 를 되살리는 방식) | #39975 가 지운 goal_notification 행이 e-masc-the-leader 대화 파일에 남아 그 Keeper 의 저장이 전부 막힌다 | 1) changelog 가 이미 적어 둔 정리를 그대로 한다. e-masc-the-leader 를 세운 상태에서 3390줄의 delivery_key 와 transcript_slot 을 함께 지우고 본문은 둔다. 백업, atomic replace. | 확인 · High |
| D7-02 | P2 ←P1 | `<base>/.masc/config/runtime.toml:96-102 (operator 소유)` |  | Goal 검증기는 슬롯이 하나라 GLM 이 멈추면 Goal 이 Verifying 에 묶이고, 아무 wake 든 멈춘 Goal 전부를 다시 검토한다 | 1) wake 가 가리킨 goal_id 만 scan 한다(부팅의 첫 scan 은 전체). deferral 을 (Goal, 요청) 단위로 기억하고, 그 Goal 자신의 request_complete·reopen 이 오기 전에는 다시 검토하지 않는다. | 확인 · High |
| D7-05 | P2 | `lib/auth/auth_credential_token.ml:262-263` | #40171 (스택 #40174, #40182); 09-29 DM-PL-06 | credential 만료 판정이 4곳, 규칙 2개 | 만료 판정 함수 하나(파싱 실패는 Error)로 모으는 열린 스택 #40171→#40174→#40182 를 그대로 진행한다. 새 PR 은 만들지 않는다. | 열린 PR 이 다룸 |
| D7-06 | P2 | `docs/spec/00-glossary.md:525-531` |  | glossary 에 Keeper Owner 가 없고 owner 라는 말이 4가지 뜻으로 쓰인다 | glossary 에 Keeper Owner 를 한 항목으로 정의하고(Keeper 메타를 쓰는 유일한 fiber), 운영자 발신 권한 Owner 는 '운영자'로 이름을 바꾼다. RFC-0362 는 지우고 '폐기됐다' 문구는 남기지 않는다. | 확인 |
| D7-03 | P3 | `lib/server/server_routes_http_routes_dashboard.ml:3663-3666` |  | 질문 답변 route 가 Worker 권한으로 열려 있다 | tool-approval 처럼 숨은 admin 키(예: keeper_ask_answer_route, admin_tool)를 하나 만들어 이 route 에 쓴다. TUI 는 admin credential(masc-tui, 10-25 만료)이고 웹은 Admin dev-token 이라 깨지는 호출자가 없다. | 확인 |

## D12 perf 캐시 계층의 정확성 (09-27~30 perf 변경 전수)

perf 커밋 47개 중 캐시·재사용·offload 를 넣은 약 25개의 diff 와 테스트를 읽었습니다. 새 캐시가 옛 값을 내는 결함은 못 찾았습니다. 키에서 입력이 빠진 곳, 에러를 성공으로 저장하는 곳, 도메인 사이 경쟁, 권한별 바이트가 섞이는 곳은 이번 변경에는 없었습니다. 남은 문제는 그 주변입니다. (1) Board 목록 캐시가 고정·닫기·다시 열기·수정·삭제에는 무효화되지 않고, HTTP/2 도 이번에 같은 캐시를 타게 됐습니다. (2) 같은 일을 하는 파일 버전 캐시가 5개 사본으로 흩어져 있고 키가 서로 다릅니다. (3) Workspace_backlog 캐시가 전역 뮤텍스를 잡은 채 blocking stat 을 합니다. (4) 스스로 효과가 없다고 적은 perf PR 3개가 압축 파일 60 MB 를 git 에 넣었습니다. (5) Board 저장은 6.5 KB 가 바뀌어도 22.6 MB 를 통째로 다시 씁니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D12-01 | P2 | `lib/board/board_dispatch.ml:105-118` |  | Board 목록 캐시가 고정·닫기·다시 열기·수정·삭제 뒤에도 최대 15초 옛 목록을 냅니다 | board_sse_event 에 Post_edited, Post_pin_changed, Post_closed, Post_reopened, Post_deleted 를 더하고 위 5개 함수가 같은 hook 을 부르게 합니다. hook 쪽 match 는 exhaustive 로 두어 새 종류를 빠뜨리지 못하게 합니다. | 확인 |
| D12-02 | P3 | `lib/core/file_version_cache.ml:5-27` |  | 같은 일을 하는 파일 버전 캐시가 5개 사본이고, 키가 서로 다르며 고친 곳이 다른 사본에 안 퍼집니다 | File_version_cache 의 version 에 ctime 을 더합니다(같은 stat 한 번에 얻음). 그 뒤 사본을 한 PR 에 하나씩 옮깁니다. | 확인 |
| D12-03 | P3 | `lib/workspace/workspace_backlog.ml:61-62` |  | Workspace_backlog 캐시가 전역 뮤텍스를 잡은 채 blocking Unix.stat 을 합니다 | D12-02 의 이전 PR 에 포함합니다. Workspace_backlog 를 File_version_cache 로 옮기면 stat 이 뮤텍스 밖으로 나갑니다. 별도 우회는 만들지 않습니다. | 확인 |
| D12-04 | P3 | `docs/evidence/worker-support-task-index-2026-09-27/raw.tar.gz` |  | 효과가 없다고 스스로 적은 perf PR 3개가 압축 파일 60 MB 를 git 에 넣었습니다 | 세 tar.gz 를 git rm 하고 README, SHA256SUMS, summary.json 은 남깁니다(README 가 이미 CI run 번호와 artifact 해시를 적음). .gitignore 에 docs/evidence 의 *.tar.gz 를 추가합니다. | 확인 |

## L2 Drain Queue · 서버 로그 소음 · 부팅 신호 · Keeper 가동 (라이브)

라이브 서버는 지금 ccef0a8dab(09-30 23:45 KST 부팅)이라 브리프의 4b881ab570 이 아닙니다. 로그 파일 날짜는 UTC 기준입니다(09-29 파일 = 09-29 09:00 KST ~ 09-30 09:00 KST). 새 결함 두 개가 P1 입니다. (1) #40019 뒤로 Librarian 이어받기(continuity) 저장이 20명 Keeper 에서 매번 실패해요(L2-01). (2) #39975 가 지운 goal_notification 행 한 줄이 e-masc-the-leader 채팅 저장을 막고 있어요(L2-02). 둘 다 데이터를 손보라는 changelog 단계 또는 새 코드 경로가 원인이고, 지금 라이브에서 계속 일어납니다. Q1 Drain Queue: 옛 메모리("cadence 마다 자극 하나만 비운다")는 낡았습니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| L2-01 | P1 | `lib/keeper/keeper_librarian_range.ml:150-190` | 09-29 MM-C1 | #40019 뒤로 Librarian 이어받기(continuity) 저장이 20명 Keeper 에서 매번 실패해요 | capture_range 가 끝 줄을 다시 찾지 않고, prepare 단계가 이미 고른 covering_cut(cut_line, cut_turn_ref)을 그대로 쓰게 합니다. 끝점을 정하는 규칙이 range 한 곳에만 있게 됩니다. | 확인 · High |
| L2-02 | P1 | `lib/keeper_chat_delivery_identity/keeper_chat_delivery_identity.ml:188` | #40337; 09-29 TU-F18 | 지워진 goal_notification 행 한 줄이 e-masc-the-leader 채팅 저장과 멘션 전달을 막고 있어요 | 열린 #40337 은 지운 종류를 읽는 코드를 되살립니다. 하드 컷 규칙(호환 reader 를 만들지 않는다)과 어긋나고, 남은 데이터는 한 줄입니다. changelog 의 손 단계를 지금 실행하는 쪽이 맞습니다(서버 정지, 백업, 그 행의 delivery_key·transcript_slot 제거). | 열린 PR 이 다룸 · High |
| L2-03 | P2 | `lib/run_registry_core/run_registry_core.ml:751-765,784-800` |  | verification-runs.jsonl 의 읽을 수 없는 19행이 정리를 막아 파일이 계속 커지고 부팅마다 경고해요 | 지금은 서버를 멈추고 4개 run registry 파일을 백업한 뒤 cut-run-registries 를 실행합니다. 구조적으로는 preflight 검사가 'malformed 가 있으면 배포 실패'로 끝나게 하고 install-local-build.sh 가 그 검사를 부르게 합니다. | 확인 |
| L2-04 | P2 | `lib/runtime/runtime_exact_lane_backpressure.ml:54-61` | 09-29 DM-BD-3 | exact lane 의 쉼(rest)은 순서만 바꿔서 슬롯이 하나인 lane 은 쿼터가 막혀도 계속 호출해요 | 쉼을 순서 정렬이 아니라 '다음 호출 시각'으로 만들어, lane 의 모든 후보가 쉬는 동안은 호출하지 않고 대기열에 둡니다. Keeper turn 의 Wait_for_path_release 와 같은 규칙을 공용 함수 하나로 모읍니다. cap·cooldown·dedup 이 아니라 release 시각을 그대로 쓰는 방향입니다. | 확인 |
| L2-05 | P2 | `lib/server/server_bootstrap_loops.ml:2125-2160` |  | msx-retro-mania 가 이미지 승격 없음으로 16시간 부팅하지 못하고 30초마다 ERROR 만 남겼어요 | 거절 사유를 '기다리면 풀림'과 '사람이 해야 풀림'으로 닫힌 variant 로 나누고, 후자는 재시도를 멈춘 채 TUI 의 Keeper 상태에 그대로 보이게 합니다. 로그 중복 제거나 재시도 간격 늘리기는 근본 해결이 아닙니다. | 확인 |
| L2-08 | P2 | `assets/dashboard/.build-stamp` |  | 웹 대시보드 번들이 09-29 11:52 커밋에 멈춰 있어 부팅마다 경고해요 | install-local-build 가 dashboard 번들을 다시 만들게 하거나, 웹 대시보드를 쓰지 않으면 지문 검사와 경고를 함께 지웁니다. | 확인 |
| L2-09 | P2 | `lib/config/masc_network_defaults.ml:228-233` |  | Keeper 의 웹 검색이 일주일째 모든 provider 에서 실패해요 | searxng 를 띄우거나, 쓰지 않으면 provider 목록에서 빼 도구 설명이 실패할 도구를 광고하지 않게 합니다. | 확인 |
| L2-06 | P3 | `lib/exact_lane_run_registry.ml:423` |  | 읽고 쓰는 코드가 없는 파일이 약 1.2GB 남아 있어요 | 운영자가 v5 와 .atomic 5개와 autonomy_stats.jsonl 을 지웁니다(repo 밖 스크립트가 읽는지는 못 봤습니다). 코드는 부팅 때 .masc 루트의 atomic orphan 을 이미 있는 cleanup_atomic_orphans 로 한 번 치우게 합니다. | 확인 |
| L2-07 | P3 | `로그 이름을 짓는 시작 스크립트는 이 repo 에 없음(scripts/start-masc-supervised.sh 는 확인 안 함)` |  | 재시작마다 서버 시작이 두 번 불려 부팅 8번의 시작 로그가 덮이고 있어요 | 시작 로그 이름에 PID 나 초를 넣고, 재시작 경로가 시작을 한 번만 부르게 합니다. 어느 스크립트인지는 못 찾았습니다. | 확인 못 함 |

## D9 Portrait · Item Slot(착용) · 초상화 표시

P0·P1 결함은 없다. 09-29 발견 중 DM-PT-1(메달 잘림)과 DM-PT-2(보관 PNG)는 코드에서 닫혔다. DM-PT-3~7은 그대로 열려 있고 그중 3·4·5·6 을 P2 로 다시 올렸다. 새 결함은 P2 셋이다. (1) 모자이크용 축약 그림이 눈·방울·체형·장신구를 버린다(#39886). (2) 용어집과 주석이 이미 사라진 '시작 화면'과 '상단 바 축약 캔들'을 설명하고, 이 문장이 키퍼 메모리로 복사됐다. (3) 대시보드 설정 패널이 실제 초상화 대신 시길만 보여 주고 '초상화는 기획 단계'라고 적는다. #39987(아이템 둘러보기·PNG 미리보기)은 읽기 전용이고 권한(키퍼 자기 이름만), 입력 검사(size 48~512, 알려진 id 만), 자원(내용 주소 저장)에서 문제를 못 찾았다. 착용 저장·구매 코드는 main 에 없다. 구매·착용·지갑·TUI·대시보드는 열린 PR 약 40개 스택(#40008~#40288)에 있다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D9-04 | P2 | `docs/spec/00-glossary.md:296` |  | 이미 없는 '시작 화면'과 '상단 바 축약 캔들'을 용어집과 주석이 설명한다 | 용어집 두 문장에서 '시작 화면'과 '상단 바 축약 캔들'을 지운다(폐기 언급 없이 /about 과 키퍼 상세로 고친다). mascot 주석과 draw.ml, solid.ml 주석의 splash 도 고친다. 키퍼 메모리의 해당 claim 은 glossary-maniac 가 다시 쓰게 한다. | 확인 |
| D9-01 | P3 | `bin/masc_tui_keeper_portrait.ml:60` | #40010 (세 곳에 착용 상태를 넘기지만 호출은 셋인 채); 09-29 DM-PT-3 | 이름으로 외형을 계산하는 곳이 아직 셋이다 | Keeper_portrait_look 에 이름 → (body, equipment) 를 돌려주는 함수 하나를 두고 세 곳이 그것만 부른다. 착용 상태는 그 함수 바로 위 한 곳에서 덮어쓴다. RFC 3.6 의 '호출부 두 곳'은 세 곳으로 고친다. | 열린 PR 이 다룸 |
| D9-02 | P3 | `lib/keeper_portrait/keeper_portrait_look.ml:94` | 09-29 DM-PT-4 | 목록 길이로 index 를 골라서 항목이 늘면 이름의 절반쯤 기본 모습이 바뀐다 | 고정된 규칙으로 바꾼다. 예: 이름과 항목 id 를 함께 해시해 가장 큰 값을 가진 항목을 고른다(rendezvous). 항목이 하나 늘 때 바뀌는 이름은 1/(n+1) 이다. nothing_share 도 같은 방식의 후보 하나로 둔다. | 확인 |
| D9-05 | P3 | `dashboard/src/components/keeper-config-v2-blocks.ts:25-60` | #40010, #40288 은 keeper-detail-shell.ts, keeper-portrait.ts 를 건드리나 keeper-config-v2-blocks.ts 는 안 건드린다 | 설정 패널의 아바타는 시길이고 '초상화는 기획 단계'라고 적는다 | 설정 패널 미리보기를 KeeperPortrait 로 바꾸고 '초상화 프리셋·업로드 기획' 버튼과 '슬롯 색' 자리는 지운다. keeper.emoji 필드와 분기를 지운다. 시길(KeeperBadge)이 남아야 하면 초상화와 무관한 다른 이름으로 구분한다. | 확인 |
| D9-06 | P3 | `lib/keeper/keeper_portrait_read.ml:5-7` | #40288 (HTTP 파일 수정, 상수는 안 다룸); 09-29 DM-PT-5, DM-PT-6 | MCP 도구와 HTTP 경로가 같은 그림을 다른 규칙으로 그린다 | 기본 크기와 범위를 Keeper_portrait_draw 에서 한 번 정의하고 MCP 하한 48 만 이름 있는 상수로 남긴다. 배경 22 는 이름을 붙이거나 RGBA 그대로 보낸다. 이런 정리는 D9-01 의 공용 함수 PR 에 묶는다. | 확인 |

## D10 Play Invite · DOS 기계 조종권(Seat) · MSX · 외부 에이전트 안내

새 결함 5건(P1 1, P2 4). 가장 큰 것은 D10-01이다. 서버가 뜰 때 MASC_HTTP_BASE_URL 을 http://127.0.0.1:8935 로 미리 채워 두기 때문에, 초대 발급의 "공개 주소 없음" 검사(No_public_base_url)가 켜질 일이 없다. 라이브 GET /play/agent.md 가 200 이고 안내문의 주소가 전부 127.0.0.1 이다. 지금 초대를 발급하면 바깥 사람이 열 수 없는 링크가 나온다. 나머지는 msx/ 10.4GB의 원인(D10-02), 복원 못 하는 DOS autosave 안내와 죽은 체크포인트 26개(D10-03), 죽은 TUI 거절 해석 함수(D10-04), 운영자가 조종권을 강제로 풀 길이 없음(D10-05)이다. #40045(지운 Keeper 조종권)는 3개 삭제 사유 모두 finalize 에서 풀도록 되어 있어 새 결함이 없다. #39986(credential 락)은 재진입·교착 경로를 못 찾았다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D10-01 | P1 | `lib/server/server_bootstrap_http.ml:19-25` | #39891 (이슈: 값 모양 검사 없음). 이 결함을 다루는 열린 PR 은 못 찾음 | 초대 발급의 '공개 주소 있음' 검사가 켜질 수 없다. 링크가 127.0.0.1 로 나간다 | 운영자가 실제로 넣은 값을 부팅 첫머리(make_http_config 호출 전, server_runtime_bootstrap.ml:1633 위)에서 한 번 읽어 '명시한 공개 주소'로 따로 보관하고, 발급 route 와 안내 route 는 그것만 읽는다. | 확인 · High |
| D10-02 | P2 | `lib/msx_lane/msx_lane.ml:780-811,863-916` |  | msx/saves 2075개 10.4GB: 비압축, 같은 디스크 이미지와 ledger 를 저장마다 되풀이, 상한·삭제 없음 | MSX 저장·복원을 Machine_checkpoint(Msx 는 이미 있음)로 옮긴다. meta 에는 ledger 와 매체의 sha256 목록만 두고, 디스크 이미지는 sha256 이름으로 한 번만 저장한다. | 확인 |
| D10-03 | P2 | `lib/dos_lane/dos_lane.ml:525,1058-1082,1149-1165` |  | 복원 못 하는 DOS autosave 를 'resume with masc_dos_restore slot=autosave' 로 안내한다. 옛 체크포인트 26개 73MB 가 죽은 파일 | lane 의 checkpoint_format 을 코어의 스냅샷 format 에서 직접 가져와서(손으로 올리는 번호 없애기) header.format 에 넣는다. 그러면 read_meta 의 기존 'format 이 다르면 거절'이 압축을 풀지 않고도 잡는다. 옛 파일 26개는 운영자가 지운다(읽는 길 없음, hard cut). | 확인 |
| D10-04 | P2 | `lib/tui_decode.ml:11157-11190` | 09-29 TU-F11 (거절 모양 4개)의 잔재. 1단계 #40050 은 병합됨 | TUI play_invite_refusal 은 옛 거절 모양({error: 코드, message: 문장})을 읽어서 실서버 응답에는 항상 None 이다 | play_invite_refusal 과 그 테스트를 지우고, 상세(missing, taken_by)가 필요하면 http_status_error 와 같은 자리에서 새 모양의 code·missing·taken_by 를 읽는 디코더 하나로 합친다. 주석의 옛 모양 설명도 지운다. | 확인 |

## L3 디스크·보존(retention): .masc 111GB, worktree 991개, 여유 98GiB

측정 시각은 10-01 01:13~02:10 KST 입니다. 여유 공간이 빠르게 줄고 있고, 줄이는 자동 장치는 돌지 않습니다. 여유는 01:13 에 209GiB, 02:06 에 143.9GiB 였습니다. 53분에 65GiB, 시간당 약 74GiB 입니다. 지난 하루 평균은 시간당 약 19GiB 였습니다(메모리 기록 580Gi 에서 119Gi). 이 속도가 이어지면 2시간 안쪽, 평균 속도면 8시간 안쪽에 찹니다. 다른 세션의 빌드가 겹친 구간이라 순간 속도는 과대일 수 있습니다. 용량이 큰 곳은 worktree 995개(du 합 386GB, 저장소 .worktrees 114GB + /private/tmp 268GB), keeper 작업 볼륨 332GB, dune cache 63.9GB(09-29 에 24.8GB), .masc 111GB 입니다. .masc 안에서는 official-clients 53GB 중 antigravity 33.2GB 가 09-27 이후 읽는 코드가 없는 옛 홈이라 지워도 됩니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| L3-01 | P1 | `<base-path>/scripts/disk-hygiene.sh:182` |  | 여유 공간이 시간당 수십 GiB 줄고, 줄이는 장치가 자동으로 돌지 않는다 | 새 Gate 는 만들지 않습니다(헌법 budget_gate). 만든 쪽이 치우는 구조로 갑니다. (1) 아래 L3-02 worktree 제거를 worktree 를 만든 도구의 종료 단계에 둡니다. (2) L3-13 dune cache 를 같은 자리에서 줄입니다. | 확인 · Medium |
| L3-02 | P2 | `git worktree list` |  | worktree 995개가 쌓였고 병합·닫힌 PR 의 것도 지우는 주체가 없다 | A 106개만 git worktree remove(강제 없이)로 지웁니다. 원인은 만든 쪽이 안 치우는 것이라 worktree 생성 도구(masc_worktree_create, 세션 스킬)가 PR 머지·닫힘을 볼 때 제거까지 하게 합니다. | 확인 |
| L3-03 | P2 | `lib/runtime/runtime_antigravity_home.ml:548` |  | antigravity 옛 홈 33.2GB: 09-27 이후 읽는 코드가 없고 지우는 코드도 없다 | 지금 것은 운영자가 삭제(안전, 읽는 곳 없음). 코드는 keeper 제거 흐름에서 keeper_owner_leaf 로 계산한 홈을 지우게 합니다. 이름 폴더를 읽는 호환 코드는 만들지 않습니다. | 확인 |
| L3-05 | P2 | `lib/tool_blob_store/tool_blob_maintenance.ml:120` |  | tool_blobs 정리 코드는 있는데 한 번도 안 돌았다 | 이미 있는 2단계 명령을 서버 재시작 절차에 넣어 Observe 와 Delete 를 차례로 돌립니다. 새 Gate 나 나이 기준은 만들지 않습니다(코드 주석이 나이·개수 휴리스틱을 거부함). | 확인 |
| L3-08 | P2 | `lib/tool_misc_msx_lane.ml:404` |  | msx/saves 10.4GB: 지우는 코드와 개수 한도가 없다 | keeper 가 자기 slot 을 볼 수 있게 목록과 삭제 도구를 더합니다. 숫자 한도나 자동 삭제는 만들지 않습니다(판단이 필요한 자리). | 확인 |
| L3-09 | P2 | `lib/keeper/keeper_board_attention_candidate.ml:1758` |  | board_attention_candidates 원장이 소비된 후보를 지우지 않고 하루 12배로 늘었다 | 먼저 '소비된 후보를 얼마나 증거로 남겨야 하나'를 정합니다. 정해지면 다른 저장소처럼 기존 prune_shared_jsonl_stores 한 곳에 넣습니다. 새 계수는 만들지 않습니다. | 확인 |
| L3-12 | P2 | `lib/runtime/runtime_setup_login_client.ml:33` |  | codex 계정 홈 17.2GB(3일): 이 홈에는 masc 쪽 정리 코드가 없다 | 홈의 sessions 와 sqlite 를 줄이는 일을 '계정 홈의 수명'에 넣습니다. ~/.codex/sessions 용 기존 정리(CODEX_KEEP_DAYS)와 같은 규칙을 이 경로에도 씁니다. Codex 를 멈추고 해야 하는 VACUUM 은 수동입니다. | 확인 |
| L3-04 | P3 | `lib/keeper/keeper_sandbox_microvm.ml:1590` |  | 제거된 keeper 의 작업 볼륨·흔적이 남는다 (lane-smith 12GB) | keeper 제거가 '영구 삭제'일 때만 볼륨과 .masc 하위 폴더를 지우는 한 군데를 만듭니다. 일시 정지나 shutdown 과 구분하는 타입이 먼저 있어야 합니다. | 확인 |
| L3-07 | P3 | `lib/exact_lane_run_registry.ml:423` |  | 죽은 파일 1.2GB: exact-lane-runs-v5.jsonl 과 .atomic_*.tmp 5개 | 파일 6개를 운영자가 삭제합니다. 재발 방지는 기동 때 .masc 루트에도 이미 있는 cleanup_atomic_orphans 를 부릅니다(새 개념 없음). | 확인 |
| L3-10 | P3 | `scripts/run-local.sh:168` |  | .git 안 run-local 실행 파일 4.7GB 와 worktree 관리 폴더 1.86GB | provenance 가 가리키지 않는 실행 파일을 지우는 한 줄을 run-local.sh 에 넣습니다. .git/worktrees 는 L3-02 로 줄어듭니다. | 확인 |
| L3-11 | P3 | `docs/evidence/worker-support-task-index-2026-09-27/raw.tar.gz` | 09-29 prev-matrix 저장소 행(tar.gz 56.5MB) | 모든 worktree 가 docs/evidence 를 통째로 받는다: 증거 원본 tar.gz 2개 56.5MB 는 읽는 곳도 없다 | 원본 tar.gz 를 git 밖(.masc/evidence 나 release asset)에 두고 문서엔 요약과 경로만 둡니다. worktree 생성 때 docs/evidence 를 sparse-checkout 에서 뺍니다. | 확인 |

## D11 Multi Lane · Lane Add-on · Fusion

P2 8건, P3 10건. P0·P1 없음. 가장 큰 것은 두 가지다. (1) Lane 이름과 목록이 아직 다섯 갈래로 따로 산다. RFC 3단계 중 1a 만 머지됐고 Lane_id 를 쓰는 곳은 3곳이다 (D11-04). (2) 라이브 Add-on 은 선언 2개에 active 0 인데 Lanes 개요 줄은 읽지도 않고 서버 로그에도 한 줄이 없다 (D11-03). 09-29 이후 변경 #39892 #39955 #40125 #40107 에서는 새 결함을 못 찾았다 (#40107 은 diff 일부만 읽음). 라이브 서버는 지금 ebea1d97a7 (11:36 시작)이고 D11 파일은 스냅샷 e1f1429890 과 5파일 17줄만 다르다. 초안에서 P2 로 적었던 effect_disposition N-of-M 은 Failure_returns_to_model 때문에 영향이 좁아 P3 로 내렸다. Fusion 은 패널 수 상한과 fan-out timeout 합성이 없어 헌법을 지킨다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D11-06 | P2 | `lib/slack_lane/slack_lane.ml:1-92` |  | Slack_lane 은 쓰기만 있고 읽는 곳이 없다 | 읽는 쪽(Keeper 도구나 TUI 탭)을 같은 PR 에서 붙이거나, 붙일 계획이 없으면 Slack_lane·poll lane·checkpoint 설계 문서를 지운다. 이 경우 주석의 없는 읽기 경로도 같이 사라진다. | 확인 |
| D11-08 | P2 | `lib/server/server_routes_http_routes_lane_addons.ml:43-46,279-285` | 09-29 TU-F35 | 같은 Add-on 도구가 실패를 세 가지로 말하고, HTTP 는 거절과 결과 모름을 모두 400 으로 보낸다 | Lane_addon_runtime.error 를 2갈래 글자 대신 닫힌 variant(Request_rejected·Runtime_failed·Io_failed)로 올리고, HTTP 상태와 MCP class 를 한 함수에서 만든다. declaration 의 error_code 도 같은 variant 로 합친다. | 확인 |
| D11-03 | P3 | `bin/masc_tui.ml:5588-5600` |  | Lanes 개요는 Add-on 을 읽지 않고, 라이브 Add-on 은 선언 2개에 active 0 인데 로그에 한 줄도 없다 | Lanes 를 열 때 Add-on inventory 읽기도 같이 보낸다(launch_lanes_load 가 Inspect 를 함께 부른다). 또는 D11-04 의 GET /api/v1/lanes 한 줄로 합친다. reconcile 이 issue 를 처음 만들 때와 바뀔 때 한 번 로그를 남긴다(매 박자 반복 금지). | 확인 |
| D11-05 | P3 | `config/tools/masc_lane_detach.toml:3-5` |  | masc_lane_detach 설명은 '워커만 멈춘다' 인데 실제로는 운영자의 선언 TOML 을 지운다 | 설명에 '선언 파일도 지운다. 다시 쓰려면 declaration 을 새로 저장한다' 를 쓴다. 한 줄만 고치면 된다. 지우는 일을 Keeper 가 해도 되는지는 운영자 판단이라 따로 묻는다. | 확인 |
| D11-07 | P3 | `lib/server/server_routes_http_routes_lane_addons.ml:74-92` |  | workspace 경계 검사가 package-preview 에만 있고 attach·declaration 은 아무 경로나 받는다 | 경계 검사를 Lane_addon_manifest.load 입구 한 곳으로 옮겨 preview·attach·declaration 이 같은 함수를 지나게 한다. snapshot_file 의 absolute path 도 같은 경계 함수로 거른다. resources 상한은 숫자를 새로 정하지 말고 운영자가 설정으로 정한 값 아래만 받게 한다. | 확인 |

## D13a TUI·대시보드 데이터 배선 (서버 route ↔ decoder ↔ 화면)

09-29 이후 TUI 가 부르는 경로는 거의 그대로다(경로 +1 provider-usage-history, -1 repositories/pulls). 메서드까지 대조한 불일치는 0이다. 새 디코더 15개를 서버 encoder 와 필드 이름까지 맞춰 봤고, 어긋난 것은 play 초대 거절 reader 하나다(D13a-01). 웹 F01·F02·F17·F18 은 코드상 고쳐졌다. Home 은 읽기 상태를 잘 나눠 그린다. 새 폴링도 늘리지 않았다. 새 결함은 여덟 개다. 가장 큰 것은 실제 운영 TUI 세션 4시간 17분 중 32분(12.5%)이 메인 루프 정지였다는 측정이다(D13a-02, 이슈 #39763). 그 밖에 Home 의 마지막 대화 기록이 매 방문마다 runtime.toml 을 다시 쓴다(D13a-03). ask 로그를 못 읽으면 질문 0개로 답한다(D13a-04). 서버가 60초마다 GitHub 를 읽지만 읽는 화면이 없다(D13a-06).

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D13a-01 | P2 | `lib/tui_decode.ml:10615-10650` | 09-29 TU-F11 | TUI 의 play 초대 거절 reader 가 #40050 이 없앤 `message` 필드를 읽어서 항상 None 이 된다 | play_invite_refusal 이 `error` 문장과 `missing`, `taken_by` 를 읽게 바꾼다. 테스트는 issue_response 가 만든 JSON 을 그대로 넣는다. 위 주석의 옛 모양 설명도 지운다. | 확인 |
| D13a-02 | P2 ←P1 | `bin/masc_tui_http.ml:5-40` | 이슈 #39763 (가설만 있음, 프로토타입 PR #39762 는 닫힘); 09-29 TU-F55 | 실제 운영 TUI 가 4시간 17분 중 32분 멈춰 있고, 그동안 폴링 요청이 전부 같이 늦어진다 | 고치기 전에 잰다. MASC_TUI_FRAME_TIMING 으로 present 단계의 write_ms·flush_ms 를 라이브 TUI 에 켜서 write 가 막히는지 본다(이미 있는 계측). 막히면 터미널 출력을 render 와 다른 스레드로 옮긴다. 안 막히면 load_from_masc_dir 의 동기 파일 읽기를 본다. | 확인 못 함 · Medium |
| D13a-05 | P2 | `bin/masc_tui.ml:11120-11160` | #40079 (ready, APPROVED, 09-29 19:54Z 부터 미병합); 09-29 TU-F55 | 매 2초 tick 이 바뀌지 않은 응답 약 190 KB 를 다시 받아 파싱한다. 서버는 이미 304 를 준다 | #40079 를 머지한다(승인됨, mergeable). 머지 뒤에도 schedules 가 '다음 깨움 하나' 때문에 행 20개를 받는지 다시 잰다. | 열린 PR 이 다룸 |
| D13a-07 | P2 | `bin/masc_tui.ml:26512-26541` |  | TUI 가 Eio poll 단언 실패로 죽은 기록이 09-28 이후 5건이다 | 먼저 재현한다: 터미널 탭을 닫을 때(PTY hangup)와 stdin 대기 fiber. Eio 가 기다리는 fd 를 동기로 닫는 곳을 전수 확인한다(Unix.close 는 위 두 곳뿐이고 둘 다 대기 fd 는 아님). 원인 전에 단언을 잡아 조용히 넘기지 않는다. | 확인 |
| D13a-08 | P2 | `test/test_tui_decode.ml:371` | 09-29 TU-F04 | TUI 디코더 테스트의 JSON 이 서버 encoder 가 아니라 손으로 쓴 값이라, TU-F04 같은 사고가 이번 주 두 번 났다 | 디코더마다 서버 encoder 가 만든 JSON 을 넣는 테스트 한 벌을 둔다. encoder 는 lib/ 안이라 test 에서 바로 부를 수 있다. 먼저 play 거절, schedules 스냅샷, asks, keeper-costs 네 개. 문자열 검사 CI 는 만들지 않는다. | 확인 |
| D13a-04 | P3 | `lib/keeper/keeper_ask_store.ml:99-104` |  | ask 로그를 못 읽으면 서버가 질문 0개로 답하고, Home 이 '결정 기다리는 것 없음'이라고 그린다 | route 가 load_events_result 를 쓰고 읽지 못한 Keeper 이름을 응답에 싣는다. TUI 디코더는 그것을 '읽지 못함'(Approval_unavailable)으로 잇는다. | 확인 |

## D13b TUI 키·푸터·정보 선명성 (Home 포함)

Home 의 j/k·Enter·p·;·m·r·Tab·q 는 푸터와 dispatch 가 맞습니다. Home 의 Recent 창도 닫혀 있습니다(`acting_pane_layout`). 입력 리더 분리(#40126)에서 죽은 export 는 없었습니다. 새 결함은 열 가지입니다. Home 은 부분 읽기 실패를 전체 실패로 읽어 operator 결정 카드를 숨깁니다(#40307 이 고치는 중). Home 에서 연 요청 화면은 한 번의 읽기 실패에 닫히면서 쓰던 답 초안을 버립니다. Home 으로 Esc 해서 돌아온 뒤 `p` 를 누르면 요청 목록이 아니라 지난 상세가 열립니다. Approvals 목록 푸터에는 Enter 가 없습니다. Usage 의 Keeper usage 행은 "읽음 범위" 칸이 줄 맨 끝이라 80열과 120열에서 잘립니다. 채팅을 열 때마다 runtime.toml 을 통째로 commit 합니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D13b-01 | P2 | `bin/masc_tui_types.ml:11344-11354 (home_decision_rows tasks 분기)` | #40307; 09-29 TU-F56 | Home 이 부분 읽기 실패를 전체 실패로 읽어 operator 결정 카드를 숨깁니다 | `tasks_error : string option` 하나를 '필수 읽기 결과'(Rows_read/Rows_unavailable 는 이미 `task_reading` 에 있음)와 '보조 메모'로 나눕니다. Home 은 `task_reading` 과 `operator_stalled` 만 보고, 메모는 Work 에만 그립니다. | 열린 PR 이 다룸 |
| D13b-04 | P2 | `bin/masc_tui.ml:23850-23857 (followed_from 의 Esc 가 먼저)` |  | Home 에서 연 요청을 Esc 로 닫고 돌아온 뒤 `p` 를 누르면 요청 목록 대신 지난 상세가 열립니다 | 요청 상세의 '열림' 을 Home 이 들고 있는 `home_opened_request` 한 곳에서만 정하고, Approvals 는 그 값이 있을 때만 상세를 그립니다. 그러면 `goto_surface` 가 그 값을 지울 때 플래그도 함께 사라집니다. | 확인 |
| D13b-06 | P2 | `bin/masc_tui_render.ml:13423-13445 (행 조립, coverage 가 마지막)` | #40091, #40331 (같은 Usage 좁은 폭 작업. Keeper usage 행을 고치는지는 확인 못 함) | Usage 의 Keeper usage 행에서 '읽음 범위'(read/partial/unavailable)가 줄 맨 끝이라 잘립니다 | coverage 를 줄 앞(이름 바로 뒤)으로 옮기고 'read' 는 그리지 않습니다(완전할 때는 침묵). partial·unavailable 일 때만 앞에 표시합니다. 숫자 칸은 폭이 모자라면 뒤에서 자릅니다. 열린 #40091·#40331 이 Usage 좁은 폭을 고치지만 이 행을 다루는지는 확인 못 함. | 열린 PR 이 다룸 |
| D13b-09 | P2 | `bin/masc_tui_input_reader.ml:105-130 (terminal_has_bytes: Fiber.first(await_readable stdin, sleep))` |  | TUI 가 Eio 스케줄러 assert(sched.ml:155)로 비정상 종료한 기록이 3일에 5건입니다 | 먼저 재현 조건을 가립니다(터미널 창 닫기, macOS 잠자기 뒤 깨우기, 세션 중 stdin 교체). stdin 을 Eio 에 등록하는 대신 이미 같은 파일에 있는 `Unix.select` 커널 대기 + 짧은 주기를 쓰면 이 assert 경로가 없어집니다. | 확인 못 함 |
| D13b-03 | P3 | `bin/masc_tui_types.ml:11312-11319 (source_notes)` |  | Home 승인 줄이 '아직 안 읽음'·'읽기 실패'·'옛 값'·'사용 불가'를 같은 문구로 그립니다 | `List_not_read` 네 가지를 match 로 풀어 'loading' 과 '못 읽음: 이유' 와 '옛 값' 을 다르게 그립니다. 이름은 길면 '2 sources' 식으로 줄이고 자세한 것은 Approvals 제목에 맡깁니다. PTY 는 '로딩' 과 '실패' 를 따로 단언합니다. | 확인 |
| D13b-05 | P3 | `bin/masc_tui_keys.ml:1032-1045 (Approval_browsing 행)` | 09-29 TU-F49 | Approvals 목록 푸터에 Enter·R·Y 가 없고, 상세 푸터에는 [ / ] 가 없습니다 | Approval_browsing 행에 `approval_read`(Enter)를 넣고 같은 표에서 R·Y 는 help 에만 둡니다. 상세 푸터에는 `approval_walk` 를 넣습니다. 테스트를 양방향으로 바꿔 '표의 Navigate·Act 키는 모두 어느 푸터 상태에든 나온다'를 확인합니다. | 확인 |
| D13b-07 | P3 | `bin/masc_tui.ml:777-822 (open_message_for_keeper, remember_home_chat)` |  | 채팅을 열 때마다 runtime.toml 을 통째로 commit 합니다 (#40137 이후) | 탐색 기록은 운영자 설정이 아니라 TUI 전용 상태 파일 한 곳에 쓰고(`opening` 이 읽는 값은 그 파일에서 읽음), 바뀔 때만 씁니다. | 확인 |
| D13b-08 | P3 | `bin/masc_tui_account_login.ml:482-486 (Models when key="a")` | 09-29 TU-F47 | /login 모델 선택의 `a:전체` 는 context 를 모르는 모델을 안내 없이 건너뜁니다 | `a` 를 누르면 notice 에 'N개 선택, M개는 context 를 몰라 건너뜀(Space 로 한도 입력)' 을 씁니다. 푸터 라벨은 `a:고를 수 있는 것 전체` 로 바꿉니다. eligible 이 비면 '고를 수 있는 모델이 없어요' 를 씁니다. | 확인 |
| D13b-10 | P3 | `bin/masc_tui_render_tools.ml:1489-1511` | 09-29 TU-F58 | 한국어와 영어가 한 화면에 섞인 곳이 /login 밖으로 넓어졌습니다 | 운영자에게 먼저 묻습니다: TUI 화면 언어는 영어 하나인지 한국어 하나인지. 정해지면 문구를 그 언어로 맞추고, 코드 이름(ORIGIN, DIRECT 등)은 영어 그대로 둡니다. 문구는 화면별로 나눠 작은 PR 로 옮깁니다. | 확인 |

## D14 Terminal-Bench(4.0 및 최신) 통과 준비 상태

결론: 어댑터 코드는 main 의 인터페이스(masc login 인자, keeper 도구 이름·인자, approval-mode REST, 작업 상태 이름, runtime.toml 키)와 맞고 끝까지 이어져 있다. 하지만 head 기준으로 돌려 본 기록이 없다. 마지막 실행은 09-22 20:54~22:07 KST 의 trial 7건(task 1개, dist 0.35.22)이고 통과는 1건이다(docs/audits/2026-09-23-week-change-audit-evidence-record.md:309-322). 스펙이 정한 확인런(전체 66 x arm a,b x k=1)은 한 번도 안 돌았다. 이 호스트 docker 로는 66개 중 53개만 돌릴 수 있고, GPU 3개에 필요한 Modal 경로는 자격도 없고 실행된 적도 없다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D14-01 | P2 ←P1 | `docs/audits/2026-09-23-week-change-audit-evidence-record.md:309-322` |  | head 기준 Terminal-Bench 실행 증거가 없고 전체 66 task 를 돌릴 수 있는 경로가 막혀 있다 | 스펙 5.4 순서를 지킨다: 스모크 1 task -> 확인런(66 x arm a,b x k=1, GPU 제공 환경) -> 본런. 확인런 결과로 인프라 실패율과 task 당 비용을 먼저 본다. 비용과 환경 선택은 운영자 결정이다. | 확인 · High |
| D14-02 | P2 | `benchmarks/terminal_bench/image/fetch_masc.sh:15-22` |  | 바이너리는 최신 릴리스, 설정은 체크아웃 head 에서 와서 두 출처가 어긋나고 trial 기록에 설정 출처가 없다 | trial 에 체크아웃 커밋, 렌더한 runtime.toml 과 keeper TOML 의 sha256, effort 를 기록한다. 더 좋은 쪽은 설정과 프롬프트를 릴리스 바이너리에 내장된 것에서만 읽게 하거나, 릴리스 태그와 같은 커밋의 config 를 쓰게 고정하는 것이다(선택지는 운영자 결정). | 확인 |
| D14-05 | P2 | `benchmarks/quick-bench.sh:211` |  | 성능 벤치 스크립트가 없는 도구 masc_agents 를 부르고 기본값이 운영 서버다 | 없는 도구 호출을 지우고(죽은 개념은 지운다), 기본 MASC_URL 을 운영 포트가 아닌 격리 서버(9400 이상, docs/BENCHMARK-RUNBOOK.md 의 포트 규칙)로 바꾸거나 URL 을 필수 인자로 만든다. 스크립트가 더 이상 쓰이지 않으면 두 파일과 PERFORMANCE-SLO.md 측정 절을 지운다. | 확인 |
| D14-03 | P3 | `benchmarks/terminal_bench/configs/render_configs.py:190-205` |  | 렌더한 벤치 설정이 서버 로더를 통과하는지 실행 전에 확인하는 고리가 없다 | run_matrix.sh 가 dataset 을 받기 전에 arm 마다 설정을 한 번 렌더하고, 받은 릴리스 바이너리로 임시 base-path 에서 masc start 를 띄워 MCP initialize 까지 확인한다. 문자열 검사나 임계값 CI 는 만들지 않는다. | 열린 PR 이 다룸 |
| D14-04 | P3 | `benchmarks/terminal_bench/agents/masc_agent.py:75-125` |  | 어댑터는 ATIF 를 만들지 않는데 리더보드 제출에 필요한지는 공식 근거가 없다 | 공식 문서로 4.0 제출 요건을 먼저 확인하고 evidence record 에 적는다. ATIF 가 필요하면 trace 를 ATIF 로 바꾸는 변환을 RFC 로 먼저 설계한다. 요건이 없으면 이 항목을 닫는다. | 확인 못 함 |

## D15 Keeper 프롬프트·도구 설명의 정확성과 낭비

P0·P1 은 없고 P2 가 7개입니다. (1) 라이브 Keeper 26명은 저장소의 keeper.md 대신 운영자 override `keeper` 를 읽습니다. 10-01 09:00~11:22 KST wire-capture 476/476 요청이 override 문장입니다. 기본값과 6곳 다르고 부팅 WARN 도 납니다. 열린 PR #40389·#40204 의 keeper.md 변경은 override 를 지우기 전까지 Keeper 에게 닿지 않습니다. (2) 이 요청의 33%(121/372)에 'keeper_status tool 이 이유를 담고 있다'는 줄이 실립니다. 그 도구는 Keeper 에게 주어지지 않습니다(Operator_only). (3) 지운 개념이 Keeper 가 읽는 글에 3곳 남았습니다(`generation`, `older proposal`, plan 도구 안내). (4) keeper.en.md 는 읽는 곳이 없는 영어 사본이고 5곳 이상 낡았습니다. (5) MM-W5 는 반만 바뀌었습니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D15-01 | P2 | `lib/prompt_registry/prompt_registry.ml:768-780 (resolve: override > file)` | #40389 (Native Stack 문장), #40204 (<portrait>), #40363 (2분 문장, 라이브 기본에는 이미 반영) | 라이브 Keeper 는 저장소 keeper.md 가 아니라 override `keeper` 를 읽고, 기본값과 6곳 다르다 | 새 장치를 더하지 않습니다. 운영자가 (a) 의도해서 뺀 두 문장을 main 의 keeper.md 에서 PR 로 빼거나 되살리기로 정하고 (b) Native Stack 문장은 #40389 로 머지하고 (c) `<board>` Vote 블록은 worldview 의 Vote 문단에 합친 뒤 (d) `keeper` override 를 지웁니다. | 확인 |
| D15-02 | P2 | `config/prompts/keeper.md:141-142` |  | 모든 Keeper 가 읽는 World State 줄이 존재하지 않는 도구 `keeper_status` 를 가리킨다 | 줄에서 도구 안내 절을 지우고 개수만 남깁니다('N checkout(s) not measurable this turn'). 이유를 Keeper 가 알아야 한다면 Keeper 도구(keeper_context_status 등)의 응답에 넣는 것이 맞고, 그 판단은 별도입니다. | 확인 |
| D15-03 | P2 | `config/tools/keeper_context_status.toml:3-4` |  | 지운 개념이 Keeper 가 읽는 글에 3곳 남아 있다 | (a) 설명에서 `generation, ` 를 지웁니다. (b) 'or substitute an older proposal' 를 지웁니다. (c) 두 설명에서 다른 도구 이름을 빼고 이 도구가 하는 일만 적습니다. 폐기됐다는 말을 대신 적지 않습니다. | 확인 |
| D15-04 | P3 | `config/tools/keeper_workspace_memory_read.toml:14-17` | 09-29 MM-W5 | keeper_workspace_memory_read 인자 설명은 'bounded' 인데 summary 에 상한이 없다 | 설명에서 'bounded' 를 지우고 실제 모양(claim·conflict 전부와 member 참조)을 적습니다. 구조 쪽 수정은 summary 가 id 와 text 만 주고 member 는 `id` 읽기로만 내려가게 하는 것입니다. 응답이 fact 가 아니라 claim 수에 비례하게 됩니다. | 확인 |

## D16a 죽은 개념 잔재 · 중복 개념 · 어려운 표현 (Glossary 개정 근거)

정적 감사입니다(라이브 데이터 해당 없음). 스냅샷 e1f1429890 기준이고, 아래 파일들은 라이브 소스 37e390738d 와 diff 가 없습니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D16a-01 | P2 | `dashboard/src/components/keeper-config-panel.ts:2372 ('☠ 제거됨 · Handoff_triggered 이벤트와 자동 핸드오프 임계치는 소스에서 삭제됐습니다')` | #40266 (keeper-config-panel.ts 를 고침, 다른 주제), #40393 #40024 #40010 (dashboard_execution_builders 를 고침, 주제 다름) | 지운 Keeper handoff 가 대시보드 문구·설정·문서에 남아 있어요 | '핸드오프 임박' 상태를 '컨텍스트가 거의 찼어요' 같은 사실 문구로 바꾸거나 상태째 지웁니다. MASC_DASHBOARD_CTX_HANDOFF_IMMINENT 는 임계값이 다른 이름으로 필요할 때만 남깁니다. | 확인 |
| D16a-02 | P2 | `lib/keeper_registry/keeper_state_machine.ml:89-90` |  | Keeper_state_machine 의 Context_measured 이벤트를 만드는 곳이 없어 context_handoff_needed 는 늘 false 예요 | Context_measured 이벤트, context_actions 타입, context_handoff_needed, pending_turn_measurement 를 지우고 JSON·대시보드 스키마도 같이 줄입니다. 먼저 mark_turn_measurement 가 다른 production 입력으로 채워지는지 한 번 더 확인하고 지웁니다. | 확인 |
| D16a-03 | P2 | `lib/metrics_store_eio.ml:25-26,137-157,265-270 (No handoffs = perfect handoff rate)` |  | 에이전트 적합도의 '핸드오프' 값은 늘 100% 예요 | handoff 필드 2개, handoff_success_rate, 적합도의 handoff 성분, 카드를 지웁니다. 측정할 수 없는 값에 '없으면 만점'을 주는 기본값을 두지 않습니다. | 확인 |
| D16a-06 | P2 | `docs/LOGGING.md:3,73,112 (scripts/ci/check-logging-consistency.sh)` | #40370 #40367 #40290 등이 CONTRIBUTING.md 를 고침. 이 잔재를 다루는 PR 은 못 찾음. | 지운 CI 스캐너 96개를 가리키는 문서·주석과 주인 없는 설정 파일이 남아 있어요 | 문서와 주석의 해당 문장을 지우고(폐기 표기 없이), ci/logging-consistency-*.txt 와 주인 없는 lint 스크립트 2개를 지웁니다. CONTRIBUTING.md:112 는 scripts/ci/ 에 스크립트가 남아 있어 틀리지 않으니 그대로 둡니다. CI 청결도 스택으로 묶어 올립니다. | 확인 |
| D16a-13 | P2 | `docs/spec/00-glossary.md:1238 (7,252 B)` | 09-29 09-29 감사 9절 | Glossary 가 하루에 6.5 KB 씩 늘고 항목 중 절반이 코드 경로나 PR 번호를 품어요 | 결정 A(한두 문장 + 코드 링크)면 summary 의 샘플 3개 형식으로 줄입니다. 값 이름·PR 번호·route 는 .mli 와 RFC 로 넘깁니다. 결정 B 면 항목당 최대 크기 기준 없이 계속 커집니다. 판단은 운영자 몫이라 임계값은 제안하지 않습니다. | 확인 |
| D16a-04 | P3 | `bin/masc_tui_loader.ml:1404-1412,1504-1531 (overview_keeper_rows_of_briefs, ov_keeper_rows)` | masc_tui_loader.ml·tui_decode.ml·masc_tui_types.ml 을 고치는 열린 PR 이 많음(#40393 #40374 #40278 #40260 #40250 등). | #38801 이 지운 Overview Team 블록의 계산·타입·주석이 남아 있어요 | ov_keeper_rows 와 overview_keeper(+ overview_keeper_phase), overview_keeper_rows_of_briefs, Tui_decode.keeper_phase_band 를 지웁니다. | 확인 |
| D16a-05 | P3 | `docs/rfc/RFC-0362-goal-owner-and-intake-contract.md:1-10 (status Draft, 제목 'Goal owner and the intake contract')` | #40337 (D5-01, 같은 주제) | 하루 살고 지운 Goal owner 가 RFC·대시보드 디코더·테스트 fixture 에 남아 있어요 | RFC-0362 를 지우고 RFC-goal-candle-ledger:17, RFC-0448:24 의 링크를 뺍니다. 재배포 때 채팅 파일의 옛 줄을 정리(D5-01 계획)한 뒤 대시보드 디코더와 fixture 를 같이 지웁니다. #40337 처럼 지운 종류를 되살리는 방식은 권하지 않습니다. | 확인 |
| D16a-07 | P3 | `packages/agent_core/lib/handoff.ml (118줄)` |  | Agent Core 의 Handoff(하위 에이전트로 넘기기)는 lib·bin 에서 부르는 곳이 없어요 | agent_core 를 MASC 전용으로 본다면 handoff 전체와 sse.ts 타입을 지웁니다. 밖에서 쓴다면 그 사실을 운영자가 정해 주세요(결정 필요). 결정 전에는 고치지 않습니다. | 확인 못 함 |
| D16a-08 | P3 | `docs/spec/00-glossary.md:622-625 ('이 조건의 runtime blocker class 는 만드는 곳이 없어 지웠다. capacity_backpressure 라는 글자는 다른 개념…')` | #40382 #40318 #40260 #40239 (glossary 를 고치는 열린 PR, 같은 줄은 안 건드림) | Glossary 에 '지웠다' 설명과 없는 항목을 가리키는 문장이 있어요 | 622-625 와 2519-2521 에서 과거 설명을 지우고 지금 동작만 적습니다. 1470·1485 는 'Dashboard Goals' 로 바꿉니다(D16a-04 와 같은 PR). 502 는 실제 타입 이름으로 고칩니다. | 확인 |
| D16a-11 | P3 | `bin/masc_tui_types.ml:2881 ((Overview, "Dashboard"))` | #40318 (Home 화면 glossary 추가) | TUI 첫 화면을 Overview, Dashboard, Home 세 이름으로 불러요 | 운영자가 이름 하나를 고릅니다(TUI 화면에 보이는 'Dashboard' 가 가장 덜 고칩니다). glossary 에 그 이름으로 항목 하나를 두고 나머지는 지웁니다. 설정 값 'overview' 를 바꾸면 runtime.toml 이 깨지므로 설정 이름은 별도 결정. | 확인 |
| D16a-14 | P3 | `docs/spec/00-glossary.md (Access Control 0곳, Keeper Owner 1곳:2254 항목 없음, Credential 1곳, Worker 0곳, Workspace Curator 4곳 항목 없음)` | 09-29 09-23·09-29 감사 지적 | Glossary 에 정의가 없는 말이 그대로예요 (Access Control, Keeper Owner, Worker 등) | Glossary 개정안(한두 문장): ① Keeper Owner — Keeper 하나의 turn 을 한 번에 하나만 돌리고 chat·스케줄·maintenance 를 직렬로 받는 서버 쪽 주인(keeper_owner.mli). | 확인 |
| D16a-15 | P3 | `docs/spec/00-glossary.md` |  | 가장 어려운 표현 30개와 쉬운 대안 (phrasing-vocabulary.md 기준) | glossary 와 TUI·대시보드 문구는 위 대안으로 고칩니다(PR 제목은 이미 머지돼 고치지 않음). 새 글에서는 '걸음' 대신 '순회', '사정' 대신 '원인', '후계' 대신 '대신 쓰는'을 씁니다. 코드 이름과 필드 이름은 영어 그대로 둡니다. | 확인 |

## D16b 도메인 결합 · 의존 방향 · 큰 파일

스냅샷 e1f1429890 기준이다. dune 라이브러리 357개에 순환과 역방향 참조는 없다. 새 라이브러리(candle*, keeper_portrait, lane_activity, machine_checkpoint, machine_live_publication, runtime_toml_namespace)도 방향이 맞다. 문제는 방향이 아니라 크기다. Keeper 541파일 229,995줄이 라이브러리 하나(`masc`, 약 322k줄)에 들어 있어서 컴파일러가 도메인 경계를 지켜 주지 못한다. 09-23 결합 해소 5건은 지금도 모두 열려 있다. (1) TUI 가 backlog·goal store·Keeper meta 를 직접 읽는다 (`bin/masc_tui_loader.ml:75,102,159,241`). (2) Librarian 이 Keeper meta 와 checkpoint store 를 직접 부른다 (`keeper_librarian_durable_consumer.ml:732-744`).

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| D16b-01 | P2 | `bin/masc_tui.ml:12985` | #40324 #40376 #40377 #40380 #40381 #40390 #40391 #40398 외 refactor(tui) 21개 (총 29개) | TUI `main` 함수 한 개가 9,953줄이고 state 레코드의 mutable 필드가 약 600개다 | 이미 열린 스택(#40324 → #40398)을 아래부터 머지한다. 다음 조각은 `apply_async_message` 를 메시지 종류별 모듈(`masc_tui_<표면>_updates.ml`)로 나누는 것이고, state 는 표면별 하위 레코드로 나눈다. 줄 수 검사나 새 CI 검사는 더하지 않는다. | 열린 PR 이 다룸 |
| D16b-07 | P2 | `lib/keeper/keeper_antigravity_runtime.ml:458` | #40349 #40139 (muse_runtime 수정 중) | provider 런타임 4개가 850줄짜리 같은 함수를 따로 갖고 있다. 이번 주 Muse 가 네 번째가 됐다 | 공통 28개 인자를 한 레코드(`Provider_turn_input.t`)로 모아 `run_named` 가 한 번만 만들고 네 런타임에 넘긴다. effect 보고 방식은 먼저 어떤 런타임이 어떤 경우를 못 알리는지 표로 확인한 뒤 `Keeper_provider_attempt_effect` 쪽 한 함수로 모은다. | 확인 |
| D16b-08 | P2 | `lib/keeper/keeper_agent_run.ml:782` |  | Keeper 의 한 턴 길을 이루는 함수 4개가 1,100~1,800줄이다. `run_named` 는 RFC-0051 때보다 커졌다 | 줄 수가 아니라 단계로 나눈다. `run_named` 는 런타임 종류 match 갈래(2389-2851)마다 어댑터 모듈 하나로 빼고(D16b-07 의 공통 입력 레코드와 같이), `run_turn` 은 compaction·재시도·결과 정리처럼 이미 이름이 있는 단계 단위로 나눈다. 한 PR 에 한 함수만 한다. | 확인 |
| D16b-02 | P3 | `lib/dune:1` |  | Keeper 541파일 229,995줄이 라이브러리 하나에 들어 있고 RFC-0215 머리말은 낡았다 | 비용 0인 것부터 라이브러리로 뺀다. PR1: `lib/world_constitution/dune` 추가(4파일). PR2: `play` 의 `Keeper_meta_store` 2곳을 이름 목록 인자로 바꾸고 `lib/play/dune` 추가. | 확인 |
| D16b-03 | P3 | `lib/server/server_schedule_consumers.ml:403-1224` | 09-29 09-23 감사 #5 / 09-29 문서 8절 | Schedule 소비자가 Keeper 내부 모듈 14개를 136번 부른다 (09-23 #5, 아직 열림) | Keeper 쪽에 "이 Keeper 를 이 긴급도·이 회차 id 로 깨운다" 함수 하나(`Keeper_schedule_wake.deliver`)를 두고 403-1224줄 어댑터를 lib/keeper 로 옮긴다. 소비자는 그 함수와 결과 타입만 부른다. | 확인 |
| D16b-05 | P3 | `lib/keeper/keeper_librarian_durable_consumer.ml:732-744` | D3-01 과 같은 영역: #40019 계열; 09-29 09-23 감사 #2 | Librarian 이 Keeper 모듈을 237번 부르고 meta 전체와 checkpoint store 를 직접 읽는다 (09-23 #2, 아직 열림) | Keeper 쪽이 "trace_id → 메시지 목록" 읽기 함수 하나와 네 값만 담은 레코드를 만들어 Librarian 에 넘긴다. Librarian 은 `Keeper_checkpoint_store` 의 오류 타입을 모르게 한다. | 확인 |

## W1 배선 점검 1: MCP 도구 registry ↔ 핸들러 ↔ 프롬프트 ↔ 클라이언트

registry 와 핸들러 사이의 이름 어긋남은 찾지 못했다. descriptor 의 runtime_handler 는 exhaustive match 이고, 부팅할 때 태그 없는 도구가 있으면 서버가 뜨지 않는다. TUI 와 dashboard 가 부르는 도구·route 이름은 전부 서버에 있다. 프롬프트가 부르는 도구 중 없는 이름은 `keeper_status` 하나다. 이번 주 도구 diff 에서 스키마와 핸들러가 어긋난 곳(board_post_get, Edit cwd, goal_measure, portrait_read, 한도 숫자 몇 개)은 없었다. 대신 세 가지 구조 문제가 나왔다. (1) Keeper 가 admin 등급 파괴 도구 `masc_gc`, `masc_board_cleanup` 을 권한·승인 없이 부를 수 있고, 09-20 에 실제로 메시지 3462개를 지웠다. (2) 도구 지표 저장소가 한 도구를 두 이름으로 쪼개고, 도구 호출의 4.3% 를 아예 기록하지 않는다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| W1-01 | P2 ←P1 | `lib/tool/tool_catalog.ml:413-421` |  | Keeper 가 admin 등급 파괴 도구 masc_gc·masc_board_cleanup 을 권한·승인 없이 부른다 | 권한 판단을 한 곳에 모은다. 두 도구를 sub_board 처럼 Operator_only 로 내리는 안이 가장 작다(둘 다 8일간 호출 0회, Keeper 가 쓸 일이 거의 없다). | 확인 · High |
| W1-03 | P2 | `lib/keeper/keeper_tool_descriptor_resolution.ml:123-135` |  | 도구 지표가 한 도구를 모델 이름과 내부 이름 두 줄로 쪼갠다 | 기록 지점 하나에서 canonical 이름으로 통일한다. Keeper_tool_descriptor_resolution.canonical_tool_name 이 이미 있으니 observer 에서 Tool_result 의 이름을 이 함수로 바꿔 저장한다. 읽는 쪽에서 문자열 별칭 표로 합치지 않는다. | 확인 |
| W1-04 | P2 | `lib/server/server_bootstrap_maintenance.ml:576-585` |  | 도구 지표 저장소가 Skill·Composition·tool_search·외부 MCP 호출을 기록하지 않는다 | 기록을 observer 한 곳에서 하는 대신 Keeper 도구 호출이 끝나는 지점(tool_calls 로그를 쓰는 곳)에서 한 번 쓴다. 그러면 W1-03 의 이름 통일도 같은 자리에서 끝난다. 지표를 tool_calls 로그에서 만들어 내는 방법도 있다. | 확인 |
| W1-07 | P2 | `config/tools/keeper_workspace_memory_read.toml:13` | 09-29 MM-W5 | keeper_workspace_memory_read 는 'bounded' 라고 하지만 상한이 없고, id 조회도 전체를 읽는다 | summary 에 개수 상한과 이어 읽기 값을 typed 로 두거나, 설명에서 'bounded' 를 지운다. detail 은 원장에서 항목 하나를 찾고 그 member 만 현재 기억과 맞춘다. | 확인 |
| W1-02 | P3 | `lib/board_tool_adapter/board_tool_handlers.ml:646-648` |  | masc_board_cleanup 은 최신 글 500개만 훑는다 | 500 을 없애고 Board.search_posts 처럼 전체를 훑은 뒤 조건을 거른다. W1-01 에서 이 도구를 Operator_only 로 내리면 operator 경로에서만 고치면 된다. | 확인 |
| W1-05 | P3 | `config/prompts/keeper.md:142` |  | keeper.md 가 Keeper 에게 없는 'keeper_status 도구' 를 읽으라고 한다 | 문장에서 도구 이름을 지우고 Keeper 가 할 수 있는 일만 적는다. 이유를 Keeper 가 읽어야 한다면 keeper_context_status 에 typed 로 싣는다. 죽은 이름은 '폐기됐다' 라고 적지 말고 그냥 지운다. | 확인 |

## W2 배선 점검 2: TOML 키·환경변수 ↔ 읽는 코드, 하드코딩

스냅샷 e1f1429890 기준으로 P2 9건, P3 10줄을 적었습니다. P0·P1 은 못 찾았습니다. 가장 큰 것은 세 가지입니다. (1) runtime.toml 로 줄 수 있다고 안내하는 Keeper 설정 키 8개가 서버가 뜰 때 이미 계산된 값만 읽습니다. 그래서 TOML 로 바꿔도 효과가 없는데 설정 화면은 "applied" 라고 합니다(W2-02). (2) 라이브 runtime.toml 에 아무도 읽지 않는 키가 2개 있습니다. [health] 와 [tui] 같은 표는 모르는 키가 있어도 거절하지 않고, 저장 검사도 11개 표 중 4개만 합니다(W2-01, W2-08). (3) 이름만 "strict" 인 MASC_AUTH_STRICT=strict 는 요청을 거절하지 않고 로그만 남깁니다(W2-04). 이번 주(09-29 20:55 이후) 새로 생긴 MASC_* 환경변수는 0개이고 280개 그대로입니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| W2-01 | P2 | `bin/masc_tui_config.ml:172-190,214-238` | #40112, #40139, #40213, #40351 은 runtime_toml.ml 을 리팩터링한다(제목만 확인). 이 문제를 다루는지는 확인 못 함.; 09-29 RT-A6 | 라이브 runtime.toml 에 아무도 읽지 않는 키 2개가 있고, 모르는 키를 거절하지 않는 표가 7개다 | 표마다 허용 키 목록을 닫힌 목록으로 두고 모르는 키는 로드 오류로 거절한다(voice, typesafeai, candle 이 이미 그렇게 한다). 최상위 표 이름이 Runtime_toml_namespace 와 Keeper 설정 네임스페이스에 없으면 거절한다. 그러면 [health] 같은 표도 배포 전 검사에서 걸린다. | 확인 |
| W2-02 | P2 | `lib/config/env_config_keeper.ml:138,141,302,305,569,584,599,611` | 열린 PR 없음(env_config_keeper.ml 을 바꾸는 열린 PR 을 못 찾음). | runtime.toml 로 줄 수 있다고 한 Keeper 설정 키 8개는 서버가 뜰 때 이미 계산된 값을 읽어서 TOML 값이 닿지 않는다 | 8개를 함수(let interval_sec () = ...)로 바꿔 호출 때 읽게 하고, 읽는 곳 7개를 함께 고친다. 이어서 Toml_and_env 행마다 'boot override 를 싣고 → 그 행의 읽는 코드가 그 값을 돌려준다' 는 왕복 시험을 넣는다(consumers 문자열 목록을 믿지 않는다). | 확인 |
| W2-03 | P2 | `lib/keeper_runtime/keeper_runtime_config.ml:413-445` | 열린 PR 없음. | 설정 화면의 effective_value 는 Runtime_params 를 안 봐서, 같은 설정 7개가 설정 화면과 실제 값이 다를 수 있다 | 화면에 값을 하나만 보이게 한다. Runtime_params 에 쌍이 있는 행은 effective 칸에 Runtime_params 값을 쓰고 source 에 'runtime_param' 을 더한다. | 확인 |
| W2-06 | P2 | `lib/http_server_eio.ml:18-30` | 열린 PR 없음. | 카탈로그에는 있고 읽는 코드가 없거나 읽고 버리는 환경변수가 3개다. 라이브 프로세스는 읽는 곳 없는 MASC_KEEPER_BOOTSTRAP_ENABLED 를 쥐고 있다 | 카탈로그 행 3개(MASC_HTTP_HOST, MASC_WS_PORT, MASC_KEEPER_AUTONOMOUS_MAX_TOKENS)와 http_server_eio.ml 의 host 필드를 지운다(host 는 make_http_config 의 인자만 쓴다). | 확인 |
| W2-08 | P2 | `lib/runtime/runtime.ml:3440-3447,3463-3496,3672-3680,4221-4231` | #40213, #40223 (저장 편집과 검증을 순수 함수로 분리하는 리팩터링, 제목만 확인). 이 문제를 다루는지는 확인 못 함. | runtime.toml 저장 검사는 11개 표 중 4개 안팎만 보고, 나머지는 쓰는 쪽이 처음 읽을 때 터진다 | 표마다 '문자열을 받아 Result 를 돌려주는' 검사 함수를 소유 모듈에 두고(voice, browser, slack, discord, board 는 이미 있다), validate_save_text 가 Runtime_toml_namespace.all 을 돌며 그 함수를 부르게 한다. | 확인 |
| W2-04 | P3 | `lib/auth/auth_strict_mode.ml:5-20` | 열린 PR 없음. | MASC_AUTH_STRICT=strict 는 요청을 거절하지 않는다. 2026-04 부터 '다음 단계'로 미룬 로그 전용 설정이다 | 둘 중 하나로 정한다. (a) Strict 를 실제 거절로 만든다: Result 로 실패를 돌려주고 호출자가 처리한다. (b) 이 설정을 지운다: Auth_strict_mode 모듈, metric, 이 환경변수를 함께 지우고 MASC_HTTP_AUTH_STRICT 하나만 남긴다. | 확인 |
| W2-05 | P3 | `lib/config/env_config_core.ml:79-110,767-772` | 열린 PR 없음(보존 정책으로 이 파일들을 바꾸는 PR 을 못 찾음). | 보존 기간이 환경변수 6개와 리터럴 3개로 흩어져 있고 기본값이 서로 다르다. 둘은 기본이 '영원히'다 | 보존 기간을 한 곳(닫힌 variant 와 TOML 표 하나, 예: [retention])에 선언하고 저장소마다 그 선언을 읽게 한다. '영원히'는 variant 의 한 값으로 명시한다. 리터럴 30, 16, 7 을 그 선언의 기본값으로 옮기고 이유를 주석에 적는다. | 확인 |
| W2-07 | P3 | `lib/config/env_setting.mli:1-12` | 열린 PR 없음.; 09-29 DM-BD-8, MM-M4 | 운영자가 조절해야 하는 한도가 환경변수로만 바뀌고, 환경변수 카탈로그에는 82개가 빠져 있다 (env_var_sprawl) | 정책이 되는 한도부터 Env_setting 구성자나 레지스트리 행으로 올리고(보존 4개, comment cap, facts 한도, HITL 동시성), TOML 키를 준다. 테스트·개발용 이름(MASC_TEST_*, MASC_TUI_*, MASC_TLC_*)은 카탈로그에서 뺀다고 명시한다. | 확인 |

## W3 배선 점검 3: 저장 파일·이벤트 producer ↔ consumer, 죽은 표면

새 결함 4개(P2)와 P3 잔재를 찾았다. 코드는 스냅샷 e1f1429890 기준이다. 아래 파일들은 라이브 소스 37e390738d 와 diff 가 없다. (1) 엄격하게 읽는 저장소 몇 개가 부팅·배포 검사 목록(Keeper_durable_store.Id.t, 18개)에 없다. 그중 keeper_chat 은 D5-01 사고가 난 저장소다. (2) board_attention_partitions 원장이 settled 파티션을 지우지 않는다. 지금 87,760행에 40.9MB 이고 하루 약 2만 개씩 는다. (3) 날짜별 로그를 지우는 목록이 손으로 쓴 목록이라 5곳이 빠졌다. 가장 큰 곳은 <base-path>/data/tool-events 로 2.8GB 이고 2026-04-23 부터 하루 17~35MB 씩 쌓인다. 그 데이터를 읽는 production 코드는 없다. (4) 쓰는 곳 없이 읽기만 하는 저장소 둘(Mention_inbox, Keeper_response_feedback 쓰기 쪽).

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| W3-01 | P2 | `lib/keeper/keeper_durable_store.ml:714-736` | 없음. #40122 는 이 파일에서 Keeper_approval_queue 를 Keeper_approval_queue_codec 로 바꾸는 이름 변경만 한다.; 09-29 MM-S4 | 부팅·배포 검사 목록에 엄격하게 읽는 저장소가 빠져 있다 (keeper_chat, 파티션 원장, board 4종, candle 원장, skill 활성화 원장) | 저장소를 만드는 모듈이 Id.t 값 하나를 받아야 파일을 열 수 있게 바꾼다. 그러면 새 저장소를 넣고 정책(Refuse_boot, Degrade_typed, Preflight_only)을 안 정하면 컴파일이 실패한다. 먼저 빠진 8개를 Id.t 에 넣고 reader 정책을 정한다. board_posts 문구는 지금 동작에 맞게 고친다. | 확인 |
| W3-02 | P2 | `lib/keeper/keeper_board_attention_partition.ml:1606-1663` | 없음; 09-29 DM-BD-2 | Board attention 파티션 원장이 settled 를 지우지 않아 계속 커진다 | 정리 때 지워도 되는 행을 구조로 정한다. 이미 소비된 후보의 settled 루트처럼 다시 쓰일 일이 없는 행이다. 임계값이나 점수는 쓰지 않는다. 먼저 settled 행을 읽는 곳이 dedupe 외에 있는지 확인한다(이 부분은 전 실행 검증을 따랐고 내가 다시 따라가지 않았다). | 확인 |
| W3-03 | P2 | `lib/server/server_runtime_startup_maintenance.ml:133-145` | 없음. 이 파일을 건드리는 열린 PR 은 찾지 못했다.; 09-29 RT-S8 | 날짜별 로그를 지우는 목록이 손으로 쓴 목록이라 5곳이 빠졌다. 2.8GB 짜리 tool-events 는 아무도 읽지 않는다 | Dated_jsonl.create 의 retention 을 필수 인자로 바꾼다. 값은 Keep_forever 나 Days n 같은 닫힌 타입으로 한다. 그러면 손으로 쓴 목록 두 개를 지울 수 있고 새 저장소가 빠질 수 없다. tool-events 는 읽는 곳이 메모리 맵뿐이므로 Assigned 행 전체를 디스크에 남길지 먼저 정한다. | 확인 |
| W3-04 | P3 | `lib/mention_inbox.ml:56-94` | 없음 | 쓰는 곳이 없는 저장소 둘: Mention_inbox 와 Keeper_response_feedback 쓰기 쪽 | 쓰는 호출이 생길 계획이 없으면 두 모듈과 route 와 문서 줄을 지운다. 계획이 있으면 쓰는 쪽을 같은 PR 에 넣는다. | 확인 |

## X1 렌즈 1: 이번 주 추가된 문자열·부분문자열 판정

09-23~30 에 추가된 비테스트 줄 99,019줄을 훑었습니다. 옛 파일 이동·포맷으로 딸려 온 줄을 빼면 66,890줄입니다. 패턴별 추가 줄 수는 starts_with·ends_with 43, contains·includes 60, 정규식 34(secret_patterns 19), lowercase 비교 20, 리터럴 String.equal/=== 449(대부분 TS 의 union 분기), 리터럴 match 팔 370입니다. 팔 370줄 중 대부분은 와이어 디코더입니다(runtime_muse_msp 82, 키 입력 분기 masc_tui.ml 63, observer 18). 이것들은 (a)(b) 로 분류해서 정당합니다. (c)~(e) 로 남긴 것은 P2 4건뿐입니다. 이번 주에 새로 늘린 것은 둘입니다. 하나는 TU-F36 으로, #40206 이 비교 2곳을 더했습니다. 다른 하나는 runtime id `<provider>.<model>` 를 첫 점에서 자르는 곳 4곳(새 발견)입니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| X1-01 | P2 | `lib/lane_addon/lane_addon_runtime.ml:216-220` | 09-29 TU-F36 | Lane 행 소유자를 `instance_id/` 접두사로 되찾는 곳이 #40206 으로 2곳 늘었습니다 | Lane_addon_types.row 에 `instance_id : string` 과 행 로컬 id 를 typed 필드로 넣고 namespace 가 채웁니다. TUI 는 `String.equal row.instance_id instance.id` 로 비교하고 store 는 `seq` 를 필드로 받습니다. | 확인 |
| X1-05 | P2 | `dashboard/src/components/runtime-setup-picker.ts:50-54` | 09-29 RT-A4 | 공식 client 4종을 이름 문자열로 가르는 분기와, 서버가 붙인 `muse_` 접두사를 대시보드가 떼어 쓰는 곳이 남아 있습니다 | 서버가 `client_kind` closed enum 과 `catalog_verified: bool` 을 와이어에 내보내고, 대시보드는 문자열 목록 대신 이 필드를 읽습니다. TUI 의 client_of_protocol 도 같은 enum 디코더 하나로 모읍니다. | 확인 |
| X1-03 | P3 | `lib/keeper/keeper_durable_store.ml:94-101` |  | 배포 전 durable store 검사가 파일 이름 접두사로 대상을 고르고, 하나도 못 찾아도 통과합니다 | receipt 모듈이 `receipt_paths_of_masc_root : masc_root:string -> (string list, string) result` 를 내보내고 durable_store 는 그것만 부릅니다. files_under 는 ENOENT 만 [] 로 하고 다른 Sys_error 는 Error 로 돌립니다. | 확인 |
| X1-04 | P3 | `bin/masc_tui_render_chat.ml:313` | 09-29 TU-F20 | TUI 도구 결과 색이 만든 글자를 다시 부분문자열로 읽어 정합니다 (09-29 발견이 그대로) | render 가 글자 대신 outcome variant 를 받고 exhaustive match 로 색을 고릅니다. 건드릴 파일은 masc_tui_render_chat.ml, masc_tui_keeper_chat_transcript.ml 입니다. | 확인 |

## X2 렌즈 2: 근거 없는 상수·계수·임계값·추정식

09-23~10-01 에 추가된 비테스트 .ml 약 129,000줄(lib, packages, bin)에서 비교에 쓴 숫자, 이름 있는 상수, 시간·바이트 리터럴, 토큰 추정식을 훑었습니다. 근거 없는 상수는 드물었고, 대부분 측정값이나 RFC 를 주석으로 달고 있었습니다. Keeper 흐름을 누적 turn·time·token·cost 로 막는 새 숫자는 못 찾았습니다. 남은 문제는 네 가지입니다. (1) checkout 신선도를 900초로 갈라 Keeper 에게 current 또는 unverified 라고 알립니다. (2) Workspace Curator 의 입력 한도가 토큰 값에서 토큰 값과 바이트 값을 섞어 뺍니다. (3) Memory 사실 한도 512 KiB 는 하루 최대치 위의 둥근 수이고 모델 창과 관계가 없습니다. e-masc-the-leader 는 이미 약 444 KB 입니다. (4) Curator 가 이웃 사실을 BM25 상위 K개로 고르는데, 놓치는 비율을 재는 하네스가 main 에 없습니다.

## X3 렌즈 3: 스텁·조용한 실패·catch-all·기본값 삼킴

09-23~30 비테스트 .ml 추가 110,183줄에서 패턴 hit 857건을 뽑았다. 그중 앞뒤를 읽은 것은 약 250건이다. 입력이 실제로 들어올 수 있고 막는 곳이 없음을 끝까지 따라간 P2 는 2건이다. 하나는 Stagehand exact lane 만 쉼 순서(backpressure)를 안 쓰는 6곳 중 5곳 대 1곳 문제다. 다른 하나는 production 6곳이 전부 no-op 으로 넘기는 measurement 훅이다. 나머지 hit 는 대부분 파서의 `_ -> None`, 닫힌 집합의 `_ -> false`, 예외 뒤 로그 같은 의도된 코드였다. 예외 핸들러는 전부 로그를 남기거나 다시 던졌고, 문자열 파서는 전부 None/Error 를 돌려줬다. 이 렌즈의 새 결함 밀도는 낮다. 09-29 의 RT-S6 같은 '항상 입력을 돌려주는 함수'는 새로 만들어진 것을 찾지 못했다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| X3-02 | P2 | `packages/agent_core/lib/llm_provider/exact_output.ml:1964-1994` | #40397 (draft)가 exact_output.ml 과 test_exact_output_flow.ml 을 같이 고친다. 이 정리는 그 PR 뒤에 한다. | execute_flow_once 의 measurement 훅 두 개는 production 6곳 모두 아무것도 안 한다 | production 에 쓰는 곳이 없으니 두 인자를 필수에서 빼거나 지운다. 측정이 flow 안에서 receipt 만 남기게 하고, 막는 훅이 정말 필요해질 때 그때 다시 만든다. before_dispatch 와 before_advance 는 3곳이 실제로 쓰므로 선택 인자(?before_dispatch)로 바꾼다. | 확인 |

## X4 렌즈 4: 숫자만 맞춘 작업 (테스트·증거·측정·게이트 제거)

가장 큰 것은 증거 문서와 라이브가 다른 한 건입니다. Stagehand 는 fixture 한 번 성공을 '라이브에서 돈다'고 적었는데, 그 뒤 Keeper 호출 10건은 전부 실패했습니다(X4-01). 게이트를 지운 뒤 실제로 깨진 것은 변경 기록 조각 11/68개이고, 릴리스 스크립트가 거절합니다(X4-02). main 에서는 09-30 18:49 이후 커밋 75개 동안 빌드·테스트 실행이 0회입니다. 야간 전체 테스트는 지우기 전 5일 중 4일이 빨강이었습니다(X4-04). 지우기 전 검사 98개를 스냅샷 복사본에 다시 돌렸더니 진짜 위반은 1개(변경 기록)였습니다. 지금까지는 지운 검사 때문에 놓친 결함이 거의 없습니다. 다만 지운 검사를 '돈다'고 적은 문서·주석이 43개 파일에 남아 있고(X4-05), 부르는 곳 없는 스크립트도 많습니다(X4-06). 증거 폴더는 8곳의 수치를 원본에서 다시 계산해 모두 맞았고, manifest 해시 505개도 맞았습니다. 증거 쪽 정직성은 좋습니다.

| id | sev | file:line | 열린 PR · 09-29 | 한 줄 결함 | 고치는 방향 | 판정 |
|---|---|---|---|---|---|---|
| X4-01 | P1 | `docs/evidence/browser-lanes-audit-20260929/README.md:3-8` | 없음. #40194 는 TUI 선택 화면만 다룬다 | Stagehand '라이브 활성화' 증거는 fixture 한 번의 성공이고, 그 뒤 Keeper 호출 10건은 전부 실패했어요 | 1) 증거 문서에 '라이브 Keeper 호출 0/10 성공'을 적고 '활성화 확인은 fixture 1회'로 범위를 좁힌다. 2) Stagehand 모델 호출마다 slot, 소요, 결과를 한 줄 남긴다(L1-04 와 같은 뿌리: exact lane 호출 기록 없음). | 확인 · High |
| X4-02 | P2 | `changelog.d/40282.md` | #40313 (조각 11개를 손으로 접음. 검사는 안 고침) | 변경 기록 조각 68개 중 11개가 형식 검사를 통과하지 못하고, 릴리스 bump 가 거절해요 | 11개 조각을 형식에 맞게 고친다(첫 줄에 `### Changed` 같은 머리글, 문장은 `- ` 로 시작하고 `#번호` 를 인용). changelog.d/README.md:18 문장을 사실대로 고친다. 형식 검사를 PR 경로에 되돌릴지는 운영자 결정이다. 이 검사는 문구 휴리스틱이 아니라 파일 구문 검사다. | 확인 |
| X4-05 | P2 | `docs/audits/2026-09-30-ci-gate-cleanup.md` | #40234 본문에 해당 문장이 있음(수정 PR 아님) | 지운 검사가 '돈다'고 적은 문서·주석·이슈 문장이 43개 파일에 남아 있어요 | '폐기됐다' 안내를 달지 말고 문장을 지운다. ci-gate-cleanup.md 는 '유지' 표를 지우고 삭제 목록만 남기거나 통째로 지운다. 주석 6곳은 규칙 문장만 남기고 스크립트 이름을 지운다. test.yml 은 머리말을 현재 모양으로 줄이고 schedule 전용 step 을 지운다. 문서 36개는 파일별로 해당 문장만 지운다. | 확인 |
| X4-03 | P3 | `test/test_tui_decode.ml:12135-12160` | 없음; 09-29 TU-F01, TU-F04 (09-29 되풀이 원인 4-1). 같은 사례: D10-01, D10-04 | 서버 시험과 TUI 시험이 같은 거절 응답을 서로 다른 모양으로 고정하고, 초대 시험은 127.0.0.1 을 공개 주소로 고정해요 | 서버가 만든 JSON 을 fixture 로 쓰고 TUI decoder 시험이 그것을 읽게 한다(09-29 근본 수정 그대로). 먼저 Server_refusal 한 종류부터: 서버 쪽에 typed 디코더를 두고 TUI 가 그것을 쓰면 철자가 한 곳에만 있다. | 확인 |
| X4-06 | P3 | `scripts/ci/run-edited-tests.sh` | 없음 | 부르는 곳이 없는 검사 스크립트 16개와 run-edited-tests 사슬 2,263줄이 남아 있어요 | 호출자가 없는 파일을 지운다. test-modules-are-wired 같은 쓸모 있는 검사는 지울지 PR 경로나 release 단계에 두고 쓸지 운영자가 정한다. 지우기 전에 모듈 별칭·include 로 부르는 곳이 없는지 한 번 더 본다. | 확인 |

### 기각된 발견

| id | 영역 | 한 줄 | 사유 |
|---|---|---|---|
| D1-04 | D1 | 실패를 쉼으로 적는 규칙이 걷기마다 다르다. Codex 사용량 판정 표만 4개다 | 설계대로: 코드 주장은 대부분 맞다. runtime_exact_lane_backpressure.ml:69-89 note_cause 는 Rate_limited 만 적고 나머지 Provider_response_refused 는 와일드카드로 버린다(다른 refusal 은 12종이 아니라 13종, exact_output.mli:250-271). |
| D1-05 | D1 | #39997 최종 코드는 소진된 Codex 계정을 쉬게 하지 않는다. RT-R1 은 열려 있다 | 설계대로: 코드 서술은 맞다. runtime_provider_usage_read.ml:585-606 read_codex_after_spent_usage_refusal 은 로그만 남기고 window 를 안 쓴다. 그러나 회귀도 오류도 아니고 리뷰를 거쳐 정한 동작이다. 근거 셋. |
| D1-07 | D1 | usage-read 가 '소진'이라 해도 429 경로는 그것을 읽지 않는다 | 설계대로: 코드 서술은 맞다. keeper_turn_driver.ml:909-915 는 429(Rate_limited)에서 note_rate_limit 만 하고, usage 읽기는 Authorization_refused(403)에서만 부른다(:948-950). 그러나 429 를 일부러 후보 단위 증거로만 둔 결정이다. |
| D4-06 | D4 | Skill 발견 목록이 26일에 5.2배로 늘었고, 27명 전원이 같은 목록을 매 요청 싣는다 | 설계대로: Available 목록을 defer 없이 싣는 것은 의도된 설계다. config/tools/keeper_skill.toml:5-8 이 '# Keep discovery resident: this schema carries the Available Skill list. |
| D4-08 | D4 | Task 에 고정한 Skill 이 지워지거나 revision 이 바뀌면 그 Keeper 의 모든 턴이 막힌다(잠재) | 설계대로: 코드 경로는 맞다: keeper_task_skill_turn.ml:33-60 resolve_with_task_ids 는 snapshot 에 없거나 revision 이 다르면 Error, resolve_observations(:192-214)가 그 Error 를 그대로 돌려주고,… |
| D4-10 | D4 | keeper_skill_publish 정의가 매 요청에 실린다. 형제 keeper_skill_validate 는 같은 기준으로 09-24 에 defer 됐다 | 설계대로: config/tools/keeper_skill_publish.toml 에 defer_loading 이 없는 것은 맞다(tool_definition_toml.ml:839-844 기본 Always_loaded). 그러나 의도된 결정이다. |
| L1-07 | L1 | #39972 뒤에도 Codex 이어받기의 12% 가 전체 바이트의 55% 를 다시 보낸다 | 설계대로: 낭비 수치는 재현된다. |
| D8-09 | D8 | 반감기는 미구현이고 헌법은 이미 규칙으로 적혀 있다 | 설계대로: 직접 확인: constitution.xml:210-223 세 번째 규칙과 no_wall_clock_death 예외가 적혀 있다. candle_balance.ml:1-29 는 Paid 합만 더하고 시간을 받지 않는다. candle_config.ml:51-58 은 ['payout'] 만 허용하고 모르는 키를 거절한다. |
| D6-10 | D6 | Jev 의 not_relevant 는 끝이 아니라서 하루 4,257번 LLM 이 다시 판정한다 (운영자 결정 필요) | 설계대로: 설계 문서가 이 동작을 명시합니다. |
| D7-04 | D7 | 사람이 확정한 Completed Goal 을 Worker 가 되돌릴 수 있고, 되돌린 앞 단계는 drop 이벤트에 안 남는다 | 설계대로: 코드 경로는 맞다. |
| D12-05 | D12 | Board 저장은 6.5 KB 가 바뀌어도 22.6 MB 를 통째로 쓰고, 수정 경로는 #39989 의 행 캐시를 아예 안 씁니다 | 설계대로: 코드 사실은 맞다. board_votes.ml:954-961 에서 had_dirty 이면 posts, comments, vote log, reactions 를 모두 다시 렌더한다. 저장은 board_core_persist.ml:453-470, 493-505 에서 Fs_compat.save_file_atomic 으로 파일 전체를 바꾼다. |
| D9-03 | D9 | 모자이크용 축약 그림이 눈·방울·체형·장신구를 버린다 | 설계대로: render_compact_posed(keeper_portrait_draw.ml:1207-1283)는 b.eyes, b.drips, half_width, twin_flame, flame_size, horn_length, e.face/neck/head/hand 를 읽지 않는다. |
| D10-05 | D10 | 운영자가 조종권을 강제로 풀 길이 없다: Running·Failing·Crashed Keeper 나 Worker(비 Keeper) 가 쥐면 재시작까지 그대로 | 설계대로: 호출 경로는 맞다. lib/keeper/keeper_dos_controller.ml:46-71 holder_left 는 Running\|Failing\|Draining\|Restarting\|Crashed\|Offline 이면 None 이고 Worker/Admin credential 도 만료 없으면 None(Some _ -> None). |
| L3-06 | L3 | keeper 체크포인트 76MB 를 매 저장마다 두 번 통째로 쓴다 | 반박됨: '매 저장마다 체크포인트와 history 사본을 각각 통째로 쓴다'는 틀립니다. |
| L3-13 | L3 | dune cache 63.9GB, 자동 trim 없음 | 반박됨: '자동 trim 없음'이 틀렸다. ~/Library/LaunchAgents/com.dancer.dune-cache-trim.plist 가 있고 launchctl list 에 등록돼 있다(종료 코드 0). 내용은 `dune cache trim --size=5GB` 를 StartInterval 21600초(6시간)마다 실행한다. |
| D11-01 | D11 | Fusion 자리 걷기만 한도 소진 기록을 읽지 않는다 | 설계대로: 코드 사실은 맞다. fusion_seat.ml:12-47 은 ordered_candidates 를 선언 순서대로 걷고, rg 'Runtime_quota_window' lib/fusion 은 note_* 쓰기 5곳(fusion_official_client.ml:336,344,346,360,516)뿐이다. |
| D11-02 | D11 | snapshot_file 소스는 모든 도구 완료에 깨고, 깰 때마다 observation 파일이 쌓인다 | 설계대로: 코드는 인용대로다: lane_addon_sources.ml:157-163 Snapshot_file -> true, lane_addon_runtime.ml:374-381 지문 비교는 Source_changes 이면서 snapshot_files_only 일 때뿐, lane_addon_store.ml:170-176… |
| D11-04 | D11 | '한 레지스트리 한 행' 은 타입만 만들어졌고, Lane 목록은 아직 다섯 길로 따로 읽힌다 | 설계대로: 사실은 맞다. |
| D13a-03 | D13a | Home 의 '마지막 대화' 기록이 모든 채팅 방문마다 operator 소유 runtime.toml 전체를 다시 쓴다 | 설계대로: #40137 본문(머지 09-30 10:43Z)에 '각 방문이 쓴다. 최근 대상 쓰기 억제 캐시는 동시 설정 변경에서 안전하지 않아 뺐다'고 적혀 있습니다. 즉 매 방문 쓰기는 검토 끝에 고른 설계입니다. docs/TUI-GUIDE.md:250,2226 도 같은 동작을 명세로 적습니다. |
| D13a-06 | D13a | 서버가 60초마다 GitHub GraphQL 로 열린 PR 을 읽지만 읽는 화면이 없다 | 설계대로: docs/rfc/RFC-0465-pull-requests-reach-the-overview.md:14-16 에 '2026-09-25 운영자 결정으로 Team 행·Overview PR 표시 제안은 측정 중심 TUI 가 대체한다. 서버의 PR 조회 API와 Keeper 귀속 규칙은 별도 기능으로 남는다'고 적혀 있습니다. |
| D13b-02 | D13b | Home 에서 연 요청 화면이 읽기 실패 한 번에 닫히고, 쓰던 답 초안을 버립니다 | 설계대로: 흐름은 맞습니다. masc_tui_types.ml:11189-11194 kept_rows_reading 이 observed+error 를 Approval_stale 로 만들고, 11283-11297 이 current=false 행을 빼며, 11384-11389 reconcile 이 상세를 닫습니다. |
| D15-05 | D15 | keeper.en.md 는 읽는 곳 없는 영어 사본이고 5곳 이상 낡았다 | 반박됨: 핵심 주장 '읽는 곳이 없다'가 틀립니다. dashboard/src/components/tools/prompt-registry-panel.ts:698 이 `const sourceKey = language === 'ko' ? |
| D15-06 | D15 | 코딩 Keeper 만 필요한 PR 승인·병합 절차가 26명 전원의 system 블록에 실린다 | 반박됨: 핵심 전제인 '코딩 Keeper 만 PR 절차가 필요하다'가 틀렸습니다. 라이브 <base-path>/.masc/tool_calls/2026-09/30.jsonl 에서 `gh pr`·`gh api`·`pulls/` 입력을 센 결과, 26명 중 24명이 쓴 호출이 10,657건입니다. |
| D15-07 | D15 | 역할과 무관한 도구와 Skill 목록이 26명 전원의 도구 배열에 실린다 | 이미 고쳐짐: already_fixed: '공식 클라이언트 레인이 defer_loading 을 따르지 않는다'는 스냅샷에서 거짓입니다. #39455(09-27 머지, 라이브 부팅 37e390738d 보다 앞)가 선언을 두 레인 wire 에 싣습니다. |
| D16a-09 | D16a | 'lane' 한 단어가 8가지 이상 뜻으로 쓰여요 (Glossary 개정안) | 설계대로: 이미 머지된 RFC docs/rfc/RFC-every-lane-is-one-row-in-one-registry.md (PR #39388, 09-27 머지) 가 같은 문제를 다룸. :52 'glossary 는 이 중 일부를 이미 나눴다 ... |
| D16a-10 | D16a | '격리' 한 단어가 서로 다른 일 6가지에 쓰여요 (Glossary 개정안) | 설계대로: glossary 에서 '격리\|quarantine' 줄은 rg -c 로 36줄(감사관은 47번이라 적음, 단어 횟수와 줄 수 차이일 수 있어 미확인). |
| D16b-04 | D16b | TUI 로더가 서버를 건너뛰고 backlog·goal store·Keeper meta 를 직접 읽는다 (09-23 #1, 아직 열림) | 설계대로: 줄 번호는 맞다(loader 75, 102, 160, 222, 241). 그러나 docs/rfc/RFC-tui-server-lifecycle.md 0절과 2절이 'TUI 는 디스크 .masc/ 를 직접 읽어 서버 없이 관찰한다. 디스크 단독 관찰이 기본으로 남는다'고 정해 놓았다. |
| D16b-06 | D16b | Board attention 후보 레코드가 Board 의 `board_signal` 을 통째로 들고 파일에 쓴다 (09-23 #4) | 설계대로: 인용한 줄은 맞다: candidate.mli:168 은 `signal : Board_dispatch.board_signal`, board_dispatch.mli:73-81 은 title/content/author/hearth/updated_at 을 가진다. 하지만 영향 주장은 틀렸다. 저장 모양은 Board 타입이 정하지 않는다. |
| W1-06 | W1 | MASC 저장소 전용 작업 규칙이 모든 Keeper 의 공용 프롬프트에 들어 있다 | 설계대로: config/prompts/keeper.md:35 와 라이브 .masc/config/prompts/keeper.md:35 에 같은 문장이 있다. |
| W2-09 | W2 | provider 의 healthcheck.path 는 설정 마법사가 모든 HTTP provider 에 적어 넣고 로드할 때 검사까지 하지만, 그것으로 상태를 확인하는 곳이 없다 | 반박됨: bin/main_eio.ml:1712 의 "healthcheck_path" 는 죽은 출력이 아니라 runtime-wizard-catalog 출력이다. |
| X1-02 | X1 | runtime id `<provider>.<model>` 를 첫 점에서 자르는 곳이 클라이언트에 4곳 있습니다 | 설계대로: 코드 인용은 맞음(runtime_schema.ml:612-614 binding_key, masc_tui.ml:17850-17870, masc_tui_types.ml:10583, runtime-toml-config.ts:812, runtime-exact-lane-editor.ts:31). |
| X2-01 | X2 | checkout 신선도를 900초로 갈라 Keeper 에게 current 또는 unverified 라고 알려요 | 설계대로: "주석 없음" 주장이 틀렸어요. keeper_sandbox_control.ml:335-338 에 근거 주석이 있어요: 5분 동기화 주기 3번 치를 정상 스케줄러 흔들림 허용치로 잡고, 동기화 주기가 바뀌어도 두 probe 경로가 같은 값을 쓴다고 적혀 있어요. |
| X2-02 | X2 | Curator 입력 한도가 토큰에서 토큰과 바이트를 섞어 빼요 | 설계대로: RFC Q2 (docs/rfc/RFC-workspace-curator-curates-changed-facts.md:159)가 이 계산을 구현 결정으로 적어 둬요: 슬롯별 context window 에서 출력 토큰 예산과 출력 스키마 바이트를 빼고 가장 작은 값을 렌더링된 프롬프트의 바이트 상한으로 쓰고, 창이나 출력 예산을 모르면… |
| X2-03 | X2 | Memory 사실 한도 512 KiB 는 하루 최대치 위의 둥근 수이고 모델 창과 관계가 없어요 | 설계대로: 512 KiB 는 근거 없는 둥근 수가 아니에요. PR #39755 본문 'Why 512 KiB'에 2026-09-28 14:02:59Z 측정(28 Keeper, 최대 464,514 바이트)과 증거 파일이 있고, 목적은 저장소 증가 상한이에요(이슈 #25052). |
| X2-04 | X2 | Curator 가 이웃 사실을 BM25 상위 K개로 고르는데 놓치는 비율을 재는 하네스가 없어요 | 설계대로: RFC(status Draft)가 이 한계를 스스로 쓰고 계획에 넣었어요. §3(:140) '이웃 검색의 한계는 실제 문제다 ... |
| X3-01 | X3 | Stagehand exact lane 만 slot 쉼 순서와 쉼 기록을 안 쓴다 (6곳 중 5곳은 씀) | 설계대로: 코드 사실은 맞다. |
| X4-04 | X4 | main 에서는 09-30 18:49 이후 빌드·테스트 실행이 0회이고, 마지막 야간 전체 테스트는 5일 중 4일 빨강이었어요 | 설계대로: gh run list 로 숫자를 다시 셌고 맞다. main 의 마지막 Stack Core build 는 09-30T09:49:51Z 취소, 그 앞 09:34:15Z 실패(0c37b5c285)다. 마지막 Test 는 08:47:03Z 실패(f0f66a68fb)다. |

## 09-29 발견 중 일부만 고쳐졌거나 나빠진 것

### S1 RT-* 발견 상태 확인

27행 확인 (스냅샷 727fc53123). fixed 7, partial 3, open 17. fixed는 C1~C4(#39972), S1·S2·S7(#40006). partial은 R1(#39997은 Keeper 경로만), R5, A7. worse와 moot는 없다. 열린 PR 중 이 행들의 결함을 직접 다루는 것은 없다. #40139·#40213·#40172는 같은 파일을 건드리는 리팩터와 기능 PR이다. 코드는 스냅샷에서만 읽었고, 빌드·테스트·서버 호출은 하지 않았다.

| 상태 | 개수 |
|---|---|
| 고쳐짐 | 7 |
| 일부만 고쳐짐 | 3 |
| 그대로 열림 | 17 |

| id | 09-29 sev | 상태 | 근거 |
|---|---|---|---|
| RT-R1 | P1 | 일부만 반영(관측 갱신) | #39997 뒤 Keeper Codex 경로는 사용량 관측을 갱신한다. 스냅샷 727fc53123의 runtime_provider_usage_read.ml:593-604는 거절된 limit_id를 알 수 없어 reset 기반 account rest를 추론하지 않는다고 명시한다. 원래 지적한 reset까지의 쉼은 구현된 것으로 셀 수 없다. 이는 D1-05에서 기각한 설계 변경 요구와 구분한다. Fusion one-shot도 관측만 기록한다. |
| RT-R5 | P2 | 일부만 고쳐짐 | refresh_scope가 매 주기 catalogue를 다시 읽어 주기를 바꾸고, 없어지면 멈춘다(runtime_provider_usage_read.ml:324-334). 그러나 반복 대상 목록은 부팅 때 한 번 만들어진다(:337-348). 부팅 뒤 새로 선언한 refresh-s는 시작되지 않는다. |
| RT-A7 | P2 | 일부만 고쳐짐 | #40096 뒤 모델 set은 여러 계정이 공유하므로 계정을 지워도 남는 것이 의도다(runtime_account_removal.ml:194-211). 저장 뒤 검사도 after.models = config.models를 요구한다(:292). 계정 전용 명시 바인딩의 모델 표가 남는지는 확인하지 못했다. |

이하 S2·S3·S5의 본문 합계는 문서에 보존된 상태 표와 맞췄다. 이번 문서 정정으로 과거의 전체 항목을 다시 측정하거나 판정한 것은 아니다.

### S2 MM-* 발견 상태 확인

아래 상태 표의 MM 합계는 28개다. 고쳐짐 4 (M1, M2, M5, C1), 일부만 2 (M3, S3), 그대로 열림 17, 위치를 못 찾음 5 (W6~W10). 나머지 open 행은 09-29 이후 그 파일을 건드린 커밋이 없어 결함이 그대로다. 근거: 스냅샷 727fc53123 에서 각 위치를 열어 봤고, base 99076b1308 이후 커밋을 파일별 git log 로 대조했다. 열린 PR 199개 중 이 행들을 실제로 다루는 PR 은 못 찾았다(파일명만 겹치는 PR 은 무관한 리팩터링). 스냅샷 코드 기준이다. 라이브 서버 소스는 4b881ab570 이라 그 뒤(#40019 등)는 라이브에 아직 없을 수 있다. Curator(W1~W5)는 라이브 runtime.toml 에 lane 이 없고 로그도 0건이라 코드 결함만 남은 잠복 상태다.

| 상태 | 개수 |
|---|---|
| 고쳐짐 | 4 |
| 일부만 고쳐짐 | 2 |
| 그대로 열림 | 17 |
| 위치를 못 찾음 | 5 |

| id | 09-29 sev | 상태 | 근거 |
|---|---|---|---|
| MM-M3 | P1(예측) | 일부만 고쳐짐 | #40001 이 사실이 안 바뀐 Librarian commit 을 건너뛰고, 예산 검사는 actual<previous_bytes 면 통과시킨다. 그러나 늘기만 하는 쪽은 그대로다. 라이브 memory-current.json 최대 540 KB(e-masc-the-leader), 3개가 460 KB 이상이다. 09-28~30 로그에 'exceed commit budget' 은 0건이다. |
| MM-S3 | P2 | 일부만 고쳐짐 | gh pr view 39881 은 MERGED 다. 옛 snapshot 파일은 라이브에 24개 남아 있다(09-29 는 25개). CHANGELOG.md:227 은 지워도 된다고 적는다. |

### S3 DM-* 발견 상태 확인

42행 확인 (DM-GT-11 은 09-29 발견 목록에 행이 없어 위치를 못 찾음). 아래 상태 표의 합계: 고쳐짐 7, 없어진 코드 2, 일부만 4, 그대로 열림 28, 위치를 못 찾음 1. 기준은 감사 시점의 origin/main 727fc53123. 코드에서 위치를 다시 열어 확인했고, 09-29 20:58 이후 바뀐 파일은 git log 로 확인함. 크게 닫힌 것은 세 묶음이다. 첫째 #40003 이 Board attention 일꾼이 통째로 멈추는 문제(BD-1)를 닫았다. 둘째 #39975 가 Goal owner 개념과 알림 scan 을 없애서 GT-01, GT-07, GT-12 가 닫히거나 무의미해졌다. 셋째 Play·Portrait P1 4건(PL-01, PL-09, PT-1, PT-2)이 머지된 PR 로 닫혔다. 나머지 P2 는 대부분 그대로다. 그 파일들이 09-29 이후 안 바뀌었거나, 바뀐 커밋이 다른 곳을 고쳤다. 열린 PR 가운데 #40171 은 PL-06 과 PL-07 을 같은 파일에서 고치려는 PR 로 보인다. 다만 PR diff 는 읽지 않았고 제목과 파일 목록만 봤다.

| 상태 | 개수 |
|---|---|
| 고쳐짐 | 7 |
| 일부만 고쳐짐 | 4 |
| 그대로 열림 | 28 |
| 없어진 코드라 해당 없음 | 2 |
| 위치를 못 찾음 | 1 |

| id | 09-29 sev | 상태 | 근거 |
|---|---|---|---|
| DM-BD-8 | P2 | 일부만 고쳐짐 | cap 은 여전히 env 로만 바뀌고 0 이하면 꺼진다(기본 100). 꺼질 때 WARN 한 줄이 생겼다(board_types.ml:328-338, board_dispatch.ml:277). 무음은 닫혔고 env 전용은 그대로다. |
| DM-PL-07 | P2 | 일부만 고쳐짐 | 두 곳 모두 이제 Play_invite.expired 를 쓰므로 만료 부분은 닫혔다. play_seat 는 Worker 역할을 자리에서 빼고, controller 는 credential 이 있는 이름이면 역할과 무관하게 남겨 둔다. 이 차이는 그대로다. |
| DM-GT-06 | P2 | 일부만 고쳐짐 | due_date 는 이제 쓰기 때 YYYY-MM-DD 로 검증하고 아니면 거절한다(goal_store.ml:673-683). 그러나 None 을 주면 기존 값을 유지해서 기한을 지울 방법이 여전히 없다. 읽을 수 없는 옛 값이 알림에서 빠지는 부분은 알림 scan 이 사라져서 무의미하다. |
| DM-CD-1 | P2 | 일부만 고쳐짐 | append 함수(cursor 조건)와 PayoutOwed 를 쓰는 주체(confirm_completion 안, 3.1, 3.2)는 RFC 가 코드와 맞는다. 초상화 호출부는 RFC 가 두 곳이라고 적지만 코드는 세 곳이다(DM-PT-3). |

### S4 TU-F01~F30 상태 확인

30행 중 fixed 5(F01, F02, F04, F17, F18), partial 2(F11, F19), open 23. 나머지 23행은 스냅샷(727fc53123)에서 코드를 열어 그대로인 것을 확인했습니다. 09-29 이후 커밋 중 이 행들을 건드린 것은 #39991, #39996, #39998, #40050 넷뿐이고, 열린 PR 중 이 행들을 다루는 것은 찾지 못했습니다(파일명 전수 대조는 안 했고 제목과 커밋 목록만 봤습니다). 웹 쪽 P0 두 건(F01, F02)은 닫혔습니다. 남은 것 중 F03, F10, F12, F13, F14, F16은 기본 조작이 실제로 어긋나는 결함입니다.

| 상태 | 개수 |
|---|---|
| 고쳐짐 | 5 |
| 일부만 고쳐짐 | 2 |
| 그대로 열림 | 23 |

| id | 09-29 sev | 상태 | 근거 |
|---|---|---|---|
| TU-F11 | P1 | 일부만 고쳐짐 | activity 와 msx 는 {ok, message}, keeper_chat_operations 는 error 에 code 를 넣고 message 는 따로, stream 은 {error:{message}} 입니다. Tui_decode.json_error_sentence(:1423)는 여전히 error 문자열만 읽으므로 이 넷은 09-29 때와 같습니다. |
| TU-F19 | P1 (web) | 일부만 고쳐짐 | 웹은 cost_unread_samples 로 못 읽음 턴을 표시합니다(cost-dashboard.ts:360-370). 서버가 보내는 metrics_read(state=failed 이면 전부 0 으로 리셋)와 unread_turn_rows 는 dashboard/src 어디서도 읽지 않아, 읽기 실패 Keeper 가 샘플 0개로 보입니다. |

### S5 TU-F31~F60 상태 확인

34행(TU-F31~F60 30행 + 웹 전용 P2 4건)을 스냅샷 727fc53123 에서 열어 확인했습니다. 아래 상태 표의 합계는 고쳐짐 0, 일부만 4(F34, F44, F49, F51), 위치를 못 찾음 1(웹 퍼센트), 그대로 열림 29입니다. 09-29 문서가 겹친다고 적은 #39892(F46), #39971(F47)은 둘 다 머지됐지만 그 행은 닫히지 않았습니다. 줄 번호는 많이 밀렸고 이름과 문맥으로 다시 찾았습니다. 열린 PR 이 이 결함을 직접 다루는 행은 못 찾았습니다(파일만 겹치는 PR 은 F34 한 곳에 적음).

| 상태 | 개수 |
|---|---|
| 일부만 고쳐짐 | 4 |
| 그대로 열림 | 29 |
| 위치를 못 찾음 | 1 |

| id | 09-29 sev | 상태 | 근거 |
|---|---|---|---|
| TU-F34 | P2 | 일부만 고쳐짐 | 앞 절반은 닫혔습니다. 할당 목록을 못 읽으면 Quota_failed 가 되고 이유가 그려집니다(masc_tui_types.ml:2038, overview_providers.ml:499). 뒤 절반은 그대로입니다. 사용량 행이 비면 ' no usage data' 만 그리고 notes 와 소진 안내를 버립니다. |
| TU-F44 | P2 | 일부만 고쳐짐 | Sandbox 는 닫혔습니다. keeper_control_hints 에 ?taken 이 생겼고 keeper_detail_tab_taken_keys 가 탭 키를 푸터에서 뺍니다(keys.ml:1618). GitHub 탭은 그대로입니다. 바인딩은 'P' 인데 디스패치는 p 와 P 를 둘 다 받습니다. taken 비교가 대소문자를 구분해서 p:pause 가 남습니다. |
| TU-F49 | P2 | 일부만 고쳐짐 | Keepers 목록의 d(프로젝트 변경 열기)는 keeper_actions(keys.ml:273-287)에 없고, Tools 바인딩에도 Enter 가 없습니다. Overview task x 는 Planning 상세로 옮겨졌고(masc_tui.ml:25556) Planning 표에 x 항목이 있는지, Runs 탭 j/k/Enter 가 표에 있는지는 확인 못 했습니다. |
| TU-F51 | P2 | 일부만 고쳐짐 | 푸터에는 position 인자와 with_position 이 생겼습니다(masc_tui_footer.ml:204). 하지만 Approval 상세와 Runtime 에서는 '[rows a-b/n] ' 을 힌트 문자열 앞에 그대로 붙입니다. 09-29 의 4곳 중 2곳만 확인했고 나머지 2곳은 확인 못 했습니다. |
