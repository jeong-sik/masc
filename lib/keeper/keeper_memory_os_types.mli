(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    This module defines the canonical fact and episode records used by
    the librarian, the I/O layer, and Memory projections. All records
    carry a [schema_version] to support future migrations. *)

(** Current schema version written to disk. *)
val schema_version : string

(** RFC-0244 Tier 2: reserved keeper id for the shared semantic store
    (keepers/_shared.facts.jsonl). Not a legal keeper name, so no real keeper
    collides; the consolidator filters it out of its source keeper list. *)
val shared_store_id : string

(** Canonical JSON wire field names for Memory OS persistence and librarian
    ingestion. The schema module owns these strings so parser, retry prompt,
    persistence codec, and tests share one source. *)
val wire_field_trace_id : string
val wire_field_turn : string
val wire_field_tool_call_id : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_source : string
val wire_field_first_seen : string
val wire_field_valid_until : string
val wire_field_last_verified_at : string
val wire_field_observed_by : string
val wire_field_claim_id : string
val wire_field_claim_kind : string
val wire_field_schema_version : string
val wire_field_generation : string
val wire_field_episode_summary : string
val wire_field_claims : string
val wire_field_open_items : string
val wire_field_constraints : string
val wire_field_preserved_tool_refs : string
val wire_field_source_turn : string
val wire_field_source_tool_call_id : string
val wire_field_source_turn_range : string
val wire_field_lo : string
val wire_field_hi : string
val wire_field_created_at : string
val wire_field_terminal_marker : string

(** Episode-object fields accepted from the librarian and rendered in retry
    prompts. [wire_field_schema_version] is accepted separately for compatibility
    but is not requested from the provider. *)
val wire_librarian_episode_fields : string list

(** Claim-object fields accepted from the librarian and rendered in retry
    prompts. *)
val wire_librarian_claim_fields : string list

(** Source attribution for a single extracted fact. *)
type provenance_event =
  { trace_id : string
  ; turn : int
  ; tool_call_id : string option
  }

(** Librarian taxonomy as a closed sum. The LLM-produced label is parsed once at
    the producer boundary; [Unknown] preserves labels outside the current
    vocabulary. Categories are model context only and do not grant retention,
    expiry, or promotion authority. *)
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

(** All closed taxonomy categories that can be emitted by the librarian prompt.
    [Unknown _] is excluded because it carries an arbitrary producer label. *)
val all_categories : category list

(** Parse a free-text category label (trimmed, case-insensitive on known tokens);
    anything outside the taxonomy becomes [Unknown] carrying the raw label. *)
val category_of_string : string -> category

(** Producer-emitted origin tag, orthogonal to {!category}. It is parsed once at
    the librarian boundary and preserved as model context; it does not create a
    validity horizon or promotion hierarchy. *)
type claim_kind =
  | Self_observation
  | External_state
  | Durable_knowledge
  | Diagnostic

(** Canonical lowercase token (round-trips with [claim_kind_of_string]). *)
val claim_kind_to_string : claim_kind -> string

(** All closed claim-kind tokens. *)
val all_claim_kinds : claim_kind list

(** Claim-kind tokens the librarian prompt should ask a provider to emit.
    [Diagnostic] is system-authored and intentionally excluded from the LLM
    retry contract. *)
val librarian_claim_kinds : claim_kind list

(** Parse a claim-kind token. Persisted invalid labels are rejected rather than
    silently treated as absent. *)
val claim_kind_of_string : string -> claim_kind option

(** A single semantic claim extracted from conversation history.

    RFC-0247 (purge): the fact carries only structure — claim, typed category,
    provenance, the distinct-keeper corroboration set, and the timestamps. The
    deleted fields (confidence, access_count, last_accessed, stale_factor,
    expected_lifetime_cycles) fed the removed composite score; a fact's value is
    the librarian's judgment, not a number on the row. *)
type fact =
  { claim : string
  ; category : category
  ; claim_kind : claim_kind option
    (** Producer-emitted origin tag, orthogonal to [category]. It is model
        context only; it does not create a lifetime or a
        promotion hierarchy. Omitted from JSON when [None]. *)
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
    (** Optional producer-emitted stable conclusion id. It is preserved exactly;
        absent ids use exact observation identity, never normalized prose. *)
  }

(** The exact producer-supplied hard-expiry horizon. No category, claim-kind, or
    timestamp-derived fallback is applied. *)
val fact_effective_valid_until : fact -> float option

(** Whether a fact's hard-expiry horizon still admits it at [now]. Facts with no
    effective [valid_until] are durable and current. *)
val fact_is_current : now:float -> fact -> bool

(** Partition facts into [(live, expired)] at [now] using only the exact stored
    [valid_until]. Facts with [None] are always in [live]. *)
val partition_expired : now:float -> fact list -> fact list * fact list

(** Presentation timestamp: [last_verified_at] if set, else [first_seen]. Recall
    and dashboard share it for ordering, but it is not an expiry or truth
    boundary. *)
val reference_time : fact -> float

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

(** Producer identity SSOT. A non-empty [claim_id] is preserved exactly. When it
    is absent, identity uses the exact source event plus exact claim payload, so
    code never semantically normalizes or classifies prose. *)
val claim_identity : fact -> string

(** {1 JSON codecs} *)

val provenance_event_to_json : provenance_event -> Yojson.Safe.t
val provenance_event_of_json : Yojson.Safe.t -> provenance_event option

val fact_to_json : fact -> Yojson.Safe.t
val fact_of_json : Yojson.Safe.t -> fact option

val episode_to_json : episode -> Yojson.Safe.t
val episode_of_json : Yojson.Safe.t -> episode option
