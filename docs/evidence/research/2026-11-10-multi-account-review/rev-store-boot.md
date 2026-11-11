> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

기준 head `85b8af5b0453`(브랜치 `feat/authz-f3a-off-command-20261110`, 16:53 KST에 `git rev-parse`로 다시 확인) · 확인 시각 2026-11-10 16:53 KST · 읽은 방식: `rg`와 파일 읽기만. 빌드·시험·서버 실행 없음, 저장소 파일 변경 없음.

# 적대적 리뷰: 권한 로그 · 외부 저장소 · 부팅 판정

- worktree: `.worktrees/authz-d1-1-20261108`. 아래 경로는 모두 이 아래다.
- 설계: `docs/superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md`
- 계획: `docs/superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md`
- 모든 판단은 코드를 읽고 따라간 것이다. 실행해서 재현한 것은 하나도 없다. "재현 조건"은 읽어서 얻은 입력이다. 이 파생본은 「깨지는 입력」 문단의 번호 붙은 단계를 지우고 「무엇이 틀렸나」로 줄였다.
- 검토는 끝났다. 남은 범위는 맨 아래 "읽지 않은 것"에 있다.

## 요약

| # | 등급 | 한 줄 | 신뢰도 |
|---|---|---|---|
| 1 | P1 | `맞음`이 마지막 `Committed`만 본다. 설계가 요구한 epoch 대조가 없고 저장소 mode도 대조하지 않는다 | 사실 high, 심각도 medium |
| 2 | P1 | 요청 게이트가 `Authz_zone.revocation`을 묻지 않아, 막힌 principal과 멈춘 파일을 보지 못한다 | medium-high |
| 3 | P2 | 저장소가 없을 때 8행(`AuthorizationUncertain`)이 "로그를 읽지 못함" 거부로 바뀌는 로그가 있다 | medium-high |
| 4 | P2 | lease 배타가 `MASC_BASE_PATH_LEASE_DIR` 값이 같다는 데 달려 있다 | medium |
| 5 | P3 | CLI 명령마다 로그·저장소를 두 번 통째로 읽는다. 열 때 메모리는 파일 크기만큼이다 | high |
| 6 | P3 | 지우는 startup sweep이 부팅 판정보다 먼저 돈다 | low |
| 7 | P3 | host tool은 lease 없이 한 번 판정하고 그 결과를 끝까지 쓴다 | low |
| 8 | P3 | Keeper 재배정은 intent가 없어 되감겨도 모른다 | medium |

P0(오늘 도는 경로에서 틀린 것)는 찾지 못했다. 오늘 도는 경로는 서버·stdio 부팅과 `masc auth bootstrap|invite|off|preview`다. fail-open 부팅, 답한 레코드를 잃는 꼬리 자르기, 모르는 값을 허용으로 바꾸는 catch-all은 없다.

---

## 발견

### 1. [P1] `맞음`이 설계보다 약하다

- 신뢰도: 사실 high, 심각도 medium
- 근거
  - `lib/auth/authz_high_water.ml:114-118` `check_commit`은 마지막 `Committed`가 로그에 있는지만 본다.
  - `lib/auth/authz_high_water.ml:156-161` `judge`는 그 검사와 대기 중 intent 판정만으로 `Matches`를 낸다.
  - `lib/auth/authz_high_water.mli:78-79` "The epoch values that design 5.1 compares as well are not part of the store yet, so this module does not compare them."
  - `lib/auth/authz_boot_mode_read.ml:126` 부팅이 이 `judge`를 그대로 쓴다.
  - 설계 257줄: `맞음`은 "외부 고수위와 replay의 epoch 값이 같다"까지 요구한다.
  - 계획 161·171·223줄: epoch 항목과 비교 판정은 B3c가 더한다고 적었다. F3a-2까지 왔는데 없다. 다음 층 S1이 7행을 서빙한다.
  - 저장소는 자기 mode를 접어서 들고 있다(`lib/auth/authz_external_store.ml:164-173`, `198-219`). 부팅은 그 값을 로그의 mode와 대조하지 않는다. `rg`로 `authz_boot_mode_read.ml`·`authz_high_water.ml`·`authz_zone.ml`에서 저장소 mode를 읽는 곳이 없음을 확인했다. workspace는 마지막 `Committed`가 로그에 있으면 해시 체인이 대신 고정한다.
