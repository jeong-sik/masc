(** OAS approval callbacks shared across call sites.

    Kept in a standalone module (not in [Governance_pipeline]) so callers
    like [Dashboard_operator_judge] or [Tool_deep_review] can reference
    it without forming a dependency cycle through
    [Operator_pending_confirm] and the governance approval queue. *)

(* #7883 *)

(** Always-approve callback for system-level OAS runs that MASC has
    already decided to trust (judges, auto_responder, autoresearch
    codegen, deep_review, anti_rationalization, OpenAI-compat bridge).
    Unreachable-by-policy tool calls will be accepted here — install only
    where the trust decision is made at the call site. *)
let auto_approve : Agent_sdk.Hooks.approval_callback =
  Agent_sdk.Approval.(create [ always_approve ] |> as_callback)

(** Fail-closed default for OAS Agent builder sites without an explicit
    HITL or trusted-system decision source. Rejects every
    ApprovalRequired tool call with a reason that names the tool.
    Unreachable-by-policy cases will now be rejected rather than silently
    executed (OAS's fail-open default). Hand-rolled instead of
    [Agent_sdk.Approval.always_reject] to preserve per-call tool-name
    templating. *)
let reject_by_default : Agent_sdk.Hooks.approval_callback =
  fun ~tool_name ~input:_ ->
    Agent_sdk.Hooks.Reject
      (Printf.sprintf
         "MASC approval fail-closed: tool %s requires approval but no \
          approval_callback was wired at this Agent builder site. Install \
          Governance_pipeline.to_oas_approval_callback (keeper HITL) or \
          Approval_callbacks.auto_approve (trusted system run). See #7883."
         tool_name)
