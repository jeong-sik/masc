(** Secret_patterns — structural secret masking shared by every sink.

    Moved verbatim from [Observability_redact] (which now delegates here)
    so [masc_log] can mask without depending on the main masc library.
    Uses [Re] (thread-safe) instead of [Str]. *)

let sensitive_keys =
  [ "access_key"
  ; "access_key_id"
  ; "access_token"
  ; "api_key"
  ; "api_secret"
  ; "api_token"
  ; "apikey"
  ; "auth_token"
  ; "authorization"
  ; "bearer_token"
  ; "client_secret"
  ; "cookie"
  ; "credential"
  ; "credentials"
  ; "id_token"
  ; "passphrase"
  ; "password"
  ; "passwd"
  ; "private_key"
  ; "proxy-authorization"
  ; "refresh_token"
  ; "secret"
  ; "secret_access_key"
  ; "secret_key"
  ; "secretaccesskey"
  ; "session_token"
  ; "set-cookie"
  ; "token"
  ; "x-api-key"
  ; "x-auth-token"
  ; "x-goog-api-key"
  ]

let is_sensitive_key key =
  let lower = String.lowercase_ascii key in
  List.exists (String.equal lower) sensitive_keys

(** [://user:password@] in a URL.

    The user and the password sit in the URL's authority, which ends at the
    first [/], [?] or [#], and they are written in the characters RFC 3986
    section 3.2.1 gives userinfo. An [@] later in the path or the query is
    therefore not a credential separator: [https://cdn.example/npm/pkg@1.2.3]
    and [https://example.com/a?mail=me@example.com] are left as they are. A
    user with no password ([ssh://git@host]) names an account and is left
    too. The password may hold [:] and [@]; the match runs to the last [@] of
    the authority, where a URL parser splits userinfo from the host. *)
let url_credential =
  let userinfo_char extra =
    Re.alt
      [ Re.rg 'a' 'z'; Re.rg 'A' 'Z'; Re.rg '0' '9'; Re.set ("-._~%!$&'()*+,;=" ^ extra) ]
  in
  Re.seq
    [ Re.str "://"; Re.rep (userinfo_char ""); Re.char ':'; Re.rep1 (userinfo_char ":@")
    ; Re.char '@' ]

let url_credential_re = Re.compile url_credential

(** Common secret-bearing value patterns — structural prefixes only.

    Each pattern identifies a secret by its *structure* (a known prefix family
    or the [://user:pass@] URL shape), not by a length heuristic. A generic
    "20+ alphanumeric run" matcher is deliberately absent: it would classify
    ordinary identifiers (keeper names, commit hashes, task ids) as secrets by
    length alone, erasing them from observability fields, while every real
    prefix it would catch is already matched here in one shot (e.g.
    [sk-proj-...] via the [sk-] body below). Known secret *values* loaded from
    the environment remain
    redacted exactly by {!Keeper_secret_redaction}, which does not rely on this
    heuristic.

    Specific prefix regexes are hoisted to module level so they are compiled
    once at init, not rebuilt on every [redact_text] call. [Re] is thread-safe
    (see file header), so sharing compiled regexes across fibers/domains is
    safe — [url_credential_re] already does this. *)
let sk_prefixes = [ "sk-" ]
let sk = Re.seq [Re.bow; Re.alt (List.map Re.str sk_prefixes); Re.rep1 (Re.alt [Re.alnum; Re.char '-'])]
let sk_re = Re.compile sk

let stripe_key_prefixes = [ "sk_live_"; "sk_test_"; "rk_live_" ]

let stripe_key =
  Re.seq
    [ Re.bow
    ; Re.alt (List.map Re.str stripe_key_prefixes)
    ; Re.rep1 (Re.alt [ Re.alnum; Re.char '_' ])
    ]
let stripe_key_re = Re.compile stripe_key

let awsakia = Re.seq [Re.bow; Re.str "AKIA"; Re.repn Re.alnum 16 (Some 16); Re.eow]
let awsakia_re = Re.compile awsakia

(* AWS STS temporary access keys start with ASIA followed by 16 uppercase
   alphanumeric characters. Requiring uppercase + exact length + word boundary
   prevents false positives on ordinary words/timezones like "ASIAN" or
   "ASIA/SEOUL". *)
let awsasia =
  Re.seq
    [ Re.bow
    ; Re.str "ASIA"
    ; Re.repn (Re.alt [ Re.rg 'A' 'Z'; Re.rg '0' '9' ]) 16 (Some 16)
    ; Re.eow
    ]
let awsasia_re = Re.compile awsasia

let slack_token_prefixes = [ "xoxb-"; "xoxp-"; "xoxa-"; "xoxr-"; "xoxs-" ]

let slack_token =
  Re.seq
    [ Re.bow
    ; Re.alt (List.map Re.str slack_token_prefixes)
    ; Re.rep1 (Re.alt [ Re.alnum; Re.char '-' ])
    ]
let slack_token_re = Re.compile slack_token

(* GitHub token prefixes, per the official token-format table
   (docs.github.com "About authentication to GitHub", checked 2026-08-17):
   [ghp_] classic PAT, [github_pat_] fine-grained PAT, [gho_] OAuth access
   token, [ghu_] GitHub App user token, [ghs_] App installation token,
   [ghr_] App refresh token.

   The body includes [.] and [-] besides [alnum]/[_] because the stateless
   installation-token format ([ghs_APPID_JWT], staged rollout from
   2026-04-27) embeds a JWT: without [.] in the body the match would stop at
   the first dot and leave the JWT payload and signature bytes visible.
   Lengths are deliberately unconstrained — GitHub documents the 40-char
   assumption as already broken by the stateless format, and a masking layer
   must not leak a token because it is longer or shorter than expected. *)
let github_token_prefixes =
  [ "github_pat_"
  ; "ghp_"
  ; "gho_"
  ; "ghu_"
  ; "ghs_"
  ; "ghr_"
  ]

let github_token =
  Re.seq
    [ Re.bow
    ; Re.alt (List.map Re.str github_token_prefixes)
    ; Re.rep1 (Re.alt [ Re.alnum; Re.set "_-." ])
    ]

let github_token_re = Re.compile github_token

(* MASC Personal Access Tokens ([mpat_<id>.<64-hex>]) and Service credentials
   ([msvc_<id>.<64-hex>]), defined in [lib/auth/authz_credential_token.mli]. *)
let masc_credential_prefixes = [ "mpat_"; "msvc_" ]

let masc_credential_token =
  Re.seq
    [ Re.bow
    ; Re.alt (List.map Re.str masc_credential_prefixes)
    ; Re.rep1 (Re.alt [ Re.alnum; Re.set "_-." ])
    ]

let masc_credential_token_re = Re.compile masc_credential_token

(** A PEM private key block, header to footer.

    This was a hand-written substring scan that allocated a fresh
    [String.sub] at every byte position it tested -- 27 bytes copied per
    position, per marker, per message. Measured 2026-09-05 on this fleet it
    was the single largest allocation source in the server, 586 MB in thirty
    seconds, and it had matched nothing: the store holds no PEM block at all.
    Every other agent framework that redacts these does it with one regular
    expression; Hermes Agent's redactor is the same shape as the line below.

    The key type is a character class rather than the two literals the scan
    carried, so EC, DSA, OPENSSH and ENCRYPTED blocks are covered too. The
    old pair list would have let those through.

    An unterminated block still redacts to the end of the string. The scan
    did that by dropping the remainder once it had seen a header with no
    footer, and a block whose footer is missing because the text was
    truncated is exactly when leaking the body would be worst. *)
let pem_header_or_footer word =
  Re.seq
    [ Re.str "-----"
    ; Re.no_case (Re.str word)
    ; Re.rep (Re.no_case (Re.set "ABCDEFGHIJKLMNOPQRSTUVWXYZ "))
    ; Re.no_case (Re.str "PRIVATE KEY")
    ; Re.str "-----"
    ]

let pem_begin_re = Re.compile (pem_header_or_footer "BEGIN ")
let pem_end_re = Re.compile (pem_header_or_footer "END ")

let pem_private_key_re =
  Re.compile
    (Re.seq
       [ pem_header_or_footer "BEGIN "
       ; Re.alt
           [ Re.seq [ Re.non_greedy (Re.rep Re.any); pem_header_or_footer "END " ]
           ; Re.rep Re.any
           ]
       ])
;;

type source_span = { first_byte : int; past_byte : int }

type source_piece =
  | Copied of { source : source_span; text : string }
  | Masked of { source : source_span; replacement : string }

let source_of_piece = function
  | Copied { source; _ } | Masked { source; _ } -> source

let text_of_piece = function
  | Copied { text; _ } -> text
  | Masked { replacement; _ } -> replacement

let render_pieces pieces = String.concat "" (List.map text_of_piece pieces)

let copied_text text =
  if String.equal text "" then []
  else [ Copied { source = { first_byte = 0; past_byte = String.length text }; text } ]

(* Slice by the current output coordinates, retaining the original input
   coordinates. A later masking pass may match part of an earlier replacement;
   every such part still belongs to that replacement's entire source range. *)
let split_piece piece length =
  match piece with
  | Copied { source; text } ->
      let middle = source.first_byte + length in
      ( Copied { source = { source with past_byte = middle }; text = String.sub text 0 length }
      , Copied { source = { source with first_byte = middle };
                 text = String.sub text length (String.length text - length) } )
  | Masked { source; replacement } ->
      ( Masked { source; replacement = String.sub replacement 0 length }
      , Masked { source; replacement = String.sub replacement length (String.length replacement - length) } )

let take_output length pieces =
  let rec take reversed remaining pieces =
    if remaining = 0 then List.rev reversed, pieces
    else match pieces with
      | [] -> invalid_arg "Secret_patterns.take_output: invalid mapped range"
      | piece :: rest ->
          let size = String.length (text_of_piece piece) in
          if size <= remaining then take (piece :: reversed) (remaining - size) rest
          else let first, last = split_piece piece remaining in
            List.rev (first :: reversed), last :: rest
  in
  take [] length pieces

(* Splitting an earlier replacement can leave adjacent output pieces that own
   overlapping source ranges. Coalesce those into one actual replacement,
   preserving its final output verbatim and giving each source byte one owner. *)
let normalize_pieces pieces =
  List.fold_left
    (fun reversed piece -> match reversed with
       | previous :: rest
         when (source_of_piece previous).past_byte > (source_of_piece piece).first_byte ->
           let left = source_of_piece previous and right = source_of_piece piece in
           Masked
             { source = { first_byte = min left.first_byte right.first_byte;
                          past_byte = max left.past_byte right.past_byte }
             ; replacement = text_of_piece previous ^ text_of_piece piece
             } :: rest
       | _ -> piece :: reversed)
    [] pieces
  |> List.rev

let replace_matches ?(replacement = "[REDACTED]") ?prefix_group pattern pieces =
  let text = render_pieces pieces in
  let matches = Re.all pattern text in
  match matches with
  | [] -> pieces
  | _ :: _ ->
  let reversed, remaining, _ =
    List.fold_left
      (fun (reversed, remaining, position) group ->
         let first, past = Re.Group.offset group 0 in
         let first = match prefix_group with
           | None -> first
           | Some index -> Re.Group.stop group index in
         if first = past then reversed, remaining, position
         else
           let copied, remaining = take_output (first - position) remaining in
           let matched, remaining = take_output (past - first) remaining in
           match matched with
           | [] -> invalid_arg "Secret_patterns.replace_matches: empty match range"
           | first_piece :: rest ->
               let source = List.fold_left (fun source piece ->
                 let next = source_of_piece piece in
                 { first_byte = min source.first_byte next.first_byte;
                   past_byte = max source.past_byte next.past_byte })
                   (source_of_piece first_piece) rest in
               let masked = Masked { source; replacement } in
               masked :: List.rev_append copied reversed, remaining, past)
      ([], pieces, 0) matches
  in
  normalize_pieces (List.rev_append reversed remaining)

let mask_matches pattern pieces = replace_matches pattern pieces

(** Common secret-bearing value patterns. Specific prefixes are listed before
    any generic matcher so short, well-known tokens are not missed when they
    are embedded inside larger strings.

    Each prefix literal is anchored at a word boundary ([Re.bow]) so a
    word-internal substring is not mistaken for a key. Without the anchor, the
    [sk-] pattern matched the substring [sk-1234] inside the task id
    [task-1234] and redacted it to [ta\[REDACTED\]], destroying diagnostic
    identifiers in error previews (and any other observability field carrying a
    [task-XXXX] reference). [bow] rejects that match because [sk-] is preceded
    by the identifier char 'a'. [Re.bow]/[eow] are zero-width assertions, so
    [Re.replace_string] preserves the boundary character (=, space, quote)
    automatically. The [sk-] body allows [-] so modern [sk-proj-...] keys are
    matched in one shot instead of leaving a [-abc...] tail. [AKIA]/[ASIA] are
    anchored at both ends so a 17-char run is not truncated to its first 16 chars. *)
let secret_res =
  [ url_credential_re
  ; sk_re
  ; stripe_key_re
  ; awsakia_re
  ; awsasia_re
  ; github_token_re
  ; slack_token_re
  ; masc_credential_token_re
  ]

(* A text matches [Re.alt] of the patterns exactly when it matches one of them,
   and a replacement pass that finds no match returns its input. So when this
   scan finds nothing, every pass in [secret_res] would leave the text as it
   is, and [redact_text] skips them: one scan instead of eight for the text
   that carries no secret. When the scan finds a match the passes run in
   their order. *)
let any_secret_re =
  Re.compile
    (Re.alt
       [ url_credential
       ; sk
       ; stripe_key
       ; awsakia
       ; awsasia
       ; github_token
       ; slack_token
       ; masc_credential_token
       ])

(* Sensitive HTTP headers: field name, colon, and the rest of the line.
   Longer hyphenated names precede their suffixes so [proxy-authorization],
   [set-cookie], and [x-goog-api-key] match whole. The name and colon stay;
   the value is replaced. *)
let horizontal_space = Re.rep (Re.set " \t")

let sensitive_header_names =
  [ "proxy-authorization"
  ; "authorization"
  ; "x-goog-api-key"
  ; "x-api-key"
  ; "x-auth-token"
  ; "set-cookie"
  ; "cookie"
  ]

let sensitive_header_re =
  Re.compile
    (Re.seq
       [ Re.group
           (Re.seq
              [ Re.bow
              ; Re.no_case (Re.alt (List.map Re.str sensitive_header_names))
              ; horizontal_space
              ; Re.char ':'
              ; horizontal_space
              ])
       ; Re.rep1 (Re.compl [ Re.set "\r\n" ])
       ])
;;

let redact_pieces pieces =
  let pieces = mask_matches pem_private_key_re pieces in
  let pieces = replace_matches ~prefix_group:1 sensitive_header_re pieces in
  if Re.execp any_secret_re (render_pieces pieces)
  then List.fold_left (fun pieces pattern -> mask_matches pattern pieces) pieces secret_res
  else pieces

(* Synthetic word-character lookbehind used by incremental stream redaction.
   ['_'] is classified as a word char by [Re.Category.from_char], and no
   structural pattern starts with ['_'], so the 1-byte sentinel at [-1..0)
   always survives untouched as the first byte of the first [Copied] piece. *)
let redact_pieces_with_lookbehind ~prev_ended_word pieces =
  match prev_ended_word, pieces with
  | false, _ | true, [] -> redact_pieces pieces
  | true, _ :: _ ->
      let sentinel = Copied { source = { first_byte = -1; past_byte = 0 }; text = "_" } in
      match redact_pieces (sentinel :: pieces) with
      | Copied { source = { first_byte = -1; past_byte = 0 }; text = "_" } :: rest -> rest
      | Copied { source = { first_byte = -1; past_byte }; text } :: rest
        when past_byte > 0 && String.length text > 1 && Char.equal text.[0] '_' ->
          Copied
            { source = { first_byte = 0; past_byte }
            ; text = String.sub text 1 (String.length text - 1)
            }
          :: rest
      | [] | (Copied _ | Masked _) :: _ ->
          invalid_arg
            "Secret_patterns.redact_pieces_with_lookbehind: synthetic prefix consumed"

(* Exact match to [Re.Cset.alnum] and [Re.Category.from_char] in [re], so
   prefix-safety decisions agree bit-for-bit with [Re.bow], [Re.eow] and
   [Re.alnum] even on non-ASCII UTF-8 bytes. *)
let is_re_alnum = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '\170' | '\181' | '\186'
  | '\192' .. '\214'
  | '\216' .. '\246'
  | '\248' .. '\255' -> true
  | _ -> false

let is_word_char c = Char.equal c '_' || is_re_alnum c

let is_sk_body c = is_re_alnum c || Char.equal c '-'
let is_stripe_body c = is_re_alnum c || Char.equal c '_'
let is_token_dot_body c =
  is_re_alnum c || Char.equal c '_' || Char.equal c '-' || Char.equal c '.'
let is_upper_ascii_alnum = function
  | 'A' .. 'Z' | '0' .. '9' -> true
  | _ -> false

let is_url_userinfo_base = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
  | '-' | '.' | '_' | '~' | '%' | '!' | '$' | '&' | '\'' | '(' | ')'
  | '*' | '+' | ',' | ';' | '=' -> true
  | _ -> false

let is_pem_label_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | ' ' -> true
  | _ -> false

let exact_prefix_at s ~start ~len target =
  let tlen = String.length target in
  let n = min (len - start) tlen in
  let rec loop k =
    k = n || (Char.equal s.[start + k] target.[k] && loop (k + 1))
  in
  loop 0

let ci_prefix_at s ~start ~len target =
  let tlen = String.length target in
  let n = min (len - start) tlen in
  let rec loop k =
    k = n
    || (Char.equal (Char.lowercase_ascii s.[start + k]) target.[k] && loop (k + 1))
  in
  loop 0

let ci_equal_at s ~start target =
  let tlen = String.length target in
  let rec loop k =
    k = tlen
    || (Char.equal (Char.lowercase_ascii s.[start + k]) target.[k] && loop (k + 1))
  in
  start >= 0 && start + tlen <= String.length s && loop 0

let five_dashes_at s k =
  k + 5 <= String.length s
  && Char.equal s.[k] '-'
  && Char.equal s.[k + 1] '-'
  && Char.equal s.[k + 2] '-'
  && Char.equal s.[k + 3] '-'
  && Char.equal s.[k + 4] '-'

let all_chars_match s ~start ~len pred =
  let rec loop k = k >= len || (pred s.[k] && loop (k + 1)) in
  loop start

let has_unclosed_pem_block s =
  let len = String.length s in
  let rec loop pos =
    if pos >= len then false
    else
      match Re.exec_opt ~pos pem_begin_re s with
      | None -> false
      | Some begin_group ->
          let body_start = Re.Group.stop begin_group 0 in
          match Re.exec_opt ~pos:body_start pem_end_re s with
          | None -> true
          | Some end_group -> loop (Re.Group.stop end_group 0)
  in
  loop 0

let find_pem_footer_end s =
  match Re.exec_opt pem_end_re s with
  | None -> None
  | Some group -> Some (Re.Group.stop group 0)

let pem_holds_at s ~start ~len =
  if not (Char.equal s.[start] '-') then false
  else
    let begin_lit = "-----begin " in
    let begin_len = String.length begin_lit in
    let rem = len - start in
    if rem <= begin_len then ci_prefix_at s ~start ~len begin_lit
    else if not (ci_prefix_at s ~start ~len begin_lit) then false
    else
      let label_start = start + begin_len in
      let rec scan_label k =
        if k >= len then true
        else if is_pem_label_char s.[k] then scan_label (k + 1)
        else if Char.equal s.[k] '-' then
          let key_lit = "private key" in
          let key_len = String.length key_lit in
          if k - label_start < key_len
             || not (ci_equal_at s ~start:(k - key_len) key_lit)
          then false
          else
            let tail = len - k in
            if tail < 5 then all_chars_match s ~start:k ~len (Char.equal '-')
            else if five_dashes_at s k then
              Option.is_none (Re.exec_opt ~pos:(k + 5) pem_end_re s)
            else false
        else false
      in
      scan_label label_start

let url_credential_holds_at s ~start ~len =
  if not (Char.equal s.[start] ':') then false
  else
    let rem = len - start in
    if rem = 1 then true
    else if rem = 2 then Char.equal s.[start + 1] '/'
    else if Char.equal s.[start + 1] '/' && Char.equal s.[start + 2] '/' then
      let rec scan k seen_colon =
        if k >= len then true
        else
          let c = s.[k] in
          if seen_colon then
            if is_url_userinfo_base c || Char.equal c ':' || Char.equal c '@'
            then scan (k + 1) true
            else false
          else if Char.equal c ':' then scan (k + 1) true
          else if is_url_userinfo_base c then scan (k + 1) false
          else false
      in
      scan (start + 3) false
    else false

let unbounded_prefix_holds_at ~is_body s ~start ~len prefix =
  let plen = String.length prefix in
  let rem = len - start in
  if rem <= plen then exact_prefix_at s ~start ~len prefix
  else exact_prefix_at s ~start ~len prefix
       && all_chars_match s ~start:(start + plen) ~len is_body

(* Fixed-length [Re.eow]-anchored AWS keys (4-byte prefix + 16-byte body):
   hold up through length 20 so the 21st byte (or stream end) decides [Re.eow]. *)
let fixed_aws_holds_at ~is_body ~prefix s ~start ~len =
  let plen = String.length prefix in
  let rem = len - start in
  if rem <= plen then exact_prefix_at s ~start ~len prefix
  else if rem <= plen + 16 then
    exact_prefix_at s ~start ~len prefix
    && all_chars_match s ~start:(start + plen) ~len is_body
  else false

let sensitive_header_holds_at s ~start ~len name =
  let nlen = String.length name in
  let rem = len - start in
  if rem <= nlen then ci_prefix_at s ~start ~len name
  else if not (ci_prefix_at s ~start ~len name) then false
  else
    let rec skip_hspace k =
      if k < len && (Char.equal s.[k] ' ' || Char.equal s.[k] '\t')
      then skip_hspace (k + 1)
      else k
    in
    let k = skip_hspace (start + nlen) in
    if k = len then true
    else if Char.equal s.[k] ':' then
      let rec no_newline j =
        j >= len
        || (not (Char.equal s.[j] '\r')
            && not (Char.equal s.[j] '\n')
            && no_newline (j + 1))
      in
      no_newline (k + 1)
    else false

let word_bounded_token_groups =
  [ sk_prefixes, is_sk_body
  ; stripe_key_prefixes, is_stripe_body
  ; slack_token_prefixes, is_sk_body
  ; github_token_prefixes, is_token_dot_body
  ; masc_credential_prefixes, is_token_dot_body
  ]

let word_pattern_start_table =
  let tbl = Array.make 256 false in
  let mark c = tbl.(Char.code c) <- true in
  List.iter
    (fun (prefixes, _) ->
       List.iter (fun p -> if String.length p > 0 then mark p.[0]) prefixes)
    word_bounded_token_groups;
  mark 'A';
  List.iter
    (fun name ->
       if String.length name > 0 then (
         mark (Char.lowercase_ascii name.[0]);
         mark (Char.uppercase_ascii name.[0])))
    sensitive_header_names;
  tbl

let non_pem_holds_at ~prev_ended_word s ~start ~len =
  let c = s.[start] in
  if Char.equal c ':' && url_credential_holds_at s ~start ~len then true
  else if not word_pattern_start_table.(Char.code c) then false
  else
    let at_bow =
      if start = 0 then not prev_ended_word
      else not (is_word_char s.[start - 1])
    in
    if not at_bow then false
    else
      List.exists
        (fun (prefixes, is_body) ->
           List.exists (unbounded_prefix_holds_at ~is_body s ~start ~len) prefixes)
        word_bounded_token_groups
      || fixed_aws_holds_at ~is_body:is_re_alnum ~prefix:"AKIA" s ~start ~len
      || fixed_aws_holds_at ~is_body:is_upper_ascii_alnum ~prefix:"ASIA" s ~start ~len
      || List.exists (sensitive_header_holds_at s ~start ~len) sensitive_header_names

let scan_non_pem_hold ~prev_ended_word s =
  let len = String.length s in
  let rec loop i =
    if i >= len then len
    else if non_pem_holds_at ~prev_ended_word s ~start:i ~len then i
    else loop (i + 1)
  in
  loop 0

let source_offset_of_rendered_pieces pieces rendered_offset =
  let rec walk rendered_pos = function
    | [] -> 0
    | piece :: rest ->
        let source, piece_len, is_masked =
          match piece with
          | Copied { source; text } -> source, String.length text, false
          | Masked { source; replacement } -> source, String.length replacement, true
        in
        if rendered_offset <= rendered_pos then source.first_byte
        else if rendered_offset < rendered_pos + piece_len then
          if is_masked then source.first_byte
          else source.first_byte + (rendered_offset - rendered_pos)
        else if rest = [] then source.past_byte
        else walk (rendered_pos + piece_len) rest
  in
  walk 0 pieces

let safe_stream_prefix_len ~prev_ended_word s =
  let len = String.length s in
  if len = 0 then 0
  else
    let rec scan_pem i =
      if i >= len then len
      else if Char.equal s.[i] '-' && pem_holds_at s ~start:i ~len then i
      else scan_pem (i + 1)
    in
    let pem_hold = scan_pem 0 in
    (* Pass 1 ([pem_private_key_re]) runs before Pass 2 ([sensitive_header_re])
       and collapses any closed PEM block's newlines into [[REDACTED]]. When a
       PEM block is already present in [s], scan the post-PEM text as well so a
       header enclosing a closed PEM block stays held until its real newline. *)
    let non_pem_hold =
      let raw_hold = scan_non_pem_hold ~prev_ended_word s in
      if Re.execp pem_private_key_re s then
        let after_pem = mask_matches pem_private_key_re (copied_text s) in
        let after_pem_rendered = render_pieces after_pem in
        let after_pem_hold =
          scan_non_pem_hold ~prev_ended_word after_pem_rendered
          |> source_offset_of_rendered_pieces after_pem
        in
        min raw_hold after_pem_hold
      else raw_hold
    in
    min pem_hold non_pem_hold

let cut_before_straddling_match ~prev_ended_word text cut =
  let len = String.length text in
  if cut <= 0 || cut >= len then max 0 (min cut len)
  else
    let scan_text, offset =
      if prev_ended_word then "_" ^ text, 1 else text, 0
    in
    let tighten_from_matches re acc =
      List.fold_left
        (fun acc group ->
           let first = Re.Group.start group 0 - offset in
           let past = Re.Group.stop group 0 - offset in
           if first < acc && past > acc then max 0 first else acc)
        acc
        (Re.all re scan_text)
    in
    let acc =
      cut
      |> tighten_from_matches pem_private_key_re
      |> tighten_from_matches sensitive_header_re
      |> fun acc ->
      if Re.execp any_secret_re scan_text
      then List.fold_left (fun acc re -> tighten_from_matches re acc) acc secret_res
      else acc
    in
    let acc =
      List.fold_left
        (fun acc piece ->
           match piece with
           | Copied _ -> acc
           | Masked { source; _ } ->
               if source.first_byte < acc && source.past_byte > acc
               then min acc source.first_byte
               else acc)
        acc
        (redact_pieces_with_lookbehind ~prev_ended_word (copied_text text))
    in
    if acc <= 0 || acc >= len then acc
    else
      let prefix_scan = String.sub scan_text 0 (acc + offset) in
      let tighten_ending_at_cut re current =
        List.fold_left
          (fun current group ->
             let first = Re.Group.start group 0 - offset in
             let past = Re.Group.stop group 0 - offset in
             if first < current && past = current then max 0 first else current)
          current
          (Re.all re prefix_scan)
      in
      acc
      |> tighten_ending_at_cut awsakia_re
      |> tighten_ending_at_cut awsasia_re

let redact_text_mapped text = redact_pieces (copied_text text)
let redact_text text = render_pieces (redact_text_mapped text)

let redact_structural_values ?(replacement = "[REDACTED]") text =
  let pieces = copied_text text in
  let pieces = replace_matches ~replacement pem_private_key_re pieces in
  if Re.execp any_secret_re (render_pieces pieces)
  then
    List.fold_left
      (fun pieces pattern -> replace_matches ~replacement pattern pieces)
      pieces
      secret_res
    |> render_pieces
  else render_pieces pieces
;;

let has_secret_token_shape text =
  Re.execp pem_private_key_re text || Re.execp any_secret_re text
;;

(* A key is text too: a map keyed by URL (registry [auths], remote lists)
   carries credentials in its keys, so the key's text is redacted like any
   string. Whether the value is masked whole is decided on the key as it came.
   Two keys that differ only in their secret redact to the same text; both
   members are kept, in order, so no value is dropped here — a reader that
   folds members by name sees the last one. *)
let redact_json_with ~on_string json =
  let rec redact = function
    | `String s -> `String (on_string s)
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
               let key' = redact_text key in
               if is_sensitive_key key
               then (key', `String "[REDACTED]")
               else (key', redact value))
             fields)
    | `List items -> `List (List.map redact items)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as json -> json
  in
  redact json

let redact_json_strings json = redact_json_with ~on_string:redact_text json
