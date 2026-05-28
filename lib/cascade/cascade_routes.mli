(** Config-driven mapping from logical cascade usages to live profile names.

    Code should name the usage it needs (for example [Governance_judge]) and
    let [cascade.toml] decide which concrete profile handles it.
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

(** #19327/#19340 follow-up: [cascade_name_for_use] moved to
    {!Cascade_routes_resolve} so this module no longer depends on
    {!Cascade_catalog_runtime}.  Callers that need catalog cross-check use
    the new module; callers that only need configured route data use
    {!configured_route_bindings} / {!configured_route_targets} here. *)

val configured_route_bindings :
  ?config_path:string -> unit -> (string * string) list
(** [(route_key, target_profile_name)] association list parsed from
    [\[routes.*\]] in the live cascade config.  No catalog dependency. *)

val route_bindings_from_json : Yojson.Safe.t -> (string * string) list
(** Decode the [routes] object of the in-memory cascade view into a
    [(key, target)] association list. Only the RFC-0058 sub-table
    encoding [\[routes.X\] target = "Y"] is accepted. *)

val configured_route_targets : ?config_path:string -> unit -> string list
(** Unique non-empty profile names referenced by [routes]. *)

val configured_route_keys : ?config_path:string -> unit -> string list
(** Unique keys declared by [routes]. *)

val configured_unknown_route_keys : ?config_path:string -> unit -> string list
(** Declared route keys that are not part of {!known_route_keys}. *)

val fallback_name_for_catalog : logical_use -> catalog:string list -> string
(** Catalog-only fallback used by string normalizers that already have an
    explicit active profile list.  Returns the first catalog entry, or the
    canonical [route.<key>] name when [catalog] is empty. *)

(** Reused by {!Cascade_routes_resolve}. *)
val warn_unvalidated_route_target_once :
  route_key:string -> target:string -> fallback:string -> unit

val warn_invalid_route_target_once :
  route_key:string -> target:string -> fallback:string -> unit
