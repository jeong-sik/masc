> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

기준 head 85b8af5b0453 (branch feat/authz-f3a-off-command-20261110, 범위 파일에 커밋 안 된 변경 없음) · 확인 시각 2026-11-10 16:52 KST (07:52Z) · 세는 범위: worktree `.worktrees/authz-d1-1-20261108` 의 `lib/auth/authz_*.ml`, `lib/auth/login_*.ml`, `lib/auth/oidc_*.ml`, `lib/auth/github_*.ml`, `lib/auth/google_login_flow.ml`, `lib/auth_gate.ml`, `lib/auth_preview.ml`, `lib/auth_preview_keeper.ml`, `lib/runtime/runtime_account_access.ml`, `lib/runtime/runtime_account_home*.ml`, `lib/runtime/runtime_account_runtime.ml`, `lib/server/server_login_http.ml`, `lib/server/server_preview_keeper_turn.ml`, `lib/server/server_request_authority.ml`, `bin/masc_cli_auth.ml` — `.ml` 79개 15,144줄, 같은 이름 `.mli` 79개

# 다계정(authz) 코드 금지 패턴 집계 (rev-rules-census)

- 읽기 전용으로 했다. `rg` 와 파일 읽기만 썼다. dune·시험·네트워크는 쓰지 않았고 환경 변수 값은 읽거나 출력하지 않았다.
- 판정 기준: `docs/constitution.xml` 의 `<invariants>`(closed_sum_over_string, strict_parse_no_default), `<engineering>`, `<forbidden>`(magic_number, string_matching, budget_gate, greedy_shortcut, hardcoded_path, env_var_sprawl, legacy_residue)와 소유자 추가 요구(SSOT, 휴리스틱·하드코딩·문자열 판정 금지, 불변 데이터, env → TOML, 프롬프트 외부화).
- 아래 경로는 모두 worktree 뿌리 기준이다.
- 신뢰도: 수치 High(07:52Z 에 같은 head 에서 다시 센 값). 판정 Medium-High(읽어서 내린 판정이고 빌드·시험으로 확인하지 않았다).

## 1. 쓴 rg 명령

`$ML` = 범위 `.ml` 79개, `$MLI` = 같은 이름 `.mli` 79개. 어느 census 도 `head` 로 자르지 않았다.

```
a   rg -n 'String\.(equal|starts_with|ends_with|sub|index|split_on_char|lowercase_ascii)|Str\.|Re\.|= "' $ML
b1  rg -n 'Option\.value|~default' $ML
b2  rg -n '\btry\b|with _ ->|\bignore\b|\| exception|Result\.(get_ok|value)|Option\.get|failwith|invalid_arg|assert false|raise ' $ML
b3  rg -n '\| _ ->' $ML
d1  rg -n '[0-9]{2,}' $ML
d2  rg -n '"[/~][^"]*"|"\.[a-z_-]+[^"]*"|"https?://[^"]*"' $ML
e   rg -n 'Sys\.getenv|Env_config|getenv_opt|Unix\.getenv|Unix\.environment|putenv|MASC_[A-Z_]+|XDG_[A-Z_]+|\bHOME\b|_env\b|env_' $ML
e'  rg -n 'Sys\.getenv|Unix\.getenv' $ML                      (직접 읽기만)
f   rg -n '\bref\b|Atomic\.make|Hashtbl\.|Mutex\.create|Eio\.Mutex\.create|Fiber\.create_key|\blazy\b|Lazy\.' $ML
g   rg -n -i '_for_test|for_testing|reset_|for_tests|test_only' $MLI
h1  rg -n '"[^"]{60,}' $ML        h2  rg -n '\\$' $ML        h3  rg -n '\{\|' $ML
i   rg -n '\bmutable\b|<-|Array\.|\[\|' $ML
c   단일 rg 없음. 읽어서 찾은 리터럴을 lib·bin 전체에 교차 rg 했다. 예:
    rg -n '"official-clients"|official-clients' lib bin --glob '*.ml'
    rg -n '"service_credential"|"registration"|"session"|"pat"|"invite"|"grant"|"credential"|"principal"|"runtime"|"human"|"service"' lib/auth lib/auth_preview.ml lib/auth_preview_keeper.ml
    rg -n '"/auth/[a-z/_-]*"|"/api/v1/auth/[a-z/_-]*"|"/api/v1/setup/accounts[a-z/_-]*"' lib bin --glob '*.ml'
    rg -n 'attempts' lib/auth ...     rg -n 'let is_lower_hex' lib/auth ...     rg -n 'System_migration|Migration_diagnostic' lib bin
    rg -n 'Authz_zone\.revocation|Authz_state\.revocation' lib bin     rg -n 'of_environment' lib bin test
```

