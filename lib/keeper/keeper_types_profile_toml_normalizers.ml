(** Keeper_types_profile_toml — TOML parsing, loading, merging, and
    unknown-key detection for keeper profile defaults.

    Extracted from keeper_types_profile.ml to reduce file size.
    The parent module includes this one so all symbols remain
    accessible under [Keeper_types_profile.*]. *)

include Keeper_config
include Keeper_types_profile_sandbox
include Keeper_types_profile_defaults

(* ── Normalizers (shared by TOML section and persona JSON loader) ── *)

let dedupe_keep_order = Json_util.dedupe_keep_order

let normalize_name_list items =
  items
  |> List.map String.trim
  |> List.filter (fun item -> item <> "")
  |> dedupe_keep_order

let normalize_name_list_opt items =
  match normalize_name_list items with
  | [] -> None
  | xs -> Some xs

let lower_string_list_opt = function
  | [] -> None
  | xs -> Some (List.map String.lowercase_ascii xs)

let first_some = Dashboard_utils.first_some

(* ── Persona path helpers ──────────────────────────────────────── *)

let personas_root_opt = Keeper_types_profile_persona.personas_root_opt
let persona_profile_path_opt = Keeper_types_profile_persona.persona_profile_path_opt

(* ================================================================ *)
(* TOML -> keeper_profile_defaults conversion                        *)
(* ================================================================ *)
