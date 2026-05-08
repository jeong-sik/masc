# RFC-0054 — `[@@deriving shell_ir]` PPX for Typed Capability Substrate Phase 2

Status: Draft · PR-1 + PR-1b attempted 2026-05-09 · blocked (5/5 approaches fail) · candidate for CLOSED-WONTFIX
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-09 (drafted) · 2026-05-09 (§5.3.1 + §5.3.3 empirical evidence amendments)
Supersedes: —
Related: RFC-0005 §3.2 (Phase 2 PPX, listed but unsourced),
progress_report.md 2026-05-09 §3.2

## 1. Problem

`lib/exec/shell_ir_typed.ml` defines a 9-constructor GADT
`('i, 'o, 'r, 's) command` plus four hand-written walker functions:

| Function | Signature | What it does |
|---|---|---|
| `to_simple` | `('i,'o,'r,'s) command -> Shell_ir.simple` | typed → untyped, for legacy callers |
| `of_simple` | `Shell_ir.simple -> wrapped` | untyped → typed (existential `W : … -> wrapped`) |
| `risk` | `wrapped -> [`Safe | `Audited | `Privileged]` | extract third type param |
| `sandbox` | `wrapped -> [`Host | `Docker]` | extract fourth type param |

Three problems:

1. **Boilerplate liability.** Each new GADT constructor requires four new
   match arms — none of them carry information the type declaration
   doesn't already encode. Adding `Mv : { src : string; dst : string }
   -> (unit, unit, [`Audited], [`Host]) command` means writing four
   ~3-line cases that the type signature already determines.

2. **Drift class.** When constructors are added without updating one of
   the four functions, the compiler catches `to_simple` /  `of_simple`
   (exhaustive match), but **not** `risk` / `sandbox` (catch-all
   patterns). Silent miscategorisation of a new privileged command as
   `Safe` is the highest-impact failure mode.

3. **Scaling barrier.** Phase 3-4 of RFC-0005 (61-tool migration)
   would multiply this boilerplate by ~7×. Hand-writing is the
   blocker, not the design.

The standard fix in this repo is `ppx_tla` (711 LoC, Cycles 2-21).
That deriver was not extended to GADTs with non-phantom type
parameters — see Cycle 20 / Tier I8 deferral note in
`ppx_tla/ppx_tla.ml`:

> Emitting `let to_tla_symbol : type a. a t -> string = function …` via
> ppxlib AST builders requires a three-piece AST (`ptyp_poly` +
> `pexp_newtype` + inner `pexp_constraint`) whose interaction with
> OCaml 5.4's scoped-type rules is non-trivial.

`[@@tla.phantom_param]` (Cycle 20 / Tier I9) handles *phantom* type
parameters but not *constrained* parameters like
`Ls : … -> (unit, string, [`Safe], [`Host]) command` where the third
slot is a specific closed poly-variant value, not a type variable.

## 2. Goals

1. Eliminate the four hand-written walker functions in
   `shell_ir_typed.ml` in favor of `[@@deriving shell_ir]` annotation.
2. Make adding a new GADT constructor a one-line type-decl change —
   the deriver generates all four walkers; no manual case work.
3. Keep the existing untyped path (`Capability_check.of_simple`) and
   typed path (`Capability_check_typed.of_command`) running in
   parallel through migration; bytewise-identical behaviour to today.
4. Preserve `Generic : Shell_ir.simple -> (..., [`Privileged], [`Host])
   command` as the fail-closed catch-all. The deriver must respect
   this pattern, not strip it.

## 3. Non-goals

- **`[@@deriving tool]` for tool descriptors** — separate trajectory
  (Phase 2.5). Tool_id.t is already typed (PR #14282); JSON-schema
  derivation across 61 tool variants is a different problem with
  different ergonomics.
- **`mode_enforcer.ml → tool_effect.ml` rename** — separate
  refactor; can land before, after, or independent of this RFC.
- **Migration of `lib/exec/test/test_shell_ir_typed.ml`** — tests
  consume the public API. The PPX retains the same function names and
  signatures; tests stay green by construction.
- **Wider use of `[@@deriving shell_ir]`** beyond `shell_ir_typed.ml`.
  The deriver is GADT-shape-specific. Reuse outside that file is a
  follow-up RFC if a second consumer ever appears.

## 4. Design

### 4.1 Library placement

Add the new deriver to **`ppx_tla` itself** (not a separate
`ppx_shell_ir` library). Rationale:

- `ppx_tla` already has 711 LoC of ppxlib AST machinery, GADT
  detection (Tier I8), phantom-param handling (Tier I9). Building
  fresh duplicates that work.
- Both PPXs operate on the same kind of input (variant declarations
  with per-constructor metadata). The deferral in I8 was about *how*
  to emit `let f : type a. a t -> _`; that machinery, once built,
  serves both `[@@deriving tla]` and `[@@deriving shell_ir]`.
- Two libraries doubles the dune wiring + opam pin surface area. One
  library + two deriver entry points is leaner.

If `ppx_tla` later grows large enough that splitting helps reader
load, that's a separate RFC; not a prerequisite.

### 4.2 Annotation surface

```ocaml
type wrapped = W : ('i, 'o, 'r, 's) command -> wrapped

