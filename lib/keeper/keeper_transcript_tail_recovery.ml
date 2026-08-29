module Store = Keeper_checkpoint_store
module Unit_ = Keeper_transcript_unit

type keeper_outcome =
  | Already_dispatchable
  | Closed of { tool_use_ids : string list }
  | Unparseable of Unit_.structural_error
  | Meta_unavailable of string
  | Checkpoint_unavailable of Store.checkpoint_ref_load_error
  | Commit_rejected of Store.checkpoint_cas_error

type report =
  { examined : int
  ; closed : int
  ; tool_results_appended : int
  ; unparseable : int
  ; failed : int
  ; outcomes : (string * keeper_outcome) list
  }

let empty_report =
  { examined = 0
  ; closed = 0
  ; tool_results_appended = 0
  ; unparseable = 0
  ; failed = 0
  ; outcomes = []
  }
;;

(* A keeper with no durable metadata, or whose canonical checkpoint has not been
   written yet, has no in-flight tool cycle to recover. Those are ordinary
   startup states, not failures, so they do not inflate the failure count that
   [observe_preparation_stage] reports. *)
let recover_keeper config name =
  match Keeper_meta_store.read_meta config name with
  | Error error -> Meta_unavailable error
  | Ok None -> Already_dispatchable
  | Ok (Some meta) ->
    let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let session_dir =
      Filename.concat (Keeper_types_support.session_base_dir_ config) session_id
    in
    (match Store.load_agent_core_with_ref ~session_dir ~session_id with
     | Error error -> Checkpoint_unavailable error
     | Ok (checkpoint, expected_source_ref) ->
       (match Unit_.close_open_tail checkpoint.Agent_core.Checkpoint.messages with
        | Error structural -> Unparseable structural
        | Ok { Unit_.closed_tool_use_ids = []; _ } -> Already_dispatchable
        | Ok { Unit_.messages; closed_tool_use_ids } ->
          let candidate = { checkpoint with Agent_core.Checkpoint.messages } in
          (match Store.save_agent_core_if_source ~session_dir ~expected_source_ref candidate with
           | Store.Installed _ -> Closed { tool_use_ids = closed_tool_use_ids }
           | Store.Not_installed { cause; _ } -> Commit_rejected cause)))
;;

let accumulate report (name, outcome) =
  let report = { report with examined = report.examined + 1 } in
  let report =
    match outcome with
    | Already_dispatchable -> report
    | Closed { tool_use_ids } ->
      { report with
        closed = report.closed + 1
      ; tool_results_appended =
          report.tool_results_appended + List.length tool_use_ids
      }
    | Unparseable _ -> { report with unparseable = report.unparseable + 1 }
    | Meta_unavailable _ | Checkpoint_unavailable _ | Commit_rejected _ ->
      { report with failed = report.failed + 1 }
  in
  { report with outcomes = (name, outcome) :: report.outcomes }
;;

let log_outcome name outcome =
  match outcome with
  | Already_dispatchable -> ()
  | Closed { tool_use_ids } ->
    (* RFC-0240 §2.4. This is the line that says a lane was saved from
       latching, so it is not silent even on the happy path. *)
    Log.Keeper.warn
      "transcript_tail_recovery: closed interrupted tool cycle keeper=%s \
       tool_use_ids=%s"
      name
      (String.concat "," tool_use_ids)
  | Unparseable structural ->
    Log.Keeper.error
      "transcript_tail_recovery: keeper=%s history does not parse; the \
       reset-required latch stands: %s"
      name
      (Unit_.show_structural_error structural)
  | Meta_unavailable detail ->
    Log.Keeper.error
      "transcript_tail_recovery: keeper=%s durable metadata unavailable: %s"
      name
      detail
  | Checkpoint_unavailable _ ->
    Log.Keeper.error
      "transcript_tail_recovery: keeper=%s canonical checkpoint unavailable"
      name
  | Commit_rejected _ ->
    Log.Keeper.error
      "transcript_tail_recovery: keeper=%s closed tail was not installed"
      name
;;

let recover_open_tails config =
  let names = Keeper_meta_store.persisted_keeper_names config in
  let report =
    List.fold_left
      (fun report name ->
         let outcome = recover_keeper config name in
         log_outcome name outcome;
         accumulate report (name, outcome))
      empty_report
      names
  in
  { report with outcomes = List.rev report.outcomes }
;;
