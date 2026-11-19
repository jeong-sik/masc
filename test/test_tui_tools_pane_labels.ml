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

let async_json_submitted_at submitted_at =
  `Assoc
    [ "schema", `String "masc.async-request-observation/v1"; "status", `String "ready"
    ; "summary", `Assoc [ "active", `Int 1; "runtime_owned", `Int 1; "ownership_unknown", `Int 0; "record_errors", `Int 0 ]
    ; "requests", `List [ `Assoc [ "request_id", `String "req-capture-0001"; "submitted_by", `String "capture-owner"; "keeper_name", `String "imp"; "status", `String "running"; "worker_ownership", `String "runtime_owned"; "submitted_at", `Float submitted_at; "elapsed_sec", `Float 12.5 ] ]
    ; "startup_recovery", `Null ]

let async_json = async_json_submitted_at 1000.0

let ledger_of_json revision =
  match Masc.Keeper_skill_activation_ledger.of_projection_yojson (List.assoc "ledger" (match ledger_json revision with `Assoc fields -> fields | _ -> failwith "obj")) with
  | Ok ledger -> ledger
  | Error detail -> failwith ("decode: " ^ Masc.Keeper_skill_activation_ledger.decode_error_code detail)

let revision_solved =
  let canonical = `Assoc [ "workspace_key", `String hex64; "session_id", `String trace_id; "activations", `List [ activation ]; "transition_rejections", `List []; "async_result_deliveries", `List []; "async_actions", `List [] ] in
  Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string canonical)))

let async_of_json ?(json = async_json) () =
  match Masc.Tui_decode.decode_async_request_observation json with
  | Ok observation -> observation
  | Error detail -> failwith ("async: " ^ detail)

let tools_state () =
  let state = create_state ~workspace:"" ~port:0 () in
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
         ; ts_usage = None
         ; ts_volume_gc_report = None
         ; ts_storage =
             { Masc.Tui_decode_tools.st_host_disk = Masc.Tui_decode_tools.Host_disk_absent
             ; st_keeper_cleanup = Masc.Tui_decode_tools.Keeper_cleanup_absent } };
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

(* The Usage pane joins each Keeper's own usage answer to the catalog by
   exact reference and counts the ledgers it read. *)
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
    [ "alpha"; "bravo"; "carol"; "idle" ] (List.map fst state.tools_keeper_usage)

(* A failed read keeps the Keeper's last answer in the totals and says the
   read failed; a Keeper with no answer at all is not counted. *)
let test_a_failed_read_keeps_the_last_answer () =
  let state = usage_state () in
  record_keeper_skill_usage state ~keeper:"alpha" (ready [ usage_row 2 ]);
  record_keeper_skill_usage state ~keeper:"alpha" (Error (Request_failed "timed out"));
  record_keeper_skill_usage state ~keeper:"bravo" (Error (Request_failed "connection refused"));
  (match List.assoc_opt "alpha" state.tools_keeper_usage with
   | Some (Skill_usage_read_failed { last = Some (Masc.Tui_decode_tools.Keeper_usage_ready [ _ ]); detail }) ->
     Alcotest.(check bool) "the failure is kept" true (detail = Request_failed "timed out")
   | Some (Skill_usage_read _ | Skill_usage_read_failed _) | None ->
     Alcotest.fail "alpha should keep its last answer beside the failure")

(* Only a whole roster drops a reading. A roster read empty says there is no
   Keeper; one not read yet, or whose read failed, keeps the readings and
   says why the totals may miss Keepers. *)
let test_only_a_whole_roster_drops_readings () =
  let roster_state local =
    let state = usage_state () in
    record_keeper_skill_usage state ~keeper:"alpha" (ready [ usage_row 2 ]);
    state.keepers <- [];
    state.local_keepers <- local;
    keep_roster_skill_usage state;
    state
  in
  let unread = roster_state Local_workspace_unread in
  Alcotest.(check int) "an unread roster keeps the reading" 1 (List.length unread.tools_keeper_usage);
  let failed = roster_state (Local_workspace_failed "roster unavailable") in
  Alcotest.(check int) "a failed roster keeps the reading" 1 (List.length failed.tools_keeper_usage);
  let partial = roster_state Local_workspace_read in
  partial.keepers_error <- Some "one keeper unreadable";
  record_keeper_skill_usage partial ~keeper:"alpha" (ready [ usage_row 2 ]);
  keep_roster_skill_usage partial;
  Alcotest.(check int) "a roster read with an error keeps the reading" 1
    (List.length partial.tools_keeper_usage);
  let empty = roster_state Local_workspace_read in
  Alcotest.(check int) "a whole empty roster keeps none" 0 (List.length empty.tools_keeper_usage)

