(** CascadeRef — Group/Item hierarchy types for cascade routing (RFC-0041).

    Defines the 3-layer cascade data model:
    - [cascade_profile]: top-level named configuration
    - [cascade_group]: named collection of items + traversal strategy
    - [cascade_item]: single callable provider+model combination
    - [cascade_ref]: keeper's routing position (group + optional pinned item)

    Backward compatibility: existing [cascade_name:string] configurations
    are migrated via [cascade_ref_of_string] to a single-group,
    single-item profile. *)

(** A single callable item within a cascade group. *)
type cascade_item = {
  id : string;
  provider : string;
  model : string;
  timeout_ms : int;
  priority : int;  (** Lower value = higher priority. *)
}

(** Strategy for ordering items within a group during traversal. *)
type traversal_strategy =
  | Priority  (** Select by priority ascending. *)
  | RoundRobin  (** Cycle through items in order. *)
  | Random  (** Random selection. *)

(** A group of items with a traversal strategy and optional fallback link. *)
type cascade_group = {
  name : string;
  items : cascade_item list;
  strategy : traversal_strategy;
  fallback_group : string option;  (** [None] terminates the chain. *)
}

(** A named cascade profile containing one or more groups. *)
type cascade_profile = {
  name : string;
  groups : cascade_group list;
}

(** A reference to a specific position within a cascade profile.
    [item = None] means "let the group's strategy decide". *)
type cascade_ref = {
  group : string;
  item : string option;
}

(** Catalog-aware cascade name after point-of-use runtime normalization.
    Lives at this leaf module so [Cascade_strategy] can carry it without
    pulling in [Keeper_cascade_profile] (which depends on
    [Cascade_catalog_runtime]). *)
type runtime_name = Runtime_name of string

val runtime_name_to_string : runtime_name -> string

(** {1 JSON serialization} *)

val traversal_strategy_to_json : traversal_strategy -> Yojson.Safe.t
val traversal_strategy_of_json : Yojson.Safe.t -> traversal_strategy option

val cascade_item_to_json : cascade_item -> Yojson.Safe.t
val cascade_item_of_json : Yojson.Safe.t -> cascade_item option

val cascade_group_to_json : cascade_group -> Yojson.Safe.t
val cascade_group_of_json : Yojson.Safe.t -> cascade_group option

val cascade_profile_to_json : cascade_profile -> Yojson.Safe.t
val cascade_profile_of_json : Yojson.Safe.t -> cascade_profile option

val cascade_ref_to_json : cascade_ref -> Yojson.Safe.t
val cascade_ref_of_json : Yojson.Safe.t -> cascade_ref option

(** {1 Migration helper} *)

(** Convert a legacy cascade_name string into a cascade_ref.
    The string becomes both the group name and (if non-empty) the item id.
    Empty string produces an unconfigured reference. *)
val cascade_ref_of_string : string -> cascade_ref

(** {1 Lookup helpers} *)

(** Find a group by name within a profile. *)
val find_group : cascade_profile -> string -> cascade_group option

(** Find an item by id within a group. *)
val find_item : cascade_group -> string -> cascade_item option

(** Order items according to the group's traversal strategy.
    [Random] returns items unchanged; randomization is applied at
    selection time. *)
val order_items : traversal_strategy -> cascade_item list -> cascade_item list

(** {1 Logical use routing} *)

type logical_use =
  | Keeper_turn
  | Phase_recovery
  | Phase_buffer
  | Tool_required
  | Governance_judge
  | Operator_judge
  | Cross_verifier
  | Verifier
  | Autoresearch
  | Adversarial_reviewer
  | Auto_responder
  | Routing
  | Openai_compat
  | Persona_generation
  | Provider_benchmark
  | Simple_task
  | Moderate_task
  | Complex_task
  | Tool_rerank_use
