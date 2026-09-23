open Alcotest
open Masc

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let auth_subscription =
  {|{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","apiProvider":"firstParty"}|}
;;

let assistant ~turn_id text =
  Printf.sprintf
    {|{"type":"assistant","session_id":"__SESSION__","uuid":"assistant-%s","message":{"role":"assistant","model":"claude-fixture","content":[{"type":"text","text":%S}]}}|}
    turn_id
    text
;;

let result ~turn_id text =
  Printf.sprintf
    {|{"type":"result","subtype":"success","is_error":false,"session_id":"__SESSION__","uuid":%S,"result":%S,"api_error_status":null}|}
    turn_id
    text
;;

let rate_limit_rejected =
  {|{"type":"rate_limit_event","session_id":"__SESSION__","uuid":"limit-1","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day","resetsAt":1786356000,"overageStatus":"rejected","overageDisabledReason":"org_level_disabled_until"}}|}
;;

let quota_result =
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-quota-1","result":"not inspected","api_error_status":429,"terminal_reason":"api_error"}|}
;;

let generic_provider_rejection =
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-rejected-1","result":"API Error: Sonnet safeguards flagged this message","api_error_status":null}|}
;;

let prompt_too_long_result =
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-overflow-1","result":"Prompt is too long · the request is ~250000 tokens (limit 200000)","api_error_status":400,"terminal_reason":"prompt_too_long"}|}
;;

(* CLI 2.1.278 refuses to send when its count reaches the window minus 3000:
   it emits a synthetic API-error assistant message and ends the loop with
   [terminal_reason = "blocking_limit"] and no API status. Seen live on
   2026-09-19 as "terminal subtype=success api_status=unknown
   reason=blocking_limit: Prompt is too long". *)
let blocking_limit_diagnostic =
  {|{"type":"assistant","session_id":"__SESSION__","uuid":"assistant-blocking-limit-1","is_api_error_message":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Prompt is too long"}]}}|}
;;

let blocking_limit_result =
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-blocking-limit-1","result":"Prompt is too long","terminal_reason":"blocking_limit"}|}
;;

(* The same CLI context_limit stop cause, with a different diagnostic. The
   typed terminal reason, not either sentence, selects the shrink path. *)
let rapid_refill_breaker_diagnostic =
  {|{"type":"assistant","session_id":"__SESSION__","uuid":"assistant-rapid-refill-1","is_api_error_message":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Autocompact is thrashing"}]}}|}
;;

let rapid_refill_breaker_result =
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-rapid-refill-1","result":"Autocompact is thrashing","terminal_reason":"rapid_refill_breaker"}|}
;;

let mcp_initialize =
  {|{"type":"control_request","request_id":"mcp-init-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code-fixture","version":"1"}}}}}|}
;;

let mcp_initialized_notification =
  {|{"type":"control_request","request_id":"mcp-notify-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}}}|}
;;

let mcp_list =
  {|{"type":"control_request","request_id":"mcp-list-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}}}|}
;;

let mcp_call_with_id id =
  Printf.sprintf
    {|{"type":"control_request","request_id":"mcp-call-%s","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":"call-%s","method":"tools/call","params":{"name":"masc_probe","arguments":{"marker":"from-claude"}}}}}|}
    id
    id
;;

let mcp_call = mcp_call_with_id "1"

let native_tool_call_block ~turn_id ~call_id ~tool_name =
  Printf.sprintf
    {|{"type":"assistant","session_id":"__SESSION__","uuid":"assistant-%s","message":{"role":"assistant","model":"claude-fixture","content":[{"type":"tool_use","id":"%s","name":"%s"}]}}|}
    turn_id
    call_id
    tool_name
;;

let native_tool_result ~call_id ~content =
  Printf.sprintf
    {|{"type":"user","session_id":"__SESSION__","uuid":"user-native-result-1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":%S}]}}|}
    call_id
    content
;;

type fixture_step =
  | Emit of string
  | Emit_and_read of string
  | Close_transport

let fixture_script ?system_marker ?prompt_marker ?(remove_after_auth = false) ?(forbid_mcp = false)
    lines =
  let path = Filename.temp_file "masc-keeper-claude-code-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output "set -eu\n";
  (* The client puts its flags ahead of the subcommand, so the probe arrives
     as `--setting-sources=<layers> auth status --json`. Matching the
     subcommand pair anywhere in argv keeps this fixture answering the probe
     when a flag is added or moved; pinning a position sends the probe into
     the turn body instead, which answers it with turn output and reports
     nothing. *)
  output_string output "case \" $* \" in *\" auth status \"*)\n";
  output_string output ("  printf '%s\\n' " ^ shell_quote auth_subscription ^ "\n");
  if remove_after_auth
  then output_string output "  rm -- \"$0\"\n";
  output_string output "  exit 0\n";
  output_string output "  ;;\nesac\n";
  Option.iter (fun marker ->
    output_string output ("previous_arg=''\nfor arg in \"$@\"; do\n" ^
      "  if [ \"$previous_arg\" = '--system-prompt-file' ]; then cat -- \"$arg\" > " ^
      shell_quote marker ^ "; printf '%s' \"$arg\" > " ^ shell_quote (marker ^ ".path") ^
      "; fi\n  previous_arg=$arg\ndone\n")) system_marker;
  output_string output "session=''\n";
  output_string output "for arg in \"$@\"; do\n";
  output_string output "  case \"$arg\" in\n";
  output_string output "    --session-id=*) session=${arg#--session-id=} ;;\n";
  output_string output "    --resume=*) session=${arg#--resume=} ;;\n";
  if forbid_mcp
  then
    output_string output
      "    --mcp-config|--strict-mcp-config|--allowedTools) exit 98 ;;\n";
  output_string output "  esac\n";
  output_string output "done\n";
  output_string output "[ -n \"$session\" ] || exit 94\n";
  output_string output
    "emit() { printf '%s\\n' \"$1\" | sed \"s/__SESSION__/$session/g\"; }\n";
  output_string output "IFS= read -r initialize\n";
  output_string output
    "request_id=$(printf '%s' \"$initialize\" | sed -n 's/.*\"request_id\":\"\\([^\"]*\\)\".*/\\1/p')\n";
  output_string output "[ -n \"$request_id\" ] || exit 95\n";
  output_string output
    "printf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"%s\",\"response\":{}}}\\n' \"$request_id\"\n";
  output_string output "IFS= read -r user_message\n";
  Option.iter
    (fun marker ->
      output_string output
        ("printf '%s\\n' \"$user_message\" > " ^ shell_quote marker ^ "\n"))
    prompt_marker;
  List.iter
    (function
      | Emit line -> output_string output ("emit " ^ shell_quote line ^ "\n")
      | Emit_and_read line ->
        output_string output ("emit " ^ shell_quote line ^ "\n");
        output_string output "IFS= read -r ignored_response\n"
      | Close_transport -> output_string output "exit 0\n")
    lines;
  output_string output "while IFS= read -r ignored; do :; done\n";
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture ?system_marker ?prompt_marker ?remove_after_auth ?forbid_mcp lines f =
  let path = fixture_script ?system_marker ?prompt_marker ?remove_after_auth ?forbid_mcp lines in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

let with_fixture_sequence
    ?first_system_marker
    ?second_system_marker
    ?first_prompt_marker
    ?second_prompt_marker
    first_lines
    second_lines
    f =
  let first_path = fixture_script ?system_marker:first_system_marker ?prompt_marker:first_prompt_marker first_lines in
  let second_path = fixture_script ?system_marker:second_system_marker ?prompt_marker:second_prompt_marker second_lines in
  let counter_path = Filename.temp_file "masc-keeper-claude-sequence-" ".txt" in
  Sys.remove counter_path;
  let path = Filename.temp_file "masc-keeper-claude-sequence-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output "set -eu\n";
  output_string output "case \" $* \" in *\" auth status \"*)\n";
  output_string output ("  printf '%s\\n' " ^ shell_quote auth_subscription ^ "\n");
  output_string output "  exit 0\n";
  output_string output "  ;;\nesac\n";
  output_string output "count=0\n";
  output_string output
    ("if [ -f " ^ shell_quote counter_path ^ " ]; then\n"
     ^ "  IFS= read -r count < " ^ shell_quote counter_path ^ "\n"
     ^ "fi\n");
  output_string output "count=$((count + 1))\n";
  output_string output
    ("printf '%s\\n' \"$count\" > " ^ shell_quote counter_path ^ "\n");
  output_string output
    ("if [ \"$count\" -eq 1 ]; then\n"
     ^ "  exec " ^ shell_quote first_path ^ " \"$@\"\n"
     ^ "else\n"
     ^ "  exec " ^ shell_quote second_path ^ " \"$@\"\n"
     ^ "fi\n");
  close_out output;
  Unix.chmod path 0o700;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun candidate ->
           if Sys.file_exists candidate then Sys.remove candidate)
        [ path; first_path; second_path; counter_path ])
    (fun () -> f path)
;;

let runtime_toml ?(tools_support = true) cli_path =
  Printf.sprintf
    "[providers.claude]\n\
     protocol = \"claude-code\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [models.claude]\n\
     api-name = \"claude-fixture\"\n\
     max-context = 200000\n\
     tools-support = %b\n\
     \n\
     [claude.claude]\n\
     \n\
     [runtime]\n\
     default = \"claude.claude\"\n"
    cli_path
    tools_support
;;

