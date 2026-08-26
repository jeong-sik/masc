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
  }

type awaiting =
  { asked_by : string
  ; question : string
  }

type t =
  { next : scheduled option
  ; waiting : int
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

let earliest rows =
  rows
  |> List.filter is_coming
  |> List.fold_left
       (fun acc row ->
          match acc with
          | Some best when String.compare best.at_iso row.at_iso <= 0 -> Some best
          | Some _ | None -> Some row)
       None
;;

let project ~scheduled ~awaiting =
  { next = earliest scheduled; waiting = List.length awaiting }
;;

(* One predicate, two readers: the row the frame draws and the row the
   keypress bound subtracts are the same row or neither exists. *)
let is_silent t = t.next = None && t.waiting = 0
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

   Not a second copy of that badge. The strip windows its ring to fit, and the
   window grows around the active entry: on Connectors at eighty columns it
   read "‹11 Repos Code Changes ▸Connectors Runtime Config Resources Tools 1›",
   with Approvals among the eleven it had dropped and its count with it. This
   row is not windowed, so the count is on screen from wherever the operator
   is standing. *)
let waiting_half waiting =
  if waiting <= 0 then "" else Printf.sprintf "Awaiting you\xc2\xb7%d" waiting
;;

let strip ~now ~localtime ~cols t =
  if is_silent t
  then None
  else begin
    let waiting = waiting_half t.waiting in
    let reserved =
      if waiting = "" then 0 else Masc_tui_message_layout.display_width waiting + 2
    in
    let clock =
      match t.next with
      | None -> ""
      | Some row -> clock_half ~now ~localtime ~cells:(max 0 (cols - reserved)) row
    in
    Some { clock; waiting }
  end
;;
