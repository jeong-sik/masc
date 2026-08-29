(** Tests for IDE Bridge event collection. *)

open Alcotest

(* RFC-0378 A2: test-side attribution builders. *)
let unattributed_file attempted_path =
  Agent_observation.File
    (Agent_observation.Unaddressed
       { reason = Agent_observation.Unattributed.Unregistered_path; attempted_path })
;;

let addressed_file ~codebase ~path =
  match Agent_observation.Code_address.v ~codebase ~path with
  | Ok address ->
    Agent_observation.File (Agent_observation.Addressed { address; checkout = None })
  | Error e -> failwith (Agent_observation.Code_address.invalid_to_string e)
;;

let with_temp_dir f =
  let dir = Filename.temp_file "ide_bridge_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  (try f dir with exn ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" dir));
     raise exn);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" dir))
;;

let test_ingest_tool_event () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"fs_write"
      ~keeper_id:"keeper-alpha"
      ~turn_id:"turn-123"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:150
      ~summary:"Wrote 50 lines to test.ml"
      ~file_path:(Some "lib/test.ml")
      ~timestamp_ms:1717400000000L
      ();
    let dir = Ide_paths.code_store_dir ~base_dir:base_dir ~codebase:"github.com_other_repo" in
    let path = Filename.concat dir "tool_events.jsonl" in
    check bool "file exists" true (Sys.file_exists path);
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let tool_name = Yojson.Safe.Util.member "tool_name" json |> Yojson.Safe.Util.to_string in
    let keeper_id = Yojson.Safe.Util.member "keeper_id" json |> Yojson.Safe.Util.to_string in
    check string "tool_name" "fs_write" tool_name;
    check string "keeper_id" "keeper-alpha" keeper_id)
;;

(* RFC-0378 B: the bus carries no turn events. Tests that exercise the
   turn read path seed the stored row directly — standing in for the
   pre-existing data the readers serve until rung E. *)
let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let seed_turn_row ~base_dir ~turn_id ~keeper_id ~phase ~timestamp_ms =
  let dir = Ide_paths.code_store_dir ~base_dir ~codebase:"github.com_other_repo" in
  mkdir_p dir;
  let row =
    Ide_event_types.ide_event_to_json
      (Ide_event_types.Turn_event
         { turn_id
         ; keeper_id
         ; phase
         ; model_used = None
         ; tools_used = []
         ; stop_reason = None
         ; duration_ms = None
         ; timestamp_ms
         })
  in
  let oc =
    open_out_gen
      [ Open_append; Open_creat ]
      0o644
      (Filename.concat dir "turn_events.jsonl")
  in
  output_string oc (Yojson.Safe.to_string row ^ "\n");
  close_out oc
;;

let test_turn_rows_remain_readable () =
  with_temp_dir (fun base_dir ->
    seed_turn_row
      ~base_dir
      ~turn_id:"turn-456"
      ~keeper_id:"keeper-beta"
      ~phase:"completed"
      ~timestamp_ms:1717400000000L;
    match
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:"github.com_other_repo"
        ~kind:Ide_bridge.Turn
        ()
    with
    | [ event ] ->
      let field key = Yojson.Safe.Util.(member key event |> to_string) in
      check string "turn_id" "turn-456" (field "turn_id");
      check string "phase" "completed" (field "phase")
    | events -> Alcotest.failf "expected one turn event, got %d" (List.length events))
;;

let test_ingest_multiple_events () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"fs_write"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"first"
      ~file_path:None
      ~timestamp_ms:1000L
      ();
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:200
      ~summary:"second"
      ~file_path:None
      ~timestamp_ms:2000L
      ();
    let dir = Ide_paths.code_store_dir ~base_dir:base_dir ~codebase:"github.com_other_repo" in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let count = ref 0 in
    (try while true do ignore (input_line ic); incr count done with End_of_file -> ());
    close_in ic;
    check int "two events" 2 !count)
;;

let json_string key json =
  Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_string
;;

