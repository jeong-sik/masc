# 감사 2/8 전수 판정 — 2026-11-08 (task-3362 취합 문서)

작성: claude-62be833e. 감사 원문: board:p-552e3b078e87319dad966f79e837d6c2 및
jeong-sik/masc#49741. 모든 좌표는 main 08c901ec380c(판정 시점 origin/main)에서
재직독해 판정했다. 수리 커밋은 이 문서가 속한 PR에 실려 있다.

## 항목 1 JSON 필드 추출기 — 수리 1 + 이전 해소 확인 1 + 판정 3

| 좌표(감사 시점) | 판정 | 근거 |
| --- | --- | --- |
| `lib/core/json_util.ml:187-205` 자기 복제(`int_option_to_yojson`/`int_opt_to_json` 등) | **이전 해소 확인** | 재실측: 동일 몸통 쌍이 사라지고 `int_opt_to_json`/`string_opt_to_json` 정본만 남음. "Use these instead of per-module definitions" 주석의 정본 |
| 중앙 헬퍼 5벌(`json_field`·`json_util`·`tui_decode_fields`·`dashboard_utils`·agent_core `json_util`) | **판정: 각자 다른 계약, 무변경** | `Json_field`는 3분기 extraction(`Found`/`Field_absent`/`Wrong_shape`), `Json_util`은 인코더+assoc 원시+`kind_name`, `Tui_decode_fields`는 `Result` 기반 required/optional 디코드, `Dashboard_utils`는 문자열 파생(`dedup_strings`는 아래 수리로 위임 처리), agent_core `Llm_provider.Json_util`은 패키지 최하층이라 lib 헬퍼를 의존하면 순환. 반환 타입·오류 의미가 다른 다섯 계약이지 한 계약의 다섯 벌이 아니다 |
| `json_type_name` 4벌 | **수리(이름 분리)** | 재실측 2정의(+변형명 1). `Llm_provider.Json_util.json_type_name`은 JSON wire 어휘(`Int`/`Float` → number), typed_input 쪽은 JSON Schema 어휘(integer/number 분리)라 합치면 오류 문장이 달라진다. 스키마 쪽을 `json_schema_type_name`으로 개명하고 주석으로 어휘 차이를 밝혔다. `Shared_types.Json_kind.name`은 yojson 변형명(intlit 등)을 노출하는 별도 공개 계약(`Json_util.kind_name`으로만 소비, 재실측)이고 `Json_field.yojson_variant_name`과 몸통이 같지만 한쪽은 공개·한쪽은 내부용이라 통합하면 잎 라이브러리에 서로 의존이 얹힌다 — 무변경 |
| 로컬 `string_field`/`int_field`/`bool_field` 50곳 이상(재실측 173정의) | **판정: 무변경** | 지역 헬퍼는 `string -> json -> string option` 3줄 얇은 포장이다. `Json_field.string`은 3분기 extraction이라 `None` 분기의 의미가 다르고, 전환은 173개 호출처의 오류 흐름을 다시 짜는 의미 변경이다. 이득은 줄 수뿐 — 무리한 추상화보다 반복이 낫다(constitution `engineering.abstraction`) |

