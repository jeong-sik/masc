(** How much of the questions panel fits.

    The panel is drawn last on the Approvals surface, and a surface that
    overruns its budget loses its final rows: an ask of four questions was
    enough to push the rest of the block off the bottom, the cursor with it, so
    [/] and j/k moved a selection nothing on screen showed. Rather than let the
    block run and be cut from the end, the panel asks here what it can afford
    and folds the rest into counted lines.

    Heights come in measured -- a prompt wraps against the terminal's width, so
    the caller draws each question into a buffer of its own and reports what it
    came out to. Nothing here draws, so every decision it makes is testable
    without a terminal. *)

type plan = {
  question_start : int;
      (** Index of the first question drawn. Non-zero when the cursor's own
          question did not fit in a window starting at the top. *)
  questions_shown : int;
      (** Includes a compact preview when the cursor's full question cannot
          fit. The complete question remains in the answering reader. *)
  questions_hidden : int;
  question_preview_rows : int;
      (** Zero for full questions; otherwise the exact row allowance for the
          selected question's read-only preview, including its reader hint. *)
  question_notice : bool;
      (** Whether the hidden-question count itself has a row. A one-row
          viewport serves the selected preview first; a zero-row viewport
          cannot emit a notice outside its budget. *)
  context_shown : bool;
  context_notice : bool;
      (** The reason was dropped and one line saying so fits. The line spends
          a row like the hidden-question count does, so the plan decides it
          here rather than the renderer drawing it past the budget: with the
          questions filling the room exactly, a notice drawn outside the plan
          pushed the bottom of the block off, and the bottom is where the
          folded asks and their own count line are. *)
  summaries_shown : int;
      (** Folded asks that get a line. The rest are counted in
          [summaries_hidden]. *)
  summaries_hidden : int;
}

(* Reserve the compact question's prompt/continuation and reader hint before
   folded asks. If the viewport is smaller, use only its actual remaining rows.
   Full choices and answering stay in the existing scrolling reader. *)
let min_expanded_rows = 3

let plan ~budget ~spent ~question_heights ~question_cursor ~context_height
    ~other_asks =
  let available = max 0 (budget - spent) in
  let total_questions = List.length question_heights in
  (* The expansion is served first: the folded lines are cheap, and the ask
     under the cursor is the one the keys act on.

     The cap covers the count line as well as the lines it counts. Leaving it
     out was worth three rows on a narrow pane -- the fold announced itself in
     a row it had not budgeted for, and that row came out of the questions,
     which is the one thing the cap exists to protect. *)
  let folded_cap = max 0 (available - min min_expanded_rows available) in
  let others_shown =
    if other_asks <= folded_cap then other_asks else max 0 (folded_cap - 1)
  in
  let others_hidden = max 0 (other_asks - others_shown) in
  let others_rows =
    min available (others_shown + if others_hidden > 0 then 1 else 0)
  in
  let expand_available = max 0 (available - others_rows) in
  let fit start room =
    let rec walk index used taken =
      match List.nth_opt question_heights index with
      | Some height when used + height <= room ->
          walk (index + 1) (used + height) (taken + 1)
      | Some _ | None -> (used, taken)
    in
    walk start 0 0
  in
  let cursor =
    if total_questions = 0 then 0
    else min (max 0 question_cursor) (total_questions - 1)
  in
  (* Whether anything is left over decides how much room there was, because
     saying so costs a row. Try for all of them first; only once that fails is
     a row spent on the count -- and it is spent before the window is chosen,
     not after, or the count line takes a row from the questions it counts. *)
  let full_used, full_taken = fit 0 expand_available in
  let question_start, used, questions_shown, question_preview_rows, question_notice =
    if full_taken = total_questions then (0, full_used, full_taken, 0, false)
    else
      let room = max 0 (expand_available - 1) in
      (* Fill from the top, and fall back to a window starting at the cursor
         when the cursor's own question did not fit. The question the keys are
         on must be visible; which of its neighbours came along is not a
         promise. *)
      let top_used, top_taken = fit 0 room in
      if top_taken > cursor then (0, top_used, top_taken, 0, true)
      else
        let used, taken = fit cursor room in
        if taken > 0 then (cursor, used, taken, 0, true)
        else
          (* A tall prompt/choice list is not an absent question. Keep the
             selected question identifiable, with its original rendered rows,
             and let [a] open the full reader. Never spend the sole remaining
             row on a count while hiding the selected question itself. *)
          let notice_rows = if total_questions > 1 && expand_available > 1 then 1 else 0 in
          let preview_rows = min min_expanded_rows (max 0 (expand_available - notice_rows)) in
          let shown = if preview_rows > 0 then 1 else 0 in
          let notice = total_questions > shown && expand_available > preview_rows in
          cursor, preview_rows, shown, preview_rows, notice
  in
  let questions_hidden = total_questions - questions_shown in
  (* The reason goes in only when it does not cost a question its place. It
     explains the ask; the questions are the ask. *)
  let hidden_line = if question_notice then 1 else 0 in
  let context_shown =
    context_height > 0 && used + hidden_line + context_height <= expand_available
  in
  (* Saying the reason was dropped costs a row of its own. When not even that
     row is left the block says nothing, as it did before: keeping to the
     budget matters more than the notice. *)
  let context_notice =
    context_height > 0
    && (not context_shown)
    && used + hidden_line + 1 <= expand_available
  in
  {
    question_start;
    questions_shown;
    questions_hidden;
    question_preview_rows;
    question_notice;
    context_shown;
    context_notice;
    summaries_shown = others_shown;
    summaries_hidden = others_hidden;
  }
