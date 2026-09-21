open Masc_tui_types

let expect label wanted actual = Alcotest.(check int) label wanted actual

let runtime id : Masc.Tui_decode.runtime_option =
  { ro_id = id; ro_provider = "provider"; ro_model = "model";
    ro_effective_max_context = 200000; ro_max_context_source = Runtime_context_capability;
    ro_max_output_tokens = Some 8192; ro_declared_reasoning_effort = None; ro_is_local = false;
    ro_is_default = false;
    ro_quota_exhausted = false; ro_quota_resets_at = None; ro_quota_scope = None }

let state () = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let check_layout state expected =
  expect "rendering chrome" expected (runtime_surface_listing_chrome state);
  match scrolled_surface_rows state Runtime with
  | None -> Alcotest.fail "runtime list has no scroll geometry"
  | Some layout -> expect "keyboard shares rendering chrome" expected layout.sc_chrome

let test_picker_and_refusal_keep_footer_space () =
  let state = state () in
  state.runtime_catalog <- [runtime "a"; runtime "b"; runtime "c"];
  check_layout state 12;
  state.runtime_lane_pick <- Some (Pick_conversation_lane "primary");
  (* Three choices, prompt and divider consume five additional rows. *)
  check_layout state 17;
  state.runtime_lane_notice <- Some (Lane_write_refused "route write rejected");
  check_layout state 19;
  state.runtime_surface_error <- Some "resolved unavailable";
  check_layout state 21;
  state.runtime_lane_pick_cursor <- 2;
  check_layout state 19;
  state.runtime_lane_pick <- None;
  check_layout state 16

let test_empty_picker_keeps_its_explanation () =
  let state = state () in
  state.runtime_lane_pick <- Some (Pick_conversation_lane "primary");
  check_layout state 15

(* The lane editor's prompt row -- a name being typed, a lane armed for
   removal -- is two rows the footer has to be moved for, like the refusal. *)
let test_lane_prompt_keeps_footer_space () =
  let state = state () in
  check_layout state 12;
  state.runtime_lane_name_draft <- Some (Naming_new_lane "coding");
  check_layout state 14;
  state.runtime_lane_name_draft <- None;
  state.runtime_lane_remove_armed <- Some "coding";
  check_layout state 14;
  state.runtime_lane_notice <- Some (Lane_write_refused "lane \"coding\" is in use by alpha");
  check_layout state 16;
  state.runtime_lane_remove_armed <- None;
  state.runtime_lane_notice <- None;
  state.runtime_lane_pick <- Some (Pick_new_lane "coding");
  (* A lane being created has no candidates to note, and the catalogue is
     unread here: prompt, divider and the explanation row. *)
  check_layout state 15

let test_a_move_past_either_end_is_no_move () =
  let order = [ "a"; "b"; "c" ] in
  Alcotest.(check (option (list string))) "down" (Some [ "b"; "a"; "c" ])
    (swap_candidates order 0 1);
  Alcotest.(check (option (list string))) "up" (Some [ "a"; "c"; "b" ])
    (swap_candidates order 2 1);
  Alcotest.(check (option (list string))) "past the head" None (swap_candidates order 0 (-1));
  Alcotest.(check (option (list string))) "past the tail" None (swap_candidates order 2 3)

(* Two lanes on the lanes reading: primary is rows 0 and 1, solo is row 2. *)
let lane_state () =
  let state = state () in
  let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
    { rrs_generated_at_iso = "fixture"; rrs_config_path = None;
      rrs_default_runtime_id = Some "a";
      rrs_media_failover = []; rrs_media_failover_declared = [];
      rrs_runtimes = [runtime "a"; runtime "b"; runtime "c"];
      rrs_lanes =
        [{rrl_id = "primary"; rrl_runtime_ids = ["a"; "b"]; rrl_declared = true};
         {rrl_id = "solo"; rrl_runtime_ids = ["c"]; rrl_declared = true}] } in
  (match Masc.Tui_decode.join_runtime_surface ~probe:None ~probe_error:None ~resolved with
   | Ok snapshot -> state.runtime_surface <- Some snapshot
   | Error detail -> Alcotest.fail detail);
  state.runtime_mode <- Runtime_lanes;
  state

let notice_text = function
  | None -> "no line"
  | Some (Lane_write_refused reason) -> "refuse: " ^ reason
  | Some Lane_write_pending -> "pending"

let stale_text state =
  match runtime_lane_stale_lines state with
  | [] -> "fresh"
  | lines -> String.concat " | " lines

