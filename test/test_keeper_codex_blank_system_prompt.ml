(* A blank composed developer-instructions string must not reach
   [Runtime_codex_app_server.config.developer_instructions] as [None]. [None]
   means "omit developerInstructions": the app-server starts the thread on
   Codex's own default instructions while masc's tool surface stays attached,
   a failure that looks like it is working. The refusal is checked on the
   typed [InvalidConfig] field rather than a substring of the detail, and
   against a working app-server fixture: the refusal has to land before spawn,
   so a spawn failure here would mean the check ran too late and a completed
   turn would mean it did not run at all. The non-blank control reads the
   thread/start request the fixture received and checks that its
   developerInstructions member is exactly the composed text, so the refusal
   added nothing to the admitted path. Mirrors the Claude Code case in
   [test_keeper_claude_code_runtime] (#33086). *)
open Alcotest
open Masc

let init_result =
  {|{"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
;;

let account_chatgpt =
  {|{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
;;

let thread_result =
  {|{"id":3,"result":{"thread":{"id":"thread-1"},"model":"gpt-fixture"}}|}
;;

let turn_result = {|{"id":4,"result":{"turn":{"id":"turn-1"}}}|}

let item_completed =
  {|{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"type":"agentMessage","id":"message-1","text":"MASC_FIXTURE_OK","phase":"final_answer"}}}|}
;;

let turn_completed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[{"type":"agentMessage","id":"message-1","text":"MASC_FIXTURE_OK","phase":"final_answer"}],"status":"completed"}}}|}
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

(* Positional app-server fixture in the request order
   [test_runtime_codex_app_server] drives: initialize, the initialized
   notification, account/read, thread/start, turn/start. A fresh thread with
   no history sends no thread/inject_items, so turn/start carries id 4. Every
   request line is appended to [capture_path] before it is answered, which is
   what the control case reads back. *)
let fixture_script ~base_path ~capture_path =
  let path = Filename.concat base_path "codex-fixture.sh" in
  let output = open_out_bin path in
  let read_request () =
    output_string output "IFS= read -r request\n";
    output_string
      output
      ("printf '%s\\n' \"$request\" >> " ^ shell_quote capture_path ^ "\n")
  in
  let emit line =
    output_string output ("printf '%s\\n' " ^ shell_quote line ^ "\n")
  in
  output_string output "#!/bin/sh\n";
  output_string output "case \"$1\" in --masc-warmup) exit 0 ;; esac\n";
  read_request ();
  emit init_result;
  read_request ();
  read_request ();
  emit account_chatgpt;
  read_request ();
  emit thread_result;
  read_request ();
  emit turn_result;
  emit item_completed;
  emit turn_completed;
  output_string output "while IFS= read -r ignored; do :; done\n";
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let runtime_toml cli_path =
  Printf.sprintf
    "[providers.codex]\n\
     protocol = \"codex-app-server\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [models.codex]\n\
     api-name = \"codex-fixture\"\n\
     max-context = 400000\n\
     \n\
     [codex.codex]\n\
     \n\
     [runtime]\n\
     default = \"codex.codex\"\n"
    cli_path
;;

let temp_workspace () =
  let path = Filename.temp_file "masc-keeper-codex-blank-prompt-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  Unix.mkdir (Filename.concat path ".masc") 0o700;
  path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let write_file path contents =
  let output = open_out_bin path in
  output_string output contents;
  close_out output
;;

let run_direct_attempt ~system_prompt ~base_path ~cli_path ~on_transmitted_model_input =
  let runtime_path = Filename.concat base_path "runtime.toml" in
  write_file runtime_path (runtime_toml cli_path);
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
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
                  match Runtime.get_runtime_by_id "codex.codex" with
                  | Some
                      { Runtime.execution =
                          Runtime_execution.Codex_app_server config
                      ; _
                      } ->
                    config
                  | Some _ | None -> fail "Codex runtime fixture did not resolve"
                in
                Keeper_codex_runtime.run
                  ~runtime_id:"codex.codex"
                  ~keeper_name:"codex-blank-prompt"
                  ~pre_tool_rejects:(ref [])
                  ~base_path
                  ~goal:"Return the fixture marker"
                  ~goal_blocks:None
                  ~system_prompt
                  ~tools:[]
                  ~initial_messages:[]
                  ~model_input_projection:None
                  ~on_transmitted_model_input
                  ~hooks:None
                  ~context_injector:None
                  ~context:(Some (Agent_core.Context.create ()))
                  ~event_bus:None
                  ~raw_trace:None
                  ~on_event:None
                  ~config
                  ()))))
