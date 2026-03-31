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

let normalize_similarity_text (s : string) : string =
  let len = String.length s in
  let buf = Bytes.create len in
  for i = 0 to len - 1 do
    let c = Char.lowercase_ascii s.[i] in
    let keep =
      (c >= 'a' && c <= 'z')
      || (c >= '0' && c <= '9')
      || c = ' '
    in
    Bytes.set buf i (if keep then c else ' ')
  done;
  Bytes.to_string buf

let similarity_tokens (s : string) : string list =
  s
  |> normalize_similarity_text
  |> Re.split (Re.Pcre.re "[ \t\r\n]+" |> Re.compile)
  |> List.filter (fun t -> String.length t >= 2)

let jaccard_similarity (a : string list) (b : string list) : float =
  let to_set xs =
    List.fold_left
      (fun acc x -> if List.mem x acc then acc else x :: acc)
      []
      xs
  in
  let sa = to_set a in
  let sb = to_set b in
  if sa = [] && sb = [] then 1.0
  else
    let inter =
      List.fold_left (fun n x -> if List.mem x sb then n + 1 else n) 0 sa
    in
    let union = List.length sa + List.length sb - inter in
    if union <= 0 then 0.0 else float_of_int inter /. float_of_int union

let proactive_similarity_score ~(candidate : string) ~(previous : string) : float =
  let a = similarity_tokens candidate in
  let b = similarity_tokens previous in
  jaccard_similarity a b

let soul_profile_policy profile =
  match profile with
  | "safety" ->
      "SOUL profile: safety-first.\n\
       Preserve first: user safety boundaries, explicit consent constraints, unresolved risks, and trust continuity.\n\
       Keep policy/guardrail decisions before optimization details."
  | "delivery" ->
      "SOUL profile: delivery.\n\
       Preserve first: concrete goal progress, accepted decisions, blockers, and next executable steps.\n\
       Keep implementation tradeoffs and done/not-done boundaries."
  | "research" ->
      "SOUL profile: research.\n\
       Preserve first: hypotheses, evidence, source-backed findings, and confidence/uncertainty.\n\
       Keep why conclusions changed, not just final statements."
  | "relationship" ->
      "SOUL profile: relationship.\n\
       Preserve first: user preferences, tone cues, collaboration style, and long-lived context about expectations.\n\
       Keep agreements and communication constraints."
  | "minimal" ->
      "SOUL profile: minimal.\n\
       Preserve only high-signal continuity: current goal, single most important decision, top blocker, and next action.\n\
       Aggressively drop low-value historical detail."
  | _ ->
      "SOUL profile: balanced.\n\
       Preserve in this order: safety/trust continuity, goal progress & decisions, unresolved risks, tool outcomes, style preferences."

let proactive_seed_for_soul_profile (profile : string) : string =
  match canonical_soul_profile profile |> Option.value ~default:default_soul_profile with
  | "safety" ->
      "Safety hint: prioritize current risk signals and mitigations."
  | "delivery" ->
      "Delivery hint: prioritize concrete next actions and execution momentum."
  | "research" ->
      "Research hint: you have access to masc_research_start and masc_research_status tools. \
       Periodically call masc_research_start with max_iterations=5 to find code improvements. \
       After each run, check masc_research_status and report results to the board. \
       Prioritize hypotheses, evidence, and validation steps. \
       Track keep rate — if it drops below 50%, adjust strategy."
  | "relationship" ->
      "Relationship hint: prioritize user intent alignment and collaboration continuity."
  | "minimal" ->
      "Minimal hint: keep only high-signal continuity and next move."
  | _ ->
      "Balanced hint: keep a practical mix of risk, progress, and next step."

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

let normalize_tool_preset_raw raw =
  let normalized = String.trim (String.lowercase_ascii raw) in
  match normalized with
  | "minimal" | "messaging" | "coding" | "research" | "full" -> Some normalized
  | _ -> None

let first_some = Dashboard_utils.first_some

let canonical_room_scope = function
  | "all" -> "all"
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
  soul_profile : string option;
  will : string option;
  needs : string option;
  desires : string option;
  instructions : string option;
  policy_voice_enabled : bool option;
  room_scope : string option;
  scope_kind : string option;
  mention_targets : string list;
  proactive_enabled : bool option;
  shards : string list option;
  allowed_paths : string list option;
  execution_scope : string option;
  tool_preset : string option;
  tool_also_allow : string list option;
  tool_denylist : string list option;
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
  soul_profile = None;
  will = None;
  needs = None;
  desires = None;
  instructions = None;
  policy_voice_enabled = None;
  room_scope = None;
  scope_kind = None;
  mention_targets = [];
  proactive_enabled = None;
  shards = None;
  allowed_paths = None;
  execution_scope = None;
  tool_preset = None;
  tool_also_allow = None;
  tool_denylist = None;
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
  match personas_root_opt () with
  | None -> None
  | Some root ->
      let path = Filename.concat (Filename.concat root name) "profile.json" in
      if Sys.file_exists path then Some path else None

