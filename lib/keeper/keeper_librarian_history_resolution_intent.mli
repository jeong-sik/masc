(** One original's durable resolution requests. Submission identity is the
    canonical original/guard/actor/reason digest; Cut also binds its tagged
    origin. Existing absence submissions retain their exact encoding/identity.
    At most one non-refused request and one child intent own an original. *)
type refusal = Observation_changed | No_longer_eligible of string
type origin = Worker_absence
  | Same_binding_cut of Keeper_librarian_history_resolution_state.cut_basis
type child = private { request_id:string; request_digest:string }
type prepared_child = private {
  child:child;
  request:Keeper_librarian_durable_request.t;
}
type phase = Requested | Refused of refusal | Fenced
  | Child_prepared of prepared_child | Child_intended of child | Child_confirmed of child
type memory_commit = private {
  request_id:string;
  receipts:Keeper_memory_os_current_types.durable_range_receipt list;
  program:Keeper_librarian_history_program_settlement.retained option;
}
type t = private {
  intent_id:string;
  scope:string;
  original_request_id:string;
  expected:Keeper_librarian_history_resolution_state.guard;
  origin:origin;
  actor:string;
  reason:string;
  submitted_at:float;
  phase:phase;
  memory_commit:memory_commit option;
}
type error = Invalid of string | Conflict of string | Unavailable of string
  | Publication_uncertain of string | Host_claim_busy
val error_to_string : error -> string
val to_public_json : t -> Yojson.Safe.t
(** Contains no original body, preimage or child request body. *)
val decode_published : scope:string -> request_id:string -> Yojson.Safe.t ->
  (t list, string) result
(** Pure strict envelope decoder for the deployment preflight's owned bytes. *)
val check_published_file : group:string -> name:string -> Yojson.Safe.t -> (unit, string) result
(** What a pass does with one file of a scope's resolution directory, for the
    deployment preflight: [group] is the directory's name, [name] the file's.
    A pass decodes every file there, whether or not its original still has a
    record. *)
val submit : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard -> actor:string ->
  reason:string -> now:float -> (t * bool, error) result
val submit_cut : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard ->
  basis:Keeper_librarian_history_resolution_state.cut_basis -> actor:string ->
  reason:string -> now:float -> (t * bool, error) result
(** Explicit same-binding Cut command. Requested grants no successor. The
    existing absence v2 encoding and identity remain unchanged. *)
(** The bool is true for an existing identical submission. This only persists
    the intent; no scheduling or Memory effect. Changed payloads refuse while
    active or fenced. A pre-fence refusal permits a new guard, preserving both.
    A post-fence refusal terminates only the continuation; its immutable fence
    remains and a changed submission for that original is still refused. *)
val read : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (t list, error) result
val active_for_keeper : config:Workspace.config -> keeper_name:string ->
  (t list, error) result
(** Strict complete scope inventory. Any unreadable intent prevents new work. *)
val reload : store:Lane_addon_store.t -> t -> (t, error) result
val refuse : store:Lane_addon_store.t -> expected:t -> refusal -> (t, error) result
(** Requested may be refused; Fenced may only be refused as No_longer_eligible
    before any child intent, after confirming the same durable fence. No fence,
    source cursor or Memory receipt is removed or acknowledged. *)
val confirm_fence : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_history_resolution_state.t -> (t, error) result
val confirm_cut_fence : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_history_resolution.cut_grant -> (t, error) result
(** Only the source/Memory/actual-claim callback can produce this grant.
    Strict Fenced publication and readback complete before that scope exits. *)
val require_successor_authority : t -> Keeper_librarian_history_resolution_state.t ->
  (unit, string) result
(** Contextual authority: absence retains its exact guard; Cut additionally
    needs the matching explicit command's durable Fenced-or-later phase.
    Neither a bare Cut fence nor Requested/Refused Cut grants a child. *)
val prepare_child : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_durable_request.t -> (t, error) result
(** Persist the complete canonical child and its identity in the resolution
    before writing its content-addressed body. A retry restores this exact
    preparation instead of rendering or minting another request. No child
    owner record, provider call, Memory publication or source ACK is allowed. *)
val intend_child : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_durable_request.t -> (t, error) result
(** Stage and strictly confirm the already prepared child's body, then compact
    the resolution to its ID and digest. A crash at either side of that write
    leaves the same complete preparation recoverable. *)
val confirm_child : store:Lane_addon_store.t -> expected:t ->
  Lane_addon_tool_request_owner.Record.t -> (t, error) result
val observe_memory_commit : store:Lane_addon_store.t -> expected:t ->
  request:Keeper_librarian_durable_request.t ->
  completed:Lane_addon_tool_request_owner.retained -> (t, error) result
(** Serialized Memory-lane use only. Confirm exact current committed range
    receipts under Memory locks without recovery, then retain that observation.
    A missing/pending/uncertain receipt does not establish completion.
    When [request] is a replacement that descends from the resolution child,
    the child is read as its record and index, not its body: the caller has
    confirmed [request]'s lineage, which restores that child. *)
val observe_program_commit : store:Lane_addon_store.t -> expected:t ->
  settled:Keeper_librarian_history_program_settlement.t -> (t, error) result
(** Consume an actual fully-read original program and exact post-ACK proof.
    Require this command's contextual durable fence and acknowledged child, verify
    every confirmed descendant link and owner/source basis, reobserve the
    opaque proof, then retain the full canonical program and receipts before
    step or rolling-receipt cleanup. No new Finished fact or ACK is created.
    Caller owns the serialized Memory lane/purge exclusion and holds no
    source or Memory locks. Existing receipt-only completions are unchanged. *)
val child : t -> child option
(** The child a [Child_intended] or [Child_confirmed] intent names by ID and
    digest. [Child_prepared] does not grant a child: its complete request stays
    in the preparation until the body it names is staged and strictly read
    back. The compact intent then keeps only the ID and digest. *)
