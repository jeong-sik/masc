# RFC-OAS-036: Model catalog overlay and alias-canonicalized provider lookup

- Status: Implemented (this PR)
- Date: 2026-07-15
- Related: RFC-OAS-034 (endpoint/capability boundary), masc RFC-0342 (D1), masc#24528

## Problem

`Model_catalog` supported exactly two catalog sources: the build-time embedded
`models.toml`, and a whole-catalog replacement installed with `set_global`.
A deployment that needs even one extra row — a provider-scoped row for a
locally-served model, a coding-plan endpoint alias — had to fork the entire
catalog and re-install it, which:

- masks every upstream row behind a copy that goes stale on every release
  (observed 2026-07-15: a 103-row fork from three schema generations back
  shadowed the current 171-row embedded catalog and took a whole fleet's boot
  gate down),
- pushes deployment-specific rows upstream instead (`provider_name =
  "runpod_rtxa6000"` in the shared `models.toml`), violating RFC-OAS-034's
  serving-contract namespace rule from the other direction.

Separately, capability lookup had two alias semantics. The binding-registry
path (`Provider_runtime_binding.provider_id_of_provider_config`) resolves a
provider label through declared aliases before use; the capability path
(`Provider_config.capabilities_for_config_model` →
`Model_catalog.lookup_for_provider`) compared the raw label only. The same
config could resolve capabilities on one path and miss on the other.

## Change

1. **`Model_catalog.merge ~base ~overlay`** — row-level merge. Identity is
   what lookup keys on: `(provider_name, id_prefix)` for model rows (a bare
   row and a provider-scoped row with the same `id_prefix` are distinct),
   `id` for provider entries, compared with lookup normalization
   (trim + ASCII case-fold). Overlay rows replace same-identity base rows;
   rows unique to either side are kept.

2. **`Model_catalog.set_global_overlay`** — installs a deployment overlay.
   `global ()` now resolves: `set_global` replacement (unchanged, still wins
   outright — tests and explicit full-catalog callers keep their semantics) →
   embedded ⊕ overlay (cached, invalidated on overlay change) → embedded.
   `clear_global` also drops the overlay and the merged cache.

3. **Alias-canonicalized `lookup_for_provider`** — when no row matches the
   requested provider name verbatim, the name is canonicalized once through
   the catalog's own `[[providers]]` entries (`id` or `aliases` containing the
   requested name) and the exact lookup is retried with that entry's `id`.
   A verbatim row always wins. This closes the two-path asymmetry and lets an
   overlay express a deployment alias as data: a provider entry
   `id = "vllm-qwen3-mtp"` with `aliases = ["runpod_mtp"]` and
   `capabilities_base = "openai_compat"` routes the deployment label to the
   upstream serving-contract rows without duplicating capability data.
   `capabilities_base` is required in practice for deployment-only ids:
   `Provider_registry.default` resolves an absent `capabilities_base` to the
   entry `id` (`lib/llm_provider/provider_registry.ml`), and a label unknown
   to `Capabilities.capabilities_for_provider_label` raises `Invalid_argument`
   at registry construction — before any request is served. Overlay authors
   must pick a label the capability table already resolves (a
   `Provider_kind.to_string` value or a declared alias such as
   `"openai_chat"`).

No lookup behavior changes for names that already resolved: the alias pass
only runs where the previous implementation returned `None`.

## Consumer wiring (out of scope here)

Downstream runtimes (masc) resolve an overlay file (e.g. config-root
`oas-models-overlay.toml`) and call `set_global_overlay` during bootstrap,
replacing their full-file `oas-models.toml` pickup. Tracked in masc RFC-0342
(D1 landing plan and the deployment-fork removal target).

## Tests

`test/test_model_catalog_overlay.ml`: merge precedence per key kind, bare vs
provider-scoped key distinctness, provider-entry replacement, embedded ⊕
overlay composition through `global ()`, `set_global` precedence,
`clear_global` reset, alias resolution, and verbatim-over-alias precedence.
