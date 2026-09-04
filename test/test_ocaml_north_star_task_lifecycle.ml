module Types = Masc_domain

(** Behavior-locking tests for the current task lifecycle.

    These tests document existing semantics before any north-star refactor.
    They intentionally do not introduce a new FSM or change transition policy. *)

open Alcotest
open Masc

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
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "worker"));
       f config)
;;

let add_task config =
  ignore
    (Workspace.add_task
       config
       ~title:"north-star task"
       ~priority:3
       ~description:"behavior lock");
  match (Workspace.read_backlog config).tasks with
  | task :: _ -> task.id
  | [] -> fail "fixture task not created"
;;

let task config task_id =
  match
    List.find_opt
      (fun (task : Masc_domain.task) -> String.equal task.id task_id)
      (Workspace.read_backlog config).tasks
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

let verification_id_for_task config task_id =
  match
    Workspace.get_tasks_raw config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  with
  | Some { task_status = Masc_domain.AwaitingVerification { verification_id; _ }; _ }
    ->
    verification_id
  | Some _ -> failf "task %s is not awaiting verification" task_id
  | None -> failf "task %s not found" task_id
;;

(* [Done_action] on a claimed or started task is answered with
   [Verification_submission_required]: the producer submits, and a completion
   authority commits the verdict. The peer-keeper claim that used to sit
   between them is gone -- the authority is not a keeper -- but the submission
   and the verdict both remain, so a test that wants a completed task has to
   walk that path rather than name its destination. *)
let transition config ~agent_name ~task_id ~action ?(notes = "") ?(reason = "") () =
  let submit_then_approve () =
    match
      Workspace.transition_task_r config ~agent_name ~task_id
        ~action:Masc_domain.Submit_for_verification
          (* Submission persists a verification record before it moves the
             status, and refuses to move it when that storage is absent. This
             suite has no verification store, so it stands in for one. *)
        ~prepare_verification_request:
          (fun ~task:_ ~assignee:_ ~verification_id:_ ~claim:_ -> Ok ())
        ~notes ()
    with
    | Error _ as error -> error
    | Ok _ ->
      Workspace.commit_verdict_r config
        ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
        ~verdict:Masc_domain.Verdict_approved ~task_id
        ~verification_id:(verification_id_for_task config task_id)
        ~notes:("verified: " ^ notes) ()
      |> Result.map (fun (o : Workspace.transition_outcome) -> o.Workspace.message)
  in
  match action with
  | Masc_domain.Done_action ->
    (match (task config task_id).task_status with
     | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> submit_then_approve ()
     | Masc_domain.Todo | Masc_domain.AwaitingVerification _ | Masc_domain.Done _
     | Masc_domain.Cancelled _ ->
       Workspace.transition_task_r config ~agent_name ~task_id ~action ~notes ~reason
         ())
  | Masc_domain.Claim | Masc_domain.Start | Masc_domain.Release
  | Masc_domain.Submit_for_verification | Masc_domain.Cancel ->
    Workspace.transition_task_r config ~agent_name ~task_id ~action ~notes ~reason ()
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
      check bool "notes preserve evidence" true
        (Option.fold ~none:false
           ~some:(Astring.String.is_infix ~affix:"verified: tests pass")
           notes)
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
      (* The rejection names what to do instead. It used to spell that as
         "action=claim"; it now lists every action the status admits. *)
      "remediation names claim"
      true
      (Astring.String.is_infix ~affix:"valid_next_actions=[claim" msg);
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
      (* Cancelled admits nothing, so the rejection carries no
         valid_next_actions clause; naming the status it refused from is what
         tells the caller the task is over. *)
      "terminal rejection names the cancelled status"
      true
      (Astring.String.is_infix ~affix:"cancelled -> claim" msg))
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
    let before_version = (Workspace.read_backlog config).version in
    ignore
      (transition
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Done_action
         ~notes:"second"
         ()
       |> expect_ok "done idempotent");
    let after_backlog = Workspace.read_backlog config in
    check
      int
      "idempotent done does not rewrite backlog"
      before_version
      after_backlog.version;
    match (task config task_id).task_status with
    | Masc_domain.Done { notes; _ } ->
      check bool "original notes" true
        (Option.fold ~none:false
           ~some:(Astring.String.is_infix ~affix:"verified: first")
           notes)
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
