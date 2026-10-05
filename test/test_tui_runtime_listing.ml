open Masc_tui_types

let expect label wanted actual = Alcotest.(check int) label wanted actual

let runtime id : Masc.Tui_decode.runtime_option =
  { ro_id = id; ro_provider = "provider"; ro_provider_id = "provider"; ro_model = "model";
    ro_exact_slot_group = Exact_http_slots;
    ro_effective_max_context = 200000; ro_max_context_source = Runtime_context_capability;
    ro_max_output_tokens = Some 8192; ro_declared_reasoning_effort = None; ro_is_local = false;
    ro_is_default = false;
    ro_quota_exhausted = false; ro_quota_resets_at = None; ro_quota_scope = None; ro_quota_scope_id = None;
    ro_rate_limited = false; ro_rate_limit_resets_at = None }

let state () = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

(* The width these checks read at. Wide enough that the authority row -- two
   clauses while no runtime surface has loaded -- stays one row, so the counts
   below are about the rows each check is named for. *)
let check_cols = 140

let check_layout state expected =
  expect "rendering chrome" expected
    (runtime_surface_listing_chrome ~rows:100 ~cols:check_cols state);
  match runtime_scrolled ~rows:100 ~cols:check_cols state with
  | None -> Alcotest.fail "runtime list has no scroll geometry"
  | Some layout -> expect "keyboard shares rendering chrome" expected layout.sc_chrome

(* Press these keys in the open picker, over the same rows the key handler
   reads. *)
let press state keys =
  match state.runtime_lane_pick with
  | None -> Alcotest.fail "no picker is open"
  | Some (pick, list) ->
      let _, _, catalog = runtime_picker_rows state pick in
      let moved =
      List.fold_left
        (fun list key ->
          match
            Masc_tui_pick_list.action_of_key ~close_keys:[] list key
          with
          | None -> Alcotest.failf "key %S is not the picker's" key
          | Some action -> (
              match
                Masc_tui_pick_list.apply ~page:runtime_picker_page
                  ~label:(runtime_picker_label_for pick) catalog list action
              with
              | Masc_tui_pick_list.Stay list -> list
              | Masc_tui_pick_list.Chosen _ | Masc_tui_pick_list.Dismissed ->
                  Alcotest.failf "key %S left the picker" key))
        list keys
      in
      state.runtime_lane_pick <- Some (pick, moved)

let test_schema_less_client_is_refused_only_for_exact_lane () =
  let muse = { (runtime "muse.fixture") with
    ro_exact_slot_group = Masc.Tui_decode.Exact_output_unsupported } in
  (match runtime_pick_availability (Pick_exact_lane Standalone_lane.Verifier) muse with
   | Pick_refused _ -> ()
   | Pick_available -> Alcotest.fail "schema-less Muse client was offered to an exact lane");
  (match runtime_pick_availability (Pick_conversation_lane "primary") muse with
   | Pick_available -> ()
   | Pick_refused _ -> Alcotest.fail "normal Keeper routing must remain available")

let test_picker_and_refusal_keep_footer_space () =
  let state = state () in
  state.runtime_catalog <- [runtime "a"; runtime "b"; runtime "c"];
  check_layout state 12;
  open_runtime_lane_pick state (Pick_conversation_lane "primary");
  (* Three choices, prompt and divider consume five additional rows. *)
  check_layout state 17;
  state.runtime_lane_notice <- Some (Lane_write_refused "route write rejected");
  check_layout state 19;
  state.runtime_surface_error <- Some "resolved unavailable";
  check_layout state 21;
  (* The cursor on the last runtime keeps the window a full page: the rows
     the listing gave up stay given up while the cursor moves. *)
  press state [ "end" ];
  check_layout state 21;
  state.runtime_lane_pick <- None;
  check_layout state 16

