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

let expected_manifest_revision before =
  match member "manifest_revision" before with
  | Some (`Assoc _ as revision) -> Ok revision
  | Some _ | None -> Error "keeper manifest revision was not observed"

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
        if changed = []
        then Ok (`Assoc [])
        else
          Result.map
            (fun revision ->
              `Assoc (("expected_manifest_revision", revision) :: changed))
            (expected_manifest_revision before)
  | _ -> Error "keeper settings must remain a JSON object"

(* Marker column. The glyph carries the editable/read-only split on its own,
   because colour collapses to nothing under NO_COLOR and dim inverts on a
   light background. Colour repeats what the glyph already says. *)
let editable_glyph = "\xe2\x97\x8f"
let read_only_glyph = "\xe2\x97\x8b"

let label_width = 22

let styled code text =
  if String.equal code "" then text else code ^ text ^ Masc_tui_theme.Sgr.reset

(* Notes and values share one column so the eye reads the pane as a table
   rather than as ragged prose. Padding is computed from the visible prefix,
   which the styling codes do not add to. *)
let note_column = label_width + 5

let pad_to_note ~prefix_width = String.make (max 1 (note_column - prefix_width)) ' '

let section title note =
  let heading = styled Masc_tui_theme.Sgr.bold title in
  if String.equal note ""
  then " " ^ heading
  else
    Printf.sprintf " %s%s%s" heading
      (pad_to_note ~prefix_width:(1 + String.length title))
      (styled Masc_tui_theme.Sgr.dim note)

let marked_section glyph colour title note =
  Printf.sprintf " %s %s%s%s"
    (styled colour glyph)
    (styled Masc_tui_theme.Sgr.bold title)
    (pad_to_note ~prefix_width:(3 + String.length title))
    (styled Masc_tui_theme.Sgr.dim note)

let marked_row glyph colour label value =
  Printf.sprintf "  %s %s %s"
    (styled colour glyph)
    (styled colour (Printf.sprintf "%-*s" label_width label))
    value

let editable_row label value = marked_row editable_glyph Masc_tui_theme.Sgr.cyan label value
let read_only_row label value = marked_row read_only_glyph Masc_tui_theme.Sgr.dim label value

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

(* A stored field usually ends with a newline, which splits into a trailing
   empty line. Left in, it doubles the gap before the next heading and makes
   the line count in that heading one more than the reader can see. Interior
   blanks are the text's own paragraphs and stay. *)
let rec drop_trailing_blanks = function
  | [] -> []
  | lines ->
    (match List.rev lines with
     | last :: rest when String.trim last = "" -> drop_trailing_blanks (List.rev rest)
     | _ -> lines)

let free_text ~sanitize = function
  | Some (`String text) when String.trim text <> "" ->
    String.split_on_char '\n' text
    |> drop_trailing_blanks
    |> List.map (fun line -> "   " ^ sanitize line)
  | Some _ | None -> [ "   (not declared)" ]

let counted = function
  | [ "   (not declared)" ] -> "not declared"
  | [ _ ] -> "1 line"
  | lines -> Printf.sprintf "%d lines" (List.length lines)

