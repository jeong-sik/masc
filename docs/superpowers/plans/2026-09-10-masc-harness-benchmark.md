# MASC Harness Benchmark (Terminal-Bench 2.0 + Harbor) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MASC를 Harbor 커스텀 에이전트로 Terminal-Bench 2.0에 붙여, same-model ablation(arm A~H)으로 하네스 가치를 수치 판결하는 인프라를 만든다.

**Architecture:** Harbor `BaseInstalledAgent`(`agents/masc_agent.py`)가 태스크 컨테이너 안에 prebuilt `masc` 바이너리 + bash 드라이버를 업로드한다. 컨테이너 안에서 sshd(localhost)를 띄우고, keeper는 `sandbox_profile="remote_ssh"`(endpoint=127.0.0.1)로 모든 쉘 실행이 태스크 컨테이너 내부에 떨어진다. 드라이버 플로우는 `scripts/harness_coding_eval.sh`(RFC-0396)의 bash 이식이다.

**Tech Stack:** Harbor 0.22.0(`uv tool install harbor` 완료), Python 3.13(uv venv), bash+curl+jq(컨테이너内), MASC release 바이너리(GitHub Releases, 빌드 불필요).

**Spec:** `docs/superpowers/specs/2026-09-09-masc-harness-benchmark-design.md`

## 작업 위치 (모든 Task 공통 전제)

모든 작업은 worktree에서 한다:

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/bench-harness-design
```

이하 모든 상대 경로는 이 worktree 루트 기준. 커밋도 여기서. main 체크아웃은 타인의 WIP로 더러우니 건드리지 않는다.

## 조사로 확정된 외부 사실 (플랜 전체가 의존)

- Harbor CLI: `-d terminal-bench@2.0`(89 tasks), `-a <agent|module.path:ClassName>`, `-m <provider/model>`, `-k <attempts>`, `-n <concurrency>`, `-i <task-name-glob>`(반복 가능), `-o <jobs-dir>`, `--job-name`, `--ak key=value`(에이전트 ctor kwarg), `--install-only`.
- 커스텀 에이전트 ctor: `(logs_dir: Path, model_name: str|None, *args, **kwargs)` — `--ak`가 kwargs로 들어온다.
- `BaseInstalledAgent` 헬퍼: `exec_as_root(env, command, env=None, cwd=None, timeout_sec=None)`, `exec_as_agent(...)` 동일 시그니처, `environment.upload_file(local, remote)`, `environment.upload_dir(local, remote)`. exec 결과 객체는 `.return_code/.stdout/.stderr`.
- `AgentContext` 필드: `n_input_tokens, n_cache_tokens, n_output_tokens, cost_usd, metadata`.
- MASC 토큰: 서버 기동 **전에** `masc login --base-path $BASE --host 127.0.0.1 --port 8935 --agent bench --role admin --client-env MCP_TOKEN --no-expiry --json` → JSON의 `bearer_token` 필드(`lib/auth/auth_login.ml:19`). 원시 토큰은 `<base>/.masc/auth/bench.token`에도 저장된다.
- MASC 서버: `masc start --host 127.0.0.1 --port 8935 --base-path $BASE`. 환경: `MASC_CONFIG_DIR`(config root override), `MASC_KEEPER_AUTONOMOUS_ENABLED=0`, `MASC_ORCHESTRATOR_ENABLED=0`.
- MCP: `POST http://127.0.0.1:8935/mcp`, `initialize`(protocolVersion `2025-11-25`) → 응답 헤더 `mcp-session-id` 캡처 → `notifications/initialized` → `tools/call`. 응답은 JSON 또는 SSE(`data:` 라인).
- 에피소드 플로우: `masc_keeper_up{name,instructions,runtime_id,activation_mode:"manual"}` → REST `POST /api/v1/keepers/tool-approval-mode {name, mode:"yolo"}` → `masc_keeper_msg{name,message}` → `.operation_id` → `masc_keeper_delegate_status{target:{kind:"keeper",name},operation_id}` 폴링, 터미널 상태 `Succeeded|Failed|Cancelled` → `masc_keeper_down{name}`.
- keeper profile TOML(`$MASC_CONFIG_DIR/keepers/<name>.toml`): `[keeper] always_allow=true`, `sandbox_profile="remote_ssh"`, `remote_endpoint="local"`; skills 끄기는 `[skills] names=[]`(생략=전부).
- runtime.toml 키(실재 확인): `[runtime] default="<provider>.<model>"`, `[providers.X] protocol= endpoint=`, `[providers.X.credentials] type="env" key="ENV_VAR"`, `[exec.ssh.endpoints.local] host user remote_root port identity_file`, `[models.<alias>] reasoning-effort="high"`, `[<provider>.<model>] max-concurrent=1`, `[fusion] enabled=false`.
- parallel tool 억제: overlay TOML `[[models]]` row의 `supports_parallel_tool_calls = false`(config/agent-core-models-overlay.toml 위치, `$MASC_CONFIG_DIR` 기준).
- tool 호출 로그: `$BASE/.masc/tool_calls/*.jsonl`(필드 `keeper`, `tool`). 토큰 사용량은 coding-eval도 null로 남김 → Task 8에서 실측 소스를 찾아 연결한다.
- 모델 카탈로그(packages/agent_core/models.toml)에 `claude-fable-5`(base `anthropic`) 존재. 기본 모델은 `anthropic/claude-fable-5`(Harbor 표기) / runtime_id `anthropic.claude-fable-5`. 환경변수로 교체 가능.
- sshd 픽스처 선례: `test/fixtures/sshd/Dockerfile`.

---

### Task 1: 벤치 스캐폴드 + masc 바이너리 확보

**Files:**
- Create: `benchmarks/terminal_bench/.gitignore`
- Create: `benchmarks/terminal_bench/image/fetch_masc.sh`
- Create: `benchmarks/terminal_bench/README.md`

- [ ] **Step 1: 디렉터리와 .gitignore**

```bash
mkdir -p benchmarks/terminal_bench/{image,driver,agents,configs,suite,tests,dist,results}
```

`benchmarks/terminal_bench/.gitignore`:

```gitignore
.venv/
dist/
results/jobs/
__pycache__/
.pytest_cache/
```

- [ ] **Step 2: fetch_masc.sh 작성**

`benchmarks/terminal_bench/image/fetch_masc.sh`:

