(** test_verification_fsm -- FSM transition tests for AwaitingVerification state.

    Tests Phase B+C transitions with MASC_VERIFICATION_FSM_ENABLED=true:
    - InProgress -> AwaitingVerification (submit_for_verification)
    - AwaitingVerification -> Done (cross-agent approve)
    - AwaitingVerification -> InProgress (cross-agent reject)
    - Self-approval/rejection blocked
    - FSM disabled path: error message *)

open Masc_mcp

let with_temp_config ~fsm_enabled f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Unix.putenv "MASC_VERIFICATION_FSM_ENABLED" (if fsm_enabled then "true" else "false");
  let dir = Filename.temp_file "verification_fsm_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let config = Coord.default_config dir in
  ignore (Coord.init config ~agent_name:(Some "worker"));
  Task_dispatch.reset_for_test ();
  Task_dispatch.init_jsonl ();
  Fun.protect ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm (Filename.concat path name));
            Unix.rmdir path)
          else
            Unix.unlink path
      in
      rm dir) (fun () -> f config)

(* Add a task with strict contract requiring verification *)
let add_strict_task config =
  let contract : Types.task_contract = {
    strict = true;
    completion_contract = ["tests pass"];
    required_evidence = [];
    inspect_gate_evidence = [];
    verify_gate_evidence = ["output.json"];
    links = { operation_id = None; session_id = None; autoresearch_loop_id = None };
  } in
  let _msg = Coord.add_task ~contract config ~title:"strict task"
    ~priority:3 ~description:"needs verification" in
  let backlog = Coord.read_backlog config in
  match List.nth_opt backlog.tasks 0 with
  | None -> Alcotest.fail "no task added"
  | Some t -> t.id

let claim_and_start config agent_name task_id =
  let _ = Coord.transition_task_r config ~agent_name ~task_id
    ~action:Types.Claim () in
  let _ = Coord.transition_task_r config ~agent_name ~task_id
    ~action:Types.Start () in
  ()

let get_task config task_id =
  let backlog = Coord.read_backlog config in
  List.find_opt (fun (t : Types.task) -> t.id = task_id) backlog.tasks

let status_string config task_id =
  match get_task config task_id with
  | None -> "not_found"
  | Some t -> Types.string_of_task_status t.task_status

(* ================================================================ *)
(* FSM transitions (enabled)                                         *)
(* ================================================================ *)

let test_submit_for_verification_moves_to_awaiting () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    match Coord.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Types.Submit_for_verification () with
    | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "awaiting_verification"
        (status_string config task_id))

let test_approve_by_other_agent_moves_to_done () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let _ = Coord.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Types.Submit_for_verification () in
    match Coord.transition_task_r config ~agent_name:"verifier"
            ~task_id ~action:Types.Approve_verification () with
    | Error e -> Alcotest.fail ("approve failed: " ^ Types.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "done"
        (status_string config task_id))

let test_reject_by_other_agent_moves_to_in_progress () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let _ = Coord.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Types.Submit_for_verification () in
    match Coord.transition_task_r config ~agent_name:"verifier"
            ~task_id ~action:Types.Reject_verification ~reason:"test reject" () with
    | Error e -> Alcotest.fail ("reject failed: " ^ Types.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "in_progress"
        (status_string config task_id))

let test_self_approval_blocked () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let _ = Coord.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Types.Submit_for_verification () in
    match Coord.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Types.Approve_verification () with
    | Ok _ -> Alcotest.fail "self-approval should be blocked"
    | Error e ->
      let msg = Types.show_masc_error e in
      Alcotest.(check bool) "error mentions self-approval" true
        (Astring.String.is_infix ~affix:"Self-approval" msg))

let test_self_rejection_blocked () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let _ = Coord.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Types.Submit_for_verification () in
    match Coord.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Types.Reject_verification () with
    | Ok _ -> Alcotest.fail "self-rejection should be blocked"
    | Error _ -> ())

