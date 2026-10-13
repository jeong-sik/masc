module Persistence = Keeper_event_queue_persistence
module Queue = Keeper_event_queue
module State = Keeper_event_queue_state

let unwrap = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let with_workspace run =
  let base_path = Filename.temp_file "queue_fleet_projection" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> run base_path)
;;

let field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> Alcotest.fail ("missing field " ^ name))
  | _ -> Alcotest.fail "expected object"
;;

let int_field name json =
  match field name json with
  | `Int value -> value
  | _ -> Alcotest.fail (name ^ " is not an integer")
;;

let bool_field name json =
  match field name json with
  | `Bool value -> value
  | _ -> Alcotest.fail (name ^ " is not a boolean")
;;

let rows json =
  match field "keepers" json with
  | `List rows -> rows
  | _ -> Alcotest.fail "keepers is not a list"
;;

let row keeper_name json =
  rows json
  |> List.find (fun row -> field "keeper_name" row = `String keeper_name)
;;

let test_owner_facts_and_incomplete_storage_stay_distinct () =
  with_workspace @@ fun base_path ->
  let owners = Persistence.
    ["fleet-runnable", Runnable; "fleet-recoverable", Recoverable;
     "fleet-disabled", Retained_disabled; "fleet-paused", Paused_dead;
     "fleet-shutdown", Shutdown_fenced; "fleet-unknown", Lifecycle_unknown "owner not observed"]
  in
  List.iter (fun (keeper_name, _) ->
    let stimulus : Queue.stimulus =
      { post_id = "source-" ^ keeper_name; urgency = Queue.Normal;
        arrived_at = 10.0; payload = Queue.Bootstrap }
    in
    Persistence.update_result ~base_path ~keeper_name
      (fun queue -> Queue.enqueue queue stimulus) |> unwrap) owners;
  let calls = ref [] in
  let summarize () =
    calls := [];
    Persistence.fleet_summary_json ~now:20.0 ~base_path
      ~owner_lifecycle:(fun ~keeper_name ->
        calls := keeper_name :: !calls;
        List.assoc keeper_name owners)
  in
  let complete = summarize () in
  Alcotest.(check int) "owner facts acquired once each" 6 (List.length !calls);
  Alcotest.(check int) "all six durable sources retained" 6 (int_field "pending_count" complete);
  Alcotest.(check bool) "unknown owner does not invalidate queue counts" true
    (bool_field "counts_complete" complete);
  List.iter (fun key -> Alcotest.(check int) key 1 (int_field key complete))
    ["runnable_backlog_count"; "recoverable_backlog_count"; "retained_disabled_backlog_count";
     "paused_dead_backlog_count"; "shutdown_fenced_backlog_count"; "unclassified_count"];
  Alcotest.(check bool) "unknown owner's cause survives" true
    (field "owner_lifecycle_detail" (row "fleet-unknown" complete) = `String "owner not observed");
  Alcotest.(check bool) "source age is observed separately" true
    (field "oldest_source_age_seconds" complete = `Float 10.0);
  Alcotest.(check bool) "source age cannot supply queue residence" true
    (field "oldest_age_seconds" (field "queue_residence" complete) = `Null);
  let corrupt_keeper = "fleet-runnable" in
  let snapshot = Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) corrupt_keeper)
      Persistence.snapshot_filename in
  let broken = "{invalid queue bytes" in
  let channel = open_out_bin snapshot in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel broken);
  let incomplete = summarize () in
  Alcotest.(check int) "failed queue keeps its owner fact" 6 (List.length !calls);
  Alcotest.(check bool) "corrupt storage is incomplete" false (bool_field "counts_complete" incomplete);
  Alcotest.(check int) "other five sources stay visible" 5 (int_field "pending_count" incomplete);
  Alcotest.(check bool) "read error remains visible" true (int_field "read_error_count" incomplete > 0);
  Alcotest.(check bool) "corrupt owner row remains visible" false
    (bool_field "counts_complete" (row corrupt_keeper incomplete));
  Alcotest.(check bool) "incomplete residence carries the storage cause" true
    (field "reason" (field "queue_residence" incomplete) = `String "queue_observation_incomplete");
  let channel = open_in_bin snapshot in
  let contents = Fun.protect ~finally:(fun () -> close_in channel)
      (fun () -> really_input_string channel (in_channel_length channel)) in
  Alcotest.(check string) "observation preserves rejected bytes" broken contents
