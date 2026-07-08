module Types = Masc_domain

(** test_verification_fsm -- FSM transition tests for AwaitingVerification state.

    Tests Phase B+C transitions with MASC_VERIFICATION_FSM_ENABLED=true:
    - InProgress -> AwaitingVerification (submit_for_verification)
    - AwaitingVerification -> Done (cross-agent approve)
    - AwaitingVerification -> InProgress (cross-agent reject)
    - Self-approval/rejection blocked
    - FSM disabled path: error message *)

open Masc
module Planning_eio = Masc.Task.Planning_eio

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
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "worker"));
  Task.Dispatch.reset_for_test ();
  Task.Dispatch.init_jsonl ();
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
    Workspace.read_backlog config
    |> fun backlog -> List.map (fun (t : Masc_domain.task) -> t.id) backlog.tasks
  in
  let title = Printf.sprintf "strict task %d" (List.length existing_ids + 1) in
  let contract : Masc_domain.task_contract = {
    strict = true;
    completion_contract = ["tests pass"];
    required_evidence = [];
    inspect_gate_evidence = [];
    verify_gate_evidence = ["output.json"];
    evidence_claims = [];
    stale_claim_timeout_sec = 0;
    links = { operation_id = None; session_id = None };
  } in
  let _msg = Workspace.add_task ~contract config ~title
    ~priority:3 ~description:"needs verification" in
  let backlog = Workspace.read_backlog config in
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> not (List.mem t.id existing_ids))
      backlog.tasks
  with
  | Some t -> t.id
  | None -> Alcotest.fail "new task not found after add_task"

let add_required_evidence_only_task config =
  let existing_ids =
    Workspace.read_backlog config
    |> fun backlog -> List.map (fun (t : Masc_domain.task) -> t.id) backlog.tasks
  in
  let contract : Masc_domain.task_contract = {
    strict = true;
    completion_contract = [];
    required_evidence = ["artifact://coverage.json"];
    inspect_gate_evidence = [];
    verify_gate_evidence = [];
    evidence_claims = [];
    stale_claim_timeout_sec = 0;
    links = { operation_id = None; session_id = None };
  } in
  let _msg =
    Workspace.add_task ~contract config ~title:"required evidence only"
      ~priority:3 ~description:"requires a named evidence artifact"
  in
  let backlog = Workspace.read_backlog config in
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> not (List.mem t.id existing_ids))
      backlog.tasks
  with
  | Some t -> t.id
  | None -> Alcotest.fail "new task not found after add_task"

let add_placeholder_evidence_task config =
  let existing_ids =
    Workspace.read_backlog config
    |> fun backlog -> List.map (fun (t : Masc_domain.task) -> t.id) backlog.tasks
  in
  let contract : Masc_domain.task_contract = {
    strict = true;
    completion_contract = ["tests pass"];
    required_evidence = ["completion_notes"];
    inspect_gate_evidence = [];
    verify_gate_evidence = ["reviewable_evidence_ref"];
    evidence_claims = [];
    stale_claim_timeout_sec = 0;
    links = { operation_id = None; session_id = None };
  } in
  let _msg =
    Workspace.add_task ~contract config ~title:"placeholder evidence task"
      ~priority:3 ~description:"placeholder evidence must not open verification"
  in
  let backlog = Workspace.read_backlog config in
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> not (List.mem t.id existing_ids))
      backlog.tasks
  with
  | Some t -> t.id
  | None -> Alcotest.fail "new task not found after add_task"

let claim_and_start config agent_name task_id =
  let _ = Workspace.transition_task_r config ~agent_name ~task_id
    ~action:Masc_domain.Claim () in
  let _ = Workspace.transition_task_r config ~agent_name ~task_id
    ~action:Masc_domain.Start () in
  ()

let create_pending_request config ~task_id ~worker ~request_id =
  match Verification.create_request ~base_path:config.Workspace.base_path
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
  let backlog = Workspace.read_backlog config in
  List.find_opt (fun (t : Masc_domain.task) -> t.id = task_id) backlog.tasks

