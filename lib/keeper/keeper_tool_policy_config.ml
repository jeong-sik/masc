(** Keeper_tool_policy_config — load tool policy from config/tool_policy.toml.

    Replaces hardcoded preset definitions with declarative configuration.

    @since 2.236.0 *)

(* ── Types ────────────────────────────────────────────────────────── *)

type group_source =
  | Static of string list        (** Explicit tool name list *)
  | Shard_ref of string          (** Resolve from Tool_shard at runtime *)

type preset_resolution =
  | All_candidates        (** Use the entire candidate tool set *)
  | Subset of string list (** Use exactly this list of tool names *)

type preset_def = {
  groups : string list;          (** Group names to include *)
  masc_groups : string list;     (** MASC group names to include *)
  masc_tools : string list;      (** Individual MASC tool names *)
  all_candidates : bool;         (** true = include all candidate tools *)
}

type gh_cache_config = {
  cache_ttl_sec : float;
  fetch_page_size : int;
  fetch_timeout_sec : float;
  max_alternatives : int;
  max_output_bytes : int;
}

type git_clone_config = {
  allowed_orgs : string list;
  denied_repos : string list;
  default_depth : int;
  clone_timeout_sec : float;
  push_timeout_sec : float;
  pr_create_timeout_sec : float;
}

type t = {
  groups : (string, group_source) Hashtbl.t;
  masc_groups : (string, string list) Hashtbl.t;
  presets : (string, preset_def) Hashtbl.t;
  gh_cache : gh_cache_config;
  git_clone : git_clone_config;
}

(* ── TOML parsing helpers ─────────────────────────────────────────── *)

let toml_string_list_at doc prefix key =
  Keeper_toml_loader.toml_string_list doc (prefix ^ "." ^ key)

let toml_string_opt_at doc prefix key =
  Keeper_toml_loader.toml_string_opt doc (prefix ^ "." ^ key)

let toml_bool_at doc prefix key =
  Keeper_toml_loader.toml_bool_opt doc (prefix ^ "." ^ key)

let toml_int_at doc prefix key =
  Keeper_toml_loader.toml_int_opt doc (prefix ^ "." ^ key)

(** Collect all table prefixes matching a dotted prefix pattern.
    E.g., for prefix "groups" in a doc with "groups.base.tools",
    "groups.board.tools", returns ["base"; "board"]. *)
let collect_table_names (doc : Keeper_toml_loader.toml_doc) ~(prefix : string) : string list =
  let prefix_dot = prefix ^ "." in
  let prefix_len = String.length prefix_dot in
  doc
  |> List.filter_map (fun (key, _) ->
    if String.starts_with ~prefix:prefix_dot key then
      let rest = String.sub key prefix_len (String.length key - prefix_len) in
      match String.index_opt rest '.' with
      | Some idx -> Some (String.sub rest 0 idx)
      | None -> Some rest
    else
      None)
  |> List.sort_uniq String.compare

let normalize_tool_names ~scope tools =
  let alias_notes = ref [] in
  let dropped_notes = ref [] in
  let rec add seen acc = function
    | [] -> List.rev acc
    | raw :: rest ->
        let raw = String.trim raw in
        if String.equal raw "" then
          add seen acc rest
        else
          let resolved =
            match raw with
            | "keeper_fs_write" ->
                alias_notes := "keeper_fs_write -> keeper_fs_edit" :: !alias_notes;
                Some "keeper_fs_edit"
            | "keeper_fs_delete" ->
                dropped_notes :=
                  "keeper_fs_delete removed; use keeper_fs_edit patch/write or masc_code_delete"
                  :: !dropped_notes;
                None
            | name -> Some name
          in
          match resolved with
          | None -> add seen acc rest
          | Some name when List.mem name seen -> add seen acc rest
          | Some name -> add (name :: seen) (name :: acc) rest
  in
  let normalized = add [] [] tools in
  (match List.rev !alias_notes with
  | [] -> ()
  | notes ->
      Log.Keeper.info "tool_policy_config: normalized legacy tool name(s) in %s: %s"
        scope (String.concat ", " notes));
  (match List.rev !dropped_notes with
  | [] -> ()
  | notes ->
      Log.Keeper.info "tool_policy_config: dropped removed legacy tool name(s) in %s: %s"
        scope (String.concat ", " notes));
  normalized

(* ── Loading ──────────────────────────────────────────────────────── *)

