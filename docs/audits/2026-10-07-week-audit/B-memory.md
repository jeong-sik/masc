# B-memory 감사: Librarian / Memory / Skills

기준: origin/main (작업 트리 lib 는 b99c9d77 직전 fb5344a25a 와 같고, b99c9d77 은 working_context 프롬프트 한 줄 정리라 영향 없음). 라이브 데이터: ~/me/.masc (2026-10-07 14시 KST 표본).

## 1. 영역 지도

- 입력: 턴이 끝나면 `turn-boundaries.jsonl` 에 경계 줄이 쌓이고, atom(대화 조각)은 체크포인트에 있다. 공식 클라이언트 세션은 별도의 "official line" 커서로 읽는다.
- 트리거: `Keeper_librarian_queue_signal.changed` 신호가 오면 `keeper_librarian_queue_refresh.ml` 이 한 번 돈다. 타이머 없음. 실패해도 재시도 타이머를 안 세우고 다음 신호(다음 턴)를 기다린다 (queue_refresh.ml:426).
- 읽을 범위 선택: `keeper_librarian_durable_consumer.ml` (consume_one_with_extent, 550줄 함수) + `keeper_librarian_range.ml` + 위치 파일 `librarian-progress.json`. 실패하면 메모리 내 `failed_ranges` Hashtbl 로 "첫 cut point 까지만" 좁혀 읽는다 (durable_consumer.ml:552-571, 1361).
- LLM 실행: `keeper_librarian_runtime.ml` `run_best_effort` (약 700줄 한 함수, 1190-1880). 순서는 슬롯 확보 → (옵션) JEV preflight → exact lane 실행 → 작업 맥락(working context) 반영 → absorb gate → `Keeper_memory_os_current.apply_disposition` → continuity 스냅샷 → events(Revised).
- 저장소 (keeper 당): `<k>.memory-current.json`(스냅샷), `.memory-journal.jsonl`(append-only), `.memory-events.jsonl`, `.memory-absorbed.jsonl`, `.memory-source-current.json`, `.librarian-range-commit.json`, `.working-context*.json`. 실행 기록은 `exact-lane-runs-v6.jsonl` + `exact-lane-run-payloads/<run>/`.
- 쓰기 경로 2개: Librarian(`source=librarian`, 모든 claim 이 origin=injected) 과 keeper 도구 `keeper_memory_write/retract/search` (`keeper_tool_memory_runtime.ml` 2270줄).
- 읽기(recall): 매 턴 `keeper_run_tools_hooks.ml:1009` → `Keeper_memory_os_recall.render_if_enabled`. 검색 도구가 있으면 "사실 N개 저장됨, 필요하면 keeper_memory_search 쓰라"는 짧은 안내만 넣는다. 본문은 안 넣는다 (#40473, #40782).
- 스킬: `keeper_skill_*` 14개 파일(catalog 825줄, activation_ledger 2609줄) + 도구 `keeper_skill`, `keeper_skill_validate`, `keeper_skill_publish`.

## 2. 7일 흐름 (이 영역 파일 기준)

- D-7→D-6 (09-29→09-30): 11 파일, +545/-333. #40019 끝 줄 없는 atom 도 읽게 함, #40001 Librarian 이 사실을 안 바꾸면 스냅샷을 다시 안 씀 (09-29 에 Librarian 커밋 2,379 건 중 1,600 건이 변화 없음이었다는 측정에서 나온 수정), #39972 native resume 반복 컨텍스트 제거.
- D-6→D-5 (09-30→10-01): 7 파일. #40473 "저장된 지식을 전부 주입하지 말고 필요할 때 검색". 작업 맥락 recall artifact 보존/복구 (#40557, #40486), 컨텍스트 identity 충돌 수정 (#40481). 같은 영역 fix 가 3건 연속 (working-context recall artifact).
- D-5→D-4 (10-01→10-02): 22 파일, +611/-169, 가장 큰 날. 12개 커밋 중 fix 11. recall 검색 우선 (#40782, #40784, #40826), exact-lane backpressure 귀속 (#40742), CLI 용량 증거 (#40741), recall artifact 복구 (#40739), 턴 위치 (#40716), absorb 평가 dispatch 전 저장 (#40709), 역사적 Task 맥락 (#40681, #40686, #40672), durable catch-up 양보 (#40652). 라이브 저널에서 10-02 하루 failed 줄 4,806 개: 같은 날 provider 장애가 겹쳤다.
- D-4→D-3 (10-02→10-03): 2 파일 ±15. #40789 최신 상태 보존 전에 내구 가치 판단, #40844 짧은 질의 검색.
- D-3→D-2 (10-03→10-04): #40758 JEV no-change preflight (opt-in), #40744 카테고리 동적 생성, #40944 취소를 정지 중인 executor 밖에서 기록.
- D-2→D-1 (10-04→10-05): 변경 없음.
- D-1→HEAD (10-05→10-07): 8 파일. #41297 preflight 적격 판정을 "프롬프트에 보이는 것" 기준으로 (직전 구현은 라이브 패스를 전부 거절했다고 커밋이 적음 = #40758 이 며칠 동안 사실상 동작 안 함), #41398 반복 감지가 도구 답만 비교 (sangsu 가 12개 claim 을 1,861번 다시 쓴 일), #41483 프롬프트 불변부 앞으로 (캐시), #41431 검색 랭킹이 메인 도메인을 막던 문제, #41332 judgment lane 이 admission permit 우선.
- 뒤집기/재수정(churn) 징후: (a) preflight: #40758 → #41297(적격 기준 수정) → 아직 라이브에서 85% 가 400 으로 실패 (아래 D1). (b) working-context recall artifact 가 #40486, #40557, #40739 로 3번 고침. (c) recall: 주입 → 검색(#40473) → 검색 최적화(#40782/#40784/#40826/#40844/#41431) 로 5번 연속 후속 수정.

## 3. 기능 매트릭스

경로 약칭: K=lib/keeper, RT=K/keeper_librarian_runtime.ml, DC=K/keeper_librarian_durable_consumer.ml, QR=K/keeper_librarian_queue_refresh.ml, CUR=K/keeper_memory_os_current.ml, TOOL=K/keeper_tool_memory_runtime.ml.

| 기능 | 정상 경로 | 경계·코너 | N-Tick | 관측성 | TUI | 테스트 | 판정 | 근거 | 제안 | 크기 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 Librarian 사이클 (읽기·위치·실패) | 턴 끝 신호(keeper_agent_run_post_turn_memory.ml:93) → QR:590 run → DC.consume_one(:799) → RT.run_best_effort(:1190). 29개 keeper 모두 위치가 턴 경계 최신과 0.3시간 이내 (라이브) | 실패하면 `failed_ranges`(DC:552), 폭 `limited_widths`(QR:35)를 서버 메모리에만 기록해 재시작하면 잊는다. 공급자 실패는 쉬지 않고 다음 신호마다 재시도 | 위치는 닫힘(진행). 비용은 열림: 장애 때 시간당 최대 965번 실패(10-02 00시) | exact-lane-runs-v6 + payload(최근 2000건 = 약 8시간만 남음, exact_lane_run_registry.ml:271), 저널 failed 줄 | Memory 화면(bin/masc_tui_render_memory.ml), 대시보드 memory-health | test_keeper_librarian_durable_consumer/range/progress/retry/cancellation 등 18개 | 의심 | 결함 D2, D3 | 고침 | M |
| 2 기억 생산 (Librarian + keeper_memory_write) | Librarian 이 새 claim 을 내면 RT 가 absorb gate → CUR.apply_disposition(:2492). keeper 도구는 TOOL:1780 → upsert | 같은 바이트를 또 쓰면 snapshot 을 다시 쓰고 revision 이 오른다 (CUR:2338-2352, :2750) | 사실 수는 닫힘에 가까움(최대 298KB/512KB, 하루 순증 -45~+857). 쓰기 비용은 열림 | 저널(committed/failed/noop), memory-events | Memory 화면 | test_keeper_memory_write, memory_os_current, memory_journal_projection | 의심 | 결함 D4. 현재 사실의 91%가 Librarian 작성(injected 4602 / authored 456) | 고침 | S |
| 3 합성·파생 (derived, premise) | keeper_memory_write 에 rule_id+premise_ids → derivations_supported(CUR:663) → maintain_supported_facts(CUR:1196) 가 지지 집합 유지 | 전제가 사라지면 자동 철회 | 닫힘 (고정점) | change.invalidated 줄 | 미확인 | test_keeper_memory_os_current | 의심(과잉) | 라이브 5,058 사실 중 derived 4개, 모두 전제 1개짜리 단일 derivation. 코드 언급 353곳(types 71, current 116, tool 166) | 지움 또는 둠(§7) | L |
| 4 삭제 (retract, supersede, quarantine, purge) | retract_fact(CUR:2859), supersede_fact(CUR:2909), retract_facts(CUR:3005), 읽을 수 없는 snapshot 은 quarantine 줄(CUR:1422)로 | retract 는 현재 목록에서만 뺀다. 원문은 저널 줄과 absorbed 파일에 계속 남는다 | 저널·absorbed 는 열림(보존 정책 없음) | quarantined 줄(라이브 0건), retraction plan receipt | 미확인 | test_keeper_memory_write_supersedes, memory_os_current | 정상(삭제 의미는 "현재에서 제거") | 라이브 retract 사용 3턴/5,615턴 | 둠 | - |
| 5 흡수 (absorb gate, JEV, absorbed store) | RT 가 gate 호출(RT:1595) → 문장 단위로 JEV 에 묻고 conveyed_boundary=0.5 로 판정(K/keeper_librarian_absorb_gate.ml:146) → 흡수된 사실은 `.memory-absorbed.jsonl` | 32KB 요청 상한을 gate 에서 먼저 확인(:169). 같은 질문을 다시 물음 | 질문은 열림(매 pass 재질문), absorbed 파일은 열림(1.7MB, 914행) | #41513 absorb 실행 기록, 단 elapsed_s 가 전부 0.0 | 미확인 | test_keeper_librarian_absorb_gate | 의심 | 결함 D6, D7 | 고침 | S |
| 6 강화 (재관측, 지지 갱신, 감쇠) | 같은 바이트가 다시 오면 last_seen 만 앞으로(CUR:2750-2775). 횟수·강도는 일부러 세지 않음(RFC-0418) | 감쇠·만료 없음 | 열림 (오래된 사실이 줄어드는 길은 Librarian 의 drop 뿐) | 없음 | 없음 | test_keeper_memory_os_current | 미확인(설계상 없음) | last_seen 을 읽는 코드는 Librarian 프롬프트(K/keeper_librarian.ml:234)뿐 | 둠, 감쇠가 필요하면 RFC 먼저 | - |
| 7 턴으로 회상 (recall) | 매 턴 keeper_run_tools_hooks.ml:1009 → keeper_memory_os_recall.ml render_demand_notice(:103): 개수와 "keeper_memory_search 쓰세요" 안내만 | 검색 도구가 없으면 artifact 경로(:111) | 닫힘 (고정 크기 약 1.2KB) | 대시보드 recall_enabled, 회상 불가 카운터 | Context inspector | test_keeper_memory_os_current, test_keeper_codex_current_context | 정상 | 매 턴 snapshot 전체(평균 94KB, 최대 298KB 렌더 크기)를 읽고 파싱해 개수만 낸다 (:23-31, :103-113). 사용률: 회상 도구 사용 279턴, 쓰기 472턴 / 5,615턴 | 고침(개수 캐시) | S |
| 8 반복 해법 → Skill | 자동 경로 없음. keeper 가 직접 keeper_skill_publish(K/keeper_skill_publish.ml) | validate 는 publish 와 별개 도구 | 열림: 기억의 lesson/validated_approach 가 Skill 로 이어지는 닫는 단계가 없다 | skill-activations 8,365건 | 도구 목록 | test_keeper_skill_publish/validate/catalog 등 | 결함(루프 안 닫힘) | Librarian 프롬프트에 skill 언급 0건. 5,615턴 중 publish 3턴, validate 0턴, keeper_skill 열람 85턴. ~/.masc/skills 22개(활성화 기록에는 다른 소스의 skill 도 섞임). 활성화 8,365건 중 71%가 work-intake(4,184)와 msx-observe(1,744) | 합침 또는 둠(§5 D8) | M |
| 9 작업 맥락 (working context) | RT:1451 organize_working_context → Keeper_librarian_context.commit(K/keeper_librarian_context.ml:201-245) → recall artifact 게시 | 비어 있는 결과도 매번 commit | 쓰기는 열림: revision 합계 60,442 | context_write 상태가 run output 에 | Context inspector | test_keeper_librarian_context*.ml | 의심 | 결함 D5. keeper 29명 중 16명이 pocket 0개 | 고침 | S |

N-Tick 요약: 
- Librarian 위치: 닫힘. 성공하면 위치가 한 칸 앞으로 가고, 라이브에서 29개 keeper 모두 밀림이 0.3시간 이내.
- Librarian 공급자 실패: 상태는 닫혀 있고 비용이 열려 있다. 위치는 그대로인데 신호마다 같은 250KB 요청을 다시 보낸다 (D3).
- 저널(`.memory-journal.jsonl`): 열림. 줄이 계속 쌓이고 지우는 코드가 없다. 합계 88MB, 20%(17MB)가 failed 줄.
- absorbed 파일: 열림. keeper 당 최대 1.7MB(914행)이고 검색 때마다 통째로 읽는다 (TOOL:331-340).
- 사실 목록: 느리게 열림. 상한은 커밋 때 512KB 검사(K/keeper_memory_os_render.ml:38-51)뿐이고 현재 최대 298KB.
- 작업 맥락 revision: 파일 크기는 닫힘, 쓰기 횟수는 열림(D5).

## 4. 결함 목록

### P1

**D1. JEV preflight 의 85%가 400 으로 실패한다. 3%만 판정하고 1%만 LLM 호출을 아낀다.**
- 위치: lib/typesafeai/typesafeai_librarian_preflight.ml:34-60 (assess 에 크기 검사 없음), RT:1411-1423 (프롬프트 전체를 보냄). 설정: ~/me/.masc/config/runtime.toml:1467 `librarian_preflight = true`.
- 상황: 라이브 librarian 실행 1,852건 중 preflight 상태가 ineligible 1,268, failed 506, judged 70, invalid 1. failed 506건은 전부 HTTP 400 `max_tokens_exceeded`. judged 70건 중 LLM 을 생략한 것(`full_llm_skipped`)은 20건(1.1%). 즉 적격 596번 호출해서 20번 아꼈다.
- 원인: 프롬프트가 중앙값 250KB인데 JEV 상태 한도는 32k 토큰이다. 같은 한도를 흡수 게이트는 먼저 막는다 (absorb_gate.ml:169-170 `request_bytes_limit = 32_000`). preflight 에는 그 검사가 없다. #41297 이 적격 판정만 고쳤고 크기는 안 봤다.
- 덤: 실패해도 keeper 의 전체 기억과 대화 조각이 외부 api.typesafe.ai 로 매번 나간다.
- 확신: 높음 (라이브 출력 1,852건 집계).
- 최소 수정: 지움. 쓰는 곳 하나(RT)이고 효과 1%다. 남기려면 크기가 한도를 넘으면 `Ineligible` 로 돌려서 호출 자체를 막는다.

**D2. Memory pass 는 새 근거 약 0.8KB를 처리하려고 기억 전체 약 139KB를 매번 보낸다.**
- 위치: K/keeper_librarian.ml:322-341 `prompt_variables` 의 `current_memory`. 라이브 payload 에서 변수별 크기(중앙값): librarian pass current_memory 138,976B vs conversation_history 818B.
- 상황: 8.1시간(06:20~14:29) 동안 1,854번 실행. 입력 합계 약 495MB(한국어 바이트/토큰 비율을 3.5로 가정하면 약 1.4억 토큰, 추정). pass 종류: working_context 954(51%), librarian 750, continuity 152. working_context pass 도 current_memory 142KB를 같이 보냈다. 이 부분은 b99c9d77(#41408)이 HEAD 에서 이미 뺐다. 배포 여부는 미확인.
- Memory pass 의 64%는 결과가 "변화 없음"이다 (저널 noop 19,452 / change 11,007).
- 확신: 높음(크기), 중간(토큰 환산).
- 제안: 관련 사실만 고르는 단계(keeper_memory_search_index 의 FTS5 가 이미 있다)와 주기적 전체 정리로 나누는 설계가 필요하다. 이건 RFC 가 먼저다. 당장 줄일 수 있는 건 변화 없음 pass 를 부르지 않는 쪽이다.

### P2

**D3. 공급자 연결 실패가 쉬지 않고 신호마다 재시도된다.**
- 위치: lib/runtime/runtime_exact_lane_backpressure.ml:15-35 (속도 제한과 할당량만 슬롯을 쉬게 하고, "rate limit 이 아닌 실패는 쉼을 만들지 않는다"고 주석에 적혀 있음), QR:426 (실패하면 타이머 없이 다음 신호 대기).
- 상황: 9일 저널에서 `exact_execution_failure` 14,545줄(17MB). 그중 9,651줄이 슬롯 ollama-cloud-deepseek-v4-1-flash 의 `completion failed raw_response=none`. 간격 중앙값 22초, 10-02 00시 한 시간에 965건. 실패마다 보낸 요청은 중앙값 250KB. CLI 대체 슬롯(claude sonnet)도 1,269번 "fallback exhausted".
- 확신: 높음(저널), 중간(요청 크기가 실패 요청에도 전부 전송되는지 — 연결 실패라 일부는 본문 전송 전일 수 있음, 미확인).
- 최소 수정: 새 쿨다운을 만들지 말고 이미 있는 backpressure 저장소에 "연속 연결 실패한 슬롯"을 타입으로 넣는다 (`Candidate_fault` 같은 닫힌 변형이 이미 있음, glossary 785행). 상한·쿨다운 숫자 추가는 증상 억제 패턴이라 RFC 로 닫을 것.

**D4. 똑같은 claim 을 다시 쓰면 snapshot 전체를 다시 쓰고 revision 이 오른다.**
- 위치: CUR:2338-2352 (`update_locked_with_error` 가 항상 `Write_revision`), CUR:2750-2775 (`insert_or_reobserve`), 주석 CUR:1940-1943.
- 상황: sangsu 가 12개 claim 을 1,861번 다시 썼다 (10-06). 저널에 reobserve_rewrite 1,979줄(3MB), 그만큼의 revision 과 snapshot 쓰기(81KB 파일 × 1,861 = 약 150MB 쓰기). #41398 은 반복 감지기가 도구 답만 보게 했을 뿐 쓰기는 그대로다. Librarian 쪽은 #40001 에서 같은 문제를 이미 `Keep_stored` 로 고쳤다.
- 확신: 중간(코드 확인, last_seen 을 갱신해야 한다는 주석이 근거라서 일부러 쓰는 것일 수 있음).
- 최소 수정: `last_seen` 은 Librarian 프롬프트에만 쓰이므로(K/keeper_librarian.ml:234) 같은 바이트의 재관측은 revision 을 올리지 않고 현재 receipt 를 그대로 돌려주는 쪽이 맞다. 읽는 쪽이 없는 필드를 갱신하려고 쓰기를 만든 셈이다.

**D5. 작업 맥락은 내용이 같아도 매번 revision 을 올리고 파일과 recall artifact 를 다시 쓴다.**
- 위치: K/keeper_librarian_context.ml:241-245, 호출 RT:1451-1486.
- 상황: revision 합계 60,442 (29명). pr-updater 5,761, e-masc-the-leader 5,031 인데 둘 다 pocket 0개. keeper 16명이 비어 있음. Memory 쪽은 #40001 에서 "안 바뀌면 안 쓴다"로 고쳤는데 작업 맥락은 빠졌다 (N-of-M 모양).
- 확신: 중간(쓰기 비용은 크지 않을 수 있음; 구독자 깨움은 미확인).
- 최소 수정: pockets 와 sources 가 이전과 같으면 Ok 로 이전 snapshot 반환(commit 안 함).

**D6. 흡수 게이트가 같은 질문을 되풀이해서 묻는다.**
- 위치: K/keeper_librarian_absorb_gate.ml (기억 장치 없음. cache/memo 검색 결과 0건), RT:1595.
- 상황: 남은 evaluation 148건, 질문 1,467개 중 144개(9.8%)는 (keeper, state, question)이 완전히 같다. 같은 문장이 다른 state 로 다시 묻힌 경우까지 334번, 한 쌍이 최대 8번. 되풀이한 쌍에서 답이 갈린 적은 0건, 점수 차이 중앙값 0.01. 낭비 바이트 약 55만. 질문 바이트의 82%는 고정 안내문.
- 확신: 중간(표본이 8시간치).
- 최소 수정: (claim sha, statement sha, direction) 결과를 absorbed 파일 옆에 기억하거나 고정 안내문을 요청 앞쪽으로 둔다.

### P3

- **D7. absorb 평가 실행 기록의 elapsed_s 가 하드코딩 0.0.** RT:1359, RT:1387. 159건 전부 0.0. #41513 이 기록하는 실행 기록인데 지연시간을 못 읽는다. 측정해서 넣거나 필드를 빼야 한다. 확신 높음.
- **D8. 반복 풀이가 Skill 로 이어지는 닫는 단계가 없다.** Librarian 프롬프트(config/prompts/librarian*.md)에 skill 언급 없음. 기억에는 lesson 2,156개, validated_approach 356개가 쌓이는데 이를 Skill 후보로 올리는 코드 경로를 못 찾았다. publish 는 keeper 가 직접 부르는 도구뿐이고 5,615턴 중 3턴. 설계상 없는 것일 수 있어 "결함"이라기보다 요청된 루프가 안 닫혔다는 뜻. 확신 중간.
- **D9. 저널·absorbed 에 보존 정책이 없다.** 저널 합계 88MB (가장 큰 파일은 직접 안 쟀음, sangsu 5.8MB). 폭주한 실패 줄이 20%. retract 확인용 `journal_contains_entry`(CUR:1747)는 파일 전체를 읽는다. 확신 높음.
- **D10. 재시작하면 잊는 전역 Hashtbl 5개.** QR:16,17,35,495, DC:552. 재시작 직후 폭 제한이 풀려 첫 pass 가 전체 밀린 범위를 한 번에 읽는다. 확신 중간.
- **D11. 한 함수가 너무 크다.** RT `run_best_effort` 약 700줄(1190-1880), DC `consume_one_with_extent` 약 550줄(799-1350). 참조 셀 10여 개와 클로저로 얽혀 있어 테스트가 For_testing 뒤로 가야 한다(RT:1884, DC:1420). 확신 높음.

## 5. 낭비

| 무엇 | 크기 | 어디 | 고칠 곳 |
|---|---|---|---|
| Memory/continuity pass 마다 전체 기억 재전송 | 중앙값 139~142KB/회, 8시간 1,854회 합계 약 495MB | K/keeper_librarian.ml:322 | D2 |
| working_context pass 가 기억 전체를 보냄 | 954회 × 142KB = 약 135MB (전체 입력의 27%) | b99c9d77 로 HEAD 에서 제거됨 | 배포 확인 |
| JEV preflight 실패 호출 | 506회 × 약 250KB 외부 전송, 절약 20회 | typesafeai_librarian_preflight.ml:34 | D1 |
| 공급자 실패 재시도 | 9일 14,545회, 17MB 저널 | runtime_exact_lane_backpressure.ml | D3 |
| 반복 absorb 질문 | 144회, 약 55만 바이트 | absorb_gate.ml | D6 |
| 같은 claim 재기록 | 1,979줄 3MB + snapshot 150MB 쓰기(한 keeper) | CUR:2338 | D4 |
| 매 턴 snapshot 을 읽고 파싱해 개수만 출력 | keeper 평균 94KB, 최대 298KB, 매 턴 | keeper_memory_os_recall.ml:23-31, 103-113 | 개수 캐시 |
| 빈 작업 맥락 쓰기 | revision 60,442 | keeper_librarian_context.ml:241 | D5 |
| payload 보존 | 1.8GB, 4,237 폴더 (librarian 약 250KB × 1,852) | exact_lane_run_registry.ml:271 | 입력을 sha256 참조로 |

참고: 8시간 창이라 하루 환산은 하지 않았다 (시간대별 편차 큼).

## 6. 용어·결합

- **absorb 의 두 뜻.** (1) 기억 A 가 B 에 흡수된다 (`absorbs`, `.memory-absorbed.jsonl`, absorb gate). (2) 턴 경계 줄 종류 `Absorbed { trace_id; end_atom }` 와 TUI 의 "absorbed to atom N" 은 "Librarian 이 이 턴까지 읽었다"는 뜻 (glossary 3047-3056). 분리 제안: (2)는 `Read_through` 같은 이름.
- **claim 의 세 뜻.** Task 전이 `Claim`, Fact 의 문장 필드, 소스 결속 기록의 `claim_id` (glossary 2166-2173이 이미 구별 설명). 코드에서 Fact 문장 필드는 `claim`. 한 단어로 둘 다 부르는 건 둠(설명 있음).
- **Working context 세 뜻.** glossary 2676-2684 가 이미 적었다: Librarian pocket 묶음 / `Keeper_types.working_context`(Checkpoint) / route 이름. 앞의 둘은 이름이 같고 뜻이 달라서 코드 쪽을 `Keeper_types.checkpoint_holder` 처럼 바꾸는 게 맞다.
- **Librarian 한 번의 이름이 pass, round, cycle, unit.** glossary 3063이 pass 로 통일하라고 적었으나 QR 주석과 로그에 round/unit 이 남아 있다.
- **ordinary 대 source-bound 기억.** 같은 "Memory" 지만 파일 둘(`memory-current.json` 5,058 사실, `memory-source-current.json` 79 사실)이고 읽기 경로도 둘이다. 사용량이 1.5%라 합칠 후보 (아래 §7).
- **결합.** Librarian 이 working context(받은 일 정리)와 Memory(장기 기억)와 continuity(대화 요약)를 한 신호·한 파이프에서 처리한다. 같은 신호로 durable → continuity → queue context pass 가 차례로 도는데(QR:558-585), 이 세 일은 입력도 저장소도 다르다. 분리해도 잃는 게 없다(실행 기록의 prompt key 가 이미 셋으로 나뉘어 있음).

## 7. 지울 것

- JEV no-change preflight 전체 (D1). 쓰는 곳 하나, 라이브 효과 1%.
- `Keeper_memory_os_recall.render_context` (keeper_memory_os_recall.ml:49): 프로덕션 호출 0건, 테스트 6곳에서만 부른다. 기억 전부를 프롬프트에 넣던 옛 경로의 잔재.
- `render_with_source_revalidation` (:125-197): 검색 도구도 artifact 도구도 없는 표면에서만 닿는다. 그런 표면이 실제로 있는지 미확인 (확인되면 지움).
- derived 기억의 지지 집합 유지 코드: 사실 5,058개 중 4개이고 전부 전제 1개 (CUR:663, :1196, types 71곳, tool 166곳). 쓰는 사람이 사실상 없다. 지우기 전에 operator 확인이 필요 (설계 결정).
- source-bound 기억 798줄(K/keeper_memory_source_current.ml): 사실 79개(1.5%). 존재 이유(소스 sha 재검증)는 있지만 쓰임이 적다. 합치거나 남길지는 operator 판단 (둠).
- 전역 Hashtbl 5개 (D10)는 파일 상태로 옮기거나 지운다.
- `eval_memory_os_value.ml`: 점수 공식만 있고 라이브 측정은 LLM 판정에 넘겼다고 파일이 직접 말한다. 기억이 도움이 되는지 재는 하네스가 실제로는 없다 (회상 도구 사용 5%, 쓰기 8%). 하네스 우선 원칙 위반으로 기록.