```bash
#!/usr/bin/env bash
# Download the pinned prebuilt masc server binary and verify it runs in a
# linux container of the target architecture. No local build (constitution).
set -euo pipefail

MASC_VERSION="${MASC_VERSION:-0.35.1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/../dist"
ARCH="${MASC_LINUX_ARCH:-arm64}"   # Apple Silicon docker → arm64; Intel/amd64 호스트면 x64
if [[ "${ARCH}" == "x64" ]]; then PLATFORM="linux/amd64"; else PLATFORM="linux/arm64"; fi

mkdir -p "${DIST_DIR}"
gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
  -p "masc-linux-${ARCH}" -O "${DIST_DIR}/masc" --clobber
chmod +x "${DIST_DIR}/masc"

docker run --rm --platform "${PLATFORM}" \
  -v "${DIST_DIR}:/opt/dist:ro" \
  ubuntu:24.04 bash -c '/opt/dist/masc --version || /opt/dist/masc --help | head -5'
```

- [ ] **Step 3: 실행 + 검증**

```bash
chmod +x benchmarks/terminal_bench/image/fetch_masc.sh
./benchmarks/terminal_bench/image/fetch_masc.sh
```

Expected: `gh` 다운로드 성공 후 컨테이너에서 masc 버전/헬프 출력. 실패 시: `gh auth status` 확인.

- [ ] **Step 4: README.md**

`benchmarks/terminal_bench/README.md`:

```markdown
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
```

- [ ] **Step 5: Commit**

```bash
git add benchmarks/terminal_bench
git commit -m "bench: terminal_bench scaffold + masc release fetcher"
```

---

### Task 2: 컨테이너内 MCP 클라이언트 (driver/mcp.sh)

**Files:**
- Create: `benchmarks/terminal_bench/driver/mcp.sh`

- [ ] **Step 1: mcp.sh 작성** (`scripts/harness/lib/mcp_jsonrpc.sh`의 최소 이식)

```bash
#!/usr/bin/env bash
# Minimal MCP Streamable HTTP client for the MASC server (curl + jq only).
# Source this file; requires MCP_TOKEN in env.
set -euo pipefail

MCP_URL="${MASC_MCP_URL:-http://127.0.0.1:8935/mcp}"
MCP_SESSION_ID=""
: "${MCP_TOKEN:?MCP_TOKEN required}"

_mcp_post() { # body timeout_sec -> raw response body
  local body="$1" timeout="${2:-30}"
  local -a args=(
    -sS --max-time "$timeout" -X POST "$MCP_URL"
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream'
    -H "Authorization: Bearer ${MCP_TOKEN}"
  )
  [[ -n "${MCP_SESSION_ID}" ]] && args+=( -H "Mcp-Session-Id: ${MCP_SESSION_ID}" )
  curl "${args[@]}" --data-binary "$body"
}

_mcp_extract() { # raw -> json payload (unwrap SSE data: lines)
  local raw="$1"
  if printf '%s' "$raw" | grep -q '^data:'; then
    printf '%s' "$raw" | grep '^data:' | sed 's/^data: //' | tail -1
  else
    printf '%s' "$raw"
  fi
}

mcp_init() {
  local body resp
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"masc-bench","version":"0.1"}}}'
  resp="$(curl -sS -i --max-time 30 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${MCP_TOKEN}" \
    --data-binary "$body")"
  MCP_SESSION_ID="$(printf '%s' "$resp" | tr -d '\r' \
    | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tail -1)"
  if [[ -z "${MCP_SESSION_ID}" ]]; then
    echo "mcp_init: no mcp-session-id header" >&2; return 1
  fi
  _mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized"}' 10 >/dev/null
}

mcp_call() { # id tool args_json timeout_sec -> tool result json (stdout)
  local id="$1" tool="$2" args_json="$3" timeout="${4:-60}"
  local body resp payload
  body="$(jq -cn --argjson id "$id" --arg name "$tool" --argjson a "$args_json" \
    '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$name,arguments:$a}}')"
  resp="$(_mcp_post "$body" "$timeout")"
  payload="$(_mcp_extract "$resp")"
  if ! printf '%s' "$payload" | jq -e '.error == null and (.result.isError // false) == false' >/dev/null 2>&1; then
    echo "mcp_call ${tool} failed: ${payload}" >&2
    return 1
  fi
  printf '%s' "$payload" | jq -c 'try (.result.content[0].text | fromjson) catch .result'
}
```

- [ ] **Step 2: 문법 검사**

```bash
bash -n benchmarks/terminal_bench/driver/mcp.sh && shellcheck benchmarks/terminal_bench/driver/mcp.sh || true
```

Expected: `bash -n` 통과 (shellcheck은 있으면). 단위 실행 테스트는 Task 7 통합 스모크가 담당한다.

- [ ] **Step 3: Commit**

```bash
git add benchmarks/terminal_bench/driver/mcp.sh
git commit -m "bench: in-container MCP client for MASC"
```

---

### Task 3: bootstrap.sh — 컨테이너内 환경 구성

**Files:**
- Create: `benchmarks/terminal_bench/driver/bootstrap.sh`

- [ ] **Step 1: bootstrap.sh 작성**

install()에서 root로 1회 실행된다. sshd(localhost, root key auth) + 의존성 + config 배치 + 토큰 발급 + 서버 기동.