let status_string config task_id =
  match get_task config task_id with
  | None -> "not_found"
  | Some t -> Masc_domain.string_of_task_status t.task_status

let submit_notes = "verification evidence captured for FSM transition test"

(* Strict-contract submits carry evidence through the typed handoff channel
   (#23719 evidence gate, scoped to contract.strict by RFC-0323 Phase A). *)
let submit_handoff : Masc_domain.task_handoff_context =
  { summary = submit_notes
  ; reason = None
  ; next_step = None
  ; failure_mode = None
  ; reclaim_policy = None
  ; evidence_refs = [ "output.json" ]
  ; updated_at = None
  ; updated_by = None
  }

let verification_id_of_task config task_id =
  match get_task config task_id with
  | None -> Alcotest.fail "task not found"
  | Some (t : Masc_domain.task) ->
    (match t.task_status with
     | Masc_domain.AwaitingVerification { verification_id; _ } -> verification_id
     | _ -> Alcotest.fail "task is not awaiting verification")

let expect_claim_next_claimed result ~task_id ~released_task_id =
  match result with
  | Workspace.Claim_next_claimed
      { task_id = actual_task_id; released_task_id = actual_released; _ } ->
      Alcotest.(check string) "claimed task" task_id actual_task_id;
      Alcotest.(check (option string)) "released task" released_task_id
        actual_released
  | Workspace.Claim_next_no_unclaimed ->
      Alcotest.fail "expected claim_next to claim a task, got no_unclaimed"
  | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "expected claim_next to claim a task, got no_eligible"
  | Workspace.Claim_next_error message ->
      Alcotest.failf "expected claim_next to claim a task, got error: %s"
        message

let expect_claim_next_no_eligible result =
  match result with
  | Workspace.Claim_next_no_eligible _ -> ()
  | Workspace.Claim_next_no_unclaimed ->
      Alcotest.fail "expected claim_next to report no_eligible, got no_unclaimed"
  | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.failf "expected claim_next to report no_eligible, got %s"
        task_id
  | Workspace.Claim_next_error message ->
      Alcotest.failf "expected claim_next to report no_eligible, got error: %s"
        message

let expect_claim_next_no_unclaimed result =
  match result with
  | Workspace.Claim_next_no_unclaimed -> ()
  | Workspace.Claim_next_no_eligible _ ->
      Alcotest.fail "expected claim_next to report no_unclaimed, got no_eligible"
  | Workspace.Claim_next_claimed { task_id; _ } ->
      Alcotest.failf "expected claim_next to report no_unclaimed, got %s"
        task_id
  | Workspace.Claim_next_error message ->
      Alcotest.failf "expected claim_next to report no_unclaimed, got error: %s"
        message

(* ================================================================ *)
(* FSM transitions (enabled)                                         *)
(* ================================================================ *)

let test_submit_for_verification_moves_to_awaiting () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    match Workspace.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Masc_domain.Submit_for_verification
            ~notes:submit_notes ~handoff_context:submit_handoff () with
    | Error e -> Alcotest.fail ("submit failed: " ^ Masc_domain.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "awaiting_verification"
        (status_string config task_id))

let test_submit_for_verification_from_claimed_moves_to_awaiting () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    ignore
      (Workspace.transition_task_r config ~agent_name:"worker"
         ~task_id ~action:Masc_domain.Claim ());
    match Workspace.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Masc_domain.Submit_for_verification
            ~notes:submit_notes ~handoff_context:submit_handoff () with
    | Error e -> Alcotest.fail ("submit from claimed failed: " ^ Masc_domain.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "awaiting_verification"
        (status_string config task_id))

let test_submit_prepare_failure_keeps_task_in_progress () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let prepare_called = ref false in
    let result =
      Workspace.transition_task_r config ~agent_name:"worker"
        ~task_id ~action:Masc_domain.Submit_for_verification
        ~notes:submit_notes
        ~handoff_context:submit_handoff
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
      let msg = Masc_domain.show_masc_error e in
      Alcotest.(check bool) "error mentions verification request" true
        (Astring.String.is_infix
           ~affix:"verification request creation failed"
           msg);
      let reqs =
        Verification.list_requests config.Workspace.base_path
        |> List.filter (fun (r : Verification.verification_request) ->
          r.task_id = task_id)
      in
      Alcotest.(check int) "no orphan request" 0 (List.length reqs))

let test_submit_phase_e_no_substring_reject_at_transition () =
  (* RFC-0109 Phase E (2026-05-27): the transition layer no longer
     applies a substring classifier to reject submissions with
      "placeholder-only" notes. Gating for contracted tasks lives in
      [Task_completion_gate.decide] (see test/test_task_completion_gate.ml).
     transition_task_r called directly forwards typed evidence refs as
     observability metadata and lets the verifier protocol observe what
     the keeper actually wrote. *)
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_placeholder_evidence_task config in
    claim_and_start config "worker" task_id;
    let prepare_called = ref false in
    let captured_refs = ref [] in
    let result =
      Workspace.transition_task_r config ~agent_name:"worker"
        ~task_id ~action:Masc_domain.Submit_for_verification
        ~notes:"implementation complete"
        ~handoff_context:submit_handoff
        ~prepare_verification_request:
          (fun ~task:_ ~assignee:_ ~verification_id:_ ~evidence_refs ->
             prepare_called := true;
             captured_refs := evidence_refs;
             Ok ())
        ()
    in
    match result with
    | Error e ->
      Alcotest.fail ("submit should pass at transition layer in Phase E: "
                     ^ Masc_domain.show_masc_error e)
    | Ok _ ->
      Alcotest.(check bool) "prepare called" true !prepare_called;
      Alcotest.(check string) "status moved to awaiting_verification"
        "awaiting_verification" (status_string config task_id);
      Alcotest.(check bool) "contract spec strings carried as observability"
        true
        (List.mem "reviewable_evidence_ref" !captured_refs
         && List.mem "completion_notes" !captured_refs))

