open Result.Syntax
open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model
open Keeper_skill_activation_ledger_encode
open Keeper_skill_activation_ledger_decode_ledger
open Keeper_skill_activation_ledger_events
open Keeper_skill_activation_ledger_replay
open Keeper_skill_activation_ledger_load

(* A write transaction. Every append goes through [commit_event_locked], which
   takes the writer of its transaction and marks it, so a write that may have
   changed the store is announced once its session lock is released
   (RFC-0483 §4.2). A write that only re-observes what is stored appends
   nothing and announces nothing. *)
type writer = { mutable appended : bool }

let no_commit_observer ~config:_ ~trace_id:_ = ()

let commit_observer : (config:Workspace.config -> trace_id:Keeper_id.Trace_id.t -> unit) Atomic.t =
  Atomic.make no_commit_observer

let install_commit_observer observer = Atomic.set commit_observer observer

let withdraw_commit_observer observer =
  ignore (Atomic.compare_and_set commit_observer observer no_commit_observer : bool)

let with_write_lock ~config ~trace_id operation =
  let writer = { appended = false } in
  (* The observer only records the trace, so it runs on a raise too: a row
     appended before the raise is on disk all the same. *)
  let announce () = if writer.appended then (Atomic.get commit_observer) ~config ~trace_id in
  match with_lock ~config ~trace_id (operation writer) with
  | result ->
    announce ();
    result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    announce ();
    Printexc.raise_with_backtrace exn backtrace
;;

(* Append [event] after the rows [log] was read to and keep the ledger it
   makes. The row is decoded before it is written, and the decoded event is
   the one applied: a replay reads every row this appends, so a row it could
   not read is never written, and what this process holds is what a replay
   builds. The header goes first when the store has none. A failed append
   leaves the store's end unknown to this process, so the next read replays
   it from the first byte. *)
let commit_event_locked (writer : writer) session_dir (log : session_log) event =
  let row = event_to_yojson event in
  let* ledger =
    (let* decoded = decode_event ~expected_trace_id:log.ledger.session_id row in
     let builder = builder_of_ledger log.ledger in
     let* () = apply_event builder decoded in
     Ok (ledger_of_builder builder))
    |> Result.map_error (fun error -> Decode_failed error)
  in
  let path = events_path session_dir in
  let header =
    if log.header_written
    then ""
    else
      event_row
        (header_to_yojson ~workspace_key:ledger.workspace_key ~session_id:ledger.session_id)
  in
  match
    cursor_result
      ~path
      (Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
         path
         ~expected:log.cursor
         (header ^ event_row row))
  with
  | Error error ->
    (* The row may be on disk; a reader told to read again loses one read. *)
    forget_session_log path;
    writer.appended <- true;
    Error (Event_log_failed error)
  | Ok cursor ->
    remember_session_log path { ledger; cursor; header_written = true };
    writer.appended <- true;
    Ok ledger
;;

type activation_clock = Exact_activation_clock | Original_activation_clock

let record_with_clock ~activation_clock ~config ~trace_id (activation : activation) =
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* () =
      if
        String.equal
          (Ids.Turn_ref.trace_id activation.turn_ref)
          (Keeper_id.Trace_id.to_string trace_id)
      then Ok ()
      else Error (Decode_failed Turn_ref_session_mismatch)
    in
    let* log = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    let current = log.ledger in
    match List.find_opt (exact_key_equal activation) current.activations with
    | Some existing ->
      let expected = match activation_clock,activation.invocation with
        | Original_activation_clock,Nested_composition_invocation _ ->
          {activation with activated_at=existing.activated_at}
        | Exact_activation_clock,_
        | Original_activation_clock,(Instruction_invocation _ | Composition_invocation _) -> activation in
      if Yojson.Safe.equal (activation_to_yojson (recorded_part existing))
          (activation_to_yojson (recorded_part expected))
      then Ok (current, Already_recorded existing)
      else Error (Invocation_id_collision activation.skill_tool_use_id)
    | None ->
      let* stored =
        commit_event_locked writer session_dir log (Activation_recorded activation)
      in
      Ok (stored, Recorded activation))
;;

let record ~config ~trace_id activation =
  record_with_clock ~activation_clock:Exact_activation_clock ~config ~trace_id activation
;;

let record_original_invocation ~config ~trace_id activation =
  record_with_clock ~activation_clock:Original_activation_clock ~config ~trace_id activation
;;

(* The rejection is evidence in its own right: it is recorded, and the
   observation that produced it still fails. *)
let reject_transition_locked writer session_dir log rejection error =
  let* _stored = commit_event_locked writer session_dir log (Transition_rejected rejection) in
  Error error
;;
