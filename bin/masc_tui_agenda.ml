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
  ; question : string
  ; asked_at : float
  ; timeout_sec : float
  }

(* A task whose only exit belongs to the operator, as
   [Operator_task_attention] projected it. Flattened to text here: the panel
   draws rows, and three surfaces describing the same row three ways is what
   the projection exists to prevent, so the sentence is made once over there. *)
(* What ends this wait, as [Operator_task_attention] already knows it: a stop
   is granted as a verdict in the verify queue, and work nobody holds is read
   on the task itself. Carried rather than re-derived here from [what], which
   is a sentence written for a reader. *)
type ends_at =
  | Verify_queue
  | The_task

type stalled =
  { task_id : string
  ; what : string
  ; since_iso : string
  ; ends_at : ends_at
  }

type 'row reading =
  | Not_read
  | Read_failed of string
  | Read of 'row list

type t =
  { coming : scheduled reading  (** earliest first *)
  ; blocked : awaiting reading
  ; stuck : stalled reading  (** longest wait first *)
  }

let rows_of = function
  | Read rows -> rows
  | Not_read | Read_failed _ -> []

(* [payload_target] arrives as ["keeper:edgar.a.poe"]. The kind is the same on
   every row the strip can draw, so it is a prefix that says nothing and costs
   seven cells of a line that has to fit a title. *)
let keeper_prefix = "keeper:"

let short_who who =
  let n = String.length keeper_prefix in
  if String.length who > n && String.sub who 0 n = keeper_prefix
  then String.sub who n (String.length who - n)
  else who
;;

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

let project ~scheduled ~awaiting ~stalled =
  { coming =
      (match scheduled with
       | Read rows -> Read (rows |> List.filter is_coming |> List.sort by_time)
       | (Not_read | Read_failed _) as unread -> unread)
  ; blocked = awaiting
  ; stuck = stalled
  }
;;

let next t = match rows_of t.coming with row :: _ -> Some row | [] -> None

(* One predicate, two readers: the row the frame draws and the row the
   keypress bound subtracts are the same row or neither exists. A section
   that was never read has no row to name, so the strip stays down for it
   the same way; the overlay is where the difference is said. *)
let is_silent t =
  rows_of t.coming = [] && rows_of t.blocked = [] && rows_of t.stuck = []
let rows_taken t = if is_silent t then 0 else 1

type strip =
  { clock : string
  ; waiting : string
  }

let same_day (a : Unix.tm) (b : Unix.tm) =
  a.Unix.tm_year = b.Unix.tm_year && a.Unix.tm_yday = b.Unix.tm_yday
;;

(* [Tui_decode.clock_timestamp_for_terminal] answers HH:MM:SS and this strip
   has one line to spend, so the seconds go. A wake the codec cannot read
   keeps its own text: a row that says nothing readable is still a row that
   says something is scheduled. *)
let hour_and_minute ~now ~localtime row =
  match Time_codec.parse_rfc3339_opt row.at_iso with
  | None -> Masc.Tui_decode.short_timestamp_for_terminal ~localtime row.at_iso
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
  let who = short_who row.who in
  let said =
    match String.trim row.what, String.trim who with
    | "", "" -> ""
    | "", who -> who
    | what, "" -> what
    | what, who -> Printf.sprintf "%s \xc2\xb7 %s" what who
  in
  let room = cells - Masc_tui_message_layout.display_width head in
  if room <= 0 then "" else head ^ Masc_tui_message_layout.fit_middle room said
;;

(* The same [label·count] shape the surface strip's Approvals badge uses, so
   two counts of blocked work on one screen read as one vocabulary.

   Not a second copy of that badge. The strip windows its ring to fit, and
   the window grows around the active entry: at eighty columns the entries
   far from the active one drop out, Approvals among them and its count with
   it. This row is not windowed, so the count is on screen from wherever the
   operator is standing. *)
let waiting_half waiting =
  if waiting <= 0 then "" else Printf.sprintf "Awaiting you\xc2\xb7%d" waiting
;;

let strip ~now ~localtime ~cols t =
  if is_silent t
  then None
  else begin
    (* One number for both: a keeper holding a tool call and a task only the
       operator can move are the same answer to "is anything waiting on me",
       and two badges beside each other would make the operator add them up. *)
    let waiting =
      waiting_half (List.length (rows_of t.blocked) + List.length (rows_of t.stuck))
    in
    let reserved =
      if waiting = "" then 0 else Masc_tui_message_layout.display_width waiting + 2
    in
    let clock =
      match next t with
      | None -> ""
      | Some row -> clock_half ~now ~localtime ~cells:(max 0 (cols - reserved)) row
    in
    Some { clock; waiting }
  end
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
  | Keeper_holding of string
      (** the keeper sitting on a tool call only an operator releases *)
  | Stuck_task of
      { task_id : string
      ; ends_at : ends_at
      }

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

let said row =
  let who = short_who row.who in
  match String.trim row.what, String.trim who with
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
   because the wait is long, and minutes past the first day are noise. A stamp
   this cannot read says nothing rather than saying zero. *)
let waited ~now since_iso =
  match Time_codec.parse_rfc3339_opt since_iso with
  | None -> ""
  | Some since ->
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

(* Sixty-two rows is not a panel, it is a wall, and the operator reads the
   oldest few and then goes to the tool. The count is the part that has to be
   exact; the rows are the part that has to fit. *)
let stalled_rows_shown = 5

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
    { tone = Failed; text = two_column ~cols reason ""; goes_to = Nowhere }
  in
  (* An empty section is an answer only once its list was read. Before that,
     or when the read failed, "nothing is scheduled" and "nobody is waiting on
     you" were said about lists no one had seen. *)
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
    | Read [] -> [ quiet "nobody is waiting on you" ]
    | Read rows ->
      List.map
        (fun (held : awaiting) ->
           { tone = Question
           ; goes_to = Keeper_holding held.asked_by
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf "%s is holding %s" held.asked_by held.question)
                 (time_left ~now held)
           })
        rows
  in
  let stuck =
    match t.stuck with
    | Not_read -> [ quiet "not loaded yet" ]
    | Read_failed reason -> [ failure ~cols reason ]
    | Read [] -> [ quiet "no task is stuck on you" ]
    | Read rows ->
      let shown = List.filteri (fun index _ -> index < stalled_rows_shown) rows in
      let hidden = List.length rows - List.length shown in
      List.map
        (fun (row : stalled) ->
           { tone = Question
           ; goes_to =
               Stuck_task { task_id = row.task_id; ends_at = row.ends_at }
           ; text = two_column ~cols row.what (waited ~now row.since_iso)
           })
        shown
      @
      if hidden <= 0
      then []
      else [ quiet (Printf.sprintf "and %d more \xe2\x80\x94 masc_operator_digest" hidden) ]
  in
  let heading text = { tone = Heading; text; goes_to = Nowhere } in
  let blank = { tone = Quiet; text = ""; goes_to = Nowhere } in
  (heading "Coming up" :: wakes)
  @ [ blank; heading "Waiting on you" ]
  @ questions
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
         | Keeper_holding _ | Stuck_task _ -> index :: acc)
        rest
  in
  loop 0 [] lines
;;
