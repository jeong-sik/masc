(* keeper_keepalive_signal — gRPC client refs, FSM guard identity helpers,
   interruptible sleep, wakeup dispatch, board-reactive wakeup filtering,
   stage_timing type, event dispatch helpers.

   Extracted from keeper_keepalive.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_execution

module Board_wake = Keeper_world_observation_board_signal
module Board_signal_outbox = Masc_board_handlers.Board_signal_outbox

type grpc_heartbeat_starter_fn = {
  f : 'a. ctx:'a context -> m:keeper_meta -> stop:bool Atomic.t -> (unit -> unit) option;
}

let grpc_heartbeat_starter_fn : grpc_heartbeat_starter_fn Atomic.t =
  Atomic.make { f = (fun ~ctx:_ ~m:_ ~stop:_ -> None) }

let register_grpc_heartbeat_starter (f : grpc_heartbeat_starter_fn) =
  Atomic.set grpc_heartbeat_starter_fn f
;;

let grpc_heartbeat_starter ~ctx ~m ~stop =
  (Atomic.get grpc_heartbeat_starter_fn).f ~ctx ~m ~stop

let record_wake_payload_callback
    : (keeper_name:string ->
       trace_id:string ->
       turn_index:int ->
       context_window:int ->
       system_prompt_bytes:int ->
       tool_schema_json_bytes:int ->
       message_content_bytes:int ->
       message_count:int ->
       role_counts:(string * int) list ->
       tool_count:int ->
       unit)
      Atomic.t
  =
  Atomic.make
    (fun ~keeper_name
      ~trace_id:_
      ~turn_index:_
      ~context_window:_
      ~system_prompt_bytes:_
      ~tool_schema_json_bytes:_
      ~message_content_bytes:_
      ~message_count:_
      ~role_counts:_
      ~tool_count:_ ->
      Log.Keeper.warn "wake-payload observer unavailable: keeper=%s" keeper_name)

let record_wake_payload
    ~keeper_name
    ~trace_id
    ~turn_index
    ~context_window
    ~system_prompt_bytes
    ~tool_schema_json_bytes
    ~message_content_bytes
    ~message_count
    ~role_counts
    ~tool_count
  =
  (Atomic.get record_wake_payload_callback)
    ~keeper_name
    ~trace_id
    ~turn_index
    ~context_window
    ~system_prompt_bytes
    ~tool_schema_json_bytes
    ~message_content_bytes
    ~message_count
    ~role_counts
    ~tool_count
;;

let register_record_wake_payload f = Atomic.set record_wake_payload_callback f

let record_tool_skipped_callback
    : (keeper_name:string -> tool_name:string -> reason_code:string -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~tool_name:_ ~reason_code:_ -> ())

let record_tool_skipped ~keeper_name ~tool_name ~reason_code =
  (Atomic.get record_tool_skipped_callback) ~keeper_name ~tool_name ~reason_code
;;

let register_record_tool_skipped f = Atomic.set record_tool_skipped_callback f

let record_execute_output_callback
    : (keeper_name:string ->
       task_id:string option ->
       stdout:string ->
       stderr:string ->
       status:Yojson.Safe.t ->
       streamed:bool ->
       unit)
      Atomic.t
  =
  Atomic.make
    (fun ~keeper_name:_ ~task_id:_ ~stdout:_ ~stderr:_ ~status:_ ~streamed:_ -> ())

let record_execute_output ~keeper_name ~task_id ~stdout ~stderr ~status ~streamed =
  (Atomic.get record_execute_output_callback)
    ~keeper_name
    ~task_id
    ~stdout
    ~stderr
    ~status
    ~streamed
;;

let register_record_execute_output f = Atomic.set record_execute_output_callback f

let record_execute_stream_chunk_callback
    : (keeper_name:string -> stream:[ `Stdout | `Stderr ] -> string -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~stream:_ _chunk -> ())

let record_execute_stream_chunk ~keeper_name ~stream chunk =
  (Atomic.get record_execute_stream_chunk_callback) ~keeper_name ~stream chunk
;;

let register_record_execute_stream_chunk f =
  Atomic.set record_execute_stream_chunk_callback f

let record_execute_stream_start_callback
    : (keeper_name:string -> task_id:string option -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~task_id:_ -> ())

let record_execute_stream_start ~keeper_name ~task_id =
  (Atomic.get record_execute_stream_start_callback) ~keeper_name ~task_id
;;

let register_record_execute_stream_start f =
  Atomic.set record_execute_stream_start_callback f

let record_execute_stream_end_callback
    : (keeper_name:string -> task_id:string option -> status:Yojson.Safe.t -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~task_id:_ ~status:_ -> ())

let record_execute_stream_end ~keeper_name ~task_id ~status =
  (Atomic.get record_execute_stream_end_callback) ~keeper_name ~task_id ~status
;;

let register_record_execute_stream_end f = Atomic.set record_execute_stream_end_callback f

(* Skip log throttle removed with manual_reconcile blocker — no more
   sticky reconcile state means no flood of "reconcile pending" skip logs. *)

let format_since_last_scheduled_autonomous = function
  | Some s when s = max_int -> "never"
  | Some s -> string_of_int s
  | None -> "-"

(* ── KeeperHeartbeat.tla spec-action runtime guards (Cycle 43) ────────

   Identity helpers carrying [@@fsm_guard] payloads that mirror the
   honest actions of [specs/keeper-state-machine/KeeperHeartbeat.tla].
   Each helper is wrapped at the call site by
   [Keeper_fsm_guard_runtime.wrap_unit], so an [Assert_failure] from a
   PPX-injected guard increments the Otel_metric_store violation counter and
   re-raises. The bug-action [MissedWakeup] is
   intentionally NOT instrumented — it is the failure mode these guards
   are designed to detect, not to enforce. *)

(* Heartbeat turn lifecycle flag, mirroring KeeperHeartbeat.tla's
   [turn_state] in the {"idle", "running"} alphabet. Read inside
   identity helpers; written by the caller around [run_heartbeat_loop]
   and the dispatch sites. Single-fiber by construction — only the
   keeper's own heartbeat loop touches its [turn_running] ref. *)
let pre_turn_complete_heartbeat ~(turn_running : bool ref) = ignore turn_running
  [@@fsm_guard "!turn_running = true"]

let post_turn_complete_heartbeat ~(turn_running : bool ref) = ignore turn_running
  [@@fsm_guard "!turn_running = false"]

(* WakeupSignal: external code sets the wakeup atomic to TRUE. Spec
   says the post-condition is [wakeup_signaled = TRUE]. The OCaml
   [Atomic.set] is idempotent so the assert is trivially true on the
   honest path; the guard catches a regression where someone replaces
   [Atomic.set ... true] with [Atomic.set ... false] or forgets the
   set entirely. *)
let post_wakeup_signal ~(wakeup : bool Atomic.t) = ignore wakeup
  [@@fsm_guard "Atomic.get wakeup = true"]

(* SubmitTask (KeeperTaskAcquisition.tla, Cycle 44): an external
   producer (operator directive in this case) attaches a task_id to the
   keeper's [current_task_id]. The post-action invariant is that the
   meta carries the assigned id after [persist_directive_meta_update]
   returns. The honest path is trivially true; the guard catches a
   regression where someone updates [persist_directive_meta_update] to
   skip the [current_task_id] field or persist a different id. *)
let post_submit_task ~(meta : keeper_meta) ~(task_id : Keeper_id.Task_id.t) =
  ignore meta; ignore task_id
  [@@fsm_guard "meta.current_task_id = Some task_id"]

(* HeartbeatTick: the [compare_and_set wakeup true false] in
   [interruptible_sleep] succeeded — wakeup transitioned TRUE -> FALSE
   and the sleep returned so the loop can dispatch. Spec post-condition
   is [wakeup_signaled = FALSE]. False-positive risk: a producer that
   re-sets the atomic to TRUE between the CAS and this read would make
   the guard fire. The [interruptible_sleep] body is single-fiber and
   the only producer is external, so the window is one tick and the
   counter signal is operationally meaningful — a non-zero count means
   producers are racing the consumer, which is itself a bug class. *)
let post_heartbeat_tick ~(wakeup : bool Atomic.t) = ignore wakeup
  [@@fsm_guard "Atomic.get wakeup = false"]

type sleep_outcome =
  | Stopped
  | Woken
  | Timeout

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
let interruptible_sleep ~clock ~stop ~wakeup duration : sleep_outcome =
  let chunk_sec = Env_config.KeeperKeepalive.sleep_chunk_sec in
  let rec wait remaining =
    if Atomic.get stop
    then Stopped
    else if (* Spec: KeeperHeartbeat.tla HeartbeatTick action — wakeup is
              consumed (TRUE -> FALSE) and the caller's next loop iteration
              dispatches the exact Keeper lane. *)
            Atomic.compare_and_set wakeup true false
    then (
      (* Cycle 43: post-action guard mirrors the spec's [wakeup_signaled =
         FALSE] postcondition. The [@@fsm_guard] PPX routes the
         assertion through [wrap_unit ~stage:"guard"] automatically. *)
      post_heartbeat_tick ~wakeup;
      Woken)
    else if remaining <= 0.0
    then Timeout
    else (
      let chunk = Float.min chunk_sec remaining in
      Eio.Time.sleep clock chunk;
      wait (remaining -. chunk))
  in
  wait duration
;;

(** Wake up a specific keeper immediately, causing it to skip the rest of
    its sleep and run the next heartbeat cycle. Used by broadcast notification
    when a @mention targets a running keeper.

    When [?stimulus] is provided, the stimulus is appended to the keeper's
    Event Layer queue ([Keeper_registry_event_queue.enqueue]) before the wakeup
    flag flips. This is RFC-0020 Rule 1 (enqueue is independent of policy)
    + the data-channel half of the layer split — [fiber_wakeup] remains the
    Running-lane hint signal, the queue is the authoritative payload. *)
let wakeup_keeper ?base_path ?stimulus name =
  let entries =
    Keeper_registry.all ?base_path ()
    |> List.filter (fun (entry : Keeper_registry.registry_entry) ->
         String.equal entry.name name)
  in
  (* Payload admission is independent of current lifecycle phase. A completion
     that arrives while the keeper is paused/restarting must remain durable for
     the lane's next admitted turn; the wake hint delegates to the typed
     Running-lane and lifecycle admission contract. *)
  (match entries, stimulus, base_path with
   | [], Some value, Some resolved_base_path ->
     Keeper_registry_event_queue.enqueue
       ~base_path:resolved_base_path
       name
       value;
     Log.Keeper.info ~keeper_name:name
       "wakeup_keeper: stimulus queued without live registry entry stimulus=%s"
       (Keeper_event_queue.payload_kind_label value.Keeper_event_queue.payload)
   | [], Some value, None ->
     Log.Keeper.error ~keeper_name:name
       "wakeup_keeper: cannot persist stimulus without registry entry or base_path \
        stimulus=%s"
       (Keeper_event_queue.payload_kind_label value.Keeper_event_queue.payload)
   | [], None, _ | _ :: _, _, _ -> ());
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       Option.iter
         (fun value ->
            Keeper_registry_event_queue.enqueue
              ~base_path:entry.base_path
              name
              value)
         stimulus;
       match
         Keeper_registry.wakeup_running
           ~intent:Keeper_registry.Reactive_signal
           ~base_path:entry.base_path
           name
       with
       | Keeper_registry.Signaled -> ()
       | Keeper_registry.Deferred_unregistered ->
         Log.Keeper.info ~keeper_name:name
           "wakeup_keeper: wake deferred after registry removal"
       | Keeper_registry.Deferred_not_running phase ->
         Log.Keeper.info ~keeper_name:name
           "wakeup_keeper: wake deferred by registry phase contract phase=%s"
           (Keeper_state_machine.phase_to_string phase)
       | Keeper_registry.Deferred_lifecycle denial ->
         Log.Keeper.info ~keeper_name:name
           "wakeup_keeper: wake deferred by lifecycle reason=%s"
           (Keeper_lifecycle_admission.autonomous_denial_to_wire denial))
    entries