## 항목 2 문자열 / UTF-8 / trim / dedupe — 수리 2 + 이전 해소 확인 2 + 판정 2

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `keeper_librarian_absorb_gate.ml:8-31` `is_ascii_space`·`utf8_length`·`strip` | **수리** | `strip` → `String.trim`(문장 양끝 수직 탭을 더 이상 떼지 않는다 — 같은 파일의 다른 경로가 이미 `String.trim`을 쓴다), `utf8_length` → `String_util.utf8_length`, `is_ascii_space` → `is_prose_separator`로 개명(붙여넣은 로그의 폼피드·수직 탭을 포함하는 문장 분리 집합임을 주석화) |
| UTF-8 세기 4벌(`string_util`·absorb_gate·`tool_input_contract:481-493`·`wiki_rank:25-52`) | **수리** | `String_util.utf8_length` 신설(표준 `String.get_utf_8_uchar` 순회, 잘못된 바이트도 1자로 세며 항상 진행). `tool_input_contract.utf8_character_count`는 이 정의였으므로 삭제하고 호출, absorb_gate 와 함께 이 한 곳로 합쳤다. `wiki_rank`의 `utf8_length`는 리드 바이트가 여는 시퀀스 길이(문자 수 아님)라 `utf8_sequence_length`로 개명해 혼동을 없앴다 |
| `String_util.trim_nonempty` 재구현 7곳 | **이전 해소 확인 + 수리** | 재실측: `masc_tui_http`·`eval_tool_selector`·`keeper_librarian`은 이미 별칭 위임. `board_tool_format.trim_nonempty_string`(몸통 동일)은 이번에 위임으로 바꿨다. `voice_config.trim_nonempty_json`은 입력이 Yojson 값이라(`json -> string option`) 다른 계약 — 무변경 |
| `dedupe_keep_order` 중복 | **이전 해소 확인 + 수리** | `dashboard_utils.dedupe_keep_order` 사본은 이미 사라짐(재실측). 잔여 `dashboard_utils.dedup_strings`(Set 기반 자체 구현)을 `Json_util.dedupe_keep_order` 위임으로 바꾸고 안 쓰는 `String_set` 별칭을 지웠다. `mcp_server_eio_protocol.dedup_strings`(`List.sort_uniq`)은 정렬된 결과가 계약(리소스 목록)이라 무변경 |

## 항목 3 시각 포맷 — 수리 1 + 이전 해소 확인 2 + 판정 2

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `msx_lane.ml:1263-1268` 수동 RFC3339 | **이전 해소 확인** | 재실측: `Time_codec.rfc3339_of_unix stats.st_mtime` 호출 |
| `keeper_sandbox_image_version.ml:201-205` 수동 gmtime | **판정: 무변경** | 해당 함수 `build_minute`는 분 단위 도커 태그(`%04d%02d%02dT%02d%02dZ`, 초 없음)이지 RFC 3339 스탬프가 아니다. 같은 파일의 `rfc3339_utc`는 이미 `Time_codec` 위임(재실측) |
| agent_core `log.ml:194-197` 수동 gmtime | **판정: 무변경** | llm_provider 라이브러리는 lib/time_codec 위층을 의존할 수 없다(`agent_core` 본체→llm_provider, `agent_core_base`→llm_provider 방향이므로 순환). 패키지 안의 RFC 3339 스탬프가 이 한 곳뿐이라 하부 기판 라이브러리를 새로 만들지 않는다 |
| `Types_core.now_iso` 중복(`prompt_preset.ml:134`, `keeper_meta_contract.ml:9`) | **수리(반쪽) + 이전 해소 확인** | `prompt_preset`의 동일 몸통 지역 정의를 지우고 `Types_core.now_iso`를 부른다. `keeper_meta_contract`은 이미 `Masc_domain.now_iso` 위임(`Masc_domain`은 `Types_core` 포함 재수출 퍼사드, 재실측) |
| `Jsonl_writer.day_key` 중복(`workspace_memory_execution_capture.ml:19-20`) | **이전 해소 확인** | 재실측: `Jsonl_writer.day_key` 위임 |

