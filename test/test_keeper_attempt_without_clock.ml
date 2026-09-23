(* The attempt watchdog needs the clock in [Eio_context]. A process that
   has none never ran the attempt: [Runtime_agent.build] reads the same
   source and refuses the stream-idle budget the driver always declares
   when there is no clock to arm it. The driver refuses that condition one
   layer earlier, in the name of the deadline it could not set. This suite
   pins that refusal's name: without the driver's arm the same run ends in
   the runtime's refusal, field [stream_idle_timeout_s], nothing sent
   either way. It is the only driver suite that installs no clock --
   [Eio_main.run] alone does not -- so it is the one place that path is
   exercised. *)
open Alcotest
open Masc

let write path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel content)
;;

let test_a_process_without_a_clock_refuses_the_attempt () =
  check
    bool
    "the suite runs with no process clock"
    true
    (Option.is_none (Eio_context.get_clock_opt ()));
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let config_path = Filename.temp_file "keeper-attempt-without-clock-" ".toml" in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    try Sys.remove config_path with
    | Sys_error _ -> ());
  (* A live listener, so "nothing was sent" is a count and not an inference
     from a refused port. *)
  let server =
    Exact_output_fixture.start_server
      ~sw
      ~net:env#net
      ~clock:env#clock
      (Exact_output_fixture.Reply
         (Exact_output_fixture.openai_response (`Assoc [ "answer", `String "unreached" ])))
  in
  write
    config_path
    (Printf.sprintf
       {|[runtime]
default = "listener.sample"
[providers.listener]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "listener-model"
max-context = 200000
[listener.sample]
|}
       server.Exact_output_fixture.base_url);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> fail detail);
  let attempt_errors = ref [] in
  let result =
    Keeper_turn_driver.run_named ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
      ~system_prompt:"Attempt without a clock."
      ~runtime_id:"listener.sample"
      ~keeper_name:"attempt-without-clock"
      ~base_path:(Filename.get_temp_dir_name ())
      ~agent_core_tools:[]
      ~goal:"this must not be sent"
      ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ error ->
        attempt_errors := error :: !attempt_errors)
      ~sw
      ~net:env#net
      ()
  in
  let refused = function
    | Agent_core.Error.Config
        (Agent_core.Error.InvalidConfig { field = "provider_call_deadline_sec"; detail }) ->
      check
        bool
        "the refusal names the runtime and says nothing was sent"
        true
        (Astring.String.is_infix ~affix:"listener.sample" detail
         && Astring.String.is_infix ~affix:"nothing was sent" detail)
    | error ->
      failf
        "expected the typed no-clock refusal, got %s"
        (Agent_core.Error.to_string error)
  in
  (match result with
   | Ok _ -> fail "an attempt with no clock to bound it must not complete"
   | Error error -> refused error);
  (* Both refusals leave the provider untouched; the field above is what
     tells them apart. *)
  List.iter refused !attempt_errors;
  check int "no request reached the provider" 0 (Exact_output_fixture.post_count server)
;;

(* Any positive budget: the refusal is about the clock, not the size. *)
let declared_idle_budget_s = 30.0

(* The runtime reads the clock source the driver reads. A process whose only
   clock is [Process_eio]'s -- the child-process clock [Process_eio.init]
   installs -- is still a process with no clock for an attempt: the runtime
   refuses the stream-idle budget instead of arming it on a clock the
   driver's watchdog does not read. Until 2026-09-15 the runtime read
   [Process_eio] first and ran the attempt. Driven at the runtime, below the
   driver's own arm. *)
let test_a_process_with_only_the_child_process_clock_refuses_the_attempt () =
  check
    bool
    "the suite runs with no clock in Eio_context"
    true
    (Option.is_none (Eio_context.get_clock_opt ()));
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.on_release sw Process_eio.reset_for_testing;
  let server =
    Exact_output_fixture.start_server
      ~sw
      ~net:env#net
      ~clock:env#clock
      (Exact_output_fixture.Reply
         (Exact_output_fixture.openai_response (`Assoc [ "answer", `String "unreached" ])))
  in
  let config =
    Runtime_agent.default_config
      ~name:"child-process-clock-only"
      ~provider_cfg:
        (Llm_provider.Provider_config.make
           ~kind:Llm_provider.Provider_config.OpenAI_compat
           ~model_id:"listener-model"
           ~base_url:server.Exact_output_fixture.base_url
           ())
      ~system_prompt:"Attempt with only the child-process clock."
      ~tools:[]
  in
  let config = { config with Runtime_agent.stream_idle_timeout_s = Some declared_idle_budget_s } in
  (match Runtime_agent.run ~sw ~net:env#net ~config "this must not be sent" with
   | Ok _ -> fail "an attempt whose only clock is the child-process clock must not run"
   | Error
       (Agent_core.Error.Config
          (Agent_core.Error.InvalidConfig { field = "stream_idle_timeout_s"; _ })) -> ()
   | Error error ->
     failf "expected the runtime's no-clock refusal, got %s" (Agent_core.Error.to_string error));
  check int "no request reached the provider" 0 (Exact_output_fixture.post_count server)
;;

let () =
  Alcotest.run
    "keeper_attempt_without_clock"
    [ ( "run_named"
      , [ test_case
            "a process with no clock refuses the attempt before sending anything"
            `Quick
            test_a_process_without_a_clock_refuses_the_attempt
        ] )
    ; ( "runtime"
      , [ test_case
            "a process with only the child-process clock refuses the attempt"
            `Quick
            test_a_process_with_only_the_child_process_clock_refuses_the_attempt
        ] )
    ]
;;
