# MASC × Terminal-Bench 4.x (Harbor)

MASC 하네스 자체를 Terminal-Bench 4.0.0 전체로 잰다.
설계: `docs/superpowers/specs/2026-09-09-masc-harness-benchmark-design.md`

재는 것은 keeper 가 태스크 컨테이너 안에서 일을 끝내는 경로다.
`masc start` → `masc_keeper_up` → `masc_keeper_msg` → keeper 턴 루프 →
`remote_ssh` 로 같은 컨테이너에 떨어지는 도구 실행. 자율 루프와 오케스트레이터는 끈다.
점수를 MASC 몫으로 읽으려면 같은 모델의 harbor 기본 에이전트(arm A)와 나란히 본다.

## 준비

    ./image/fetch_masc.sh                         # 최신 릴리스, linux-x64 와 linux-arm64 둘 다
    uv venv -p 3.12 && uv pip install -r requirements.txt   # harbor 0.23.0 고정
    export ANTHROPIC_API_KEY=...                  # 모델 제공자 키 (아래 레인 표)

- Harbor hub 의 4.0.0 태스크는 태스크마다 미리 빌드된 이미지(`docker_image`)를 쓰고, 그
  이미지는 amd64 전용이다(2026-09-17 registry 조회, 66개 중 65개 확인). Apple Silicon
  에서는 전부 에뮬레이션으로 돈다. 에이전트는 컨테이너마다 `uname -m` 을 읽어
  `dist/linux-x64` 나 `dist/linux-arm64` 를 올린다.
- 에뮬레이션은 CPU 를 많이 쓰는 태스크를 느리게 만든다. 8시간 제한 안에서 걸리는 시간이
  네이티브 amd64 환경과 달라지므로, 리더보드와 비교할 실행은 amd64 환경(`BENCH_ENV=modal`)
  에서 돌린다.
