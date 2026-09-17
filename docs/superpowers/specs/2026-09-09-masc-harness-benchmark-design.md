# MASC 하네스 벤치마크 설계 — Terminal-Bench 4.x + Harbor

- 목적: 모델이 아니라 **MASC 라는 하네스 자체**가 성공률·비용·시간에 기여하는가를 수치로 판결한다.
- 실행 안내: `benchmarks/terminal_bench/README.md`

## 1. 판결 질문

1. 같은 모델·같은 reasoning effort 에서 MASC 가 그 제공자의 기본 에이전트보다 성공률을 올리는가?
2. Skills / Composition / Parallel / Multi-Keeper / Fusion 각각이 기여하는가, 오버헤드인가? (ablation)
3. 기여가 있다면 $/task·wall-clock·토큰으로 정당화되는가?

## 2. Terminal-Bench 4.0.0 사실 (2026-09-17 확인)

- 데이터셋: `terminal-bench/terminal-bench@4.0.0`, 66 태스크. 태스크 이름은
  `terminal-bench/<task>` 이고 harbor 의 `-i`/`-x` 는 이 이름으로 매칭한다.
- 에이전트 타임아웃: 66개 전부 28800s. 검증은 전부 `environment_mode = "separate"` —
  에이전트 환경을 멈춘 뒤 새 컨테이너에서, 선언된 `artifacts` 만 넘겨받아 검증한다.
- 태스크마다 미리 빌드된 amd64 전용 이미지(`[environment] docker_image`, digest 고정)를 쓴다.
  Apple Silicon 에서는 에뮬레이션으로 돈다.
- 자원: CPU 2–16, 메모리 4096–32768 MiB. GPU(H100) 요구 태스크 3개.
- 태스크별 선언: `mcp_servers`(비어 있지 않은 것 1개), `skills_dir` 1개, `healthcheck` 1개,
  docker-compose 11개.
- 공식 실행 예시(terminal-bench README): `-k 5`, `--env modal`.

## 3. 실행 경계 — 접근법

keeper 의 도구 실행은 MASC 호스트가 아니라 샌드박스 프로파일(`docker|microvm|remote_ssh`)로
나간다. Terminal-Bench 는 **태스크 컨테이너 내부 상태**를 검증하므로 이 경계가 어댑터의 핵심이다.

### A. Installed agent + remote_ssh → localhost (채택)

harbor `BaseInstalledAgent` 로 MASC 를 태스크 컨테이너 안에 설치하고, sshd 를 띄워 keeper 의
`remote_ssh` 엔드포인트를 `127.0.0.1` 로 둔다. 모든 쉘 실행이 같은 컨테이너에 떨어진다.

- 장점: 검증 시맨틱과 일치한다. harbor 의 특수 마운트가 필요 없다.
- 단점: 컨테이너 안에 MASC 서버와 sshd 두 프로세스가 돈다. 태스크 베이스 이미지 배포판마다
  의존성 설치가 달라진다(`driver/deps.sh`).

### B. docker.sock 마운트 (기각)

sibling 컨테이너는 태스크 컨테이너 파일시스템을 공유하지 않는다. 검증 시맨틱이 깨진다.

### C. External agent (기각)

MASC 의 도구 실행이 harbor `environment.exec` 를 타지 않아 브리지가 필요하고, 하네스를
있는 그대로 재는 순수성을 해친다.

## 4. 어댑터

```
benchmarks/terminal_bench/
├── agents/masc_agent.py      # arm b–h: BaseInstalledAgent
├── agents/masc_dist.py       # 컨테이너 uname -m → dist/linux-{x64,arm64}
├── agents/keeper_tools_*.py  # arm K: claude-code / opencode + masc 사이드카
├── configs/render_configs.py # arm 별 runtime.toml / keeper TOML
├── driver/bootstrap.sh       # 의존성, sshd, 토큰, masc start
├── driver/run_episode.sh     # keeper_up → keeper_msg → 상태 폴링
├── driver/collect_result.sh  # keeper 정지 대기, result.json
├── image/fetch_masc.sh       # 릴리스 바이너리 두 아키텍처
├── dataset_plan.py           # 실행 전 GPU·자원 판정
├── run_matrix.sh             # arm × 4.0.0 전체
└── aggregate.py              # jobs → CSV
```

