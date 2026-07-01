open Alcotest
open Masc

let temp_dir () =
  let dir = Filename.temp_file "test_audit_log_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let assoc_key_count key = function
  | `Assoc fields ->
      List.length (List.filter (fun (field, _) -> String.equal field key) fields)
  | _ -> 0

let test_system_internal_details_deduplicate_canonical_keys () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      Audit_log.log_system_internal_tool_call config ~agent_id:"codex"
        ~tool_name:"masc_status" ~success:true ~error_msg:None
        ~details:
          (`Assoc
             [
               ("surface", `String "overridden");
               ("tool_name", `String "wrong_name");
               ("source", `String "unit_test");
             ])
        ();
      let entry =
        match Audit_log.read_entries ~n:10 config with
        | [ entry ] -> entry
        | _ -> fail "expected one audit entry"
      in
      check string "canonical surface wins" "system_internal"
        Yojson.Safe.Util.(entry.details |> member "surface" |> to_string);
      check string "canonical tool name wins" "masc_status"
        Yojson.Safe.Util.(entry.details |> member "tool_name" |> to_string);
      check int "surface appears once" 1 (assoc_key_count "surface" entry.details);
      check int "tool_name appears once" 1
        (assoc_key_count "tool_name" entry.details);
      check string "keeps non-canonical fields" "unit_test"
        Yojson.Safe.Util.(entry.details |> member "source" |> to_string))

let entry ~timestamp ~agent_id ~action ~outcome =
  {
    Audit_log.timestamp;
    agent_id;
    action;
    workspace_id = None;
    details = `Null;
    outcome;
    cost_estimate = None;
    token_count = None;
    trace_id = None;
  }

let test_audit_events_filter_severity_before_paging () =
  let entries =
    [
      entry ~timestamp:1.0 ~agent_id:"keeper-a" ~action:Audit_log.AuthFailure
        ~outcome:(Audit_log.Failure "bad token");
      entry ~timestamp:2.0 ~agent_id:"keeper-b" ~action:Audit_log.AuthSuccess
        ~outcome:Audit_log.Success;
      entry ~timestamp:3.0 ~agent_id:"keeper-c" ~action:Audit_log.AuthSuccess
        ~outcome:Audit_log.Success;
    ]
  in
  let json =
    Audit_log.audit_events_response_json ~severity:"error" ~limit:2 entries
  in
  let open Yojson.Safe.Util in
  check int "one error survives paging" 1 (json |> member "count" |> to_int);
  let rows = json |> member "entries" |> to_list in
  check int "one row" 1 (List.length rows);
  let row = List.hd rows in
  check string "older error retained" "keeper-a" (row |> member "actor" |> to_string);
  check string "severity" "error" (row |> member "severity" |> to_string)

(* ── Codec round-trip tests ────────────────────────────────────────── *)

let action_roundtrip label action expected_wire =
  let wire = Audit_log.action_to_string action in
  check string (label ^ " encode") expected_wire wire;
  let decoded = Audit_log.string_to_action wire in
  (* Compare via re-encoding because [action] has no [equal] deriving *)
  check string (label ^ " round-trip") wire (Audit_log.action_to_string decoded)

let test_codec_roundtrip_simple_actions () =
  action_roundtrip "ClaimTask" Audit_log.ClaimTask "claim_task";
  action_roundtrip "StartTask" Audit_log.StartTask "start_task";
  action_roundtrip "DoneTask" Audit_log.DoneTask "done_task";
  action_roundtrip "CancelTask" Audit_log.CancelTask "cancel_task";
  action_roundtrip "ReleaseTask" Audit_log.ReleaseTask "release_task";
  action_roundtrip "Broadcast" Audit_log.Broadcast "broadcast";
  action_roundtrip "Suspend" Audit_log.Suspend "suspend";
  action_roundtrip "AuthSuccess" Audit_log.AuthSuccess "auth_success";
  action_roundtrip "AuthFailure" Audit_log.AuthFailure "auth_failure";
  action_roundtrip "CircuitOpen" Audit_log.CircuitOpen "circuit_open";
  action_roundtrip "CircuitClose" Audit_log.CircuitClose "circuit_close";
  action_roundtrip "SearchRefinement" Audit_log.SearchRefinement "search_refinement";
  action_roundtrip "RuntimeConfigWrite" Audit_log.RuntimeConfigWrite
    "runtime_config_write"

let test_codec_roundtrip_parametric_actions () =
  action_roundtrip "ToolCall"
    (Audit_log.ToolCall "masc_status") "tool_call:masc_status";
  action_roundtrip "ToolCall:colon-in-name"
    (Audit_log.ToolCall "provider:model") "tool_call:provider:model";
  action_roundtrip "GovernanceDecision:allow"
    (Audit_log.GovernanceDecision Audit_log.Governance_allow)
    "governance_decision:allow";
  action_roundtrip "GovernanceDecision:deny"
    (Audit_log.GovernanceDecision Audit_log.Governance_deny)
    "governance_decision:deny";
  action_roundtrip "Custom"
    (Audit_log.Custom "my_event") "custom:my_event";
  action_roundtrip "Custom:colon-in-name"
    (Audit_log.Custom "foo:bar") "custom:foo:bar"

let check_unknown label expected = function
  | Audit_log.Unknown raw -> check string label expected raw
  | action ->
      failf "%s decoded as %s" label (Audit_log.action_to_string action)

let test_codec_unknown_preserves_wire () =
  let decoded = Audit_log.string_to_action "future_action" in
  check_unknown "unknown bare" "future_action" decoded;
  check string "unknown bare re-encoded" "future_action"
    (Audit_log.action_to_string decoded);
  let decoded_tagged = Audit_log.string_to_action "unknown_tag:payload" in
  check_unknown "unknown tagged" "unknown_tag:payload" decoded_tagged;
  check string "unknown tagged re-encoded" "unknown_tag:payload"
    (Audit_log.action_to_string decoded_tagged)

let test_codec_empty_payload () =
  (* Edge: colon at end means empty payload *)
  let decoded = Audit_log.string_to_action "custom:" in
  check string "empty Custom payload" "custom:" (Audit_log.action_to_string decoded);
  let decoded_tc = Audit_log.string_to_action "tool_call:" in
  check string "empty ToolCall payload" "tool_call:" (Audit_log.action_to_string decoded_tc)

(* RFC-0273 §3.3 — the dashboard runtime.toml write logs a RuntimeConfigWrite
   action. Lock the operator-facing event projection: kind/summary/target must
   surface the config path (not the body, which can carry provider secrets).
   Severity must be "warn" even on success: a runtime.toml write rewrites global
   keeper routing (RFC-0273 §3.2, highest-risk surface), so it must rank above
   routine info events in a severity-filtered audit scan. Without this assertion
   a wildcard refactor in [audit_severity] could silently demote it to "info". *)
let test_runtime_config_write_event_projection () =
  let entry : Audit_log.audit_entry =
    {
      timestamp = 1_700_000_000.0;
      agent_id = "operator";
      action = Audit_log.RuntimeConfigWrite;
      workspace_id = None;
      details =
        `Assoc
          [
            ("path", `String "/x/config/runtime.toml");
            ("bytes", `Int 100);
            ("lines", `Int 5);
          ];
      outcome = Audit_log.Success;
      cost_estimate = None;
      token_count = None;
      trace_id = None;
    }
  in
  let json = Audit_log.audit_event_json entry in
  let field key =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`String v) -> v
        | _ -> failf "missing string field %s" key)
    | _ -> failf "audit_event_json is not an object"
  in
  check string "kind" "runtime_config_write" (field "kind");
  check string "summary" "runtime.toml updated: /x/config/runtime.toml"
    (field "summary");
  check string "target" "/x/config/runtime.toml" (field "target");
  check string "severity" "warn" (field "severity")

let test_runtime_config_write_assignment_projection () =
  let entry : Audit_log.audit_entry =
    {
      timestamp = 1_700_000_001.0;
      agent_id = "dashboard";
      action = Audit_log.RuntimeConfigWrite;
      workspace_id = None;
      details =
        `Assoc
          [
            ("path", `String "/x/config/runtime.toml");
            ("operation", `String "assignment");
            ("keeper_name", `String "verifier");
            ("runtime_id", `String "ollama_cloud.deepseek-v4-flash");
            ("cleared", `Bool false);
            ("bytes", `Int 18783);
            ("lines", `Int 464);
          ];
      outcome = Audit_log.Success;
      cost_estimate = None;
      token_count = None;
      trace_id = None;
    }
  in
  let json = Audit_log.audit_event_json entry in
  let field key =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`String v) -> v
        | _ -> failf "missing string field %s" key)
    | _ -> failf "audit_event_json is not an object"
  in
  check string "summary"
    "runtime.toml assignment updated: verifier -> ollama_cloud.deepseek-v4-flash"
    (field "summary");
  check string "target" "/x/config/runtime.toml" (field "target");
  check string "severity" "warn" (field "severity")