let test_submit_retry_records_request_created_backlog_orphan_policy () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let orphan_request_id = "vrf-request-created-backlog-write-failed" in
    ignore
      (create_pending_request
         config
         ~task_id
         ~worker:"worker"
         ~request_id:orphan_request_id);
    (* Simulates the observable orphan left when the verification request
       was already persisted, but the following backlog status write failed
       before the task left InProgress.  Current recovery policy is a retry
       with a fresh verification request; the old request stays as audit
       evidence instead of being mutated implicitly. *)
    Alcotest.(check string)
      "orphaned task still in progress"
      "in_progress"
      (status_string config task_id);
    let retry_request_id = ref None in
    (match
       Workspace.transition_task_r
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Submit_for_verification
         ~notes:submit_notes
         ~handoff_context:submit_handoff
         ~prepare_verification_request:
           (fun ~task:_ ~assignee ~verification_id ~evidence_refs ->
             retry_request_id := Some verification_id;
             match
               Verification.create_request
                 ~base_path:config.Workspace.base_path
                 ~task_id
                 ~output:
                   (`Assoc
                     [ ( "evidence_refs"
                       , `List (List.map (fun s -> `String s) evidence_refs) )
                     ])
                 ~criteria:[]
                 ~worker:assignee
                 ~request_id:verification_id
                 ()
             with
             | Ok _ -> Ok ()
             | Error e -> Error e)
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit retry failed: " ^ Masc_domain.show_masc_error e));
    let new_request_id = verification_id_of_task config task_id in
    Alcotest.(check bool)
      "retry uses a fresh request id"
      true
      (not (String.equal new_request_id orphan_request_id));
    Alcotest.(check (option string))
      "prepare saw retry request id"
      (Some new_request_id)
      !retry_request_id;
    let reqs =
      Verification.list_requests config.Workspace.base_path
      |> List.filter (fun (r : Verification.verification_request) -> r.task_id = task_id)
    in
    Alcotest.(check int) "orphan plus retry request remain visible" 2 (List.length reqs);
    Alcotest.(check bool)
      "original orphan remains pending for audit"
      true
      (List.exists
         (fun (r : Verification.verification_request) ->
           String.equal r.id orphan_request_id
           &&
           match r.status with
           | Pending -> true
           | _ -> false)
         reqs);
    Alcotest.(check bool)
      "retry request is pending"
      true
      (List.exists
         (fun (r : Verification.verification_request) ->
           String.equal r.id new_request_id
           &&
           match r.status with
           | Pending -> true
           | _ -> false)
         reqs))

(* Regression for the criteria ← completion_contract vs
   evidence_refs ← verify_gate_evidence split. Prior to the fix both
   sides pulled from verify_gate_evidence, so criteria ended up
   containing artefact paths instead of the contract text.

   Exercises Verification_protocol.on_submit_for_verification directly —
   Workspace.transition_task_r only flips task.task_status; the protocol call
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
    let reqs = Verification.list_requests config.Workspace.base_path in
    let req = List.find (fun (r : Verification.verification_request) ->
      r.task_id = task_id) reqs in
    let custom_texts = List.filter_map (function
      | Verification.Custom s -> Some s
      | _ -> None) req.criteria in
    (* add_strict_task fixture: completion_contract = ["tests pass"];
       verify_gate_evidence = ["output.json"]. *)
    let expected_criteria, expected_persisted_refs =
      match task.contract with
      | Some c -> c.completion_contract, c.verify_gate_evidence
      | None -> Alcotest.fail "fixture task has no contract"
    in
    Alcotest.(check (list string)) "criteria from completion_contract"
      expected_criteria custom_texts;
    let persisted_refs = match req.output with
      | `Assoc fields ->
          (match List.assoc_opt "evidence_refs" fields with
           | Some (`List xs) ->
               List.filter_map (function `String s -> Some s | _ -> None) xs
           | _ -> [])
      | _ -> []
    in
    Alcotest.(check (list string)) "evidence_refs from verify_gate_evidence"
      expected_persisted_refs persisted_refs)

let string_list_output_field name output =
  match output with
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`List xs) ->
       List.map
         (function
           | `String value -> value
           | other ->
             Alcotest.fail
               (Printf.sprintf "field %s contains non-string element: %s"
                  name (Yojson.Safe.to_string other)))
         xs
     | Some other ->
       Alcotest.fail
         (Printf.sprintf "field %s is not a JSON list: %s"
            name (Yojson.Safe.to_string other))
     | None ->
       Alcotest.fail (Printf.sprintf "field %s missing from output" name))
  | _ -> Alcotest.fail "verification output is not a JSON object"

let test_submit_typed_evidence_split_uses_submitted_refs () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    let task =
      match get_task config task_id with
      | Some t -> t
      | None -> Alcotest.fail "fixture task not retrievable"
    in
    let submitted_refs = [ "https://example.invalid/pr/23057" ] in
    submit_protocol_or_fail
      config
      task
      ~assignee:"verifier-agent"
      ~verification_id:"vrf-typed-evidence"
      ~evidence_refs:submitted_refs;
    let reqs = Verification.list_requests config.Workspace.base_path in
    let req =
      List.find
        (fun (r : Verification.verification_request) -> r.task_id = task_id)
        reqs
    in
    let raw_required_sources =
      match task.contract with
      | Some c ->
        Alcotest.(check (list string))
          "verify-only fixture keeps required_evidence empty"
          []
          c.required_evidence;
        c.verify_gate_evidence @ c.required_evidence
      | None -> Alcotest.fail "fixture task has no contract"
    in
    (* The production projection trims and de-duplicates into deterministic
       order; this fixture has no blanks/placeholders, so sorting the raw
       contract sources is enough without mirroring the projection helper. *)
    let expected_required_artifacts =
      List.sort_uniq String.compare raw_required_sources
    in
    Alcotest.(check (list string))
      "concrete_verification_evidence projection matches raw contract artifacts"
      expected_required_artifacts
      (Task.Completion_review.concrete_verification_evidence task).required_artifacts;
    Alcotest.(check (list string))
      "legacy evidence_refs preserve submitted refs"
      submitted_refs
      (string_list_output_field "evidence_refs" req.output);
    Alcotest.(check (list string))
      "required_artifacts come from the task contract"
      expected_required_artifacts
      (string_list_output_field "required_artifacts" req.output);
    Alcotest.(check (list string))
      "submitted_evidence comes from submit-time evidence_refs"
      submitted_refs
      (string_list_output_field "submitted_evidence" req.output))

let test_submit_uses_required_evidence_when_verify_refs_empty () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_required_evidence_only_task config in
    claim_and_start config "worker" task_id;
    let captured_refs = ref None in
    let result =
      Workspace.transition_task_r
        config
        ~agent_name:"worker"
        ~task_id
        ~action:Masc_domain.Submit_for_verification
        ~notes:"implementation complete"
        ~handoff_context:submit_handoff
        ~prepare_verification_request:
          (fun ~task:_ ~assignee:_ ~verification_id:_ ~evidence_refs ->
             captured_refs := Some evidence_refs;
             Ok ())
        ()
    in
    (match result with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail
         (Printf.sprintf "submit failed: %s" (Masc_domain.show_masc_error e)));
    (* Phase E (2026-05-27): notes survives the typed concat alongside
       the contract's required_evidence. Pre-Phase-E the substring
       classifier would have dropped "implementation complete" — now
       observability metadata reflects what the keeper actually wrote. *)
    Alcotest.(check (list string))
      "required_evidence + notes carried to verification refs"
      ["artifact://coverage.json"; "implementation complete"]
      (Option.value ~default:[] !captured_refs))

