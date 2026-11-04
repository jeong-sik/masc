(* The server probes the runtimes on its own clock: at start, every
   [dashboard_runtime_probe_cache_ttl_sec], and at once when a forced read past
   the recent window asks. A probe a read asked for is announced as
   [runtime_probe]; a periodic one only when what it found differs from the
   last probe, the times it was checked aside. *)

open Alcotest
open Masc

module Info = Server_dashboard_http_runtime_info

let probes = ref 0
let finding = ref "a"

(* Each probe is checked at a new time; what it finds is [!finding]. *)
let runner () : Yojson.Safe.t =
  incr probes;
  `Assoc
    [ "probe_ok", `Bool true
    ; "status", `String "reachable"
    ; "marker", `String !finding
    ; "checked_at", `String (string_of_int !probes)
    ; "providers", `List [ `Assoc [ "runtime_id", `String "p.m1"; "checked_at", `Int !probes ] ]
    ]

let marker_of json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "probe" fields with
     | Some (`Assoc probe) ->
       (match List.assoc_opt "marker" probe with
        | Some (`String marker) -> Some marker
        | Some _ | None -> None)
     | Some _ | None -> None)
  | _ -> None

let refresh_state_of json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "refresh_state" fields with
     | Some (`String state) -> state
     | Some _ | None -> "?")
  | _ -> "?"

(* The loop fiber runs its probe and announcement synchronously once woken. *)
let settle () =
  for _ = 1 to 5 do
    Eio.Fiber.yield ()
  done

(* Runs [f] with the loop going on a mock clock and the announcements counted.
   The loop's switch ends with [f]. *)
let with_loop f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "runtime-probe-loop-" "") in
  probes := 0;
  finding := "a";
  Info.clear_dashboard_runtime_probe_cache_for_tests ();
  Info.set_dashboard_runtime_probe_runner_for_tests runner;
  Fun.protect
    ~finally:(fun () ->
      Info.clear_dashboard_runtime_probe_runner_for_tests ();
      Info.clear_dashboard_runtime_probe_cache_for_tests ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
      let heard = ref 0 in
      let id = "runtime-probe-loop" in
      let name = Workspace_dataset_event.dataset_name Workspace_dataset_event.Runtime_probe in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match
            ( Json_util.assoc_string_opt "type" event.ext_payload
            , Json_util.assoc_string_opt "dataset" event.ext_payload )
          with
          | Some kind, Some dataset
            when String.equal kind Workspace_dataset_event.event_type
                 && String.equal dataset name -> incr heard
          | (Some _ | None), (Some _ | None) -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        let clock = Eio_mock.Clock.make () in
        Eio.Fiber.first
          (fun () ->
            Eio.Switch.run (fun sw ->
              Info.start_dashboard_runtime_probe_loop ~sw ~clock ~base_path;
              Eio.Fiber.await_cancel ()))
          (fun () ->
            settle ();
            f ~clock ~heard)))

let test_the_loop_probes_at_start () =
  with_loop @@ fun ~clock:_ ~heard ->
  check int "one probe at start" 1 !probes;
  check int "the first probe is announced" 1 !heard;
  let json = Info.dashboard_runtime_probe_http_json () in
  check string "a read serves it as fresh" "fresh" (refresh_state_of json);
  check (option string) "the probe's value" (Some "a") (marker_of json)

let test_a_periodic_probe_is_announced_when_its_findings_move () =
  with_loop @@ fun ~clock ~heard ->
  Eio_mock.Clock.advance clock;
  settle ();
  check int "the interval probes again" 2 !probes;
  check int "the same findings at a new time are not announced" 1 !heard;
  finding := "b";
  Eio_mock.Clock.advance clock;
  settle ();
  check int "the next interval probes again" 3 !probes;
  check int "moved findings are announced" 2 !heard;
  check (option string) "a read serves them" (Some "b")
    (marker_of (Info.dashboard_runtime_probe_http_json ()))

let test_a_forced_read_wakes_the_loop () =
  with_loop @@ fun ~clock:_ ~heard ->
  (* Older than the force window, so the read asks for a probe. *)
  Info.set_dashboard_runtime_probe_cache_for_tests ~probe:(runner ()) ~age_sec:100.0 ();
  let probes_before = !probes in
  let json = Info.dashboard_runtime_probe_http_json ~force:true () in
  check string "the read serves the old value" "served_stale" (refresh_state_of json);
  settle ();
  check int "the loop probes without waiting out its interval" (probes_before + 1) !probes;
  check int "a probe a read asked for is announced, findings unmoved" 2 !heard

let () =
  run "dashboard_runtime_probe_loop"
    [ ( "loop"
      , [ test_case "the loop probes at start" `Quick test_the_loop_probes_at_start
        ; test_case "a periodic probe is announced when its findings move" `Quick
            test_a_periodic_probe_is_announced_when_its_findings_move
        ; test_case "a forced read wakes the loop" `Quick test_a_forced_read_wakes_the_loop
        ] )
    ]
