(* HIGH-RISK-UNREVIEWED: this is the mode that the mode events of the
   authorization log add up to. The boot decides from it whether the
   installation runs with accounts. *)

(** The mode of the installation, as the mode events of [authz.jsonl] leave it
    (design 5.1, 8.4, 10.5). It is the mode field of {!Authz_state}.

    [Fresh_bootstrap] sets the installation up, once, with its workspace id.
    [Off] turns the accounts off and [Reactivate] turns them on again; both
    name the workspace that the bootstrap set up. {!apply} refuses every other
    order, because a log that holds one was not written by masc: every pair of
    a state and an event is listed in {!apply}. *)

type t =
  | Not_bootstrapped  (** No mode event yet. *)
  | Multi_account of Authz_types.Workspace_id.t
      (** The last mode event is [Fresh_bootstrap] or [Reactivate]. *)
  | Off of Authz_types.Workspace_id.t  (** The last mode event is [Off]. *)

val empty : t
val equal : t -> t -> bool

(** A label for messages. *)
val to_string : t -> string

type refusal =
  | Out_of_order of
      { state : t
      ; event : Authz_mode_event.event
      }  (** This event cannot follow this state. *)
  | Workspace_differs of
      { bootstrapped : Authz_types.Workspace_id.t
      ; named : Authz_types.Workspace_id.t
      }  (** [Off] or [Reactivate] names another workspace than the bootstrap. *)

val refusal_to_string : refusal -> string

(** The state after one more mode event. *)
val apply : t -> Authz_mode_event.t -> (t, refusal) result
