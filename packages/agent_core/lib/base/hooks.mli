(** Lifecycle hooks for agent execution.

    @stability Stable
    @since 0.93.1 *)

(** Per-turn adjustable parameters.
    Returned via [AdjustParams] from [BeforeTurnParams] hook. *)
type turn_params =
  { temperature : float option
  ; thinking_budget : int option
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; tool_choice : Types.tool_choice option
  ; extra_system_context : string option
  ; system_prompt_override : string option
  }

val default_turn_params : turn_params

(** Reasoning summary extracted from structured assistant message blocks.
    [extract_reasoning] preserves Thinking blocks without inferring uncertainty
    or tool rationale from prose. *)
type reasoning_summary =
  { thinking_blocks : string list
  ; has_uncertainty : bool
  ; tool_rationale : string option
  }

val empty_reasoning_summary : reasoning_summary
val extract_reasoning : Types.message list -> reasoning_summary

(** Events emitted during agent execution *)
type hook_event =
  | BeforeTurn of
      { turn : int
      ; messages : Types.message list
      }
  | BeforeTurnParams of
      { turn : int
      ; messages : Types.message list
      ; last_tool_results : Types.tool_result list
      ; current_params : turn_params
      ; reasoning : reasoning_summary
      }
  | AfterTurn of
      { turn : int
      ; response : Types.api_response
      }
  | PreToolUse of
      { invocation : Tool_contract.Invocation.t
        (** Exact run-scoped model-tool occurrence. @since 0.216.0 *)
      ; tool_name : string
      ; input : Yojson.Safe.t
      ; accumulated_cost_usd : float
      }
  | PostToolUse of
      { invocation : Tool_contract.Invocation.t
        (** Same exact occurrence as the matching [PreToolUse].
            @since 0.216.0 *)
      ; tool_name : string
      ; input : Yojson.Safe.t
      ; output : Types.tool_result
      ; result_bytes : int
      ; duration_ms : float
      }
  | PostToolUseFailure of
      { invocation : Tool_contract.Invocation.t
        (** Same exact occurrence as the matching [PreToolUse].
            @since 0.216.0 *)
      ; tool_name : string
      ; input : Yojson.Safe.t
      ; error : string
      }
  | OnStop of
      { reason : Types.stop_reason
      ; response : Types.api_response
      }
  | OnError of
      { invocation : Tool_contract.Invocation.t option
        (** [Some] for an error attributable to one exact tool occurrence;
            [None] for non-tool errors. *)
      ; detail : string
      ; context : string
      }
  | OnToolError of
      { invocation : Tool_contract.Invocation.t
      ; tool_name : string
      ; error : string
      }

(** Exact tool occurrence associated with a hook event, when any. *)
val invocation_of_event : hook_event -> Tool_contract.Invocation.t option

(** Elicitation: structured request for user input during agent execution. *)
type elicitation_request =
  { question : string
  ; schema : Yojson.Safe.t option
  ; timeout_s : float option
  }

type elicitation_response =
  | Answer of Yojson.Safe.t
  | Declined
  | Timeout

type elicitation_callback = elicitation_request -> elicitation_response

(** Prompt supplied by a [PreToolUse] hook when caller approval is required.
    It deliberately has no generic JSON schema: authorization is a closed
    protocol, not an arbitrary elicitation answer. OAS does not install a timer
    or persist a pending approval request at this synchronous boundary. *)
type tool_approval_prompt = { question : string }

(** Exact immutable tool occurrence presented to the caller-owned approval
    boundary. [input] is the invocation input selected by the provider. *)
