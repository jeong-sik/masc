(** Durable document ownership, independent of TOML parsing and live sources.
    The caller has already verified the Keeper and proposed binding. Initial
    admission precedes the source write and grants access only to its exact
    prior/proposed bytes; completion establishes stable repair authority.
    These blocking operations run at the runtime's filesystem effect boundary. *)
type t
val read : root:string -> source_path:string -> (t option, string) result
val permits : t -> keeper:string -> source_revision:string -> bool
val prepare : root:string -> source_path:string -> keeper:string ->
  prior_revision:string option -> proposed_revision:string -> (unit, string) result
val complete : root:string -> source_path:string -> keeper:string ->
  source_revision:string -> (unit, string) result
