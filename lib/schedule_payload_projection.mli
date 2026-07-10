(** Typed projection and registry for schedule payload envelopes.

    The schedule domain keeps payloads opaque. This module is the boundary that
    names the payload kinds MASC can understand, validates side-effecting
    creation requests, and returns typed views for production dispatch. *)

type known_kind =
  | Board_post
  | Keeper_wake

type support_status =
  | Supported
  | Unsupported
  | Unknown

type creation_rejection =
  | Creation_invalid_payload of string
  | Creation_invalid_supported_payload of known_kind * string
  | Creation_unsupported_side_effecting_kind of string

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

val known_kind_to_string : known_kind -> string
val dispatch_tool_name : known_kind -> string
val supported_payload_kinds : string list
val support_status_to_string : support_status -> string
val creation_rejection_message : creation_rejection -> string
val dispatch_rejection_message : dispatch_rejection -> string
val supported_contracts_to_yojson : unit -> Yojson.Safe.t
val support_summary : Schedule_domain.schedule_request list -> support_summary
val support_summary_yojson : support_summary -> Yojson.Safe.t
val support_summary_to_yojson : Schedule_domain.schedule_request list -> Yojson.Safe.t
val kind_of_json_result : Yojson.Safe.t -> (string, string) result

(** [intrinsic_risk_class_of_payload payload] is the risk_class the payload's
    kind mandates, when the kind (not the caller) determines it. [masc.keeper_wake]
    is always [Reminder_only]; other/unknown kinds return [None] (caller-specified).
    Used at the creation boundary to clamp a caller-supplied risk_class that would
    otherwise force a self-wake into a human-grant deadlock. *)
val intrinsic_risk_class_of_payload
  :  Yojson.Safe.t
  -> Schedule_domain.risk_class option

val validate_request_payload_for_creation_detailed
  :  payload:Yojson.Safe.t
  -> risk_class:Schedule_domain.risk_class
  -> (unit, creation_rejection) result

val validate_request_payload_for_creation
  :  payload:Yojson.Safe.t
  -> risk_class:Schedule_domain.risk_class
  -> (unit, string) result

val dispatch_view_detailed
  :  Schedule_domain.schedule_request
  -> (known_kind * payload_view, dispatch_rejection) result

val dispatch_view
  :  Schedule_domain.schedule_request
  -> (known_kind * payload_view, string) result

val support_status_result
  :  Schedule_domain.schedule_request
  -> (support_status, string) result

val support_status : Schedule_domain.schedule_request -> support_status
val kind_result : Schedule_domain.schedule_request -> (string, string) result
val kind : Schedule_domain.schedule_request -> string option

val dispatch_tool_for_request_result
  :  Schedule_domain.schedule_request
  -> (string, dispatch_rejection) result

val dispatch_tool_for_request : Schedule_domain.schedule_request -> string option
val target_summary_result
  :  Schedule_domain.schedule_request
  -> (string option * string option, string) result

val target_summary : Schedule_domain.schedule_request -> string option * string option

val view_kind : payload_view -> string
val view_schema_version : payload_view -> int
val body_required_string : payload_view -> string -> (string, string) result
val body_optional_string : payload_view -> string -> (string option, string) result
val body_optional_int : payload_view -> string -> (int option, string) result
val body_optional_assoc : payload_view -> string -> (Yojson.Safe.t option, string) result
