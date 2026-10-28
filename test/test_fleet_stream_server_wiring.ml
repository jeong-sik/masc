open Alcotest
module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Refresh = Server_routes_http_runtime.For_testing

(* The fleet section as the scan writes it. Only the running count varies; the
   other keys take the empty value of their type. *)
let fleet_section ~running : Yojson.Safe.t =
  let counts =
    List.map
      (fun key -> key, `Int 0)
      [ "bootable_keeper_count"
      ; "executable_keeper_fiber_count"
      ; "failing_keeper_fiber_count"
      ; "recovering_keeper_fiber_count"
      ; "turn_configuration_error_keeper_count"
      ; "official_client_recovery_required_keeper_count"
      ; "paused_keeper_count"
      ; "target_reaction_capacity_count"
      ; "reaction_capacity_shortfall_count"
      ; "active_task_owner_without_executable_fiber_count"
      ; "completion_authority_pending_task_count"
      ; "active_task_owner_scan_error_count"
      ]
  in
  let names =
    List.map
      (fun key -> key, `List [])
      [ "bootable_keeper_names"
      ; "running_keeper_names"
      ; "executable_keeper_names"
      ; "turn_configuration_error_keeper_names"
      ; "official_client_recovery_required_keeper_names"
      ]
  in
  `Assoc
    ([ "schema", `String Masc.Keeper_fleet_blocker.reading_schema
     ; "status", `String "ok"
     ; "blocker", `Null
     ; "operator_action_required", `Bool false
     ; "running_keeper_fiber_count", `Int running
     ]
     @ counts
     @ names)
;;

let health_fields section : (string * Yojson.Safe.t) list =
  [ "overall_status", `String "ok"; "keeper_fleet_safety", section ]
;;

(* What an event says, without the time the scan finished. *)
let describe : F.event -> string = function
  | F.Snapshot { revision; fleet; degraded; _ } ->
    Printf.sprintf "snapshot r%d running=%d degraded=%s" (F.Revision.to_int revision)
      fleet.F.fs_running_count
      (match degraded with
       | None -> "no"
       | Some { F.reason = F.Scan_timed_out; _ } -> "timed_out"
       | Some { F.reason = F.Scan_failed; _ } -> "failed")
  | F.Changed { revision; fleet; _ } ->
    Printf.sprintf "changed r%d running=%d" (F.Revision.to_int revision)
      fleet.F.fs_running_count
  | F.Degraded { revision; degradation } ->
    Printf.sprintf "degraded r%d %s" (F.Revision.to_int revision)
      (match degradation.F.reason with
       | F.Scan_timed_out -> "timed_out"
       | F.Scan_failed -> "failed")
;;

let test_the_cached_snapshot_publishes_to_the_hub () =
  Refresh.reset_full_health_snapshot ();
  let seen = ref [] in
  let (_ : unit -> unit) =
    Hub.subscribe Server_routes_http_runtime.fleet_stream_hub ~on_event:(fun event ->
      seen := describe event :: !seen)
  in
  let told () = List.rev !seen in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let scan fields =
        Refresh.run_full_health_refresh_worker ~sw ~compute:(fun () -> Ok fields)
      in
      scan (health_fields (fleet_section ~running:1));
      check (list string) "the first reading" [ "snapshot r1 running=1 degraded=no" ] (told ());
      scan (health_fields (fleet_section ~running:1));
      check int "the same reading makes no event" 1 (List.length (told ()));
      scan (health_fields (fleet_section ~running:2));
      check string "a different reading" "changed r2 running=2" (List.nth (told ()) 1);
      Refresh.mark_full_health_snapshot_failure (Proactive_refresh.Raised (Failure "scan raised"));
      check string "a failed scan" "degraded r3 failed" (List.nth (told ()) 2);
      Refresh.mark_full_health_snapshot_failure (Proactive_refresh.Raised (Failure "again"));
      check int "a second failure makes no event" 3 (List.length (told ()));
      scan (health_fields (fleet_section ~running:2));
      check string "the same reading ends the outage" "changed r4 running=2"
        (List.nth (told ()) 3);
      Refresh.mark_full_health_snapshot_failure
        (Proactive_refresh.Timed_out
           { Proactive_refresh.label = "full_health_snapshot"
           ; phase = Proactive_refresh.Refresh
           ; timeout_s = 30.0
           ; elapsed_s = 31.0
           });
      check string "a scan that ran out of time" "degraded r5 timed_out"
        (List.nth (told ()) 4);
      (* Snapshots with no reading in them tell the hub nothing. *)
      scan [ "overall_status", `String "ok" ];
      scan
        (health_fields
           (`Assoc [ "status", `String "warming"; "component_timed_out", `Bool false ]));
      scan
        (health_fields
           (`Assoc [ "schema", `String Masc.Keeper_fleet_blocker.reading_schema ]));
      check int "nothing came of them" 5 (List.length (told ()));
      match Hub.current Server_routes_http_runtime.fleet_stream_hub with
      | Some state ->
        check string "the state is still the outage"
          "snapshot r5 running=2 degraded=timed_out" (describe state)
      | None -> fail "no state"))
;;

let () =
  run "fleet_stream_server_wiring"
    [ ( "publishing"
      , [ test_case "the cached snapshot publishes to the hub" `Quick
            test_the_cached_snapshot_publishes_to_the_hub
        ] )
    ]
;;
