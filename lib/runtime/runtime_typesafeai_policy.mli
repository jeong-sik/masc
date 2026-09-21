(** The [\[typesafeai\]] table of the loaded runtime.toml, as the lane's
    readers see it. {!Runtime.set_loaded} publishes it on every load; before
    any load, {!current} is {!Runtime_schema.default_typesafeai}. *)

val current : unit -> Runtime_schema.typesafeai
(** The published policy. *)

val publish : Runtime_schema.typesafeai -> unit
(** Replace the published policy. Called by {!Runtime.set_loaded}; a test
    that needs a policy without a runtime.toml calls it directly and restores
    what it found. *)
