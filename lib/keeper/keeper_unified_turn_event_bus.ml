(** Turn-scoped OAS event-bus state for [Keeper_unified_turn].

    Concurrency model: each keeper turn creates one [t]. The event-bus subscriber
    ([Agent_sdk_metrics_bridge]) pushes events from the agent-sdk event domain,
    which runs on its own Eio domain/fiber. The turn executes on a different
    domain/fiber. Therefore reads and writes of shared state ([state],
    [drain_cancel]) can interleave across domains, justifying [Atomic.t] + CAS
    rather than a simple [ref]. *)

type event_bus_state =
  { summary : Keeper_turn_runtime_budget.turn_event_bus_summary
  ; tracker : Keeper_unified_turn_types.turn_tool_event_tracker
  ; pending_tool_count : int
  }

(** Lifecycle state of the background drain fiber's cancellation handle.
    - [Inactive]: no background fiber has claimed the handle yet.
    - [Active cc]: a background fiber is running and can be cancelled via [cc].
    - [Closed]: [unsubscribe] has been called; no new background fiber may
      start and any active one must stop.

    The variant is stored under an [Atomic.t] and updated with CAS so that
    [unsubscribe] cannot miss a handle that is about to be installed by a
    freshly-forked fiber (the set-after-exchange race). *)
type drain_cancel_state =
  | Inactive
  | Active of Eio.Cancel.t
  | Closed

type event_bus_subscription =
  | No_event_bus
  | Subscribed of
      { event_bus : Agent_sdk.Event_bus.t
      ; event_bus_sub : Agent_sdk_metrics_bridge.handle
      }

type t =
  { keeper_name : string
  ; turn_id : int
  ; event_bus_subscription : event_bus_subscription Atomic.t
  ; drain_cancel : drain_cancel_state Atomic.t
  ; state : event_bus_state Atomic.t
  ; on_pending_count_change : int -> unit
  }

let create ?event_bus ?(on_pending_count_change = fun _ -> ()) ~keeper_name ~turn_id () =
  let event_bus =
    match event_bus with
    | Some _ as bus -> bus
    | None -> Keeper_event_bus.get ()
  in
  let event_bus_subscription =
    match event_bus with
    | Some event_bus ->
      Subscribed
        { event_bus
        ; event_bus_sub =
            Agent_sdk_metrics_bridge.subscribe
              ~capacity:256
              ~overflow:Agent_sdk.Event_bus.Drop_oldest
              ~purpose:"keeper_turn"
              ~filter:(Agent_sdk.Event_bus.filter_agent keeper_name)
              event_bus
        }
    | None -> No_event_bus
  in
  { keeper_name
  ; turn_id
  ; event_bus_subscription = Atomic.make event_bus_subscription
  ; drain_cancel = Atomic.make Inactive
  ; state =
      Atomic.make
        { summary = Keeper_turn_runtime_budget.empty_turn_event_bus_summary
        ; tracker = Keeper_unified_turn_types.create_turn_tool_event_tracker ()
        ; pending_tool_count = 0
        }
  ; on_pending_count_change
  }
;;

type fsm_transition =
  | Enter_awaiting
  | Leave_awaiting

(* Compute the new pending-tool count and any Streaming⇄Awaiting_tool_result
   FSM transitions implied by [events]. The transitions are returned as a list
   so the caller can emit them only after the new count has been committed
   atomically with the rest of the event-bus state. *)
let record_fsm_tool_transitions ~keeper_name ~turn_id old_count events =
  let count = ref old_count in
  let transitions = ref [] in
  List.iter
    (fun (evt : Agent_sdk.Event_bus.event) ->
       match evt.payload with
       | Agent_sdk.Event_bus.ToolCalled _ ->
         let prev = !count in
         count := prev + 1;
         if prev = 0 then transitions := Enter_awaiting :: !transitions
       | Agent_sdk.Event_bus.ToolCompleted _ ->
         let prev = !count in
         if prev > 0
         then (
           count := prev - 1;
           if prev = 1 then transitions := Leave_awaiting :: !transitions)
       | _ -> ())
    events;
  !count, List.rev !transitions
