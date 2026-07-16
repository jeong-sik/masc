include Keeper_config

type persona_summary =
  { persona_name : string
  ; display_name : string
  ; role : string option
  ; trait : string option
  ; profile_path : string
  ; has_keeper_defaults : bool
  }

let operator_todo_placeholder_marker = "OPERATOR_TODO"

let string_has_operator_todo_placeholder value =
  String_util.contains_substring value operator_todo_placeholder_marker
;;

let rec json_has_operator_todo_placeholder = function
  | `String value -> string_has_operator_todo_placeholder value
  | `Assoc fields ->
    List.exists
      (fun (key, value) ->
        string_has_operator_todo_placeholder key
        || json_has_operator_todo_placeholder value)
      fields
  | `List values -> List.exists json_has_operator_todo_placeholder values
  | `Tuple values -> List.exists json_has_operator_todo_placeholder values
  | `Variant (name, value) ->
    string_has_operator_todo_placeholder name
    ||
    (match value with
     | Some json -> json_has_operator_todo_placeholder json
     | None -> false)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Floatlit _ -> false
;;

let json_operator_todo_placeholder_paths json =
  let child_path path key = if path = "$" then "$." ^ key else path ^ "." ^ key in
  let indexed_path path index = Printf.sprintf "%s[%d]" path index in
  let rec loop path = function
    | `String value ->
      if string_has_operator_todo_placeholder value then [ path ] else []
    | `Assoc fields ->
      fields
      |> List.map (fun (key, value) ->
        let field_path = child_path path key in
        let key_hits =
          if string_has_operator_todo_placeholder key then [ field_path ] else []
        in
        key_hits @ loop field_path value)
      |> List.concat
    | `List values | `Tuple values ->
      values
      |> List.mapi (fun index value -> loop (indexed_path path index) value)
      |> List.concat
    | `Variant (name, value) ->
      let variant_path = child_path path name in
      let name_hits =
        if string_has_operator_todo_placeholder name then [ variant_path ] else []
      in
      name_hits
      @
      (match value with
       | Some json -> loop variant_path json
       | None -> [])
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Floatlit _ -> []
  in
  loop "$" json
;;

let reject_placeholder_persona_profile ~label ~path json =
  if json_has_operator_todo_placeholder json
  then (
    Log.Keeper.warn
      "%s: rejecting persona profile %s because it contains %s placeholder text"
      label
      path
      operator_todo_placeholder_marker;
    true)
  else false
;;

let personas_root_opt () =
  try
    Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
    Config_dir_resolver.personas_dir_opt ()
  with
  | Sys_error _ -> None
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ProfileLoadFailures)
      ~labels:[ "site", Keeper_profile_load_failure_site.(to_label Personas_root) ]
      ();
    Log.Keeper.warn "personas_root_opt unexpected: %s" (Printexc.to_string exn);
    None
;;

let persona_profile_path_opt_in_dirs dirs name =
  (* Search the resolved persona roots only.
     Config_dir_resolver.personas_dirs now returns a single source of truth:
     explicit MASC_PERSONAS_DIR or resolved CONFIG_ROOT/personas. *)
  dirs
  |> List.find_map (fun root ->
    let path = Filename.concat (Filename.concat root name) "profile.json" in
    if Fs_compat.file_exists path then Some path else None)
;;

let persona_profile_path_opt name =
  let dirs =
    try
      Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
      Config_dir_resolver.personas_dirs ()
    with
    | Sys_error _ -> []
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ProfileLoadFailures)
        ~labels:[ "site", Keeper_profile_load_failure_site.(to_label Personas_dirs_resolve) ]
        ();
      Log.Keeper.warn "personas_dirs unexpected: %s" (Printexc.to_string exn);
      []
  in
  persona_profile_path_opt_in_dirs dirs name
;;

(** Load extended persona description from AGENT.md if present.
    Truncated to [max_chars] to avoid bloating the system prompt. *)
let persona_description_max_chars = 4000

let load_persona_extended ?(max_chars = persona_description_max_chars) name
  : string option =
  let dirs =
    try Config_dir_resolver.personas_dirs () with
    | Sys_error _ -> []
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ProfileLoadFailures)
        ~labels:[ "site", Keeper_profile_load_failure_site.(to_label Load_persona_extended) ]
        ();
      Log.Keeper.warn
        "load_persona_extended personas_dirs unexpected: %s"
        (Printexc.to_string exn);
      []
  in
  (* Later dirs (local) override earlier (repo) *)
  dirs
  |> List.rev
  |> List.find_map (fun root ->
    let path = Filename.concat (Filename.concat root name) "AGENT.md" in
    if Fs_compat.file_exists path
    then
      match Safe_ops.read_file_safe path with
      | Error msg ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string ProfileLoadFailures)
          ~labels:[ "site", Keeper_profile_load_failure_site.(to_label Agent_md_read) ]
          ();
        Log.Keeper.warn "[load_agent_md] failed to read %s: %s" path msg;
        None
      | Ok content ->
        let trimmed = String.trim content in
        if String.length trimmed = 0
        then None
        else if String.length trimmed <= max_chars
        then Some trimmed
        else Some (String.sub trimmed 0 max_chars ^ "\n[truncated]")
    else None)
;;

let persona_summary_of_profile_json name profile_path json =
  if reject_placeholder_persona_profile ~label:"load_persona_summary" ~path:profile_path json
  then None
  else (
    let display_name =
      match Safe_ops.json_string_opt "name" json with
      | Some value -> value
      | None -> name
    in
    let role = Safe_ops.json_string_opt "role" json in
    let trait = Safe_ops.json_string_opt "trait" json in
    let has_keeper_defaults =
      match Json_util.assoc_member_opt "keeper" json with
      | Some (`Assoc _) -> true
      | _ -> false
    in
    Some { persona_name = name; display_name; role; trait; profile_path; has_keeper_defaults })
;;

let load_persona_summary name : persona_summary option =
  match persona_profile_path_opt name with
  | None -> None
  | Some path ->
    (match Safe_ops.read_json_file_logged ~label:"load_persona_summary" path with
     | None -> None
     | Some json -> persona_summary_of_profile_json name path json)
;;

let load_persona_summary_from_path name profile_path : persona_summary option =
  match Safe_ops.read_json_file_logged ~label:"load_persona_summary_from_path" profile_path with
  | None -> None
  | Some json -> persona_summary_of_profile_json name profile_path json
;;

let list_persona_summaries () : persona_summary list =
  let dirs =
    try Config_dir_resolver.personas_dirs () with
    | Sys_error _ -> []
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ProfileLoadFailures)
        ~labels:[ "site", Keeper_profile_load_failure_site.(to_label List_persona_summaries) ]
        ();
      Log.Keeper.warn
        "list_persona_summaries personas_dirs unexpected: %s"
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
        let profile_path = Filename.concat (Filename.concat root name) "profile.json" in
        if Fs_compat.file_exists profile_path then Some (name, profile_path) else None)
    with
    | Sys_error _ -> []
  in
  (* Collect all persona (name, path) from all dirs; later dirs override. *)
  let module SS = Set_util.StringSet in
  let raw = dirs |> List.concat_map entries_from_dir in
  let all_entries =
    List.fold_left
      (fun (acc, seen) (name, path) ->
        if SS.mem name seen then acc, seen else (name, path) :: acc, SS.add name seen)
      ([], SS.empty)
      raw
    |> fun (acc, _) -> List.rev acc
  in
  all_entries
  |> List.filter_map (fun (name, path) -> load_persona_summary_from_path name path)
  |> List.sort (fun a b -> String.compare a.persona_name b.persona_name)
;;