let parse_groups (doc : Keeper_toml_loader.toml_doc) : ((string, group_source) Hashtbl.t, string) result =
  let tbl = Hashtbl.create 16 in
  let names = collect_table_names doc ~prefix:"groups" in
  let errors =
    List.filter_map (fun name ->
      let shard = toml_string_opt_at doc "groups" (name ^ ".shard") in
      let tools = toml_string_list_at doc "groups" (name ^ ".tools") in
      match shard, tools with
      | Some _, _ :: _ ->
        Some (Printf.sprintf
          "groups.%s: define exactly one of 'shard' or non-empty 'tools', not both" name)
      | Some shard_name, [] ->
        Hashtbl.replace tbl name (Shard_ref shard_name);
        None
      | None, _ :: _ ->
        let tools = normalize_tool_names ~scope:("groups." ^ name ^ ".tools") tools in
        Hashtbl.replace tbl name (Static tools);
        None
      | None, [] ->
        Some (Printf.sprintf
          "groups.%s: must define exactly one of 'shard' or non-empty 'tools'" name)
    ) names
  in
  match errors with
  | [] -> Ok tbl
  | _ -> Error (String.concat "; " errors)

let parse_masc_groups (doc : Keeper_toml_loader.toml_doc) : (string, string list) Hashtbl.t =
  let tbl = Hashtbl.create 8 in
  let names = collect_table_names doc ~prefix:"masc" in
  List.iter (fun name ->
    let tools = toml_string_list_at doc "masc" (name ^ ".tools") in
    if tools <> [] then
      let tools = normalize_tool_names ~scope:("masc." ^ name ^ ".tools") tools in
      Hashtbl.replace tbl name tools
  ) names;
  tbl

let parse_presets
    (doc : Keeper_toml_loader.toml_doc)
  : (string, preset_def) Hashtbl.t =
  let tbl = Hashtbl.create 8 in
  let names = collect_table_names doc ~prefix:"presets" in
  List.iter (fun name ->
    let groups = toml_string_list_at doc "presets" (name ^ ".groups") in
    let masc_groups = toml_string_list_at doc "presets" (name ^ ".masc_groups") in
    let masc_tools =
      toml_string_list_at doc "presets" (name ^ ".masc_tools")
      |> normalize_tool_names ~scope:("presets." ^ name ^ ".masc_tools")
    in
    let all_candidates =
      Option.value ~default:false
        (toml_bool_at doc "presets" (name ^ ".all_candidates"))
    in
    Hashtbl.replace tbl name { groups; masc_groups; masc_tools; all_candidates }
  ) names;
  tbl

let parse_gh_cache (doc : Keeper_toml_loader.toml_doc) : gh_cache_config =
  let cache_ttl_sec =
    Option.value ~default:120 (toml_int_at doc "gh_cache" "cache_ttl_sec")
    |> Float.of_int
  in
  let fetch_page_size =
    Option.value ~default:100 (toml_int_at doc "gh_cache" "fetch_page_size")
  in
  let fetch_timeout_sec =
    Option.value ~default:10 (toml_int_at doc "gh_cache" "fetch_timeout_sec")
    |> Float.of_int
  in
  let max_alternatives =
    Option.value ~default:20 (toml_int_at doc "gh_cache" "max_alternatives")
  in
  let max_output_bytes =
    Option.value ~default:8192 (toml_int_at doc "gh_cache" "max_output_bytes")
  in
  { cache_ttl_sec; fetch_page_size; fetch_timeout_sec;
    max_alternatives; max_output_bytes }

let parse_git_clone (doc : Keeper_toml_loader.toml_doc) : git_clone_config =
  let allowed_orgs = toml_string_list_at doc "git_clone" "allowed_orgs" in
  let denied_repos = toml_string_list_at doc "git_clone" "denied_repos" in
  let default_depth =
    Option.value ~default:0 (toml_int_at doc "git_clone" "default_depth")
  in
  let clone_timeout_sec =
    Option.value ~default:120 (toml_int_at doc "git_clone" "clone_timeout_sec")
    |> Float.of_int
  in
  let push_timeout_sec =
    Option.value ~default:60 (toml_int_at doc "git_clone" "push_timeout_sec")
    |> Float.of_int
  in
  let pr_create_timeout_sec =
    Option.value ~default:30 (toml_int_at doc "git_clone" "pr_create_timeout_sec")
    |> Float.of_int
  in
  { allowed_orgs; denied_repos; default_depth;
    clone_timeout_sec; push_timeout_sec; pr_create_timeout_sec }

(* Shortcut: if the caller's [base_path] already points at a project root
   that has [base_path/config/tool_policy.toml], prefer that directly.
   This is the common case when callers pass the result of
   [Masc_test_deps.find_project_root ()] in tests or the repo root in
   production. The direct check avoids the executable-relative walk in
   [Config_dir_resolver] which can pick up partial config shards
   materialised by dune into [_build/default/config/cascade.json] and
   resolve the wrong root. Scoped to this loader only — the generic
   resolver (used by dashboard/runtime code that reads per-env state
   from the resolved root) is untouched. *)
