(** Projection from internal tool IDs to active schema-allowed names.

    This module is the SSOT for schema-allowed tool name resolution. All
    production code paths that produce schema-allowed text about tools must
    go through this module, not call runtime alias tables directly.

    @since 2.187.0 — RFC-0064 two-surface model
    @since 2.210.0 — wired into MCP server error path (#17023) *)

type context =
  | Schema_allowed
  | Internal_audit

type schema_resolution =
  | Use_public_name of
      { public_name : string
      ; internal_name : string
      }
  | Use_internal_name of { internal_name : string }
  | No_allowed_name of
      { internal_name : string
      ; public_names : string list
      }
  | Unknown_name of string

let allowed_set allowed_tool_names =
  let tbl = Hashtbl.create (List.length allowed_tool_names) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) allowed_tool_names;
  tbl
;;

let public_aliases_for_internal_name internal_name =
  Keeper_tool_descriptor_resolution.model_names_for_internal internal_name
;;

let public_alias_for_internal internal_name =
  Keeper_tool_descriptor_resolution.public_name_for_internal internal_name
;;

let resolve_allowed_name ~(allowed_tool_names : string list) (name : string) =
  let allowed = allowed_set allowed_tool_names in
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let internal_name =
    match Keeper_tool_descriptor_resolution.canonical_internal_name_for_tool_name stripped with
    | Some internal_name -> internal_name
    | None -> stripped
  in
  let public_names = public_aliases_for_internal_name internal_name in
  let allowed_public_name =
    List.find_opt (fun public_name -> Hashtbl.mem allowed public_name) public_names
  in
  match allowed_public_name with
  | Some public_name -> Use_public_name { public_name; internal_name }
  | None when Hashtbl.mem allowed internal_name -> Use_internal_name { internal_name }
  | None when public_names <> [] || Keeper_tool_alias.is_known_internal internal_name ->
    No_allowed_name { internal_name; public_names }
  | None -> Unknown_name name
;;

let allowed_name ~allowed_tool_names name =
  match resolve_allowed_name ~allowed_tool_names name with
  | Use_public_name { public_name; _ } -> Some public_name
  | Use_internal_name { internal_name } -> Some internal_name
  | No_allowed_name _ | Unknown_name _ -> None
;;

let render_reference ~context ~allowed_tool_names name =
  match context with
  | Internal_audit -> name
  | Schema_allowed ->
    (match resolve_allowed_name ~allowed_tool_names name with
     | Use_public_name { public_name; _ } -> public_name
     | Use_internal_name { internal_name } -> internal_name
     | No_allowed_name { internal_name; public_names } ->
       let alias_hint =
         match public_names with
         | [] -> ""
         | aliases ->
           Printf.sprintf
             " Public alias%s when allowed: %s."
             (if List.length aliases = 1 then "" else "es")
             (String.concat " or " aliases)
       in
       Printf.sprintf
         "No active schema name is visible for %s. Report the blocker instead \
          of inventing an internal tool call.%s"
         internal_name
         alias_hint
     | Unknown_name unknown ->
       Printf.sprintf
         "Unknown tool name %s. Use only names listed in the active schema."
         unknown)
;;

let blocker_guidance ~allowed_tool_names internal_name =
  match resolve_allowed_name ~allowed_tool_names internal_name with
  | No_allowed_name { internal_name; public_names } ->
    let alias_sentence =
      match public_names with
      | [] -> ""
      | aliases ->
        Printf.sprintf
          " Public alias%s when visible: %s."
          (if List.length aliases = 1 then "" else "es")
          (String.concat " or " aliases)
    in
    Some
      (Printf.sprintf
         "No schema-allowed tool for %s is allowed in this turn; report the \
          blocker instead of inventing internal tool names.%s"
         internal_name
         alias_sentence)
  | Use_public_name _ | Use_internal_name _ | Unknown_name _ -> None
;;

(** [filter_schema_visible_suggestions names] replaces internal names
    names with their public aliases and removes any that have no mapping.
    Used to sanitize "did you mean" suggestion lists so the caller never
    sees internal handler names. *)
let filter_schema_visible_suggestions names =
  names
  |> List.filter_map (fun name ->
    match public_alias_for_internal name with
    | Some public -> Some public
    | None when String.starts_with ~prefix:"keeper_" name -> None
    | None -> Some name)
  |> Keeper_types_profile_toml_normalizers.dedupe_keep_order
;;