and (_, _, _, _) command =
  | Ls : { path : string option; flags : [ `Long | `All | `Human ] list }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | Cat : { path : string }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  (* … 7 more constructors … *)
  | Generic : Shell_ir.simple
      -> (Shell_ir.simple, string, [ `Privileged ], [ `Host ]) command
[@@deriving shell_ir]
```

Generated functions (signatures unchanged from current hand-written):

```ocaml
val to_simple : ('i, 'o, 'r, 's) command -> Shell_ir.simple
val of_simple : Shell_ir.simple -> wrapped
val risk      : wrapped -> [ `Safe | `Audited | `Privileged ]
val sandbox   : wrapped -> [ `Host | `Docker ]
```

### 4.3 Per-constructor metadata

The deriver reads:

- **Constructor name** → maps to `Shell_ir` opcode by lowercasing
  (`Ls` → `"ls"`, `Git_status` → `"git status"`). Override via
  `[@shell_ir.opcode "git status"]` per constructor.
- **Result type's third param** (`[`Safe]`, `[`Audited]`,
  `[`Privileged]`) → drives `risk`.
- **Result type's fourth param** (`[`Host]`, `[`Host | `Docker]`) →
  drives `sandbox`. When the param is a *union* (`[`Host | `Docker]`),
  default to the most-permissive `Host` unless overridden by
  `[@shell_ir.sandbox `Docker]`.
- **Constructor field names** → drive `to_simple` argv assembly. For
  the `Generic` catch-all, `to_simple` returns the carried
  `Shell_ir.simple` directly.

### 4.4 `of_simple` reverse direction

The hardest derivation. Maps a runtime `Shell_ir.simple` (untyped) to
`wrapped` (existential). Strategy:

1. Examine `simple.bin` (the binary name).
2. Look up the matching constructor via the inverse of §4.3's name
   mapping (table generated alongside `to_simple`).
3. If matched, parse args according to the constructor's field schema.
4. If unmatched, return `W (Generic simple)` — the type system already
   classifies `Generic` as `[`Privileged]`/`[`Host]`, fail-closed.

Failure modes:

- Bin name in lookup table but args don't parse (e.g. `Ls { path: …;
  flags: … }` but the runtime simple has unknown flag) → fall back to
  `W (Generic simple)`. Operator gets `Privileged` classification, not
  a stale `Safe` derived from a half-parsed constructor.
- Unknown bin → `W (Generic simple)` (current hand-written behaviour
  preserved).

### 4.5 Sequencing

```
PR-1  PPX skeleton + Tier I8b unblocking
       (no shell_ir use yet — adds the type-param-emit machinery
        to ppx_tla, validates with a synthetic GADT in
        test/ppx_tla/test_typed_param.ml)

PR-2  [@@deriving shell_ir] generates `risk` and `sandbox`
       Hand-written `risk` and `sandbox` deleted; deriver output
       diffed against pre-deriver behaviour byte-for-byte in a
       golden-file test.

PR-3  [@@deriving shell_ir] generates `to_simple`
       Same migration discipline — golden-file equivalence test.

PR-4  [@@deriving shell_ir] generates `of_simple`
       Hardest derivation. Includes the round-trip property test
       (`forall c, of_simple (to_simple c) ≡ W c` for all 9
       constructors).

PR-5  Cleanup: hand-written walker code in shell_ir_typed.ml deleted;
       only the GADT type decl + `[@@deriving shell_ir]` line remain.
