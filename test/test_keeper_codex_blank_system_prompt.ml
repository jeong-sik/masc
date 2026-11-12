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

let with_direct_attempt ~base_path ~cli_path body =
  let runtime_path = Filename.concat base_path "runtime.toml" in
  write_file runtime_path (runtime_toml cli_path);
  (* #36066: the posture resolve reads the keeper's declaration before the
     blank-prompt check, so the fixture keeper is declared. *)
  Masc_test_deps.declare_fixture_keeper
    ~base_path ~sandbox_profile:None "codex-blank-prompt";
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
                let runtime = Runtime.get_runtime_by_id "codex.codex" |> Option.get in
                let config =
                  match runtime.Runtime_instance.execution with
                  | Runtime_execution.Codex_app_server config -> config
                  | Agent_core _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
                    fail "Codex runtime fixture did not resolve"
                in
                let attempt ?on_guidance_prepared ~system_prompt ~on_transmitted_model_input () =
                Keeper_codex_runtime.run ~outbox_viewer:Keeper_client_tool_outbox.Unowned_only ?on_guidance_prepared
                  ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "codex-blank-prompt" })
                  ~context_window:(Some (Runtime_instance.max_context_of_runtime runtime))
                  ~configured_reasoning_effort:runtime.model.reasoning_effort
                  ~turn_timeout_s:runtime.model.turn_timeout_s
                  ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input ~runtime)
                  ~runtime_id:"codex.codex"
                  ~keeper_name:"codex-blank-prompt"
                  ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
                  ~pre_tool_rejects:(ref [])
                  ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
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
                  ~account:(Masc_test_deps.authorized_account config.account_home)
                  ~config
                  () in
                body ~sw ~attempt))))
;;

let run_direct_attempt ~system_prompt ~base_path ~cli_path ~on_transmitted_model_input =
  with_direct_attempt ~base_path ~cli_path (fun ~sw:_ ~attempt ->
    attempt ~system_prompt ~on_transmitted_model_input ())
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
  let key = Prompt_names.keeper_codex_native_read in
  let previous = (Prompt_registry.resolve_prompt key).override_value in
  let posture_note = "CODEX_POSTURE_FROM_MANAGED_OVERRIDE" in
  (match Prompt_registry.set_override key posture_note with
   | Ok () -> () | Error detail -> fail detail);
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some value ->
         (match Prompt_registry.set_override key value with
          | Ok () -> () | Error detail -> fail detail)
       | None -> Prompt_registry.clear_prompt_override key);
      cleanup_tree base_path)
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
            posture note the default posture appends and the frozen Librarian
            unread observation every request carries (unavailable here: the
            fixture has no snapshot or Memory reader), joined the way the
            runtime joins them. Computed from the same producers so the check
            is exact rather than a substring. *)
         let unread_observation =
           let unread =
             Keeper_librarian_request_unread.of_results
               ~snapshot:(Error "fixture has no snapshot reader")
               ~memory:(Error "fixture has no Memory reader")
           in
           match
             Keeper_librarian_request_unread.attach
               ~include_empty:true
               ~role:Agent_core.Types.System
               unread
               []
           with
           | [carrier] -> Keeper_official_client_host.encode_history_message carrier
           | [] | _ :: _ :: _ -> fail "an unread observation must have one carrier"
         in
         let expected =
           String.concat
             "\n\n"
             [ system_prompt; posture_note; unread_observation ]
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

let test_missing_native_guidance_refuses_before_spawn () =
  let base_path = temp_workspace () in
  let key = Prompt_names.keeper_codex_native_read in
  let previous = (Prompt_registry.resolve_prompt key).override_value in
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
      (match previous with Some value -> Prompt_registry.set_override key value |> Result.get_ok
       | None -> Prompt_registry.clear_prompt_override key);
      cleanup_tree base_path)
    (fun () ->
      let empty = Filename.concat base_path "missing-guidance" in
      Unix.mkdir empty 0o700;
      Prompt_registry.clear_prompt_override key;
      Prompt_registry.set_markdown_dir empty;
      let capture_path = Filename.concat base_path "requests.jsonl" in
      let cli_path = fixture_script ~base_path ~capture_path in
      let transmissions = ref 0 in
      let attempt = run_direct_attempt ~system_prompt:"current keeper instructions" ~base_path ~cli_path
          ~on_transmitted_model_input:(fun _ -> incr transmissions) in
      (match attempt.Keeper_codex_runtime.result with
       | Error error -> check bool "actual Codex adapter returns positive preparation failure" true
           (Option.is_some (Keeper_internal_error.guidance_preparation_failure error))
       | Ok _ -> fail "missing guidance dispatched Codex");
      check bool "no app-server was spawned" false (Sys.file_exists capture_path);
      check int "no model input was transmitted" 0 !transmissions)
