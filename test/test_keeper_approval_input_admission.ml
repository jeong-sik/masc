module Admission = Masc.Keeper_approval_input_admission

let checkpoint ?(working_context = Some (`Assoc [])) messages =
  Agent_core.Checkpoint.
    { version = checkpoint_version
    ; session_id = "old-session"
    ; agent_name = "test-agent"
    ; model = "test-model"
    ; system_prompt = Some "system"
    ; messages
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 1
    ; created_at = 1_000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context
  }


let unwrap = function Ok value -> value | Error _ -> failwith "unexpected error"
let input = Agent_core.Types.user_msg "Approval settled; effect receipt is durable."
let identity fingerprint = Admission.identity ~approval_id:"approval-a" ~evidence_fingerprint:fingerprint |> unwrap
let prepare ?(fingerprint = "receipt-a") checkpoint =
  Admission.prepare ~identity:(identity fingerprint) ~message:input checkpoint
let admitted () =
  match prepare (checkpoint []) |> unwrap with
  | Admission.Admission_new cp -> cp
  | Admission.Admission_resume _ -> failwith "expected new admission"
let resumed cp =
  match prepare cp |> unwrap with
  | Admission.Admission_resume result -> result
  | Admission.Admission_new _ -> failwith "expected resume"
let expect_conflict result =
  match result with
  | Error Admission.Conflicting_evidence -> ()
  | _ -> Alcotest.fail "conflicting effect identity was accepted"

let restart () =
  let cp = admitted () in
  let reloaded = Agent_core.Checkpoint.to_json cp
    |> Yojson.Safe.to_string |> Yojson.Safe.from_string
    |> Agent_core.Checkpoint.of_json |> unwrap in
  let after = resumed reloaded in
  Alcotest.(check int) "one admitted message after restart" 1 (List.length after.messages)

let newer_history () =
  let cp = admitted () in
  let b = Agent_core.Types.user_msg "Independent B made newer progress" in
  let cp = { cp with messages = cp.messages @ [b]; turn_count = 19 } in
  let after = resumed cp in
  Alcotest.(check bool) "entire newer checkpoint preserved" true (after == cp)

let removed () =
  let cp = admitted () in
  let b = Agent_core.Types.user_msg "Compacted B history" in
  let cp = { cp with messages = [b] } in
  match prepare cp |> unwrap with
  | Admission.Admission_new after ->
    Alcotest.(check int) "original input rehydrated" 2 (List.length after.messages);
    Alcotest.(check bool) "B preserved" true (List.hd after.messages = b)
  | _ -> Alcotest.fail "missing evidence treated as admitted"

let rewritten () =
  let cp = admitted () in
  let original = List.hd cp.messages in
  let rewritten = { original with Agent_core.Types.content = [Text "Compacted summary"];
    metadata = original.metadata @ ["other", `String "preserve"] } in
  let cp = { cp with messages = [rewritten] } in
  match prepare cp |> unwrap with
  | Admission.Admission_new after ->
    Alcotest.(check int) "rewritten history plus rehydrated input" 2 (List.length after.messages);
    let first = List.hd after.messages in
    Alcotest.(check bool) "rewritten content retained" true (first.content = rewritten.content);
    Alcotest.(check bool) "only stale marker revoked" true
      (first.metadata = ["other", `String "preserve"]);
    ignore (resumed after)
  | _ -> Alcotest.fail "rewritten evidence did not readmit"

let conflict () = expect_conflict (prepare ~fingerprint:"different-effect" (admitted ()))

let malformed () =
  let cp = admitted () in
  let message = List.hd cp.messages in
  let message = { message with metadata = ["masc.approval_input_admission", `Null] } in
  match prepare { cp with messages = [message] } with
  | Error Admission.Malformed_marker -> ()
  | _ -> Alcotest.fail "malformed marker was silently accepted"

let duplicate () =
  let cp = admitted () in
  match prepare { cp with messages = cp.messages @ cp.messages } with
  | Error Admission.Duplicate_admission -> ()
  | _ -> Alcotest.fail "duplicate admission was silently accepted"

let () = Alcotest.run "approval input admission"
  [ "durable conversation", List.map (fun (name, test) -> Alcotest.test_case name `Quick test)
      [ "restart", restart; "newer history", newer_history; "removed evidence", removed
      ; "rewritten evidence", rewritten; "conflicting effect", conflict
      ; "malformed marker", malformed; "duplicate admission", duplicate ] ]
