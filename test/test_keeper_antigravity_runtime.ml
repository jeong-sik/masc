open Alcotest
open Masc

let conversation_id = "9971bfe0-4e21-40f9-8b5d-715ec5096965"

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

let fixture_script ~workspace =
  let path = Filename.temp_file "masc-agy-keeper-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output
    ("test \"$PWD\" = " ^ shell_quote workspace ^ " || exit 71\n");
  output_string output ("conversation=" ^ shell_quote conversation_id ^ "\n");
  output_string output "turns=1\nresponse=MASC_AGY_KEEPER_START\n";
  output_string output
    "while test \"$#\" -gt 0; do case \"$1\" in --conversation) shift; conversation=\"$1\"; turns=2; response=MASC_AGY_KEEPER_RESUME ;; esac; shift; done\n";
  output_string output
    "printf '%s\\n' \"{\\\"event\\\":\\\"init\\\",\\\"conversation_id\\\":\\\"$conversation\\\",\\\"init\\\":{\\\"model\\\":\\\"gemini-fixture\\\",\\\"cwd\\\":\\\"$PWD\\\",\\\"tools\\\":[\\\"run_command\\\"],\\\"permission_mode\\\":\\\"always-proceed\\\"}}\"\n";
  output_string output
    "printf '%s\\n' \"{\\\"event\\\":\\\"step_update\\\",\\\"step_update\\\":{\\\"conversation_id\\\":\\\"$conversation\\\",\\\"step_index\\\":1,\\\"state\\\":\\\"DONE\\\",\\\"step_type\\\":\\\"tool\\\"}}\"\n";
  output_string output
    "printf '%s\\n' \"{\\\"event\\\":\\\"result\\\",\\\"result\\\":{\\\"conversation_id\\\":\\\"$conversation\\\",\\\"status\\\":\\\"SUCCESS\\\",\\\"response\\\":\\\"$response\\\",\\\"num_turns\\\":$turns,\\\"usage\\\":{\\\"input_tokens\\\":21,\\\"output_tokens\\\":4,\\\"thinking_tokens\\\":2,\\\"cache_read_tokens\\\":7,\\\"total_tokens\\\":25}}}\"\n";
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
  |> List.filter_map (function Agent_sdk.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let run_turn ~base_path ~cli_path ~goal =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config ~cli_path (fun runtime_path ->
         Eio_main.run (fun env ->
           Eio.Switch.run (fun sw ->
             Eio_context.set_env env;
             Process_eio.init
               ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / ".")
               ~proc_mgr:(Eio.Stdenv.process_mgr env)
               ~clock:(Eio.Stdenv.clock env);
             Fun.protect
               ~finally:Process_eio.reset_for_testing
               (fun () ->
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
                           ~initial_messages:[]
                           ~sw
                           ~net:(Eio.Stdenv.net env)
                           ()))))))
;;

let test_session_store_roundtrip_and_duplicate_claim () =
  let base_path = temp_workspace "masc-agy-store-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let usage : Runtime_antigravity_cli.usage =
         { input_tokens = 10
         ; output_tokens = 3
         ; thinking_tokens = 2
         ; cache_read_tokens = 4
         ; total_tokens = 13
         }
       in
       let claim =
         Keeper_antigravity_session_store.claim
           ~base_path
           ~keeper_name:"store"
           ~expected:None
           ~runtime_id:"antigravity.gemini-fixture"
           ~updated_at:1.0
         |> Result.get_ok
       in
       (match
          Keeper_antigravity_session_store.claim
            ~base_path
            ~keeper_name:"store"
            ~expected:(Some claim)
            ~runtime_id:claim.runtime_id
            ~updated_at:2.0
        with
        | Error _ -> ()
        | Ok _ -> fail "unsettled Antigravity claim admitted duplicate execution");
       let settled =
         Keeper_antigravity_session_store.settle
           ~base_path
           ~keeper_name:"store"
           ~expected:claim
           ~conversation_id
           ~usage
           ~updated_at:3.0
         |> Result.get_ok
       in
       match Keeper_antigravity_session_store.load ~base_path ~keeper_name:"store" with
       | Error detail -> fail detail
       | Ok None -> fail "settled Antigravity session disappeared"
       | Ok (Some loaded) ->
         check int "turn count" 1 loaded.turn_count;
         check bool "settled state" true (loaded = settled);
         check (option int) "measured input" (Some 10)
           (Option.map (fun usage -> usage.Runtime_antigravity_cli.input_tokens) loaded.last_usage))
;;

let test_keeper_start_resume_and_measured_observation () =
  let base_path = temp_workspace "masc-agy-keeper-" in
  let cli_path = fixture_script ~workspace:base_path in
  Fun.protect
    ~finally:(fun () -> Sys.remove cli_path; cleanup_tree base_path)
    (fun () ->
       let first =
         match run_turn ~base_path ~cli_path ~goal:"fixture start" with
         | Ok result -> result
         | Error error -> fail (Agent_sdk.Error.to_string error)
       in
       check string "first response" "MASC_AGY_KEEPER_START" (response_text first);
       check int "first turn" 1 first.turns;
       check string "conversation session" conversation_id first.session_id;
       (match first.response.usage with
        | None -> fail "provider-reported usage was dropped"
        | Some usage ->
          check int "input usage" 21 usage.input_tokens;
          check int "output usage" 4 usage.output_tokens;
          check int "cache usage" 7 usage.cache_read_input_tokens);
       (match first.runtime_observation with
        | None -> fail "measured runtime observation was not emitted"
        | Some observation ->
          List.iter
            (fun label ->
              check bool label true (List.mem label observation.configured_labels))
            [ "tool_owner=official_client"
            ; "execution_mode=plan_sandbox"
            ; "permission_mode=always-proceed"
            ; "tool_calls=1"
            ; "thinking_tokens=2"
            ]);
       let resumed =
         match run_turn ~base_path ~cli_path ~goal:"fixture resume" with
         | Ok result -> result
         | Error error -> fail (Agent_sdk.Error.to_string error)
       in
       check string "resume response" "MASC_AGY_KEEPER_RESUME" (response_text resumed);
       check int "resume turn" 2 resumed.turns;
       match Keeper_antigravity_session_store.load ~base_path ~keeper_name:"agy-fixture" with
       | Error detail -> fail detail
       | Ok None -> fail "resumed Antigravity session disappeared"
       | Ok (Some session) -> check int "stored turn count" 2 session.turn_count)
;;

let () =
  run
    "Keeper Antigravity official-client runtime"
    [ ( "durable session and dispatch"
      , [ test_case
            "session store roundtrip and duplicate claim"
            `Quick
            test_session_store_roundtrip_and_duplicate_claim
        ; test_case
            "start resume and measured observation"
            `Quick
            test_keeper_start_resume_and_measured_observation
        ] )
    ]
;;
