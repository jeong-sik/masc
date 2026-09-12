# MASC 하네스 벤치마크 설계 — Terminal-Bench 2.0 + Harbor

- 날짜: 2026-09-09
- 상태: 설계안 (구현 전 사용자 승인 대기)
- 목적: 모델이 아니라 **MASC라는 하네스 자체**가 성공률·비용·시간에 기여하는가를 수치로 판결한다.

## 1. 배경과 판결 질문

SWE-bench만으로는 "코딩 모델이 patch를 잘 만드는가"를 주로 측정하게 된다. 하네스 기여를
직접 측정하려면 Terminal-Bench 2.0 + Harbor가 1순위다. 같은 모델에서 하네스만 바꿨을 때
리더보드 점수가 크게 갈리는 사례가 이미 관측된다.

판결 질문:

1. 같은 모델·같은 reasoning effort에서 MASC가 단순 단일 에이전트 대비 성공률을 올리는가?
2. Skills / Composition / Multi-Keeper 각각이 기여하는가, 아니면 오버헤드인가? (ablation)
3. 기여가 있다면 $/task·wall-clock·토큰 관점에서 정당화되는가?
4. Terminal-Bench(범용 터미널)와 SWE-bench Verified(실제 SW 개발) 양쪽에서 재현되는가?

## 2. 핵심 외부 사실 (조사 완료)

- Harbor는 Terminal-Bench 2.0의 공식 하네스. `uv tool install harbor`로 설치.
  - 실행: `harbor run -d terminal-bench@2.0 --agent <agent> --model <provider/model>`
  - 커스텀 에이전트: `--agent path.to.agent:SomeAgent` (Python 클래스 import path)
  - `BaseInstalledAgent`: `install(environment)`에서 컨테이너 내부 설치,
    `run(instruction, environment, context)`에서 `exec_as_agent`로 실행,
    `populate_context_post_run(context)`에서 trajectory 파싱.
  - 빌트인 에이전트(terminus-2, claude-code, codex-cli, gemini-cli 등)가 있어
    **같은 모델 베이스라인을 추가 비용 없이** 돌릴 수 있다.
  - Terminal-Bench 2.0은 89개 태스크.
- 로컬 환경: Docker 28.4.0 동작 중, uv 보유. Harbor 미설치(설치 필요).
- SWE-bench Verified도 Harbor registry에서 `harbor datasets list`로 확인 가능.

## 3. MASC 측 사실 (코드 탐색 완료)

- 헤드리스 원샷 바이너리는 **없다**. 정석 경로는 MCP 서버 기동 → MCP로 keeper 에피소드 구동.
  이 플로우를 이미 구현한 레퍼런스가 `scripts/harness_coding_eval.sh`(RFC-0396)다.
  - 토큰 발급(서버 기동 전) → `masc start --port P --base-path X` → MCP initialize
  - `masc_keeper_up` → REST `POST /api/v1/keepers/tool-approval-mode {mode:"yolo"}`
  - `masc_keeper_msg {message}` → `masc_keeper_delegate_status` 폴링
    (`Succeeded|Failed|Cancelled`) → `masc_keeper_down`
  - MCP 통신 헬퍼: `scripts/harness/lib/mcp_jsonrpc.sh`
- 컨테이너화: `Dockerfile`(ubuntu:24.04 + prebuilt `masc` 바이너리) 존재.
  런타임 의존성 작음(libffi, libgmp, libsqlite3, libssl, ca-certificates, curl, jq, tini).
- 모델 핀: keeper TOML이 아니라 `runtime.toml`의 `[runtime.assignments]` /
  `masc_keeper_up`의 `runtime_id` 파라미터 + `[models.<id>] reasoning-effort`.
- ablation 노브(전부 확인됨):
  | Arm 요소 | 노브 |
  |---|---|
  | Skills off | keeper TOML `skills.names = []` |
  | Composition off | skills 제거 + `keeper_spawn*` tool policy 차단 |
  | Fusion off | `runtime.toml` `[fusion] enabled = false` |
  | Parallel tools off | `[[models]]` `supports_parallel_tool_calls = false` + `max-concurrent = 1` |
  | Keeper 수 | `masc_keeper_up` 호출 수 |
  | 자율성 억제(재현성) | `MASC_KEEPER_AUTONOMOUS_ENABLED=0`, `MASC_ORCHESTRATOR_ENABLED=0` |
