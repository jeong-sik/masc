module Types = Masc_domain

(** test_verification_fsm -- FSM transition tests for AwaitingVerification state.

    Tests Phase B+C transitions with MASC_VERIFICATION_FSM_ENABLED=true:
    - InProgress -> AwaitingVerification (submit_for_verification)
    - AwaitingVerification -> Done (cross-agent approve)
    - AwaitingVerification -> InProgress (cross-agent reject)
    - Self-approval/rejection blocked
    - FSM disabled path: error message *)

open Masc_mcp

let rng_initialized = ref false

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect f ~finally:(fun () ->
      match previous with
      | Some raw -> Unix.putenv key raw
      | None -> Unix.putenv key "")

let with_temp_config ~fsm_enabled f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* Initialize mirage-crypto-rng for verification_id generation.
     Production initializes this at server startup; tests must do it explicitly. *)
  if not !rng_initialized then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true
  end;
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
  let existing_ids =
    Coord.read_backlog config
    |> fun backlog -> List.map (fun (t : Types.task) -> t.id) backlog.tasks
  in
  let title = Printf.sprintf "strict task %d" (List.length existing_ids + 1) in
  let contract : Types.task_contract = {
    strict = true;
    completion_contract = ["tests pass"];
    required_tools = [];
    required_evidence = [];
    inspect_gate_evidence = [];
    verify_gate_evidence = ["output.json"];
    links = { operation_id = None; session_id = None; autoresearch_loop_id = None };
  } in
  let _msg = Coord.add_task ~contract config ~title
    ~priority:3 ~description:"needs verification" in
  let backlog = Coord.read_backlog config in
  match
    List.find_opt
      (fun (t : Types.task) -> not (List.mem t.id existing_ids))
      backlog.tasks
  with
  | Some t -> t.id
  | None -> Alcotest.fail "new task not found after add_task"

let claim_and_start config agent_name task_id =
  let _ = Coord.transition_task_r config ~agent_name ~task_id
    ~action:Types.Claim () in
  let _ = Coord.transition_task_r config ~agent_name ~task_id
    ~action:Types.Start () in
  ()

