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

(** Why a binding of a provider names no model a person may call. *)
type withheld =
  | Model_undeclared
      (** runtime.toml declares no row for the model the binding names, so
          the binding makes no Runtime. *)
  | Model_refused of Runtime_verification.unavailable
      (** {!Runtime_verification.model_refusal} refuses the row: a
          verification of it ends there, before any client starts. *)

type integration =
  { integration_id : string  (** The id the connect request names. *)
  ; display_name : string
  ; models : string list
      (** The models of the bindings of this provider in runtime.toml whose
          model row declares tool calling ({!Runtime_verification.model_refusal}),
          the [model] a verification names. A verification refuses the others
          before any client starts, so a provider may have none. A binding the
          runtime cannot build from its declaration alone, such as one of a
          provider without [is-non-interactive = true], is still listed: its
          verification ends with "The runtime of this account does not load"
          (masc #51775). *)
  ; withheld : (string * withheld) list
      (** The other bindings of this provider, each with the model it names
          and why that model is not in [models]. With [models] it holds every
          binding of the provider once, in declared order. A provider with
          neither has no binding. *)
  ; calls : calls
  }

(** The providers of runtime.toml a person may log in to, in declared order:
    those {!Server_setup_account_login.person_target} allows, the rule the
    connect route judges a person's login by. *)
val of_config : Runtime_schema.config -> integration list

(** What the operator is told once when the account server starts
    ({!Server_accounts.run}), a line each: that no provider is one a person
    signs in to, or which providers offer no model, with the code of
    {!answer} for each binding withheld. The page of a person shows the same
    reasons; the log is where the operator reads them. Empty when every
    provider offers a model. *)
val start_notes : integration list -> string list

(** [/api/v1/auth/integrations]. *)
val path : string

(** The answer of [GET path] for a signed-in person:
    [{"integrations":[{"integration_id":...,"display_name":...,"models":[...],"withheld":[...],"calls":"allowed"}]}],
    and ["calls":"refused","refusal":<code>] for a refused one, where the code
    names the {!Runtime_account_access.native_refusal}. A member of
    ["withheld"] is [{"model":<id>,"reason":<code>}]: the code is
    ["model_undeclared"], or the {!Runtime_verification.failure_code} of the
    refusal a verification of the model ends with, such as
    ["tools_not_declared"]. A runtime.toml that cannot be read is a 503. *)
val answer : base_path:string -> Login_routes.answer