let with_runtime_config ?tools_support cli_path f =
  let path = Filename.temp_file "masc-keeper-claude-runtime-" ".toml" in
  let output = open_out_bin path in
  output_string output (runtime_toml ?tools_support cli_path);
  close_out output;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let temp_workspace () =
  let path = Filename.temp_file "masc-keeper-claude-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let keeper_response_text (result : Runtime_agent.run_result) =
  result.response.content
  |> List.filter_map (function Agent_core.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let message role text : Agent_core.Types.message =
  { role; content = [ Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

(* [Runtime_claude_code.user_message] always sends a content-block array —
   "never the bare-string form", as its own comment puts it — so the text a
   turn carries is the text block inside that array, not the member itself.
   Reading the member as a string was right until #30567 gave the array an
   image block to hold in front of the text. Images are dropped here on
   purpose: every caller of this helper asks what prompt text went out. *)
let content_of_wire_message raw =
  Yojson.Safe.from_string raw
  |> Yojson.Safe.Util.member "message"
  |> Yojson.Safe.Util.member "content"
  |> Yojson.Safe.Util.to_list
  |> List.filter_map (fun block ->
       match Yojson.Safe.Util.member "type" block with
       | `String "text" -> Some (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "text" block))
       | _ -> None)
  |> String.concat ""
;;

let run_keeper_turn ?(tools = []) ?(tools_support = true) ?(initial_messages = []) ?event_bus
    ?event_capture ?on_event ?agent_core_checkpoint ?runtime_manifest_context
    ?runtime_manifest_append ?raw_trace ?on_official_client_native_action
    ?(system_prompt = "pre-dispatch fixture system prompt")
    ?on_request_attribution ?official_client_continuation ~base_path ~cli_path ~goal () =
  Masc_test_deps.declare_fixture_keeper
    ~base_path ~sandbox_profile:None "claude-fixture";
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config ~tools_support cli_path (fun runtime_path ->
         Eio_main.run (fun env ->
           Eio.Switch.run (fun sw ->
             Eio_context.set_env env;
             Eio_context.with_test_env
               ~net:(Eio.Stdenv.net env)
               ~clock:(Eio.Stdenv.clock env)
               ~mono_clock:(Eio.Stdenv.mono_clock env)
               ~sw
               (fun () ->
                  match Runtime.init_default ~config_path:runtime_path with
                  | Error error -> fail error
                  | Ok () ->
                    let context =
                      match tools with
                      | [] -> None
                      | _ :: _ -> Some (Agent_core.Context.create ())
                    in
                    let run () =
                      Result.map
                        (fun selected -> selected.Keeper_turn_driver.run_result)
                        (Keeper_turn_driver.run_named
                           ~runtime_id:"claude.claude"
                           ~keeper_name:"claude-fixture"
                           ~base_path
                           ~goal
                           ~system_prompt
                           ~tools
                           ~agent_core_tools:tools
                           ~initial_messages
                           ?context
                           ?event_bus
                           ?on_event
                           ?agent_core_checkpoint
                           ?runtime_manifest_context
                           ?runtime_manifest_append
                           ?raw_trace
                           ?on_official_client_native_action
                           ?on_request_attribution
                           ?official_client_continuation
                           ~sw
                           ~net:(Eio.Stdenv.net env)
                           ())
                    in
                    (match event_bus, event_capture with
                     | Some bus, Some capture ->
                       let subscription =
                         Runtime_event_bus.subscribe
                           ~capacity:16
                           ~overflow:Agent_core.Event_bus.Drop_oldest
                           ~purpose:"claude-code-lifecycle-test"
                           bus
                       in
                       Fun.protect
                         ~finally:(fun () ->
                           Runtime_event_bus.unsubscribe bus subscription)
                         (fun () ->
                            let result = run () in
                            capture := Runtime_event_bus.drain subscription;
                            result)
                     | _, None -> run ()
                     | None, Some _ ->
                       invalid_arg "event_capture requires event_bus"))))))
;;

let check_usage_scope ~frames ~expected_scope ~input_tokens ~output_tokens
    ~cache_read_input_tokens () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture frames (fun cli_path ->
         match run_keeper_turn ~base_path ~cli_path ~goal:"USAGE_SCOPE" () with
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok turn ->
           (match turn.response.usage with
            | None -> fail "known CLI usage was dropped"
            | Some usage ->
              check int "inclusive input preserved" input_tokens usage.input_tokens;
              check int "output preserved" output_tokens usage.output_tokens;
              check int "cache read preserved" cache_read_input_tokens
                usage.cache_read_input_tokens;
              check int "absent cache creation remains zero" 0
                usage.cache_creation_input_tokens);
           (match turn.runtime_observation with
            | None -> fail "runtime observation was dropped"
            | Some observation ->
              check string "scope follows the usage producer" expected_scope
                (Runtime_usage_scope.to_string observation.usage_scope))))
;;

let result_with_aggregate_usage =
  {|{"type":"result","subtype":"success","is_error":false,"session_id":"__SESSION__","uuid":"turn-usage","result":"USAGE_OK","api_error_status":null,"usage":{"input_tokens":123456,"output_tokens":789,"cache_read_input_tokens":42}}|}
;;

let test_result_only_usage_keeps_client_turn_scope () =
  check_usage_scope
    ~frames:
      [ Emit (assistant ~turn_id:"usage" "USAGE_OK")
      ; Emit result_with_aggregate_usage
      ]
    ~expected_scope:"turn_total"
    ~input_tokens:123498 ~output_tokens:789 ~cache_read_input_tokens:42 ()
;;

let test_latest_request_usage_outranks_client_turn_total () =
  let counted_assistant =
    {|{"type":"assistant","session_id":"__SESSION__","uuid":"assistant-counted","message":{"id":"msg-counted","role":"assistant","model":"claude-fixture","content":[{"type":"text","text":"USAGE_OK"}],"usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":5}}}|}
  in
  check_usage_scope
    ~frames:
      [ Emit counted_assistant
      ; Emit (assistant ~turn_id:"uncounted" "USAGE_OK")
      ; Emit result_with_aggregate_usage
      ]
    ~expected_scope:"per_request"
    ~input_tokens:205 ~output_tokens:20 ~cache_read_input_tokens:5 ()
;;

let checkpoint_with_messages
      (messages : Agent_core.Types.message list)
  : Agent_core.Checkpoint.t
  =
  { version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = "agent_core-session"
  ; agent_name = "agent_core-agent"
  ; model = "agent_core-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count = 1
  ; created_at = 1.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Off
  ; reasoning_effort = None
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create ()
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let test_agent_core_checkpoint_starts_official_client_turn () =
  let base_path = temp_workspace () in
  let prompt_marker = Filename.concat base_path "checkpoint-prompt.json" in
  let manifests = ref [] in
  let checkpoint_history : Agent_core.Types.message list =
    [ { role = Assistant
      ; content =
          [ ToolUse
              { id = "agent_core-tool-call"
              ; name = "agent_core_tool"
              ; input = `Assoc []
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; Agent_core.Types.tool_result_msg
        ~tool_use_id:"agent_core-tool-call"
        ~content:"agent_core tool result"
        ()
    ]
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         ~prompt_marker
         [ Emit (assistant ~turn_id:"turn-checkpoint-1" "MASC_CLAUDE_CHECKPOINT")
         ; Emit (result ~turn_id:"turn-checkpoint-1" "MASC_CLAUDE_CHECKPOINT")
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~initial_messages:checkpoint_history
                ~agent_core_checkpoint:(checkpoint_with_messages checkpoint_history)
                ~runtime_manifest_context:
                  { Keeper_runtime_manifest.manifest_keeper_name =
                      "claude-fixture"
                  ; manifest_trace_id = "claude-fixture-trace"
                  ; manifest_keeper_turn_id = Some 1
                  }
                ~runtime_manifest_append:(fun manifest ->
                  manifests := manifest :: !manifests)
                ~base_path
                ~cli_path
                ~goal:"CHECKPOINT_GOAL"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok turn ->
              check string
                "checkpoint response"
                "MASC_CLAUDE_CHECKPOINT"
                (keeper_response_text turn));
       let input = open_in_bin prompt_marker in
       let raw =
         Fun.protect ~finally:(fun () -> close_in input) (fun () -> input_line input)
       in
       let projected =
         content_of_wire_message raw |> Yojson.Safe.from_string
       in
       let open Yojson.Safe.Util in
       check string
         "typed initial-turn schema"
         "masc.claude-code.initial-turn.v1"
         (projected |> member "schema" |> to_string);
       check string
         "current goal"
         "CHECKPOINT_GOAL"
         (projected |> member "current_goal" |> to_string);
       check int
         "canonical history length"
         2
         (projected |> member "history" |> to_list |> List.length);
       let routed_rows_with_status status =
         List.filter
           (fun (manifest : Keeper_runtime_manifest.t) ->
             manifest.event = Keeper_runtime_manifest.Runtime_routed
             && String.equal manifest.status status)
           !manifests
       in
       (match routed_rows_with_status "fresh_session" with
        | [] -> ()
        | _ :: _ ->
          fail "the retired fresh_session manifest row must not reappear");
       match routed_rows_with_status "checkpoint_not_replayed" with
       | [ manifest ] ->
         let decision =
           Keeper_runtime_manifest.public_projection_of_decision
             manifest.decision
         in
         check string
           "checkpoint routing action"
           "official_client_checkpoint_not_replayed"
           (decision |> member "routing_action" |> to_string);
         check string
           "checkpoint routing reason"
           "official_client_session_store_owns_resume"
           (decision |> member "routing_reason" |> to_string)
       | [] -> fail "checkpoint_not_replayed manifest row was not observable"
       | _ :: _ :: _ -> fail "expected exactly one checkpoint_not_replayed row")
;;

let test_keeper_projects_typed_tool_history_and_lifecycle () =
  let base_path = temp_workspace () in
  let prompt_marker = Filename.concat base_path "typed-history-prompt.json" in
  let bus = Agent_core.Event_bus.create () in
  let captured_events = ref [] in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let tool_use : Agent_core.Types.message =
         { role = Assistant
         ; content =
             [ ToolUse
                 { id = "prior-tool-call"
                 ; name = "prior_tool"
                 ; input = `Assoc [ "path", `String "README.md" ]
                 }
             ]
         ; name = None
         ; tool_call_id = None
         ; metadata = []
         }
       in
       let tool_result =
         Agent_core.Types.tool_result_msg
           ~tool_use_id:"prior-tool-call"
           ~content:"prior result"
           ()
       in
       with_fixture
         ~prompt_marker
         [ Emit (assistant ~turn_id:"turn-history-1" "MASC_CLAUDE_HISTORY")
         ; Emit (result ~turn_id:"turn-history-1" "MASC_CLAUDE_HISTORY")
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~initial_messages:[ tool_use; tool_result ]
                ~event_bus:bus
                ~event_capture:captured_events
                ~base_path
                ~cli_path
                ~goal:"CURRENT_GOAL"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok turn ->
              check string
                "history response"
                "MASC_CLAUDE_HISTORY"
                (keeper_response_text turn));
       let input = open_in_bin prompt_marker in
       let raw =
         Fun.protect ~finally:(fun () -> close_in input) (fun () -> input_line input)
       in
       let history =
         content_of_wire_message raw
         |> Yojson.Safe.from_string
         |> Yojson.Safe.Util.member "history"
         |> Yojson.Safe.Util.to_list
       in
       (match history with
        | [ assistant_history; tool_history ] ->
          let envelope_message value =
            let open Yojson.Safe.Util in
            check string
              "history envelope schema"
              Keeper_official_client_context_codec.schema
              (value |> member "schema" |> to_string);
            value |> member "message"
          in
          let assistant_history = envelope_message assistant_history in
          let tool_history = envelope_message tool_history in
          check string
            "assistant history role"
            "assistant"
            Yojson.Safe.Util.(assistant_history |> member "role" |> to_string);
          let tool_use_block =
            Yojson.Safe.Util.(assistant_history |> member "content_blocks" |> to_list)
            |> List.hd
          in
          check string
            "typed tool use"
            "tool_use"
            Yojson.Safe.Util.(tool_use_block |> member "type" |> to_string);
          check string
            "tool result history role"
            "tool"
            Yojson.Safe.Util.(tool_history |> member "role" |> to_string)
        | _ -> fail "typed history projection did not preserve the tool cycle");
       let lifecycle_kinds =
         !captured_events
         |> List.map (fun event ->
           Agent_core.Event_bus.payload_kind event.Agent_core.Event_bus.payload)
       in
       check
         (list string)
         "official-client lifecycle"
         [ "agent_started"; "agent_completed" ]
         lifecycle_kinds)
;;

