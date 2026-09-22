(** Keeper_model_input_demotion — replace aged tool-result bodies with their
    blob marker in the provider-bound copy (RFC-0363).

    A tool result is externalized at creation only when it exceeds
    [Tool_bridge.default_externalize_threshold_bytes] (65,536). Measured on a
    live checkpoint on 2026-08-05: of 5,540 inline tool messages holding 20.0MB
    — 71% of all message bytes — exactly one exceeded that threshold. The rest
    ride in history and are re-serialized into every later request.

    The caller selects the conversation range and verified completed boundary.
    Substitution reduces body bytes inside that range without adding or removing
    atoms. Small Keeper input policy uses this with Librarian continuity; spare
    capacity is not a reason to widen the conversation range.

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

type address_memo
(** The content addresses {!materialize} has already computed in one provider
    attempt, keyed by tool_use_id. *)

val create_address_memo : unit -> address_memo
(** One memo per provider attempt. The demotion boundary is pinned to the
    turn's seed, so every request of an attempt demotes the same aged results,
    and a durable tool result's body never changes under its id — the address
    is therefore the same every time. It is not safe to share across attempts
    of different keepers. *)

val materialize
  :  store:Tool_blob_store.t
  -> addresses:address_memo
  -> pending:pending list
  -> Agent_core.Types.message list
  -> materialize_outcome
(** Store the bodies of the demotions still present in [messages] and swap
    their placeholders for real markers. Demotions the cut removed are not
    stored.

    A body's address is computed once per attempt and reused by every later
    request in it ([addresses]); an address this call has not seen is computed
    through the process CPU pool ({!Tool_blob_store.address}). Only the writes
    run on the calling fiber.

    Both matter because the store skips writing an address this process already
    wrote, so on a long-lived keeper the sha256 over every aged body is the
    whole cost of this call. The attempt runs 62 to 83 provider requests and
    each one repeated it, and doing it on the calling fiber held the main Eio
    domain for one uninterrupted run of 0.7 to 1.6 seconds (rtev, 2026-09-16).

    A write failure restores that message's body instead of emitting a marker
    for bytes that were never persisted, and is counted in [reverted]; no write
    failure raises and none leaves a dangling reference. A cancelled fiber still
    propagates [Eio.Cancel.Cancelled], as the addressing awaits the pool.

    On blob lifetime: these blobs have no durable referrer, because the copy
    that carries the marker is never persisted. That is safe rather than
    overlooked. Offline {!Tool_blob_maintenance} runs only under the exclusive
    BasePath process lease, which the running server holds, and it chooses
    what to delete from candidate sets rather than file ages. The first put of
    an address in a server process writes it; later puts of that address skip
    the write (see {!Tool_blob_store.put}). A blob removed from outside the
    store is written again after a read of it fails, and a new process starts
    by writing every address it puts. The body is still verbatim in the
    checkpoint, so the blob is derived data that a later put restores. Nothing
    needs adding to [durable_consumer_basenames]: no reference is persisted. *)
