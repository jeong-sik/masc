(* HIGH-RISK-UNREVIEWED: see the interface. *)

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

let is_lower_hex_of ~length text = String.length text = length && String.for_all is_lower_hex text

(* The token of [Authz_activation] is 32 bytes as hex. *)
let invite_token_hex_length = 64

module Invite_token = struct
  type t = string

  let of_form text = if is_lower_hex_of ~length:invite_token_hex_length text then Some text else None
  let digest = Authz_invite_event.Token_digest.of_token
end

module Local_path = struct
  type t = string

  let is_hex_digit = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  ;;

  (* RFC 3986 [pchar] without [pct-encoded]: unreserved, sub-delims, ":" and "@". *)
  let is_pchar = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
    | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' -> true
    | ':' | '@' -> true
    | _ -> false
  ;;

  (* Whether [text] from [from] to before [until] is a run of [pchar], of
     [pct-encoded], and of the bytes [extra] allows. *)
  let rec runs_of text ~from ~until ~extra =
    if from >= until
    then true
    else if Char.equal text.[from] '%'
    then
      from + 3 <= until
      && is_hex_digit text.[from + 1]
      && is_hex_digit text.[from + 2]
      && runs_of text ~from:(from + 3) ~until ~extra
    else (is_pchar text.[from] || extra text.[from]) && runs_of text ~from:(from + 1) ~until ~extra
  ;;

  (* [path-absolute [ "?" query ]]. [path-absolute] is "/" with no second "/"
     right after it, so [//host] is refused. *)
  let of_string text =
    let length = String.length text in
    let path_end = Option.value ~default:length (String.index_opt text '?') in
    let starts_one_slash =
      length >= 1 && Char.equal text.[0] '/' && not (length >= 2 && Char.equal text.[1] '/')
    in
    if
      starts_one_slash
      && runs_of text ~from:1 ~until:path_end ~extra:(Char.equal '/')
      && runs_of text ~from:(path_end + 1) ~until:length ~extra:(fun c ->
        Char.equal c '/' || Char.equal c '?')
    then Some text
    else None
  ;;

  let to_string text = text
  let root = "/"
end

(* 32 bytes for the state, the nonce, and the PKCE verifier. The verifier is
   then 64 characters, inside the 43 to 128 of RFC 7636 section 4.1. *)
let random_bytes = 32

(* RFC 6265 section 6.1 has a browser keep at least 4096 bytes of a cookie:
   its name, its value and its attributes. The name and the attributes of
   the transaction cookie are under 96 bytes
   ([Authz_browser_request.set_transaction_cookie], whose test holds the
   sum). *)
let max_sealed_length = 4000

module Sealed = struct
  type t = string

  let is_base64url = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false
  ;;

  let of_string text =
    let length = String.length text in
    if length >= 1 && length <= max_sealed_length && String.for_all is_base64url text
    then Some text
    else None
  ;;

  let to_string text = text
end

let lifetime_ms = 10 * 60 * 1000

type google = { nonce : string }

type _ flow =
  | Google : google flow
  | Github : unit flow

type (_, _) same = Same : ('a, 'a) same

(* No wildcard, so a third flow is a compile error here and not a silent
   [None]. *)
let same_flow : type a b. a flow -> b flow -> (a, b) same option =
  fun a b ->
  match a, b with
  | Google, Google -> Some Same
  | Github, Github -> Some Same
  | Google, Github | Github, Google -> None
;;

type 'held started =
  { sealed : Sealed.t
  ; state : string
  ; code_challenge : string
  ; held : 'held
  }

type 'held taken =
  { held : 'held
  ; code_verifier : string
  ; invite : Authz_invite_event.Token_digest.t option
  ; return_to : Local_path.t
  ; replaces : Authz_types.Session_id.t option
  }

(* ChaCha20-Poly1305 (RFC 8439): a 32-byte key and a 12-byte nonce that must
   not come twice under one key. *)
module Aead = Mirage_crypto.Chacha20

let key_bytes = 32
let nonce_bytes = 12
let count_bytes = 8

(* The key is drawn once for the process and the count goes up by one for
   every seal, so no nonce comes twice under the key: the count is the last
   eight bytes of the nonce. *)
type t =
  { key : Aead.key
  ; sealed_so_far : int Atomic.t
  }

let create () =
  { key = Aead.of_secret (Crypto_rng.generate key_bytes); sealed_so_far = Atomic.make 0 }
;;

(* What the tag covers beside the bytes: a text of another purpose that was
   sealed with this key does not open as a login. *)
let purpose = "masc-login-transaction-v1"

let nonce_of count =
  let nonce = Bytes.make nonce_bytes '\000' in
  Bytes.set_int64_be nonce (nonce_bytes - count_bytes) (Int64.of_int count);
  Bytes.unsafe_to_string nonce
;;

let flow_field = "flow"
let started_at_field = "started_at_ms"
let state_field = "state"
let code_verifier_field = "code_verifier"
let nonce_field = "nonce"
let invite_field = "invite"
let return_to_field = "return_to"
let replaces_field = "replaces"
let google_label = "google"
let github_label = "github"

let optional_string = function
  | None -> `Null
  | Some text -> `String text
;;

let json_of
  : type held. held flow -> started_at_ms:int -> state:string -> held taken -> Yojson.Safe.t
  =
  fun flow ~started_at_ms ~state taken ->
  let label, nonce =
    match flow with
    | Google -> google_label, Some taken.held.nonce
    | Github -> github_label, None
  in
  `Assoc
    [ flow_field, `String label
    ; started_at_field, `Int started_at_ms
    ; state_field, `String state
    ; code_verifier_field, `String taken.code_verifier
    ; nonce_field, optional_string nonce
    ; ( invite_field
      , optional_string (Option.map Authz_invite_event.Token_digest.to_hex taken.invite) )
    ; return_to_field, `String (Local_path.to_string taken.return_to)
    ; ( replaces_field
      , optional_string (Option.map Authz_types.Session_id.to_string taken.replaces) )
    ]
;;

type opened =
  | Opened :
      { flow : 'held flow
      ; started_at_ms : int
      ; state : string
      ; taken : 'held taken
      }
      -> opened

(* [Some None] for no value, [Some (Some _)] for one that reads, and [None]
   for one that does not. *)
let optional read : Yojson.Safe.t -> _ option option = function
  | `Null -> Some None
  | `String text -> Option.map Option.some (read text)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> None
;;

let ( let* ) = Option.bind

(* Only the bytes that [json_of] wrote open under the key, so a shape that
   is not read here is a text of another build. *)
let opened_of_json : Yojson.Safe.t -> opened option = function
  | `Assoc
      [ (flow_name, `String label)
      ; (started_at_name, `Int started_at_ms)
      ; (state_name, `String state)
      ; (code_verifier_name, `String code_verifier)
      ; (nonce_name, nonce)
      ; (invite_name, invite)
      ; (return_to_name, `String return_to)
      ; (replaces_name, replaces)
      ]
    when String.equal flow_name flow_field
         && String.equal started_at_name started_at_field
         && String.equal state_name state_field
         && String.equal code_verifier_name code_verifier_field
         && String.equal nonce_name nonce_field
         && String.equal invite_name invite_field
         && String.equal return_to_name return_to_field
         && String.equal replaces_name replaces_field ->
    let* invite = optional Authz_invite_event.Token_digest.of_hex invite in
    let* return_to = Local_path.of_string return_to in
    let* replaces =
      optional (fun text -> Result.to_option (Authz_types.Session_id.of_string text)) replaces
    in
    let* nonce = optional Option.some nonce in
    (match nonce with
     | Some nonce when String.equal label google_label ->
       Some
         (Opened
            { flow = Google
            ; started_at_ms
            ; state
            ; taken = { held = { nonce }; code_verifier; invite; return_to; replaces }
            })
     | None when String.equal label github_label ->
       Some
         (Opened
            { flow = Github
            ; started_at_ms
            ; state
            ; taken = { held = (); code_verifier; invite; return_to; replaces }
            })
     | Some (_ : string) | None -> None)
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let base64url = Base64.uri_safe_alphabet