let json_field_is_null key json =
  match Yojson.Safe.Util.member key json with
  | `Null -> true
  | _ -> false
;;

let json_intlit key json =
  match Yojson.Safe.Util.member key json with
  | `Int i -> Int64.of_int i
  | `Intlit s -> Int64.of_string s
  | _ -> failwith ("expected int field " ^ key)
;;

let json_int key json =
  Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_int
;;

let test_list_events_filters_keeper_and_pages () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t-old"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"old"
      ~file_path:None
      ~timestamp_ms:1000L
      ();
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"read_file"
      ~keeper_id:"k2"
      ~turn_id:"t-other"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"other"
      ~file_path:None
      ~timestamp_ms:3000L
      ();
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"write_file"
      ~keeper_id:"k1"
      ~turn_id:"t-new"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"new"
      ~file_path:None
      ~timestamp_ms:2000L
      ();
    let events =
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:"github.com_other_repo"
        ~kind:Ide_bridge.Tool
        ~keeper_id:"k1"
        ~limit:1
        ()
    in
    match events with
    | [ event ] ->
      check string "keeper filter" "k1" (json_string "keeper_id" event);
      check string "newest event" "t-new" (json_string "turn_id" event)
    | _ -> fail "expected one paged event")
;;

let test_list_events_merges_kinds_newest_first () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t-tool"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:100
      ~summary:"tool"
      ~file_path:None
      ~timestamp_ms:1000L
      ();
    seed_turn_row
      ~base_dir
      ~turn_id:"t-turn"
      ~keeper_id:"k1"
      ~phase:"completed"
      ~timestamp_ms:3000L;
    let events =
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:"github.com_other_repo"
        ~limit:2
        ()
    in
    check (list string) "newest-first types" [ "turn"; "tool" ]
      (List.map (json_string "type") events);
    check (list int64) "newest-first timestamps" [ 3000L; 1000L ]
      (List.map (json_intlit "timestamp_ms") events))
;;

(* masc#28582: the row carries the path the attribution resolver named, not the
   argument the keeper typed. The two differ whenever the keeper addressed a
   file through its sandbox — which is the normal case — and a consumer that
   joins on [file_path] can only match one of them. *)
let test_hook_row_carries_the_resolved_path_not_the_raw_argument () =
  with_temp_dir (fun base_dir ->
    let raw_argument =
      "/base/.masc/playground/delta/repos/masc/lib/keeper/keeper_approval_queue.ml"
    in
    let resolved = "lib/keeper/keeper_approval_queue.ml" in
    let input =
      `Assoc [ "path", `String raw_argument; "line_start", `Int 5 ]
    in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:(addressed_file ~codebase:"github.com_x_y" ~path:resolved)
      ~tool_name:"edit_file"
      ~keeper_id:"delta"
      ~turn_id:"turn-3"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:4.0
      ~output_text:"edited"
      ~input;
    match
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:("github.com_x_y")
        ~kind:Ide_bridge.Tool
        ()
    with
    | [ event ] ->
      check string "event carries the resolved path" resolved (json_string "file_path" event)
    | events -> Alcotest.failf "expected one tool event, got %d" (List.length events))
;;

(* A tool call that names no file stores no document: the row is a
   keeper-timeline fact. *)
let test_pathless_hook_stores_no_document () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:Agent_observation.Pathless
      ~tool_name:"masc_broadcast"
      ~keeper_id:"delta"
      ~turn_id:"turn-4"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:1.0
      ~output_text:"sent"
      ~input:(`Assoc [ "message", `String "hello" ]);
    (* RFC-0378 §5.2: nothing is persisted — the keeper-timeline record of
       a pathless call lives in the tool_calls store, not here. *)
    match
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:"github.com_x_y"
        ~kind:Ide_bridge.Tool
        ()
    with
    | [] -> ()
    | events ->
      Alcotest.failf "pathless call must persist nothing, got %d" (List.length events))
;;

(* RFC-0378 §5.2: an unaddressed write is a keeper fact — the ide store
   persists no row for it; its durable record is the tool_calls store. *)
