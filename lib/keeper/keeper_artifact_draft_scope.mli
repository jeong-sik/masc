(** A sealed editing lifetime owned by one tool bundle. Closing is terminal:
    a suspended tool may report its durable result but cannot revive presence. *)
type t
type error = Closed | Owner_mismatch | Turn_mismatch
val create : base_path:string -> keeper:string -> t
val admit : t -> base_path:string -> keeper:string -> turn_ref:Ids.Turn_ref.t -> (unit, error) result
val present : t -> turn_ref:Ids.Turn_ref.t -> Artifact_draft_store.view -> (unit, error) result
val leave : t -> target:Artifact_draft.target -> unit
val close : t -> unit
