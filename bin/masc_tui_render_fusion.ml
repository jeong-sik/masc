(** Fusion frames, detail documents and tool/evidence readings. *)

open Masc_tui_types
open Masc.Tui_decode_fusion
open Masc_tui_ansi
open Masc_tui_render_prim

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection
module Render_schedule = Masc_tui_render_schedule
module Link = Masc_tui_link
module Chart = Masc_tui_chart

(* What became of the selected run, in one row under the list. It opened
   with "Flow: Question → Panel → Judge → Evidence" on every run: the four
   stops are the same for every run and say nothing about this one, the
   detail's Pipeline row draws them with the run's state and its own arrow,
   and beside the roster pane they pushed the part that is this run's --
   its progress, its failure, or that its evidence is retained -- off the
   row. Enter is the footer's to name. *)
let fusion_run_summary run =
  match run.fur_status with
  | Fusion_running ->
      ((Masc_tui_theme.tone Masc_tui_theme.Accent), fusion_run_progress_text run.fur_stage)
  | Fusion_completed ->
      (match run.fur_decision, run.fur_summary with
       | Some decision, Some summary ->
           ( (Theme.ok ())
           , Terminal_text.single_line decision ^ " \xc2\xb7 "
             ^ Terminal_text.single_line summary )
       | (Some _ | None), (Some _ | None) -> ((Theme.ok ()), "evidence retained"))
  | Fusion_failed failure ->
      ( (Theme.bad ())
      , Printf.sprintf "failed [%s]: %s"
          (Terminal_text.single_line failure.frs_failure_code)
          (Terminal_text.single_line failure.frs_error) )

let fusion_replay_warning = function
  | Masc.Tui_decode_fusion.Fusion_not_replayed | Masc.Tui_decode_fusion.Fusion_log_absent -> None
  | Masc.Tui_decode_fusion.Fusion_replayed { malformed_lines = 0; dropped_running = 0;
                                incomplete = false } -> None
  | Masc.Tui_decode_fusion.Fusion_replayed { malformed_lines; dropped_running; incomplete } ->
      Some (Printf.sprintf
        "Registry startup read: %d invalid rows; %d registrations omitted%s"
        malformed_lines dropped_running (if incomplete then "; read incomplete" else ""))

let render_fusion_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let reading = Masc_tui_fusion_model.fusion_runs_view state in
  let snapshot = Masc_tui_fusion_model.fusion_snapshot state in
  let runs =
    match snapshot with
    | None -> []
    | Some snapshot -> snapshot.fus_runs
  in
  let entries = Masc_tui_fusion_model.fusion_list_entries state in
  let shown = List.length entries in
  let history_count = shown - List.length runs in
  let replay_warning = Option.bind snapshot
      (fun snapshot -> fusion_replay_warning snapshot.fus_replay) in
  (* The list's own failure first: with rows held it marks them stale, with
     none it is the page. A launch form that could not open says so on the
     same row when the list itself read fine. *)
  let failure =
    match reading with
    | Masc_tui_fetched.Stale (_, detail) | Masc_tui_fetched.Failed detail -> Some detail
    | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading ->
        state.fusion_launch_error
  in
  let now_epoch = Unix.gettimeofday () in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match snapshot with
    | None ->
        let reading_note =
          match failure with
          | None -> title_missing_reading ~error:None
          | Some _ -> ""
        in
        Printf.sprintf "%s  %s  %s  %s"
          (screen_title fusion_title) reading_note timestamp
          (connection_badge state)
    | Some _ ->
        let completed_count =
          List.fold_left
            (fun acc (r : Masc.Tui_decode_fusion.fusion_run) ->
               if r.fur_status = Masc.Tui_decode_fusion.Fusion_completed then acc + 1 else acc)
            0 runs
        in
        let failed_count =
          List.fold_left
            (fun acc (r : Masc.Tui_decode_fusion.fusion_run) ->
               match r.fur_status with Masc.Tui_decode_fusion.Fusion_failed _ -> acc + 1 | _ -> acc)
            0 runs
        in
        let running_count = Stdlib.max 0 (List.length runs - completed_count - failed_count) in
        (* The running count is a state, not a second noun for the runs: with
           nothing running the title read "2 runs \xc2\xb7 2 done \xc2\xb7 0 run",
           where the last pair says nothing and reads as a third total. It is
           left out when it is zero, the way the failures beside it already
           are. *)
        let stats_note =
          Printf.sprintf " (%s · %s%d done%s%s%s)"
            (Masc_tui_message_layout.count_noun (List.length runs) "run")
            (Theme.ok ()) completed_count Ansi.reset
            (if running_count > 0 then
               Printf.sprintf " · %s%d running%s" (Theme.info ()) running_count
                 Ansi.reset
             else "")
            (if failed_count > 0 then Printf.sprintf " · %s%d fail%s" (Theme.bad ()) failed_count Ansi.reset else "")
        in
        Printf.sprintf "%s%s  %s  %s"
          (screen_title fusion_title)
          (stats_note ^ (if history_count = 0 then "" else
             Printf.sprintf " · %d Board evidence" history_count)) timestamp
          (connection_badge state)
  in
  (* Measured from the rows, the way the Approvals table measures its own
     name column. Eighteen of twenty-eight keepers were cut at sixteen while
     RUN, a [kmsg-] and thirty-two hex digits nobody reads off a screen, sat
     whole beside them -- and the detail pane already carries that id in full
     under Link. RUN is last, so what it loses is the end of an identifier the
     pane below repeats. *)
  let keeper_width =
    List.fold_left
      (fun widest (run : Masc.Tui_decode_fusion.fusion_run) ->
        max widest
          (Message_layout.display_width
             (Terminal_text.single_line run.fur_keeper)))
      16 runs
    |> min 26
  in
  (* The run id takes what the named columns leave, once the keeper column has
     been sized to the names it actually holds. *)
  let columns =
    Render_schedule.allocate_fusion_columns ~keeper_width
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Render_schedule.fusion_header_row columns);
  box_divider buf cols;
  (match failure with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  Option.iter (fun warning ->
      box_line_styled buf cols ~style:(Theme.warn ()) ("  " ^ warning);
      box_divider buf cols) replay_warning;
  let chrome_rows = listing_chrome ~error:failure
      + (if Option.is_some replay_warning then 2 else 0) in
  (* The selected run's lifecycle is a reading, not footer help, and it is
     asked for its own height the way the Memory block under the roster is
     (#38432): the clauses are packed into rows here, before the list is given
     its height. [listing_note_rows] hands it only the rows the list leaves
     blank, so every run still says where it is in the four-stage flow and no
     entry loses its row. *)
  let summary_indent = "  " in
  let summary_clauses =
    match List.nth_opt entries state.fusion_cursor with
    | None -> None
    | Some (Masc.Tui_decode_fusion.Fusion_historical_evidence _) ->
        Some
          ( Theme.warn ()
          , [ "Historical Board evidence; run lifecycle unavailable"
            ; "Enter:read original result" ] )
    | Some (Masc.Tui_decode_fusion.Fusion_retained_run selected) ->
        let style, summary = fusion_run_summary selected in
        Some (style, [ fusion_run_duration ~now:now_epoch selected; summary ])
  in
  let packed_summary =
    match summary_clauses with
    | None -> []
    | Some (_, clauses) ->
        Message_layout.pack_clauses
          ~max_cells:
            (max 1
               (framed_inner_width cols
                - Message_layout.display_width summary_indent))
          clauses
  in
  let summary_rows =
    listing_note_rows ~body_rows:(rows - chrome_rows) ~entries:shown
      ~wanted:(List.length packed_summary)
  in
  let content_height = max 1 (rows - chrome_rows - summary_rows) in
  let scroll =
    if state.fusion_cursor >= content_height then
      state.fusion_cursor - content_height + 1
    else 0
  in
  let entries_window = Rows.of_list ~first:scroll ~height:content_height entries in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot ~error:failure
      with
      | Page_failed -> page_failed_note
      | Page_unread -> page_unread_note
      | Page_empty ->
          if Option.is_some replay_warning then "  No readable retained runs; see startup read warning above"
          else "  (no retained Fusion runs)"
    in
    box_line_styled buf cols ~style:(Theme.recede ()) empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      let row_index = index + scroll in
      match Rows.at entries_window row_index with
      | None -> box_empty buf cols
      | Some (Masc.Tui_decode_fusion.Fusion_historical_evidence evidence) ->
          let line = "Board evidence · " ^ Terminal_text.single_line evidence.fhe_title
              ^ " · " ^ Link.reference Board_post evidence.fhe_post_id in
          let marker = if row_index = state.fusion_cursor then
              Ansi.reverse ^ ">" ^ Ansi.reset else " " in
          box_line buf cols (marker ^ " " ^ line)
      | Some (Masc.Tui_decode_fusion.Fusion_retained_run run) ->
          let state_text =
            fusion_run_state_text ~status:run.fur_status ~stage:run.fur_stage
          in
          let line =
            Render_schedule.fusion_row columns
              ~state_style:(fusion_run_status_color run.fur_status)
              { Render_schedule.frow_time = fusion_run_clock run
              ; frow_age = fusion_run_age ~now:now_epoch run
              ; frow_state = state_text
              ; frow_keeper = Terminal_text.single_line run.fur_keeper
              ; frow_preset = Terminal_text.single_line run.fur_preset
              ; frow_run = Terminal_text.single_line run.fur_run_id
              }
          in
          if row_index = state.fusion_cursor then
            box_line buf cols (Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line)
          else box_line buf cols ("  " ^ line)
    done;
  (match summary_clauses with
   | None -> for _ = 1 to summary_rows do box_empty buf cols done
   | Some (style, clauses) ->
       (* The packed rows are drawn only when the frame had room for all of
          them. A reading that does not fit is drawn as the one joined row it
          was, where the frame's own cut mark still says it was cut; stopping
          after the rows that fit would end on a row that reads as whole
          (#38432 falls back to the same line). *)
       let drawn =
         if List.length packed_summary <= summary_rows then packed_summary
         else [ String.concat Message_layout.clause_separator clauses ]
       in
       List.iter
         (fun row -> box_line_styled buf cols ~style (summary_indent ^ row))
         drawn;
       for _ = List.length drawn + 1 to summary_rows do box_empty buf cols done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints ~detail_open:false Fusion));
  finish_surface state ~surface_key:"fusion-list" ~rows:terminal_rows ~cols buf

(* The panel as marks, one per model, filled where the model answered.

   Which preset ran and whether the panel that fed the judge was whole is the
   first thing an operator reads off a run, and the pane said it in a sentence
   of counts -- "judge-of-judges  first x3  meta x1" -- with the failures
   counted somewhere else entirely. A model that did not answer is a hole in
   the row here, so a thin panel is seen before it is read.

   Past the cap the row would stop being countable at a glance, so it becomes
   the two numbers it was drawn from. *)
let fusion_panel_dots ~answered ~failed =
  let cap = 24 in
  let filled = "\xe2\x97\x8f" in
  let hollow = "\xe2\x97\x8b" in
  let run style mark n =
    if n <= 0 then ""
    else style ^ String.concat "" (List.init n (fun _ -> mark)) ^ Ansi.reset
  in
  match answered + failed with
  | 0 -> ""
  | total when total > cap ->
    Printf.sprintf "%s%d\xc3\x97%s%s  %s%d\xc3\x97%s%s"
      (Theme.ok ()) answered filled Ansi.reset
      (Theme.bad ()) failed hollow Ansi.reset
  | _ -> run (Theme.ok ()) filled answered ^ run (Theme.bad ()) hollow failed
;;

let fusion_wrapped_block ~width ~indent text =
  let body_width = max 1 (width - Message_layout.display_width indent) in
  String.split_on_char '\n' text
  |> List.concat_map (fun raw ->
         let safe = Terminal_text.single_line raw in
         if String.equal safe "" then [ indent ^ "(empty)" ]
         else
           Message_layout.wrap_words ~max_cells:body_width safe
           |> List.map (fun line -> indent ^ line))
  |> List.map (fun line -> Ansi.reset, line)

let fusion_markdown_block ~width ~indent text =
  let body_width = max 1 (width - Message_layout.display_width indent) in
  if String.equal (String.trim text) "" then [ Ansi.dim, indent ^ "(empty)" ]
  else
    document_markdown ~width:body_width text
    |> List.map (fun line -> Ansi.reset, indent ^ line)

let fusion_labeled_markdown ~width ~label text =
  (Ansi.bold, "  " ^ label)
  :: fusion_markdown_block ~width ~indent:"    " text

let fusion_tool_actor_text actor =
  match actor.fta_phase with
  | Fusion_tool_panel -> "panel/" ^ Terminal_text.single_line actor.fta_identity
  | Fusion_tool_judge role ->
      Printf.sprintf "judge/%s/%s" (fusion_judge_role_label role)
        (Terminal_text.single_line actor.fta_identity)

let fusion_tool_agent_suffix actor agent_name =
  if String.equal actor.fta_identity agent_name
  then ""
  else "  agent=" ^ Terminal_text.single_line agent_name

let fusion_tool_preview_lines ~width ~label preview =
  let size =
    if preview.ftp_truncated
    then Printf.sprintf "%d bytes; preview truncated" preview.ftp_bytes
    else Printf.sprintf "%d bytes" preview.ftp_bytes
  in
  let payload_text =
    if preview.ftp_truncated
    then preview.ftp_text
    else
      try
        preview.ftp_text
        |> Yojson.Safe.from_string
        |> Yojson.Safe.pretty_to_string
      with
      | Yojson.Json_error _ -> preview.ftp_text
  in
  let trimmed = String.trim payload_text in
  let body =
    if String.starts_with ~prefix:"{" trimmed
       || String.starts_with ~prefix:"[" trimmed
    then "```json\n" ^ payload_text ^ "\n```"
    else payload_text
  in
  [ Ansi.dim, Printf.sprintf "    %s (%s)" label size ]
  @ fusion_markdown_block ~width ~indent:"      " body

let fusion_tool_event_lines ~width = function
  | Fusion_tool_called event ->
      [ ( (Masc_tui_theme.tone Masc_tui_theme.Accent)
        , Printf.sprintf "  [called] %s%s  %s  turn %d/%d  id=%s"
            (fusion_tool_actor_text event.fte_actor)
            (fusion_tool_agent_suffix event.fte_actor event.fte_agent_name)
            (Terminal_text.single_line event.fte_tool_name)
            event.fte_turn event.fte_planned_index
            (Terminal_text.single_line event.fte_tool_use_id) )
      ]
      @ fusion_tool_preview_lines ~width ~label:"Input" event.fte_input
  | Fusion_tool_completed event ->
      let status, style, output, failure_suffix =
        match event.fte_completion with
        | Fusion_tool_succeeded output -> ("succeeded", Theme.ok (), output, "")
        | Fusion_tool_failed { ftc_output; ftc_recoverable; ftc_error_class }
          ->
          ( "failed"
          , Theme.bad ()
          , ftc_output
          , Printf.sprintf "  recoverable=%b%s" ftc_recoverable
              (match ftc_error_class with
               | Some class_ -> " class=" ^ Terminal_text.single_line class_
               | None -> " class=unavailable") )
      in
      [ ( style
        , Printf.sprintf "  [%s] %s%s  %s  turn %d/%d  id=%s%s" status
            (fusion_tool_actor_text event.fte_actor)
            (fusion_tool_agent_suffix event.fte_actor event.fte_agent_name)
            (Terminal_text.single_line event.fte_tool_name)
            event.fte_turn event.fte_planned_index
            (Terminal_text.single_line event.fte_tool_use_id)
            failure_suffix )
      ]
      @ fusion_tool_preview_lines ~width ~label:"Output" output

let fusion_tool_trace_lines ~width (trace : Masc.Tui_decode_fusion.fusion_tool_trace) =
      let coverage =
        if trace.ftt_complete
        then
          ( Theme.ok ()
          , Printf.sprintf "  Coverage: complete across %d AGENT_CORE actor(s)"
              (List.length trace.ftt_observed_actors) )
        else
          ( Theme.warn ()
          , Printf.sprintf
              "  Coverage: partial across %d actor(s) (%d dropped event(s), %d gap(s))"
              (List.length trace.ftt_observed_actors)
              trace.ftt_dropped_events (List.length trace.ftt_gaps) )
      in
      let observed =
        match trace.ftt_observed_actors with
        | [] -> [ Ansi.dim, "  Observed actors: (none)" ]
        | actors ->
            fusion_wrapped_block ~width ~indent:"  "
              ("Observed actors: "
               ^ String.concat ", " (List.map fusion_tool_actor_text actors))
      in
      let gaps =
        List.map
          (fun gap ->
             ( Theme.warn ()
             , Printf.sprintf "  Gap: %s [%s]"
                 (fusion_tool_actor_text gap.ftg_actor)
                 (Terminal_text.single_line gap.ftg_reason) ))
          trace.ftt_gaps
      in
      let events =
        match trace.ftt_events with
        | [] when trace.ftt_complete ->
            [ Ansi.dim, "  No Tool calls were observed for instrumented actors" ]
        | [] -> [ Ansi.dim, "  No Tool events retained in this partial ledger" ]
        | events ->
            events
            |> List.concat_map (fun event ->
                   (Ansi.dim, "") :: fusion_tool_event_lines ~width event)
      in
      (coverage :: observed) @ gaps @ events

let fusion_pipeline_diagram (run : Masc.Tui_decode_fusion.fusion_run) =
  let glyph_done = (Theme.ok ()) ^ "\xe2\x97\x8f" ^ Ansi.reset in
  let glyph_active = (Theme.warn ()) ^ "\xe2\x97\x90" ^ Ansi.reset in
  let glyph_waiting = Ansi.dim ^ "\xe2\x97\x8b" ^ Ansi.reset in
  let glyph_failed = (Theme.bad ()) ^ "\xc3\x97" ^ Ansi.reset in
  let arrow = " " ^ (Theme.recede ()) ^ "\xe2\x96\xb8" ^ Ansi.reset ^ " " in
  let status =
    match run.fur_status with
    | Fusion_completed -> `Completed
    | Fusion_running -> `Running
    | Fusion_failed _ -> `Failed
  in
  let stage, panel_answered, panel_expected =
    match run.fur_stage with
    | Fusion_stage_accepted -> `Accepted, 0, 0
    | Fusion_stage_panel { frs_expected } -> `Panel, 0, frs_expected
    | Fusion_stage_judge { frs_expected; frs_answered; _ } -> `Judge, frs_answered, frs_expected
    | Fusion_stage_computed { frs_answered; frs_expected; _ }
    | Fusion_stage_recording_evidence { frs_answered; frs_expected; _ } -> `Evidence, frs_answered, frs_expected
    | Fusion_stage_completed -> `Completed, 0, 0
    | Fusion_stage_failed -> `Failed, 0, 0
  in
  Render_schedule.fusion_pipeline_diagram
    ~glyph_done ~glyph_active ~glyph_waiting ~glyph_failed ~arrow
    ~status ~stage ~panel_answered ~panel_expected ()

let fusion_evidence_lines ~width (evidence : fusion_evidence) =
  let answered, failed, input_tokens, output_tokens =
    List.fold_left
      (fun (answered, failed, input_tokens, output_tokens) result ->
        match result with
        | Fusion_panel_answered answer ->
            ( answered + 1
            , failed
            , input_tokens + answer.fpa_input_tokens
            , output_tokens + answer.fpa_output_tokens )
        | Fusion_panel_failed _ ->
            answered, failed + 1, input_tokens, output_tokens)
      (0, 0, 0, 0) evidence.fe_panel
  in
  let panel_lines =
    evidence.fe_panel
    |> List.mapi (fun index result ->
           match result with
           | Fusion_panel_answered answer ->
               [ ( (Theme.ok ())
                 , Printf.sprintf
                     "  Panel %d [answered] %s  (%d in / %d out)"
                     (index + 1)
                     (Terminal_text.single_line answer.fpa_model)
                     answer.fpa_input_tokens answer.fpa_output_tokens )
               ]
               @ fusion_markdown_block ~width ~indent:"    "
                   answer.fpa_answer
           | Fusion_panel_failed failure ->
               [ ( (Theme.bad ())
                 , Printf.sprintf "  Panel %d [failed] %s  [%s]"
                     (index + 1)
                     (Terminal_text.single_line failure.fpf_model)
                     (Terminal_text.single_line failure.fpf_reason_code) )
               ; Ansi.dim, "    Token usage: not recorded"
               ]
               @ fusion_wrapped_block ~width ~indent:"    "
                   failure.fpf_reason_detail)
    |> List.concat
  in
  let panel_token_items =
    List.filter_map
      (function
        | Fusion_panel_answered answer ->
            Some
              { Chart.name = Terminal_text.single_line answer.fpa_model
              ; count = answer.fpa_input_tokens + answer.fpa_output_tokens
              ; style = Some (Chart.Status Masc_tui_theme.Ok)
              }
        | Fusion_panel_failed _ -> None)
      evidence.fe_panel
  in
  let panel_chart_lines =
    if List.length panel_token_items >= 2 then
      ( Ansi.dim
      , if failed = 0 then "  Model token distribution:"
        else Printf.sprintf "  Model token distribution (measured %d/%d panels):"
            answered (answered + failed) )
      :: List.map (fun row -> (Ansi.reset, row)) (Chart.distribution_bars ~width panel_token_items)
      @ [ Ansi.dim, "" ]
    else []
  in
  let judge_lines =
    match evidence.fe_judge with
    | Fusion_judge_synthesized judge ->
        [ ( (Theme.info ())
          , "  Judge [synthesized] "
            ^ Terminal_text.single_line judge.fj_decision )
        ]
        @ fusion_labeled_markdown ~width ~label:"Resolved"
            judge.fj_resolved_answer
        @ fusion_labeled_markdown ~width ~label:"Reason" judge.fj_reason
    | Fusion_judge_failed failure ->
        [ ( (Theme.bad ())
          , "  Judge [failed] ["
            ^ Terminal_text.single_line failure.fj_failure_code
            ^ "]" )
        ]
        @ fusion_wrapped_block ~width ~indent:"    " failure.fj_error
  in
  (* RFC-0284 judge nodes. The canonical [Judge] row above is the final
     synthesis; this block is the topology it came through -- first the
     observed shape as one line, then one card per first-pass lens.
     Meta/stage/final nodes stay in the shape line only: their output
     is intermediate synthesis, and printing it next to the final one
     would render the same deliberation twice. Pre-RFC posts decode
     with no nodes and draw none of this. *)
  let judges_lines =
    match evidence.fe_judges with
    | [] -> []
    | nodes ->
        let count_role wanted =
          List.fold_left
            (fun n node ->
              if node.fjn_role = wanted then n + 1 else n)
            0 nodes
        in
        let firsts = count_role Judge_first in
        let metas = count_role Judge_meta in
        let stage_metas = count_role Judge_stage_meta in
        let final_metas = count_role Judge_final_meta in
        let refines = count_role Judge_refine in
        let singles = count_role Judge_single in
        let shape =
          (* Same reading the dashboard's shape classifier makes: a
             first-pass judge only exists in a judge-of-judges run,
             and stage/final metas only in the staged one. *)
          if stage_metas > 0 || final_metas > 0 then "staged judge-of-judges"
          else if firsts > 0 then "judge-of-judges"
          else if refines > 0 then "refine"
          else "single"
        in
        let counts =
          List.filter_map
            (fun (label, n) ->
              if n > 0 then Some (Printf.sprintf "%s \xc3\x97%d" label n) else None)
            [ ("first", firsts); ("meta", metas); ("stage-meta", stage_metas)
            ; ("final-meta", final_metas); ("refine", refines)
            ; ("single", singles) ]
        in
        let first_cards =
          nodes
          |> List.filter (fun node -> node.fjn_role = Judge_first)
          |> List.mapi (fun index node ->
                 match node.fjn_outcome with
                 | Judge_node_synthesized synthesized ->
                     [ ( (Theme.info ())
                       , Printf.sprintf
                           "  First %d [synthesized] %s  (%d in / %d out)"
                           (index + 1)
                           (Terminal_text.single_line node.fjn_identity)
                           synthesized.fjno_input_tokens
                           synthesized.fjno_output_tokens )
                     ]
                     @ fusion_labeled_markdown ~width
                         ~label:
                           (Printf.sprintf "First %d %s" (index + 1)
                              (Terminal_text.single_line node.fjn_identity))
                         synthesized.fjno_resolved_answer
                 | Judge_node_failed failed ->
                     let clock =
                       match (failed.fjno_timed_out, failed.fjno_elapsed_s) with
                       | true, _ -> "  (timed out)"
                       | false, Some seconds ->
                           Printf.sprintf "  (%.0fs)" seconds
                       | false, None -> ""
                     in
                     [ ( (Theme.bad ())
                       , Printf.sprintf
                           "  First %d [failed] %s  [%s]%s"
                           (index + 1)
                           (Terminal_text.single_line node.fjn_identity)
                           (Terminal_text.single_line failed.fjno_failure_code)
                           clock )
                     ]
                     @ fusion_wrapped_block ~width ~indent:"    "
                         failed.fjno_error)
          |> List.concat
        in
        [ Ansi.dim, "" ]
        (* The counts are already in pipeline order, so joining them
           with the same arrow the Goal stage rail uses draws the run
           rather than describing it. The shape name stays, at the end,
           because it is what the preset is called. *)
        @ ( Ansi.dim
          , Printf.sprintf "  %s  \xe2\x94\x80\xe2\x96\xb6  %s  \xc2\xb7  %s"
              (fusion_panel_dots ~answered ~failed)
              (String.concat "  \xe2\x94\x80\xe2\x96\xb6  " counts)
              shape )
        :: first_cards
  in
  let tool_lines =
    fusion_tool_trace_lines ~width evidence.fe_tool_trace
  in
  (* One line per seat: the route it was given and who answered, each
     failed candidate under it. A post the sink wrote without routes draws
     no block and keeps the evidence section at 5; with routes the seats are
     5 and the evidence is 6. *)
  let seat_route_lines =
    match evidence.fe_seat_routes with
    (* An empty array draws nothing rather than a header with no seat under
       it. The sink writes the key on every post, so a deliberation that
       seated nobody reaches here as [Some []]. *)
    | None | Some [] -> []
    | Some routes ->
        [ Ansi.dim, ""; Ansi.bold, "  5  SEAT ROUTES" ]
        @ List.concat_map
            (fun line ->
              Message_layout.split_cells ~max_cells:(max 1 (width - 2)) line
              |> List.map (fun line -> Ansi.reset, "  " ^ line))
            (Masc_tui_fusion_seat_routes.lines routes)
  in
  let evidence_section = if seat_route_lines = [] then "5" else "6" in
  [ Ansi.bold, "  Title: " ^ Terminal_text.single_line evidence.fe_title
  ; Ansi.dim, ""
  ; Ansi.bold, "  1  QUESTION"
  ]
  @ fusion_markdown_block ~width ~indent:"    " evidence.fe_question
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  2  PANEL RESPONSES"
    ; ( Ansi.dim
      , let usage =
          if answered = 0 then "panel token usage: not recorded"
          else if failed = 0 then
            Printf.sprintf "%d input / %d output tokens" input_tokens output_tokens
          else
            Printf.sprintf "measured %d/%d panels: %d input / %d output tokens"
              answered (answered + failed) input_tokens output_tokens
        in
        Printf.sprintf "  %d answered / %d failed  \xc2\xb7  %s"
          answered failed usage )
  ]
  @ [ Ansi.dim, "" ]
  @ panel_chart_lines
  @ panel_lines
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  3  JUDGE"
    ]
  @ judge_lines
  @ judges_lines
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  4  TOOL EXECUTIONS"
    ]
  @ tool_lines
  @ seat_route_lines
  @ [ Ansi.dim, ""
    ; Ansi.bold, "  " ^ evidence_section ^ "  EVIDENCE RECORDED"
    ; ( Ansi.dim
      , "  Board link: "
        ^ Link.reference Board_post
            (Terminal_text.single_line evidence.fe_post_id) )
    ]

let fusion_detail_lines ~width (detail : fusion_detail) =
  let run = detail.fud_run in
  let status = fusion_run_status_to_string run.fur_status in
  let now = Unix.gettimeofday () in
  let tm = Unix.localtime run.fur_started_at in
  let date_time =
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let age = fusion_run_age ~now run in
  let started_text = Printf.sprintf "%s (%s ago)" date_time age in
  let pipeline = fusion_pipeline_diagram run in
  (* The pipeline row names the four stops and marks the one the run is on;
     a Flow row above it named the same four stops again with no state, and a
     Stage row below the status named the marked stop a third time. On a
     finished run the three read "completed / completed / completed". The
     stops are the pipeline's to draw; the status says whether the run ended,
     and Progress says what it is doing about the stop it is on. *)
  let run_lines =
    [ Ansi.bold, "  RUN"
    ; Ansi.reset, "  Pipeline: " ^ pipeline
      (* No Actions row: every key it named is on the footer, drawn from the
         key table, and this row spelled them three ways ("K Keeper",
         "[Y] Copy Link", "[PgUp/PgDn] Page"). *)
    ; ( Ansi.dim
      , "  Link: "
        ^ Link.reference Fusion_run
            (Terminal_text.single_line run.fur_run_id) )
    ; ( Ansi.reset
      , Printf.sprintf "  Caller: %s@%s%s %s[Keeper]%s  \xc2\xb7  %s"
          (Masc_tui_theme.tone Masc_tui_theme.Accent)
          (Terminal_text.single_line run.fur_keeper)
          Ansi.reset
          (Theme.warn ())
          Ansi.reset
          (Link.reference Keeper (Terminal_text.single_line run.fur_keeper)) )
    ; fusion_run_status_color run.fur_status, "  Status: " ^ status
    ]
    (* Progress narrates a stop the run is still on. Once it has ended the
       stage is terminal and the row would repeat the status word. *)
    @ (match run.fur_stage with
       | Fusion_stage_completed | Fusion_stage_failed -> []
       | Fusion_stage_accepted | Fusion_stage_panel _ | Fusion_stage_judge _
       | Fusion_stage_computed _ | Fusion_stage_recording_evidence _ ->
           [ Ansi.dim, "  Progress: " ^ fusion_run_progress_text run.fur_stage ])
    @ [ ( Ansi.reset
    , "  Configuration: " ^ Terminal_text.single_line run.fur_preset ^ " \xc2\xb7 "
      ^ Fusion_types.fusion_topology_to_string run.fur_topology )
    ; Ansi.dim, "  Started: " ^ started_text
    ; Ansi.reset, "  Duration: " ^ fusion_run_duration ~now run
    ]
    @ (match detail.fud_evidence with
       | None -> [Ansi.dim, "  Original question and Board link: awaiting evidence"]
       | Some evidence ->
           [ Theme.info (), "  Board: " ^ Link.reference Board_post evidence.fe_post_id
           ; Ansi.bold, "  Original question: " ^ Terminal_text.single_line evidence.fe_question ])
    @
    match run.fur_status with
    | Fusion_running -> []
    | Fusion_completed ->
        (match run.fur_decision, run.fur_summary with
         | Some decision, Some summary ->
             [ (Theme.ok ()), "  Outcome: " ^ Terminal_text.single_line decision ]
             @ fusion_labeled_markdown ~width ~label:"Outcome summary" summary
         | (Some _ | None), (Some _ | None) -> [])
    | Fusion_failed failure ->
        [ (Theme.bad ())
        , Printf.sprintf "  Registry failure [%s]: %s"
            (Terminal_text.single_line failure.frs_failure_code)
            (Terminal_text.single_line failure.frs_error)
        ]
  in
  let evidence_lines =
    match detail.fud_evidence_status, detail.fud_evidence with
    | Fusion_evidence_pending, None ->
        [ (Theme.warn ()), "  Evidence: pending (run is still running)" ]
    | Fusion_evidence_absent, None ->
        [ (Theme.warn ())
        , "  Evidence: absent (no current Board projection for this retained run)"
        ]
    | Fusion_evidence_recorded, Some evidence -> fusion_evidence_lines ~width evidence
    | Fusion_evidence_recorded, None
    | Fusion_evidence_pending, Some _
    | Fusion_evidence_absent, Some _ ->
        (* The strict decoder makes these states unreachable. Keeping the row
           explicit protects locally-constructed test state from looking like
           a legitimate empty reading. *)
        [ (Theme.bad ()), "  Fusion evidence invariant violated" ]
  in
  run_lines @ [ Ansi.dim, "" ] @ evidence_lines

let fusion_historical_lines ~width (detail : fusion_historical_detail) =
  [ Ansi.bold, "  HISTORICAL BOARD EVIDENCE"
  ; Theme.warn (), "  This Board evidence does not provide execution status or finish time"
  ; Ansi.reset, "  Run reference: " ^ Terminal_text.single_line detail.fhd_reference.fhe_run_id
  ; Ansi.reset, "  Board author: " ^ Terminal_text.single_line detail.fhd_author
  ; Theme.info (), "  Board: " ^ Link.reference Board_post detail.fhd_reference.fhe_post_id
  ; Ansi.reset, "  Title: " ^ Terminal_text.single_line detail.fhd_title
  ]
  @ (match detail.fhd_observations with
     | Error error ->
         [ Theme.bad (), "  Observed usage could not be decoded: " ^ Terminal_text.single_line error ]
     | Ok (usage, cost_usd) ->
         [ Ansi.reset, (match usage with
             | None -> "  Observed tokens: not recorded"
             | Some (input, output) -> Printf.sprintf "  Observed tokens: %d input / %d output" input output)
         ; Ansi.reset, (match cost_usd with
             | None -> "  Observed cost: not recorded"
             | Some cost -> Printf.sprintf "  Observed cost: $%.4f" cost) ])
  @ [ Ansi.dim, "  B: Board original · Y: copy Board link · Esc: back to Fusion list"
  ; Ansi.dim, "" ]
  @ (match detail.fhd_evidence with
     | Ok evidence -> fusion_evidence_lines ~width evidence
     | Error error -> [ Theme.bad (), "  Structured Fusion evidence could not be decoded: " ^ Terminal_text.single_line error ])
  @ [ Ansi.dim, ""; Ansi.bold, "  BOARD ORIGINAL" ]
  @ fusion_markdown_block ~width ~indent:"    " detail.fhd_body

let fusion_detail_pane (state : state) ~rows ~cols run_id buf =
  let detail =
    match state.fusion_detail with
    | Some detail when String.equal detail.fud_run.fur_run_id run_id ->
        Some detail
    | Some _ | None -> None
  in
  let header =
    detail_heading ~cols ~lead:(Lead_text (screen_title fusion_title ^ "  "))
      ~id:run_id ~after:"" ~tail:(connection_badge state)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.fusion_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:(Theme.bad ())
         ("  " ^ Keeper_chat.terminal_safe_text error);
       box_divider buf cols);
  let chrome_rows =
    if Option.is_some state.fusion_detail_error then 7 else 5
  in
  let content_height = max 1 (rows - chrome_rows) in
  let lines =
    match state.fusion_mode with
    | Fusion_historical_detail reference ->
        (match state.fusion_historical_detail with
         | Some original when original.fhd_reference.fhe_post_id = reference.fhe_post_id
                              && original.fhd_reference.fhe_run_id = reference.fhe_run_id ->
             (if Option.is_some state.fusion_detail_error then [ Theme.warn (), "  Previous Board reading retained" ] else [])
             @ fusion_historical_lines ~width:(max 1 (cols - 8)) original
         | Some _ | None -> [ Ansi.dim, "  (waiting for the selected Board original; r retries)" ])
    | Fusion_list | Fusion_detail _ ->
        (match detail, state.fusion_detail_error with
         | None, None -> [ Ansi.dim, "  (loading exact Fusion detail)" ]
         | None, Some _ -> [ Ansi.dim, page_failed_note ]
         | Some detail, (Some _ | None) -> fusion_detail_lines ~width:(max 1 (cols - 8)) detail)
  in
  let total = List.length lines in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.fusion_scroll max_scroll) in
  let lines_window = Rows.of_list ~first:scroll ~height:content_height lines in
  for index = 0 to content_height - 1 do
    match Rows.at lines_window (index + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  scroll, Masc_tui_scroll.window_text ~scroll ~height:content_height total
;;

(* The run list stays beside the run. Opening one used to hide the others, and the others
   are what say whether this is the one to act on. Below the split
   width there is no room for both and the detail keeps the screen. *)
let render_fusion_detail (state : state) run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let scroll, position =
    if cols < keeper_split_threshold_cols then
      fusion_detail_pane state ~rows ~cols run_id buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let format_sidebar_fusion (row : Masc.Tui_decode_fusion.fusion_run) =
        let status =
          match row.fur_status with
          | Masc.Tui_decode_fusion.Fusion_running -> "run "
          | Masc.Tui_decode_fusion.Fusion_completed -> "done"
          | Masc.Tui_decode_fusion.Fusion_failed _ -> "fail"
        in
        let time = fusion_run_clock row in
        let keeper = Terminal_text.single_line row.fur_keeper in
        let run_id = Terminal_text.single_line row.fur_run_id in
        Render_schedule.fusion_sidebar_label ~status ~time ~keeper ~run_id
      in
      let labels =
        Masc_tui_fusion_model.fusion_list_entries state
        |> List.map (function
            | Fusion_retained_run run -> format_sidebar_fusion run
            | Fusion_historical_evidence reference ->
                "history " ^ Terminal_text.single_line reference.fhe_title)
      in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* No list row is selected when its original remains open after the
         refreshed inventory omits it. The sidebar's index API uses -1 for
         no matching row; the domain selection stays optional. *)
      let selected = Option.value (Masc_tui_fusion_model.fusion_detail_entry_index state) ~default:(-1) in
      (* The retained inventory is the whole list; nothing is held back. *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Fusion"
        ~focused:false ~holding:None ~labels ~selected;
      let answer =
        fusion_detail_pane state ~rows ~cols:(cols - left_cols) run_id
          right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      answer
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols ~position
       ~hints:Masc_tui_keys.footer_hints_fusion_detail);
  finish_surface state ~clamped:(Fusion_detail_scroll scroll)
    ~surface_key:"fusion-detail" ~rows:terminal_rows ~cols buf

(* The launch form over the Fusion list, in the shared overlay chrome. The
   form is what the operator is looking at, so its refusal line is where
   the server's answer goes; the list's own error row is under it. The
   scroll rides [fusion_scroll], idle while the list is up, and the frame
   reports what it clamped to the way the detail does. *)
let render_fusion_launch (state : state) ~(form : Masc_tui_fusion_launch.t option) =
  let terminal_rows, cols = get_terminal_size () in
  let width = framed_inner_width cols in
  let text, hints =
    match form with
    | None -> [ "Reading the Fusion presets from runtime.toml..." ], "Esc:cancel"
    | Some form -> Masc_tui_fusion_launch.lines form, Masc_tui_fusion_launch.hints
  in
  let lines =
    List.concat_map
      (fun line ->
        Message_layout.split_cells ~max_cells:(max 1 (width - 2))
          (Masc.Tui_terminal_text.sanitize_terminal_text line))
      text
    |> List.map (fun line -> "  " ^ line)
  in
  surface_chrome state ~terminal_rows ~cols ~surface_key:"fusion-launch"
    ~frame:Chrome_overlay
    ~overflow:
      (Scrolled
         { scroll = state.fusion_scroll
         ; report = (fun scroll -> Fusion_detail_scroll scroll) })
    ~title:(screen_title (fusion_title ^ " - LAUNCH"))
    ~hints
    ~body:(fun ~budget:_ c -> List.iter c.push lines)
