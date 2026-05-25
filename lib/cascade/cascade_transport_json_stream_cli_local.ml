(** JSON-stream CLI completion transport, extracted from
    [cascade_transport.ml] as a top-level module (godfile decomp).

    This module was previously embedded as a nested
    [module Json_stream_cli_transport_local] inside
    [Cascade_transport] (665 LOC). Moving it to a separate file
    preserves all type identities + value bindings — the parent
    file retains a 1-line module alias
    [module Json_stream_cli_transport_local =
       Cascade_transport_json_stream_cli_local], and the
    [Cascade_transport.mli] signature constraint continues to
    apply unchanged.

    External callers reference
    [Cascade_transport.Json_stream_cli_transport_local.*] — those
    paths keep working through the alias. *)

module Runtime_policy_provider = Cascade_transport_runtime_policy_provider

type config =
  { cli_path : string
  ; process_name : string
  ; model : string option
  ; cwd : string option
  ; config_json : string option
  ; mcp_config_json : string list
  ; extra_env : (string * string) list
  ; cancel : unit Eio.Promise.t option
  ; stdout_idle_timeout_s : float option
  }

let default_config =
  { cli_path = "json-stream-cli"
  ; process_name = "json_stream_cli"
  ; model = None
  ; cwd = None
  ; config_json = None
  ; mcp_config_json = []
  ; extra_env = []
  ; cancel = None
  ; stdout_idle_timeout_s = None
  }
;;

(* Some Python CLI launchers import [setproctitle] before processing the
   request. UTF-8 prompts in argv can make setproctitle's import-time
   [getproctitle()] decode fail before the CLI reads the prompt, so keep
   non-ASCII or large prompts out of argv and stream them via stdin. *)
let default_prompt_argv_threshold = 16 * 1024

let prompt_argv_threshold () =
  match Sys.getenv_opt "MASC_JSON_STREAM_CLI_PROMPT_ARGV_THRESHOLD" with
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some value when value >= 0 -> value
     | _ -> default_prompt_argv_threshold)
  | None -> default_prompt_argv_threshold
;;

let prompt_exceeds_argv_budget prompt = String.length prompt >= prompt_argv_threshold ()

let prompt_contains_non_ascii prompt =
  let rec loop idx =
    idx < String.length prompt && (Char.code prompt.[idx] > 0x7f || loop (idx + 1))
  in
  loop 0
;;

let prompt_needs_stdin prompt =
  prompt_exceeds_argv_budget prompt || prompt_contains_non_ascii prompt
;;

let sanitize_for_cli_prompt = Inference_utils.sanitize_text_utf8

let stdin_for_prompt prompt =
  let prompt = sanitize_for_cli_prompt prompt in
  if prompt_needs_stdin prompt then Some prompt else None
;;

let cli_model_override ~(config : config) ~(req_config : Llm_provider.Provider_config.t)
  =
  match String.trim req_config.model_id |> String.lowercase_ascii with
  | "" | "auto" -> config.model
  | _ -> Some (String.trim req_config.model_id)
;;

let build_args
      ~(config : config)
      ~(req_config : Llm_provider.Provider_config.t)
      ~(mcp_config_json : string list)
      ~prompt
  =
  let prompt = sanitize_for_cli_prompt prompt in
  let prompt_via_stdin = prompt_needs_stdin prompt in
  let args = ref [ config.cli_path; "--print"; "--output-format"; "stream-json" ] in
  let add xs = args := !args @ xs in
  (match config.config_json with
   | Some json -> add [ "--config"; json ]
   | None -> ());
  if not prompt_via_stdin then add [ "-p"; prompt ];
  (match cli_model_override ~config ~req_config with
   | Some model -> add [ "--model"; model ]
   | None -> ());
  (match config.cwd with
   | Some dir when String.trim dir <> "" -> add [ "--work-dir"; dir ]
   | None | Some _ -> ());
  List.iter (fun json -> add [ "--mcp-config"; json ]) mcp_config_json;
  (match req_config.enable_thinking with
   | Some true -> add [ "--thinking" ]
   | Some false -> add [ "--no-thinking" ]
   | None -> ());
  !args
;;

let json_of_argument_string = function
  | None | Some "" -> Ok (`Assoc [])
  | Some raw ->
    let raw = String.trim raw in
    if raw = ""
    then Ok (`Assoc [])
    else (
      try Ok (Yojson.Safe.from_string raw) with
      | Yojson.Json_error msg -> Error msg)
;;