let test_keeper_projects_masc_tool () =
  let base_path = temp_workspace () in
  let raw_trace_path = Filename.concat base_path "claude-raw-trace.jsonl" in
  let raw_trace =
    Agent_core.Raw_trace.create ~path:raw_trace_path ()
    |> Result.map_error (fun error -> fail (Agent_core.Error.to_string error))
    |> Result.get_ok
  in
  let observed = ref `Null in
  let marker_param : Agent_core.Types.tool_param =
    { name = "marker"
    ; description = "Fixture marker"
    ; param_type = String
    ; required = true
    }
  in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic fixture marker"
      ~parameters:[ marker_param ]
      (fun input ->
        observed := input;
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit_and_read mcp_initialize
         ; Emit mcp_initialized_notification
         ; Emit_and_read mcp_list
         ; Emit_and_read mcp_call
         ; Emit (assistant ~turn_id:"turn-tool-1" "MASC_CLAUDE_TOOL")
         ; Emit (result ~turn_id:"turn-tool-1" "MASC_CLAUDE_TOOL")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~tools:[ tool ]
               ~base_path
               ~cli_path
               ~goal:"USE_TOOL"
               ~raw_trace
               ()
           with
           | Error error -> fail (Agent_core.Error.to_string error)
           | Ok turn ->
             check string
               "tool response"
               "MASC_CLAUDE_TOOL"
               (keeper_response_text turn);
             check string
               "tool arguments"
               {|{"marker":"from-claude"}|}
               (Yojson.Safe.to_string !observed);
             (match turn.trace_ref with
              | Some trace_ref ->
                check string "RAW trace path" raw_trace_path trace_ref.path
              | None -> fail "Claude Code turn did not expose its RAW trace reference");
             let input = open_in_bin raw_trace_path in
             let raw =
               Fun.protect
                 ~finally:(fun () -> close_in input)
                 (fun () -> really_input_string input (in_channel_length input))
             in
             check bool
               "RAW trace contains tool input"
               true
               (String_util.contains_substring raw "from-claude");
             check bool
               "RAW trace contains tool output"
               true
               (String_util.contains_substring raw "MASC_TOOL_RESULT")))
;;

(* WP1 completion trigger (native tool provenance): each official-client
   runtime fixture must emit a native tool event that is distinguishable from
   a MASC/MCP dynamic-tool event by a typed record_type, not by a string
   heuristic over tool names, with matching counts and zero unknown-origin
   events. antigravity (test_keeper_antigravity_runtime.ml) and codex
   (test_runtime_codex_app_server.ml) already cover this; before this test,
   claude_code had zero coverage even though runtime_claude_code.ml emits
   [Native_tool_started]/[Native_tool_finished] (see await_terminal) alongside
   [Dynamic_tool_started]/[Dynamic_tool_finished] for MCP/MASC tool calls on a
   separate control-request channel. This fixture drives one of each in a
   single turn and asserts the RAW trace record_type counts. *)
let test_keeper_distinguishes_native_and_masc_tool_provenance () =
  let base_path = temp_workspace () in
  let raw_trace_path = Filename.concat base_path "claude-native-raw-trace.jsonl" in
  let raw_trace =
    Agent_core.Raw_trace.create ~path:raw_trace_path ()
    |> Result.map_error (fun error -> fail (Agent_core.Error.to_string error))
    |> Result.get_ok
  in
  let marker_param : Agent_core.Types.tool_param =
    { name = "marker"
    ; description = "Fixture marker"
    ; param_type = String
    ; required = true
    }
  in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic fixture marker"
      ~parameters:[ marker_param ]
      (fun _ -> Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
  in
  let native_actions = ref [] in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit_and_read mcp_initialize
         ; Emit mcp_initialized_notification
         ; Emit_and_read mcp_list
         ; Emit
             (native_tool_call_block
                ~turn_id:"turn-mcp-1"
                ~call_id:"provider-mcp-call-1"
                ~tool_name:"mcp__masc__masc_probe")
         ; Emit_and_read mcp_call
         ; Emit
             (native_tool_result
                ~call_id:"provider-mcp-call-1"
                ~content:"MASC_TOOL_RESULT")
         ; Emit
             (native_tool_call_block
                ~turn_id:"turn-native-1"
                ~call_id:"native-call-1"
                ~tool_name:"Bash")
         ; Emit (native_tool_result ~call_id:"native-call-1" ~content:"native tool output")
         ; Emit (assistant ~turn_id:"turn-native-1" "MASC_CLAUDE_NATIVE")
         ; Emit (result ~turn_id:"turn-native-1" "MASC_CLAUDE_NATIVE")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~tools:[ tool ]
               ~base_path
               ~cli_path
               ~goal:"USE_NATIVE_AND_MASC_TOOLS"
               ~raw_trace
               ~on_official_client_native_action:
                 (fun ~runtime_id ~official_turn ~identity ~tool_name ->
                    native_actions :=
                      (runtime_id, official_turn, identity, tool_name)
                      :: !native_actions)
               ()
           with
           | Error error -> fail (Agent_core.Error.to_string error)
           | Ok turn ->
             check string
               "native+masc tool response"
               "MASC_CLAUDE_NATIVE"
               (keeper_response_text turn);
             let records =
               match Agent_core.Raw_trace.read_all ~path:raw_trace_path () with
               | Ok records -> records
               | Error error -> fail (Agent_core.Error.to_string error)
             in
             let records_of_type record_type =
               List.filter
                 (fun (record : Agent_core.Raw_trace.record) ->
                    record.record_type = record_type)
                 records
             in
             check int
               "native tool start count"
               2
               (List.length (records_of_type Native_tool_started));
             check int
               "native tool finish count"
               2
               (List.length (records_of_type Native_tool_finished));
             check int
               "MASC tool execution start count"
               1
               (List.length (records_of_type Tool_execution_started));
             check int
               "MASC tool execution finish count"
               1
               (List.length (records_of_type Tool_execution_finished));
             let native_starts = records_of_type Native_tool_started in
             check bool "MCP wrapper is typed in RAW" true
               (List.exists
                  (fun (record : Agent_core.Raw_trace.record) ->
                     record.native_tool_identity
                     = Some (Agent_core.Raw_trace.Call_id "provider-mcp-call-1")
                     && record.native_tool_origin = Some Agent_core.Raw_trace.Mcp_wrapper)
                  native_starts);
             check bool "built-in action is typed in RAW" true
               (List.exists
                  (fun (record : Agent_core.Raw_trace.record) ->
                     record.native_tool_identity
                     = Some (Agent_core.Raw_trace.Call_id "native-call-1")
                     && record.native_tool_origin = Some Agent_core.Raw_trace.Built_in)
                  native_starts);
             check bool "only the built-in reaches Skill native action observer" true
               (match List.rev !native_actions with
                | [ ( "claude.claude"
                    , 1
                    , Runtime_native_tools.Call_id "native-call-1"
                    , "Bash" ) ] -> true
                | _ -> false)))
;;

let test_keeper_streams_text_and_tool_events () =
  let base_path = temp_workspace () in
  let events = ref [] in
  let marker_param : Agent_core.Types.tool_param =
    { name = "marker"
    ; description = "Fixture marker"
    ; param_type = String
    ; required = true
    }
  in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic fixture marker"
      ~parameters:[ marker_param ]
      (fun _ ->
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit_and_read mcp_initialize
         ; Emit mcp_initialized_notification
         ; Emit_and_read mcp_list
         ; Emit (assistant ~turn_id:"turn-stream-1" "MASC_")
         ; Emit_and_read mcp_call
         ; Emit (result ~turn_id:"turn-stream-1" "MASC_CLAUDE_STREAM")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~tools:[ tool ]
               ~on_event:(fun event -> events := event :: !events)
               ~base_path
               ~cli_path
               ~goal:"USE_TOOL"
               ()
           with
           | Error error -> fail (Agent_core.Error.to_string error)
           | Ok _ ->
             match List.rev !events with
             | [ Agent_core.Types.MessageStart
                   { id = "assistant-turn-stream-1"
                   ; model = "claude-fixture"
                   ; usage = None
                   }
               ; ContentBlockDelta { index = 0; delta = TextDelta "MASC_" }
               ; ContentBlockStart
                   { index = 1
                   ; content_type = "tool_use"
                   ; tool_id = Some "call-1"
                   ; tool_name = Some "masc_probe"
                   }
               ; ContentBlockDelta
                   { index = 1
                   ; delta = InputJsonSnapshot arguments
                   }
               ; ContentBlockStop { index = 1 }
               ; ContentBlockDelta
                   { index = 0; delta = TextDelta "CLAUDE_STREAM" }
               ; MessageDelta { stop_reason = Some EndTurn; usage = None }
               ; MessageStop
               ] ->
               check string
                 "exact keeper tool arguments"
                 {|{"marker":"from-claude"}|}
                 arguments
             | _ -> fail "Keeper did not project the exact Claude stream") )
;;

let test_tools_support_false_omits_mcp_bridge () =
  let base_path = temp_workspace () in
  let called = ref false in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Must not reach a tools-disabled Claude runtime"
      ~parameters:[]
      (fun _ ->
        called := true;
        Ok { Agent_core.Types.content = "unexpected"; content_blocks = None; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         ~forbid_mcp:true
         [ Emit (assistant ~turn_id:"turn-no-mcp" "MASC_CLAUDE_NO_MCP")
         ; Emit (result ~turn_id:"turn-no-mcp" "MASC_CLAUDE_NO_MCP")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~tools:[ tool ]
               ~tools_support:false
               ~base_path
               ~cli_path
               ~goal:"NO_MCP"
               ()
           with
           | Error error -> fail (Agent_core.Error.to_string error)
           | Ok turn ->
             check bool "tool callback not installed" false !called;
             check string
               "response"
               "MASC_CLAUDE_NO_MCP"
               (keeper_response_text turn)))
;;

(* The suite drives two runners under different keeper names, and the session
   store is keyed by that name: the main runner uses [claude-fixture] and
   [run_direct_attempt] uses [claude-pre-dispatch]. Loading under a fixed name
   reads an empty store for the other runner's tests and reports it as state
   that disappeared. *)
let load_state ?(keeper_name = "claude-fixture") base_path =
  match Keeper_official_client_session_store.load ~base_path ~keeper_name with
  | Error detail -> fail detail
  | Ok None -> fail "Claude Code current-owner state disappeared"
  | Ok (Some state) -> state
;;

let prompt_history path =
  let raw =
    In_channel.with_open_bin path (fun input -> In_channel.input_line input)
  in
  match raw with
  | None -> fail "Claude fixture did not capture a prompt"
  | Some raw ->
    raw
    |> content_of_wire_message
    |> Yojson.Safe.from_string
    |> Yojson.Safe.Util.member "history"
    |> Yojson.Safe.Util.to_list
;;

let history_uses_current_schema history =
  List.for_all
    (fun value ->
       Yojson.Safe.Util.(value |> member "schema" |> to_string)
       = Keeper_official_client_context_codec.schema)
    history
;;

let test_keeper_shrinks_history_after_statusless_context_error
    ?(native_gate=false)
    ~overflow_frames
    () =
  let base_path = temp_workspace () in
  let first_system_marker = Filename.concat base_path "full-system.txt" in
  let second_system_marker = Filename.concat base_path "shrunk-system.txt" in
  let first_prompt_marker = Filename.concat base_path "overflow-full-prompt.json" in
  let second_prompt_marker = Filename.concat base_path "overflow-shrunk-prompt.json" in
  let initial_messages =
    List.init 240 (fun index ->
      message
        (if index mod 2 = 0 then User else Assistant)
        (Printf.sprintf "%03d:%s" index (String.make 1_024 'x')))
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let official_client_continuation = if not native_gate then None else (
         with_fixture
           [ Emit (assistant ~turn_id:"turn-gated" "GATE_WAIT")
           ; Emit (result ~turn_id:"turn-gated" "GATE_WAIT") ]
           (fun cli_path -> match run_keeper_turn ~base_path ~cli_path ~goal:"GATE" () with
             | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
         let stored = load_state base_path in
         match stored.phase with
         | Settled {session_id; turn_id} ->
           Some ({ client_kind=stored.client_kind; runtime_id=stored.runtime_id;
             session_id; turn_id; tool_surface_sha256=stored.tool_surface_sha256;
             frame=Keeper_repetition_snapshot.empty } : Keeper_semantic_execution.official_client_checkpoint)
         | _ -> fail "native Gate seed did not settle") in
       with_fixture_sequence
         ~first_system_marker ~second_system_marker
         ~first_prompt_marker
         ~second_prompt_marker
         (List.map (fun frame -> Emit frame) overflow_frames)
         [ Emit (assistant ~turn_id:"turn-shrunk" "MASC_CLAUDE_SHRUNK")
         ; Emit (result ~turn_id:"turn-shrunk" "MASC_CLAUDE_SHRUNK")
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ?official_client_continuation
                ~initial_messages
                ~base_path
                ~cli_path
                ~goal:"SHRINK_HISTORY"
                ()
            with
            | Error error ->
              if not native_gate then fail (Agent_core.Error.to_string error)
            | Ok turn ->
              if native_gate then fail "a Gate resume refused for size completed the turn";
              check string
                "Keeper response"
                "MASC_CLAUDE_SHRUNK"
                (keeper_response_text turn));
       if native_gate then (
         (* A resumed session is refused on the vendor's own conversation, and
            the resume prompt is the same at every capacity, so shrinking
            cannot help. A Gate must stay in its original session, so the turn
            ends on the overflow instead of respawning the same input. *)
         check bool "the Gate resume is not respawned" false
           (Sys.file_exists second_prompt_marker);
         let raw = In_channel.with_open_bin first_prompt_marker In_channel.input_line in
         (match raw with
          | None -> fail "native Gate fixture did not capture its resume input"
          | Some raw ->
            check string "a Gate resume sends only its new input"
              "SHRINK_HISTORY" (content_of_wire_message raw));
         check bool "resume system file carries no canonical snapshot" false
           (String_util.contains_substring
              (In_channel.with_open_bin first_system_marker In_channel.input_all)
              "masc.official-client-canonical-context.v1");
         let checkpoint = match official_client_continuation with
           | Some checkpoint -> checkpoint
           | None -> fail "native Gate seed produced no continuation" in
         let full = load_state base_path in
         let recovery_id = match full.phase with
           | Recovery_required
               { failure =
                   Keeper_official_client_session_store.Vendor_session_full
                     Keeper_official_client_session_store.No_activity_observed
               ; recovery_id
               ; _
               } -> recovery_id
           | _ -> fail "a Gate resume refused for size did not record Vendor_session_full" in
         (* The operation fails with this cause: the Gate cannot continue in
            any session other than the full one. *)
         (match Keeper_direct_gate_continuation.session_full_cause ~checkpoint
             ~approval_id:"approval-full" (Some full) with
          | Some (Keeper_request_failure.Gate_session_full
              { approval_id; runtime_id; session_id; recovery_id = recorded
              ; activity = Keeper_internal_error.No_activity_observed }) ->
            check string "the failure names the Gate" "approval-full" approval_id;
            check string "the failure names the runtime" checkpoint.runtime_id runtime_id;
            check string "the failure names the full session" checkpoint.session_id session_id;
            check string "the failure names the session record" recovery_id recorded
          | Some _ | None -> fail "a full Gate session did not end the operation with its cause");
         check bool "the full session no longer admits the continuation" true
           (Result.is_error
              (Keeper_official_client_session_store.validate_continuation ~checkpoint
                 ~expected:(Some full) ~client_kind:checkpoint.client_kind
                 ~runtime_id:checkpoint.runtime_id
                 ~tool_surface_sha256:checkpoint.tool_surface_sha256));
         (match Eio_main.run (fun _ ->
             Keeper_official_client_session_store.resolve_recovery ~base_path
               ~keeper_name:"claude-fixture" ~expected:full ~recovery_id
               ~resolution:Keeper_official_client_session_store.Retry_previous
               ~resolved_by:"test"
               ~resolved_at:(Unix.gettimeofday ())) with
          | Error Keeper_official_client_session_store.Retry_previous_unavailable -> ()
          | Error _ | Ok _ -> fail "a full session offered to resend the same resume");
         (* The next ordinary turn is not held for an operator: it supersedes
            the record and starts a new session. *)
         with_fixture
           [ Emit (assistant ~turn_id:"turn-fresh" "MASC_CLAUDE_FRESH")
           ; Emit (result ~turn_id:"turn-fresh" "MASC_CLAUDE_FRESH") ]
           (fun cli_path ->
              match run_keeper_turn ~base_path ~cli_path ~goal:"AFTER_FULL" () with
              | Ok turn ->
                check string "the next turn answers" "MASC_CLAUDE_FRESH"
                  (keeper_response_text turn)
              | Error error -> fail (Agent_core.Error.to_string error));
         let fresh = load_state base_path in
         check int "the new session restarts the ordinal" 1 fresh.turn_count;
         match fresh.phase with
         | Settled { turn_id = "turn-fresh"; session_id } ->
           check bool "the new session is not the full one" false
             (String.equal session_id checkpoint.session_id)
         | _ -> fail "the turn after a full Gate session did not settle a new session")
       else (
       List.iter (fun marker ->
         let scoped_path = In_channel.with_open_bin (marker ^ ".path") In_channel.input_all in
         check bool "System file cleaned after rejected and successful turns" false (Sys.file_exists scoped_path))
         [first_system_marker; second_system_marker];
       let full_history = prompt_history first_prompt_marker in
       let shrunk_history = prompt_history second_prompt_marker in
       let full_count = List.length full_history in
       let shrunk_count = List.length shrunk_history in
       check int "first attempt keeps full history" 240 full_count;
       check bool "full history uses current codec" true
         (history_uses_current_schema full_history);
       check bool "retry keeps non-empty history" true (shrunk_count > 0);
       check bool "retry history uses current codec" true
         (history_uses_current_schema shrunk_history);
       check bool
         "retry shrinks provider-bound history"
         true
         (shrunk_count < full_count);
       let state = load_state base_path in
       check int "retry keeps the turn ordinal" 1 state.turn_count;
       match state.phase with
       | Settled { turn_id = "turn-shrunk"; _ } -> ()
       | _ -> fail "shrunk Claude Code retry did not settle"))
;;

let test_post_effect_transport_enters_recovery () =
  let base_path = temp_workspace () in
  let call_count = ref 0 in
  let marker_param : Agent_core.Types.tool_param =
    { name = "marker"
    ; description = "Fixture marker"
    ; param_type = String
    ; required = true
    }
  in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Record one deterministic fixture effect"
      ~parameters:[ marker_param ]
      (fun _input ->
        incr call_count;
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit_and_read mcp_initialize
         (* This notification still has a Claude control request ID, so read
            its control acknowledgement before the tool-list/call replies. *)
         ; Emit_and_read mcp_initialized_notification
         ; Emit_and_read mcp_list
         (* Receiving the actual tool reply orders the disconnect after the
            effect. Closing stdin before emitting the call races the pending
            control replies and can interrupt before the tool ever executes. *)
         ; Emit_and_read mcp_call
         ; Close_transport
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~tools:[ tool ]
                ~base_path
                ~cli_path
                ~goal:"USE_TOOL_ONCE"
                ()
            with
            | Error error ->
              (* Since #28178 the provider-attempt effect fence wraps the
                 provider error once an effect was attempted, so the caller no
                 longer sees the raw [ProviderUnavailable]. The recovery phase
                 asserted below is what this test is named for and is
                 unchanged; here we only pin that the failure is the fence and
                 that it forbids same-turn retry. *)
              (match Keeper_internal_error.classify_masc_internal_error error with
               | Some
                   (Keeper_internal_error.Provider_attempt_effect_fenced
                      { effect_disposition; _ }) ->
                 check
                   string
                   "the fence observed the transport interruption (fail-closed Observation_unavailable)"
                   "observation_unavailable"
                   (Keeper_provider_attempt_effect.to_string effect_disposition);
                 check
                   bool
                   "post-effect failure is fenced against same-turn retry"
                   false
                   (Keeper_provider_attempt_effect.allows_same_turn_retry
                      effect_disposition)
               | _ -> fail (Agent_core.Error.to_string error))
            | Ok _ -> fail "post-effect response failure completed the Keeper turn");
       check int "tool effect count" 1 !call_count;
       let state = load_state base_path in
       match state.phase with
       | Recovery_required { failure = Transport_interrupted; _ } -> ()
       | _ -> fail "post-effect transport failure released the durable claim")
;;

let test_keeper_does_not_retry_context_error_after_tool_effect () =
  let base_path = temp_workspace () in
  let call_count = ref 0 in
  let marker_param : Agent_core.Types.tool_param =
    { name = "marker"
    ; description = "Fixture marker"
    ; param_type = String
    ; required = true
    }
  in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Record one deterministic fixture effect"
      ~parameters:[ marker_param ]
      (fun _input ->
        incr call_count;
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit_and_read mcp_initialize
         ; Emit mcp_initialized_notification
         ; Emit_and_read mcp_list
         ; Emit_and_read mcp_call
         ; Emit prompt_too_long_result
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~tools:[ tool ]
                ~base_path
                ~cli_path
                ~goal:"USE_TOOL_THEN_OVERFLOW"
                ()
            with
            | Error error ->
              (match Keeper_internal_error.classify_masc_internal_error error with
               | Some
                   (Keeper_internal_error.Provider_attempt_effect_fenced
                      { effect_disposition; _ }) ->
                 check
                   bool
                   "post-effect overflow is fenced"
                   false
                   (Keeper_provider_attempt_effect.allows_same_turn_retry
                      effect_disposition)
               | _ -> fail (Agent_core.Error.to_string error))
            | Ok _ -> fail "post-effect context overflow completed the Keeper turn");
       check int "tool effect is not replayed" 1 !call_count;
       let state = load_state base_path in
       match state.phase with
       | Recovery_required
           { failure =
               Input_rejected
                 Keeper_official_client_session_store.Effect_fenced
           ; _
           } -> ()
       | phase ->
         fail
           ("post-effect context overflow did not durably fence the input: "
            ^ (match phase with
               | Recovery_required { failure; _ } ->
                 Keeper_official_client_session_store
                 .recovery_failure_to_string failure
               | _ -> "not-in-recovery")))
;;

let test_keeper_settles_and_resumes () =
  let effect_count = ref 0 in
  let tool = Agent_core.Tool.create ~name:"masc_probe" ~description:"Record one effect"
    ~parameters:[{Agent_core.Types.name="marker";description="marker";param_type=String;required=true}]
    (fun _ -> incr effect_count;
      Ok {Agent_core.Types.content="completed official effect";content_blocks=None;_meta=None}) in
  let base_path = temp_workspace () in
  let system_marker = Filename.concat base_path "resume-system.txt" in
  let native_history = [message User "Native correction after the official turn";
    Agent_core.Types.make_message ~role:Tool [Agent_core.Types.ToolResult
      {tool_use_id="native-call";content="completed native effect";outcome=Tool_succeeded;
       json=Some (`Assoc ["receipt",`String "native-proof"]);content_blocks=None}]] in
  let prompt_marker = Filename.concat base_path "resume-prompt.json" in
  let start_system_marker = Filename.concat base_path "start-system.txt" in
  (* The two messages the host composes for each turn: the per-turn context
     carrier and the Librarian working state. *)
  let carrier : Agent_core.Types.message =
    { role = System
    ; content = [ Text "MASC_TURN_CONTEXT memory revision 903" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = Agent_core.Types.Extra_system_context_provenance.metadata
    }
  in
  let working_state : Agent_core.Types.message =
    { role = System
    ; content = [ Text "MASC_WORKING_STATE two asks answered" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = Runtime_model_input_tail_window.working_state_metadata
    }
  in
  let rendered (message : Agent_core.Types.message) =
    Keeper_official_client_host.history_role_label message.role
    ^ Keeper_official_client_host.encode_history_message message
  in
  let has_canonical_snapshot wire =
    String_util.contains_substring wire "masc.official-client-canonical-context.v1"
  in
  (* What each turn reported about its own model input. The start/resume split
     the rest of this test pins on the wire has to be the same split the
     record carries, or the metrics row describes a request that was not
     sent. *)
  let reports = ref [] in
  let on_request_attribution ~runtime_id:_ ~tools:_ ~transmitted =
    reports := transmitted :: !reports
  in
  let reported_input () =
    match !reports with
    | [ latest ] -> latest
    | other ->
      fail
        (Printf.sprintf
           "expected exactly one input report for the turn, got %d"
           (List.length other))
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         ~system_marker:start_system_marker
         [ Emit_and_read mcp_initialize; Emit mcp_initialized_notification;
           Emit_and_read mcp_list; Emit_and_read mcp_call;
           Emit (assistant ~turn_id:"turn-1" "MASC_CLAUDE_FIRST")
         ; Emit (result ~turn_id:"turn-1" "MASC_CLAUDE_FIRST")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~tools:[tool]
               ~initial_messages:
                 [ message User "earlier user"; message Assistant "earlier assistant"
                 ; carrier ]
               ~base_path
               ~cli_path
               ~goal:"FIRST_GOAL"
               ~on_request_attribution
               ()
           with
           | Error error -> fail (Agent_core.Error.to_string error)
           | Ok turn ->
             check string
               "first response"
               "MASC_CLAUDE_FIRST"
               (keeper_response_text turn);
             check int "first turn" 1 turn.turns);
       (* A start renders the whole prepared list into the prompt, so the
          record may attribute it. *)
       (match reported_input () with
        | Keeper_official_client_host.Whole_input_transmitted messages ->
          check bool
            "a started conversation reports the history it rendered"
            true
            (List.length messages > 0)
        | Keeper_official_client_host.Held_by_client_session ->
          fail "a started conversation reported nothing to attribute");
       (* A start still writes the composed context into the system prompt
          the client records for the session. *)
       let start_system_wire =
         In_channel.with_open_bin start_system_marker In_channel.input_all
       in
       check bool "a start's system prompt carries the turn context" true
         (String_util.contains_substring start_system_wire
            (Keeper_official_client_host.encode_history_message carrier));
       check bool "a start's system prompt carries no canonical snapshot" false
         (has_canonical_snapshot start_system_wire);
       (match (load_state base_path).context_frontier with
        | Some { delivery = Prepared_start_context; _ } -> ()
        | Some _ | None -> fail "a start did not record its prepared context");
       reports := [];
       let first = load_state base_path in
       let session_id =
         match first.phase with
         | Settled { session_id; turn_id = "turn-1" } -> session_id
         | _ -> fail "first Claude Code turn did not settle"
       in
       with_fixture
         ~prompt_marker ~system_marker
         [ Emit (assistant ~turn_id:"turn-2" "MASC_CLAUDE_SECOND")
         ; Emit (result ~turn_id:"turn-2" "MASC_CLAUDE_SECOND")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~tools:[tool]
               ~initial_messages:(carrier :: working_state :: native_history)
               ~system_prompt:"Updated core instructions"
               ~base_path
               ~cli_path
               ~goal:"SECOND_GOAL"
               ~on_request_attribution
               ()
           with
           | Error error -> fail (Agent_core.Error.to_string error)
           | Ok turn ->
             check string "session identity" session_id turn.session_id;
             check int "resumed turn" 2 turn.turns;
             check string
               "second response"
               "MASC_CLAUDE_SECOND"
               (keeper_response_text turn));
       let input = open_in_bin prompt_marker in
       let raw =
         Fun.protect ~finally:(fun () -> close_in input) (fun () -> input_line input)
       in
       (* Claude Code resumes with the system prompt it recorded at the
          session's first launch, so what changes per turn rides in front of
          the resume prompt and the conversation the session holds is not
          sent again. *)
       let resume_prompt = content_of_wire_message raw in
       let position text =
         match Astring.String.find_sub ~sub:text resume_prompt with
         | Some index -> index
         | None -> fail ("resume prompt is missing " ^ text)
       in
       check bool "resume prompt opens with the turn context" true
         (String.starts_with ~prefix:(rendered carrier) resume_prompt);
       check bool "the working state follows the turn context" true
         (position (rendered carrier) < position (rendered working_state));
       check bool "resume prompt ends with the goal" true
         (String.ends_with ~suffix:"\n\nSECOND_GOAL" resume_prompt);
       check bool "resume prompt does not replay the conversation" false
         (String_util.contains_substring resume_prompt "Native correction");
       let system_wire = In_channel.with_open_bin system_marker In_channel.input_all in
       let scoped_path = In_channel.with_open_bin (system_marker ^ ".path") In_channel.input_all in
       check bool "replacement context file removed after child settles" false (Sys.file_exists scoped_path);
       check bool "core instructions lead the resume system prompt" true
         (String.starts_with ~prefix:"Updated core instructions" system_wire);
       check bool "resume system prompt carries no canonical snapshot" false
         (has_canonical_snapshot system_wire);
       check bool "resume system prompt carries no conversation" false
         (String_util.contains_substring system_wire "Native correction");
       check bool "resume system prompt carries no composed context" false
         (String_util.contains_substring system_wire "MASC_TURN_CONTEXT"
          || String_util.contains_substring system_wire "MASC_WORKING_STATE");
       (match reported_input () with
        | Keeper_official_client_host.Held_by_client_session -> ()
        | Keeper_official_client_host.Whole_input_transmitted _ ->
          fail "a resume reported the conversation the vendor session holds as sent");
       check int "resumed context does not repeat official tool effect" 1 !effect_count;
       let second = load_state base_path in
       (match second.context_frontier with
        | Some {acknowledged_turn=Some receipt;delivery=Held_by_vendor_session;message_count;_} ->
          check string "frontier bound to resumed vendor turn" "turn-2" receipt.turn_id;
          check int "frontier counts the canonical history, not the composed context"
            (List.length native_history) message_count
        | Some _ | None -> fail "a resume did not record that the vendor session holds the context");
       check int "durable cumulative turns" 2 second.turn_count;
       match second.phase with
       | Settled { session_id = settled_session; turn_id = "turn-2" } ->
         check string "settled session" session_id settled_session
       | _ -> fail "resumed Claude Code turn did not settle")
;;

(* The historical task reference only exists on a resume of the operation's
   own vendor session, so it has to ride in the resume prompt too: the system
   prompt file it used to land in is not what a resumed session reads. *)
let test_resume_prompt_carries_the_task_reference () =
  let reference : Agent_core.Types.message =
    { (Agent_core.Types.system_msg "MASC_TASK_REFERENCE") with
      metadata = [ "masc_official_historical_task", `String "v1" ] }
  in
  let carrier : Agent_core.Types.message =
    { role = System
    ; content = [ Text "MASC_TURN_CONTEXT" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = Agent_core.Types.Extra_system_context_provenance.metadata
    }
  in
  check bool "the reference is recognised" true
    (Keeper_official_task_reference.is_reference reference);
  let rendered (message : Agent_core.Types.message) =
    Keeper_official_client_host.history_role_label message.role
    ^ Keeper_official_client_host.encode_history_message message
  in
  check string "reference, then turn context, then the goal; history left out"
    (rendered reference ^ "\n\n" ^ rendered carrier ^ "\n\nGOAL")
    (Keeper_official_client_host.resume_prompt ~goal:"GOAL"
       [ reference; message User "held by the vendor session"; carrier ])
;;

let test_pre_effect_provider_rejection_keeps_failover_open () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture [ Emit generic_provider_rejection ] (fun cli_path ->
         match run_keeper_turn ~base_path ~cli_path ~goal:"READ_ONLY_SLACK" () with
         | Error
             (Agent_core.Error.Provider
                (Llm_provider.Error.ProviderReportedError { detail; _ })) ->
           check
             bool
             "provider safeguard diagnostic survives without an effect fence"
             true
             (Astring.String.is_infix ~affix:"safeguards flagged" detail);
           let state = load_state base_path in
           (match state.phase with
            | Recovery_required required ->
              check bool
                "pre-effect provider rejection remains recoverable"
                true
                (required.failure = Provider_rejected)
            | _ -> fail "pre-effect provider rejection did not enter recovery")
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok _ -> fail "provider rejection completed the Keeper turn"))
;;

