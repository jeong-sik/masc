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
  || (Char.equal
        (Char.lowercase_ascii s.[pos + index])
        (Char.lowercase_ascii prefix.[index])
      && prefix_matches s pos prefix (index + 1))
;;

let has_prefix_at s pos prefix =
  pos >= 0 && pos + String.length prefix <= String.length s && prefix_matches s pos prefix 0
;;

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let prefix_boundary_ok s pos prefix =
  if String.ends_with ~suffix:"=" prefix
  then pos = 0 || not (is_ident_char s.[pos - 1])
  else true
;;

let rec find_prefix s pos prefix =
  if pos + String.length prefix > String.length s
  then None
  else if prefix_boundary_ok s pos prefix && has_prefix_at s pos prefix
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
let is_hspace ch = Char.equal ch ' ' || Char.equal ch '\t'

let rec skip_hspace s ~stop pos =
  if pos < stop && is_hspace s.[pos] then skip_hspace s ~stop (pos + 1) else pos
;;

let is_ascii_letter ch = ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z')

let is_escaped_at s pos =
  let rec count i acc =
    if i >= 0 && Char.equal s.[i] '\\' then count (i - 1) (acc + 1) else acc
  in
  count (pos - 1) 0 mod 2 = 1
;;

let update_quote_state s ~start ~stop in_dquote in_squote =
  let len = String.length s in
  let rec loop i =
    if i < stop
    then (
      (match s.[i] with
       | '\r' | '\n' ->
         in_dquote := false;
         in_squote := false
       | '"' when (not !in_squote) && not (is_escaped_at s i) ->
         in_dquote := not !in_dquote
       | '\'' when (not !in_dquote) && not (is_escaped_at s i) ->
         let is_contraction =
           i > 0
           && i + 1 < len
           && is_ascii_letter s.[i - 1]
           && is_ascii_letter s.[i + 1]
         in
         if not is_contraction then in_squote := not !in_squote
       | _ -> ());
      loop (i + 1))
  in
  loop start
;;

let header_value_end s ~stop ~in_dquote ~in_squote pos =
  let rec scan i =
    if i >= stop
    then i
    else (
      match s.[i] with
      | '\r' | '\n' -> i
      | '"' when in_dquote && not (is_escaped_at s i) -> i
      | '\'' when in_squote && not (is_escaped_at s i) -> i
      | _ -> scan (i + 1))
  in
  let raw_end = scan pos in
  let rec trim_trailing i =
    if i > pos && is_hspace s.[i - 1] then trim_trailing (i - 1) else i
  in
  trim_trailing raw_end
;;

let is_auth_scheme_header prefix =
  let lower = String.lowercase_ascii prefix in
  String.equal lower "authorization:" || String.equal lower "proxy-authorization:"
;;

let is_cookie_header prefix =
  let lower = String.lowercase_ascii prefix in
  String.equal lower "cookie:" || String.equal lower "set-cookie:"
;;

let known_http_auth_schemes =
  [ "bearer"
  ; "basic"
  ; "token"
  ; "digest"
  ; "negotiate"
  ; "ntlm"
  ; "aws4-hmac-sha256"
  ; "hmac"
  ; "hoba"
  ; "mutual"
  ; "oauth"
  ; "scram-sha-256"
  ; "vapid"
  ; "apikey"
  ; "api-key"
  ; "bot"
  ]
;;

let match_auth_scheme_end s ~stop pos =
  let rec loop = function
    | [] -> None
    | scheme :: rest ->
      let len = String.length scheme in
      if pos + len < stop && prefix_matches s pos scheme 0 && is_hspace s.[pos + len]
      then Some (skip_hspace s ~stop (pos + len))
      else loop rest
  in
  loop known_http_auth_schemes
;;

let redact_prefixes s prefixes =
  let buf = Buffer.create (String.length s) in
  let cursors = List.map (fun prefix -> { prefix; next = Not_looked }) prefixes in
  let in_dquote = ref false in
  let in_squote = ref false in
  let emit_raw start len =
    if len > 0
    then (
      update_quote_state s ~start ~stop:(start + len) in_dquote in_squote;
      Buffer.add_substring buf s start len)
  in
  let rec redact_range pos stop =
    match first_listed_occurrence s ~pos ~stop cursors with
    | None -> emit_raw pos (stop - pos)
    | Some (index, prefix) ->
      redact_range pos index;
      emit_raw index (String.length prefix);
      let after_prefix = index + String.length prefix in
      let is_auth = is_auth_scheme_header prefix in
      let is_cookie = is_cookie_header prefix in
      let token_pos =
        if String.ends_with ~suffix:":" prefix
        then (
          let ws_end = skip_hspace s ~stop after_prefix in
          (* For [Authorization:] / [Proxy-Authorization:], preserve known HTTP
             auth schemes (e.g. [Basic], [Token], [Negotiate], [Digest],
             [AWS4-HMAC-SHA256]) followed by horizontal whitespace and redact
             the full credential value that follows; unknown schemes and raw
             tokens are redacted from [ws_end] to the end of the header value so
             no credential bytes ever leak. *)
          let scheme_end =
            if is_auth
            then Option.value ~default:ws_end (match_auth_scheme_end s ~stop ws_end)
            else ws_end
          in
          emit_raw after_prefix (scheme_end - after_prefix);
          scheme_end)
        else after_prefix
      in
      let token_stop =
        if is_auth || is_cookie
        then
          header_value_end
            s
            ~stop
            ~in_dquote:!in_dquote
            ~in_squote:!in_squote
            token_pos
        else token_end s ~stop token_pos
      in
      if token_stop > token_pos then Buffer.add_string buf redaction_marker;
      redact_range token_stop stop
  in
  redact_range 0 (String.length s);
  Buffer.contents buf