- 무엇이 틀렸나 A (저장소가 답하지 않은 모드 사건): 끈 설치의 로그 끝에 모드 사건 한 줄이 덧붙으면, 저장소가 답한 적이 없는데도 부팅 판정이 그 설치를 다계정으로 읽는다. 체인 해시는 키 없는 SHA-256이라 파일 내용만으로 계산된다(`lib/auth/authz_record.ml:249`).
  - replay가 그 줄을 받는다: `lib/auth/authz_state.ml:650-651`은 모드 사건을 어느 mode에서나 읽고, `lib/auth/authz_mode_state.ml:70`은 `Off, Reactivate -> Multi_account`다. 이 빌드에 `reactivate`를 쓰는 코드는 없다.
  - 저장소의 마지막 `Committed`(Off 레코드)는 로그에 있다 → `Matches`. 로그 mode는 `Multi_account` → 7행.
  - 결과(오늘): 서버는 `Multi_account_not_served`로 멈춘다. `masc auth invite`와 `masc auth preview`는 7행을 조건으로 돈다(`lib/auth/authz_activation.ml:180-195`). 초대 발급은 intent가 없어 저장소에 닿지 않는다. 저장소는 mode가 Off여도 권한 intent를 받는다(`lib/auth/authz_external_store.ml:170-173`). 그래서 입장·세션도 통과한다.
  - 결과(S1부터): 서버가 7행으로 다계정을 서빙한다. 설계 §10.5의 `Recovery_manifest`·`Pending` 절차를 건너뛴다. `lib/auth/authz_off.mli:1-3`의 "nothing in this build turns them on again"이 깨진다.
  - 저장소가 이 어긋남을 처음 알아채는 때는 다음 모드 intent다. 예: 다시 `masc auth off`를 돌리면 저장소 mode가 이미 Off라 `Intent_pending`이 거절된다.
- 무엇이 틀렸나 B (저장소만 되돌아감): 외부 저장소 파일이 옛 사본으로 돌아가도(예: 홈 디렉터리 복원이 저장소까지 되돌림), 옛 사본의 마지막 `Committed`가 지금 로그에 있으면 `Matches`이고 7행이다. 그 뒤 base path까지 옛 시점으로 되돌아가도 `Matches`인 구간이 있다. 되살아난 grant·세션·Admin 지정을 알아채지 못한다.
- 계획 §7과의 차이: §7-2가 받아들인 한계는 "설정 디렉터리와 base path에 모두 쓸 수 있는 쪽"이다. A는 base path만 쓰면 된다. B는 저장소만 되돌아가면 된다.
- 단서: base path에 쓸 수 있는 쪽은 `.masc/accounts`와 `config.json`에도 이미 닿는다. A의 실제 권한 상승은 작다. 깨지는 것은 "끈 설치는 저장소가 답한 `reactivate` 없이 켜지지 않는다"는 무결성이다. 심각도는 이 위협 모델을 어떻게 보느냐에 달렸다.
- 방향(제안): 부팅 판정에서 저장소 mode와 로그 mode가 다르면 `Mismatch`로 읽는 검사는 지금 있는 값만으로 된다. epoch 항목은 계획이 적은 대로 저장소 형식이 바뀌는 hard cut이다.

### 2. [P1] 요청 게이트가 `Authz_zone.revocation`을 묻지 않는다

- 신뢰도: medium-high(코드 사실), 설계가 읽기 경로까지 막으라는 뜻인지는 medium
- 범위 주의: 검토 목록 밖의 인접 코드다. snapshot을 읽는 곳을 따라가다 나왔다.
- 근거
  - `lib/auth/authz_zone.mli:65-66` "The snapshot does not say that a file stopped." 게이트 값은 `revocation`으로 묻게 돼 있다(`lib/auth/authz_zone.ml:164-174`). 멈춘 로그·멈춘 저장소·어긋난 파일·답 없는 저장소는 `Unknown_*`다.
  - 계획 195줄: "snapshot은 파일이 멈춘 것을 담지 않아서(B3b), 값을 snapshot에서 바로 읽지 않는다."
  - `Authz_zone.revocation`을 부르는 곳은 둘뿐이다: `lib/auth/authz_login.ml:82-84`(로그인 때), `lib/auth/authz_keeper_turn.ml:102-133`(Keeper 턴 판정).
  - 요청 인증은 state만 받는다: `lib/auth_gate.ml:197-215` `authenticate state`, `lib/server/server_login_http.ml:237-248` `as_gated`.
  - 세션: `lib/auth/authz_browser_session.ml:130-141`은 `Subject.Session`의 막힘과 `is_active`만 본다.
  - PAT: `lib/auth/authz_pat.ml:92-95`는 `Subject.Pat`의 막힘과 `is_active`만 본다.
  - Service credential: `lib/auth/authz_service_credential.ml:92-94`는 그 credential의 막힘만 본다.
  - 막힘은 subject가 정확히 같을 때만 선다(`lib/auth/authz_state.ml:50-52`). `is_active`는 `status`만 본다(`lib/auth/authz_principal_state.ml:57-61`). 역할도 같다(`lib/auth_gate.ml:160-164`의 `is_admin`).
  - `lib/runtime/runtime_account_access.ml:242-246` `Own_account`는 snapshot에서 `status = Active`만 본다.
