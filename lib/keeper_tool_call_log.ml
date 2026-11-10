(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records (input arguments + output text)
    to [.masc/tool_calls/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Unlike {!Tool_usage_log} (metadata only) and {!Tool_metrics_persist}
    (aggregated counts), this module stores the actual I/O for debugging
    and dashboard inspection.

    Output is truncated to {!max_output_len} bytes to prevent disk
    explosion from large tool results (e.g. full file reads).

    @since 2.249.0 — Keeper observability *)

let max_output_len = 4000

module Invocation_key = struct
  type t = Agent_core.Tool_contract.Invocation.t

  let equal left right = left == right
  let hash = Hashtbl.hash
end

module Invocation_table = Ephemeron.K1.Make (Invocation_key)

let invocation_execution_ids : Ids.Execution_id.t Invocation_table.t =
  Invocation_table.create 8
let invocation_execution_ids_mu = Stdlib.Mutex.create ()

let with_invocation_execution_ids_lock f =
  Stdlib.Mutex.lock invocation_execution_ids_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock invocation_execution_ids_mu)
    f

let invocation_execution_id ~invocation =
  match Agent_core.Tool_contract.Invocation.occurrence invocation with
  | Some occurrence ->
    Ids.Execution_id.of_string (Agent_core.Tool_contract.Occurrence.node_id occurrence)
  | None ->
    with_invocation_execution_ids_lock (fun () ->
      match Invocation_table.find_opt invocation_execution_ids invocation with
      | Some execution_id -> execution_id
      | None ->
          let execution_id = Ids.Execution_id.generate () in
          Invocation_table.add invocation_execution_ids invocation execution_id;
          execution_id)

(** Pre-truncation info, keyed by the exact Agent Core occurrence. Set by the
    tool handler wrapper and consumed by the on-tool-result hook. The weak key
    prevents cancellation before that hook from retaining the invocation. *)
let pending_truncation : (int * int option) Invocation_table.t =
  Invocation_table.create 8
;;

let pending_truncation_mu = Stdlib.Mutex.create ()

let with_pending_truncation_lock f =
  Stdlib.Mutex.lock pending_truncation_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock pending_truncation_mu)
    f
;;

let set_truncation_info ~invocation ~original_bytes ?truncated_to () =
  with_pending_truncation_lock (fun () ->
    Invocation_table.replace
      pending_truncation
      invocation
      (original_bytes, truncated_to))
;;

let consume_truncation_info ~invocation () =
  with_pending_truncation_lock (fun () ->
    match Invocation_table.find_opt pending_truncation invocation with
    | Some info ->
      Invocation_table.remove pending_truncation invocation;
      info
    | None -> 0, None)
;;

(** The typed disposition, keyed the same way and for the same reason.

    The row this module writes is the only per-call record MASC keeps, and
    until now the ordinary path filled its outcome from a boolean: the hook
    receives AGENT_CORE's [tool_result], which says whether the call errored
    and not why. [Deferred] has no representation there at all, and
    agent_core's own error class is a different taxonomy. The value exists at
    the masc dispatch boundary and is already handed to two other stores
    ([Keeper_registry.record_tool_use], [Tool_registry.record_call]); this
    carries it to the third.

    Same weak key as the truncation table above, so a cancelled invocation
    releases its pending entry rather than holding it. *)
let pending_disposition :
      (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition
        Invocation_table.t
  =
  Invocation_table.create 8
;;

let pending_disposition_mu = Stdlib.Mutex.create ()

let with_pending_disposition_lock f =
  Stdlib.Mutex.lock pending_disposition_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock pending_disposition_mu)
    f
;;

let set_disposition ~invocation ~disposition =
  with_pending_disposition_lock (fun () ->
    Invocation_table.replace pending_disposition invocation disposition)
;;

let consume_disposition ~invocation () =
  with_pending_disposition_lock (fun () ->
    match Invocation_table.find_opt pending_disposition invocation with
    | Some disposition ->
      Invocation_table.remove pending_disposition invocation;
      Some disposition
    | None -> None)
;;

(** Producer-owned file change evidence, keyed by the exact physical
    invocation. It must not be reconstructed from the output string at the
    hook boundary. *)
let pending_file_change_evidence :
      (Keeper_file_change_evidence.t * Tool_output.artifact_ref list) Invocation_table.t
  =
  Invocation_table.create 8
;;

let pending_file_change_evidence_mu = Stdlib.Mutex.create ()

let with_pending_file_change_evidence_lock f =
  Stdlib.Mutex.lock pending_file_change_evidence_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock pending_file_change_evidence_mu)
    f
;;

let set_file_change_evidence ~invocation ~evidence ~artifact_refs =
  with_pending_file_change_evidence_lock (fun () ->
    Invocation_table.replace pending_file_change_evidence invocation (evidence, artifact_refs))
;;

let consume_file_change_evidence ~invocation () =
  with_pending_file_change_evidence_lock (fun () ->
    match Invocation_table.find_opt pending_file_change_evidence invocation with
    | Some (evidence, _) ->
      Invocation_table.remove pending_file_change_evidence invocation;
      Some evidence
    | None -> None)
;;

let peek_file_change_evidence ~invocation () =
  with_pending_file_change_evidence_lock (fun () ->
    Invocation_table.find_opt pending_file_change_evidence invocation |> Option.map fst)
;;

let peek_file_change_artifact_refs ~invocation () =
  with_pending_file_change_evidence_lock (fun () ->
    match Invocation_table.find_opt pending_file_change_evidence invocation with
    | Some (_, refs) -> refs
    | None -> [])
;;

let pending_board_action_evidence :
      (Board_tool_evidence.t, string) result Invocation_table.t =
  Invocation_table.create 8

(* An ephemeron table cannot be enumerated, so the testing snapshot follows the
   most recently retained invocation through a one-slot weak array. The slot
   does not keep the invocation alive. *)
let latest_board_action_invocation : Invocation_key.t Weak.t = Weak.create 1

let pending_board_action_mu = Stdlib.Mutex.create ()
let with_pending_board_action_lock f =
  Stdlib.Mutex.lock pending_board_action_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock pending_board_action_mu) f

let set_board_action_evidence ~invocation ~evidence =
  with_pending_board_action_lock (fun () ->
    Weak.set latest_board_action_invocation 0 (Some invocation);
    Invocation_table.replace pending_board_action_evidence invocation evidence)

let peek_board_action_evidence ~invocation () =
  with_pending_board_action_lock (fun () ->
    Invocation_table.find_opt pending_board_action_evidence invocation)

let clear_board_action_evidence ~invocation () =
  with_pending_board_action_lock (fun () ->
    Invocation_table.remove pending_board_action_evidence invocation)

