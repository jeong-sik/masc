(** Pure, content-addressed proposal for a validated Keeper Tool plan.

    The source capability-surface digest is provenance only. Loading a
    proposal never compares it with a current surface; execution code must
    resolve every exact Tool reference against its own frozen surface. *)

module Proposal_id : sig
  type t = private string

  type error = Not_lowercase_sha256

  val of_string : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type execution =
  | Inline
  | Async

type invalid_payload =
  | Payload_not_object
  | Json_not_canonicalizable of string
  | Unknown_field of string
  | Missing_field of string
  | Invalid_field_type of
      { field : string
      ; expected : string
      ; found : string
      }
  | Blank_field of string
  | Invalid_json_syntax of string

type digest_field =
  | Capability_surface_sha256
  | Proposal_digest

type reference_error =
  | Reference_parse_failed of
      { index : int
      ; error : Keeper_capability_surface.ordinary_tool_reference_parse_error
      }
  | Duplicate_reference of Keeper_capability_surface.ordinary_tool_reference
  | Unknown_descriptor_reference of Keeper_capability_surface.ordinary_tool_reference
  | Mismatched_capability_reference of
      { reference : Keeper_capability_surface.ordinary_tool_reference
      ; expected_capability_id : string
      }
  | Missing_plan_reference of
      { descriptor_id : string
      ; capability_id : string
      }

type error =
  | Invalid_payload of invalid_payload
  | Unsupported_version of int
  | Invalid_reference of reference_error
  | Invalid_digest of
      { field : digest_field
      ; value : string
      }
  | Plan_rejected of Keeper_tool_plan_request.error
  | Async_tool_not_statically_read_only of
      { descriptor_id : string
      ; capability_id : string
      }
  | Tampered_payload of
      { stored_digest : string
      ; computed_digest : string
      }
  | Filename_digest_mismatch of
      { filename_digest : string
      ; content_digest : string
      }

type t

val create
  :  descriptors:Keeper_tool_descriptor.t list
  -> objective:string
  -> execution:execution
  -> capability_surface_sha256:string
  -> ordinary_tool_references:Keeper_capability_surface.ordinary_tool_reference list
  -> plan_json:Yojson.Safe.t
  -> (t, error) result
(** [create] accepts no unvalidated plan bytes. [plan_json] is first passed
    through the strict canonical JSON boundary and then through
    {!Keeper_tool_plan_request.plan_of_json}. *)

val of_stored_yojson
  :  descriptors:Keeper_tool_descriptor.t list
  -> expected_id:Proposal_id.t
  -> Yojson.Safe.t
  -> (t, error) result
(** Strict persisted decoder. Unknown and duplicate fields fail closed, the
    plan is revalidated, and both stored and filename digests are verified. *)

val schema_version : t -> int
val id : t -> Proposal_id.t
val digest : t -> string
val objective : t -> string
val execution : t -> execution
val capability_surface_sha256 : t -> string

val ordinary_tool_references
  :  t
  -> Keeper_capability_surface.ordinary_tool_reference list

val plan : t -> Keeper_tool_plan.t
(** The validated in-process plan reconstructed on both create and load. *)

val plan_json : t -> Yojson.Safe.t
val to_yojson : t -> Yojson.Safe.t
val canonical_bytes : t -> string
val error_to_yojson : error -> Yojson.Safe.t
