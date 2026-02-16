(** MASC Spawn - Agent subprocess management *)

(** Spawn configuration for an agent *)
type spawn_config = {
  agent_name: string;
  command: string;       (* e.g., "claude -p", "gemini", "codex" *)
  timeout_seconds: int;
  working_dir: string option;
  mcp_tools: string list;  (* MCP tools to allow, e.g., ["mcp__masc__masc_status"] *)
}

(** Spawn result with token tracking *)
type spawn_result = {
  success: bool;
  output: string;
  exit_code: int;
  elapsed_ms: int;
  (* Token tracking (Phase 10) *)
  input_tokens: int option;
  output_tokens: int option;
  cache_creation_tokens: int option;
  cache_read_tokens: int option;
  cost_usd: float option;
}

(** MASC MCP tools available for spawned agents *)
let masc_mcp_tools = [
  "mcp__masc__masc_status";
  "mcp__masc__masc_tasks";
  "mcp__masc__masc_claim";
  "mcp__masc__masc_claim_next";
  "mcp__masc__masc_transition";
  "mcp__masc__masc_release";
  "mcp__masc__masc_task_history";
  "mcp__masc__masc_done";
  "mcp__masc__masc_broadcast";
  "mcp__masc__masc_join";
  "mcp__masc__masc_leave";
  "mcp__masc__masc_who";
  "mcp__masc__masc_agent_update";
  "mcp__masc__masc_add_task";
  "mcp__masc__masc_heartbeat";
  "mcp__masc__masc_messages";
  "mcp__masc__masc_worktree_create";
  "mcp__masc__masc_worktree_remove";
  "mcp__masc__masc_worktree_list";
  (* Cellular Agent Handover tools *)
  "mcp__masc__masc_handover_create";
  "mcp__masc__masc_handover_list";
  "mcp__masc__masc_handover_claim";
  "mcp__masc__masc_handover_get";
  (* Infinite Session Lifecycle tools *)
  "mcp__masc__masc_memento_mori";
  "mcp__masc__masc_relay_status";
  "mcp__masc__masc_relay_checkpoint";
  (* TRPG tools *)
  "mcp__masc__masc_trpg_dice_roll";
  "mcp__masc__masc_trpg_turn_advance";
  "mcp__masc__masc_trpg_stream";
  "mcp__masc__masc_trpg_round_run";
]

(** MASC Lifecycle Protocol - auto-appended to spawned agent prompts *)
let masc_lifecycle_suffix = {|

---
[MASC LIFECYCLE PROTOCOL - Auto-injected]

You are running as a MASC-managed agent. Follow these rules strictly:

1. **Session Start**: Call `mcp__masc__masc_join` with your agent name
2. **Heartbeat**: Call `mcp__masc__masc_heartbeat` every 2 minutes during long tasks
3. **Context Monitoring**: Periodically call `mcp__masc__masc_memento_mori` with estimated context_ratio:
   - 0.0-0.5: Continue normally
   - 0.5-0.8: Prepare DNA (context summary) - will auto-prepare
   - 0.8+: Auto-handoff to successor agent
4. **Task Completion**: Call `mcp__masc__masc_transition` with action="done" then `mcp__masc__masc_leave`

Example lifecycle:
```
mcp__masc__masc_join(agent_name="gemini", capabilities=["typescript","react"])
... work ...
mcp__masc__masc_heartbeat(agent_name="gemini")  // every 2 min
... more work ...
mcp__masc__masc_memento_mori(context_ratio=0.6, full_context="summary of work so far")
... continue or handoff ...
mcp__masc__masc_transition(agent_name="gemini", task_id="task-XXX", action="done")
mcp__masc__masc_leave(agent_name="gemini")
```

IMPORTANT: If context_ratio exceeds 0.8, you MUST handoff. Do not ignore this.
---
|}