;;

(** Wake up all running keepers — used when a broadcast mentions @@all
    or when a system-wide event requires immediate attention.
    [None] preserves the legacy global wakeup behavior. *)
let wakeup_all_keepers ?base_path () =
  match base_path with
  | None -> Keeper_registry.wakeup_all ~intent:Keeper_registry.Broadcast_signal ()
  | Some expected ->
    Keeper_registry.wakeup_all
      ~intent:Keeper_registry.Broadcast_signal
      ~base_path:expected
      ()

(* RFC-0020: enqueue the board signal as a typed [stimulus_payload] (PR-1).
   [reason] is the typed {!Board_wake.wake_reason} that selected this keeper;
   here it only picks urgency (explicit mentions are [Immediate]). It is not
   carried in the payload — the next prompt re-derives board context from the
   typed [Board_signal] payload, not from a wake-reason string. *)
let queue_reaction_target_of_board = function
  | Board.Reaction_post -> Keeper_event_queue.Reaction_post
  | Board.Reaction_comment -> Keeper_event_queue.Reaction_comment
;;

let queue_reaction_change_of_board
      (reaction : Board_dispatch.board_reaction_change)
  : Keeper_event_queue.board_reaction_change
  =
  { target_type = queue_reaction_target_of_board reaction.target_type
  ; target_id = reaction.target_id
  ; user_id = reaction.user_id
  ; emoji = reaction.emoji
  ; reacted = reaction.reacted
  }