(* Complete observation artifacts must outlive their truncated log preview.
   The Agent Core hook keeps this carrier until it commits the exact
   invocation row; a composition executor takes a child call's entry and
   carries it to that node's row. *)
let pending_retained_artifacts : Tool_output.artifact_ref list Invocation_table.t =
  Invocation_table.create 8
let retained_artifacts_mu = Stdlib.Mutex.create ()
let with_retained_artifacts_lock f =
  Stdlib.Mutex.lock retained_artifacts_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock retained_artifacts_mu) f
let set_retained_artifacts ~invocation references =
  with_retained_artifacts_lock (fun () ->
    Invocation_table.replace pending_retained_artifacts invocation references)
let peek_retained_artifacts ~invocation () =
  with_retained_artifacts_lock (fun () ->
    (* DET-OK: the invocation carrier is optional; ordinary results own no
       retained roots. Absence does not manufacture a successful receipt. *)
    Option.value ~default:[] (Invocation_table.find_opt pending_retained_artifacts invocation))
let clear_retained_artifacts ~invocation () =
  with_retained_artifacts_lock (fun () -> Invocation_table.remove pending_retained_artifacts invocation)

type turn_ctx_cell = Keeper_tool_call_log_context.cell

let create_turn_ctx_cell = Keeper_tool_call_log_context.create_cell
let set_turn_context = Keeper_tool_call_log_context.set_turn_context
let get_turn_context = Keeper_tool_call_log_context.get_turn_context

let runtime_observability_contract_json_for_call =
  Keeper_tool_call_log_context.runtime_observability_contract_json_for_call
;;

let action_radius_json_for_call =
  Keeper_tool_call_log_context.action_radius_json_for_call
;;

;;

let route_evidence_json_of_tool_io ~tool_name ~input ~output_text ~execution_evidence =
  Keeper_tool_call_log_route_evidence.route_evidence_json_of_tool_io
    ~max_output_len
    ~tool_name
    ~input
    ~output_text
    ~execution_evidence
;;

let execution_evidence_metadata_key = "masc.execution_evidence"

let execution_evidence_metadata fields =
  `Assoc [ execution_evidence_metadata_key, `Assoc fields ]
;;

(* A Gate-authorized result keeps its producer's metadata under "producer"
   ([Keeper_gate.authorization_metadata]); read through it the way
   [Tool_projection.artifact_manifest_from_metadata] does. *)
let execution_evidence_of_metadata metadata =
  let rec find = function
    | `Assoc fields ->
      (match List.assoc_opt execution_evidence_metadata_key fields with
       | Some (`Assoc _ as evidence) -> Some evidence
       | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
         None
       | None ->
         (match List.assoc_opt "producer" fields with
          | Some producer -> find producer
          | None -> None))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
  in
  Option.bind metadata find
;;

type written = { canonical_masc_root : string; keeper_name : string }

type write_observer = { callback : written -> unit }
let write_observers : write_observer list Atomic.t = Atomic.make []
let write_notification_failures = Atomic.make 0
let failed_write_notifications () = Atomic.get write_notification_failures

let rec update_write_observers f =
  let before = Atomic.get write_observers in
  if not (Atomic.compare_and_set write_observers before (f before)) then
    update_write_observers f
;;

let subscribe_written callback =
  let observer = {callback} in
  update_write_observers (fun before -> observer :: before);
  fun () -> update_write_observers (List.filter (fun current -> current != observer))
;;

let notify_written written =
  (* cancel-guard-ok: a listener's cancellation cannot replace this committed
     row's outcome. The writer's next suspension still observes its own
     cancellation. This boundary performs no I/O. *)
  List.iter (fun observer ->
    match observer.callback written with
    | () -> ()
    | exception _ -> ignore (Atomic.fetch_and_add write_notification_failures 1))
    (Atomic.get write_observers)
;;

type store_state =
  { store : (Dated_jsonl.t * string) option
  ; configured : (string * string) option
  }

let store_state = Atomic.make { store = None; configured = None }
module Keeper_revisions = Map.Make (String)

(* One revision per keeper, so a keeper's derived caches go stale on its own
   appends only. A single process-wide counter made every keeper's chat
   history stale on any keeper's tool call, so with a working fleet the
   history was recomputed on nearly every request. *)
let committed_revisions = Atomic.make Keeper_revisions.empty

(* No entry is a keeper with no committed append in this process. *)
let committed_revision ~keeper_name =
  match Keeper_revisions.find_opt keeper_name (Atomic.get committed_revisions) with
  | Some revision -> revision
  | None -> 0
;;

let rec advance_committed_revision ~keeper_name =
  let current = Atomic.get committed_revisions in
  let next =
    Keeper_revisions.update
      keeper_name
      (function
        | Some revision -> Some (revision + 1)
        | None -> Some 1)
      current
  in
  if not (Atomic.compare_and_set committed_revisions current next)
  then advance_committed_revision ~keeper_name
;;

type record_kind =
  | Tool_call
  | Composition_run
  | Lifecycle_event
[@@deriving enumerate]

type committed_call =
  { record_kind : record_kind
  ; keeper_name : string
  ; tool_name : string
  ; execution_id : Ids.Execution_id.t option
  ; tool_use_id : string option
  ; trace_id : string option
  ; task_id : string option
  ; keeper_turn_id : int option
  ; composition_node_id : string option
  ; parent_tool_use_id : string option
  }

type commit_observer =
  { notify : committed_call -> unit
  ; failed_deliveries : int Atomic.t
  }

let commit_observer_key : commit_observer option Eio.Fiber.key = Eio.Fiber.create_key ()
let make_commit_observer notify = {notify; failed_deliveries = Atomic.make 0}
let current_commit_observer () = match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> None
  | Fs_compat.Eio_fiber -> Option.join (Eio.Fiber.get commit_observer_key)
let with_commit_observer observer operation = Eio.Fiber.with_binding commit_observer_key (Some observer) operation
let capture_commit_observer operation =
  let observer = current_commit_observer () in
  fun () -> match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> operation ()
    | Fs_compat.Eio_fiber -> Eio.Fiber.with_binding commit_observer_key observer operation
let failed_commit_deliveries observer = Atomic.get observer.failed_deliveries

let notify_commit observer receipt =
  match observer.notify receipt with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as error) -> raise error
  | exception error ->
    ignore (Atomic.fetch_and_add observer.failed_deliveries 1);
    Log.Misc.warn "keeper Tool commit observer delivery failed: %s" (Printexc.to_string error)
;;

let record_kind_to_string = function
  | Tool_call -> "tool_call"
  | Composition_run -> "composition_run"
  | Lifecycle_event -> "lifecycle_event"
;;

let record_kind_of_string s = List.find_opt (fun v -> String.equal (record_kind_to_string v) s) all_of_record_kind
;;

type append_entry =
  { store : Dated_jsonl.t
  ; canonical_masc_root : string
  ; keeper_name : string
  ; tool_name : string
  ; trace_id : string option
  ; json : Yojson.Safe.t
  }

