(** Completed dynamic-tool receipts that the ended vendor turn could not
    receive. The outbox is Keeper-owned, independent of vendor process and
    session identity. It does not authorize executing or replaying tools. *)

type snapshot

type receipt =
  { thread_id : string
  ; turn_id : string
  ; call_id : string
  ; tool_name : string
  ; arguments : Yojson.Safe.t
  ; response : Yojson.Safe.t
  }
(** Original producer coordinates and complete returned data. [thread_id] is
    the opaque vendor session identity in the existing durable receipt format;
    it does not authorize resuming that vendor session or executing a tool. *)

val retain :
  base_path:string -> keeper_name:string ->
  receipt -> (unit, string) result

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
  arguments:Yojson.Safe.t -> response:Yojson.Safe.t -> (host_delivery, string) result
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
  invocation_index:int -> call_id:string -> tool_name:string -> arguments:Yojson.Safe.t ->
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

val load : base_path:string -> keeper_name:string -> (snapshot, string) result
(** Read exact committed results, excluding host producers whose kernel lease
    is still held. Vendor receipts remain independent. An unavailable/missing
    host lease is a failure, never an inactive owner or permission to ACK.
    Loading is independent of the active producer's frozen delivery frontier. *)
val receipt_ids : snapshot -> string list
(** Exact SHA256 identities of the validated committed receipts. Staging files
    and provider execution cell numbers are not receipt identities. *)
val contains_receipt : snapshot -> receipt_id:string -> bool
val contains_call : snapshot -> call_id:string -> bool
(** Whether a retained receipt, vendor or host, carries this [call_id]. A
    producer that mints its own call ids uses it to see that the Keeper already
    holds a receipt for a call before it writes a second one. *)
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
