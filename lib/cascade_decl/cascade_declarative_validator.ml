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
    R11: Binding max-concurrent required and positive (RFC-0058 §3.4)
    R12: Protocol ↔ transport consistency (RFC-0058 §2.1) *)

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

(* Build a name-keyed Hashtbl once for O(1) membership.  Eight
   validator rules below (R1-R8) used to do [List.mem key list]
   per filtered item, paying O(items × |list|).  Several rules also
   concatenate sub-lists ([bkeys @ akeys], etc.) producing 50-100
   element lists that compound the cost.  Each validator now builds
   the set once and uses [Hashtbl.mem] per check. *)
let name_set (names : string list) : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length names) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) names;
  tbl

let err (rule : string) (path : string) (message : string) : validation_error list =
  [ { rule; path; message } ]
;;

(* --- R1: Binding → provider exists --- *)

let validate_binding_providers (cfg : cascade_config) : validation_error list =
  let pids_set = name_set (provider_ids cfg) in
  List.filter_map
    (fun (b : cascade_binding) ->
       if Hashtbl.mem pids_set b.provider_id
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
  let mids_set = name_set (model_ids cfg) in
  List.filter_map
    (fun (b : cascade_binding) ->
       if Hashtbl.mem mids_set b.model_id
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
  let bkeys_set = name_set (binding_keys cfg) in
  List.filter_map
    (fun (a : cascade_alias) ->
       let parent_key = Printf.sprintf "%s.%s" a.provider_id a.model_id in
       if Hashtbl.mem bkeys_set parent_key
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
  let all_valid_set = name_set (binding_keys cfg @ alias_keys cfg) in
  List.concat_map
    (fun (t : cascade_tier) ->
       List.filter_map
         (fun member ->
            if Hashtbl.mem all_valid_set member
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
  let tnames_set = name_set (tier_names_bare cfg) in
  List.concat_map
    (fun (g : cascade_tier_group) ->
       List.filter_map
         (fun tier_name ->
            if Hashtbl.mem tnames_set tier_name
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
  let all_targets_set =
    name_set
      (tier_group_names cfg @ tier_names cfg
      @ binding_keys cfg @ alias_keys cfg)
  in
  List.filter_map
    (fun (r : cascade_route) ->
       if Hashtbl.mem all_targets_set r.target
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
  let all_valid_set = name_set (binding_keys cfg @ alias_keys cfg) in
  List.filter_map
    (fun (r : cascade_route) ->
       if Hashtbl.mem all_valid_set r.target
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
   unified the previous laxer/strict surfaces). The validator itself
   is not auto-invoked by the parser hotpath — callers that opt into
   validation (e.g. `cascade_catalog_validator`, declarative-config
   tests) now get R11 enforcement; the parser's tolerant load path
   is unchanged. *)

(* --- R12: Protocol ↔ transport consistency ---

   A protocol string ending in "-cli" must pair with a Cli transport,
   and one ending in "-http" must pair with an Http transport.
   This catches misconfigurations where, e.g., a CLI provider is
   accidentally given an HTTP endpoint. *)

let validate_protocol_transport (cfg : cascade_config) : validation_error list =
  List.filter_map
    (fun (p : cascade_provider) ->
       let path = Printf.sprintf "providers.%s.protocol" p.id in
       let expected_transport =
         if String.length p.protocol >= 4
            && String.sub p.protocol (String.length p.protocol - 4) 4 = "-cli"
         then Some "Cli"
         else if String.length p.protocol >= 5
                 && String.sub p.protocol (String.length p.protocol - 5) 5 = "-http"
         then Some "Http"
         else None
       in
       match expected_transport with
       | None -> None
       | Some expected ->
         (match p.transport with
          | Cli _ when expected = "Cli" -> None
          | Http _ when expected = "Http" -> None
          | Cli _ ->
            Some
              { rule = "R12"
              ; path
              ; message =
                  Printf.sprintf
                    "protocol %S implies Http transport, but transport is Cli"
                    p.protocol
              }
          | Http _ ->
            Some
              { rule = "R12"
              ; path
              ; message =
                  Printf.sprintf
                    "protocol %S implies Cli transport, but transport is Http"
                    p.protocol
              }))
    cfg.providers
;;

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
  @ validate_protocol_transport cfg
;;
