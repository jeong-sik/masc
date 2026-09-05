(** Typed, validated dataflow plan for one Keeper tool-composition unit.

    Display groups remain discovery metadata. Execution dependencies come only
    from explicit [after] edges and typed JSON output references. *)

module Node_id : sig
  type t = private string

  type error = Empty

  val make : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Json_pointer : sig
  type t = private string list

  type syntax_error =
    | Missing_initial_slash
    | Dangling_escape of { segment : string }
    | Invalid_escape of
        { segment : string
        ; found : char
        }

  type resolution_error =
    | Missing_object_field of string
    | Ambiguous_object_field of string
    | Invalid_array_index of string
    | Array_index_out_of_bounds of int
    | Expected_container of string

  type schema_error =
    | Missing_properties of string
    | Missing_property_schema of string
    | Ambiguous_property_schema of string
    | Missing_items_schema of string
    | Expected_schema_container of string

  val root : t
  val of_string : string -> (t, syntax_error) result
  val segments : t -> string list
  val to_string : t -> string
  (** Canonical RFC 6901 spelling. *)
  val resolve : t -> Yojson.Safe.t -> (Yojson.Safe.t, resolution_error) result
end

module Json_template : sig
  type t = private
    | Literal of Yojson.Safe.t
    | Output of
        { node_id : Node_id.t
        ; pointer : Json_pointer.t
        }
    | Param of { name : string }
        (** A declared composition parameter, bound per invocation. A plan may
            hold [Param] leaves indefinitely; execution requires a
            param-free plan produced by {!substitute_params} first, and
            {!resolve} refuses an unsubstituted leaf rather than guessing. *)
    | Object of (string * t) list
    | Array of t list

  type object_error = Duplicate_field of string

  type resolution_error =
    | Missing_output of Node_id.t
    | Pointer_resolution_failed of
        { node_id : Node_id.t
        ; error : Json_pointer.resolution_error
        }
    | Param_not_substituted of string

  type substitution_error = Missing_param of string

  val literal : Yojson.Safe.t -> t
  val output : node_id:Node_id.t -> pointer:Json_pointer.t -> t
  val param : name:string -> t
  val object_ : (string * t) list -> (t, object_error) result
  val array : t list -> t
  val dependencies : t -> Node_id.t list

  val param_names : t -> string list
  (** Every distinct [Param] name in the template, in first-appearance
      order. The catalog checks this set against the composition's declared
      parameter list in both directions. *)

  val substitute_params
    :  lookup:(string -> Yojson.Safe.t option)
    -> t
    -> (t, substitution_error) result
  (** Replace every [Param] leaf with the caller's value as a [Literal].
      Structure is otherwise preserved, so validity carries over. *)

  val resolve
    :  lookup:(Node_id.t -> Yojson.Safe.t option)
    -> t
    -> (Yojson.Safe.t, resolution_error) result
end

module Run_id : sig
  type t = private int

  val fresh : unit -> t
  val equal : t -> t -> bool
end

(** Globally unique durable observation identity for one composition
    invocation. Unlike {!Run_id}, this UUID crosses process and fleet storage
    boundaries and is never used to control plan execution. *)
module Composition_run_id : sig
  type t

  type error = Invalid_uuid_v7 of string

  val fresh : unit -> t
  val of_string : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type json_type =
  | Null_type
  | Boolean_type
  | Integer_type
  | Number_type
  | String_type
  | Array_type
  | Object_type

type schema_value_error =
  | Unsupported_schema_type of Yojson.Safe.t
  | Missing_required_field of
      { path : string list
      ; field : string
      }
  | Unexpected_field of
      { path : string list
      ; field : string
      }
  | Duplicate_value_field of
      { path : string list
      ; field : string
      }
  | Type_mismatch of
      { path : string list
      ; expected : json_type
      ; actual : json_type
      }

(** Structural error in the deliberately small composable-output schema
    language. The accepted keywords are [type], plus [properties], [required],
    and boolean [additionalProperties] for objects, and [items] for arrays.
    Every nested schema is checked when the plan is created. *)
type schema_contract_error =
  | Expected_schema_object of
      { path : string list
      ; schema : Yojson.Safe.t
      }
  | Duplicate_schema_keyword of
      { path : string list
      ; keyword : string
      }
  | Missing_schema_type of { path : string list }
  | Unsupported_contract_type of
      { path : string list
      ; value : Yojson.Safe.t
      }
  | Unsupported_schema_keyword of
      { path : string list
      ; keyword : string
      }
  | Invalid_schema_keyword_value of
      { path : string list
      ; keyword : string
      ; value : Yojson.Safe.t
      }
  | Duplicate_required_field of
      { path : string list
      ; field : string
      }
  | Unknown_required_property of
      { path : string list
      ; field : string
      }

