module Admission = Masc.Keeper_approval_input_admission

(* What the operator's window currently says. The store takes the window as an
   argument -- it is reachable from a raw Domain, where reading a setting
   raises -- so every caller names it. These cases are not about the window and
   pass what production passes. *)
let history_retained () =
  Runtime_params.get Masc.Runtime_settings.keeper_checkpoint_history_retained

let checkpoint ?(working_context = Some (`Assoc [])) messages =
  Agent_core.Checkpoint.
    { provider_binding = None; version = checkpoint_version
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
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None; mcp_sessions = []
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
  ignore (Masc.Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    ~history_retained:(history_retained ()) ~session_dir newer |> unwrap);
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
  (match Masc.Keeper_checkpoint_store.save_agent_core_if_absent ~boundary:Agent_core.Checkpoint_objects.Turn_continues ~session_dir first with
   | Installed { auxiliary = []; _ } -> ()
   | _ -> Alcotest.fail "cold checkpoint creation failed");
  let loser = checkpoint [Agent_core.Types.user_msg "late cold writer"] in
  (match Masc.Keeper_checkpoint_store.save_agent_core_if_absent ~boundary:Agent_core.Checkpoint_objects.Turn_continues ~session_dir loser with
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
    match result.replay_evidence with
    | [ evidence ] -> evidence
    | [] | _ :: _ :: _ -> Alcotest.fail "expected one independent replay evidence"
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

let gate_and_answer_co_admission () = with_directory (fun root ->
  let session_dir = Filename.concat root "session" in
  let answer = Agent_core.Types.user_msg
      "event=ask_answered post_id=keeper-ask:schedule author=operator preview=2026-10-17 / 전시실" in
  let ask_identity = Admission.answered_ask_identity ~ask_id:"approval-a"
      ~evidence_fingerprint:"answer-v1" |> unwrap in
  let co_inputs = [ask_identity, answer] in
  let admit cp = Masc.Keeper_approval_input_checkpoint.admit ~co_inputs
      ~session_dir ~identity:(identity "receipt-a") ~message:input cp |> unwrap in
  let first = admit (checkpoint []) in
  Alcotest.(check int) "Gate and Ask committed together, distinct typed identities" 2
    (List.length first.messages);
  let disk = Masc.Keeper_checkpoint_store.load_agent_core
      ~session_dir ~session_id:first.session_id |> unwrap in
  Alcotest.(check bool) "Gate persisted" true
    (Admission.contains ~identity:(identity "receipt-a") ~message:input disk.messages);
  Alcotest.(check bool) "complete Ask persisted" true
    (Admission.contains ~identity:ask_identity ~message:answer disk.messages);
  let later = { disk with turn_count = 12;
    messages = disk.messages @ List.init 10 (fun _ -> Agent_core.Types.user_msg "Continue.") } in
  ignore (Masc.Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    ~history_retained:(history_retained ()) ~session_dir later |> unwrap);
  let retried = admit (checkpoint []) in
  Alcotest.(check int) "same Gate and Ask retry retains ten later turns without duplication" 12
    (List.length retried.messages);
  let second = Agent_core.Types.user_msg "operator corrected the room" in
  let second_identity = Admission.answered_ask_identity ~ask_id:"new-ask"
      ~evidence_fingerprint:"answer-v2" |> unwrap in
  let after = Masc.Keeper_approval_input_checkpoint.admit
      ~co_inputs:[second_identity, second] ~session_dir
      ~identity:(identity "receipt-a") ~message:input (checkpoint []) |> unwrap in
  Alcotest.(check int) "already admitted Gate admits new Ask once" 13 (List.length after.messages);
  let conflict = Admission.answered_ask_identity ~ask_id:"approval-a"
      ~evidence_fingerprint:"different-answer" |> unwrap in
  (match Masc.Keeper_approval_input_checkpoint.admit ~co_inputs:[conflict, second]
      ~session_dir ~identity:(Admission.identity ~approval_id:"new-gate" ~evidence_fingerprint:"receipt-new" |> unwrap) ~message:input after with
   | Error _ -> () | Ok _ -> Alcotest.fail "conflicting co-input was accepted");
  let unchanged = Masc.Keeper_checkpoint_store.load_agent_core
      ~session_dir ~session_id:after.session_id |> unwrap in
  Alcotest.(check bool) "failed co-admission changes neither input" true
    (unchanged.messages = after.messages))

(* RFC-0468 §3.2: an input admitted before its speaker was stamped matches the
   stamped copy of the same input. A gate pending across the upgrade resumes
   instead of admitting the answer a second time. *)
let speaker_stamp_resumes_pre_speaker_admission () =
  let before = admitted () in
  let stamped =
    { input with
      metadata =
        Masc.Keeper_input_speaker.metadata
          (Masc.Keeper_input_speaker.Person Masc.Keeper_input_speaker.Owner) }
  in
  match Admission.prepare ~identity:(identity "receipt-a") ~message:stamped before with
  | Ok (Admission.Admission_resume after) ->
    Alcotest.(check bool) "history unchanged, no second copy" true
      (after.messages = before.messages)
  | Ok (Admission.Admission_new _) -> Alcotest.fail "the stamped input was admitted again"
  | Error error -> Alcotest.fail (Admission.error_to_string error)

let answered_ask_prompt_upgrade () =
  let base_text =
    "event=ask_answered post_id=\"keeper-ask:schedule\" author=\"operator\" title=\"schedule\" preview=\"2026-10-17 / 전시실\""
  in
  let module Ask = Masc.Keeper_ask in
  let question =
    Ask.question
      ~question_id:"q-schedule"
      ~header:"schedule"
      ~prompt:"어느 전시의 일정과 입장료를 확정할까요?"
      ~choices:[]
      ~mode:Ask.Single
      ~free_text:(Ask.Free_text_allowed { hint = None })
    |> unwrap
  in
  let original_ask =
    Ask.ask
      ~ask_id:"schedule"
      ~keeper_name:"alpha"
      ~questions:[ question ]
      ~context:"전시 준비 결정"
      ~task_id:"task-101"
      ~goal_id:"goal-original"
      ~continuation:(Keeper_continuation_channel.unrouted "approval admission fixture")
      ~asked_at:100.0
      ()
    |> unwrap
  in
  let answers =
    Ask.parse_answers
      ~ask:original_ask
      ~submissions:[ "q-schedule", Ask.Wrote "2026-10-17 / 전시실" ]
    |> unwrap
  in
  let ask_input : Masc.Keeper_world_observation.answered_ask_input =
    { original_ask; answers; answered_at = 200.0 }
  in
  let canonical_fp =
    Masc.Keeper_unified_prompt.answered_ask_evidence_fingerprint ask_input
  in
  let canonical_id =
    Admission.answered_ask_identity
      ~ask_id:"keeper-ask:schedule"
      ~evidence_fingerprint:canonical_fp
    |> unwrap
  in
  let initial_msg = Agent_core.Types.user_msg base_text in
  let initial_cp =
    match
      Admission.prepare ~identity:canonical_id ~message:initial_msg (checkpoint [])
      |> unwrap
    with
    | Admission.Admission_new cp -> cp
    | Admission.Admission_resume _ ->
      Alcotest.fail "expected initial canonical answer admission"
  in
  let expanded_msg =
    Agent_core.Types.user_msg
      (base_text
       ^ " ask_origin=\"{\\\"task_id\\\":\\\"task-101\\\"}\" questions=\"[...]\"")
  in
  let upgraded_cp =
    match
      Admission.prepare ~identity:canonical_id ~message:expanded_msg initial_cp |> unwrap
    with
    | Admission.Admission_new cp -> cp
    | Admission.Admission_resume _ ->
      Alcotest.fail "expected prompt-rendering change to revoke old marker and admit expanded row"
  in
  Alcotest.(check int)
    "initial message preserved without marker plus upgraded message"
    2
    (List.length upgraded_cp.messages);
  (match
     Admission.prepare ~identity:canonical_id ~message:expanded_msg upgraded_cp |> unwrap
   with
   | Admission.Admission_resume resumed_cp ->
     Alcotest.(check int)
       "subsequent wake resumes without duplicating upgraded message"
       2
       (List.length resumed_cp.messages)
   | Admission.Admission_new _ ->
     Alcotest.fail "upgraded canonical answer should resume on subsequent wake");
  let reworded_msg =
    Agent_core.Types.user_msg (base_text ^ " questions=\"[updated-rendering]\"")
  in
  (match
     Admission.prepare ~identity:canonical_id ~message:reworded_msg upgraded_cp |> unwrap
   with
   | Admission.Admission_new cp ->
     Alcotest.(check bool)
       "prompt-rendering change for same canonical answer revokes old marker and admits new copy"
       true
       (Admission.contains ~identity:canonical_id ~message:reworded_msg cp.messages)
   | Admission.Admission_resume _ ->
     Alcotest.fail "expected updated prompt text to replace marker");
  let other_answers =
    Ask.parse_answers
      ~ask:original_ask
      ~submissions:[ "q-schedule", Ask.Wrote "다른 답변" ]
    |> unwrap
  in
  let conflicting_fp =
    Masc.Keeper_unified_prompt.answered_ask_evidence_fingerprint
      { ask_input with answers = other_answers }
  in
  let conflicting_id =
    Admission.answered_ask_identity
      ~ask_id:"keeper-ask:schedule"
      ~evidence_fingerprint:conflicting_fp
    |> unwrap
  in
  expect_conflict
    (Admission.prepare ~identity:conflicting_id ~message:reworded_msg upgraded_cp)

let batched_replay_admission () = with_directory (fun root ->
  let module Replay = Masc.Keeper_gate_replay in
  let session_dir = Filename.concat root "batch-session" in
  let artifact bytes =
    Replay.For_testing.persist_replay_artifact ~base_path:root bytes |> unwrap in
  let first_outcome = Replay.Applied
    { operation = "filesystem_write"; output_ref = artifact "first effect";
      journal = Replay.Replay_journal_recorded } in
  let second_outcome = Replay.Failed
    { operation = "tool_execute"; detail_ref = artifact "second refusal";
      journal = Replay.Replay_journal_recorded } in
  let resolution approval_id : Keeper_event_queue.hitl_resolution =
    { approval_id; decision = Keeper_event_queue.Hitl_approved;
      channel = Keeper_continuation_channel.unrouted "batch admission fixture" } in
  let observed approval_id outcome =
    Replay.resolution_input ~resolution:(resolution approval_id)
      ~replay_delivery:(Some (approval_id, outcome)) |> unwrap in
  let model = Replay.compose_model_message ~base_path:root
    ~user_message:"Continue the original request."
    ~inputs:[ observed "approval-a" first_outcome; observed "approval-b" second_outcome ] in
  Alcotest.(check (list string)) "both source resolutions retain their order"
    [ "approval-a"; "approval-b" ]
    (List.map (fun (resolution : Keeper_event_queue.hitl_resolution) -> resolution.approval_id)
       model.resolutions);
  let first, second = match model.replay_evidence with
    | [ first; second ] -> Replay.approval_input first |> unwrap,
                           Replay.approval_input second |> unwrap
    | [] | [ _ ] | _ :: _ :: _ :: _ ->
      Alcotest.fail "both approvals must keep independent canonical evidence" in
  let first_identity, first_message = first in
  let second_identity, second_message = second in
  Alcotest.(check bool) "approval identities remain distinct" false
    (first_identity = second_identity);
  let original = Agent_core.Types.user_msg "Original conversation" in
  let admit cp = Masc.Keeper_approval_input_checkpoint.admit
    ~session_dir ~identity:first_identity ~message:first_message ~co_inputs:[ second ] cp
    |> unwrap in
  let initial = admit (checkpoint [ original ]) in
  Alcotest.(check int) "original conversation plus both approval inputs" 3
    (List.length initial.messages);
  List.iter (fun (identity, message) ->
    Alcotest.(check bool) "each approval has its own admission marker" true
      (Admission.contains ~identity ~message initial.messages)) [ first; second ];
  let later = Agent_core.Types.assistant_msg "Later work" in
  let progressed = { initial with messages = initial.messages @ [ later ]; turn_count = 4 } in
  ignore (Masc.Keeper_checkpoint_store.save_agent_core_classified
    ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    ~history_retained:(history_retained ()) ~session_dir progressed |> unwrap);
  let restarted = admit (checkpoint []) in
  Alcotest.(check bool) "retry preserves newer history without duplicating either approval" true
    (restarted.messages = progressed.messages && restarted.turn_count = 4);
  let without_second = List.filter (fun message ->
    not (Admission.contains ~identity:second_identity ~message:second_message [ message ]))
    restarted.messages in
  let projected = Masc.Keeper_run_tools_hooks.project_model_input ~base_path:root
    ~gate_replay_evidence:model.replay_evidence without_second |> unwrap in
  Alcotest.(check int) "provider restores only the windowed second evidence" 4
    (List.length projected);
  Alcotest.(check bool) "restored evidence belongs to the second approval" true
    (List.hd (List.rev projected) = second_message);
  let disk = Masc.Keeper_checkpoint_store.load_agent_core
    ~session_dir ~session_id:initial.session_id |> unwrap in
  Alcotest.(check bool) "provider projection does not rewrite canonical history" true
    (disk.messages = progressed.messages))

let resolution_input_ownership () =
  let module Replay = Masc.Keeper_gate_replay in
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id = "approval-a"; decision = Keeper_event_queue.Hitl_approved;
      channel = Keeper_continuation_channel.unrouted "resolution ownership fixture" } in
  (match Replay.resolution_input ~resolution
    ~replay_delivery:(Some ("approval-b", Replay.Not_applicable)) with
   | Error (Replay.Replay_approval_mismatch { resolution_id; replay_id }) ->
     Alcotest.(check string) "resolution owner" "approval-a" resolution_id;
     Alcotest.(check string) "unrelated replay owner" "approval-b" replay_id
   | Ok _ | Error (Replay.Replay_for_rejected_resolution _) ->
     Alcotest.fail "an unrelated replay was bound to this resolution");
  let rejected = { resolution with decision = Keeper_event_queue.Hitl_rejected "no" } in
  match Replay.resolution_input ~resolution:rejected
    ~replay_delivery:(Some ("approval-a", Replay.Not_applicable)) with
  | Error (Replay.Replay_for_rejected_resolution approval_id) ->
    Alcotest.(check string) "rejected resolution owner" "approval-a" approval_id
  | Ok _ | Error (Replay.Replay_approval_mismatch _) ->
    Alcotest.fail "a rejection accepted an approved replay"

let () = Alcotest.run "approval input admission"
  [ "durable conversation", List.map (fun (name, test) -> Alcotest.test_case name `Quick test)
      [ "Gate and answered Ask atomic admission", gate_and_answer_co_admission
      ; "multiple approval inputs survive restart and provider projection", batched_replay_admission
      ; "resolution input owns its replay", resolution_input_ownership
      ; "restart", restart; "newer history", newer_history; "removed evidence", removed
      ; "rewritten evidence", rewritten; "conflicting effect", conflict
      ; "malformed marker", malformed; "duplicate admission", duplicate
      ; "durable restart with newer history", durable_restart
      ; "cold creation race", cold_creation_race
      ; "interrupted tool before approval", interrupted_tool_then_approval
      ; "stable replay identity and wire projection", stable_replay_identity
      ; "speaker stamp resumes a pre-speaker admission", speaker_stamp_resumes_pre_speaker_admission
      ; "answered Ask prompt upgrade", answered_ask_prompt_upgrade ] ]
