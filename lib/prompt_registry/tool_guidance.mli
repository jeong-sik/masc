(** Generic cross-domain tool-result guidance (RFC
    prompts-and-tool-definitions-outside-ocaml §3.11).

    The closed variant below is the only way to reach a [tool_guidance.*]
    prompt key: call sites construct an arm with its data, {!to_string}
    renders the managed template from [config/prompts/tool_guidance.md]. Raw
    key strings never appear at call sites. A template that does not render
    is logged and falls back to the bare data — never to prose written in
    OCaml (#32848 precedent).

    Domain-specific guidance keeps its own local variant next to the producer
    ([keeper_tool_filesystem_runtime.fs_guidance], the [keeper.gate_replay]
    state arms, [Exec_policy.block_reason], [Subset_rewrite.t]); this type is
    only for guidance with no single domain home. *)

type t =
  | Broadcast_delivery_rejected of { request_id : string }
  (** The broadcast write persisted but the explicit Keeper delivery was
      rejected; the model must not resend. *)
  | Broadcast_content_required
  (** keeper_broadcast arrived with an empty content payload. *)
  | Workspace_message_delivery_rejected
  (** Same delivery rejection on the operator surface, without a
      request_id. *)
  | Post_execution_hook_failed
  (** The tool completed; only its post-execution hook failed. *)
  | Mcp_outcome_unknown
  (** An official-client MCP call's outcome is unknown; the call id must
      not be retried. *)
  | Reject_verdict_requires_reason
  (** A reviewer REJECT verdict arrived with an empty reason. *)
  | No_metrics_found_for_agent of { agent : string }
  | Invalid_agent_card_action of
      { action_quoted : string (** Already OCaml-quoted ([Printf %S]). *)
      ; valid_actions : string
      }

(** Render the arm's managed template; on render failure log and return the
    bare data (never inline prose). *)
val to_string : t -> string