;;

let is_authority_delimiter = function
  | '/' | '?' | '#' | ' ' | '\t' | '\r' | '\n' | '"' | '\'' | ')' | ']' | '>' -> true
  | _ -> false
;;

let has_scheme_sep_at s ~stop i =
  i + 3 <= stop
  && Char.equal s.[i] ':'
  && Char.equal s.[i + 1] '/'
  && Char.equal s.[i + 2] '/'
;;

let find_authority_end s ~pos ~stop =
  let rec loop i =
    if i >= stop || is_authority_delimiter s.[i] || has_scheme_sep_at s ~stop i
    then i
    else loop (i + 1)
  in
  loop pos
;;

let last_char_in_range s ~start ~stop target =
  let rec loop i found =
    if i >= stop then found
    else loop (i + 1) (if Char.equal s.[i] target then Some i else found)
  in
  loop start None
;;

let redact_url_userinfo s =
  let stop = String.length s in
  match find_prefix s 0 "://" with
  | None -> s
  | Some first_sep ->
    let buf = Buffer.create stop in
    let rec scan pos next_sep_opt =
      match next_sep_opt with
      | None -> Buffer.add_substring buf s pos (stop - pos)
      | Some sep ->
        let auth_start = sep + 3 in
        let auth_end = find_authority_end s ~pos:auth_start ~stop in
        let authority_colon =
          let rec find_colon i =
            if i >= auth_end then None
            else if Char.equal s.[i] ':' then Some i
            else find_colon (i + 1)
          in
          find_colon auth_start
        in
        (match authority_colon with
         | Some colon ->
           (match last_char_in_range s ~start:(colon + 1) ~stop:auth_end '@' with
            | Some at ->
              Buffer.add_substring buf s pos (auth_start - pos);
              Buffer.add_string buf redaction_marker;
              Buffer.add_char buf '@';
              Buffer.add_substring buf s (at + 1) (auth_end - at - 1)
            | None -> Buffer.add_substring buf s pos (auth_end - pos))
         | None -> Buffer.add_substring buf s pos (auth_end - pos));
        scan auth_end (find_prefix s auth_end "://")
    in
    scan 0 (Some first_sep);
    Buffer.contents buf
;;

let redact_private_key_block s =
  let stop = String.length s in
  match find_prefix s 0 "-----BEGIN" with
  | None -> s
  | Some first_start ->
    let buf = Buffer.create stop in
    let rec scan pos next_start_opt =
      match next_start_opt with
      | None -> Buffer.add_substring buf s pos (stop - pos)
      | Some start ->
        Buffer.add_substring buf s pos (start - pos);
        Buffer.add_string buf redaction_marker;
        (match find_prefix s (start + 10) "-----END" with
         | None -> ()
         | Some end_pos ->
           let block_end =
             match String.index_from_opt s end_pos '\n' with
             | Some nl -> nl + 1
             | None -> stop
           in
           scan block_end (find_prefix s block_end "-----BEGIN"))
    in
    scan 0 (Some first_start);
    Buffer.contents buf
;;

let builtin_prefixes =
  [ "Bearer "
  ; "Bearer\t"
  ; "x-goog-api-key:"
  ; "x-auth-token:"
  ; "x-api-key:"
  ; "api-key:"
  ; "Proxy-Authorization:"
  ; "Authorization:"
  ; "Set-Cookie:"
  ; "Cookie:"
  ; "api_key="
  ; "token="
  ; "key="
  ]
;;

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

let rec redact_json (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `String s -> `String (redact_string s)
  | `Assoc pairs -> `Assoc (List.map (fun (k, v) -> k, redact_json v) pairs)
  | `List xs -> `List (List.map redact_json xs)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as leaf -> leaf
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

let max_redacted_excerpt_bytes = 256

let redacted_excerpt raw =
  let redacted = redact_string raw in
  if String.length redacted <= max_redacted_excerpt_bytes
  then redacted
  else
    Agent_core_strings.utf8_prefix ~max_bytes:max_redacted_excerpt_bytes redacted
    ^ "...(truncated)"
;;