## 2. 범주별 건수

| 범주 | 수 | 실제 위반 |
|---|---|---|
| a 문자열·substring 판정 | 237줄(47파일) | 3 |
| b catch-all·기본값 접기 | b1 1줄 / b2 55줄 / b3 51줄. `with _ ->` 0, `ignore` 0, `failwith` 0, `assert false` 0, `invalid_arg` 2, `raise` 1 | 3 |
| c SSOT 중복 | 읽어서 찾은 중복 20묶음(사실 14, 도우미 코드 6) | 14 |
| d 하드코딩 값·경로·매직 넘버 | d1 243줄 + d2 36줄 | 4 |
| e 환경 변수 | 21줄. 키 8개 + 암묵 `TMPDIR`. 직접 `Sys.getenv_opt` 는 1줄 | 3 |
| f 가변 전역 상태 | 9줄(모듈 수준 2, 인스턴스 생성 7) | 1 |
| g `.mli` 의 테스트 훅 | 0 | none found |
| h 코드에 박힌 문구·프롬프트 | h1 159줄 / h2 80줄 / h3 38줄 | 2 |
| i 불변일 수 있는 가변 데이터 | 22줄(mutable 필드 7, 배열 0, Hashtbl 0) | 1 |
| 범주 밖: legacy_residue | — | 1 |

- 3번·12번은 a 와 b 에, 19번은 c 와 h 에, 20번은 c 와 d 에 둘 다 셌다.
- 하드코딩 경로만 따로 보면: 코드 경로에 절대 경로 0, `.masc` 는 코드에서 `Common.masc_dir_from_base_path`·`Common.auth_dir_from_base_path` 로만 만든다. `.masc/...` 를 글자로 적은 곳은 문장 4줄뿐이다(19번). 디렉터리 이름 `"official-clients"` 는 코드 6곳에 따로 있다(26번).
- 매직 넘버만 따로 보면: 흐름을 정하는 수는 `attempts = 3`(1번, 17번), `turn_timeout_s = 120.0`(16번), 이름 없는 `65_535`·80·443(20번)이다.

## 3. 실제 위반 (계약 위배 순)

