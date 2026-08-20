(** Parse one model-authored plan request into a validated
    {!Keeper_tool_plan.t}.

    The JSON grammar mirrors the operator catalog grammar in
    tool-compositions.toml: a plan is a list of nodes, each naming a canonical
    tool, optional [after] edges, and an input template whose values are
    literals, typed references into an earlier node's declared composable
    output, objects, or arrays. Everything semantic (unknown tools, unbound
    references, cycles, opaque-output references, pointer/schema mismatches)
    is rejected by {!Keeper_tool_plan.create}; this module owns only the JSON
    shape. *)

type template_error =
  | Template_not_an_object of { found : string }
  | Template_missing_kind
  | Template_unknown_kind of string
  | Template_missing_field of
      { kind : string
      ; field : string
      }
  | Template_invalid_field of
      { kind : string
      ; field : string
      ; found : string
      }
  | Template_invalid_pointer of { pointer : string }
  | Template_duplicate_object_field of string

type error =
  | Request_not_an_object of { found : string }
  | Missing_nodes
  | Nodes_not_an_array of { found : string }
  | Node_not_an_object of
      { index : int
      ; found : string
      }
  | Node_missing_field of
      { index : int
      ; field : string
      }
  | Node_invalid_field of
      { index : int
      ; field : string
      ; found : string
      }
  | Node_empty_id of { index : int }
  | Node_template_error of
      { index : int
      ; error : template_error
      }
  | Unknown_request_field of { field : string }
  | Plan_rejected of Keeper_tool_plan.error

val error_message : error -> string
val error_to_json : error -> Yojson.Safe.t

(** Canonical tool names a plan node may reference as a producer: descriptors
    that declare a composable JSON output. Used to make rejection results
    instructive. *)
val composable_tool_names : descriptors:Keeper_tool_descriptor.t list -> string list

val plan_of_json
  :  descriptors:Keeper_tool_descriptor.t list
  -> Yojson.Safe.t
  -> (Keeper_tool_plan.t, error) result