;;

let board_signal_stimulus
      ~routing_event_id
      ~(reason : Board_wake.wake_reason)
      (signal : Board_dispatch.board_signal)
  =
  let payload : Keeper_event_queue.stimulus_payload =
    Keeper_event_queue.Board_signal
      { kind =
          (match signal.kind with
           | Board_dispatch.Board_post_created -> Keeper_event_queue.Post_created
           | Board_dispatch.Board_comment_added -> Keeper_event_queue.Comment_added
           | Board_dispatch.Board_reaction_changed reaction ->
             Keeper_event_queue.Reaction_changed (queue_reaction_change_of_board reaction))
      ; routing_event_id = Some routing_event_id
      ; author = signal.author
      ; title = signal.title
      ; content = signal.content
      ; hearth = signal.hearth
      ; updated_at = signal.updated_at
      }
  in
  { Keeper_event_queue.post_id = signal.post_id
  ; urgency =
      (match reason with
       | Board_wake.Explicit_mention -> Keeper_event_queue.Immediate
       | Board_wake.Broadcast -> Keeper_event_queue.Immediate
       | Board_wake.Thread_reply_after_self_comment
       | Board_wake.Reaction_after_self_activity ->
         Keeper_event_queue.Normal)
  ; arrived_at = Time_compat.now ()
  ; payload
  }