1. **[d, magic_number]** `lib/auth/authz_keeper_turn.ml:12,186-198` — 결정 도중 로그 head 가 3번 바뀌면 실패 상태 없이 `Log_kept_moving` 으로 Keeper 턴을 거절한다. `lib/server/server_preview_keeper_turn.ml:94-95` 가 503 을 낸다. 한 결정이 snapshot(`before.state`)과 live `Authz_zone.revocation`(:102-109)을 섞어 읽어서 생긴 재시도다.
2. **[b, strict_parse_no_default]** `lib/auth/authz_boot_mode_read.ml:41-43,46,50,53,61-62` — config.json 을 확인 못 하거나(`Cannot_check`) 못 읽거나 JSON 객체가 아니면 warn 한 줄과 함께 `B.Not_set` 으로 접는다. `lib/auth/authz_boot_mode.ml:85` 가 이를 `Asks_single_user` 로 읽고 :131 이 `Settings_unreadable` 을 버린다. 로그에 mode event 가 없으면 `Activation_requested` 정지 대신, Off 뒤면 `Reactivation_not_ready` 거절 대신 single user 로 부팅한다. 로그가 `Made_multi` 면 `Downgraded_from_multi_account` 로 거절하므로 켜진 설치는 막힌다.
3. **[a, b]** `lib/auth/authz_bootstrap.ml:188-193` — `Unix.stat dir` 이 ENOENT 가 아닌 오류(EACCES, ELOOP 등)를 내도 "external store 가 설치 안에 있나" 판정을 inode 비교에서 realpath 문자열 `String.starts_with` 로 바꾼다. :199 와 :215 는 stat 오류를 "안 닿음", "다른 파일"로 접는다. 이 검사는 안에 있으면 거절하는 검사라 접힌 쪽이 허용이다. 형제 모듈 `lib/auth/authz_presence.ml:12-20,35-39` 는 ENOENT 와 다른 오류를 나눈다.
4. **[c]** Subject·Principal wire 라벨(`grant`, `credential`, `principal`, `runtime`, `session`, `pat`, `service_credential`, `invite`, `registration`, `human`, `service`)이 네 곳에 따로 있다: `lib/auth/authz_cancel_event.ml:25-42`(쓰기), `:88-106`(읽기), `lib/auth/authz_external_store.ml:241-253`(쓰기), `:312-332`(읽기), `lib/auth/authz_record.ml:156-158`, `:171-173`. `authz_cancel_event.ml:15-17` 주석이 "시험이 두 쪽 바이트를 맞춘다"고 적는다.
5. **[c]** 폐기(revocation) 질문에 답이 둘이다. `lib/auth/authz_pat.ml:92`, `lib/auth/authz_browser_session.ml:131`, `lib/auth/authz_service_credential.ml:92` 는 snapshot 의 `Authz_state.revocation` 만 읽는다(`lib/server/server_login_http.ml:230,239` 가 snapshot 을 넘김). `lib/auth/authz_login.ml:82` 와 `lib/auth/authz_keeper_turn.ml:103` 은 파일 정지를 먼저 묻는 `Authz_zone.revocation`(`lib/auth/authz_zone.ml:164-173`)을 쓴다. 로그나 store 가 멈춰도 세션·PAT·Service credential 인증은 모른다. 의도된 선택일 수 있어 확인이 필요하다.
6. **[d, stub]** `lib/auth/authz_keeper_turn.ml:72,79,94,117,134` — `Authz_decision.allowed` 의 유일한 호출처(:163)가 Runtime 상태, provider account 상태, grant 상태, auth binding 상태, dependency 를 상수(`Active`, `Cleared`)로 넣는다. 판정 엔진의 그 갈래는 실행되지 않는다.
7. **[legacy_residue]** `lib/auth/authz_record.ml:129-145`, `lib/auth/authz_state.ml:698-706` — Kind 21개 중 8개(`Runtime_grant`, `Delegate_policy`, `Permission_revocation`, `Trigger_evidence`, `Lease_terminal_evidence`, `Preauthorized_expiry`, `Migration_diagnostic`, `Local_recovery`)는 쓰는 곳이 없고 읽으면 `Kind_not_read` 로 거절한다. `Migration_diagnostic` 과 `Author.System_migration`(`lib/auth/authz_record.ml:118,167,184`)은 "미출시 제품이라 내부 마이그레이션도 불필요"와 어긋난다. 6번과 같은 뿌리다.
8. **[e]** `bin/masc_cli_auth.ml:46-51` — multi-account 전제인 anonymous mutation 설정을 이 CLI 셸의 `MASC_ALLOW_ANONYMOUS_MUTATIONS` 로 읽는다. :44-45 주석이 "다른 환경에서 뜬 서버는 자기 것을 읽는다"고 적는다. config 필드가 없어 CLI 와 서버가 다르게 답할 수 있다.
9. **[e]** `bin/masc_cli_auth.ml:155,254` — `MASC_GITHUB_CLIENT_SECRET` 이름을 코드에 박고 `Sys.getenv_opt` 로 바로 읽는다(`Env_config_core` 를 거치지 않음). config.json 에 `github.client_id/redirect_uri/client_secret_env`(`lib/types/types_auth.ml:196-210`)가 있지만 lib·bin 에서 읽는 곳이 없다. 그 필드를 받으려고 만든 `Login_client.of_environment`(`lib/auth/login_client.ml:81-83`)는 `test/test_login_flow.ml:288,529` 만 부른다.
10. **[e]** `bin/masc_cli_auth.ml:25-27` — 초대 링크 주소를 `MASC_HTTP_BASE_URL` 로만 받는다(:22-24 주석). config 필드가 없고 TOML key 등록부(`lib/config/keeper_runtime_setting_registry.ml:977-985`)에도 없다.
11. **[f]** `lib/runtime/runtime_account_access.ml:86-97` — 프로세스 전역 `Atomic` 에 판정 근거를 한 번만 넣고 `judge`(:314), `host_access`(:356), `authorize_native`(:410)가 인자 없이 읽는다. 자세한 것은 5절 표.
12. **[a, b]** `lib/runtime/runtime_account_home_layout.ml:27-36,53-62` — Off 뒤 "home 이 persons 아래인가"를 '/' 로 쪼갠 조각 문자열 비교로 정한다(`..` 은 조각으로 남는다). :43 은 realpath 의 모든 오류를 "없는 부분"으로 접고 부모로 올라간다. `lib/auth/authz_bootstrap.ml:194-206` 의 inode 비교와 다른 두 번째 구현이다.
13. **[c]** `lib/auth_preview.ml:55-57,118-119,129,161-162` — HTML·JS 문자열이 라우트 4개(`lib/server/server_login_http.ml:184,186,187,194`), form 필드 2개(`lib/auth/login_routes.ml:209-210`), SSE 이벤트 이름 2개(`output`, `started`)를 다시 적는다. `lib/auth_preview.ml:87` 은 `lib/server/server_routes_http_routes_setup.ml:85` 와 `lib/server/server_setup_account_login.ml:6` 의 경로를 다시 적는다. `lib/auth_preview.ml:6` 의 `https://github.com` 은 `lib/auth/github_oauth.ml:7` 과 따로다.
14. **[h]** `lib/auth_preview.ml:33-48,53-73,92-228` — HTML 두 장과 137줄 JS 가 gate 판정 함수(`whoami`, `human`, `person`)와 같은 OCaml 모듈의 문자열 리터럴이다.
15. **[c]** `lib/auth/oidc_login_transaction.ml:11`(`invite_token_hex_length = 64`)이 `lib/auth/authz_activation.ml:14`(`token_bytes = 32`)에서 나오는 값을 다시 적는다. "64 lowercase hex characters" 문장도 8곳에 있다: `lib/auth/authz_record.ml:305,306`, `lib/auth/authz_external_store.ml:305`, `lib/auth/authz_session_event.ml:103`, `lib/auth/authz_pat_event.ml:81`, `lib/auth/authz_service_credential_event.ml:69`, `lib/auth/authz_cancel_event.ml:61`, `lib/auth/authz_invite_event.ml:113`.
16. **[d, budget_gate]** `lib/server/server_preview_keeper_turn.ml:9,216-217,244-245` — `timeout_s = Some turn_timeout_s`(120초)로 고정하고 runtime 설정의 `execution.timeout_s` 는 admission 에만 `Float.min` 으로 쓴다.
17. **[c]** `attempts = 3` 이 여섯 모듈에 따로 있다: `lib/auth/authz_keeper_turn.ml:12`, `lib/auth/authz_login.ml:79`, `lib/auth/authz_pat.ml:20`, `lib/auth/authz_browser_session.ml:61`, `lib/auth/authz_service_credential.ml:21`, `lib/auth/authz_allowlist.ml:24`. 각 `.mli` 가 `val attempts` 를 내보내지만 lib·bin·test 에서 읽는 곳은 0이다. keeper_turn 말고 다섯은 마지막 시도에서 실제 실패(zone 거절, 마지막 오류)를 돌려주므로 흐름 자체는 1번만큼 어긋나지 않는다.
18. **[c]** 소유자 함수의 사본: `Author.label`(`lib/auth/authz_records.ml:139-144`)을 `lib/auth/authz_session_state.ml:58-63`, `lib/auth/authz_pat_state.ml:56-61`, `lib/auth/authz_registration_state.ml:59-64`, `lib/auth/authz_service_credential_state.ml:41-46` 이 다시 적는다. `Authz_id.error_to_string`(`lib/auth/authz_id.ml:9-14`)을 `lib/auth/authz_registration_event.ml:50-55` 가 글자 그대로 다시 적는다.
19. **[c, h]** 문장이 다른 모듈 소유 이름을 다시 적는다. `config.json` 13곳(소유 `lib/auth/auth_credential_base.ml:41`): `lib/auth/authz_boot_mode.ml:173,181,185,192,194,198`, `lib/auth/authz_boot_mode_read.ml:174,180,186,187`, `lib/auth/authz_activation.ml:64,67`, `bin/masc_cli_auth.ml:145`. `account_mode`(소유 `lib/auth/authz_boot_mode_read.ml:13`)도 같은 문장들에 있다. `.masc/auth/authz.jsonl` 과 `authz-install-*.json`(`lib/auth/authz_boot_mode_read.ml:172-173`), `.masc/accounts`(`lib/runtime/runtime_account_access.ml:189`, `bin/masc_cli_auth.ml:148`), env 이름(`lib/auth/authz_boot_mode.ml:196`). Off 안내 문단은 `bin/masc_cli_auth.ml:144-148` 과 `bin/main_eio.ml:1238-1243` 에 두 번 있다.
20. **[d, c]** `lib/server/server_request_authority.ml:131` 의 `65_535` 는 이름이 없다(`lib/auth/login_client.ml:31` 에 `highest_port = 65535`). 80·443 은 :200-201(`default_port_for_scheme`)과 :492-493(`port_or_default`)에 두 번 있다.
21. **[c]** loopback 주소가 `bin/masc_cli_auth.ml:157`(`preview_host`), `lib/auth/login_client.ml:30`(`loopback_host`), `bin/masc_cli_auth.ml:229`(`Eio.Net.Ipaddr.V4.loopback`)에 따로 있다. redirect URI 호스트와 listen 호스트가 각자 적힌다.
22. **[c]** OAuth access token 접두 `"mat_"` 가 읽는 쪽 `lib/auth/authz_credential_presentation.ml:47` 과 쓰는 쪽 `lib/auth/auth_oauth.ml:876`(범위 밖)에 따로 있다.
23. **[a]** `lib/runtime/runtime_account_access.ml:254` — 요청의 `runtime_id` 문자열을 `Runtime_id.to_string` 결과와 비교한다. 같은 필드를 :283 은 `Runtime_id.of_string` 으로 파싱한다.
24. **[i]** `lib/auth/authz_jsonl_file.ml:133-135` — 파일 상태 하나를 `head`, `cursor`, `stopped` 세 mutable 필드에 따로 대입하고(:343,350-351,357,361,459,480) 정지 사유를 문장 `string option` 으로 둔다. `lib/auth/authz_zone.ml:96-97` 은 불변 snapshot 하나를 `Atomic` 으로 낸다.
25. **[c, effects]** `bin/masc_cli_auth.ml:7,203,220` — 한 명령이 "지금"을 `Unix.gettimeofday`, `Eio.Time.now`, `Ptime_clock.now` 세 곳에서 얻는다. 난수도 id 는 주입된 `~draw` 로, secret 과 일부 id 는 `Random_id.hex` 직접 호출(`lib/auth/authz_browser_session.ml:83`, `lib/auth/authz_credential_token.ml:76`, `lib/auth/authz_activation.ml:111,113,145`, `lib/auth/oidc_login_transaction.ml:146,167-169`)로 나뉜다.

