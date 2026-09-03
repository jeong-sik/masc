(* See [.mli] for the design notes. *)

type t =
  | Broadcast_delivery_rejected of { request_id : string }
  | Broadcast_content_required
  | Workspace_message_delivery_rejected
  | Post_execution_hook_failed
  | Mcp_outcome_unknown
  | Reject_verdict_requires_reason
  | No_metrics_found_for_agent of { agent : string }
  | Invalid_agent_card_action of
      { action_quoted : string
      ; valid_actions : string
      }

let key = function
  | Broadcast_delivery_rejected _ ->
    Prompt_names.tool_guidance_broadcast_delivery_rejected
  | Broadcast_content_required -> Prompt_names.tool_guidance_broadcast_content_required
  | Workspace_message_delivery_rejected ->
    Prompt_names.tool_guidance_workspace_message_delivery_rejected
  | Post_execution_hook_failed -> Prompt_names.tool_guidance_post_execution_hook_failed
  | Mcp_outcome_unknown -> Prompt_names.tool_guidance_mcp_outcome_unknown
  | Reject_verdict_requires_reason ->
    Prompt_names.tool_guidance_reject_verdict_requires_reason
  | No_metrics_found_for_agent _ -> Prompt_names.tool_guidance_no_metrics_found_for_agent
  | Invalid_agent_card_action _ -> Prompt_names.tool_guidance_invalid_agent_card_action
;;

let vars = function
  | Broadcast_delivery_rejected { request_id } -> [ "request_id", request_id ]
  | Broadcast_content_required | Workspace_message_delivery_rejected -> []
  | Post_execution_hook_failed -> []
  | Mcp_outcome_unknown -> []
  | Reject_verdict_requires_reason -> []
  | No_metrics_found_for_agent { agent } -> [ "agent", agent ]
  | Invalid_agent_card_action { action_quoted; valid_actions } ->
    [ "action_quoted", action_quoted; "valid_actions", valid_actions ]
;;

(* Bare data, never prose written here: the model still gets the payload the
   guidance was annotating, and the operator gets the log line naming the
   missing asset (#32848 precedent). *)
let fallback t =
  match t with
  | Broadcast_delivery_rejected { request_id } -> "request_id=" ^ request_id
  | Broadcast_content_required
  | Workspace_message_delivery_rejected
  | Post_execution_hook_failed
  | Mcp_outcome_unknown
  | Reject_verdict_requires_reason -> key t
  | No_metrics_found_for_agent { agent } -> "agent=" ^ agent
  | Invalid_agent_card_action { action_quoted; valid_actions = _ } ->
    "action=" ^ action_quoted
;;

let to_string t =
  let key = key t in
  match Prompt_registry.render_prompt_template key (vars t) with
  | Ok text -> String.trim text
  | Error detail ->
    Log.Misc.warn
      "tool guidance %s did not render, falling back to the bare data: %s"
      key
      detail;
    fallback t
;;
