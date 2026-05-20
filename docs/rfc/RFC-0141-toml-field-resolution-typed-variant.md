---
rfc: "0141"
title: "TOML Field Resolution Typed Variant for repo_manager + credential subsystem"
status: Active
created: 2026-05-20
updated: 2026-05-21
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0126", "0142", "0148", "0154"]
implementation_prs: [16837, 16887, 16889]
---

## Progress audit (2026-05-21)

Status promoted Draft → Active. PR-1/2/3 of the five-PR phase plan
landed within the §4 cadence; PR-4 and PR-5 remain.

| Phase | PR | Scope | Merged |
|-------|-----|------|--------|
| PR-1 | #16837 | `lib/repo_manager/field_resolution.{ml,mli}` typed extractor + variant tests | 2026-05-19 |
| PR-2 | #16887 | `repo_store.ml:48-67` 4-site migration | 2026-05-19 |
| PR-3 | #16889 | `credential_store.ml:75-94` 4-site migration | 2026-05-19 |
| **PR-4** | (pending) | `credential_materializer.ml` `try … with _` → typed exception matching | not landed |
| **PR-5** | (pending) | silent-failure ratchet regenerate (`error_result_silence` ≥8 drop) | not landed |

### Pending work — PR-4

`lib/repo_manager/credential_materializer.ml` still contains five
bare `try` blocks (lines 68 / 83 / 170 / 213 / 292) that swallow
exceptions with `_ -> default`. The RFC §4 PR-4 prescription is to
convert each to a concrete-exception match (`Unix.Unix_error _ |
Otoml.Parse_error _`) while ensuring `Eio.Cancel.Cancelled`
propagates unchanged. Until PR-4 lands, the typed variant introduced
by PR-1 is not load-bearing on the materializer surface — the
swallow-on-error path is still the dominant failure handling.

### Pending work — PR-5

Silent-failure ratchet (`scripts/silent-failure-ratchet.sh` if
present, otherwise the equivalent in `scripts/audit-*`) has not been
regenerated post-PR-2/3. The §7 acceptance metric —
`error_result_silence` drops by ≥8,
`exception_catchall_swallow` drops by ≥2 — is unverified.

### Related RFC

- **RFC-0142** (cascade_error_classify decomposition, Active 2026-05-21):
  the sister Json_field migration. Same audit cohort.
- **RFC-0148** (Tool_error closed sum, Implemented 2026-05-20),
  **RFC-0154** (System_error_class typed SSOT, Implemented
  2026-05-21): closed-sum variant pattern. PR-4's typed exception
  matching here is the same parse-don't-validate discipline applied
  to the OCaml `exn` boundary.

---

# RFC-0141 — TOML Field Resolution Typed Variant

## 1. Summary

Replace `Otoml.find_result toml … |> function Ok v -> Ok v | Error _ -> Ok default` with a typed `Field_resolution.t` variant that distinguishes *missing field* (legitimate default) from *type mismatch* (schema violation). Targets:

- `lib/repo_manager/repo_store.ml:48-67` (4 sites)
- `lib/repo_manager/credential_store.ml:75-94` (4 sites)
- `lib/repo_manager/credential_materializer.ml` (2 sites, `try … with _ ->` swallow)

Total 10 sites. All in the credential/repo_manager subsystem flagged by CLAUDE.md `<agent_delegation>` for RFC-required PRs.

## 2. Background — what fails today

`Otoml.find_result` returns `Error` for two unrelated reasons:

1. **Field absent** — legitimate, the caller wants the default.
2. **Field present but wrong type** — schema violation; the TOML is corrupt.

Today both collapse into `Ok default`. The audit on 2026-05-20 measured this pattern in:

| Site | Field | Default substituted on type mismatch |
|---|---|---|
| `repo_store.ml:50` | `local_path` (string) | `default_local_path id` |
| `repo_store.ml:55` | `auto_sync` (bool) | `false` |
| `repo_store.ml:60` | `sync_interval` (int) | `Int64.of_int 300` |
| `repo_store.ml:65` | `aliases` (string list) | `[]` |
| `credential_store.ml:75` | `credentials_dir` | `None` |
| `credential_store.ml:80` | `credential_path` | `None` |
| `credential_store.ml:85` | `credential_id` | `None` |
| `credential_store.ml:90` | `secret` | `None` |
| `credential_materializer.ml` | try/with _ | swallowed I/O exception |

If `repositories.toml` declares `local_path = 42` (int instead of string), `repository_of_toml` silently substitutes `default_local_path id` and returns `Ok` — a corrupt repository is *startup-clean*. Same applies to credentials: a malformed credential block becomes an *anonymous credential lookup*, with no diagnostic trace.

Past surface evidence:

- Two PR cycles (#10660 RFC-0008 PR-1 + #12304) shipped credential-adjacent code without cross-reference — root-caused by absence of a typed resolution boundary that would have made the schema invariant explicit. Referenced in `~/me/knowledge/research/2026-04-30-keeper-credential-architecture-state.md` §8.

## 3. Proposal — `Field_resolution.t`

Single helper module `lib/repo_manager/field_resolution.ml(.mli)`:

```ocaml
(** Result of resolving an optional TOML field at a given path. *)
type 'a t =
  | Present of 'a              (** field exists and parsed cleanly *)
  | Missing                    (** field absent — caller may substitute default *)
  | Type_mismatch of {
      path: string list;
      expected: string;        (** "string" | "int" | "bool" | "string list" | … *)
      message: string;         (** Otoml's diagnostic text *)
    }

val resolve_string : Otoml.t -> string list -> string t
val resolve_bool   : Otoml.t -> string list -> bool t
val resolve_int    : Otoml.t -> string list -> int t
val resolve_strings: Otoml.t -> string list -> string list t

(** [or_default ~default r] substitutes [default] for [Missing] only;
    propagates [Type_mismatch] as [Error]. *)
val or_default : default:'a -> 'a t -> ('a, string) result

(** [require r] treats both [Missing] and [Type_mismatch] as [Error]. *)
val require : 'a t -> ('a, string) result
```

Call-site shape after migration:

```ocaml
let* local_path =
  Field_resolution.(resolve_string toml (path "local_path")
                    |> or_default ~default:(default_local_path id))
in
```

The `or_default` helper renders the schema-violation case loud: caller still sees `Error msg`, and the existing `Result.bind`/`let*` chain in `repository_of_toml` propagates it to the caller — `load_all` already collects per-repository errors, so the corrupt-config repo simply doesn't get loaded.

## 4. Migration steps

1. **PR-1** — add `lib/repo_manager/field_resolution.ml(.mli)` + unit tests covering all four variants and both `or_default` / `require` semantics. No call-site change.
2. **PR-2** — migrate `repo_store.ml:48-67` (4 sites). Add round-trip test covering type-mismatch detection (TOML with wrong-type field → `Error` propagated).
3. **PR-3** — migrate `credential_store.ml:75-94` (4 sites). Same test discipline.
4. **PR-4** — replace `credential_materializer.ml` `try … with _` with concrete exception matching (`Unix.Unix_error _ | Otoml.Parse_error _`). `Eio.Cancel.Cancelled` must propagate.
5. **PR-5** — silent-failure ratchet regenerate (`error_result_silence` drops by ~10).

Each PR is self-contained, builds clean, and lints clean. PR-3 + PR-4 stack on PR-1 only (not on each other).

## 5. Compatibility

- TOMLs that are valid today remain valid: `Field_resolution.or_default` reproduces today's behavior for `Missing`.
- TOMLs that were *silently corrupt* today (wrong-typed fields) become *startup errors*. This is the intended behavior change. Affected operators must fix their config.
- No on-wire / API surface change.
- `credential_materializer.ml` exception migration may surface previously-swallowed `Unix_error` cases — these were already broken at runtime but invisible; now they fail loud at the credential boundary.

## 6. Non-goals

- Wholesale `Otoml` replacement.
- Generic `'k -> 'v t` map; the helper is intentionally tied to TOML-shaped paths.
- Other subsystems' Otoml usage (e.g. `cascade_decl/`). Those are tracked separately in RFC-0142 / future RFCs.

## 7. Test plan

| Phase | Test |
|---|---|
| PR-1 | Unit test: each variant constructor, `or_default` Missing → default, `or_default` Type_mismatch → Error, `require` Missing/Type_mismatch → Error |
| PR-2 | `repositories.toml` with `local_path = 42` (int) → `repository_of_toml` returns `Error` naming the path. Existing happy-path tests must still pass. |
| PR-3 | `credentials.toml` with wrong-typed `credential_path` → `Error`. Existing keeper credential lookup test must still pass. |
| PR-4 | `credential_materializer` against a mocked `Unix_error` → caller sees typed `Error`. `Eio.Cancel.Cancelled` injected → propagates (not swallowed). |
| PR-5 | `silent-failure-ratchet.sh` baseline regenerate: `error_result_silence` drops by ≥8, `exception_catchall_swallow` drops by ≥2. |

## 8. RFC-0088 conformance

- This RFC does **not** add telemetry-as-fix counters (§3.1 anti-pattern).
- This RFC does **not** introduce a string-substring classifier (§3.2 anti-pattern).
- This RFC explicitly closes 10 sites in one phased migration; no N-of-M anti-pattern (§3.3) because all 10 sites share a single helper.
- This RFC does **not** add cap/cooldown/dedup/repair (§3.4 anti-pattern); behavior change is "fail at write/read with typed error".

## 9. Open questions

1. Should `Type_mismatch` carry the offending value for diagnostic logs, or only the path + expected type? Carrying the value risks logging credentials on credential_store paths. Tentative answer: path + expected only; value omitted.
2. Should PR-4 expand to `lib/keeper/credential_*` modules in the same PR, or defer? Defer — those have their own audit pending, and bundling makes the PR's blast radius hard to bound.