## 항목 4 원자적 파일 쓰기 — 수리 3 + 이전 해소 확인 1 + 판정 4

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `telemetry_unified.ml:1008-1018` | **이전 해소 확인** | 재실측: `Fs_compat.save_file_atomic` 호출 |
| `dos_lane.ml:661-673` `write_atomically`(+재귀 `mkdir_p`) | **수리** | 고정 tmp 이름(`.<name>.tmp`) 직접 쓰기를 지우고 `Fs_compat.save_file_atomic`을 부른다. `keep_writes`는 `Result`를 받고 `mkdir_p` 실패만 예외로 잡는다. 고정 tmp 이름은 동시 호출이 서로의 임시 파일을 겹칠 수 있었다 |
| `msx_lane.ml:941-962` `atomic_write` | **수리** | `Fs_compat.save_file_atomic_strict_staged`로 바꾼다(payload·상위 fsync, 임시 파일 정리, 취소 정리 후 재발생은 정본 경로). 레인은 실패 단계만 자기 오류 분류로 옮긴다 — rename 앞 실패 `Unreadable`(이전 체크포인트 유지), 뒤 실패 `Effect_unknown`. 정확히 기존 `replaced` 플래그의미와 일치한다 |
| `keeper_identity_tools.ml:186-209`·`server_keeper_oauth.ml:608-632` `write_private_file_atomic` 3벌 | **수리** | 카탈로그·해지 영수증의 같은 몸통(고정 `path ^ ".tmp"`) 쌍을 `Keeper_identity_tools.write_json_snapshot` 하나로 합친다. 임시 파일은 `Filename.temp_file`로 대상 옆 고유·0600. 잔여 1벌 `keeper_oauth_client_store.write_whole`(lib/keeper_identity 잎)은 이미 고유 tmp·0600 계약이고 Fs_compat(Eio 기판) 의존을 잎에 얹는 비용이 크다 — 무변경 |
| `masc_tui_msx_checkpoint_pending.ml:69-77` | **판정: 무변경** | 의도 체크포인트 쓰기는 fsync 후 directory sync 실패 시 의도를 철회하는 도메인 내구성 계약이 붙어 있어 일반 원자적 쓰기로 흡수할 수 없다 |
| `masc_exec_ssh_bootstrap.ml:172-198` | **판정: 무변경** | 재실측: 원자적 갱신이 아니라 1회성 새 파일 생성(ssh 호스트 키·원격 토큰 stdin)이라 대상이 다르다 |
| agent_core `fs_result.ml:100-130` vs `llm_provider/metrics.ml:175-199` | **판정: 무변경(층위)** | `Fs_result`는 agent_core 본체 모듈이고 본체→llm_provider 의존 방향 때문에 llm_provider의 `metrics`가 부르면 순환이다. metrics 사본은 패키지 최하층의 유일 사본(fsync·fsync_dir·고유 tmp 포함, 재실측) |

## 항목 5 수제 AVL / TOML 헬퍼 / Random ID — 수리 1 + 판정 2

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `tool_metrics.ml:28-120` 수제 `Duration_tree` AVL | **수리** | 표준 `Map.Make(Float)`(값→개수 다중집합)로 교체. 백분위 선택은 오름차순 바인딩을 한 번 훑는 선형 탐색이고 읽기는 `all_stats` 캐시를 통과한다(기록 1건이 캐시 무효화). 순서·다중도·선택 의미는 동일 |
| TOML 검증 헬퍼 3벌(composition_catalog·skill_source_config·skill_reference) | **판정: 무변경** | 재실측: 세 파일 모두 표준 `Keeper_toml_loader`로 파싱한다. 그 위의 헬퍼들은 각자 닫힌 오류 ADT(`Empty_name`/`Wrong_value_kind`/`Expected_object` 등)를 가진 도메인 디코더라 몸통이 같지 않고, 공유 추출은 오류 타입 전체를 합치는 재설계가 된다 |
| Random ID 2벌(lib/random_id vs agent_core llm_provider/random_id) | **판정: 무변경** | lib 쪽은 `Crypto_rng`+UUIDv7 정본, agent_core 쪽은 `Mirage_crypto_rng_unix` 직접 사용 `Result` 계약의 최소 hex. 층위(llm_provider는 lib 의존 불가)·에러 계약(예외 vs `Result`)·기능 범위가 다르다 |

## 감사 후속 (이번 전수로 새로 등기하는 것)

없음. 판정·수리로 닫히지 않은 열린 끝은 없다. 로컬 `*_field` 얇은 포작 173곳은
위 판정대로 유지 원칙이고, 이후 새 코드가 같은 포장을 만드는 것은 금지 아니다.

## 수리 커밋 (이 PR)

1. `refactor(utf8)` — String_util.utf8_length 신설, absorb_gate·tool_input_contract·wiki_rank·dashboard_utils 정리
2. `refactor(time)` — prompt_preset now_iso → Types_core 위임
3. `refactor(fs)` — dos_lane·msx_lane 원자적 쓰기 → Fs_compat 정본
4. `refactor(metrics)` — Duration_tree AVL → Map.Make(Float) 다중집합
5. `refactor(keeper)` — json_schema_type_name 개명
6. `refactor(keeper)` — 카탈로그·영수증 스냅샷 쓰기 write_json_snapshot 통합 + board trim_nonempty 위임