(** Parse Claude JSON output to extract token usage *)
let parse_claude_json output =
  try
    let json = Yojson.Safe.from_string output in
    let module U = Yojson.Safe.Util in
    let usage = json |> U.member "usage" in
    let input_tokens = usage |> U.member "input_tokens" |> U.to_int_option in
    let output_tokens = usage |> U.member "output_tokens" |> U.to_int_option in
    let cache_creation = usage |> U.member "cache_creation_input_tokens" |> U.to_int_option in
    let cache_read = usage |> U.member "cache_read_input_tokens" |> U.to_int_option in
    let cost_usd = json |> U.member "total_cost_usd" |> U.to_float_option in
    let result_text = json |> U.member "result" |> U.to_string_option in
    (result_text, input_tokens, output_tokens, cache_creation, cache_read, cost_usd)
  with Yojson.Json_error _ | U.Type_error _ ->
    (* If JSON parsing fails, return raw output with no token info *)
    (Some output, None, None, None, None, None)

(** Default spawn configs for known agents *)
let default_configs = [
  ("claude", {
    agent_name = "claude";
    command = "claude --output-format json -p";  (* -p must be last before prompt *)
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;  (* Claude: --allowedTools flag *)
  });
  ("gemini", {
    agent_name = "gemini";
    command = "gemini --yolo";  (* Auto-approve tools for non-interactive *)
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;  (* Gemini: --allowed-mcp-server-names flag *)
  });
  ("codex", {
    agent_name = "codex";
    command = "codex exec";  (* Non-interactive mode *)
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;  (* Codex: uses config.toml MCP servers *)
  });
  ("ollama", {
    agent_name = "ollama";
    command = Printf.sprintf "ollama run %s" Env_config.Ollama.default_model;  (* Direct ollama CLI *)
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = [];  (* Ollama has no MCP support *)
  });
]

(** Get spawn config for agent *)
let get_config agent_name =
  List.assoc_opt agent_name default_configs

(** Build MCP flags as argument list (no shell escaping needed) *)
let build_mcp_args agent_name tools =
  if tools = [] then []
  else match agent_name with
  | "claude" ->
    (* Claude: --allowedTools "tool1,tool2,..." *)
    let tools_str = String.concat "," tools in
    ["--allowedTools"; tools_str]
  | "gemini" ->
    (* Gemini: --allowed-mcp-server-names masc --allowed-tools tool1 tool2 *)
    ["--allowed-mcp-server-names"; "masc"; "--allowed-tools"] @ tools
  | "codex" ->
    (* Codex: Uses config.toml MCP servers automatically, no extra flags needed *)
    []
  | "ollama" ->
    (* Ollama: Direct CLI, no MCP support *)
    []
  | _ -> []

(** Parse command string into executable and arguments *)
let parse_command cmd =
  let parts = String.split_on_char ' ' cmd in
  List.filter (fun s -> String.length s > 0) parts

