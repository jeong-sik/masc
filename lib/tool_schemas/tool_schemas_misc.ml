(** Tool schemas for Tool_misc — separated to break Config dependency cycle *)

open Masc_domain

(** Issue #8592: hand-mirrored from [Dashboard.valid_scope_strings].
    Cycle constraint — Tool_schemas_misc is upstream of Dashboard.
    The test [test_types.ml :: dashboard_scope_ssot] asserts this
    mirror stays in sync with the SSOT so adding a 3rd scope
    constructor fails compilation in [scope_to_string] AND fails the
    test here, instead of silently dropping from the JSON Schema. *)
let dashboard_scope_enum_strings = [ "all"; "current" ]

(** Issue #8493: [masc_config] category filter strings mirror
    [Env_config_snapshot.valid_config_category_strings]. This library
    depends only on [masc_types], so it cannot depend on [masc_config]
    directly without reintroducing the cycle this split avoids. The
    sync test in [test/test_types.ml :: config_category_ssot] keeps this
    mirror aligned with the producer-side SSOT. *)
let config_category_enum_strings =
  [ "server"
  ; "auth"
  ; "transport"
  ; "storage"
  ; "runtime"
  ; "rate_limiting"
  ; "inference"
  ; "autonomy"
  ; "level2"
  ; "dashboard"
  ; "economy"
  ; "governance"
  ; "channel"
  ; "process"
  ; "worker"
  ; "web_search"
  ; "session"
  ]
;;

(* [schemas] is the full generated misc schema set, including the
   descriptor-backed web tools (masc_web_search / masc_web_fetch).
   Web tools must stay in this list because it feeds
   [Config.raw_all_tool_schemas] — the substrate's "all tools that exist"
   set, which is the source for both (a) the keeper progressive-disclosure
   universe (Keeper_tool_dispatch_runtime.inject_masc_schemas) and (b) the
   public MCP surface. Public exclusion is the job of
   [Tool_catalog.public_mcp_surface_tools] / [is_public_mcp] (web tools are
   absent from that allowlist), NOT of this inventory. PR #19864 filtered web
   tools out here as a "keeper-only backend" optimisation; that excluded them
   from the keeper universe too, so the descriptor bundle never registered
   WebSearch/WebFetch while [effective_core_tools] still injected the public
   names every turn — every keeper turn logged "AllowList pruned ... WebSearch,
   WebFetch". The exclusion belonged on the public-surface layer, not the raw
   inventory. *)
let schemas : tool_schema list = Tool_descriptors_gen.schemas
