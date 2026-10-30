(** Original host-owned explicit-candidate execution. No provider, worker,
    Memory mutation, queue ACK or execution grant is created by these ports. *)
type owner
val observe_owner : base_path:string -> keepers_dir:string -> keeper_id:string ->
  (owner, string) result
(** Blocking descriptor-bound workspace and actual flat-file keepers_dir observation.
    Missing/replaced/symlinked roots, missing queue generation or missing Memory
    epoch refuse. Queue generation is retained even if its pending rows are empty.
    The new-root owner first uses Current.capture_program_anchor to establish
    the original epoch. That initialization grants no provider or consumption
    authority. Caller holds the Memory-lane purge fence and offloads this
    complete observation in Eio contexts. *)
type scope_identity
val scope_identity : owner -> scope_identity
val scope_hash : scope_identity -> string
(** Address-only identity from physical workspace/keepers roots, canonical Keeper
    and the existing Queue generation. Epoch is deliberately excluded so its
    loss/replacement cannot hide original records in a new Store scope. This
    opaque identity grants no authority; restore always compares the full owner,
    including the original epoch and generation, before any effect. *)
val owner_to_json : owner -> Yojson.Safe.t
val owner_of_json : Yojson.Safe.t -> (owner, string) result
(** Decode captured physical identity only. This pure operation neither
    observes today's roots/epoch nor establishes execution authority. *)
val owner_matches_json : owner -> Yojson.Safe.t -> (unit, string) result
val observe_record_owner : base_path:string -> keepers_dir:string ->
  Lane_addon_tool_request_owner.retained -> (owner, string) result
(** For an original request found by its scope-bound execution ID: strictly decode
    its captured Keeper identity, observe the actual configured roots/epoch,
    and require exact original ownership. This grants no capture/parent or
    destination authority; full [restore] must follow. *)
val keeper_id : owner -> string
val base_path : owner -> string
val keepers_dir : owner -> string

type destination = {
  installation_id : string;
  package_id : string;
  tool : string;
  source_revision : string;
  configuration_revision : string;
}
type t
val scope : owner -> string
val fresh_request_id : owner -> string
val scope_of_request_id : string -> (string, string) result
(** Host-minted canonical tagged JSON binds the original physical Keeper and
    Queue-generation scope hash and UUIDv7. Parsing only computes a Store
    lookup scope; original
    capture/physical equality must still be checked before any effect. *)
val package_id : string
val tool : string
val create : request_id:string -> parent_part_id:string -> owner:owner ->
  destination:destination -> batch:Keeper_memory_admission_queue.batch ->
  input:Keeper_librarian.input -> expected_revision:int option -> now:float ->
  retirement:Keeper_memory_admission_judgment.retirement_evidence ->
  preparation:Keeper_librarian_runtime.admission_preparation -> (t, string) result
(** Original input and complete prompt preparation, including both managed
    admission and retirement policies, are checked together.
    This purpose requires the actual pending-candidate input: no conversation,
    historical spans, tools, counterparts or working-context sources. Those
    fields are retained explicitly and nonempty values refuse; another pass's
    evidence is never discarded. The parsing time is immutable. Parent-part authority is separately checked by
    the owner's typed loader before creation and during restoration. *)
val to_json : t -> Yojson.Safe.t
val restore : owner:owner ->
  load_parent:(request_id:string ->
    (Keeper_memory_admission_queue.batch, string) result) ->
  Lane_addon_tool_request_owner.retained -> (t, string) result
(** The supplied parent loader must strictly restore the original physical
    candidate part and its acknowledged partition ancestry, never today's
    queue. Its complete batch must equal this execution's original batch.
    This read does not establish live destination or Memory commit authority. *)
val request_id : t -> string
val parent_part_id : t -> string
val destination : t -> destination
val batch : t -> Keeper_memory_admission_queue.batch
val input : t -> Keeper_librarian.input
val expected_revision : t -> int option
val now : t -> float
val request : t -> (Lane_addon_exact.request, string) result
val confirm_final : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (unit, string) result
(** Blocking read-only original host proof confirmation. Reobserve the physical
    owner, derive the original request/schema/declaration, and require an exact
    actual retained host terminal. Every Call_final additionally requires the
    actual latest completed original execution proof and matching full outcome;
    missing/open history and a different final refuse. Host Outcome_unknown,
    Not_allowed and Request_id_reused remain their original uncertainty/refusal
    and never borrow a call proof or authorize replay. No worker JSON, domain
    answer or host progress record alone supplies this evidence, except for a
    final where {!Lane_addon_exact.refused_before_host} holds: the host never
    retained that request, so an absent host record confirms it and no proof is
    read. Offload the complete operation in an Eio caller; no provider, write
    or ACK occurs. *)
val validate_proposal : t -> Yojson.Safe.t ->
  (Keeper_librarian_runtime.admission_proposal, string) result
(** Full original admission validation, including every candidate, exact
    support, original surrogate identities and stable parsing time. Deferred
    is distinct from an accepted proposal; neither is a Memory disposition. *)