let test_submit_marks_conflict_triage_when_deliverable_claims_completion () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    ignore
      (Planning_eio.set_deliverable config ~task_id
         ~content:"Task-001 completed. Exercised masc_operator_snapshot.");
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
    let reqs = Verification.list_requests config.Workspace.base_path in
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
    let _ = Workspace.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Masc_domain.Submit_for_verification
      ~notes:submit_notes ~handoff_context:submit_handoff () in
    match Workspace.transition_task_r config ~agent_name:"verifier"
            ~task_id ~action:Masc_domain.Approve_verification () with
    | Error e -> Alcotest.fail ("approve failed: " ^ Masc_domain.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "done"
        (status_string config task_id))

let test_reject_by_other_agent_moves_to_in_progress () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let _ = Workspace.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Masc_domain.Submit_for_verification
      ~notes:submit_notes ~handoff_context:submit_handoff () in
    match Workspace.transition_task_r config ~agent_name:"verifier"
            ~task_id ~action:Masc_domain.Reject_verification ~reason:"test reject" () with
    | Error e -> Alcotest.fail ("reject failed: " ^ Masc_domain.show_masc_error e)
    | Ok _ ->
      Alcotest.(check string) "status" "in_progress"
        (status_string config task_id))

(* RFC-0221 §3.2: the verdict record write is best-effort POST-commit. A
   record-store failure must NOT block a decided outcome — the approval already
   lives in [task_status] (Done, with the verdict in notes). This is the
   deliberate reversal of the old "keeps_task_awaiting" contract (which let an
   audit-write failure block the outcome and re-admit the drift). The failed
   write leaves the record Pending: an inert orphan (§3.5), which proves the
   failure was tolerated, not hidden. *)