25위 밖(낮음):

26. **[c]** 디렉터리 이름 `"official-clients"` 가 코드 6곳에 따로 있다: `lib/runtime/runtime_account_home_layout.ml:8`(이름 있는 상수 `clients_dir`), `lib/runtime/runtime_muse_home.ml:301,311`, `lib/runtime/runtime_antigravity_home.ml:666,691`, `lib/keeper/keeper_codex_runtime.ml:980`. 뒤 다섯은 범위 밖이다.
27. **[c]** `lib/auth/authz_types.ml:74-99,136-161` — Effect·Channel 라벨을 `to_string` 과 `of_string` 에 각각 적는다. 다른 코덱은 `all` + `List.find_opt` 로 한 번만 적는다.
28. **[c]** `unknown_keeper` 문장 2곳(`lib/server/server_preview_keeper_turn.ml:12`, `lib/auth_preview_keeper.ml:12`). 작은 쌍둥이: `http_ok = 200`(`lib/auth/github_oauth.ml:16`, `lib/auth/oidc_google_exchange.ml:11`), issuer URL(`lib/auth/oidc_google.ml:6,9`), `(1 lsl 53) - 1`(`lib/auth/authz_body.ml:31`, `lib/auth/authz_external_identity.ml:21`), "between 1 and 65535" 문장(`lib/auth/login_client.ml:68`).
29. **[h]** `bin/masc_cli_auth.ml:109-110` — 자기 문장 상수(`Authz_boot_mode_read.turn_off_line`, `single_user_again`)에 `String.capitalize_ascii` 를 걸어 다시 쓴다. 운영자 안내 문단이 판정 모듈 안에 있다: `lib/auth/authz_boot_mode.ml:170-198`, `lib/auth/authz_boot_mode_read.ml:170-191`, `lib/runtime/runtime_account_access.ml:139-196,396-406`.
30. **[engineering]** `lib/runtime/runtime_account_home.ml:4-15` 는 검증 뒤 같은 `string` 과 문자열 오류를 돌려준다(parse 가 아니라 validate). 문자열 오류는 `lib/runtime/runtime_account_home_layout.ml:66,68,72`, `lib/auth/authz_install_record.ml:224,296,305` 에도 있다.
31. **[i, 효율]** `lib/auth/authz_keeper_state.ml:81-83` 은 Made 마다 Map 전체를 훑어 policy 중복을 본다(replay 가 O(n²)). `lib/auth/authz_runtime_state.ml:17,87` 은 같은 일에 `Grant_id.Set` 색인을 둔다.

