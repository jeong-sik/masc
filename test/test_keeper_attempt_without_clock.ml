(* The attempt watchdog needs the process clock. A process that has none
   used to run the attempt anyway, with no MASC-side bound at all: the one
   silent way left for a keeper turn to wait forever. It is now refused
   before anything is sent, with a typed configuration error. This suite is
   the only driver suite that installs no clock -- [Eio_main.run] alone does
   not -- so it is the one place that path is exercised. *)
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
max-context = 8192
[listener.sample]
|}
       server.Exact_output_fixture.base_url);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> fail detail);
  let attempt_errors = ref [] in
  let result =
    Keeper_turn_driver.run_named
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
  List.iter refused !attempt_errors;
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
    ]
;;
