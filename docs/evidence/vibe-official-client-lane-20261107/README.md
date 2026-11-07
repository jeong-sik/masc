# Vibe 3.1.0 headless 실측 (RFC-vibe-official-client-lane §4 1단계)

`docs/rfc/RFC-vibe-official-client-lane.md` 가 lane 코드보다 먼저 하라고 정한 실측의
기록이다. 해석과 결정은 RFC 에 있고, 이 문서는 무엇을 돌려 무엇을 봤는지만 적는다.

## 환경

- 2026-11-07, macOS(aarch64), `vibe 3.1.0`(PyPI `mistral-vibe` 3.1.0, `uv tool` 설치).
- 자격 증명: `env -u MISTRAL_API_KEY vibe --setup` 이 macOS keychain 에 넣은 항목
  (`svce=ai.mistral.vibe`, `acct=MISTRAL_API_KEY`). 이 문서는 이것을 keychain 자격
  증명이라 부른다. 마법사에서 브라우저 로그인과 키 입력 중 어느 쪽을 골랐는지는
  기록하지 않았다. 그래서 이 자격 증명이 플랜 자격 증명인지는 이 묶음으로 말할 수 없다.
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
  이 칸이 `n/a` 다. `export_seconds` 는 `export.json` 의 `ended_at - started_at` 이다.
- run-l0.sh 는 지금 실행마다 `work.ls`(work 폴더의 `ls -A`)를 남긴다. 이 묶음의 원본은
  그 줄을 넣기 전에 찍었다. 그래서 m1~m11 의 work 폴더는 실행 뒤에 손으로 `ls -A` 했고,
  모두 비어 있었다.

## 관찰

| run | 조건 | exit | `export.json` outcome | 본 것 |
|---|---|---|---|---|
| m0 | 첫 호출, keychain | 0 | finished | `cost_usd 0.0`, `routed_default_model=mistral-large-4-0-3` |
| m1 | `--output streaming` | 0 | finished | 항목마다 한 줄이다(user 메시지·reasoning·assistant 메시지 3줄, 모두 `generationStatus=completed`). 줄의 칸은 m0 `--output json` 배열 원소의 칸과 같다. 짧은 답 하나라 중간 갱신 줄이 나오는지는 보지 못했다 |
| m2 | 모르는 플래그 | 1 | (`export.json` 없음) | 인자 파서 오류(stderr `unexpected argument '--no-such-flag'`). stdout 은 비었다 |
| m3 | 모르는 `--model` | 1 | usage_error | `error.message` 가 쓸 수 있는 별칭으로 glm-5-3, mistral-large-4-0-3, mistral-medium-3.5, zai-glm-5-3-flash 를 나열한다 |
| m4 | env `MISTRAL_API_KEY` 를 남김 | 2 | infrastructure_failure | env 키가 keychain 보다 먼저다. m1·m8 의 stderr 첫 줄 `Reading API keys from the macOS Keychain …` 이 m4 에는 없다. `error.code=backend_error`, message 에 공급자 402 본문 |
| m5 | `--time-limit 1` | 3 | deadline | stderr `Stopped: deadline`. 1초 한도에 3.05초 돌았다(`export_seconds`). stdout 은 비었다 |
| m6 | `--max-price 0.000001` | 0 | finished | `cost_usd 0.0` 이라 가격 상한이 걸리지 않는다 |
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
  - 세션 journal(`session/`)과 `meta.json` 은 계정 사용자 이름과 경로를 담아 넣지 않았다.

## 확인하지 않은 것

- pool 관계는 한 번의 대비(같은 시각 API 402 / Vibe 성공)뿐이다. 공식 문서는
  "monthly usage that is shared across Studio, the API, and Vibe Code" 라고 적는다.
  콘솔 두 막대의 소비 곡선은 재지 않았다.
- 한도 소진·세션 만료의 Vibe 쪽 실패 모양(exit·outcome)은 보지 못했다. 거절을
  만들 방법이 없었다.
- `--disabled-tools` 의 올바른 도구 이름, bash 기본 허용 목록의 범위,
  `--resume`/`--continue`, MCP 브리지, `vibe-acp`·`vibe-app-server` 는 재지 않았다.
- 무인 준비 검사(로그인·플랜 상태)를 부를 argv 는 찾지 못했다.
