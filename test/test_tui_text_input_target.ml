(* Which field takes typed characters, and therefore where a paste goes.

   Typing named seven fields and paste named four, each guard written where
   its field was added. A paste into the palette, into row search, or into a
   preset name went to the chat draft the operator was not looking at, or
   nowhere at all: the operator saw paste work on one screen and do nothing
   on the next. Both paths read this function now, so what is checked here is
   the order they share and the conditions each field is claimed under. *)

module Tui_types = Masc_tui_types
open Alcotest

let target =
  testable
    (Fmt.of_to_string (function
      | None -> "none"
      | Some Tui_types.Text_preset_name -> "preset-name"
      | Some Tui_types.Text_runtime_param -> "runtime-param"
      | Some Tui_types.Text_voice_wizard -> "voice-wizard"
      | Some Tui_types.Text_palette -> "palette"
      | Some Tui_types.Text_row_search -> "row-search"
      | Some Tui_types.Text_identity_app_form -> "identity-app-form"
      | Some Tui_types.Text_identity_filter -> "identity-filter"
      | Some Tui_types.Text_browser_url -> "browser-url"
      | Some Tui_types.Text_ask_answer -> "ask-answer"
      | Some Tui_types.Text_board_draft -> "board-draft"))
    ( = )
;;

let fresh_state () =
  Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
;;

let resolved ?(compact_viewport = false) state =
  Tui_types.text_input_target state ~compact_viewport
;;

let identity_surface state =
  state.Tui_types.view <- Tui_types.Keepers Tui_types.Keeper_detail;
  state.Tui_types.detail_tab <- Tui_types.Detail_identity
;;

let test_nothing_claims_a_plain_surface () =
  check target "no field is taking text" None (resolved (fresh_state ()))
;;

let test_the_palette_claims_while_it_is_open () =
  let state = fresh_state () in
  state.Tui_types.palette_open <- true;
  check target "palette" (Some Tui_types.Text_palette) (resolved state)
;;

let test_row_search_claims_while_a_query_is_armed () =
  let state = fresh_state () in
  state.Tui_types.search <- Some "que";
  check target "row search" (Some Tui_types.Text_row_search) (resolved state);
  (* An empty query is still a query: "/" arms the field before a character
     lands in it, and that is exactly when a paste is likely. *)
  state.Tui_types.search <- Some "";
  check target "armed but empty" (Some Tui_types.Text_row_search)
    (resolved state)
;;

let test_a_preset_name_being_typed_claims_over_the_palette () =
  let state = fresh_state () in
  state.Tui_types.view <- Tui_types.Config;
  state.Tui_types.config_pane <- Tui_types.Config_presets;
  state.Tui_types.preset_save_draft <- Some "nightly";
  state.Tui_types.palette_open <- true;
  check target "preset name first" (Some Tui_types.Text_preset_name)
    (resolved state)
;;

let test_a_preset_draft_claims_only_on_its_own_pane () =
  let state = fresh_state () in
  state.Tui_types.preset_save_draft <- Some "nightly";
  check target "not on another surface" None (resolved state);
  state.Tui_types.view <- Tui_types.Config;
  check target "not on another Config pane" None (resolved state);
  state.Tui_types.config_pane <- Tui_types.Config_presets;
  check target "on its own pane" (Some Tui_types.Text_preset_name)
    (resolved state)
;;

let test_an_inline_setting_claims_over_the_palette () =
  let state = fresh_state () in
  state.Tui_types.runtime_param_edit <-
    Some
      { Tui_types.rpe_key = "keeper.turn_budget"
      ; rpe_value_type = "int"
      ; rpe_draft = "12"
      ; rpe_replace_on_type = true
      ; rpe_mode = Tui_types.Friendly_value
      ; rpe_choices = []
      };
  state.Tui_types.palette_open <- true;
  check target "runtime param first" (Some Tui_types.Text_runtime_param)
    (resolved state)
;;

(* The wizard is a field like the others, and it is open on exactly one pane,
   so its presence is the whole condition. It claims over the palette and row
   search the same way a preset name does: what is being typed belongs to the
   thing that was opened last. *)
let voice_wizard_open state =
  state.Tui_types.voice_wizard <-
    Some
      (Tui_types.voice_wizard_open ~section:Voice_setup.Tts
         ~provider:Voice_wizard.Elevenlabs ~revision:"a-revision")
;;

let test_the_voice_wizard_claims_over_the_palette () =
  let state = fresh_state () in
  voice_wizard_open state;
  state.Tui_types.palette_open <- true;
  state.Tui_types.search <- Some "";
  check target "the wizard first" (Some Tui_types.Text_voice_wizard) (resolved state)
;;

(* An inline setting is opened from inside the config pane the wizard is on,
   so the two can be open at once; the one opened last is the runtime param,
   and it takes the keys. *)
let test_an_inline_setting_claims_over_the_voice_wizard () =
  let state = fresh_state () in
  voice_wizard_open state;
  state.Tui_types.runtime_param_edit <-
    Some
      { Tui_types.rpe_key = "keeper.turn_budget"
      ; rpe_value_type = "int"
      ; rpe_draft = "12"
      ; rpe_replace_on_type = true
      ; rpe_mode = Tui_types.Friendly_value
      ; rpe_choices = []
      };
  check target "the inline setting first" (Some Tui_types.Text_runtime_param)
    (resolved state)
