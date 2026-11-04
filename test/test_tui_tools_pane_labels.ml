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

let usage_reference =
  match
    Skill_reference.of_yojson
      (`Assoc
         [ "identity", `Assoc [ "source_id", `String "project-masc"; "package_id", `String "masc-capture"; "name", `String "capture-skill" ]
         ; "content_revision", `String hex64 ])
  with
  | Ok reference -> reference
  | Error _ -> failwith "reference fixture"

let usage_row invocations =
  { Masc.Tui_decode_tools.ksu_reference = usage_reference
  ; ksu_invocations = invocations
  ; ksu_deliveries = invocations
  ; ksu_actions = 1
  ; ksu_last_used_at = "2026-11-04T00:00:00Z"
  }

(* The Usage pane joins each Keeper's own usage answer to the catalog by
   exact reference (RFC-0483) and counts the ledgers it read. *)
let test_usage_pane_joins_each_keepers_answer () =
  let state = tools_state () in
  state.tools_pane <- Tools_usage;
  state.skills_catalog <-
    Some
      { Masc.Tui_decode_tools.sc_state = Masc.Tui_decode_tools.Skills_ready
      ; sc_config = None
      ; sc_sources = []
      ; sc_surfaces =
          [ { Masc.Tui_decode_tools.scs_reference = usage_reference
            ; scs_name = "capture-skill"
            ; scs_kind = "instruction"
            ; scs_flow = None
            } ]
      ; sc_rejections = []
      ; sc_shadows = []
      };
  state.tools_keeper_usage <-
    [ "alpha", Ok (Masc.Tui_decode_tools.Keeper_usage_ready [ usage_row 2 ])
    ; "bravo", Ok (Masc.Tui_decode_tools.Keeper_usage_ready [ usage_row 3 ])
    ; ( "carol"
      , Ok
          (Masc.Tui_decode_tools.Keeper_usage_unavailable
             { kua_reason = "activation_ledger_unreadable"; kua_detail = "decode failed" }) )
    ; "idle", Ok Masc.Tui_decode_tools.Keeper_usage_no_session
    ];
  let text =
    Masc_tui_render_tools.tools_display_lines ~cols:160 state
    |> List.map snd |> String.concat "\n"
  in
  let contains needle = String_util.contains_substring text needle in
  Alcotest.(check bool) "both Keepers' uses are summed" true
    (contains "Keepers 2 · TRIGGERED 5 · DELIVERED 5 · ACTIONS 2");
  Alcotest.(check bool) "read ledgers are counted" true
    (contains "Activation ledgers loaded: 2; unavailable: 1");
  Alcotest.(check bool) "the unreadable ledger is named" true
    (contains "Unavailable: carol: activation_ledger_unreadable (decode failed)");
  Alcotest.(check bool) "each Keeper has a row" true (contains "alpha" && contains "bravo")

let () =
  let open Alcotest in
  run "TUI tools pane labels"
    [ ( "labels"
      , [ test_case "stored action keeps the wire name" `Quick
            test_wire_name_preserved
        ; test_case "the Usage pane joins each Keeper's answer" `Quick
            test_usage_pane_joins_each_keepers_answer
        ] )
    ]
