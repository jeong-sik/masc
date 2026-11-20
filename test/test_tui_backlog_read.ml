(* RFC-tui-backlog-read: the TUI's backlog reader answers what the full
   reader answers for the same file. Each step replaces the file the way
   writers do (a new file renamed over it) and compares the two readers'
   answers: tasks added, changed, removed, reordered and repeated, rows and
   documents that do not decode, with and without a recovery copy, and the
   valid file again after them. The steps run in order on one reader, so
   every step after the first starts from the rows of the one before. *)

open Alcotest

let task ?(title = "") ~id status : Masc_domain.task =
  { id; title = (if title = "" then id else title); description = "the " ^ id;
    task_status = status; priority = 3; files = []; created_at = "2026-11-20T00:00:00Z";
    created_by = Some "producer"; predecessor_task_id = None; contract = None;
    execution_links = Masc_domain.no_execution_links; handoff_context = None;
    cycle_count = 0; skills = [] }

let claimed = Masc_domain.Claimed { assignee = "keeper-a"; claimed_at = "2026-11-20T01:00:00Z" }
let in_progress = Masc_domain.InProgress { assignee = "keeper-a"; started_at = "2026-11-20T02:00:00Z" }
let done_ = Masc_domain.Done { assignee = "keeper-b"; completed_at = "2026-11-20T03:00:00Z"; notes = Some "ok" }

let t1 = task ~id:"task-1" Masc_domain.Todo
let t2 = task ~id:"task-2" claimed
(* Quotes, a backslash, a bracket and a brace inside strings, and a
   non-ASCII title: a row ends where the lexer says, not at the first ']'. *)
let t3 = task ~id:"task-3" ~title:"say \"]}\" and \\ then 한글" in_progress
let t4 = task ~id:"task-4" done_
let t5 = task ~id:"task-5" (Masc_domain.Cancelled { cancelled_by = "op"; cancelled_at = "2026-11-20T04:00:00Z"; reason = None })
let t6 = task ~id:"task-6" Masc_domain.Todo

let document ?(version = 7) tasks =
  Masc_domain.backlog_to_yojson
    { tasks; pending_completion_rejections = []; delivered_completion_rejections = [];
      pending_completion_approvals = []; task_deletion_receipts = [];
      task_creation_receipts = []; last_updated = "2026-11-20T05:00:00Z"; version }
  |> Yojson.Safe.pretty_to_string

(* A document with one row spliced in as text, for rows no encoder writes. *)
let document_with_row ~row tasks =
  let text = document tasks in
  let anchor = "\"tasks\": [" in
  let at = Str.search_forward (Str.regexp_string anchor) text 0 + String.length anchor in
  String.sub text 0 at ^ "\n" ^ row ^ ",\n" ^ String.sub text at (String.length text - at)

let replace path text =
  let temp = path ^ ".writing" in
  Out_channel.with_open_bin temp (fun channel -> Out_channel.output_string channel text);
  Unix.rename temp path

let full config =
  Workspace_backlog.invalidate_backlog_cache config;
  Workspace_backlog.read_backlog_observation_with_source_r config

let observation =
  testable
    (fun formatter (reading : (Workspace_backlog.backlog_observation, string) result) ->
      match reading with
      | Error detail -> Format.fprintf formatter "Error %S" detail
      | Ok { observed_backlog; recovered_from } ->
          Format.fprintf formatter "Ok {recovered=%b; %a}" (Option.is_some recovered_from)
            Masc_domain.pp_backlog observed_backlog)
    ( = )

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "tui-backlog-read-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace_core.default_config base_path in
    let path = Workspace_backlog.backlog_path config in
    Fs_compat.mkdir_p (Filename.dirname path);
    f config path)

let same_as_full config label =
  let tui = Masc_tui_backlog_read.read config in
  check observation label (full config) tui;
  tui

let tasks_of = function
  | Ok (reading : Workspace_backlog.backlog_observation) -> reading.observed_backlog.tasks
  | Error detail -> fail detail

