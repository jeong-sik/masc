open Tui_decode_fields
open Result.Syntax
module Standing = Keeper_memory_recall_standing

type memory_recall_reading =
  { mrr_lane : (unit, Standing.reason) result
  ; mrr_keepers : (string * Standing.t) list
  }

let reason_of_word ~field word =
  match Standing.reason_of_string word with
  | Some reason -> Ok reason
  | None -> Error (Printf.sprintf "%s: unknown word %S" field word)
;;

(* The lane is told by its own reasons only. *)
let lane_of_word word =
  if String.equal word Standing.lane_armed_word
  then Ok (Ok ())
  else
    let* reason = reason_of_word ~field:"lane" word in
    if Standing.is_lane_reason reason
    then Ok (Error reason)
    else Error (Printf.sprintf "lane: %S is not a reason of the lane" word)
;;

let standing_of_word word =
  if String.equal word Standing.judged_word
  then Ok Standing.Judged
  else
    Result.map
      (fun reason -> Standing.Not_judged reason)
      (reason_of_word ~field:"standing" word)
;;

let decode_keeper row =
  let* name = required_string_field row "name" in
  let* word = required_string_field row "standing" in
  let* standing = standing_of_word word in
  Ok (name, standing)
;;

let first_repeated names =
  let rec loop seen = function
    | [] -> None
    | name :: rest -> if List.mem name seen then Some name else loop (name :: seen) rest
  in
  loop [] names
;;

let decode_memory_recall_reading json =
  let* lane_word = required_string_field json "lane" in
  let* mrr_lane = lane_of_word lane_word in
  let* rows = required_list_field json "keepers" in
  let* mrr_keepers = decode_list "keepers" decode_keeper rows in
  match first_repeated (List.map fst mrr_keepers) with
  | Some name -> Error (Printf.sprintf "keepers: %S is listed twice" name)
  | None -> Ok { mrr_lane; mrr_keepers }
;;