;;

let test_admission_clock_survives_retention_and_reload () =
  with_workspace @@ fun base_path ->
  let keeper_name = "clock-owner" in
  let source : Queue.stimulus =
    { post_id = "old-source-new-admission"; urgency = Queue.Normal;
      arrived_at = 1.0; payload = Queue.Bootstrap } in
  Persistence.enqueue_stimulus_if_absent_result ~base_path ~keeper_name source |> unwrap |> ignore;
  let selections () = Persistence.pending_selections_result ~base_path ~keeper_name |> unwrap in
  let selection () = List.hd (selections ()) in
  let admission = match (selection ()).first_admitted_at with
    | Some time -> time | None -> Alcotest.fail "new admission clock missing" in
  Persistence.enqueue_stimulus_if_absent_result ~base_path ~keeper_name source |> unwrap |> ignore;
  Alcotest.(check bool) "duplicate admission retains original clock" true
    ((selection ()).first_admitted_at = Some admission);
  Persistence.note_checkpoint_retention_result ~base_path ~keeper_name
    ~selection:(selection ()) () |> unwrap |> ignore;
  Persistence.reprioritize_pending_result ~base_path ~keeper_name
    ~selection:(selection ()) ~urgency:Queue.Low () |> unwrap |> ignore;
  Persistence.defer_pending_result ~base_path ~keeper_name
    ~selection:(selection ()) () |> unwrap |> ignore;
  let receipt_path = Filename.concat base_path "fresh-reader.json" in
  let error_path = Filename.concat base_path "fresh-reader.stderr" in
  let receipt = Unix.openfile receipt_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
  let errors = Unix.openfile error_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
  let reader = Fun.protect ~finally:(fun () -> Unix.close receipt; Unix.close errors) (fun () ->
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; "--read-admission"; base_path; keeper_name |]
      Unix.stdin receipt errors) in
  let _, status = Unix.waitpid [] reader in
  Alcotest.(check bool) "fresh reader process completed" true (status = Unix.WEXITED 0);
  let fresh = Yojson.Safe.from_file receipt_path in
  Alcotest.(check bool) "fresh process recovers exact admission" true
    (field "first_admitted_at" fresh = `Float admission && field "read_errors" fresh = `Int 0);
  let reloaded = Persistence.load_selections_with_errors ~base_path ~keeper_name in
  Alcotest.(check int) "reloaded queue read errors" 0 (List.length reloaded.read_errors);
  Alcotest.(check bool) "reloaded retained clock is exact" true
    ((List.hd reloaded.pending).first_admitted_at = Some admission);
  let now = Unix.gettimeofday () in
  let observed = Persistence.fleet_summary_json ~now ~base_path
    ~owner_lifecycle:(fun ~keeper_name:_ -> Persistence.Runnable) in
  let residence = field "queue_residence" observed in
  Alcotest.(check bool) "actual admission, not old source timestamp" true
    (field "status" residence = `String "observed"
     && field "oldest_admitted_at_unix" residence = `Float admission
     && field "oldest_age_seconds" residence = `Float (now -. admission));
  Alcotest.(check bool) "ordinary clock observation preserves owner liveness" true
    (int_field "runnable_backlog_count" observed = 1);
  Persistence.ack_pending_result ~base_path ~keeper_name ~selection:(selection ()) () |> unwrap;
  let empty = Persistence.fleet_summary_json ~now ~base_path
    ~owner_lifecycle:(fun ~keeper_name:_ -> Persistence.Runnable) in
  Alcotest.(check bool) "empty queue has no invented duration" true
    (field "status" (field "queue_residence" empty) = `String "empty"
     && field "oldest_age_seconds" (field "queue_residence" empty) = `Null);
  Printf.printf "queue_preparation_clock_trial retained_clock=true duplicate_preserved=true reload_preserved=true source_age_seconds=%.6f queue_residence_seconds=%.6f empty_has_no_duration=true\n%!"
    (now -. source.arrived_at) (now -. admission)
;;

let test_missing_and_invalid_clock_evidence_stays_unknown () =
  let source : Queue.stimulus =
    { post_id = "unrecorded"; urgency = Queue.Normal; arrived_at = 1.0; payload = Queue.Bootstrap } in
  let pending = Queue.enqueue Queue.empty source in
  let unrecorded = State.with_pending pending State.empty in
  let retained = State.with_pending_at ~admitted_at:100.0 pending unrecorded |> unwrap in
  let from_wire = State.to_yojson retained |> State.of_yojson |> unwrap in
  Alcotest.(check bool) "later observation cannot invent first admission" true
    ((List.hd (State.pending_selections from_wire)).first_admitted_at = None);
  let residence state = Persistence.queue_residence_of_selections ~now:110.0 ~complete:true
    (State.pending_selections state) in
  Alcotest.(check bool) "missing clock stays explicit" true
    (residence from_wire = Persistence.Unknown Persistence.First_admission_not_recorded);
  let mixed_pending = Queue.enqueue pending { source with post_id = "recorded" } in
  let mixed = State.with_pending_at ~admitted_at:100.0 mixed_pending retained |> unwrap in
  Alcotest.(check bool) "one missing entry prevents aggregate oldest claim" true
    (residence mixed = Persistence.Unknown Persistence.First_admission_not_recorded);
  let recorded = State.with_pending_at ~admitted_at:100.0 pending State.empty |> unwrap in
  Alcotest.(check bool) "clock regression stays unknown" true
    (Persistence.queue_residence_of_selections ~now:99.0 ~complete:true
      (State.pending_selections recorded) = Persistence.Unknown Persistence.Clock_observation_invalid);
  Alcotest.(check bool) "read failure prevents measurement claim" true
    (Persistence.queue_residence_of_selections ~now:110.0 ~complete:false
      (State.pending_selections recorded) = Persistence.Unknown Persistence.Queue_observation_incomplete);
  Alcotest.(check bool) "nonfinite admission is rejected" true
    (Result.is_error (State.with_pending_at ~admitted_at:Float.nan pending State.empty));
  let invalid_wire = match State.to_yojson recorded with
    | `Assoc fields ->
      let entries = match List.assoc "pending" fields with
        | `List [`Assoc entry] -> `List [`Assoc (("first_admitted_at", `Float Float.infinity)
            :: List.remove_assoc "first_admitted_at" entry)]
        | _ -> Alcotest.fail "expected one pending entry" in
      `Assoc (("pending", entries) :: List.remove_assoc "pending" fields)
    | _ -> Alcotest.fail "expected queue object" in
  Alcotest.(check bool) "nonfinite wire admission is rejected" true
    (Result.is_error (State.of_yojson invalid_wire))
;;

let () =
  match Array.to_list Sys.argv with
  | [ _; "--read-admission"; base_path; keeper_name ] ->
    let observed = Persistence.load_selections_with_errors ~base_path ~keeper_name in
    let admission = match observed.pending with
      | [ entry ] -> (match entry.first_admitted_at with Some time -> `Float time | None -> `Null)
      | _ -> `Null in
    print_endline (Yojson.Safe.to_string (`Assoc [ "first_admitted_at", admission;
      "read_errors", `Int (List.length observed.read_errors) ]))
  | _ -> Alcotest.run "Fleet queue projection"
    ["durable observation", [Alcotest.test_case
      "owner lifecycle and failed queue reads remain separate observations"
      `Quick test_owner_facts_and_incomplete_storage_stay_distinct;
      Alcotest.test_case "first admission survives duplicate, retention and reload"
        `Quick test_admission_clock_survives_retention_and_reload;
      Alcotest.test_case "unrecorded, incomplete and invalid admission clocks"
        `Quick test_missing_and_invalid_clock_evidence_stays_unknown]]
;;