let test_approve_verdict_failure_still_completes () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match
       Workspace.transition_task_r
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Submit_for_verification
         ~notes:submit_notes
         ~handoff_context:submit_handoff
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Masc_domain.show_masc_error e));
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
      Workspace.transition_task_r
        config
        ~agent_name:"verifier"
        ~task_id
        ~action:Masc_domain.Approve_verification
        ~prepare_verification_verdict:
          (fun ~task:_ ~verifier:_ ~verification_id:_ ~decision:_ ->
             prepare_called := true;
             Error "simulated verdict store failure")
        ()
    in
    match result with
    | Error e ->
      Alcotest.fail
        ("approve must complete despite verdict-store failure: "
         ^ Masc_domain.show_masc_error e)
    | Ok _ ->
      Alcotest.(check bool) "verdict prepare attempted post-commit" true
        !prepare_called;
      Alcotest.(check string) "status moves to done"
        "done" (status_string config task_id);
      (match Verification.load_request config.Workspace.base_path req.id with
       | Error err -> Alcotest.fail ("load_request failed: " ^ err)
       | Ok updated ->
         Alcotest.(check bool) "record left pending (audit write tolerated)" true
           (match updated.status with Pending -> true | _ -> false)))

(* RFC-0221 §3.2 (reject side): same reversal. The outcome (InProgress, task
   bounced back to the worker) is in [task_status]; the reject reason reaches
   the worker via the separate post-commit notify, not this record. So an
   audit-record failure must not block the bounce. The failed write leaves the
   record Pending — inert (§3.5). *)
