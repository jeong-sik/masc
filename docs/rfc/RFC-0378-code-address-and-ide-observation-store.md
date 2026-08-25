---
rfc: "0378"
title: "Code fact 는 태어날 때 주소를 받는다 — typed address, code-fact 전용 store, anchor 계약 통일"
status: Implemented
created: 2026-08-14
updated: 2026-08-17
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0343", "keeper-workspace-root-only", "0233"]
---

# RFC-0378: Code fact 는 태어날 때 주소를 받는다

## 0. Summary

Keeper 의 코드 작업이 IDE 에 보이려면 쓰기와 읽기가 같은 주소로 만나야 한다. 지금은 `file_path : string` 하나가 4개 어휘(repo-relative / `repos/<id>/` 접두 / `.worktrees/` 접두 / 절대경로)를 실어 나르고, 읽기는 그중 1개만 묻는다. 이 RFC 는 주소를 **발행 시점에 한 번 파싱된 타입**으로 확정하고, IDE store 를 addressed code fact 전용으로 좁혀 `_orphan` 을 없애고 (keeper fact 는 기존 SSOT 인 turn-records/tool_calls 가 소유 — §5.2), annotate 의 anchor 계약을 IDE co-view 계약과 동일하게 만든다. 귀속 *메커니즘*(경로→저장소 정체)은 RFC-keeper-workspace-root-only 소관이고, 이 RFC 는 **그 결과값의 타입·수명·저장·소비**를 소관한다.

## 1. 원칙 → 설계 강제

프로젝트 원칙(2026-08-14, 24항) 중 이 설계를 실제로 강제한 항목과, 그로 인해 **이전 제안에서 뒤집힌 것**:

| 원칙 | 이 RFC 에서의 강제 |
|---|---|
| 10. String 비교 | 결함의 본체가 stringly-typed 주소다. 주소는 abstract 타입 + smart constructor 로만 생성 — raw string 으로 code fact 를 만들 수 없게 한다 (Parse, don't validate) |
| 8. 레거시 | `_orphan`·실패 partition 변형·구 store 데이터는 hard cut. 호환 reader·converter·"deprecated" 흔적 일절 없음 |
| 7. 게이트 | 신규 게이트 0. scope 명시 선택은 게이트가 아니라 추측 제거. 귀속 실패를 막는 장치를 만들지 않고, 실패를 **타입이 있는 keeper fact** 로 흘린다 |
| 11. 관측성/카운터 | `IdeOrphanWrites` 카운터는 telemetry-as-fix — 삭제. 귀속 실패 사유는 카운터가 아니라 fact 의 typed 필드로 남아 질의 가능하다 |
| 9. 매직 넘버 | 신규 임계값 0. 판정 조건(§6.2)도 수치 없이 존재 기준으로만 서술 |
| 20. 테스트 | acceptance 는 feature 왕복(마커 표시, anchor 왕복)이며 경로 헬퍼 단위 테스트가 아니다. 죽는 표면의 회귀 테스트는 함께 삭제 |
| 24. 환경변수 | 신규 env var 0, 신규 TOML 키 0. scope 는 서버 설정이 아니라 viewer 상태이므로 클라이언트에 지속 |
| 16. CI/분할 | 구현은 stacked PR 사다리(각 ≤20k output tokens), 인접 단계 사이 적대적 리뷰 병렬 |
| 13. 제3의 길 | annotate 의 트리거는 결정론 장치를 만들지 않는다 — co-view 컨텍스트를 프롬프트로 주고(원칙 22) 판단은 keeper LLM 몫 |

이전 분석(2026-08-14 세션)에서 **철회되는 제안 2건**: (1) turn_events 에 partition 부여 — 턴은 여러 저장소를 만질 수 있어 단일 partition 은 거짓이다. 저장소 타임라인은 `code fact(address, turn_id) → turn` 조인으로 파생한다. (2) orphan 을 "알람으로 승격" — 카운터 보강이 아니라 개념 자체를 삭제한다.

## 2. 문제 — 실측

라이브 store `<basepath 형제>/.masc-ide/` (2026-08-14 측정):

| 항목 | 값 |
|---|---|
| store 전체 | 389 MiB |
| 그중 `_orphan/` | 380 MiB (**97.6%**) |
| `by-url/` 파티션 15개 중 내용 있는 것 | 3개 (masc, agent_core, masc 8.5M 가 사실상 전부) |
| `by-url/wkbl·kirin·grpc-direct` | 0행 (라이브 API 확인) |
| turn_events 가 by-url 에 존재 | **0건** — 146 MiB 전량 `_orphan` |
| annotations 평생 총량 | **4행**, 전부 `_orphan` |

같은 masc 파티션 안의 경로 어휘 분열:

| | join 가능 (repo-relative) | `repos/<id>/` 접두 | `.worktrees/` 접두 | 절대경로 |
|---|---|---|---|---|
| tool_events 19,291행 | **13.0%** | 80.3% | 0 | 6.7% |
| regions 1,621행 | **64.1%** | 1.0% | 34.9% | 0 |

읽기(`/api/v1/ide/regions?canonical_url=…&file_path=<repo-relative>`)는 repo-relative 만 묻는다. 즉 scope 를 맞게 잡아도 tool 마커의 87%, region 마커의 36%는 원리상 안 보인다.

### 2.1 압축 표본 — owner probe (2026-08-11)

`.masc/tool_calls/2026-08/12.jsonl` 의 `keeper_surface_read` 출력에 왕복 전체가 남아 있다:

1. Operator 가 IDE co-view 로 `(repo: masc, lib/ide/ide_annotations.ml, L39)` 를 keeper analyst 에게 전달, annotate 지시.
2. analyst 는 받은 그대로 `lib/ide/ide_annotations.ml` 를 넘김.
3. `keeper_ide_annotate` 는 bare relative 를 **sandbox root 에 앵커** (`repos/masc/` 세그먼트 부재) → `Base_unresolved` → `_orphan` 매장 (id `528e6fd6-…`, `161648b0-…` 2건).
4. analyst 스스로 보고: *"도구가 반환한 file_path 는 … 제 샌드박스 루트 기준으로 해석되었습니다."*

**IDE 가 주는 어휘와 도구가 받는 어휘가 다르다.** 왕복의 두 절반이 서로 다른 언어를 쓴다. 이 한 건이 이 평면의 전체 병리다.

### 2.2 투자 대비

비테스트 약 24.4k LoC (lib/ide 2,487 + agent_observation 604 + server ide/lsp 3,585 + dashboard ide 17,727) 가 이 평면에 있다. LSP overlay 13개 진입점 중 8개(definition/references/symbols/highlights 계열)는 **평생 4행뿐인 annotations** 를 읽는다. 죽은 store 를 읽는 완성된 표면이다.

## 3. Needs — 실사용에서 역산

지어낸 요구가 아니라 operator 가 실제로 한 행동 3건에서 역산했다:

| # | Need | 증거 | git/GitHub 이 못 주는 이유 |
|---|---|---|---|
| N1 | 저장소를 열면 keeper 가 어디를 만졌는지 보인다 | "어떤 저장소를 열어봐도 표식이 없다" (operator 직접 보고) | PR 이전 in-flight 작업·실패한 시도는 git 에 없음 |
| N2 | file:line 을 가리켜 keeper 와 말하고, 답이 그 지점에 돌아온다 | §2.1 owner probe — operator 가 직접 시도 | GitHub 리뷰 코멘트는 PR 이후에만 존재 |
| N3 | 마커에서 turn/task 로 점프 | task-320 (약함, N1 hover 로 흡수 가능) | turn/task 는 masc 고유 개념 |

**Need 가 아닌 것** (사용 증거 0): annotation 기반 코드 *탐색* (definition/references/symbols/highlights), cursor_events (store 마지막 기록 07-04), pr_events (06-12).

## 4. 경계 — RFC-keeper-workspace-root-only 와의 분업

| 질문 | 소유자 |
|---|---|
| 이 경로는 어느 저장소인가 (git 실측, bounded, cache, local-path fallback) | workspace-root-only §3.2, §5 (2a/2b) |
| typed `Unattributed` (귀속 실패의 타입) | workspace-root-only 2a 가 도입, **이 RFC 가 소비** |
| 귀속 결과의 타입·발행 시점·저장 배치·읽기 어휘·anchor 계약 | **이 RFC** |
| 동일 origin N-clone 의 checkout 판별자를 record 에 넣는가 (그쪽 §5.2 미결) | **이 RFC 가 답한다**: 넣되 key 가 아니라 projection 메타데이터 (§5.1). 원 질문은 region 레코드 한정이었으나 답은 Code fact 전체로 일반화한다 — 세 파일이 같은 key 로 조인되는 것이 이 RFC 의 요지이므로 판별자도 세 파일 같은 자리(비-key)에 있어야 한다 |

agent_observation.mli 가 인용하는 "IDE Observation Plane v2 §7" 문서는 repo 에 존재하지 않는다. 이 RFC 구현에서 해당 포인터를 함께 제거한다 (원칙 8).

## 5. 설계

### 5.1 Typed address — 발행 시 1회 파싱

```ocaml
(* lib/agent_observation — 스케치. 정확 시그니처는 PR-A 에서. *)
module Code_address : sig
  type t  (* abstract: raw string 으로 생성 불가 *)
  val codebase : t -> string   (* canonical-url slug *)
  val path : t -> string       (* repo-root 상대, 정규화 완료 *)
  (* 유일한 생성자는 resolver 출력만 받는다 *)
end

type fact =
  | Code of
      { address : Code_address.t
      ; checkout : string option
        (* projection 메타데이터: 어느 체크아웃(worktree/clone)에서 관측됐나.
           key 비참여 — 같은 파일의 worktree 편집과 본 트리 편집은 같은 주소로 접힌다 *)
      ; body : body
      }
  | Keeper of
      { keeper_id : string
      ; unaddressed : unaddressed option
        (* None = 애초에 파일이 없는 호출 (board/memory 등 순수 keeper-timeline fact).
           Some = 파일은 있었으나 귀속 실패. 현행 orphan 레코드가 보존하던
           포렌식 정보(시도한 경로)를 잃지 않는다. 관측성은 여기서:
           카운터가 아니라 질의 가능한 필드 *)
      ; body : body
      }

and unaddressed =
  { reason : Unattributed.reason  (* workspace-root-only 2a 의 타입 *)
  ; attempted_path : string       (* resolver 가 본 원경로 그대로 *)
  }
```

- 소비자는 주소를 **재유도할 수 없다** — 타입이 원천 봉쇄한다 (#28582/#28595 독트린의 타입화).
- `codebase_partition` 의 실패 4변형(`No_canonical_url`/`Unmatched`/`Base_unresolved`/`Legacy_default`)은 **삭제**. 실패는 store 의 파티션이 아니라 fact 의 종류다.
- turn event 는 정의상 `Keeper` fact. 저장소 타임라인은 `Code(address, turn_id)` 조인으로 파생 — 스키마 추가 없음.
- 효과 분리(원칙 4/17): 주소 발행은 순수, append 는 가장자리.
- 경로 containment 는 resolver 의 lexical segment stack 으로 판정한다. `.` 은 버리고,
  `..` 은 stack 이 비어 있으면 root escape 로 reject, 아니면 한 segment 를 pop 한다.
  `Fpath.normalize` 는 선행 `..` 을 보존하므로 "정규화된 문자열"은 만들 수 있어도
  repo root 안이라는 증명은 만들지 못한다. 따라서 A2 의 stack 은 편의용 path helper 가
  아니라 containment reject 를 수행하는 `Code_address.v` 앞단의 보안 경계다.

### 5.2 Store 는 code fact 전용 — `_orphan` 소멸, keeper store 신설 없음

**측정이 설계를 바꿨다 (2026-08-14, Open Q 였던 항목).** keeper fact 의 durable SSOT 는 이미 둘 다 존재한다:

| keeper fact | 기존 SSOT | ide store 의 사본 |
|---|---|---|
| 턴 | `keepers/<k>/turn-records/` — 24필드 (absolute_turn·generation·trace_id·토큰·runtime_profile…) | turn_events 8필드, **더 약한 key**(`turn-<name>`) |
| tool 호출 | `tool_calls/YYYY-MM/` — input/output/runtime_contract/action_radius 전부 | tool_events 의 Pathless/Unaddressed 행 |

ide store 의 keeper-fact 절반은 **더 약한 스키마의 중복 투영**이었고, `_orphan` 380 MiB (97.6%) 는 그 중복의 누적이다. 따라서 `keeper/<keeper_id>/` 를 신설하지 않는다:

```
<store-root>/
  by-url/<slug>/{tool_events,regions,annotations}.jsonl   ← Addressed code fact 만
```

- **IDE sink 는 Addressed fact 만 영속한다.** Unaddressed/Pathless fact 는 bus 에는 흐르되(typed reason 포함 — 다른 소비자·스냅샷·메트릭 표면에서 질의 가능) ide store 에 쓰지 않는다. durable 증거는 tool_calls/turn-records 가 이미 소유한다 — 같은 사실을 더 약한 스키마로 두 번 쓰는 것이 지금까지의 결함이었다.
- turn_events 의 방출→sink 사슬은 통째로 죽는다 (emit_turn_event 포함). keeper 타임라인 표면은 turn-records 를 읽는 read path 로 간다.
- `_orphan/`·`orphan_path`·`partition_is_orphan` 은 신규 쓰기 0 이 된 뒤 E 에서 데이터와 함께 삭제.
- 회전(rotation) 메커니즘은 by-url 스토어에 유지 (storage 역학이지 keeper 흐름 제어가 아님 — 원칙 9 비저촉).
- `Scope_keeper_lane` 은 **E 에서 데이터와 함께 소멸한다** (구현이 정정한 결정 — D 의 "keeper SSOT 기반 read path 이행" 은 신규 read 표면 신설이라 §5.2 의 중복-투영 금지와 충돌한다). 그 scope 의 존재 이유는 orphan 데이터 접근(2026-07-07 감사)이었고, B 가 신규 쓰기를 끊고 cut 이 데이터를 지우면 대상이 없다. keeper 타임라인 표면은 기존 keeper 대시보드가 담당한다. **scope·구 partition 타입 삭제와 데이터 cut 은 한 단계로 묶는다 — 근거는 위생이다**: scope 를 먼저 지우면 잔존 orphan row 가 읽기 불가능한 바이트로 남는데 (keeper fact 의 SSOT 는 turn-records/tool_calls 이므로 데이터 손실은 아니고, cut 을 마저 돌리면 사라지는 deferred cleanup 이다), 같은 스텝이 그 잔존물을 애초에 만들지 않는 가장 싼 방법이다. 순서-critical 한 실위험은 머지 순서가 아니라 라이브 서버 앞의 디렉터리 스왑이며 (§5.6 메모리 epoch), cut 스크립트가 store 파일 홀더를 감지해 거부한다 (적대 리뷰 P1-2/P2-4 정정). 현행은 전 keeper 의 `_orphan` 혼합을 읽고 keeper_id 로 필터링하는 구조 (`server_ide_scope.ml` 의 Legacy_default 매핑 — 2026-07-07 감사가 "턴은 repo fact 가 아니다"를 인지하고 만든 우회로였고, 이 정리가 그 인지의 정식화다).

### 5.3 Anchor 계약 = co-view 계약

`keeper_ide_annotate`(및 향후 anchored reply)의 입력은 **IDE 가 keeper 에게 준 바로 그 어휘**다: `(canonical slug, repo-root 상대 경로, line range)`.

- **repo *이름*이 아니라 slug 다.** 현행 co-view 는 `repo: masc` 처럼 이름을 보내는데, 이름은 slug 와 별개인 또 하나의 문자열 별칭이라 계약 안에 어휘 분열을 재생산한다 (원칙 10). §5.3b 의 단일 wire key 아래에서 co-view 도 slug 를 싣고, annotate 의 서버 측 카탈로그 홉(이름→url→slug)은 통째로 사라진다 — 왕복의 두 절반과 read path 가 문자 그대로 같은 key 를 쓴다.
- keeper 가 자기 마운트 레이아웃(`repos/<id>/…`)을 알아야 앵커를 되돌려줄 수 있는 현행 계약(#23469 의 sandbox-root 앵커링)은 삭제한다. keeper 는 받은 것을 그대로 돌려주면 된다.
- **실패는 typed reject 다.** 입력이 (slug, repo-relative, lines) 이므로 annotate 에는 "귀속 실패인데 성공을 반환하는" 경로가 없어진다 — slug 는 어떤 값이든 정당한 파티션이고(모집합은 store 실측, §5.4), path 가 파싱 불가면 도구가 명시적으로 reject 한다. 현행 구현은 `Base_unresolved` 매장에도 `ok:true` 를 돌려준다 (`keeper_tool_ide_runtime.ml` — silent failure 의 재생산) — 이것이 계약 수준에서 불가능해진다.
- **사람 쪽 절반도 같은 생성자를 지난다.** 대시보드의 REST annotation POST 는 현재 **세 번째 귀속 경로**를 갖는다: `server_ide_http.ml` 이 카탈로그 local_path 접두 매칭으로 raw file_path 에서 파티션을 재유도하고, 자체 실패 taxonomy 3종(`File_path_repo_id_mismatch` 등, :113-126)을 따로 둔다 — `codebase_partition` 4변형과도 workspace-root-only 의 `Unattributed` 와도 별개인 세 번째 어휘다. 이 경로와 taxonomy 는 죽고, REST 도 (slug, repo-relative) 를 받아 같은 smart constructor 로 `Code_address` 를 발행한다. keeper 절반·사람 절반·read path 가 한 생성자를 공유한다.
- 도구 스키마와 keeper 프롬프트가 이 계약을 서술한다 (프롬프트 변경은 원칙 22 로 허용).
- acceptance: §2.1 owner probe 의 **정확한 재실행**이 green — 같은 (repo, path, line) 에 마커가 뜬다.

### 5.3b 하나의 wire key — slug

경로 어휘만 4종이 아니다. **codebase 를 지칭하는 철자도 wire 에 4종** 있다: REST scope 는 `canonical_url=<full URL>` 또는 `repo_id`, store 디렉터리는 slug, co-view 는 repo *이름*, dashboard 선택 상태는 repository id. 주소의 한 축(경로)을 통일하면서 다른 축(codebase key)의 분열을 방치하면 같은 병이 재발한다.

계약: **파싱 이후의 codebase key 는 slug 하나다.**

- full URL 은 귀속 시점(git remote → `canonical_url_of_remote`)에만 존재하는 raw 입력.
- repo 표시 이름·카탈로그 repo_id 는 projection 라벨 — wire key 로 쓰지 않는다.
- REST 질의는 `codebase=<slug>`, co-view 는 slug, annotate 는 slug, viewer 지속 상태도 slug. 전부 문자 그대로 store 디렉터리 이름과 같은 값.
- scope 는 `codebase=<slug>` 단일 variant 다. keeper-lane scope 는 §5.2 정정대로 E 에서 orphan 데이터와 함께 소멸했고 (그 scope 가 읽을 store 가 없다), 그와 함께 scope 상호배타 검사(`conflicting_ide_scope`)도 대상이 사라져 죽었다 — 파라미터가 하나뿐인 resolver 에 배타 계약은 공집합 위 명제다. keeper 타임라인은 turn-records/tool_calls 위 기존 keeper 대시보드가 담당한다.
- 알려진 한계: `canonical_url_of_remote` 는 입력 전체를 소문자화하므로, 대소문자를 구분하는 self-hosted 호스트에서 실제로 다른 두 저장소가 같은 slug 로 충돌할 수 있다. GitHub 중심 카탈로그인 현재는 저위험 — 충돌이 실측되면 slug drift(§9 Q5)와 같은 축에서 다룬다.

### 5.4 Scope — 추측하지 않는다

- `selectPreferredIdeRepositoryId` 의 경로 모양 휴리스틱(절대경로·`/.masc/` 포함 여부로 "사람의 repo" 추측)은 삭제. 현재 이 추측의 답(wkbl)은 code fact 0행 파티션이다.
- 첫 진입은 명시 선택, 선택은 viewer 클라이언트에 지속 (localStorage — 서버 설정이 아니므로 TOML/env 비대상, 원칙 24).
- 저장소 목록의 **모집합도 실측**이다: 선택지는 카탈로그(repositories.toml)가 아니라 `by-url/` 에 실존하는 파티션에서 온다. workspace-root-only 하에서 slug 는 git remote 실측으로 발행되므로 **카탈로그 미등록 repo 의 파티션도 정당하게 생긴다** — 카탈로그를 모집합으로 쓰면 그 작업은 기록되고도 선택 불가능해진다. 카탈로그는 등록 repo 의 표시 이름을 빌려주는 projection 으로만 참여한다.
- 목록의 **정렬**은 실측(파티션별 code fact 최근성)으로 — 그것도 projection 이라 허용.
- 빈 파티션은 정직한 empty state: "이 저장소에서 keeper 작업 기록 없음".

### 5.5 개념 축소 — kill list

| 대상 | 증거 | 처분 |
|---|---|---|
| partition 실패 4변형 + orphan 경로/판별 함수 | §5.1 — 실패는 fact 종류 | **E 에서** 삭제 — read path 가 D 까지 이 타입으로 조회 (§7 머지 지점) |
| `_orphan/` 데이터 380 MiB | store 의 97.6%, code fact 아님 | hard cut (§5.6) |
| `IdeOrphanWrites` 카운터 | telemetry-as-fix, 소비자 0 | 삭제 |
| LSP definition/references/documentSymbol/highlights/related-locations | 읽는 store 가 평생 4행 | 삭제 + 해당 테스트 동반 삭제 (원칙 20) |
| LSP InlayHint (route-context) | 사용 증거 0 + overlay 병합이 순수 additive 라 하부 LSP 네이티브 inlayHint 무손상 (적대 리뷰 확인) | 삭제 |
| pr_events store 잔재 | 코드 소비자 **0 파일** (lib+dashboard 비테스트 전수) — 이미 코드 레벨 사망 | 삭제 |
| cursor_events (store + `list_cursors` + overlay) | UI 는 wired(`keeper-cursor-overlay` → `fetchIdeCursors`)인데 producer 가 07-04 이후 침묵 — "안 쓰는 기능"이 아니라 "조용히 고장난 기능" | Open Q1: producer 수선 vs 동반 삭제 |
| REST annotation POST 의 경로 재유도 + 실패 taxonomy 3종 | 세 번째 귀속 어휘 (§5.3) | C 에서 smart constructor 로 교체 |
| `selectPreferredIdeRepositoryId` 휴리스틱 | 추측의 답이 빈 파티션 | 삭제 → §5.4 |
| wire 의 codebase 철자 혼용 (`canonical_url=<full URL>`·`repo_id` scope param, co-view repo 이름) | codebase key 4종 분열 (§5.3b) | 단일 `codebase=<slug>` 로 — C(co-view)·D(REST) 에서 교체 |
| `?(partition = Legacy_default)` optional 인자 기본값 11사이트 (ide_annotations 6 · ide_region_tracker 4 · ide_bridge 1) | 인자 누락이 조용히 orphan 착지 — #28581 결함이 정확히 이 모양이었음 | write 측은 A, read 측은 D 에서 required 로 |
| annotate sandbox-root 앵커링 | owner probe 2건 매장 | 계약 교체로 소멸 (§5.3) |
| "IDE Observation Plane v2" 죽은 포인터 | repo 에 문서 부재 | 주석에서 제거 |

**살아남는 것**: regions gutter 마커, addressed tool 타임라인, 기존 keeper 대시보드의 turn 타임라인, CodeLens + hover, annotation rail, anchored interject, REST annotations CRUD (사람 쪽 절반 — 단 귀속은 §5.3 의 공유 생성자로), `canonical_url_of_remote`, 그리고 `ide_annotation_types.ml` 의 on-disk JSON 코덱. 코덱의 경계: `Code_address` 는 in-process 증명 타입이고 디스크 표현은 지금처럼 slug=디렉터리·path=문자열 필드다 — 코덱은 그 문자열을 주소로 재승격하지 않고 read path 의 질의 키로만 쓴다.

annotation 의 존재 이유는 축소 재정의된다: **(a)** anchored interject 에 대한 keeper 의 anchored reply, **(b)** 기존 decision/task record 의 code-anchored projection. "keeper 가 아무 때나 남기는 노트"는 평생 4행으로 반증됐다.

### 5.6 데이터 hard cut

- `<store-root>` 전체를 아카이브 후 삭제, fresh start (원칙 8/22). 마이그레이션·호환 reader 없음.
- masc 파티션의 유용분(8.5 MiB)은 keeper 상시 가동으로 수일 내 자연 재생성된다.
- 실행은 dry-run 근거 제시 후 별도 단계 (workspace-root-only 3b 와 같은 성격의 `rm -rf` 경로 분리 원칙).
- **cut 은 프로세스 메모리 무효화와 원자적이다.** LSP overlay 캐시는 파일 byte 길이를 리비전 토큰으로 쓰는데 그 전제는 append-only 다 — 디렉터리 교체는 전제를 깬다. old-epoch 캐시 엔트리와 재생성된 파일이 같은 크기에서 마주치면 **삭제된 pre-cut 데이터를 live 로 서빙**한다 (적대 리뷰 P0-2; 캐시는 무기한 Hashtbl, 무효화 훅은 didSave 뿐). cut 절차 = store 교체 + 서버 재시작(권장) 또는 overlay 캐시 전체 무효화 호출.

## 6. 검증

### 6.1 Browser 실측 acceptance (원칙 14/15/21 — 스크린샷 + store 행 대조 로그 필수)

| # | 시나리오 | green 조건 |
|---|---|---|
| V1 | IDE 진입 → 저장소 명시 선택 → keeper 쓰기 1회 후 해당 파일 열기 | gutter 마커 표시, store 의 해당 행과 주소 일치 |
| V2 | **owner probe 재실행**: co-view interject at file:line → keeper annotate | 같은 (repo, path, line) 에 마커 + rail 표시. `_orphan` 부재이므로 매장 불가 |
| V3 | scope 선택 → reload | 선택 유지, 재추측 없음 |
| V4 | cut 이후 store 전수 스캔 **+ LSP 응답 재확인** | IDE store 전수가 addressed code fact 이고 `_orphan`/`keeper` bucket 이 없음 (스크립트 출력 = 증거). keeper fact 의 durable 증거는 turn-records/tool_calls 에만 존재한다. 추가로 cut 직후 pre-cut 파일을 겨냥한 LSP 질의가 빈 결과 반환 — 디스크 스캔은 §5.6 의 메모리 epoch 혼입을 못 잡으므로 (버그가 서버 메모리에 있음) |

feature 왕복만 테스트한다 (원칙 20). 경로 헬퍼 단위 테스트는 만들지 않는다. 신규 테스트는 CI focused suite 에 배선한다 — masc CI 는 named suite 만 실행하므로 배선 없는 테스트는 컴파일만 된다.

### 6.2 이 설계가 틀렸다고 판정할 조건

- 주소를 타입으로 막았는데도 소비자가 주소를 재유도하는 새 사례가 컴파일을 통과하면 — 타입 설계 실패.
- V2 가 keeper 프롬프트 갱신 후에도 재현 실패하면 — 계약이 여전히 레이아웃 지식을 요구하는 것.
- keeper 가 실제 저장소 파일을 편집한 fact 가 `Keeper(unaddressed)` 로 떨어지는 재현 가능한 사례가 남으면 — 귀속(workspace-root-only 2b 폴백) 미성숙. 이 RFC 는 그 수선 없이 완료 선언 불가.

## 7. 구현 순서 — stacked PR 사다리 (원칙 16)

각 단계 ≤20k output tokens. 인접 단계 사이 적대적 리뷰 에이전트 병렬 → 리뷰 대응 에이전트 병렬.

| PR | 내용 | 성격 |
|---|---|---|
| A1 [#28649](https://github.com/jeong-sik/masc/pull/28649) | `Code_address` smart constructor + 수용/거부 테스트 (CI 배선) | 타입 신설, 행동 불변 |
| A2 [#28664](https://github.com/jeong-sik/masc/pull/28664) | `resolve_write_attribution` resolver + producer 이행 + sink 라우팅 | 최대 낙진, 행동 불변 |
| B [#28671](https://github.com/jeong-sik/masc/pull/28671) | sink 를 Addressed-only 영속으로 전환 + turn_events 방출 사슬 삭제 (§5.2) | 쓰기 전환 |
| C [#28676](https://github.com/jeong-sik/masc/pull/28676) | annotate/anchor 계약 + keeper 프롬프트 + owner-probe feature test + cursor REST POST 의 생성자 흡수 (§5.3) | N2 왕복 완성 |
| D [#28682](https://github.com/jeong-sik/masc/pull/28682) | read path 잔존분 + dashboard scope 명시화(선택 지속·휴리스틱 삭제) + empty state | N1 가시화 |
| E [#28684](https://github.com/jeong-sik/masc/pull/28684) | kill list 집행 (overlay 5표면 절제·타입/어휘 숙청·keeper-lane scope 와 dashboard `IdeScope` 미러 동반 소멸) + 구 테스트 삭제 + 데이터 cut (dry-run 선행) | 청소 |

### 7.1 As-built deviations

리뷰 snapshot 에서 구현하며 확인된 차이는 설계로 되돌려 기록한다:

- **A2 path containment** — 초안의 `fpath` 정규화 대신 lexical segment stack 을
  사용한다. 선행 `..` 을 보존하는 `Fpath.normalize` 로는 repo-root escape 를 reject 할
  수 없기 때문이다. 구현은 escape 를 수선하지 않고 거부한다 (§5.1).
- **B keeper fact 배치** — `keeper/<id>/` partition 을 만들거나 그쪽으로 옮기지 않았다.
  IDE `turn_events` 는 이미 존재하는 turn-records/tool_calls 보다 약한 중복 projection
  이므로 방출과 sink 를 삭제했다. IDE store 는 addressed code fact 만 소유한다 (§5.2).
- **E current-only cut** — 구 scope/type/data 와 Dashboard 의 mirror producer/reader 를
  같은 누적 diff 에서 제거한다. 호환 reader, fallback, dual-read 기간은 없다.

**착륙 계약 — 단계별 rollout 은 없다.** A~E 는 review 와 충돌 반경을 줄이기 위한
stacked branch 단위일 뿐, 어느 중간 rung 도 main 에 독립적으로 merge 하지 않는다.
최종 integration PR 하나가 A~E 누적 diff 를 current main 위에 materialize 하고,
producer/reader/writer/caller 및 구 partition 타입·호환 reader·fallback 을 같은 merge 에서
전부 제거한 current-only 상태로만 착륙한다. 따라서 아래의 "A 시점"·"D 시점"은
배포/운영 단계가 아니라 아직 merge 불가인 review snapshot 을 뜻한다. 데이터 cut 은 그
최종 binary 배포와 함께 수행하며 migration code 나 dual-read 기간을 두지 않는다.

순서 제약과 머지 지점 일관성:

- **A review snapshot** — 낙진 실측 두 겹 (2026-08-14, 독립 이중 측정): constructor 이름 grep 은 lib 13파일 · ~40사이트 · dashboard TS 0 을 주지만 **이것은 하한이다**. 타입 등식 재수출(`ide_paths.ml` 의 `type partition = Agent_observation.codebase_partition = …`)과 constructor 를 이름짓지 않는 타입 소비자 — 대표적으로 `lsp_overlay_provider.ml` 의 `Cache.key` 가 `partition_store_dir` 를 호출하며 이는 13개 LSP 진입점 전부의 공유 캐시 키다 — 는 이름 grep 에 잡히지 않는다 (적대 리뷰 P0-1). A~D 의 개별 branch 에서는 review 가능한 누적 diff 를 유지했지만, 최종 착륙은 E 의 current-only cut 을 포함한다. optional 기본값 11사이트 중 write 측이 A 에서 required 가 된다.
- **D 시점**: 리더가 slug/keeper 어휘로 이행하며 구 partition 타입의 마지막 소비자가 사라진다 — 구체적으로 `Ide_bridge` 의 list_* 시그니처, `Lsp_overlay_provider` 13개 진입점의 `partition option` 파라미터, REST scope 해석(`server_ide_scope.ml` 의 `scope_params` / `resolve_declared_scope` — 상호배타 검사 포함), dashboard snapshot, 그리고 그 규칙을 클라이언트에서 미러링하는 `api/ide.ts` resolveIdeScope 와 `ide-memory-panel.ts` 의 사전 검사. 서버 파라미터 개명은 미러 2곳과 한 PR 에서 움직인다. **A 에서는 이 read 시그니처들이 의도적으로 무변경이다** (타입이 살아 있으므로 컴파일 일관 — A2 는 sink write 시그니처의 분할 지점이지 리더 이행 지점이 아니다).
- **B 시점**: sink 가 Addressed fact 만 영속하고 turn_events 방출 사슬이 죽는다 (§5.2 — keeper fact 는 기존 SSOT 가 소유). 이 순간부터 `_orphan` 에 새 쓰기 0.
- **C 는 B 이후**: annotations 가 `code/` 에 떨어져야 V2 가 성립한다.
- **E 최후**: 구 partition 타입(variant enum 의 사망 지점) · orphan 기계 · 죽는 표면을 데이터 cut 과 함께 삭제한다. cut 은 §5.6 의 프로세스 메모리 무효화와 원자적으로 묶인다.

workspace-root-only 2a/2b 와의 결합: A 는 2a 의 `Unattributed` 타입을 소비하므로 **2a 선행이 이상적**이나, 2a 미착륙 시 A 가 동등 타입을 자기 모듈에 정의하고 2a 착륙 시 치환한다 (facade 아님 — 동일 개념의 소유권 이관).

## 8. 참고 제품 (원칙 5 — 검색 검증 2026-08-14)

| 제품 | 관측 | 근거 | confidence |
|---|---|---|---|
| Codex (GitHub 통합) | 리뷰를 **standard GitHub code review 의 inline comment** 로 게시 — 호스트(PR diff)의 anchor 어휘를 재사용, 자체 주소 발명 안 함 | [공식 문서](https://developers.openai.com/codex/integrations/github) | High |
| OpenHands | **append-only event log 가 authority** — file 편집·관측·인과 링크가 전부 이벤트이고, UI/agent/runtime 은 서로 직접 호출 없이 같은 로그를 읽고 쓴다. "every run replayable by construction". 파일 앵커는 이벤트 페이로드, 별도 per-repo 주석 store 없음 | [SDK events 문서](https://docs.openhands.dev/sdk/arch/events), [arXiv 2511.03690](https://arxiv.org/abs/2511.03690) | High |
| OpenClaw | 영속성은 markdown 파일 + SQLite(sqlite-vec) 의 **agent 메모리** — 코드 앵커 store 아님 | [forensic 분석 arXiv 2604.05589](https://arxiv.org/pdf/2604.05589) | Medium |
| Hermes Agent (Nous) | FTS5 세션 검색 + curated memory + subagent 관측 오버레이 — 역시 세션/메모리 축이고 per-repo 코드 앵커 영속화는 부재 | [문서 저장소](https://github.com/mudrii/hermes-agent-docs) | Medium (2차 출처) |
| Claude Code | 세션 내 편집 표시는 ephemeral, 영속 주석 DB 없음 | 직접 관측 | High |
| Orca | 확인 필요 (동명 대상 다수, 식별 불가) | — | — |

검증된 패턴 두 가지:

1. **anchor 어휘는 빌리거나(GitHub PR diff) ephemeral 로 남긴다.** 자체 어휘의 영속 per-repo 주석 DB 를 유지하는 제품은 4개 검증 대상 중 0 — §5.5 축소 방향과 정합.
2. **이벤트 로그가 authority, 뷰는 projection** (OpenHands). masc 용어로: observation bus 의 fact 가 authority 이고 per-repo 타임라인·gutter 는 파생 — §5.1 의 turn join 파생과 같은 구조다.

## 9. Open questions

1. cursor_events — UI 는 wired(`keeper-cursor-overlay` → `fetchIdeCursors` → `list_cursors`, dashboard snapshot 도 호출)인데 producer 가 07-04 이후 침묵. "안 쓰는 기능"이 아니라 **"조용히 고장난 기능"**이다 — producer 수선 vs 기능 동반 삭제의 제품 결정 필요.
2. checkout 판별자 표기 — `rev-parse --show-toplevel` 기반 실측값 제안 (workspace-root-only §5.2 인수). key 비참여는 본문 확정, 표기 형식만 미정.
3. 한 tool call 이 **두 저장소의 파일을 만지는 경우** (예: Execute 가 masc 와 agent_core 를 함께 편집) — fact 는 주 경로 하나의 주소만 나른다. 현행과 동일한 한계이나 타입이 이를 명시하지 않는다. 부 경로들을 별도 Code fact 로 분리 방출할지, 단일 주소 한계를 계약으로 못박을지 결정 필요.
4. annotate 의 unaddressed tool-response — §5.3 의 typed reject 로 원칙은 닫혔으나, reject payload 의 정확한 필드(재시도 힌트 포함 여부)는 C 의 스키마 작업에서 확정.
5. keeper 가 보내는 slug 는 self-asserted — 형식 검증(`Code_address.v`)만 있고 "이 keeper 가 실제로 그 저장소에서 작업 중인가"는 검증하지 않는다 (C 적대 리뷰 P1-3). co-view echo 계약의 의도된 신뢰이나, LLM 이 멀티턴에서 이전 저장소의 slug 를 재사용하면 orphan 매장보다 조용한 오귀속이 된다. 방어를 넣는다면 자리는 workspace-root-only 2b 의 실측 체크아웃 slug 집합 대조 — 게이트 신설이 아니라 관측 소비.
6. slug drift — origin remote 가 바뀌면(조직 개명, host 이전, fork 승격) slug 가 갈라져 같은 저장소의 기록이 두 파티션으로 나뉜다. 일회성 전환이 아니라 **운영 중 반복 가능한 정상 이벤트**라 hard-cut 독트린의 범주 밖이다. 권고 기본값: drift 는 정상 동작으로 계약한다 — 새 파티션이 시작되고 둘 다 §5.4 모집합에 보인다. 자동 병합은 만들지 않는다 (병합은 identity 를 다시 추측하는 일이고, 그 추측이 이 RFC 가 죽이는 부류다). 운영에서 실제로 아프면 명시적 1회성 이관 도구로.
