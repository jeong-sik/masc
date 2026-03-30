open Printf

module U = Yojson.Safe.Util

open Result_syntax

type runtime = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  mcp_state : Mcp_server.server_state;
  mcp_session_id : string option;
  auth_token : string option;
}

type chain_run_response = {
  output : string;
  chain_id : string option;
  run_id : string option;
  duration_ms : int option;
  trace_count : int option;
}

type chain_orchestrate_response = {
  summary : string;
  success : bool option;
  total_replans : int option;
  chain_id : string option;
  run_id : string option;
}

type tool_executor =
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?mcp_session_id:string ->
  ?auth_token:string ->
  Mcp_server.server_state ->
  name:string ->
  arguments:Yojson.Safe.t ->
  bool * string

let tool_executor_ref : tool_executor option ref = ref None

let set_tool_executor executor =
  tool_executor_ref := Some executor

let bootstrap_mutex = Eio.Mutex.create ()
let bootstrapped_roots : (string, unit) Hashtbl.t = Hashtbl.create 4

let with_mutex mutex f =
  Eio.Mutex.use_rw ~protect:true mutex f

let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let option_first_some a b =
  match a with
  | Some _ -> a
  | None -> b

let trim = String.trim

let option_trim = function
  | Some raw ->
      let value = trim raw in
      if String.equal value "" then None else Some value
  | None -> None

let putenv_default key value =
  match option_trim (Sys.getenv_opt key) with
  | Some _ -> ()
  | None -> Unix.putenv key value

let ensure_dir path =
  Fs_compat.mkdir_p path

let read_lines_tail ~max_bytes:_ ~max_lines path =
  if not (Fs_compat.file_exists path) then []
  else
    let content = Fs_compat.load_file path in
    let lines =
      String.split_on_char '\n' content
      |> List.filter (fun s -> String.trim s <> "")
    in
    let rec take n xs =
      if n <= 0 then []
      else
        match xs with
        | [] -> []
        | hd :: tl -> hd :: take (n - 1) tl
    in
    lines |> take max_lines

let load_prompt_dir dir =
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir
    |> Array.iter (fun file ->
           if Filename.check_suffix file ".json" then (
             let path = Filename.concat dir file in
             try
               let content = Fs_compat.load_file path in
               let json = Yojson.Safe.from_string content in
               match Prompt_registry.prompt_entry_of_yojson json with
               | Ok entry -> Prompt_registry.register entry
               | Error msg ->
                   Log.Chain.warn "prompt parse failed for %s: %s"
                     path msg
             with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
               Log.Chain.error "prompt load failed for %s: %s"
                 path (Printexc.to_string exn)))

let chain_source_roots (config : Room.config) =
  let add acc value =
    let value = trim value in
    if value = "" || List.mem value acc then acc else acc @ [ value ]
  in
  let roots = add [] config.base_path in
  let roots =
    match Env_config_core.base_path_opt () with
    | Some path -> add roots path
    | None -> roots
  in
  match Env_config.Chain.source_base_path_opt () with
  | Some path -> add roots path
  | None -> roots

let configure_storage_paths (config : Room.config) =
  let masc_dir = Room.masc_dir config in
  let control_plane_dir = Filename.concat masc_dir "control-plane" in
  let logs_dir = Filename.concat masc_dir "logs" in
  let checkpoints_dir = Filename.concat control_plane_dir "checkpoints" in
  ensure_dir control_plane_dir;
  ensure_dir logs_dir;
  ensure_dir checkpoints_dir;
  putenv_default "MASC_CHAIN_HISTORY_FILE"
    (Filename.concat control_plane_dir "chain_history.jsonl");
  putenv_default "MASC_CHAIN_CHECKPOINT_DIR" checkpoints_dir;
  putenv_default "MASC_CHAIN_RUN_LOG_PATH"
    (Filename.concat logs_dir "chain_runs.jsonl");
  putenv_default "MASC_CHAIN_RUN_STORE_PATH"
    (Filename.concat control_plane_dir "chain_run_store.jsonl")

