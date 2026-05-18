---
rfc: "0128"
title: "IDE store partitioning by canonical git URL — sandbox/working-tree write-read parity"
status: Active
created: 2026-05-17
updated: 2026-05-18
author: vincent
supersedes: []
superseded_by: null
related: ["0035", "0036", "0084"]
implementation_prs: [16028, 16036, 16040, 16044, 16049, 16053, 16055, 16058, 16061, 16062, 16063]
---

# RFC-0128 — IDE store partitioning by canonical git URL

## 1. Context

`.masc-ide/` 는 keeper 가 만든 code annotation/region 의 disk store다 (`lib/ide/ide_paths.ml:1` — `store_subdir = ".masc-ide"`). 의도: keeper 가 어떤 파일의 어떤 라인을 어떤 turn 에서 손댔는지 IDE 가 overlay 로 보여준다.

2026-05-17 현재 working 시스템에서 IDE 가 "라이브 정보가 안 뜬다 / 파일 트리가 비어 보인다 / `.masc-ide/` 가 비어있다" 는 사용자 보고가 들어왔다. 트레이스 결과 단순 설정 미스가 아니라 **read/write base 비대칭 + identity 모델 누락** 의 합이었다.

### 1.1 관측 사실 (working server 진단, port 8935)

서버 인보케이션: `--base-path=/Users/dancer/me` (Second Brain 루트).

| 경로 | base_dir 해결 | 코드 위치 | 결과 |
|------|--------------|----------|------|
| HTTP `/api/v1/ide/annotations?repo_id=X` 읽기 | `resolve_workspace_base` → `repo.local_path` (repo-aware) | `lib/server/server_ide_http.ml:92,129,223,260,266` | repo 별 partitioning **인지함** |
| Keeper file edit → region 기록 쓰기 | `Keeper_alerting_path.project_root_of_config config` → **서버 base_path flat** | `lib/keeper/keeper_exec_fs.ml:230`, `lib/keeper/keeper_alerting_path.ml:69` | repo 모름. 항상 `<server-base>/.masc-ide/regions.jsonl` |

읽기는 repo_id 인자를 보고 정확한 repo 디렉토리를 찾지만, 쓰기는 그 모델을 모른 채 서버 base 에 평면적으로 쌓는다. 결과: keeper 가 sandbox 안 repo clone 에 annotation 을 만들어도 사용자가 working tree 로 IDE 를 열면 **항상 빈 결과**.

### 1.2 sandbox/working-tree 동시 존재

Keeper 는 docker / playground sandbox 안에서 일한다. 같은 upstream 의 *별개 clone* 두 개가 동시에 존재한다:

```
<base-path>/.masc/playground/docker/tech_glutton/repos/masc-mcp/    ← keeper sandbox clone
~/me/workspace/yousleepwhen/masc-mcp/                        ← 사용자 working tree
```

`repositories.toml` 의 한 entry (예: `repository.masc`) 는 둘 중 하나만 가리킨다. 다른 하나는 등록되지 않거나 별 id 로 등록된다. 즉 **repo_id 는 *clone* 의 라벨이지 *codebase* 의 identity 가 아니다**.

이 비대칭 위에서 partitioning key 를 `repo_id` 로 잡으면 sandbox 쓰기 (`repo_id=masc`) 와 working tree 읽기 (`repo_id=masc-dev`) 가 다른 bucket 에 떨어져 join 자체가 안 된다.

### 1.3 유령 데이터 (제거 완료)

진단 중 `<base-path>/.masc-ide/2026-05/16.jsonl`, `17.jsonl` 발견. `code_region` 모양인데 현재 코드 (`Ide_region_tracker.append_region` → `regions.jsonl` 평면) 가 만들 수 없는 date-partitioned 포맷.

- `lib/ide/dune:22` 가 `dated_jsonl` lib 의존을 가지지만 lib/ide 안 `Dated_jsonl.` caller 0.
- 5월 이전 dated writer 가 있었다가 제거됐고, 디스크에 잔재만 남음.
- 본 RFC 작성 직전 삭제 (`rm /Users/dancer/me/.masc-ide/2026-05/{16,17}.jsonl`).

