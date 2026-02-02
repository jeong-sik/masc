(** Heartbeat tools - Agent health monitoring *)

let get_string args key default =
  match Yojson.Safe.Util.member key args with
  | `String s -> s
  | _ -> default

let get_int args key default =
  match Yojson.Safe.Util.member key args with
  | `Int n -> n
  | _ -> default

let get_int_opt args key =
  match Yojson.Safe.Util.member key args with
  | `Int n -> Some n
  | _ -> None

let get_float_opt args key =
  match Yojson.Safe.Util.member key args with
  | `Float f -> Some f
  | `Int n -> Some (float_of_int n)
  | _ -> None

let get_bool args key default =
  match Yojson.Safe.Util.member key args with
  | `Bool b -> b
  | _ -> default

type 'a context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
}

type result = bool * string

let parse_context args =
  match Yojson.Safe.Util.member "context" args with
  | `Assoc _ as ctx_json ->
      let used_tokens = get_int_opt ctx_json "used_tokens" in
      let max_tokens = get_int_opt ctx_json "max_tokens" in
      let ratio = get_float_opt ctx_json "ratio" in
      let messages = get_int_opt ctx_json "messages" in
      let tool_calls = get_int_opt ctx_json "tool_calls" in
      if used_tokens = None && max_tokens = None && ratio = None && messages = None && tool_calls = None then
        None
      else
        let open Types in
        Some {
          used_tokens;
          max_tokens;
          ratio;
          messages;
          tool_calls;
          reported_at = None;
        }
  | _ -> None

let handle_heartbeat ctx args =
  let context = parse_context args in
  (true, Room.heartbeat ctx.config ~agent_name:ctx.agent_name ~context)

let handle_heartbeat_start ctx args =
  let interval = get_int args "interval" 30 in
  let message = get_string args "message" "🏓 heartbeat" in
  let smart = get_bool args "smart" false in
  let context = parse_context args in
  let actual_name = Room.resolve_agent_name ctx.config ctx.agent_name in
  (* Validate interval: min 5, max 300 *)
  let interval = max 5 (min 300 interval) in
  let hb_id = Heartbeat.start ~agent_name:actual_name ~interval ~message in

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
                match List.find_opt (fun (a : Types.agent) -> a.name = actual_name) room_agents with
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
          (* Always update liveness on each tick (with optional context) *)
          (try
             ignore (Room.heartbeat ctx.config ~agent_name:actual_name ~context)
           with exn ->
             Printf.eprintf "[Heartbeat] liveness update error: %s\n%!"
               (Printexc.to_string exn));

          if should_send then begin
            (try
               ignore (Room.broadcast ctx.config ~from_agent:actual_name ~content:message)
             with exn ->
               Printf.eprintf "[Heartbeat] broadcast error: %s\n%!"
                 (Printexc.to_string exn));
            last_heartbeat := Time_compat.now ()
          end;
          (* Sleep for base interval (smart mode adjusts internally) *)
          Eio.Time.sleep ctx.clock (float_of_int interval);
          loop ()
      | _ -> ()
    in
    try loop () with exn ->
      Printf.eprintf "[Heartbeat] loop error: %s\n%!" (Printexc.to_string exn)
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
