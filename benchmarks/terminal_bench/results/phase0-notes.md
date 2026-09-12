# Phase 0 — Harbor 실측 스모크 결과 (gpt2-codegolf, kimi-for-coding)

날짜: 2026-09-10. 호스트: macOS arm64, Docker Desktop(amd64 컨테이너는 에뮬레이션).
Harbor 0.22.0 (`benchmarks/terminal_bench/.venv`), 태스크 이미지 `alexgshaw/gpt2-codegolf:20251031` (linux/amd64).

## arm A 베이스라인 — **kimi-cli로 대체** (terminus-2 불가 판정)

계획상 arm A는 terminus-2 + 같은 모델(kimi-for-coding, https://api.kimi.com/coding/v1)이었다.
terminus-2 연결 자체는 성공했으나 실측 3회 시도 끝에 불가 판정:

1. attempt 1/2: 컨테이너 내 tmux/asciinema apt 설치가 terminus-2의 하드코딩된
   120s exec 예산(`tmux_session.py:_TOOL_INSTALL_TIMEOUT_SEC`)을 초과.
   에뮬레이션 환경에서 `apt-get install tmux` 단독 측정 약 121s.
   attempt 3은 `record_terminal_session=false`(asciinema 스킵)로 설치 통과.
2. attempt 3: 15 step / 29분 실제 LLM 턴 후
   `litellm.BadRequestError: the message at position 27 with role 'assistant' must not be empty`.
   kimi-for-coding은 reasoning-only 응답(visible content 빈 문자열)을 반환하고,
   terminus-2는 빈 assistant 메시지를 히스토리에 그대로 쌓아 코딩 엔드포인트가 400으로 거부.
   trajectory 전 step `model_response=''` (reasoning 필드만 존재).
   bench 측에서 수정 불가(harbor 낮은 코드) → **terminus-2를 포기하고 kimi-cli를 arm A로 채택**.
   - 증거: `results/jobs/phase0-arm-a-attempt3-terminus2/gpt2-codegolf__n6ccJ8G/{exception.txt,agent/trajectory.json}`

**arm A가 측정하는 것이 바뀐다**: "terminus-2 하네스 vs MASC"가 아니라
"kimi-cli 하네스(동일 모델, Moonshot 레퍼런스 CLI) vs MASC"다.

### arm A 성공 커맨드 (kimi-cli)

```bash
uv run harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
  --agent kimi-cli -m kimi/kimi-for-coding \
  --agent-setup-timeout-multiplier 5 --agent-timeout-multiplier 3 \
  -k 1 -n 1 -o results/jobs --job-name phase0-arm-a
```

- 결과: **reward 1.0** (PASS), 에이전트 실행 44m35s, 설치 1m29s, 잡 전체 48m42s
- 토큰: input 2,163,698 (cached 2,090,240), output 59,375
- 산출물: `results/jobs/phase0-arm-a/gpt2-codegolf__5PFEpjS/`
- 참고: kimi-cli 에이전트는 harbor가 컨테이너에 kimi CLI를 설치하고
  `KIMI_API_KEY` env로 `https://api.kimi.com/coding/v1`에 접속한다
  (`harbor/agents/installed/kimi_cli.py:_PROVIDER_CONFIG["kimi"]`).

### terminus-2 시도 커맨드 (기록용, 실패)

```bash
OPENAI_API_KEY="$KIMI_API_KEY" uv run harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
  --agent terminus-2 -m openai/kimi-for-coding \
  --ak api_base=https://api.kimi.com/coding/v1 --ak record_terminal_session=false \
  --agent-setup-timeout-multiplier 5 --agent-timeout-multiplier 3 \
  -k 1 -n 1 -o results/jobs --job-name phase0-arm-a
```

litellm에 `kimi/` 프로바이더가 없어 `openai/` 프리픽스 + api_base + OPENAI_API_KEY
우회가 필요했다(엔드포인트 도달 자체는 이 조합으로 성공).

## arm B — MASC (agents.masc_agent:MascAgent, arm=b, runtime kimi_coding.kimi-for-coding)

```bash
export GH_TOKEN="$(gh auth token)"
uv run harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
  --agent agents.masc_agent:MascAgent -m kimi/kimi-for-coding \
  --ak arm=b --ak runtime_id=kimi_coding.kimi-for-coding \
  --agent-setup-timeout-multiplier 5 --agent-timeout-multiplier 3 \
  -k 1 -n 1 -o results/jobs --job-name phase0-arm-b
```

주의: `-m kimi/kimi-for-coding`은 MascAgent에서 runtime_id `kimi.kimi-for-coding`으로
오매핑되므로 `--ak runtime_id=kimi_coding.kimi-for-coding` 명시가 필수.
`GH_TOKEN`은 keeper_up preflight(gh auth) 때문에 필요.

### arm B 결과 (attempt 3, 파이프라인 end-to-end 성공)

- **reward 0.0** (verifier 기록됨), 에피소드 state=**Timeout** (EPISODE_TIMEOUT_SEC=2400 소진,
  keeper는 kill 시점까지 정상 턴 진행 중이었음 — 패스/타임아웃 모두 Phase 0 목표인
  파이프라인 검증에는 해당)
- harbor 예외 `NonZeroAgentExitCodeError`는 run_episode.sh가 Succeeded가 아니면 exit 1을
  반환하는 설계상 예정된 신호이며, `finally` 경로로 result.json 회수·context 채움 확인.
- agent_result.metadata: `masc_state=Timeout, duration_ms=2410000, tool_calls=48,
  duplicate_tool_calls=3, arm=b, runtime_id=kimi_coding.kimi-for-coding`
- 토큰: input 2,722,487 (cached 2,626,816), output 62,958
- 에이전트 실행 40m42s, 잡 전체 49m28s
- 산출물: `results/jobs/phase0-arm-b/gpt2-codegolf__CaMemWf/`
  (trial result.json + 회수된 `agent/result.json` 포함)

### 두 arm 비교 (n=1, 스모크 — 성능 판결 아님)

| arm | 하네스 | reward | 에이전트 시간 | output tokens |
|-----|--------|--------|--------------|---------------|
| A   | kimi-cli | 1.0 | 44m35s | 59,375 |
| B   | MASC (arm b) | 0.0 (Timeout@2400s) | 40m42s | 62,958 |

### install-only 검증

`--install-only` 성공(0 exceptions, agent_setup 4m51s, bootstrap exit 0 = "MASC server ready").
산출물: `results/jobs/phase0-install-check/gpt2-codegolf__UhY2qSg/`.

### arm B 시도 중 발견·수정한 통합 버그 (전부 커밋됨)

1. `masc-exec-shim` 미업로드 → bootstrap이 `/usr/local/bin/masc-exec-shim` install에 실패
   (commit 76544dbd61: dist/masc + dist/masc-exec-shim 둘 다 업로드).
2. 아키텍처 불일치: dist가 linux/arm64였으나 태스크 이미지는 linux/amd64 →
   "cannot execute: required file not found". `MASC_LINUX_ARCH=x64 bash image/fetch_masc.sh`로
   x64 바이너리 재다운로드. **Harbor 실측에는 x64 dist가 필요**(로컬 arm64 컨테이너 스모크와 다름).
3. setup 타임아웃: bootstrap(apt 포함)이 에뮬레이션에서 360s 기본 setup cap 초과
   → `--agent-setup-timeout-multiplier 5` 필요.
4. 에피소드 타임아웃 역전: run_episode.sh 날부 데드라인 기본 3600s > harbor 에이전트
   cap 900s×3=2700s → harbor가 먼저 kill해 result.json 미회수(agent_result 전부 null).
   masc_agent가 `EPISODE_TIMEOUT_SEC=2400`을 컨테이너 env로 주입(commit 8d7957e7f1).
   - attempt2 증거: `results/jobs/phase0-arm-b-attempt2/gpt2-codegolf__LE3krbX/`
     (keeper turn 31+까지 정상 동작, verifier reward 0.0 기록됨)

## aggregate.py 보정 (harbor 0.22.0 실측 레이아웃)

- trial 결과: `<jobs>/<job>/<task>__<suffix>/result.json` — 필드 `task_name`, `trial_name`,
  `agent_result`(AgentContext: n_input_tokens/n_cache_tokens/n_output_tokens/cost_usd/metadata),
  `verifier_result.rewards.reward`. `job_name`/`attempt` 필드는 존재하지 않음
  (job은 디렉터리명에서, attempt 개념은 없음 — 컬럼을 trial_name으로 교체).
- job-level `result.json`은 `task_name`이 없어 스킵(기존 코드는 쓰레기 행을 냈음).
- `uv run pytest tests/ -q` → 14 passed. `uv run python aggregate.py results/jobs`로 실측 행 출력 확인.

## 재실행 시 필요한 것 치트시트

- `export GH_TOKEN="$(gh auth token)"` (MASC arm만)
- dist는 x64: `MASC_LINUX_ARCH=x64 bash image/fetch_masc.sh`
- 두 arm 모두 `--agent-setup-timeout-multiplier 5` 권장(에뮬레이션 apt가 느림)
- 결과는 gitignored → notes만 -f로 커밋
