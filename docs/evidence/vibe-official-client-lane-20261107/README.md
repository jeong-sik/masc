# Vibe 3.1.0 headless 실측 (RFC-vibe-official-client-lane §4 1단계)

`docs/rfc/RFC-vibe-official-client-lane.md` 가 lane 코드보다 먼저 하라고 정한 실측(L0)의
기록이다. 해석과 결정은 RFC 에 있고, 이 문서는 무엇을 돌려 무엇을 봤는지만 적는다.

## 환경

- 2026-11-07, macOS(aarch64), `vibe 3.1.0`(PyPI `mistral-vibe` 3.1.0, `uv tool` 설치).
- 자격 증명: `env -u MISTRAL_API_KEY vibe --setup` 이 macOS keychain 에 넣은 항목
  (`svce=ai.mistral.vibe`, `acct=MISTRAL_API_KEY`). 이 문서는 이것을 keychain 자격
  증명이라 부른다. 마법사에서 브라우저 로그인과 키 입력 중 어느 쪽을 골랐는지는
  기록하지 않았다. 아래 「L0 뒤 실측」이 키 scope 로 이 자격 증명의 종류를 적는다.
- 계정은 Mistral Pro 플랜 하나다. 같은 시각 masc 의 mistral HTTP 레인
  (env `MISTRAL_API_KEY`)은 402 `billing_api_budget_exhausted` 를 받고 있었다
  (`system_log_2026-11-07.jsonl`, sangsu, 09:10:57Z). 이 로그 줄은 묶음에 없다.
  묶음 안의 대비는 m4 다. 09:21:34Z 에 env 키로 부른 m4 는 같은 402 를 받았고,
  keychain 자격 증명으로 부른 m1·m6·m8 은 그 앞뒤로 exit 0 으로 끝났다.
- m1~m11 은 실행마다 빈 work 폴더와 `--output-dir` 을 썼다. m2 를 뺀 실행은 `--trust`
  도 썼다. m4 를 뺀 모든 실행은 `env -u MISTRAL_API_KEY` 로 env 키를 뺐다.
- user `config.toml` 에는 `theme` 한 줄만 있었다. 도구 승인 값은 Vibe 기본값이다.

## 명령

```sh
bash docs/evidence/vibe-official-client-lane-20261107/repro/run-l0.sh <새 출력 폴더>
python3 -I docs/evidence/vibe-official-client-lane-20261107/repro/sanitize.py \
  <run-l0 출력 폴더> <m0 출력 폴더> <새 bundle 폴더>
```

- m0 은 같은 날 09:14Z 의 첫 호출이다
  (`--agent ask --max-turns 1 --max-price 0.05 --time-limit 120 --output json`).
- m10·m11 은 run-l0.sh 의 첫 실행 뒤에 같은 플래그로 손으로 돌렸다. `repro/run-l0.sh`
  에는 둘 다 들어 있다.
- `summary.tsv` 의 `seconds` 는 run-l0.sh 가 잰 벽시계 시간이다. 손으로 돌린 m10·m11 은
  이 칸이 `n/a` 다. run-l0.sh 로 다시 돌리면 m10·m11 에도 이 칸이 찍힌다. `export_seconds`
  는 `export.json` 의 `ended_at - started_at` 이다.
- run-l0.sh 는 지금 실행마다 `work.ls`(work 폴더의 `ls -A`)를 남긴다. 이 묶음의 원본은
  그 줄을 넣기 전에 찍었다. 그래서 m1~m11 의 work 폴더는 실행 뒤에 손으로 `ls -A` 했고,
  모두 비어 있었다. 이 확인은 묶음에 파일로 남지 않았다.

## 관찰

