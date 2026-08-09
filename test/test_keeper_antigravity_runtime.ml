open Alcotest
open Masc
open Keeper_official_client_session_store

let conversation_id = "conversation-fixture-1"

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let temp_workspace prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  Unix.realpath path
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

let fixture_script ~workspace ?(malformed = false) () =
  let path = Filename.temp_file "masc-agy-keeper-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output ("test \"$PWD\" = " ^ shell_quote workspace ^ " || exit 71\n");
  output_string output
    "test -z \"${GEMINI_API_KEY+x}\" && test -z \"${GOOGLE_API_TOKEN+x}\" && test -z \"${ANTHROPIC_API_KEY+x}\" || exit 72\n";
  output_string output
    "case \" $* \" in *\" --model gemini-fixture \"*) ;; *) exit 73 ;; esac\n";
  output_string output
    "case \" $* \" in *\" --mode plan \"*) ;; *) exit 74 ;; esac\n";
  output_string output
    "case \" $* \" in *\" --disable-slash-commands \"*) ;; *) exit 75 ;; esac\n";
  output_string output ("conversation=" ^ shell_quote conversation_id ^ "\n");
  output_string output "turns=1\nresponse=MASC_AGY_KEEPER_START\n";
  output_string output
    "while test \"$#\" -gt 0; do case \"$1\" in --conversation) shift; conversation=\"$1\"; turns=2; response=MASC_AGY_KEEPER_RESUME ;; esac; shift; done\n";
  if malformed
  then output_string output "printf '%s\\n' 'not-json'\n"
  else (
    output_string output
      "printf '%s\\n' \"{\\\"event\\\":\\\"init\\\",\\\"conversation_id\\\":\\\"$conversation\\\",\\\"init\\\":{\\\"model\\\":\\\"gemini-fixture\\\",\\\"cwd\\\":\\\"$PWD\\\",\\\"tools\\\":[\\\"run_command\\\"],\\\"permission_mode\\\":\\\"always-proceed\\\"}}\"\n";
    output_string output
      "printf '%s\\n' \"{\\\"event\\\":\\\"step_update\\\",\\\"step_update\\\":{\\\"conversation_id\\\":\\\"$conversation\\\",\\\"step_index\\\":1,\\\"state\\\":\\\"ACTIVE\\\",\\\"step_type\\\":\\\"tool\\\"}}\"\n";
    output_string output
      "printf '%s\\n' \"{\\\"event\\\":\\\"result\\\",\\\"result\\\":{\\\"conversation_id\\\":\\\"$conversation\\\",\\\"status\\\":\\\"SUCCESS\\\",\\\"response\\\":\\\"$response\\\",\\\"num_turns\\\":$turns,\\\"usage\\\":{\\\"input_tokens\\\":21,\\\"output_tokens\\\":4,\\\"thinking_tokens\\\":2,\\\"cache_read_tokens\\\":7,\\\"total_tokens\\\":25}}}\"\n");
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let runtime_toml ~cli_path =
  Printf.sprintf
    "[providers.antigravity]\n\
     protocol = \"antigravity-cli\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [models.gemini-fixture]\n\
     api-name = \"gemini-fixture\"\n\
     max-context = 128000\n\
     \n\
     [antigravity.gemini-fixture]\n\
     \n\
     [runtime]\n\
     default = \"antigravity.gemini-fixture\"\n"
    cli_path
;;

let with_runtime_config ~cli_path f =
  let path = Filename.temp_file "masc-agy-keeper-runtime-" ".toml" in
  let output = open_out_bin path in
  output_string output (runtime_toml ~cli_path);
  close_out output;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let response_text (result : Runtime_agent.run_result) =
  result.response.content
  |> List.filter_map (function
    | Agent_sdk.Types.Text text -> Some text
    | _ -> None)
  |> String.concat ""
;;

let run_turn ?(tools = []) ~base_path ~cli_path ~goal () =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config ~cli_path (fun runtime_path ->
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
                    Keeper_turn_driver.run_named
                      ~runtime_id:"antigravity.gemini-fixture"
                      ~keeper_name:"agy-fixture"
                      ~base_path
                      ~goal
                      ~tools
                      ~initial_messages:[]
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ())))))
;;

let fixture_tool () =
  Agent_sdk.Tool.create
    ~name:"masc_fixture"
    ~description:"A MASC-only fixture tool"
    ~parameters:[]
    (fun _ -> Ok { Agent_sdk.Types.content = "fixture"; _meta = None })
