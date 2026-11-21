(** Immutable presentation of a harness capture or its separate assessment.
    This projection neither schedules Keeper work nor certifies continuity. *)
type provenance = Live_keeper | Assessment
type capture_status = Recording | Recorded | Incomplete
type step_kind = Message | Restart
type step_status = Started | Collecting | Captured | Restart_observed
type scope = Reply | Working_state | Tool_calls
type judgment_result = Unavailable | Pending | Measured of { probability : float; model : string }
type judgment = { criterion_id : string; scope : scope; result : judgment_result }
type memory_readiness = Memory_unavailable | Memory_operations of (string * string) list
type step = {
  id : string;
  kind : step_kind;
  status : step_status;
  operation_state : string option;
  turn_ref : string option;
  working_state_messages : int option;
  working_state : Yojson.Safe.t list option;
  reply : string list;
  judgments : judgment list;
}
type t = {
  keeper : string;
  provenance : provenance;
  status : capture_status;
  started_at : string;
  finished_at : string option;
  error : string option;
  report_path : string;
  report_sha256 : string;
  harness_source_sha256 : string;
  source_capture_sha256 : string option;
  binary_commit : string option;
  executable_sha256 : string option;
  memory_readiness : memory_readiness option;
  timeline : step list;
}
val schema : string
val of_yojson : Yojson.Safe.t -> (t, string) result
