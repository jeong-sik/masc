(** Runtime_model_input_tail_window — bounded transmission view over
    provider-bound conversation history (RFC #26534 PR-C, #26544).

    [project] keeps only the most recent atoms of the message list that OAS
    is about to send to a provider. One atom is either an organic [User]
    message or an [Assistant] message together with the [Tool] messages that
    answer it, so a cut can never separate a tool result from the tool call
    that produced it. Durable agent state and checkpoints are untouched: OAS
    applies a [model_input_projection] to the provider-bound copy only
    ({!Runtime_agent_context.config.model_input_projection}).

    Cut placement is quantized to whole windows: with
    [atoms_per_window = K], the drop count is the largest multiple of [K]
    that still leaves at least [K] atoms. The transmitted prefix therefore
    stays byte-identical across [K] consecutive atoms of growth before
    jumping once, which preserves provider prompt-cache reuse between jumps
    (#26535 measured the alternative: a per-turn sliding cut changes the
    prefix on every request).

    Messages carrying OAS extra-system-context provenance are never counted
    and never dropped; that block is re-assembled fresh each turn by the
    keeper hooks and must survive the cut. When the cut leaves a non-[User]
    message at the head of the transmitted history, a constant synthetic
    [User] preamble is prepended so providers that require a [User]-first
    conversation accept the request; being constant, it does not perturb the
    quantized prefix. *)

val atoms_per_window : int
(** Window quantum [K]. Once the conversation exceeds [2*K - 1] atoms the
    transmitted history holds between [K] and [2*K - 1] atoms; below that
    threshold {!project} is the identity. Sized from live checkpoint
    measurement (2026-08-01: sangsu 487 atoms / 706KB, kidsnote 442 atoms /
    719KB, mean atom ≈ 1.5KB — a [K]..[2K-1] window transmits ≈ 90..180KB
    of history against a 200K-token primary context). *)

val preamble_marker_key : string
(** Metadata key tagging the synthetic preamble message, so a captured
    request distinguishes the marker from organic history. The preamble
    exists only in the transmitted copy; nothing writes it to durable
    state. *)

val project :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list
(** Total on every input: never raises, never fails, and returns the input
    list physically unchanged below the window threshold (including the
    empty list). *)