let ensure_bootstrap (config : Room.config) =
  with_mutex bootstrap_mutex (fun () ->
      if not (Hashtbl.mem bootstrapped_roots config.base_path) then (
        configure_storage_paths config;
        Chain_registry.init ();
        chain_source_roots config
        |> List.iter (fun root ->
               ignore
                 (Chain_registry.load_from_dir
                    (Filename.concat root "data/chains")));
        Prompt_registry.init ();
        chain_source_roots config
        |> List.iter (fun root ->
               load_prompt_dir (Filename.concat root "data/prompts"));
        Hashtbl.replace bootstrapped_roots config.base_path ()))

let model_tool_defs_of_json = function
  | None -> []
  | Some (`List items) ->
      items
      |> List.filter_map (fun item ->
             let name =
               match U.member "name" item with
               | `String value -> Some value
               | _ -> None
             in
             match name with
             | None -> None
             | Some tool_name ->
                 let parameters =
                   match U.member "input_schema" item with
                   | (`Assoc _ | `List _ | `String _ | `Int _ | `Float _ | `Bool _ | `Null)
                     as schema ->
                       schema
                   | _ -> (
                       match U.member "parameters" item with
                       | (`Assoc _ | `List _ | `String _ | `Int _ | `Float _ | `Bool _ | `Null)
                         as schema ->
                           schema
                       | _ ->
                           `Assoc
                             [
                               ("type", `String "object");
                               ("properties", `Assoc []);
                             ])
                 in
                 let description =
                   match U.member "description" item with
                   | `String value -> value
                   | _ -> ""
                 in
                 Some
                   {
                     Types.name = tool_name;
                     description;
                     input_schema = parameters;
                   })
  | Some _ -> []

type model_runner =
  | Stub
  | Direct of string  (** model label, e.g. "llama:qwen3.5" *)

let model_runner_of_string raw =
  let model = trim raw in
  let lower = String.lowercase_ascii model in
  let direct label =
    (* Validate the label parses, but carry the string *)
    match Llm_provider.Cascade_config.parse_model_string label with
    | Some _ -> Ok (Direct label)
    | None -> Error (Printf.sprintf "Cannot parse model: %s" label)
  in
  match lower with
  | "" | "gemini" -> direct "gemini:pro"
  | "pro" -> direct "gemini:pro"
  | "flash" | "flash-lite" -> direct "gemini:flash"
  | "claude" | "claude-cli" | "opus" -> direct "claude:opus"
  | "sonnet" -> direct "claude:sonnet"
  | "haiku" -> direct "claude:haiku"
  | "ollama" -> Error (Provider_adapter.bare_ollama_migration_message ())
  | "llama" -> (
      match Provider_adapter.explicit_llama_model_label_result () with
      | Ok label -> direct label
      | Error msg -> Error msg)
  | "glm" ->
      direct "glm:auto"
  | "stub" | "mock" -> Ok Stub
  | "codex" ->
      direct
        (Printf.sprintf "codex-api:%s" Env_config.OpenAI.default_model)
  | value when starts_with ~prefix:"codex:" value ->
      let requested =
        String.sub model 6 (String.length model - 6) |> trim
      in
      let effective =
        if requested = "" then Env_config.OpenAI.default_model else requested
      in
      direct (Printf.sprintf "codex-api:%s" effective)
  | value -> (
      match Llm_provider.Cascade_config.parse_model_string model with
      | Some _ -> Ok (Direct model)
      | None when starts_with ~prefix:"llama:" value -> direct model
      | None when starts_with ~prefix:"gemini:" value -> direct model
      | None when starts_with ~prefix:"claude:" value -> direct model
      | None when starts_with ~prefix:"glm:" value -> direct model
      (* Bare provider model names → route to provider *)
      | None when starts_with ~prefix:"glm-" value ->
          direct (Printf.sprintf "glm:%s" value)
      | None when starts_with ~prefix:"gemini-" value ->
          direct (Printf.sprintf "gemini:%s" value)
      | None when starts_with ~prefix:"claude-" value ->
          direct (Printf.sprintf "claude:%s" value)
      | None when starts_with ~prefix:"codex-" value ->
          direct (Printf.sprintf "codex-api:%s" value)
      | None when starts_with ~prefix:"gpt-" value ->
          direct (Printf.sprintf "codex-api:%s" value)
      | None when String.equal value "gpt" ->
          direct (Printf.sprintf "codex-api:%s" Env_config.OpenAI.default_model)
      | None when starts_with ~prefix:"o1" value || starts_with ~prefix:"o3" value ->
          direct (Printf.sprintf "codex-api:%s" value)
      | None -> Error (Printf.sprintf "Cannot parse model: %s" model))

