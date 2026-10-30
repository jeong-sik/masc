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
  val of_segments : string list -> t
  (** Construct from already decoded object fields / array index segments. *)
  val of_string : string -> (t, syntax_error) result
  val to_string : t -> string
  (** Canonical RFC 6901 spelling. *)
  val uncons : t -> (string * t) option
  (** [None] means the root pointer; segments are already RFC 6901 decoded. *)
  val append : t -> t -> t
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
  val result_receipt_id : t -> string
  val child_tool_use_id : t -> parent_tool_use_id:string -> alias:Node_id.t -> string
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
    A type may also be a two-element array containing one non-null type and
    [null], in either order. Other type unions remain unsupported. Every
    nested schema is checked when the plan is created, even if its value
    may be null. *)
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

type export = private
  { name : string
  ; node_id : Node_id.t
  ; pointer : Json_pointer.t
  }

val export : name:string -> node_id:Node_id.t -> pointer:Json_pointer.t -> export
(** A requested model-facing field. {!create} checks its name, producer and
    pointer against the same descriptor-owned schema as a node output edge. *)

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
  | Empty_export_name
  | Duplicate_export_name of string
  | Unknown_export_node of { name : string; node_id : Node_id.t }
  | Opaque_export of { name : string; node_id : Node_id.t; tool_name : string }
  | Invalid_export_pointer of
      { name : string
      ; node_id : Node_id.t
      ; pointer : Json_pointer.t
      ; error : Json_pointer.schema_error
      }
  | Unknown_descriptor_id of string
  | Compiled_child_conflict of Node_id.t
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

type branch_failure_policy =
  | Fail_fast
  | Continue_independent

val default_branch_failure_policy : branch_failure_policy
val branch_failure_policy_to_string : branch_failure_policy -> string
val branch_failure_policy_of_string : string -> branch_failure_policy option

val branch_failure_policy : t -> branch_failure_policy

type parameter_binding_error =
  | Missing_argument of string
  | Instantiated_plan_rejected of error

val instantiate_params : descriptors:Keeper_tool_descriptor.t list ->
  args:Yojson.Safe.t -> t -> (t, parameter_binding_error) result
(** Pure per-invocation substitution. The declared plan remains immutable;
    the returned graph is revalidated against the supplied authority. *)

val create
  :  descriptors:Keeper_tool_descriptor.t list
  -> ?branch_failure_policy:branch_failure_policy
  -> ?exports:export list
  -> node list
  -> (t, error) result

type async_child
(** A native compiler operand retaining the exact Skill, argument template,
    parameter schema and immutable declared plan. It grants no admission. *)

val fixed_async_child : alias:Node_id.t -> reference:Skill_reference.t ->
  tool_name:string -> args:Yojson.Safe.t -> input_schema:Yojson.Safe.t ->
  bound_plan:t -> async_child
val dynamic_async_child : alias:Node_id.t -> reference:Skill_reference.t ->
  tool_name:string -> input:Json_template.t -> input_schema:Yojson.Safe.t ->
  declared_plan:t -> async_child
val child_alias : async_child -> Node_id.t
val child_reference : async_child -> Skill_reference.t
val child_tool_name : async_child -> string
val child_input : async_child -> Json_template.t
val child_input_schema : async_child -> Yojson.Safe.t
val child_plan : async_child -> t

type child_binding_error =
  | Child_arguments_rejected of Tool_input_validation.rejection
  | Fixed_child_input_mismatch
  | Child_plan_rejected of parameter_binding_error

val child_binding_error_to_string : child_binding_error -> string
val bind_child_plan : input:Yojson.Safe.t -> async_child -> (t, child_binding_error) result
(** Validate resolved arguments and bind only the frozen declared plan. For
    fixed inputs, also require the original literal value. No source reread. *)

type child_nodes = private
  { child : async_child
  ; submission : node
  ; result : node
  ; output_schema : Yojson.Safe.t
  }

val child_nodes : child:async_child -> submission_id:Node_id.t -> result_id:Node_id.t ->
  ?after:Node_id.t list -> unit -> child_nodes