let plan_text = function
  | Open_lane_name_field -> "open the name field"
  | Open_lane_rename_field lane -> "rename " ^ lane
  | Arm_lane_removal lane -> "arm " ^ lane
  | Send_lane_write { lane; request; cursor_after } ->
    Printf.sprintf "write %s %s, cursor %s" lane
      (match request with
       | Write_lane_order ids -> "[" ^ String.concat "; " ids ^ "]"
       | Write_lane_removal -> "removal")
      (match cursor_after with Some row -> string_of_int row | None -> "stays")
  | Refuse_lane_edit notice -> notice_text (Some notice)

let expect_plan label state edit expected =
  Alcotest.(check string) label expected (plan_text (plan_runtime_lane_edit state edit))

let drop = Row_edit Drop_candidate
let down = Row_edit (Move_candidate Move_down)
let up = Row_edit (Move_candidate Move_up)
let remove = Row_edit Remove_lane

let test_a_lane_edit_sends_the_whole_order () =
  let state = lane_state () in
  expect_plan "a needs no row" state New_lane "open the name field";
  expect_plan "J on the head" state down "write primary [b; a], cursor 1";
  expect_plan "K on the head" state up "refuse: a is already first in primary";
  state.runtime_cursor <- 1;
  expect_plan "x on the tail" state drop "write primary [a], cursor 0";
  expect_plan "J on the tail" state down "refuse: b is already last in primary";
  state.runtime_cursor <- 2;
  expect_plan "the first D arms" state remove "arm solo";
  state.runtime_lane_remove_armed <- Some "solo";
  expect_plan "the second D removes" state remove "write solo removal, cursor 1";
  state.runtime_lane_remove_armed <- Some "primary";
  expect_plan "a D armed for another lane arms this one" state remove "arm solo";
  state.runtime_cursor <- 3;
  expect_plan "no row under the cursor" state drop
    "refuse: no lane row is under the cursor"

(* Each write is built from the surface's last reading. Until the previous
   write is read back, a write would be built from the order it replaced. *)
let test_a_lane_edit_waits_for_the_previous_write () =
  let busy = "pending" in
  List.iter (fun (phase, write) ->
    let state = lane_state () in
    state.runtime_lane_write <- write;
    expect_plan (phase ^ ": J") state down busy;
    expect_plan (phase ^ ": K on the head is pending, not 'already first'") state up busy;
    expect_plan (phase ^ ": x") state drop busy;
    expect_plan (phase ^ ": the first D still arms") state remove "arm primary";
    state.runtime_lane_remove_armed <- Some "primary";
    expect_plan (phase ^ ": the second D") state remove busy;
    expect_plan (phase ^ ": a still opens the name field") state New_lane
      "open the name field")
    [ "posting", Lane_write_posting;
      "rereading", Lane_write_rereading (Runtime_surface_list, 3) ];
  let state = lane_state () in
  state.runtime_lane_write <- Lane_write_idle;
  expect_plan "idle: J" state down "write primary [b; a], cursor 1"

(* The transitions the async handler makes: [settle_runtime_lane_write] when
   a write answers, [runtime_lane_list_reread] when a list load lands. *)
let test_a_written_list_holds_edits_until_its_reread () =
  let state = lane_state () in
  state.runtime_surface_generation <- 4;
  state.runtime_lane_write <- Lane_write_posting;
  settle_runtime_lane_write state ~written:Runtime_surface_list (Ok ());
  expect_plan "the write answered" state down "pending";
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:4 (Ok ());
  expect_plan "a load that left before the answer" state down "pending";
  runtime_lane_list_reread state ~list:Standalone_lanes_list ~generation:9 (Ok ());
  expect_plan "a load of the other list" state down "pending";
  state.runtime_lane_notice <- Some Lane_write_pending;
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:5 (Ok ());
  expect_plan "the re-read landed" state down "write primary [b; a], cursor 1";
  Alcotest.(check string) "the pending line went with it" "no line"
    (notice_text state.runtime_lane_notice)

(* A standalone lane's slots are read back from the standalone lanes list;
   the Runtime surface landing says nothing about them. *)
let test_a_standalone_write_waits_for_the_standalone_list () =
  let state = lane_state () in
  state.standalone_lanes_generation <- 2;
  state.runtime_surface_generation <- 7;
  state.runtime_lane_write <- Lane_write_posting;
  settle_runtime_lane_write state ~written:Standalone_lanes_list (Ok ());
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:8 (Ok ());
  expect_plan "the Runtime surface landed" state down "pending";
  runtime_lane_list_reread state ~list:Standalone_lanes_list ~generation:3 (Ok ());
  expect_plan "the standalone list landed" state down "write primary [b; a], cursor 1"

