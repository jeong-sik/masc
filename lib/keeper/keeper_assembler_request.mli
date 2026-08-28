(** Pure request boundary for an Assembler proposal.

    Exact Tool references are resolved only against the immutable capability
    surface supplied by the current Keeper turn. The result contains active
    descriptors only and performs no provider call or Tool execution. *)

type execution = Keeper_plan_proposal.execution =
  | Inline
  | Async

type error =
  | Request_not_object
  | Duplicate_field of string
  | Unknown_field of string
  | Missing_field of string
  | Invalid_field_type of
      { field : string
      ; expected : string
      ; found : string
      }
  | Blank_objective
  | Invalid_execution of string
  | Empty_tool_references
  | Reference_parse_failed of
      { index : int
      ; error : Keeper_capability_surface.ordinary_tool_reference_parse_error
      }
  | Duplicate_tool_reference of Keeper_capability_surface.ordinary_tool_reference
  | Reference_resolution_failed of
      { index : int
      ; error : Keeper_capability_surface.ordinary_tool_resolution_error
      }
  | Referenced_tool_unavailable of
      { index : int
      ; reference : Keeper_capability_surface.ordinary_tool_reference
      ; availability : Keeper_capability_surface.capability_availability
      }
  | Async_tool_not_statically_read_only of
      { descriptor_id : string
      ; capability_id : string
      }
  | Prompt_variable_json_not_canonicalizable of
      { variable : string
      ; detail : string
      }

type output =
  | Plan of
      { plan_json : Yojson.Safe.t
      ; plan : Keeper_tool_plan.t
      }
  | Cannot_assemble

type output_error =
  | Output_not_object
  | Output_duplicate_field of string
  | Output_unknown_field of string
  | Output_missing_field of string
  | Output_invalid_kind of Yojson.Safe.t
  | Output_plan_rejected of Keeper_tool_plan_request.error

type t

val input_schema : Yojson.Safe.t

val of_yojson
  :  capability_surface:Keeper_capability_surface.t
  -> Yojson.Safe.t
  -> (t, error) result

val objective : t -> string
val execution : t -> execution

val ordinary_tool_references
  :  t
  -> Keeper_capability_surface.ordinary_tool_reference list

val descriptors : t -> Keeper_tool_descriptor.t list
val capability_surface_sha256 : t -> string

val output_schema : Yojson.Safe.t
(** Closed model-output sum: [{kind:"plan", plan:...}] or exactly
    [{kind:"cannot_assemble"}]. *)

val output_of_yojson
  :  request:t
  -> Yojson.Safe.t
  -> (output, output_error) result

val output_error_to_yojson : output_error -> Yojson.Safe.t

val prompt_variables : t -> ((string * string) list, error) result
(** Variables for {!Prompt_names.assembler}. JSON values are canonical compact
    JSON. Descriptor rows include their exact input schema. *)

val error_to_yojson : error -> Yojson.Safe.t
