(** Reading what a payout looks at (RFC-goal-candle-ledger 3.4): the Tasks a Goal
    linked, from the backlog and from tasks-archive.json, and the Keepers. *)

open Alcotest
open Masc

(* {1 Fixtures} *)

let temp_dir () =
  let path = Filename.temp_file "candle_tasks_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "planner"));
       f config)
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let write_file path text =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc text)
;;

let make_task ?(title = "A Task") ~id status : Masc_domain.task =
  { Masc_domain.id
  ; title
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-09-01T00:00:00Z"
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

let done_by ?(assignee = "keeper-a") ?(completed_at = "2026-09-25T00:00:00Z") () =
  Masc_domain.Done { assignee; completed_at; notes = None }
;;

let cancelled = Masc_domain.Cancelled { cancelled_by = "operator"; cancelled_at = "2026-09-26T00:00:00Z"; reason = None }

let awaiting_verification =
  Masc_domain.AwaitingVerification
    { assignee = "keeper-c"
    ; started_at = "2026-09-25T00:00:00Z"
    ; submitted_at = "2026-09-26T00:00:00Z"
    ; verification_id = "verification-1"
    }
;;

let write_backlog config tasks =
  Workspace_backlog.write_backlog
    config
    { Masc_domain.tasks
    ; task_deletion_receipts = []
    ; pending_completion_approvals = []; pending_completion_rejections = []
    ; last_updated = "2026-09-29T00:00:00Z"
    ; version = 1
    }
;;

let write_archive config tasks =
  match Workspace.append_archive_tasks config tasks with
  | Ok () -> ()
  | Error detail -> Alcotest.fail ("archive write failed: " ^ detail)
;;

let write_links config links = Workspace_goal_index.write_goal_task_links config links
let lookups config ids = Candle_tasks.lookups config ~goal_id:"goal-1" ids

let lookup_of task_id = function
  | Ok found ->
    (match List.assoc_opt task_id found with
     | Some lookup -> lookup
     | None -> failf "no lookup for %s" task_id)
  | Error detail -> failf "%s" detail
;;

let is_error label = function
  | Ok _ -> failf "%s: expected an error" label
  | Error (_ : string) -> ()
;;

let error_names label ~needle = function
  | Ok _ -> failf "%s: expected an error" label
  | Error detail ->
    check bool (label ^ ": names " ^ needle) true (String_util.contains_substring detail needle)
;;

let time text = Result.get_ok (Candle_time.of_rfc3339 text)

(* {1 Tasks} *)

let test_a_task_in_the_backlog_is_found_with_what_its_status_says () =
  with_workspace
  @@ fun config ->
  write_backlog
    config
    [ make_task ~id:"task-1" ~title:"Write it" (done_by ())
    ; make_task ~id:"task-2" Masc_domain.Todo
    ; make_task ~id:"task-3" awaiting_verification
    ; make_task ~id:"task-4" cancelled
    ; make_task
        ~id:"task-5"
        (Masc_domain.Claimed { assignee = "keeper-d"; claimed_at = "2026-09-25T00:00:00Z" })
    ; make_task
        ~id:"task-6"
        (Masc_domain.InProgress { assignee = "keeper-e"; started_at = "2026-09-25T00:00:00Z" })
    ];
  let found = lookups config [ "task-1"; "task-2"; "task-3"; "task-4"; "task-5"; "task-6" ] in
  (match lookup_of "task-1" found with
   | Candle_event.Found { title; assignee; status = Candle_event.Done { completed_at } } ->
     check string "title" "Write it" title;
     check (option string) "assignee" (Some "keeper-a") assignee;
     check bool "completed_at" true (Candle_time.equal completed_at (time "2026-09-25T00:00:00Z"))
   | Candle_event.Found _ -> fail "task-1 is done"
   | Candle_event.Deleted -> fail "task-1 was not found");
  (match lookup_of "task-2" found with
   | Candle_event.Found { assignee; status = Candle_event.Todo; _ } ->
     check (option string) "no one on a todo Task" None assignee
   | Candle_event.Found _ -> fail "task-2 is todo"
   | Candle_event.Deleted -> fail "task-2 was not found");
  (match lookup_of "task-3" found with
   | Candle_event.Found { assignee; status = Candle_event.Awaiting_verification; _ } ->
     check (option string) "the one who submitted it" (Some "keeper-c") assignee
   | Candle_event.Found _ -> fail "task-3 awaits verification"
   | Candle_event.Deleted -> fail "task-3 was not found");
  (match lookup_of "task-4" found with
   | Candle_event.Found { assignee; status = Candle_event.Cancelled; _ } ->
     check (option string) "whoever cancelled it did not do the work" None assignee
   | Candle_event.Found _ -> fail "task-4 is cancelled"
   | Candle_event.Deleted -> fail "task-4 was not found");
  (match lookup_of "task-5" found with
   | Candle_event.Found { assignee; status = Candle_event.Claimed; _ } ->
     check (option string) "the one who claimed it" (Some "keeper-d") assignee
   | Candle_event.Found _ -> fail "task-5 is claimed"
   | Candle_event.Deleted -> fail "task-5 was not found");
  match lookup_of "task-6" found with
  | Candle_event.Found { assignee; status = Candle_event.In_progress; _ } ->
    check (option string) "the one working on it" (Some "keeper-e") assignee
  | Candle_event.Found _ -> fail "task-6 is in progress"
  | Candle_event.Deleted -> fail "task-6 was not found"
;;

let test_a_task_only_the_archive_has_is_found () =
  with_workspace
  @@ fun config ->
  write_backlog config [];
  write_archive config [ make_task ~id:"task-9" ~title:"Old" (done_by ~assignee:"keeper-b" ()) ];
  match lookup_of "task-9" (lookups config [ "task-9" ]) with
  | Candle_event.Found { title; assignee; _ } ->
    check string "title" "Old" title;
    check (option string) "assignee" (Some "keeper-b") assignee
  | Candle_event.Deleted -> fail "task-9 was not found"
;;

let test_the_backlog_wins_over_the_archive () =
  with_workspace
  @@ fun config ->
  write_backlog config [ make_task ~id:"task-1" ~title:"Live" (done_by ()) ];
  write_archive config [ make_task ~id:"task-1" ~title:"Stale copy" (done_by ()) ];
  match lookup_of "task-1" (lookups config [ "task-1" ]) with
  | Candle_event.Found { title; _ } -> check string "title" "Live" title
  | Candle_event.Deleted -> fail "task-1 was not found"
;;

let test_the_order_asked_is_the_order_answered () =
  with_workspace
  @@ fun config ->
  write_backlog config [ make_task ~id:"task-2" (done_by ()); make_task ~id:"task-1" (done_by ()) ];
  match lookups config [ "task-1"; "task-2" ] with
  | Ok found -> check (list string) "order" [ "task-1"; "task-2" ] (List.map fst found)
  | Error detail -> failf "%s" detail
;;

let test_a_task_neither_store_has_is_deleted_when_the_goal_no_longer_links_it () =
  with_workspace
  @@ fun config ->
  write_backlog config [];
  write_links config [ "goal-1", [ "task-7" ]; "goal-2", [ "task-3" ] ];
  (* Another Goal's link does not keep this Goal's Task alive. *)
  (match lookup_of "task-3" (lookups config [ "task-3" ]) with
   | Candle_event.Deleted -> ()
   | Candle_event.Found _ -> fail "a Task no store has was found");
  error_names "still linked" ~needle:"task-7" (lookups config [ "task-7" ])
;;

(* A payout that could not read the links would take every Task no store has
   for a deleted one, and pay nobody. *)
let test_links_that_do_not_read_are_an_error_not_a_deletion () =
  with_workspace
  @@ fun config ->
  write_backlog config [];
  write_links config [ "goal-1", [ "task-7" ] ];
  write_file (Workspace_goal_index.goal_task_links_path config) "not json";
  error_names "links" ~needle:"links" (lookups config [ "task-7" ])
;;

(* {1 Stores that do not read} *)

let test_a_backlog_that_does_not_read_is_an_error () =
  with_workspace
  @@ fun config ->
  write_backlog config [ make_task ~id:"task-1" (done_by ()) ];
  write_file (Workspace_backlog.backlog_path config) "not json";
  error_names "backlog" ~needle:"backlog" (lookups config [ "task-1" ])
;;

let test_an_archive_that_is_not_the_collectors_document_is_an_error () =
  with_workspace
  @@ fun config ->
  write_backlog config [];
  let archive_path = Workspace_utils_paths_backend.archive_path config in
  write_file archive_path "not json";
  error_names "not JSON" ~needle:"tasks-archive.json" (lookups config [ "task-1" ]);
  write_file archive_path {|{"last_updated":"x"}|};
  error_names "no tasks list" ~needle:"tasks-archive.json" (lookups config [ "task-1" ]);
  write_file archive_path {|{"tasks":[{"id":"task-1"}]}|};
  error_names "the wanted row does not decode" ~needle:"task-1" (lookups config [ "task-1" ]);
  write_file archive_path {|{"tasks":[{"title":"no id"}]}|};
  error_names "a row with no id" ~needle:"no readable id" (lookups config [ "task-1" ]);
  write_file archive_path {|{"tasks":[]}|};
  match lookup_of "task-1" (lookups config [ "task-1" ]) with
  | Candle_event.Deleted -> ()
  | Candle_event.Found _ -> fail "an empty archive found a Task"
;;

(* The archive grows for as long as the server runs. A row this build cannot
   decode stops only the payouts that ask for it. *)
let test_a_row_nobody_asked_for_is_not_decoded () =
  with_workspace
  @@ fun config ->
  write_backlog config [];
  let archive_path = Workspace_utils_paths_backend.archive_path config in
  write_archive config [ make_task ~id:"task-9" ~title:"Old" (done_by ()) ];
  let text = In_channel.with_open_bin archive_path In_channel.input_all in
  let damaged =
    match String.index_opt text '[' with
    | Some open_bracket ->
      String.sub text 0 (open_bracket + 1)
      ^ {|{"id":"task-2"},|}
      ^ String.sub text (open_bracket + 1) (String.length text - open_bracket - 1)
    | None -> fail "the archive has no list"
  in
  write_file archive_path damaged;
  (match lookup_of "task-9" (lookups config [ "task-9" ]) with
   | Candle_event.Found { title; _ } -> check string "the wanted row reads" "Old" title
   | Candle_event.Deleted -> fail "task-9 was not found");
  error_names "the damaged row is the wanted one" ~needle:"task-2" (lookups config [ "task-2" ])
;;

(* Nothing to look up reads nothing, and a Task the backlog has does not need the
   archive or the links. *)
let test_only_a_missing_task_sends_the_read_to_the_archive () =
  with_workspace
  @@ fun config ->
  write_backlog config [ make_task ~id:"task-1" (done_by ()) ];
  write_file (Workspace_utils_paths_backend.archive_path config) "not json";
  write_file (Workspace_goal_index.goal_task_links_path config) "not json";
  (match lookups config [] with
   | Ok [] -> ()
   | Ok _ -> fail "no ids gave an answer"
   | Error detail -> failf "%s" detail);
  (match lookup_of "task-1" (lookups config [ "task-1" ]) with
   | Candle_event.Found _ -> ()
   | Candle_event.Deleted -> fail "task-1 was not found");
  error_names "a Task the backlog lacks" ~needle:"tasks-archive.json" (lookups config [ "task-1"; "task-2" ])
;;

let test_a_completion_time_the_ledger_cannot_hold_is_an_error () =
  with_workspace
  @@ fun config ->
  write_backlog config [ make_task ~id:"task-1" (done_by ~completed_at:"yesterday" ()) ];
  error_names "completed_at" ~needle:"task-1" (lookups config [ "task-1" ])
;;

let test_a_blank_assignee_is_unreadable () =
  with_workspace
  @@ fun config ->
  write_backlog config [ make_task ~id:"task-1" (done_by ~assignee:"  " ()) ];
  error_names "blank performer" ~needle:"assignee" (lookups config [ "task-1" ])
;;

(* {1 Keepers} *)

(* The test writes into this directory, so it stops if the resolver points
   anywhere but the temporary workspace. *)
let keepers_dir (config : Workspace.config) =
  let directory = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path in
  if not (String.starts_with ~prefix:config.base_path directory)
  then failf "the keepers directory %s is outside the test workspace" directory;
  directory
;;

let test_a_name_is_a_keeper_when_its_config_file_is_there () =
  with_workspace
  @@ fun config ->
  write_file (Filename.concat (keepers_dir config) "keeper-a.toml") "";
  match Candle_tasks.is_keeper config with
  | Error detail -> failf "%s" detail
  | Ok is_keeper ->
    check bool "keeper-a" true (is_keeper "keeper-a");
    check bool "no file" false (is_keeper "keeper-b");
    check bool "not a name" false (is_keeper "../keeper-a");
    check bool "empty" false (is_keeper "");
    check bool "the file's own name" false (is_keeper "keeper-a.toml")
;;

(* A workspace that was never initialised has no keepers directory. *)
let test_a_keepers_directory_that_does_not_list_is_an_error () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       check bool "precondition: no keepers directory" false (Sys.file_exists (keepers_dir config));
       error_names "missing directory" ~needle:"keepers directory" (Candle_tasks.is_keeper config))
