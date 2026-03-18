(** MASC Spawn - OAS Agent.t based agent execution.

    All agent execution routes through Provider_adapter → OAS Agent.t.
    CLI subprocess path has been removed. Every agent is a real OAS agent.

    @since 2.106.0 — Provider_adapter routing, CLI subprocess removed *)

module Oas = Agent_sdk

(** Spawn configuration for an agent *)
type spawn_config = {
  agent_name: string;
  command: string;
  timeout_seconds: int;
  working_dir: string option;
  mcp_tools: string list;
}

(** Structured termination reason for subagent lifecycle tracking *)
type termination_reason =
  | Task_completed
  | Error_budget_exceeded of { errors: int; max_errors: int }
  | Timeout of { elapsed_ms: int; limit_ms: int }
  | User_interrupt
  | Resource_limit of string
  | Unknown_failure of { exit_code: int; message: string }

(** Termination record capturing why and how an agent finished *)
type termination_record = {
  reason: termination_reason;
  agent_name: string;
  elapsed_ms: int;
  tool_call_count: int;
  input_tokens: int option;
  output_tokens: int option;
  cost_usd: float option;
}

(** Spawn result with token tracking *)
type spawn_result = {
  success: bool;
  output: string;
  exit_code: int;
  elapsed_ms: int;
  tool_call_count: int;
  tool_names: string list;
  input_tokens: int option;
  output_tokens: int option;
  cache_creation_tokens: int option;
  cache_read_tokens: int option;
  cost_usd: float option;
  raw_trace_run: Oas.Raw_trace.run_ref option;
  termination: termination_record option;
}

let termination_reason_to_string = function
  | Task_completed -> "task_completed"
  | Error_budget_exceeded { errors; max_errors } ->
      Printf.sprintf "error_budget_exceeded (errors=%d, max=%d)" errors max_errors
  | Timeout { elapsed_ms; limit_ms } ->
      Printf.sprintf "timeout (elapsed=%dms, limit=%dms)" elapsed_ms limit_ms
  | User_interrupt -> "user_interrupt"
  | Resource_limit msg -> Printf.sprintf "resource_limit: %s" msg
  | Unknown_failure { exit_code; message } ->
      Printf.sprintf "unknown_failure (exit=%d): %s" exit_code message

(** Build a termination record from a completed spawn result *)
let make_termination ~agent_name ~exit_code ~elapsed_ms ~tool_call_count
    ~input_tokens ~output_tokens ~cost_usd ~output ~timeout_seconds
    : termination_record =
  let limit_ms = timeout_seconds * 1000 in
  let reason = match exit_code with
    | 0 -> Task_completed
    | 124 -> Timeout { elapsed_ms; limit_ms }
    | -1 -> User_interrupt
    | 2 -> Resource_limit (Provider_adapter.bare_ollama_migration_message ())
    | code -> Unknown_failure { exit_code = code; message = output }
  in
  { reason; agent_name; elapsed_ms; tool_call_count;
    input_tokens; output_tokens; cost_usd }

(** MASC MCP tools available for spawned agents *)
let masc_mcp_tools = Agent_tool_surfaces.spawned_agent_prefixed_tools

let llama_mcp_tools = Agent_tool_surfaces.llama_worker_prefixed_tools

let coding_worker_mcp_tools =
  [ "mcp__masc__masc_heartbeat"; "mcp__masc__masc_memento_mori" ]

