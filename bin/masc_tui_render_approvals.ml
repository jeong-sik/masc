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

(** Render the Approvals surface (pending confirmations). *)
(* The ask, whole. The list row is one line through [single_line], which
   turns a newline into the six characters [\x0A] and then cuts; an [Edit]
   carrying a page of code read as its first forty characters and there was
   no second screen. This is that screen. *)
let approval_detail_pane (state : state) ~clamped ~rows ~cols (row : Masc_tui_approvals_model.approval_row) buf =
  let width = max 8 (cols - 6) in
  (* The fields are handed to [Approval_detail.of_fields] as they are built,
     not bound first: it is where every value is made terminal-safe, and the
     field guard in test_tui_http_ast.ml reads a wire field as sanitised only
     inside that call. *)
  let lines =
    Approval_detail.of_fields ~width
      (match row with
    | Masc_tui_approvals_model.Keeper_tool_row held ->
      [ "keeper", held.Tui_decode.kta_keeper
      ; "tool", held.Tui_decode.kta_tool
      ; "call", held.Tui_decode.kta_tool_call_id
      ; "question", held.Tui_decode.kta_question
      ; "args", held.Tui_decode.kta_args
      ]
    | Masc_tui_approvals_model.Gate_row pending ->
      let phase =
        match pending.Tui_decode.gp_phase with
        | Gate_queued -> "queued"
        | Gate_judging -> "judging"
        | Gate_human_required -> "human required"
        | Gate_blocked -> "auto judge blocked"
      in
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
        | Gate_queued | Gate_judging | Gate_human_required -> []
      in
      [ "keeper", pending.Tui_decode.gp_keeper
      ; "tool", pending.Tui_decode.gp_display_tool
      ; "operation", pending.Tui_decode.gp_operation
      ; "state", phase
      ]
      @ blocked_fields
      @ [
        ( "approval", pending.Tui_decode.gp_id )
      ; ( "sandbox"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_sandbox )
      ; ( "working directory"
        , Terminal_text.single_line_or ~default:"(not recorded)"
            pending.Tui_decode.gp_execution_cwd )
      ]
      @ (match pending.Tui_decode.gp_input_rows with
         | Tui_decode.Rows (_ :: _ as fields) ->
           List.map
             (fun (key, value) -> (Terminal_text.single_line key, value))
             fields
         | Tui_decode.Rows [] -> [ "input", "(the stored input object is empty)" ]
         | Tui_decode.Flattened preview ->
           [ ( "input (flattened preview, may be cut)"
             , Terminal_text.single_line_or
                 ~default:"(the server recorded no input preview)" preview )
           ])
    | Masc_tui_approvals_model.Operator_row a ->
      [ "actor", a.Masc_tui_operator_projection.ap_actor
      ; "action", a.Masc_tui_operator_projection.ap_action_type
      ; "target", a.Masc_tui_operator_projection.ap_target_type
      ; "summary", a.Masc_tui_operator_projection.ap_summary
      ; "payload",
        Yojson.Safe.pretty_to_string a.Masc_tui_operator_projection.ap_payload
      ])
  in
  box_top buf cols;
  (* Opens on MASC and its name, like every other surface; the way out is the
     footer's to say, and saying it here too spelled the same key twice in two
     notations. *)
  box_line buf cols (screen_title " MASC Approval");
  box_divider buf cols;
  let content_height = max 1 (rows - 6) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length lines) ~height:content_height
      state.approval_detail_scroll
  in
  (* The pane is where the field count and the drawn height meet, so the row
     it could actually use is reported back rather than recomputed outside. *)
  clamped := scroll;
  (* The pane scrolls, but nothing on it said the ask ran past the frame: an
     operator could read the first screen, believe it whole, and press y. The
     window line the other reading panes carry is what says there is more, so
     the footer gets it when the field list outgrows the frame. *)
  let total = List.length lines in
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
    (fun (line : Approval_detail.line) ->
      let text = line.Approval_detail.text in
      match line.Approval_detail.label with
      | Some label ->
        (* The name is bold, what sits beside it is not: the row carries both
           now, and bolding the whole of it would weight the value too. *)
        let drawn = fit_width text (cols - 6) in
        let name = String.length label in
        (* Split only where the whole name survived the cut. A narrow pane
           can end the row inside the name, and [fit_width]'s ellipsis is
           three bytes: splitting at the name's byte length there would cut
           the ellipsis and send half a character to the terminal. *)
        box_line buf cols
          (if String.starts_with ~prefix:label drawn then
             Printf.sprintf "  %s%s%s%s" Ansi.bold label Ansi.reset
               (String.sub drawn name (String.length drawn - name))
           else Printf.sprintf "  %s%s%s" Ansi.bold drawn Ansi.reset)
      | None ->
        box_line buf cols (Printf.sprintf "  %s" (fit_width text (cols - 6))))
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
  let overflow_hint =
    if cols < keeper_split_threshold_cols then
      approval_detail_pane state ~clamped:scroll ~rows ~cols row buf
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
        approval_detail_pane state ~clamped:scroll ~rows
          ~cols:(cols - left_cols) row right_buf
      in
      write_two_panes buf ~left_cols ~left:left_buf ~right:right_buf;
      hint
    end
  in
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(overflow_hint ^ Masc_tui_keys.footer_hints_approval_detail));
  finish_surface state ~clamped:(Approval_detail_scroll !scroll)
    ~surface_key:"approval-detail" ~rows:terminal_rows ~cols buf