let test_unaddressed_hook_persists_nothing () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:(unattributed_file "/outside/tree.ml")
      ~tool_name:"edit_file"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:1.0
      ~output_text:"x"
      ~input:
        (`Assoc [ "path", `String "/outside/tree.ml"; "line_start", `Int 1 ]);
    match
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:"github.com_x_y"
        ~kind:Ide_bridge.Tool
        ()
    with
    | [] -> ()
    | events ->
      Alcotest.failf "unaddressed call must persist nothing, got %d" (List.length events))
;;



let test_hook_no_file_path () =
  with_temp_dir (fun base_dir ->
    let input = `Assoc [ "command", `String "ls" ] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:Agent_observation.Pathless
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:10.0
      ~output_text:"file1.ml\nfile2.ml"
      ~input;
    (* RFC-0378 §5.2: a pathless call is a keeper fact — the ide store
       persists nothing for it, in any store. *)
    let dir = Ide_paths.code_store_dir ~base_dir:base_dir ~codebase:"github.com_other_repo" in
    let path = Filename.concat dir "tool_events.jsonl" in
    check bool "pathless call persists no ide row" false (Sys.file_exists path))
;;

let test_hook_summary_truncation () =
  with_temp_dir (fun base_dir ->
    let long_output = String.make 300 'x' in
    let input = `Assoc [] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:(addressed_file ~codebase:"github.com_x_y" ~path:"lib/test.ml")
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:10.0
      ~output_text:long_output
      ~input;
    let dir =
      Ide_paths.code_store_dir
        ~base_dir:base_dir
        ~codebase:"github.com_x_y"
    in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let summary = Yojson.Safe.Util.member "summary" json |> Yojson.Safe.Util.to_string in
    check bool "summary truncated" true (String.length summary <= 200))
;;

let test_hook_typed_outcome_mapping () =
  with_temp_dir (fun base_dir ->
    let input = `Assoc [] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:(addressed_file ~codebase:"github.com_x_y" ~path:"lib/test.ml")
      ~tool_name:"execute"
      ~keeper_id:"k1"
      ~turn_id:"t1"
      ~outcome:"error"
      ~typed_outcome_str:"error"
      ~duration_ms:10.0
      ~output_text:"command failed"
      ~input;
    let dir =
      Ide_paths.code_store_dir
        ~base_dir:base_dir
        ~codebase:"github.com_x_y"
    in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let line = input_line ic in
    close_in ic;
    let json = Yojson.Safe.from_string line in
    let typed = Yojson.Safe.Util.member "typed_outcome" json |> Yojson.Safe.Util.to_string in
    check string "typed_outcome" "error" typed)
;;

let test_concurrent_ingest () =
  with_temp_dir (fun base_dir ->
    (* Simulate parallel tool calls writing to the same file *)
    let n = 50 in
    let fibers = List.init n (fun i ->
      fun () ->
        Ide_bridge.ingest_tool_event
          ~base_path:base_dir
          ~codebase:"github.com_other_repo"
          ~tool_name:"fs_write"
          ~keeper_id:"k1"
          ~turn_id:(Printf.sprintf "t-%d" i)
          ~outcome:"success"
          ~typed_outcome:"progress"
          ~latency_ms:i
          ~summary:(Printf.sprintf "event %d" i)
          ~file_path:None
          ~timestamp_ms:(Int64.of_int (1000 + i))
          ())
    in
    (* Run all fibers concurrently via Eio *)
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        List.iter (fun f -> Eio.Fiber.fork ~sw f) fibers));
    (* Verify all events were written *)
    let dir = Ide_paths.code_store_dir ~base_dir:base_dir ~codebase:"github.com_other_repo" in
    let path = Filename.concat dir "tool_events.jsonl" in
    let ic = open_in path in
    let count = ref 0 in
    (try while true do ignore (input_line ic); incr count done with End_of_file -> ());
    close_in ic;
    check int "all events written" n !count)
;;

(* ── Segment rotation + tail-read (IDE v2 A2/A3) ──────────────────── *)

let tool_row i =
  `Assoc
    [ "type", `String "tool"
    ; "keeper_id", `String "k1"
    ; "timestamp_ms", `Int i
    ; "turn_id", `String (Printf.sprintf "t-%d" i)
    ]
;;

let row_timestamp line =
  Yojson.Safe.from_string line
  |> Yojson.Safe.Util.member "timestamp_ms"
  |> Yojson.Safe.Util.to_int
;;

let read_lines path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let rec loop acc =
         match input_line ic with
         | line -> loop (line :: acc)
         | exception End_of_file -> List.rev acc
       in
       loop [])
;;

(* (a) The live segment rotates to a numbered archive once it reaches the
   size threshold; the live filename stays stable. *)
let test_segment_rotates_on_threshold () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    for i = 1 to 6 do
      Ide_bridge.For_testing.append_rotating
        ~path
        ~max_segment_bytes:100
        ~max_retained_segments:8
        (tool_row i)
    done;
    check bool "live segment exists" true (Sys.file_exists path);
    check bool "at least one archive created" true
      (List.length (Ide_bridge.For_testing.archive_indices ~path) >= 1))