;;

let emit_fsm_transition ~keeper_name ~turn_id ~pending_count transition =
  let attempt ~from_state ~to_state =
    match
      Keeper_turn_fsm.assert_transition_allowed ~from_state ~to_state ()
    with
    | Ok _ ->
      Keeper_turn_fsm.emit_transition
        ~keeper_name
        ~turn_id
        ~prev:from_state
        to_state
    | Error violation ->
      (* The FSM is a separate channel from the event-bus counter, so a
         transition that the counter thinks should happen can be rejected by
         the FSM when another drainer has already moved the FSM. We do not
         silently ignore the drop: log the reason and bump a telemetry counter
         so operators can detect count/FSM skew. *)
      Log.Keeper.debug
        "%s: event-bus FSM transition dropped: %s -> %s (reason=%s; pending_count=%d)"
        keeper_name
        violation.from_state
        violation.to_state
        violation.reason
        pending_count;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string EventBusDrain)
        ~labels:[ "site", "emit"; "outcome", "fsm_drop" ]
        ()
  in
  match transition with
  | Enter_awaiting ->
    attempt
      ~from_state:Keeper_turn_fsm.Streaming
      ~to_state:Keeper_turn_fsm.Awaiting_tool_result
  | Leave_awaiting ->
    attempt
      ~from_state:Keeper_turn_fsm.Awaiting_tool_result
      ~to_state:Keeper_turn_fsm.Streaming
;;

let drain ?(site = "unspecified") t =
  let events =
    match Atomic.get t.event_bus_subscription with
    | Subscribed { event_bus_sub; _ } -> Agent_sdk_metrics_bridge.drain event_bus_sub
    | No_event_bus -> []
  in
  let outcome = if events = [] then "empty" else "drained" in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string EventBusDrain)
    ~labels:[ "site", site; "outcome", outcome ]
    ();
  let rec update () =
    let old = Atomic.get t.state in
    let new_pending_tool_count, transitions =
      record_fsm_tool_transitions
        ~keeper_name:t.keeper_name
        ~turn_id:t.turn_id
        old.pending_tool_count
        events
    in
    let new_tracker =
      Keeper_unified_turn_types.record_turn_tool_events
        ~keeper_name:t.keeper_name
        old.tracker
        events
    in
    let new_summary =
      Keeper_turn_runtime_budget.merge_turn_event_bus_summary
        old.summary
        (Keeper_turn_runtime_budget.summarize_turn_event_bus events)
    in
    let new_state =
      { summary = new_summary
      ; tracker = new_tracker
      ; pending_tool_count = new_pending_tool_count
      }
    in
    if Atomic.compare_and_set t.state old new_state
    then (
      List.iter
        (emit_fsm_transition
           ~keeper_name:t.keeper_name
           ~turn_id:t.turn_id
           ~pending_count:new_state.pending_tool_count)
        transitions;
      (* Mirror the in-flight count to the registry only when it moved, so the
         supervisor sweep can exclude active tool execution (RFC-0197 P1-4a).
         The count is the authoritative FSM value, not a re-derived counter. *)
      if old.pending_tool_count <> new_state.pending_tool_count
      then t.on_pending_count_change new_state.pending_tool_count;
      new_summary)
    else update ()
  in
  update ()
;;

let integrity_error t =
  (Atomic.get t.state).tracker
  |> Keeper_unified_turn_types.turn_tool_event_integrity_error
;;

let tool_completed_count t =
  (Atomic.get t.state).tracker
  |> Keeper_unified_turn_types.turn_tool_completed_count
;;

