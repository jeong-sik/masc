(* What the archive adds to the task flow: the days and the 24 hour window
   count archived tasks, a task that is also live counts once, bad times
   are counted, an archived open task can be the oldest open one, and a row
   that does not decode is counted apart. The fixture is written to a file
   and read back the way the TUI reads it. *)

open Alcotest

let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-12T12:00:00Z")

let task ~id ~created_at status : Masc_domain.task =
  { id; title = id; description = ""; task_status = status; priority = 3;
    files = []; created_at; created_by = Some "producer";
    predecessor_task_id = None; contract = None;
    execution_links = Masc_domain.no_execution_links; handoff_context = None;
    cycle_count = 0; skills = [] }

let done_at at =
  Masc_domain.Done { assignee = "producer"; completed_at = at; notes = None }

let cancelled_at at =
  Masc_domain.Cancelled { cancelled_by = "producer"; cancelled_at = at; reason = None }

let live =
  [ task ~id:"live-open" ~created_at:"2026-09-12T01:00:00Z" Todo;
    task ~id:"both" ~created_at:"2026-09-11T00:00:00Z" (done_at "2026-09-11T13:00:00Z") ]

let archived =
  [ task ~id:"done-recent" ~created_at:"2026-09-10T00:00:00Z" (done_at "2026-09-11T20:00:00Z");
    task ~id:"cancel-recent" ~created_at:"2026-09-12T02:00:00Z"
      (cancelled_at "2026-09-12T03:00:00Z");
    task ~id:"done-in-span" ~created_at:"2026-08-20T00:00:00Z" (done_at "2026-09-01T00:00:00Z");
    task ~id:"done-ancient" ~created_at:"2026-07-01T00:00:00Z" (done_at "2026-07-02T00:00:00Z");
    (* Also live: counted once, as live. *)
    task ~id:"both" ~created_at:"2026-09-11T00:00:00Z" (done_at "2026-09-11T13:00:00Z");
    (* The decoder refuses a status time that is not RFC 3339, so only the
       registration time can be bad on a row that decodes. *)
    task ~id:"bad-created" ~created_at:"not a time" (done_at "2026-09-02T00:00:00Z");
    task ~id:"stranded-open" ~created_at:"2026-09-05T00:00:00Z" Todo;
    task ~id:"future-open" ~created_at:"2026-09-13T00:00:00Z" Todo ]

let archive_json =
  `Assoc
    [ ("last_updated", `String "2026-09-12T11:00:00Z");
      ( "tasks",
        `List
          (List.map Masc_domain.task_to_yojson archived
           @ [ `Assoc [ ("id", `String "broken"); ("title", `Int 7) ] ]) ) ]

let with_archive_file f =
  let dir = Filename.temp_dir "masc-task-archive-" "" in
  let path = Filename.concat dir "tasks-archive.json" in
  Yojson.Safe.to_file path archive_json;
  Fun.protect ~finally:(fun () -> Sys.remove path; Sys.rmdir dir) (fun () -> f path)

let day_rows (flow : Masc_tui_task_flow.t) =
  List.filter_map
    (fun (day : Masc_tui_task_flow.day) ->
      match day.d_created, day.d_completed, day.d_cancelled with
      | 0, 0, 0 -> None
      | created, completed, cancelled ->
          let tm = Unix.gmtime day.d_start in
          Some
            (Printf.sprintf "%02d-%02d %d/%d/%d" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
               created completed cancelled))
    flow.daily

let read_archive path =
  match Masc_tui_loader.read_archive path with
  | Error error -> fail error
  | Ok reading -> reading

let flow_of_archive_file path =
  let reading = read_archive path in
  Masc_tui_task_flow.of_tasks ~now ~archived:reading.archived live, reading.undecoded

