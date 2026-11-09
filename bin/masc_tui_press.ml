open Masc_tui_types

(* What a press on marked text does. Each constructor is a place a key
   already reaches, so a press never does something the keyboard cannot. *)
type ring_edge = Ring_before | Ring_after

type queue_selection = {
  qs_workspace : workspace_authority;
  qs_read_authority : unit ref;
  qs_keeper : string;
  qs_id : Masc_tui_queue_inspection.item_id;
  qs_text : string;
  qs_action_ready : bool;
}

type fragment_source =
  | Quit_notice of Masc_tui_action_notice.quit_confirmation
  | Rejection_notice of Masc_tui_action_notice.rejection

type notice_fragment = {
  nf_source : fragment_source;
  nf_cols : int;
  nf_index : int;
}

(* [Press_surface] is a Tab-ring entry, or a title-strip entry that is a
   surface of its own (Activity's Events and Logs, Planning's three stops).
   [Press_ring_edge] is the count of ring entries hidden
   past one edge of a narrow strip. The rest are the entries of one screen's
   own strip, each named by the value its cycle key steps through. A list row
   is named by its ID, so a refresh that reorders the list cannot move a
   press onto another row. *)
type press_target =
  | Press_surface of surface
  | Press_ring_edge of ring_edge
  | Press_keeper_tab of keeper_detail_tab
  | Press_config_pane of config_pane
  | Press_metrics_section of metrics_section
  | Press_tools_pane of tools_pane
  | Press_memory_category of memory_category_filter
  | Press_theme_filter of [ `All | `Dark | `Light ]
  | Press_ui_language
  | Press_runtime_mode of runtime_mode
  | Press_standalone_lanes
  | Press_usage_calls
  | Press_context_tab of Masc_tui_context_inspector.tab
  | Press_keeper_row of string
  | Press_keeper_view of Masc_tui_keeper_list_model.view
  | Press_chat_call of workspace_authority * unit ref * string * string
  | Press_lane_row of Masc_tui_lane_inventory.identity
  | Press_queue_selected of queue_selection
  | Press_input_rejection of Masc_tui_action_notice.rejection
  | Press_quit_confirmation of Masc_tui_action_notice.quit_confirmation
  | Press_notice_fragment of notice_fragment

(* An overlay keeps the surface's strip on its first row, and a press there
   would change the surface under a modal no key can leave that way. The
   Context inspector's tabs and the selected Queue row act only in their own
   overlay. *)
let press_changes_the_surface = function
  | Press_surface _ | Press_ring_edge _ | Press_keeper_tab _
  | Press_config_pane _ | Press_metrics_section _ | Press_tools_pane _
  | Press_memory_category _ | Press_theme_filter _ | Press_ui_language | Press_runtime_mode _
  | Press_standalone_lanes | Press_usage_calls | Press_keeper_row _ | Press_keeper_view _
  | Press_lane_row _ | Press_chat_call _ ->
      true
  | Press_context_tab _ | Press_queue_selected _ | Press_input_rejection _
  | Press_quit_confirmation _ | Press_notice_fragment _ -> false

let press_is_interactive = function
  | Press_input_rejection _ | Press_quit_confirmation _ | Press_notice_fragment _ -> false
  | Press_surface _ | Press_ring_edge _ | Press_keeper_tab _ | Press_config_pane _
  | Press_metrics_section _ | Press_tools_pane _ | Press_memory_category _
  | Press_theme_filter _ | Press_ui_language | Press_runtime_mode _ | Press_standalone_lanes
  | Press_usage_calls
  | Press_context_tab _ | Press_keeper_row _ | Press_keeper_view _ | Press_chat_call _ | Press_lane_row _
  | Press_queue_selected _ -> true

(* Marks drawn during the frame being built. The frame's renderer resets it
   before drawing and reads it back once the rows are final. *)
let press_marks : press_target Masc_tui_hit.registry = Masc_tui_hit.registry ()

let pressable target text = Masc_tui_hit.mark press_marks target text

let same_fragment_source left right =
  match left, right with
  | Quit_notice left, Quit_notice right -> Masc_tui_action_notice.same_quit left right
  | Rejection_notice left, Rejection_notice right -> Masc_tui_action_notice.same_rejection left right
  | Quit_notice _, Rejection_notice _ | Rejection_notice _, Quit_notice _ -> false

let fragment_text = function
  | Quit_notice confirmation -> fst (Masc_tui_action_notice.quit_ordinary confirmation)
  | Rejection_notice notice -> Masc_tui_action_notice.rejection_text notice

let notice_parts ~cols source =
  if cols <= 0 then []
  else
    Masc_tui_message_layout.split_styled_cells ~max_cells:cols
      (fragment_text source)
    |> List.mapi (fun index text ->
         { nf_source = source; nf_cols = cols; nf_index = index }, text)

let notice_fragments ~cols source =
  notice_parts ~cols source
  |> List.map (fun (fragment, text) -> Press_notice_fragment fragment, text)

let quit_fragments ~cols confirmation =
  notice_fragments ~cols (Quit_notice confirmation)

let rejection_fragments ~cols notice =
  notice_fragments ~cols (Rejection_notice notice)

let queue_selection_for_item state panel (item : Masc_tui_queue_inspection.item) =
  Option.map (fun id ->
    {qs_workspace=state.workspace_authority; qs_read_authority=state.workspace_read_authority;
     qs_keeper=panel.qp_keeper; qs_id=id; qs_text=item.text;
     qs_action_ready=(panel.qp_reading = Queue_current && server_authority_ready state)}) item.id

let queue_selection_visible ~inner_width ~marker ~text =
  let module Layout = Masc_tui_message_layout in
  let plain = marker ^ text in
  let marker_bytes = String.length marker in
  let retained = Layout.fitted_source_bytes plain inner_width in
  if Layout.display_width marker = 0 || retained < marker_bytes then false
  else
    let visible_text = String.sub plain marker_bytes (retained - marker_bytes) in
    Layout.display_width (String.trim visible_text) > 0

let same_queue_selection left right =
  left.qs_workspace = right.qs_workspace
  && left.qs_read_authority == right.qs_read_authority
  && String.equal left.qs_keeper right.qs_keeper
  && left.qs_id = right.qs_id
  && String.equal left.qs_text right.qs_text
  && left.qs_action_ready = right.qs_action_ready

let queue_owner_matches state panel ~viewport presented =
  same_queue_panel_owner presented (queue_panel_owner state panel ~viewport)

let queue_owner_authority_changed ~presented ~candidate =
  not (Option.equal same_queue_panel_owner presented candidate)

let play_card_matches ~presented ~current =
  match presented, current with
  | Some painted, Some current -> painted == current
  | Some _, None | None, Some _ | None, None -> false

let play_owner_authority_changed ~presented ~candidate =
  not (Option.equal ( == ) presented candidate)

type queue_play_input_owner =
  | Queue_input of queue_panel
  | Play_input
  | Wait_for_frame
  | Other_input

let queue_play_input_owner ~play_presented ~play_shown ~compact ~state ~beneath ~viewport ~presented_queue =
  if compact then Other_input
  else if Option.is_some play_presented then
    if play_card_matches ~presented:play_presented ~current:play_shown then Play_input else Wait_for_frame
  else match presented_queue, beneath, viewport, play_shown with
    | Some owner, Some panel, Some viewport, (Some _ | None)
      when queue_owner_matches state panel ~viewport owner -> Queue_input panel
    | Some _, (Some _ | None), (Some _ | None), (Some _ | None)
    | None, Some _, (Some _ | None), (Some _ | None)
    | None, None, (Some _ | None), Some _ -> Wait_for_frame
    | None, None, (Some _ | None), None -> Other_input

let presented_queue_selection zones =
  Masc_tui_hit.to_list zones |> List.find_map (fun (_, _, _, target) ->
    match target with
    | Press_queue_selected selected -> Some selected
    | Press_surface _ | Press_ring_edge _ | Press_keeper_tab _ | Press_config_pane _
    | Press_metrics_section _ | Press_tools_pane _ | Press_memory_category _
    | Press_theme_filter _ | Press_ui_language | Press_runtime_mode _ | Press_standalone_lanes | Press_usage_calls
    | Press_context_tab _ | Press_keeper_row _ | Press_keeper_view _ | Press_chat_call _ | Press_lane_row _
    | Press_input_rejection _ | Press_quit_confirmation _ | Press_notice_fragment _ -> None)

(* All rows must belong to one notice, in order, at the same physical width.
   Each target can only be made together with its source text above. *)
let presented_fragment_sources ~rows ~cols complete =
  complete |> List.filter_map (fun (row, _, _, target) ->
    match target with
    | Press_notice_fragment fragment when fragment.nf_index = 0 && fragment.nf_cols = cols ->
        let source = fragment.nf_source in
        let expected = notice_parts ~cols source in
        let visible index (expected_fragment, text) =
          List.exists (fun (actual_row, actual_first, actual_last, actual_target) ->
            match actual_target with
            | Press_notice_fragment actual ->
                actual.nf_cols = cols && actual.nf_index = expected_fragment.nf_index
                && same_fragment_source source actual.nf_source
                && actual_row = row + index && actual_row > 0 && actual_row <= rows
                && actual_first = 1 && actual_last <= cols
                && actual_last = Masc_tui_message_layout.display_width text
            | Press_quit_confirmation _ | Press_input_rejection _ | Press_surface _
            | Press_ring_edge _ | Press_keeper_tab _ | Press_config_pane _
            | Press_metrics_section _ | Press_tools_pane _ | Press_memory_category _
            | Press_theme_filter _ | Press_ui_language | Press_runtime_mode _
            | Press_standalone_lanes | Press_usage_calls | Press_context_tab _ | Press_keeper_row _ | Press_keeper_view _
            | Press_chat_call _ | Press_lane_row _ | Press_queue_selected _ -> false) complete in
        if List.length expected > 1 && List.for_all Fun.id (List.mapi visible expected)
        then Some source else None
    | Press_notice_fragment _ | Press_quit_confirmation _ | Press_input_rejection _
    | Press_surface _ | Press_ring_edge _ | Press_keeper_tab _ | Press_config_pane _
    | Press_metrics_section _ | Press_tools_pane _ | Press_memory_category _
    | Press_theme_filter _ | Press_ui_language | Press_runtime_mode _
    | Press_standalone_lanes | Press_usage_calls | Press_context_tab _ | Press_keeper_row _ | Press_keeper_view _
    | Press_chat_call _ | Press_lane_row _ | Press_queue_selected _ -> None)

let presented_input_rejection ~rows ~cols zones =
  let complete = Masc_tui_hit.complete_to_list zones in
  let single = complete |> List.find_map (fun (row, first, last, target) ->
    match target with
    | Press_input_rejection notice
      when row > 0 && row <= rows && first > 0 && last <= cols
           && last - first + 1 =
              Masc_tui_message_layout.display_width (Masc_tui_action_notice.rejection_text notice) ->
        Some notice
    | Press_input_rejection _ | Press_surface _ | Press_ring_edge _ | Press_keeper_tab _
    | Press_config_pane _ | Press_metrics_section _ | Press_tools_pane _
    | Press_memory_category _ | Press_theme_filter _ | Press_ui_language
    | Press_runtime_mode _ | Press_standalone_lanes | Press_usage_calls | Press_context_tab _
    | Press_keeper_row _ | Press_keeper_view _ | Press_chat_call _ | Press_lane_row _ | Press_queue_selected _
    | Press_quit_confirmation _ | Press_notice_fragment _ -> None) in
  match single with
  | Some _ -> single
  | None ->
      presented_fragment_sources ~rows ~cols complete |> List.find_map (function
        | Rejection_notice notice -> Some notice
        | Quit_notice _ -> None)

let presented_quit_confirmation ~rows ~cols zones =
  let complete = Masc_tui_hit.complete_to_list zones in
  let single = complete |> List.find_map (fun (row, first, last, target) ->
    match target with
    | Press_quit_confirmation confirmation
      when row > 0 && row <= rows && first > 0 && last <= cols
           && last - first + 1 =
              Masc_tui_message_layout.display_width
                (fst (Masc_tui_action_notice.quit_ordinary confirmation)) ->
        Some confirmation
    | Press_quit_confirmation _ | Press_input_rejection _ | Press_surface _
    | Press_ring_edge _ | Press_keeper_tab _ | Press_config_pane _
    | Press_metrics_section _ | Press_tools_pane _ | Press_memory_category _
    | Press_theme_filter _ | Press_ui_language | Press_runtime_mode _
    | Press_standalone_lanes | Press_usage_calls | Press_context_tab _ | Press_keeper_row _ | Press_keeper_view _
    | Press_chat_call _ | Press_lane_row _ | Press_queue_selected _ | Press_notice_fragment _ -> None) in
  match single with
  | Some _ -> single
  | None ->
      presented_fragment_sources ~rows ~cols complete |> List.find_map (function
        | Quit_notice confirmation -> Some confirmation
        | Rejection_notice _ -> None)

let queue_selection_authority_changed ~presented ~candidate =
  not (Option.equal same_queue_selection
    (presented_queue_selection presented) (presented_queue_selection candidate))

let resolve_queue_selection ~require_action_ready ~state ~panel ~items presented =
  match panel.qp_detail, queue_panel_selected_index ~items panel with
  | None, Some index ->
    (match List.nth_opt items index with
     | Some item ->
       (match queue_selection_for_item state panel item with
        | Some current when same_queue_selection presented current
            && (not require_action_ready || current.qs_action_ready) -> Some current.qs_id
        | Some _ | None -> None)
     | None -> None)
  | None, None | Some _, Some _ | Some _, None -> None
