(** See {!Keeper_cascade_profile} interface for rationale. *)

(** SSOT variant for the 1+1 cascade model.

    One keeper-assignable bootstrap profile ({!Big_three}) and one system-only
    profile ({!Tool_rerank}).  Phase-routing names ("local_only",
    "local_recovery") are NOT variants — they pass through
    [canonicalize_with_catalog] as catalog names, so keeper phase-routing
    code that references them by string continues to work without changes.

    Adding a new profile is a compile-time event: add a variant here, then
    exhaustive [match] sites flag every consumer that needs to handle it.
    Personal/playground-only cascades must NOT be added here — they live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json] only. *)
type t =
  | Big_three
  | Tool_rerank

let to_string = function
  | Big_three -> "big_three"
  | Tool_rerank -> "tool_rerank"

let all = [ Big_three; Tool_rerank ]

(** All known cascade profile names, derived from the variant. Consumers
    that still operate on strings can use this list; new code should
    take {!t} directly. *)
let known_cascades = List.map to_string all

let default = Big_three
let default_name = to_string default

let of_string_opt (raw : string) : t option =
  match String.trim raw |> String.lowercase_ascii with
  | "" -> Some default
  | "big_three" -> Some Big_three
  | "tool_rerank" -> Some Tool_rerank
  (* Legacy aliases → Big_three *)
  | "default"
  | "keeper_unified"
  | "oas-keeper_unified"
  | "coding_first"
  | "oas-coding_first"
  | "keeper_turn" | "keeper_reply"
  | "sangsu" | "local_mlx_vlm_qwen36"
  | "nick0cave" | "capacity_queue_trio" | "vendor_mix_balanced"
  | "cost_tier_ladder" | "oauth_cli_rotate" | "quality_sticky_glm51"
  | "tool_use_strict" | "resilient_breaker"
  | "underdog" | "local"
    -> Some Big_three
  (* Phase-routing names: NOT variants.  Returning None lets
     [canonicalize_with_catalog] preserve them as catalog names so
     keeper phase-routing code (local_only, local_recovery) continues
     to resolve cascade.json keys correctly. *)
  | "local_only" | "local_recovery" -> None
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

let normalize_declared_name (raw : string) : string =
  let trimmed = String.trim raw in
  match of_string_opt trimmed with
  | Some t -> to_string t
  | None when trimmed = "" -> default_name
  | None -> trimmed

let resolve_live_with_catalog ~catalog raw =
  let normalized = normalize_declared_name raw in
  if List.mem normalized catalog then normalized else default_name

let resolve_live ?config_path raw =
  resolve_live_with_catalog ~catalog:(catalog_names ?config_path ()) raw

let canonicalize (raw : string) : string =
  canonicalize_with_catalog ~catalog:(catalog_names ()) raw

let models_key_t t = to_string t ^ "_models"
let temperature_key_t t = to_string t ^ "_temperature"
let max_tokens_key_t t = to_string t ^ "_max_tokens"

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"
