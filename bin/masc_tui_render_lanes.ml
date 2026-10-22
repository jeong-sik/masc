(** Lanes and System / Runtime / Clients screens. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection
module Render_schedule = Masc_tui_render_schedule

let standing_colour standing = match Masc_tui_lane_standing.status standing with
  | Masc_tui_theme.Ok -> Theme.ok ()
  | Masc_tui_theme.Warn -> Theme.warn ()
  | Masc_tui_theme.Bad -> Theme.bad ()
  | Masc_tui_theme.Info -> Theme.info ()
  | Masc_tui_theme.Muted -> Theme.muted ()

let format_context_tokens = Masc_tui_types.format_context_tokens

(* A refusal is bad news about the key pressed; a pending write is a warning
   about what the screen shows, as is a list that may be stale
   ([Masc_tui_types.runtime_lane_stale_lines], drawn in warn). *)
let runtime_lane_notice_style = function
  | Masc_tui_types.Lane_write_refused _ -> Theme.bad ()
  | Masc_tui_types.Lane_write_pending -> Theme.warn ()
  | Masc_tui_types.Lane_write_committed receipt ->
    if Masc_tui_runtime_config_receipt.lane_needs_attention receipt then Theme.warn ()
    else Theme.info ()

let standalone_lane_detail_lines ~now ~width (lane : Tui_decode.standalone_lane) =
  let ordered values =
    match values with
    | [] -> "(none)"
    | values ->
      values
      |> List.mapi (fun index value ->
        Printf.sprintf "%d %s" (index + 1) (Terminal_text.single_line value))
      |> String.concat "  →  "
  in
  let wrap style text =
    Message_layout.wrap_words ~max_cells:(max 1 (width - 4)) text
    |> List.map (fun line -> style, "  " ^ line)
  in
  let purpose =
    Option.value ~default:"No consumer purpose reported by this server."
      lane.sl_purpose
  in
  let answer = Tui_decode.standalone_lane_answer lane in
  (* Three facts the server has always sent and nothing drew.

     [required] is the one that changes what an operator does about a lane
     that cannot run: an optional lane nobody configured is a choice, and a
     required one is a hole.

     [configuration_state] separates "nobody configured this" from "the
     registry could not be read", which the status word beside the lane
     collapses into one "unavailable". The block draws the admission error
     below, and those two states each carry one, so this is the typed half
     of a distinction that was only ever legible as prose.

     The last terminal run is what the totals cannot say. [ok/fail/cancel
     962/133/0] reads the same whether the failures were this morning or
     last quarter, and an idle lane says nothing at all about when it last
     did work. *)
  let obligation = if lane.sl_required then "Required" else "Optional" in
  let configuration =
    Tui_decode.standalone_lane_configuration_phrase
      lane.sl_configuration_state
  in
  let last_run =
    match lane.sl_last_outcome, lane.sl_last_terminal_at with
    | None, _ -> "no retained terminal observation"
    | Some outcome, None -> "last run " ^ Terminal_text.single_line outcome
    | Some outcome, Some at ->
      Printf.sprintf "last run %s %s ago"
        (Terminal_text.single_line outcome)
        (Masc_tui_answering.elapsed_text ~now at)
  in
  (* By the state alone. This block draws no glyph, so a colour that also
     answered "is it required" would make a split nothing else in the block
     recovers -- the row two lines up gives every colour class its own mark
     for exactly that reason. The obligation is in the words. *)
  let state_style =
    match lane.sl_configuration_state with
    | Tui_decode.Lane_off -> Theme.recede ()
    | Tui_decode.Lane_ready -> Ansi.reset
    | Tui_decode.Lane_slotless | Tui_decode.Lane_unconfigured -> Theme.warn ()
    | Tui_decode.Lane_registry_unavailable -> Theme.bad ()
  in
  let jev_lines =
    match lane.sl_jev with
    | None -> []
    | Some Tui_decode.Jev_off -> wrap (Theme.recede ()) "JEV OFF"
    | Some Tui_decode.Jev_cli_only ->
      wrap (Theme.recede ()) "JEV unavailable: Board lane is CLI-only"
    | Some Tui_decode.Jev_lane_unavailable ->
      wrap (Theme.warn ()) "JEV unavailable: Board lane is not ready"
    | Some (Tui_decode.Jev_configured { destinations }) ->
      let named (destination : Tui_decode.standalone_lane_jev_destination) =
        Printf.sprintf "%s (%s)" destination.sljd_destination_uri destination.sljd_model
      in
      wrap Ansi.reset
        (Printf.sprintf
           "JEV CONFIGURED \xc2\xb7 %s"
           (Terminal_text.single_line (String.concat ", " (List.map named destinations))))
  in
  let activity =
    let status = Tui_decode.standalone_lane_status_to_string lane.sl_status in
    match lane.sl_status, lane.sl_last_started_at with
    | Tui_decode.Standalone_off, _ ->
        Printf.sprintf "Activity: off · %d accepted runs finishing" lane.sl_running_count
    | Tui_decode.Standalone_running, Some started ->
        Printf.sprintf "Activity: %d running · latest started %s ago"
          lane.sl_running_count (Masc_tui_answering.elapsed_text ~now started)
    | (Standalone_running, None)
    | ((Standalone_idle | (Standalone_degraded | (Standalone_no_retained_observation | Standalone_unavailable))), _) -> "Activity: " ^ status in
  let run_stats =
    let total = lane.sl_retained_run_count in
    if total > 0 then
      let rate =
        float_of_int lane.sl_succeeded_count /. float_of_int total *. 100.0
      in
      let p50_str =
        (* Use the shared elapsed-time formatting for this observation. *)
        match lane.sl_p50_elapsed_s with
        | Some s -> (
            match Message_layout.elapsed_text s with
            | Some text -> Printf.sprintf " · p50 latency %s" text
            | None -> "")
        | None -> ""
      in
      Printf.sprintf "Runs: %d retained (%d ok / %d fail / %d cancel) · %.1f%% success%s"
        total lane.sl_succeeded_count lane.sl_failed_count
        lane.sl_cancelled_count rate p50_str
    else "Runs: no runs retained yet"
  in
  let slot_distribution =
    (* Every finished run, by who answered it. The slot counts cover only
       runs that named a slot; the rest come from the server by why they
       named none. On Board Attention most of those are Vendor System One,
       which answers before any slot is bound (#37296), so a reader who saw
       only the slots would take its answers for missing records. *)
    let dist =
      match lane.sl_selected_slots with
      | [] -> []
      | scs ->
        [ String.concat ", "
            (List.map
               (fun (sc : Tui_decode.standalone_lane_slot_count) ->
                  Printf.sprintf "%s: %d"
                    (Terminal_text.single_line sc.slsc_slot_id) sc.slsc_count)
               scs) ]
    in
    match dist @ standalone_lane_runs_without_slot_parts lane with
    | [] -> []
    | parts ->
      wrap Ansi.reset
        ("Slot selection history: " ^ String.concat " \xc2\xb7 " parts)
  in
  wrap Ansi.bold
    (Printf.sprintf "%s · %s" (Terminal_text.single_line lane.sl_label)
       (Terminal_text.single_line purpose))
  @ wrap state_style
      (Printf.sprintf "%s lane · %s · %s" obligation
         configuration last_run)
  @ wrap Ansi.dim
      (Printf.sprintf "Config: [runtime.exact_output_lanes.%s]"
         (Standalone_lane.to_id lane.sl_lane))
  @ jev_lines
  @ wrap Ansi.reset activity
  @ wrap (if lane.sl_failed_count > 0 then Theme.warn () else Ansi.reset)
      run_stats
  @ slot_distribution
  @ wrap Ansi.reset
      ("Catalog attempts (admitted order): " ^ ordered lane.sl_admitted_slots)
  @ wrap Ansi.reset
      ("Then CLI (after catalog exhaustion): " ^ ordered lane.sl_cli_slots)
  @ wrap
      (if lane.sl_dropped_slots = [] then Ansi.dim else Theme.warn ())
      ("Dropped before execution: " ^ ordered lane.sl_dropped_slots)
  @ (match lane.sl_admission_error with
     | None -> []
     | Some error ->
       wrap (Theme.bad ())
         ("Admission error: " ^ Terminal_text.single_line error))
  (* The file's shape and the editor [e] opens are the same two sentences on
     every lane, so they cost four of this pane's rows to say what no lane
     answers. They are under [?] with the key that acts on them, the move the
     Keeper columns and the Memory ST words already made. What stays here is
     what this lane answers: the section it configures is on the Config row
     above, and the evidence line below says what its runs retain. *)
  @ wrap Ansi.reset answer.sla_output_meaning
  @ wrap Ansi.dim answer.sla_evidence

let rec take_rows remaining acc = function
  | _ when remaining <= 0 -> List.rev acc
  | [] -> List.rev acc
  | row :: rest -> take_rows (remaining - 1) (row :: acc) rest

(* Editing takes the pane while it is open. A long CLI tail otherwise sits
   below the lane matrix and can put the acting cursor outside the frame. *)
let render_exact_lane_provider_editor (state : state) editor =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let lane = Masc_tui_types.slot_editor_target_name editor.Masc_tui_types.se_target in
  let entries = Masc_tui_types.slot_editor_rows state in
  let count = List.length entries in
  let selected_index = Masc_tui_types.slot_editor_cursor_index state in
  (* j/k stop on slots, never on a group's title, so an empty group has no
     row to move into. Its title says where a slot comes from instead: [a]
     picks one, and the runtime's kind decides the group it joins. *)
  let group_rows kind title =
    let rows =
      entries
      |> List.mapi (fun index row -> index, row)
      |> List.filter (fun (_, row) -> row.Masc_tui_types.sr_kind = kind)
    in
    let heading =
      match rows with
      | [] -> Printf.sprintf "  %s (0) · a adds one" title
      | _ :: _ -> Printf.sprintf "  %s (%d)" title (List.length rows)
    in
    (None, heading)
    :: List.map (fun (index, row) -> Some index, row.Masc_tui_types.sr_slot) rows
  in
  let display_rows =
    group_rows Masc_tui_types.Catalog_slot "HTTP slots · tried first"
    @ group_rows Masc_tui_types.Official_client_slot
        "CLI slots · tried after every HTTP slot"
  in
  box_top buf cols;
  box_line buf cols (screen_title (" MASC / " ^ lane ^ " / Model order"));
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.info ())
    (Printf.sprintf "  %s · HTTP candidates first, then CLI candidates"
       (Terminal_text.single_line lane));
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
     box_lines_styled buf cols ~style:(Theme.warn ())
       (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail));
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
     box_lines_styled buf cols ~style:(runtime_lane_notice_style notice)
       (Keeper_chat.terminal_safe_text ~preserve_newlines:true
          (Masc_tui_types.runtime_lane_notice_text notice)));
  List.iter
    (fun line -> box_line_styled buf cols ~style:(Theme.warn ())
       ("  " ^ Keeper_chat.terminal_safe_text line))
    (Masc_tui_types.runtime_lane_stale_lines state);
  (match state.runtime_lane_write with
   | Masc_tui_types.Lane_write_posting ->
     box_line_styled buf cols ~style:(Theme.info ()) "  Saving candidate order..."
   | Masc_tui_types.Lane_write_rereading _ ->
     box_line_styled buf cols ~style:(Theme.info ()) "  Reading current candidate order..."
   | Masc_tui_types.Lane_write_idle -> ());
  (match Masc_tui_types.runtime_picker_projection
     ~page:(Masc_tui_types.runtime_exact_picker_page state ~terminal_rows ~cols) state with
   | Some picker ->
     let action = match picker.Masc_tui_types.rlp_pick with
       | Masc_tui_types.Pick_exact_lane_replacement _ -> "Replace selected candidate", "Enter replace"
       | Pick_media_failover | Pick_route_default | Pick_conversation_lane _ | Pick_exact_lane _
       | Pick_new_lane _ -> "Add fallback candidate", "Enter add" in
     box_line_styled buf cols ~style:(Theme.info ())
       ("  " ^ fst action);
     box_line_styled buf cols ~style:(Theme.recede ())
       ("  " ^ picker.Masc_tui_types.rlp_summary);
     if picker.Masc_tui_types.rlp_choices = [] then
       box_line_styled buf cols ~style:(Theme.recede ())
         (Masc_tui_types.runtime_picker_empty_note picker)
     else
       picker.Masc_tui_types.rlp_choices
       |> List.iteri (fun offset choice ->
            match choice with
            | Masc_tui_types.Lane_choice _ -> ()
            | Masc_tui_types.Runtime_choice runtime ->
            let destination =
              match picker.rlp_pick, runtime.ro_exact_slot_group with
              | Masc_tui_types.Pick_exact_lane_replacement _, Tui_decode.Exact_http_slots -> "HTTP replacement"
              | Masc_tui_types.Pick_exact_lane_replacement _, Tui_decode.Exact_cli_slots -> "CLI replacement"
              | (Pick_conversation_lane _, Tui_decode.Exact_http_slots)
              | (Pick_exact_lane _, Tui_decode.Exact_http_slots)
              | (Pick_new_lane _, Tui_decode.Exact_http_slots)
              | (Pick_media_failover, Tui_decode.Exact_http_slots)
              | (Pick_route_default, Tui_decode.Exact_http_slots) -> "HTTP tail"
              | (Pick_conversation_lane _, Tui_decode.Exact_cli_slots)
              | (Pick_exact_lane _, Tui_decode.Exact_cli_slots)
              | (Pick_new_lane _, Tui_decode.Exact_cli_slots)
              | (Pick_media_failover, Tui_decode.Exact_cli_slots)
              | (Pick_route_default, Tui_decode.Exact_cli_slots) -> "CLI tail"
              | (Pick_conversation_lane _, Tui_decode.Exact_output_unsupported)
              | (Pick_exact_lane _, Tui_decode.Exact_output_unsupported)
              | (Pick_exact_lane_replacement (_, _, _), Tui_decode.Exact_output_unsupported)
              | (Pick_new_lane _, Tui_decode.Exact_output_unsupported)
              | (Pick_media_failover, Tui_decode.Exact_output_unsupported)
              | (Pick_route_default, Tui_decode.Exact_output_unsupported) -> "no output schema"
            in
            let line bracket note =
              Printf.sprintf "  %s [%s] %s%s"
                (if picker.Masc_tui_types.rlp_selected_row = Some offset
                 then ">" else " ")
                bracket
                (Masc_tui_types.runtime_model_picker_title runtime)
                note
            in
            (match
              Masc_tui_types.runtime_pick_availability
                picker.Masc_tui_types.rlp_pick runtime
            with
            | Masc_tui_types.Pick_refused refusal ->
              (* The bracket carries the refusal: a note after the model
                 is the first thing the frame cuts. *)
              box_line_styled buf cols ~style:(Theme.recede ())
                (line (Masc_tui_types.runtime_pick_refusal_tag refusal) "")
            | Masc_tui_types.Pick_available ->
              (if picker.rlp_selected_row = Some offset
               then box_line_selected buf cols
               else box_line buf cols)
                (line destination
                   (if List.mem runtime.ro_id picker.rlp_already
                    then "  (already declared)" else "")));
            let prefix = "      Quota scope " in
            let suffix = " · " ^ format_context_tokens runtime.ro_effective_max_context ^ " context" in
            let scope_width =
              max 1 (framed_inner_width cols - Message_layout.display_width (prefix ^ suffix)) in
            box_line_styled buf cols ~style:(Theme.recede ())
              (prefix ^ Masc_tui_message_layout.truncate_middle scope_width
                 (Terminal_text.single_line (runtime_quota_scope_label runtime)) ^ suffix));
     (match picker.rlp_selected_row with
      | Some offset ->
        (match List.nth_opt picker.rlp_choices offset with
         | Some (Masc_tui_types.Runtime_choice runtime) ->
           box_line_styled buf cols ~style:(Theme.recede ())
             ("  " ^ Masc_tui_message_layout.truncate_middle (max 1 (framed_inner_width cols - 2))
                (Terminal_text.single_line ("Connection " ^ runtime.ro_provider_id ^ " · Selected " ^ runtime.ro_id)))
         | Some (Masc_tui_types.Lane_choice _) | None -> ())
      | None -> ());
     box_line_styled buf cols ~style:(Theme.info ())
       ("  " ^ Masc_tui_types.runtime_picker_keys (snd action) picker.rlp_filter)
   | None ->
     let catalog = match state.runtime_catalog_reading with
       | Runtime_catalog_read | Runtime_catalog_refreshing _ | Runtime_catalog_stale _ -> state.runtime_catalog
       | Runtime_catalog_unread | Runtime_catalog_loading | Runtime_catalog_failed _ -> [] in
     (match state.runtime_catalog_reading with
      | Runtime_catalog_read -> ()
      | Runtime_catalog_refreshing _ | Runtime_catalog_stale _ ->
          box_line_styled buf cols ~style:(Theme.warn ())
            ("  " ^ Terminal_text.single_line (Masc_tui_types.runtime_catalog_reading_suffix state.runtime_catalog_reading))
      | Runtime_catalog_unread ->
          box_line_styled buf cols ~style:(Theme.recede ()) "  runtime catalogue unread · showing slot IDs"
      | Runtime_catalog_loading ->
          box_line_styled buf cols ~style:(Theme.recede ()) "  runtime catalogue loading · showing slot IDs"
      | Runtime_catalog_failed detail ->
          box_line_styled buf cols ~style:(Theme.warn ())
            ("  runtime catalogue read failed: " ^ Terminal_text.single_line detail ^ " · showing slot IDs"));
     (* Reserve a key line and the frame bottom; at least the selected row
        stays visible on a short terminal. The ordinal places the moving
        window in the complete declaration. *)
     let visible =
       let reserved = if entries <> [] && Option.is_none selected_index then 8 else 7 in
       max 1 (min (List.length display_rows) (rows - count_frame_lines buf - reserved))
     in
     let selected_display_index =
       display_rows
       |> List.find_mapi (fun display_index (index, _) ->
            if index <> None && index = selected_index
            then Some display_index
            else None)
       |> Option.value ~default:0
     in
     let first =
       min (max 0 (List.length display_rows - visible))
         (max 0 (selected_display_index - (visible / 2)))
     in
     if entries = [] then
       box_line_styled buf cols ~style:(Theme.recede ())
         "  no provider slots declared; a adds one"
     else
       display_rows
       |> List.iteri (fun display_index (index, label) ->
            if display_index >= first && display_index < first + visible then (
              match index with
              | None -> box_line_styled buf cols ~style:(Theme.info ()) label
              | Some index ->
              let row = List.nth entries index in
              let kind =
                match row.Masc_tui_types.sr_kind with
                | Masc_tui_types.Catalog_slot -> "HTTP"
                | Masc_tui_types.Official_client_slot -> "CLI"
                | Masc_tui_types.Media_route_slot -> "ROUTE"
              in
              let line =
                Printf.sprintf "  %s %d/%d  [%s] %s%s"
                  (if Some index = selected_index then ">" else " ")
                  (index + 1) count kind
                  (match List.find_opt (fun (runtime : Tui_decode.runtime_option) ->
                     String.equal runtime.ro_id row.Masc_tui_types.sr_slot) catalog with
                   | Some runtime -> Masc_tui_types.runtime_model_picker_title runtime
                   | None -> Terminal_text.single_line row.Masc_tui_types.sr_slot)
                  (if row.Masc_tui_types.sr_admitted then ""
                   else "  (not admitted)")
              in
              if Some index = selected_index
              then box_line_selected buf cols line
              else box_line buf cols line));
     if entries <> [] && Option.is_none (selected_index) then
       box_line_styled buf cols ~style:(Theme.warn ())
         "  no slot selected; j/k selects a current slot";
     (match Masc_tui_types.slot_editor_cursor_row state with
      | None -> ()
      | Some row ->
        let selected_runtime = List.find_opt (fun (runtime : Tui_decode.runtime_option) ->
           String.equal runtime.ro_id row.Masc_tui_types.sr_slot) catalog in
        let identity = Terminal_text.single_line
          ((match selected_runtime with
            | Some runtime -> "Connection " ^ runtime.ro_provider_id ^ " · "
            | None -> "") ^ "Selected " ^ row.sr_slot) in
        (match selected_runtime with
         | Some runtime ->
           let prefix = "  Quota scope " in
           let suffix = " · " ^ format_context_tokens runtime.ro_effective_max_context ^ " context" in
           let scope_width =
             max 1 (framed_inner_width cols - Message_layout.display_width (prefix ^ suffix)) in
           box_line_styled buf cols ~style:(Theme.info ())
             (prefix ^ Masc_tui_message_layout.truncate_middle scope_width
                (Terminal_text.single_line (runtime_quota_scope_label runtime)) ^ suffix)
         | None -> box_line_styled buf cols ~style:(Theme.warn ()) "  Model details unavailable");
        box_line_styled buf cols ~style:(Theme.recede ())
          ("  " ^ Masc_tui_message_layout.truncate_middle (max 1 (framed_inner_width cols - 2)) identity));
     box_line_styled buf cols ~style:(Theme.recede ())
       "  arrows/j/k select · r replace model/effort · a add fallback · 1 first in group";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  J/K reorder · x remove · Enter/d settings · e TOML · Esc back";
     box_line_styled buf cols ~style:(Theme.recede ())
       "  Changes save immediately; file and application results are shown separately");
  for _ = 1 to max 0 (rows - count_frame_lines buf - 2) do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