- 무엇이 틀렸나 A (막힌 principal): 사람의 Disable·Delete나 Admin 회수는 subject가 `Subject.Principal`이다(Admin 회수 `lib/auth/authz_state.ml:381`, Disable·Delete `400`). `Intent_pending`이 저장소에 들어간 뒤 로그 append가 실패하면(`lib/auth/authz_zone.ml:366-380`) 구역은 그 사람의 막힘을 바로 발행한다. 설계 §8.3의 기대는 재시도나 적격 Admin의 취소 전까지 게이트에서 막히는 것이다. 실제로는 그 사람의 새 로그인이 `Blocked`이고, 그 사람이 작성자인 레코드가 거절되고(`lib/auth/authz_state.ml:721-736`), Keeper 턴도 거절된다. 그런데 그 사람의 기존 쿠키·PAT는 요청 게이트를 통과한다. 로그에 레코드가 없어 `status`는 `Active`이고, Admin 지정을 회수하던 사람이면 Admin 집합에도 남아 역할이 `Admin`으로 나온다. `Own_account`로 자기 계정의 공식 클라이언트 실행과 verification 호출도 시작한다(`lib/server/server_setup_account_login.ml:185,446`).
- 무엇이 틀렸나 B (멈춘 파일): 서빙 중인 프로세스의 로그가 `Diverged`나 쓰기 실패로 멈추면 Keeper 턴과 로그인은 `Unreadable`/`Uncertain`으로 거절된다. 세션·PAT 요청은 멈추기 전 snapshot으로 계속 인증된다.
- 닿는 경로: 오늘은 `masc auth preview`뿐이다(`bin/masc_cli_auth.ml:214-227`이 `Server_login_http` 경로를 올린다). S1부터는 서버다.
- 단서: 설계 §8.3의 글자는 "새 dispatch·lease·tool effect"다. 계획 214줄은 레코드 작성까지 넓혔다. 읽기 경로와 역할 판정까지 막을지는 적혀 있지 않다. 로그인은 막고 기존 세션은 통과시키는 지금 동작은 한쪽으로 정해야 한다.

### 3. [P2] 8행이 로그 읽기 실패로 바뀐다

- 신뢰도: medium-high
- 근거
  - `lib/auth/authz_boot_mode_read.ml:110-115` 저장소가 없거나(`Ok None`) 못 읽으면(`Error _`) 로그를 `S.State.empty`로 replay한다.
  - `lib/auth/authz_zone.ml:36-43` replay의 막힘은 저장소의 `Aborted_intent` 목록에서만 나온다.
  - `lib/auth/authz_state.ml:748-766` `closes`가 가리키는 막힘이 없으면 `Closes_not_held`다. `472-504` 취소도 같다(`Cancel_not_held`).
  - `lib/auth/authz_boot_mode_read.ml:119` replay 실패는 `Log_unreadable`이다. `lib/auth/authz_boot_mode.ml:103-104`가 설정과 상관없이 거부한다.
- 무엇이 틀렸나: 축소 사건의 append가 한 번 실패한 뒤 재시도하거나 취소한 설치는 로그에 `closes`가 붙은 재시도 레코드나 `Revocation_cancel` 레코드가 있다. 설정이 `Multi_account`인 그 설치에서 외부 저장소가 없으면(볼륨 유실, 설치 기록 유실) 아래 결과가 난다. 저장소를 못 읽거나 `Aborted_intent`가 빠진 옛 사본이어도 같다.
- 결과: 설계 표 8행은 `AuthorizationUncertain`으로 시작이다. 코드는 "authorization log cannot be read"로 부팅을 거부한다. 로그 파일은 멀쩡한데 원인으로 로그를 가리킨다.
  - `masc auth off`도 `Store_absent` 대신 `Log_unreadable`을 말한다(`lib/auth/authz_off.ml:51`).
  - 이 로그는 저장소 없이는 다시 읽히지 않는다. 끄는 길도 막힌다.
- 영향: fail-closed다. 오늘은 문구만 틀린다(7·8행 모두 멈춘다). S1이 8행에서 무언가를 서빙하기 시작하면 동작이 갈린다.
- 닿는 경로: 서버·stdio 부팅(`lib/server/server_runtime_bootstrap.ml:1691`, `bin/main_stdio_eio.ml:78`), `masc auth off`, `masc auth invite`, `masc auth preview`.

