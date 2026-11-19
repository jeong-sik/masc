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
  | Error (Masc_tui_loader.Archive_malformed error | Archive_unreadable error) -> fail error
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
       | Error (Masc_tui_loader.Archive_malformed error | Archive_unreadable error) ->
           fail error);
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

(* What the bytes of one version say is kept with it, a fault as well as a
   reading, so an archive stuck in a shape that is not an archive is not
   streamed again on every Work read. A file that cannot be opened now is
   not kept. Taking the read permission away keeps the file version, so
   which of the two answers tells whether the file was opened again. *)
let test_a_fault_is_kept_only_when_the_bytes_said_it () =
  if Unix.geteuid () = 0 then skip ();
  let dir = Filename.temp_dir "masc-task-archive-fault-" "" in
  let path = Filename.concat dir "tasks-archive.json" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod path 0o600 with Unix.Unix_error _ -> ());
      (try Sys.remove path with Sys_error _ -> ());
      Sys.rmdir dir)
    (fun () ->
      let malformed () =
        match Masc_tui_loader.read_archive path with
        | Error (Masc_tui_loader.Archive_malformed _) -> true
        | Ok _ | Error (Masc_tui_loader.Archive_unreadable _) -> false
      in
      let unreadable () =
        match Masc_tui_loader.read_archive path with
        | Error (Masc_tui_loader.Archive_unreadable _) -> true
        | Ok _ | Error (Masc_tui_loader.Archive_malformed _) -> false
      in
      Out_channel.with_open_bin path (fun channel ->
        Out_channel.output_string channel "{\"tasks\":[]} trailing");
      check bool "bytes after the object are not an archive" true (malformed ());
      Unix.chmod path 0o000;
      check bool "the same version answers from what its bytes said" true (malformed ());
      Unix.chmod path 0o600;
      let replacement = path ^ ".replacement" in
      Out_channel.with_open_bin replacement (fun channel ->
        Out_channel.output_string channel "{\"tasks\":[]}");
      Unix.chmod replacement 0o000;
      Unix.rename replacement path;
      check bool "a file that cannot be opened is unreadable" true (unreadable ());
      Unix.chmod path 0o600;
      check bool "and that is not kept" true
        (match Masc_tui_loader.read_archive path with
         | Ok reading -> reading.undecoded = 0
         | Error (Masc_tui_loader.Archive_malformed _ | Archive_unreadable _) -> false))

(* The whole-file readers repair invalid UTF-8 before they parse; this
   reader takes the bytes as they are. A row whose id is not UTF-8 does not
   decode, so a task the backlog holds under the repaired id is not counted
   a second time from the archive. *)
let test_an_id_that_is_not_utf8_does_not_decode () =
  let dir = Filename.temp_dir "masc-task-archive-utf8-" "" in
  let path = Filename.concat dir "tasks-archive.json" in
  let restored = task ~id:"restored\xff" ~created_at:"2026-09-12T01:00:00Z"
      (done_at "2026-09-12T02:00:00Z") in
  let live = [ { restored with id = Safe_ops.repair_utf8_text restored.id } ] in
  Yojson.Safe.to_file path
    (`Assoc [ ("tasks", `List [ Masc_domain.task_to_yojson restored ]) ]);
  Fun.protect ~finally:(fun () -> Sys.remove path; Sys.rmdir dir) (fun () ->
    let reading = read_archive path in
    check int "the row is counted as one that does not decode" 1 reading.undecoded;
    let flow = Masc_tui_task_flow.of_tasks ~now ~archived:reading.archived live in
    check int "the task is completed once, as live" 1 flow.recent.completed)

(* The Work read keeps the decoded backlog across refreshes and events, and
   decodes it again when the file is another version, including a
   replacement that keeps the size and the modification time. *)