let create_pending_request config ~task_id ~worker ~request_id =
  match Verification.create_request ~base_path:config.Coord.base_path
          ~task_id ~output:`Null ~criteria:[] ~worker ~request_id () with
  | Ok req -> req
  | Error e -> Alcotest.fail ("create_request failed: " ^ e)

let submit_protocol_or_fail config task ~assignee ~verification_id ~evidence_refs =
  match
    Verification_protocol.on_submit_for_verification ~config ~task
      ~assignee ~verification_id ~evidence_refs
  with
  | Ok () -> ()
  | Error e -> Alcotest.fail ("on_submit_for_verification failed: " ^ e)

let get_task config task_id =
  let backlog = Coord.read_backlog config in
  List.find_opt (fun (t : Types.task) -> t.id = task_id) backlog.tasks

let status_string config task_id =
  match get_task config task_id with
  | None -> "not_found"
  | Some t -> Types.string_of_task_status t.task_status

let verification_id_of_task config task_id =
  match get_task config task_id with
  | None -> Alcotest.fail "task not found"
  | Some (t : Types.task) ->
    (match t.task_status with
     | Types.AwaitingVerification { verification_id; _ } -> verification_id
     | _ -> Alcotest.fail "task is not awaiting verification")

let expect_claim_next_claimed result ~task_id ~released_task_id =
  match result with
  | Coord.Claim_next_claimed
      { task_id = actual_task_id; released_task_id = actual_released; _ } ->
      Alcotest.(check string) "claimed task" task_id actual_task_id;
      Alcotest.(check (option string)) "released task" released_task_id
        actual_released
  | Coord.Claim_next_no_unclaimed ->
      Alcotest.fail "expected claim_next to claim a task, got no_unclaimed"
  | Coord.Claim_next_no_eligible _ ->
      Alcotest.fail "expected claim_next to claim a task, got no_eligible"
  | Coord.Claim_next_error message ->
      Alcotest.failf "expected claim_next to claim a task, got error: %s"
        message

let expect_claim_next_no_eligible result =
  match result with
  | Coord.Claim_next_no_eligible _ -> ()
  | Coord.Claim_next_no_unclaimed ->
      Alcotest.fail "expected claim_next to report no_eligible, got no_unclaimed"
  | Coord.Claim_next_claimed { task_id; _ } ->
      Alcotest.failf "expected claim_next to report no_eligible, got %s"
        task_id
  | Coord.Claim_next_error message ->
      Alcotest.failf "expected claim_next to report no_eligible, got error: %s"
        message

let expect_claim_next_no_unclaimed result =
  match result with
  | Coord.Claim_next_no_unclaimed -> ()
  | Coord.Claim_next_no_eligible _ ->
      Alcotest.fail "expected claim_next to report no_unclaimed, got no_eligible"
  | Coord.Claim_next_claimed { task_id; _ } ->
      Alcotest.failf "expected claim_next to report no_unclaimed, got %s"
        task_id
  | Coord.Claim_next_error message ->
      Alcotest.failf "expected claim_next to report no_unclaimed, got error: %s"
        message

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

let test_submit_for_verification_sets_timeout_deadline () =
  with_env "MASC_VERIFICATION_TIMEOUT_DEADLINE_SEC" "86400" @@ fun () ->
  with_temp_config ~fsm_enabled:true @@ fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    match Coord.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Types.Submit_for_verification () with
    | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e)
    | Ok _ ->
      match get_task config task_id with
      | Some { task_status =
                 Types.AwaitingVerification { submitted_at; deadline = Some deadline; _ };
               _ } ->
        let submitted_ts = Types.parse_iso8601 submitted_at in
        let deadline_ts = Types.parse_iso8601 deadline in
        Alcotest.(check (float 0.0)) "deadline offset"
          86400.0
          (deadline_ts -. submitted_ts)
      | Some { task_status = Types.AwaitingVerification { deadline = None; _ }; _ } ->
        Alcotest.fail "awaiting verification deadline missing"
      | Some _ -> Alcotest.fail "task is not awaiting verification"
      | None -> Alcotest.fail "task not found"

let test_submit_for_verification_from_claimed_moves_to_awaiting () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    ignore
      (Coord.transition_task_r config ~agent_name:"worker"
         ~task_id ~action:Types.Claim ());
    match Coord.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Types.Submit_for_verification () with
    | Error e -> Alcotest.fail ("submit from claimed failed: " ^ Types.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "awaiting_verification"
        (status_string config task_id))

let test_submit_prepare_failure_keeps_task_in_progress () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let prepare_called = ref false in
    let result =
      Coord.transition_task_r config ~agent_name:"worker"
        ~task_id ~action:Types.Submit_for_verification
        ~prepare_verification_request:
          (fun ~task:_ ~assignee:_ ~verification_id:_ ~evidence_refs:_ ->
             prepare_called := true;
             Error "simulated verification store failure")
        ()
    in
    match result with
    | Ok _ -> Alcotest.fail "submit should fail when verification request creation fails"
    | Error e ->
      Alcotest.(check bool) "prepare called" true !prepare_called;
      Alcotest.(check string) "status remains in_progress" "in_progress"
        (status_string config task_id);
      let msg = Types.show_masc_error e in
      Alcotest.(check bool) "error mentions verification request" true
        (Astring.String.is_infix
           ~affix:"verification request creation failed"
           msg);
      let reqs =
        Verification.list_requests config.Coord.base_path
        |> List.filter (fun (r : Verification.verification_request) ->
          r.task_id = task_id)
      in
      Alcotest.(check int) "no orphan request" 0 (List.length reqs))

(* Regression for the criteria ← completion_contract vs
   evidence_refs ← verify_gate_evidence split. Prior to the fix both
   sides pulled from verify_gate_evidence, so criteria ended up
   containing artefact paths instead of the contract text.

   Exercises Verification_protocol.on_submit_for_verification directly —
   Coord.transition_task_r only flips task.task_status; the protocol call
   that persists the verification record lives in tool_task.ml. *)
let test_submit_populates_criteria_from_completion_contract () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    let task =
      match get_task config task_id with
      | Some t -> t
      | None -> Alcotest.fail "fixture task not retrievable"
    in
    let evidence_refs = match task.contract with
      | Some c -> c.verify_gate_evidence
      | None -> []
    in
    submit_protocol_or_fail config task
      ~assignee:"verifier-agent" ~verification_id:"vrf-wiring"
      ~evidence_refs;
    let reqs = Verification.list_requests config.Coord.base_path in
    let req = List.find (fun (r : Verification.verification_request) ->
      r.task_id = task_id) reqs in
    let custom_texts = List.filter_map (function
      | Verification.Custom s -> Some s
      | _ -> None) req.criteria in
    (* add_strict_task fixture: completion_contract = ["tests pass"];
       verify_gate_evidence = ["output.json"]. *)
    Alcotest.(check (list string)) "criteria from completion_contract"
      ["tests pass"] custom_texts;
    let persisted_refs = match req.output with
      | `Assoc fields ->
          (match List.assoc_opt "evidence_refs" fields with
           | Some (`List xs) ->
               List.filter_map (function `String s -> Some s | _ -> None) xs
           | _ -> [])
      | _ -> []
    in
    Alcotest.(check (list string)) "evidence_refs from verify_gate_evidence"
      ["output.json"] persisted_refs)

