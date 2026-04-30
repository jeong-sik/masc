(** Keeper_types_profile — keeper profile defaults, persona loading,
    and directory path helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include Keeper_config
let keeper_debug = Env_config.KeeperRuntime.debug

type sandbox_profile =
  | Local
    (** Host-process execution. Filesystem scope is bound to
        [~/me/.masc/playground/<keeper>/] (see [Playground_paths]).
        Network inherits the server's namespace. Intended for keepers
        whose work stays on local files and does not need container-grade
        isolation. *)
  | Docker
    (** Containerized execution with hardened defaults: cap-drop,
        no-new-privs, read-only rootfs, tmpfs, pids/memory limits.
        Network defaults to [Network_none]; the internal git/gh
        dispatcher (see [Keeper_exec_shell.cmd_targets_git_or_gh])
        upgrades the container to [Network_inherit] with read-only
        mounts of ~/.config/gh and ~/.gitconfig (and optionally ~/.ssh)
        for the duration of a git/gh command. *)

type network_mode =
  | Network_none [@tla.symbol "Network_none"]
  | Network_inherit [@tla.symbol "Network_inherit"]
[@@deriving tla]

type shared_memory_scope =
  | Shared_memory_disabled
  | Shared_memory_room

let sandbox_profile_to_string = function
  | Local -> "local"
  | Docker -> "docker"

let reserved_cascade_names =
  List.sort_uniq String.compare
    (Keeper_cascade_profile.known_cascades
     @ phase_routing_cascade_names
     @ [ tool_use_strict_cascade_name ])

(** Parse a sandbox profile string. Canonical values are ["local"] and
    ["docker"]. Legacy names ["legacy_local"], ["docker_hardened"], and
    ["docker_with_git"] are still accepted for backward compatibility
    with existing keeper JSON/TOML; they map to the new variants and
    [load_keeper_sandbox_profile_with_warning] below emits a warning. *)
let sandbox_profile_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "local" -> Some Local
  | "docker" -> Some Docker
  (* Temporary compatibility layer — remove after all config/state files
     have been migrated to the canonical names. Keep in ONE place so the
     eventual removal is a single diff. *)
  | "legacy_local" -> Some Local
  | "docker_hardened" -> Some Docker
  | "docker_with_git" -> Some Docker
  | _ -> None

(** Same as [sandbox_profile_of_string] but emits a warning when a
    deprecated string is encountered. Call from the boundary that reads
    keeper state/config files so operators see drift in the server log. *)
let sandbox_profile_of_string_with_warning ~source raw =
  let trimmed = String.trim (String.lowercase_ascii raw) in
  (match trimmed with
   | "legacy_local" | "docker_hardened" | "docker_with_git" ->
       Log.Keeper.warn
         "%s: sandbox_profile %S is deprecated, mapped to %S"
         source trimmed
         (match trimmed with
          | "legacy_local" -> "local"
          | "docker_hardened" | "docker_with_git" -> "docker"
          | _ -> trimmed)
   | _ -> ());
  sandbox_profile_of_string raw

(* Issue #8467: Variant SSOT — adding a constructor to [sandbox_profile]
   forces [sandbox_profile_to_string] exhaustiveness AND extends
   [valid_sandbox_profile_strings] so [keeper_schema] picks it up via
   the mirror declared there. *)
let all_sandbox_profiles = [ Local; Docker ]
let valid_sandbox_profile_strings =
  List.map sandbox_profile_to_string all_sandbox_profiles

let network_mode_to_string = function
  | Network_none -> "none"
  | Network_inherit -> "inherit"

let network_mode_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "none" -> Some Network_none
  | "inherit" -> Some Network_inherit
  | "host" ->
      Log.Keeper.warn
        "network_mode=\"host\" is a deprecated alias for \"inherit\"; \
         update TOML to use \"inherit\"";
      Some Network_inherit
  | _ -> None

(* Issue #8467: Variant SSOT for [network_mode]. *)
let all_network_modes = [ Network_none; Network_inherit ]
let valid_network_mode_strings =
  List.map network_mode_to_string all_network_modes

let shared_memory_scope_to_string = function
  | Shared_memory_disabled -> "disabled"
  | Shared_memory_room -> "room"

let shared_memory_scope_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "disabled" -> Some Shared_memory_disabled
  | "room" -> Some Shared_memory_room
  | _ -> None

(* Issue #8467: Variant SSOT for [shared_memory_scope]. *)
let all_shared_memory_scopes = [ Shared_memory_disabled; Shared_memory_room ]
let valid_shared_memory_scope_strings =
  List.map shared_memory_scope_to_string all_shared_memory_scopes

let default_sandbox_profile = Local

let default_network_mode_for_profile = function
  | Local -> Network_inherit
  | Docker -> Network_none
  (* git/gh dispatch in Docker upgrades to Network_inherit at runtime
     via Keeper_exec_shell.cmd_targets_git_or_gh; that upgrade is not
     visible here because it's a per-command decision, not a profile
     default. *)

let default_shared_memory_scope = Shared_memory_disabled

type 'a context = {
  config: Coord.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net: [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type tool_result = bool * string

let schemas = Keeper_schema.schemas

(* Configuration: see Keeper_config *)
include Keeper_config

let short_preview ?(max_len = 220) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else utf8_safe_prefix_bytes s ~max_bytes:max_len ^ "..."

let take n xs =
  let rec go i acc = function
    | [] -> List.rev acc
    | _ when i <= 0 -> List.rev acc
    | x :: rest -> go (i - 1) (x :: acc) rest
  in
  go n [] xs

(* Delegated to Keeper_fs — single fiber-safe ensure_dir implementation. *)
let ensure_dir = Keeper_fs.ensure_dir

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
      | "github_identity" -> Some "github_identity"
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
  [ "minimal"; "social"; "messaging"; "dispatch"; "coding"; "research"; "delivery"; "full" ]

let normalize_tool_preset_raw raw =
  let normalized = String.trim (String.lowercase_ascii raw) in
  if List.mem normalized valid_tool_preset_raw_strings then Some normalized else None

let first_some = Dashboard_utils.first_some

let canonical_voice_channel = function
  | "voice_only" -> "voice_only"
  | "text_only" -> "text_only"
  | _ -> "voice_text"

let default_voice_enabled_for _name =
  (* Pure tests may parse keeper metadata without an Eio context. In that
     case, treat voice as disabled rather than failing metadata decoding. *)
  try
    match Voice_config.load () with
    | Ok _ -> true
    | Error _ -> false
  with
  | Effect.Unhandled _ -> false
  | Sys_error _ -> false
  | Unix.Unix_error _ -> false
  | _ -> false

let default_voice_channel_for name =
  if default_voice_enabled_for name then "voice_text" else "text_only"

let default_voice_agent_id_for name =
  if default_voice_enabled_for name then name else ""

let room_seq_map_to_json (items : (string * int) list) : Yojson.Safe.t =
  `Assoc (List.map (fun (room_id, seq) -> (room_id, `Int seq)) items)

let room_seq_map_of_json (json : Yojson.Safe.t) : (string * int) list =
  match json with
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (room_id, value) ->
             if not (validate_name room_id) then
               None
             else
               match value with
               | `Int seq -> Some (room_id, seq)
               | `Intlit raw ->
                   Some (room_id, Safe_ops.int_of_string_with_default ~default:0 raw)
               | _ -> None)
  | _ -> []