let test_backlog_decoded_again_only_when_its_version_moves () =
  let dir = Filename.temp_dir "masc-task-backlog-" "" in
  let masc = Filename.concat dir ".masc" in
  let tasks = Filename.concat masc "tasks" in
  Unix.mkdir masc 0o700;
  Unix.mkdir tasks 0o700;
  let backlog = Filename.concat tasks "backlog.json" in
  let body title =
    Yojson.Safe.to_string
      (`Assoc
        [ ("tasks",
           `List [ Masc_domain.task_to_yojson
                     (task ~id:"task-fixture" ~created_at:"2026-01-01T00:00:00Z" Todo
                      |> fun task -> { task with title }) ]);
          ("last_updated", `String "2026-01-01T00:00:00Z");
          ("version", `Int 1) ])
  in
  Out_channel.with_open_bin backlog (fun channel ->
    Out_channel.output_string channel (body "backlog-OLD"));
  let stamp = Float.floor (Unix.gettimeofday ()) -. 1. in
  Unix.utimes backlog stamp stamp;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> try Sys.remove path with Sys_error _ -> ())
        [ backlog; Filename.concat masc "tasks-archive.json" ];
      List.iter (fun path -> try Unix.rmdir path with Unix.Unix_error _ -> ())
        [ tasks; masc; dir ])
    (fun () ->
      let domain_rows () =
        let _, rows, _, _, _, _ = Masc_tui_loader.load_active_tasks dir in
        rows
      in
      let first = domain_rows () in
      check bool "an unchanged backlog is not decoded again" true (domain_rows () == first);
      let before, after = replace backlog (body "backlog-NEW") ~keep_stat:true in
      check bool "the replacement keeps size and modification time" true
        (before.Unix.st_size = after.Unix.st_size
         && Float.equal before.Unix.st_mtime after.Unix.st_mtime);
      check (list string) "a same-stat replacement is decoded again" [ "backlog-NEW" ]
        (List.map (fun (task : Masc_domain.task) -> task.title) (domain_rows ())))

(* The Work read itself, not only [read_archive], takes the kept archive
   while the file version holds. Taking the read permission away keeps the
   device, inode, size and modification time, so a Work read that opened
   the archive again would answer that it is unavailable. *)
let test_work_read_does_not_open_an_unchanged_archive () =
  if Unix.geteuid () = 0 then skip ();
  let dir = Filename.temp_dir "masc-task-work-read-" "" in
  let masc = Filename.concat dir ".masc" in
  let tasks = Filename.concat masc "tasks" in
  Unix.mkdir masc 0o700;
  Unix.mkdir tasks 0o700;
  let backlog = Filename.concat tasks "backlog.json" in
  let archive = Filename.concat masc "tasks-archive.json" in
  Yojson.Safe.to_file backlog
    (`Assoc
      [ ("tasks", `List (List.map Masc_domain.task_to_yojson live));
        ("last_updated", `String "2026-09-12T11:00:00Z");
        ("version", `Int 1) ]);
  Yojson.Safe.to_file archive
    (`Assoc [ ("tasks", `List (List.map Masc_domain.task_to_yojson archived)) ]);
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod archive 0o600 with Unix.Unix_error _ -> ());
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) [ backlog; archive ];
      List.iter (fun path -> try Unix.rmdir path with Unix.Unix_error _ -> ())
        [ tasks; masc; dir ])
    (fun () ->
      let tasks_error () =
        let _, _, error, _, _, _ = Masc_tui_loader.load_active_tasks dir in
        error
      in
      let first = tasks_error () in
      check (option string) "the archive reads" None first;
      let before = Unix.stat archive in
      Unix.chmod archive 0o000;
      let after = Unix.stat archive in
      check bool "taking the permission keeps the file version" true
        (before.Unix.st_ino = after.Unix.st_ino
         && before.Unix.st_size = after.Unix.st_size
         && Float.equal before.Unix.st_mtime after.Unix.st_mtime);
      check bool "the archive cannot be opened now" true
        (match Unix.openfile archive [ Unix.O_RDONLY ] 0 with
         | descriptor -> Unix.close descriptor; false
         | exception Unix.Unix_error (Unix.EACCES, _, _) -> true);
      check (option string) "the next Work read takes the kept archive" first (tasks_error ()))

let () =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    run "tui_task_archive"
      [ ( "flow",
          [ test_case "the archive's days, window and leftovers" `Quick
              test_counts_with_the_archive ] );
        ( "reader",
          [ test_case "kept until the file version moves" `Quick
              test_kept_until_the_file_version_moves;
            test_case "archive shapes" `Quick test_archive_shapes;
            test_case "a fault is kept only when the bytes said it" `Quick
              test_a_fault_is_kept_only_when_the_bytes_said_it;
            test_case "an id that is not UTF-8 does not decode" `Quick
              test_an_id_that_is_not_utf8_does_not_decode;
            test_case "backlog decoded again only when its version moves" `Quick
              test_backlog_decoded_again_only_when_its_version_moves;
            test_case "a Work read does not open an unchanged archive" `Quick
              test_work_read_does_not_open_an_unchanged_archive ] ) ])