let test_empty_picker_keeps_its_explanation () =
  let state = state () in
  open_runtime_lane_pick state (Pick_conversation_lane "primary");
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
  open_runtime_lane_pick state (Pick_new_lane "coding");
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
    { rrs_usage = Error "not reported"; rrs_generated_at_iso = "fixture"; rrs_config_path = None;
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
  | Some Lane_write_confirmed -> "saved and reloaded"

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
    expect_plan (phase ^ ": R cannot open a rename field") state
      (Row_edit Rename_lane) busy;
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
  Alcotest.(check string) "success waits for the saved order reload" "saved and reloaded"
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

(* The authority row names the file this screen is a reading of. Drawn as one
   line it asked for 143 cells with no fleet on screen and about 197 with one,
   while the frame gives 96 at 100 columns -- so the clause it lost was the
   config path, and a cut path names a file that does not exist (#36497). *)
let authority_state () =
  let state = state () in
  let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
    { rrs_usage = Error "not reported"; rrs_generated_at_iso = "fixture";
      rrs_config_path = Some "/Users/operator/work/.masc/config/runtime.toml";
      rrs_default_runtime_id = Some "assigned";
      rrs_media_failover = []; rrs_media_failover_declared = [];
      rrs_runtimes = [runtime "assigned"];
      rrs_lanes =
        [{rrl_id = "primary"; rrl_runtime_ids = ["assigned"]; rrl_declared = true}] } in
  let snapshot = match Masc.Tui_decode.join_runtime_surface
      ~probe:None ~probe_error:None ~resolved with
    | Ok snapshot -> snapshot | Error detail -> Alcotest.fail detail in
  state.runtime_surface <- Some snapshot;
  state

let test_the_authority_row_spells_its_config_path_whole () =
  let state = authority_state () in
  let path = "/Users/operator/work/.masc/config/runtime.toml" in
  let rows_at cols = runtime_authority_rows ~cols state in
  List.iter
    (fun cols ->
      let rows = rows_at cols in
      let inner = Masc_tui_frame.inner_width ~cols in
      List.iter
        (fun row ->
          Alcotest.(check bool)
            (Printf.sprintf "row fits the frame at %d columns: %S" cols row)
            true
            (Masc_tui_message_layout.display_width row <= inner))
        rows;
      Alcotest.(check bool)
        (Printf.sprintf "the config path is whole at %d columns" cols)
        true
        (List.exists
           (fun row ->
             let needle = path in
             let n = String.length needle and h = String.length row in
             let rec seek i = i + n <= h && (String.sub row i n = needle || seek (i + 1)) in
             seek 0)
           rows))
    [ 80; 100; 110; 120; 140; 180 ];
  (* A wider frame spends fewer rows on the same sentence, and the widest fits
     it on one. Without this the packing could return one clause per row at
     every width and every check above would still pass. *)
  Alcotest.(check int) "one row once the frame is wide enough" 1
    (List.length (rows_at 260));
  Alcotest.(check bool) "a narrow frame spends more rows than a wide one" true
    (List.length (rows_at 80) > List.length (rows_at 260));
  (* The budget follows the rows. Counting one authority row at every width put
     the footer past the frame's last row exactly when the sentence wrapped.
     The selected row's summary is chrome too and wraps at a narrow width, so
     the relation counts its rows as well; leaving them out failed the check
     once the summary wrapped at 100 columns. *)
  let selection_rows_at cols =
    List.length (runtime_selection_summary_for_viewport ~rows:100 ~cols state) in
  Alcotest.(check int) "the chrome count follows the rows drawn"
    (runtime_surface_listing_chrome ~rows:100 ~cols:260 state
     + List.length (rows_at 100) - 1
     + (selection_rows_at 100 - selection_rows_at 260))
    (runtime_surface_listing_chrome ~rows:100 ~cols:100 state);
  match runtime_scrolled ~rows:100 ~cols:100 state with
  | None -> Alcotest.fail "runtime list has no scroll geometry"
  | Some layout ->
      Alcotest.(check int) "the keys move through the drawing's count"
        (runtime_surface_listing_chrome ~rows:100 ~cols:100 state) layout.sc_chrome

let test_search_follows_the_runtime_mode () =
  let state = state () in
  let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
    { rrs_usage = Error "not reported"; rrs_generated_at_iso = "fixture"; rrs_config_path = None;
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
      (Some expected) (Masc_tui_surface_search.surface_row_texts state Runtime);
    match runtime_scrolled ~rows:100 ~cols:check_cols state with
    | Some layout -> expect "scroll and search have the same rows" (List.length expected) layout.sc_count
    | None -> Alcotest.fail "runtime list lost its scroll geometry" in
  state.runtime_mode <- Runtime_lanes;
  expect_rows ["lane-only assigned"];
  state.runtime_mode <- Runtime_all;
  expect_rows ["unassigned"; "assigned"];
  Alcotest.(check (option int)) "unassigned runtime is searchable" (Some 1)
    (Masc_tui_surface_search.surface_search_count state Runtime ~query:"unassigned");
  Alcotest.(check (option int)) "hidden lane does not contribute" (Some 0)
    (Masc_tui_surface_search.surface_search_count state Runtime ~query:"lane-only");
  state.runtime_detail_target <- Some (Runtime_catalog_entry {runtime_id = "assigned"});
  Alcotest.(check (option (list string))) "runtime detail has no list cursor" None
    (Masc_tui_surface_search.surface_row_texts state Runtime)

(* Opening a detail, then receiving a reordered listing, must not turn an
   Enter/Right press in the reader into a selection of the hidden cursor. *)
let test_runtime_detail_keeps_its_owner () =
  let snapshot ids =
    let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
      { rrs_usage = Error "not reported"; rrs_generated_at_iso = "fixture"; rrs_config_path = None;
        rrs_default_runtime_id = None;
        rrs_media_failover = []; rrs_media_failover_declared = [];
        rrs_runtimes = List.map runtime ids;
        rrs_lanes =
          (match ids with
           | [] -> []
           | _ -> [{rrl_id = "lane"; rrl_runtime_ids = ids; rrl_declared = true}]) }
    in
    match Masc.Tui_decode.join_runtime_surface ~probe:None ~probe_error:None ~resolved with
    | Ok snapshot -> snapshot
    | Error detail -> Alcotest.fail detail
  in
  List.iter
    (fun mode ->
      let state = state () in
      state.view <- Runtime;
      state.runtime_mode <- mode;
      state.runtime_surface <- Some (snapshot ["first"; "second"]);
      state.runtime_cursor <- 1;
      open_runtime_row_detail state;
      let expected =
        match mode with
        | Runtime_lanes ->
            Runtime_lane_candidate {lane_id = "lane"; runtime_id = "second"}
        | Runtime_all -> Runtime_catalog_entry {runtime_id = "second"}
      in
      Alcotest.(check bool) "open captures the selected identity" true
        (state.runtime_detail_target = Some expected);
      state.runtime_detail_scroll <- 7;
      state.runtime_surface <- Some (snapshot ["second"; "first"]);
      open_runtime_row_detail state;
      Alcotest.(check bool) "reordered hidden cursor cannot retarget a reader" true
        (state.runtime_detail_target = Some expected);
      expect "repeated open preserves reading position" 7 state.runtime_detail_scroll;
      state.runtime_detail_target <- Some Runtime_routes;
      open_runtime_row_detail state;
      Alcotest.(check bool) "route document remains the active reading" true
        (state.runtime_detail_target = Some Runtime_routes);
      expect "route document preserves reading position" 7 state.runtime_detail_scroll;
      state.runtime_detail_target <- None;
      state.runtime_surface <- Some (snapshot []);
      open_runtime_row_detail state;
      Alcotest.(check bool) "empty listing does not invent a target" true
        (state.runtime_detail_target = None);
      state.runtime_surface <- Some (snapshot ["second"; "first"]);
      open_runtime_row_detail state;
      let expected =
        match mode with
        | Runtime_lanes -> Runtime_lane_candidate {lane_id = "lane"; runtime_id = "first"}
        | Runtime_all -> Runtime_catalog_entry {runtime_id = "first"}
      in
      Alcotest.(check bool) "after returning to list the new selection opens" true
        (state.runtime_detail_target = Some expected);
      expect "new reading starts at top" 0 state.runtime_detail_scroll)
    [Runtime_lanes; Runtime_all]

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
    [ 40; 60; 80; 100; 120; 160; 200 ]

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

(* A rate limit is its own fact, not a spelling of the quota window: the row
   says which refusal it is, and a lane row counts the candidates that hold
   either. *)
let test_rate_limit_is_said_on_model_and_lane_rows () =
  let limited = { (runtime "a") with ro_rate_limited = true } in
  let quota = { (runtime "b") with ro_quota_exhausted = true } in
  let clear = runtime "c" in
  let texts item =
    runtime_pick_visible_facts ~cols:200 item
    |> List.map (fun (fact : runtime_pick_fact) -> fact.rpf_text)
  in
  Alcotest.(check (list string)) "a rate-limited model row says so"
    [ "[200k ctx]"; "[rate limited]" ]
    (texts (Pick_model limited));
  Alcotest.(check (list string)) "a clear model row says neither"
    [ "[200k ctx]" ] (texts (Pick_model clear));
  let both = { limited with ro_quota_exhausted = true } in
  Alcotest.(check (list string)) "80 columns retain both refusals"
    [ "[quota + rate]" ]
    (runtime_pick_visible_facts ~cols:80 (Pick_model both)
     |> List.map (fun (fact : runtime_pick_fact) -> fact.rpf_text));
  let lane candidates =
    Pick_lane
      ( { rrl_id = "coding"; rrl_runtime_ids = List.map (fun (o : Masc.Tui_decode.runtime_option) -> o.ro_id) candidates;
          rrl_declared = true }
      , candidates )
  in
  Alcotest.(check (list string)) "a lane counts quota and rate limit alike"
    [ "(3 hops)"; "[2 of 3 limited]" ]
    (texts (lane [ limited; quota; clear ]));
  Alcotest.(check (list string)) "a lane with nothing refusing adds nothing"
    [ "(1 hops)" ] (texts (lane [ clear ]))

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
let standalone_lane ?(declared_cli = []) ?(admitted_cli = [])
    ~(lane : Standalone_lane.t) ~declared ~admitted () : Masc.Tui_decode.standalone_lane =
  { Masc.Tui_decode.sl_lane = lane
  ; sl_label = Standalone_lane.to_id lane
  ; sl_purpose = None
  ; sl_required = false
  ; sl_status = Masc.Tui_decode.Standalone_idle
  ; sl_configuration_state = Masc.Tui_decode.Lane_ready
  ; sl_jev = None
  ; sl_admitted_slots = admitted
  ; sl_cli_slots = admitted_cli
  ; sl_dropped_slots =
      List.filter (fun slot -> not (List.mem slot admitted)) declared
  ; sl_declared_slots = declared
  ; sl_declared_cli_slots = declared_cli
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
  ; sl_runs_without_slot =
      { Tui_decode.slws_vendor_system_one = 0; slws_server_restarted = 0; slws_no_slot = 0 }
  }

let slot_editor_state ?(cursor = 0) ?(declared = [ "a"; "rejected"; "b" ])
      ?(admitted = [ "a"; "b" ]) ?(declared_cli = []) ?(admitted_cli = []) () =
  let state = state () in
  state.standalone_lanes <-
    Some
      { Masc.Tui_decode.sls_observed_at_unix = 0.
      ; sls_exact_run_projection_count = 0
      ; sls_exact_run_source_total = 0
      ; sls_exact_run_projection_truncated = false
      ; sls_lanes =
          [ standalone_lane ~lane:Standalone_lane.Librarian ~declared ~admitted
              ~declared_cli ~admitted_cli () ]
      };
  open_slot_editor state (Exact_lane_slots Standalone_lane.Librarian);
  select_slot_editor_row state cursor;
  state

let slot_plan_text = function
  | Send_slot_write { target; slot; request } ->
    Printf.sprintf "%s %s %s" (slot_editor_target_name target)
      (match request with
       | Drop_declared_slot -> "drop"
       | First_declared_slot -> "first in group"
       | Move_declared_slot Move_up -> "up"
       | Move_declared_slot Move_down -> "down"
       | Write_route_order order -> "order [" ^ String.concat "; " order ^ "]")
      slot
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
    "librarian_exact down a"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)));
  let state = slot_editor_state ~cursor:1 () in
  Alcotest.(check string) "a rejected slot is dropped like any other"
    "librarian_exact drop rejected"
    (slot_plan_text (plan_slot_edit state Drop_slot));
  let state = slot_editor_state ~cursor:2 () in
  Alcotest.(check string) "dropping the last row addresses its identity"
    "librarian_exact drop b"
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

let test_the_slot_editor_edits_cli_slots_after_http () =
  let state = slot_editor_state ~cursor:1 ~declared:[ "http" ]
      ~admitted:[ "http" ] ~declared_cli:[ "cli-a"; "cli-rejected"; "cli-b" ]
      ~admitted_cli:[ "cli-a"; "cli-b" ] () in
  Alcotest.(check (list string)) "both source arrays are visible in execution order"
    [ "http HTTP"; "cli-a CLI"; "cli-rejected CLI"; "cli-b CLI" ]
    (List.map (fun row ->
       row.sr_slot ^ " " ^
       (match row.sr_kind with Catalog_slot -> "HTTP"
        | Official_client_slot -> "CLI" | Media_route_slot -> "route"))
       (slot_editor_rows state));
  Alcotest.(check bool) "rejected CLI stays in its declared position" false
    (List.nth (slot_editor_rows state) 2).sr_admitted;
  Alcotest.(check string) "CLI row moves within CLI array"
    "librarian_exact down cli-a"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)));
  Alcotest.(check string) "HTTP/CLI boundary explains execution order"
    "refuse: HTTP slots run first; CLI slots are the fallback after HTTP exhaustion. Reorder within a group"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_up)));
  select_slot_editor_row state 2;
  Alcotest.(check string) "rejected CLI can be dropped"
    "librarian_exact drop cli-rejected"
    (slot_plan_text (plan_slot_edit state Drop_slot))

