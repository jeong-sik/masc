(** Secret_patterns — structural secret masking shared by every sink.

    Moved verbatim from [Observability_redact] (which now delegates here)
    so [masc_log] can mask without depending on the main masc library.
    Uses [Re] (thread-safe) instead of [Str]. *)

let sensitive_keys =
  [ "access_token"
  ; "api_key"
  ; "api_token"
  ; "apikey"
  ; "authorization"
  ; "client_secret"
  ; "credential"
  ; "credentials"
  ; "password"
  ; "passwd"
  ; "private_key"
  ; "refresh_token"
  ; "secret"
  ; "token"
  ]

let is_sensitive_key key =
  let lower = String.lowercase_ascii key in
  List.exists (String.equal lower) sensitive_keys

(** URL credential pattern — ://user:pass@ *)
let url_credential_re =
  Re.compile (Re.seq [Re.str "://"; Re.rep1 (Re.compl [Re.set "@ "]); Re.char '@'])

(** Common secret-bearing value patterns — structural prefixes only.

    Each pattern identifies a secret by its *structure* (a known prefix family
    or the [://user:pass@] URL shape), not by a length heuristic. The former
    generic "20+ alphanumeric run" matcher was removed: it classified ordinary
    identifiers (keeper names, commit hashes, task ids) as secrets by length
    alone, erasing them from observability fields, while every real prefix it
    caught is already matched here in one shot (e.g. [sk-proj-...] via the
    [sk-] body below). Known secret *values* loaded from the environment remain
    redacted exactly by {!Keeper_secret_redaction}, which does not rely on this
    heuristic.

    Specific prefix regexes are hoisted to module level so they are compiled
    once at init, not rebuilt on every [redact_text] call. [Re] is thread-safe
    (see file header), so sharing compiled regexes across fibers/domains is
    safe — [url_credential_re] already does this. *)
let bearer_re =
  Re.compile (Re.seq [Re.str "Bearer "; Re.rep1 (Re.compl [Re.set " \t\r\n"])])

let sk_re =
  Re.compile (Re.seq [Re.bow; Re.str "sk-"; Re.rep1 (Re.alt [Re.alnum; Re.char '-'])])

let awsakia_re =
  Re.compile (Re.seq [Re.bow; Re.str "AKIA"; Re.repn Re.alnum 16 (Some 16); Re.eow])

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
let github_token_re =
  Re.compile
    (Re.seq
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
       ])

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
      [ Re.str "-----"; Re.str word; Re.rep (Re.set "ABCDEFGHIJKLMNOPQRSTUVWXYZ ")
      ; Re.str "PRIVATE KEY-----"
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

let redact_pem_blocks s = Re.replace_string pem_private_key_re ~by:"[REDACTED]" s

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
    matched in one shot instead of leaving a [-abc...] tail. [AKIA] is anchored
    at both ends so a 17-char run is not truncated to its first 16 chars. *)
let secret_res () =
  [ url_credential_re
  ; bearer_re
  ; sk_re
  ; awsakia_re
  ; github_token_re
  ]

let redact_text (s : string) : string =
  List.fold_left
    (fun acc re -> Re.replace_string re ~by:"[REDACTED]" acc)
    (redact_pem_blocks s)
    (secret_res ())

let rec redact_json_strings = function
  | `String s -> `String (redact_text s)
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if is_sensitive_key key then (key, `String "[REDACTED]")
             else (key, redact_json_strings value))
           fields)
  | `List items -> `List (List.map redact_json_strings items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as json -> json
