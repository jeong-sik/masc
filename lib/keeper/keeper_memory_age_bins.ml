let bin_count = 24

type bin = int

(* The ladder's two exact edges. The bins between them start on equal log
   steps, so bin 1 starts at the lower edge and bin 23 at the upper one. *)
let hour_edge = Masc_time_constants.hour
let month_edge = Masc_time_constants.days_to_seconds 30
let log_steps = bin_count - 2
let span_ratio = month_edge /. hour_edge
let log_step = Float.log span_ratio /. float_of_int log_steps
let newest = 0
let oldest = bin_count - 1
let bins = List.init bin_count Fun.id
let index bin = bin

(* [span_ratio ** 1.0] is [span_ratio] exactly, so bin 23 starts at 30 days
   to the second, and bin 1 at one hour. *)
let edges =
  Array.init bin_count (fun k ->
    if k = newest
    then 0.0
    else hour_edge *. Float.pow span_ratio (float_of_int (k - 1) /. float_of_int log_steps))
;;

let lower_edge bin = edges.(bin)

let nearest_edge age =
  if age <= hour_edge
  then 1
  else if age >= month_edge
  then oldest
  else (
    let k = Float.to_int (Float.round (Float.log (age /. hour_edge) /. log_step)) + 1 in
    max 1 (min oldest k))
;;

(* An array the module builds and never hands out, so the counts cannot change
   after construction. *)
type t = int array

let zero = Array.make bin_count 0

let classify ~now ts =
  let age = if ts > now then 0.0 else now -. ts in
  (* The oldest bin whose lower edge the age reaches. *)
  let rec reached k = if k = newest || age >= edges.(k) then k else reached (k - 1) in
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