type keeper_profile_defaults = {
  id : Ids.Keeper_id.t option; [@default None]
  manifest_path : string option;
  persona_name : string option;
  goal : string option;
  short_goal : string option;
  mid_goal : string option;
  long_goal : string option;
  will : string option;
  needs : string option;
  desires : string option;
  instructions : string option;
  policy_voice_enabled : bool option;
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  proactive_idle_sec : int option;
  proactive_cooldown_sec : int option;
  room_signal_prompt_enabled : bool option;
  shards : string list option;
  allowed_paths : string list option;
  sandbox_profile : sandbox_profile option;
  sandbox_image : string option;
  network_mode : network_mode option;
  shared_memory_scope : shared_memory_scope option;
  github_identity : string option;
  git_identity_mode : string option;
  tool_preset : string option;
  tool_preset_source : string option;
  tool_also_allow : string list option;
  tool_denylist : string list option;
  active_goal_ids : string list option;
  (* Work Discovery — config-driven proactive work scanning *)
  work_discovery_enabled : bool option;
  work_discovery_sources : string list option;
  work_discovery_interval_sec : int option;
  work_discovery_guidance : string option;
  (* Telemetry Feedback — inject behavioral stats into keeper context *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  per_provider_timeout_state : per_provider_timeout_state;
  (* Per-provider timeout for cascade fallback. None = use turn budget heuristic. *)
  per_provider_timeout : float option;
  always_approve : bool option;
  social_model : string option;
  cascade_name : string option;
  models : string list option;
  (* Turn budget overrides. None = inherit env default
     (MASC_KEEPER_OAS_MAX_TURNS_PER_CALL / ..._SCHEDULED_AUTONOMOUS). *)
  max_turns_per_call : int option;
  max_turns_per_call_scheduled_autonomous : int option;
  (* Per-keeper OAS CLI transport env vars (OAS 0.159+).
     Parsed from [[keeper.oas_env]] table.  Keys MUST match
     ^OAS_(CLAUDE|CODEX|GEMINI)_.+ — any other entries are dropped with
     a warning to avoid ambient env injection via keeper TOML.
     Applied via Unix.putenv right before each turn so OAS transport
     build_args picks them up.  Empty list = no overrides. *)
  oas_env : (string * string) list;
  (* Keys present under [keeper] (or other tables) that are NOT in
     [canonical_keeper_toml_key_names].  Captured at load time so
     downstream surfaces (keeper_status_detail, dashboards) can show
     drift instead of silently ignoring legacy / typo'd keys.
     Today this is also logged via [warn_unknown_keeper_toml_keys];
     the field is purely additive. *)
  unknown_toml_keys : string list;
}

and per_provider_timeout_state =
  | Per_provider_timeout_unset
  | Per_provider_timeout_invalid
  | Per_provider_timeout_set

type persona_summary = {
  persona_name : string;
  display_name : string;
  role : string option;
  trait : string option;
  profile_path : string;
  has_keeper_defaults : bool;
}

let empty_keeper_profile_defaults = {
  id = None;
  manifest_path = None;
  persona_name = None;
  goal = None;
  short_goal = None;
  mid_goal = None;
  long_goal = None;
  will = None;
  needs = None;
  desires = None;
  instructions = None;
  policy_voice_enabled = None;
  autoboot_enabled = None;
  mention_targets = [];
  proactive_enabled = None;
  proactive_idle_sec = None;
  proactive_cooldown_sec = None;
  room_signal_prompt_enabled = None;
  shards = None;
  allowed_paths = None;
  sandbox_profile = None;
  sandbox_image = None;
  network_mode = None;
  shared_memory_scope = None;
  github_identity = None;
  git_identity_mode = None;
  tool_preset = None;
  tool_preset_source = None;
  tool_also_allow = None;
  tool_denylist = None;
  active_goal_ids = None;
  work_discovery_enabled = None;
  work_discovery_sources = None;
  work_discovery_interval_sec = None;
  work_discovery_guidance = None;
  telemetry_feedback_enabled = None;
  telemetry_feedback_window_hours = None;
  per_provider_timeout_state = Per_provider_timeout_unset;
  per_provider_timeout = None;
  always_approve = None;
  social_model = None;
  max_turns_per_call = None;
  max_turns_per_call_scheduled_autonomous = None;
  cascade_name = None;
  models = None;
  unknown_toml_keys = [];
  oas_env = [];
}

let normalize_per_provider_timeout_opt ~(source : string)
    (value : float option) : float option =
  match value with
  | Some f when Float.is_finite f && f > 0.0 -> Some f
  | Some f when not (Float.is_finite f) ->
      Log.Keeper.warn
        "%s per_provider_timeout=%s is non-finite; ignoring"
        source (string_of_float f);
      None
  | Some f ->
      Log.Keeper.warn
        "%s per_provider_timeout=%s is non-positive; ignoring"
        source (string_of_float f);
      None
  | None -> None
;;

let per_provider_timeout_of_declared_float_opt ~(source : string)
    ~(declared : bool)
    (value : float option)
    : per_provider_timeout_state * float option =
  if not declared then
    Per_provider_timeout_unset, None
  else
    match value with
    | None ->
        Log.Keeper.warn
          "%s per_provider_timeout has invalid type; ignoring"
          source;
        Per_provider_timeout_invalid, None
    | Some _ ->
        (match normalize_per_provider_timeout_opt ~source value with
         | Some f -> Per_provider_timeout_set, Some f
         | None -> Per_provider_timeout_invalid, None)
;;

let per_provider_timeout_of_toml ~(source : string)
    (doc : Keeper_toml_loader.toml_doc)
    (key : string)
    : per_provider_timeout_state * float option =
  per_provider_timeout_of_declared_float_opt
    ~source
    ~declared:(List.mem_assoc key doc)
    (Keeper_toml_loader.toml_float_opt doc key)
;;

let per_provider_timeout_of_json_field ~(source : string)
    ~(field : string)
    (json : Yojson.Safe.t)
    : per_provider_timeout_state * float option =
  per_provider_timeout_of_declared_float_opt
    ~source
    ~declared:(Option.is_some (Safe_ops.json_member_opt field json))
    (Safe_ops.json_float_opt field json)
;;

let normalize_per_provider_timeout_json_field ~(source : string)
    ~(field : string)
    (json : Yojson.Safe.t)
    : float option =
  per_provider_timeout_of_json_field ~source ~field json |> snd
;;

let personas_root_opt () =
  try
    Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
    Config_dir_resolver.personas_dir_opt ()
  with
  | Sys_error _ -> None
  | exn ->
      Log.Keeper.warn "personas_root_opt unexpected: %s" (Printexc.to_string exn);
      None

let persona_profile_path_opt name =
  let dirs =
    try
      Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
      Config_dir_resolver.personas_dirs ()
    with
    | Sys_error _ -> []
    | exn ->
        Log.Keeper.warn "personas_dirs unexpected: %s" (Printexc.to_string exn);
        []
  in
  (* Search the resolved persona roots only.
     Config_dir_resolver.personas_dirs now returns a single source of truth:
     explicit MASC_PERSONAS_DIR or resolved CONFIG_ROOT/personas. *)
  dirs
  |> List.find_map (fun root ->
         let path = Filename.concat (Filename.concat root name) "profile.json" in
         if Fs_compat.file_exists path then Some path else None)

(* ================================================================ *)
(* TOML -> keeper_profile_defaults conversion                        *)
(* ================================================================ *)

(** Scan a flat TOML doc for keys under [[keeper.oas_env]].  Only keys
    matching ^(OAS_(CLAUDE|CODEX|GEMINI)_|MASC_KEEPER_OAS_) are accepted
    — any other entries are dropped silently.  This guards against
    arbitrary process env injection via keeper TOML.  Values are coerced
    to strings via [string_of_toml_value_for_env] (bool → "1"/"0"), so
    integers and booleans in TOML map to the string shapes the OAS
    transport build_args already understand. *)
let string_of_toml_value_for_env = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f -> Some (string_of_float f)
  | Keeper_toml_loader.Toml_bool true -> Some "1"
  | Keeper_toml_loader.Toml_bool false -> Some "0"
  | Keeper_toml_loader.Toml_string_array _ -> None

let oas_env_key_prefix = "keeper.oas_env."

let oas_env_key_is_allowed suffix =
  let allowed_prefixes =
    [ "OAS_CLAUDE_"; "OAS_CODEX_"; "OAS_GEMINI_"; "MASC_KEEPER_OAS_" ]
  in
  List.exists
    (fun p ->
      String.length suffix > String.length p
      && String.sub suffix 0 (String.length p) = p)
    allowed_prefixes

let extract_oas_env_from_doc (doc : Keeper_toml_loader.toml_doc)
    : (string * string) list =
  let prefix_len = String.length oas_env_key_prefix in
  List.filter_map
    (fun (k, v) ->
      if String.length k > prefix_len
         && String.sub k 0 prefix_len = oas_env_key_prefix
      then
        let suffix = String.sub k prefix_len (String.length k - prefix_len) in
        if oas_env_key_is_allowed suffix then
          Option.map (fun sv -> (suffix, sv)) (string_of_toml_value_for_env v)
        else None
      else None)
    doc

let profile_defaults_of_toml (doc : Keeper_toml_loader.toml_doc)
    : (keeper_profile_defaults, string) result =
  let k key = "keeper." ^ key in
  let str key = Keeper_toml_loader.toml_string_opt doc (k key) in
  let bool_ key = Keeper_toml_loader.toml_bool_opt doc (k key) in
  let int_ key = Keeper_toml_loader.toml_int_opt doc (k key) in
  let strs key = Keeper_toml_loader.toml_string_list doc (k key) in
  let has key = List.mem_assoc (k key) doc in
  let has_raw key = List.mem_assoc key doc in
  let tool_access_key key = k ("tool_access." ^ key) in
  let tool_access_defaults_result =
    let kind_key = tool_access_key "kind" in
    let preset_key = tool_access_key "preset" in
    let also_allow_key = tool_access_key "also_allow" in
    let tools_key = tool_access_key "tools" in
    match Keeper_toml_loader.toml_string_opt doc kind_key with
    | None
      when has_raw preset_key || has_raw also_allow_key || has_raw tools_key ->
        Error
          "keeper.tool_access.kind is required when keeper.tool_access.* keys are present"
    | None -> Ok (None, None, None)
    | Some "preset" -> (
        match Keeper_toml_loader.toml_string_opt doc preset_key with
        | None ->
            Error
              "keeper.tool_access.preset is required when keeper.tool_access.kind = \"preset\""
        | Some raw -> (
            match normalize_tool_preset_raw raw with
            | Some normalized ->
                Ok
                  ( Some normalized,
                    normalize_name_list_opt
                      (Keeper_toml_loader.toml_string_list doc also_allow_key),
                    Some "toml" )
            | None ->
                Error
                  (Printf.sprintf
                     "invalid keeper.tool_access.preset '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_tool_preset_raw_strings))))
    | Some "custom" ->
        Error
          "keeper.tool_access.kind=\"custom\" cannot be used in keeper TOML defaults yet; use masc_keeper_up tool_access for runtime custom policies"
    | Some raw ->
        Error
          (Printf.sprintf
             "invalid keeper.tool_access.kind '%s' (allowed: preset)"
             raw)
  in
  let per_provider_timeout_state, per_provider_timeout =
    per_provider_timeout_of_toml
      ~source:"keeper TOML"
      doc
      (k "per_provider_timeout")
  in
  let removed_present =
    ("also_allow" :: removed_keeper_input_key_names)
    |> List.map k
    |> List.filter (fun key -> List.mem_assoc key doc)
  in
  let result =
    match removed_present with
    | [] -> Ok ()
    | fields ->
        Error
          (Printf.sprintf
             "removed keeper TOML keys: %s"
             (String.concat ", " fields))
  in
  let result =
    Result.bind result (fun () ->
        match str "persona_name" with
        | Some raw when not (validate_name raw) ->
            Error (Printf.sprintf "invalid persona_name '%s'" raw)
        | _ -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "github_identity" with
        | Some raw when not (validate_name raw) ->
            Error (Printf.sprintf "invalid github_identity '%s'" raw)
        | _ -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "git_identity_mode" with
        | Some raw -> (
            match normalize_git_identity_mode_opt (Some raw) with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid git_identity_mode '%s' (allowed: keeper_alias, github_identity)"
                     raw))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "social_model" with
        | Some raw -> (
            match normalize_social_model_opt (Some raw) with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid social_model '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_social_model_strings)))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "sandbox_profile" with
        | Some raw -> (
            match sandbox_profile_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid sandbox_profile '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_sandbox_profile_strings)))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "network_mode" with
        | Some raw -> (
            match network_mode_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid network_mode '%s' (allowed: none, inherit; \
                      deprecated alias: host)"
                     raw))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "shared_memory_scope" with
        | Some raw -> (
            match shared_memory_scope_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid shared_memory_scope '%s' (allowed: disabled, room)"
                     raw))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "cascade_name" with
        | None -> Ok ()
        | Some raw ->
            let normalized =
              Keeper_cascade_profile.normalize_declared_name raw
              |> String.lowercase_ascii
            in
            if List.mem normalized reserved_cascade_names then Ok ()
            else
              (* #10259: don't collapse to the reserved list when only the
                 strict materializer fails — fall back to top-level TOML
                 section names so operator-defined cascades stay valid. *)
              match
                Keeper_cascade_profile.catalog_names_with_toml_fallback ()
              with
              | Ok (catalog, source) ->
                  let all_valid =
                    List.sort_uniq String.compare
                      (reserved_cascade_names @ catalog)
                  in
                  let suffix =
                    match source with
                    | Keeper_cascade_profile.Live_catalog -> ""
                    | Keeper_cascade_profile.Toml_section_fallback
                        { catalog_error } ->
                        Printf.sprintf
                          " [degraded toml-section fallback; live \
                           catalog unavailable: %s]"
                          catalog_error
                  in
                  if not (List.mem normalized all_valid) then
                    Error
                      (Printf.sprintf
                         "invalid cascade_name '%s' (known: %s)%s"
                         raw
                         (String.concat ", " all_valid)
                         suffix)
                  (* #10388: keeper_assignable=false cascades must reject
                     at config-load to avoid runtime reconcile failures. *)
                  else if Keeper_cascade_profile.is_system_only_cascade normalized
                  then
                    let assignable =
                      Keeper_cascade_profile.keeper_catalog_names ()
                    in
                    let assignable_hint =
                      if assignable = [] then "(none)"
                      else String.concat ", " assignable
                    in
                    Error
                      (Printf.sprintf
                         "cascade_name '%s' is system-only \
                          (keeper_assignable=false); keepers must \
                          reference an assignable cascade. \
                          Assignable: %s"
                         raw assignable_hint)
                  else Ok ()
              | Error fallback_error ->
                  Error
                    (Printf.sprintf
                       "invalid cascade_name '%s' (reserved: %s; %s)"
                       raw
                       (String.concat ", " reserved_cascade_names)
                       fallback_error))
  in
  let result =
    Result.bind result (fun () -> tool_access_defaults_result)
  in
  Result.map
    (fun (tool_preset, tool_also_allow, tool_preset_source) ->
      {
        id = None;
        manifest_path = None;
        persona_name = str "persona_name";
        goal = str "goal";
        short_goal =
          str "short_goal"
          |> normalize_goal_horizon_opt;
        mid_goal =
          str "mid_goal"
          |> normalize_goal_horizon_opt;
        long_goal =
          str "long_goal"
          |> normalize_goal_horizon_opt;
        will = str "will";
        needs = str "needs";
        desires = str "desires";
        instructions = str "instructions";
        policy_voice_enabled = bool_ "policy_voice_enabled";
        autoboot_enabled = bool_ "autoboot_enabled";
        mention_targets = strs "mention_targets";
        proactive_enabled = bool_ "proactive_enabled";
        proactive_idle_sec = int_ "proactive_idle_sec";
        proactive_cooldown_sec = int_ "proactive_cooldown_sec";
        room_signal_prompt_enabled = bool_ "room_signal_prompt_enabled";
        shards =
          (match strs "shards" with
           | [] -> None
           | xs -> Some xs);
        allowed_paths =
          if has "allowed_paths" then Some (strs "allowed_paths")
          else None;
        sandbox_profile =
          Option.bind (str "sandbox_profile") sandbox_profile_of_string;
        sandbox_image = str "sandbox_image";
        network_mode =
          Option.bind (str "network_mode") network_mode_of_string;
        shared_memory_scope =
          Option.bind (str "shared_memory_scope")
            shared_memory_scope_of_string;
        github_identity = str "github_identity";
        git_identity_mode =
          normalize_git_identity_mode_opt (str "git_identity_mode");
        tool_preset;
        tool_preset_source;
        tool_also_allow;
        tool_denylist = normalize_name_list_opt (strs "tool_denylist");
        active_goal_ids =
          if has "active_goal_ids" then
            Some (normalize_name_list (strs "active_goal_ids"))
          else None;
        work_discovery_enabled = bool_ "work_discovery_enabled";
        work_discovery_sources =
          (match strs "work_discovery_sources" with
           | [] -> None
           | xs -> Some xs);
        work_discovery_interval_sec = int_ "work_discovery_interval_sec";
        work_discovery_guidance = str "work_discovery_guidance";
        telemetry_feedback_enabled = bool_ "telemetry_feedback_enabled";
        telemetry_feedback_window_hours = int_ "telemetry_feedback_window_hours";
        per_provider_timeout_state;
        per_provider_timeout;
        always_approve = bool_ "always_approve";
        max_turns_per_call = int_ "max_turns_per_call";
        max_turns_per_call_scheduled_autonomous =
          int_ "max_turns_per_call_scheduled_autonomous";
        social_model = normalize_social_model_opt (str "social_model");
        cascade_name = normalize_cascade_name_opt (str "cascade_name");
        models = None;
        oas_env = extract_oas_env_from_doc doc;
        unknown_toml_keys = [];
      })
    result

(** Fields actually read by [profile_defaults_of_toml] from the [[keeper]]
    TOML table.  Keep this in sync with the record construction above — the
    compile-time assertion below will fail if the two lists diverge. *)
let parsed_field_key_names =
  [ "name"
  ; "persona_name"
  ; "goal"
  ; "short_goal"
  ; "mid_goal"
  ; "long_goal"
  ; "will"
  ; "needs"
  ; "desires"
  ; "instructions"
  ; "policy_voice_enabled"
  ; "autoboot_enabled"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "proactive_idle_sec"
  ; "proactive_cooldown_sec"
  ; "room_signal_prompt_enabled"
  ; "shards"
  ; "allowed_paths"
  ; "sandbox_profile"
  ; "sandbox_image"
  ; "network_mode"
  ; "shared_memory_scope"
  ; "github_identity"
  ; "git_identity_mode"
  ; "tool_access.kind"
  ; "tool_access.preset"
  ; "tool_access.also_allow"
  ; "tool_access.tools"
  ; "tool_denylist"
  ; "active_goal_ids"
  ; "work_discovery_enabled"
  ; "work_discovery_sources"
  ; "work_discovery_interval_sec"
  ; "work_discovery_guidance"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "per_provider_timeout"
  ; "always_approve"
  ; "max_turns_per_call"
  ; "max_turns_per_call_scheduled_autonomous"
  ; "social_model"
  ; "cascade_name"
  ]

(** Canonical TOML key names used by [detect_unknown_keeper_toml_keys].
    Keys outside this set under [[keeper]] (or any other table) are silently
    ignored by the loader, which historically let dead config accumulate
    (e.g. legacy [legacy_scope], [scope_kind]).  [warn_unknown_keeper_toml_keys]
    uses this list to surface drift on boot, symmetric with
    [warn_unknown_keeper_meta_keys] on the JSON side.

    Must be kept in sync with [parsed_field_key_names] — the assertion below
    catches drift at compile time. *)
let canonical_keeper_toml_key_names =
  [ "name"
  ; "persona_name"
  ; "goal"
  ; "short_goal"
  ; "mid_goal"
  ; "long_goal"
  ; "will"
  ; "needs"
  ; "desires"
  ; "instructions"
  ; "policy_voice_enabled"
  ; "autoboot_enabled"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "proactive_idle_sec"
  ; "proactive_cooldown_sec"
  ; "room_signal_prompt_enabled"
  ; "shards"
  ; "allowed_paths"
  ; "sandbox_profile"
  ; "sandbox_image"
  ; "network_mode"
  ; "shared_memory_scope"
  ; "github_identity"
  ; "git_identity_mode"
  ; "tool_access.kind"
  ; "tool_access.preset"
  ; "tool_access.also_allow"
  ; "tool_access.tools"
  ; "tool_denylist"
  ; "active_goal_ids"
  ; "work_discovery_enabled"
  ; "work_discovery_sources"
  ; "work_discovery_interval_sec"
  ; "work_discovery_guidance"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "per_provider_timeout"
  ; "always_approve"
  ; "max_turns_per_call"
  ; "max_turns_per_call_scheduled_autonomous"
  ; "social_model"
  ; "cascade_name"
  ]

let () =
  assert (
    List.sort String.compare canonical_keeper_toml_key_names
    = List.sort String.compare parsed_field_key_names)

(** Pure detector: returns TOML keys that [profile_defaults_of_toml] does not
    consume.  Exposed separately from the logging wrapper so tests can
    assert on the key list without mocking the Log subsystem. *)
let detect_unknown_keeper_toml_keys (doc : Keeper_toml_loader.toml_doc) =
  let known =
    canonical_keeper_toml_key_names
    |> List.map (fun k -> "keeper." ^ k)
  in
  let oas_env_prefix = oas_env_key_prefix in
  let oas_env_prefix_len = String.length oas_env_prefix in
  let starts_with_oas_env k =
    String.length k > oas_env_prefix_len
    && String.sub k 0 oas_env_prefix_len = oas_env_prefix
  in
  doc
  |> List.map fst
  |> List.filter (fun key ->
       not (List.mem key known) && not (starts_with_oas_env key))
  |> dedupe_keep_order

let warn_unknown_keeper_toml_keys ~path (doc : Keeper_toml_loader.toml_doc) =
  match detect_unknown_keeper_toml_keys doc with
  | [] -> ()
  | unknown ->
    Log.Keeper.warn
      "keeper TOML %s has unknown keys: %s"
      path
      (String.concat ", " unknown)

let load_keeper_toml (path : string)
    : (string * keeper_profile_defaults, string) result =
  match Safe_ops.read_file_safe path with
  | Error e -> Error (Printf.sprintf "cannot read %s: %s" path e)
  | Ok content ->
    match Keeper_toml_loader.parse_toml content with
    | Error e -> Error (Printf.sprintf "%s: %s" path e)
    | Ok doc ->
      match profile_defaults_of_toml doc with
      | Error e -> Error (Printf.sprintf "%s: %s" path e)
      | Ok defaults ->
        let unknown_toml_keys = detect_unknown_keeper_toml_keys doc in
        warn_unknown_keeper_toml_keys ~path doc;
        let defaults = { defaults with unknown_toml_keys } in
        let name =
          match Keeper_toml_loader.toml_string_opt doc "keeper.name" with
          | Some n when n <> "" -> n
          | _ ->
            Filename.basename path
            |> Filename.remove_extension
        in
        if not (validate_name name) then
          Error (Printf.sprintf "%s: invalid keeper name '%s'" path name)
        else
          let id = Ids.Keeper_id.generate ~name ~path in
          Ok (name,
              { defaults with manifest_path = Some path
                            ; id = Some id })

(* #10259: every reconcile cycle calls [discover_keepers_toml], so a
   persistent fail mode (4 keepers stuck on cascade_name "ollama_only"
   while the materializer rejects it) emits 4 identical WARNs per
   cycle — 16+ events in a 43-minute window of system_log.  Dedup by
   [(filename, error_text)] so an unchanged failure is logged only on
   first observation; a *new* error text for the same file still
   emits, and a fresh process starts the table empty so restart
   diagnoses survive.  Mirrors the [logged_invalid_fallback] pattern
   in [Keeper_cascade_profile]. *)
let logged_toml_skip : (string * string, unit) Hashtbl.t = Hashtbl.create 8

let log_toml_skip_once ~file ~error =
  let key = (file, error) in
  if Hashtbl.mem logged_toml_skip key then false
  else begin
    Hashtbl.add logged_toml_skip key ();
    Log.Keeper.warn "toml_loader: skipping %s: %s" file error;
    true
  end

let reset_logged_toml_skip_for_test () = Hashtbl.clear logged_toml_skip

let discover_keepers_toml (dir : string)
    : (string * keeper_profile_defaults) list =
  if not (Fs_compat.file_exists dir && Sys.is_directory dir) then []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".toml")
    |> List.sort String.compare
    |> List.filter_map (fun f ->
         let path = Filename.concat dir f in
         match load_keeper_toml path with
         | Ok pair -> Some pair
         | Error e ->
           let _emitted = log_toml_skip_once ~file:f ~error:e in
           None)

let keeper_toml_path_opt name =
  Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
  Config_dir_resolver.keeper_toml_path_opt name

let load_keeper_profile_defaults_from_persona name : keeper_profile_defaults =
  match persona_profile_path_opt name with
  | None -> empty_keeper_profile_defaults
  | Some path -> (
      match Safe_ops.read_json_file_logged ~label:"load_keeper_profile_defaults" path with
      | None -> empty_keeper_profile_defaults
      | Some json ->
          let keeper_json = Yojson.Safe.Util.member "keeper" json in
          let per_provider_timeout_state, per_provider_timeout =
            per_provider_timeout_of_json_field
              ~source:(Printf.sprintf "persona profile %s" path)
              ~field:"per_provider_timeout"
              keeper_json
          in
          match keeper_json with
          | `Assoc _ ->
              {
                id = Some (Ids.Keeper_id.generate ~name ~path);
                manifest_path = Some path;
                persona_name = Some name;
                goal = Safe_ops.json_string_opt "goal" keeper_json;
                short_goal =
                  normalize_goal_horizon_opt
                    (Safe_ops.json_string_opt "short_goal" keeper_json);
                mid_goal =
                  normalize_goal_horizon_opt
                    (Safe_ops.json_string_opt "mid_goal" keeper_json);
                long_goal =
                  normalize_goal_horizon_opt
                    (Safe_ops.json_string_opt "long_goal" keeper_json);
                will = Safe_ops.json_string_opt "will" keeper_json;
                needs = Safe_ops.json_string_opt "needs" keeper_json;
                desires = Safe_ops.json_string_opt "desires" keeper_json;
                instructions = Safe_ops.json_string_opt "instructions" keeper_json;
                policy_voice_enabled =
                  (match Yojson.Safe.Util.member "policy_voice_enabled" keeper_json with
                  | `Bool flag -> Some flag
                  | _ -> None);
                autoboot_enabled = None;
                mention_targets = Safe_ops.json_string_list "mention_targets" keeper_json;
                proactive_enabled = Safe_ops.json_bool_opt "proactive_enabled" keeper_json;
                proactive_idle_sec = Safe_ops.json_int_opt "proactive_idle_sec" keeper_json;
                proactive_cooldown_sec = Safe_ops.json_int_opt "proactive_cooldown_sec" keeper_json;
                room_signal_prompt_enabled =
                  Safe_ops.json_bool_opt "room_signal_prompt_enabled" keeper_json;
                shards =
                  (match Safe_ops.json_string_list "shards" keeper_json with
                   | [] -> None
                   | xs -> Some xs);
                (* Persona profiles are not allowed to own execution allowlists.
                   Keep these in keeper TOML / runtime config only. *)
                allowed_paths = None;
                sandbox_profile = None;
                sandbox_image = None;
                network_mode = None;
                shared_memory_scope = None;
                github_identity = None;
                git_identity_mode = None;
                tool_preset = None;
                tool_preset_source = None;
                tool_also_allow = None;
                tool_denylist =
                  normalize_name_list_opt
                    (Safe_ops.json_string_list "tool_denylist" keeper_json);
                active_goal_ids = None;
                work_discovery_enabled =
                  Safe_ops.json_bool_opt "work_discovery_enabled" keeper_json;
                work_discovery_sources =
                  (match Safe_ops.json_string_list "work_discovery_sources" keeper_json with
                   | [] -> None
                   | xs -> Some xs);
                work_discovery_interval_sec =
                  Safe_ops.json_int_opt "work_discovery_interval_sec" keeper_json;
                work_discovery_guidance =
                  Safe_ops.json_string_opt "work_discovery_guidance" keeper_json;
                telemetry_feedback_enabled =
                  Safe_ops.json_bool_opt "telemetry_feedback_enabled" keeper_json;
                telemetry_feedback_window_hours =
                  Safe_ops.json_int_opt "telemetry_feedback_window_hours" keeper_json;
                per_provider_timeout_state;
                per_provider_timeout;
                always_approve =
                  Safe_ops.json_bool_opt "always_approve" keeper_json;
                max_turns_per_call =
                  Safe_ops.json_int_opt "max_turns_per_call" keeper_json;
                max_turns_per_call_scheduled_autonomous =
                  Safe_ops.json_int_opt
                    "max_turns_per_call_scheduled_autonomous" keeper_json;
                social_model =
                  (match
                     normalize_social_model_opt
                       (Safe_ops.json_string_opt "social_model" keeper_json)
                   with
                  | Some _ as normalized -> normalized
                  | None -> (
                      match
                        Safe_ops.json_string_opt "social_model" keeper_json
                      with
                      | Some raw ->
                          Log.Keeper.warn
                            "persona profile %s has invalid social_model '%s'; ignoring"
                            path raw;
                          None
                      | None -> None));
                cascade_name =
                  normalize_cascade_name_opt
                    (Safe_ops.json_string_opt "cascade_name" keeper_json);
                models =
                  (match Safe_ops.json_string_list "models" keeper_json with
                   | [] -> None
                   | xs -> Some xs);
                (* oas_env lives only in keeper TOML, not persona JSON —
                   persona profiles are a design-time artifact whereas
                   transport env is an ops-time toggle. *)
                oas_env = [];
                (* Persona JSON has no [keeper] TOML; nothing to flag. *)
                unknown_toml_keys = [];
              }
          | _ -> { empty_keeper_profile_defaults with manifest_path = Some path })