type tool_approval_request =
  { prompt : tool_approval_prompt
  ; invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

(** Closed authorization result for an exact tool occurrence. *)
type tool_approval =
  | Approved
  | Denied
  | Timed_out

(** Caller-owned synchronous settlement callback for an exact tool occurrence.
    It must return a closed decision. If the caller needs a timeout, remote
    prompt, or restart recovery, it must settle those concerns before returning;
    [Timed_out] reports a timeout already enforced by the caller. *)
type tool_approval_callback = tool_approval_request -> tool_approval

(** Closed set of lifecycle stages accepted by the hook decision matrix. *)
type hook_stage =
  | Before_turn
  | Before_turn_params
  | After_turn
  | Pre_tool_use
  | Post_tool_use
  | Post_tool_use_failure
  | On_stop
  | On_error
  | On_tool_error

(** Decision returned by a hook *)
type hook_decision =
  | Continue
  | AdjustParams of turn_params
  | ElicitInput of elicitation_request
  | ElicitToolApproval of tool_approval_prompt
  (** PreToolUse only: ask the caller to settle the exact invocation through
      {!tool_approval_callback}. Generic [ElicitInput] answers cannot grant
      execution authority. *)
  | Nudge of string (** BeforeTurn: inject a user-role message before tool preparation. *)
  | HookFailed of
      { stage : hook_stage
      ; detail : string
      }
  (** Returned by [invoke_validated] when a user hook raises or
      returns a stage-illegal decision. Call sites must handle this explicitly;
      the SDK does not coerce it to [Continue]. *)
  | Block of string
  (** PreToolUse only: intentional caller rejection. The host executes no tool
      and emits an [is_error=true], [Non_retryable_tool_error] tool result whose
      content is the string payload verbatim. Distinct from [HookFailed], which
      represents an unintentional hook failure. Legal only at [PreToolUse];
      rejected elsewhere via {!validate_decision}. *)

type hook = hook_event -> hook_decision

(** Collection of optional hooks *)
type hooks =
  { before_turn : hook option
  ; before_turn_params : hook option
  ; after_turn : hook option
  ; pre_tool_use : hook option
  ; post_tool_use : hook option
  ; post_tool_use_failure : hook option
  ; on_stop : hook option
  ; on_error : hook option
  ; on_tool_error : hook option
  }

(** Context injection: data returned by a context_injector after tool execution *)
type injection =
  { context_updates : (string * Yojson.Safe.t) list
  ; extra_messages : Types.message list
  }

(** Context injector: called after tool execution to inject external state *)
type context_injector =
  tool_name:string -> input:Yojson.Safe.t -> output:Types.tool_result -> injection option

val empty : hooks

(** {2 Decision validity matrix}

    Each hook stage accepts only a subset of decisions.
    Returning an unlisted decision is a programming error.

    {v
    Stage                | Continue | AdjustParams | ElicitInput | ElicitToolApproval | Nudge | Block
    ---------------------+----------+--------------+-------------+-------------------+-------+------
    before_turn          |    Y     |              |      Y      |                   |   Y   |
    before_turn_params   |    Y     |      Y       |             |       |
    after_turn           |    Y     |              |             |       |
    pre_tool_use         |    Y     |              |             |         Y         |       |   Y
    post_tool_use        |    Y     |              |             |       |
    post_tool_use_failure|    Y     |              |             |       |
    on_stop              |    Y     |              |             |       |
    on_error             |    Y     |              |             |       |
    on_tool_error        |    Y     |              |             |       |
    v}

    The closed {!hook_stage} variant makes unknown stages unrepresentable. *)

(** Classification tag for hook_decision, without payload. *)
type hook_decision_kind =
  | K_Continue
  | K_AdjustParams
  | K_ElicitInput
  | K_ElicitToolApproval
  | K_Nudge
  | K_HookFailed
  | K_Block

(** Extract the kind tag from a decision value. *)
val classify_decision : hook_decision -> hook_decision_kind

(** Human-readable name for a decision kind. *)
val decision_kind_to_string : hook_decision_kind -> string

(** Extract the typed stage from a hook event. *)
val stage_of_event : hook_event -> hook_stage

(** Human-readable stage name for logs and error projections. *)
val hook_stage_to_string : hook_stage -> string

(** Return the legal decision kinds for the typed stage. *)
val legal_decisions_for_stage : hook_stage -> hook_decision_kind list

(** Validate a decision against the matrix for the given stage.
    Returns [Ok decision] when legal, [Error msg] otherwise. *)
val validate_decision
  :  stage:hook_stage
  -> hook_decision
  -> (hook_decision, string) result

(** Invoke a hook and validate its decision against the matrix.
    Illegal decisions return [HookFailed]; the rejection is logged as a warning
    (including [hook_name] when given) and [on_illegal] is called with
    diagnostics when a violation is detected. *)
val invoke_validated
  :  ?hook_name:string
  -> ?on_illegal:(stage:hook_stage -> decision:hook_decision -> msg:string -> unit)
  -> hook option
  -> hook_event
  -> hook_decision

(** Compose two hook sets. [outer] fires first for each slot.
    If [outer] returns a non-Continue decision, [inner] is bypassed.
    If [outer] returns [Continue], [inner] fires and its decision is used. *)
val compose : outer:hooks -> inner:hooks -> hooks