let blocks_of_message_content json =
  match json with
  | `String text when String.trim text = "" -> []
  | `String text -> [ Agent_sdk.Types.Text text ]
  | `List items -> List.filter_map Llm_provider.Api_common.content_block_of_json items
  | `Null -> []
  | other -> [ Agent_sdk.Types.Text (Yojson.Safe.to_string other) ]
;;

let tool_use_of_json json =
  let open Yojson.Safe.Util in
  try
    let fn = json |> member "function" in
    let id = Llm_provider.Cli_common_json.member_str "id" json in
    let name = Llm_provider.Cli_common_json.member_str "name" fn in
    match fn |> member "arguments" |> to_string_option |> json_of_argument_string with
    | Ok args -> Ok (Some (Agent_sdk.Types.ToolUse { id; name; input = args }))
    | Error msg ->
      Error
        (Printf.sprintf "invalid CLI tool arguments JSON for tool %S: %s" name msg)
  with
  | Type_error _ -> Ok None
;;

let tool_uses_of_json calls =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | call :: rest ->
      (match tool_use_of_json call with
       | Ok (Some block) -> loop (block :: acc) rest
       | Ok None -> loop acc rest
       | Error _ as err -> err)
  in
  loop [] calls
;;

let tool_result_of_json json =
  let open Yojson.Safe.Util in
  match json |> member "tool_call_id" |> to_string_option with
  | Some tool_use_id ->
    let content_json = json |> member "content" in
    let content, parsed_json =
      match content_json with
      | `String text -> text, Agent_sdk.Types.try_parse_json text
      | `Null -> "", None
      | other -> Yojson.Safe.to_string other, Some other
    in
    Some
      (Agent_sdk.Types.ToolResult
         { tool_use_id; content; is_error = false; json = parsed_json })
  | None -> None
;;

let parse_json_line line =
  Yojson.Safe.from_string (Inference_utils.sanitize_text_utf8 line)
;;

