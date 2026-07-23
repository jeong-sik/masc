(** #10247 root cause: [masc_goal_upsert] used to let callers write
    lifecycle fields directly into the Goal Store.  Goal lifecycle
    moves must go through the FSM tool so transition audit bookkeeping
    cannot be bypassed. *)

open Alcotest
open Masc
open Workspace_types

let temp_dir () =
  let path = Filename.temp_file "goal_fsm_bypass_10247_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
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

let workspace_ctx ?(agent_name = "planner") config : Tool_workspace.context =
  { Tool_workspace.config; agent_name }
;;

let dispatch_upsert ctx args =
  match Tool_workspace.dispatch ctx ~name:"masc_goal_upsert" ~args:(`Assoc args) with
  | Some result -> result
  | None -> fail "masc_goal_upsert not handled"
;;

let dispatch_upsert_must_fail ctx args =
  let result = dispatch_upsert ctx args in
  if (Tool_result.is_success result)
  then
    fail
      (Printf.sprintf
         "expected upsert rejection, got success: %s"
         ((Tool_result.message result)))
  else Yojson.Safe.from_string ((Tool_result.message result))
;;

let dispatch_upsert_must_succeed ctx args =
  let result = dispatch_upsert ctx args in
  if (Tool_result.is_success result)
  then Yojson.Safe.from_string ((Tool_result.message result))
  else
    fail
      (Printf.sprintf
         "expected upsert success, got error: %s"
         ((Tool_result.message result)))
;;

let body_contains json needle =
  let raw = Yojson.Safe.to_string json in
  let len = String.length raw
  and nlen = String.length needle in
  let rec loop i =
    if nlen = 0
    then true
    else if i + nlen > len
    then false
    else if String.sub raw i nlen = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let string_field json field =
  match Yojson.Safe.Util.member field json with
  | `String value -> value
  | other ->
    fail
      (Printf.sprintf
         "expected string field %s, got %s"
         field
         (Yojson.Safe.to_string other))
;;

let create_goal_id config ~title =
  let body = dispatch_upsert_must_succeed (workspace_ctx config) [ "title", `String title ] in
  string_field body "goal_id"
;;

let dispatch_transition_must_succeed (ctx : Tool_workspace.context) ~goal_id ~action =
  match
    Tool_workspace.dispatch
      ctx
      ~name:"masc_goal_transition"
      ~args:
        (`Assoc
            [ "goal_id", `String goal_id
            ; "action", `String action
            ])
  with
  | Some result when (Tool_result.is_success result) -> ()
  | Some result ->
    fail
      (Printf.sprintf
         "expected transition %s success, got error: %s"
         action
         ((Tool_result.message result)))
  | None -> fail "masc_goal_transition not handled"
;;

let saved_phase config goal_id =
  match Goal_store.get_goal config ~goal_id with
  | Some goal -> Goal_phase.to_string goal.phase
  | None -> fail "goal missing"
;;

let check_lifecycle_error ~field body =
  check
    bool
    (field ^ " error cites lifecycle field")
    true
    (body_contains body ("lifecycle field " ^ field));
  check
    bool
    (field ^ " error points at FSM tools")
    true
    (body_contains body "masc_goal_transition")
;;

let test_any_phase_field_rejected () =
  with_workspace
  @@ fun config ->
  [ "executing"
  ; "completed"
  ; "dropped"
  ; "blocked"
  ; "paused"
  ]
  |> List.iter (fun phase ->
    let body =
      dispatch_upsert_must_fail
        (workspace_ctx config)
        [ "title", `String ("Bypass " ^ phase); "phase", `String phase ]
    in
    check_lifecycle_error ~field:"phase" body)
;;

let test_any_status_field_rejected () =
  with_workspace
  @@ fun config ->
  [ "active"; "done"; "dropped"; "paused" ]
  |> List.iter (fun status ->
    let body =
      dispatch_upsert_must_fail
        (workspace_ctx config)
        [ "title", `String ("Bypass status " ^ status); "status", `String status ]
    in
    check_lifecycle_error ~field:"status" body)
;;

let test_no_lifecycle_field_still_round_trips () =
  with_workspace
  @@ fun config ->
  let body =
    dispatch_upsert_must_succeed
      (workspace_ctx config)
      [ "title", `String "Default goal"; "priority", `Int 2 ]
  in
  check
    bool
    "default upsert produces goal_id"
    true
    (match Yojson.Safe.Util.member "goal_id" body with
     | `String id -> id <> ""
     | _ -> false)
;;

let test_existing_blocked_cannot_resume_with_executing_phase () =
  with_workspace
  @@ fun config ->
  let goal_id = create_goal_id config ~title:"Blocked goal" in
  dispatch_transition_must_succeed (workspace_ctx config) ~goal_id ~action:"block";
  check string "fixture moved to blocked" "blocked" (saved_phase config goal_id);
  let body =
    dispatch_upsert_must_fail
      (workspace_ctx config)
      [ "id", `String goal_id; "phase", `String "executing" ]
  in
  check_lifecycle_error ~field:"phase" body;
  check string "blocked goal remains blocked" "blocked" (saved_phase config goal_id)
;;

let test_existing_paused_cannot_resume_with_active_status () =
  with_workspace
  @@ fun config ->
  let goal_id = create_goal_id config ~title:"Paused goal" in
  dispatch_transition_must_succeed (workspace_ctx config) ~goal_id ~action:"pause";
  check string "fixture moved to paused" "paused" (saved_phase config goal_id);
  let body =
    dispatch_upsert_must_fail
      (workspace_ctx config)
      [ "id", `String goal_id; "status", `String "active" ]
  in
  check_lifecycle_error ~field:"status" body;
  check string "paused goal remains paused" "paused" (saved_phase config goal_id)
;;

let test_phase_violation_beats_status () =
  with_workspace
  @@ fun config ->
  let body =
    dispatch_upsert_must_fail
      (workspace_ctx config)
      [ "title", `String "Both fields violate"
      ; "phase", `String "completed"
      ; "status", `String "done"
      ]
  in
  check_lifecycle_error ~field:"phase" body
;;

let () =
  run
    "goal_upsert_fsm_bypass_10247"
    [ ( "phase-rejection"
      , [ test_case "any phase field is blocked" `Quick test_any_phase_field_rejected ] )
    ; ( "status-rejection"
      , [ test_case "any status field is blocked" `Quick test_any_status_field_rejected ]
      )
    ; ( "happy-path"
      , [ test_case
            "no lifecycle field round trips"
            `Quick
            test_no_lifecycle_field_still_round_trips
        ] )
    ; ( "existing-goal-regression"
      , [ test_case
            "blocked goal cannot resume via phase=executing"
            `Quick
            test_existing_blocked_cannot_resume_with_executing_phase
        ; test_case
            "paused goal cannot resume via status=active"
            `Quick
            test_existing_paused_cannot_resume_with_active_status
        ] )
    ; ( "ordering"
      , [ test_case
            "phase violation beats status"
            `Quick
            test_phase_violation_beats_status
        ] )
    ]
;;