```bash
#!/usr/bin/env bash
# One-shot container bootstrap for the MASC bench agent. Runs as root.
# Expects uploads already in place:
#   /opt/masc-bench/bin/masc      (release binary, +x)
#   /opt/masc-bench/driver/       (mcp.sh, bootstrap.sh, run_episode.sh)
#   /opt/masc-bench/config/       (rendered arm config: runtime.toml, keepers/, ...)
set -euo pipefail

BENCH=/opt/masc-bench
export MASC_BASE_PATH=$BENCH/base
export MASC_CONFIG_DIR=$BENCH/config
export MASC_KEEPER_AUTONOMOUS_ENABLED=0
export MASC_ORCHESTRATOR_ENABLED=0
export AGENT_CORE_MCP_SERVERS_CONFIG="mcp_servers={}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  openssh-server jq curl ca-certificates \
  libffi8 libgmp10 libsqlite3-0 libssl3t64 libzstd1 zlib1g >/dev/null

# --- sshd on localhost, root key auth (keeper remote_ssh endpoint target) ---
install -d -m 0755 /run/sshd
install -d -m 0700 "$BENCH/ssh" /root/.ssh
[[ -f "$BENCH/ssh/id_ed25519" ]] || ssh-keygen -t ed25519 -N '' -q -f "$BENCH/ssh/id_ed25519"
install -m 0600 "$BENCH/ssh/id_ed25519.pub" /root/.ssh/authorized_keys
{
  echo 'PasswordAuthentication no'
  echo 'PermitRootLogin prohibit-password'
  echo 'PubkeyAuthentication yes'
} >> /etc/ssh/sshd_config
pgrep -x sshd >/dev/null || /usr/sbin/sshd
ssh -i "$BENCH/ssh/id_ed25519" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@127.0.0.1 true

# --- token BEFORE server start (minting against a live base path makes the
# --- server yield ownership; harness_coding_eval.sh:195-199) ---
if [[ ! -s "$BENCH/token" ]]; then
  "$BENCH/bin/masc" login \
    --base-path "$MASC_BASE_PATH" --host 127.0.0.1 --port 8935 \
    --agent bench --role admin --client-env MCP_TOKEN --no-expiry --json \
    | jq -r '.bearer_token' > "$BENCH/token"
  chmod 600 "$BENCH/token"
  [[ -s "$BENCH/token" ]] || { echo "login did not yield bearer_token" >&2; exit 1; }
fi

# --- start server (idempotent) ---
if ! pgrep -f "masc start" >/dev/null; then
  nohup "$BENCH/bin/masc" start --host 127.0.0.1 --port 8935 \
    --base-path "$MASC_BASE_PATH" > "$BENCH/server.log" 2>&1 &
fi

# --- wait until MCP answers ---
export MCP_TOKEN="$(cat "$BENCH/token")"
source "$BENCH/driver/mcp.sh"
for _ in $(seq 1 60); do
  if mcp_init 2>/dev/null; then echo "MASC server ready"; exit 0; fi
  sleep 1
done
echo "MASC server failed to start; server.log tail:" >&2
tail -50 "$BENCH/server.log" >&2 || true
exit 1
```

- [ ] **Step 2: 문법 검사 + commit**

```bash
bash -n benchmarks/terminal_bench/driver/bootstrap.sh
git add benchmarks/terminal_bench/driver/bootstrap.sh
git commit -m "bench: container bootstrap (sshd + token + server)"
```

---

### Task 4: run_episode.sh — 에피소드 구동 + result.json

**Files:**
- Create: `benchmarks/terminal_bench/driver/run_episode.sh`

- [ ] **Step 1: run_episode.sh 작성**

`KEEPER_COUNT`(arm)만큼 keeper를 띄운다. 1기면 instruction을 직접 보내고, N기면 lead(bench-1)에게 팀 지시 래퍼를 붙여 보낸다.

```bash
#!/usr/bin/env bash
# usage: run_episode.sh <instruction-file> <result-json-path>
set -euo pipefail

BENCH=/opt/masc-bench
export MASC_BASE_PATH=$BENCH/base
export MASC_CONFIG_DIR=$BENCH/config
export MCP_TOKEN="$(cat "$BENCH/token")"
source "$BENCH/driver/mcp.sh"

INSTRUCTION_FILE="$1"
RESULT_JSON="$2"
KEEPER_COUNT="${KEEPER_COUNT:-1}"
RUNTIME_ID="${BENCH_RUNTIME_ID:?BENCH_RUNTIME_ID required (e.g. anthropic.claude-fable-5)}"
EPISODE_TIMEOUT_SEC="${EPISODE_TIMEOUT_SEC:-3600}"
POLL_INTERVAL_SEC=10

KEEPER_INSTRUCTIONS="You are an autonomous engineering agent inside a Linux container. \
Complete the task by running shell commands (your tool calls execute in this container as root). \
Work directly; do not ask questions. When the task is verifiably done, finish."

mcp_init

lead_msg="$(cat "$INSTRUCTION_FILE")"
if [[ "${KEEPER_COUNT}" -gt 1 ]]; then
  names=""
  for i in $(seq 1 "${KEEPER_COUNT}"); do names="${names} bench-${i}"; done
  lead_msg="You are the lead of a keeper team:${names}. Decompose the task, delegate to the team with your keeper tools, integrate their results, and verify completion yourself.

${lead_msg}"
fi

for i in $(seq 1 "${KEEPER_COUNT}"); do
  k="bench-${i}"
  mcp_call $((100+i)) masc_keeper_up "$(jq -cn \
    --arg name "$k" --arg ins "$KEEPER_INSTRUCTIONS" --arg rid "$RUNTIME_ID" \
    '{name:$name, instructions:$ins, runtime_id:$rid, activation_mode:"manual"}')" 90 >/dev/null
  curl -fsS -m 20 -X POST "http://127.0.0.1:8935/api/v1/keepers/tool-approval-mode" \
    -H "Authorization: Bearer ${MCP_TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${k}\",\"mode\":\"yolo\"}" >/dev/null
done

start_epoch="$(date +%s)"
printf '%s' "$lead_msg" > "$BENCH/episode-message.txt"
submit="$(mcp_call 200 masc_keeper_msg \
  "$(jq -cn --arg name bench-1 --rawfile m "$BENCH/episode-message.txt" \
    '{name:$name, message:$m}')" 60)"
op_id="$(printf '%s' "$submit" | jq -r '.operation_id // empty')"
[[ -n "$op_id" ]] || { echo "keeper_msg returned no operation_id: $submit" >&2; exit 1; }

state="Timeout"; final='{}'
deadline=$(( start_epoch + EPISODE_TIMEOUT_SEC ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  st="$(mcp_call 300 masc_keeper_delegate_status "$(jq -cn \
    --arg op "$op_id" \
    '{target:{kind:"keeper",name:"bench-1"}, operation_id:$op}')" 30)" || true
  s="$(printf '%s' "$st" | jq -r '.state // empty' 2>/dev/null || true)"
  case "$s" in
    Succeeded|Failed|Cancelled) state="$s"; final="$st"; break ;;
  esac
  sleep "$POLL_INTERVAL_SEC"
done
end_epoch="$(date +%s)"

for i in $(seq 1 "${KEEPER_COUNT}"); do
  mcp_call $((400+i)) masc_keeper_down "$(jq -cn --arg n "bench-${i}" '{name:$n}')" 20 >/dev/null || true
done

# --- metrics: tool calls + duplicate calls from the tool_calls jsonl store ---
tool_log_dir="$MASC_BASE_PATH/.masc/tool_calls"
tool_calls=0; dup_calls=0
if [[ -d "$tool_log_dir" ]]; then
  tool_calls="$(find "$tool_log_dir" -name '*.jsonl' -exec cat {} + | jq -s 'length')"
  dup_calls="$(find "$tool_log_dir" -name '*.jsonl' -exec cat {} + \
    | jq -s 'group_by([.tool, ((.input // .arguments // {})|tostring)]) | map(select(length>1) | (length-1)) | add // 0')"
fi

jq -n \
  --arg state "$state" \
  --argjson duration_ms $(( (end_epoch - start_epoch) * 1000 )) \
  --argjson tool_calls "${tool_calls:-0}" \
  --argjson duplicate_tool_calls "${dup_calls:-0}" \
  --argjson final "${final:-{}}" \
  '{state:$state, duration_ms:$duration_ms, tool_calls:$tool_calls,
    duplicate_tool_calls:$duplicate_tool_calls, final:$final}' \
  > "$RESULT_JSON"
cat "$RESULT_JSON"
[[ "$state" == "Succeeded" ]]
```

