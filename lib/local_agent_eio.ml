open Printf

module Oas = Agent_sdk

let ( let* ) = Result.bind

include Worker_container
include Worker_mcp_transport

let worker_container_version = 1

type run_result = {
  output : string;
  model_used : string;
  input_tokens : int option;
  output_tokens : int option;
  cost_usd : float option;
  tool_call_count : int;
  tool_names : string list;
  session_id : string;
  raw_trace_run : Oas.Raw_trace.run_ref option;
}

let safe_text_for_followup text =
  let trimmed = String.trim text in
  if String.length trimmed <= 1200 then trimmed
  else String.sub trimmed 0 1200 ^ "...[truncated]"

let followup_prompt ~original_prompt ~tool_outputs ~already_used =
  let tool_lines =
    tool_outputs
    |> List.mapi (fun idx ((tc : Llm_client.tool_call), output) ->
           sprintf "%d. %s(%s)\n%s" (idx + 1) tc.call_name tc.call_arguments
             (safe_text_for_followup output))
    |> String.concat "\n\n"
  in
  sprintf
    {|Continue the same worker task.

Original task:
%s

Tool results:
%s

Already used tools: %s

If more tools are required, call them. Otherwise return the final result.|}
    original_prompt tool_lines
    (if already_used = [] then "none" else String.concat ", " already_used)

let split_top_level delimiter (text : string) =
  let len = String.length text in
  let buf = Buffer.create len in
  let acc = ref [] in
  let in_string = ref false in
  let escaped = ref false in
  let paren_depth = ref 0 in
  let bracket_depth = ref 0 in
  let brace_depth = ref 0 in
  let flush () =
    let item = Buffer.contents buf |> String.trim in
    Buffer.clear buf;
    if item <> "" then acc := item :: !acc
  in
  for idx = 0 to len - 1 do
    let ch = text.[idx] in
    if !in_string then (
      Buffer.add_char buf ch;
      if !escaped then
        escaped := false
      else
        match ch with
        | '\\' -> escaped := true
        | '"' -> in_string := false
        | _ -> ())
    else
      match ch with
      | '"' ->
          in_string := true;
          Buffer.add_char buf ch
      | '(' ->
          incr paren_depth;
          Buffer.add_char buf ch
      | ')' ->
          decr paren_depth;
          Buffer.add_char buf ch
      | '[' ->
          incr bracket_depth;
          Buffer.add_char buf ch
      | ']' ->
          decr bracket_depth;
          Buffer.add_char buf ch
      | '{' ->
          incr brace_depth;
          Buffer.add_char buf ch
      | '}' ->
          decr brace_depth;
          Buffer.add_char buf ch
      | c
        when c = delimiter && !paren_depth = 0 && !bracket_depth = 0
             && !brace_depth = 0 ->
          flush ()
      | _ -> Buffer.add_char buf ch
  done;
  flush ();
  List.rev !acc

let find_top_level_char target (text : string) =
  let len = String.length text in
  let in_string = ref false in
  let escaped = ref false in
  let paren_depth = ref 0 in
  let bracket_depth = ref 0 in
  let brace_depth = ref 0 in
  let result = ref None in
  let idx = ref 0 in
  while !idx < len && !result = None do
    let ch = text.[!idx] in
    if !in_string then
      if !escaped then
        escaped := false
      else
        match ch with
        | '\\' -> escaped := true
        | '"' -> in_string := false
        | _ -> ()
    else
      match ch with
      | '"' -> in_string := true
      | '(' -> incr paren_depth
      | ')' -> decr paren_depth
      | '[' -> incr bracket_depth
      | ']' -> decr bracket_depth
      | '{' -> incr brace_depth
      | '}' -> decr brace_depth
      | _ when ch = target && !paren_depth = 0 && !bracket_depth = 0 && !brace_depth = 0 ->
          result := Some !idx
      | _ -> ();
    incr idx
  done;
  !result

let parse_text_tool_args (args_text : string) =
  let trimmed = String.trim args_text in
  if trimmed = "" then Ok (`Assoc [])
  else
    let parts = split_top_level ',' trimmed in
    let rec build acc = function
      | [] -> Ok (`Assoc (List.rev acc))
      | part :: rest -> (
          match find_top_level_char '=' part with
          | None ->
              Error (sprintf "invalid tool arg assignment: %s" part)
          | Some idx ->
              let key = String.sub part 0 idx |> String.trim in
              let value_text =
                String.sub part (idx + 1) (String.length part - idx - 1)
                |> String.trim
              in
              if key = "" then
                Error "empty tool arg key"
              else
                match Yojson.Safe.from_string value_text with
                | value -> build ((key, value) :: acc) rest
                | exception Yojson.Json_error msg ->
                    Error
                      (sprintf "invalid tool arg JSON for %s: %s" key msg))
    in
    build [] parts

