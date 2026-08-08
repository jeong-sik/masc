(** Best-effort secret redaction for strings and JSON values.

    This is a defence-in-depth layer: secrets should never be written to
    traces/logs in the first place, but if they leak in via user prompts,
    tool arguments, or provider error bodies, the redactor scrubs generic
    credential contexts before persistence or emission. It deliberately does
    not classify bare strings from provider-specific token formats.

    The scanner is intentionally simple (allocation-conscious string scanning)
    to avoid pulling in a regex library and to keep latency predictable in the
    hot trace path.

    @since 0.207.0 *)

let is_token_char ch =
  match ch with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '+' | '/' | '=' -> true
  | _ -> false
;;

let token_len s pos =
  let len = String.length s in
  let rec scan i = if i < len && is_token_char s.[i] then scan (i + 1) else i in
  scan pos - pos
;;

let redaction_marker = "[REDACTED]"
let media_redaction_marker = "[REDACTED_MEDIA]"

let is_uri_scheme_char ch =
  ('a' <= ch && ch <= 'z')
  || ('A' <= ch && ch <= 'Z')
  || ('0' <= ch && ch <= '9')
  || Char.equal ch '+'
  || Char.equal ch '-'
  || Char.equal ch '.'
;;

let starts_with_ci_at s pos ~prefix =
  let len = String.length s in
  let prefix_len = String.length prefix in
  if pos < 0 || pos + prefix_len > len
  then false
  else (
    let rec loop i =
      i = prefix_len
      || (Char.equal (Char.lowercase_ascii s.[pos + i]) (Char.lowercase_ascii prefix.[i])
          && loop (i + 1))
    in
    loop 0)
;;

let contains_substring_ci s needle =
  let len = String.length s in
  let needle_len = String.length needle in
  let rec matches_at pos i =
    i = needle_len
    || (Char.equal (Char.lowercase_ascii s.[pos + i]) (Char.lowercase_ascii needle.[i])
        && matches_at pos (i + 1))
  in
  let rec scan pos = pos + needle_len <= len && (matches_at pos 0 || scan (pos + 1)) in
  needle_len = 0 || scan 0
;;

let is_data_url_boundary s pos = pos = 0 || not (is_uri_scheme_char s.[pos - 1])

let is_data_url_header_terminal ch =
  Char.equal ch '"'
  || Char.equal ch '\''
  || Char.equal ch '<'
  || Char.equal ch '>'
  || Char.equal ch ' '
  || Char.equal ch '\t'
  || Char.equal ch '\n'
  || Char.equal ch '\r'
;;

let find_data_url_comma s pos =
  let len = String.length s in
  let rec loop i =
    if i >= len
    then None
    else (
      match s.[i] with
      | ',' -> Some i
      | '"' | '\'' | '<' | '>' | ' ' | '\t' | '\n' | '\r' -> None
      | '\000' .. '\b'
      | '\011' | '\012' | '\014'
      | '\015' .. '!'
      | '#' .. '&'
      | '(' .. '+'
      | '-' .. ';'
      | '='
      | '?' .. '\255' -> loop (i + 1))
  in
  loop pos
;;

let is_base64_payload_char ch =
  ('a' <= ch && ch <= 'z')
  || ('A' <= ch && ch <= 'Z')
  || ('0' <= ch && ch <= '9')
  || Char.equal ch '+'
  || Char.equal ch '/'
  || Char.equal ch '='
;;

let base64_payload_end s pos =
  let len = String.length s in
  let rec loop i = if i < len && is_base64_payload_char s.[i] then loop (i + 1) else i in
  loop pos
;;

let find_media_data_url s pos =
  let len = String.length s in
  let rec scan i =
    if i >= len
    then None
    else if is_data_url_boundary s i && starts_with_ci_at s i ~prefix:"data:"
    then (
      match find_data_url_comma s i with
      | None -> scan (i + 1)
      | Some comma ->
        let header = String.sub s i (comma - i) in
        if contains_substring_ci header ";base64"
        then Some (i, comma, base64_payload_end s (comma + 1))
        else scan (i + 1))
    else scan (i + 1)
  in
  scan pos
;;

let redact_media_data_url s =
  match find_media_data_url s 0 with
  | None -> None
  | Some first ->
    let buf = Buffer.create (String.length s) in
    let rec loop pos (start, comma, payload_end) =
      Buffer.add_substring buf s pos (start - pos);
      Buffer.add_substring buf s start (comma - start + 1);
      Buffer.add_string buf media_redaction_marker;
      match find_media_data_url s payload_end with
      | None -> Buffer.add_substring buf s payload_end (String.length s - payload_end)
      | Some next -> loop payload_end next
    in
    loop 0 first;
    Some (Buffer.contents buf)
;;

let has_prefix_at s pos prefix =
  let len = String.length s in
  let n = String.length prefix in
  if pos < 0 || pos + n > len
  then false
  else (
    let rec loop i = i = n || (Char.equal s.[pos + i] prefix.[i] && loop (i + 1)) in
    loop 0)
;;

let find_prefix s pos prefix =
  let len = String.length s in
  let n = String.length prefix in
  let rec scan i =
    if i + n > len then None else if has_prefix_at s i prefix then Some i else scan (i + 1)
  in
  scan pos
;;

(** Redact every occurrence of [prefix] by replacing the token that follows
    it with {!redaction_marker}. *)
