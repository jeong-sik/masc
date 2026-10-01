# 작은 것들과 확인 못 한 것 (2026-09-29 ~ 10-01)

[발견 목록](2026-10-01-week-audit-findings.md)에 못 올린 것이다. P3 는 기록하고 주제별로 모아 별도 스택에서 정리한다.
`확인 못 한 것`은 이 감사가 열어 보지 못한 자리다. 없다는 뜻이 아니다.

## D1 Runtime Failover · Lane · 계정·한도

작은 것들(P3)

- D1-06 쉼 기록이 프로세스 메모리에만 있다. 부팅 직후마다 소진된 계정을 다시 부른다
- D1-08 failed_attempt 마크와 exact lane 쉼이 /runtime/resolved 에 안 나온다
- D1-10 [providers.*] 표의 알 수 없는 key 를 조용히 무시한다. #40096 의 model-set 오타가 계정을 바인딩 0개로 만든다
- #39932 이후 Retry.error_message 가 Overloaded 와 PaymentRequired 에 '(retry_after: none)' 상수를 붙인다. 두 타입에 retry_after 필드가 없다 (packages/agent_core/lib/llm_provider/retry.ml:70-82)
- 라이브 runtime.toml 에 배정도 Fusion 도 안 가리키는 lane 11개(glm-first, glm-5-3-first, deepseek-first, sonnet, sonnet-high-then-codex, frontier, codex_subscription.codex-gpt-6-sol-xhigh, claude_code.* 4개).
- 라이브 runtime.toml 주석 'runtime.default 는 failover 가 없다'는 틀렸다. 같은 이름 lane 이 후보 9개다
- prompt_preset.restore_runtime 은 파일을 읽고 lock 밖에서 save_config_text 로 쓴다. edit_config_text(lock 안 읽고 쓰기)가 있다.
- exact-lane-runs-v5.jsonl 743MB 는 마지막 쓰기가 09-15 이다. 읽는 코드가 있는지 확인하고 없으면 지운다
- provider_usage_history 는 usage 이벤트마다 한 줄을 쓴다(Codex 계정 하나 하루 19,147줄). 읽기는 UTC 하루 최신 하나만 쓴다 (server_provider_usage_history.ml:38-52,140-206)
- HITL 의 CLI slot 걷기는 order_slots 를 부르지 않아 소진된 계정을 선언 순서대로 부른다 (hitl_summary_worker.ml:1402). 라이브 hitl lane 은 cli_slots 가 비어 있어 아직 영향 없음
- Codex 프레임 오류 문구에 threadId, turnId, item 종류가 없다 (runtime_codex_app_server.ml:1003)
- Muse 가 429('Subscription quota exhausted')를 turn 시작에서 받아도 effect fence 때문에 같은 turn 에서 다음 후보로 못 가고 cycle 이 실패한다. 다음 cycle 부터는 window 로 순서가 바뀐다 (09-30 glossary-maniac, gayo-yoga-leader 각 4건)

확인 못 한 것

