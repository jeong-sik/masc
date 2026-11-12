(* HIGH-RISK-UNREVIEWED: [whoami] tells a browser who the server takes it for,
   and the pages start a login and sign a browser out. *)

(** The pages and the who-am-I answer of the localhost preview of
    multi-account login (plan, preview scope P2).

    Each value is an answer of {!Login_routes}, so the server writes it as it
    writes a login answer. This module holds no HTTP type: the preview command
    (P3) reads the request and registers the routes.

    The pages hold no request data. The invitation token stays in the
    fragment of the link ({!Authz_activation.link}), which the browser does
    not send, and the script of the invitation page copies it into the form.
    The CSRF token of a sign-out comes from [GET /auth/session]. *)

(** [GET /accounts/invite], the page that an invitation link opens: a form
    that starts a GitHub login with the token of the link. [nonce] is the
    nonce of its script. [github] is whether the server has a GitHub login
    client: without one the button cannot be pressed and the page says that
    the server has no GitHub login. An address with no token shows how to open
    the invitation again in place of the form. The pages start no Google
    login. *)
val invite_page : nonce:string -> github:bool -> Login_routes.answer

(** [GET /]: for a browser with no session, a form that starts a GitHub
    login and no answer of a route. For a signed-in browser, the session and
    who the server takes it for, and a sign-out button. Below them, the
    subscriptions the person owns, a form that connects one through
    {!connect_path} and answers its login, and a form that calls one through
    {!verify_path}. Last, the person's Runtimes and Keepers, a form that
    makes a Keeper and gives it a Runtime through {!Auth_preview_keeper}, and
    a form that sends the Keeper a message through
    {!Auth_preview_keeper.turn_path} and shows its answer. *)
val home_page : nonce:string -> github:bool -> Login_routes.answer

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
    (plan D1-6a). The home page posts the account and the model to it. *)
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

(** A 200 JSON [{"provider_accounts": [...], "runtimes": [...]}]: the ids of
    the accounts the person owns ({!Authz_provider_account.owned}), and the
    Runtimes they own as [{"runtime_id":...,"provider_account_id":...}]
    ({!Authz_runtime.owned}). *)
val provider_accounts : Authz_state.t -> person -> Login_routes.answer