(** Validate the closed schema language used by composable declared outputs.
    This pure entry point is also used by configuration readers before they
    construct any runtime plan. *)
val validate_composable_schema
  :  Yojson.Safe.t
  -> (unit, schema_contract_error) result

type node = private
  { id : Node_id.t
  ; tool_name : string
  ; input : Json_template.t
  ; after : Node_id.t list
  }

val node
  :  id:Node_id.t
  -> tool_name:string
  -> ?after:Node_id.t list
  -> input:Json_template.t
  -> unit
  -> node

(** Why a descriptor that exists is absent from the Keeper model surface.
    [Unknown_tool] means no descriptor owns the name at all; these mean one
    does, and the Keeper model still cannot call it. The two need opposite
    answers, so they are separate errors rather than one. *)
type off_surface_reason =
  | Operator_only_tool
  | Aliased_by of { projected_by : string }
  | Unresolved_schema

type error =
  | Empty_plan
  | Unknown_descriptor_id of string
  | Duplicate_node_id of Node_id.t
  | Duplicate_tool_name of string
  | Unknown_tool of
      { node_id : Node_id.t
      ; tool_name : string
      }
  | Tool_off_keeper_surface of
      { node_id : Node_id.t
      ; tool_name : string
      ; reason : off_surface_reason
      }
  | Missing_dependency of
      { node_id : Node_id.t
      ; dependency : Node_id.t
      }
  | Opaque_output_reference of
      { node_id : Node_id.t
      ; source_node_id : Node_id.t
      ; source_tool_name : string
      }
  | Invalid_output_pointer of
      { node_id : Node_id.t
      ; source_node_id : Node_id.t
      ; pointer : Json_pointer.t
      ; error : Json_pointer.schema_error
      }
  | Invalid_output_schema of
      { node_id : Node_id.t
      ; tool_name : string
      ; error : schema_contract_error
      }
  | Multiple_terminal_nodes of Node_id.t list
  | Terminal_node_missing_dependency of
      { terminal_node_id : Node_id.t
      ; node_id : Node_id.t
      }
  | Dependency_cycle of Node_id.t list

val error_to_string : error -> string
val error_to_json : error -> Yojson.Safe.t
(** Exhaustive typed projection for operator and client surfaces. *)

type t

val create
  :  descriptors:Keeper_tool_descriptor.t list
  -> node list
  -> (t, error) result

val nodes : t -> node list
val dependencies : node -> Node_id.t list

(** Stable topological layers only. This is not an execution schedule: serial,
    concurrent, and terminal descriptor semantics are applied by the executor. *)
val dependency_layers : t -> node list list

val descriptor : t -> Node_id.t -> Keeper_tool_descriptor.t option

(** A validated output is an in-process capability branded by the exact
    immutable plan instance and [Run_id] that produced it. It is deliberately
    not serializable or durable: process restart, plan reconstruction, or a
    different run must revalidate the producer value instead of replaying this
    token. *)
type output

(** [Unknown_node_id] means the caller asked to validate or resolve a node that
    is not in the canonical plan. A producer lookup miss inside an otherwise
    known consumer is reported by [Input_template_resolution_failed], so the
    two failures are not interchangeable. *)
type execution_error =
  | Unknown_node_id of Node_id.t
  | Input_template_resolution_failed of
      { node_id : Node_id.t
      ; error : Json_template.resolution_error
      }
  | Input_validation_failed of
      { node_id : Node_id.t
      ; tool_name : string
      ; rejection : Tool_result.result
      }
  | Output_validation_failed of
      { node_id : Node_id.t
      ; tool_name : string
      ; error : schema_value_error
      }
  | Output_not_composable of
      { node_id : Node_id.t
      ; tool_name : string
      }

(** Validate one completed producer value against its descriptor-owned output
    schema before it becomes referenceable by another node. *)
val validate_output
  :  t
  -> run_id:Run_id.t
  -> node_id:Node_id.t
  -> Yojson.Safe.t
  -> (output, execution_error) result

val output_node_id : output -> Node_id.t

(** Resolve a canonical plan node's input from already validated producer
    outputs, then validate the resolved value against the consumer's exact
    descriptor input schema before dispatch. *)
val resolve_input
  :  t
  -> run_id:Run_id.t
  -> node_id:Node_id.t
  -> lookup:(Node_id.t -> output option)
  -> (Yojson.Safe.t, execution_error) result
