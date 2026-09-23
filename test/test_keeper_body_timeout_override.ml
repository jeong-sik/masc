(* The non-streaming body deadline is the operator's override, read by
   [Keeper_turn_driver.run_named] itself from the resolved layer: no caller
   can leave a turn without it once the operator declared one. The proof
   drives a non-streaming turn through [run_named] with nothing said about
   timeouts at the call site, against a loopback endpoint that accepts the
   request and never answers, with the override declared as the operator
   declares it, and watches the typed timeout end the attempt at the
   declared value. The declared range's lower bound is ten seconds, so the
   case is slow by construction. *)
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

(* [Unix] has no unsetenv, and an empty value is not an absent one: the
   timeout readers reject "" as malformed. The stub removes the variable, so
   the case leaves the process environment as it found it. *)
external unsetenv : string -> unit = "masc_test_unsetenv"

(* The shortest override the setting admits; paid once. *)
let declared_body_timeout_s = Env_config_keeper.KeeperKeepalive.body_timeout_min_sec

(* How far past the declared value the verdict may arrive: a loaded runner's
   scheduling and the socket teardown. Well under the ten seconds the case
   already waits, so a second full window would still show. *)
let slack_s = 2.5

let start_silent_listener ~sw ~net =
  let listening =
    Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let accepted = Atomic.make 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun flow _addr ->
      Atomic.incr accepted;
      let buf = Cstruct.create 4096 in
      try
        while true do
          ignore (Eio.Flow.single_read flow buf)
        done
      with
      | End_of_file | Eio.Io _ -> ());
    `Stop_daemon);
  match Eio.Net.listening_addr listening with
  | `Tcp (_, port) -> port, accepted
  | `Unix _ -> fail "expected a TCP listening socket"
;;

let test_the_declared_body_timeout_reaches_a_turn_that_named_none () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let base_path = Filename.temp_dir "keeper-body-timeout-override-" "" in
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  let inherited_body_timeout = Sys.getenv_opt "MASC_KEEPER_BODY_TIMEOUT_SEC" in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    Config_boot_overrides.reset_for_tests ();
    Keeper_runtime_resolved.reset_for_tests ();
    (match inherited_body_timeout with
     | Some value -> Unix.putenv "MASC_KEEPER_BODY_TIMEOUT_SEC" value
     | None -> unsetenv "MASC_KEEPER_BODY_TIMEOUT_SEC");
    remove base_path);
  let port, accepted = start_silent_listener ~sw ~net:env#net in
  let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname config_path);
  write
    config_path
    (Printf.sprintf
       {|[runtime]
default = "silent.sample"
[providers.silent]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d"
[models.sample]
api-name = "silent-model"
max-context = 200000
[silent.sample]
|}
       port);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> fail detail);
  (* The override is declared the way the operator declares it: the setting
     has no runtime.toml key, so the boot never writes it as an override and
     the process environment is its only channel. Setting it there also
     covers whatever the shell running this suite inherited. *)
  Unix.putenv "MASC_KEEPER_BODY_TIMEOUT_SEC" (Printf.sprintf "%g" declared_body_timeout_s);
  Keeper_runtime_resolved.reset_for_tests ();
  check
    (option (float 0.0001))
    "the resolved layer serves the declared override"
    (Some declared_body_timeout_s)
    (Keeper_runtime_resolved.body_timeout_override_sec ());
  let attempt_errors = ref [] in
  let started = Unix.gettimeofday () in
  let result =
    Keeper_turn_driver.run_named ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
      ~system_prompt:"Body timeout override proof."
      ~runtime_id:"silent.sample"
      ~keeper_name:"body-timeout-override-proof"
      ~base_path
      ~agent_core_tools:[]
      ~goal:"ask, and hear nothing back"
      ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ error ->
        attempt_errors := error :: !attempt_errors)
      ~sw
      ~net:env#net
      ()
  in
  let elapsed_s = Unix.gettimeofday () -. started in
  check bool "the turn does not complete on a silent endpoint" true (Result.is_error result);
  check bool "the request reached the endpoint" true (Atomic.get accepted >= 1);
  check bool "at least one provider attempt was observed" true (!attempt_errors <> []);
  List.iter
    (fun error ->
       match error with
       (* A keeper turn hands Agent Core its own transport, so the body
          deadline wraps that transport's round trip and reports the
          non-streaming body phase. *)
       | Agent_core.Error.Provider
           (Llm_provider.Error.Timeout
              { timeout_phase = Some Llm_provider.Http_client.Non_streaming_body; _ })
         -> ()
       | error ->
         failf
           "expected the declared body deadline to end the attempt, got %s"
           (Agent_core.Error.to_string error))
    !attempt_errors;
  check
    bool
    (Printf.sprintf "the attempt ended at the declared override (%.2fs)" elapsed_s)
    true
    (elapsed_s >= declared_body_timeout_s && elapsed_s < declared_body_timeout_s +. slack_s)
;;

let () =
  Alcotest.run
    "keeper_body_timeout_override"
    [ ( "run_named"
      , [ test_case
            "a non-streaming turn that names no timeout is bound by the declared body override"
            `Slow
            test_the_declared_body_timeout_reaches_a_turn_that_named_none
        ] )
    ]
;;
