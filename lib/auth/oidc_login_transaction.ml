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

(* 32 bytes for the ID, the state, the nonce, and the PKCE verifier. The
   verifier is then 64 characters, inside the 43 to 128 of RFC 7636
   section 4.1. *)
let random_bytes = 32

module Id = struct
  type t = string

  let of_string text = if is_lower_hex_of ~length:(2 * random_bytes) text then Some text else None
  let to_string text = text
end

let lifetime_ms = 10 * 60 * 1000

type started =
  { id : Id.t
  ; state : string
  ; nonce : string
  ; code_challenge : string
  }

type taken =
  { nonce : string
  ; code_verifier : string
  ; invite : Invite_token.t option
  ; return_to : Local_path.t
  }

type entry =
  { started_at_ms : int
  ; state : string
  ; held : taken
  }

module Id_map = Map.Make (String)

type t =
  { mutex : Mutex.t
  ; capacity : int
  ; mutable entries : entry Id_map.t
  }

let create ~capacity =
  if capacity < 1 then invalid_arg "Oidc_login_transaction.create: capacity below 1";
  { mutex = Mutex.create (); capacity; entries = Id_map.empty }
;;

let is_live ~now_ms entry = now_ms - entry.started_at_ms < lifetime_ms
let live_entries t ~now_ms = Id_map.filter (fun _ entry -> is_live ~now_ms entry) t.entries

type start_error = Full

let start t ~now_ms ~invite ~return_to =
  Mutex.protect t.mutex (fun () ->
    let live = live_entries t ~now_ms in
    t.entries <- live;
    if Id_map.cardinal live >= t.capacity
    then Error Full
    else (
      let id = Random_id.hex ~bytes:random_bytes in
      let state = Random_id.hex ~bytes:random_bytes in
      let nonce = Random_id.hex ~bytes:random_bytes in
      let code_verifier = Random_id.hex ~bytes:random_bytes in
      t.entries
      <- Id_map.add
           id
           { started_at_ms = now_ms; state; held = { nonce; code_verifier; invite; return_to } }
           live;
      Ok { id; state; nonce; code_challenge = Auth_oauth.pkce_s256 code_verifier }))
;;

type take_error =
  | Unknown
  | Expired
  | State_differs

let take_error_to_string = function
  | Unknown -> "no login is in flight with this transaction"
  | Expired -> "the login took too long and has to start again"
  | State_differs -> "the state does not belong to this login"
;;

let take t ~now_ms id ~state =
  Mutex.protect t.mutex (fun () ->
    match Id_map.find_opt id t.entries with
    | None -> Error Unknown
    | Some entry ->
      t.entries <- Id_map.remove id t.entries;
      if not (is_live ~now_ms entry)
      then Error Expired
      else if not (Eqaf.equal entry.state state)
      then Error State_differs
      else Ok entry.held)
;;

let live t ~now_ms = Mutex.protect t.mutex (fun () -> Id_map.cardinal (live_entries t ~now_ms))