let parse_text_tool_calls (content : string) : Llm_client.tool_call list =
  let prefix = "mcp__masc__" in
  let prefix_len = String.length prefix in
  let len = String.length content in
  let is_name_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let rec parse_args idx depth in_string escaped =
    if idx >= len then None
    else
      let ch = content.[idx] in
      if in_string then
        if escaped then
          parse_args (idx + 1) depth true false
        else
          match ch with
          | '\\' -> parse_args (idx + 1) depth true true
          | '"' -> parse_args (idx + 1) depth false false
          | _ -> parse_args (idx + 1) depth true false
      else
        match ch with
        | '"' -> parse_args (idx + 1) depth true false
        | '(' -> parse_args (idx + 1) (depth + 1) false false
        | ')' ->
            if depth = 1 then Some idx
            else parse_args (idx + 1) (depth - 1) false false
        | _ -> parse_args (idx + 1) depth false false
  in
  let rec collect idx call_id acc =
    if idx >= len - prefix_len then List.rev acc
    else if String.sub content idx prefix_len <> prefix then
      collect (idx + 1) call_id acc
    else
      let name_start = idx in
      let name_end = ref (idx + prefix_len) in
      while !name_end < len && is_name_char content.[!name_end] do
        incr name_end
      done;
      if !name_end >= len || content.[!name_end] <> '(' then
        collect (!name_end) call_id acc
      else
        match parse_args (!name_end + 1) 1 false false with
        | None -> collect (!name_end + 1) call_id acc
        | Some close_idx ->
            let tool_name =
              String.sub content name_start (!name_end - name_start)
              |> strip_mcp_prefix
            in
            let args_raw =
              String.sub content (!name_end + 1) (close_idx - !name_end - 1)
            in
            (match parse_text_tool_args args_raw with
            | Ok args_json ->
                collect (close_idx + 1) (call_id + 1)
                  ({
                     Llm_client.call_id = sprintf "text-fallback-%d" call_id;
                     call_name = tool_name;
                     call_arguments = Yojson.Safe.to_string args_json;
                   }
                  :: acc)
            | Error msg ->
                eprintf "[local-worker] ignored text tool call (%s): %s\n%!"
                  tool_name msg;
                collect (close_idx + 1) call_id acc)
  in
  collect 0 1 []

let make_usage ?(input_tokens = 0) ?(output_tokens = 0) () =
  {
    Llm_client.input_tokens;
    output_tokens;
    total_tokens = input_tokens + output_tokens;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
  }

let merge_usage a b =
  {
    Llm_client.input_tokens = a.Llm_client.input_tokens + b.Llm_client.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    total_tokens = a.total_tokens + b.total_tokens;
    cache_creation_input_tokens =
      a.cache_creation_input_tokens + b.cache_creation_input_tokens;
    cache_read_input_tokens =
      a.cache_read_input_tokens + b.cache_read_input_tokens;
  }

let estimate_cost_usd (model : Llm_client.model_spec)
    (usage : Llm_client.token_usage) : float option =
  let input_cost =
    (float_of_int usage.input_tokens /. 1000.0) *. model.cost_per_1k_input
  in
  let output_cost =
    (float_of_int usage.output_tokens /. 1000.0) *. model.cost_per_1k_output
  in
  Some (input_cost +. output_cost)

let local_worker_max_tokens () =
  match Sys.getenv_opt "MASC_LOCAL_WORKER_MAX_TOKENS" with
  | None -> 1024
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value -> max 64 (min 2048 value)
      | None -> 1024)

let local_worker_heartbeat_interval_sec () =
  match Sys.getenv_opt "MASC_LOCAL_WORKER_HEARTBEAT_SEC" with
  | None -> 60
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value -> max 0 (min 600 value)
      | None -> 60)

let join_worker ~sw ~(auth_token : string option) ~session_id ~worker_name =
  let args =
    `Assoc
      [
        ("agent_name", `String worker_name);
        ( "capabilities",
          `List
            [
              `String "llama";
              `String "mcp-worker";
              `String "local-tool-loop";
            ] );
      ]
  in
  call_masc_tool ~sw ~auth_token ~session_id ~tool_name:"masc_join" ~args

let leave_worker ~sw ~(auth_token : string option) ~session_id ~worker_name =
  let args = `Assoc [ ("agent_name", `String worker_name) ] in
  call_masc_tool ~sw ~auth_token ~session_id ~tool_name:"masc_leave" ~args

let default_system_prompt ~worker_name ~model_id ?session_id ?role
    ?selection_note () =
  let session_line =
    match session_id with
    | Some value when String.trim value <> "" ->
        sprintf "Team session: %s\n" (String.trim value)
    | _ -> ""
  in
  let role_line =
    match role with
    | Some value when String.trim value <> "" ->
        sprintf "Assigned role: %s\n" (String.trim value)
    | _ -> ""
  in
  let selection_line =
    match selection_note with
    | Some value when String.trim value <> "" ->
        sprintf "Leader-selected model context: %s\n" (String.trim value)
    | _ -> ""
  in
  sprintf
    {|You are a MASC-managed tool-aware worker.
Worker name: %s
Model: %s
%s%s%s
Operate through the provided MASC tools.
Use tools when state inspection, task coordination, work delegation, or room updates are needed.
Keep responses concise and task-focused.
If a tool schema includes agent_name and you omit it, the runtime will inject %s automatically.
Do not invent tool names or arguments that are not in schema.
If you are operating inside a team session, record your own work with masc_team_session_step as the worker.
Inside a team session, record at least one note turn with masc_team_session_step(session_id="...", turn_kind="note", message="...") and a non-empty message that states your concrete contribution.
A note turn without a message is invalid and will be rejected.
When the task is complete, return a short final result summarizing what you changed or learned.|}
    worker_name model_id session_line role_line selection_line worker_name

let worker_session_id worker_name =
  let digest =
    Digest.string (worker_name ^ string_of_float (Time_compat.now ())) |> Digest.to_hex
  in
  sprintf "llama-%s" (String.sub digest 0 12)