let render_lanes_overview (state : state) =
  match state.slot_editor with
  | Some ({ Masc_tui_types.se_target = Masc_tui_types.Exact_lane_slots _; _ } as editor) ->
    render_exact_lane_provider_editor state editor
  | None | Some { Masc_tui_types.se_target = Masc_tui_types.Media_failover_slots; _ } ->
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let inner = max 1 (framed_inner_width cols) in
  let buf = Buffer.create 4096 in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    (* Both readings come from [runtime_surface], which the Runtime screen
       loads and this one does not, so on a first visit here they were zeros
       nobody measured. *)
    let lane_reading =
      Option.map
        (fun snapshot ->
          string_of_int (List.length snapshot.rss_resolved.rrs_lanes))
        state.runtime_surface
    in
    let all_reading =
      Option.map
        (fun snapshot ->
          string_of_int (List.length snapshot.rss_resolved.rrs_runtimes))
        state.runtime_surface
    in
    let lane_count = lanes_inventory_count state in
    match state.lane_inventory with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Lanes") (title_missing_reading ~error:state.standalone_lanes_error) timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC Lanes")
          (tab_strip
             ~width:
               (tab_strip_width ~cols
                  ~before:(screen_title " MASC Lanes" ^ tab_strip_gap)
                  ~after:("  " ^ timestamp ^ "  " ^ connection_badge state))
             ~press:pressable
             [ ( tab_entry_label "Candidate orders" lane_reading
               , false
               , Press_runtime_mode Masc_tui_types.Runtime_lanes )
             ; ( tab_entry_label "All runtimes" all_reading
               , false
               , Press_runtime_mode Masc_tui_types.Runtime_all )
             ; ( tab_entry_label "Lanes"
                   (Some
                      (Masc_tui_message_layout.count_noun lane_count "lane"))
               , true
               , Press_standalone_lanes )
             ])
          timestamp (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let observed_heading = match state.lane_inventory with
    | None -> "  All lanes"
    | Some snapshot ->
        let observed = Unix.localtime snapshot.Masc.Tui_decode_lane_inventory.observed_at in
        let standings = Masc_tui_lane_standing.counts
            (List.map Masc_tui_lane_inventory.row_standing snapshot.Masc.Tui_decode_lane_inventory.rows) in
        Printf.sprintf "  All lanes · observed %02d:%02d:%02d%s"
          observed.Unix.tm_hour observed.Unix.tm_min observed.Unix.tm_sec
          (if standings = "" then "" else " · " ^ standings) in
  box_line_styled buf cols ~style:(Ansi.bold ^ Theme.info ()) observed_heading;
  List.iter (fun notice -> box_line_styled buf cols ~style:(Theme.warn ()) ("  " ^ notice))
    (Masc_tui_types.lane_inventory_notice_lines ~cols state);
  let inventory = lane_inventory_rows state in
  let layout = Masc_tui_types.lanes_scrolled ~cols state in
  let height = Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row in
  let scroll = Masc_tui_scroll.normalize ~count:layout.sc_count ~height state.lanes_scroll
    |> Masc_tui_scroll.ensure_visible ~cursor:state.lanes_cursor ~height in
  (* The standing leads the state, so a narrow STATE column still shows
     whether the lane is ready, failing or never set up. *)
  let summary row = Masc_tui_lane_standing.word (Masc_tui_lane_inventory.row_standing row) ^ " · "
    ^ Terminal_text.single_line (match state.lane_inventory with
      | Some snapshot -> Masc_tui_lane_inventory.row_summary_in snapshot row
      | None -> Masc_tui_lane_inventory.row_summary row) in
  let status_width = List.fold_left (fun width row -> max width
      (Message_layout.display_width (summary row))) (String.length "STATE") inventory
    |> min (max 1 (inner / 2)) in
  let mark_width = 2 in
  let label_width = max 1 (inner - mark_width - status_width - 2) in
  box_line_styled buf cols ~style:(Theme.recede ())
    (String.make mark_width ' ' ^ fit_width "LANE" label_width ^ "  " ^ fit_width "STATE" status_width);
  let window = Rows.of_list ~first:scroll ~height inventory in
  for offset = 0 to height - 1 do
    let index = scroll + offset in
    match Rows.at window index with
    | None when offset = 0 && Option.is_none state.lane_inventory ->
        box_line_styled buf cols ~style:(Theme.recede ())
          (if Option.is_some state.standalone_lanes_error then "  r: retry inventory"
           else "  reading all lanes…")
    | None -> box_empty buf cols
    | Some row ->
        let standing = Masc_tui_lane_inventory.row_standing row in
        let label = fit_width (Terminal_text.single_line
            (Masc_tui_lane_inventory.family_label row.selection ^ " · " ^ row.label)) label_width in
        let mark = fit_width (Masc_tui_lane_standing.mark standing) mark_width in
        let state_text = fit_width (summary row) status_width in
        (* The final frame owns click geometry, including narrow terminals and
           scrolling. A retained mark names an identity, never a former index. *)
        let marked text = pressable (Press_lane_row row.id) (fit_width text inner) in
        (* The selection band takes no colour of its own, so the selected row
           keeps the mark and drops the styles. *)
        if index = state.lanes_cursor then
          box_line_selected buf cols (marked (mark ^ label ^ "  " ^ state_text))
        else
          let row_style = if Masc_tui_lane_standing.recedes standing then Theme.recede () else "" in
          let state_style = match standing with
            | Masc_tui_lane_standing.Failing -> Theme.bad ()
            | Masc_tui_lane_standing.(Ready | Waiting | Changing | Off | Not_set_up | Unobserved) -> row_style in
          box_line buf cols (marked (standing_colour standing ^ mark ^ Ansi.reset
            ^ row_style ^ label ^ "  " ^ Ansi.reset ^ state_style ^ state_text ^ Ansi.reset))
  done;
  (match Masc_tui_scroll.position_row ~scroll ~height (List.length inventory) with
   | None -> ()
   | Some text -> box_line_styled buf cols ~style:(Theme.recede ()) text);
  (* The selected row gets the remaining preview space; the list scrolls
     independently and Enter opens the full existing management surface. *)
  (match selected_inventory_lane state with
   | None -> ()
   | Some inventory_row ->
       let action_error_rows =
         (match state.lanes_action_error with
          | None -> 0
          | Some detail ->
              box_lines_row_count ~cols
                (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail))
         + (match state.runtime_lane_notice with
            | None -> 0
            | Some notice ->
                box_lines_row_count ~cols
                  (Keeper_chat.terminal_safe_text ~preserve_newlines:true
                     (Masc_tui_types.runtime_lane_notice_text notice)))
         + List.length (Masc_tui_types.runtime_lane_stale_lines state)
       in
       let picker_rows =
         match Masc_tui_types.runtime_picker_projection state with
         | None -> 0
         | Some picker -> 1 + max 1 (2 * List.length picker.rlp_choices)
       in
       let available =
         max 0
           (rows - count_frame_lines buf - action_error_rows - picker_rows - 3)
       in
       if available > 0 then begin
         box_divider buf cols;
         let detail = match selected_standalone_lane state with
           | Some lane ->
               (Theme.info (), "  Space: activity · s: models · a: candidate")
               :: standalone_lane_detail_lines ~now:(Unix.gettimeofday ()) ~width:inner lane
           | None ->
               ((match inventory_row.Masc.Tui_decode_lane_inventory.selection with
                 | Browser _ -> ["Space: activity · Enter: browser"]
                 | Machine _ -> ["Space: activity · Enter: spectate"]
                 | Exact _ | Declaration _ | Manual_instance _ -> [])
                @ Masc_tui_lane_inventory.detail_lines inventory_row
                @ Masc_tui_lane_inventory.exact_output_lines
                    ~selected:(Masc_tui_types.lanes_exact_output_name state inventory_row) inventory_row)
               |> List.concat_map (fun line ->
                    Terminal_text.single_line line
                    |> Message_layout.wrap_words ~max_cells:(max 1 (inner - 2))
                    |> List.map (fun line -> Theme.recede (), "  " ^ line))
         in
         let shown = take_rows available [] detail in
         let shown =
           if List.length detail <= available then shown
           else
             match List.rev shown with
             | [] -> []
             | _ :: rest ->
               List.rev ((Theme.warn (), "  … d: full reading") :: rest)
         in
         List.iter
           (fun (style, line) -> box_line_styled buf cols ~style line)
           shown
       end);
  (match state.lanes_action_error with
   | None -> ()
   | Some detail ->
       box_lines_styled buf cols ~style:(Theme.warn ())
         (Keeper_chat.terminal_safe_text ~preserve_newlines:true detail));
  (* The lane editor's notice is the Runtime view's too: a standalone lane's
     slots are written from here, and a write started on either view can
     still be out when the other is opened. *)
  (match state.runtime_lane_notice with
   | None -> ()
   | Some notice ->
       (* The refusal can be the server's own multi-line sentence, which wraps
          to more rows than the frame has left. Bound it to what remains after
          the picker and the footer, keeping the "lane write refused" head and
          the actionable tail. *)
       let picker_rows =
         match Masc_tui_types.runtime_picker_projection state with
         | None -> 0
         | Some picker -> 1 + max 1 (2 * List.length picker.rlp_choices)
       in
       let budget = max 1 (rows - count_frame_lines buf - picker_rows - 4) in
       box_lines_styled_bounded buf cols ~style:(runtime_lane_notice_style notice) ~budget
         (Keeper_chat.terminal_safe_text ~preserve_newlines:true
                   (Masc_tui_types.runtime_lane_notice_text notice)));
  List.iter
    (fun line ->
       box_line_styled buf cols ~style:(Theme.warn ())
         ("  " ^ Keeper_chat.terminal_safe_text line))
    (Masc_tui_types.runtime_lane_stale_lines state);
  (* The runtime-candidate picker the "a" key opens. Same projection the
     Runtime surface draws; the row order both render and the key handler
     read is the picker's own, so the cursor and the drawing cannot drift. *)
  (match Masc_tui_types.runtime_picker_projection state with
   | None -> ()
   | Some picker ->
       box_line_styled buf cols ~style:(Theme.info ())
         (Printf.sprintf
            "  adding a candidate to the candidate order of %s — %s — %s"
            (Terminal_text.single_line picker.Masc_tui_types.rlp_lane)
            picker.Masc_tui_types.rlp_summary
            (Masc_tui_types.runtime_picker_keys "Enter append"
               picker.Masc_tui_types.rlp_filter));
       if picker.Masc_tui_types.rlp_choices = [] then
         box_line_styled buf cols ~style:(Theme.recede ())
           (Masc_tui_types.runtime_picker_empty_note picker)
       else
         List.iteri
           (fun offset choice ->
              match choice with
              | Masc_tui_types.Lane_choice _ -> ()
              | Masc_tui_types.Runtime_choice runtime ->
              (* A refusal leads the row, as in the provider editor: a note
                 after the label is the first thing the frame cuts. *)
              let refusal_prefix, note =
                match
                  Masc_tui_types.runtime_pick_availability
                    picker.Masc_tui_types.rlp_pick runtime
                with
                | Masc_tui_types.Pick_refused refusal ->
                  ( Ansi.dim ^ "[" ^ Masc_tui_types.runtime_pick_refusal_tag refusal
                    ^ "] " ^ Ansi.reset
                  , "" )
                | Masc_tui_types.Pick_available ->
                  ( ""
                  , if List.exists (String.equal runtime.ro_id) picker.rlp_already
                    then "  (already a slot)"
                    else if List.exists (String.equal runtime.ro_provider) picker.rlp_providers
                    then "  (same provider as a current slot)"
                    else "" )
              in
              let mark =
                if picker.Masc_tui_types.rlp_selected_row = Some offset then ">" else " "
              in
              let ctx =
                Printf.sprintf " [%s context]"
                  (format_context_tokens runtime.ro_effective_max_context)
              in
              let def = if runtime.ro_is_default then " [default]" else "" in
              box_line buf cols
                (Printf.sprintf "  %s %s%s%s%s%s"
                   mark refusal_prefix
                   (Masc_tui_types.runtime_model_picker_title runtime)
                   ctx def
                   (Ansi.dim ^ note ^ Ansi.reset));
              box_line_styled buf cols ~style:(Theme.recede ())
                ("      Quota scope " ^ Terminal_text.single_line (runtime_quota_scope_label runtime)
                  ^ " · Connection " ^ Terminal_text.single_line runtime.ro_provider_id
                  ^ " · " ^ Terminal_text.single_line runtime.ro_id))
           picker.Masc_tui_types.rlp_choices);
  let used_rows = count_frame_lines buf in
  for _ = 1 to max 0 (rows - used_rows - 2) do
    box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

(* Status colours for standalone-lane runs, keyed on the decoded variant; a label
   the producer adds later decodes to [Lane_run_other] and reads muted until
   it is named here. *)
let lane_run_status_style = function
  | Tui_decode.Lane_run_succeeded
  | Tui_decode.Lane_run_approved
  | Tui_decode.Lane_run_reviewed
  | Tui_decode.Lane_run_committed -> Theme.ok ()
  | Tui_decode.Lane_run_cancelled
  | Tui_decode.Lane_run_rejected
  | Tui_decode.Lane_run_superseded
  | Tui_decode.Lane_run_deferred
  | Tui_decode.Lane_run_review_cancelled -> Theme.warn ()
  | Tui_decode.Lane_run_failed
  | Tui_decode.Lane_run_completion_persistence_failed
  | Tui_decode.Lane_run_completion_durability_unknown
  | Tui_decode.Lane_run_infrastructure_unavailable
  | Tui_decode.Lane_run_not_reviewed
  | Tui_decode.Lane_run_commit_failed
  | Tui_decode.Lane_run_raised -> Theme.bad ()
  | Tui_decode.Lane_run_running -> Theme.info ()
  | Tui_decode.Lane_run_other _ -> Theme.muted ()

let observed_lane_label (target : Lane_run_identity.t) =
  Lane_run_identity.label target

let lane_run_subject (run : Tui_decode.lane_run_summary) =
  match run.lrs_run_kind, run.lrs_subject_id with
  | Tui_decode.Lane_run_task_verification, Some subject -> "task " ^ subject
  | Tui_decode.Lane_run_goal_verification, Some subject -> "goal " ^ subject
  | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    None ->
    run.lrs_actor
;;

(** Recent retained runs of one standalone lane. The list is the paged summary:
    no payload ever crosses it, so Enter fetches one exact detail. *)
let render_lane_run_list (state : state) ~(lane : Lane_run_identity.t) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let runs =
    match state.lane_runs with
    | None -> []
    | Some runs -> runs
  in
  let shown = List.length runs in
  let coverage =
    let count = match state.lane_runs_total with
      | Some total -> Printf.sprintf "%d loaded / %d retained" shown total
      | None -> Printf.sprintf "%d loaded" shown in
    let continuation =
      if state.lane_runs_loading then " · loading"
      else match state.lane_runs_next with
        | Some _ -> " · ] older"
        | None -> if Option.is_some state.lane_runs then " · end" else "" in
    count ^ continuation in
  let header =
    Printf.sprintf "%s · %s (%s)  %s"
      (screen_title " MASC Lanes")
      (fit_width
         (Terminal_text.single_line (observed_lane_label lane))
         20)
      coverage (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let identity_heading =
    match lane with
    | Lane_run_identity.Verifier -> "SUBJECT"
    | Lane_run_identity.Librarian
    | Lane_run_identity.Hitl_auto_judge
    | Lane_run_identity.Board_attention
    | Lane_run_identity.Workspace_curator
    | Lane_run_identity.Candle_appraiser
    | Lane_run_identity.Browser_stagehand -> "ACTOR"
  in
  (* The slot takes what the drawn columns leave. *)
  let run_layout =
    Render_schedule.lane_run_layout
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  "
    ^ Render_schedule.lane_run_header_row ~identity_header:identity_heading
        ~layout:run_layout);
  box_divider buf cols;
  (match state.lane_runs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let layout = lanes_scrolled state ~cols in
  let content_height =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.lane_runs_scroll max_scroll) in
  let runs_window = Rows.of_list ~first:scroll ~height:content_height runs in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.lane_runs ~error:state.lane_runs_error
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (no retained runs for this lane)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      match Rows.at runs_window (index + scroll) with
      | None -> box_empty buf cols
      | Some (run : Tui_decode.lane_run_summary) ->
          let elapsed =
            match run.lrs_elapsed_s with
            | None -> Masc_tui_theme.Glyph.no_value
            | Some seconds -> (
                match Message_layout.elapsed_text seconds with
                | Some text -> text
                | None -> Masc_tui_theme.Glyph.no_value)
          in
          let line =
            "  "
            ^ Render_schedule.lane_run_row ~identity_header:identity_heading
                ~status_style:(lane_run_status_style run.lrs_status)
                ~layout:run_layout
                { Render_schedule.lrow_started =
                    lane_run_clock run.lrs_started_at
                ; lrow_subject =
                    Terminal_text.single_line (lane_run_subject run)
                ; lrow_status =
                    Tui_decode.lane_run_status_label run.lrs_status
                ; lrow_elapsed = elapsed
                ; lrow_slot =
                    Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
                      run.lrs_selected_slot
                }
          in
          if index + scroll = state.lane_runs_cursor then
            box_line_selected buf cols (Masc_tui_theme.strip_sgr line)
          else box_line buf cols line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "  [runs %s]" (Masc_tui_scroll.window_text ~scroll ~height:content_height shown));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:Masc_tui_keys.footer_hints_lanes_run_list);
  finish_surface state ~surface_key:"lane-runs" ~rows:terminal_rows ~cols buf