let append_queue_capacity = 4096
let append_flush_interval_s = 0.5
let append_queue_mu = Stdlib.Mutex.create ()
let append_queue : append_entry Stdlib.Queue.t = Stdlib.Queue.create ()
let async_append_active = Atomic.make false
let append_queue_dropped = Atomic.make 0

let with_append_queue_lock f =
  Stdlib.Mutex.lock append_queue_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock append_queue_mu) f

let queued_count_for_testing () =
  with_append_queue_lock (fun () -> Stdlib.Queue.length append_queue)


let iso_date_of_unix ts = Jsonl_writer.day_key ~ts

(* A trailing-window tally and its exact file identities. Ordinary appends
   extend it; replacement, rotation or retention invalidates the cursor and
   rebuilds the answer. A moving window prunes timestamps before extension. *)
type file_change_cache_entry =
  { fcc_since_ts : float
        (** The window floor this entry was folded against. *)
  ; fcc_oldest_row_ts : float option
        (** The oldest row the tally counted, or [None] if it counted none.
            While this is still inside the window, nothing the entry holds has
            aged out and nothing needs dropping. *)
  ; fcc_cursor : Dated_jsonl.append_cursor
  ; fcc_tally : Keeper_tool_call_file_change.tally
  }

let file_change_cache : (string * float, file_change_cache_entry) Hashtbl.t =
  Hashtbl.create 16
;;

(* Guards [file_change_cache] and makes the incremental fold a single flight, so
   two callers do not read the same appended bytes twice. The fold holds it
   across calls that may suspend the calling fiber. The
   fibers of one domain share one thread, and a [Stdlib.Mutex] raises
   [Sys_error "Mutex.lock: Resource deadlock avoided"] when the thread that
   holds it locks it again, so the next caller of the domain raised instead of
   waiting. [Cross_context_mutex] makes a fiber wait cooperatively, and system
   threads and other domains still wait on the underlying mutex. A cancelled
   fold leaves the cache as it was, because its entry is written after the
   fold returns. *)
let file_change_cache_lock = Cross_context_mutex.create ()

