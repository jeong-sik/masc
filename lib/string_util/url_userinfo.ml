let redaction = "[REDACTED]"

(* RFC 3986 section 3.2: the authority runs up to the next "/", "?" or "#". *)
let authority_end value start =
  let len = String.length value in
  let rec loop i =
    if i >= len
    then len
    else (
      match value.[i] with
      | '/' | '?' | '#' -> i
      | _ -> loop (i + 1))
  in
  loop start
;;

(* "//host" is protocol-relative. In "scheme://host" the authority starts
   after the "://" only when that separator is the first delimiter in the
   value, so a "://" inside a path or query ("host/p?next=http://x") does not
   move the start. Anything else is a bare authority ("user:pw@host:8080"). *)
let authority_start value =
  if String.starts_with ~prefix:"//" value
  then 2
  else (
    let first_delim = authority_end value 0 in
    match String_util.find_substring value "://" with
    | Some scheme_end
      when scheme_end + 1 = first_delim
           && not (String.contains (String.sub value 0 scheme_end) '@') ->
      scheme_end + 3
    | Some _ | None -> 0)
;;

let redact value =
  let auth_start = authority_start value in
  let auth_end = authority_end value auth_start in
  if auth_end <= auth_start
  then value
  else (
    match String.rindex_opt (String.sub value auth_start (auth_end - auth_start)) '@' with
    | None -> value
    | Some at_idx ->
      let host_offset = auth_start + at_idx in
      String.concat
        ""
        [ String.sub value 0 auth_start
        ; redaction
        ; String.sub value host_offset (String.length value - host_offset)
        ])
;;
