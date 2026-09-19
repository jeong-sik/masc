(** The list of tasks whose only exit belongs to the operator.

    Every row here is a task that cannot move on its own: a stop only an
    operator may grant, or work held by a name that will never act again. The
    fixtures build those states the way production reaches them — the cancel
    claim goes through the real transition so the record it writes is the one
    the list reads back. *)
module D = Masc_domain
module W = Workspace_core
module Attention = Masc.Operator_task_attention
module Store = Workspace_verification_store

let () = Mirage_crypto_rng_unix.use_default ()

let ok = function Ok value -> value | Error detail -> Alcotest.fail detail

let workspace_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.masc_error_to_string error)

let live_keeper = "edgar.a.poe"
let vanished = "codex-mcp-client"
let undecodable = "half-written-keeper"
let stop_reason = "the issue this task answers was closed upstream on 2026-07-27"

let with_workspace f =
  (* The verification-request adapter is part of the contract: the cancel
     claim's record is written by the installed runtime hook, not by the
     test. *)
  Masc.Workspace_metric_hooks.install ();
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let base_path = Filename.temp_dir "masc-operator-attention-" "" in
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.on_release sw (fun () ->
        Fs_compat.clear_fs ();
        Masc_test_deps.cleanup_test_workspace base_path);
      let config = W.default_config base_path in
      ignore (W.init config ~agent_name:(Some live_keeper));
      f config))

let persist_keeper config name =
  let meta =
    ok (Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]))
  in
  ok
    (Masc.Keeper_fs.save_json_atomic
       (Masc.Keeper_types_profile.keeper_meta_path config name)
       (Masc.Keeper_meta_json.meta_to_json meta))

let add_task config ~title =
  ignore (W.add_task config ~title ~priority:1 ~description:title)

let set_status config ~task_id ~status =
  let backlog = ok (Workspace_backlog.read_backlog_r config) in
  let tasks =
    List.map
      (fun (task : D.task) ->
         if String.equal task.id task_id then { task with task_status = status } else task)
      backlog.tasks
  in
  W.write_backlog config { backlog with tasks }

let in_progress ~assignee ~started_at = D.InProgress { assignee; started_at }

let project config =
  Attention.project ~config (ok (Workspace_backlog.read_backlog_r config)).tasks

