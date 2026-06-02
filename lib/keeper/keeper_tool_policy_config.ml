(** Keeper_tool_policy_config — load tool groups from config/tool_policy.toml.

    Groups define named tool lists for keeper [tool_access] composition.

    @since 2.236.0 *)

(* ── Types ────────────────────────────────────────────────────────── *)

type group_source =
  | Static of string list        (** Explicit tool name list *)
  | Shard_ref of string          (** Resolve from Tool_shard at runtime *)

type t = {
  groups : (string, group_source) Hashtbl.t;
  masc_groups : (string, string list) Hashtbl.t;
}

(* ── TOML parsing helpers ─────────────────────────────────────────── *)

let toml_string_list_at doc prefix key =
  Keeper_toml_loader.toml_string_list doc (prefix ^ "." ^ key)

let toml_string_opt_at doc prefix key =
  Keeper_toml_loader.toml_string_opt doc (prefix ^ "." ^ key)

let toml_bool_at doc prefix key =
  Keeper_toml_loader.toml_bool_opt doc (prefix ^ "." ^ key)

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

let dedupe_tool_names tools =
  let rec add seen acc = function
    | [] -> List.rev acc
    | raw :: rest ->
        let raw = String.trim raw in
        if String.equal raw "" then
          add seen acc rest
        else
          if List.mem raw seen then
            add seen acc rest
          else
            add (raw :: seen) (raw :: acc) rest
  in
  add [] [] tools

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
        let tools = dedupe_tool_names tools in
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
      let tools = dedupe_tool_names tools in
      Hashtbl.replace tbl name tools
  ) names;
  tbl

let unresolved_tool_message ~label ~name =
  match Keeper_tool_resolution.resolve name with
  | Keeper_tool_resolution.Resolved _ | Keeper_tool_resolution.Alias_to _ -> None
  | Keeper_tool_resolution.Unknown { tried; _ } ->
      Some (Printf.sprintf "%s: tool '%s' unresolved: tried [%s]"
              label name (Keeper_tool_resolution.string_of_tried tried))

(* Shortcut: if the caller's [base_path] already points at a project root
   that has [base_path/config/tool_policy.toml], prefer that directly.
   This is the common case when callers pass the result of
   [Masc_test_deps.find_project_root ()] in tests or the repo root in
   production. The direct check avoids the executable-relative walk in
   [Config_dir_resolver] which can pick up partial config shards
   materialised by dune into [_build/default/config/keeper_runtime.toml] and
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
        let unknown_static_tools =
          Hashtbl.fold (fun group_name (group : group_source) acc ->
            match group with
            | Static tools ->
                List.filter_map (fun t ->
                  unresolved_tool_message ~label:(Printf.sprintf "groups.%s" group_name) ~name:t
                ) tools
                |> List.rev_append acc
            | Shard_ref _ -> acc
          ) groups []
        in
        let unknown_shard_refs =
          Hashtbl.fold (fun group_name (group : group_source) acc ->
            match group with
            | Static _ -> acc
            | Shard_ref shard_name ->
              (match Tool_shard.get_shard shard_name with
               | Some _ -> acc
               | None ->
                 Printf.sprintf
                   "groups.%s: shard '%s' is not registered in Tool_shard"
                   group_name shard_name
                 :: acc)
          ) groups []
        in
        let unknown_masc_tools =
          Hashtbl.fold (fun group_name tools acc ->
            List.filter_map (fun t ->
              unresolved_tool_message ~label:(Printf.sprintf "masc.%s" group_name) ~name:t
            ) tools
            |> List.rev_append acc
          ) masc_groups []
        in
        (match unknown_shard_refs with
        | _ :: _ ->
            Log.Keeper.warn "tool_policy_config: %d unknown shard refs in %s"
              (List.length unknown_shard_refs) path;
            List.iter (fun e -> Log.Keeper.warn "  %s" e) unknown_shard_refs
        | [] -> ());
        (match unknown_static_tools @ unknown_masc_tools with
        | _ :: _ as errors ->
            Error (Printf.sprintf "in %s: %s" path (String.concat "; " errors))
        | [] ->
            Log.Keeper.info "tool_policy_config: loaded %d groups, %d masc_groups from %s"
              (Hashtbl.length groups) (Hashtbl.length masc_groups) path;
            Ok { groups; masc_groups })

(* ── Resolution ───────────────────────────────────────────────────── *)

let resolve_group_source = function
  | Static tools -> tools
  | Shard_ref shard_name ->
    match Tool_shard.get_shard shard_name with
    | Some shard ->
      shard.tools |> List.map (fun (t : Masc_domain.tool_schema) -> t.name)
    | None ->
      (* Missing shards are surfaced once per load by [load_config] via
         [unknown_shard_refs] (groups.X: shard 'Y' is not registered). The
         runtime path stays silent — emitting a WARN per resolution
         produced 31k+/day from a single stale ref and is the textbook
         Log Dedup workaround (CLAUDE.md §1). *)
      []

let resolve_group (config : t) (name : string) : string list option =
  match Hashtbl.find_opt config.groups name with
  | Some source -> Some (resolve_group_source source)
  | None -> None

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

