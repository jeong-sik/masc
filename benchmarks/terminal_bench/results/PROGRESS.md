# Harness Bench — 실행 진행 상황 (handoff)

## 상태 (2026-09-10)

- Plan: `docs/superpowers/plans/2026-09-10-masc-harness-benchmark.md` (worktree 내)
- Spec: `docs/superpowers/specs/2026-09-09-masc-harness-benchmark-design.md`
- Branch: `bench/harness-design`
- Task 1-8 완료. **Task 9 완료** (Phase 0 harbor 스모크, 아래 요약). 다음은 Task 10 (Phase 1 매트릭스: `./run_matrix.sh a,b,c,e,f,h 3`).

## 제품 픽스 2건 (2026-09-10, 별도 worktree/브랜치 — 벤치 발견사항의 upstream 수정)

- **PR #35168** (`fix/anthropic-tool-schema-oneof`, origin/main 기반): `backend_anthropic.ml`에 Anthropic-kind 전용 top-level oneOf/anyOf/allOf projection 추가 (OpenAI #34054와 같은 층). Kimi kind은 통과(해당 엔드포인트는 top-level 허용, 라이브 검증). combinator-only 스키마는 `type:object` 합성. 적대적 리뷰 통과(블로커 0). **merge + release 후 anthropic 레인 재개 가능.**
- **PR #35169** (`fix/keeper-capability-gate`, origin/main 기반): keeper TOML `[keeper.tools] deny = [...]` 추가 — model-visible 이름으로 built-in tool을 capability surface에서 완전 제거(dispatch bundle/digest 포함, frozen-surface admission이 dispatch 거부). 적대적 리뷰 통과(블로커 0). **merge + release 후 arm c/d 렌더러가 skills.names 외에 `tools.deny = ["keeper_spawn","keeper_spawn_read","keeper_spawn_wait","keeper_spawn_stop","masc_keeper_delegate","masc_keeper_delegate_status","masc_keeper_delegate_cancel"]`를 추가로 쏘도록 renderer 갱신 필요** — 그 전까지 arm c는 composition skill 2개만 게이트되고 spawn/delegate는 전 arm에서 visible(단 우리 토폴로지에서 spawn-Start는 remote_ssh profile이라 어차피 Policy_rejection).
- spawn의 실제 모델 이름은 `keeper_spawn`(start) — `keeper_spawn_start` 아님.
- 벤치가 쓰는 release 바이너리(v0.35.2)엔 두 픽스 모두 없음. matrix 전에 release 포함 여부를 결정할 것: 포함되면 arm c/d 정직해지고 anthropic 레인 복귀, 안 되면 현재 한계를 리포트에 명시.

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
