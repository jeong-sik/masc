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
       model_id:string ->
       context_window:int ->
       approx_body_bytes:int ->
       system_prompt_bytes:int ->
       tool_defs_bytes:int ->
       messages_bytes:int ->
       message_count:int ->
       role_counts:(string * int) list ->
       tool_count:int ->
       has_compact_happened:bool ->
       unit)
      Atomic.t
  =
  Atomic.make
    (fun ~keeper_name:_
      ~trace_id:_
      ~turn_index:_
      ~model_id:_
      ~context_window:_
      ~approx_body_bytes:_
      ~system_prompt_bytes:_
      ~tool_defs_bytes:_
      ~messages_bytes:_
      ~message_count:_
      ~role_counts:_
      ~tool_count:_
      ~has_compact_happened:_ -> ())

let record_wake_payload
    ~keeper_name
    ~trace_id
    ~turn_index
    ~model_id
    ~context_window
    ~approx_body_bytes
    ~system_prompt_bytes
    ~tool_defs_bytes
    ~messages_bytes
    ~message_count
    ~role_counts
    ~tool_count
    ~has_compact_happened
  =
  (Atomic.get record_wake_payload_callback)
    ~keeper_name
    ~trace_id
    ~turn_index
    ~model_id
    ~context_window
    ~approx_body_bytes
    ~system_prompt_bytes
    ~tool_defs_bytes
    ~messages_bytes
    ~message_count
    ~role_counts
    ~tool_count
    ~has_compact_happened
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
    hint signal, the queue is the authoritative payload. *)
let wakeup_keeper ?base_path ?stimulus name =
  let entries =
    Keeper_registry.all ?base_path ()
    |> List.filter (fun (entry : Keeper_registry.registry_entry) ->
         String.equal entry.name name)
  in
  (* Payload admission is independent of current lifecycle phase. A completion
     that arrives while the keeper is paused/restarting must remain durable for
     the lane's next admitted turn; only the wake hint is phase-gated. *)
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
       if entry.phase = Keeper_state_machine.Running
       then (
         match
           Keeper_registry.wakeup
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
             "wakeup_keeper: wake deferred after phase change phase=%s"
             (Keeper_state_machine.phase_to_string phase)
         | Keeper_registry.Deferred_lifecycle denial ->
           Log.Keeper.info ~keeper_name:name
             "wakeup_keeper: wake deferred by lifecycle reason=%s"
             (Keeper_lifecycle_admission.autonomous_denial_to_wire denial))
       else
         Log.Keeper.info ~keeper_name:name
           "wakeup_keeper: stimulus queued; wake hint withheld phase=%s stimulus=%s"
           (Keeper_state_machine.phase_to_string entry.phase)
           (match stimulus with
            | None -> "none"
            | Some value ->
              Keeper_event_queue.payload_kind_label value.Keeper_event_queue.payload))
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
       | Board_wake.Thread_reply_after_self_comment
       | Board_wake.Reaction_after_self_activity ->
         Keeper_event_queue.Normal)
  ; arrived_at = Time_compat.now ()
  ; payload
  }
;;

let board_signal_entry_accepts_delivery (entry : Keeper_registry.registry_entry) =
  not (Keeper_state_machine.is_terminal entry.phase)
;;

let record_board_attention_candidate
      ~(config : Workspace.config)
      ~(signal_kind_label : string)
      ~(meta : keeper_meta)
      (signal : Board_dispatch.board_signal)
  =
  match
    Keeper_board_attention_candidate.of_board_signal
      ~meta
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
      (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
  | Keeper_world_observation_board_signal.Available candidate ->
    (match
       Keeper_board_attention_candidate.record_and_start
         ~base_path:config.base_path
         candidate
     with
     | Ok _ ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string BoardSignalAttentionCandidateTotal)
         ~labels:[ ("keeper", meta.name); ("kind", signal_kind_label) ]
         ()
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
         err)
;;

let deliver_addressed_board_signal
      ~(config : Workspace.config)
      ~(reason : Board_wake.wake_reason)
      ~(signal : Board_dispatch.board_signal)
      (meta : keeper_meta)
  =
  let stimulus = board_signal_stimulus ~reason signal in
  match
    Keeper_registry_event_queue.enqueue_stimulus_durable_result
      ~base_path:config.base_path
      meta.name
      stimulus
  with
  | Keeper_registry_event_queue.Stimulus_enqueued
  | Keeper_registry_event_queue.Stimulus_already_present -> Ok ()
  | Keeper_registry_event_queue.Stimulus_storage_error detail -> Error detail
;;

