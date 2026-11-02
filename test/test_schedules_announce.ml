(** A workspace's schedules announce each change, and a reader that answers
    the announcement sees it: a schedule written to the store is on the fleet
    schedule list read when its write is heard, though the list was cached
    before the write, and a runner tick is on it once its outcome is heard. A
    tick that leaves the list as it was is not announced, unless the list was
    read while the tick ran.
    The moment the runner's status turns with nothing recorded, its staleness
    deadline, is announced once. *)

open Alcotest

let actor : Schedule_domain.actor =
  { id = "test"; kind = Schedule_domain.Human_operator; display_name = None }

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    Schedule_store.install_change_observer (fun ~base_path:_ -> ());
    Dashboard_cache.invalidate_all ();
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
          (fun () ->
            let state = Masc.Mcp_server.For_testing.create_state ~base_path in
            let config = Masc.Mcp_server.workspace_config state in
            ignore (Workspace_core.init config ~agent_name:(Some "test"));
            Server_schedule_broadcast.install_store_announcer ~sw;
            f (Eio.Stdenv.clock env) config))))

let is_change frame =
  match Masc.Sse.data_payload_of_frame frame with
  | Error Masc.Sse.Missing_data_payload -> false
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       List.assoc_opt "type" fields = Some (`String Server_schedule_broadcast.changed_event)
     | _ -> false
     | exception Yojson.Json_error _ -> false)

(* Calls [f] with a list that gains [read ()] each time a change is heard. *)
let hearing ~read f =
  let id = Printf.sprintf "schedules-announce-%d" (Unix.getpid ()) in
  let heard = ref [] in
  Masc.Sse.subscribe_external ~id
    ~callback:(fun (ev : Masc.Sse.external_event) ->
      if is_change ev.Masc.Sse.ext_frame then heard := read () :: !heard)
    ();
  Fun.protect ~finally:(fun () -> Masc.Sse.unsubscribe_external id) (fun () -> f heard)

let listed_ids config =
  match Server_dashboard_http.dashboard_scheduled_automation_http_json ~config with
  | `Assoc fields ->
    (match List.assoc_opt "requests" fields with
     | Some (`List rows) ->
       List.filter_map (function
         | `Assoc row ->
           (match List.assoc_opt "schedule_id" row with
            | Some (`String id) -> Some id
            | _ -> None)
         | _ -> None) rows
       |> List.sort String.compare
     | _ -> fail "the schedule list has no requests")
  | _ -> fail "the schedule list is not an object"

let insert config schedule_id =
  let request =
    match Schedule_domain.create_request ~schedule_id ~requested_by:actor ~scheduled_by:actor
            ~requested_at:100.0 ~due_at:4_000_000_000.0
            ~payload:(`Assoc [ "kind", `String "consumer.note"; "body", `Assoc [] ])
            ~source:Schedule_domain.Operator_request () with
    | Ok request -> request
    | Error err -> fail err
  in
  match Schedule_store.insert_request config ~runner_tick_sec:1.0 request with
  | Ok _ -> ()
  | Error err -> fail (Schedule_store.store_error_to_string err)

(* The announcement leaves the writer, so it is waited for. *)
let await_heard clock heard =
  Eio.Time.with_timeout_exn clock 5.0 (fun () ->
    while !heard = [] do Eio.Time.sleep clock 0.01 done)

let test_each_write_is_announced_and_read () =
  with_workspace (fun clock config ->
    check (list string) "the cached list starts empty" [] (listed_ids config);
    hearing ~read:(fun () -> listed_ids config) (fun heard ->
      insert config "announced-first";
      await_heard clock heard;
      check (list (list string)) "the first write is on the list read when heard"
        [ [ "announced-first" ] ] (List.rev !heard);
      heard := [];
      insert config "announced-second";
      await_heard clock heard;
      check (list (list string)) "the second write is on the list read when heard"
        [ [ "announced-first"; "announced-second" ] ] (List.rev !heard)))

let runner_word config =
  match Server_dashboard_http.dashboard_scheduled_automation_http_json ~config with
  | `Assoc fields ->
    (match List.assoc_opt "schedule_runner" fields with
     | Some (`Assoc runner) ->
       (match List.assoc_opt "status" runner with
        | Some (`String word) -> word
        | _ -> fail "the runner has no status word")
     | _ -> fail "the schedule list has no runner")
  | _ -> fail "the schedule list is not an object"

let word status = Schedule_contract_values.runner_status_to_string status

let test_a_tick_is_announced_after_its_record () =
  with_workspace (fun _clock config ->
    Schedule_runner_status.reset_for_test ();
    Fun.protect ~finally:Schedule_runner_status.reset_for_test (fun () ->
      check string "the cached list is from before any tick"
        (word Schedule_contract_values.Runner_not_started) (runner_word config);
      hearing ~read:(fun () -> runner_word config) (fun heard ->
        ignore
          (Server_bootstrap_maintenance.run_schedule_runner_tick ~clock:Unix.gettimeofday
             config ~state:Server_bootstrap_maintenance.initial_schedule_runner_state
           : Server_bootstrap_maintenance.schedule_runner_state);
        match !heard with
        | latest :: _ ->
          check string "the last change heard reads the recorded tick"
            (word Schedule_contract_values.Runner_ok) latest
        | [] -> fail "the tick was not announced")))

let test_a_tick_that_changes_nothing_is_not_announced () =
  with_workspace (fun clock config ->
    Schedule_runner_status.reset_for_test ();
    Fun.protect ~finally:Schedule_runner_status.reset_for_test (fun () ->
      let tick state =
        Server_bootstrap_maintenance.run_schedule_runner_tick ~clock:Unix.gettimeofday
          config ~state
      in
      let first = tick Server_bootstrap_maintenance.initial_schedule_runner_state in
      (* Lets a store write of the first tick be announced before listening. *)
      Eio.Time.sleep clock 0.05;
      hearing ~read:(fun () -> runner_word config) (fun heard ->
        ignore (tick first : Server_bootstrap_maintenance.schedule_runner_state);
        check int "an idle tick leaves the list as it was, unannounced" 0
          (List.length !heard))))

let test_a_tick_read_while_it_ran_is_announced () =
  with_workspace (fun clock config ->
    Schedule_runner_status.reset_for_test ();
    Fun.protect ~finally:Schedule_runner_status.reset_for_test (fun () ->
      let tick state =
        Server_bootstrap_maintenance.run_schedule_runner_tick ~clock:Unix.gettimeofday
          config ~state
      in
      let first = tick Server_bootstrap_maintenance.initial_schedule_runner_state in
      Eio.Time.sleep clock 0.05;
      hearing ~read:(fun () -> runner_word config) (fun heard ->
        let finished = ref false in
        Eio.Fiber.both
          (fun () ->
            ignore (tick first : Server_bootstrap_maintenance.schedule_runner_state);
            finished := true)
          (fun () ->
            (* An announcement made while the tick runs, as a store write of
               the tick would make. *)
            while not ((Schedule_runner_status.snapshot ()).tick_in_flight || !finished) do
              Eio.Fiber.yield ()
            done;
            if not !finished then Server_schedule_broadcast.changed ~base_path:config.base_path);
        check bool "a reader read the list while the tick ran" true
          (List.mem (word Schedule_contract_values.Runner_running) !heard);
        match !heard with
        | latest :: _ ->
          check string "the last change heard reads the finished tick"
            (word Schedule_contract_values.Runner_ok) latest
        | [] -> fail "nothing was heard")))

let test_each_deadline_is_announced_once () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let stale_after_sec = 0.5 in
    let finished = ref (Eio.Time.now clock -. 0.2) in
    let announced = ref [] in
    let on_deadline () =
      announced := (Eio.Time.now clock, !finished +. stale_after_sec) :: !announced;
      (* The first deadline is followed by a newer finished tick. *)
      if List.length !announced = 1 then finished := Eio.Time.now clock;
      (* A watch that kept announcing still lets the window below close. *)
      Eio.Fiber.yield ()
    in
    Eio.Fiber.first
      (fun () ->
        Server_schedule_runner_staleness.watch ~clock ~stale_after_sec
          ~finished_at:(fun () -> Some !finished) ~on_deadline)
      (fun () -> Eio.Time.sleep clock 1.6);
    check int "one announcement per finished tick" 2 (List.length !announced);
    List.iter (fun (at, deadline) ->
      check bool "at its deadline, not before" true (at > deadline)) !announced)

let () =
  run
    "schedules_announce"
    [ ( "schedule store"
      , [ test_case "each write is announced and read" `Quick
            test_each_write_is_announced_and_read
        ] )
    ; ( "schedule runner"
      , [ test_case "a tick is announced after its record" `Quick
            test_a_tick_is_announced_after_its_record
        ; test_case "a tick that changes nothing is not announced" `Quick
            test_a_tick_that_changes_nothing_is_not_announced
        ; test_case "a tick read while it ran is announced" `Quick
            test_a_tick_read_while_it_ran_is_announced
        ; test_case "each deadline is announced once" `Quick
            test_each_deadline_is_announced_once
        ] )
    ]
