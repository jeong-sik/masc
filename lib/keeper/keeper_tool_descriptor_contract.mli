(** Serializable acceptance-time semantics for one Keeper tool descriptor.

    Runtime handlers, translations, functions, and process identities are
    deliberately absent. The descriptor id and capability id retain route
    identity while the remaining fields retain the semantics used by
    {!Keeper_tool_plan}. *)

type t

type schema_location =
  | Input_schema
  | Composable_output_schema

type canonical_json_error = Keeper_chat_operation.canonical_json_error =
  | Duplicate_object_key of string
  | Non_finite_float

type invariant_error =
  | Uncallable_model_projection of Keeper_tool_descriptor.keeper_model_projection
  | Blank_accepted_tool_name
  | Invalid_model_input_schema of string list

type create_error =
  | Accepted_tool_name_not_projected of
      { accepted : string
      ; projected : string list
      }
  | Non_canonical_schema of
      { location : schema_location
      ; error : canonical_json_error
      }
  | Create_invariant_violation of invariant_error

type decode_error =
  | Non_canonical_json of canonical_json_error
  | Expected_object
  | Unknown_field of string
  | Missing_field of string
  | Expected_string of string
  | Expected_nullable_string of string
  | Empty_string of string
  | Invalid_model_projection of string
  | Model_projection_payload_mismatch
  | Invalid_composable_output of string
  | Composable_output_payload_mismatch
  | Invalid_execution of string
  | Decode_invariant_violation of invariant_error

type drift =
  | Descriptor_removed of
      { descriptor_id : string
      ; accepted_tool_name : string
      }
  | Ambiguous_descriptor_id of
      { descriptor_id : string
      ; accepted_tool_name : string
      }
  | Capability_identity_changed of
      { accepted_tool_name : string
      ; accepted : string
      ; current : string
      }
  | Accepted_tool_name_changed of
      { descriptor_id : string
      ; accepted : string
      ; current : string list
      }
  | Model_projection_changed of
      { accepted_tool_name : string
      ; accepted : Keeper_tool_descriptor.keeper_model_projection
      ; current : Keeper_tool_descriptor.keeper_model_projection
      }
  | Input_schema_changed of
      { accepted_tool_name : string
      ; accepted : Yojson.Safe.t
      ; current : Yojson.Safe.t
      }
  | Composable_output_changed of
      { accepted_tool_name : string
      ; accepted : Keeper_tool_descriptor.composable_output
      ; current : Keeper_tool_descriptor.composable_output
      }
  | Execution_changed of
      { accepted_tool_name : string
      ; accepted : Keeper_tool_descriptor.execution
      ; current : Keeper_tool_descriptor.execution
      }
  | Current_schema_non_canonical of
      { accepted_tool_name : string
      ; location : schema_location
      ; error : canonical_json_error
      }

val create
  :  accepted_tool_name:string
  -> Keeper_tool_descriptor.t
  -> (t, create_error) result

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, decode_error) result

val descriptor_id : t -> string

val revalidate
  :  descriptors:Keeper_tool_descriptor.t list
  -> t
  -> (Keeper_tool_descriptor.t, drift) result
(** Resolve by descriptor identity and compare the exact accepted semantics.
    Success returns the current runtime descriptor; it never reconstructs or
    persists its opaque execution fields. *)