(* Six cells hold [Message_layout.span_text]'s widest reading ("99d23h"), the
   same cell the Board and Keeper roster ages take. *)
let ask_age_cells = 6

(* One line for an ask the cursor is not on: who is waiting, how long, and
   how much they asked. What the operator needs from a folded ask is that it
   exists and can be reached; the choices belong to the one they are on.

   The age is here because a keeper can have more than one ask open, and
   without it the rows for them are the same line twice. Measured on the live
   Approvals screen: e-masc-the-leader held two, three hours apart, and both
   read "e-masc-the-lead...  1 question waiting". It is also the reading an
   operator picks the next ask by -- [ar_asked_at] was decoded and drawn
   nowhere. *)
let ask_summary_line ~now ~(row : Masc.Tui_decode_asks.ask_row) =
  let count = List.length row.Masc.Tui_decode_asks.ar_questions in
  Printf.sprintf " %s%s  %s  %d question%s waiting%s" Ansi.dim
    (fit_width (Terminal_text.single_line row.Masc.Tui_decode_asks.ar_keeper) 16)
    (fit_width
       (* [age_text], not a subtraction into [span_text]: the two ends are
          named, so the difference cannot be taken the wrong way round, and a
          clock that has moved backwards says nothing rather than drawing
          every row as "0s" -- which is the same two-rows-alike this column
          exists to end. *)
       (Option.value ~default:""
          (Message_layout.age_text ~now
             ~since:row.Masc.Tui_decode_asks.ar_asked_at))
       ask_age_cells)
    count
    (if count = 1 then "" else "s")
    Ansi.reset