- [ ] **Step 2: 문법 검사 + commit**

```bash
bash -n benchmarks/terminal_bench/driver/run_episode.sh
git add benchmarks/terminal_bench/driver/run_episode.sh
git commit -m "bench: episode driver (keeper up/msg/poll + metrics)"
```

---

### Task 5: arm config 렌더러 (render_configs.py + 테스트)

**Files:**
- Create: `benchmarks/terminal_bench/configs/render_configs.py`
- Create: `benchmarks/terminal_bench/tests/test_render_configs.py`
- Create: `benchmarks/terminal_bench/tests/__init__.py` (빈 파일)

- [ ] **Step 1: 실패하는 테스트 작성**

`benchmarks/terminal_bench/tests/test_render_configs.py`:

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "configs"))

from render_configs import ARMS, keeper_toml, render_arm  # noqa: E402


def test_arms_cover_spec():
    assert set(ARMS) == {"b", "c", "d", "e", "f", "g", "h"}
    assert ARMS["b"]["keepers"] == 1
    assert ARMS["f"]["keepers"] == 4
    assert ARMS["g"]["keepers"] == 8


def test_arm_b_skills_off():
    out = render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high")
    keeper = (out / "keepers" / "bench-1.toml").read_text()
    assert "always_allow = true" in keeper
    assert 'sandbox_profile = "remote_ssh"' in keeper
    assert "[skills]" in keeper and "names = []" in keeper
    rt = (out / "runtime.toml").read_text()
    assert '[fusion]' in rt and "enabled = false" in rt
    assert 'default = "anthropic.claude-fable-5"' in rt
    assert "[exec.ssh.endpoints.local]" in rt
    assert 'reasoning-effort = "high"' in rt


def test_arm_c_skills_on_no_composition():
    keeper = keeper_toml("c", 1)
    assert "[skills]" not in keeper  # 생략 = profile skills 전부
    assert "attached_allow" in keeper  # spawn/composition 도구 차단


def test_arm_e_parallel_on():
    rt_e = render_arm("e", runtime_id="anthropic.claude-fable-5", effort="high")
    overlay = (rt_e / "agent-core-models-overlay.toml").read_text()
    assert "supports_parallel_tool_calls = true" in overlay
    rt_b = render_arm("b", runtime_id="anthropic.claude-fable-5", effort="high")
    overlay_b = (rt_b / "agent-core-models-overlay.toml").read_text()
    assert "supports_parallel_tool_calls = false" in overlay_b
    assert "max-concurrent = 1" in (rt_b / "runtime.toml").read_text()


def test_arm_f_renders_four_keepers():
    out = render_arm("f", runtime_id="anthropic.claude-fable-5", effort="high")
    keepers = sorted((out / "keepers").glob("bench-*.toml"))
    assert len(keepers) == 4
```

- [ ] **Step 2: 테스트가 실패함을 확인**

```bash
cd benchmarks/terminal_bench && uv venv && uv pip install harbor pytest && uv run pytest tests/ -x -q
```

Expected: FAIL (`render_configs` 모듈 없음).

- [ ] **Step 3: render_configs.py 구현**

`benchmarks/terminal_bench/configs/render_configs.py`:

```python
"""Render per-arm MASC configs for the harness benchmark.

Arm 체인 (spec §6.2): b(1 keeper, 전부 off) -> c(+skills) -> d(+composition)
-> e(+parallel) -> f(4 keepers) -> g(8 keepers) -> h(fusion on).
Arm A는 Harbor 빌트인 terminus-2라 여기서 렌더하지 않는다.
"""
from __future__ import annotations

import shutil
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = BENCH_ROOT.parents[1]
OUT_ROOT = BENCH_ROOT / "configs" / "out"

# keepers, skills, composition, parallel
ARMS: dict[str, dict] = {
    "b": dict(keepers=1, skills=False, composition=False, parallel=False, fusion=False),
    "c": dict(keepers=1, skills=True,  composition=False, parallel=False, fusion=False),
    "d": dict(keepers=1, skills=True,  composition=True,  parallel=False, fusion=False),
    "e": dict(keepers=1, skills=True,  composition=True,  parallel=True,  fusion=False),
    "f": dict(keepers=4, skills=True,  composition=True,  parallel=True,  fusion=False),
    "g": dict(keepers=8, skills=True,  composition=True,  parallel=True,  fusion=False),
    "h": dict(keepers=8, skills=True,  composition=True,  parallel=True,  fusion=True),
}

# composition을 싣는 keeper coordination 도구. skills가 켜진 arm에서
# composition=False이면 이들을 attached_allow에서 빼서 차단한다.
NON_COMPOSITION_TOOLS = [
    "tool_execute", "tool_read_file", "tool_write_file", "tool_edit_file",
    "tool_search_files", "Read", "Write", "Edit", "Grep",
    "keeper_tasks", "keeper_memory", "keeper_board",
]

RUNTIME_TOML = """\
[runtime]
default = "{runtime_id}"

[providers.{provider}]
display-name = "Bench provider"
protocol = "{protocol}"
endpoint = "{endpoint}"

[providers.{provider}.credentials]
type = "env"
key = "{api_key_env}"

[models.{model_alias}]
reasoning-effort = "{effort}"

[{runtime_id}]
max-concurrent = {max_concurrent}

[exec.ssh.endpoints.local]
host = "127.0.0.1"
user = "root"
remote_root = "/root"
port = 22
identity_file = "/opt/masc-bench/ssh/id_ed25519"

[fusion]
enabled = {fusion}
"""

OVERLAY_TOML = """\
[[models]]
id-prefix = "{model_alias}"
supports_parallel_tool_calls = {parallel}
"""

