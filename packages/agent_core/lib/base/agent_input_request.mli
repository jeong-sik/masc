(** Canonical elicitation request and its originating run. A pending value is
    owned by one Agent continuation, including its durable checkpoint. *)
type t =
  { request_id : string
  ; participant_name : string option
  ; question : string
  ; schema : Yojson.Safe.t option
  ; timeout_s : float option
  ; created_at : float
  }

type pending = { run_id : string; request : t }

type settlement_error = No_pending_request | Request_not_current

val settle : current:pending option -> pending -> (pending, settlement_error) result
(** Validate both originating run and request identity and return the owner's
    canonical request. The caller applies the response and clears its current
    value atomically. Question/schema supplied in the response proof are never
    substituted for the canonical request. *)

val pending_to_json : pending -> Yojson.Safe.t
val pending_of_json : Yojson.Safe.t -> (pending, string) result
(** Exact object shapes; malformed or incomplete ownership is rejected. *)
