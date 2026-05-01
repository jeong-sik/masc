(** Trust rotation constants and kill switch for cascade provider scoring.

    Phase-1 trust auto-rotation was reverted in #10412 due to design concerns
    (see RFC: "cascade trust_score redesign — kill switch + hardcoded
    calibration").  This module re-introduces trust-based weight attenuation
    satisfying the redesign constraints:

    - One env-var kill switch: [MASC_CASCADE_TRUST_ROTATION=on|off]
      (default [off] until canary validation completes).
    - All calibration constants are top-level [let] bindings here —
      no [read_bounded_float_setting] calls (constraint C2).
    - Trust ceiling fixed at 1.0 — trust multiplies [effective_weight]
      in \[0, 1\] so it can only attenuate, never amplify, a provider's
      configured weight (constraint C3).

    Changing calibration requires a PR + version bump per the
    five-SSOT convention.

    Calibration source: 4040-decision fleet corpus, week 16 of 2026.
    Validation corpus: fleet data week 17 of 2026 (disjoint from calibration).

    @since 0.184.0 *)

(* ── Kill switch ──────────────────────────────────────── *)

(** Whether trust-based weight rotation is active.

    Controlled by [MASC_CASCADE_TRUST_ROTATION=on] (any other value, or
    absent, means off).  Default: [false] — disabled until a canary run
    validates the trust distribution against production traffic. *)
let trust_rotation_enabled : bool =
  match Sys.getenv_opt "MASC_CASCADE_TRUST_ROTATION" with
  | None -> false
  | Some raw -> String.trim raw |> String.lowercase_ascii = "on"

(* ── Calibration constants ─────────────────────────────
   These are algorithm constants, not operator knobs.  To tune them,
   open a PR, update the values below, and bump the project version.
   Do NOT expose them as env vars (constraint C2). *)

(** Initial trust score for newly-tracked providers.
    Full trust (1.0) until evidence of unreliability arrives. *)
let initial_trust : float = 1.0

(** Maximum trust score.  Fixed at 1.0 — trust only attenuates weight,
    never amplifies it past the operator-configured weight.
    Effective weight is always [≤ config_weight] (constraint C3). *)
let ceiling : float = 1.0

(** Trust increment added per successful call (additive, capped at [ceiling]).
    At 0.15 a provider recovers from [decay_transient] decay in ~6 successes. *)
let reward_on_success : float = 0.15

(** Multiplicative decay applied on a transient failure (the first or an
    isolated failure outside the persistence window). *)
let decay_transient : float = 0.7

(** Multiplicative decay applied on a persistent failure — when the provider
    has accumulated [≥ persistent_threshold] failures within the last
    [persistent_window_sec] seconds.  Much more aggressive than transient
    decay to rapidly attenuate the weight of a consistently-failing provider. *)
let decay_persistent : float = 0.15

(** Minimum number of failure events within [persistent_window_sec] required
    to classify the current failure as "persistent". *)
let persistent_threshold : int = 2

(** Rolling window in seconds within which failure count is measured for
    the persistent failure classification. *)
let persistent_window_sec : float = 600.0

(* ── Trust computation ────────────────────────────────── *)

(** [apply_success trust] increases [trust] by [reward_on_success],
    capped at [ceiling]. *)
let apply_success trust_score =
  Float.min ceiling (trust_score +. reward_on_success)

(** [apply_failure ~persistent trust] decays [trust] by [decay_persistent]
    when [~persistent:true], or [decay_transient] otherwise. *)
let apply_failure ~persistent trust_score =
  let decay = if persistent then decay_persistent else decay_transient in
  trust_score *. decay