# provider 프로토콜 매핑. 새 provider 추가 시 여기만 고친다.
PROVIDERS = {
    "anthropic": dict(protocol="messages-http",
                      endpoint="https://api.anthropic.com",
                      api_key_env="ANTHROPIC_API_KEY"),
    "openai": dict(protocol="openai-compatible-http",
                   endpoint="https://api.openai.com/v1",
                   api_key_env="OPENAI_API_KEY"),
    "kimi_coding": dict(protocol="openai-compatible-http",
                        endpoint="https://api.kimi.com/coding/v1",
                        api_key_env="KIMI_API_KEY"),
}


def keeper_toml(arm: str, index: int) -> str:
    spec = ARMS[arm]
    lines = [
        "[keeper]",
        "always_allow = true",
        'sandbox_profile = "remote_ssh"',
        'remote_endpoint = "local"',
    ]
    if not spec["skills"]:
        lines += ["", "[skills]", "names = []"]
    elif not spec["composition"]:
        tools = ", ".join(f'"{t}"' for t in NON_COMPOSITION_TOOLS)
        lines += ["", "[tools]", f"attached_allow = [{tools}]"]
    return "\n".join(lines) + "\n"


def render_arm(arm: str, runtime_id: str, effort: str, out_root: Path | None = None) -> Path:
    """arm config를 (out_root/<arm>/)에 렌더하고 디렉터리를 반환한다.

    레포 config/ 시드(도구 정의·프롬프트 등)를 복사한 뒤 runtime.toml,
    keepers/, overlay를 arm 사양으로 덮어쓴다.
    """
    if arm not in ARMS:
        raise ValueError(f"unknown arm {arm!r}; expected one of {sorted(ARMS)}")
    spec = ARMS[arm]
    provider, _, model_alias = runtime_id.partition(".")
    if not provider or not model_alias:
        raise ValueError(f"runtime_id must be '<provider>.<model>', got {runtime_id!r}")
    pcfg = PROVIDERS[provider]

    root = (out_root or OUT_ROOT) / arm
    if root.exists():
        shutil.rmtree(root)
    shutil.copytree(REPO_ROOT / "config", root, ignore=shutil.ignore_patterns(
        "keepers", "keepers-default", "runtime.toml", "*.env",
        "agent-core-models-overlay.toml"))

    (root / "runtime.toml").write_text(RUNTIME_TOML.format(
        runtime_id=runtime_id, provider=provider, model_alias=model_alias,
        effort=effort, fusion=str(spec["fusion"]).lower(),
        max_concurrent=4 if spec["parallel"] else 1,
        **pcfg))
    (root / "agent-core-models-overlay.toml").write_text(OVERLAY_TOML.format(
        model_alias=model_alias, parallel=str(spec["parallel"]).lower()))

    keepers = root / "keepers"
    keepers.mkdir(exist_ok=True)
    for i in range(1, spec["keepers"] + 1):
        (keepers / f"bench-{i}.toml").write_text(keeper_toml(arm, i))
    return root


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("arm", choices=sorted(ARMS))
    ap.add_argument("--runtime-id", default="anthropic.claude-fable-5")
    ap.add_argument("--effort", default="high")
    ns = ap.parse_args()
    print(render_arm(ns.arm, ns.runtime_id, ns.effort))
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd benchmarks/terminal_bench && uv run pytest tests/test_render_configs.py -q
```

Expected: 4 passed. 실패 시: `[tools] attached_allow`가 keeper TOML parser 허용 키인지 `lib/keeper/keeper_types_profile_toml_parser.ml:23-50`에서 확인하고 키 이름을 맞춘다. `NON_COMPOSITION_TOOLS`의 도구명은 추정이 아니라 실재여야 한다 — `ls config/tools/ | sed 's/\.toml$//'`로 실제 도구명을 확인해 목록을 맞춘다(composition/spawn 계열을 제외한 allowlist). overlay 키(`id-prefix` 등)는 `config/agent-core-models-overlay.toml`의 기존 row 표기를 그대로 따른다 — 다르면 그 파일 문법에 맞춰 OVERLAY_TOML을 수정한다.

- [ ] **Step 5: Commit**

```bash
git add benchmarks/terminal_bench/configs benchmarks/terminal_bench/tests
git commit -m "bench: per-arm config renderer (ablation knobs)"
```

---

### Task 6: Harbor 에이전트 (agents/masc_agent.py + 테스트)

**Files:**
- Create: `benchmarks/terminal_bench/agents/__init__.py` (빈 파일)
- Create: `benchmarks/terminal_bench/agents/masc_agent.py`
- Create: `benchmarks/terminal_bench/tests/test_masc_agent.py`

- [ ] **Step 1: 실패하는 테스트 작성**

`benchmarks/terminal_bench/tests/test_masc_agent.py`:

```python
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agents.masc_agent import MascAgent  # noqa: E402


class FakeResult:
    def __init__(self, stdout="", return_code=0):
        self.stdout = stdout
        self.returncode = return_code
        self.return_code = return_code
        self.stderr = ""


class FakeEnv:
    def __init__(self):
        self.commands = []
        self.uploads = []
        self.default_user = None

    async def upload_file(self, src, dst):
        self.uploads.append(("file", str(src), dst))

    async def upload_dir(self, src, dst):
        self.uploads.append(("dir", str(src), dst))

    async def exec(self, command, **kw):
        self.commands.append(command)
        if command.startswith("cat /opt/masc-bench/result.json"):
            return FakeResult('{"state":"Succeeded","duration_ms":1234,'
                              '"tool_calls":17,"duplicate_tool_calls":2,"final":{}}')
        return FakeResult("")


def make_agent(tmp_path, **kw):
    return MascAgent(logs_dir=tmp_path, model_name="anthropic/claude-fable-5", **kw)


def test_runtime_id_from_model(tmp_path):
    a = make_agent(tmp_path)
    assert a.runtime_id == "anthropic.claude-fable-5"


def test_runtime_id_kwarg_wins(tmp_path):
    a = make_agent(tmp_path, runtime_id="kimi_coding.kimi-k2.7")
    assert a.runtime_id == "kimi_coding.kimi-k2.7"


@pytest.mark.asyncio
async def test_install_uploads_binary_driver_config(tmp_path):
    a = make_agent(tmp_path, arm="b")
    env = FakeEnv()
    await a.install(env)
    kinds = [(k, d) for k, _, d in env.uploads]
    assert ("file", "/opt/masc-bench/bin/masc") in kinds
    assert ("dir", "/opt/masc-bench/driver") in kinds
    assert ("dir", "/opt/masc-bench/config") in kinds
    assert any("bootstrap.sh" in c for c in env.commands)


