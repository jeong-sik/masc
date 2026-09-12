# 설치/첫 실행이 사소한 잔재에 막히지 않게 하는 설계 (0.35.3 후보)

날짜: 2026-09-10
계기: v0.35.2를 다른 컴에 설치할 때 ① setup이 "Model connection failed"로 막히고 ② 서버가 안 뜨고 ③ TUI가 `Unix.EMFILE`로 죽은 사건. 사용자 요구: "install에서 막히는 경우가 앞으로는 자동으로 잘 해결되었으면".

## 이번에 실제로 막힌 지점들 (2026-09-10, vincent 맥, 전부 실측)

1. **overlay 설정 하나가 전부를 멈춤**: 이전 dev 빌드가 남긴 `.masc/config/agent-core-models-overlay.toml`의 unknown 필드(`supports_extended_thinking` 등) → `configure_agent_core_model_catalog_overlay`가 `Config_error` raise → 서버 부팅 fatal(`server_runtime_bootstrap.ml:118-121`).
2. **Claude Code가 깔려 있어도 못 봄**: `setup_validate_runtime`(`bin/main_eio.ml:2545-2556`)은 overlay 설정이 `Runtime.load_list`보다 먼저라, overlay 실패 시 어떤 runtime도 로드/검증하지 못한다. 설치된 Claude Code는 무관하게 전멸.
3. **에러 라벨이 거짓말**: 실제 원인은 설정 parse 실패인데 "Model connection failed"로 표시. 운영자는 모델/자격증명만 들여다보게 된다.
4. **서버가 안 뜨면 TUI가 죽음**: refresh tick(2초)마다 표면 GET ~9개 → `pool.ml` `create_fresh`(`Piaf.Client.create ~sw`) connect 실패 경로가 소켓을 해제하지 못해 요청당 fd 1개 누수 → stock macOS(ulimit 256)에서 1분 내 EMFILE. 로컬 재현으로 실측(죽은 포트: fd 50→554/120초, 살아있는 서버: 20개 평탄).
5. **설치 후 bare `masc`가 base path를 모름**: install/setup은 선택한 workspace에 config까지 심지만, 그 경로를 나중에 CLI가 읽는 곳에 기록하지 않는다. base-path 해소는 `MASC_BASE_PATH_INPUT` → `MASC_BASE_PATH` env 뿐(`env_config_core.ml:410-416`)이라, "configuration later"로 설치를 끝내면 bare `masc`/`masc start`는 `MASC_BASE_PATH is not set`으로 즉사한다.

## PR A — overlay/설정 parse 실패의 자동 디그레이드

**가장 우선. 이것이 install을 막은 직접 원인.**

- agent_core `Model_catalog`에 lenient 로드 경로 추가: 유효 엔트리는 적용, 불량 엔트리는 `(entry_id, error)` 목록으로 반환. 기존 strict `load_file` 유지.
- server bootstrap의 **overlay 경로만** lenient 적용, 건너뛴 엔트리마다 WARN. 다음은 기존대로 fatal 유지:
  - overlay 파일이 아예 읽히지 않거나 TOML이 깨진 경우
  - `AGENT_CORE_MODEL_CATALOG` full-replacement 경로(SSOT 보호)
- 헌법 `strict_parse_no_default`와의 관계: 도메인 상태 decode(Goal status 등)는 strict 유지. overlay는 부가 메타데이터이며 "기본값으로 눌러 담기"가 아니라 "엔트리를 시끄럽게 제외". 대안(fatal 유지 + `--accept-overlay-quarantine` 플래그)은 수동 개입이 필요해 "자동 해결" 요구에 못 미쳐 기각.

## PR B — setup 에러 귀인 정확성

- `setup_validate_runtime`이 `Runtime.load_list`/overlay 설정의 `Config_error`를 "Model connection failed"로 뭉뚱그리지 않고, **설정 로드 실패는 설정 실패로** 보고하게 한다: 실패한 파일 경로 + 사유 + 다음 행동(파일을 치우거나 `masc runtime-verify`로 재확인)을 인쇄.
- 모델 probe 실패(진짜 연결 문제)와 설정 로드 실패를 별도 메시지로 분리. exit code는 둘 다非0 유지(동작 변경 없음, 메시지만 정확하게).
- 작은 PR. 테스트: 중독 overlay를 놓고 setup_validate_runtime을 돌리면 출력이 "Model connection"이 아니라 설정 파일 경로를 가리키는 것.

