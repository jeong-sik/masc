module Correction = Masc.Keeper_context_correction
module Testing = Correction.For_testing

let message role text =
  Agent_sdk.Types.make_message ~role [ Agent_sdk.Types.Text text ]
;;

let checkpoint ?(messages = []) () =
  let context = Agent_sdk.Context.create_sync () in
  Agent_sdk.Context.set_scoped
    context
    Agent_sdk.Context.Session
    Masc.Keeper_checkpoint_store.keeper_generation_context_key
    (`Int 1);
  Agent_sdk.Checkpoint.
    { version = checkpoint_version
    ; session_id = "trace"
    ; agent_name = "keeper"
    ; model = "model"
    ; system_prompt = Some "system"
    ; messages
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 1
    ; created_at = 1.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.Off
    ; thinking_budget = None
    ; reasoning_effort = None
    ; cache_system_prompt = false
    ; context
    ; mcp_sessions = []
    ; working_context = None
    }
;;

let checkpoint_ref (checkpoint : Agent_sdk.Checkpoint.t) =
  let trace_id =
    match Keeper_id.Trace_id.of_string checkpoint.Agent_sdk.Checkpoint.session_id with
    | Ok value -> value
    | Error detail -> Alcotest.fail detail
  in
  match
    Keeper_checkpoint_ref.create
      ~trace_id
      ~generation:1
      ~turn_count:checkpoint.turn_count
      ~canonical_checkpoint_bytes:(Agent_sdk.Checkpoint.to_string checkpoint)
  with
  | Ok value -> value
  | Error _ -> Alcotest.fail "checkpoint ref"
;;

let install_marker checkpoint marker =
  Agent_sdk.Context.set_scoped
    checkpoint.Agent_sdk.Checkpoint.context
    Agent_sdk.Context.Session
    Correction.state_context_key
    (Testing.marker_to_json marker)
;;

let provenance slot_id =
  Correction.
    { slot_id; call_id = "call"; plan_fingerprint = "plan";
      request_body_sha256 = "request" }
;;

let expect_candidate marker checkpoint =
  match
    Testing.prepare_candidate
      ~marker
      ~raw_checkpoint:checkpoint
      ~semantic_context:"semantic"
  with
  | Ok value -> value
  | Error _ -> Alcotest.fail "candidate rejected"
;;

let test_closed_units_advance_and_open_suffix_is_exact () =
  let open_tool =
    Agent_sdk.Types.make_message
      ~role:Agent_sdk.Types.Assistant
      [ Agent_sdk.Types.ToolUse
          { id = "open"; name = "tool"; input = `Assoc [] }
      ]
  in
  let raw =
    checkpoint
      ~messages:
        [ message Agent_sdk.Types.User "u"
        ; message Agent_sdk.Types.Assistant "a"
        ; open_tool
        ]
      ()
  in
  let marker = Testing.genesis_marker in
  install_marker raw marker;
  let candidate, _ = expect_candidate marker raw in
  match candidate.messages with
  | semantic :: [ protected ] ->
    Alcotest.(check bool) "fixed system role" true
      (semantic.role = Agent_sdk.Types.System);
    Alcotest.(check bool) "open suffix exact" true (protected = open_tool)
  | _ -> Alcotest.fail "unexpected candidate partition"
;;

let test_marker_schema_is_current_only () =
  match Testing.marker_of_json (`Assoc [ "version", `Int 0 ]) with
  | Error Correction.Marker_corrupt -> ()
  | _ -> Alcotest.fail "old marker accepted"
;;

let test_applied_checkpoint_is_downstream_checkpoint () =
  let raw = checkpoint ~messages:[ message Agent_sdk.Types.User "u" ] () in
  let marker = Testing.genesis_marker in
  install_marker raw marker;
  let candidate, _ = expect_candidate marker raw in
  let raw_ref = checkpoint_ref raw in
  let installed_ref = checkpoint_ref candidate in
  let provenance = provenance "second" in
  let outcome =
    Testing.classify_installation
      ~raw_checkpoint:raw
      ~raw_ref
      ~candidate
      ~provenance
      (Masc.Keeper_checkpoint_store.Installed
         { installed_ref; auxiliary = [] })
  in
  Alcotest.(check bool) "corrected downstream" true
    (Correction.checkpoint_of_outcome outcome = Some candidate)
;;

let test_cas_conflict_preserves_raw () =
  let raw = checkpoint ~messages:[ message Agent_sdk.Types.User "u" ] () in
  let marker = Testing.genesis_marker in
  install_marker raw marker;
  let candidate, _ = expect_candidate marker raw in
  let raw_ref = checkpoint_ref raw in
  let provenance = provenance "slot" in
  let outcome =
    Testing.classify_installation
      ~raw_checkpoint:raw
      ~raw_ref
      ~candidate
      ~provenance
      (Masc.Keeper_checkpoint_store.Not_installed
         { cause = Masc.Keeper_checkpoint_store.Source_changed raw_ref
         ; auxiliary = []
         })
  in
  match outcome with
  | Correction.Preserved { checkpoint; reason = Correction.Cas_conflict; _ } ->
    Alcotest.(check bool) "raw preserved" true (checkpoint = raw)
  | _ -> Alcotest.fail "CAS conflict was not loud"