let merge_string_list ~base overlay =
  match overlay with [] -> base | xs -> xs

let merge_keeper_profile_defaults
    ~agent_name
    ~(base : keeper_profile_defaults)
    ~(overlay : keeper_profile_defaults) : keeper_profile_defaults =
  ignore agent_name;
  let prefer overlay_value base_value =
    match overlay_value with Some _ -> overlay_value | None -> base_value
  in
  let per_provider_timeout_state, per_provider_timeout =
    match overlay.per_provider_timeout_state with
    | Per_provider_timeout_unset ->
        base.per_provider_timeout_state, base.per_provider_timeout
    | Per_provider_timeout_invalid ->
        Per_provider_timeout_invalid, None
    | Per_provider_timeout_set ->
        Per_provider_timeout_set, overlay.per_provider_timeout
  in
  {
    id = prefer overlay.id base.id;
    manifest_path = prefer overlay.manifest_path base.manifest_path;
    persona_name = prefer overlay.persona_name base.persona_name;
    goal = prefer overlay.goal base.goal;
    short_goal = prefer overlay.short_goal base.short_goal;
    mid_goal = prefer overlay.mid_goal base.mid_goal;
    long_goal = prefer overlay.long_goal base.long_goal;
    will = prefer overlay.will base.will;
    needs = prefer overlay.needs base.needs;
    desires = prefer overlay.desires base.desires;
    instructions = prefer overlay.instructions base.instructions;
    policy_voice_enabled =
      prefer overlay.policy_voice_enabled base.policy_voice_enabled;
    autoboot_enabled = prefer overlay.autoboot_enabled base.autoboot_enabled;
    mention_targets =
      merge_string_list ~base:base.mention_targets overlay.mention_targets;
    proactive_enabled = prefer overlay.proactive_enabled base.proactive_enabled;
    proactive_idle_sec = prefer overlay.proactive_idle_sec base.proactive_idle_sec;
    proactive_cooldown_sec =
      prefer overlay.proactive_cooldown_sec base.proactive_cooldown_sec;
    room_signal_prompt_enabled =
      prefer overlay.room_signal_prompt_enabled base.room_signal_prompt_enabled;
    shards = prefer overlay.shards base.shards;
    allowed_paths = prefer overlay.allowed_paths base.allowed_paths;
    sandbox_profile = prefer overlay.sandbox_profile base.sandbox_profile;
    sandbox_image = prefer overlay.sandbox_image base.sandbox_image;
    network_mode = prefer overlay.network_mode base.network_mode;
    shared_memory_scope =
      prefer overlay.shared_memory_scope base.shared_memory_scope;
    github_identity = prefer overlay.github_identity base.github_identity;
    git_identity_mode =
      prefer overlay.git_identity_mode base.git_identity_mode;
    tool_preset = prefer overlay.tool_preset base.tool_preset;
    tool_preset_source =
      (match overlay.tool_preset_source with
       | Some _ as source -> source
       | None ->
         match overlay.tool_preset with
       | Some _ -> Some "toml"
       | None ->
           match base.tool_preset with
           | Some _ -> Some "persona"
           | None -> None);
    tool_also_allow = prefer overlay.tool_also_allow base.tool_also_allow;
    tool_denylist = prefer overlay.tool_denylist base.tool_denylist;
    active_goal_ids = prefer overlay.active_goal_ids base.active_goal_ids;
    work_discovery_enabled =
      prefer overlay.work_discovery_enabled base.work_discovery_enabled;
    work_discovery_sources =
      prefer overlay.work_discovery_sources base.work_discovery_sources;
    work_discovery_interval_sec =
      prefer overlay.work_discovery_interval_sec base.work_discovery_interval_sec;
    work_discovery_guidance =
      prefer overlay.work_discovery_guidance base.work_discovery_guidance;
    telemetry_feedback_enabled =
      prefer overlay.telemetry_feedback_enabled base.telemetry_feedback_enabled;
    telemetry_feedback_window_hours =
      prefer overlay.telemetry_feedback_window_hours
        base.telemetry_feedback_window_hours;
    per_provider_timeout_state;
    per_provider_timeout;
    always_approve = prefer overlay.always_approve base.always_approve;
    social_model = prefer overlay.social_model base.social_model;
    cascade_name = prefer overlay.cascade_name base.cascade_name;
    models = prefer overlay.models base.models;
    max_turns_per_call = prefer overlay.max_turns_per_call base.max_turns_per_call;
    max_turns_per_call_scheduled_autonomous =
      prefer overlay.max_turns_per_call_scheduled_autonomous
        base.max_turns_per_call_scheduled_autonomous;
    (* oas_env merges key-by-key: overlay wins per key, base keys that
       overlay doesn't mention survive.  Preserves the natural intent
       that a persona sets base defaults and keeper TOML layers its
       own toggles on top. *)
    oas_env =
      (let overlay_keys = List.map fst overlay.oas_env in
       let surviving_base =
         List.filter (fun (k, _) -> not (List.mem k overlay_keys)) base.oas_env
       in
       surviving_base @ overlay.oas_env);
    unknown_toml_keys =
      merge_string_list ~base:base.unknown_toml_keys overlay.unknown_toml_keys;
  }

