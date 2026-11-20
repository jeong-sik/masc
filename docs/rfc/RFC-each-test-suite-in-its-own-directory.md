---
rfc: "each-test-suite-in-its-own-directory"
title: "Each test suite lives in its own directory, so Dune finds it without a hand-kept include list"
status: Draft
created: 2026-11-20
updated: 2026-11-20
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: 시험마다 자기 디렉터리를 가져서 dune 이 손 목록 없이 찾는다

- 관련: #53664, #53690(이 RFC), #53685(첫 조각), #12425(`.inc` 로 나눈 PR)
- 숫자는 2026-11-20 `origin/main`(1c604689ccb8d)에서 셌어요.

## 지금 사실

### 시험이 어디에 선언돼 있나

| 자리 | 수 |
|---|---|
| `test/dune` 줄 수 | 7,810 |
| `test/dune` 의 `(include stanzas/*.inc)` 줄 | 1,061 (`test/dune:143` ~ `test/dune:7810`) |
| `test/stanzas/*.inc` | 1,061 + `README.md` |
| `test/dune` 안에 바로 쓴 `(test ...)` | 638 |
| `test/dune` 의 `(tests (names ...))` 묶음 | 4개, 이름 497개 (`test/dune:524` 347개, `:1792` 8개, `:1813` 1개, `:1923` 141개) |
| `test/` 자체(dune + `.inc`)에 사는 시험 이름 | 2,151 (stanza 1,657) |
| 이미 자기 디렉터리를 가진 시험 디렉터리 | 42 (`test/voice_wizard/dune` 등, 이름 62개) |
| `test/dune` 의 helper `library` | 9 (`exact_output_fixture`, `librarian_floor_fixture` 등) |

### 왜 `.inc` 로 나눴나

`test/stanzas/README.md` 와 #12425(2026-05-01)가 이유를 적었어요.
모든 PR 이 `test/dune` 의 같은 끝에 stanza 를 붙여서 서로 충돌했어요.
그래서 stanza 를 파일로 빼고, `test/dune` 에는 정렬된 include 한 줄만 넣기로 했어요.

그 약속은 지금 지켜지지 않아요.

- include 줄은 한 덩어리가 아니라 448군데에 흩어져 있어요. 정렬돼 있지도 않아요(`LC_ALL=C sort -c` 가 둘째 줄에서 멈춰요).
- 최근 30일(2026-10-21 ~ 11-20) main 커밋 6,776개 중 912개가 `test/dune` 을 고쳤어요. 열린 PR 14개 중 6개가 지금도 `test/dune` 을 고쳐요.

### 빠뜨린 include 는 조용히 사라진다

dune 은 어느 stanza 의 `(modules ...)` 에도 없는 `.ml` 을 경고 없이 건너뛰어요.
장난감 프로젝트(dune 3.24.2, `lang dune 3.22`)에서 stanza 없는 `t_b.ml` 을 두고 `@test/runtest` 를 돌렸어요.
`t_b` 는 빌드도 실행도 안 됐고, dune 은 아무 말도 안 했어요.

이 빠뜨림을 잡는 검사는 main 에 없어요.
`rg` 로 `scripts`·`.github`·`tools` 에서 include 나 미소속 모듈을 세는 검사를 찾았지만 0건이에요.
지금 main 에는 미소속 시험 모듈이 0개예요(`test/*.ml` 2,198개 모두 어느 stanza 에 속해요). 사람이 매번 맞게 넣었을 뿐이에요.

### dune 을 dune 밖에서 다시 읽는 곳

- `scripts/ci/stanza_env.py`(619줄): 표적 실행이 실행 파일을 셸에서 돌리느라 stanza 의 env·deps 를 다시 읽었어요. #53685 가 표적 실행을 dune 의 `@@DIR/runtest-NAME` 별칭으로 바꾸고, 이 파일을 예산 밖 선빌드 대상만 말하는 `scripts/ci/alias_prebuild_deps.py` 로 줄여요.
- `scripts/ci-run-targeted-tests.sh:47-75`: shard 모드가 `test/dune`, `test/stanzas/*.inc`, `test/*/dune` 을 정규식으로 읽어 시험 이름을 모아요. 이 shard 모드를 부르는 workflow 는 없어요(`rg SHARD_COUNT .github` 0건).
- `scripts/ci/check-test-prompt-deps.py:126-132`: `.inc` 면 모듈이 한 단계 위 디렉터리에 있다고 따로 처리해요.
- `.github/workflows/test.yml:146-160` 과 러너의 이름 풀이: `test/<name>.ml` 이 있는지로 스위트를 찾아요.

### 옮길 때 걸리는 것

