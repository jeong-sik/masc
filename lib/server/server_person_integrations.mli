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
    same way. A multi-account process
    allows no native tools, so today the models of Claude Code are
    [Allowed], and those of Codex are refused with
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
  ; takes_login : bool
      (** Whether a person connects it through an official-client login.
          False for HTTP API-key providers (RFC
          a-persons-api-key-is-their-own-provider-account 3.9). *)
  ; takes_key : bool
      (** Whether a person registers an API key of their own for it
          ({!Server_key_account.takes_key} or {!Server_key_account.http_takes_key}). *)
  }

(** The providers of runtime.toml a person may connect, in declared order:
    official clients allowed by {!Server_setup_account_login.person_target}
    and HTTP API-key providers allowed by {!Server_key_account.http_takes_key}. *)
val of_config : Runtime_schema.config -> integration list

(** What a start of the routes of people says once about the providers a
    person signs in to. *)
type start_note =
  | Access_unpublished
      (** The providers were read before this process published its access:
          each reads as refused then, and which of them offers a model is
          not known. *)
  | No_person_provider
      (** runtime.toml declares no provider that a person signs in to. *)
  | No_model of
      { integration_id : string
      ; withheld : (string * withheld) list
      }
      (** A provider whose models are called here ([Allowed]) offers none.
          [withheld] holds its bindings, and is empty when it has none. *)

(** The notes of the providers {!of_config} gave, in their order. A provider
    whose calls are [Refused] for its tools gets no note: a model of it would
    still not be called here, and the page of a person says that refusal. For
    a provider with a note, the page says beside the model check which models
    are withheld and why. [calls] is read from the access this process
    published: asked before the publication, the answer is
    [Access_unpublished] alone. *)
val start_notes : integration list -> start_note list

(** The lines of {!start_notes} for the runtime.toml of [base_path], with the
    code of {!answer} for each binding withheld: what the account server
    ({!Server_accounts.run}) writes to its log and [masc auth preview] prints.
    The person is not the one who edits runtime.toml, so the operator reads
    them there. A file that cannot be read gives no line:
    {!Server_runtime_setup_actions.config} writes that to the log itself. A
    working directory that is gone, which the lookup of a relative provider
    command reads, is a line and not an exception, so a start goes on. *)
val start_lines : base_path:string -> string list

(** [/api/v1/auth/integrations]. *)
val path : string

(** The answer of [GET path] for a signed-in person:
    [{"integrations":[{"integration_id":...,"display_name":...,"connect":[...],"models":[...],"withheld":[...],"calls":"allowed"}]}],
    where ["connect"] holds how a person connects it: ["login"] for official
    clients, and ["key"] for one that takes an API key (RFC
    a-persons-api-key-is-their-own-provider-account 3.8 and 3.9),
    and ["calls":"refused","refusal":<code>] for a refused one, where the code
    names the {!Runtime_account_access.native_refusal}. A member of
    ["withheld"] is [{"model":<id>,"reason":<code>}]: the code is
    ["model_undeclared"], or the {!Runtime_verification.failure_code} of the
    refusal a verification of the model ends with, such as
    ["tools_not_declared"]. A runtime.toml that cannot be read is a 503. *)
val answer : base_path:string -> Login_routes.answer
