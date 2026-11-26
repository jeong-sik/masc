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
let sk = Re.seq [Re.bow; Re.str "sk-"; Re.rep1 (Re.alt [Re.alnum; Re.char '-'])]
let sk_re = Re.compile sk

let stripe_key =
  Re.seq
    [ Re.bow
    ; Re.alt [ Re.str "sk_live_"; Re.str "sk_test_"; Re.str "rk_live_" ]
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

let slack_token =
  Re.seq
    [ Re.bow
    ; Re.alt
        [ Re.str "xoxb-"; Re.str "xoxp-"; Re.str "xoxa-"; Re.str "xoxr-"; Re.str "xoxs-" ]
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
let github_token =
  Re.seq
    [ Re.bow
    ; Re.alt
        [ Re.str "github_pat_"
        ; Re.str "ghp_"
        ; Re.str "gho_"
        ; Re.str "ghu_"
        ; Re.str "ghs_"
        ; Re.str "ghr_"
        ]
    ; Re.rep1 (Re.alt [ Re.alnum; Re.set "_-." ])
    ]

let github_token_re = Re.compile github_token

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
let pem_private_key_re =
  let header_or_footer word =
    Re.seq
      [ Re.str "-----"
      ; Re.no_case (Re.str word)
      ; Re.rep (Re.no_case (Re.set "ABCDEFGHIJKLMNOPQRSTUVWXYZ "))
      ; Re.no_case (Re.str "PRIVATE KEY")
      ; Re.str "-----"
      ]
  in
  Re.compile
    (Re.seq
       [ header_or_footer "BEGIN "
       ; Re.alt
           [ Re.seq [ Re.non_greedy (Re.rep Re.any); header_or_footer "END " ]
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
  ]

(* A text matches [Re.alt] of the patterns exactly when it matches one of them,
   and a replacement pass that finds no match returns its input. So when this
   scan finds nothing, every pass in [secret_res] would leave the text as it
   is, and [redact_text] skips them: one scan instead of seven for the text
   that carries no secret. When the scan finds a match the passes run in
   their order. *)
let any_secret_re =
  Re.compile
    (Re.alt
       [ url_credential; sk; stripe_key; awsakia; awsasia; github_token; slack_token ])

(* Sensitive HTTP headers: field name, colon, and the rest of the line.
   Longer hyphenated names precede their suffixes so [proxy-authorization],
   [set-cookie], and [x-goog-api-key] match whole. The name and colon stay;
   the value is replaced. *)
let horizontal_space = Re.rep (Re.set " \t")

let sensitive_header_re =
  Re.compile
    (Re.seq
       [ Re.group
           (Re.seq
              [ Re.bow
              ; Re.no_case
                  (Re.alt
                     [ Re.str "proxy-authorization"
                     ; Re.str "authorization"
                     ; Re.str "x-goog-api-key"
                     ; Re.str "x-api-key"
                     ; Re.str "x-auth-token"
                     ; Re.str "set-cookie"
                     ; Re.str "cookie"
                     ])
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
