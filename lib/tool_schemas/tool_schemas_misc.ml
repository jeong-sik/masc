(** Tool schemas for Tool_misc — separated to break Config dependency cycle *)

open Masc_domain

(** Issue #8592: hand-mirrored from [Dashboard.valid_scope_strings].
    Cycle constraint — Tool_schemas_misc is upstream of Dashboard.
    The test [test_types.ml :: dashboard_scope_ssot] asserts this
    mirror stays in sync with the SSOT so adding a 3rd scope
    constructor fails compilation in [scope_to_string] AND fails the
    test here, instead of silently dropping from the JSON Schema. *)
let dashboard_scope_enum_strings = [ "all"; "current" ]

type control_operation =
  | Pause
  | Resume
  | Pause_status

let control_operations = [ Pause; Resume; Pause_status ]

let control_operation_id = function
  | Pause -> "pause"
  | Resume -> "resume"
  | Pause_status -> "pause_status"
;;

let control_schema = function
  | Pause -> Tool_descriptors_gen.masc_pause_schema
  | Resume -> Tool_descriptors_gen.masc_resume_schema
  | Pause_status -> Tool_descriptors_gen.masc_pause_status_schema
;;

let control_schemas = List.map control_schema control_operations

(* [schemas] is the generated public misc schema set. Operator control schemas
   use the dedicated typed projection above so they remain registered without
   entering Config's public/front-door inventory. Descriptor-owned web backend
   names (masc_web_search / masc_web_fetch) are intentionally not generated
   here; [Config.raw_all_tool_schemas] projects them from
   [Keeper_tool_descriptor.public_descriptors] so the keeper universe still
   knows they exist without duplicating their schema ownership. *)
let schemas : tool_schema list = Tool_descriptors_gen.schemas
