(** Behavior-locking tests for the current task lifecycle.

    These tests document existing semantics before any north-star refactor.
    They intentionally do not introduce a new FSM or change transition policy. *)

open Alcotest
open Masc_mcp

let counter = ref 0

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-ocaml-north-star-%d-%d"
         (int_of_float (Unix.gettimeofday () *. 1000.0))
         !counter)
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Coord.default_config dir in
       ignore (Coord.init config ~agent_name:(Some "worker"));
       f config)
;;

let add_task config =
  ignore
    (Coord.add_task
       config
       ~title:"north-star task"
       ~priority:3
       ~description:"behavior lock");
  match (Coord.read_backlog config).tasks with
  | task :: _ -> task.id
  | [] -> fail "fixture task not created"
;;

let task config task_id =
  match
    List.find_opt
      (fun (task : Masc_domain.task) -> String.equal task.id task_id)
      (Coord.read_backlog config).tasks
  with
  | Some task -> task
  | None -> fail ("task not found: " ^ task_id)
;;

let status_name config task_id =
  (task config task_id).task_status |> Masc_domain.task_status_to_string
;;

let expect_ok label = function
  | Ok value -> value
  | Error err -> fail (label ^ ": " ^ Masc_domain.masc_error_to_string err)
;;

let expect_invalid_transition label = function
  | Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState msg)) -> msg
  | Error err -> fail (label ^ ": unexpected error " ^ Masc_domain.masc_error_to_string err)
  | Ok msg -> fail (label ^ ": unexpectedly succeeded: " ^ msg)
;;

let transition config ~agent_name ~task_id ~action ?(notes = "") ?(reason = "") () =
  Coord.transition_task_r config ~agent_name ~task_id ~action ~notes ~reason ()
;;

let test_claim_start_done_path () =
  with_config (fun config ->
    let task_id = add_task config in
    check string "initial" "todo" (status_name config task_id);
    ignore
      (transition config ~agent_name:"worker" ~task_id ~action:Masc_domain.Claim ()
       |> expect_ok "claim");
    check string "after claim" "claimed" (status_name config task_id);
    ignore
      (transition config ~agent_name:"worker" ~task_id ~action:Masc_domain.Start ()
       |> expect_ok "start");
    check string "after start" "in_progress" (status_name config task_id);
    ignore
      (transition
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Done_action
         ~notes:"tests pass"
         ()
       |> expect_ok "done");
    check string "after done" "done" (status_name config task_id);
    match (task config task_id).task_status with
    | Masc_domain.Done { assignee; notes; _ } ->
      check string "assignee" "worker" assignee;
      check (option string) "notes" (Some "tests pass") notes
    | other -> fail ("expected done, got " ^ Masc_domain.task_status_to_string other))
;;

let test_done_from_todo_is_rejected () =
  with_config (fun config ->
    let task_id = add_task config in
    let msg =
      transition config ~agent_name:"worker" ~task_id ~action:Masc_domain.Done_action ()
      |> expect_invalid_transition "done from todo"
    in
    check
      bool
      "remediation mentions claim"
      true
      (Astring.String.is_infix ~affix:"action=claim" msg);
    check string "status preserved" "todo" (status_name config task_id))
;;

let test_release_from_claimed_returns_to_todo () =
  with_config (fun config ->
    let task_id = add_task config in
    ignore
      (transition config ~agent_name:"worker" ~task_id ~action:Masc_domain.Claim ()
       |> expect_ok "claim");
    ignore
      (transition config ~agent_name:"worker" ~task_id ~action:Masc_domain.Release ()
       |> expect_ok "release");
    check string "released" "todo" (status_name config task_id);
    check int "cycle count increments" 1 (task config task_id).cycle_count)
;;

let test_cancel_from_todo_is_terminal () =
  with_config (fun config ->
    let task_id = add_task config in
    ignore
      (transition
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Cancel
         ~reason:"not needed"
         ()
       |> expect_ok "cancel");
    check string "cancelled" "cancelled" (status_name config task_id);
    let msg =
      transition config ~agent_name:"worker" ~task_id ~action:Masc_domain.Claim ()
      |> expect_invalid_transition "claim cancelled"
    in
    check
      bool
      "terminal remediation"
      true
      (Astring.String.is_infix ~affix:"already cancelled" msg))
;;

let test_done_is_idempotent_terminal () =
  with_config (fun config ->
    let task_id = add_task config in
    ignore
      (transition config ~agent_name:"worker" ~task_id ~action:Masc_domain.Claim ()
       |> expect_ok "claim");
    ignore
      (transition
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Done_action
         ~notes:"first"
         ()
       |> expect_ok "done");
    let before_version = (Coord.read_backlog config).version in
    ignore
      (transition
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Done_action
         ~notes:"second"
         ()
       |> expect_ok "done idempotent");
    let after_backlog = Coord.read_backlog config in
    check
      int
      "idempotent done does not rewrite backlog"
      before_version
      after_backlog.version;
    match (task config task_id).task_status with
    | Masc_domain.Done { notes; _ } ->
      check (option string) "original notes" (Some "first") notes
    | other -> fail ("expected done, got " ^ Masc_domain.task_status_to_string other))
;;

let () =
  Alcotest.run
    "ocaml_north_star_task_lifecycle"
    [ ( "current semantics"
      , [ test_case "claim start done path" `Quick test_claim_start_done_path
        ; test_case "done from todo is rejected" `Quick test_done_from_todo_is_rejected
        ; test_case
            "release from claimed returns to todo"
            `Quick
            test_release_from_claimed_returns_to_todo
        ; test_case
            "cancel from todo is terminal"
            `Quick
            test_cancel_from_todo_is_terminal
        ; test_case "done is idempotent terminal" `Quick test_done_is_idempotent_terminal
        ] )
    ]
;;
