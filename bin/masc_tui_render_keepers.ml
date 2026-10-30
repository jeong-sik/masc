(** Keepers list, detail pane, and turn logs screens. *)

open Masc.Tui_decode_connectors
open Masc_tui_types
open Tui_decode
open Masc.Tui_decode_fusion
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Message_layout = Masc_tui_message_layout
module Metrics_tail = Masc_tui_metrics_tail

let keeper_log_style = function
  | Masc_tui_types.Keeper_log_fact -> Ansi.reset
  | Keeper_log_notice -> Theme.recede ()
  | Keeper_log_warning -> Theme.warn ()
  | Keeper_log_failure -> Theme.bad ()

module Rows = Masc_tui_rows
module Observation_layout = Masc_tui_observation_layout
module Keeper_activity = Masc_tui_keeper_activity
module Render_schedule = Masc_tui_render_schedule
module Layout = Masc_tui_layout
module Keeper_control = Masc_tui_keeper_control
module Keeper_list_model = Masc_tui_keeper_list_model
module Item_account = Masc_tui_keeper_items

let format_context_tokens = Masc_tui_types.format_context_tokens
let schedule_status_color = Masc_tui_render_work.schedule_status_color
let schedule_status_word_cells = Masc_tui_render_work.schedule_status_word_cells
let schedule_requested_clock_cells = Masc_tui_render_work.schedule_requested_clock_cells
let schedule_outcome_word = Masc_tui_render_work.schedule_outcome_word
let schedule_status_is_terminal = Masc_tui_render_work.schedule_status_is_terminal

(* Healthy keepers stay quiet beside their NOW activity. A health deviation
   remains available to the secondary detail row instead of repeating a
   separate health word in every compact row. *)
let keeper_health_deviation_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> (
      match Tui_decode.keeper_health_reading value with
      | Tui_decode.Health_running -> ""
      | Tui_decode.Health_idle | Tui_decode.Health_failing | Tui_decode.Health_offline ->
          Tui_decode.keeper_health_to_string value)

(* [runtime_id] is the producer-owned runtime identity. Keep it whole instead
   of deriving a model by splitting its spelling: the phase is a separate
   typed reading, while the sanitized id is the exact identity the gate named. *)
let keeper_runtime_label (runtime : keeper_runtime option) =
  match runtime with
  | None -> Masc_tui_theme.Glyph.no_value
  | Some row ->
      Printf.sprintf "%s %s"
        (Tui_decode.keeper_phase_to_string row.kr_phase)
        (Terminal_text.single_line row.kr_runtime_id)

(* The two halves of the runtime cell, so the column that has to be wide
   enough for them is measured from the same strings that get drawn. *)
let keeper_runtime_parts (row : keeper_runtime) =
  let phase =
    if row.kr_paused then "paused "
    else if Tui_decode.keeper_phase_is_running row.kr_phase then ""
    else Tui_decode.keeper_phase_to_string row.kr_phase ^ " "
  in
  (phase, Terminal_text.single_line row.kr_runtime_id)

(* What the widest row would spend on this cell. A keeper the roster cannot
   see draws an em dash, which is one cell. *)
let keeper_runtime_cells (runtime : keeper_runtime option) =
  match runtime with
  | None -> 1
  | Some row ->
      let phase, runtime_id = keeper_runtime_parts row in
      Message_layout.display_width phase
      + Message_layout.display_width runtime_id

let keeper_failure_cause_word = function
  | Keeper_failure_heartbeat -> "heartbeat"
  | Keeper_failure_turn -> "turn"
  | Keeper_failure_provider -> "provider"
  | Keeper_failure_configuration -> "config"
  | Keeper_failure_client_recovery -> "client recovery"
  | Keeper_failure_fiber -> "fiber"
  | Keeper_failure_exception -> "exception"
  | Keeper_failure_operator_interrupt -> "operator interrupt"

let keeper_current_activity_word = function
  | Keeper_activity_idle -> "idle"
  | Keeper_activity_waiting -> "waiting"
  | Keeper_activity_running -> "running"
  | Keeper_activity_streaming -> "streaming"
  | Keeper_activity_tool -> "tool"
  | Keeper_activity_preparing -> "preparing"
  | Keeper_activity_attempt_failed -> "attempt failed"
  | Keeper_activity_unknown -> "unknown"

let keeper_failure_context ~now status =
  let cause, age =
    match status.kfs_last_failure with
    | None -> ("unknown", "unknown time")
    | Some failure ->
        ( keeper_failure_cause_word failure.kf_cause
        , match failure.kf_at_unix with
          | None -> "unknown time"
          | Some since -> Option.value (Message_layout.age_text ~now ~since) ~default:"unknown time" )
  in
  keeper_current_activity_word status.kfs_current_activity
  ^ " · last failed · " ^ cause ^ " · " ^ age

let keeper_runtime_cell ~width ?failure_context (runtime : keeper_runtime option) =
  match failure_context with
  | Some text -> fit_width text width
  | None ->
      (match runtime with
       | None -> fit_width Masc_tui_theme.Glyph.no_value width
       | Some row ->
           (* Running is the normal lifecycle and stays silent; the cell goes
              to the runtime identity unless failure context takes priority. *)
           let phase, runtime_id = keeper_runtime_parts row in
           let phase_width = Message_layout.display_width phase in
           if phase_width >= width then fit_width (keeper_runtime_label runtime) width
           else
             fit_width
               (phase ^ fit_runtime_id (width - phase_width) runtime_id)
               width)

