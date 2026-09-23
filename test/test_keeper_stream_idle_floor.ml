(* The stream idle bound is keeper policy: [Keeper_turn_driver.run_named]
   reads the resolved value itself, so no caller can leave a turn without
   one. The proof drives a turn through [run_named] with nothing said about
   timeouts at the call site, against a loopback provider that streams one
   answer delta and then goes quiet, and watches the typed stream-idle
   timeout end the attempt at the resolved bound. *)
open Alcotest
open Masc

let write path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel content)
;;

let rec remove path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

(* The idle bound the case installs as the operator's value. Long enough
   that scheduler jitter cannot fire it before the first delta is read,
   short enough that the case ends well inside the fixture budget. *)
let idle_bound_s = 0.5

(* One OpenAI-compatible answer delta. Once it is read the stream is past
   its first output, so the deadline that ends the wait afterwards is the
   inter-line idle bound, not the first-event one. *)
let first_answer_delta =
  "data: {\"id\":\"stall-1\",\"object\":\"chat.completion.chunk\",\"model\":\"stall-model\",\
   \"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\
   \"finish_reason\":null}]}\n\n"
;;

let stream_idle_timeout_after_the_first_delta = function
  | Agent_core.Error.Provider
      (Llm_provider.Error.Timeout
         { timeout_phase =
             Some
               (Llm_provider.Http_client.Stream_idle
                  Llm_provider.Http_client.Streaming_answer)
         ; _
         }) ->
    true
  | _ -> false
;;

let test_idle_bound_reaches_a_turn_that_named_none () =
  match Sys.getenv_opt Env_config_keeper.KeeperKeepalive.stream_idle_timeout_env_key with
  | Some _ ->
    (* An ambient operator value would replace the bound this case installs. *)
    skip ()
  | None ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let runtime_snapshot = Runtime.For_testing.snapshot () in
    let base_path = Filename.temp_dir "keeper-stream-idle-floor-" "" in
    Config_boot_overrides.reset_for_tests ();
    Keeper_runtime_resolved.reset_for_tests ();
    Eio.Switch.on_release sw (fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Config_boot_overrides.reset_for_tests ();
      Keeper_runtime_resolved.reset_for_tests ();
      remove base_path);
    (* Provider: one delta, then silence. *)
    let server =
      Exact_output_fixture.start_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        (Exact_output_fixture.Stream_then_stall first_answer_delta)
    in
    (* One workspace runtime.toml, as an operator writes it: the provider,
       the model, the [stall.sample] binding that makes them a runtime, and
       under [turn] the idle bound. The runtime half feeds the runtime
       registry; the [turn] half feeds the resolved layer that run_named
       reads. *)
    let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
    Fs_compat.mkdir_p (Filename.dirname config_path);
    write
      config_path
      (Printf.sprintf
         {|[runtime]
default = "stall.sample"
[providers.stall]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "stall-model"
max-context = 200000
streaming = true
[stall.sample]
[turn]
stream_idle_timeout_sec = %g
|}
         server.Exact_output_fixture.base_url
         idle_bound_s);
    (match Runtime.init_default ~config_path with
     | Ok () -> ()
     | Error detail -> fail detail);
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Ok applied -> check int "the idle bound is the one applied override" 1 applied
     | Error failure -> fail (Keeper_runtime_config.load_failure_to_string failure));
    Keeper_runtime_resolved.reset_for_tests ();
    check
      (float 0.0001)
      "the resolved layer serves the installed bound"
      idle_bound_s
      (Keeper_runtime_resolved.stream_idle_timeout_sec ());
    let attempt_errors = ref [] in
    let started = Unix.gettimeofday () in
    (* Under the fixture budget: a turn the idle bound does not end would
       otherwise hang on the attempt watchdog until the runner kills the
       suite, a failure with no name. *)
    let result =
      Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
        Keeper_turn_driver.run_named ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
          ~system_prompt:"Stream idle bound proof."
          ~runtime_id:"stall.sample"
          ~keeper_name:"stream-idle-bound-proof"
          ~base_path
          ~agent_core_tools:[]
          ~goal:"answer, then stop mid-stream"
          ~on_event:(fun _ -> ())
          ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ error ->
            attempt_errors := error :: !attempt_errors)
          ~sw
          ~net:env#net
          ())
    in
    let elapsed_s = Unix.gettimeofday () -. started in
    check bool "the turn does not complete on a stalled stream" true (Result.is_error result);
    check
      bool
      "the request reached the provider"
      true
      (Exact_output_fixture.post_count server >= 1);
    check bool "at least one provider attempt was observed" true (!attempt_errors <> []);
    List.iter
      (fun error ->
         if not (stream_idle_timeout_after_the_first_delta error)
         then
           failf
             "expected the stream-idle timeout after the first answer delta, got %s"
             (Agent_core.Error.to_string error))
      !attempt_errors;
    check
      bool
      (Printf.sprintf
         "the turn ended by the installed bound, not the fixture budget (%.2fs)"
         elapsed_s)
      true
      (elapsed_s >= idle_bound_s && elapsed_s < Exact_output_fixture.fixture_wait_seconds)
;;

let () =
  Alcotest.run
    "keeper_stream_idle_floor"
    [ ( "run_named"
      , [ test_case
            "a turn that names no timeout is still bound by the resolved stream idle value"
            `Quick
            test_idle_bound_reaches_a_turn_that_named_none
        ] )
    ]
;;