let test_submit_marks_conflict_triage_when_deliverable_claims_completion () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    ignore
      (Planning_eio.set_deliverable config ~task_id
         ~content:"Task-001 completed. Exercised masc_observe_operations.");
    let task =
      match get_task config task_id with
      | Some t -> t
      | None -> Alcotest.fail "fixture task not retrievable"
    in
    let evidence_refs =
      match task.contract with
      | Some c -> c.verify_gate_evidence
      | None -> []
    in
    submit_protocol_or_fail config task
      ~assignee:"verifier-agent" ~verification_id:"vrf-conflict"
      ~evidence_refs;
    let reqs = Verification.list_requests config.Coord.base_path in
    let req =
      List.find
        (fun (r : Verification.verification_request) -> r.task_id = task_id)
        reqs
    in
    let output_fields =
      match req.output with
      | `Assoc fields -> fields
      | _ -> Alcotest.fail "expected output assoc"
    in
    let string_field key =
      match List.assoc_opt key output_fields with
      | Some (`String value) -> value
      | _ -> Alcotest.fail (Printf.sprintf "%s missing" key)
    in
    Alcotest.(check string) "request_kind" "conflict_triage"
      (string_field "request_kind");
    Alcotest.(check string) "request_summary"
      "Conflict verification required: board / planning / mutation path disagree."
      (string_field "request_summary");
    Alcotest.(check string) "next_action"
      "Reconcile board / planning / mutation surfaces before ordinary approval."
      (string_field "next_action"))

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

let test_approve_prepare_failure_keeps_task_awaiting () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match
       Coord.transition_task_r
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Types.Submit_for_verification
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e));
    let verification_id = verification_id_of_task config task_id in
    let req =
      create_pending_request
        config
        ~task_id
        ~worker:"worker"
        ~request_id:verification_id
    in
    let prepare_called = ref false in
    let result =
      Coord.transition_task_r
        config
        ~agent_name:"verifier"
        ~task_id
        ~action:Types.Approve_verification
        ~prepare_verification_verdict:
          (fun ~task:_ ~verifier:_ ~verification_id:_ ~decision:_ ->
             prepare_called := true;
             Error "simulated verdict store failure")
        ()
    in
    match result with
    | Ok _ -> Alcotest.fail "approve should fail when verdict persistence fails"
    | Error e ->
      Alcotest.(check bool) "prepare called" true !prepare_called;
      Alcotest.(check string) "status remains awaiting_verification"
        "awaiting_verification" (status_string config task_id);
      let msg = Types.show_masc_error e in
      Alcotest.(check bool) "error mentions verdict persistence" true
        (Astring.String.is_infix
           ~affix:"verification verdict persistence failed"
           msg);
      (match Verification.load_request config.Coord.base_path req.id with
       | Error err -> Alcotest.fail ("load_request failed: " ^ err)
       | Ok updated ->
         Alcotest.(check bool) "request remains pending" true
           (match updated.status with Pending -> true | _ -> false)))

