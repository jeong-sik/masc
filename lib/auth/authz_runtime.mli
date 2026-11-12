(* HIGH-RISK-UNREVIEWED: this module writes the record that makes a person the
   owner of a Runtime and gives them its Self grant. *)

(** Makes a Runtime on a provider account of its owner, against the writer zone
    (design 4.2-4.3, plan D1). The subscription verify route calls {!make} when
    a model of the person's account answered and called a tool. *)

type error =
  | Id_not_drawn of Authz_id.error  (** [draw] gave a value that is not a grant id. *)
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error
      (** The zone refused the record: the person is no longer active, the
          account is not theirs, or the Runtime was made before, among others. *)

(** The reason in full, as {!Authz_zone.error_detail} gives that of a commit
    that failed. It can name paths of the server, so it is for the log of the
    server and not for an answer to a person. *)
val error_detail : error -> string

(** Writes the record that makes [runtime_id] on [provider_account_id] for
    [user_id], with a Self grant whose id is [draw ()] and that allows
    [self_effects]. The result is that id. *)
val make
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> runtime_id:Authz_types.Runtime_id.t
  -> self_effects:Authz_types.Effect.Set.t
  -> draw:(unit -> string)
  -> (Authz_types.Grant_id.t, error) result

(** The Runtimes the person owns, in the order of their ids. *)
val owned
  :  Authz_state.t
  -> Authz_types.User_id.t
  -> (Authz_types.Runtime_id.t * Authz_runtime_state.runtime) list
