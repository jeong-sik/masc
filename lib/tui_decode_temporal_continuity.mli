(** Immutable presentation of a harness capture or its separate assessment.
    This projection neither schedules Keeper work nor certifies continuity. *)
type provenance = Live_keeper | Assessment
type capture_status = Recording | Recorded | Incomplete
type step_kind = Message | Restart | Await_summary
type step_status = Started | Collecting | Captured | Restart_observed | Summary_ready_observed
type scope = Reply | Working_state | Tool_calls
type judgment_result = Unavailable | Pending | Measured of { probability : float; model : string }
type judgment = { criterion_id : string; scope : scope; result : judgment_result }
type request_range = { capture_id : string; body_sha256 : string; first_atom : int; summary_end_atom : int option }
type omission_detail = { target_end_atom : int; requests : request_range list }
type omission = Not_requested | Omission_unavailable of string | Not_observed of string * omission_detail | Observed of omission_detail
type step = {
  id : string;
  kind : step_kind;
  status : step_status;
  operation_state : string option;
  turn_ref : string option;
  working_state_messages : int option;
  working_state : Yojson.Safe.t list option;
  reply : string list;
  omission : omission;
  target_end_atom : int option;
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
  timeline : step list;
}
val schema : string
val of_yojson : Yojson.Safe.t -> (t, string) result