let test_reject_prepare_failure_keeps_task_awaiting () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match
       Coord.transition_task_r
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Types.Submit_for_verification
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e));
    let verification_id = verification_id_of_task config task_id in
    let req =
      create_pending_request
        config
        ~task_id
        ~worker:"worker"
        ~request_id:verification_id
    in
    let prepare_called = ref false in
    let result =
      Coord.transition_task_r
        config
        ~agent_name:"verifier"
        ~task_id
        ~action:Types.Reject_verification
        ~reason:"missing evidence"
        ~prepare_verification_verdict:
          (fun ~task:_ ~verifier:_ ~verification_id:_ ~decision:_ ->
             prepare_called := true;
             Error "simulated verdict store failure")
        ()
    in
    match result with
    | Ok _ -> Alcotest.fail "reject should fail when verdict persistence fails"
    | Error e ->
      Alcotest.(check bool) "prepare called" true !prepare_called;
      Alcotest.(check string) "status remains awaiting_verification"
        "awaiting_verification" (status_string config task_id);
      let msg = Types.show_masc_error e in
      Alcotest.(check bool) "error mentions verdict persistence" true
        (Astring.String.is_infix
           ~affix:"verification verdict persistence failed"
           msg);
      (match Verification.load_request config.Coord.base_path req.id with
       | Error err -> Alcotest.fail ("load_request failed: " ^ err)
       | Ok updated ->
         Alcotest.(check bool) "request remains pending" true
           (match updated.status with Pending -> true | _ -> false)))

let test_claim_next_skips_pending_verification_tasks () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_1 = add_strict_task config in
    let task_2 = add_strict_task config in
    claim_and_start config "worker" task_1;
    (match Coord.transition_task_r config ~agent_name:"worker"
             ~task_id:task_1 ~action:Types.Submit_for_verification () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e));
    ignore
      (create_pending_request config ~task_id:task_1 ~worker:"worker"
         ~request_id:"vrf-pending-claim-next");
    Coord.claim_next_r config ~agent_name:"worker" ()
    |> expect_claim_next_claimed ~task_id:task_2 ~released_task_id:None;
    Alcotest.(check string) "pending task remains awaiting_verification"
      "awaiting_verification" (status_string config task_1);
    Coord.claim_next_r config ~agent_name:"other" ()
    |> expect_claim_next_no_unclaimed)

let test_claim_next_skips_rejected_verification_tasks () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_1 = add_strict_task config in
    let task_2 = add_strict_task config in
    claim_and_start config "worker" task_1;
    (match Coord.transition_task_r config ~agent_name:"worker"
             ~task_id:task_1 ~action:Types.Submit_for_verification () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e));
    let req =
      create_pending_request config ~task_id:task_1 ~worker:"worker"
        ~request_id:"vrf-rejected-claim-next"
    in
    (match Coord.transition_task_r config ~agent_name:"verifier"
             ~task_id:task_1 ~action:Types.Reject_verification
             ~reason:"CI checks failed at plan commit and PR head" () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("reject failed: " ^ Types.show_masc_error e));
    (match Verification.submit_verdict ~base_path:config.Coord.base_path
             ~req_id:req.id ~verifier:"verifier"
             ~verdict:(Verification.Fail "CI checks failed at plan commit and PR head") with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit_verdict failed: " ^ e));
    Coord.claim_next_r config ~agent_name:"worker" ()
    |> expect_claim_next_claimed ~task_id:task_2 ~released_task_id:(Some task_1);
    Coord.claim_next_r config ~agent_name:"other" ()
    |> expect_claim_next_no_eligible)