let draw_ask_questions buf cols (state : state) ~budget =
  let now = Unix.gettimeofday () in
  (* Questions Keepers put to a human sit under the approval queue rather than
     in it. Nothing is held waiting on them -- the Keeper that asked kept
     working -- so they are not a queue of blocked calls, but an operator
     deciding things belongs in one place either way. *)
  let answering_ask_id =
    match state.ask_answer_mode with
    | Ask_answering { aam_ask_id } -> Some aam_ask_id
    | Ask_browsing -> None
  in
  match Masc_tui_approvals_model.approvals_open_questions state with
  | None -> ()
  | Some open_rows -> (
      box_divider buf cols;
      box_line buf cols
        (Printf.sprintf "  %s%s[?] Questions waiting on you (%d) · a:open answers%s" Ansi.bold (Theme.warn ())
           (Masc_tui_approvals_model.approvals_open_question_count state) Ansi.reset);
      match open_rows with
      | [] ->
          box_line buf cols
            (Printf.sprintf "  %snone -- no Keeper is waiting on a decision%s"
               Ansi.dim Ansi.reset)
      | rows ->
          (* Only the ask under the cursor keeps its questions; every other one
             folds to a line. Before this the panel drew all of them and the
             surface, which puts this block last, dropped whatever ran past its
             budget -- an ask of four questions was enough to push the rest off
             the bottom, the cursor with it, so [/] and j/k moved a selection
             nothing on screen showed. *)
          let count = List.length rows in
          let cursor = min (max 0 state.ask_cursor) (count - 1) in
          let selected = List.nth rows cursor in
          let draft = Ask_projection.draft_for state.ask_draft ~row:selected in
          let answering =
            match answering_ask_id with
            | Some ask_id -> String.equal ask_id selected.Masc.Tui_decode_asks.ar_id
            | None -> false
          in
          let questions = selected.Masc.Tui_decode_asks.ar_questions in
          let question_blocks =
            List.mapi
              (fun index question ->
                ask_block (fun b ->
                    draw_ask_question b cols state ~row:selected ~draft ~question
                      ~answering
                      ~selected_question:(index = state.ask_question_cursor)))
              questions
          in
          let why_text, why_rows =
            ask_block (fun b -> draw_ask_context b cols ~row:selected)
          in
          let plan =
            Ask_layout.plan ~budget ~spent:(count_frame_lines buf)
              ~question_heights:(List.map snd question_blocks)
              ~question_cursor:state.ask_question_cursor
              ~context_height:why_rows ~other_asks:(count - 1)
          in
          List.iteri
            (fun index (text, _) ->
              if
                index >= plan.Ask_layout.question_start
                && index
                   < plan.Ask_layout.question_start
                     + plan.Ask_layout.questions_shown
              then Buffer.add_string buf text)
            question_blocks;
          if plan.Ask_layout.questions_hidden > 0 then
            box_line buf cols
              (* "in this ask", because the count above names every question
                 the fleet is waiting on and this one names the selected
                 ask's own. Both said "questions", and a reader saw "(1)"
                 three rows above "+2 more questions". *)
              (Printf.sprintf "    %s+%d more in this ask -- j/k to reach%s"
                 Ansi.dim plan.Ask_layout.questions_hidden Ansi.reset);
          if plan.Ask_layout.context_shown then Buffer.add_string buf why_text
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
                box_line buf cols (ask_summary_line ~now ~row);
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
                (fit_width (Terminal_text.single_line a.ap_summary) (cols - 22))
                Ansi.reset
          | _ ->
              let summary =
                fit_width (Terminal_text.single_line a.ap_summary) (max 8 (cols - 34))
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
             (max 8 (cols - 28)))
          Ansi.reset
          (Theme.info ()) Ansi.reset
          Ansi.dim
          (fit_width
             (Terminal_text.single_line_or ~default:"(not provided)"
                held.kta_because)
             (max 8 (cols - 12)))
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
        let phase, tone =
          match pending.Tui_decode.gp_phase with
          | Gate_queued -> "QUEUED", (Theme.warn ())
          | Gate_judging -> "JUDGING", (Theme.info ())
          | Gate_human_required -> "HUMAN REQUIRED", (Theme.warn ())
          | Gate_blocked -> "AUTO JUDGE BLOCKED", (Theme.bad ())
        in
        let actions = "  " ^ (Theme.info ()) ^ "[y] Approve  [n] Reject" ^ Ansi.reset in
        let headline =
          Printf.sprintf "  %s%s → %s · %s%s%s"
            tone
            keeper
            (fit_width
               (Terminal_text.single_line pending.Tui_decode.gp_display_tool)
               (max 8 (cols - 56 - Message_layout.display_width keeper
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
               (fit_width detail (max 8 (cols - 12))) Ansi.reset
               Ansi.dim (fit_width next (max 8 (cols - 4))) Ansi.reset
         | Gate_queued | Gate_judging | Gate_human_required -> headline)
    | None -> ""
;;


(* The two rows drawn under the approval queue: what the selected ask is, and
   its payload. Both sit below the box with the frame's own margins, so both
   belong inside [framed_inner_width]. The payload row always asked for that
   width; the metadata row never did, and with [expires] now spelled as a full
   timestamp it wanted eighty-four columns on every terminal (#36333).

   The metadata row is a list of clauses rather than one joined string, so it
   breaks where a clause ends and keeps every value whole -- the rule this
   surface already states for the ask body, where a value too wide for the
   pane wraps rather than being cut. Nothing is dropped either: [trace] is how
   an operator matches this decision in the log afterwards, and a trace id cut
   to its first few bytes is worse than one that took its own row. *)
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
        ( [ Printf.sprintf "trace=%s"
              (Terminal_text.single_line approval.ap_trace_id)
          ; Printf.sprintf "created=%s"
              (Terminal_text.short_timestamp approval.ap_created_at)
          ; Printf.sprintf "expires=%s" expires ]
        , Printf.sprintf "  %spayload=%s%s" Ansi.dim
            (fit_width payload (max 8 (cols - 12)))
            Ansi.reset )
    | Some (Masc_tui_approvals_model.Keeper_tool_row held) ->
        ( [ Printf.sprintf "keeper=%s"
              (Terminal_text.single_line held.kta_keeper)
          ; Printf.sprintf "call=%s"
              (Terminal_text.single_line held.kta_tool_call_id) ]
        , Printf.sprintf "  %sargs=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.preview_line held.kta_args)
               (max 8 (cols - 9)))
            Ansi.reset )
    | Some (Masc_tui_approvals_model.Gate_row pending) ->
        (* The keeper name is not repeated here: the line directly above is
           "<keeper> -> <what it wants>", so this line spends its width on
           what that line cannot say. Where the command would run comes first
           among those -- the same command means different things on the host
           and in a container -- and the approval id, a uuid nobody reads off
           a screen, takes what is left. *)
        (* Ordered by what the eye needs first. The sandbox is short and
           decides the most -- host or container -- so it leads; the working
           directory refines it and is long, so it is the clause most likely
           to start a second row. At eighty columns the old order lost the
           sandbox entirely, and the directory it kept was measured by
           nothing: [approval=] was bound to the width left over, while
           [at=] inside this pair was not bound at all. *)
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
          @ [ Printf.sprintf "approval=%s"
                (Terminal_text.single_line pending.Tui_decode.gp_id) ]
        , Printf.sprintf "  %sinput=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.single_line_or ~default:"(no input preview)"
                  pending.Tui_decode.gp_input_preview)
               (max 8 (cols - 10)))
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

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  (* The same population the tab badge and the Overview row count: the
     approval rows plus the open questions. This title counted the approval
     rows alone, so an operator who came here from a badge of 1 was met with
     "(0)" and had to find the question block further down to learn what the
     badge had been counting. *)
  let count = Masc_tui_approvals_model.approvals_surface_pending state in
  (* The count is what is on screen. It used to be the pending-confirm queue's
     own visible/total pair, and that queue is one of the three lists this
     screen draws: with seven Gate rows waiting and no confirm entries, the
     title read "(0/0, hidden 0)" while the tab beside it read "7".

     The filter clause stays -- an actor filter really does hide confirm
     entries, and [visible_entries]/[hidden_entries] partition the same list,
     so the hidden count is the whole of what the old total said. It now
     reads as a note about that queue rather than as the screen's count. *)
  let hidden_note =
    match state.approval_snapshot with
    | Some snapshot when snapshot.aps_hidden_count > 0 ->
        Printf.sprintf ", %d hidden from %s" snapshot.aps_hidden_count
          (Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value
             snapshot.aps_actor_filter)
    | Some _ | None -> ""
  in
  (* Which list the count cannot stand behind, one clause per list, from the
     same readings that keep the strip entry and put "?" on the Overview
     count. A stale list still draws its earlier rows, and those are the rows
     an operator decides against. *)
  let reading = Masc_tui_approvals_model.approvals_reading state in
  let reading_notes = Masc_tui_approvals_model.approvals_title_notes reading in
  let action_badge = if action_inflight then "  [submitting]" else "" in
  (* The count and where it came from, naming only the lists that have a row
     on the screen. It read "3 [0 held · 0 gate · 3 op]": two zeros for lists
     with nothing in them, a bracket inside the parenthesis, and a total the
     one kind that did have rows had already said. With one kind its count is
     the total; with more, the total leads and the kinds follow it. *)
  (* The questions a Keeper is waiting on are the fourth kind this surface
     answers, and the only one whose word takes a plural, so it is built
     beside the three rather than inside their format. *)
  let question_count = Masc_tui_approvals_model.approvals_open_question_count state in
  let count_text =
    let kinds =
      [ (Theme.warn (), List.length state.keeper_tool_approvals, "held")
      ; (Theme.bad (), List.length state.gate_pending, "gate")
      ; (Theme.info (), List.length (Masc_tui_approvals_model.operator_approval_items state), "op")
      ]
      |> List.filter_map (fun (style, kind_count, word) ->
             if kind_count = 0 then None
             else
               Some
                 (Printf.sprintf "%s%d %s%s" style kind_count word Ansi.reset))
    in
    let kinds =
      if question_count = 0 then kinds
      else
        kinds
        @ [ Printf.sprintf "%s%s%s" (Theme.warn ())
              (Masc_tui_message_layout.count_noun question_count "question")
              Ansi.reset
          ]
    in
    match kinds with
    | [] -> string_of_int count
    | [ only ] -> only
    | several ->
      Printf.sprintf "%d: %s" count (String.concat " \xc2\xb7 " several)
  in
  let header =
    Printf.sprintf
      "%s (%s%s%s)  %s  %s%s"
      (screen_title " MASC Approvals")
      count_text hidden_note reading_notes timestamp
      (connection_badge state) action_badge
  in

  box_top buf cols;
  box_line buf cols header;
  (* Both Gate lanes, always on screen here — one row, counted with the rule
     row below it in [gate_lane_rows] so the body arithmetic can subtract
     both as a constant. The durable rows obey
     the external lane, and an operator deciding them needs to see which
     switch they are under. The [e] that cycles the external lane is a
     footer key like any other -- it reaches the footer and the [?] help
     through the Approvals row of Masc_tui_keys, which is where it was
     missing until 2026-08-29. *)
  box_line buf cols
    (match state.gate_modes, Terminal_text.optional_single_line state.gate_error with
     | Some modes, _ ->
         Printf.sprintf
           "  %s[w] Workspace: %s  |  [e] Outside services: %s%s"
           (Theme.info ())
           (match Masc.Keeper_gate_mode.of_string modes.Tui_decode.glm_workspace with
            | Some mode -> Masc_tui_palette.gate_mode_label mode | None -> "Unknown mode")
           (match Masc.Keeper_gate_mode.of_string modes.Tui_decode.glm_external with
            | Some mode -> Masc_tui_palette.gate_mode_label mode | None -> "Unknown mode")
           Ansi.reset
     (* No prefix: [data_unreliable_row] already opens "(data unreliable: "
        and the loader's message already opens "gate load failed:", so a third
        "gate:" in front read as a stutter -- "(data unreliable: gate: gate
        load failed: ...)". Same rule the schedule warning is written to. The
        two rows below keep their prefixes because the detail there is the
        server's own sentence about the store, which does not name itself. *)
     | None, Some err -> data_unreliable_row ~cols err
     | None, None ->
         Ansi.dim ^ "  Gate lanes: loading" ^ Ansi.reset);
  (* Standing always-allow rules, on the row under the lanes. A rule answers
     its call before the call can reach the queue, so an operator reading an
     empty queue is reading the rules' work without seeing them. One row: the
     count, and who the newest one covers. *)
  box_line buf cols
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
  box_divider buf cols;

  (* Every row the surface spends around the queue, read back off the buffers
     they were drawn into. Declared beside the drawing instead, the rows above
     the queue were subtracted twice -- once inside [boxed_surface_chrome_rows]
     and again as the two Gate lane rows -- so the surface came out two rows
     short of its budget. [finish_surface] pads a short surface under its last
     row, and the last row here is the footer: it floated two rows above the
     composer at every terminal height, and the queue drew two blank rows in
     place of two approvals. *)
  let head_rows = count_frame_lines buf in
  (* The rows under the queue: the frame's closing row, the selected row's
     detail, the metadata rows, and the payload row beneath them. Drawn now so
     their height is the same measured fact -- a metadata row that breaks into
     two, or a held tool call whose detail takes two, is counted because it is
     in the buffer, not because a reader remembered to add one. *)
  let below_buf = Buffer.create 1024 in
  box_bottom below_buf cols;
  Buffer.add_string below_buf (Printf.sprintf "%s\n" detail_line);
  Buffer.add_string below_buf
    (Printf.sprintf "%s\n%s\n" metadata_line payload_line);
  (* The footer ends its own row, so the buffer holds exactly the row it
     draws. *)
  let footer_buf = Buffer.create 256 in
  Buffer.add_string footer_buf
    (footer_line state ~max_cells:cols ~hints:(question_hints state));
  let around_rows =
    head_rows + count_frame_lines below_buf + count_frame_lines footer_buf
  in
  (* What the questions may spend. The block is drawn last, and a surface that
     overruns loses its final rows, so an unbudgeted question list does not
     push the approval queue off the screen -- it pushes itself off, cursor and
     all. One row is held back for the queue, which is what the [max 1] below
     was already trying to promise and could not keep. *)
  let ask_budget = max 4 (rows - around_rows - 1) in
  (* Drawn before the queue's own budget is settled so its height is a measured
     fact rather than a second estimate that can disagree with the drawing. *)
  let ask_buf = Buffer.create 1024 in
  draw_ask_questions ask_buf cols state ~budget:ask_budget;
  let ask_rows = count_frame_lines ask_buf in
  let approval_body_rows = max 1 (rows - around_rows - ask_rows) in

  (* The queue's own population, not the surface's. [count] above is the
     approval rows plus the open questions -- the right reading for the title
     and the badge, which name the screen -- and this block is about the three
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
    List.iter (fun line -> box_line buf cols line) lines;
    for _ = 1 to max 0 (approval_body_rows - List.length lines) do
      box_empty buf cols
    done
  end else begin
    let content_height = approval_body_rows in
    let scroll_offset =
      if content_height > 0 && state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    let now_unix = Unix.gettimeofday () in
    (* The name column, sized to the names it has to hold rather than to a
       number chosen once. Sixteen cells cut "rw-e0-r9-20260820-review" to
       "rw-e0-r9-202608~", and two keepers whose names share a long prefix
       then read alike -- which is the whole job of the column.

       The cells come out of the last one, which carries the server's input
       preview. That preview is a JSON envelope, so at this width it shows
       "{\"schema\":\"ma…" and nothing a reader can act on; ten fewer of those
       characters costs nothing and buys the identifier back. The cap keeps
       one long name from taking the row. *)
    (* Sanitised here, not at the call below. These are external names and
       every path that reads one goes through [Terminal_text] -- measuring is
       a path like any other, and a measurement taken off the raw field would
       size the column to control characters the screen never draws. *)
    let approval_row_name = function
      | Masc_tui_approvals_model.Operator_row a -> Terminal_text.single_line a.ap_actor
      | Masc_tui_approvals_model.Keeper_tool_row held ->
        Terminal_text.single_line held.Tui_decode.kta_keeper
      | Masc_tui_approvals_model.Gate_row pending ->
        Terminal_text.single_line pending.Tui_decode.gp_keeper
    in
    let name_width =
      List.fold_left
        (fun widest row ->
          max widest (Message_layout.display_width (approval_row_name row)))
        16 approvals
      |> min 26
    in
    let approvals_window = Rows.of_list ~first:scroll_offset ~height:content_height approvals in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let line =
          match Rows.at approvals_window idx with
          | None -> ""
          | Some (Masc_tui_approvals_model.Operator_row a) ->
              let target_id =
                Terminal_text.single_line_or ~default:Masc_tui_theme.Glyph.no_value a.ap_target_id
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line a.ap_actor) name_width)
                (fit_width (Terminal_text.single_line a.ap_action_type) 20)
                (fit_width (Terminal_text.single_line a.ap_target_type) 16)
                target_id
          | Some (Masc_tui_approvals_model.Keeper_tool_row held) ->
              (* The remaining wait, not the age: this row disappears on its
                 own when it runs out, and what an operator weighs is how
                 long they still have. *)
              let remaining =
                max 0.
                  (held.kta_asked_at +. held.kta_timeout_sec -. now_unix)
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line held.kta_keeper) name_width)
                (fit_width
                   ("tool: " ^ Terminal_text.single_line held.kta_tool)
                   20)
                (fit_width
                   (Masc_tui_answering.duration_text remaining ^ " left")
                   16)
                (Terminal_text.single_line held.kta_question ^ " — "
                ^ Terminal_text.single_line_or ~default:"(not provided)"
                    held.kta_because)
          | Some (Masc_tui_approvals_model.Gate_row pending) ->
              (* The age is not worker duration. A durable row survives after
                 Auto Judge hands off to a human or fails, so pair age with
                 the canonical phase instead of calling every row waiting. *)
              let age =
                match pending.Tui_decode.gp_waiting_s with
                | Some seconds ->
                  Masc_tui_answering.duration_text seconds
                | None -> Masc_tui_theme.Glyph.no_value
              in
              let phase, tone =
                match pending.Tui_decode.gp_phase with
                | Gate_queued -> "queued", (Theme.warn ())
                | Gate_judging -> "judging", (Theme.info ())
                | Gate_human_required -> "human", (Theme.warn ())
                | Gate_blocked -> "blocked", (Theme.bad ())
              in
              let phase_cell =
                tone ^ fit_width (age ^ " " ^ phase) 16 ^ Ansi.reset
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width
                   (Terminal_text.single_line pending.Tui_decode.gp_keeper)
                   name_width)
                (fit_width
                   ("gate: "
                   ^ Terminal_text.single_line
                       pending.Tui_decode.gp_display_tool)
                   20)
                phase_cell
                (Terminal_text.single_line_or ~default:"(no input preview)"
                   pending.Tui_decode.gp_input_preview)
        in
        let is_selected = idx = state.approval_cursor in
        if is_selected then
          box_line_selected buf cols (Masc_tui_theme.strip_sgr ("> " ^ line))
        else
          box_line buf cols ("  " ^ line)
      end else
        box_empty buf cols
    done
  end;

  Buffer.add_buffer buf below_buf;

  Buffer.add_buffer buf ask_buf;

  Buffer.add_buffer buf footer_buf;

  finish_surface state ~surface_key:"approvals" ~rows:terminal_rows
      ~cols buf