(* Derived transport guards for combinations that are otherwise easy to
   misconfigure. *)
let oas_env_truthy value =
  match String.lowercase_ascii (String.trim value) with
  | "1" | "true" | "yes" | "on" -> true
  | _ -> false

let oas_env_has_non_empty key pairs =
  match List.assoc_opt key pairs with
  | Some value when String.trim value <> "" -> true
  | _ -> false

let effective_oas_env pairs =
  let gemini_mcp_disabled =
    match List.assoc_opt "OAS_GEMINI_NO_MCP" pairs with
    | Some value -> oas_env_truthy value
    | None -> false
  in
  if
    gemini_mcp_disabled
    && not (oas_env_has_non_empty "OAS_GEMINI_APPROVAL_MODE" pairs)
  then
    pairs @ [ ("OAS_GEMINI_APPROVAL_MODE", "plan") ]
  else
    pairs

type keeper_oas_context = {
  env_pairs : (string * string) list;
  gemini_mcp_disabled : bool;
  gemini_approval_mode : string option;
  gemini_approval_mode_derived : bool;
  claude_mcp_config : string option;
}

let empty_keeper_oas_context =
  {
    env_pairs = [];
    gemini_mcp_disabled = false;
    gemini_approval_mode = None;
    gemini_approval_mode_derived = false;
    claude_mcp_config = None;
  }

