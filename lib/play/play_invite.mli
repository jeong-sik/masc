(** Invites to the shared machine (RFC play-link-for-the-shared-machine §2.4).

    An invite is a credential with the [Player] role and an expiry. The
    operator issues it under a name, hands the link on, and revokes it by
    that name. This module owns the credential side only: whoever calls
    {!revoke} frees the DOS controller the name may still hold. *)

(** An invite's name: the [who] its presses are recorded under.

    A lowercase ASCII letter, then up to {!max_name_length} - 1 lowercase
    letters or digits. No hyphen: a hyphenated credential name is read as a
    generated nickname or a keeper transport alias ([Auth_nickname]), which
    can resolve it to a different name. *)
module Name : sig
  type t = private string

  val of_string : string -> (t, string) result
  val to_string : t -> string
end

val max_name_length : int

(** What stops the workspace from issuing an invite. With auth off every
    request is an [Admin], and without [require_token] a request with no
    bearer is a [Worker], so a narrower [Player] credential would narrow
    nothing. Without a public base URL there is no link to hand on. *)
type readiness_gap =
  | Auth_disabled
  | Token_not_required
  | No_public_base_url

val readiness_gap_to_string : readiness_gap -> string

type taken_by =
  | Keeper
  | Credential

val taken_by_to_string : taken_by -> string

type issue_error =
  | Not_ready of readiness_gap list  (** non-empty, in declaration order *)
  | Name_taken of taken_by
      (** Two participants under one name could not be told apart in the
          ledger or by [pass]. *)
  | Keeper_names_unreadable of string
      (** The fleet did not list, so a clash cannot be ruled out. *)
  | Hours_out_of_range of int
  | Credential_not_saved of Masc_domain.masc_error

type issued =
  { name : Name.t
  ; expires_at : string
  ; link : string  (** [<public base>/play#<raw token>]; the only copy of the token *)
  }

val issue :
  base_path:string ->
  public_base_url:string option ->
  keeper_names:(string list, string) result ->
  name:Name.t ->
  hours:int ->
  (issued, issue_error) result
(** Issues a [Player] credential that expires [hours] from now.
    [public_base_url] is the configured [MASC_HTTP_BASE_URL] and
    [keeper_names] every keeper the workspace knows; the caller reads both. *)

type invite =
  { invite_name : string
  ; expires_at : string option
  ; expired : bool
  }

val list : base_path:string -> now:float -> invite list
(** Every [Player] credential, expired ones included, by name. *)

type revoke_error =
  | No_such_invite
  | Not_an_invite of Masc_domain.agent_role
      (** The name belongs to a credential of another role; nothing changed. *)

val revoke : base_path:string -> name:Name.t -> (unit, revoke_error) result
(** Deletes the invite's credential; its bearer stops validating from the
    next request. *)
