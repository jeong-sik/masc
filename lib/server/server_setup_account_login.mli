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

    One verification of an account runs at a time: a second request while one
    runs is answered 409 (issue #50018). *)
val verify : person:person -> base_path:string -> body:string ->
  Httpun.Request.t -> Http_reqd.t -> unit