| run | 조건 | exit | `export.json` outcome | 본 것 |
|---|---|---|---|---|
| m0 | 첫 호출, keychain | 0 | finished | `cost_usd 0.0`, `routed_default_model=mistral-large-4-0-3` |
| m1 | `--output streaming` | 0 | finished | 항목마다 한 줄이다(user 메시지·reasoning·assistant 메시지 3줄, 모두 `generationStatus=completed`). 줄의 칸은 m0 `--output json` 배열 원소의 칸과 같다. 짧은 답 하나라 중간 갱신 줄이 나오는지는 보지 못했다 |
| m2 | 모르는 플래그 | 1 | (`export.json` 없음) | 인자 파서 오류(stderr `unexpected argument '--no-such-flag'`). stdout 은 비었다 |
| m3 | 모르는 `--model` | 1 | usage_error | `error.message` 가 쓸 수 있는 별칭으로 glm-5-3, mistral-large-4-0-3, mistral-medium-3.5, zai-glm-5-3-flash 를 나열한다 |
| m4 | env `MISTRAL_API_KEY` 를 남김 | 2 | infrastructure_failure | env 키가 keychain 보다 먼저다. m1·m8 의 stderr 첫 줄 `Reading API keys from the macOS Keychain …` 이 m4 에는 없다. `error.code=backend_error`, message 에 공급자 402 본문 |
| m5 | `--time-limit 1` | 3 | deadline | stderr `Stopped: deadline`. 1초 한도에 3.05초 돌았다(`export_seconds`). stdout 은 비었다 |
| m6 | `--max-price 0.000001` | 0 | finished | `cost_usd 0.0` 이었고 가격 상한은 걸리지 않았다. 2 step 에 끝나서, 비용이 0 이어서인지 상한 검사가 턴 사이에만 도는지는 가를 수 없다 |
| m7 | `--max-tokens 200` | 3 | token_limit | 한도 200 에 `output_tokens` 845. 답은 1~400 을 다 적었다. `stop_reason=interrupted`. 한도는 넘은 뒤에 멈춘다 |
| m8 | `--agent ask`, bash `echo hi` | 0 | finished | 승인 없이 실행됐다. effect `completed`, `state.decision=execute`, `approvalType=always`, `approvalSource=config` |
| m9 | `-p "/whoami"` | 3 | turn_limit | slash 명령으로 처리되지 않고 모델 프롬프트가 됐다. 모델이 `skill.read`, bash `pwd && ls -la`(m8 과 같은 승인 값)와 도구 검색으로 3턴을 썼다. 입력 64,027 토큰 |
| m10 | `--agent ask`, `touch …` | 0 | finished | effect `failed`, `state.decision=skip`, `approvalType=ask`, `approvalSource=user`, `error.code=tool_denied`("Tool execution denied by approval callback"). work 폴더는 비어 있었다 |
| m11 | `--agent ask`, `--disabled-tools file_system.bash`, `touch …`(m10 에서 `chmod` 를 뺀 명령) | 0 | finished | `config_kept_values.disabled_tools` 에 `file_system.bash` 가 들어갔다. 그래도 모델은 `file_system.bash` 를 불렀고 m10 과 같이 거절됐다 |

`export.json` 의 칸: outcome, stop_reason, error, session_id, usage(input/output/
cached_input/total tokens), cost_usd, steps, config, schema_version(=1), vibe_version,
journal_dir, started_at, ended_at, limits, exit_code.

## 보존한 것과 바꾼 것

- `fixtures/<run>/` 에 stdout·stderr·export.json 을 남겼다.
- 파생본이다. 원본 바이트와 같지 않다.
  - 로컬 경로는 `<run>/…`, 홈은 `~`, 사용자 이름은 `<user>`, 이메일은 `<email>` 로 바꿨다.
    경로는 넘긴 경로와 macOS 가 푼 경로(`/tmp` → `/private/tmp`)를 둘 다 바꿨다.
  - export.json 의 `config`(유효 설정 전체, 로컬 경로 포함)는 칸 이름을 `config_keys_only`
    로 남겼다. 경로가 없는 값 5개(`routed_default_model`, `default_agent`,
    `enabled_tools`, `disabled_tools`, `tools`)는 `config_kept_values` 로 남겼다.
  - m9 stdout(90 KB, 대부분 Vibe 가 읽어 들인 skill 문서)은 `stdout.summary.json` 으로
    바꿨다. 메시지 종류·도구 제목·도구 입력·상태·승인 값만 남겼다.
  - 세션·턴 UUID 는 그대로 남겼다. 그 UUID 가 가리키는 journal 은 넣지 않았다.
    `repro/acp-probe.py` 는 콘솔에 찍을 때만 세션 ID 를 가린다.
  - 세션 journal(`session/`)과 `meta.json` 은 계정 사용자 이름과 경로를 담아 넣지 않았다.

## L0 뒤 실측: vibe-acp 준비 검사와 Vibe 몫 계량기 (2026-11-07 12:1xZ)

- 근거: vibe 3.1.0 설치본의 Python 소스와 아래 두 번의 호출이다. 소스 파일은
  `vibe/setup/auth/auth_state.py`, `vibe/acp/agent.py`, `vibe/app_server/_account.py`,
  `vibe/app_server/_billing.py` 다. 아래 확장 메서드는 공개 문서에 없다. 이 Python
  소스는 `vibe-acp` 의 것이다. `vibe -p` 는 Rust 바이너리(`vibe/_bin/vibe-rs`)를
  실행하고, 그 하위 명령은 `mcp`·`config`·`update` 뿐이다(`vibe --help`).
