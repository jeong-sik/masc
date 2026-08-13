---
rfc: "0378"
title: "Code fact 는 태어날 때 주소를 받는다 — typed address, observation store 이분, anchor 계약 통일"
status: Draft
created: 2026-08-14
updated: 2026-08-14
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0343", "keeper-workspace-root-only", "0233"]
implementation_prs: []
---

# RFC-0378: Code fact 는 태어날 때 주소를 받는다

## 0. Summary

Keeper 의 코드 작업이 IDE 에 보이려면 쓰기와 읽기가 같은 주소로 만나야 한다. 지금은 `file_path : string` 하나가 4개 어휘(repo-relative / `repos/<id>/` 접두 / `.worktrees/` 접두 / 절대경로)를 실어 나르고, 읽기는 그중 1개만 묻는다. 이 RFC 는 주소를 **발행 시점에 한 번 파싱된 타입**으로 확정하고, store 를 code fact / keeper fact 로 이분해 `_orphan` 을 없애고, annotate 의 anchor 계약을 IDE co-view 계약과 동일하게 만든다. 귀속 *메커니즘*(경로→저장소 정체)은 RFC-keeper-workspace-root-only 소관이고, 이 RFC 는 **그 결과값의 타입·수명·저장·소비**를 소관한다.

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
| `by-url/` 파티션 15개 중 내용 있는 것 | 3개 (masc, oas, masc 8.5M 가 사실상 전부) |
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
| 동일 origin N-clone 의 checkout 판별자를 record 에 넣는가 (그쪽 §5.2 미결) | **이 RFC 가 답한다**: 넣되 key 가 아니라 projection 메타데이터 (§5.1) |

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
      ; unaddressed : Unattributed.reason option
        (* workspace-root-only 2a 의 타입. 관측성은 여기서: 카운터가 아니라 질의 가능한 필드 *)
      ; body : body
      }
```

- 소비자는 주소를 **재유도할 수 없다** — 타입이 원천 봉쇄한다 (#28582/#28595 독트린의 타입화).
- `codebase_partition` 의 실패 4변형(`No_canonical_url`/`Unmatched`/`Base_unresolved`/`Legacy_default`)은 **삭제**. 실패는 store 의 파티션이 아니라 fact 의 종류다.
- turn event 는 정의상 `Keeper` fact. 저장소 타임라인은 `Code(address, turn_id)` 조인으로 파생 — 스키마 추가 없음.
- 효과 분리(원칙 4/17): 주소 발행은 순수, append 는 가장자리.
- 경로 정규화는 손 구현 대신 이미 의존성에 있는 `fpath` 를 쓴다 (`lib/server/dune:123`, 원칙 19).

### 5.2 Store 이분 — `_orphan` 소멸

```
<store-root>/
  code/by-url/<slug>/{tool_events,regions,annotations}.jsonl   ← Code fact 만
  keeper/<keeper_id>/{turn_events,tool_events}.jsonl           ← Keeper fact 만