let keeper_oas_context_of_defaults (defaults : keeper_profile_defaults) :
    keeper_oas_context =
  let env_pairs = effective_oas_env defaults.oas_env in
  let gemini_mcp_disabled =
    match List.assoc_opt "OAS_GEMINI_NO_MCP" env_pairs with
    | Some value -> oas_env_truthy value
    | None -> false
  in
  let gemini_approval_mode_explicit =
    List.assoc_opt "OAS_GEMINI_APPROVAL_MODE" defaults.oas_env
    |> Option.map String.trim
    |> fun value -> Option.bind value (fun trimmed -> if trimmed = "" then None else Some trimmed)
  in
  let gemini_approval_mode =
    List.assoc_opt "OAS_GEMINI_APPROVAL_MODE" env_pairs
    |> Option.map String.trim
    |> fun value -> Option.bind value (fun trimmed -> if trimmed = "" then None else Some trimmed)
  in
  let gemini_approval_mode_derived =
    gemini_mcp_disabled
    && Option.is_none gemini_approval_mode_explicit
    && Option.is_some gemini_approval_mode
  in
  let claude_mcp_config =
    match List.assoc_opt "OAS_CLAUDE_MCP_CONFIG" env_pairs with
    | Some raw when String.trim raw <> "" -> Some raw
    | _ ->
      if
        match List.assoc_opt "OAS_CLAUDE_STRICT_MCP" env_pairs with
        | Some value -> oas_env_truthy value
        | None -> false
      then Some {|{"mcpServers":{}}|}
      else None
  in
  {
    env_pairs;
    gemini_mcp_disabled;
    gemini_approval_mode;
    gemini_approval_mode_derived;
    claude_mcp_config;
  }

