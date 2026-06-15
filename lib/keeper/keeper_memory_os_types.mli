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

(** A single semantic claim extracted from conversation history. *)
type fact =
  { claim : string
  ; confidence : float
  ; category : string
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