@pytest.mark.asyncio
async def test_run_populates_context(tmp_path):
    from harbor.models.agent.context import AgentContext

    a = make_agent(tmp_path, arm="b")
    env = FakeEnv()
    ctx = AgentContext()
    await a.run("do the task", env, ctx)
    assert any("run_episode.sh" in c for c in env.commands)
    assert ctx.metadata["masc_state"] == "Succeeded"
    assert ctx.metadata["tool_calls"] == 17
    assert ctx.metadata["duplicate_tool_calls"] == 2
```

- [ ] **Step 2: 실패 확인**

```bash
cd benchmarks/terminal_bench && uv run pytest tests/test_masc_agent.py -q
```

Expected: FAIL (`agents.masc_agent` 없음).

- [ ] **Step 3: masc_agent.py 구현**

`benchmarks/terminal_bench/agents/masc_agent.py`:

```python
"""MASC harness as a Harbor installed agent (spec §5, approach A).

install(): prebuilt masc 바이너리 + bash 드라이버 + 렌더된 arm config를
태스크 컨테이너 /opt/masc-bench에 업로드하고 bootstrap.sh를 root로 실행한다.
run(): instruction을 업로드하고 run_episode.sh를 실행한 뒤 result.json을
읽어 AgentContext에 싣는다.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

BENCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_ROOT / "configs"))

from render_configs import ARMS, PROVIDERS, render_arm  # noqa: E402

REMOTE = "/opt/masc-bench"


class MascAgent(BaseInstalledAgent):
    def __init__(self, logs_dir, model_name=None, arm="b",
                 runtime_id=None, effort="high", **kwargs):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)
        if arm not in ARMS:
            raise ValueError(f"unknown arm {arm!r}; expected one of {sorted(ARMS)}")
        self.arm = arm
        self.effort = effort
        if runtime_id:
            self.runtime_id = runtime_id
        elif model_name and "/" in model_name:
            provider, model = model_name.split("/", 1)
            self.runtime_id = f"{provider}.{model}"
        else:
            raise ValueError("model_name 'provider/model' 또는 runtime_id kwarg 필요")

    @staticmethod
    def name() -> str:
        return "masc"

    def version(self) -> str:
        version_file = BENCH_ROOT / "dist" / ".version"
        return version_file.read_text().strip() if version_file.exists() else "unknown"

    def _container_env(self) -> dict[str, str]:
        provider = self.runtime_id.split(".", 1)[0]
        key_env = PROVIDERS[provider]["api_key_env"]
        key = os.environ.get(key_env)
        if not key:
            raise RuntimeError(f"{key_env} not set in harbor process env")
        return {
            key_env: key,
            "BENCH_RUNTIME_ID": self.runtime_id,
            "KEEPER_COUNT": str(ARMS[self.arm]["keepers"]),
        }

    async def install(self, environment: BaseEnvironment) -> None:
        binary = BENCH_ROOT / "dist" / "masc"
        if not binary.exists():
            raise RuntimeError("run image/fetch_masc.sh first")
        config_dir = render_arm(self.arm, self.runtime_id, self.effort)
        await self.exec_as_root(environment, f"mkdir -p {REMOTE}/bin")
        await environment.upload_file(binary, f"{REMOTE}/bin/masc")
        await environment.upload_dir(BENCH_ROOT / "driver", f"{REMOTE}/driver")
        await environment.upload_dir(config_dir, f"{REMOTE}/config")
        await self.exec_as_root(
            environment,
            f"chmod +x {REMOTE}/bin/masc {REMOTE}/driver/*.sh && "
            f"bash {REMOTE}/driver/bootstrap.sh",
            env=self._container_env(),
            timeout_sec=900,
        )

    async def run(self, instruction: str, environment: BaseEnvironment,
                  context: AgentContext) -> None:
        instr_local = Path(self.logs_dir) / "instruction.txt"
        instr_local.parent.mkdir(parents=True, exist_ok=True)
        instr_local.write_text(instruction)
        await environment.upload_file(instr_local, f"{REMOTE}/instruction.txt")
        await self.exec_as_root(
            environment,
            f"bash {REMOTE}/driver/run_episode.sh "
            f"{REMOTE}/instruction.txt {REMOTE}/result.json",
            env=self._container_env(),
            timeout_sec=None,  # Harbor의 agent timeout이 상한
        )
        result = await self.exec_as_root(environment, f"cat {REMOTE}/result.json")
        (Path(self.logs_dir) / "result.json").write_text(result.stdout)
        self.populate_context_post_run(context)

    def populate_context_post_run(self, context: AgentContext) -> None:
        result_path = Path(self.logs_dir) / "result.json"
        if not result_path.exists():
            return
        data = json.loads(result_path.read_text())
        final = data.get("final") or {}
        usage = final.get("usage") or {}
        context.n_input_tokens = usage.get("input_tokens")
        context.n_cache_tokens = usage.get("cache_tokens")
        context.n_output_tokens = usage.get("output_tokens")
        context.metadata = {
            **(context.metadata or {}),
            "masc_state": data.get("state"),
            "duration_ms": data.get("duration_ms"),
            "tool_calls": data.get("tool_calls"),
            "duplicate_tool_calls": data.get("duplicate_tool_calls"),
            "arm": self.arm,
            "runtime_id": self.runtime_id,
        }
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd benchmarks/terminal_bench && uv run pytest tests/ -q
```

Expected: 전부 PASS. `BaseInstalledAgent`의 추상 메서드가 더 있어 instantiate 에러가 나면 harbor 소스(`~/.local/share/uv/tools/harbor/lib/python3.13/site-packages/harbor/agents/installed/base.py`의 `@abstractmethod`)를 보고 stub을 추가한다.

- [ ] **Step 5: Commit**

```bash
git add benchmarks/terminal_bench/agents benchmarks/terminal_bench/tests
git commit -m "bench: Harbor installed-agent adapter for MASC"
```

---

### Task 7: 로컬 컨테이너 통합 스모크 (Harbor 없이)

**Files:**
- 없음 (검증 전용 Task). 발견한 수정사항은 해당 파일에 반영 후 커밋.

목적: Harbor를 끼우기 전에 bootstrap+episode가 실제 LLM API로 종단 동작함을 확인한다. 여기서 토큰 usage 필드 소스도 찾는다.

- [ ] **Step 1: 스모크 컨테이너 실행**

```bash
cd benchmarks/terminal_bench
uv run python configs/render_configs.py b --runtime-id anthropic.claude-fable-5
docker run --rm --platform linux/arm64 \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -v "$PWD/dist:/opt/masc-bench/bin:ro" \
  -v "$PWD/driver:/opt/masc-bench/driver:ro" \
  -v "$PWD/configs/out/b:/opt/masc-bench/config:ro" \
  ubuntu:24.04 bash -c '
    chmod +x /opt/masc-bench/bin/masc /opt/masc-bench/driver/*.sh
    bash /opt/masc-bench/driver/bootstrap.sh &&
    cp -r /opt/masc-bench/config /tmp/config-rw &&  # config가 ro 마운트일 경우 대비
    printf "Create a file /tmp/masc-smoke-ok containing the word done. Then finish." > /tmp/instruction.txt &&
    BENCH_RUNTIME_ID=anthropic.claude-fable-5 KEEPER_COUNT=1 EPISODE_TIMEOUT_SEC=900 \
      bash /opt/masc-bench/driver/run_episode.sh /tmp/instruction.txt /tmp/result.json;
    ls -la /tmp/masc-smoke-ok 2>/dev/null; cat /tmp/result.json
  '
```

Expected: bootstrap "MASC server ready", episode state `Succeeded`, `/tmp/masc-smoke-ok` 생성, result.json 출력. config를 ro로 마운트했으므로 bootstrap이 config에 쓰려다 실패하면 rw 복사본(`MASC_CONFIG_DIR=/tmp/config-rw`)으로 재실행한다 — 그 경우 bootstrap.sh에 rw 사본 로직을 반영.

- [ ] **Step 2: 토큰 usage 소스 실측**

같은 컨테이너 안에서:

```bash
find /opt/masc-bench/base/.masc -name '*.jsonl' | head -20
grep -rl '"usage"\|input_tokens' /opt/masc-bench/base/.masc 2>/dev/null | head
tail -200 /opt/masc-bench/server.log | grep -i 'usage\|token' | head
```

발견한 필드를 `run_episode.sh`의 result.json에 `input_tokens/output_tokens/cache_tokens`로 추가하고, `populate_context_post_run`의 `usage` fallback을 그에 맞춘다. 못 찾으면 null 유지 + 결과 테이블에 "tokens: not instrumented"로 명시(스펙 §7 리스크와 동일 처리).

- [ ] **Step 3: Commit (수정분이 있으면)**

```bash
git add -A benchmarks/terminal_bench
git commit -m "bench: smoke-verified bootstrap + token usage wiring"
```

---

### Task 8: mini-suite + 매트릭스 러너 + 집계

**Files:**
- Create: `benchmarks/terminal_bench/suite/mini-suite.txt`
- Create: `benchmarks/terminal_bench/suite/SELECTION.md`
- Create: `benchmarks/terminal_bench/run_matrix.sh`
- Create: `benchmarks/terminal_bench/aggregate.py`

- [ ] **Step 1: mini-suite.txt** (89개 중 24개, 카테고리 분산)

```text
gpt2-codegolf
break-filter-js-from-html
build-cython-ext
compile-compcert
configure-git-webserver
fix-git
git-multibranch
sanitize-git-repo
crack-7z-hash
openssl-selfsigned-cert
fix-code-vulnerability
nginx-request-logging
pypi-server
sqlite-db-truncate
query-optimize
log-summary-date-ranges
regex-log
large-scale-text-editing
polyglot-c-py
kv-store-grpc
cancel-async-tasks
constraints-scheduling
chess-best-move
write-compressor
```

- [ ] **Step 2: SELECTION.md**

```markdown
# Mini-suite 선정 기준

- 모수: terminal-bench@2.0 전체 89 task (harbor registry.json 기준).
- 24개 선정, 기준은 유형 분산: 빌드/컴파일(build-cython-ext, compile-compcert),
  git 계열 4개, 보안/암호 3개, 서버/인프라 3개, 데이터/쿼리 2개,
  텍스트/로그 처리 3개, 언어/비동기 3개, 알고리즘 2개.
- gpt2-codegolf 포함: Harbor 문서상 첫 실행 태스크라 스모크와 연속성 확보.
- 제외 원칙: GUI/영상 의존(extract-moves-from-video, code-from-image)과
  초장시간 학습 계열(train-fasttext, caffe-cifar-10)은 mini-suite에서 제외.
  Phase 2(전체 89개)에서 다시 포함된다.
```

- [ ] **Step 3: run_matrix.sh**

```bash
#!/usr/bin/env bash
# usage: ./run_matrix.sh [arms-csv] [attempts]
# env: BENCH_MODEL (default anthropic/claude-fable-5), CONCURRENCY (default 2)
set -euo pipefail
cd "$(dirname "$0")"

ARMS_CSV="${1:-a,b,c,e,f,h}"
K="${2:-3}"
MODEL="${BENCH_MODEL:-anthropic/claude-fable-5}"
TS="$(date +%Y%m%d-%H%M%S)"

mapfile -t TASKS < suite/mini-suite.txt 2>/dev/null || true
TASK_ARGS=()
if [[ ${#TASKS[@]} -gt 0 ]]; then
  for t in "${TASKS[@]}"; do TASK_ARGS+=( -i "$t" ); done
else
  # macOS 기본 bash 3.2에는 mapfile이 없다.
  while IFS= read -r t; do TASK_ARGS+=( -i "$t" ); done < suite/mini-suite.txt
fi

for arm in ${ARMS_CSV//,/ }; do
  job="arm-${arm}-${TS}"
  if [[ "$arm" == "a" ]]; then
    uv run harbor run -d terminal-bench@2.0 --agent terminus-2 \
      --model "$MODEL" -k "$K" -n "${CONCURRENCY:-2}" \
      -o results/jobs --job-name "$job" "${TASK_ARGS[@]}"
  else
    uv run harbor run -d terminal-bench@2.0 \
      --agent agents.masc_agent:MascAgent --model "$MODEL" \
      --ak "arm=$arm" -k "$K" -n "${CONCURRENCY:-2}" \
      -o results/jobs --job-name "$job" "${TASK_ARGS[@]}"
  fi
done
python aggregate.py "results/jobs" > "results/summary-${TS}.csv"
echo "wrote results/summary-${TS}.csv"
```

- [ ] **Step 4: aggregate.py** — Harbor trial 산출물에서 arm×task 성공률/시간/토큰 집계.

```python
"""Harbor jobs 디렉터리를 훑어 arm×task 요약 CSV를 만든다.

