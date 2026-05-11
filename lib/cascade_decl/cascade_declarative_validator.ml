(** Declarative cascade config cross-reference validator (RFC-0058 v2).

    Validates 11 load-time invariants on a parsed [cascade_config]:
    R1: Every binding references an existing provider
    R2: Every binding references an existing model
    R3: Every alias references an existing binding
    R4: Alias max-input ≤ model max-context
    R5: Tier members resolve to valid bindings or aliases
    R6: Tier-group tiers reference existing tiers
    R7: Route targets reference existing tier-groups, tiers, or bindings
    R8: System targets reference existing bindings or aliases
    R9: At most one is-default=true per provider
    R10: Strategy-specific fields match the declared strategy
    R11: Binding max-concurrent required and positive (RFC-0058 §3.4) *)

open Cascade_declarative_types

type validation_error =
  { rule : string
  ; path : string
  ; message : string
  }
[@@deriving show]

(* --- Helpers --- *)

let provider_ids (cfg : cascade_config) : string list =
  List.map (fun (p : cascade_provider) -> p.id) cfg.providers
;;

let model_ids (cfg : cascade_config) : string list =
  List.map (fun (m : cascade_model_spec) -> m.id) cfg.models
;;

let binding_keys (cfg : cascade_config) : string list =
  List.map
    (fun (b : cascade_binding) -> Printf.sprintf "%s.%s" b.provider_id b.model_id)
    cfg.bindings
;;

let alias_keys (cfg : cascade_config) : string list =
  List.map
    (fun (a : cascade_alias) -> Printf.sprintf "%s.%s.%s" a.provider_id a.model_id a.name)
    cfg.aliases
;;

let tier_names (cfg : cascade_config) : string list =
  List.map (fun (t : cascade_tier) -> Printf.sprintf "tier.%s" t.name) cfg.tiers
;;

let tier_names_bare (cfg : cascade_config) : string list =
  List.map (fun (t : cascade_tier) -> t.name) cfg.tiers
;;

let tier_group_names (cfg : cascade_config) : string list =
  List.map
    (fun (g : cascade_tier_group) -> Printf.sprintf "tier-group.%s" g.name)
    cfg.tier_groups
;;

let is_member (lst : string list) (key : string) : bool = List.mem key lst

let err (rule : string) (path : string) (message : string) : validation_error list =
  [ { rule; path; message } ]
;;

(* --- R1: Binding → provider exists --- *)

let validate_binding_providers (cfg : cascade_config) : validation_error list =
  let pids = provider_ids cfg in
  List.filter_map
    (fun (b : cascade_binding) ->
       if is_member pids b.provider_id
       then None
       else
         Some
           { rule = "R1"
           ; path = Printf.sprintf "%s.%s" b.provider_id b.model_id
           ; message =
               Printf.sprintf "binding references unknown provider %S" b.provider_id
           })
    cfg.bindings
;;

(* --- R2: Binding → model exists --- *)

let validate_binding_models (cfg : cascade_config) : validation_error list =
  let mids = model_ids cfg in
  List.filter_map
    (fun (b : cascade_binding) ->
       if is_member mids b.model_id
       then None
       else
         Some
           { rule = "R2"
           ; path = Printf.sprintf "%s.%s" b.provider_id b.model_id
           ; message = Printf.sprintf "binding references unknown model %S" b.model_id
           })
    cfg.bindings
;;

(* --- R3: Alias → binding exists --- *)

let validate_alias_bindings (cfg : cascade_config) : validation_error list =
  let bkeys = binding_keys cfg in
  List.filter_map
    (fun (a : cascade_alias) ->
       let parent_key = Printf.sprintf "%s.%s" a.provider_id a.model_id in
       if is_member bkeys parent_key
       then None
       else
         Some
           { rule = "R3"
           ; path = Printf.sprintf "%s.%s.%s" a.provider_id a.model_id a.name
           ; message = Printf.sprintf "alias references unknown binding %S" parent_key
           })
    cfg.aliases
;;

(* --- R4: Alias max-input ≤ model max-context --- *)

let validate_alias_max_input (cfg : cascade_config) : validation_error list =
  List.filter_map
    (fun (a : cascade_alias) ->
       match a.max_input with
       | None -> None
       | Some max_input ->
         (match model_of_id cfg a.model_id with
          | None -> None (* R2 already catches this *)
          | Some m ->
            if max_input <= m.max_context
            then None
            else
              Some
                { rule = "R4"
                ; path =
                    Printf.sprintf "%s.%s.%s.max-input" a.provider_id a.model_id a.name
                ; message =
                    Printf.sprintf
                      "alias max-input %d exceeds model %S max-context %d"
                      max_input
                      a.model_id
                      m.max_context
                }))
    cfg.aliases
;;

(* --- R5: Tier members resolve to binding or alias --- *)

let validate_tier_members (cfg : cascade_config) : validation_error list =
  let bkeys = binding_keys cfg in
  let akeys = alias_keys cfg in
  let all_valid = bkeys @ akeys in
  List.concat_map
    (fun (t : cascade_tier) ->
       List.filter_map
         (fun member ->
            if is_member all_valid member
            then None
            else
              Some
                { rule = "R5"
                ; path = Printf.sprintf "tier.%s.members" t.name
                ; message =
                    Printf.sprintf
                      "tier member %S does not resolve to any binding or alias"
                      member
                })
         t.members)
    cfg.tiers
;;

(* --- R6: Tier-group tiers reference existing tiers --- *)