let test_a_refused_write_opens_edits_at_once () =
  let state = lane_state () in
  state.runtime_lane_write <- Lane_write_posting;
  settle_runtime_lane_write state ~written:Runtime_surface_list (Error "HTTP 400: no");
  expect_plan "after the refusal" state down "write primary [b; a], cursor 1";
  Alcotest.(check string) "the refusal is drawn" "refuse: HTTP 400: no"
    (notice_text state.runtime_lane_notice)

let test_a_failed_reread_refuses_candidate_edits_with_a_line () =
  let state = lane_state () in
  state.runtime_surface_generation <- 1;
  state.runtime_lane_write <- Lane_write_posting;
  settle_runtime_lane_write state ~written:Runtime_surface_list (Ok ());
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:2
    (Error "HTTP 503: down");
  expect_plan "move is refused" state down
    "refuse: the lane list may be stale; reload it before changing candidates";
  expect_plan "drop is refused" state drop
    "refuse: the lane list may be stale; reload it before changing candidates";
  Alcotest.(check string) "the list is said to be stale"
    "the lane list could not be re-read after the change and may be stale: HTTP 503: down"
    (stale_text state);
  Alcotest.(check string) "the pending line went" "no line"
    (notice_text state.runtime_lane_notice)

let stale_after_503 =
  "the lane list could not be re-read after the change and may be stale: HTTP 503: down"

(* The stale line is about the list, not about a key, so it is not the notice:
   no key, refusal or dismissal reaches it, and only that list loading again
   ends it. *)
let test_a_stale_line_holds_until_its_list_loads () =
  let state = lane_state () in
  state.runtime_surface_generation <- 1;
  state.runtime_lane_write <- Lane_write_posting;
  settle_runtime_lane_write state ~written:Runtime_surface_list (Ok ());
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:2
    (Error "HTTP 503: down");
  dismiss_runtime_lane_notice state;
  Alcotest.(check string) "a view change keeps it" stale_after_503 (stale_text state);
  runtime_lane_list_reread state ~list:Standalone_lanes_list ~generation:3 (Ok ());
  Alcotest.(check string) "the other list loading keeps it" stale_after_503
    (stale_text state);
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:3
    (Error "HTTP 503: still down");
  Alcotest.(check string) "a failed load with no write out keeps it" stale_after_503
    (stale_text state);
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:4 (Ok ());
  Alcotest.(check string) "its list loading ends it" "fresh" (stale_text state)

(* The review's case. A drop's read-back fails, so the list on screen still
   shows the dropped candidate. A refused key then says something of its own
   and a view change dismisses that. The stale line outlives both, and the
   stale order is never sent as a second write. *)
let test_a_refusal_and_a_dismissal_leave_the_stale_line () =
  let state = lane_state () in
  state.runtime_surface_generation <- 1;
  state.runtime_lane_write <- Lane_write_posting;
  settle_runtime_lane_write state ~written:Runtime_surface_list (Ok ());
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:2
    (Error "HTTP 503: down");
  (match plan_runtime_lane_edit state up with
   | Refuse_lane_edit notice -> state.runtime_lane_notice <- Some notice
   | plan -> Alcotest.failf "K on the head: %s" (plan_text plan));
  Alcotest.(check string) "the refusal is drawn"
    "refuse: the lane list may be stale; reload it before changing candidates"
    (notice_text state.runtime_lane_notice);
  Alcotest.(check string) "beside the stale line" stale_after_503 (stale_text state);
  dismiss_runtime_lane_notice state;
  Alcotest.(check string) "the dismissal ended the refusal" "no line"
    (notice_text state.runtime_lane_notice);
  state.runtime_cursor <- 1;
  expect_plan "x cannot write from the stale list" state drop
    "refuse: the lane list may be stale; reload it before changing candidates";
  Alcotest.(check string) "and the stale line is still drawn" stale_after_503
    (stale_text state)

let test_a_new_view_ends_what_a_key_said () =
  let state = lane_state () in
  List.iter (fun notice ->
    state.runtime_lane_notice <- Some notice;
    dismiss_runtime_lane_notice state;
    Alcotest.(check string) (notice_text (Some notice)) "no line"
      (notice_text state.runtime_lane_notice))
    [ Lane_write_refused "HTTP 400: no"; Lane_write_pending ]

(* [R] opens the field on the name the lane has now, so the common edit --
   changing part of it -- starts from what is there rather than from empty. *)
let test_a_rename_opens_the_field_on_the_current_name () =
  let state = lane_state () in
  expect_plan "the lane under the cursor" state (Row_edit Rename_lane) "rename primary";
  state.runtime_cursor <- 2;
  expect_plan "the next lane" state (Row_edit Rename_lane) "rename solo"