본 RFC 는 이 잔재의 재발을 막기 위해 *disk format 의 SSOT 화* 까지 범위에 포함한다.

## 2. 문제 정의

쓰기와 읽기가 같은 *codebase identity* 에서 만난다는 invariant 가 코드에 없다. 결과:

1. **Repo-blind 쓰기**: keeper 가 어떤 codebase 의 어떤 파일을 손댔는지 disk 가 모름. 라인 번호와 keeper_id 만 남고 codebase context 가 사라짐.
2. **Identity 불안정**: `repo_id` 라벨은 clone-local. 같은 upstream 의 sandbox/working-tree 별 clone 이 서로 분리된 store 를 만듦.
3. **누적 silent loss**: 위 둘로 인해 sandbox keeper 가 만든 데이터를 사용자 working tree 에서 볼 수 없음. counter 도 없음. 누가 알아채기 전엔 안 알아챔.
4. **Format 표류 가능성**: 코드 인터페이스 (`regions.jsonl` 평면) 와 disk 모양 (date-partitioned) 이 한 번 어긋난 적이 있고, 코드가 그 어긋남을 감지하지 못함.

## 3. 비목표 (Non-goals)

- Branch / ref 단위 partitioning. 같은 codebase 의 main 과 feature branch 에서 line shift 가 일어나는 문제는 본 RFC 범위 밖. 향후 RFC 로 분리.
- Multi-worktree 의 working-tree 별 분기. 같은 canonical_url 의 두 worktree 는 같은 bucket 을 공유한다 (장점: keeper sandbox 와 working tree 가 자동 join. 단점: 두 worktree 의 line 이 다르면 사용자가 구분해야 함 — 본 RFC 는 후자를 받아들임).
- 기존 `Ide_annotations.create` / `list` 외부 API 시그니처 변경. partition 은 *내부* 로 흡수.

## 4. 설계

### 4.1 SSOT — canonical URL

새 함수 `Ide_paths.canonical_url_of_remote : string -> string` 로 git remote 문자열을 host_path slug 으로 정규화한다.

정규화 규칙:

| 입력 | 출력 |
|------|------|
| `https://github.com/jeong-sik/masc-mcp` | `github.com_jeong-sik_masc-mcp` |
| `https://github.com/jeong-sik/masc-mcp.git` | `github.com_jeong-sik_masc-mcp` |
| `git@github.com:jeong-sik/masc-mcp.git` | `github.com_jeong-sik_masc-mcp` |
| `ssh://git@github.com/jeong-sik/masc-mcp.git` | `github.com_jeong-sik_masc-mcp` |
| (정규화 실패) | `None` → caller 가 `_orphan` bucket 으로 라우팅 |

규칙 본문:

1. 스킴 (`https://`, `ssh://`, `git@` prefix) 제거 후 호스트와 path 분리.
2. `.git` suffix 제거 (대소문자 무시).
3. host 와 path segment 를 `_` 로 join. path segment 안의 `/` 만 `_` 로, 다른 분리자는 reject (`None` 반환).
4. 결과는 `[a-z0-9._-]` + `_` 만 허용. 한 글자라도 벗어나면 reject.

테스트 케이스는 §6.1 에 명시.

### 4.2 디스크 레이아웃

```
<server-base>/.masc-ide/
  by-url/
    github.com_jeong-sik_masc-mcp/
      annotations.jsonl
      regions.jsonl
    github.com_jeong-sik_oas/
      annotations.jsonl
      regions.jsonl
  _orphan/
    annotations.jsonl    # canonical_url resolve 실패한 record
    regions.jsonl
```

- `_orphan/` 은 silent loss 회피용. counter `Prometheus.inc_counter ide_orphan_writes_total` (kind=annotation|region) 함께 증가.
- 기존 `<base>/.masc-ide/{annotations,regions}.jsonl` 평면 파일은 §5 migration 으로 처리.

### 4.3 시그니처 변경

`lib/ide/ide_paths.mli` 확장 (호환 유지 + 신규 함수):