let ask_question_page_size state = snd (ask_question_viewport state)

let ask_question_scroll_limit state =
  let lines, room = ask_question_viewport state in
  max 0 (List.length lines - room)

let render_question_reader (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let asks = question_asks state in
  let selected = List.nth_opt asks state.ask_cursor in
  box_top buf cols;
  box_line buf cols (screen_title
    (" MASC Approvals / Questions"
     ^ Masc_tui_approvals_model.approval_list_note ~name:"questions" (Masc_tui_approvals_model.approvals_questions_reading state)));
  box_line buf cols
    (match selected with
     | None -> "  No questions waiting"
     | Some row ->
         let draft = Ask_projection.draft_for state.ask_draft ~row in
         let answered = List.filter (fun question ->
             Option.is_some (Ask_projection.response_for draft ~question)) row.ar_questions |> List.length in
         Printf.sprintf "  %s%s · Ask %d/%d · Question %d/%d · %d answered%s"
           (Theme.warn ()) (Terminal_text.single_line row.ar_keeper)
           (state.ask_cursor + 1) (List.length asks) (state.ask_question_cursor + 1)
           (List.length row.ar_questions) answered Ansi.reset);
  box_line buf cols
    (match state.asks_error with
     | Some error -> "  Question source unavailable · " ^ Terminal_text.single_line error
     | None ->
       if Option.is_some state.ask_text_entry then "  Enter: save written answer · Esc: cancel writing"
       else
         "  Left/Right: previous/next question · [/]: previous/next ask · "
         ^ "PgUp/PgDn: page · Home/End: top/bottom · Esc: "
         ^ (match state.followed_from with Some (Overview, _) -> "Dashboard" | _ -> "approvals"));
  box_divider buf cols;
  let lines, room = ask_question_viewport state in
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