(* The total preview includes labels, fences and notices. Complete payloads
   that fit stay complete; oversized fields share the space left after each
   field's minimum preview. If even those minima do not fit, preserve the
   original prefix and name the omitted suffix count. Stored bytes do not change. *)
let lane_run_preview_source_max_bytes = 65536

type lane_run_prepared_document =
  { full_text : string
  ; document : string
  ; notice : string
  }

type lane_run_prepared_field =
  { index : int
  ; heading : string
  ; heading_bytes : int
  ; prepared : lane_run_prepared_document
  ; minimum_bytes : int
  ; full_bytes : int
  }

let lane_run_payload_lines ~width json =
  let fence = fenced_document_text ~language:"json" in
  let prepare_document value =
    let full_text = Yojson.Safe.pretty_to_string value in
    let document = fence full_text in
    let notice = Printf.sprintf "… truncated, total %d bytes" (String.length full_text) in
    { full_text; document; notice }
  in
  let minimum_document_bytes prepared =
    min (String.length prepared.document)
      (String.length prepared.document - String.length prepared.full_text
       + String.length prepared.notice + 1)
  in
  (* Field allocation reserves the minimum above; non-object payloads receive
     the full preview budget. Both callers therefore leave a non-negative room. *)
  let render_document ~budget prepared =
    let document, notices =
      if String.length prepared.document <= budget then prepared.document, []
      else
        let wrapper_bytes = String.length prepared.document - String.length prepared.full_text in
        let room = budget - wrapper_bytes - String.length prepared.notice - 1 in
        let cut =
          match String.rindex_from_opt prepared.full_text room '\n' with
          | Some newline -> newline
          | None -> String_util.utf8_char_boundary prepared.full_text room
        in
        fence (String.sub prepared.full_text 0 cut), [ Theme.warn (), prepared.notice ]
    in
    let lines =
      document_markdown ~width document
      |> List.map (fun line -> Ansi.reset, line)
    in
    lines @ notices
  in
  match json with
  | `Assoc (_ :: _ as fields) ->
    let omitted count = Printf.sprintf "… %d more field(s) not rendered" count in
    let fields =
      List.mapi
        (fun index (name, value) ->
          let heading = Yojson.Safe.to_string (`String name) |> Terminal_text.single_line in
          let heading_bytes = String.length heading + 1 in
          let prepared = prepare_document value in
          { index; heading; heading_bytes; prepared
          ; minimum_bytes = heading_bytes + minimum_document_bytes prepared
          ; full_bytes = heading_bytes + String.length prepared.document })
        fields
    in
    let render_field budget field =
      (Ansi.bold, field.heading)
      :: render_document ~budget:(budget - field.heading_bytes) field.prepared
    in
    let total = List.fold_left (fun n field -> n + field.full_bytes) 0 fields in
    if total <= lane_run_preview_source_max_bytes then
      List.concat_map (fun field -> render_field field.full_bytes field) fields
    else begin
      let minimum_total fields =
        List.fold_left (fun n field -> n + field.minimum_bytes) 0 fields
      in
      let notice_bytes = function None -> 0 | Some text -> String.length text + 1 in
      let fields, suffix_notice =
        if minimum_total fields <= lane_run_preview_source_max_bytes then fields, None
        else
          let rec prefix used remaining notice acc = function
            | [] -> List.rev acc, None
            | field :: rest ->
              let next_notice =
                if List.is_empty rest then None else Some (omitted (remaining - 1))
              in
              if used + field.minimum_bytes + notice_bytes next_notice <= lane_run_preview_source_max_bytes then
                prefix (used + field.minimum_bytes) (remaining - 1) next_notice (field :: acc) rest
              else List.rev acc, notice
          in
          let count = List.length fields in
          prefix 0 count (Some (omitted count)) [] fields
      in
      let needed field = field.full_bytes - field.minimum_bytes in
      let ranked = List.stable_sort (fun a b -> Int.compare (needed a) (needed b)) fields in
      let rec allocate extra remaining = function
        | [] -> []
        | field :: rest ->
          let added = min (needed field) (extra / remaining) in
          (field, field.minimum_bytes + added) :: allocate (extra - added) (remaining - 1) rest
      in
      let extra = lane_run_preview_source_max_bytes - notice_bytes suffix_notice - minimum_total fields in
      let allocated =
        allocate extra (List.length fields) ranked
        |> List.sort (fun (a, _) (b, _) -> Int.compare a.index b.index)
      in
      let lines = List.concat_map (fun (field, budget) -> render_field budget field) allocated in
      match suffix_notice with None -> lines | Some text -> lines @ [ Theme.warn (), text ]
    end
  | _ ->
    render_document ~budget:lane_run_preview_source_max_bytes (prepare_document json)