;;

type board_delivery_entry =
  { base_path : string
  ; name : string
  ; meta : keeper_meta
  }

let board_delivery_entry_compare left right = String.compare left.name right.name

let board_delivery_entry_is_terminal entry =
  match entry.meta.latched_reason with
  | Some Keeper_latched_reason.Dead_tombstone -> true
  | Some _ | None ->
    (match Keeper_registry.get ~base_path:entry.base_path entry.name with
     | Some live -> Keeper_state_machine.is_terminal live.phase
     | None -> false)
;;

let canonical_board_delivery_entries entries =
  entries
  |> List.filter (fun entry -> not (board_delivery_entry_is_terminal entry))
  |> List.sort_uniq board_delivery_entry_compare
;;

let read_board_delivery_entry config name =
  Result.bind (Keeper_meta_store.read_effective_meta config name) (function
    | Some meta -> Ok (Some { base_path = config.Workspace.base_path; name = meta.name; meta })
    | None -> Ok None)
;;

let all_durable_board_delivery_entries config =
  let ( let* ) = Result.bind in
  let* persisted_names = Keeper_meta_store.keeper_names_result config in
  let configured_names = Keeper_meta_store.configured_keeper_names config in
  let unmaterialized =
    List.filter
      (fun name -> not (List.exists (String.equal name) persisted_names))
      configured_names
  in
  if unmaterialized <> []
  then
    Error
      (Printf.sprintf
         "Board recipient authority is not materialized for configured Keepers: %s"
         (String.concat "," unmaterialized))
  else
    let rec read acc = function
      | [] -> Ok (canonical_board_delivery_entries (List.rev acc))
      | name :: rest ->
        let* entry = read_board_delivery_entry config name in
        (match entry with
         | Some entry -> read (entry :: acc) rest
         | None ->
           Error
             (Printf.sprintf
                "Board recipient metadata disappeared during authority read: keeper=%s"
                name))
    in
    read [] persisted_names
;;

let board_delivery_entries_for_audience config audience =
  match audience with
  | Board_signal_audience.Targets identities ->
    let configured_names = Keeper_meta_store.configured_keeper_names config in
    let rec exact acc unresolved = function
      | [] -> Ok (List.rev acc, List.rev unresolved)
      | identity :: rest ->
        Result.bind (read_board_delivery_entry config identity) (function
          | Some entry -> exact (entry :: acc) unresolved rest
          | None when List.exists (String.equal identity) configured_names ->
            Error
              (Printf.sprintf
                 "Board target metadata is not materialized: target=%s"
                 identity)
          | None -> exact acc (identity :: unresolved) rest)
    in
    Result.bind (exact [] [] identities) (fun (exact_entries, unresolved) ->
      if unresolved = []
      then Ok (canonical_board_delivery_entries exact_entries)
      else
        Result.map
          (fun all -> canonical_board_delivery_entries (exact_entries @ all))
          (all_durable_board_delivery_entries config))
  | Board_signal_audience.Broadcast
  | Board_signal_audience.Discoverable
  | Board_signal_audience.Thread_participants _ ->
    all_durable_board_delivery_entries config
;;