;;

(* (b)+(d) A budget-limited tail-read of a 100-row live segment returns
   exactly the newest [budget] rows — not the whole file — proving the read
   cost is bounded by [budget], not by file size. *)
let test_tail_read_returns_newest_bounded () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    for i = 1 to 100 do
      Ide_bridge.For_testing.append_rotating
        ~path
        ~max_segment_bytes:max_int (* never rotate: single live segment *)
        ~max_retained_segments:8
        (tool_row i)
    done;
    let lines = Ide_bridge.For_testing.tail_read_lines ~path ~budget:5 in
    check int "reads only budget rows, not all 100" 5 (List.length lines);
    check (list int) "newest five rows, oldest-first"
      [ 96; 97; 98; 99; 100 ]
      (List.map row_timestamp lines))
;;

(* (c) When the budget exceeds the newest segment's rows, the tail-read
   expands into the previous segment. Rows 1..3 land in archive .1, rows
   4..6 in the live segment; a budget of 5 returns the newest 5 overall
   (rows 2..6), drawing from both segments. *)
let test_tail_read_crosses_boundary () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    let append ~cap i =
      Ide_bridge.For_testing.append_rotating
        ~path ~max_segment_bytes:cap ~max_retained_segments:8 (tool_row i)
    in
    List.iter (fun i -> append ~cap:max_int i) [ 1; 2; 3 ];
    append ~cap:1 4 (* rotates rows 1..3 into an archive, row 4 into fresh live *);
    List.iter (fun i -> append ~cap:max_int i) [ 5; 6 ];
    check int "one archive present" 1
      (List.length (Ide_bridge.For_testing.archive_indices ~path));
    let lines = Ide_bridge.For_testing.tail_read_lines ~path ~budget:5 in
    check int "budget rows collected across segments" 5 (List.length lines);
    let timestamps = List.map row_timestamp lines |> List.sort compare in
    check (list int) "newest five across both segments" [ 2; 3; 4; 5; 6 ] timestamps)
;;

(* (e) Retention prunes the oldest archives, keeping at most
   [max_retained_segments] of them (the most recent by index). *)
let test_retention_prunes_old_segments () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    for i = 1 to 10 do
      Ide_bridge.For_testing.append_rotating
        ~path ~max_segment_bytes:1 ~max_retained_segments:2 (tool_row i)
    done;
    check bool "live segment exists" true (Sys.file_exists path);
    check (list int) "keeps only the two newest archives"
      [ 8; 9 ]
      (List.sort compare (Ide_bridge.For_testing.archive_indices ~path)))
;;

let test_concurrent_rotation_preserves_rows () =
  with_temp_dir (fun base_dir ->
    let path = Filename.concat base_dir "tool_events.jsonl" in
    let workers = 8 in
    let per_worker = 20 in
    let domains =
      List.init workers (fun worker ->
        Domain.spawn (fun () ->
          for i = 1 to per_worker do
            let row_id = (worker * 1000) + i in
            Ide_bridge.For_testing.append_rotating
              ~path
              ~max_segment_bytes:1
              ~max_retained_segments:(workers * per_worker)
              (tool_row row_id)
          done))
    in
    List.iter Domain.join domains;
    let timestamps =
      Ide_bridge.For_testing.segment_paths_newest_first ~path
      |> List.concat_map read_lines
      |> List.map row_timestamp
      |> List.sort_uniq compare
    in
    check
      int
      "concurrent rotations preserve every appended row"
      (workers * per_worker)
      (List.length timestamps))
;;

(* Integration: [list_events] merges live and archived segments through the
   public API, newest-first. *)