(* A reading or a failure is held for one Keeper. The Tools screen treats
   one held for another Keeper, or for one while none is selected, as
   another Keeper's: it reads the selected Keeper without the other's
   backoff and draws none of the other's failure. *)
let test_readings_and_failures_belong_to_their_keeper () =
  let reading keeper =
    Some (Activations_read
            (Masc.Tui_decode_tools.Skill_activations_no_session { sap_keeper_name = keeper }))
  in
  let failure keeper = Some { taf_keeper = keeper; taf_detail = Request_failed "read failed" } in
  let held ~selected reading failure = activations_held_for_another ~selected reading failure in
  Alcotest.(check bool) "the selected Keeper's reading" false (held ~selected:(Some "a") (reading "a") None);
  Alcotest.(check bool) "another Keeper's reading" true (held ~selected:(Some "b") (reading "a") None);
  Alcotest.(check bool) "the selected Keeper's failure" false (held ~selected:(Some "a") None (failure "a"));
  Alcotest.(check bool) "another Keeper's failure" true (held ~selected:(Some "b") None (failure "a"));
  Alcotest.(check bool) "a failure while no Keeper is selected" true (held ~selected:None None (failure "a"));
  Alcotest.(check bool) "no Keeper, nothing held" false
    (held ~selected:None (Some Activations_no_keeper) None);
  Alcotest.(check bool) "a no-Keeper reading once one is selected" true
    (held ~selected:(Some "a") (Some Activations_no_keeper) None);
  Alcotest.(check bool) "nothing held yet" false (held ~selected:(Some "a") None None);
  let waiting = Masc_tui_owed_read.Waiting { failures = 3; retry_at = 100. } in
  let failures = function
    | Masc_tui_owed_read.Reading { failures; _ } -> failures
    | Masc_tui_owed_read.(Settled | Owed _ | Waiting _) -> Alcotest.fail "the read did not start"
  in
  Alcotest.(check int) "another Keeper's read starts with no failures" 0
    (failures (start_owed_read ~for_another:true waiting));
  Alcotest.(check int) "the same Keeper's read keeps backing off" 3
    (failures (start_owed_read ~for_another:false waiting));
  let error = Some "inventory read failed" in
  Alcotest.(check (option string)) "the selected Keeper's error is drawn" error
    (held_tools_error ~selected:(Some "a") ~held_keeper:(Some "a") error);
  Alcotest.(check (option string)) "another Keeper's error is not" None
    (held_tools_error ~selected:(Some "b") ~held_keeper:(Some "a") error);
  Alcotest.(check (option string)) "an error read with no Keeper selected" error
    (held_tools_error ~selected:None ~held_keeper:None error)

(* The Async pane lists every request with its age and scrolls. Building
   the rows notes no redraw; each request row carries the instant its age
   reads differently, and only a window that draws the row asks for it. *)
let async_display ~cols =
  let state = tools_state () in
  let submitted_at = Unix.gettimeofday () -. 20. in
  state.tools_async_observation <-
    Some (async_of_json ~json:(async_json_submitted_at submitted_at) ());
  state.tools_pane <- Tools_async;
  Masc_tui_value.Redraw.begin_frame ();
  let display = Masc_tui_render_tools.tools_display ~cols state in
  Alcotest.(check bool) "building every row notes nothing" true
    (Option.is_none (Masc_tui_value.Redraw.next_change ()));
  (submitted_at, display)

let drawn (display : Masc_tui_render_tools.display) ~first ~height =
  Masc_tui_render_tools.drawn_change display
    (Masc_tui_rows.of_list ~first ~height display.lines)

let test_a_request_age_asks_for_a_redraw_only_when_drawn () =
  let submitted_at, display = async_display ~cols:160 in
  match display.row_changes with
  | [ (index, at) ] ->
    Alcotest.(check bool) "its age changes after it was submitted" true (at > submitted_at);
    Alcotest.(check (option (float 0.))) "a window that draws the row asks for it" (Some at)
      (drawn display ~first:index ~height:1);
    Alcotest.(check (option (float 0.))) "a window above the row asks nothing" None
      (drawn display ~first:0 ~height:index);
    Alcotest.(check (option (float 0.))) "a window below the row asks nothing" None
      (drawn display ~first:(index + 1) ~height:(List.length display.lines))
  | ([] | _ :: _ :: _) as changes ->
    Alcotest.failf "only the request row carries a change, not %d rows" (List.length changes)

(* A request row too wide for the frame wraps, and its age may land on any
   of the rows: a window that draws only the last of them still asks. *)
let test_a_wrapped_request_asks_from_each_of_its_rows () =
  let _, display = async_display ~cols:40 in
  match display.row_changes, List.rev display.row_changes with
  | (_, at) :: _ :: _, (last, _) :: _ ->
    Alcotest.(check bool) "every row of the request carries one instant" true
      (List.for_all (fun (_, other) -> Float.equal other at) display.row_changes);
    Alcotest.(check (option (float 0.))) "a window over its last row asks for it" (Some at)
      (drawn display ~first:last ~height:1)
  | ([] | [ _ ]), _ | _, [] ->
    Alcotest.failf "the request row wraps into more than one row, not %d"
      (List.length display.row_changes)

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
        ; test_case "only a whole roster drops readings" `Quick
            test_only_a_whole_roster_drops_readings
        ; test_case "readings and failures belong to their Keeper" `Quick
            test_readings_and_failures_belong_to_their_keeper
        ; test_case "a request age asks for a redraw only when drawn" `Quick
            test_a_request_age_asks_for_a_redraw_only_when_drawn
        ; test_case "a wrapped request asks from each of its rows" `Quick
            test_a_wrapped_request_asks_from_each_of_its_rows
        ] )
    ]
