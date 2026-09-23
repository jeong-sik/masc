(** Server_routes_http_routes_verification — HTTP routes for the
    TLA+ verification dashboard surface.

    - [GET /api/v1/verification/requests] — immutable verification submissions.
    - [GET /api/v1/verification/summary] — submission count.
    - [GET /api/v1/verification/specs] — TLA+ spec index.
    - [GET /api/v1/verification/tlc-results] — latest observed TLC
      log projection.
    - [GET /api/v1/verification/evidence] — token-bound CanAdmin evidence.
    - [POST /api/v1/verification/verdict] — token-bound CanAdmin verdict.

    Keeper task actions do not expose the evidence or verdict routes. *)

type operator_verdict_request =
  { task_id : string
  ; verification_id : string
      (** The submission whose evidence the operator read. A verdict naming
          a submission that is no longer awaiting one is refused with 409. *)
  ; verdict : Masc_domain.completion_verdict
  ; notes : string
  }

(** [GET|POST /api/v1/goals/confirmation] failures. [Confirmation_rejected]
    is the caller's 400 ([{ok:false, error}]); [Goal_store_unavailable] is
    503 with the RFC-0444 envelope ({!Goal_unavailable_envelope.to_yojson}). *)
type confirmation_error =
  | Confirmation_rejected of string
  | Goal_store_unavailable of Goal_store.unavailable

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val commit_goal_confirmation_json : config:Workspace.config -> operator_id:string ->
    Yojson.Safe.t -> (Yojson.Safe.t, confirmation_error) result
  val confirmation_error_to_string : confirmation_error -> string
  val parse_operator_verdict_json :
    Yojson.Safe.t -> (operator_verdict_request, string) result

  val operator_evidence_json :
    config:Workspace.config ->
    operator_id:string ->
    task_id:string ->
    (Yojson.Safe.t, string) result

  val commit_operator_verdict :
    config:Workspace.config ->
    operator_id:string ->
    operator_verdict_request ->
    (Workspace.transition_outcome, Masc_domain.masc_error) result
end