## 4. 환경 변수 (키 이름만)

| 키 | 범위 안에서 읽는 곳 | 읽는 경로 | 같은 일을 하는 config 필드 |
|---|---|---|---|
| `MASC_HTTP_BASE_URL` | `bin/masc_cli_auth.ml:26-27` | `Env_config_core.masc_http_base_url_opt` (`lib/config/env_config_core.ml:308,330-334`) | 없음 |
| `MASC_ALLOW_ANONYMOUS_MUTATIONS` | `bin/masc_cli_auth.ml:51` | `Server_auth_config.read_env` (`lib/server/server_auth_config.ml:1,32-37`) | 없음 |
| `MASC_HTTP_DEV_MUTATION_ORIGINS` | 위와 같은 호출이 같이 읽음 | `lib/server/server_auth_config.ml:2,36` | 찾지 않음 |
| `XDG_CONFIG_HOME`, `HOME` | `bin/masc_cli_auth.ml:64,138,274` | `Env_config_core.masc_config_dir_opt` (`lib/config/env_config_core.ml:398-401`) | 해당 없음(config 위치를 찾는 값) |
| `MASC_GITHUB_CLIENT_SECRET` | `bin/masc_cli_auth.ml:155,254` | `Sys.getenv_opt` 직접 | config.json `github.client_secret_env` 가 있으나 읽는 곳 없음 |
| `MASC_BASE_PATH_LEASE_DIR`, `MASC_CONFIG_DIR` | `bin/masc_cli_auth.ml:14` | `Host_config.host ()` (`lib/host_config/host_config.ml:43-50`) | 찾지 않음 |
| 암묵 `TMPDIR` | `lib/server/server_preview_keeper_turn.ml:177` | `Filename.temp_dir` | — |
| 주입된 getenv | `lib/auth/login_client.ml:81-83` | `of_environment ~getenv` | 생산 호출처 0 |

