(** Chain Utils - Safe Helper Functions

    Provides safe, exception-free alternatives to common OCaml stdlib functions.
    All functions return Option types or safe defaults instead of raising exceptions.
*)

(** {1 Safe List Helpers} *)

(** Safe version of List.nth - returns Option instead of raising Not_found *)
let list_nth_opt lst idx =
  if idx < 0 then None
  else
    let rec aux i = function
      | [] -> None
      | x :: _ when i = 0 -> Some x
      | _ :: xs -> aux (i - 1) xs
    in
    aux idx lst

(** Safe version of List.hd - returns Option *)
let list_hd_opt = function
  | [] -> None
  | x :: _ -> Some x

(** Safe version of List.tl - returns empty list if input is empty *)
let list_tl_safe = function
  | [] -> []
  | _ :: xs -> xs

(** Safe head/tail split - returns None if list is empty *)
let list_uncons = function
  | [] -> None
  | x :: xs -> Some (x, xs)

(** Safe last element - O(n) but safe *)
let list_last_opt lst =
  match lst with
  | [] -> None
  | _ -> Some (List.hd (List.rev lst))

(** {1 Safe String Helpers} *)

(** Check if string starts with prefix - safe, no exceptions *)
let starts_with ~prefix s =
  let p = String.length prefix in
  String.length s >= p && String.sub s 0 p = prefix

(** Check if string ends with suffix - safe, no exceptions *)
let ends_with ~suffix s =
  let p = String.length suffix in
  let len = String.length s in
  len >= p && String.sub s (len - p) p = suffix

(** Safe substring extraction - returns None if out of bounds *)
let string_sub_opt s start len =
  if start < 0 || len < 0 || start + len > String.length s then None
  else Some (String.sub s start len)

(** Safe string truncation with ellipsis *)
let truncate_with_ellipsis ?(max_len=160) s =
  if String.length s > max_len then String.sub s 0 max_len ^ "..."
  else s

(** Strip prefix if present, returns original string otherwise *)
let strip_prefix ~prefix s =
  if starts_with ~prefix s then
    String.sub s (String.length prefix) (String.length s - String.length prefix)
  else s

(** Strip suffix if present, returns original string otherwise *)
let strip_suffix ~suffix s =
  if ends_with ~suffix s then
    String.sub s 0 (String.length s - String.length suffix)
  else s

(** {1 Empty Response Handling} *)

(** Maximum retries for empty LLM responses (configurable via CHAIN_EMPTY_RETRIES env) *)
let max_empty_retries =
  Safe_parse.env_int ~var:"CHAIN_EMPTY_RETRIES" ~default:3

(** Check if response is empty or whitespace-only *)
let is_empty_response output =
  String.length (String.trim output) = 0

(** Enhancement prompt added on retry for empty responses *)
let empty_retry_suffix =
  "\n\n[IMPORTANT: You must provide a non-empty response. Do not return blank or empty output.]"

(** {1 Prompt Analysis Helpers} *)

(** Detect if a prompt is complex enough to benefit from thinking mode.
    Heuristics: length > 500 chars, contains code blocks, multi-step instructions *)
let is_complex_prompt prompt =
  let len = String.length prompt in
  let has_code = String.contains prompt '`' || Str.string_match (Str.regexp ".*```.*") prompt 0 in
  let has_steps = Str.string_match (Str.regexp ".*\\(step\\|1\\.\\|2\\.\\|3\\.\\|first\\|then\\|finally\\).*") (String.lowercase_ascii prompt) 0 in
  len > 500 || has_code || has_steps

(** Check if model is GLM variant *)
let is_glm_model model =
  let m = String.lowercase_ascii model in
  m = "glm" || String.length m >= 3 && String.sub m 0 3 = "glm"

(** Check if string contains substring - safe version using Str module *)
let string_contains ~substring str =
  try
    let _ = Str.search_forward (Str.regexp_string substring) str 0 in
    true
  with Not_found -> false