let test_quota_enters_typed_recovery () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture [ Emit rate_limit_rejected; Emit quota_result ] (fun cli_path ->
         (match run_keeper_turn ~base_path ~cli_path ~goal:"QUOTA_GOAL" () with
          | Error
              (Agent_core.Error.Provider
                 (Llm_provider.Error.HardQuota { detail; _ })) ->
            check bool "quota diagnostic survives" true
              (Astring.String.is_infix ~affix:"quota" detail)
          | Error error -> fail (Agent_core.Error.to_string error)
          | Ok _ -> fail "quota rejection completed the Keeper turn");
         let state = load_state base_path in
         match state.phase with
         | Recovery_required required ->
           check bool
             "provider rejection"
             true
             (required.failure = Provider_rejected);
           check bool
             "measured session"
             true
             (Option.is_some required.observed_session_id);
           check (option string) "no fabricated turn" None required.observed_turn_id
         | _ -> fail "quota rejection did not require explicit recovery"))
;;

let test_quota_after_tool_effect_remains_fenced () =
  let base_path = temp_workspace () in
  let call_count = ref 0 in
  let marker_param : Agent_core.Types.tool_param =
    { name = "marker"
    ; description = "Fixture marker"
    ; param_type = String
    ; required = true
    }
  in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Record one deterministic fixture effect"
      ~parameters:[ marker_param ]
      (fun _input ->
        incr call_count;
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit_and_read mcp_initialize
         ; Emit mcp_initialized_notification
         ; Emit_and_read mcp_list
         ; Emit_and_read mcp_call
         ; Emit rate_limit_rejected
         ; Emit quota_result
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~tools:[ tool ]
                ~base_path
                ~cli_path
                ~goal:"USE_TOOL_THEN_QUOTA"
                ()
            with
            | Error error ->
              (match Keeper_internal_error.classify_masc_internal_error error with
               | Some
                   (Keeper_internal_error.Provider_attempt_effect_fenced
                      { effect_disposition; _ }) ->
                 check bool "post-effect quota remains fenced" false
                   (Keeper_provider_attempt_effect.allows_same_turn_retry
                      effect_disposition)
               | _ -> fail (Agent_core.Error.to_string error))
            | Ok _ -> fail "post-effect quota completed the Keeper turn");
       check int "tool effect is not replayed" 1 !call_count)
