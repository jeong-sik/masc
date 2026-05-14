# RFC-0058 Phase 5.7: Generalize doctor modules and MCP config sync

| | |
|---|---|
| Status | Draft |
| Depends-on | RFC-0058 Phase 5.6 (closed 2026-05-11), RFC-0058 §2.4 |
| Related | RFC-0072 (provider_adapter sublib extraction — separate host-side split) |
| Scope | OCaml doctor/bootstrap modules — remove single-product knowledge |

## 1. Problem

Phase 5.1–5.6 erased the closed `provider_id` variant from dispatch sites
and removed `match provider_cfg.kind` from the keeper layer. The §1
inventory in the parent Phase-5 RFC focused on cascade/dispatch leakage
and did not cover three modules that grew product-specific by accretion:

| File | LoC | `codex` hits | Other product hits | Shape |
|------|-----|--------------|--------------------|-------|
| `lib/codex_mcp_config_doctor.ml` | 433 | 58 | 0 | Entire module named after a product; diagnoses + repairs Codex CLI's `~/.codex/config.toml` MCP entry pointing at MASC. |
| `lib/auth_doctor.ml` | 855 | 64 | gemini: 2 | Doctor logic with explicit Codex branches (auth provider detection, login probe, header-sync repair) and minor Gemini coverage. |
| `lib/server/server_runtime_bootstrap.ml` | 1909 | 21 | gemini: 2 | Boot-time helpers that synthesize a Codex MCP config block (`codex_mcp_headers_line`, `sync_codex_mcp_auth_header_content`). |

(Measurements: `rg -c <product>` against `origin/main` `f1bcdad26e` on
2026-05-14.)

These three files survive Phase 5.6's keeper-layer cleanup precisely
because they live *outside* the dispatch path. They are not "code that
chooses a provider by variant"; they are **code that knows how a
specific tool's configuration file is shaped**. The closed-variant
sweep does not reach them.

But the architectural invariant from RFC-0072 §2 still applies:
*"Provider and Model are opaque alias. No vendor name is 1st-class."*
A doctor module whose **filename** is a product name is the loudest
possible violation.

### 1.1 Why this is not a workaround

The CLAUDE.md workaround rejection bar §3 ("N-of-M abstraction
absence") is exactly the trap here. Phase 5.6 closed 8 keeper sites
and called it done. The doctor modules carry 143 lines of the same
product knowledge in a different shape. Without an explicit scope
amendment, the next product-doctor (e.g., `claude_code_mcp_config_doctor.ml`,
`gemini_cli_auth_doctor.ml`) becomes the path of least resistance —
re-establishing the very pattern Phase 5 sought to eliminate.

### 1.2 What MASC core should *not* know

A user-installed CLI tool's config file format (where it lives, what
TOML key holds an MCP block, what auth header convention it uses)
is a property of *that tool*, not of MASC. MASC's job is to expose
its MCP endpoint correctly; it should not ship a `codex_mcp_config_doctor`
any more than `git` ships a `vscode_settings_doctor`.

## 2. Goals

- Filename invariant: `rg --files lib/ | rg -i 'codex|claude_code|gemini|kimi|glm|llama|ollama|dashscope'` returns 0 hits *for non-adapter modules*. Adapter modules (`*_adapter.ml`) remain — they legitimately encode wire-format quirks (RFC-0058 §3 Non-Goals).
- Function/binding name invariant: `rg 'val (codex_|claude_code_|gemini_|kimi_|glm_)' lib/ --type ocaml` returns 0 hits outside adapter modules.
- The doctor capabilities that survive are **driven by the same
  declarative source** Phase 5.3 uses (TOML `[providers.<id>]` table,
  extended with `[providers.<id>.mcp_client_config]` and
  `[providers.<id>.auth_doctor]` sub-tables).
- Boot-time bootstrap reads the provider TOML and conditionally
  invokes a generic doctor module, not a hard-coded Codex branch.

## 3. Non-Goals

- Removing the *behaviour* of MCP config sync or auth detection. Users
  who run MASC with Codex CLI still need their `~/.codex/config.toml`
  to point at MASC. The capability survives — only its packaging
  changes.
- Migrating the doctor capability *out of MASC entirely* (i.e., to
  OAS or to per-tool plugins). That is a separate decision tracked in
  §7 Open Questions.
- Adapter modules (`messages_api_adapter.ml`, `kimi_cli_adapter.ml`, etc.)
  — same exemption as RFC-0058 §3.

## 4. Approach

Phased so each PR keeps `main` green.

### Phase 5.7.1 — Inventory and TOML schema extension

- Audit every product mention in the three target files. Produce
  `docs/rfc/RFC-0058-phase-5-7-inventory.csv` with columns:
  `file,line,product_name,leak_class,target_replacement`.
  `leak_class` is one of: `filename`, `function_name`, `tom_key_literal`,
  `header_value_literal`, `path_template`, `branch_condition`.
- Extend `config/cascade.toml` schema:
  - `[providers.<id>.mcp_client_config]` with fields `config_path_template`,
    `config_format` (toml | json | yaml), `mcp_table_key`,
    `header_keys_to_sync = [...]`.
  - `[providers.<id>.auth_doctor]` with fields `auth_kind`
    (api_key | oauth_pkce | none), `login_probe_command`,
    `env_vars_to_check = [...]`.
- Parser + R-rule validator coverage for both sub-tables (RFC-0058 §G4).
- Existing Codex behaviour ships as a `[providers.codex_cli.*]` entry
  in `config/cascade.toml`. Byte-equivalent migration; no runtime
  behaviour change.

