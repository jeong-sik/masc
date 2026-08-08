(** Lifecycle hooks for agent execution.
    Inspired by Anthropic SDK PreToolUse/PostToolUse/Stop
    and Google ADK ToolContext patterns.

    All hook types use exhaustive variants for compile-time safety. *)

open Types

(** Per-turn adjustable parameters.
    Hooks can return [AdjustParams] from [BeforeTurnParams] to override
    these for a single turn. Values revert to the agent's base config
    on the next turn. *)
type turn_params =
  { temperature : float option
  ; thinking_budget : int option
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; tool_choice : tool_choice option
  ; extra_system_context : string option
  ; system_prompt_override : string option
  }

let default_turn_params =
  { temperature = None
  ; thinking_budget = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; tool_choice = None
  ; extra_system_context = None
  ; system_prompt_override = None
  }
;;

(** Reasoning summary extracted from assistant messages.
    Hooks can inspect this to decide per-turn parameter adjustments. *)
type reasoning_summary =
  { thinking_blocks : string list
  ; has_uncertainty : bool
  ; tool_rationale : string option
  }

let empty_reasoning_summary =
  { thinking_blocks = []; has_uncertainty = false; tool_rationale = None }
;;

(** Extract structured reasoning summary from message list.
    This only preserves provider-emitted Thinking blocks; it does not infer
    uncertainty or tool rationale from prose. *)
let extract_reasoning (messages : message list) : reasoning_summary =
  let thinking_blocks =
    List.concat_map
      (fun (msg : message) ->
         List.filter_map
           (function
             | Thinking { content; _ } -> Some content
             | ReasoningDetails { reasoning_content; details } ->
               let content = reasoning_details_text ~reasoning_content ~details in
               if content = "" then None else Some content
             | Text _
             | RedactedThinking _
             | ToolUse _
             | ToolResult _
             | Image _
             | Document _
             | Audio _ -> None)
           msg.content)
      messages
  in
  { thinking_blocks; has_uncertainty = false; tool_rationale = None }
;;

(** Events emitted during agent execution *)
type hook_event =
  | BeforeTurn of
      { turn : int
      ; messages : message list
      }
  | BeforeTurnParams of
      { turn : int
      ; messages : message list
      ; last_tool_results : tool_result list
      ; current_params : turn_params
      ; reasoning : reasoning_summary
      }
  | AfterTurn of
      { turn : int
      ; response : api_response
      }
  | PreToolUse of
      { invocation : Tool_contract.Invocation.t
      ; tool_name : string
      ; input : Yojson.Safe.t
      ; accumulated_cost_usd : float
      }
  | PostToolUse of
      { invocation : Tool_contract.Invocation.t
      ; tool_name : string
      ; input : Yojson.Safe.t
      ; output : Types.tool_result
      ; result_bytes : int
      ; duration_ms : float
      }
  | PostToolUseFailure of
      { invocation : Tool_contract.Invocation.t
      ; tool_name : string
      ; input : Yojson.Safe.t
      ; error : string
      }
  | OnStop of
      { reason : stop_reason
      ; response : api_response
      }
  | OnError of
      { invocation : Tool_contract.Invocation.t option
      ; detail : string
      ; context : string
      }
  | OnToolError of
      { invocation : Tool_contract.Invocation.t
      ; tool_name : string
      ; error : string
      }

let invocation_of_event = function
  | PreToolUse { invocation; _ }
  | PostToolUse { invocation; _ }
  | PostToolUseFailure { invocation; _ }
  | OnToolError { invocation; _ } -> Some invocation
  | OnError { invocation; _ } -> invocation
  | BeforeTurn _ | BeforeTurnParams _ | AfterTurn _ | OnStop _ -> None
;;

(** Elicitation: structured request for user input during agent execution.
    Inspired by Claude SDK MCP Elicitation pattern. *)
type elicitation_request =
  { question : string
  ; schema : Yojson.Safe.t option (** JSON Schema for expected answer *)
  ; timeout_s : float option
  }