let seal t json =
  let nonce = nonce_of (Atomic.fetch_and_add t.sealed_so_far 1) in
  let sealed =
    Aead.authenticate_encrypt ~key:t.key ~nonce ~adata:purpose (Yojson.Safe.to_string json)
  in
  Base64.encode_string ~pad:false ~alphabet:base64url (nonce ^ sealed)
;;

(* The decoder passes a text with a trailing character it does not read, and
   one whose last character differs in the bits it does not read. Those are
   other texts of the same bytes: only the text that [seal] wrote opens. *)
let unsealed_json t sealed =
  match Base64.decode ~pad:false ~alphabet:base64url sealed with
  | Error (`Msg (_ : string)) -> None
  | Ok bytes ->
    if String.length bytes < nonce_bytes + Aead.tag_size
       || not (String.equal (Base64.encode_string ~pad:false ~alphabet:base64url bytes) sealed)
    then None
    else (
      let nonce = String.sub bytes 0 nonce_bytes in
      let sealed = String.sub bytes nonce_bytes (String.length bytes - nonce_bytes) in
      let* text = Aead.authenticate_decrypt ~key:t.key ~nonce ~adata:purpose sealed in
      match Yojson.Safe.from_string text with
      | json -> Some json
      | exception Yojson.Json_error (_ : string) -> None)
;;

type start_error = Too_long

let draw_held : type held. held flow -> held = function
  | Google -> { nonce = Random_id.hex ~bytes:random_bytes }
  | Github -> ()
;;

let start
  : type held.
    t
    -> now_ms:int
    -> held flow
    -> invite:Invite_token.t option
    -> return_to:Local_path.t
    -> replaces:Authz_types.Session_id.t option
    -> (held started, start_error) result
  =
  fun t ~now_ms flow ~invite ~return_to ~replaces ->
  let state = Random_id.hex ~bytes:random_bytes in
  let code_verifier = Random_id.hex ~bytes:random_bytes in
  let held = draw_held flow in
  let taken =
    { held; code_verifier; invite = Option.map Invite_token.digest invite; return_to; replaces }
  in
  match Sealed.of_string (seal t (json_of flow ~started_at_ms:now_ms ~state taken)) with
  | None -> Error Too_long
  | Some sealed ->
    Ok { sealed; state; code_challenge = Auth_oauth.pkce_s256 code_verifier; held }
;;

type open_error =
  | Unknown
  | Other_flow
  | Expired
  | State_differs

let open_error_to_string = function
  | Unknown -> "this server did not start a login with this transaction"
  | Other_flow -> "this transaction belongs to a login with another provider"
  | Expired -> "the login took too long and has to start again"
  | State_differs -> "the state does not belong to this login"
;;

let open_
  : type held.
    t -> now_ms:int -> held flow -> Sealed.t -> state:string -> (held taken, open_error) result
  =
  fun t ~now_ms flow sealed ~state ->
  match Option.bind (unsealed_json t sealed) opened_of_json with
  | None -> Error Unknown
  | Some (Opened opened) ->
    (match same_flow flow opened.flow with
     | None -> Error Other_flow
     | Some Same ->
       if now_ms - opened.started_at_ms >= lifetime_ms
       then Error Expired
       else if not (Eqaf.equal opened.state state)
       then Error State_differs
       else Ok opened.taken)
;;