let test_reject_verdict_failure_still_transitions () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match
       Workspace.transition_task_r
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Submit_for_verification
         ~notes:submit_notes
         ~handoff_context:submit_handoff
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Masc_domain.show_masc_error e));
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
      Workspace.transition_task_r
        config
        ~agent_name:"verifier"
        ~task_id
        ~action:Masc_domain.Reject_verification
        ~reason:"missing evidence"
        ~prepare_verification_verdict:
          (fun ~task:_ ~verifier:_ ~verification_id:_ ~decision:_ ->
             prepare_called := true;
             Error "simulated verdict store failure")
        ()
    in
    match result with
    | Error e ->
      Alcotest.fail
        ("reject must transition despite verdict-store failure: "
         ^ Masc_domain.show_masc_error e)
    | Ok _ ->
      Alcotest.(check bool) "verdict prepare attempted post-commit" true
        !prepare_called;
      Alcotest.(check string) "status moves back to in_progress"
        "in_progress" (status_string config task_id);
      (match Verification.load_request config.Workspace.base_path req.id with
       | Error err -> Alcotest.fail ("load_request failed: " ^ err)
       | Ok updated ->
         Alcotest.(check bool) "record left pending (audit write tolerated)" true
         (match updated.status with Pending -> true | _ -> false)))

let test_approve_retry_recovers_completed_verdict_orphan () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match
       Workspace.transition_task_r
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Submit_for_verification
         ~notes:submit_notes
         ~handoff_context:submit_handoff
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Masc_domain.show_masc_error e));
    let verification_id = verification_id_of_task config task_id in
    ignore (create_pending_request config ~task_id ~worker:"worker" ~request_id:verification_id);
    (* Simulates the observable orphan left when the verifier callback
       persisted its verdict, then the subsequent backlog status write
       failed or was lost before the task left AwaitingVerification. *)
    (match
       Verification_protocol.record_approve_verification
         ~config
         ~task_id
         ~verifier:"verifier"
         ~verification_id
         ~notes:"verified"
     with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("record approve failed: " ^ e));
    Alcotest.(check string)
      "orphan status remains awaiting"
      "awaiting_verification"
      (status_string config task_id);
    (match
       Workspace.transition_task_r
         config
         ~agent_name:"verifier"
         ~task_id
         ~action:Masc_domain.Approve_verification
         ~notes:"retry after orphan"
         ~prepare_verification_verdict:
           (fun ~task:_ ~verifier ~verification_id ~decision ->
              match decision with
              | `Approve notes ->
                Verification_protocol.record_approve_verification
                  ~config
                  ~task_id
                  ~verifier
                  ~verification_id
                  ~notes
              | `Reject _ ->
                Error "unexpected reject decision in approve recovery")
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("approve retry failed: " ^ Masc_domain.show_masc_error e));
    Alcotest.(check string)
      "retry moves task done"
      "done"
      (status_string config task_id);
    match Verification.load_request config.Workspace.base_path verification_id with
    | Error e -> Alcotest.fail ("load_request failed: " ^ e)
    | Ok updated ->
      Alcotest.(check bool)
        "request remains completed pass"
        true
        (match updated.status, updated.verifier with
         | Completed Pass, Some "verifier" -> true
         | _ -> false))