let call_model_text (runtime : runtime) ~model ?system ?tools ?thinking:_ ~prompt
    ~timeout_sec () =
  match model_runner_of_string model with
  | Error msg -> Error msg
  | Ok Stub -> Ok (sprintf "[stub]%s" prompt)
  | Ok (Direct model_label) ->
      let system_prompt =
        match system with
        | Some sys when trim sys <> "" -> sys
        | _ -> ""
      in
      let tool_defs = model_tool_defs_of_json tools in
      (* Inference parameters (temperature, max_tokens) are delegated to OAS
         pipeline defaults. No hardcoded values here -- OAS controls inference
         params via cascade config or provider defaults. #2408 *)
      let result =
        if tool_defs = [] then
          Oas_worker.run_model_by_label ~model_label ~goal:prompt ~system_prompt
            ~max_turns:1 ~priority:Llm_provider.Request_priority.Interactive ~sw:runtime.sw ?net:runtime.mcp_state.Mcp_server.net ()
        else
          (Oas_worker.run_model_with_masc_tools ~model_label ~goal:prompt
              ~system_prompt ~masc_tools:tool_defs
              ~dispatch:(fun ~name ~args ->
                match !tool_executor_ref with
                | None -> (false, "native MASC tool executor unavailable")
                | Some execute_tool ->
                    let final_args =
                      if starts_with ~prefix:"masc_" name then
                        match args with
                        | `Assoc fields when List.mem_assoc "agent_name" fields -> args
                        | `Assoc fields ->
                            `Assoc
                              (("agent_name", `String runtime.agent_name) :: fields)
                        | _ -> `Assoc [ ("agent_name", `String runtime.agent_name) ]
                      else
                        args
                    in
                    execute_tool ~sw:runtime.sw ~clock:runtime.clock
                      ?mcp_session_id:runtime.mcp_session_id
                      ?auth_token:runtime.auth_token runtime.mcp_state ~name
                      ~arguments:final_args)
              ~max_turns:1 ~priority:Llm_provider.Request_priority.Interactive ~sw:runtime.sw
              ?net:runtime.mcp_state.Mcp_server.net ())
      in
      (match result with
      | Ok run_result ->
          let text =
            Oas_response.text_of_response run_result.Oas_worker.response
            |> trim
          in
          if text <> "" then Ok text else Error "empty completion"
      | Error msg ->
          Error
            (Printf.sprintf "OAS model run failed (%s, timeout=%ds): %s"
               model_label timeout_sec msg))

let assoc_get_string_opt (json : Yojson.Safe.t) key =
  match U.member key json with
  | `String value ->
      let trimmed = trim value in
      if String.equal trimmed "" then None else Some trimmed
  | _ -> None

let assoc_get_bool_default (json : Yojson.Safe.t) key default =
  match U.member key json with
  | `Bool value -> value
  | _ -> default

let tool_args_with_agent (runtime : runtime) tool_name (args : Yojson.Safe.t) =
  if starts_with ~prefix:"masc_" tool_name then
    match args with
    | `Assoc fields when List.mem_assoc "agent_name" fields -> args
    | `Assoc fields -> `Assoc (("agent_name", `String runtime.agent_name) :: fields)
    | _ -> `Assoc [ ("agent_name", `String runtime.agent_name) ]
  else
    args