- `vibe-acp` 의 자격 증명 순서(`assess_auth_state`): 프로세스 env → `~/.vibe/.env` →
  OS keyring. OIDC 를 켜면 OIDC 토큰이 그보다 먼저다(`utils/api_keys.py`).
  상태 종류는 `signed_out`, `auth_not_required`, `os_keyring`, `vibe_home_env_file`,
  `process_env`, `unsupported_provider` 다. 이 계정에는 `~/.vibe/.env` 가 없었다.
- `repro/acp-probe.py` 는 `vibe-acp` 에 `initialize`, `_auth/status`, `session/new`,
  `_account/read` 를 보낸다. 프롬프트를 보내지 않는다. 다섯 번 돌렸고(처음, m12 앞,
  m12 뒤, 스크립트를 고친 뒤 두 번) 모두 `_account/read` 의 답을 받았다. 잰 시간은
  5.0초, 7.4초, 5.8초다. work 폴더는 비어 있었다.
  - 이 호출은 읽기만 하지 않는다. `_account/read` 는 `~/.vibe` 의 whoami 캐시를 다시
    쓰고, `session/new` 는 세션 lease 를 잡는다.
  - `acp/auth-status.json`: `authenticated=true`, `authState=os_keyring`
  - `acp/account-read.shape.json`: `status=ready`, `plan.kind=chat`, `apiKey.scope=vibe`.
    플랜 이름, 키 끝자리, budget 값은 계정 값이라 남기지 않았다.
- 키 종류: Vibe 의 whoami 캐시(`~/.vibe/whoami_cache.json`)에 같은 날 두 항목이 있었다.
  m0 시각(09:14:45Z)의 항목은 `plan_type=chat`, m4 시각(09:21:45Z, env 키)의 항목은
  `plan_type=api` 다. Vibe 소스 주석은 plan_type 이 키 scope 에서 온다고 적는다
  (`chat`↔`vibe`, `api`↔`workspace`). 서버 쪽은 확인하지 않았다. 캐시는 첫
  `vibe-acp` 호출보다 먼저 읽었다. 캐시 파일은 묶음에 넣지 않았다.
- m12(12:17Z, 손으로 돌림, run-l0.sh 에 없음): `env -u MISTRAL_API_KEY vibe --workdir
  <work> --output-dir <out> --trust --agent ask --max-turns 1 --time-limit 120 --output
  json -p "Write the numbers from 1 to 300, one per line."`. 호출 앞뒤로 `_account/read`
  를 읽었다. `budget.usagePercentage` 가 호출 뒤에 올랐다. `export.json` 의 `cost_usd`
  는 0.0 이었다. exit 3 `turn_limit`, 입력 7,938·출력 342 토큰. 계량기 값은 묶음에
  넣지 않았다.
  - Vibe 소스 주석은 이 budget 을 `/v1/billing/budget` 의 `vibe_budget`, 곧
    "monthly Vibe Code allowance" 의 사용량이라 적는다.

## 확인하지 않은 것

- pool 관계: Vibe 호출이 Vibe 몫 계량기를 올리는 것은 한 번 봤다(m12). Vibe 호출이
  API 쪽 계량기를 올리는지, API 키 호출이 Vibe 몫을 올리는지는 재지 않았다. API 키
  예산이 바닥이라 API 쪽 소비를 만들 수 없었고, `_account/read` 는 API 쪽 계량기를
  보여 주지 않는다. 공식 문서는 "monthly usage that is shared across Studio, the API,
  and Vibe Code" 라고 적는다.
- 한도 소진·세션 만료의 Vibe 쪽 실패 모양(exit·outcome)은 보지 못했다. 거절을
  만들 방법이 없었다.
- `--disabled-tools` 의 올바른 도구 이름, bash 기본 허용 목록의 범위,
  `--resume`/`--continue`, MCP 브리지, `vibe-acp` 로 세션을 돌리는 경로,
  `vibe-app-server` 는 재지 않았다.
- `-p` 로 부르는 준비 검사 argv 는 찾지 못했다. `vibe-acp` 확장 메서드는 공개 문서에
  없어서 Vibe 버전이 바뀌면 다시 재야 한다. 만료·취소된 키의 `unauthorized` 응답은
  만들지 않았다(keychain 을 건드리지 않았다).
- `vibe -p`(Rust)가 `~/.vibe/.env` 를 어떻게 읽는지, `vibe-acp` 와 같은 keychain
  항목을 읽는지는 재지 않았다.
