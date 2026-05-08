(** CascadeRef — Group/Item hierarchy types for cascade routing.

    RFC-0041: Cascade Routing Architecture — Group/Item Hierarchy
    with Health-Aware Fallback.

    This module defines the data model for cascades as hierarchical
    structures: cascade_profile -> cascade_group -> cascade_item.
    The previous flat [cascade_name:string] is migrated to this model
    with backward compatibility: a plain string becomes a single-group,
    single-item profile. *)

(** A single callable item within a cascade group.
    Represents one provider+model combination with its routing metadata. *)
type cascade_item = {
  id : string;
  provider : string;
  model : string;
  timeout_ms : int;
  priority : int;  (** Lower value = higher priority. Used by [Priority] strategy. *)
}

(** Strategy for ordering items within a group during traversal. *)
type traversal_strategy =
  | Priority  (** Select by priority ascending (lower value first). *)
  | RoundRobin  (** Cycle through items in order. *)
  | Random  (** Random selection. *)

(** A group of items with a traversal strategy and optional fallback chain.
    Groups form a directed graph via [fallback_group]; cycle detection is
    the responsibility of the router. *)
type cascade_group = {
  name : string;
  items : cascade_item list;
  strategy : traversal_strategy;
  fallback_group : string option;  (** [None] terminates the fallback chain. *)
}

(** A named cascade profile containing one or more groups.
    This is the top-level configuration object loaded from cascade.json. *)
type cascade_profile = {
  name : string;
  groups : cascade_group list;
}

(** A reference to a specific position within a cascade profile.
    Used by keeper_meta and registry_entry to pin the keeper's routing
    context. [item = None] means "let the group's strategy decide". *)
type cascade_ref = {
  group : string;
  item : string option;
}

(** Logical use cases for cascade routing.  Moved here from [Cascade_routes]
    to break the circular dependency with [Keeper_cascade_profile]. *)
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

(* ------------------------------------------------------------------ *)
(* JSON serialization helpers                                         *)
(* ------------------------------------------------------------------ *)

let traversal_strategy_to_json = function
  | Priority -> `String "priority"
  | RoundRobin -> `String "round_robin"
  | Random -> `String "random"

let traversal_strategy_of_json = function
  | `String "priority" -> Some Priority
  | `String "round_robin" -> Some RoundRobin
  | `String "random" -> Some Random
  | _ -> None

let cascade_item_to_json (item : cascade_item) : Yojson.Safe.t =
  `Assoc [
    "id", `String item.id;
    "provider", `String item.provider;
    "model", `String item.model;
    "timeout_ms", `Int item.timeout_ms;
    "priority", `Int item.priority;
  ]

let cascade_item_of_json (json : Yojson.Safe.t) : cascade_item option =
  match json with
  | `Assoc fields ->
      let find_str key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let find_int key =
        match List.assoc_opt key fields with
        | Some (`Int n) -> Some n
        | _ -> None
      in
      (match find_str "id", find_str "provider", find_str "model",
            find_int "timeout_ms", find_int "priority" with
       | Some id, Some provider, Some model, Some timeout_ms, Some priority ->
           Some { id; provider; model; timeout_ms; priority }
       | _ -> None)
  | _ -> None

let cascade_group_to_json (group : cascade_group) : Yojson.Safe.t =
  `Assoc [
    "name", `String group.name;
    "items", `List (List.map cascade_item_to_json group.items);
    "strategy", traversal_strategy_to_json group.strategy;
    "fallback_group",
      (match group.fallback_group with
       | Some name -> `String name
       | None -> `Null);
  ]

let cascade_group_of_json (json : Yojson.Safe.t) : cascade_group option =
  match json with
  | `Assoc fields ->
      let find_str key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let name_opt = find_str "name" in
      let strategy_opt =
        match List.assoc_opt "strategy" fields with
        | Some s -> traversal_strategy_of_json s
        | None -> None
      in
      let items =
        match List.assoc_opt "items" fields with
        | Some (`List arr) ->
            List.filter_map cascade_item_of_json arr
        | _ -> []
      in
      let fallback_group =
        match List.assoc_opt "fallback_group" fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      (match name_opt, strategy_opt with
       | Some name, Some strategy -> Some { name; items; strategy; fallback_group }
       | _ -> None)
  | _ -> None

let cascade_profile_to_json (profile : cascade_profile) : Yojson.Safe.t =
  `Assoc [
    "name", `String profile.name;
    "groups", `List (List.map cascade_group_to_json profile.groups);
  ]

let cascade_profile_of_json (json : Yojson.Safe.t) : cascade_profile option =
  match json with
  | `Assoc fields ->
      let name_opt =
        match List.assoc_opt "name" fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let groups =
        match List.assoc_opt "groups" fields with
        | Some (`List arr) -> List.filter_map cascade_group_of_json arr
        | _ -> []
      in
      (match name_opt with
       | Some name -> Some { name; groups }
       | None -> None)
  | _ -> None

let cascade_ref_to_json (ref_ : cascade_ref) : Yojson.Safe.t =
  `Assoc [
    "group", `String ref_.group;
    "item",
      (match ref_.item with
       | Some id -> `String id
       | None -> `Null);
  ]

let cascade_ref_of_json (json : Yojson.Safe.t) : cascade_ref option =
  match json with
  | `Assoc fields ->
      let group_opt =
        match List.assoc_opt "group" fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let item =
        match List.assoc_opt "item" fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      (match group_opt with
       | Some group -> Some { group; item }
       | None -> None)
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Migration helper: string -> cascade_ref                            *)
(* ------------------------------------------------------------------ *)

(** Convert a legacy cascade_name string into a cascade_ref.
    The string is treated as both the group name and (if non-empty)
    the single item id. This preserves backward compatibility with
    existing keeper configurations that use flat cascade_name strings.

    Empty string -> { group = ""; item = None } (unconfigured keeper). *)
let cascade_ref_of_string (cascade_name : string) : cascade_ref =
  if String.equal cascade_name "" then
    { group = ""; item = None }
  else
    { group = cascade_name; item = Some cascade_name }

(* ------------------------------------------------------------------ *)
(* Lookup helpers                                                     *)
(* ------------------------------------------------------------------ *)

(** Find a group by name within a profile. *)
let find_group (profile : cascade_profile) (group_name : string)
    : cascade_group option =
  List.find_opt (fun (g : cascade_group) -> String.equal g.name group_name) profile.groups

(** Find an item by id within a group. *)
let find_item (group : cascade_group) (item_id : string)
    : cascade_item option =
  List.find_opt (fun item -> String.equal item.id item_id) group.items

(** Order items according to the group's traversal strategy. *)
let order_items (strategy : traversal_strategy) (items : cascade_item list)
    : cascade_item list =
  match strategy with
  | Priority -> List.sort (fun a b -> Int.compare a.priority b.priority) items
  | RoundRobin -> items
  | Random -> items  (* Randomization applied at selection time, not here. *)
