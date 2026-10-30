(** Host-owned original Librarian authority for common Exact dispatch/delivery.
    Neither a package name nor a worker request can grant Background admission. *)
type authorization = {
  validate_output : Lane_addon_exact.output_validator;
  before_dispatch : Lane_addon_exact.dispatch_guard;
  with_execution : Lane_addon_exact.execution_scope;
}
val authorize : base_path:string -> store:Lane_addon_store.t -> declaration_id:string ->
  package:Lane_addon_types.package -> Lane_addon_exact.request ->
  (authorization option, Lane_addon_exact.authority_refusal) result
(** [None] means this request does not occupy the Librarian original namespace.
    A Librarian package or a namespaced request without a complete original
    capture is refused. Decode explicit-candidate and completed-history IDs as
    separate typed namespaces. Restore the physical Keeper/Memory epoch and
    either the complete candidate forest/acknowledged ancestry or complete
    history source and immutable Memory preparation, then the original request/schema
    and any replacement parent's complete acknowledged child intent, rechecked
    at actual dispatch,
    before returning a pure complete-domain validator and an execution-only
    fresh physical original/semantic Runtime guard and the original Keeper
    external-effect purge scope. The latter is called at each actual dispatch,
    never for retained delivery or after provider completion. Both new execution and
    retained delivery use this boundary. No provider, worker, Memory or ACK
    effect is performed. Existing Store reads run on a system thread. *)