- **치명적 설계 제약**: keeper의 `tool_execute`는 MASC 호스트에서 실행되지 않는다.
  호출마다 `docker run --rm` 샌드박스 컨테이너로 디스패치된다(`sandbox_profile`은
  `docker|microvm|remote_ssh` — host 프로파일 없음). Terminal-Bench는
  **태스크 컨테이너 내부 상태**를 검증하므로, 이 경계를 해결하는 것이 어댑터의 핵심이다.

## 4. 접근법 비교 (exec boundary)

### A. Installed agent + remote_ssh → localhost (추천)

Harbor `BaseInstalledAgent`로 MASC를 태스크 컨테이너 안에 설치하고, `install()`에서
openssh-server를 함께 깔아 localhost sshd를 띄운다. keeper는
`sandbox_profile = "remote_ssh"`, endpoint = `127.0.0.1`로 설정해 모든 쉘 실행이
sshd를 통해 **같은 컨테이너 안**에 떨어지게 한다.

- 장점: Terminal-Bench 검증 시맨틱과 정확히 일치(명령이 태스크 컨테이너에서 실행).
  Harbor의 어떤 특수 마운트도 요구하지 않음. `test/fixtures/sshd/Dockerfile` 선례 존재.
- 단점: 컨테이너 안에 MASC 서버 + sshd 두 프로세스 관리. 태스크 이미지가 비-Ubuntu면
  sshd 설치 분기 필요(TB2는 대부분 Ubuntu 계열).

### B. Installed agent + docker.sock 마운트 (sibling 컨테이너)

컨테이너에 `/var/run/docker.sock`을 마운트하고 keeper 샌드박스를 sibling으로 실행.

- 치명적 문제: sibling 컨테이너는 태스크 컨테이너의 파일시스템을 공유하지 않는다.
  named volume으로 workspace를 공유하는 우회가 필요한데, Harbor 태스크의 검증 스크립트가
  컨테이너 임의 경로를 검사하므로 시맨틱이 깨진다. **기각.**

### C. External agent (호스트에서 구동)

`BaseAgent`로 MASC를 Harbor 호스트에서 띄우고 `environment.exec` 경유.

- 장점: MASC 설치가 한 번이면 됨.
- 단점: MASC의 tool_execute가 `environment.exec`를 타지 않는다. MASC 내부 샌드박스
  디스패치를 Harbor 환경 exec으로 연결하는 브리지가 필요해 MASC 측 수정이 커진다.
  하네스를 "있는 그대로" 벤치한다는 실험 순수성도 훼손. **기각** (단, A가 막히면 재검토).

**결정: A.** MASC는 무수정, 어댑터는 Harbor 측 Python 클래스 하나 + 컨테이너 내 부트스트랩
스크립트로 닫힌다.

## 5. 어댑터 설계 (Approach A 상세)

디렉터리: `benchmarks/terminal_bench/` (신규, repo 내)

```
benchmarks/terminal_bench/
├── agents/
│   └── masc_agent.py        # BaseInstalledAgent 구현
├── image/
│   ├── Dockerfile.masc-agent  # ubuntu:24.04 + masc 바이너리 + sshd + config seed
│   └── bootstrap.sh           # 컨테이너 내: sshd 기동 → masc start → 토큰 → keeper_up
├── configs/                   # arm별 runtime.toml / keeper TOML 템플릿
│   ├── arm-a-simple/ ... arm-h-full/
├── suite/
│   ├── mini-suite.txt         # 선정 태스크 id 24개
│   └── SELECTION.md           # 선정 기준
└── results/                   # run 산출물 (gitignore 대상, 요약만 커밋)
```

`masc_agent.py` 동작:

1. `install()`: prebuilt `masc` 바이너리 복사, openssh-server 설치·기동,
   `masc init`으로 config seed, arm별 `runtime.toml`/keeper TOML 배치,
   `MASC_KEEPER_AUTONOMOUS_ENABLED=0` 등 환경 고정.
2. `run(instruction)`: `masc start` 백그라운드 기동 → (기동 전 발급된) admin 토큰으로
   MCP initialize → arm 수만큼 `masc_keeper_up`(runtime_id로 모델 핀) →
   `tool-approval-mode=yolo` → multi-keeper arm이면 태스크 분배 지시를 lead keeper에게
   전달, 단일 arm이면 `masc_keeper_msg`로 instruction 직접 전달 →
   `masc_keeper_delegate_status` 폴링(터미널 상태까지) → 종료.
   내부 구현은 `scripts/harness_coding_eval.sh`와 `scripts/harness/lib/mcp_jsonrpc.sh`의
   bash 로직을 Python으로 이식.
3. `populate_context_post_run()`: MASC 로그/이벤트에서 토큰·툴콜·턴 수를 긁어
   `AgentContext`에 기록. Harbor 자체 메트릭(wall-clock, 비용)과 병행.