(* The same snapshot replacement and reconciliation used by async read-back.
   Test selected destinations, not only the ordinal rendered beside them. *)
let test_slot_selection_survives_refresh () =
  let cases =
    [ Catalog_slot, true; Catalog_slot, false;
      Official_client_slot, true; Official_client_slot, false ]
  in
  List.iter (fun (kind, admitted) ->
    let http, cli =
      match kind with
      | Catalog_slot -> ["before"; "selected"; "after"], ["selected"]
      | Official_client_slot -> ["selected"], ["before"; "selected"; "after"]
      | Media_route_slot -> assert false
    in
    let state = slot_editor_state ~declared:http ~declared_cli:cli
        ~admitted:(if admitted then http else [])
        ~admitted_cli:(if admitted then cli else [])
        ~cursor:(if kind = Catalog_slot then 1 else 2) () in
    let refresh http cli =
      state.standalone_lanes <- Some
        { sls_observed_at_unix = 1.; sls_exact_run_projection_count = 0;
          sls_exact_run_source_total = 0; sls_exact_run_projection_truncated = false;
          sls_lanes = [standalone_lane ~lane:Standalone_lane.Librarian
            ~declared:http ~declared_cli:cli
            ~admitted:(if admitted then http else [])
            ~admitted_cli:(if admitted then cli else []) ()] };
      reconcile_slot_editor_selection state
    in
    let check_selected index =
      Alcotest.(check (option int)) "render position follows identity" (Some index)
        (slot_editor_cursor_index state);
      (match slot_editor_cursor_row state with
       | None -> Alcotest.fail "config action lost selected slot"
       | Some row ->
         Alcotest.(check string) "config slot" "selected" row.sr_slot;
         Alcotest.(check bool) "config kind" true (row.sr_kind = kind);
         Alcotest.(check bool) "admission is independent of identity" admitted row.sr_admitted);
      List.iter (fun edit ->
        match plan_slot_edit state edit with
        | Send_slot_write { slot; target; _ } ->
          Alcotest.(check string) "write still names selection" "selected" slot;
          Alcotest.(check bool) "write stays on original lane" true
            (target = Exact_lane_slots Standalone_lane.Librarian)
        | Refuse_slot_edit _ -> Alcotest.fail "selected middle row should be editable")
        [Drop_slot; Move_slot Move_up; Move_slot Move_down]
    in
    (* Insert before, then reorder within the selected group. An identical
       spelling in the other group must never become the selected row. *)
    (match kind with
     | Catalog_slot -> refresh ["inserted"; "before"; "selected"; "after"] cli; check_selected 2;
       refresh ["after"; "selected"; "before"; "inserted"] cli; check_selected 1;
       refresh ["after"; "before"] cli
     | Official_client_slot -> refresh ["inserted"; "selected"] ["before"; "selected"; "after"]; check_selected 3;
       refresh ["selected"] ["after"; "selected"; "before"]; check_selected 2;
       refresh ["selected"] ["after"; "before"]
     | Media_route_slot -> assert false);
    Alcotest.(check bool) "removal disables config" true
      (Option.is_none (slot_editor_cursor_row state));
    List.iter (fun edit ->
      match plan_slot_edit state edit with
      | Refuse_slot_edit _ -> ()
      | Send_slot_write _ -> Alcotest.fail "removed selection wrote a neighbour")
      [Drop_slot; Move_slot Move_up; Move_slot Move_down];
    refresh http cli;
    Alcotest.(check bool) "reappearance does not silently reselect" true
      (Option.is_none (slot_editor_cursor_row state));
    navigate_slot_editor state Move_down;
    Alcotest.(check (option int)) "explicit navigation restores selection" (Some 0)
      (slot_editor_cursor_index state);
    state.standalone_lanes <- Some
      { sls_observed_at_unix = 2.; sls_exact_run_projection_count = 0;
        sls_exact_run_source_total = 0; sls_exact_run_projection_truncated = false;
        sls_lanes = [standalone_lane ~lane:Standalone_lane.Verifier
          ~declared:http ~admitted:http ~declared_cli:cli ()] };
    reconcile_slot_editor_selection state;
    Alcotest.(check bool) "another lane's same IDs cannot substitute" true
      (Option.is_none (slot_editor_cursor_row state))) cases

let test_slot_editor_keys_parse () =
  Alcotest.(check (list string)) "the editor's own keys"
    [ "drop"; "down"; "up"; "first"; "none" ]
    (List.map
       (fun key ->
          match slot_edit_of_key key with
          | Some Drop_slot -> "drop"
          | Some First_slot -> "first"
          | Some (Move_slot Move_down) -> "down"
          | Some (Move_slot Move_up) -> "up"
          | None -> "none")
       [ "x"; "J"; "K"; "1"; "a" ])

