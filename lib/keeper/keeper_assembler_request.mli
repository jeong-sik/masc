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

val prompt_variables : t -> (string * string) list
(** Variables for {!Prompt_names.assembler}. JSON values are canonical compact
    JSON. Descriptor rows include their exact input schema. *)

val error_to_yojson : error -> Yojson.Safe.t
