(** RFC-0262 §9 completion-trust dispatch oracle (E1: scripted backbone).

    A deterministic regression oracle for the completion-trust invariants:
    replay known-bad [keeper_task_done] attempts through the *full* keeper
    tool-dispatch path ([Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome])
    and assert that each deterministic gate rejects them — with no LLM and no
    network. The point is not to measure a behavior change (RFC-0262 Phase 1 is a
    behavior-preserving refactor); it is to *catch* a future regression where a
    Done becomes reachable through an illegitimate path.

    Three deterministic reject gates are on the Done_action path (see
    [Tool_task.handle_transition] gate ordering):

    1. [completion_state_error] (tool_task_contract_gate.ml) — the tool-layer
       ownership/lifecycle precondition, fires first:
         - foreign-owned task + non-owner caller -> [AlreadyClaimed],
           rule_id "task_done_requires_current_owner" (this is the dispatch-level
           enforcement of RFC-0262 axis-2 ownership; [owner_authorized] in
           workspace_task_lifecycle is the deeper redundant defense).
         - Todo (unclaimed) task -> [NotClaimed],
           rule_id "task_done_requires_claimed_or_started".
    2. anti-rationalization Gate 1 (anti_rationalization.ml:644) — completion
       notes below the substance floor ([min_notes_length] = 10) are rejected
       before Gate 3 ever calls an LLM. Reachable only when the caller owns the
       task (otherwise gate 1 above intercepts first).
    3. [Task_completion_gate] — done attempts with substantive notes but no
       trusted, reviewer-inspectable [handoff_context.evidence_refs] are
       rejected, and a later retry with a trusted ref can still complete the
       same task.

    Each reject asserts a gate-SPECIFIC signal (distinct rule_id / substring /
    failure_class), not merely outcome=failure — a tool-not-allowed or unknown-tool
    reject would also be a failure but carries failure_class "policy_rejection",
    so the gate-specific assertion is what proves the *intended* gate fired. Each
    reject also asserts the task FSM was NOT mutated (anti-vacuity).

    Completion success is covered with a locally resolvable trace artifact, so
    the deterministic evidence gate validates the ref without a network/forge
    lookup. Evidence-gate rejection and recovery are covered by replaying a fake
    prose ref followed by a locally resolvable trace ref, proving the gate is
    selective rather than reject-everything. The evaluator's
    Indeterminate-dominates determinism remains covered by
    test_keeper_deterministic_evidence_probe.ml.

    The fixture helpers below are intentionally a local copy of the minimal subset
    used by test_keeper_tool_dispatch_runtime.ml (Eio workspace + a registered
    keeper). Kept self-contained so this oracle is decoupled from that 1.4k-line
    test's churn rather than coupling them through a shared module. *)

open Alcotest

module KET = Masc.Keeper_tool_dispatch_runtime
module Workspace = Masc.Workspace
module Task_completion_gate = Masc.Task_completion_gate

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target then
      if Sys.is_directory target then begin
        Sys.readdir target
        |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target
      end
      else Unix.unlink target
  in
  try rm path with _ -> ()

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let output = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output contents)

let make_meta ?(name = "keeper-completion-trust") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("agent_name", `String name)
        ; ("trace_id", `String "completion-trust-harness-trace")
        ; ("allowed_paths", `List [ `String "*" ])
        ; ("policy_voice_enabled", `Bool false)
        ; ("tool_access", `List [])
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let make_ctx () =
  Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
    ~max_tokens:4000

let with_ws name fn =
  let dir = temp_dir name in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Masc.Workspace.default_config dir in
      let meta = make_meta () in
      ignore (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_registry.unregister ~base_path:config.base_path meta.name)
        (fun () -> fn ~config ~meta ~ctx_work:(make_ctx ())))

let payload_kind = function
  | KET.Structured_success -> "structured_success"
  | KET.Structured_error -> "structured_error"
  | KET.Plain_text -> "plain_text"
  | KET.Malformed_structured _ -> "malformed_structured"