let test_reject_retry_recovers_completed_verdict_orphan () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    (match
       Workspace.transition_task_r
         config
         ~agent_name:"worker"
         ~task_id
         ~action:Masc_domain.Submit_for_verification
         ~notes:submit_notes
         ~handoff_context:submit_handoff
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Masc_domain.show_masc_error e));
    let verification_id = verification_id_of_task config task_id in
    ignore (create_pending_request config ~task_id ~worker:"worker" ~request_id:verification_id);
    (* Same orphan shape as the approve case, but the persisted verdict
       is a rejection and the backlog retry should return ownership to
       the worker's in-progress task. *)
    (match
       Verification_protocol.record_reject_verification
         ~config
         ~task_id
         ~verifier:"verifier"
         ~verification_id
         ~reason:"missing evidence"
     with
     | Ok () -> ()
     | Error e -> Alcotest.fail ("record reject failed: " ^ e));
    Alcotest.(check string)
      "orphan status remains awaiting"
      "awaiting_verification"
      (status_string config task_id);
    (match
       Workspace.transition_task_r
         config
         ~agent_name:"verifier"
         ~task_id
         ~action:Masc_domain.Reject_verification
         ~reason:"retry after orphan"
         ~prepare_verification_verdict:
           (fun ~task:_ ~verifier ~verification_id ~decision ->
              match decision with
              | `Reject reason ->
                Verification_protocol.record_reject_verification
                  ~config
                  ~task_id
                  ~verifier
                  ~verification_id
                  ~reason
              | `Approve _ ->
                Error "unexpected approve decision in reject recovery")
         ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("reject retry failed: " ^ Masc_domain.show_masc_error e));
    Alcotest.(check string)
      "retry moves task in_progress"
      "in_progress"
      (status_string config task_id);
    match Verification.load_request config.Workspace.base_path verification_id with
    | Error e -> Alcotest.fail ("load_request failed: " ^ e)
    | Ok updated ->
      Alcotest.(check bool)
        "request remains completed fail"
        true
        (match updated.status, updated.verifier with
         | Completed (Fail reason), Some "verifier" ->
           Astring.String.is_infix ~affix:"retry after orphan" reason
         | _ -> false))

let test_claim_next_preserves_rejected_verification_owner_task () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_1 = add_strict_task config in
    let task_2 = add_strict_task config in
    claim_and_start config "worker" task_1;
    (match Workspace.transition_task_r config ~agent_name:"worker"
             ~task_id:task_1 ~action:Masc_domain.Submit_for_verification
             ~notes:submit_notes ~handoff_context:submit_handoff () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit failed: " ^ Masc_domain.show_masc_error e));
    let req =
      create_pending_request config ~task_id:task_1 ~worker:"worker"
        ~request_id:"vrf-rejected-claim-next"
    in
    (match Workspace.transition_task_r config ~agent_name:"verifier"
             ~task_id:task_1 ~action:Masc_domain.Reject_verification
             ~reason:"CI checks failed at plan commit and PR head" () with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("reject failed: " ^ Masc_domain.show_masc_error e));
    (match Verification.submit_verdict ~base_path:config.Workspace.base_path
             ~req_id:req.id ~verifier:"verifier"
             ~verdict:(Verification.Fail "CI checks failed at plan commit and PR head") with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("submit_verdict failed: " ^ e));
    Workspace.claim_next_r config ~agent_name:"worker" ()
    |> expect_claim_next_claimed ~task_id:task_1 ~released_task_id:None;
    Workspace.claim_next_r config ~agent_name:"other" ()
    |> expect_claim_next_claimed ~task_id:task_2 ~released_task_id:None)

