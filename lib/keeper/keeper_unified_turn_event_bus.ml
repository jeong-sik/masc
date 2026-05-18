(** Turn-scoped OAS event-bus state for [Keeper_unified_turn]. *)

type t =
  { keeper_name : string
  ; event_bus_sub : Agent_sdk_metrics_bridge.handle option
  ; tool_event_tracker : Keeper_unified_turn_types.turn_tool_event_tracker
  ; drain_cancel : Eio.Cancel.t option ref
  ; turn_event_bus_mu : Eio.Mutex.t
  ; turn_event_bus : Keeper_turn_cascade_budget.turn_event_bus_summary ref
  }

let create ~keeper_name () =
  let event_bus_sub =
    match Keeper_event_bus.get () with
    | Some bus ->
      Some
        (Agent_sdk_metrics_bridge.subscribe
           ~purpose:"keeper_turn"
           ~filter:(Agent_sdk.Event_bus.filter_agent keeper_name)
           bus)
    | None -> None
  in
  { keeper_name
  ; event_bus_sub
  ; tool_event_tracker = Keeper_unified_turn_types.create_turn_tool_event_tracker ()
  ; drain_cancel = ref None
  ; turn_event_bus_mu = Eio.Mutex.create ()
  ; turn_event_bus = ref Keeper_turn_cascade_budget.empty_turn_event_bus_summary
  }
;;

let with_turn_event_bus_lock t f =
  Eio.Mutex.use_rw ~protect:true t.turn_event_bus_mu f
;;

let process_tool_events_for_side_effects t events =
  Keeper_unified_turn_types.record_turn_tool_events
    ~keeper_name:t.keeper_name
    t.tool_event_tracker
    events
;;

let drain ?(site = "unspecified") t =
  with_turn_event_bus_lock t (fun () ->
    let events =
      match t.event_bus_sub, Keeper_event_bus.get () with
      | Some sub, Some _bus -> Agent_sdk_metrics_bridge.drain sub
      | _ -> []
    in
    let outcome = if events = [] then "empty" else "drained" in
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_event_bus_drain
      ~labels:[ "site", site; "outcome", outcome ]
      ();
    process_tool_events_for_side_effects t events;
    let summary = Keeper_turn_cascade_budget.summarize_turn_event_bus events in
    t.turn_event_bus
    := Keeper_turn_cascade_budget.merge_turn_event_bus_summary
         !(t.turn_event_bus)
         summary;
    !(t.turn_event_bus))
;;

let committed_mutating_tools t =
  with_turn_event_bus_lock t (fun () ->
    Keeper_unified_turn_types.committed_mutating_tools_from_events
      t.tool_event_tracker)
;;

let integrity_error t =
  with_turn_event_bus_lock t (fun () ->
    Keeper_unified_turn_types.turn_tool_event_integrity_error
      t.tool_event_tracker)
;;

let start_background_drain ~clock t =
  match t.event_bus_sub, Eio_context.get_switch_opt () with
  | Some _, Some sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Cancel.sub (fun cc ->
        t.drain_cancel := Some cc;
        let rec loop () =
          try
            let _summary = drain ~site:"background_poll" t in
            ()
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Keeper.warn
              "%s: keeper_turn event-bus drain failed: %s"
              t.keeper_name
              (Printexc.to_string exn);
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_event_bus_drain
              ~labels:
                [ ( "site"
                  , Keeper_event_bus_drain_site.(to_label Background_poll) )
                ; "outcome", "exception"
                ]
              ();
            Eio.Time.sleep clock (Keeper_turn_helpers.turn_event_bus_drain_interval_sec ());
            loop ()
        in
        loop ()))
  | _ -> ()
;;

let unsubscribe t =
  (match !(t.drain_cancel) with
   | Some cc ->
     t.drain_cancel := None;
     (try Eio.Cancel.cancel cc (Failure "event_bus_unsubscribed") with
      | Eio.Cancel.Cancelled _ -> ()
      | Invalid_argument msg ->
        Log.Keeper.debug
          "%s: event bus drain cancel ignored after context finish: %s"
          t.keeper_name
          msg)
   | None -> ());
  ignore (drain ~site:"unsubscribe_final" t);
  match t.event_bus_sub, Keeper_event_bus.get () with
  | Some sub, Some bus -> Agent_sdk_metrics_bridge.unsubscribe bus sub
  | _ -> ()
;;
