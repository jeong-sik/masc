(** MASC Spawn - Eio Native Agent subprocess management *)

(** Spawn configuration for an agent *)
type spawn_config = {
  agent_name: string;
  command: string;
  timeout_seconds: int;
  working_dir: string option;
  mcp_tools: string list;
}

(** Spawn result with token tracking *)
type spawn_result = {
  success: bool;
  output: string;
  exit_code: int;
  elapsed_ms: int;
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
  "mcp__masc__masc_handover_create";
  "mcp__masc__masc_handover_list";
  "mcp__masc__masc_handover_claim";
  "mcp__masc__masc_handover_get";
  "mcp__masc__masc_memento_mori";
  "mcp__masc__masc_relay_status";
  "mcp__masc__masc_relay_checkpoint";
  "mcp__masc__masc_board_list";
  "mcp__masc__masc_board_post";
  "mcp__masc__masc_board_comment";
  "mcp__masc__masc_board_vote";
  "mcp__masc__masc_board_get";
  "mcp__masc__masc_a2a_subscribe";
  "mcp__masc__masc_poll_events";
  "mcp__masc__masc_spawn";
  "mcp__masc__masc_heartbeat_list";
]

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

IMPORTANT: If context_ratio exceeds 0.8, you MUST handoff. Do not ignore this. 
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

(** Parse Gemini output for token tracking
    Format: {"usageMetadata": {"promptTokenCount": N, "candidatesTokenCount": M, "cachedContentTokenCount": C}} *)
let parse_gemini_output output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let usage = json |> member "usageMetadata" in
    let input_tokens = usage |> member "promptTokenCount" |> to_int_option in
    let output_tokens = usage |> member "candidatesTokenCount" |> to_int_option in
    let cached_tokens = usage |> member "cachedContentTokenCount" |> to_int_option in
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

(** Parse GLM (Z.ai) output for token tracking - OpenAI-compatible format
    Format: {"choices": [...], "usage": {"prompt_tokens": N, "completion_tokens": M}} *)
let parse_glm_output output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let usage = json |> member "usage" in
    let input_tokens = usage |> member "prompt_tokens" |> to_int_option in
    let output_tokens = usage |> member "completion_tokens" |> to_int_option in
    (* GLM-4.7: Z.ai Coding Plan pricing is subscription-based, estimate $0 per token *)
    let cost = Some 0.0 in
    (input_tokens, output_tokens, cost)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None)

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
    command = "gemini --yolo";
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
  ("ollama", {
    agent_name = "ollama";
    command = Printf.sprintf "ollama run %s" Env_config.Ollama.default_model;
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = [];
  });
  (* GLM uses Z.ai API directly - no llm-mcp dependency *)
  ("glm", {
    agent_name = "glm";
    (* Direct Z.ai API call - requires ZAI_API_KEY env var *)
    command = "curl -s -X POST https://api.z.ai/api/coding/paas/v4/chat/completions -H 'Content-Type: application/json' -H \"Authorization: Bearer $ZAI_API_KEY\" -d";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = [];  (* GLM has no MCP support *)
  });
]

let get_config agent_name = 
  List.assoc_opt agent_name default_configs

(** Build MCP flags as argument list (no shell escaping needed) *)
let build_mcp_args agent_name tools = 
  if tools = [] then []
  else match agent_name with 
  | "claude" -> 
    let tools_str = String.concat "," tools in 
    ["--allowedTools"; tools_str]
  | "gemini" -> 
    ["--allowed-mcp-server-names"; "masc"; "--allowed-tools"] @ tools
  | _ -> []

(** Parse command string into executable and arguments *)
let parse_command cmd =
  let parts = String.split_on_char ' ' cmd in
  List.filter (fun s -> String.length s > 0) parts

