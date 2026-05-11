(** Config-driven mapping from logical cascade usages to live profile names.

    Code should name the usage it needs (for example [Governance_judge]) and
    let [cascade.toml]/[cascade.json] decide which concrete profile handles it.
    This keeps profiles as configuration data instead of scattering profile
    literals through runtime call sites. *)

type logical_use = Cascade_ref.logical_use =
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

val logical_use_key : logical_use -> string
val logical_use_of_string_opt : string -> logical_use option

val all_logical_uses : logical_use list
(** Logical call-site uses known by the route registry. *)

val known_route_keys : string list
(** Stable keys accepted under [routes]. *)

val cascade_name_for_use : ?config_path:string -> logical_use -> string
(** Resolve a logical use through [routes.<logical_use_key>] in the live
    cascade catalog.  Falls back to the first catalog entry when no route
    binding is declared.  Raises [Failure] when the catalog itself is
    empty — [Cascade_catalog_runtime.validate_path_result] is the boot-time
    boundary that prevents this state from being reached at runtime. *)

val route_bindings_from_json : Yojson.Safe.t -> (string * string) list
(** Decode the [routes] object of a materialized cascade JSON into a
    [(key, target)] association list. Accepts both the legacy
    encoding [routes.X = "Y"] and the RFC-0058 sub-table encoding
    [\[routes.X\] target = "Y"]. Exposed for regression testing of
    the dual-form decoder. *)

val configured_route_targets : ?config_path:string -> unit -> string list
(** Unique non-empty profile names referenced by [routes]. *)

val configured_route_keys : ?config_path:string -> unit -> string list
(** Unique keys declared by [routes]. *)

val configured_unknown_route_keys : ?config_path:string -> unit -> string list
(** Declared route keys that are not part of {!known_route_keys}. *)

val fallback_name_for_catalog : logical_use -> catalog:string list -> string
(** Catalog-only fallback used by string normalizers that already have an
    explicit active profile list.  Returns the first catalog entry; raises
    [Failure] when [catalog] is empty. *)
