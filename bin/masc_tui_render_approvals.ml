(** Approval queue, detail and question surfaces. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim

module Approval_detail = Masc_tui_approval_detail
module Ask_projection = Masc_tui_ask_projection
module Ask_layout = Masc_tui_ask_layout
module Message_layout = Masc_tui_message_layout
module Render_schedule = Masc_tui_render_schedule
module Rows = Masc_tui_rows

type approval_line =
  | Field_line of Approval_detail.line
  | Gate_line of Approval_detail.gate_line

let approval_gate_phase state = function
  | Gate_queued -> ui_text state ~ko:"검토 대기" ~en:"queued", Theme.warn ()
  | Gate_judging -> ui_text state ~ko:"자동 검토 중" ~en:"judging", Theme.info ()
  | Gate_human_required -> ui_text state ~ko:"사람 판단 필요" ~en:"human required", Theme.warn ()
  | Gate_blocked -> ui_text state ~ko:"자동 검토 중단" ~en:"auto judge blocked", Theme.bad ()

let approval_source_notices state ~(reading : Masc_tui_approvals_model.approvals_reading) =
  [ ui_text state ~ko:"운영자 승인" ~en:"Confirmations", reading.confirm_queue
  ; ui_text state ~ko:"보류 도구" ~en:"Held calls", reading.held_calls
  ; ui_text state ~ko:"도구 심사" ~en:"Gate queue", reading.gate_queue
  ; ui_text state ~ko:"질문" ~en:"Questions", reading.questions ]
  |> List.filter_map (fun (label, list_reading) ->
    let open Masc_tui_approvals_model in
    match list_reading with
    | List_read -> None
    | List_not_read Approval_unread ->
        Some (Theme.recede (), label ^ ui_text state ~ko:" · 미조회" ~en:" · not read")
    | List_not_read (Approval_failed cause) ->
        Some (Theme.bad (), label ^ ui_text state ~ko:" · 조회 실패: " ~en:" · read failed: "
          ^ Terminal_text.single_line cause)
    | List_not_read (Approval_stale cause) ->
        Some (Theme.warn (), label ^ ui_text state ~ko:" · 이전 조회 · 갱신 실패: " ~en:" · retained; refresh failed: "
          ^ Terminal_text.single_line cause)
    | List_not_read (Approval_unavailable detail) ->
        Some (Theme.warn (), label ^ ui_text state ~ko:" · 조회 불가: " ~en:" · unavailable: "
          ^ Terminal_text.single_line detail))

(** Render the Approvals surface (pending confirmations). *)
(* The ask, whole. The list row is one line through [single_line], which
   turns a newline into the six characters [\x0A] and then cuts; an [Edit]
   carrying a page of code read as its first forty characters and there was
   no second screen. This is that screen. *)
let approval_detail_pane (state : state) ~value_hint ~clamped ~viewport ~rows ~cols (row : Masc_tui_approvals_model.approval_row) buf =
  let width = max 0 (framed_inner_width cols - 2) in
  (* [Approval_detail.of_fields] makes every value terminal-safe. *)
  let fields, gate_fields, identifiers =
    match row with
    | Masc_tui_approvals_model.Keeper_tool_row held ->
      ([ "question", held.Tui_decode.kta_question
      ; "because", Option.value ~default:"(not provided)" held.Tui_decode.kta_because
      ; "keeper", held.Tui_decode.kta_keeper
      ; "tool", held.Tui_decode.kta_tool
      ; "args", held.Tui_decode.kta_args
      ], None, ["call", held.Tui_decode.kta_tool_call_id])
    | Masc_tui_approvals_model.Gate_row pending ->
      let phase = fst (approval_gate_phase state pending.Tui_decode.gp_phase) in
      let blocked_fields =
        match pending.Tui_decode.gp_phase with
        | Gate_blocked ->
          [ ( "reason"
            , Option.value
                ~default:"(the server recorded no detail)"
                pending.Tui_decode.gp_auto_judge_detail )
          ; ( "next"
            , match pending.Tui_decode.gp_retry_request with
              | Some _ -> "R: retry Auto Judge; y/n: decide now"
              | None ->
                  "y/n: decide now (this exact attempt cannot be replayed)" )
          ]
        | Gate_human_required ->
          (* Auto Judge handed the row over with its reasons; the person
             deciding reads them here instead of guessing why. *)
          (match pending.Tui_decode.gp_judge_advice with
           | Some advice ->
             ( "judge said", Terminal_text.single_line advice.rationale )
             :: List.mapi
                  (fun index question ->
                     ((if index = 0 then "asks" else ""), Terminal_text.single_line question))
                  advice.key_questions
           | None -> [])
        | Gate_queued | Gate_judging -> []
      in
      let fields = [ "tool", pending.Tui_decode.gp_display_tool
      ; "keeper", pending.Tui_decode.gp_keeper
      ; "state", phase
      ]
      @ blocked_fields
      @ [
        ( "operation", pending.Tui_decode.gp_operation )
      ; ( "sandbox"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_sandbox )
      ; ( "working directory"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_cwd )
      ]
      in
      let fields, input = match pending.Tui_decode.gp_input_rows with
         | Tui_decode.Rows (_ :: _ as input_fields) ->
           fields, Some input_fields
         | Tui_decode.Rows [] ->
           fields @ [ "input", "(the stored input object is empty)" ], None
         | Tui_decode.Flattened preview ->
           fields @ [ ( "input (flattened preview, may be cut)"
             , Terminal_text.single_line_or
                 ~default:"(the server recorded no input preview)" preview )
           ], None in
      fields, input, ["approval", pending.Tui_decode.gp_id]
    | Masc_tui_approvals_model.Operator_row a ->
      ([ "summary", a.Masc_tui_operator_projection.ap_summary
      ; "actor", a.Masc_tui_operator_projection.ap_actor
      ; "action", a.Masc_tui_operator_projection.ap_action_type
      ; "target", a.Masc_tui_operator_projection.ap_target_type
      ; "payload",
        Masc_tui_operator_projection.approval_payload_document_for_terminal
          a.Masc_tui_operator_projection.ap_payload
      ], None,
      [ "target id", Terminal_text.single_line_or ~default:"(not recorded)" a.ap_target_id
      ; "created", Terminal_text.short_timestamp a.ap_created_at
      ; "expires", (match Terminal_text.optional_single_line a.ap_expires_at with
          | None -> Masc_tui_theme.Glyph.no_value
          | Some at -> Terminal_text.short_timestamp at)
      ; "trace", a.ap_trace_id
      ])
  in
  let lines =
    List.map (fun line -> Field_line line) (Approval_detail.of_fields ~width fields)
    @ (match gate_fields with
       | None -> []
       | Some fields ->
         let string_reading = match value_hint with
           | Masc_tui_keys.No_value_reading | Readable_values -> Approval_detail.Readable_string
           | Byte_values -> Approval_detail.Exact_string_bytes in
         Approval_detail.of_gate_fields ~string_reading ~width fields
         |> List.map (fun line -> Gate_line line))
    @ List.map (fun line -> Field_line line) (Approval_detail.of_fields ~width identifiers)
    @ List.map (fun line -> Field_line line)
        (Approval_detail.of_fields ~width
          (approval_source_notices state ~reading:(Masc_tui_approvals_model.approvals_reading state)
           |> List.map (fun (_, text) -> "read status", text)))
  in
  let input_unreadable =
    List.exists
      (function
        | Field_line line -> line.unreadable
        | Gate_line line -> line.gate_origin = Approval_detail.Gate_unreadable)
      lines
  in
  let key_has_bytes =
    List.exists
      (function
        | Field_line _ -> false
        | Gate_line line ->
          (match line.gate_origin with
           | Approval_detail.Gate_key_with_bytes _ -> true
           | Gate_key | Gate_key_continuation | Gate_key_with_bytes_continuation _
           | Gate_key_bytes _ | Gate_key_bytes_continuation _
           | Gate_string | Gate_string_bytes | Gate_json | Gate_unreadable -> false))
      lines
  in
  box_top buf cols;
  (* Keep the numbered-key legend visible while scrolling; unreadable input
     takes precedence over it. The footer owns the way out. *)
  box_line buf cols (screen_title
    (if input_unreadable then "!WIDEN Approval"
     else match value_hint, key_has_bytes with
       | Masc_tui_keys.No_value_reading, false -> " MASC Approval"
       | No_value_reading, true -> "*N=bN bytes | Approval"
       | Readable_values, false -> "v:bytes | top-level strings"
       | Readable_values, true -> "v:bytes *N=bN | Approval"
       | Byte_values, false -> "v:text | top-level string bytes"
       | Byte_values, true -> "v:text *N=bN | top-level strings"));
  box_divider buf cols;
  let content_height = max 1 (rows - 6) in
  let total = List.length lines in
  viewport := Some
    { adv_count = total; adv_height = content_height;
      adv_presentation = (match value_hint with
        | Masc_tui_keys.Byte_values -> Approval_string_bytes
        | No_value_reading | Readable_values -> Approval_text) };
  let scroll =
    Masc_tui_scroll.normalize ~count:total ~height:content_height
      state.approval_detail_scroll
  in
  (* The pane is where the field count and the drawn height meet, so the row
     it could actually use is reported back rather than recomputed outside. *)
  clamped := scroll;
  (* The pane scrolls, but nothing on it said the ask ran past the frame: an
     operator could read the first screen, believe it whole, and press y. The
     window line the other reading panes carry is what says there is more, so
     the footer gets it when the field list outgrows the frame. *)
  let overflow_hint =
    if total > content_height then
      Printf.sprintf "[rows %s]  "
        (Masc_tui_scroll.window_text ~scroll ~height:content_height total)
    else ""
  in
  let drawn =
    lines |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  in
  List.iter
    (fun line ->
      let label, text, prefix =
        match line with
        | Field_line line -> line.label, line.text, ""
        | Gate_line line -> line.gate_label, line.gate_text, Approval_detail.prefix line.gate_origin
      in
      let content_width = max 0 (framed_inner_width cols - 2 - String.length prefix) in
      match label with
      | Some label ->
        (* The name is bold, what sits beside it is not: the row carries both
           now, and bolding the whole of it would weight the value too. *)
        let drawn = fit_width text content_width in
        let name = String.length label in
        (* Split only where the whole name survived the cut. A narrow pane
           can end the row inside the name, and [fit_width]'s ellipsis is
           three bytes: splitting at the name's byte length there would cut
           the ellipsis and send half a character to the terminal. *)
        box_line buf cols
          (if String.starts_with ~prefix:label drawn then
             Printf.sprintf "  %s%s%s%s%s" prefix Ansi.bold label Ansi.reset
               (String.sub drawn name (String.length drawn - name))
           else Printf.sprintf "  %s%s%s%s" prefix Ansi.bold drawn Ansi.reset)
      | None ->
        box_line buf cols (Printf.sprintf "  %s%s" prefix (fit_width text content_width)))
    drawn;
  for _ = 1 to content_height - List.length drawn do
    box_empty buf cols
  done;
  box_bottom buf cols;
  overflow_hint
;;

(* The queue stays beside the ask. Reading one used to hide the rest, and the
   rest is what tells an operator whether this one is the urgent one. *)
(* Who asked, beside what they asked for. The label was the tool alone, and a
   queue holds one row per held call. Many calls can name the same tool while
   different Keepers wait. The full-width list row beside this pane already
   draws the asker; only the index dropped it.

   The asker goes after the tool because the pane folds a label from the
   middle and keeps its tail (Render_schedule.sidebar_row_label). *)
let approval_sidebar_label (row : Masc_tui_approvals_model.approval_row) =
  let about, apart =
    match row with
    | Masc_tui_approvals_model.Keeper_tool_row held ->
      held.Tui_decode.kta_tool, held.Tui_decode.kta_keeper
    | Masc_tui_approvals_model.Gate_row pending ->
      pending.Tui_decode.gp_display_tool, pending.Tui_decode.gp_keeper
    | Masc_tui_approvals_model.Operator_row item -> item.ap_action_type, item.ap_actor
  in
  Render_schedule.sidebar_row_label ~about ~apart:(Some apart)

let render_approval_detail (state : state) (row : Masc_tui_approvals_model.approval_row) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let scroll = ref state.approval_detail_scroll in
  let viewport = ref None in
  let value_hint =
    if not (Masc_tui_approvals_model.value_reading_available state row) then
      Masc_tui_keys.No_value_reading
    else if Option.is_some (Masc_tui_approvals_model.current_value_reading state) then
      Masc_tui_keys.Byte_values
    else Masc_tui_keys.Readable_values in
  let overflow_hint =
    if cols < keeper_split_threshold_cols then
      approval_detail_pane state ~value_hint ~clamped:scroll ~viewport ~rows ~cols row buf
    else begin
      let left_cols = keeper_roster_pane_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      (* Not "Asks": this surface already calls a Keeper's question to a human
         an ask, and these rows are the confirmations waiting on an operator. *)
      (* The actor filter hides entries rather than paging past them, and
         the surface's own title already carries "hidden N". *)
      write_list_sidebar left_buf ~rows ~cols:left_cols ~title:"Approvals"
        ~holding:None
        ~focused:false
        ~labels:(List.map approval_sidebar_label (Masc_tui_approvals_model.approval_items state))
        ~selected:state.approval_cursor;
      let hint =
        approval_detail_pane state ~value_hint ~clamped:scroll ~viewport ~rows
          ~cols:(cols - left_cols) row right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      hint
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(overflow_hint ^ Masc_tui_keys.footer_hints_approval_detail ~lang:state.ui_language
              ~value_hint));
  finish_surface state ~clamped:(Approval_detail_scroll (!scroll, !viewport))
    ~surface_key:"approval-detail" ~rows:terminal_rows ~cols buf

(* Six cells hold [Message_layout.span_text]'s widest reading ("99d23h"), the
   same cell the Board and Keeper roster ages take. *)
let ask_age_cells = 6

(* A folded Ask leads with its first original question. The asker, age and
   additional-question count distinguish it without opening an answer editor. *)
let ask_summary_line state ~cols ~now ~(row : Masc.Tui_decode_asks.ask_row) =
  let count = List.length row.Masc.Tui_decode_asks.ar_questions in
  let prompt = match row.Masc.Tui_decode_asks.ar_questions with
    | question :: _ -> Terminal_text.single_line question.aq_prompt
    | [] -> ui_text state ~ko:"질문 없음" ~en:"no questions" in
  let context =
    Printf.sprintf "%s  %s%s"
      (fit_width (Terminal_text.single_line (Masc.Tui_decode_asks.ask_asker_label row.ar_asker)) 16)
      (fit_width
         (Option.value ~default:"" (Message_layout.age_text ~now ~since:row.ar_asked_at))
         ask_age_cells)
      (if count > 1 then Printf.sprintf " · +%d" (count - 1) else "") in
  let width = max 1 (framed_inner_width cols - Message_layout.display_width context - 3) in
  Printf.sprintf " %s%s  %s%s" (Theme.recede ()) (fit_width prompt width) context Ansi.reset

(* Keep the original strings until the reader sanitizes and wraps them.
   Compact rendering and the immutable reader share the same receipt facts. *)
let ask_answer_feedback_document (state : state) =
  let module Decode = Masc.Tui_decode_asks in
  Option.map (fun feedback ->
    let fields = ref [] in
    let emit heading style body =
      let section : Masc_tui_detail_reading.section = {heading; body} in
      fields := (section, style) :: !fields in
    let followup = Masc_tui_types.current_ask_followup state in
    let delivered ~already = function
      | Decode.Ask_wake_stored ->
          (if already then "Existing answer retained · wake recorded"
           else "Answer saved · wake recorded"), Theme.info (),
          (match followup with None -> Some "Keeper activity shows whether work has resumed." | Some _ -> None)
      | Decode.Ask_wake_pending detail ->
          (if already then "Existing answer retained · initial delivery pending"
           else "Answer saved · initial delivery pending"), Theme.warn (), Some detail in
    let status, style, detail = match feedback.Ask_projection.af_receipt with
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_recorded delivery)) -> delivered ~already:false delivery
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_already_recorded { aar_delivery; _ })) ->
          delivered ~already:true aar_delivery
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_written_unconfirmed detail)) ->
          "Winning answer unconfirmed · log written", Theme.warn (), Some detail
      | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_refused detail))
      | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_refused detail)) ->
          "Answer refused", Theme.bad (), Some detail
      | Ok (Decode.Installation_answer_receipt Decode.Installation_answer_recorded) ->
          "Answer saved · installation reads it on its next host request cycle", Theme.info (), None
      | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_already_answered _)) ->
          "An earlier answer stands", Theme.info (), None
      | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_withdrawn _)) ->
          "Installation withdrew the question", Theme.warn (), None
      | Error detail ->
          "Answer recording unconfirmed", Theme.warn (), Some detail in
    emit "Recording" style status;
    emit "Question" Ansi.dim
      (Decode.ask_asker_label feedback.af_asker ^ "\nAsk ID: " ^ feedback.af_ask_id);
    Option.iter (emit "Recorded answer label" Ansi.dim) feedback.af_submitted_label;
    Option.iter (emit "Recording details" (Theme.warn ())) detail;
    (match feedback.af_asker with
     | Decode.Ask_keeper _ ->
         let source = match feedback.af_source_turn_ref with
           | None -> "Original asking turn: not recorded"
           | Some reference ->
               "Original asking turn:\n" ^ Yojson.Safe.pretty_to_string (Ids.Turn_ref.to_yojson reference) in
         emit "Original asking turn" Ansi.dim source
     | Decode.Ask_installation { ai_title; _ } ->
         emit "Installation" Ansi.dim
           ("Esc to return · g: open " ^ ai_title ^ " Results\n"
            ^ Yojson.Safe.pretty_to_string (Ask_projection.asker_to_json feedback.af_asker)));
    Option.iter (fun reading ->
      let observed = Ask_projection.followup_view reading in
      let source_notice source = match source.Ask_projection.fo_state with
        | Followup_pending ->
            (match source.fo_value with None -> "" | Some _ -> " · reading latest")
        | Followup_received -> ""
        | Followup_unconfirmed ->
            (match source.fo_value with None -> ""
             | Some _ -> " · earlier observation; latest source unconfirmed") in
      let source_style source observed = match source.Ask_projection.fo_state with
        | Followup_unconfirmed -> Theme.warn ()
        | Followup_pending | Followup_received -> observed in
      let absent source label = match source.Ask_projection.fo_state with
        | Followup_pending -> label ^ ": reading", Theme.recede ()
        | Followup_received -> label ^ ": observation unavailable", Theme.warn ()
        | Followup_unconfirmed -> label ^ ": latest source unconfirmed", Theme.warn () in
      Option.iter (fun identity ->
        emit "Original answer identity" Ansi.dim
          (Yojson.Safe.pretty_to_string (`Assoc [
            "answered_at", `Float identity.Decode.afi_answered_at;
            "stimulus_id", `String identity.afi_stimulus_id]))) observed.fv_identity;
      (match observed.fv_reactions.fo_value with
       | None ->
           let text, style = absent observed.fv_reactions "Keeper wake/turn" in
           emit "Keeper follow-up" style text
       | Some Decode.Ask_reactions_unavailable ->
           emit "Keeper follow-up" (Theme.warn ())
             ("Wake/turn observation unavailable" ^ source_notice observed.fv_reactions)
       | Some (Ask_reactions_observed reactions) ->
           let facts = List.filter_map Fun.id
             [Option.map (fun _ -> "turn entry observed") reactions.ar_turn_started_at;
              Option.map (fun _ -> "turn boundary observed") reactions.ar_turn_finished_at;
              Option.map (fun _ -> "wake settled or transferred (consumption unproven)") reactions.ar_queue_settled_at;
              Option.map (fun _ -> "wake cancelled") reactions.ar_queue_cancelled_at] in
           let facts = if facts=[] then ["no turn entry observed"] else facts in
           let facts = if reactions.ar_evidence_complete then facts else facts @ ["evidence incomplete"] in
           let facts = if reactions.ar_evidence_current then facts
             else facts @ ["some earlier observations remain unconfirmed"] in
           emit "Keeper follow-up"
             (source_style observed.fv_reactions
               (if reactions.ar_evidence_complete && reactions.ar_evidence_current
                then Theme.info () else Theme.warn ()))
             (String.concat " · " facts ^ source_notice observed.fv_reactions));
      let action_text, action_style = match observed.fv_tools.fo_value with
        | None -> absent observed.fv_tools "Tool results"
        | Some Decode.Ask_tools_unavailable -> "Observation unavailable", Theme.warn ()
        | Some (Decode.Ask_tools_observed {at_count;at_outcomes;at_evidence_current;_}) ->
            let counts = List.filter_map (fun (label,count) ->
                if count=0 then None else Some (Printf.sprintf "%s %d" label count))
              ["succeeded",at_outcomes.ato_succeeded;"failed",at_outcomes.ato_failed;
               "deferred",at_outcomes.ato_deferred;"unsettled",at_outcomes.ato_unsettled;
               "malformed",at_outcomes.ato_malformed] in
            let text = if at_count=0 then "None observed"
              else Printf.sprintf "%d observed · %s" at_count (String.concat " · " counts) in
            let uncertain = at_outcomes.ato_failed>0 || at_outcomes.ato_unsettled>0 || at_outcomes.ato_malformed>0 in
            if at_evidence_current then text, (if uncertain then Theme.warn () else Theme.info ())
            else text ^ " · retained earlier evidence", Theme.warn () in
      emit "Tool results" (source_style observed.fv_tools action_style)
        (action_text ^ source_notice observed.fv_tools);
      (match observed.fv_tools.fo_value with
       | Some (Decode.Ask_tools_observed {at_latest=Some latest;at_evidence_current;_}) ->
           let style = match latest.ata_outcome with
             | Tool_result.Recorded_failed when at_evidence_current -> Theme.bad ()
             | Recorded_succeeded | Recorded_deferred when at_evidence_current -> Theme.info ()
             | Recorded_failed | Recorded_succeeded | Recorded_deferred
             | Recorded_unsettled | Recorded_malformed -> Theme.warn () in
           emit "Latest Tool result" style
             (Printf.sprintf "%s · %s · turn #%d"
               (Tool_result.recorded_call_outcome_to_string latest.ata_outcome)
               latest.ata_tool latest.ata_keeper_turn_id)
       | None | Some Decode.Ask_tools_unavailable | Some (Ask_tools_observed {at_latest=None;_}) -> ());
      let task_text, task_style = match observed.fv_task.fo_value with
        | None -> absent observed.fv_task "Original Task"
        | Some Decode.Ask_task_unlinked -> "No linked Task", Theme.recede ()
        | Some (Ask_task_missing id) -> id ^ ": not observed in lookup", Theme.warn ()
        | Some (Ask_task_unavailable id) -> id ^ ": observation unavailable", Theme.warn ()
        | Some (Ask_task_observed {akt_task_id;akt_location;akt_status;akt_evidence_current;akt_observed_at=_}) ->
            let phase = match akt_status with
              | Masc_domain.Todo -> "to do"
              | Claimed {assignee;_} -> "claimed by " ^ assignee
              | InProgress {assignee;_} -> "in progress by " ^ assignee
              | AwaitingVerification {verification_id;_} -> "awaiting verification " ^ verification_id
              | Done {assignee;_} -> "done by " ^ assignee
              | Cancelled {cancelled_by;_} -> "cancelled by " ^ cancelled_by in
            let location = match akt_location with
              | Decode.Ask_task_backlog -> "" | Ask_task_archive -> " · archived" in
            let freshness = if akt_evidence_current then ""
              else " · last observed; not freshly confirmed" in
            akt_task_id ^ ": " ^ phase ^ location ^ freshness,
            (if akt_evidence_current then Theme.info () else Theme.warn ()) in
      emit "Original Task" (source_style observed.fv_task task_style)
        (task_text ^ source_notice observed.fv_task);
      (match observed.fv_identity, observed.fv_task.fo_value with
       | Some _, Some (Decode.Ask_task_missing _ | Ask_task_unavailable _ | Ask_task_observed _) ->
           emit "Original Task reader" (Theme.info ())
             "Esc to return · T: inspect this answered Ask's original Task, history and verification evidence"
       | Some _, (Some Decode.Ask_task_unlinked | None)
       | None, (Some _ | None) -> ())) followup;
    Option.iter (fun failure ->
      emit "Follow-up read incomplete" (Theme.warn ())
        ("Completed sources retained\n" ^ Ask_projection.followup_failure_text failure)) state.ask_followup_error;
    List.rev !fields) (Masc_tui_types.current_ask_answer_feedback state)

let answer_feedback_reading (state : state) =
  Option.map (fun fields ->
    Masc_tui_detail_reading.create ~ko:(state.ui_language = Lang_ko)
      ~title:(ui_text state ~ko:"마지막 답변 결과" ~en:"Last answer")
      (List.map fst fields)) (ask_answer_feedback_document state)

let draw_ask_answer_feedback buf cols state =
  match ask_answer_feedback_document state with
  | Some ((section, style) :: _) ->
      box_line buf cols ("  v: " ^ style ^ Terminal_text.single_line section.body ^ Ansi.reset)
  | Some [] | None -> ()

let draw_compact_ask_origin buf cols state =
  Option.iter (fun (origin : Ask_projection.origin) ->
    let turn = match origin.ao_source_turn_ref with
      | None -> " · original turn not recorded"
      | Some reference -> Printf.sprintf " · turn #%d" (Ids.Turn_ref.absolute_turn reference) in
    box_line buf cols (Ansi.dim ^ "  o/O source: "
      ^ Terminal_text.single_line (origin.ao_keeper_name ^ turn ^ " · " ^ origin.ao_ask_id)
      ^ Ansi.reset)) (Masc_tui_types.current_ask_origin state)

(* Copy complete terminal rows from the original safe question rendering.
   Do not cut an ANSI/UTF-8 sequence, reflow the prompt or borrow choice/draft
   state from another question. This preview does not enter answering mode. *)
let draw_ask_question_preview buf cols ~rows text =
  let length = String.length text in
  let prompt_rows = if rows > 1 then rows - 1 else rows in
  let rec copy offset remaining =
    if remaining > 0 && offset < length then
      match String.index_from_opt text offset '\n' with
      | Some stop ->
          Buffer.add_substring buf text offset (stop - offset + 1);
          copy (stop + 1) (remaining - 1)
      | None ->
          Buffer.add_substring buf text offset (length - offset);
          Buffer.add_char buf '\n'
  in
  copy 0 prompt_rows;
  if rows > 1 then
    box_line buf cols (Ansi.dim ^ "    … a opens the full ask and answers" ^ Ansi.reset)

let draw_ask_questions buf cols (state : state) ~budget =
  let now = Unix.gettimeofday () in
  (* Questions Keepers put to a human sit under the approval queue rather than
     in it. Nothing is held waiting on them -- the Keeper that asked kept
     working -- so they are not a queue of blocked calls, but an operator
     deciding things belongs in one place either way. *)
  let answering_ask =
    match state.ask_answer_mode with
    | Ask_answering { aam_ask } -> Some aam_ask
    | Ask_browsing -> None
  in
  match Masc_tui_approvals_model.approvals_open_questions state with
  | None -> ()
  | Some open_rows -> (
      box_divider buf cols;
      (* The warning colour says someone is waiting. With nobody waiting the
         heading drew it anyway, over a line that reads "none", so the one
         row on the screen asking for attention was the one with nothing to
         ask. *)
      let heading_tone =
        match open_rows with
        | [] -> Theme.recede ()
        | _ :: _ -> Ansi.bold ^ Theme.warn ()
      in
      (* [a] opens the question under the cursor. With none under it the key
         answers "Choose a question with [ or ] first", so the heading names it
         only while one is selected, in the footer's words. *)
      let selected_index = Ask_projection.selected_index open_rows state.ask_cursor in
      let answer_hint =
        if Option.is_some selected_index then " · " ^ Masc_tui_keys.approval_answer_hint
        else ""
      in
      box_line buf cols
        (Printf.sprintf "  %s[?] Questions waiting on you (%d)%s%s" heading_tone
           (Masc_tui_approvals_model.approvals_open_question_count state) answer_hint Ansi.reset);
      match open_rows with
      | [] ->
          box_line buf cols
            (Printf.sprintf "  %snone -- nobody is waiting on a decision%s"
               Ansi.dim Ansi.reset)
      | rows ->
          (* Only the ask under the cursor keeps its questions; every other one
             folds to a line. Before this the panel drew all of them and the
             surface, which puts this block last, dropped whatever ran past its
             budget -- an ask of four questions was enough to push the rest off
             the bottom, the cursor with it, so [/] and j/k moved a selection
             nothing on screen showed. *)
          match selected_index with
          | None ->
              (* The selected ask left the list. No ask is drawn open, because
                 an open ask here is the one the next keys would answer. *)
              box_line buf cols
                (Printf.sprintf "  %snothing selected -- [ or ] chooses a question%s"
                   Ansi.dim Ansi.reset);
              let count = List.length rows in
              let room = max 0 (budget - count_frame_lines buf) in
              let shown = if count <= room then count else max 0 (room - 1) in
              List.iteri
                (fun index row -> if index < shown then box_line buf cols (ask_summary_line state ~cols ~now ~row))
                rows;
              if shown < count then
                box_line buf cols
                  (Printf.sprintf "  %s+%d more ask%s -- [/] to reach%s" Ansi.dim (count - shown)
                     (if count - shown = 1 then "" else "s") Ansi.reset)
          | Some cursor ->
          let count = List.length rows in
          let selected = List.nth rows cursor in
          let draft = Ask_projection.draft_for state.ask_draft ~row:selected in
          let answering =
            match answering_ask with
            | Some ask -> Masc.Tui_decode_asks.(equal_ask_key ask (ask_key selected))
            | None -> false
          in
          let questions = Array.of_list selected.Masc.Tui_decode_asks.ar_questions in
          let question_count = Array.length questions in
          let question_cursor =
            max 0 (min state.ask_question_cursor (question_count - 1))
          in
          let text_entry = state.ask_text_entry in
          (* Each lazy cell is private to this synchronous draw. The layout
             and emission below are its only force sites; no cell/provider
             escapes to a fiber, worker or later frame. Capture original
             immutable inputs rather than mutable UI state in the cells. *)
          let question_blocks =
            Array.mapi
              (fun index question ->
                lazy (ask_block (fun b ->
                    draw_ask_question b cols ~text_entry ~row:selected ~draft ~question
                      ~answering
                      ~selected_question:(index = question_cursor))))
              questions
          in
          let question_block index = Stdlib.Lazy.force question_blocks.(index) in
          let context_block =
            lazy (ask_block (fun b -> draw_ask_context b cols ~row:selected))
          in
          let plan =
            Ask_layout.plan ~budget ~spent:(count_frame_lines buf)
              ~question_count ~question_height:(fun index -> snd (question_block index))
              ~question_cursor
              ~context_height:(fun () -> snd (Stdlib.Lazy.force context_block))
              ~other_asks:(count - 1)
          in
          for index = plan.Ask_layout.question_start to
              plan.Ask_layout.question_start + plan.Ask_layout.questions_shown - 1 do
            let text, _ = question_block index in
            if plan.Ask_layout.question_preview_rows > 0 then
              draw_ask_question_preview buf cols
                ~rows:plan.Ask_layout.question_preview_rows text
            else Buffer.add_string buf text
          done;
          if plan.Ask_layout.question_notice then
            box_line buf cols
              (* "in this ask", because the count above names every question
                 the fleet is waiting on and this one names the selected
                 ask's own. Both said "questions", and a reader saw "(1)"
                 three rows above "+2 more questions". *)
              (Printf.sprintf "    %s+%d more in this ask -- a opens the full ask%s"
                 Ansi.dim plan.Ask_layout.questions_hidden Ansi.reset);
          if plan.Ask_layout.context_shown then
            Buffer.add_string buf (fst (Stdlib.Lazy.force context_block))
          else if plan.Ask_layout.context_notice then
            (* The questions are the ask and the reason explains it, so the
               reason is what the plan drops first. It used to drop without a
               word: hidden questions are counted on a line of their own and
               folded asks are too, and only this one left no trace, so a
               reader had nothing to tell them there was a reason to go and
               read. The answering view draws it whole and scrolls. *)
            box_line buf cols
              (Printf.sprintf "    %sthe reason did not fit -- a opens it%s"
                 Ansi.dim Ansi.reset);
          let printed = ref 0 in
          List.iteri
            (fun index row ->
              if index <> cursor && !printed < plan.Ask_layout.summaries_shown
              then begin
                box_line buf cols (ask_summary_line state ~cols ~now ~row);
                incr printed
              end)
            rows;
          if plan.Ask_layout.summaries_hidden > 0 then
            box_line buf cols
              (Printf.sprintf "  %s+%d more ask%s -- [/] to reach%s" Ansi.dim
                 plan.Ask_layout.summaries_hidden
                 (if plan.Ask_layout.summaries_hidden = 1 then "" else "s")
                 Ansi.reset))

(* The selected row's detail, and the only one of the three detail rows whose
   height depends on which kind is selected. A held tool call answers two
   questions -- what is being asked, and why it was held -- and the ask runs
   the width of the pane, so at eighty columns the two cannot share a row.

   Built here rather than inline so the surface draws it into the block it
   then measures with [count_frame_lines], which is where its height comes
   from.
   Until 2026-08-31 the second row was spelled as a literal ["\\n"] --
   backslash and n, printed as those two characters -- because a real newline
   would have drawn a row nobody counted. *)
let approval_detail_line (state : state) ~approvals ~cols ~action_inflight =
    match List.nth_opt approvals state.approval_cursor with
    | Some (Masc_tui_approvals_model.Operator_row a) -> (
        if action_inflight then
          Printf.sprintf "  %sApproval request in progress…%s" (Theme.warn ())
            Ansi.reset
        else
          match state.pending_approval_action with
          | Some { paa_token; paa_decision }
            when String.equal paa_token a.ap_token ->
              let key =
                match paa_decision with
                | Confirm -> "y"
                | Deny -> "n"
              in
              Printf.sprintf "  %sPress %s again: %s%s" (Theme.warn ()) key
                (fit_width (Terminal_text.single_line a.ap_summary) (framed_inner_width cols - 18))
                Ansi.reset
          | _ ->
              let summary =
                fit_width (Terminal_text.single_line a.ap_summary) (max 8 (framed_inner_width cols - 30))
              in
              Printf.sprintf "  %s%s%s  %s[y] Approve  [n] Reject%s"
                Ansi.dim summary Ansi.reset
                (Theme.info ()) Ansi.reset)
    | Some (Masc_tui_approvals_model.Keeper_tool_row held) ->
        (* One press answers a held call, matching the chat pane's [y]. The
           question is the whole ask, so it is the row the eye lands on;
           the because is why this call was held at all — an operator
           repeating the same yes needs the reason visible, not the name
           of a policy table they cannot open. *)
        (* Two rows. This carried a literal "\n" -- backslash and n, printed as
           those two characters -- because a real newline would have drawn a
           row nobody had budgeted for. [detail_extra_rows] above budgets it. *)
        Printf.sprintf "  %s%s%s  %s[y] Allow  [n] Deny%s\n  %swhy: %s%s"
          (Theme.warn ())
          (fit_width
             (Terminal_text.single_line held.kta_question)
             (max 8 (framed_inner_width cols - 24)))
          Ansi.reset
          (Theme.info ()) Ansi.reset
          Ansi.dim
          (fit_width
             (Terminal_text.single_line_or ~default:"(not provided)"
                held.kta_because)
             (max 8 (framed_inner_width cols - 8)))
          Ansi.reset
    | Some (Masc_tui_approvals_model.Gate_row pending) ->
        (* A durable Gate ask: it keeps until answered, and the answer goes
           through the dashboard resolve route. What the eye needs is who
           wants to touch what, and that the decision spends here. *)
        (* The name is not padded here. This is one line with nothing under
           it to line up with, so a fixed twenty both cut
           "rw-e0-r9-20260820-review" and left short names trailing spaces.
           The list above it now sizes its column to the names it holds and
           this line disagreed with it three rows apart.

           What follows absorbs the difference, which is the same order the
           list uses: the identifier is why the line exists. *)
        let keeper =
          Terminal_text.single_line pending.Tui_decode.gp_keeper
        in
        let phase, tone = approval_gate_phase state pending.Tui_decode.gp_phase in
        let actions = "  " ^ (Theme.info ()) ^ "[y] Approve  [n] Reject" ^ Ansi.reset in
        let headline =
          Printf.sprintf "  %s%s → %s · %s%s%s"
            tone
            keeper
            (fit_width
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
               (max 8 (framed_inner_width cols - 52 - Message_layout.display_width keeper
                       - Message_layout.display_width phase)))
            phase
            Ansi.reset
            actions
        in
        (match pending.gp_phase with
         | Gate_blocked ->
             let detail =
               Terminal_text.single_line_or ~default:"(the server recorded no detail)"
                 pending.gp_auto_judge_detail
             in
             let next =
               match pending.gp_retry_request with
               | Some _ -> "R: retry Auto Judge; y/n: decide now"
               | None -> "y/n: decide now (this exact attempt cannot be replayed)"
             in
             Printf.sprintf "%s\n  %sreason: %s%s\n  %s%s%s"
               headline Ansi.dim
               (fit_width detail (max 8 (framed_inner_width cols - 8))) Ansi.reset
               Ansi.dim (fit_width next (max 8 (framed_inner_width cols))) Ansi.reset
         | Gate_human_required ->
             (match pending.gp_judge_advice with
              | Some advice ->
                  Printf.sprintf "%s\n  %sjudge: %s%s"
                    headline Ansi.dim
                    (fit_width (Terminal_text.single_line advice.rationale) (max 8 (framed_inner_width cols - 7)))
                    Ansi.reset
              | None -> headline)
         | Gate_queued | Gate_judging -> headline)
    | None -> ""
;;

(* The selected request's decision context and input preview. Technical
   identifiers belong to the full reader; execution site, age and deadlines
   remain here. Pack clauses with the same measured rows the queue budgets. *)
let approval_metadata_lines (state : state) ~approvals ~cols =
  let clauses, payload_line =
    match List.nth_opt approvals state.approval_cursor with
    | None -> [], ""
    | Some (Masc_tui_approvals_model.Operator_row approval) ->
        (* The same clock as [created] beside it. This one kept the server's
           RFC 3339 string as it arrived -- UTC, and in Seoul nine hours off
           the local reading next to it -- so a row could show a decision
           created at 09:03 expiring at 00:03 and read as already gone. It is
           also the longer of the two spellings, which is what pushed this row
           past every terminal width once it was spelled in full (#36333); the
           row now breaks instead of losing it. A decision with no deadline
           still draws the no-value mark: that is not a time. *)
        let expires =
          match Terminal_text.optional_single_line approval.ap_expires_at with
          | None -> Masc_tui_theme.Glyph.no_value
          | Some at -> Terminal_text.short_timestamp at
        in
        let payload =
          Masc_tui_operator_projection.approval_payload_for_terminal
            approval.ap_payload
        in
        ( [ Printf.sprintf "created=%s"
              (Terminal_text.short_timestamp approval.ap_created_at)
          ; Printf.sprintf "expires=%s" expires ]
        , Printf.sprintf "  %spayload=%s%s" Ansi.dim
            (fit_width payload (max 8 (framed_inner_width cols - 8)))
            Ansi.reset )
    | Some (Masc_tui_approvals_model.Keeper_tool_row held) ->
        ( [ Printf.sprintf "keeper=%s"
              (Terminal_text.single_line held.kta_keeper)
          ; Printf.sprintf "tool=%s" (Terminal_text.single_line (Masc.Tool_display.label held.kta_tool))
          ; Masc_tui_answering.duration_text (max 0. (Unix.gettimeofday () -. held.kta_asked_at))
            ^ ui_text state ~ko:" 대기" ~en:" waiting" ]
        , Printf.sprintf "  %sargs=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.preview_line held.kta_args)
               (max 8 (framed_inner_width cols - 5)))
            Ansi.reset )
    | Some (Masc_tui_approvals_model.Gate_row pending) ->
        (* Execution site affects the decision. Keep it in the selected
           preview; the exact approval ID remains in the full reader. *)
        let site =
          match
            pending.Tui_decode.gp_execution_sandbox,
            pending.Tui_decode.gp_execution_cwd
          with
          | None, None -> []
          | sandbox, cwd ->
            [ Printf.sprintf "sandbox=%s"
                (Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value sandbox)
            ; Printf.sprintf "at=%s"
                (Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value cwd) ]
        in
        (* The operation is already the right-hand side of the line above
           whenever the two agree, which is every operation but an identity
           call. Repeating it there costs the width this line needs. *)
        let operation =
          let name = Terminal_text.single_line pending.Tui_decode.gp_operation in
          if String.equal name
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
          then []
          else [ Printf.sprintf "operation=%s" name ]
        in
        ( operation @ site
          @ (match pending.gp_waiting_s with
             | None -> []
             | Some seconds -> [Masc_tui_answering.duration_text seconds
                 ^ ui_text state ~ko:" 경과" ~en:" old"])
        , Printf.sprintf "  %sinput=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.single_line_or ~default:"(no input preview)"
                  pending.Tui_decode.gp_input_preview)
               (max 8 (framed_inner_width cols - 6)))
            Ansi.reset )
  in
  let metadata_rows =
    match clauses with
    | [] -> [ "" ]
    | clauses ->
        Message_layout.pack_clauses ~max_cells:(framed_inner_width cols) clauses
        |> List.map (fun row -> Printf.sprintf "  %s%s%s" Ansi.dim row Ansi.reset)
  in
  String.concat "\n" metadata_rows, payload_line
;;

module Window = Masc_tui_approvals_window

let render_approvals (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let approvals = Masc_tui_approvals_model.approval_items state in
  let action_inflight =
    Masc_tui_operator_projection.Flow.action_inflight state.approval_flow
  in
  let detail_line =
    approval_detail_line state ~approvals ~cols ~action_inflight
  in
  let metadata_line, payload_line =
    approval_metadata_lines state ~approvals ~cols
  in

  let count = Masc_tui_approvals_model.approvals_surface_pending state in
  let reading = Masc_tui_approvals_model.approvals_reading state in
  let source_notices = approval_source_notices state ~reading in
  let count_text =
    if Masc_tui_approvals_model.approvals_reading_current state then
      Printf.sprintf (if state.ui_language = Lang_ko then "대기 %d" else "%d pending") count
    else Printf.sprintf (if state.ui_language = Lang_ko then
        "관측 %d · 조회 미확인 %d곳" else "%d observed · %d sources not current")
      count (List.length source_notices) in
  let hidden_note = match state.approval_snapshot with
    | Some snapshot when snapshot.aps_hidden_count > 0 ->
        Printf.sprintf (if state.ui_language = Lang_ko then ", 승인 %d개 숨김 · 필터 %s"
          else ", %d confirmations hidden · filter %s") snapshot.aps_hidden_count
          (Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value snapshot.aps_actor_filter)
    | Some _ | None -> "" in
  let header =
    here_row ~cols state
      ~path:[ ui_text state ~ko:"요청" ~en:"requests" ]
      ~readings:
        [ count_text ^ hidden_note
        ; (if action_inflight then ui_text state ~ko:"제출 중" ~en:"submitting"
           else "") ]
      ~position:None
  in
  box_top buf cols;
  box_line buf cols header;
  let policy_buf = Buffer.create 512 in
  (* Both Gate lanes are always on screen here. The durable rows obey the
     external lane, and an operator deciding them needs to see which switch
     they are under. The [e] that cycles the external lane is a footer key
     like any other: it reaches the footer and the [?] help through the
     Approvals row of Masc_tui_keys. *)
  (* A lane word this build does not know is drawn as the server wrote it,
     the same spelling the chat header and the Keeper detail draw. *)
  let lane_mode_label = function
    | Tui_decode.Gate_mode mode -> Masc_tui_palette.gate_mode_label mode
    | Tui_decode.Unrecognised_gate_mode raw -> Terminal_text.single_line raw
  in
  (* The two lanes share a row while both fit. A narrower terminal gives each
     lane its own row, so a mode is not cut off in the middle of its words. *)
  let lane_rows modes =
    let lane ~key gate mode =
      Printf.sprintf "[%s] %s: %s" key (Masc_tui_palette.gate_lane_label gate)
        (lane_mode_label mode)
    in
    let workspace =
      lane ~key:"w" Masc_tui_palette.Workspace_gate modes.Tui_decode.glm_workspace
    in
    let external_lane =
      lane ~key:"e" Masc_tui_palette.External_gate modes.Tui_decode.glm_external
    in
    let together = Printf.sprintf "  %s  |  %s" workspace external_lane in
    List.map
      (fun row -> Theme.info () ^ row ^ Ansi.reset)
      (if Message_layout.display_width together <= framed_inner_width cols
       then [ together ]
       else [ "  " ^ workspace; "  " ^ external_lane ])
  in
  List.iter (box_line policy_buf cols)
    (match state.gate_modes, Terminal_text.optional_single_line state.gate_error with
     | Some modes, _ -> lane_rows modes
     (* No prefix: [data_unreliable_row] already opens "(data unreliable: "
        and the loader's message already opens "gate load failed:", so a third
        "gate:" in front read as a stutter -- "(data unreliable: gate: gate
        load failed: ...)". Same rule the schedule warning is written to. The
        two rows below keep their prefixes because the detail there is the
        server's own sentence about the store, which does not name itself. *)
     | None, Some err -> [ data_unreliable_row ~cols err ]
     | None, None ->
         [ Ansi.dim ^ "  Gate lanes: loading" ^ Ansi.reset ]);
  (* Standing always-allow rules, on the row under the lanes. A rule answers
     its call before the call can reach the queue, so an operator reading an
     empty queue is reading the rules' work without seeing them. One row: the
     count, and who the newest one covers. *)
  box_line policy_buf cols
    (match state.gate_rules_unavailable, state.gate_rules with
     | Some detail, _ ->
         data_unreliable_row ~cols ("always-allow rules: " ^ detail)
     | None, [] ->
         Ansi.dim ^ "  Always-allow rules: none" ^ Ansi.reset
     | None, (newest :: _ as rules) ->
         Printf.sprintf
           "  %sAlways-allow rules: %d  ·  newest %s / %s%s%s"
           Ansi.dim
           (List.length rules)
           newest.Tui_decode.gr_keeper
           newest.Tui_decode.gr_tool
           (match newest.Tui_decode.gr_expires_at with
            | Some _ -> " (expires)"
            | None -> "")
           Ansi.reset);
  box_divider policy_buf cols;

  let footer_buf = Buffer.create 256 in
  Buffer.add_string footer_buf
    (footer_line state ~max_cells:cols ~hints:(question_hints state));
  let footer_rows = count_frame_lines footer_buf in
  let preview_minimum =
    if Option.is_some state.pending_approval_action || action_inflight then 1 else 0 in
  let base_head_rows = count_frame_lines buf + count_frame_lines policy_buf in
  (* Reserve the selected question, decision notice and footer first. Last
     answer/source summaries use only the remaining complete terminal rows;
     their full text stays available in the receipt/question readers. *)
  let question_room = max 0
      (rows - base_head_rows - footer_rows - 2 - preview_minimum) in
  let question_rows = min question_room
      (match Masc_tui_approvals_model.approvals_open_questions state with
       | None -> 0
       | Some [] -> 3
       | Some (_ :: _) -> 2 + Ask_layout.min_expanded_rows) in
  let intro_room = max 0 (question_room - question_rows) in
  let intro_buf = Buffer.create 256 in
  if intro_room > 0 then draw_ask_answer_feedback intro_buf cols state;
  if count_frame_lines intro_buf < intro_room then
    draw_compact_ask_origin intro_buf cols state;
  let intro_rows = count_frame_lines intro_buf in
  let primary_rows = 1 (* queue *) + 1 (* closing edge *) + footer_rows
      + intro_rows + question_rows + preview_minimum in
  let notice_room = max 0 (rows - base_head_rows - primary_rows) in
  List.iteri (fun index (style, text) ->
    if index < notice_room then box_line_styled buf cols ~style ("  " ^ text)) source_notices;
  Buffer.add_buffer buf policy_buf;
  let head_rows = count_frame_lines buf in
  let preview = Buffer.create 1024 in
  List.iter (fun line ->
    if not (String.equal line "") then Buffer.add_string preview (line ^ "\n"))
    [detail_line; metadata_line; payload_line];
  let preview_room = max 0 (rows - head_rows - footer_rows - 1 - 1 - intro_rows - question_rows) in
  let preview_count = count_frame_lines preview in
  let preview_notice = preview_count > preview_room && preview_room > 1 in
  let shown_preview = min preview_count (if preview_notice then preview_room - 1 else preview_room) in
  let below_buf = Buffer.create 1024 in
  box_bottom below_buf cols;
  let text = Buffer.contents preview in
  let rec copy_rows offset remaining =
    if remaining > 0 && offset < String.length text then
      match String.index_from_opt text offset '\n' with
      | Some stop ->
          Buffer.add_substring below_buf text offset (stop - offset + 1);
          copy_rows (stop + 1) (remaining - 1)
      | None ->
          Buffer.add_substring below_buf text offset (String.length text - offset);
          Buffer.add_char below_buf '\n'
  in
  copy_rows 0 shown_preview;
  if preview_notice then
    Buffer.add_string below_buf (Theme.recede ()
      ^ fit_width (ui_text state ~ko:"  Enter: 요청 전체 읽기" ~en:"  Enter: read the complete request")
          (max 1 (framed_inner_width cols)) ^ Ansi.reset ^ "\n");
  let around_rows = head_rows + count_frame_lines below_buf + footer_rows in
  let ask_budget = max 0 (rows - around_rows - 1) in
  let ask_buf = Buffer.create 1024 in
  Buffer.add_buffer ask_buf intro_buf;
  draw_ask_questions ask_buf cols state ~budget:ask_budget;
  let ask_rows = count_frame_lines ask_buf in
  let approval_body_rows = max 0 (rows - around_rows - ask_rows) in

  (* The queue's own population, not the surface's. [count] above is the
     approval rows plus the open questions -- the right reading for the title,
     which names the screen -- and this block is about the three
     lists that hold approval rows. With the queue empty and a question
     waiting, [count] was three, so the list drew its empty self: a cursor
     mark on a blank row and nothing to say the queue was empty, where the
     same screen with no question at all said "(no pending approvals)".

     "(no pending approvals)" is itself a reading of all three lists. A Gate
     poll that failed after one that answered keeps its empty rows, so the
     queue is empty on screen while the server may hold Gate approvals; each
     list that was not read says so here instead. *)
  if approvals = [] then begin
    let lines =
      match Masc_tui_approvals_model.approvals_empty_queue reading with
      | Masc_tui_approvals_model.Nothing_pending ->
          [ Ansi.dim ^ "  (no pending approvals)" ^ Ansi.reset ]
      | Masc_tui_approvals_model.Lists_not_read not_read ->
          List.map
            (fun (name, (not_read : Masc_tui_approvals_model.approval_not_read)) ->
              match not_read with
              | Masc_tui_approvals_model.Approval_unread ->
                  Printf.sprintf "%s  (%s not read yet \xe2\x80\x94 press 'r' to refresh)%s"
                    Ansi.dim name Ansi.reset
              (* The loader's message already names what failed ("... load
                 failed: ..."), so the row carries it as it came. *)
              | Masc_tui_approvals_model.Approval_failed cause
              | Masc_tui_approvals_model.Approval_stale cause ->
                  data_unreliable_row ~cols (Terminal_text.single_line cause)
              | Masc_tui_approvals_model.Approval_unavailable detail ->
                  data_unreliable_row ~cols
                    (Printf.sprintf "%s unavailable: %s" name
                       (Terminal_text.single_line detail)))
            not_read
    in
    let lines = List.take approval_body_rows lines in
    List.iter (fun line -> box_line buf cols line) lines;
    for _ = 1 to max 0 (approval_body_rows - List.length lines) do
      box_empty buf cols
    done
  end else begin
    (* A queue longer than its rows says which of them these are, the way the
       Keepers roster does: the line costs one of the rows it describes, so it
       is drawn only where there is something to say and a row to spend on it.
       Without it the rows past the window were not drawn at all and nothing
       said so -- an operator on a short frame could read the first screen,
       believe it whole, and decide against a queue they had not seen. *)
    let approval_total = List.length approvals in
    let overflowing = Window.overflows ~body_rows:approval_body_rows ~total:approval_total in
    let content_height = Window.rows ~body_rows:approval_body_rows ~total:approval_total in
    let scroll_offset =
      if content_height > 0 && state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    let approval_row_name = function
      | Masc_tui_approvals_model.Operator_row item -> Terminal_text.single_line item.ap_actor
      | Masc_tui_approvals_model.Keeper_tool_row held -> Terminal_text.single_line held.kta_keeper
      | Masc_tui_approvals_model.Gate_row pending -> Terminal_text.single_line pending.gp_keeper in
    (* The request keeps at least as much room as its author at narrow widths.
       Both columns are display-only; selection still addresses the original row. *)
    let phase_width = List.fold_left (fun widest -> function
      | Masc_tui_approvals_model.Gate_row pending ->
          max widest (Message_layout.display_width (fst (approval_gate_phase state pending.gp_phase)))
      | Keeper_tool_row _ | Operator_row _ -> widest) 0 approvals in
    let name_width =
      List.fold_left (fun widest row ->
        max widest (Message_layout.display_width (approval_row_name row))) 16 approvals
      |> min 26
      |> min (max 0 ((framed_inner_width cols - 6) / 2))
      |> min (max 0 (framed_inner_width cols - 6 - phase_width)) in
    let subject_width = max 1 (framed_inner_width cols - name_width - 6) in
    let approvals_window = Rows.of_list ~first:scroll_offset ~height:content_height approvals in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < approval_total then begin
        let line =
          match Rows.at approvals_window idx with
          | None -> ""
          | Some row ->
              let subject = match row with
                | Masc_tui_approvals_model.Operator_row item ->
                    Terminal_text.single_line_or
                      ~default:(Terminal_text.single_line item.ap_action_type) (Some item.ap_summary)
                | Masc_tui_approvals_model.Keeper_tool_row held ->
                    Terminal_text.single_line held.kta_question
                | Masc_tui_approvals_model.Gate_row pending ->
                    let phase, tone = approval_gate_phase state pending.gp_phase in
                    let tool_width = subject_width - Message_layout.display_width phase - 3 in
                    if tool_width <= 0 then tone ^ phase ^ Ansi.reset
                    else fit_width (Terminal_text.single_line pending.gp_display_tool) tool_width
                      ^ " · " ^ tone ^ phase ^ Ansi.reset
              in
              Printf.sprintf "  %s  %s" (fit_width subject subject_width)
                (fit_width (approval_row_name row) name_width)
        in
        (* One row and more rows than it: no room for the window line, so the
           row says where it sits in the queue itself. *)
        let line =
          if Window.hides_rows ~body_rows:approval_body_rows ~total:approval_total
             && not overflowing
          then Printf.sprintf "%s[%d/%d]%s %s" Ansi.dim (idx + 1) approval_total Ansi.reset line
          else line
        in
        let is_selected = idx = state.approval_cursor in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr ("> " ^ line))
        else
          box_line buf cols ("  " ^ line)
      end else
        box_empty buf cols
    done;
    if overflowing then
      box_line_styled buf cols ~style:(Theme.recede ())
        ("  "
         ^ Window.note ~scroll:scroll_offset ~height:content_height
             ~total:approval_total)
  end;

  Buffer.add_buffer buf below_buf;

  Buffer.add_buffer buf ask_buf;

  Buffer.add_buffer buf footer_buf;

  finish_surface state ~surface_key:"approvals" ~rows:terminal_rows
      ~cols buf

(* Source diagnostics that cannot take space from the selected compact Ask
   remain reachable in the same full reader and its actual scroll domain. *)
let question_reader_viewport state =
  let lines, room = ask_question_viewport state in
  (* The editor follows the last question row while typing. Diagnostics must
     not become the new end and scroll the active editor out of view. *)
  let notices = match state.ask_text_entry with
    | Some _ -> []
    | None -> approval_source_notices state
        ~reading:(Masc_tui_approvals_model.approvals_reading state) in
  let buf = Buffer.create 512 in
  let _, cols = get_terminal_size () in
  if notices <> [] then box_divider buf cols;
  List.iter (fun (style, text) -> box_wrapped_field buf cols ~head:"  " ~style text) notices;
  let notice_lines = String.split_on_char '\n' (Buffer.contents buf)
      |> List.filter (fun line -> line <> "") in
  lines @ notice_lines, room

let ask_question_page_size state = snd (question_reader_viewport state)

let ask_question_scroll_limit state =
  let lines, room = question_reader_viewport state in
  max 0 (List.length lines - room)

let render_question_reader (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let asks = open_ask_rows state in
  let selected_index = Ask_projection.selected_index asks state.ask_cursor in
  let selected = Option.bind selected_index (List.nth_opt asks) in
  box_top buf cols;
  box_line buf cols (screen_title
    (" MASC Approvals / Questions"
     ^ Masc_tui_approvals_model.approval_list_note ~name:"questions" (Masc_tui_approvals_model.approvals_questions_reading state)));
  box_line buf cols
    (match selected with
     | None ->
         (match Masc_tui_approvals_model.approvals_questions_reading state with
          | Masc_tui_approvals_model.List_read when asks <> [] ->
              "  Nothing selected -- [ or ] chooses a question"
          | Masc_tui_approvals_model.List_read -> "  No questions waiting"
          | List_not_read Approval_unread -> "  Questions not loaded"
          | List_not_read (Approval_failed _ | Approval_stale _ | Approval_unavailable _) ->
              "  Question source unavailable")
     | Some row ->
         let draft = Ask_projection.draft_for state.ask_draft ~row in
         let drafted = List.filter (fun question ->
             Option.is_some (Ask_projection.response_for draft ~question)) row.ar_questions |> List.length in
         Printf.sprintf "  %s%s · Ask %d/%d · Question %d/%d · %d drafted%s"
           (Theme.warn ()) (Terminal_text.single_line (Masc.Tui_decode_asks.ask_asker_label row.ar_asker))
           (Option.fold ~none:0 ~some:succ selected_index) (List.length asks) (state.ask_question_cursor + 1)
           (List.length row.ar_questions) drafted Ansi.reset);
  box_line buf cols
    (match state.asks_error with
     | Some error -> "  Question source unavailable · " ^ Terminal_text.single_line error
     | None ->
       if Option.is_some state.ask_text_entry then "  Enter: save written answer · Esc: cancel writing"
       else
         "  Left/Right: previous/next question · [/]: previous/next ask · "
         ^ "PgUp/PgDn: page · Home/End: top/bottom · Esc: "
         ^ (match state.followed_from with
          | Some (Overview, _) -> "Dashboard"
          | Some ((Acting | Metrics | Keepers _ | Memory | Lanes | Clients | Board
              | Approvals | Planning | Schedules | Verification | Harness | Fusion
              | Repositories | Code | Changes | Connectors | Runtime | Config
              | Resources | Tools | System_logs), _)
            | None -> "approvals"));
  box_divider buf cols;
  let lines, room = question_reader_viewport state in
  let limit = max 0 (List.length lines - room) in
  let scroll =
    if Option.is_some state.ask_text_entry then limit
    else max 0 (min state.ask_question_scroll limit)
  in
  let lines_window = Rows.of_list ~first:scroll ~height:room lines in
  for i = 0 to room - 1 do
    match Rows.at lines_window (scroll + i) with
    | Some line -> Buffer.add_string buf (line ^ "\n")
    | None -> box_empty buf cols
  done;
  box_divider buf cols;
  box_line buf cols
    (if Option.is_some state.ask_text_entry then "  Writing answer · Enter saves locally before you send"
     else
       Printf.sprintf "  Lines %s · PgUp/PgDn or wheel to read"
         (Masc_tui_scroll.window_text ~scroll ~height:room (List.length lines)));
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints:(question_hints state));
  finish_surface state ~surface_key:"approval-questions" ~rows:terminal_rows ~cols buf
