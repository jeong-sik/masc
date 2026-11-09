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

(** Append a single element to the tail of a list.
    This is [O(n)] in the length of [xs] because it copies [xs]. It is fine
    for one-off appends, but using it inside a loop to build a list yields
    quadratic cost; prefer cons-into-an-accumulator followed by [List.rev]. *)
let snoc xs x = xs @ [ x ]

let snoc_list xs ys = xs @ ys

(** Truncate string to [max_len] bytes on a UTF-8 character boundary,
    appending "..." if truncated. *)
let clip s max_len =
  if String.length s > max_len
  then Agent_core_strings.utf8_prefix ~max_bytes:max_len s ^ "..."
  else s
;;

let regex_match re str =
  try
    let (_ : int) = Str.search_forward re str 0 in
    true
  with
  | Not_found -> false
;;

(** Case-insensitive substring search. Delegates to the dependency-free leaf:
    [Str] keeps its match state in globals, which is unsound under fibers, and
    recompiles the pattern on every call. *)
let contains_substring_ci = Agent_core_strings.contains_substring_ci

let filter_non_empty = List.filter (fun s -> s <> "")

let trim_non_empty s =
  let trimmed = String.trim s in
  if trimmed = "" then None else Some trimmed
;;

let trim_non_empty_opt = function
  | None -> None
  | Some s -> trim_non_empty s
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