태스크 타임아웃: Harbor task.toml의 기본 agent timeout을 그대로 사용(arm 간 동일).

## 6. 실험 설계

### 6.1 공정성 불변식 (모든 arm 공통)

- 같은 모델, 같은 reasoning effort, 같은 태스크 세트, 같은 타임아웃, 같은 n-attempts.
- 모델은 실험 시작 시점에 1개로 고정(예: `anthropic/claude-*` 또는
  `openai-compatible` 계열 — Phase 0에서 API 가용성 확인 후 결정).
- MASC의 자율 루프·오케스트레이터는 전 arm에서 억제(재현성). 측정 대상은
  "태스크 해결 루프"이지 방치형 자율성이 아니다.

### 6.2 Arms (ablation)

| Arm | 구성 | 노브 |
|---|---|---|
| A | Simple baseline | Harbor 빌트인 `terminus-2`, 같은 모델 |
| B | MASC 1 keeper | skills 없음, fusion off, spawn 차단 |
| C | B + Skills | keeper TOML `skills.names` 기본값 |
| D | C + Composition | spawn/composition tool 허용 |
| E | D + parallel/batch | `supports_parallel_tool_calls=true`, `max-concurrent` 기본 |
| F | E를 4 keeper | keeper 4개, lead가 분배 |
| G | E를 8 keeper | keeper 8개 |
| H | MASC Full | fusion on 포함 전부 |

참조 베이스라인(주 판결 아님, 위치 확인용): claude-code / codex-cli 같은 모델.

### 6.3 메트릭 (run·task 단위)

success(verify pass), wall-clock, input/output/cached tokens, LLM turns, tool calls,
중복 tool calls(같은 tool·입력 반복), $/task(토큰 단가표로 환산), human intervention(0이어야 함),
infrastructure failure(MASC crash, sshd 사망 등 — 실패와 구분 기록).

### 6.4 Phase 계획

- **Phase 0 — 스모크**: 태스크 1개(`gpt2-codegolf` 등)로 arm B 파이프라인 종단 검증.
  Harbor CLI 플래그(`--n-attempts`, 태스크 필터)를 `harbor run --help`로 확정.
- **Phase 1 — mini-suite**: 89개 중 24개를 계층 선정(카테고리·난이도 분포 유지,
  기준은 `suite/SELECTION.md`에 기록) × 3 attempts × arms {A, B, C, E, F, H}
  (D, G는 Phase 1 결과가 유망할 때만).
- **Phase 2 — 확대**: 차이가 보이는 arm만 89개 × 5 attempts.
- **Phase 3 — SWE-bench Verified**: 동일 arm 구성으로 50개 서브셋부터.

### 6.5 판결 규칙 (사전 선언)

- "유효"의 정의: mini-suite에서 성공률 차이가 반복 간 변동(±표준오차)을 넘을 것.
- MASC Full이 Simple 대비 성공률 같거나 낮고 $/task가 높으면 하네스 가치 부정.
- 개별 노브(Skills 등)는 켰을 때 성공률·비용 모두 악화면 "무가치" 판정.
- 판결은 숫자로, 어느 쪽이든 결과를 그대로 기록한다.

## 7. 리스크

1. **sshd/네트워크**: TB2 태스크 중 네트워크 차단 태스크는 agent 설치 후 네트워크가
   막힐 수 있음 → `install()` 시점에 모든 설치 완료, LLM API 접근은 태스크가 허용하는
   범위 확인(막힌 태스크는 모든 arm이 동등하게 실패하므로 공정성은 유지, 샘플에서 제외 검토).
2. **parallel-tool 억제 플래그**: constitution parity B4 기준 flag-only일 수 있음 →
   Phase 0에서 provider별 동작 실측 후 arm E 해석에 반영.
3. **zero-operator 안정성**: `always_allow`+`yolo` 조합은 coding-eval에서 실증됐으나
   TB2 태스크의 장기 실행에서 keeper 턴 교착 가능 → 폴링에 하드 타임아웃 + 상태 덤프.
4. **비용**: Phase 1 = 24 tasks × 3 × 6 arms ≈ 432 runs. subscription 플랜 rate limit
   내에서 `--n-concurrent` 조절.

## 8. 범위 밖 (YAGNI)

- MASC 코드 수정 (어댑터는 repo에 추가되지만 MASC 런타임은 무수정).
- RL/SFT 데이터 생성, 클라우드 provider(Daytona/Modal) 스케일아웃.
- 다중 모델 매트릭스(모델 1개 고정이 원칙).
