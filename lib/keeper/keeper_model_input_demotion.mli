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
    the unmodified history first chooses the authoritative window cut. {!plan}
    substitutes a saturating placeholder below the caller's age boundary (the
    keeper's assembly uses the current turn, see {!plan}), the window cuts
    again against the smaller messages, and {!materialize} stores only the
    messages that survived. The real marker is never larger than the
    placeholder, so a request that fit the plan still fits after
    materialization. *)

type pending
(** A demotion chosen by {!plan} and not yet stored. Keyed internally by
    [tool_use_id], which is stable across the cut. *)

type plan_result =
  { messages : Agent_core.Types.message list
        (** [messages] with each planned demotion replaced by a saturating
            placeholder marker. Physically the input list when nothing was
            planned. *)
  ; pending : pending list  (** Empty when nothing was planned. *)
  }

val plan
  :  measure_message_bytes:(Agent_core.Types.message -> int)
  -> demote_before:int
  -> Agent_core.Types.message list
  -> plan_result
(** Choose demotions and substitute upper-bound placeholders. Pure: no I/O or
    hashing. The byte budget stays in the cut; this function receives only the
    exact cut result so it cannot invent a second moving boundary.

    A tool result is demoted only when all of these hold:

    - it is a [ToolResult] whose [content_blocks] is [None]. When
      [content_blocks] is [Some], the provider encoder emits the blocks and
      never serializes [content], so replacing [content] would free nothing
      while this function credited a reduction — an under-estimate, the
      direction that lets a materialized request exceed the cap.
    - {!Tool_output.decode_from_agent_core} reports [Not_marker]. [Decoded] is already
      demoted; [Invalid_marker] is marker-shaped content that failed to parse
      and is left exactly as-is rather than being stored as a blob, which would
      make a corrupt payload content-addressed and permanent.
    - its atom index is below [demote_before], an atom index into this same
      unmodified message list. The caller owns where that boundary sits and
      owns the consequence: a boundary that moves on every message rewrites the
      transmitted prefix on every request and costs the provider's prompt
      cache, so callers pick one that moves at the rate the conversation
      itself does. The keeper's assembly uses the turn — results the current
      turn produced are what it is reasoning over, results from earlier turns
      were already reported elsewhere — which moves once per turn. One
      exception: when the raw cut refuses because the newest atom alone
      exceeds the budget, the assembly retries once with the boundary past
      the newest atom, so the turn's own results leave as markers rather than
      failing the turn (#28845).
    - the placeholder measures strictly smaller than the message does now.
      This replaces a size threshold: the encoded marker runs from about 125
      bytes to 1,154 depending on the preview's bytes, because
      {!Tool_output.encode_for_agent_core} escapes the preview and the JSON encoder
      escapes it again, so any fixed floor is wrong for one of the two ends.

    [measure_message_bytes] must be the encoder the window will use. The bound
    is obtained by measuring a real placeholder message through it rather than
    by restating the marker's format here. *)

type materialize_outcome =
  { messages : Agent_core.Types.message list
  ; reverted : int
        (** Planned demotions whose blob write failed and whose body was
            restored. Non-zero means the list is larger than the plan the cut
            was chosen against, so the caller must run the cut again. *)
  }

val materialize
  :  store:Tool_blob_store.t
  -> pending:pending list
  -> Agent_core.Types.message list
  -> materialize_outcome
(** Store the bodies of the demotions still present in [messages] and swap
    their placeholders for real markers. Demotions the cut removed are not
    stored.

    A write failure restores that message's body instead of emitting a marker
    for bytes that were never persisted, and is counted in [reverted]; it never
    raises and never leaves a dangling reference.

    On blob lifetime: these blobs have no durable referrer, because the copy
    that carries the marker is never persisted. That is safe rather than
    overlooked. Offline {!Tool_blob_maintenance} runs only under the exclusive
    BasePath process lease and deletes only hashes that were already candidates
    in a previous complete scan, while this function re-stores the same
    content-addressed bytes on every turn the demotion is transmitted. The body
    is still verbatim in the checkpoint, so the blob is derived data that the
    next turn restores. Nothing needs adding to [durable_consumer_basenames]: no
    reference is persisted. *)