let retirement_reason_for_missing_entry config keeper_name =
  Result.bind (Keeper_meta_store.read_effective_meta config keeper_name) (function
    | Some meta ->
      let durable_terminal =
        match meta.latched_reason with
        | Some Keeper_latched_reason.Dead_tombstone -> true
        | Some _ | None -> false
      in
      let live_terminal =
        match Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name with
        | Some entry -> Keeper_state_machine.is_terminal entry.phase
        | None -> false
      in
      if durable_terminal || live_terminal
      then Ok Board_signal_outbox.Keeper_terminal
      else
        Error
          (Printf.sprintf
             "Board recipient is absent from an authority snapshot but remains eligible: keeper=%s"
             keeper_name)
    | None ->
      if
        List.exists
          (String.equal keeper_name)
          (Keeper_meta_store.configured_keeper_names config)
      then
        Error
          (Printf.sprintf
             "Board recipient metadata is not materialized: keeper=%s"
             keeper_name)
      else Ok Board_signal_outbox.Keeper_metadata_removed)
;;

let record_board_attention_candidate
      ~(config : Workspace.config)
      ~routing_event_id
      ~(signal_kind_label : string)
      ~(meta : keeper_meta)
      (signal : Board_dispatch.board_signal)
  =
  match
    Keeper_board_attention_candidate.of_board_signal
      ~meta
      ~routing_event_id
      ~recorded_at:(Time_compat.now ())
      signal
  with
  | Keeper_world_observation_board_signal.Unavailable unavailable ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string KeepaliveSignalFailures)
      ~labels:[ ("keeper", meta.name); ("phase", "board_attention_evidence_read") ]
      ();
    Log.Keeper.warn
      "board attention evidence unavailable: keeper=%s post=%s error=%s"
      meta.name
      signal.post_id
      (Keeper_world_observation_board_signal.unavailable_to_string unavailable);
    Error (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
  | Keeper_world_observation_board_signal.Available candidate ->
    (match
       Keeper_board_attention_worker.record_and_notify
         ~base_path:config.base_path
         candidate
     with
     | Ok _ ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string BoardSignalAttentionCandidateTotal)
         ~labels:[ ("keeper", meta.name); ("kind", signal_kind_label) ]
         ();
       Ok ()
     | Error err ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string KeepaliveSignalFailures)
         ~labels:
           [ ("keeper", meta.name); ("phase", "board_attention_candidate_record") ]
         ();
       Log.Keeper.warn
         "board attention candidate record failed: keeper=%s post=%s error=%s"
         meta.name
         signal.post_id
         err;
       Error err)
;;

let deliver_addressed_board_signal
      ~(config : Workspace.config)
      ~routing_event_id
      ~(reason : Board_wake.wake_reason)
      ~(signal : Board_dispatch.board_signal)
      ~keeper_name
  =
  let stimulus = board_signal_stimulus ~routing_event_id ~reason signal in
  match
    Keeper_registry_event_queue.enqueue_stimulus_durable_result
      ~base_path:config.base_path
      keeper_name
      stimulus
  with
  | Keeper_registry_event_queue.Stimulus_enqueued
  | Keeper_registry_event_queue.Stimulus_already_present -> Ok ()
  | Keeper_registry_event_queue.Stimulus_storage_error detail -> Error detail
;;

let keeper_ids identities =
  identities
  |> List.filter_map Keeper_identity.Keeper_id.of_string
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

let entry_matches_target_identity entry target_identity
  =
  match Keeper_identity.Keeper_id.of_string target_identity with
  | None -> false
  | Some target_id ->
    let delivery_ids =
      Keeper_world_observation_message_scope.message_feed_targets entry.meta
      |> Keeper_lane_mentions.target_ids_of
    in
    List.exists (Keeper_identity.Keeper_id.equal target_id) delivery_ids
;;

let entry_matches_participant_identities participant_ids entry
  =
  let self_ids = Keeper_world_observation_message_scope.self_ids entry.meta in
  List.exists
    (fun participant ->
       List.exists (Keeper_identity.Keeper_id.equal participant) self_ids)
    participant_ids
;;

let dedupe_registry_entries entries =
  entries
  |> List.sort board_delivery_entry_compare
  |> List.sort_uniq board_delivery_entry_compare
;;

let resolve_target_entry registry_entries identity =
  match
    List.filter
      (fun entry -> entry_matches_target_identity entry identity)
      registry_entries
  with
  | [] -> Error (Printf.sprintf "Board target has no Keeper lane: %s" identity)
  | [ entry ] -> Ok entry
  | matches ->
    Error
      (Printf.sprintf
         "Board target resolves to multiple Keeper lanes: target=%s lanes=%s"
         identity
         (String.concat
            ","
            (List.map
               (fun entry -> entry.name)
               matches)))
