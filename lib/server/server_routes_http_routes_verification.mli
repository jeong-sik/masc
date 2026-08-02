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
  ; verdict : Masc_domain.completion_verdict
  ; notes : string
  }

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
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
    (Workspace.transition_outcome, string) result
end