- TOML 로 옮길 길은 이미 있다. `lib/config/keeper_runtime_setting_registry.ml:977-985` 가 TOML key 와 env 이름을 짝짓고(등록된 `MASC_*` 이름 49개), runtime 파일이 소유한 이름이면 `Env_config_core.raw_value_opt`(`lib/config/env_config_core.ml:23-29`)가 프로세스 환경을 읽지 않는다. `MASC_HTTP_BASE_URL` 과 `MASC_ALLOW_ANONYMOUS_MUTATIONS` 는 그 등록부에 없다(rg 0건).
- `bin/masc_cli_auth.ml` 과 `bin/main_eio.ml` 에는 runtime 파일을 올리는 `Keeper_runtime_config.load_and_apply` 호출이 없다(rg 0건). 등록만으로는 `masc auth` CLI 가 파일 값을 읽지 못한다.
- 주석에만 나오는 이름: `MASC_HOST`, `MASC_HTTP_PORT`(`bin/masc_cli_auth.ml:23-24`).

## 5. 가변·전역 상태

| 위치 | 담는 것 | 두 번째 프로세스 | 재시작 | 같은 프로세스의 시험 |
|---|---|---|---|---|
| `lib/runtime/runtime_account_access.ml:86` `state` (모듈 수준 `Atomic`) | `Unpublished` 또는 `Published` (`Single_user` = 부팅 때 읽은 single user 와 Off 기록, `Multi_account` = zone·base_path·clock) | 프로세스마다 따로다. 다른 프로세스가 mode 를 바꿔도 모른다 | 부팅 때 파일에서 다시 읽어 publish | publish 한 번뿐이고 reset 이 없어 실행 파일 하나가 접근 하나만 쓴다 |
| `lib/server/server_request_authority.ml:561` `current_key` (모듈 수준 fiber key) | 요청의 authority | 무관 | 무관 | fiber 마다 binding |
| `lib/auth/authz_zone.ml:133-134,428-429` (필드 :96-97) | snapshot `Atomic`, probe `Atomic` | zone 은 lease 를 쥔 프로세스 하나가 연다 | 로그 replay 로 복원 | 인스턴스별 |
| `lib/auth/authz_jsonl_file.ml:283` (필드 :132-135,140) | `Eio.Mutex`, `head`·`cursor`·`stopped`, writer `live` | 다른 writer 는 cursor 불일치(`End_moved`)로 잡힘 | 파일에서 복원 | 인스턴스별 |
| `lib/auth/oidc_login_transaction.ml:137` (필드 :130-132) | 진행 중 로그인 Map + stdlib `Mutex` | 공유 안 됨. 콜백이 다른 프로세스에 닿으면 실패 | 사라짐(로그인을 다시 시작) | 인스턴스별 |
| `lib/auth/oidc_google_exchange.ml:24` (필드 :19-21) | discovery·jwks 캐시 + stdlib `Mutex` | 프로세스마다 다시 받음 | 다시 받음 | 인스턴스별 |
| `bin/masc_cli_auth.ml:185-188` | 전역 setter 호출: `Crypto_rng.ensure_default`, `Eio_context.set_env/set_switch/set_net` | — | — | — |

