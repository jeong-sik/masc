# RFC-OAS-015: Mutable Cleanup Roadmap

| | |
|---|---|
| Status | Draft |
| Author | jeong-sik (with Claude analysis) |
| Created | 2026-05-09 |
| Target | `agent_sdk` (oas) — and as cross-repo template for `masc_mcp` |
| Supersedes | None |

## 0. Summary

OCaml `ref` / `mutable record` / `Hashtbl` 사용지점을 *3 카테고리*로 분류하고 *category별 점진 cleanup roadmap*을 제시. 무차별 immutable 변환은 *concurrency 의미*와 *성능 가정*을 silent로 깨뜨릴 수 있어 *분류 우선* 전략 채택.

본 RFC는 *roadmap docs + 1 demo cleanup*. 실제 변환은 *카테고리별 후속 PR*로 분리.

## 1. Inventory (line-pinned, 2026-05-09 main)

### 1.1 OAS (`agent_sdk`)

| 패턴 | 카운트 | 비고 |
|---|---|---|
| `let X = ref Y` | 149 init | 가장 큰 surface |
| `mutable record field` | 50+ files | metrics + state buffers |
| `Hashtbl` | 100+ files | tool_index, complete_stream_acc |

Top files:
- `lib/streaming.ml`: 17 ref (streaming buffer — *legitimate*)
- `lib/llm_provider/complete_stream_acc.ml`: 16 ref (stream accumulator — *legitimate*)
- `lib/llm_provider/transport_codex_cli.ml`: 12 ref (transport state — 검토 필요)
- `lib/proof_store.ml`: 11 ref (CDAL 제거 때 OAS lib에서 함께 제거됨)

### 1.2 masc-mcp

| 패턴 | 카운트 | 비고 |
|---|---|---|
| `let X = ref Y` | **592 init** | 340 files |
| `mutable record field` | 132 files | dashboard + governance state |
| `Hashtbl` | 230 files | coordination state, registry |

Top files:
- `lib/keeper/keeper_run_tools.ml`: 28 ref
- `lib/keeper/keeper_turn_slot.ml`: 24 ref
- `lib/keeper/keeper_heartbeat_loop.ml`: 19 ref
- `lib/dashboard/dashboard_http_keeper.ml`: 18 ref

### 1.3 합계

**OAS + masc-mcp = ~700+ ref** + **180+ mutable record** + **300+ Hashtbl**.

## 2. 카테고리 분류

### 2.1 Category A — Legitimate (변경 금지)

*concurrency, performance, streaming buffer, atomic counter for thread-safety* 정당한 사용.

특징:
- `Atomic.t` 기반 lock-free
- streaming buffer (byte-level append)
- *Eio-domain shared state* (mutex-protected)
- Hashtbl with O(1) lookup performance assumption

예: `streaming.ml`의 17 ref, `complete_stream_acc.ml`의 51 Hashtbl.

**처리**: *그대로 유지*. cleanup 대상 아님.

### 2.2 Category B — Idiomatic but replaceable (cleanup 가능)

*counter, accumulator in pure-ish function* — `fold` 또는 `mapi`로 대체 가능.

패턴 예:
```ocaml
let idx = ref 0 in
List.fold_left (fun acc x ->
  let v = f x !idx in
  incr idx;
  acc + v
) 0 xs
```

→
```ocaml
let _, total =
  List.fold_left (fun (idx, acc) x ->
    let v = f x idx in
    (idx + 1, acc + v)
  ) (0, 0) xs
in
total
```

또는 `List.mapi` + `List.fold_left`로.

**처리**: *카테고리별 PR로 점진 변환*. behavior 변화 0이지만 idiomatic 깨끗함 +.

### 2.3 Category C — Workaround (cleanup 우선)

*single-write 후 read*만 — `let binding`으로 충분한데 `ref` 사용. *lazy code* 또는 *literal copy from imperative source*.

패턴 예:
```ocaml
let x = ref initial in
(* no `:=`, no `incr x`, no `decr x` *)
... !x ...
```

이런 ref는 *완전히 불필요*. let binding 직접 교체.

**처리**: *우선순위 cleanup*. 위험 0, 면적 작음.

#### 2.3.1 Identification grep recipe

```bash
# Look for ref vars with NO mutation of any kind across the whole file:
#   `:=` assignment (any newline-formatting), `incr v`, `decr v`.
# Multi-line (-U) is required: OCaml frequently formats long mutations as
#   `varname\n        := <expression>` over two lines, and a line-based
# rg call would treat the `:=` line as not containing the variable.
for f in $(rg -l 'let \w+ = ref ' lib/); do
  for v in $(grep -oE 'let [a-z_][a-z_0-9]* = ref ' "$f" | awk '{print $2}'); do
    mut=$(rg -U -c \
            -e "\b$v\s*:=" \
            -e "\bincr\s+$v\b" \
            -e "\bdecr\s+$v\b" \
            "$f" 2>/dev/null \
          | awk -F: '{s+=$NF} END{print s+0}')
    rd=$(rg -c "!$v\b" "$f" 2>/dev/null || echo 0)
    if [ "$mut" = "0" ] && [ "$rd" -ge "1" ]; then
      echo "$f: '$v' is Category C (no mutation, $rd reads)"
    fi
  done
done
```