let test_self_approval_blocked () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let _ = Workspace.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Masc_domain.Submit_for_verification
      ~notes:submit_notes ~handoff_context:submit_handoff () in
    match Workspace.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Masc_domain.Approve_verification () with
    | Ok _ -> Alcotest.fail "self-approval should be blocked"
    | Error e ->
      let msg = Masc_domain.show_masc_error e in
      Alcotest.(check bool) "error mentions self-approval" true
        (Astring.String.is_infix ~affix:"Self-approval" msg))

let test_self_rejection_blocked () =
  with_temp_config ~fsm_enabled:true (fun config ->
    let task_id = add_strict_task config in
    claim_and_start config "worker" task_id;
    let _ = Workspace.transition_task_r config ~agent_name:"worker"
      ~task_id ~action:Masc_domain.Submit_for_verification
      ~notes:submit_notes ~handoff_context:submit_handoff () in
    match Workspace.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Masc_domain.Reject_verification () with
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
    let base_path = config.Workspace.base_path in
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
    let base_path = config.Workspace.base_path in
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
    match Workspace.transition_task_r config ~agent_name:"worker"
            ~task_id ~action:Masc_domain.Submit_for_verification
            ~handoff_context:submit_handoff () with
    | Ok _ -> Alcotest.fail "submit should fail when FSM disabled"
    | Error e ->
      let msg = Masc_domain.show_masc_error e in
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
      Alcotest.test_case "submit from claimed moves to awaiting_verification"
        `Quick test_submit_for_verification_from_claimed_moves_to_awaiting;
      Alcotest.test_case "submit prepare failure keeps task in_progress"
        `Quick test_submit_prepare_failure_keeps_task_in_progress;
      Alcotest.test_case "phase E: transition layer no longer substring-rejects submit"
        `Quick test_submit_phase_e_no_substring_reject_at_transition;
      Alcotest.test_case
        "submit retry records request-created backlog orphan policy"
        `Quick
        test_submit_retry_records_request_created_backlog_orphan_policy;
      Alcotest.test_case "submit splits criteria/evidence by contract field"
        `Quick test_submit_populates_criteria_from_completion_contract;
      Alcotest.test_case "submit keeps typed required/submitted evidence split"
        `Quick test_submit_typed_evidence_split_uses_submitted_refs;
      Alcotest.test_case "submit carries required_evidence into verifier refs"
        `Quick test_submit_uses_required_evidence_when_verify_refs_empty;
      Alcotest.test_case "submit marks conflict triage from completed deliverable"
        `Quick test_submit_marks_conflict_triage_when_deliverable_claims_completion;
      Alcotest.test_case "cross-agent approve moves to done" `Quick
        test_approve_by_other_agent_moves_to_done;
      Alcotest.test_case "cross-agent reject moves to in_progress" `Quick
        test_reject_by_other_agent_moves_to_in_progress;
      Alcotest.test_case "approve completes despite verdict-store failure" `Quick
        test_approve_verdict_failure_still_completes;
      Alcotest.test_case "reject transitions despite verdict-store failure" `Quick
        test_reject_verdict_failure_still_transitions;
      Alcotest.test_case
        "approve retry recovers completed verdict orphan"
        `Quick
        test_approve_retry_recovers_completed_verdict_orphan;
      Alcotest.test_case
        "reject retry recovers completed verdict orphan"
        `Quick
        test_reject_retry_recovers_completed_verdict_orphan;
      Alcotest.test_case "claim_next preserves rejected owner task" `Quick
        test_claim_next_preserves_rejected_verification_owner_task;
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