(** Spawn an agent with a prompt/task (direct execution, no shell) *)
let spawn ~agent_name ~prompt ?timeout_seconds ?working_dir () =
  let start_time = Time_compat.now () in

  (* Get config or use defaults *)
  let config = match get_config agent_name with
    | Some c -> c
    | None -> {
        agent_name;
        command = agent_name;  (* fallback: use agent_name as command *)
        timeout_seconds = Option.value timeout_seconds ~default:Env_config.Spawn.timeout_seconds;
        working_dir;
        mcp_tools = [];
      }
  in

  let timeout = Option.value timeout_seconds ~default:config.timeout_seconds in
  let mcp_args = build_mcp_args agent_name config.mcp_tools in
  (* Auto-append MASC lifecycle protocol to prompt *)
  let augmented_prompt = prompt ^ masc_lifecycle_suffix in

  (* Build command args - direct execution without shell *)
  let base_args = parse_command config.command in
  let cmd_args = ["timeout"; string_of_int timeout] @ base_args @ mcp_args in
  let cmd_array = Array.of_list cmd_args in

  (* Change to working dir if specified *)
  let original_dir = Sys.getcwd () in
  let () = match working_dir with
    | Some dir -> Sys.chdir dir
    | None -> match config.working_dir with
      | Some dir -> Sys.chdir dir
      | None -> ()
  in

  try
    (* Create pipes for stdin and stdout *)
    let (stdout_read, stdout_write) = Unix.pipe () in
    let (stdin_read, stdin_write) = Unix.pipe () in
    
    (* Spawn process directly without shell *)
    let pid = Unix.create_process 
      (List.hd cmd_args) cmd_array
      stdin_read stdout_write Unix.stderr in
    
    (* Close unused ends *)
    Unix.close stdout_write;
    Unix.close stdin_read;
    
    (* Write prompt to stdin and close *)
    let _ = Unix.write_substring stdin_write augmented_prompt 0 (String.length augmented_prompt) in
    Unix.close stdin_write;
    
    (* Read output *)
    let ic = Unix.in_channel_of_descr stdout_read in
    let raw_output = In_channel.input_all ic in
    In_channel.close ic;
    
    (* Wait for process *)
    let (_, status) = Unix.waitpid [] pid in

    (* Restore directory *)
    Sys.chdir original_dir;

    let elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
    let exit_code = match status with
      | Unix.WEXITED code -> code
      | Unix.WSIGNALED _ -> -1
      | Unix.WSTOPPED _ -> -2
    in

    (* Extract token usage for Claude (JSON output) *)
    let (output, input_tokens, output_tokens, cache_creation, cache_read, cost_usd) =
      if agent_name = "claude" then
        let (result_opt, inp, out, cache_c, cache_r, cost) = parse_claude_json raw_output in
        (Option.value result_opt ~default:raw_output, inp, out, cache_c, cache_r, cost)
      else
        (raw_output, None, None, None, None, None)
    in

    {
      success = (exit_code = 0);
      output;
      exit_code;
      elapsed_ms;
      input_tokens;
      output_tokens;
      cache_creation_tokens = cache_creation;
      cache_read_tokens = cache_read;
      cost_usd;
    }
  with e ->
    Sys.chdir original_dir;
    {
      success = false;
      output = Printf.sprintf "Spawn error: %s" (Printexc.to_string e);
      exit_code = -99;
      elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
      input_tokens = None;
      output_tokens = None;
      cache_creation_tokens = None;
      cache_read_tokens = None;
      cost_usd = None;
    }

(** Spawn and wait for result (synchronous) *)
let spawn_sync = spawn

(** Helper for optional int to JSON *)
let int_opt_to_json = function
  | Some n -> `Int n
  | None -> `Null

(** Helper for optional float to JSON *)
let float_opt_to_json = function
  | Some f -> `Float f
  | None -> `Null

(** Result to JSON *)
let result_to_json result =
  `Assoc [
    ("success", `Bool result.success);
    ("output", `String result.output);
    ("exit_code", `Int result.exit_code);
    ("elapsed_ms", `Int result.elapsed_ms);
    ("input_tokens", int_opt_to_json result.input_tokens);
    ("output_tokens", int_opt_to_json result.output_tokens);
    ("cache_creation_tokens", int_opt_to_json result.cache_creation_tokens);
    ("cache_read_tokens", int_opt_to_json result.cache_read_tokens);
    ("cost_usd", float_opt_to_json result.cost_usd);
  ]

(** Format token info for display *)
let format_token_info result =
  match result.input_tokens, result.output_tokens, result.cost_usd with
  | Some inp, Some out, Some cost ->
    let cache_info = match result.cache_creation_tokens, result.cache_read_tokens with
      | Some cc, Some cr when cc > 0 || cr > 0 ->
        Printf.sprintf " (cache: +%d created, %d read)" cc cr
      | _ -> ""
    in
    Printf.sprintf "\n📊 Tokens: %d in / %d out%s | Cost: $%.4f" inp out cache_info cost
  | _ -> ""

(** Result to human-readable string *)
let result_to_string result =
  let token_info = format_token_info result in
  if result.success then
    Printf.sprintf "✅ Agent completed in %dms%s\n\n%s"
      result.elapsed_ms token_info result.output
  else
    Printf.sprintf "❌ Agent failed (exit %d) in %dms%s\n\n%s"
      result.exit_code result.elapsed_ms token_info result.output
