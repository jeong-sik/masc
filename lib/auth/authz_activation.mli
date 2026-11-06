(* HIGH-RISK-UNREVIEWED: this module writes the first records of a
   multi-account installation, the bootstrap and the first Admin invitation.
   The token of that invitation is the only way in, and an activation that runs
   where a boot would not open it leaves an installation that refuses to boot. *)

(** The host-local activation of a multi-account installation (design 5.1-1,
    8.4, plan B3d-1). [masc auth bootstrap] calls {!activate}, which does this,
    in order, and stops at the first step that fails:
    + It reads what a boot reads ({!Authz_boot_mode_read.input}) and goes on
      only on the row of design 5.1 that asks for an activation: [config.json]
      asks for [Multi_account] with [enabled] and [require_token], anonymous
      mutations are off, the log holds no mode event, and the external store
      no high-water mark. Every other row is refused before anything is
      written: a single-user boot with {!Not_asked} or {!Config_unreadable},
      an installation that a boot reads as activated with {!Already_active},
      and a boot that stops for another reason with the lines it prints
      ({!Boot_stops}).
    + It runs {!Authz_bootstrap.fresh_bootstrap} with a new workspace id.
    + It opens the zone over the two files and commits an Admin invitation
      written by the host-local operator. Only the digest of the token is
      written. The invitation expires {!admin_invitation_lifetime_ms} after
      the clock read before the commit.

    A failure of the last step leaves the installation bootstrapped with no
    invitation ({!Invitation_not_written}).

    A refusal writes no record. The first step opens the log and the store as a
    boot does, which cuts a last line that never ended and leaves lock files
    next to them.

    The caller holds the BasePath lease, so no server runs on the base path and
    no other activation runs at once. It calls {!activate} inside an Eio event
    loop, because the zones are [Eio.Mutex]es. The workspace id, the invite id
    and the token come from the operating system ({!Random_id.hex}). *)

(** 24 hours. Design 5.1-4 leaves the value to the plan. *)
val admin_invitation_lifetime_ms : int

(** An Admin invitation that was just committed. Its token is 32 random bytes
    as 64 lowercase hex characters, written nowhere; {!link} is the only way
    out of the value. *)
type invitation

val invite_id : invitation -> Authz_types.Invite_id.t
val expires_at_ms : invitation -> int

(** ["/accounts/invite"]. The screen of the invitation (plan C6) and its
    consumption (plan C2a) serve this path. *)
val invitation_path : string

(** [<base_url>/accounts/invite#<token>]. The token is in the fragment, so a
    browser does not send it to the server in the URL (design 5.1-4). *)
val link : base_url:string -> invitation -> string

type activated =
  { workspace_id : Authz_types.Workspace_id.t
  ; invitation : invitation
  }

(** Why the invitation was not written. The id and the body are refused only if
    {!Authz_id} or {!Authz_body} stop accepting what this module builds. *)
type invitation_error =
  | Invite_id_not_built of Authz_id.error
  | Body_not_built of Authz_body.error
  | Zone_not_opened of Authz_zone.open_error
  | Commit_failed of Authz_zone.error

type error =
  | Not_asked
      (** [config.json] does not ask for [Multi_account], so a boot starts a
          single user. No record was written. *)
  | Config_unreadable of string
      (** A boot reads [config.json] as unreadable, with the reason: it could
          not be checked or read, it is not a regular file or not JSON, or its
          fields do not decode (also beside an explicit [Single_user]). A boot
          starts a single user that answers 503 to a request reading the
          config. No record was written. *)
  | Already_active
      (** The log made [Multi_account] and the external store matches it: a
          boot reads this installation as activated. No record was written. *)
  | Boot_stops of string * string list
      (** A boot stops on this installation for another reason than an
          activation, with the lines it prints. No record was written. *)
  | Workspace_id_not_built of Authz_id.error  (** No record was written. *)
  | Bootstrap_failed of Authz_bootstrap.error  (** As {!Authz_bootstrap} says. *)
  | Invitation_not_written of invitation_error
      (** The log holds the bootstrap and no invitation. *)

val error_to_string : error -> string

val activate
  :  base_path:string
  -> config_dir:string option
  -> external_store:string
  -> anonymous_mutations:bool
  -> now_ms:(unit -> int)
  -> (activated, error) result