### 4. [P2] lease 배타가 환경 변수에 달려 있다

- 신뢰도: medium(코드 사실 high, 일어날 빈도 low-medium)
- 근거
  - `lib/host_config/host_config.ml:43-49` `MASC_BASE_PATH_LEASE_DIR`가 있으면 lease 디렉터리를 그 값으로 바꾼다.
  - `lib/server/server_startup_takeover.ml:231-233` override면 그 디렉터리를 그대로 쓴다.
  - `bin/masc_cli_auth.ml:14` CLI는 자기 셸의 값을 읽는다. `bin/main_eio.ml:377-379` 서버는 자기 환경의 값을 읽는다.
  - `scripts/docker-entrypoint.sh:13`, `scripts/container-runtime-entrypoint.sh:6`은 이 변수를 필수로 요구한다.
- 무엇이 틀렸나: 떠 있는 프로세스(오늘은 `masc auth preview`, S1부터 서버)와 CLI가 `MASC_BASE_PATH_LEASE_DIR` 값을 다르게 보면 두 프로세스의 lease 파일이 달라진다. 같은 OS 사용자·같은 설정 디렉터리여도 그렇다. 그러면 프로세스가 떠 있는데도 `masc auth off`가 lease를 얻는다.
- 결과: `off`가 로그와 저장소에 들어가고 CLI는 성공을 말한다. 떠 있는 쪽은 `Multi_account` snapshot으로 계속 답한다. 다음 자기 append에서 `Diverged`로 로그가 멈출 때까지다. 발견 2 때문에 멈춘 뒤에도 세션 요청은 통과한다.
- 계획과의 관계: 계획 134·227줄은 "lease 없는 두 번째 writer는 첫 쓰기에서 `Diverged`"까지 적었다. F3a 범위(771줄)의 "서버가 떠 있으면 lease를 얻지 못한다"는 두 프로세스의 lease 디렉터리가 같다는 가정 위에 있다.
- 단서: 컨테이너 밖 호스트에서 돌린 CLI는 설정 디렉터리가 달라 설치 기록을 찾지 못하고 `Store_absent`로 끝난다. 그 경우는 쓰지 않는다.

### 5. [P3] 비용

- 신뢰도: high
- O(로그 줄 수)인 것
  - 열기: 파일 전체를 문자열 하나로 읽고 줄마다 파싱·해시·접기를 한다(`lib/auth/authz_jsonl_file.ml:228-246`). 열 때 메모리는 파일 크기만큼이다. 계획 167줄의 "메모리는 로그 길이와 상관없이 일정하다"는 `Probe`에만 맞다.
  - 부팅마다 로그 한 번, 저장소 한 번. 계획 §6-6이 이미 아는 항목이다.
  - `masc auth invite|off|preview`는 판정에서 한 번, 구역을 열며 한 번, 합쳐 두 번씩 읽는다: `lib/auth/authz_off.ml:50,76`, `lib/auth/authz_activation.ml:181,125`, `bin/masc_cli_auth.ml:272,194`. S1이 부팅 판정 뒤 구역을 따로 열면 부팅도 두 번이 된다.
  - `Replay.reach`·`Replay.step`은 레코드마다 `unreached`를 `List.partition`한다(`lib/auth/authz_zone.ml:29-33,52-57`). 줄 수 × 닫히지 않은 포기 축소 수다. 포기 축소가 적으면 무시할 값이다.
  - 저장소 상태의 `aborted` 목록은 줄지 않는다(`lib/auth/authz_external_store.ml:217-218`).
- O(1)이거나 map인 것
  - commit의 고수위 판정(`lib/auth/authz_zone.ml:409`), 게이트 값(`164-174`, 막힘 목록 길이만큼).
  - 접힌 상태의 조회는 하위 모듈의 `Map`이다(`rg`로 확인).
- snapshot: 불변 값 `{state; head}`를 `Atomic`으로 한 번에 바꾼다(`lib/auth/authz_zone.ml:383-384`). `probe`는 다른 `Atomic`이고 한 줄 먼저 놓인다(382). 그 사이에 읽은 게이트는 commit 직전 상태로 답한다. commit은 아직 성공을 돌려주지 않았으니 틀린 답이 아니다.
- fsync: epoch 사건 하나에 세 번(intent, 레코드, `Committed`), intent 없는 사건은 한 번이다.

### 6. [P3] 판정보다 먼저 지우는 sweep

