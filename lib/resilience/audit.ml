(* Resilience_audit — Cycle 28 / Tier A12.

   Typed category enum lifted onto Shared_audit.Envelope. The shared
   envelope stays the single Merkle-chained record; this module only
   pins the category surface and threads keeper_name / session_id into
   the payload. *)

type category =
  | OutcomeRecorded
  | ConfidenceEvaluated
  | DegradationTriggered
  | DegradationRecovered
  | SpeculativeBranchStarted
  | SpeculativeBranchCompleted
  | SpeculativeWinnerSelected
  | RecoveryAttempted
  | RecoverySucceeded
  | RecoveryFailed
  | BudgetChecked
  | BudgetExceeded

let category_to_string = function
  | OutcomeRecorded -> "OutcomeRecorded"
  | ConfidenceEvaluated -> "ConfidenceEvaluated"
  | DegradationTriggered -> "DegradationTriggered"
  | DegradationRecovered -> "DegradationRecovered"
  | SpeculativeBranchStarted -> "SpeculativeBranchStarted"
  | SpeculativeBranchCompleted -> "SpeculativeBranchCompleted"
  | SpeculativeWinnerSelected -> "SpeculativeWinnerSelected"
  | RecoveryAttempted -> "RecoveryAttempted"
  | RecoverySucceeded -> "RecoverySucceeded"
  | RecoveryFailed -> "RecoveryFailed"
  | BudgetChecked -> "BudgetChecked"
  | BudgetExceeded -> "BudgetExceeded"

let category_of_string = function
  | "OutcomeRecorded" -> Some OutcomeRecorded
  | "ConfidenceEvaluated" -> Some ConfidenceEvaluated
  | "DegradationTriggered" -> Some DegradationTriggered
  | "DegradationRecovered" -> Some DegradationRecovered
  | "SpeculativeBranchStarted" -> Some SpeculativeBranchStarted
  | "SpeculativeBranchCompleted" -> Some SpeculativeBranchCompleted
  | "SpeculativeWinnerSelected" -> Some SpeculativeWinnerSelected
  | "RecoveryAttempted" -> Some RecoveryAttempted
  | "RecoverySucceeded" -> Some RecoverySucceeded
  | "RecoveryFailed" -> Some RecoveryFailed
  | "BudgetChecked" -> Some BudgetChecked
  | "BudgetExceeded" -> Some BudgetExceeded
  | _ -> None

let category_to_json c : Yojson.Safe.t = `String (category_to_string c)

(* Wrap [payload] into a JSON object that carries optional [keeper_name]
   and [session_id] alongside the caller's payload. The shared envelope
   has no such fields, so we thread them through the payload sub-tree. *)
let wrap_payload ?keeper_name ?session_id ~payload () : Yojson.Safe.t =
  let base_assoc =
    match payload with
    | `Assoc kvs -> kvs
    | other -> [ "payload", other ]
  in
  let with_keeper =
    match keeper_name with
    | None -> base_assoc
    | Some k -> ("_keeper_name", `String k) :: base_assoc
  in
  let with_session =
    match session_id with
    | None -> with_keeper
    | Some s -> ("_session_id", `String s) :: with_keeper
  in
  `Assoc with_session

let make_entry ~category ?keeper_name ?session_id ~payload ~prev_hash () =
  let wrapped = wrap_payload ?keeper_name ?session_id ~payload () in
  Shared_audit.Envelope.make
    ~category:(category_to_string category)
    ~payload:wrapped
    ~prev_hash

let entry_to_json = Shared_audit.Envelope.to_json
let entry_of_json = Shared_audit.Envelope.of_json

let category_of_entry (e : Shared_audit.Envelope.t) =
  category_of_string e.category
