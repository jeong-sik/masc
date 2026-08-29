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

(* Control key, not a setting: the server refuses a patch that lowers
   [max_context_override] unless it carries this flag, and its refusal tells
   the operator to re-send with it. Without accepting the key here that
   instruction was impossible to follow — [patch_of_edit] answered
   "unknown keeper setting(s): confirm_context_shrink" and the TUI had no way
   at all to shrink a keeper's context window. It stays out of
   [editable_fields] so it never appears in the editor stem or the view: the
   operator types it only when the server has asked for it. SSOT for the name
   is the server's [confirm_context_shrink_field]. *)
let confirm_context_shrink_field = "confirm_context_shrink"

let is_lowercase_sha256 = String_util.is_lowercase_sha256_hex

let exact_keys expected fields =
  List.length fields = List.length expected
  && List.for_all (fun key -> List.mem_assoc key fields) expected

(* The wire shape is parsed ONCE into these closed types; validation is the
   parser and rendering is a total function over the result. The previous
   arrangement kept four validate_* and four render_* functions matching the
   same JSON in parallel — the same value was matched up to three times, and
   the render side re-decided validity with the diagnostics erased. *)
type manifest_revision =
  | Manifest_missing
  | Manifest_sha256 of string

type runtime_assignment =
  | Assignment_absent
  | Assignment_assigned of string

type runtime_assignment_revision =
  | Runtime_config_missing
  | Runtime_config_present of
      { source_revision : string
      ; assignment : runtime_assignment
      }

type config_revision =
  { manifest : manifest_revision
  ; runtime_assignment : runtime_assignment_revision
  }

(* The server answers {state:"unavailable", detail} in place of the revision
   pair when it could not read it (dashboard_http_keeper_snapshot). That is
   an answer to show, not an invalid document. *)
type config_revision_state =
  | Revision of config_revision
  | Revision_unavailable of string

let manifest_revision_of_json = function
  | `Assoc [ ("state", `String "missing") ] -> Ok Manifest_missing
  | `Assoc fields when exact_keys [ "state"; "value" ] fields ->
    (match List.assoc_opt "state" fields, List.assoc_opt "value" fields with
     | Some (`String "sha256"), Some (`String value)
       when is_lowercase_sha256 value -> Ok (Manifest_sha256 value)
     | _ -> Error "keeper config manifest revision is invalid")
  | _ -> Error "keeper config manifest revision is invalid"

let runtime_assignment_of_json = function
  | `Assoc [ ("state", `String "missing") ] -> Ok Assignment_absent
  | `Assoc fields when exact_keys [ "state"; "runtime_id" ] fields ->
    (match List.assoc_opt "state" fields, List.assoc_opt "runtime_id" fields with
     | Some (`String "assigned"), Some (`String runtime_id)
       when String.trim runtime_id <> "" -> Ok (Assignment_assigned runtime_id)
     | _ -> Error "keeper runtime assignment state is invalid")
  | _ -> Error "keeper runtime assignment state is invalid"

let runtime_assignment_revision_of_json = function
  | `Assoc [ ("state", `String "runtime_config_missing") ] ->
    Ok Runtime_config_missing
  | `Assoc fields
    when exact_keys [ "state"; "source_revision"; "assignment" ] fields ->
    (match
       List.assoc_opt "state" fields,
       List.assoc_opt "source_revision" fields,
       List.assoc_opt "assignment" fields
     with
     | ( Some (`String "runtime_config_present")
       , Some (`String source_revision)
       , Some assignment )
       when is_lowercase_sha256 source_revision ->
       Result.map
         (fun assignment ->
           Runtime_config_present { source_revision; assignment })
         (runtime_assignment_of_json assignment)
     | _ -> Error "keeper runtime assignment revision is invalid")
  | _ -> Error "keeper runtime assignment revision is invalid"

let config_revision_state_of_json = function
  | `Assoc fields when exact_keys [ "state"; "detail" ] fields ->
    (match List.assoc_opt "state" fields, List.assoc_opt "detail" fields with
     | Some (`String "unavailable"), Some (`String detail) ->
       Ok (Revision_unavailable detail)
     | _ -> Error "keeper config revision is invalid")
  | `Assoc fields
    when exact_keys [ "manifest"; "runtime_assignment" ] fields ->
    (match
       List.assoc_opt "manifest" fields,
       List.assoc_opt "runtime_assignment" fields
     with
     | Some manifest, Some runtime_assignment ->
       Result.bind
         (manifest_revision_of_json manifest)
         (fun manifest ->
           Result.map
             (fun runtime_assignment -> Revision { manifest; runtime_assignment })
             (runtime_assignment_revision_of_json runtime_assignment))
     | _ -> Error "keeper config revision is incomplete")
  | _ -> Error "keeper config revision is invalid"

let expected_config_revision before =
  match member "config_revision" before with
  | Some revision ->
    (match config_revision_state_of_json revision with
     | Ok (Revision _) -> Ok revision
     | Ok (Revision_unavailable detail) ->
       (* Posting the unavailable marker as a CAS expected value can only
          fail later with a worse message; stop with the server's own. *)
       Error ("keeper config revision is unavailable: " ^ detail)
     | Error _ as error -> error)
  | None -> Error "keeper config revision was not observed"

let expected_runtime_assignment_revision before =
  Result.bind
    (expected_config_revision before)
    (fun revision ->
      match member "runtime_assignment" revision with
      | Some runtime_assignment -> Ok runtime_assignment
      | None -> Error "keeper runtime assignment revision was not observed")

let decode_unchanged_runtime_assignment_response = function
  | `Assoc fields
    when exact_keys [ "ok"; "applied"; "assignment_revision"; "warnings" ] fields ->
    (match
       List.assoc_opt "ok" fields,
       List.assoc_opt "applied" fields,
       List.assoc_opt "assignment_revision" fields,
       List.assoc_opt "warnings" fields
     with
     | Some (`Bool true), Some (`Bool false), Some revision, Some (`List warnings)
       when List.for_all
              (function
                | `Assoc warning_fields
                  when exact_keys [ "code"; "detail" ] warning_fields ->
                  (match
                     List.assoc_opt "code" warning_fields,
                     List.assoc_opt "detail" warning_fields
                   with
                   | Some (`String _), Some (`String _) -> true
                   | _ -> false)
                | _ -> false)
              warnings ->
       Result.map
         (fun (_ : runtime_assignment_revision) -> revision)
         (runtime_assignment_revision_of_json revision)
     | _ -> Error "runtime assignment response is not an unchanged write")
  | _ -> Error "runtime assignment response must be an object"

let config_write_warning_codes json =
  match member "config_write" json with
  | Some (`Assoc fields)
    when exact_keys [ "revision"; "applied"; "warnings" ] fields ->
    (match
       List.assoc_opt "revision" fields,
       List.assoc_opt "applied" fields,
       List.assoc_opt "warnings" fields
     with
     | Some revision, Some (`Bool _), Some (`List warnings) ->
       (* A write receipt's revision is the pair the write produced; the
          unavailable marker there is a contract violation, matching the
          dashboard's reading of the same receipt. *)
       Result.bind
         (match config_revision_state_of_json revision with
          | Ok (Revision _) -> Ok ()
          | Ok (Revision_unavailable detail) ->
            Error ("config write revision is unavailable: " ^ detail)
          | Error _ as error -> error)
         (fun () ->
           let rec decode acc = function
             | [] -> Ok (List.rev acc)
             | `Assoc warning_fields :: rest
               when exact_keys [ "code"; "detail" ] warning_fields ->
               (match
                  List.assoc_opt "code" warning_fields,
                  List.assoc_opt "detail" warning_fields
                with
                | Some (`String code), Some (`String detail)
                  when String.trim code <> "" && String.trim detail <> "" ->
                  decode (code :: acc) rest
                | _ -> Error "config durability warning is malformed")
             | _ -> Error "config durability warning is malformed"
           in
           decode [] warnings)
     | _ -> Error "config_write receipt is malformed")
  | Some _ -> Error "config_write receipt is malformed"
  | None -> Error "config_write receipt is missing"