let normalize_tool_name name =
  let raw = trim name in
  if raw = "" then raw
  else
    match String.index_opt raw '.' with
    | None -> raw
    | Some idx ->
        let prefix = String.sub raw 0 idx in
        let suffix = String.sub raw (idx + 1) (String.length raw - idx - 1) in
        if suffix = "" then raw
        else if starts_with ~prefix:(prefix ^ "_") suffix then suffix
        else if String.equal prefix "masc" then "masc_" ^ suffix
        else suffix

let tool_string_result (ok, payload) =
  if ok then Ok payload
  else
    try
      match Yojson.Safe.from_string payload with
      | `Assoc fields -> (
          match List.assoc_opt "message" fields with
          | Some (`String message) -> Error message
          | _ -> Error payload)
      | _ -> Error payload
    with Yojson.Json_error _ -> Error payload

let exec_masc_tool (runtime : runtime) ~name ~args =
  let normalized_name = normalize_tool_name name in
  let final_args = tool_args_with_agent runtime normalized_name args in
  match !tool_executor_ref with
  | None -> Error "native MASC tool executor unavailable"
  | Some execute_tool ->
      execute_tool ~sw:runtime.sw ~clock:runtime.clock
        ?mcp_session_id:runtime.mcp_session_id ?auth_token:runtime.auth_token
        runtime.mcp_state ~name:normalized_name ~arguments:final_args
      |> tool_string_result

let call_named_tool_model (runtime : runtime) ~tool_name ~(args : Yojson.Safe.t) =
  let prompt =
    assoc_get_string_opt args "prompt"
    |> option_first_some (assoc_get_string_opt args "message")
    |> Option.value ~default:(Yojson.Safe.to_string args)
  in
  let system =
    assoc_get_string_opt args "system_prompt"
    |> option_first_some (assoc_get_string_opt args "system")
  in
  let timeout_sec =
    match U.member "timeout" args with
    | `Int value -> max 1 value
    | _ -> 120
  in
  let model_result =
    match tool_name with
    | "gemini" ->
        Ok (assoc_get_string_opt args "model" |> Option.value ~default:"gemini:pro")
    | "claude" | "claude-cli" ->
        Ok (assoc_get_string_opt args "model" |> Option.value ~default:"claude:opus")
    | "codex" ->
        Ok (assoc_get_string_opt args "model" |> Option.value ~default:"codex")
    | "llama" ->
        (match assoc_get_string_opt args "model" with
        | Some value when starts_with ~prefix:"llama:" (String.lowercase_ascii value) ->
            Ok value
        | Some value -> Ok ("llama:" ^ value)
        | None -> Provider_adapter.explicit_llama_model_label_result ())
    | "glm" ->
        Ok (match assoc_get_string_opt args "model" with
        | Some value when starts_with ~prefix:"glm:" (String.lowercase_ascii value) -> value
        | Some value -> "glm:" ^ value
        | None -> "glm:auto")
    | _ -> Ok tool_name
  in
  match model_result with
  | Ok model -> call_model_text runtime ~model ?system ~prompt ~timeout_sec ()
  | Error msg -> Error msg

let exec_tool (runtime : runtime) ~name ~(args : Yojson.Safe.t) =
  match String.lowercase_ascii (trim name) with
  | "echo" ->
      let input =
        assoc_get_string_opt args "input" |> Option.value ~default:(Yojson.Safe.to_string args)
      in
      Ok input
  | "identity" -> Ok (Yojson.Safe.to_string args)
  | "gemini" | "claude" | "claude-cli" | "codex" | "llama" | "glm" as model_tool ->
      call_named_tool_model runtime ~tool_name:model_tool ~args
  | raw when starts_with ~prefix:"masc." raw || starts_with ~prefix:"masc_" raw ->
      exec_masc_tool runtime ~name:raw ~args
  | raw when String.contains raw '.' ->
      let normalized = normalize_tool_name raw in
      exec_masc_tool runtime ~name:normalized ~args
  | raw -> exec_masc_tool runtime ~name:raw ~args

let tool_exec_json runtime ~name ~args =
  match exec_tool runtime ~name ~args with
  | Ok payload -> (
      try Yojson.Safe.from_string payload with
      | Yojson.Json_error _ -> `String payload)
  | Error message -> `Assoc [ ("error", `String message) ]

