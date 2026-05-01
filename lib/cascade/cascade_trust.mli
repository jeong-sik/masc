(** Trust rotation constants and kill switch for cascade provider scoring.

    See the [.ml] module for design rationale and calibration notes.

    @since 0.184.0 *)

(** Whether trust-based weight rotation is active.

    Controlled by [MASC_CASCADE_TRUST_ROTATION=on|off] (default [off]).
    When [false], trust scores are computed and stored on each provider
    state but NOT applied to [effective_weight] — routing is by
    [success_rate] only, as before Phase 1.  This lets operators observe
    the trust distribution (via dashboard / JSONL snapshots) before
    committing to trust-gated routing. *)
val trust_rotation_enabled : bool

(** {1 Calibration constants}

    All values are hardcoded algorithm constants.  To tune them, open a PR
    and bump the project version.  There are no corresponding env vars. *)

val initial_trust : float
(** Initial trust score for newly-tracked providers (1.0 = full trust). *)

val ceiling : float
(** Maximum trust score (1.0 — trust only attenuates, never amplifies). *)

val reward_on_success : float
(** Trust increment per successful call (additive, capped at [ceiling]). *)

val decay_transient : float
(** Multiplicative decay for a transient (isolated) failure. *)

val decay_persistent : float
(** Multiplicative decay for a persistent failure (≥ [persistent_threshold]
    failures within [persistent_window_sec]). *)

val persistent_threshold : int
(** Minimum number of recent failures to classify a failure as persistent. *)

val persistent_window_sec : float
(** Rolling window in seconds for measuring recent failure count for
    persistent classification. *)

(** {1 Trust computation} *)

val apply_success : float -> float
(** [apply_success trust] increases trust by [reward_on_success], capped at
    [ceiling]. *)

val apply_failure : persistent:bool -> float -> float
(** [apply_failure ~persistent trust] decays trust by [decay_persistent]
    when [~persistent:true], or [decay_transient] when [~persistent:false]. *)
