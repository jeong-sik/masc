(** Parse one model-authored plan request into a validated
    {!Keeper_tool_plan.t}.

    The JSON grammar mirrors the composition fence grammar in [SKILL.md]: a
    plan is a list of nodes, each naming a canonical tool, optional [after]
    edges, and either fixed [args] as an object or an [input] template whose values are literals, typed references
    into an earlier node's declared composable output, objects, or arrays.
    Everything semantic (unknown tools, unbound references, cycles,
    opaque-output references, pointer/schema mismatches) is rejected by
    {!Keeper_tool_plan.create}; this module owns only the JSON shape. *)

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
  | Template_duplicate_field of
      { kind : string
      ; field : string
      }
  | Template_unknown_field of
      { kind : string
      ; field : string
      }

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
  | Duplicate_request_field of { field : string }
  | Node_duplicate_field of
      { index : int
      ; field : string
      }
  | Request_invalid_field of { field : string; found : string }
  | Export_invalid_field of { index : int; field : string; found : string }
  | Export_template_error of { index : int; error : template_error }
  | Plan_rejected of Keeper_tool_plan.error

type encode_error = Unsubstituted_param of { name : string }

val template_of_json : Yojson.Safe.t -> (Keeper_tool_plan.Json_template.t, template_error) result
val template_to_yojson : Keeper_tool_plan.Json_template.t -> (Yojson.Safe.t, encode_error) result
(** The public template grammar. [Param] remains rejected in both directions. *)

val input_schema : Yojson.Safe.t
(** Canonical model-visible schema for the JSON grammar parsed by
    {!plan_of_json}. The nested template shapes are advertised here; semantic
    validation remains owned by {!Keeper_tool_plan.create}. Optional [exports]
    select named node-output pointers; [branch_failure_policy] is explicit
    [fail_fast] or [continue_independent]. *)

val error_message : error -> string
val error_to_json : error -> Yojson.Safe.t

val to_yojson
  :  Keeper_tool_plan.t
  -> (Yojson.Safe.t, encode_error) result
(** Encode a validated, parameter-free plan. Ordinary nodes round-trip through
    the public grammar. Native compiled nodes additionally preserve their exact
    operand and declared child plan (including its private parameter leaves);
    the public parser rejects this private metadata.
    Owned drafts recompile the original recipe and compare this evidence;
    decoding metadata never grants a compiler or execution capability. *)

val contracts_to_yojson : Keeper_tool_plan.t -> (Yojson.Safe.t, encode_error) result
(** Canonical per-node route/input/output contracts as literal JSON strings.
    Compiled routes include all bound child contracts recursively. Schema
    property names cannot be mistaken for execution artifact references. *)

(** Canonical tool names a plan node may reference as a producer: descriptors
    that declare a composable JSON output. Used to make rejection results
    instructive. *)
val composable_tool_names : descriptors:Keeper_tool_descriptor.t list -> string list

type request_shape = private
  { node_jsons : Yojson.Safe.t list
  ; exports : Keeper_tool_plan.export list
  ; branch_failure_policy : Keeper_tool_plan.branch_failure_policy
  }

val shape_of_json : Yojson.Safe.t -> (request_shape, error) result
(** Decode the closed outer grammar without resolving node authority. Nested
    composition compilation reuses this parser and the ordinary node parser;
    it must still validate the final expanded graph through [Plan.create]. *)

val node_of_json : index:int -> Yojson.Safe.t -> (Keeper_tool_plan.node, error) result
(** Fixed [args] objects normalize to the existing literal input AST. An
    ordinary node may omit both forms for empty arguments, but supplying both
    is rejected. Encoding always emits the canonical tagged [input] form. *)

val plan_of_json
  :  descriptors:Keeper_tool_descriptor.t list
  -> Yojson.Safe.t
  -> (Keeper_tool_plan.t, error) result