(* A cancel by the holder ends the Task where it is asked, so nothing lands in
   the operator's list. The row this replaces existed because a stop waited for
   an operator's answer; nothing waits now. *)
let test_a_cancel_leaves_no_operator_row () =
  with_workspace (fun config ->
    add_task config ~title:"a task its holder gives up on";
    ignore
      (workspace_ok
         (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
            ~action:D.Claim ()));
    ignore
      (workspace_ok
         (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
            ~action:D.Start ()));
    ignore
      (workspace_ok
         (W.transition_task_r config ~agent_name:live_keeper ~task_id:"task-001"
            ~action:D.Cancel ~reason:stop_reason ()));
    match project config with
    | [] -> ()
    | items ->
      Alcotest.failf "a stop asks nobody, got %d operator rows" (List.length items))

(* A completion waits on the system authority, which is running. Only a stop
   waits on a person. *)
let test_a_completion_is_not_the_operators_row () =
  with_workspace (fun config ->
    persist_keeper config live_keeper;
    add_task config ~title:"work submitted as finished";
    set_status config ~task_id:"task-001"
      ~status:
        (D.AwaitingVerification
           { assignee = live_keeper
           ; started_at = "2026-09-01T00:00:00Z"
           ; submitted_at = "2026-09-02T00:00:00Z"
           ; verification_id = "vrf-completion"
           });
    Alcotest.(check int) "a completion is nobody's operator row" 0
      (List.length (project config)))

(* The route is the same one the rejection delivery computes: a name with a
   live registry entry or a Keeper meta file can still act, and a name with
   neither cannot. *)
let test_only_work_with_no_actor_is_listed () =
  with_workspace (fun config ->
    persist_keeper config live_keeper;
    add_task config ~title:"held by a Keeper that is still there";
    add_task config ~title:"held by a session that is gone";
    set_status config ~task_id:"task-001"
      ~status:(in_progress ~assignee:live_keeper ~started_at:"2026-09-03T00:00:00Z");
    set_status config ~task_id:"task-002"
      ~status:(in_progress ~assignee:vanished ~started_at:"2026-09-04T00:00:00Z");
    match project config with
    | [ Attention.Held_without_actor { task_id; assignee; since } ] ->
      Alcotest.(check string) "the abandoned task is the row" "task-002" task_id;
      Alcotest.(check string) "named by who holds it" vanished assignee;
      Alcotest.(check string) "waiting since it started" "2026-09-04T00:00:00Z" since
    | items ->
      Alcotest.failf "a live Keeper's task is not an operator row (got %d rows)"
        (List.length items))

(* A file at the meta path this binary cannot decode is a Keeper whose record
   needs repair, not a Keeper that is gone. Folding the two together would put
   a task up for recovery whose owner is still running. *)
let test_an_undecodable_keeper_record_is_its_own_row () =
  with_workspace (fun config ->
    let meta_path = Masc.Keeper_types_profile.keeper_meta_path config undecodable in
    Fs_compat.mkdir_p (Filename.dirname meta_path);
    Out_channel.with_open_text meta_path (fun out -> output_string out "[]");
    add_task config ~title:"held by a Keeper whose record does not decode";
    set_status config ~task_id:"task-001"
      ~status:(in_progress ~assignee:undecodable ~started_at:"2026-09-05T00:00:00Z");
    match project config with
    | [ Attention.Producer_record_unreadable { producer; detail; _ } ] ->
      Alcotest.(check string) "named by whose record it is" undecodable producer;
      Alcotest.(check bool) "and says what could not be read" true
        (String.length detail > 0)
    | items ->
      Alcotest.failf "an undecodable record is its own row, got %d" (List.length items))

(* The longest wait is the row that has gone unanswered the longest, and a
   surface that draws a few draws those. *)
let test_rows_are_oldest_first () =
  with_workspace (fun config ->
    add_task config ~title:"abandoned later";
    add_task config ~title:"abandoned first";
    set_status config ~task_id:"task-001"
      ~status:(in_progress ~assignee:vanished ~started_at:"2026-09-10T00:00:00Z");
    set_status config ~task_id:"task-002"
      ~status:(in_progress ~assignee:vanished ~started_at:"2026-09-02T00:00:00Z");
    Alcotest.(check (list string)) "oldest wait first"
      [ "task-002"; "task-001" ]
      (List.map Attention.task_id (project config)))

let test_terminal_and_unclaimed_tasks_are_not_rows () =
  with_workspace (fun config ->
    add_task config ~title:"nobody has claimed this";
    add_task config ~title:"finished";
    add_task config ~title:"stopped";
    set_status config ~task_id:"task-002"
      ~status:
        (D.Done
           { assignee = vanished; completed_at = "2026-09-06T00:00:00Z"; notes = None });
    set_status config ~task_id:"task-003"
      ~status:
        (D.Cancelled
           { cancelled_by = vanished
           ; cancelled_at = "2026-09-06T00:00:00Z"
           ; reason = None
           });
    Alcotest.(check int) "todo and terminal tasks wait on nobody" 0
      (List.length (project config)))

let () =
  Alcotest.run "operator_task_attention"
    [ ( "tasks only an operator can move"
      , [ Alcotest.test_case "a cancel claim carries its reason" `Quick
            test_a_cancel_leaves_no_operator_row
        ; Alcotest.test_case "a completion is not an operator row" `Quick
            test_a_completion_is_not_the_operators_row
        ; Alcotest.test_case "only work with no actor is listed" `Quick
            test_only_work_with_no_actor_is_listed
        ; Alcotest.test_case "an undecodable keeper record is its own row" `Quick
            test_an_undecodable_keeper_record_is_its_own_row
        ; Alcotest.test_case "rows are oldest first" `Quick test_rows_are_oldest_first
        ; Alcotest.test_case "terminal and unclaimed tasks are not rows" `Quick
            test_terminal_and_unclaimed_tasks_are_not_rows
        ] )
    ]