- 신뢰도: low(순서는 확인, sweep 본문은 읽지 않음)
- 근거: `bin/main_eio.ml:459-531`의 retained checkpoint sweep, checkpoint object sweep, settled archive sweep이 lease 직후에 돈다. 계정 모드 판정은 그 뒤 `lib/server/server_runtime_bootstrap.ml:1691`이다.
- 입력: 다계정 로그가 있는 base path에서 서버를 띄운다(오늘은 늘 거부된다). 또는 끈 설치(4행)다.
- 결과: 부팅이 거부되기 전에 단일 사용자 가정의 삭제가 이미 돌았다. 4행은 multi-owned record를 읽기 전용으로 둔다고 했는데, 판정 전이라 sweep은 끈 설치인지 모른다.
- 확인하지 못한 것: sweep이 계정 소유 Keeper의 checkpoint를 실제로 지우는지.

### 7. [P3] host tool 판정이 낡는다

- 신뢰도: low
- 근거: `lib/runtime/runtime_account_access.ml:99-105` `publish_host_tool`은 `Authz_boot_mode_read.tool`로 파일 유무만 보고(lease 없음) `Single_user`를 한 번 게시한다. `313-318`에서 `Never_set_up`은 모든 요청이 `Ok ()`다. 사람 홈(`.masc/accounts`) 위의 시작도 포함이다.
- 호출처 11곳: `bin/masc_cli_antigravity.ml:18`, `bin/main_eio.ml:2071,2818,2967`, `bin/masc_lane_cli_probe.ml:188`, `bin/masc_cli_muse_models.ml:7`, `bin/masc_librarian_continuity.ml:480`, `bin/deployment_preflight_helper.ml:1155`, `bin/fusion_run.ml:575`, `bin/keeper_capability_probe_cli.ml:409`, `bin/masc_cli_codex_models.ml:7`.
- 입력: 오래 도는 도구가 떠 있는 동안 `masc auth bootstrap`이 끝나고 사람 계정이 생긴다.
- 결과: 그 도구 프로세스는 끝날 때까지 "설정한 적 없는 단일 사용자"로 판정한다.

### 8. [P3] Keeper 재배정은 되감겨도 모른다

- 신뢰도: medium
- 근거: `lib/auth/authz_state.ml:627-643` Keeper 레코드는 `high_water = None`이다. 주석은 "되감기면 Keeper에 owner나 Runtime이 없다"고 적었다. `lib/auth/authz_keeper_state.ml:97-111` `assign`은 이미 배정된 Keeper의 재배정을 막지 않는다.
- 무엇이 틀렸나: Keeper를 다른 Runtime으로 다시 배정한 뒤 로그가 그 레코드 앞으로 되감기면 Keeper가 앞선 Runtime에서 다시 돈다. 저장소는 `Matches`다.
- 영향: 같은 owner의 Runtime 사이다. R1을 Disable·Block했다면 그 사건은 intent가 있어 되감기가 드러난다.

---

## §5.1 표 대조

`lib/auth/authz_boot_mode.ml`의 `judge`(144-160)는 입력이 맞으면 11행 모두 표와 같다.

| 행 | 설정 / 로그 mode / 고수위 | 코드 | 같음 |
|---|---|---|---|
| 1 | 없음·Single / 없음 / 없음 | 105, 116 → `Single_user` | 예 |
| 2 | 없음·Single / 없음 / 있음 | 106-107 → `Rewound_before_bootstrap`·`External_store_unreadable` | 예 |
| 3 | 없음·Single / Multi / 무엇이든 | 111, 117 → `Downgraded_from_multi_account` | 예 |
| 4 | 없음·Single / off / 맞음 | 108, 118 → `Single_user_after_off state` | 예 |
| 5 | Multi / 없음 / 없음 | 105, 123 → `Activation_requested` | 예 |
| 6 | Multi / 없음 / 있음 | 106-107 → 거부 | 예 |
| 7 | Multi / Multi / 맞음 | 124 → `Multi_account` | 예(단, `맞음`의 정의는 발견 1) |
| 8 | Multi / Multi / 없음·안 맞음·읽지 못함 | 125 → `Multi_account_uncertain` | 예(단, 발견 3의 로그는 여기까지 오지 못함) |
| 9 | Multi / off / 맞음 | 108, 126 → `Reactivation_not_ready` | 예 |
| 10 | 무엇이든 / off / 없음·안 맞음·읽지 못함 | 109-110 → `Rewound_after_off`·`External_store_unreadable` | 예 |
| 11 | 알 수 없는 값 / 무엇이든 / 무엇이든 | 149-151 → `Unknown_account_mode` | 예 |
| 표 아래 문단 | 로그가 있는데 읽지 못함 | 103-104 → `Authorization_log_unreadable` | 예 |

