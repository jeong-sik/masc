(** Closed types of the authorization domain: who acts, on which runtime,
    through which channel, for which effects (design 4.1 and 4.4).

    Nothing here reads a store or the clock. Callers build these values from
    verified credentials and stored rows; {!Authz_decision} combines them. *)

module User_id : Authz_id.S
module Service_id : Authz_id.S
module Runtime_id : Authz_id.S
module Provider_account_id : Authz_id.S
module Grant_id : Authz_id.S
module Policy_id : Authz_id.S
module Workspace_id : Authz_id.S

module Principal : sig
  type t =
    | Human of User_id.t
    | Service of Service_id.t

  val equal : t -> t -> bool

  (** A label for logs. It is not an identifier and is not parsed back. *)
  val to_string : t -> string
end

(** What a request wants to do. The set is closed: a new effect is denied
    everywhere until a grant lists it. *)
module Effect : sig
  type t =
    | Read_state
    | Invoke_model
    | Use_tool
    | Manage_own_provider
    | Manage_own_runtime
    | Manage_own_grant
    | Manage_own_keeper
    | Manage_machine_shared
    | Admin_disable_block
    | Read_audit_metadata

  val to_string : t -> string

  (** The five [Manage_*] effects and [Admin_disable_block]: the ones that
      change who may do what, or whether something runs. A PAT that asks for
      one must name the channel and the effects; [All] in either does not
      count, and its runtimes may stay [All] (design 4.4). Every effect is
      placed by an exhaustive match, so a new one cannot skip this question. *)
  val is_management : t -> bool

  module Set : Set.S with type elt = t
end

(** How a request reached the runtime. *)
module Channel : sig
  type t =
    | Direct
    | Delegate
    | Schedule
    | Board_trigger
    | Retry
    | Resume
    | Fusion
    | Vision
    | Verifier
    | Autonomous

  val equal : t -> t -> bool

  module Set : Set.S with type elt = t
end

module Runtime_scope :
  Authz_scope.S with type elt = Runtime_id.t and module Set = Runtime_id.Set

module Channel_scope : Authz_scope.S with type elt = Channel.t and module Set = Channel.Set
module Effect_scope : Authz_scope.S with type elt = Effect.t and module Set = Effect.Set

(** The limits one source puts on a request (design 4.4). *)
module Authorization_scope : sig
  type t =
    { runtimes : Runtime_scope.t
    ; channels : Channel_scope.t
    ; allowed_effects : Effect_scope.t
    }

  (** Puts no limit on any dimension. *)
  val all : t

  val inter : t -> t -> t
end

module Pat_scope : sig
  type t =
    { scope : Authorization_scope.t
    ; expires_at : float option
        (** Seconds since the epoch. A scope is expired when the clock is not
            before this instant. *)
    }
end

(** [Not_pat] is a request that does not authenticate with a PAT. It limits
    nothing, but it does not skip the grant, policy, or channel checks. *)
module Pat_binding : sig
  type t =
    | Not_pat
    | Pat of Pat_scope.t

  val scope : t -> Authorization_scope.t
end

module Delegate_policy : sig
  type t =
    { id : Policy_id.t
    ; initiator : Principal.t
    ; executor : Principal.t
    ; scope : Authorization_scope.t
    }

  (** The filter used when the initiator is the executor and the channel is
      [Direct]: every runtime and effect, [Direct] only. It is not a stored
      policy and grants nothing. *)
  val neutral_direct : Authorization_scope.t
end

(** The effects a request asks for. It is never empty, so a request cannot
    pass an effects check by asking for nothing. *)
module Effect_request : sig
  type t

  val make : Effect.t -> Effect.t list -> t
  val to_set : t -> Effect.Set.t
end

module Execution_context : sig
  type t =
    { initiator : Principal.t
    ; executor : Principal.t
    ; channel : Channel.t
    ; stored_scope : Authorization_scope.t
    ; pat_scope : Pat_binding.t
    }
end
