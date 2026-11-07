(** Keeper_model_input_demotion — replace aged tool-result bodies and verified
    completed arguments with blob references in the provider-bound copy (RFC-0363).

    A tool result is externalized at creation only when it exceeds the inline
    ceiling of the projection it crosses ({!Tool_output.inline_ceiling_bytes}):
    {!Common.max_tool_result_wire_bytes} by default, and the lane's own ceiling
    ({!Runtime_execution.tool_result_inline_ceiling_bytes}) where the lane
    widens it. Every result below that ceiling rides in history and is
    re-serialized into every later request.

    The caller selects the conversation range and verified completed boundary.
    Substitution reduces body bytes inside that range without adding or removing
    atoms. Every substitution rewrites a message a provider may already hold in
    its prompt cache, so the keeper's agent_core assembly asks for it in two
    places only: the results of turns that already ended, once each, on the
    first request after their turn ended (RFC-tool-results-age-out-of-context,
    an exception to RFC-0363 §3.4.1), and every result of the resend that
    answers a size refusal.

    Durable state is untouched. This runs on the provider-bound copy, like the
    window, so a blob written here has no durable referrer — see
    {!materialize} on why that is safe.

    {1 Two phases}

    A marker cannot be produced without hashing and storing the bytes, and the
    transmitted list is rebuilt from durable state every turn, so demoting
    everything eagerly would re-store thousands of blobs per turn. Instead
    the unmodified history first chooses the authoritative window cut. {!plan}
    substitutes a marker with the store's exact preview below the caller's boundary (the
    keeper's assembly uses the refused request's end, see {!plan}), the window cuts
    again against the smaller messages, and {!materialize} stores only the
    messages that survived. The real marker is never larger than the
    placeholder, so a request that fit the plan still fits after
    materialization. *)

type pending
(** A demotion chosen by {!plan}, retaining its exact original block and
    placeholder. Tool IDs can recur in distinct closed protocol cycles and
    do not identify a payload. *)

