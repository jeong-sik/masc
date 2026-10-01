(** Durable document ownership, independent of TOML parsing and live sources.
    The caller has already verified the Keeper and proposed binding. Initial
    admission precedes the source write and grants access only to its exact
    prior/proposed bytes; completion binds the admitted revision and retains
    stable repair authority for malformed edits.
    These blocking operations run at the runtime's filesystem effect boundary. *)
type t
val read : root:string -> source_path:string -> (t option, string) result
val permits : t -> keeper:string -> source_revision:string -> bool
val repair_permits : t -> keeper:string -> bool
(** A completed owner may submit a repair for unadmitted current bytes without
    receiving their body. The proposed binding still needs live authority. *)
val prepare : root:string -> source_path:string -> keeper:string ->
  prior_revision:string option -> proposed_revision:string -> (unit, string) result
val complete : root:string -> source_path:string -> keeper:string ->
  source_revision:string -> (unit, string) result
val reassign : root:string -> source_path:string -> keeper:string ->
  source_revision:string -> (unit, string) result
(** Operator configuration authority only: records an explicit reassignment to
    exact observed bytes. Call [complete] after rereading those bytes. *)

val revoke : root:string -> source_path:string -> (unit, string) result
(** Supersede Keeper authority when operator configuration becomes shared or operator-only. *)