let test_lane_keys_parse_to_edits () =
  let parsed key = Option.map (fun edit -> plan_text (plan_runtime_lane_edit (lane_state ()) edit))
      (runtime_lane_edit_of_key key) in
  Alcotest.(check (option string)) "a" (Some "open the name field") (parsed "a");
  Alcotest.(check (option string)) "J" (Some "write primary [b; a], cursor 1") (parsed "J");
  Alcotest.(check (option string)) "D" (Some "arm primary") (parsed "D");
  Alcotest.(check (option string)) "j is the cursor's, not an edit" None (parsed "j")

let test_cli_probe_is_a_note () =
  let detail = "CLI runtimes do not expose an HTTP reachability endpoint" in
  Alcotest.(check bool) "typed CLI exclusion remains informational" true
    (runtime_probe_annotation ~status:Runtime_provider_skipped_cli (Some detail)
     = Some (Runtime_probe_note detail));
  Alcotest.(check string) "human-readable excluded probe status" "CLI not probed"
    (runtime_probe_status_label Runtime_provider_skipped_cli);
  List.iter (fun status ->
    Alcotest.(check bool) "the same words cannot disguise a real failure" true
      (runtime_probe_annotation ~status (Some detail) = Some (Runtime_probe_failure detail)))
    [Runtime_provider_network_error; Runtime_provider_endpoint_not_found;
     Runtime_provider_auth_failed; Runtime_provider_invalid_execution_transport];
  Alcotest.(check bool) "no diagnostic is invented" true
    (runtime_probe_annotation ~status:Runtime_provider_skipped_cli None = None);
  let adc = "Vertex Gemini authenticates with Google Application Default Credentials" in
  Alcotest.(check bool) "a native-auth skip is informational too" true
    (runtime_probe_annotation ~status:Runtime_provider_skipped_native_auth (Some adc)
     = Some (Runtime_probe_note adc));
  Alcotest.(check string) "human-readable native-auth skip" "ADC not probed"
    (runtime_probe_status_label Runtime_provider_skipped_native_auth)

let test_search_follows_the_runtime_mode () =
  let state = state () in
  let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
    { rrs_generated_at_iso = "fixture"; rrs_config_path = None;
      rrs_default_runtime_id = Some "assigned";
      rrs_media_failover = []; rrs_media_failover_declared = [];
      rrs_runtimes = [runtime "unassigned"; runtime "assigned"];
      rrs_lanes =
        [{rrl_id = "lane-only"; rrl_runtime_ids = ["assigned"]; rrl_declared = true}] } in
  let snapshot = match Masc.Tui_decode.join_runtime_surface
      ~probe:None ~probe_error:None ~resolved with
    | Ok snapshot -> snapshot | Error detail -> Alcotest.fail detail in
  state.runtime_surface <- Some snapshot;
  let expect_rows expected =
    Alcotest.(check (option (list string))) "search uses the visible cursor order"
      (Some expected) (surface_row_texts state Runtime);
    match scrolled_surface_rows state Runtime with
    | Some layout -> expect "scroll and search have the same rows" (List.length expected) layout.sc_count
    | None -> Alcotest.fail "runtime list lost its scroll geometry" in
  state.runtime_mode <- Runtime_lanes;
  expect_rows ["lane-only assigned"];
  state.runtime_mode <- Runtime_all;
  expect_rows ["unassigned"; "assigned"];
  Alcotest.(check (option int)) "unassigned runtime is searchable" (Some 1)
    (surface_search_count state Runtime ~query:"unassigned");
  Alcotest.(check (option int)) "hidden lane does not contribute" (Some 0)
    (surface_search_count state Runtime ~query:"lane-only");
  state.runtime_detail_target <- Some (Runtime_catalog_entry {runtime_id = "assigned"});
  Alcotest.(check (option (list string))) "runtime detail has no list cursor" None
    (surface_row_texts state Runtime)

(* Bindings of one model that differ only in reasoning effort share provider,
   model and context, so their ids are the only text that tells them apart.
   At a fixed 24-cell target column both ids below drew as
   [claude_code.claude-sonn…]. *)
let test_picker_target_column_fits_the_longest_id () =
  let effort_pair =
    [ Pick_model { (runtime "claude_code.claude-sonnet-5-low") with ro_model = "claude-sonnet-5" }
    ; Pick_model { (runtime "claude_code.claude-sonnet-5-high") with ro_model = "claude-sonnet-5" }
    ]
  in
  let longest = String.length "claude_code.claude-sonnet-5-high" in
  let target, route = runtime_pick_column_widths ~cols:200 effort_pair in
  expect "wide terminal: the target column holds the longest id" longest target;
  expect "wide terminal: the route column gives up the room"
    (Masc_tui_frame.inner_width ~cols:200
     - runtime_pick_fixed_cells
     - runtime_pick_tail_width ~cols:200 (List.hd effort_pair))
    (target + route);
  let target, route = runtime_pick_column_widths ~cols:80 effort_pair in
  Alcotest.(check bool)
    "narrow terminal: target keeps its floor"
    true
    (target >= runtime_pick_min_column_cells);
  Alcotest.(check bool)
    "narrow terminal: route keeps its floor"
    true
    (route >= runtime_pick_min_column_cells);
  let target, _ = runtime_pick_column_widths ~cols:200 [ Pick_model (runtime "short") ] in
  expect "short ids keep the floor" runtime_pick_min_column_cells target

