module Persistence = Keeper_event_queue_persistence
module Queue = Keeper_event_queue

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

let () =
  Alcotest.run "Fleet queue projection"
    ["durable observation", [Alcotest.test_case
      "owner lifecycle and failed queue reads remain separate observations"
      `Quick test_owner_facts_and_incomplete_storage_stay_distinct]]
;;
