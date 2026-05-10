(** Unit tests for Chronicle_event (RFC-0035 PR-4,
    Master Report Dim02 P1). *)

open Masc_mcp.Chronicle_event

let test_event_type_roundtrip () =
  let all_event_types =
    [ Ev_file_opened; Ev_file_edited; Ev_file_saved; Ev_command_executed
    ; Ev_keeper_started; Ev_keeper_step; Ev_keeper_decision
    ; Ev_keeper_completed; Ev_keeper_error
    ; Ev_plan_created; Ev_plan_updated; Ev_plan_step_completed
    ; Ev_plan_blocked
    ; Ev_build_completed; Ev_test_passed; Ev_test_failed
    ; Ev_git_commit; Ev_git_merge
    ; Ev_conversation
    ; Ev_suggestion_accepted; Ev_suggestion_rejected
    ]
  in
  List.iter
    (fun ev ->
      let s = event_type_to_string ev in
      match event_type_of_string s with
      | Ok ev' when ev = ev' -> ()
      | Ok _ ->
        Alcotest.failf
          "event_type_of_string %s did not roundtrip cleanly" s
      | Error msg ->
        Alcotest.failf
          "event_type_of_string %s rejected: %s" s msg)
    all_event_types

let test_actor_kind_roundtrip () =
  let all = [ Ak_user; Ak_keeper; Ak_agent; Ak_system ] in
  List.iter
    (fun a ->
      let s = actor_kind_to_string a in
      match actor_kind_of_string s with
      | Ok a' when a = a' -> ()
      | Ok _ -> Alcotest.failf "actor_kind %s did not roundtrip" s
      | Error msg -> Alcotest.failf "actor_kind %s rejected: %s" s msg)
    all

let test_target_kind_roundtrip () =
  let all =
    [ Tk_file; Tk_module; Tk_plan; Tk_issue; Tk_command; Tk_test
    ; Tk_conversation
    ]
  in
  List.iter
    (fun t ->
      let s = target_kind_to_string t in
      match target_kind_of_string s with
      | Ok t' when t = t' -> ()
      | Ok _ -> Alcotest.failf "target_kind %s did not roundtrip" s
      | Error msg -> Alcotest.failf "target_kind %s rejected: %s" s msg)
    all