```

Each PR is a Draft until human approval, mechanical-only diff at the
shell_ir_typed.ml site (deriver output substitutes hand-written code,
no semantic change). PR-2/3/4 each ship with a golden-file test that
asserts byte-for-byte equivalence between hand-written and derived
output for the existing 9 constructors — regression catches itself.

## 5. Compatibility & risk

### 5.1 Type signatures preserved

`to_simple`, `of_simple`, `risk`, `sandbox` keep their existing
signatures so callers (`exec_gate.ml`, `capability_check_typed.ml`,
`risk_classifier_typed.ml`, `approval_policy_typed.ml`) need zero
changes.

### 5.2 Runtime equivalence test

PR-2/3/4 each include a test of the form:

```ocaml
let%test "deriver matches hand-written for Ls" =
  let cmd = Ls { path = Some "/tmp"; flags = [ `Long ] } in
  Shell_ir_typed.to_simple_old cmd = Shell_ir_typed.to_simple cmd
```

The `_old` form is the pre-deriver implementation kept temporarily as
a comparison baseline. Removed in PR-5 once all 9 constructors clear.

### 5.3 OCaml 5.4 scoped-type interaction

The Tier I8 deferral note flagged this. PR-1 establishes the AST
pattern:

```ocaml
let to_simple : type i o r s. (i, o, r, s) command -> Shell_ir.simple = function
  | Ls { path; flags } -> …
  | …
```

If the AST builder for this shape doesn't compose cleanly (e.g.
ppxlib version requires a specific Ast_helper invocation), PR-1 falls
back to scope-A: emit `to_simple_explicit` with manual type
annotations and document the workaround. The deriver still ships;
just doesn't claim universal type abstraction in PR-1.

#### 5.3.1 Empirical finding (RFC-0054 PR-1 attempt, 2026-05-09)

The `Ast_builder.Default` path *does* hit a non-trivial OCaml 5.4
interaction. PR-1 attempted the natural generalisation
(`pexp_newtype` × N nested + `ptyp_poly` over N univ vars +
`pexp_constraint` or `ppat_constraint`-typed argument) under three
naming conventions:

1. Same names for universal & locally-abstract (`'a, a`) — works for
   N=1 (Tier I8) but raises `variable 'a is reserved for the local
   type a` at N≥2.
2. Disjoint names (`'a, pa`) — bypasses the reserved-name error but
   the GADT match still narrows: `This pattern matches values of
   type (string, unit) edge but a pattern was expected which
   matches values of type (unit, string) edge`.
3. Argument-pattern annotation (`fun (arg : (pa, pb) edge) -> match
   arg with …`) — same narrowing failure.

The decisive observation: dumping the failing AST back to source
text via `ocamlfind ocamlc -dsource -i` produces OCaml that compiles
and runs cleanly when fed to `ocaml` directly. So the generated
*text* is valid; the *AST node tree* `Ast_builder.Default`
constructs contains some metadata divergent from what the parser
produces for the same source — and that divergence triggers GADT
narrowing during the typechecker pass.

`test/ppx_tla/test_typed_param.ml` (added by PR-1, **not registered
in the dune file**) carries the failing 2-param and 4-param GADT
cases as commented-out evidence + the diagnosis above. It serves as
a regression marker: when Tier I8b lands, the file's
`[@@deriving tla]` blocks should compile and the file gets
registered in dune.

#### 5.3.2 Fallback paths (one of these, separate PR)

- **Source-template approach.** Use `Ppxlib.Parse.expression` on a
  hand-written template string with type-name + constructor-list
  placeholders. Brittle (escaping, hygiene) but guaranteed to match
  what the parser produces.
- **ppxlib-internals approach.** Investigate Astlib / Migrate
  transforms to discover which Parsetree node attribute the source
  path attaches that the Ast_builder path omits. Requires deep
  ppxlib knowledge.

Until one of those lands, `[@@deriving tla]` continues to raise the
existing "not yet supported" error for non-phantom N-param GADT
existentials. `shell_ir_typed.ml`'s hand-written walkers stay. PR-2
through PR-5 of this RFC are blocked on this fallback being
selected and implemented.

#### 5.3.3 Source-template approaches also fail (PR-1b attempt, 2026-05-09)

§5.3.2 listed source-template via `Ppxlib.Parse.*` as the cheap
fallback path. PR-1b attempted three variants of this approach. All
three produced an AST whose dumped source compiles cleanly under
`ocaml` directly, yet fails the typechecker when consumed as the
ppxlib-emitted AST. The empirical trail extends to **five total
failed approaches**:

| # | Approach | Result |
|---|---|---|
| 1 | `Ast_builder` + same names (`'a` & `a`) | reserved-name error at N≥2 |
| 2 | `Ast_builder` + disjoint names (`'a` & `pa`) | GADT narrowing |
| 3 | `Ast_builder` + arg-pattern annotation | GADT narrowing |
| 4 | `Parse.expression` body, wrapped in `value_binding` | GADT narrowing |
| 5 | `Parse.implementation` of full `let f : type a b. T = function …` | GADT narrowing |

The decisive evidence persists: every attempted output, when
extracted via `ocamlfind ocamlc -dsource -i` and fed back to `ocaml`
as source, compiles and runs. Yet the original AST consistently
fails. The bug is in some Parsetree node attribute that *every*
ppxlib emission path attaches and the parser path omits — even
though `Parse.implementation` IS the parser path. There must be a
later transformation (possibly the ppxlib driver's `Astlib.Migrate`
between OCaml versions) that reintroduces the divergence.

Conclusion: this is not solvable by source synthesis alone. The
remaining viable path is `ppxlib-internals` (RFC §5.3.2's second
option) — direct investigation of which Parsetree attribute is
diverging, requiring deep ppxlib + OCaml typechecker knowledge.

PR-1b's deriver code is therefore **not shipped**. PR-2 through
PR-5 of this RFC remain blocked. `shell_ir_typed.ml`'s
hand-written walkers stay indefinitely until either a ppxlib
expert resolves the divergence or OCaml's GADT inference is
extended in a way that accepts the AST ppxlib produces.

The pragmatic implication: **`[@@deriving shell_ir]` may not be
achievable with the current ppxlib + OCaml 5.4 stack**. RFC-0054 may
need to be marked CLOSED-WONTFIX rather than DEFERRED. That decision
deserves an RFC-0054 amendment of its own.

### 5.4 Fail-closed preservation

`Generic : Shell_ir.simple -> (..., [`Privileged], [`Host]) command`
is the catch-all. The deriver must:

- For `to_simple`: return the carried `simple`.
- For `of_simple`: produce `W (Generic simple)` when no other branch
  matches.
- For `risk`: return `` `Privileged``.
- For `sandbox`: return `` `Host``.

If any of those four fall through to a less-restrictive value, the
type system is no longer fail-closed. PR-2/3/4 each carry a regression
test: `risk (W (Generic Shell_ir.empty_simple)) = `Privileged`.

### 5.5 PPX dev environment

`ppx_tla` already wires through `dune` with `(kind ppx_rewriter)` and
depends on `ppxlib`. PR-1 adds no new external dependency. The
existing test harness at `test/ppx_tla/` provides the smoke-test
template.

## 6. Done criteria

RFC-0054 closes when **all five** hold:

1. PR-5 has merged. `shell_ir_typed.ml` contains the GADT type decl +
   `[@@deriving shell_ir]` annotation only — no hand-written
   walkers.
2. The 9-constructor round-trip property test
   (`of_simple (to_simple c) = W c`) passes for every existing
   constructor.
3. Adding a synthetic 10th constructor (e.g. `Mv : … -> (unit, unit,
   [`Audited], [`Host]) command`) requires only the type-decl line —
   no other code change — and the new constructor is correctly
   classified by `risk` (`Audited`) and `sandbox` (`Host`).
4. `risk (W (Generic _)) = `Privileged` regression test green on every
   PR.
5. `lib/exec/shell_ir_typed.ml` LoC reduces by ≥ 60% from current
   (1023 LoC reported in earlier surveys; expect ≤ 400 after deriver
   migration). Number is informative, not a CI gate.

If any future PR re-introduces hand-written walker code adjacent to
`[@@deriving shell_ir]`, that PR is an RFC-0054 amendment. Same
discipline as RFC-0050 §6.

## 7. Open questions

1. **`[@@deriving show]` interaction.** `shell_ir_typed.ml` may
   eventually want `show` for debug. The deriver order in `[@@deriving
   show, shell_ir]` matters in ppxlib. Default: declare `shell_ir`
   first; `show` later if added.

2. **Phase 2.5 `[@@deriving tool]`.** The Tool_id.t (#14282) hand-
   written `to_string` / `of_string` could in principle be derived too.
   But Tool_id is a closed poly-variant, not a GADT — same surface as
   `[@@deriving tla]` already handles. If `[@@deriving tla]` covers
   Tool_id's needs, no new deriver is needed; otherwise a separate
   RFC. Out of scope here.

3. **Existential `wrapped` vs explicit type-param interface.** Some
   callers may want `(_, _, _, _) command` directly (no existential
   wrapper). Whether to derive functions for both forms is decided per
   PR.

## 8. Out of scope (cross-references)

- RFC-0005 §A4 87-site cutover: requires the typed walker to be
  efficient enough to replace untyped — RFC-0054 ships the typed path
  but does not retire the untyped path.
- 61-tool migration (Phase 3): unrelated to GADT walker derivation.
  Tool_id.t covers tool ID typing; tool effect classification is
  separate.
- Multi-provider JSON Schema generation: blocked on
  `[@@deriving tool]`, which is Phase 2.5 not this RFC.
- Dashboard telemetry typed surface IDs: RFC-0048 territory, unrelated.