;;

let test_start_resume_and_durable_ordinal () =
  let base_path = temp_workspace "masc-agy-keeper-" in
  let cli_path = fixture_script ~workspace:base_path () in
  Fun.protect
    ~finally:(fun () -> Sys.remove cli_path; cleanup_tree base_path)
    (fun () ->
       let first =
         match run_turn ~base_path ~cli_path ~goal:"fixture start" () with
         | Ok result -> result
         | Error error -> fail (Agent_sdk.Error.to_string error)
       in
       check string "first response" "MASC_AGY_KEEPER_START" (response_text first);
       check int "first turn" 1 first.turns;
       check string "conversation" conversation_id first.session_id;
       (match first.response.usage with
        | None -> fail "provider usage was dropped"
        | Some usage ->
          check int "input tokens" 21 usage.input_tokens;
          check int "output tokens" 4 usage.output_tokens;
          check int "cache tokens" 7 usage.cache_read_input_tokens);
       let resumed =
         match run_turn ~base_path ~cli_path ~goal:"fixture resume" () with
         | Ok result -> result
         | Error error -> fail (Agent_sdk.Error.to_string error)
       in
       check string "resumed response" "MASC_AGY_KEEPER_RESUME" (response_text resumed);
       check int "resumed turn" 2 resumed.turns;
       match
         Keeper_official_client_session_store.load
           ~base_path
           ~keeper_name:"agy-fixture"
       with
       | Error detail -> fail detail
       | Ok None -> fail "settled Antigravity session disappeared"
       | Ok (Some binding) ->
         check bool
           "client kind"
           true
           (binding.client_kind = Antigravity);
         (match binding.phase with
          | Settled { session_id; turn_id } ->
            check string "stored conversation" conversation_id session_id;
            check string
              "provider-observed ordinal"
              (conversation_id ^ ":ordinal:2")
              turn_id
          | Ready | Start _ | Active _ | Turn_inflight _ | Recovery_required _ ->
            fail "successful Antigravity turn was not settled"))
;;

let test_protocol_failure_requires_recovery () =
  let base_path = temp_workspace "masc-agy-recovery-" in
  let cli_path = fixture_script ~workspace:base_path ~malformed:true () in
  Fun.protect
    ~finally:(fun () -> Sys.remove cli_path; cleanup_tree base_path)
    (fun () ->
       (match run_turn ~base_path ~cli_path ~goal:"malformed" () with
        | Error _ -> ()
        | Ok _ -> fail "malformed Antigravity stream completed");
       match
         Keeper_official_client_session_store.load
           ~base_path
           ~keeper_name:"agy-fixture"
       with
       | Error detail -> fail detail
       | Ok None -> fail "failed turn left no recovery record"
       | Ok (Some { phase = Recovery_required recovery; _ }) ->
         check bool "protocol failure" true (recovery.failure = Protocol_failed)
       | Ok (Some _) -> fail "failed turn did not require recovery")
;;

let test_masc_tools_fail_before_claim () =
  let base_path = temp_workspace "masc-agy-tools-" in
  let cli_path = fixture_script ~workspace:base_path () in
  Fun.protect
    ~finally:(fun () -> Sys.remove cli_path; cleanup_tree base_path)
    (fun () ->
       match
         run_turn
           ~tools:[ fixture_tool () ]
           ~base_path
           ~cli_path
           ~goal:"must reject unprojected tools"
           ()
       with
       | Error
         (Agent_sdk.Error.Config
             (Agent_sdk.Error.InvalidConfig { field; _ })) ->
         check string "rejection field" "tools" field;
         (match
            Keeper_official_client_session_store.load
              ~base_path
              ~keeper_name:"agy-fixture"
          with
          | Ok None -> ()
          | Ok (Some _) -> fail "tool rejection left a durable claim"
          | Error detail -> fail detail)
       | Error error -> fail (Agent_sdk.Error.to_string error)
       | Ok _ -> fail "MASC tools were silently dropped")
;;

let () =
  run
    "Keeper Antigravity official-client runtime"
    [ ( "durable execution"
      , [ test_case "start resume and durable ordinal" `Quick test_start_resume_and_durable_ordinal
        ; test_case "protocol failure requires recovery" `Quick test_protocol_failure_requires_recovery
        ; test_case "MASC tools fail before claim" `Quick test_masc_tools_fail_before_claim
        ] )
    ]
;;
