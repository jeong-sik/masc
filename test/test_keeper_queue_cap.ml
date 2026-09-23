(* A keeper turn queued behind another caller's admission permit ends as a
   [Queue] timeout at the keeper's provider-call deadline, with nothing sent.
   Two things make that so, and this proof needs both: the driver hands
   Agent Core the deadline as the stream's admission bound (#36232), and the
   attempt watchdog stands down while Agent Core reports a bounded permit
   wait, so the admission bound alone ends the wait and the record says
   [Queue] rather than whichever clock fired first. The proof drives a
   streaming turn through [Keeper_turn_driver.run_named] on a binding with
   one permit, held by another fiber for the whole case, with the deadline
   declared at the shortest value the setting admits, and reads the typed
   timeout and the elapsed time. The declared range's lower bound is thirty
   seconds, so the case is slow by construction. *)
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

(* The shortest deadline the setting admits; paid once. *)
let declared_deadline_s = Env_config_keeper.KeeperKeepalive.provider_call_deadline_min_sec

(* Scheduling on a loaded runner; the wait itself is exact to the deadline. *)
let deadline_slack_s = 5.0

let queue_timeout = function
  | Agent_core.Error.Provider
      (Llm_provider.Error.Timeout
         { timeout_phase = Some Llm_provider.Http_client.Queue; _ }) -> true
  | _ -> false
;;

let test_a_turn_queued_behind_a_held_permit_ends_as_queue () =
  match Sys.getenv_opt Env_config_keeper.KeeperKeepalive.provider_call_deadline_env_key with
  | Some _ ->
    (* An ambient operator value outranks the deadline this case declares. *)
    skip ()
  | None ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let runtime_snapshot = Runtime.For_testing.snapshot () in
    let base_path = Filename.temp_dir "keeper-queue-cap-" "" in
    Config_boot_overrides.reset_for_tests ();
    Keeper_runtime_resolved.reset_for_tests ();
    Eio.Switch.on_release sw (fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Config_boot_overrides.reset_for_tests ();
      Keeper_runtime_resolved.reset_for_tests ();
      remove base_path);
    (* A provider that would answer, and must never be asked. *)
    let server =
      Exact_output_fixture.start_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        (Exact_output_fixture.Reply "{}")
    in
    let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
    Fs_compat.mkdir_p (Filename.dirname config_path);
    write
      config_path
      (Printf.sprintf
         {|[runtime]
default = "busy.sample"
[providers.busy]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "busy-model"
max-context = 200000
streaming = true
[busy.sample]
max-concurrent = 1
[turn]
provider_call_deadline_sec = %g
|}
         server.Exact_output_fixture.base_url
         declared_deadline_s);
    (match Runtime.init_default ~config_path with
     | Ok () -> ()
     | Error detail -> fail detail);
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Ok applied -> check int "the deadline is the one applied override" 1 applied
     | Error failure -> fail (Keeper_runtime_config.load_failure_to_string failure));
    Keeper_runtime_resolved.reset_for_tests ();
    check
      (float 0.0001)
      "the resolved layer serves the declared deadline"
      declared_deadline_s
      (Keeper_runtime_resolved.provider_call_deadline_sec ());
    (* The binding's one permit, held for the whole case by a caller with
       the same endpoint identity the keeper's turn resolves to: kind, the
       normalised endpoint, and no credential. *)
    let holder_config =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~model_id:"busy-model"
        ~base_url:
          (Masc_network_defaults.normalize_loopback_base_url
             server.Exact_output_fixture.base_url)
        ~api_key:""
        ~max_concurrent_requests:1
        ()
    in
    let release, resolve_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Llm_provider.Provider_admission.with_admission ~config:holder_config (fun () ->
        Eio.Promise.await release));
    let attempt_errors = ref [] in
    let started = Unix.gettimeofday () in
    let result =
      Eio.Time.with_timeout_exn
        env#clock
        (declared_deadline_s +. Exact_output_fixture.fixture_wait_seconds)
        (fun () ->
           Keeper_turn_driver.run_named ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
             ~system_prompt:"Queue cap proof."
             ~runtime_id:"busy.sample"
             ~keeper_name:"queue-cap-proof"
             ~base_path
             ~agent_core_tools:[]
             ~goal:"wait for a permit that never comes"
             ~on_event:(fun _ -> ())
             ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ error ->
               attempt_errors := error :: !attempt_errors)
             ~sw
             ~net:env#net
             ())
    in
    let elapsed_s = Unix.gettimeofday () -. started in
    Eio.Promise.resolve resolve_release ();
    check bool "the turn does not complete behind a held permit" true (Result.is_error result);
    check int "nothing reached the provider" 0 (Exact_output_fixture.post_count server);
    check bool "at least one provider attempt was observed" true (!attempt_errors <> []);
    List.iter
      (fun error ->
         if not (queue_timeout error)
         then
           failf
             "expected the queue timeout at the keeper's deadline, got %s"
             (Agent_core.Error.to_string error))
      !attempt_errors;
    check
      bool
      (Printf.sprintf "the wait ended at the declared deadline (%.2fs)" elapsed_s)
      true
      (elapsed_s >= declared_deadline_s && elapsed_s < declared_deadline_s +. deadline_slack_s);
    (match Llm_provider.Provider_admission.snapshot_for ~config:holder_config with
     | Some snapshot ->
       check
         int
         "the expired waiter left the queue"
         0
         snapshot.Llm_provider.Slot_scheduler.queue_length
     | None -> fail "the keeper's turn and the holder must share one scheduler")
;;

let () =
  Alcotest.run
    "keeper_queue_cap"
    [ ( "run_named"
      , [ test_case
            "a turn queued behind a held permit ends as Queue at the keeper's deadline"
            `Slow
            test_a_turn_queued_behind_a_held_permit_ends_as_queue
        ] )
    ]
;;