;;

let test_quota_after_native_tool_remains_fenced () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit
             (native_tool_call_block
                ~turn_id:"native-quota"
                ~call_id:"native-quota-call"
                ~tool_name:"Write")
         ; Emit
             (native_tool_result
                ~call_id:"native-quota-call"
                ~content:"native tool output")
         ; Emit rate_limit_rejected
         ; Emit quota_result
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~base_path
                ~cli_path
                ~goal:"NATIVE_TOOL_THEN_QUOTA"
                ()
            with
            | Error error ->
              (match Keeper_internal_error.classify_masc_internal_error error with
               | Some
                   (Keeper_internal_error.Provider_attempt_effect_fenced
                      { effect_disposition; _ }) ->
                 check bool "post-native-tool quota remains fenced" false
                   (Keeper_provider_attempt_effect.allows_same_turn_retry
                      effect_disposition)
               | _ -> fail (Agent_core.Error.to_string error))
            | Ok _ -> fail "post-native-tool quota completed the Keeper turn"))
;;

let test_spawn_failure_releases_claim () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let reports = ref 0 in
       with_fixture ~remove_after_auth:true [] (fun cli_path ->
         (match run_keeper_turn ~base_path ~cli_path ~goal:"SPAWN_GOAL"
             ~on_request_attribution:(fun ~runtime_id:_ ~tools:_ ~transmitted:_ -> incr reports) () with
          | Error (Agent_core.Error.Provider (Llm_provider.Error.ProviderUnavailable _)) ->
            ()
          | Error error -> fail (Agent_core.Error.to_string error)
          | Ok _ -> fail "removed CLI unexpectedly completed the Keeper turn");
         check int "prepared turn with missing CLI reports no input" 0 !reports;
         let state = load_state base_path in
         (match state.phase with
          | Ready -> ()
          | _ -> fail "transient spawn failure left the claim occupied");
         match state.last_transient_release with
         | Some { failure = Transient_spawn_failed; _ } -> ()
         | _ -> fail "transient release evidence was not persisted"))
;;

let run_direct_attempt
      ?hooks
      ?(system_prompt = "pre-dispatch fixture system prompt")
      ~base_path
      ~cli_path
      ~goal
      ~tools
      ()
  =
  Masc_test_deps.declare_fixture_keeper
    ~base_path ~sandbox_profile:None "claude-pre-dispatch";
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config cli_path (fun runtime_path ->
         Eio_main.run (fun env ->
           Eio.Switch.run (fun sw ->
             Eio_context.set_env env;
             Eio_context.with_test_env
               ~net:(Eio.Stdenv.net env)
               ~clock:(Eio.Stdenv.clock env)
               ~mono_clock:(Eio.Stdenv.mono_clock env)
               ~sw
               (fun () ->
                  Runtime.init_default ~config_path:runtime_path |> Result.get_ok;
                  let config =
                    match Runtime.get_runtime_by_id "claude.claude" with
                    | Some
                        { Runtime.execution = Runtime_execution.Claude_code config
                        ; _
                        } ->
                      config
                    | Some _ | None -> fail "Claude runtime fixture did not resolve"
                  in
                  Keeper_claude_code_runtime.run
                    ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
                    ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input
                      ~runtime:(Runtime.get_runtime_by_id "claude.claude" |> Option.get))
                    ~pre_tool_rejects:(ref [])
                    ~runtime_id:"claude.claude"
                    ~keeper_name:"claude-pre-dispatch"
                    ~base_path
                    ~goal
                    ~goal_blocks:None
                    (* Defaults to non-empty text. The keeper mainline refuses a
                       composed system prompt that comes out blank rather than
                       omitting [--system-prompt] and running the turn under
                       the client's built-in prompt, so [""] would make every
                       attempt below fail on config instead of reaching the
                       behaviour each one asserts. The text is a don't-care;
                       only its non-emptiness is load-bearing. *)
                    ~system_prompt
                    ~tools
                    ~initial_messages:[]
                    ~model_input_projection:None
                    ~on_transmitted_model_input:(fun _ -> ())
                    ~hooks
                    ~context_injector:None
                      (* Dynamic tools require the Keeper shared context
                         ([Keeper_official_client_host.dynamic_tools] rejects
                         [tools <> []] with [context = None]). Supply one
                         unconditionally: with [~tools:[]] the gate returns
                         [Ok []] either way, so the no-tools attempts are
                         unaffected. *)
                    ~context:(Some (Agent_core.Context.create ()))
                    ~event_bus:None
                    ~raw_trace:None
                    ~on_event:None
                    ~config
                    ())))))
;;

let check_pre_dispatch_attempt label attempt =
  (match attempt.Keeper_claude_code_runtime.result with
   | Error (Agent_core.Error.Provider (Llm_provider.Error.ProviderUnavailable _)) -> ()
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail (label ^ " unexpectedly ran"));
  check string
    (label ^ " is proven pre-dispatch")
    "no_effect_observed"
    (Keeper_provider_attempt_effect.to_string attempt.effect_disposition)
;;

let test_subscription_spawn_failure_is_pre_dispatch () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let missing_cli = Filename.concat base_path "missing-claude" in
       run_direct_attempt
         ~base_path
         ~cli_path:missing_cli
         ~goal:"subscription probe should fail"
         ~tools:[]
         ()
       |> check_pre_dispatch_attempt "subscription probe spawn failure")
;;

let test_turn_spawn_failure_is_pre_dispatch_with_tools () =
  let base_path = temp_workspace () in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Must not execute when the turn process cannot spawn"
      ~parameters:[]
      (fun _input ->
        fail "turn-spawn fixture unexpectedly executed a dynamic tool")
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture ~remove_after_auth:true [] (fun cli_path ->
         run_direct_attempt
           ~base_path
           ~cli_path
           ~goal:"turn process spawn should fail"
           ~tools:[ tool ]
           ()
         |> check_pre_dispatch_attempt "turn process spawn failure"))
;;

let test_unbounded_turn_keeps_subscription_probe_bounded () =
  let turn_config =
    { (Runtime_claude_code.default_config ~cwd:"/tmp") with timeout_s = None }
  in
  let probe_config =
    Keeper_claude_code_runtime.For_testing.bounded_probe_config
      ~fallback_timeout_s:17.0
      turn_config
  in
  match probe_config.timeout_s with
  | Some seconds -> check (float 0.0) "probe fallback" 17.0 seconds
  | None -> fail "unbounded turn config leaked into the subscription probe"
;;

let repeated_tool_fixture =
  [ Emit_and_read mcp_initialize
  ; Emit mcp_initialized_notification
  ; Emit_and_read mcp_list
  ; Emit_and_read (mcp_call_with_id "repeat-1")
  ; Emit_and_read (mcp_call_with_id "repeat-2")
  ; Emit_and_read (mcp_call_with_id "repeat-3")
  ]
;;

let repeated_tool () =
  Agent_core.Tool.create
    ~name:"masc_probe"
    ~description:"Return the same deterministic result"
    ~parameters:
      [ { Agent_core.Types.name = "marker"
        ; description = "Fixture marker"
        ; param_type = String
        ; required = true
        }
      ]
    (fun _ ->
      Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; content_blocks = None; _meta = None })
