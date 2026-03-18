(** MASC Spawn - Eio Native Agent subprocess management *)

module Oas = Agent_sdk

(** Mutex to serialize Sys.chdir + process fork.
    Sys.chdir is process-global; under Eio's fiber concurrency,
    concurrent spawn_agent calls would race on CWD without this. *)
let chdir_mutex = Eio.Mutex.create ()

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

(** Parse Claude CLI JSON output for token tracking *)
let parse_claude_json output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let usage = json |> member "usage" in
    let input_tokens = usage |> member "input_tokens" |> to_int_option in
    let output_tokens = usage |> member "output_tokens" |> to_int_option in
    let cache_creation = usage |> member "cache_creation_input_tokens" |> to_int_option in
    let cache_read = usage |> member "cache_read_input_tokens" |> to_int_option in
    let cost_usd = json |> member "total_cost_usd" |> to_float_option in
    let result_text = json |> member "result" |> to_string_option in
    (result_text, input_tokens, output_tokens, cache_creation, cache_read, cost_usd)
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (Some output, None, None, None, None, None)

(** Extract Gemini CLI response text from JSON output. *)
let extract_gemini_response_text output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    json |> member "response" |> to_string_option
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    None

(** Parse Gemini output for token tracking
    Supports both:
    - Gemini API style: {"usageMetadata": {"promptTokenCount": N, "candidatesTokenCount": M, "cachedContentTokenCount": C}}
    - Gemini CLI JSON: {"response": "...", "stats": {"models": {"...": {"tokens": {...}}}}} *)
