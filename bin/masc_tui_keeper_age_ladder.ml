module Bins = Masc.Keeper_memory_age_bins

type bin = Bins.bin

let oldest_first = [ Bins.Older; Bins.Under_week; Bins.Under_day; Bins.Under_hour ]

let count (bins : Bins.t) = function
  | Bins.Under_hour -> bins.under_hour
  | Bins.Under_day -> bins.under_day
  | Bins.Under_week -> bins.under_week
  | Bins.Older -> bins.older
;;

(* The three edges, each declared once with its unit. The seconds and the words
   below are both made from them. *)
type edge =
  | Hours of int
  | Days of int

let hour_edge = Hours 1
let day_edge = Days 1
let week_edge = Days 7

let seconds_of_edge = function
  | Hours n -> float_of_int n *. Masc_time_constants.hour
  | Days n -> Masc_time_constants.days_to_seconds n
;;

let edge_text ~ko = function
  | Hours n -> Printf.sprintf (if ko then "%d시간" else "%dh") n
  | Days n -> Printf.sprintf (if ko then "%d일" else "%dd") n
;;

let edge_seconds = function
  | Bins.Under_hour -> Some (seconds_of_edge hour_edge)
  | Bins.Under_day -> Some (seconds_of_edge day_edge)
  | Bins.Under_week -> Some (seconds_of_edge week_edge)
  | Bins.Older -> None
;;

(* A bin that holds nothing draws the digit 0, as the input trend strip does
   for a recorded zero. The middle dot is that strip's mark for a sample that
   is unavailable, so a measured zero does not borrow it. *)
let empty_mark = "0"
let unmeasured_mark = "?"

let name ~ko = if ko then "처음 본 뒤" else "since first seen"

let range_text ~ko bin =
  let edge = edge_text ~ko in
  match bin with
  | Bins.Under_hour -> if ko then edge hour_edge ^ " 미만" else "under " ^ edge hour_edge
  | Bins.Under_day ->
    if ko
    then edge hour_edge ^ "~" ^ edge day_edge
    else edge hour_edge ^ " to " ^ edge day_edge
  | Bins.Under_week ->
    if ko
    then edge day_edge ^ "~" ^ edge week_edge
    else edge day_edge ^ " to " ^ edge week_edge
  | Bins.Older -> if ko then edge week_edge ^ " 이상" else edge week_edge ^ " or older"
;;

type mark =
  | Empty
  | Bar of string

let marks bins =
  let counts = List.map (count bins) oldest_first in
  let peak = List.fold_left max 0 counts in
  List.map2
    (fun n glyph -> if n = 0 then Empty else Bar glyph)
    counts
    (Masc_tui_chart.sparkline_marks ~min:0 ~max:peak counts)
;;

let strip bins =
  marks bins
  |> List.map (function
    | Empty -> empty_mark
    | Bar glyph -> glyph)
  |> String.concat ""
;;

let cell_label = "facts"

let count_text = function
  | None -> cell_label ^ " " ^ unmeasured_mark
  | Some bins -> Printf.sprintf "%s %d" cell_label (Bins.total bins)
;;

let cell bins : Masc_tui_keeper_axis_cell.t =
  let text =
    match bins with
    | None -> count_text None
    | Some measured -> count_text bins ^ " " ^ strip measured
  in
  { text; tone = Quiet }
;;

let legend =
  Printf.sprintf
    "ordinary memory facts counted by time %s, oldest on the left (%s); bar height is \
     relative to the tallest bin of the same strip, %s is none, %s is not measured"
    (name ~ko:false)
    (String.concat ", " (List.map (range_text ~ko:false) oldest_first))
    empty_mark
    unmeasured_mark
;;

let rung_clauses ~ko bins =
  List.map
    (fun bin ->
      Printf.sprintf
        (if ko then "%s %d개" else "%s: %d")
        (range_text ~ko bin)
        (count bins bin))
    oldest_first
;;

(* [lead] names what is counted when no label above the row does. *)
let shape_clauses ~ko ~lead bins =
  (lead ^ name ~ko ^ " " ^ strip bins) :: rung_clauses ~ko bins
;;

let keeper_lead ~ko = if ko then "일반 기억 " else "ordinary facts "

let keeper_clauses ~ko = function
  | None -> [ keeper_lead ~ko ^ name ~ko ^ " " ^ unmeasured_mark ]
  | Some bins -> shape_clauses ~ko ~lead:(keeper_lead ~ko) bins
;;

type fleet =
  | Nobody_measured of { keepers : int }
  | Measured of
      { bins : Bins.t
      ; unmeasured_keepers : int
      }

let add (a : Bins.t) (b : Bins.t) : Bins.t =
  { under_hour = a.under_hour + b.under_hour
  ; under_day = a.under_day + b.under_day
  ; under_week = a.under_week + b.under_week
  ; older = a.older + b.older
  }
;;

let fleet_of
      ~refused_rows
      (keepers : Masc.Tui_decode_memory_health.memory_keeper_health list)
  =
  let measured =
    List.filter_map
      (fun (k : Masc.Tui_decode_memory_health.memory_keeper_health) -> k.mkh_age_bins)
      keepers
  in
  (* The server's fact totals count a row this build refused. That row has no
     ladder here, so it is named with the Keepers that have none. *)
  let unmeasured_keepers =
    List.length keepers - List.length measured + refused_rows
  in
  if List.is_empty measured && unmeasured_keepers > 0
  then Nobody_measured { keepers = unmeasured_keepers }
  else Measured { bins = List.fold_left add Bins.zero measured; unmeasured_keepers }
;;

let unmeasured_keepers_clause ~ko keepers =
  if ko
  then Printf.sprintf "미측정 키퍼 %d명" keepers
  else Masc_tui_message_layout.count_noun keepers "keeper" ^ " not measured"
;;

let fleet_clauses ~ko = function
  | Nobody_measured { keepers } ->
    [ name ~ko ^ " " ^ unmeasured_mark; unmeasured_keepers_clause ~ko keepers ]
  | Measured { bins; unmeasured_keepers = 0 } -> shape_clauses ~ko ~lead:"" bins
  | Measured { bins; unmeasured_keepers } ->
    shape_clauses ~ko ~lead:"" bins @ [ unmeasured_keepers_clause ~ko unmeasured_keepers ]
;;
