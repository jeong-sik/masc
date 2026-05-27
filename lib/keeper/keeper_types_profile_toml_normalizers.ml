(** Keeper_types_profile_toml — TOML parsing, loading, merging, and
    unknown-key detection for keeper profile defaults.

    Extracted from keeper_types_profile.ml to reduce file size.
    The parent module includes this one so all symbols remain
    accessible under [Keeper_types_profile.*]. *)

include Keeper_config
include Keeper_types_profile_sandbox
include Keeper_types_profile_defaults

(* ── Normalizers (shared by TOML section and persona JSON loader) ── *)

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then
        false
      else (
        Hashtbl.add seen item ();
        true))
    items

let normalize_name_list items =
  items
  |> List.map String.trim
  |> List.filter (fun item -> item <> "")
  |> dedupe_keep_order

let normalize_name_list_opt items =
  match normalize_name_list items with
  | [] -> None
  | xs -> Some xs

let normalize_cascade_name_opt = function
  | None -> None
  | Some raw -> Some (Keeper_cascade_profile.normalize_declared_name raw)

let normalize_git_identity_mode_opt = function
  | None -> None
  | Some raw -> (
      match String.trim (String.lowercase_ascii raw) with
      | "keeper_alias" -> Some "keeper_alias"
      | "repo_cli_identity" -> Some "repo_cli_identity"
      | _ -> None)

let normalize_social_model_opt = function
  | None -> None
  | Some raw -> (
      match Keeper_social_model_types.model_id_of_string raw with
      | Some model_id ->
          Some (Keeper_social_model_types.model_id_to_string model_id)
      | None -> None)

let valid_social_model_strings =
  Keeper_social_model_types.valid_model_id_strings

let lower_string_list_opt = function
  | [] -> None
  | xs -> Some (List.map String.lowercase_ascii xs)

let valid_tool_preset_raw_strings =
  [ "minimal"; "social"; "messaging"; "dispatch"; "research"; "coding"; "delivery"; "full" ]

let normalize_tool_preset_raw raw =
  let normalized = String.trim (String.lowercase_ascii raw) in
  if List.mem normalized valid_tool_preset_raw_strings then Some normalized else None

let first_some = Dashboard_utils.first_some
(* ── Per-provider timeout aliases ──────────────────────────────── *)

let normalize_per_provider_timeout_opt =
  Keeper_types_profile_per_provider_timeout.normalize_per_provider_timeout_opt
let per_provider_timeout_of_declared_float_opt =
  Keeper_types_profile_per_provider_timeout.per_provider_timeout_of_declared_float_opt
let per_provider_timeout_of_toml =
  Keeper_types_profile_per_provider_timeout.per_provider_timeout_of_toml
let per_provider_timeout_of_json_field =
  Keeper_types_profile_per_provider_timeout.per_provider_timeout_of_json_field
let normalize_per_provider_timeout_json_field =
  Keeper_types_profile_per_provider_timeout.normalize_per_provider_timeout_json_field

(* ── Persona path helpers ──────────────────────────────────────── *)

let personas_root_opt = Keeper_types_profile_persona.personas_root_opt
let persona_profile_path_opt = Keeper_types_profile_persona.persona_profile_path_opt

(* ================================================================ *)
(* TOML -> keeper_profile_defaults conversion                        *)
(* ================================================================ *)