- 설정이 `Multi_account`인 행에는 auth 설정 사유가 더해진다(129-142). auth가 꺼져 있거나 `require_token`이 false거나 익명 쓰기가 켜져 있으면 5·7·8행도 거부다. 설계 §11.1의 요구와 같은 방향이다.
- 이 브랜치에서 5행은 `Activation_requested`, 7·8행은 `Multi_account_not_served`로 멈춘다(`lib/auth/authz_boot_mode_read.ml:150-158`).
- 어긋나는 것은 표가 아니라 입력이다: `맞음` 열(발견 1), 8행(발견 3).

---

## 확인해서 문제없던 것

### 질문 1: fail-open 부팅

- `config.json`을 못 읽거나 JSON이 아니면 설정 없음 + `Settings_unreadable`이다(`lib/auth/authz_boot_mode_read.ml:39-63`). 다계정 흔적이 있으면 2·3·10행이 거부한다. 설계 237줄이 정한 동작이다.
- 로그가 있는데 열지 못하거나 있는지 알 수 없으면 `Log_unreadable`이다(`95-106`, `119`).
- 저장소를 못 읽으면 로그와 상관없이 `Store_unreadable`이다(`124`).
- 설정 디렉터리가 소유자 검사에 걸리면 기록이 없어도 읽지 못함이다(`lib/auth/authz_install_record.ml:209-225`).
- masc가 설정 디렉터리를 만들 때는 0700이다(`lib/config/env_config_core.ml`의 `record_default_base_path`). masc 때문에 검사에 걸리지는 않는다.
- `single_user` 값은 `boot`와 `tool`만 만든다(`lib/auth/authz_boot_mode_read.mli:101-104`). 서버는 lease 뒤에 판정한다(`bin/main_eio.ml:377-379` → `lib/server/server_runtime_bootstrap.ml:1687-1701`). stdio도 같다(`bin/main_stdio_eio.ml:52-89`).

### 질문 2: 죽는 자리와 꼬리 자르기

- activate(`lib/auth/authz_bootstrap.ml:403-417` → `Authz_zone.install` → `lib/auth/authz_activation.ml:107-159`)
  - 설치 기록만 쓴 뒤, 빈 저장소만 만든 뒤, `Intent_pending`만 쓴 뒤에 죽으면 다시 부를 때 이어진다(판정 3).
  - 로그 첫 줄은 임시 파일 + rename이라 반쯤 쓴 첫 줄이 없다.
  - 레코드는 들어갔고 `Committed`가 없으면 다음 부팅이 판정 2로 `Matches`를 낸다.
  - 초대 전에 죽으면 `masc auth invite`가 메운다.
- 일반 commit·invite·off(`lib/auth/authz_zone.ml:310-393`)
  - 순서: 진입 판정(409) → 레코드 만들기와 `apply`(323-341) → abort 전 `confirm_end`(345) → 막힘 발행(350) → settlement(351) → `Intent_pending`(359-365) → 로그 append(366-381) → probe·snapshot(382-384) → `Committed`(385-391).
  - 어느 줄 사이에서 죽어도 다음 진입이나 부팅이 판정 2·3으로 같은 결론에 닿는다.
  - append 실패 뒤 축소 사건의 막힘은 그 자리에서 발행된다(376-379).
- off: `Intent_pending(Off)`만 남으면 다음 부팅은 7행 그대로다(모드 사건은 축소가 아니라 막힘이 없다). 레코드까지 들어갔으면 4행이다.
- 꼬리 자르기: 열 때 마지막 줄바꿈 뒤 바이트만 자른다. 줄바꿈으로 끝났는데 읽히지 않는 줄은 거부다. 답한 레코드는 fsync가 돌아온 뒤에만 답하므로 잘리는 줄에 답한 레코드는 없다(계획 §7-7의 `F_FULLFSYNC` 한계 안에서).
- 파일을 여는 쪽은 모두 lease를 쥔다. host tool은 파일을 열지 않는다(`lib/auth/authz_boot_mode_read.ml:240-283`).

### 질문 3: 알아채는 변조·되감기

- 줄 하나를 고치면 체인 해시가 어긋나 로그 전체가 읽지 못함이다.
- 답한 사건(마지막 `Committed`) 앞으로 로그를 되감으면 `Commit_not_in_log`다.
- 로그·저장소·잠금 파일이 링크나 디렉터리로 바뀌면 읽지 못함이다.
- 대기 중 intent 뒤에 다른 레코드가 있으면 `Digest_differs`, 자리를 못 찾으면 `Intent_unplaced`다.
- 저장소 규칙을 어기는 줄은 `Line_rejected`다.
- 알아채지 못하는 것 가운데 계획·설계가 이미 적은 것은 아래 "이미 아는 한계"에 있다. 그 밖은 발견 1과 8이다.

