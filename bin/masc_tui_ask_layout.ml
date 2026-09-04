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
  questions_hidden : int;
  context_shown : bool;
  summaries_shown : int;
      (** Folded asks that get a line. The rest are counted in
          [summaries_hidden]. *)
  summaries_hidden : int;
}

(* The least a question can occupy: its prompt, one choice, one hint. Held back
   from the folded lines so the ask the keys act on always has room to say
   something, however many other asks are waiting. *)
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
  let question_start, used, questions_shown =
    if full_taken = total_questions then (0, full_used, full_taken)
    else
      let room = max 0 (expand_available - 1) in
      (* Fill from the top, and fall back to a window starting at the cursor
         when the cursor's own question did not fit. The question the keys are
         on must be visible; which of its neighbours came along is not a
         promise. *)
      let top_used, top_taken = fit 0 room in
      if top_taken > cursor then (0, top_used, top_taken)
      else
        let used, taken = fit cursor room in
        (cursor, used, taken)
  in
  let questions_hidden = total_questions - questions_shown in
  (* The reason goes in only when it does not cost a question its place. It
     explains the ask; the questions are the ask. *)
  let context_shown =
    context_height > 0
    && used + (if questions_hidden > 0 then 1 else 0) + context_height
       <= expand_available
  in
  {
    question_start;
    questions_shown;
    questions_hidden;
    context_shown;
    summaries_shown = others_shown;
    summaries_hidden = others_hidden;
  }
