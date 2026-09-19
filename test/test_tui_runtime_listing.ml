open Masc_tui_types

let expect label wanted actual = Alcotest.(check int) label wanted actual

let runtime id : Masc.Tui_decode.runtime_option =
  { ro_id = id; ro_provider = "provider"; ro_model = "model";
    ro_effective_max_context = 200000; ro_max_context_source = Runtime_context_capability;
    ro_max_output_tokens = Some 8192; ro_is_local = false;
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
  check_layout state 9;
  state.runtime_lane_pick <- Some (Pick_conversation_lane "primary");
  (* Three choices, prompt and divider consume five additional rows. *)
  check_layout state 14;
  state.runtime_lane_notice <- Some (Lane_write_refused "route write rejected");
  check_layout state 16;
  state.runtime_surface_error <- Some "resolved unavailable";
  check_layout state 18;
  state.runtime_lane_pick_cursor <- 2;
  check_layout state 16;
  state.runtime_lane_pick <- None;
  check_layout state 13

let test_empty_picker_keeps_its_explanation () =
  let state = state () in
  state.runtime_lane_pick <- Some (Pick_conversation_lane "primary");
  check_layout state 12

(* The lane editor's prompt row -- a name being typed, a lane armed for
   removal -- is two rows the footer has to be moved for, like the refusal. *)
let test_lane_prompt_keeps_footer_space () =
  let state = state () in
  check_layout state 9;
  state.runtime_lane_name_draft <- Some "coding";
  check_layout state 11;
  state.runtime_lane_name_draft <- None;
  state.runtime_lane_remove_armed <- Some "coding";
  check_layout state 11;
  state.runtime_lane_notice <- Some (Lane_write_refused "lane \"coding\" is in use by alpha");
  check_layout state 13;
  state.runtime_lane_remove_armed <- None;
  state.runtime_lane_notice <- None;
  state.runtime_lane_pick <- Some (Pick_new_lane "coding");
  (* A lane being created has no candidates to note, and the catalogue is
     unread here: prompt, divider and the explanation row. *)
  check_layout state 12

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
      rrs_runtimes = [runtime "a"; runtime "b"; runtime "c"];
      rrs_lanes =
        [{rrl_id = "primary"; rrl_runtime_ids = ["a"; "b"]};
         {rrl_id = "solo"; rrl_runtime_ids = ["c"]}] } in
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

let test_a_failed_reread_opens_edits_with_a_line () =
  let state = lane_state () in
  state.runtime_surface_generation <- 1;
  state.runtime_lane_write <- Lane_write_posting;
  settle_runtime_lane_write state ~written:Runtime_surface_list (Ok ());
  runtime_lane_list_reread state ~list:Runtime_surface_list ~generation:2
    (Error "HTTP 503: down");
  expect_plan "edits are open" state down "write primary [b; a], cursor 1";
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
   and a view change dismisses that: the stale line has to outlive both,
   because the next write is built from the stale list. With one notice slot
   the refusal replaced the stale line and the dismissal cleared it. *)
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
  Alcotest.(check string) "the refusal is drawn" "refuse: a is already first in primary"
    (notice_text state.runtime_lane_notice);
  Alcotest.(check string) "beside the stale line" stale_after_503 (stale_text state);
  dismiss_runtime_lane_notice state;
  Alcotest.(check string) "the dismissal ended the refusal" "no line"
    (notice_text state.runtime_lane_notice);
  state.runtime_cursor <- 1;
  expect_plan "x still writes from the stale list" state drop "write primary [a], cursor 0";
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
      rrs_runtimes = [runtime "unassigned"; runtime "assigned"];
      rrs_lanes =
        [{rrl_id = "lane-only"; rrl_runtime_ids = ["assigned"]}] } in
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

let () = Alcotest.run "runtime list geometry"
  ["operator states", [
      Alcotest.test_case "picker and failures reserve footer space" `Quick test_picker_and_refusal_keep_footer_space;
      Alcotest.test_case "empty picker explanation" `Quick test_empty_picker_keeps_its_explanation;
      Alcotest.test_case "lane prompt reserves footer space" `Quick test_lane_prompt_keeps_footer_space;
      Alcotest.test_case "a move past either end is no move" `Quick test_a_move_past_either_end_is_no_move;
      Alcotest.test_case "a lane edit sends the whole order" `Quick test_a_lane_edit_sends_the_whole_order;
      Alcotest.test_case "a lane edit waits for the previous write" `Quick test_a_lane_edit_waits_for_the_previous_write;
      Alcotest.test_case "lane keys parse to edits" `Quick test_lane_keys_parse_to_edits;
      Alcotest.test_case "a written list holds edits until its re-read" `Quick test_a_written_list_holds_edits_until_its_reread;
      Alcotest.test_case "a standalone write waits for the standalone list" `Quick test_a_standalone_write_waits_for_the_standalone_list;
      Alcotest.test_case "a refused write opens edits at once" `Quick test_a_refused_write_opens_edits_at_once;
      Alcotest.test_case "a failed re-read opens edits with a line" `Quick test_a_failed_reread_opens_edits_with_a_line;
      Alcotest.test_case "a stale line holds until its list loads" `Quick test_a_stale_line_holds_until_its_list_loads;
      Alcotest.test_case "a refusal and a dismissal leave the stale line" `Quick test_a_refusal_and_a_dismissal_leave_the_stale_line;
      Alcotest.test_case "a new view ends what a key said" `Quick test_a_new_view_ends_what_a_key_said;
      Alcotest.test_case "CLI probe is informational" `Quick test_cli_probe_is_a_note;
      Alcotest.test_case "search follows Runtime mode and cursor order" `Quick test_search_follows_the_runtime_mode]]