- **같이 쓰는 모듈**: `test/dune:524` 의 347개 묶음은 `test_keeper_state_machine_preconditions` 와 `test_operator_control_confirm` 을 묶음 안 이름들이 같이 써요. `test/stanzas/test_oidc_id_token_signature.inc` 의 묶음은 `oidc_id_token_vectors` 를 같이 써요. 디렉터리를 나누면 이 모듈은 library 가 돼야 해요.
- **lib 모듈 복사**: `test/dune:2284-2285` 가 `../lib/server/server_full_health_refresh_state.ml(i)` 를 `test/` 로 복사하고, `test_server_runtime_bootstrap` 이 그 모듈을 자기 `(modules ...)` 에 넣어요(`test/dune:2289`).
- **실행 디렉터리**: dune 은 시험을 그 stanza 의 디렉터리(sandbox 안의 `default/test`)에서 돌려요. `test/<name>/` 로 옮기면 작업 디렉터리가 한 단계 내려가요. deps 가 있는 이름이 674개이고, 코드에 `"../`·`"fixtures/`·`"./` 로 시작하는 경로 문자열이 있는 시험 파일이 144개예요. 이 144개를 다 읽지는 않았어요.
- **다른 stanza 가 시험 실행 파일을 부르는 곳**: `test/dune` 의 rule 이 `%{exe:test_runtime_verification.exe}`, `%{exe:test_keeper_codex_current_context.exe}` 처럼 시험 실행 파일을 인자와 함께 돌려요. 옮기면 경로가 `test_x/test_x.exe` 로 바뀌어요.
- **`(env)`**: `test/dune:487` 의 `(env (_ ...))` 는 하위 디렉터리에도 적용돼요. 장난감 프로젝트에서 `test/sub/` 의 시험이 `test/dune` 의 env-vars 를 받는 것을 확인했어요. 옮겨도 그대로예요.

## 목표 모양

```
test/
  dune                      ; (env), helper library, 여러 시험이 같이 쓰는 rule 만
  fixtures/                 ; 그대로
  test_keeper_turn_interrupt/
    dune                    ; (test (name test_keeper_turn_interrupt) ...)
    test_keeper_turn_interrupt.ml
  ...
```

- 시험 하나 = 디렉터리 하나. dune 이 디렉터리를 찾으니 include 목록과 빠뜨림 검사가 필요 없어요.
- 새 시험을 더하는 PR 은 새 디렉터리만 더해요. 다른 PR 과 같은 파일을 고치지 않아요.
- 시험 하나는 `dune build @@test/<name>/runtest-<name>` 이나 `dune build @test/<name>/runtest` 로 돌아요.
- `test/stanzas/` 와 그 README 는 없어져요.

## 옮기는 방법

codemod 한 번으로 옮겨요. 손으로 옮기지 않아요.

1. `test/dune` 과 `.inc` 를 S-expression 으로 읽어 이름 있는 시험마다 stanza 를 꺼내요.
2. `(tests (names ...))` 묶음은 이름마다 `(test (name X) ...)` 로 펼쳐요. 묶음의 `libraries`·`deps`·`action`·`flags` 는 이름마다 복사해요.
3. stanza 안의 상대 경로(deps 의 literal, `%{dep:..}`, `%{exe:..}`)에 `../` 를 붙여요. `%{workspace_root}`·`%{project_root}` 경로는 그대로 둬요.
4. 실행 디렉터리를 지키려고 action 을 `(chdir .. ...)` 로 감싸요(D2). action 이 없는 stanza 는 `(action (chdir .. (run %{test})))` 를 받아요. 장난감 프로젝트에서 `(deps ../fixtures/x.txt) (action (chdir .. (setenv FOO bar (run %{test}))))` 가 `cwd=test` 로 돌고 `fixtures/x.txt` 를 읽는 것을 확인했어요.
5. `(modules ...)` 의 모듈마다 `git mv test/<m>.ml test/<name>/<m>.ml` 해요(`.mli` 도).
6. `test/dune` 에서 그 include 줄과 stanza 를 지우고, `.inc` 를 지워요.
7. `test/dune` 의 rule 이 시험 실행 파일을 부르는 경로를 `test_x/test_x.exe` 로 바꿔요.

### 옮김이 기계적이었는지 확인

- 이름 집합: 옮기기 전 `test/dune`+`.inc` 의 시험 이름 집합과 옮긴 뒤 `test/*/dune` 의 이름 집합이 같아요. 스크립트로 비교해요.
- 모듈: `git diff --name-status -M` 에서 `.ml`·`.mli` 는 모두 `R100`(내용 그대로 이름만 바뀜)이에요.
- stanza: 옮긴 stanza 의 토큰 열이, 옛 stanza 에 3·4단계 변환만 적용한 토큰 열과 같아요. 스크립트로 비교해요.
- dune: PR 의 Merge compile 이 타입 검사를 해요. 묶음 PR 마다 운영자에게 전체 `@runtest` 한 번을 요청하고, main 의 마지막 전체 회귀와 성공·실패 스위트가 같은지 봐요.

