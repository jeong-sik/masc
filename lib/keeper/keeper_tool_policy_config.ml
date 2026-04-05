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

type t = {
  groups : (string, group_source) Hashtbl.t;
  masc_groups : (string, string list) Hashtbl.t;
  presets : (string, preset_def) Hashtbl.t;
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

(* ── Loading ──────────────────────────────────────────────────────── *)

let parse_groups (doc : Keeper_toml_loader.toml_doc) : (string, group_source) Hashtbl.t =
  let tbl = Hashtbl.create 16 in
  let names = collect_table_names doc ~prefix:"groups" in
  List.iter (fun name ->
    let source =
      match toml_string_opt_at doc "groups" (name ^ ".shard") with
      | Some shard_name -> Shard_ref shard_name
      | None ->
        let tools = toml_string_list_at doc "groups" (name ^ ".tools") in
        Static tools
    in
    Hashtbl.replace tbl name source
  ) names;
  tbl

let parse_masc_groups (doc : Keeper_toml_loader.toml_doc) : (string, string list) Hashtbl.t =
  let tbl = Hashtbl.create 8 in
  let names = collect_table_names doc ~prefix:"masc" in
  List.iter (fun name ->
    let tools = toml_string_list_at doc "masc" (name ^ ".tools") in
    if tools <> [] then
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
    let masc_tools = toml_string_list_at doc "presets" (name ^ ".masc_tools") in
    let all_candidates =
      match toml_bool_at doc "presets" (name ^ ".all_candidates") with
      | Some b -> b
      | None -> false
    in
    Hashtbl.replace tbl name { groups; masc_groups; masc_tools; all_candidates }
  ) names;
  tbl

let load ~base_path : (t, string) result =
  let path = Filename.concat base_path "config/tool_policy.toml" in
  match Safe_ops.read_file_safe path with
  | Error _ -> Error (Printf.sprintf "tool policy config not found: %s" path)
  | Ok content ->
    match Keeper_toml_loader.parse_toml content with
    | Error msg -> Error (Printf.sprintf "tool policy config parse error: %s" msg)
    | Ok doc ->
      let groups = parse_groups doc in
      let masc_groups = parse_masc_groups doc in
      let presets = parse_presets doc in
      Log.Keeper.info "tool_policy_config: loaded %d groups, %d masc_groups, %d presets from %s"
        (Hashtbl.length groups) (Hashtbl.length masc_groups) (Hashtbl.length presets) path;
      Ok { groups; masc_groups; presets }

(* ── Resolution ───────────────────────────────────────────────────── *)

let resolve_group_source = function
  | Static tools -> tools
  | Shard_ref shard_name ->
    match Tool_shard.get_shard shard_name with
    | Some shard ->
      shard.tools |> List.map (fun (t : Types.tool_schema) -> t.name)
    | None ->
      Log.Keeper.warn "tool_policy_config: shard '%s' not found, resolving to empty" shard_name;
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
  | Some def ->
    if def.all_candidates then
      Some All_candidates
    else
      let group_tools =
        def.groups
        |> List.concat_map (fun group_name ->
          match Hashtbl.find_opt config.groups group_name with
          | Some source -> resolve_group_source source
          | None ->
            Log.Keeper.warn "tool_policy_config: group '%s' referenced by preset '%s' not found"
              group_name preset_name;
            [])
      in
      let masc_from_groups =
        def.masc_groups
        |> List.concat_map (fun mg_name ->
          match Hashtbl.find_opt config.masc_groups mg_name with
          | Some tools -> List.filter masc_filter tools
          | None ->
            Log.Keeper.warn "tool_policy_config: masc group '%s' referenced by preset '%s' not found"
              mg_name preset_name;
            [])
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
