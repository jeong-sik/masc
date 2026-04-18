(** Tests for Types module *)

open Types

let test_agent_status_roundtrip () =
  let statuses = [Active; Busy; Listening; Inactive] in
  List.iter (fun status ->
    let json = agent_status_to_yojson status in
    match agent_status_of_yojson json with
    | Ok parsed -> Alcotest.(check string) "roundtrip" (show_agent_status status) (show_agent_status parsed)
    | Error e -> Alcotest.fail e
  ) statuses

let test_task_status_todo () =
  let status = Todo in
  let json = task_status_to_yojson status in
  match task_status_of_yojson json with
  | Ok Todo -> ()  (* Pattern match to verify it's Todo *)
  | Ok _ -> Alcotest.fail "expected Todo"
  | Error e -> Alcotest.fail e

let test_task_status_claimed () =
  let status = Claimed { assignee = "claude"; claimed_at = "2024-01-01T00:00:00Z" } in
  let json = task_status_to_yojson status in
  match task_status_of_yojson json with
  | Ok (Claimed { assignee; _ }) -> Alcotest.(check string) "assignee" "claude" assignee
  | Ok _ -> Alcotest.fail "wrong variant"
  | Error e -> Alcotest.fail e

let test_task_status_done () =
  let status = Done { assignee = "gemini"; completed_at = "2024-01-01T00:00:00Z"; notes = Some "test" } in
  let json = task_status_to_yojson status in
  match task_status_of_yojson json with
  | Ok (Done { notes = Some n; _ }) -> Alcotest.(check string) "notes" "test" n
  | Ok _ -> Alcotest.fail "wrong variant or missing notes"
  | Error e -> Alcotest.fail e

let test_message_roundtrip () =
  let msg = {
    seq = 1;
    from_agent = "claude";
    msg_type = "broadcast";
    content = "Hello @gemini!";
    mention = Some "gemini";
    timestamp = "2024-01-01T00:00:00Z";
    trace_context = None;
  } in
  let json = message_to_yojson msg in
  match message_of_yojson json with
  | Ok parsed ->
      Alcotest.(check int) "seq" 1 parsed.seq;
      Alcotest.(check string) "from" "claude" parsed.from_agent;
      Alcotest.(check (option string)) "mention" (Some "gemini") parsed.mention
  | Error e -> Alcotest.fail e

let test_parse_iso8601_epoch_utc () =
  let parsed = parse_iso8601 "1970-01-01T00:00:00Z" in
  Alcotest.(check (float 0.001)) "utc epoch" 0.0 parsed

(* Issue #8312: lenient parser must accept target-state aliases without
   widening canonical Variant SSOT. *)
let action_to_canonical = function
  | Claim -> "claim"
  | Start -> "start"
  | Done_action -> "done"
  | Cancel -> "cancel"
  | Release -> "release"
  | Submit_for_verification -> "submit_for_verification"
  | Approve_verification -> "approve"
  | Reject_verification -> "reject"

let check_lenient input expected =
  match task_action_of_string_lenient input with
  | Ok a -> Alcotest.(check string) input expected (action_to_canonical a)
  | Error e -> Alcotest.failf "expected %s for %s, got error: %s" expected input e

let test_action_alias_claimed () = check_lenient "claimed" "claim"
let test_action_alias_todo () = check_lenient "todo" "release"
let test_action_alias_in_progress () = check_lenient "in_progress" "start"
let test_action_alias_completed () = check_lenient "completed" "done"
let test_action_alias_cancelled () = check_lenient "cancelled" "cancel"
let test_action_canonical_still_works () = check_lenient "claim" "claim"
let test_action_case_insensitive () = check_lenient "CLAIMED" "claim"

let test_action_unknown_still_rejected () =
  match task_action_of_string_lenient "definitely-not-an-action" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "lenient parser must reject genuine garbage"

(* Strict parser must NOT have grown alias support — preserves SSOT
   for places that document only canonical vocabulary. *)
let test_strict_parser_unchanged () =
  match task_action_of_string "claimed" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "strict parser must reject aliases; lenient owns aliases"

(* Issue #8372: schema enums for [agent_status] used to be hand-rolled.
   The witness function ensures every variant produces a string that
   appears in [valid_agent_status_strings]. A 5th constructor forces
   the witness match to fail compilation. *)
let test_agent_status_witness_in_enum () =
  let witness s =
    let actual = agent_status_to_string s in
    if not (List.mem actual valid_agent_status_strings) then
      Alcotest.failf "agent_status_to_string %S not in valid_agent_status_strings" actual
  in
  witness Active;
  witness Busy;
  witness Listening;
  witness Inactive;
  Alcotest.(check int) "count" 4 (List.length valid_agent_status_strings)

let test_agent_status_strings_complete () =
  List.iter (fun expected ->
    Alcotest.(check bool) (Printf.sprintf "%s present" expected) true
      (List.mem expected valid_agent_status_strings)
  ) ["active"; "busy"; "listening"; "inactive"]

(* Issue #8354: schema enums must stay in sync with the Variant SSOT.
   The witness function below uses an exhaustive [match]: adding a 7th
   constructor to [task_status] forces this match to fail to compile. *)
let test_status_strings_match_variant_witness () =
  let witness s =
    let actual = task_status_to_string s in
    if not (List.mem actual valid_task_status_strings) then
      Alcotest.failf "task_status_to_string %S not in valid_task_status_strings" actual
  in
  witness Todo;
  witness (Claimed { assignee = "a"; claimed_at = "t" });
  witness (InProgress { assignee = "a"; started_at = "t" });
  witness (AwaitingVerification {
    assignee = "a"; submitted_at = "t"; verification_id = "v";
    required_verifier_role = Reviewer; deadline = None });
  witness (Done { assignee = "a"; completed_at = "t"; notes = None });
  witness (Cancelled { cancelled_by = "a"; cancelled_at = "t"; reason = None });
  Alcotest.(check int) "count" 6 (List.length valid_task_status_strings)

let test_awaiting_verification_in_enum () =
  Alcotest.(check bool) "awaiting_verification present"
    true (List.mem "awaiting_verification" valid_task_status_strings)

let test_actions_enum_has_verification_actions () =
  let must = ["submit_for_verification"; "approve"; "reject"] in
  List.iter (fun s ->
    Alcotest.(check bool) (Printf.sprintf "%s present" s) true
      (List.mem s valid_task_action_strings)
  ) must

(* Regression for live-basepath decode spike (2026-04-18): backlog.json
   written without the [last_updated]/[version] metadata fields used to
   fail parsing with [Type_error("Expected string, got null")], forcing
   every reader onto the empty fallback and blocking the stale-claims
   GC for hours. *)
let test_backlog_parse_missing_metadata_fields () =
  let json =
    `Assoc [
      ("tasks", `List [
         `Assoc [
           ("id", `String "t-1");
           ("title", `String "demo");
           ("description", `String "");
           ("files", `List []);
           ("created_at", `String "2026-04-18T10:00:00Z");
           ("status", `String "todo");
         ];
      ]);
    ]
  in
  match backlog_of_yojson json with
  | Ok b ->
    Alcotest.(check int) "one task parsed" 1 (List.length b.tasks);
    Alcotest.(check string) "last_updated defaulted to empty" "" b.last_updated;
    Alcotest.(check int) "version defaulted to 1" 1 b.version
  | Error msg ->
    Alcotest.fail ("expected Ok, got Error: " ^ msg)

let test_backlog_parse_null_metadata_fields () =
  let json =
    `Assoc [
      ("tasks", `List []);
      ("last_updated", `Null);
      ("version", `Null);
    ]
  in
  match backlog_of_yojson json with
  | Ok b ->
    Alcotest.(check string) "null last_updated -> empty" "" b.last_updated;
    Alcotest.(check int) "null version -> 1" 1 b.version
  | Error msg ->
    Alcotest.fail ("expected Ok with null metadata, got Error: " ^ msg)

let test_backlog_parse_live_shape_with_null_optional_nested_fields () =
  let json =
    `Assoc [
      ( "tasks",
        `List
          [
            `Assoc
              [
                ("id", `String "task-live");
                ("title", `String "live payload");
                ("description", `String "");
                ("files", `List []);
                ("created_at", `String "2026-04-18T19:24:00Z");
                ("status", `String "todo");
                ( "handoff_context",
                  `Assoc
                    [
                      ("summary", `String "partial progress");
                      ("reason", `Null);
                      ("next_step", `Null);
                      ("failure_mode", `Null);
                      ("evidence_refs", `List []);
                      ("updated_at", `String "2026-04-18T19:25:00Z");
                      ("updated_by", `String "keeper-janitor-agent");
                    ] );
                ( "contract",
                  `Assoc
                    [
                      ("strict", `Bool false);
                      ("completion_contract", `List []);
                      ("required_evidence", `List []);
                      ("inspect_gate_evidence", `List []);
                      ("verify_gate_evidence", `List []);
                      ( "links",
                        `Assoc
                          [
                            ("operation_id", `Null);
                            ("session_id", `Null);
                            ("autoresearch_loop_id", `Null);
                          ] );
                    ] );
              ];
          ] );
    ]
  in
  match backlog_of_yojson json with
  | Error msg ->
      Alcotest.fail
        ("expected Ok for live-shaped backlog payload, got Error: " ^ msg)
  | Ok backlog ->
      Alcotest.(check int) "one live-shaped task parsed" 1
        (List.length backlog.tasks);
      let task = List.hd backlog.tasks in
      Alcotest.(check string) "last_updated defaulted to empty for live payload"
        "" backlog.last_updated;
      Alcotest.(check int) "version defaulted to 1 for live payload" 1
        backlog.version;
      (match task.handoff_context with
       | None -> Alcotest.fail "expected handoff_context"
       | Some handoff ->
           Alcotest.(check (option string)) "reason null -> None" None
             handoff.reason;
           Alcotest.(check (option string)) "next_step null -> None" None
             handoff.next_step;
           Alcotest.(check (option string)) "failure_mode null -> None" None
             handoff.failure_mode);
      (match task.contract with
       | None -> Alcotest.fail "expected contract"
       | Some contract ->
           Alcotest.(check (option string)) "operation_id null -> None" None
             contract.links.operation_id;
           Alcotest.(check (option string)) "session_id null -> None" None
             contract.links.session_id;
           Alcotest.(check (option string))
             "autoresearch_loop_id null -> None" None
             contract.links.autoresearch_loop_id)

