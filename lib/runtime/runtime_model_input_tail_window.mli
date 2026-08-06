(** Runtime_model_input_tail_window — bounded transmission view over
    provider-bound conversation history (RFC-0351 §3 L5, #26534 PR-C, #26544,
    #26551).

    [project] keeps only the most recent atoms of the message list that OAS
    is about to send to a provider. One atom is either an organic [User]
    message or an [Assistant] message together with the [Tool] messages that
    answer it, so a cut can never separate a tool result from the tool call
    that produced it. Durable agent state and checkpoints are untouched: OAS
    applies a [model_input_projection] to the provider-bound copy only
    ({!Runtime_agent_context.config.model_input_projection}).

    The cut is chosen by measured bytes against the target's declared request
    capacity, not by atom count. An atom count cannot bound a request because
    atom weight is not uniform: live checkpoints on 2026-08-04 measured 0.3KB
    to 8.7KB per atom across the fleet, so a window sized for the light end
    transmits an over-capacity request at the heavy end (#26551).

    Cut placement is quantized to whole windows where the budget allows: the
    smallest multiple of {!atoms_per_window} whose remaining history fits is
    used, so the transmitted prefix stays byte-identical while the
    conversation grows inside one window, which preserves provider
    prompt-cache reuse between jumps (#26535 measured the alternative: a
    per-turn sliding cut changes the prefix on every request). When no
    quantized cut fits, an exact cut is used instead — correctness outranks
    cache reuse.

    Two properties of that quantization are worth stating because they are
    costs, not guarantees. History growth moves the cut in one direction
    only, but the budget also depends on inputs that shrink: pinned context
    is re-assembled each turn, so a smaller pinned block can move the cut
    back and change the prefix once. The cost of that is a cache miss, never
    a refusal. And because a window is a fixed atom count against a byte
    budget, a jump can free far more room than it needed — a keeper whose
    atoms are heavy transmits well under its budget right after a jump and
    refills toward it, the same sawtooth an atom-count window had, now
    bounded in the unit the target actually refuses on.

    Messages carrying OAS extra-system-context provenance are never counted
    as atoms and never dropped; that block is re-assembled fresh each turn by
    the keeper hooks and must survive the cut. When the cut leaves a
    non-[User] message at the head of the transmitted history, a constant
    synthetic [User] preamble is prepended so providers that require a
    [User]-first conversation accept the request; being constant, it does not
    perturb the quantized prefix. Both are charged against the budget before
    any atom is considered, because no cut can remove them. *)

val atoms_per_window : int
(** Window quantum for cut placement. This bounds how often the transmitted
    prefix changes; it does not bound the request size — {!project} does that
    from measured bytes. *)

val preamble_marker_key : string
(** Metadata key tagging the synthetic preamble message, so a captured
    request distinguishes the marker from organic history. The preamble
    exists only in the transmitted copy; nothing writes it to durable
    state. *)

type label =
  | Pinned
      (** Survives every cut: [System] entries and messages carrying
          extra-system-context provenance, both re-assembled fresh each turn. *)
  | Atom of int  (** Zero-based index of the atom this message belongs to. *)

val annotate
  :  Agent_sdk.Types.message list
  -> (Agent_sdk.Types.message * label) list * int
(** Label every message with its atom index, in order, and return the atom
    count. [User] and [Assistant] open a new atom; [Tool] joins the atom of the
    assistant that issued the call, so both sides of a tool exchange always
    share one label.

    Exported because the atom is now a shared unit of the projection pipeline
    rather than a private detail of the cut: a stage that runs before
    {!project} and needs to reason about age must use the same labelling, and
    a second implementation of it would let the two stages disagree about
    where an atom begins. *)

type budget_error =
  | Reservation_exceeds_capacity of
      { capacity_bytes : int
      ; reserved_bytes : int
      ; undroppable_bytes : int
      }
      (** The caller's reservation plus the messages no cut can remove
          already fill the target's capacity, so no history can be
          transmitted. Dropping atoms cannot resolve this, which is why it is
          refused rather than cut further. *)
  | Newest_atom_exceeds_available of
      { available_bytes : int
      ; newest_atom_bytes : int
      }
      (** A single atom is larger than the whole history budget. Splitting it
          would separate a tool result from its call, so the request is
          refused instead. *)

type projection =
  { messages : Agent_sdk.Types.message list
  ; dropped_atoms : int
        (** Exact raw-history cut chosen for [messages]. Projection stages that
            rewrite historical bytes use this as their cache-stable anchor: the
            rewrite boundary moves only when the authoritative cut moves. *)
  }

val budget_error_to_string : budget_error -> string
(** Diagnostic rendering carrying the measured values. Suitable as the
    [Error] payload of an [Agent_sdk.Agent.model_input_projection], which
    aborts the turn before request measurement or dispatch. *)

val project_with_drop
  :  measure_message_bytes:(Agent_sdk.Types.message -> int)
  -> capacity_bytes:int
  -> reserved_bytes:int
  -> Agent_sdk.Types.message list
  -> (projection, budget_error) result
(** The canonical projection result, including the exact atom cut selected
    from the unmodified input. [messages] is physically the input list when
    [dropped_atoms = 0]. *)

val project
  :  measure_message_bytes:(Agent_sdk.Types.message -> int)
  -> capacity_bytes:int
  -> reserved_bytes:int
  -> Agent_sdk.Types.message list
  -> (Agent_sdk.Types.message list, budget_error) result
(** [project ~measure_message_bytes ~capacity_bytes ~reserved_bytes messages]
    returns the most recent suffix of [messages] whose measured size fits
    [capacity_bytes - reserved_bytes], with pinned messages preserved in
    place.

    [capacity_bytes] is the target's declared request-body cap. MASC does not
    own provider serialization, so [reserved_bytes] is the caller's account
    of every request byte that is not conversation history — tool schemas,
    system prompt, and an allowance for the provider-specific fields MASC
    cannot measure. Under-reserving does not corrupt state: the provider
    refusal stays typed, and the next assembly re-measures.

    [measure_message_bytes] is injected rather than fixed here because the
    canonical message encoder lives above this library. It must be the same
    encoder for every message of one call; exact agreement with the
    provider's own serializer is not required, since [reserved_bytes] carries
    that allowance.

    Never raises. Returns the input list physically unchanged when the whole
    history fits (including the empty list), so a request that needs no cut
    is byte-identical to the uncut one. *)
