---
rfc: "runtime-settings-have-one-owner"
title: "파일에 키가 있는 설정은 서버를 띄운 셸의 환경변수를 읽지 않는다"
status: Draft
created: 2026-10-29
updated: 2026-10-29
author: claude
related: ["0335", "settings-typed-delivery", "keeper-guests-stay-inside-a-host-memory-budget"]
---

# RFC: 파일에 키가 있는 설정은 서버를 띄운 셸의 환경변수를 읽지 않는다

- 상태: 초안. 이 RFC 를 쓰는 동안 코드는 바꾸지 않았다. 코드에는 임시 처방 #46805 만 있다(§1.3).
- 근거: 코드 사실은 `origin/main` `59faef0be37` 에서 읽었고, 수치는 2026-10-29 에 센 값이다. 시각은 모두 KST 다. 세는 방법은 부록 A.
- 운영자 답(2026-10-29): 근본 개선이 필요하다고 했다. 결정 D1~D3 은 이 문서의 기본안대로 가기로 했다(§8).
- 사람 결정 필요: D4(§8).

## 0. 요약

서버는 같은 설정을 두 곳에서 읽는다. 하나는 `runtime.toml` 이고, 다른 하나는 서버를 띄운 셸의 환경변수다. 환경변수가 이긴다.

`masc restart` 는 부른 셸의 환경변수를 통째로 새 서버에 넘긴다. 그래서 옛 탭에 남은 값이 서버 설정을 덮는다. 10-29 에 `MASC_KEEPER_MICROVM_MEMORY=8g` 가 이렇게 세 번 되살아나 Keeper VM 8개가 8 GiB 로 떴다. 같은 종류의 사고가 봄과 7월에도 있었다.

이 RFC 는 이렇게 바꾼다.

- 설정마다 주인을 하나로 한다. `runtime.toml` 에 키가 있는 설정 38개는 환경변수를 읽지 않는다. 환경변수는 환경 전용 설정 26개(비밀, 경로)만 남는다.
- 강제하는 곳은 읽는 함수 한 군데(`Env_config_core.raw_value_opt`)다. 설정마다 고치지 않는다.
- 레지스트리 밖에서 환경변수를 직접 읽는 곳을 찾아 등록하거나 없애고, 새로 늘지 않게 검사한다.
- 마지막으로 `masc restart` 가 넘기는 환경을 레지스트리에서 만든다.

RFC-0335 가 같은 방향을 7월에 정했지만 코드에 들어간 단계가 없다. 이 RFC 는 0335 의 W2·W3 를 지금 있는 레지스트리 위에서 다시 자른다(§1.4).

## 1. 문제

### 1.1 지금 구조

