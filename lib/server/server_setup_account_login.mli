(** Official-client login of a provider account. Session control also checks
    the caller and the canonical workspace. No browser paths or commands. *)

(** Who connects the account. It decides where the account home lies and
    what a confirmed login leaves behind. *)
type owner =
  | Operator of { actor : string }
      (** Single-user: the caller passed [CanAdmin], and [actor] is its agent
          name. The home goes under the workspace's official-clients
          directory, and a confirmed login publishes the account to the setup
          registry. *)
  | Person of
      { zone : Authz_zone.t
      ; user_id : Authz_types.User_id.t
      ; namespace : Authz_types.Account_home_namespace.t
          (** The namespace the admission of [user_id] fixed. *)
      }
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
