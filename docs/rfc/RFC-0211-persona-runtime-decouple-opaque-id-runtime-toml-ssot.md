---
rfc: "0211"
title: "Persona ⊥ {model, runtime}, opaque runtime id, runtime.toml keeper-assignment SSOT"
status: Draft
created: 2026-06-02
updated: 2026-06-02
author: jeong-sik
supersedes: []
related: ["0206", "0207", "0001"]
implementation_prs: []
---

# RFC-0211 — Persona ⊥ {model, runtime}, opaque runtime id, runtime.toml keeper-assignment SSOT

- Status: Draft. Pairs with an in-flight implementation branch
  (`feat-keeper-persona-runtime-decouple`); this document is the design SSOT, the
  implementation confirms the as-built TOML shape.
- Date: 2026-06-02
- Builds on: RFC-0206 (single-binding `Runtime`), RFC-0207 (per-keeper runtime
  routing, Part A), RFC-0001 (silent-substitution anti-pattern).
- Supersedes (partial): RFC-0207 §2 (surface choice), RFC-0206 (runtime id
  format). See §9.

## 0. Summary

A keeper's runtime is decided in one place: the `runtime.toml` keeper→runtime
assignment table. A persona carries no `model` and no `runtime` field. The masc
core treats a runtime id as an opaque token — it dispatches on the id and never
reads a provider or model out of it. The only component that parses an id into a
provider/model/spec is OAS (the external `agent_sdk` opam package), at the
TOML-binding boundary.

This keeps RFC-0207's per-keeper routing mechanism (the dispatcher honours a
per-keeper runtime selection, fail-fast on an unresolved id) and redirects the
*source* that mechanism reads from: persona-`model` (RFC-0207 §2) becomes the
`runtime.toml` keeper-assignment table. It also replaces RFC-0206's
`"provider.model"` binding-key id with an opaque token, so that no masc core
module can read provider identity out of an id.

## 1. Problem

Three coupled defects in the current main (SHA `8ed74a37c9`):

1. **Persona leaks model.** The persona JSON reader populates
   `keeper_profile_defaults.model` from a `model` key
   (`keeper_types_profile.ml:249-250`). A persona — a declarative role/identity
   description — should not name a provider-model. The persona *summary* type is
   already clean (`Keeper_types_profile_persona.persona_summary` =
   `persona_name; display_name; role; trait; profile_path; has_keeper_defaults`,
   no model/runtime field); the leak is in the separate `keeper_profile_defaults`
   blob the persona reader fills.

2. **Runtime id is not opaque.** `Runtime.t.id` is the binding key
   `"provider.model"` (RFC-0206; `runtime.mli:11,18,43-47`). `get_runtime_by_id`
   resolves a runtime by parsing that string. Any masc consumer that splits the
   id on `.` reads the provider out of the core, violating the masc ⊥
   Model/Provider goal.

3. **Two definitions of the runtime resolver disagree.**
   `keeper_meta_contract.runtime_id_of_meta` is defined twice in the same file:

   - line 648 (shadowed; zero call sites in the file), defaulting via
     `Keeper_config.default_runtime_id ()`;
   - line 750 (the binding the `.mli` exports), defaulting via
     `Runtime.get_default_runtime_id ()`.

   OCaml binds the later definition, so external callers reach line 750 and 648
   is dead. But two live definitions disagreeing on the *default source* is
   precisely the split-brain this RFC removes, observed in current code. The
   shadow is a broken-main merge artifact; §6 records its removal.

These are coupled: as long as the per-keeper runtime lives in the persona
(RFC-0207 §2) and the id is a parseable `"provider.model"`, masc cannot be made
provider-agnostic and the resolver source stays forkable.

## 2. Concept model: persona → keeper → runtime.toml → OAS

Four layers, each with one job, in dependency order:

- **persona** — a *declarative idea*. A pure role/identity definition. Knows
  nothing about model, provider, or runtime. This is the raw, unparsed input.
- **keeper** — a *materialized* execution instance derived from a persona. The
  runtime binding is injected at materialization time, read from the
  `runtime.toml` keeper-assignment table. This is the parsed, runnable value.
- **runtime.toml** — the *single source of truth*. It defines runtimes
  (provider/model/binding declarations, RFC-0206 layers 1-3 + `[runtime].default`)
  **and** the keeper→runtime assignment. Nothing else assigns a keeper a runtime.
- **OAS** (`agent_sdk` opam package) — the *only parser*. It turns an opaque
  runtime id (and the TOML provider/model/binding declarations) into a concrete
  `Llm_provider.Provider_config.t`. masc holds the id and dispatches; OAS
  resolves the id to an implementation.