(* The row is the chrome, the two columns padded to their widths, and the
   facts. Widening one part used to push the rest off the right edge, where
   the frame cut it: a row carrying [effort medium] lost its [default]. Every
   width the picker can pick has to leave the whole row inside the frame. *)
let test_every_row_fits_the_frame () =
  let items =
    [ Pick_model
        { (runtime "claude_code.claude-sonnet-5-high") with
          ro_declared_reasoning_effort = Some Llm_provider.Reasoning_effort.High
        ; ro_is_default = true
        }
    ; Pick_model
        { (runtime "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731") with
          ro_declared_reasoning_effort = Some Llm_provider.Reasoning_effort.Medium
        ; ro_quota_exhausted = true
        }
    ; Pick_model (runtime "short")
    ]
  in
  List.iter
    (fun cols ->
       let target, route = runtime_pick_column_widths ~cols items in
       let widest_tail =
         List.fold_left
           (fun longest item -> max longest (runtime_pick_tail_width ~cols item))
           0
           items
       in
       let row = runtime_pick_fixed_cells + target + route + widest_tail in
       Alcotest.(check bool)
         (Printf.sprintf "%d columns: the row stays inside the frame" cols)
         true
         (row <= Masc_tui_frame.inner_width ~cols))
    [ 80; 100; 120; 160; 200 ]

(* The facts a narrow row drops, and the one it keeps. *)
let test_narrow_rows_keep_the_fact_that_is_said_nowhere_else () =
  let quota_row =
    Pick_model
      { (runtime "claude_code.claude-sonnet-5-high") with
        ro_declared_reasoning_effort = Some Llm_provider.Reasoning_effort.High
      ; ro_quota_exhausted = true
      }
  in
  let texts cols =
    runtime_pick_visible_facts ~cols quota_row
    |> List.map (fun (fact : runtime_pick_fact) -> fact.rpf_text)
  in
  Alcotest.(check (list string))
    "a wide terminal says all three"
    [ "[200k ctx]"; "[effort high]"; "[quota exhausted]" ]
    (texts 200);
  (* The cut point follows the frame, so the test asks what survived rather
     than repeating the arithmetic. *)
  match texts 80 with
  | [ only ] ->
    Alcotest.(check bool) "80 columns keeps the warning" true
      (String.length only >= 6 && String.equal (String.sub only 0 6) "[quota");
    expect "the kept fact spends the whole budget"
      (runtime_pick_tail_budget ~cols:80)
      (Masc_tui_message_layout.display_width only)
  | facts ->
    Alcotest.failf "80 columns kept %d facts, wanted the warning alone"
      (List.length facts)

(* The reasoning step is the last four cells of the id, and a head-keeping cut
   drops exactly those: at 80 columns both bindings drew as
   [claude_code.claude-sonn…]. *)
let test_narrow_target_column_still_tells_the_variants_apart () =
  let pair =
    [ Pick_model (runtime "claude_code.claude-sonnet-5-low")
    ; Pick_model (runtime "claude_code.claude-sonnet-5-high")
    ]
  in
  let target, _ = runtime_pick_column_widths ~cols:80 pair in
  let drawn id = Masc_tui_message_layout.fit_middle target id in
  let low = drawn "claude_code.claude-sonnet-5-low" in
  let high = drawn "claude_code.claude-sonnet-5-high" in
  Alcotest.(check bool) "the two ids do not draw the same" true (not (String.equal low high));
  Alcotest.(check bool) "the step survives the cut" true
    (Masc_tui_message_layout.display_width high = target)

(* The slot editor's rows are the lane's declared order with each slot marked
   by whether publication admitted it. A rejected slot keeps its place: the
   admitted list alone cannot say where that is, and the editor moves and
   drops by position. *)
