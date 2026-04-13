(** Tests for the HITL approval pipeline (#5907).

    Proves:
    1. Governance risk classification maps tool names to correct levels
    2. Governance threshold × risk level → correct approval decisions
    3. Approval queue: fiber suspension via Eio.Promise, resolution resumes
    4. Approval queue: stale entries expire with Reject
    5. Approval callback returns correct OAS decisions *)

module GP = Masc_mcp.Governance_pipeline
module AQ = Masc_mcp.Keeper_approval_queue

let check = Alcotest.(check string)

(* ── 1. Risk classification ──────────────────────────────── *)

let test_risk_classification_critical () =
  let tools = [
    ("masc_code_delete", GP.Critical);
    ("masc_force_reset", GP.Critical);
    ("keeper_destroy", GP.Critical);
  ] in
  List.iter (fun (tool_name, expected) ->
    let actual = GP.assess_risk ~tool_name ~input:(`Assoc []) in
    check
      (Printf.sprintf "%s → %s" tool_name (GP.risk_level_to_string expected))
      (GP.risk_level_to_string expected)
      (GP.risk_level_to_string actual)
  ) tools

let test_risk_classification_high () =
  let tools = [
    ("masc_code_write", GP.High);
    ("keeper_write", GP.High);
    ("keeper_fs_edit", GP.High);
    ("keeper_pr_submit", GP.High);
    ("masc_create_task", GP.High);
  ] in
  List.iter (fun (tool_name, expected) ->
    let actual = GP.assess_risk ~tool_name ~input:(`Assoc []) in
    let actual_int = GP.risk_level_to_int actual in
    let expected_int = GP.risk_level_to_int expected in
    Alcotest.(check bool)
      (Printf.sprintf "%s ≥ %s" tool_name (GP.risk_level_to_string expected))
      true
      (actual_int >= expected_int)
  ) tools

let test_risk_classification_low () =
  let tools = [
    ("masc_status", GP.Low);
    ("keeper_context_status", GP.Low);
    ("masc_board_list", GP.Low);
  ] in
  List.iter (fun (tool_name, expected) ->
    let actual = GP.assess_risk ~tool_name ~input:(`Assoc []) in
    check
      (Printf.sprintf "%s → %s" tool_name (GP.risk_level_to_string expected))
      (GP.risk_level_to_string expected)
      (GP.risk_level_to_string actual)
  ) tools

let test_keeper_github_read_only_stays_low () =
  let actual =
    GP.assess_risk
      ~tool_name:"keeper_github"
      ~input:(`Assoc [("cmd", `String "pr view 123")])
  in
  check "keeper_github pr view → low"
    (GP.risk_level_to_string GP.Low)
    (GP.risk_level_to_string actual)

let test_keeper_github_mutation_escalates_high () =
  let actual =
    GP.assess_risk
      ~tool_name:"keeper_github"
      ~input:(`Assoc [("cmd", `String "pr comment 123 --body hi")])
  in
  check "keeper_github pr comment → high"
    (GP.risk_level_to_string GP.High)
    (GP.risk_level_to_string actual)

(* ── 2. Threshold decisions ──────────────────────────────── *)

let test_development_allows_all () =
  (* development: no confirmation needed for any risk level *)
  Alcotest.(check (option string))
    "development → None"
    None
    (Option.map GP.risk_level_to_string (GP.confirm_threshold "development"))

let test_paranoid_blocks_medium () =
  (* paranoid: confirmation from Medium upward *)
  match GP.confirm_threshold "paranoid" with
  | Some GP.Medium -> ()
  | Some other ->
    Alcotest.fail
      (Printf.sprintf "expected Medium, got %s" (GP.risk_level_to_string other))
  | None -> Alcotest.fail "expected Some Medium, got None"

let test_production_blocks_critical () =
  match GP.confirm_threshold "production" with
  | Some GP.Critical -> ()
  | Some other ->
    Alcotest.fail
      (Printf.sprintf "expected Critical, got %s" (GP.risk_level_to_string other))
  | None -> Alcotest.fail "expected Some Critical, got None"

let test_enterprise_blocks_high () =
  match GP.confirm_threshold "enterprise" with
  | Some GP.High -> ()
  | Some other ->
    Alcotest.fail
      (Printf.sprintf "expected High, got %s" (GP.risk_level_to_string other))
  | None -> Alcotest.fail "expected Some High, got None"

(* ── 3. Approval queue: Eio.Promise-based suspend/resume ── *)

let test_approval_queue_submit_and_resolve () =
  Eio_main.run @@ fun _env ->
  (* Simulate: agent fiber submits, operator fiber resolves *)
  Eio.Switch.run @@ fun sw ->
  let result = ref None in
  (* Agent fiber: submit and await (will block until resolved) *)
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name:"test-keeper"
        ~tool_name:"masc_code_delete"
        ~input:(`Assoc [("path", `String "/dangerous")])
        ~risk_level:"critical"
    in
    result := Some decision
  );
  (* Give agent fiber time to submit *)
  Eio.Fiber.yield ();
  (* Verify pending *)
  let pending_count = AQ.pending_count () in
  Alcotest.(check bool) "1 pending" true (pending_count >= 1);
  (* Get pending list to find ID *)
  let pending_json = AQ.list_pending_json () in
  let entries = match pending_json with
    | `List entries -> entries
    | _ -> Alcotest.fail "expected list"
  in
  Alcotest.(check bool) "has entries" true (List.length entries >= 1);
  let id = match List.hd entries with
    | `Assoc kvs ->
      (match List.assoc_opt "id" kvs with
       | Some (`String id) -> id
       | _ -> Alcotest.fail "no id field")
    | _ -> Alcotest.fail "bad entry"
  in
  (* Operator resolves: approve *)
  (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
   | Ok () -> ()
   | Error msg -> Alcotest.fail ("resolve failed: " ^ msg));
  (* Agent fiber should resume *)
  Eio.Fiber.yield ();
  match !result with
  | Some Agent_sdk.Hooks.Approve -> ()
  | Some (Agent_sdk.Hooks.Reject r) ->
    Alcotest.fail ("expected Approve, got Reject: " ^ r)
  | Some (Agent_sdk.Hooks.Edit _) ->
    Alcotest.fail "expected Approve, got Edit"
  | None -> Alcotest.fail "agent fiber did not resume"

let test_approval_queue_reject () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name:"test-keeper"
        ~tool_name:"masc_force_reset"
        ~input:(`Assoc [])
        ~risk_level:"critical"
    in
    result := Some decision
  );
  Eio.Fiber.yield ();
  let pending_json = AQ.list_pending_json () in
  let id = match pending_json with
    | `List (`Assoc kvs :: _) ->
      (match List.assoc_opt "id" kvs with
       | Some (`String id) -> id
       | _ -> "")
    | _ -> ""
  in
  (match AQ.resolve ~id ~decision:(Agent_sdk.Hooks.Reject "too dangerous") with
   | Ok () -> ()
   | Error msg -> Alcotest.fail ("resolve failed: " ^ msg));
  Eio.Fiber.yield ();
  match !result with
  | Some (Agent_sdk.Hooks.Reject reason) ->
    Alcotest.(check bool) "reason contains text" true
      (String.length reason > 0)
  | _ -> Alcotest.fail "expected Reject"

let test_approval_queue_expire_stale () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let decision =
      AQ.submit_and_await
        ~keeper_name:"test-keeper"
        ~tool_name:"masc_dangerous_tool"
        ~input:(`Assoc [])
        ~risk_level:"critical"
    in
    result := Some decision
  );
  Eio.Fiber.yield ();
  (* Expire with max_wait_s=0 → everything is stale *)
  AQ.expire_stale ~max_wait_s:0.0;
  Eio.Fiber.yield ();
  match !result with
  | Some (Agent_sdk.Hooks.Reject reason) ->
    Alcotest.(check bool) "timeout reason" true
      (String.starts_with ~prefix:"approval timed out" reason)
  | _ -> Alcotest.fail "expected Reject from timeout"

let test_approval_resolve_nonexistent () =
  Eio_main.run @@ fun _env ->
  match AQ.resolve ~id:"nonexistent_id" ~decision:Agent_sdk.Hooks.Approve with
  | Error msg ->
    Alcotest.(check bool) "error message" true
      (String.length msg > 0)
  | Ok () -> Alcotest.fail "expected error for nonexistent id"

let test_approval_queue_cancel_cleans_up () =
  Eio_main.run @@ fun _env ->
  (* Simulate: agent fiber is cancelled (Switch closes) while awaiting.
     The pending entry must be cleaned up from the hashtbl. (#5949) *)
  let initial_count = AQ.pending_count () in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Fiber.fork ~sw (fun () ->
       let _decision =
         AQ.submit_and_await
           ~keeper_name:"cancel-test"
           ~tool_name:"masc_dangerous"
           ~input:(`Assoc [])
           ~risk_level:"critical"
       in
       ());
     Eio.Fiber.yield ();
     (* Cancel the switch — this cancels the awaiting fiber *)
     Eio.Switch.fail sw (Failure "simulated shutdown")
   with Failure _ -> ());
  (* After cancellation, the pending entry should be cleaned up *)
  let final_count = AQ.pending_count () in
  Alcotest.(check int) "no orphan entries" initial_count final_count

(* ── 4. Approval callback integration ────────────────────── *)

let test_callback_approves_low_risk () =
  (* development level: no confirmation needed *)
  let cb = GP.to_oas_approval_callback
    ~governance_level:"development" ~keeper_name:"test" in
  let decision = cb ~tool_name:"masc_status" ~input:(`Assoc []) in
  match decision with
  | Agent_sdk.Hooks.Approve -> ()
  | Agent_sdk.Hooks.Reject r ->
    Alcotest.fail ("expected Approve for low-risk tool, got Reject: " ^ r)
  | _ -> Alcotest.fail "unexpected decision"

let test_callback_production_keeper_write_requires_approval () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let initial_pending = AQ.pending_count () in
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let cb =
      GP.to_oas_approval_callback
        ~governance_level:"production" ~keeper_name:"test" in
    let decision =
      cb
        ~tool_name:"keeper_fs_edit"
        ~input:(`Assoc [
          ("path", `String "lib/example.ml");
          ("content", `String "let x = 1\n");
        ])
    in
    result := Some decision
  );
  Eio.Fiber.yield ();
  Alcotest.(check int) "one pending approval"
    (initial_pending + 1) (AQ.pending_count ());
  let pending_json = AQ.list_pending_json () in
  let id =
    match pending_json with
    | `List (`Assoc kvs :: _) ->
      (match List.assoc_opt "id" kvs with
       | Some (`String id) -> id
       | _ -> Alcotest.fail "missing approval id")
    | _ -> Alcotest.fail "expected pending approval entry"
  in
  (match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
   | Ok () -> ()
   | Error msg -> Alcotest.fail ("resolve failed: " ^ msg));
  Eio.Fiber.yield ();
  match !result with
  | Some Agent_sdk.Hooks.Approve -> ()
  | Some _ -> Alcotest.fail "expected Approve after operator resolution"
  | None -> Alcotest.fail "keeper write callback did not suspend for approval"

let test_callback_production_keeper_github_read_only_auto_approved () =
  let cb =
    GP.to_oas_approval_callback
      ~governance_level:"production" ~keeper_name:"test" in
  let decision =
    cb ~tool_name:"keeper_github"
      ~input:(`Assoc [("cmd", `String "pr view 123")])
  in
  match decision with
  | Agent_sdk.Hooks.Approve -> ()
  | Agent_sdk.Hooks.Reject r ->
    Alcotest.fail ("expected Approve for read-only keeper_github, got Reject: " ^ r)
  | _ -> Alcotest.fail "unexpected decision"

(* ── Test runner ──────────────────────────────────────────── *)

let () =
  Alcotest.run "HITL Approval" [
    ("risk_classification", [
      Alcotest.test_case "critical tools" `Quick test_risk_classification_critical;
      Alcotest.test_case "high-risk tools" `Quick test_risk_classification_high;
      Alcotest.test_case "low-risk tools" `Quick test_risk_classification_low;
      Alcotest.test_case "keeper_github read-only stays low" `Quick
        test_keeper_github_read_only_stays_low;
      Alcotest.test_case "keeper_github mutation escalates high" `Quick
        test_keeper_github_mutation_escalates_high;
    ]);
    ("threshold_decisions", [
      Alcotest.test_case "development allows all" `Quick test_development_allows_all;
      Alcotest.test_case "paranoid blocks medium+" `Quick test_paranoid_blocks_medium;
      Alcotest.test_case "production blocks critical" `Quick test_production_blocks_critical;
      Alcotest.test_case "enterprise blocks high+" `Quick test_enterprise_blocks_high;
    ]);
    ("approval_queue", [
      Alcotest.test_case "submit and approve" `Quick test_approval_queue_submit_and_resolve;
      Alcotest.test_case "submit and reject" `Quick test_approval_queue_reject;
      Alcotest.test_case "expire stale" `Quick test_approval_queue_expire_stale;
      Alcotest.test_case "resolve nonexistent" `Quick test_approval_resolve_nonexistent;
      Alcotest.test_case "cancel cleans up" `Quick test_approval_queue_cancel_cleans_up;
    ]);
    ("callback_integration", [
      Alcotest.test_case "low risk auto-approved" `Quick test_callback_approves_low_risk;
      Alcotest.test_case "production keeper write requires approval" `Quick
        test_callback_production_keeper_write_requires_approval;
      Alcotest.test_case "production keeper_github read-only auto-approved" `Quick
        test_callback_production_keeper_github_read_only_auto_approved;
    ]);
  ]