let wakeup_relevant_keeper_for_board_signal
      ~(config : Workspace.config)
      (signal : Board_dispatch.board_signal)
  =
  let registry_entries =
    Keeper_registry.all ~base_path:config.base_path ()
    |> List.filter board_signal_entry_accepts_delivery
  in
  let signal_kind_label =
    match signal.kind with
    | Board_dispatch.Board_post_created -> "post_created"
    | Board_dispatch.Board_comment_added -> "comment_added"
    | Board_dispatch.Board_reaction_changed _ -> "reaction_changed"
  in
  (* Every lane is independent: persist and signal each addressed Keeper
     without a fleet-wide cap, ordering dependency, or content debounce. *)
  let board_ym = Eio_guard.create_yield_meter () in
  List.iter
    (fun (entry : Keeper_registry.registry_entry) ->
       (try
          match read_meta config entry.name with
        | Error detail ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string KeepaliveSignalFailures)
            ~labels:[ ("keeper", entry.name); ("phase", "board_meta_read") ]
            ();
          Log.Keeper.warn
            "board signal Keeper metadata unavailable: keeper=%s error=%s"
            entry.name
            detail
        | Ok None ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string KeepaliveSignalFailures)
            ~labels:[ ("keeper", entry.name); ("phase", "board_meta_missing") ]
            ();
          Log.Keeper.warn
            "board signal Keeper metadata missing: keeper=%s"
            entry.name
        | Ok (Some meta) ->
          (match
             Keeper_world_observation.board_signal_wake_reason
               ~meta
               ~signal
           with
           | Keeper_world_observation_board_signal.Unavailable unavailable ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string KeepaliveSignalFailures)
               ~labels:[ ("keeper", meta.name); ("phase", "board_signal_read") ]
               ();
             Log.Keeper.warn
               "board signal relevance read unavailable: keeper=%s post=%s error=%s"
               meta.name
               signal.post_id
               (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
           | Keeper_world_observation_board_signal.Available None ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string BoardSignalNoWakeTotal)
               ~labels:[ ("keeper", meta.name); ("kind", signal_kind_label) ]
               ();
             record_board_attention_candidate
               ~config
               ~signal_kind_label
               ~meta
               signal
           | Keeper_world_observation_board_signal.Available (Some reason) ->
             (match deliver_addressed_board_signal ~config ~reason ~signal meta with
              | Error detail ->
                Otel_metric_store.inc_counter
                  Keeper_metrics.(to_string KeepaliveSignalFailures)
                  ~labels:
                    [ ("keeper", meta.name); ("phase", "board_signal_delivery") ]
                  ();
                Log.Keeper.warn
                  "board signal durable delivery failed: keeper=%s reason=%s post=%s error=%s"
                  meta.name
                  (Board_wake.wake_reason_label reason)
                  signal.post_id
                  detail
              | Ok () ->
                if meta.paused || entry.phase = Keeper_state_machine.Paused
                then
                  Log.Keeper.info
                    "board signal queued for paused Keeper: keeper=%s reason=%s post=%s"
                    meta.name
                    (Board_wake.wake_reason_label reason)
                    signal.post_id
                else (
                  let outcome =
                    Keeper_registry.wakeup
                      ~intent:Keeper_registry.Reactive_signal
                      ~base_path:config.base_path
                      meta.name
                  in
                  match outcome with
                  | Keeper_registry.Signaled ->
                    Log.Keeper.info
                      "board signal wakeup: keeper=%s reason=%s post=%s"
                      meta.name
                      (Board_wake.wake_reason_label reason)
                      signal.post_id
                  | Keeper_registry.Deferred_unregistered
                  | Keeper_registry.Deferred_not_running _
                  | Keeper_registry.Deferred_lifecycle _ ->
                    Log.Keeper.info
                      "board signal durably queued; live wake deferred: keeper=%s reason=%s post=%s"
                      meta.name
                      (Board_wake.wake_reason_label reason)
                      signal.post_id)))
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string KeepaliveSignalFailures)
            ~labels:[ ("keeper", entry.name); ("phase", "board_lane_failure") ]
            ();
          Log.Keeper.warn
            "board signal lane failed independently: keeper=%s post=%s error=%s"
            entry.name
            signal.post_id
            (Printexc.to_string exn));
       Eio_guard.yield_step board_ym)
    registry_entries
;;

(* Per-stage timing accumulator for Phase 0 profiling.
   In-memory ring of last 100 cycles. Flushed as aggregate at snapshot cadence.
   No additional file I/O — appended to existing snapshot JSON. *)
type stage_timing =
  { presence_ms : float
  ; snapshot_ms : float
  ; board_ms : float
  ; turn_ms : float
  ; recurring_ms : float
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
      ; "recurring", extract (fun t -> t.recurring_ms)
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
