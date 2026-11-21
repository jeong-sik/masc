(** Types and strict JSON codecs for MASC lock-free MVCC World Memory.

    World Memory stores shared cross-Keeper facts with explicit provenance back
    to proposing Keepers and local Memory OS fact IDs, typed relational edges
    ([Supersedes | Refines | Contradicts | Synthesizes_from]), closed algebraic
    lifecycle states ([Working | Consolidated | Canonical | Superseded | Molted]),
    and a unified typed index spanning Wiki pages, durable Artifacts, and MCP
    Resources.

    No wall-clock TTL expiry and no numeric importance scoring exist here:
    every lifecycle transition is strictly declarative. *)

open Keeper_memory_os_types

type lifecycle =
  | Working
  | Consolidated
  | Canonical
  | Superseded
  | Molted

val lifecycle_to_string : lifecycle -> string
val lifecycle_of_string : string -> lifecycle option
val is_active_lifecycle : lifecycle -> bool

type invalid_lifecycle_transition =
  { from : lifecycle
  ; to_ : lifecycle
  ; reason : string
  }

val transition_lifecycle
  :  from:lifecycle
  -> to_:lifecycle
  -> (lifecycle, invalid_lifecycle_transition) result

val invalid_lifecycle_transition_to_string : invalid_lifecycle_transition -> string

type edge_kind =
  | Supersedes
  | Refines
  | Contradicts
  | Synthesizes_from

val edge_kind_to_string : edge_kind -> string
val edge_kind_of_string : string -> edge_kind option

type provenance =
  | Proposed_by of
      { keeper_id : string
      ; source_fact_ids : string list
      }
  | Cross_keeper_synthesized of
      { keeper_ids : string list
      ; source_world_fact_ids : string list
      }

val provenance_to_json : provenance -> Yojson.Safe.t
val provenance_of_json : Yojson.Safe.t -> (provenance, string) result

type world_fact =
  { fact_id : string
  ; claim : string
  ; category : category
  ; facets : string list
  ; scope : string
  ; provenance : provenance
  ; lifecycle : lifecycle
  ; revision : int
  ; created_seq : int
  ; updated_seq : int
  }

(** Deterministic content-addressed world fact ID derived from [(scope, claim)]. *)
val fact_id_of_claim : scope:string -> claim:string -> string

val world_fact_to_json : world_fact -> Yojson.Safe.t

type world_edge =
  { from_fact_id : string
  ; to_fact_id : string
  ; kind : edge_kind
  ; reason : string
  ; created_seq : int
  }

val world_edge_to_json : world_edge -> Yojson.Safe.t

type index_entry_kind =
  | Wiki_page
  | Artifact
  | Mcp_resource

val index_entry_kind_to_string : index_entry_kind -> string
val index_entry_kind_of_string : string -> index_entry_kind option

type index_entry =
  { entry_id : string
  ; kind : index_entry_kind
  ; title : string
  ; uri : string
  ; summary : string
  ; facets : string list
  ; sha256 : string option
  ; updated_seq : int
  }

val index_entry_to_json : index_entry -> Yojson.Safe.t

type world_digest =
  { digest_revision : int
  ; digest_sha256 : string
  ; fact_count : int
  ; canonical_count : int
  ; wiki_count : int
  ; artifact_count : int
  ; resource_count : int
  ; rendered : string
  }

val world_digest_to_json : world_digest -> Yojson.Safe.t

type change_event_kind =
  | Fact_upserted
  | Fact_lifecycle_changed
  | Edge_added
  | Index_upserted
  | Digest_committed

val change_event_kind_to_string : change_event_kind -> string
val change_event_kind_of_string : string -> change_event_kind option

type change_event =
  { seq : int
  ; kind : change_event_kind
  ; target_id : string
  ; summary : string
  ; actor : string
  ; recorded_at : float
  }

val change_event_to_json : change_event -> Yojson.Safe.t

type search_hit =
  { entry_type : string
  ; target_id : string
  ; title : string
  ; body : string
  ; score : float
  }

val search_hit_to_json : search_hit -> Yojson.Safe.t
