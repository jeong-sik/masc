module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Mcp_tool_runtime_comm — communication tool handlers.

    Handles: masc_broadcast, masc_messages.

    Extracted from mcp_tool_runtime.ml to keep the runtime router small. *)

open Mcp_tool_runtime_types

type tool_result = Mcp_tool_runtime_types.tool_result

type context = Mcp_tool_runtime_types.context

(** Argument extraction helpers bound to ctx.arguments. *)
let arg_get_string ctx key default =
  Safe_ops.json_string ~default key ctx.arguments

let arg_get_int ctx key default =
  Safe_ops.json_int ~default key ctx.arguments

(** masc_broadcast — broadcast a message to the workspace *)
let handle_broadcast ~tool_name ~start_time (ctx : context) : tool_result option =
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let registry = ctx.registry in
  let state = ctx.state in
  let message = arg_get_string ctx "message" "" in
  let trimmed = String.trim message in
  if String.equal trimmed "" then
    (* RFC-0189: caller-input violation (empty broadcast message).
       The producer supplies [Workflow_rejection] explicitly; message text
       never participates in classification. *)
    Some (Tool_result.error
            ~failure_class:(Some Tool_result.Workflow_rejection)
            ~tool_name ~start_time
            "Broadcast message cannot be empty")
  else
  let allowed, wait_secs = Session.check_rate_limit registry ~agent_name in
  if not allowed then
    (* RFC-0189: rate-limit hit — caller should retry after [wait_secs].
       [Transient_error] is the closest existing variant for
       retry-friendly failure, mirroring the same tag used by
       [tool_misc_web_fetch] / [tool_misc_web_search] for rate
       limits. *)
    Some (Tool_result.error
            ~failure_class:(Some Tool_result.Transient_error)
            ~tool_name ~start_time
            (Printf.sprintf "Rate limited. %d sec remaining." wait_secs))
  else begin
    let message =
      Workspace_task_cache_invariant.rewrite_broadcast_content
        ~config
        ~from_agent:agent_name
        ~module_name:"mcp_tool_runtime_comm"
        ~content:message
    in
    let trace_context = Otel_trace_context.from_ambient () in
    let broadcast_result =
      Workspace.broadcast ?trace_context ~task_cache_invariant_checked:true config
        ~from_agent:agent_name ~content:message
    in
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
        ignore (config, agent_name);
        Audit_log.log_broadcast config ~agent_id:agent_name
          ~message_preview:message ();
        Some (Tool_result.ok ~tool_name ~start_time broadcast_result)
  end

(** masc_messages — retrieve recent messages *)
let handle_messages ~tool_name ~start_time (ctx : context) : tool_result option =
  let config = ctx.config in
  let since_seq = arg_get_int ctx "since_seq" 0 in
  let limit = arg_get_int ctx "limit" 10 in
  Some (Tool_result.ok ~tool_name ~start_time (Workspace.get_messages config ~since_seq ~limit))
