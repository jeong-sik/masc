(* HIGH-RISK-UNREVIEWED: this module writes the first records of a
   multi-account installation, the bootstrap and the first Admin invitation.
   The token of that invitation is the only way in, and an activation that runs
   where a boot would not open it leaves an installation that refuses to boot. *)

(** The host-local activation of a multi-account installation (design 5.1-1,
    8.4, plan B3d-1). [masc auth bootstrap] calls {!activate}, which does this,
    in order, and stops at the first step that fails:
    + It reads what a boot reads ({!Authz_boot_mode_read.input}) and goes on
      only on the row of design 5.1 that asks for an activation: [config.json]
      asks for [Multi_account], and neither the log nor the external store
      holds anything. Every other row is refused before anything is written:
      a single-user boot with {!Not_asked}, a boot that stops with the lines
      it prints ({!Boot_stops}).
    + It runs {!Authz_bootstrap.fresh_bootstrap} with a new workspace id.
    + It opens the zone over the two files and commits an Admin invitation
      written by the host-local operator. Only the digest of the token is
      written. The invitation expires {!admin_invitation_lifetime_ms} after
      the clock read before the commit.

    A failure of the last step leaves the installation bootstrapped with no
    invitation ({!Invitation_not_written}).

    The caller holds the BasePath lease, so no server runs on the base path and
    no other activation runs at once. It calls {!activate} inside an Eio event
    loop, because the zones are [Eio.Mutex]es. The workspace id, the invite id
    and the token come from the operating system ({!Random_id.hex}). *)

(** 24 hours. Design 5.1-4 leaves the value to the plan. *)
val admin_invitation_lifetime_ms : int

type invitation =
  { invite_id : Authz_types.Invite_id.t
  ; token : string
        (** 32 random bytes as 64 lowercase hex characters. It is returned once
            and written nowhere. *)
  ; expires_at_ms : int
  }

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
          single user. Nothing was written. *)
  | Boot_stops of string * string list
      (** A boot stops on this installation for another reason than an
          activation, with the lines it prints. Nothing was written. *)
  | Workspace_id_not_built of Authz_id.error  (** Nothing was written. *)
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
