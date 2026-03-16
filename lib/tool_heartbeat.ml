(** Heartbeat tools - Agent health monitoring *)

open Tool_args

type 'a context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
}

type result = bool * string

(* Eio cancellation is structured control flow, not an operational error. *)
let log_non_cancelled prefix = function
  | Eio.Cancel.Cancelled _ as ex -> raise ex
  | exn ->
      Log.Keeper.info "%s: %s" prefix (Printexc.to_string exn)

let handle_heartbeat ctx _args =
  (true, Room.heartbeat ctx.config ~agent_name:ctx.agent_name)

let handle_heartbeat_start ctx args =
  let interval = get_int args "interval" 30 in
  let message = get_string args "message" "🏓 heartbeat" in
  let smart = get_bool args "smart" false in
  (* Validate interval: min 5, max 300 *)
  let interval = max 5 (min 300 interval) in
  let hb_id = Heartbeat.start ~agent_name:ctx.agent_name ~interval ~message in

  (* Smart heartbeat config *)
  let smart_config = Heartbeat_smart.make_config
    ~base_interval_s:(float_of_int interval)
    ~idle_multiplier:3.0
    ~busy_skip:true
    ~idle_threshold_s:300.0  (* 5 minutes *)
    () in

  (* Mutable state for smart mode *)
  let last_activity = ref (Time_compat.now ()) in
  let last_heartbeat = ref (Time_compat.now ()) in

  (* Start background fiber for actual heartbeat *)
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    let rec loop () =
      match Heartbeat.get hb_id with
      | Some hb when hb.Heartbeat.active ->
          let should_send =
            if smart then begin
              (* Get agent status for busy detection *)
              let room_agents = Room.get_agents_raw ctx.config in
              let agent_status : Types.agent_status =
                match List.find_opt (fun (a : Types.agent) -> a.name = ctx.agent_name) room_agents with
                | Some a -> a.status
                | None -> Types.Active  (* Default: not busy *)
              in
              (* Update last_activity when agent is actively working *)
              if agent_status = Types.Busy then
                last_activity := Time_compat.now ();
              let decision = Heartbeat_smart.should_emit
                ~config:smart_config
                ~agent_status
                ~last_activity:!last_activity
                ~last_heartbeat:!last_heartbeat in
              Heartbeat_smart.should_emit_now decision
            end else
              true
          in
          (* Keep agent liveness fresh so zombie cleanup does not remove active heartbeat owners. *)
          (try
             ignore (Room.heartbeat ctx.config ~agent_name:ctx.agent_name)
           with exn -> log_non_cancelled "[Heartbeat] keepalive error" exn);
          if should_send then begin
            (try
               ignore (Room.broadcast ctx.config ~from_agent:ctx.agent_name ~content:message)
             with exn -> log_non_cancelled "[Heartbeat] broadcast error" exn);
            last_heartbeat := Time_compat.now ()
          end;
          (* Sleep for base interval (smart mode adjusts internally) *)
          Eio.Time.sleep ctx.clock (float_of_int interval);
          loop ()
      | _ -> ()
    in
    try loop ()
    with exn -> log_non_cancelled "[Heartbeat] loop error" exn
  );
  let mode_str = if smart then " [SMART]" else "" in
  (true, Printf.sprintf "✅ Heartbeat started: %s (interval: %ds, message: %s)%s" hb_id interval message mode_str)

let handle_heartbeat_stop _ctx args =
  let hb_id = get_string args "heartbeat_id" "" in
  if hb_id = "" then
    (false, "❌ heartbeat_id required")
  else if Heartbeat.stop hb_id then
    (true, Printf.sprintf "✅ Heartbeat stopped: %s" hb_id)
  else
    (false, Printf.sprintf "❌ Heartbeat not found: %s" hb_id)

let handle_heartbeat_list _ctx _args =
  let hbs = Heartbeat.list () in
  let fmt_hb hb =
    let uptime = int_of_float (Time_compat.now () -. hb.Heartbeat.created_at) in
    Printf.sprintf "  • %s: agent=%s interval=%ds message=\"%s\" uptime=%ds"
      hb.Heartbeat.id hb.agent_name hb.interval hb.message uptime
  in
  let list_str =
    if List.length hbs = 0 then "No active heartbeats"
    else "Active heartbeats:\n" ^ String.concat "\n" (List.map fmt_hb hbs)
  in
  (true, list_str)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_heartbeat" -> Some (handle_heartbeat ctx args)
  | "masc_heartbeat_start" -> Some (handle_heartbeat_start ctx args)
  | "masc_heartbeat_stop" -> Some (handle_heartbeat_stop ctx args)
  | "masc_heartbeat_list" -> Some (handle_heartbeat_list ctx args)
  | _ -> None
