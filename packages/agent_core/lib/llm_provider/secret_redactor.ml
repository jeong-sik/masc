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

(* Where the token that starts at [pos] ends, reading no further than [stop]. *)
let rec token_end s ~stop pos =
  if pos < stop && is_token_char s.[pos] then token_end s ~stop (pos + 1) else pos
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

(* A top-level recursion: a local one closing over [s] allocated a closure at
   every boundary position a data URL scan visits. *)
let rec prefix_matches_ci s pos prefix index =
  index = String.length prefix
  || (Char.equal (Char.lowercase_ascii s.[pos + index]) (Char.lowercase_ascii prefix.[index])
      && prefix_matches_ci s pos prefix (index + 1))
;;

let starts_with_ci_at s pos ~prefix =
  pos >= 0
  && pos + String.length prefix <= String.length s
  && prefix_matches_ci s pos prefix 0
;;

let is_data_url_boundary s pos = pos = 0 || not (is_uri_scheme_char s.[pos - 1])

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
        if Agent_core_strings.contains_substring_ci ~haystack:header ~needle:";base64"
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

(* The scanning helpers are top-level recursions over explicit arguments. A
   local [let rec] that closes over the string allocates a closure on every
   call, and these run once per byte per prefix: 8.4 GB of a live server's
   allocation in four hours (2026-09-16). *)
let rec prefix_matches s pos prefix index =
  index = String.length prefix
  || (Char.equal s.[pos + index] prefix.[index] && prefix_matches s pos prefix (index + 1))
;;

let has_prefix_at s pos prefix =
  pos >= 0 && pos + String.length prefix <= String.length s && prefix_matches s pos prefix 0
;;

let rec find_prefix s pos prefix =
  if pos + String.length prefix > String.length s
  then None
  else if has_prefix_at s pos prefix
  then Some pos
  else find_prefix s (pos + 1) prefix
;;

(* Where a prefix next occurs, as far as one redaction has looked. *)
type next_occurrence =
  | Not_looked
  | Occurs_at of int
  | Occurs_nowhere_after

type prefix_cursor =
  { prefix : string
  ; mutable next : next_occurrence
  }

(* The first occurrence of the cursor's prefix at or after [pos]. The positions
   one redaction asks about never decrease, so an occurrence found earlier
   answers every later ask until [pos] passes it, and each prefix reads the
   text once. Looking again from every [pos] made a run of one prefix ahead of
   a later occurrence of another quadratic: 120 KB of [key=a ] before a
   [Bearer ] took 19 s. *)
let next_occurrence s cursor ~pos =
  match cursor.next with
  | Occurs_at index when index >= pos -> Some index
  | Occurs_nowhere_after -> None
  | Not_looked | Occurs_at _ ->
    let found = find_prefix s pos cursor.prefix in
    cursor.next
    <- (match found with
        | Some index -> Occurs_at index
        | None -> Occurs_nowhere_after);
    found
;;

(* The first prefix in list order that occurs in [[pos, stop)], at its first
   occurrence there. *)
let rec first_listed_occurrence s ~pos ~stop = function
  | [] -> None
  | cursor :: rest ->
    (match next_occurrence s cursor ~pos with
     | Some index when index + String.length cursor.prefix <= stop ->
       Some (index, cursor.prefix)
     | Some _ | None -> first_listed_occurrence s ~pos ~stop rest)
;;

(** Redact every occurrence of a prefix by replacing the token that follows it
    with {!redaction_marker}.

    The range is split at the first occurrence of the first listed prefix
    found in it, and the text before that occurrence is redacted the same way.
    Copying that text verbatim, as this used to, let a credential through when
    its prefix came before an earlier-listed one: [key=SECRET Bearer TOKEN]
    kept [SECRET]. The split keeps what a listed prefix claimed: in
    [Authorization: Bearer TOKEN] the token belongs to [Bearer ], and the text
    before it holds [Authorization:] with no token after it, which is left as
    it is rather than marked. *)
let redact_prefixes s prefixes =
  let buf = Buffer.create (String.length s) in
  let cursors = List.map (fun prefix -> { prefix; next = Not_looked }) prefixes in
  let rec redact_range pos stop =
    match first_listed_occurrence s ~pos ~stop cursors with
    | None -> Buffer.add_substring buf s pos (stop - pos)
    | Some (index, prefix) ->
      redact_range pos index;
      Buffer.add_string buf prefix;
      let token_pos = index + String.length prefix in
      let token_stop = token_end s ~stop token_pos in
      if token_stop > token_pos then Buffer.add_string buf redaction_marker;
      redact_range token_stop stop
  in
  redact_range 0 (String.length s);
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