let config_root_for_base_path ~base_path =
  let base_path =
    if Filename.is_relative base_path then Filename.concat (Sys.getcwd ()) base_path
    else base_path
  in
  let direct_config = Filename.concat base_path "config" in
  let direct_policy =
    Filename.concat direct_config Config_dir_resolver.tool_policy_toml_filename
  in
  if Sys.file_exists direct_policy then (direct_config, [])
  else
    let inputs = Config_dir_resolver.inputs_from_env () in
    let inputs = { inputs with cwd = base_path; env_base_path = Some base_path } in
    let resolution = Config_dir_resolver.resolve_with inputs in
    (resolution.Config_dir_resolver.config_root.path, resolution.warnings)

let load ~base_path : (t, string) result =
  let config_root, resolution_warnings = config_root_for_base_path ~base_path in
  let path =
    Filename.concat config_root Config_dir_resolver.tool_policy_toml_filename
  in
  match Safe_ops.read_file_safe path with
  | Error msg ->
      let warning_detail =
        match resolution_warnings with
        | [] -> ""
        | warnings -> Printf.sprintf " warnings: %s" (String.concat " | " warnings)
      in
      Error
        (Printf.sprintf
           "tool policy config not found at resolved config root %s (%s).%s"
           path msg warning_detail)
  | Ok content ->
    match Keeper_toml_loader.parse_toml content with
    | Error msg -> Error (Printf.sprintf "tool policy config parse error in %s: %s" path msg)
    | Ok doc ->
      match parse_groups doc with
      | Error msg -> Error (Printf.sprintf "tool policy config group error in %s: %s" path msg)
      | Ok groups ->
        let masc_groups = parse_masc_groups doc in
        let presets = parse_presets doc in
        (* Validate that each preset's group references are defined *)
        let ref_errors =
          Hashtbl.fold (fun preset_name (def : preset_def) acc ->
            let bad_groups =
              List.filter (fun g -> not (Hashtbl.mem groups g)) def.groups
              |> List.rev_map (fun g ->
                Printf.sprintf "presets.%s: group '%s' is not defined" preset_name g)
            in
            let bad_masc_groups =
              List.filter (fun g -> not (Hashtbl.mem masc_groups g)) def.masc_groups
              |> List.rev_map (fun g ->
                Printf.sprintf "presets.%s: masc_group '%s' is not defined" preset_name g)
            in
            List.rev_append bad_groups (List.rev_append bad_masc_groups acc)
          ) presets []
        in
        let all_errors = ref_errors in
        (match all_errors with
        | _ :: _ -> Error (Printf.sprintf "in %s: %s" path (String.concat "; " all_errors))
        | [] ->
          (* Validate that all tool names in groups/masc_groups/presets are
             known to Tool_spec.  Skip shard-backed groups (resolved at
             runtime) and MASC tools (injected).

             Use [Tool_spec.is_known], NOT [Tool_dispatch.is_registered]:
             dispatch's registry only sees [Direct]/[Shared] handler
             bindings, while [Tag_dispatch]/[Match_chain] bindings — the
             majority of the [keeper_*] / [masc_*] surface — are
             dispatched via match patterns in [keeper_exec_tools.ml] etc.
             and would falsely register as unknown. The old check was
             flagging ~135 working tools as "not registered" on every
             boot. *)
          let unknown_tools =
            Hashtbl.fold (fun group_name (group : group_source) acc ->
              match group with
              | Static tools ->
                  List.filter (fun t -> not (Tool_spec.is_known t)) tools
                  |> List.rev_map (fun t ->
                    Printf.sprintf "groups.%s: tool '%s' is not registered" group_name t)
                  |> List.rev_append acc
              | Shard_ref _ -> acc
            ) groups []
          in
          let unknown_masc_tools =
            Hashtbl.fold (fun group_name tools acc ->
              List.filter (fun t -> not (Tool_spec.is_known t)) tools
              |> List.rev_map (fun t ->
                Printf.sprintf "masc_groups.%s: tool '%s' is not registered" group_name t)
              |> List.rev_append acc
            ) masc_groups []
          in
          let unknown_preset_tools =
            Hashtbl.fold (fun preset_name (def : preset_def) acc ->
              List.filter (fun t -> not (Tool_spec.is_known t)) def.masc_tools
              |> List.rev_map (fun t ->
                Printf.sprintf "presets.%s.masc_tools: tool '%s' is not registered" preset_name t)
              |> List.rev_append acc
            ) presets []
          in
          let all_tool_errors = unknown_tools @ unknown_masc_tools @ unknown_preset_tools in
          (match all_tool_errors with
          | _ :: _ ->
              Log.Keeper.warn "tool_policy_config: %d unknown tools in %s" (List.length all_tool_errors) path;
              List.iter (fun e -> Log.Keeper.warn "  %s" e) all_tool_errors
          | [] -> ());
          let gh_cache = parse_gh_cache doc in
          let git_clone = parse_git_clone doc in
          Log.Keeper.info "tool_policy_config: loaded %d groups, %d masc_groups, %d presets from %s"
            (Hashtbl.length groups) (Hashtbl.length masc_groups) (Hashtbl.length presets) path;
          Ok { groups; masc_groups; presets; gh_cache; git_clone })

(* ── Resolution ───────────────────────────────────────────────────── *)

let resolve_group_source = function
  | Static tools -> tools
  | Shard_ref shard_name ->
    match Tool_shard.get_shard shard_name with
    | Some shard ->
      shard.tools |> List.map (fun (t : Masc_domain.tool_schema) -> t.name)
    | None ->
      Log.Keeper.warn "tool_policy_config: shard '%s' not found, returning empty" shard_name;
      []

let resolve_group (config : t) (name : string) : string list option =
  match Hashtbl.find_opt config.groups name with
  | Some source -> Some (resolve_group_source source)
  | None -> None

let resolve_preset
    (config : t)
    (preset_name : string)
    ?(masc_filter = fun _ -> true)
    ()
  : preset_resolution option =
  match Hashtbl.find_opt config.presets preset_name with
  | None -> None
  | Some (def : preset_def) ->
    if def.all_candidates then
      Some All_candidates
    else
      let group_tools =
        def.groups
        |> List.concat_map (fun group_name ->
          match Hashtbl.find_opt config.groups group_name with
          | Some group -> resolve_group_source group
          | None -> [])
      in
      let masc_from_groups =
        def.masc_groups
        |> List.concat_map (fun mg_name ->
          match Hashtbl.find_opt config.masc_groups mg_name with
          | Some tools -> List.filter masc_filter tools
          | None -> [])
      in
      let masc_individual =
        def.masc_tools |> List.filter masc_filter
      in
      Some (Subset (group_tools @ masc_from_groups @ masc_individual))

let preset_names (config : t) : string list =
  Hashtbl.fold (fun name _ acc -> name :: acc) config.presets []
  |> List.sort String.compare

let group_names (config : t) : string list =
  Hashtbl.fold (fun name _ acc -> name :: acc) config.groups []
  |> List.sort String.compare

let all_group_tools (config : t) : string list =
  group_names config
  |> List.concat_map (fun name ->
    match Hashtbl.find_opt config.groups name with
    | Some group -> resolve_group_source group
    | None -> [])

let all_masc_tools (config : t) : string list =
  Hashtbl.fold (fun _ tools acc -> tools @ acc) config.masc_groups []

(** Check if [agent_preset]'s resolved tool set covers [required_preset]'s.
    Derived from config — adding a new preset to tool_policy.toml automatically
    updates the subsumption graph.  No hardcoded hierarchy. *)
let preset_can_satisfy (config : t) ~(agent_preset : string) ~(required_preset : string) : bool =
  if String.equal agent_preset required_preset then true
  else
    let resolve name =
      match resolve_preset config name ~masc_filter:(fun _ -> true) () with
      | Some All_candidates -> `Full
      | Some (Subset tools) -> `Tools (List.sort_uniq String.compare tools)
      | None -> `Unknown
    in
    match resolve agent_preset, resolve required_preset with
    | `Unknown, _ | _, `Unknown -> false  (* unknown preset — can't verify, reject *)
    | `Full, _ -> true                     (* agent has full access *)
    | _, `Full -> false                    (* required is full, agent isn't *)
    | `Tools agent_tools, `Tools req_tools ->
      List.for_all (fun t -> List.mem t agent_tools) req_tools

(* ── GH cache config accessors ───────────────────────────────────── *)

let gh_cache_ttl_sec (config : t) : float =
  config.gh_cache.cache_ttl_sec

let gh_cache_fetch_page_size (config : t) : int =
  config.gh_cache.fetch_page_size

let gh_cache_fetch_timeout_sec (config : t) : float =
  config.gh_cache.fetch_timeout_sec

let gh_cache_max_alternatives (config : t) : int =
  config.gh_cache.max_alternatives

let gh_cache_max_output_bytes (config : t) : int =
  config.gh_cache.max_output_bytes

(* ── Git clone config accessors ──────────────────────────────────── *)

let git_clone_allowed_orgs (config : t) : string list =
  config.git_clone.allowed_orgs

let git_clone_denied_repos (config : t) : string list =
  config.git_clone.denied_repos

let clone_depth (config : t) : int =
  config.git_clone.default_depth

let clone_timeout_sec (config : t) : float =
  config.git_clone.clone_timeout_sec

let push_timeout_sec (config : t) : float =
  config.git_clone.push_timeout_sec

let pr_create_timeout_sec (config : t) : float =
  config.git_clone.pr_create_timeout_sec
