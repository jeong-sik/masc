(** Approval rows and readings projected from the latest terminal state. *)

open Masc_tui_types

(* One list under one cursor: the calls keepers are holding first (they run
   out in [kta_timeout_sec]; the operator actions keep), then the operator
   actions. The two kinds answer through different routes, so the row is a
   sum the key handler matches on rather than a shape it infers. *)
type approval_row =
  | Keeper_tool_row of Tui_decode.keeper_tool_approval
  | Gate_row of Tui_decode.gate_pending
      (** A durable Gate approval — an external-service write among them.
          It keeps: nobody watching loses nothing. Answered through the
          dashboard resolve route. *)
  | Operator_row of Masc_tui_operator_projection.approval_item

let operator_approval_items (state : state) =
  match state.approval_snapshot with
  | Some snapshot -> snapshot.aps_items
  | None -> []

let approval_items (state : state) =
  List.map (fun held -> Keeper_tool_row held) state.keeper_tool_approvals
  @ List.map (fun pending -> Gate_row pending) state.gate_pending
  @ List.map (fun item -> Operator_row item) (operator_approval_items state)

(* Everything on the Approvals surface waiting on the operator: the three
   approval row kinds plus the questions keepers have open. The surface
   answers both -- that is why it fetches asks -- so its ring entry, badge
   and alert colour must all count the same thing. One count here, not
   three copies that can drift: with zero approvals and one open question
   the entry still has to be reachable, or the question has nowhere to be
   seen from. The badge number is therefore the SUM of approval rows and open
   questions, not an approval count: a badge of 3 may be three approvals,
   three questions, or a mix. *)
(* The questions behind the count, so the three places that say how many there
   are cannot count different things: this surface's title, the block heading
   above the questions themselves, and the badge below. [None] is a reading
   that has not come back, which is not the same answer as a reading with no
   question in it -- the block draws nothing for the first and says so for the
   second. *)
let approvals_open_questions (state : state) =
  Option.map Masc_tui_ask_projection.open_rows state.asks_snapshot

(* The questions themselves. One ask can carry several, and counting the asks
   under the word "question" understated the work: the live surface read
   "MASC Approvals (1 question)" and "Questions waiting on you (1)" over one
   ask holding two, with "+2 more questions" three rows below saying so. *)
let approvals_open_question_count (state : state) =
  match approvals_open_questions state with
  | Some rows ->
      List.fold_left
        (fun total (row : Masc.Tui_decode_asks.ask_row) ->
          total + List.length row.Masc.Tui_decode_asks.ar_questions)
        0 rows
  | None -> 0

(* One list the Approvals surface draws, as its last poll left it.

   - [List_read]: the last poll answered, and the rows on screen are its rows.
   - [List_not_read Approval_unread]: no poll has answered yet.
   - [List_not_read (Approval_failed cause)]: the last poll failed and nothing
     from an earlier one is on screen. A failed confirm-queue read clears its snapshot
     ([apply_approvals_load]), and a first poll that fails has nothing to keep.
   - [List_not_read (Approval_stale cause)]: the last poll failed and the
     rows on screen are an
     earlier poll's. The held-call, Gate and question polls replace their rows
     only on [Ok], so those rows can name calls the server no longer holds.
   - [List_not_read (Approval_unavailable detail)]: the server answered and
     said the store behind the list could not be read. The Gate snapshot sends
     [approval_queue: null] with [approval_queue_state] in this case.

   Every place that has to know whether a list was read -- the strip entry,
   the Dashboard approvals count, the Approvals title and the empty queue --
   reads it from here, so none of them keeps its own list of fields. *)
type approval_not_read =
  | Approval_unread
  | Approval_failed of string
  | Approval_stale of string
  | Approval_unavailable of string

type approval_list_reading =
  | List_read
  | List_not_read of approval_not_read

type approvals_reading =
  { confirm_queue : approval_list_reading
  ; held_calls : approval_list_reading
  ; gate_queue : approval_list_reading
  ; questions : approval_list_reading
  }

(* A failed confirm-queue read sets [approval_snapshot] to [None] in the same
   step as it sets [approvals_error], so a snapshot on screen is always the
   last answer. *)
let confirm_queue_reading (state : state) =
  match (state.approval_snapshot, state.approvals_error) with
  | Some _, _ -> List_read
  | None, Some cause -> List_not_read (Approval_failed cause)
  | None, None -> List_not_read Approval_unread