let parse_gemini_output output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let usage_opt =
      match json |> member "usageMetadata" with
      | `Assoc _ as usage -> Some usage
      | _ -> None
    in
    let stats_models_opt =
      match json |> member "stats" with
      | `Assoc _ as stats ->
          (match stats |> member "models" with
           | `Assoc entries -> Some entries
           | _ -> None)
      | _ -> None
    in
    let input_tokens =
      match Option.bind usage_opt (fun usage -> usage |> member "promptTokenCount" |> to_int_option) with
      | Some _ as value -> value
      | None ->
          (match stats_models_opt with
           | None -> None
           | Some entries ->
               let sum_field field =
                 entries
                 |> List.fold_left (fun acc (_name, item) ->
                     acc + (item |> member "tokens" |> member field |> to_int_option |> Option.value ~default:0)
                   ) 0
               in
               let input = sum_field "input" in
               let prompt = sum_field "prompt" in
               let chosen = if input > 0 then input else prompt in
               if chosen > 0 then Some chosen else None)
    in
    let output_tokens =
      match Option.bind usage_opt (fun usage -> usage |> member "candidatesTokenCount" |> to_int_option) with
      | Some _ as value -> value
      | None ->
          (match stats_models_opt with
           | None -> None
           | Some entries ->
               let total =
                 entries
                 |> List.fold_left (fun acc (_name, item) ->
                     acc + (item |> member "tokens" |> member "candidates" |> to_int_option |> Option.value ~default:0)
                   ) 0
               in
               if total > 0 then Some total else None)
    in
    let cached_tokens =
      match Option.bind usage_opt (fun usage -> usage |> member "cachedContentTokenCount" |> to_int_option) with
      | Some _ as value -> value
      | None ->
          (match stats_models_opt with
           | None -> None
           | Some entries ->
               let total =
                 entries
                 |> List.fold_left (fun acc (_name, item) ->
                     acc + (item |> member "tokens" |> member "cached" |> to_int_option |> Option.value ~default:0)
                   ) 0
               in
               if total > 0 then Some total else None)
    in
    (* Gemini 2.5: cached tokens are 90% cheaper *)
    let cost = match input_tokens, output_tokens, cached_tokens with
      | Some inp, Some out, Some cached ->
          let uncached = inp - cached in
          (* $0.15/1M uncached input, $0.015/1M cached, $0.60/1M output for 2.5 Flash *)
          Some (float_of_int uncached *. 0.00015 /. 1000.0 +.
                float_of_int cached *. 0.000015 /. 1000.0 +.
                float_of_int out *. 0.0006 /. 1000.0)
      | Some inp, Some out, None ->
          Some (float_of_int inp *. 0.00015 /. 1000.0 +. float_of_int out *. 0.0006 /. 1000.0)
      | _ -> None
    in
    (input_tokens, output_tokens, cached_tokens, cost)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None, None)

(** Parse Ollama output for token tracking
    Format: {"prompt_eval_count": N, "eval_count": M} *)
let parse_ollama_output output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let input_tokens = json |> member "prompt_eval_count" |> to_int_option in
    let output_tokens = json |> member "eval_count" |> to_int_option in
    (* Local ollama has no cost *)
    (input_tokens, output_tokens, Some 0.0)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None)

(** Parse Codex JSONL output for token tracking
    Last line format: {"type":"turn.completed","usage":{"input_tokens":N,"output_tokens":M}} *)
let parse_codex_output output =
  try
    (* Find the last line with turn.completed *)
    let lines = String.split_on_char '\n' output in
    let turn_completed = List.find_opt (fun line ->
      String.length line > 0 &&
      match Safe_ops.parse_json_safe ~context:"codex_parse" line with
      | Error _ -> false
      | Ok json ->
        Safe_ops.json_string "type" json = "turn.completed"
    ) (List.rev lines) in
    match turn_completed with
    | Some line ->
        let json = Yojson.Safe.from_string line in
        let open Yojson.Safe.Util in
        let usage = json |> member "usage" in
        let input_tokens = usage |> member "input_tokens" |> to_int_option in
        let output_tokens = usage |> member "output_tokens" |> to_int_option in
        let cached = usage |> member "cached_input_tokens" |> to_int_option in
        (* OpenAI pricing estimate: $15/1M input, $60/1M output *)
        let cost = match input_tokens, output_tokens with
          | Some inp, Some out ->
              Some (float_of_int inp *. 0.015 /. 1000.0 +. float_of_int out *. 0.06 /. 1000.0)
          | _ -> None
        in
        (input_tokens, output_tokens, cached, cost)
    | None -> (None, None, None, None)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None, None)

let default_configs = [
  ("claude", {
    agent_name = "claude";
    command = "claude --output-format json -p";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
  ("gemini", {
    agent_name = "gemini";
    command = "gemini --yolo --output-format json";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
  ("codex", {
    agent_name = "codex";
    command = "codex exec --json";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
  ("llama", {
    agent_name = "llama";
    command = "llama:explicit-model-required";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
  (* GLM uses Llm_client cascade via Lodge_cascade — no direct curl *)
  ("glm", {
    agent_name = "glm";
    command = "glm:via-llm-client";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = [];
  });
]

let get_config agent_name = 
  let canonical =
    match Provider_adapter.resolve_cli_canonical_name agent_name with
    | Some value -> value
    | None -> agent_name
  in
  List.assoc_opt canonical default_configs

(** Build MCP flags as argument list (no shell escaping needed) *)
let build_mcp_args agent_name tools =
  if tools = [] then []
  else
    match Provider_adapter.resolve_cli_canonical_name agent_name |> Option.value ~default:agent_name with
  | "claude" -> 
    let tools_str = String.concat "," tools in 
    ["--allowedTools"; tools_str]
  | "gemini" -> 
    ["--allowed-mcp-server-names"; "masc"; "--allowed-tools"] @ tools
  | _ -> []

let build_prompt_args agent_name prompt =
  match Provider_adapter.resolve_cli_canonical_name agent_name |> Option.value ~default:agent_name with
  | "gemini" -> ["-p"; prompt]
  | _ -> []

(** Parse command string into executable and arguments *)
let parse_command cmd =
  let parts = String.split_on_char ' ' cmd in
  List.filter (fun s -> String.length s > 0) parts

let add_default_model_arg agent_name argv =
  match Provider_adapter.resolve_direct_adapter agent_name with
  | Some adapter when adapter.canonical_name = "llama" -> (
      match Provider_adapter.explicit_llama_model_id_result () with
      | Ok model_id -> argv @ [ model_id ]
      | Error _ -> argv)
  | _ -> argv

(** Spawn GLM agent via Llm_client cascade.
    Uses Lodge_cascade config for model selection, Llm_client for cache + metrics. *)
let spawn_glm_via_client ~prompt ~timeout ~start_time : spawn_result =
  let model_specs = Lodge_cascade.get_cascade ~cascade_name:"spawn_glm" () in
  if model_specs = [] then
    let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
    let output = "GLM cascade: no models available (check ZAI_API_KEY and config/llm_cascade.json)" in
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
        agent_name = "glm"; elapsed_ms = elapsed; tool_call_count = 0;
        input_tokens = None; output_tokens = None; cost_usd = None };
    }
  else
    match
      Llm_client.run_prompt_cascade ~temperature:0.7
        ~timeout_sec:timeout ~model_specs ~max_tokens:4096 ~prompt ()
    with
    | Ok resp ->
        let elapsed = resp.Llm_client.latency_ms in
        let inp = Some resp.Llm_client.usage.Llm_client.input_tokens in
        let out = Some resp.Llm_client.usage.Llm_client.output_tokens in
        {
          success = true;
          output = Llm_client.text_of_response resp;
          exit_code = 0;
          elapsed_ms = elapsed;
          tool_call_count = 0;
          tool_names = [];
          input_tokens = inp;
          output_tokens = out;
          cache_creation_tokens =
            (let v = resp.Llm_client.usage.Llm_client.cache_creation_input_tokens in
             if v > 0 then Some v else None);
          cache_read_tokens =
            (let v = resp.Llm_client.usage.Llm_client.cache_read_input_tokens in
             if v > 0 then Some v else None);
          cost_usd = None;
          raw_trace_run = None;
          termination = Some { reason = Task_completed; agent_name = "glm";
            elapsed_ms = elapsed; tool_call_count = 0;
            input_tokens = inp; output_tokens = out; cost_usd = None };
        }
    | Error e ->
        let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
        let output = Printf.sprintf "GLM cascade failed: %s" e in
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
            agent_name = "glm"; elapsed_ms = elapsed; tool_call_count = 0;
            input_tokens = None; output_tokens = None; cost_usd = None };
        }


(** Spawn an agent using Eio.Process (direct execution, no shell)

    Agent Being Protocol: Cultural Inheritance
    - When room_config is provided, loads institution memory and injects it
    - New agents inherit: mission, values, patterns, onboarding steps
    - This enables multi-generational knowledge transfer
*)
let spawn ~sw ~proc_mgr ~agent_name ~prompt ?timeout_seconds ?working_dir
    ?room_config ?runtime_agent_name ?runtime_model ?runtime_role
    ?runtime_session_id ?runtime_selection_note ?worker_run_id ?worker_class ?worker_size
    ?execution_scope ?thinking_enabled ?max_turns ?model_override () : spawn_result =
  let start_time = Time_compat.now () in
  let normalized_agent = String.lowercase_ascii (String.trim agent_name) in
  if Provider_adapter.is_bare_ollama_label normalized_agent then
    let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
    let output = Provider_adapter.bare_ollama_migration_message () in
    {
      success = false;
      output;
      exit_code = 2;
      elapsed_ms = elapsed;
      tool_call_count = 0;
      tool_names = [];
      input_tokens = None;
      output_tokens = None;
      cache_creation_tokens = None;
      cache_read_tokens = None;
      cost_usd = None;
      raw_trace_run = None;
      termination = Some (make_termination ~agent_name ~exit_code:2 ~elapsed_ms:elapsed
        ~tool_call_count:0 ~input_tokens:None ~output_tokens:None ~cost_usd:None
        ~output ~timeout_seconds:(Option.value timeout_seconds ~default:Env_config.Spawn.timeout_seconds));
    }
  else

  let config = match get_config agent_name with
    | Some c -> c
    | None -> {
        agent_name;
        command = agent_name;
        timeout_seconds = Option.value timeout_seconds ~default:Env_config.Spawn.timeout_seconds;
        working_dir;
        mcp_tools = [];
      }
  in

  let timeout = Option.value timeout_seconds ~default:config.timeout_seconds in
  let mcp_args = build_mcp_args agent_name config.mcp_tools in

  (* Agent Being Protocol: Inject institution memory for cultural inheritance
     Note: We use synchronous file loading here since spawn is already in Eio context
     Institution file is small (<10KB) so sync read is acceptable *)
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
  (* State isolation: spawned agents receive only:
     - Their explicit task prompt
     - Institution memory (cultural inheritance)
     - MASC lifecycle suffix
     - State isolation notice
     Parent's working context, full history, todos, and skills are excluded.
     This follows Deep Agents' _EXCLUDED_STATE_KEYS pattern.
     See excluded_state_keys for the full exclusion list. *)
  let augmented_prompt =
    prompt ^ institution_memory ^ masc_lifecycle_suffix ^ role_instructions
    ^ state_isolation_notice
  in

  (* GLM agents use Llm_client cascade (no chdir needed — direct HTTP).
     Non-GLM agents need chdir + fork protected by mutex. *)
  if agent_name = "glm" then
    spawn_glm_via_client ~prompt:augmented_prompt ~timeout ~start_time
  else if normalized_agent = "llama" || normalized_agent = "default" then
    let worker_name =
      match runtime_agent_name with
      | Some name when String.trim name <> "" -> String.trim name
      | _ ->
          let digest =
            Digest.string (Printf.sprintf "%f:%d:%s" start_time (Unix.getpid ()) prompt)
            |> Digest.to_hex
          in
          Printf.sprintf "llama-local-%s" (String.sub digest 0 8)
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
    (match runtime_model with
     | None ->
         let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
         let output = "Spawn error (local worker): explicit runtime_model is required for local workers" in
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
     | Some model when model.Llm_client.provider <> Llm_client.Llama ->
         let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
         let output = "Spawn error (local worker): runtime_model provider must be llama" in
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
     | Some model ->
         match
           Local_agent_eio.run_worker ~sw ~base_path ~worker_name ~model
             ~room_config
             ~team_session_id:runtime_session_id ~role:runtime_role
             ?working_dir:worker_working_dir ?worker_run_id ?worker_class ?worker_size
             ?execution_scope ?thinking_enabled ?max_turns
             ~selection_note:runtime_selection_note
             ~prompt:augmented_prompt
             ~allowed_tools:
               (match execution_scope with
               | Some Team_session_types.Autonomous ->
                   let resolvable =
                     Agent_tool_surfaces.local_worker_resolvable_tool_names ()
                   in
                   Agent_tool_surfaces.build_tool_catalog ~role:"autonomous" ()
                   |> List.filter (fun name -> List.mem name resolvable)
                   |> Agent_tool_surfaces.prefixed_tool_names
               | Some Team_session_types.Limited_code_change ->
                   coding_worker_mcp_tools
               | _ -> llama_mcp_tools)
             ~timeout_sec:timeout ()
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
             let output = Printf.sprintf "Spawn error (local worker): %s" e in
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
             })
  else
    (* Build command arguments outside the chdir critical section *)
    let base_args = parse_command config.command |> add_default_model_arg agent_name in
    let model_args = match model_override with
      | Some m -> ["-m"; m]
      | None -> []
    in
    let prompt_args = build_prompt_args agent_name augmented_prompt in
    let cmd_args = base_args @ model_args @ mcp_args @ prompt_args in
    let full_args = ["timeout"; string_of_int timeout] @ cmd_args in
    let stdin_content = if agent_name = "gemini" then "" else augmented_prompt in

    (* Serialize chdir + fork under mutex. Sys.chdir is process-global;
       without this, concurrent Eio fibers would race on the CWD. *)
    let (process, output_buf) =
      Eio.Mutex.use_rw ~protect:true chdir_mutex (fun () ->
        let original_dir = Sys.getcwd () in
        (match working_dir with Some d -> Sys.chdir d | None -> ());
        Fun.protect ~finally:(fun () -> Sys.chdir original_dir) (fun () ->
          let buf = Buffer.create 4096 in
          let proc =
            Eio.Process.spawn ~sw proc_mgr
              ~stdin:(Eio.Flow.string_source stdin_content)
              ~stdout:(Eio.Flow.buffer_sink buf)
              full_args
          in
          (proc, buf)))
    in

    let result =
      try
        let status = Eio.Process.await process in
        let raw_output = Buffer.contents output_buf in
        let exit_code =
          match status with
          | `Exited code -> code
          | `Signaled _ -> -1
        in

        let output, input_tokens, output_tokens, cache_creation, cache_read, cost_usd =
          match agent_name with
          | "claude" ->
              let result_opt, inp, out, cache_c, cache_r, cost =
                parse_claude_json raw_output
              in
              (Option.value result_opt ~default:raw_output, inp, out, cache_c, cache_r, cost)
          | "gemini" ->
              let inp, out, cached, cost = parse_gemini_output raw_output in
              let result_text = Option.value (extract_gemini_response_text raw_output) ~default:raw_output in
              (result_text, inp, out, cached, None, cost)
          | "codex" ->
              let inp, out, cached, cost = parse_codex_output raw_output in
              (raw_output, inp, out, cached, None, cost)
          | _ -> (raw_output, None, None, None, None, None)
        in

        let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
        {
          success = (exit_code = 0);
          output;
          exit_code;
          elapsed_ms = elapsed;
          tool_call_count = 0;
          tool_names = [];
          input_tokens;
          output_tokens;
          cache_creation_tokens = cache_creation;
          cache_read_tokens = cache_read;
          cost_usd;
          raw_trace_run = None;
          termination = Some (make_termination ~agent_name ~exit_code ~elapsed_ms:elapsed
            ~tool_call_count:0 ~input_tokens ~output_tokens ~cost_usd ~output
            ~timeout_seconds:timeout);
        }
      with e ->
        let elapsed = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
        let output = Printf.sprintf "Spawn error (Eio): %s" (Printexc.to_string e) in
        {
          success = false;
          output;
          exit_code = -99;
          elapsed_ms = elapsed;
          tool_call_count = 0;
          tool_names = [];
          input_tokens = None;
          output_tokens = None;
          cache_creation_tokens = None;
          cache_read_tokens = None;
          cost_usd = None;
          raw_trace_run = None;
          termination = Some { reason = Unknown_failure { exit_code = -99; message = output };
            agent_name; elapsed_ms = elapsed; tool_call_count = 0;
            input_tokens = None; output_tokens = None; cost_usd = None };
        }
    in
    result

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