```ocaml
val store_subdir : string                                (* unchanged *)
val store_path : base_dir:string -> string               (* unchanged — returns root .masc-ide/ *)
val by_url_path : base_dir:string -> canonical_url:string -> string
val orphan_path : base_dir:string -> string
val canonical_url_of_remote : string -> string option
```

`Ide_annotations` / `Ide_region_tracker` 내부에서 store 위치는 `canonical_url` 인자로 결정:

```ocaml
val create
  :  base_dir:string
  -> canonical_url:string option   (* None → _orphan/ *)
  -> keeper_id:string
  -> file_path:string               (* repo-relative when canonical_url=Some _ *)
  ...
```

### 4.4 file_path 정규화

`canonical_url=Some _` 일 때 `file_path` 는 *repo-relative* 만 받는다. caller 가 절대경로를 주면 boundary 에서 strip:

| 입력 | canonical_url | 정규화 |
|------|--------------|--------|
| `<base-path>/.masc/playground/docker/tech_glutton/repos/masc-mcp/lib/foo.ml` | `github.com_jeong-sik_masc-mcp` | `lib/foo.ml` |
| `~/me/workspace/yousleepwhen/masc-mcp/lib/foo.ml` | `github.com_jeong-sik_masc-mcp` | `lib/foo.ml` |
| `lib/foo.ml` | `github.com_jeong-sik_masc-mcp` | `lib/foo.ml` (그대로) |
| `/tmp/scratch.ml` | (resolve 실패) | `None` → `_orphan/` (절대경로 그대로 기록) |

repo-relative 강제는 sandbox 와 working tree 의 같은 파일이 같은 `file_path` 로 저장됨을 보장한다. 이것이 두 clone 간 join 의 필수조건.

### 4.5 Reverse lookup 세 방향

`Repo_store` 에 신규 함수:

```ocaml
(* lib/repo_manager/repo_store.mli *)
val find_canonical_url_by_path_prefix
  :  base_path:string
  -> string
  -> (string * string) option
(** [find_canonical_url_by_path_prefix ~base_path abs_path]
    → 가장 긴 prefix 가 일치하는 repo entry 의 (canonical_url, rel_path).
    같은 path 가 두 repo entry 의 prefix 면 더 긴 local_path 가 이김.
    매치 없으면 [None]. *)

val find_canonical_url_by_repo_id
  :  base_path:string
  -> string
  -> string option
(** repositories.toml 에서 repo_id 의 url 필드 → canonical_url. *)
```

세 가지 진입점:

1. **Keeper write (sandbox)**: keeper meta 가 `repos[]` 를 가지고 있으면 거기서 lookup. 없으면 `find_canonical_url_by_path_prefix` fallback.
2. **HTTP read (repo_id 쿼리)**: `find_canonical_url_by_repo_id`. 실패 시 `_orphan` 응답 아니라 빈 결과 (`[]`).
3. **HTTP read (직접 URL 쿼리)**: 신규 `?canonical_url=...` 쿼리 파라미터. repo_id 와 동등 우선순위, 둘 다 있으면 url 이 이김.

### 4.6 `excluded_dirs` 보완

`lib/server/server_routes_http_routes_workspace.ml:160` 의 `excluded_dirs` 에 `.masc-ide` 추가. 현재 `?repo_id=masc` 호출 응답에 `.masc-ide` 가 노출되는 leak.

## 5. Migration

### Phase 0 — RFC body merge (본 PR)

본 spec 머지. 코드 변경 0.

### Phase 1 — write-side plumbing (PR 1)

- `Ide_paths.canonical_url_of_remote` 구현 + 단위 테스트.
- `Repo_store.find_canonical_url_by_*` 두 함수 추가.
- `Ide_annotations.create` / `Ide_region_tracker.append_region` 시그니처에 `canonical_url:string option` 추가.
- 모든 caller (`server_ide_http.ml`, `keeper_exec_fs.ml`, `keeper_exec_ide.ml`) 업데이트.
- 기존 store path (`<base>/.masc-ide/{annotations,regions}.jsonl`) 는 *읽기 전용* 으로 유지. 새 record 는 `by-url/<slug>/` 또는 `_orphan/` 으로만.