let test_exact_replacement_search_exposes_model_effort_and_same_group () =
  let state = slot_editor_state ~declared:[] ~admitted:[]
      ~declared_cli:["account.current"] ~admitted_cli:["account.current"] () in
  let selected = { (runtime "account.luna-medium") with
    ro_model = "gpt-6-luna"; ro_provider_id = "account";
    ro_exact_slot_group = Tui_decode.Exact_cli_slots;
    ro_effective_max_context = 750000;
    ro_declared_reasoning_effort = Some Llm_provider.Reasoning_effort.Medium } in
  state.runtime_catalog <- [runtime "http.other"; selected;
    { selected with ro_id = "account.current" }];
  let pick = Pick_exact_lane_replacement
      (Standalone_lane.Librarian, "account.current", Tui_decode.Exact_cli_slots) in
  List.iter (fun reading ->
    state.runtime_catalog_reading <- reading;
    open_runtime_lane_pick state pick;
    let _, _, rows = runtime_picker_rows state pick in
    Alcotest.(check int) "cached replacement choices cannot be submitted" 0 (List.length rows);
    match state.runtime_lane_pick with
    | Some (_, list) ->
        (match Masc_tui_pick_list.apply ~page:runtime_picker_page
           ~label:(runtime_picker_label_for pick) rows list Masc_tui_pick_list.Choose with
         | Masc_tui_pick_list.Stay _ -> ()
         | _ -> Alcotest.fail "Enter acted on an unconfirmed replacement catalogue")
    | None -> Alcotest.fail "replacement picker is closed")
    [Runtime_catalog_unread; Runtime_catalog_loading; Runtime_catalog_failed "offline"];
  state.runtime_catalog_reading <- Runtime_catalog_read;
  open_runtime_lane_pick state pick;
  press state (List.init (String.length "luna medium")
    (fun index -> String.make 1 "luna medium".[index]));
  (match runtime_picker_projection state with
   | Some picker ->
     Alcotest.(check (list string)) "search chooses a configured model with declared effort"
       ["account.luna-medium"] (List.map (fun runtime -> runtime.Tui_decode.ro_id) picker.rlp_choices)
   | None -> Alcotest.fail "replacement picker is closed");
  open_runtime_lane_pick state pick;
  press state (List.init (String.length "750k context")
    (fun index -> String.make 1 "750k context".[index]));
  (match runtime_picker_projection state with
   | Some picker ->
     Alcotest.(check (list string)) "search matches the visible formatted context"
       ["account.luna-medium"] (List.map (fun runtime -> runtime.Tui_decode.ro_id) picker.rlp_choices)
   | None -> Alcotest.fail "replacement picker is closed");
  state.runtime_catalog <- [{ selected with ro_id = "account.current" }];
  state.runtime_catalog_reading <- Runtime_catalog_read;
  open_runtime_lane_pick state pick;
  (match runtime_picker_projection state with
   | Some picker ->
     Alcotest.(check string) "loaded catalogue has no eligible replacement"
       "  (no eligible replacement in this candidate group)" (runtime_picker_empty_note picker)
   | None -> Alcotest.fail "replacement picker is closed");
  List.iter (fun (reading, expected) ->
    state.runtime_catalog_reading <- reading;
    match runtime_picker_projection state with
    | Some picker -> Alcotest.(check string) "cached rows do not imply a fresh read"
        expected (runtime_picker_empty_note picker)
    | None -> Alcotest.fail "replacement picker is closed")
    [ Runtime_catalog_loading, "  (runtime catalogue loading)"
    ; Runtime_catalog_failed "offline", "  (runtime catalogue read failed: offline)" ];
  Alcotest.(check string) "first means first within the declared group"
    "librarian_exact first in group account.current"
    (slot_plan_text (plan_slot_edit state First_slot));
  Alcotest.(check bool) "replacement sends one operation rather than replacing a stale list"
    false (runtime_lane_pick_sends_whole_order pick)

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
    { rrs_usage = Error "not reported"; rrs_generated_at_iso = "fixture"; rrs_config_path = None;
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
         | Pick_lane (lane, _) -> "lane " ^ lane.Masc.Tui_decode.rrl_id
         | Pick_model model -> "model " ^ model.Masc.Tui_decode.ro_id)
        (runtime_picker_items state))

(* [runtime].media_failover is written as a whole list -- the routing endpoint
   has no per-entry action for it -- so the editor shows the file's
   declaration rather than the shorter admitted fleet. An entry boot could not
   resolve keeps its position and is marked, exactly like a rejected
   exact-lane slot, so moving or dropping a neighbour cannot erase it. *)
let media_failover_state ?(cursor = 0) ?(declared = [ "a"; "b" ]) ?(admitted = [ "a"; "b" ]) () =
  let state = state () in
  let resolved : Masc.Tui_decode.runtime_resolved_snapshot =
    { rrs_usage = Error "not reported"; rrs_generated_at_iso = "fixture"; rrs_config_path = None;
      rrs_default_runtime_id = Some "a";
      rrs_media_failover = admitted; rrs_media_failover_declared = declared;
      rrs_runtimes = [runtime "a"; runtime "b"; runtime "c"];
      rrs_lanes = [{rrl_id = "solo"; rrl_runtime_ids = ["c"]; rrl_declared = true}] } in
  (match Masc.Tui_decode.join_runtime_surface ~probe:None ~probe_error:None ~resolved with
   | Ok snapshot -> state.runtime_surface <- Some snapshot
   | Error detail -> Alcotest.fail detail);
  open_slot_editor state Media_failover_slots;
  select_slot_editor_row state cursor;
  state

let test_media_slot_selection_survives_refresh () =
  let state = media_failover_state ~cursor:1 () in
  let refresh declared =
    let replacement = media_failover_state ~declared () in
    state.runtime_surface <- replacement.runtime_surface;
    reconcile_slot_editor_selection state
  in
  refresh ["inserted"; "b"; "a"];
  Alcotest.(check string) "route reorder still acts on b"
    "[runtime].media_failover order [b; inserted; a] b"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_up)));
  refresh ["b"; "a"; "inserted"];
  Alcotest.(check (option int)) "render follows moved route identity" (Some 0)
    (slot_editor_cursor_index state);
  refresh ["a"; "inserted"];
  Alcotest.(check bool) "removed route has no config target" true
    (Option.is_none (slot_editor_cursor_row state));
  Alcotest.(check string) "removed route cannot drop a neighbour"
    "refuse: no slot is under the cursor"
    (slot_plan_text (plan_slot_edit state Drop_slot));
  refresh ["b"; "a"; "inserted"];
  Alcotest.(check bool) "reappearing route stays deselected" true
    (Option.is_none (slot_editor_cursor_row state));
  navigate_slot_editor state Move_up;
  Alcotest.(check (option int)) "explicit up selects the final current row" (Some 2)
    (slot_editor_cursor_index state)

(* The route editor sends the order it read, in full, and it reads that order
   off the same list the candidate guard watches. After a failed read-back
   that order is evidence of the state before the last write, so sending it
   restores whatever that write removed.

   The conversation-lane editor has refused this since the guard was written.
   The route editor did not: its plan asked only whether a write was in
   flight, and the pick list put [Pick_media_failover] on the unguarded side
   of a match whose comment said only the conversation-lane arm sends the
   order in full. *)
let test_the_route_editor_will_not_write_from_a_stale_list () =
  let stale state =
    state.runtime_surface_generation <- 1;
    state.runtime_lane_write <- Lane_write_posting;
    settle_runtime_lane_write state ~written:Runtime_surface_list (Ok ());
    runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:2
      (Error "HTTP 503: down")
  in
  let refusal =
    "refuse: the lane list may be stale; reload it before changing candidates"
  in
  let state = media_failover_state () in
  stale state;
  Alcotest.(check string) "a move is refused" refusal
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)));
  Alcotest.(check string) "so is a drop" refusal
    (slot_plan_text (plan_slot_edit state Drop_slot));
  Alcotest.(check string) "and the stale line says why" stale_after_503
    (stale_text state);
  (* An exact lane names the one slot it changes and the writer reads the
     declared order under its lock, so a stale reading here cannot undo
     anything and the edit still lands. *)
  let exact = slot_editor_state () in
  stale exact;
  Alcotest.(check string) "an exact lane's drop is untouched"
    "librarian_exact drop a"
    (slot_plan_text (plan_slot_edit exact Drop_slot))

(* Which writes a stale list can undo is one question, asked of the value
   rather than of a list of constructors written at each dispatch. Both
   vocabularies answer it exhaustively, so a pick or a slot target added later
   has to choose a side instead of inheriting the unguarded one. *)