(* ================================================================ *)
(* TOML -> keeper_profile_defaults conversion                        *)
(* ================================================================ *)

let profile_defaults_of_toml (doc : Keeper_toml_loader.toml_doc)
    : (keeper_profile_defaults, string) result =
  let k key = "keeper." ^ key in
  let str key = Keeper_toml_loader.toml_string_opt doc (k key) in
  let bool_ key = Keeper_toml_loader.toml_bool_opt doc (k key) in
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
      match str "soul_profile" with
      | Some raw ->
          (match canonical_soul_profile raw with
           | None ->
               Error
                 (Printf.sprintf
                    "invalid soul_profile '%s' (allowed: balanced, safety, delivery, research, relationship, minimal)"
                    raw)
           | Some _ -> Ok ())
      | None -> Ok ())
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
                     "invalid tool_preset '%s' (allowed: minimal, messaging, coding, research, full)"
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
        soul_profile =
          str "soul_profile"
          |> Option.map (fun s ->
               canonical_soul_profile s
               |> Option.value ~default:default_soul_profile);
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
        tool_also_allow = normalize_name_list_opt (strs "tool_also_allow");
        tool_denylist = normalize_name_list_opt (strs "tool_denylist");
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
  if not (Sys.file_exists dir && Sys.is_directory dir) then []
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
      match Safe_ops.read_json_file_safe path with
      | Error _ -> empty_keeper_profile_defaults
      | Ok json ->
          let keeper_json = Yojson.Safe.Util.member "keeper" json in
          match keeper_json with
          | `Assoc _ ->
              let soul_profile =
                match Safe_ops.json_string_opt "soul_profile" keeper_json with
                | None -> None
                | Some raw -> (
                    match canonical_soul_profile raw with
                    | Some profile -> Some profile
                    | None ->
                        Log.Keeper.warn
                          "persona profile %s has invalid soul_profile '%s'; ignoring"
                          path raw;
                        None)
              in
              {
                manifest_path = Some path;
                goal = Safe_ops.json_string_opt "goal" keeper_json;
                short_goal =
                  normalize_goal_horizon_opt (Safe_ops.json_string_opt "short_goal" keeper_json);
                mid_goal =
                  normalize_goal_horizon_opt (Safe_ops.json_string_opt "mid_goal" keeper_json);
                long_goal =
                  normalize_goal_horizon_opt (Safe_ops.json_string_opt "long_goal" keeper_json);
                soul_profile;
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
let load_persona_extended ?(max_chars = 4000) name : string option =
  match personas_root_opt () with
  | None -> None
  | Some root ->
    let path = Filename.concat (Filename.concat root name) "AGENT.md" in
    if Sys.file_exists path then
      match Safe_ops.read_file_safe path with
      | Error _ -> None
      | Ok content ->
        let trimmed = String.trim content in
        if String.length trimmed = 0 then None
        else if String.length trimmed <= max_chars then Some trimmed
        else Some (String.sub trimmed 0 max_chars ^ "\n[truncated]")
    else None

let load_persona_summary name : persona_summary option =
  match persona_profile_path_opt name with
  | None -> None
  | Some path -> (
      match Safe_ops.read_json_file_safe path with
      | Error _ -> None
      | Ok json ->
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

let list_persona_summaries () : persona_summary list =
  match personas_root_opt () with
  | None -> []
  | Some root ->
      root
      |> Sys.readdir
      |> Array.to_list
      |> List.filter validate_name
      |> List.filter_map load_persona_summary
      |> List.sort (fun a b -> String.compare a.persona_name b.persona_name)

let keeper_dir (config : Room.config) =
  let d = Filename.concat (Room.masc_root_dir config) "keepers" in
  ensure_dir d

let keeper_meta_path config name =
  Filename.concat (keeper_dir config) (name ^ ".json")

let session_base_dir (config : Room.config) =
  let d = Filename.concat (Room.masc_root_dir config) "traces" in
  ensure_dir d

let keeper_agent_name name =
  Printf.sprintf "keeper-%s-agent" name
