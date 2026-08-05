(** Keeper_model_input_demotion — replace aged tool-result bodies with their
    blob marker in the provider-bound copy (RFC-0363).

    A tool result is externalized at creation only when it exceeds
    [Tool_bridge.default_externalize_threshold_bytes] (65,536). Measured on a
    live checkpoint on 2026-08-05: of 5,540 inline tool messages holding 20.0MB
    — 71% of all message bytes — exactly one exceeded that threshold. The rest
    ride in history and are re-serialized into every later request.

    {!Runtime_model_input_tail_window} already fits each request to the
    target's capacity, so this does not shrink requests; it buys atoms. Only
    1.9-4.7% of that history is transmitted, and old tool output consumes most
    of it. Replacing a median 2,862-byte body with its marker raises how much
    conversation fits the same budget.

    Durable state is untouched. This runs on the provider-bound copy, like the
    window, so a blob written here has no durable referrer — see
    {!materialize} on why that is safe.

    {1 Two phases}

    A marker cannot be produced without hashing and storing the bytes, and the
    transmitted list is rebuilt from durable state every turn, so demoting
    everything eagerly would re-store thousands of blobs per turn. Instead
    {!plan} substitutes a saturating placeholder whose serialized size is an
    upper bound on the real marker, the window cuts against that, and
    {!materialize} stores only the messages that survived the cut. The real
    marker is never larger than the placeholder, so a request that fit the
    plan still fits after materialization. *)

val retain_atoms : int
(** How many of the newest atoms keep their tool-result bodies verbatim.

    A recency window, not an importance judgement: RFC-0351 §3 admits it on
    the grounds that a keeper is a single timeline, so recency is the
    timeline's own structure. The boundary moves one atom per turn at the
    {e tail} of the transmitted list while the cut moves at its {e head}, so
    the two never fight over the same bytes and the stable prefix a prompt
    cache matches only grows.

    Initial value is empirical and unvalidated — RFC-0363 §6 is the measurement
    that fixes it. *)

type pending
(** A demotion chosen by {!plan} and not yet stored. Keyed internally by
    [tool_use_id], which is stable across the cut. *)

type plan_result =
  { messages : Agent_sdk.Types.message list
        (** [messages] with each planned demotion replaced by a saturating
            placeholder marker. Physically the input list when nothing was
            planned. *)
  ; pending : pending list  (** Empty when nothing was planned. *)
  }

val plan
  :  measure_message_bytes:(Agent_sdk.Types.message -> int)
  -> Agent_sdk.Types.message list
  -> plan_result
(** Choose demotions and substitute upper-bound placeholders. Pure: no I/O, no
    hashing, and no dependence on the byte budget — the budget belongs to the
    cut, and giving both stages the same trigger is what keeps the demotion
    boundary off the head of the list.

    A tool result is demoted only when all of these hold:

    - it is a [ToolResult] whose [content_blocks] is [None]. When
      [content_blocks] is [Some], the provider encoder emits the blocks and
      never serializes [content], so replacing [content] would free nothing
      while this function credited a reduction — an under-estimate, the
      direction that lets a materialized request exceed the cap.
    - {!Tool_output.decode_from_oas} reports [Not_marker]. [Decoded] is already
      demoted; [Invalid_marker] is marker-shaped content that failed to parse
      and is left exactly as-is rather than being stored as a blob, which would
      make a corrupt payload content-addressed and permanent.
    - its atom index is older than the newest {!retain_atoms} atoms.
    - the placeholder measures strictly smaller than the message does now.
      This replaces a size threshold: the encoded marker runs from about 125
      bytes to 1,154 depending on the preview's bytes, because
      {!Tool_output.encode_for_oas} escapes the preview and the JSON encoder
      escapes it again, so any fixed floor is wrong for one of the two ends.

    [measure_message_bytes] must be the encoder the window will use. The bound
    is obtained by measuring a real placeholder message through it rather than
    by restating the marker's format here. *)

type materialize_outcome =
  { messages : Agent_sdk.Types.message list
  ; reverted : int
        (** Planned demotions whose blob write failed and whose body was
            restored. Non-zero means the list is larger than the plan the cut
            was chosen against, so the caller must run the cut again. *)
  }

val materialize
  :  store:Tool_blob_store.t
  -> pending:pending list
  -> Agent_sdk.Types.message list
  -> materialize_outcome
(** Store the bodies of the demotions still present in [messages] and swap
    their placeholders for real markers. Demotions the cut removed are not
    stored.

    A write failure restores that message's body instead of emitting a marker
    for bytes that were never persisted, and is counted in [reverted]; it never
    raises and never leaves a dangling reference.

    On blob lifetime: these blobs have no durable referrer, because the copy
    that carries the marker is never persisted. That is safe rather than
    overlooked. {!Tool_blob_maintenance} deletes only at the quiescent startup
    boundary and only hashes that were already candidates in a previous
    complete scan, while this function re-stores the same content-addressed
    bytes on every turn the demotion is transmitted. The body is still verbatim
    in the checkpoint, so the blob is derived data that the next turn restores.
    Nothing needs adding to [durable_consumer_basenames]: no reference is
    persisted. *)
