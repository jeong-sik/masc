(** Tool_inline_dispatch_comm — communication tool handlers.

    Handles: masc_broadcast, masc_messages, masc_who.

    Extracted from tool_inline_dispatch.ml to reduce file size. *)

open Tool_inline_dispatch_types

(** Argument extraction helpers bound to ctx.arguments. *)
let arg_get_string ctx key default =
  Safe_ops.json_string ~default key ctx.arguments

let arg_get_int ctx key default =
  Safe_ops.json_int ~default key ctx.arguments

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

(** masc_who — list agents currently in the room *)
let handle_who (ctx : context) : tool_result option =
  let registry = ctx.registry in
  Some (true, Session.status_string registry)
