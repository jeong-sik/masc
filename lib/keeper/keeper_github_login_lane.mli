(** Which machine a Keeper's GitHub device-flow login is written to, and so
    which machine its status and its token are read from.

    A Docker or Micro_vm Keeper reads the host directory
    [<base>/.masc/keepers/<name>/github-cli] through a mount, so its login
    belongs on this host. A Remote_ssh Keeper's tree and its [gh] live on
    another machine, and a login written here would never be seen there: every
    turn would keep failing the endpoint's identity preflight
    ([remote_github_identity_missing]) while the operator looks at a successful
    login on this screen. *)

val for_keeper
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> hostname:string
  -> (Keeper_github_identity.login_lane, string) result
(** The lane for [meta]'s declared sandbox profile. [meta] has to come from
    {!Keeper_meta_store.read_effective_meta}: persisted meta omits
    [sandbox_profile], so a lane chosen from a persisted read sends every
    Keeper to this host. A Remote_ssh Keeper whose endpoint cannot be resolved
    is an error rather than a host login. *)

val observe
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> hostname:string
  -> (Keeper_github_identity.observation, string) result
(** The identity on the machine {!for_keeper} would log [meta] into. Docker and
    Micro_vm read this host's directory ({!Keeper_github_identity.observe}); a
    Remote_ssh Keeper runs one [gh] probe on its endpoint and creates nothing
    there. A probe the transport could not deliver is an error
    ([remote_ssh_github_endpoint_unreachable]) rather than an unauthenticated
    reading. [meta] comes from {!Keeper_meta_store.read_effective_meta}, for the
    reason {!for_keeper} gives. *)

type stored_token_error =
  | Keeper_meta_unreadable of string
      (** The Keeper has a meta file and it could not be read. A Keeper with
          no meta at all declares no endpoint and is read on this host. *)
  | Remote_ssh_identity_on_endpoint of { keeper_name : string }
      (** The login lives on a Remote_ssh endpoint. Reading it would copy a
          credential from the endpoint back to this host, which nothing in
          masc does, so the read is refused rather than answered from a host
          directory the login never wrote. *)
  | Host_identity_unavailable of string
      (** {!Keeper_github_identity.stored_token}'s own refusal. *)

val stored_token_error_to_string : stored_token_error -> string

val stored_token
  :  config:Workspace.config
  -> keeper_name:string
  -> hostname:string
  -> (string, stored_token_error) result
(** The token the Keeper's gh CLI holds for [hostname], for a caller on this
    host that sends it itself (the GitHub MCP identity). Reads the Keeper's
    effective meta to find the profile, then the host directory for Docker,
    Micro_vm and a Keeper with no meta. *)