;;

let test_post_durable_auxiliary_is_applied () =
  let raw = checkpoint ~messages:[ message Agent_sdk.Types.User "u" ] () in
  let marker = Testing.genesis_marker in
  install_marker raw marker;
  let candidate, _ = expect_candidate marker raw in
  let raw_ref = checkpoint_ref raw in
  let installed_ref = checkpoint_ref candidate in
  let provenance = provenance "slot" in
  let outcome =
    Testing.classify_installation
      ~raw_checkpoint:raw
      ~raw_ref
      ~candidate
      ~provenance
      (Masc.Keeper_checkpoint_store.Installed
         { installed_ref
         ; auxiliary =
             [ Masc.Keeper_checkpoint_store.Commit_observer_failed
                 (Failure "observed after rename", Printexc.get_callstack 1)
             ]
         })
  in
  match outcome with
  | Correction.Applied _ -> ()
  | _ -> Alcotest.fail "durable installation was discarded"
;;

let test_empty_semantic_output_does_not_advance_marker () =
  let raw = checkpoint ~messages:[ message Agent_sdk.Types.User "u" ] () in
  let marker = Testing.genesis_marker in
  install_marker raw marker;
  match
    Testing.prepare_candidate
      ~marker
      ~raw_checkpoint:raw
      ~semantic_context:" "
  with
  | Error Correction.Semantic_output_invalid ->
    Alcotest.(check bool) "marker unchanged" true
      (Agent_sdk.Context.get_scoped
         raw.context
         Agent_sdk.Context.Session
         Correction.state_context_key
       = Some (Testing.marker_to_json marker))
  | _ -> Alcotest.fail "empty semantic output accepted"
;;

let test_executor_never_runs_inline () =
  Testing.reset_executor ();
  let ran = ref false in
  let outcome =
    Correction.submit
      ~base_path:"/tmp/context-correction"
      ~keeper_name:"keeper"
      (fun () -> ran := true)
  in
  Alcotest.(check bool) "unavailable" true
    (outcome = Correction.Unavailable);
  Alcotest.(check bool) "not inline" false !ran
;;

let test_executor_coalesces_and_releases () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Testing.reset_executor ();
  Correction.init ~sw;
  let release_p, release_u = Eio.Promise.create () in
  let first =
    Correction.submit
      ~base_path:"/tmp/context-correction"
      ~keeper_name:"keeper"
      (fun () -> Eio.Promise.await release_p)
  in
  Eio.Fiber.yield ();
  let second =
    Correction.submit
      ~base_path:"/tmp/context-correction"
      ~keeper_name:"keeper"
      (fun () -> ())
  in
  Alcotest.(check bool) "submitted" true (first = Correction.Submitted);
  Alcotest.(check bool) "coalesced" true (second = Correction.Coalesced);
  Eio.Promise.resolve release_u ();
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
    while
      Testing.in_flight
        ~base_path:"/tmp/context-correction"
        ~keeper_name:"keeper"
    do Eio.Fiber.yield () done);
  let third =
    Correction.submit
      ~base_path:"/tmp/context-correction"
      ~keeper_name:"keeper"
      (fun () -> ())
  in
  Alcotest.(check bool) "released" true (third = Correction.Submitted)
;;

let () =
  Alcotest.run
    "keeper context correction"
    [ ( "correction"
      , [ Alcotest.test_case
            "closed units and protected suffix"
            `Quick
            test_closed_units_advance_and_open_suffix_is_exact
        ; Alcotest.test_case
            "current marker only"
            `Quick
            test_marker_schema_is_current_only
        ; Alcotest.test_case
            "applied checkpoint downstream"
            `Quick
            test_applied_checkpoint_is_downstream_checkpoint
        ; Alcotest.test_case
            "CAS conflict"
            `Quick
            test_cas_conflict_preserves_raw
        ; Alcotest.test_case
            "post durable install wins"
            `Quick
            test_post_durable_auxiliary_is_applied
        ; Alcotest.test_case
            "invalid output preserves marker"
            `Quick
            test_empty_semantic_output_does_not_advance_marker
        ; Alcotest.test_case
            "executor never inline"
            `Quick
            test_executor_never_runs_inline
        ; Alcotest.test_case
            "executor coalesces and releases"
            `Quick
            test_executor_coalesces_and_releases
        ] )
    ]
;;