## PR C — 죽은 서버 fd 누수 제거

- **클라이언트별 소켓 소유권**: TCP probe는 단명 child switch에서 수행한다. 실제 `Piaf.Client.create`도 별도 child switch에서 수행하고, 생성 실패·취소 때 그 switch를 닫는다. 성공한 클라이언트는 같은 switch를 유지하며 pool에서 재사용하고, eviction·shutdown 때 취소와 정리를 끝까지 기다린다. TLS 실패나 취소의 소켓 정리를 probe 성공 여부에 맡기지 않는다.
- **호스트별 connect-failure 백오프**: 보고된 실패 이후 cooldown 동안 후속 요청이 소켓 생성 없이 fast-fail한다. 동시에 시작한 요청까지 직렬화하지 않으며, 백오프는 소켓 회수를 보장하는 수단이 아니다. cooldown 값은 기존 pool config 필드를 사용한다.
- 회귀 테스트: cooldown을 끄고 도달 불가 포트·잘못된 TLS 응답·TLS handshake 중 취소를 각각 반복한 뒤 프로세스 fd 수를 확인한다. 정상 HTTP 연결 재사용과 shutdown도 확인한다. 테스트 코드 추가와 실제 실행 결과는 구분하며, TLS 누수 여부의 실측 판정은 해당 커밋의 CI 결과가 필요하다. 선례: `test/test_keeper_fd_pressure_fleet.ml`.
- Piaf는 upstream 고정(`piaf (= 0.2.0)`)이라 masc 쪽에서 감내. upstream 기여는 별건.

## PR D — 설치가 workspace를 기억하게 (bare `masc` 동작)

- **persisted default base path**: `masc setup` 및 `masc init --record-default` 성공 시, 그리고 `masc start --record-default` (또는 bare `masc --record-default`)로 지정하여 부팅할 때, 해소된 절대경로를 사용자 전역 위치에 기록한다 (`--record-default`는 opt-in으로 임시 workspace 오염 방지, #35101/#35147). 후보 위치: `$XDG_CONFIG_HOME/masc/default-base-path`(기본 `~/.config/masc/default-base-path`). 기록 파일을 base path 안에 두면 base path 자체와 헷갈리므로 바깥에 둔다.
- **해소 순서 확장** (`env_config_core.base_path_source_opt`): `--base-path` 플래그 > `MASC_BASE_PATH_INPUT`/`MASC_BASE_PATH` env > persisted default > 기존 에러. env/flag는 항상 이긴다(명시가 기록을 덮는다).
- **stale 방어**: 기록된 경로가 더 이상 `.masc`를 품고 있지 않으면 무시하고 기존 에러 메시지에 "기록된 기본값 X가 유효하지 않아 무시했다"를 덧붙인다. uninstall은 자기가 지우는 workspace를 가리키는 기록을 함께 제거한다.
- 비목표: cwd walk-up 자동 감지(별도 논의; blast radius가 커서 이번엔 뺀다).

## 비목표

- TUI 재연결 백오프, TUI 자동시작 실패 가시화 — 좋지만 이번 사건의 뿌리가 아니므로 후속.
- install.sh의 checksum 게이트 완화 — 정상 동작이었음(미발행 버전 설치 시도였음).
- base path의 cwd walk-up 자동 감지.

## 검증 계획

- PR A: 중독 overlay로 서버 부팅 시 부팅 성공 + 엔트리별 WARN을 CI 테스트로. full-replacement는 여전히 fatal임도 테스트.
- PR B: setup 출력이 설정 파일 경로를 가리키는지 테스트.
- PR C: 새 회귀 테스트가 수정 전엔 실패, 후엔 통과를 CI로 확인.
- PR D: 기록된 default base path가 env 없이도 `masc start`를 성공시키고, env/flag가 그것을 이기고, stale 경로는 무시되는 것을 CI 테스트로.

## 진행 방식

- 헌법 실행 프로토콜: 독립 수정이므로 main 기반 별도 PR 4개. 로컬 빌드 없이 CI를 경계에서 사용. 작업 간 적대적 리뷰 에이전트 병렬 부착.
- 순서: A(install 언블록) → B(메시지 정확성) → D(workspace 기억) → C(fd 누수).
