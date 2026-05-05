(** Per-persona admission policy for the work-conserving keeper scheduler.

    Part of RFC-0026 (Work-Conserving Keeper Admission, §3.3).  Owns the
    "which providers will I accept and at what quality tier" decision
    that the admission router consults at every keeper turn.

    This module is purely declarative — it loads a TOML block, validates
    invariants, and exposes a query API.  It performs no I/O against
    providers and does no fairness scheduling.  Those layers are
    [Keeper_provider_token_bucket] (PR-A, already merged) and the
    forthcoming admission router + WFQ overflow modules (PR-C).

    Layered invariants (RFC-0026 §3.1):

      I5 (Drift Observability): every dispatch where [preferred(k) /=
      actual(k)] is logged with [(keeper, preferred, actual, reason,
      tier)].  The persona policy supplies [preferred(k)] and the tier
      classification of every other candidate; the router emits the log
      line.

    Non-goals:

    - This module does NOT decide whether a provider's bucket has
      tokens — that is [Keeper_provider_token_bucket.try_acquire].
    - This module does NOT enqueue starved keepers — that is the WFQ
      overflow queue (PR-C scope).
    - This module does NOT model in-attempt streaming liveness
      (RFC-0022 territory). *)

type tier =
  | Preferred
  (** Top-tier model the persona prefers.  Drift to other tiers is
      always logged. *)
  | Acceptable
  (** Same-quality alternatives.  No surface event — the persona
      considers these equivalent for its workload. *)
  | Survival
  (** Last-resort models (e.g. local Ollama).  Only used when all
      higher tiers are throttled.  Always emits a Drift log line. *)

type candidate = {
  provider : string;     (* matches Keeper_provider_token_bucket.provider_id *)
  model : string;        (* concrete model id, e.g. "claude-sonnet-4-6" *)
  tier : tier;
}
(** A single (provider, model, tier) entry.  Order in the candidate
    list is the persona's preference; the admission router walks it
    in order and stops at the first available bucket. *)

type t
(** Opaque persona admission policy.  Built from a parsed TOML block;
    immutable after creation. *)

(** {1 Construction} *)

type validation_error =
  | Empty_candidate_list
  | Min_tier_above_preferred
  | Duplicate_provider of string
  | Unknown_tier_label of string
  | Weight_out_of_range of int

val of_fields :
  keeper_id:string ->
  candidates:candidate list ->
  weight:int ->
  min_tier:tier ->
  (t, validation_error) result
(** Build a policy from already-typed fields.  Returns [Error] when an
    invariant is violated.  Pure — no I/O.

    Invariants enforced:

    - [candidates <> []]
    - [min_tier] is not strictly above [Preferred] (i.e. [min_tier] is
      not "better than the most preferred candidate")
    - all [candidate.provider] strings are distinct
    - [weight >= 1] (default 1; persona-level priority for WFQ) *)

val parse_admission_json :
  keeper_id:string -> Yojson.Safe.t -> (t, validation_error) result
(** Parse the [admission] sub-object of a per-keeper config block (the
    JSON view that [cascade_toml_materializer] produces from
    [\[admission.<keeper_id>\]] sub-tables in [cascade.toml]).  Schema
    (informal):

    {v
    [admission.analyst]
    weight = 1
    min_tier = "Acceptable"
    candidates = [
      { provider = "anthropic", model = "claude-sonnet-4-6", tier = "Preferred" },
      { provider = "glm-coding", model = "auto",             tier = "Acceptable" },
      { provider = "ollama",     model = "qwen3.6:27b-coding-nvfp4", tier = "Survival" },
    ]
    v}

    The materializer lifts that to:

    {v
    {
      "weight": 1,
      "min_tier": "Acceptable",
      "candidates": [
        {"provider":"anthropic","model":"claude-sonnet-4-6","tier":"Preferred"},
        ...
      ]
    }
    v}

    Missing fields default to: [weight = 1], [min_tier = "Acceptable"].
    Missing or empty [candidates] returns [Error Empty_candidate_list]
    — every persona must declare candidates explicitly to make I5
    (drift observability) defensible.

    Pure: no file I/O.  The caller is expected to read the JSON from
    [cascade_config_loader.load_json] and select the appropriate
    sub-object before calling this function. *)

(** {1 Query} *)

val keeper_id : t -> string

val candidates : t -> candidate list
(** Returns the candidate list in persona preference order.  The
    admission router is expected to walk this list and call
    [Keeper_provider_token_bucket.try_acquire] on the first whose tier
    is not below [min_tier]. *)

val candidates_above_min_tier : t -> candidate list
(** Same as [candidates] but with entries below [min_tier] filtered
    out.  Convenience for routers that always respect the floor. *)

val weight : t -> int
(** WFQ weight.  Default 1.  Higher weight = more frequent dispatch
    when the overflow queue chooses among waiters. *)

val min_tier : t -> tier
(** The minimum tier this persona will accept.  When all candidates
    above [min_tier] are throttled, the router must surface a
    [Capacity_exhausted] event rather than silently demoting. *)

val top_provider : t -> string
(** [provider] of the head of the candidate list — the persona's
    most-preferred provider.  Used for I5 drift logging
    ([preferred] field). *)

(** {1 Tier helpers} *)

val tier_label : tier -> string
(** ["Preferred" | "Acceptable" | "Survival"].  Stable string for log
    lines and Prometheus labels. *)

val tier_of_label : string -> tier option
(** Inverse of [tier_label].  Returns [None] for unknown labels — the
    parser uses this to surface [Unknown_tier_label]. *)

val tier_compare : tier -> tier -> int
(** Total order: [Preferred < Acceptable < Survival].  Lower is
    better.  Used to filter against [min_tier]. *)
