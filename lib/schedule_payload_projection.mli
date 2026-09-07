(** Typed projection and registry for schedule payload envelopes.

    The schedule domain keeps payloads opaque. This module is the boundary that
    names the payload kinds MASC can understand, validates their objective
    schemas, and returns typed views for production dispatch. *)

type known_kind = Keeper_wake

type support_status =
  | Supported
  | Unsupported
  | Unknown

type creation_rejection =
  | Creation_invalid_payload of string
  | Creation_invalid_supported_payload of known_kind * string
  | Creation_unsupported_kind of string

type dispatch_rejection =
  | Dispatch_invalid_payload of string
  | Dispatch_invalid_supported_payload of known_kind * string
  | Dispatch_unsupported_kind of string

type payload_view

type unsupported_kind_count =
  { raw_kind : string
  ; count : int
  }

type support_summary =
  { supported_kinds : string list
  ; unsupported_request_count : int
  ; unsupported_kinds : unsupported_kind_count list
  ; unknown_request_count : int
  }

val supported_payload_kinds : string list
val support_status_to_string : support_status -> string
val creation_rejection_message : creation_rejection -> string
val dispatch_rejection_message : dispatch_rejection -> string
val supported_contracts_to_yojson : unit -> Yojson.Safe.t
val support_summary_to_yojson : Schedule_domain.schedule_request list -> Yojson.Safe.t

val validate_request_payload_for_creation_detailed
  :  payload:Yojson.Safe.t
  -> (unit, creation_rejection) result

(** Extract the wake target keeper name from a creation payload. [Ok (Some name)]
    for a structurally complete [masc.keeper_wake] payload, [Ok None] for any
    other kind (creation validation rejects those separately). Total on raw
    JSON so callers can consult the target before the request is persisted. *)
val creation_keeper_wake_target
  :  payload:Yojson.Safe.t
  -> (string option, string) result

val set_keeper_wake_result_delivery :
  payload:Yojson.Safe.t ->
  channel:Keeper_continuation_channel.t option ->
  (Yojson.Safe.t, string) result
(** Stamp the creation-boundary result policy into a Keeper wake payload.
    A routable current continuation becomes [reply_to_origin]; absence or an
    unroutable continuation becomes explicit [none]. Caller-supplied delivery
    coordinates are replaced, never trusted. *)

val dispatch_view_detailed
  :  Schedule_domain.schedule_request
  -> (known_kind * payload_view, dispatch_rejection) result

val support_status : Schedule_domain.schedule_request -> support_status
val kind : Schedule_domain.schedule_request -> string option

val dispatch_tool_for_request_result
  :  Schedule_domain.schedule_request
  -> (string, dispatch_rejection) result

val target_summary : Schedule_domain.schedule_request -> string option * string option

(** [wake_keeper_name request] is the bare keeper name a [masc.keeper_wake]
    payload targets, without the ["keeper:"] display prefix that
    [target_summary] carries. [None] for every other payload kind and for a
    malformed payload (logged, same policy as [target_summary]). Consumers
    that need the keeper identity read this instead of parsing the prefixed
    display string. *)
val wake_keeper_name : Schedule_domain.schedule_request -> string option
val result_delivery :
  Schedule_domain.schedule_request ->
  (Keeper_continuation_channel.t option, string) result

val body_required_string : payload_view -> string -> (string, string) result
val body_optional_string : payload_view -> string -> (string option, string) result
val body_result_delivery :
  payload_view -> (Keeper_continuation_channel.t option, string) result