let validate_tier_group_refs (cfg : cascade_config) : validation_error list =
  let tnames = tier_names_bare cfg in
  List.concat_map
    (fun (g : cascade_tier_group) ->
       List.filter_map
         (fun tier_name ->
            if is_member tnames tier_name
            then None
            else
              Some
                { rule = "R6"
                ; path = Printf.sprintf "tier-group.%s.tiers" g.name
                ; message =
                    Printf.sprintf "tier-group references unknown tier %S" tier_name
                })
         g.tiers)
    cfg.tier_groups
;;

(* --- R7: Route targets exist --- *)

let validate_route_targets (cfg : cascade_config) : validation_error list =
  let tg_names = tier_group_names cfg in
  let t_names = tier_names cfg in
  let bkeys = binding_keys cfg in
  let akeys = alias_keys cfg in
  let all_targets = tg_names @ t_names @ bkeys @ akeys in
  List.filter_map
    (fun (r : cascade_route) ->
       if is_member all_targets r.target
       then None
       else
         Some
           { rule = "R7"
           ; path = Printf.sprintf "routes.%s.target" r.name
           ; message =
               Printf.sprintf
                 "route target %S does not resolve to any tier-group, tier, binding, or \
                  alias"
                 r.target
           })
    cfg.routes
;;

(* --- R8: System targets exist --- *)

let validate_system_targets (cfg : cascade_config) : validation_error list =
  let bkeys = binding_keys cfg in
  let akeys = alias_keys cfg in
  let all_valid = bkeys @ akeys in
  List.filter_map
    (fun (r : cascade_route) ->
       if is_member all_valid r.target
       then None
       else
         Some
           { rule = "R8"
           ; path = Printf.sprintf "system.%s.target" r.name
           ; message =
               Printf.sprintf
                 "system target %S does not resolve to any binding or alias"
                 r.target
           })
    cfg.system_targets
;;

(* --- R9: At most one is-default per provider --- *)

let validate_single_default (cfg : cascade_config) : validation_error list =
  let defaults_by_provider =
    List.filter_map
      (fun (b : cascade_binding) -> if b.is_default then Some b.provider_id else None)
      cfg.bindings
  in
  let counts =
    List.sort String.compare defaults_by_provider
    |> List.filter (fun x ->
      let count = List.length (List.filter (fun y -> y = x) defaults_by_provider) in
      count > 1)
    |> List.sort_uniq String.compare
  in
  List.concat_map
    (fun pid ->
       err
         "R9"
         (Printf.sprintf "%s.*.is-default" pid)
         (Printf.sprintf "provider %S has multiple bindings with is-default=true" pid))
    counts
;;

(* --- R10: Strategy-specific fields match declared strategy --- *)

let validate_strategy_fields (cfg : cascade_config) : validation_error list =
  List.concat_map
    (fun (t : cascade_tier) ->
       let path = Printf.sprintf "tier.%s" t.name in
       let mismatch_errors field_name expected_strategy =
         err
           "R10"
           (Printf.sprintf "%s.%s" path field_name)
           (Printf.sprintf
              "%s is only valid with strategy %S, but tier uses %s"
              field_name
              expected_strategy
              (show_cascade_strategy t.strategy))
       in
       let cycle_errs =
         match t.cycle_policy, t.strategy with
         | Some _, Circuit_breaker_cycling -> []
         | Some _, _ -> mismatch_errors "cycle-policy" "circuit_breaker_cycling"
         | None, _ -> []
       in
       let sticky_errs =
         match t.sticky_ttl_ms, t.strategy with
         | Some _, Sticky -> []
         | Some _, _ -> mismatch_errors "sticky-ttl-ms" "sticky"
         | None, _ -> []
       in
       let scoring_errs =
         match t.scoring_params, t.strategy with
         | Some _, Weighted_random -> []
         | Some _, _ -> mismatch_errors "scoring-params" "weighted_random"
         | None, _ -> []
       in
       cycle_errs @ sticky_errs @ scoring_errs)
    cfg.tiers
;;

(* --- R11: Binding max-concurrent is required and positive ---

   RFC-0058 §3.4 declares `max-concurrent` mandatory. The parser keeps
   a sentinel value (0) when the field is missing so that this rule can
   flag the omission instead of silently throttling the binding to 1.

   Run unconditionally as part of {!validate} (RFC-0058 Phase 5.5
   unified the previous laxer/strict surfaces — every cascade.toml load
   site now enforces capacity declaration). *)

let validate_binding_capacity (cfg : cascade_config) : validation_error list =
  List.filter_map
    (fun (b : cascade_binding) ->
       if b.max_concurrent > 0
       then None
       else
         Some
           { rule = "R11"
           ; path = Printf.sprintf "%s.%s.max-concurrent" b.provider_id b.model_id
           ; message =
               "binding max-concurrent is required and must be > 0 (RFC-0058 §3.4); add \
                `max-concurrent = N` to this binding"
           })
    cfg.bindings
;;

(* --- Top-level validation --- *)

let validate (cfg : cascade_config) : validation_error list =
  validate_binding_providers cfg
  @ validate_binding_models cfg
  @ validate_alias_bindings cfg
  @ validate_alias_max_input cfg
  @ validate_tier_members cfg
  @ validate_tier_group_refs cfg
  @ validate_route_targets cfg
  @ validate_system_targets cfg
  @ validate_single_default cfg
  @ validate_strategy_fields cfg
  @ validate_binding_capacity cfg
;;
