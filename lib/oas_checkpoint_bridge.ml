(** OAS Checkpoint bridge for Perpetual Loop state persistence.

    Converts between MASC's [loop_state + working_context] and
    OAS [Checkpoint.t] for portable state snapshots.

    OAS Checkpoint provides:
    - Atomic file writes (write to .tmp, then rename)
    - Version-tracked serialization
    - Session-based file layout

    @since 2.90.0 *)

(** Convert a MASC Llm_client.message to an OAS Types.message.
    Delegates to [Llm_client.to_oas_message] — the canonical conversion. *)
let masc_msg_to_oas (m : Llm_client.message) : Agent_sdk.Types.message =
  Llm_client.to_oas_message m

(** Convert an OAS Types.message back to MASC Llm_client.message.
    Delegates to [Llm_client.of_oas_message]. *)
let oas_msg_to_masc (m : Agent_sdk.Types.message) : Llm_client.message =
  Llm_client.of_oas_message m

(** Minimal perpetual-loop state needed for OAS checkpoint persistence. *)
type checkpoint_state = {
  session_id : string;
  generation : int;
  turn_count : int;
  total_tokens : int;
  total_cost : float;
  trace_id : string;
}

(** Build an OAS Checkpoint from perpetual loop state and working context.
    Stores MASC-specific metadata (generation, goal, turn_count) in the
    checkpoint's context via scoped keys. *)
let to_oas_checkpoint
    ~(state : checkpoint_state)
    ~(ctx : Context_manager.working_context)
    ~(goal : string)
  : Agent_sdk.Checkpoint.t =
  let oas_ctx = Agent_sdk.Context.copy ctx.oas_context in
  (* Store MASC metadata in Session scope *)
  Agent_sdk.Context.set_scoped oas_ctx Agent_sdk.Context.Session
    "goal" (`String goal);
  Agent_sdk.Context.set_scoped oas_ctx Agent_sdk.Context.Session
    "generation" (`Int state.generation);
  Agent_sdk.Context.set_scoped oas_ctx Agent_sdk.Context.Session
    "turn_count" (`Int state.turn_count);
  Agent_sdk.Context.set_scoped oas_ctx Agent_sdk.Context.Session
    "trace_id" (`String state.trace_id);
  Agent_sdk.Context.set_scoped oas_ctx Agent_sdk.Context.App
    "masc_version" (`String Version.version);
  let messages = List.map masc_msg_to_oas ctx.messages in
  {
    Agent_sdk.Checkpoint.version = 3;
    session_id = state.session_id;
    agent_name = "perpetual";
    model = Agent_sdk.Types.Custom "masc-perpetual";
    system_prompt = Some ctx.system_prompt;
    messages;
    usage = {
      Agent_sdk.Types.total_input_tokens = state.total_tokens;
      total_output_tokens = 0;
      total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0;
      api_calls = state.turn_count;
      estimated_cost_usd = state.total_cost;
    };
    turn_count = state.turn_count;
    created_at = Time_compat.now ();
    tools = [];
    tool_choice = None;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    response_format_json = false;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = Some ctx.max_tokens;
    max_total_tokens = None;
    context = oas_ctx;
    mcp_sessions = [];
    disable_parallel_tool_use = false;
  }

(** Extract MASC metadata from an OAS Checkpoint for loop state initialization. *)
let from_oas_checkpoint (ckpt : Agent_sdk.Checkpoint.t)
  : (string * int * Agent_sdk.Types.message list) =
  let ctx = ckpt.context in
  let goal =
    match Agent_sdk.Context.get_scoped ctx Agent_sdk.Context.Session "goal" with
    | Some (`String g) -> g
    | _ -> ""
  in
  let generation =
    match Agent_sdk.Context.get_scoped ctx Agent_sdk.Context.Session "generation" with
    | Some (`Int g) -> g
    | _ -> 0
  in
  (goal, generation, ckpt.messages)

(** Convert OAS messages back to MASC messages for working context init. *)
let restore_messages (oas_msgs : Agent_sdk.Types.message list) : Llm_client.message list =
  List.map oas_msg_to_masc oas_msgs
