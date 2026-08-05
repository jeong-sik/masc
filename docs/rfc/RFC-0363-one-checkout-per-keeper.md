# RFC-0363 — keeper 당 체크아웃 하나 (`repos/` 중간 디렉터리 폐기)

- Status: Draft
- Updated: 2026-08-05
- Author: vincent
- Related: RFC-0343 (repo location SSOT), RFC-0312 (keeper-repo-mapping advisory scope), RFC-0324 (filesystem repo truth), RFC-0128 §4.5 (write partition)
- Supersedes: RFC-0343 의 LIVE 범위 (§3.1 reverse-parse attribution) — 이 RFC 가 채택되면 그 메커니즘이 존재할 자리가 없어진다

## 0. Summary

keeper 의 playground 는 `.masc/playground/<keeper>/` 이고, 체크아웃은 그 아래 `repos/<repo>/` 에 놓인다. 중간 디렉터리 `repos/` 는 **keeper 하나가 체크아웃 여러 개를 갖는다**는 전제에서만 필요하다.

그 전제는 강제되지 않으며 사용되지도 않는다. 이 RFC 는 전제를 폐기하고 playground root 자체를 체크아웃으로 만든다. 다른 코딩 에이전트가 작업 디렉터리 하나를 받는 것과 같은 모양이다.

## 1. Problem (evidence)

### 1.1 능력이 아무것도 강제하지 않는다

`repository_scope` 의 유일한 소비자는 `server_routes_http_routes_keeper_repos.ml:20` 이고, 대시보드에 `allow_all : bool` 을 그리는 것이 전부다. 같은 응답이 정책 값을 리터럴로 내보낸다:

```ocaml
("policy_mode", `String "advisory");
("access_cap",  `Bool false);
```

RFC-0312 가 제목부터 `advisory-scope` 로 명시적 강등을 기록했다. 매핑은 접근을 막지 않는다. keeper 가 저장소 3개에 매핑되어 있든 0개든 동작이 같다.

같은 함수가 `repository_ids` 를 `repositories` 와 `allowed_repos` 두 키로 내보낸다. 하나는 SSOT, 하나는 그 복제다.

### 1.2 다중 매핑이 실제로 없다

측정한 `repositories.toml` (2026-08-05):

| repository | keepers |
|---|---|
| masc | `["nick0cave", "ramarama"]` |
| oas | `[]` |
| wkbl | `[]` |
| kirin | `[]` |
| grpc-direct | `[]` |
| ocaml-webrtc | `[]` |

저장소 6개 중 매핑된 것은 1개. **keeper 하나가 저장소 둘 이상을 갖는 사례 0건.**

### 1.3 비용

`"repos"` 는 프로덕션 OCaml 코드에 9곳으로 흩어져 있다. writer 와 reader 를 잇는 불변식은 없다.

| 역할 | 위치 |
|---|---|
| 호스트 경로 조립 | `keeper_sandbox_repo_path.ml:12,106` · `keeper_sandbox_control.ml:290,415` · `keeper_turn_sandbox_runtime.ml:119` · `keeper_alerting_path.ml:791` |
| 모델 대면 어휘 | `keeper_sandbox.ml:171,172` · `keeper_sandbox_control.ml:442` · `keeper_turn_sandbox_runtime.ml:164` · `keeper_run_tools_hooks.ml:77` · 툴 스키마 산문 4곳 |
| 역파싱 | `keeper_sandbox_repo_path.ml:103` · `playground_paths.ml:173,176` |

`keeper_sandbox_repo_path.ml:106` 은 두 줄 위의 `repo_root_of_playground_root` 와 같은 조립을 인라인으로 반복한다 (모듈 내부 중복).

### 1.4 가르친 레이아웃이 이미 두 번 거짓이 됐다

- RFC-0343 §1 이 기록한 사고: 프롬프트 불변식 *"every catalog id resolves under `repos/<name>/`"* 가 **거짓이어서 제거**됐다 (RFC-0324 B-1). 그 전까지 `path_not_found` 379/24h (2026-07-08 audit). keeper 들이 clone 된 적 없는 경로를 믿었다.
- 남은 잔여물도 이미 거짓이다. `tool_shard_types_schemas_search_files.ml:12` 가 `'repos/X' or 'scratch/X'` 를 가르치는데, **`scratch/` 를 만드는 코드가 없다.** `scratch` 는 코드베이스 전체에서 그 문장과 `keeper_run_tools_hooks.ml:77` 허용목록 두 곳에만 존재한다.

허용목록과 번들 생성기도 어긋나 있다. 생성기(`sandbox_bundle_paths_of_meta`)는 `[root; root/repos]` 2개를 만들고, 허용목록은 4개 세그먼트를 통과시킨다.

### 1.5 역파싱은 이 전제의 직접 산물이다

`parse_playground_repo_path` (`playground_paths.ml`, live caller `keeper_tool_filesystem_runtime.ml:481`) 는 keeper 의 쓰기 경로를 `(repo_id, rel)` 로 되돌린다. 이 함수가 필요한 이유는 **keeper 가 N 개 중 어디에 썼는지 모르기** 때문이다.

RFC-0343 은 이것을 `git remote get-url` 로 대체하자고 제안한다. 체크아웃이 하나면 되돌릴 것이 없다 — 있는 곳이 곧 그 저장소다.

### 1.6 죽은 잔여물

`Playground_paths.repos_path`, `Playground_paths.bundle_paths`, `Keeper_alerting_path.playground_bundle_paths`, `Keeper_alerting_path.ensure_playground_bundle` 은 프로덕션 호출자가 0이고 sandbox_profile 도입 이전의 Local 전용 버전이다 (PR #27010 에서 삭제). `Playground_paths.parse_playground_file_path` 도 프로덕션 호출자가 0이다.

## 2. Non-goals

- 저장소 **정체성** 저장 방식 변경. `repositories.toml` 이 identity SSOT 로 남는다.
- 마이그레이션 코드. 이 변경은 hard cut 이다 — 과거 레이아웃을 읽는 호환 경로나 변환기를 넣지 않는다. 기존 playground 는 재생성 대상이지 변환 대상이 아니다.
- keeper credential / GitHub identity (RFC 게이트 별건).
- Docker `docker/` 세그먼트 자체의 존폐 (RFC-0343 이 D8 로 분리해 둔 항목).

## 3. Design

### 3.1 playground root 가 체크아웃이다

```
현재:  .masc/playground/<keeper>/repos/<repo>/<파일>
변경:  .masc/playground/<keeper>/<파일>
```

keeper 의 ownership root 가 곧 작업 트리다. `Keeper_sandbox_config.host_root_abs_of_agent` 가 반환하는 경로가 `git rev-parse --show-toplevel` 과 일치한다.

keeper 가 어느 저장소를 받는지는 `repositories.toml` 의 `keepers` 필드가 결정한다 — 지금과 같다. 달라지는 것은 keeper 당 **하나**라는 것이 타입과 레이아웃에 나타난다는 점이다.

### 3.2 사라지는 것

| 대상 | 근거 |
|---|---|
| `"repos"` 문자열 9곳 | 조립할 세그먼트가 없다 |
| `parse_playground_repo_path` + 호출자 | 되돌릴 것이 없다 (§1.5) |
| `parse_playground_file_path` | 이미 프로덕션 호출자 0 |
| `execution_location_scope` 의 `Repo_root` / `Repo_subpath` | `Playground_root` / `Playground_subpath` / `Outside_playground` 로 충분 |
| `keeper_sandbox.ml` 의 `repos_arg`, `task_overlay_pattern` | 알릴 구조가 없다 |
| wire `sandbox_repos`, `sandbox_paths.repos` | 위와 동일 |
| 툴 스키마의 `repos/X` 산문 4곳 | 관측 채널이 대체 (§3.3) |
| 허용목록의 `"repos"`, `"scratch"` | `scratch` 는 애초에 유령 |
| RFC-0343 §3.1 (origin URL 귀속) | 풀 문제가 사라진다 |

### 3.3 모델에게 레이아웃을 가르치지 않는다

경로 규약을 산문으로 가르치는 것이 §1.4 의 두 사고를 만들었다. 대신 keeper 는 이미 관측 채널을 갖고 있다:

- `Keeper_sandbox_repo_path.execution_location_json` 이 Execute 응답마다 `scope` / `playground_root` / `relative_cwd` 를 실측으로 돌려준다.
- `tool_list_dir` / `tool_read_file` 로 직접 확인할 수 있다.

관측은 거짓이 될 수 없고, 산문은 될 수 있다.

남길지 판단이 필요한 것은 **네임스페이스** 지시("호스트 절대경로를 넣지 말 것")다. 이것은 레이아웃이 아니라 규약이며, 위반이 조용히 실패하는지 타입 있는 거부로 돌아오는지에 따라 결정한다. 조용히 실패한다면 산문이 아니라 그 거부를 고칠 문제다.

## 4. 검증

이 RFC 를 구현했다고 말하려면 다음이 성립해야 한다.

1. `rg '"repos"' lib/ bin/` 이 `config_dir_resolver.ml` 의 `.masc/repos` (오퍼레이터 작업 트리, 별개 개념) 외에 아무것도 반환하지 않는다.
2. `parse_playground_repo_path` / `parse_playground_file_path` 가 존재하지 않는다.
3. `execution_location_scope` 가 3개 생성자다.
4. keeper 가 부팅해 자기 트리에서 파일을 읽고 쓰고 커밋하는 경로가 통합 테스트로 증명된다.
5. `path_not_found` 카운터가 변경 전 기준선을 넘지 않는다 (§1.4 재발 방지).

## 5. Open questions

1. **다중 저장소를 쓸 계획이 있는가.** 코드는 "지금은 아무 역할도 없다" 고 답했다 (§1.1, §1.2). 계획이 있다면 이 RFC 는 무효이고, 대신 `repository_scope` 를 실제로 강제하는 쪽이 과제가 된다 — 지금처럼 표시만 하는 상태가 최악이다.
2. **한 keeper 가 두 저장소를 필요로 하는 작업이 실제로 있는가.** 있다면 두 번째 keeper 를 띄우는 비용과, `repos/` 를 유지하는 비용(§1.3, §1.4)을 비교해야 한다.
3. **Docker `docker/` 세그먼트.** 이 RFC 와 직교하지만, 둘 다 정리하면 레이아웃이 `.masc/playground/<keeper>/` 하나로 수렴한다.

## 6. 이 RFC 를 채택하지 않는 경우

`repos/` 를 유지한다면 §1.3 의 9곳을 상수 하나로 수렴시키고, `scratch` 유령을 제거하고, 허용목록과 번들 생성기를 일치시켜야 한다. 그 작업은 이 RFC 가 채택되면 전부 불필요해지므로, 채택 여부를 먼저 정하는 것이 순서다.