사용: python aggregate.py <jobs-dir>
행: job(=arm), task, attempt, reward(0/1), duration_ms, tokens, tool_calls.
Harbor trial 결과 파일 레이아웃은 Phase 0 첫 실행 산출물로 확정한다
(trial 디렉터리의 result/config json을 재귀 탐색).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def iter_trials(jobs: Path):
    for result in sorted(jobs.rglob("result.json")):
        try:
            data = json.loads(result.read_text())
        except json.JSONDecodeError:
            continue
        yield result.parent, data


def main() -> None:
    jobs = Path(sys.argv[1])
    print("job,task,attempt,reward,duration_ms,input_tokens,output_tokens,"
          "cache_tokens,cost_usd,tool_calls,duplicate_tool_calls,masc_state")
    for trial_dir, data in iter_trials(jobs):
        agent = data.get("agent_result") or {}
        verifier = data.get("verifier_result") or {}
        meta = (data.get("agent_context") or {}).get("metadata") or {}
        reward = (verifier.get("rewards") or {}).get("reward", "")
        row = [
            data.get("job_name", trial_dir.parts[-3] if len(trial_dir.parts) > 2 else ""),
            data.get("task_name", trial_dir.name),
            str(data.get("attempt", "")),
            str(reward),
            str(meta.get("duration_ms", "")),
            str((data.get("agent_context") or {}).get("n_input_tokens") or ""),
            str((data.get("agent_context") or {}).get("n_output_tokens") or ""),
            str((data.get("agent_context") or {}).get("n_cache_tokens") or ""),
            str((data.get("agent_context") or {}).get("cost_usd") or ""),
            str(meta.get("tool_calls", "")),
            str(meta.get("duplicate_tool_calls", "")),
            str(meta.get("masc_state", "")),
        ]
        print(",".join(row))


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: 문법 검사 + commit**