```

- 모든 fact 는 정확히 한 곳에 떨어진다. `_orphan/` 디렉터리·`orphan_path`·`partition_is_orphan`·`IdeOrphanWrites` 카운터는 코드에서 삭제.
- 회전(rotation) 메커니즘은 유지 (storage 역학이지 keeper 흐름 제어가 아님 — 원칙 9 비저촉).
- IDE 는 `code/` 만 읽고, keeper 타임라인 패널은 `keeper/` 를 읽는다.

### 5.3 Anchor 계약 = co-view 계약

`keeper_ide_annotate`(및 향후 anchored reply)의 입력은 **IDE 가 keeper 에게 준 바로 그 어휘**다: `(canonical slug, repo-root 상대 경로, line range)`.

- **repo *이름*이 아니라 slug 다.** 현행 co-view 는 `repo: masc` 처럼 이름을 보내는데, 이름은 slug 와 별개인 또 하나의 문자열 별칭이라 계약 안에 어휘 분열을 재생산한다 (원칙 10). IDE 는 이미 자기 scope 의 slug 로 질의하고 있으므로 co-view 도 slug 를 싣는다. 그러면 annotate 의 서버 측 카탈로그 홉(이름→url→slug)이 통째로 사라진다 — 왕복의 두 절반과 read path 셋이 문자 그대로 같은 key 를 쓴다.
- keeper 가 자기 마운트 레이아웃(`repos/<id>/…`)을 알아야 앵커를 되돌려줄 수 있는 현행 계약(#23469 의 sandbox-root 앵커링)은 삭제한다. keeper 는 받은 것을 그대로 돌려주면 된다.
- 도구 스키마와 keeper 프롬프트가 이 계약을 서술한다 (프롬프트 변경은 원칙 22 로 허용).
- acceptance: §2.1 owner probe 의 **정확한 재실행**이 green — 같은 (repo, path, line) 에 마커가 뜬다.

### 5.4 Scope — 추측하지 않는다

- `selectPreferredIdeRepositoryId` 의 경로 모양 휴리스틱(절대경로·`/.masc/` 포함 여부로 "사람의 repo" 추측)은 삭제. 현재 이 추측의 답(wkbl)은 code fact 0행 파티션이다.
- 첫 진입은 명시 선택, 선택은 viewer 클라이언트에 지속 (localStorage — 서버 설정이 아니므로 TOML/env 비대상, 원칙 24).
- 저장소 목록의 **모집합도 실측**이다: 선택지는 카탈로그(repositories.toml)가 아니라 `code/by-url/` 에 실존하는 파티션에서 온다. workspace-root-only 하에서 slug 는 git remote 실측으로 발행되므로 **카탈로그 미등록 repo 의 파티션도 정당하게 생긴다** — 카탈로그를 모집합으로 쓰면 그 작업은 기록되고도 선택 불가능해진다. 카탈로그는 등록 repo 의 표시 이름을 빌려주는 projection 으로만 참여한다.
- 목록의 **정렬**은 실측(파티션별 code fact 최근성)으로 — 그것도 projection 이라 허용.
- 빈 파티션은 정직한 empty state: "이 저장소에서 keeper 작업 기록 없음".

### 5.5 개념 축소 — kill list

| 대상 | 증거 | 처분 |
|---|---|---|
| partition 실패 4변형 + orphan 경로/판별 함수 | §5.1 — 실패는 fact 종류 | 삭제 (컴파일러가 낙진 전파) |
| `_orphan/` 데이터 380 MiB | store 의 97.6%, code fact 아님 | hard cut (§5.6) |
| `IdeOrphanWrites` 카운터 | telemetry-as-fix, 소비자 0 | 삭제 |
| LSP definition/references/documentSymbol/highlights/related-locations | 읽는 store 가 평생 4행 | 삭제 + 해당 테스트 동반 삭제 (원칙 20) |
| LSP InlayHint (route-context) | 사용 증거 0 | 삭제 후보 — Open Q1 |
| cursor_events·pr_events store/라우트/오버레이 | 마지막 기록 07-04/06-12, orphan 한정 | 라이브 여부 실측 후 삭제 — Open Q2 |
| `selectPreferredIdeRepositoryId` 휴리스틱 | 추측의 답이 빈 파티션 | 삭제 → §5.4 |
| annotate sandbox-root 앵커링 | owner probe 2건 매장 | 계약 교체로 소멸 (§5.3) |
| "IDE Observation Plane v2" 죽은 포인터 | repo 에 문서 부재 | 주석에서 제거 |

**살아남는 것**: regions gutter 마커, tool/turn 타임라인, CodeLens + hover, annotation rail, anchored interject, REST annotations CRUD (사람 쪽 절반), `canonical_url_of_remote`.

annotation 의 존재 이유는 축소 재정의된다: **(a)** anchored interject 에 대한 keeper 의 anchored reply, **(b)** 기존 decision/task record 의 code-anchored projection. "keeper 가 아무 때나 남기는 노트"는 평생 4행으로 반증됐다.

### 5.6 데이터 hard cut

- `<store-root>` 전체를 아카이브 후 삭제, fresh start (원칙 8/22). 마이그레이션·호환 reader 없음.
- masc 파티션의 유용분(8.5 MiB)은 keeper 상시 가동으로 수일 내 자연 재생성된다.
- 실행은 dry-run 근거 제시 후 별도 단계 (workspace-root-only 3b 와 같은 성격의 `rm -rf` 경로 분리 원칙).

## 6. 검증

### 6.1 Browser 실측 acceptance (원칙 14/15/21 — 스크린샷 + store 행 대조 로그 필수)

| # | 시나리오 | green 조건 |
|---|---|---|
| V1 | IDE 진입 → 저장소 명시 선택 → keeper 쓰기 1회 후 해당 파일 열기 | gutter 마커 표시, store 의 해당 행과 주소 일치 |
| V2 | **owner probe 재실행**: co-view interject at file:line → keeper annotate | 같은 (repo, path, line) 에 마커 + rail 표시. `_orphan` 부재이므로 매장 불가 |
| V3 | scope 선택 → reload | 선택 유지, 재추측 없음 |
| V4 | cut 이후 store 전수 스캔 | code fact 전수가 addressed, keeper fact 전수가 keeper/ 아래 (스크립트 출력 = 증거) |

feature 왕복만 테스트한다 (원칙 20). 경로 헬퍼 단위 테스트는 만들지 않는다. 신규 테스트는 CI focused suite 에 배선한다 — masc CI 는 named suite 만 실행하므로 배선 없는 테스트는 컴파일만 된다.

### 6.2 이 설계가 틀렸다고 판정할 조건

- 주소를 타입으로 막았는데도 소비자가 주소를 재유도하는 새 사례가 컴파일을 통과하면 — 타입 설계 실패.
- V2 가 keeper 프롬프트 갱신 후에도 재현 실패하면 — 계약이 여전히 레이아웃 지식을 요구하는 것.
- keeper 가 실제 저장소 파일을 편집한 fact 가 `Keeper(unaddressed)` 로 떨어지는 재현 가능한 사례가 남으면 — 귀속(workspace-root-only 2b 폴백) 미성숙. 이 RFC 는 그 수선 없이 완료 선언 불가.

## 7. 구현 순서 — stacked PR 사다리 (원칙 16)

각 단계 ≤20k output tokens. 인접 단계 사이 적대적 리뷰 에이전트 병렬 → 리뷰 대응 에이전트 병렬. 로컬 빌드 없이 CI 로 판정.

| PR | 내용 | 성격 |
|---|---|---|
| A | `Code_address` + fact 이분 타입 + producer 컴파일 낙진 (필요시 A1/A2 분할) | 최대 낙진, 행동 불변 |
| B | store 이분 (`code/` / `keeper/`) + writer 전환 + rotation 승계 | 쓰기 전환 |
| C | annotate/anchor 계약 + keeper 프롬프트 + owner-probe feature test | N2 왕복 완성 |
| D | read path 잔존분 + dashboard scope 명시화 + empty state | N1 가시화 |
| E | kill list 집행 + 구 테스트 삭제 + 데이터 cut (dry-run 선행) | 청소 |

순서 제약과 머지 지점 일관성:

- **A 시점**: 타입만 바뀐다. sink 는 현행 배치를 유지한다 — `Code` → `by-url/<slug>/`, `Keeper` → 현행 `_orphan/` 디렉터리. 배치가 안 바뀌었으므로 read path 도 그대로 일관이다. (`_orphan` *데이터와 기계*의 삭제는 E 소관 — A 가 지우면 Keeper fact 의 착지점이 없어 일관성이 깨진다.)
- **B 시점**: 배치 전환 (`keeper/<keeper_id>/` 신설, Keeper fact 이동). 이 순간부터 `_orphan` 에 새 쓰기 0.
- **C 는 B 이후**: annotations 가 `code/` 에 떨어져야 V2 가 성립한다.
- **E 최후**: 죽는 표면의 소비자가 D 까지 존재하고, `_orphan` 잔여 기계는 B 이후 dead 지만 데이터 cut 과 함께 지운다.

workspace-root-only 2a/2b 와의 결합: A 는 2a 의 `Unattributed` 타입을 소비하므로 **2a 선행이 이상적**이나, 2a 미착륙 시 A 가 동등 타입을 자기 모듈에 정의하고 2a 착륙 시 치환한다 (facade 아님 — 동일 개념의 소유권 이관).

## 8. 참고 제품 (원칙 5 — confidence 표기, 개선 패스에서 검색 검증 예정)

| 제품 | 관측 | confidence |
|---|---|---|
| Codex (cloud) | 코드 앵커 코멘트를 GitHub PR 리뷰 어휘로 남김 — 호스트의 안정 anchor 어휘를 재사용, 자체 주소 발명 안 함 | Medium |
| Claude Code | 세션 내 편집 표시는 ephemeral, 영속 주석 DB 없음 | High (직접 관측) |
| OpenHands 계열 | event stream + replay, 파일 앵커는 이벤트 페이로드 | Medium |
| Hermes Agent / Orca | 확인 필요 | — |

패턴: 성공한 제품은 (a) 호스트(GitHub)의 anchor 어휘를 빌리거나 (b) ephemeral 로 남긴다. 자체 어휘의 영속 per-repo 주석 DB 를 유지하는 사례는 드물다 — §5.5 의 축소 방향과 정합.

## 9. Open questions

1. InlayHint(route-context) 존폐 — 사용 증거 0 이나 소비 경로 실측 후 확정.
2. cursor_events / pr_events — store 는 죽었으나 in-memory presence 경로가 별도인지 실측 후 처분.
3. keeper fact 의 배치 — 신설 `keeper/<id>/` 가 기존 keeper 이벤트 스토어(turn record 등)와 중복 방출인지 조사. 중복이면 한쪽을 죽인다 (SSOT).
4. checkout 판별자 표기 — `rev-parse --show-toplevel` 기반 실측값 제안 (workspace-root-only §5.2 인수). key 비참여는 본문 확정, 표기 형식만 미정.
5. 한 tool call 이 **두 저장소의 파일을 만지는 경우** (예: Execute 가 masc 와 oas 를 함께 편집) — fact 는 주 경로 하나의 주소만 나른다. 현행과 동일한 한계이나 타입이 이를 명시하지 않는다. 부 경로들을 별도 Code fact 로 분리 방출할지, 단일 주소 한계를 계약으로 못박을지 결정 필요.
