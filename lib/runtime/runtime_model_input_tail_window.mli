(** Runtime_model_input_tail_window — bounded transmission view over
    provider-bound conversation history (RFC-0351 §3 L5, #26534 PR-C, #26544,
    #26551).

    [project] keeps only the most recent atoms of the message list that AGENT_CORE
    is about to send to a provider. One atom is either an organic [User]
    message or an [Assistant] message together with the [Tool] messages that
    answer it, so a cut can never separate a tool result from the tool call
    that produced it. Durable agent state and checkpoints are untouched: AGENT_CORE
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

    Messages carrying AGENT_CORE extra-system-context provenance are never counted
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
  :  Agent_core.Types.message list
  -> (Agent_core.Types.message * label) list * int
(** Label every message with its atom index, in order, and return the atom
    count. [User] and [Assistant] open a new atom; [Tool] joins the atom of the
    assistant that issued the call, so both sides of a tool exchange always
    share one label.

    Exported because the atom is now a shared unit of the projection pipeline
    rather than a private detail of the cut: a stage that runs before
    {!project} and needs to reason about age must use the same labelling, and
    a second implementation of it would let the two stages disagree about
    where an atom begins. *)

val first_atom_at_or_after
  :  Agent_core.Types.message list
  -> message_index:int
  -> int
(** Atom index of the first atom whose message sits at or after
    [message_index]; the atom count when none does.

    Converts a position in the message list into the atom vocabulary the cut
    and the demotion boundary both speak. A caller that knows a boundary as a
    message count — how many messages a turn was seeded with, say — cannot use
    that number directly: pinned messages are not atoms, and a [Tool] message
    belongs to the atom its [Assistant] opened, so the two indices drift apart.
    Kept here so the conversion uses the same labelling as the cut rather than
    a second reading of where an atom begins. *)

val next_shrink_capacity_bytes
  :  ?allow_empty_history:bool
  -> measure_message_bytes:(Agent_core.Types.message -> int)
  -> target_capacity_bytes:int
  -> Agent_core.Types.message list
  -> int option
(** Choose a smaller projection capacity at an atom boundary after a provider
    has rejected [messages]. [None] means there is no smaller structural view.

    [allow_empty_history=false] preserves the newest atom. When explicitly
    [true], a caller that carries the current goal outside [messages] may use a
    zero-prior-history floor after every atom boundary has been exhausted.

    The returned capacity is never below the bytes required by pinned
    messages, the synthetic preamble, and the newest atom, and it is strictly
    smaller than the exact rejected window after synthetic framing is
    charged. Candidate views are tried largest first: every atom boundary at
    or below [target_capacity_bytes], then the newest atom alone, then the
    empty history when allowed; the first that frames strictly smaller is the
    answer, and [None] means none does. A boundary can fail that test while a
    deeper one passes: dropping only the oldest atom saves less than the
    preamble the cut adds when that atom is shorter than the preamble
    encoding (#33217). Thus applying {!project} cannot replace a size-driven
    refusal with an equal or larger request. *)

val minimum_capacity_bytes
  :  measure_message_bytes:(Agent_core.Types.message -> int)
  -> Agent_core.Types.message list
  -> int option
(** Return the exact measured capacity of the zero-prior-history view: pinned
    messages plus the omission preamble. [None] means [messages] has no
    shrinkable atom or the framed floor is not strictly smaller than the
    rejected view. Callers must pass [allow_empty_history=true] to {!project}
    when applying this capacity. *)

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
  { messages : Agent_core.Types.message list
  ; dropped_atoms : int
        (** Exact raw-history cut chosen for [messages]. Describes this cut and
            nothing else: the stage that rewrites historical bytes used to
            anchor its own boundary here, and now chooses one from the
            conversation's structure instead, so a reader must not take this as
            a boundary anyone else is required to share. *)
  ; atom_count : int
        (** Atoms the input history contained, before the cut. [atom_count -
            dropped_atoms] is what the provider receives. Both are reported
            because a share is not recoverable from the transmitted list alone:
            the dropped atoms leave no trace in [messages], so an observer
            given only the result cannot tell a keeper that transmitted all of
            a short history from one that transmitted the tail of a long one.
            Pinned messages are not atoms and are counted in neither. *)
  }

type window_observation =
  { transmitted_atoms : int
  ; total_atoms : int
  }
(** How much of a history one projection carried, kept without the messages so
    an observer can hold it for the length of a turn. *)

val observe : history_atom_count:int -> projection -> window_observation
(** [observe ~history_atom_count projection] pairs what [projection]
    transmitted with the history it was measured against.

    [history_atom_count] is passed in rather than read off [projection]
    because a projection only knows the list it was handed. The demotion
    pipeline cuts, materializes, and on a storage failure re-cuts the
    surviving sublist — and that last projection's own [atom_count] is the
    size of the sublist, not of the turn's history. Reading the denominator
    from it inflates the share by whatever the earlier cuts already removed:
    a keeper that reached over 800 of 5,000 atoms would report 800 of 1,000
    (illustrative shape, not a measured trace). Supply the [atom_count] of the
    first cut, which is the only one taken against the full history. *)

val budget_error_to_string : budget_error -> string
(** Diagnostic rendering carrying the measured values. *)

val budget_error_to_core_error : budget_error -> Agent_core.Error.t
(** The [Error] payload of an [Agent_core.Agent.model_input_projection], which
    aborts the turn before request measurement or dispatch.

    Both constructors are named [Api (ContextOverflow _)]: each says this
    candidate's declared ceiling cannot carry the turn, which is a
    per-candidate capacity bound rather than a defect in the request, and the
    lane loop already treats that constructor as grounds to try the next
    candidate. [limit] is [None] — it is a token count and this window
    measures bytes. *)

val project_with_drop
  :  ?allow_empty_history:bool
  -> measure_message_bytes:(Agent_core.Types.message -> int)
  -> capacity_bytes:int
  -> reserved_bytes:int
  -> Agent_core.Types.message list
  -> (projection, budget_error) result
(** The canonical projection result, including the exact atom cut selected
    from the unmodified input. [messages] is physically the input list when
    [dropped_atoms = 0]. *)

val project
  :  ?allow_empty_history:bool
  -> measure_message_bytes:(Agent_core.Types.message -> int)
  -> capacity_bytes:int
  -> reserved_bytes:int
  -> Agent_core.Types.message list
  -> (Agent_core.Types.message list, budget_error) result
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

    By default the newest atom is mandatory. [allow_empty_history=true] is for
    bootstrap callers whose current goal is carried outside [messages]; when
    no prior atom fits, the projection may retain only pinned messages and the
    omission preamble.

    Never raises. Returns the input list physically unchanged when the whole
    history fits (including the empty list), so a request that needs no cut
    is byte-identical to the uncut one. *)
