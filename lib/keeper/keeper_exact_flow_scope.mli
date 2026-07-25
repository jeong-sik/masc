(** Opaque OAS exact-flow preference ownership for one registered Keeper.

    MASC owns only the logical [(base_path, keeper_name)] lifetime and the
    facade label. Candidate identities, admission, execution, and preference
    updates remain OAS-owned. *)

type surface =
  | Compaction
  | Board_attention
  | Hitl_summary
  | Librarian

type t

val for_registered
  :  is_registered:(unit -> bool)
  -> base_path:string
  -> keeper_name:string
  -> surface:surface
  -> (t, string) result
(** Return the stable scope owned by one currently registered Keeper. The
    registry predicate is evaluated while the Keeper lifecycle key lock is
    held, so unregister cannot race a late owner insertion. *)

val preference_store : t -> Agent_sdk.Exact_output.flow_preference_store
val scope : t -> Agent_sdk.Exact_output.flow_scope

val release_owner : base_path:string -> keeper_name:string -> unit
(** Remove every facade scope for the logical owner. Registry unregistration
    calls this while it still owns the lifecycle key lock. *)

val clear : unit -> unit

module For_testing : sig
  val create
    :  base_path:string
    -> keeper_name:string
    -> surface:surface
    -> t
  (** Create an unregistered, caller-owned scope without touching the global
      owner table. Tests must retain and explicitly share this value when they
      want to prove future-snapshot preference behavior. *)
end
