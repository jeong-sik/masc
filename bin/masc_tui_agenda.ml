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

type t =
  { coming : scheduled list  (** earliest first *)
  ; blocked : awaiting list
  }

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

let project ~scheduled ~awaiting =
  { coming = scheduled |> List.filter is_coming |> List.sort by_time
  ; blocked = awaiting
  }
;;

let next t = match t.coming with row :: _ -> Some row | [] -> None

(* One predicate, two readers: the row the frame draws and the row the
   keypress bound subtracts are the same row or neither exists. *)
let is_silent t = t.coming = [] && t.blocked = []
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
  | None -> Masc.Tui_decode.short_timestamp_for_terminal row.at_iso
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
    let waiting = waiting_half (List.length t.blocked) in
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

type line =
  { tone : tone
  ; text : string
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

let overlay ~now ~localtime ~cols t =
  let quiet text = { tone = Quiet; text = "  " ^ text } in
  let wakes =
    match t.coming with
    | [] -> [ quiet "nothing is scheduled" ]
    | rows ->
      List.map
        (fun row ->
           { tone = Wake
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
    | [] -> [ quiet "nobody is waiting on you" ]
    | rows ->
      List.map
        (fun (held : awaiting) ->
           { tone = Question
           ; text =
               two_column
                 ~cols
                 (Printf.sprintf "%s is holding %s" held.asked_by held.question)
                 (time_left ~now held)
           })
        rows
  in
  ({ tone = Heading; text = "Coming up" } :: wakes)
  @ [ { tone = Quiet; text = "" }; { tone = Heading; text = "Waiting on you" } ]
  @ questions
;;