let lane_run_decision_badge (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_decision with
  | Tui_decode.Lane_run_decision_approved -> Theme.ok (), "APPROVED"
  | Tui_decode.Lane_run_decision_rejected -> Theme.warn (), "REJECTED"
  | Tui_decode.Lane_run_decision_reviewed -> Theme.ok (), "REVIEWED"
  | Tui_decode.Lane_run_decision_committed -> Theme.ok (), "COMMITTED"
  | Tui_decode.Lane_run_decision_superseded -> Theme.info (), "SUPERSEDED"
  | Tui_decode.Lane_run_decision_pending -> Theme.info (), "NO DECISION YET"
  | Tui_decode.Lane_run_decision_not_reached -> Theme.warn (), "NO DECISION"
  | Tui_decode.Lane_run_not_a_decision -> Theme.info (), "NOT A VERDICT"
  | Tui_decode.Lane_run_decision_unknown -> Theme.muted (), "UNKNOWN"

let lane_run_tool_disposition_presentation = function
  | Tui_decode.Lane_run_tool_completed -> Theme.ok (), "✓"
  | Tui_decode.Lane_run_tool_deferred -> Theme.warn (), "△"
  | Tui_decode.Lane_run_tool_failed -> Theme.bad (), "✗"
  | Tui_decode.Lane_run_tool_disposition_other _ -> Theme.warn (), "?"

let lane_run_tool_call_summary (tool : Tui_decode.lane_run_tool) =
  let style, mark =
    lane_run_tool_disposition_presentation tool.lrt_disposition
  in
  let disposition =
    Tui_decode.lane_run_tool_disposition_label tool.lrt_disposition
    |> Terminal_text.single_line
  in
  Printf.sprintf "%s%s%s %s%s%s ‹%s · %.0fms›%s"
    style Ansi.bold mark
    (Terminal_text.single_line tool.lrt_name)
    Ansi.reset style disposition tool.lrt_duration_ms Ansi.reset

type lane_run_tool_counts =
  { completed : int
  ; deferred : int
  ; failed : int
  ; other : int
  }

let lane_run_tool_count_summary tools =
  let counts =
    List.fold_left
      (fun counts (tool : Tui_decode.lane_run_tool) ->
         match tool.lrt_disposition with
         | Tui_decode.Lane_run_tool_completed ->
           { counts with completed = counts.completed + 1 }
         | Tui_decode.Lane_run_tool_deferred ->
           { counts with deferred = counts.deferred + 1 }
         | Tui_decode.Lane_run_tool_failed ->
           { counts with failed = counts.failed + 1 }
         | Tui_decode.Lane_run_tool_disposition_other _ ->
           { counts with other = counts.other + 1 })
      { completed = 0; deferred = 0; failed = 0; other = 0 }
      tools
  in
  [ Theme.bad (), "✗", counts.failed, "failed"
  ; Theme.warn (), "△", counts.deferred, "deferred"
  ; Theme.warn (), "?", counts.other, "other"
  ; Theme.ok (), "✓", counts.completed, "completed"
  ]
  |> List.filter_map (fun (style, mark, count, label) ->
    if count = 0 then None
    else
      Some
        (Printf.sprintf "%s%s%s %s %s %d %s" style Ansi.reverse Ansi.bold mark
           (String.uppercase_ascii label) count Ansi.reset))
  |> String.concat " "

let lane_run_tool_summary = function
  | Tui_decode.Lane_run_no_tools_by_contract ->
    Theme.muted (), "TOOLS  none · exact-output runs do not use the MASC tool loop"
  | Tui_decode.Lane_run_tools_pending ->
    Theme.info (), "TOOLS  pending · the verifier run is still in progress"
  | Tui_decode.Lane_run_tools_contract_unknown ->
    Theme.muted (), "TOOLS  unknown · this run kind has no typed tool contract"
  | Tui_decode.Lane_run_tools_observed tools ->
    let calls = List.length tools in
    let counts = lane_run_tool_count_summary tools in
    let names =
      List.map lane_run_tool_call_summary tools
      |> String.concat "  │  "
    in
    let evidence =
      [ names ]
      |> List.filter (fun value -> not (String.equal value ""))
      |> String.concat "  ·  "
    in
    let call_count =
      Printf.sprintf "%d %s" calls (if calls = 1 then "CALL" else "CALLS")
    in
    let overview =
      if String.equal counts "" then call_count else counts ^ "  ──  " ^ call_count
    in
    (* fit_width clips the right edge, so put the worst typed disposition
       immediately after the label. Even an ultra-narrow terminal retains the
       operator-significant failure/deferred badge before call metadata. *)
    ( Ansi.reset
    , Printf.sprintf "%sTOOLS%s %s%s" Ansi.bold Ansi.reset overview
        (if String.equal evidence "" then "" else "  │  " ^ evidence) )

let lane_run_skill_summary = function
  | Tui_decode.Lane_run_no_skills_by_contract ->
    Theme.muted (),
    "SKILLS  none · these runs do not load Keeper Skill instructions"
  | Tui_decode.Lane_run_skills_contract_unknown ->
    Theme.muted (), "SKILLS  unknown · this run kind has no typed Skill contract"

let lane_run_gate_judgment_summary = function
  | Tui_decode.Lane_run_not_gate_judgment -> None
  | Tui_decode.Lane_run_gate_judgment_pending ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %spending%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.info ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_judgment_unavailable ->
    Some (Theme.warn (), "JUDGMENT  원문 사용 불가 · 판정 여부를 확인할 수 없습니다")
  | Tui_decode.Lane_run_gate_judgment_not_reached ->
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %snone%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset (Theme.warn ()) Ansi.reset )
  | Tui_decode.Lane_run_gate_advisory judgment ->
    let style =
      match judgment with
      | Keeper_approval_queue_rules_types.Approve -> Theme.ok ()
      | Keeper_approval_queue_rules_types.Deny -> Theme.warn ()
      | Keeper_approval_queue_rules_types.Require_human -> Theme.info ()
    in
    let label =
      Keeper_approval_queue_rules_types.advisory_judgment_to_string judgment
      |> String.uppercase_ascii
    in
    Some
      ( Ansi.reset
      , Printf.sprintf
          "%sJUDGMENT%s  %sADVISORY %s%s  ·  GATE RESOLUTION  NOT PROVEN BY THIS RUN"
          Ansi.bold Ansi.reset style label Ansi.reset )

