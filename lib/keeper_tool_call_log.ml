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
      Keeper_file_change_evidence.t Invocation_table.t
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

let set_file_change_evidence ~invocation ~evidence =
  with_pending_file_change_evidence_lock (fun () ->
    Invocation_table.replace pending_file_change_evidence invocation evidence)
;;

let consume_file_change_evidence ~invocation () =
  with_pending_file_change_evidence_lock (fun () ->
    match Invocation_table.find_opt pending_file_change_evidence invocation with
    | Some evidence ->
      Invocation_table.remove pending_file_change_evidence invocation;
      Some evidence
    | None -> None)
;;

let peek_file_change_evidence ~invocation () =
  with_pending_file_change_evidence_lock (fun () ->
    Invocation_table.find_opt pending_file_change_evidence invocation)
;;

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

let route_evidence_json_of_tool_io ~tool_name ~input ~output_text =
  Keeper_tool_call_log_route_evidence.route_evidence_json_of_tool_io
    ~max_output_len
    ~tool_name
    ~input
    ~output_text
;;

type store_state =
  { store : Dated_jsonl.t option
  ; configured : (string * string) option
  }

let store_state = Atomic.make { store = None; configured = None }
let committed_revision_ref = Atomic.make 0

let committed_revision () = Atomic.get committed_revision_ref

type record_kind =
  | Tool_call
  | Composition_run

let record_kind_to_string = function
  | Tool_call -> "tool_call"
  | Composition_run -> "composition_run"
;;