## 6. 오탐으로 뺀 기준

- **a**: 다음은 위반으로 세지 않았다.
  - 경계에서 wire 글자를 닫힌 타입으로 바꾸는 디코드. 라벨 상수를 한 번 적고 `String.equal event label` 로 고른 뒤 `| _ -> Error Wrong_members` 나 `Error (Unknown_event …)` 로 끝난다(event 코덱 13개, `Authz_external_identity`, `Authz_credential_token.read`, `Authz_credential_presentation.of_bearer`).
  - HTTP Host·authority·origin 파싱(`lib/server/server_request_authority.ml` 24줄), form·cookie·header 이름 고르기, 라우트 접두 떼기(`lib/server/server_login_http.ml:168-171`).
  - id·host 의 동일성 비교(`lib/runtime/runtime_account_runtime.ml`), 파서 안의 빈 문자열 검사.
  - canonical 정렬을 위한 라벨 순서 비교(`lib/auth/authz_types.ml:104,165-166`, 주석 있음).
  - OCaml 문자열 안의 JS 줄(`lib/auth_preview.ml:69,161-163`)과 `let name = "…"` 상수 정의 줄.
  - 변형 타입 전수 match 는 문자열 비교가 아니다: `Runtime_codex_app_server.refused_for_spent_usage`(`lib/runtime/runtime_codex_app_server.ml:511-530`), `failure_kind`(`lib/auth/authz_jsonl_file.ml:75-91`).
- **b**: 다음은 위반으로 세지 않았다.
  - `| _ -> Error …`, `| _ -> None` (디코더가 모르는 입력을 거절), 리스트 모양 패턴(`| _ :: _ :: _`, `| _ -> Multiple`).
  - 오류를 변형이나 문장으로 돌려주는 `exception` 갈래. ENOENT 만 따로 받는 갈래(`lib/auth/authz_presence.ml`, `lib/auth/authz_jsonl_file.ml:100`).
  - 잡은 예외를 다시 던지는 `exception exn`(`lib/auth/authz_jsonl_file.ml:337-347,503-511`).
  - `Option.value ~default:length`(`lib/auth/oidc_login_transaction.ml:54`, '?' 위치 파싱).
  - 접은 오류가 다른 길로 다시 나오는 곳: `lib/auth/authz_zone.ml:74`(probe 에 남음), `lib/auth/authz_state.ml:783`(다음 step 이 같은 body 를 다시 디코드해 거절).
  - 주석·JS·문장 hit 6줄: `lib/auth/authz_login.ml:93`, `lib/auth/oidc_id_token_signature.ml:121`, `lib/auth/google_login_flow.ml:19`, `lib/auth_preview.ml:115,223`, `lib/server/server_request_authority.ml:411`.
  - `invalid_arg` 2(`lib/auth/authz_external_store.ml:212`, `lib/auth/oidc_login_transaction.ml:136`)와 `raise` 1(`lib/server/server_request_authority.ml:569`)은 부분 함수지만 기본값 접기는 아니다.
  - `lib/runtime/runtime_account_access.ml:275,284` 는 "id 가 아닌 이름은 로그의 기록이 아니다"를 `None` 으로 답한다(주석 :271-272).
- **c**: 사실이 아니라 도우미 코드가 겹친 6묶음은 뺐다. `<abstraction>` 이 "깊은 추상화보다 중복이 낫다"고 한다.
  - `is_lower_hex` 6벌(`lib/auth/authz_record.ml:15`, `authz_session_event.ml:20`, `authz_invite_event.ml:36`, `authz_credential_token.ml:29`, `oidc_login_transaction.ml:3`, `authz_browser_session.ml:10`)
  - `string_member` 3벌·`json_members` 2벌, sha256 hex digest 모듈 4벌, `type answer = Code | Refused` 3벌
  - `ms_of` 3벌(`lib/auth/login_routes.ml:195`, `github_login_flow.ml:14`, `google_login_flow.ml:24`)과 ms 상수 3벌
  - `"cache-control","no-store"` 3곳과 HTML 골격 2곳
  - 코덱마다 member 이름을 쓰기·읽기에 한 번씩 적는 것은 canonical round-trip 검사가 잡는다.