let chain_of_source ~config ?chain_id ?mermaid () =
  ensure_bootstrap config;
  match chain_id, mermaid with
  | Some id, _ -> (
      match Chain_registry.lookup id with
      | Some chain -> Ok chain
      | None -> Error (sprintf "ChainRef '%s' not found in MASC registry" id))
  | None, Some text -> Chain_mermaid_parser.parse_mermaid_to_chain text
  | None, None -> Error "chain_id or mermaid is required"

let registered_chain_mermaid ~config ~chain_id =
  match chain_of_source ~config ~chain_id () with
  | Ok chain -> Some (Chain_mermaid_parser.chain_to_mermaid chain)
  | Error _ -> None

let run_chain (runtime : runtime) ?chain_id ?mermaid ?input_json ~checkpoint_enabled () :
    (chain_run_response, string) result =
  let* chain = chain_of_source ~config:runtime.config ?chain_id ?mermaid () in
  let* plan =
    match Chain_compiler.compile chain with
    | Ok compiled -> Ok compiled
    | Error msg -> Error (sprintf "Compile error: %s" msg)
  in
  let exec_fn ~model ?system ~prompt ?tools ?thinking () =
    call_model_text runtime ~model ?system ?tools ?thinking ~prompt
      ~timeout_sec:(max 1 plan.chain.config.timeout) ()
  in
  let tool_exec ~name ~args = exec_tool runtime ~name ~args in
  let checkpoint =
    Some
      (Chain_executor_eio.make_checkpoint_config ?fs:runtime.mcp_state.Mcp_server.fs
         ~enabled:checkpoint_enabled ())
  in
  let input = Option.map Yojson.Safe.to_string input_json in
  let result =
    Chain_executor_eio.execute ~sw:runtime.sw ~clock:runtime.clock
      ~timeout:(max 1 plan.chain.config.timeout) ~trace:plan.chain.config.trace
      ~exec_fn ~tool_exec ?input ?checkpoint plan
  in
  let run_id = List.assoc_opt "run_id" result.metadata in
  Ok
    {
      output = result.output;
      chain_id = Some result.chain_id;
      run_id;
      duration_ms = Some result.duration_ms;
      trace_count = Some (List.length result.trace);
    }

let default_orchestrator_model () =
  Env_config.Chain.orchestrator_model ()

let orchestrate_goal (runtime : runtime) ~(on_chain_designed : Chain_types.chain -> unit) ~goal :
    (chain_orchestrate_response, string) result =
  ensure_bootstrap runtime.config;
  let model_call ~prompt =
    match
      call_model_text runtime ~model:(default_orchestrator_model ()) ~prompt ~timeout_sec:180
        ()
    with
    | Ok output -> output
    | Error msg -> sprintf "MODEL orchestration failed: %s" msg
  in
  let tool_exec ~name ~args = tool_exec_json runtime ~name ~args in
  match
    Chain_orchestrator_eio.orchestrate_quick ~sw:runtime.sw ~clock:runtime.clock
      ~model_call ~tool_exec ~on_chain_designed ~goal ~tasks:[]
  with
  | Ok result ->
      Ok
        {
          summary = result.summary;
          success = Some result.success;
          total_replans = Some result.total_replans;
          chain_id = result.chain_id;
          run_id = result.run_id;
        }
  | Error err ->
      Error
        (match err with
        | Chain_orchestrator_eio.DesignFailed msg -> "Design failed: " ^ msg
        | Chain_orchestrator_eio.CompileFailed msg -> "Compile failed: " ^ msg
        | Chain_orchestrator_eio.ExecutionFailed msg -> "Execution failed: " ^ msg
        | Chain_orchestrator_eio.VerificationFailed msg ->
            "Verification failed: " ^ msg
        | Chain_orchestrator_eio.MaxReplansExceeded -> "Max replans exceeded"
        | Chain_orchestrator_eio.Timeout -> "Timeout")

