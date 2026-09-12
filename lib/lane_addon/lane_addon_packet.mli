(** Opt-in worker output. Artifact bytes arrive inside the already bounded MCP
    reply; the host hashes and retains them before accepting row references.
    URI evidence remains a reference and is never fetched here. *)
val decode : ?store:Lane_addon_store.t -> max_bytes:int -> Yojson.Safe.t ->
  (Lane_addon_types.output, string) result
