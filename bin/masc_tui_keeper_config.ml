(* Pure projection for the Keeper settings surface and its $EDITOR round-trip.
   Keeping this apart from HTTP makes the important promise testable: the
   editor starts from observed values, while the PATCH contains only values the
   operator actually changed. *)

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let member_path path json =
  List.fold_left
    (fun current key -> Option.bind current (member key))
    (Some json) path

type editable_field =
  | Direct of string * string list
  | Skill_selection

let editable_fields =
  [ Direct ("runtime_id", [ "execution"; "selected_runtime_id" ])
  ; Direct ("mention_targets", [ "workspace"; "mention_targets" ])
  ; Direct ("autoboot_enabled", [ "autoboot_enabled" ])
  ; Direct ("max_context_override", [ "max_context_override" ])
  ; Direct ("autonomous_wake_prompt", [ "autonomous_wake_prompt" ])
  ; Direct ("allowed_paths", [ "allowed_paths" ])
  ; Direct ("sandbox_profile", [ "sandbox_profile" ])
  ; Direct ("network_mode", [ "network_mode" ])
  ; Direct ("instructions", [ "prompt"; "instructions" ])
  ; Direct ("proactive_enabled", [ "proactive"; "enabled" ])
  ; Skill_selection
  ]

let editable_field_name = function
  | Direct (name, _) -> name
  | Skill_selection -> "skills"

(* The read contract represents the default selection as [names: null], while
   the write contract represents it as an empty [skills] object. Normalize at
   this projection boundary so every value shown in the editor is also a valid
   partial update. *)
let editable_field_value json = function
  | Direct (_, path) -> member_path path json
  | Skill_selection -> (
    match member_path [ "skills"; "names" ] json with
    | Some `Null -> Some (`Assoc [])
    | Some (`List names) -> Some (`Assoc [ "names", `List names ])
    | Some _ | None -> None)

let editable_snapshot json =
  `Assoc
    (List.filter_map
       (fun field ->
         Option.map
           (fun value -> editable_field_name field, value)
           (editable_field_value json field))
       editable_fields)

let editor_stem json =
  editable_snapshot json |> Yojson.Safe.pretty_to_string |> fun text -> text ^ "\n"

let editable_field_names = List.map editable_field_name editable_fields

let patch_of_edit ~before ~after =
  match after with
  | `Assoc edited_fields ->
      let unknown =
        edited_fields
        |> List.filter_map (fun (key, _) ->
               if List.mem key editable_field_names then None else Some key)
      in
      if unknown <> [] then
        Error ("unknown keeper setting(s): " ^ String.concat ", " unknown)
      else
        let before_fields =
          match editable_snapshot before with
          | `Assoc fields -> fields
          | _ -> assert false
        in
        let changed =
          edited_fields
          |> List.filter (fun (key, value) ->
                 match List.assoc_opt key before_fields with
                 | Some old_value -> not (Yojson.Safe.equal value old_value)
                 | None -> true)
        in
        Ok (`Assoc changed)
  | _ -> Error "keeper settings must remain a JSON object"

let string_value ?(missing = "not observed") = function
  | Some (`String value) when String.trim value <> "" -> value
  | Some (`String _) -> "(empty)"
  | Some `Null -> "default"
  | Some value -> Yojson.Safe.to_string value
  | None -> missing

let bool_value = function
  | Some (`Bool true) -> "on"
  | Some (`Bool false) -> "off"
  | value -> string_value value

let string_list_value = function
  | Some (`List []) -> "none"
  | Some (`List values) ->
      values
      |> List.map (function
           | `String value -> value
           | value -> Yojson.Safe.to_string value)
      |> String.concat ", "
  | value -> string_value value

let int_override_value = function
  | Some `Null -> "default runtime window"
  | Some (`Int value) -> Printf.sprintf "%d tokens" value
  | value -> string_value value

let skill_selection_value = function
  | Some `Null -> "all published Skills"
  | Some (`List []) -> "none"
  | Some (`List names) -> string_list_value (Some (`List names))
  | value -> string_value value

let row label value = Printf.sprintf "%-22s %s" label value

let view_lines json =
  let at path = member_path path json in
  let sources = at [ "sources" ] in
  let source path = Option.bind sources (member_path path) in
  [ "# effective settings"
  ; row "Runtime" (string_value (at [ "execution"; "selected_runtime_id" ]))
  ; row "Autoboot" (bool_value (at [ "autoboot_enabled" ]))
  ; row "Autonomous turns" (bool_value (at [ "proactive"; "enabled" ]))
  ; row "Context override" (int_override_value (at [ "max_context_override" ]))
  ; row "Wake prompt override" (string_value (at [ "autonomous_wake_prompt" ]))
  ; row "Sandbox / network"
      (Printf.sprintf "%s / %s"
         (string_value (at [ "sandbox_profile" ]))
         (string_value (at [ "network_mode" ])))
  ; row "Allowed paths" (string_list_value (at [ "allowed_paths" ]))
  ; row "Effective paths" (string_list_value (at [ "effective_allowed_paths" ]))
  ; row "Mention targets"
      (string_list_value (at [ "workspace"; "mention_targets" ]))
  ; row "Skills" (skill_selection_value (at [ "skills"; "names" ]))
  ; ""
  ; "# provenance"
  ; row "Live override" (bool_value (source [ "has_live_override" ]))
  ; row "Override fields" (string_list_value (source [ "override_fields" ]))
  ; row "Precedence" (string_list_value (source [ "precedence" ]))
  ; row "Default manifest" (string_value (source [ "default_manifest_path" ]))
  ; row "Live metadata" (string_value (source [ "live_meta_path" ]))
  ; ""
  ; "# editing"
  ; "Press e to edit the observed values. Only changed fields are sent."
  ; "Skills: {} selects all; {\"names\":[]} selects none; names select exactly."
  ; "Deleting a field means unchanged. null clears context/wake overrides."
  ]
