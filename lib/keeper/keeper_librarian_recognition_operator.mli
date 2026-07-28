(** Authenticated operator boundary for a latched recognition publication. *)

type request = Keeper_librarian_recognition_ledger.pending_repair

type outcome =
  { action : request
  ; repair : Keeper_librarian_recognition_ledger.repair_outcome
  }

type error =
  | Invalid_request of string
  | Admission_busy of Keeper_turn_admission.autonomous_block
  | Repair_failed of Keeper_librarian_recognition_ledger.repair_error

type error_class = [ `Bad_request | `Not_found | `Conflict | `Unavailable ]

val request_of_yojson : Yojson.Safe.t -> (request, string) result
(** Strict [{"action":"abort_preserving_current"|"restore_store_before"|
    "settle_store_after"}] parser. Unknown and extra fields fail closed. *)

val execute :
  Workspace.config -> keeper_name:string -> request -> (outcome, error) result
(** Serialize the repair against the keeper turn slot, then execute it against
    the configuration's exact workspace/cluster root. *)

val outcome_to_yojson : outcome -> Yojson.Safe.t
val error_to_string : error -> string
val error_to_yojson : error -> Yojson.Safe.t
val error_class : error -> error_class
