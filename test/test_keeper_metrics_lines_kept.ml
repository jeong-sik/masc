(** The text of a Keeper's newest metrics rows is a fact of the Keeper's
    metrics store, kept in memory by the process that writes the store
    ([Keeper_status_metrics.newest_metrics_lines_result], RFC "Keeper row
    facts are kept in memory by their writers", layer 3).

    The rows go through the writer the Keeper's turn and its heartbeat loop
    use, [Keeper_types_support.append_keeper_metrics].

    What is pinned:

    1. Every row appended moves the kept lines, with the store's day files
       gone: no file is read for them. The Keeper list's recent tools and
       the metrics chart answer from them.
    2. The lines are the newest [recent_metrics_row_count] rows, oldest
       first, and are what the files say.
    3. A store the strict read refuses: the strict reader says so, and the
       reader that shows what it can reads the rows.
    4. Held lines are answered without the fiber giving up its turn. *)

open Alcotest
open Masc

let keeper_name = "metrics-lines-kept"

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper_metrics_lines_kept_" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f (Workspace.default_config base_path))
;;

(* Each row carries its number, so a line is told by the row it came from
   and not by how the writer spelled it. *)
let turn number tool_name =
  `Assoc
    (Keeper_metrics_record.fields Keeper_metrics_record.Turn
     @ [ "ts", `String "2026-11-19T00:00:01Z"
       ; "channel", `String "turn"
       ; "row", `Int number
       ; "tool_call_count", `Int 1
       ; "tools_used", `List [ `String tool_name ]
       ])
;;

let heartbeat number =
  `Assoc
    (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
     @ [ "ts", `String "2026-11-19T00:00:02Z"
       ; "channel", `String "heartbeat"
       ; "row", `Int number
       ])
;;

let append config row = Keeper_types_support.append_keeper_metrics config keeper_name row

let numbers lines =
  List.map
    (fun line ->
       match Dated_jsonl.parse_line line with
       | Error detail -> failf "a line that is not JSON (%s): %s" detail line
       | Ok json ->
         (match Yojson.Safe.Util.member "row" json with
          | `Int number -> number
          | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
            failf "a line without its row number: %s" line))
    lines
;;

(* The rows of the kept lines, as the strict reader gives them. *)
let kept config =
  match Keeper_status_metrics.newest_metrics_lines_result config ~keeper_name with
  | Ok lines -> Ok (numbers lines)
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
;;

let answer = result (list int) string

(* The rows the reader that shows what it can gives. *)
let shown config =
  numbers
    (Keeper_status_metrics.newest_metrics_lines_passing_over_what_is_not_the_stores
       config
       ~keeper_name)
;;

let meta =
  lazy
    (match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ]) with
     | Ok meta -> meta
     | Error detail -> failwith detail)
;;

(* The recent tools of a Keeper row, read as a request that does not reuse a
   cached answer reads them. *)
let recent_tools config =
  match
    Operator_control_snapshot_tool_audit.read
      ~read_policy:Dashboard_projection_read.Current
      config
      (Lazy.force meta)
  with
  | Operator_control_snapshot_tool_audit.Read audit ->
    audit.Operator_control_snapshot_tool_audit.recent_tool_names
  | Operator_control_snapshot_tool_audit.Timed_out -> fail "the tool audit read timed out"
  | Operator_control_snapshot_tool_audit.Unreadable detail -> fail detail
;;

(* How many rows the metrics chart of the Keeper looked at. *)
let chart_rows config =
  let request =
    Httpun.Request.create `GET ("/api/v1/keepers/" ^ keeper_name ^ "/metrics")
  in
  match
    Server_dashboard_http_keeper_api.keeper_metrics_response ~config ~keeper_name request
  with
  | `OK, json -> Yojson.Safe.Util.(json |> member "scanned_rows" |> to_int)
  | (`Bad_request | `Service_unavailable), json -> fail (Yojson.Safe.to_string json)
;;

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

(* After the day files go the first turn is only in memory. The readers that
   still tell of it read no file. *)
