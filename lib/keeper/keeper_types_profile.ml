(** Keeper_types_profile — keeper profile defaults, persona loading,
    and directory path helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include Keeper_config
let keeper_debug = Env_config.KeeperRuntime.debug

type 'a context = {
  config: Room.config;
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

let lower_string_list_opt = function
  | [] -> None
  | xs -> Some (List.map String.lowercase_ascii xs)

let normalize_tool_preset_raw raw =
  let normalized = String.trim (String.lowercase_ascii raw) in
  match normalized with
  | "minimal" | "social" | "messaging" | "coding" | "research" | "delivery" | "full" -> Some normalized
  | _ -> None

let first_some = Dashboard_utils.first_some

let canonical_room_scope = function
  | _ -> "current"

let canonical_scope_kind = function
  | "global" -> "global"
  | _ -> "local"

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
  manifest_path : string option;
  goal : string option;
  short_goal : string option;
  mid_goal : string option;
  long_goal : string option;
  will : string option;
  needs : string option;
  desires : string option;
  instructions : string option;
  policy_voice_enabled : bool option;
  room_scope : string option;
  scope_kind : string option;
  mention_targets : string list;
  proactive_enabled : bool option;
  proactive_idle_sec : int option;
  proactive_cooldown_sec : int option;
  room_signal_prompt_enabled : bool option;
  shards : string list option;
  allowed_paths : string list option;
  execution_scope : string option;
  tool_preset : string option;
  tool_also_allow : string list option;
  tool_denylist : string list option;
  (* Work Discovery — config-driven proactive work scanning *)
  work_discovery_enabled : bool option;
  work_discovery_sources : string list option;
  work_discovery_interval_sec : int option;
  work_discovery_guidance : string option;
  (* Telemetry Feedback — inject behavioral stats into keeper context *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  cascade_name : string option;
}

type persona_summary = {
  persona_name : string;
  display_name : string;
  role : string option;
  trait : string option;
  profile_path : string;
  has_keeper_defaults : bool;
}

let empty_keeper_profile_defaults = {
  manifest_path = None;
  goal = None;
  short_goal = None;
  mid_goal = None;
  long_goal = None;
  will = None;
  needs = None;
  desires = None;
  instructions = None;
  policy_voice_enabled = None;
  room_scope = None;
  scope_kind = None;
  mention_targets = [];
  proactive_enabled = None;
  proactive_idle_sec = None;
  proactive_cooldown_sec = None;
  room_signal_prompt_enabled = None;
  shards = None;
  allowed_paths = None;
  execution_scope = None;
  tool_preset = None;
  tool_also_allow = None;
  tool_denylist = None;
  work_discovery_enabled = None;
  work_discovery_sources = None;
  work_discovery_interval_sec = None;
  work_discovery_guidance = None;
  telemetry_feedback_enabled = None;
  telemetry_feedback_window_hours = None;
  cascade_name = None;
}

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

let profile_defaults_of_toml (doc : Keeper_toml_loader.toml_doc)
    : (keeper_profile_defaults, string) result =
  let k key = "keeper." ^ key in
  let str key = Keeper_toml_loader.toml_string_opt doc (k key) in
  let bool_ key = Keeper_toml_loader.toml_bool_opt doc (k key) in
  let int_ key = Keeper_toml_loader.toml_int_opt doc (k key) in
  let strs key = Keeper_toml_loader.toml_string_list doc (k key) in
  let removed_present =
    removed_keeper_input_key_names
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
        match str "tool_preset" with
        | Some raw -> (
            match normalize_tool_preset_raw raw with
            | Some _ -> Ok ()
            | _ ->
                Error
                  (Printf.sprintf
                     "invalid tool_preset '%s' (allowed: minimal, messaging, coding, research, delivery, full)"
                     raw))
        | None -> Ok ())
  in
  Result.map
    (fun () ->
      {
        manifest_path = None;
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
        room_scope =
          str "room_scope"
          |> Option.map canonical_room_scope;
        scope_kind = str "scope_kind";
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
          (match strs "allowed_paths" with
           | [] -> None
           | xs -> Some xs);
        execution_scope = str "execution_scope";
        tool_preset =
          (match str "tool_preset" with
           | None -> None
           | Some raw -> normalize_tool_preset_raw raw);
        tool_also_allow =
          (match normalize_name_list_opt (strs "tool_also_allow") with
           | Some _ as explicit -> explicit
           | None ->
               (* Backward-compat alias kept in some live keeper TOMLs. *)
               normalize_name_list_opt (strs "also_allow"));
        tool_denylist = normalize_name_list_opt (strs "tool_denylist");
        work_discovery_enabled = bool_ "work_discovery_enabled";
        work_discovery_sources =
          (match strs "work_discovery_sources" with
           | [] -> None
           | xs -> Some xs);
        work_discovery_interval_sec = int_ "work_discovery_interval_sec";
        work_discovery_guidance = str "work_discovery_guidance";
        telemetry_feedback_enabled = bool_ "telemetry_feedback_enabled";
        telemetry_feedback_window_hours = int_ "telemetry_feedback_window_hours";
        cascade_name = str "cascade_name";
      })
    result

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
          Ok (name, { defaults with manifest_path = Some path })

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
           Log.Keeper.warn "toml_loader: skipping %s: %s" f e;
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
          match keeper_json with
          | `Assoc _ ->
              {
                manifest_path = Some path;
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
                room_scope = Safe_ops.json_string_opt "room_scope" keeper_json;
                scope_kind = Safe_ops.json_string_opt "scope_kind" keeper_json;
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
                allowed_paths =
                  (match Safe_ops.json_string_list "allowed_paths" keeper_json with
                   | [] -> None
                   | xs -> Some xs);
                execution_scope = Safe_ops.json_string_opt "execution_scope" keeper_json;
                tool_preset =
                  (match Safe_ops.json_string_opt "tool_preset" keeper_json with
                  | None -> None
                  | Some raw -> (
                      match normalize_tool_preset_raw raw with
                      | Some normalized -> Some normalized
                      | None ->
                          Log.Keeper.warn
                            "persona profile %s has invalid tool_preset '%s'; ignoring"
                            path raw;
                          None));
                tool_also_allow =
                  normalize_name_list_opt
                    (Safe_ops.json_string_list "tool_also_allow" keeper_json);
                tool_denylist =
                  normalize_name_list_opt
                    (Safe_ops.json_string_list "tool_denylist" keeper_json);
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
                cascade_name = Safe_ops.json_string_opt "cascade_name" keeper_json;
              }
          | _ -> { empty_keeper_profile_defaults with manifest_path = Some path })

let load_keeper_profile_defaults name : keeper_profile_defaults =
  (* Priority: TOML config/keepers/<name>.toml > persona profile.json *)
  match keeper_toml_path_opt name with
  | Some toml_path ->
    (match load_keeper_toml toml_path with
     | Ok (_name, defaults) -> defaults
     | Error e ->
       Log.Keeper.warn "toml config for %s failed (%s), falling back to persona" name e;
       load_keeper_profile_defaults_from_persona name)
  | None ->
    load_keeper_profile_defaults_from_persona name

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
  let seen = Hashtbl.create 32 in
  let all_entries =
    dirs
    |> List.concat_map entries_from_dir
    |> List.filter (fun (name, _) ->
           if Hashtbl.mem seen name then false
           else (Hashtbl.add seen name (); true))
  in
  all_entries
  |> List.filter_map (fun (name, path) -> load_persona_summary_from_path name path)
  |> List.sort (fun a b -> String.compare a.persona_name b.persona_name)

let keeper_dir (config : Room.config) =
  let d = Filename.concat (Room.masc_root_dir config) "keepers" in
  ensure_dir d

let keeper_meta_path config name =
  Filename.concat (keeper_dir config) (name ^ ".json")

let session_base_dir (config : Room.config) =
  let d = Filename.concat (Room.masc_root_dir config) "traces" in
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
