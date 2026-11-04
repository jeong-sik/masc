open Masc_tui_types

let hex64 = String.init 64 (fun index -> "0123456789abcdef".[index * 7 mod 16])

let wire_name = "masc_board_post"
let trace_id = "capture-harness"
let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:3

let activation =
  `Assoc
    [ "identity", `Assoc [ "source_id", `String "project-masc"; "package_id", `String "masc-capture"; "name", `String "capture-skill" ]
    ; "content_revision", `String hex64
    ; "snapshot_revision", `String hex64
    ; "turn_ref", `String (Ids.Turn_ref.to_string turn_ref)
    ; "runtime_id", `String "ollama-cloud-deepseek"
    ; "skill_tool_use_id", `String "call_capture_001"
    ; "agent_core_turn", `Int 3
    ; "invocation", `Assoc [ "kind", `String "composition"; "origin", `Assoc [ "kind", `String "session_composition" ]; "execution_id", `String "exec-capture-001"; "tool_name", `String "masc_capture_helper" ]
    ; "delivery", `Assoc [ "boundary", `Assoc [ "kind", `String "model_response"; "agent_core_turn", `Int 4 ]; "runtime_id", `String "ollama-cloud-deepseek"; "delivered_at", `String "2026-10-13T15:00:00Z"; "content_bytes", `Int 128; "content_sha256", `String hex64 ]
    ; "actions", `List [ `Assoc [ "identity", `Assoc [ "kind", `String "call_id"; "call_id", `String "call_capture_action_001" ]; "tool_name", `String wire_name; "runtime_id", `String "ollama-cloud-deepseek"; "agent_core_turn", `Int 5; "observed_at", `String "2026-10-13T15:00:05Z" ] ]
    ; "activated_at", `String "2026-10-13T14:59:00Z"
    ]

let ledger_json revision =
  `Assoc
    [ "status", `String "available"; "keeper_name", `String "imp"
    ; "ledger", `Assoc [ "schema", `String "masc.skill-activations/v8"; "workspace_key", `String hex64; "session_id", `String trace_id; "revision", `String revision; "activations", `List [ activation ]; "transition_rejections", `List []; "async_result_deliveries", `List []; "async_actions", `List [] ] ]

let async_json =
  `Assoc
    [ "schema", `String "masc.async-request-observation/v1"; "status", `String "ready"
    ; "summary", `Assoc [ "active", `Int 1; "runtime_owned", `Int 1; "ownership_unknown", `Int 0; "record_errors", `Int 0 ]
    ; "requests", `List [ `Assoc [ "request_id", `String "req-capture-0001"; "submitted_by", `String "capture-owner"; "keeper_name", `String "imp"; "status", `String "running"; "worker_ownership", `String "runtime_owned"; "submitted_at", `Float 1000.0; "elapsed_sec", `Float 12.5 ] ]
    ; "startup_recovery", `Null ]

let ledger_of_json revision =
  match Masc.Keeper_skill_activation_ledger.of_projection_yojson (List.assoc "ledger" (match ledger_json revision with `Assoc fields -> fields | _ -> failwith "obj")) with
  | Ok ledger -> ledger
  | Error detail -> failwith ("decode: " ^ Masc.Keeper_skill_activation_ledger.decode_error_code detail)

let revision_solved =
  let canonical = `Assoc [ "workspace_key", `String hex64; "session_id", `String trace_id; "activations", `List [ activation ]; "transition_rejections", `List []; "async_result_deliveries", `List []; "async_actions", `List [] ] in
  Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string canonical)))

let async_of_json () =
  match Masc.Tui_decode.decode_async_request_observation async_json with
  | Ok observation -> observation
  | Error detail -> failwith ("async: " ^ detail)

let tools_state () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Tools;
  state.agenda_open <- false;
  state.schedules <- None;
  state.schedules_error <- None;
  state.keeper_tool_approvals_observed <- false;
  state.keeper_tool_approvals_error <- None;
  state.observer <- Observer_off;
  state.keepers_error <- None;
  state.tools_inventory <-
    Some { Masc.Tui_decode_tools.ts_tools = []
         ; ts_count = 0
         ; ts_freshness = Masc.Tui_decode_tools.Settled
         ; ts_effective = None };
  state.tools_activations <-
    Some
      (Activations_read
         (Masc.Tui_decode_tools.Skill_activations_available
            { sap_keeper_name = "imp"
            ; sap_ledger = ledger_of_json revision_solved }));
  state.tools_async_observation <- Some (async_of_json ());
  state

let test_wire_name_preserved () =
  let state = tools_state () in
  match state.tools_activations with
  | Some
      (Activations_read
         (Masc.Tui_decode_tools.Skill_activations_available { sap_ledger; _ })) ->
    (match Masc.Keeper_skill_activation_ledger.activations sap_ledger with
     | activation :: _ ->
       (match activation.actions with
        | action :: _ ->
          Alcotest.check Alcotest.string "stored action keeps the wire name"
            wire_name action.tool_name
        | [] -> Alcotest.fail "expected one action")
     | [] -> Alcotest.fail "expected one activation")
  | _ -> Alcotest.fail "the Activations pane should hold the ledger"

let reference_at revision =
  match
    Skill_reference.of_yojson
      (`Assoc
         [ "identity", `Assoc [ "source_id", `String "project-masc"; "package_id", `String "masc-capture"; "name", `String "capture-skill" ]
         ; "content_revision", `String revision ])
  with
  | Ok reference -> reference
  | Error _ -> failwith "reference fixture"

let usage_reference = reference_at hex64

(* A revision of the same Skill that the catalog reading does not hold. *)
let other_revision = String.make 64 'b'

let usage_row ?(reference = usage_reference) invocations =
  { Masc.Tui_decode_tools.ksu_reference = reference
  ; ksu_invocations = invocations
  ; ksu_deliveries = invocations
  ; ksu_actions = 1
  ; ksu_last_used_at = "2026-11-04T00:00:00Z"
  }

let usage_state () =
  let state = tools_state () in
  state.tools_pane <- Tools_usage;
  state.skills_catalog <-
    Some
      { Masc.Tui_decode_tools.sc_state = Masc.Tui_decode_tools.Skills_ready
      ; sc_config = None
      ; sc_sources = []
      ; sc_surfaces =
          [ { Masc.Tui_decode_tools.scs_reference = usage_reference
            ; scs_kind = "instruction"
            ; scs_flow = None
            } ]
      ; sc_rejections = []
      ; sc_shadows = []
      };
  state

let ready rows = Ok (Masc.Tui_decode_tools.Keeper_usage_ready rows)

let usage_text state =
  Masc_tui_render_tools.tools_display_lines ~cols:160 state
  |> List.map snd |> String.concat "\n"

(* The Usage pane joins each Keeper's own usage answer to the catalog by
   exact reference (RFC-0483) and counts the ledgers it read. *)
let test_usage_pane_joins_each_keepers_answer () =
  let state = usage_state () in
  record_keeper_skill_usage state ~keeper:"bravo" (ready [ usage_row 3 ]);
  record_keeper_skill_usage state ~keeper:"alpha" (ready [ usage_row 2 ]);
  record_keeper_skill_usage state ~keeper:"carol"
    (Ok
       (Masc.Tui_decode_tools.Keeper_usage_unavailable
          { kua_reason = "activation_ledger_unreadable"; kua_detail = "decode failed" }));
  record_keeper_skill_usage state ~keeper:"idle" (Ok Masc.Tui_decode_tools.Keeper_usage_no_session);
  Alcotest.(check (list string)) "readings are kept in Keeper name order"
    [ "alpha"; "bravo"; "carol"; "idle" ] (List.map fst state.tools_keeper_usage);
  let text = usage_text state in
  let contains needle = String_util.contains_substring text needle in
  Alcotest.(check bool) "both Keepers' uses are summed" true
    (contains "Keepers 2 · TRIGGERED 5 · DELIVERED 5 · ACTIONS 2");
  Alcotest.(check bool) "read ledgers are counted" true
    (contains "Activation ledgers loaded: 2; unavailable: 1");
  Alcotest.(check bool) "the unreadable ledger is named" true
    (contains "Unavailable: carol: activation_ledger_unreadable (decode failed)");
  Alcotest.(check bool) "each Keeper has a row" true (contains "alpha" && contains "bravo")

(* A failed read keeps the Keeper's last answer in the totals and says the
   read failed; a Keeper with no answer at all is not counted. *)
let test_a_failed_read_keeps_the_last_answer () =
  let state = usage_state () in
  record_keeper_skill_usage state ~keeper:"alpha" (ready [ usage_row 2 ]);
  record_keeper_skill_usage state ~keeper:"alpha" (Error "timed out");
  record_keeper_skill_usage state ~keeper:"bravo" (Error "connection refused");
  (match List.assoc_opt "alpha" state.tools_keeper_usage with
   | Some (Skill_usage_read_failed { last = Some (Masc.Tui_decode_tools.Keeper_usage_ready [ _ ]); detail }) ->
     Alcotest.(check string) "the failure is kept" "timed out" detail
   | Some (Skill_usage_read _ | Skill_usage_read_failed _) | None ->
     Alcotest.fail "alpha should keep its last answer beside the failure");
  let text = usage_text state in
  let contains needle = String_util.contains_substring text needle in
  Alcotest.(check bool) "the last answer stays in the totals" true
    (contains "Keepers 1 · TRIGGERED 2 · DELIVERED 2 · ACTIONS 1");
  Alcotest.(check bool) "the Keeper with no answer is not counted" true
    (contains "Activation ledgers loaded: 1; unavailable: 1");
  Alcotest.(check bool) "the kept answer is marked" true
    (contains "Unavailable: alpha: read failed: timed out; last answer shown");
  Alcotest.(check bool) "the failed Keeper is named" true
    (contains "Unavailable: bravo: read failed: connection refused")

(* A Keeper answered against a catalog this reading does not hold: its row
   is drawn on its own and counted, not dropped. *)
let test_a_revision_outside_the_catalog_reading_is_drawn () =
  let state = usage_state () in
  record_keeper_skill_usage state ~keeper:"alpha"
    (ready [ usage_row 2; usage_row ~reference:(reference_at other_revision) 4 ]);
  let text = usage_text state in
  let contains needle = String_util.contains_substring text needle in
  Alcotest.(check bool) "both rows are counted" true
    (contains "Keepers 1 · TRIGGERED 6 · DELIVERED 6 · ACTIONS 2");
  Alcotest.(check bool) "the outside rows are headed" true
    (contains "Revisions outside this catalog reading — 1");
  Alcotest.(check bool) "the outside revision is named" true
    (contains ("capture-skill · rev " ^ other_revision));
  Alcotest.(check bool) "its Keeper's counts are drawn" true
    (contains "alpha · TRIGGERED 4 · DELIVERED 4 · ACTIONS 1")

(* An empty roster leaves no readings and says so instead of waiting for a
   read; a failed roster read says the totals may be missing Keepers. *)
let test_an_empty_roster_leaves_no_readings () =
  let state = usage_state () in
  record_keeper_skill_usage state ~keeper:"alpha" (ready [ usage_row 2 ]);
  state.keepers <- [];
  keep_roster_skill_usage state ~roster:[];
  Alcotest.(check int) "no reading is kept" 0 (List.length state.tools_keeper_usage);
  Alcotest.(check bool) "the pane says there is no Keeper" true
    (String_util.contains_substring (usage_text state) "No Keepers in the roster.");
  state.keepers_error <- Some "roster unavailable";
  let text = usage_text state in
  Alcotest.(check bool) "a failed roster read is named" true
    (String_util.contains_substring text
       "Keeper roster read failed: roster unavailable; totals cover only the Keepers listed.");
  Alcotest.(check bool) "it is not called an empty roster" false
    (String_util.contains_substring text "No Keepers in the roster.")

let () =
  let open Alcotest in
  run "TUI tools pane labels"
    [ ( "labels"
      , [ test_case "stored action keeps the wire name" `Quick
            test_wire_name_preserved
        ; test_case "the Usage pane joins each Keeper's answer" `Quick
            test_usage_pane_joins_each_keepers_answer
        ; test_case "a failed read keeps the last answer" `Quick
            test_a_failed_read_keeps_the_last_answer
        ; test_case "a revision outside the catalog reading is drawn" `Quick
            test_a_revision_outside_the_catalog_reading_is_drawn
        ; test_case "an empty roster leaves no readings" `Quick
            test_an_empty_roster_leaves_no_readings
        ] )
    ]
