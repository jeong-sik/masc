# Harness Bench — 실행 진행 상황 (handoff)

## 상태 (2026-09-10)

- Plan: `docs/superpowers/plans/2026-09-10-masc-harness-benchmark.md` (worktree 내)
- Spec: `docs/superpowers/specs/2026-09-09-masc-harness-benchmark-design.md`
- Branch: `bench/harness-design`
- Task 1-8 완료. **Task 9 완료** (Phase 0 harbor 스모크, 아래 요약). 다음은 Task 10 (Phase 1 매트릭스: `./run_matrix.sh a,b,c,e,f,h 3`).

## 제품 픽스 2건 — 전부 머지 + v0.35.6 릴리스 완료 (2026-09-10/11)

- **PR #35168 merged** (anthropic projection), **PR #35169 merged** (tools.deny). 둘 다 적대적 리뷰 블로커 0, CI green.
- #35169 CI가 한 번 실패했던 원인: OCaml warning 16 — optional 뒤에 labelled만 있으면 erase 불가. `~tool_deny` 필수 인자로 교정(c90e0b6f2e).
- **v0.35.6 릴리스 완료** (assets 37개, masc-linux-x64 포함): 첫 태그는 version truth 불일치로 실패 → #35180(version bump) 머지 → 재태그 성공. **주의**: version bump는 dune-project + masc.opam + ROADMAP.md + CHANGELOG.md + **docs/PRODUCT-OPERATING-PLAN.md** 5곳 (lint의 doc-truth check가 마지막 것도 비교 — #35191로 후속 수정, 머지 진행 중).
- **벤치 채택 완료** (a769343e08, pytest 15개 통과): renderer가 `tools.deny` 발행 — spawn 4개(keeper_spawn/read/wait/stop)는 parallel=False arm(b,c,d)에서, delegate 3개(masc_keeper_delegate/status/cancel)는 keepers=1 arm(b-e)에서 deny. arm f/g/h는 deny 없음. anthropic arm의 [[one_of]] 벤치 strip 워크어라운드 제거. fetch_masc.sh 기본 0.35.6. dist/ 는 이미 v0.35.6 x64로 갱신됨.
- **진행 중**: anthropic 레인 스모크 (v0.35.6, arm b, gpt2-codegolf, `ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY_MASC"`, job-name `phase0-arm-b-anthropic`) — 백그라운드 실행 중. 400 해소 + keeper turn 진행 확인이 목표.
- spawn의 실제 모델 이름은 `keeper_spawn`(start) — `keeper_spawn_start` 아님.
- 다음: 스모크 확인 → Task 10 매트릭스 (`./run_matrix.sh a,b,c,e,f,h 3`).

## Task 9 결과 요약 (상세: results/phase0-notes.md)

- install-only 성공 (0 exceptions, bootstrap exit 0): `results/jobs/phase0-install-check/`
- arm A = **kimi-cli** (terminus-2 대체 — kimi-for-coding이 reasoning-only 응답 + 빈 assistant 메시지를 코딩 엔드포인트가 400 거부; 3회 시도 기록됨): **reward 1.0**, 44m35s, `results/jobs/phase0-arm-a/`
- arm B = MASC arm b: **reward 0.0, state=Timeout@2400s**, tool_calls=48, metadata/토큰 회수 확인, `results/jobs/phase0-arm-b/`
- 수정사항(커밋됨): masc-exec-shim 업로드, **dist는 x64 필수** (`MASC_LINUX_ARCH=x64 bash image/fetch_masc.sh`), setup multiplier 5 필요, `EPISODE_TIMEOUT_SEC=2400` 주입(harbor 2700s cap 전에 result.json 쓰기), aggregate.py를 실측 레이아웃(agent_result, job-level 스킵, trial_name 컬럼)으로 보정. `uv run pytest tests/ -q` 14 passed.

## 중요한 판정 변경 — 기본 모델 레인

- **anthropic 레인 BLOCKED (MASC 제품 버그)**: `tool_execute`의 LLM-facing 스키마가 release 바이너리에 crunch 임베드되어 있고(`lib/embedded_config/dune`), top-level oneOf를 Anthropic API가 400으로 거부. `backend_anthropic.ml`에 conformant projection 없음 (v0.35.1, v0.35.2 모두). 벤치 측에서 수정 불가 → upstream 수정 필요.
- **kimi_coding 레인 동작 확인**: smoke에서 keeper가 실제 LLM 턴을 돌려 `/tmp/masc-smoke-ok` 생성, state=Succeeded, 20s, tool_calls=1, tokens 28006/207/0 (trace-*.json ground truth와 일치).
- **결정**: Phase 0/1의 기본 레인은 `kimi_coding` (KIMI_API_KEY는 host env에 SET). `BENCH_RUNTIME_ID=kimi_coding.kimi-for-coding`(? 정확한 alias는 configs/out 렌더 결과 참조). Harbor 베이스라인(terminus-2)도 같은 모델을 써야 하므로 Task 9에서 `--model` 값과 필요 env(KIMI/MOONSHOT base_url)를 맞출 것. harbor의 kimi-cli 에이전트 구현(agents/installed/kimi_cli.py)이 base_url `https://api.kimi.com/coding/v1` + KIMI_API_KEY를 쓰는 것을 참고.
- openai 레인: API는 닿으나 현재 키에 크레딧 없음(미검증).
- `ANTHROPIC_API_KEY`(host env)는 무효 키, 유효한 건 `ANTHROPIC_API_KEY_MASC`.

## Task 7에서 고쳐진 것들 (전부 커밋됨, 3a00bcf69d)