type elicitation_response =
  | Answer of Yojson.Safe.t
  | Declined
  | Timeout

(** Elicitation callback: called when a hook returns ElicitInput.
    Returns the user's response or Declined/Timeout. *)
type elicitation_callback = elicitation_request -> elicitation_response

(** A pre-tool authorization cannot be represented by [Answer of Yojson.Safe.t]:
    that value is user input, not execution authority. Keep the prompt and the
    exact runtime request distinct so malformed data is unrepresentable at the
    authorization boundary. *)
type tool_approval_prompt = { question : string }

type tool_approval_request =
  { prompt : tool_approval_prompt
  ; invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type tool_approval =
  | Approved
  | Denied
  | Timed_out

type tool_approval_callback = tool_approval_request -> tool_approval

(** Typed lifecycle stage used by the hook decision matrix. *)
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
  (** BeforeTurnParams only: override params for this turn *)
  | ElicitInput of elicitation_request (** Request user input before proceeding *)
  | ElicitToolApproval of tool_approval_prompt
  (** PreToolUse only: request a caller-owned exact-tool authorization. *)
  | Nudge of string (** BeforeTurn: inject a user-role message before tool preparation. *)
  | HookFailed of
      { stage : hook_stage
      ; detail : string
      }
  (** Internal failure decision returned when invoking a user hook raises or
      returns a stage-illegal decision. Call sites must handle this explicitly;
      it is never coerced to [Continue]. *)
  | Block of string
  (** PreToolUse only: intentional caller rejection. The host executes no tool
      and produces an [is_error=true] tool result ([Non_retryable_tool_error],
      [Deterministic]) whose content is the string payload verbatim. Distinct
      from [HookFailed], which represents an unintentional hook failure. Use
      this when the embedding application has already made an explicit
      decision outside OAS. *)

(** A hook function *)
type hook = hook_event -> hook_decision

(** Collection of optional hooks *)
type hooks =
  { before_turn : hook option
  ; before_turn_params : hook option (** Called before each turn to adjust parameters *)
  ; after_turn : hook option
  ; pre_tool_use : hook option
  ; post_tool_use : hook option
  ; post_tool_use_failure : hook option
  ; on_stop : hook option
  ; on_error : hook option
  ; on_tool_error : hook option
  }

(** Empty hooks -- no-op default *)
let empty =
  { before_turn = None
  ; before_turn_params = None
  ; after_turn = None
  ; pre_tool_use = None
  ; post_tool_use = None
  ; post_tool_use_failure = None
  ; on_stop = None
  ; on_error = None
  ; on_tool_error = None
  }
;;

(** Context injection: data returned by a context_injector after tool execution.
    [context_updates] are key-value pairs to set in the shared Context.
    [extra_messages] are appended to the conversation (e.g., system observations). *)
type injection =
  { context_updates : (string * Yojson.Safe.t) list
  ; extra_messages : Types.message list
  }

(** Context injector: called after tool execution to inject external state.
    Returns [Some injection] to update context/messages, [None] to skip. *)
type context_injector =
  tool_name:string -> input:Yojson.Safe.t -> output:Types.tool_result -> injection option

(** Classification of hook_decision variants for the decision matrix.
    Using a separate type avoids comparing functional values
   (AdjustParams and elicitation decisions carry payloads). *)
type hook_decision_kind =
  | K_Continue
  | K_AdjustParams
  | K_ElicitInput
  | K_ElicitToolApproval
  | K_Nudge
  | K_HookFailed
  | K_Block

let classify_decision = function
  | Continue -> K_Continue
  | AdjustParams _ -> K_AdjustParams
  | ElicitInput _ -> K_ElicitInput
  | ElicitToolApproval _ -> K_ElicitToolApproval
  | Nudge _ -> K_Nudge
  | HookFailed _ -> K_HookFailed
  | Block _ -> K_Block
;;

let decision_kind_to_string = function
  | K_Continue -> "Continue"
  | K_AdjustParams -> "AdjustParams"
  | K_ElicitInput -> "ElicitInput"
  | K_ElicitToolApproval -> "ElicitToolApproval"
  | K_Nudge -> "Nudge"
  | K_HookFailed -> "HookFailed"
  | K_Block -> "Block"
;;

(** Extract the typed stage from a hook event. *)
let stage_of_event = function
  | BeforeTurn _ -> Before_turn
  | BeforeTurnParams _ -> Before_turn_params
  | AfterTurn _ -> After_turn
  | PreToolUse _ -> Pre_tool_use
  | PostToolUse _ -> Post_tool_use
  | PostToolUseFailure _ -> Post_tool_use_failure
  | OnStop _ -> On_stop
  | OnError _ -> On_error
  | OnToolError _ -> On_tool_error
;;

let hook_stage_to_string = function
  | Before_turn -> "before_turn"
  | Before_turn_params -> "before_turn_params"
  | After_turn -> "after_turn"
  | Pre_tool_use -> "pre_tool_use"
  | Post_tool_use -> "post_tool_use"
  | Post_tool_use_failure -> "post_tool_use_failure"
  | On_stop -> "on_stop"
  | On_error -> "on_error"
  | On_tool_error -> "on_tool_error"
;;

(** Legal decision matrix.

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

    Fail-closed: any decision not explicitly listed is rejected. [Block] is
    legal only at [pre_tool_use].

    [ElicitInput] is legal only at [before_turn], where it asks before the model
    runs. [ElicitToolApproval] is legal only at [pre_tool_use] and its separate
    typed callback settles the exact call before its invocation is opened. A
    caller gate that authorizes a specific command with a specific input can
    only decide once both exist, which is after the model has chosen them.
    Without this,
    such a gate has to answer the call without caller input, and
    {!Llm_provider.Types.tool_result_outcome} offers only [Tool_succeeded] or
    [Tool_failed] — so a deferral would have to report a success that did not
    happen. *)
let legal_decisions_for_stage stage =
  match stage with
  | Before_turn -> [ K_Continue; K_ElicitInput; K_Nudge ]
  | Before_turn_params -> [ K_Continue; K_AdjustParams ]
  | After_turn -> [ K_Continue ]
  | Pre_tool_use -> [ K_Continue; K_Block; K_ElicitToolApproval ]
  | Post_tool_use | Post_tool_use_failure | On_stop | On_error | On_tool_error ->
    [ K_Continue ]
;;

(** Validate that a hook_decision is legal for a given stage.
    Fail-closed: unknown stages and unlisted decisions return Error. *)
let validate_decision ~stage decision =
  let kind = classify_decision decision in
  let legal = legal_decisions_for_stage stage in
  if List.mem kind legal
  then Ok decision
  else (
    let msg =
      Printf.sprintf
        "illegal hook decision %s at stage %s; legal: [%s]"
        (decision_kind_to_string kind)
        (hook_stage_to_string stage)
        (String.concat ", " (List.map decision_kind_to_string legal))
    in
    Error msg)
;;

(* Run a user-supplied hook and capture its decision. All exceptions classified
   by [Reserved_exn] propagate; anything else is captured so callers can fail
   closed without losing stage/detail provenance. *)
let try_hook f event =
  try Ok (f event) with
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    Error exn
;;

let hook_failed ~stage detail = HookFailed { stage; detail }

let warn_hook_raised stage exn =
  let detail = Printexc.to_string exn in
  Eio.traceln
    "[warn] [hooks] user hook for %s raised %s"
    (hook_stage_to_string stage)
    detail;
  hook_failed ~stage detail
;;

(** Invoke a hook with decision validation.
    If the hook returns an illegal decision for the stage,
    logs a warning (naming the stage, the rejected decision and, when
    [hook_name] is given, the hook), returns [HookFailed] and calls
    [on_illegal] (if provided).
    If the hook raises (non-reserved), the exception is logged and [HookFailed]
    is returned without invoking [on_illegal] (which is reserved for
    decision-shape errors, not exceptions). *)
let invoke_validated ?hook_name ?on_illegal hook_opt event =
  match hook_opt with
  | None -> Continue
  | Some f ->
    let stage = stage_of_event event in
    (match try_hook f event with
     | Error exn -> warn_hook_raised stage exn
     | Ok decision ->
       (match validate_decision ~stage decision with
        | Ok d -> d
        | Error msg ->
          Eio.traceln
            "[warn] [hooks] %s%s"
            msg
            (match hook_name with
             | Some name -> Printf.sprintf " (hook: %s)" name
             | None -> "");
          Option.iter (fun cb -> cb ~stage ~decision ~msg) on_illegal;
          hook_failed ~stage msg))
;;

(** Compose a single hook slot. [outer] fires first.
    If outer returns a non-Continue decision, inner is bypassed. *)
let compose_hook (outer : hook option) (inner : hook option) : hook option =
  match outer, inner with
  | None, None -> None
  | Some _, None -> outer
  | None, Some _ -> inner
  | Some f_outer, Some f_inner ->
    Some
      (fun event ->
        match f_outer event with
        | Continue -> f_inner event
        | HookFailed _ as failed -> failed
        | decision -> decision)
;;

let compose ~outer ~inner =
  { before_turn = compose_hook outer.before_turn inner.before_turn
  ; before_turn_params = compose_hook outer.before_turn_params inner.before_turn_params
  ; after_turn = compose_hook outer.after_turn inner.after_turn
  ; pre_tool_use = compose_hook outer.pre_tool_use inner.pre_tool_use
  ; post_tool_use = compose_hook outer.post_tool_use inner.post_tool_use
  ; post_tool_use_failure =
      compose_hook outer.post_tool_use_failure inner.post_tool_use_failure
  ; on_stop = compose_hook outer.on_stop inner.on_stop
  ; on_error = compose_hook outer.on_error inner.on_error
  ; on_tool_error = compose_hook outer.on_tool_error inner.on_tool_error
  }
;;

(* ── Hook exception safety regression tests ─────────────────── *)

let%test "invoke_validated: hook returning Continue propagates" =
  let event = BeforeTurn { turn = 0; messages = [] } in
  match invoke_validated (Some (fun _ -> Continue)) event with
  | Continue -> true
  | _ -> false
;;

let%test "invoke_validated: None hook returns Continue" =
  let event = BeforeTurn { turn = 0; messages = [] } in
  match invoke_validated None event with
  | Continue -> true
  | _ -> false
;;

let%test "invoke_validated: Sys.Break remains reserved" =
  let event = BeforeTurn { turn = 0; messages = [] } in
  match invoke_validated (Some (fun _ -> raise Sys.Break)) event with
  | exception Sys.Break -> true
  | (exception _)
  | Continue
  | AdjustParams _
  | ElicitInput _
  | ElicitToolApproval _
  | Nudge _
  | HookFailed _
  | Block _ -> false
;;

(* ── Block variant (RFC-0321) regression tests ─────────────── *)

let%test "Block: classify_decision tags as K_Block" =
  classify_decision (Block "forbidden") = K_Block
;;

let%test "Block: decision_kind_to_string" = decision_kind_to_string K_Block = "Block"

let%test "Block: legal only at pre_tool_use" =
  List.mem K_Block (legal_decisions_for_stage Pre_tool_use)
  && (not (List.mem K_Block (legal_decisions_for_stage Before_turn)))
  && (not (List.mem K_Block (legal_decisions_for_stage After_turn)))
  && not (List.mem K_Block (legal_decisions_for_stage Post_tool_use))
;;

let%test "Block: validate_decision accepts at pre_tool_use" =
  validate_decision ~stage:Pre_tool_use (Block "nope") = Ok (Block "nope")
;;

let%test "Block: validate_decision rejects at after_turn" =
  match validate_decision ~stage:After_turn (Block "nope") with
  | Error msg -> String.length msg > 0
  | Ok _ -> false
;;