;;

(* Closing it hands the keys back rather than leaving them held by a field
   nothing draws. *)
let test_closing_the_wizard_releases_the_keys () =
  let state = fresh_state () in
  voice_wizard_open state;
  state.Tui_types.voice_wizard <- None;
  check target "nothing claims it now" None (resolved state)
;;

let test_the_identity_form_claims_before_its_filter () =
  let state = fresh_state () in
  identity_surface state;
  state.Tui_types.identity_filter <- Some "git";
  check target "filter alone" (Some Tui_types.Text_identity_filter)
    (resolved state);
  state.Tui_types.identity_app_form <-
    Some
      { Tui_types.iaf_provider = "github"
      ; iaf_label = "GitHub"
      ; iaf_field = Tui_types.App_client_id
      ; iaf_client_id = ""
      ; iaf_client_secret = ""
      ; iaf_scopes = ""
      };
  check target "form first" (Some Tui_types.Text_identity_app_form)
    (resolved state)
;;

let test_the_identity_fields_let_go_of_a_compact_frame () =
  (* A frame the last paint had to draw compact is not showing these fields,
     which is the ground the key dispatch already refused them on. *)
  let state = fresh_state () in
  identity_surface state;
  state.Tui_types.identity_filter <- Some "git";
  check target "drawn" (Some Tui_types.Text_identity_filter) (resolved state);
  check target "compact" None (resolved ~compact_viewport:true state)
;;

let test_the_palette_keeps_a_compact_frame () =
  (* The palette draws over the surface rather than beside it, and its key
     handler never asked about the viewport. Paste follows typing. *)
  let state = fresh_state () in
  state.Tui_types.palette_open <- true;
  check target "compact" (Some Tui_types.Text_palette)
    (resolved ~compact_viewport:true state)
;;

let test_a_board_post_being_written_claims_its_draft () =
  let state = fresh_state () in
  state.Tui_types.view <- Tui_types.Board;
  check target "reading the board" None (resolved state);
  state.Tui_types.board_mode <- Tui_types.Board_compose;
  check target "writing a post" (Some Tui_types.Text_board_draft)
    (resolved state)
;;

let test_the_palette_claims_over_a_board_draft () =
  (* The palette draws over the board pane, and its key handler runs first.
     A paste follows the characters. *)
  let state = fresh_state () in
  state.Tui_types.view <- Tui_types.Board;
  state.Tui_types.board_mode <- Tui_types.Board_compose;
  state.Tui_types.palette_open <- true;
  check target "palette first" (Some Tui_types.Text_palette) (resolved state)
;;

let test_browser_url_input_ownership () =
  let state = fresh_state () in
  let open Tui_types.Browser_lane_view in
  Tui_types.show_browser_lane state;
  state.Tui_types.browser_lane <- Some
    { (switch_source Automation (create ())) with url_draft = Some "https://example.org" };
  check target "URL owns typing and paste" (Some Tui_types.Text_browser_url) (resolved state);
  state.Tui_types.palette_open <- true;
  check target "palette takes priority" (Some Tui_types.Text_palette) (resolved state);
  state.Tui_types.palette_open <- false;
  check target "hidden compact URL does not take input" None (resolved ~compact_viewport:true state);
  state.Tui_types.view <- Tui_types.Overview;
  check target "hidden URL does not capture another surface" None (resolved state)
;;

let test_browser_reader_chrome_scope () =
  let state = fresh_state () in
  let module Lane = Tui_types.Browser_lane_view in
  List.iter (fun source ->
    Tui_types.show_browser_lane state;
    state.Tui_types.browser_lane <- Some (Lane.switch_source source (Lane.create ()));
    check bool "reader owns its context row" true
      (Option.is_some (Tui_types.browser_lane_on_screen state));
    check int "reader highlights its Runtime family"
      (Tui_types.visible_surface_ring_index state Tui_types.Runtime)
      (Tui_types.visible_surface_ring_index state state.Tui_types.view);
    state.Tui_types.view <- Tui_types.Keepers Tui_types.Keeper_detail;
    check bool "retained browser does not hide Keeper chrome" true
      (Option.is_none (Tui_types.browser_lane_on_screen state)))
    [Lane.Live; Lane.Automation];
  state.Tui_types.view <- Tui_types.Connectors;
  state.Tui_types.browser_lane <- None;
  check bool "connector routing retains Keeper context" true
    (Option.is_none (Tui_types.browser_lane_on_screen state));
  check int "connector routing keeps its existing navigation family"
    (Tui_types.visible_surface_ring_index state (Tui_types.Keepers Tui_types.Keeper_list))
    (Tui_types.visible_surface_ring_index state Tui_types.Connectors)
;;