let test_runtime_config_write_routing_list_projection () =
  let entry : Audit_log.audit_entry =
    {
      timestamp = 1_700_000_002.0;
      agent_id = "dashboard";
      action = Audit_log.RuntimeConfigWrite;
      workspace_id = None;
      details =
        `Assoc
          [
            ("path", `String "/x/config/runtime.toml");
            ("operation", `String "routing");
            ("lane", `String "media_failover");
            ("runtime_ids", `List [ `String "rt-a"; `String "rt-b" ]);
            ("cleared", `Bool false);
            ("bytes", `Int 18783);
            ("lines", `Int 464);
          ];
      outcome = Audit_log.Success;
      cost_estimate = None;
      token_count = None;
      trace_id = None;
    }
  in
  let json = Audit_log.audit_event_json entry in
  let field key =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`String v) -> v
        | _ -> failf "missing string field %s" key)
    | _ -> failf "audit_event_json is not an object"
  in
  check string "summary"
    "runtime.toml routing updated: media_failover -> [rt-a, rt-b]"
    (field "summary");
  check string "target" "/x/config/runtime.toml" (field "target");
  check string "severity" "warn" (field "severity")

let () =
  run "Audit_log"
    [
      ( "audit_log",
        [
          test_case "system_internal details deduplicate canonical keys" `Quick
            test_system_internal_details_deduplicate_canonical_keys;
          test_case "audit event severity filters before paging" `Quick
            test_audit_events_filter_severity_before_paging;
        ] );
      ( "codec_roundtrip",
        [
          test_case "simple actions round-trip" `Quick
            test_codec_roundtrip_simple_actions;
          test_case "parametric actions round-trip" `Quick
            test_codec_roundtrip_parametric_actions;
          test_case "unknown preserves wire" `Quick
            test_codec_unknown_preserves_wire;
          test_case "empty payload edge case" `Quick
            test_codec_empty_payload;
          test_case "runtime_config_write event projection" `Quick
            test_runtime_config_write_event_projection;
          test_case "runtime_config_write assignment projection" `Quick
            test_runtime_config_write_assignment_projection;
          test_case "runtime_config_write routing list projection" `Quick
            test_runtime_config_write_routing_list_projection;
        ] );
    ]
