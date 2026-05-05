# RFC-0031 — Three-Tier Config Disclosure (Basic / Advanced / Godmode)

- **Status**: Draft
- **Author**: yousleepwhen (vincent)
- **Created**: 2026-05-05
- **Audit reference**: `docs/audit-responses/2026-05-05-integrated-improvement-design.md` §2-3, §3-1
- **Related**: RFC-0030 (`masc create` CLI), RFC-0027 (typed cascade)

## 1. Problem

Today's TOML schema (keeper persona, cascade profile, env knobs) treats
all fields as equally visible. The 5 hand-written persona TOMLs are
already minimal — `sangsu.toml` is 8 lines including the `[keeper]`
header — but the *parseable surface* is much wider:

- `keeper_types_profile.ml` lists ~40 fields the parser accepts,
  including `sandbox_profile`, `network_mode`, `keepalive_interval_sec`,
  `git_identity_mode`, `keeper_assignable`, `max_context_tokens`, etc.
- `cascade_toml_materializer.ml:356` lists ~20 valid cascade fields
  including `sticky_ttl_ms`, `latency_baseline_ms`,
  `rate_limit_recency_window_s`, `server_error_decay_base`, etc.
- `cascade_client_capacity.ml` exposes 6+ env knobs around capacity
  layering.