- jq `--argjson` corruption: bash `${final:-{}}` 가 첫 `}`에서 닫혀 잔여 `}`가 payload에 붙던 버그 → `"$final"`로 수정
- keeper_up preflight가 gh auth 요구 → masc_agent.py가 GH_TOKEN 포워드
- TOML dotted-key 버그: `[models."alias"]` 헤더 quoting
- kimi 레인: `ignored_sampling_parameters`, provider-conditional reasoning-effort
- 토큰 usage: `.masc/traces/*/trace-*.json`의 누적 `.usage`를 세션별 max-api_calls 덤프만 합산 (snapshot 제외, double-count 방지) → result.json top-level input/output/cache_tokens
- fetch_masc.sh 기본 버전 v0.35.2

## Task 8-10 잔여 작업 요약 (plan Task 텍스트 참조)

- Task 8: suite/mini-suite.txt(24 tasks, plan에 목록 있음), SELECTION.md, run_matrix.sh, aggregate.py 작성+커밋
- Task 9: `harbor run -d terminal-bench@2.0 -i gpt2-codegolf --agent agents.masc_agent:MascAgent -m <model> --ak arm=b -k 1 -n 1` + terminus-2 베이스라인, aggregate.py 필드 경로를 실제 harbor 산출물 레이아웃에 맞춰 보정
- Task 10: `./run_matrix.sh a,b,c,e,f,h 3` (CONCURRENCY=4) → results/phase1-report.md (spec §6.5 판결 규칙 적용)

## 환경

- bench venv: benchmarks/terminal_bench/.venv (harbor 0.22.0 + pytest, pytest-asyncio 없음)
- 실행은 worktree에서만: /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/bench-harness-design
- main 체크아웃은 타인 WIP로 dirty — 건드리지 말 것
- `uv run pytest tests/ -q` 현재 12 passed

## 2026-09-11 v0.35.7 — 세 번째 제품 갭 픽스 + 채택

- **갭 3**: anthropic 스모크 2회 연속 `turn_failed: 'temperature' may only be set to 1 when thinking is enabled` (oneOf 400은 v0.35.6에서 해소 확인). 원인: `Reasoning_dialect.base_for_provider_config`의 Anthropic arm이 capability row를 소비하지 않아 `ignored_sampling_parameters` 선언이 침묵 무시 + `backend_anthropic`이 sampling 필드 무조건 emit.
- **픽스**: #35193 (reasoning_dialect Anthropic arm이 sampling_policy 소비 + backend_anthropic이 add_sampling_field 게이트 사용, 알고테스트 2개) merged → #35194 (10파일 bump) merged → **v0.35.7 태그/릴리스 (assets 37)** → dist 재fetch 완료 (`dist/.version=0.35.7`), fetch_masc.sh 기본값 0.35.7.
- **aggregate.py 필드 보정**: 추가 수정 불필요 확인. arm-b(kimi) 행에서 reward/tokens/tool_calls/state 전부 파싱됨. terminus attempt3의 reward 공란은 verifier 이전 exception이라 정상.
- **baseline 블로커**: terminus-2 + `openai/kimi-for-coding`은 27턴째 `assistant must not be empty` 400 (litellm↔Kimi wire 비호환, MASC 버스 아님). anthropic 스모크가 통과하면 매트릭스 전체를 `anthropic/claude-fable-5`로 돌려 same-model 비교를 만족시키는 방향.
- **kimi MASC 레인 검증됨**: phase0-arm-b 48 tool calls, 토큰 계측 정상, 40분 Timeout(state 기록됨) — gpt2-codegolf는 난 task.
- 진행 중: `phase0-arm-b-anthropic3` 스모크 (v0.35.7 바이너리).

## 2026-09-11 v0.35.8 — 네 번째 제품 갭 픽스

- **갭 3 검증 + 갭 4 발견** (phase0-arm-b-anthropic3, v0.35.7): temperature 400 해소 확인(요청 통과, 2 tool calls, 토큰 계측 정상). 136s에 신규 실패 `turn_failed: cannot set reasoning_effort "high" when enable_thinking=false`. 체인: thinking-on 첫 시도가 max_tokens truncation → truncation_recovery의 Retry_without_thinking이 enable_thinking만 뒤집고 candidate의 reasoning_effort 잔류 → validate_thinking_controls 정당 거부.
- **픽스**: #35195 (retry 시 candidate에서 reasoning_effort strip, For_testing 노출 + 알고테스트) merged → #35196 bump merged → **v0.35.8 태그**. bench fetch 기본값 0.35.8. CI에서 For_testing re-export 누락 1회 실패 후 수정(로컬 dune 금지 룰의 blind spot).
- 관찰: thinking-on + max_tokens 16k에서 truncation 실제 발생 → 매트릭스 때 anthropic 레인 max_tokens 상향 검토.

## 2026-09-11 anthropic 레인 완전 개통 (smoke 6 PASS)

- phase0-arm-b-anthropic6 (v0.35.8 + adaptive_only + max_output 64k): **reward 1.0, 예외 0**, state=Succeeded, 9 tool calls, dup 0, agent 365s, input 380k(전량 cache hit급), output 22.9k.
- 갭 5/6은 제품 버그가 아니라 벤치 선언 오류였음: fable-5는 disabled 미지원(adaptive_only 필요), 출력 상한 8192 기본값 부족(64000 필요). 제품 capability 모델이 이미 올바른 노브 제공.
- 최종 실패 시퀀스: 12s(oneOf→v0.35.6) → 12s(temperature→v0.35.7) → 136s(retry effort→v0.35.8) → 138s(disabled→adaptive_only) → 775s(output ceiling→64k) → **PASS**.
- Task 10 착수: BENCH_MODEL=anthropic/claude-fable-5, arms a,b,c,e,f,h × 24 tasks × 3회, CONCURRENCY=4, timeout multiplier 전 arm 동일(setup 5 / agent 3).
