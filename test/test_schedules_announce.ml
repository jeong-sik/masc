(** A workspace's schedules announce each change, and a reader that answers
    the announcement sees it: a schedule written to the store is on the fleet
    schedule list read when its write is heard, though the list was cached
    before the write. *)

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

let () =
  run
    "schedules_announce"
    [ ( "schedule store"
      , [ test_case "each write is announced and read" `Quick
            test_each_write_is_announced_and_read
        ] )
    ]