;;

(* A context-limit refusal and an empty history leave no smaller view to try,
   so the attempt ends on the overflow. No answer or tool activity was
   observed, so the attempt must report no effect: that is what lets
   the lane move to its next runtime instead of fencing the turn. *)
let test_unshrinkable_context_limit_reports_no_effect ~overflow_frames () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture (List.map (fun frame -> Emit frame) overflow_frames)
         (fun cli_path ->
            let attempt =
              run_direct_attempt ~base_path ~cli_path ~goal:"BLOCKED" ~tools:[] ()
            in
            (match attempt.result with
             | Error (Agent_core.Error.Api (Llm_provider.Retry.ContextOverflow _)) -> ()
             | Error error -> fail (Agent_core.Error.to_string error)
             | Ok _ -> fail "a context-limit refusal completed the attempt");
            check
              string
              "a refusal without observed activity has no effect"
              "no_effect_observed"
              (Keeper_provider_attempt_effect.to_string attempt.effect_disposition)))
;;

(* A blank composition must not reach [Runtime_claude_code.config.system_prompt]
   as [None]. [None] means "omit --system-prompt", which since #33072 hands the
   turn Claude Code's built-in coding-agent prompt while masc's tool set and
   [--permission-mode dontAsk] stay in place. The refusal is checked on the
   typed [InvalidConfig] field rather than by substring so a reworded detail
   does not silently stop proving anything. The CLI fixture is deliberately a
   working one: the refusal has to land before spawn, so reaching a spawn
   failure here would mean the check ran too late. *)
let test_blank_system_prompt_is_refused_not_defaulted () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture repeated_tool_fixture (fun cli_path ->
         let attempt =
           run_direct_attempt
             ~system_prompt:"   "
             ~base_path
             ~cli_path
             ~goal:"REPEAT_TOOL"
             ~tools:[ repeated_tool () ]
             ()
         in
         match attempt.result with
         | Error
             (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; _ }))
           -> check string "refused field" "system_prompt" field
         | Error error ->
           fail
             ("blank system prompt produced the wrong error: "
              ^ Agent_core.Error.to_string error)
         | Ok _ -> fail "blank system prompt was sent as the client default"))
;;

let test_repeated_tool_stop_records_pre_result_turn_identity () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture repeated_tool_fixture (fun cli_path ->
         let attempt =
           run_direct_attempt
             ~base_path
             ~cli_path
             ~goal:"REPEAT_TOOL"
             ~tools:[ repeated_tool () ]
             ()
         in
         (match attempt.result with
          | Error error -> fail (Agent_core.Error.to_string error)
          | Ok result ->
            (match result.stop_reason with
             | Runtime_agent.Yielded_after_repeated_tool_call
                 { tool_name; repeated_count; _ } ->
               check string "repeated tool" "masc_probe" tool_name;
               check int "repeat threshold" 3 repeated_count
             | _ -> fail "repeated Claude tool call was not a checkpoint yield"));
         match
           (load_state ~keeper_name:"claude-pre-dispatch" base_path).phase
         with
         | Settled { session_id; turn_id; _ } ->
           check
             string
             "deterministic pre-result turn identity"
             (Keeper_claude_code_runtime.For_testing.host_stop_turn_identity
                ~session_id
                ~turn_count:1)
             turn_id
         | _ -> fail "repeated Claude tool call did not settle durable state"))
;;

let test_repeated_tool_stop_preserves_terminal_hook_failure () =
  let base_path = temp_workspace () in
  let hooks =
    { Agent_core.Hooks.empty with
      post_tool_use =
        Some
          (fun _ ->
             raise (Failure "post-tool fixture terminal failure"))
    }
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture repeated_tool_fixture (fun cli_path ->
         let attempt =
           run_direct_attempt
             ~hooks
             ~base_path
             ~cli_path
             ~goal:"REPEAT_FAILED_HOOK"
             ~tools:[ repeated_tool () ]
             ()
         in
         match attempt.result with
         | Ok _ -> fail "repeated host stop hid the terminal hook failure"
         | Error error ->
           check bool
             "terminal hook detail survives"
             true
             (String_util.contains_substring
                (Agent_core.Error.to_string error)
                "post-tool fixture terminal failure")))
;;

(* The activity axis decides which admission fence the durable session gets:
   an overflow with any observed activity is effect-fenced, an activity-free
   overflow that exhausted the in-run shrink floor is floor-exceeded. Both
   must stop the next cycle from replaying the same over-capacity input. *)
let test_context_overflow_maps_to_input_rejected_recovery () =
  let map = Keeper_claude_code_runtime.For_testing.recovery_failure_of_client_error in
  let overflow ~tool_effect_attempted ~response_emitted =
    Runtime_claude_code.Context_window_exceeded
      { message = "Prompt is too long"; tool_effect_attempted; response_emitted }
  in
  check bool "no-activity overflow is floor-exceeded"
    (map (overflow ~tool_effect_attempted:false ~response_emitted:false)
    = Keeper_official_client_session_store.(
         Input_rejected Bootstrap_floor_exceeded))
    true;
  check bool "response observed is effect-fenced"
    (map (overflow ~tool_effect_attempted:false ~response_emitted:true)
    = Keeper_official_client_session_store.(Input_rejected Effect_fenced))
    true;
  check bool "tool effect observed is effect-fenced"
    (map (overflow ~tool_effect_attempted:true ~response_emitted:false)
    = Keeper_official_client_session_store.(Input_rejected Effect_fenced))
    true;
  check bool "other provider rejections stay generic"
    (map (Runtime_claude_code.Subscription_required "auth required")
    = Keeper_official_client_session_store.Provider_rejected)
    true
;;

(* A Gate continuation's resume refused as full ends the Gate whatever it did
   first; the record keeps whether a response or tool effect came first. *)
let test_gate_resume_overflow_is_session_full () =
  let map = Keeper_claude_code_runtime.For_testing.recovery_failure_of_attempt in
  let overflow ~tool_effect_attempted ~response_emitted =
    Runtime_claude_code.Context_window_exceeded
      { message = "Prompt is too long"; tool_effect_attempted; response_emitted }
  in
  let resume = Runtime_claude_code.Resume { session_id = "session-1" } in
  check bool "no activity"
    (map ~session_mode:resume ~gate_continuation:true
       (overflow ~tool_effect_attempted:false ~response_emitted:false)
     = Keeper_official_client_session_store.(Vendor_session_full No_activity_observed))
    true;
  check bool "after a tool effect"
    (map ~session_mode:resume ~gate_continuation:true
       (overflow ~tool_effect_attempted:true ~response_emitted:false)
     = Keeper_official_client_session_store.(Vendor_session_full Activity_observed))
    true;
  check bool "after a response"
    (map ~session_mode:resume ~gate_continuation:true
       (overflow ~tool_effect_attempted:false ~response_emitted:true)
     = Keeper_official_client_session_store.(Vendor_session_full Activity_observed))
    true;
  check bool "an ordinary resume keeps the input fence"
    (map ~session_mode:resume ~gate_continuation:false
       (overflow ~tool_effect_attempted:true ~response_emitted:false)
     = Keeper_official_client_session_store.(Input_rejected Effect_fenced))
    true
;;

let test_native_action_observer_keeps_exact_provider_identity () =
  let seen = ref [] in
  let observe ~official_turn ~identity ~tool_name =
    seen := (official_turn, identity, tool_name) :: !seen
  in
  Keeper_claude_code_runtime.For_testing.observe_stream_native_action ~turn_count:9 ~observe
    (Runtime_claude_code.Native_tool_started
       { Runtime_native_tools.identity = Some (Call_id "claude-call")
       ; tool_name = Some "Edit"
       ; origin = Built_in
       });
  Keeper_claude_code_runtime.For_testing.observe_stream_native_action ~turn_count:10 ~observe
    (Runtime_claude_code.Native_tool_started
       { Runtime_native_tools.identity = Some (Call_id "claude-call-2")
       ; tool_name = None
       ; origin = Built_in
       });
  check
    bool
    "exact only"
    true
    (match List.rev !seen with
     | [ 9, Runtime_native_tools.Call_id "claude-call", "Edit" ] -> true
     | _ -> false)
;;

(* [--tools] narrows the CLI's built-in set to the names it lists, and the
   CLI defers MCP tool schemas only while its own [ToolSearch] is among them.
   A posture that drops the name therefore sends every masc tool schema
   inline on every request, so each posture keeps it. *)
let test_every_posture_names_the_schema_lookup () =
  check
    string
    "none carries the lookup alone"
    "ToolSearch"
    (Runtime_native_tools.claude_code_tools_arg Runtime_native_tools.Native_none);
  check
    string
    "read carries it after the read set"
    "Read,Glob,Grep,ToolSearch"
    (Runtime_native_tools.claude_code_tools_arg Runtime_native_tools.Native_read);
  check
    string
    "full is the whole built-in set, which already carries it"
    "default"
    (Runtime_native_tools.claude_code_tools_arg Runtime_native_tools.Native_full)
;;

(* RFC-0454 P2. A Claude Code client that exited, or whose stdout reached EOF,
   is the twin of the Codex runtime's closed connection. It shared one rendered
   sentence with a failed spawn, which is what the chat pane had to read back;
   now the two are separate values and the spawn keeps its old carriage. *)
let test_a_closed_client_connection_is_typed () =
  let core =
    Keeper_claude_code_runtime.For_testing.claude_error_to_core_error
      (Runtime_claude_code.Process_exited
         { detail = "stdout closed"; turn_admitted = true })
  in
  (match Keeper_internal_error.classify_masc_internal_error core with
   | Some
       (Keeper_internal_error.Runtime_connection_closed
          { runtime_id; detail; turn_accepted }) ->
     check string "runtime" "claude_code" runtime_id;
     check string "detail" "stdout closed" detail;
     check bool "turn was admitted" true turn_accepted
   | Some _ | None -> fail "a closed Claude Code connection did not decode");
  match
    Keeper_claude_code_runtime.For_testing.claude_error_to_core_error
      (Runtime_claude_code.Spawn_failed "executable not found")
  with
  | Agent_core.Error.Provider (Llm_provider.Error.ProviderUnavailable _) -> ()
  | other ->
    failf
      "a failed spawn must stay provider-unavailable, got %s"
      (Agent_core.Error.to_string other)
;;

