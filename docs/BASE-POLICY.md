# Jane Street Base Adoption Contract

> **MASC tracking**: goal `goal-janestreet-base-adoption`, task `task-130`
>
> This document is the single source of truth for how Jane Street
> [Base](https://github.com/janestreet/base) is used in `masc`.
> It exists so reviewers can give consistent feedback without relying
> on ad-hoc PR memory.

---

## 1. Inventory

`open Base` is not in this tree. Counted 2026-08-25 with
`rg '^\s*open!? Base'` over every `.ml` and `.mli`:

| Layer | `.mli` with `open Base` | `.ml` with `open Base` |
|---|---:|---:|
| `lib/` (top-level) | 0 | 0 |
| every sub-package  | 0 | 0 |

The contract was written when `lib/` top-level held 97 `.mli` and 100 `.ml`
with `open Base`. The purge in §7 ran to completion; §6 asked whether to
continue it or stop, and continuing is what happened.

The one `Base.` left in `lib/` is `Agent_core.Base.Tool` in
`tool_bridge.ml` -- masc's own module of that name, not Jane Street's. The
`base` in several `dune` files is `masc.agent_core.base`, likewise.

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
| `mli_open_base` | `.mli` files in `lib/` containing the `open Base` directive (anchored: `^[[:space:]]*open[[:space:]]+Base([^[:alnum:]_]|$)`, excludes comments/docstrings) |
| `ml_base_stdlib_shadow` | `.ml` files in `lib/` containing a Stdlib-shadow block (`^[[:space:]]*module[[:space:]]+List[[:space:]]*=[[:space:]]*Stdlib\.List([^[:alnum:]_]|$)`), whether or not the file still opens Base |
| `bin_ml_base_stdlib_shadow` | `.ml` files in `bin/` containing the same Stdlib-shadow block, on the same terms |

These counters are recorded in `.ci/health-baseline.json` and reported
by `scripts/health_snapshot.sh`.  A PR that increases any counter
above the baseline fails the gate when the audit is run with
`base-policy-audit.sh --fail-on-regression`;
CI also includes them in the `health_snapshot.sh --fail-on-lib-regression`
ratchet.  When a baseline ref predates these counters, the audit treats
the first measured value as the bootstrap baseline rather than a
regression.

The two shadow counters used to require the `open Base` directive in the
same file. Once the opens were gone the counters read zero while 82 files
kept the shadow block, so the audit passed over exactly the residue it
exists to catch. They now match the block on its own.

As of the 2026-05-05 ratchet, all three tracked counters are zero in
current `main`; `.ci/health-baseline.json` records zero so any
reintroduction of the forbidden interface open or shadow anti-pattern
fails the ratchet.

```sh
bash scripts/base-policy-audit.sh --fail-on-regression
```

Run without arguments to report counts without failing:

```sh
bash scripts/base-policy-audit.sh
```

---

## 5. MASC goal and task linkage

| Field | Value |
|---|---|
| Goal ID | `goal-janestreet-base-adoption` |
| Task ID | `task-130` |

The decision §6 of the original contract left open -- continue the purge or
stop it -- was settled by continuing. There are no `open Base` occurrences
left to evaluate, so the lane has nothing to claim; what remains is the audit
in §4, which holds the count at zero.

---

## 6. Migration order — done

The order the contract recommended, and what is left of each step:

1. **`.mli` files in `lib/`** — nothing left (0).
2. **`.ml` files with the Stdlib-shadow anti-pattern** — nothing left (0),
   and `scripts/base-policy-audit.sh` holds `ml_base_stdlib_shadow` and
   `bin_ml_base_stdlib_shadow` at that count.
3. **`.ml` files with genuine Base usage** — nothing left (0).
4. **Sub-packages** — Base-free, as they were.

So this document is no longer a plan. It is the rule a reviewer applies to a
new `open Base`, and §4 is the check that catches one.