;;

let addressed_entries_for_audience registry_entries audience signal =
  match audience with
  | Board_signal_audience.Targets _ ->
    Error "Target identities must be resolved as independent delivery units"
  | Board_signal_audience.Broadcast ->
    Ok (List.map (fun entry -> entry, Board_wake.Broadcast) registry_entries)
  | Board_signal_audience.Thread_participants identities ->
    let participant_ids = keeper_ids identities in
    let entries =
      registry_entries
      |> List.filter (entry_matches_participant_identities participant_ids)
      |> dedupe_registry_entries
    in
    (match signal.Board_dispatch.kind with
     | Board_dispatch.Board_comment_added ->
       Ok
         (List.map
            (fun entry -> entry, Board_wake.Thread_reply_after_self_comment)
            entries)
     | Board_dispatch.Board_reaction_changed _ ->
       Ok
         (List.map
            (fun entry -> entry, Board_wake.Reaction_after_self_activity)
            entries)
     | Board_dispatch.Board_post_created ->
       Error "Board post-created signal cannot have Thread_participants audience")
  | Board_signal_audience.Discoverable ->
    Error "Discoverable Board audience is not deterministic delivery"
;;

let addressed_reason_for_audience audience signal =
  match audience with
  | Board_signal_audience.Targets _ -> Ok Board_wake.Explicit_mention
  | Board_signal_audience.Broadcast -> Ok Board_wake.Broadcast
  | Board_signal_audience.Thread_participants _ ->
    (match signal.Board_dispatch.kind with
     | Board_dispatch.Board_comment_added ->
       Ok Board_wake.Thread_reply_after_self_comment
     | Board_dispatch.Board_reaction_changed _ ->
       Ok Board_wake.Reaction_after_self_activity
     | Board_dispatch.Board_post_created ->
       Error "Board post-created signal cannot have Thread_participants audience")
  | Board_signal_audience.Discoverable ->
    Error "Discoverable Board audience has no addressed wake reason"
;;

let rec traverse_recipients make acc = function
  | [] -> Ok (List.rev acc)
  | value :: rest ->
    Result.bind (make value) (fun recipient ->
      traverse_recipients make (recipient :: acc) rest)
;;

let delivery_units_for_audience registry_entries audience signal =
  match audience with
  | Board_signal_audience.Targets identities ->
    traverse_recipients Board_signal_outbox.target_identity [] identities
  | Board_signal_audience.Discoverable ->
    traverse_recipients
      Board_signal_outbox.keeper_lane
      []
      (List.map
	      (fun entry -> entry.name)
         registry_entries)
  | Board_signal_audience.Broadcast
  | Board_signal_audience.Thread_participants _ ->
    Result.bind
      (addressed_entries_for_audience registry_entries audience signal)
      (fun entries ->
         traverse_recipients
           Board_signal_outbox.keeper_lane
           []
           (List.map
	              (fun (entry, _reason) -> entry.name)
              entries))
;;

