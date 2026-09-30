(** Invites to the shared machine (RFC play-link-for-the-shared-machine §2.4).

    An invite is a credential with the [Player] role and an expiry. The
    operator issues it under a name, hands the link on, and revokes it by
    that name. This module owns the credential side only: {!revoke} keeps its
    caller's controller effect inside the credential transaction. *)

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

val play_path : string
(** [/play]: the page a person opens the link in. *)

val agent_guide_path : string
(** [/play/agent.md]: how an agent that was handed the link joins, read
    without a credential. The link's token is not in it. *)

val issue :
  base_path:string ->
  public_base_url:string option ->
  keeper_names:(string list, string) result ->
  name:Name.t ->
  hours:int ->
  (issued, issue_error) result
(** Issues a [Player] credential that expires [hours] from now.
    [public_base_url] is the configured [MASC_HTTP_BASE_URL] and
    [keeper_names] every keeper the workspace knows; the caller reads both.
    A name clashes with a keeper when they share a credential file name
    ({!is_keeper_name}). *)

val is_keeper_name : keepers:string list -> Name.t -> bool
(** Whether a keeper among [keepers] would own [name]'s credential file:
    [Common.safe_filename] lowercases, so the keeper "Minsu" owns "minsu". *)

type invite =
  { invite_name : string
  ; expires_at : string option
  ; expired : bool
  }

val expired : now:float -> Masc_domain.agent_credential -> bool
(** Whether a credential's time has run out at [now]. A credential with no
    [expires_at] never expires; an invite always has one. This is the rule a
    static bearer is checked by: whole UTC seconds and a strict [now > expiry],
    so the bearer still works during its expiry second. *)

val list : base_path:string -> now:float -> invite list
(** Every [Player] credential, expired ones included, by name. *)

type revoked =
  | Deleted  (** the invite's credential was there and is gone *)
  | Already_gone
      (** no credential has the name: revoked before, or never issued. The
          caller may still have to free a controller the name holds, when a
          request the invitee sent before the delete took it afterwards. *)

type revoke_error =
  | Not_an_invite of Masc_domain.agent_role
      (** The name belongs to a credential of another role; nothing changed. *)
  | Credential_not_deleted of Masc_domain.masc_error
      (** Credential storage or lock admission failed; no controller effect ran. *)
  | Credential_unreadable
      (** The name file exists but cannot resolve to a credential. No effect ran. *)
  | Credential_identity_mismatch of string
      (** The file resolves to another credential owner. No effect ran. *)

val revoke :
  base_path:string -> name:Name.t -> after_revoke:(revoked -> 'a) ->
  ('a, revoke_error) result
(** Checks the current role and deletes the invite in one Auth transaction;
    its bearer stops validating from the next request. [after_revoke] runs for
    both [Deleted] and [Already_gone], before credential writers can resume.
    A present unreadable or mismatched credential is refused, not treated as gone.
    It may free a controller or check Keeper identity but must not enter an
    Auth transaction or perform Board publication. Flush announcements after
    this returns. *)