let test_list_events_reads_across_segments () =
  with_temp_dir (fun base_dir ->
    Ide_bridge.ingest_tool_event
      ~base_path:base_dir
      ~codebase:"github.com_other_repo"
      ~tool_name:"write_file"
      ~keeper_id:"k1"
      ~turn_id:"t-live"
      ~outcome:"success"
      ~typed_outcome:"progress"
      ~latency_ms:10
      ~summary:"live"
      ~file_path:None
      ~timestamp_ms:5000L
      ();
    let dir = Ide_paths.code_store_dir ~base_dir ~codebase:"github.com_other_repo" in
    let path = Filename.concat dir "tool_events.jsonl" in
    let oc = open_out (path ^ ".1") in
    output_string oc
      ({|{"type":"tool","keeper_id":"k1","timestamp_ms":1000,"turn_id":"t-arch"}|}
       ^ "\n");
    close_out oc;
    let events =
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:"github.com_other_repo"
        ~kind:Ide_bridge.Tool
        ~limit:10
        ()
    in
    check int "reads both live and archived segments" 2 (List.length events);
    check (list string) "newest-first across segments" [ "t-live"; "t-arch" ]
      (List.map (json_string "turn_id") events))
;;

(* ── Bounded ingestion queue (IDE v2 A1) ─────────────────────────── *)

(* (e) With no writer installed, submit runs the job inline (works outside an
   Eio context), preserving the previous synchronous behavior. *)
let test_queue_inline_when_no_writer () =
  Ide_ingest_queue.For_testing.reset ();
  let ran = ref 0 in
  Ide_ingest_queue.submit (fun () -> incr ran);
  check int "job runs inline when inactive" 1 !ran
;;

(* (a)+(b) When active, submit only enqueues — the job (which is where the
   Yojson parse + append live) does not run on the calling fiber. It runs on
   drain. This is what keeps the hot path free of parse/I/O. *)
let test_queue_defers_when_active () =
  Eio_main.run (fun _env ->
    Ide_ingest_queue.For_testing.reset ();
    Ide_ingest_queue.For_testing.set_active true;
    let ran = ref 0 in
    Ide_ingest_queue.submit (fun () -> incr ran);
    check int "job not run on the calling fiber" 0 !ran;
    check int "job is queued" 1 (Ide_ingest_queue.depth ());
    Ide_ingest_queue.drain_pending ();
    check int "job runs on drain" 1 !ran)
;;

(* (c) At capacity, the oldest queued job is dropped (counted) so the newest
   survive and enqueue never blocks. *)
let test_queue_drop_oldest () =
  Eio_main.run (fun _env ->
    Ide_ingest_queue.For_testing.reset ~capacity_override:4 ();
    Ide_ingest_queue.For_testing.set_active true;
    let tags = ref [] in
    for i = 1 to 10 do
      Ide_ingest_queue.submit (fun () -> tags := i :: !tags)
    done;
    check int "depth capped at capacity" 4 (Ide_ingest_queue.depth ());
    check int "dropped the six oldest" 6 (Ide_ingest_queue.dropped_count ());
    Ide_ingest_queue.drain_pending ();
    check (list int) "newest four survive, oldest dropped" [ 7; 8; 9; 10 ]
      (List.rev !tags))
;;

(* (d) A running writer fiber drains every submitted job. [Eio.Fiber.first]
   runs the writer alongside the producer and cancels it once the producer has
   observed all jobs executed. *)
let test_queue_writer_drains () =
  Eio_main.run (fun _env ->
    Ide_ingest_queue.For_testing.reset ();
    let n = 20 in
    let ran = Atomic.make 0 in
    Eio.Fiber.first
      (fun () -> Ide_ingest_queue.run_writer ())
      (fun () ->
        for _ = 1 to n do
          Ide_ingest_queue.submit (fun () -> Atomic.incr ran)
        done;
        let tries = ref 0 in
        while Atomic.get ran < n && !tries < 100_000 do
          Eio.Fiber.yield ();
          incr tries
        done);
    check int "writer drained all jobs" n (Atomic.get ran))
;;

