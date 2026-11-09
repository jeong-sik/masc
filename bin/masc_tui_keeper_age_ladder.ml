module Bins = Masc.Keeper_memory_age_bins

type bin = Bins.bin

(* An age in the unit a person reads it in. Korean reads one day as 하루. *)
let span_text ~ko = function
  | Bins.Days 1 when ko -> "하루"
  | Bins.Hours n -> Printf.sprintf (if ko then "%d시간" else "%dh") n
  | Bins.Days n -> Printf.sprintf (if ko then "%d일" else "%dd") n
;;

type group =
  | Past_week
  | Within_week
  | Within_day

let groups_oldest_first = [ Past_week; Within_week; Within_day ]
let groups_newest_first = List.rev groups_oldest_first

(* The bins before the one the day edge starts are under a day, those before
   the week edge's bin a day to seven days, the rest older. No bin crosses an
   edge, so a bin's group is the group of every fact in it. *)
let group_of_bin bin =
  let k = Bins.index bin in
  if k < Bins.index (Bins.edge_bin Bins.Day)
  then Within_day
  else if k < Bins.index (Bins.edge_bin Bins.Week)
  then Within_week
  else Past_week
;;

let group_count bins group =
  List.fold_left
    (fun sum bin -> if group_of_bin bin = group then sum + Bins.count bins bin else sum)
    0
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

let tick_line ~column =
  let line = Bytes.make (max 0 column) ' ' in
  (match merge_of_column column with
   | None -> ()
   | Some merge ->
     (* A tick names an edge at the cell of the bin the edge starts. In the
        column it stands at [(column − cells) + cells − 1 − ⌊k ÷ merge⌋], the
        cells being on the right. [right] is where the tick placed before it
        starts; the youngest edge is placed first. *)
     let place right edge =
       let text = span_text ~ko:false (Bins.edge_span edge) in
       let k = Bins.index (Bins.edge_bin edge) in
       let at = column - 1 - (k / merge) in
       if at < 0 || at + String.length text + 1 > right
       then right
       else (
         Bytes.blit_string text 0 line at (String.length text);
         at)
     in
     ignore (List.fold_left place (column + 1) Bins.edges : int));
  Bytes.to_string line
;;

let column_legend ~empty =
  let edge e = span_text ~ko:false (Bins.edge_span e) in
  Printf.sprintf
    "the server's %d age bins, %s or older on the left and under %s on the right, on log \
     steps between the edges %s, two or four bins to a cell on a narrow list; a cell is a \
     level against the row's largest one, %s when empty, in the info colour under %s, the \
     row's own to %s and dim past that"
    Bins.bin_count
    (edge Bins.Month)
    (edge Bins.Hour)
    (String.concat ", " (List.map edge Bins.edges))
    empty
    (edge Bins.Day)
    (edge Bins.Week)
;;

(* {1 Words and the second-row strip} *)

let span_number = function
  | Bins.Hours n | Bins.Days n -> n
;;

let range_text ~ko low high =
  let sep = if ko then "~" else "–" in
  match low, high with
  | Bins.Hours _, Bins.Hours _ | Bins.Days _, Bins.Days _ ->
    string_of_int (span_number low) ^ sep ^ span_text ~ko high
  | Bins.Hours _, Bins.Days _ | Bins.Days _, Bins.Hours _ ->
    span_text ~ko low ^ sep ^ span_text ~ko high
;;

(* Each group is named by the edges it lies between. *)
let group_words ~ko group =
  let edge e = Bins.edge_span e in
  match group with
  | Within_day ->
    let under = span_text ~ko (edge Bins.Day) in
    if ko then under ^ " 안" else "under " ^ under
  | Within_week -> range_text ~ko (edge Bins.Day) (edge Bins.Week)
  | Past_week ->
    let over = span_text ~ko (edge Bins.Week) in
    if ko then over ^ " 넘음" else "over " ^ over
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
    "ordinary memory facts by time since first seen, one bar per group oldest first (%s); \
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
      groups_newest_first
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
