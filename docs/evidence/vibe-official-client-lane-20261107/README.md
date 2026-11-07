# Vibe 3.1.0 headless 실측 (RFC-vibe-official-client-lane §4 1단계)

`docs/rfc/RFC-vibe-official-client-lane.md` 가 lane 코드보다 먼저 하라고 정한 실측의
기록이다. 해석과 결정은 RFC 에 있고, 이 문서는 무엇을 돌려 무엇을 봤는지만 적는다.

## 환경

- 2026-11-07, macOS(aarch64), `vibe 3.1.0`(PyPI `mistral-vibe` 3.1.0, `uv tool` 설치).
- 자격 증명: `env -u MISTRAL_API_KEY vibe --setup` 이 macOS keychain 에 넣은 항목
  (`svce=ai.mistral.vibe`, `acct=MISTRAL_API_KEY`). 마법사에서 브라우저 로그인과
  키 입력 중 어느 쪽을 골랐는지는 기록하지 않았다.
- 계정은 Mistral Pro 플랜 하나다. 같은 시각 masc 의 mistral HTTP 레인
  (env `MISTRAL_API_KEY`)은 402 `billing_api_budget_exhausted` 를 받고 있었다
  (`system_log_2026-11-07.jsonl`, sangsu, 09:10:57Z).
- 실행마다 빈 work 폴더, `--trust`, `--output-dir` 을 썼다. m4 를 뺀 모든 실행은
  `env -u MISTRAL_API_KEY` 로 env 키를 뺐다.

## 명령

```sh
bash docs/evidence/vibe-official-client-lane-20261107/repro/run-l0.sh <새 출력 폴더>
python3 -I docs/evidence/vibe-official-client-lane-20261107/repro/sanitize.py \
  <run-l0 출력 폴더> <m0 출력 폴더> <새 bundle 폴더>
```

- m0 은 같은 날 09:14Z 의 첫 호출이다
  (`--agent ask --max-turns 1 --max-price 0.05 --time-limit 120 --output json`).
- m10·m11 은 run-l0.sh 의 첫 실행 뒤에 같은 플래그로 손으로 돌렸다. 그래서
  `summary.tsv` 의 시간 칸이 `n/a` 다. `repro/run-l0.sh` 에는 둘 다 들어 있다.

## 관찰

| run | 조건 | exit | `export.json` outcome | 본 것 |
|---|---|---|---|---|
| m0 | 첫 호출, keychain | 0 | finished | `cost_usd 0.0`, `routed_default_model=mistral-large-4-0-3` |
| m1 | `--output streaming` | 0 | finished | 한 줄에 한 메시지. 줄의 모양은 `--output json` 배열의 원소와 같다 |
| m2 | 모르는 플래그 | 1 | (export 없음) | 인자 파서 오류. `--output-dir` 에 아무것도 안 쓴다 |
| m3 | 모르는 `--model` | 1 | usage_error | `error.message` 가 쓸 수 있는 별칭을 적는다: glm-5-3, mistral-large-4-0-3, mistral-medium-3.5, zai-glm-5-3-flash |
| m4 | env `MISTRAL_API_KEY` 를 남김 | 2 | infrastructure_failure | env 키가 keychain 보다 먼저다(keychain 안내 줄이 없다). `error.code=backend_error`, message 에 공급자 402 본문 |
| m5 | `--time-limit 1` | 3 | deadline | stderr `Stopped: deadline` |
| m6 | `--max-price 0.000001` | 0 | finished | `cost_usd 0.0` 이라 가격 상한이 걸리지 않는다 |
| m7 | `--max-tokens 200` | 3 | token_limit | `stop_reason=interrupted` |
| m8 | `--agent ask`, bash `echo hi` | 0 | finished | 승인 없이 실행됐다(effect `completed`) |
| m9 | `-p "/whoami"` | 3 | turn_limit | slash 명령으로 처리되지 않고 모델 프롬프트가 됐다. 도구를 찾으며 3턴, 입력 64,027 토큰 |
| m10 | `--agent ask`, `touch …` | 0 | finished | effect `failed`, `error.code=tool_denied`("Tool execution denied by approval callback"), `_meta.approval.decision=skip`. 파일이 생기지 않았다 |
| m11 | m10 + `--disabled-tools file_system.bash` | 0 | finished | m10 과 같은 거절. 이 이름으로는 도구가 빠지지 않았다 |

`export.json` 의 칸: outcome, stop_reason, error, session_id, usage(input/output/
cached_input/total tokens), cost_usd, steps, config, schema_version(=1), vibe_version,
journal_dir, started_at, ended_at, limits, exit_code.

## 보존한 것과 바꾼 것

- `fixtures/<run>/` 에 stdout·stderr·export.json 을 남겼다.
- 파생본이다. 원본 바이트와 같지 않다.
  - 로컬 경로는 `<run>/…`, 홈은 `~`, 사용자 이름은 `<user>`, 이메일은 `<email>` 로 바꿨다.
  - export.json 의 `config`(유효 설정 전체, 로컬 경로 포함)는 칸 이름만 `config_keys_only` 로 남겼다.
  - m9 stdout(90 KB, 대부분 Vibe 가 읽어 들인 skill 문서)은 메시지 종류·도구 제목·상태만 남긴 `stdout.summary.json` 으로 바꿨다.
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
