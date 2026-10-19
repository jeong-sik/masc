(** Exact original-request observation. These values grant no execution rights. *)
type target = { submitted_by : string; request_id : string; keeper_name : string }
val equal_target : target -> target -> bool
val target_of_json : Yojson.Safe.t -> (target, string) result
type source = { target : target; request_context : Yojson.Safe.t }
val equal_source : source -> source -> bool
type phase = Queued | Running | Cancelling | Waiting | Lost | Cancelled | Persistence_failed | Done of bool
type owner = { request_id : string; generation : int }
type decision = Rejected | Cancelled_continuation
type resolution =
  { owner : owner; decision : decision; requested_by : string; reason : string
  ; resolved_at : float; expected_version : string; marker_version : string }
type run =
  { run_id : string; source_task_id : string option; owner : owner
  ; journal_version : string; observed_at : float; resolution : resolution option }
type logical_value = Not_composition | Original_run of run
type logical = Confirmed of logical_value | Unavailable of string
type snapshot =
  { source : source; phase : phase; submitted_at : float; completed_at : float option
  ; dependencies : Keeper_composition_dependency.t list; result : Yojson.Safe.t option
  ; notice : string option; logical : logical }
type reading = Observed of snapshot | Absent
val decode : target:target -> Yojson.Safe.t -> (reading, string) result
(** Strict schema, physical owner/target echo, closed outcomes, original run/Task
    and resolution-owner agreement. Outer unavailable/rejected reads are errors,
    allowing the fetch owner to retain its last good value. Inner logical failure
    is independent of the successfully observed physical attempt. *)