let resolved_persona_name ~keeper_name
    (defaults : keeper_profile_defaults) : string =
  match defaults.persona_name with
  | Some name when String.trim name <> "" -> name
  | _ -> keeper_name

let load_keeper_profile_defaults_result name :
    (keeper_profile_defaults, string) result =
  (* Priority: TOML config/keepers/<name>.toml > persona profile.json.
     If TOML sets [persona_name], load that persona first and treat TOML as a
     thin overlay instead of duplicating the full keeper profile. *)
  match keeper_toml_path_opt name with
  | Some toml_path ->
    (match load_keeper_toml toml_path with
     | Ok (_name, defaults) -> (
         match defaults.persona_name with
         | Some persona_name ->
             let persona_defaults =
               load_keeper_profile_defaults_from_persona persona_name
             in
             Ok
               (merge_keeper_profile_defaults ~agent_name:name
                  ~base:persona_defaults ~overlay:defaults)
         | None -> Ok defaults)
     | Error e -> Error e)
  | None ->
    Ok (load_keeper_profile_defaults_from_persona name)

(* Classify a [load_keeper_toml] failure message into a low-cardinality
   label suitable for Prometheus. The raw error string embeds user input
   (invalid enum values etc.) and would blow up metric cardinality. *)
let classify_toml_failure_reason (err : string) : string =
  let err_lc = String.lowercase_ascii err in
  let contains needle =
    let nl = String.length needle in
    let hl = String.length err_lc in
    if nl = 0 then true
    else if nl > hl then false
    else
      let rec loop i =
        if i + nl > hl then false
        else if String.sub err_lc i nl = needle then true
        else loop (i + 1)
      in
      loop 0
  in
  if contains "invalid network_mode" then "invalid_network_mode"
  else if contains "invalid sandbox_profile" then "invalid_sandbox_profile"
  else if contains "invalid shared_memory_scope" then "invalid_shared_memory_scope"
  else if contains "invalid" then "invalid_enum"
  else if contains "unknown" || contains "unexpected field" then "unknown_field"
  else if contains "parse" || contains "syntax" then "parse_error"
  else "other"