let wakeup_relevant_keeper_for_board_signal
      ~(config : Workspace.config)
      ({ event_id = routing_event_id; audience; signal } :
        Board_dispatch.board_signal_event)
  =
  let signal_kind_label =
    match signal.kind with
    | Board_dispatch.Board_post_created -> "post_created"
    | Board_dispatch.Board_comment_added -> "comment_added"
    | Board_dispatch.Board_reaction_changed _ -> "reaction_changed"
  in
  let board_ym = Eio_guard.create_yield_meter () in
  let fail ~keeper ~phase detail =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string KeepaliveSignalFailures)
      ~labels:[ "keeper", keeper; "phase", phase ]
      ();
    Log.Keeper.warn
      "board signal lane failed: event_id=%s keeper=%s phase=%s post=%s error=%s"
      routing_event_id
      keeper
      phase
      signal.post_id
      detail;
    Error (Printf.sprintf "keeper=%s phase=%s error=%s" keeper phase detail)
  in
  Result.bind (board_delivery_entries_for_audience config audience) (fun registry_entries ->
  let registry_entry recipient =
    List.find_opt
      (fun entry -> String.equal entry.name recipient)
      registry_entries
  in
  let process_addressed_recipient entry (reason : Board_wake.wake_reason) =
    let recipient = entry.name in
    try
      match
        deliver_addressed_board_signal
          ~config
          ~routing_event_id
          ~reason
          ~signal
          ~keeper_name:recipient
      with
      | Error detail -> fail ~keeper:recipient ~phase:"board_signal_delivery" detail
      | Ok () ->
        let paused =
          entry.meta.paused
          || match Keeper_registry.get ~base_path:config.base_path recipient with
             | Some live -> live.phase = Keeper_state_machine.Paused
             | None -> false
        in
        if paused
        then
          Log.Keeper.info
            "board signal queued for paused Keeper: keeper=%s reason=%s post=%s"
            recipient
            (Board_wake.wake_reason_label reason)
            signal.post_id
        else (
          let outcome =
            Keeper_registry.wakeup_running
              ~intent:Keeper_registry.Reactive_signal
              ~base_path:config.base_path
              recipient
          in
          match outcome with
          | Keeper_registry.Signaled ->
            Log.Keeper.info
              "board signal wakeup: keeper=%s reason=%s post=%s"
              recipient
              (Board_wake.wake_reason_label reason)
              signal.post_id
          | Keeper_registry.Deferred_unregistered
          | Keeper_registry.Deferred_not_running _
          | Keeper_registry.Deferred_lifecycle _ ->
            Log.Keeper.info
              "board signal durably queued; live wake deferred: keeper=%s reason=%s post=%s"
              recipient
              (Board_wake.wake_reason_label reason)
              signal.post_id);
        Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      fail
        ~keeper:recipient
        ~phase:"board_lane_failure"
        (Printexc.to_string exn)
  in
  let process_discoverable_recipient entry =
    Result.map_error
      (fun detail ->
         Printf.sprintf
           "keeper=%s phase=board_attention_candidate_record error=%s"
           entry.name
           detail)
      (record_board_attention_candidate
         ~config
         ~routing_event_id
         ~signal_kind_label
         ~meta:entry.meta
         signal)
  in
  let ensure_recipient_plan () =
    match Board_signal_outbox.recipient_progress ~event_id:routing_event_id with
    | Error _ as error -> error
    | Ok Board_signal_outbox.Recipients_unplanned ->
      Result.bind
        (delivery_units_for_audience registry_entries audience signal)
        (fun recipients ->
           Result.bind
             (Board_signal_outbox.plan_recipients
                ~event_id:routing_event_id
                ~recipients)
             (fun () ->
                Board_signal_outbox.recipient_progress ~event_id:routing_event_id))
    | Ok progress -> Ok progress
  in
  Result.bind (ensure_recipient_plan ()) (fun progress ->
  let recipients =
    match progress with
    | Board_signal_outbox.Recipients_unplanned -> []
    | Board_signal_outbox.Recipients_pending recipients -> recipients
    | Board_signal_outbox.Recipients_settled -> []
  in
  let addressed_reason = addressed_reason_for_audience audience signal in
  let process_recipient recipient =
    let retire_missing keeper_name phase =
      Result.bind
        (retirement_reason_for_missing_entry config keeper_name)
        (fun reason ->
           Log.Keeper.warn
             "board signal recipient retired: event_id=%s keeper=%s phase=%s post=%s"
             routing_event_id
             keeper_name
             phase
             signal.post_id;
           Result.map
             (fun () -> `Terminalized)
             (Board_signal_outbox.retire_recipient
                ~event_id:routing_event_id
                ~recipient
                ~reason))
    in
    match recipient, audience with
    | ( Board_signal_outbox.Target_identity { identity; keeper_name = None }
      , Board_signal_audience.Targets _ ) ->
      (match resolve_target_entry registry_entries identity with
       | Error detail ->
         ignore
           (fail ~keeper:identity ~phase:"board_target_resolution" detail
             : (unit, string) result);
         Result.map
           (fun () -> `Terminalized)
           (Board_signal_outbox.reject_target
              ~event_id:routing_event_id
              ~identity)
       | Ok entry ->
         Result.bind
           (Board_signal_outbox.resolve_target
              ~event_id:routing_event_id
              ~identity
              ~keeper_name:entry.name)
           (fun resolved ->
              Result.map
                (fun () -> `Settle resolved)
                (process_addressed_recipient
                   entry
                   Board_wake.Explicit_mention)))
    | ( Board_signal_outbox.Target_identity
          { identity = _; keeper_name = Some keeper_name }
      , Board_signal_audience.Targets _ ) ->
      (match registry_entry keeper_name with
       | None -> retire_missing keeper_name "board_target_recipient_retired"
       | Some entry ->
         Result.map
           (fun () -> `Settle recipient)
           (process_addressed_recipient entry Board_wake.Explicit_mention))
    | Board_signal_outbox.Keeper_lane keeper_name, Board_signal_audience.Discoverable ->
      (match registry_entry keeper_name with
       | None -> retire_missing keeper_name "board_attention_recipient_retired"
       | Some entry ->
         Result.map
           (fun () -> `Settle recipient)
           (process_discoverable_recipient entry))
    | ( Board_signal_outbox.Keeper_lane keeper_name
      , (Board_signal_audience.Broadcast
        | Board_signal_audience.Thread_participants _) ) ->
      (match registry_entry keeper_name with
       | None -> retire_missing keeper_name "board_addressed_recipient_retired"
       | Some entry ->
         Result.bind addressed_reason (fun reason ->
           Result.map
             (fun () -> `Settle recipient)
             (process_addressed_recipient entry reason)))
    | Board_signal_outbox.Keeper_lane _, Board_signal_audience.Targets _
    | Board_signal_outbox.Target_identity _, Board_signal_audience.Discoverable
    | Board_signal_outbox.Target_identity _, Board_signal_audience.Broadcast
    | ( Board_signal_outbox.Target_identity _
      , Board_signal_audience.Thread_participants _ ) ->
      Error "Board audience and durable recipient kind disagree"
  in
  let failures =
    List.fold_left
      (fun failures recipient ->
         let result = process_recipient recipient in
         let result =
           Result.bind result (function
             | `Terminalized -> Ok ()
             | `Settle settled_recipient ->
               Board_signal_outbox.settle_recipient
                 ~event_id:routing_event_id
                 ~recipient:settled_recipient)
         in
         Eio_guard.yield_step board_ym;
         match result with
         | Ok () -> failures
         | Error detail -> detail :: failures)
      []
      recipients
  in
  match failures with
  | [] -> Ok ()
  | _ -> Error (String.concat "; " (List.rev failures))))