let config_write_status_message ~keeper_name json =
  Result.map
    (function
      | [] -> "system", keeper_name ^ ": changed settings applied"
      | warning_codes ->
        ( "error"
        , Printf.sprintf
            "%s: settings applied with %d config durability warning(s): %s"
            keeper_name
            (List.length warning_codes)
            (String.concat ", " warning_codes) ))
    (config_write_warning_codes json)

let patch_of_edit ~before ~after =
  match after with
  | `Assoc edited_fields ->
      let unknown =
        edited_fields
        |> List.filter_map (fun (key, _) ->
               if List.mem key editable_field_names
                  || String.equal key confirm_context_shrink_field
               then None
               else Some key)
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
                 String.equal key confirm_context_shrink_field
                 ||
                 match List.assoc_opt key before_fields with
                 | Some old_value -> not (Yojson.Safe.equal value old_value)
                 | None -> true)
        in
        (* The confirm flag alone is not an edit. Sending it on its own would
           post a patch that changes nothing and still burn a revision. *)
        let settings_changed =
          List.filter
            (fun (key, _) -> not (String.equal key confirm_context_shrink_field))
            changed
        in
        if settings_changed = []
        then Ok (`Assoc [])
        else
          Result.map
            (fun revision ->
              `Assoc (("expected_config_revision", revision) :: changed))
            (expected_config_revision before)
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

(* Total renderers over the parsed types: the JSON was judged once by the
   parser, so nothing here can fail or disagree with validation. *)
let render_manifest_revision = function
  | Manifest_missing -> "manifest=missing"
  | Manifest_sha256 value -> "manifest=sha256:" ^ value

let render_assignment = function
  | Assignment_absent -> "assignment=missing"
  | Assignment_assigned runtime_id -> "assignment=assigned:" ^ runtime_id

let render_runtime_assignment_revision = function
  | Runtime_config_missing -> "runtime=missing"
  | Runtime_config_present { source_revision; assignment } ->
    Printf.sprintf "runtime=present source=sha256:%s %s"
      source_revision
      (render_assignment assignment)

let config_revision_value = function
  | Some revision ->
    (match config_revision_state_of_json revision with
     | Ok (Revision { manifest; runtime_assignment }) ->
       render_manifest_revision manifest
       ^ " | "
       ^ render_runtime_assignment_revision runtime_assignment
     | Ok (Revision_unavailable detail) ->
       "revision unavailable: " ^ detail
     | Error detail -> "invalid composite config revision: " ^ detail)
  | None -> "invalid composite config revision: not observed"

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
  ; editable_value_row "Sandbox / network"
      (fun () ->
        Printf.sprintf "%s / %s"
          (string_value (at [ "sandbox_profile" ]))
          (string_value (at [ "network_mode" ])))
  ; editable_value_row "Mention targets"
      (fun () -> string_list_value (at [ "workspace"; "mention_targets" ]))
  ; editable_value_row "Skills"
      (fun () -> skill_selection_value (at [ "skills"; "names" ]))
  ; ""
  ; section "derived" "read-only"
  ; read_only_value_row "Config revision"
      (fun () -> config_revision_value (at [ "config_revision" ]))
  ; read_only_value_row "Sandbox roots"
      (fun () -> string_list_value (at [ "sandbox_roots" ]))
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
