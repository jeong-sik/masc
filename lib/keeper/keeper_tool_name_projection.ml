(** Projection from internal keeper tool IDs to active model-facing names. *)

type context =
  | Model_facing
  | Internal_audit

type model_resolution =
  | Use_public_name of
      { public_name : string
      ; internal_name : string
      }
  | Use_internal_name of { internal_name : string }
  | No_visible_name of
      { internal_name : string
      ; public_names : string list
      }
  | Unknown_name of string

let visible_set visible_tool_names =
  let tbl = Hashtbl.create (List.length visible_tool_names) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) visible_tool_names;
  tbl
;;

let public_aliases_for_internal_name internal_name =
  Keeper_tool_alias.public_names ()
  |> List.filter (fun public_name ->
    match Keeper_tool_alias.route public_name with
    | Some route -> String.equal route.internal_name internal_name
    | None -> false)
;;

let resolve_model_name ~(visible_tool_names : string list) (name : string) =
  let visible = visible_set visible_tool_names in
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let internal_name =
    match Keeper_tool_alias.canonical_internal_name stripped with
    | Some internal_name -> internal_name
    | None -> stripped
  in
  let public_names = public_aliases_for_internal_name internal_name in
  let visible_public_name =
    List.find_opt (fun public_name -> Hashtbl.mem visible public_name) public_names
  in
  match visible_public_name with
  | Some public_name -> Use_public_name { public_name; internal_name }
  | None when Hashtbl.mem visible internal_name -> Use_internal_name { internal_name }
  | None when public_names <> [] || Keeper_tool_alias.is_known_internal internal_name ->
    No_visible_name { internal_name; public_names }
  | None -> Unknown_name name
;;

let model_name ~visible_tool_names name =
  match resolve_model_name ~visible_tool_names name with
  | Use_public_name { public_name; _ } -> Some public_name
  | Use_internal_name { internal_name } -> Some internal_name
  | No_visible_name _ | Unknown_name _ -> None
;;

let render_reference ~context ~visible_tool_names name =
  match context with
  | Internal_audit -> name
  | Model_facing ->
    (match resolve_model_name ~visible_tool_names name with
     | Use_public_name { public_name; _ } -> public_name
     | Use_internal_name { internal_name } -> internal_name
     | No_visible_name { internal_name; public_names } ->
       let alias_hint =
         match public_names with
         | [] -> ""
         | aliases ->
           Printf.sprintf
             " Public alias%s when visible: %s."
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

let blocker_guidance ~visible_tool_names internal_name =
  match resolve_model_name ~visible_tool_names internal_name with
  | No_visible_name { internal_name; public_names } ->
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
         "No model-facing tool for %s is visible in this turn; report the \
          blocker instead of inventing internal tool names.%s"
         internal_name
         alias_sentence)
  | Use_public_name _ | Use_internal_name _ | Unknown_name _ -> None
;;