(* ================================================================ *)
(* Verification.ml state sync (P0 #7544)                             *)
(* ================================================================ *)

(* Directly exercises Verification.submit_verdict — the state-sync primitive
   that verification_protocol.on_approve/reject calls internally.
   Full protocol (board + SSE) is tested e2e. *)
let test_submit_verdict_pass () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let base_path = config.Coord.base_path in
    let req = match Verification.create_request
      ~base_path ~task_id:"task-x" ~output:(`Assoc [])
      ~criteria:[Verification.Custom "tests pass"] ~worker:"worker" () with
      | Ok r -> r
      | Error e -> Alcotest.fail e
    in
    Alcotest.(check bool) "initial pending" true
      (match req.status with Pending -> true | _ -> false);
    let _ = match Verification.submit_verdict ~base_path
      ~req_id:req.id ~verifier:"verifier-agent"
      ~verdict:Verification.Pass with
      | Ok _ -> ()
      | Error e -> Alcotest.fail ("submit_verdict failed: " ^ e)
    in
    match Verification.load_request base_path req.id with
    | Error e -> Alcotest.fail ("load_request failed: " ^ e)
    | Ok updated ->
      Alcotest.(check bool) "completed pass" true
        (match updated.status with Completed Pass -> true | _ -> false))

let test_submit_verdict_fail () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let base_path = config.Coord.base_path in
    let req = match Verification.create_request
      ~base_path ~task_id:"task-y" ~output:(`Assoc [])
      ~criteria:[Verification.Custom "tests pass"] ~worker:"worker" () with
      | Ok r -> r
      | Error e -> Alcotest.fail e
    in
    let _ = match Verification.submit_verdict ~base_path
      ~req_id:req.id ~verifier:"verifier-agent"
      ~verdict:(Verification.Fail "missing evidence") with
      | Ok _ -> ()
      | Error e -> Alcotest.fail ("submit_verdict failed: " ^ e)
    in
    match Verification.load_request base_path req.id with
    | Error e -> Alcotest.fail ("load_request failed: " ^ e)
    | Ok updated ->
      Alcotest.(check bool) "completed fail" true
        (match updated.status with
         | Completed (Fail r) ->
           Astring.String.is_infix ~affix:"missing evidence" r
         | _ -> false))

(* ================================================================ *)
(* FSM disabled                                                      *)
(* ================================================================ *)

let test_fsm_disabled_submit_fails () =
  with_temp_config ~fsm_enabled:false (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    match Coord.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Types.Submit_for_verification () with
    | Ok _ -> Alcotest.fail "submit should fail when FSM disabled"
    | Error e ->
      let msg = Types.show_masc_error e in
      Alcotest.(check bool) "error mentions FSM disabled" true
        (Astring.String.is_infix ~affix:"not enabled" msg))

(* ================================================================ *)
(* Test suite                                                        *)
(* ================================================================ *)

let () =
  Alcotest.run "verification_fsm" [
    ("transitions_enabled", [
      Alcotest.test_case "submit moves to awaiting_verification" `Quick
        test_submit_for_verification_moves_to_awaiting;
      Alcotest.test_case "cross-agent approve moves to done" `Quick
        test_approve_by_other_agent_moves_to_done;
      Alcotest.test_case "cross-agent reject moves to in_progress" `Quick
        test_reject_by_other_agent_moves_to_in_progress;
      Alcotest.test_case "self-approval blocked" `Quick
        test_self_approval_blocked;
      Alcotest.test_case "self-rejection blocked" `Quick
        test_self_rejection_blocked;
    ]);
    ("fsm_disabled", [
      Alcotest.test_case "submit fails when FSM disabled" `Quick
        test_fsm_disabled_submit_fails;
    ]);
    ("verification_state_sync", [
      Alcotest.test_case "submit_verdict Pass updates state" `Quick
        test_submit_verdict_pass;
      Alcotest.test_case "submit_verdict Fail preserves reason" `Quick
        test_submit_verdict_fail;
    ]);
  ]
