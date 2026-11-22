(** Official-client login of a provider account. Session control also checks
    the caller and the canonical workspace. A request names no browser path
    or command; {!sign_in_browser} decides what the client is handed. *)

(** Who connects the account. It decides where the account home lies and
    what a confirmed login leaves behind. *)
type person =
  { zone : Authz_zone.t
  ; user_id : Authz_types.User_id.t
  ; namespace : Authz_types.Account_home_namespace.t
      (** The namespace the admission of [user_id] fixed. *)
  }

type owner =
  | Operator of { actor : string }
      (** Single-user: the caller passed [CanAdmin], and [actor] is its agent
          name. The home goes under the workspace's official-clients
          directory, and a confirmed login publishes the account to the setup
          registry. *)
  | Person of person
      (** Multi-account: the caller passed [Manage_own_provider] as [user_id]
          (plan D1-4). The home goes under [accounts/<namespace>] of the
          workspace's masc directory, and a confirmed login links the account,
          whose id is the login id, to [user_id] in the authorization log. A
          person always makes a new account: [account_ref] is refused. A
          person logs in only where {!person_target} allows. *)

(** The CORS headers of the event stream that {!start} answers. A person's
    stream has none: the page of the account server reads it from the same
    origin, and no other origin is allowed to read it with the person's
    credentials. The operator's stream allows the [Origin] of the request,
    as the single-user server does ({!Server_auth.cors_headers}). *)
val stream_cors_headers : owner -> Httpun.Request.t -> (string * string) list

(** What the sign-in child of [owner] is handed for the browser it would
    start. A person signs in from another machine, so their client gets a
    command that does nothing ({!Runtime_setup_login_client.no_host_browser}),
    and the sign-in is refused on a machine that has none. The operator's
    client gets {!Runtime_setup_login_client.host_browser}. {!start} hands the
    answer to {!Runtime_setup_login_client.prepare}, which makes the home of
    the login, so a refused sign-in has no directory made for it. *)
val sign_in_browser : owner -> (Runtime_setup_login_client.browser, string) result

(** Why a person may not log in to an integration. *)
type person_refusal =
  | Invalid_integration
      (** The id is not a valid {!Authz_types.Integration_id.t}. *)
  | Not_declared
      (** No provider of runtime.toml has the id. The account a person makes
          is used only through the provider its login names
          ({!Runtime_account_runtime.of_template}). *)
  | No_login of Server_runtime_setup_actions.error
      (** The provider has no official-client login, as a server over HTTP. *)
  | Copy_without_owner
      (** Antigravity: its credential copy lives in the setup registry, which
          has no owner. *)
  | Host_keyring_without_owner of Runtime_setup_login_client.client
      (** Host OS-keyring / CLI-store ACP clients (Mistral Vibe, Kimi Code,
          Antigravity ACP): their credentials are shared on the host rather than
          isolated per multi-account person. *)

(** The sentence {!start} answers a person with. *)
val person_refusal_message : person_refusal -> string