let chain_event_name = function
  | Chain_telemetry.ChainStart _ -> "chain_start"
  | Chain_telemetry.NodeStart _ -> "node_start"
  | Chain_telemetry.NodeComplete _ -> "node_complete"
  | Chain_telemetry.ChainComplete _ -> "chain_complete"
  | Chain_telemetry.Error _ -> "chain_error"

let chain_event_json = function
  | Chain_telemetry.ChainStart payload ->
      `Assoc
        [
          ("event", `String "chain_start");
          ("chain_id", `String payload.start_chain_id);
          ("nodes", `Int payload.start_nodes);
          ("timestamp", `Float payload.start_timestamp);
          ( "mermaid_dsl",
            match payload.start_mermaid_dsl with
            | Some value -> `String value
            | None -> `Null );
        ]
  | Chain_telemetry.NodeStart payload ->
      `Assoc
        [
          ("event", `String "node_start");
          ("node_id", `String payload.node_start_id);
          ("node_type", `String payload.node_start_type);
          ( "parent",
            match payload.node_parent with Some value -> `String value | None -> `Null );
        ]
  | Chain_telemetry.NodeComplete payload ->
      `Assoc
        [
          ("event", `String "node_complete");
          ("node_id", `String payload.node_complete_id);
          ("duration_ms", `Int payload.node_duration_ms);
          ("confidence", `Float payload.node_confidence);
          ("tokens", Chain_category.token_usage_to_yojson payload.node_tokens);
          ("verdict", Chain_category.verdict_to_yojson payload.node_verdict);
          ( "output_preview",
            match payload.node_output_preview with
            | Some value -> `String value
            | None -> `Null );
        ]
  | Chain_telemetry.ChainComplete payload ->
      `Assoc
        [
          ("event", `String "chain_complete");
          ("chain_id", `String payload.complete_chain_id);
          ("duration_ms", `Int payload.complete_duration_ms);
          ("tokens", Chain_category.token_usage_to_yojson payload.complete_tokens);
          ("nodes_executed", `Int payload.nodes_executed);
          ("nodes_skipped", `Int payload.nodes_skipped);
        ]
  | Chain_telemetry.Error payload ->
      `Assoc
        [
          ("event", `String "chain_error");
          ("node_id", `String payload.error_node_id);
          ("message", `String payload.error_message);
          ("retries", `Int payload.error_retries);
          ("timestamp", `Float payload.error_timestamp);
        ]

let running_chains_json () =
  Chain_telemetry.get_running_chains ()
  |> List.map (fun (chain_id, started_at, progress) ->
         `Assoc
           [
             ("chain_id", `String chain_id);
             ("started_at", `Float started_at);
             ("progress", `Float progress);
             ("elapsed_sec", `Float (max 0.0 (Time_compat.now () -. started_at)));
           ])

let read_history_events ~limit =
  let history_file =
    Env_config.Chain.history_file_opt ()
    |> Option.value ~default:"data/chain_history.jsonl"
  in
  if not (Sys.file_exists history_file) then []
  else
    read_lines_tail ~max_bytes:(1024 * 1024) ~max_lines:(max limit 1)
      history_file
    |> List.filter_map (fun line ->
           let line = trim line in
           if String.equal line "" then None
           else
             try Some (Yojson.Safe.from_string line)
             with Yojson.Json_error _ -> None)

let run_json ~run_id =
  Chain_run_store.get_run_json ~run_id
