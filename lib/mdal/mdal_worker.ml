open Printf

type report = {
  changes : string;
  failed_attempts : string;
  next_suggestion : string;
}

type run_result = {
  prompt : string;
  report : report;
  evidence : Mdal.worker_evidence;
  cost_usd : float option;
}

type missing_evidence = {
  prompt : string;
  raw_output : string;
  model_used : string;
  session_id : string;
  tool_call_count : int;
  tool_names : string list;
}

type run_error =
  | Worker_unavailable of string
  | Worker_failed of string
  | Evidence_missing of missing_evidence
  | Output_unparseable of string

type runner =
  config:Room.config ->
  Mdal.loop_state ->
  current_metric:float ->
  (run_result, run_error) result

let auditable_tool_catalog : string list =
  Agent_tool_surfaces.mdal_auditable_tool_names

let unique_preserve_order items =
  let rec loop seen = function
    | [] -> List.rev seen
    | x :: xs ->
        if List.mem x seen then loop seen xs else loop (x :: seen) xs
  in
  loop [] items

let trunc ?(limit = 48) text =
  if String.length text <= limit then text else String.sub text 0 limit

let worker_name_for_state (state : Mdal.loop_state) =
  let safe_loop = Room_utils.safe_filename state.loop_id |> trunc in
  sprintf "mdal-%s-%02d" safe_loop (state.current_iteration + 1)

let model_provider_label = function
  | Masc_model.Llama -> "llama"
  | Masc_model.Claude -> "claude"
  | Masc_model.OpenAI -> "openai"
  | Masc_model.Gemini -> "gemini"
  | Masc_model.Glm_cloud -> "glm"
  | Masc_model.OpenRouter -> "openrouter"
  | Masc_model.Custom name -> "custom:" ^ name

let model_label (spec : Masc_model.model_spec) =
  sprintf "%s:%s" (model_provider_label spec.provider) spec.model_id

let validate_model_spec (spec : Masc_model.model_spec) :
    (Masc_model.model_spec, string) result =
  match spec.provider with
  | Masc_model.Claude
  | Masc_model.OpenAI
  | Masc_model.Gemini
  | Masc_model.Llama
  | Masc_model.Glm_cloud -> Ok spec
  | Masc_model.OpenRouter
  | Masc_model.Custom _ ->
      Error
        (sprintf
           "MDAL strict worker does not support provider `%s`. Use claude, openai, gemini, llama:<model>, or glm."
           (model_provider_label spec.provider))

let resolve_model_spec ~(agent : string) ~(worker_model : string option) :
    (Masc_model.model_spec * string, string) result =
  let parse_worker_model raw =
    match Cascade.model_spec_of_string raw with
    | Error _ as e -> e
    | Ok spec -> (
        match validate_model_spec spec with
        | Error _ as e -> e
        | Ok valid -> Ok (valid, model_label valid))
  in
  match worker_model with
  | Some raw when String.trim raw <> "" -> parse_worker_model (String.trim raw)
  | _ ->
      let normalized = String.trim agent |> String.lowercase_ascii in
      if String.contains normalized ':' then parse_worker_model normalized
      else
        match normalized with
        | "claude" -> Ok (Masc_model.claude_opus, model_label Masc_model.claude_opus)
        | "openai" | "codex-api" ->
            Ok (Masc_model.openai_default, model_label Masc_model.openai_default)
        | "gemini" -> Ok (Masc_model.gemini_pro, model_label Masc_model.gemini_pro)
        | "ollama" ->
            Error (Provider_adapter.bare_ollama_migration_message ())
        | "glm" ->
            Ok (Masc_model.glm_cloud, model_label Masc_model.glm_cloud)
        | "llama" ->
            Error
              "MDAL strict worker requires `worker_model` for llama providers, e.g. `llama:<model-id>`."
        | "codex" ->
            Error
              "MDAL strict worker does not support `codex` yet because auditable tool-call evidence is unavailable on that runtime."
        | other ->
            Error
              (sprintf
                 "MDAL strict worker cannot resolve agent `%s`. Pass `worker_model` explicitly as provider:model."
                 other)

let resolve_allowed_tools ~(tools_allow : string list) ~(tools_deny : string list) :
    (string list, string) result =
  let requested =
    if tools_allow = [] then auditable_tool_catalog
    else
      tools_allow
      |> unique_preserve_order
      |> List.filter (fun name -> List.mem name auditable_tool_catalog)
  in
  let denied = tools_deny |> unique_preserve_order in
  let final_tools =
    requested |> List.filter (fun name -> not (List.mem name denied))
  in
  if final_tools = [] then
    Error
      "MDAL strict worker has no auditable tools left after applying tools_allow/tools_deny. Use tools from the auditable MDAL catalog such as masc_spawn, masc_code_*, masc_worktree_*, or masc_run_*."
  else
    Ok final_tools

let runtime_available ~(sw : Eio.Switch.t option) ~(config : Room.config option) =
  match sw, config with
  | Some _, Some _ -> true
  | _ -> false

let timeout_seconds (state : Mdal.loop_state) =
  match state.profile.max_time_seconds with
  | Some seconds -> max 60 (min 900 (int_of_float seconds))
  | None -> 300

let run ~(sw : Eio.Switch.t) ~(config : Room.config) (state : Mdal.loop_state)
    ~(current_metric : float) : (run_result, run_error) result =
  let model_label =
    match state.worker_model with
    | Some value when String.trim value <> "" -> String.trim value
    | _ ->
        let message =
          sprintf "Loop %s has no strict worker model configured." state.loop_id
        in
        raise (Invalid_argument message)
  in
  let model_spec =
    match Cascade.model_spec_of_string model_label with
    | Ok spec -> spec
    | Error message -> raise (Invalid_argument message)
  in
  let prompt =
    Mdal.render_worker_prompt state.profile state.history current_metric
  in
  let worker_name = worker_name_for_state state in
  match
    Local_agent_eio.run_worker ~sw ~base_path:config.Room_utils.base_path
      ~room_config:(Some config)
      ~worker_name ~model:model_spec ~team_session_id:None ~role:(Some "mdal")
      ~selection_note:(Some "strict-mdal-worker")
      ~prompt ~allowed_tools:state.profile.tools_allow
      ~timeout_sec:(timeout_seconds state) ()
  with
  | Error message -> Error (Worker_failed message)
  | Ok result ->
      if result.tool_call_count < 1 || result.tool_names = [] then
        Error
          (Evidence_missing
             {
               prompt;
               raw_output = result.output;
               model_used = result.model_used;
               session_id = result.session_id;
               tool_call_count = result.tool_call_count;
               tool_names = result.tool_names;
             })
      else
        match Mdal.parse_worker_result result.output with
        | Error message ->
            Error
              (Output_unparseable
                 (sprintf
                    "Worker output for `%s` was not parseable JSON: %s (raw=%s)"
                    model_label message
                    (String.trim result.output
                    |> fun text ->
                    if String.length text <= 240 then text
                    else String.sub text 0 240 ^ "...")))
        | Ok parsed ->
            Ok
              {
                prompt;
                report =
                  {
                    changes = parsed.changes;
                    failed_attempts = parsed.failed_attempts;
                    next_suggestion = parsed.next_suggestion;
                  };
                evidence =
                  {
                    engine = `Api_tool_loop;
                    model_used = result.model_used;
                    tool_call_count = result.tool_call_count;
                    tool_names = result.tool_names;
                    session_id = result.session_id;
                    status = `Verified;
                  };
                cost_usd = result.cost_usd;
              }
