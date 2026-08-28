(** In-turn liveness pulse helpers for the keeper heartbeat loop,
    extracted from keeper_heartbeat_loop.ml.

    Drives a side-fiber that emits Workspace.heartbeat + SSE broadcasts at
    a bounded interval while a keeper turn is executing, so operators
    see continued presence and the registry can detect stuck turns. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

let in_turn_liveness_pulse_interval_sec () =
  max 5.0 (min 30.0 (float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ())))
;;

let with_pulse_fiber ~sw:_sw ~clock ~interval_sec ~tick f =
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

(* #27349: raw elapsed-time facts about the current turn, carried without any
   threshold or judgment -- the SSE payload and the two gauges below expose
   [in_flight_elapsed_ms]/[since_last_progress_ms] verbatim on every pulse
   tick (5-30s) while a turn is executing. Nothing here decides "stuck";
   consumers do (the operator dashboard live, and eventually #27323's
   supervision seat reading the gauge series). [started_at]/[last_progress_at]
   already exist on every [turn_observation] (stamped by
   [Keeper_registry.stamp_turn_progress] on every progress event) but were
   previously read only for dashboard JSON display -- nothing computed or
   surfaced the elapsed deltas that would have shown "4 keepers in-flight
   25min, progress 0" instead of a heartbeat pulse that just says "alive". *)
let elapsed_ms ~now_ts ~since = Float.max 0.0 ((now_ts -. since) *. 1000.0)

let in_flight_elapsed_ms ~now_ts ~started_at = elapsed_ms ~now_ts ~since:started_at

let since_last_progress_ms ~now_ts ~last_progress_at =
  elapsed_ms ~now_ts ~since:last_progress_at
;;

let record_in_flight_elapsed_gauges
      ~(meta : keeper_meta)
      ~now_ts
      ~(obs : Keeper_registry_types.turn_observation)
  =
  let labels = [ "keeper", meta.name ] in
  Otel_metric_store.register_gauge
    ~name:Keeper_metrics.(to_string InFlightElapsedSeconds)
    ~help:"Wall-clock seconds since the current turn started. No threshold: \
           a supervising consumer judges staleness against progress, not \
           against this value alone."
    ~labels
    ();
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string InFlightElapsedSeconds)
    ~labels
    (in_flight_elapsed_ms ~now_ts ~started_at:obs.started_at /. 1000.0);
  Otel_metric_store.register_gauge
    ~name:Keeper_metrics.(to_string SinceLastProgressSeconds)
    ~help:"Wall-clock seconds since the current turn's last recorded \
           progress event. No threshold: a long-running turn that keeps \
           progressing stays near zero; a stalled provider call grows \
           unbounded."
    ~labels
    ();
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string SinceLastProgressSeconds)
    ~labels
    (since_last_progress_ms ~now_ts ~last_progress_at:obs.last_progress_at /. 1000.0)
;;

let emit_in_turn_liveness_pulse ~(ctx : _ context) ~(meta : keeper_meta) =
  match Keeper_registry.get ~base_path:ctx.config.base_path meta.name with
  | Some { current_turn_observation = Some obs; _ } ->
    (try
       let _heartbeat = Workspace.heartbeat ctx.config ~agent_name:meta.name in
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
    (try record_in_flight_elapsed_gauges ~meta ~now_ts ~obs with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn
         "in-turn elapsed gauges failed for %s: %s"
         meta.name
         (Printexc.to_string exn));
    (try
       let json =
         `Assoc
           [ "type", `String "keeper_heartbeat"
           ; "name", `String meta.name
           ; "ts_unix", `Float now_ts
           ; "phase", `String "turn_running"
           ; "in_turn", `Bool true
           ; "in_flight_elapsed_ms",
             `Float (in_flight_elapsed_ms ~now_ts ~started_at:obs.started_at)
           ; "since_last_progress_ms",
             `Float (since_last_progress_ms ~now_ts ~last_progress_at:obs.last_progress_at)
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
  with_pulse_fiber
    ~sw:ctx.sw
    ~clock:ctx.clock
    ~interval_sec:(in_turn_liveness_pulse_interval_sec ())
    ~tick:(fun () -> if not (Atomic.get stop) then emit_in_turn_liveness_pulse ~ctx ~meta)
    f
;;
