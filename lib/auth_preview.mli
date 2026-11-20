(* HIGH-RISK-UNREVIEWED: [whoami] tells a browser who the server takes it for,
   the pages start a login, and the home page signs a browser out. *)

(** The pages and the who-am-I answer of the localhost preview of
    multi-account login (plan, preview scope P2).

    Each value is an answer of {!Login_routes}, so the server writes it as it
    writes a login answer. This module holds no HTTP type: the preview command
    (P3) reads the request and registers the routes.

    The pages hold no request data. The invitation token stays in the
    fragment of the link ({!Authz_activation.link}), which the browser does
    not send, and the script of the invitation page copies it into the form.
    A login started from either page comes back to
    {!Account_page.console_path}. *)

(** [GET /accounts/invite], the page that an invitation link opens: a form
    that starts a GitHub login with the token of the link. [nonce] is the
    nonce of its script. [github] is whether the server has a GitHub login
    client: without one the button cannot be pressed and the page says that
    the server has no GitHub login. When [google] is [true], the page also
    renders a [POST /auth/oidc/start] form. An address with no token shows how
    to open the invitation again in place of the form. *)
val invite_page : google:bool -> nonce:Csp_nonce.t -> github:bool -> Login_routes.answer

(** [GET /]: for a browser with no session, a form that starts a GitHub
    login and no answer of a route. When the session routes do not say whether
    a session is open, the page says so in place of that form. A browser with
    a session goes on to {!Account_page.console_path}, where the person uses
    their subscriptions, Keepers and tokens, and signs out. When the server
    does not give the console (a 503 while the dashboard bundle cannot be
    read), the page stays, says so, and offers the sign-out
    ([POST /auth/logout]) in its place. *)
val home_page : google:bool -> nonce:Csp_nonce.t -> github:bool -> Login_routes.answer

(** [GET /api/v1/auth/whoami], judged as [Read_auth] by {!Auth_gate.decide}
    on a snapshot the zone could be trusted for ({!Authz_zone.read}), as
    every judgment of this interface is. A 200 JSON
    [{"principal": ..., "role": ..., "binding": ...}], or a JSON
    [{"error": ...}] with a 401 or a 403 ({!Auth_gate.is_unauthenticated}). *)
val whoami : Authz_zone.trusted -> now_ms:int -> Auth_gate.request -> Login_routes.answer

(** [/api/v1/setup/accounts/login], the subscription connect route of the
    server. The preview serves it, its status and its control under
    {!connect_prefix}, for a {!person} (plan D1-4). *)
val connect_path : string

val connect_prefix : string

(** [/api/v1/auth/provider-accounts]: {!provider_accounts}. *)
val provider_accounts_path : string

(** [/api/v1/setup/accounts/verify]: one call of the person's own account
    (plan D1-6a). The console posts the account and the model to it. *)
val verify_path : string

(** A person that a [Manage_own_provider] route lets through, with the
    namespace their admission fixed. *)
type person =
  { user_id : Authz_types.User_id.t
  ; namespace : Authz_types.Account_home_namespace.t
  }

(** Judges the request as [Manage_own_provider] by {!Auth_gate.decide}. A
    request that does not pass gets the answer to write: a JSON
    [{"error": ...}] with a 401 or a 403. *)
val person
  :  Authz_zone.trusted
  -> now_ms:int
  -> Auth_gate.request
  -> (person, Login_routes.answer) result

(** Judges the request as [Manage_own_keeper] by {!Auth_gate.decide}: the
    person whose Keepers a Keeper route reads and writes (plan D1-5). A
    request that does not pass gets the answer to write, as for {!person}. *)
val keeper_owner
  :  Authz_zone.trusted
  -> now_ms:int
  -> Auth_gate.request
  -> (Authz_types.User_id.t, Login_routes.answer) result

(** Who asks for a turn of their Keeper. *)
type turn_caller =
  { person : person
        (** With the namespace their admission fixed: the turn starts the
            client of their account on a home under it (plan D2-8). *)
  ; pat : Authz_types.Pat_binding.t
        (** The personal access token that authenticated the request, or
            [Not_pat] for a session. The decision of the turn reads its
            scope ({!Authz_keeper_turn.decide}). *)
  }

(** Judges the request as [Manage_own_keeper], as {!keeper_owner} does, and
    gives the caller of the turn. *)
val keeper_turn_caller
  :  Authz_zone.trusted
  -> now_ms:int
  -> Auth_gate.request
  -> (turn_caller, Login_routes.answer) result

(** Who reads what they asked their Keeper and what it answered (plan
    S1b-3). The request is judged as [Manage_own_keeper], as {!keeper_owner}
    judges it, and as [Read_auth], as {!whoami} judges it: a personal access
    token needs both effects, so one that lists Keepers and lacks
    [read_state] reads no conversation. *)
val keeper_conversation_reader
  :  Authz_zone.trusted
  -> now_ms:int
  -> Auth_gate.request
  -> (person, Login_routes.answer) result

(** A 200 JSON [{"provider_accounts": [...], "runtimes": [...]}].

    - The accounts of the person that a list shows
      ({!Authz_provider_account.shown}: not those whose removal is pending
      or went through), as
      [{"provider_account_id":...,"kind":...,"integration_id":...}].
      ["kind"] is ["login"] or ["key"] (RFC
      a-persons-api-key-is-their-own-provider-account 3.8). The integration
      of both a login account and a key account is the one its record names.
      A key account has ["key"] too: ["readable"], or [key_missing] or
      [key_unreadable] as a use of the account answers
      ({!Runtime_key_account_files.key_state}), or [not_looked_at]. Nothing
      of the key is in the answer. An account whose removal did not go
      through has ["removal"]: [key_not_removed] or [home_not_removed], the
      stage that stayed, or [start_given_up]. Nothing spends such an
      account, and its owner asks for the removal again. An account whose
      key was to be replaced, where the start of the replacement wrote its
      intent and no record, has ["replacement"]: [start_given_up]. Nothing
      spends it either, and its owner asks for the replacement again or
      removes the account. An account with both has ["removal"] only.
    - The Runtimes they own ({!Authz_runtime.owned}) on the accounts shown
      that a turn would be let onto ({!Authz_provider_account.availability}),
      so none of an account with a removal or a replacement on it, as
      [{"runtime_id":...,"provider_account_id":...,"model":...}]: the model
      of the binding of the account's template that makes the Runtime id
      ({!Runtime_account_runtime.binding_of}), the binding a turn of the
      Runtime finds. The model is the key of its [models.<id>] table, as
      the integrations list names it; a turn sends the model's [api-name],
      which may be another name. [config] is the runtime.toml of the
      workspace, [None] when it could not be read.

    A model that is not read is [null], and ["unread"] says why:
    [configuration_unavailable],
    [template_not_declared] (runtime.toml no longer declares the account's
    integration) or [runtime_not_bound] (no binding of it makes the Runtime
    id). *)
val provider_accounts
  :  base_path:string
  -> config:Runtime_schema.config option
  -> Authz_state.t
  -> person
  -> Login_routes.answer