let lane_run_summary_lines (detail : Tui_decode.lane_run_detail) =
  let subject =
    match detail.lrd_run_kind, detail.lrd_subject_id with
    | Tui_decode.Lane_run_task_verification, Some subject ->
      "  ·  TASK " ^ Terminal_text.single_line subject
    | Tui_decode.Lane_run_goal_verification, Some subject ->
      "  ·  GOAL " ^ Terminal_text.single_line subject
    | (Tui_decode.Lane_run_exact_output | Tui_decode.Lane_run_kind_other _), _
    | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
      None ->
      ""
  in
  let elapsed =
    match detail.lrd_elapsed_s with
    | None -> ""
    | Some seconds -> (
        match Message_layout.elapsed_text seconds with
        | Some text -> Printf.sprintf "  ·  %s" text
        | None -> "")
  in
  let slot =
    match detail.lrd_answer_source, detail.lrd_selected_slot with
    | Some _, _ | None, None -> ""
    | None, Some slot -> "  ·  SLOT " ^ Terminal_text.single_line slot
  in
  let answer_source =
    match detail.lrd_answer_source with
    | None -> []
    | Some (Tui_decode.Lane_run_answer_exact_attempt slot) ->
      [ Ansi.reset, "  ANSWER  EXACT · " ^ Terminal_text.single_line slot ]
    | Some (Tui_decode.Lane_run_answer_cli_slot slot) ->
      [ Ansi.reset, "  ANSWER  CLI · " ^ Terminal_text.single_line slot ]
    | Some (Tui_decode.Lane_run_answer_vendor_system_one { model; endpoint = _ }) ->
      [ ( Ansi.reset
        , "  ANSWER  VENDOR SYSTEM ONE · "
          ^ Terminal_text.single_line model
          ^ " · NO EXACT-FLOW RECEIPT" ) ]
  in
  let failure =
    match detail.lrd_failure with
    | None -> []
    | Some failure ->
      [ ( Theme.bad ()
        , Printf.sprintf
            "  CODE  %s  ·  %s"
            (Terminal_text.single_line failure.lrf_code)
            (Terminal_text.single_line failure.lrf_detail) ) ]
  in
  let decision_style, decision = lane_run_decision_badge detail in
  let tool_style, tools = lane_run_tool_summary detail.lrd_tool_evidence in
  let skill_style, skills = lane_run_skill_summary detail.lrd_skill_evidence in
  let gate_judgment =
    match lane_run_gate_judgment_summary detail.lrd_gate_judgment with
    | None -> []
    | Some (style, line) -> [ style, "  " ^ line ]
  in
  [ ( Ansi.reset
    , Printf.sprintf "  LANE  %s  ·  %s%s"
        (Lane_run_identity.to_id detail.lrd_lane)
        (Terminal_text.single_line
           (Tui_decode.lane_run_kind_label detail.lrd_run_kind))
        subject )
  ; ( Ansi.dim
    , Printf.sprintf "  ACTOR  %s  ·  STARTED %s%s%s"
        (Terminal_text.single_line detail.lrd_actor)
        (lane_run_clock detail.lrd_started_at) elapsed slot )
  ; ( Ansi.reset
    , Printf.sprintf "  DECISION  %s%s%s  ·  RUN  %s%s%s" decision_style
        decision Ansi.reset (lane_run_status_style detail.lrd_status)
        (Terminal_text.single_line
           (Tui_decode.lane_run_status_label detail.lrd_status))
        Ansi.reset )
  ]
  @ failure
  @ answer_source
  @ gate_judgment
  @ [ tool_style, "  " ^ tools; skill_style, "  " ^ skills ]

let lane_run_panel_titles (detail : Tui_decode.lane_run_detail) =
  match detail.lrd_run_kind, detail.lrd_tool_evidence with
  | Tui_decode.Lane_run_exact_output, _ ->
    "INPUT · RUN INPUT", "OUTPUT · RUN RESULT"
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    Tui_decode.Lane_run_tools_observed tools ->
    ( "INPUT · VERIFICATION REQUEST"
    , Printf.sprintf "OUTPUT · VERDICT + TOOL EVIDENCE (%d %s)"
        (List.length tools)
        (if List.length tools = 1 then "CALL" else "CALLS") )
  | (Tui_decode.Lane_run_task_verification | Tui_decode.Lane_run_goal_verification),
    (Tui_decode.Lane_run_tools_pending | Tui_decode.Lane_run_no_tools_by_contract
    | Tui_decode.Lane_run_tools_contract_unknown) ->
    "INPUT · VERIFICATION REQUEST", "OUTPUT · VERDICT + TOOL EVIDENCE"
  | Tui_decode.Lane_run_kind_other _, _ -> "INPUT", "OUTPUT"

let lane_run_payload_availability_lines ~width availability payload =
  match availability with
  | Masc.Exact_lane_run_registry.Available ->
    (match payload with
     | Some value -> lane_run_payload_lines ~width value
     | None -> [ Theme.warn (), "원문 상태 불일치: 사용 가능한 원문 필드가 없습니다" ])
  | Masc.Exact_lane_run_registry.Not_loaded ->
    [ Theme.muted (), "원문을 불러오지 않았습니다" ]
  | Masc.Exact_lane_run_registry.Unavailable error ->
    let text = "원문 사용 불가: " ^ Masc.Exact_lane_run_registry.payload_read_error_to_string error in
    Message_layout.wrap_words ~max_cells:(max 1 width) (Terminal_text.single_line text)
    |> List.map (fun line -> Theme.warn (), line)

let lane_run_input_lines ~width (detail : Tui_decode.lane_run_detail) =
  lane_run_payload_availability_lines ~width detail.lrd_input_availability (Some detail.lrd_input_payload)

