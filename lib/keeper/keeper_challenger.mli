(** Keeper_challenger — dialectical verification round for keeper turns.

    Implements the A1 "Dialectical Verification + Veto" pattern.

    @since A1 Dialectical Verification *)

val challenger_enabled : unit -> bool
(** [challenger_enabled ()] returns [true] when [MASC_CHALLENGER_ENABLED=1]
    (or ["true"]) is set in the environment. *)

val challenger_cascade_name : unit -> string
(** [challenger_cascade_name ()] returns the cascade name to use for the
    challenger round.  Reads [MASC_CHALLENGER_CASCADE] first; falls back to
    the sentinel ["challenger"] (which resolves via [cascade.toml]
    [[challenger]] section). *)

val different_provider_tier : string -> string -> bool
(** [different_provider_tier keeper_cascade challenger_cascade] returns
    [true] when the two cascade names have different scheme prefixes and
    therefore originate from different provider tiers. *)

val should_run_challenger :
  keeper_cascade:string -> challenger_cascade:string -> bool
(** [should_run_challenger ~keeper_cascade ~challenger_cascade] returns
    [true] when the challenger round should run for this combination. *)

val evaluate :
  keeper_name:string ->
  keeper_cascade:string ->
  result_text:string ->
  unit ->
  Keeper_challenger_outcome.t
(** [evaluate ~keeper_name ~keeper_cascade ~result_text ()] runs the
    challenger evaluation and returns a structured outcome.

    Returns [No_challenger] when the flag is off or eligibility gates fail.
    Returns [Accept] or [Veto _] otherwise. *)
