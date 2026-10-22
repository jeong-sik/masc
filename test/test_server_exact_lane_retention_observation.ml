open Alcotest

module Exact = Masc.Exact_lane_run_registry
module Projection = Server_exact_lane_retention_observation

let project replay payload_sweep =
  Projection.to_json ({ replay; payload_sweep } : Exact.startup_observation)
;;

let test_replay_metadata_and_partial_effects_are_preserved () =
  let json = project
      (Run_registry_core.Replayed
         { lines_read = 17; malformed_lines = 0; dropped_running = 2; reached_end = true })
      (Exact.Swept
         { examined_root_entries = 4; unlinked_entries = 7
         ; removed_run_directories = 2; failed_root_entries = 1 }) in
  let open Yojson.Safe.Util in
  let replay = member "replay" json in
  check int "actual replay line count" 17 (member "lines_read" replay |> to_int);
  check int "actual dropped running count" 2 (member "dropped_running" replay |> to_int);
  check bool "actual EOF" true (member "reached_end" replay |> to_bool);
  let sweep = member "payload_sweep" json in
  check string "failure is not completed" "partial_failure" (member "status" sweep |> to_string);
  List.iter (fun (name, expected) ->
      check int name expected (member name sweep |> to_int))
    [ "examined_root_entries", 4; "unlinked_entries", 7
    ; "removed_run_directories", 2; "failed_root_entries", 1 ];
  check string "EOF does not prove compaction" "unobserved"
    (json |> member "compaction" |> member "status" |> to_string)
;;

let test_no_effect_states_do_not_invent_counts () =
  let open Yojson.Safe.Util in
  List.iter (fun (state, expected) ->
      let sweep = project Run_registry_core.Not_replayed state |> member "payload_sweep" in
      check string "closed no-effect state" expected (member "status" sweep |> to_string);
      check bool "no invented zero-removal receipt" true
        (member "unlinked_entries" sweep = `Null))
    [ Exact.Not_attempted, "not_attempted"
    ; Exact.Replay_not_trusted, "replay_not_trusted"
    ; Exact.Root_absent, "root_absent"
    ; Exact.Root_unavailable, "root_unavailable" ];
  let absent = project Run_registry_core.Log_absent Exact.Replay_not_trusted in
  check string "absent replay stays absent" "log_absent"
    (absent |> member "replay" |> member "status" |> to_string)
;;

let test_completed_sweep_and_snapshot_scope () =
  let registry = Exact.create () in
  let captured = Exact.startup_observation registry in
  let before = Projection.to_json captured in
  Exact.register_running registry ~run_id:"after-startup" ~lane:Exact.Librarian
    ~actor:"fixture" ~started_at:1.0 ~input:(Exact.Exact_input `Null);
  check bool "projection only reads original observation" true
    (before = Projection.to_json (Exact.startup_observation registry));
  let completed = project
      (Run_registry_core.Replayed
         { lines_read = 0; malformed_lines = 0; dropped_running = 0; reached_end = true })
      (Exact.Swept
         { examined_root_entries = 0; unlinked_entries = 0
         ; removed_run_directories = 0; failed_root_entries = 0 }) in
  let open Yojson.Safe.Util in
  check string "empty visited root is a completed sweep" "completed"
    (completed |> member "payload_sweep" |> member "status" |> to_string);
  check string "startup scope, not a live census" "process_startup"
    (completed |> member "scope" |> to_string);
  check int "retention comes from the existing policy" Exact.max_completed_retained
    (completed |> member "completed_retained_per_lane" |> to_int)
;;

let () =
  run "exact lane startup retention projection"
    [ "observation",
      [ test_case "replay and partial effects preserve independent units" `Quick
          test_replay_metadata_and_partial_effects_are_preserved
      ; test_case "no-effect states do not invent removal counts" `Quick
          test_no_effect_states_do_not_invent_counts
      ; test_case "completed sweep and immutable startup scope" `Quick
          test_completed_sweep_and_snapshot_scope
      ] ]
;;