;;

let test_core_checkpoint_survives_codex_guidance_failure () =
  let module Owner = Keeper_owner in
  let module Semantic = Keeper_semantic_execution in
  let module Operation = Keeper_chat_operation in
  let base_path = temp_workspace () in
  let key = Prompt_names.keeper_codex_native_read in
  let previous = (Prompt_registry.resolve_prompt key).override_value in
  let original_prompt_dir = Prompt_registry.get_markdown_dir ()
    |> Option.value ~default:(Masc_test_deps.source_path "config/prompts") in
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.set_markdown_dir original_prompt_dir;
      (match previous with Some value -> Prompt_registry.set_override key value |> Result.get_ok
       | None -> Prompt_registry.clear_prompt_override key);
      cleanup_tree base_path)
    (fun () ->
      let missing = Filename.concat base_path "missing-guidance" in
      Unix.mkdir missing 0o700;
      Prompt_registry.clear_prompt_override key;
      Prompt_registry.set_markdown_dir missing;
      let capture_path = Filename.concat base_path "requests.jsonl" in
      let cli_path = fixture_script ~base_path ~capture_path in
      with_direct_attempt ~base_path ~cli_path (fun ~sw ~attempt ->
        let require = function Ok value -> value | Error error -> fail (Owner.error_to_string error) in
        let id = Operation.Operation_id.of_string "core-checkpoint-codex-guidance" |> Result.get_ok in
        let trace_id = Keeper_id.Trace_id.of_string "original-core-trace" |> Result.get_ok in
        let reference = Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count:1
            ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes "original cooperative checkpoint")
          |> function Ok value -> value | Error _ -> fail "original Core checkpoint fixture" in
        let checkpoint = Semantic.Agent_core reference in
        let input = `Assoc ["message",`String "Return the fixture marker";
          "instructions",`String "original operation authority"]
          |> Operation.canonical_json |> Result.get_ok in
        let owner_p, publish_owner = Eio.Promise.create () in
        let blocked, publish_blocked = Eio.Promise.create () in
        let finished, publish_finished = Eio.Promise.create () in
        let require_settlement = function Ok () -> () | Error detail -> fail detail in
        let attempts = ref 0 and entries = ref 0 and transmissions = ref 0 in
        let assert_original owner =
          let original = Owner.exact_operation owner id |> require |> Option.get in
          check bool "original operation input is retained" true (original.input=Some input);
          check bool "original cooperative checkpoint is retained" true
            (Option.equal Semantic.equal_gate_checkpoint (Some checkpoint)
              (Owner.direct_checkpoint owner ~operation_id:id |> require)) in
        let execute ~sw:_ ~keeper_name:_ ~claim =
          let owner = Eio.Promise.await owner_p in
          let operation : Operation.t = claim () |> require |> Option.get in
          incr attempts;
          match !attempts with
          | 1 ->
            Owner.defer_direct_checkpoint owner ~operation_id:id ~execution_digest:operation.execution_digest
              ~checkpoint |> require |> ignore;
            Owner.Operation_deferred
          | 2 | 3 ->
            assert_original owner;
            let run = attempt ~system_prompt:"current keeper instructions"
                ~on_guidance_prepared:(fun () ->
                  incr entries;
                  Owner.resume_direct_checkpoint owner ~operation_id:id ~observed:checkpoint
                  |> Result.map_error (fun error -> Agent_core.Error.Internal (Owner.error_to_string error)))
                ~on_transmitted_model_input:(fun _ -> incr transmissions) () in
            (match !attempts,run.Keeper_codex_runtime.result with
             | 2, Error error ->
               check bool "Codex native-read failure has positive preparation authority" true
                 (Option.is_some (Keeper_internal_error.guidance_preparation_failure error));
               check int "failed guidance does not consume the checkpoint" 0 !entries;
               check int "failed guidance transmits no input" 0 !transmissions;
               check bool "failed guidance spawns no app-server" false (Sys.file_exists capture_path);
               Owner.wait_direct_preparation owner ~operation_id:id
                 ~execution_digest:operation.execution_digest ~observed:checkpoint ~failure:error
                 |> require |> ignore;
               Owner.Operation_deferred
             | 3, Ok _ -> Owner.Operation_succeeded {outcome_ref="original Core continuation completed"}
             | _, Error error -> fail (Agent_core.Error.to_string error)
             | _, Ok _ -> fail "missing guidance unexpectedly dispatched Codex")
          | _ -> fail "blocked Core checkpoint was automatically retried" in
        let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
          "name",`String "codex-blank-prompt";"trace_id",`String "codex-blank-prompt";
          "activation_mode",`String "manual"]) |> Result.get_ok in
        let owner = Owner.start ~base_path ~sw ~keeper_name:meta.name ~initial_meta:(Some meta)
            ~store:{replace=(fun _ -> Ok ());remove=(fun _ -> Ok ())}
            ~operation_store_path:(Filename.concat base_path "operations.sqlite3")
            ~session_root:(Filename.concat base_path "traces") ~now:(fun () -> 42.)
            ~on_turn_slot_released:None
            ~operation_runner:(Some Owner.{ready=(fun ~keeper_name:_ -> true);execute;
              on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution ->
                match !attempts,execution with
                | 1,Operation_deferred -> ()
                | 2,Operation_deferred -> Eio.Promise.resolve publish_blocked (Ok ())
                | 3,Operation_succeeded _ -> Eio.Promise.resolve publish_finished (Ok ())
                | attempt,execution ->
                  let detail = match execution with
                    | Operation_failed {detail;_} -> detail
                    | Operation_deferred -> "unexpected checkpoint deferral"
                    | Operation_succeeded _ -> "unexpected operation success" in
                  Eio.Promise.resolve
                    (if attempt < 3 then publish_blocked else publish_finished)
                    (Error (Printf.sprintf "Codex checkpoint attempt %d failed: %s" attempt detail)))}) |> require in
        Eio.Promise.resolve publish_owner owner;
        Owner.submit_operation owner ~operation_id:id ~source:(`Assoc ["surface",`String "test"])
          ~input |> require |> ignore;
        Eio.Promise.await blocked |> require_settlement;
        let waiting = Owner.direct_preparation_wait owner ~operation_id:id |> require |> Option.get in
        assert_original owner;
        check bool "waiting checkpoint keeps its Core identity" true
          (Semantic.equal_gate_checkpoint checkpoint waiting.waiting.checkpoint);
        Owner.wake_operation_drain owner |> require;
        check int "ordinary drain cannot retry missing guidance" 2 !attempts;
        Prompt_registry.set_markdown_dir original_prompt_dir;
        Owner.retry_direct_preparation owner ~operation_id:id ~expected_revision:waiting.revision
          ~execution_digest:waiting.execution_digest |> require |> ignore;
        Eio.Promise.await finished |> require_settlement;
        check int "explicit retry enters Codex once" 1 !entries;
        check int "explicit retry transmits the original operation once" 1 !transmissions;
        check int "only one explicit retry ran" 3 !attempts;
        let completed = Owner.exact_operation owner id |> require |> Option.get in
        check string "same operation completes" "succeeded" (Operation.state_to_string completed.state);
        Owner.begin_stopping owner |> require |> ignore))
;;

let () =
  run
    "keeper_codex_blank_system_prompt"
    [ ( "developer instructions"
      , [ test_case "missing guidance refuses before app-server spawn" `Quick
            test_missing_native_guidance_refuses_before_spawn
        ; test_case "Core checkpoint survives Codex guidance failure and explicit retry" `Quick
            test_core_checkpoint_survives_codex_guidance_failure
        ; test_case
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
