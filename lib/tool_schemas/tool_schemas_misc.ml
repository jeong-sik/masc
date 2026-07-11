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

let surface_audit_schema ~remote =
  { name = "masc_surface_audit"
  ; description =
      (if remote
       then
         "Read dashboard surface readiness, exposure policy, and evidence references. Use this before pointing operators to an experimental surface."
       else
         "Read dashboard surface readiness, exposure policy, and evidence references. Use this to decide whether a surface belongs in main navigation, Lab, or should stay hidden.")
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; "properties", `Assoc [ "surface_id", `Assoc [ "type", `String "string" ] ]
        ; "additionalProperties", `Bool false
        ]
  }
;;

(* [schemas] is the generated public misc schema set. Descriptor-owned web backend
   names (masc_web_search / masc_web_fetch) are intentionally not generated
   here; [Config.raw_all_tool_schemas] projects them from
   [Keeper_tool_descriptor.public_descriptors] so the keeper universe still
   knows they exist without duplicating their schema ownership. *)
let schemas : tool_schema list = Tool_descriptors_gen.schemas