Acceptance:
- sandbox keeper edit → `by-url/<slug>/regions.jsonl` 에 record 출현. `file_path` 가 repo-relative.
- working tree user 가 IDE 로 같은 파일 보면 같은 record 가 보임.
- `Repo_store` 등록 안 된 path 의 write → `_orphan/` 에 떨어지고 counter +1.

### Phase 2 — read-side multi-source (PR 2)

- `Ide_annotations.list` 가 `<canonical_url>` 인자를 받아 `by-url/<slug>/` + 기존 평면 파일 양쪽을 읽어 merge.
- HTTP route 에 `?canonical_url=` 받기.
- 평면 파일의 record 는 ad-hoc 으로 `_orphan` 으로 취급 (canonical_url 없음).

### Phase 3 — flat-file purge (PR 3, optional)

- 평면 `<base>/.masc-ide/{annotations,regions}.jsonl` 의 모든 record 를 reverse lookup 으로 분류 시도 → `by-url/<slug>/` 또는 `_orphan/` 으로 이동.
- 평면 파일 삭제.
- counter 로 분류 결과 보고.

Phase 3 는 lazy 가능. 평면 파일이 비어있거나 사용자가 동의하면 즉시.

### 유령 데이터

`<base-path>/.masc-ide/2026-05/{16,17}.jsonl` 는 본 RFC 작성 직전 사용자 동의로 삭제됨. Phase 1 acceptance test 에서 동일 포맷의 잔재가 다시 생기는지 검사 (`find <base>/.masc-ide -name '*-*.jsonl' | wc -l == 0`).

## 6. Test plan

### 6.1 canonical_url_of_remote 단위 테스트

```
test/test_ide_paths.ml
  - canonical_url_of_remote
    - https URL 정규화
    - https URL .git suffix
    - SSH (git@host:path) 정규화
    - SSH URL (ssh://) 정규화
    - 대소문자
    - 비정상 입력 (None 반환):
      - 빈 문자열
      - 호스트만 (`https://github.com`)
      - 허용되지 않는 문자 (`https://github.com/foo bar/baz`)
      - path traversal (`https://github.com/../etc/passwd`)
```

### 6.2 reverse lookup 통합 테스트

```
test/test_repo_store_reverse_lookup.ml
  - 두 repo entry: masc (local_path /a/repos/masc), oas (/a/repos/oas)
    - /a/repos/masc/lib/foo.ml → (canonical_url_masc, lib/foo.ml)
    - /a/repos/oas/lib/foo.ml  → (canonical_url_oas, lib/foo.ml)
    - /a/other/path → None
  - Nested local_path (longest-match wins):
    - /a/repos/masc-mcp/sub-repo/ 가 별 entry 면 sub-repo 우선
```

### 6.3 sandbox/working-tree join 통합 테스트

```
test/test_ide_canonical_url_join.ml
  - sandbox path 로 write → by-url/<slug>/regions.jsonl 에 lib/foo.ml record
  - working-tree path 로 list (같은 canonical_url) → 위 record 보임
  - canonical_url 일치 안 하는 working tree 로 list → 빈 결과