This is Alexis King's "parse, don't validate" applied across the whole system:
the persona is the raw idea, the keeper is the parsed value, and parsing
(id → provider/model/spec) happens exactly once, at the OAS boundary. The masc
core stays in the unparsed (opaque-id) world and cannot accidentally read
provider identity out of a token it was never meant to interpret.

### 2.1 persona ⊥ {model, runtime}

A persona TOML/JSON carries no `model` and no `runtime` key. Model-level
differentiation (an analyst keeper on a larger model, a worker keeper on a
smaller one) is expressed by *assigning different runtimes* in the
keeper-assignment table, never by a persona naming a `provider.model`. A persona
does not know which runtime it runs on; a keeper learns its runtime from
`runtime.toml` at materialization. Per-keeper runtime differentiation remains
fully supported — it just moves from the persona to the assignment table.

### 2.2 opaque runtime id

A runtime id is an opaque token to masc. masc compares ids for equality and
dispatches on them; it does not parse them. The `[providers.*]`, `[models.*]`,
and binding declarations in `runtime.toml` — and the id → provider/model/spec
resolution — are the OAS-adapter boundary. `get_runtime_by_id` /
`runtime_id_of_meta` perform opaque-id dispatch only and never inspect an
internal provider or model.

This matches the openclaw registry seam ("a lane label must carry no readable
provider field"): the masc core deals in lanes; the OAS registry resolves a lane
to an implementation. It is the same "parse, don't validate" discipline as §2,
stated at the id level — masc holds an unparsed opaque token, OAS is the sole
parser.

## 3. Design

### 3.1 Remove the persona model leak

Delete the `model` field from `keeper_profile_defaults` and the persona-JSON
reader that fills it (`keeper_types_profile.ml:249-250`). The persona summary
type is already clean and is untouched.

### 3.2 runtime.toml keeper-assignment table + parser

`runtime.toml` gains a keeper→runtime assignment. Today the parser
(`runtime_toml.ml`) reads only "layers 1-3 plus `[runtime].default`" and reserves
the top-level namespaces `providers`, `models`, `runtime` (the routing
namespaces `system`, `routes`, etc. are dropped, RFC-0206 §2). There is **no**
keeper-assignment namespace today; this RFC adds one.

The assignment maps each keeper name to a runtime id (an opaque token that must
resolve to a materialized runtime, i.e. one of the binding keys the TOML
declares). A keeper with no entry falls back to `[runtime].default` — a
documented default, **not** a silent substitution (RFC-0001, RFC-0206 §2.1).

The concrete table *shape* (a `[keeper_assignment]` table vs. a
`[[keeper]]` array vs. an `assignment` key under `[runtime]`) is proposed below
but **the as-built form is fixed in the implementation PR**, since the parallel
implementation session owns the parser. Proposed shape, to be confirmed:

```toml
# runtime.toml
[runtime]
default = "<opaque-runtime-id>"

# keeper → runtime assignment (one SSOT)
[keeper_assignment]
echo    = "<opaque-runtime-id>"
analyst = "<opaque-runtime-id>"
```

The id values are opaque tokens. Whether the id remains the legacy
`"provider.model"` string for one transition window, or moves to a separately
declared `[runtime].<name>` token immediately, is an implementation decision
(§7 staging); either way masc must not parse it.

### 3.3 Redirect `runtime_id_of_meta` to the assignment table

`runtime_id_of_meta` resolves a keeper's runtime from the `runtime.toml`
keeper-assignment table instead of `keeper_profile_defaults.model`:

- assignment has an entry for `meta.name` → that opaque id;
- otherwise → `[runtime].default` (`Runtime.get_default_runtime_id ()`), not a
  silent substitution.

The duplicate definition (§1.3) collapses to one. The reconcile change-detector
and the dashboard/operator status override (which RFC-0207 §3 kept reading from
the same source as the dispatcher) read the same assignment table, so they
cannot disagree — one surface, no reconcile storm (§4).

### 3.4 Opaque id at the seam

`Runtime.t.id` and `get_runtime_by_id` are treated by masc as opaque. The
resolution of an id into `provider`/`model`/`provider_config` is owned by the
OAS adapter (`runtime_adapter` / `agent_sdk`). The format change from
`"provider.model"` to an opaque token (RFC-0206 supersede, §9) is the
implementation's call on timing; the invariant this RFC fixes is *masc must not
read provider/model out of an id*, independent of the exact token format.

### Validation (fail-fast at dispatch, RFC-0206 §2.1)

An assignment id is validated at dispatch, not startup: the driver calls
`Runtime.get_runtime_by_id id`; an id that does not resolve to a materialized
runtime returns `None`, and the driver returns an `Agent_sdk.Error.Internal`
rather than silently substituting the default. A typo in the assignment table
surfaces as a loud dispatch error on that keeper's first turn. This is the same
fail-fast contract RFC-0207 §3 established; only the source of the id changes.

## 4. Why one surface, and why no reconcile storm

RFC-0207 §2 (lines 58-63) rejected adding a second per-keeper surface
(`[llm_runtime.<keeper>]` alongside the persona `model` field) because the
dispatcher would read one surface and the reconcile/status layer the other, with
opposite precedence — flagging `runtime` drift on every ~30 s reconcile sweep, a
re-sync write storm (cf. #10061).

That argument is conditioned on **two surfaces coexisting**. This RFC does not
add a second surface alongside the persona field; it **removes the persona
`model` field entirely** and makes `runtime.toml` the sole surface. The
load-bearing precondition is total removal of persona-`model` — if the persona
field were left in place as a fallback, two surfaces would coexist and the
RFC-0207 §2 storm argument would re-apply. With one surface, the dispatcher and
the reconcile/status layer read the same assignment table; the change-detector
(`runtime_changed`) is false unless the assignment table actually changed. No
storm.

This is why RFC-0211 supersedes RFC-0207 §2 rather than coexisting with it: the
two designs cannot both hold. §2 says the single surface is the persona field;
this RFC says the single surface is `runtime.toml`. Choosing this RFC requires
deleting the persona field.

## 5. Why opaque id

**For (opaque token):**
- The masc core becomes structurally unable to read provider/model from an id; a
  consumer that splits the id on `.` no longer compiles against a meaningful
  parse, removing a class of boundary violations at the type/usage level.
- It aligns the runtime seam with the openclaw lane-label rule (no readable
  provider field in a core label) — one consistent boundary across the system.
- It localises provider knowledge to OAS, the one component that legitimately
  needs real provider/model names.

**Against / cost:**
- An opaque id is not human-legible in logs and dashboards without a lookup
  (`id → display`) through the runtime table. Operator-facing surfaces must
  resolve the id for display, adding an indirection that the `"provider.model"`
  string gave for free.
- The transition has a window where some surfaces still treat the id as
  `"provider.model"`; mixing the two interpretations during migration is a
  correctness risk (§7 stages it explicitly, one interpretation at a time).
- Equality-on-opaque-token loses the incidental ability to group runtimes by
  provider prefix; any such grouping must move to OAS or to an explicit field.

The format change from `"provider.model"` is RFC-0206's supersede (§9); RFC-0211
fixes the invariant (masc does not parse the id) and defers the exact token
encoding to the implementation.

## 6. Dead duplicate: `runtime_id_of_meta`

On SHA `8ed74a37c9`, `keeper_meta_contract.ml` defines `runtime_id_of_meta`
twice (lines 648 and 750). The `.mli` exports one symbol; OCaml binds the later
(750), and line 648 has zero call sites in the file (a grep of the 649-749 window
finds no call). Line 648 is dead, shadowed, and defaults via a *different* source
(`Keeper_config.default_runtime_id ()`) than the live 750
(`Runtime.get_default_runtime_id ()`).

This is a broken-main merge artifact (the file's recent history includes
boundary-cut and remnant-clearing merges, #19797/#19806/#19729). The
implementation removes line 648 as part of §3.3 (the surviving definition is
rewritten to read the assignment table). Recorded here so the removal is not
mistaken for a behaviour change: the live behaviour is line 750's; deleting 648
is dead-code removal.

## 7. Migration

Staged so that exactly one id interpretation and one assignment source are live
at each step. Fail-fast (RFC-0206 §2.1) is preserved throughout.

1. **Add the `runtime.toml` keeper-assignment parser** (new namespace in
   `runtime_toml.ml`). Parse-only; nothing reads it yet. Bad/unresolvable ids are
   a load-time `Error` for the assignment table, consistent with the existing
   layer-1-3 validation.
2. **Redirect `runtime_id_of_meta`** to read the assignment table (§3.3),
   defaulting to `[runtime].default`. Remove the dead duplicate (§6). At this
   step both the persona `model` field and the assignment table can resolve an
   id; the assignment table takes precedence, and the persona field is read by
   nothing once the reader is removed.
3. **Remove the persona-JSON model reader and the
   `keeper_profile_defaults.model` field** (§3.1). After this step the persona
   field is gone and `runtime.toml` is the sole surface (§4 precondition
   satisfied).
4. **Make the id opaque at the seam** (§3.4): keep the format change isolated to
   the OAS adapter, so masc consumers never parse the id. The exact token
   encoding (legacy `"provider.model"` retained vs. new opaque token) is fixed
   here by the implementation.

The consumer surface for step 2/3 is wide: `runtime_id_of_meta` is referenced by
32 files on SHA `8ed74a37c9`, spanning the keeper (26), dashboard (3), operator
(2), and the tool-call layer (1). Most are read-only consumers of the resolved
id; they are unaffected by the source change as long as the resolved id and its
fail-fast contract are unchanged. (RFC-0207's "12 callers" figure was a subset;
the measured caller set is 32 files.)

## 8. Tests

- assignment table drives `runtime_id_of_meta` (an assigned keeper resolves to
  its assigned id, not the default);
- an unassigned keeper falls to `[runtime].default`;
- an assignment id that does not resolve to a materialized runtime makes the
  driver fail fast (`Internal`), not silently substitute the default
  (RFC-0001 regression guard);
- a persona with no `model` field (the new shape) materializes and routes
  correctly via the assignment table;
- the reconcile change-detector is false when only the persona file changes and
  the assignment table is unchanged (no-storm guard for §4).

Whole-program `dune build @check` and `dune build .` must be green. The
fail-fast test is the load-bearing one: it proves the assignment source did not
re-introduce a silent default.

## 9. Supersede relationships

- **RFC-0207 §2** ("There is only one surface: the persona `model` field") is
  superseded. The single surface is `runtime.toml`'s keeper-assignment table, not
  the persona field; the persona is model/runtime-agnostic (§2.1). RFC-0207's
  per-keeper routing *mechanism* (Part A: dispatcher honours a per-keeper
  selection, fail-fast on unresolved id, §3-§4) is **kept** — only the source the
  mechanism reads changes. RFC-0207 §6 (Part B, ordered failover) is out of scope
  and unchanged.
- **RFC-0206** binding-key id format (`id = "provider.model"`) is superseded in
  intent: the id is opaque to masc (§2.2, §5), parsed only by OAS. RFC-0206's
  single-binding `Runtime` model, fail-fast load (§2.1), and "code does not know
  provider/model names" principle are kept and strengthened by this RFC.

RFC-0207 is only partially superseded (Part A stands); its `superseded_by` is not
flipped wholesale. The §2-specific supersede is recorded in this RFC's frontmatter
and in this section.

## 10. Open items (implementation-dependent — not asserted here)

- **As-built keeper-assignment TOML shape.** The §3.2 `[keeper_assignment]` shape
  is a proposal. The parallel implementation session owns the parser; the
  concrete table form (table vs. array vs. nested key) and key naming are fixed in
  the implementation PR, not here.
- **Opaque id encoding and transition window.** Whether the id stays the legacy
  `"provider.model"` string for one window or moves to a new opaque token
  immediately (§3.4, §7 step 4) is an implementation decision. This RFC fixes the
  invariant (masc does not parse the id), not the encoding.
- **OAS de-anonymization scope.** OAS is the sole parser and must know real
  provider/model names; any anonymized provider labels inside the OAS parser are a
  separate cleanup, scoped by an OAS change map, not by this RFC.

## 11. Risks

- **R1 (two-surface fallback re-opens the storm):** if step 3 (persona-`model`
  removal) is skipped or partially done, the persona field and the assignment
  table coexist and the RFC-0207 §2 reconcile storm re-applies (§4). Total
  removal is the load-bearing precondition; do not leave the persona field as a
  fallback.
- **R2 (mixed id interpretation):** during the format transition, a surface that
  still treats the id as `"provider.model"` while another treats it as opaque is a
  correctness hazard. §7 stages one interpretation at a time; do not interleave.
- **R3 (silent-default regression):** the assignment-table fallback must remain a
  documented `[runtime].default`, never a silent substitution (RFC-0001). The §8
  fail-fast test guards this; do not weaken it to accept a default on an
  unresolved assignment id.
- **R4 (parallel conflict):** the implementation runs in a separate worktree
  editing `lib/`. This RFC touches `docs/rfc/` only. The two must not edit the
  same files; the as-built shape (§10) flows from the implementation PR back into
  this RFC, not the other way.
- **R5 (frozen operator seam):** the exhaustion/blocker_class strings
  (`keeper_meta_contract`, RFC-0206 §5) that operator dashboards parse are
  unaffected by this change and must stay frozen; the id is not part of that seam,
  but display surfaces that show the id must resolve an opaque id to a label
  rather than print the raw token if legibility is required.