let worker_auth_token ~base_path ~worker_name =
  let auth_cfg = Auth.load_auth_config base_path in
  if auth_cfg.enabled && auth_cfg.require_token then
    match Auth.create_token base_path ~agent_name:worker_name ~role:Types.Worker with
    | Ok (token, _cred) -> Ok (Some token)
    | Error err -> Error (Types.masc_error_to_string err)
  else
    Ok None

let start_worker_heartbeat ~sw ~(auth_token : string option) ~session_id
    ~worker_name =
  let interval = local_worker_heartbeat_interval_sec () in
  match (interval, Eio_context.get_clock_opt ()) with
  | interval, _ when interval <= 0 -> fun () -> ()
  | _, None -> fun () -> ()
  | interval, Some clock ->
      let active = ref true in
      Eio.Fiber.fork ~sw (fun () ->
          let rec loop () =
            if !active then (
              Eio.Time.sleep clock (float_of_int interval);
              if !active then (
                match
                  call_masc_tool ~sw ~auth_token ~session_id
                    ~tool_name:"masc_heartbeat" ~args:(`Assoc [])
                with
                | Ok _ -> ()
                | Error e ->
                    eprintf "[local-worker] heartbeat error for %s: %s\n%!"
                      worker_name e;
                loop ()))
          in
          try loop ()
          with
          | Eio.Cancel.Cancelled _ as ex -> raise ex
          | exn ->
            eprintf "[local-worker] heartbeat loop error for %s: %s\n%!"
              worker_name (Printexc.to_string exn));
      fun () -> active := false

let resolve_execution_scope ~base_path ~(team_session_id : string option)
    ?execution_scope () =
  match execution_scope with
  | Some scope -> scope
  | None -> (
      match team_session_id with
      | Some session_id -> (
          match Team_session_store.load_session (Room.default_config base_path) session_id with
          | Some session -> session.execution_scope
          | None -> Team_session_types.Limited_code_change)
      | None -> Team_session_types.Limited_code_change)

let build_oas_mcp_tools ~sw ~auth_token ~session_id ~worker_name ~prompt
    ~allowed_tools =
  let allowed_names =
    match allowed_tools |> List.map strip_mcp_prefix |> unique_preserve_order with
    | [] -> session_min_tool_names
    | names -> names
  in
  let listed_schemas =
    list_masc_tools ~sw ~auth_token ~session_id ~names:(Some allowed_names) ()
  in
  Result.map
    (fun schemas ->
      schemas
      |> List.filter (fun (schema : Types.tool_schema) ->
             List.mem schema.name allowed_names)
      |> List.map (fun (schema : Types.tool_schema) ->
             let call_fn input =
               let args =
                 input
                 |> inject_default_agent_name ~worker_name
                      ~schema:(Some schema)
                 |> inject_prompt_full_context ~prompt ~tool_name:schema.name
               in
               match
                 call_masc_tool ~sw ~auth_token ~session_id ~tool_name:schema.name
                   ~args
               with
               | Ok result when result.is_error ->
                 Error { Oas.Types.message = result.text; recoverable = false }
               | Ok result ->
                 Ok { Oas.Types.content = result.text }
               | Error e ->
                 Error { Oas.Types.message = e; recoverable = false }
             in
             Oas.Mcp.mcp_tool_to_sdk_tool ~call_fn
               {
                 Oas.Mcp.name = schema.name;
                 description = schema.description;
                 input_schema = schema.input_schema;
               }))
    listed_schemas

let build_local_shell_tools ~room_config ~worker_name ~execution_scope ~workdir =
  match Process_eio.get_proc_mgr (), Process_eio.get_clock () with
  | Ok proc_mgr, Ok clock -> (
      let on_exec ~tool_name ~success ~duration_ms =
        (match room_config, Fs_compat.get_fs_opt () with
        | Some config, Some fs -> (
            try
              Telemetry_eio.track_tool_called ~fs config ~tool_name ~success
                ~duration_ms ~agent_id:worker_name ()
            with exn ->
              eprintf "[local-worker] telemetry error for %s/%s: %s\n%!"
                worker_name tool_name (Printexc.to_string exn))
        | _ -> ());
        ()
      in
      match execution_scope with
      | Team_session_types.Observe_only ->
          Ok
            (Agent_swarm_dev_tools.make_readonly_tools ~proc_mgr ~clock
               ~workdir ~on_exec ())
      | Team_session_types.Limited_code_change ->
          Ok
            (Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock ~workdir
               ~on_exec ()))
  | Error e, _ | _, Error e -> Error e

let oas_provider_of_model (model : Llm_client.model_spec) : Oas.Provider.config =
  {
    Oas.Provider.provider =
      Oas.Provider.OpenAICompat
        {
          base_url = model.api_url;
          auth_header = None;
          path = "/v1/chat/completions";
          static_token = None;
        };
    model_id = model.model_id;
    api_key_env = "DUMMY_KEY";
  }

let oas_tool_names (tools : Oas.Tool.t list) =
  List.map (fun (tool : Oas.Tool.t) -> tool.schema.name) tools

let oas_extract_text (response : Oas.Types.api_response) =
  response.content
  |> List.filter_map (function Oas.Types.Text text -> Some text | _ -> None)
  |> String.concat "\n"

let make_worker_meta ~base_path ~workspace_path ~team_session_id ~worker_name
    ~mcp_session_id ~role ~selection_note ~execution_scope ~worker_class
    ~worker_size ~effective_model ~thinking_enabled ~max_turns_override
    ~timeout_seconds =
  let tool_profile, shell_profile = worker_profiles_of_scope execution_scope in
  let effective_tier = derive_effective_tier worker_size effective_model in
  {
    version = worker_container_version;
    worker_name;
    mcp_session_id;
    team_session_id;
    workspace_path;
    role;
    selection_note;
    execution_scope;
    thinking_enabled;
    max_turns_override;
    timeout_seconds;
    tool_profile;
    shell_profile;
    worker_class;
    worker_size = effective_worker_size worker_size effective_model;
    effective_model;
    effective_tier;
    checkpoint_path =
      worker_checkpoint_path ~base_path ~team_session_id ~worker_name;
    turn_log_path =
      worker_turn_log_path ~base_path ~team_session_id ~worker_name;
    last_run_at = None;
  }

let append_worker_completion_log ~base_path ~team_session_id ~worker_name
    ~prompt ~tool_names ~status ~output ?error () =
  append_worker_turn_log ~base_path ~team_session_id ~worker_name
    (`Assoc
      [
        ("ts", `Float (Time_compat.now ()));
        ("status", `String status);
        ("prompt", `String (safe_text_for_followup prompt));
        ("tool_names", `List (List.map (fun name -> `String name) tool_names));
        ("output_preview", `String (safe_text_for_followup output));
        ( "error",
          Option.fold ~none:`Null ~some:(fun value -> `String value) error );
      ])

let build_oas_agent ~worker_name ~model ~system_prompt ~tools ~max_turns
    ~thinking_enabled ~hooks ~raw_trace =
  let config =
    {
      Oas.Types.default_config with
      name = worker_name;
      model = Oas.Types.Custom model.Llm_client.model_id;
      system_prompt = Some system_prompt;
      max_tokens = local_worker_max_tokens ();
      max_turns;
      temperature = Some 0.2;
      top_p = Some 0.95;
      top_k = Some 20;
      min_p = Some 0.0;
      enable_thinking = Some thinking_enabled;
      tool_choice = Some Oas.Types.Auto;
    }
  in
  let options =
    {
      Oas.Agent.default_options with
      provider = Some (oas_provider_of_model model);
      hooks;
      guardrails =
        {
          Oas.Guardrails.tool_filter =
            Oas.Guardrails.AllowList (oas_tool_names tools);
          max_tool_calls_per_turn = Some 12;
        };
      raw_trace = Some raw_trace;
    }
  in
  (config, options)

let materialize_direct_evidence ~base_path ~worker_name
    ~(worker_run_id : string option) ~(meta : worker_container_meta) ~prompt
    ~workspace_path ~agent ~raw_trace =
  match evidence_session_id_of_worker_run worker_run_id with
  | None -> ()
  | Some session_id ->
      let aliases =
        unique_preserve_order
          ([ worker_name ]
          @
          match meta.role with
          | Some role
            when String.trim role <> ""
                 && not (String.equal role worker_name) ->
              [ role ]
          | _ -> [])
      in
      let options =
        {
          Oas.Direct_evidence.session_root =
            Some (oas_trace_session_root ~base_path);
          session_id;
          goal = prompt;
          title = Some (Printf.sprintf "MASC worker %s" worker_name);
          tag = Some "masc-team-worker";
          worker_id =
            Some (stable_worker_session_id ?team_session_id:meta.team_session_id worker_name);
          runtime_actor = Some worker_name;
          role = meta.role;
          aliases;
          requested_provider = Some "local";
          requested_model = Some meta.effective_model;
          requested_policy =
            Some
              (Team_session_types.execution_scope_to_string
                 meta.execution_scope);
          workdir = Some workspace_path;
        }
      in
      match Oas.Direct_evidence.persist ~agent ~raw_trace ~options () with
      | Ok _ -> ()
      | Error err ->
          eprintf
            "[local-worker] direct evidence persist failed for %s/%s: %s\n%!"
            worker_name session_id (Oas.Error.to_string err)

let run_worker_oas ~sw ~base_path ~worker_name
    ~(model : Llm_client.model_spec) ~team_session_id
    ~room_config ?working_dir ?worker_class ?worker_size ?execution_scope
    ?thinking_enabled ?max_turns ?worker_run_id
    ~role
    ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  fun () ->
    let mcp_session_id =
      resolved_mcp_session_id ~base_path ~team_session_id ~worker_name
    in
    let execution_scope =
      resolve_execution_scope ~base_path ~team_session_id ?execution_scope ()
    in
    let workspace_path =
      match working_dir with
      | Some dir when String.trim dir <> "" -> dir
      | _ -> base_path
    in
    let meta =
      make_worker_meta ~base_path ~workspace_path ~team_session_id ~worker_name
        ~mcp_session_id ~role ~selection_note ~execution_scope ~worker_class
        ~worker_size ~effective_model:model.model_id
        ~thinking_enabled ~max_turns_override:max_turns
        ~timeout_seconds:(Some timeout_sec)
    in
    match worker_auth_token ~base_path ~worker_name with
    | Error e -> Error e
    | Ok auth_token ->
        let* net =
          match Eio_context.get_net_opt () with
          | Some net -> Ok net
          | None -> Error "Eio net not initialized"
        in
        let evidence_session_id =
          evidence_session_id_of_worker_run worker_run_id
        in
        let system_prompt =
          default_system_prompt ~worker_name ~model_id:model.model_id
            ?session_id:team_session_id ?role ?selection_note ()
        in
        let prompt =
          let tool_contract =
            "Tool contract reminder: if you call masc_team_session_step with \
             turn_kind=\"note\", you must include a non-empty message field. \
             Calls missing message fail."
          in
          let workflow_contract =
            match execution_scope with
            | Team_session_types.Limited_code_change ->
                "Coding worker protocol: you must use tools before answering. \
                 If the task requires a code change, the expected loop is \
                 file_read -> shell_exec -> file_write -> shell_exec, and you \
                 should not finish until the verification shell_exec succeeds. \
                 If the task is inspection-only, do not modify files."
            | Team_session_types.Observe_only ->
                "Readonly worker protocol: use file_read and shell_exec for \
                 inspection, but do not modify files."
          in
          String.concat "\n\n" [ tool_contract; workflow_contract; prompt ]
        in
        let* () =
          save_worker_meta ~base_path ~team_session_id ~worker_name meta
        in
        let stop_heartbeat =
          start_worker_heartbeat ~sw ~auth_token ~session_id:mcp_session_id
            ~worker_name
        in
        Fun.protect
          ~finally:(fun () ->
            stop_heartbeat ();
            ignore
              (leave_worker ~sw ~auth_token ~session_id:mcp_session_id
                 ~worker_name))
          (fun () ->
          let _ =
            match join_worker ~sw ~auth_token ~session_id:mcp_session_id
                    ~worker_name with
            | Ok _ -> ()
            | Error e -> raise (Failure ("worker join failed: " ^ e))
          in
          let* mcp_tools =
            build_oas_mcp_tools ~sw ~auth_token ~session_id:mcp_session_id
              ~worker_name ~prompt ~allowed_tools
          in
          let* shell_tools =
            build_local_shell_tools ~room_config ~worker_name ~execution_scope
              ~workdir:workspace_path
          in
          let tools = mcp_tools @ shell_tools in
          let* raw_trace =
            match evidence_session_id with
            | Some trace_session_id ->
                Oas.Raw_trace.create_for_session
                  ~session_root:(oas_trace_session_root ~base_path)
                  ~session_id:trace_session_id ~agent_name:worker_name ()
                |> Result.map_error Oas.Error.to_string
            | None -> (
                match team_session_id with
                | Some trace_session_id ->
                    Oas.Raw_trace.create_for_session
                      ~session_root:(oas_trace_session_root ~base_path)
                      ~session_id:trace_session_id ~agent_name:worker_name ()
                    |> Result.map_error Oas.Error.to_string
                | None ->
                    Oas.Raw_trace.create ~session_id:mcp_session_id
                      ~path:
                        (worker_raw_trace_path ~base_path
                           ~team_session_id
                           ~worker_name)
                      ()
                    |> Result.map_error Oas.Error.to_string)
          in
          let tool_names_ref = ref [] in
          let hooks =
            {
              Oas.Hooks.empty with
              pre_tool_use =
                Some
                  (function
                    | Oas.Hooks.PreToolUse { tool_name; _ } ->
                        tool_names_ref := tool_name :: !tool_names_ref;
                        Oas.Hooks.Continue
                    | _ -> Oas.Hooks.Continue);
            }
          in
          let max_turn_cap =
            match execution_scope with
            | Team_session_types.Limited_code_change -> 20
            | Team_session_types.Observe_only -> 12
          in
          let max_turns =
            match max_turns with
            | Some value -> max 1 (min max_turn_cap value)
            | None -> max 2 (min max_turn_cap (max 2 (timeout_sec / 20)))
          in
          let thinking_enabled =
            Option.value ~default:false thinking_enabled
          in
          let config, options =
            build_oas_agent ~worker_name ~model ~system_prompt ~tools
              ~max_turns ~thinking_enabled ~hooks ~raw_trace
          in
          let agent = Oas.Agent.create ~net ~config ~tools ~options () in
          let result =
            Oas.Agent.run ~sw agent prompt
          in
          let raw_trace_run = Oas.Agent.last_raw_trace_run agent in
          let checkpoint =
            Oas.Agent.checkpoint ~session_id:mcp_session_id agent
          in
          let tool_names =
            List.rev !tool_names_ref |> unique_preserve_order
          in
          let* () =
            save_worker_checkpoint ~base_path ~team_session_id ~worker_name
              checkpoint
          in
          let* () =
            save_worker_meta ~base_path ~team_session_id ~worker_name
              { meta with last_run_at = Some (Time_compat.now ()) }
          in
          materialize_direct_evidence ~base_path ~worker_name ~worker_run_id
            ~meta ~prompt ~workspace_path ~agent ~raw_trace;
          Oas.Agent.close agent;
          match result with
          | Ok response ->
              let output = oas_extract_text response in
              let* () =
                append_worker_completion_log ~base_path ~team_session_id
                  ~worker_name ~prompt ~tool_names ~status:"ok" ~output ()
              in
              Ok
                {
                  output;
                  model_used =
                    (if String.trim response.model <> "" then response.model
                     else model.model_id);
                  input_tokens = Some checkpoint.usage.total_input_tokens;
                  output_tokens = Some checkpoint.usage.total_output_tokens;
                  cost_usd = estimate_cost_usd model
                      (make_usage ~input_tokens:checkpoint.usage.total_input_tokens
                         ~output_tokens:checkpoint.usage.total_output_tokens ());
                  tool_call_count = List.length tool_names;
                  tool_names;
                  session_id = mcp_session_id;
                  raw_trace_run;
                }
          | Error err ->
              let detail = Agent_sdk__Error.to_string err in
              let* () =
                append_worker_completion_log ~base_path ~team_session_id
                  ~worker_name ~prompt ~tool_names ~status:"error"
                  ~output:detail ~error:detail ()
              in
              Error detail)

let continue_worker ?worker_run_id ~sw ~base_path ~room_config ~worker_name
    ~(team_session_id : string) ~(prompt : string) :
    unit -> (run_result, string) result =
  fun () ->
  let team_session_id = Some team_session_id in
  match get_worker_container_state ~base_path ~team_session_id ~worker_name with
  | Worker_missing ->
      Error
        (sprintf
           "target worker '%s' was not found. Use status.worker_runs or the \
            latest team_step_spawn event to find a ready worker name."
           worker_name)
  | Worker_pending ->
      Error
        (sprintf
           "target worker '%s' has been accepted but is not ready for \
            delegation yet. Wait for a successful team_step_spawn event or a \
            ready worker in status.worker_runs."
           worker_name)
  | Worker_ready ->
      let meta =
        load_worker_meta ~base_path ~team_session_id ~worker_name
      in
      let checkpoint =
        load_worker_checkpoint ~base_path ~team_session_id ~worker_name
      in
      (match meta, checkpoint with
      | None, _ ->
          Error
            (sprintf "worker container metadata disappeared: %s" worker_name)
      | _, None ->
          Error
            (sprintf
               "worker checkpoint is not available for '%s'; wait for the \
                worker to finish its first run before delegating."
               worker_name)
      | Some meta, Some checkpoint -> (
      let workspace_path =
        if String.trim meta.workspace_path <> "" then meta.workspace_path
        else base_path
      in
      match worker_auth_token ~base_path ~worker_name with
      | Error e -> Error e
      | Ok auth_token ->
          let* net =
            match Eio_context.get_net_opt () with
            | Some net -> Ok net
            | None -> Error "Eio net not initialized"
          in
          let stop_heartbeat =
            start_worker_heartbeat ~sw ~auth_token ~session_id:meta.mcp_session_id
              ~worker_name
          in
          Fun.protect
            ~finally:(fun () ->
              stop_heartbeat ();
              ignore
                (leave_worker ~sw ~auth_token
                   ~session_id:meta.mcp_session_id ~worker_name))
            (fun () ->
              let _ =
                match join_worker ~sw ~auth_token
                        ~session_id:meta.mcp_session_id ~worker_name with
                | Ok _ -> ()
                | Error e -> raise (Failure ("worker join failed: " ^ e))
              in
              let allowed_tools =
                match meta.shell_profile with
                | Shell_dev ->
                    [ "mcp__masc__masc_heartbeat"; "mcp__masc__masc_memento_mori" ]
                | _ ->
                    session_min_tool_names
                    |> List.map (fun name -> "mcp__masc__" ^ name)
              in
              let* mcp_tools =
                build_oas_mcp_tools ~sw ~auth_token
                  ~session_id:meta.mcp_session_id ~worker_name ~prompt
                  ~allowed_tools
              in
              let shell_tools =
                match meta.shell_profile with
                | Shell_none -> Ok []
                | Shell_readonly ->
                    build_local_shell_tools
                      ~room_config ~worker_name
                      ~execution_scope:Team_session_types.Observe_only
                      ~workdir:workspace_path
                | Shell_dev ->
                    build_local_shell_tools
                      ~room_config ~worker_name
                      ~execution_scope:Team_session_types.Limited_code_change
                      ~workdir:workspace_path
              in
              let* shell_tools = shell_tools in
              let* raw_trace =
                match evidence_session_id_of_worker_run worker_run_id with
                | Some trace_session_id ->
                    Oas.Raw_trace.create_for_session
                      ~session_root:(oas_trace_session_root ~base_path)
                      ~session_id:trace_session_id ~agent_name:worker_name ()
                    |> Result.map_error Oas.Error.to_string
                | None -> (
                    match meta.team_session_id with
                    | Some trace_session_id ->
                        Oas.Raw_trace.create_for_session
                          ~session_root:(oas_trace_session_root ~base_path)
                          ~session_id:trace_session_id ~agent_name:worker_name ()
                        |> Result.map_error Oas.Error.to_string
                    | None ->
                        Oas.Raw_trace.create ~session_id:meta.mcp_session_id
                          ~path:
                            (worker_raw_trace_path ~base_path ~team_session_id
                               ~worker_name)
                          ()
                        |> Result.map_error Oas.Error.to_string)
              in
              let tools = mcp_tools @ shell_tools in
              let tool_names_ref = ref [] in
              let hooks =
                {
                  Oas.Hooks.empty with
                  pre_tool_use =
                    Some
                      (function
                        | Oas.Hooks.PreToolUse { tool_name; _ } ->
                            tool_names_ref := tool_name :: !tool_names_ref;
                            Oas.Hooks.Continue
                        | _ -> Oas.Hooks.Continue);
                }
              in
              let model =
                let base_model = Llm_client.default_local_model_spec () in
                match checkpoint.model with
                | Oas.Types.Custom model_id ->
                    { base_model with model_id }
                | _ ->
                    { base_model with model_id = meta.effective_model }
              in
              let prompt =
                let tool_contract =
                  "Tool contract reminder: if you call masc_team_session_step \
                   with turn_kind=\"note\", you must include a non-empty \
                   message field. Calls missing message fail."
                in
                let workflow_contract =
                  match meta.execution_scope with
                  | Team_session_types.Limited_code_change ->
                      "Coding worker protocol: you must use tools before \
                       answering. If the task requires a code change, the \
                       expected loop is file_read -> shell_exec -> file_write \
                       -> shell_exec, and you should not finish until \
                       verification succeeds. If the task is inspection-only, \
                       do not modify files."
                  | Team_session_types.Observe_only ->
                      "Readonly worker protocol: use file_read and shell_exec \
                       for inspection, but do not modify files."
                in
                String.concat "\n\n" [ tool_contract; workflow_contract; prompt ]
              in
              let max_turns =
                match meta.max_turns_override with
                | Some value -> max 1 value
                | None ->
                    (match meta.execution_scope with
                    | Team_session_types.Limited_code_change -> 20
                    | Team_session_types.Observe_only -> 8)
              in
              let thinking_enabled =
                Option.value ~default:false meta.thinking_enabled
              in
              let config, options =
                build_oas_agent ~worker_name ~model
                  ~system_prompt:
                    (default_system_prompt ~worker_name ~model_id:model.model_id
                       ?session_id:meta.team_session_id ?role:meta.role
                       ?selection_note:meta.selection_note ())
                  ~tools ~max_turns ~thinking_enabled ~hooks ~raw_trace
              in
              let agent =
                Oas.Agent.resume ~net ~checkpoint ~tools ~options ~config ()
              in
              let result =
                Oas.Agent.run ~sw agent prompt
              in
              let raw_trace_run = Oas.Agent.last_raw_trace_run agent in
              let next_checkpoint =
                Oas.Agent.checkpoint ~session_id:meta.mcp_session_id agent
              in
              let tool_names =
                List.rev !tool_names_ref |> unique_preserve_order
              in
              let* () =
                save_worker_checkpoint ~base_path ~team_session_id ~worker_name
                  next_checkpoint
              in
              let* () =
                save_worker_meta ~base_path ~team_session_id ~worker_name
                  { meta with last_run_at = Some (Time_compat.now ()) }
              in
              materialize_direct_evidence ~base_path ~worker_name
                ~worker_run_id ~meta ~prompt ~workspace_path ~agent ~raw_trace;
              Oas.Agent.close agent;
              match result with
              | Ok response ->
                  let output = oas_extract_text response in
                  let* () =
                    append_worker_completion_log ~base_path ~team_session_id
                      ~worker_name ~prompt ~tool_names ~status:"ok" ~output ()
                  in
                  Ok
                    {
                      output;
                      model_used =
                        (if String.trim response.model <> "" then response.model
                         else meta.effective_model);
                      input_tokens = Some next_checkpoint.usage.total_input_tokens;
                      output_tokens = Some next_checkpoint.usage.total_output_tokens;
                      cost_usd =
                        estimate_cost_usd model
                          (make_usage
                             ~input_tokens:next_checkpoint.usage.total_input_tokens
                             ~output_tokens:next_checkpoint.usage.total_output_tokens
                             ());
                      tool_call_count = List.length tool_names;
                      tool_names;
                      session_id = meta.mcp_session_id;
                      raw_trace_run;
                    }
              | Error err ->
                  let detail = Agent_sdk__Error.to_string err in
                  let* () =
                    append_worker_completion_log ~base_path ~team_session_id
                      ~worker_name ~prompt ~tool_names ~status:"error"
                      ~output:detail ~error:detail ()
                  in
                  Error detail)))

let run_worker_legacy ~sw ~base_path ~worker_name
    ~(model : Llm_client.model_spec) ~team_session_id ~role
    ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  fun () ->
    let mcp_session_id =
      resolved_mcp_session_id ~base_path ~team_session_id ~worker_name
    in
    let execution_scope =
      resolve_execution_scope ~base_path ~team_session_id ?execution_scope:None ()
    in
    let meta =
      make_worker_meta ~base_path ~workspace_path:base_path ~team_session_id
        ~worker_name ~mcp_session_id ~role ~selection_note ~execution_scope
        ~worker_class:None ~worker_size:None ~effective_model:model.model_id
        ~thinking_enabled:None ~max_turns_override:None
        ~timeout_seconds:(Some timeout_sec)
    in
    match worker_auth_token ~base_path ~worker_name with
    | Error e -> Error e
    | Ok auth_token ->
        let* () =
          save_worker_meta ~base_path ~team_session_id ~worker_name meta
        in
        let stop_heartbeat =
          start_worker_heartbeat ~sw ~auth_token ~session_id:mcp_session_id
            ~worker_name
        in
        Fun.protect
          ~finally:(fun () ->
            stop_heartbeat ();
            ignore
              (leave_worker ~sw ~auth_token ~session_id:mcp_session_id
                 ~worker_name))
          (fun () ->
            let _ =
              match
                join_worker ~sw ~auth_token ~session_id:mcp_session_id
                  ~worker_name
              with
              | Ok _ -> ()
              | Error e -> raise (Failure ("worker join failed: " ^ e))
            in
            let allowed_names =
              allowed_tools |> List.map strip_mcp_prefix |> unique_preserve_order
            in
            let listed_schemas =
              match
                list_masc_tools ~sw ~auth_token ~session_id:mcp_session_id
                  ~names:(Some allowed_names) ()
              with
              | Ok schemas -> schemas
              | Error e -> raise (Failure ("tools/list failed: " ^ e))
            in
            let tool_schemas =
              List.filter
                (fun (schema : Types.tool_schema) ->
                  List.mem schema.name allowed_names)
                listed_schemas
            in
            let tool_defs = tool_defs_of_schemas tool_schemas in
            if tool_defs = [] then
              Error "no MASC tool definitions available for local worker"
            else
              let zero_usage = make_usage () in
              let rec loop ~round ~usage_acc ~tools_used current_prompt =
                let request : Llm_client.completion_request =
                  {
                    model;
                    messages =
                      [
                        Llm_client.system_msg
                          (default_system_prompt ~worker_name
                             ~model_id:model.model_id ?session_id:team_session_id
                             ?role ?selection_note ());
                        Llm_client.user_msg current_prompt;
                      ];
                    temperature = 0.2;
                    max_tokens = local_worker_max_tokens ();
                    tools = tool_defs;
                    response_format = `Text;
                  }
                in
                match Llm_client.complete ~timeout_sec request with
                | Error e -> Error e
                | Ok resp ->
                    let tool_calls =
                      match resp.tool_calls with
                      | [] -> parse_text_tool_calls resp.content
                      | calls -> calls
                    in
                    let usage_acc = merge_usage usage_acc resp.usage in
                    if tool_calls = [] then
                      let output =
                        let trimmed = String.trim resp.content in
                        if trimmed <> "" then trimmed
                        else if tools_used <> [] then
                          sprintf "(tools executed: %s)"
                            (String.concat ", "
                               (unique_preserve_order tools_used))
                        else
                          "(no output)"
                      in
                      Ok
                        {
                          output;
                          model_used = resp.model_used;
                          input_tokens = Some usage_acc.input_tokens;
                          output_tokens = Some usage_acc.output_tokens;
                          cost_usd = estimate_cost_usd model usage_acc;
                          tool_call_count = List.length tools_used;
                          tool_names = unique_preserve_order tools_used;
                          session_id = mcp_session_id;
                          raw_trace_run = None;
                        }
                    else
                      let tool_outputs =
                        List.map
                          (fun (tc : Llm_client.tool_call) ->
                            let schema =
                              tool_schema_of_name tool_schemas tc.call_name
                            in
                            let parsed_args =
                              match Yojson.Safe.from_string tc.call_arguments with
                              | json -> json
                              | exception Yojson.Json_error msg ->
                                  `Assoc
                                    [
                                      ( "error",
                                        `String
                                          ("invalid tool args: " ^ msg) );
                                    ]
                            in
                            let args =
                              parsed_args
                              |> inject_default_agent_name ~worker_name ~schema
                              |> inject_prompt_full_context ~prompt
                                   ~tool_name:tc.call_name
                            in
                            let output =
                              match
                                call_masc_tool ~sw ~auth_token
                                  ~session_id:mcp_session_id
                                  ~tool_name:tc.call_name ~args
                              with
                              | Ok result ->
                                  if result.is_error then
                                    Yojson.Safe.to_string
                                      (`Assoc
                                        [
                                          ("tool", `String tc.call_name);
                                          ("error", `String result.text);
                                        ])
                                  else result.text
                              | Error e ->
                                  Yojson.Safe.to_string
                                    (`Assoc
                                      [
                                        ("tool", `String tc.call_name);
                                        ("error", `String e);
                                      ])
                            in
                            (tc, output))
                          tool_calls
                      in
                      let round_tools =
                        List.map
                          (fun (tc : Llm_client.tool_call) -> tc.call_name)
                          tool_calls
                      in
                      let tools_used = tools_used @ round_tools in
                      let output =
                        let trimmed = String.trim resp.content in
                        if trimmed <> "" then trimmed
                        else
                          sprintf "(tools executed: %s)"
                            (String.concat ", "
                               (unique_preserve_order tools_used))
                      in
                      if round >= 3 then
                        Ok
                          {
                            output;
                            model_used = resp.model_used;
                            input_tokens = Some usage_acc.input_tokens;
                            output_tokens = Some usage_acc.output_tokens;
                            cost_usd = estimate_cost_usd model usage_acc;
                            tool_call_count = List.length tools_used;
                            tool_names = unique_preserve_order tools_used;
                            session_id = mcp_session_id;
                            raw_trace_run = None;
                          }
                      else
                        loop ~round:(round + 1) ~usage_acc ~tools_used
                          (followup_prompt ~original_prompt:prompt ~tool_outputs
                             ~already_used:tools_used)
              in
              loop ~round:1 ~usage_acc:zero_usage ~tools_used:[] prompt)

let run_worker ~sw ~base_path ~worker_name ~model ~team_session_id
    ~room_config ?working_dir ?worker_class ?worker_size ?execution_scope
    ?thinking_enabled ?max_turns ?worker_run_id ~role
    ~selection_note
    ~(prompt : string) ~(allowed_tools : string list) ~(timeout_sec : int) :
    unit -> (run_result, string) result =
  match configured_backend () with
  | `Legacy ->
      run_worker_legacy ~sw ~base_path ~worker_name ~model ~team_session_id
        ~role ~selection_note ~prompt ~allowed_tools ~timeout_sec
  | `Oas ->
      run_worker_oas ~sw ~base_path ~worker_name ~model ~team_session_id
        ~room_config ?working_dir ?worker_class ?worker_size ?execution_scope
        ?thinking_enabled ?max_turns ?worker_run_id ~role
        ~selection_note ~prompt ~allowed_tools ~timeout_sec