(* The typed codebase carried through the hook path must route the tool event
   into that codebase's store. *)
let test_codebase_routes_tool_event () =
  with_temp_dir (fun base_dir ->
    let by_url = "github.com_jeong-sik_wkbl" in
    let input = `Assoc [ "file_path", `String "lib/test.ml"; "line", `Int 7 ] in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:(addressed_file ~codebase:"github.com_jeong-sik_wkbl" ~path:"lib/test.ml")
      ~tool_name:"keeper_ide_annotate"
      ~keeper_id:"k1"
      ~turn_id:"turn-1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:5.0
      ~output_text:"{}"
      ~input;
    (* Scoped (by-url) reads see the tool event. *)
    let by_url_events =
      Ide_bridge.list_events ~base_path:base_dir ~codebase:by_url ()
    in
    check bool "codebase holds the tool event" true
      (List.length by_url_events >= 1);
    let other_events =
      Ide_bridge.list_events ~base_path:base_dir
        ~codebase:"github.com_other_repo" ()
    in
    check int "other codebase has no tool event" 0 (List.length other_events))
;;

let test_codebases_are_isolated () =
  with_temp_dir (fun base_dir ->
    let input =
      `Assoc [ "file_path", `String "lib/test.ml"; "line", `Int 3 ]
    in
    Ide_bridge.ingest_tool_event_from_hook
      ~base_path:base_dir
      ~attribution:(addressed_file ~codebase:"github.com_x_y" ~path:"lib/test.ml")
      ~tool_name:"keeper_ide_annotate"
      ~keeper_id:"k1"
      ~turn_id:"turn-1"
      ~outcome:"ok"
      ~typed_outcome_str:"progress"
      ~duration_ms:5.0
      ~output_text:"{}"
      ~input;
    let by_url_events =
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:("github.com_x_y")
        ()
    in
    check bool "addressed write lands in its codebase" true
      (List.length by_url_events >= 1);
    let other_events =
      Ide_bridge.list_events ~base_path:base_dir ~codebase:"github.com_other_repo" ()
    in
    check int "other codebase does not see the addressed write" 0
      (List.length other_events))
;;

let () =
  run
    "ide_bridge"
    [ ( "ingest"
      , [ test_case "tool event" `Quick test_ingest_tool_event
        ; test_case "seeded turn rows remain readable" `Quick test_turn_rows_remain_readable
        ; test_case "multiple events" `Quick test_ingest_multiple_events
        ] )
    ; ( "codebase attribution"
      , [ test_case "routes tool event" `Quick test_codebase_routes_tool_event
        ; test_case "codebases are isolated" `Quick test_codebases_are_isolated
        ] )
    ; ( "read"
      , [ test_case "filters keeper and pages" `Quick test_list_events_filters_keeper_and_pages
        ; test_case "merges kinds newest first" `Quick test_list_events_merges_kinds_newest_first
        ; test_case "reads across segments" `Quick test_list_events_reads_across_segments
        ] )
    ; ( "rotation"
      , [ test_case "rotates on threshold" `Quick test_segment_rotates_on_threshold
        ; test_case "tail-read returns newest bounded" `Quick
            test_tail_read_returns_newest_bounded
        ; test_case "tail-read crosses segment boundary" `Quick
            test_tail_read_crosses_boundary
        ; test_case "retention prunes old segments" `Quick
            test_retention_prunes_old_segments
        ; test_case "concurrent rotations preserve rows" `Quick
            test_concurrent_rotation_preserves_rows
        ] )
    ; ( "ingest_queue"
      , [ test_case "inline when no writer" `Quick test_queue_inline_when_no_writer
        ; test_case "defers job when active" `Quick test_queue_defers_when_active
        ; test_case "drops oldest at capacity" `Quick test_queue_drop_oldest
        ; test_case "writer drains queue" `Quick test_queue_writer_drains
        ] )
    ; ( "document identity"
      , [ test_case
            "row carries the resolved path, not the raw argument"
            `Quick
            test_hook_row_carries_the_resolved_path_not_the_raw_argument
        ; test_case
            "pathless call stores no document"
            `Quick
            test_pathless_hook_stores_no_document
        ; test_case
            "unaddressed hook persists nothing"
            `Quick
            test_unaddressed_hook_persists_nothing
        ] )
    ; ( "hook_extract"
      , [ test_case "no file_path (execute)" `Quick test_hook_no_file_path
        ; test_case "summary truncation" `Quick test_hook_summary_truncation
        ; test_case "typed_outcome mapping" `Quick test_hook_typed_outcome_mapping
        ] )
    ; ( "concurrency"
      , [ test_case "concurrent ingest" `Quick test_concurrent_ingest
        ] )
    ]
