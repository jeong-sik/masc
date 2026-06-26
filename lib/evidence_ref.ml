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

(* Minimum length of a git "short" commit id (git's default abbrev). Hex
   strings shorter than this are not treated as commit refs. *)
let min_short_commit_hex_len = 7
(* Maximum length of a commit hex id. 64 = SHA-256 hex; git SHA-1 is 40.
   Accept the longer form so SHA-256 repos are covered. *)
let max_commit_hex_len = 64
(* Upper bound on a plausible file extension (e.g. final segment of
   ".tar.gz"). Bounds the plausible-extension check in
   [has_plausible_extension]. *)
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

let is_decimal_digit = function
  | '0' .. '9' -> true
  | _ -> false

let parse_commit value =
  let len = String.length value in
  if
    len >= min_short_commit_hex_len
    && len <= max_commit_hex_len
    && String.for_all is_hex_char value
  then Some (Commit value)
  else None

let parse_positive_decimal value =
  if String.equal value "" || not (String.for_all is_decimal_digit value)
  then None
  else (
    match int_of_string_opt value with
    | Some n when n > 0 -> Some n
    | Some _ | None -> None)

let parse_pr value =
  let parse_prefixed ~prefix value =
    if starts_with ~prefix value
    then Option.map (fun n -> Pr n) (parse_positive_decimal (payload_after_prefix ~prefix value))
    else None
  in
  match parse_prefixed ~prefix:"PR#" value with
  | Some _ as parsed -> parsed
  | None ->
    (match parse_prefixed ~prefix:"pr#" value with
     | Some _ as parsed -> parsed
     | None -> parse_prefixed ~prefix:"#" value)

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

let is_reference_body_char = function
  | '0' .. '9'
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '/'
  | '_'
  | '-'
  | '~'
  | '@' -> true
  | _ -> false

let is_reference_connector_char = function
  | '.' | ':' | '?' | '&' | '=' | '%' | '#' | '+' -> true
  | _ -> false

let reference_char_extends_right haystack idx =
  if idx >= String.length haystack then false
  else if is_reference_body_char haystack.[idx] then true
  else if is_reference_connector_char haystack.[idx]
  then (
    let next = idx + 1 in
    next < String.length haystack && is_reference_body_char haystack.[next])
  else false

let reference_char_extends_left haystack idx =
  idx >= 0
  && idx < String.length haystack
  &&
  (is_reference_body_char haystack.[idx]
   || is_reference_connector_char haystack.[idx])

let boundary_match ~haystack ~needle ~start =
  let before = start = 0 || not (reference_char_extends_left haystack (start - 1)) in
  let after_idx = start + String.length needle in
  let after = not (reference_char_extends_right haystack after_idx) in
  before && after

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

let is_absolute_path value =
  String.length value > 0 && Char.equal value.[0] '/'

let contains_parent_segment value =
  (* Reject ".." as a path segment (parent-dir traversal). Matched only at
     a segment boundary so a literal ".." inside a file name (e.g. "v1..0")
     is not falsely rejected. *)
  let len = String.length value in
  let rec scan i =
    if i + 2 > len then false
    else if
      Char.equal value.[i] '.'
      && (i + 1 < len)
      && Char.equal value.[i + 1] '.'
      && (i = 0 || Char.equal value.[i - 1] '/')
      && (i + 2 = len || Char.equal value.[i + 2] '/')
    then true
    else scan (i + 1)
  in
  scan 0

let parse_file_path value =
  (* P0 (#22348 review): a concrete artifact reference must not be an
     absolute path or contain a parent-dir ("..") segment — both are
     gate-bypass shapes, not legitimate relative artifact refs. NOTE: this
     is shape validation only; the deeper "candidate vs validated"
     separation the review asks for (so even a/b and x.txt require a
     base-path-resolved validated variant before the gate accepts them) is
     deferred as a follow-up. *)
  if
    not (is_absolute_path value)
    && not (contains_parent_segment value)
    && String.for_all is_file_ref_char value
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

(* Formerly [is_concrete_string]. Renamed (#22348 review P1): the typed
   variant only recognizes a *shape* (url / commit / pr / file_path / …)
   — it does NOT semantically validate that the value is a real, existing,
   base-path-resolved artifact. Callers must not read "true" as "this is a
   concrete, trusted evidence reference". *)
let recognizes_evidence_shape value = Option.is_some (of_string value)