;;

(* Per-stage timing accumulator for Phase 0 profiling.
   In-memory ring of last 100 cycles. Flushed as aggregate at snapshot cadence.
   No additional file I/O — appended to existing snapshot JSON. *)
type stage_timing =
  { presence_ms : float
  ; snapshot_ms : float
  ; board_ms : float
  ; turn_ms : float
  }

let stage_timing_ring_size () =
  Runtime_params.get Runtime_settings.keeper_stage_timing_ring_size
;;

let percentile arr p =
  let n = Array.length arr in
  if n = 0
  then 0.0
  else (
    let sorted = Array.copy arr in
    Array.sort Float.compare sorted;
    let idx = Float.to_int (Float.round (float_of_int (n - 1) *. p)) in
    sorted.(min idx (n - 1)))
;;

let stage_timing_to_json ~ring ~count =
  let n = min count (Array.length ring) in
  if n = 0
  then `Null
  else (
    let extract field =
      let arr = Array.init n (fun i -> field ring.(i)) in
      `Assoc
        [ "p50", `Float (percentile arr 0.5)
        ; "p95", `Float (percentile arr 0.95)
        ; "max", `Float (percentile arr 1.0)
        ; "samples", `Int n
        ]
    in
    `Assoc
      [ "presence", extract (fun t -> t.presence_ms)
      ; "snapshot", extract (fun t -> t.snapshot_ms)
      ; "board", extract (fun t -> t.board_ms)
      ; "turn", extract (fun t -> t.turn_ms)
      ])
;;

let keepalive_entry_accepts_late_event ~(ctx : _ context) ~(keeper_name : string) =
  match Keeper_registry.get_phase ~base_path:ctx.config.base_path keeper_name with
  | None -> true
  | Some (Keeper_state_machine.Stopped | Keeper_state_machine.Dead) -> false
  | Some _ -> true

let dispatch_keepalive_event ~(ctx : _ context) ~(keeper_name : string) event =
  if keepalive_entry_accepts_late_event ~ctx ~keeper_name then
    Keeper_registry.dispatch_event_unit
      ~base_path:ctx.config.base_path keeper_name event

let dispatch_keepalive_event_with_audit
      ~(ctx : _ context)
      ~(keeper_name : string)
      ~snapshot
      ~events_fired
      ~selected_event
      event
  =
  if keepalive_entry_accepts_late_event ~ctx ~keeper_name then
    (match Keeper_registry.dispatch_event_with_audit_and_log
       ~base_path:ctx.config.base_path
       ~snapshot
       ~events_fired
       ~selected_event
       keeper_name
       event
     with
     | Ok _ -> ()
     | Error err ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string KeepaliveSignalFailures)
           ~labels:[("keeper", keeper_name); ("site", "late_event_rejected")]
           ();
         Log.Keeper.warn
           "%s: keepalive late-event dispatch rejected: %s"
           keeper_name
           (Keeper_state_machine.transition_error_to_string err))