(** Submission is Serial and effectful; its acknowledgement is opaque. The
    readonly Concurrent result depends on submission and exposes only the
    child plan's validated named exports. No descriptor is copied or invented. *)

type inline_arguments = private
  { alias : Node_id.t
  ; reference : Skill_reference.t
  ; node : node
  ; input_schema : Yojson.Safe.t
  ; output_schema : Yojson.Safe.t
  }
(** Pure compiler-owned argument validation. Its resolved value is available
    only after the frozen parameter schema accepts it. It submits no work. *)

val inline_arguments : alias:Node_id.t -> reference:Skill_reference.t ->
  id:Node_id.t -> tool_name:string -> input:Json_template.t ->
  input_schema:Yojson.Safe.t -> output_schema:Yojson.Safe.t ->
  ?after:Node_id.t list -> unit -> inline_arguments

val create_compiled : descriptors:Keeper_tool_descriptor.t list ->
  children:child_nodes list -> ?arguments:inline_arguments list -> ?branch_failure_policy:branch_failure_policy ->
  ?exports:export list -> node list -> (t, error) result
(** Native compiler entry. Every compiled node must exactly match its operand;
    a plain node or model JSON cannot acquire a child route by tool name.
    Canonical unique nodes and their resolved contracts are indexed once for
    this immutable plan. Validation retains its original node/error order;
    reconstructed or parameter-bound plans build their own index. *)
val compiled_children : t -> child_nodes list

type execution_target =
  | Descriptor_target of Keeper_tool_descriptor.t
  | Child_arguments of inline_arguments
  | Child_submission of child_nodes
  | Child_result of child_nodes

type contract = private
  { target : execution_target
  ; input_schema : Yojson.Safe.t
  ; composable_output : Keeper_tool_descriptor.composable_output
  ; execution : Keeper_tool_descriptor.execution
  }
val contract : t -> Node_id.t -> contract option
val readonly_for_input : t -> node_id:Node_id.t -> input:Yojson.Safe.t -> bool option
(** Resolve the exact per-node contract, including distinct export schemas for
    different children. Reuses this plan's original resolved contract without
    searching the node/child/descriptor lists again. [descriptor] below returns
    [None] for compiled nodes. The index grants no effect or replay authority. *)

val nodes : t -> node list
val exports : t -> export list
val dependencies : node -> Node_id.t list

(** Stable topological layers of the validated plan. Each layer retains the
    relative order in [nodes] and the original node objects, including compiled
    operands. A call builds an immutable dependency frontier without retaining
    state across calls. This is not an execution schedule: serial, concurrent,
    terminal and resource semantics are applied by the executor. *)
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
      ; rejection : Tool_input_validation.rejection
          (** The same validator a direct call of [tool_name] goes through;
              [rejection.violation] names the field and the rule. *)
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

type export_resolution_error =
  | Producer_unavailable of Node_id.t
  | Producer_invalid of execution_error
  | Export_pointer_unavailable of Json_pointer.resolution_error

val resolve_export
  :  t
  -> lookup:(Node_id.t -> Yojson.Safe.t option)
  -> export
  -> (Yojson.Safe.t, export_resolution_error) result
(** Resolve a mapped child export through this plan's authoritative producer
    descriptor and pointer. A child export need not be an outer selected field. *)

val resolve_exports
  :  t
  -> lookup:(Node_id.t -> Yojson.Safe.t option)
  -> (export * (Yojson.Safe.t, export_resolution_error) result) list
(** Resolve declared exports from completed producer data. Each value is
    revalidated against this exact plan before selection. Missing producers,
    invalid output and absent optional fields remain explicit per-field
    errors; a legitimate JSON null is an available value. No I/O or effect
    replay occurs here. The caller keeps execution dispositions separately. *)

(** Resolve a canonical plan node's input from already validated producer
    outputs, then validate the resolved value against the consumer's exact
    descriptor input schema before dispatch. *)
val resolve_input
  :  t
  -> run_id:Run_id.t
  -> node_id:Node_id.t
  -> lookup:(Node_id.t -> output option)
  -> (Yojson.Safe.t, execution_error) result

(** When a node's input is known and checked. [private]: only
    {!prepare_inputs} produces [Checked_before_run], so a value carrying it has
    passed validation. *)
type prepared_input = private
  | Checked_before_run of Yojson.Safe.t
      (** The template reads no producer output, so its value is fixed once
          parameters are bound. This is the validated value to dispatch. *)
  | Checked_when_node_runs
      (** The template reads a producer output; {!resolve_input} resolves and
          validates it after that producer settles. *)

(** Resolve and validate, before any node runs, every node input whose
    template reads no producer output. Nodes are visited in canonical plan
    order and the first rejection is returned with its node, so a plan whose
    later node carries a bad literal or parameter fails without running the
    nodes before it. Each node is validated at most once: a
    [Checked_before_run] value is dispatched as is. A successful result contains
    exactly one entry per node, in the order returned by {!nodes}. *)
val prepare_inputs
  :  t
  -> ((Node_id.t * prepared_input) list, Node_id.t * execution_error) result

val validate_parameterized_inputs : t -> (unit, Node_id.t * execution_error) result
(** Check fixed inputs in a declared Skill plan while leaving parameterized
    inputs for invocation binding. This produces no executable input token. *)