;;

let () =
  run
    "candle_tasks"
    [ ( "lookups"
      , [ test_case
            "a task in the backlog is found with what its status says"
            `Quick
            test_a_task_in_the_backlog_is_found_with_what_its_status_says
        ; test_case "a task only the archive has is found" `Quick test_a_task_only_the_archive_has_is_found
        ; test_case "the backlog wins over the archive" `Quick test_the_backlog_wins_over_the_archive
        ; test_case "the order asked is the order answered" `Quick test_the_order_asked_is_the_order_answered
        ; test_case
            "a task neither store has is deleted when the goal no longer links it"
            `Quick
            test_a_task_neither_store_has_is_deleted_when_the_goal_no_longer_links_it
        ; test_case
            "links that do not read are an error, not a deletion"
            `Quick
            test_links_that_do_not_read_are_an_error_not_a_deletion
        ; test_case
            "only a missing task sends the read to the archive"
            `Quick
            test_only_a_missing_task_sends_the_read_to_the_archive
        ; test_case "a blank assignee is unreadable" `Quick test_a_blank_assignee_is_unreadable
        ] )
    ; ( "stores that do not read"
      , [ test_case "a backlog that does not read is an error" `Quick test_a_backlog_that_does_not_read_is_an_error
        ; test_case
            "an archive that is not the collector's document is an error"
            `Quick
            test_an_archive_that_is_not_the_collectors_document_is_an_error
        ; test_case
            "a row nobody asked for is not decoded"
            `Quick
            test_a_row_nobody_asked_for_is_not_decoded
        ; test_case
            "a completion time the ledger cannot hold is an error"
            `Quick
            test_a_completion_time_the_ledger_cannot_hold_is_an_error
        ] )
    ; ( "keepers"
      , [ test_case
            "a name is a keeper when its config file is there"
            `Quick
            test_a_name_is_a_keeper_when_its_config_file_is_there
        ; test_case
            "a keepers directory that does not list is an error"
            `Quick
            test_a_keepers_directory_that_does_not_list_is_an_error
        ] )
    ]
;;
