(** Autoresearch → Verification bridge.

    Closes the contract-closure gap formally proved in
    [specs/closure/ContractClosure.tla]: when an autoresearch cycle
    settles, propagate the result into the verification layer and emit
    an attribution envelope for SSE consumers.

    The bridge is [NonDet]: autoresearch decisions aggregate per-cycle
    metric scores and a model-generated hypothesis into a Keep/Discard
    verdict. The score is numeric but the choice of hypothesis is
    model-authored — not reproducible across replays with identical
    inputs. See MEMORY [deterministic-nondeterministic-boundary].

    This module lives at [lib/] (not [lib/autoresearch/]) because it
    bridges two sub-libraries: [masc_autoresearch] for the loop state
    and [masc_mcp.Verification] for the verdict target. Both are in
    scope here; they are not in scope inside [masc_autoresearch].

    Once [Attribution_tagged] (PR #7782) lands, [attribution_of_cycle]
    should migrate to return [Attribution_tagged.nondet
    Attribution_tagged.t] for compile-time NonDet enforcement. Until
    then the runtime [origin:NonDet] field carries the invariant.

    @since 2.263.0 *)

(** Convert an autoresearch cycle outcome to a verification verdict.

    Mapping:
    - [Keep] + [score_after] meets [target_score] → [Pass]
    - [Keep] + below target → [Partial (score_norm, rationale)]
      where [score_norm] is normalized to [[0.0, 1.0]] against
      [target_score] (or unit range fallback if no target).
    - [Discard] → [Fail reason] with a rationale assembled from the
      cycle hypothesis and delta.

    Orientation is handled: when [lower_is_better] is set, the score
    normalization inverts so that lower raw scores map to higher
    verification scores. *)
val verdict_of_cycle
  :  Autoresearch.loop_state
  -> Autoresearch.cycle_record
  -> Verification.verdict

(** Produce the attribution envelope with [origin = NonDet] and
    [gate = "autoresearch"]. Evidence includes [loop_id], [cycle],
    [hypothesis], [score_before], [score_after], [delta], [model_used],
    [elapsed_ms], [lower_is_better], [target_score]. [rationale] is
    folded into the evidence for [Passed]/[Policy_failed] (mirrors
    future [Attribution_tagged.nondet_*] shape); [Partial_pass] keeps
    [rationale] as the outcome's own field.

    Outcome mapping:
    - Keep + target met          → [Passed]
    - Keep + below target        → [Partial_pass]
    - Discard                    → [Policy_failed] (not a transition — a
                                   hypothesis was rejected, not a state
                                   change) *)
val attribution_of_cycle
  :  Autoresearch.loop_state
  -> Autoresearch.cycle_record
  -> Attribution.t