type completed_arguments
(** Frozen argument occurrences from cycles already closed in the raw seed,
    bound to the immutable blocks of one provider attempt's first request. *)

val prepend_argument_messages :
  prefix:Agent_core.Types.message list -> completed_arguments -> completed_arguments
(** Shift frozen message coordinates by a caller-owned prefix. This adds no
    eligible occurrence and keeps every immutable block guard. The caller must
    verify that these exact prefix messages were prepended; a pinned official
    context prefix must not change the completed atom boundary. *)

type argument_binding_error =
  | Invalid_argument_seed of Keeper_transcript_unit.structural_error
  | Argument_seed_prefix_mismatch of Keeper_replay_prefix.prefix_mismatch
  | Argument_replay_prefix_mismatch of Keeper_replay_prefix.restore_error
  | Argument_occurrence_mismatch

val protect_argument_prefix : through_message:int -> completed_arguments -> completed_arguments
(** Keep arguments after this original request message occurrence eligible.
    Earlier arguments stay verbatim when a signed reasoning replay depends on
    their exact prefix. This can only narrow an already frozen set. *)

val bind_completed_arguments :
  completed_before:int ->
  seed:Agent_core.Types.message list ->
  replay_prefix:Keeper_replay_prefix.projection ->
  Agent_core.Types.message list ->
  (completed_arguments, argument_binding_error) result
(** Call once, before projecting the attempt's first request. [seed] must be
    the raw history before this turn's Gate or provider-transcript admission;
    a native continuation uses its retained initial seed, not its latest
    checkpoint. Later synthesized or journal-replayed results cannot enlarge
    this set. Only the seed's structurally closed prefix below the verified
    completed-turn [completed_before] atom boundary is eligible.

    The closed prefix must match the request's canonical replay view exactly.
    A typed media projection may change other blocks; within each corresponding
    message the complete ordered ToolUse sequence must still match exactly.
    The returned set binds the actual dispatch blocks and positions, so native
    deserialization and media projection do not depend on raw-seed pointer
    identity. A later request may append history, but replacing a bound block
    makes that occurrence ineligible. Failure disables argument demotion only;
    it is not authority to repair, trim or reject the conversation. *)

type plan_result =
  { messages : Agent_core.Types.message list
        (** [messages] with each planned demotion replaced by a saturating
            placeholder marker. Physically the input list when nothing was
            planned. *)
  ; pending : pending list  (** Empty when nothing was planned. *)
  }

val plan
  :  ?completed_arguments:completed_arguments
  -> ?min_result_bytes:int
  -> measure_message_bytes:(Agent_core.Types.message -> int)
  -> measure_wire_bytes:(Agent_core.Types.message -> int option)
  -> demote_before:int
  -> Agent_core.Types.message list
  -> plan_result
(** Choose demotions and substitute upper-bound placeholders. Pure: no I/O or
    hashing. The byte budget stays in the cut; this function receives only the
    exact cut result so it cannot invent a second moving boundary.

    A tool result is demoted only when all of these hold:

    - it is a text body of a [ToolResult]: its [content], and each [Text]
      block of one whose [content_blocks] is [Some]. Image, document and
      audio blocks keep their place; they have no marker form (RFC-0363
      §3.1.2). The floor below is checked for the whole result; the other
      conditions for each body.
    - {!Tool_output.decode_from_agent_core} reports [Not_marker]. [Decoded] is already
      demoted; [Invalid_marker] is marker-shaped content that failed to parse
      and is left exactly as-is rather than being stored as a blob, which would
      make a corrupt payload content-addressed and permanent.
    - its atom index is below [demote_before], an atom index into this same
      unmodified message list. The caller owns where that boundary sits and
      owns the consequence: a boundary that moves while the range's front stays
      rewrites a message the provider already holds and costs its prompt cache
      from that message on. A boundary at the current turn moves once per turn,
      so each result changes once, on the first request after its turn ended,
      and costs the cache from that message on. The keeper's agent_core
      assembly passes the turn boundary for a Keeper that can read markers
      back, and the refused request's atom count for the
      one resend that answers a size refusal, so every result in the refused
      request leaves as a marker rather than failing the turn (#28845).
    - its result carries at least [min_result_bytes] bytes of text on one
      lane: [content], or with [Some] the longer of [content] and the sum of
      its [Text] blocks. The floor checks the whole result, not each body.
      It is 0 when the argument is omitted, so a result is demoted whenever
      the next bullets allow it. It applies to results only;
      [completed_arguments] are chosen by their own eligibility.
    - [measure_wire_bytes] of the result alone in its message is strictly
      smaller with the placeholder in that body than without it, each body
      measured on top of the bodies already chosen. Providers send different
      bodies of one result, and OpenAI chat, Responses, GLM and Ollama escape
      the blocks twice, so this is a question for the lane's own encoder
      ({!Keeper_model_input_wire_bytes.measurer}): a body the lane does not
      send leaves the measure equal, and a short body can grow into a longer
      marker once escaped twice. [None] keeps the body. Applies to results
      only.
    - the placeholder message measures strictly smaller under
      [measure_message_bytes] than the message does now, so the window's
      count of it never grows. The encoded marker runs from about 125 bytes
      to 1,154 under one JSON escape and to about 1,530 under two, depending
      on the preview's bytes, because {!Tool_output.encode_for_agent_core}
      escapes the preview with [%S] before any JSON encoder escapes it again;
      a fixed floor cannot stand in for either. [min_result_bytes] is a floor
      on what the caller wants to trade for a marker, checked in addition to
      these rules.

    [measure_message_bytes] must be the encoder the window will use. The bound
    is obtained by measuring a real placeholder message through it rather than
    by restating the marker's format here.

    When [completed_arguments] is supplied, eligible ToolUse inputs are replaced
    with the existing normalized [_blob] JSON reference, preserving ID, name
    and every other block. Original arguments are stored as [application/json]
    bytes using [Yojson.Safe.to_string]. Existing or invalid normalized
    references are left verbatim. Argument eligibility is independent of the
    ToolResult [demote_before] range. The same per-message encoded-size
    comparison and two-phase materialization apply. Omitting the frozen set
    preserves all arguments. *)

type materialize_outcome =
  { messages : Agent_core.Types.message list
  ; reverted : int
        (** Planned demotions whose blob write failed, so the body stayed in
            its slot. Non-zero means the list is larger than the plan
            measured. The range is a position, not a size, so the same atoms
            go out and the caller reports the failure. *)
  }

type materialized_replay

val capture_materialized :
  pending:pending list -> before:Agent_core.Types.message list ->
  after:Agent_core.Types.message list -> materialized_replay option
(** Capture the actual retained slot replacements, including failed writes
    that kept their original bodies. [None] rejects a changed message/block shape
    or changes outside planned placeholders. Pure; no store retry. *)

val replay_materialized :
  materialized_replay option -> pending:pending list ->
  Agent_core.Types.message list -> Agent_core.Types.message list
(** Apply exactly the captured outcomes to another plan over the same source
    occurrences, guarded by immutable original identity. Missing entries or
    [None] restore original blocks. This lets reasoning comparisons vary only
    arguments, without retrying a failed Result write inside the comparison. *)

type address_memo
(** The content addresses {!materialize} has already computed in one provider
    attempt, keyed by original message/block position and guarded by physical
    identity of the immutable original block. *)

val create_address_memo : unit -> address_memo
(** One memo per provider attempt and blob store. Repeated requests reuse the
    address only for the same original block at the same position. A changed
    history or reused tool ID cannot reuse another payload's address. *)

val materialize
  :  store:Tool_blob_store.t
  -> addresses:address_memo
  -> pending:pending list
  -> Agent_core.Types.message list
  -> materialize_outcome
(** Store the bodies of the demotions still present in [messages] and swap
    their placeholders for real markers. Demotions the cut removed are not
    stored. Between {!plan} and this call, the projection must retain the
    physical identity of surviving content blocks. It may remove messages or
    add unrelated blocks, but must not clone planned placeholders. Existing
    markers are never matched by their text or tool ID alone.

    A body's address is computed once per attempt and reused by every later
    request in it ([addresses]); an address this call has not seen is computed
    through the process CPU pool ({!Tool_blob_store.address}). Only the writes
    run on the calling fiber.

    Both matter because the store skips writing an address this process already
    wrote, so on a long-lived keeper the sha256 over every aged body is the
    whole cost of this call. The attempt runs 62 to 83 provider requests and
    each one repeated it, and doing it on the calling fiber held the main Eio
    domain for one uninterrupted run of 0.7 to 1.6 seconds (rtev, 2026-09-16).

    A planned block is built again from its original, with a real marker in
    each body whose bytes were written. A body whose write failed keeps its
    original text instead of a marker for bytes that were never persisted,
    and is counted in [reverted]; the result's other bodies keep the markers
    that were written. No write failure raises and none leaves a dangling
    reference. A planned body its original block no longer has raises
    [Invalid_argument]: [plan] read every body from that block. A cancelled fiber still
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
    needs adding to the sweep's scope: no reference is persisted. *)
