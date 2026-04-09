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
  let result = Room.heartbeat ctx.config ~agent_name:ctx.agent_name in
  (* Room.heartbeat returns "⚠ ..." on failure (agent not found, invalid file) *)
  let success = not (String.length result >= 3
    && Char.code result.[0] = 0xe2
    && Char.code result.[1] = 0x9a
    && Char.code result.[2] = 0xa0) in
  (success, result)

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
           with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_non_cancelled "[Heartbeat] keepalive error" exn);
          if should_send then begin
            (try
               ignore (Room.broadcast ctx.config ~from_agent:ctx.agent_name ~content:message)
             with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_non_cancelled "[Heartbeat] broadcast error" exn);
            last_heartbeat := Time_compat.now ()
          end;
          (* Sleep for base interval (smart mode adjusts internally) *)
          Eio.Time.sleep ctx.clock (float_of_int interval);
          loop ()
      | _ -> ()
    in
    try loop ()
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_non_cancelled "[Heartbeat] loop error" exn
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

let handle_heartbeat_list _ctx args =
  let limit = get_int args "limit" 20 |> max 1 |> min 100 in
  let hbs = Heartbeat.list () in
  let hbs = List.filteri (fun i _ -> i < limit) hbs in
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

(** Canonical masc_heartbeat schema — SSOT.
    Consumers (agent_tool_surfaces, sdk_tool_contract) derive their
    projections from this value. *)
let heartbeat_schema : Types.tool_schema = {
  name = "masc_heartbeat";
  description = "Update your heartbeat timestamp to prove you are still active. \
Call every few minutes during long tasks; agents silent for 5+ min become zombie candidates. \
Prefer masc_heartbeat_start for automatic pings. Pair with masc_cleanup_zombies to reap stale agents.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("agent_name", `Assoc [
        ("type", `String "string");
        ("description", `String "Your agent name");
      ]);
    ]);
    ("required", `List [`String "agent_name"]);
  ];
}

let schemas : Types.tool_schema list = [
  heartbeat_schema;

  (* masc_heartbeat_start *)
  {
    name = "masc_heartbeat_start";
    description = "Start automatic background heartbeat pings at a given interval. \
Call after masc_join to keep your presence alive during long-running work. \
Smart mode skips beats when busy. Stop with masc_heartbeat_stop before masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("interval", `Assoc [
          ("type", `String "integer");
          ("description", `String "Interval in seconds between heartbeats (min: 5, max: 300)");
          ("default", `Int 30);
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Heartbeat message content");
          ("default", `String "🏓 heartbeat");
        ]);
        ("smart", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable smart mode: skip when busy, 3x interval when idle >5min");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };

  (* masc_heartbeat_stop *)
  {
    name = "masc_heartbeat_stop";
    description = "Stop a periodic heartbeat that was started by masc_heartbeat_start. \
Call when your long task is complete or you are about to masc_leave. \
Get heartbeat_id from masc_heartbeat_start response or masc_heartbeat_list.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("heartbeat_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of heartbeat to stop (from masc_heartbeat_start)");
        ]);
      ]);
      ("required", `List [`String "heartbeat_id"]);
    ];
  };

  (* masc_heartbeat_list *)
  {
    name = "masc_heartbeat_list";
    description = "List all active heartbeat timers in the room with their interval and last beat time. \
Use when debugging presence issues or looking for orphaned heartbeats before cleanup. \
Pair with masc_heartbeat_stop to cancel or masc_cleanup_zombies to reap dead agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max heartbeats to return");
          ("default", `Int 20);
          ("minimum", `Int 1);
          ("maximum", `Int 100);
        ]);
      ]);
    ];
  };

]

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_requires_join = [ "masc_heartbeat" ]
let _tool_spec_system_internal =
  [ "masc_heartbeat_start"; "masc_heartbeat_stop"; "masc_heartbeat_list" ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      let is_system = List.mem s.name _tool_spec_system_internal in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_heartbeat
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ~visibility:(if is_system then Tool_catalog.Hidden else Tool_catalog.Default)
           ~allow_direct_call_when_hidden:is_system
           ()))
    schemas