let test_the_lines_follow_the_rows_appended () =
  with_workspace
  @@ fun config ->
  check answer "a Keeper without a row" (Ok []) (kept config);
  append config (turn 1 "first_tool");
  check answer "the first row" (Ok [ 1 ]) (kept config);
  remove_day_files config;
  check answer "with the day files gone" (Ok [ 1 ]) (kept config);
  append config (heartbeat 2);
  append config (turn 3 "second_tool");
  check answer "the rows appended since" (Ok [ 1; 2; 3 ]) (kept config);
  check (list int) "the reader that shows what it can" [ 1; 2; 3 ] (shown config);
  check
    (list string)
    "the recent tools come from the kept lines"
    [ "second_tool"; "first_tool" ]
    (recent_tools config);
  check int "the chart looks at the kept lines" 3 (chart_rows config);
  (* The files hold the heartbeat and the second turn. *)
  Dated_jsonl.directories_removed ();
  check answer "as the files say" (Ok [ 2; 3 ]) (kept config);
  check (list string) "the recent tools of the files" [ "second_tool" ] (recent_tools config);
  check int "the chart of the files" 2 (chart_rows config)
;;

let test_the_lines_are_the_newest_rows () =
  with_workspace
  @@ fun config ->
  let count = Keeper_status_metrics.recent_metrics_row_count in
  append config (heartbeat 1);
  check answer "the first row" (Ok [ 1 ]) (kept config);
  for number = 2 to count + 5 do
    append config (heartbeat number)
  done;
  let newest = List.init count (fun index -> index + 6) in
  check answer "the newest rows, oldest first" (Ok newest) (kept config);
  Dated_jsonl.directories_removed ();
  check answer "as the files say" (Ok newest) (kept config)
;;

(* A name beside the months that the layout does not make. The strict read
   refuses the store and nothing is kept. The reader that shows what it can
   passes the name over, as it did before the lines were kept. *)
let test_a_store_the_strict_read_refuses () =
  with_workspace
  @@ fun config ->
  append config (heartbeat 1);
  append config (heartbeat 2);
  let store = Keeper_types_support.keeper_metrics_store config keeper_name in
  let foreign = Filename.concat (Dated_jsonl.base_dir store) "invalid-layout" in
  Out_channel.with_open_text foreign (fun channel -> output_string channel "not a month");
  (match Keeper_status_metrics.newest_metrics_lines_result config ~keeper_name with
   | Ok _ -> fail "the strict reader read a store the strict read refuses"
   | Error (_ : Dated_jsonl.read_error) -> ());
  check (list int) "the reader that shows what it can" [ 1; 2 ] (shown config);
  Sys.remove foreign;
  check answer "once the name is gone" (Ok [ 1; 2 ]) (kept config)
;;

(* How many turns a fiber that is ready to run gets while [read] is called
   fifty times. Fibers of one domain take turns only where one of them
   waits, so a read that never waits gives the fiber beside it none. A read
   that asks the file system through Eio waits for a worker thread, and the
   fiber beside it runs. *)
let turns_of_a_fiber_beside read =
  Eio.Switch.run
  @@ fun sw ->
  let turns = ref 0 in
  let stop = ref false in
  Eio.Fiber.fork ~sw (fun () ->
    while not !stop do
      incr turns;
      Eio.Fiber.yield ()
    done);
  Eio.Fiber.yield ();
  let before = !turns in
  for _ = 1 to 50 do
    read ()
  done;
  let during = !turns - before in
  stop := true;
  during
;;

let test_held_lines_are_answered_without_waiting () =
  with_workspace
  @@ fun config ->
  append config (heartbeat 1);
  check answer "read and kept" (Ok [ 1 ]) (kept config);
  check
    int
    "the fiber beside got no turn"
    0
    (turns_of_a_fiber_beside (fun () ->
       check answer "held" (Ok [ 1 ]) (kept config);
       check (list int) "held, for the reader that shows what it can" [ 1 ] (shown config)))
;;

(* The rows are appended in the server, the process that writes the store and
   keeps its facts in memory. *)
let () =
  Fact_cell.keep_in_this_process ();
  run
    "keeper_metrics_lines_kept"
    [ ( "the newest metrics rows are the store's kept lines"
      , [ test_case
            "the lines follow the rows appended"
            `Quick
            test_the_lines_follow_the_rows_appended
        ; test_case
            "the lines are the newest rows"
            `Quick
            test_the_lines_are_the_newest_rows
        ; test_case
            "a store the strict read refuses"
            `Quick
            test_a_store_the_strict_read_refuses
        ; test_case
            "held lines are answered without waiting"
            `Quick
            test_held_lines_are_answered_without_waiting
        ] )
    ]
;;
