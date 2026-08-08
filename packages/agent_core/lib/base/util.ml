(** Shared utility functions.

    Extracted from agent.ml, runtime_server.ml, sessions.ml,
    direct_evidence.ml, runtime_projection.ml, provider.ml, raw_trace.ml
    to eliminate duplication. *)

let first_some a b =
  match a with
  | Some _ -> a
  | None -> b
;;

let string_contains ~needle haystack =
  needle = ""
  ||
  try
    let (_ : int) = Str.search_forward (Str.regexp_string needle) haystack 0 in
    true
  with
  | Not_found -> false
;;

let json_parse_error detail = Error.Serialization (JsonParseError { detail })
let file_read_error ~path ~detail = Error.Io (FileOpFailed { op = "read"; path; detail })

let file_write_error ~path ~detail =
  Error.Io (FileOpFailed { op = "write"; path; detail })
;;

(** Append a single element to the tail of a list.
    This is [O(n)] in the length of [xs] because it copies [xs]. It is fine
    for one-off appends, but using it inside a loop to build a list yields
    quadratic cost; prefer cons-into-an-accumulator followed by [List.rev]. *)
let snoc xs x = xs @ [ x ]

let snoc_list xs ys = xs @ ys

(** Traverse a list with a function returning [result], short-circuit on first error. *)
let result_traverse ~f items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | x :: rest ->
      (match f x with
       | Ok v -> loop (v :: acc) rest
       | Error e -> Error e)
  in
  loop [] items
;;

(** Truncate string to [max_len], appending "..." if truncated. *)
let clip s max_len =
  if String.length s > max_len then String.sub s 0 max_len ^ "..." else s
;;

(** Safe substring: returns "" if start is past end or len is negative. *)
let safe_sub s start len =
  let actual_len = min len (String.length s - start) in
  if actual_len <= 0 then "" else String.sub s start actual_len
;;

let regex_match re str =
  try
    let (_ : int) = Str.search_forward re str 0 in
    true
  with
  | Not_found -> false
;;

(** Case-insensitive substring search. *)
let contains_substring_ci ~haystack ~needle =
  needle = "" || regex_match (Str.regexp_string_case_fold needle) haystack
;;

let filter_non_empty = List.filter (fun s -> s <> "")

let split_on_char_trim sep s =
  String.split_on_char sep s |> List.map String.trim |> filter_non_empty
;;

let trim_non_empty s =
  let trimmed = String.trim s in
  if trimmed = "" then None else Some trimmed
;;

let trim_non_empty_opt = function
  | None -> None
  | Some s -> trim_non_empty s
;;

let json_member_str key json =
  Yojson.Safe.Util.(json |> member key |> to_string_option) |> Option.value ~default:""
;;

let json_member_bool key json =
  Yojson.Safe.Util.(json |> member key |> to_bool_option) |> Option.value ~default:false
;;

let json_of_int_opt = function
  | None -> `Null
  | Some v -> `Int v
;;

let json_of_float_opt = function
  | None -> `Null
  | Some v -> `Float v
;;

let json_of_bool_opt = function
  | None -> `Null
  | Some v -> `Bool v
;;

let json_of_string_opt = function
  | None -> `Null
  | Some v -> `String v
;;

let json_of_string_list lst = `List (List.map (fun s -> `String s) lst)

let string_list_of_json lst =
  List.filter_map
    (function
      | `String s -> Some s
      | _ -> None)
    lst
;;

let json_of_string_pairs pairs = `Assoc (List.map (fun (k, v) -> k, `String v) pairs)
