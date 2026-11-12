(** What a person may connect on the account server, and whether the models of
    each can be called there (plan L2a). The page offers these instead of
    asking for an integration id and a model name.

    Nothing here decides anything: each fact comes from the function that
    decides it for the route that acts. *)

(** Whether a model of the integration is called on this server. A
    verification ({!Server_setup_account_login.verify}) starts the official
    client with the native posture of its default configuration, and
    {!Runtime_account_access.authorize_native} judges that posture. A Keeper
    turn ({!Server_preview_keeper_turn.run}) starts Claude Code and Codex the
    same way, and takes no Muse Runtime at all. A multi-account process
    allows no native tools, so today the models of Claude Code are
    [Allowed], and those of Codex and Muse are refused with
    [Native_tools_reach_other_homes] (plan D3c), the reason a verification
    of them is refused. *)
type calls =
  | Allowed
  | Refused of Runtime_account_access.native_refusal

type integration =
  { integration_id : string  (** The id the connect request names. *)
  ; display_name : string
  ; models : string list
      (** The models of the bindings of this provider in runtime.toml: the
          [model] a verification names. *)
  ; calls : calls
  }

(** The providers of runtime.toml a person may log in to, in declared order:
    those whose login target resolves
    ({!Server_runtime_setup_actions.login_target_of_config}) to a client a
    person may connect ({!Server_setup_account_login.person_may_connect}).
    The account a person makes is used through such a provider
    ({!Runtime_account_runtime.of_template}), so an integration that no
    provider declares is not listed. *)
val of_config : Runtime_schema.config -> integration list

(** [/api/v1/auth/integrations]. *)
val path : string

(** The answer of [GET path] for a signed-in person:
    [{"integrations":[{"integration_id":...,"display_name":...,"models":[...],"calls":"allowed"}]}],
    and ["calls":"refused","refusal":<code>] for a refused one, where the code
    names the {!Runtime_account_access.native_refusal}. A runtime.toml that
    cannot be read is a 503. *)
val answer : base_path:string -> Login_routes.answer