- `GH_TOKEN` 은 선택이다. 주면 keeper 가 GitHub 로그인을 갖고 `gh` 도 같이 올라간다.
  주지 않으면 remote_ssh 사전 점검이 신원 확인을 건너뛴다(v0.35.15+, #35488).
  주면 전체 실행의 모든 태스크 컨테이너에 그 토큰이 들어간다.

## 한 태스크 스모크

태스크 이름은 `terminal-bench/<task>` 전체로 준다. 짧은 이름은 매칭되지 않는다.

    harbor run -d terminal-bench/terminal-bench@4.0.0 \
      -i terminal-bench/embedding-drift-monitor \
      --agent agents.masc_agent:MascAgent -m anthropic/claude-fable-5 \
      --ak arm=b -k 1 -n 1 --agent-setup-timeout-multiplier 5 -o results/jobs

## 전체 실행

    ./run_matrix.sh                  # arms a,b,c,e,f,h × 4.0.0 전체 × k=5, BENCH_ENV=docker
    BENCH_ENV=modal ./run_matrix.sh  # 샌드박스를 태스크마다 맞춰 만드는 환경
    python aggregate.py results/jobs # → CSV

`run_matrix.sh` 는 데이터셋을 받아(`results/datasets/`, 끝까지 받았을 때만 `.complete`)
`dataset_plan.py` 로 먼저 판정한다.

- GPU 태스크(`fp8-rmsnorm-gemm`, `jax-speedrun-gpu`, `math-eval-grader`, H100 요구)는
  docker 에서 `-x` 로 뺀다. harbor 는 GPU 를 줄 수 없는 환경에서 이 trial 을 만들다가
  예외를 던지고, 그 자리가 trial 단위 에러 처리 밖이라 job 전체가 멈춘다.
  뺐을 때는 "전체 세트가 아니다" 라고 출력한다.
- 태스크가 선언한 CPU·메모리(에이전트·검증 환경 중 큰 쪽)를 Docker 데몬이 줄 수 없으면
  시작 전에 이름과 숫자를 대고 거부한다. `CONCURRENCY` 만큼 큰 태스크가 동시에 도는
  경우도 같이 본다.

로컬 docker 로 GPU 가 아닌 63개를 다 돌리려면 Docker Desktop 에 CPU 16개 이상,
`docker info` 의 `MemTotal` 이 16384 MiB 이상이 되게 메모리를 줘야 한다. Docker
Desktop 에 16 GiB 를 줘도 `MemTotal` 은 15972 MiB 로 보고된다(2026-09-17 실측).
동시 실행 수를 올리면 필요한 양도 같이 커진다.

### 타임아웃

- 4.0.0 은 66 태스크 전부 에이전트 타임아웃이 28800s(8시간)다. `--agent-timeout-multiplier`
  를 주지 않는다.
- 에피소드에는 자체 마감이 없다. harbor 는 설치형 에이전트에게 타임아웃 값을 알려 주지
  않고, 시간이 다 되면 `run()` 을 취소한다. 그때 `MascAgent` 가
  `driver/collect_result.sh --interrupted` 를 실행한다.
  - 남아 있는 `run_episode.sh` 를 끝낸다.
  - keeper 를 내리고 실제로 없어질 때까지 기다린다. harbor 는 에이전트 환경이 켜진 채로
    artifact 를 내려받기 때문이다.
  - 그 순간의 delegate 상태와 토큰·도구 호출 수를 `result.json` 에 쓴다
    (`interrupted: true`, `keepers_stopped`).
- claude_code 레인은 `turn-timeout-s = 0`(무응답 제한 없음),
  `wall-clock-ceiling-s = 28800.0` 으로 렌더한다. 런타임 기본 턴 상한은 14400s 다.
- `--agent-setup-timeout-multiplier 5` 는 설치 단계용이다. harbor 기본 설치 타임아웃은
  360s 이고 에이전트 작업 시간에 들어가지 않는다.

## arm

| arm | 구성 |
|---|---|
| a | 같은 모델, harbor 기본 에이전트 (anthropic → `claude-code`, kimi_coding → `kimi-cli`) |
| b | keeper 1, skills·composition·parallel·fusion 끔 |
| c | b + skills |
| d | c + composition (spawn 도구) |
| e | d + parallel tool calls |
| f | e 를 keeper 4 로 |
| g | e 를 keeper 8 로 |
| h | g + fusion |
| k | harbor `claude-code`/`opencode` 가 풀고, keeper 풀을 MCP 도구로 받는다 (아래) |

spawn 도구는 parallel 이 꺼진 arm(b, c, d)에서, delegate 도구는 keeper 1 인 arm(b–e)에서
keeper TOML `tools.deny` 로 막는다.

## 모델 레인

`-m <masc provider>/<model>` 이 runtime id `<provider>.<model>` 이 된다.

| provider | 키 | 비고 |
|---|---|---|
| `anthropic` | `ANTHROPIC_API_KEY` | 이 호스트는 `ANTHROPIC_API_KEY` 가 무효라 `ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY_MASC"` 로 넘긴다 |
| `openrouter` | `OPENROUTER_API_KEY` | 와이어 id 의 슬래시는 runtime.toml model id 로 못 쓴다. 렌더러가 바인딩을 슬러그로 만든다(`openrouter/z-ai/glm-4.7-flash` → `openrouter.z-ai-glm-4.7-flash`) |
| `kimi_coding` | `KIMI_API_KEY` | arm A 의 kimi-cli 에는 `kimi/<model>` 로 넘어간다 |
| `openai` | `OPENAI_API_KEY` | 2026-09-10 기준 키에 크레딧이 없어 요청 생성 이후는 확인하지 못했다 |
| `claude_code` | `CLAUDE_CODE_OAUTH_TOKEN` | 아래 구독 레인 |

## Claude Code 구독 레인 (`claude_code/<model>`)

keeper 의 모델 런타임을 수정하지 않은 Claude Code CLI 로 쓴다(masc protocol
`claude-code`). 도구는 masc 가 MCP 로 넣고 CLI 내장 도구는 끄므로 측정 대상은 masc
루프이고, 세션·컴팩션·로그인만 CLI 가 맡는다.

    claude setup-token                      # 호스트에서 1회, 토큰을 복사
    export CLAUDE_CODE_OAUTH_TOKEN=...
    BENCH_MODEL=claude_code/claude-sonnet-5 CONCURRENCY=1 ./run_matrix.sh b 1

- effort 는 `--ak effort=high|max` 로 준다(CLI 의 --effort; minimal 은 거부).
- bootstrap.sh 가 native 설치본을 깔고 `claude auth status --json` 이 `oauth_token` 을
  보고할 때만 서버를 띄운다.
- 구독 5시간 창을 쓰므로 `CONCURRENCY=1` 또는 2. 한도 도달은 masc 가 CLI 의
  rate_limit 이벤트로 받아 검증 실패와 섞이지 않는다.
- 정책: OAuth 는 "ordinary use of Claude Code" 용도다
  (code.claude.com/docs/en/legal-and-compliance). 매트릭스 규모로 돌릴지는 운영자
  판단이고, 제출 런은 API 키 레인으로 남긴다.

## arm K — keeper 를 도구로 부리는 레인

태스크는 harbor 의 `claude-code` 에이전트가 그대로 풀고, 같은 컨테이너에서 도는 masc
서버를 MCP 서버로 물려 준다. 모델은 `masc_keeper_up` 으로 keeper 를 세우고
`masc_keeper_msg` 로 일을 주고 `masc_board_post` / `masc_add_task` 로 공유 맥락을 쓴다.
keeper 의 쉘은 `remote_ssh` 로 같은 컨테이너에 떨어지므로 검증기가 보는 자리에 결과가 남는다.

기준선은 `--agent claude-code` 에 같은 모델, MCP 서버 없음이다. 두 arm 사이의 차이는
keeper 계층 하나다.

    harbor run -d terminal-bench/terminal-bench@4.0.0 -i terminal-bench/<task> \
      --agent agents.keeper_tools_agent:KeeperToolsAgent \
      -m anthropic/claude-sonnet-5 -k 1 -n 1 -o results/jobs

    harbor run -d terminal-bench/terminal-bench@4.0.0 -i terminal-bench/<task> \
      --agent claude-code -m anthropic/claude-sonnet-5 -k 1 -n 1 -o results/jobs

- `--ak keeper_runtime_id=claude_code.claude-sonnet-5` 로 keeper 도 구독 CLI 를 쓰게 할 수 있다.
- `--ak announce_pool=false` 면 시스템 프롬프트에 keeper 안내를 넣지 않는다. 도구만 두고
  모델이 스스로 발견하는지 재는 변형이다.
- keeper 4개(`bench-1`..`bench-4`)의 프로필을 렌더하고 bootstrap 이 풀을 세운다.
- 채팅 승인 스탠스(`Keeper_tool_approval_mode`)는 메모리에만 있고 REST 로만 바뀐다.
  MCP 클라이언트는 REST 에 못 닿으므로 bootstrap 이 풀 이름마다 미리 `yolo` 를 건다.
  안 그러면 keeper 가 채팅으로 승인을 물으며 멈춘다.

### arm K 기계 경로 확인 (2026-09-12)

`image/probe_keeper_tools.sh` 를 ubuntu:24.04 + `openrouter.z-ai/glm-4.7-flash` 로 돌린 결과.
harbor 없이 컨테이너 하나에서 arm K 의 기계 경로 전체를 확인한다.

    keeper pool up: bench-1
    MASC server ready
    PROBE_OK marker=/tmp/arm-k-keeper-was-here written by the keeper
       argv: ['touch', '/tmp/arm-k-keeper-was-here']
       exit: {'kind': 'exit', 'code': 0} | via: remote_ssh | host: 127.0.0.1
             | boundary: sandbox_applied

증인은 argv 하나로 만들 수 있어야 한다. `Execute` 는 argv 리스트를 셸 없이 실행하므로
`printf x > /tmp/marker` 를 시키면 `>` 가 printf 의 리터럴 인자가 되어 exit 0 으로 끝나고
파일은 안 생긴다.

## 베이스 이미지 확인

    ./image/probe_bases.sh                  # 4.0.0 세트의 서로 다른 베이스들
    ./image/probe_bases.sh python:3.13-slim # 특정 이미지만

`driver/deps.sh` 를 태스크 베이스 이미지에서 그대로 돌려 masc 가 실행되는지와 sshd 가
있는지만 본다. API 키도 태스크도 서버도 필요 없다. 플랫폼은 harbor 와 같이
`DOCKER_DEFAULT_PLATFORM`, 없으면 Docker 데몬 것을 쓴다.

deps.sh 는 패키지 매니저 계열(apt/dnf/apk)을 감지하고, 런타임 라이브러리는
`masc --version` 이 실패할 때만 설치하며, 안 되면 배포판 이름과 이유(아키텍처·glibc·
라이브러리)를 찍고 끝난다. 릴리스 바이너리의 glibc 바닥값은 2.35 다
(`scripts/check-glibc-floor.sh`, v0.35.19 실측).

## 4.0.0 에서 아직 맞지 않는 조건

- keeper 명령은 태스크 이미지가 선언한 `PATH`·환경변수를 보지 못한다. `masc-exec-shim`
  이 PATH 를 `/usr/local/bin:/usr/bin:/bin` 로 고정한다. 21/66 태스크가 PATH 디렉터리를
  잃는다 — #36907
- 태스크가 선언한 `mcp_servers`(medical-claims-processing)와 `skills_dir`
  (cumulative-layout-shift)를 keeper 에 연결하지 않는다 — #36908
- GPU 태스크 3개는 GPU 를 주는 환경(`BENCH_ENV=modal`)에서만 돈다. 이 호스트에는 Modal
  자격 증명이 없다.

비교 기준점은 Terminal-Bench 리더보드
(`hub.harborframework.com/datasets/terminal-bench/terminal-bench/latest?tab=leaderboard`)에서 본다.