(* A start seed begins where the last completed turn's range did, whichever
   runtime measured it: this lane cuts from the keeper's checkpoint history
   like every Agent Core candidate, so the same position names the same atoms
   (RFC keeper-context-window-in-tokens §10.4). The declared ceiling keeps its
   own cut and the later of the two positions wins, so a ceiling never widens
   a seeded range and a seed never widens the ceiling's. *)
let start_seed_history () =
  let message role text : Agent_core.Types.message =
    { role; content = [ Text text ]; name = None; tool_call_id = None; metadata = [] }
  in
  List.concat
    (List.init 60 (fun i ->
       [ message Agent_core.Types.User (Printf.sprintf "ask %02d" i)
       ; message Agent_core.Types.Assistant (Printf.sprintf "answer %02d" i)
       ]))
;;

let completed_record ~messages ~transmitted : Turn_record.t =
  let total_atoms = snd (Runtime_model_input_tail_window.annotate messages) in
  let front_atom_digest =
    match
      Runtime_model_input_tail_window.atom_opening_digest
        messages
        (total_atoms - transmitted)
    with
    | Some digest -> digest
    | None -> fail "the record's own history has that atom"
  in
  { execution_ids = []
  ; keeper = "alpha"
  ; agent_name = "alpha-agent"
  ; turn_kind = Turn_record.Direct
  ; trace_id = "trace-1"
  ; absolute_turn = 1260
  ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1260
  ; blocks = []
  ; input_components = None
  ; tool_surface_ref = None
  ; runtime_profile = "kimi_coding.kimi-k3"
  ; selected_model = None
  ; finish_reason = Some "completed"
  ; context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = None
  ; ttfrc_ms = None
  ; request_wire_observation = None
  ; model_input_window =
      Some
        { Turn_record.transmitted_atoms = transmitted
        ; total_atoms
        ; measurement = Turn_record.Wire_shape
        ; front_atom_digest
        }
  ; response_observed_model_input =
      Some
        { runtime_profile = "kimi_coding.kimi-k3"
        ; window =
            { transmitted_atoms = transmitted
            ; total_atoms
            ; measurement = Turn_record.Wire_shape
            ; front_atom_digest
            }
        }
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
  ; usage =
      { input_tokens = None
      ; output_tokens = None
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope = Runtime_usage_scope.Per_request
      }
  ; ts = 0.
  }
;;

let seed_read_of records =
  { Keeper_carried_front.seed =
      Keeper_carried_front.of_records
        ~trace_id:"trace-1"
        records
  ; unreadable = None
  ; boundary_error = None
  }
;;

(* What the Agent Core path composes for the same front, so the assertion is
   "the same range", not "this many atoms". *)
let agent_core_range ?(turn_start = 0) ~front messages =
  (Keeper_turn_driver_try_provider.For_testing.compose_carried_model_input
     ~measure_message_bytes:(Keeper_context_core.message_measurer ())
     ~front
     ~history_digest_at:(Runtime_model_input_tail_window.atom_opening_digest messages)
     ~current_turn_results:Keeper_turn_driver_try_provider.Current_turn_verbatim
     ~base_path:""
     ~demote_before:0
     ~turn_boundary:(Keeper_carried_front.Turn_boundary { end_atom = turn_start })
     messages)
    .Keeper_turn_driver_try_provider.projection
    .Runtime_model_input_tail_window.messages
;;

let encoded = List.map Keeper_official_client_host.encode_history_message

let test_a_start_seed_begins_at_the_carried_front () =
  let observed = ref None in
  let messages = start_seed_history () in
  let seed_read = seed_read_of [ completed_record ~messages ~transmitted:7 ] in
  match
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes:Keeper_claude_code_runtime.For_testing.unbounded_capacity_bytes
      ~carried_front_seed:(fun () -> seed_read)
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~on_model_input_window_observation:(fun o -> observed := Some o)
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok carried ->
    check (list string) "the same range the Agent Core path composes"
      (encoded (agent_core_range ~front:seed_read.Keeper_carried_front.seed messages))
      (encoded carried);
    (match !observed with
     | None -> fail "the projection reported no window"
     | Some observation ->
       check int "the reading counts the whole history" 120
         observation.Runtime_model_input_tail_window.total_atoms;
       check int "and says seven atoms went" 7
         observation.Runtime_model_input_tail_window.transmitted_atoms)
;;

(* The declared ceiling names a front of its own. When it is the later of the
   two, it decides, so the shrink ladder that answers a typed overflow
   (#37063) keeps narrowing a seeded start instead of being widened back by
   the seed on the retry. *)
let test_the_declared_ceiling_wins_when_it_cuts_deeper () =
  let observed = ref None in
  let messages = start_seed_history () in
  let seed_read = seed_read_of [ completed_record ~messages ~transmitted:7 ] in
  (* The zero-history floor is what the framing alone costs; two more
     messages above it leaves the exact cut room for about two atoms, well
     inside the seed's seven and far below the 60-atom quantum, so the cut is
     exact rather than quantized. *)
  let measure = Keeper_official_client_host.measure_message_bytes in
  let newest_two =
    match List.rev messages with
    | newest :: before :: _ -> measure newest + measure before
    | _ -> fail "the history has at least two messages"
  in
  let capacity_bytes =
    match
      Runtime_model_input_tail_window.minimum_capacity_bytes
        ~measure_message_bytes:measure
        messages
    with
    | Some floor_bytes -> floor_bytes + newest_two
    | None -> fail "a history this long has a framed floor"
  in
  let ceiling_only =
    match
      Runtime_model_input_tail_window.project_with_drop
        ~allow_empty_history:true
        ~measure_message_bytes:Keeper_official_client_host.measure_message_bytes
        ~capacity_bytes
        ~reserved_bytes:0
        messages
    with
    | Ok projection -> projection
    | Error error ->
      fail (Runtime_model_input_tail_window.budget_error_to_string error)
  in
  match
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes
      ~carried_front_seed:(fun () -> seed_read)
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~on_model_input_window_observation:(fun o -> observed := Some o)
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok carried ->
    check bool "the ceiling cuts deeper than the seed here" true
      (ceiling_only.Runtime_model_input_tail_window.dropped_atoms > 113);
    check bool "and still carries the turn" true
      (ceiling_only.Runtime_model_input_tail_window.dropped_atoms < 120);
    check (list string) "so the ceiling decides the range"
      (encoded ceiling_only.Runtime_model_input_tail_window.messages)
      (encoded carried);
    (match !observed with
     | None -> fail "the projection reported no window"
     | Some observation ->
       check int "and the reading is the ceiling's"
         (120 - ceiling_only.Runtime_model_input_tail_window.dropped_atoms)
         observation.Runtime_model_input_tail_window.transmitted_atoms)
;;

(* Cold start on a history with no completed turn: no record names a front
   and the turn start is 0, so everything the history has goes. *)
let test_a_cold_start_with_no_completed_turn_carries_everything () =
  let observed = ref None in
  let messages = start_seed_history () in
  match
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes:Keeper_claude_code_runtime.For_testing.unbounded_capacity_bytes
      ~carried_front_seed:(fun () -> seed_read_of [])
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~on_model_input_window_observation:(fun o -> observed := Some o)
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok carried ->
    check (list string) "the same range the Agent Core path composes"
      (encoded (agent_core_range ~front:None messages))
      (encoded carried);
    (match !observed with
     | None -> fail "the projection reported no window"
     | Some observation ->
       check int "every atom went" 120
         observation.Runtime_model_input_tail_window.transmitted_atoms)
;;

(* No record names a front but the history has completed turns: the range
   starts where the last of them ended, this turn's own atoms, the same
   place the Agent Core path starts (RFC keeper-context-window-in-tokens
   §13.4). *)
let test_a_cold_start_begins_at_the_turn_start () =
  let observed = ref None in
  let messages = start_seed_history () in
  match
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes:Keeper_claude_code_runtime.For_testing.unbounded_capacity_bytes
      ~carried_front_seed:(fun () -> seed_read_of [])
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 112 })
      ~on_model_input_window_observation:(fun o -> observed := Some o)
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok carried ->
    check (list string) "the same range the Agent Core path composes"
      (encoded (agent_core_range ~turn_start:112 ~front:None messages))
      (encoded carried);
    (match !observed with
     | None -> fail "the projection reported no window"
     | Some observation ->
       check int "the reading counts the whole history" 120
         observation.Runtime_model_input_tail_window.total_atoms;
       check int "and says this turn's eight atoms went" 8
         observation.Runtime_model_input_tail_window.transmitted_atoms)
;;

(* A snapshot the Librarian wrote after reading [messages] through
   [end_atom], on a history whose one completed turn ended there. *)
let snapshot_through ~messages ~end_atom ~working_state =
  let covered = List.filteri (fun i _ -> i < end_atom) messages in
  let position =
    match Keeper_turn_boundaries.position_of_messages covered with
    | Ok position -> position
    | Error detail -> fail detail
  in
  let line =
    ( 1
    , Ok
        { Keeper_turn_boundaries.recorded_at = 1.
        ; event =
            Keeper_turn_boundaries.Turn_ended
              { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
              ; history_at_start = Keeper_turn_boundaries.Fresh_history
              ; position
              }
        } )
  in
  match
    Librarian_continuity_snapshot.capture ~trace_id:"trace-1" ~lines:[ line ] ~messages:covered
      ~working_state
  with
  | Ok snapshot -> snapshot
  | Error error -> fail (Librarian_continuity_snapshot.error_to_string error)
;;

let text_of (message : Agent_core.Types.message) =
  match message.content with
  | [ Agent_core.Types.Text text ] -> text
  | _ -> ""
;;

(* The Librarian front reaches the list this lane sends -- a read position
   as the start, a working state carried in place of the atoms before it --
   and a list the turn's choice no longer describes refuses the request,
   as it refuses an Agent Core request, instead of going out from the seed. *)
let test_the_librarian_front_reaches_the_list_and_its_error_refuses () =
  let messages = start_seed_history () in
  let seen_front = ref None in
  let project librarian_front =
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes:Keeper_claude_code_runtime.For_testing.unbounded_capacity_bytes
      ~librarian_front
      ~on_carried_front:(fun front ~transmitted_bytes -> seen_front := Some (front, transmitted_bytes))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  in
  (match project (fun _ -> Ok (Keeper_turn_driver_try_provider.Librarian_progress { end_atom = 100 })) with
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok carried ->
     check (list string) "the range starts at the read position"
       (encoded (List.filteri (fun i _ -> i >= 100) messages))
       (encoded carried));
  (match !seen_front with
   | Some (Keeper_official_client_host.Librarian_progress { end_atom = 100 }, bytes) ->
     check bool "the front is reported with the range's bytes" true (bytes > 0)
   | Some _ -> fail "the reported front is not the read position"
   | None -> fail "the composition reported no front");
  let snapshot =
    snapshot_through ~messages ~end_atom:100 ~working_state:"Fifty asks answered so far."
  in
  (match project (fun _ -> Ok (Keeper_turn_driver_try_provider.Librarian_snapshot snapshot)) with
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok carried ->
     (match carried with
      | working :: rest ->
        check string "the working state leads the list"
          (Keeper_turn_driver_try_provider.working_state_text snapshot)
          (text_of working);
        check (list string) "and the atoms it covers are not sent"
          (encoded (List.filteri (fun i _ -> i >= 100) messages))
          (encoded rest)
      | [] -> fail "nothing was composed"));
  let refused _ =
    Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig
            { field = "librarian.continuity"; detail = "Covered conversation changed during dispatch" }))
  in
  match project refused with
  | Error _ -> ()
  | Ok _ -> fail "a list the turn's choice no longer describes went out"
;;

let working_state_not_carried ~reason =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string WorkingStateNotCarried)
    ~labels:
      [ "keeper", "alpha"; "runtime", "claude_code.claude-sonnet-5"; "reason", reason ]
    ()
;;

(* The declared ceiling cuts before the working state is known (RFC-0460).
   A working state carried in front of a range the ceiling then has to cut
   would push out atoms it does not cover, so it stays out and the
   Librarian's position goes alone: the same range, every atom of it. The
   turn is not refused, and the counter says the summary was left out and
   why. *)
let test_a_working_state_that_would_displace_atoms_stays_out () =
  let messages = start_seed_history () in
  let measure = Keeper_official_client_host.measure_message_bytes in
  let bytes lo hi =
    List.fold_left
      (fun total message -> total + measure message)
      0
      (List.filteri (fun i _ -> i >= lo && i < hi) messages)
  in
  (* The omission preamble the window charges on a cut: the floor of a
     history with no pinned message is that one message. *)
  let preamble_bytes =
    match
      Runtime_model_input_tail_window.minimum_capacity_bytes
        ~measure_message_bytes:measure
        messages
    with
    | Some bytes -> bytes
    | None -> fail "the fixture history has no shrinkable atom"
  in
  (* Room for the preamble and the twenty messages from atom 100, where the
     Librarian read to, and nothing for a working state on top. *)
  let capacity_bytes = preamble_bytes + bytes 100 120 in
  let observed = ref None in
  let project snapshot =
    observed := None;
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes
      ~librarian_front:(fun _ ->
        Ok (Keeper_turn_driver_try_provider.Librarian_snapshot snapshot))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~on_model_input_window_observation:(fun o -> observed := Some o)
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  in
  let is_atom (message : Agent_core.Types.message) =
    (not (Runtime_model_input_tail_window.is_synthetic_preamble message))
    && message.role <> Agent_core.Types.System
  in
  let goes_alone ~reason snapshot =
    let before = working_state_not_carried ~reason in
    match project snapshot with
    | Error error -> fail (Agent_core.Error.to_string error)
    | Ok sent ->
      let working_state = Keeper_turn_driver_try_provider.working_state_text snapshot in
      check int "the working state stays out" 0
        (List.length (List.filter (fun m -> String.equal (text_of m) working_state) sent));
      check (list string) "and every atom from the Librarian's position goes"
        (encoded (List.filteri (fun i _ -> i >= 100) messages))
        (encoded (List.filter is_atom sent));
      check bool "inside the ceiling" true
        (List.fold_left (fun total m -> total + measure m) 0 sent <= capacity_bytes);
      (match !observed with
       | None -> fail "the projection reported no window"
       | Some (observation : Runtime_model_input_tail_window.window_observation) ->
         check int "the window reports the twenty atoms that went" 20
           observation.transmitted_atoms;
         check int "of the whole history" 120 observation.total_atoms);
      check (float 0.) ("counted as " ^ reason) (before +. 1.)
        (working_state_not_carried ~reason)
  in
  goes_alone ~reason:"displaces_atoms"
    (snapshot_through ~messages ~end_atom:100 ~working_state:"Fifty asks answered so far.");
  (* A working state the ceiling cannot hold beside the pinned messages at
     all is the same answer: the position goes alone. *)
  goes_alone ~reason:"does_not_fit"
    (snapshot_through ~messages ~end_atom:100 ~working_state:(String.make 4_000 'w'))
;;

