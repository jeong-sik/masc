(** The tool audit of a Keeper's newest turn is a fact of the Keeper's metrics
    store, kept in memory by the process that writes the store
    ([Keeper_status_metrics.latest_tool_audit_snapshot_from_files], RFC
    "Keeper row facts are kept in memory by their writers", layer 3).

    The rows go through the writer the Keeper's turn and its heartbeat loop
    use, [Keeper_types_support.append_keeper_metrics].

    What is pinned:

    1. After a turn row the audit is answered with the store's day files
       gone: no file is read for it.
    2. A heartbeat row leaves it as it is, still without a file. A read of
       the files would find no turn row.
    3. The next turn row replaces it.
    4. A removal that is told is read from the files again. *)

open Alcotest
open Masc

let keeper_name = "tool-audit-kept"

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper_tool_audit_kept_" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f (Workspace.default_config base_path))
;;

let turn tool_name =
  `Assoc
    (Keeper_metrics_record.fields Keeper_metrics_record.Turn
     @ [ "ts", `String "2026-11-19T00:00:01Z"
       ; "channel", `String "turn"
       ; "tool_call_count", `Int 1
       ; "tools_used", `List [ `String tool_name ]
       ])
;;

let heartbeat =
  `Assoc
    (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
     @ [ "ts", `String "2026-11-19T00:00:02Z"; "channel", `String "heartbeat" ])
;;

let append config row = Keeper_types_support.append_keeper_metrics config keeper_name row

(* The tools of the newest turn, as a Keeper row is told them. *)
let tools config =
  match Keeper_status_metrics.latest_tool_audit_snapshot_from_files config ~keeper_name with
  | Ok snapshot ->
    Ok
      (Option.map
         (fun (snapshot : Keeper_status_metrics.tool_audit_snapshot) ->
            snapshot.latest_tool_names)
         snapshot)
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
;;

let answer = result (option (list string)) string

(* The store's day files go, and nobody is told. *)
let remove_day_files config =
  let store = Keeper_types_support.keeper_metrics_store config keeper_name in
  let listed = function
    | Ok paths -> paths
    | Error error -> fail (Dated_jsonl.read_error_to_string error)
  in
  Dated_jsonl.prepare_for_directory_removal store;
  List.iter
    (fun month ->
       List.iter Sys.remove (listed (Dated_jsonl.day_file_paths_newest_first_result month)))
    (listed (Dated_jsonl.month_dir_paths_newest_first_result store))
;;

let test_the_audit_is_held_between_turns () =
  with_workspace
  @@ fun config ->
  check answer "a Keeper without a row" (Ok None) (tools config);
  append config (turn "first_tool");
  check answer "the turn's tools" (Ok (Some [ "first_tool" ])) (tools config);
  remove_day_files config;
  check answer "with the day files gone" (Ok (Some [ "first_tool" ])) (tools config);
  List.iter
    (fun beat ->
       append config heartbeat;
       check
         answer
         (Printf.sprintf "after heartbeat %d" beat)
         (Ok (Some [ "first_tool" ]))
         (tools config))
    [ 1; 2; 3 ];
  append config (turn "second_tool");
  check answer "the next turn's tools" (Ok (Some [ "second_tool" ])) (tools config);
  (* The files hold the three heartbeats and the second turn. *)
  Dated_jsonl.directories_removed ();
  check answer "as the files say" (Ok (Some [ "second_tool" ])) (tools config)
;;

let test_a_removal_that_is_told_is_read_again () =
  with_workspace
  @@ fun config ->
  append config (turn "first_tool");
  check answer "the turn's tools" (Ok (Some [ "first_tool" ])) (tools config);
  remove_day_files config;
  Dated_jsonl.directories_removed ();
  check answer "the files hold no turn" (Ok None) (tools config);
  append config heartbeat;
  check answer "a heartbeat is not a turn" (Ok None) (tools config)
;;

(* The rows are appended in the server, the process that writes the store and
   keeps its facts in memory. *)
let () =
  Fact_cell.keep_in_this_process ();
  run
    "keeper_turn_tool_audit_kept"
    [ ( "the newest turn's tool audit"
      , [ test_case "it is held between turns" `Quick test_the_audit_is_held_between_turns
        ; test_case
            "a removal that is told is read again"
            `Quick
            test_a_removal_that_is_told_is_read_again
        ] )
    ]
;;