let example_event () =
  {
    id = "01HQK0G7Y0X8M";
    event_type = Ev_keeper_step;
    timestamp = 1_778_073_600_000;
    actor = {
      kind = Ak_keeper;
      id = "keeper-executor";
      display_name = "Executor";
    };
    target = {
      kind = Tk_file;
      uri = "lib/chronicle_event.ml";
      range = Some (1, 50);
    };
    content = {
      summary = "scaffolded chronicle_event";
      detail = Some "added type definitions and JSON codec";
      diff = None;
      metadata = [ "loc", `Int 200 ];
    };
    context = {
      session_id = "session-001";
      parent_event_id = Some "parent-event-id";
      related_event_ids = [ "ev-1"; "ev-2" ];
      tags = [ "p1"; "chronicle" ];
      project_state = Some {
        branch = Some "feat/rfc-0035-pr-4";
        commit = Some "abc123";
        files_changed = Some 3;
        dirty = Some true;
      };
    };
    intent = Some {
      stated_goal = Some "ship Chronicle backend";
      inferred_intent = Some "RFC-0035 P1 progress";
      confidence = 0.85;
    };
  }

let test_json_roundtrip_full () =
  let ev = example_event () in
  let json = to_yojson ev in
  match of_yojson json with
  | Ok ev' ->
    Alcotest.(check string) "id preserved" ev.id ev'.id;
    Alcotest.(check string)
      "eventType preserved"
      (event_type_to_string ev.event_type)
      (event_type_to_string ev'.event_type);
    Alcotest.(check int) "timestamp preserved" ev.timestamp ev'.timestamp;
    Alcotest.(check string)
      "actor display_name preserved"
      ev.actor.display_name ev'.actor.display_name;
    Alcotest.(check string)
      "target uri preserved" ev.target.uri ev'.target.uri;
    Alcotest.(check string)
      "content summary preserved"
      ev.content.summary ev'.content.summary;
    Alcotest.(check string)
      "session_id preserved"
      ev.context.session_id ev'.context.session_id;
    Alcotest.(check (list string))
      "tags preserved" ev.context.tags ev'.context.tags
  | Error msg ->
    Alcotest.failf "of_yojson rejected our own emit: %s" msg

let test_dashboard_camelcase_keys () =
  (* Verify that to_yojson emits the camelCase keys the dashboard
     read model (chronicle-types.ts) expects. *)
  let ev = example_event () in
  let json = to_yojson ev in
  let s = Yojson.Safe.to_string json in
  let must_contain needle =
    Alcotest.(check bool)
      (Printf.sprintf "wire format must contain '%s'" needle)
      true
      (let len_n = String.length needle in
       let len_s = String.length s in
       let rec scan i =
         if i + len_n > len_s then false
         else if String.sub s i len_n = needle then true
         else scan (i + 1)
       in
       scan 0)
  in
  List.iter must_contain
    [ "\"eventType\""
    ; "\"displayName\""
    ; "\"sessionId\""
    ; "\"parentEventId\""
    ; "\"relatedEventIds\""
    ; "\"projectState\""
    ; "\"filesChanged\""
    ; "\"statedGoal\""
    ; "\"inferredIntent\""
    ]

let test_optional_intent_absent () =
  let ev = { (example_event ()) with intent = None } in
  let json = to_yojson ev in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool)
      "intent must be absent (not null) when None"
      true
      (not (List.mem_assoc "intent" fields))
  | _ -> Alcotest.fail "to_yojson must emit a JSON object"

let test_of_yojson_rejects_unknown_event_type () =
  let json =
    Yojson.Safe.from_string
      {|{"id":"a","eventType":"unknown.thing","timestamp":1,
       "actor":{"type":"user","id":"u","displayName":"User"},
       "target":{"type":"file","uri":"x"},
       "content":{"summary":"s"},
       "context":{"sessionId":"sess","relatedEventIds":[],"tags":[]}}|}
  in
  match of_yojson json with
  | Ok _ -> Alcotest.fail "of_yojson should reject unknown.thing"
  | Error _ -> ()

let test_of_yojson_rejects_missing_required () =
  let json =
    Yojson.Safe.from_string
      {|{"id":"a","timestamp":1,
       "actor":{"type":"user","id":"u","displayName":"User"},
       "target":{"type":"file","uri":"x"},
       "content":{"summary":"s"},
       "context":{"sessionId":"sess","relatedEventIds":[],"tags":[]}}|}
  in
  match of_yojson json with
  | Ok _ -> Alcotest.fail "of_yojson should reject missing eventType"
  | Error _ -> ()

let test_well_formed_accepts_example () =
  match is_well_formed (example_event ()) with
  | Ok () -> ()
  | Error msg -> Alcotest.failf "example event rejected: %s" msg

let test_well_formed_rejects_blanks () =
  let blank_id = { (example_event ()) with id = "" } in
  Alcotest.(check bool)
    "blank id rejected" true (Result.is_error (is_well_formed blank_id));
  let blank_summary =
    let ev = example_event () in
    { ev with content = { ev.content with summary = "" } }
  in
  Alcotest.(check bool)
    "blank summary rejected" true
    (Result.is_error (is_well_formed blank_summary));
  let bad_intent =
    let ev = example_event () in
    {
      ev with
      intent = Some {
        stated_goal = None;
        inferred_intent = None;
        confidence = 1.5;
      };
    }
  in
  Alcotest.(check bool)
    "out-of-range confidence rejected" true
    (Result.is_error (is_well_formed bad_intent))

let () =
  Alcotest.run "chronicle_event"
    [
      ( "string_taxonomies",
        [
          Alcotest.test_case "event_type round-trip" `Quick
            test_event_type_roundtrip;
          Alcotest.test_case "actor_kind round-trip" `Quick
            test_actor_kind_roundtrip;
          Alcotest.test_case "target_kind round-trip" `Quick
            test_target_kind_roundtrip;
        ] );
      ( "json_codec",
        [
          Alcotest.test_case "full event round-trip" `Quick
            test_json_roundtrip_full;
          Alcotest.test_case "dashboard camelCase keys" `Quick
            test_dashboard_camelcase_keys;
          Alcotest.test_case "optional intent absent on emit" `Quick
            test_optional_intent_absent;
          Alcotest.test_case "rejects unknown eventType" `Quick
            test_of_yojson_rejects_unknown_event_type;
          Alcotest.test_case "rejects missing eventType" `Quick
            test_of_yojson_rejects_missing_required;
        ] );
      ( "well_formed",
        [
          Alcotest.test_case "accepts example" `Quick
            test_well_formed_accepts_example;
          Alcotest.test_case "rejects blanks and out-of-range" `Quick
            test_well_formed_rejects_blanks;
        ] );
    ]