let redact_prefixes s prefixes =
  let buf = Buffer.create (String.length s) in
  let rec loop pos =
    if pos >= String.length s
    then ()
    else (
      match
        List.find_map
          (fun prefix -> Option.map (fun i -> i, prefix) (find_prefix s pos prefix))
          prefixes
      with
      | None -> Buffer.add_substring buf s pos (String.length s - pos)
      | Some (i, prefix) ->
        Buffer.add_substring buf s pos (i - pos);
        Buffer.add_string buf prefix;
        let token_pos = i + String.length prefix in
        let tok_len = token_len s token_pos in
        Buffer.add_string buf redaction_marker;
        loop (token_pos + tok_len))
  in
  loop 0;
  Buffer.contents buf
;;

let redact_url_userinfo s =
  match String.index_opt s '/' with
  | Some i1 when i1 + 2 <= String.length s && s.[i1 + 1] = '/' ->
    let auth_start = i1 + 2 in
    let auth_end =
      match String.index_from_opt s auth_start '/' with
      | Some j -> j
      | None -> String.length s
    in
    let authority = String.sub s auth_start (auth_end - auth_start) in
    (match String.index_opt authority ':' with
     | Some colon ->
       (match String.index_from_opt authority colon '@' with
        | Some at ->
          let host = String.sub authority (at + 1) (String.length authority - at - 1) in
          let prefix = String.sub s 0 auth_start in
          let suffix = String.sub s auth_end (String.length s - auth_end) in
          prefix ^ "[REDACTED]@" ^ host ^ suffix
        | None -> s)
     | None -> s)
  | _ -> s
;;

let redact_private_key_block s =
  match find_prefix s 0 "-----BEGIN" with
  | None -> s
  | Some start ->
    (match find_prefix s (start + 10) "-----END" with
     | None ->
       let before = String.sub s 0 start in
       before ^ redaction_marker
     | Some end_pos ->
       let block_end =
         match String.index_from_opt s end_pos '\n' with
         | Some nl -> nl + 1
         | None -> String.length s
       in
       let before = String.sub s 0 start in
       let after = String.sub s block_end (String.length s - block_end) in
       before ^ redaction_marker ^ after)
;;

let builtin_prefixes = [ "Bearer "; "api-key: "; "x-api-key: "; "Authorization:"; "key=" ]

let redact_common_tokens s =
  let s = redact_url_userinfo s in
  let s = redact_private_key_block s in
  redact_prefixes s builtin_prefixes
;;

let redact_string s =
  match redact_media_data_url s with
  | Some redacted -> redact_common_tokens redacted
  | None -> redact_common_tokens s
;;

let rec redact_json = function
  | `String s -> `String (redact_string s)
  | `Assoc pairs -> `Assoc (List.map (fun (k, v) -> k, redact_json v) pairs)
  | `List xs -> `List (List.map redact_json xs)
  | other -> other
;;

let%test "redact_string masks Bearer token" =
  redact_string "Authorization: Bearer opaque-token" = "Authorization: Bearer [REDACTED]"
;;

let%test "redact_string masks api-key header" =
  redact_string "x-api-key: opaque-token" = "x-api-key: [REDACTED]"
;;

let%test "redact_string masks URL userinfo" =
  redact_string "https://user:secret@api.example.com/v1"
  = "https://[REDACTED]@api.example.com/v1"
;;

let%test "redact_string masks private key block" =
  let s = "-----BEGIN PRIVATE KEY-----\nABCD\n-----END PRIVATE KEY-----" in
  String.starts_with ~prefix:"[REDACTED]" (redact_string s)
;;

let%test "redact_json preserves structure" =
  redact_json (`Assoc [ "key", `String "Bearer tok" ])
  = `Assoc [ "key", `String "Bearer [REDACTED]" ]
;;

let%test "redact_string collapses base64 media data url" =
  let payload = String.make (128 * 1024) 'A' in
  redact_string ("data:image/png;base64," ^ payload)
  = "data:image/png;base64,[REDACTED_MEDIA]"
;;

let%test "redact_string preserves ordinary media metadata" =
  let payload = String.make (128 * 1024) 'A' in
  redact_string ("data:image/png;name=opaque-label;base64," ^ payload)
  = "data:image/png;name=opaque-label;base64,[REDACTED_MEDIA]"
;;

let%test "redact_string collapses embedded base64 media data url" =
  let payload = String.make (128 * 1024) 'A' in
  redact_string ("prefix data:image/png;base64," ^ payload ^ " suffix")
  = "prefix data:image/png;base64,[REDACTED_MEDIA] suffix"
;;

let%test "redact_string collapses media data url inside json text" =
  let payload = String.make (128 * 1024) 'A' in
  redact_string ("{\"url\":\"data:image/png;base64," ^ payload ^ "\",\"ok\":true}")
  = "{\"url\":\"data:image/png;base64,[REDACTED_MEDIA]\",\"ok\":true}"
;;

let%test "redact_string does not treat metadata key as data url" =
  redact_string "metadata:text/plain;base64,AAAA" = "metadata:text/plain;base64,AAAA"
;;

let%test "redact_json collapses image_url data url" =
  let payload = String.make (128 * 1024) 'A' in
  redact_json
    (`Assoc
        [ "image_url", `Assoc [ "url", `String ("data:image/png;base64," ^ payload) ] ])
  = `Assoc
      [ "image_url", `Assoc [ "url", `String "data:image/png;base64,[REDACTED_MEDIA]" ] ]
;;

let%test "redact_string preserves large non-secret payload" =
  let payload = String.make (128 * 1024) 'A' in
  redact_string payload = payload
;;

let%test "redact_string leaves ordinary text alone" =
  redact_string "hello world" = "hello world"
;;

let%test "redact_string does not infer credential meaning from a bare identifier" =
  redact_string "opaque_prefix_0123456789" = "opaque_prefix_0123456789"
;;