let test_reader_discards_active_and_queued_voice () =
  let state = fresh_state () in
  state.Tui_types.composer_focused <- true;
  state.Tui_types.voice_capture <- Some "analyst";
  state.Tui_types.voice_continuous <- Some "analyst";
  state.Tui_types.voice_floor <- Some (-50.);
  state.Tui_types.voice_level_db <- Some (-20.);
  Buffer.add_string state.Tui_types.msg_input "reviewed draft";
  Tui_types.release_composer_for_browser_reader state;
  check bool "composer releases input" false state.Tui_types.composer_focused;
  check (option string) "continuous capture stops" None state.Tui_types.voice_continuous;
  check bool "calibration and meter clear" true
    (state.Tui_types.voice_floor = None && state.Tui_types.voice_level_db = None);
  check (option string) "microphone remains occupied until completion"
    (Some "analyst") state.Tui_types.voice_capture;
  check bool "recorder receives discard" true
    (state.Tui_types.voice_stop_requested = Some Masc.Voice_bridge.Discard);
  (* Returning to the composer and stopping again cannot resurrect a result
     already queued before the reader was opened. *)
  Tui_types.request_voice_stop state Masc.Voice_bridge.Keep_what_was_heard;
  check bool "late transcript is discarded" true
    (Tui_types.settle_voice_transcript state ~keeper:"analyst"
     = Some Masc.Voice_bridge.Discard);
  check (option string) "completion releases microphone" None state.Tui_types.voice_capture;
  check bool "duplicate completion has no owner" true
    (Tui_types.settle_voice_transcript state ~keeper:"analyst" = None);
  check string "existing draft survives reader entry" "reviewed draft"
    (Buffer.contents state.Tui_types.msg_input);
  (* A fresh capture explicitly started after returning remains usable. *)
  state.Tui_types.voice_capture <- Some "analyst";
  state.Tui_types.voice_stop_requested <- None;
  check bool "fresh capture delivers" true
    (Tui_types.settle_voice_transcript state ~keeper:"analyst"
     = Some Masc.Voice_bridge.Keep_what_was_heard)
;;

let test_ask_answer_input_ownership () =
  let state = fresh_state () in
  let question : Masc.Tui_decode.ask_question =
    { aq_id = "q1"; aq_header = "Route"; aq_prompt = "Which route?";
      aq_mode = Masc.Tui_decode.Ask_single;
      aq_free_text = Masc.Tui_decode.Ask_choices_only;
      aq_choices = [{ac_id = "route"; ac_label = "Offered route"; ac_description = None}] }
  in
  state.Tui_types.view <- Tui_types.Approvals;
  state.Tui_types.ask_text_entry <- Some
    { ate_slot = Masc_tui_ask_projection.free_text_slot question; ate_text = "draft" };
  check target "answer owns typing and paste" (Some Tui_types.Text_ask_answer) (resolved state);
  check target "compact frame hides answer editor" None (resolved ~compact_viewport:true state);
  state.Tui_types.context_inspector_open <- true;
  check target "inspector hides answer editor" None (resolved state);
  state.Tui_types.context_inspector_open <- false;
  state.Tui_types.view <- Tui_types.Overview;
  check target "retained answer cannot capture another surface" None (resolved state)
;;

let () =
  Alcotest.run
    "tui text input target"
    [ ( "which field takes text",
        [ test_case "ask answer input ownership" `Quick test_ask_answer_input_ownership;
          test_case "reader discards active and queued voice" `Quick test_reader_discards_active_and_queued_voice;
          test_case "browser reader chrome scope" `Quick test_browser_reader_chrome_scope;
          test_case "browser URL input ownership" `Quick test_browser_url_input_ownership;
          test_case "nothing claims a plain surface" `Quick
            test_nothing_claims_a_plain_surface;
          test_case "the palette claims while it is open" `Quick
            test_the_palette_claims_while_it_is_open;
          test_case "row search claims while a query is armed" `Quick
            test_row_search_claims_while_a_query_is_armed;
          test_case "a preset name claims over the palette" `Quick
            test_a_preset_name_being_typed_claims_over_the_palette;
          test_case "a preset draft claims only on its own pane" `Quick
            test_a_preset_draft_claims_only_on_its_own_pane;
          test_case "the voice wizard claims over the palette" `Quick
            test_the_voice_wizard_claims_over_the_palette;
          test_case "an inline setting claims over the voice wizard" `Quick
            test_an_inline_setting_claims_over_the_voice_wizard;
          test_case "closing the wizard releases the keys" `Quick
            test_closing_the_wizard_releases_the_keys;
          test_case "an inline setting claims over the palette" `Quick
            test_an_inline_setting_claims_over_the_palette;
          test_case "the identity form claims before its filter" `Quick
            test_the_identity_form_claims_before_its_filter;
          test_case "the identity fields let go of a compact frame" `Quick
            test_the_identity_fields_let_go_of_a_compact_frame;
          test_case "the palette keeps a compact frame" `Quick
            test_the_palette_keeps_a_compact_frame;
          test_case "a board post being written claims its draft" `Quick
            test_a_board_post_being_written_claims_its_draft;
          test_case "the palette claims over a board draft" `Quick
            test_the_palette_claims_over_a_board_draft
        ] )
    ]
;;