let manifest_revision_value = function
  | Some (`Assoc [ ("state", `String "missing") ]) -> "missing"
  | Some (`Assoc fields) -> string_value (List.assoc_opt "value" fields)
  | value -> string_value value

(* One document, but the reader has to be able to answer "will [e] change
   this?" without counting rows against the editor stem. The glyph answers it
   on every line, and the field count in the heading is taken from the same
   snapshot the editor opens rather than from the rows drawn here — two rows
   share one heading (sandbox / network) and one row is derived, so a count of
   rows would be a different number than the one [e] shows. *)
let view_lines ~sanitize json =
  let at path = member_path path json in
  let text value = sanitize (value ()) in
  let editable_value_row label value = editable_row label (text value) in
  let read_only_value_row label value = read_only_row label (text value) in
  let sources = at [ "sources" ] in
  let source path = Option.bind sources (member_path path) in
  let editable_count =
    match editable_snapshot json with `Assoc fields -> List.length fields | _ -> 0
  in
  let prompt key = at [ "prompt"; key ] in
  let instructions = free_text ~sanitize (prompt "instructions") in
  let effective_prompt = free_text ~sanitize (prompt "effective_system_prompt") in
  [ Printf.sprintf " %s editable   %s read-only"
      (styled Masc_tui_theme.Sgr.cyan editable_glyph)
      (styled Masc_tui_theme.Sgr.dim read_only_glyph)
  ; ""
  ; section "edit here" "$EDITOR JSON form"
  ; "   Press e. Save and close the editor to apply; exit non-zero to cancel."
  ; "   Only changed fields are sent. The server validates before persisting."
  ; ""
  ; section "effective settings" (Printf.sprintf "e opens %d fields" editable_count)
  ; editable_value_row "Runtime"
      (fun () -> string_value (at [ "execution"; "selected_runtime_id" ]))
  ; editable_value_row "Autoboot" (fun () -> bool_value (at [ "autoboot_enabled" ]))
  ; editable_value_row "Autonomous turns"
      (fun () -> bool_value (at [ "proactive"; "enabled" ]))
  ; editable_value_row "Context override"
      (fun () -> int_override_value (at [ "max_context_override" ]))
  ; editable_value_row "Wake prompt override"
      (fun () -> string_value (at [ "autonomous_wake_prompt" ]))
  ; editable_value_row "Sandbox / network"
      (fun () ->
        Printf.sprintf "%s / %s"
          (string_value (at [ "sandbox_profile" ]))
          (string_value (at [ "network_mode" ])))
  ; editable_value_row "Allowed paths"
      (fun () -> string_list_value (at [ "allowed_paths" ]))
  ; editable_value_row "Mention targets"
      (fun () -> string_list_value (at [ "workspace"; "mention_targets" ]))
  ; editable_value_row "Skills"
      (fun () -> skill_selection_value (at [ "skills"; "names" ]))
  ; ""
  ; section "derived" "read-only"
  ; read_only_value_row "Manifest revision"
      (fun () -> manifest_revision_value (at [ "manifest_revision" ]))
  ; read_only_value_row "Effective paths"
      (fun () -> string_list_value (at [ "effective_allowed_paths" ]))
  ; ""
  ; section "provenance" "read-only"
  ; read_only_value_row "Live override"
      (fun () -> bool_value (source [ "has_live_override" ]))
  ; read_only_value_row "Override fields"
      (fun () -> string_list_value (source [ "override_fields" ]))
  ; read_only_value_row "Precedence"
      (fun () -> string_list_value (source [ "precedence" ]))
  ; read_only_value_row "Default manifest"
      (fun () -> string_value (source [ "default_manifest_path" ]))
  ; read_only_value_row "Live metadata"
      (fun () -> string_value (source [ "live_meta_path" ]))
  ; ""
  ; marked_section editable_glyph Masc_tui_theme.Sgr.cyan "instructions"
      (Printf.sprintf "editable \xc2\xb7 %s" (counted instructions))
  ]
  @ instructions
  @ [ ""
    ; marked_section read_only_glyph Masc_tui_theme.Sgr.dim "effective system prompt"
        (Printf.sprintf "read-only \xc2\xb7 %s" (counted effective_prompt))
    ]
  @ effective_prompt
  @ (match sources with
     | None -> []
     | Some value ->
       (* The named provenance rows above pick five fields out of this object.
          The raw block stays because the endpoint decides what else it sends,
          and dropping the rest would quietly narrow what the operator can
          see. *)
       ""
       :: marked_section read_only_glyph Masc_tui_theme.Sgr.dim "sources" "read-only \xc2\xb7 raw"
       :: (Yojson.Safe.pretty_to_string value
           |> String.split_on_char '\n'
           |> List.map (fun line -> "   " ^ sanitize line)))
  @ [ ""
    ; section "field rules" ""
    ; "   Skills: {} selects all; {\"names\":[]} selects none; names select exactly."
    ; "   Deleting a field means unchanged. null clears context/wake overrides."
    ]
;;
