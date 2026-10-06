(** Start-prompt ceilings of the official clients that cannot report an
    oversized input back as a typed error.

    An official-client turn 1 sends the whole projected history and the
    client owns the transcript from turn 2. A start prompt over what the
    client takes must be cut before sending, so the ceiling comes from the
    model's window ([max-context], in tokens) and from transport sizes that
    were measured end to end, never from an operator-entered byte count.
    Claude Code and Codex have no ceiling here: the provider refuses an oversized start
    with a typed overflow and the turn retries smaller. Muse Code has its own
    measured derivation ({!Runtime_muse_prompt_capacity}). *)

val bytes_per_window_token : int
(** The bytes of start prompt allowed per token of window. MASC has no
    tokenizer, so this is an estimate, not a bound: a token can carry a single
    byte, and text dense in such tokens goes over the window at this ratio.
    Antigravity rewrites an oversized input without reporting it, so such an
    excess is cut silently rather than refused. *)

val antigravity_proven_start_prompt_bytes : int
(** The largest start prompt the Antigravity CLI is known to take: 2,078,915
    bytes went end to end on agy 1.2.6 on 2026-09-18. Long-lived Keepers
    later sent 21.9 to 48.5 MB to a fresh session and failed before their
    first turn (#37123). It is a measured success point, not the CLI maximum;
    raise it only after a larger end-to-end probe. *)

val antigravity_start_prompt_bytes : max_context:int -> int
(** The smaller of {!antigravity_proven_start_prompt_bytes} and
    [bytes_per_window_token × max_context]. *)