```bash
bash -n benchmarks/terminal_bench/run_matrix.sh
chmod +x benchmarks/terminal_bench/run_matrix.sh
cd benchmarks/terminal_bench && uv run python -c "import aggregate"
git add benchmarks/terminal_bench/suite benchmarks/terminal_bench/run_matrix.sh benchmarks/terminal_bench/aggregate.py
git commit -m "bench: mini-suite + matrix runner + aggregation"
```

---

### Task 9: Phase 0 — Harbor 스모크 (1 task, arm B, 실제 실행)

**Files:**
- 없음 (실행 + 발견 수정).

- [ ] **Step 1: install-only 검증**

```bash
cd benchmarks/terminal_bench && source .venv/bin/activate
harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
  --agent agents.masc_agent:MascAgent -m anthropic/claude-fable-5 \
  --ak arm=b --install-only -n 1 -o results/jobs
```

Expected: 태스크 컨테이너 빌드 + MASC install 성공. 실패 시 install 로그(harbor jobs dir)를 보고 bootstrap을 고친다.

- [ ] **Step 2: 실제 1회 실행**

```bash
harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
  --agent agents.masc_agent:MascAgent -m anthropic/claude-fable-5 \
  --ak arm=b -k 1 -n 1 -o results/jobs --job-name phase0-arm-b
```

Expected: trial 완료(성공/실패 무관 — 파이프라인 종단이 목적). 산출물에서: verifier reward 존재, `result.json`에 masc_state 기록.

- [ ] **Step 3: 베이스라인(arm A) 1회 실행 — 모델 동일성 확인**

```bash
harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
  --agent terminus-2 -m anthropic/claude-fable-5 \
  -k 1 -n 1 -o results/jobs --job-name phase0-arm-a
```

- [ ] **Step 4: 산출물 레이아웃 확정 + aggregate.py 보정**

```bash
find results/jobs/phase0-arm-b -name '*.json' | head -20
```

실제 trial result JSON 키(`agent_result`, `verifier_result.rewards.reward`, `task_name`, agent context 직렬화 위치)를 확인하고 `aggregate.py`의 필드 경로를 실물에 맞게 수정한다. 두 arm에 대해 `python aggregate.py results/jobs`가 2행 이상 출력하면 통과.

- [ ] **Step 5: 결과 기록 + commit**

`benchmarks/terminal_bench/results/phase0-notes.md`에 두 arm의 reward/시간/로그 경로를 기록하고:

```bash
git add -A benchmarks/terminal_bench
git commit -m "bench: phase 0 smoke results (arm a/b, gpt2-codegolf)"
```

---

### Task 10: Phase 1 — mini-suite 매트릭스 실행 + 판결 리포트

**Files:**
- Create: `benchmarks/terminal_bench/results/phase1-report.md`

- [ ] **Step 1: 매트릭스 실행** (24 tasks × 3 attempts × 6 arms; 오래 걸리므로 백그라운드)

```bash
cd benchmarks/terminal_bench
CONCURRENCY=4 ./run_matrix.sh a,b,c,e,f,h 3
```

- [ ] **Step 2: 집계 + 리포트**

`results/phase1-report.md`에 arm별: success rate, wall-clock 중앙값, tokens, tool_calls, duplicate_tool_calls, infra failure 수. 스펙 §6.5 판결 규칙을 그대로 적용: Skills(c vs b), Parallel(e vs d는 생략했으므로 e vs c는 composition 혼재를 명시), 4-keeper(f vs e), Full(h)을 표로 정리. 어느 쪽 결과든 숫자 그대로.

- [ ] **Step 3: Commit**

```bash
git add benchmarks/terminal_bench/results
git commit -m "bench: phase 1 mini-suite results + verdict report"
```

---

## Self-review 메모 (작성 시점 확인 완료)

- 스펙 커버리지: §5 어댑터(Tasks 1-6), §6.2 arms(Task 5), §6.3 메트릭(Tasks 4,6,8,9), §6.4 Phase 0/1(Tasks 9-10). Phase 2/3는 Phase 1 결과 조건부이므로 이 플랜 범위 밖(스펙과 일치).
- D arm과 G arm은 스펙대로 Phase 1 조건부 — run_matrix.sh 인자로 언제든 추가 가능.
- 알려진 미확정 3개(실행 중 확정, 플레이스홀더 아님): ① config ro 마운트 시 rw 사본(Task 7 Step 1에 처리 내장), ② 토큰 usage 소스(Task 7 Step 2), ③ Harbor trial JSON 레이아웃(Task 9 Step 4).