```

### 6.4 회귀 — silent loss 0

`_orphan` 으로 떨어진 record 가 있을 때 counter `ide_orphan_writes_total` 가 증가했는지 단위 테스트. Phase 1 acceptance: production sandbox 에서 한 turn 돌리고 `_orphan/` 이 비어있어야 함.

## 7. Open questions

1. **`.masc-ide` 위치 — server base anchored 유지 vs. user-home XDG-style**: 현재 안 = server base anchored. 두 서버 인스턴스가 같은 host 에서 돌면 store 가 분리됨. XDG-style 이면 통합. 사용자 의견 필요. (본 RFC default: server base anchored 유지.)

2. **유사 캐노니컬 URL의 prefix 충돌**: `github.com/foo/bar` 와 `github.com/foo/bar-mirror` 의 slug 는 `_` 로 구분되지만 `find_canonical_url_by_path_prefix` 가 path 기반이라 두 repo 가 nested 면 longest-match 만으로 충분한지 검토 필요.

3. **`_orphan` 의 lifecycle**: 무기한 누적 vs. 90일 rotation. 본 RFC 는 default = 무기한. Rotation 은 별 RFC.

## 8. Risk

- Phase 1 plumbing 이 `Ide_annotations.create` 시그니처를 변경 → 모든 caller 업데이트 필요. 누락 시 빌드 실패라 silent loss 위험은 없음.
- `find_canonical_url_by_path_prefix` 가 `Repo_store.list_all` 을 매 write 호출. write rate 가 높으면 캐시 필요 (현재 keeper write 는 turn 당 수 회 수준이라 우선 비캐시).
- Migration Phase 2/3 미수행 상태에서 평면 파일과 `by-url/` 가 공존 → list query 가 양쪽 읽음. 이중 record 위험은 동일 source 가 한 곳에만 쓰므로 없음.

## 9. References

- RFC-0078 — RFC number reservation ledger (본 RFC 번호 할당 근거).
- RFC-0084 — Keeper tool dispatch unification. §1.7 scattered hardcoded default cleanup 의 후속으로 본 RFC 가 *내부 partitioning* 까지 확장.
- RFC-0035 — Cognitive IDE master plan (broader IDE strategy).
- RFC-0036 — Multi-keeper docker orchestration (sandbox path 형태의 출처).
- `lib/ide/ide_paths.ml`, `lib/ide/ide_annotations.ml`, `lib/ide/ide_region_tracker.ml`, `lib/ide/ide_meta_sync.ml`.
- `lib/server/server_ide_http.ml`, `lib/server/server_routes_http_routes_workspace.ml`.
- `lib/keeper/keeper_exec_fs.ml:230` (write entry point), `lib/keeper/keeper_alerting_path.ml:69` (현재 base 해결).
- `lib/repo_manager/repo_store.ml` — repository.toml 모델.

## 10. Implementation summary (2026-05-18)

본 spec 머지 (#16014) 후 11 PR 로 분할 구현. 각 PR 은 single-purpose 원칙 적용.

| PR | 번호 | 역할 | 상태 |
|----|------|------|------|
| 1a + 1b | [#16028](https://github.com/jeong-sik/masc-mcp/pull/16028) | `canonical_url_of_remote`, `Repo_store.find_repo_by_path_prefix`, `Ide_paths.partition` 타입, `?partition` 옵셔널 인자 plumbing | **MERGED** |
| 1c | [#16036](https://github.com/jeong-sik/masc-mcp/pull/16036) | keeper write + HTTP read cut-over to `By_url`, `_orphan` bucket + `masc_ide_orphan_writes_total` counter | Open |
| 1d | [#16040](https://github.com/jeong-sik/masc-mcp/pull/16040) | `excluded_dirs` 에 `.masc-ide` 추가 (file-tree leak fix) | Open |
| 1e | [#16044](https://github.com/jeong-sik/masc-mcp/pull/16044) | `Ide_meta_sync` 호출 사이트 제거 + `ingest_tool_call` 의 content fallback (double-write 해소) | Open |
| 1f | [#16055](https://github.com/jeong-sik/masc-mcp/pull/16055) | `Ide_meta_sync` 모듈 자체 삭제 (caller 0 후 dead-code purge) | Open |
| 2 | [#16049](https://github.com/jeong-sik/masc-mcp/pull/16049) | `?merge_legacy:bool` read-side merge — Legacy + By_url + structural dedup. UUID 충돌 버그도 함께 fix | Open |
| 3 | [#16053](https://github.com/jeong-sik/masc-mcp/pull/16053) | `Ide_migration.migrate_flat_to_partitioned` — idempotent + dry_run + delete_legacy_after | Open |
| 4 | [#16058](https://github.com/jeong-sik/masc-mcp/pull/16058) | `masc-ide-migrate` CLI — operator-facing | Open |
| 6 | [#16061](https://github.com/jeong-sik/masc-mcp/pull/16061) | sandbox playground path → repo_id lookup (`Playground_paths.parse_playground_repo_path` + `find_url_by_id`) — §4.5 두 번째 chain | Open |
| 8 | [#16062](https://github.com/jeong-sik/masc-mcp/pull/16062) | HTTP IDE routes 가 partition base 를 server `base_path` 로 통일 (workspace tree 가 아닌) | Open |
| 9 | [#16063](https://github.com/jeong-sik/masc-mcp/pull/16063) | `docs/IDE-STORE-MIGRATION-RUNBOOK.md` operator-facing runbook | Open |

### Critical merge atomicity

PR-1c + **PR-6** + **PR-8** 셋이 *같은 sweep 에서* 머지돼야 사용자 환경에서 keeper write/read 가 join. 각각 단독은 silent failure:

| 단독 머지 | 결과 |
|----------|------|
| PR-1c 만 | sandbox writes → `_orphan` (PR-6 의 두 번째 chain 부재). HTTP read base ≠ keeper write base (PR-8 의 base 통일 부재) |
| PR-1c + PR-6 | write base ≠ read base 여전. HTTP read 0 건 |
| PR-1c + PR-8 | sandbox writes → `_orphan` 여전 |
| **PR-1c + PR-6 + PR-8** | write/read 일치 ✓ |

### §4/§5 invariant 입증 단위 테스트 (총합 65+ cases)

- `test_ide_paths` 18 cases (canonical URL 정규화 + join invariant)
- `test_repo_store` reverse_lookup 6 cases (path_prefix sibling-safe + url-by-id)
- `test_ide_annotations` 17 cases (partition routing + dedup + UUID + read-merge)
- `test_ide_canonical_url_join` 5 cases (sandbox/working-tree 같은 slug join, sandbox playground path resolution, docker playground path)
- `test_ide_migration` 5 cases (Phase 3 idempotency + dry_run + delete)
- `test_workspace_tree_exclusions` 2 cases (.masc-ide leak guard)

### Operator runbook

상세 진단/migration 절차는 [`docs/IDE-STORE-MIGRATION-RUNBOOK.md`](../IDE-STORE-MIGRATION-RUNBOOK.md) 참조 (PR-9 가 추가).

### Recommended merge sequence

PR sweep 결정 시 다음 순서 권장. 각 그룹 안의 PR 들은 서로 독립이라 임의 순서 가능.

**Phase A — Critical atomic group** (셋 같이, 사용자 환경에서 keeper write/read join 의 필수조건):

- [ ] #16036 PR-1c — write/read cut-over framework
- [ ] #16061 PR-6 — sandbox playground path lookup (§4.5 두 번째 chain)
- [ ] #16062 PR-8 — HTTP partition base 통일 (server base_path)

**Phase B — Phase 1 polish** (독립, Phase A 후 또는 병행):

- [ ] #16044 PR-1e — single-write 보강 (Ide_meta_sync 호출 제거)
- [ ] #16055 PR-1f — Ide_meta_sync 모듈 dead-code purge (PR-1e 후)
- [ ] #16040 PR-1d — `excluded_dirs` 에 `.masc-ide` 추가 (Phase A 와 무관)

**Phase C — Phase 2 read merge** (Phase A 의 By_url cut-over 후 가치 발휘):

- [ ] #16049 PR-2 — `?merge_legacy:bool` + structural dedup + UUID fix

**Phase D — Phase 3 migration tooling** (Phase A + C 후):

- [ ] #16053 PR-3 — `Ide_migration.migrate_flat_to_partitioned` 라이브러리
- [ ] #16058 PR-4 — `masc-ide-migrate` CLI

**Phase E — Documentation 동기화** (어디서나 가능):

- [ ] #16060 PR-5 — RFC status Draft → Active + index row + implementation_prs
- [ ] #16063 PR-9 — `docs/IDE-STORE-MIGRATION-RUNBOOK.md`

**최소 가치 머지 set**: Phase A 만으로도 사용자 환경의 즉시 unblock 달성 (working tree IDE 가 keeper 활동 표시).

### Implementation → Implemented status 조건

Phase 3 migration 의 운영 적용 + `?merge_legacy` flag 제거가 끝나면 RFC status 를 `Implemented` 로 갱신. 본 cycle (2026-05-18) 까지의 status 는 `Active`.