let test_answers_what_the_full_reader_answers () =
  with_workspace (fun config path ->
    let step label text =
      replace path text;
      same_as_full config label
    in
    let first = step "first read" (document [ t1; t2; t3; t4; t5 ]) in
    let again = Masc_tui_backlog_read.read config in
    check bool "an unchanged version is the observation read last" true
      (match first, again with Ok a, Ok b -> a == b | _ -> false);
    let same = step "same bytes, new inode" (document [ t1; t2; t3; t4; t5 ]) in
    check bool "rows with the bytes of the last read are its tasks" true
      (List.for_all2 ( == ) (tasks_of first) (tasks_of same));
    ignore (step "a task added" (document ~version:8 [ t1; t2; t3; t4; t5; t6 ]));
    let changed =
      step "a task changed"
        (document ~version:9
           [ t1; t2; { t3 with title = "renamed"; task_status = done_ }; t4; t5; t6 ])
    in
    check bool "the unchanged rows are the tasks read before" true
      (match tasks_of same, tasks_of changed with
       | a1 :: a2 :: _ :: a4 :: a5 :: _, b1 :: b2 :: b3 :: b4 :: b5 :: _ ->
           a1 == b1 && a2 == b2 && a4 == b4 && a5 == b5 && b3.title = "renamed"
       | _ -> false);
    (* Same length and the same first bytes, one digit different near the end. *)
    ignore
      (step "a task changed at the same length"
         (document ~version:9
            [ t1; t2; { t3 with title = "renamed"; task_status = done_ }; t4;
              { t5 with priority = 4 }; t6 ]));
    ignore (step "a task removed" (document ~version:10 [ t1; t3; t4; t5; t6 ]));
    ignore (step "tasks reordered" (document ~version:11 [ t6; t5; t4; t3; t1 ]));
    ignore (step "a task repeated" (document ~version:12 [ t1; t1; t6 ]));
    ignore
      (step "a row with a field the decoder does not know"
         (document_with_row ~row:{|{"id": "task-7", "title": "t", "status": "todo", "created_at": "2026-11-20T00:00:00Z", "unknown": [1, {"a": "]"}]}|} [ t1 ]));
    ignore
      (step "a comment between rows"
         (document_with_row ~row:{|/* a ] comment */ {"id": "task-8", "title": "t", "status": "todo", "created_at": "2026-11-20T00:00:00Z"}|} [ t1 ]));
    ignore
      (step "a row whose status does not decode, no recovery copy"
         (document_with_row ~row:{|{"id": "task-9", "title": "t", "status": "nope", "created_at": "2026-11-20T00:00:00Z"}|} [ t1; t2 ]));
    ignore (step "a row that is not an object" (document_with_row ~row:"42" [ t1; t2 ]));
    ignore (step "tasks is not a list" {|{"tasks": {}, "last_updated": "x", "version": 1}|});
    ignore
      (step "tasks twice"
         {|{"tasks": [], "tasks": [], "last_updated": "2026-11-20T05:00:00Z", "version": 1}|});
    ignore (step "a document cut short" (String.sub (document [ t1; t2 ]) 0 120));
    ignore (step "something after the document" (document [ t1 ] ^ " []"));
    ignore (step "a blank file" " \n\t ");
    ignore (step "a version that is not positive" (document ~version:0 [ t1 ]));
    ignore
      (step "invalid UTF-8 in a title, which the full reader repairs"
         (document_with_row ~row:"{\"id\": \"task-10\", \"title\": \"bad \xff byte\", \"status\": \"todo\", \"created_at\": \"2026-11-20T00:00:00Z\"}" [ t1 ]));
    ignore (step "spaces around the document" ("\n\n  " ^ document [ t1; t2 ] ^ "\r\n\t"));
    replace (Workspace_backlog.backlog_recovery_path config) (document ~version:5 [ t4 ]);
    ignore
      (step "a row that does not decode, with a recovery copy"
         (document_with_row ~row:{|{"id": "task-9", "title": 7}|} [ t1 ]));
    ignore (step "valid again" (document ~version:13 [ t1; t2; t3; t4; t5; t6 ]));
    Sys.remove path;
    ignore (same_as_full config "no primary file, the recovery copy");
    Sys.remove (Workspace_backlog.backlog_recovery_path config);
    ignore (same_as_full config "no file at all"))

let () =
  run "tui_backlog_read"
    [ ( "full reader",
        [ test_case "answers what the full reader answers" `Quick
            test_answers_what_the_full_reader_answers ] ) ]