The audit framed this as operator confusion ("operator가 36개 keeper를
관리할 수 없다"). At today's 5-persona scale operators rarely touch
advanced fields, but the *discoverability* problem is real: an
operator reading a `cascade_toml_materializer.ml` error sees 20 valid
field names with no hint about which 3 they actually need.

The goal is **progressive disclosure**: show the small set 95% of
operators ever touch, gate the rest behind explicit opt-in.

## 2. Goal

Three disclosure tiers, with metadata at the field level driving the
behaviour:

- **Basic**: ~6 fields per asset (persona / cascade / keeper). Default
  CLI output, default validation hint set.
- **Advanced**: ~20 fields. Visible only with `--advanced` flag or
  explicit opt-in env var.
- **Godmode**: 50+ internal fields (concurrency tunables, scheduler
  hooks, atomic semantics). Visible only with `--godmode` and a
  documented break-glass note.

This is purely a *presentation* layer. The underlying schema doesn't
change; existing TOML files keep working unchanged.

## 3. Non-goals

- Removing any field. The audit's §4 listed "dead fields" but most
  of those were verified live in audit-response §10. Disclosure
  tiering is orthogonal to dead-field cleanup (which has its own
  cleanup track, e.g. #13091, #13076).
- Schema versioning. Fields don't move between tiers per release; if
  a field's audience genuinely changes, that's a separate decision.
- Locking advanced fields away from hand-editing. Operators can still
  edit any field in the TOML directly; the tiering only affects what
  the CLI / MCP tool *generates* and *suggests*.
- Changing the wire format. JSON output for advanced tools includes
  all tiers; the tier metadata is a sibling field.

## 4. Design

### 4.1 Field-tier metadata

Each schema-bearing module (currently `keeper_types_profile.ml`,
`cascade_toml_materializer.ml`, `env_config_core.ml`) gains a
companion `*_tiers.ml` file with a single mapping:

```ocaml
(* lib/keeper/keeper_types_profile_tiers.ml *)
type tier = Basic | Advanced | Godmode

let field_tier : string -> tier = function
  | "name" | "persona" | "tier" | "tools" | "work_source"
  | "git_identity_mode" -> Basic
  | "sandbox_profile" | "network_mode" | "keepalive_interval_sec"
  | "max_retries" | "max_context_tokens"
  | "keeper_assignable" -> Advanced
  | "holder_mutex_timeout_sec" | "fiber_cancel_hook"
  | "atomic_semantics" | "cas_retry_limit"
  | _ -> Godmode
```

The `_` fallthrough case is intentional — any new field defaults to
Godmode (most conservative). Promoting a field to Basic requires an
explicit entry, which forces a review of the field's audience.

### 4.2 CLI surface integration

`masc create persona` (RFC-0030 §4.1) consults `field_tier`:

- Default: only Basic flags are accepted; Advanced/Godmode flags emit
  "did you mean to pass `--advanced`?" hint.
- `--advanced`: Basic + Advanced flags accepted. Godmode hidden.
- `--godmode`: all flags. Prints a break-glass warning header to
  stderr.

The validator runs identically across tiers (the schema doesn't
change); the disclosure logic only affects which fields the CLI
*offers* to set.

### 4.3 Validation hint formatting

When validation fails on a field, the error message includes the
field's tier:

```
error: invalid value for `holder_mutex_timeout_sec` (godmode field)
  hint: this field is normally not set; only override if you have
        a documented reason. Re-run with --godmode to confirm intent.
```

Basic / Advanced errors don't get the heavy hint; the field is
expected to be set.

### 4.4 Documentation generation

`masc help create persona` lists Basic flags inline. `--advanced` adds
the Advanced section. `--godmode` adds the Godmode section with the
break-glass header. This is the audit's "Progressive Disclosure" — the
help text grows with the operator's stated expertise.

The full schema (all tiers) is always available via `masc schema dump
[persona|cascade]`, JSON output. This is for tooling; humans use
the tiered CLI.

### 4.5 No tier on existing TOML files

Existing TOML files don't carry tier markers — operators hand-edit
into any tier and the parser accepts it. Tiering only affects what
the *CLI* generates. This avoids forcing a migration.

## 5. Tests

- `test_field_tier_basic_persona_fields`: assert the 6 named Basic
  fields are tagged Basic.
- `test_field_tier_unknown_defaults_to_godmode`: assert
  `field_tier "made_up_field"` returns Godmode.
- `test_persona_create_rejects_advanced_field_without_flag`: integration
  with RFC-0030 — assert Advanced flag without `--advanced` errors.
- `test_persona_create_accepts_advanced_field_with_flag`: assert
  `--advanced` allows the same flag.
- `test_godmode_emits_break_glass_warning`: assert stderr contains the
  warning when `--godmode` is used.
- `test_validation_error_mentions_field_tier`: assert error message
  for a Godmode field mentions "(godmode field)".

## 6. Performance

The tier lookup is a string match (~7 comparisons for Basic, ~20 for
Advanced, fallthrough for Godmode). Sub-microsecond per call.
Disclosure is per-CLI-invocation, not per-request, so performance is
not a constraint.

## 7. Migration

PR-1: ship `keeper_types_profile_tiers.ml` + lookup. No CLI changes
yet — this just establishes the metadata.

PR-2: wire `masc create persona` (assuming RFC-0030 PR-2.1 is merged)
to consult the tier mapping. Add `--advanced` / `--godmode` flags.

PR-3: same for `masc create cascade`.

PR-4: same for `masc create keeper`.

No data migration. Existing TOML files keep working. Operators who
already hand-edit Advanced fields continue to do so without flag
changes — the tier gate only applies to CLI-driven authoring.

## 8. Open questions

- **Should tiers apply to env vars?** `MASC_KEEPER_*` knobs span all
  three tiers (capacity tuning is Advanced; semaphore wait timeout
  internals are Godmode). RFC-0032 (env unification) is the natural
  home for env tiering. Defer to RFC-0032.
- **Should the dashboard render hide Advanced fields by default?**
  Tempting — the dashboard keeper-detail view shows ~30 fields today.
  But the dashboard audience is mixed (operators + developers), and
  dashboard tier gating is its own feature. Defer.
- **Should we lint TOML files against tier?** i.e. flag a TOML that
  sets only Godmode fields without setting any Basic? Held off — that
  punishes legitimate break-glass cases (debugging, staging clusters).
  The schema already rejects truly invalid TOML; tier is presentation.

## 9. Decision log

- Tier metadata as separate module (not annotation on the original
  type) — chosen so the type module doesn't gain a runtime dependency.
  The cost is one place to update when fields are added; the benefit
  is the type module stays free of UX concerns.
- Godmode fallthrough — chosen over Basic-fallthrough or
  error-on-unknown. Conservative default for new fields, forces
  explicit promotion when an audience is identified.
- No TOML-level tier annotations — chosen to keep TOML files
  hand-editable without operator confusion. The tiering is at the
  *generative* surface, not the *file* surface.
