module Store = Keeper_checkpoint_store
module History = Keeper_checkpoint_store.Saved_history
module Unit_ = Keeper_transcript_unit

type keeper_outcome =
  | Already_dispatchable
  | Closed of { tool_use_ids : string list }
  | Unparseable of Unit_.structural_error
  | Meta_unavailable of string
  | Checkpoint_unavailable of History.ref_error
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

(* A history this build reads, or the outcome of a keeper that has none. *)
let history_or_outcome = function
  | Error History.Ref_not_found ->
    (* No canonical checkpoint: the keeper has not saved one on this trace
       (an official-client lane, or a trace whose checkpoint a purge moved
       aside), so there is no open tool cycle to close. Reporting it as a
       load failure logged an ERROR and counted one recovery failure on
       every boot -- 27 boots on 2026-09-22 for one such keeper. *)
    Error Already_dispatchable
  | Ok (History.Superseded _) ->
    (* The next turn starts fresh and does not replay this history, so no
       tool cycle in it is open for that turn. *)
    Error Already_dispatchable
  | Error
      ((History.Ref_read_failed _ | History.Ref_identity_invalid _
       | History.Ref_session_mismatch _ | History.Ref_lock_failed _) as error) ->
    Error (Checkpoint_unavailable error)
  | Ok (History.Read history) -> Ok history
;;

(* How the canonical's history ends, read from its last message back to the
   last one that requests tool calls. Reading every keeper's whole history
   took a boot 15 to 214 seconds, in 25 boots from 2026-11-08 to 2026-11-10
   (#46541), so a history is read whole only when this says a request awaits
   results.

   The store asks for the messages one by one, last message first, and each
   once, so [reading] always holds what the messages after the one asked
   leave. *)
let tail_end ~session_dir ~session_id =
  let reading = ref Unit_.tail_reading_start in
  Store.find_last_agent_core_message ~session_dir ~session_id (fun message ->
    match Unit_.read_tail_message !reading message with
    | Unit_.Tail_end ending -> Some ending
    | Unit_.Reads_message_before earlier ->
      reading := earlier;
      None)
  |> Result.map (function
    | Some ending -> ending
    | None ->
      (* No message requests a tool call. *)
      Unit_.Every_request_answered)
;;

(* The whole history decides what is appended: [close_open_tail] refuses one
   that does not parse, whatever its end looks like. *)
let close_tail_of_whole_history ~session_dir ~session_id =
  match
    history_or_outcome
      (Store.saved_history_of_ref (Store.load_agent_core_with_ref ~session_dir ~session_id))
  with
  | Error outcome -> outcome
  | Ok (checkpoint, expected_source_ref) ->
    (match Unit_.close_open_tail checkpoint.Agent_core.Checkpoint.messages with
     | Error structural -> Unparseable structural
     | Ok { Unit_.closed_tool_use_ids = []; _ } -> Already_dispatchable
     | Ok { Unit_.messages; closed_tool_use_ids } ->
       let candidate = { checkpoint with Agent_core.Checkpoint.messages } in
       (* The closers end the interrupted turn, so its messages become one
          bundle and the next turn starts with no open message. *)
       (match
          Store.save_agent_core_if_source ~session_dir ~expected_source_ref
            ~boundary:Agent_core.Checkpoint_objects.Turn_closes candidate
        with
        | Store.Installed _ -> Closed { tool_use_ids = closed_tool_use_ids }
        | Store.Not_installed { cause; _ } -> Commit_rejected cause))
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
    (match
       history_or_outcome (Store.saved_history_of_ref (tail_end ~session_dir ~session_id))
     with
     | Error outcome -> outcome
     | Ok Unit_.Every_request_answered -> Already_dispatchable
     | Ok Unit_.Request_awaits_results -> close_tail_of_whole_history ~session_dir ~session_id)
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
  | Checkpoint_unavailable error ->
    (* The cause decides the remedy: a lock failure is transient, damaged
       bytes are not. *)
    Log.Keeper.error
      "transcript_tail_recovery: keeper=%s canonical checkpoint unavailable: %s"
      name
      (Store.saved_history_ref_error_to_string error)
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