(** Spawn an agent using Eio.Process (direct execution, no shell)

    Agent Being Protocol: Cultural Inheritance
    - When room_config is provided, loads institution memory and injects it
    - New agents inherit: mission, values, patterns, onboarding steps
    - This enables multi-generational knowledge transfer
*)
let spawn ~sw ~proc_mgr ~agent_name ~prompt ?timeout_seconds ?working_dir ?room_config () =
  let start_time = Time_compat.now () in

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
          let ic = open_in inst_file in
          let content = Common.protect ~module_name:"spawn_eio" ~finally_label:"finalizer" ~finally:(fun () -> close_in_noerr ic)
            (fun () -> really_input_string ic (in_channel_length ic)) in
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

  let augmented_prompt = prompt ^ institution_memory ^ masc_lifecycle_suffix in

  let original_dir = Sys.getcwd () in
  (match working_dir with Some d -> Sys.chdir d | None -> ());

  let result =
    try
      let output_buf = Buffer.create 4096 in
      
      (* Build command arguments - direct execution without shell *)
      let (cmd_args, stdin_data) =
        if agent_name = "glm" then
          (* GLM: Direct Z.ai API call - no llm-mcp dependency *)
          let api_key = Sys.getenv_opt "ZAI_API_KEY" |> Option.value ~default:"" in
          let model = "glm-4.7" in
          let json_body = Yojson.Safe.to_string (`Assoc [
            ("model", `String model);
            ("messages", `List [
              `Assoc [("role", `String "user"); ("content", `String augmented_prompt)]
            ]);
            ("stream", `Bool false)
          ]) in
          (["curl"; "-s"; "-X"; "POST"; "https://api.z.ai/api/coding/paas/v4/chat/completions";
            "-H"; "Content-Type: application/json";
            "-H"; Printf.sprintf "Authorization: Bearer %s" api_key;
            "-d"; json_body], None)
        else
          (* Other agents: parse command and pass prompt via stdin *)
          let base_args = parse_command config.command in
          (base_args @ mcp_args, Some augmented_prompt)
      in
      
      (* Wrap with timeout command for process-level timeout (no shell injection) *)
      let full_args = ["timeout"; string_of_int timeout] @ cmd_args in
      
      (* Spawn process with optional stdin - direct execution, no shell *)
      let process = match stdin_data with
        | Some data ->
            Eio.Process.spawn ~sw proc_mgr
              ~stdin:(Eio.Flow.string_source data)
              ~stdout:(Eio.Flow.buffer_sink output_buf)
              full_args
        | None ->
            Eio.Process.spawn ~sw proc_mgr
              ~stdout:(Eio.Flow.buffer_sink output_buf)
              full_args
      in
      
      let status = Eio.Process.await process in
      let raw_output = Buffer.contents output_buf in
      let exit_code = match status with 
        | `Exited code -> code
        | `Signaled _ -> -1
      in 

      let (output, input_tokens, output_tokens, cache_creation, cache_read, cost_usd) =
        match agent_name with
        | "claude" ->
            let (result_opt, inp, out, cache_c, cache_r, cost) = parse_claude_json raw_output in
            (Option.value result_opt ~default:raw_output, inp, out, cache_c, cache_r, cost)
        | "gemini" ->
            let (inp, out, cached, cost) = parse_gemini_output raw_output in
            (raw_output, inp, out, cached, None, cost)
        | "ollama" ->
            let (inp, out, cost) = parse_ollama_output raw_output in
            (raw_output, inp, out, None, None, cost)
        | "codex" ->
            let (inp, out, cached, cost) = parse_codex_output raw_output in
            (raw_output, inp, out, cached, None, cost)
        | "glm" ->
            (* GLM response comes wrapped in MCP JSON-RPC, extract the text content *)
            let (response_text, inp, out, cost) =
              try
                let json = Yojson.Safe.from_string raw_output in
                let open Yojson.Safe.Util in
                let result = json |> member "result" in
                let content = result |> member "content" in
                let text = match content with
                  | `List items ->
                      let texts = List.filter_map (fun item ->
                        match item |> member "type" |> to_string_option with
                        | Some "text" -> item |> member "text" |> to_string_option
                        | _ -> None
                      ) items in
                      String.concat "\n" texts
                  | _ -> raw_output
                in
                let (inp, out, cost) = parse_glm_output raw_output in
                (text, inp, out, cost)
              with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
                (raw_output, None, None, None)
            in
            (response_text, inp, out, None, None, cost)
        | _ ->
            (raw_output, None, None, None, None, None)
      in 

      {
        success = (exit_code = 0);
        output;
        exit_code;
        elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
        input_tokens;
        output_tokens;
        cache_creation_tokens = cache_creation;
        cache_read_tokens = cache_read;
        cost_usd;
      }
    with e -> 
      {
        success = false;
        output = Printf.sprintf "Spawn error (Eio): %s" (Printexc.to_string e);
        exit_code = -99;
        elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
        input_tokens = None;
        output_tokens = None;
        cache_creation_tokens = None;
        cache_read_tokens = None;
        cost_usd = None;
      }
  in 
  Sys.chdir original_dir;
  result

let result_to_human_string result = 
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
  if result.success then 
    Printf.sprintf "✅ Agent completed in %dms%s\n\n%s"
      result.elapsed_ms token_info result.output
  else 
    Printf.sprintf "❌ Agent failed (exit %d) in %dms%s\n\n%s"
      result.exit_code result.elapsed_ms token_info result.output