(* A range the ceiling already fits goes out as it was cut. When the cut
   lands on an assistant turn the range opens with the omission preamble,
   and a window handed that list must charge the preamble once: it is the
   message the window itself would put back, not an atom of the range.
   Charged twice, a range that fit loses atoms at its front, and the reading
   names a later front that the next turn's seed then holds. *)
(* The live warning this pins: a Claude Code request that carried a working
   state and the turn's own context carrier failed the composition check as a
   repeated carrier, because both wore the carrier's tag. *)
let test_a_working_state_beside_the_turn_carrier_passes_the_composition_check () =
  let messages = start_seed_history () in
  let measure = Keeper_official_client_host.measure_message_bytes in
  let snapshot =
    snapshot_through ~messages ~end_atom:100 ~working_state:"Fifty asks answered so far."
  in
  let capacity_bytes =
    List.fold_left (fun total message -> total + measure message) 0 messages * 2
  in
  match
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes
      ~librarian_front:(fun _ ->
        Ok (Keeper_turn_driver_try_provider.Librarian_snapshot snapshot))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok sent ->
    let working_state = Keeper_turn_driver_try_provider.working_state_text snapshot in
    check int "the working state is sent" 1
      (List.length (List.filter (fun m -> String.equal (text_of m) working_state) sent));
    let carrier : Agent_core.Types.message =
      { role = System
      ; content = [ Text "turn context" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = Agent_core.Types.Extra_system_context_provenance.metadata
      }
    in
    (match
       Keeper_agent_prompt_metrics.provider_content_of_transmitted
         ~prompt_context_present:true
         ~messages:(sent @ [ carrier ])
     with
     | Ok retained ->
       check int "only the carrier is removed" (List.length sent) (List.length retained)
     | Error _ -> fail "the working state was read as a second carrier")
;;

let test_a_range_the_ceiling_fits_goes_as_cut () =
  (* One ask in front of the fixture puts an assistant turn at atom 60, the
     first multiple the window's quantized cut tries, and leaves 61 atoms
     from there: more than one quantum, so a window that failed at 0 would
     jump to 60 rather than drop the preamble alone. *)
  let messages =
    ({ role = User; content = [ Text "ask intro" ]; name = None; tool_call_id = None
     ; metadata = [] }
     : Agent_core.Types.message)
    :: start_seed_history ()
  in
  let measure = Keeper_official_client_host.measure_message_bytes in
  let preamble_bytes =
    match
      Runtime_model_input_tail_window.minimum_capacity_bytes
        ~measure_message_bytes:measure
        messages
    with
    | Some bytes -> bytes
    | None -> fail "the fixture history has no shrinkable atom"
  in
  (* Exactly the preamble and the atoms from 60, an assistant turn. *)
  let capacity_bytes =
    preamble_bytes
    + List.fold_left
        (fun total message -> total + measure message)
        0
        (List.filteri (fun i _ -> i >= 60) messages)
  in
  let observed = ref None in
  let project ?librarian_front () =
    observed := None;
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes
      ?librarian_front
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~on_model_input_window_observation:(fun o -> observed := Some o)
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  in
  let goes_as_cut label sent =
    (match sent with
     | head :: rest ->
       check bool (label ^ ": the range opens with the preamble") true
         (Runtime_model_input_tail_window.is_synthetic_preamble head);
       check (list string) (label ^ ": and every atom from the cut follows")
         (encoded (List.filteri (fun i _ -> i >= 60) messages))
         (encoded rest)
     | [] -> fail (label ^ ": nothing went out"));
    match !observed with
    | None -> fail (label ^ ": the projection reported no window")
    | Some (observation : Runtime_model_input_tail_window.window_observation) ->
      check int (label ^ ": the reading counts the sixty-one atoms") 61
        observation.transmitted_atoms;
      check (option string) (label ^ ": and names atom 60 as its front")
        (Runtime_model_input_tail_window.atom_opening_digest messages 60)
        (Some observation.front_atom_digest)
  in
  (match project () with
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok sent -> goes_as_cut "no Librarian position" sent);
  (* A snapshot behind the cut does not win the range: the same range goes,
     nothing is pinned, and nothing is counted as left out. *)
  let before = working_state_not_carried ~reason:"displaces_atoms" in
  match
    project
      ~librarian_front:(fun _ ->
        Ok
          (Keeper_turn_driver_try_provider.Librarian_snapshot
             (snapshot_through ~messages ~end_atom:50 ~working_state:"Twenty-five asks.")))
      ()
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok sent ->
    goes_as_cut "a snapshot behind the cut" sent;
    check (float 0.) "and no working state is counted as left out" before
      (working_state_not_carried ~reason:"displaces_atoms")
;;

(* A ceiling that holds the working state and the whole range sends both. *)
let test_a_working_state_that_displaces_nothing_goes () =
  let messages = start_seed_history () in
  let measure = Keeper_official_client_host.measure_message_bytes in
  let snapshot =
    snapshot_through ~messages ~end_atom:100 ~working_state:"Fifty asks answered so far."
  in
  let working_state = Keeper_turn_driver_try_provider.working_state_text snapshot in
  let pinned : Agent_core.Types.message =
    { role = System
    ; content = [ Text working_state ]
    ; name = None
    ; tool_call_id = None
    ; metadata = Runtime_model_input_tail_window.working_state_metadata
    }
  in
  (* Exactly the working state, the preamble and the twenty atoms from 100. *)
  let capacity_bytes =
    (match
       Runtime_model_input_tail_window.minimum_capacity_bytes
         ~measure_message_bytes:measure
         (pinned :: messages)
     with
     | Some bytes -> bytes
     | None -> fail "the fixture history has no shrinkable atom")
    + List.fold_left
        (fun total message -> total + measure message)
        0
        (List.filteri (fun i _ -> i >= 100) messages)
  in
  let before = working_state_not_carried ~reason:"displaces_atoms" in
  match
    Keeper_claude_code_runtime.For_testing.start_seed_projection
      ~capacity_bytes
      ~librarian_front:(fun _ ->
        Ok (Keeper_turn_driver_try_provider.Librarian_snapshot snapshot))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ~keeper_name:"alpha"
      ~runtime_id:"claude_code.claude-sonnet-5"
      messages
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok sent ->
    check int "the working state goes, once" 1
      (List.length (List.filter (fun m -> String.equal (text_of m) working_state) sent));
    check (list string) "with every atom it abuts"
      (encoded (List.filteri (fun i _ -> i >= 100) messages))
      (encoded
         (List.filter
            (fun (m : Agent_core.Types.message) ->
               (not (Runtime_model_input_tail_window.is_synthetic_preamble m))
               && m.role <> Agent_core.Types.System)
            sent));
    check (float 0.) "and nothing is counted as left out" before
      (working_state_not_carried ~reason:"displaces_atoms")
;;

let () =
  run
    "keeper_claude_code_runtime"
    [ ( "native action", [ test_case "exact provider identity" `Quick test_native_action_observer_keeps_exact_provider_identity ] )
    ; ( "usage scope"
      , [ test_case "result-only usage keeps client-turn scope" `Quick
            test_result_only_usage_keeps_client_turn_scope
        ; test_case "latest request outranks client-turn total" `Quick
            test_latest_request_usage_outranks_client_turn_total
        ] )
    ; ( "lifecycle"
      , [ test_case "settles and resumes" `Quick test_keeper_settles_and_resumes
        ; test_case "resume prompt carries the task reference" `Quick
            test_resume_prompt_carries_the_task_reference
        ; test_case
            "Agent Core checkpoint starts official-client turn"
            `Quick
            test_agent_core_checkpoint_starts_official_client_turn
        ; test_case "native Gate resume refused as full ends the Gate and frees the session" `Quick
            (test_keeper_shrinks_history_after_statusless_context_error
               ~native_gate:true
               ~overflow_frames:[ blocking_limit_diagnostic; blocking_limit_result ])
        ; test_case
            "shrinks history after the CLI's blocking_limit refusal"
            `Quick
            (test_keeper_shrinks_history_after_statusless_context_error
               ~overflow_frames:[ blocking_limit_diagnostic; blocking_limit_result ])
        ; test_case
            "shrinks history after the CLI's rapid_refill_breaker refusal"
            `Quick
            (test_keeper_shrinks_history_after_statusless_context_error
               ~overflow_frames:[ rapid_refill_breaker_diagnostic; rapid_refill_breaker_result ])
        ; test_case
            "projects typed tool history and lifecycle"
            `Quick
            test_keeper_projects_typed_tool_history_and_lifecycle
        ; test_case "projects MASC tool" `Quick test_keeper_projects_masc_tool
        ; test_case
            "distinguishes native and MASC tool provenance"
            `Quick
            test_keeper_distinguishes_native_and_masc_tool_provenance
        ; test_case
            "streams text and tool events"
            `Quick
            test_keeper_streams_text_and_tool_events
        ; test_case
            "tools-support false omits MCP bridge"
            `Quick
            test_tools_support_false_omits_mcp_bridge
        ; test_case
            "post-effect transport enters recovery"
            `Quick
            test_post_effect_transport_enters_recovery
        ; test_case
            "does not retry context error after tool effect"
            `Quick
            test_keeper_does_not_retry_context_error_after_tool_effect
        ; test_case
            "context overflow maps to input-rejected recovery"
            `Quick
            test_context_overflow_maps_to_input_rejected_recovery
        ; test_case "Gate resume overflow is session-full" `Quick
            test_gate_resume_overflow_is_session_full
        ; test_case
            "pre-effect provider rejection keeps failover open"
            `Quick
            test_pre_effect_provider_rejection_keeps_failover_open
        ; test_case "quota enters recovery" `Quick test_quota_enters_typed_recovery
        ; test_case "quota after tool effect remains fenced" `Quick
            test_quota_after_tool_effect_remains_fenced
        ; test_case "quota after native tool remains fenced" `Quick
            test_quota_after_native_tool_remains_fenced
        ; test_case
            "spawn failure releases claim"
            `Quick
            test_spawn_failure_releases_claim
        ; test_case
            "subscription spawn failure is pre-dispatch"
            `Quick
            test_subscription_spawn_failure_is_pre_dispatch
        ; test_case
            "turn spawn failure is pre-dispatch with tools"
            `Quick
            test_turn_spawn_failure_is_pre_dispatch_with_tools
        ; test_case
            "unbounded turn keeps subscription probe bounded"
            `Quick
            test_unbounded_turn_keeps_subscription_probe_bounded
        ; test_case
            "unshrinkable blocking_limit reports no effect"
            `Quick
            (test_unshrinkable_context_limit_reports_no_effect
               ~overflow_frames:[ blocking_limit_diagnostic; blocking_limit_result ])
        ; test_case
            "unshrinkable rapid_refill_breaker without activity reports no effect"
            `Quick
            (test_unshrinkable_context_limit_reports_no_effect
               ~overflow_frames:[ rapid_refill_breaker_diagnostic; rapid_refill_breaker_result ])
        ; test_case
            "blank system prompt is refused not defaulted"
            `Quick
            test_blank_system_prompt_is_refused_not_defaulted
        ; test_case
            "repeated tool stop records pre-result turn identity"
            `Quick
            test_repeated_tool_stop_records_pre_result_turn_identity
        ; test_case
            "repeated tool stop preserves terminal hook failure"
            `Quick
            test_repeated_tool_stop_preserves_terminal_hook_failure
        ; test_case
            "every posture names the schema lookup"
            `Quick
            test_every_posture_names_the_schema_lookup
        ; test_case
            "a closed client connection is typed"
            `Quick
            test_a_closed_client_connection_is_typed
        ] )
    ; ( "start seed"
      , [ test_case
            "a start seed begins at the carried front"
            `Quick
            test_a_start_seed_begins_at_the_carried_front
        ; test_case
            "the declared ceiling wins when it cuts deeper"
            `Quick
            test_the_declared_ceiling_wins_when_it_cuts_deeper
        ; test_case
            "a cold start with no completed turn carries everything"
            `Quick
            test_a_cold_start_with_no_completed_turn_carries_everything
        ; test_case
            "a cold start begins at the turn start"
            `Quick
            test_a_cold_start_begins_at_the_turn_start
        ; test_case
            "the Librarian front reaches the list and its error refuses"
            `Quick
            test_the_librarian_front_reaches_the_list_and_its_error_refuses
        ; test_case
            "a working state that would displace atoms stays out"
            `Quick
            test_a_working_state_that_would_displace_atoms_stays_out
        ; test_case
            "a working state that displaces nothing goes"
            `Quick
            test_a_working_state_that_displaces_nothing_goes
        ; test_case
            "a working state beside the turn carrier passes the composition check"
            `Quick
            test_a_working_state_beside_the_turn_carrier_passes_the_composition_check
        ; test_case
            "a range the ceiling fits goes as cut"
            `Quick
            test_a_range_the_ceiling_fits_goes_as_cut
        ] )
    ]
;;
