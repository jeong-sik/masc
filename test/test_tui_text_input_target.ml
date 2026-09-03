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
      | Some Tui_types.Text_palette -> "palette"
      | Some Tui_types.Text_row_search -> "row-search"
      | Some Tui_types.Text_identity_app_form -> "identity-app-form"
      | Some Tui_types.Text_identity_filter -> "identity-filter"
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
      };
  state.Tui_types.palette_open <- true;
  check target "runtime param first" (Some Tui_types.Text_runtime_param)
    (resolved state)
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

let () =
  Alcotest.run
    "tui text input target"
    [ ( "which field takes text",
        [ test_case "nothing claims a plain surface" `Quick
            test_nothing_claims_a_plain_surface;
          test_case "the palette claims while it is open" `Quick
            test_the_palette_claims_while_it_is_open;
          test_case "row search claims while a query is armed" `Quick
            test_row_search_claims_while_a_query_is_armed;
          test_case "a preset name claims over the palette" `Quick
            test_a_preset_name_being_typed_claims_over_the_palette;
          test_case "a preset draft claims only on its own pane" `Quick
            test_a_preset_draft_claims_only_on_its_own_pane;
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