let standalone_lane ~lane_id ~declared ~admitted : Masc.Tui_decode.standalone_lane =
  { Masc.Tui_decode.sl_lane_id = lane_id
  ; sl_label = lane_id
  ; sl_purpose = None
  ; sl_required = false
  ; sl_status = Masc.Tui_decode.Standalone_idle
  ; sl_configuration_state = Masc.Tui_decode.Lane_ready
  ; sl_jev = None
  ; sl_admitted_slots = admitted
  ; sl_cli_slots = []
  ; sl_dropped_slots =
      List.filter (fun slot -> not (List.mem slot admitted)) declared
  ; sl_declared_slots = declared
  ; sl_admission_error = None
  ; sl_retained_run_count = 0
  ; sl_running_count = 0
  ; sl_succeeded_count = 0
  ; sl_failed_count = 0
  ; sl_cancelled_count = 0
  ; sl_last_started_at = None
  ; sl_last_terminal_at = None
  ; sl_last_outcome = None
  ; sl_p50_elapsed_s = None
  ; sl_selected_slots = []
  }

let slot_editor_state ?(cursor = 0) ?(declared = [ "a"; "rejected"; "b" ])
      ?(admitted = [ "a"; "b" ]) () =
  let state = state () in
  state.standalone_lanes <-
    Some
      { Masc.Tui_decode.sls_observed_at_unix = 0.
      ; sls_exact_run_projection_count = 0
      ; sls_exact_run_source_total = 0
      ; sls_exact_run_projection_truncated = false
      ; sls_lanes = [ standalone_lane ~lane_id:"librarian_exact" ~declared ~admitted ]
      };
  state.slot_editor <-
    Some { se_target = Exact_lane_slots "librarian_exact"; se_cursor = cursor };
  state

let slot_plan_text = function
  | Send_slot_write { target; slot; request; cursor_after } ->
    Printf.sprintf "%s %s %s, cursor %s" (slot_editor_target_name target)
      (match request with
       | Drop_declared_slot -> "drop"
       | Move_declared_slot Move_up -> "up"
       | Move_declared_slot Move_down -> "down"
       | Write_route_order order -> "order [" ^ String.concat "; " order ^ "]")
      slot
      (match cursor_after with Some row -> string_of_int row | None -> "stays")
  | Refuse_slot_edit notice -> notice_text (Some notice)

let test_the_slot_editor_edits_the_declared_order () =
  let state = slot_editor_state () in
  Alcotest.(check (list string)) "a rejected slot keeps its place"
    [ "a (admitted)"; "rejected (declared)"; "b (admitted)" ]
    (List.map
       (fun row ->
          Printf.sprintf "%s (%s)" row.sr_slot
            (if row.sr_admitted then "admitted" else "declared"))
       (slot_editor_rows state));
  Alcotest.(check string) "the head cannot move up"
    "refuse: a is already first in librarian_exact"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_up)));
  Alcotest.(check string) "the head moves down"
    "librarian_exact down a, cursor 1"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)));
  let state = slot_editor_state ~cursor:1 () in
  Alcotest.(check string) "a rejected slot is dropped like any other"
    "librarian_exact drop rejected, cursor stays"
    (slot_plan_text (plan_slot_edit state Drop_slot));
  let state = slot_editor_state ~cursor:2 () in
  Alcotest.(check string) "dropping the last row moves the cursor up"
    "librarian_exact drop b, cursor 1"
    (slot_plan_text (plan_slot_edit state Drop_slot))

let test_the_slot_editor_keeps_the_last_slot () =
  let state = slot_editor_state ~declared:[ "only" ] ~admitted:[ "only" ] () in
  Alcotest.(check string) "the lane needs one slot"
    "refuse: only is the last slot of librarian_exact; an exact-output lane needs at least one"
    (slot_plan_text (plan_slot_edit state Drop_slot));
  (* A write already out is the other refusal both editors share: the writer
     reads the declaration, but a second write sent before the first is read
     back would be planned against rows the first replaced. *)
  state.runtime_lane_write <- Lane_write_posting;
  Alcotest.(check string) "a write already out holds the next edit"
    "pending"
    (slot_plan_text (plan_slot_edit state Drop_slot))

let test_slot_editor_keys_parse () =
  Alcotest.(check (list string)) "the editor's own keys"
    [ "drop"; "down"; "up"; "none" ]
    (List.map
       (fun key ->
          match slot_edit_of_key key with
          | Some Drop_slot -> "drop"
          | Some (Move_slot Move_down) -> "down"
          | Some (Move_slot Move_up) -> "up"
          | None -> "none")
       [ "x"; "J"; "K"; "a" ])

(* [runtime].media_failover is written as a whole list -- the routing endpoint
   has no per-entry action for it -- so the editor reads and writes the file's
   declared order while marking entries absent from the active fleet. *)