let blocks_of_output_line line =
  let open Yojson.Safe.Util in
  try
    let json = parse_json_line line in
    match json |> member "role" |> to_string_option with
    | Some "assistant" ->
      let content = blocks_of_message_content (json |> member "content") in
      let tool_uses_result =
        match json |> member "tool_calls" with
        | `List calls -> tool_uses_of_json calls
        | _ -> Ok []
      in
      Result.map (fun tool_uses -> content @ tool_uses) tool_uses_result
    | Some "tool" ->
      (match tool_result_of_json json with
       | Some block -> Ok [ block ]
       | None -> Ok [])
    | _ -> Ok []
  with
  | Yojson.Json_error _ | Type_error _ -> Ok []
;;

let response_id_of_lines lines =
  let open Yojson.Safe.Util in
  let find_id line =
    try
      let json = parse_json_line line in
      match json |> member "id" |> to_string_option with
      | Some id when String.trim id <> "" -> Some id
      | _ ->
        (match json |> member "session_id" |> to_string_option with
         | Some id when String.trim id <> "" -> Some id
         | _ -> None)
    with
    | Yojson.Json_error _ | Type_error _ -> None
  in
  List.find_map find_id lines |> Option.value ~default:"cli-json-stream"
;;

let response_model_of_lines ~model_id lines =
  let open Yojson.Safe.Util in
  let find_model line =
    try
      let json = parse_json_line line in
      match json |> member "model" |> to_string_option with
      | Some model when String.trim model <> "" -> Some model
      | _ -> None
    with
    | Yojson.Json_error _ | Type_error _ -> None
  in
  List.find_map find_model lines |> Option.value ~default:model_id
;;

let parse_jsonl_result ~model_id lines =
  let content_result =
    let rec loop acc = function
      | [] -> Ok (List.concat (List.rev acc))
      | line :: rest ->
        (match blocks_of_output_line line with
         | Ok blocks -> loop (blocks :: acc) rest
         | Error _ as err -> err)
    in
    loop [] lines
  in
  match content_result with
  | Error message ->
    Error (Llm_provider.Http_client.NetworkError { message; kind = Unknown })
  | Ok [] ->
    Error
      (Llm_provider.Http_client.NetworkError
         { message = "no messages parsed from CLI JSON-stream output"; kind = Unknown })
  | Ok content ->
    Ok
      { Agent_sdk.Types.id = response_id_of_lines lines
      ; model = response_model_of_lines ~model_id lines
      ; stop_reason = Agent_sdk.Types.EndTurn
      ; content
      ; usage = None
      ; telemetry = None
      }
;;

let events_of_block ~index = function
  | Agent_sdk.Types.Text text ->
    [ Agent_sdk.Types.ContentBlockStart
        { index; content_type = "text"; tool_id = None; tool_name = None }
    ; Agent_sdk.Types.ContentBlockDelta
        { index; delta = Agent_sdk.Types.TextDelta text }
    ; Agent_sdk.Types.ContentBlockStop { index }
    ]
  | Agent_sdk.Types.Thinking { content; _ } ->
    [ Agent_sdk.Types.ContentBlockStart
        { index; content_type = "thinking"; tool_id = None; tool_name = None }
    ; Agent_sdk.Types.ContentBlockDelta
        { index; delta = Agent_sdk.Types.ThinkingDelta content }
    ; Agent_sdk.Types.ContentBlockStop { index }
    ]
  | Agent_sdk.Types.ToolUse { id; name; input } ->
    [ Agent_sdk.Types.ContentBlockStart
        { index; content_type = "tool_use"; tool_id = Some id; tool_name = Some name }
    ; Agent_sdk.Types.ContentBlockDelta
        { index; delta = Agent_sdk.Types.InputJsonDelta (Yojson.Safe.to_string input) }
    ; Agent_sdk.Types.ContentBlockStop { index }
    ]
  | Agent_sdk.Types.ToolResult { tool_use_id; content; _ } ->
    [ Agent_sdk.Types.ContentBlockStart
        { index
        ; content_type = "tool_result"
        ; tool_id = Some tool_use_id
        ; tool_name = None
        }
    ; Agent_sdk.Types.ContentBlockDelta
        { index; delta = Agent_sdk.Types.TextDelta content }
    ; Agent_sdk.Types.ContentBlockStop { index }
    ]
  | Agent_sdk.Types.RedactedThinking _
  | Agent_sdk.Types.Image _
  | Agent_sdk.Types.Document _
  | Agent_sdk.Types.Audio _ -> []
;;

let emit_blocks ~on_event ~start_index blocks =
  List.fold_left
    (fun index block ->
       match events_of_block ~index block with
       | [] -> index
       | events ->
         List.iter on_event events;
         index + 1)
    start_index
    blocks
;;

let resumable_session_detail =
  "CLI JSON-stream transport reported a resumable session. Resumable session \
   available via -r."
;;

let resume_hint_marker = "to resume this session:"
let resumable_session_public_marker = "resumable session available via -r."

let is_resume_hint_line line =
  let trimmed = String.trim line in
  trimmed <> "" && String_util.contains_substring_ci trimmed resume_hint_marker
;;

let should_log_stderr_line line =
  let trimmed = String.trim line in
  trimmed <> "" && not (is_resume_hint_line trimmed)
;;

let on_stderr_line ~process_name line =
  if should_log_stderr_line line
  then
    Llm_provider.Cli_common_subprocess.default_on_stderr_line ~name:process_name line
;;

let index_of_substring text marker =
  let marker_len = String.length marker in
  let text_len = String.length text in
  let rec loop idx =
    if marker_len = 0
    then Some idx
    else if idx + marker_len > text_len
    then None
    else if String.sub text idx marker_len = marker
    then Some idx
    else loop (idx + 1)
  in
  loop 0
;;

let exit_code_span_of_message message =
  let marker = " exited with code " in
  match index_of_substring message marker with
  | None -> None
  | Some marker_start ->
    let code_start = marker_start + String.length marker in
    (match String.index_from_opt message code_start ':' with
     | None -> None
     | Some colon ->
       let raw = String.sub message code_start (colon - code_start) |> String.trim in
       Option.map (fun code -> code, colon) (int_of_string_opt raw))
;;

let exit_code_of_message message =
  Option.map fst (exit_code_span_of_message message)
;;

let exit_code_marker_of_text text =
  let marker = "(exit " in
  let lower = String.lowercase_ascii text in
  let marker_len = String.length marker in
  let text_len = String.length lower in
  let rec find_marker index =
    if index + marker_len > text_len
    then None
    else if String.sub lower index marker_len = marker
    then (
      let number_start = index + marker_len in
      match String.index_from_opt lower number_start ')' with
      | Some number_end when number_end > number_start ->
        String.sub lower number_start (number_end - number_start)
        |> String.trim
        |> int_of_string_opt
      | _ -> None)
    else find_marker (index + 1)
  in
  find_marker 0
;;

let exit_payload_of_message message =
  match exit_code_span_of_message message with
  | None -> None
  | Some (_, colon) ->
    Some
      (String.sub message (colon + 1) (String.length message - colon - 1)
       |> String.trim)
;;

let payload_has_only_resume_hint payload =
  payload
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
  |> fun lines -> lines <> [] && List.for_all is_resume_hint_line lines
;;

let text_looks_like_resumable_session text =
  let trimmed = String.trim text in
  let has_raw_resume_hint =
    match exit_code_of_message trimmed with
    | Some 75 -> is_resume_hint_line trimmed
    | Some 1 ->
      (match exit_payload_of_message trimmed with
       | Some payload -> payload_has_only_resume_hint payload
       | None -> false)
    | _ -> false
  in
  trimmed <> ""
  && (has_raw_resume_hint
      || String_util.contains_substring_ci trimmed resumable_session_public_marker)
;;

let resumable_session_detail_of_text text =
  if text_looks_like_resumable_session text
  then (
    let trimmed = String.trim text in
    match
      match exit_code_of_message trimmed with
      | Some code -> Some code
      | None -> exit_code_marker_of_text trimmed
    with
    | Some code ->
      Printf.sprintf
        "CLI JSON-stream transport reported a resumable session (exit %d). \
         Resumable session available via -r."
        code
    | None -> resumable_session_detail)
  else String.trim text
;;

let resumable_session_exit_code_of_text text =
  match exit_code_of_message text with
  | Some (75 as code) -> Some code
  | Some (1 as code) when text_looks_like_resumable_session text -> Some code
  | _ when text_looks_like_resumable_session text -> exit_code_marker_of_text text
  | _ -> None
;;

let text_looks_like_process_title_unicode_crash text =
  String_util.contains_substring_ci text "UnicodeDecodeError"
  && String_util.contains_substring_ci text "setproctitle"
;;

let classify_cli_error = function
  | Error (Llm_provider.Http_client.NetworkError { message; _ }) as err ->
    if text_looks_like_resumable_session message
    then
      Error
        (Llm_provider.Http_client.AcceptRejected
           { reason = resumable_session_detail_of_text message })
    else if text_looks_like_process_title_unicode_crash message
    then
      Error
        (Llm_provider.Http_client.AcceptRejected
           { reason =
               "provider CLI startup crash while setting process title \
                (UnicodeDecodeError). This is a local CLI/runtime failure, not keeper \
                auth or sandbox failure; rejecting without retry so the cascade can \
                move on. "
               ^ message
           })
    else (
      match exit_code_of_message message with
      | Some 1 ->
        Error
          (Llm_provider.Http_client.AcceptRejected
             { reason =
                 "provider CLI rejected the request (exit 1). "
                 ^ "This is usually a permanent auth/config/model error rather "
                 ^ "than a transient transport failure. "
                 ^ message
             })
      | Some 75 ->
        Error
          (Llm_provider.Http_client.AcceptRejected
             { reason = resumable_session_detail_of_text message })
      | _ -> err)
  | other -> other
;;

let warn_external_tools_once warned tools =
  if !warned || tools = []
  then ()
  else (
    warned := true;
    Log.Misc.warn
      "CLI JSON-stream print mode ignores OAS req.tools. Provider-native built-in tools and \
       configured MCP servers remain available; external OAS tool callbacks require a \
       future wire-mode transport.")
;;

let create ~sw ~(mgr : _ Eio.Process.mgr) ~(config : config) =
  let warned = ref false in
  { Llm_provider.Llm_transport.complete_sync =
      (fun (req : Llm_provider.Llm_transport.completion_request) ->
        warn_external_tools_once warned req.tools;
        let messages =
          Llm_provider.Cli_common_prompt.non_system_messages req.messages
        in
        let system_prompt =
          Llm_provider.Cli_common_prompt.system_prompt_of
            ~req_config:req.config
            req.messages
        in
        let prompt =
          Llm_provider.Cli_common_prompt.prompt_of_messages
            ~include_tool_blocks:true
            messages
          |> fun prompt ->
          Llm_provider.Cli_common_prompt.prompt_with_system_prompt
            ~prompt
            ~system_prompt
        in
        let prompt = sanitize_for_cli_prompt prompt in
        let model_id =
          match cli_model_override ~config ~req_config:req.config with
          | Some model -> model
          | None -> req.config.model_id
        in
        let mcp_config_json =
          Runtime_policy_provider.cli_runtime_mcp_jsons ~base:config.mcp_config_json req.runtime_mcp_policy
        in
        let argv = build_args ~config ~req_config:req.config ~mcp_config_json ~prompt in
        let seen_lines = ref [] in
        let on_line line =
          if String.trim line <> "" then seen_lines := line :: !seen_lines
        in
        let stdout_idle_timeout_s = config.stdout_idle_timeout_s in
        let clock_opt =
          match stdout_idle_timeout_s with
          | None -> None
          | Some _ ->
            (match Process_eio.get_clock () with
             | Ok c -> Some c
             | Error _ -> None)
        in
        let run_result, measured_latency_ms =
          Inference_utils.timed (fun () ->
            Llm_provider.Cli_common_subprocess.run_stream_lines
              ~sw
              ~mgr
              ?clock:clock_opt
              ?stdout_idle_timeout_s
              ~name:config.process_name
              ~cwd:config.cwd
              ~extra_env:config.extra_env
              ~on_stderr_line:(on_stderr_line ~process_name:config.process_name)
              ?stdin_content:(stdin_for_prompt prompt)
              ~on_line
              ?cancel:config.cancel
              argv)
        in
        match run_result with
        | Error _ as err ->
          { Llm_provider.Llm_transport.response = classify_cli_error err
          ; latency_ms = Some measured_latency_ms
          }
        | Ok { latency_ms; _ } ->
          let response = parse_jsonl_result ~model_id (List.rev !seen_lines) in
          { Llm_provider.Llm_transport.response; latency_ms = Some latency_ms })
  ; complete_stream =
      (fun ?on_telemetry:_
        ~on_event
        (req : Llm_provider.Llm_transport.completion_request) ->
        warn_external_tools_once warned req.tools;
        let messages =
          Llm_provider.Cli_common_prompt.non_system_messages req.messages
        in
        let system_prompt =
          Llm_provider.Cli_common_prompt.system_prompt_of
            ~req_config:req.config
            req.messages
        in
        let prompt =
          Llm_provider.Cli_common_prompt.prompt_of_messages
            ~include_tool_blocks:true
            messages
          |> fun prompt ->
          Llm_provider.Cli_common_prompt.prompt_with_system_prompt
            ~prompt
            ~system_prompt
        in
        let prompt = sanitize_for_cli_prompt prompt in
        let model_id =
          match cli_model_override ~config ~req_config:req.config with
          | Some model -> model
          | None -> req.config.model_id
        in
        let mcp_config_json =
          Runtime_policy_provider.cli_runtime_mcp_jsons ~base:config.mcp_config_json req.runtime_mcp_policy
        in
        let argv = build_args ~config ~req_config:req.config ~mcp_config_json ~prompt in
        let seen_lines = ref [] in
        let next_index = ref 0 in
        let started = ref false in
        let parse_error = ref None in
        let ensure_started () =
          if not !started
          then (
            started := true;
            on_event
              (Agent_sdk.Types.MessageStart
                 { id = "cli-json-stream"; model = model_id; usage = None }))
        in
        let on_line line =
          match !parse_error with
          | Some _ -> ()
          | None ->
            if String.trim line <> ""
            then (
              seen_lines := line :: !seen_lines;
              match blocks_of_output_line line with
              | Error message -> parse_error := Some message
              | Ok blocks ->
                if blocks <> []
                then (
                  ensure_started ();
                  next_index := emit_blocks ~on_event ~start_index:!next_index blocks))
        in
        let stdout_idle_timeout_s = config.stdout_idle_timeout_s in
        let clock_opt =
          match stdout_idle_timeout_s with
          | None -> None
          | Some _ ->
            (match Process_eio.get_clock () with
             | Ok c -> Some c
             | Error _ -> None)
        in
        match
          classify_cli_error
            (Llm_provider.Cli_common_subprocess.run_stream_lines
               ~sw
               ~mgr
               ?clock:clock_opt
               ?stdout_idle_timeout_s
               ~name:config.process_name
               ~cwd:config.cwd
               ~extra_env:config.extra_env
               ~on_stderr_line:(on_stderr_line ~process_name:config.process_name)
               ?stdin_content:(stdin_for_prompt prompt)
               ~on_line
               ?cancel:config.cancel
               argv)
        with
        | Error _ as err -> err
        | Ok _ ->
          (match !parse_error with
           | Some message ->
             Error (Llm_provider.Http_client.NetworkError { message; kind = Unknown })
           | None ->
             (match parse_jsonl_result ~model_id (List.rev !seen_lines) with
              | Error _ as err -> err
              | Ok resp as ok ->
                if !started
                then (
                  on_event
                    (Agent_sdk.Types.MessageDelta
                       { stop_reason = Some resp.stop_reason; usage = resp.usage });
                  on_event Agent_sdk.Types.MessageStop)
                else Llm_provider.Cli_common_synthetic_events.replay ~on_event resp;
                ok)))
  }
;;
