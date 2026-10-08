(** The operator recovery surface for restart residuals (design D4,
    task-1665): see the implementation for the closed rearm/ack contract. *)

val permission : Masc_domain.permission
(** [CanAdmin] — recovery changes durable queue state. *)

val route : string -> string option
(** [route path] recognizes [POST /api/v1/keepers/hitl/approvals/:id/recover]
    and returns the [:id]. *)

type rearm_request =
  { id : string
  ; input_hash : string
  ; sequence : int
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; expected_exact_attempt :
      Keeper_approval_queue_rules_types.exact_attempt_state
  ; expected_disposition :
      Keeper_approval_queue_rules_types.summary_attempt_disposition
  }

val parse_rearm_fields :
  (string * Yojson.Safe.t) list -> (rearm_request, string) result
(** The typed admission gate for [action:"rearm"]: only a restart-latched
    exact attempt ([Exact_restart_quarantined] or
    [Exact_released_recovery_required]) with an [in_flight] or
    [persistence_uncertain] disposition parses. Everything else is a typed
    refusal before any queue lookup. *)

val handle_post :
  Mcp_server.server_state ->
  actor:string ->
  approval_id:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit
(** One recover POST: [action:"rearm"] clears an install-only restart latch
    through the queue's typed CAS ([Exact_restart_quarantined] or
    [Exact_released_recovery_required] with disposition [in_flight] or
    [persistence_uncertain] back to a fresh unbound flow — summary creation
    resumes, an external tool is never re-dispatched), and
    [action:"ack_uncertain"] acknowledges a consume-only late-approval tail
    (a warning acknowledgement, never a re-authorization). The workspace is
    the authenticated caller's. *)

val uncertain_path : string
val uncertain_response : Mcp_server.server_state -> Httpun.Status.t * Yojson.Safe.t
val handle_uncertain_get : Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** CanAdmin listing of exact attempts in the authenticated workspace; unavailable
    journals return 503, never an empty successful list. ack requires consume_id. *)

val parse_ack_fields : (string * Yojson.Safe.t) list -> ((string * string), string) result
(** Exact keeper/consume ID; no original argument reconstruction required. *)