let load_keeper_profile_defaults name : keeper_profile_defaults =
  match load_keeper_profile_defaults_result name with
  | Ok defaults -> defaults
  | Error e ->
    (match keeper_toml_path_opt name with
     | Some _ ->
       Log.Keeper.warn "toml config for %s failed (%s), falling back to persona" name e;
       Prometheus.inc_counter "masc_keeper_toml_invalid_total"
         ~labels:[ ("keeper", name); ("reason", classify_toml_failure_reason e) ]
         ()
     | None -> ());
    load_keeper_profile_defaults_from_persona name

(** Clamp a profile-provided max-turns override to [1, 100] — the same range
    enforced by [Keeper_runtime_resolved.reactive_max_turns_per_call].
    Values outside the range are rejected so a typo in TOML cannot silently
    bypass the budget envelope. *)
let clamp_max_turns_override : int option -> int option = function
  | Some n
    when n >= Keeper_runtime_resolved.max_turns_per_call_min
      && n <= Keeper_runtime_resolved.max_turns_per_call_max ->
    Some n
  | _ -> None

let effective_max_turns_per_call (profile : keeper_profile_defaults) : int =
  match clamp_max_turns_override profile.max_turns_per_call with
  | Some n -> n
  | None -> Keeper_runtime_resolved.reactive_max_turns_per_call ()

