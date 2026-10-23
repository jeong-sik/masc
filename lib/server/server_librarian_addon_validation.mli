(** Host-owned original Librarian authority for common Exact dispatch/delivery.
    Neither a package name nor a worker request can grant Background admission. *)
val authorize : base_path:string -> store:Lane_addon_store.t -> declaration_id:string ->
  package:Lane_addon_types.package -> Lane_addon_exact.request ->
  (Lane_addon_exact.output_validator option, string) result
(** [None] means this request does not occupy the Librarian original namespace.
    A Librarian package or a namespaced request without a complete original
    capture is refused. Restore the physical Keeper/Memory epoch, complete
    original part forest, acknowledged ancestry and full original request/schema
    before returning a pure complete-domain validator. Both new execution and
    retained delivery use this boundary. No provider, worker, Memory or ACK
    effect is performed. Existing Store reads run on a system thread. *)
