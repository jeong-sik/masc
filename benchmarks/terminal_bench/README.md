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
  `BENCH_MODEL=openrouter/z-ai/glm-4.7-flash ./run_matrix.sh b,c,e 3` 처럼 쓴다.
  와이어 id 의 슬래시는 runtime.toml 의 model id 로 못 쓴다(`[A-Za-z0-9._-]+`).
  렌더러가 바인딩을 슬러그로 만들고 와이어 이름을 `api-name` 에 넣으므로,
  masc 가 해소하는 runtime id 는 `openrouter.z-ai-glm-4.7-flash` 다.
  2026-09-12 실측: `runtime-verify` verified (response·tool_called·tool_roundtrip).
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

## arm K — Keeper 를 도구로 부리는 레인

앞의 레인들은 masc 가 태스크를 푼다. arm K 는 반대다. 태스크는 harbor 의
`claude-code` 에이전트가 그대로 풀고, 같은 컨테이너에서 도는 masc 서버를 MCP
서버로 물려 준다. 모델은 `masc_keeper_up` 으로 키퍼를 세우고 `masc_keeper_msg`
로 일을 주고 `masc_board_post` / `masc_add_task` 로 공유 맥락을 쓴다. 키퍼의
쉘은 `remote_ssh` 로 같은 컨테이너에 떨어지므로 검증기가 보는 자리에 결과가
남는다.

베이스라인은 `--agent claude-code` 에 같은 모델, MCP 서버 없음이다. 이건 이미
리더보드에 있는 구성이라 외부 닻이 있고, 두 arm 사이의 유일한 차이가 키퍼
계층이다. 그래서 차이가 나면 하네스가 아니라 다중 에이전트 계층에 귀속된다.

    export ANTHROPIC_API_KEY=...        # 키퍼가 쓸 모델
    harbor run -d terminal-bench/terminal-bench@4.0.0 -i <task> \
      --agent agents.keeper_tools_agent:KeeperToolsAgent \
      -m anthropic/claude-sonnet-5 -k 1 -n 1 -o results/jobs-40

    # 베이스라인 (같은 모델, 키퍼 없음)
    harbor run -d terminal-bench/terminal-bench@4.0.0 -i <task> \
      --agent claude-code -m anthropic/claude-sonnet-5 -k 1 -n 1 -o results/jobs-40

- `--ak keeper_runtime_id=claude_code.claude-sonnet-5` 로 키퍼도 구독 CLI 를
  쓰게 할 수 있다. 그러면 위 레인과 합쳐져 API 키가 아예 필요 없다.
- `--ak announce_pool=false` 면 시스템 프롬프트에 키퍼 안내를 넣지 않는다.
  도구만 두고 모델이 스스로 발견하는지 재는 변형이다.
- 키퍼 4개(`bench-1`..`bench-4`)의 프로필만 렌더하고 아무것도 미리 띄우지
  않는다. 몇 개를 쓸지는 모델이 정한다.
- 채팅 승인 스탠스(`Keeper_tool_approval_mode`)는 메모리에만 있고 REST 로만
  바뀌며 설정 기본값이 없다. MCP 클라이언트는 REST 에 못 닿으므로 bootstrap 이
  풀 이름마다 미리 `yolo` 를 걸어 둔다. 안 그러면 키퍼가 채팅으로 승인을
  물으며 멈춘다.

## 베이스 이미지 이식성 확인

    ./image/probe_bases.sh                  # 4.0 세트의 서로 다른 베이스들
    ./image/probe_bases.sh python:3.13-slim # 특정 이미지만

`driver/deps.sh` 를 태스크 베이스 이미지에서 그대로 돌려 masc 가 실행되는지와
sshd 가 있는지만 본다. API 키도 태스크도 서버도 필요 없다. 2026-09-11 매트릭스가
arm 당 72 trial 중 36개를 LLM 토큰 한 개 쓰기 전에 잃은 게 `libssl3t64` 한 줄
때문이었고, 이 프로브가 그걸 공짜로 잡는다.

`libssl3t64` 는 ubuntu 24.04 에만 있다. 4.0 의 66 태스크 중 24.04 는 14개뿐이고
python:*-slim(debian) 이 30개가 넘는다. deps.sh 는 이제 패키지 매니저 계열
(apt/dnf/apk)을 감지하고, 런타임 라이브러리는 `masc --version` 이 실패할 때만
설치하며, 안 되면 배포판 이름과 빠진 라이브러리를 찍고 죽는다. `gh` 는 debian
stable 에 패키지가 없는데 keeper_up preflight 가 요구하므로 `dist/` 에 실어
보낸다 (`image/fetch_masc.sh` 가 같이 받는다).

### arm K 실측 (2026-09-12)

`image/probe_keeper_tools.sh` 를 ubuntu:24.04 + `openrouter.z-ai/glm-4.7-flash` 로
돌린 결과. harbor 없이 컨테이너 하나에서 arm K 의 기계적 경로 전체를 확인한다.

    keeper pool up: bench-1
    MASC server ready
    PROBE_OK marker=/tmp/arm-k-keeper-was-here written by the keeper
       argv: ['touch', '/tmp/arm-k-keeper-was-here']
       exit: {'kind': 'exit', 'code': 0} | via: remote_ssh | host: 127.0.0.1
             | boundary: sandbox_applied

즉 MCP 로 키퍼를 세우고, 메시지를 주고, 모델이 턴을 돌려, 도구 호출이 **태스크
컨테이너 안에서** 실행된다. 검증기가 보는 자리다.

증인은 argv 하나로 만들 수 있어야 한다. `Execute` 는 argv 리스트를 셸 없이
실행하므로 `printf x > /tmp/marker` 를 시키면 `>` 가 printf 의 리터럴 인자가 되어
exit 0 으로 끝나고 파일은 안 생긴다. masc 는 이걸 정확히 보고한다(출력에 printf
자신의 경고가 실린다). 도구가 아니라 지시가 틀린 것이다.
