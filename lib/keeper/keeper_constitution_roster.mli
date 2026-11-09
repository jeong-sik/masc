(** Capture durable Keeper names once for a constitution read. Metadata
    contents and transient registry health do not determine name membership.
    The returned resolver is immutable: a held ledger and its historical
    prefix must use the same captured names. An unreadable roster is an error,
    never an empty roster that silently isolates every norm. *)
val read :
  config:Workspace.config ->
  ((string -> bool), World_constitution_store.read_error) result
