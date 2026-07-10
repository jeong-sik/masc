(** In-turn liveness pulse helpers for the keeper heartbeat loop,
    extracted from keeper_heartbeat_loop.ml.

    Drives a side-fiber that emits Workspace.heartbeat_r + SSE broadcasts at
    a bounded interval while a keeper turn is executing, so operators
    see continued presence and the registry can detect stuck turns. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

let in_turn_liveness_pulse_interval_sec () =
  max 5.0 (min 30.0 (float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ())))
;;

let with_in_turn_liveness_pulse_for_test ~sw:_sw ~clock ~interval_sec ~tick f =
  let interval_sec = max 0.001 interval_sec in
  Eio.Switch.run (fun pulse_sw ->
    let pulse_stop = Atomic.make false in
    let pulse_cancel = ref None in
    let stop_pulse () =
      Atomic.set pulse_stop true;
      match !pulse_cancel with
      | None -> ()
      | Some cc ->
        (try Eio.Cancel.cancel cc (Failure "in_turn_liveness_pulse_stop") with
         | Eio.Cancel.Cancelled _ -> ()
         | Invalid_argument _ -> ())
    in
    Eio.Switch.on_release pulse_sw stop_pulse;
    Eio.Fiber.fork ~sw:pulse_sw (fun () ->
      try
        Eio.Cancel.sub (fun cc ->
          pulse_cancel := Some cc;
          let rec loop () =
            if not (Atomic.get pulse_stop)
            then (
              Eio.Time.sleep clock interval_sec;
              if not (Atomic.get pulse_stop)
              then
                (try tick () with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Keeper.warn
                     "in-turn liveness pulse failed: %s"
                     (Printexc.to_string exn);
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string HeartbeatFailures)
                     ~labels:[ "keeper", "liveness_pulse"; "phase", "pulse_tick" ]
                     ());
              loop ())
          in
          loop ())
      with
      | Eio.Cancel.Cancelled _ -> ());
    match f () with
    | result ->
      stop_pulse ();
      result
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      stop_pulse ();
      Printexc.raise_with_backtrace exn backtrace)
;;

let emit_in_turn_liveness_pulse ~(ctx : _ context) ~(meta : keeper_meta) =
  match Keeper_registry.get ~base_path:ctx.config.base_path meta.name with
  | Some entry when Option.is_some entry.current_turn_observation ->
    (try
       match Workspace.heartbeat_r ctx.config ~agent_name:meta.agent_name with
       | Workspace.Heartbeat_updated _ -> ()
       | Workspace.Heartbeat_agent_not_found { agent_name } ->
         Log.Keeper.warn
           "in-turn heartbeat owner %s disappeared"
           agent_name;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string HeartbeatFailures)
           ~labels:[ "keeper", meta.name; "phase", "in_turn_heartbeat_missing" ]
           ()
       | Workspace.Heartbeat_invalid_agent_file { agent_name; detail } ->
         Log.Keeper.warn
           "in-turn heartbeat state for %s is invalid: %s"
           agent_name
           detail;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string HeartbeatFailures)
           ~labels:[ "keeper", meta.name; "phase", "in_turn_heartbeat_invalid" ]
           ()
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn
         "in-turn heartbeat failed for %s: %s"
         meta.name
         (Printexc.to_string exn);
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string HeartbeatFailures)
         ~labels:[ "keeper", meta.name; "phase", "in_turn_heartbeat" ]
         ());
    let now_ts = Time_compat.now () in
    (try
       let json =
         `Assoc
           [ "type", `String "keeper_heartbeat"
           ; "name", `String meta.name
           ; "generation", `Int meta.runtime.generation
           ; "ts_unix", `Float now_ts
           ; "phase", `String "turn_running"
           ; "in_turn", `Bool true
           ]
       in
       Sse.broadcast json;
       Sse.broadcast_presence json
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string SseBroadcastFailures)
         ~labels:[ "keeper", meta.name ]
         ();
       Log.Keeper.error
         "in-turn heartbeat SSE broadcast failed: %s"
         (Printexc.to_string exn))
  | _ -> ()
;;

let with_in_turn_liveness_pulse
      ~(ctx : _ context)
      ~(meta : keeper_meta)
      ~(stop : bool Atomic.t)
      f
  =
  with_in_turn_liveness_pulse_for_test
    ~sw:ctx.sw
    ~clock:ctx.clock
    ~interval_sec:(in_turn_liveness_pulse_interval_sec ())
    ~tick:(fun () -> if not (Atomic.get stop) then emit_in_turn_liveness_pulse ~ctx ~meta)
    f
;;