let start_background_drain ~clock t =
  match Atomic.get t.event_bus_subscription, Eio_context.get_switch_opt () with
  | Subscribed _, Some sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Cancel.sub (fun cc ->
        match Atomic.compare_and_set t.drain_cancel Inactive (Active cc) with
        | true ->
          let rec loop () =
            try
              let _summary = drain ~site:"background_poll" t in
              Eio.Time.sleep clock (Keeper_turn_helpers.turn_event_bus_drain_interval_sec ());
              loop ()
            with
            | Eio.Cancel.Cancelled _ ->
              (* [unsubscribe] cancels this background worker as normal teardown. *)
              ()
            | exn ->
              Log.Keeper.warn
                "%s: keeper_turn event-bus drain failed: %s"
                t.keeper_name
                (Printexc.to_string exn);
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string EventBusDrain)
                ~labels:
                  [ ( "site"
                    , Keeper_event_bus_drain_site.(to_label Background_poll) )
                  ; "outcome", "exception"
                  ]
                ();
              Eio.Time.sleep clock (Keeper_turn_helpers.turn_event_bus_drain_interval_sec ());
              loop ()
          in
          loop ()
        | false ->
          (* [unsubscribe] has already closed the bus, or another fiber has
             already claimed the active drainer role. Either way this fiber
             must not install [cc] or start polling. *)
          ()))
  | _ -> ()
;;

(* Atomically claim the [Closed] state and hand back any background drain
   handle the caller must cancel. [Atomic.exchange] takes no [seen] argument,
   so unlike a [compare_and_set] retry loop it cannot spin: the previous value
   is taken in a single step. The earlier loop compared against a freshly
   reconstructed [Active cc], which is never PHYSICALLY equal to the stored box
   (OCaml [Atomic.compare_and_set] uses [==]), so on [Active] the CAS failed
   forever and the loop busy-spun at 100% CPU, starving the Eio scheduler
   (server-wide hang — regression from #21447). Cancellation is left to the
   caller, keeping this a pure state transition (testable without a live
   cancel context). *)
let take_drain_cancel t : Eio.Cancel.t option =
  match Atomic.exchange t.drain_cancel Closed with
  | Closed | Inactive -> None
  | Active cc -> Some cc
;;

let unsubscribe t =
  (match take_drain_cancel t with
   | None -> ()
   | Some cc -> (
     try Eio.Cancel.cancel cc (Failure "event_bus_unsubscribed") with
     | Eio.Cancel.Cancelled _ -> ()
     | Invalid_argument msg ->
       Log.Keeper.debug
         "%s: event bus drain cancel ignored after context finish: %s"
         t.keeper_name
         msg));
  ignore (drain ~site:"unsubscribe_final" t);
  (match Atomic.exchange t.event_bus_subscription No_event_bus with
  | Subscribed { event_bus; event_bus_sub } ->
    Agent_sdk_metrics_bridge.unsubscribe event_bus event_bus_sub
  | No_event_bus -> ())
;;

module For_testing = struct
  type nonrec fsm_transition = fsm_transition = Enter_awaiting | Leave_awaiting

  type nonrec event_bus_state = event_bus_state =
    { summary : Keeper_turn_runtime_budget.turn_event_bus_summary
    ; tracker : Keeper_unified_turn_types.turn_tool_event_tracker
    ; pending_tool_count : int
    }

  type nonrec drain_cancel_state = drain_cancel_state =
    | Inactive
    | Active of Eio.Cancel.t
    | Closed

  let record_fsm_tool_transitions = record_fsm_tool_transitions

  (** Test-only read accessor. *)
  let get_state t = Atomic.get t.state

  (** Test-only read accessor. *)
  let get_drain_cancel t = Atomic.get t.drain_cancel

  (** Test-only write accessor. No production caller; exposed only so unit
      tests can inject or reset the cancel lifecycle state. *)
  let set_drain_cancel t v = Atomic.set t.drain_cancel v

  (** Test-only write accessor. No production caller; exposed only so unit
      tests can exercise the take-and-close race path used by [unsubscribe]. *)
  let exchange_drain_cancel t v = Atomic.exchange t.drain_cancel v

  (** The exact take-and-close step [unsubscribe] runs: claims [Closed] and
      returns the displaced background drain handle (if any). Exposed so a
      unit test can assert it terminates and is idempotent on [Active]. *)
  let take_drain_cancel = take_drain_cancel
end