type append_entry =
  { store : Dated_jsonl.t
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


(* RFC-0162 §3.3: default retention. The earlier opt-in policy
   (None unless env explicitly set positive) let `.masc/tool_calls/`
   grow unbounded; RFC-0162 §1.2 observed 30 day-files / 465 MB on a
   developer workstation. The dashboard count_entries scan
   (Phase 0b) and the host kern.maxfiles budget both degrade
   monotonically with directory size.

   The mli already documents "default is 30 days, and values <= 0
   disable pruning" (lib/keeper_tool_call_log.mli:99-103), so this
   change is a contract recovery — the ml implementation was
   drifted from its own stated contract. Operators that want the
   prior unbounded behavior must now opt out explicitly with
   MASC_TOOL_CALL_LOG_RETENTION_DAYS=0. *)
let retention_days_default = 30

(* Opt-out: unset prunes after [retention_days_default]. A malformed value
   lands on that same default and warns, rather than being the one store that
   treated garbage differently from the two that cite this one (#27110). *)
let retention_days () =
  match
    Env_config_core.get_retention_days
      ~default:(Env_config_core.Prune_after_days retention_days_default)
      "MASC_TOOL_CALL_LOG_RETENTION_DAYS"
  with
  | Env_config_core.Retain_forever -> None
  | Env_config_core.Prune_after_days days -> Some days

let init ?cluster_name ~base_path () =
  let cluster_name =
    Option.value ~default:(Env_config_core.cluster_name ()) cluster_name
  in
  let masc_root = Workspace_utils.masc_root_dir_from ~base_path ~cluster_name in
  let dir = Filename.concat masc_root "tool_calls" in
  Atomic.set store_state { store = None; configured = Some (masc_root, dir) };
  try
    let retention_days = retention_days () in
    let store = Dated_jsonl.create ~base_dir:dir ?retention_days () in
    Atomic.set store_state
      { store = Some store; configured = Some (masc_root, dir) }
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
  Atomic.set committed_revision_ref 0;
  Atomic.set async_append_active false;
  Atomic.set append_queue_dropped 0;
  with_append_queue_lock (fun () -> Stdlib.Queue.clear append_queue);
  with_pending_truncation_lock (fun () -> Invocation_table.reset pending_truncation);
  with_pending_file_change_evidence_lock (fun () ->
    Invocation_table.reset pending_file_change_evidence)
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

let store_dir () =
  match (Atomic.get store_state).store with
  | Some store -> Some (Dated_jsonl.base_dir store)
  | None -> None
;;

let current_log_path () =
  match store_dir () with
  | None -> None
  | Some dir ->
    (* Same layout this file already reads through Jsonl_writer.day_key below;
       it was spelled out again here (#27143). *)
    Some (Jsonl_writer.dated_path_now ~base_dir:dir).Jsonl_writer.path
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

let append_to_store_result (entry : append_entry) =
  try
    Dated_jsonl.append entry.store entry.json;
    (* fire-and-forget: pre-increment count is unused; committed_revision () reads the counter directly. *)
    ignore (Atomic.fetch_and_add committed_revision_ref 1 : int);
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
  match append_to_store_result entry with
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

let drain_queued_appends () =
  let count = ref 0 in
  let rec loop () =
    match take_queued_append () with
    | None -> !count
    | Some entry ->
      (match append_to_store entry with
       | () -> ()
       | exception exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         requeue_append_front entry;
         Printexc.raise_with_backtrace exn backtrace);
      incr count;
      loop ()
  in
  loop ()
;;

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

let normalized_artifact_refs_in_typed_data data =
  Tool_output.normalized_artifact_refs_in_json data
  |> List.map (fun reference ->
    Tool_output.with_preview reference ""
    |> Tool_output.normalized_artifact_ref_to_json)
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
      ~(success : bool)
      ~(duration_ms : float)
      ?(record_kind = Tool_call)
      ?(model : string = "")
      ?agent_name
      ?turn_kind
      ?lane
      ?tool_choice
      ?thinking_enabled
      ?thinking_budget
      ?prompt_fingerprint
      ?execution_id
      ?tool_use_id
      ?planned_index
      ?batch_index
      ?batch_size
      ?execution_mode
      ?typed_result
      ?disposition
      ?file_change_evidence
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
      ?result_bytes
      ?truncated_to
      ?on_committed
      ()
  =
  match (Atomic.get store_state).store with
    | None ->
      record_unavailable_coverage_gap ~keeper_name ~tool_name ?trace_id ();
      (match on_committed with
       | None -> ()
       | Some _ -> raise Commit_required_but_store_unavailable)
    | Some store ->
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
      let thinking_budget_field =
        match thinking_budget with
        | Some value -> [ "thinking_budget", `Int value ]
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
      let typed_result_fields =
        match typed_result with
        | Some result ->
          let artifact_refs =
            normalized_artifact_refs_in_typed_data (Tool_result.data result)
          in
          [ "disposition", `String (Tool_result.string_of_disposition result) ]
          @ failure_class_field result
          @ (if artifact_refs = []
             then []
             else [ "artifact_refs", `List artifact_refs ])
        | None ->
          (* The ordinary path knows the disposition but not the payload, so it
             cannot supply [typed_result] and cannot name artifact refs. Kept
             as a separate argument rather than a synthesised result: a made-up
             payload would put an empty [artifact_refs] on a row that simply
             does not know. *)
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
      let file_change_evidence_field =
        match file_change_evidence with
        | Some evidence ->
          [ ( "file_change_evidence"
            , Keeper_file_change_evidence.to_yojson evidence ) ]
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
        Observability_redact.redact_preview ~max_len:max_output_len output_text
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
      let error = if success then None else Some safe_output in
      let action_radius =
        Keeper_runtime_contract.action_radius_json
          ~tool_name
          ~input:safe_input
          ~success
          ~duration_ms
          ?error
          ?sandbox_target:sandbox_profile
          ()
      in
      let route_evidence_field =
        match
          route_evidence_json_of_tool_io ~tool_name ~input:safe_input ~output_text
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
           ; "success", `Bool success
           ; "duration_ms", `Float duration_ms
           ; "runtime_contract", runtime_contract
           ; "action_radius", action_radius
           ]
           @ route_evidence_field
           @ agent_name_field
           @ model_field
           @ runtime_profile_field
           @ turn_kind_field
           @ lane_field
           @ tool_choice_field
           @ thinking_enabled_field
           @ thinking_budget_field
           @ prompt_fingerprint_field
           @ execution_id_field
           @ tool_use_id_field
           @ planned_index_field
           @ batch_index_field
           @ batch_size_field
           @ execution_mode_field
           @ typed_result_fields
           @ file_change_evidence_field
           @ composition_fields
           @ skill_reference_field
           @ composition_execution_field
           @ composition_tool_kind_field
           @ trace_id_field
           @ session_id_field
           @ turn_field
           @ keeper_turn_id_field
           @ task_id_field
           @ sandbox_profile_field
           @ network_mode_field
           @ result_bytes_field
           @ truncated_to_field)
      in
      (* Sanitize UTF-8 before persisting.  Tool output may contain invalid
         byte sequences (truncated UTF-8, binary output from subprocess
         captures) that would corrupt the JSONL file and cause downstream
         readers — including the dashboard — to silently skip entire rows. *)
      let safe_json = Inference_utils.sanitize_json_utf8 json in
      let entry = { store; keeper_name; tool_name; trace_id; json = safe_json } in
      (match on_committed with
       | None -> append_or_enqueue entry
       | Some notify ->
         (match append_to_store_result entry with
          | Ok () -> notify ()
          | Error exn -> raise exn))
;;

(* Scan multiplier applied before the keeper filter: [read_recent] reads
   [n * read_over_scan_factor] fleet rows to find [n] matching entries.
   Named (rather than a literal 5) so callers sharing one fleet read can
   size their window to reproduce [read_recent]'s coverage exactly. *)
let read_over_scan_factor = 5

let keeper_matches name json =
  match Safe_ops.json_string_opt "keeper" json with
  | Some k -> String.equal k name
  | None -> false
;;

(* Single-pass ring buffer: keep the last [n] rows satisfying [keep],
   preserving row order. *)
let ring_keep_last ~n ~keep rows : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    let buf = Array.make n (`Null : Yojson.Safe.t) in
    let pos = ref 0 in
    let total = ref 0 in
    List.iter
      (fun json ->
         if keep json
         then (
           buf.(!pos mod n) <- json;
           incr pos;
           incr total))
      rows;
    let count = min !total n in
    if count = 0
    then []
    else (
      let start = if !total <= n then 0 else !pos mod n in
      List.init count (fun i -> buf.((start + i) mod n))))
;;

let read_recent_rows ~n () : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    match (Atomic.get store_state).store with
    | None -> []
    | Some store -> Dated_jsonl.read_recent store n)
;;

let filter_rows_for_keeper ~keeper_name ~n rows : Yojson.Safe.t list =
  ring_keep_last ~n ~keep:(keeper_matches keeper_name) rows
;;

let read_recent ?keeper_name ?(n = 100) () : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    (* The over-scan pays for the keeper filter: to end up with [n] rows from
       one keeper you must read more than [n] fleet rows. With no keeper the
       filter keeps everything, so the extra rows are read, parsed, and then
       discarded by [ring_keep_last] — four fifths of the work for an answer
       that cannot change.

       It is not a rounding error at this size. The tool-call log averages
       6.8 KB per row on this host, so the fleet-wide dashboard aggregate
       (n = 5000) read 25,000 rows = 165 MB and took 3.5 s in the tail read
       alone, where 5,000 rows = 33 MB and 0.65 s answer the same question. *)
    let scan_factor =
      match keeper_name with
      | None -> 1
      | Some _ -> read_over_scan_factor
    in
    let raw = read_recent_rows ~n:(n * scan_factor) () in
    let keep =
      match keeper_name with
      | None -> fun (_ : Yojson.Safe.t) -> true
      | Some name -> keeper_matches name
    in
    ring_keep_last ~n ~keep raw)
;;

let iso_date_of_unix ts = Jsonl_writer.day_key ~ts

let ts_of_entry (json : Yojson.Safe.t) : float option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "ts" fields with
     | Some (`Float f) -> Some f
     | Some (`Int i) -> Some (Float.of_int i)
     | _ -> None)
  | _ -> None
;;

(* A trailing-window file-change answer, kept between calls.

   The store is append-only per day file, so what a window gains between two
   calls is the bytes appended plus files that did not exist yet. Measured
   2026-09-06 on this workspace: a 24h window is 242MB and the busy hour
   appends about 15MB, so a caller ten seconds apart needs 0.04MB of it. The
   endpoint that reads this answered 1.8-8.8s per call and was the top
   allocator in the profile at 2.62GB of major-direct allocation.

   Held per (keeper, window) because that is what a caller asks for, and the
   tally is small: the same measurement put every file change in a 24h window
   across fifteen keepers at 3.4MB, the largest keeper at 0.8MB.

   [Keeper_tool_call_file_change.tally] carries no timestamp on its unreadable
   rows, so a folded tally cannot drop what aged out of the window. The cache
   is therefore keyed by the day range it covers: when the range moves, the
   entry is dropped and refolded. A day range moves once a day; the repeat
   this exists to remove happens within it. *)
type file_change_cache_entry =
  { fcc_since : string
  ; fcc_until : string
  ; fcc_cursors : (string * int) list
  ; fcc_tally : Keeper_tool_call_file_change.tally
  }

let file_change_cache : (string * float, file_change_cache_entry) Hashtbl.t =
  Hashtbl.create 16
;;

let file_change_cache_mu = Stdlib.Mutex.create ()

let reset_file_change_cache_for_testing () =
  Stdlib.Mutex.protect file_change_cache_mu (fun () -> Hashtbl.reset file_change_cache)
;;

let file_change_tally ?keeper_name ~(window_hours : float) () =
  if window_hours <= 0.0
  then Keeper_tool_call_file_change.empty_tally
  else (
    match (Atomic.get store_state).store with
    | None -> Keeper_tool_call_file_change.empty_tally
    | Some store ->
      let now = Time_compat.now () in
      let since_ts = now -. (window_hours *. Masc_time_constants.hour) in
      let since = iso_date_of_unix since_ts in
      let until = iso_date_of_unix now in
      let key = Option.value keeper_name ~default:"", window_hours in
      Stdlib.Mutex.protect file_change_cache_mu (fun () ->
        let carried =
          match Hashtbl.find_opt file_change_cache key with
          | Some entry
            when String.equal entry.fcc_since since
                 && String.equal entry.fcc_until until -> Some entry
          | Some _ | None -> None
        in
        let cursors, tally =
          match carried with
          | Some entry -> entry.fcc_cursors, entry.fcc_tally
          | None -> [], Keeper_tool_call_file_change.empty_tally
        in
        let tally, cursors =
          Dated_jsonl.fold_range_appended
            store
            ~since
            ~until
            ~cursors
            ~init:tally
            ~f:(fun tally json ->
              let in_window =
                match ts_of_entry json with
                | Some ts -> ts >= since_ts
                | None -> false
              in
              let keeper_ok =
                match keeper_name with
                | None -> true
                | Some name -> keeper_matches name json
              in
              if in_window && keeper_ok
              then Keeper_tool_call_file_change.fold_row tally json
              else tally)
        in
        Hashtbl.replace
          file_change_cache
          key
          { fcc_since = since; fcc_until = until; fcc_cursors = cursors; fcc_tally = tally };
        Keeper_tool_call_file_change.seal_tally tally))
;;

let read_window ?keeper_name ~(window_hours : float) () : Yojson.Safe.t list =
  if window_hours <= 0.0
  then []
  else (
    match (Atomic.get store_state).store with
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
  match (Atomic.get store_state).store with
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