(* One activation mode and the sandbox declaration from the roster row. *)
let keeper_flag_cell (runtime : keeper_runtime option) =
  match runtime with
  | None -> Ansi.dim ^ "- -" ^ Ansi.reset
  | Some row ->
      let module Mark = Masc_tui_keeper_mark in
      let sandbox =
        match Mark.sandbox_of_profile row.kr_sandbox_profile, row.kr_sandbox_profile with
        | Some (Mark.Docker as known), _ ->
          (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ Mark.sandbox_letter known ^ Ansi.reset
        | Some (Mark.Micro_vm as known), _ ->
          (Theme.category Theme.Slot_2) ^ Mark.sandbox_letter known ^ Ansi.reset
        | Some (Mark.Remote_ssh as known), _ ->
          (Theme.category Theme.Slot_1) ^ Mark.sandbox_letter known ^ Ansi.reset
        | None, other when String.length other > 0 ->
          (Theme.warn ()) ^ String.uppercase_ascii (String.sub other 0 1) ^ Ansi.reset
        | None, _ -> Ansi.dim ^ "?" ^ Ansi.reset
      in
      Mark.activation_letter row.kr_activation_mode ^ " " ^ sandbox

let keeper_activity_word (activity : Keeper_list_model.activity) =
  match activity with
  | Held_call -> "held call"
  | Question -> "question"
  | Confirmation -> "confirm"
  | Failure -> "failure"
  | Preparing -> "preparing"
  | Streaming -> "streaming"
  | Running -> "running"
  | Async_working count -> Printf.sprintf "async %d" count
  | Deferred -> "deferred"
  | Tool_waiting -> "tool wait"
  | Model_waiting -> "model wait"
  | Delegate_result -> "result in"
  | Verifying -> "verify"
  | External_waiting -> "external"
  | Idle -> "idle"
  | Paused -> "paused"
  | Offline -> "offline"
  | Unknown -> "unknown"

let keeper_activity_style (activity : Keeper_list_model.activity) =
  match activity with
  | Held_call | Failure -> Theme.bad ()
  | Question | Confirmation | Offline -> Theme.warn ()
  | Preparing | Streaming | Running | Async_working _ | Deferred -> Theme.info ()
  | Tool_waiting -> Theme.warn ()
  | Model_waiting -> Theme.info ()
  | Delegate_result -> Theme.category Theme.Slot_2
  | Verifying -> Theme.category Theme.Slot_1
  | External_waiting | Idle | Paused | Unknown -> Theme.recede ()

let keeper_badge_text (badge : Keeper_list_model.badge) =
  let glyph = Masc_tui_keeper_mark.badge_glyph badge in
  match badge with
  | Badge_read_error -> glyph ^ " read error"
  | Badge_waiting_unavailable -> glyph ^ " waiting unavailable"
  | Badge_async { running; ownership_unknown } ->
      Printf.sprintf "%s async %d%s" glyph running
        (if ownership_unknown > 0 then Printf.sprintf " (%d owner?)" ownership_unknown else "")
  | Badge_async_queued count -> Printf.sprintf "%s queued %d" glyph count
  | Badge_async_cancelling count -> Printf.sprintf "%s cancelling %d" glyph count
  | Badge_delegate -> glyph ^ " delegate result"
  | Badge_verification -> glyph ^ " verify"
  | Badge_schedule -> glyph ^ " schedule"

let keeper_task_detail (row : Keeper_list_model.row) =
  match row.task with
  | Some task ->
      let id = Terminal_text.single_line task.Tui_decode.id in
      let title = Terminal_text.single_line task.Tui_decode.title in
      Some ("task " ^ id ^ if String.equal title "" then "" else " · " ^ title)
  | None -> (
      match row.keeper.Tui_decode.k_activity with
      | Some activity -> Option.map (fun id -> "task " ^ Terminal_text.single_line id)
          activity.Tui_decode.k_current_task_id
      | None -> Some "task not observed")

let keeper_waiting_detail (row : Keeper_list_model.row) =
  match row.waiting with
  | Keeper_list_model.Waiting_observed { Tui_decode.kwr_waiting_on = (first :: rest as items); _ } ->
      (* A delegate result's operator sentence includes the other Keeper and
         its outcome. Do not hide that behind an earlier scheduled wake. *)
      let item =
        match List.find_opt
            (fun item -> item.Tui_decode.kwi_wake_producer = Tui_decode.Wake_keeper_delegate)
            items with
        | Some result -> result
        | None -> first
      in
      let detail =
        if not (String.equal (String.trim item.Tui_decode.kwi_what) "") then item.kwi_what
        else if not (String.equal (String.trim item.kwi_next_action) "") then item.kwi_next_action
        else item.kwi_waiting_on
      in
      Some (Terminal_text.single_line detail
        ^ (match rest with [] -> "" | _ -> Printf.sprintf " (+%d more)" (List.length rest)))
  | Keeper_list_model.Waiting_observed { kwr_waiting_on = []; _ }
  | Keeper_list_model.Waiting_unobserved | Keeper_list_model.Waiting_unavailable -> None

let keeper_detail_text ?(failure_context = None) (row : Keeper_list_model.row) =
  let approval =
    Option.map
      (fun (approval : Tui_decode.keeper_tool_approval) ->
        "hold " ^ Terminal_text.single_line approval.kta_tool
        ^ " · " ^ Terminal_text.single_line approval.kta_question)
      row.approval
  in
  let questions =
    if row.open_questions > 0 then
      Some (Masc_tui_message_layout.count_noun row.open_questions "question" ^ " awaiting you")
    else None
  in
  let health =
    match keeper_health_deviation_word (Keeper_control.health row.reading) with
    | "" -> None
    | word -> Some ("health " ^ word)
  in
  Option.to_list failure_context
  @ List.map keeper_badge_text (Keeper_list_model.badges_of_row row)
  @ List.filter_map Fun.id
      [ approval; questions; keeper_waiting_detail row; keeper_task_detail row; health ]
  |> String.concat " · "

let keeper_column_header (columns : Render_schedule.keeper_columns) =
  String.concat ""
    [ String.make Render_schedule.keeper_marker_width ' '
    ; Message_layout.fit_width "KEEPER" columns.kcol_name
    ; " "
    ; Message_layout.fit_width "NOW" Render_schedule.keeper_status_width
    ; (if columns.kcol_show_flags then
         " " ^ Message_layout.fit_width "Mode S" Render_schedule.keeper_flags_width
       else "")
    ; " " ^ Message_layout.pad_left "AGE" Render_schedule.keeper_last_turn_width
    ; (if columns.kcol_show_runtime then
         " " ^ fit_width "LIFECYCLE / RUNTIME" columns.kcol_runtime
       else "")
    ; " "
    ; Message_layout.fit_width "DETAIL" columns.kcol_task
    ]

let keeper_row_content ~(columns : Render_schedule.keeper_columns)
    ~now ~frame ~yolo ~selected (row : Keeper_list_model.row) =
  let keeper = row.keeper in
  let activity = Keeper_list_model.primary_activity_of_row row in
  let status_color = keeper_activity_style activity in
  let glyph =
    match activity with
    | Preparing | Running -> Masc_tui_answering.running_glyph ~frame
    | Held_call | Question | Confirmation | Failure | Streaming | Async_working _
    | Deferred | Tool_waiting | Model_waiting | Delegate_result | Verifying | External_waiting
    | Idle | Paused | Offline | Unknown -> Masc_tui_keeper_mark.activity_glyph activity
  in
  let name =
    Message_layout.fit_middle columns.kcol_name
      (Terminal_text.single_line keeper.Tui_decode.k_name)
  in
  let health = Keeper_control.health row.reading in
  let runtime =
    match row.reading.Keeper_control.liveness with
    | Keeper_control.Present runtime -> Some runtime
    | Keeper_control.Absent | Keeper_control.Unobserved | Keeper_control.Invalid _ -> None
  in
  let failure_context =
    Option.map (keeper_failure_context ~now)
      (Tui_decode.keeper_failure_status_of_readings ~health ~turn:row.turn ~runtime)
  in
  let age =
    match row.last_activity_at with
    | Some since -> Option.value (Message_layout.age_text ~now ~since)
        ~default:Masc_tui_theme.Glyph.no_value
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let marker = if selected then "\xe2\x80\xba  " (* › *) else "   " in
  String.concat ""
    [ marker
    ; (if yolo then Theme.bad () ^ name ^ Ansi.reset else name)
    ; " "
    ; status_color ^ glyph ^ " "
      ^ Message_layout.fit_width (keeper_activity_word activity)
          (Render_schedule.keeper_status_width - 2)
      ^ Ansi.reset
    ; (if columns.kcol_show_flags then " " ^ keeper_flag_cell runtime else "")
    ; " " ^ Theme.recede ()
      ^ Message_layout.pad_left age Render_schedule.keeper_last_turn_width
      ^ Ansi.reset
    ; (if columns.kcol_show_runtime then
         " " ^ Theme.recede ()
         ^ keeper_runtime_cell ~width:columns.kcol_runtime ?failure_context runtime
         ^ Ansi.reset
       else "")
    ; " "
    ; Theme.recede ()
      ^ fit_width
          (keeper_detail_text
             ~failure_context:
               (Render_schedule.keeper_failure_context_for_detail
                  ~show_runtime:columns.kcol_show_runtime failure_context)
             row)
          columns.kcol_task
      ^ Ansi.reset
    ]

let keeper_secondary_row_content ~inner (row : Keeper_list_model.row) =
  let indent_cells = Render_schedule.keeper_marker_width + 2 in
  let detail =
    match keeper_detail_text row with
    | "" -> Masc_tui_theme.Glyph.no_value
    | text -> text
  in
  String.make indent_cells ' ' ^ Theme.recede ()
  ^ fit_width detail (max 0 (inner - indent_cells))
  ^ Ansi.reset

(* The subtractions over the fleet's name lists. They answer different
   questions and only one of them is about being stopped: a keeper the fleet
   wants with no live turn-executing fiber is bootable minus executable,
   while a keeper whose fiber is alive but whose durable demand is not
   admissible is running minus executable. Reporting the second as "not
   running" sent an operator to boot ten keepers that were already up, and
   subtracting the Running-phase list instead of the executable list here put
   every Failing keeper in "not running" too -- a failing keepalive still
   runs its turns, so keepers that were visibly turning were listed as not
   running (2026-09-16). Executable is the set with a live fiber (Running or
   Failing), which is the fact the label names. *)
let keeper_fleet_gap_lines (fleet : fleet_safety) =
  let names = Masc.Fleet_stream.Names.to_list in
  let subtract from_names remove_names =
    List.filter (fun name -> not (List.mem name remove_names)) from_names
  in
  let not_running =
    subtract (names fleet.fs_bootable_names) (names fleet.fs_executable_names)
  in
  let running_without_turn =
    subtract (names fleet.fs_running_names) (names fleet.fs_executable_names)
  in
  List.filter_map
    (fun (names, label, color) ->
       match names with
       | [] -> None
       | _ -> Some (color, label, String.concat ", " names))
    [ (not_running, "not running", (Theme.bad ()))
    ; (running_without_turn, "running, cannot take a turn", (Theme.warn ()))
    ; (* Failing subsets that need operator action: turn configuration
         errors survive every retry, so the names are listed where the
         failing counter only counts them. Unscoped on purpose -- the
         configuration_blocked_* wire fields are autoboot-scoped and skip a
         blocked keeper booted on request. *)
      ( names fleet.fs_turn_configuration_error_names
      , "config-blocked"
      , (Theme.bad ()) )
    ; ( names fleet.fs_official_client_recovery_required_names
      , "session recovery required"
      , (Theme.bad ()) )
    ]


(* The conditions that share a phase with another: either health reading
   makes a keeper failing, and a pending launch is one of the ways it is
   offline. Each of the other conditions has a phase of its own, which the
   lifecycle word already says, so naming it again would add nothing. *)
let keeper_lane_phase_causes (conditions : Tui_decode.keeper_lane_conditions) =
  List.filter_map
    (fun (holds, words) -> if holds then Some words else None)
    [ (not conditions.klc_turn_healthy, "last turn failed")
    ; (not conditions.klc_heartbeat_healthy, "heartbeat failed")
    ; (conditions.klc_launch_pending, "launch pending")
    ]

let keeper_lane_lifecycle_text (lane : Tui_decode.keeper_lane) =
  let phase =
    Terminal_text.single_line (Tui_decode.keeper_lane_phase_to_string lane.kl_phase)
  in
  match keeper_lane_phase_causes lane.kl_conditions with
  | [] -> phase
  | causes -> Printf.sprintf "%s (%s)" phase (String.concat ", " causes)

let keeper_operations_outcome_text = function
  | None -> Masc_tui_theme.Glyph.no_value
  | Some (outcome : Tui_decode.keeper_lane_last_outcome) ->
      let state = Terminal_text.single_line outcome.klo_runtime_state in
      (match outcome.klo_selected_model with
       | Some model when String.trim model <> "" ->
           state ^ " · " ^ Terminal_text.single_line model
       | Some _ | None -> state)

(* The runtime that produced the last outcome, apart from the one the keeper
   is assigned: after a failover they differ. An id the catalog does not list
   (or a catalog not loaded yet) shows the raw id, never a guessed provider. *)
let keeper_last_runtime_text (state : state) = function
  | Some { Tui_decode.klo_selected_runtime_id = Some runtime_id; _ } ->
      let id_text = Terminal_text.single_line runtime_id in
      (match state.runtime_surface with
       | None -> id_text
       | Some snap ->
           (match
              Tui_decode.resolve_last_runtime
                snap.rss_resolved.rrs_runtimes runtime_id
            with
            | Tui_decode.Last_runtime_cataloged ro ->
                id_text ^ " \xc2\xb7 " ^ Terminal_text.single_line ro.ro_provider
            | Tui_decode.Last_runtime_uncataloged _ ->
                id_text ^ " \xc2\xb7 not in the runtime list"))
  | Some { Tui_decode.klo_selected_runtime_id = None; _ } | None ->
      Masc_tui_theme.Glyph.no_value

(* Composite execution facts belong to this Keeper's Info pane. Separate
   fields use the pane's wrapped, scrollable rows; a long one-line preview
   beside the list footer silently lost its outcome and runtime target. *)
let keeper_operations_fields (state : state) ~keeper_name =
  let fields = match state.lanes with
  | Some snapshot ->
      (match
         List.find_opt
           (fun (lane : Tui_decode.keeper_lane) ->
             String.equal lane.kl_keeper keeper_name)
           snapshot.kls_lanes
       with
       | Some lane ->
           [ "Lifecycle:", keeper_lane_lifecycle_text lane
           ; "Turn:", Terminal_text.single_line
               (Tui_decode.keeper_lane_turn_phase_to_string lane.kl_turn_phase)
           ; "Idle:", keeper_lane_idle_text lane.kl_idle_seconds
           ; "Last outcome:", keeper_operations_outcome_text lane.kl_last_outcome
           ; "Last runtime:", keeper_last_runtime_text state lane.kl_last_outcome
           ]
       | None ->
           [ "Execution:", Ansi.dim ^ "no composite row for "
             ^ Terminal_text.single_line keeper_name ^ Ansi.reset ])
  | None ->
      (match state.lanes_error with
       | Some detail ->
           [ "Execution:", Theme.warn () ^ "unavailable · "
             ^ Terminal_text.single_line detail ^ Ansi.reset ]
       | None ->
           if state.keeper_lanes_inflight then []
           else [ "Execution:", Ansi.dim ^ "not observed" ^ Ansi.reset ])
  in
  let fields = match state.lanes, state.lanes_error with
    | Some _, Some detail ->
        ("Execution:", Theme.warn () ^ "stale · refresh failed: "
          ^ Terminal_text.single_line detail ^ Ansi.reset) :: fields
    | Some _, None | None, (Some _ | None) -> fields in
  if state.keeper_lanes_inflight then
    ("Execution:", Ansi.dim
      ^ (match state.lanes with
         | None -> "reading execution snapshot…"
         | Some _ -> "refreshing execution snapshot · last observation")
      ^ Ansi.reset) :: fields
  else fields

type keeper_display_entry =
  | Keeper_group_heading of Keeper_list_model.attention * int
  | Keeper_display_row of int * Keeper_list_model.row

let keeper_display_entries rows layout =
  let entries =
    List.mapi (fun position (row : Keeper_list_model.row) -> position, row) rows
  in
  match layout with
  | Keeper_list_model.Compact | Keeper_list_model.Detailed ->
      List.map (fun (position, row) -> Keeper_display_row (position, row)) entries
  | Keeper_list_model.Grouped ->
      let attention, active, waiting, inactive, unobserved = Keeper_list_model.group_counts rows in
      [ Keeper_list_model.Attention, attention
      ; Keeper_list_model.Active, active
      ; Keeper_list_model.Waiting, waiting
      ; Keeper_list_model.Inactive, inactive
      ; Keeper_list_model.Unobserved, unobserved
      ]
      |> List.concat_map (fun (group, count) ->
        let matching =
          List.filter (fun (_, row) -> Keeper_list_model.group_of_row row = group) entries
        in
        match matching with
        | [] -> []
        | _ ->
            Keeper_group_heading (group, count)
            :: List.map (fun (position, row) -> Keeper_display_row (position, row)) matching)

let keeper_group_heading_text ~available_cells rows group count =
  let glyph, label =
    match group with
    | Keeper_list_model.Attention -> "!", "ATTENTION"
    | Keeper_list_model.Active -> "\xe2\x96\xb6", "ACTIVE" (* ▶ *)
    | Keeper_list_model.Waiting -> "\xe2\x97\x8c", "WAITING" (* ◌ *)
    | Keeper_list_model.Inactive -> "\xe2\x97\x8b", "INACTIVE" (* ○ *)
    | Keeper_list_model.Unobserved -> "?", "UNKNOWN"
  in
  let detail =
    match group with
    | Keeper_list_model.Waiting ->
        Render_schedule.waiting_group_heading_detail ~available_cells ~group_count:count
          (Keeper_list_model.waiting_summary rows)
    | Keeper_list_model.Attention | Keeper_list_model.Active
    | Keeper_list_model.Inactive | Keeper_list_model.Unobserved -> ""
  in
  Printf.sprintf "%s %s %d%s" glyph label count detail

let keeper_group_heading_style = function
  | Keeper_list_model.Attention -> Theme.bad ()
  | Keeper_list_model.Active -> Theme.ok ()
  | Keeper_list_model.Waiting -> Theme.info ()
  | Keeper_list_model.Inactive -> Theme.recede ()
  | Keeper_list_model.Unobserved -> Theme.warn ()

let keeper_view_summary rows layout sort =
  let mode = Keeper_list_model.layout_label layout ^ " · " ^ Keeper_list_model.sort_label sort in
  match layout with
  | Keeper_list_model.Grouped -> "  " ^ mode
  | Keeper_list_model.Compact | Keeper_list_model.Detailed ->
      let attention, active, waiting, inactive, unobserved = Keeper_list_model.group_counts rows in
      Printf.sprintf "  %s   ! %d attention   \xe2\x96\xb6 %d active   \xe2\x97\x8c %d waiting   \xe2\x97\x8b %d inactive   ? %d unknown"
        mode attention active waiting inactive unobserved

let render_keeper_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let inner = max 1 (framed_inner_width cols) in
  let model_rows = keeper_list_rows state in
  (* Selection already follows this ordered model in list mode. Reuse it in
     this synchronous draw rather than rebuilding it through selected_keeper. *)
  let selected_reading =
    Option.map (fun (row : Keeper_list_model.row) -> row.reading)
      (List.nth_opt model_rows state.keeper_cursor)
  in
  let keepers_error = Terminal_text.optional_single_line state.keepers_error in

  Buffer.add_char buf '\n';

  (* One observation time for stale fleet readings and roster turn ages. *)
  let now_unix = Unix.gettimeofday () in
  let heading =
    screen_title
      (Printf.sprintf " MASC Keepers %s"
         (match state.keepers, keeper_rows_page state ~error:keepers_error with
          | _ :: _, _ | [], Page_empty ->
              Printf.sprintf "(%d)" (List.length state.keepers)
          | [], (Page_unread | Page_failed) ->
              title_missing_reading ~error:keepers_error))
  in
  (* The roster is the surface an operator watches to see which keepers are
     up, and it was the one top-level surface whose title never said whether
     the reading was live: "1 healthy · 1 idle" read the same over a dead
     coordinator as over a live one. The badge also carries the workspace
     mismatch, which this screen could not report at all. *)
  let badge = connection_badge state in
  (* Style bytes are zero-width to [display_width], so the gap is measured on
     the styled string rather than on a plain copy that could drift from it. *)
  let gap =
    max 1
      (inner - Message_layout.display_width heading
       - Message_layout.display_width badge)
  in
  box_line buf cols (heading ^ String.make gap ' ' ^ badge);
  box_line buf cols
    (Theme.recede ()
     ^ keeper_view_summary model_rows state.keeper_list_layout state.keeper_list_sort
     ^ Ansi.reset);
  Option.iter
    (fun message -> box_line buf cols
      (Theme.warn () ^ "  preferences: " ^ Terminal_text.single_line message ^ Ansi.reset))
    state.keeper_list_preference_notice;

  (match fleet_stream_view state with
   | Masc_tui_fleet_stream.Awaiting_first_reading -> ()
   | Masc_tui_fleet_stream.Unreachable { since } ->
       box_line buf cols
         ((Theme.warn ()) ^ "  fleet: "
          ^ Masc_tui_fleet_line.unreachable_text ~now:now_unix ~since
          ^ Ansi.reset)
   | Masc_tui_fleet_stream.Cannot_read failure ->
       box_line buf cols
         ((Theme.bad ()) ^ "  fleet: " ^ Masc_tui_fleet_line.failure_text failure
          ^ Ansi.reset)
   | Masc_tui_fleet_stream.Unavailable { degradation; disconnected_since } ->
       box_line buf cols
         ((Theme.warn ()) ^ "  fleet: "
          ^ Masc_tui_fleet_line.unavailable_text ~now:now_unix ~degradation ~disconnected_since
          ^ Ansi.reset)
   | Masc_tui_fleet_stream.Reading { reading = { fleet; _ }; trouble } ->
       let tone =
         if fleet.fs_operator_action_required then (Theme.bad ())
         else if Masc_tui_fleet_line.status_is_ok fleet.fs_status then (Theme.ok ())
         else (Theme.warn ())
       in
       let blocker =
         match Masc_tui_fleet_line.blocker_text fleet with
         | None -> ""
         | Some text -> "   " ^ text
       in
       box_line buf cols
         (Printf.sprintf
            "%s  fleet %s%s   running %d/%d   turn capacity %d/%d%s%s%s" tone
            (Masc_tui_fleet_line.status_text fleet.fs_status)
            Ansi.reset fleet.fs_running_count
            fleet.fs_bootable_count
            (fleet.fs_target_reaction_capacity
            - fleet.fs_reaction_capacity_shortfall)
            fleet.fs_target_reaction_capacity Ansi.dim blocker Ansi.reset);
       (* Its own row under the fleet line rather than a tail on it: the
          frame cuts a row from the right, and the counts are what a narrow
          screen keeps. *)
       Option.iter
         (fun trouble ->
            box_line buf cols
              ((Theme.warn ()) ^ "  fleet reading: "
               ^ Masc_tui_fleet_line.trouble_text ~now:now_unix trouble ^ Ansi.reset))
         trouble;
       let failing_entry =
         Option.to_list (Masc_tui_fleet_line.failing_text fleet)
       in
       let entry label n =
         if n > 0 then [ Printf.sprintf "%s %d" label n ] else []
       in
       (* The owner count keeps its place in the row and brings its own
          shortfall, which is the only reading that says the scan came up
          short: an unread Keeper does not move the fleet status. *)
       let counts =
         failing_entry
         @ entry "paused" fleet.fs_paused_count
         @ Option.to_list (Masc_tui_fleet_line.owner_scan_text fleet)
         @ entry "awaiting verdict" fleet.fs_completion_authority_pending_count
       in
       if counts <> [] then
         box_line buf cols
           (Ansi.dim ^ "  " ^ String.concat "   " counts ^ Ansi.reset);
       List.iter
         (fun (color, label, names) ->
            box_line buf cols
              (Printf.sprintf "%s  %s: %s%s" color label
                 (Terminal_text.single_line names) Ansi.reset))
         (keeper_fleet_gap_lines fleet));

  (* The roster's own failure. The rows below still come from disk so they stay
     on screen; this says the live half of every one of them is missing, which
     does not prevent confirmed deletion through the authoritative server. *)
  (match state.keeper_roster_error with
   | Some err ->
       box_line buf cols
         ((Theme.warn ()) ^ "  " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_roster with
   | Keeper_control.Roster_invalid { errors; _ } ->
       box_line buf cols
         (Printf.sprintf "%s  configuration errors: %d; select a keeper for details%s"
            (Theme.warn ()) (List.length errors) Ansi.reset);
       (match selected_reading with
        | Some { Keeper_control.name; liveness = Keeper_control.Invalid detail; _ } ->
            box_line buf cols ((Theme.warn ()) ^ "  "
              ^ Terminal_text.single_line (name ^ ": " ^ detail) ^ Ansi.reset)
        | Some
            { Keeper_control.liveness =
                ( Keeper_control.Unobserved | Keeper_control.Absent
                | Keeper_control.Present _ )
            ; _
            }
        | None -> ())
   | Keeper_control.Roster_partial { observed; total } ->
       box_line buf cols
         (Printf.sprintf
            "%s  live status covers %d of %s; the rest read as unknown%s"
            (Theme.warn ()) (List.length observed) (Masc_tui_message_layout.count_noun total "keeper") Ansi.reset)
   | Keeper_control.Roster_unobserved | Keeper_control.Roster_complete _ -> ());

  (* Measured over every reading rather than the rows on screen, so the
     columns do not move while a reader scrolls. *)
  let has_failing_keeper =
    List.exists
      (fun (row : Keeper_list_model.row) ->
        match Keeper_control.health row.reading with
        | Some value ->
            Tui_decode.keeper_health_reading value = Tui_decode.Health_failing
        | None -> false)
      model_rows
  in
  let widest_runtime =
    List.fold_left
      (fun widest (row : Keeper_list_model.row) ->
        let reading = row.reading in
        let runtime =
          match reading.Keeper_control.liveness with
          | Keeper_control.Present row -> Some row
          | Keeper_control.Absent | Keeper_control.Unobserved
          | Keeper_control.Invalid _ -> None
        in
        let failure_context_width =
          match Keeper_control.health reading with
          | Some value when
              Tui_decode.keeper_health_reading value = Tui_decode.Health_failing -> 60
          | None | Some _ -> 0
        in
        max widest (max failure_context_width (keeper_runtime_cells runtime)))
      0 model_rows
  in
  let columns =
    Render_schedule.allocate_keeper_columns
      (* Compact and grouped views give the available row to the current
         work. The detailed view keeps the explicit runtime column. *)
      ~runtime_visible:(match state.keeper_list_layout with
        | Keeper_list_model.Detailed -> true
        | Keeper_list_model.Compact | Keeper_list_model.Grouped -> false)
      ~prioritize_runtime:has_failing_keeper ~inner_width:inner ~widest_runtime ()
  in
  box_line_styled buf cols ~style:(Theme.recede ()) (keeper_column_header columns);

  (match keepers_error with
   | Some err -> box_line buf cols ((Theme.bad ()) ^ "  " ^ err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_turns_error with
   | Some err ->
       box_line buf cols
         (Theme.warn () ^ "  turn/waiting observation: "
          ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_waiting_failure with
   | None -> ()
   | Some failure ->
       let detail =
         match failure with
         | Tui_decode.Keeper_waiting_sources_unavailable errors ->
             errors
             |> List.map (fun item -> Terminal_text.single_line item.Tui_decode.kwi_waiting_on)
             |> String.concat ", "
         | Tui_decode.Keeper_waiting_invalid detail -> Terminal_text.single_line detail
       in
       box_line buf cols
         (Theme.warn () ^ "  fleet waiting observation unavailable: " ^ detail ^ Ansi.reset));
  (match state.tools_async_observation_error with
   | Some err ->
       box_line buf cols
         (Theme.warn () ^ "  async observation: "
          ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());

  Option.iter (fun note -> box_line buf cols (Theme.recede () ^ note ^ Ansi.reset))
    (local_source_pending_note state Local_keepers);

  let chrome_rows = count_frame_lines buf in
  let footer_rows = 2 in
  let keeper_count = List.length model_rows in
  let cursor = max 0 (min state.keeper_cursor (keeper_count - 1)) in
  let entry_height =
    match state.keeper_list_layout with
    | Keeper_list_model.Detailed -> 2
    | Keeper_list_model.Compact | Keeper_list_model.Grouped -> 1
  in
  let entries = keeper_display_entries model_rows state.keeper_list_layout in
  let portrait_candidate =
    match state.keeper_list_layout, selected_reading with
    | Keeper_list_model.Detailed, Some reading -> (
        match reading.Keeper_control.liveness with
        | Keeper_control.Present runtime -> (
            match runtime.Tui_decode.kr_portrait with
            | Tui_decode.Ready equipment ->
                Option.map (fun portrait -> reading.Keeper_control.name, portrait)
                  (Masc_tui_chat_portrait.shown ~name:reading.Keeper_control.name
                     ~portrait:(Keeper_portrait_equipment.Ready equipment)
                     ~rows ~cols)
            | Tui_decode.Unavailable _ -> None)
        | Keeper_control.Unobserved | Keeper_control.Absent
        | Keeper_control.Invalid _ -> None)
    | Keeper_list_model.Detailed, None
    | (Keeper_list_model.Compact | Keeper_list_model.Grouped), _ -> None
  in
  let portrait_list_rows =
    let target = min 4 keeper_count in
    target * 2 + if keeper_count > target then 1 else 0
  in
  let portrait =
    match portrait_candidate with
    | Some (_, portrait) as candidate
      when portrait.Masc_tui_chat_portrait.roster_rows - chrome_rows - footer_rows
           >= portrait_list_rows -> candidate
    | Some _ | None -> None
  in
  let roster_rows =
    match portrait with
    | None -> rows
    | Some (_, portrait) -> portrait.Masc_tui_chat_portrait.roster_rows
  in
  let content_rows = max 0 (roster_rows - chrome_rows - footer_rows) in
  Option.iter
    (fun (name, portrait) ->
      box_line buf cols
        (Theme.recede () ^ "  selected · " ^ Terminal_text.single_line name ^ Ansi.reset);
      let picture_row = count_frame_lines buf in
      List.iter (box_line buf cols) portrait.Masc_tui_chat_portrait.picture_lines;
      box_line buf cols "";
      Option.iter
        (fun (placement : Masc_tui_portrait_view.placement) ->
          Masc_tui_portrait_view.request
            { placement with row = picture_row + strip_rows })
        portrait.Masc_tui_chat_portrait.placement)
    portrait;

  let total_entry_lines = List.length entries * entry_height in
  let overflowing = content_rows > 0 && total_entry_lines > content_rows in
  let entry_rows = if overflowing then max 0 (content_rows - 1) else content_rows in
  let entry_capacity = entry_rows / entry_height in
  let selected_entry =
    match
      List.find_index
        (function
          | Keeper_display_row (position, _) -> position = cursor
          | Keeper_group_heading _ -> false)
        entries
    with
    | Some index -> index
    | None -> 0
  in
  let scroll_offset =
    if entry_capacity > 0 then
      min
        (max 0 (List.length entries - entry_capacity))
        (Masc_tui_scroll.ensure_visible ~cursor:selected_entry
           ~height:entry_capacity state.keeper_list_scroll)
    else 0
  in
  let entries_window = List.take entry_capacity (List.drop scroll_offset entries) in
  List.iter
    (function
      | Keeper_group_heading (group, count) ->
          box_line buf cols
            (keeper_group_heading_style group ^ Ansi.bold ^ "  "
             ^ keeper_group_heading_text ~available_cells:(inner - 2) model_rows group count
             ^ Ansi.reset)
      | Keeper_display_row (position, row) ->
          let selected = position = cursor in
          let primary =
            keeper_row_content ~columns ~now:now_unix ~frame:state.activity_frame
              ~yolo:(List.mem row.Keeper_list_model.keeper.Tui_decode.k_name
                       state.keeper_yolo_names)
              ~selected row
          in
          let secondary = keeper_secondary_row_content ~inner row in
          let press text =
            pressable (Press_keeper_row row.Keeper_list_model.keeper.Tui_decode.k_name)
              (fit_width text inner)
          in
          let emit text =
            if selected then
              box_line_selected buf cols (press (Masc_tui_theme.strip_sgr text))
            else box_line buf cols (press text)
          in
          emit primary;
          (match state.keeper_list_layout with
           | Keeper_list_model.Detailed -> emit secondary
           | Keeper_list_model.Compact | Keeper_list_model.Grouped -> ()))
    entries_window;

  let note =
    if keeper_count > 0 then None
    else
      match keeper_rows_page state ~error:keepers_error with
      | Page_empty -> Some (match state.workspace_identity with
          | Workspace_identity_mismatch _ -> "   server Keeper roster is empty"
          | Workspace_identity_match | Workspace_identity_match_unconfirmed _
          | Workspace_identity_unread ->
            "   no keeper metadata under .masc/keepers/")
      | Page_unread -> Some page_unread_note
      | Page_failed -> None
  in
  Option.iter
    (fun text ->
      if entry_rows > 0 then box_line buf cols (Theme.recede () ^ text ^ Ansi.reset))
    note;
  let note_rows = match note with Some _ when entry_rows > 0 -> 1 | Some _ | None -> 0 in
  let drawn_rows = List.length entries_window * entry_height + note_rows in
  for _ = 1 to max 0 (entry_rows - drawn_rows) do
    box_empty buf cols
  done;

  if overflowing then begin
    let count_keepers entries =
      List.fold_left
        (fun count entry ->
          match entry with
          | Keeper_display_row _ -> count + 1
          | Keeper_group_heading _ -> count)
        0 entries
    in
    let before = count_keepers (List.take scroll_offset entries) in
    let visible = count_keepers entries_window in
    let range =
      if visible = 0 then "0/" ^ string_of_int keeper_count
      else Printf.sprintf "%d–%d/%d" (before + 1) (before + visible) keeper_count
    in
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "  [keepers %s]" range)
  end;

  box_divider buf cols;
  Buffer.add_string buf
    (footer_line state
       ~status:(keeper_action_status state)
       ~max_cells:cols
       ~hints:(keeper_control_hints ~offers_back:false state selected_reading));

  finish_surface state ~clamped:(Keeper_list_scroll scroll_offset)
    ~surface_key:"keeper-list" ~rows:terminal_rows ~cols buf

(** Render keeper detail view with live context and scrolling *)
(* The detail box alone -- borders, title, scrolled content -- written into
   [buf] at [cols] wide, footer excluded so a caller can lay it beside the
   roster pane. Returns the scroll the frame actually used. *)
(* What the Keeper carries to reach a service, by name.

   Values are not here to be hidden -- the producer never sends them. The
   composite body carries names, counts and a validation flag, so this pane
   cannot show a credential by accident.

   A Keeper absent from the projection list is a different reading from one
   whose projection says [absent]: the first means the producer has not
   answered for this Keeper yet, the second means it answered that no root is
   configured. Saying "none" for both would report a fact the server did not
   send. [None] here is the first; the tab decides what to say about it from
   the Lanes reading the list rides on, because a list that is empty after a
   failed read and one that is empty before any read are the same list. *)
let secret_lines (state : state) (k : keeper) =
  let dim line = Ansi.dim ^ line ^ Ansi.reset in
  match
    List.find_opt
      (fun (p : Masc.Tui_decode.keeper_secret_projection) ->
        String.equal p.Masc.Tui_decode.ksp_keeper k.k_name)
      state.keeper_secrets
  with
  | None -> None
  | Some p ->
      let status = Masc.Tui_decode.keeper_secret_status_to_string p.ksp_status in
      let status_line =
        match p.ksp_status with
        | Masc.Tui_decode.Secret_ready ->
            "  Status:  " ^ (Theme.ok ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_error ->
            "  Status:  " ^ (Theme.bad ()) ^ status ^ Ansi.reset
        | Masc.Tui_decode.Secret_empty | Masc.Tui_decode.Secret_absent
        | Masc.Tui_decode.Secret_status_unknown _ ->
            "  Status:  " ^ Ansi.dim ^ status ^ Ansi.reset
      in
      let entry_lines label = function
        | [] -> [ dim (Printf.sprintf "  %s  -" label) ]
        | names ->
            List.mapi
              (fun index name ->
                let lead = if index = 0 then label else String.make (String.length label) ' ' in
                Printf.sprintf "  %s  %s" lead (Terminal_text.single_line name))
              names
      in
      detail_section_lines ~first:true "1. 시크릿 상태 · 루트 경로 (Status & Root)"
      @ [ status_line
        ; Printf.sprintf "  Root:    %s" (Terminal_text.single_line p.ksp_root)
        ]
      @ detail_section_lines "2. 환경변수 · 시크릿 파일 (Env & Files)"
      @ entry_lines "Env: " p.ksp_env_names
      @ (match p.ksp_file_paths with
         | [] -> []
         | paths -> "" :: entry_lines "Files:" paths)
      @ (match p.ksp_error with
         | None -> []
         | Some detail ->
             [ ""; (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ])
      @ [ ""
        ; dim
            (if p.ksp_values_validated then
               "  Values were read and validated. They are never sent here."
             else "  Values were not validated on the last read.")
        ]
      |> Option.some

(* The Identity tab's body. Numbering comes from
   [Masc_tui_identity_model.identity_connectable], which is also what the key handler
   indexes, so the number on screen and the provider a keypress starts are
   the same list. *)
let proactive_outcome_word = function
  | Masc.Keeper_meta_contract.Proactive_never_started -> "never started"
  | Masc.Keeper_meta_contract.Proactive_unknown -> "unknown"
  | Masc.Keeper_meta_contract.Proactive_silent -> "silent"
  | Masc.Keeper_meta_contract.Proactive_text_response -> "replied with text"
  | Masc.Keeper_meta_contract.Proactive_tool_use -> "used tools"
  | Masc.Keeper_meta_contract.Proactive_mixed_response -> "text and tools"
  | Masc.Keeper_meta_contract.Proactive_error -> "error"

(* The Terminal tab: a Keeper's Execute output as a terminal draws it, oldest
   row first. [terminal_rows] scroll; [terminal_status] is the row under them
   that stays put. [width] is the cells a row may use. *)
type terminal_drawing = { terminal_rows : string list; terminal_status : string }

let terminal_drawing (state : state) ~width =
  let module Execute_terminal = Masc_tui_execute_terminal in
  let hold = Masc_tui_types.keeper_terminal_hold state in
  let live = keeper_execute_view state in
  let observation = match hold with
    | Execute_terminal.Paused { frozen; _ } ->
        Masc_tui_fetched.Ready (frozen.ktf_reading, frozen.ktf_observed_at)
    | Execute_terminal.Following -> live in
  let sanitize = Masc.Tui_terminal_text.sanitize_terminal_text in
  let text_cells = max 1 (width - 2) in
  (* Each wrapped row replays the style it opened under and ends with a reset,
     so the pane can cut the list anywhere. *)
  let wrapped styled =
    Message_layout.wrap_styled_words ~max_cells:text_cells styled
    |> List.map (fun row -> "  " ^ row) in
  let note text = wrapped (Theme.recede () ^ sanitize text) in
  let lines_of = function
    | Keeper_execute_none -> []
    | Keeper_execute_snapshot snapshot ->
        List.map terminal_line_of_execute_line snapshot.kes_lines in
  let drawn_rows (reading : keeper_execute_reading) =
    match reading with
    | Keeper_execute_none -> note "No Execute output observed in this server process."
    | Keeper_execute_snapshot snapshot ->
        let rows = Execute_terminal.rows (lines_of reading) in
        let tagged = Execute_terminal.tagged rows in
        let tag (row : Execute_terminal.row) =
          if not tagged then ""
          else
            Theme.recede ()
            ^ Printf.sprintf "[%s] "
                (match row.stream_id with Some id -> string_of_int id | None -> "?")
            ^ Ansi.reset in
        (* A terminal puts a tab at the next stop; here it would read [\x09]. The
           stops run across the colour runs of one row. *)
        let with_tab_stops line =
          let _, runs =
            List.fold_left
              (fun (column, expanded) (run : Masc_tui_sgr_text.run) ->
                 let text, column = Execute_terminal.expand_tabs ~column run.text in
                 column, { run with text } :: expanded)
              (0, []) line in
          List.rev runs in
        let output_rows ~style (row : Execute_terminal.row) =
          Masc_tui_sgr_text.parse row.text
          |> List.concat_map (fun line ->
               wrapped
                 (tag row ^ style
                  ^ Masc_tui_sgr_text.render ~sanitize (with_tab_stops line))) in
        let ended_rows (row : Execute_terminal.row) status =
          let tone, label = match status with
            | Execute_terminal.Process (Unix.WEXITED 0 as ended) ->
                Theme.recede (), Masc_tui_execute_result.process_status_text ended
            | Process (Unix.WEXITED _ | Unix.WSIGNALED _ as ended) ->
                Theme.bad (), Masc_tui_execute_result.process_status_text ended
            | Process (Unix.WSTOPPED _ as ended) ->
                Theme.warn (), Masc_tui_execute_result.process_status_text ended
            | Outcome (phase, outcome) ->
                let what = match phase with
                  | Execute_terminal.Command -> ""
                  | Gate_observation -> "gate observation " in
                (match outcome with
                 | Execute_terminal.Result_unknown -> Theme.warn (), what ^ "result unknown"
                 | Request_not_sent -> Theme.warn (), what ^ "request not sent"
                 | Observation_ended -> Theme.recede (), what ^ "ended")
            | Rejected { why; reason } ->
                Theme.bad (),
                "rejected: " ^ why ^ (match reason with Some r -> " (" ^ r ^ ")" | None -> "")
            | Unrecognized text -> Theme.recede (), "status " ^ text in
          wrapped (tag row ^ tone ^ "\xc2\xb7 " ^ sanitize label) in
        let drawn (row : Execute_terminal.row) =
          match row.kind with
          | Execute_terminal.Command_start ->
              wrapped (tag row ^ Theme.info () ^ "$ " ^ Ansi.reset ^ Ansi.bold ^ sanitize row.text)
          | Command_more ->
              wrapped (tag row ^ Theme.info () ^ "> " ^ Ansi.reset ^ Ansi.bold ^ sanitize row.text)
          | Stdout -> output_rows ~style:"" row
          | Stderr -> output_rows ~style:(Theme.warn ()) row
          | Status status -> ended_rows row status
          | Foreign name ->
              wrapped (tag row ^ Theme.recede () ^ sanitize ("[" ^ name ^ "] " ^ row.text)) in
        let started = List.filter_map (fun (row : Execute_terminal.row) ->
          match row.kind with
          | Execute_terminal.Command_start -> row.stream_id
          | Command_more | Stdout | Stderr | Status _ | Foreign _ -> None) rows in
        (* A command that began before this window still runs; its line is the
           only thing that says what the output below belongs to. *)
        let running = List.filter (fun (stream : keeper_execute_stream) ->
          not (List.mem stream.kes_id started)) snapshot.kes_active in
        (if snapshot.kes_first_seq > 1 then
           note (Printf.sprintf "Earlier output is no longer kept (before sequence %d)."
                   snapshot.kes_first_seq)
         else [])
        @ (if snapshot.kes_lines_omitted > 0 then
             note (Printf.sprintf "%d older rows are not in this view." snapshot.kes_lines_omitted)
           else [])
        @ List.concat_map (fun (stream : keeper_execute_stream) ->
            note ("running: " ^ stream.kes_command)) running
        @ List.concat_map drawn rows in
  let rows = match observation with
    | Masc_tui_fetched.Absent -> note "Execute output has not been read."
    | Loading -> note "Reading Execute output\xe2\x80\xa6"
    | Failed detail -> wrapped (Theme.bad () ^ sanitize ("Execute output unavailable: " ^ detail))
    | Ready (reading, _) | Stale ((reading, _), _) -> drawn_rows reading in
  let newer = match hold, Masc_tui_fetched.value live with
    | Execute_terminal.Paused { frozen; _ }, Some (live_reading, _) ->
        Execute_terminal.unseen ~seen:(lines_of frozen.ktf_reading) ~latest:(lines_of live_reading)
    | (Execute_terminal.Paused _ | Execute_terminal.Following), (Some _ | None) -> 0 in
  let mode = match hold with
    | Execute_terminal.Following -> "following"
    | Paused _ ->
        Printf.sprintf "paused \xc2\xb7 %s \xc2\xb7 End:follow"
          (Message_layout.count_noun newer "newer row") in
  let facts = match observation with
    | Masc_tui_fetched.Ready (Keeper_execute_snapshot snapshot, observed_at)
    | Stale ((Keeper_execute_snapshot snapshot, observed_at), _) ->
        let time = Unix.localtime observed_at in
        [ (if snapshot.kes_active_count > 0 then Printf.sprintf "%d active" snapshot.kes_active_count
           else if snapshot.kes_closed then "closed" else "state unknown")
        ; Printf.sprintf "%02d:%02d:%02d" time.Unix.tm_hour time.tm_min time.tm_sec ]
    | Ready (Keeper_execute_none, _) | Stale ((Keeper_execute_none, _), _)
    | Absent | Loading | Failed _ -> [] in
  let stale = match observation with
    | Masc_tui_fetched.Stale (_, detail) -> [ Theme.bad () ^ "stale: " ^ sanitize detail ^ Ansi.reset ]
    | Ready _ | Absent | Loading | Failed _ -> [] in
  { terminal_rows = rows;
    terminal_status = Theme.recede () ^ String.concat " \xc2\xb7 " (mode :: facts) ^ Ansi.reset
                      ^ String.concat "" (List.map (fun part -> " \xc2\xb7 " ^ part) stale) }

let keeper_detail_pane (state : state) (k : keeper) ~framed ~rows ~cols
    ~origin:(origin_row, origin_col) buf =
    (* Beside the roster pane the box is the pane separator; alone on the
       surface it is the redundant outer frame, dropped. *)
    let box_top = if framed then framed_top else box_top in
    let box_divider = if framed then framed_divider else box_divider in
    let box_line = if framed then framed_line else box_line in
    let box_empty = if framed then framed_empty else box_empty in
    let box_bottom = if framed then framed_bottom else box_bottom in
    let inner = framed_inner_width cols in
    (* What the pane has written so far, so the portrait's placement is
       counted from what was drawn above it rather than by hand. *)
    let pane_start = Buffer.length buf in
    (* The content rows under the title and divider, before an overflow
       indicator takes one of them. *)
    let base_height = max 0 (rows - framed_chrome_rows) in
    (* Info shows the current outfit; Items changes only the drawing for its
       selected preview. Both use the server's observed equipment. *)
    let portrait_reading = match (keeper_reading state k).Keeper_control.liveness with
      | Keeper_control.Present runtime -> runtime.kr_portrait
      | Keeper_control.Unobserved -> Tui_decode.Unavailable "not yet read"
      | Keeper_control.Absent -> Tui_decode.Unavailable "absent from live roster"
      | Keeper_control.Invalid detail -> Tui_decode.Unavailable detail in
    let account = selected_item_account state in
    let items = item_browser_items state in
    let cursor = Item_account.cursor ~items state.item_cursor in
    let selected_item = List.nth_opt items cursor in
    let milli value = Printf.sprintf "%d.%03d" (value / 1000) (value mod 1000) in
    let account_line =
      match account, state.item_account_error with
      | Some (Item_account.Ready account), _ ->
          Printf.sprintf "  Wallet %s Candle · %d owned" (milli account.balance_milli)
            (List.length account.owned_items)
      | Some Item_account.Off, _ -> "  Candle off"
      | Some (Item_account.Disabled reason), _ ->
          "  Candle disabled: " ^ Terminal_text.single_line reason
      | None, Some detail -> "  Account unavailable: " ^ Terminal_text.single_line detail
      | None, None ->
          (match pending_detail_read state ~tab:Detail_items ~keeper:k.k_name with
           | Some _ -> "  Loading Item account…"
           | None -> "  Item account not observed")
    in
    let is_worn item =
      match portrait_reading with
      | Tui_decode.Unavailable _ -> false
      | Tui_decode.Ready equipment ->
          Keeper_portrait_item.in_slot equipment (Keeper_portrait_item.slot item) = Some item
    in
    (* Starting accessories may be worn without being purchased. Ownership and
       the observed picture therefore remain separate facts. *)
    let equipped_word = "  " ^ Ansi.bold ^ "wearing" ^ Ansi.reset in
    let item_account_facts item =
      match account with
      | Some (Item_account.Ready account) ->
          let owned = List.mem item account.owned_items in
          let price =
            match List.find_opt (fun (entry : Item_account.entry) -> entry.item = item) account.catalog with
            | None -> "catalog unavailable"
            | Some { price = Item_account.Unpriced; _ } -> "unpriced"
            | Some { price = Item_account.Priced 0; _ } -> "free"
            | Some { price = Item_account.Priced amount; _ } ->
              milli amount ^ " Candle"
              ^ (if owned then ""
                 else if amount <= account.balance_milli then " · can buy"
                 else " · need " ^ milli (amount - account.balance_milli) ^ " more")
          in
          Some ((if owned then "owned · " else "not owned · ") ^ price)
      | Some (Item_account.Off | Item_account.Disabled _) | None -> None
    in
    let outfit_lines = match portrait_reading with
      | Tui_decode.Unavailable _ -> []
      | Tui_decode.Ready equipment ->
        let slots = List.map (fun slot ->
          let name = match Keeper_portrait_item.in_slot equipment slot with
            | None -> "none"
            | Some item -> Item_account.item_name item in
          Keeper_portrait_item.slot_id slot ^ ": " ^ name) Keeper_portrait_item.slots in
        Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
          ("Wearing · " ^ String.concat " · " slots)
        |> List.map (fun line -> "  " ^ line)
    in
    let portrait =
      match state.detail_tab, portrait_reading with
      | Detail_info, Tui_decode.Ready equipment ->
          Masc_tui_keeper_portrait.shown ~name:k.k_name ~equipment
            ~content_rows:base_height ~content_cols:inner
      | Detail_items, Tui_decode.Ready equipment ->
          let equipment = match state.item_preview, selected_item with
            | true, Some item -> Keeper_portrait_item.preview item equipment
            | (true | false), (Some _ | None) -> equipment in
          Masc_tui_keeper_portrait.preview ~name:k.k_name ~equipment
            ~content_rows:base_height ~content_cols:inner
      | (Detail_info | Detail_items), Tui_decode.Unavailable _
      | (Detail_sandbox | Detail_instructions | Detail_secrets | Detail_github
        | Detail_identity | Detail_channels | Detail_automation | Detail_runs
        | Detail_terminal), _ -> None
    in
    let item_row index item =
      let facts = if inner < 90 then "" else
        match item_account_facts item with Some facts -> "  " ^ facts | None -> "" in
      Printf.sprintf "  %s %-5s %s%s%s"
        (if index = cursor then ">" else " ")
        (Keeper_portrait_item.slot_id (Keeper_portrait_item.slot item))
        (Item_account.item_name item) facts (if is_worn item then equipped_word else "")
    in
    let headline =
      [ Printf.sprintf "  Items · %s · %d/%d · %s"
          (Item_account.filter_name state.item_filter)
          (if items = [] then 0 else cursor + 1) (List.length items)
          (if state.item_preview && selected_item <> None then "try on" else "current outfit")
      ; account_line ]
    in
    let portrait = match state.detail_tab, portrait with
      | Detail_items, Some band ->
          if List.exists (fun line -> Message_layout.display_width line > inner)
               (Masc_tui_keeper_portrait.beside band (headline @ List.mapi item_row items))
          then None else Some band
      | (Detail_info | Detail_items | Detail_sandbox | Detail_instructions | Detail_secrets
        | Detail_github | Detail_identity | Detail_channels | Detail_automation | Detail_runs
        | Detail_terminal), portrait -> portrait
    in
    let item_lines () =
      let count = List.length items in
      let observation = match portrait_reading with
        | Tui_decode.Ready _ -> []
        | Tui_decode.Unavailable reason ->
          [ "  Portrait unavailable: " ^ Terminal_text.single_line reason ] in
      let selected_facts = match selected_item with
        | None -> []
        | Some item ->
          let name = "  " ^ Ansi.bold ^ Item_account.item_name item ^ Ansi.reset
            ^ " · " ^ Keeper_portrait_item.slot_id (Keeper_portrait_item.slot item)
            ^ (if is_worn item then equipped_word else "") in
          name :: (match item_account_facts item with
            | Some facts -> ["  " ^ facts]
            | None -> []) in
      let empty = if count > 0 then [] else
        [ "  " ^ (match state.item_filter, account with
          | Item_account.Owned, Some (Item_account.Ready _) -> "No purchased accessories yet."
          | Item_account.Can_buy, Some (Item_account.Ready _) -> "No unowned item fits the current balance."
          | (Item_account.Owned | Item_account.Can_buy), (None | Some (Item_account.Off | Item_account.Disabled _)) ->
            "This view needs a ready Item account."
          | (Item_account.All | Item_account.In_slot _), _ -> "No items in this view.") ] in
      let footer = ["  Requests open a chat draft; the Keeper reports the result."] in
      let reserved = List.length headline + List.length selected_facts + List.length outfit_lines
        + List.length observation + List.length empty + List.length footer in
      let visible = min count (max 1 (base_height - reserved)) in
      let first = max 0 (min (cursor - visible / 2) (count - visible)) in
      let rows = List.filter_map (fun (index, item) ->
        if index < first || index >= first + visible then None else Some (item_row index item))
        (List.mapi (fun index item -> index, item) items) in
      let listing = match portrait with
        | Some band -> Masc_tui_keeper_portrait.beside band (headline @ rows @ empty)
        | None -> headline @ rows @ empty in
      listing @ selected_facts @ outfit_lines @ observation @ footer
    in
    (* A long value takes the width below its label, rather than the few
       cells a fixed label column leaves beside it. These are actual display
       rows, counted before the detail window is sliced. Values have already
       passed their wire-boundary sanitizer and may carry this pane's SGR. *)
    let field_rows ~width ~label_cells ~label_style label value =
      let prefix = "  " ^ label_style ^ fit_width label label_cells ^ Ansi.reset ^ " " in
      if Message_layout.display_width label <= label_cells
         && Message_layout.display_width (prefix ^ value) <= width then
        [prefix ^ value]
      else
        (Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 2)) label
         |> List.map (fun line -> "  " ^ label_style ^ line ^ Ansi.reset))
        @ (Message_layout.wrap_styled_words ~max_cells:(max 1 (width - 4)) value
           |> List.map (fun line -> "    " ^ line ^ Ansi.reset))
    in

    (* Each tab projects only when selected. Retained data for the other
       tabs must not be walked and formatted on every scroll frame. These
       functions capture this frame, so switching tabs reads current state. *)
    let info_lines () =
      (* Build all detail lines first, then apply scroll *)
      let lines = ref [] in
      let add_line s = lines := s :: !lines in

      (* Helper to add a labeled row *)
      let row_lines ~width label value =
        field_rows ~width ~label_cells:18
          ~label_style:Ansi.dim label value
      in
      let add_row label value = List.iter add_line (row_lines ~width:inner label value) in
      let add_empty () = add_line "" in
      let section_line title = Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset in
      let add_section title = add_line (section_line title) in

      (* Identity, current task and context share the icon's header. These
         facts use the same label column, rather than leaving the portrait's
         lower rows blank while the current work falls below the viewport. *)
      let header_width = match portrait with
        | None -> inner
        | Some band -> max 1 (inner - 2 - band.Masc_tui_keeper_portrait.box.cols)
      in
      let identity =
        let width = header_width in
        [ section_line "Identity" ]
        @ row_lines ~width "Name:" (Terminal_text.single_line k.k_name)
        @ row_lines ~width "Paused:"
            (match k.k_origin, (keeper_reading state k).Keeper_control.liveness with
             | Tui_decode.Remote_keeper,
                 (Keeper_control.Invalid _ | Unobserved | Absent) ->
                 Ansi.dim ^ "not observed" ^ Ansi.reset
             | (Tui_decode.Persisted_keeper | Declared_keeper _), _
             | Remote_keeper, Keeper_control.Present _ ->
                 if k.k_paused then (Theme.warn ()) ^ "yes" ^ Ansi.reset
                 else Ansi.dim ^ "no" ^ Ansi.reset)
        @ (let amount = match (keeper_reading state k).Keeper_control.liveness with
            | Keeper_control.Present runtime -> runtime.kr_candle_balance_milli
            | Keeper_control.Unobserved | Keeper_control.Absent | Keeper_control.Invalid _ -> None in
           match Masc_tui_candle.balance_text state.candle_observation amount with
           | None -> []
           | Some value -> row_lines ~width "Candle balance:" (Terminal_text.single_line value))
      in
      List.iter add_line identity;
      (match portrait_reading with
       | Tui_decode.Ready _ -> ()
       | Tui_decode.Unavailable reason -> add_row "Portrait:" ("unavailable: " ^ Terminal_text.single_line reason));
      add_empty ();
      let add_row label value =
        List.iter add_line (row_lines ~width:header_width label value)
      in
      (* Current work section *)
      add_section "Current Work";
      add_row "Task:"
        (match k.k_activity with
         | None -> "not observed"
         | Some activity -> Terminal_text.single_line_or
             ~default:Masc_tui_theme.Glyph.no_value activity.k_current_task_id);
      add_empty ();

      add_section "Live Context";
      let add_context observation =
        match Observation_layout.context_summary observation with
        | Observation_layout.Context_measured observation ->
            let ratio = observation.ratio in
            let pct = Float.of_int (Observation_layout.percentage_tenths ratio) /. 10.0 in
            let bar_width = Layout.keeper_context_bar_width ~inner_width:header_width in
            add_row "Context:"
              (Printf.sprintf "%s%.1f%%%s  %s  %s / %s tokens"
                 (ctx_color ratio) pct Ansi.reset (ctx_bar ratio bar_width)
                 (Masc_tui_message_layout.compact_count observation.tokens)
                 (Masc_tui_message_layout.compact_count observation.maximum));
            add_row "Observed:" (Terminal_text.short_timestamp observation.observed_at);
            add_row "Turn Ref:" (Terminal_text.single_line observation.turn_ref)
        | Observation_layout.Context_partial observation ->
            add_row "Context:"
              (Printf.sprintf "%s tokens in context; window not observed"
                 (Masc_tui_message_layout.compact_count observation.tokens));
            add_row "Observed:" (Terminal_text.short_timestamp observation.observed_at);
            add_row "Turn Ref:" (Terminal_text.single_line observation.turn_ref)
        | Observation_layout.Context_unavailable reason ->
            add_row "Context:" (Ansi.dim ^ reason ^ Ansi.reset)
      in
      (match live_context_view state k with
       | Masc_tui_fetched.Absent ->
           add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset)
       | Masc_tui_fetched.Loading ->
           add_row "Context:" (Ansi.dim ^ "reading" ^ Ansi.reset)
       | Masc_tui_fetched.Ready observation -> add_context observation
       | Masc_tui_fetched.Stale (observation, detail) ->
           add_row "Refresh:" ((Theme.bad ()) ^ Terminal_text.single_line detail ^ Ansi.reset);
           add_context observation
       | Masc_tui_fetched.Failed detail ->
           add_row "Context:" ((Theme.bad ()) ^ Terminal_text.single_line detail ^ Ansi.reset));
      add_empty ();

      let header_lines = List.rev !lines in
      lines := [];
      List.iter add_line
        (match portrait with
         | Some band -> Masc_tui_keeper_portrait.beside band header_lines
         | None -> header_lines);
      let add_row label value = List.iter add_line (row_lines ~width:inner label value) in
      let add_numbered_section ?(first = false) title =
        List.iter add_line (detail_section_lines ~first title)
      in

      (* The live roster owns this reading, including its absence after a
         successful turn. Neither historical last_error nor the last outcome
         can answer for the current failure. A blocker may carry a signature:
         the machine wire its summary replaced with a human sentence. It is
         drawn dimmed underneath, so the wire a log search keys on stays on
         screen without ever leading the row. *)
      add_numbered_section ~first:true
        "1. 현재 장애 · 보드 격리 (Current Failure & Board Attention)";
      let indent = "  " in
      let wrap ?(tone = "") text =
        Message_layout.wrap_words
          ~max_cells:(max 1 (inner - Message_layout.display_width indent))
          (Terminal_text.single_line text)
        |> List.iter (fun line -> add_line (indent ^ tone ^ line ^ Ansi.reset))
      in
      let () =
        match (keeper_reading state k).Keeper_control.liveness with
        | Keeper_control.Present runtime -> (
            match runtime.kr_runtime_blocker_summary with
            | Some summary ->
                wrap ~tone:(Theme.bad ()) summary;
                (match runtime.kr_runtime_blocker_signature with
                | Some signature -> wrap ~tone:Ansi.dim signature
                | None -> ())
            | None -> wrap ~tone:Ansi.dim "none")
        | Keeper_control.Unobserved -> wrap ~tone:Ansi.dim "unread"
        | Keeper_control.Absent -> wrap ~tone:Ansi.dim "absent from live roster"
        | Keeper_control.Invalid detail ->
            wrap ~tone:(Theme.bad ()) ("config error: " ^ detail)
      in

      (* Blocked Board-attention partitions wait here for an
         operator's requeue, and nothing else on the screens said they existed.
         Beside the current failure because it is one: this Keeper's Board
         judgments for those posts do not move until someone presses Q. *)
      Masc_tui_board_quarantine.lines ~now:(Unix.gettimeofday ())
        state.keeper_board_quarantines ~keeper_name:k.k_name
      |> List.iter (fun (tone, text) ->
           let color =
             match tone with
             | Masc_tui_board_quarantine.Plain -> ""
             | Masc_tui_board_quarantine.Dim -> Ansi.dim
             | Masc_tui_board_quarantine.Warn -> Theme.warn ()
             | Masc_tui_board_quarantine.Bad -> Theme.bad ()
           in
           Message_layout.wrap_words ~max_cells:(max 1 (inner - 2)) text
           |> List.iter (fun line -> add_line (indent ^ color ^ line ^ Ansi.reset)));

      (* Gate section. Two settings with similar names decide different things,
         so both are named rather than merged: YOLO is the in-memory stance that
         stops this chat asking and a restart clears, while the Gate mode is
         durable and is what an external effect -- a write to a service this
         Keeper is attached to -- is actually decided under. An operator reading
         one for the other is how a call gets made that nobody meant to allow. *)
      add_numbered_section "2. 권한 게이트 · 승인 정책 (Gate & Tool Policy)";
      (* The same word the chat header wears in capitals and the footer offers
         after g, with what it does beside it. This row said "asked" under a
         header saying AUTO. *)
      add_row "Tool calls:"
        (let mode =
           if List.mem k.k_name state.keeper_yolo_names then
             Masc.Keeper_tool_approval_mode.Yolo
           else Masc.Keeper_tool_approval_mode.Auto
         in
         let tone =
           match mode with
           | Masc.Keeper_tool_approval_mode.Yolo -> Theme.bad ()
           | Masc.Keeper_tool_approval_mode.Auto -> Ansi.dim
         in
         tone ^ Masc_tui_types.tool_mode_word mode ^ " \xc2\xb7 "
         ^ Masc_tui_types.tool_mode_effect mode ^ Ansi.reset);
      (* "workspace" is where the stance comes from, not what it is. The chat
         header resolves the same inheritance before drawing it; this row left
         the reader to go and look it up. *)
      add_row "Effects (Gate mode):"
        (let inherited =
           Option.map
             (fun (modes : Tui_decode.gate_lane_modes) ->
               gate_mode_reading_word modes.Tui_decode.glm_workspace)
             state.gate_modes
         in
         match List.assoc_opt k.k_name state.keeper_gate_modes with
         | Some mode ->
             (Masc_tui_theme.tone Masc_tui_theme.Accent)
             ^ Terminal_text.single_line (gate_mode_reading_word mode)
             ^ Ansi.reset
         | None ->
             Ansi.dim ^ "workspace"
             ^ (match inherited with
                | Some word -> " \xc2\xb7 " ^ Terminal_text.single_line word
                | None -> "")
             ^ Ansi.reset);
      add_row "Lane first:"
        (match
           List.filter
             (fun (first : Tui_decode.keeper_exact_lane_first) ->
               String.equal first.Tui_decode.kel_keeper k.k_name)
             state.keeper_exact_lane_firsts
         with
         | [] -> Ansi.dim ^ "lane order" ^ Ansi.reset
         | firsts ->
             (Masc_tui_theme.tone Masc_tui_theme.Accent)
             ^ Terminal_text.single_line
                 (String.concat ", "
                    (List.map
                       (fun (first : Tui_decode.keeper_exact_lane_first) ->
                         (* The marker leads: a narrow pane cuts the row's
                            tail, and the slot id is the part it can lose. *)
                         (if first.kel_offered then ""
                          else "not offered, lane order \xc2\xb7 ")
                         ^ first.Tui_decode.kel_lane_id ^ " \xe2\x86\x92 "
                         ^ first.kel_slot_id)
                       firsts))
             ^ Ansi.reset);
      (match state.keeper_gate_settings_unread with
       | None -> ()
       | Some reason ->
           add_row "Gate settings:"
             (Theme.bad () ^ "unread \xc2\xb7 "
              ^ Terminal_text.single_line reason ^ Ansi.reset));

      (* Runtime & 24h section *)
      add_numbered_section "3. 런타임 배정 · 최근 24시간 활동 (Runtime & Last 24h Activity)";
      List.iter (fun (label, value) -> add_row label value)
        (keeper_operations_fields state ~keeper_name:k.k_name);
      let assignment =
        List.find_opt
          (fun (a : Tui_decode.runtime_assignment) ->
             String.equal a.ra_keeper k.k_name)
          state.runtime_assignments
      in
      let target_str =
        match assignment with
        | Some a -> runtime_assignment_label a
        | None ->
            let def_name =
              match state.runtime_surface with
              | Some s ->
                  (match s.rss_resolved.rrs_default_runtime_id with
                   | Some d -> Printf.sprintf "inherited: %s" d
                   | None -> "inherited")
              | None -> "inherited"
            in
            Printf.sprintf "default (%s)" def_name
      in
      add_row "Runtime Target:" target_str;
      (match assignment with
       | Some { ra_resolution = Runtime_assignment_lane tid; _ } ->
           (match
              List.find_opt
                (fun (l : Tui_decode.runtime_resolved_lane) ->
                   String.equal l.rrl_id tid)
                state.runtime_lanes
            with
            | Some lane ->
                let hops =
                  String.concat " \xe2\x86\x92 "
                    (List.map runtime_id_model_part lane.rrl_runtime_ids)
                in
                add_row "Candidate Chain:" hops;
                (match lane.rrl_runtime_ids with
                 | first :: _ -> add_row "Head Candidate:" first
                 | [] -> ())
            | None -> ())
       | Some
           { ra_resolution =
               (Runtime_assignment_missing | Runtime_assignment_unavailable _)
           ; _
           } ->
         ()
       | None ->
           (match state.runtime_surface with
            | Some snap ->
                (match snap.rss_resolved.rrs_default_runtime_id with
                 | Some def_id ->
                     (match
                        List.find_opt
                          (fun (ro : Tui_decode.runtime_option) -> String.equal ro.ro_id def_id)
                          snap.rss_resolved.rrs_runtimes
                      with
                      | Some ro ->
                          add_row "Default Context:"
                            (Printf.sprintf "%s \xc2\xb7 max output %s"
                               (format_context_tokens ro.ro_effective_max_context)
                               (match ro.ro_max_output_tokens with
                                | Some t -> format_context_tokens t
                                | None -> "default"))
                      | None -> ())
                 | None -> ())
            | None -> ()));
      (match k.k_origin with
       | Tui_decode.Persisted_keeper -> ()
       | Remote_keeper -> add_row "Source:" "server roster"
       | Declared_keeper requirements ->
         add_row "Preparation:" (String.concat " · "
           (List.map Masc.Keeper_declared_roster.requirement_label requirements)));
      add_row "Last Outcome:"
        (match k.k_activity with
         | None -> "not observed"
         | Some activity ->
           (match activity.k_last_proactive_outcome with
            | Some outcome -> proactive_outcome_word outcome
            | None -> Masc_tui_theme.Glyph.no_value));
      (* Recent activity, folded from the metrics rows already read for this
         Keeper. The window is bounded by row count, so it can fall short of the
         span; when it does, say what it reached instead of implying a full day.
         With no rows there is nothing to total, so the section says why and
         draws no zeros: the same sentence the Logs tab gives for the same
         read. *)
      let log_snapshot = keeper_log_snapshot state in
      let log_diagnostics = keeper_log_diagnostics state in
      List.iter (fun (tone, detail) ->
        add_row "Metrics:" (keeper_log_style tone ^ Terminal_text.single_line detail ^ Ansi.reset))
        log_diagnostics;
      (match
         Keeper_activity.read
           ~since:
             (Keeper_activity.cutoff_of ~now:(Unix.gettimeofday ()) ~hours:24)
           log_snapshot.entries
       with
       | Keeper_activity.No_rows ->
         if log_diagnostics = [] then add_row "Window:"
           (Ansi.dim ^ Metrics_tail.empty_message log_snapshot.error ^ Ansi.reset)
       | Keeper_activity.Rows activity ->
         if not activity.Keeper_activity.aw_covered then
           add_row "Window:"
             (match activity.Keeper_activity.aw_oldest_ts with
              | Some oldest ->
                Printf.sprintf "partial, reaches %s"
                  (Terminal_text.short_timestamp oldest)
              | None -> "partial");
         add_row "Turns / Heartbeats:"
           (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_turns
              activity.Keeper_activity.aw_heartbeats);
         add_row "Tokens In / Out:"
           (Printf.sprintf "%s / %s"
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_input_tokens)
              (Masc_tui_message_layout.compact_count
                 activity.Keeper_activity.aw_output_tokens));
         add_row "Cost:"
           (match activity.Keeper_activity.aw_cost_usd with
            | Some cost -> Printf.sprintf "$%.4f" cost
            | None -> Ansi.dim ^ "not priced by the provider" ^ Ansi.reset);
         add_row "Tool Calls:"
           (string_of_int activity.Keeper_activity.aw_tool_calls);
         add_row "Top Tools:"
           (match activity.Keeper_activity.aw_top_tools with
            | [] -> Masc_tui_theme.Glyph.no_value
            | tools ->
              tools
              |> List.map (fun (tool : Keeper_activity.tool_use) ->
                     Printf.sprintf "%s x%d"
                       (Terminal_text.single_line tool.Keeper_activity.tu_name)
                       tool.Keeper_activity.tu_calls)
              |> String.concat "  "));

      (* Historical receipt evidence is a separate reading. A successful
         fallback may retain earlier refusals while the live blocker is clear. *)
      add_numbered_section "4. 최근 후보 모델 폴백 이력 (Recorded Runtime Walk)";
      let module Receipt = Masc.Keeper_execution_receipt in
      let module Evidence = Keeper_runtime_walk_evidence in
      let module Fault = Llm_provider.Candidate_fault in
      let history_row label value = add_row label (Terminal_text.single_line value) in
      let source (turn : Receipt.receipt_turn) =
        history_row "Receipt trace:" turn.receipt_trace_id;
        history_row "Receipt turn:"
          (match turn.receipt_turn_count with
           | Some count -> string_of_int count
           | None -> "not recorded");
        history_row "Receipt ended:" turn.receipt_ended_at
      in
      let fault = function
        | None -> "API classification inapplicable"
        | Some Fault.Unattributed -> "unattributed API refusal"
        | Some Fault.Unknown_after_dispatch -> "outcome uncertain"
        | Some (Fault.Binding binding) ->
          match binding with
          | Fault.Credential -> "credential"
          | Fault.Account_access -> "account access"
          | Fault.Account -> "account"
          | Fault.Model_absent -> "model absent"
          | Fault.Rate_limit -> "rate limit"
          | Fault.Capacity -> "capacity"
          | Fault.Server -> "server"
          | Fault.Window -> "context window"
          | Fault.Body_limit -> "body limit"
          | Fault.Admission -> "admission"
          | Fault.Deadline -> "deadline"
          | Fault.Output_dialect -> "output dialect"
          | Fault.Refusal_unread -> "refusal unread"
      in
      (match (keeper_reading state k).Keeper_control.liveness with
       | Keeper_control.Present runtime ->
         (match runtime.kr_runtime_lane_observation with
          | None -> wrap ~tone:Ansi.dim "no receipt"
          | Some (Receipt.Runtime_lane_not_observed turn) ->
            source turn;
            wrap ~tone:Ansi.dim "candidate walk was not captured"
          | Some (Receipt.Runtime_lane_unreadable {turn;field}) ->
            Option.iter source turn;
            wrap ~tone:(Theme.warn ()) ("historical evidence unreadable: " ^ field)
          | Some (Receipt.Runtime_lane_observed {turn;evidence}) ->
            source turn;
            (match evidence.failures with
             | [] -> wrap ~tone:Ansi.dim "no candidate failure recorded"
             | failures -> List.iter (fun (failure : Evidence.failure) ->
                 history_row "Candidate:"
                   (Printf.sprintf "%d · %s" failure.attempt failure.runtime_id);
                 history_row "Invocation:"
                   (match failure.dispatch with
                    | Runtime_attempt_dispatch.Dispatched -> "candidate invoked"
                    | Runtime_attempt_dispatch.Rejected_before_dispatch -> "rejected before invocation");
                 history_row "API fact:" (fault failure.api_candidate_fault);
                 wrap (Keeper_request_failure.summary failure.failure)) failures);
            (match evidence.terminal with
             | Evidence.Terminal_not_observed ->
               history_row "Terminal origin:" "not observed"
             | Evidence.Candidate_terminal {runtime_id;attempt;failure} ->
               history_row "Terminal origin:" (Printf.sprintf "%d · %s" attempt runtime_id);
               wrap (Keeper_request_failure.summary failure)))
       | Keeper_control.Unobserved -> wrap ~tone:Ansi.dim "live roster unread"
       | Keeper_control.Absent -> wrap ~tone:Ansi.dim "absent from live roster"
       | Keeper_control.Invalid detail ->
         wrap ~tone:(Theme.warn ()) ("roster unavailable: " ^ detail));

      (* Lifetime totals & Timestamps section *)
      add_numbered_section "5. 누적 통계 · 생성 이력 (Lifetime Totals & Timestamps)";
      (match k.k_activity with
       | None -> add_row "Activity:" "not observed"
       | Some activity ->
         add_row "Total Turns:" (string_of_int activity.k_total_turns);
         (* Read at a glance, the way the Acting pane's block already reads its
            token figures. A live roster drew "75111274" here: eight digits a
            reader counts rather than reads. Turns and tool calls keep their
            digits -- three or four of them, and a count of things done rather
            than a size. *)
         add_row "Total Tokens:"
           (Masc_tui_message_layout.compact_count activity.k_total_tokens);
         add_row "Lifetime Cost:" (Tui_decode.keeper_cost_summary activity.k_total_cost_usd);
         add_row "Last Turn:" (Terminal_text.short_timestamp activity.k_last_turn_ts));
      (match k.k_identity with
       | Ok identity ->
         add_row "Created:" (Terminal_text.short_timestamp identity.k_created_at);
         add_row "Updated:" (Terminal_text.short_timestamp identity.k_updated_at)
       | Error reason ->
           Message_layout.wrap_words ~max_cells:(max 1 (inner - 26))
             (Terminal_text.single_line reason)
           |> List.iteri (fun index line ->
                add_row (if index = 0 then "Metadata:" else "") line));

      List.rev !lines
    in
    (* The non-Info tabs draw a fetched read; the stamp has to name the
       keeper on screen or the pane shows loading, never another keeper's
       answer. *)
    (* A pending read says how long it has been pending. Five to sixteen
       seconds is what the Sandbox tab's status took against a live server,
       and a bare "(loading...)" through that window reads as a stall.

       The stamp is the read's own: the tab read and the container-log read are
       two reads and the operator starts the second long after the first has
       landed. One reading of the clock for the frame, so two rows drawn in the
       same frame cannot disagree about what time it is. *)
    let now_ns = Mtime_clock.elapsed_ns () in
    let loading_row ?started_ns what =
      Ansi.dim ^ "  "
      ^ Masc_tui_types.loading_notice
          ?elapsed_s:(Masc_tui_types.pending_elapsed_s ~now_ns started_ns)
          what
      ^ Ansi.reset
    in
    let stamped_or view error =
      let observed = match view with
        | Some (stamp, lines) when String.equal stamp k.k_name ->
            Some (List.map (fun line -> "  " ^ line) lines)
        | Some _ | None -> None in
      (* Only this tab's original pending request proves a read is scheduled.
         A missing or foreign snapshot does not prove any work is in flight. *)
      let pending = Masc_tui_types.detail_read_started state
          ~tab:state.detail_tab ~keeper:k.k_name in
      let failure = match error with
        | None -> []
        | Some detail ->
            [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset ] in
      let progress = match pending with
        | None -> []
        | Some started_ns ->
            [ loading_row ~started_ns
                (match observed with None -> "loading" | Some _ -> "refreshing") ] in
      match observed with
      | Some lines ->
          let previous = match error, pending with
            | None, None -> []
            | Some _, (Some _ | None) | None, Some _ ->
                [ Ansi.dim ^ "  Last observation:" ^ Ansi.reset ] in
          failure @ progress @ previous @ lines
      | None ->
          (match error, pending with
           | None, None ->
               [ Ansi.dim ^ "  "
                 ^ (if server_authority_ready state then "Not observed · r to read"
                    else "Not observed · workspace confirmation required")
                 ^ Ansi.reset ]
           | Some _, (Some _ | None) | None, Some _ -> failure @ progress)
    in
    let channel_lines () =
      let rows = match state.connectors_error, state.connectors with
      | Some detail, None ->
          [ (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail
            ^ Ansi.reset ]
      | None, None ->
          (match Connector_read.view state.connectors_read with
           | Connector_read.Quiet ->
               [ Ansi.dim ^ "  Channel transports not observed" ^ Ansi.reset ]
           | Reading _ | Waiting_after_write | Failed_to_start ->
               (* The existing typed-source notice below owns pending,
                  held recheck and failed-start guidance; none is a value. *)
               [])
      | error, Some snapshot ->
          let connectors = snapshot.cs_connectors in
          let selected_index =
            max 0 (min state.connectors_cursor (List.length connectors - 1))
          in
          (* The list row and the detail badge spell the same connection, so
             they read the same table. This pane kept a byte-identical copy of
             it, which meant a change to the vocabulary could land in one
             place and leave the omission rule in [Masc_tui_connector_state]
             judging against the other. *)
          let connection_label (connector : Masc.Tui_decode_connectors.connector) =
            let word =
              Masc_tui_connector_state.badge_word connector.cn_connection
            in
            match connector.cn_connection with
            | Masc.Tui_decode_connectors.Connector_connected ->
                (Theme.ok ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_connected_unavailable ->
                (Theme.warn ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_disconnected -> (Theme.bad ()) ^ "● " ^ word ^ Ansi.reset
            | Connector_offline -> Ansi.dim ^ "○ " ^ word ^ Ansi.reset
            | Connector_stale -> (Theme.warn ()) ^ "● " ^ word ^ Ansi.reset
          in
          let transport_rows =
            List.mapi
              (fun index (connector : Masc.Tui_decode_connectors.connector) ->
                 let here_count =
                   List.length
                     (List.filter
                        (fun (binding : Masc.Tui_decode_connectors.connector_binding) ->
                           String.equal binding.cb_keeper_name k.k_name)
                        connector.cn_bindings)
                 in
                 let tail =
                   Printf.sprintf "  %d here / %d total" here_count
                     (List.length connector.cn_bindings)
                 in
                 (* Two cells of indent, two for the cursor mark, two between
                    the name and the badge: the padding the row spends before
                    its columns. *)
                 let name_cells =
                   Masc_tui_connector_state.list_row_name_cells
                     ~inner:(framed_inner_width cols) ~fixed_cells:6
                     ~tail_cells:(String.length tail)
                 in
                 let line =
                   "  " ^ (if index = selected_index then "▸ " else "  ")
                   ^ fit_width
                       (Terminal_text.single_line connector.cn_display_name)
                       name_cells
                   ^ "  "
                   ^ fit_width
                       (Masc_tui_connector_state.badge_word
                          connector.cn_connection)
                       Masc_tui_connector_state.badge_column_cells
                   ^ tail
                 in
                 if index = selected_index then Ansi.reverse ^ line ^ Ansi.reset
                 else line)
              connectors
          in
          let refused_rows =
            List.map
              (fun (refusal : Masc.Tui_decode_connectors.connector_refusal) ->
                 let name =
                   match refusal.cr_connector_id with
                   | Some id -> Terminal_text.single_line id
                   | None -> Printf.sprintf "connectors[%d]" refusal.cr_row
                 in
                 (Theme.bad ()) ^ "    " ^ name ^ "  unreadable: "
                 ^ Terminal_text.single_line refusal.cr_reason ^ Ansi.reset)
              snapshot.cs_refused
          in
          let selected_lines =
            match List.nth_opt connectors selected_index, snapshot.cs_refused with
            | None, [] ->
                [ Ansi.dim ^ "  (no channel transports registered)" ^ Ansi.reset ]
            | None, _ :: _ -> []
            | Some connector, _ ->
                let field label value =
                  field_rows ~width:inner ~label_cells:18 ~label_style:"" label value
                in
                let optional_row label value =
                  match value with
                  | None -> []
                  | Some value ->
                      field label (Terminal_text.single_line value)
                in
                let optional_bool_row label value =
                  optional_row label
                    (Option.map (fun present -> if present then "yes" else "no") value)
                in
                let optional_int_row label value =
                  optional_row label (Option.map string_of_int value)
                in
                let selected_binding =
                  List.nth_opt connector.cn_bindings state.connectors_binding_cursor
                in
                let keeper_is_present keeper_name =
                  List.exists
                    (fun (keeper : Tui_decode.keeper) ->
                       String.equal keeper.k_name keeper_name)
                    state.keepers
                in
                let binding_reference (binding : Masc.Tui_decode_connectors.connector_binding) =
                  Masc_tui_connector_unbind.channel_label
                    ~channel_id:binding.cb_channel_id
                    ~channel_name:binding.cb_channel_name
                in
                let store_state =
                  match connector.cn_binding_store_read_ok with
                  | Some true -> Some "readable"
                  | Some false -> Some "UNREADABLE"
                  | None -> None
                in
                let binding_lines =
                  List.mapi
                    (fun index (binding : Masc.Tui_decode_connectors.connector_binding) ->
                      let here = String.equal binding.cb_keeper_name k.k_name in
                      let selected = index = state.connectors_binding_cursor in
                      let missing_keeper =
                        not (keeper_is_present binding.cb_keeper_name)
                      in
                      let line =
                        Printf.sprintf "    %s %s → %s%s"
                          (if selected then Masc_tui_theme.Glyph.current_entry else " ")
                          (binding_reference binding)
                          (Terminal_text.single_line binding.cb_keeper_name)
                          (if here then "  (this Keeper)"
                           else if missing_keeper then
                             "  (MISSING KEEPER · e reassign · u u remove)"
                           else "")
                      in
                      if selected then Ansi.reverse ^ line ^ Ansi.reset
                      else if missing_keeper then
                        (Theme.bad ()) ^ line ^ Ansi.reset
                      else line)
                    connector.cn_bindings
                  |> function
                  | [] -> [ Ansi.dim ^ "    (no channel bindings)" ^ Ansi.reset ]
                  | lines -> lines
                in
                [ ""
                ; Ansi.bold ^ "  Selected · "
                  ^ Terminal_text.single_line connector.cn_display_name
                  ^ Ansi.reset
                ]
                @ detail_section_lines "1. 연결 상태 · 트리거 및 응답 정책 (Connection & Routing Policy)"
                @ field "Binding target"
                    (match selected_binding with
                     | None -> "(no binding selected)"
                     | Some binding -> binding_reference binding)
                  (* The badge is read from the status the row would print
                     beside it ([decode_connector_connection] takes status,
                     available and connected), so the word never differs from
                     the badge and the row said the same thing twice. *)
                @ field "Connection"
                    (connection_label connector)
                @ field "MASC API"
                    (Printf.sprintf "%s:%d"
                       Masc_network_defaults.masc_http_loopback_peer state.port)
                @ field "Channel type"
                    (Terminal_text.single_line_or
                       ~default:Masc_tui_theme.Glyph.no_value connector.cn_channel)
                @ optional_row "Runtime state"
                    (Masc_tui_connector_state.runtime_state_to_draw connector)
                @ optional_row "Status source" connector.cn_status_source
                @ optional_row "Remote endpoint" connector.cn_endpoint
                @ optional_row "Status file" connector.cn_status_path
                @ optional_row "Binding store" connector.cn_binding_store_path
                @ optional_row "Store state" store_state
                @ optional_row "Binding source" connector.cn_binding_source
                @ optional_row "Trigger policy" connector.cn_trigger_policy
                @ optional_row "Reply mode" connector.cn_reply_mode
                @ optional_row "Chat database" connector.cn_chat_db_path
                @ detail_section_lines "2. 봇 자격증명 · 프로세스 상태 (Bot Credentials & Process)"
                @ optional_row "Bot user" connector.cn_bot_user_name
                @ optional_row "Bot user id" connector.cn_bot_user_id
                @ optional_bool_row "Bot token ready" connector.cn_bot_token_present
                @ optional_bool_row "App token ready" connector.cn_app_token_present
                @ optional_bool_row "Gate healthy" connector.cn_gate_healthy
                @ optional_int_row "Server pid" connector.cn_pid
                @ optional_int_row "Guilds" connector.cn_guild_count
                @ detail_section_lines "3. 디렉토리 동기화 · 이름 매핑 파일 (Directory & Name Mapping)"
                @ optional_row "Directory state"
                    (Option.map
                       (function
                         | Masc.Tui_decode_connectors.Connector_directory_not_started ->
                           "not started"
                         | Connector_directory_refreshing -> "refreshing"
                         | Connector_directory_complete -> "complete"
                         | Connector_directory_partial -> "partial")
                       connector.cn_directory_state)
                @ optional_int_row "Servers learned"
                    connector.cn_directory_server_count
                @ optional_int_row "Channels learned"
                    connector.cn_directory_channel_count
                @ optional_int_row "People learned"
                    connector.cn_directory_person_count
                @ (match connector.cn_directory_authentication_failed with
                   | [] -> []
                   | values ->
                     field "Authentication"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_permission_denied with
                   | [] -> []
                   | values ->
                     field "Permission limits"
                         (String.concat ", "
                            (List.map Terminal_text.single_line values))
                     )
                @ (match connector.cn_directory_errors with
                   | [] -> []
                   | values ->
                     field "Directory errors"
                         (String.concat "; "
                            (List.map Terminal_text.single_line values))
                     )
                @ optional_row "Directory updated"
                    connector.cn_directory_updated_at
                @ optional_row "Workspace id" connector.cn_workspace_id
                @ optional_row "Server names" connector.cn_server_names_path
                @ optional_row "Channel names" connector.cn_channel_names_path
                @ optional_row "People names" connector.cn_people_names_path
                @ optional_row "Mapping scope" connector.cn_name_mapping_scope
                @ optional_row "Names read error" connector.cn_names_error
                @ optional_row "Updated" connector.cn_updated_at
                @ optional_row "Connection error" connector.cn_error
                @ optional_row "Store error" connector.cn_binding_store_error
                @ detail_section_lines "4. 채널 → 키퍼 바인딩 (Channel → Keeper Bindings)"
                @ binding_lines
                @ (match connector.cn_name_mappings with
                   | [] -> []
                   | mappings ->
                       [ ""; Ansi.bold ^ "  Known ID ↔ names" ^ Ansi.reset ]
                       @ List.concat_map
                           (fun (mapping : Masc.Tui_decode_connectors.connector_name_mapping) ->
                              Printf.sprintf "%-7s %s ↔ %s"
                                (match mapping.cnm_kind with
                                 | Masc.Tui_decode_connectors.Connector_channel_name -> "channel"
                                 | Connector_person_name -> "person"
                                 | Connector_server_name -> "server")
                                (Terminal_text.single_line mapping.cnm_id)
                                (Terminal_text.single_line mapping.cnm_name)
                              |> Message_layout.wrap_styled_words ~max_cells:(max 1 (inner - 4))
                              |> List.map (fun line -> "    " ^ line))
                           mappings)
                @ [ ""
                  ; Ansi.dim
                    ^ "  j/k transport · J/K binding · b bind · e reassign · u u remove"
                    ^ Ansi.reset
                  ; Ansi.dim
                    ^ "  These actions change channel routing, not the connector process."
                    ^ Ansi.reset
                  ; Ansi.dim ^ "  PgUp/PgDn scrolls this detail" ^ Ansi.reset
                  ; Ansi.dim ^ "  r reloads bindings and learned names" ^ Ansi.reset
                  ]
          in
          [ Printf.sprintf "  %d transports · %d available · actions target %s"
              snapshot.cs_total snapshot.cs_active
              (Terminal_text.single_line k.k_name)
          ]
          @ (match error with
             | None -> []
             | Some detail ->
                 [ (Theme.bad ()) ^ "  STALE · "
                   ^ Terminal_text.single_line detail ^ Ansi.reset
                 ])
          @ transport_rows @ refused_rows @ selected_lines
      in
      match connectors_read_notice state with
      | None -> rows
      | Some notice -> (Theme.info () ^ "  " ^ notice ^ Ansi.reset) :: rows
    in
    let automation_lines () =
      (* This tab reads the Keeper's own page from the server rather than
         filtering the fleet page: that page caps at its own limit with active
         rows first, so a Keeper whose schedules are terminal or further down
         was absent from it and the tab said none existed. The page it asks for
         can still truncate, which is why the absence reading stays. *)
      let pending = detail_read_started state ~tab:Detail_automation ~keeper:k.k_name in
      let observed = match state.keeper_schedules with
        | Some (name, _) -> String.equal name k.k_name
        | None -> false in
      let error = match state.keeper_schedules_error with
        | Some (name, detail) when String.equal name k.k_name -> Some detail
        | Some _ | None -> None in
      let error_lines = match error with
        | Some detail ->
            [ (Theme.bad ()) ^ "  " ^ (if observed then "STALE · " else "")
              ^ Terminal_text.single_line detail ^ Ansi.reset ]
        | None -> [] in
      let progress = match pending with
        | None -> []
        | Some started_ns ->
            [ loading_row ~started_ns (if observed
                then "refreshing this Keeper's schedules · last observation"
                else "loading this Keeper's schedules") ] in
      let snapshot_lines = match state.keeper_schedules with
      | Some (keeper_name, snapshot) when String.equal keeper_name k.k_name ->
          let rows = snapshot.scs_rows in
          if not (String.equal snapshot.scs_status "ok") then
            [ (Theme.bad ())
              ^ (match snapshot.scs_read_error with
                 | Some err -> "  " ^ Terminal_text.single_line err
                 | None -> "  (schedule store unreadable)")
              ^ Ansi.reset ]
          else if rows = [] then
            match
              Render_schedule.classify_keeper_schedule_absence
                ~truncated:snapshot.scs_truncated
                ~shown:(List.length snapshot.scs_rows)
                ~total:snapshot.scs_request_count
            with
            | Render_schedule.Store_has_none ->
                [ Ansi.dim ^ "  (no schedules for this Keeper)" ^ Ansi.reset ]
            | Render_schedule.Page_capped { shown; total } ->
                let of_total =
                  match total with
                  | Some total -> Printf.sprintf " -- %d of %d requests" shown total
                  | None -> ""
                in
                [ Ansi.dim
                  ^ Printf.sprintf
                      "  (none on the page the server sent%s; open Schedules \
                       for the full list)"
                      of_total
                  ^ Ansi.reset
                ]
          else
            (* What the store holds, above the rows it sent. The rows come
               live-first, and a Keeper whose store has run for weeks answers
               with a page of closed work behind the one live row -- without
               this line a reader learns that only by scrolling to the end.
               The counts describe the whole store, so they stay right when
               the page below them is capped. *)
            (match snapshot.scs_counts with
             | None -> []
             | Some counts ->
                 [ Ansi.dim ^ "  "
                   ^ Masc_tui_types.schedule_counts_line counts
                   ^ Ansi.reset
                 ; ""
                 ])
            @ (let outcome_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line (schedule_outcome_word row))
                   rows
               in
               let by_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line row.sch_requested_by)
                   rows
               in
               let recurrence_words =
                 List.map
                   (fun (row : schedule_row) ->
                      Terminal_text.single_line row.sch_recurrence_summary)
                   rows
               in
               (* Every line carries a two-cell lead before the table, so the
                  table is fitted to what the lead leaves -- the same reserve
                  the Schedules list makes, without which the frame cuts the
                  last column's tail on every row. *)
               let table_inner = max 1 (inner - 2) in
               let layout =
                 Render_schedule.kauto_layout ~inner_width:table_inner
                   ~status_width:schedule_status_word_cells
                   ~clock_width:schedule_requested_clock_cells
                   ~outcome_width:
                     (Render_schedule.schedule_delivery_width outcome_words)
                   ~recurrence_width:
                     (Render_schedule.kauto_recurrence_width recurrence_words)
                   ~by_width:(Render_schedule.kauto_by_width by_words)
               in
               let header = Render_schedule.kauto_header_row ~layout in
               (* The rule under the names runs the header's own width, so a
                  pane narrower than the table does not draw a rule longer
                  than the rows under it. The closed rule below ends at the
                  same cell, so the two rules read as one margin. *)
               let rule_cells =
                 min table_inner (Message_layout.display_width header) in
               let occurrence_clock = function
                 | Some iso -> Terminal_text.short_timestamp iso
                 | None -> Masc_tui_theme.Glyph.no_value
               in
               let row_line (row : schedule_row) =
                 (* The mark and the state word wear one colour, the state's
                    own; the outcome wears the outcome's, so a failed wake
                    reads red beside a state still reading live. *)
                 let status_style = schedule_status_color row.sch_status in
                 (* A held occurrence has no wake of its own, and the wake and
                    ledger fields on the row still describe the occurrence
                    before it (#38205): while the hold holds, the three
                    occurrence cells draw nothing rather than the previous
                    occurrence's clocks beside a state that reads due-now.
                    Why it holds is the Schedules list's own reading -- its
                    row carries the hold tag -- which this tab's capped-page
                    line already points the reader to. *)
                 let held = Option.is_some row.sch_runner_hold in
                 let occurrence_clock value =
                   if held then Masc_tui_theme.Glyph.no_value
                   else occurrence_clock value
                 in
                 let outcome =
                   if held then Masc_tui_theme.Glyph.no_value
                   else Terminal_text.single_line (schedule_outcome_word row)
                 in
                 "  "
                 ^ Render_schedule.kauto_row ~layout
                     ~styles:
                       ({ kstyle_mark = status_style
                        ; kstyle_status = status_style
                        ; kstyle_outcome = semantic_status_color outcome
                        ; kstyle_recurrence = Ansi.dim
                        ; kstyle_by = Theme.recede ()
                        } : Render_schedule.kauto_row_styles)
                     { Render_schedule.krow_mark =
                         Render_schedule.kauto_status_mark row.sch_status
                     ; krow_status = Terminal_text.single_line row.sch_status
                     ; krow_triggered =
                         occurrence_clock row.sch_last_wake_started_at_iso
                     ; krow_outcome = outcome
                     ; krow_received =
                         occurrence_clock row.sch_stimulus_recorded_at_iso
                     ; krow_recurrence =
                         Terminal_text.single_line row.sch_recurrence_summary
                     ; krow_by = Terminal_text.single_line row.sch_requested_by
                     ; krow_requested =
                         Terminal_text.short_timestamp row.sch_requested_at_iso
                     ; krow_what =
                         Terminal_text.single_line
                           (Option.value ~default:row.sch_schedule_id
                              row.sch_payload_summary)
                     }
               in
               (* The page's live rows, then its closed ones under a labelled
                  rule. The server sends live-first; the partition keeps each
                  group's order and makes the grouping this pane's own rather
                  than the server's sort happening to be right. *)
               let live, closed =
                 List.partition
                   (fun (row : schedule_row) ->
                      not (schedule_status_is_terminal row.sch_status))
                   rows
               in
               let closed_rule =
                 if closed = [] || live = [] then []
                 else
                   let words =
                     List.map
                       (fun (row : schedule_row) -> row.sch_status)
                       closed
                   in
                   let rec first_seen acc = function
                     | [] -> List.rev acc
                     | word :: rest ->
                         if List.mem word acc then first_seen acc rest
                         else first_seen (word :: acc) rest
                   in
                   let label =
                     Render_schedule.kauto_group_label ~title:"closed"
                       (List.map
                          (fun word ->
                             Printf.sprintf "%d %s"
                               (List.length
                                  (List.filter (String.equal word) words))
                               (Terminal_text.single_line word))
                          (first_seen [] words))
                   in
                   let lead = "  \xe2\x94\x80\xe2\x94\x80 " ^ label ^ " " in
                   let rest_cells =
                     max 0
                       (min (2 + rule_cells) inner
                          - Message_layout.display_width lead)
                   in
                   [ Theme.recede () ^ lead ^ draw_hline rest_cells
                     ^ Ansi.reset
                   ]
               in
               [ Theme.recede () ^ "  " ^ header ^ Ansi.reset
               ; Theme.recede () ^ "  " ^ draw_hline rule_cells ^ Ansi.reset
               ]
               @ List.map row_line live
               @ closed_rule
               @ List.map row_line closed)
      | Some _ | None ->
          (match error, pending with
           | None, None -> [ Ansi.dim ^ "  Schedules not observed" ^ Ansi.reset ]
           | Some _, (Some _ | None) | None, Some _ -> [])
      in
      error_lines @ progress @ snapshot_lines
    in
    let run_lines () =
      let failure detail =
        (Theme.bad ()) ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset
      in
      let listing runs =
        "  Fusion runs · j/k:select · Enter:open · same IDs as Fusion" ::
        (if runs = [] then ["  No retained Fusion runs for this Keeper"]
         else List.mapi (fun index (run : Masc.Tui_decode_fusion.fusion_run) ->
           (* The clock the Fusion list and the run detail already draw for
              this field, rather than a second copy of its format: three
              lists show a run's start, and a copy is one that stops
              following when the other two change. *)
           Printf.sprintf "%s %s · %s · %s · %s"
             (if Option.fold ~none:false ~some:(fun (cursor, _) -> index = cursor)
                   (Masc_tui_fusion_model.selected_keeper_run state) then ">" else " ")
             (fusion_run_clock run)
             (Masc.Tui_decode_fusion.fusion_run_status_to_string run.fur_status)
             (Terminal_text.single_line run.fur_preset)
             (Terminal_text.single_line run.fur_run_id)) runs)
      in
      match Masc_tui_fusion_model.keeper_runs_view state with
      | Masc_tui_fetched.Absent -> [ Ansi.dim ^ page_unread_note ^ Ansi.reset ]
      | Masc_tui_fetched.Loading -> [ loading_row "loading Fusion runs" ]
      | Masc_tui_fetched.Failed detail -> [ failure detail ]
      (* Rows already held stay on a failed refresh, as they do on the Fusion
         surface, with the failure above them so they read as stale. *)
      | Masc_tui_fetched.Stale (runs, detail) -> failure detail :: listing runs
      | Masc_tui_fetched.Ready runs -> listing runs
    in
    let terminal = lazy (terminal_drawing state ~width:inner) in
    let all_lines =
      match state.detail_tab with
      | Detail_info -> info_lines ()
      | Detail_items -> item_lines ()
      | Detail_sandbox ->
          let width = max 24 (framed_inner_width cols - 4) in
          let status =
            stamped_or
              (Option.map
                 (fun (stamp, reading) ->
                   stamp, Masc_tui_keeper_sandbox.view_lines ~width reading)
                 state.keeper_sandbox_view)
              state.keeper_sandbox_view_error
          in
          let logs =
            match state.keeper_sandbox_logs_inflight with
            | Some request when String.equal request.slr_keeper k.k_name ->
              [ loading_row ~started_ns:request.slr_started_ns
                  "loading actual container logs" ]
            | Some _ | None ->
              match state.keeper_sandbox_logs_error with
              | Some (stamp, detail) when String.equal stamp k.k_name ->
                [ (Theme.bad ()) ^ "  Container logs unavailable: "
                  ^ Terminal_text.single_line detail ^ Ansi.reset
                ]
              | Some _ | None ->
                (match state.keeper_sandbox_logs with
                 | Some (stamp, logs) when String.equal stamp k.k_name ->
                   Masc_tui_keeper_sandbox.logs_view_lines ~width logs
                   |> List.map (fun line -> "  " ^ line)
                 | Some _ | None -> [])
          in
          status @ logs
      | Detail_instructions ->
          stamped_or state.keeper_config_view state.keeper_config_view_error
      | Detail_secrets ->
          let observed = Option.is_some state.lanes in
          let failure = match state.lanes_error with
            | None -> []
            | Some detail ->
                [ (Theme.bad ()) ^ "  " ^ (if observed then "STALE · " else "")
                  ^ Terminal_text.single_line detail ^ Ansi.reset ] in
          let progress = if state.keeper_lanes_inflight then
              [ loading_row (if observed
                  then "refreshing execution snapshot · last observation"
                  else "reading execution snapshot") ]
            else [] in
          let lines = match secret_lines state k with
            | Some lines -> lines
            | None ->
                (match state.lanes, state.lanes_error, state.keeper_lanes_inflight with
                 | None, None, false ->
                     [ Ansi.dim ^ "  Execution snapshot not observed" ^ Ansi.reset ]
                 | None, (Some _ | None), true | None, Some _, false -> []
                 | Some _, (Some _ | None), (true | false) ->
                     [ Ansi.dim ^ "  (no projection reported for this Keeper)" ^ Ansi.reset ]) in
          failure @ progress @ lines
      | Detail_github ->
          let base =
            stamped_or state.github_identity_view
              state.github_identity_view_error
          in
          Masc_tui_render_github.lines
            { token_input = state.github_token_input
            ; save_status = state.github_token_save_status
            ; login_scopes = state.github_login_scopes
            }
            ~base
      | Detail_identity ->
          stamped_or
            (Option.map
               (fun (stamp, providers) ->
                 ( stamp
                 , Masc_tui_render_identity.lines ~cols
                     { keeper_name = k.k_name
                     ; providers
                     ; filter = state.identity_filter
                     ; cursor = state.identity_cursor
                     ; logins = state.identity_logins
                     ; attempt_error = state.identity_attempt_error
                     ; app_form = state.identity_app_form
                     } ))
               state.identity_view)
            state.identity_view_error
      | Detail_channels ->
          channel_lines ()
      | Detail_automation -> automation_lines ()
      | Detail_runs -> run_lines ()
      | Detail_terminal -> (Lazy.force terminal).terminal_rows
    in
    let total_lines = List.length all_lines in

    (* Top border *)
    box_top buf cols;

    (* Title, with the tab walk on the same row so the chrome height the
       scroll math counts does not move. *)
    (* The tab you are on carries the mark the surface strip puts on the
       surface you are on. Bold and underline said it alone before, so the
       answer was gone from a monochrome terminal, from one that drops
       underline, and from every text capture -- a frame dump, a screenshot
       pasted into an issue, the keyboard-input fixtures. Info's own body
       opens with a section called "Identity", which is also the name of
       another tab, so a reader with no mark had a wrong guess waiting.

       Drawn through [tab_strip] with the row's width: ten tabs are wider
       than the row beside the roster pane, and cut from the right the mark
       on Runs was the part that went. *)
    let before =
      Printf.sprintf " Keepers \xe2\x96\xb8 %s%s%s%s" Ansi.bold
        (Terminal_text.single_line k.k_name)
        Ansi.reset tab_strip_gap
    in
    let tabs =
      tab_strip ~width:(tab_strip_width ~cols ~before ~after:"")
        ~press:(fun tab text -> pressable (Press_keeper_tab tab) text)
        (List.map
           (fun tab ->
             ( Masc_tui_types.keeper_detail_tab_label tab
             , tab = state.detail_tab
             , tab ))
           Masc_tui_types.keeper_detail_tabs)
    in
    let title = before ^ tabs in
    box_line buf cols title;

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling. Chrome is 4 rows (top, title, divider,
       bottom); the indicator, when the content overflows, spends one
       content row rather than growing the pane, so the pane's height is
       rows - 1 in both cases and the split's two bottoms stay level. *)
    let terminal_tab = state.detail_tab = Detail_terminal in
    let content_height =
      (* The Terminal's status row is there whether or not the output
         overflows, so the output never moves when it starts to. *)
      if total_lines > base_height || terminal_tab then max 0 (base_height - 1)
      else base_height
    in
    let visible_lines = min content_height total_lines in
    (* How far back from the bottom this window can go, and how far it is. *)
    let terminal_back =
      min (Masc_tui_execute_terminal.back (Masc_tui_types.keeper_terminal_hold state))
        (max 0 (total_lines - content_height))
    in
    let scroll =
      if terminal_tab then max 0 (total_lines - content_height) - terminal_back
      else
        Render_schedule.normalize_keeper_detail_scroll ~line_count:total_lines
          ~content_height state.detail_scroll
        |> fun scroll ->
          if state.detail_tab = Detail_runs then
            Option.fold ~none:scroll
              ~some:(fun (cursor, _) ->
                Masc_tui_scroll.ensure_visible ~cursor:(cursor + 1)
                  ~height:(max 1 content_height) scroll)
              (Masc_tui_fusion_model.selected_keeper_run state)
          else scroll
    in
    let all_lines_window = Rows.of_list ~first:scroll ~height:visible_lines all_lines in

    (* Real pixels go over the blank cells the band left, from the first
       content row: the lines this pane drew above it, under whatever the
       caller drew above the pane. *)
    Option.iter
      (fun band ->
        Masc_tui_keeper_portrait.placement band ~scroll ~visible_rows:visible_lines
          ~origin:
            ( origin_row + lines_ended_since buf ~start:pane_start
            , origin_col + framed_content_column )
        |> Option.iter Masc_tui_portrait_view.request)
      portrait;

    for i = 0 to visible_lines - 1 do
      let idx = i + scroll in
      if idx < total_lines then
        box_line buf cols (Option.value (Rows.at all_lines_window idx) ~default:"")
      else
        box_empty buf cols
    done;

    (* Fill remaining space *)
    for _ = visible_lines to content_height - 1 do
      box_empty buf cols
    done;

    (* Scroll indicator; on the Terminal tab the row says what the view is
       doing instead. *)
    if terminal_tab then box_line buf cols (Lazy.force terminal).terminal_status
    else
      Option.iter
        (fun row ->
          box_line buf cols ((Theme.recede ()) ^ row ^ Ansi.reset))
        (Masc_tui_scroll.position_row ~scroll ~height:content_height total_lines);

    (* Bottom border *)
    box_bottom buf cols;
    if terminal_tab then Keeper_terminal_scroll terminal_back else Keeper_detail scroll


let render_keeper_detail (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  if state.keeper_cursor >= List.length state.keepers then begin
    surface_chrome ~overflow:Fits state ~terminal_rows ~cols
      ~surface_key:"keeper-detail"
      ~title:
        (Printf.sprintf "%s  %s"
           (screen_title " Keepers \xe2\x96\xb8 detail")
           (connection_badge state))
      ~hints:(Masc_tui_keys.footer_hints state.view)
      ~body:(fun ~budget:_ c ->
        c.push_styled ~style:(Theme.recede ()) "  No keeper selected.")
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    (* The row the Keepers list draws, through the same [footer_line]: the
       armed or running action as a status item, the keys as items the fitter
       can drop whole, [Esc] and [q] kept whatever else goes. It was cut with
       [fit_width] instead, which keeps the front and loses the back -- where
       [Left / Esc] and [q] sit -- so at 80 columns the row ended "t:c…" and
       named no way out. [key:label] for the roster pane's key too. *)
    (* The open tab's own keys lead, and a Keeper control on a key the tab
       answers itself leaves the row. They were a strip at the end of the
       title row, which the frame cut at 120 columns ("o:act…", "L:log…"),
       while this row said "s:shutdown" and "o:container logs" on the
       Sandbox tab, where [s] sets the remote_ssh backend and [o] reads the
       container logs the strip called "actual logs". *)
    let hints =
      Masc_tui_keys.keeper_detail_tab_hint state.detail_tab
      ^ "  "
      ^ keeper_control_hints
          ~taken:(Masc_tui_keys.keeper_detail_tab_taken_keys state.detail_tab)
          state (Some (keeper_reading state k))
    in
    let hints =
      if keeper_roster_pane_shown state ~cols then "h/l:pane  " ^ hints
      else hints
    in
    let footer =
      footer_line state ~status:(keeper_action_status state) ~max_cells:cols ~hints
    in
    if not (keeper_roster_pane_shown state ~cols) then begin
      let scroll =
        keeper_detail_pane state k ~framed:false ~rows ~cols
          ~origin:(strip_rows, 0) buf
      in
      Buffer.add_string buf footer;
      finish_surface state ~clamped:scroll
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
    else begin
      (* Wide terminals keep the roster in sight beside the detail. Both
         panes draw the same number of rows, so the zip below is a plain
         row-by-row join. *)
      let left_cols = keeper_roster_pane_cols in
      let right_cols = cols - left_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      keeper_roster_pane
        ~focused:(state.keeper_detail_focus = Left_pane)
        state ~rows ~cols:left_cols left_buf;
      let scroll =
        keeper_detail_pane state k ~framed:true ~rows ~cols:right_cols
          ~origin:(strip_rows, left_cols) right_buf
      in
      write_two_panes buf ~left_cols:left_cols ~left:left_buf
        ~right:right_buf;
      Buffer.add_string buf footer;
      finish_surface state ~clamped:scroll
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in

  if state.keeper_cursor >= List.length state.keepers then begin
    surface_chrome ~overflow:Fits state ~terminal_rows ~cols
      ~surface_key:"keeper-logs"
      ~title:
        (Printf.sprintf "%s  %s"
           (screen_title " Keepers \xe2\x96\xb8 logs")
           (connection_badge state))
      ~hints:(Masc_tui_keys.footer_hints state.view)
      ~body:(fun ~budget:_ c ->
        c.push_styled ~style:(Theme.recede ()) "  No keeper selected.")
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let log_snapshot = keeper_log_snapshot state in
    let total_entries = List.length log_snapshot.entries in
    let reading_label = match keeper_logs_view state with
      | Masc_tui_fetched.Absent -> "not read"
      | Loading -> "reading metrics"
      | Failed _ -> "unavailable"
      | Ready _ | Stale _ ->
          Masc_tui_message_layout.count_noun ~plural:"entries" total_entries "entry" in

    (* Header *)
    let header =
      Printf.sprintf "%s  (%s)  %s"
        (screen_title
           (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 logs"
              (Terminal_text.single_line k.k_name)))
        reading_label
        (connection_badge state)
    in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    box_line_styled buf cols ~style:(Theme.recede ())
      "  TIME  KIND  LATENCY · full facts below";
    box_divider buf cols;

    let log_rows = Masc_tui_types.keeper_log_rows state ~cols in
    let row_count = List.length log_rows in
    let content_height =
      Metrics_tail.content_height ~terminal_rows:rows ~error:None
    in
    let scroll =
      Metrics_tail.normalize_scroll ~entry_count:row_count ~content_height
        (if state.log_wrap_cols = Some cols then state.log_scroll else 0)
    in
    let visible = Rows.of_list ~first:scroll ~height:content_height log_rows in
    for index = 0 to content_height - 1 do
      if row_count = 0 && index = 0 then
        box_line_styled buf cols ~style:(Theme.recede ())
          ("  " ^ Metrics_tail.empty_message log_snapshot.error)
      else
        match Rows.at visible (scroll + index) with
        | Some (diagnostic, line) ->
            let style = keeper_log_style diagnostic in
            box_line_styled buf cols ~style line
        | None -> box_empty buf cols
    done;
    if row_count > content_height then
      box_line_styled buf cols ~style:(Theme.recede ())
        (Printf.sprintf "  [newest rows %d-%d of %d]" (scroll + 1)
           (min row_count (scroll + content_height)) row_count)
    else box_empty buf cols;

    box_bottom buf cols;

    Buffer.add_string buf
      (footer_line state ~max_cells:cols
         ~hints:(Masc_tui_keys.footer_hints state.view));

    finish_surface state ~clamped:(Keeper_logs_scroll { scroll; cols })
      ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end