;;

let test_blank_system_prompt_is_refused_not_defaulted () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let capture_path = Filename.concat base_path "requests.jsonl" in
       let cli_path = fixture_script ~base_path ~capture_path in
       let reports = ref 0 in
       let attempt =
         run_direct_attempt
           ~system_prompt:"   "
           ~base_path
           ~cli_path
           ~on_transmitted_model_input:(fun _ -> incr reports)
       in
       (match attempt.Keeper_codex_runtime.result with
        | Error
            (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; _ }))
          -> check string "refused field" "system_prompt" field
        | Error error ->
          fail
            ("blank system prompt produced the wrong error: "
             ^ Agent_core.Error.to_string error)
        | Ok _ -> fail "blank system prompt was sent as the client default");
       check
         bool
         "the app-server was never spawned"
         false
         (Sys.file_exists capture_path);
       (* A refused turn transmits nothing; recording it as a whole-input
          transmission would be masc#32995's zero-bytes misreading flipped. *)
       check int "a refused turn reports no transmitted input" 0 !reports)
;;

let thread_start_request capture_path =
  let input = open_in capture_path in
  let lines =
    Fun.protect ~finally:(fun () -> close_in input) (fun () ->
      In_channel.input_lines input)
  in
  List.find_map
    (fun line ->
       match Yojson.Safe.from_string line with
       | `Assoc fields ->
         (match List.assoc_opt "method" fields with
          | Some (`String "thread/start") -> Some (`Assoc fields)
          | Some _ | None -> None)
       | _ -> None)
    lines
;;

let test_non_blank_system_prompt_reaches_thread_start_unchanged () =
  let base_path = temp_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let capture_path = Filename.concat base_path "requests.jsonl" in
       let cli_path = fixture_script ~base_path ~capture_path in
       let system_prompt = "keeper fixture system prompt" in
       let attempt =
         run_direct_attempt
           ~system_prompt
           ~base_path
           ~cli_path
           ~on_transmitted_model_input:(fun _ -> ())
       in
       (match attempt.Keeper_codex_runtime.result with
        | Error
            (Agent_core.Error.Config
               (Agent_core.Error.InvalidConfig { field = "system_prompt"; detail }))
          -> fail ("a non-blank system prompt was refused: " ^ detail)
        | Error _ | Ok _ -> ());
       check
         bool
         "the app-server was spawned"
         true
         (Sys.file_exists capture_path);
       match thread_start_request capture_path with
       | None -> fail "the fixture received no thread/start request"
       | Some request ->
         (* The composition is the keeper prompt followed by the native
            posture note the default posture appends, joined the way the
            runtime joins them. Computed from the same producers so the check
            is exact rather than a substring. *)
         let expected =
           String.concat
             "\n\n"
             (system_prompt
              :: Keeper_codex_runtime.For_testing.native_posture_note
                   Runtime_native_tools.codex_default)
         in
         let received =
           Yojson.Safe.Util.(
             request |> member "params" |> member "developerInstructions")
         in
         (match received with
          | `String text ->
            check string "developerInstructions is the composition" expected text
          | other ->
            fail
              ("developerInstructions was not a string: "
               ^ Yojson.Safe.to_string other)))
;;

let () =
  run
    "keeper_codex_blank_system_prompt"
    [ ( "developer instructions"
      , [ test_case
            "blank system prompt is refused not defaulted"
            `Quick
            test_blank_system_prompt_is_refused_not_defaulted
        ; test_case
            "non-blank system prompt reaches thread/start unchanged"
            `Quick
            test_non_blank_system_prompt_reaches_thread_start_unchanged
        ] )
    ]
;;
