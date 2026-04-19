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
    "admin_section_ssot", [
      (* Issue #8546: schema advertised [auth; unit_policy] while the
         handler only implemented `auth`, so LLM clients following the
         schema got `"section must be one of: auth"`. SSOT now lives in
         [Tool_misc_admin] and both the schema (via hand mirror) and the
         dispatcher error message derive from it. *)
      Alcotest.test_case "SSOT contains exactly the implemented sections" `Quick (fun () ->
        Alcotest.(check (list string)) "auth only"
          [ "auth" ]
          Masc_mcp.Tool_misc_admin.valid_admin_section_strings);
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_schemas mirror == SSOT"
          Masc_mcp.Tool_misc_admin.valid_admin_section_strings
          Tool_schemas_misc.admin_section_enum_strings);
    ];
    "config_category_ssot", [
      Alcotest.test_case "producer helper matches all_categories order" `Quick (fun () ->
        Alcotest.(check (list string)) "all_categories -> names"
          (Env_config_snapshot.all_categories () |> List.map fst)
          Env_config_snapshot.valid_config_category_strings);
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "schema mirror"
          Env_config_snapshot.valid_config_category_strings
          Tool_schemas_misc.config_category_enum_strings);
      Alcotest.test_case "missing runtime categories are now published" `Quick (fun () ->
        let categories = Env_config_snapshot.valid_config_category_strings in
        List.iter (fun expected ->
          Alcotest.(check bool) (Printf.sprintf "%s present" expected) true
            (List.mem expected categories)
        ) [
          "keeper_execution"; "keeper_guardrails"; "autonomy";
          "level2"; "economy"; "governance"; "channel";
          "process"; "worker"; "web_search"; "session";
        ]);
    ];
    "fsm_transition_matrix", [
      (* Issue #8474: schema transition matrix had drifted from
         [Coord_task.valid_next_actions_for_status] — submit/approve/
         reject_verification missing. This test asserts every action
         declared valid for any reachable status appears in the
         published [task_fsm_transitions] list. *)
      Alcotest.test_case "every valid action appears in transitions" `Quick (fun () ->
        let reachable_statuses : Types.task_status list = [
          Todo;
          Claimed { assignee = "a"; claimed_at = "" };
          InProgress { assignee = "a"; started_at = "" };
          AwaitingVerification {
            assignee = "a"; submitted_at = "";
            verification_id = "v"; required_verifier_role = Reviewer;
            deadline = None;
          };
          Done { assignee = "a"; completed_at = ""; notes = None };
          Cancelled { cancelled_by = "a"; cancelled_at = ""; reason = None };
        ] in
        let valid_actions =
          reachable_statuses
          |> List.concat_map Coord_task.valid_next_actions_for_status
          |> List.map task_action_to_string
          |> List.sort_uniq String.compare
        in
        let published_actions =
          Masc_mcp.Mcp_server.task_fsm_transitions
          |> List.map (fun (a, _, _, _) -> a)
          |> List.sort_uniq String.compare
        in
        List.iter (fun action ->
          if not (List.mem action published_actions) then
            Alcotest.failf
              "action %S valid per Coord_task.valid_next_actions_for_status \
               but missing from Mcp_server.task_fsm_transitions" action
        ) valid_actions);
      Alcotest.test_case "verifier-FSM transitions present" `Quick (fun () ->
        let actions =
          Masc_mcp.Mcp_server.task_fsm_transitions
          |> List.map (fun (a, _, _, _) -> a)
        in
        List.iter (fun expected ->
          Alcotest.(check bool) (Printf.sprintf "%s present" expected) true
            (List.mem expected actions)
        ) [
          "submit_for_verification";
          "approve";
          "reject";
        ]);
    ];
    "pr_review_event_ssot", [
      (* Issue #8480: introduces [pr_review_event] Variant where 4 sites
         previously hand-validated raw strings. Witness covers all 3
         constructors; mirror sync test asserts [Tool_shard]'s
         hand-mirrored enum stays in lock-step with the SSOT (cycle
         avoidance: Tool_shard -> Keeper_tool_pr_review -> Keeper_alerting
         -> Tool_shard). *)
      Alcotest.test_case "witness covers all 3 variants" `Quick (fun () ->
        let module K = Masc_mcp.Keeper_tool_pr_review in
        let witness e =
          let actual = K.pr_review_event_to_string e in
          if not (List.mem actual K.valid_pr_review_event_strings) then
            Alcotest.failf "pr_review_event_to_string %S not in valid_pr_review_event_strings" actual
        in
        witness K.Comment; witness K.Approve; witness K.Request_changes;
        Alcotest.(check int) "count" 3 (List.length K.valid_pr_review_event_strings));
      Alcotest.test_case "of_string_opt accepts canonical and case-insensitive" `Quick (fun () ->
        let module K = Masc_mcp.Keeper_tool_pr_review in
        Alcotest.(check bool) "COMMENT" true (K.pr_review_event_of_string_opt "COMMENT" <> None);
        Alcotest.(check bool) "approve (lower)" true (K.pr_review_event_of_string_opt "approve" <> None);
        Alcotest.(check bool) "  request_changes  " true
          (K.pr_review_event_of_string_opt "  request_changes  " <> None);
        Alcotest.(check bool) "garbage rejected" true
          (K.pr_review_event_of_string_opt "MERGE" = None));
      Alcotest.test_case "gh flag mapping" `Quick (fun () ->
        let module K = Masc_mcp.Keeper_tool_pr_review in
        Alcotest.(check string) "comment" "--comment" (K.pr_review_event_to_gh_flag K.Comment);
        Alcotest.(check string) "approve" "--approve" (K.pr_review_event_to_gh_flag K.Approve);
        Alcotest.(check string) "request" "--request-changes"
          (K.pr_review_event_to_gh_flag K.Request_changes));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_shard mirror == SSOT"
          Masc_mcp.Keeper_tool_pr_review.valid_pr_review_event_strings
          Masc_mcp.Tool_shard.pr_review_event_enum_strings);
    ];
    "memory_search_source_ssot", [
      (* Issue #8484: introduces [memory_search_source] Variant where 3
         sites previously hand-validated raw strings + relied on a silent
         _ -> memory wildcard fallback. Witness covers all 3 constructors;
         mirror sync test asserts [Tool_shard]'s hand-mirrored enum stays
         in lock-step with the SSOT (cycle-avoidance pattern from #8467/
         #8480). *)
      Alcotest.test_case "witness covers all 3 variants" `Quick (fun () ->
        let module M = Masc_mcp.Keeper_exec_memory in
        let witness s =
          let actual = M.memory_search_source_to_string s in
          if not (List.mem actual M.valid_memory_search_source_strings) then
            Alcotest.failf "memory_search_source_to_string %S not in valid_memory_search_source_strings" actual
        in
        witness M.Memory; witness M.History; witness M.All;
        Alcotest.(check int) "count" 3 (List.length M.valid_memory_search_source_strings));
      Alcotest.test_case "of_string_opt sound partial" `Quick (fun () ->
        let module M = Masc_mcp.Keeper_exec_memory in
        Alcotest.(check bool) "memory" true (M.memory_search_source_of_string_opt "memory" <> None);
        Alcotest.(check bool) "HISTORY (case)" true (M.memory_search_source_of_string_opt "HISTORY" <> None);
        Alcotest.(check bool) "  all  (trim)" true
          (M.memory_search_source_of_string_opt "  all  " <> None);
        Alcotest.(check bool) "garbage rejected" true
          (M.memory_search_source_of_string_opt "definitely-not-a-source" = None));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_shard mirror == SSOT"
          Masc_mcp.Keeper_exec_memory.valid_memory_search_source_strings
          Masc_mcp.Tool_shard.memory_search_source_enum_strings);
    ];
    "memory_kind_ssot", [
      (* Issue #8527: schema enum for [keeper_memory_search.kind] dropped
         [long_term] even though [keeper_memory_bank] actively writes
         long_term rows. Same cycle-avoidance pattern as #8484 — hand
         mirror in Tool_shard, sync-test the mirror against the SSOT. *)
      Alcotest.test_case "SSOT includes every kind_caps entry" `Quick (fun () ->
        let caps = Masc_mcp.Keeper_memory_policy.kind_caps () in
        Alcotest.(check (list string)) "derived == kind_caps keys"
          (List.map fst caps)
          Masc_mcp.Keeper_memory_policy.valid_memory_kind_strings);
      Alcotest.test_case "long_term is in SSOT" `Quick (fun () ->
        Alcotest.(check bool) "long_term present" true
          (List.mem "long_term"
             Masc_mcp.Keeper_memory_policy.valid_memory_kind_strings));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_shard mirror == SSOT"
          Masc_mcp.Keeper_memory_policy.valid_memory_kind_strings
          Masc_mcp.Tool_shard.memory_kind_enum_strings);
    ];
    "fs_write_mode_ssot", [
      (* Issue #8490: introduces [fs_write_mode] Variant where 5 sites
         previously hand-validated raw strings + relied on an
         empty-string-as-overwrite back-compat. Witness covers both
         constructors; mirror sync test asserts [Tool_shard]'s
         hand-mirrored enum stays in lock-step with the SSOT
         (cycle-avoidance pattern from #8467/#8480/#8484). *)
      Alcotest.test_case "witness covers both variants" `Quick (fun () ->
        let module F = Masc_mcp.Keeper_exec_fs in
        let witness m =
          let actual = F.fs_write_mode_to_string m in
          if not (List.mem actual F.valid_fs_write_mode_strings) then
            Alcotest.failf "fs_write_mode_to_string %S not in valid_fs_write_mode_strings" actual
        in
        witness F.Overwrite; witness F.Append;
        Alcotest.(check int) "count" 2 (List.length F.valid_fs_write_mode_strings));
      Alcotest.test_case "of_string_opt sound partial + empty back-compat" `Quick (fun () ->
        let module F = Masc_mcp.Keeper_exec_fs in
        Alcotest.(check bool) "overwrite" true (F.fs_write_mode_of_string_opt "overwrite" <> None);
        Alcotest.(check bool) "APPEND (case)" true (F.fs_write_mode_of_string_opt "APPEND" <> None);
        Alcotest.(check bool) "  empty -> Overwrite (back-compat)" true
          (F.fs_write_mode_of_string_opt "" = Some F.Overwrite);
        Alcotest.(check bool) "whitespace-only -> Overwrite" true
          (F.fs_write_mode_of_string_opt "   " = Some F.Overwrite);
        Alcotest.(check bool) "garbage rejected" true
          (F.fs_write_mode_of_string_opt "definitely-not-a-mode" = None));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_shard mirror == SSOT"
          Masc_mcp.Keeper_exec_fs.valid_fs_write_mode_strings
          Masc_mcp.Tool_shard.fs_write_mode_enum_strings);
    ];
    "vote_direction_ssot", [
      (* Issue #8506: Variant + to_string already existed (board_types/
         board_votes), but 4 inline matches in server_bootstrap_loops.ml
         re-implemented the same thing AND tool_shard.ml hardcoded the
         schema enum. This test asserts the [Tool_shard] mirror stays
         in sync with the SSOT and the witness covers both Variants. *)
      Alcotest.test_case "witness covers both variants" `Quick (fun () ->
        let module B = Masc_mcp.Board_votes in
        let witness d =
          let actual = B.vote_direction_to_string d in
          if not (List.mem actual B.valid_vote_direction_strings) then
            Alcotest.failf "vote_direction_to_string %S not in valid_vote_direction_strings" actual
        in
        witness Masc_mcp.Board_votes.Up; witness Masc_mcp.Board_votes.Down;
        Alcotest.(check int) "count" 2 (List.length B.valid_vote_direction_strings));
      Alcotest.test_case "of_string_opt sound partial + back-compat" `Quick (fun () ->
        let module B = Masc_mcp.Board_votes in
        Alcotest.(check bool) "up" true (B.vote_direction_of_string_opt "up" <> None);
        Alcotest.(check bool) "DOWN (case)" true (B.vote_direction_of_string_opt "DOWN" <> None);
        Alcotest.(check bool) "  empty -> Up back-compat" true
          (B.vote_direction_of_string_opt "" = Some Masc_mcp.Board_votes.Up);
        Alcotest.(check bool) "garbage rejected" true
          (B.vote_direction_of_string_opt "left" = None));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_shard mirror == SSOT"
          Masc_mcp.Board_votes.valid_vote_direction_strings
          Masc_mcp.Tool_shard.vote_direction_enum_strings);
    ];
    "agent_tool_variants_ssot", [
      (* Issue #8501: introduces [agent_card_action] and
         [collaboration_format] Variants where 4 sites previously
         hand-validated raw strings. Same shape as #8480/#8484/#8490
         mirror+sync pattern. *)
      Alcotest.test_case "agent_card_action witness covers both variants" `Quick (fun () ->
        let module T = Masc_mcp.Tool_agent in
        let witness a =
          let actual = T.agent_card_action_to_string a in
          if not (List.mem actual T.valid_agent_card_action_strings) then
            Alcotest.failf "agent_card_action_to_string %S not in valid_agent_card_action_strings" actual
        in
        witness T.Get; witness T.Refresh;
        Alcotest.(check int) "count" 2 (List.length T.valid_agent_card_action_strings));
      Alcotest.test_case "collaboration_format witness covers both variants" `Quick (fun () ->
        let module T = Masc_mcp.Tool_agent in
        let witness f =
          let actual = T.collaboration_format_to_string f in
          if not (List.mem actual T.valid_collaboration_format_strings) then
            Alcotest.failf "collaboration_format_to_string %S not in valid_collaboration_format_strings" actual
        in
        witness T.Text; witness T.Json;
        Alcotest.(check int) "count" 2 (List.length T.valid_collaboration_format_strings));
      Alcotest.test_case "of_string_opt sound partial + back-compat" `Quick (fun () ->
        let module T = Masc_mcp.Tool_agent in
        Alcotest.(check bool) "agent_card_action 'get'" true
          (T.agent_card_action_of_string_opt "get" = Some T.Get);
        Alcotest.(check bool) "agent_card_action '' -> Get back-compat" true
          (T.agent_card_action_of_string_opt "" = Some T.Get);
        Alcotest.(check bool) "agent_card_action 'REFRESH' (case)" true
          (T.agent_card_action_of_string_opt "REFRESH" = Some T.Refresh);
        Alcotest.(check bool) "agent_card_action garbage rejected" true
          (T.agent_card_action_of_string_opt "delete" = None);
        Alcotest.(check bool) "collaboration_format 'json'" true
          (T.collaboration_format_of_string_opt "json" = Some T.Json);
        Alcotest.(check bool) "collaboration_format '' -> Text back-compat" true
          (T.collaboration_format_of_string_opt "" = Some T.Text);
        Alcotest.(check bool) "collaboration_format garbage rejected" true
          (T.collaboration_format_of_string_opt "yaml" = None));
      Alcotest.test_case "schema mirrors stay in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "agent_card_action mirror == SSOT"
          Masc_mcp.Tool_agent.valid_agent_card_action_strings
          Tool_schemas_agent.agent_card_action_enum_strings;
        Alcotest.(check (list string)) "collaboration_format mirror == SSOT"
          Masc_mcp.Tool_agent.valid_collaboration_format_strings
          Tool_schemas_agent.collaboration_format_enum_strings);
    ];
    "sort_order_schema_ssot", [
      (* Issue #8513: Tool_shard.sort_order_enum_strings (used in
         keeper_board_list schema) hand-listed only 3 of 5 sort orders
         exposed by Board_dispatch.valid_sort_order_strings (#8453).
         Trending and Discussed were missing. This test asserts the
         mirror == SSOT so adding a new sort order Variant flows
         through to the schema automatically. *)
      Alcotest.test_case "tool_shard mirror == Board_dispatch SSOT" `Quick (fun () ->
        Alcotest.(check (list string)) "schema mirror == sort_order SSOT"
          Masc_mcp.Board_dispatch.valid_sort_order_strings
          Masc_mcp.Tool_shard.sort_order_enum_strings);
      Alcotest.test_case "Trending and Discussed now present" `Quick (fun () ->
        let actual = Masc_mcp.Tool_shard.sort_order_enum_strings in
        Alcotest.(check bool) "trending present" true (List.mem "trending" actual);
        Alcotest.(check bool) "discussed present" true (List.mem "discussed" actual));
    ];
    "git_action_ssot", [
      (* Issue #8522: introduces [Tool_code_write.git_action] Variant
         where 3 sites within the same file co-validated the same 11-
         action vocabulary (allowlist + schema enum + 6 inline string
         comparisons). Witness covers all 11 constructors. *)
      Alcotest.test_case "witness covers all 11 variants" `Quick (fun () ->
        let module T = Masc_mcp.Tool_code_write in
        let witness a =
          let actual = T.git_action_to_string a in
          if not (List.mem actual T.valid_git_action_strings) then
            Alcotest.failf "git_action_to_string %S not in valid_git_action_strings" actual
        in
        witness T.Add; witness T.Commit; witness T.Push;
        witness T.Diff; witness T.Status; witness T.Log;
        witness T.Branch; witness T.Checkout; witness T.Stash;
        witness T.Fetch; witness T.Clone;
        Alcotest.(check int) "count" 11 (List.length T.valid_git_action_strings));
      Alcotest.test_case "of_string_opt sound partial" `Quick (fun () ->
        let module T = Masc_mcp.Tool_code_write in
        Alcotest.(check bool) "commit" true (T.git_action_of_string_opt "commit" <> None);
        Alcotest.(check bool) "PUSH (case)" true (T.git_action_of_string_opt "PUSH" <> None);
        Alcotest.(check bool) "  clone  (trim)" true
          (T.git_action_of_string_opt "  clone  " <> None);
        Alcotest.(check bool) "garbage rejected" true
          (T.git_action_of_string_opt "rebase" = None));
      Alcotest.test_case "allowed_git_actions == SSOT" `Quick (fun () ->
        Alcotest.(check (list string)) "allowlist == valid_git_action_strings"
          Masc_mcp.Tool_code_write.valid_git_action_strings
          Masc_mcp.Tool_code_write.allowed_git_actions);
    ];
    "mcp_session_action_ssot", [
      (* Issue #8520: introduces [Mcp_session.action] Variant where 2
         sites previously co-validated raw strings (schema enum +
         tool_inline_dispatch match). Witness covers all 5 constructors;
         mirror sync test asserts the Tool_schemas_inline_infra mirror
         stays in lock-step with the SSOT. *)
      Alcotest.test_case "witness covers all 5 variants" `Quick (fun () ->
        let module M = Mcp_session in
        let witness a =
          let actual = M.action_to_string a in
          if not (List.mem actual M.valid_action_strings) then
            Alcotest.failf "action_to_string %S not in valid_action_strings" actual
        in
        witness M.Get; witness M.Create; witness M.List;
        witness M.Cleanup; witness M.Remove;
        Alcotest.(check int) "count" 5 (List.length M.valid_action_strings));
      Alcotest.test_case "of_string_opt sound partial" `Quick (fun () ->
        let module M = Mcp_session in
        Alcotest.(check bool) "create" true (M.action_of_string_opt "create" <> None);
        Alcotest.(check bool) "GET (case)" true (M.action_of_string_opt "GET" <> None);
        Alcotest.(check bool) "  list  (trim)" true
          (M.action_of_string_opt "  list  " <> None);
        Alcotest.(check bool) "garbage rejected" true
          (M.action_of_string_opt "delete" = None);
        Alcotest.(check bool) "empty rejected" true
          (M.action_of_string_opt "" = None));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_schemas mirror == SSOT"
          Mcp_session.valid_action_strings
          Tool_schemas_inline_infra.mcp_session_action_enum_strings);
    ];
    "keeper_shell_op_ssot", [
      (* Issue #8524: Keeper_exec_shell.shell_op Variant has 16
         constructors but tool_shard.ml schema enum hand-listed only
         15 — git_worktree was missing even though the dispatcher
         accepted it (line 1021) and supported_ops self-advertised it
         (line 1383). 6th REAL bug found via this sweep. Same shape
         as #8430 / #8471 / #8474 / #8493 / #8513. *)
      Alcotest.test_case "witness covers all 16 variants" `Quick (fun () ->
        let module S = Masc_mcp.Keeper_exec_shell in
        let witness o =
          let actual = S.shell_op_to_string o in
          if not (List.mem actual S.valid_shell_op_strings) then
            Alcotest.failf "shell_op_to_string %S not in valid_shell_op_strings" actual
        in
        witness S.Pwd; witness S.Ls; witness S.Cat; witness S.Rg;
        witness S.Git_status; witness S.Find; witness S.Head; witness S.Tail;
        witness S.Wc; witness S.Tree; witness S.Git_log; witness S.Git_diff;
        witness S.Git_worktree; witness S.Bash; witness S.Git_clone; witness S.Gh;
        Alcotest.(check int) "count" 16 (List.length S.valid_shell_op_strings));
      Alcotest.test_case "schema mirror matches SSOT" `Quick (fun () ->
        Alcotest.(check (list string)) "tool_shard mirror == SSOT"
          Masc_mcp.Keeper_exec_shell.valid_shell_op_strings
          Masc_mcp.Tool_shard.keeper_shell_op_enum_strings);
      Alcotest.test_case "git_worktree now in schema" `Quick (fun () ->
        Alcotest.(check bool) "git_worktree present" true
          (List.mem "git_worktree" Masc_mcp.Tool_shard.keeper_shell_op_enum_strings));
    ];
    "channel_label_ssot", [
      (* Issue #8569: keeper_keepalive used to hand-build the
         [channel=…] log label as [if is_autonomous then "autonomous"
         else "reactive"], emitting [autonomous] (truncated) while
         every other surface emitted the SSOT
         [Keeper_world_observation.channel_to_string]'s
         [scheduled_autonomous] (full snake_case). Operators grepping
         for one form silently missed events from the other. The fix
         derives the keepalive label from the SSOT directly. These
         tests pin the SSOT label and catch any future re-truncation. *)
      Alcotest.test_case "channel_to_string emits full snake_case" `Quick (fun () ->
        let open Masc_mcp.Keeper_world_observation in
        Alcotest.(check string) "Scheduled_autonomous label"
          "scheduled_autonomous" (channel_to_string Scheduled_autonomous);
        Alcotest.(check string) "Reactive label"
          "reactive" (channel_to_string Reactive));
      Alcotest.test_case "truncated 'autonomous' label is NOT the SSOT (regression #8569)" `Quick (fun () ->
        let open Masc_mcp.Keeper_world_observation in
        let label = channel_to_string Scheduled_autonomous in
        Alcotest.(check bool) "label is not the truncated form" false
          (String.equal label "autonomous"));
    ];
    "tail_order_ssot", [
      (* Issue #8486: witness exhaustiveness for [Keeper_status_detail.tail_order]
         + sync test for the [Keeper_schema.tail_order_enum_strings] mirror.
         Same shape as #8467 (sandbox/network/shared_memory). *)
      Alcotest.test_case "witness covers both variants" `Quick (fun () ->
        let module S = Masc_mcp.Keeper_status_detail in
        let witness o =
          let actual = S.tail_order_to_string o in
          if not (List.mem actual S.valid_tail_order_strings) then
            Alcotest.failf "tail_order_to_string %S not in valid_tail_order_strings" actual
        in
        witness S.Oldest_first; witness S.Newest_first;
        Alcotest.(check int) "count" 2 (List.length S.valid_tail_order_strings));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "tail_order mirror == SSOT"
          Masc_mcp.Keeper_status_detail.valid_tail_order_strings
          Masc_mcp.Keeper_schema.tail_order_enum_strings);
    ];
    "dashboard_scope_ssot", [
      (* Issue #8592: witness exhaustiveness for [Dashboard.scope] +
         sync test for [Tool_schemas_misc.dashboard_scope_enum_strings].
         Same shape as #8486 (tail_order). The dashboard scope was
         hand-rolled inline in tool_schemas_misc.ml; adding a 3rd
         constructor would silently drop from the JSON Schema. *)
      Alcotest.test_case "witness covers both variants" `Quick (fun () ->
        let module D = Masc_mcp.Dashboard in
        let witness s =
          let actual = D.scope_to_string s in
          if not (List.mem actual D.valid_scope_strings) then
            Alcotest.failf "scope_to_string %S not in valid_scope_strings" actual
        in
        witness D.All; witness D.Current;
        Alcotest.(check int) "count" 2 (List.length D.valid_scope_strings));
      Alcotest.test_case "schema mirror stays in sync" `Quick (fun () ->
        Alcotest.(check (list string)) "dashboard scope mirror == SSOT"
          Masc_mcp.Dashboard.valid_scope_strings
          Tool_schemas_misc.dashboard_scope_enum_strings);
      Alcotest.test_case "scope_of_string_opt round-trips SSOT strings" `Quick (fun () ->
        let module D = Masc_mcp.Dashboard in
        List.iter (fun s ->
          match D.scope_of_string_opt s with
          | None -> Alcotest.failf "scope_of_string_opt %S returned None" s
          | Some scope ->
            let back = D.scope_to_string scope in
            Alcotest.(check string) (Printf.sprintf "round-trip %S" s) s back)
        D.valid_scope_strings);
      Alcotest.test_case "scope_of_string_opt rejects unknown input" `Quick (fun () ->
        Alcotest.(check (option string)) "unknown -> None"
          None
          (Option.map Masc_mcp.Dashboard.scope_to_string
             (Masc_mcp.Dashboard.scope_of_string_opt "recent")));
    ];
    "compact_retry_exhausted_ssot", [
      (* Issue #8581: the [compact_retry_exhausted] field was read by
         derive_phase to promote (context_overflow + latch) to Paused
         but never set in OCaml — the right disjunct of the Paused
         branch was dead code. The fix introduces a first-class event
         [Compact_retry_exhausted] that latches the field, dispatched by
         [pause_keeper_for_overflow] before [Operator_pause]. These
         tests pin the new event surface and the latch transition. *)
      Alcotest.test_case "event_to_string emits stable wire string" `Quick (fun () ->
        let open Masc_mcp.Keeper_state_machine in
        Alcotest.(check string) "Compact_retry_exhausted wire form"
          "compact_retry_exhausted"
          (event_to_string Compact_retry_exhausted));
      Alcotest.test_case "update_conditions latches the flag" `Quick (fun () ->
        let open Masc_mcp.Keeper_state_machine in
        let c0 = default_conditions in
        Alcotest.(check bool) "init: flag false" false
          c0.compact_retry_exhausted;
        let c1 = update_conditions c0 Compact_retry_exhausted in
        Alcotest.(check bool) "after event: flag true" true
          c1.compact_retry_exhausted);
      Alcotest.test_case "Operator_compact_requested clears the latch" `Quick (fun () ->
        let open Masc_mcp.Keeper_state_machine in
        let c =
          update_conditions default_conditions Compact_retry_exhausted
        in
        Alcotest.(check bool) "latched" true c.compact_retry_exhausted;
        let c' = update_conditions c Operator_compact_requested in
        Alcotest.(check bool) "cleared by operator compact" false
          c'.compact_retry_exhausted);
    ];
    "lifecycle_events_ssot", [
      (* Issue #8575: Oas_events.publish_keeper_lifecycle docstring
         used to list 5 event names (started/stopped/crashed/restarted/
         dead) while the supervisor + keepalive together emit 10 —
         operators reading the doc silently missed the cleanup /
         self-healing events (reconciled / dead_cleaned /
         self_preservation / paused_pruned). The fix introduces
         Keeper_lifecycle_events as the SSOT vocabulary and these
         tests pin it: every literal still emitted by the production
         code lives in [all_event_names], and the phase-derived strings
         match Keeper_state_machine.phase_to_string for the four
         phases that fire a wire event. *)
      Alcotest.test_case "custom-event witness covers all constructors" `Quick (fun () ->
        let module L = Masc_mcp.Keeper_lifecycle_events in
        let witness e =
          let s = L.to_string e in
          if not (List.mem s L.valid_custom_event_strings) then
            Alcotest.failf "to_string %S not in valid_custom_event_strings" s
        in
        witness L.Started;
        witness L.Reconciled;
        witness L.Restarted;
        witness L.Dead_cleaned;
        witness L.Self_preservation;
        witness L.Paused_pruned;
        Alcotest.(check int) "all_custom_events count" 6
          (List.length L.all_custom_events));
      Alcotest.test_case "phase-derived strings match Keeper_state_machine SSOT" `Quick (fun () ->
        let open Masc_mcp.Keeper_state_machine in
        let expected = [
          phase_to_string Stopped;
          phase_to_string Crashed;
          phase_to_string Dead;
          phase_to_string Running;
        ] in
        Alcotest.(check (list string)) "phase-derived event names match SSOT"
          expected
          Masc_mcp.Keeper_lifecycle_events.phase_derived_event_strings);
      Alcotest.test_case "all_event_names covers cleanup events (regression #8575)" `Quick (fun () ->
        let names = Masc_mcp.Keeper_lifecycle_events.all_event_names in
        List.iter (fun n ->
          Alcotest.(check bool) (Printf.sprintf "%s present" n) true
            (List.mem n names))
          [ "reconciled"; "dead_cleaned"; "self_preservation"; "paused_pruned" ]);
      Alcotest.test_case "all_event_names totals 10 distinct names" `Quick (fun () ->
        let names = Masc_mcp.Keeper_lifecycle_events.all_event_names in
        let dedup = List.sort_uniq String.compare names in
        Alcotest.(check int) "10 distinct" 10 (List.length names);
        Alcotest.(check int) "no duplicates" (List.length names)
          (List.length dedup));
    ];
    "publish_phase_lifecycle_ssot", [
      (* Issue #8572: phase-bearing publish_lifecycle calls used to pass
         a hand-coded event_name string alongside the phase Variant —
         no compile-time link, so [~phase:Stopped "crashed"] would
         have shipped a contradictory event. The fix derives the
         event from [Keeper_state_machine.phase_to_string]; these
         tests pin the wire-format strings downstream consumers
         (dashboards, audit log) depend on so a Variant rename
         cannot silently change the event name. *)
      Alcotest.test_case "phase_to_string emits stable wire strings" `Quick (fun () ->
        let open Masc_mcp.Keeper_state_machine in
        Alcotest.(check string) "Stopped" "stopped" (phase_to_string Stopped);
        Alcotest.(check string) "Crashed" "crashed" (phase_to_string Crashed);
        Alcotest.(check string) "Running" "running" (phase_to_string Running);
        Alcotest.(check string) "Dead" "dead" (phase_to_string Dead));
      Alcotest.test_case "all_phases round-trip through to_string/of_string" `Quick (fun () ->
        let open Masc_mcp.Keeper_state_machine in
        List.iter (fun p ->
          let s = phase_to_string p in
          match phase_of_string s with
          | Some p' when phase_to_string p' = s -> ()
          | Some _ -> Alcotest.failf "phase_of_string %S parsed to a different phase" s
          | None -> Alcotest.failf "phase_of_string %S returned None — round-trip broken" s
        ) all_phases);
    ];
    "health_paths_ssot", [
      (* Issue #8403: SSOT for /health/live and /health/ready strings.
         The literals previously appeared 9 times across 5 files (HTTP/1
         router, H/2 gateway, auth public-read whitelist, startup
         takeover liveness probe default, bin rate-limit exemption)
         with no shared constant — silent drift was the failure mode
         (a renamed probe could leak an auth-required URL through the
         public whitelist, or fall outside the rate-limit exemption).
         These tests pin the constants to their literal wire format
         (external monitors depend on them) and assert [is_public]
         covers both probes. *)
      Alcotest.test_case "constants pinned to wire format" `Quick (fun () ->
        let open Masc_mcp.Server_health_paths in
        Alcotest.(check string) "liveness wire path" "/health/live" liveness;
        Alcotest.(check string) "readiness wire path" "/health/ready" readiness);
      Alcotest.test_case "public lists both probes in order" `Quick (fun () ->
        let open Masc_mcp.Server_health_paths in
        Alcotest.(check (list string)) "public order"
          [ "/health/live"; "/health/ready" ] public);
      Alcotest.test_case "is_public matches probes, rejects others" `Quick (fun () ->
        let open Masc_mcp.Server_health_paths in
        Alcotest.(check bool) "/health/live" true (is_public "/health/live");
        Alcotest.(check bool) "/health/ready" true (is_public "/health/ready");
        Alcotest.(check bool) "/health (root) not in public" false
          (is_public "/health");
        Alcotest.(check bool) "/foo not in public" false (is_public "/foo");
        Alcotest.(check bool) "empty path" false (is_public ""));
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