let test_claim_next_blocks_pending_requests_stored_only_under_masc_root () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    let req =
      match Verification.create_request ~base_path:config.Coord.base_path
              ~task_id ~output:`Null ~criteria:[] ~worker:"worker"
              ~request_id:"vrf-masc-root-only" () with
      | Ok req -> req
      | Error e -> Alcotest.fail ("create_request failed: " ^ e)
    in
    let active_path =
      Filename.concat (Filename.concat (Coord_utils.masc_dir config) "verifications")
        (req.id ^ ".json")
    in
    Alcotest.(check bool) "request stored under .masc" true
      (Sys.file_exists active_path);
    Alcotest.(check bool) "legacy root verifications absent" false
      (Sys.file_exists
         (Filename.concat config.Coord.base_path "verifications"));
    Coord.claim_next_r config ~agent_name:"other" ()
    |> expect_claim_next_no_eligible)

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
(* Verification timeout transition (check_timeouts)                  *)
(* ================================================================ *)

(* Move a task's deadline far into the past so the next check_timeouts
   cycle sees [now > deadline_ts] without sleeping. *)
let force_deadline_past config task_id =
  let backlog = Coord.read_backlog config in
  let past_iso =
    Types.iso8601_of_unix_seconds (Time_compat.now () -. 3600.0)
  in
  let new_tasks =
    List.map (fun (t : Types.task) ->
      if t.id <> task_id then t
      else match t.task_status with
        | Types.AwaitingVerification fields ->
          { t with task_status =
              Types.AwaitingVerification { fields with deadline = Some past_iso } }
        | _ -> t)
      backlog.tasks
  in
  Coord.write_backlog config { backlog with tasks = new_tasks }

let test_check_timeouts_transitions_awaiting_to_cancelled () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match Coord.transition_task_r config ~agent_name:"worker"
             ~task_id ~action:Types.Submit_for_verification () with
     | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e)
     | Ok _ -> ());
    Alcotest.(check string) "pre-check status" "awaiting_verification"
      (status_string config task_id);
    force_deadline_past config task_id;
    Verification_protocol.check_timeouts ~config;
    Alcotest.(check string) "post-check status" "cancelled"
      (status_string config task_id);
    match get_task config task_id with
    | Some { task_status = Types.Cancelled { cancelled_by; reason; _ }; _ } ->
      Alcotest.(check string) "cancelled_by system" "system" cancelled_by;
      let reason_str = Option.value reason ~default:"" in
      Alcotest.(check bool)
        "reason mentions verification deadline" true
        (Astring.String.is_infix ~affix:"verification deadline" reason_str)
    | _ -> Alcotest.fail "task is not Cancelled after check_timeouts")

let test_check_timeouts_idempotent_after_cancel () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match Coord.transition_task_r config ~agent_name:"worker"
             ~task_id ~action:Types.Submit_for_verification () with
     | Error e -> Alcotest.fail ("submit failed: " ^ Types.show_masc_error e)
     | Ok _ -> ());
    force_deadline_past config task_id;
    Verification_protocol.check_timeouts ~config;
    let status_after_first = status_string config task_id in
    Verification_protocol.check_timeouts ~config;
    let status_after_second = status_string config task_id in
    Alcotest.(check string) "first check cancels" "cancelled" status_after_first;
    Alcotest.(check string) "second check is no-op" "cancelled" status_after_second)

(* ================================================================ *)
(* Test suite                                                        *)
(* ================================================================ *)

let () =
  Alcotest.run "verification_fsm" [
    ("transitions_enabled", [
      Alcotest.test_case "submit moves to awaiting_verification" `Quick
        test_submit_for_verification_moves_to_awaiting;
      Alcotest.test_case "submit sets timeout deadline" `Quick
        test_submit_for_verification_sets_timeout_deadline;
      Alcotest.test_case "submit from claimed moves to awaiting_verification"
        `Quick test_submit_for_verification_from_claimed_moves_to_awaiting;
      Alcotest.test_case "submit prepare failure keeps task in_progress"
        `Quick test_submit_prepare_failure_keeps_task_in_progress;
      Alcotest.test_case "submit splits criteria/evidence by contract field"
        `Quick test_submit_populates_criteria_from_completion_contract;
      Alcotest.test_case "submit marks conflict triage from completed deliverable"
        `Quick test_submit_marks_conflict_triage_when_deliverable_claims_completion;
      Alcotest.test_case "cross-agent approve moves to done" `Quick
        test_approve_by_other_agent_moves_to_done;
      Alcotest.test_case "cross-agent reject moves to in_progress" `Quick
        test_reject_by_other_agent_moves_to_in_progress;
      Alcotest.test_case "approve prepare failure keeps task awaiting" `Quick
        test_approve_prepare_failure_keeps_task_awaiting;
      Alcotest.test_case "reject prepare failure keeps task awaiting" `Quick
        test_reject_prepare_failure_keeps_task_awaiting;
      Alcotest.test_case "claim_next skips pending verification tasks" `Quick
        test_claim_next_skips_pending_verification_tasks;
      Alcotest.test_case "claim_next skips rejected verification tasks" `Quick
        test_claim_next_skips_rejected_verification_tasks;
      Alcotest.test_case ".masc pending verification blocks claim_next" `Quick
        test_claim_next_blocks_pending_requests_stored_only_under_masc_root;
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
    ("timeout_check", [
      Alcotest.test_case "check_timeouts transitions AwaitingVerification to Cancelled"
        `Quick test_check_timeouts_transitions_awaiting_to_cancelled;
      Alcotest.test_case "check_timeouts is idempotent after cancellation"
        `Quick test_check_timeouts_idempotent_after_cancel;
    ]);
  ]
