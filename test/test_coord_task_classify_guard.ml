(** Unit tests for [Coord_task_classify.required_tool_claim_guard].

    Validates that the guard correctly rejects claims when the agent's
    tool surface is unknown ([agent_tool_names = None]) and the task
    requires specific tools.  This prevents routing loops where agents
    without the right tools claim tasks they cannot execute. *)

module CTC = Coord_task_classify

(* Minimal config stub — only [base_path] is used by [log_event]. *)
let test_config : CTC.config =
  { base_path = "/tmp/test-classify-guard"
  ; workspace_path = "/tmp/test-classify-guard"
  ; lock_expiry_minutes = 5
  ; backend_config = Backend_types.default_config
  ; backend = CTC.Memory (Backend.Memory.create ())
  }

let make_task ~id ~title ~description ~required_tools () : Masc_domain.task =
  { id
  ; title
  ; description
  ; priority = 3
  ; task_status = Masc_domain.Todo
  ; files = []
  ; created_at = "2026-05-29T00:00:00Z"
  ; created_by = None
  ; goal_id = None
  ; stage = None
  ; contract =
      (if required_tools = []
       then None
       else Some { Masc_domain.strict = false
                 ; completion_contract = []
                 ; required_tools
                 ; required_evidence = []
                 ; required_evidence_typed = []
                 ; inspect_gate_evidence = []
                 ; verify_gate_evidence = []
                 ; links = { operation_id = None; session_id = None }
                 })
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

(* -- agent_tool_names = None, required_tools non-empty → rejected -------- *)

let test_none_with_required_tools_rejects () =
  let task =
    make_task ~id:"t1" ~title:"Run tests"
      ~description:"Execute the test suite"
      ~required_tools:[ "Bash"; "Read" ]
      ()
  in
  (* Omit ~agent_tool_names to pass None *)
  match CTC.required_tool_claim_guard test_config ~agent_name:"codex-mcp-client" task with
  | Ok () ->
    Alcotest.fail "expected rejection when agent_tool_names=None and required_tools non-empty"
  | Error _ -> ()

(* -- agent_tool_names = None, required_tools empty → accepted ----------- *)

let test_none_with_empty_tools_accepts () =
  let task =
    make_task ~id:"t2" ~title:"Review status"
      ~description:"Check current progress"
      ~required_tools:[]
      ()
  in
  (* Omit ~agent_tool_names to pass None *)
  match CTC.required_tool_claim_guard test_config ~agent_name:"codex-mcp-client" task with
  | Ok () -> ()
  | Error e ->
    Alcotest.failf "expected acceptance but got error: %s"
      (Masc_domain.masc_error_to_string e)

(* -- agent_tool_names = Some [...], all tools present → accepted -------- *)

let test_some_with_all_tools_accepts () =
  let task =
    make_task ~id:"t3" ~title:"Run tests"
      ~description:"Execute the test suite"
      ~required_tools:[ "Bash"; "Read" ]
      ()
  in
  match CTC.required_tool_claim_guard test_config ~agent_name:"keeper-helper"
          ~agent_tool_names:[ "Bash"; "Read"; "Grep" ] task with
  | Ok () -> ()
  | Error e ->
    Alcotest.failf "expected acceptance but got error: %s"
      (Masc_domain.masc_error_to_string e)

(* -- agent_tool_names = Some [...], missing tools → rejected ------------ *)

let test_some_with_missing_tools_rejects () =
  let task =
    make_task ~id:"t4" ~title:"Run tests"
      ~description:"Execute the test suite"
      ~required_tools:[ "Bash"; "Read"; "Grep" ]
      ()
  in
  match CTC.required_tool_claim_guard test_config ~agent_name:"codex-mcp-client"
          ~agent_tool_names:[ "Read" ] task with
  | Ok () ->
    Alcotest.fail "expected rejection when required tools are missing"
  | Error _ -> ()

(* -- agent_tool_names = Some [] → rejected when tools required ---------- *)

let test_empty_list_with_required_tools_rejects () =
  let task =
    make_task ~id:"t5" ~title:"Run tests"
      ~description:"Execute the test suite"
      ~required_tools:[ "Bash" ]
      ()
  in
  match CTC.required_tool_claim_guard test_config ~agent_name:"codex-mcp-client"
          ~agent_tool_names:[] task with
  | Ok () ->
    Alcotest.fail "expected rejection when agent has no tools but task requires some"
  | Error _ -> ()

let () =
  Alcotest.run "task_state_classify.required_tool_claim_guard"
    [
      ( "unknown surface (None)",
        [
          Alcotest.test_case
            "required tools non-empty → reject"
            `Quick
            test_none_with_required_tools_rejects;
          Alcotest.test_case
            "required tools empty → accept"
            `Quick
            test_none_with_empty_tools_accepts;
        ] );
      ( "known surface (Some)",
        [
          Alcotest.test_case
            "all tools present → accept"
            `Quick
            test_some_with_all_tools_accepts;
          Alcotest.test_case
            "missing tools → reject"
            `Quick
            test_some_with_missing_tools_rejects;
          Alcotest.test_case
            "empty list with required → reject"
            `Quick
            test_empty_list_with_required_tools_rejects;
        ] );
    ]
