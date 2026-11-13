(** Official-client login of a provider account. Session control also checks
    the caller and the canonical workspace. No browser paths or commands. *)

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
          person always makes a new account: [account_ref] is refused, and so
          is Antigravity, whose credential copy lives in the setup registry,
          which has no owner. *)

(** The CORS headers of the event stream that {!start} answers. A person's
    stream has none: the page of the account server reads it from the same
    origin, and no other origin is allowed to read it with the person's
    credentials. The operator's stream allows the [Origin] of the request,
    as the single-user server does ({!Server_auth.cors_headers}). *)
val stream_cors_headers : owner -> Httpun.Request.t -> (string * string) list

(** Whether a person may log in to an account of this client: every client
    but Antigravity, whose credential copy lives in the setup registry, which
    has no owner. The error is the sentence {!start} answers a person with. *)
val person_may_connect : Runtime_setup_login_client.client -> (unit, string) result

val start : owner:owner -> base_path:string -> body:string ->
  Httpun.Request.t -> Http_reqd.t -> unit
val control : owner:owner -> base_path:string -> body:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

val status : owner:owner -> base_path:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

(** Calls a person's own account once (plan D1-6a): the body is
    [{"provider_account_id":...,"model":...}]. The account must be one the
    person owns in the authorization log; another person's is answered as one
    that does not exist (404). The runtime is the workspace provider the login
    receipt names, with the person's account home and that provider's binding
    of [model] ({!Runtime_account_runtime}), and the call is
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

    One call of an account runs at a time ({!one_call_of}): a request while a
    verification or a Keeper turn of the account runs is answered 409. *)
val verify : person:person -> base_path:string -> body:string ->
  Httpun.Request.t -> Http_reqd.t -> unit

(** The runtime of a person's own account. *)
type prepared =
  { provider_account_id : Authz_types.Provider_account_id.t
  ; runtime_id : Authz_types.Runtime_id.t
      (** The id of [runtime], which a Runtime record of the person names. *)
  ; runtime : Runtime_instance.t
  }

(** The runtime of [binding] on the home of the person's account
    [provider_account_id]: the workspace provider the login receipt of the
    account names, with the account's home ({!Runtime_account_runtime}).
    {!verify} chooses a model, and a turn of a Keeper the Runtime its owner
    gave it (plan D2-8). An account the person does not own, or one with no
    login receipt of theirs, is a 404 with the same sentence. *)
val person_runtime
  :  person
  -> base_path:string
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> binding:Runtime_account_runtime.binding
  -> (prepared, [ `Bad_request | `Not_found | `Service_unavailable ] * string) result

(** Runs [f] when no other call of the account runs, and gives [busy]
    otherwise. A call starts the official client on the home of the account,
    and no two clients refresh the credential of one home at once, so a
    verification and a Keeper turn of one account take turns (issue #50018).
    It holds within this process. *)
val one_call_of
  :  Authz_types.Provider_account_id.t
  -> busy:'e
  -> (unit -> ('a, 'e) result)
  -> ('a, 'e) result