let () =
  Alcotest.run "Types" [
    "agent_status", [
      Alcotest.test_case "roundtrip" `Quick test_agent_status_roundtrip;
    ];
    "task_status", [
      Alcotest.test_case "todo" `Quick test_task_status_todo;
      Alcotest.test_case "claimed" `Quick test_task_status_claimed;
      Alcotest.test_case "done" `Quick test_task_status_done;
    ];
    "message", [
      Alcotest.test_case "roundtrip" `Quick test_message_roundtrip;
    ];
    "timestamp", [
      Alcotest.test_case "parse utc epoch" `Quick test_parse_iso8601_epoch_utc;
    ];
    "backlog_lenient_parse", [
      Alcotest.test_case "missing last_updated/version -> defaults" `Quick
        test_backlog_parse_missing_metadata_fields;
      Alcotest.test_case "null last_updated/version -> defaults" `Quick
        test_backlog_parse_null_metadata_fields;
      Alcotest.test_case "live shape with nested null optionals" `Quick
        test_backlog_parse_live_shape_with_null_optional_nested_fields;
    ];
    "task_action_lenient", [
      Alcotest.test_case "alias claimed -> claim" `Quick test_action_alias_claimed;
      Alcotest.test_case "alias todo -> release" `Quick test_action_alias_todo;
      Alcotest.test_case "alias in_progress -> start" `Quick test_action_alias_in_progress;
      Alcotest.test_case "alias completed -> done" `Quick test_action_alias_completed;
      Alcotest.test_case "alias cancelled -> cancel" `Quick test_action_alias_cancelled;
      Alcotest.test_case "canonical claim still works" `Quick test_action_canonical_still_works;
      Alcotest.test_case "case insensitive" `Quick test_action_case_insensitive;
      Alcotest.test_case "garbage still rejected" `Quick test_action_unknown_still_rejected;
      Alcotest.test_case "strict parser ssot preserved" `Quick test_strict_parser_unchanged;
    ];
    "agent_status_ssot", [
      Alcotest.test_case "witness covers all variants" `Quick test_agent_status_witness_in_enum;
      Alcotest.test_case "all 4 strings present" `Quick test_agent_status_strings_complete;
    ];
    "variant_ssot", [
      Alcotest.test_case "status strings match witness" `Quick test_status_strings_match_variant_witness;
      Alcotest.test_case "awaiting_verification in enum" `Quick test_awaiting_verification_in_enum;
      Alcotest.test_case "actions enum has verification actions" `Quick test_actions_enum_has_verification_actions;
    ];
    "agent_role_ssot", [
      Alcotest.test_case "witness covers all variants" `Quick (fun () ->
        let open Types_auth in
        let witness s =
          let actual = agent_role_to_string s in
          if not (List.mem actual valid_agent_role_strings) then
            Alcotest.failf "agent_role_to_string %S not in valid_agent_role_strings" actual
        in
        witness Reader; witness Worker; witness Admin;
        Alcotest.(check int) "count" 3 (List.length valid_agent_role_strings));
      Alcotest.test_case "all 3 strings present" `Quick (fun () ->
        let open Types_auth in
        List.iter (fun expected ->
          Alcotest.(check bool) (Printf.sprintf "%s present" expected) true
            (List.mem expected valid_agent_role_strings)
        ) ["reader"; "worker"; "admin"]);
    ];
    "tool_preset_ssot", [
      (* Issue #8430: witness covers all 7 variants — adding an 8th
         constructor will fail to compile here AND in
         tool_preset_to_string. *)
      Alcotest.test_case "witness covers all variants" `Quick (fun () ->
        let open Masc_mcp.Keeper_types in
        let witness s =
          let actual = tool_preset_to_string s in
          if not (List.mem actual valid_tool_preset_strings) then
            Alcotest.failf "tool_preset_to_string %S not in valid_tool_preset_strings" actual
        in
        witness Minimal; witness Social; witness Messaging; witness Coding;
        witness Research; witness Delivery; witness Full;
        Alcotest.(check int) "count" 7 (List.length valid_tool_preset_strings));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        (* Keeper_schema.tool_preset_enum_strings is a hand-mirrored copy
           of Keeper_types.valid_tool_preset_strings (cycle-avoidance).
           If they ever diverge this test fails and a silently-dropped
           schema enum constructor is caught immediately. *)
        Alcotest.(check (list string)) "schema mirror == variant SSOT"
          Masc_mcp.Keeper_types.valid_tool_preset_strings
          Masc_mcp.Keeper_schema.tool_preset_enum_strings);
      Alcotest.test_case "Social and Delivery present" `Quick (fun () ->
        let open Masc_mcp.Keeper_types in
        Alcotest.(check bool) "social present" true
          (List.mem "social" valid_tool_preset_strings);
        Alcotest.(check bool) "delivery present" true
          (List.mem "delivery" valid_tool_preset_strings));
    ];
    "operator_view_ssot", [
      (* Issue #8471: tool_operator view enum was missing 'sessions'
         while parser+impl supported all 5. This test catches schema
         drift by deriving the asserted list from the Variant SSOT. *)
      Alcotest.test_case "witness covers all 5 variants" `Quick (fun () ->
        let open Masc_mcp.Operator_control_snapshot in
        let witness v =
          let actual = snapshot_view_to_string v in
          if not (List.mem actual valid_snapshot_view_strings) then
            Alcotest.failf "snapshot_view_to_string %S not in valid_snapshot_view_strings" actual
        in
        witness Summary; witness Sessions; witness Keepers;
        witness Messages; witness Full;
        Alcotest.(check int) "count" 5 (List.length valid_snapshot_view_strings));
      Alcotest.test_case "all 5 strings present" `Quick (fun () ->
        let strs = Masc_mcp.Operator_control_snapshot.valid_snapshot_view_strings in
        List.iter (fun expected ->
          Alcotest.(check bool) (Printf.sprintf "%s present" expected) true
            (List.mem expected strs)
        ) ["summary"; "sessions"; "keepers"; "messages"; "full"]);
      Alcotest.test_case "of_string_opt rejects garbage" `Quick (fun () ->
        Alcotest.(check bool) "garbage" true
          (Masc_mcp.Operator_control_snapshot.snapshot_view_of_string_opt
             "definitely-not-a-view" = None);
        Alcotest.(check bool) "sessions accepted" true
          (Masc_mcp.Operator_control_snapshot.snapshot_view_of_string_opt
             "sessions" <> None));
    ];
    "keeper_profile_enum_ssot", [
      (* Issue #8467: witness exhaustiveness for [Keeper_types_profile]
         nullary variants — adding a new constructor fails compilation
         in the matching [*_to_string] function. *)
      Alcotest.test_case "sandbox_profile witness covers both variants" `Quick (fun () ->
        let open Masc_mcp.Keeper_types_profile in
        let witness s =
          let actual = sandbox_profile_to_string s in
          if not (List.mem actual valid_sandbox_profile_strings) then
            Alcotest.failf "sandbox_profile_to_string %S not in valid_sandbox_profile_strings" actual
        in
        witness Legacy_local; witness Docker_hardened;
        Alcotest.(check int) "count" 2 (List.length valid_sandbox_profile_strings));
      Alcotest.test_case "network_mode witness covers both variants" `Quick (fun () ->
        let open Masc_mcp.Keeper_types_profile in
        let witness s =
          let actual = network_mode_to_string s in
          if not (List.mem actual valid_network_mode_strings) then
            Alcotest.failf "network_mode_to_string %S not in valid_network_mode_strings" actual
        in
        witness Network_none; witness Network_inherit;
        Alcotest.(check int) "count" 2 (List.length valid_network_mode_strings));
      Alcotest.test_case "shared_memory_scope witness covers both variants" `Quick (fun () ->
        let open Masc_mcp.Keeper_types_profile in
        let witness s =
          let actual = shared_memory_scope_to_string s in
          if not (List.mem actual valid_shared_memory_scope_strings) then
            Alcotest.failf "shared_memory_scope_to_string %S not in valid_shared_memory_scope_strings" actual
        in
        witness Shared_memory_disabled; witness Shared_memory_room;
        Alcotest.(check int) "count" 2 (List.length valid_shared_memory_scope_strings));
      Alcotest.test_case "schema mirrors stay in sync" `Quick (fun () ->
        (* Cycle-avoidance: Keeper_schema cannot depend on
           Keeper_types_profile directly, so it hand-mirrors the SSOT.
           This test catches drift before a new constructor silently
           drops from the JSON Schema. *)
        Alcotest.(check (list string)) "sandbox_profile mirror"
          Masc_mcp.Keeper_types_profile.valid_sandbox_profile_strings
          Masc_mcp.Keeper_schema.sandbox_profile_enum_strings;
        Alcotest.(check (list string)) "network_mode mirror"
          Masc_mcp.Keeper_types_profile.valid_network_mode_strings
          Masc_mcp.Keeper_schema.network_mode_enum_strings;
        Alcotest.(check (list string)) "shared_memory_scope mirror"
          Masc_mcp.Keeper_types_profile.valid_shared_memory_scope_strings
          Masc_mcp.Keeper_schema.shared_memory_scope_enum_strings);
    ];
    "verdict_ssot", [
      (* Issue #8436: payload-bearing variants need a witness function
         (not List.map verdict_to_string list, which would emit "WARN: "
         etc). Adding a new constructor will fail compilation in the
         witness inside the impl. *)
      Alcotest.test_case "verifier_core covers Pass/Warn/Fail" `Quick (fun () ->
        let open Masc_mcp.Verifier_core in
        let witness v =
          let n = verdict_constructor_name v in
          if not (List.mem n valid_verdict_strings) then
            Alcotest.failf "verdict_constructor_name %S not in valid_verdict_strings" n
        in
        witness Pass;
        witness (Warn "x");
        witness (Fail "y");
        Alcotest.(check int) "count" 3 (List.length valid_verdict_strings));
      Alcotest.test_case "anti_rationalization covers Approve/Reject" `Quick (fun () ->
        let open Masc_mcp.Anti_rationalization in
        let witness v =
          let n = verdict_constructor_name v in
          if not (List.mem n valid_verdict_strings) then
            Alcotest.failf "verdict_constructor_name %S not in valid_verdict_strings" n
        in
        witness Approve;
        witness (Reject "x");
        Alcotest.(check int) "count" 2 (List.length valid_verdict_strings));
    ];
  ]