let test_counts_with_the_archive () =
  with_archive_file (fun path ->
    let flow, undecoded = flow_of_archive_file path in
    check int "the row that does not decode is counted apart" 1 undecoded;
    check int "created in the window" 2 flow.recent.created;
    check int "completed in the window" 2 flow.recent.completed;
    check int "cancelled in the window" 1 flow.recent.cancelled;
    check int "bad times are counted" 1 flow.unparseable_timestamps;
    check (option (float 0.)) "an archived open task can be the oldest"
      (Masc_domain.parse_iso8601_opt "2026-09-05T00:00:00Z")
      flow.oldest_open_created_at;
    check int "the span is the declared number of days" Masc_tui_task_flow.daily_days
      (List.length flow.daily);
    check (list string) "the days the archive and the backlog fill"
      [ "09-01 0/1/0"; "09-02 0/1/0"; "09-05 1/0/0"; "09-10 1/0/0"; "09-11 1/2/0"; "09-12 2/0/1" ]
      (day_rows flow);
    check int "the board count is the backlog's" 1 flow.current.completed;
    check int "open on the board is the backlog's" 1 flow.current.todo)

(* A replacement the way writers make one: a new file renamed over the old.
   [keep_stat] gives it the old file's modification time, which
   [Unix.utimes] copies exactly only when it is whole seconds. *)
let replace path contents ~keep_stat =
  let before = Unix.stat path in
  let replacement = path ^ ".replacement" in
  Out_channel.with_open_bin replacement (fun channel ->
    Out_channel.output_string channel contents);
  if keep_stat then Unix.utimes replacement before.Unix.st_atime before.Unix.st_mtime;
  Unix.rename replacement path;
  before, Unix.stat path

let test_kept_until_the_file_version_moves () =
  with_archive_file (fun path ->
    let first = read_archive path in
    check bool "an unchanged archive is not decoded again" true (read_archive path == first);
    (* Same bytes, new inode: the version moved, so the value is replaced
       even though nothing it counts changed. *)
    let original = In_channel.with_open_bin path In_channel.input_all in
    let _, _ = replace path original ~keep_stat:false in
    let stamp = Float.floor (Unix.gettimeofday ()) -. 1. in
    Unix.utimes path stamp stamp;
    let second = read_archive path in
    check bool "a new file version is decoded again" false (second == first);
    check bool "and then kept" true (read_archive path == second);
    (* Same size and modification time, other content: only the inode
       tells it apart. *)
    let swapped =
      Str.global_replace (Str.regexp_string "\"done-recent\"") "\"done-recenT\"" original
    in
    check int "the swap keeps the size" (String.length original) (String.length swapped);
    let before, after = replace path swapped ~keep_stat:true in
    check bool "the replacement keeps size and modification time" true
      (before.Unix.st_size = after.Unix.st_size
       && Float.equal before.Unix.st_mtime after.Unix.st_mtime);
    let third = read_archive path in
    check bool "a same-stat replacement is decoded again" false (third == second))

let test_archive_shapes () =
  let dir = Filename.temp_dir "masc-task-archive-shapes-" "" in
  let path = Filename.concat dir "tasks-archive.json" in
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with Sys_error _ -> ()); Sys.rmdir dir)
    (fun () ->
      (match Masc_tui_loader.read_archive path with
       | Ok reading ->
           check bool "a missing archive is empty" true (reading == Masc_tui_loader.no_archive)
       | Error error -> fail error);
      let refused contents =
        Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel contents);
        (* A fresh inode each time, so no kept value answers. *)
        let copy = path ^ ".copy" in
        Out_channel.with_open_bin copy (fun channel -> Out_channel.output_string channel contents);
        Unix.rename copy path;
        Result.is_error (Masc_tui_loader.read_archive path)
      in
      check bool "no tasks list is an error" true (refused "{\"last_updated\":\"x\"}");
      check bool "two tasks lists are an error" true (refused "{\"tasks\":[],\"tasks\":[]}");
      check bool "a list is not an archive" true (refused "[]");
      check bool "a cut file is an error" true (refused "{\"tasks\":[");
      check bool "an empty tasks list reads" false (refused "{\"tasks\":[]}\n"))

let () =
  Eio_main.run (fun _env ->
    run "tui_task_archive"
      [ ( "flow",
          [ test_case "the archive's days, window and leftovers" `Quick
              test_counts_with_the_archive ] );
        ( "reader",
          [ test_case "kept until the file version moves" `Quick
              test_kept_until_the_file_version_moves;
            test_case "archive shapes" `Quick test_archive_shapes ] ) ])
