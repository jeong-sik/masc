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

let mcp_initialize =
  {|{"type":"control_request","request_id":"mcp-init-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}}}|}
;;

let mcp_list =
  {|{"type":"control_request","request_id":"mcp-list-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}}}|}
;;

let mcp_call =
  {|{"type":"control_request","request_id":"mcp-call-1","request":{"subtype":"mcp_message","server_name":"masc","message":{"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"masc_probe","arguments":{"marker":"from-claude"}}}}}|}
;;

let fixture_script ?prompt_marker ?(remove_after_auth = false) lines =
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
    (fun line -> output_string output ("emit " ^ shell_quote line ^ "\n"))
    lines;
  output_string output "while IFS= read -r ignored; do :; done\n";
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let with_fixture ?prompt_marker ?remove_after_auth lines f =
  let path = fixture_script ?prompt_marker ?remove_after_auth lines in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

let runtime_toml cli_path =
  Printf.sprintf
    "[providers.claude]\n\
     protocol = \"claude-code\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [models.claude]\n\
     api-name = \"claude-fixture\"\n\
     max-context = 200000\n\
     \n\
     [claude.claude]\n\
     \n\
     [runtime]\n\
     default = \"claude.claude\"\n"
    cli_path
;;

let with_runtime_config cli_path f =
  let path = Filename.temp_file "masc-keeper-claude-runtime-" ".toml" in
  let output = open_out_bin path in
  output_string output (runtime_toml cli_path);
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
  |> List.filter_map (function Agent_sdk.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let message role text : Agent_sdk.Types.message =
  { role; content = [ Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

let run_keeper_turn ?(tools = []) ?(initial_messages = []) ~base_path ~cli_path
    ~goal () =
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
                  match Runtime.init_default ~config_path:runtime_path with
                  | Error error -> fail error
                  | Ok () ->
                    let context =
                      match tools with
                      | [] -> None
                      | _ :: _ -> Some (Agent_sdk.Context.create ())
                    in
                    Keeper_turn_driver.run_named
                      ~runtime_id:"claude.claude"
                      ~keeper_name:"claude-fixture"
                      ~base_path
                      ~goal
                      ~tools
                      ~initial_messages
                      ?context
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ())))))
;;

let test_keeper_projects_masc_tool () =
  let base_path = temp_workspace () in
  let observed = ref `Null in
  let marker_param : Agent_sdk.Types.tool_param =
    { name = "marker"
    ; description = "Fixture marker"
    ; param_type = String
    ; required = true
    }
  in
  let tool =
    Agent_sdk.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic fixture marker"
      ~parameters:[ marker_param ]
      (fun input ->
        observed := input;
        Ok { Agent_sdk.Types.content = "MASC_TOOL_RESULT"; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ mcp_initialize
         ; mcp_list
         ; mcp_call
         ; assistant ~turn_id:"turn-tool-1" "MASC_CLAUDE_TOOL"
         ; result ~turn_id:"turn-tool-1" "MASC_CLAUDE_TOOL"
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~tools:[ tool ]
               ~base_path
               ~cli_path
               ~goal:"USE_TOOL"
               ()
           with
           | Error error -> fail (Agent_sdk.Error.to_string error)
           | Ok turn ->
             check string
               "tool response"
               "MASC_CLAUDE_TOOL"
               (keeper_response_text turn);
             check string
               "tool arguments"
               {|{"marker":"from-claude"}|}
               (Yojson.Safe.to_string !observed)))
;;

let load_state base_path =
  match
    Keeper_official_client_session_store.load
      ~base_path
      ~keeper_name:"claude-fixture"
  with
  | Error detail -> fail detail
  | Ok None -> fail "Claude Code current-owner state disappeared"
  | Ok (Some state) -> state
;;

let content_of_wire_message raw =
  Yojson.Safe.from_string raw
  |> Yojson.Safe.Util.member "message"
  |> Yojson.Safe.Util.member "content"
  |> Yojson.Safe.Util.to_string
;;

let test_keeper_settles_and_resumes () =
  let base_path = temp_workspace () in
  let prompt_marker = Filename.concat base_path "resume-prompt.json" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ assistant ~turn_id:"turn-1" "MASC_CLAUDE_FIRST"
         ; result ~turn_id:"turn-1" "MASC_CLAUDE_FIRST"
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~initial_messages:
                 [ message User "earlier user"; message Assistant "earlier assistant" ]
               ~base_path
               ~cli_path
               ~goal:"FIRST_GOAL"
               ()
           with
           | Error error -> fail (Agent_sdk.Error.to_string error)
           | Ok turn ->
             check string
               "first response"
               "MASC_CLAUDE_FIRST"
               (keeper_response_text turn);
             check int "first turn" 1 turn.turns);
       let first = load_state base_path in
       let session_id =
         match first.phase with
         | Settled { session_id; turn_id = "turn-1" } -> session_id
         | _ -> fail "first Claude Code turn did not settle"
       in
       with_fixture
         ~prompt_marker
         [ assistant ~turn_id:"turn-2" "MASC_CLAUDE_SECOND"
         ; result ~turn_id:"turn-2" "MASC_CLAUDE_SECOND"
         ]
         (fun cli_path ->
           match
             run_keeper_turn
               ~initial_messages:[ message User "ALREADY_IN_OFFICIAL_SESSION" ]
               ~base_path
               ~cli_path
               ~goal:"SECOND_GOAL"
               ()
           with
           | Error error -> fail (Agent_sdk.Error.to_string error)
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
       let second = load_state base_path in
       check int "durable cumulative turns" 2 second.turn_count;
       match second.phase with
       | Settled { session_id = settled_session; turn_id = "turn-2" } ->
         check string "settled session" session_id settled_session
       | _ -> fail "resumed Claude Code turn did not settle")
;;

let test_quota_enters_typed_recovery () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture [ rate_limit_rejected; quota_result ] (fun cli_path ->
         (match run_keeper_turn ~base_path ~cli_path ~goal:"QUOTA_GOAL" () with
          | Error (Agent_sdk.Error.Provider (Llm_provider.Error.HardQuota _)) -> ()
          | Error error -> fail (Agent_sdk.Error.to_string error)
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

let test_spawn_failure_releases_claim () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture ~remove_after_auth:true [] (fun cli_path ->
         (match run_keeper_turn ~base_path ~cli_path ~goal:"SPAWN_GOAL" () with
          | Error (Agent_sdk.Error.Provider (Llm_provider.Error.ProviderUnavailable _)) ->
            ()
          | Error error -> fail (Agent_sdk.Error.to_string error)
          | Ok _ -> fail "removed CLI unexpectedly completed the Keeper turn");
         let state = load_state base_path in
         (match state.phase with
          | Ready -> ()
          | _ -> fail "transient spawn failure left the claim occupied");
         match state.last_transient_release with
         | Some { failure = Transient_spawn_failed; _ } -> ()
         | _ -> fail "transient release evidence was not persisted"))
;;

let () =
  run
    "keeper_claude_code_runtime"
    [ ( "lifecycle"
      , [ test_case "settles and resumes" `Quick test_keeper_settles_and_resumes
        ; test_case "projects MASC tool" `Quick test_keeper_projects_masc_tool
        ; test_case "quota enters recovery" `Quick test_quota_enters_typed_recovery
        ; test_case
            "spawn failure releases claim"
            `Quick
            test_spawn_failure_releases_claim
        ] )
    ]
;;
