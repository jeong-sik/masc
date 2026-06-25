(** Durable operator approval requests for goal completion.

    This store backs [Goal_phase.Awaiting_approval]. The phase alone is
    intentionally not enough: callers need a durable request id, opener,
    resolver, and final decision to audit who approved or rejected completion. *)

type approval_status =
  | Open
  | Approved
  | Rejected
  | Cancelled

val approval_status_to_string : approval_status -> string
val approval_status_to_yojson : approval_status -> Yojson.Safe.t
val approval_status_of_yojson : Yojson.Safe.t -> (approval_status, string) result

type approval_request =
  { id : string
  ; goal_id : string
  ; verification_request_id : string option
  ; opened_by : Goal_verification.goal_principal
  ; opened_at : string
  ; status : approval_status
  ; resolved_by : Goal_verification.goal_principal option
  ; resolved_at : string option
  ; resolution_note : string option
  }

val approval_request_to_yojson : approval_request -> Yojson.Safe.t
val approval_request_of_yojson : Yojson.Safe.t -> (approval_request, string) result

type state =
  { version : int
  ; updated_at : string
  ; requests : approval_request list
  }

val state_to_yojson : state -> Yojson.Safe.t
val state_of_yojson : Yojson.Safe.t -> (state, string) result

val requests_path : Workspace_utils.config -> string

(** Reads the durable approval ledger. Read-only projections recover from
    [requests_path ^ ".last-good"] when possible and fall back to an empty state
    only after logging an unrecoverable read failure. Mutating operations use an
    internal fail-closed reader and do not overwrite corrupt primary/recovery
    state with an empty default. *)
val read_state : Workspace_utils.config -> state

val find_open_request :
  Workspace_utils.config -> goal_id:string -> approval_request option

val open_request :
  Workspace_utils.config ->
  goal_id:string ->
  ?verification_request_id:string ->
  opened_by:Goal_verification.goal_principal ->
  unit ->
  (approval_request, string) result

val resolve_open_request :
  Workspace_utils.config ->
  goal_id:string ->
  status:approval_status ->
  resolved_by:Goal_verification.goal_principal ->
  ?note:string ->
  unit ->
  (approval_request, string) result