let test_the_writes_a_stale_list_can_undo_are_named_once () =
  let pick name expected value =
    Alcotest.(check bool) name expected
      (runtime_lane_pick_sends_whole_order value)
  in
  pick "a conversation lane sends its whole order" true
    (Pick_conversation_lane "coding");
  pick "so does the media failover route" true Pick_media_failover;
  pick "an exact lane appends one slot" false (Pick_exact_lane Standalone_lane.Verifier);
  pick "a new lane sends only the pick" false (Pick_new_lane "fresh");
  pick "the default is one entry, replaced" false Pick_route_default;
  Alcotest.(check bool) "the route editor sends its whole order" true
    (slot_editor_target_sends_whole_order Media_failover_slots);
  Alcotest.(check bool) "the exact-lane editor names one slot" false
    (slot_editor_target_sends_whole_order (Exact_lane_slots Standalone_lane.Verifier))

let test_the_route_editor_writes_the_whole_order () =
  let state = media_failover_state () in
  Alcotest.(check (list string)) "the route's entries, in call order"
    [ "a"; "b" ]
    (List.map (fun row -> row.sr_slot) (slot_editor_rows state));
  Alcotest.(check string) "a move sends the reordered list"
    "[runtime].media_failover order [b; a] a"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)));
  Alcotest.(check string) "a drop sends what is left"
    "[runtime].media_failover order [b] a"
    (slot_plan_text (plan_slot_edit state Drop_slot));
  (* An empty route is a configuration, not a broken one: no vision runtimes. The
     exact-lane editor refuses its last slot; this one does not. *)
  let state = media_failover_state ~declared:[ "only" ] ~admitted:[ "only" ] () in
  Alcotest.(check string) "the last entry may go"
    "[runtime].media_failover order [] only"
    (slot_plan_text (plan_slot_edit state Drop_slot))

(* An entry boot could not resolve is still the file's, so it is listed where
   the file puts it and edited there. Writing the admitted list alone would
   have deleted it. *)
let test_the_route_editor_keeps_an_unresolved_entry_in_place () =
  let state =
    media_failover_state ~declared:[ "a"; "gone.model"; "b" ] ~admitted:[ "a"; "b" ] ()
  in
  Alcotest.(check (list string)) "the declaration is what the editor lists"
    [ "a (admitted)"; "gone.model (declared)"; "b (admitted)" ]
    (List.map
       (fun row ->
          Printf.sprintf "%s (%s)" row.sr_slot
            (if row.sr_admitted then "admitted" else "declared"))
       (slot_editor_rows state));
  Alcotest.(check string) "a move past it carries it along"
    "[runtime].media_failover order [gone.model; a; b] a"
    (slot_plan_text (plan_slot_edit state (Move_slot Move_down)));
  let state =
    media_failover_state ~cursor:1 ~declared:[ "a"; "gone.model"; "b" ]
      ~admitted:[ "a"; "b" ] ()
  in
  Alcotest.(check string) "and it can be dropped from where it sits"
    "[runtime].media_failover order [a; b] gone.model"
    (slot_plan_text (plan_slot_edit state Drop_slot))

let catalogue_state () =
  let state = state () in
  state.runtime_catalog_reading <- Runtime_catalog_read;
  state.runtime_catalog <-
    [ runtime "anthropic.claude"; runtime "openai.gpt"; runtime "ollama.qwen";
      runtime "zai.glm"; runtime "kimi.k2" ];
  open_runtime_lane_pick state (Pick_conversation_lane "primary");
  state.view <- Runtime;
  state

let drawn state =
  match runtime_picker_projection state with
  | None -> Alcotest.fail "the picker is not drawn"
  | Some picker ->
      ( List.map (fun (r : Masc.Tui_decode.runtime_option) -> r.ro_id) picker.rlp_choices,
        Option.bind picker.rlp_selected_row (fun row ->
          Option.map (fun (r : Masc.Tui_decode.runtime_option) -> r.ro_id)
            (List.nth_opt picker.rlp_choices row)),
        picker )

(* The operator types part of a runtime id and the drawn choices are the ones
   that carry it; the header says how many of the catalogue those are. *)
let test_a_typed_filter_narrows_the_drawn_choices () =
  let state = catalogue_state () in
  press state [ "/"; "o"; "l" ];
  let rows, selected, picker = drawn state in
  Alcotest.(check (list string)) "only the ids with ol" [ "ollama.qwen" ] rows;
  Alcotest.(check (option string)) "and it is under the cursor" (Some "ollama.qwen") selected;
  Alcotest.(check string) "the header counts the catalogue"
    "filter: ol\xe2\x96\x8f 1 of 5" picker.rlp_summary;
  Alcotest.(check bool) "the filter holds typed keys" true
    (text_input_target state ~compact_viewport:false = Some Text_runtime_picker_filter);
  Alcotest.(check bool) "and so holds q" false
    (quit_key_allowed_for (text_input_target state ~compact_viewport:false))

(* A filter nothing matches draws one row that says so, and not the row an
   unread catalogue draws: the fix for one is typing, for the other waiting. *)
let test_an_empty_match_is_not_an_unread_catalogue () =
  let filtered = catalogue_state () in
  press filtered [ "/"; "x"; "y" ];
  let rows, selected, picker = drawn filtered in
  Alcotest.(check (list string)) "nothing is drawn" [] rows;
  Alcotest.(check (option string)) "nothing is selected" None selected;
  Alcotest.(check string) "the note says the filter kept nothing"
    "  (no runtime among 5 matches the filter)" (runtime_picker_empty_note picker);
  let unread = state () in
  open_runtime_lane_pick unread (Pick_conversation_lane "primary");
  let _, _, picker = drawn unread in
  Alcotest.(check string) "an unread catalogue still says unread"
    "  (runtime catalogue unread)" (runtime_picker_empty_note picker)

(* The filter matches the text the row draws. A model id carrying a control
   byte is drawn with it escaped, and typing what is drawn finds it. *)
let test_the_filter_matches_the_drawn_text () =
  let state = catalogue_state () in
  let odd = { (runtime "odd.id") with ro_model = "mod\nel" } in
  state.runtime_catalog <- odd :: state.runtime_catalog;
  (match state.runtime_lane_pick with
   | None -> Alcotest.fail "no picker"
   | Some (pick, list) ->
       state.runtime_lane_pick <-
         Some (pick, Masc_tui_pick_list.type_text list "mod\\x0Ael"));
  let rows, _, _ = drawn state in
  Alcotest.(check (list string)) "the escaped text finds it" [ "odd.id" ] rows;
  Alcotest.(check string) "the label is the drawn, escaped text"
    "odd.id   provider / mod\\x0Ael" (runtime_picker_label odd)

(* A reload that shortens the catalogue under a cursor on its last row draws
   the new last row selected, never a cursor past the end. *)
let test_the_drawn_cursor_clamps_to_a_shorter_catalogue () =
  let state = catalogue_state () in
  press state [ "end" ];
  state.runtime_catalog <- [ runtime "anthropic.claude"; runtime "openai.gpt" ];
  let rows, selected, _ = drawn state in
  Alcotest.(check (list string)) "both are drawn" [ "anthropic.claude"; "openai.gpt" ] rows;
  Alcotest.(check (option string)) "the last is selected" (Some "openai.gpt") selected

(* The Keeper runtime picker (Keepers, [U]): the declared lanes first, then
   the whole catalogue, one list the filter reads across. *)
let keeper_picker_rows = 40