## 조각

| 조각 | 내용 | 확인 |
|---|---|---|
| S0 | 표적 실행을 dune 의 `runtest-NAME` 별칭으로 돌리고 `stanza_env.py` 를 선빌드 리더로 줄인다 | #53685. `scripts/ci/tests/test_targeted_stanza_isolation.py` |
| S1 | 같이 쓰는 모듈 셋(`test_keeper_state_machine_preconditions`, `test_operator_control_confirm`, `oidc_id_token_vectors`)과 `copy_files` 한 lib 모듈을 library 로 만든다 | 각 시험이 자기 모듈만 가져요. Merge compile |
| S2 | 러너·`test.yml`·`check-test-prompt-deps.py` 가 `test/<name>/<name>.ml` 을 찾게 한다(D3) | 경계 시험에 새 경로 사례 |
| S3 | codemod 스크립트와 그 비교 스크립트를 더한다. 첫 묶음(이름 a~d)을 옮긴다 | 위 「확인」 넷 |
| S4 | 나머지 묶음을 옮긴다. 묶음은 열린 PR 이 `test/dune` 을 적게 고칠 때 연다(D4) | 같은 넷 |
| S5 | `test/stanzas/`·README, 러너 shard 모드의 `.inc` 읽기, `check-test-prompt-deps.py` 의 `.inc` 분기, `CONTRIBUTING.md:134` 를 지운다 | `rg 'stanzas/' scripts .github test docs` 0건 |

묶음 PR 이 열린 PR 과 충돌하면 충돌을 손으로 풀지 않아요. main 위에서 codemod 를 다시 돌려요.
codemod 는 결정적이라 같은 입력이면 같은 결과가 나와요.

## 열린 결정

- **D1 디렉터리 이름**: 시험 이름 그대로(`test/test_keeper_turn_interrupt/`)를 권해요. `TARGET_SUITES`, `runtest-NAME`, `config/release-behavior.json` 이 모두 이 이름으로 말해요. 접두어를 떼면(`test/keeper_turn_interrupt/`) 짧지만 이름이 둘이 돼요.
- **D2 실행 디렉터리**: `(chdir ..)` 로 감싸면 시험 코드를 안 고치고 옮길 수 있어요. 대신 stanza 마다 감싸는 줄이 하나 늘어요. 시험이 경로를 `%{dep:...}` 인자나 env 로 받게 고치면 감쌀 필요가 없지만, 144개 파일을 하나씩 읽고 고쳐야 해서 기계적이지 않아요. 옮김은 `(chdir ..)` 로 하고, 시험을 고치는 일은 따로 하기를 권해요.
- **D3 이름 풀이**: 러너가 맨 이름 `test_x` 를 `test/test_x/test_x.ml` 로도 찾게 할지, 호출하는 쪽(`config/release-behavior.json`, workflow 입력)이 `test_x/test_x` 로 쓰게 할지 정해야 해요. 맨 이름을 권해요. 디렉터리 하나에 시험 하나라 이름이 겹치지 않아요.
- **D4 언제**: 묶음 PR 은 `test/dune` 을 고치는 열린 PR 을 모두 깨요. 운영자가 정한 짧은 창에 S3·S4 를 연달아 넣기를 권해요.
- **D5 묶음 하나 = 디렉터리 하나?**: `(tests (names ...))` 묶음을 디렉터리 하나에 두면 묶음 필드를 복사하지 않아도 돼요. 하지만 347개 묶음 디렉터리가 지금의 `test/dune` 처럼 충돌 자리가 돼요. 이름마다 디렉터리를 권해요.

## 해 보고 버린 것

- **`(dynamic_include)` 로 `.inc` 를 모으기**: 장난감 프로젝트에서 `test/stanzas/dune` 의 rule 이 `*.inc` 를 이어 붙이고 `test/dune` 이 그것을 `dynamic_include` 하게 했어요. dune 이 `Dependency cycle` 로 거절했어요. 생성 rule 을 형제 디렉터리에 두면 돌지만, 시험 목록이 소스가 아니라 빌드 산출물이 돼요. `test/dune` 을 읽어서는 어떤 시험이 있는지 알 수 없어요.
- **`(include stanzas/*.inc)` glob**: dune 이 `File test/stanzas/*.inc doesn't exist` 로 거절해요. `include` 는 파일 하나만 받아요.
