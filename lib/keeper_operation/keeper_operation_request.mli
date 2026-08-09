module Canonical_json : sig
  type t

  type error =
    | Duplicate_field of string
    | Invalid_utf8 of string
    | Non_finite_number
    | Unsupported_json_shape
    | Malformed_json of string

  val of_yojson : Yojson.Safe.t -> (t, error) result
  val of_string : string -> (t, error) result
  val to_yojson : t -> Yojson.Safe.t
  val to_bytes : t -> string
  val error_to_string : error -> string
end

type kind =
  | Message
  | Stimulus
  | Autonomous

module Source_ref : sig
  type connector =
    | Dashboard
    | Discord
    | Slack

  type t =
    | Operator_message of { request_id : string }
    | Connector_message of
        { connector : connector
        ; message_id : string
        }
    | Keeper_message of
        { keeper_name : string
        ; causing_operation_id : Keeper_operation_id.Operation_id.t
        ; ordinal : int
        }
    | Event of { event_id : string }
    | Continuation of
        { causal_parent_operation_id : Keeper_operation_id.Operation_id.t
        ; delta_ref : string
        }
    | Autonomous_candidate of { candidate_id : string }

  val to_canonical_json : t -> (Canonical_json.t, string) result
end

module Submitter_ref : sig
  type t =
    | Operator of { principal_id : string }
    | Connector of { authenticated_identity : string }
    | Keeper of { keeper_name : string }
    | System

  val to_canonical_json : t -> (Canonical_json.t, string) result
end

type t

val make
  :  operation_id:Keeper_operation_id.Operation_id.t
  -> kind:kind
  -> source_ref:Source_ref.t
  -> submitter_ref:Submitter_ref.t
  -> input:Canonical_json.t
  -> (t, string) result

val operation_id : t -> Keeper_operation_id.Operation_id.t
val kind : t -> kind
val source_ref : t -> Source_ref.t
val submitter_ref : t -> Submitter_ref.t
val input : t -> Canonical_json.t
val canonical_bytes : t -> string
val request_digest : t -> string
val kind_to_string : kind -> string
