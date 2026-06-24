(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    This module defines the canonical fact and episode records used by
    the librarian, the I/O layer, and the retention policy. All records
    carry a [schema_version] to support future migrations. *)

(** Current schema version written to disk. *)
val schema_version : string

(** RFC-0244 Tier 2: reserved keeper id for the shared semantic store
    (keepers/_shared.facts.jsonl). Not a legal keeper name, so no real keeper
    collides; the consolidator filters it out of its source keeper list. *)
val shared_store_id : string

(** Source attribution for a single extracted fact. *)
type provenance_event =
  { trace_id : string
  ; turn : int
  ; tool_call_id : string option
  }

(** Librarian taxonomy as a closed sum (RFC-0244 §2.3, #21241; RFC-0247 §2.5).
    The free-text label the LLM emits is parsed once at the producer boundary via
    [category_of_string]; [Unknown] absorbs any label outside the taxonomy so a
    drifted/typo'd label can never be silently promoted by the consolidator.

    [Ephemeral] is the load-bearing RFC-0247 arm: lifecycle/coordination
    boilerplate that is true but not durable cross-keeper knowledge ("checkpoint
    saved", "no tasks", "remains scheduled"). The #21244 live dry-run found these
    are the only >=2-keeper-corroborated claims today; a structurally
    non-promotable category is the type-level backstop that lets the consolidation
    fiber be turned back on without injecting recall noise — robust even when the
    prompt's durability gate is imperfect. [Unknown] is distinct: a rising
    [Unknown] rate signals the librarian prompt needs a new arm.

    [Validated_approach] and [Lesson] (RFC-0247 §6) are the outcome-derived kinds
    the redesign exists to capture: an approach confirmed by its result, and a
    failure distilled into how to improve next time. Both are durable and
    promotable. *)
type category =
  | Code_change
  | Fact
  | Preference
  | Blocker
  | Goal
  | Constraint
  | Ephemeral
  | Validated_approach
  | Lesson
  | Unknown of string

(** Canonical lowercase token for a category (round-trips with
    [category_of_string] for known variants; [Unknown s] yields [s]). *)
val category_to_string : category -> string

(** Parse a free-text category label (trimmed, case-insensitive on known tokens);
    anything outside the taxonomy becomes [Unknown] carrying the raw label. *)
val category_of_string : string -> category

(** RFC-0285 §3.1: producer-emitted origin tag, orthogonal to {!category} (a [Lesson]
    can be a self-observation). A closed sum classified ONCE at the librarian write
    boundary — not a read-time string match. Drives {!fact_valid_until}
    ([Self_observation] gets a short finite horizon) and gates promotion. *)
type claim_kind =
  | Self_observation
  | External_state
  | Durable_knowledge

(** Canonical lowercase token (round-trips with [claim_kind_of_string]). *)
val claim_kind_to_string : claim_kind -> string

(** Parse a claim_kind token (trimmed, case-insensitive on known tokens); an
    absent/unrecognized label yields [None], routing to the durable pre-RFC path
    (safe), never to wrong-volatile. *)
val claim_kind_of_string : string -> claim_kind option

(** Whether a category may be promoted into the shared semantic tier. Exhaustive
    over {!category}; only [Fact] and [Constraint] promote (preserving the prior
    ["fact";"constraint"] whitelist), so a new or typo'd category cannot silently
    join the promotable set — a future durable kind must be classified here at
    compile time. *)
val is_promotable : category -> bool

(** RFC-0259 §3.2(b): the kind of external state a claim references. Closed sum so
    the grounding reconciler (P2/P3) must handle every kind at compile time. *)
type external_ref_kind =
  | Pr
  | Issue
  | Task

(** Canonical lowercase token for an external-ref kind (round-trips with
    [external_ref_kind_of_string]). *)
val external_ref_kind_to_string : external_ref_kind -> string

(** Parse an external-ref kind token; [None] outside the closed set. *)
val external_ref_kind_of_string : string -> external_ref_kind option

(** RFC-0259 §3.2(b): a reference to verifiable external state named by a claim.
    [id] is the numeric id for [Pr]/[Issue] and the full key for [Task]
    (e.g. ["PK-1234"]). *)
type external_ref =
  { kind : external_ref_kind
  ; id : string
  }

(** RFC-0259 §3.2(b): parse an external-state reference out of a claim, once, at
    the producer boundary. CONSERVATIVE — only an explicit marker counts
    ("PR #123", "pull request #123", "pull/123", "issue #123", "issues/123",
    "PK-1234"); a bare "#123" with no keyword yields [None] (it is prose, not a
    reference). Returns the earliest-positioned reference when several are named. *)
val external_ref_of_claim : string -> external_ref option

(** RFC-0247 §2.3 (forgetting): the hard-expiry timestamp a newly written fact of
    this category should carry, given [now]. Exhaustive over {!category}. Only
    [Ephemeral] (coordination boilerplate) gets a finite TTL — the brain's
    episodic memory that fades; durable knowledge ([Fact]/[Constraint]/…) and
    [Unknown] (conservative: we do not aggressively expire what we do not
    understand) return [None] and never hard-expire. This is the write-side
    producer that makes the previously-inert [valid_until] field (and the GC TTL
    pass) reachable. *)
val category_valid_until : now:float -> category -> float option

(** RFC-0259 §3.2: the volatile-claim decay horizon (a TIME, not a score). Bounds
    how long an un-re-observed external-state claim survives before the grounding
    reconciler (P2) lands. *)
val volatile_external_ttl_seconds : float

(** RFC-0285 §3.4: the self-observation decay horizon (a TIME, not a score). Shorter
    than [volatile_external_ttl_seconds] — transient first-person self-state changes
    every turn, so a tighter horizon quiets the echo faster. Tune in cycles. *)
val self_observation_ttl_seconds : float

(** RFC-0259 §3.2 / RFC-0285 §3.4: the write-side [valid_until] producer. Precedence:
    [Self_observation] claim_kind gets the shortest finite horizon
    ([self_observation_ttl_seconds]) regardless of category/external_ref; otherwise an
    [external_ref] claim gets [volatile_external_ttl_seconds] (so a PR-status claim
    mislabeled [Fact]/[Unknown] still decays); otherwise the category decides (only
    [Ephemeral] is finite). *)
val fact_valid_until
  :  now:float
  -> external_ref:external_ref option
  -> claim_kind:claim_kind option
  -> category
  -> float option

(** A single semantic claim extracted from conversation history.

    RFC-0247 (purge): the fact carries only structure — claim, typed category,
    provenance, the distinct-keeper corroboration set, and the timestamps. The
    deleted fields (confidence, access_count, last_accessed, stale_factor,
    expected_lifetime_cycles) fed the removed composite score; a fact's value is
    the librarian's judgment, not a number on the row. *)
type fact =
  { claim : string
  ; category : category
  ; external_ref : external_ref option
    (** RFC-0259 §3.2(b): set by the producer when the claim names a PR/issue/task
        id. Orthogonal to [category]. Drives [fact_valid_until] (a referenced
        claim is volatile, never durable). Omitted from JSON when [None]. *)
  ; claim_kind : claim_kind option
    (** RFC-0285 §3.1: producer-emitted origin tag, parallel to [external_ref] and
        orthogonal to [category]. Drives [fact_valid_until] ([Self_observation] gets a
        short horizon) and gates promotion ([Self_observation] never crosses keepers).
        Omitted from JSON when [None]; a missing tag degrades to the durable path. *)
  ; source : provenance_event
  ; observed_by : string list
    (** RFC-0244 Tier 2 (shared semantic store) only: the sorted set of distinct
        keeper ids that have corroborated this claim. Empty for Tier-1 per-keeper
        facts (omitted from their JSON). Populated by the consolidator. *)
  ; first_seen : float
  ; valid_until : float option
  ; last_verified_at : float option
  ; schema_version : string
  ; claim_id : string option
    (** RFC-0259 §3.7 (P6): a producer (librarian) -emitted stable slug for the
        claim's CONCLUSION (not its wording). A reworded re-extraction of the same
        conclusion reuses the id and UPSERTs; a changed conclusion gets a new id
        and stays a distinct row. Omitted from JSON when [None]; legacy / id-less
        rows fall back to [normalize_claim] in [claim_identity]. *)
  }

(** Whether a fact's hard-expiry horizon still admits it at [now]. Facts with no
    [valid_until] are durable and current. *)
val fact_is_current : now:float -> fact -> bool

(** RFC-0259 §3.6 (P5): partition facts into [(live, expired)] at [now] on the
    [valid_until] boundary ([fact_is_current]). The cap path drops the expired
    partition so on-disk retention honours the same [valid_until] the GC sweep
    does. Durable facts ([valid_until = None]) are always in [live]. *)
val partition_expired : now:float -> fact list -> fact list * fact list

(** The time a fact was last known good: [last_verified_at] if set, else
    [first_seen]. The SSOT staleness anchor shared by the reconciler, recall,
    and dashboard user-model ordering so those paths cannot drift on the anchor
    rule. *)
val reference_time : fact -> float

(** Whether the fact belongs to the operator/user-model projection. *)
val fact_is_user_model : fact -> bool

(** A librarian extraction result: a summary plus structured claims. *)
type episode =
  { trace_id : string
  ; generation : int
  ; episode_summary : string
  ; claims : fact list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  ; source_turn_range : (int * int) option
  ; created_at : float
  ; valid_until : float option
  ; terminal_marker : string option
  ; schema_version : string
  }

(** Claim identity SSOT. Normalizes a claim to a fingerprint (lowercase +
    internal-whitespace-collapsed + trailing-space-trimmed) so re-confirmations of
    the same conclusion share a key. Used by both the recall-time dedup and the
    write-time upsert so the two key identically. *)
val normalize_claim : string -> string

(** Canonicalize a producer-emitted [claim_id] at the typed boundary. Formatting
    differences from the LLM such as whitespace, case, underscores, or stray
    punctuation normalize to the same lowercase kebab slug; blank/empty ids
    degrade to [None]. *)
val normalize_claim_id : string -> string option

(** RFC-0259 §3.7 (P6): the producer-identity dedup SSOT. When the librarian emits
    a [claim_id] (a stable slug for the claim's CONCLUSION, not its wording) that id
    is the key, so reworded re-extractions of the same conclusion UPSERT one row and
    inherit its [first_seen] anchor instead of minting a fresh row that resets the
    volatile TTL, while a changed conclusion carries a new id and stays distinct. A
    claim with no [claim_id] (legacy / id-less) falls back to [normalize_claim] of
    its text (pre-P6 append behavior — the degrade never over-merges). The id is the
    librarian's judgment surfaced as a typed key, not a fuzzy / embedding / substring
    classifier we author. The write upsert, recall dedup, GC dedup, and Tier-2
    consolidation MUST all key on this one function. *)
val claim_identity : fact -> string

(** {1 JSON codecs} *)

val provenance_event_to_json : provenance_event -> Yojson.Safe.t
val provenance_event_of_json : Yojson.Safe.t -> provenance_event option

val external_ref_to_json : external_ref -> Yojson.Safe.t
(** RFC-keeper-memory-panel-real-data: the on-disk external-ref JSON shape ([{ kind; id }]). Exported so
    the dashboard fact projection ([Server_dashboard_http_keeper_api.memory_os_fact_json])
    surfaces an external_ref byte-identical to storage, instead of re-inlining the
    shape in the server (SSOT). *)

val fact_to_json : fact -> Yojson.Safe.t
val fact_of_json : Yojson.Safe.t -> fact option

val episode_to_json : episode -> Yojson.Safe.t
val episode_of_json : Yojson.Safe.t -> episode option