let keeper_picker_state () =
  let state = state () in
  state.runtime_lanes <-
    [ { rrl_id = "coding"; rrl_runtime_ids = [ "anthropic.claude"; "zai.glm" ];
        rrl_declared = true };
      { rrl_id = "vision"; rrl_runtime_ids = [ "openai.gpt" ]; rrl_declared = true } ];
  state.runtime_catalog <-
    [ runtime "anthropic.claude"; runtime "openai.gpt"; runtime "ollama.qwen";
      runtime "zai.glm" ];
  state.runtime_pick_keeper <- Some "alpha";
  state.view <- Keepers Keeper_runtime_pick;
  state

(* The picker's list after these keys, through the list, label and page the
   key handler reads. A key that closes or picks fails the check. *)
let keeper_pick_after state keys =
  List.fold_left
    (fun list key ->
      match Masc_tui_pick_list.action_of_key ~close_keys:[] list key with
      | None -> Alcotest.failf "key %S is not the picker's" key
      | Some action -> (
          match
            Masc_tui_pick_list.apply
              ~page:(keeper_runtime_picker_page state ~terminal_rows:keeper_picker_rows)
              ~label:runtime_pick_label (runtime_picker_items state) list action
          with
          | Masc_tui_pick_list.Stay list -> list
          | Masc_tui_pick_list.Chosen _ | Masc_tui_pick_list.Dismissed ->
              Alcotest.failf "key %S left the picker" key))
    state.runtime_pick_list keys

let keeper_drawn ?(terminal_rows = keeper_picker_rows) state =
  let view = keeper_runtime_picker_view state ~terminal_rows in
  ( List.map runtime_pick_item_id view.Masc_tui_pick_list.rows,
    Option.bind view.Masc_tui_pick_list.selected_row (fun row ->
      Option.map runtime_pick_item_id (List.nth_opt view.Masc_tui_pick_list.rows row)),
    view )

let test_the_keeper_picker_filters_across_lanes_and_runtimes () =
  let state = keeper_picker_state () in
  let rows, selected, view = keeper_drawn state in
  Alcotest.(check (list string)) "lanes first, then the catalogue"
    [ "coding"; "vision"; "anthropic.claude"; "openai.gpt"; "ollama.qwen"; "zai.glm" ] rows;
  Alcotest.(check (option string)) "the head is selected" (Some "coding") selected;
  Alcotest.(check string) "the header counts both groups" "6 of 6 \xc2\xb7 / filter"
    (keeper_runtime_picker_summary view);
  (* "gl" is in the coding lane's route and in zai.glm's id: both stay, lane
     first, so the order across the two groups is kept. *)
  state.runtime_pick_list <- keeper_pick_after state [ "/"; "g"; "l" ];
  let rows, selected, view = keeper_drawn state in
  Alcotest.(check (list string)) "the filter reads the lane route and the id"
    [ "coding"; "zai.glm" ] rows;
  Alcotest.(check (option string)) "the first match is under the cursor" (Some "coding") selected;
  Alcotest.(check string) "the header names the filter"
    "filter: gl\xe2\x96\x8f 2 of 6 \xe2\x80\x94 \xe2\x86\x91/\xe2\x86\x93 move, Enter choose, Esc clear filter"
    (keeper_runtime_picker_summary view);
  (* The badge is drawn, so it is filtered on: "lane" keeps the lanes. *)
  state.runtime_pick_list <- keeper_pick_after state [ "\127"; "\127"; "l"; "a"; "n"; "e" ];
  let rows, _, _ = keeper_drawn state in
  Alcotest.(check (list string)) "the drawn [LANE] badge narrows to lanes"
    [ "coding"; "vision" ] rows;
  Alcotest.(check bool) "the filter holds typed keys" true
    (text_input_target state ~compact_viewport:false = Some Text_keeper_runtime_picker_filter);
  Alcotest.(check bool) "and so holds q" false
    (quit_key_allowed_for (text_input_target state ~compact_viewport:false))

(* What the filter matches is what the row draws: the label is the join of
   the columns the renderer draws. *)
let test_the_keeper_picker_label_is_the_drawn_columns () =
  let lane =
    Pick_lane
      ( { rrl_id = "coding"; rrl_runtime_ids = [ "anthropic.claude"; "odd" ];
          rrl_declared = true }
      , [] )
  in
  let columns = runtime_pick_columns lane in
  Alcotest.(check string) "a lane route names its models"
    "claude \xe2\x86\x92 odd" columns.rpc_route;
  Alcotest.(check string) "the label joins badge, target and route"
    "[LANE]  coding  claude \xe2\x86\x92 odd" (runtime_pick_label lane);
  Alcotest.(check string) "a model row names provider and model"
    "[MODEL]  zai.glm  provider / model" (runtime_pick_label (Pick_model (runtime "zai.glm")))

let test_the_keeper_picker_empty_match_is_not_an_unread_catalogue () =
  let picker = keeper_picker_state () in
  picker.runtime_pick_list <- keeper_pick_after picker [ "/"; "x"; "y" ];
  let rows, selected, view = keeper_drawn picker in
  Alcotest.(check (list string)) "nothing is drawn" [] rows;
  Alcotest.(check (option string)) "nothing is selected" None selected;
  Alcotest.(check (option string)) "the note says the filter kept nothing"
    (Some "  (no lane or runtime among 6 matches the filter)")
    (keeper_runtime_picker_empty_note view);
  let unread = state () in
  unread.view <- Keepers Keeper_runtime_pick;
  let _, _, view = keeper_drawn unread in
  Alcotest.(check (option string)) "an unread catalogue still says loading"
    (Some "  (loading runtime catalogue\xe2\x80\xa6)") (keeper_runtime_picker_empty_note view);
  let _, _, view = keeper_drawn (keeper_picker_state ()) in
  Alcotest.(check (option string)) "rows draw the header, not a note" None
    (keeper_runtime_picker_empty_note view)

(* A reload that shortens the list under a cursor on its last row draws the
   new last row selected. *)
let test_the_keeper_picker_cursor_clamps_to_a_shorter_list () =
  let state = keeper_picker_state () in
  state.runtime_pick_list <- keeper_pick_after state [ "end" ];
  state.runtime_lanes <- [];
  state.runtime_catalog <- [ runtime "anthropic.claude"; runtime "openai.gpt" ];
  let rows, selected, _ = keeper_drawn state in
  Alcotest.(check (list string)) "both are drawn" [ "anthropic.claude"; "openai.gpt" ] rows;
  Alcotest.(check (option string)) "the last is selected" (Some "openai.gpt") selected

(* The picker fills the screen, so the window stays on the first page while
   the cursor walks it, and a page key moves by the rows drawn. *)
let test_the_keeper_picker_window_follows_the_cursor () =
  let state = keeper_picker_state () in
  state.runtime_catalog <- List.init 60 (fun i -> runtime (Printf.sprintf "r%02d" i));
  let page = keeper_runtime_picker_page state ~terminal_rows:keeper_picker_rows in
  Alcotest.(check bool) "a page is shorter than the list" true (page < 62);
  state.runtime_pick_list <- keeper_pick_after state [ "j"; "j" ];
  let rows, selected, _ = keeper_drawn state in
  Alcotest.(check (option string)) "the head stays drawn" (Some "coding") (List.nth_opt rows 0);
  Alcotest.(check (option string)) "the cursor moved down" (Some "r00") selected;
  Alcotest.(check int) "a whole page is drawn" page (List.length rows);
  state.runtime_pick_list <- keeper_pick_after state [ "pagedown" ];
  let rows, selected, view = keeper_drawn state in
  Alcotest.(check (option string)) "PgDn moves a page"
    (Some (Printf.sprintf "r%02d" page)) selected;
  Alcotest.(check (option int)) "and the cursor rides the last drawn row"
    (Some (page - 1)) view.Masc_tui_pick_list.selected_row;
  Alcotest.(check int) "still a whole page" page (List.length rows)

