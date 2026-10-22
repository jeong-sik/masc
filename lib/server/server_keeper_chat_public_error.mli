(** Public Keeper chat errors contain only server-selected protocol values.
    Diagnostic text stays with the caller's typed cause and operator log. *)
type kind = Keeper_chat_public_error.kind =
  | Invalid_input | Unknown_operation | Not_queued | Idempotency_conflict
  | Native_call_unsettled | Store_unavailable | Owner_unavailable | Owner_stopping
  | Interrupt_failed | Operation_forbidden | Keeper_paused | Unknown_keeper
  | Journal_unreadable | Journal_corrupt | Journal_missing | Journal_pruned
  | Cursor_refusal of Keeper_chat_event_log.cursor_refusal
(** The shared vocabulary ({!Keeper_chat_public_error}); this module adds the
    HTTP status and the incident identity. *)

type t = private
  { status : Httpun.Status.t
  ; code : string
  ; message : string
  ; incident_id : string
  }

val make : incident_id:string -> kind -> t
(** [incident_id] is an existing operation identity or a server-generated ID,
    never a diagnostic or caller error message. No text classifier is used. *)
val to_json : t -> Yojson.Safe.t

val failure_fields : t -> (string * Yojson.Safe.t) list
(** Fixed public detail, stable error code and the same incident identity for
    an otherwise successful control command that could not interrupt a turn. *)

val prioritized_operation_json :
  request_id:string -> signalled:bool -> interrupt_error:t option -> Yojson.Safe.t
(** Queue prioritization remains successful even when interruption failed.
    With no failure, no error code or incident is invented. *)
