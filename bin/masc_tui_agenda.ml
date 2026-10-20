type standing =
  | Coming
  | Settled
  | Unrecognised of string

(* The wire strings are [Schedule_domain.schedule_status_to_string]'s. Two of
   them are still ahead of the operator; the rest have already happened. A
   string outside the set is kept as itself rather than folded into [Settled]:
   "we do not know what this is" and "this is over" are different answers, and
   only one of them should silence a row for good. *)
let standing_of_wire = function
  | "scheduled" | "due" -> Coming
  | ("running" | "succeeded" | "failed" | "cancelled" | "expired") -> Settled
  | other -> Unrecognised other
;;

type scheduled =
  { at_iso : string
  ; standing : standing
  ; who : string
  ; what : string
  ; recurrence : string
  }

type awaiting =
  { asked_by : string
  ; tool_call_id : string
  ; question : string
  ; asked_at : float
  ; timeout_sec : float
  }

(* A task whose only exit belongs to the operator, as
   [Operator_task_attention] projected it. Flattened to text here: the panel
   draws rows, and three surfaces describing the same row three ways is what
   the projection exists to prevent, so the sentence is made once over there. *)
type stalled =
  { task_id : string
  ; what : string
  ; since_iso : string
  }

(* A Goal the verifier proved and only the operator's confirmation closes. *)
type goal_to_confirm =
  { goal_id : string
  ; title : string
  ; since_iso : string
  }

(* An ask a Keeper put to the operator and nobody has answered. One row per
   ask, however many questions it holds: the operator answers an ask as one
   draft and one submit, so the ask is what is waiting. *)
type open_question =
  { ask : Masc.Tui_decode_asks.ask_key
  ; asked_by : string
  ; first_question : string option
  ; asked_at : float
  }

type 'row reading =
  | Not_read
  | Read_failed of string
  | Read of 'row list

type t =
  { coming : scheduled reading  (** earliest first *)
  ; blocked : awaiting reading
  ; asking : open_question reading  (** in the order the server sent them *)
  ; confirming : goal_to_confirm reading
  ; stuck : stalled reading  (** longest wait first *)
  }

let rows_of = function
  | Read rows -> rows
  | Not_read | Read_failed _ -> []

let is_coming row = match row.standing with
  | Coming -> true
  | Settled | Unrecognised _ -> false
;;

(* RFC 3339 in UTC with a fixed shape, which the projection writes and the
   decoder passes through, so bytes order the same way instants do. Sorting
   here rather than trusting the payload: the projection orders active rows
   ahead of settled ones and then by due time, and a strip that depends on
   somebody else's sort is a strip that changes when their sort does. *)
let by_time left right = String.compare left.at_iso right.at_iso

let project ~scheduled ~awaiting ~asking ~confirming ~stalled =
  { coming =
      (match scheduled with
       | Read rows -> Read (rows |> List.filter is_coming |> List.sort by_time)
       | (Not_read | Read_failed _) as unread -> unread)
  ; blocked = awaiting
  ; asking
  ; confirming
  ; stuck = stalled
  }
;;

let next t = match rows_of t.coming with row :: _ -> Some row | [] -> None

(* A keeper holding a tool call, a question a keeper asked, a Goal waiting for
   confirmation and a task only the operator can move all wait on the operator,
   and each asks for a different thing. The badge names them one by one
   ([waiting_label]); this total is what it falls back to when there is no room
   to name them. *)
let waiting t =
  List.length (rows_of t.blocked)
  + List.length (rows_of t.asking)
  + List.length (rows_of t.confirming)
  + List.length (rows_of t.stuck)

(* Only a wake takes the row above the composer: what waits on the operator is
   on the surface strip at the top of every frame. One predicate, two readers:
   the row the frame draws and the row the keypress bound subtracts are the
   same row or neither exists. A section that was never read has no row to
   name, so the row stays down for it the same way; the overlay is where the
   difference is said. *)
let rows_taken t = if rows_of t.coming = [] then 0 else 1

let same_day (a : Unix.tm) (b : Unix.tm) =
  a.Unix.tm_year = b.Unix.tm_year && a.Unix.tm_yday = b.Unix.tm_yday
;;

(* [Masc.Tui_terminal_text.clock_timestamp_for_terminal] answers HH:MM:SS and this strip
   has one line to spend, so the seconds go. A wake the codec cannot read
   keeps its own text: a row that says nothing readable is still a row that
   says something is scheduled. *)
let hour_and_minute ~now ~localtime row =
  match Time_codec.parse_rfc3339_opt row.at_iso with
  | None -> Masc.Tui_terminal_text.short_timestamp_for_terminal ~localtime row.at_iso
  | Some at ->
    let tm = localtime at in
    let clock = Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min in
    if same_day tm (localtime now)
    then clock
    else Printf.sprintf "%s %02d/%02d" clock (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
;;

let next_glyph = "\xe2\x96\xb8"

let clock_half ~now ~localtime ~cells row =
  let head = Printf.sprintf "%s %s  " next_glyph (hour_and_minute ~now ~localtime row) in
  let said =
    match String.trim row.what, String.trim row.who with
    | "", "" -> ""
    | "", who -> who
    | what, "" -> what
    | what, who -> Printf.sprintf "%s \xc2\xb7 %s" what who
  in
  let room = cells - Masc_tui_message_layout.display_width head in
  if room <= 0 then "" else head ^ Masc_tui_message_layout.fit_middle room said
;;

(* One phrase per kind, questions first. The words follow the Dashboard's rows
   and the [;] panel: a keeper's held call is a "Held call" there, and the
   panel has the "Confirm a goal" and "Stuck on you" sections. Gate requests and
   operator confirmations are not in the agenda, so "approval" would claim more
   than the number counts. *)
let waiting_phrases t =
  [ List.length (rows_of t.asking), "question", "questions"
  ; List.length (rows_of t.blocked), "held call", "held calls"
  ; List.length (rows_of t.confirming), "goal to confirm", "goals to confirm"
  ; List.length (rows_of t.stuck), "stuck task", "stuck tasks"
  ]
  |> List.filter_map (fun (count, one, many) ->
    if count <= 0 then None
    else Some (Printf.sprintf "%d %s" count (if count = 1 then one else many)))
;;

(* What waits on the operator, by kind, for the surface strip at the top of
   every frame. The key leads the badge. The panel behind [;] is the only
   screen that lists this work, and the footer that names [;] is among the
   first things a narrow terminal gives up, so the badge carries its own door.

   Three spellings, longest first, and the first that fits [cells] is drawn:
   the sentence, the kinds alone, the total alone. The total is the last
   resort and is returned even when it does not fit, because a badge that
   vanishes is worse than one the ring has to make room for. *)
let waiting_label ~cells t =
  match waiting_phrases t with
  | [] -> ""
  | phrases ->
    let listed = String.concat " \xc2\xb7 " phrases in
    let spellings =
      [ "; Awaiting you: " ^ listed
      ; "; " ^ listed
      ]
    in
    let total = Printf.sprintf "; %d waiting" (waiting t) in
    let fits text = Masc_tui_message_layout.display_width text <= cells in
    (match List.find_opt fits spellings with
     | Some text -> text
     | None -> total)
;;

(* The row above the composer: the next wake, or nothing. *)
let strip ~now ~localtime ~cols t =
  match next t with
  | None -> None
  | Some row -> Some (clock_half ~now ~localtime ~cells:cols row)
;;

type tone =
  | Heading
  | Wake
  | Question
  | Quiet
  | Failed

(* Where a row leads. Most lead nowhere -- headings, the blank spacers, the
   note an empty section draws -- and a row that leads nowhere is a row the
   cursor does not stop on.

   The panel used to lead nowhere at all: it counted the work waiting on the
   operator and then had no way to reach any of it, which is a count rather
   than an answer. *)
type destination =
  | Nowhere
  | Keeper_holding of { keeper : string; tool_call_id : string }
      (** The exact held call; one Keeper can have several awaiting answers. *)
  | Ask_to_answer of Masc.Tui_decode_asks.ask_key  (** the ask, answered on Approvals *)
  | Goal_to_confirm of string  (** the Goal, confirmed on its own detail *)
  | Stuck_task of string  (** the task, read on its own detail *)

type line =
  { tone : tone
  ; text : string
  ; goes_to : destination
  }

(* Cells the left column keeps before the right one is dropped: a clock that
   has spilled onto a second day ("08:00 08/27") and enough of a name to tell
   two keepers apart. *)
let minimum_left_cells = 24

(* Two cells of indent under a heading, and the right-hand column laid against
   the far edge. One helper so the wake rows and the question rows land on the
   same two columns; laying each out where it is written is how two lists on
   one panel end up half a cell apart.

   What the row is for is on the left. The right is context, and it is dropped
   whole rather than cut when it will not fit: half a cron expression reads as
   a schedule that is not the one running. *)
let two_column ~cols left right =
  let width = Masc_tui_message_layout.display_width in
  let indent = "  " in
  let body = max 0 (cols - width indent) in
  let right = if width right + minimum_left_cells > body then "" else right in
  let separator = if right = "" then 0 else 2 in
  let room = max 0 (body - width right - separator) in
  let left = Masc_tui_message_layout.fit_middle room left in
  let gap = max 0 (body - width left - width right) in
  indent ^ left ^ String.make gap ' ' ^ right
;;

let said (row : scheduled) =
  match String.trim row.what, String.trim row.who with
  | "", "" -> "(untitled)"
  | "", who -> who
  | what, "" -> what
  | what, who -> Printf.sprintf "%s \xc2\xb7 %s" what who
;;

(* Whole minutes while there are any, then seconds. A held call is denied when
   this reaches zero, so the number is the reason to look rather than
   decoration. *)
let time_left ~now (held : awaiting) =
  let remaining = held.asked_at +. held.timeout_sec -. now in
  if Float.compare remaining 0.0 <= 0
  then "expired"
  else begin
    let whole = int_of_float remaining in
    if whole >= 60
    then Printf.sprintf "%dm %02ds left" (whole / 60) (whole mod 60)
    else Printf.sprintf "%ds left" whole
  end
;;

(* How long the operator has not answered. Coarse on purpose: the row exists
   because the wait is long, and minutes past the first day are noise. *)
let waited_since ~now since =
  let seconds = now -. since in
  if Float.compare seconds 0.0 <= 0
  then "just now"
  else (
    let whole = int_of_float seconds in
    if whole >= 86_400
    then Printf.sprintf "%dd waiting" (whole / 86_400)
    else if whole >= 3_600
    then Printf.sprintf "%dh waiting" (whole / 3_600)
    else Printf.sprintf "%dm waiting" (whole / 60))
;;

(* A stamp this cannot read says nothing rather than saying zero. *)
let waited ~now since_iso =
  match Time_codec.parse_rfc3339_opt since_iso with
  | None -> ""
  | Some since -> waited_since ~now since
;;

let overlay ~now ~localtime ~cols t =
  let quiet text = { tone = Quiet; text = "  " ^ text; goes_to = Nowhere } in
  (* Why it failed, not only that it did. The reason is beside the flag in the
     state -- "schedule load failed: HTTP 503" -- and this panel dropped it,
     leaving two words that name neither the source nor the fault. Fitted like
     any other row here, so a long transport error cannot push the frame. *)
  let failure ~cols reason =
    (* No "load failed:" in front: the loader's own message already opens with
       the read that failed ("schedule load failed: HTTP 503"), and a prefix
       made the row stutter the way the Gate row did before #35436. *)
    (* Row-budget queries also project the agenda. Only the overlay displays
       read failures, so sanitize here, before measuring or clipping text. *)
    let reason = Masc.Tui_terminal_text.sanitize_terminal_text reason in
    { tone = Failed; text = two_column ~cols reason ""; goes_to = Nowhere }
  in
  (* An empty section is an answer only once its list was read. Before that,
     or when the read failed, each section's empty note was said about a list
     no one had seen. *)
  let wakes =
    match t.coming with
    | Not_read -> [ quiet "not loaded yet" ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] -> [ quiet "nothing is scheduled" ]
    | Read rows ->
      List.map
        (fun row ->
           { tone = Wake
           ; goes_to = Nowhere
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf
                    "%-6s  %s"
                    (hour_and_minute ~now ~localtime row)
                    (said row))
                 row.recurrence
           })
        rows
  in
  let questions =
    match t.blocked with
    | Not_read -> [ quiet "not loaded yet" ]
    | Read_failed reason -> [ failure ~cols reason ]
    (* Named after what this section holds, the way the stuck section is. The
       note used to read "nobody is waiting on you" while the strip's badge
       said "Awaiting you" over a number that counts this list AND the stuck
       one: with no held call and sixteen stuck tasks the panel answered the
       badge with "nobody is waiting on you" two rows under it. *)
    | Read [] -> [ quiet "no keeper is holding a call" ]
    | Read rows ->
      List.map
        (fun (held : awaiting) ->
           { tone = Question
           ; goes_to = Keeper_holding { keeper = held.asked_by; tool_call_id = held.tool_call_id }
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf "%s is holding %s" held.asked_by held.question)
                 (time_left ~now held)
           })
        rows
  in
  let asked =
    match t.asking with
    | Not_read -> [ quiet "not loaded yet" ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] -> [ quiet "no keeper has asked a question" ]
    | Read rows ->
      List.map
        (fun (row : open_question) ->
           (* The asker wrote both, so both are made safe to draw before the
              row is measured; a question's line breaks are content and are
              kept as marks rather than dropped. *)
           let keeper = Masc.Tui_terminal_text.sanitize_terminal_text row.asked_by in
           { tone = Question
           ; goes_to = Ask_to_answer row.ask
           ; text =
               two_column
                 ~cols
                 (match row.first_question with
                  | Some question ->
                    Printf.sprintf "%s asks: %s" keeper
                      (Masc.Tui_terminal_text.preview_line question)
                  | None -> Printf.sprintf "%s asked a question" keeper)
                 (waited_since ~now row.asked_at)
           })
        rows
  in
  let stuck =
    match t.stuck with
    | Not_read -> [ quiet "not loaded yet" ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] -> [ quiet "no task is stuck on you" ]
    (* Every row, oldest first. The panel scrolls, and a row the cursor
       cannot reach is work the operator cannot open. *)
    | Read rows ->
      List.map
        (fun (row : stalled) ->
           { tone = Question
           ; goes_to = Stuck_task row.task_id
           ; text = two_column ~cols row.what (waited ~now row.since_iso)
           })
        rows
  in
  let goals =
    match t.confirming with
    | Not_read -> [ quiet "not loaded yet" ]
    | Read_failed reason -> [ failure ~cols reason ]
    (* Short enough for the narrowest panel, like the other notes: a quiet
       row is not fitted. *)
    | Read [] -> [ quiet "no goal awaits confirmation" ]
    | Read rows ->
      List.map
        (fun (row : goal_to_confirm) ->
           { tone = Question
           ; goes_to = Goal_to_confirm row.goal_id
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf "%s \xe2\x80\x94 the verifier proved it" row.title)
                 (waited ~now row.since_iso)
           })
        rows
  in
  let heading text = { tone = Heading; text; goes_to = Nowhere } in
  let blank = { tone = Quiet; text = ""; goes_to = Nowhere } in
  (heading "Coming up" :: wakes)
  (* "Awaiting you" is the badge's word for the four lists below together.
     Each heading names its own rows, so the badge's number reads as the
     sections under it rather than as any one of them. *)
  @ [ blank; heading "Holding a call" ]
  @ questions
  @ [ blank; heading "Answer a question" ]
  @ asked
  @ [ blank; heading "Confirm a goal" ]
  @ goals
  @ [ blank; heading "Stuck on you" ]
  @ stuck
;;

(** Indexes of the rows Enter can act on, in display order. The cursor moves
    over these, not over prose -- the same shape the answering overlay walks
    its own lines with, so two panels that both step a subset of their rows
    step it the same way. *)
let target_indexes lines =
  let rec loop index acc = function
    | [] -> List.rev acc
    | line :: rest ->
      loop
        (index + 1)
        (match line.goes_to with
         | Nowhere -> acc
         | Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _
         | Stuck_task _ -> index :: acc)
        rest
  in
  loop 0 [] lines
;;

(* Two destinations are the same target when they name the same held call,
   Goal or task, or the same ask by [Masc.Tui_decode_asks.equal_ask_key]: an
   installation's title is the package's and does not name the ask. *)
let equal_destination left right =
  match left, right with
  | Nowhere, Nowhere -> true
  | Keeper_holding left, Keeper_holding right ->
      String.equal left.keeper right.keeper && String.equal left.tool_call_id right.tool_call_id
  | Ask_to_answer left, Ask_to_answer right -> Masc.Tui_decode_asks.equal_ask_key left right
  | Goal_to_confirm left, Goal_to_confirm right | Stuck_task left, Stuck_task right ->
      String.equal left right
  | (Nowhere | Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _ | Stuck_task _), _ -> false
;;

let selected_index lines ~selected =
  match selected with
  | Nowhere -> None
  | Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _ | Stuck_task _ ->
      List.find_index (fun line -> equal_destination line.goes_to selected) lines
;;

let selected_line lines ~selected =
  Option.bind (selected_index lines ~selected) (List.nth_opt lines)
;;

type step = Next | Previous

let step lines ~selected direction =
  let targets =
    List.filter_map (fun line ->
      match line.goes_to with
      | Nowhere -> None
      | (Keeper_holding _ | Ask_to_answer _ | Goal_to_confirm _ | Stuck_task _)
        as target -> Some target)
      lines
  in
  match targets with
  | [] -> Nowhere
  | first :: _ ->
      (match List.find_index (equal_destination selected) targets with
       | None -> first
       | Some index ->
           let next = match direction with
             | Next -> min (List.length targets - 1) (index + 1)
             | Previous -> max 0 (index - 1)
           in
           List.nth targets next)
;;
