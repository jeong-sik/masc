# MASC × Terminal-Bench 2.0 (Harbor)

MASC 하네스 자체를 벤치마크한다. 스펙: docs/superpowers/specs/2026-09-09-masc-harness-benchmark-design.md

## Setup

    ./image/fetch_masc.sh          # prebuilt masc 바이너리
    uv venv && uv pip install harbor pytest
    export ANTHROPIC_API_KEY=...   # 또는 BENCH_API_KEY_ENV가 가리키는 키

## Smoke (1 task, arm B)

    source .venv/bin/activate
    harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
      --agent agents.masc_agent:MascAgent -m anthropic/claude-fable-5 \
      --ak arm=b -k 1 -n 1 -o results/jobs

## Mini-suite matrix

    ./run_matrix.sh                # arms a,b,c,e,f,h × suite × k=3
    python aggregate.py            # results/jobs → results/summary.csv

## Lane status (2026-09-10, masc v0.35.6)

- `kimi_coding/kimi-for-coding` — docker smoke Succeeded (1 keeper, arm b);
  needs `GH_TOKEN` in the env (keeper_up preflight runs `gh auth status`).
- `anthropic/claude-fable-5` — unblocked in v0.35.6: backend_anthropic now
  projects top-level oneOf/anyOf/allOf out of tool input_schemas at request
  build time (#35168). The bench-side [[one_of]] strip in render_configs.py
  was removed at the same time. Needs re-verification against the release
  binary; use `ANTHROPIC_API_KEY_MASC` (host `ANTHROPIC_API_KEY` is invalid).
- arm spawn/delegate gating uses keeper TOML `tools.deny` (v0.35.6, #35169):
  spawn tools denied when parallel=False (arms b, c, d), delegate tools
  denied when keepers=1 (arms b-e). The earlier skills.names-only gating
  could not hide them.
- `openai/gpt-5.x` — harness reaches the API; the current OPENAI_API_KEY
  project has no credits and lacks gpt-5.5, so this lane is unverified past
  the request-build stage.
- `openrouter/<vendor>/<model>` — 스윕 레인. `OPENROUTER_API_KEY`(크레딧 충전됨).
  `BENCH_MODEL=openrouter/z-ai/glm-5.3 ./run_matrix.sh b,c,e 3` 처럼 쓴다.
  glm/deepseek 계열 단가($0.09~1.4/1M)로 fable($10/$50) 매트릭스 전부를
  돌리는 대신 넓게 여러 번 돌리는 용도. capabilities_base="openai" 라
  reasoning_effort 노선으로 렌더된다.

## 4.0 확인런 (매트릭스 승자 arm 용)

2.0 매트릭스는 내부 절제 비교용으로 버전 일관성만 필요하다. 외부 닻과 비교하려면
4.0 확인런을 승자 arm + Terminus 베이스라인(arm-a)에만:

    harbor run -d terminal-bench@4.0 --agent agents.masc_agent:MascAgent \
      -m anthropic/claude-fable-5 --ak arm=<winner> -k 3 \
      --agent-setup-timeout-multiplier 5 --agent-timeout-multiplier 3 \
      -o results/jobs-40 --job-name <winner>-40-$(date +%Y%m%d-%H%M%S)

- 4.0 은 타임아웃이 8시간 플랫이고 saturated 태스크를 제거했다. multiplier 3
  (45분) 유지 시 heavy 태스크는 여전히 못 끝내니, 비용을 감수하고 재려면
  multiplier 를 키운다.
- 비교 닻(Anthropic 공식, 4.0): Fable 5 42.0% / Opus 5 52.3% /
  Fable 5.1 55.8% / Mythos 5.1 60.9%. 2.0 서브셋 숫자와 직접 비교하지 않는다.

## Claude Code 구독 레인 (`claude_code/<model>`)

keeper 의 모델 런타임을 unmodified Claude Code CLI 로 쓴다 (masc protocol
`claude-code`, 프로덕션 `~/me/.masc/config/runtime.toml` 의 `[providers.claude_code]`
와 같은 구성). 도구는 masc 가 MCP 로 넣고 CLI 내장 도구는 끄므로 측정 대상은
masc 루프이고, 세션·컴팩션·로그인만 CLI 가 맡는다.

    claude setup-token                      # 호스트에서 1회, 토큰을 복사
    export CLAUDE_CODE_OAUTH_TOKEN=...
    BENCH_MODEL=claude_code/claude-sonnet-5 ./run_matrix.sh b 1
    BENCH_MODEL=claude_code/claude-opus-5   ./run_matrix.sh b 1

- effort 는 `--ak effort=high|max` 로 준다 (CLI 의 --effort; minimal 은 거부).
- bootstrap.sh 가 native 설치본을 깔고 `claude auth status --json` 이
  `oauth_token` 을 보고할 때만 서버를 띄운다. `ANTHROPIC_API_KEY` 는 필요 없다.
- 구독 5시간 창을 쓰므로 `CONCURRENCY=1` 또는 2. 한도 도달은 masc 가 CLI 의
  rate_limit 이벤트로 받아 verify 실패와 섞이지 않는다.
- 정책: OAuth 는 "ordinary use of Claude Code" 용도다
  (code.claude.com/docs/en/legal-and-compliance). 매트릭스 규모로 돌릴지는
  운영자 판단이고, 제출 런은 API 키 레인으로 남긴다.
