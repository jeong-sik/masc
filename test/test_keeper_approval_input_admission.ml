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

let with_directory f =
  let path = Filename.temp_file "approval-admission" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> remove path) (fun () -> f path)

let durable_restart () = with_directory (fun root ->
  let session_dir = Filename.concat root "session" in
  let admit cp = Masc.Keeper_approval_input_checkpoint.admit
    ~session_dir ~identity:(identity "receipt-a") ~message:input cp |> unwrap in
  let first = admit (checkpoint []) in
  let b = Agent_core.Types.user_msg "B progressed after approval input" in
  let newer = { first with messages = first.messages @ [b]; turn_count = 3 } in
  Agent_core.Context.set newer.context "newer" (`String "B");
  ignore (Masc.Keeper_checkpoint_store.save_agent_core_classified ~session_dir newer |> unwrap);
  let after = admit (checkpoint []) in
  Alcotest.(check int) "fresh canonical turn retained" 3 after.turn_count;
  Alcotest.(check bool) "B message retained" true (List.hd (List.rev after.messages) = b);
  Alcotest.(check bool) "B context retained" true
    (Agent_core.Context.get after.context "newer" = Some (`String "B"));
  let disk = Masc.Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:after.session_id |> unwrap in
  Alcotest.(check int) "restart does not append again" 2 (List.length disk.messages))

let cold_creation_race () = with_directory (fun root ->
  let session_dir = Filename.concat root "session" in
  let first = checkpoint [Agent_core.Types.user_msg "winner"] in
  (match Masc.Keeper_checkpoint_store.save_agent_core_if_absent ~session_dir first with
   | Installed { auxiliary = []; _ } -> ()
   | _ -> Alcotest.fail "cold checkpoint creation failed");
  let loser = checkpoint [Agent_core.Types.user_msg "late cold writer"] in
  (match Masc.Keeper_checkpoint_store.save_agent_core_if_absent ~session_dir loser with
   | Not_installed { cause = Source_changed _; _ } -> ()
   | _ -> Alcotest.fail "cold loser overwrote existing equal-turn checkpoint");
  let after = Masc.Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:first.session_id |> unwrap in
  Alcotest.(check bool) "winner bytes remain authoritative" true (after.messages = first.messages))

let interrupted_tool_then_approval () = with_directory (fun root ->
  let session_dir = Filename.concat root "session" in
  let request = Agent_core.Types.make_message ~role:Assistant
    [ToolUse { id = "interrupted-call"; name = "read"; input = `Assoc [] }] in
  let after = Masc.Keeper_approval_input_checkpoint.admit
    ~session_dir ~identity:(identity "receipt-a") ~message:input (checkpoint [request]) |> unwrap in
  (match after.messages with
   | first :: result :: approval :: [] ->
     Alcotest.(check bool) "original request preserved" true (first = request);
     Alcotest.(check bool) "tool result closes before approval" true (result.role = Tool);
     Alcotest.(check bool) "approval follows result" true (approval.role = User)
   | _ -> Alcotest.fail "interrupted tool was not closed before approval input");
  ignore (Masc.Keeper_transcript_unit.validate_provider_transcript after.messages |> unwrap))

let stable_replay_identity () = with_directory (fun root ->
  let module Replay = Masc.Keeper_gate_replay in
  let output_ref = Replay.For_testing.persist_replay_artifact ~base_path:root "effect bytes" |> unwrap in
  let evidence journal =
    let result = Replay.append_model_evidence ~approval_id:"approval-a" ~user_message:"changing wake"
      (Applied { operation = "write"; output_ref; journal }) in
    Option.get result.replay_evidence
  in
  let initial = evidence Replay.Replay_journal_recorded in
  let recovered = evidence Replay.Replay_journal_already_recorded in
  let id1, message1 = Replay.approval_input initial |> unwrap in
  let id2, message2 = Replay.approval_input recovered |> unwrap in
  Alcotest.(check bool) "journal disposition does not change message" true (message1 = message2);
  let cp = match Admission.prepare ~identity:id1 ~message:message1 (checkpoint []) |> unwrap with
    | Admission_new cp -> cp | _ -> Alcotest.fail "expected admission" in
  (match Admission.prepare ~identity:id2 ~message:message2 cp |> unwrap with
   | Admission_resume _ -> () | _ -> Alcotest.fail "journal recovery reinjected input");
  let projected = Replay.project_model_input ~base_path:root recovered cp.messages |> unwrap in
  Alcotest.(check int) "intact admission not projected twice" 1 (List.length projected);
  let projected_missing = Replay.project_model_input ~base_path:root recovered [] |> unwrap in
  Alcotest.(check int) "windowed evidence restored on wire" 1 (List.length projected_missing))

let () = Alcotest.run "approval input admission"
  [ "durable conversation", List.map (fun (name, test) -> Alcotest.test_case name `Quick test)
      [ "restart", restart; "newer history", newer_history; "removed evidence", removed
      ; "rewritten evidence", rewritten; "conflicting effect", conflict
      ; "malformed marker", malformed; "duplicate admission", duplicate
      ; "durable restart with newer history", durable_restart
      ; "cold creation race", cold_creation_race
      ; "interrupted tool before approval", interrupted_tool_then_approval
      ; "stable replay identity and wire projection", stable_replay_identity ] ]
