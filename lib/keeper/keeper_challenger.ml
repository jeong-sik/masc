(** Keeper_challenger — dialectical verification round for keeper turns.

    Implements the A1 "Dialectical Verification + Veto" pattern: after a
    keeper turn completes but before [apply_post_turn_lifecycle], an
    optional challenger keeper running on a different provider can review the
    turn result and either accept or veto it.

    Design constraints (per issue A1):
    - Challenger eligibility requires [risk_posture = "cautious"] on the
      original keeper archetype (gate in [Keeper_persona_authoring]).
    - The challenger MUST run on a different provider tier than the primary
      keeper to reduce sycophantic convergence risk.
    - Veto reasons are structured variants — no string matching allowed
      (memory [no-string-matching-classification]).
    - This module owns only the evaluation gate and cascade routing for the
      challenger.  The hook insertion point is in [Keeper_unified_turn].

    PoC scope (cycle 1): evaluation always returns [Accept]; full LLM-backed
    challenger call is deferred to cycle 2 after the A4 token-cost baseline
    is established.

    @since A1 Dialectical Verification *)

(** Environment flag that enables challenger evaluation.
    Set [MASC_CHALLENGER_ENABLED=1] (or [true]) to opt in.
    Defaults to off so existing deployments are unaffected. *)
let challenger_enabled () =
  match Sys.getenv_opt "MASC_CHALLENGER_ENABLED" with
  | Some ("1" | "true" | "TRUE") -> true
  | _ -> false

(** Name of the cascade profile to use for the challenger round.
    Reads [MASC_CHALLENGER_CASCADE] first; falls back to the [cascade.toml]
    [challenger] section's [models] profile name; finally returns the
    hard-coded sentinel ["challenger"] so callers can detect "not configured"
    by checking whether the name resolves to actual providers. *)
let challenger_cascade_name () =
  match Sys.getenv_opt "MASC_CHALLENGER_CASCADE" with
  | Some s when String.trim s <> "" -> String.trim s
  | _ -> "challenger"

(** Return [true] when [keeper_cascade] and [challenger_cascade] are
    considered different provider tiers.

    Provider tier is determined by the scheme prefix before the first [':'].
    Two cascade names with the same scheme prefix (e.g. both start with
    ["codex_cli:"]) are considered the same tier and the challenger is
    suppressed to avoid sycophantic convergence.

    When either name is empty or contains no [':'], the names are compared
    directly; equality means same tier. *)
let different_provider_tier keeper_cascade challenger_cascade =
  let scheme_of name =
    match String.index_opt name ':' with
    | Some i -> String.sub name 0 i
    | None -> name
  in
  not (String.equal (scheme_of keeper_cascade) (scheme_of challenger_cascade))

(** Determine whether the challenger round should run for this turn.

    Returns [true] when:
    1. [challenger_enabled ()] is true, AND
    2. [~keeper_cascade] differs in provider tier from [~challenger_cascade],
       AND
    3. [~challenger_cascade] is non-empty and not equal to [~keeper_cascade].

    The [risk_posture] eligibility gate lives in [Keeper_persona_authoring];
    callers are expected to check [Keeper_persona_authoring.is_challenger_eligible]
    before calling here. *)
let should_run_challenger ~keeper_cascade ~challenger_cascade =
  challenger_enabled ()
  && String.length challenger_cascade > 0
  && not (String.equal keeper_cascade challenger_cascade)
  && different_provider_tier keeper_cascade challenger_cascade

(** Evaluate the turn result using the challenger.

    PoC (cycle 1): logs the evaluation intent and always returns [Accept].
    The full LLM-backed challenger call will be added in cycle 2 once the
    A4 token-cost baseline is available.

    @param keeper_name Name of the primary keeper being evaluated
    @param keeper_cascade Cascade the primary keeper ran on this turn
    @param result_text Text output of the primary turn (for future use)
    @param challenger_cascade_name_val Resolved challenger cascade name *)
let evaluate_poc ~keeper_name ~keeper_cascade ~result_text:_ ~challenger_cascade_name_val =
  Log.Keeper.debug
    "%s: challenger round (PoC) — keeper_cascade=%s challenger_cascade=%s; returning Accept"
    keeper_name keeper_cascade challenger_cascade_name_val;
  Keeper_challenger_outcome.Accept

(** Main entry point.  Called from [Keeper_unified_turn] after [turn_cost]
    is computed and before [apply_post_turn_lifecycle].

    Returns [No_challenger] when:
    - the env flag is off, or
    - the keeper is not eligible (checked by caller via
      [Keeper_persona_authoring.is_challenger_eligible]), or
    - challenger and primary cascade are the same provider tier.

    Returns [Accept] or [Veto _] otherwise. *)
let evaluate
    ~(keeper_name : string)
    ~(keeper_cascade : string)
    ~(result_text : string)
    () : Keeper_challenger_outcome.t =
  let challenger_casc = challenger_cascade_name () in
  if not (should_run_challenger ~keeper_cascade ~challenger_cascade:challenger_casc)
  then Keeper_challenger_outcome.No_challenger
  else
    evaluate_poc ~keeper_name ~keeper_cascade ~result_text
      ~challenger_cascade_name_val:challenger_casc
