module Bins = Masc.Keeper_memory_age_bins

type bin = Bins.bin

(* The ages the screens name, each declared with its unit. The seconds and
   the words are both made from them. *)
type span =
  | Hours of int
  | Days of int

let span_seconds = function
  | Hours n -> float_of_int n *. Masc_time_constants.hour
  | Days n -> Masc_time_constants.days_to_seconds n
;;

let span_text ~ko = function
  | Hours n -> Printf.sprintf (if ko then "%d시간" else "%dh") n
  | Days n -> Printf.sprintf (if ko then "%d일" else "%dd") n
;;

let hour_edge = Hours 1
let day_edge = Days 1
let week_edge = Days 7

type group =
  | Past_week
  | Within_week
  | Within_day
  | Within_hour

let groups_oldest_first = [ Past_week; Within_week; Within_day; Within_hour ]

(* Where the bin starts decides its group, as the mock's [cellZone] does. *)
let group_of_bin bin =
  let start = Bins.lower_edge bin in
  if start < span_seconds hour_edge
  then Within_hour
  else if start < span_seconds day_edge
  then Within_day
  else if start < span_seconds week_edge
  then Within_week
  else Past_week
;;

let group_count bins group =
  List.fold_left
    (fun sum bin -> if group_of_bin bin = group then sum + Bins.count bins bin else sum)
    0
    Bins.bins
;;

(* The age the group's youngest bin starts at. *)
let group_start group =
  List.fold_left
    (fun start bin ->
      if group_of_bin bin = group then Float.min start (Bins.lower_edge bin) else start)
    Float.infinity
    Bins.bins
;;

(* {1 The age view's column} *)

type merge = int

(* A drawn cell adds 1, 2 or 4 bins, so the column holds 24, 12 or 6 cells
   (E25). *)
let merges = [ 1; 2; 4 ]

let merge_of_column cells =
  List.find_opt (fun merge -> cells >= Bins.bin_count / merge) merges
;;

let bins_per_cell merge = merge

type cell =
  { count : int
  ; group : group
  }

let cells merge bins =
  (* [Bins.bins] runs newest first, so each chunk starts with its newest bin. *)
  let rec chunks = function
    | [] -> []
    | newest :: _ as rest ->
      let chunk = List.take merge rest in
      { count = List.fold_left (fun sum bin -> sum + Bins.count bins bin) 0 chunk
      ; group = group_of_bin newest
      }
      :: chunks (List.drop merge rest)
  in
  List.rev (chunks Bins.bins)
;;

(* The mock's [ladderTicks], newest first. *)
let tick_spans = [ hour_edge; Hours 6; day_edge; week_edge; Days 30 ]

let tick_line ~column =
  let line = Bytes.make (max 0 column) ' ' in
  (match merge_of_column column with
   | None -> ()
   | Some merge ->
     (* A tick names the bin whose edge is nearest its age. In the column it
        stands at [(column − cells) + cells − 1 − ⌊k ÷ merge⌋], the cells being
        on the right. [right] is where the tick placed before it starts. *)
     let place right span =
       let text = span_text ~ko:false span in
       let k = Bins.index (Bins.nearest_edge (span_seconds span)) in
       let at = column - 1 - (k / merge) in
       if at < 0 || at + String.length text + 1 > right
       then right
       else (
         Bytes.blit_string text 0 line at (String.length text);
         at)
     in
     ignore (List.fold_left place (column + 1) tick_spans : int));
  Bytes.to_string line
;;

(* {1 Words and the second-row strip} *)

(* An edge in the unit a person reads it in: hours under two days, days from
   there, each to the nearest whole. *)
let hours_until = Days 2

let span_of_seconds seconds =
  let nearest unit = Float.to_int (Float.round (seconds /. span_seconds unit)) in
  if seconds < span_seconds hours_until
  then Hours (nearest (Hours 1))
  else Days (nearest (Days 1))
;;

let span_number = function
  | Hours n | Days n -> n
;;

let range_text ~ko low high =
  let sep = if ko then "~" else "–" in
  match low, high with
  | Hours _, Hours _ | Days _, Days _ ->
    string_of_int (span_number low) ^ sep ^ span_text ~ko high
  | Hours _, Days _ | Days _, Hours _ -> span_text ~ko low ^ sep ^ span_text ~ko high
;;

(* Each group is named by the ages its bins span: from where its youngest bin
   starts to where the next older group starts. *)
let group_words ~ko group =
  let edge group = span_of_seconds (group_start group) in
  match group with
  | Past_week ->
    let since = span_text ~ko (edge Past_week) in
    if ko then Printf.sprintf "배운 지 %s 넘음" since
    else Printf.sprintf "learned over %s ago" since
  | Within_week -> range_text ~ko (edge Within_week) (edge Past_week)
  | Within_day -> range_text ~ko (edge Within_day) (edge Within_week)
  | Within_hour ->
    let under = span_text ~ko (edge Within_day) in
    if ko then under ^ " 안" else "under " ^ under
;;

(* A group that holds nothing draws the digit 0, as the input trend strip does
   for a recorded zero. The middle dot is that strip's mark for a sample that
   is unavailable, so a measured zero does not borrow it. *)
let empty_mark = "0"
let unmeasured_mark = "?"

type mark =
  | Empty
  | Bar of string

let marks bins =
  let counts = List.map (group_count bins) groups_oldest_first in
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
    "ordinary memory facts by time since first seen, in four groups oldest first (%s); \
     bar height is relative to the largest group of the same strip, %s is none, %s is \
     not measured"
    (String.concat ", " (List.map (group_words ~ko:false) groups_oldest_first))
    empty_mark
    unmeasured_mark
;;

let ages_clauses ~ko = function
  | None -> [ (if ko then "기억 나이 " else "fact ages ") ^ unmeasured_mark ]
  | Some bins ->
    List.map
      (fun group -> Printf.sprintf "%s %d" (group_words ~ko group) (group_count bins group))
      groups_oldest_first
;;

let keeper_clauses ~ko = function
  | None -> ages_clauses ~ko None
  | Some bins ->
    let facts = Bins.total bins in
    (if ko
     then Printf.sprintf "기억 %d개" facts
     else Masc_tui_message_layout.count_noun facts "fact")
    :: ages_clauses ~ko (Some bins)
;;

type fleet =
  | Nobody_measured of { keepers : int }
  | Measured of
      { bins : Bins.t
      ; unmeasured_keepers : int
      }

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
  else Measured { bins = List.fold_left Bins.add Bins.zero measured; unmeasured_keepers }
;;

let unmeasured_keepers_clause ~ko keepers =
  if ko
  then Printf.sprintf "미측정 키퍼 %d명" keepers
  else Masc_tui_message_layout.count_noun keepers "keeper" ^ " not measured"
;;

let fleet_clauses ~ko = function
  | Nobody_measured { keepers } ->
    ages_clauses ~ko None @ [ unmeasured_keepers_clause ~ko keepers ]
  | Measured { bins; unmeasured_keepers = 0 } -> ages_clauses ~ko (Some bins)
  | Measured { bins; unmeasured_keepers } ->
    ages_clauses ~ko (Some bins) @ [ unmeasured_keepers_clause ~ko unmeasured_keepers ]
;;