### Phase 5.7.2 — Generic MCP config doctor

- New module `lib/mcp_client_config_doctor.ml(+.mli)` that takes a
  `provider_id` string + a `mcp_client_config` record (parsed from TOML
  §5.7.1) and performs the same diagnose/repair operations the current
  `codex_mcp_config_doctor.ml` performs.
- Old `codex_mcp_config_doctor.ml` becomes a *thin alias* that calls
  the generic module with `~provider_id:"codex_cli"`. The alias is
  marked `[@@deprecated "use Mcp_client_config_doctor"]`.
- Caller-site grep: 1 site in `server_runtime_bootstrap.ml`. Migrated
  in the same PR.

### Phase 5.7.3 — Generic auth doctor

- Extract product-agnostic logic from `auth_doctor.ml` into
  `lib/auth_doctor_core.ml(+.mli)` (~600 LoC estimated, the non-branchy
  helpers).
- Product-specific branches collapse to a TOML lookup over
  `[providers.<id>.auth_doctor]`. The `codex`-named functions get
  product-neutral names (`detect_auth_for_provider`,
  `repair_auth_for_provider`).
- Public-API breaking change: callers using
  `Auth_doctor.detect_codex_auth` get `Auth_doctor.detect_for_provider
  ~provider_id:"codex_cli"`. Compilation errors enumerate every call
  site (`rg 'Auth_doctor\.' lib/ bin/`).

### Phase 5.7.4 — Boot-time bootstrap cleanup

- Replace the hard-coded `codex_mcp_headers_line` /
  `sync_codex_mcp_auth_header_content` helpers in
  `server_runtime_bootstrap.ml` with a loop over enabled providers
  that read `[providers.<id>.mcp_client_config]` and call the generic
  doctor.
- Result: `rg 'codex|gemini|kimi|claude_code' lib/server/server_runtime_bootstrap.ml`
  returns 0 OCaml-code hits (config file paths in TOML are fine).

### Phase 5.7.5 — Filename rename and deletion

- `git mv lib/codex_mcp_config_doctor.ml lib/mcp_client_config_doctor.ml`
  (already happened in 5.7.2 if the alias path was taken; this PR
  deletes the alias and updates the last caller).
- Final invariant check: `rg --files lib/ | rg -i 'codex|claude_code|gemini_cli|kimi_cli|glm-coding'`
  returns adapter files only.

## 5. Acceptance Gates

For each Phase 5.7.N PR:

- G1: `rg 'codex|claude_code|gemini|kimi|glm-coding' lib/codex_mcp_config_doctor.ml lib/auth_doctor.ml lib/server/server_runtime_bootstrap.ml -t ocaml | wc -l` shrinks monotonically.
- G2: After 5.7.5, the three target files either no longer exist
  under their product-named identifiers, or contain 0 product-name
  hits in OCaml code (TOML literals in fixtures are excluded).
- G3: `dune build --root .` and `dune test` pass.
- G4: New TOML sub-tables ship with parser + R-rule validator coverage
  (same gate as Phase 5.1).
- G5: Existing operational behaviour is preserved. Specifically:
  - Codex CLI users running `masc doctor` still receive the same
    diagnostic output (verified by snapshot test).
  - The auth header sync at boot still pins the same
    `~/.codex/config.toml` entry (verified by tmpdir integration test).

## 6. Risks

- **User-facing behaviour change**: doctor command outputs are part of
  the user-visible CLI surface. Snapshot test coverage required before
  any rename touches output strings.
- **Migration cliff**: Phase 5.7.3 changes `Auth_doctor` public API.
  Sequence so that the new API ships before the old API removal, with
  one intermediate PR exposing both (one deprecated). Avoids
  breaking downstream callers in a single PR.
- **TOML schema drift**: extending `cascade.toml` with two new
  sub-tables grows the contract. Mitigation: the new sub-tables are
  optional. Providers without them retain "no doctor capability"
  behaviour rather than crashing.
- **Hidden product knowledge**: Phase 5.7 may surface that other
  modules (not in the §1 inventory) also encode product specifics.
  Mitigation: §5.7.1 audit CSV is the canonical scope; new findings
  go into a follow-up RFC, not into this RFC's scope creep.

## 7. Open Questions

1. **Should doctor capability stay in MASC at all?** An alternative
   future is to expose the diagnostic primitives as a generic MCP
   tool that any external doctor program (Codex's own `codex doctor`,
   a hypothetical `claude-code doctor`, etc.) can call. MASC would
   then ship 0 doctor logic. This RFC chooses the smaller migration
   (generalize, keep in core); the larger migration is tracked
   separately.

2. **Should provider TOML own auth-doctor declarations?** Auth
   discovery is partly a property of the provider (where env vars
   live, what login command to run) and partly a property of the
   user's environment. The TOML approach in Phase 5.7.3 puts the
   *capability shape* in TOML but the *runtime probe results* stay
   in process state. This is correct but bears verifying with one
   non-Codex provider (Gemini, currently 2 hits in auth_doctor) at
   Phase 5.7.3 design time.

3. **Naming**: `mcp_client_config_doctor` vs `external_mcp_config_doctor`
   vs `peer_mcp_config_doctor`. RFC-0072 §2 prefers abstract terms.
   `mcp_client_config` is the term that already exists in MCP spec
   prose; this RFC adopts it. Revisit at Phase 5.7.2 implementation
   time if a clearer term emerges.