- `install()`: 컨테이너 아키텍처에 맞는 바이너리·드라이버·렌더된 config 를 올리고
  `bootstrap.sh` 를 root 로 돌린다. 상한은 harbor 설치 타임아웃이다.
- `run()`: `run_episode.sh` 가 delegate 가 끝난 상태(`Succeeded|Failed|Cancelled`)가 될 때까지
  폴링한다. 자체 마감은 없다. harbor 가 타임아웃으로 `run()` 을 취소하면
  `collect_result.sh --interrupted` 가 keeper 를 멈추고 그 순간을 기록한다.
- `populate_context_post_run()`: `result.json` 의 토큰·도구 호출·상태를 `AgentContext` 에 싣는다.

## 5. 실험 설계

### 5.1 공정성 불변식

- 같은 모델, 같은 reasoning effort, 같은 태스크 세트, 같은 타임아웃(태스크 선언 그대로),
  같은 attempts.
- MASC 의 자율 루프·오케스트레이터는 모든 arm 에서 끈다.
- 태스크가 선언한 자원을 실행 환경이 줄 수 있어야 한다. 못 주면 돌리지 않는다(`dataset_plan.py`).

### 5.2 Arms

| Arm | 구성 |
|---|---|
| A | 같은 모델, 그 제공자의 harbor 기본 에이전트 |
| B | MASC keeper 1, skills·composition·parallel·fusion 끔 |
| C | B + Skills |
| D | C + Composition |
| E | D + parallel tool calls |
| F | E 를 keeper 4 로 |
| G | E 를 keeper 8 로 |
| H | G + Fusion |
| K | 기본 에이전트가 keeper 풀을 MCP 도구로 쓴다 (기준선: 같은 에이전트, MCP 없음) |

### 5.3 메트릭

reward(검증 통과), wall-clock, input/output/cache 토큰, $/task(litellm 단가), 도구 호출,
중복 도구 호출, 인프라 실패(설치·서버·sshd — 에이전트 실패와 구분),
`interrupted`(타임아웃으로 끊겼는지), `keepers_stopped`.

### 5.4 실행 순서

1. **스모크**: 태스크 1개, arm B.
2. **확인런**: 4.0.0 전체 × arm A, B × k=1. 인프라 실패율과 비용을 먼저 본다.
3. **본런**: 4.0.0 전체 × arms A, B, C, E, F, H × k=5. D, G 는 본런 결과가 유망할 때만.

### 5.5 판결 규칙 (사전 선언)

- "유효" 는 성공률 차이가 반복 간 변동(±표준오차)을 넘을 때만.
- MASC 가 arm A 대비 성공률이 같거나 낮고 $/task 가 높으면 하네스 가치 부정.
- 개별 노브는 켰을 때 성공률·비용이 모두 나빠지면 "무가치".
- 판결은 숫자로, 결과를 그대로 기록한다.

## 6. 리스크

1. **실행 환경 차이**: keeper 명령은 이미지가 선언한 PATH·환경변수를 보지 못한다(#36907).
   harbor 기본 에이전트는 보므로 arm A 대비 불리하다. 해결 전 결과에는 이 한계를 적는다.
2. **태스크 선언 도구**: `mcp_servers`·`skills_dir` 를 keeper 에 연결하지 않는다(#36908).
3. **GPU·자원·에뮬레이션**: 로컬 docker 는 GPU 3태스크를 못 돌리고, 16 CPU 태스크 때문에
   사실상 동시 실행 1이다. Apple Silicon 에서는 amd64 이미지가 에뮬레이션으로 돌아 시간 조건이
   달라진다. 리더보드와 비교할 전체 세트는 GPU 를 주는 amd64 환경이 필요하다.
4. **네트워크**: 검증 환경에서 인터넷을 막는 태스크가 있다. 에이전트 단계의 LLM API 접근은
   태스크 설정을 따른다.

## 7. 범위 밖

- RL/SFT 데이터 생성.
- 다중 모델 매트릭스(실험 한 번에 모델 1개).
