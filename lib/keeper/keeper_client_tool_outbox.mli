(** Completed dynamic-tool receipts that the ended vendor turn could not
    receive. The outbox is Keeper-owned, independent of vendor process and
    session identity. It does not authorize executing or replaying tools. *)

type snapshot

(** The arguments of the call a receipt answers. [Unknown] is a receipt for a
    call whose arguments were not recorded; no value stands in for them. *)
type arguments = Keeper_client_tool_outbox_codec.arguments =
  | Known of Yojson.Safe.t
  | Unknown

type receipt = Keeper_client_tool_outbox_codec.receipt =
  { thread_id : string
  ; turn_id : string
  ; call_id : string
  ; tool_name : string
  ; arguments : arguments
  ; response : Yojson.Safe.t
  }
(** Original producer coordinates and complete returned data. [thread_id] is
    the opaque vendor session identity in the existing durable receipt format;
    it does not authorize resuming that vendor session or executing a tool. *)

val retain :
  base_path:string -> keeper_name:string ->
  receipt -> (unit, string) result

(** Whose receipts a read may carry. A background-run request whose receipt an
    unsettled chat execution waits for is owned by that execution
    ({!Keeper_semantic_execution.receipt_obligation}), and no other run may
    read it: a run that completes acknowledges exactly the receipts it read,
    so another run's read would delete the receipt the owner waits for. *)
type viewer =
  | Unowned_only
      (** Receipts no execution owns. A run that serves no chat execution, and
          a stimulus that points at a receipt. *)
  | Owner_and_unowned of Keeper_execution_scope_id.t
      (** The receipts that execution owns, and the unowned ones. *)
  | Every_receipt
      (** All of them. Only a read that neither carries a receipt to a model
          nor acknowledges one may use it. *)

val receipt_visible : viewer -> owner:Keeper_execution_scope_id.t option -> bool
(** Whether [viewer] may read a receipt whose request [owner] owns; [None] is a
    request no execution owns. *)

type host_producer
val host_producer :
  base_path:string -> keeper_name:string -> runtime_label:string -> turn_count:int ->
  (host_producer, string) result
(** One host-owned dynamic-tool projection with fixed workspace/Keeper
    authority, a fresh source identity and an existing private lease inode.
    This standalone producer is inactive; real runtime projections use
    [start_host_producer].
    Its label and claim ordinal describe the host; neither impersonates vendor
    session/turn coordinates or authorizes tool replay. *)

val start_host_producer :
  sw:Eio.Switch.t -> base_path:string -> keeper_name:string ->
  runtime_label:string -> turn_count:int -> (host_producer, string) result
(** Bind this producer to its real runtime switch. An existing private lease
    inode stays held through child/worker drain and is closed by the switch
    release hook.
    [load] skips its results while that exact kernel lease is held, including
    from another process. Crash/exit releases the lease without PID guessing,
    TTL or replay. Lease files are retained stable and never enumerated as
    results. Prevalidation must not start a producer. *)

type host_delivery
val retain_host_result_with_delivery :
  host_producer -> invocation_index:int -> call_id:string -> tool_name:string ->
  arguments:arguments -> response:Yojson.Safe.t -> (host_delivery, string) result
(** An opaque token for this exact durably retained physical result. *)
val mark_response_sent : host_delivery -> unit
(** Pure per-producer state update, after complete original response write.
    A closed completion frontier excludes late marks. This never ACKs data. *)
val close_delivery_frontier : host_producer -> snapshot
(** Freeze exactly the writes observed before the client's terminal boundary.
    Idempotent: late writes cannot enter a previously frozen snapshot. Only a
    natural, accepted Completed turn with durable settlement can ACK it. *)

val retain_confirmed_calls : snapshot -> call_ids:string list -> snapshot
(** Restrict a frozen host snapshot to the call IDs independently confirmed by
    the same provider turn. This does not ACK or alter retained results. The
    caller must establish that each ID uniquely identifies a physical call in
    that producer's turn. *)

val retain_host_result :
  host_producer ->
  invocation_index:int -> call_id:string -> tool_name:string -> arguments:arguments ->
  response:Yojson.Safe.t -> (unit, string) result
(** Retain original returned data before a host stop can discard the provider
    invocation. Host and vendor receipts have distinct, strict source shapes
    and share exact snapshot consumption and ACK. [invocation_index] is the
    nonnegative physical invocation index assigned by this host projection;
    a client may reuse [call_id] for a later physical invocation. *)

val host_response :
  host_producer -> min_result_bytes:int -> success:bool -> content:string ->
  content_blocks:Llm_provider.Types.content_block list option ->
  (Yojson.Safe.t, string) result
(** The [response] of one host receipt: [success], [content] and
    [content_blocks].

    {!context_message} puts every retained receipt into one text message, and
    each later request of the Keeper carries it until a completed turn
    acknowledges it. No window cuts that message, so the receipt names large
    bytes by blob address instead of holding them.

    - An image, document or audio block with a [Base64] source becomes
      [{"type":_,"media_type":_,"artifact":_}]: the decoded bytes, under
      {!Tool_output.normalized_artifact_ref_to_json}. A base64 payload inside
      text reaches the model as text, not as media. A payload that does not
      decode keeps its exact string under [undecodable_base64], with the
      decoder's [detail]. [Url] and [File_id] sources keep the provider
      shape.
    - When the result carries at least [min_result_bytes] bytes of text, the
      longer of [content] and the sum of its [Text] blocks, each text body
      that is shorter as its blob marker becomes that marker. A marker already
      in the result stays as it is. This holds for a Keeper without the
      artifact reader too: it sees the marker's preview, where the whole
      bodies would keep growing a message nothing bounds.

    Each blob is written with {!Tool_blob_store.put_durable_reuse}, because
    the receipt outlives the process and names the bytes. Blob maintenance
    keeps them live through these reserved reference forms, which it reads
    inside receipt payloads too. A failed blob write returns [Error], and
    nothing is written to the outbox. *)

val load : base_path:string -> keeper_name:string -> viewer:viewer -> (snapshot, string) result
(** Read exact committed results, excluding host producers whose kernel lease
    is still held. Vendor receipts remain independent. An unavailable/missing
    host lease is a failure, never an inactive owner or permission to ACK.
    Loading is independent of the active producer's frozen delivery frontier.

    Receipts [viewer] may not read are left out of the snapshot, so
    {!acknowledge} never removes them. Reading the owners needs the Keeper's
    chat operation journal when the outbox holds a receipt and [viewer] is not
    [Every_receipt]; a journal that cannot be read is an [Error], not an empty
    owner set. *)
val inspect_committed :
  base_path:string -> keeper_name:string ->
  ((string * (unit, string) result) list, string) result
(** Each committed receipt file of the Keeper's outbox, in the order {!load}
    reads them, with what the read and validation {!load} applies to that file
    say of it. {!load} stops at the first [Error]; this reads every file, so a
    check before a start can count them. It takes no producer lease, reads no
    receipt owner, and creates, writes and removes nothing. The outer [Error]
    is an outbox that cannot be listed; a missing outbox is [Ok []]. *)

val receipt_ids : snapshot -> string list
(** Exact SHA256 identities of the validated committed receipts. Staging files
    and provider execution cell numbers are not receipt identities. *)
val contains_receipt : snapshot -> receipt_id:string -> bool
val contains_call : snapshot -> call_id:string -> bool
(** Whether a retained receipt, vendor or host, carries this [call_id]. A
    producer that mints its own call ids uses it to see that the Keeper already
    holds a receipt for a call before it writes a second one. *)

(** What a line that points at a receipt says about it. A module of its own so
    its labels do not shadow those of {!receipt}. *)
module Summary : sig
  type t =
    { call_id : string
    ; tool_name : string
    ; outcome : string option
      (** [response.outcome] when the response is an object holding a string
          under that key. A background run's receipt carries [completed],
          [deferred], [failed] or [unfinished]; a vendor turn's receipt has
          none. *)
    }
end

val receipt_summary : snapshot -> receipt_id:string -> Summary.t option
(** What one loaded receipt says about itself, for a line that points at it.
    [None] when the snapshot holds no receipt with this identity. It reads the
    loaded snapshot only: nothing is read from disk and nothing is
    acknowledged. *)

val summary_reader :
  base_path:string ->
  keeper_name:string ->
  viewer:viewer ->
  on_unavailable:(string -> unit) ->
  string ->
  Summary.t option
(** [summary_reader ~base_path ~keeper_name ~viewer ~on_unavailable] is a lookup from a
    receipt identity to its {!Summary.t}. It loads the outbox at the
    first lookup and answers every later lookup from that load, so a round that
    points at no receipt reads nothing. An outbox that cannot be loaded calls
    [on_unavailable] with the reason once and answers [None]. A reader belongs
    to one round: it never sees a receipt written after its load, and two
    fibers must not force the first lookup together, so each round makes its
    own. *)

val developer_context : snapshot -> string list
(** The retained receipts as model-facing text, in snapshot order. Base64
    media in a response is shown by its identity
    ({!Keeper_client_tool_outbox_media.carrier_row}); every other receipt value
    is carried losslessly. *)

val context_message : snapshot -> Agent_core.Types.message option
(** A separately identified result-data carrier for official Start and Resume
    and Agent Core's final model-input projection.
    It cannot collide with the ordinary composed-context or Librarian carrier. *)
val is_context_message : Agent_core.Types.message -> bool

(** [place_carrier carrier messages] removes any result-data carrier from
    [messages] and puts [carrier] right after the latest caller query (the
    last [User] row of [Conversation] origin), or first when there is none.
    Every round of a turn reproduces that position, so signed reasoning bound
    to an earlier round's request still replays, and on a turn-scoped lane
    the context rows that close the request stay last. Used for the request
    and for the input record of the same request. *)
val place_carrier :
  'source Llm_provider.Types.message_with ->
  'source Llm_provider.Types.message_with list ->
  'source Llm_provider.Types.message_with list

(** {1 The carrier of one run}

    RFC retained-results-carrier-shrinks-to-an-address. Every retained receipt
    rides on every request until a completed turn acknowledges it, and no
    window cuts the carrier: 248 receipts made one larger than the model
    window (#49634). When a provider refuses a run's request for its size, the
    run can carry the same text behind one blob address instead. *)

type form =
  | Inline  (** The {!developer_context} text. *)
  | By_address
      (** The receipt count, the receipts per tool and the marker of one
          [text/plain] blob holding the [Inline] text, with how to read it.
          Its length depends only on the tool names, the digits of those
          numbers and of the blob's byte count, and whether the run offers a
          reader. *)

type carrier
(** The carrier of one run: every provider attempt of one runtime call to one
    candidate. A new run starts a new carrier. *)

val carrier :
  base_path:string -> artifact_reader_available:bool -> snapshot -> carrier
(** Start a run's carrier of [snapshot] in the [Inline] form. Reads and writes
    no file. [artifact_reader_available] says whether the run's requests offer
    keeper_artifact_read: the [By_address] text then says how to read the blob,
    and otherwise that the request cannot read it. *)

val carrier_form : carrier -> form

val carrier_context : carrier -> string list
(** The carrier text in its current form. Reads and writes no file. *)

val carrier_message : carrier -> Agent_core.Types.message option
(** {!context_message} of the current form. *)

val carrier_reprojection :
  carrier ->
  then_:Keeper_memory_delivery_reprojection.t ->
  Keeper_memory_delivery_reprojection.t
(** The capacity-refusal hook of a run, with the carrier step before [then_].

    The carrier step switches an [Inline] carrier that holds receipts to
    [By_address] when that text is strictly shorter. It measures with a
    planned marker, without hashing or file I/O, so a form that is not shorter
    writes nothing. Before switching it writes the blob with
    {!Tool_blob_store.put_durable_reuse}; a failed write returns [Error] and
    the form stays [Inline]. A switch returns [Reprojected], and the caller
    sends again at the same capacity.

    Otherwise the carrier step is [Unchanged] and [then_] decides, so a carrier
    switches at most once and never back. [Error] from the carrier step does
    not call [then_]. The blob is named by no durable store, so offline blob
    maintenance may delete it after the run; the next run that switches writes
    it again at the same address. *)

type run_carrier
(** The retained results of one run. A runtime makes it once per run, before
    the run's first attempt. *)

val run_carrier :
  base_path:string -> keeper_name:string -> artifact_reader_available:bool ->
  viewer:viewer -> run_carrier
(** Reads and writes no file. [artifact_reader_available] is as for {!carrier}.
    [viewer] is the run's, for its one load: a run serving a chat execution
    passes [Owner_and_unowned] with that execution's scope. *)

val run_carrier_load : run_carrier -> (snapshot * carrier, string) result
(** The first successful call loads the outbox and starts its carrier. Every
    later call returns that same snapshot and carrier, so a form the hook
    switched stays switched for the rest of the run and the run acknowledges
    exactly the snapshot it carried. A failed load is returned and not kept.
    A run's attempts call it one after another. *)

val run_carrier_reprojection :
  run_carrier ->
  then_:Keeper_memory_delivery_reprojection.t ->
  Keeper_memory_delivery_reprojection.t
(** {!carrier_reprojection} of the loaded carrier; before the first load, [then_]
    alone. *)

val acknowledge : snapshot -> (unit, string) result
(** Remove only the exact loaded receipts after the consumer completes.
    Newer receipts remain pending. Runtime callers use [settle_after_turn] so
    a successful checkpoint cannot acknowledge unfinished consumption. *)

val settle_after_turn :
  snapshot -> stop_reason:Runtime_agent_context.stop_reason -> (unit, string) result
(** Only [Completed] acknowledges the loaded receipts. Every checkpoint,
    scheduling handoff and input wait preserves their original content across
    vendor session replacement. Provider failures never call this function. *)

type consumption
val pending_consumption : snapshot list -> consumption
(** Immutable exact receipt snapshots, returned without acknowledgement by a
    settled adapter. Producing this token does not accept a model response. *)
val settle_consumption :
  consumption -> stop_reason:Runtime_agent_context.stop_reason -> (unit, string) result
(** The caller invokes this only after its actual response acceptance succeeds,
    using the accepted result's final stop reason. Non-completion preserves all
    receipts; failures are returned without executing any tool again. *)