### 질문 4: 동시성

- 프로세스 안: 구역은 저장소 → 로그 순서의 `Eio.Mutex` 둘이다(`lib/auth/authz_zone.ml:396-405`). `probe`는 저장소 구역 안에서만 놓는다.
- 프로세스 사이: `bootstrap`·`invite`·`off`·`preview`는 모두 `with_lease` 아래다(`bin/masc_cli_auth.ml:9-20,56-69,133-151,267-277`). 발견 4의 조건은 빼고다.
- 판정과 구역 열기 사이: `turn_off`와 `invite`는 판정 뒤 설치 기록을 다시 읽어 구역을 연다. `commit`이 들어갈 때 다시 판정하므로(409) 그 사이 바뀐 저장소에는 쓰지 않는다. mode가 바뀌었으면 `Mode_moved`다(`lib/auth/authz_off.ml:78-82`).
- `masc auth preview`의 `A.active_store`는 Eio 밖에서 돈다. `Systhread_host.run`이 Eio가 아니면 그 자리에서 실행하므로 문제없다(`lib/core/systhread_host.ml:99-127`).

### 질문 5: `Authz_off.turn_off`

- 쓰는 조건은 로그가 `Multi_account`이고 저장소가 `Matches`일 때뿐이다(`lib/auth/authz_off.ml:49-58`). 그 밖은 아무것도 쓰지 않는다.
- 끈 뒤
  - `masc auth invite`는 `Accounts_turned_off`, `masc auth bootstrap`은 `Turned_off`, 두 번째 `off`는 `Already_off`다.
  - 설정이 `Multi_account`를 물으면 9행 `Reactivation_not_ready`다. `off`는 `config.json`을 쓰지 않는다(계획 790줄의 결정).
  - 모든 종류의 레코드가 `Accounts_off`로 거절된다(`lib/auth/authz_state.ml:653-676`).
  - 단일 사용자 부팅은 로그의 Keeper·Runtime·사람 홈 위의 시작을 거절한다(`lib/runtime/runtime_account_access.ml:296-311`).
- 끈 뒤 다시 켜지는 길은 발견 1의 A뿐이다.

### 질문 7: 오류 처리

- 범위 안 catch-all은 10곳이다: `lib/auth/authz_record.ml:17,175,185,359,372`, `lib/auth/authz_id.ml:31`, `lib/auth/authz_external_store.ml:336,348,381,382`. 모두 `false`·`None`·`Error`로 끝난다.
- `with _ ->`, `Option.value ~default`, `exception _`, 버린 Result는 범위 안에 없다(`rg`로 확인).
- 모르는 것을 한쪽으로 접는 곳은 둘이다.
  - `lib/auth/authz_boot_mode_read.ml:113` `Ok None | Error _ -> S.State.empty`: 고수위는 따로 `Store_unreadable`·`Absent`로 남아 fail-closed다. 발견 3의 원인이다.
  - `lib/auth/authz_zone.ml:74` `Replay.finish`의 `Error _ -> []`: 그때 게이트는 `Unknown_files_disagree`로 답한다. 발견 2의 경로에서만 드러난다.
- `lib/auth/authz_external_store.ml:211-214`의 `invalid_arg`는 `check`를 통과한 intent에서는 닿지 않는다.

---

## Not reachable yet

- `Authz_zone.open_at_start`는 로그가 있는지만 먼저 본다(`lib/auth/authz_zone.ml:140-145`). 저장소가 없거나 비었거나 어긋나도 구역과 snapshot을 낸다(`118-136`). 없는 저장소 경로에 디렉터리와 잠금 파일도 생긴다. 지금 여는 세 곳(`bin/masc_cli_auth.ml:194`, `lib/auth/authz_off.ml:76`, `lib/auth/authz_activation.ml:125`)은 lease 아래에서 `Matches`를 먼저 본다. 계획 236줄이 S1의 결정으로 남겼다. 발견 2가 그대로면 이 구역의 snapshot으로 요청이 인증된다.
- `reactivate`를 쓰는 코드는 없다(F3b). replay는 받는다(발견 1).
- `Multi_account`·`Multi_account_uncertain` 서빙은 없다. 실제 서버는 `Multi_account_not_served`로 멈춘다.
- `Authz_external_store.State.workspace_id` 접근자는 부르는 곳이 없다.

## 이미 아는 한계 (다시 보고하지 않음)

