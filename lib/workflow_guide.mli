(** Workflow Guidance — encodes Golden Path sequences so agents know
    "what to do next" without reading documentation.

    Each tool call returns structured next_steps based on the tool name
    and whether the call succeeded. This data is injected into the MCP
    response envelope as an additive field.

    @since 2.89.0 *)

(** A single suggested next action. *)
type step =
  { tool : string
  ; reason : string
  }

(** Guidance returned for a tool invocation. *)
type guidance =
  { next_steps : step list
  ; preconditions : string list
  ; common_mistakes : string list
  }

(** [next_steps ~tool_name ~success] returns conservative workflow guidance for the
    tool that was just called. When argument-specific semantics matter
    (for example [masc_transition]), this wrapper returns the generic safe path. *)
val next_steps : tool_name:string -> success:bool -> guidance

(** [next_steps_for_call ~tool_name ~args ~success] returns workflow guidance for an
    actual tool invocation. This is the canonical path for MCP tool-call envelopes
    because it can inspect arguments when tool semantics depend on them. *)
val next_steps_for_call
  :  tool_name:string
  -> args:Yojson.Safe.t
  -> success:bool
  -> guidance

(** [guidance_to_json g] serialises guidance to a Yojson value suitable
    for embedding in the MCP response envelope. *)
val guidance_to_json : guidance -> Yojson.Safe.t

(** [workflow_context ~tool_name] returns before/after/common_mistakes
    context for use in tool help responses.  Returns [None] for tools
    that have no registered workflow context. *)
val workflow_context
  :  tool_name:string
  -> (string list * string list * string list) option

(** [current_state_guidance ~room_set ~joined ~task_claimed
     ~current_task_set ~worktree_active ~session_active] returns
    the next recommended steps based on the agent's current state.
    Used by the [masc_workflow_guide] tool. *)
val current_state_guidance
  :  room_set:bool
  -> joined:bool
  -> task_claimed:bool
  -> current_task_set:bool
  -> worktree_active:bool
  -> session_active:bool
  -> guidance