let test_account_usage_stays_spent_until_new_report () =
  let open Masc.Tui_decode_usage in
  let snapshot = match (lane_state ()).runtime_surface with
    | Some snapshot -> snapshot
    | None -> Alcotest.fail "missing fixture" in
  let window = { puw_limit_id = Some "account-bucket";
    puw_kind = Window_seven_day; puw_role = Role_gates_model_calls;
    puw_utilization = Utilization_percent 100; puw_resets_at = Some 1.;
    puw_observed_at = 0. } in
  let account window = { pua_scope = "account:1"; pua_scope_id = "fixture";
    pua_providers = []; pua_state = Account_reported (window, []) } in
  let resolved window = { snapshot.rss_resolved with
    rrs_usage = Ok { puws_since = 0.; puws_accounts = [account window] } } in
  let rt = { (runtime "a") with ro_quota_scope = Some "account:1" } in
  let count resolved rt = match runtime_spent_usage resolved rt with
    | Ok windows -> List.length windows
    | Error detail -> Alcotest.fail detail in
  expect "past reset and no refusal do not clear observed spending" 1
    (count (resolved window) rt);
  expect "new report below limit clears warning" 0
    (count (resolved {window with puw_utilization = Utilization_percent 99}) rt);
  expect "rounded display100 is not actual exhaustion" 0
    (count (resolved {window with puw_utilization = Utilization_fraction 0.999}) rt);
  expect "non-model-call bucket does not warn" 0
    (count (resolved {window with puw_role = Role_counts_other_use}) rt);
  expect "unclassified bucket does not assert model-call exhaustion" 0
    (count (resolved {window with puw_role = Role_unclassified_limit}) rt);
  Alcotest.(check bool) "another account does not inherit evidence" true
    (Result.is_error (runtime_spent_usage (resolved window)
       {rt with ro_quota_scope = Some "account:2"}));
  Alcotest.(check bool) "failed usage decode stays unknown" true
    (Result.is_error (runtime_spent_usage
       {snapshot.rss_resolved with rrs_usage = Error "bad report"} rt))

let test_credit_cap_removal_clears_spent_warning () =
  let module Usage = Runtime_provider_usage_window in
  let open Masc.Tui_decode_usage in
  let scope = Runtime_quota_window.scope_of_credential
      ~provider_id:"usage_cap_removal_runtime_fixture" None in
  let snapshot = match (lane_state ()).runtime_surface with
    | Some snapshot -> snapshot | None -> Alcotest.fail "missing fixture" in
  let record at body =
    match Usage.decode_openrouter_key (Yojson.Safe.from_string body) with
    | Error detail -> Alcotest.fail (Usage.decode_error_to_string detail)
    | Ok report -> Usage.record ~scope ~observed_at:at report in
  let reading () =
    let json = Server_dashboard_runtime_resolved_json.build
        ~generated_at_iso:"2026-10-04T00:00:00Z"
        ~config:(Masc.Workspace.default_config (Filename.get_temp_dir_name ())) in
    let usage = match decode_provider_usage_windows json with
      | Ok usage -> usage | Error detail -> Alcotest.fail detail in
    let account = List.find (fun account -> account.pua_scope_id =
      Server_provider_usage_history.scope_id scope) usage.puws_accounts in
    let rt = { (runtime "credit") with ro_quota_scope = Some account.pua_scope } in
    let windows = match runtime_spent_usage
        { snapshot.rss_resolved with rrs_usage = Ok usage } rt with
      | Ok windows -> windows | Error detail -> Alcotest.fail detail in
    account, List.length windows in
  record 100. {|{"data":{"limit":20,"limit_remaining":0}}|};
  expect "spent credit cap warns" 1 (snd (reading ()));
  record 101. {|{"data":{"limit":null,"usage":21.5}}|};
  let account, warnings = reading () in
  expect "removing the cap removes the old spent warning" 0 warnings;
  (match account.pua_state with
   | Account_reported ({ puw_utilization = Utilization_usd { used; limit = None }; _ }, []) ->
       Alcotest.(check (float 0.0001)) "only current uncapped USD remains" 21.5 used
   | _ -> Alcotest.fail "stale credit-cap window survived the complete report");
  record 102. {|{"data":{"limit":null}}|};
  let account, warnings = reading () in
  expect "empty complete report has no spent warning" 0 warnings;
  (match account.pua_state with
   | Account_reported_no_windows { observed_at; _ } ->
       Alcotest.(check (float 0.0)) "empty report keeps its observation time" 102. observed_at
   | _ -> Alcotest.fail "empty report became a missing report");
  record 100.5 {|{"data":{"limit":20,"limit_remaining":0}}|};
  expect "late older snapshot cannot resurrect the removed cap" 0 (snd (reading ()))

let test_runtime_quota_scope_is_shared_but_connection_keys_remain () =
  let first = { (runtime "first.luna") with ro_provider_id = "first";
    ro_quota_scope = Some "account:1"; ro_quota_scope_id = Some "shared-codex-scope";
    ro_effective_max_context = 272000 } in
  let wide = { first with ro_id = "first_wide.luna"; ro_provider_id = "first_wide";
    ro_effective_max_context = 500000 } in
  let other = { first with ro_id = "second.luna"; ro_provider_id = "second";
    ro_quota_scope = Some "account:2"; ro_quota_scope_id = Some "other-codex-scope" } in
  Alcotest.(check string) "one quota scope spans both provider connections"
    (runtime_quota_scope_label first) (runtime_quota_scope_label wide);
  Alcotest.(check bool) "a distinct quota scope retains its own label" true
    (runtime_quota_scope_label first <> runtime_quota_scope_label other);
  List.iter (fun (runtime, context) ->
    let label = runtime_model_picker_label runtime in
    List.iter (fun fact -> Alcotest.(check bool) ("picker retains " ^ fact) true
      (Astring.String.is_infix ~affix:fact label))
      ["Quota scope shared-codex-scope"; "Connection " ^ runtime.ro_provider_id; runtime.ro_id; context])
    [first, "272k context"; wide, "500k context"];
  Alcotest.(check string) "missing quota ID preserves explicitly response-local correlation"
    "unavailable; response-local scope account:1"
    (runtime_quota_scope_label {first with ro_quota_scope_id=None})

let test_selected_status_wraps_and_reserves_rows () =
  let open Masc.Tui_decode_usage in
  let state = lane_state () in
  let snapshot = match state.runtime_surface with
    | Some snapshot -> snapshot | None -> Alcotest.fail "missing fixture" in
  let account = { pua_scope = "account:status"; pua_scope_id = "status"; pua_providers = [];
    pua_state = Account_reported ({ puw_limit_id = None; puw_kind = Window_five_hour;
      puw_role = Role_gates_model_calls; puw_utilization = Utilization_percent 100;
      puw_resets_at = None; puw_observed_at = 0. }, []) } in
  let observed = { (runtime "a") with
    ro_provider_id = "codex-account-two"; ro_provider = "Account Two";
    ro_quota_exhausted = true; ro_rate_limited = true; ro_quota_scope = Some "account:status";
    ro_quota_scope_id = Some "status" } in
  let resolved = { snapshot.rss_resolved with
    rrs_usage = Ok { puws_since = 0.; puws_accounts = [account] };
    rrs_runtimes = [observed; runtime "b"; runtime "c"] } in
  state.runtime_surface <- Some (match Masc.Tui_decode.join_runtime_surface
      ~probe:None ~probe_error:None ~resolved with
    | Ok snapshot -> snapshot | Error detail -> Alcotest.fail detail);
  List.iter (fun cols ->
    let lines = runtime_selection_summary_lines ~cols state in
    let text = String.concat " " (List.map String.trim lines) in
    List.iter (fun fact -> Alcotest.(check bool) ("complete selected fact: " ^ fact) true
        (Astring.String.is_infix ~affix:fact text))
      [ "Lane primary"; "Quota scope status"; "Connection codex-account-two"; "Account Two / model";
        "quota exhausted (no reset stated)"; "rate limited"; "account limit spent / unobserved" ];
    List.iter (fun line -> Alcotest.(check bool) "wrapped status fits frame" true
        (Masc_tui_message_layout.display_width line <= Masc_tui_frame.inner_width ~cols)) lines;
    let chrome = runtime_surface_listing_chrome ~rows:100 ~cols state in
    state.runtime_cursor <- 99;
    let without_selection = runtime_surface_listing_chrome ~rows:100 ~cols state in
    state.runtime_cursor <- 0;
    expect "render and navigation reserve the full selected block"
      (without_selection + List.length lines + 1) chrome)
    [80;132]

