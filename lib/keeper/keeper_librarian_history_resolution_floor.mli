(** Full-source floor owned by a confirmed Cut descendant. This path never
    selects fresh source, narrows its original range, abandons counterpart
    input or turns a refused message into accounted unread coverage. Call
    inside the serialized Memory lane and purge fence. *)
type t
val candidate : store:Lane_addon_store.t ->
  record:Lane_addon_tool_request_owner.retained ->
  request:Keeper_librarian_durable_request.t -> (t option, string) result
(** Strict actual definite input-refused leaf and confirmed Cut ancestry.
    The original has no preparation, replacement or settlement. This supplies
    no dispatch, publication or ACK authority by itself. *)
val request : t -> Keeper_librarian_durable_request.t
val cut_original_id : t -> string

type attention =
  | No_message_coordinate
  | Message_refused of {position:int; report:Keeper_librarian_runtime.not_committed}
  | Declaration_replaced of {position:int; request_id:string}
type prepared
type outcome = Pending of Keeper_librarian_pending.t | Attention of attention | Prepared of prepared
val descend : config:Workspace.config -> reserved:string list -> t -> (outcome, string) result
(** Restore the same first anchor/complete manifest before observing pending
    work. Fresh source/anchor checks guard only new inference, outside model
    calls. Every question uses the definite leaf's frozen preparation and
    working context. A source with no message coordinate stays attention. *)
val publish : t -> prepared -> (Keeper_memory_os_current.committed_program, string) result
(** Reattest the exact full source under its owning locks, rejoin the original
    first anchor and atomically publish once. Strict readback, full ranges,
    source hashes, original anchor and an empty program unread list decide
    success. No ACK, intent completion or cleanup. *)
val recover_committed : t -> (Keeper_memory_os_current.committed_program option, string) result
(** Recover only this retained chain's actual canonical program. It does not
    reread prunable source fragments or infer from a range receipt alone. *)
val confirm_program : t -> Keeper_memory_os_current.committed_program -> (unit, string) result
(** Fresh contextual leaf/Cut confirmation plus exact program/range readback.
    Caller keeps the source-owner scope and holds no Memory lock. *)
val validate_retained_step : store:Lane_addon_store.t ->
  Keeper_librarian_floor_step_request.t -> (unit, string) result
(** Host fresh-dispatch guard. Ordinary steps preserve their existing policy.
    Retained mode must rejoin the actual input-refused leaf, confirmed Cut
    ancestry, first full manifest/anchor and current source. A mode tag alone
    never grants execution authority. No provider call. *)