let media_failover_state
    ?(cursor = 0)
    ?(admitted = [ "a"; "b" ])
    ?declared
    ()
  =
  let declared = Option.value declared ~default:admitted in
  let state = state () in
  let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
    { rrs_generated_at_iso = "fixture"; rrs_config_path = None;
      rrs_default_runtime_id = Some "a";
      rrs_media_failover = admitted; rrs_media_failover_declared = declared;
      rrs_runtimes = [runtime "a"; runtime "b"; runtime "c"];
      rrs_lanes = [{rrl_id = "solo"; rrl_runtime_ids = ["c"]; rrl_declared = true}] } in
  (match Masc.Tui_decode.join_runtime_surface ~probe:None ~probe_error:None ~resolved with
   | Ok snapshot -> state.runtime_surface <- Some snapshot
   | Error detail -> Alcotest.fail detail);
  state.slot_editor <- Some { se_target = Media_failover_slots; se_cursor = cursor };
  state

let test_the_route_editor_writes_the_whole_order () =
  let state = media_failover_state () in
  Alcotest.(check (list string)) "the route's entries, in call order"
    [ "a"; "b" ]
    (List.map (fun row -> row.sr_slot) (slot_editor_rows state));
  Alcotest.(check string) "a move sends the reordered list"
    "[runtime].media_failover order [b; a] a, cursor 1"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)));
  Alcotest.(check string) "a drop sends what is left"
    "[runtime].media_failover order [b] a, cursor stays"
    (slot_plan_text (plan_slot_edit state Drop_slot));
  (* An empty route is a configuration, not a broken one: no vision fleet. The
     exact-lane editor refuses its last slot; this one does not. *)
  let state = media_failover_state ~admitted:[ "only" ] () in
  Alcotest.(check string) "the last entry may go"
    "[runtime].media_failover order [] only, cursor stays"
    (slot_plan_text (plan_slot_edit state Drop_slot))

let test_the_route_editor_edits_a_partly_unresolved_route () =
  let state =
    media_failover_state
      ~cursor:1
      ~admitted:[ "a"; "b" ]
      ~declared:[ "a"; "gone.model"; "b" ]
      ()
  in
  Alcotest.(check (list string)) "the rejected entry keeps its declared position"
    [ "a (admitted)"; "gone.model (declared)"; "b (admitted)" ]
    (List.map
       (fun row ->
          Printf.sprintf "%s (%s)" row.sr_slot
            (if row.sr_admitted then "admitted" else "declared"))
       (slot_editor_rows state));
  Alcotest.(check string) "the rejected entry can be removed"
    "[runtime].media_failover order [a; b] gone.model, cursor stays"
    (slot_plan_text (plan_slot_edit state Drop_slot));
  Alcotest.(check string) "the rejected entry can be reordered"
    "[runtime].media_failover order [a; b; gone.model] gone.model, cursor 2"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)))

(* A lane no [runtime.lanes.<id>] table declares reaches this surface as one
   candidate in first position -- the same shape a declared lane holding one
   candidate has. The row fact is the only thing that separates them. *)
let fact_text = function
  | Lane_undeclared -> "runtime, not a declared lane"
  | Lane_single_candidate -> "single candidate"
  | Lane_head -> "head"
  | Lane_fallback position -> Printf.sprintf "fallback #%d" position

let test_an_undeclared_lane_is_not_read_as_a_single_candidate () =
  let state = state () in
  let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
    { rrs_generated_at_iso = "fixture"; rrs_config_path = None;
      rrs_default_runtime_id = Some "a";
      rrs_media_failover = []; rrs_media_failover_declared = [];
      rrs_runtimes = [runtime "a"; runtime "b"; runtime "c"];
      rrs_lanes =
        [{rrl_id = "solo"; rrl_runtime_ids = ["a"]; rrl_declared = true};
         {rrl_id = "b"; rrl_runtime_ids = ["b"]; rrl_declared = false};
         {rrl_id = "pair"; rrl_runtime_ids = ["c"; "a"]; rrl_declared = true}] } in
  (match Masc.Tui_decode.join_runtime_surface ~probe:None ~probe_error:None ~resolved with
   | Ok snapshot -> state.runtime_surface <- Some snapshot
   | Error detail -> Alcotest.fail detail);
  (match state.runtime_surface with
   | None -> Alcotest.fail "the surface did not join"
   | Some snapshot ->
     Alcotest.(check (list string)) "one fact per row"
       ["single candidate"; "runtime, not a declared lane"; "head"; "fallback #1"]
       (List.map (fun row -> fact_text (runtime_lane_fact_of_row row))
          snapshot.Masc.Tui_decode.rss_candidates));
  state.runtime_cursor <- 1;
  expect_plan "R refuses the runtime row before opening a field" state
    (Row_edit Rename_lane)
    "refuse: b is a runtime, not a declared lane; there is no table to rename";
  expect_plan "D refuses the runtime row before arming" state remove
    "refuse: b is a runtime, not a declared lane; there is no table to remove"

