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
    ; "requests", `List [ `Assoc [ "request_id", `String "req-capture-0001"; "submitted_by", `String "capture-owner"; "keeper_name", `String "imp"; "status", `String "running"; "worker_ownership", `String "runtime_owned"; "elapsed_sec", `Float 12.5 ] ]
    ; "startup_recovery", `Null ]

let ledger_of_json revision =
  match Masc.Keeper_skill_activation_ledger.of_projection_yojson (List.assoc "ledger" (match ledger_json revision with `Assoc fields -> fields | _ -> failwith "obj")) with
  | Ok ledger -> ledger
  | Error detail -> failwith ("decode: " ^ Masc.Keeper_skill_activation_ledger.decode_error_code detail)

let revision_solved =
  let canonical = `Assoc [ "workspace_key", `String hex64; "session_id", `String trace_id; "activations", `List [ activation ]; "transition_rejections", `List []; "async_result_deliveries", `List []; "async_actions", `List [] ] in
  Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string canonical)))

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
         ; ts_effective = None
         ; ts_skill_activations =
             Some
               (Masc.Tui_decode_tools.Skill_activations_available
                  { sap_keeper_name = "imp"
                  ; sap_ledger = ledger_of_json revision_solved }) };
  state.tools_async_observation <- Some (async_of_json ());
  state

let test_wire_name_preserved () =
  let state = tools_state () in
  match state.tools_inventory with
  | Some
      { Masc.Tui_decode_tools.ts_skill_activations =
          Some
            (Masc.Tui_decode_tools.Skill_activations_available { sap_ledger; _ });
        _ } ->
    (match Masc.Keeper_skill_activation_ledger.activations sap_ledger with
     | activation :: _ ->
       (match activation.actions with
        | action :: _ ->
          Alcotest.check Alcotest.string "stored action keeps the wire name"
            wire_name action.tool_name
        | [] -> Alcotest.fail "expected one action")
     | [] -> Alcotest.fail "expected one activation")
  | _ -> Alcotest.fail "inventory should hold the ledger"

let () =
  let open Alcotest in
  run "TUI tools pane labels"
    [ ( "labels"
      , [ test_case "stored action keeps the wire name" `Quick
            test_wire_name_preserved
        ] )
    ]