let test_quota_scope_label_preserves_correlation () =
  let first = { (runtime "a") with ro_provider_id = "connection-a";
    ro_quota_scope = Some "account:1"; ro_quota_scope_id = Some "stable-first" } in
  let sibling = { first with ro_provider_id = "connection-b" } in
  Alcotest.(check string) "quota scope label uses retained Usage scope" "stable-first"
    (runtime_quota_scope_label first);
  Alcotest.(check string) "connections sharing quota share scope label"
    (runtime_quota_scope_label first) (runtime_quota_scope_label sibling);
  Alcotest.(check string) "unjoined ordinal remains explicitly response-local"
    "unavailable; response-local scope account:1"
    (runtime_quota_scope_label {first with ro_quota_scope_id = None});
  Alcotest.(check string) "no reported quota scope remains unavailable"
    "unavailable (no quota scope reported)"
    (runtime_quota_scope_label {first with ro_quota_scope_id = None; ro_quota_scope = None})

let test_short_viewport_preserves_selected_list_row () =
  let state = lane_state () in
  List.iter (fun mode ->
    state.runtime_mode <- mode;
    List.iter (fun cols ->
      List.iter (fun rows ->
        List.iter (fun cursor ->
          state.runtime_cursor <- cursor;
          let chrome = runtime_surface_listing_chrome ~rows ~cols state in
          let visible = rows - chrome in
          Alcotest.(check bool) "supported viewport retains a list row" true
            (visible >= 1);
          let summary = runtime_selection_summary_for_viewport ~rows ~cols state in
          expect "render budget counts exactly the drawn summary and divider"
            (runtime_surface_base_chrome ~cols state
             + (if summary = [] then 0 else List.length summary + 1)) chrome;
          (match runtime_scrolled ~rows ~cols state with
           | None -> Alcotest.fail "runtime list has no scroll geometry"
           | Some layout ->
               expect "navigation and renderer share short-height chrome" chrome layout.sc_chrome;
               expect "navigation sees every runtime" 3 layout.sc_count))
          [0; 1; 2]) [14; 15; 16; 40]) [80; 132])
    [Runtime_lanes; Runtime_all];
  state.runtime_mode <- Runtime_lanes;
  state.runtime_cursor <- 0;
  List.iter (fun cols ->
    Alcotest.(check (list string)) "ample height retains complete selected evidence"
      (runtime_selection_summary_lines ~cols state)
      (runtime_selection_summary_for_viewport ~rows:100 ~cols state)) [80; 132]

let () = Alcotest.run "runtime list geometry"
  ["operator states", [ Alcotest.test_case "quota scope label preserves correlation" `Quick
        test_quota_scope_label_preserves_correlation;
      Alcotest.test_case "short viewport retains selected list row" `Quick
        test_short_viewport_preserves_selected_list_row;
      Alcotest.test_case "quota scope spans provider connections" `Quick
        test_runtime_quota_scope_is_shared_but_connection_keys_remain;
      Alcotest.test_case "account usage survives reset until new report" `Quick
        test_account_usage_stays_spent_until_new_report;
        Alcotest.test_case "selected status wraps with shared scroll geometry" `Quick
          test_selected_status_wraps_and_reserves_rows;
        Alcotest.test_case "credit cap removal reaches runtime warning" `Quick
          test_credit_cap_removal_clears_spent_warning;
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
        Alcotest.test_case "the authority row spells its config path whole" `Quick
        test_the_authority_row_spells_its_config_path_whole; Alcotest.test_case "picker target column fits the longest id" `Quick
        test_picker_target_column_fits_the_longest_id; Alcotest.test_case "every picker row fits the frame" `Quick
        test_every_row_fits_the_frame; Alcotest.test_case "narrow rows keep the quota warning" `Quick
        test_narrow_rows_keep_the_fact_that_is_said_nowhere_else; Alcotest.test_case "runtime readers retain their owner after list refresh" `Quick
        test_runtime_detail_keeps_its_owner; Alcotest.test_case "rate limit shows on model and lane rows" `Quick
        test_rate_limit_is_said_on_model_and_lane_rows; Alcotest.test_case "narrow target column tells the variants apart" `Quick
        test_narrow_target_column_still_tells_the_variants_apart; Alcotest.test_case "the slot editor edits the declared order" `Quick
        test_the_slot_editor_edits_the_declared_order; Alcotest.test_case "the slot editor keeps the last slot" `Quick
        test_the_slot_editor_keeps_the_last_slot; Alcotest.test_case "the slot editor includes CLI fallback slots" `Quick
        test_the_slot_editor_edits_cli_slots_after_http; Alcotest.test_case "slot editor keys parse" `Quick
        test_slot_editor_keys_parse;
        Alcotest.test_case "exact replacement searches model and effort within its group" `Quick
        test_exact_replacement_search_exposes_model_effort_and_same_group;
        Alcotest.test_case "slot selection survives refreshed declarations" `Quick
        test_slot_selection_survives_refresh; Alcotest.test_case "media slot selection survives refreshed declarations" `Quick
        test_media_slot_selection_survives_refresh; Alcotest.test_case "an undeclared lane is not a single candidate" `Quick
        test_an_undeclared_lane_is_not_read_as_a_single_candidate; Alcotest.test_case "the picker offers only declared lanes" `Quick
        test_the_picker_offers_only_declared_lanes; Alcotest.test_case "the route editor writes the whole order" `Quick
        test_the_route_editor_writes_the_whole_order; Alcotest.test_case "the route editor will not write from a stale list"
        `Quick test_the_route_editor_will_not_write_from_a_stale_list; Alcotest.test_case "the writes a stale list can undo are named once"
        `Quick test_the_writes_a_stale_list_can_undo_are_named_once; Alcotest.test_case "the route editor edits a partly unresolved route" `Quick
        test_the_route_editor_keeps_an_unresolved_entry_in_place; Alcotest.test_case "a typed filter narrows the drawn choices" `Quick
        test_a_typed_filter_narrows_the_drawn_choices; Alcotest.test_case "an empty match is not an unread catalogue" `Quick
        test_an_empty_match_is_not_an_unread_catalogue; Alcotest.test_case "the filter matches the drawn text" `Quick
        test_the_filter_matches_the_drawn_text; Alcotest.test_case "the drawn cursor clamps to a shorter catalogue" `Quick
        test_the_drawn_cursor_clamps_to_a_shorter_catalogue; Alcotest.test_case "keeper picker filters across lanes and runtimes" `Quick
        test_the_keeper_picker_filters_across_lanes_and_runtimes; Alcotest.test_case "keeper picker label is the drawn columns" `Quick
        test_the_keeper_picker_label_is_the_drawn_columns; Alcotest.test_case "keeper picker empty match is not an unread catalogue" `Quick
        test_the_keeper_picker_empty_match_is_not_an_unread_catalogue; Alcotest.test_case "keeper picker cursor clamps to a shorter list" `Quick
        test_the_keeper_picker_cursor_clamps_to_a_shorter_list; Alcotest.test_case "keeper picker window follows the cursor" `Quick
        test_the_keeper_picker_window_follows_the_cursor; Alcotest.test_case "schema-less client only refuses exact lanes" `Quick
        test_schema_less_client_is_refused_only_for_exact_lane
]]
