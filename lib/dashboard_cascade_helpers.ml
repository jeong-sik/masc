module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Pure helpers shared across the dashboard_cascade projection submodules:
    JSON shape primitives, public profile name normalization, validation
    rejection parsing, and retention/query envelope builders. No side
    effects beyond reading [Cascade_toml_materializer.source_info] when
    [source_info] is invoked. *)

module CC = Cascade_config
module StringSet = Set.Make (String)

let now_iso () = Masc_domain.now_iso ()

let json_string_option = function
  | Some value -> `String value
  | None -> `Null
;;

let candidate_to_json (c : CC.candidate_info) : Yojson.Safe.t =
  `Assoc
    [ "model", `String c.model_string
    ; "display_model", `String c.display_model_string
    ; "provider_name", json_string_option c.provider_name
    ; "display_provider_name", json_string_option c.display_provider_name
    ; "runtime_kind", json_string_option c.runtime_kind
    ; "expanded_models", `List (List.map (fun value -> `String value) c.expanded_models)
    ; "config_weight", `Int c.config_weight
    ; "effective_weight", `Int c.effective_weight
    ; "success_rate", `Float c.success_rate
    ; "in_cooldown", `Bool c.in_cooldown
    ]
;;

let source_to_string = function
  | CC.Named -> "named"
  | CC.Default_fallback -> "default_fallback"
  | CC.Hardcoded_defaults -> "hardcoded_defaults"
  | CC.Load_failed _ -> "load_failed"
;;

let string_list_to_json values = `List (List.map (fun value -> `String value) values)

let invalid_profile_to_json ((name, errors) : string * string list) =
  `Assoc [ "name", `String name; "errors", string_list_to_json errors ]
;;

let public_cascade_profile_name name =
  let tier_group_prefix = "tier-group." in
  let tier_prefix = "tier." in
  if String.starts_with ~prefix:tier_group_prefix name then
    String.sub name (String.length tier_group_prefix)
      (String.length name - String.length tier_group_prefix)
  else if String.starts_with ~prefix:tier_prefix name then
    String.sub name (String.length tier_prefix)
      (String.length name - String.length tier_prefix)
  else
    name
;;

let public_profile_names names =
  names |> List.map public_cascade_profile_name |> List.sort_uniq String.compare
;;

let invalid_profiles_with_internal_names profiles =
  profiles
  |> List.fold_left
       (fun acc (name, errors) ->
          let prior =
            match List.assoc_opt name acc with
            | Some prior -> prior
            | None -> []
          in
          (name, prior @ errors) :: List.remove_assoc name acc)
       []
  |> List.map (fun (name, errors) -> (name, List.sort_uniq String.compare errors))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
;;

let qualified_profile_candidates name =
  let trimmed = String.trim name in
  if String.starts_with ~prefix:"tier-group." trimmed
     || String.starts_with ~prefix:"tier." trimmed
  then [ trimmed ]
  else [ "tier-group." ^ trimmed; "tier." ^ trimmed; trimmed ]
;;

let invalid_assignment_reasons ~known_internal_profiles ~invalid_profiles name =
  let rec first_declared_candidate = function
    | [] -> None
    | candidate :: rest ->
      if List.mem candidate known_internal_profiles
      then List.assoc_opt candidate invalid_profiles
      else if List.mem_assoc candidate invalid_profiles
      then List.assoc_opt candidate invalid_profiles
      else first_declared_candidate rest
  in
  first_declared_candidate (qualified_profile_candidates name)
;;

let invalid_assignments_for_public_profiles ~known_internal_profiles
    ~invalid_profiles public_profiles =
  public_profiles
  |> List.filter_map (fun public_name ->
    match
      invalid_assignment_reasons
        ~known_internal_profiles
        ~invalid_profiles
        public_name
    with
    | Some reasons -> Some (public_name, reasons)
    | None -> None)
;;

let json_assoc_member key = function
  | `Assoc fields -> Option.value (List.assoc_opt key fields) ~default:`Null
  | _ -> `Null
;;

let json_string_list = function
  | `List values ->
    List.filter_map
      (function
        | `String value -> Some value
        | _ -> None)
      values
  | _ -> []
;;

let invalid_profiles_of_rejection_json rejection_json =
  match json_assoc_member "profiles" rejection_json with
  | `List profiles ->
    List.filter_map
      (fun profile_json ->
         match json_assoc_member "name" profile_json with
         | `String name ->
           Some (name, json_string_list (json_assoc_member "errors" profile_json))
         | _ -> None)
      profiles
    |> invalid_profiles_with_internal_names
  | _ -> []
;;

let source_info ?config_path () =
  let config_path =
    match config_path with
    | Some path -> path
    | None -> Config_dir_resolver.cascade_path_candidate ()
  in
  Cascade_toml_materializer.source_info ~config_path
;;

let source_json_fields (source : Cascade_toml_materializer.source_info) =
  [ "source_kind", `String (Cascade_toml_materializer.source_kind_to_string source.kind)
  ; "source_path", `String source.source_path
  ]
;;

(* ── Query / retention envelopes shared across capacity / strategy /
   audit / SLO projections.  Kept here so each projection submodule can
   render a consistent envelope without re-declaring the helpers. *)

let cascade_query_json fields = `Assoc fields

let optional_string_field key = function
  | None -> key, `Null
  | Some value -> key, `String value
;;

let optional_float_field key = function
  | None -> key, `Null
  | Some value -> key, `Float value
;;

let retention_json ?durable_store ?ring_capacity ~scope ~producer ~store_kind
    ~cache_policy () =
  let optional_fields =
    List.filter_map
      (fun x -> x)
      [ Option.map (fun path -> "durable_store", `String path) durable_store
      ; Option.map (fun capacity -> "ring_capacity", `Int capacity) ring_capacity
      ]
  in
  `Assoc
    ([ "scope", `String scope
     ; "producer", `String producer
     ; "store_kind", `String store_kind
     ; "cache_policy", `String cache_policy
     ]
     @ optional_fields)
;;
