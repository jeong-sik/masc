(** Share links for collab live sessions (RFC-0471 §2.2).

    Terminal link: [<room>.<secret>] where both parts are unpadded base64url.
    [room] decodes to 16 bytes. [secret] decodes to 32 bytes (view: room key
    only) or 48 bytes (control: 32-byte room key + 16-byte write token).

    Web link: [<base>/#<terminal-link>]. The secret travels in the URL
    fragment only, so it never reaches server or relay logs. *)

type capability = View | Control
(** [View] watches with the room key only. [Control] additionally carries the
    write token and may steer the session. *)

type room = {
  id : string; (** 16 bytes. *)
  key : string; (** 32 bytes, AES-256 room key. *)
  write_token : string; (** 16 bytes. *)
}
(** A room as minted by {!generate}. Every field carries exactly the
    documented byte length. *)

type parse_error =
  | Missing_separator
  | Invalid_room_id
  | Invalid_secret
  | Invalid_secret_length of int
  | Missing_fragment

val generate : unit -> room
(** [generate ()] mints a fresh room from the OS cryptographic source. *)

val format_link : room -> capability -> string
(** [format_link room cap] renders the terminal link. [View] encodes the key
    only (32 bytes of secret); [Control] encodes key + write token (48
    bytes). [room] carries the byte lengths {!room} documents. *)

val format_web_link : base:string -> room -> capability -> string
(** [format_web_link ~base room cap] renders [base ^ "/#" ^ link]. [base]
    carries no trailing slash. *)

type parsed = {
  id : string; (** 16 bytes. *)
  key : string; (** 32 bytes. *)
  capability : capability;
  write_token : string option;
      (** [Some token] (16 bytes) iff [capability = Control], else [None]. *)
}

val parse_link : string -> (parsed, parse_error) result
(** [parse_link s] strictly decodes a terminal link. Anything that is not
    exactly [<b64url-16B>.<b64url-32|48B>] is an [Error]; there is no repair
    and no default. *)

val parse_web_link : string -> (parsed, parse_error) result
(** [parse_web_link s] decodes the fragment after the last ['#'] as a
    terminal link. A link without ['#'] is [Missing_fragment]. *)
