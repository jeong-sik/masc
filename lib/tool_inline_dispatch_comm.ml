(** Tool_inline_dispatch_comm — communication tool handlers.

    Handles: masc_bounded_run, masc_broadcast, masc_messages,
    masc_listen, masc_who.

    Extracted from tool_inline_dispatch.ml to reduce file size. *)

open Tool_inline_dispatch_types

(** Argument extraction helpers bound to ctx.arguments. *)
let arg_get_string ctx key default =
  Safe_ops.json_string ~default key ctx.arguments

let arg_get_int ctx key default =
  Safe_ops.json_int ~default key ctx.arguments

(** masc_bounded_run only accepts configured spawnable agent labels.
    Arbitrary executables are valid for [Spawn.spawn] test helpers, but not for
    user-facing bounded runs where we want deterministic validation errors. *)
let invalid_bounded_agents (agents : string list) : string list =
  let invalid =
    agents
    |> List.map String.trim
    |> List.filter (fun name ->
      name = "" || not (Provider_adapter.is_spawnable_agent name))
  in
  List.sort_uniq String.compare invalid

(** masc_bounded_run — run a bounded multi-agent execution *)
let handle_bounded_run (ctx : context) : tool_result option =
  let module U = Yojson.Safe.Util in
  let state = ctx.state in
  let sw = ctx.sw in
  let arguments = ctx.arguments in
  let agents = match arguments |> U.member "agents" with
    | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in
  let prompt = arg_get_string ctx "prompt" "" in
  if String.trim prompt = "" then
    Some (false, Tool_args.error_response "prompt is required")
  else
    match invalid_bounded_agents agents with
    | invalid :: rest ->
      let invalid_names = String.concat ", " (invalid :: rest) in
      let allowed =
        Provider_adapter.spawnable_canonical_names ()
        |> List.sort_uniq String.compare
        |> String.concat ", "
      in
      Some
        ( false,
          Tool_args.error_response_typed
            ~code:Tool_args.Validation_error
            (Printf.sprintf
               "invalid agent name(s): %s. Use configured spawnable agents: %s"
               invalid_names allowed) )
    | [] ->
      let constraints_json = arguments |> U.member "constraints" in
      let goal_json = arguments |> U.member "goal" in
      let constraints = Bounded.constraints_of_json constraints_json in
      let goal = Bounded.goal_of_json goal_json in
      ignore (state, sw);
      let spawn_fn agent_name prompt =
        Spawn.spawn ~agent_name ~prompt
          ~timeout_seconds:Env_config.Spawn.timeout_seconds ()
      in
      let result = Bounded.bounded_run ~constraints ~goal ~agents ~prompt ~spawn_fn in
      let json = Bounded.result_to_json result in
      Some (result.Bounded.status = `Goal_reached, Yojson.Safe.pretty_to_string json)

(** masc_broadcast — broadcast a message to the room *)
let handle_broadcast (ctx : context) : tool_result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let registry = ctx.registry in
  let state = ctx.state in
  let sw = ctx.sw in
  let message = arg_get_string ctx "message" "" in
  let trimmed = String.trim message in
  if trimmed = "" then
    Some (false, "Broadcast message cannot be empty")
  else
  let allowed, wait_secs = Session.check_rate_limit registry ~agent_name in
  if not allowed then
    Some (false, Printf.sprintf "Rate limited. %d sec remaining." wait_secs)
  else begin
    let trace_context = Otel_trace_context.from_ambient () in
    let result = Room.broadcast ?trace_context config ~from_agent:agent_name ~content:message in
    let mention = Mention.extract message in
    let _ = Session.push_message registry ~from_agent:agent_name ~content:message ~mention in
    let notification_fields = [
      ("type", `String "masc/broadcast");
      ("from", `String agent_name);
      ("content", `String message);
      ("mention", Json_util.string_opt_to_json mention);
      ("timestamp", `Float (Time_compat.now ()));
    ] in
    let notification = `Assoc (Otel_trace_context.inject_json notification_fields trace_context) in
    Mcp_server.sse_broadcast state notification;
    Subscriptions.push_event_to_sessions notification;
    (match mention with
     | Some target -> Notify.notify_mention ~from_agent:agent_name ~target_agent:target ~message ()
     | None -> ());
    A2a_tools.notify_event
      ~event_type:A2a_tools.Broadcast
      ~agent:agent_name
      ~data:(`Assoc [
        ("message", `String message);
        ("mention", Json_util.string_opt_to_json mention);
      ]);
    let _ = Auto_responder.maybe_respond
      ~sw
      ~base_path:config.base_path
      ~from_agent:agent_name
      ~content:message
      ~mention
    in
    (* Team_session_engine_eio removed — skip broadcast increment *)
    ignore (config, agent_name);
    Audit_log.log_broadcast config ~agent_id:agent_name
      ~message_preview:message ();
    Some (true, result)
  end

(** masc_messages — retrieve recent messages *)
let handle_messages (ctx : context) : tool_result option =
  let config = ctx.config in
  let since_seq = arg_get_int ctx "since_seq" 0 in
  let limit = arg_get_int ctx "limit" 10 in
  Some (true, Room.get_messages config ~since_seq ~limit)

(** masc_listen — long-poll for a message addressed to this agent *)
let handle_listen (ctx : context) : tool_result option =
  let agent_name = ctx.agent_name in
  let registry = ctx.registry in
  let timeout = float_of_int (arg_get_int ctx "timeout" 300) in
  Log.Mcp.info "%s is now listening (timeout: %.0fs)..." agent_name timeout;
  let msg_opt = ctx.wait_for_message registry ~agent_name ~timeout in
  (match msg_opt with
   | Some msg ->
       (match Json_util.get_string msg "from",
              Json_util.get_string msg "content",
              Json_util.get_string msg "timestamp" with
        | Some from, Some content, Some timestamp ->
            Some (true, Printf.sprintf {|
MESSAGE RECEIVED
From: %s
Time: %s

%s

Call masc_listen again to continue listening.
|} from timestamp content)
        | _ ->
            Log.Mcp.warn
              "masc_listen received malformed message (missing from/content/timestamp) for agent %s"
              agent_name;
            Some (Tool_args.error_result
                    "received malformed message (missing from/content/timestamp)"))
   | None ->
       Some (true, Printf.sprintf "Listening timed out after %.0fs. No messages received." timeout))

(** masc_who — list agents currently in the room *)
let handle_who (ctx : context) : tool_result option =
  let registry = ctx.registry in
  Some (true, Session.status_string registry)
