type bin = int

type edge =
  | Hour
  | Day
  | Week
  | Month

type span =
  | Hours of int
  | Days of int

let edges = [ Hour; Day; Week; Month ]

let edge_span = function
  | Hour -> Hours 1
  | Day -> Days 1
  | Week -> Days 7
  | Month -> Days 30
;;

let span_seconds = function
  | Hours n -> float_of_int n *. Masc_time_constants.hour
  | Days n -> Masc_time_constants.days_to_seconds n
;;

let edge_seconds edge = span_seconds (edge_span edge)

(* How many bins split the ages from one edge to the next (E28). *)
let hour_to_day_bins = 8
let day_to_week_bins = 8
let week_to_month_bins = 6
let newest = 0

let edge_bin = function
  | Hour -> newest + 1
  | Day -> newest + 1 + hour_to_day_bins
  | Week -> newest + 1 + hour_to_day_bins + day_to_week_bins
  | Month -> newest + 1 + hour_to_day_bins + day_to_week_bins + week_to_month_bins
;;

let oldest = edge_bin Month
let bin_count = oldest + 1
let bins = List.init bin_count Fun.id
let index bin = bin

let segments =
  [ Hour, Day, hour_to_day_bins; Day, Week, day_to_week_bins; Week, Month, week_to_month_bins ]
;;

(* The bins from [low] to [high], each a log step older than the one before.
   The first is [low × ratio ** 0.0], which is [low] exactly, so every edge
   starts its bin to the second. *)
let segment_starts (low, high, steps) =
  let ratio = edge_seconds high /. edge_seconds low in
  List.init steps (fun step ->
    edge_seconds low *. Float.pow ratio (float_of_int step /. float_of_int steps))
;;

(* The youngest age each bin counts, bin 0 first. *)
let lower_edges =
  Array.of_list ((0.0 :: List.concat_map segment_starts segments) @ [ edge_seconds Month ])
;;

(* An array the module builds and never hands out, so the counts cannot change
   after construction. *)
type t = int array

let zero = Array.make bin_count 0

let classify ~now ts =
  let age = if ts > now then 0.0 else now -. ts in
  (* The oldest bin whose lower edge the age reaches. *)
  let rec reached k = if k = newest || age >= lower_edges.(k) then k else reached (k - 1) in
  reached oldest
;;

let of_first_seen ~now timestamps =
  let counts = Array.make bin_count 0 in
  List.iter
    (fun ts ->
      let bin = classify ~now ts in
      counts.(bin) <- counts.(bin) + 1)
    timestamps;
  counts
;;

let count t bin = t.(bin)
let total t = Array.fold_left ( + ) 0 t
let add a b = Array.init bin_count (fun k -> a.(k) + b.(k))
let to_json t = `List (Array.to_list (Array.map (fun n -> `Int n) t))

let of_json = function
  | `List items ->
    let rec counts acc = function
      | [] -> Ok (List.rev acc)
      | `Int n :: rest when n >= 0 -> counts (n :: acc) rest
      | `Int n :: _ -> Error (Printf.sprintf "age_bins count %d is negative" n)
      | other :: _ ->
        Error
          (Printf.sprintf
             "age_bins count must be an int, got %s"
             (Yojson.Safe.to_string other))
    in
    (match counts [] items with
     | Error err -> Error err
     | Ok counts when List.length counts = bin_count -> Ok (Array.of_list counts)
     | Ok counts ->
       Error
         (Printf.sprintf
            "age_bins must hold %d counts, got %d"
            bin_count
            (List.length counts)))
  | other ->
    Error
      (Printf.sprintf
         "expected age_bins array of %d counts, got %s"
         bin_count
         (Yojson.Safe.to_string other))
;;