- 왜 07:46~08:00Z 에 Librarian 폭풍이 줄었는지: runtime.toml 변경 이력이 없어 설정 변경인지 계정 회복인지 못 가린다
- Ollama HTTP slot 이 08Z 이후에도 매 pass 호출되는지의 직접 증거: 성공 경로는 로그가 없다. 09:16Z 실패 줄 하나와 exact-lane-runs-v6 의 CLI 선택 2,993건으로 추정했다
- Codex 신원 불일치의 실제 원인(하위 thread 여부): 실패 turn 의 원문 프레임을 열지 않았다
- glm-5.3-flash verifier 호출이 900초 무진행이 되는 이유(응답 지연, prompt 크기, 계정 동시성)
- 라이브 GET /api/v1/runtime/resolved 응답: 토큰이 필요해 읽지 않았다
- Claude Code, Codex CLI 의 429/한도 거절 요청이 계정 한도에 따로 세어지는지
- Antigravity 한도 거절의 typed 신호(agy 는 status: ERROR + 자유 문장만 준다)
- dashboard/src/lib/runtime-toml-config.ts(#40096)의 편집 동작
- #39972 의 Codex held_context 세부 로직(Memory 담당 범위)
- Fusion 실사용 경로의 쉼 동작(라이브 호출 없음), Stagehand(트래픽 0)
- RT-A6, RT-A8 상태(상태 에이전트 담당)

## D2 Keeper 한 명의 Context 생명주기 · Runtime 초과를 만들지 않는 순환

작은 것들(P3)

- D2-08 ?recovery_view 를 만드는 production 호출이 여전히 0곳이라 Some 분기가 전부 죽은 코드다
- D2-09 resume 이 보내지 않은 범위를 'transmitted_bytes' 로 적는다 (라이브에서 9~12배 부풀려짐)
- config/keepers/*.turn-boundaries.jsonl 18개(0.5MB)는 09-20 22:40 에 멈춘 옛 경로 잔재이고 코드가 읽지 않는다(현재 경로 keepers/<name>/turn-boundaries.jsonl). 지울 것.
- MM-C5 낡은 주석 그대로: keeper_official_client_host.ml:89-97 은 Claude Code 가 resume 에서도 --system-prompt 에 합친다고 쓰지만 실제로는 keeper_claude_code_runtime.ml:748-760 이 carried 메시지를 빼고 resume 프롬프트 앞에 붙인다.
- 저장된 history 가 없는 Codex 전용 Keeper(hole-finder)는 매 턴 History_restarted 와 turn_ended 두 줄을 쓴다(400줄 중 201줄). 'restart' 는 이전 위치가 모두 죽었다는 뜻이라 Librarian 판독에 잡음이다(keeper_agent_run_turn_helpers.ml:337).
- Antigravity 는 witness 가 없어 매 resume 에 carried context 전량을 보낸다(165건, 중앙값 130KB, 18.7MB/일). 코드가 이유를 적어 둔 설계이나 msx-retro-mania 한 Keeper 가 109건이다.
- #39761(체크포인트 history 오프로드)은 #39974 측정에서 개선이 확인되지 않았다(inventory p50 26.0~26.7ms 대 26.3~27.1ms). 유지할지 근거를 정할 것.
- 'Codex context compaction completed' 로그에 turn id 와 크기가 없어 어느 턴의 compaction 인지 시각 짝맞춤으로만 안다(keeper_codex_runtime.ml:486).
- turn-boundaries 증가(MM-C4): pr-updater 하루 약 320줄, 10일 0.87MB. 회전 코드는 없다. D2-01 루프가 있는 동안 Librarian pass 당 2회 전체 디코드가 늘어난다(비용 작음).
- last-prompt.json 이 턴마다 최대 470KB 다시 쓰인다(Keeper 당 파일 하나라 크기는 유한).
- jazz-developer 는 오늘 resume 16건에 compaction 43회라서 한 턴 안에서 여러 번 compaction 이 난다. 이 Keeper 의 작업 방식과 D2-02 의 창 점유가 함께 작용한 것으로 보이나 분리해서 재지는 못했다.

확인 못 한 것

- Claude Code·Muse 의 #39972 뒤 라이브 resume(데이터에 resume 이 없다: Claude 호출 전부 quota_blocked, Muse Start 9건뿐).
- item/started 신원 불일치의 wire 원인(raw-traces 에 프로토콜 frame 이 없고, Codex app-server 소스는 읽지 않았다). 6.1 sol high 와의 관계는 상관만 봤다.
- recall block 의 Keeper 별 토큰 환산(rollout 2개 표본만 잼). 한국어 비중이 큰 Keeper 는 바이트당 토큰이 더 크다.
- Agent Core 레인의 하루 stage save 횟수와 쓴 바이트(계측이 없다).
- 09-29 이전 부팅의 시간대별 resume 크기(09-30 로그만 분석했고 09-30 00:00Z 앞 구간은 안 봤다).
- Muse·Antigravity 의 capacity_bounded_model_input_projection 내부(읽지 않음). Codex 에서 더 작은 capacity 의 Agent Core 후보로 넘어가는 failover 는 코드 설계만 읽었고 라이브 사례는 찾지 못했다.
- Codex Start 171건 중 supersede 와 짝이 안 맞는 약 74건의 사유(첫 턴, snapshot 변경, 계정 전환 등).
- D2-01 의 continuity 실패 pass 하나하나가 정확히 모델 호출 하나인지(시각 짝맞춤은 pr-updater 89건 전부 성공했고 전체 1098건 매칭은 직전 run 기준이라 근사).

## D3 Librarian · Memory (생산·합성·소거·흡수·강화·반감기) · World Curator

작은 것들(P3)

- D3-05 facts 한도(512 KiB)에 가까운 Keeper 2명이 있고, 한도에 닿으면 같은 range 로 모델을 신호마다 다시 부른다 (잠복)
- 설계 결과 측정(고치자는 뜻 아님): 모든 슬롯이 quota 로 거절되던 09-30 14~17시 KST 에 Librarian 실패 회차 2,133건이 매번 슬롯 3곳(ollama 429 + Claude Code quota + Codex usage limit)을 시도했다. Codex 'usageLimitExceeded' 줄이 05~07Z 합계 5,207건.
- durable 읽기는 실패 원인과 상관없이 한 cut 씩만 읽는다(keeper_librarian_durable_consumer.ml:1331-1356, mark_failed 가 429 에도 남음). continuity 는 크기 때문이 아닌 실패에는 폭을 줄이지 않는다고 명시했다(keeper_librarian_queue_refresh.ml:363-372).
- 죽은 개념 문구(지우기 대상): keeper_memory_recall.mli:3 ('removed with the legacy memory bank'), keeper_memory_os_current.mli:409 ('used to also carry a whole-set keep list'), keeper_librarian.ml:631,…
- 이름 혼동: Keeper_memory_recall 은 JSONL 꼬리 읽기 모듈인데 이름이 recall 이라 Keeper_memory_os_recall(프롬프트 recall 블록)과 헷갈린다.
- keeper_memory_search_index.ml 의 search: (exclude_owner, max_results)의 곱으로 SQL 을 고르며 한쪽만 Some 이면 다른 쪽을 조용히 무시한다. 지금 호출 두 곳은 둘 다 Some 이거나 둘 다 None 이라 닿지 않는다.
- curator 이웃 수 K = owner_count − 1(server_workspace_memory_curator.ml:181)은 RFC Q3(이웃 K)가 열린 채 Keeper 수에 묶여 있다. owner_count 에는 toml 없는 저장소(taskmaster 72 facts, lab-sangsu 43, microvm-probe-829 0)도 들어간다.
- basis=derived fact 는 4,236개 중 2개(모두 Keeper 가 직접 쓴 것)다. 근거 유지 계산(maintain_supported_facts 등 약 200줄)과 프롬프트 문단이 이 2개를 위해 있다. 쓸모를 운영자가 판단할 것.
- 파일 크기 규칙(300줄+) 초과: keeper_memory_os_current.ml 3,170줄, keeper_librarian_runtime.ml 1,710, keeper_librarian_durable_consumer.ml 1,400, keeper_librarian_absorb_gate.ml 1,011.
- facts_budget 프롬프트 변수는 source 줄 바이트를 뺀다(keeper_librarian.ml:304-320, MM-M4 그대로). 최대 약 8 KB 차이라 영향은 작다.
- glossary: Continuity 계열이 9개(Snapshot, Synthesis Observation, Request Observation, Lag, Width, Measurement, Librarian Gap·Replay·Pass End)로 나뉘어 있고, 'Continuity Lag' 항목은 저장본이 시작 위치 cut 에 걸려 못 나아가는 상태를 말하지 않는다.

확인 못 한 것

- D3-03 합성 중단의 원인: 07시 전후로 바뀐 것이 입력인지 모델 행동인지 확인 못 함. 09-30 07시 전 회차의 모델·출력은 payload(18:46 이후만 남음)와 lane 기록(17시 이후만 있음)이 없어 비교하지 못했다.
- exact-lane-runs-v6 의 librarian_exact 기록은 09-30 17시부터라 그 전 슬롯별 성공·실패와 API 슬롯이 마지막으로 답한 시각은 못 봤다. 09-29 이전 Librarian 회차 수는 v5(09-15 까지)뿐이다.
- Librarian 의 Codex 사용이 계정 한도 소진(14~17시 usage limit, 10-07 까지)의 원인인지는 못 재봤다. 같은 계정을 다른 Keeper 작업이 쓰는지 미확인.
- 'found no fragments for N official line(s); passing them' 경고: 09-29 136건(줄 247개, 공식 클라이언트 turn 3,751개의 약 6.6%), 09-30 23건. 이 turn 들을 Librarian 이 못 읽고 지나가는 원인(fragment 생산 쪽)은 추적하지 못했다.
- 대시보드·TUI 가 continuity 지연('continuity behind n')과 D3-01 을 어떻게 보여 주는지는 서버를 호출하지 않아 못 봤다(코드상 continuity_unread_atoms 는 계산된다).
- World Curator 를 실제로 켠 실행은 하지 않았다(읽기 전용). MM-W2~W5, DM-BD-4·5·9 는 코드가 그대로임만 봤고 각각 다시 따라가지 않았다.
- checkpoint 읽기 비용: D3-01 의 매 시도가 checkpoint(pr-updater 82 MB 파일)를 다시 읽고 파싱하는지는 코드로만 봤고 시간을 재지 않았다.
- absorb gate 의 JEV 판정 품질과 문장 자르기 규칙(statements)은 이번에 보지 않았다.
- Terminal-Bench 경로에서 Librarian 이 쓰이는지와 그 비용은 이번 범위 밖이라 보지 않았다.

## D4 Skills 발행·발견·활성화와 재생성 (되풀이 풀이 → Skill)

작은 것들(P3)

- D4-03 Skill 사용량을 세 곳이 세 기준으로 세고, 스크립트는 '한 번도 안 쓴 Skill'을 잘못 알려 준다
- D4-05 원장 파일이 부팅 검사 목록에 없고, 원장 쓰기가 실패하면 Skill 읽기와 합성 실행이 막힌다
- D4-09 모델 응답마다 Skill 과 상관없이 원장 잠금과 파일 읽기를 한다
- D4-11 Skill 종류와 실행 방식이 문자열로 저장되어 같은 파일 안에서 다시 문자열로 비교된다
- MM-S3·S5 잔재: skill-activations.json 24개 8.9 MB 는 읽는 곳이 없다(옛 활성화의 유일한 사본이라 백업 뒤 삭제). skill_source_config.ml 의 Ignored_resource_read_max_bytes 알림과 config/runtime.toml:15 주석은 없어진 키를 설명한다.
- 문서가 코드와 다르다: RFC skills-as-tools §5 '지시 Skill 은 도구 스키마 0 B'(지금 9,866 B), RFC-0411 은 Draft 인데 구현됨, RFC self-authored-skills 의 'composition 오류는 강등'(편집기는 거절함), RFC peer-signal 의 '삭제는 SKILL.md 만 옮긴다'(#38594 이후 빈…
- keeper_skill_body_ast.ml:26-56 의 fence 파서는 CommonMark 와 다르다(들여쓰기 무제한, 백틱 fence 의 info 안 백틱 허용). 들여쓴 예시가 진짜 composition 선언으로 읽힐 수 있다. 라이브 Skill 에는 그런 예가 없다.
- keeper_capability_search 는 FTS5 문법을 그대로 받아 09-29·09-30 에 27/865건(3.1%)이 하이픈·콜론·슬래시 때문에 거절된다. #40049 뒤에도 같은 비율이다. 용어 목록을 받아 안에서 따옴표를 씌우는 typed 질의가 낫다.
- work-intake 는 한 턴에 2회 이상 불린 턴이 141개(추가 158회, 1.9 MB, 전달 바이트의 6.5%)다. code-reviewer 는 같은 keeper_skill 호출 3회로 09-30 에 4번 yield 됐다.
- scripts/harness/workload/skill_activation_events.py(805줄)의 시험 fixture 는 Python 이 쓴 행이다. OCaml 이 쓴 로그로는 시험하지 않는다. 오늘 라이브 27개로 확인해 맞았다.
- test_keeper_tool_schema_bytes.ml 의 ceiling_bytes 는 #40049 가 129,395 에서 130,262 로 측정값에 맞춰 올렸다(여유 0). 매 PR 이 올리는 숫자 검사다. 09-30 의 '임의 숫자 검사 CI 를 안 만든다' 규칙과 결이 다르다.
- keeper_skill_composition_evidence.ml save_latest 는 기존 파일을 읽고 버린다(_existing). 파일 하나가 깨지면 그 revision 의 evidence 저장이 계속 실패한다. 옛 revision·지운 Skill 의 파일 19개(584 KB, what-arrived 291 KB)가 남아 있다.
- POST /api/v1/skills/evidence(Keeper_skill_activation_discovery.discover)는 원장 27개(4.2 MB)를 두 번 통째로 읽고, TUI 는 키를 누르면 이벤트 루프에서 동기로 부른다(bin/masc_tui.ml:18077-18092).
- 이름 없는 상수와 중복: keeper_skill_catalog.ml:258 의 1_048_576, server_keeper_skill_publish.ml:5 의 'project-agents' 문자열, keeper_skill_inventory.ml:52-59 의 catalog_status_of_entry 는 #40085 가 만든 effective 와 같은 판정을 따로…

확인 못 한 것

- 빌드 금지라 summarize_by_scope 의 실제 CPU 시간을 못 쟀다. 제곱 계산은 코드로만 확인했다.
- 토큰이 필요한 POST /api/v1/skills/evidence 의 응답 시간을 못 쟀다.
- Agent Core 레인의 현재 하루 요청 수를 못 셌다. 09-23 값 5,047건(도구 정의 주석)을 인용했다.
- prompt cache 적중률과, Skill 발행·수정이 27명의 캐시 접두를 깬 횟수는 측정하지 못했다.
- work-intake 보드 노드를 바꿨을 때 합성 결과가 16,384 B 한도 안에 드는지 재측정하지 못했다.
- browser 두 composition 의 실패 원인(live-follow-read 5/5 오류 destination_url_not_observed, navigate-read 11/49 오류)은 lane·browser 담당 범위라 파고들지 않았다.
- 터널 도메인(masc.crying.pictures)에서 무인증 읽기가 되는지는 보지 않았다. 루프백에서는 /api/v1/skills 와 /api/v1/dashboard/tools 가 토큰 없이 200 이었다(Access Control 담당이 볼 일).
- 옛 skill-activations.json 24개는 활성화 개수만 셌고 스키마 검증은 하지 않았다.
- keeper_skill_publish 의 Created_but_unpublished 복구 경로는 읽기 전용이라 실제로 시험하지 못했다.
- lane add-on 이 내보내는 Skill(publish_lane_skills)의 라이브 동작은 보지 않았다(라이브 source 는 config 의 5개뿐).

## L1 토큰·캐시·Skills·재전송 낭비 실측 (라이브)

작은 것들(P3)

- L1-06 `transmitted_bytes` 는 이어받기 요청이 보낸 크기가 아니라 carried range 크기다 (RT-C4 열림)
- 옛 형식 `traces/*/skill-activations.json` 24개(9.07 MB)를 읽는 코드가 없다(#39862 뒤 남은 데이터 잔재).
- finish_reason 문자열에 `yielded_after_repeated_tool_call:<turns_used>:<도구>:<횟수>` 를 합쳐 넣는다. turns_used 는 같은 Keeper 의 turn 마다 21146, 21147 처럼 이어져 턴 안 요청 수가 아니라 세션 누적으로 보인다(Low, 확인 못 함). 집계할 때 ':' 로 잘라야 한다.
- Board 판정 invalid_domain_output 148회(3.4%, 평균 약 200초): 모델이 `rationale_extra` 같은 필드를 더 붙여 엄격 검사에서 떨어진다.
- skill 도구 호출 로그의 keeper_name 이 455건 모두 `system` 이라 어느 Keeper 가 불렀는지 로그로는 알 수 없다.
- 09-29 감사의 '하루' 재전송 수치는 00:00Z~약 12:35Z 부분 하루였다. 다음 비교는 전체 UTC일이나 시간당으로 한다.

확인 못 한 것

- Claude Code 이어받기: 09-30 turn 이 6개뿐(quota_blocked)이라 #39972 효과를 잴 수 없다. Muse 는 09-30 9턴이라 억제 효과를 못 봤다.
- 요청 단위 캐시 미적중 원인: 기록이 turn 합계뿐이고 요청별 원인 필드가 없다. 위 원인은 새 내용, compaction, 새 스레드로 좁혔을 뿐이다.
- 바이트를 token 으로 바꾼 정적 block 점유율: 미측정.
- 실패 turn(finish None)의 토큰과 비용: 기록이 없다. exact lane 호출의 token: 기록이 없다(L1-04). 그래서 무산출 turn 의 비용은 끊긴 turn(usage 라벨 unavailable)까지만 셌다.
- TU-F55(TUI 폴링): 서버 접근 로그가 없고 TUI 프로파일을 안 돌려 비용을 못 잼.
- exact lane 실행 기록 v6 는 09-30 08:01Z 부터라 05~07Z 폭풍은 그 파일에 없다(로그 줄로 셈). 이전은 닫힌 v5(743 MB)에 있고 안 읽었다.
- 09-23~25 의 일부 행은 per_request 라 09-26 이전 일별 토큰은 다른 기준이다.
- Codex 이어받기에서 recall 이 안 바뀌었는데도 250 KB 이상인 10% 의 원인(compaction, 재부팅, held 초기화)은 분리하지 못했다.
- 라이브 서버 masc MCP 는 끝에 접속 거절(ECONNREFUSED)이 나서 쓰지 않았다. 모든 수치는 파일과 로그를 읽은 것이다.

## D5 Schedule · Event queue · Drain Queue · 자율(Autonomous/Proactive)

작은 것들(P3)

- D5-05 reaction ledger 는 보존 기간이 없고, 처음 보는 stimulus id 마다 전체를 처음부터 읽어요
- D5-06 schedules/signals 는 하루 1.6~1.9MB 씩 늘고 읽는 곳은 최근 20행뿐이에요
- D5-09 chat 에 막혀 미뤄진 cycle 이 30분 자율 경계를 써 버리고, 풀렸다는 wake 는 자율 turn 없이 Skip 돼요
- 대시보드 'Next due' 가 hold 중인 일정의 과거 시각을 보여요. server_dashboard_schedule_projection.ml:102 가 Due 를 포함해서, 라이브 sched-a580c 는 568초 지난 시각이에요.
- RT-S5 recurrence 생략 호환 경로: 09-28 35회, 09-29 8회, 09-30 0회 사용. 이슈 #39511 이 열려 있어요. 쓰는 곳이 없으니 지울 때예요(tool_schedule.ml:749-768).
- 'deferral debt cap reached' 로그가 대기 chat 이 없어도 start_child_if_needed 마다 찍혀요(keeper_owner.ml:1289). 같은 초에 3번도 나와서 관측이 chat 지연 횟수를 못 세요.
- autonomy_stats.jsonl 은 쓰는 코드가 없고 08-05 이후 그대로예요. docs/design/world-presets-measurement.md:28 은 원천 파일로 나열하고 RFC-0435:644 는 안 쓴다고 적어서 문서끼리 달라요.
- turn 기록의 turn_kind 'autonomous' 에 반응형 board turn(channel=turn, 09-29 2,981건)이 들어가요. '자율 turn 비율'로 읽으면 2.6배 부풀어요. 용어집도 자율을 turn 종류, lane, gate 세 곳에서 다르게 써요.
- Schedule_runner.signal_kind 는 값이 Due_candidate 하나뿐인 variant 예요(schedule_runner.ml:5-6).
- 라이브 일정 2개(sangsu-daily-movie-news, sched-757df354)는 payload 에 result_delivery 키가 아예 없어요(옛 형식). 소비자는 none 으로 읽어요.
- 은퇴 경로 cancel_keeper_schedules 는 큐 회수를 원장 lock 밖에서 해요. cancel_request 는 lock 안이에요. 남은 entry 는 owner-absent drain 이 거둬요(server_schedule_consumers.ml:1226-1290).
- dispatch detail 의 keeper_wake_reaction_ledger_status 는 항상 Recorded 로 하드코딩돼요(recorded 인 경로에서만 여기 오므로 무해하지만 상수 필드예요).
- terminal_wakes_retained_per_schedule = 32, schedules_forgotten_per_pass = 64, mailbox_capacity = 128 은 이름 있는 상수지만 근거를 코드 밖 측정에 기대요.

확인 못 한 것

- 자율 turn 중 도구 호출 0개(748개/일)가 실제로 '할 일 없음' 답인지는 확인 못 했어요. raw trace 파일이 이미 지워져 있어서 execution_ids 개수만 쟀어요.
- 09-30 turn 기록의 input_tokens 합(약 2.4B)과 output 0 은 계측 형식이 바뀐 것으로 보여 쓰지 않았어요(토큰 담당 몫).
- Schedules 화면이 실제로 얼마나 자주 새로 고쳐지는지와 D5-05 의 화면 지연은 서버를 호출하지 않아서 못 쟀어요.
- 09-30 서버 로그에 17~19분 무기록 구간이 4곳 있어요(00:28-00:47Z, 12:01-12:18Z, 12:19-12:36Z, 12:36-12:45Z). 21:19·21:36 KST 의 wake dispatch 1,042초·508초와 겹쳐요. 원인(멈춤·블록)은 확인 못 했어요.
- jazz-developer 큐의 board_attention 이 21~34시간 남는 이유는 Board 담당 몫이라 안 봤어요.
- keeper_owner.ml 의 chat operation store, 재시작 복구 부분과 schedule_domain.ml 의 cron·timezone 계산은 안 읽었어요.
- schedule update 가 옛 정의의 pending 회차를 회수하지 않아요. 다음 발화의 supersede 가 거두므로 rare 로 보고 조사를 줄였어요.
- transfer 된 wake 의 취소 경로(RT-S6 stub 과 이어짐)는 실측이 없어요.

## D8 Candle 원장 · 논공행상 분배 · 반감기 · Economy(turn spend·cost ledger)

작은 것들(P3)

- D8-03 cost 원장의 80.5%가 아무도 읽지 않는 raw 줄이고 보관 기한도 없다
- D8-04 DM-CD-4 상태: meta 를 먼저 커밋하고 원장 쓰기가 실패하면 카운터와 로그만 남는다
- D8-10 구매·지갑·착용 코드가 main 에 없고, keeper 는 지급받은 것을 알 길이 없다
- `Candle_payout_owed.write` 의 `None` 하나가 'Snapshot 없음', '이미 지급 대기', '이미 끝남', '같은 실행의 실패'를 합친다(candle_payout_owed.ml:31, candle_payout.ml owed_pass). 켜져 있는데 Snapshot 이 없으면 로그도 없다.
- `Candle_appraise.drain_once` 는 운영 호출자가 없고 시험만 쓴다(candle_appraise.ml:120-128). 일꾼은 pending+settle_one 을 쓴다. 시험이 운영 경로를 안 지난다. 지운다.
- 관계 판정이 keeper 가 아닌 담당자의 Task 에도 모델을 부른다(candle_appraise.ml:22-36). validate_settlement 이 후보 Task 전수 판정을 요구해서 뺄 수 없다. 받을 수 없는 Task 마다 호출 1번이다.
- docs/guides/candle-payout-policy.md 끝 문단이 낡았다('평가 모델, Paid 기록은 후속 구현'). 켜는 데 필요한 runtime.toml 의 candle_appraiser lane 도 안 적혀 있다.
- 용어집 Candle 항목의 '오류 시 Payout_failed' 는 기한을 읽을 수 없을 때 하나뿐이다. Payout_failed 에는 이유 필드가 없고 JSON 에 상수 문자열 `unreadable_due_date` 를 쓴다(candle_event.ml payout_failed_of_fields). 이유가 둘이 되면 닫힌 variant 여야 한다.
- `resolved_delta` 줄에는 resolution_status 가 없고 attempt 줄에만 있다(keeper_unified_turn_success.ml:389-415). 원장만 봐서는 턴 몫이 Exact 인지 알 수 없다.
- code-reviewer 는 meta 가 09-23 생성인데 원장에는 09-02 줄부터 있다(재생성된 keeper 의 옛 몫이 이름으로 합쳐짐, 원장/meta = 2.2배). Usage 는 meta 가 있는 keeper 만 읽어서 제거된 keeper 몫이 빠진다.
- `execute_http` 의 `rejected` 는 한 slot 이라도 잘못된 출력을 내면 이후 전송 실패까지 Invalid_response 로 분류해 pulse 재시도에서 빠진다(server_candle_appraiser.ml:47-56).
- weight_max 를 max_int 근처로 설정하면 가중치 합이 넘쳐서 모든 다중 keeper 지급이 Rejected 로 멈춘다(candle_config.ml:58, candle_math.ml:75-85). 운영자 설정 실수라 rare.
- 라이브 원장이 생기면 매 pulse(60초)마다 ledger 를 두 번 전부 읽고 파싱한다(candidates drain + pending). 지금 규모에선 무시할 수준이다(줄 수 = Goal × 5 정도).

확인 못 한 것

- 모델 판정의 실제 품질과 반복 안정성: 라이브가 Off 이고 실행하지 않았다(코드 읽기만).
- DM-CD-1·3, DM-GT-02·03·04, TU-F19 의 상태 확인은 다른 에이전트 몫이라 보지 않았다.
- msx-retro-mania 와 masc-pro-builder 의 원장이 meta 보다 큰 원인. 단일 줄 일치와 중복 줄은 없었고 옛 커밋 순서 때문일 것으로 짐작만 한다.
- OTel 카운터 `metric_emit_dropped{site=cost_event_write}` 의 라이브 값(서버 호출 금지). 시스템 로그 0건만 확인했다.
- 열린 PR 중 diff 를 읽은 것은 #40302 뿐이다. #40365, #40024, #40066, #40303 의 내용은 제목과 본문만 봤다.
- TUI 화면을 실제로 띄워 보지 않았다. 코드와 라이브 데이터 계산만 근거다.
- 스냅샷 727fc53123 과 라이브 소스 ccef0a8dab 사이 D8 파일 변경: GitHub compare 로 candle·cost·goal 파일이 없음을 확인했다(헌법·용어집·TUI 파일만 바뀜). TUI 비용 줄은 바뀌지 않았다.

## D6 Board 주의(attention) · 판정(verification) · Task 완료 루프

작은 것들(P3)

- D6-07 운영자 스냅숏의 quarantines 칸이 4초 걸린다
- `Verification_protocol.notify_stalled_verification`(runtime 이름 없음)은 테스트만 부르고 운영 경로는 `_with_runtime` 이다. 테스트가 운영 경로의 runtime 문구를 덮지 못한다 (lib/verification_protocol.ml, test/test_verification.ml).
- completion_authority_agent.ml:1274 `review_slots = Semaphore.make 4`, :19 `judge_few_shot_examples = 3` 이 이름만 있고 근거 주석이 없다.
- exact_flow.ml:524-528 주석 'not-relevant verdict drops the post ... so the LLM lane judges it again' 이 스스로 모순이다. 실제 동작은 LLM 재판정이다.
- Board 목록 캐시는 수정·pin·close·reopen·삭제에 이벤트가 없어서 TTL(15초)+읽기 1번 동안 옛 목록을 준다(server_board_list_http.ml:14-25).
- DM-BD-8: comment cap 이 아직 env(MASC_BOARD_COMMENT_COUNT_CAP)로만 바뀐다(board_types.ml:325).
- 지운 keeper 의 후보·파티션 원장이 남는다: lane-smith(09-30 23:45 shutdown) 후보 pending 395개.
- verification_run_registry.ml 주석 '이 원장의 실사용은 1MB 미만' 이 라이브 7.2MB 와 다르다.
- 서버 재시작마다 진행 중이던 review 가 Graceful_shutdown 으로 취소된다(09-29 47, 09-30 36, 중앙값 452초 소요분 버림).
- 블록 파티션 233개가 09-25~09-28 의 429 때문이다. #39186 이후에는 안 생기지만 아직 풀리지 않았다.

확인 못 한 것

- 브리프의 라이브 소스(4b881ab570, 19:55 부팅)는 사실과 다르다: 19:55 시작은 base path 잠금으로 FATAL 이었고, 그때까지 돈 서버는 19:04 부팅(3e22dc273c)이며 지금은 23:45 부팅(pid 72110, ccef0a8dab)이다.
- D6-07 의 4초가 락 경합인지 목록 복사인지 분리하지 못했다.
- GLM coding endpoint 가 strict JSON schema 응답 형식을 지원하는지 공식 문서로 확인하지 못했다(D6-04 수정안 1).
- keeper 별 drain 횟수가 왜 3명에 몰리는지 worker.run(2284-2437)의 wake 제어를 끝까지 읽지 못했다.
- verifier 시도 한 번의 토큰·비용은 사용량 원장과 join 하지 못했다.
- #39555 Comment_page.select 의 경계 계산은 diff 로만 읽었고 실행하지 않았다.
- TU-F05·TU-F07(TUI 디코더)과 DM-BD-2·6·9·10 상태는 이번에 다시 보지 않았다(상태 확인은 별도 에이전트).
- masc MCP 서버 연결이 거절돼 라이브 API 호출은 쓰지 않고 파일과 로그만 읽었다.
- Jev 호출 자체의 비용과 지연(api.typesafe.ai)은 재지 않았다.

## D7 Goal · HITL(Gate·승인·질문) · Access Control(auth·credential)

작은 것들(P3)

- D7-03 질문 답변 route 가 Worker 권한으로 열려 있다
- 죽은 개념 잔재: dashboard/src/keeper-delivery-provenance.ts:19,115 와 api/schemas/keeper-chat-delivery-provenance.ts:72-75 의 goal_notification·owner, work.test.ts·dashboard-goals.test.ts 의 kind 'goal_owner' 픽스처,…
- Goal 타임라인 mutation_summary 가 actor 없는 옛 goal_created 행 16개(전체 18개 중)를 '<missing payload.actor>' 경고로 그린다(dashboard_goals_types_timeline.ml:231-243). #39975 이전 행이라 정상이다.
- goal-1790663276268-59ef0a2d 의 due_date 가 '2026-09-29T21:00:00Z' 라 Goal_due 가 읽지 못한다. TUI 에 overdue 표시가 없고, 빈 값은 '안 보냄'으로 취급돼(tool_args.ml:32-35) 지울 수 없다. 읽을 수 있는 날짜로 덮어쓰면 된다(DM-GT-06 일부).
- goal_events 를 쓰는 raw emit_goal_event 호출이 7곳(workspace_goals.ml:736,776,925,949,1034,1051,1107)이고 upsert 3곳만 record_committed_goal_event 로 감싸졌다.
- keeper_ask_store.load_events 는 해독 실패를 경고만 하고 [] 를 돌려줘 질문이 목록에서 사라지고, answer 는 읽기와 추가 사이에 잠금이 없어 두 화면이 동시에 답하면 둘 다 Ok 를 받는다(keeper_ask_store.ml).
- Auth_strict_mode 는 2026-04 'Phase B 에서 거절 예정' 소크 카운터인데 09-30 로그에 would_reject 0건이다. 계획 문구를 지우거나 strict 로 올린다(mcp_server_eio_caller_identity.ml:167-180).
- audit-approvals: always_allow 라 도구 호출마다 gate_allowed 행 하나. 09-30 20,670행 9.7MB(행 약 467바이트, 대부분 null), 09-29 33,517행, 디렉터리 전체 178MB, 회전 없음.
- credential 정리: 만료 9개(admin 6, worker 2, player 1)와 raw 토큰 파일이 남아 있다. 만료 없는 Worker 65개. 정리 PR #40174·#40182 가 열려 있다.
- Goal verdict 공지가 28명 대화에 285행 369KB(행당 약 1.3KB)로 쌓였다. 검증은 13번이라 비용은 작다.
- 재확정 때 event actor 가 첫 번째 확정자로 남는다(record_human_confirmation 이 현재 값을 돌려줌). 실제로 마무리한 두 번째 사람은 기록되지 않는다.

확인 못 한 것

- 09-30 08:41, 10:20, 11:56, 12:44, 13:56 KST 검증기 scan 을 누가 깨웠는지(INFO 로그가 남아 있지 않다).
- Gate Manual·Auto Judge 의 실제 동작. 라이브가 always_allow 라 keeper_gate_replay.ml 과 Hitl_summary_worker 는 코드도 끝까지 읽지 않았다.
- 웹 대시보드 Gate·승인 화면의 그림. #39991 decode 수정만 확인했다.
- 이번 주 바뀐 route 46개 전부를 한 줄씩 읽지는 않았다. 등록 344개는 스크립트로 래퍼를 뽑았고 쓰기·승인·Goal·Play·lane-addons 는 읽었다.
- OAuth route(server_oauth_http)와 /mcp 프로필 인증의 세부.
- Candle 을 켠 경우의 확정 후속과 Snapshot 실패 경로(라이브 candle.toml 없음).
- 긴 DOS load 중 credential 잠금 재시도(약 2초)가 끝나 인증 조회가 실패하는 경우.
- goal_events emit 실패 경로를 실제로 만들어 보지는 않았다(코드만 읽음).

## D12 perf 캐시 계층의 정확성 (09-27~30 perf 변경 전수)

작은 것들(P3)

- D12-02 같은 일을 하는 파일 버전 캐시가 5개 사본이고, 키가 서로 다르며 고친 곳이 다른 사본에 안 퍼집니다
- D12-03 Workspace_backlog 캐시가 전역 뮤텍스를 잡은 채 blocking Unix.stat 을 합니다
- D12-04 효과가 없다고 스스로 적은 perf PR 3개가 압축 파일 60 MB 를 git 에 넣었습니다
- git blame, log, diff 실패가 캐시에 성공으로 남습니다. git_run_lines 가 실패를 빈 목록으로 삼키고(카운터만 올림) diff 는 Null 을 15초 캐시해 400 을 냅니다. Dashboard_cache 에 저장 금지로 돌려줄 Result 가 없어 tool-quality 만 예외를 던지는 우회를 씁니다. 부팅 뒤 실패 WARN 은 0건입니다.
- ETag 규칙이 두 곳입니다. etag_hex_chars = 12 와 weak etag 만들기가 dashboard_cache.ml:46-52 와 http_server_eio.ml:230-234 에 따로 있는데 http_server_eio.ml 은 한 규칙만 두겠다고 적고 있습니다. 지금은 같은 값입니다.
- #40060 뒤에도 kept bytes 를 요청마다 CPU 풀에서 다시 압축합니다(Identity_only 로만 준비함). 288 KB Board 페이지도 마찬가지입니다. (server_cached_read_http.ml:16-22)
- load_auth_config 는 인증된 요청마다 stat 뒤에 파일 전체를 읽고 파싱합니다. stat 은 존재 확인뿐이라 #39935 가 요청당 1.2 µs 를 11 µs 로 늘렸습니다. 직접 읽고 ENOENT 를 기본값으로 처리하면 stat 이 필요 없습니다. (auth_credential_base.ml:174-200)
- Scheduler_lag.summarize 의 직접 만든 quickselect 는 /health 요청당 약 30 µs 를 줄이려고 60줄이 넘습니다. 오버 엔지니어링 후보입니다. (scheduler_lag.ml:62-125)
- #40052 와 #40060 의 테스트는 route 를 같은 URL 로만 읽습니다. 키에서 sort, exclude, author, limit, offset, goal_id, window_hours, path 를 빼도 통과합니다. (test_board_rest_routes.ml, test_dashboard_http_core.ml)
- timeout 봉투를 504 로 바꾸는 판정이 세 곳입니다. Server_cached_read_http.respond, Board 목록 H1 핸들러(routes_activity.ml:936-947), h2_respond_cached_payload.
- tool_quality 키는 window_hours 를 %.2f 로 찍지만 계산은 원래 float 을 써서 1.234 와 1.2349 가 한 항목을 씁니다. (routes_dashboard.ml:3329-3332)
- cached_payload 는 json 트리와 raw_json 을 둘 다 들고 있습니다. 응답기는 json 을 최상위 error 필드 확인에만 씁니다. 항목 수 상한 256 은 바이트 상한이 아닙니다.
- kept bytes 이전이 일부만 끝났습니다. Dashboard_cache 호출처는 payload 22, JSON 18, timeout JSON 13개입니다.

확인 못 한 것

- Dashboard_cache 라이브 통계(hit 비율, 항목 수, 메모리): 인증된 HTTP 호출이 필요해 하지 않았습니다.
- 각 PR 의 속도 주장(ms, µs): 빌드와 측정을 하지 않아 다시 재지 않았습니다.
- kept bytes 응답이 요청마다 CPU 풀에서 압축하는 비용과, blob 해시가 풀을 점유할 때의 대기: 미측정.
- TU-F24, TU-F26, TU-F28, TU-F55 의 현재 상태: 별도 에이전트 몫입니다.
- 다른 worktree 에 실제로 체크아웃된 tar.gz 용량: 다른 worktree 를 열지 않았습니다.
- activity_defaults 가 14:45:46Z 에 1.2 GB 를 할당한 원인.
- Eio.Lazy 의 도메인 간 강제 실행 의미: 작성자 설명을 믿고 문서를 다시 보지 않았습니다.
- 범위 밖에서 본 것: Keeper e-masc-the-leader 의 mention 수신 보류 ERROR 250건(부팅 뒤)은 조사하지 않았습니다.

## L2 Drain Queue · 서버 로그 소음 · 부팅 신호 · Keeper 가동 (라이브)

작은 것들(P3)

- L2-06 읽고 쓰는 코드가 없는 파일이 약 1.2GB 남아 있어요
- L2-07 재시작마다 서버 시작이 두 번 불려 부팅 8번의 시작 로그가 덮이고 있어요
- keeper_heartbeat_stimulus_intake.ml:24-45 의 forced_transient_board_reads_for_test 가 운영 경로(pending_board_event_of_stimulus)에서 자극마다 읽히는 테스트 뒷문(체크리스트 6번).
- keeper_autonomous_turn_source.ml:466-485 load_recent 가 읽을 때마다 낡은 turn record 행마다 WARN 을 냄. 09-27 127,704줄. 지금은 242줄/일이지만 창에 남는 한 계속 나옴(하드 컷 잔재).
- 부팅 때 'recovered shutdown operation' 이 완료된 것을 매번 다시 처리(28→40건). 복구가 끝난 기록이 남아 늘어남.
- sandbox_image_lock_marker_missing 이 부팅마다 10~18건, 09-29~30 703건. 읽는 곳이 마커를 필요로 하는지 확인 필요.
- 'dp<N>/_build is a real directory ...' WARN 이 부팅마다 7건(일주일 539건).
- schedules/signals 일별 파일이 08-31 부터 30개(22MB)로 삭제 없음(RT-S8 그대로).
- reaction-ledger v7 일별 파일이 09-02 부터 삭제 없이 253MB(RT-S3 관련).
- 'Claude Code result ... reported usage with no measured model response' WARN 5,198건이 quota_blocked 와 같은 호출에서 이중으로 나옴(소음).
- Keeper 설정 sandbox_image="ocaml" 승격 상태를 부팅 전에 확인하는 곳이 없음(L2-05 관련).
- autonomy_stats.jsonl 은 코드가 없는 고아 파일(L2-06에 포함).

확인 못 한 것

- masc MCP 연결 실패(ECONNREFUSED)로 keeper status API 는 못 씀. Keeper 상태는 파일과 로그로만 봄.
- 자극당 turn 비용의 합계: usage_scope=conversation_cumulative 행이 다수(39,640 of 약 63,000)라 합칠 수 없어 turn 중앙값만 냄.
- 리더 큐에 도착 5.4~5.9시간 전인 board_attention 25행이 최근 revision 으로 들어온 이유(후보 판정 지연인지 재투영인지) 못 밝힘.
- L2-07 의 시작 스크립트 위치와 숨은 8번 부팅의 종료 사유 못 찾음.
- L2-01 은 코드와 실데이터(pr-updater 줄 3046/3238)로 경로를 끝까지 따랐지만 빌드·테스트로 재현하지 않음. 다른 19명의 boundary 파일은 pr-updater 만큼 열어 보지 않음.
- L2-02 의 다른 채팅 전달(스케줄 reply_to_origin, 승인 알림)이 실제 얼마나 막혔는지 코드로 끝까지 안 따라감(로그의 request 실패 3건만).
- v5 파일을 repo 밖 스크립트가 읽는지 못 봄.
- schedules.json 의 종료된 일정 1,627건이 보관 기준(마지막 쓰기 7일)보다 오래 남았는지(due 가 21일 전인 것 있음) 판정 못 함. schedule notes 4,145건 정리 여부도 못 봄.
- Board attention Jev 판정의 84% not_relevant 가 낭비인지는 판단 문제라 수치로 자르는 제안을 하지 않음. 비용(glm 요금 체계)은 못 봄.

## D9 Portrait · Item Slot(착용) · 초상화 표시

작은 것들(P3)

- D9-01 이름으로 외형을 계산하는 곳이 아직 셋이다
- D9-02 목록 길이로 index 를 골라서 항목이 늘면 이름의 절반쯤 기본 모습이 바뀐다
- D9-05 설정 패널의 아바타는 시길이고 '초상화는 기획 단계'라고 적는다
- D9-06 MCP 도구와 HTTP 경로가 같은 그림을 다른 규칙으로 그린다
- evidence/39827/ 에 PNG 4개와 capture.py 가 저장소에 들어갔다(#39886). 작은 파일이지만 바이너리 커밋 금지 규칙과 어긋난다.
- keeper_portrait_read 응답이 매 호출 catalog 18개와 equipment 2개를 담는다(약 1.2KB). 카탈로그를 보려면 PNG 를 그려 저장해야 한다.
- preview_item 은 빈 칸으로 되돌려 보기나 여러 항목 동시 미리보기를 못 한다. 틀이 장비에 따라 달라서 메달 미리보기는 몸이 작아진다.
- portrait_read_output_schema 의 id 와 slot 이 enum 없는 string 이다. Item.all 에서 enum 을 만들 수 있다.
- Keeper_portrait_look.body(검사하는 생성자)와 invalid_body 9개 variant 는 테스트만 부른다. starting_equipment 와 flame_weight 도 테스트용으로만 공개돼 있다.
- test_keeper_portrait.ml 의 live_keepers 25명 목록은 손으로 적은 낡은 명단이다(라이브 26명과 다름).
- DM-PT-7 그대로: keeper_present 가 keeper_meta_path 대신 경로를 직접 조립한다(server_dashboard_http_keeper_portrait.ml:161-167).
- keeper-portrait.ts 가 useEffect 로 fetch 한다. 프로젝트 규칙은 useQuery 를 권한다(외부 자원 동기화라 예외로 볼 수도 있다).
- masc_tui_keeper_portrait.ml 의 band 상수 주석('24px 부터 안경이 보인다')은 축약 렌더러 이전 측정이다.
- docs 의 '장착 권한 변경 없이 임시 미리보기' 표현이 어렵다. '착용 상태를 바꾸지 않고 미리 그려 본다'가 쉽다. 장비·아이템·액세서리·장신구가 한 개념에 네 이름으로 쓰인다.

확인 못 한 것

- HTTP 를 실제로 호출하거나 PNG 를 눈으로 보지 않았다(호출 금지 규칙).
- keeper_portrait_draw.ml 1345줄 안쪽(거리장, 채색, 겹침 순서)은 #39961·#39886 diff 만 읽었다. 경계 테스트 extreme_cases 는 head 를 Bow 로 고정해서 Crown·Beanie 의 테두리 검사는 확인 못 했다.
- 열린 스택(#40008~#40288)은 #40010 의 핵심 파일 패치만 읽었다. 나머지 PR 의 결함은 보지 않았다.
- 도구 인자가 null 이거나 '160' 문자열일 때의 상위 변환은 확인 못 했다. request_arg 는 `Null 과 문자열을 오류로 돌려준다.
- won-chik.vision 834파일, msx-retro-mania.vision 7303파일이 초상화에서 나왔는지 확인 못 했다.
- 브라우저로 대시보드 설정 패널과 머리글을 열어 보지 않았다.
- #39987 병합 뒤 preview_item 을 쓴 라이브 호출이 0건이라 그 경로의 라이브 동작은 확인 못 했다.

## D10 Play Invite · DOS 기계 조종권(Seat) · MSX · 외부 에이전트 안내

작은 것들(P3)

- 안내 route 의 거절이 옛 모양: play_guide.ml:13 error_json 이 {error: 코드, message}. 열린 #40262 가 Server_refusal 로 바꾸고 H2 도 함께 고침.
- 안내문(config/prompts/play.agent_guide.md)은 '400 이면 아무것도 실행되지 않았다'고 적지만 dos 라우트는 Guest_fault·Unreadable 도 400 으로 답하고 그때 기계는 이미 움직였다(tool_misc_dos_lane.ml of_lane). 손님 에이전트가 같은 키를 다시 보낼 수 있다.
- Tool_misc.dispatch 를 부르는 곳이 5개이고 gate 는 호출자가 각자 건다. keeper_tag_dispatch.ml:132 는 gate 가 없다. DOS 도구는 descriptor 가 있어 지금 도달하지 않는다. 새 문이 생기면 빠질 수 있다.
- 'Seat'라는 말이 네 곳에서 다른 뜻이다: /mcp/play 프로필 Seat, GET /api/v1/play/seat, Play_seat 모듈, Fusion Seat(judge/panel). 용어집에 조종권(Controller)은 있으나 앉은 이름(seat)의 뜻은 따로 없다.
- seat 응답의 participants 가 Admin credential 이름(admin, codex-runtime-operator, masc-tui 등)과 Keeper 27명 이름을 초대 손님에게 그대로 보여 준다. pass 대상에 필요한 이름은 Keeper·초대뿐이다.
- GET /api/v1/lane-addons/live 는 CanPlayMachine 만 있으면 msx_capture 도 준다(RFC 는 play-link 를 DOS 만 대상으로 함). GET /api/v1/msx/carts 는 인증 없이 cart 파일 이름과 적재 상태를 준다.
- 만료된 credential 9개(admin 6, worker 2, player 1)가 자동으로 안 지워진다. seat·초대 목록이 매 호출 agents/ 176개 파일을 읽는다(Eio 도메인에서 동기 읽기).
- before_move 는 credential 파일 락을 쥔 채 DOS machine mutex 를 기다린다(press 한 번 약 170ms, load 는 더 김). 그동안 색인 캐시가 비어 있는 토큰 조회는 같은 락에서 기다린다. 미측정.
- DOS autosave 가 모든 press·type·step 뒤 2.8MB 를 쓰고 ledger 전체를 다시 직렬화한다(dos_lane.ml:611). MSX 도구는 도메인 0 에서 최대 300프레임을 돌린다(DOS 는 off_domain). 둘 다 미측정.
- samguk3 패드 배치가 OCaml 소스 문자열에 있다(play_pad.ml:150-). 안내문의 'claude mcp add --header' 는 토큰을 ~/.claude.json 에 남긴다.

확인 못 한 것

- ocaml-dos 코어 소스: 스냅샷 format 2→3 은 메모리와 체크포인트 header 의 코어 digest 로만 확인했다(D10-03 Medium).
- /mcp/play 의 H1·H2 메서드 제한(listen 가로채기, GET 405/404)은 메모리 기록만 읽고 코드를 다시 따라가지 않았다. H2 gateway 에 /play·/api/v1/dos·play·msx·live 가 없는 빈틈은 그대로로 보인다(#40262 는 안내 route 하나만).
- TUI 카드·QR(bin/masc_tui_play_card.ml)의 링크 보관과 DM-PL-09 상태, TU-F12(MSX 키 거절 무표시, masc_tui.ml:19001 의 Ok _ | Error _ -> () 가 그대로로 보임)의 판정은 상태 확인 담당에게 맡김.
- play 페이지 JS 를 브라우저에서 실행하지 않았다(코드만 읽음). test_play_page_client.cjs 가 CI 에서 도는지 확인 못 함.
- Play_seat.participants·credential 목록 읽기(176파일)의 실제 지연, credential 락 대기 시간, DOS autosave 호출당 시간, MSX 300프레임이 도메인 0 을 막는 시간은 측정하지 않았다.
- raw 초대를 실제 발급·회수하는 동작 테스트는 하지 않았다(읽기 전용 규칙). D10-01 은 라이브 GET /play/agent.md 와 코드 경로로만 증명했다.
- 외부 Cloudflare 터널(masc.crying.pictures)로 실제 접속한 결과는 확인하지 않았다.

## L3 디스크·보존(retention): .masc 111GB, worktree 991개, 여유 98GiB

작은 것들(P3)

- L3-04 제거된 keeper 의 작업 볼륨·흔적이 남는다 (lane-smith 12GB)
- L3-07 죽은 파일 1.2GB: exact-lane-runs-v5.jsonl 과 .atomic_*.tmp 5개
- L3-10 .git 안 run-local 실행 파일 4.7GB 와 worktree 관리 폴더 1.86GB
- L3-11 모든 worktree 가 docs/evidence 를 통째로 받는다: 증거 원본 tar.gz 2개 56.5MB 는 읽는 곳도 없다
- logs/ 에 .log 파일 2,331개(masc-tui-<pid>.log 10MB)와 30일 넘은 .log 769개 144MB 가 있습니다. 30일 정리는 .jsonl 만 대상이라 이들은 안 지워집니다.
- trajectories/_build 에 dune 임시 파일이 09-26 부터 남아 있습니다(작음).
- _trash/accepted-checkpoints-unreferenced-20260923 2.6GB 는 일주일 전 운영자가 옮긴 것입니다. 서버 로그 확인 뒤 지우는 절차가 문서에 없습니다.
- playground/docker/polisher 2.3GB, playground/rondo/repos 1.1GB 는 7일 넘게 변경이 없습니다.
- lane-addons-archive 는 파일 126,248개(184MB, 블록 514MB)인 운영자 보관물로 코드 참조가 없습니다.
- keepers/lane-smith.*.lock, antigravity-*.prepare.lock 같은 0바이트 lock 파일이 제거된 keeper 뒤에도 남습니다.
- /private/tmp 에 masc-* 항목 4,503개(worktree 외 대부분 작은 json·diff)가 있고 세션 scratchpad 하나가 22.8GB 입니다.
- worktree 이름이 다른 세션 것과 겹치지 않게 만들었는지는 확인 못 했지만 .worktrees 에 .git 없는 폴더 5개(합 7MB)가 있습니다.
- docs/evidence/task-611 tar.gz 3.1MB, 2026-09-10 wav 2.1MB 등 원본 파일이 그 외에도 있습니다.

확인 못 한 것

- keeper 작업 볼륨 332GB 의 안쪽(게스트 worktree 수, _build 크기, trim 효과). 메모리 기록으로만 알고 있습니다.
- ~/.codex(179GB), ~/.ollama, ~/.colima, ~/Library 같은 .masc 밖의 큰 디렉터리.
- msx 저장본이 keeper 메모리에서 slot 이름으로 참조되는지.
- tool_blobs 중 지금 참조 중인 blob 의 비율(GC 를 안 돌려서 측정 못 함).
- JSONL append 가 ENOSPC 에서 줄 중간만 쓰고 끝나는 경우의 재생 처리.
- playground(3.4GB), .masc/repos(2.2GB) 의 정리 규칙과 안의 미커밋 작업.
- worktree C 분류 318개(remote 에 없는 커밋)의 실제 미push 커밋 내용.
- 디스크 줄어드는 속도는 측정 창이 53분이라 하루 평균과 섞였는지.
- clusters 하위 workspace 의 크기.
- 09-29 이후 커밋 115개 중 디스크와 직접 관련된 것은 찾지 못했고 개별 diff 는 읽지 않았습니다(담당 범위에 지정 없음).

## D11 Multi Lane · Lane Add-on · Fusion

작은 것들(P3)

- D11-03 Lanes 개요는 Add-on 을 읽지 않고, 라이브 Add-on 은 선언 2개에 active 0 인데 로그에 한 줄도 없다
- D11-05 masc_lane_detach 설명은 '워커만 멈춘다' 인데 실제로는 운영자의 선언 TOML 을 지운다
- D11-07 workspace 경계 검사가 package-preview 에만 있고 attach·declaration 은 아무 경로나 받는다
- effect_disposition 이 lane 종류마다 다르다: MSX 한 곳(tool_misc_msx_lane.ml:19-24)과 Browser 18곳만 Proven_pre_effect 를 선언하고 DOS(tool_misc_dos_lane.ml:19-20), lane_error(tool_misc.ml:151-156), fusion_tool 은 기본…
- 재시작 닫힘을 문자열로 가른다: Failed { code : string } 에서 'server_restarted' 글자 비교(exact_lane_run_registry.ml:39,236 ↔ server_standalone_lane_projection.ml:485-488). outcome 에 variant 를 하나 두면 컴파일러가 잡는다.
- 파일 하나가 깨지면 멈춤이 번진다: 못 읽는 binding 하나가 있으면 reconcile 전체가 can_apply=false(lane_addon_runtime.ml:948). cursor 파일이 깨지면 Read·Ack 모두 영구 Error(lane_addon_subscription.ml:65-79). 쓰기는 atomic 이라 드물다.
- masc_lane_updates save 는 caller 를 쓰지 않아 어느 Keeper 든 모든 Keeper 의 구독 설정(lane-subscriptions.toml)을 다시 쓴다(lane_addon_subscription.ml:156-170). Read·Ack 만 caller 를 검사한다.
- Add-on 기록에 보존 한도가 없다: lane-addons 37MB(observations 154 디렉터리, 최대 1,607개), 서버 재시작마다 선언당 인스턴스가 1개씩 늘어 dos-counter 와 dos-output-statistics 가 각 약 70개 detached 로 남았다.
- parse_source 의 모르는 필드 거절은 lane_output 에만 있다(lane_addon_sources.ml:80-100). snapshot_file·msx_capture·dos_capture 의 오타 필드는 조용히 무시된다.
- 미완료 실행은 재시작에서만 닫힌다: 08:00 에 board_attention 1건이 02:31 등록 후 5.5시간 Running 이었고 projection 은 그 때문에 degraded 보다 먼저 'running' 을 냈다(server_standalone_lane_projection.ml:723-731). 09:06 재시작으로 정리돼 지금은 0. 감시 코드는 없다.
- Fusion 도구 흔적 상한: max_tool_trace_events=256(fusion_types.ml:336), 입력·출력 미리보기 1,024·2,048바이트(fusion_agent_core.ml:55-57). 넘친 것은 dropped_events 로 센다. 헌법의 '수치 cap 없음'은 패널 fan-out 얘기라 위반은 아니나 숫자의 근거 주석이 없다.
- 같은 말이 두 곳: 상태 낱말을 서버가 글자로 쓰고(server_standalone_lane_projection.ml:720-733) TUI 가 variant 로 되읽는다(tui_decode.ml:6747-6753).
- 낡은 글: 글로서리 Lane 항목은 exact lane 을 다섯, 실행 기록을 넷이라 적지만(00-glossary.md:897-905) 코드는 7개와 5개다. Lane_manifest.purpose 의 Browser_stagehand 설명에 'not retained yet'(lane_manifest.ml:~30)이 남아 있다.

확인 못 한 것

- 라이브 서버(ebea1d97a7)에 직접 읽기 호출: 이전 시도가 토큰 불일치(AuthError)로 실패해 파일·로그·docker 읽기로만 확인했다.
- 이미지는 있는데 worker start 가 반복 실패할 때 인스턴스가 박자마다 새로 생기는지(reconcile 이 retire 후 attach 를 되풀이하는 모양이나 끝까지 따라가지 않음).
- MSX·DOS·Browser 도구의 입력 검증 세부와 effect_disposition 소비 전체(D10·D1 범위). 여기서는 Failure_returns_to_model 경로만 확인했다.
- #40107 이 지운 Timeline·Connections 화면(bin/masc_tui_lane_addons.ml 332줄 삭제)이 기능 후퇴인지는 diff 일부만 읽어 판정하지 못했다.
- TU-F36·TU-F46 의 현재 상태(별도 에이전트 몫). TU-F35 만 코드를 다시 읽었다.
- addons/ 파이썬 패키지(dos-world·web-project·frame-progress·value-difference)의 내부와 열린 스택 #40184~#40396(Fusion_run 소스, Broadcast 장부)은 main 이 아니라 읽지 않았다.
- Fusion 판정 반복 호출 낭비(#40273)는 main 에 그 합성 경로가 없어 재현하지 못했다.
- Browser Lane 모듈(RT-R4 Stagehand 429 기억)의 현재 상태는 별도 에이전트 몫이라 보지 않았다.

## D13a TUI·대시보드 데이터 배선 (서버 route ↔ decoder ↔ 화면)

작은 것들(P3)

- D13a-04 ask 로그를 못 읽으면 서버가 질문 0개로 답하고, Home 이 '결정 기다리는 것 없음'이라고 그린다
- 지워진 goal_notification 이 dashboard TS 3곳(keeper-delivery-provenance.ts, schemas/keeper-chat-delivery-provenance.ts, .test.ts)에 남았다. OCaml 은 #39975(09-30 19:51)가 지웠고 TS 는 #39996(00:37)이 넣었다.
- keeper-costs 서버 주석(dashboard_http_keeper_feeds.ml:79-84)은 'TUI 가 window 를 안 보낸다'인데 TUI 는 window=1440 을 보낸다(masc_tui_http.ml:1708).
- provider-usage-history 의 일수 집합 [1;7;14] 이 tui_decode.ml:4561 과 Server_provider_usage_history.window 두 곳에 있다.
- Usage 화면은 서버 캐시가 처음 채워지는 동안 state:loading 을 'unavailable: history is loading' 로 그린다(masc_tui_loader.ml:1273, masc_tui_render.ml:13349).
- runtime/resolved 의 scope_id 는 scope 문자열(환경변수 이름·홈 경로)의 MD5 이고 공개 읽기에 실린다. 같은 파일 주석은 '응답마다 바뀌는 키만 내보낸다'고 적었다(server_dashboard_runtime_resolved_json.ml:297-340). D10 에서 볼 것.
- #40145 의 merge_paged_history 는 서버에서 사라진 행(purge 뒤)을 계속 들고 있다(masc_tui_types.ml:8998-9013). 드물다.
- TU-F38 그대로: 브리핑 기본값 'ok'(dashboard_briefing.ml:210)와 미초기화 digest 'ok'(operator_digest.ml:296)가 Home 'Health: ok' 로 나온다.
- Home 의 approvals 행이 안 읽음·실패·낡음·사용불가를 'not fully read' 한 문구로 합친다. 원인은 Approvals 화면에서만 보인다(masc_tui_types.ml:11318-11330).
- /health 는 ETag 를 주지만 같은 태그에 304 를 안 준다(라이브 curl).

확인 못 한 것

- TU-F01~F60 의 상태 확인은 S4·S5 몫이라 하지 않았다.
- operator 요약, keepers/asks, keepers/tool-approvals, gate/keepers 의 라이브 응답 크기는 인증이 필요해서 못 쟀다.
- D13a-02 의 원인(터미널 write 가 막히는지, 동기 파일 읽기인지)은 증명하지 못했다. MASC_TUI_FRAME_TIMING 을 켜지 않았다.
- D13a-03 의 runtime.toml 쓰기 횟수와 걸리는 시간은 재지 못했다. 웹 설정 저장이 실제로 거절된 기록도 찾지 못했다.
- D13a-07 의 fd 를 닫은 곳은 찾지 못했다. 터미널 종료와 겹치는지 확인 못 했다.
- #40031(Skill 사용량 카드), #40080(텍스트 캐시), #40088, #40094, #40110 같은 그리기 정확성은 읽지 않았다(D13b 몫).
- Home 의 PTY 색·크기 화면과 401/403 일 때 실제 화면은 보지 않았다.
- 웹 TS 스키마 전수 대조는 하지 않았다. 09-29 이후 바뀐 api 파일만 봤다.
- masc_keeper_list 의 total·truncated 가 없을 때 TUI 가 '안 잘림'으로 읽는 기본값(tui_decode.ml:6561-6568)은 서버가 항상 보내는지 확인하지 못했다.
- masc_tui.ml 26,710줄 중 갱신·Home·채팅 읽기 경로만 읽었다.

## D13b TUI 키·푸터·정보 선명성 (Home 포함)

작은 것들(P3)

- D13b-03 Home 승인 줄이 '아직 안 읽음'·'읽기 실패'·'옛 값'·'사용 불가'를 같은 문구로 그립니다
- D13b-05 Approvals 목록 푸터에 Enter·R·Y 가 없고, 상세 푸터에는 [ / ] 가 없습니다
- D13b-07 채팅을 열 때마다 runtime.toml 을 통째로 commit 합니다 (#40137 이후)
- D13b-08 /login 모델 선택의 `a:전체` 는 context 를 모르는 모델을 안내 없이 건너뜁니다
- D13b-10 한국어와 영어가 한 화면에 섞인 곳이 /login 밖으로 넓어졌습니다
- masc_tui.ml:20570 의 `| "esc" -> state.about_open <- false` 는 죽은 분기입니다. 같은 match 앞(20155)에서 `Some "esc" when state.about_open` 가 먼저 받습니다.
- docs/design/tui/HOME-JOURNEY-ACCEPTANCE.md 가 낡았습니다. 'home_last_chat is session-only'(#40137 이 영속화), 'Renderer currently ignores its body budget'(#40130 이 고침), '160열에 Recent 창'(코드가 닫음)이 아직 '남은 일' 로 적혀 있습니다.
- Home 의 `p` 나 'Approvals and questions' 줄 Enter 로 Approvals 에 가면 Esc 는 Home 이 아니라 Work 로 갑니다(masc_tui.ml:24021 `goto_surface Planning`). 요청 행 Enter 로 간 경우만 Home 으로 돌아옵니다.
- Usage 에서 `w` 를 누르면 `provider_history` 를 Unread 로 만들고 읽기를 시작하지 않아, 다음 새로고침까지 'Quota scope trend · not observed' 가 보입니다(masc_tui.ml:22617-22625).
- Usage 의 'Keeper usage (24h)' 글자는 안 읽음·오류·수집 중 상태에 박혀 있고, 읽은 뒤에는 서버가 준 window_minutes 로 'last %dm' 을 그립니다(render.ml:13405-13423).
- TU-F03 이 그대로입니다. 채팅 푸터 'Ctrl-T:queue' (render_chat.ml:3472,3612; keys.ml:505)인데 Ctrl-T 는 마우스 추적 끄기입니다(masc_tui.ml:16576, keys.ml:266).
- Lane Add-ons 상세의 `5` 키는 `4`(Rows)와 같은 동작이고 푸터·도움말에 없습니다(masc_tui.ml:19812).
- Home 문구 세 곳에 공백 둘이 있습니다: 'Choose a Keeper · start a conversation', 'New work · choose a Keeper', 'Create a Keeper · choose …'(masc_tui_types.ml:11441-11457).
- HOME-JOURNEY-ACCEPTANCE 의 fixture 이름 '160×48 Recent pane' 같은 evidence README 줄도 같이 낡았습니다(docs/evidence/tui-home-journey-20260930/README.md).
- Approvals 상세 푸터에 Esc 는 있지만, Home 에서 열었을 때 '어디로 돌아가는지'(Home)는 이름이 없습니다.

확인 못 한 것

- 60x20 같은 더 좁은 폭의 Home·Usage·Work 화면: 60열 fixture 가 없어 코드로만 보았습니다. 이번 감사에서 PTY 를 직접 돌리지 않았습니다.
- Keepers(TU-F44·F49·F50), Board read(F42·F43), Runtime, Code 의 푸터 대 dispatch 전수 대조: 09-29 발견 상태 확인은 다른 에이전트 몫이고, 이번에는 새 변경 위주로만 보았습니다. 09-30 23:15 통합 PR(#40277~#40328)이 새로 만든 푸터도 일부만 봤습니다.
- D13b-09 의 원인 fd 와 종료 때 서버 switch 정리 여부: 재현 없이는 못 가릴 것 같습니다. 크래시와 터미널 창 닫기를 구분하지 못했습니다.
- D13b-02·D13b-04 는 코드 경로 추적입니다. PTY 로 재현하지 않았습니다.
- Usage 의 Keeper usage 가 라이브에서 partial 행을 실제로 내는지, D13b-01 의 부분 실패가 라이브에서 나는지는 라이브 응답이 없어 확인하지 못했습니다.
- main loop 공백(p50 1.7초, p90 4.8초, 최대 23초; masc-tui-80035.log 764회)은 perf 캠페인이 이미 추적하고 있어 원인 조사는 하지 않았습니다.
- help overlay 의 'you are here' 매칭과 스크롤은 안 봤습니다.

## D14 Terminal-Bench(4.0 및 최신) 통과 준비 상태

작은 것들(P3)

- D14-03 렌더한 벤치 설정이 서버 로더를 통과하는지 실행 전에 확인하는 고리가 없다
- D14-04 어댑터는 ATIF 를 만들지 않는데 리더보드 제출에 필요한지는 공식 근거가 없다
- AGENT_CORE_MCP_SERVERS_CONFIG 는 읽는 코드가 lib/packages/bin 어디에도 없다.
- docs/BENCHMARK-RUNBOOK.md 의 E0 점수판 절은 goal-campaign-ratchet-20260902 가 점수 파일을 읽는다고 적는다. 라이브 goals.json(목표 23개)에 그 목표가 없고, 출력 파일 docs/evidence/keeper-e0-campaign-scoreboard.json 도 저장소에 없다. 마지막 증거는 r6(08-18)이다.
- masc-workflow.md 가 벤치 정본 경로로 지목하는 docs/BENCHMARK-RUNBOOK.md 에는 Terminal-Bench 절이 없다. 증거 경계 한 줄뿐이고 실제 안내는 benchmarks/terminal_bench/README.md 에만 있다.
- 이슈 #36908 은 OPEN 이고 제목이 mcp_servers 와 skills_dir 둘을 말한다. skills_dir 는 #37286 으로 닫혔다. 남은 것은 medical-claims-processing 의 mcp_servers 하나(66개 중 1개, README.md 에도 적혀 있음). 제목과 본문을 현재 사실로 고친다.
- arm c~h 는 seed skill 21개(게임용 dos-play, msx-play, sangokushi-2/3 포함, composition 8개)를 전부 켠다. arm b 와 c 의 차이에 TB 와 무관한 게임 skill 이 섞인다. 스킬 기여 판정을 읽을 때 같이 본다.
- 비용 기록(메모리, 2026-09-12): 6 arm x 24 task x 3회(432 trial)에 $7,987, arm a 는 break-filter-js-from-html 3회에 $3,633. trial 평균 $18.5 로 단순 환산하면 기본값 a,b,c,e,f,h x 53 task x k=5(1,590 trial)는 약 $29k 다.
- arm a 기준선이 09-11 매트릭스에서는 Terminus-2 였고 지금 run_matrix.sh 는 claude-code(anthropic)다. 09-11 숫자(49/72)는 지금 arm a 와 비교할 수 없다.
- trial 마다 masc 바이너리(약 116MB)와 shim 을 컨테이너로 올린다. 1,590 trial 이면 업로드만 약 184GB(116,036,504 x 1,590 계산)다.

확인 못 한 것

- 실제 실행: 규칙상 docker·harbor·서버를 돌리지 않았다. 스모크가 통과하는지는 모른다.
- results/jobs(git 밖, bench 체크아웃 안)는 다른 세션이 쓰는 체크아웃이라 열지 않았다. 09-22 이후 trial 이 더 있는지 확인 못 했다.
- v0.48.0 서버가 빈 컨테이너에서 뜨는 데 걸리는 시간. bootstrap.sh 는 MCP 응답을 최대 60번(약 60초) 기다린다. 에뮬레이션 amd64 에서 이 안에 드는지 미측정.
- Modal·Daytona 경로 전체(자격 없음, 실행 이력 없음).
- 66개 task 이미지 전수의 배포판·glibc. README 의 09-17 기록(65/66 확인)에 기댔다.
- Terminal-Bench 4.0 리더보드 제출 규칙(trial 수, ATIF, trajectory 공개). 공식 출처에서 못 찾았다.
- collect_result.sh 가 읽는 .masc/traces/<세션>/trace-*.json 을 쓰는 곳을 끝까지 못 따라갔다. Checkpoint_store 가 <session_id>.json 으로 쓰고 session id 가 trace-<시각>-<번호> 형식이라 맞을 것으로 추정한다(Medium).
- head 설정 파일(도구 TOML 설명, keeper.md)이 v0.48.0 바이너리에서 문제없이 읽히는지. 설명 문구 변경만 봤고 새 도구 이름 참조는 확인 못 함.
- 부팅 때 뜨는 Workspace curator·goal verifier·completion authority 가 빈 벤치 base 에서 모델 호출을 하는지. 코드를 끝까지 읽지 않았다.
- 어댑터 pytest 193개(09-23 통과)를 이번에 다시 돌리지 않았다.

## D15 Keeper 프롬프트·도구 설명의 정확성과 낭비

작은 것들(P3)

- D15-04 keeper_workspace_memory_read 인자 설명은 'bounded' 인데 summary 에 상한이 없다
- lib/keeper/keeper_prompt.ml:5-11 은 `open Keeper_meta_contract` 와 `open Keeper_types_profile` 을 세 번씩 반복한다. :14-19 주석은 지운 치환 단계('The former … pass is gone')를 설명한다. 주석은 지운다.
- masc_plan_set_task 의 [help] 는 지운 plan-of-record 를 설명한다('Set or update the plan-of-record', 예시 plan='…', 'Plan body should be short prose').
- keeper_task_create 의 contract.inspect_gate_evidence 는 만들어 저장하지만 verifier 가 읽지 않고 대시보드 work.ts:402 만 보여 준다. verify_gate_evidence 는 verification_protocol.ml:99 가 읽는다.
- packages/agent_core 의 handoff.* 와 agent_tool.* 문구(config/prompts/agent_core.md:24-30)는 lib, bin 에서 handoff 도구를 만드는 호출이 없다(Medium).
- masc_gc 는 CanAdmin 도구인데 Keeper 도구 목록에 있다. 설명은 '나이 기준 정리'라고만 쓰지만 workspace_gc.ml:175-205 는 days 보다 오래된 메시지를 Sys.remove 로 지우고, 열린 Task id 가 본문에 문자열로 들어 있으면 남긴다. 인자 설명은 'Operator-selected' 다.
- keeper.md 의 `gate_replay.*` 조각과 keeper.gate_replay.md 는 같은 Gate 재실행 문구를 두 파일에 나눠 둔다. 키가 겹치지는 않는다.
- masc_schedule_update 설명의 'next version requires it' 는 어느 버전인지 적혀 있지 않다(tool_schedule.ml:762).
- config/runtime.toml:15-17 주석은 resource-read-max-bytes 를 'WARN 후 무시, 다음 버전은 거절'이라 쓰지만 #39498 이 deploy preflight 에서 이미 거절한다(MM-S5 와 같은 잔재, 메모리 a-retired-runtime-toml-key…).
- Keeper 목록 도구가 쓰는 `masc_plan_clear_task` 설명은 'Use masc_transition' 이라 쓰는데 Keeper 는 keeper_task_release/cancel/done 을 쓴다(D15-03 c 와 같은 줄기).
- worldview override 의 Vote Up·Karma 문단과 keeper override 의 `<board>` 블록이 같은 말을 두 번 한다(약 330 B).

확인 못 한 것

- 공식 CLI(Codex, Claude Code, Antigravity)가 wire 로 실제 보내는 도구 크기. wire-capture 는 MASC 가 만든 projection 이다.
- `keeper` override 에서 빠진 두 문장을 운영자가 일부러 뺐는지.
- librarian.md(21 KB), verification.md, goal_verification.md, fusion.judge.md, tool_failure.md 본문 전수 대조. #39755 의 facts_budget 문장만 봤다(MM-M4 의 source 바이트 누락은 그대로).
- 이번 주 바뀌지 않은 도구 설명 약 190개의 구현 대조.
- 프롬프트 편집기(대시보드)에서 keeper.en 이 실제로 보이는지와 운영자가 쓰는지.
- wire-capture 가 10-01 09:00~11:22 KST 구간뿐이라 09-23~30 의 요청 크기 변화는 git 크기로만 봤다.
- masc_gc, masc_board_cleanup, masc_board_delete(CanAdmin)를 Keeper 가 실제로 부르면 허용되는지. Worker 에게 CanAdmin 이 없다(types_auth.ml:343)는 것만 확인했다.
- 대시보드 프롬프트 목록의 override_default_moved 표시가 운영자 화면에 보이는지.
- #40204 `<portrait>` 와 열린 Candle 도구 PR 의 프롬프트 문장(머지 전이라 스냅샷에 없음).

## D16a 죽은 개념 잔재 · 중복 개념 · 어려운 표현 (Glossary 개정 근거)

작은 것들(P3)

- D16a-04 #38801 이 지운 Overview Team 블록의 계산·타입·주석이 남아 있어요
- D16a-05 하루 살고 지운 Goal owner 가 RFC·대시보드 디코더·테스트 fixture 에 남아 있어요
- D16a-07 Agent Core 의 Handoff(하위 에이전트로 넘기기)는 lib·bin 에서 부르는 곳이 없어요
- D16a-08 Glossary 에 '지웠다' 설명과 없는 항목을 가리키는 문장이 있어요
- D16a-11 TUI 첫 화면을 Overview, Dashboard, Home 세 이름으로 불러요
- D16a-14 Glossary 에 정의가 없는 말이 그대로예요 (Access Control, Keeper Owner, Worker 등)
- D16a-15 가장 어려운 표현 30개와 쉬운 대안 (phrasing-vocabulary.md 기준)
- 09-29 발견이 그대로 있음: RT-R7 lib/runtime/runtime.ml:1316,1324 ('used to be read', 'the old comment here'), RT-S5 lib/tool_schedule.ml:749-768, DM-GT-08 lib/types/types_core.ml:418-425, MM-S5…
- test/test_tui_no_value_mark.ml:72 의 'overview_team_lines' 는 없는 함수라 세면 0 이 되어 조용히 통과합니다(D16a-04 안에 포함).
- docs/rfc/RFC-0240:121,466,645 와 RFC-0132:92,95 가 지운 keeper_rollover.ml 을 인용합니다.
- docs/rfc/RFC-0465:37,47,182 가 이미 지운 pr_history 를 설명합니다.
- glossary 296-303 '시작 화면', '상단 바 축약 캔들'은 D9-04 와 같은 지적이고 이번에 코드로 재확인하지 않았습니다.
- scripts/check-runtime-deployment-preflight.sh:542-573 이 지운 intent 필드가 든 행을 만들어 거절 동작을 시험합니다(의도된 거절이지만 DM-GT-08 과 같이 정리 대상).
- glossary 502 의 굵은 글씨 'Keeper Turn Outcome' 은 항목이 없습니다(D16a-08 에 포함).

확인 못 한 것

- DM-BD-10(lane_manifest 의 없어진 proposals 설명, board_types.ml:192, masc_tui_loader.ml:644-660)은 파일을 열어 보지 않았습니다. 상태 판정은 별도 에이전트 몫입니다
- RT-R7, RT-S5, DM-GT-08, MM-S5 는 같은 줄이 그대로 있다는 것만 확인했습니다. MM-C5(keeper_official_client_host.ml:89-97)는 주석 원문만 읽고 실제 resume 동작과 비교하지 않았습니다
- docs/rfc 전체(수백 개)의 죽은 개념 인용은 전수 조사하지 않았습니다. 지운 개념 이름으로 찾은 것만 적었습니다
- dashboard/src 의 죽은 타입·필드는 handoff, goal_owner 주제만 봤습니다. 나머지 전수 조사는 안 했습니다
- receipt·evidence·ledger·record 와 lane·slot·candidate·runtime 을 같은 개념으로 합칠 수 있는지는 코드 타입까지 대조하지 못했습니다. glossary 출현 횟수(영수증 21, 원장 70, 기록 115, 후보 129)만 셌습니다
- keeper owner·owner lane 은 'owner lane' 이 glossary 에 0곳이라 합칠 대상을 못 찾았습니다(fs_compat 의 owner lane 은 다른 뜻)
- 라이브 데이터(.masc)와 대시보드 화면은 열지 않았습니다. D16a-01 의 '핸드오프 임박' 표시 빈도와 D16a-03 의 100% 표시는 화면으로 확인하지 못했습니다
- 프롬프트 파일(config/prompts/*.md)과 스킬 문서의 어려운 표현은 전수로 읽지 않았습니다. glossary, PR 제목, TUI 문구 일부만 봤습니다
- agent_core 패키지를 MASC 밖에서 쓰는 사용자가 있는지 모릅니다(D16a-07)

## D16b 도메인 결합 · 의존 방향 · 큰 파일

작은 것들(P3)

- D16b-02 Keeper 541파일 229,995줄이 라이브러리 하나에 들어 있고 RFC-0215 머리말은 낡았다
- D16b-03 Schedule 소비자가 Keeper 내부 모듈 14개를 136번 부른다 (09-23 #5, 아직 열림)
- D16b-05 Librarian 이 Keeper 모듈을 237번 부르고 meta 전체와 checkpoint store 를 직접 읽는다 (09-23 #2, 아직 열림)
- `.ci/health-baseline.json`, `.ci/ml-line-cap-exceptions.txt`, `scripts/ml_line_cap_audit.sh`, `docs/BASE-POLICY.md:120` 은 쓰는 CI 가 없다(.github 에서 health_snapshot 을 부르지 않고 `make health` 수동 실행만 남았다).
- `masc_tui_types`(22개 라이브러리가 의존)가 `masc.server`(428모듈)에 의존하는 이유는 `Server_routes_http_routes_workspace.max_tree_node_limit`(=2000) 하나뿐이다(types.ml:12501, tui_http.ml:919). 상수를 하위 모듈로 내리면 의존이 없어진다.
- `Workspace_utils*` 4모듈(1,562줄)이 masc_workspace(11.8k줄) 안에 있어서 schedule(40곳), goal(29곳), prompt_registry(3곳), voice_config, candle_store 가 유틸 때문에 masc_workspace 전체를 링크한다.
- `lib/runtime/runtime.ml:528,1307,1320,1347,1363` 의 주석이 위층 모듈(`Keeper_lane_cli_oneshot`, `Keeper_librarian_runtime`)을 이름으로 설명한다. 코드 참조는 아니다.
- `lib/lane_registry/lane_manifest.ml:60-65` 가 `Tool_schemas_misc.misc_operation` 을 match 한다(참조 53곳). lane 등록부가 도구 스키마 variant 를 안다. 지금은 exhaustive match 라 안전하다.
- `lib/typesafeai/typesafeai_board_attention.ml` 이 `Keeper_board_attention_candidate` 를 5곳에서 부른다. typesafeai 묶음이 Keeper 하위 도메인을 안다(같은 라이브러리 안).
- `lib/keeper_contract/keeper_approval_queue_rules_types.mli:201` 이 `Keeper_continuation_channel.t` 를 그대로 든다(09-23 부록 표, 줄 번호만 142→201로 옮겨졌다).
- `lib/keeper_approval/dune` 이 `masc.keeper_runtime`·`masc.keeper_failure_taxonomy` 에 의존한다. audit.ml 에서 쓰는 함수는 하나씩이다(09-23 부록, 아직 열림).
- `lib/verification_collaboration_evidence.ml:30` 이 `Board.workspace_masc_dir` 레코드 필드를 직접 읽는다(09-23 부록, 아직 열림). `lib/keeper/keeper_tool_board_runtime.ml:84` 의 `Board_core_classify` 도 같다.

확인 못 한 것

- 컴파일 시간과 재컴파일 범위(dune 실행 금지라 재지 않았다).
- bin/dune 의 masc_tui 실행 파일이 `masc.dashboard` 를 실제로 쓰는지(모듈 이름으로는 확인하지 못했다).
- Librarian→`Keeper_turn_boundaries` 87곳이 타입 참조뿐인지 함수 호출인지.
- packages/ 아래 라이브러리의 방향.
- Context 도메인(Context→Keeper 66)의 분리 비용. 이음 후보만 적었다.
- 함수 길이는 `let` 시작 줄 기준 근사값이고 AST 도구로 경계를 재지 않았다.
- 도메인 참조 수는 모듈 이름 접두어로 도메인을 나눴다. 접두어가 다른 이름의 모듈(예: `Audit` 는 HITL 이 아니라 Infra 로 분류)은 표에서 빠질 수 있다.
- 09-29 문서가 "96"을 어떻게 셌는지(재현 실패, 계산 방법 모름).

## W1 배선 점검 1: MCP 도구 registry ↔ 핸들러 ↔ 프롬프트 ↔ 클라이언트

작은 것들(P3)

- W1-02 masc_board_cleanup 은 최신 글 500개만 훑는다
- W1-05 keeper.md 가 Keeper 에게 없는 'keeper_status 도구' 를 읽으라고 한다
- lib/tool_surface/tool_help_registry.ml:80-99 의 tool_family(Policy | Observe, 접두어 masc_policy_ / masc_observe_)는 해당 이름의 도구가 registry 에 하나도 없다(legacy purge 로 삭제됨). help_doc_refs 는 없는 도구군에만 문서 링크를 돌려준다.
- masc_schedule_update 의 recurrence_kind 생략 허용(#39451 '다음 버전에 필수')은 경고를 서버 로그에만 남기고 Keeper 에게 돌려주지 않는다. 09-28~30 호출 334건 중 상당수가 여전히 생략한다(정확한 수 미측정). 추적할 후속 PR(#39511)은 열려 있지 않다. 하드컷으로 바꾸거나 응답에 경고를 싣는다.
- keeper_candle_balance/catalog/purchase/equip(live fda7ada7f6)은 defer_loading=false 라 4개 합쳐 약 1.6KB 가 매 요청에 실린다. 호출 0회(방금 배포).
- .masc/tool_calls 에 keeper 'system' 이름으로 pseudo 도구 vision_candidate 1914건이 섞여 있다(keeper_vision_tool.ml:161-242). registry 에 없는 이름이라 도구 호출 통계를 센 사람이 헷갈린다.
- skills/run-and-read/SKILL.md:25,30 과 skills/work-intake/SKILL.md:28 이 lib/ 소스 파일 이름과 함수 이름(spawn_start_output_schema, keeper_tool_task_runtime.ml)을 Keeper 용 본문에 적는다. Keeper 는 그 파일을 못 읽는다. 지워도 뜻이 같다.
- masc_lane_act/attach/detach/evidence/observe/updates/action_status/declaration_save 8개와 masc_msx_eject 는 09-23 이후 호출 0회다. 지연 로딩이라 비용은 없다. 정리 후보로만 적는다.
- keeper_skill_publish 는 25명 모두에게 항상 로드되는데 09-23 이후 8회 호출됐다(wave1 D4-10 과 같은 이야기라 새로 더하지 않음).

확인 못 한 것

- 모든 toml 인자를 핸들러가 읽는지 하나씩 대조하지 않았다. 이번 주 변경 도구와 대표 몇 개(board_post_get, Edit, goal_measure, portrait_read, schedule_update, msx)만 봤다. dos/lane/library/browser 핸들러의 무시되는 인자는 확인 못 했다.
- masc_keeper_delegate, masc_fusion, masc_lane_*, masc_library_* 등 이번 주 이전부터 있던 deferred 도구의 설명 대 구현은 열어보지 않았다.
- 외부 MCP 도구(github_*, railway_*, supabase_*, cloudflare_*)의 노출 범위는 보지 않았다.
- TU-F53(클라이언트가 안 부르는 route)은 서버 route 쪽에서 세지 않았다. 클라이언트가 부르는 경로가 서버에 있는지만 봤다.
- tools-as-shell-commands(keeper_lane_status, board list, board post get 의 shell_command) 경로의 인자 변환은 확인 못 했다. 최근 3일 Execute 에서 masc board 호출 0건이었다.
- W1-01 에서 code-reviewer 의 09-20 masc_gc 호출이 운영자 지시였는지는 확인 못 했다.
- live 서버가 fda7ada7f6 이고 스냅샷이 e1f1429890 이다. candle 도구 4개 외 도구 변경(config/tools diff)은 portrait_read 문구뿐이었다. 그 57 커밋 안의 핸들러 변경은 candle·portrait 말고는 읽지 않았다.

## W2 배선 점검 2: TOML 키·환경변수 ↔ 읽는 코드, 하드코딩

작은 것들(P3)

- W2-04 MASC_AUTH_STRICT=strict 는 요청을 거절하지 않는다. 2026-04 부터 '다음 단계'로 미룬 로그 전용 설정이다
- W2-05 보존 기간이 환경변수 6개와 리터럴 3개로 흩어져 있고 기본값이 서로 다르다. 둘은 기본이 '영원히'다
- W2-07 운영자가 조절해야 하는 한도가 환경변수로만 바뀌고, 환경변수 카탈로그에는 82개가 빠져 있다 (env_var_sprawl)
- provider-name 과 model-name 별칭(runtime_toml.ml:787,1345,1395, runtime_account_declaration.ml:142)을 받지만 라이브와 저장소 runtime.toml 에서 쓰는 곳이 0이다(legacy_residue).
- keeper_types_profile_toml_parser.ml:420-428 의 assert 는 parsed_field_key_names = keeper_toml_field_names 라서 절대 실패하지 않는다. '선언 없이 파싱한 필드'를 잡는다는 주석과 다르다.
- '"limit" ~default:50' 가 20곳이고 clamp 1..200 이 9곳이다. 공용 함수 Server_utils.standard_limit 은 호출자가 1곳(server_routes_http_routes_activity.ml:1507)이다.
- server_provider_usage_history.ml:9 의 retention_days:16 은 이유가 안 적힌 리터럴이다(W2-05 에 포함되지 않은 근거 없는 상수).
- 라이브 ~/.masc/config/keeper.env 는 권한 0644 이고 API 키 export 2줄이 있다. 읽는 코드가 없다(deploy.sh 는 $REPO_DIR/config/keeper.env 를 읽는데 저장소에 그 파일이 없다). 같은 폴더의 runtime.toml, connection.toml 은 0600 이다.
- 낡은 문서·주석: ENV-CONTRACT.md §4 'Execute exec gates' 는 플래그를 하나도 적지 않고 인용한 exec_buffer.ml, exec_policy.ml 에도 getenv 가 없다. §2 의 keeper.smart_hb_enabled 키는 코드에 없다.
- [tui].last_chat_keeper 는 TUI 세션 상태인데 운영자 소유 runtime.toml 에 줄 편집기로 쓴다(masc_tui_config.ml:51-90).
- 로컬 base URL 을 http://127.0.0.1:%d 로 조립하는 곳이 8곳(masc_cli_setup.ml:216, masc_cli_owner_upgrade.ml:33,53, masc_cli_model_resume.ml:31, server_upgrade_preparation.ml:68, runtime_official_client_mcp_http.ml:449…
- #39566 제목은 '표 이름을 읽는 모든 곳이 variant 에서 가져온다'인데 리터럴이 남아 있다: board_tool_handlers.ml:69, server_voice_setup_actions.ml:278, main_eio.ml:2202, runtime_account_removal.ml:212-251.
- MASC_SEARXNG_URL: ENV-CONTRACT.md 는 기본값을 http://localhost:8888 로 적고 레지스트리 default 는 '(none)'이다.

확인 못 한 것

- init-time 키 8개(W2-02)가 실제로 TOML 값을 못 받는지는 서버를 임시 경로로 띄워 확인하지 않았다(상태 변경 금지). OCaml 의 모듈 초기화 순서와 코드 경로로만 판정했다.
- 설정 화면 effective_value(W2-03)를 라이브 엔드포인트로 읽지 못했다. 11:25 에 서버가 종료 중이어서 GET /api/v1/runtime/config/raw 가 연결 거부였다.
- config/tools/*.toml 202개(도구 정의)의 키별 읽는 곳과 모르는 키 처리는 보지 않았다.
- MASC_* 280개 기본값을 docs 와 일일이 대조하지 않았다. 카탈로그 93개만 정규식으로 대조했다.
- Runtime_params 약 30개 키의 범위·기본값·소비자는 전수 확인하지 않았다. heartbeat 등 쌍이 되는 7개만 따라갔다.
- dashboard/src 의 설정 편집기가 어떤 키를 어떻게 보여주는지는 보지 않았다.
- [providers.*] 표의 모르는 키 무시는 1차 감사 D1-10 이 다뤄서 다시 따라가지 않았다. RT-A8(slots/cli_slots 중복) 상태는 다른 감사관 몫이다.
- MCP 호출자 확인(W2-04)에서 토큰 해석이 실패한 뒤 caller 이름이 그대로 쓰이는 것이 실제 인증 우회로 이어지는지는 Auth.authorize_tool_v2 이후를 따라가지 않았다.
- 열린 PR 본문과 diff 는 읽지 않았고 제목과 파일 이름만 봤다(open_pr 칸의 '확인 못 함' 표시 참고).
- 토큰·키가 든 줄은 출력하지 않았다. ~/.zshenv 는 이름만 확인했다.

## W3 배선 점검 3: 저장 파일·이벤트 producer ↔ consumer, 죽은 표면

작은 것들(P3)

- W3-04 쓰는 곳이 없는 저장소 둘: Mention_inbox 와 Keeper_response_feedback 쓰기 쪽
- Candidate_fault.of_transport_error(candidate_fault.ml:62)와 Runtime_muse_msp.turn_interrupt_request(runtime_muse_msp.ml:489)는 export 만 있고 테스트 포함 호출 0.
- DM-BD-2 열림: ready_confirmation 3,157행(782,714바이트)은 쓰기만 하고 읽는 곳이 없다. 큰 부팅은 1,125행을 더한다.
- bin/masc_tui.ml:3842-3868 tui-account-login.json 은 저장하고 읽기만 하고 지우는 곳이 없다. 라이브에 09-29 20:08 파일이 141바이트로 남아 있다.
- Keeper_chat_events.Tool_replay_mismatch(keeper_chat_events.ml:8,371,398)는 만드는 곳이 없다. dashboard/src/lib/keeper-chat-stream-contract.ts:74 에도 이름이 남아 있다.
- repositories/pulls: 서버가 60초마다 저장소 3곳을 읽는다(server_bootstrap_maintenance.ml:546). TUI 읽는 쪽은 #38801 에서 지워졌고 대시보드는 없다. RFC-keeper-world-state-shows-open-work 가 이 스냅샷을 쓸 곳으로 적으므로 설계상 미연결이다.
- docs/JSONL-CONTRACT-INVENTORY.md 는 2026-05-18 문서이고 Mention inbox 행의 writer 와 reader 이름이 지금 코드에 없다.
- keeper_durable_store.ml:245-262 board_posts on_refusal 문구가 board_core_persist.ml:441-470 의 현재 동작과 다르다(W3-01 에 포함).
- MM-S3 열림: traces/*/skill-activations.json 24개가 남아 있고 OCaml 읽기 코드가 없다. scripts/harness 만 이름을 쓴다.
- DM-BD-10 일부 남음: lane_manifest.ml:23-24 와 tui_decode.ml:6716-6722 가 Workspace Curator 출력을 proposal 로 설명한다.
- mention_inbox.mli 에 Generate a unique mention ID, Append a mention record 같은 지운 함수의 설명이 남아 있다. keeper_response_feedback.mli 머리말은 이미 들어온 read_tally 를 Phase 1b 예정이라고 적는다.

확인 못 한 것

- 이벤트 variant 의 match 가 _ -> 로 뭉개는지는 보지 않았다. 생성자가 자기 파일 밖에서 언급되는지만 봤다. Execution_event(170개)와 Keeper_chat_events(117개)는 match 별 검사를 못 했다.
- W3-02 에서 settled 파티션 행을 dedupe 외에 읽는 곳이 있는지는 내가 다시 따라가지 않았다. 07:35 실행의 검증 결과를 따랐다.
- 라이브 서버 로그에서 /api/v1/mentions/ 와 /keepers/:name/feedback 호출이 오는지 확인하지 못했다.
- workspace_memory 의 ledger.json 쓰기·읽기와 curator 가 아직 proposal 을 내는지(DM-BD-10 의 남은 문구가 맞는지)는 D3 범위라 보지 않았다.
- 데이터 크기는 개별 폴더 du 로만 쟀다. 깊은 du 는 돌리지 않았다. W3-05 의 5.3GB 는 그 합이다.
- keepers/ 아래 로스터에 없는 Keeper 디렉터리(53개 대 27명)의 쓰기 여부는 L3-04 범위라 보지 않았다.
- MM-S4 는 skill 활성화 원장이 Id.t 에 없다는 것까지만 봤다. 그 파일이 부팅 때 실제로 어떻게 읽히는지는 D4-05 에 맡긴다.
- data/ 폴더 안의 다른 하위 폴더 중 masc 코드가 쓰는 것이 더 있는지는 tool-events, keeper-wake-payload, verdicts 만 확인했다.

## X1 렌즈 1: 이번 주 추가된 문자열·부분문자열 판정

작은 것들(P3)

- X1-03 배포 전 durable store 검사가 파일 이름 접두사로 대상을 고르고, 하나도 못 찾아도 통과합니다
- X1-04 TUI 도구 결과 색이 만든 글자를 다시 부분문자열로 읽어 정합니다 (09-29 발견이 그대로)
- bin/masc_tui_types.ml:128-152 TUI 세션 이벤트 event_type 이 string 이고 add_event 호출 35곳이 "error"(18) "info"(8) "system"(4) "observer"(3) "message"(3) 만 씁니다.
- lib/server/server_dashboard_runtime_request.ml:17 의 "exact/" 가 bin/masc_tui_http.ml 과 dashboard settings-surface.ts:827 runtimeLaneNameReserved 에 따로 적혀 있습니다. 서버가 create 에서 강제하므로 영향은 작습니다.
- lib/multimodal/vision_artifact_reference.ml:17-21 durable_consumer_basenames 가 Tool_blob_maintenance 의 같은 목록을 손으로 복사했고, 한쪽은 `"keepers"` 리터럴, 한쪽은 Common.keepers_runtime_dirname 입니다.
- lib/multimodal/vision_artifact_reference.ml:29-41 contains_substring 이 위치마다 String.sub 로 새 문자열을 만듭니다. 큰 파일에서 할당이 늘지만 호출은 유지 보수 스캔 한 곳입니다.
- lib/keeper/keeper_supervisor_reconcile_keepalive.ml:25-33 remember_refusal 이 오류 문장이 같으면 로그를 건너뜁니다(log dedup). 반복 자체의 원인은 이 렌즈에서 보지 않았습니다.
- lib/core/common.ml:172 `List.mem (String.lowercase_ascii name) keepers_root_store_dirnames` 로 예약 디렉터리 이름을 이름으로 판정합니다. 목록은 variant 에서 만들어져 한 곳입니다.
- bin/masc_tui_runtime_account_form.ml, masc_tui_pick_list.ml 의 소문자 비교는 사용자 입력 필터라 정당합니다.
- lib/keeper/keeper_github_identity.ml 의 secret key 이름 예외 몇 건은 문자열 목록이지만 secret_patterns 한 곳에서만 씁니다.

확인 못 한 것

- bin/masc_tui.ml 의 키 입력 문자열 팔 63줄은 하나씩 읽지 않았습니다. docs RFC-tui-single-input-decoder 가 Key of string 을 명세한 것으로 보고 정당 쪽으로 분류했습니다.
- TU-F22, TU-F39, TU-F40, MM-S6, DM-GT-05 의 상태는 이 렌즈에서 다시 읽지 않았습니다.
- DM-GT-09: lib/keeper/hitl_summary_worker.ml:69 에 Source_resolved -> "exact_source_resolved" 가 아직 있고 1084-1089 가 새 reason 문자열을 만듭니다. 새 실행이 그 code 를 내보내는지는 끝까지 따라가지 않았습니다.
- 이 clone 이 shallow 라서 git blame 에 `^8439213b70` 이 나온 줄은 '09-21 이전'이라는 뜻입니다. 그런 줄은 이번 주 추가로 세지 않았습니다.
- Lane addon instance id 에 `/` 를 허용하는지 확인하지 않았습니다(X1-01 의 접두사 충돌 여부).
- 라이브 로그·상태 파일은 이 렌즈에서 보지 않았습니다.

## X2 렌즈 2: 근거 없는 상수·계수·임계값·추정식

작은 것들(P3)

- 초 단위 상수가 흩어져 있어요: lib/config/masc_time_constants.ml(38개 모듈이 씀)가 있는데 seconds_per_day 를 따로 정의한 곳이 5곳(bin/masc_tui_board_quarantine.ml:162, bin/masc_tui_usage_trend.ml:20, bin/masc_tui_task_flow.ml:26,…
- percent 계산을 손으로 두 번 써요: x / 100 * p + x mod 100 * p / 100 (lib/runtime/runtime_muse_prompt_capacity.ml:26-28, lib/keeper/keeper_turn_runtime_budget.ml:148).
- claude_code_inline_result_bytes = 32_768 (lib/runtime/runtime_execution.ml:73)은 근거가 코드에 없어요. CHANGELOG 는 '그 lane 이 선언한 한도'라고만 해요.
- server_board_list_http.ml:36-37 이 Server_utils.standard_limit(server_utils.ml:254)과 같은 50 / 1..200 을 다시 적어요. offset 상한 5000 은 조용히 잘려요(board_posts.jsonl 은 현재 1,880줄이라 아직 안 닿음).
- browser 도구 timeout 이 두 곳에 따로 있어요: server_routes_http_browser_surface.ml:27,30,42 는 60초, tool_misc_browser_lane.ml:168,169 는 60.0, :173 은 10.0, :187 은 45.0.
- HTTP 2xx 판정 status >= 200 && status < 300 이 이번 주 새로 3곳에 생겼어요 (runtime_provider_usage_read.ml:171, server_repository_pulls.ml:463, exact_output_execution.ml:173).
- 로그인 helper 입력 한도 65536 이 runtime_setup_login_session.ml:31 과 :165(6 * 65536 + 1024)에 리터럴로 두 번 있고 helper 스크립트의 64 KiB 와 같은 값이에요.
- dashboard_execute_output.ml:86-89 per_keeper_cap=50, retained_stream_bytes=256 KiB, event_log_capacity=5000, max_line_bytes=4096 에 근거가 없어요. 표시용 버퍼라 Keeper 흐름은 아니에요.
- server_startup_takeover.ml:729-731 은 SIGTERM 뒤 1.0초, SIGKILL 뒤 0.5초 기본값에 근거 주석이 없어요. 09-21 이전 값이고 L3-07 의 .atomic_*.tmp 와 관련이 있는지는 확인 못 했어요.
- keeper_tool_memory_runtime.ml:647 의 limit 1..10 기본 5 가 config/tools/keeper_memory_search.toml 설명문의 숫자와 따로 적혀 있어요. 같은 도구 설정의 숫자를 코드와 TOML 에 이중으로 적은 것이에요.

확인 못 한 것

- 라이브 로그: Stale_ref 가 실제로 얼마나 뜨는지, curator 이웃 놓침 비율, repeated_tool_call_input 5 에서 yield 가 걸린 횟수(#36503 재측정 여부).
- facts 렌더 바이트는 jq 로 ordinary 사실만 근사했어요(label 오차 약 3%). source-bound 포함 실제 값은 못 구했어요.
- e-masc-the-leader 등이 어느 lane 을 타는지(D1-03 에서 15명은 lane 이 없다고 함).
- bin TUI 폭 보정 +1/-1 은 이름 있는 상수와 표본만 봤고 전수는 안 봤어요.
- dashboard TypeScript 상수는 범위 밖이라 안 봤어요.
- '이번 주 추가' 판정을 git log -S 로 확인한 것은 주요 발견 4개뿐이에요. 파일이 쪼개지며 옮겨진 코드(KeeperTurn, dashboard_briefing_assembly 등)는 diff 에 추가로 잡혀서 p3_notes 일부가 오래된 코드일 수 있어요.
- server_startup_takeover.ml 의 SIGTERM 뒤 1.0초 기본값이 데이터에 주는 영향은 확인 못 했어요.

## X3 렌즈 3: 스텁·조용한 실패·catch-all·기본값 삼킴

작은 것들(P3)

- keeper_names_result 가 Error 일 때 warn 로그 + [] 로 넘어가는 곳이 21곳(provider_runs.ml:255,358,389 = TU-F32 포함, dashboard_http_keeper.ml:311,337,996,1068, goals 2, supervisor, tool_keeper_audit, operator_digest,…
- 쓰는 곳이 0인 export 3개: Keeper_turn_boundaries.states_position(mli:274), Lane_addon_sources.browser_selection_lane(mli:7), Runtime_muse_msp.turn_interrupt_request(mli:234).
- 시험에서만 쓰는 export 3개: Keeper_memory_os_recall.render_context(production 은 render_with_source_revalidation), Browser_lane.verb_allowed, Keeper_sandbox_microvm.image_probe_for. 시험이 production 경로를 안 거친다.
- bin/masc_tui_lane_addons.ml:664-665 technical_lines 의 ?(height=24) 는 `let _ = height in` 로 버려진다. 호출 1곳(:1129)이 height 를 넘긴다. 죽은 인자이고 24 는 이름 없는 숫자다.
- lib/dos_lane/dos_lane.ml:586-591 preserve_previous_autosave 는 rename 실패를 삼키고, 이어지는 첫 autosave 가 이전 incarnation 의 저장을 덮어쓴다. ran.autosave 에 이 실패가 안 나온다. 주석에는 의도가 적혀 있다.
- bin/masc_tui_config.ml:216-223 runtime.toml 을 못 읽거나 TOML 이 깨지면 theme, reduce_motion, hints_visible, lift_colours, board_sort 가 전부 기본값으로 읽힌다(last_chat_keeper 만 Error). 값 타입이 틀려도 toml_bool_opt 가 None 이라 같다.
- lib/runtime/runtime_quota_window.ml:108-123 official_client_scope 는 HOME 이 없거나 CODEX_HOME 이 상대경로면 invalid_arg 를 던진다. Result 가 아니다.
- lib/runtime/runtime_setup_spec.ml:129 `| _ -> "agy"` 와 :104 `| _ -> []` 는 닫힌 variant 에 와일드카드를 썼다. Antigravity 를 이름으로 적지 않아 새 variant 가 컴파일러에 안 잡힌다.
- lib/keeper/keeper_turn_driver.ml:628-637 과 :2150-2156 에 read_usage_after_account_refusal 구현이 똑같이 두 벌 있다(결과 버리고 () 반환).
- docs/spec/00-glossary.md:897-904 Lane 항목은 Standalone_lane 이 5개라고 적지만 lib/runtime/standalone_lane.ml 은 7개(Browser_stagehand, Candle_appraiser 추가)다.

확인 못 한 것

- 패턴 hit 857건 중 앞뒤를 읽은 것은 약 250건이다. bin/masc_tui_render*.ml, masc_tui_types.ml, tui_decode*.ml 의 `_ -> ...` 약 400건은 이름과 한 줄만 보고 읽지 않았다. TUI 쪽 조용한 실패(09-29 의 TU-F12 계열)는 이 감사가 새로 확인한 게 아니다.
- dashboard TS 는 84 hit 중 대표 12건만 읽었다.
- 추가 줄이 아닌 기존 코드의 조용한 실패는 범위 밖이라 보지 않았다.
- 라이브 로그·상태 파일은 X3-01 의 runtime.toml 선언과 부팅 로그 확인에만 썼다. WARN 반복 횟수는 세지 않았다.
- 09-29 발견 8개(RT-S6, TU-F12, TU-F21, TU-F29, TU-F32, TU-F38, DM-BD-7, DM-GT-07)의 닫힘 여부는 판정하지 않았다. matrix 줄에 눈에 띈 변화만 적었다.
- '버그를 넣으면 시험이 실패하는가'는 확인하지 않았다(dune 시험을 돌리지 않는 규칙). X3-01 의 시험 제안은 기존 시험이 이 호출 경로를 덮는지 확인하지 못한 채 쓴 것이다.
- fork_daemon 19곳 중 candle_payout_worker, completion_authority_agent, stagehand 3곳, server_repository_pulls 만 읽었다.
- unused 함수 스캔은 이름 토큰 수로 했다. 모듈 별칭 호출은 토큰이 같아 잡히지만, 문자열 안에서 이름을 부르는 호출(리플렉션 없음)은 해당 없음. 후보 14개 중 6개만 직접 확인했다.

## X4 렌즈 4: 숫자만 맞춘 작업 (테스트·증거·측정·게이트 제거)

작은 것들(P3)

- X4-03 서버 시험과 TUI 시험이 같은 거절 응답을 서로 다른 모양으로 고정하고, 초대 시험은 127.0.0.1 을 공개 주소로 고정해요
- X4-06 부르는 곳이 없는 검사 스크립트 16개와 run-edited-tests 사슬 2,263줄이 남아 있어요
- test_keeper_portrait.ml:152-158 주석은 '라이브 규모 roster'인데 이름 25개이고 라이브는 27명. 3개 이름은 대역(lane-smith, quill-tender, lamp-mender), 라이브 5명(gayo-yoga-leader, judas-priest, ocaml-refactor-woman, rondo, sangsu)이 빠짐.
- test_lib/ast_grep.ml:1312 constructor_names_of_type 만 읽기·파싱 실패에 []를 돌려준다(다른 helper 는 failwith). test_tui_http_ast.ml 은 존재 단언이 같이 있어 지금은 안 뚫리지만, '없다'만 단언하는 시험이 생기면 빈 통과가 된다.
- Goal goal-reliable-change-g1-20260909: 09-09부터 executing, 마지막 갱신 09-12, 측정 행 0건. playground summary.json 은 measurement_state not_run 이고 계약 sha 가 다르다(7e701e3b 대 로드맵 c2cf0a67).
- Goal 숫자 목표 두 개는 개수만 잰다: keeper-portrait-items 는 .mli 의 생성자 수 3(completed). Keeper 가 아이템을 얻거나 고르는 코드는 main 에 없다(D8-10). 9cef44ef 의 목표 6 은 문서 6개의 개수다. 둘 다 verifier 가 읽을 수는 있다.
- 옛 Goal 4개(09-09~09-12)는 metric 이 verifier 가 못 읽는 로컬 경로를 가리켜 refuted 후 dropped. 09-22 이후 Goal 은 Board·GitHub 좌표를 쓴다. Goal 생성 때 읽을 수 있는 좌표인지 보는 곳은 없다(Goal_store.upsert_goal 은 자유 문자열을 받음). 스스로 닫힌 문제.
- docs/BENCHMARK-RUNBOOK.md:191 과 scripts/harness/workload/campaign_scoreboard.py:19 가 없는 Goal goal-campaign-ratchet-20260902 와 없는 파일 docs/evidence/keeper-e0-campaign-scoreboard.json(--out 대상, 있는 것은 r4·r6)을 말한다.
- 병합된 #39371, #39412 의 evidence README 가 'PR remains draft'로 남음(D12-04 와 같은 뿌리). #39371 은 p95 악화 두 번을 기록하고도 병합됨.
- 측정 원본이 저장소에 없는 수치: #40080 changelog(14%, 2.96–3.00→0.46–0.49ms)는 라이브 게시판 사본 1,000줄 기준이다. vision-36580779720 표의 Scheduler p99 열은 6행 모두 0.0839 로 같아 이 열로는 변화를 볼 수 없다.
- #40261(release/v0.49.0)은 도구 스키마 상한을 관측값 129,411 바이트에 여유 0 으로 올렸고(+16바이트), #40265 가 상한 시험을 삭제. 지금 도구 목록 크기를 재는 곳은 없다(L1-08 의 Codex 창 95% 와 연결).
- test_tui_keyboard_input.py 20,573줄, lib/tui_decode.ml 12K줄, test_tui_decode.ml 13,014줄. #40234 가 PTY 파일을 24개로 나누는 중(열린 PR, 본문은 Draft 유지라 하나 ready 상태).

확인 못 한 것

- 라이브 Stagehand 에서 첫 slot 이 호출 시간 120초를 다 쓰는지: slot 별 기록이 없어서 확인 못 함.
- Terminal-Bench 원본 결과(bench-harness-design worktree)는 다른 세션이 쓰는 곳이라 열지 않았다. 퍼센트 산수만 확인.
- wkbl 화면 품질 측정 도구 measure.py 는 다른 저장소라 다시 돌리지 않았다. Goal 측정 자체를 다시 돌린 것은 없다(글만 읽음).
- 증거 폴더 393개 중 8개만 원본에서 재계산. 나머지는 README 문장과 manifest 해시만 확인.
- 오래된 PTY 시험의 판정 방식(출력 바이트에 글자가 한 번이라도 나오면 통과하는 needle-in-stream)이 지나간 화면에 속는지는 깊이 보지 않았다.
- 삭제된 검사의 과거 적중: 저장소 history 가 09-21 에서 잘려 있어(shallow) PR 제목과 스크립트 머리말만 근거로 썼다.
- 시험 15개 판정은 코드 읽기와 추론이다. 변이를 넣어 돌리는 것은 금지라 하지 않았다.
- RC 실패(recut 브랜치)가 어떤 PR 조합에서 왔는지는 보지 않았다.
