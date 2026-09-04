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
  let content = arg_get_string ctx "content" "" in
  let trimmed = String.trim content in
  let task_cache_signal_result =
    Workspace_broadcast.task_cache_signal_of_args ctx.arguments
  in
  if String.equal trimmed "" then
    (* RFC-0189: caller-input violation (empty broadcast content).
       The producer supplies [Workflow_rejection] explicitly; body text
       never participates in classification. *)
    Some (Tool_result.error
            ~failure_class:Tool_result.Workflow_rejection
            ~tool_name ~start_time
            "Broadcast content cannot be empty")
  else
    match task_cache_signal_result with
    | Error detail ->
      Some
        (Tool_result.error
           ~failure_class:Tool_result.Workflow_rejection
           ~tool_name
           ~start_time
           detail)
    | Ok task_cache_signal ->
  let allowed, wait_secs = Session.check_rate_limit registry ~agent_name in
  if not allowed then
    (* RFC-0189: rate-limit hit — caller should retry after [wait_secs].
       [Dependency_unavailable] is the closest existing variant for
       retry-friendly failure, mirroring the same tag used by
       [tool_misc_web_fetch] / [tool_misc_web_search] for rate
       limits. *)
    Some (Tool_result.error
            ~failure_class:Tool_result.Dependency_unavailable
            ~tool_name ~start_time
            (Printf.sprintf "Rate limited. %d sec remaining." wait_secs))
  else
    let trace_context = Otel_trace_context.from_ambient () in
    let delivery =
      (* A Keeper calling masc_broadcast is speaking to the workspace, so
         this reaches every Keeper's conversation window. *)
      Workspace.broadcast ?trace_context
        ?task_cache_signal
        ~audience:Workspace_broadcast.Fleet_conversation config
        ~from_agent:agent_name ~content
    in
    match delivery with
    | Error (Workspace_broadcast.Broadcast_policy_rejected detail) ->
      Some
        (Tool_result.error
           ~failure_class:Tool_result.Workflow_rejection
           ~tool_name
           ~start_time
           ("Broadcast rejected: " ^ detail))
    | Error error ->
      Some
        (Tool_result.error
           ~failure_class:Tool_result.Runtime_failure
           ~tool_name
           ~start_time
           (Printf.sprintf
              "Broadcast was not persisted: %s"
              (Workspace.broadcast_error_to_string error)))
    | Ok delivery ->
      let from_agent = delivery.from_agent in
      let mention = delivery.mention in
      let message = delivery.content in
      let project_auxiliary label project =
        try project () with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Log.Mcp.warn
            "broadcast auxiliary projection failed projection=%s request_id=%s: %s"
            label
            delivery.request_id
            (Printexc.to_string exn)
      in
      project_auxiliary "session" (fun () ->
        let recipients =
          Session.push_message registry ~from_agent ~content:message ~mention
        in
        Log.Mcp.debug
          "broadcast session push delivered to %d recipient(s) request_id=%s"
          (List.length recipients)
          delivery.request_id);
      let notification_fields =
        [ ("type", `String "masc/broadcast")
        ; ("request_id", `String delivery.request_id)
        ; ("from", `String from_agent)
        ; ("content", `String message)
        ; ("mention", Json_util.string_opt_to_json mention)
        ; ( "mention_delivery"
          , Workspace_broadcast.mention_delivery_to_yojson
              delivery.mention_delivery )
        ; ("timestamp", `Float (Time_compat.now ()))
        ]
      in
      let notification =
        `Assoc (Otel_trace_context.inject_json notification_fields trace_context)
      in
      project_auxiliary "sse" (fun () ->
        Mcp_server.sse_broadcast state notification);
      project_auxiliary "subscriptions" (fun () ->
        Subscriptions.push_event_to_sessions notification);
      project_auxiliary "notification" (fun () ->
        match mention with
        | Some target ->
          Notify.notify_mention ~from_agent ~target_agent:target ~message ()
        | None -> ());
      project_auxiliary "audit" (fun () ->
        Audit_log.log_broadcast config ~agent_id:from_agent ~message_preview:message ());
      let data = Workspace_broadcast.broadcast_delivery_to_yojson delivery in
      Some
        (match delivery.mention_delivery with
         | Workspace_broadcast.Passive
         | Workspace_broadcast.Accepted
         | Workspace_broadcast.Already_accepted ->
           Tool_result.make_ok ~tool_name ~start_time ~data ()
         | Workspace_broadcast.Pending
         | Workspace_broadcast.Deferred _ ->
           Tool_result.make_deferred ~tool_name ~start_time ~data ()
         | Workspace_broadcast.Rejected _ ->
           Tool_result.make_err
             ~tool_name
             ~class_:Tool_result.Workflow_rejection
             ~start_time
             ~data
             (Tool_guidance.to_string
                (Tool_guidance.Broadcast_delivery_rejected
                   { request_id = delivery.request_id })))

(** masc_messages — retrieve recent messages *)
let handle_messages ~tool_name ~start_time (ctx : context) : tool_result option =
  let config = ctx.config in
  let since_seq = arg_get_int ctx "since_seq" 0 in
  let limit = arg_get_int ctx "limit" 10 in
  Some (Tool_result.ok ~tool_name ~start_time (Workspace.get_messages config ~since_seq ~limit))