let lane_run_output_lines ~details ~width (detail : Tui_decode.lane_run_detail) =
  let preflight_lines = match detail.lrd_librarian_preflight with
    | None -> []
    | Some reading ->
      let decision = match reading.lp_status with
        | Tui_decode.Preflight_awaiting -> "응답 대기"
        | Tui_decode.Preflight_not_called reason -> "호출하지 않음 · " ^ reason
        | Tui_decode.Preflight_failed reason -> if details then "호출 실패 · " ^ reason else "호출 실패"
        | Tui_decode.Preflight_invalid reason -> "답변 거절 · " ^ reason
        | Tui_decode.Preflight_judged judgment ->
          Masc.Typesafeai_librarian_preflight.decision_label judgment.choice in
      let path = match reading.lp_generation_path with
        | Tui_decode.Generation_not_entered -> "생성 Lane 진입 전"
        | Tui_decode.Generation_full_lane -> "생성 Lane 진입 · 실제 요청 수는 별도 기록"
        | Tui_decode.Generation_jev_no_change -> "생성 호출 생략 · 빈 변경 검증 통과" in
      let probabilities = match reading.lp_status with
        | Tui_decode.Preflight_judged judgment ->
          [Printf.sprintf "Confidence %.3f" judgment.confidence]
          @ List.map (fun (decision, probability) ->
              Printf.sprintf "%s %.3f" (Masc.Typesafeai_librarian_preflight.decision_label decision) probability)
              judgment.reported_probabilities
        | Preflight_awaiting | Preflight_not_called _ | Preflight_failed _ | Preflight_invalid _ -> [] in
      let elapsed = match reading.lp_elapsed_s with
        | None -> [] | Some seconds -> [Printf.sprintf "JEV elapsed %.3fs" seconds] in
      let model = match reading.lp_model with None -> [] | Some model -> ["Model " ^ model] in
      let rejection = match reading.lp_domain_rejection with
        | None -> [] | Some reason -> ["검증 거절 → 생성 Lane · " ^ reason] in
      let memory = match reading.lp_memory_scope, reading.lp_memory_result with
        | Tui_decode.Memory_inference_scope, _ -> "기억 판정: 회차 메모리에만 보관 · 저장하지 않음"
        | Tui_decode.Context_only_scope, None -> "기억 snapshot: Context 전용 · 저장하지 않음"
        | Tui_decode.Memory_disposition_scope, None -> "기억 snapshot: 적용 결과가 기록되지 않음"
        | (Tui_decode.Memory_disposition_scope | Tui_decode.Context_only_scope),
          Some (Tui_decode.Librarian_memory_unchanged (revision, facts)) ->
          Printf.sprintf "기억 snapshot: 변경 없음 · revision %d · %d facts" revision facts
        | (Tui_decode.Memory_disposition_scope | Tui_decode.Context_only_scope),
          Some (Tui_decode.Librarian_memory_rewritten {revision;facts;added;removed}) ->
          Printf.sprintf "기억 snapshot: +%d / -%d · revision %d · %d facts" added removed revision facts in
      let side_writes = List.map (fun (kind, status) ->
        let label = match kind with
          | Tui_decode.Context_write -> "Context"
          | Tui_decode.Continuity_write -> "Continuity" in
        let outcome = match status with
          | Tui_decode.Side_not_attempted -> "not attempted"
          | Tui_decode.Side_answer_missing -> "answer missing"
          | Tui_decode.Side_withheld -> "withheld"
          | Tui_decode.Side_outcome_unconfirmed -> "outcome unconfirmed"
          | Tui_decode.Side_committed -> "committed"
          | Tui_decode.Side_answer_refused detail -> "answer refused · " ^ detail
          | Tui_decode.Side_failed detail -> "failed · " ^ detail in
        label ^ ": " ^ outcome) reading.lp_side_writes in
      let document = String.concat "\n"
        ([path; memory] @ side_writes @ ["JEV 판정 · " ^ decision] @ rejection
      @ (if details then model @ elapsed @ probabilities @ [""; "원문 실행 증거"]
         else ["d: 모델·확률·원문 펼치기"])) in
      let document =
        if String.length document <= lane_run_preview_source_max_bytes then document
        else
          let notice = Printf.sprintf "\n… truncated preflight, total %d bytes" (String.length document) in
          let room = lane_run_preview_source_max_bytes - String.length notice in
          let cut = String_util.utf8_char_boundary document room in
          String.sub document 0 cut ^ notice in
      String.split_on_char '\n' document
      |> List.concat_map (fun text ->
          Message_layout.wrap_words ~max_cells:(max 1 width) (Terminal_text.single_line text)
          |> List.map (fun line -> Theme.info (), line))
  in
  let fold_memory_evidence = match detail.lrd_librarian_preflight with
    | Some {lp_memory_scope=Tui_decode.Memory_disposition_scope;_} -> true
    | Some {lp_memory_scope=(Tui_decode.Context_only_scope | Tui_decode.Memory_inference_scope);_} | None -> false in
  preflight_lines @ (if not details && fold_memory_evidence then [] else
  match detail.lrd_output_availability, detail.lrd_output with
  | None, _ -> [ Theme.muted (), "실행 중 · 아직 출력이 기록되지 않았습니다" ]
  | Some availability, output ->
    lane_run_payload_availability_lines ~width availability output)

module Continuity_report = Masc.Librarian_continuity_report

type run_inspection =
  | Inspection_lane of Tui_decode.lane_run_detail
  | Inspection_measurement of string * Measurement.t

let measurement_summary_lines (report : Continuity_report.t) =
  let counts = Measurement.counts report in
  let provenance = match report.provenance with
    | Continuity_report.Synthetic -> "SYNTHETIC INPUT" in
  [ Ansi.reset, "  MEANING PRESERVATION  " ^ Terminal_text.single_line report.run_id
  ; Ansi.dim, "  " ^ provenance ^ "  ·  " ^ Terminal_text.single_line report.started_at
  ; Ansi.reset,
    Printf.sprintf "  SAMPLES  %d  ·  SCORED %d  ·  FAILED %d  ·  INCOMPLETE %d"
      (List.length report.samples) counts.scored counts.failed counts.incomplete
  ]

let measurement_text_lines ~width lines =
  List.concat_map
    (fun (style, text) ->
      String.split_on_char '\n' text
      |> List.concat_map (fun line ->
        Message_layout.wrap_words ~max_cells:(max 1 width)
          (Terminal_text.single_line line)
        |> List.map (fun line -> style, line)))
    lines