(** The login a person may start for [integration_id]: a provider runtime.toml
    declares, whose login target resolves, of a client that keeps its
    credential in the home of the account. {!start} asks this of a person
    before any login starts, and the list of what a person may connect
    ({!Server_person_integrations.of_config}) holds the providers it allows.
    An operator's login is not judged by it. *)
val person_target :
  Runtime_schema.config ->
  integration_id:string ->
  (Server_runtime_setup_actions.login_target, person_refusal) result

val start : owner:owner -> base_path:string -> body:string ->
  Httpun.Request.t -> Http_reqd.t -> unit
val control : owner:owner -> base_path:string -> body:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

val status : owner:owner -> base_path:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

(** Calls a person's own account once (plan D1-6a): the body is
    [{"provider_account_id":...,"model":...}]. The account must be one the
    person owns in the authorization log; another person's is answered as one
    that does not exist (404), before the call of the account is taken, so
    whether a call of another person's account runs is not told. The runtime
    is the workspace provider of the integration of the account
    ({!person_runtime}), with the person's account home and that provider's
    binding of [model] ({!Runtime_account_runtime}), and the call is
    {!Runtime_verification.verify_as_command}, the readiness check of the
    [runtime-verify] command: a model answer and a tool round trip, within 120
    seconds.

    The answer is [{"verification": ..., "runtime": ...}].
    [verification] is {!Runtime_verification.to_member_json}: the detail of a
    failure goes to the server log, since it can name a path of the server.
    When the call passes, the binding is a Runtime of the person: the first
    pass writes its record with a Self grant to the authorization log
    ({!Authz_runtime.make}); the grant allows [read_state], [invoke_model]
    and [use_tool]. [runtime] is
    [{"runtime_id":...,"record":"made"}], or ["existing"] on a later pass.
    When it fails, [runtime] is [null]. Nothing is written to runtime.toml.

    One call of an account runs at a time ({!Runtime_account_call.one_call_of}): a request while a
    verification or a Keeper turn of the account runs is answered 409. A key
    account whose key file is not there or is not read as a key is a 409 too,
    with the [code] [key_missing] or [key_unreadable] beside the [error].

    A call the provider answered with HTTP 401 on a key account is a 200
    whose [verification] failed with the code [key_refused]
    ({!Runtime_verification.failure}); on a login account the code stays
    [provider_auth_refused]. *)
val verify : person:person -> base_path:string -> body:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

(** The runtime of a person's own account. *)
type prepared =
  { provider_account_id : Authz_types.Provider_account_id.t
  ; runtime_id : Authz_types.Runtime_id.t
      (** The id of [runtime], which a Runtime record of the person names. *)
  ; runtime : Runtime_instance.t
  }

(** Why {!person_runtime} made no runtime. *)
type runtime_error =
  | Refused of [ `Bad_request | `Not_found | `Service_unavailable ] * string
      (** The status and the sentence of the answer. *)
  | Key_unusable of Runtime_api_key_file.read_error
      (** The account is a key account and its key file gave no key. No
          client starts (RFC a-persons-api-key-is-their-own-provider-account
          3.5). The reason is in the server log. *)

(** What a person is told of a key file that gave no key. It names no path
    and nothing of the key. The code of the answer is
    {!Runtime_api_key_file.read_error_code}. *)
val key_unusable_message : Runtime_api_key_file.read_error -> string

(** The runtime of [binding] on the home of the account of the call, an
    account of the person: a provider of the workspace with the home of the
    account ({!Runtime_account_runtime}). {!verify} chooses a model, and a
    turn of a Keeper the Runtime its owner gave it (plan D2-8).

    It takes the call of the account ({!Runtime_account_call.one_call_of}), so the records of the
    account and its key file are read inside that call. The files of an
    account change only inside its call, so no runtime is made on a key that
    a removal or a replacement was taking away.

    The record that linked the account says what it runs on. Both a login
    account and a key account are of the provider their record names. A login
    account runs on the login in its home. A key account runs on the key in the
    file of the generation the records say. That file is read before the home
    is looked at: an account whose record was written and whose files were not
    is [Key_unusable Key_missing].

    An account the person does not own is a 404. *)
val person_runtime
  :  Runtime_account_call.t
  -> person
  -> base_path:string
  -> binding:Runtime_account_runtime.binding
  -> (prepared, runtime_error) result

(** The runtime root of [person] under [base_path], made when it is not
    there: the folder the homes and the key files of their accounts are
    under ({!Runtime_account_home_layout.person_runtime_root}). A login and
    a verification make it the same way. The registration of a key asks for
    it after the record of its account is written
    ({!Server_key_account_registration}), and the replacement of a key
    before its record ({!Server_key_account_replacement}). A name that is
    there is taken as the folder: whether it is one, and whether it is
    reached, is for whoever makes a file under it. The error is a sentence
    that names no path. *)
val person_runtime_root : person -> base_path:string -> (string, string) result

(** Whether a key account of [integration_id] carries a Claude Code home or
    no CLI home (HTTP providers, RFC a-persons-api-key-is-their-own-provider-account 3.9). *)
val key_account_home_kind
  :  Runtime_schema.config
  -> integration_id:Authz_types.Integration_id.t
  -> Runtime_key_account_files.home_kind

(** {!key_account_home_kind} against [base_path]'s runtime.toml; defaults to
    {!Runtime_key_account_files.Claude_home} when the workspace config is
    unreadable or does not declare [integration_id]. *)
val key_account_home_kind_at
  :  base_path:string
  -> integration_id:Authz_types.Integration_id.t
  -> Runtime_key_account_files.home_kind

module For_testing : sig
  val initial_account_for_login
    :  owner
    -> Runtime_setup_login_client.client
    -> Runtime_setup_accounts.reference option
    -> base_path:string
    -> integration_id:string
    -> cli_path:string
    -> Runtime_setup_login_client.t
    -> (Runtime_setup_login_receipt.account, string) result

  val finish_login
    :  owner
    -> client:Runtime_setup_login_client.client
    -> base_path:string
    -> integration_id:string
    -> cli_path:string
    -> login_id:string
    -> Runtime_setup_login_client.t
    -> (Runtime_setup_login_receipt.account, string) result
end
