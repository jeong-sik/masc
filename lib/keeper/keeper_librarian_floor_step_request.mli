(** Original host request for one question of the durable message floor
    (RFC librarian-durable-message-floor). The floor reads a turn that exceeded
    the worker frame one message at a time; each question is one original of its
    own, retained before dispatch, in a scope of its own, so completed-history
    discovery never sees it as a history original.

    A step holds no source. Its input is the question the floor's machine asks
    after the answers the earlier steps retained, so a caller restores a step by
    replaying the chain and handing over the question; the digest of the sent
    prompt rejects any question that differs. A step names the range original
    it reads and the step before it by request ID and digest. Whether those
    records exist and agree is the chain's check, not this module's.
    Retention and restore perform no provider, Gate, Memory, source or cursor
    effect. Blocking filesystem operations must be offloaded as a whole from
    Eio callers. *)
type link = {request_id:string;request_digest:string}
(** An original named by the ID and digest of its record. *)

val scope : Keeper_librarian_durable_request.owner -> string
(** The store scope of this owner's steps. It differs from the owner's history
    scope. *)
val fresh_request_id : Keeper_librarian_durable_request.owner -> string
val scope_of_request_id : string -> (string, string) result
(** A history request ID is not a step ID, and a step ID is not a history ID. *)

type t
val create : request_id:string -> owner:Keeper_librarian_durable_request.owner ->
  destination:Keeper_librarian_durable_request.destination -> range:link -> previous:link option ->
  question:Keeper_librarian_message_floor.Machine.question ->
  step:Keeper_librarian_runtime.durable_step_preparation -> unit -> (t, string) result
(** [range] is a history request of the owner and [previous] a step of the
    owner other than this one. Only the first question has no [previous]. The
    step must be the preparation of [question]: its context, its input with the
    working context cleared, its position and its sources. The request restores
    from its own encoding before it is returned. *)
val restore : owner:Keeper_librarian_durable_request.owner ->
  question:Keeper_librarian_message_floor.Machine.question ->
  Lane_addon_tool_request_owner.retained -> (t, string) result
(** Decode the record's request against [question], rendering the prompt again
    from the retained resolutions. The record must be this owner's step scope
    with the host binding the request names. *)
val confirm_record : t -> Lane_addon_tool_request_owner.retained -> (unit, string) result
(** The record is this step's: same scope, ID and host binding, and the digest
    of this request. *)
val to_json : t -> Yojson.Safe.t
val request_id : t -> string
val physical_owner : t -> Keeper_librarian_durable_request.owner
val destination : t -> Keeper_librarian_durable_request.destination
val range : t -> link
val previous : t -> link option
val position : t -> int
val sources : t -> Keeper_librarian_unread.source list
val step : t -> Keeper_librarian_runtime.durable_step_preparation
val request : t -> (Lane_addon_exact.request, string) result
val confirm_owner : t -> (unit, string) result
val confirm_final : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (unit, string) result
(** Reobserve the full physical owner and epoch, then the host proof of
    {!Keeper_librarian_original_final.confirm_final}. *)
val refusal_evidence : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (Keeper_exact_walk_failure.t, string) result
(** What a refused step shows about reading less, by the rules of
    {!Keeper_librarian_original_final.refusal_evidence}. *)
val validate_proposal : t -> Yojson.Safe.t ->
  (Keeper_librarian_runtime.durable_step_proposal, string) result
(** Parse the step's raw answer against its input and require a nonblank
    working state. *)