##### Known false-negative classes (lessons learned)

| Iteration | Pattern that fooled it | Fix |
|---|---|---|
| PR-A | single regex with shell-quoted `\|` alternation | use `rg -e` per pattern |
| PR-B | `incr` / `decr` not covered | added per-pattern `-e` clauses |
| PR-C (this) | multi-line formatting `var\n  := ...` (line-based rg miss) | added `rg -U` (multiline) |

##### Closure-around-ref caveat (still a Category B, not C)

The recipe above flags *zero file-wide mutation*. It does **not** distinguish
between:

- *truly unused mutation* (Category C) — let-binding suffices
- *closure-mediated mutation* (Category B) — a helper inside the same function
  body mutates the ref:

```ocaml
let violations = ref [] in
let add ~axis ~code ~severity ~message =
  violations := add_violation !violations ~axis ~code ~severity ~message
in
... add ~... ; add ~... ; ...
List.rev !violations
```

Both `:=` and `!violations` exist; the recipe correctly counts them. But the
mutation is *inside a let-binding closure*, and a single mass-conversion is
risky because every caller of `add` becomes responsible for threading the
accumulator. Treat closure-around-ref as **Category B with elevated review
cost** — defer to lab/ branch demos, never bulk-cleanup.

##### Verified scan as of RFC-OAS-015 PR-C

| Repo | Category C strict (true zero mutation) |
|---|---|
| OAS `lib/` | **0** after PR-A + PR-B (eval_stats.idx and harness.common were Category B incr-loops, both converted) |
| masc-mcp `lib/` | **2** false-positives traced to multi-line `:=` formatting (`cdal_runtime/proof_capture.ml: refs`, `coordination_product.ml: violations`) — both reclassified Category B (closure-around-ref) and deferred. |

→ *true Category C is the rare case*. Most "looks like a bare ref" is actually
Category B with a non-obvious mutator.

## 3. Quick-win Demo (이 PR)

`lib/eval_stats.ml:137`의 *Category B* 패턴을 *fold accumulator*로 변환:

### Before
```ocaml
let idx = ref 0 in
let num, den =
  List.fold_left
    (fun (num, den) y ->
       let dx = float_of_int !idx -. x_mean in
       incr idx;
       num +. (dx *. (y -. m)), den +. (dx *. dx))
    (0.0, 0.0)
    xs
in
```

### After
```ocaml
let _, num, den =
  List.fold_left
    (fun (idx, num, den) y ->
       let dx = float_of_int idx -. x_mean in
       (idx + 1, num +. (dx *. (y -. m)), den +. (dx *. dx)))
    (0, 0.0, 0.0)
    xs
in
```

- `idx`가 *fold accumulator의 첫 번째 필드*로 들어감
- `incr idx` → `idx + 1` (immutable update)
- `!idx` → `idx` (직접 binding)
- 결과 tuple destructure: `let _, num, den = ...`

**Behavior 변화**: 0 (수학적 동일).

## 4. Roadmap

| Phase | 작업 | 면적 |
|---|---|---|
| **PR-A (this)** | RFC docs + Category B demo (eval_stats.ml) | 2 files / small |
| **PR-B+ (future)** | Category C cleanup — *single-read zero-mutation ref* per file | per-file |
| **PR-X (future, lab/)** | Category B — counter/accumulator → fold (eval_stats 외) | per pattern |
| **deferred** | Category A — 그대로 유지 (정당화 문서만) | 0 |

masc-mcp 측은 *별 RFC* (RFC-MASC-XXX) 또는 본 RFC 본문 확장.

## 5. 정량 측정 (Phase별)

각 cleanup PR이:
- *line-by-line* 변환 (immutable 1:1)
- behavior 동일 (테스트 통과 + dune build clean)
- 가능하면 *property test* 추가 (qcheck로 input 무작위 후 동일 결과)

## 6. 위험과 완화

| # | 위험 | 완화 |
|---|---|---|
| 1 | Category A를 잘못 분류해서 변경 → concurrency 깨짐 | RFC §2의 카테고리 정의를 *grep + caller-context*로 검증 후 PR 생성 |
| 2 | Category B의 *fold accumulator* 변환이 *closure capture* 가정 깨뜨림 | inline test + property test로 동일성 검증 |
| 3 | workaround rejection bar와의 정합 | 카테고리 C는 *workaround*에 해당, 정리가 *워크어라운드 거부 bar* 정신 일치 |

## 7. References

- `software-development.md` §OCaml — Result Type 우선, Obj.magic 금지
- `feedback_pre_migration_grep_for_classification.md` — pre-migration grep 룰
- 메모리 `feedback_workaround_rejection_bar` — workaround signature