let outcome_label = function
  | `Success -> "success"
  | `Failure -> "failure"

let parse_json raw =
  try Yojson.Safe.from_string raw with
  | Yojson.Json_error err -> fail ("invalid json: " ^ err)

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= text_len
    && (String.sub text idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0

(* Owner of a task if it is currently Claimed/InProgress, else None. *)
let assignee_of config task_id =
  match
    List.find_opt
      (fun (t : Masc_domain.task) -> String.equal t.id task_id)
      (Workspace.get_tasks_raw config)
  with
  | Some
      { task_status =
          ( Masc_domain.Claimed { assignee; _ }
          | Masc_domain.InProgress { assignee; _ } )
      ; _
      } ->
    Some assignee
  | _ -> None

let attempt_done
      ?(evidence_refs = [ "trace:completion-trust-harness" ])
      ~config
      ~meta
      ~ctx_work
      ~task_id
      ~result
      ()
  =
  KET.execute_keeper_tool_call_with_outcome
    ~config
    ~meta
    ~ctx_work
    ~exec_cache:None
    ~name:"keeper_task_done"
    ~input:
      (`Assoc
        [ "task_id", `String task_id
        ; "result", `String result
        ; ( "evidence_refs"
          , `List (List.map (fun ref_ -> `String ref_) evidence_refs) )
        ])
    ()

let seed_trace_evidence ~config trace_id =
  let path =
    Filename.concat
      (Filename.concat
         (Filename.concat config.Workspace.base_path ".masc")
         "trajectories/keeper-completion-trust")
      (trace_id ^ ".jsonl")
  in
  write_file path
    {|{"type":"completion_trust_evidence","turn":0,"trace_id":"test"}|}

let claim_via_dispatch ~config ~meta ~ctx_work ~task_id =
  KET.execute_keeper_tool_call_with_outcome
    ~config
    ~meta
    ~ctx_work
    ~exec_cache:None
    ~name:"keeper_task_claim"
    ~input:(`Assoc [ ("task_id", `String task_id) ])
    ()

(* Test A — non-owner completion is denied (RFC-0262 axis-2 ownership gate). *)
let test_completion_denied_for_non_owner () =
  with_ws "completion_trust_non_owner" (fun ~config ~meta ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"foreign-owned task" ~priority:1
         ~description:"claimed by another agent");
    let foreign = "other-keeper" in
    (match Workspace.claim_task_r config ~agent_name:foreign ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e ->
       fail ("foreign claim setup failed: " ^ Masc_domain.masc_error_to_string e));
    (* pre-state: task-001 owned by a non-caller agent (else the reject below
       would be NotClaimed for the wrong reason). *)
    (match assignee_of config "task-001" with
     | Some a ->
       check bool "pre-state: task owned by a non-caller agent" true
         (not (String.equal a meta.agent_name))
     | None ->
       fail "task-001 must be Claimed/InProgress by the foreign agent before the attack");
    (* attack: caller (non-owner) tries to complete it, with substantive notes so
       the reject is unambiguously about ownership, not note length. *)
    let result =
      attempt_done ~config ~meta ~ctx_work ~task_id:"task-001"
        ~result:"I finished another agent's task on their behalf"
        ()
    in
    check string "non-owner completion outcome" "failure" (outcome_label result.KET.outcome);
    check string "non-owner completion payload shape" "structured_error"
      (payload_kind result.KET.payload_shape);
    let json = parse_json result.KET.raw_output in
    check bool "rejection is ok=false" false Yojson.Safe.Util.(member "ok" json |> to_bool);
    check string "ownership reject is a deterministic workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
    check string "ownership reject rule_id" "task_done_requires_current_owner"
      Yojson.Safe.Util.(member "diagnosis" json |> member "rule_id" |> to_string);
    (* anti-vacuity: the rejected attempt did NOT advance the FSM. *)
    (match assignee_of config "task-001" with
     | Some a ->
       check bool "task still owned by foreign agent after rejected completion" true
         (not (String.equal a meta.agent_name))
     | None -> fail "task-001 must remain Claimed/InProgress after the rejected completion"))

(* Test B — completion of an unclaimed (Todo) task is denied. *)
let test_completion_denied_when_unclaimed () =
  with_ws "completion_trust_unclaimed" (fun ~config ~meta ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"never claimed" ~priority:1
         ~description:"still in the backlog");
    (* task-001 is Todo; nobody claimed it. *)
    let result =
      attempt_done ~config ~meta ~ctx_work ~task_id:"task-001"
        ~result:"pretending an unclaimed backlog item is finished"
        ()
    in
    check string "unclaimed completion outcome" "failure" (outcome_label result.KET.outcome);
    check string "unclaimed completion payload shape" "structured_error"
      (payload_kind result.KET.payload_shape);
    let json = parse_json result.KET.raw_output in
    check string "unclaimed reject is a workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
    check string "unclaimed reject rule_id" "task_done_requires_claimed_or_started"
      Yojson.Safe.Util.(member "diagnosis" json |> member "rule_id" |> to_string);
    (* anti-vacuity: task stays Todo. *)
    match
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some { task_status = Masc_domain.Todo; _ } -> ()
    | _ -> fail "task-001 must remain Todo after the rejected completion")

(* Test C — completion of one's OWN task with sub-floor notes is denied by the
   deterministic anti-rationalization length gate. *)
let test_completion_denied_for_thin_notes () =
  with_ws "completion_trust_thin_notes" (fun ~config ~meta ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"caller's own task" ~priority:1
         ~description:"claimed by the caller, then completed with no substance");
    (* precondition: caller legitimately claims its own task (must own it to reach
       the review gate; otherwise completion_state_error intercepts first). *)
    let claim = claim_via_dispatch ~config ~meta ~ctx_work ~task_id:"task-001" in
    check string "self-claim precondition succeeds" "success" (outcome_label claim.KET.outcome);
    (* attack: complete own task with notes below the substance floor (<10 chars). *)
    let result =
      attempt_done ~config ~meta ~ctx_work ~task_id:"task-001" ~result:"done" ()
    in
    check string "thin-notes completion outcome" "failure" (outcome_label result.KET.outcome);
    check string "thin-notes completion payload shape" "structured_error"
      (payload_kind result.KET.payload_shape);
    let json = parse_json result.KET.raw_output in
    check string "thin-notes reject is a workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
    check bool "thin-notes reject names the anti-rationalization length floor" true
      (contains_substring result.KET.raw_output "completion notes too short");
    (* anti-vacuity: caller still owns the task; it was NOT marked Done. *)
    match assignee_of config "task-001" with
    | Some assignee -> check string "task still owned by caller, not Done" meta.agent_name assignee
    | None -> fail "task-001 must remain Claimed/InProgress after the rejected completion")

let test_completion_with_evidence_refs_succeeds () =
  with_ws "completion_trust_evidence_refs" (fun ~config ~meta ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"complete with evidence refs" ~priority:1
         ~description:"claimed by the caller and completed with trusted proof");
    let claim = claim_via_dispatch ~config ~meta ~ctx_work ~task_id:"task-001" in
    check string "self-claim precondition succeeds" "success" (outcome_label claim.KET.outcome);
    seed_trace_evidence ~config "completion-trust-harness";
    let result =
      attempt_done
        ~config
        ~meta
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Implemented the deliverable and saved trace:completion-trust-harness evidence."
        ~evidence_refs:[ "trace:completion-trust-harness" ]
        ()
    in
    check string "completion outcome" "success" (outcome_label result.KET.outcome);
    check string "completion payload shape" "structured_success"
      (payload_kind result.KET.payload_shape);
    match
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some
        { task_status = Masc_domain.Done { assignee; _ }
        ; handoff_context = Some handoff
        ; _
        } ->
      check string "done assignee" meta.agent_name assignee;
      check (list string) "handoff evidence_refs" [ "trace:completion-trust-harness" ] handoff.evidence_refs
    | Some task ->
      fail
        ("expected task-001 Done with handoff evidence refs, got "
         ^ Masc_domain.task_status_to_string task.task_status)
    | None -> fail "task-001 missing after completion")

(* Test E — the evidence gate BLOCKS an untrusted (fake) reference on the *done*
   path, and the block is RECOVERABLE. This closes the reject-path proof gap the
   old harness docstring left open ("asserting a done-evidence reject here would
   assert a gate that does not exist"): the deterministic evidence gate DOES run
   on Done_action (tool_task.ml: needs_gate = Done_action -> true), so a done
   attempt whose evidence_refs hold no trusted Evidence_ref shape is rejected here.

   Two properties in one flow, mirroring test_completion_with_evidence_refs so the
   ONLY changed variable is trusted-vs-untrusted evidence:
   1. block:    substantive result (clears the anti-rationalization length floor)
                + a prose "reference" a keeper might paste to fake completion
                -> workflow rejection, FSM unchanged (anti-vacuity).
   2. recover:  the SAME work re-submitted with locally resolvable trace evidence
                completes. The keeper is not frozen — this is the property the
                CDAL redesign had to preserve: block fake-done without stalling. *)
let test_untrusted_evidence_denied_then_recovers () =
  with_ws "completion_trust_untrusted_then_recover" (fun ~config ~meta ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"complete with a fake reference" ~priority:1
         ~description:"claimed by the caller, first faked then legitimately proven");
    let claim = claim_via_dispatch ~config ~meta ~ctx_work ~task_id:"task-001" in
    check string "self-claim precondition succeeds" "success" (outcome_label claim.KET.outcome);
    (* block: notes are substantive but the reference is untrusted prose. *)
    let faked =
      attempt_done
        ~config
        ~meta
        ~ctx_work
        ~task_id:"task-001"
        ~result:"Completed the deliverable and verified it end to end."
        ~evidence_refs:[ "trust me, it is done" ]
        ()
    in
    check string "faked completion outcome" "failure" (outcome_label faked.KET.outcome);
    check string "faked completion payload shape" "structured_error"
      (payload_kind faked.KET.payload_shape);
    let faked_json = parse_json faked.KET.raw_output in
    check string "evidence reject is a workflow rejection" "workflow_rejection"
      Yojson.Safe.Util.(member "failure_class" faked_json |> to_string);
    check bool "reject names the trusted-evidence requirement (gate-specific signal)" true
      (contains_substring faked.KET.raw_output
         "no trusted, reviewer-inspectable evidence reference");
    (* anti-vacuity: the faked attempt did NOT advance the FSM. *)
    (match assignee_of config "task-001" with
     | Some assignee ->
       check string "task still owned by caller after the faked completion"
         meta.agent_name assignee
     | None ->
       fail "task-001 must remain Claimed/InProgress after the rejected fake completion");
    seed_trace_evidence ~config "completion-trust-recovery";
    (* recover: same work, now with locally resolvable trace evidence, completes. *)
    let recovered =
      attempt_done
        ~config
        ~meta
        ~ctx_work
        ~task_id:"task-001"
        ~result:
          "Completed the deliverable and saved trace:completion-trust-recovery evidence."
        ~evidence_refs:[ "trace:completion-trust-recovery" ]
        ()
    in
    check string "recovery completion outcome" "success" (outcome_label recovered.KET.outcome);
    check string "recovery payload shape" "structured_success"
      (payload_kind recovered.KET.payload_shape);
    match
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id "task-001")
        (Workspace.get_tasks_raw config)
    with
    | Some
        { task_status = Masc_domain.Done { assignee; _ }
        ; handoff_context = Some handoff
        ; _
        } ->
      check string "recovered done assignee" meta.agent_name assignee;
      check (list string) "recovered handoff evidence_refs"
        [ "trace:completion-trust-recovery" ]
        handoff.evidence_refs
    | Some task ->
      fail
        ("expected task-001 Done after recovery, got "
         ^ Masc_domain.task_status_to_string task.task_status)
    | None -> fail "task-001 missing after recovery completion")

(* Test D — positive control: the gates are SELECTIVE, not reject-everything.
   A keeper claiming its own backlog task is accepted on the same dispatch path. *)
let test_legitimate_claim_succeeds () =
  with_ws "completion_trust_positive_claim" (fun ~config ~meta ~ctx_work ->
    ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
    ignore
      (Workspace.add_task config ~title:"claimable task" ~priority:1
         ~description:"unowned backlog work");
    let result = claim_via_dispatch ~config ~meta ~ctx_work ~task_id:"task-001" in
    check string "legitimate claim outcome" "success" (outcome_label result.KET.outcome);
    check string "legitimate claim payload shape" "structured_success"
      (payload_kind result.KET.payload_shape);
    match assignee_of config "task-001" with
    | Some assignee -> check string "claimed task is owned by the caller" meta.agent_name assignee
    | None -> fail "task-001 must be Claimed/InProgress after a legitimate claim")

let () =
  Masc_test_deps.init_keeper_tool_registry ();
  (* The anti-rationalization review resolves an evaluator-runtime id before its
     gates run (default-arg of [Anti_rationalization.review]); that resolution
     reads [Workspace_hooks.get_default_runtime_id_fn], which the real server
     wires at boot (mcp_server.ml) and which raises if left unconnected. Wire a
     fixed dummy id so Test C reaches Gate 1. The length verdict stays
     deterministic: notes below [min_notes_length] short-circuit before the
     Gate-3 LLM call, so no model runtime is ever invoked. *)
  Atomic.set Workspace_hooks.get_default_runtime_id_fn (fun () -> "test-evaluator-runtime");
  (* Wire the REAL evidence gate into the completion hook. The hook defaults to a
     permissive stub (workspace_hooks.ml: always Pass); the running server swaps
     in the deterministic gate at boot via Workspace_metric_hooks. Left unwired,
     every done attempt passes the gate vacuously — a completion-with-evidence
     test would go green without the gate ever running, and a fake-evidence
     reject could never be observed. This replicates the boot adapter so the
     reject/recover oracle (and the evidence_refs-success test) exercise the
     gate itself rather than the stub. *)
  Atomic.set Workspace_hooks.task_completion_gate_decide_fn
    (fun ~base_path ~task_id ~task_opt ~notes ~handoff () ->
      match
        Task_completion_gate.decide ~base_path ~task_id ~task_opt ~notes ~handoff_context:handoff ()
      with
      | Task_completion_gate.Pass -> Workspace_hooks.Pass
      | Task_completion_gate.Reject { reason; rule_id; hint; payload_json } ->
        Workspace_hooks.Reject { reason; rule_id; hint; payload_json });
  run "Completion_trust_harness"
    [ ( "completion_trust_dispatch_oracle"
      , [ test_case "non-owner completion is denied (ownership gate)" `Quick
            test_completion_denied_for_non_owner
        ; test_case "completion of an unclaimed task is denied" `Quick
            test_completion_denied_when_unclaimed
        ; test_case "completion with sub-floor notes is denied (anti-rationalization length gate)"
            `Quick test_completion_denied_for_thin_notes
        ; test_case "completion with evidence_refs succeeds"
            `Quick test_completion_with_evidence_refs_succeeds
        ; test_case "untrusted evidence is denied then a trusted retry recovers"
            `Quick test_untrusted_evidence_denied_then_recovers
        ; test_case "legitimate self-claim is accepted (selectivity control)" `Quick
            test_legitimate_claim_succeeds
        ] )
    ]