- 읽는 순서는 `Env_config_core.raw_value_opt` 에 있다. 프로세스 환경변수가 먼저고, 그다음이 서버가 켜질 때 `runtime.toml` 에서 읽어 둔 값(`Config_boot_overrides`)이고, 마지막이 코드 기본값이다. `Keeper_runtime_config.resolve_one` 도 환경변수가 있으면 파일 값을 쓰지 않는다.
- `masc restart` 는 새 서버를 `Unix.environment ()` 로 띄운다(`bin/masc_cli_restart.ml`, 도입 #46367). 부른 셸이 가진 환경 전체가 서버로 간다.
- 터미널 탭의 환경은 탭이 열린 때 정해진다. `.zshenv` 를 고쳐도 열려 있는 탭은 옛 값을 쥐고 있다. 서버를 어느 탭에서 띄웠는지는 서버 어디에도 남지 않는다.
- `runtime.toml` 은 서버가 켜질 때 한 번만 읽는다. 핫리로드는 없다.

### 1.2 사고

| 때 | 일 | 뿌리 |
|---|---|---|
| 봄(이슈 #4568, 2026-04-02 닫힘) | 재시작 뒤 base path 가 물려받은 `MASC_BASE_PATH` 로 바뀜 | 재시작이 환경을 물려줌 |
| 2026-07-09 (RFC-0335) | Slack 토큰이 시작 경로와 부모 셸에 따라 다르게 풀려 Slack 이 끊김 | 설정 원천이 환경과 파일 둘 |
| 2026-10-29 17:48, 18:48, 20:11 | 옛 탭의 `MASC_KEEPER_MICROVM_MEMORY=8g` 가 `masc restart` 로 세 번 서버에 들어가 Keeper VM 8개가 8 GiB 로 뜸 | 같음 |

10-29 의 경우 `.zshenv` 는 오후에 이미 2g 로 고쳐 둔 뒤였다. 열려 있던 탭이 옛 값을 쥐고 있었다.

### 1.3 지금 수습

#46805 가 `microvm_memory`, `microvm_cpus` 두 설정만 환경변수를 읽지 않게 했다(레지스트리의 `Toml_only`). 2026-10-29 22:56 에 병합됐다. 파일에 키가 있는 38개 중 2개다. 나머지 36개(`Toml_and_env`)는 같은 길로 샌다. #46805 의 리뷰어(`code-reviewer`)도 이 점을 짚었다.

### 1.4 RFC-0335 와의 관계

RFC-0335(2026-07-09, Draft)는 설정의 원천을 파일 하나로 모으자고 했고 단계를 W1~W4 로 잘랐다. 방향은 이 RFC 와 같다. 코드에 들어간 단계는 없다. `credentials.toml` 을 읽는 코드가 `lib`, `bin` 에 없다. 0335 가 멈춘 이유는 확인하지 못했다. 한 덩어리가 커서였을 수 있다(추정).

이 RFC 가 0335 와 다른 점은 둘이다.

- 0335 를 쓸 때는 없던 설정 레지스트리가 지금 있다. 파일 소유 여부를 행마다 적어 둔 표라서, 설정마다 고치는 대신 읽는 함수 한 군데에서 강제할 수 있다.
- 자격 증명(W1)과 dotenv 제거(W4)는 이 RFC 범위 밖이다. 자격 증명은 환경 전용으로 남는다.

이 RFC 의 2~3층이 0335 의 W2·W3 에 해당한다.

### 1.5 settings-typed-delivery 와의 관계

RFC settings-typed-delivery(2026-09-02, Draft)는 비목표에 "env 를 입력에서 빼는 것"과 "우선순위 변경(env > TOML > 기본값 그대로)"을 적었다. 운영자가 `export MASC_…` 로 값을 주는 방식을 지키려는 뜻이었다.

이 RFC 는 그 두 항목을 `runtime.toml` 에 키가 있는 설정에 한해 바꾼다(결정 D1). 이유는 §1.2 의 사고다. `export` 로 값을 주는 길을 남기면 옛 탭에 남은 `export` 도 같이 남는다. 그 RFC 의 나머지(설정을 typed 레코드로 읽게 하기)와는 부딪치지 않는다. 그 RFC 의 맨 위에는 이 RFC 를 가리키는 줄을 덧붙인다.

## 2. 현황 수치

| 항목 | 값 |
|---|---|
| 레지스트리 행 | 64. 파일에 키가 있는 설정 38(`Toml_and_env` 36, `Toml_only` 2), 환경 전용(`Env_only`) 26 |
| `raw_value_opt` 가 나오는 줄 | 82 (`lib`, `bin`) |
| 아직 `Toml_and_env` 인 36개 이름을 쓰는 시험 | 파일 37개, 256곳 |
| 위 이름을 환경변수로 쓰는 스크립트·compose | 이름 4개, 파일 33개. `MASC_KEEPER_AUTONOMOUS_ENABLED` 27개 파일, `MASC_OTEL_ENABLED` 8개, `MASC_SEARXNG_URL` 2개, `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC` 2개(한 파일이 여러 이름을 쓰면 겹친다). harness, 스모크, 릴리스 증거 스크립트와 `docker-compose.yml` |
| 환경을 직접 읽는 줄(`Sys.getenv`, `Unix.getenv`, `Unix.environment`) | `lib` 140, `bin` 41. `bin` 에는 클라이언트(CLI, TUI)가 섞여 있다 |
| `lib`, `bin` 에서 파일 키 이름을 문자열 그대로 getenv 하는 곳 | 0 |

## 3. 설계

### 3.1 설정마다 주인이 하나

| 주인 | 레지스트리 표기 | 서버가 읽는 곳 | 예 |
|---|---|---|---|
| 파일 | `Toml_only` | 서버가 켜질 때 `runtime.toml` 에서 읽은 값. 없으면 코드 기본값 | `MASC_KEEPER_MICROVM_MEMORY` |
| 환경 | `Env_only` | 프로세스 환경변수 | 검색 API 키, 토큰 |

`Toml_and_env` 는 없앤다. 호환 읽기나 변환 코드는 만들지 않는다. 한 번에 바꾼다.

### 3.2 읽는 규칙은 한 군데

`raw_value_opt` 가 파일 소유 이름을 받으면 환경변수를 보지 않고, 서버가 켜질 때 읽어 둔 값만 본다. 부르는 82줄은 그대로다.

지금 `raw_value_opt` 안의 두 번째 조회(`Sys.getenv_opt`)는 첫 번째(`Unix.getenv`)와 같은 조회라서 닿지 않는다. 같은 층에서 지운다.

`Keeper_runtime_config.resolve_one` 과 `Config_boot_overrides.source` 의 "환경변수가 먼저" 규칙도 같은 기준으로 맞춘다. #46805 가 넣은 `file_only_env_names` 같은 특수 처리는 일반 규칙으로 대체된다.

### 3.3 읽는 함수가 레지스트리를 모르는 문제

`raw_value_opt` 는 레지스트리보다 아래층이다. 레지스트리가 `Env_config_keeper` 의 읽기 함수를 부르기 때문에 반대 방향으로 부를 수 없다. 파일 소유 이름의 집합을 아래층이 알아야 한다. 방법이 둘이다.

| | (a) 부팅 때 선언 | (b) 표를 아래층에 둔다 |
|---|---|---|
| 방법 | `apply_runtime_toml` 이 시작할 때 레지스트리의 파일 소유 이름을 `Config_boot_overrides` 에 선언한다 | 이름과 TOML 키 표를 `masc_config` 맨 아래 모듈로 옮기고 레지스트리 행이 거기서 가져다 쓴다 |
| 좋은 점 | 레지스트리가 계속 유일한 목록이다. 고칠 곳이 적다 | 선언하기 전이라는 틈이 없다 |
| 나쁜 점 | 선언 전에 읽는 값은 환경변수가 이긴다. 모듈 초기화 때 읽는 곳이 있으면 구멍이다 | 레지스트리 행의 구조를 바꾸는 큰 작업이다 |
| 기본안 | 이쪽 | |

(a) 의 구멍은 두 가지로 줄인다. 파일 소유 설정은 부를 때마다 읽는 쪽으로 이미 짜여 있다(모듈 불러올 때 캐시하지 않는다). 그리고 §7 의 시험이 선언 뒤 값을 확인한다. 모듈 초기화 때 읽는 곳은 3층의 목록에서 함께 찾는다.

`apply_runtime_toml` 은 서버 시작(`Server_runtime_bootstrap`)과 `keeper_capability_probe_cli` 가 부른다. 선언은 그 함수 맨 앞에 둔다.

### 3.4 시험

선언은 `load_and_apply` 가 하므로, 로더를 부르지 않는 시험은 지금과 같이 환경변수가 먼저인 규칙으로 돈다. 로더를 거치는 시험(`test_runtime_toml_overrides`, `test_server_runtime_bootstrap`, `test_keeper_runtime_config_leaf` 등)은 환경변수 대신 `Config_boot_overrides.set` 으로 값을 넣게 바꾼다(#46805 의 시험 helper `with_boot_override`). 로더를 부르지 않으면서 파일 소유 이름을 `putenv` 하는 시험은 (a) 방식의 구멍과 같은 모양이라, 3층의 목록에 넣어 함께 정리한다. 이 이름을 쓰는 시험 파일은 37개(256곳)지만 대부분은 이름을 기대값으로 적거나 로더 없이 읽기만 한다.

### 3.5 스크립트와 compose

스크립트가 서버를 띄울 때는 임시 base path 에 `runtime.toml` 을 쓴다. compose 는 설정 디렉터리를 마운트한다.

33개 파일 대부분은 서버를 임시 base path 에 띄우면서 `MASC_KEEPER_AUTONOMOUS_ENABLED=false` 로 Keeper 자동 시작을 끄는 harness 다. 릴리스 스모크(`release-binary-smoke.sh`, `install-smoke.sh`, `release-evidence.sh`)도 들어 있다. 로컬에서 돌려 보지 않고 한 번에 바꾸기에는 범위가 커서, 이 네 이름은 2b층으로 따로 뺀다(§6). 파일 위치를 정하는 `MASC_BASE_PATH`, `MASC_CONFIG_DIR` 는 파일을 읽기 전에 필요해서 파일 안에 둘 수 없다. 환경 전용으로 남는다. `MASC_BASE_PATH` 는 0335 의 결정 6항과 같다.

### 3.6 레지스트리 밖의 환경 읽기(3층)

`lib` 140줄, `bin` 41줄을 분류한다.

- 클라이언트(CLI, TUI)가 쓰는 값은 서버 설정이 아니므로 범위 밖이다.
- 서버 설정은 `Env_only` 로 등록하거나 `runtime.toml` 로 옮긴다.
- 어디서도 쓰지 않는 읽기는 지운다.

그다음 `lib/` 에서 `Sys.getenv`, `Unix.getenv` 를 `Env_config_core` 와 허용 파일 목록 밖에서 부르면 실패하는 검사를 넣는다. 0335 W3 가 정한 규칙 그대로다.

### 3.7 `masc restart` 가 넘기는 환경(4층)

새 서버에 넘기는 환경을 이렇게 만든다.

- 프로세스 기본: `HOME`, `USER`, `LOGNAME`, `PATH`, `SHELL`, `TMPDIR`, `LANG`, `LC_*`, `SSH_AUTH_SOCK`, `XPC_*`, `__CF_USER_TEXT_ENCODING`. 상수 목록 하나로 둔다.
- 레지스트리의 환경 전용 이름.

3층이 끝나기 전에는 하지 않는다. 레지스트리 밖에서 읽는 값이 빠지면 서버가 조용히 달라진다.

## 4. 하지 않는 것

- 자격 증명을 파일로 옮기기(0335 W1)와 dotenv 제거(W4). 자격 증명은 환경 전용으로 남고, 옛 탭의 낡은 토큰이 새는 길도 남는다.
- `runtime.toml` 핫리로드. 파일은 서버가 켜질 때 한 번 읽는다.
- launchd 도입.
- 클라이언트(CLI, TUI)가 읽는 환경변수.

## 5. 트레이드오프와 고르지 않은 안

얻는 것

- 서버를 어느 탭, 스크립트, 컨테이너에서 띄워도 같은 설정으로 뜬다.
- 설정을 더할 때 레지스트리에 한 줄만 쓰면 보호도 따라온다. 행마다 따로 고치지 않는다.

잃는 것

- 환경변수로 하던 일회성 실험이 막힌다. 파일을 고치고 서버를 다시 띄워야 한다. 파일을 켤 때 한 번만 읽으니, 다시 띄우는 일은 지금과 같다.
- 시험 37개 파일과 스크립트·compose 를 고쳐야 한다.
- 3층이 끝나기 전에는 레지스트리 밖의 값이 여전히 샌다.
- 자격 증명은 이 RFC 로 풀리지 않는다.

고르지 않은 안

| 안 | 고르지 않은 이유 |
|---|---|
| 설정마다 `Toml_only` 로 바꾼다(#46805 방식) | 한 번에 한 행이라 36개가 남는다. 새 행을 쓰는 사람이 기존 행을 보고 `Toml_and_env` 로 쓰기 쉽다 |
| `masc restart` 만 고친다 | 직접 실행, 스크립트, 컨테이너에서는 여전히 샌다. 허용 목록에서 빠진 변수는 서버를 조용히 바꾼다 |
| 서버가 자기 환경으로 스스로 다시 실행한다 | 탭의 영향은 없어지지만 종료, 포트 재사용, Eio 도메인 정리를 다시 짜야 한다. 이 RFC 범위 밖이다 |
| 환경과 파일 값이 다르면 부팅을 거부한다 | 옛 탭 때문에 서버가 안 뜨는 일이 생기고, 막는 장치만 늘어난다 |

## 6. 층

각 층은 앞 층 위에 쌓는 PR 하나다. 로컬 전체 빌드 없이 CI 로 확인한다.

| 층 | 내용 | 확인 |
|---|---|---|
| 1 | 이 RFC | 문서 검사 |
| 2a | 읽는 함수 한 군데에서 강제한다. `Config_boot_overrides` 에 파일 소유 이름을 선언하고 `raw_value_opt` 가 따른다. 스크립트가 쓰지 않는 32행을 `Toml_only` 로 바꾸고 로더를 거치는 시험을 옮긴다. #46805 의 특수 처리를 일반 규칙으로 대체하고 `docs/ENV-CONTRACT.md` 와 헤더 주석을 고친다 | §7 의 엉뚱한 환경값 시험, `Test` 워크플로 |
| 2b | 스크립트가 쓰는 네 이름(4행)을 `Toml_only` 로 바꾸고, 스크립트 33개와 compose 를 `runtime.toml` 쓰기로 옮긴 뒤 `Toml_and_env` 를 지운다 | 옮긴 스크립트 중 돌려 볼 수 있는 것은 돌린다. 릴리스 스모크는 따로 표시한다 |
| 3 | 레지스트리 밖의 서버 쪽 환경 읽기를 등록하거나 지우고, 새로 늘면 실패하는 검사를 넣는다 | 검사의 시험, 분류 목록 |
| 4 | `masc restart` 가 넘기는 환경을 레지스트리에서 만든다 | 환경 만들기 순수 함수 시험, 재시작 뒤 서버 환경 이름 확인 |

## 7. 검증

- 엉뚱한 환경값 시험: 레지스트리의 파일 소유 행마다 환경변수에 기본값과 다른 값을 둔 채 `effective` 를 읽고, 값이 파일 값이나 기본값 그대로인지 본다. 기본값과 다른 값은 행의 `value_kind` 와 `default` 로 만든다. 목록이 레지스트리에서 나오므로 행을 더하면 시험도 따라온다.
- 옛 탭 시험: `MASC_KEEPER_MICROVM_MEMORY=8g` 를 둔 채 부팅 읽기 경로를 돌려 게스트 크기가 파일 값인지 본다. #46805 의 시험에 일부 있다.
- 4층: 환경 만들기 함수에 파일 소유 이름이 든 환경을 주면 결과에 그 이름이 없는지 본다.
- 문서: `docs/ENV-CONTRACT.md` 의 우선순위 설명을 2a층에서 고친다.
- 운영 확인: 재시작 뒤 `ps eww -p <pid>` 로 서버 환경의 변수 이름을 본다. 값은 읽지 않는다. 값에 토큰이 있다. 서버 로그의 `runtime.toml: applied N override(s)` 수도 본다.

## 8. 결정

| | 내용 | 상태 |
|---|---|---|
| D1 | `Toml_and_env` 를 없애고 파일 소유 설정 전부 환경변수를 읽지 않는다. 대안은 일부에 환경 덮어쓰기를 남기는 것 | 정함(2026-10-29, 운영자) |
| D2 | 레지스트리 밖 환경 읽기(3층)는 이 RFC 의 뒤 층으로 둔다. 대안은 1~2층만 하고 3층을 별도 RFC 로 빼는 것 | 정함(2026-10-29, 운영자) |
| D3 | #46805 는 임시 처방이다. 병합됐으니(2026-10-29 22:56) 본문에 `WORKAROUND` 표시와 이 RFC 를 적고, 2층이 병합될 때 특수 처리를 일반 규칙으로 바꾼다 | 정함. 병합이 라벨보다 먼저였다 |
| D4 | 파일 소유 이름을 아래층에 알리는 방법. (a) 부팅 때 선언(기본안), (b) 표를 아래층에 둔다(§3.3) | 열림 |
| D5 | 0335 의 W1(자격 증명 파일)을 이 RFC 뒤에 이어서 할지 | 열림. 이 RFC 에는 영향이 없다 |
| D6 | 2b층에서 스크립트 33개를 옮기는 방식. 스크립트마다 `runtime.toml` 을 쓰는 공용 함수(셸 하나, 파이썬 하나)를 두거나, 서버를 띄우는 harness 공용 코드(`scripts/harness/lib/server_bootstrap.sh`)에 한 번만 넣는다 | 열림. 2b층을 시작할 때 정한다 |

## 9. 되돌리기

각 층은 PR 하나라서 되돌릴 수 있다. 호환 읽기를 만들지 않으므로 2층을 되돌리면 환경변수 덮어쓰기가 다시 열린다. 2층의 변경 기록(Upgrade notes)에 "파일 소유 설정의 환경변수는 무시된다. `runtime.toml` 로 옮겨라"를 적는다.

## 부록 A. 세는 방법

- 레지스트리 행: `lib/config/keeper_runtime_setting_registry.ml` 에서 `~exposure:(Toml_and_env "k")`, `~exposure:(Toml_only "k")`, `~exposure:Env_only` 를 센다. `~env_name` 이 문자열이 아니라 상수인 행은 상수의 정의(`let <이름> = "MASC_..."`)를 찾아 이름을 푼다.
- `raw_value_opt` 줄: `rg -n raw_value_opt lib bin --glob '*.ml'`.
- 시험: 아직 `Toml_and_env` 인 36개 이름을 `test/` 에서 `rg -c -F` 로 센다.
- 스크립트·compose: `.github scripts Makefile Dockerfile docker-compose.yml sandbox-images deploy ops` 에서 같은 이름을 센다.
- 환경 직접 읽기: `rg -n 'Sys\.getenv(_opt)?\b|Unix\.getenv\b|Unix\.environment' lib bin --glob '*.ml'`.
