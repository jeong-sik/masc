(** See {!Keeper_cascade_profile} interface for rationale. *)

(** SSOT variant. Adding a new cascade profile is a compile-time event:
    add a variant here, then exhaustive [match] sites flag every consumer
    that needs to handle it. Personal/playground-only cascades must NOT
    be added here — they live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json] only. *)
type t =
  | Default
  | Keeper_unified
  | Sangsu
  | Local_only
  | Local_mlx_vlm_qwen36
  | Local_recovery
  | Tool_rerank
  | Nick0cave
  | Capacity_queue_trio
  | Vendor_mix_balanced
  | Cost_tier_ladder
  | Oauth_cli_rotate
  | Quality_sticky_glm51
  | Tool_use_strict
  | Resilient_breaker

let to_string = function
  | Default -> "default"
  | Keeper_unified -> "keeper_unified"
  | Sangsu -> "sangsu"
  | Local_only -> "local_only"
  | Local_mlx_vlm_qwen36 -> "local_mlx_vlm_qwen36"
  | Local_recovery -> "local_recovery"
  | Tool_rerank -> "tool_rerank"
  | Nick0cave -> "nick0cave"
  | Capacity_queue_trio -> "capacity_queue_trio"
  | Vendor_mix_balanced -> "vendor_mix_balanced"
  | Cost_tier_ladder -> "cost_tier_ladder"
  | Oauth_cli_rotate -> "oauth_cli_rotate"
  | Quality_sticky_glm51 -> "quality_sticky_glm51"
  | Tool_use_strict -> "tool_use_strict"
  | Resilient_breaker -> "resilient_breaker"

let all =
  [ Default; Keeper_unified; Sangsu; Local_only; Local_mlx_vlm_qwen36;
    Local_recovery; Tool_rerank;
    Nick0cave; Capacity_queue_trio; Vendor_mix_balanced; Cost_tier_ladder;
    Oauth_cli_rotate; Quality_sticky_glm51; Tool_use_strict; Resilient_breaker ]

(** All known cascade profile names, derived from the variant. Consumers
    that still operate on strings can use this list; new code should
    take {!t} directly. *)
let known_cascades = List.map to_string all

let default = Keeper_unified
let default_name = to_string default

let of_string_opt (raw : string) : t option =
  match String.trim raw |> String.lowercase_ascii with
  | "" -> Some default
  | "default" -> Some Default
  | "keeper_unified"
  | "oas-keeper_unified"
  | "coding_first"
  | "oas-coding_first" -> Some Keeper_unified
  (* Historical drift: never defined as separate profiles, always fell
     through to default. Collapsed here so bucket/metric code does not
     see a ghost value. *)
  | "keeper_turn" | "keeper_reply" -> Some default
  | "sangsu" -> Some Sangsu
  | "local_only" -> Some Local_only
  | "local_mlx_vlm_qwen36" -> Some Local_mlx_vlm_qwen36
  | "local_recovery" -> Some Local_recovery
  | "tool_rerank" -> Some Tool_rerank
  | "nick0cave" -> Some Nick0cave
  | "capacity_queue_trio" -> Some Capacity_queue_trio
  | "vendor_mix_balanced" -> Some Vendor_mix_balanced
  | "cost_tier_ladder" -> Some Cost_tier_ladder
  | "oauth_cli_rotate" -> Some Oauth_cli_rotate
  | "quality_sticky_glm51" -> Some Quality_sticky_glm51
  | "tool_use_strict" -> Some Tool_use_strict
  | "resilient_breaker" -> Some Resilient_breaker
  | _ -> None

let canonical (raw : string) : t =
  match of_string_opt raw with
  | Some t -> t
  | None -> default

let catalog_entries ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> None
  | Some path -> (
      match Cascade_config_loader.load_catalog ~config_path:path with
      | Ok entries -> Some entries
      | Error _ -> None)

let catalog_names ?config_path () =
  match catalog_entries ?config_path () with
  | Some entries ->
      List.map (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
        entries
  | None -> []

let is_system_only_cascade raw =
  let name = String.trim raw in
  match catalog_entries () with
  | None -> false
  | Some entries ->
      List.exists
        (fun (entry : Cascade_config_loader.catalog_entry) ->
          String.equal entry.name name && not entry.keeper_assignable)
        entries

let keeper_catalog_names ?config_path () =
  match catalog_entries ?config_path () with
  | Some entries ->
      entries
      |> List.filter_map
           (fun (entry : Cascade_config_loader.catalog_entry) ->
             if entry.keeper_assignable then Some entry.name else None)
  | None -> []

let system_catalog_names ?config_path () =
  match catalog_entries ?config_path () with
  | Some entries ->
      entries
      |> List.filter_map
           (fun (entry : Cascade_config_loader.catalog_entry) ->
             if entry.keeper_assignable then None else Some entry.name)
  | None -> []

let canonicalize_with_catalog ~catalog raw =
  match String.trim raw with
  | "" -> default_name
  | trimmed -> (
      match of_string_opt trimmed with
      | Some profile -> to_string profile
      | None ->
          if List.mem trimmed catalog then trimmed else default_name)

let canonicalize (raw : string) : string =
  canonicalize_with_catalog ~catalog:(catalog_names ()) raw

let models_key_t t = to_string t ^ "_models"
let temperature_key_t t = to_string t ^ "_temperature"
let max_tokens_key_t t = to_string t ^ "_max_tokens"

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"
