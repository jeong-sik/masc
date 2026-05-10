(** Keeper_provider_health — in-memory provider health aggregator for MASC.

    Consumes typed [Agent_sdk.Telemetry_event.t] signals emitted by OAS
    and maintains per-(provider,model) EWMA health state.  Used by
    [Keeper_turn_livelock] and [Keeper_supervisor] to gate or accelerate
    stuck-turn detection.

    State is process-local: a restart resets all EWMA windows.  The signal
    of interest is in-process retry storms, not cross-restart drift. *)

type health = {
  ttfrc_ms_ewma : float;
  timeout_count_5m : int;
  prefill_ms_ewma : float;
  last_updated : float;
}

type config = {
  ttfrc_degraded_ms : float;
  ttfrc_unhealthy_ms : float;
  timeout_count_5m_unhealthy : int;
  prefill_degraded_ms : float;
}

let default_config = {
  ttfrc_degraded_ms = 5000.0;
  ttfrc_unhealthy_ms = 15000.0;
  timeout_count_5m_unhealthy = 3;
  prefill_degraded_ms = 2000.0;
}

type key = { provider : string; model : string }

module Key = struct
  type t = key
  let compare a b =
    let c = String.compare a.provider b.provider in
    if c <> 0 then c else String.compare a.model b.model
end

module KeyMap = Map.Make (Key)

let mu = Stdlib.Mutex.create ()
let state : health KeyMap.t ref = ref KeyMap.empty
let config_ref : config ref = ref default_config
let window_sec = 300.0 (* 5-minute sliding window *)

let now_unix () = Time_compat.now ()

let ewma ~alpha ~old ~new_ = alpha *. new_ +. (1.0 -. alpha) *. old

let update_health ~now ~key f =
  let current = KeyMap.find_opt key !state in
  let h =
    match current with
    | None -> f None
    | Some old ->
      let age = now -. old.last_updated in
      if age > window_sec then f None else f (Some old)
  in
  state := KeyMap.add key h !state

let update_from_event (ev : Agent_sdk.Telemetry_event.t) =
  let now = now_unix () in
  match ev with
  | Agent_sdk.Telemetry_event.Streaming_first_chunk { provider; model; ttfrc_ms; _ }
    ->
    let key = { provider; model } in
    Stdlib.Mutex.protect mu (fun () ->
      update_health ~now ~key (function
        | None ->
          { ttfrc_ms_ewma = ttfrc_ms;
            timeout_count_5m = 0;
            prefill_ms_ewma = 0.0;
            last_updated = now
          }
        | Some old ->
          { old with
            ttfrc_ms_ewma = ewma ~alpha:0.3 ~old:old.ttfrc_ms_ewma ~new_:ttfrc_ms;
            last_updated = now
          }))
  | Agent_sdk.Telemetry_event.Timeout { provider; model; _ } ->
    let key = { provider; model } in
    Stdlib.Mutex.protect mu (fun () ->
      update_health ~now ~key (function
        | None ->
          { ttfrc_ms_ewma = 0.0;
            timeout_count_5m = 1;
            prefill_ms_ewma = 0.0;
            last_updated = now
          }
        | Some old ->
          { old with
            timeout_count_5m = old.timeout_count_5m + 1;
            last_updated = now
          }))
  | Agent_sdk.Telemetry_event.Prefill_complete
      { provider; model; prompt_eval_ms; _ } ->
    let key = { provider; model } in
    Stdlib.Mutex.protect mu (fun () ->
      update_health ~now ~key (function
        | None ->
          { ttfrc_ms_ewma = 0.0;
            timeout_count_5m = 0;
            prefill_ms_ewma = prompt_eval_ms;
            last_updated = now
          }
        | Some old ->
          { old with
            prefill_ms_ewma =
              ewma ~alpha:0.3 ~old:old.prefill_ms_ewma ~new_:prompt_eval_ms;
            last_updated = now
          }))
  | _ -> ()

let is_healthy ~provider ~model =
  let key = { provider; model } in
  Stdlib.Mutex.protect mu (fun () ->
    match KeyMap.find_opt key !state with
    | None -> true
    | Some h ->
      let cfg = !config_ref in
      let age = now_unix () -. h.last_updated in
      if age > window_sec then true
      else if h.ttfrc_ms_ewma > cfg.ttfrc_unhealthy_ms then false
      else if h.timeout_count_5m >= cfg.timeout_count_5m_unhealthy then false
      else true)

let get_health ~provider ~model =
  let key = { provider; model } in
  Stdlib.Mutex.protect mu (fun () -> KeyMap.find_opt key !state)

let is_any_unhealthy_for_model ~model =
  Stdlib.Mutex.protect mu (fun () ->
    let cfg = !config_ref in
    let now = now_unix () in
    KeyMap.exists
      (fun key h ->
        if not (String.equal key.model model) then false
        else
          let age = now -. h.last_updated in
          if age > window_sec then false
          else if h.ttfrc_ms_ewma > cfg.ttfrc_unhealthy_ms then true
          else if h.timeout_count_5m >= cfg.timeout_count_5m_unhealthy then true
          else false)
      !state)

let set_config cfg = Stdlib.Mutex.protect mu (fun () -> config_ref := cfg)
let get_config () = Stdlib.Mutex.protect mu (fun () -> !config_ref)

(** Reset for tests. *)
let reset_for_tests () =
  Stdlib.Mutex.protect mu (fun () ->
    state := KeyMap.empty;
    config_ref := default_config)