- 설치 기록과 로그를 함께 잃으면 새 설치와 구분하지 못한다. 로그와 저장소만 지워도 1행이다(계획 §7-2, 252줄).
- 설정 디렉터리를 알 수 없거나 환경이 다르면 설치 기록이 없는 것으로 읽는다(계획 147줄). 설치 기록 파일 이름은 canonical base path의 해시라, base path가 옮겨지면 기록을 찾지 못한다.
- Darwin `F_FULLFSYNC`가 없다(계획 §7-7).
- 같은 inode에서 크기가 그대로인 쓰기는 알아채지 못한다(계획 227줄).
- `confirm_end`와 abort 사이에 남이 붙인 레코드는 다음 append 때만 드러난다(계획 229줄).
- lease 없는 두 번째 writer는 첫 쓰기에서야 `Diverged`다(계획 134줄).
- bootstrap이 실패를 말했는데 로그에 `Fresh_bootstrap`이 남는 경우(계획 183줄).
- 초대 발급, 등록, 재활성, 취소, 옛 세션 없는 세션 발급, PAT·Service credential 발급은 intent가 없다(설계 §8.2).
- 기동 replay 시간과 checkpoint(계획 §6-6).
- 끈 뒤 단일 사용자 Keeper의 native 도구가 `.masc/accounts`를 읽을 수 있다(계획 783줄).

## 읽지 않은 것

- 인터페이스: `lib/auth/authz_state.mli`(grep만), `authz_record.mli`, `authz_records.mli`, `authz_body.mli`, `authz_id.mli`. 다섯 파일의 `.ml`은 읽었다.
- 하위 상태 모듈: `authz_principal_state`, `authz_invite_state`, `authz_session_state`, `authz_pat_state`, `authz_service_credential_state`, `authz_provider_account_state`, `authz_runtime_state`, `authz_registration_state`는 grep만. `authz_keeper_state.ml`은 97-128줄만.
- 일부만 읽은 것: `lib/auth_gate.ml`(160-216), `lib/auth_preview.ml`(321-365), `lib/server/server_login_http.ml`(222-262), `lib/server/server_setup_account_login.ml`(150-192, 425-452), `lib/auth/authz_keeper_turn.ml`(96-140), `lib/auth/authz_login.ml`(81-89), `lib/auth/authz_browser_session.ml`(60-148), `lib/auth/authz_pat.ml`(60-100).
- `Authz_decision` 본문. 발견 2의 "Keeper 턴은 거절된다"는 `facts.revocation`에 게이트가 들어간다는 것까지만 확인했다.
- startup sweep 본문: `Keeper_retained_checkpoint_sweep`, `Keeper_checkpoint_object_sweep`, `Server_settled_archive_sweep`.
- `Fs_compat`의 owned-file read와 `atomic_replace` 내부. `fs_compat_private_jsonl_write.ml`, `fs_compat_durable_append.ml:78-116`, `fs_compat_private_jsonl_transaction.ml:480-740`은 읽었다.
- `auth_config` 디코더 본문(`lib/types/types_auth.ml`).
- `bin/`의 다른 하위 명령이 판정 없이 base path를 쓰는지는 전수로 보지 않았다. `publish_host_tool` 호출처 11곳만 확인했다.
- 시험 코드 전부. 실행한 것은 없다.

## 읽은 파일

- 범위(`.ml`은 모두 통독): `lib/auth/authz_log`, `authz_jsonl_file`, `authz_zone`(+mli), `authz_state`, `authz_record`, `authz_records`, `authz_body`, `authz_id`, `authz_high_water`(+mli), `authz_external_store`(+mli), `authz_install_record`(+mli), `authz_boot_mode`(+mli), `authz_boot_mode_read`(+mli), `authz_activation`(+mli), `authz_bootstrap`(+mli), `authz_off`(+mli), `authz_mode_event`(+mli), `authz_mode_state`(+mli), `authz_presence`(+mli), `bin/masc_cli_auth.ml`.
- 호출처와 인접: `lib/server/server_runtime_bootstrap.ml:1687-1701`, `bin/main_stdio_eio.ml:52-89`, `bin/main_eio.ml:318-540,1160-1299`, `lib/runtime/runtime_account_access.ml`, `lib/core/systhread_host.ml:99-127`, `lib/server/server_startup_takeover.ml:225-252,1121-1125`, `lib/host_config/host_config.ml:36-52`, `lib/server/server_base_path_guard.ml:18-40`, `lib/config/env_config_core.ml:391-404,619-662`.
- 문서: 설계 §3(55-67), §5.1(235-264), §8.1-8.4(461-526), §10.5(601-614), §11(616-639). 계획 A2 범위(92-101), B1~B3 범위(121-257), F3a·F3b 범위(769-798), §6(840-851), §7(853-863).