(** State isolation: keys excluded from parent context when spawning subagents.
    Spawned agents receive only their explicit task prompt, institution memory,
    and MASC lifecycle suffix. Parent's working context is excluded.
    This follows Deep Agents' _EXCLUDED_STATE_KEYS pattern. *)
let excluded_state_keys = [
  "messages";
  "full_history";
  "todos";
  "skills_metadata";
  "memory_contents";
]

let state_isolation_notice = {|
[State Isolation Notice]
You are running in an isolated context. You do not have access to the parent agent's
conversation history or working state. Focus on your assigned task and return results
when complete.
|}

let masc_lifecycle_suffix = {|
---
[MASC Capabilities — Available to you]

You are part of a MASC-coordinated workspace. These tools are available
for coordination — use them when they help accomplish your goal:

- masc_join / masc_leave: Announce presence (recommended at start/end)
- masc_heartbeat: Share liveness during long tasks (~2 min intervals)
- masc_memento_mori: Monitor context usage and remaining capacity
  - context_ratio 0.0–0.5: Normal operation
  - context_ratio 0.5–0.8: Consider preparing a handoff summary
  - context_ratio 0.8+: Handoff to successor is strongly recommended
- masc_transition: Signal task completion or state change

These are coordination aids, not rigid protocols. Prioritize your assigned goal.
If context runs low, use masc_memento_mori to decide whether to handoff.
---
|}

(** Resolve model_spec from agent_name when runtime_model is not provided.
    Uses Provider_adapter to determine provider family, then constructs
    a provider:model_id label and parses it into a model_spec. *)
let resolve_model_spec agent_name =
  match Provider_adapter.resolve_direct_adapter agent_name with
  | None ->
      Error (Printf.sprintf
        "Unknown agent '%s': not registered in Provider_adapter.direct_adapters"
        agent_name)
  | Some adapter ->
      let label_result = match adapter.provider_family with
        | Provider_adapter.Claude_family ->
            let m = Env_config.Claude.default_model in
            if m = "" then Error "No Claude model configured (MASC_CLAUDE_DEFAULT_MODEL)"
            else Ok ("claude:" ^ m)
        | Provider_adapter.Gemini_family ->
            let m = Env_config.Gemini.default_model in
            if m = "" then Error "No Gemini model configured (MASC_GEMINI_DEFAULT_MODEL)"
            else Ok ("gemini:" ^ m)
        | Provider_adapter.OpenAI_family ->
            let m = Env_config.OpenAI.default_model in
            if m = "" then Error "No OpenAI model configured (MASC_OPENAI_DEFAULT_MODEL)"
            else Ok ("openai:" ^ m)
        | Provider_adapter.Glm_family ->
            let m = Env_config.Llm.default_model in
            Ok ("glm:" ^ (if m = "" then "auto" else m))
        | Provider_adapter.Llama_family ->
            Provider_adapter.explicit_llama_model_label_result ()
        | Provider_adapter.OpenRouter_family ->
            Error "OpenRouter requires explicit runtime_model"
        | Provider_adapter.Custom_family _ ->
            Error "Custom provider requires explicit runtime_model"
      in
      Result.bind label_result Llm_client.model_spec_of_string

(** Build a spawn error result. Reduces boilerplate in spawn routing. *)
let make_error_result ~agent_name ~start_time ~exit_code ~output ~timeout_seconds =
  let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
  {
    success = false;
    output;
    exit_code;
    elapsed_ms = elapsed;
    tool_call_count = 0;
    tool_names = [];
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
    raw_trace_run = None;
    termination = Some (make_termination ~agent_name ~exit_code ~elapsed_ms:elapsed
      ~tool_call_count:0 ~input_tokens:None ~output_tokens:None ~cost_usd:None
      ~output ~timeout_seconds);
  }
(** Spawn an agent using OAS Agent.t via Provider_adapter routing.

    All providers route through Local_agent_eio.run_worker (OAS Agent.t).
    CLI subprocess path has been removed — every agent is a real OAS agent.

    Agent Being Protocol: Cultural Inheritance
    - When room_config is provided, loads institution memory and injects it
    - New agents inherit: mission, values, patterns, onboarding steps
*)
let spawn ~sw ~proc_mgr:_ ~agent_name ~prompt ?timeout_seconds ?working_dir
    ?room_config ?runtime_agent_name ?runtime_model ?runtime_role
    ?runtime_session_id ?runtime_selection_note ?worker_run_id ?worker_class ?worker_size
    ?execution_scope ?thinking_enabled ?max_turns ?model_override:_ () : spawn_result =
  let start_time = Time_compat.now () in
  let normalized_agent = String.lowercase_ascii (String.trim agent_name) in
  let timeout = Option.value timeout_seconds ~default:Env_config.Spawn.timeout_seconds in

  if Provider_adapter.is_bare_ollama_label normalized_agent then
    make_error_result ~agent_name ~start_time ~exit_code:2
      ~output:(Provider_adapter.bare_ollama_migration_message ())
      ~timeout_seconds:timeout
  else

  (* Resolve model: explicit runtime_model > auto from Provider_adapter *)
  let model_result = match runtime_model with
    | Some model -> Ok model
    | None -> resolve_model_spec agent_name
  in
  match model_result with
  | Error msg ->
      make_error_result ~agent_name ~start_time ~exit_code:1
        ~output:(Printf.sprintf "Spawn error (model resolution): %s" msg)
        ~timeout_seconds:timeout
  | Ok model ->

  (* Institution memory for cultural inheritance *)
  let institution_memory =
    let load_institution_sync base_path =
      let inst_file = Filename.concat (Filename.concat base_path ".masc") "institution.json" in
      if Sys.file_exists inst_file then
        try
          let content = Fs_compat.load_file inst_file in
          let json = Yojson.Safe.from_string content in
          let inst = Institution_eio.institution_of_json json in
          Institution_eio.format_for_injection inst
        with exn ->
          Eio.traceln "[spawn_eio] Institution load failed: %s" (Printexc.to_string exn);
          ""
      else ""
    in
    match room_config with
    | Some rc -> load_institution_sync rc.Room_utils.base_path
    | None ->
        match working_dir with
        | Some wd -> load_institution_sync wd
        | None -> ""
  in

  let role_instructions =
    match execution_scope with
    | Some Team_session_types.Autonomous ->
        "\n" ^ Agent_swarm_prompts.masc_instructions_for_role ~role:"autonomous" ()
    | _ -> ""
  in
  let augmented_prompt =
    prompt ^ institution_memory ^ masc_lifecycle_suffix ^ role_instructions
    ^ state_isolation_notice
  in

  (* Worker name *)
  let worker_name =
    match runtime_agent_name with
    | Some name when String.trim name <> "" -> String.trim name
    | _ ->
        let digest =
          Digest.string (Printf.sprintf "%f:%d:%s" start_time (Unix.getpid ()) prompt)
          |> Digest.to_hex
        in
        Printf.sprintf "%s-%s"
          (String.lowercase_ascii agent_name) (String.sub digest 0 8)
  in

  let base_path =
    match room_config with
    | Some rc -> rc.Room_utils.base_path
    | None ->
        (match working_dir with
         | Some dir -> dir
         | None -> Sys.getcwd ())
  in
  let worker_working_dir =
    match working_dir with
    | Some dir when String.trim dir <> "" -> Some dir
    | _ ->
        Option.map
          (fun (rc : Room_utils.config) -> rc.workspace_path)
          room_config
  in

  let allowed_tools =
    match execution_scope with
    | Some Team_session_types.Autonomous ->
        let resolvable =
          Agent_tool_surfaces.local_worker_resolvable_tool_names ()
        in
        Agent_tool_surfaces.build_tool_catalog ~role:"autonomous" ()
        |> List.filter (fun name -> List.mem name resolvable)
        |> Agent_tool_surfaces.prefixed_tool_names
    | Some Team_session_types.Limited_code_change ->
        coding_worker_mcp_tools
    | _ -> llama_mcp_tools
  in

  (* All providers route through OAS Agent.t via Local_agent_eio.run_worker *)
  match
    Local_agent_eio.run_worker ~sw ~base_path ~worker_name ~model
      ~room_config
      ~team_session_id:runtime_session_id ~role:runtime_role
      ?working_dir:worker_working_dir ?worker_run_id ?worker_class ?worker_size
      ?execution_scope ?thinking_enabled ?max_turns
      ~selection_note:runtime_selection_note
      ~prompt:augmented_prompt
      ~allowed_tools ~timeout_sec:timeout ()
  with
  | Ok result ->
      let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
      {
        success = true;
        output = result.output;
        exit_code = 0;
        elapsed_ms = elapsed;
        tool_call_count = result.tool_call_count;
        tool_names = result.tool_names;
        input_tokens = result.input_tokens;
        output_tokens = result.output_tokens;
        cache_creation_tokens = None;
        cache_read_tokens = None;
        cost_usd = result.cost_usd;
        raw_trace_run = result.raw_trace_run;
        termination = Some { reason = Task_completed; agent_name;
          elapsed_ms = elapsed; tool_call_count = result.tool_call_count;
          input_tokens = result.input_tokens; output_tokens = result.output_tokens;
          cost_usd = result.cost_usd };
      }
  | Error e ->
      let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
      let output = Printf.sprintf "Spawn error (OAS): %s" e in
      {
        success = false;
        output;
        exit_code = 1;
        elapsed_ms = elapsed;
        tool_call_count = 0;
        tool_names = [];
        input_tokens = None;
        output_tokens = None;
        cache_creation_tokens = None;
        cache_read_tokens = None;
        cost_usd = None;
        raw_trace_run = None;
        termination = Some { reason = Unknown_failure { exit_code = 1; message = output };
          agent_name; elapsed_ms = elapsed; tool_call_count = 0;
          input_tokens = None; output_tokens = None; cost_usd = None };
      }

let result_to_human_string (result : spawn_result) =
  let token_info =
    match result.input_tokens, result.output_tokens, result.cost_usd with
    | Some inp, Some out, Some cost ->
      let cache = match result.cache_creation_tokens, result.cache_read_tokens with
        | Some cc, Some cr when cc > 0 || cr > 0 -> Printf.sprintf " (cache: +%d, %d)" cc cr
        | _ -> ""
      in
      Printf.sprintf "\n📊 Tokens: %d in / %d out%s | Cost: $%.4f" inp out cache cost
    | _ -> ""
  in
  let termination_info =
    match result.termination with
    | Some t -> Printf.sprintf "\n🔚 Termination: %s" (termination_reason_to_string t.reason)
    | None -> ""
  in
  if result.success then
    Printf.sprintf "✅ Agent completed in %dms%s%s\n\n%s"
      result.elapsed_ms token_info termination_info result.output
  else
    Printf.sprintf "❌ Agent failed (exit %d) in %dms%s%s\n\n%s"
      result.exit_code result.elapsed_ms token_info termination_info result.output