(* An undeclared lane carries the id of the runtime it rests on, so offering
   it as a lane put the same assignment in the picker twice -- once labelled a
   lane that walks, once the runtime it actually is. *)
let test_the_picker_offers_only_declared_lanes () =
  let state = state () in
  state.runtime_lanes <-
    [{rrl_id = "coding"; rrl_runtime_ids = ["a"; "b"]; rrl_declared = true};
     {rrl_id = "b"; rrl_runtime_ids = ["b"]; rrl_declared = false}];
  state.runtime_catalog <- [runtime "a"; runtime "b"];
  Alcotest.(check (list string)) "what the picker offers"
    ["lane coding"; "model a"; "model b"]
    (List.map
       (function
         | Pick_lane lane -> "lane " ^ lane.Masc.Tui_decode.rrl_id
         | Pick_model model -> "model " ^ model.Masc.Tui_decode.ro_id)
        (runtime_picker_items state))

let () = Alcotest.run "runtime list geometry"
  ["operator states", [
      Alcotest.test_case "picker and failures reserve footer space" `Quick test_picker_and_refusal_keep_footer_space;
      Alcotest.test_case "empty picker explanation" `Quick test_empty_picker_keeps_its_explanation;
      Alcotest.test_case "lane prompt reserves footer space" `Quick test_lane_prompt_keeps_footer_space;
      Alcotest.test_case "a move past either end is no move" `Quick test_a_move_past_either_end_is_no_move;
      Alcotest.test_case "a lane edit sends the whole order" `Quick test_a_lane_edit_sends_the_whole_order;
      Alcotest.test_case "a lane edit waits for the previous write" `Quick test_a_lane_edit_waits_for_the_previous_write;
      Alcotest.test_case "lane keys parse to edits" `Quick test_lane_keys_parse_to_edits;
      Alcotest.test_case "a rename opens the field on the current name" `Quick
        test_a_rename_opens_the_field_on_the_current_name;
      Alcotest.test_case "a written list holds edits until its re-read" `Quick test_a_written_list_holds_edits_until_its_reread;
      Alcotest.test_case "a standalone write waits for the standalone list" `Quick test_a_standalone_write_waits_for_the_standalone_list;
      Alcotest.test_case "a refused write opens edits at once" `Quick test_a_refused_write_opens_edits_at_once;
      Alcotest.test_case "a failed re-read refuses candidate edits with a line" `Quick test_a_failed_reread_refuses_candidate_edits_with_a_line;
      Alcotest.test_case "a stale line holds until its list loads" `Quick test_a_stale_line_holds_until_its_list_loads;
      Alcotest.test_case "a refusal and a dismissal leave the stale line" `Quick test_a_refusal_and_a_dismissal_leave_the_stale_line;
      Alcotest.test_case "a new view ends what a key said" `Quick test_a_new_view_ends_what_a_key_said;
      Alcotest.test_case "CLI probe is informational" `Quick test_cli_probe_is_a_note;
      Alcotest.test_case "search follows Runtime mode and cursor order" `Quick test_search_follows_the_runtime_mode;
      Alcotest.test_case "picker target column fits the longest id" `Quick
        test_picker_target_column_fits_the_longest_id;
      Alcotest.test_case "every picker row fits the frame" `Quick
        test_every_row_fits_the_frame;
      Alcotest.test_case "narrow rows keep the quota warning" `Quick
        test_narrow_rows_keep_the_fact_that_is_said_nowhere_else;
      Alcotest.test_case "narrow target column tells the variants apart" `Quick
        test_narrow_target_column_still_tells_the_variants_apart;
      Alcotest.test_case "the slot editor edits the declared order" `Quick
        test_the_slot_editor_edits_the_declared_order;
      Alcotest.test_case "the slot editor keeps the last slot" `Quick
        test_the_slot_editor_keeps_the_last_slot;
      Alcotest.test_case "slot editor keys parse" `Quick
        test_slot_editor_keys_parse;
      Alcotest.test_case "the route editor writes the whole order" `Quick
        test_the_route_editor_writes_the_whole_order;
      Alcotest.test_case "the route editor edits a partly unresolved route" `Quick
        test_the_route_editor_edits_a_partly_unresolved_route;
      Alcotest.test_case "an undeclared lane is not a single candidate" `Quick
        test_an_undeclared_lane_is_not_read_as_a_single_candidate;
      Alcotest.test_case "the picker offers only declared lanes" `Quick
        test_the_picker_offers_only_declared_lanes]]
