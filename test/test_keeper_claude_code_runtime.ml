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
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-overflow-1","result":"Prompt is too long · the request is ~250000 tokens (limit 200000)","api_error_status":400}|}
;;

let prompt_too_long_statusless_result =
  {|{"type":"result","subtype":"success","is_error":true,"session_id":"__SESSION__","uuid":"turn-statusless-overflow-1","result":"Prompt is too long"}|}
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
  | Emit_after_closing_input of string

let fixture_script ?prompt_marker ?(remove_after_auth = false) ?(forbid_mcp = false)
    lines =
  let path = Filename.temp_file "masc-keeper-claude-code-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output "set -eu\n";
  output_string output "if [ \"${1-}\" = auth ]; then\n";
  output_string output ("  printf '%s\\n' " ^ shell_quote auth_subscription ^ "\n");
  if remove_after_auth
  then output_string output "  rm -- \"$0\"\n";
  output_string output "  exit 0\n";
  output_string output "fi\n";
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
      | Emit_after_closing_input line ->
        output_string output "exec 0<&-\n";
        output_string output ("emit " ^ shell_quote line ^ "\n"))
    lines;
  output_string output "while IFS= read -r ignored; do :; done\n";
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture ?prompt_marker ?remove_after_auth ?forbid_mcp lines f =
  let path = fixture_script ?prompt_marker ?remove_after_auth ?forbid_mcp lines in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

let with_fixture_sequence
    ?first_prompt_marker
    ?second_prompt_marker
    first_lines
    second_lines
    f =
  let first_path = fixture_script ?prompt_marker:first_prompt_marker first_lines in
  let second_path = fixture_script ?prompt_marker:second_prompt_marker second_lines in
  let counter_path = Filename.temp_file "masc-keeper-claude-sequence-" ".txt" in
  Sys.remove counter_path;
  let path = Filename.temp_file "masc-keeper-claude-sequence-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output "set -eu\n";
  output_string output "if [ \"${1-}\" = auth ]; then\n";
  output_string output ("  printf '%s\\n' " ^ shell_quote auth_subscription ^ "\n");
  output_string output "  exit 0\n";
  output_string output "fi\n";
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
    ?on_request_attribution ~base_path ~cli_path ~goal () =
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
  ; thinking_budget = None
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
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
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
      (fun _ -> Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
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
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
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
        Ok { Agent_core.Types.content = "unexpected"; _meta = None })
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

let test_keeper_shrinks_history_after_statusless_context_error () =
  let base_path = temp_workspace () in
  let first_prompt_marker = Filename.concat base_path "overflow-full-prompt.json" in
  let second_prompt_marker = Filename.concat base_path "overflow-shrunk-prompt.json" in
  let initial_messages =
    List.init 240 (fun index ->
      message
        (if index mod 2 = 0 then User else Assistant)
        (Printf.sprintf "%03d:%s" index (String.make 1_024 'x')))
  in
  let reset_shrink_state () =
    Eio_main.run (fun _ ->
      Keeper_context_overflow_shrink_state.For_testing.reset ())
  in
  reset_shrink_state ();
  Fun.protect
    ~finally:(fun () ->
      reset_shrink_state ();
      cleanup_tree base_path)
    (fun () ->
       with_fixture_sequence
         ~first_prompt_marker
         ~second_prompt_marker
         [ Emit prompt_too_long_statusless_result ]
         [ Emit (assistant ~turn_id:"turn-shrunk" "MASC_CLAUDE_SHRUNK")
         ; Emit (result ~turn_id:"turn-shrunk" "MASC_CLAUDE_SHRUNK")
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~initial_messages
                ~base_path
                ~cli_path
                ~goal:"SHRINK_HISTORY"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok turn ->
              check string
                "Keeper response"
                "MASC_CLAUDE_SHRUNK"
                (keeper_response_text turn));
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
       check int "fresh retry settles as turn one" 1 state.turn_count;
       match state.phase with
       | Settled { turn_id = "turn-shrunk"; _ } -> ()
       | _ -> fail "shrunk Claude Code retry did not settle")
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
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ Emit_and_read mcp_initialize
         ; Emit mcp_initialized_notification
         ; Emit_and_read mcp_list
         ; Emit_after_closing_input mcp_call
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
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
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
  let base_path = temp_workspace () in
  let prompt_marker = Filename.concat base_path "resume-prompt.json" in
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
         [ Emit (assistant ~turn_id:"turn-1" "MASC_CLAUDE_FIRST")
         ; Emit (result ~turn_id:"turn-1" "MASC_CLAUDE_FIRST")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~initial_messages:
                 [ message User "earlier user"; message Assistant "earlier assistant" ]
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
       reports := [];
       let first = load_state base_path in
       let session_id =
         match first.phase with
         | Settled { session_id; turn_id = "turn-1" } -> session_id
         | _ -> fail "first Claude Code turn did not settle"
       in
       with_fixture
         ~prompt_marker
         [ Emit (assistant ~turn_id:"turn-2" "MASC_CLAUDE_SECOND")
         ; Emit (result ~turn_id:"turn-2" "MASC_CLAUDE_SECOND")
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~initial_messages:[ message User "ALREADY_IN_OFFICIAL_SESSION" ]
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
       check string
         "resume sends only current goal"
         "SECOND_GOAL"
         (content_of_wire_message raw);
       (* And the record says the same thing the wire does. Reporting the
          prepared list here would attribute "ALREADY_IN_OFFICIAL_SESSION" and
          the first turn's history to a request that carried neither
          (masc#32995). *)
       (match reported_input () with
        | Keeper_official_client_host.Held_by_client_session -> ()
        | Keeper_official_client_host.Whole_input_transmitted messages ->
          fail
            (Printf.sprintf
               "a resumed conversation attributed %d messages the wire did not \
                carry"
               (List.length messages)));
       let second = load_state base_path in
       check int "durable cumulative turns" 2 second.turn_count;
       match second.phase with
       | Settled { session_id = settled_session; turn_id = "turn-2" } ->
         check string "settled session" session_id settled_session
       | _ -> fail "resumed Claude Code turn did not settle")
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
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
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
       with_fixture ~remove_after_auth:true [] (fun cli_path ->
         (match run_keeper_turn ~base_path ~cli_path ~goal:"SPAWN_GOAL" () with
          | Error (Agent_core.Error.Provider (Llm_provider.Error.ProviderUnavailable _)) ->
            ()
          | Error error -> fail (Agent_core.Error.to_string error)
          | Ok _ -> fail "removed CLI unexpectedly completed the Keeper turn");
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
      Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
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

let () =
  run
    "keeper_claude_code_runtime"
    [ ( "native action", [ test_case "exact provider identity" `Quick test_native_action_observer_keeps_exact_provider_identity ] )
    ; ( "lifecycle"
      , [ test_case "settles and resumes" `Quick test_keeper_settles_and_resumes
        ; test_case
            "Agent Core checkpoint starts official-client turn"
            `Quick
            test_agent_core_checkpoint_starts_official_client_turn
        ; test_case
            "shrinks history after statusless context error"
            `Quick
            test_keeper_shrinks_history_after_statusless_context_error
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
        ] )
    ]
;;
