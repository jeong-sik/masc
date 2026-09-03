(** Which machine a Keeper's GitHub device-flow login is written to.

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
