open Masc_tui_types

let expect label wanted actual = Alcotest.(check int) label wanted actual

let runtime id : Masc.Tui_decode.runtime_option =
  { ro_id = id; ro_provider = "provider"; ro_model = "model";
    ro_effective_max_context = 200000; ro_max_context_source = Runtime_context_capability;
    ro_max_output_tokens = Some 8192; ro_is_local = false;
    ro_dispatchable = true; ro_blocked_reason = None; ro_is_default = false }

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
  state.runtime_lane_pick <- Some "primary";
  (* Three choices, prompt and divider consume five additional rows. *)
  check_layout state 14;
  state.runtime_lane_error <- Some "route write rejected";
  check_layout state 16;
  state.runtime_surface_error <- Some "resolved unavailable";
  check_layout state 18;
  state.runtime_lane_pick_cursor <- 2;
  check_layout state 16;
  state.runtime_lane_pick <- None;
  check_layout state 13

let test_empty_picker_keeps_its_explanation () =
  let state = state () in
  state.runtime_lane_pick <- Some "primary";
  check_layout state 12

let () = Alcotest.run "runtime list geometry"
  ["operator states", [
      Alcotest.test_case "picker and failures reserve footer space" `Quick test_picker_and_refusal_keep_footer_space;
      Alcotest.test_case "empty picker explanation" `Quick test_empty_picker_keeps_its_explanation]]