let kept_rows_reading ~observed ~error =
  match (observed, error) with
  | false, None -> List_not_read Approval_unread
  | false, Some cause -> List_not_read (Approval_failed cause)
  | true, Some cause -> List_not_read (Approval_stale cause)
  | true, None -> List_read

let gate_queue_reading (state : state) =
  match
    kept_rows_reading ~observed:state.gate_snapshot_observed ~error:state.gate_error
  with
  | List_read ->
      (match state.gate_queue_unavailable with
       | Some detail -> List_not_read (Approval_unavailable detail)
       | None -> List_read)
  | List_not_read _ as reading -> reading

(* The questions' snapshot doubles as their "observed" mark: [apply_asks_load]
   sets it on the first [Ok] and never clears it. *)
let approvals_questions_reading (state : state) =
  kept_rows_reading ~observed:(Option.is_some state.asks_snapshot)
    ~error:state.asks_error

let approvals_reading (state : state) =
  { confirm_queue = confirm_queue_reading state
  ; held_calls =
      kept_rows_reading ~observed:state.keeper_tool_approvals_observed
        ~error:state.keeper_tool_approvals_error
  ; gate_queue = gate_queue_reading state
  ; questions = approvals_questions_reading state
  }

let list_is_read = function
  | List_read -> true
  | List_not_read _ -> false

(* The three lists that hold approval rows, by the name the title and the
   empty queue give each. The questions are drawn in their own block, which
   says for itself when they were not read. *)
let approval_row_lists (reading : approvals_reading) =
  [ ("confirm queue", reading.confirm_queue)
  ; ("held calls", reading.held_calls)
  ; ("Gate queue", reading.gate_queue)
  ]

let approvals_surface_pending (state : state) =
  List.length (approval_items state) + approvals_open_question_count state

(* Whether every list the count is taken over was read. The count is a
   reading of what is waiting only when all four came back.

   The strip entry and the Dashboard approvals count both call this, so the
   entry leaves the strip exactly when the count is drawn without "?".
   An unreadable Gate store with every other list empty keeps the entry:
   an entry that is gone reads as "nothing is waiting". *)
let approvals_reading_current (state : state) =
  let reading = approvals_reading state in
  List.for_all list_is_read
    (reading.questions :: List.map snd (approval_row_lists reading))

(* The Dashboard approvals count. The "?" tail marks a count no source will
   stand behind; it does not say which way the number is wrong, because a
   dropped confirm queue leaves it short and a stale held-call or Gate list
   can leave it long. The Approvals title says which list it was. *)
let approvals_count_label (state : state) =
  let on_screen = approvals_surface_pending state in
  if approvals_reading_current state then string_of_int on_screen
  else Printf.sprintf "%d?" on_screen

(* One title clause per list that was not read, in the order the lists are
   drawn. A list with nothing read and nothing kept is "unread" whether or not
   a poll failed; the rows of a list read before and not since are "stale". *)
let approval_list_note ~name = function
  | List_read -> ""
  | List_not_read (Approval_unread | Approval_failed _) ->
      Printf.sprintf ", %s unread" name
  | List_not_read (Approval_stale _) -> Printf.sprintf ", %s stale" name
  | List_not_read (Approval_unavailable _) ->
      Printf.sprintf ", %s unavailable" name

let approvals_title_notes (reading : approvals_reading) =
  String.concat ""
    (List.map
       (fun (name, list_reading) -> approval_list_note ~name list_reading)
       (approval_row_lists reading @ [ ("questions", reading.questions) ]))

(* What the queue says when it has no approval row to draw. "No pending
   approvals" is a reading of all three row lists, so it is said only when
   each of them was read; otherwise each list that was not read is named with
   its reading. *)
type approvals_empty_queue =
  | Nothing_pending
  | Lists_not_read of (string * approval_not_read) list

let approvals_empty_queue (reading : approvals_reading) =
  match
    List.filter_map
      (fun (name, list_reading) ->
        match list_reading with
        | List_read -> None
        | List_not_read not_read -> Some (name, not_read))
      (approval_row_lists reading)
  with
  | [] -> Nothing_pending
  | not_read -> Lists_not_read not_read

let approval_item_needs_person = function
  | Keeper_tool_row _ | Operator_row _ -> true
  | Gate_row (pending : Tui_decode.gate_pending) ->
      match pending.gp_phase with
      | Gate_human_required | Gate_blocked -> true
      | Gate_queued | Gate_judging -> false

let approvals_human_pending (state : state) =
  List.length (List.filter approval_item_needs_person (approval_items state))
  + approvals_open_question_count state
