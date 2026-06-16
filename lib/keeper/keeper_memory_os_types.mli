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
    [Unknown] rate signals the librarian prompt needs a new arm. *)
type category =
  | Code_change
  | Fact
  | Preference
  | Blocker
  | Goal
  | Constraint
  | Ephemeral
  | Unknown of string

(** Canonical lowercase token for a category (round-trips with
    [category_of_string] for known variants; [Unknown s] yields [s]). *)
val category_to_string : category -> string

(** Parse a free-text category label (trimmed, case-insensitive on known tokens);
    anything outside the taxonomy becomes [Unknown] carrying the raw label. *)
val category_of_string : string -> category

(** Whether a category may be promoted into the shared semantic tier. Exhaustive
    over {!category}; only [Fact] and [Constraint] promote (preserving the prior
    ["fact";"constraint"] whitelist), so a new or typo'd category cannot silently
    join the promotable set — a future durable kind must be classified here at
    compile time. *)
val is_promotable : category -> bool

(** RFC-0247 §2.3 (forgetting): the hard-expiry timestamp a newly written fact of
    this category should carry, given [now]. Exhaustive over {!category}. Only
    [Ephemeral] (coordination boilerplate) gets a finite TTL — the brain's
    episodic memory that fades; durable knowledge ([Fact]/[Constraint]/…) and
    [Unknown] (conservative: we do not aggressively expire what we do not
    understand) return [None] and never hard-expire. This is the write-side
    producer that makes the previously-inert [valid_until] field (and the GC TTL
    pass) reachable. *)
val category_valid_until : now:float -> category -> float option

(** RFC-0247 §2.3: the expected lifetime, in retention cycles, a newly written
    fact of this category should carry — drives the per-fact truth-decay rate in
    the retention policy ([truth_lambda_for_fact]). Exhaustive over {!category}.
    [Ephemeral] decays fast (a few cycles); everything else returns [None] and
    decays at the slow default rate. Makes the previously-inert
    [expected_lifetime_cycles] field live. *)
val category_lifetime_cycles : category -> int option

(** A single semantic claim extracted from conversation history. *)
type fact =
  { claim : string
  ; confidence : float
  ; category : category
  ; source : provenance_event
  ; observed_by : string list
    (** RFC-0244 Tier 2 (shared semantic store) only: the sorted set of distinct
        keeper ids that have corroborated this claim. Empty for Tier-1 per-keeper
        facts (omitted from their JSON). Populated by the consolidator; a shared
        fact's confidence rises only per new distinct keeper. *)
  ; access_count : int
  ; first_seen : float
  ; last_accessed : float
  ; valid_until : float option
  ; stale_factor : float
  ; last_verified_at : float option
  ; expected_lifetime_cycles : int option
  ; schema_version : string
  }

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

(** {1 JSON codecs} *)

val provenance_event_to_json : provenance_event -> Yojson.Safe.t
val provenance_event_of_json : Yojson.Safe.t -> provenance_event option

val fact_to_json : fact -> Yojson.Safe.t
val fact_of_json : Yojson.Safe.t -> fact option

val episode_to_json : episode -> Yojson.Safe.t
val episode_of_json : Yojson.Safe.t -> episode option