let measurement_input_lines ~width ~sha256 (measurement : Measurement.t) =
  let report = measurement.report in
  let module R = Continuity_report in
  let metadata =
    [ "AUTHORITATIVE FILE  " ^ report.output_path
    ; "BLOB SHA256  " ^ sha256
    ; "Published blob is a copy; it may be collected."
    ; "INPUT  " ^ report.input_path
    ; "INPUT SHA256  " ^ report.input_sha256
    ; "CONFIG REVISION  " ^ report.config_revision
    ]
    @ (match report.binary_commit with None -> [] | Some value -> [ "BINARY COMMIT  " ^ value ])
    @ (match report.executable_sha256 with None -> [] | Some value -> [ "EXECUTABLE SHA256  " ^ value ])
    @ List.map (fun (id, sha256) ->
        "CONTEXT SHA256  " ^ id ^ "  " ^ sha256) measurement.context_hashes
  in
  measurement_text_lines ~width (List.map (fun text -> Ansi.dim, text) metadata)
  @ lane_run_payload_lines ~width
      (`List (List.map (fun (sample : R.sample) -> R.case_to_yojson sample.case) report.samples))

(* Apply the same byte ceiling as exact lane payloads before wrapping. The
   report and its full score distribution remain intact; only text is a preview. *)
let measurement_output_preview ~width ~output_path lines =
  let rec take remaining reversed = function
    | [] -> List.rev reversed, false
    | (style, text) :: rest ->
      let bytes = String.length text + 1 in
      if bytes <= remaining then take (remaining - bytes) ((style, text) :: reversed) rest
      else
        let prefix = String_util.utf8_prefix ~max_bytes:(max 0 remaining) text in
        List.rev ((style, prefix) :: reversed), true
  in
  let preview, truncated = take lane_run_preview_source_max_bytes [] lines in
  let notice =
    if truncated then
      [ Theme.warn (), Printf.sprintf
          "PREVIEW · output truncated at %d bytes; full report: %s"
          lane_run_preview_source_max_bytes output_path ]
    else []
  in
  measurement_text_lines ~width (notice @ preview)

let measurement_output_lines ~width (report : Continuity_report.t) =
  let module R = Continuity_report in
  let prepared (request : R.generation_request) =
    List.concat_map
      (fun (wire : Llm_provider.Request_wire_observer.observation) ->
        [ "PREPARED REQUEST  " ^ wire.provider ^ "  ·  " ^ wire.model
        ; "PRE-DISPATCH SHA256  " ^ wire.body_sha256 ])
      request.prepared_requests
  in
  let generation label (value : R.generation) =
    [ label ^ "  " ^ value.response.model ^ "  ·  runtime " ^ value.request.runtime_id
    ; "RESPONSE  " ^ value.response.response_id
    ; value.response.text
    ] @ prepared value.request
  in
  let question_lines = function
    | R.Provided text -> [ "QUESTION PROVIDED"; text ]
    | R.Generated value -> generation "QUESTION GENERATED" value
  in
  (* The sample header names the failed stage. Retain the stage when the
     header scrolls away, without repeating the FAILED status. *)
  let failed_generation label (value : R.failed_generation) =
    [ label ^ " CAUSE  " ^ value.error
    ; "REQUESTED  " ^ value.request.requested_model ^ "  ·  runtime " ^ value.request.runtime_id
    ] @ prepared value.request
    @ (match value.incomplete_response with
       | None -> []
       | Some response -> [ "INCOMPLETE RESPONSE  " ^ response.model ^ "  ·  " ^ response.response_id; response.text ])
  in
  let values =
    List.filter_map (fun (sample : R.sample) -> match sample.progress with
      | R.Scored { judgment; _ } -> Some (judgment.probability, sample.case.id)
      | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _
      | R.Answer_ready _ | R.Judge_failed _ -> None) report.samples
    |> List.sort (fun (a, id_a) (b, id_b) ->
        let order = Float.compare a b in if order = 0 then String.compare id_a id_b else order)
  in
  let probabilities =
    (Ansi.bold, "RAW PROBABILITIES · NO PASS THRESHOLD")
    :: (match values with
        | [] -> [ Theme.muted (), "No scored samples" ]
        | values -> List.map (fun (probability, id) ->
            Ansi.reset, id ^ "  " ^ Yojson.Safe.to_string (`Float probability)) values)
  in
  let samples = List.concat_map (fun (sample : R.sample) ->
      let style, status, lines = match sample.progress with
        | R.Not_started -> Theme.muted (), "NOT STARTED", []
        | R.Question_failed failed -> Theme.bad (), "QUESTION FAILED", failed_generation "QUESTION" failed
        | R.Question_ready question -> Theme.info (), "INCOMPLETE · QUESTION READY", question_lines question
        | R.Answer_failed (question, failed) -> Theme.bad (), "ANSWER FAILED",
            question_lines question @ failed_generation "ANSWER" failed
        | R.Answer_ready { question; answer } -> Theme.info (), "INCOMPLETE · ANSWER READY",
            question_lines question @ generation "ANSWER" answer
        | R.Judge_failed { question; answer; failure } -> Theme.bad (), "JUDGE FAILED",
            question_lines question @ generation "ANSWER" answer
            @ [ "JUDGE REQUESTED  " ^ failure.request.model ^ "  ·  " ^ failure.request.endpoint
              ; "JUDGE CAUSE  " ^ failure.error ]
        | R.Scored { question; answer; judgment } -> Ansi.reset, "SCORED",
            question_lines question @ generation "ANSWER" answer
            @ [ "JUDGE  " ^ judgment.response_model ^ "  ·  " ^ judgment.request.endpoint
              ; "Noul  " ^ Yojson.Safe.to_string (`Float judgment.probability)
              ; "TRUE  " ^ judgment.request.true_criteria
              ; "FALSE  " ^ judgment.request.false_criteria
              ; "REQUEST SHA256  " ^ judgment.request_body_sha256 ]
      in
      [ Ansi.dim, ""; style, sample.case.id ^ "  ·  " ^ status ]
      @ List.map (fun line -> Ansi.reset, line) lines) report.samples
  in
  measurement_output_preview ~width ~output_path:report.output_path (probabilities @ samples)

let inspection_summary_lines = function
  | Inspection_lane detail -> lane_run_summary_lines detail
  | Inspection_measurement (_, measurement) -> measurement_summary_lines measurement.report

let inspection_panel_titles = function
  | Inspection_lane detail -> lane_run_panel_titles detail
  | Inspection_measurement (_, measurement) ->
    (match measurement.report.provenance with
     | Continuity_report.Synthetic -> "INPUT · SYNTHETIC CASES"),
    "OBSERVATIONS · NO VERDICT"

let inspection_input_lines ~width = function
  | Inspection_lane detail -> lane_run_input_lines ~width detail
  | Inspection_measurement (sha256, report) -> measurement_input_lines ~width ~sha256 report

let inspection_output_lines ~details ~width = function
  | Inspection_lane detail -> lane_run_output_lines ~details ~width detail
  | Inspection_measurement (_, measurement) -> measurement_output_lines ~width measurement.report

let lane_run_stacked_lines ~details ~width detail =
  let input_title, output_title = inspection_panel_titles detail in
  let indent lines = List.map (fun (style, line) -> style, "  " ^ line) lines in
  [ Ansi.bold, "  " ^ input_title ]
  @ indent (inspection_input_lines ~width detail)
  @ [ Ansi.dim, ""; Ansi.bold, "  " ^ output_title ]
  @ indent (inspection_output_lines ~details ~width detail)

let lane_run_split_line buf cols ~left_width ~left ~right =
  let inner = framed_inner_width cols in
  let divider = " │ " in
  let divider_width = 3 in
  let right_width = max 1 (inner - left_width - divider_width) in
  let styled width (style, line) =
    fit_width (style ^ line ^ Ansi.reset) width
  in
  box_line buf cols
    (styled left_width left ^ Theme.recede () ^ divider ^ Ansi.reset
     ^ styled right_width right)

(* Top, header, its divider, bottom and footer. A loaded run also draws
   the divider beneath its summary. Split panes use one payload row for titles. *)
let lane_run_chrome_rows_without_summary = framed_chrome_rows
let lane_run_chrome_rows = lane_run_chrome_rows_without_summary + 1

let render_lane_run_detail (state : state) ~run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let measurement = match state.lanes_mode with
    | Lanes_measurement_detail _ -> true
    | Lanes_overview | Lanes_run_list _ | Lanes_run_detail _ | Lanes_inventory_detail _ -> false in
  let detail =
    if measurement then Option.map (fun report -> Inspection_measurement (run_id, report)) state.measurement_report
    else match state.lane_run_detail with
    | Some detail when String.equal detail.Tui_decode.lrd_run_id run_id ->
        Some (Inspection_lane detail)
    | Some _ | None -> None
  in
  let header =
    detail_heading ~cols
      ~lead:
        (Lead_text
           (screen_title
              (if measurement then measurement_detail_title
               else lane_run_detail_title)
           ^ "  "))
      ~id:run_id ~after:"" ~tail:(connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.lane_run_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text error);
       if Option.is_none detail then box_divider buf cols);
  let chrome_rows_for_error =
    match detail, state.lane_run_detail_error with
    | Some _, Some _ -> 1
    | None, Some _ -> 2
    | (Some _ | None), None -> 0
  in
  (* The position the footer carries: [None] where the drawing already says
     it -- nothing to read yet, or two panes whose titles each name their
     own window. *)
  let scroll, position, content_height =
    match detail, state.lane_run_detail_error with
    | None, error ->
      let filler_rows = max 1 (rows - lane_run_chrome_rows_without_summary - chrome_rows_for_error) in
      let line =
        match error with
        | None -> Ansi.dim, (if measurement then "  (loading measurement artifact)" else "  (loading exact run record)")
        | Some _ -> Ansi.dim, page_failed_note
      in
      box_line_styled buf cols ~style:(fst line) (snd line);
      for _ = 2 to filler_rows do
        box_empty buf cols
      done;
      0, None, 0
    | Some detail, (Some _ | None) ->
      let summary = inspection_summary_lines detail in
      let compact_preflight = match detail with
        | Inspection_lane {Tui_decode.lrd_librarian_preflight=Some _;_} -> not state.lane_run_preflight_details
        | Inspection_lane { lrd_librarian_preflight = None;_} | Inspection_measurement (_, _) -> false in
      let split = cols >= keeper_split_threshold_cols && not compact_preflight in
      let payload_rows =
        max 0
          (rows - List.length summary - lane_run_chrome_rows - chrome_rows_for_error)
      in
      let title_rows = if split then 1 else 0 in
      let content_height = max 0 (payload_rows - title_rows) in
      List.iter
        (fun (style, line) -> box_line_styled buf cols ~style line)
        summary;
      box_divider buf cols;
      if split then begin
        let inner = framed_inner_width cols in
        let divider_width = 3 in
        let left_width = max 1 ((inner - divider_width) / 2) in
        let right_width = max 1 (inner - left_width - divider_width) in
        let input_lines =
          inspection_input_lines ~width:left_width detail
        in
        let output_lines = inspection_output_lines ~details:state.lane_run_preflight_details ~width:right_width detail in
        if payload_rows = 0
        then 0, None, content_height
        else begin
          let input_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length input_lines - content_height)
          in
          let output_max_scroll =
            if content_height = 0
            then 0
            else max 0 (List.length output_lines - content_height)
          in
          let max_scroll = max input_max_scroll output_max_scroll in
          let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
          let input_scroll = min scroll input_max_scroll in
          let input_lines_window = Rows.of_list ~first:input_scroll ~height:content_height input_lines in
          let output_scroll = min scroll output_max_scroll in
          let input_title, output_title = inspection_panel_titles detail in
          lane_run_split_line buf cols ~left_width
            ~left:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" input_title
                  (Masc_tui_scroll.window_text ~scroll:input_scroll
                     ~height:content_height (List.length input_lines)) )
            ~right:
              ( Ansi.bold
              , Printf.sprintf "%s  %s" output_title
                  (Masc_tui_scroll.window_text ~scroll:output_scroll
                     ~height:content_height (List.length output_lines)) );
            let output_lines_window = Rows.of_list ~first:output_scroll ~height:content_height output_lines in
          for index = 0 to content_height - 1 do
            let left =
              Option.value
                (Rows.at input_lines_window (index + input_scroll))
                ~default:(Ansi.reset, "")
            in
            let right =
              Option.value
                (Rows.at output_lines_window (index + output_scroll))
                ~default:(Ansi.reset, "")
            in
            lane_run_split_line buf cols ~left_width ~left ~right
          done;
          scroll, None, content_height
        end
      end
      else begin
        let lines =
          if compact_preflight then
            inspection_output_lines ~details:false ~width:(max 1 (framed_inner_width cols - 4)) detail
          else lane_run_stacked_lines ~details:state.lane_run_preflight_details ~width:(max 1 (framed_inner_width cols - 4)) detail
        in
        let max_scroll =
          if content_height = 0
          then 0
          else max 0 (List.length lines - content_height)
        in
        let scroll = max 0 (min state.lane_run_detail_scroll max_scroll) in
        let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
        for index = 0 to content_height - 1 do
          match Rows.at lines_window (index + scroll) with
          | None -> box_empty buf cols
          | Some (style, line) -> box_line_styled buf cols ~style line
        done;
        scroll,
        Some (Masc_tui_scroll.window_text ~scroll ~height:content_height (List.length lines)),
        content_height
      end
  in
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ?position ~hints:(Masc_tui_keys.footer_hints_lanes_run_detail_for
         ~preflight:(match detail with
           | Some (Inspection_lane {Tui_decode.lrd_librarian_preflight=Some _;_}) -> true
           | Some (Inspection_lane { lrd_librarian_preflight = None;_})
           | Some (Inspection_measurement (_, _)) | None -> false)));
  finish_surface state ~clamped:(Lane_run_detail_scroll { scroll; content_height })
    ~surface_key:"lane-run" ~rows:terminal_rows ~cols buf

(* The clients roster: everyone attached to this workspace in one reading —
   directory agents, state-backed sessions, runtime fibers. The keeper
   roster answers "which Keepers exist"; this answers "who is here now",
   which includes identities no other surface lists, such as a non-keeper
   MCP client. One row per identity, sorted by name on the server, with the
   status dot, the type, the keeper a row is bound to when it is, and what
   task it holds. *)
type client_table_column =
  | Client_status_column | Client_name_column | Client_type_column
  | Client_acting_for_column | Client_task_column | Client_last_seen_column

let render_client_detail state (client : Masc.Tui_decode.client_row) =
  let terminal_rows, cols = get_terminal_size () in
  let width = max 1 (framed_inner_width cols - 2) in
  let field label value =
    ("  " ^ Ansi.bold ^ label ^ Ansi.reset)
    :: (Message_layout.wrap_words ~max_cells:width (Terminal_text.single_line value)
        |> List.map (fun line -> "  " ^ line))
  in
  let optional = function Some value -> value | None -> Masc_tui_theme.Glyph.no_value in
  let lines = field "Name:" client.cr_name
    @ field "Status:" (Masc.Tui_decode.client_status_to_string client.cr_status)
    @ field "Type:" client.cr_agent_type
    @ field "Acting for:" (optional client.cr_keeper_name)
    @ field "Task:" (optional client.cr_current_task)
    @ field "Last seen (as read):" client.cr_last_seen
    @ field "Observation age:" (Masc_tui_wire_age.text ~now:(Unix.gettimeofday ()) client.cr_last_seen)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"client-detail"
    ~frame:Chrome_overlay ~title:(screen_title " MASC Client Detail")
    ~hints:"j/k:scroll  PgUp/PgDn:page  g/G:first/last  Esc:clients"
    ~overflow:(Scrolled {scroll=state.client_detail_scroll;
                        report=(fun scroll -> Client_detail_scroll scroll)})
    ~body:(fun ~budget:_ c -> List.iter c.push lines)

let render_clients (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let clients =
    match state.clients_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.cls_clients
  in
  let shown = List.length clients in
  (* One reading of the clock for the frame: the header and every row's span
     are distances from the same instant, and two readings would put them a
     render apart. *)
  let now_s = Unix.gettimeofday () in
  let now = Unix.localtime now_s in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.clients_surface with
    | None ->
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title " MASC System / Runtime / Clients") (title_missing_reading ~error:state.clients_surface_error) timestamp
          (connection_badge state)
    | Some _ ->
        Printf.sprintf "%s (%d attached)  %s  %s"
          (screen_title " MASC System / Runtime / Clients") shown timestamp
          (connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Measured from the rows like the verification submitter column: a fixed
     width puts the columns after the longest name out of line with the
     rest, and session names are the column the eye scans by. *)
  let table_width = max 0 (framed_inner_width cols - 2) in
  let last_seen_width =
    List.fold_left (fun widest (row : Masc.Tui_decode.client_row) ->
      max widest (Message_layout.display_width (Masc_tui_wire_age.text ~now:now_s row.cr_last_seen)))
      (Message_layout.display_width "LAST SEEN") clients
    (* The table keeps its status and identity floor. Exact observations that
       exceed this share are read in the selected client's scrollable detail. *)
    |> min (max 9 (table_width - 9 - 16 - 2 * Masc_tui_table.cell_gap))
  in
  let name_width =
    List.fold_left
      (fun widest (row : Masc.Tui_decode.client_row) ->
         max widest
           (Message_layout.display_width
              (Terminal_text.single_line row.Masc.Tui_decode.cr_name)))
      16 clients
    |> min 24
    (* A future or unreadable stamp is deliberately shown verbatim by the age
       projection. Give its measured width priority over the identity floor,
       rather than disguising a raw clock as a folded age. *)
    |> min (max 1 (table_width - 9 - last_seen_width - 2 * Masc_tui_table.cell_gap))
  in
  (* The column carries a reading only where a client is bound to a Keeper
     under a name of its own. Where no row has one, its cells and header are
     seventeen blank columns, and the clock at the end of the row is what
     loses them: "last seen 01:4…" is not a time. *)
  let acting_for_drawn = Masc_tui_types.clients_act_for_others clients in
  let column_width = function
    | Client_status_column | Client_task_column -> 9
    | Client_last_seen_column -> last_seen_width
    | Client_name_column -> name_width
    | Client_type_column -> 10
    | Client_acting_for_column -> 16
  in
  let columns =
    [ Client_status_column; Client_name_column; Client_type_column ]
    @ (if acting_for_drawn then [ Client_acting_for_column ] else [])
    @ [ Client_task_column; Client_last_seen_column ]
  in
  (* Keep identity, state and the observation age. Bindings, implementation
     type and task links yield in that order before the clock is cut. *)
  let layout = Masc_tui_table.fit ~inner_width:table_width
    ~width:column_width ~flex:Client_name_column
    ~drop_order:[ Client_acting_for_column; Client_type_column; Client_task_column ] columns in
  let cells ~status ~name ~agent_type ~keeper ~task ~last_seen =
    List.map (fun column ->
      let header, value = match column with
        | Client_status_column -> "STATUS", status
        | Client_name_column -> "NAME", name
        | Client_type_column -> "TYPE", agent_type
        | Client_acting_for_column -> "ACTING FOR", keeper
        | Client_task_column -> "TASK", task
        | Client_last_seen_column -> "LAST SEEN", last_seen
      in
      let width = if column = Client_name_column then layout.flex_width else column_width column in
      Masc_tui_table.cell ~header ~width value) layout.shown
  in
  let col_hdr = "  " ^ Masc_tui_table.header_row
    (cells ~status:"" ~name:"" ~agent_type:"" ~keeper:"" ~task:"" ~last_seen:"") in
  box_line_styled buf cols ~style:(Theme.recede ()) col_hdr;
  box_divider buf cols;
  (match state.clients_surface_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = listing_chrome ~error:state.clients_surface_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.clients_surface_scroll max_scroll) in
  let clients_window = Rows.of_list ~first:scroll ~height:content_height clients in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.clients_surface ~error:state.clients_surface_error with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty -> "  (nobody attached)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Rows.at clients_window idx with
      | None -> box_empty buf cols
      | Some row ->
          let open Masc.Tui_decode in
          let status = client_status_to_string row.cr_status in
          let name = Terminal_text.single_line row.cr_name in
          (* Both sides sanitized before they are compared: the cell is
             drawn from this reading, and a name that differs only in the
             bytes [Terminal_text] strips is the same name on screen. *)
          let keeper =
            match
              Masc_tui_types.client_acting_for ~name
                ~keeper_name:
                  (Option.map Terminal_text.single_line row.cr_keeper_name)
            with
            | Some keeper -> keeper
            | None -> ""
          in
          let task =
            match row.cr_current_task with
            | Some task -> Terminal_text.single_line task
            | None -> Masc_tui_theme.Glyph.no_value
          in
          let line =
            "  " ^ Masc_tui_table.row (cells ~status ~name
              ~agent_type:(Terminal_text.single_line row.cr_agent_type) ~keeper ~task
              (* How long ago, not when. The cell drew the clock alone on
                 the reading that the header's clock gives it a distance,
                 which holds only while the two are the same day: a dashboard
                 session last seen on 2026-09-21 drew "11:49:28" under a
                 header reading 09:31:39 on 2026-09-23, and the distance a
                 reader could take from that pointed two hours ahead. A span
                 carries its own day. *)
              ~last_seen:(Masc_tui_wire_age.text ~now:now_s row.cr_last_seen))
          in
          (* Inactive rows stay in the roster -- "who left" is part of the
             reading -- but they recede, the way the empty-state rows do. *)
          let style =
            match row.cr_status with
            | Client_inactive -> Theme.recede ()
            | Client_active | Client_busy | Client_listening -> Ansi.reset
          in
          if idx = state.clients_surface_cursor then
            box_line_selected buf cols line
          else box_line_styled buf cols ~style line
    done;
  box_bottom buf cols;
  let position =
    if shown > content_height then
      Some
        (Printf.sprintf "rows %s"
           (Masc_tui_scroll.window_text ~scroll ~height:content_height shown))
    else None
  in
  (* [listing_chrome] already counts this row. Without it the keys the table
     declares for Clients went unshown, and so did an armed search's query,
     which rides the same row. *)
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ?position
       ~hints:(Masc_tui_keys.footer_hints Masc_tui_types.Clients));
  finish_surface state ~surface_key:"clients" ~rows:terminal_rows ~cols buf
;;

let render_lane_scrollable_reading (state : state) ~terminal_rows ~cols
    ~surface_key ~title ~hints raw_lines =
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let width = max 1 (framed_inner_width cols - 2) in
  let lines =
    raw_lines
    |> List.concat_map (fun text ->
         Terminal_text.single_line text
         |> Message_layout.wrap_words ~max_cells:width)
  in
  let height = max 1 (rows - Masc_tui_frame.chrome_rows) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length lines) ~height
      state.lane_run_detail_scroll
  in
  let window = Rows.of_list ~first:scroll ~height lines in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols (screen_title title ^ "  " ^ connection_badge state);
  box_divider buf cols;
  for offset = 0 to height - 1 do
    match Rows.at window (scroll + offset) with
    | None -> box_empty buf cols
    | Some line -> box_line buf cols ("  " ^ line)
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~position:(Masc_tui_scroll.window_text ~scroll ~height (List.length lines))
       ~hints);
  finish_surface state
    ~clamped:(Lane_run_detail_scroll { scroll; content_height = height })
    ~surface_key ~rows:terminal_rows ~cols buf

let lane_activity_hints =
  "Space:draft  s:save  r:read  u:reapply  x:discard  ?:help  Esc:back"

let render_lane_inventory_detail (state : state) target =
  let terminal_rows, cols = get_terminal_size () in
  let width = max 1 (framed_inner_width cols - 2) in
  let content = match state.lane_inventory with
    | None -> ["Lane inventory has not been read. r: refresh"]
    | Some snapshot ->
        (match target with
         | None -> "Inventory diagnostics" :: (match Masc_tui_lane_inventory.snapshot_notices snapshot with
             | [] -> ["No inventory read issues observed."]
             | notices -> notices)
         | Some id ->
             (match List.find_opt (fun (row : Masc.Tui_decode_lane_inventory.row) -> String.equal row.id id) snapshot.rows with
              | None -> ["This Lane is absent from the current reading. Esc returns to the inventory."]
              | Some row ->
                  (match row.Masc.Tui_decode_lane_inventory.selection with
                   | Exact lane ->
                       (match List.find_opt (fun (item : Tui_decode.standalone_lane) ->
                            Standalone_lane.equal item.sl_lane lane) snapshot.exact_snapshot.sls_lanes with
                        | Some item -> standalone_lane_detail_lines ~now:(Unix.gettimeofday ()) ~width item
                            |> List.map (fun (_,line) -> Masc_tui_theme.strip_sgr line)
                        | None -> Masc_tui_lane_inventory.detail_lines row)
                   | Browser _ | Machine _ | Declaration _ | Manual_instance _ ->
                       Masc_tui_lane_inventory.detail_lines row))) in
  let content = (match state.standalone_lanes_error with
    | None -> [] | Some detail -> ["STALE · " ^ detail]) @ content in
  render_lane_scrollable_reading state ~terminal_rows ~cols
    ~surface_key:"lane-inventory-detail" ~title:" MASC Lane reading"
    ~hints:"j/k:scroll  PgUp/PgDn:page  Home/End:top/bottom  r:refresh  Esc/Left:inventory"
    content

let render_machine_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  render_lane_scrollable_reading state ~terminal_rows ~cols
    ~surface_key:"machine-activity" ~title:" MASC Machine activity"
    ~hints:lane_activity_hints
    (Masc_tui_machine_activity.lines session)

let render_browser_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  render_lane_scrollable_reading state ~terminal_rows ~cols
    ~surface_key:"browser-activity" ~title:" MASC Browser activity"
    ~hints:lane_activity_hints
    (Masc_tui_browser_activity.lines session)

let render_exact_activity (state : state) session =
  let terminal_rows, cols = get_terminal_size () in
  render_lane_scrollable_reading state ~terminal_rows ~cols
    ~surface_key:"exact-activity" ~title:" MASC Exact activity"
    ~hints:lane_activity_hints
    (Masc_tui_exact_activity.lines session)

let render_lanes (state : state) =
  match Masc_tui_types.shown_machine_activity state with
  | Some session -> render_machine_activity state session
  | None -> match Masc_tui_types.shown_browser_activity state with
  | Some session -> render_browser_activity state session
  | None -> match Masc_tui_types.shown_exact_activity state with
  | Some session -> render_exact_activity state session
  | None -> match state.lanes_mode with
  | Lanes_overview -> render_lanes_overview state
  | Lanes_inventory_detail target -> render_lane_inventory_detail state target
  | Lanes_run_list lane -> render_lane_run_list state ~lane
  | Lanes_run_detail (_, run_id) -> render_lane_run_detail state ~run_id
  | Lanes_measurement_detail sha256 -> render_lane_run_detail state ~run_id:sha256

