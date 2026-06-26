type trace_kind =
  | Trace
  | Turn
  | Receipt

type t =
  | Url of string
  | File_uri of string
  | Pr of int
  | Commit of string
  | Trace_ref of trace_kind * string
  | File_path of string

let min_short_commit_hex_len = 7
let max_commit_hex_len = 64
let max_file_extension_len = 12

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let payload_after_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.sub value prefix_len (String.length value - prefix_len)

let is_hex_char = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let parse_commit value =
  let len = String.length value in
  if
    len >= min_short_commit_hex_len
    && len <= max_commit_hex_len
    && String.for_all is_hex_char value
  then Some (Commit value)
  else None

let parse_positive_int value =
  match int_of_string_opt value with
  | Some n when n > 0 -> Some n
  | Some _ | None -> None

let parse_pr value =
  let len = String.length value in
  if
    len > 3
    && (starts_with ~prefix:"PR#" value || starts_with ~prefix:"pr#" value)
  then Option.map (fun n -> Pr n) (parse_positive_int (String.sub value 3 (len - 3)))
  else if len > 1 && Char.equal value.[0] '#'
  then Option.map (fun n -> Pr n) (parse_positive_int (String.sub value 1 (len - 1)))
  else None

let has_payload_char value =
  String.exists
    (function
      | '/' | '.' -> false
      | _ -> true)
    value

let has_concrete_prefix_payload ~prefix value =
  let payload = payload_after_prefix ~prefix value |> String.trim in
  if String.equal payload "" || not (has_payload_char payload) then None else Some payload

let parse_url value =
  if starts_with ~prefix:"http://" value
  then Option.map (fun payload -> Url ("http://" ^ payload)) (has_concrete_prefix_payload ~prefix:"http://" value)
  else if starts_with ~prefix:"https://" value
  then Option.map (fun payload -> Url ("https://" ^ payload)) (has_concrete_prefix_payload ~prefix:"https://" value)
  else None

let parse_file_uri value =
  if starts_with ~prefix:"file://" value
  then Option.map (fun payload -> File_uri payload) (has_concrete_prefix_payload ~prefix:"file://" value)
  else None

let parse_trace value =
  if starts_with ~prefix:"trace:" value
  then Option.map (fun payload -> Trace_ref (Trace, payload)) (has_concrete_prefix_payload ~prefix:"trace:" value)
  else if starts_with ~prefix:"turn:" value
  then Option.map (fun payload -> Trace_ref (Turn, payload)) (has_concrete_prefix_payload ~prefix:"turn:" value)
  else if starts_with ~prefix:"receipt:" value
  then Option.map (fun payload -> Trace_ref (Receipt, payload)) (has_concrete_prefix_payload ~prefix:"receipt:" value)
  else None

let is_file_ref_char = function
  | '0' .. '9'
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '/'
  | '.'
  | '_'
  | '-'
  | '~'
  | '@'
  | ':' -> true
  | _ -> false

let is_extension_char = function
  | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false

let contains_path_separator value = String.contains value '/'

let has_plausible_extension value =
  match String.rindex_opt value '.' with
  | None -> false
  | Some idx ->
    let len = String.length value in
    let ext_len = len - idx - 1 in
    idx > 0
    && ext_len >= 1
    && ext_len <= max_file_extension_len
    && String.for_all is_file_ref_char value
    && String.for_all is_extension_char (String.sub value (idx + 1) ext_len)

let parse_file_path value =
  if
    String.for_all is_file_ref_char value
    && has_payload_char value
    && (contains_path_separator value || has_plausible_extension value)
  then Some (File_path value)
  else None

let has_known_prefix value =
  starts_with ~prefix:"http://" value
  || starts_with ~prefix:"https://" value
  || starts_with ~prefix:"file://" value
  || starts_with ~prefix:"trace:" value
  || starts_with ~prefix:"turn:" value
  || starts_with ~prefix:"receipt:" value

let of_string raw =
  let value = String.trim raw in
  if String.equal value "" then None
  else if has_known_prefix value
  then (
    match parse_url value with
    | Some _ as parsed -> parsed
    | None ->
      (match parse_file_uri value with
       | Some _ as parsed -> parsed
       | None -> parse_trace value))
  else (
    match parse_pr value with
    | Some _ as parsed -> parsed
    | None ->
      (match parse_commit value with
       | Some _ as parsed -> parsed
       | None -> parse_file_path value))

let trace_kind_to_string = function
  | Trace -> "trace"
  | Turn -> "turn"
  | Receipt -> "receipt"

let to_string = function
  | Url value -> value
  | File_uri path -> "file://" ^ path
  | Pr n -> "PR#" ^ string_of_int n
  | Commit value -> value
  | Trace_ref (kind, payload) -> trace_kind_to_string kind ^ ":" ^ payload
  | File_path value -> value

let is_concrete_string value = Option.is_some (of_string value)