(* Whether a carried entry still answers for a window whose floor is now
   [since_ts] over the day range starting [since].

   Pure, and separate from the read, because it is the part that was wrong:
   the first version compared calendar days, so a one-hour window's entry
   stayed "valid" from 09:00 until midnight (#33563 review). A test cannot
   move the clock, so it exercises this instead.

   Three conditions. The floor only moves forward, or this is not the window
   the entry was folded for. Nothing the entry counted may have fallen behind
   the floor, since a folded tally cannot drop a row -- an unreadable row
   carries no timestamp. And the day range must still start where the entry
   read from, or files it never opened are inside the window. *)
let carried_entry_answers ~entry_since_ts ~entry_oldest_row_ts ~since_ts ~since =
  entry_since_ts <= since_ts
  && (match entry_oldest_row_ts with
      | None -> true
      | Some oldest -> oldest >= since_ts)
  && String.equal (iso_date_of_unix entry_since_ts) since
;;

(* Drop every carried tally. Tests that write rows and read them back in one
   process need the next read to start from an empty window. *)
let reset_file_change_cache () =
  Cross_context_mutex.with_lock file_change_cache_lock (fun () ->
    Hashtbl.reset file_change_cache)
;;

(* [masc_root] is [<base>/.masc]. *)
let location masc_root =
  Dated_jsonl.Store.(at (root_of_masc_dir masc_root) Root.Tool_calls)
;;

let init ~base_path () =
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let canonical_masc_root = Fs_compat.realpath_lenient masc_root in
  let location = location masc_root in
  let dir = Dated_jsonl.Store.dir location in
  Atomic.set store_state { store = None; configured = Some (masc_root, dir) };
  (* A carried tally names rows in the store being replaced. *)
  reset_file_change_cache ();
  try
    let store = Dated_jsonl.open_store location in
    Atomic.set store_state
      { store = Some (store, canonical_masc_root); configured = Some (masc_root, dir) }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Atomic_util.update store_state (fun state -> { state with store = None });
    Log.Misc.warn "keeper_tool_call_log: init failed: %s" (Printexc.to_string exn);
    (try
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"tool_call_io"
         ~producer:"keeper_tool_call_log.init"
         ~durable_store:dir
         ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
         ~stale_reason:"tool_call_io_init_failed"
         ~exn
         ()
     with
     | Eio.Cancel.Cancelled _ as cancel -> raise cancel
     | gap_exn ->
       Log.Misc.warn
         "keeper_tool_call_log: init coverage gap append failed: %s"
         (Printexc.to_string gap_exn))
;;

let reset_for_testing () =
  Atomic.set store_state { store = None; configured = None };
  reset_file_change_cache ();
  Atomic.set committed_revisions Keeper_revisions.empty;
  Atomic.set async_append_active false;
  Atomic.set append_queue_dropped 0;
  with_append_queue_lock (fun () -> Stdlib.Queue.clear append_queue);
  with_pending_truncation_lock (fun () -> Invocation_table.reset pending_truncation);
  with_invocation_execution_ids_lock (fun () -> Invocation_table.reset invocation_execution_ids);
  with_pending_file_change_evidence_lock (fun () ->
    Invocation_table.reset pending_file_change_evidence);
  with_pending_board_action_lock (fun () ->
    Weak.set latest_board_action_invocation 0 None;
    Invocation_table.reset pending_board_action_evidence);
  with_retained_artifacts_lock (fun () -> Invocation_table.reset pending_retained_artifacts)
;;

let pending_truncation_count_for_testing () =
  with_pending_truncation_lock (fun () ->
    Invocation_table.clean pending_truncation;
    Invocation_table.length pending_truncation)
;;

let pending_file_change_evidence_count_for_testing () =
  with_pending_file_change_evidence_lock (fun () ->
    Invocation_table.clean pending_file_change_evidence;
    Invocation_table.length pending_file_change_evidence)
;;

let pending_board_action_evidence_for_testing () =
  with_pending_board_action_lock (fun () ->
    match Weak.get latest_board_action_invocation 0 with
    | None -> []
    | Some invocation ->
      (match Invocation_table.find_opt pending_board_action_evidence invocation with
       | Some evidence -> [ (invocation, evidence) ]
       | None -> []))
;;

let store () = Option.map fst (Atomic.get store_state).store

let store_dir () = Option.map Dated_jsonl.base_dir (store ())

let current_log_path () =
  let state = Atomic.get store_state in
  match state.store, state.configured with
  | Some _, Some (masc_root, _) ->
    (* Same layout this file already reads through Jsonl_writer.day_key below;
       it was spelled out again here (#27143). *)
    Some (Dated_jsonl.Store.dated_path_now (location masc_root)).Dated_jsonl.Store.path
  | Some _, None | None, (Some _ | None) -> None
;;

let configured_masc_root () =
  Option.map fst (Atomic.get store_state).configured

exception Commit_required_but_store_unavailable

let record_append_coverage_gap ~store ~keeper_name ~tool_name ?trace_id exn =
  let durable_store = Dated_jsonl.base_dir store in
  let masc_root = Filename.dirname durable_store in
  try
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"tool_call_io"
      ~producer:"keeper_hooks_agent_core|mcp_server_eio_call_tool"
      ~durable_store
      ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
      ~stale_reason:"tool_call_io_append_failed"
      ~keeper_name
      ?trace_id
      ~error:(Printf.sprintf "%s/%s: %s" keeper_name tool_name (Printexc.to_string exn))
      ~exn
      ()
  with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | gap_exn ->
    Log.Misc.warn
      "keeper_tool_call_log: coverage gap append failed for %s/%s: %s"
      keeper_name
      tool_name
      (Printexc.to_string gap_exn)
;;

let record_unavailable_coverage_gap ~keeper_name ~tool_name ?trace_id () =
  match (Atomic.get store_state).configured with
  | None -> ()
  | Some (masc_root, durable_store) ->
    (try
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"tool_call_io"
         ~producer:"keeper_hooks_agent_core|mcp_server_eio_call_tool"
         ~durable_store
         ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
         ~stale_reason:"tool_call_io_store_unavailable"
         ~keeper_name
         ?trace_id
         ~error:
           (Printf.sprintf "%s/%s: tool call store unavailable" keeper_name tool_name)
         ()
     with
     | Eio.Cancel.Cancelled _ as cancel -> raise cancel
     | gap_exn ->
       Log.Misc.warn
         "keeper_tool_call_log: unavailable coverage gap append failed for %s/%s: %s"
         keeper_name
         tool_name
         (Printexc.to_string gap_exn))
;;

(* [committed] turns true once the row is in the ledger file. A failure after
   that point (retention pruning, the revision advance) leaves the row durable,
   so a caller that retries must read it and not append the row again. *)
(* Only the current segment changes on ordinary appends. Bound that mutable
   prefix so the index's content proof does not grow with a busy day's ledger.
   Completed segments remain authoritative and use the same dated readers;
   this byte boundary rotates storage without dropping or refusing records. *)
let max_current_segment_bytes = 16 * 1024 * 1024

exception Rotation_sequence_exhausted of int

let append_to_store_result ~committed (entry : append_entry) =
  try
    let outcome = Dated_jsonl.append_rotating
      ~on_committed:(fun () ->
        committed := true;
        advance_committed_revision ~keeper_name:entry.keeper_name;
        notify_written { canonical_masc_root = entry.canonical_masc_root;
                         keeper_name = entry.keeper_name })
      entry.store ~max_current_file_bytes:max_current_segment_bytes entry.json in
    (match outcome with
     | Dated_jsonl.Appended_to_current | Dated_jsonl.Appended_after_rotation _ -> ()
     | Dated_jsonl.Skipped_by_append_guard -> raise Dated_jsonl.Append_guard_skipped
     | Dated_jsonl.Skipped_rotation_exhausted { sequence_limit } ->
       raise (Rotation_sequence_exhausted sequence_limit));
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let trace_id = entry.trace_id in
    Keeper_fd_pressure.note_exception ~site:"keeper_tool_call_log.append" exn;
    Keeper_disk_pressure.note_exception ~site:"keeper_tool_call_log.append" exn;
    Log.Misc.warn
      "keeper_tool_call_log: append failed for %s/%s: %s"
      entry.keeper_name
      entry.tool_name
      (Printexc.to_string exn);
    record_append_coverage_gap
      ~store:entry.store
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?trace_id
      exn;
    Error exn
;;

let append_to_store entry =
  match append_to_store_result ~committed:(ref false) entry with
  | Ok () | Error _ -> ()
;;

let take_queued_append () =
  with_append_queue_lock (fun () ->
    if Stdlib.Queue.is_empty append_queue
    then None
    else Some (Stdlib.Queue.take append_queue))
;;

(* The entry leaves the queue before it is written, so a write that raises used
   to end there with the row already gone. [append_to_store_result] re-raises
   [Eio.Cancel.Cancelled] on purpose, to separate it from the failures it
   counts, and the flush daemon's [Cancelled -> ()] arm then swallowed it: one
   row lost per cancellation, with no counter and no log line (masc#30619).

   Putting the entry back at the front preserves order. This is the shape
   [Board_votes.flush_dirty] settled on in #26168 — re-mark on failure,
   because the counter and the log line are not the whole response.

   The requeue does not take the capacity check [enqueue_append] takes, and
   that is deliberate: refusing here would drop the entry this function
   exists to keep. It costs an overshoot. The entry was just taken, so the
   length returns to where it was unless a producer landed in between, and
   then the queue sits one over [append_queue_capacity] per interleaving —
   uncounted, because only [enqueue_append] reports a drop. Repeated write
   failures widen it. The bound is a memory guard rather than a contract, so
   overshooting it beats losing the row; what would be wrong is reading this
   requeue as accounted for.

   [with_append_queue_lock] holds a [Stdlib.Mutex], so the requeue completes
   even when the surrounding Eio context is already cancelled. *)
let requeue_append_front entry =
  with_append_queue_lock (fun () ->
    let rest = Stdlib.Queue.create () in
    Stdlib.Queue.transfer append_queue rest;
    Stdlib.Queue.add entry append_queue;
    Stdlib.Queue.transfer rest append_queue)
;;

type flush_completion =
  | All_committed
  | All_committed_with_post_commit_failures of exn * exn list

let drain_queued_appends_unlocked () =
  let count = ref 0 in
  let post_commit_failures = ref [] in
  let rec loop () =
    match take_queued_append () with
    | None ->
      let completion = match List.rev !post_commit_failures with
        | [] -> All_committed
        | first :: rest -> All_committed_with_post_commit_failures (first, rest) in
      !count, completion
    | Some entry ->
      let committed = ref false in
      (match append_to_store_result ~committed entry with
       | Ok () -> ()
       | Error exn ->
         if !committed then post_commit_failures := exn :: !post_commit_failures
         else (requeue_append_front entry; raise exn)
       | exception exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         if not !committed then requeue_append_front entry;
         Printexc.raise_with_backtrace exn backtrace);
      incr count;
      loop ()
  in
  loop ()
;;

(* The foreground flush waits for a background drain's in-flight append,
   not merely for the queue to look empty. Reuse the shared fiber/thread lock. *)
let append_drain_mutex = Cross_context_mutex.create ()
let drain_receipt () =
  Cross_context_mutex.with_lock append_drain_mutex drain_queued_appends_unlocked

let flush_committed () = snd (drain_receipt ())

let drain_queued_appends () =
  let count, completion = drain_receipt () in
  match completion with
  | All_committed -> count
  | All_committed_with_post_commit_failures (exn, _) -> raise exn

let flush_now () = ignore (drain_queued_appends () : int)

let enqueue_append (entry : append_entry) =
  let dropped =
    with_append_queue_lock (fun () ->
      if Stdlib.Queue.length append_queue >= append_queue_capacity
      then true
      else (
        Stdlib.Queue.add entry append_queue;
        false))
  in
  if dropped
  then (
    Otel_metric_store.inc_counter Otel_metric_store.metric_keeper_tool_call_log_queue_dropped ();
    let dropped_count = Atomic.fetch_and_add append_queue_dropped 1 + 1 in
    if dropped_count = 1 || dropped_count mod 1024 = 0
    then
      Log.Misc.warn
        "keeper_tool_call_log: dropped %d record(s) because async append queue is full"
        dropped_count)
;;

let append_or_enqueue entry =
  if Atomic.get async_append_active then enqueue_append entry else append_to_store entry
;;

let start_flush_fiber ~sw ~clock =
  Atomic.set async_append_active true;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Log.Misc.info
      "keeper_tool_call_log: async flush fiber started (interval=%.1fs, capacity=%d)"
      append_flush_interval_s
      append_queue_capacity;
    let rec loop () =
      match Eio.Time.sleep clock append_flush_interval_s with
      | exception Eio.Cancel.Cancelled _ -> `Stop_daemon
      | () ->
        (match drain_queued_appends () with
         | _ -> ()
         | exception Eio.Cancel.Cancelled _ -> ()
         | exception exn ->
           Log.Misc.warn
             "keeper_tool_call_log: async flush iteration failed: %s"
             (Printexc.to_string exn));
        loop ()
    in
    loop ());
  (* Cancellation during ordinary running no longer loses a row: the drain
     requeues before it re-raises, and the daemon comes back for it. This
     hook is the one place that still can. A cancel here re-raises, and the
     requeued entry is left in a queue that lives only in this process, which
     is on its way out. Closing that needs a durable queue, not another
     handler arm. *)
  Shutdown.register ~name:"keeper_tool_call_log_flush" ~priority:24 (fun () ->
    try
      let n = drain_queued_appends () in
      if n > 0
      then Log.Misc.info "keeper_tool_call_log: shutdown flush wrote %d records" n
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Misc.warn
        "keeper_tool_call_log: shutdown flush failed: %s"
        (Printexc.to_string exn))
;;

(** [blob_aware_output_json safe_output] wraps a tool-output string for
    persistence as the [output] field. When [safe_output] is the OCaml
    [%S]-quoted [masc:blob ...] marker produced by
    [Tool_output.encode_for_agent_core], the wire format escapes the inner
    preview JSON twice (OCaml string-literal + JSON string), which makes
    the telemetry record illegible and inflates disk usage by 30-40%.

    We decode the marker and emit a structured object instead:
      {"_blob": {"sha256":"...", "bytes":N, "mime":"...", "preview":"..."}}

    Non-marker outputs keep the historical [String _] shape so that
    older readers (dashboard, jq scripts) keep working. The dashboard
    consumers are updated in the same change to accept either shape. *)
let blob_aware_output_json (output : string) : Yojson.Safe.t =
  match Tool_output.decode_from_agent_core output with
  | Tool_output.Decoded reference ->
    Tool_output.normalized_artifact_ref_to_json reference
  | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> `String output
;;

let input_to_json (input : Yojson.Safe.t) : Yojson.Safe.t =
  (* Per-leaf marker-aware truncation. Previously
     [String.sub (Yojson.Safe.to_string input) 0 (max - suffix)] chopped
     through a [masc:blob ...] marker embedded in a nested JSON string
     value and stranded sha256/bytes/mime halfway, corrupting the
     content-addressed reference. *)
  let input = Observability_redact.preview_json_strings ~max_len:max_output_len input in
  let s = Yojson.Safe.to_string input in
  if String.length s > max_output_len
  then `String (Observability_redact.redact_preview ~max_len:max_output_len s)
  else input
;;

let log_call
      ~keeper_name
      ~tool_name
      ~(input : Yojson.Safe.t)
      ~(output_text : string)
      ~(duration_ms : float)
      ~(wire_outcome : Tool_result.tool_call_outcome)
      ?(record_kind = Tool_call)
      ?(model : string = "")
      ?agent_name
      ?turn_kind
      ?lane
      ?tool_choice
      ?thinking_enabled
      ?prompt_fingerprint
      ?execution_id
      ?tool_observation
      ?physical_execution_id
      ?tool_use_id
      ?planned_index
      ?batch_index
      ?batch_size
      ?execution_mode
      ?typed_result
      ?disposition
      ?file_change_evidence
      ?board_action_evidence
      ?execution_evidence
      ?(artifact_refs = [])
      ?composition_tool
      ?skill_reference
      ?composition_run_id
      ?composition_node_id
      ?composition_execution
      ?composition_tool_kind
      ?parent_tool_use_id
      ?trace_id
      ?session_id
      ?turn
      ?keeper_turn_id
      ?task_id
      ?sandbox_profile
      ?sandbox_root
      ?sandbox_roots
      ?network_mode
      ?runtime_profile
      ?(answer_source_ids = [])
      ?result_bytes
      ?truncated_to
      ?input_fingerprint
      ?output_fingerprint
      ?on_committed
      ()
  =
  let board_action_evidence =
    let evidence = match board_action_evidence with
      | Some value -> Some value
      | None -> Option.bind typed_result (fun result ->
          Board_tool_evidence.of_metadata (Tool_result.metadata result)) in
    Option.map (Board_tool_evidence.for_tool ~tool_name) evidence
  in
  let commit_observer = current_commit_observer () in
  let requires_commit =
    Option.is_some commit_observer || Option.is_some on_committed
    || Option.is_some tool_observation || artifact_refs <> []
    || Option.exists (fun result -> Tool_result.retained_artifacts result <> []) typed_result
    || (match board_action_evidence with Some (Ok _) -> true | Some (Error _) | None -> false)
  in
  match (Atomic.get store_state).store with
    | None ->
      record_unavailable_coverage_gap ~keeper_name ~tool_name ?trace_id ();
      if requires_commit then raise Commit_required_but_store_unavailable
    | Some (store, canonical_masc_root) ->
      (* RFC-0225 §3.3: no ambient turn-context fallback. Both production
         callers (keeper_hooks_agent_core, mcp_server_eio_call_tool) pass their
         run identity explicitly; filling [None] from a keeper-name-keyed
         global could attach an unrelated concurrent run's identity. A
         [None] field now persists as absent, which is honest. *)
      let model_field =
        if model = ""
        then []
        else [ "model", `String (Boundary_redaction.to_string Boundary_redaction.runtime_model_label) ]
      in
      let runtime_profile_field =
        match runtime_profile with
        | Some value when String.trim value <> "" -> [ "runtime_profile", `String value ]
        | _ -> []
      in
      let result_bytes_field =
        match result_bytes with
        | Some n -> [ "result_bytes", `Int n ]
        | None -> []
      in
      (* task-627: the loop guard's cross-cycle seed reads these two fields
         off the row. They are computed from the raw input and output at the
         call boundary — the row's own input/output are redacted and
         truncated, so recomputing from them would answer a different
         identity. A row without them cannot match a live call and the seed
         skips it. *)
      let input_fingerprint_field =
        match input_fingerprint with
        | Some value -> [ "input_fingerprint", `String value ]
        | None -> []
      in
      let output_fingerprint_field =
        match output_fingerprint with
        | Some value -> [ "output_fingerprint", `String value ]
        | None -> []
      in
      (* The dated log itself clamps [output_text] to [max_output_len].  Derive
         the observation truncation marker here when callers supplied exact
         producer bytes but no stricter upstream clamp.  This keeps direct and
         composed invocations on the same metric contract. *)
      let truncated_to =
        match truncated_to, result_bytes with
        | None, Some n when n > max_output_len -> Some max_output_len
        | explicit, _ -> explicit
      in
      let truncated_to_field =
        match truncated_to with
        | Some n -> [ "truncated_to", `Int n ]
        | None -> []
      in
      (* Top level, beside keeper, because that is where every reader looks:
         the dashboard's turn-actor resolver checks entry.agent_name first and
         never descends into runtime_contract, and the OCaml readers use
         json_string_opt "agent_name" on the entry. The parameter was accepted
         and then dropped, so a caller that passed one had no way to tell. *)
      let agent_name_field =
        match agent_name with
        | Some value when String.trim value <> "" -> [ "agent_name", `String value ]
        | Some _ | None -> []
      in
      let lane_field =
        match lane with
        | Some value -> [ "lane", `String value ]
        | None -> []
      in
      (* Names the turn that made the call: a submitted operation's turn or
         the keeper's own autonomous cycle. Both produce identical rows
         otherwise, so a reader joining calls to a submission had to guess
         from timestamps (#28977). *)
      let turn_kind_field =
        match turn_kind with
        | Some value ->
          [ "turn_kind", `String (Turn_record.turn_kind_to_string value) ]
        | None -> []
      in
      let tool_choice_field =
        match tool_choice with
        | Some value -> [ "tool_choice", `String value ]
        | None -> []
      in
      let thinking_enabled_field =
        match thinking_enabled with
        | Some value -> [ "thinking_enabled", `Bool value ]
        | None -> []
      in
      let prompt_fingerprint_field =
        match prompt_fingerprint with
        | Some value -> [ "prompt_fingerprint", `String value ]
        | None -> []
      in
      let trace_id_field =
        match trace_id with
        | Some value -> [ "trace_id", `String value ]
        | None -> []
      in
      (* RFC-0233 PR-1: canonical per-execution join key, minted once at
         the dispatch boundary and shared with the trajectory row. *)
      let execution_id_field =
        match execution_id with
        | Some value ->
          [ "execution_id", `String (Ids.Execution_id.to_string value) ]
        | None -> []
      in
      let physical_execution_id_field =
        match physical_execution_id with
        | Some value -> [ "physical_execution_id", Ids.Execution_id.to_yojson value ]
        | None -> []
      in
      (* RFC-0233 PR-2: provider call id — the key the agent_core-event rows
         carry, joining this store to agent_core:tool_called/agent_core:tool_completed. *)
      let tool_use_id_field =
        match tool_use_id with
        | Some value -> [ "tool_use_id", `String value ]
        | None -> []
      in
      let planned_index_field =
        match planned_index with
        | Some value -> [ "planned_index", `Int value ]
        | None -> []
      in
      let batch_index_field =
        match batch_index with
        | Some value -> [ "batch_index", `Int value ]
        | None -> []
      in
      let batch_size_field =
        match batch_size with
        | Some value -> [ "batch_size", `Int value ]
        | None -> []
      in
      let execution_mode_field =
        match execution_mode with
        | Some value ->
          [ ( "execution_mode"
            , Agent_core.Tool_contract.execution_mode_to_yojson value ) ]
        | None -> []
      in
      (* The typed class rides on the row so a failed call can be split by
         what failed (dependency, policy, runtime, workflow, operator) without
         reading its prose; absent on completed and deferred rows. *)
      let failure_class_field result =
        match Tool_result.failure_class result with
        | Some class_ ->
          [ "failure_class", `String (Tool_result.tool_failure_class_to_string class_) ]
        | None -> []
      in
      let artifact_ref_fields =
        let typed_refs =
          match typed_result with
          | Some result -> Tool_result.retained_artifacts result
              @ Tool_output.normalized_artifact_refs_in_json (Tool_result.data result)
          | None -> []
        in
        let refs =
          List.fold_left
            (fun (seen, acc) reference ->
              let normalized = Tool_output.with_preview reference "" in
              let json = Tool_output.normalized_artifact_ref_to_json normalized in
              let key = Yojson.Safe.to_string json in
              if Set_util.StringSet.mem key seen
              then seen, acc
              else Set_util.StringSet.add key seen, (key, json) :: acc)
            (Set_util.StringSet.empty, [])
            (artifact_refs @ typed_refs)
          |> snd
          |> List.sort (fun (k1, _) (k2, _) -> String.compare k1 k2)
          |> List.map snd
        in
        if refs = [] then [] else [ "artifact_refs", `List refs ]
      in
      let typed_result_fields =
        match typed_result with
        | Some result ->
          [ "disposition", `String (Tool_result.string_of_disposition result) ]
          @ failure_class_field result
        | None ->
          (* The ordinary hook carries disposition and producer-owned artifact
             references separately, without synthesising a full typed payload
             from the model-facing output text. *)
          (match disposition with
           | Some d ->
             (* This shape carries the class itself as the [Failed] payload.
                [failure_class_field] reads a full [result], which this path
                does not have. *)
             let failure_class_of_shape =
               match d with
               | Tool_result.Failed class_ ->
                 [ ( "failure_class"
                   , `String (Tool_result.tool_failure_class_to_string class_) )
                 ]
               | Tool_result.Completed () | Tool_result.Deferred () -> []
             in
             [ "disposition", `String (Tool_result.string_of_disposition d) ]
             @ failure_class_of_shape
           | None -> [])
      in
      let wire_outcome_field =
        [ ( "wire_outcome"
          , `String (Tool_result.string_of_tool_call_outcome wire_outcome) )
        ]
      in
      let board_action_evidence_field =
        match board_action_evidence with
        | None -> []
        | Some (Ok fact) -> [ "board_action_evidence", Board_tool_evidence.to_yojson fact ]
        | Some (Error _) ->
          [ "board_action_evidence", `Assoc
              [ "schema", `String Board_tool_evidence.schema; "kind", `String "invalid" ] ]
      in
      let file_change_evidence_field =
        match file_change_evidence with
        | Some evidence ->
          [ ( "file_change_evidence"
            , Keeper_file_change_evidence.to_yojson evidence ) ]
        | None -> []
      in
      (* Secret-bearing keys are masked before anything reads the evidence. It
         is stored with the same per-leaf bound as [input] (a receipt's detail
         can quote the payload's stderr); route evidence reads the masked
         object, which keeps its shape. *)
      let redacted_execution_evidence =
        Option.map Observability_redact.redact_json_value execution_evidence
      in
      let execution_evidence_field =
        match redacted_execution_evidence with
        | Some evidence -> [ "execution_evidence", input_to_json evidence ]
        | None -> []
      in
      let composition_fields =
        [ "composition_tool", composition_tool
        ; "composition_run_id", composition_run_id
        ; "composition_node_id", composition_node_id
        ; "parent_tool_use_id", parent_tool_use_id
        ]
        |> List.filter_map (fun (key, value) ->
          Option.map (fun value -> key, `String value) value)
      in
      let skill_reference_field =
        match skill_reference with
        | Some reference -> [ "skill_reference", Skill_reference.to_yojson reference ]
        | None -> []
      in
      let composition_execution_field =
        match composition_execution with
        | Some value ->
          [ ( "composition_execution"
            , `String
                (Keeper_tool_composition_catalog.execution_mode_to_string value) )
          ]
        | None -> []
      in
      let composition_tool_kind_field =
        match composition_tool_kind with
        | Some value ->
          [ ( "composition_tool_kind"
            , `String (Keeper_tool_descriptor.tool_kind_to_string value) )
          ]
        | None -> []
      in
      let session_id_field =
        match session_id with
        | Some value -> [ "session_id", `String value ]
        | None -> []
      in
      let turn_field =
        match turn with
        | Some value -> [ "turn", `Int value ]
        | None -> []
      in
      let keeper_turn_id_field =
        match keeper_turn_id with
        | Some value -> [ "keeper_turn_id", `Int value ]
        | None -> []
      in
      let task_id_field =
        match task_id with
        | Some value -> [ "task_id", `String value ]
        | None -> []
      in
      let sandbox_profile_field =
        match sandbox_profile with
        | Some value -> [ "sandbox_profile", `String value ]
        | None -> []
      in
      let network_mode_field =
        match network_mode with
        | Some value -> [ "network_mode", `String value ]
        | None -> []
      in
      let safe_input = input_to_json (Observability_redact.redact_json_value input) in
      let safe_output =
        Observability_redact.truncate_json_document
          ~max_len:max_output_len output_text
      in
      let output_json = blob_aware_output_json safe_output in
      let runtime_contract =
        Keeper_runtime_contract.runtime_observability_contract_json_from_fields
          ~keeper_name
          ?trace_id
          ?session_id
          ?keeper_turn_id
          ?task_id
          ?sandbox_profile
          ?sandbox_root
          ?sandbox_roots
          ?network_mode
          ?runtime_profile
          ()
      in
      let execution_completed =
        match typed_result, disposition, wire_outcome with
        | Some (Tool_result.Completed _), _, _
        | None, Some (Tool_result.Completed ()), _
        | None, None, Tool_result.Ok ->
          Some true
        | Some (Tool_result.Deferred _ | Tool_result.Failed _), _, _
        | None, Some (Tool_result.Deferred () | Tool_result.Failed _), _
        | None, None, Tool_result.Error ->
          Some false
        | None, None, Tool_result.Unknown -> None
      in
      let action_radius_field =
        match execution_completed with
        | None -> []
        | Some success ->
          let error = if success then None else Some safe_output in
          [ ( "action_radius"
            , Keeper_runtime_contract.action_radius_json
                ~tool_name
                ~input:safe_input
                ~duration_ms
                ?error
                ?sandbox_target:sandbox_profile
                () )
          ]
      in
      let route_evidence_field =
        match
          route_evidence_json_of_tool_io
            ~tool_name
            ~input:safe_input
            ~output_text
            ~execution_evidence:redacted_execution_evidence
        with
        | Some evidence -> [ "route_evidence", evidence ]
        | None -> []
      in
      let json =
        `Assoc
          ([ "ts", `Float (Time_compat.now ())
           ; "record_kind", `String (record_kind_to_string record_kind)
           ; "keeper", `String keeper_name
           ; "tool", `String tool_name
           ; "input", safe_input
           ; "output", output_json
           ; "duration_ms", `Float duration_ms
           ; "runtime_contract", runtime_contract
           ]
           @ action_radius_field
           @ route_evidence_field
           @ agent_name_field
           @ model_field
           @ runtime_profile_field
           @ turn_kind_field
           @ lane_field
           @ tool_choice_field
           @ thinking_enabled_field
           @ prompt_fingerprint_field
           @ execution_id_field
           @ (match tool_observation with
              | None -> []
              | Some observation ->
                [ "tool_observation", Tool_observation.to_yojson observation ])
           @ physical_execution_id_field
           @ tool_use_id_field
           @ planned_index_field
           @ batch_index_field
           @ batch_size_field
           @ execution_mode_field
           @ wire_outcome_field
           @ typed_result_fields
           @ board_action_evidence_field
           @ artifact_ref_fields
           @ file_change_evidence_field
           @ execution_evidence_field
           @ composition_fields
           @ skill_reference_field
           @ composition_execution_field
           @ composition_tool_kind_field
           @ trace_id_field
           @ (match record_kind, List.sort_uniq String.compare answer_source_ids with
              | Tool_call, (_ :: _ as sources) ->
                  ["answer_source_ids", `List (List.map (fun id -> `String id) sources)]
              | Tool_call, [] | (Composition_run | Lifecycle_event), _ -> [])
           @ session_id_field
           @ turn_field
           @ keeper_turn_id_field
           @ task_id_field
           @ sandbox_profile_field
           @ network_mode_field
           @ result_bytes_field
           @ truncated_to_field
           @ input_fingerprint_field
           @ output_fingerprint_field)
      in
      (* Sanitize UTF-8 before persisting.  Tool output may contain invalid
         byte sequences (truncated UTF-8, binary output from subprocess
         captures) that would corrupt the JSONL file and cause downstream
         readers — including the dashboard — to silently skip entire rows. *)
      let safe_json = Inference_utils.sanitize_json_utf8 json in
      let entry = { store; canonical_masc_root; keeper_name; tool_name; trace_id; json = safe_json } in
      if requires_commit then
        (match append_to_store_result ~committed:(ref false) entry with
         | Ok () ->
           Option.iter (fun observer -> notify_commit observer
             {record_kind; keeper_name; tool_name; execution_id; tool_use_id;
              trace_id; task_id; keeper_turn_id; composition_node_id; parent_tool_use_id})
             commit_observer;
           Option.iter (fun notify -> notify ()) on_committed
         | Error exn -> raise exn)
      else append_or_enqueue entry
;;

let keeper_matches name json =
  match Safe_ops.json_string_opt "keeper" json with
  | Some k -> String.equal k name
  | None -> false
;;

(* Why the index cannot be fallen back from, and why its failure is the
   caller's to see, is written above [read_recent]. Both readers share the
   one path. *)
type index_error = Index_unavailable of string

let index_rows ?keeper_name ~n () : (Yojson.Safe.t list, index_error) result =
  if n <= 0
  then Ok []
  else (
    match store () with
    | None -> Ok []
    | Some store ->
      Result.map_error
        (fun detail -> Index_unavailable detail)
        (Keeper_tool_call_index.recent_rows ~store ?keeper_name ~n ()))
;;

let read_after ~keeper_name ~after ~project =
  match store () with
  | None -> Error (Index_unavailable "tool-call ledger is not initialized")
  | Some store ->
    Keeper_tool_call_index.rows_after ~store ~keeper_name ~after ~project
    |> Result.map_error (fun detail -> Index_unavailable detail)

let current_frontier ~keeper_name =
  match store () with
  | None -> Error (Index_unavailable "tool-call ledger is not initialized")
  | Some store ->
    Keeper_tool_call_index.current_frontier ~store ~keeper_name
    |> Result.map_error (fun detail -> Index_unavailable detail)

let read_addressed ~base_path ~codebase ?keeper_name ~limit ~offset () =
  try
    let store = Dated_jsonl.open_store
        (location (Common.masc_dir_from_base_path ~base_path)) in
    Keeper_tool_call_index.addressed_rows ~store ~codebase ?keeper_name ~limit ~offset ()
    |> Result.map_error (fun detail -> Index_unavailable detail)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error (Index_unavailable detail)
  | Unix.Unix_error (error, operation, _) ->
    Error (Index_unavailable (operation ^ ": " ^ Unix.error_message error))

(* The read index answers a keeper's latest rows exactly (RFC-0437). It
   advances itself to the ledger's current end before the query, and it holds
   only where each row lives plus the fields these reads filter on. The ledger
   stays the authority: the rows returned here are read back out of it.

   An index failure is an error, not a reason to scan and not an empty
   answer: a caller could not tell an empty answer from a keeper that made no
   calls (audit F397). The failure travels to the caller as
   [Index_unavailable] and every reader states it. An unconfigured store is a
   different fact and stays [Ok []]: there is no ledger to be unable to read. *)
let read_recent ?keeper_name ?(n = 100) () = index_rows ?keeper_name ~n ()


let ts_of_entry (json : Yojson.Safe.t) : float option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "ts" fields with
     | Some (`Float f) -> Some f
     | Some (`Int i) -> Some (Float.of_int i)
     | _ -> None)
  | _ -> None
;;

exception File_change_read_failed of Dated_jsonl.read_error

let file_change_tally ?keeper_name ~(window_hours : float) () =
  if window_hours <= 0.0
  then Keeper_tool_call_file_change.empty_tally
  else (
    match store () with
    | None -> Keeper_tool_call_file_change.empty_tally
    | Some store ->
      let now = Time_compat.now () in
      let since_ts = now -. (window_hours *. Masc_time_constants.hour) in
      let since = iso_date_of_unix since_ts in
      let until = iso_date_of_unix now in
      let key = Option.value keeper_name ~default:"", window_hours in
      Cross_context_mutex.with_lock file_change_cache_lock (fun () ->
        let carried =
          match Hashtbl.find_opt file_change_cache key with
          | Some entry when entry.fcc_since_ts <= since_ts ->
            let tally =
              match entry.fcc_oldest_row_ts with
              | Some oldest when oldest >= since_ts -> entry.fcc_tally
              | _ -> Keeper_tool_call_file_change.prune_before ~since_ts entry.fcc_tally
            in
            Some (entry.fcc_cursor, tally)
          | Some _ | None -> None
        in
        let cursor, tally =
          match carried with
          | Some (cursor, pruned_tally) -> Some cursor, pruned_tally
          | None -> None, Keeper_tool_call_file_change.empty_tally
        in
        let fold tally json =
          let in_window = match ts_of_entry json with
            | Some ts -> ts >= since_ts
            | None -> false in
          let keeper_ok = match keeper_name with
            | None -> true
            | Some name -> keeper_matches name json in
          if in_window && keeper_ok
          then Keeper_tool_call_file_change.fold_row tally json
          else tally
        in
        let rec read ~cursor ~init =
          match Dated_jsonl.fold_range_appended_result store ~since ~until
              ~cursor ~init ~f:fold with
          | Ok (Dated_jsonl.Appended (tally, cursor)) -> tally, cursor
          | Ok Dated_jsonl.Cursor_invalidated ->
            (* Rotation moved the old current rows into a completed segment.
               Discard the carried tally before reading those rows again. *)
            read ~cursor:None ~init:Keeper_tool_call_file_change.empty_tally
          | Error error ->
            Hashtbl.remove file_change_cache key;
            raise (File_change_read_failed error)
        in
        let tally, cursor = read ~cursor ~init:tally in
        let oldest = Keeper_tool_call_file_change.oldest_row_ts tally in
        Hashtbl.replace
          file_change_cache
          key
          { fcc_since_ts = since_ts
          ; fcc_oldest_row_ts = oldest
          ; fcc_cursor = cursor
          ; fcc_tally = tally
          };
        Keeper_tool_call_file_change.seal_tally tally))
;;

let read_window ?keeper_name ~(window_hours : float) () : Yojson.Safe.t list =
  if window_hours <= 0.0
  then []
  else (
    match store () with
    | None -> []
    | Some store ->
      let now = Time_compat.now () in
      let since_ts = now -. (window_hours *. Masc_time_constants.hour) in
      let since_date = iso_date_of_unix since_ts in
      let until_date = iso_date_of_unix now in
      let keeper_matches name json =
        match Safe_ops.json_string_opt "keeper" json with
        | Some k -> String.equal k name
        | None -> false
      in
      Dated_jsonl.read_range store ~since:since_date ~until:until_date
      |> List.filter (fun json ->
        let in_window =
          match ts_of_entry json with
          | Some ts -> ts >= since_ts
          | None -> false
        in
        in_window
        &&
        match keeper_name with
        | None -> true
        | Some name -> keeper_matches name json))
;;

let read_latest ?keeper_name () : Yojson.Safe.t option =
  let keeper_matches name json =
    match Safe_ops.json_string_opt "keeper" json with
    | Some k -> String.equal k name
    | None -> false
  in
  match store () with
  | None -> None
  | Some store ->
    let scan_limit =
      match keeper_name with
      | None -> 1
      | Some _ -> 16
    in
    let raw_lines = Dated_jsonl.read_recent_lines store scan_limit in
    let rec loop = function
      | [] -> None
      | line :: rest ->
        (match Yojson.Safe.from_string line with
         | exception Yojson.Json_error _ -> loop rest
         | json ->
           let dominated =
             match keeper_name with
             | None -> true
             | Some name -> keeper_matches name json
           in
           if dominated then Some json else loop rest)
    in
    loop (List.rev raw_lines)
;;
