(** Keeper_memory_os_policy — Memory OS write-time merge behavior.

    RFC-0247 removed the composite importance score and every input it
    multiplied. What remains is the write-time re-observation merge — not a
    deletion policy. *)

open Keeper_memory_os_types

(** Provenance of a re-observation reaching {!reobserve_fact} (RFC-0285 §8).
    [Recalled_echo] means the incoming claim's identity was recall-injected
    into the conversation window the librarian summarized — the model restated
    its own prompt, which is not fresh evidence. The write boundary decides
    this once (the production caller joins against
    {!Keeper_recall_injection_window.recently_injected}); tests exercising the
    legacy semantics pass [Independent_observation]. A closed sum rather than
    an optional flag so no call site can skip the judgment. *)
type reobservation_provenance =
  | Independent_observation
  | Recalled_echo

(** Fold a re-observation of an existing fact into that fact. An
    [Independent_observation] records [last_verified_at = now] while preserving
    the exact stored [valid_until], independent of category or claim kind. For a
    [Recalled_echo] the row is inherited whole — an echo must never advance the
    truth anchor that recall's recency ranking reads, or a fact can sustain its
    own recall slot indefinitely (the RFC-0285 §8 flywheel). Identity and
    first-seen provenance are preserved in both cases. The prior
    confidence-blend and access-count bump fed the deleted score and are gone —
    there is no numeric strength to move. *)
val reobserve_fact
  :  now:float
  -> provenance:reobservation_provenance
  -> existing:fact
  -> incoming:fact
  -> fact
