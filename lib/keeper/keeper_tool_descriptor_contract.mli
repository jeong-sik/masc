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

type create_error =
  | Accepted_tool_name_not_projected of
      { accepted : string
      ; projected : string list
      }
  | Non_canonical_schema of
      { location : schema_location
      ; error : canonical_json_error
      }

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

val create
  :  accepted_tool_name:string
  -> Keeper_tool_descriptor.t
  -> (t, create_error) result

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, decode_error) result

val descriptor_id : t -> string
val accepted_tool_name : t -> string
