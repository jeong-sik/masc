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
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
    Schedule_store.install_change_observer (fun ~base_path:_ -> ());
    Dashboard_cache.invalidate_all ();
    Server_auth.For_testing.restore_server_state previous_state;
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
          (fun () ->
            let state = Masc.Mcp_server.For_testing.create_state ~base_path in
            Server_auth.For_testing.restore_server_state (Some state);
            let config = Masc.Mcp_server.workspace_config state in
            ignore (Workspace_core.init config ~agent_name:(Some "test"));
            Server_schedule_invalidation.start ~sw ~mono_clock:(Eio.Stdenv.mono_clock env);
            f (Eio.Stdenv.clock env) config))))

let is_change (delivery : Masc.Sse.delivery) =
  Yojson.Safe.equal delivery.Masc.Sse.payload Masc.Schedule_invalidation_event.json

(* Calls [f] with the stream of an observer session of the workspace, as a
   terminal reader holds one. The invalidation reaches observer sessions, not
   external subscribers. Only changes made after the call are delivered. *)
let observing ~(config : Masc.Workspace.config) f =
  let session_id = Printf.sprintf "schedules-announce-%d" (Unix.getpid ()) in
  let auth = Masc_test_deps.make_sse_auth config.base_path "schedules-announce" in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  match
    Masc.Sse.register ~kind:Observer ~auth session_id ~last_event_id:(Masc.Sse.current_id ())
  with
  | Error error -> fail (Masc.Sse.registration_error_to_string error)
  | Ok (_, stream, _) ->
    Fun.protect ~finally:(fun () -> Masc.Sse.unregister session_id) (fun () -> f stream)

(* A reader answers each delivered change by reading: [heard] gains
   [read ()] for every change already delivered. *)
let hear stream ~read heard =
  let rec drain () =
    match Masc.Sse.take_delivery_nonblocking stream with
    | None -> ()
    | Some delivery ->
      if is_change delivery then heard := read () :: !heard;
      drain ()
  in
  drain ()

(* As [hear], waiting for the first change: the announcement of a store
   write leaves the writer. *)
let await_heard clock stream ~read heard ~what =
  match
    Eio.Time.with_timeout clock 5.0 (fun () ->
      while !heard = [] do
        let delivery = Masc.Sse.take_delivery stream in
        if is_change delivery then heard := read () :: !heard
      done;
      Ok ())
  with
  | Ok () -> hear stream ~read heard
  | Error `Timeout -> fail what

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

let test_each_write_is_announced_and_read () =
  with_workspace (fun clock config ->
    check (list string) "the cached list starts empty" [] (listed_ids config);
    observing ~config (fun stream ->
      let read () = listed_ids config in
      let heard = ref [] in
      let notices_before = Server_schedule_invalidation.notices () in
      insert config "announced-first";
      await_heard clock stream ~read heard ~what:"the first write was not announced";
      check bool "the published write is counted for the runner" true
        (Server_schedule_invalidation.notices () > notices_before);
      check (list (list string)) "the first write is on the list read when heard"
        [ [ "announced-first" ] ] (List.rev !heard);
      heard := [];
      insert config "announced-second";
      await_heard clock stream ~read heard ~what:"the second write was not announced";
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
  with_workspace (fun clock config ->
    Schedule_runner_status.reset_for_test ();
    Fun.protect ~finally:Schedule_runner_status.reset_for_test (fun () ->
      check string "the cached list is from before any tick"
        (word Schedule_contract_values.Runner_not_started) (runner_word config);
      observing ~config (fun stream ->
        let heard = ref [] in
        ignore
          (Server_bootstrap_maintenance.run_schedule_runner_tick ~clock:Unix.gettimeofday
             config ~state:Server_bootstrap_maintenance.initial_schedule_runner_state
           : Server_bootstrap_maintenance.schedule_runner_state);
        await_heard clock stream ~read:(fun () -> runner_word config) heard
          ~what:"the tick was not announced";
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
      observing ~config (fun stream ->
        let heard = ref [] in
        ignore (tick first : Server_bootstrap_maintenance.schedule_runner_state);
        (* Lets a store write of this tick be announced too. *)
        Eio.Time.sleep clock 0.05;
        hear stream ~read:(fun () -> runner_word config) heard;
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
      observing ~config (fun stream ->
        let read () = runner_word config in
        let heard = ref [] in
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
            if not !finished then begin
              Server_schedule_invalidation.announce ~base_path:config.base_path;
              (* A reader answers it while the tick runs. *)
              hear stream ~read heard
            end);
        (* The tick's own announcement, made because the list was read while
           it ran, is delivered by now. *)
        hear stream ~read heard;
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
