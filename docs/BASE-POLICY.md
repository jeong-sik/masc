# Jane Street Base Adoption Contract

> **MASC tracking**: goal `goal-janestreet-base-adoption`, task `task-130`
>
> This document is the single source of truth for how Jane Street
> [Base](https://github.com/janestreet/base) is used in `masc-mcp`.
> It exists so reviewers can give consistent feedback without relying
> on ad-hoc PR memory.

---

## 1. Inventory (as of contract creation)

| Layer | `.mli` files with `open Base` | `.ml` files with `open Base` | `.ml` files with Stdlib-shadow block |
|---|---:|---:|---:|
| `lib/` (top-level)   | 97 | 100 | 96 |
| `lib/config/`        |  0 |   0 |  0 |
| `lib/goal/`          |  0 |   0 |  0 |
| `lib/coord/`         |  0 |   0 |  0 |
| `lib/keeper/`        |  0 |   0 |  0 |
| `lib/exec/`          |  0 |   0 |  0 |
| `lib/server/`        |  0 |   0 |  0 |
| `lib/dashboard_utils/` | 0 |   1 |  0 |
| `lib/cascade/`       |  0 |   0 |  0 |
| `lib/shared_audit/`  |  0 |   0 |  0 |
| `lib/types/`         |  0 |   0 |  0 |

**Key observation**: Sub-packages (`config`, `goal`, `coord`, `keeper`,
`exec`, `server`, `cascade`, `shared_audit`, `types`) are already
Base-free.  The concentration is in the top-level `lib/` tool and
dashboard modules.

---

## 2. Adoption rules

### Rule 1 — `open Base` in `.mli` files is **FORBIDDEN**

`.mli` files are public module contracts.  Placing `open Base` at the
top of a `.mli` has no positive effect (Base's types are structurally
identical to Stdlib's) but carries several costs:

- It introduces a spurious dependency on Base at every compilation
  unit that references this interface.
- It signals that the interface uses Base-specific types when it
  usually does not.
- Future readers must mentally track which type names come from Base
  vs Stdlib when reading the contract.

**Correct**: omit `open Base` from all `.mli` files.  Use fully
qualified `Base.X.y` names in docstring references only
(e.g. `(** Re-export of [Base.Option.first_some]. *)`).

### Rule 2 — `open Base` in `.ml` files is **ALLOWED** with constraints

`open Base` in an implementation file is legitimate when the file
genuinely uses Base-exclusive utilities (e.g. `Base.String.is_prefix`,
`Base.Option.first_some`, Base's `Sequence`, etc.).

It is **NOT** acceptable to write:

```ocaml
(* anti-pattern: open Base then immediately shadow everything back *)
open Base
module List   = Stdlib.List
module String = Stdlib.String
module Map    = Stdlib.Map
...
```

This pattern provides no benefit: Base was opened only to be un-opened
for the most commonly used modules.  Replace it with no `open` at all
or with targeted qualified access (see Rule 3).

### Rule 3 — Qualified `Base.*` access is **PREFERRED** over global open

When only one or two Base helpers are needed, use qualified access:

```ocaml
(* Good: explicit, grep-able, self-documenting *)
let first_some = Base.Option.first_some
let contains ~needle s = Base.String.is_substring s ~substring:needle
```

This keeps the Stdlib namespace unobstructed and makes Base usage
visible at the call site.

### Rule 4 — Stdlib / local compatibility APIs are **PREFERRED** by default

New code should use Stdlib unless a Base-exclusive feature is required.
Local compatibility wrappers (e.g. `Safe_ops`, `Json_util`) are
preferred over both Base and raw Stdlib when they already exist.

---

## 3. Interface (`.mli`) rules

1. **No `open Base`** — see Rule 1.
2. **No Base container types in signatures** — use `string list`,
   `(string * 'a) list`, or `Hashtbl.t` (Stdlib) rather than
   `Base.Map.t`, `Base.Set.t`, etc.  If a Base container must appear,
   qualify it explicitly: `Base.Map.Using_comparator.t`.
3. **Docstring references to Base** — allowed and encouraged for
   transparency (e.g. `(** Uses [Base.String.is_prefix]. *)`).
4. **Type identity** — since Base re-exports Stdlib primitive types,
   there is no nominal incompatibility; the restriction is purely about
   readability and dependency hygiene.

---

## 4. CI / source audit

`scripts/base-policy-audit.sh` counts:

| Counter | What it measures |
|---|---|
| `mli_open_base` | `.mli` files in `lib/` containing the `open Base` directive (anchored: `^[ \t]*open[ \t]+Base\b`, excludes comments/docstrings) |
| `ml_base_stdlib_shadow` | `.ml` files in `lib/` that contain both the `open Base` directive and a Stdlib-shadow block (`module List = Stdlib.List`) |

These counters are recorded in `.ci/health-baseline.json` and reported
by `scripts/health_snapshot.sh`.  A PR that increases either counter
above the baseline fails the gate when the audit is run with
`base-policy-audit.sh --fail-on-regression`;
CI also includes them in the `health_snapshot.sh --fail-on-lib-regression`
ratchet.  When a baseline ref predates these counters, the audit treats
the first measured value as the bootstrap baseline rather than a
regression.

```sh
bash scripts/base-policy-audit.sh --fail-on-regression
```

Run without arguments to report counts without failing:

```sh
bash scripts/base-policy-audit.sh
```

---

## 5. Representative migration — `tool_compact`

`lib/tool_compact` was the first module migrated under this policy
(see the commit that introduced this document):

**Before (`tool_compact.mli`)**:
```ocaml
open Base

type tool_result = bool * string
val schemas : Types.tool_schema list
val dispatch : name:string -> args:Yojson.Safe.t -> tool_result option
```

**After**:
```ocaml
(** Tool_compact — placeholder tool module. … *)
type tool_result = bool * string
val schemas : Types.tool_schema list
val dispatch : name:string -> args:Yojson.Safe.t -> tool_result option
```

**Before (`tool_compact.ml`)**:
```ocaml
open Base
module Format = Stdlib.Format
module Map    = Stdlib.Map
…                                (* 15 Stdlib shadow lines *)
let schemas : Types.tool_schema list = []
```

**After**:
```ocaml
(** Tool_compact — OAS-backed compaction pipeline. … *)
let schemas : Types.tool_schema list = []
```

Both files compile without `open Base` because the module contains
only empty stubs using primitive Stdlib types.  The Dune check target
(`dune build @check`) validates this.

---

## 6. MASC goal and task linkage

| Field | Value |
|---|---|
| Goal ID | `goal-janestreet-base-adoption` |
| Task ID | `task-130` |
| Horizon | Mid |
| Owner lane | Keepers on `task-130` claim work items from this policy |

Active purge tasks `task-117`–`task-125` and OAS Base policy task
`task-128` should be evaluated against this contract before any further
`open Base` removal or addition.  The contract is the decision point:

- **Continue purge** → every removed `open Base` must pass Rules 1–4.
- **Stop purge** → close the purge lane as intended direction with this
  document as the rationale.

---

## 7. Migration order (recommended)

Priority is determined by layer stability and reviewer blast-radius:

1. **`.mli` files in `lib/`** — remove `open Base` (Rule 1).  Each
   removal is a one-line change that Dune validates immediately.
2. **`.ml` files with the Stdlib-shadow anti-pattern** — remove
   `open Base` + the shadow block (Rule 2).  Validate by confirming no
   Base-exclusive calls remain.
3. **`.ml` files with genuine Base usage** — migrate call-by-call to
   qualified `Base.*` access (Rule 3), then remove `open Base`.
4. **Sub-packages** — already Base-free; maintain by policy (Rule 4).