- **d**: 주석·문서 줄, 설계 절 번호, 알고리즘 이름(RS256, S256, sha256), 문자 escape(`'\000'`, `'\012'`), 형식 폭(`%04o`, `%02X`), `Buffer.create 64`, 단위 변환 계수 1000, 이름 있는 상수는 뺐다. 이름 있는 상수는 config 가 아니라 코드 상수다: 수명 7일(`lib/auth/authz_session_state.ml:10`), 24시간(`lib/auth/authz_activation.ml:10`), 10분(`lib/auth/oidc_login_transaction.ml:83`), 크기 4096·16KiB·64KiB, port 8940·backlog 16·capacity 16(`bin/masc_cli_auth.ml:156-160`), 난수 32바이트, mode `0o700`·`0o600`, RSA 2048비트, URL(`lib/auth/github_oauth.ml:7-10`, `lib/auth/oidc_google.ml:6,9`).
- **e**: 주석 속 이름과 `_env` 로 끝나는 식별자 정의는 읽기가 아니라서 뺐다.
- **f**: 레코드를 만드는 줄 7개는 인스턴스 상태라 전역으로 세지 않았다.
- **g**: `.mli` 주석의 "test"(owner test, config-directory test 등)와 쿠키 이름 `__Host-` 는 훅이 아니다. 다만 훅은 아니어도 시험을 위해 모양이 정해진 인터페이스가 둘 있다: `lib/auth/authz_bootstrap.mli:23-26`(prepare/write 를 "시험이 사이에 파일을 바꾸려고" 나눔), 아무도 안 읽는 `val attempts` 6개(17번).
- **h**: variant → 문장 한 방향의 `*_to_string` 표와 문서 주석은 뺐다. 자기 문장을 파싱·비교하는 곳은 none found. LLM 프롬프트 리터럴도 none found(`~prompt:message` 는 사용자 입력).
- **i**: `lib/auth/authz_record.ml:216` 은 raw string 안의 `[|` 라 오탐이다. `lib/auth/oidc_google_exchange.ml:20-21`, `lib/auth/oidc_login_transaction.ml:132` 는 stdlib `Mutex` 안에서 I/O 없이 대입만 하고 값은 persistent Map 이라 뺐다.

## 7. 읽지 않은 것

- 범위 `.ml` 79개는 모두 읽었다. 그중 56개는 이 세션 문맥이 요약되기 전에 읽었고, 그 판정은 요약 기록에 기댄다. 1~7, 11, 12, 16, 23번과 표의 수치는 이번에 줄 단위로 다시 확인했다.
- 범위 `.mli` 79개는 본문을 읽지 않고 rg hit 만 봤다. 일부만 읽은 것: `lib/runtime/runtime_account_access.mli:1-90`, `lib/runtime/runtime_account_home.mli`, `lib/auth/authz_bootstrap.mli:14-34`, `lib/auth/authz_external_store.mli:136-150`.
- 범위 밖은 교차 확인한 줄만 읽었다: `lib/types/types_auth.ml:120-260`, `lib/config/env_config_core.ml:300-340,390-410`, `lib/config/config_boot_overrides.ml:1-64`, `lib/server/server_auth_config.ml`, `lib/host_config/host_config.ml:40-56`, `lib/runtime/runtime_codex_app_server.ml:495-530`, `lib/keeper_runtime/keeper_runtime_config.ml:690-720`, `bin/main_eio.ml:1160-1176,1228-1246`.
- 읽지 않은 것: 시험 코드 전부(호출처 rg 만), `execution.timeout_s` 의 정의와 뜻, SSE 이벤트 이름의 서버 쪽 소유자(`lib/server/server_setup_account_login.ml` 은 :6 만 봄), `Host_config.host ()` 전체, `MASC_HTTP_DEV_MUTATION_ORIGINS`·`MASC_BASE_PATH_LEASE_DIR`·`MASC_CONFIG_DIR` 에 대한 config 필드 유무.
- 하지 않은 것: 빌드, 시험, 실행 재현. 5번(세션·PAT 인증이 파일 정지를 안 묻는 것)과 2번(읽지 못한 config.json 으로 부팅)은 코드 읽기로만 판정했다.