let effective_max_turns_per_call_scheduled_autonomous
    (profile : keeper_profile_defaults) : int =
  let global_cap = Keeper_runtime_resolved.reactive_max_turns_per_call () in
  match clamp_max_turns_override profile.max_turns_per_call_scheduled_autonomous with
  | Some n -> min n global_cap
  | None ->
    Keeper_runtime_resolved.autonomous_max_turns_per_call ()

type keeper_default_source_snapshot = {
  source_kind : string option;
  defaults : keeper_profile_defaults;
}

let keeper_default_source_snapshot name : keeper_default_source_snapshot =
  match keeper_toml_path_opt name with
  | Some toml_path -> (
      match load_keeper_toml toml_path with
      | Ok (_name, defaults) ->
          { source_kind = Some "toml"; defaults }
      | Error e ->
          Log.Keeper.warn
            "toml config for %s failed (%s), falling back to persona"
            name e;
          let defaults = load_keeper_profile_defaults_from_persona name in
          let source_kind =
            if Option.is_some defaults.manifest_path then Some "persona" else None
          in
          { source_kind; defaults })
  | None ->
      let defaults = load_keeper_profile_defaults_from_persona name in
      let source_kind =
        if Option.is_some defaults.manifest_path then Some "persona" else None
      in
      { source_kind; defaults }

(** Load extended persona description from AGENT.md if present.
    Truncated to [max_chars] to avoid bloating the system prompt. *)
let persona_description_max_chars = 4000

let load_persona_extended ?(max_chars = persona_description_max_chars) name : string option =
  let dirs =
    try Config_dir_resolver.personas_dirs ()
    with
    | Sys_error _ -> []
    | exn ->
        Log.Keeper.warn "load_persona_extended personas_dirs unexpected: %s"
          (Printexc.to_string exn);
        []
  in
  (* Later dirs (local) override earlier (repo) *)
  dirs
  |> List.rev
  |> List.find_map (fun root ->
      let path = Filename.concat (Filename.concat root name) "AGENT.md" in
      if Fs_compat.file_exists path then
        match Safe_ops.read_file_safe path with
        | Error msg ->
          Log.Keeper.warn "[load_agent_md] failed to read %s: %s" path msg;
          None
        | Ok content ->
          let trimmed = String.trim content in
          if String.length trimmed = 0 then None
          else if String.length trimmed <= max_chars then Some trimmed
          else Some (String.sub trimmed 0 max_chars ^ "\n[truncated]")
      else None)

let load_persona_summary name : persona_summary option =
  match persona_profile_path_opt name with
  | None -> None
  | Some path -> (
      match Safe_ops.read_json_file_logged ~label:"load_persona_summary" path with
      | None -> None
      | Some json ->
          let display_name =
            Safe_ops.json_string_opt "name" json |> Option.value ~default:name
          in
          let role = Safe_ops.json_string_opt "role" json in
          let trait = Safe_ops.json_string_opt "trait" json in
          let has_keeper_defaults =
            match Yojson.Safe.Util.member "keeper" json with
            | `Assoc _ -> true
            | _ -> false
          in
          Some
            {
              persona_name = name;
              display_name;
              role;
              trait;
              profile_path = path;
              has_keeper_defaults;
            })

let load_persona_summary_from_path name profile_path : persona_summary option =
  match Safe_ops.read_json_file_logged ~label:"load_persona_summary_from_path" profile_path with
  | None -> None
  | Some json ->
      let display_name =
        Safe_ops.json_string_opt "name" json |> Option.value ~default:name
      in
      let role = Safe_ops.json_string_opt "role" json in
      let trait = Safe_ops.json_string_opt "trait" json in
      let has_keeper_defaults =
        match Yojson.Safe.Util.member "keeper" json with
        | `Assoc _ -> true
        | _ -> false
      in
      Some
        {
          persona_name = name;
          display_name;
          role;
          trait;
          profile_path;
          has_keeper_defaults;
        }

let list_persona_summaries () : persona_summary list =
  let dirs =
    try Config_dir_resolver.personas_dirs ()
    with
    | Sys_error _ -> []
    | exn ->
        Log.Keeper.warn "list_persona_summaries personas_dirs unexpected: %s"
          (Printexc.to_string exn);
        []
  in
  let entries_from_dir root =
    try
      root
      |> Sys.readdir
      |> Array.to_list
      |> List.filter validate_name
      |> List.filter_map (fun name ->
             let profile_path =
               Filename.concat (Filename.concat root name) "profile.json"
             in
             if Fs_compat.file_exists profile_path then Some (name, profile_path)
             else None)
    with Sys_error _ -> []
  in
  (* Collect all persona (name, path) from all dirs; later dirs override *)
  let module SS = Set.Make (String) in
  let raw = dirs |> List.concat_map entries_from_dir in
  let all_entries =
    List.fold_left (fun (acc, seen) (name, path) ->
      if SS.mem name seen then (acc, seen)
      else ((name, path) :: acc, SS.add name seen))
      ([], SS.empty) raw
    |> fun (acc, _) -> List.rev acc
  in
  all_entries
  |> List.filter_map (fun (name, path) -> load_persona_summary_from_path name path)
  |> List.sort (fun a b -> String.compare a.persona_name b.persona_name)

let keeper_dir (config : Coord.config) =
  let d = Filename.concat (Coord.masc_root_dir config) "keepers" in
  ensure_dir d

let keeper_meta_path config name =
  Filename.concat (keeper_dir config) (name ^ ".json")

let session_base_dir (config : Coord.config) =
  let d = Filename.concat (Coord.masc_root_dir config) "traces" in
  ensure_dir d

(** Strip "keeper-" prefix if already present to prevent double-prefixing.
    E.g. "keeper-admin" -> "admin", "sangsu" -> "sangsu". *)
let strip_keeper_prefix name =
  let prefix = "keeper-" in
  let plen = String.length prefix in
  if String.length name > plen && String.sub name 0 plen = prefix
  then String.sub name plen (String.length name - plen)
  else name

let keeper_agent_name name =
  Printf.sprintf "keeper-%s-agent" (strip_keeper_prefix name)
